import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

@main
struct OpenScreenStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    var body: some Scene { Window("录映", id: "studio") { StudioView().frame(minWidth: 1050, minHeight: 820) }.windowStyle(.titleBar) }
}
struct StudioView: View {
    @StateObject private var capture = CaptureEngine()
    @StateObject private var camera = WebcamRecorder()
    @StateObject private var exporter = ExportController()
    @StateObject private var transcriber = Transcriber()
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
    @State private var region = "0,0,1280,720"
    @State private var webcam = false
    @State private var cursor = true
    @State private var fps = 60
    @State private var video: URL?
    @State private var webcamURL: URL?
    @State private var captionsURL: URL?
    @State private var player: AVPlayer?
    @State private var start = "0"
    @State private var end = ""
    @State private var speed = 1.0
    @State private var aspect = "16:9"
    @State private var padding = 60.0
    @State private var zoom = true
    @State private var clicks = true
    @State private var format = "mp4"
    private var exporting: Bool { exporter.isRunning }
    @State private var recordingBusy = false
    @State private var message = "选择录制来源，或导入已有视频开始编辑。"
    @State private var elapsed = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Label("录映", systemImage: "record.circle").font(.title2.bold())
                Text("本地录制 · 免费导出 · 无水印").foregroundStyle(.secondary)
                Divider()
                Text("录制来源").font(.headline)
                Picker("类型", selection: $source) { Text("显示器").tag("display"); Text("窗口").tag("window"); Text("区域").tag("region") }.pickerStyle(.segmented).disabled(capture.isRecording || recordingBusy || capture.isSaving).onChange(of: source) { _, _ in capture.clearSelectedSource() }
                Button(source == "window" ? "选择窗口…" : "选择显示器…") { Task { await selectRecordingSource() } }.disabled(capture.isRecording || recordingBusy || capture.isSaving || capture.isStarting || capture.isSelecting)
                if capture.isSelecting { Button("取消选择") { capture.cancelSelection() } }
                Text(capture.selectedSourceName).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if source == "region" { TextField("区域 x,y,宽,高（逻辑像素）", text: $region); Text("先选择显示器，再设置显示器内的录制区域。").font(.caption).foregroundStyle(.secondary) }
                Toggle("录制系统声音", isOn: $systemAudio).disabled(capture.isRecording || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                Toggle("录制麦克风", isOn: $microphone).disabled(capture.isRecording || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                Toggle("录制摄像头", isOn: $webcam).disabled(capture.isRecording || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                Toggle("显示原始鼠标", isOn: $cursor).disabled(capture.isRecording || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                Picker("帧率", selection: $fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.disabled(capture.isRecording || recordingBusy)
                Text(microphone && !supportsMicrophone ? "麦克风需要 macOS 15+" : (capture.hasSelectedSource ? "录制内容已授权" : "请通过系统选择器选择内容")).font(.caption).foregroundStyle(.secondary)
                Button(action: { Task { await record() } }) {
                    Label(capture.isRecording ? "停止录制 · \(elapsed)s" : "开始录制", systemImage: capture.isRecording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity).padding(8)
                }.buttonStyle(.borderedProminent).tint(capture.isRecording ? .red : .indigo).keyboardShortcut("r", modifiers: [.command,.shift]).disabled(exporting || capture.isSaving || capture.isStarting || recordingBusy || capture.isSelecting)
                if capture.isRecording { Button(capture.isPaused ? "继续录制" : "暂停录制", systemImage: capture.isPaused ? "play.fill" : "pause.fill") { let time = CMClockGetTime(CMClockGetHostTimeClock()); capture.togglePause(at: time); camera.setPaused(capture.isPaused, at: time) } }
                Text(capture.deviceStatus).font(.caption).foregroundStyle(.secondary)
                Text(capture.status).font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("导入视频…", systemImage: "folder") { chooseVideo() }.disabled(capture.isRecording || recordingBusy || capture.isSaving || exporting)
                HStack { Button("打开项目") { openProject() }; Button("保存项目") { saveProject() }.disabled(video == nil) }.disabled(capture.isRecording || exporting || recordingBusy || capture.isSaving)
                if let video { Button("在 Finder 中显示", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.activateFileViewerSelecting([video]) } }
                Spacer()
                Text("macOS 原生录制引擎\n所有已实现功能均免费开放").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 300).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("创作工作台").font(.title.bold()); Spacer(); Text("LOCAL / FREE").font(.caption.bold()).foregroundStyle(.indigo) }
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [.indigo.opacity(0.8), .purple.opacity(0.5), .pink.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let player { NativeVideoPlayer(player: player).padding(24) }
                    else { VStack(spacing: 14) { Image(systemName: "video.badge.waveform").font(.system(size: 52)); Text("把操作录成好看的视频").font(.title2); Text("录制完成后即可预览、裁剪和导出").foregroundStyle(.secondary) } }
                }.frame(minHeight: 260)
                if let video { Text((showingEffects ? "效果预览 · " : "原始素材预览 · ") + video.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                GroupBox("编辑与画布") {
                    VStack(spacing: 12) {
                        HStack { TextField("起点（秒）", text: $start); TextField("终点（秒，留空至结尾）", text: $end); Picker("速度", selection: $speed) { ForEach([0.5,1.0,1.5,2.0], id: \.self) { Text("\($0, specifier: "%.1f")×").tag($0) } }.frame(width: 145) }
                        HStack { Picker("画布", selection: $aspect) { ForEach(["16:9","9:16","1:1","4:3"], id: \.self) { Text($0).tag($0) } }; Text("边距 \(Int(padding))"); Slider(value: $padding, in: 0...160) }
                        HStack { Picker("导出宽度", selection: $outputWidth) { Text("1280 px").tag(1280); Text("1920 px").tag(1920); Text("2560 px").tag(2560); Text("3840 px").tag(3840) }; Picker("背景", selection: $background) { Text("紫夜").tag("#18233f,#7849b8"); Text("海蓝").tag("#083344,#0891b2"); Text("暖橙").tag("#7c2d12,#fb923c"); Text("深灰").tag("#18181b,#3f3f46") } }
                        HStack { Toggle("点击自动缩放", isOn: $zoom); Toggle("点击提示", isOn: $clicks); Spacer(); Button(captionsURL == nil ? "导入 SRT 字幕…" : "已选择字幕") { captionsURL = chooseFile(types: ["srt"]) } }
                    HStack { Toggle("音频降噪", isOn: $denoise); Button(musicURL == nil ? "背景音乐…" : "更换背景音乐…") { musicURL = chooseFile(types: ["mp3","m4a","wav","aiff"]) }; Button(backgroundImageURL == nil ? "背景图片…" : "更换背景图片…") { backgroundImageURL = chooseFile(types: ["png","jpg","jpeg","heic"]) }; if musicURL != nil || backgroundImageURL != nil { Button("清除") { musicURL = nil; backgroundImageURL = nil } } }
                    HStack { Picker("字幕语言", selection: $locale) { Text("中文").tag("zh-CN"); Text("English").tag("en-US") }.frame(width: 155); Button(transcriber.isWorking ? "识别中…" : "生成本地字幕") { Task { guard let video else { return }; do { captionsURL = try await transcriber.transcribe(video: video, locale: locale); message = "字幕已生成：\(captionsURL!.lastPathComponent)" } catch { message = error.localizedDescription } } }.disabled(video == nil || transcriber.isWorking || recordingBusy || capture.isSaving); Spacer() }
                    }.padding(8)
                }.disabled(exporting || capture.isRecording || recordingBusy || capture.isSaving)
                HStack { Picker("格式", selection: $format) { Text("MP4").tag("mp4"); Text("GIF").tag("gif") }.frame(width: 140); Spacer(); Button("效果预览") { exportVideo(preview: true) }.disabled(video == nil || exporting || capture.isRecording || recordingBusy || capture.isSaving);  Button(exporting ? "正在导出…" : "导出视频…", systemImage: "square.and.arrow.up") { exportVideo() }.buttonStyle(.borderedProminent).disabled(video == nil || exporting || capture.isRecording || recordingBusy || capture.isSaving) }
                if exporting { VStack(alignment: .leading, spacing: 6) { ProgressView(value: exporter.progress); HStack { Text(exporter.phase); Text(exporter.remaining).foregroundStyle(.secondary); Spacer(); Button("取消导出") { exporter.cancel() } } }.font(.caption) }
                if exporter.canRetry && !exporting { Button("重试上次导出") { exporter.retry() }.disabled(capture.isRecording || recordingBusy) }
                Text(exporter.message.isEmpty ? message : exporter.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
            }.padding(26)
        }.onChange(of: capture.isRecording || capture.isSaving || recordingBusy || exporting, initial: true) { _, busy in AppActivity.shared.busy = busy }
        .onChange(of: message) { _, _ in exporter.clearMessage() }
        .onChange(of: recoveryData) { _, data in
            guard let data else { return }
            do { let url = recoveryURL; try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url, options: .atomic) }
            catch { message = "自动保存编辑参数失败，请手动保存项目：\(error.localizedDescription)" }
        }.onChange(of: camera.error) { _, error in if let error { message = "摄像头异常：\(error)。屏幕录制继续。" } }
        .onChange(of: exporter.completedURL) { _, url in
            guard let url else { return }
            if exporter.completedPreview { player = AVPlayer(url: url); showingEffects = true }
            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }.onChange(of: capture.recoveredURL) { _, url in
            guard let url else { return }
            Task { if webcam { webcamURL = await camera.stop() }; video = url; player = AVPlayer(url: url); showingEffects = false; message = "录制被中断，已保存可恢复的视频。" }
        }.task { capture.refreshDeviceStatus(); restoreRecovery(); if video == nil { message = "选择录制类型，再点击选择按钮。" } }.onReceive(timer) { _ in capture.refreshDeviceStatus(); if capture.isRecording && !capture.isPaused { elapsed += 1 } }
    }
    private var supportsMicrophone: Bool { if #available(macOS 15.0, *) { return true }; return false }
    func selectRecordingSource() async {
        if await capture.selectSource(mode: source) { message = "已选择：\(capture.selectedSourceName)。可以开始录制。" }
    }
    func refresh() async { do { try await capture.refreshSources() } catch { message = error.localizedDescription } }
    func record() async {
        guard !recordingBusy else { return }
        recordingBusy = true; defer { recordingBusy = false }
        if capture.isRecording {
            let saved = await capture.stop()
            if let saved { video = saved }
            if webcam { webcamURL = await camera.stop() }
            if let saved { player = AVPlayer(url: saved); showingEffects = false; message = "录制已保存。设置裁剪、画布和效果，然后导出。" }
            else { message = capture.error ?? "保存失败" }
            return
        }
        if !capture.hasSelectedSource { await selectRecordingSource(); guard capture.hasSelectedSource else { return } }
        do {
            let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("OpenScreenStudio")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("Recording-\(Int(Date().timeIntervalSince1970)).mov")
            webcamURL = nil
            var crop: CGRect? = nil
            if source == "region" { let v = region.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }; guard v.count == 4, v[2] > 0, v[3] > 0 else { throw CaptureFailure.message("区域格式应为 x,y,宽,高，例如 0,0,1280,720。") }; crop = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
            let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard free > 512 * 1024 * 1024 else { throw CaptureFailure.message("可用空间不足 512 MB，请清理磁盘后再录制。") }
            if microphone && !supportsMicrophone { throw CaptureFailure.message("麦克风录制需要 macOS 15+。") }
            if webcam { let cameraFile = destination.deletingPathExtension().appendingPathExtension("camera.mov"); try await camera.start(outputURL: cameraFile); webcamURL = cameraFile }
            let origin = CMClockGetTime(CMClockGetHostTimeClock())
            camera.beginTimeline(at: origin)
            try await capture.start(timelineStart: origin, displayID: displayID == 0 ? nil : displayID, windowID: nil, microphone: microphone, systemAudio: systemAudio, sourceRect: crop, showCursor: cursor, fps: fps, outputURL: destination)
            recordedCursor = cursor; elapsed = 0; message = "正在录制；停止后保存至 Movies/OpenScreenStudio。"
        } catch { if webcam { _ = await camera.stop() }; message = error.localizedDescription }
    }
    private var recoveryURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LuYing/Recovery.ossproject") }
    private var currentProject: StudioProject? {
        guard let video else { return nil }
        return StudioProject(video: video.path, webcam: webcamURL?.path, captions: captionsURL?.path, start: start, end: end, speed: speed, aspect: aspect, padding: padding, zoom: zoom, clicks: clicks, fps: fps, width: outputWidth, background: background, denoise: denoise, music: musicURL?.path, backgroundImage: backgroundImageURL?.path, recordedCursor: recordedCursor)
    }
    private var recoveryData: Data? { currentProject.flatMap { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try? encoder.encode($0) } }
    func restoreRecovery() {
        guard let data = try? Data(contentsOf: recoveryURL), let p = try? JSONDecoder().decode(StudioProject.self, from: data), FileManager.default.fileExists(atPath: p.video) else { return }
        applyProject(p); message = "已恢复上次编辑，原素材保留在原位置。"
    }
    func applyProject(_ p: StudioProject) {
        video = URL(fileURLWithPath: p.video); webcamURL = p.webcam.map { URL(fileURLWithPath: $0) }; captionsURL = p.captions.map { URL(fileURLWithPath: $0) }; start = p.start; end = p.end; speed = p.speed; aspect = p.aspect; padding = p.padding; zoom = p.zoom; clicks = p.clicks; fps = p.fps; outputWidth = p.width; background = p.background; denoise = p.denoise ?? false; recordedCursor = p.recordedCursor ?? true; showingEffects = false; musicURL = p.music.map { URL(fileURLWithPath: $0) }; backgroundImageURL = p.backgroundImage.map { URL(fileURLWithPath: $0) }; player = AVPlayer(url: video!)
    }
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
    func chooseVideo() { if let url = chooseFile(types: ["mov","mp4","m4v"]) { video = url; webcamURL = nil; captionsURL = nil; recordedCursor = true; player = AVPlayer(url: url); showingEffects = false; message = "已导入视频。鼠标自动缩放需要同名 JSON 轨迹文件。" } }
    func exportVideo(preview: Bool = false) {
        guard let video else { return }
        guard let begin = Double(start), begin >= 0, end.isEmpty || (Double(end) != nil && Double(end)! > begin) else { message = "裁剪时间无效：终点必须大于起点。"; return }
        let destination: URL
        if preview { destination = FileManager.default.temporaryDirectory.appendingPathComponent("OpenScreenStudio-preview-\(UUID().uuidString).mp4") }
        else { let panel = NSSavePanel(); panel.nameFieldStringValue = "Studio-export.\(format)"; panel.allowedContentTypes = [UTType(filenameExtension: format)!]; guard panel.runModal() == .OK, let url = panel.url else { return }; destination = url }
        var args = [video.path, destination.path, "--start", start, "--speed", String(speed), "--aspect", aspect, "--padding", String(Int(padding)), "--fps", String(fps), "--cursor-size", recordedCursor ? "0" : "18", "--width", String(preview ? min(outputWidth,960) : outputWidth), "--background", background]
        if preview { args += ["--end", String(min(Double(end) ?? (begin + 8), begin + 8))] } else if !end.isEmpty { args += ["--end",end] }
        let mouse = video.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: mouse.path) { args += ["--mouse",mouse.path]; if !zoom { args += ["--zoom","1"] }; if !clicks { args += ["--no-clicks"] } }
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
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.controlsStyle = .inline; view.player = player; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

struct StudioProject: Codable {
    let video: String; let webcam: String?; let captions: String?
    let start: String; let end: String; let speed: Double; let aspect: String; let padding: Double
    let zoom: Bool; let clicks: Bool; let fps: Int; let width: Int; let background: String; let denoise: Bool?; let music: String?; let backgroundImage: String?; let recordedCursor: Bool?
}
