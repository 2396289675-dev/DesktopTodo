import AppKit

let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

let rect = NSRect(origin: .zero, size: size).insetBy(dx: 96, dy: 96)
let path = NSBezierPath(roundedRect: rect, xRadius: 216, yRadius: 216)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.60, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.45, green: 0.38, blue: 0.96, alpha: 1)
])!
grad.draw(in: path, angle: -45)

NSColor.white.setStroke()
let cp = NSBezierPath()
cp.lineWidth = 86
cp.lineCapStyle = .round
cp.lineJoinStyle = .round
cp.move(to: NSPoint(x: 348, y: 528))
cp.line(to: NSPoint(x: 458, y: 418))
cp.line(to: NSPoint(x: 692, y: 648))
cp.stroke()

img.unlockFocus()

let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let rep = NSBitmapImageRep(cgImage: cg)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon ready")
