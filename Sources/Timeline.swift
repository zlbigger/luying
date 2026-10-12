import SwiftUI
import AVFoundation
import Combine

struct CutRange: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
}
struct ZoomScene: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var x: Double
    var y: Double
    var factor: Double
}
struct TimelineEdit: Codable, Equatable {
    var start: Double = 0
    var end: Double = 0
    var cuts: [CutRange] = []
    var scenes: [ZoomScene] = []
    var customZoom = false
}
struct TraceFile: Decodable { let events: [TraceEvent] }
struct TraceEvent: Decodable { let time: Double; let x: Double; let y: Double; let kind: String }

@MainActor
final class TimelineModel: ObservableObject {
    @Published private(set) var edit = TimelineEdit()
    @Published private(set) var duration = 0.0
    @Published private(set) var waveform: [Double] = []
    @Published private(set) var loading = false
    @Published private(set) var waveformMessage = ""
    @Published var selectionStart = 0.0
    @Published var selectionEnd = 0.0
    @Published var playhead = 0.0
    @Published var selectedZoom: UUID?
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private var undoStack: [TimelineEdit] = []
    private var redoStack: [TimelineEdit] = []
    private var traces: [TraceEvent] = []
    private var loadTask: Task<Void, Never>?
    private var token = UUID()
    private var gestureBefore: TimelineEdit?
    private var observation: Any?
    private weak var observedPlayer: AVPlayer?
    private var url: URL?

