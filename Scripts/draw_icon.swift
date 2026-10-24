import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.15, green: 0.23, blue: 0.18, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
NSColor(calibratedRed: 0.92, green: 0.89, blue: 0.77, alpha: 1).setFill()
for (index,height) in [150,260,370,260,150].enumerated() {
 let rect=NSRect(x: 300+index*90, y: 520-height/2, width: 42, height: height)
 NSBezierPath(roundedRect:rect, xRadius:21, yRadius:21).fill()
}
let path=NSBezierPath()
path.move(to:NSPoint(x:240,y:326));path.curve(to:NSPoint(x:512,y:268), controlPoint1:NSPoint(x:350,y:326),controlPoint2:NSPoint(x:410,y:305))
path.curve(to:NSPoint(x:784,y:326), controlPoint1:NSPoint(x:614,y:305),controlPoint2:NSPoint(x:674,y:326))
NSColor(calibratedRed:0.85,green:0.55,blue:0.34,alpha:1).setStroke();path.lineWidth=16;path.lineCapStyle = .round;path.stroke()
image.unlockFocus()
let data=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
