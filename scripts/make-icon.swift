import CoreGraphics
import Foundation
import ImageIO

// Morrow: an open inbox receiving a spark of intelligence.
// Render directly at each target size to keep the silhouette crisp.
// Usage: swift scripts/make-icon.swift output.png [pixel-size]
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift scripts/make-icon.swift output.png [pixel-size]\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let pixels = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024
guard (16...4096).contains(pixels) else {
    fputs("Icon size must be between 16 and 4096 pixels.\n", stderr)
    exit(1)
}
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255, alpha
    ])!
}
let context = CGContext(data: nil, width: pixels, height: pixels,
    bitsPerComponent: 8, bytesPerRow: pixels * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.translateBy(x: 0, y: CGFloat(pixels))
let renderScale = CGFloat(pixels) / 1024
context.scaleBy(x: renderScale, y: -renderScale)

// A macOS-sized tile with transparent outer corners and optical breathing room.
let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
    cornerWidth: 202, cornerHeight: 202, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 12 * renderScale), blur: 22 * renderScale,
    color: color(0x163C75, alpha: 0.18))
context.addPath(tile)
context.setFillColor(color(0x347FF0))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tile)
context.clip()
let tileGradient = CGGradient(colorsSpace: colorSpace,
    colors: [color(0x2858E6), color(0x347FF0), color(0x38C5D0)] as CFArray,
    locations: [0, 0.58, 1])!
context.drawLinearGradient(tileGradient, start: CGPoint(x: 104, y: 894),
    end: CGPoint(x: 926, y: 106), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
context.restoreGState()

// The tray's central recess leaves the spark visually connected to the inbox.
let tray = CGMutablePath()
tray.move(to: CGPoint(x: 264, y: 446))
tray.addCurve(to: CGPoint(x: 228, y: 482), control1: CGPoint(x: 244, y: 446), control2: CGPoint(x: 228, y: 462))
tray.addLine(to: CGPoint(x: 228, y: 674))
tray.addCurve(to: CGPoint(x: 288, y: 734), control1: CGPoint(x: 228, y: 707), control2: CGPoint(x: 255, y: 734))
tray.addLine(to: CGPoint(x: 736, y: 734))
tray.addCurve(to: CGPoint(x: 796, y: 674), control1: CGPoint(x: 769, y: 734), control2: CGPoint(x: 796, y: 707))
tray.addLine(to: CGPoint(x: 796, y: 482))
tray.addCurve(to: CGPoint(x: 760, y: 446), control1: CGPoint(x: 796, y: 462), control2: CGPoint(x: 780, y: 446))
tray.addLine(to: CGPoint(x: 685, y: 446))
tray.addCurve(to: CGPoint(x: 658, y: 463), control1: CGPoint(x: 673, y: 446), control2: CGPoint(x: 664, y: 452))
tray.addLine(to: CGPoint(x: 617, y: 532))
tray.addCurve(to: CGPoint(x: 587, y: 550), control1: CGPoint(x: 610, y: 544), control2: CGPoint(x: 599, y: 550))
tray.addLine(to: CGPoint(x: 437, y: 550))
tray.addCurve(to: CGPoint(x: 407, y: 532), control1: CGPoint(x: 425, y: 550), control2: CGPoint(x: 414, y: 544))
tray.addLine(to: CGPoint(x: 366, y: 463))
tray.addCurve(to: CGPoint(x: 339, y: 446), control1: CGPoint(x: 360, y: 452), control2: CGPoint(x: 351, y: 446))
tray.closeSubpath()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 10 * renderScale), blur: 18 * renderScale,
    color: color(0x173D91, alpha: 0.17))
context.addPath(tray)
context.setFillColor(color(0xFFFFFF))
context.fillPath()
context.restoreGState()

// One large four-point spark remains legible at Dock and favicon sizes.
let spark = CGMutablePath()
spark.move(to: CGPoint(x: 512, y: 246))
spark.addCurve(to: CGPoint(x: 646, y: 380), control1: CGPoint(x: 532, y: 339), control2: CGPoint(x: 553, y: 360))
spark.addCurve(to: CGPoint(x: 512, y: 514), control1: CGPoint(x: 553, y: 400), control2: CGPoint(x: 532, y: 421))
spark.addCurve(to: CGPoint(x: 378, y: 380), control1: CGPoint(x: 492, y: 421), control2: CGPoint(x: 471, y: 400))
spark.addCurve(to: CGPoint(x: 512, y: 246), control1: CGPoint(x: 471, y: 360), control2: CGPoint(x: 492, y: 339))
spark.closeSubpath()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 7 * renderScale), blur: 13 * renderScale,
    color: color(0x173D91, alpha: 0.12))
context.addPath(spark)
context.setFillColor(color(0xFFFFFF))
context.fillPath()
context.restoreGState()

let image = context.makeImage()!
let png = CFDataCreateMutable(kCFAllocatorDefault, 0)!
guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
    fputs("Could not encode icon PNG.\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Could not finalize icon PNG.\n", stderr)
    exit(1)
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
// ImageIO adds an EXIF block even for a fresh drawing. Keep the exported asset
// limited to pixels and color data, as required by the publication gate.
let encoded = png as Data
var cleanPNG = Data(encoded.prefix(8))
var cursor = 8
while cursor + 12 <= encoded.count {
    let length = encoded[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
    let end = cursor + length + 12
    guard end <= encoded.count else { fatalError("Invalid encoded PNG chunk.") }
    let type = String(decoding: encoded[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
    if type != "eXIf" { cleanPNG.append(encoded[cursor..<end]) }
    cursor = end
}
guard cursor == encoded.count else { fatalError("Incomplete encoded PNG.") }
try cleanPNG.write(to: output, options: .atomic)
print("Rendered \(pixels)×\(pixels): \(output.path)")