    var keptDuration: Double {
        guard edit.end > edit.start else { return 0 }
        return max(0, edit.end-edit.start-edit.cuts.reduce(0) { total, cut in total+max(0,min(edit.end,cut.end)-max(edit.start,cut.start)) })
    }
    func load(_ url: URL, saved: TimelineEdit? = nil) {
        loadTask?.cancel(); token = UUID(); let current = token
        self.url = url; duration = 0; waveform = []; loading = true; waveformMessage = "正在读取音频波形…"
        edit = saved ?? TimelineEdit(); undoStack = []; redoStack = []; counts(); traces = []; selectedZoom = nil; gestureBefore = nil
        loadTask = Task {
            do {
                let asset = AVURLAsset(url: url)
                let length = CMTimeGetSeconds(try await asset.load(.duration))
                guard !Task.isCancelled, token == current, length.isFinite, length > 0 else { return }
                duration = length
                var initial = saved ?? TimelineEdit(start: 0, end: length)
                initial.start = max(0,min(initial.start,length-0.001));initial.end = max(initial.start+0.001,min(initial.end == 0 ? length : initial.end,length))
                initial.cuts = normalized(initial.cuts, duration: length)
                initial.scenes = normalizedScenes(initial.scenes, duration: length)
                if let data = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")), let trace = try? JSONDecoder().decode(TraceFile.self, from: data) { traces = trace.events.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.time<$1.time } }
                if !initial.customZoom { initial.scenes = automaticScenes() }
                edit = initial; loading = false; selectionStart = initial.start; selectionEnd = min(initial.end,initial.start+min(2,length)); playhead = initial.start
                let peaks = try await Self.readWaveform(asset: asset, duration: length)
                guard !Task.isCancelled, token == current else { return }
                waveform = peaks; waveformMessage = peaks.isEmpty ? "此素材没有音轨" : "音频波形 · 第一音轨"
                loading = false
            } catch {
                guard !Task.isCancelled, token == current else { return };loading = false;waveformMessage = "波形不可用，仍可剪辑：\(error.localizedDescription)"
            }
        }
    }
    private nonisolated static func readWaveform(asset: AVAsset, duration: Double) async throws -> [Double] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return [] }
        let work = Task<[Double], Error>.detached(priority: .utility) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] };reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CaptureFailure.message("无法读取音频") }
            var peaks = [Double](repeating: 0, count: 600)
            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); return [] }
                guard let block = sample.dataBuffer, let format = sample.formatDescription,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
                let channels = max(1,Int(asbd.mChannelsPerFrame));let rate = asbd.mSampleRate
                guard rate>0 else { continue }
                var pointer: UnsafeMutablePointer<Int8>?, size = 0
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &size, dataPointerOut: &pointer) == noErr, let pointer else { continue }
                let time = CMTimeGetSeconds(sample.presentationTimeStamp)
                pointer.withMemoryRebound(to: Float.self, capacity: size/4) { values in
                    for n in stride(from: 0, to: size/4, by: max(channels,channels*8)) {
                        let index = Int((time+Double(n/channels)/rate)/duration*600)
                        if (0..<600).contains(index) { let value = Double(abs(values[n]));if value.isFinite { peaks[index] = max(peaks[index],min(1,value)) } }
                    }
                }
            }
            if reader.status == .failed { throw reader.error ?? CaptureFailure.message("音频读取失败") }
            return peaks
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
    func observe(_ player: AVPlayer?, source: Bool) {
        if let observation, let observedPlayer { observedPlayer.removeTimeObserver(observation) }
        observation = nil; observedPlayer = player
        guard let player, source else { return }
        observation = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in let seconds = CMTimeGetSeconds(time);if seconds.isFinite { self?.playhead = seconds } }
        }
    }
    func beginGesture() { if gestureBefore == nil { gestureBefore = edit } }
    func endGesture() { if let before = gestureBefore, before != edit { remember(before) };gestureBefore = nil }
    func setTrim(_ value: Double, start: Bool, dragging: Bool = false) {
        if dragging { beginGesture() }
        let before = edit
        if start { edit.start = max(0,min(value,edit.end-0.05)) } else { edit.end = min(duration,max(value,edit.start+0.05)) }
        if !dragging && before != edit { remember(before) }
    }
    func setSelection(_ value: Double, start: Bool) {
        let value=max(0,min(duration,value))
        if start { selectionStart=min(duration-0.05,value);if selectionEnd<=selectionStart { selectionEnd=min(duration,selectionStart+0.5) } }
        else { selectionEnd=max(0.05,value);if selectionStart>=selectionEnd { selectionStart=max(0,selectionEnd-0.5) } }
    }
    @discardableResult func deleteSelection() -> Bool {
        let lo = max(edit.start,selectionStart),hi = min(edit.end,selectionEnd)
        guard hi-lo >= 0.05 else { return false }
        let before = edit
        edit.cuts = normalized(edit.cuts+[CutRange(start: lo,end: hi)],duration: duration)
        if keptDuration < 0.05 || edit.cuts.count>=100 { edit = before;return false }
        remember(before);return true
    }
    func removeCut(_ id: UUID) { let before = edit;edit.cuts.removeAll { $0.id==id };remember(before) }
    func resetCuts() { let before = edit;edit.start = 0;edit.end = duration;edit.cuts = [];remember(before) }
    func undo() { guard let previous = undoStack.popLast() else { return };redoStack.append(edit);edit = previous;counts() }
    func redo() { guard let next = redoStack.popLast() else { return };undoStack.append(edit);edit = next;counts() }
    private func remember(_ before: TimelineEdit) { guard before != edit else { return };undoStack.append(before);if undoStack.count>100 { undoStack.removeFirst() };redoStack=[];counts() }
    private func counts() { undoCount = undoStack.count;redoCount = redoStack.count }
    func automaticScenes() -> [ZoomScene] {
        let clicks = traces.filter { $0.kind=="click" && $0.time>=0 && $0.time<duration }.prefix(80)
        var groups: [(first: Double,last: Double,x: Double,y: Double,count: Double)] = []
        for e in clicks {
            if let previous = groups.last, e.time <= previous.last+1.2, hypot(e.x-previous.x,e.y-previous.y)<=0.25 {
                var g = groups.removeLast();g.last=e.time;g.count+=1;g.x+=(e.x-g.x)/g.count;g.y+=(e.y-g.y)/g.count;groups.append(g)
            } else { groups.append((e.time,e.time,e.x,e.y,1)) }
        }
        var scenes: [ZoomScene] = []
        for g in groups {
            var begin = max(0,g.first-0.35);let end = min(duration,g.last+1.2)
            if let previous = scenes.last, begin<previous.end { let boundary = (begin+previous.end)/2;scenes[scenes.count-1].end=boundary;begin=boundary }
            if end>begin { scenes.append(ZoomScene(start: begin,end: end,x: max(0,min(1,g.x)),y: max(0,min(1,g.y)),factor: 1.65)) }
        }
        return scenes
    }
    func resetZoom() { let before = edit;edit.customZoom=false;edit.scenes=automaticScenes();selectedZoom=nil;remember(before) }
    @discardableResult func addZoom() -> Bool {
        let lo=max(edit.start,selectionStart),hi=min(edit.end,selectionEnd)
        guard hi-lo>=0.1, edit.scenes.count<80, !edit.scenes.contains(where: { $0.start<hi && $0.end>lo }) else { return false }
        let before = edit;let scene=ZoomScene(start:lo,end:hi,x:0.5,y:0.5,factor:1.65)
        edit.scenes.append(scene);edit.scenes.sort { $0.start<$1.start };edit.customZoom=true;selectedZoom=scene.id;remember(before);return true
    }
    func updateZoom(_ scene: ZoomScene, dragging: Bool = false) {
        guard let index = edit.scenes.firstIndex(where: { $0.id==scene.id }) else { return }
        var scene = scene
        let lower = index==0 ? 0 : edit.scenes[index-1].end
        let upper = index+1==edit.scenes.count ? duration : edit.scenes[index+1].start
        scene.start = max(lower,min(scene.start,upper-0.05));scene.end=max(scene.start+0.05,min(scene.end,upper))
        scene.x=max(0,min(1,scene.x));scene.y=max(0,min(1,scene.y));scene.factor=max(1,min(4,scene.factor))
        if dragging { beginGesture() };let before=edit;edit.scenes[index]=scene;edit.customZoom=true;if !dragging { remember(before) }
    }
    func deleteZoom() { guard let selectedZoom else { return };let before=edit;edit.scenes.removeAll { $0.id==selectedZoom };edit.customZoom=true;self.selectedZoom=nil;remember(before) }
    private func normalized(_ cuts: [CutRange], duration: Double) -> [CutRange] {
        var result: [CutRange] = []
        for var cut in cuts.sorted(by: { $0.start<$1.start }) {
            guard cut.start.isFinite, cut.end.isFinite else { continue };cut.start=max(0,cut.start);cut.end=min(duration,cut.end);guard cut.end>cut.start else { continue }
            if let last=result.last, cut.start<=last.end { result[result.count-1].end=max(last.end,cut.end) } else { result.append(cut) }
        }
        return result
    }
    private func normalizedScenes(_ scenes: [ZoomScene], duration: Double) -> [ZoomScene] {
        var result: [ZoomScene]=[]
        for var scene in scenes.sorted(by: { $0.start<$1.start }).prefix(80) {
            guard [scene.start,scene.end,scene.x,scene.y,scene.factor].allSatisfy(\.isFinite) else { continue }
            scene.start=max(result.last?.end ?? 0,scene.start);scene.end=min(duration,scene.end)
            guard scene.end>scene.start else { continue };scene.x=max(0,min(1,scene.x));scene.y=max(0,min(1,scene.y));scene.factor=max(1,min(4,scene.factor));result.append(scene)
        }
        return result
    }
}

