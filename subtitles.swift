#!/usr/bin/swift
import AppKit
import Foundation
struct Cue: Decodable { let text: String; let path: String }
let args = CommandLine.arguments
if args.count != 4 { fatalError("Usage: subtitles.swift cues.json width height") }
let cues = try JSONDecoder().decode([Cue].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let width = Int(args[2])!, height = Int(args[3])!
for cue in cues {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create subtitle canvas") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill(); NSRect(x: 0,y: 0,width: width,height: height).fill()
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
    let fontSize = CGFloat(max(14, min(48, Double(width) / 36)))
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    let text = NSAttributedString(string: cue.text, attributes: attributes)
    let measured = text.boundingRect(with: NSSize(width: Double(width) * 0.86, height: Double(height) - 28), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let boxWidth = min(CGFloat(width) * 0.94, max(80, measured.width + 36))
    let boxHeight = min(CGFloat(height) - 8, measured.height + 24)
    let box = NSRect(x: (CGFloat(width) - boxWidth) / 2, y: 8, width: boxWidth, height: boxHeight)
    NSColor.black.withAlphaComponent(0.72).setFill(); NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
    text.draw(with: NSRect(x: box.minX + 18, y: box.minY + 12, width: box.width - 36, height: box.height - 24), options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: cue.path))
}
