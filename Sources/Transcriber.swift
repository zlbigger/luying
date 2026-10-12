@preconcurrency import AVFoundation
@preconcurrency import Speech
import Combine

@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var status = "字幕待生成"

    func transcribe(video: URL, locale: String = "zh-CN") async throws -> URL {
        guard !isWorking else { throw TranscriptionFailure.message("正在生成字幕，请等待当前任务完成。") }
        isWorking = true
        status = "正在准备本机语音识别…"
        defer { isWorking = false }
        do {
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard authorization == .authorized else {
                throw TranscriptionFailure.message("请在系统设置 → 隐私与安全性 → 语音识别中允许访问。")
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.supportsOnDeviceRecognition else {
                throw TranscriptionFailure.message("当前系统不支持该语言的本机语音识别。请安装对应语言资源或选择其他语言。")
            }
            guard recognizer.isAvailable else {
                throw TranscriptionFailure.message("本机语音识别当前不可用，请确认该语言的识别资源已安装后重试。")
            }
            let asset = AVURLAsset(url: video)
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw TranscriptionFailure.message("视频没有音轨，无法生成字幕。")
            }
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("OpenScreenStudio-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw TranscriptionFailure.message("无法提取音轨。")
            }
            exporter.outputURL = temporaryURL
            exporter.outputFileType = .m4a
            status = "正在提取音轨…"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously { continuation.resume() }
            }
            guard exporter.status == .completed else {
                throw exporter.error ?? TranscriptionFailure.message("音轨提取失败。")
            }
            try Task.checkCancellation()
            status = "正在本机识别语音…"
            let request = SFSpeechURLRecognitionRequest(url: temporaryURL)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            let transcription = try await SpeechRecognitionOperation().run(recognizer: recognizer, request: request)
            guard !transcription.segments.isEmpty else { throw TranscriptionFailure.message("没有识别到语音。") }
            let subtitleURL = video.deletingPathExtension().appendingPathExtension("srt")
            try Self.srt(transcription).write(to: subtitleURL, atomically: true, encoding: .utf8)
            status = "字幕已保存"
            return subtitleURL
        } catch {
            status = "字幕生成失败：\(error.localizedDescription)"
            throw error
        }
    }

    private static func srt(_ transcription: SFTranscription) -> String {
        var cues: [(Double, Double, String)] = []
        var words: [String] = []
        var beginning = 0.0
        var ending = 0.0
        func flush() {
            guard !words.isEmpty else { return }
            // Recognition segments retain each language's word-level whitespace imperfectly;
            // avoid inserted spaces between Chinese characters while separating Latin words.
            var sentence = ""
            for word in words {
                if let previous = sentence.unicodeScalars.last, let first = word.unicodeScalars.first,
                   previous.isASCII && first.isASCII && CharacterSet.alphanumerics.contains(previous) && CharacterSet.alphanumerics.contains(first) {
                    sentence += " "
                }
                sentence += word
            }
            cues.append((beginning, max(beginning + 0.3, ending), sentence))
            words.removeAll()
        }
        for segment in transcription.segments {
            if !words.isEmpty && (segment.timestamp - ending > 0.65 || segment.timestamp - beginning > 4 || words.joined().count + segment.substring.count > 40) { flush() }
            if words.isEmpty { beginning = segment.timestamp }
            words.append(segment.substring)
            ending = segment.timestamp + segment.duration
            if segment.substring.last.map({ "。！？.!?".contains($0) }) == true { flush() }
        }
        flush()
        return cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.0)) --> \(timestamp(cue.1))\n\(cue.2)\n"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

/// Synchronizes callback, cancellation, and timeout completion exactly once.
private final class SpeechRecognitionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SFTranscription, Error>?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    func run(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest) async throws -> SFTranscription {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if completed {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()
                let task = recognizer.recognitionTask(with: request) { [self] result, error in
                    if let result, result.isFinal { finish(.success(result.bestTranscription)) }
                    else if let error { finish(.failure(error)) }
                }
                lock.lock()
                let alreadyCompleted = completed
                if !alreadyCompleted { recognitionTask = task }
                lock.unlock()
                if alreadyCompleted { task.cancel(); return }
                let timeout = Task { [self] in
                    do { try await Task.sleep(nanoseconds: 180_000_000_000) }
                    catch { return }
                    finish(.failure(TranscriptionFailure.message("本机语音识别超过 180 秒，请缩短视频后重试。")))
                }
                lock.lock()
                if completed { lock.unlock(); timeout.cancel() }
                else { timeoutTask = timeout; lock.unlock() }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<SFTranscription, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let pending = continuation
        let task = recognitionTask
        let timeout = timeoutTask
        continuation = nil
        recognitionTask = nil
        timeoutTask = nil
        lock.unlock()
        timeout?.cancel()
        task?.cancel()
        pending?.resume(with: result)
    }
}

private enum TranscriptionFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
