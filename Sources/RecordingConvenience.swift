import AppKit
import AVFoundation
import Combine

@MainActor
final class MicrophoneCheck: ObservableObject {
    @Published var level = 0.0
    @Published var status = "说句话，检查麦克风输入"
    private var engine: AVAudioEngine?
    private var generation = UUID()
    private var hasInput = false
    private var began = Date()
    private var heard = Date()
    func start() async {
        stop();let token = generation
        guard await AVCaptureDevice.requestAccess(for: .audio) else { status = "麦克风未授权";return }
        guard token == generation else { return }
        let audio = AVAudioEngine(), input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { status = "没有可用的麦克风输入";return }
        began = Date();heard = began;hasInput = false
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let values = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(values[i])) }
            let meter = Double(peak)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.level = min(1, max(0, (20 * log10(max(meter, 0.00001)) + 60) / 60))
                if meter > 0.005 { self.heard = Date();self.hasInput = true }
                self.status = Date().timeIntervalSince(self.heard) > 5 ? "暂未检测到声音，请检查麦克风" : (self.hasInput ? "麦克风有输入 · 可以开始录制" : "说句话，检查麦克风输入")
            }
        }
        do { try audio.start();engine = audio;status = "说句话，检查麦克风输入" }
        catch { input.removeTap(onBus: 0);status = "麦克风检查失败：\(error.localizedDescription)" }
    }
    func stop() { generation = UUID();engine?.inputNode.removeTap(onBus: 0);engine?.stop();engine = nil;level = 0 }
}

@MainActor
final class RecordingMenu: NSObject {
    private var item: NSStatusItem?
    private var menuState = ""
    var pause: (() -> Void)?
    var stop: (() -> Void)?
    func update(recording: Bool, paused: Bool, seconds: Int, source: String) {
        guard recording else { if let item { NSStatusBar.system.removeStatusItem(item) };item = nil;menuState = "";return }
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        item?.button?.title = (paused ? "Ⅱ " : "● ") + String(format: "%02d:%02d", seconds / 60, seconds % 60)
        item?.button?.toolTip = "录映 · " + source
        let state = "\(paused):\(source)"
        guard state != menuState else { return };menuState = state
        let menu = NSMenu()
        let label = NSMenuItem(title: source, action: nil, keyEquivalent: "");label.isEnabled = false;menu.addItem(label)
        let toggle = NSMenuItem(title: paused ? "继续录制" : "暂停录制", action: #selector(togglePause), keyEquivalent: "");toggle.target = self;menu.addItem(toggle)
        let finish = NSMenuItem(title: "停止并保存", action: #selector(finishRecording), keyEquivalent: "");finish.target = self;menu.addItem(finish)
        let show = NSMenuItem(title: "显示工作台", action: #selector(showStudio), keyEquivalent: "");show.target = self;menu.addItem(show)
        item?.menu = menu
    }
    @objc private func togglePause() { pause?() }
    @objc private func finishRecording() { stop?() }
    @objc private func showStudio() { NSApp.activate(ignoringOtherApps: true);NSApp.windows.first { $0.identifier?.rawValue == "studio" }?.makeKeyAndOrderFront(nil) }
}
