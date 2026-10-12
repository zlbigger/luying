import SwiftUI
struct RecordingSourceView: View {
    @ObservedObject var capture: CaptureEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认录制来源").font(.title2.bold())
            Text("点击具体显示器／窗口查看预览，再确认。录制目标按固定 ID 锁定，与鼠标或按钮所在屏幕无关。").font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 18) {
                List(capture.sourceChoices) { source in
                    Button { capture.choosePendingSource(source) } label: {
                        HStack { Image(systemName: capture.pendingSourceID == source.id ? "checkmark.circle.fill" : "circle");Text(source.name).lineLimit(3);Spacer() }.padding(.vertical,6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.frame(width: 260,height: 300)
                VStack(spacing:12) {
                    if let preview = capture.sourcePreview { Image(nsImage:preview).resizable().scaledToFit().frame(width:400,height:240) }
                    else { RoundedRectangle(cornerRadius:8).fill(.black.opacity(0.12)).frame(width:400,height:240).overlay(Text("来源预览").foregroundStyle(.secondary)) }
                    Text(capture.previewStatus).font(.caption).foregroundStyle(.secondary).frame(width:400)
                }
            }
            HStack { Button("取消") { capture.cancelSelection() }.keyboardShortcut(.cancelAction);Spacer();Button("确认录制此来源") { capture.confirmSource() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(capture.sourcePreview == nil) }
        }.padding(24).frame(width:720).interactiveDismissDisabled()
    }
}
