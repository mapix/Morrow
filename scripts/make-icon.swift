import AppKit
import Foundation
let output = CommandLine.arguments[1]
let paper = NSColor(red: 0.067, green: 0.098, blue: 0.116, alpha: 1)
let accent = NSColor(red: 0.744, green: 0.945, blue: 0.345, alpha: 1)
let ink = NSColor(red: 0.075, green: 0.13, blue: 0.025, alpha: 1)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
paper.setFill(); NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210).fill()
accent.setFill(); NSBezierPath(roundedRect: NSRect(x: 190, y: 286, width: 644, height: 452), xRadius: 58, yRadius: 58).fill()
let fold = NSBezierPath(); fold.move(to: NSPoint(x: 213, y: 700)); fold.line(to: NSPoint(x: 512, y: 473)); fold.line(to: NSPoint(x: 811, y: 700)); fold.lineWidth = 28; fold.lineCapStyle = .round; fold.lineJoinStyle = .round; ink.setStroke(); fold.stroke()
let lower = NSBezierPath(); lower.move(to: NSPoint(x: 230, y: 322)); lower.line(to: NSPoint(x: 390, y: 466)); lower.move(to: NSPoint(x: 794, y: 322)); lower.line(to: NSPoint(x: 634, y: 466)); lower.lineWidth = 24; lower.lineCapStyle = .round; ink.setStroke(); lower.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