struct TimelineView: View {
    @ObservedObject var model: TimelineModel
    let speed: Double
    let video: URL?
    let mode: String
    let seek: (Double) -> Void
    let notify: (String) -> Void
    @State private var cutToRestore: UUID?
    @State private var trimStart = ""
    @State private var trimEnd = ""
    @State private var zoomStart = ""
    @State private var zoomEnd = ""
    @FocusState private var focusedField: String?
    var body: some View {
        GroupBox(mode=="剪辑" ? "时间线 · 原素材时间" : "平滑缩放 · 原素材时间") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("成片 \(model.keptDuration/speed, specifier: "%.1f") 秒").font(.caption.monospacedDigit())
                    Spacer()
                    Button("撤销", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(model.undoCount==0).keyboardShortcut("z",modifiers: .command)
                    Button("重做", systemImage: "arrow.uturn.forward") { model.redo() }.disabled(model.redoCount==0).keyboardShortcut("z",modifiers: [.command,.shift])
                    if mode=="剪辑" { Button("恢复全片") { model.resetCuts() } }
                }
                if mode=="剪辑" {
                GeometryReader { proxy in
                    let width=proxy.size.width, duration=max(0.001,model.duration)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary).accessibilityHidden(true)
                        Canvas { context,size in
                            let height=50.0, maximum=max(0.05,model.waveform.max() ?? 1)
                            for (n,value) in model.waveform.enumerated() {
                                let x=Double(n)/Double(max(1,model.waveform.count))*size.width
                                let bar=max(1,sqrt(value/maximum)*height)
                                context.fill(Path(CGRect(x:x,y:16+(height-bar)/2,width:max(1,size.width/600),height:bar)),with:.color(.indigo.opacity(0.6)))
                            }
                            for cut in model.edit.cuts { context.fill(Path(CGRect(x:cut.start/duration*size.width,y:0,width:(cut.end-cut.start)/duration*size.width,height:80)),with:.color(.red.opacity(0.4))) }
                            context.fill(Path(CGRect(x:0,y:0,width:model.edit.start/duration*size.width,height:80)),with:.color(.black.opacity(0.35)))
                            context.fill(Path(CGRect(x:model.edit.end/duration*size.width,y:0,width:(duration-model.edit.end)/duration*size.width,height:80)),with:.color(.black.opacity(0.35)))
                        }.frame(height:80).accessibilityHidden(true).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in let time=max(0,min(duration,Double(value.location.x/width)*duration));seek(time) })
                        Rectangle().stroke(.orange,lineWidth:2).background(.orange.opacity(0.12)).frame(width:max(1,(model.selectionEnd-model.selectionStart)/duration*width),height:80).offset(x:model.selectionStart/duration*width).allowsHitTesting(false).accessibilityHidden(true)
                        handle(width:width,time:model.edit.start,duration:duration,color:.indigo,label:"裁剪起点") { model.setTrim($0,start:true,dragging:true) } end: { model.endGesture() }
                        handle(width:width,time:model.edit.end,duration:duration,color:.indigo,label:"裁剪终点") { model.setTrim($0,start:false,dragging:true) } end: { model.endGesture() }
                        handle(width:width,time:model.selectionStart,duration:duration,color:.orange,label:"选区起点",bottom:true) { model.setSelection($0,start:true) } end: {}
                        handle(width:width,time:model.selectionEnd,duration:duration,color:.orange,label:"选区终点",bottom:true) { model.setSelection($0,start:false) } end: {}
                        Rectangle().fill(.white).frame(width:2,height:80).offset(x:model.playhead/duration*width).allowsHitTesting(false).accessibilityHidden(true)
                    }.coordinateSpace(name:"timeline")
                }.frame(height:90)
                HStack { Text("0:00");Spacer();Text("\(model.playhead, specifier:"%.1f") 秒");Spacer();Text("\(model.duration, specifier:"%.1f") 秒") }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Text("保留范围").font(.caption)
                    TextField("起点",text:$trimStart).focused($focusedField,equals:"trimStart").frame(width:75).onSubmit { if let value=Double(trimStart),value.isFinite { model.setTrim(value,start:true) };syncTrim() }
                    Text("—")
                    TextField("终点",text:$trimEnd).focused($focusedField,equals:"trimEnd").frame(width:75).onSubmit { if let value=Double(trimEnd),value.isFinite { model.setTrim(value,start:false) };syncTrim() }
                    Spacer()
                    Button("设选区起点") { model.setSelection(model.playhead,start:true) }
                    Button("设选区终点") { model.setSelection(model.playhead,start:false) }
                    Button("删除选区",systemImage:"scissors") { if !model.deleteSelection() { notify("选区无效或删除后没有画面，请保留至少 0.05 秒。") } }
                }
                Text("拖动上方紫色手柄裁剪；下方橙色手柄选择要删除的区间。点波形定位原素材。").font(.caption).foregroundStyle(.secondary)
                Text("\(model.waveformMessage) · 选区 \(model.selectionStart,specifier:"%.2f")—\(model.selectionEnd,specifier:"%.2f") 秒").font(.caption).foregroundStyle(.secondary)
                if !model.edit.cuts.isEmpty {
                    HStack {
                        Picker("已删片段",selection:$cutToRestore) {
                            Text("选择要恢复的片段").tag(nil as UUID?)
                            ForEach(model.edit.cuts) { cut in Text("\(cut.start,specifier:"%.2f")—\(cut.end,specifier:"%.2f") 秒").tag(Optional(cut.id)) }
                        }
                        Button("恢复所选片段") { if let cutToRestore { model.removeCut(cutToRestore);self.cutToRestore=nil } }.disabled(cutToRestore==nil)
                    }
                }
                }
                if mode=="缩放" {
                HStack { Text("缩放区间").font(.caption.bold());Spacer();Button("选区添加缩放") { if !model.addZoom() { notify("请选至少 0.1 秒且不与已有缩放重叠的区间；可先删除已有区间。") } };Button("恢复自动缩放") { model.resetZoom() } }
                if model.edit.scenes.isEmpty { Text("暂无点击轨迹，可选择区间手动添加缩放。").font(.caption).foregroundStyle(.secondary) }
                else {
                    Picker("选择缩放区间",selection:$model.selectedZoom) {
                        Text("选择区间以调整焦点").tag(nil as UUID?)
                        ForEach(model.edit.scenes) { scene in Text("\(scene.start,specifier:"%.2f")—\(scene.end,specifier:"%.2f") 秒").tag(Optional(scene.id)) }
                    }.onChange(of:model.selectedZoom) { _,id in syncZoom();if let scene=model.edit.scenes.first(where:{$0.id==id}) { seek(scene.start) } }
                }
                if let scene=model.edit.scenes.first(where: { $0.id==model.selectedZoom }) {
                    HStack {
                        Text("时间").font(.caption)
                        TextField("起点",text:$zoomStart).focused($focusedField,equals:"zoomStart").frame(width:70).onSubmit { updateTimes(scene) }
                        Text("—");TextField("终点",text:$zoomEnd).focused($focusedField,equals:"zoomEnd").frame(width:70).onSubmit { updateTimes(scene) }
                        Text("\(scene.factor,specifier:"%.2f")×").font(.caption)
                        Slider(value:Binding(get:{scene.factor},set:{ value in var s=scene;s.factor=value;model.updateZoom(s,dragging:true) }),in:1...4,onEditingChanged:{ editing in if !editing { model.endGesture() } }).frame(maxWidth:150).accessibilityLabel("缩放倍率")
                        Spacer();Button("删除缩放") { model.deleteZoom() }
                    }
                    if let video { FocusPreview(video:video,scene:scene,update:{ model.updateZoom($0,dragging:$1) },begin:{ model.beginGesture() },end:{ model.endGesture() }) }
                    Text("焦点：横向 \(Int(scene.x*100))% · 纵向 \(Int(scene.y*100))%。点击焦点图中的位置修改焦点，按「效果预览」检查结果。").font(.caption).foregroundStyle(.secondary)
                }
                }
            }.padding(8)
        }.disabled(model.loading || model.duration<=0)
        .onChange(of:focusedField) { previous,_ in
            if previous=="trimStart",let value=Double(trimStart),value.isFinite { model.setTrim(value,start:true) }
            if previous=="trimEnd",let value=Double(trimEnd),value.isFinite { model.setTrim(value,start:false) }
            if previous=="zoomStart" || previous=="zoomEnd",let scene=model.edit.scenes.first(where:{$0.id==model.selectedZoom}) { updateTimes(scene) }
        }
        .onChange(of:model.edit) { _,_ in if focusedField != "trimStart" && focusedField != "trimEnd" { syncTrim() };if focusedField != "zoomStart" && focusedField != "zoomEnd" { syncZoom() } }.onAppear { syncTrim();syncZoom() }
    }
    private func syncTrim() { trimStart=String(format:"%.2f",model.edit.start);trimEnd=String(format:"%.2f",model.edit.end) }
    private func syncZoom() { if let scene=model.edit.scenes.first(where:{$0.id==model.selectedZoom}) { zoomStart=String(format:"%.2f",scene.start);zoomEnd=String(format:"%.2f",scene.end) } }
    private func updateTimes(_ scene: ZoomScene) { guard let begin=Double(zoomStart),let end=Double(zoomEnd),begin.isFinite,end.isFinite else { syncZoom();return };var s=scene;s.start=begin;s.end=end;model.updateZoom(s);syncZoom() }
    private func handle(width:CGFloat,time:Double,duration:Double,color:Color,label:String,bottom:Bool=false,change:@escaping(Double)->Void,end:@escaping()->Void) -> some View {
        RoundedRectangle(cornerRadius:3).fill(color).frame(width:14,height:bottom ? 22 : 34).offset(x:max(0,min(width-14,time/duration*width-7)),y:bottom ? 64 : 0)
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("timeline")).onChanged { value in change(max(0,min(duration,Double(value.location.x/width)*duration))) }.onEnded { _ in end() })
            .accessibilityElement(children:.ignore).accessibilityLabel(label).accessibilityValue(String(format:"%.2f 秒",time)).accessibilityAddTraits(.isButton).help(label)
    }
}

