import Foundation
import Darwin
import AVFoundation
import ScreenCaptureKit

func frame(_ seconds: Double) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    var format: CMVideoFormatDescription?
    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return sample!
}
@main struct Check {
 static func main() async throws {
    let original = try frame(103)
    let adjusted = removingPausedTime(original, offset: CMTime(seconds: 2, preferredTimescale: 600))!
    precondition(abs(CMTimeGetSeconds(adjusted.presentationTimeStamp)-101)<0.001)
    let url = URL(fileURLWithPath: CommandLine.arguments[1]); try? FileManager.default.removeItem(at: url)
    let camera = CameraSink(url: url); camera.origin = CMTime(seconds: 100, preferredTimescale: 600)
    let output = AVCaptureVideoDataOutput()
    let connection = AVCaptureConnection(inputPorts: [], output: output)
    for n in 0..<30 { camera.captureOutput(output, didOutput: try frame(100+Double(n)/30), from: connection); usleep(34000) }
    camera.setPaused(true, at: CMTime(seconds: 101, preferredTimescale: 600))
    camera.captureOutput(output, didOutput: try frame(102), from: connection)
    camera.setPaused(false, at: CMTime(seconds: 103, preferredTimescale: 600))
    camera.captureOutput(output, didOutput: try frame(102.9), from: connection)
    for n in 0..<30 { camera.captureOutput(output, didOutput: try frame(103+Double(n)/30), from: connection); usleep(34000) }
    let ok = await withCheckedContinuation { continuation in camera.finish { continuation.resume(returning: $0) } }
    precondition(ok)
    let duration = try await AVURLAsset(url: url).load(.duration)
    precondition(abs(CMTimeGetSeconds(duration)-2)<0.1, "pause duration mismatch")
    print("PASS: camera encoding, shared timeline, pause frame rejection, stale frame rejection, two-second gap removed")
 }
}
