import AppKit
import AVFoundation
import ScreenCaptureKit
import Combine

struct CaptureDisplay: Identifiable { let id: CGDirectDisplayID; let name: String; let width: Int; let height: Int }
struct CaptureWindow: Identifiable { let id: CGWindowID; let name: String; let application: String }
struct CursorSample: Codable { let time: Double; let x: Double; let y: Double; let kind: String }
struct RecordingMetadata: Codable { let width: Int; let height: Int; let fps: Int; let duration: Double; let events: [CursorSample] }

@MainActor
final class CaptureEngine: NSObject, ObservableObject, SCContentSharingPickerObserver {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var isSaving = false
    @Published var isStarting = false
    @Published var error: String?
    @Published var status = "准备录制"
    @Published var displays: [CaptureDisplay] = []
    @Published var windows: [CaptureWindow] = []
    @Published var selectedSourceName = "尚未选择"
    @Published var hasSelectedSource = false
    private var selectedMode = "display"
    private var pickedFilter: SCContentFilter?
    private var pickerCompletion: CheckedContinuation<Bool, Never>?
    private var pickerObserved = false
    private var stream: SCStream?
    private var sink: RecordingSink?
    private var outputURL: URL?
    private var cursorTimer: Timer?
    private var cursorSamples: [CursorSample] = []
    private var startDate: Date?
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var wasMouseDown = false
    private var captureRect = CGRect.zero
    private var width = 0
    private var height = 0
    private var fps = 60