struct FocusPreview: View {
    let video: URL
    let scene: ZoomScene
    let update: (ZoomScene,Bool) -> Void
    let begin: () -> Void
    let end: () -> Void
    @State private var image: NSImage?
    var body: some View {
        HStack {
            if let image {
                Image(nsImage:image).resizable().aspectRatio(contentMode:.fit)
                    .overlay { GeometryReader { proxy in
                        ZStack {
                            Circle().stroke(.orange,lineWidth:3).frame(width:22,height:22).position(x:scene.x*proxy.size.width,y:scene.y*proxy.size.height)
                        }.frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in var s=scene;s.x=Double(value.location.x/proxy.size.width);s.y=Double(value.location.y/proxy.size.height);update(s,false) })
                    } }.frame(maxHeight:140).accessibilityLabel("点击图像设置缩放焦点")
            } else { ProgressView().frame(height:80) }
            VStack(alignment:.leading) {
                Text("焦点横向").font(.caption)
                Slider(value:Binding(get:{scene.x},set:{ var s=scene;s.x=$0;update(s,false) }),in:0...1).accessibilityLabel("焦点横向")
                Text("焦点纵向").font(.caption)
                Slider(value:Binding(get:{scene.y},set:{ var s=scene;s.y=$0;update(s,false) }),in:0...1).accessibilityLabel("焦点纵向")
            }.frame(width:150)
        }.task(id:video.path+String(scene.start)) {
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:video));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:480,height:270)
            if let result=try? await generator.image(at:CMTime(seconds:(scene.start+scene.end)/2,preferredTimescale:600)), !Task.isCancelled { image=NSImage(cgImage:result.image,size:.zero) }
        }
    }
}
