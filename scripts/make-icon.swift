import AppKit
let directory = CommandLine.arguments[1]
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let box = NSBezierPath(roundedRect: NSRect(x: s*0.03,y: s*0.03,width: s*0.94,height: s*0.94),xRadius:s*0.22,yRadius:s*0.22)
    let gradient = NSGradient(starting: NSColor(red:0.24,green:0.19,blue:0.72,alpha:1),ending:NSColor(red:0.51,green:0.30,blue:0.98,alpha:1))!
    gradient.draw(in: box, angle: 45)
    NSColor.white.setStroke()
    let frame = NSBezierPath(roundedRect:NSRect(x:s*0.19,y:s*0.25,width:s*0.62,height:s*0.50),xRadius:s*0.08,yRadius:s*0.08)
    frame.lineWidth=s*0.047;frame.stroke()
    NSColor.white.setFill()
    let triangle=NSBezierPath();triangle.move(to:NSPoint(x:s*0.44,y:s*0.36));triangle.line(to:NSPoint(x:s*0.64,y:s*0.50));triangle.line(to:NSPoint(x:s*0.44,y:s*0.64));triangle.close();triangle.fill()
    NSColor(red:1,green:0.38,blue:0.40,alpha:1).setFill()
    NSBezierPath(ovalIn:NSRect(x:s*0.17,y:s*0.68,width:s*0.16,height:s*0.16)).fill()
    image.unlockFocus()
    let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
    let data=rep.representation(using:.png,properties:[:])!
    try data.write(to:URL(fileURLWithPath:"\(directory)/\(size).png"))
}