    func selectSource(mode: String = "display") async -> Bool {
        guard !isRecording, pickerCompletion == nil else { return false }
        let picker = SCContentSharingPicker.shared
        if !pickerObserved { picker.add(self); pickerObserved = true }
        var configuration = SCContentSharingPickerConfiguration()
        selectedMode = mode
        configuration.allowedPickerModes = mode == "window" ? [.singleWindow] : [.singleDisplay]
        picker.defaultConfiguration = configuration
        picker.isActive = true
        return await withCheckedContinuation { completion in
            pickerCompletion = completion
            picker.present(using: mode == "window" ? .window : .display)
        }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.pickerCompletion?.resume(returning: false); self.pickerCompletion = nil }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            self.pickedFilter = filter
            self.hasSelectedSource = true
            self.selectedSourceName = self.selectedMode == "window" ? "已选择窗口" : "已选择显示器"
            if #available(macOS 15.2, *) {
                if self.selectedMode == "window", let window = filter.includedWindows.first { self.selectedSourceName = (window.owningApplication?.applicationName ?? "应用") + " — " + (window.title ?? "窗口") }
                else if let display = filter.includedDisplays.first { self.selectedSourceName = "显示器 \(display.displayID) · \(display.width)×\(display.height)" }
            }
            self.status = "已选择系统授权的录制内容"
            self.pickerCompletion?.resume(returning: true); self.pickerCompletion = nil
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.error = error.localizedDescription; self.pickerCompletion?.resume(returning: false); self.pickerCompletion = nil }
    }

    func clearSelectedSource() {
        guard !isRecording else { return }
        pickedFilter = nil; hasSelectedSource = false; selectedSourceName = "尚未选择"
    }
    func refreshSources() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.message("系统尚未允许直接枚举屏幕。请使用「系统选择录制内容」；无需反复打开权限设置。") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        displays = content.displays.map { CaptureDisplay(id: $0.displayID, name: "显示器 \($0.displayID)", width: $0.width, height: $0.height) }
        windows = content.windows.filter { $0.frame.width > 100 && $0.frame.height > 100 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }.map {
            CaptureWindow(id: $0.windowID, name: $0.title ?? "无标题窗口", application: $0.owningApplication?.applicationName ?? "应用")
        }
    }

    func start(displayID: CGDirectDisplayID? = nil, windowID: CGWindowID? = nil, microphone: Bool = false, systemAudio: Bool = true, sourceRect: CGRect? = nil, showCursor: Bool = true, fps: Int = 60, outputURL: URL) async throws {
        guard !isRecording, !isSaving, !isStarting else { throw CaptureFailure.message("录制正在进行或保存，请稍候。") }
        isStarting = true
        defer { isStarting = false }
        error = nil
        status = "正在准备录制…"
        if microphone {
            guard #available(macOS 15.0, *) else { throw CaptureFailure.message("麦克风录制需要 macOS 15 或更新版本。") }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureFailure.message("请在系统设置中允许麦克风访问。") }
        }
        let filter: SCContentFilter
        if let pickedFilter {
            filter = pickedFilter
            captureRect = pickedFilter.contentRect
        } else {
            guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.message("请先点击「系统选择录制内容」选择屏幕或窗口。") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        if let windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureFailure.message("所选窗口已关闭，请重新选择。") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureRect = window.frame
        } else {
            let selectedDisplay = displayID.flatMap { id in content.displays.first(where: { $0.displayID == id }) }
            guard let display = displayID == nil ? content.displays.first : selectedDisplay else { throw CaptureFailure.message("所选显示器不可用，请重新选择。") }
            let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            captureRect = display.frame
        }
        }
        let config = SCStreamConfiguration()
        let scale = filter.pointPixelScale
        var captureSize = filter.contentRect.size
        if let sourceRect {
            guard windowID == nil else { throw CaptureFailure.message("区域录制请选择显示器。") }
            let bounds = CGRect(origin: .zero, size: captureRect.size)
            let crop = sourceRect.intersection(bounds)
            guard !crop.isNull, crop.width >= 2, crop.height >= 2 else { throw CaptureFailure.message("录制区域无效或超出显示器。") }
            config.sourceRect = crop
            captureRect = CGRect(x: captureRect.minX + crop.minX, y: captureRect.minY + crop.minY, width: crop.width, height: crop.height)
            captureSize = crop.size
        }
        width = max(2, Int(captureSize.width * CGFloat(scale)) / 2 * 2)
        height = max(2, Int(captureSize.height * CGFloat(scale)) / 2 * 2)
        self.fps = max(1, min(fps, 60))
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.fps))
        config.showsCursor = showCursor
        config.queueDepth = 6
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        if #available(macOS 15.0, *) { config.captureMicrophone = microphone }
        let recordingSink = try RecordingSink(url: outputURL, width: width, height: height, microphone: microphone)
        let capture = SCStream(filter: filter, configuration: config, delegate: recordingSink)
        try capture.addStreamOutput(recordingSink, type: .screen, sampleHandlerQueue: recordingSink.queue)
        if systemAudio { try capture.addStreamOutput(recordingSink, type: .audio, sampleHandlerQueue: recordingSink.queue) }
        if #available(macOS 15.0, *), microphone { try capture.addStreamOutput(recordingSink, type: .microphone, sampleHandlerQueue: recordingSink.queue) }
        recordingSink.onFailure = { [weak self] message in
            Task { @MainActor in self?.error = message; self?.status = message; _ = await self?.stop() }
        }
        do { try await capture.startCapture() } catch { recordingSink.cancel(); status = "录制启动失败"; throw error }
        self.stream = capture; self.sink = recordingSink; self.outputURL = outputURL
        cursorSamples = []; pausedDuration = 0; pausedAt = nil; isPaused = false; wasMouseDown = false; startDate = Date(); isRecording = true; status = "录制中"
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCursor() }
        }
    }

    func togglePause() {
        guard isRecording, let sink else { return }
        let now = Date()
        isPaused.toggle()
        if isPaused { pausedAt = now }
        else { pausedDuration += now.timeIntervalSince(pausedAt ?? now); pausedAt = nil }
        sink.setPaused(isPaused)
        status = isPaused ? "已暂停" : "录制中"
    }

    private func sampleCursor() {
        guard let startDate, !isPaused else { return }
        let point = NSEvent.mouseLocation
        // AppKit uses bottom-left global coordinates; ScreenCaptureKit uses top-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? captureRect.height
        let x = point.x - captureRect.minX
        let y = primaryHeight - point.y - captureRect.minY
        let mouseDown = NSEvent.pressedMouseButtons != 0
        let kind = mouseDown && !wasMouseDown ? "click" : "move"
        wasMouseDown = mouseDown
        cursorSamples.append(CursorSample(time: max(0, Date().timeIntervalSince(startDate) - pausedDuration), x: x / max(1, captureRect.width), y: y / max(1, captureRect.height), kind: kind))
    }

    func stop() async -> URL? {
        guard let capture = stream, let recordingSink = sink else { return nil }
        let url = outputURL
        let now = Date()
        let duration = max(0, now.timeIntervalSince(startDate ?? now) - pausedDuration - (pausedAt.map { now.timeIntervalSince($0) } ?? 0))
        stream = nil; sink = nil; cursorTimer?.invalidate(); cursorTimer = nil
        isSaving = true
        defer { isSaving = false }
        isRecording = false; isPaused = false; status = "正在保存…"
        do { try await capture.stopCapture() } catch { self.error = error.localizedDescription }
        let success = await recordingSink.finish()
        if success, let url {
            let metadata = RecordingMetadata(width: width, height: height, fps: fps, duration: duration, events: cursorSamples)
            do { try JSONEncoder().encode(metadata).write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic) }
            catch { self.error = "视频已保存，但鼠标轨迹保存失败：\(error.localizedDescription)" }
            status = "录制已保存"
        } else { error = recordingSink.failureMessage ?? "视频保存失败，可能没有收到画面。"; status = error! }
        startDate = nil; outputURL = nil
        return success ? url : nil
    }
}

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

