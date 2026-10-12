import SwiftUI
import AVFoundation
import AppKit

final class CameraLayerView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) { super.init(frame: frame);wantsLayer = true;preview.videoGravity = .resizeAspect;layer?.addSublayer(preview) }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout();preview.frame = bounds }
}
struct CameraLiveView: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraLayerView { let v = CameraLayerView(frame: .zero);v.preview.session = session;return v }
    func updateNSView(_ view: CameraLayerView, context: Context) { view.preview.session = session }
}
struct CameraPreviewContent: View {
    @ObservedObject var camera: WebcamRecorder
    var body: some View {
        VStack(spacing: 6) {
            if let session = camera.session { CameraLiveView(session: session).frame(width: 288,height: 162) }
            else { Text(camera.error ?? "正在准备摄像头…").font(.caption).frame(width:288,height:162).background(.black) }
            Text(camera.status).font(.caption).foregroundStyle(camera.isRecording ? .red : .secondary)
            Text("关闭此预览窗口不会停止摄像头录制").font(.caption2).foregroundStyle(.secondary)
        }.padding(8)
    }
}
@MainActor
final class CameraPreviewPanel {
    private var panel: NSPanel?
    func show(camera: WebcamRecorder) {
        if let panel { panel.makeKeyAndOrderFront(nil);return }
        let host = NSHostingController(rootView: CameraPreviewContent(camera:camera))
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:304,height:220),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "摄像头 · 录映";window.contentViewController = host;window.level = .floating
        window.hidesOnDeactivate = false;window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x:area.maxX - 324,y:area.minY + 24))
        } else { window.center() }
        window.makeKeyAndOrderFront(nil);panel = window
    }
    func close() { panel?.close();panel = nil }
}
