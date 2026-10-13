import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

@main
struct OpenScreenStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @State private var showingAbout = false
    @StateObject private var preview = LargePreviewModel()
    var body: some Scene {
        Window("录映", id: "studio") {
            StudioView().environmentObject(preview).frame(minWidth: 1050, minHeight: 820)
                .sheet(isPresented: $showingAbout) { AboutLuYingView() }
        }.windowStyle(.titleBar)
        .commands { CommandGroup(replacing: .appInfo) { Button("关于录映") { showingAbout = true } } }
        Window("放大预览", id: "large-preview") { LargePreviewView().environmentObject(preview) }.defaultSize(width: 1000, height: 640)

    }
}
struct StudioView: View {
    @State private var countdown = RecordingCountdown()
    @State private var cameraPreview = CameraPreviewPanel()
    @StateObject private var micCheck = MicrophoneCheck()
    @StateObject private var recordingMenu = RecordingMenu()
    @AppStorage("hideWorkbenchWhenRecording") private var hideWorkbench = true
    @State private var lastExport: URL?
    @StateObject private var capture = CaptureEngine()
    @StateObject private var camera = WebcamRecorder()
    @StateObject private var exporter = ExportController()
    @StateObject private var timeline = TimelineModel()
    @StateObject private var transcriber = Transcriber()
    @State private var showingAbout = false
    @EnvironmentObject private var preview: LargePreviewModel
    @Environment(\.openWindow) private var openWindow
    @State private var locale = "zh-CN"
    @State private var outputWidth = 1920
    @State private var background = "#18233f,#7849b8"
    @State private var projectURL: URL?
    @State private var denoise = false
    @State private var musicURL: URL?
    @State private var backgroundImageURL: URL?
    @State private var showingEffects = false
    @State private var recordedCursor = true
    @State private var source = "display"
    @State private var displayID: UInt32 = 0
    @State private var windowID: UInt32 = 0
    @State private var microphone = false
    @State private var systemAudio = true
    @State private var region: CGRect?
    @State private var regionSelection = RegionSelection()
    @State private var webcam = false
    @State private var cursor = true
    @State private var fps = 60
    @State private var video: URL?
    @State private var webcamURL: URL?
    @State private var captionsURL: URL?
    @State private var player: AVPlayer?
    @State private var speed = 1.0
    @State private var aspect = "original"
    @State private var padding = 60.0
    @State private var zoom = true
    @State private var clicks = true
    @State private var editTab = "剪辑"
    @State private var format = "mp4"
    private var exporting: Bool { exporter.isRunning }
    @State private var recordingBusy = false
    @State private var message = "选择录制来源，或导入已有视频开始编辑。"
    @State private var elapsed = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var recordingSidebar: some View {
            VStack(alignment: .leading, spacing: 20) {
                Label("录映", systemImage: "record.circle").font(.title2.bold())
                Text("本地录制 · 免费导出 · 无水印").foregroundStyle(.secondary)
                Divider()
                Text("录制来源").font(.headline)
                Picker("类型", selection: $source) { Text("显示器").tag("display"); Text("窗口").tag("window"); Text("区域").tag("region") }.pickerStyle(.segmented).disabled(capture.isRecording || recordingBusy || capture.isSaving).onChange(of: source) { _, _ in capture.clearSelectedSource();region = nil }
                Button(source == "region" ? "框选录制区域…" : (source == "window" ? "选择窗口…" : "选择显示器…")) { Task { await selectRecordingSource() } }.disabled(capture.isRecording || recordingBusy || capture.isSaving || capture.isStarting || capture.isSelecting)
                if capture.isSelecting { Button("取消选择") { capture.cancelSelection() } }
                Text(capture.selectedSourceName).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if source == "region" { Text(region.map { "已框选 \(Int($0.width)) × \(Int($0.height)) · 点击上方按钮重新选择" } ?? "选择显示器后，直接拖动鼠标框选范围。").font(.caption).foregroundStyle(.secondary) }
                Toggle("录制系统声音", isOn: $systemAudio).disabled(capture.isRecording || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                Toggle("录制麦克风", isOn: $microphone).disabled(capture.isRecording || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                if microphone && supportsMicrophone && !capture.isRecording && !recordingBusy {
                    ProgressView(value: micCheck.level).tint(.green)
                    Text(micCheck.status).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("录制时收起工作台", isOn: $hideWorkbench).font(.caption).disabled(capture.isRecording)
                Toggle("录制摄像头", isOn: $webcam).disabled(capture.isRecording || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                if webcam {
                    Text(camera.status).font(.caption).foregroundStyle(camera.error == nil ? Color.secondary : Color.red)
                    Button("显示摄像头预览") { cameraPreview.show(camera: camera) }.font(.caption)
                }
                Toggle("显示原始鼠标", isOn: $cursor).disabled(capture.isRecording || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                Picker("帧率", selection: $fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.disabled(capture.isRecording || recordingBusy)
                Text(microphone && !supportsMicrophone ? "麦克风需要 macOS 15+" : (capture.hasSelectedSource ? "录制内容已授权" : "请先选择并确认录制来源")).font(.caption).foregroundStyle(.secondary)
                Button(action: { Task { await record() } }) {
                    Label(capture.isRecording ? "停止录制 · \(elapsed)s" : "开始录制", systemImage: capture.isRecording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity).padding(8)
                }.buttonStyle(.borderedProminent).tint(capture.isRecording ? .red : .indigo).keyboardShortcut("r", modifiers: [.command,.shift]).disabled(exporting || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                if capture.isRecording { Button(capture.isPaused ? "继续录制" : "暂停录制", systemImage: capture.isPaused ? "play.fill" : "pause.fill") { let time = CMClockGetTime(CMClockGetHostTimeClock()); capture.togglePause(at: time); camera.setPaused(capture.isPaused, at: time) } }
                Text(recordingMenu.shortcutStatus).font(.caption).foregroundStyle(.secondary)
                Text(capture.deviceStatus).font(.caption).foregroundStyle(.secondary)
                Text(capture.status).font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("导入视频…", systemImage: "folder") { chooseVideo() }.disabled(capture.isRecording || recordingBusy || capture.isSaving || exporting)
                HStack { Button("打开项目") { openProject() }; Button("保存项目") { saveProject() }.disabled(video == nil) }.disabled(capture.isRecording || exporting || recordingBusy || capture.isSaving)
                if let video { Button("在 Finder 中显示", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.activateFileViewerSelecting([video]) } }
                Spacer()
                Text("macOS 原生录制引擎\n所有已实现功能均免费开放").font(.caption).foregroundStyle(.secondary)
                Link("by zlbigger.com", destination: URL(string: "https://zlbigger.com")!).font(.caption)
                Button("关于录映 · 支持作者") { showingAbout = true }.buttonStyle(.link).font(.caption)
            }.padding(24).frame(width: 300).background(Color(nsColor: .windowBackgroundColor))
    }
    private var workbench: some View {
        HStack(spacing: 0) {
            recordingSidebar

            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("创作工作台").font(.title.bold()); Spacer(); Text("LOCAL / FREE").font(.caption.bold()).foregroundStyle(.indigo) }
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [.indigo.opacity(0.8), .purple.opacity(0.5), .pink.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let player { NativeVideoPlayer(player: player).padding(24) }
                    else { VStack(spacing: 14) { Image(systemName: "video.badge.waveform").font(.system(size: 52)); Text("把操作录成好看的视频").font(.title2); Text("录制完成后即可预览、裁剪和导出").foregroundStyle(.secondary) } }
                }.frame(height:220)
                if let video {
                    if webcamURL != nil { Text(showingEffects ? "已叠加摄像头画面" : "摄像头单独保存 · 在效果预览和导出中叠加").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Text((showingEffects ? "效果预览 · " : "原始素材预览 · ") + video.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("放大预览", systemImage: "arrow.up.left.and.arrow.down.right") {
                            if let player { preview.prepare(player: player);openWindow(id: "large-preview") }
                        }.disabled(player == nil || capture.isRecording || exporting).help("打开大窗口预览，可自行切换全屏")
                    }
                }
                if video != nil {
                    Picker("编辑工作区",selection:$editTab) { Text("剪辑").tag("剪辑");Text("缩放").tag("缩放");Text("画布与声音").tag("画布") }.pickerStyle(.segmented)
                    if editTab != "画布" { TimelineView(model:timeline,speed:speed,video:video,mode:editTab,seek:seekSource,notify:{ message=$0 }).disabled(exporting || capture.isRecording || recordingBusy || capture.isSaving) }
                    HStack { Picker("速度",selection:$speed) { ForEach([0.5,1.0,1.5,2.0],id:\.self) { Text("\($0,specifier:"%.1f")×").tag($0) } }.frame(width:160);Spacer() }.disabled(exporting || capture.isRecording)
                }
                if video == nil || editTab == "画布" {
                GroupBox("编辑与画布") {
                    VStack(spacing: 12) {
                        HStack { Picker("画布", selection: $aspect) { Text("原始尺寸").tag("original"); ForEach(["16:9","9:16","1:1","4:3"], id: \.self) { Text($0).tag($0) } }; if aspect != "original" { Text("边距 \(Int(padding))"); Slider(value: $padding, in: 0...160) } }
                        if aspect == "original" { Text("保持原视频像素尺寸，不加背景、边距、圆角或阴影。").font(.caption).foregroundStyle(.secondary) }
                        else { HStack { Picker("导出宽度", selection: $outputWidth) { Text("1280 px").tag(1280); Text("1920 px").tag(1920); Text("2560 px").tag(2560); Text("3840 px").tag(3840) }; Picker("背景", selection: $background) { Text("紫夜").tag("#18233f,#7849b8"); Text("海蓝").tag("#083344,#0891b2"); Text("暖橙").tag("#7c2d12,#fb923c"); Text("深灰").tag("#18181b,#3f3f46") } } }
                        HStack { Toggle("点击自动缩放", isOn: $zoom); Toggle("点击提示", isOn: $clicks); Spacer(); Button(captionsURL == nil ? "导入 SRT 字幕…" : "已选择字幕") { captionsURL = chooseFile(types: ["srt"]) } }
                    HStack { Toggle("音频降噪", isOn: $denoise); Button(musicURL == nil ? "背景音乐…" : "更换背景音乐…") { musicURL = chooseFile(types: ["mp3","m4a","wav","aiff"]) }; Button(backgroundImageURL == nil ? "背景图片…" : "更换背景图片…") { backgroundImageURL = chooseFile(types: ["png","jpg","jpeg","heic"]) }; if musicURL != nil || backgroundImageURL != nil { Button("清除") { musicURL = nil; backgroundImageURL = nil } } }
                    HStack { Picker("字幕语言", selection: $locale) { Text("中文").tag("zh-CN"); Text("English").tag("en-US") }.frame(width: 155); Button(transcriber.isWorking ? "识别中…" : "生成本地字幕") { Task { guard let video else { return }; do { captionsURL = try await transcriber.transcribe(video: video, locale: locale); message = "字幕已生成：\(captionsURL!.lastPathComponent)" } catch { message = error.localizedDescription } } }.disabled(video == nil || transcriber.isWorking || recordingBusy || capture.isSaving); Spacer() }
                    }.padding(8)
                }.disabled(exporting || capture.isRecording || recordingBusy || capture.isSaving)
                }
                Spacer(minLength:0)
                HStack { Picker("格式", selection: $format) { Text("MP4").tag("mp4"); Text("GIF").tag("gif") }.frame(width: 140); Spacer(); Button("效果预览") { exportVideo(preview: true) }.disabled(video == nil || exporting || capture.isRecording || recordingBusy || capture.isSaving);  Button(exporting ? "正在导出…" : "导出视频…", systemImage: "square.and.arrow.up") { exportVideo() }.buttonStyle(.borderedProminent).disabled(video == nil || exporting || capture.isRecording || recordingBusy || capture.isSaving) }
                if exporting { VStack(alignment: .leading, spacing: 6) { ProgressView(value: exporter.progress); HStack { Text(exporter.phase); Text(exporter.remaining).foregroundStyle(.secondary); Spacer(); Button("取消导出") { exporter.cancel() } } }.font(.caption) }
                if let lastExport, !exporting {
                    HStack {
                        Button("复制成片文件", systemImage: "doc.on.doc") {
                            guard FileManager.default.fileExists(atPath: lastExport.path) else { message = "成片已移动或删除";return }
                            NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects([lastExport as NSURL]);message = "已复制文件，可粘贴到聊天或邮件。"
                        }
                        Button("打开成片位置") { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
                    }
                }
                if exporter.canRetry && !exporting { Button("重试上次导出") { exporter.retry() }.disabled(capture.isRecording || recordingBusy) }
                Text(exporter.message.isEmpty ? message : exporter.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
            }.padding(26)
        }
    }
    private var recordingLifecycle: some View {
        workbench
        .onChange(of: webcam) { _, enabled in
            if enabled { cameraPreview.show(camera: camera);Task { await camera.startPreview() } }
            else { cameraPreview.close();Task { await camera.stopPreview() } }
        }
        .onChange(of: microphone) { _, enabled in
            if enabled && supportsMicrophone && !capture.isRecording { Task { await micCheck.start() } } else { micCheck.stop() }
        }
        .onChange(of: capture.isRecording) { _, active in
            if !active {
                recordingMenu.update(recording: false, paused: false, seconds: elapsed, source: capture.selectedSourceName)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.identifier?.rawValue == "studio" }?.makeKeyAndOrderFront(nil)
                if microphone { Task { await micCheck.start() } }
            }
        }
        .onChange(of: capture.isPaused) { _, _ in updateRecordingMenu() }

    }
    var body: some View {
        recordingLifecycle.sheet(isPresented: $showingAbout) { AboutLuYingView() }.sheet(isPresented: $capture.isConfirmingSource) { RecordingSourceView(capture: capture) }.onChange(of: capture.isRecording || capture.isSaving || recordingBusy || exporting, initial: true) { _, busy in AppActivity.shared.busy = busy }
        .onChange(of: video) { _, url in
            timeline.observe(player,source:!showingEffects)
        }
        .onChange(of: player) { _,_ in timeline.observe(player,source:!showingEffects) }
        .onChange(of: showingEffects) { _, effects in timeline.observe(player,source:!effects) }
        .onChange(of: message) { _, _ in exporter.clearMessage() }
        .onChange(of: recoveryData) { _, data in
            guard let data else { return }
            if showingEffects, let video { showingEffects=false;player=AVPlayer(url:video) }
            do { let url = recoveryURL; try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url, options: .atomic) }
            catch { message = "自动保存编辑参数失败，请手动保存项目：\(error.localizedDescription)" }
        }.onChange(of: camera.error) { _, error in if let error { message = "摄像头异常：\(error)。" + (capture.isRecording ? "屏幕录制继续。" : "请检查设备或授权。") } }
        .onChange(of: exporter.completedURL) { _, url in
            guard let url else { return }
            if exporter.completedPreview { player = AVPlayer(url: url); showingEffects = true }
            else { lastExport = url }
        }.onChange(of: capture.recoveredURL) { _, url in
            guard let url else { return }
            Task { if webcam { webcamURL = await camera.stop() }; video = url; timeline.load(url); player = AVPlayer(url: url); showingEffects = false; message = "录制被中断，已保存可恢复的视频。" }
        }.task { capture.refreshDeviceStatus(); restoreRecovery(); if video == nil { message = "选择录制类型，再点击选择按钮。" } }.onReceive(timer) { _ in capture.refreshDeviceStatus(); if capture.isRecording && !capture.isPaused { elapsed += 1 };updateRecordingMenu() }
    }
    func updateRecordingMenu() {
        recordingMenu.pause = {
            guard capture.isRecording, !recordingBusy, !capture.isSaving else { return }
            let time = CMClockGetTime(CMClockGetHostTimeClock());capture.togglePause(at: time);camera.setPaused(capture.isPaused, at: time)
        }
        recordingMenu.stop = { guard capture.isRecording, !recordingBusy, !capture.isSaving else { return };Task { await record() } }
        recordingMenu.update(recording: capture.isRecording, paused: capture.isPaused, seconds: elapsed, source: capture.selectedSourceName)
    }
    private var supportsMicrophone: Bool { if #available(macOS 15.0, *) { return true }; return false }
    func selectRecordingSource() async {
        if await capture.selectSource(mode: source) {
            if source == "region" {
                guard let id = capture.selectedDisplayID else { capture.clearSelectedSource();return }
                let studio = NSApp.windows.first { $0.identifier?.rawValue == "studio" };studio?.orderOut(nil)
                region = await regionSelection.choose(displayID:id)
                studio?.makeKeyAndOrderFront(nil)
                guard region != nil else { capture.clearSelectedSource();message = "已取消区域选择";return }
            }
            message = "已选择：\(capture.selectedSourceName)。可以开始录制。" } else { message = capture.status }
    }
    func refresh() async { do { try await capture.refreshSources() } catch { message = error.localizedDescription } }
    func record() async {
        guard !recordingBusy else { return }
        micCheck.stop();preview.syncBack()
        recordingBusy = true; defer { recordingBusy = false }
        if capture.isRecording {
            let saved = await capture.stop()
            if let saved { video = saved; timeline.load(saved) }
            if webcam { webcamURL = await camera.stop();Task { await camera.startPreview() } }
            if let saved { player = AVPlayer(url: saved); showingEffects = false; message = "录制已保存。设置裁剪、画布和效果，然后导出。" }
            else { message = capture.error ?? "保存失败" }
            return
        }
        if !capture.hasSelectedSource { await selectRecordingSource(); guard capture.hasSelectedSource else { return } }
        do {
            let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("OpenScreenStudio")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("Recording-\(Int(Date().timeIntervalSince1970)).mov")
            var crop: CGRect? = nil
            if source == "region" { guard let region else { throw CaptureFailure.message("请先框选录制区域。") };crop = region }
            let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard free > 512 * 1024 * 1024 else { throw CaptureFailure.message("可用空间不足 512 MB，请清理磁盘后再录制。") }
            if microphone && !supportsMicrophone { throw CaptureFailure.message("麦克风录制需要 macOS 15+。") }
            let studio = NSApp.windows.first { $0.identifier?.rawValue == "studio" }
            if hideWorkbench { studio?.orderOut(nil) }
            guard await countdown.run(source:capture.selectedSourceName) else {
                studio?.makeKeyAndOrderFront(nil);message = "已取消录制";if microphone { Task { await micCheck.start() } };return
            }
            webcamURL = nil
            if webcam { let cameraFile = destination.deletingPathExtension().appendingPathExtension("camera.mov"); try await camera.start(outputURL: cameraFile); webcamURL = cameraFile }
            let origin = CMClockGetTime(CMClockGetHostTimeClock())
            camera.beginTimeline(at: origin)
            try await capture.start(timelineStart: origin, displayID: displayID == 0 ? nil : displayID, windowID: nil, microphone: microphone, systemAudio: systemAudio, sourceRect: crop, showCursor: cursor, fps: fps, outputURL: destination)
            recordedCursor = cursor; elapsed = 0;updateRecordingMenu();if hideWorkbench { NSApp.windows.filter { $0.identifier?.rawValue == "studio" || $0.identifier?.rawValue == "large-preview" }.forEach { $0.orderOut(nil) } }
             message = "正在录制；停止后保存至 Movies/OpenScreenStudio。"
        } catch { NSApp.windows.first { $0.identifier?.rawValue == "studio" }?.makeKeyAndOrderFront(nil);if webcam { _ = await camera.stop();Task { await camera.startPreview() } }; message = error.localizedDescription }
    }
    private var recoveryURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LuYing/Recovery.ossproject") }
    private var currentProject: StudioProject? {
        guard let video, !timeline.loading, timeline.duration>0 else { return nil }
        return StudioProject(video: video.path, webcam: webcamURL?.path, captions: captionsURL?.path, start: String(timeline.edit.start), end: String(timeline.edit.end), speed: speed, aspect: aspect, padding: padding, zoom: zoom, clicks: clicks, fps: fps, width: outputWidth, background: background, denoise: denoise, music: musicURL?.path, backgroundImage: backgroundImageURL?.path, recordedCursor: recordedCursor, timeline: timeline.edit)
    }
    private var recoveryData: Data? { currentProject.flatMap { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try? encoder.encode($0) } }
    func restoreRecovery() {
        guard let data = try? Data(contentsOf: recoveryURL), let p = try? JSONDecoder().decode(StudioProject.self, from: data), FileManager.default.fileExists(atPath: p.video) else { return }
        applyProject(p); message = "已恢复上次编辑，原素材保留在原位置。"
    }
    func applyProject(_ p: StudioProject) {
        video = URL(fileURLWithPath: p.video);
        timeline.load(video!,saved:p.timeline ?? TimelineEdit(start:Double(p.start) ?? 0,end:Double(p.end) ?? 0)); webcamURL = p.webcam.map { URL(fileURLWithPath: $0) }; captionsURL = p.captions.map { URL(fileURLWithPath: $0) }; speed = p.speed; aspect = p.aspect; padding = p.padding; zoom = p.zoom; clicks = p.clicks; fps = p.fps; outputWidth = p.width; background = p.background; denoise = p.denoise ?? false; recordedCursor = p.recordedCursor ?? true; showingEffects = false; musicURL = p.music.map { URL(fileURLWithPath: $0) }; backgroundImageURL = p.backgroundImage.map { URL(fileURLWithPath: $0) }; player = AVPlayer(url: video!)
    }
    static func exportTimestamp() -> String { let formatter = DateFormatter();formatter.dateFormat = "yyyyMMdd-HHmmss-SSS";return formatter.string(from:Date()) }
    func saveProject() {
        guard let project = currentProject else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Untitled"; panel.allowedContentTypes = [UTType(filenameExtension: "ossproject") ?? .json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do { try JSONEncoder().encode(project).write(to: destination, options: .atomic); projectURL = destination; message = "项目已保存；素材保留在原位置。" } catch { message = error.localizedDescription }
    }
    func openProject() {
        guard let url = chooseFile(types: ["ossproject","json"]) else { return }
        do { let p = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: url)); guard FileManager.default.fileExists(atPath: p.video) else { throw CaptureFailure.message("素材已移动，请恢复至：\(p.video)") }; applyProject(p); projectURL = url; message = "项目已恢复。" } catch { message = error.localizedDescription }
    }
    func chooseFile(types: [String]) -> URL? { let panel = NSOpenPanel(); panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }; panel.canChooseDirectories = false; return panel.runModal() == .OK ? panel.url : nil }
    func chooseVideo() { if let url = chooseFile(types: ["mov","mp4","m4v"]) { video = url; timeline.load(url); webcamURL = nil; captionsURL = nil; recordedCursor = true; player = AVPlayer(url: url); showingEffects = false; message = "已导入视频。鼠标自动缩放需要同名 JSON 轨迹文件。" } }
    func seekSource(_ seconds: Double) {
        guard let video else { return }
        if showingEffects { player=AVPlayer(url:video);showingEffects=false }
        player?.pause();player?.seek(to:CMTime(seconds:seconds,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
        timeline.playhead=seconds;timeline.observe(player,source:true)
    }
    func exportVideo(preview: Bool = false) {
        guard let video else { return }
        guard !timeline.loading, timeline.keptDuration>0.05 else { message="请等待素材读取，并保留至少 0.05 秒画面。"; return }
        let edits=timeline.edit
        let destination: URL
        if preview { destination = FileManager.default.temporaryDirectory.appendingPathComponent("OpenScreenStudio-preview-\(UUID().uuidString).mp4") }
        else { let panel = NSSavePanel(); panel.nameFieldStringValue = "录映-\(Self.exportTimestamp()).\(format)"; panel.allowedContentTypes = [UTType(filenameExtension: format)!]; guard panel.runModal() == .OK, let url = panel.url else { return }; destination = url }
        var args = [video.path, destination.path, "--start", String(edits.start), "--end", String(edits.end), "--speed", String(speed), "--aspect", aspect, "--padding", String(Int(padding)), "--fps", String(fps), "--cursor-size", recordedCursor ? "0" : "18", "--width", String(preview ? min(outputWidth,960) : outputWidth), "--background", background]
        if let data=try? JSONEncoder().encode(edits.cuts),let json=String(data:data,encoding:.utf8) { args += ["--cuts-json",json] }
        if let data=try? JSONEncoder().encode(edits.scenes),let json=String(data:data,encoding:.utf8) { args += ["--zoom-scenes-json",json] }
        if !zoom { args += ["--zoom","1"] }
        if preview { args += ["--preview-duration","8"] }
        let mouse = video.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: mouse.path) { args += ["--mouse",mouse.path]; if !clicks { args += ["--no-clicks"] } }
        if let webcamURL, FileManager.default.fileExists(atPath: webcamURL.path) { args += ["--webcam",webcamURL.path] }
        if let captionsURL { args += ["--captions",captionsURL.path] }
        if denoise { args += ["--denoise"] }
        if let musicURL { args += ["--music",musicURL.path] }
        if let backgroundImageURL { args += ["--background-image",backgroundImageURL.path] }
        exporter.start(args: args, destination: destination, preview: preview)
    }
}

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.controlsStyle = .inline; view.allowsVideoFrameAnalysis = false; view.player = player; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

struct StudioProject: Codable {
    let video: String; let webcam: String?; let captions: String?
    let start: String; let end: String; let speed: Double; let aspect: String; let padding: Double
    let zoom: Bool; let clicks: Bool; let fps: Int; let width: Int; let background: String; let denoise: Bool?; let music: String?; let backgroundImage: String?; let recordedCursor: Bool?; let timeline: TimelineEdit?
}

struct AboutLuYingView: View {
    @Environment(\.dismiss) private var dismiss
    private let repository = URL(string: "https://github.com/zlbigger/luying")!
    private let reward = URL(string: "https://www.praybuddha.com/generated/diamond-sutra-immersive/reward-qr.png")!
    var body: some View {
        VStack(spacing: 16) {
            Text("录映 · LuYing").font(.title.bold())
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").foregroundStyle(.secondary)
            Text("免费的 macOS 录屏与视频美化工具。\n本地录制、时间线剪辑、平滑缩放、字幕与无水印导出。")
                .multilineTextAlignment(.center)
            Link("by zlbigger.com", destination: URL(string: "https://zlbigger.com")!)
            Link("开源地址：github.com/zlbigger/luying", destination: repository)
            Divider()
            Text("喜欢录映？欢迎打赏支持作者").font(.headline)
            if let url = Bundle.main.url(forResource: "reward-qr", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 220, height: 220).accessibilityLabel("作者打赏二维码")
            }
            Link("打开打赏码", destination: reward)
            Text("打赏完全自愿，所有已实现功能均免费开放。").font(.caption).foregroundStyle(.secondary)
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(28).frame(width: 460)
    }
}
