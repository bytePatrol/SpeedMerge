// Draws the app icon: two folder streams merging into one. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let background = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.98, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.62, alpha: 1))!.draw(in: background, angle: -90)

let path = NSBezierPath()
path.lineWidth = 70
path.lineCapStyle = .round
path.lineJoinStyle = .round
path.move(to: NSPoint(x: 300, y: 740)); path.curve(to: NSPoint(x: 512, y: 470), controlPoint1: NSPoint(x: 300, y: 600), controlPoint2: NSPoint(x: 512, y: 600))
path.move(to: NSPoint(x: 724, y: 740)); path.curve(to: NSPoint(x: 512, y: 470), controlPoint1: NSPoint(x: 724, y: 600), controlPoint2: NSPoint(x: 512, y: 600))
path.move(to: NSPoint(x: 512, y: 470)); path.line(to: NSPoint(x: 512, y: 300))
NSColor.white.setStroke()
path.stroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 400, y: 340)); arrow.line(to: NSPoint(x: 512, y: 215)); arrow.line(to: NSPoint(x: 624, y: 340)); arrow.close()
NSColor.white.setFill()
arrow.fill()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
