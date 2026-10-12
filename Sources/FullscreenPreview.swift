import SwiftUI
import AVKit

@MainActor
final class LargePreviewModel: ObservableObject {
    @Published var player: AVPlayer?
    private var original: AVPlayer?
    func prepare(player: AVPlayer) {
        guard let item = player.currentItem else { return }
        let expanded = AVPlayer(playerItem: AVPlayerItem(asset: item.asset))
        player.pause()
        expanded.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        original = player;self.player = expanded
        expanded.play()
    }
    func syncBack() {
        if let player { original?.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero);player.pause() }
    }
}
struct LargePreviewView: View {
    @EnvironmentObject var preview: LargePreviewModel
    var body: some View {
        Group {
            if let player = preview.player { VideoPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Text("先在工作台选择素材，再点击放大预览").foregroundStyle(.secondary) }
        }.frame(minWidth: 640, minHeight: 360).background(.black).onDisappear { preview.syncBack() }
        .toolbar {
            Button("全屏", systemImage: "arrow.up.left.and.arrow.down.right") {
                if let window = NSApp.keyWindow { window.collectionBehavior.insert(.fullScreenPrimary);window.toggleFullScreen(nil) }
            }.help("切换全屏，Esc 退出全屏")
        }
    }
}
