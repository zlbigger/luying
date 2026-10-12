import Foundation
import Combine

@MainActor
final class ExportController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var phase = ""
    @Published private(set) var remaining = ""
    @Published private(set) var message = ""
    @Published private(set) var completedURL: URL?
    @Published private(set) var completedPreview = false
    @Published private(set) var canRetry = false
    private var process: Process?
    private var cancelled = false
    private var lastJob: (args: [String], destination: URL, preview: Bool)?
    private var encodingStarted: Date?

    func start(args: [String], destination: URL, preview: Bool) {
        guard !isRunning else { return }
        lastJob = (args, destination, preview)
        guard let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools"),
              FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("exporter/exporter").path) else {
            message = "安装包缺少导出组件，请重新安装完整版。"; canRetry = false; return
        }
        isRunning = true; progress = 0; phase = "正在准备素材…"; remaining = ""; message = ""; completedURL = nil; cancelled = false; canRetry = false; encodingStarted = nil
        let child = Process()
        child.executableURL = tools.appendingPathComponent("exporter/exporter")
        child.arguments = args + ["--ffmpeg", tools.appendingPathComponent("ffmpeg").path, "--subtitle-renderer", tools.appendingPathComponent("subtitles").path, "--encoder", "h264_videotoolbox"]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
        process = child
        do { try child.run() } catch { isRunning = false; process = nil; canRetry = true; message = "无法启动导出：\(error.localizedDescription)"; return }
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data(), diagnostic = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(data: pending.prefix(upTo: newline), encoding: .utf8) ?? ""
                    pending.removeSubrange(...newline)
                    if let bytes = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], json["luying"] as? Bool == true {
                        let state = json["phase"] as? String ?? ""
                        let value = json["progress"] as? Double ?? 0
                        Task { @MainActor in self.update(phase: state, value: value) }
                    } else { diagnostic = String((diagnostic + "\n" + line).suffix(2000)) }
                }
            }
            child.waitUntilExit()
            let details = String((diagnostic + (String(data: pending, encoding: .utf8) ?? "")).suffix(1200))
            Task { @MainActor in
                self.isRunning = false; self.process = nil; self.remaining = ""
                if self.cancelled || child.terminationStatus == 130 { self.phase = "已取消"; self.message = "已取消导出，原素材和已有成片保留。"; self.canRetry = true }
                else if child.terminationStatus == 0 { self.progress = 1; self.phase = "导出完成"; self.message = "导出完成：\(destination.lastPathComponent)"; self.completedPreview = preview; self.completedURL = destination }
                else { self.phase = "导出失败"; self.message = "导出失败，素材和编辑参数保留，可重试。\n\(details)"; self.canRetry = true }
            }
        }
    }
    private func update(phase: String, value: Double) {
        guard isRunning, !cancelled else { return }
        if phase == "encoding" {
            if encodingStarted == nil { encodingStarted = Date() }
            progress = max(progress, min(0.99, value)); self.phase = "正在编码 · \(Int(progress * 100))%"
            if progress > 0.03, let encodingStarted {
                let elapsed = Date().timeIntervalSince(encodingStarted)
                if elapsed > 2 { let seconds = Int(elapsed / progress * (1-progress)); remaining = seconds >= 60 ? "预计剩余 \(seconds/60) 分 \(seconds%60) 秒" : "预计剩余 \(seconds) 秒" }
            }
        } else if phase == "completed" { self.phase = "正在验证成片…" }
    }
    func clearMessage() { if !isRunning { message = "" } }
    func cancel() { guard isRunning, !cancelled else { return }; cancelled = true; phase = "正在取消…"; process?.interrupt() }
    func retry() { if let job = lastJob { start(args: job.args, destination: job.destination, preview: job.preview) } }
}
