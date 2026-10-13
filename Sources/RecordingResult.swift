import SwiftUI
import AVFoundation

@MainActor
final class RecordingCover: ObservableObject {
    @Published var image: NSImage?
    @Published var duration = ""
    private var token = UUID()
    func load(_ url: URL?) {
        let id = UUID();token = id;image = nil;duration = ""
        guard let url else { return }
        Task {
            let asset = AVURLAsset(url:url)
            if let length = try? await asset.load(.duration), token == id {
                let seconds = max(0,Int(length.seconds));duration = String(format:"%02d:%02d",seconds/60,seconds%60)
            }
            let generator = AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform = true;generator.maximumSize = CGSize(width:1280,height:720)
            guard let result = try? await generator.image(at:CMTime(seconds:0.2,preferredTimescale:600)), token == id else { return }
            image = NSImage(cgImage:result.image,size:.zero)
        }
    }
}

// Preserve captured tracks and create a broadly playable original with one mixed audio track.
func playableOriginal(_ url: URL, tools: URL?) async -> URL {
    guard let tools else { return url }
    let output = url.deletingPathExtension().appendingPathExtension("original.mp4")
    if FileManager.default.fileExists(atPath:output.path) { return url }
    let result = await Task.detached(priority:.userInitiated) { () -> Bool in
        let process = Process();process.executableURL = tools.appendingPathComponent("ffmpeg")
        process.arguments = ["-v","error","-n","-i",url.path,"-filter_complex","[0:a:0][0:a:1]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[a]","-map","0:v:0","-map","[a]","-c:v","copy","-c:a","aac","-b:a","192k","-movflags","+faststart",output.path]
        process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
        do { try process.run();process.waitUntilExit();return process.terminationStatus == 0 } catch { return false }
    }.value
    guard result else { try? FileManager.default.removeItem(at:output);return url }
    let metadata = url.deletingPathExtension().appendingPathExtension("json")
    if FileManager.default.fileExists(atPath:metadata.path) { try? FileManager.default.copyItem(at:metadata,to:output.deletingPathExtension().appendingPathExtension("json")) }
    return output
}
