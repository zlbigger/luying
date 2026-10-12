import AppKit

@MainActor
final class AppActivity {
    static let shared = AppActivity()
    var busy = false
}
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppActivity.shared.busy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "录映正在录制、保存或导出"
        alert.informativeText = "请先停止录制或取消导出，等待保存完成后再退出，以保留素材。"
        alert.addButton(withTitle: "返回录映"); alert.runModal()
        return .terminateCancel
    }
}
