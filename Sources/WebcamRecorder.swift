@preconcurrency import AVFoundation
import Combine

@MainActor
final class WebcamRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "摄像头待机"
    @Published private(set) var error: String?
    @Published private(set) var session: AVCaptureSession?
    private var previewToken = UUID()
    private var sink: CameraSink?
    private let queue = DispatchQueue(label: "LuYing.camera")
    private var currentURL: URL?

    func startPreview() async {
        guard session == nil, !isRecording else { return }
        previewToken = UUID();let token = previewToken
        error = nil;status = "正在开启摄像头预览…"
        guard await AVCaptureDevice.requestAccess(for: .video) else { error = "摄像头未授权";status = "摄像头未授权";return }
        guard token == previewToken else { return }
        do {
            guard let device = AVCaptureDevice.default(for: .video) else { throw CaptureFailure.message("未找到摄像头") }
            let input = try AVCaptureDeviceInput(device: device), capture = AVCaptureSession()
            capture.beginConfiguration()
            if capture.canSetSessionPreset(.hd1280x720) { capture.sessionPreset = .hd1280x720 }
            guard capture.canAddInput(input) else { capture.commitConfiguration();throw CaptureFailure.message("无法开启摄像头") }
            capture.addInput(input);capture.commitConfiguration()
            await withCheckedContinuation { (c: CheckedContinuation<Void,Never>) in queue.async { capture.startRunning();c.resume() } }
            guard token == previewToken else { queue.async { capture.stopRunning() };return }
            guard capture.isRunning else { throw CaptureFailure.message("摄像头启动失败") }
            session = capture;status = "摄像头预览 · 尚未录制"
        } catch { self.error = error.localizedDescription;status = "摄像头预览失败" }
    }
    func stopPreview() async {
        previewToken = UUID()
        guard !isRecording, let capture = session else { return }
        session = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void,Never>) in queue.async { capture.stopRunning();c.resume() } }
        status = "摄像头已关闭"
    }
    func start(outputURL: URL) async throws {
        await stopPreview()
        guard session == nil else { throw CaptureFailure.message("摄像头正在录制或保存。") }
        error = nil; status = "正在准备摄像头…"
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CaptureFailure.message("请在系统设置 → 隐私与安全性 → 摄像头中允许录映。") }
        guard let device = AVCaptureDevice.default(for: .video) else { throw CaptureFailure.message("未找到摄像头。") }
        let input = try AVCaptureDeviceInput(device: device)
        let capture = AVCaptureSession(), output = AVCaptureVideoDataOutput()
        capture.beginConfiguration()
        if capture.canSetSessionPreset(.hd1280x720) { capture.sessionPreset = .hd1280x720 }
        guard capture.canAddInput(input), capture.canAddOutput(output) else { capture.commitConfiguration(); throw CaptureFailure.message("无法配置摄像头。") }
        capture.addInput(input); capture.addOutput(output); capture.commitConfiguration()
        output.alwaysDiscardsLateVideoFrames = true
        let writer = CameraSink(url: outputURL)
        writer.onFailure = { [weak self] text in Task { @MainActor in self?.error = text; self?.status = "摄像头录制异常" } }
        output.setSampleBufferDelegate(writer, queue: queue)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in queue.async { capture.startRunning(); continuation.resume() } }
        guard capture.isRunning else { throw CaptureFailure.message("摄像头启动失败，可能被其他应用占用。") }
        session = capture; sink = writer; currentURL = outputURL; isRecording = true; status = "摄像头录制中"
    }
    func beginTimeline(at time: CMTime) { queue.sync { sink?.origin = time } }
    func setPaused(_ paused: Bool, at time: CMTime) { queue.sync { sink?.setPaused(paused, at: time) }; status = paused ? "摄像头已暂停" : "摄像头录制中" }
    func stop() async -> URL? {
        guard let session, let sink else { return nil }
        let url = currentURL; self.session = nil; self.sink = nil; currentURL = nil; isRecording = false; status = "正在保存摄像头…"
        let success = await withCheckedContinuation { continuation in queue.async { session.stopRunning(); sink.finish { continuation.resume(returning: $0) } } }
        status = success ? "摄像头已保存" : "摄像头没有可用画面"
        return success ? url : nil
    }
}

private final class CameraSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var origin = CMTime.invalid
    var onFailure: (@Sendable (String) -> Void)?
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var paused = false, failed = false
    private var pauseStart = CMTime.zero, removed = CMTime.zero, boundary = CMTime.invalid
    init(url: URL) { self.url = url }
    func setPaused(_ value: Bool, at time: CMTime) {
        guard paused != value else { return }; paused = value
        if value { pauseStart = time } else { removed = removed + (time - pauseStart); boundary = time }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, !failed, origin.isValid, sample.isValid, sample.presentationTimeStamp >= origin else { return }
        if boundary.isValid, sample.presentationTimeStamp < boundary { return }
        guard let adjusted = removingPausedTime(sample, offset: removed) else { return }
        do {
            if writer == nil {
                guard let description = sample.formatDescription else { return }
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(dimensions.width), AVVideoHeightKey: Int(dimensions.height)])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw CaptureFailure.message("无法创建摄像头编码轨道。") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? CaptureFailure.message("摄像头编码启动失败。") }
                writer.startSession(atSourceTime: origin); self.writer = writer; self.input = input
            }
            if let input, input.isReadyForMoreMediaData, !input.append(adjusted) { throw writer?.error ?? CaptureFailure.message("摄像头写入失败。") }
        } catch { failed = true; onFailure?(error.localizedDescription) }
    }
    func finish(completion: @escaping @Sendable (Bool) -> Void) {
        guard let writer, writer.status == .writing else { writer?.cancelWriting(); completion(false); return }
        input?.markAsFinished(); writer.finishWriting { completion(self.writer?.status == .completed) }
    }
}
