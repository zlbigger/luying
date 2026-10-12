import Foundation
import AVFoundation
@main struct TimelineModelTest {
    @MainActor static func main() async throws {
        let model = TimelineModel()
        model.load(URL(fileURLWithPath: CommandLine.arguments[1]))
        for _ in 0..<200 { if model.duration > 0 && !model.waveform.isEmpty { break };try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(model.duration > 2.9 && model.waveform.max()! > 0.01)
        model.setSelection(0.5,start:true);model.setSelection(1.0,start:false)
        precondition(model.deleteSelection());precondition(abs(model.keptDuration-(model.duration-0.5))<0.001)
        model.undo();precondition(model.edit.cuts.isEmpty);model.redo();precondition(model.edit.cuts.count==1)
        model.setSelection(1.5,start:true);model.setSelection(2.0,start:false);precondition(model.addZoom())
        var scene=model.edit.scenes[0];scene.x=0.8;scene.factor=2.0;model.updateZoom(scene)
        precondition(model.edit.scenes[0].factor==2.0);model.undo();precondition(model.edit.scenes[0].factor==1.65);model.redo()
        let saved=try JSONDecoder().decode(TimelineEdit.self,from:JSONEncoder().encode(model.edit))
        let restored=TimelineModel();restored.load(URL(fileURLWithPath:CommandLine.arguments[1]),saved:saved)
        for _ in 0..<200 { if restored.duration>0 && !restored.loading { break };try await Task.sleep(nanoseconds:50_000_000) }
        precondition(restored.edit==saved)
        print("PASS: waveform, cuts, undo/redo, editable zoom and project restore")
    }
}