private final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "OpenScreenStudio.recording")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let mic: AVAssetWriterInput?
    private var started = false
    private var firstTime = CMTime.invalid
    private var paused = false
    private var pauseStart = CMTime.zero
    private var timeRemoved = CMTime.zero
    private var resumeBoundary = CMTime.invalid

    func setPaused(_ value: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.sync {
            guard self.paused != value else { return }
            self.paused = value
            if value { self.pauseStart = now }
            else {
                self.timeRemoved = self.timeRemoved + (now - self.pauseStart)
                self.resumeBoundary = now
            }
        }
    }

    private func adjusted(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard timeRemoved > .zero else { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else { return nil }
        var timings = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else { return nil }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid { timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - timeRemoved }
            if timings[index].decodeTimeStamp.isValid { timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - timeRemoved }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }
    var onFailure: (@Sendable (String) -> Void)?
    var failureMessage: String? { writer.error?.localizedDescription }

    init(url: URL, width: Int, height: Int, microphone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, width * height * 6), AVVideoMaxKeyFrameIntervalKey: 60]])
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000]
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        mic = microphone ? AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) : nil
        super.init()
        for input in [video, audio] + (mic.map { [$0] } ?? []) {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureFailure.message("无法创建录制轨道。") }
            writer.add(input)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, !paused else { return }
        if resumeBoundary.isValid, sample.presentationTimeStamp < resumeBoundary { return }
        guard let sample = adjusted(sample) else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                guard writer.startWriting() else { onFailure?(failureMessage ?? "无法启动视频编码。"); return }
                firstTime = sample.presentationTimeStamp
                writer.startSession(atSourceTime: firstTime); started = true
            }
        }
        guard started, sample.presentationTimeStamp >= firstTime, writer.status == .writing else { return }
        let input: AVAssetWriterInput?
        switch type { case .screen: input = video; case .audio: input = audio; default: input = mic }
        if let input, input.isReadyForMoreMediaData, !input.append(sample) { onFailure?(failureMessage ?? "写入视频失败。") }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }
    func cancel() { writer.cancelWriting() }
    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.started, self.writer.status == .writing else { self.writer.cancelWriting(); continuation.resume(returning: false); return }
                self.video.markAsFinished(); self.audio.markAsFinished(); self.mic?.markAsFinished()
                self.writer.finishWriting { continuation.resume(returning: self.writer.status == .completed) }
            }
        }
    }
}
