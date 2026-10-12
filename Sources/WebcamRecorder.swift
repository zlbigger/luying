@preconcurrency import AVFoundation
import Combine

/// Records a silent camera sidecar for compositing into the screen recording.
@MainActor
final class WebcamRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "摄像头待机"
    @Published private(set) var error: String?

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "OpenScreenStudio.webcam")
    private var configured = false
    private var preparing = false
    private var currentURL: URL?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuations: [CheckedContinuation<URL?, Never>] = []

    func start(outputURL: URL) async throws {
        guard !isRecording, !preparing, currentURL == nil else {
            throw WebcamFailure.message("摄像头正在录制或保存。")
        }
        preparing = true
        error = nil
        status = "正在准备摄像头…"
        defer { preparing = false }
        do {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw WebcamFailure.message("请在系统设置 → 隐私与安全性 → 摄像头中允许访问。")
            }
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw WebcamFailure.message("摄像头输出文件已存在，请选择新的文件名。")
            }
            if !configured {
                guard let camera = AVCaptureDevice.default(for: .video) else {
                    throw WebcamFailure.message("未找到摄像头。")
                }
                let input = try AVCaptureDeviceInput(device: camera)
                session.beginConfiguration()
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                guard session.canAddInput(input), session.canAddOutput(movieOutput) else {
                    session.commitConfiguration()
                    throw WebcamFailure.message("无法配置摄像头录制。")
                }
                session.addInput(input)
                session.addOutput(movieOutput)
                session.commitConfiguration()
                configured = true
            }
            let captureSession = session
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sessionQueue.async {
                    captureSession.startRunning()
                    continuation.resume()
                }
            }
            guard session.isRunning else { throw WebcamFailure.message("摄像头启动失败，可能正在被其他应用使用。") }
            currentURL = outputURL
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                movieOutput.startRecording(to: outputURL, recordingDelegate: self)
            }
        } catch {
            self.error = error.localizedDescription
            status = "摄像头启动失败"
            if currentURL == nil { stopSession() }
            throw error
        }
    }

    /// Waits until the movie is finalized before returning a usable sidecar URL.
    func stop() async -> URL? {
        guard currentURL != nil else { return nil }
        status = "正在保存摄像头…"
        return await withCheckedContinuation { continuation in
            stopContinuations.append(continuation)
            if movieOutput.isRecording { movieOutput.stopRecording() }
        }
    }

    private func stopSession() {
        let captureSession = session
        sessionQueue.async { if captureSession.isRunning { captureSession.stopRunning() } }
    }

    private func recordingStarted() {
        isRecording = true
        status = "摄像头录制中"
        startContinuation?.resume()
        startContinuation = nil
        // A stop request may arrive while AVCaptureMovieFileOutput is starting.
        if !stopContinuations.isEmpty { movieOutput.stopRecording() }
    }

    private func recordingFinished(url: URL, failure: Error?) {
        let nsError = failure as NSError?
        let successful = failure == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        let valid = successful && FileManager.default.fileExists(atPath: url.path)
        if let continuation = startContinuation {
            continuation.resume(throwing: failure ?? WebcamFailure.message("摄像头在开始录制前停止。"))
            startContinuation = nil
        }
        isRecording = false
        currentURL = nil
        stopSession()
        if valid {
            status = "摄像头录制已保存"
        } else {
            error = failure?.localizedDescription ?? "摄像头视频保存失败。"
            status = "摄像头保存失败"
        }
        let waiting = stopContinuations
        stopContinuations.removeAll()
        for continuation in waiting { continuation.resume(returning: valid ? url : nil) }
    }
}

extension WebcamRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor [weak self] in self?.recordingStarted() }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor [weak self] in self?.recordingFinished(url: outputFileURL, failure: error) }
    }
}

private enum WebcamFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
