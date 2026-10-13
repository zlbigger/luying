import AppKit
import AVFoundation
import Combine
import Carbon

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
final class RecordingMenu: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var shortcutStatus = "录制时：⌘⇧P 暂停／继续 · ⌘⇧S 停止并保存"
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var shortcutsActive = false
    private var localKeys: Any?
    private func registerShortcuts() {
        guard !shortcutsActive else { return };shortcutsActive = true
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command,.shift], !event.isARepeat else { return event }
            if event.keyCode == UInt16(kVK_ANSI_P) { self?.pause?();return nil }
            if event.keyCode == UInt16(kVK_ANSI_S) { self?.stop?();return nil }
            return event
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard result == noErr, identity.signature == 0x4C755969 else { return OSStatus(eventNotHandledErr) }
            let menu = Unmanaged<RecordingMenu>.fromOpaque(context).takeUnretainedValue()
            let keyID = identity.id
            Task { @MainActor in
                guard menu.shortcutsActive else { return }
                if keyID == 1 { menu.pause?() } else if keyID == 2 { menu.stop?() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else { shortcutStatus = "快捷键不可用，请使用菜单栏暂停或停止";return }
        var failed = false
        for (key, id) in [(UInt32(kVK_ANSI_P), UInt32(1)), (UInt32(kVK_ANSI_S), UInt32(2))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key, UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x4C755969, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotKeys.append(reference) } else { failed = true }
        }
        shortcutStatus = failed ? "部分快捷键被占用，请使用菜单栏暂停或停止" : "⌘⇧P 暂停／继续 · ⌘⇧S 停止并保存（全局）"
    }
    private func unregisterShortcuts() {
        shortcutsActive = false
        if let localKeys { NSEvent.removeMonitor(localKeys) };localKeys = nil
        hotKeys.forEach { UnregisterEventHotKey($0) };hotKeys.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) };eventHandler = nil
        shortcutStatus = "录制时：⌘⇧P 暂停／继续 · ⌘⇧S 停止并保存"
    }
    private var controls: NSPanel?
    private var displayObserver: NSObjectProtocol?
    private func keepControlsVisible() {
        guard let panel = controls else { return }
        let frame = panel.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) { return }
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x:max(area.minX,min(frame.minX,area.maxX-frame.width)),y:max(area.minY,min(frame.minY,area.maxY-frame.height))))
    }
    func windowDidMove(_ notification: Notification) {
        guard let panel = controls else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin),forKey:"recordingControlsOrigin")
    }
    private let controlTime = NSTextField(labelWithString: "● 00:00")
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let stopButton = NSButton(title: "结束保存", target: nil, action: nil)
    private func updateControls(paused: Bool, seconds: Int) {
        if controls == nil {
            let panel = NSPanel(contentRect: NSRect(x:0,y:0,width:370,height:64),styleMask:[.titled],backing:.buffered,defer:false)
            panel.title = "录制控制 · 录映";panel.level = .floating
            panel.hidesOnDeactivate = false;panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            controlTime.font = .monospacedDigitSystemFont(ofSize:15,weight:.medium)
            pauseButton.target = self;pauseButton.action = #selector(togglePause);pauseButton.bezelStyle = .rounded
            stopButton.target = self;stopButton.action = #selector(finishRecording);stopButton.bezelStyle = .rounded
            stopButton.contentTintColor = .systemRed
            let stack = NSStackView(views:[controlTime,pauseButton,stopButton])
            stack.orientation = .horizontal;stack.spacing = 12;stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView();panel.contentView = content;content.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo:content.centerXAnchor),stack.centerYAnchor.constraint(equalTo:content.centerYAnchor)])
            if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
                let area = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x:area.midX - 185,y:area.maxY - 110))
            } else { panel.center() }
            controls = panel
            if let saved = UserDefaults.standard.string(forKey:"recordingControlsOrigin") { panel.setFrameOrigin(NSPointFromString(saved)) }
            keepControlsVisible();panel.delegate = self
            displayObserver = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.keepControlsVisible() } }
            panel.makeKeyAndOrderFront(nil)
        }
        controlTime.stringValue = (paused ? "已暂停  " : "● ") + String(format:"%02d:%02d",seconds / 60,seconds % 60)
        controlTime.textColor = paused ? .systemOrange : .systemRed
        pauseButton.title = paused ? "继续" : "暂停"
        pauseButton.toolTip = "暂停／继续 · ⌘⇧P";stopButton.toolTip = "结束并保存 · ⌘⇧S"
    }
    private var item: NSStatusItem?
    private var menuState = ""
    var pause: (() -> Void)?
    var stop: (() -> Void)?
    func update(recording: Bool, paused: Bool, seconds: Int, source: String) {
        guard recording else { if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) };displayObserver = nil;controls?.close();controls = nil;pauseButton.isEnabled = true;stopButton.isEnabled = true;if shortcutsActive { unregisterShortcuts() };if let item { NSStatusBar.system.removeStatusItem(item) };item = nil;menuState = "";return }
        registerShortcuts()
        updateControls(paused:paused,seconds:seconds)
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        item?.button?.title = (paused ? "Ⅱ " : "● ") + String(format: "%02d:%02d", seconds / 60, seconds % 60)
        item?.button?.toolTip = "录映 · " + source
        let state = "\(paused):\(source)"
        guard state != menuState else { return };menuState = state
        let menu = NSMenu()
        let label = NSMenuItem(title: source, action: nil, keyEquivalent: "");label.isEnabled = false;menu.addItem(label)
        let toggle = NSMenuItem(title: paused ? "继续录制  ⌘⇧P" : "暂停录制  ⌘⇧P", action: #selector(togglePause), keyEquivalent: "");toggle.target = self;menu.addItem(toggle)
        let finish = NSMenuItem(title: "停止并保存  ⌘⇧S", action: #selector(finishRecording), keyEquivalent: "");finish.target = self;menu.addItem(finish)
        let show = NSMenuItem(title: "显示工作台", action: #selector(showStudio), keyEquivalent: "");show.target = self;menu.addItem(show)
        item?.menu = menu
    }
    @objc private func togglePause() { pause?() }
    @objc private func finishRecording() { pauseButton.isEnabled = false;stopButton.isEnabled = false;stop?() }
    @objc private func showStudio() { NSApp.activate(ignoringOtherApps: true);NSApp.windows.first { $0.identifier?.rawValue == "studio" }?.makeKeyAndOrderFront(nil) }
}

@MainActor
final class RecordingCountdown: NSObject {
    private var panel: NSPanel?
    private var cancelled = false
    @objc func cancel() { cancelled = true;panel?.close() }
    func run(source: String, resuming: Bool = false) async -> Bool {
        cancelled = false
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:420,height:180),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = resuming ? "即将继续 · 录映" : "即将录制 · 录映";window.level = .floating;window.hidesOnDeactivate = false;window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let count = NSTextField(labelWithString:"5");count.font = .systemFont(ofSize:48,weight:.bold)
        let label = NSTextField(wrappingLabelWithString:source);label.alignment = .center
        let button = NSButton(title:resuming ? "保持暂停" : "取消录制",target:self,action:#selector(cancel));button.bezelStyle = .rounded
        let stack = NSStackView(views:[label,count,button]);stack.orientation = .vertical;stack.spacing = 12;stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView();window.contentView = content;content.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo:content.centerXAnchor),stack.centerYAnchor.constraint(equalTo:content.centerYAnchor),label.widthAnchor.constraint(lessThanOrEqualToConstant:390)])
        if let area = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame { window.setFrameOrigin(NSPoint(x:area.midX-210,y:area.midY-90)) } else { window.center() }
        panel = window;window.makeKeyAndOrderFront(nil)
        defer { window.close();panel = nil }
        for second in stride(from:5,through:1,by:-1) {
            guard !cancelled, !Task.isCancelled else { return false }
            count.stringValue = String(second)
            do { try await Task.sleep(nanoseconds:1_000_000_000) } catch { return false }
        }
        return !cancelled && !Task.isCancelled
    }
}
