import AppKit

@MainActor
final class RegionSelection {
    private var window: NSWindow?
    private var completion: CheckedContinuation<CGRect?, Never>?
    func choose(displayID: CGDirectDisplayID) async -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else { return nil }
        let panel = RegionSelectionWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        panel.level = .screenSaver;panel.isOpaque = false;panel.backgroundColor = .clear;panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let view = RegionSelectionView(frame:NSRect(origin:.zero,size:screen.frame.size))
        view.done = { [weak self] rect in self?.finish(rect) }
        panel.contentView = view;window = panel
        return await withCheckedContinuation { completion = $0;panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(view) }
    }
    private func finish(_ rect: CGRect?) { window?.close();window = nil;completion?.resume(returning:rect);completion = nil }
}
private final class RegionSelectionView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var done: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var selection = CGRect.zero
    private let confirm = NSButton(title:"确认录制此区域",target:nil,action:nil)
    private let cancel = NSButton(title:"取消",target:nil,action:nil)
    override init(frame:NSRect) {
        super.init(frame:frame)
        confirm.target = self;confirm.action = #selector(accept);confirm.bezelStyle = .rounded;confirm.isEnabled = false
        cancel.target = self;cancel.action = #selector(reject);cancel.bezelStyle = .rounded
        addSubview(confirm);addSubview(cancel)
        confirm.frame = NSRect(x:bounds.midX-140,y:60,width:180,height:36);cancel.frame = NSRect(x:bounds.midX+48,y:60,width:90,height:36)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill();bounds.fill()
        if !selection.isEmpty {
            NSColor.clear.setFill();selection.fill(using:.copy)
            NSColor.systemPurple.setStroke();let border = NSBezierPath(rect:selection);border.lineWidth = 3;border.stroke()
        }
        let text = selection.isEmpty ? "拖动鼠标框选录制区域 · Esc 取消" : "已选择 \(Int(selection.width)) × \(Int(selection.height)) · 可重新拖动 · 回车确认"
        (text as NSString).draw(at:NSPoint(x:bounds.midX-210,y:28),withAttributes:[.font:NSFont.systemFont(ofSize:16,weight:.semibold),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent) { start = convert(event.locationInWindow,from:nil);selection = .zero;confirm.isEnabled = false;needsDisplay = true }
    override func mouseDragged(with event:NSEvent) {
        guard let start else { return };let end = convert(event.locationInWindow,from:nil)
        selection = CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y)).intersection(bounds)
        confirm.isEnabled = selection.width>=32 && selection.height>=32;needsDisplay = true
    }
    override func keyDown(with event:NSEvent) { if event.keyCode == 53 { reject() } else if event.keyCode == 36 { accept() } else { super.keyDown(with:event) } }
    @objc private func accept() { guard confirm.isEnabled else { return };done?(selection.integral) }
    @objc private func reject() { done?(nil) }
}

private final class RegionSelectionWindow: NSWindow { override var canBecomeKey: Bool { true };override var canBecomeMain: Bool { true } }
