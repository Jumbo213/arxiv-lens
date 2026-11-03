import AppKit

let size = 1024
let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)

let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 205, yRadius: 205)
NSGradient(starting: NSColor(red: 0.07, green: 0.14, blue: 0.16, alpha: 1),
           ending: NSColor(red: 0.08, green: 0.37, blue: 0.32, alpha: 1))!
    .draw(in: background, angle: 48)

func page(_ x: CGFloat, y: CGFloat, angle: CGFloat, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    (AffineTransform(translationByX: x, byY: y) as NSAffineTransform).concat()
    (AffineTransform(rotationByDegrees: angle) as NSAffineTransform).concat()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 290, height: 420), xRadius: 43, yRadius: 43).fill()
    NSGraphicsContext.restoreGraphicsState()
}

page(234, y: 292, angle: 9, color: NSColor(red: 0.24, green: 0.59, blue: 0.50, alpha: 1))
page(441, y: 264, angle: 0, color: NSColor(red: 0.80, green: 0.98, blue: 0.88, alpha: 1))
NSColor(red: 0.09, green: 0.31, blue: 0.27, alpha: 1).setFill()
for (y, width) in [(565, 175), (504, 130), (443, 175)] {
    NSBezierPath(roundedRect: NSRect(x: 500, y: y, width: width, height: 19), xRadius: 9, yRadius: 9).fill()
}
let sparkle = NSBezierPath()
sparkle.move(to: NSPoint(x: 758, y: 797))
sparkle.curve(to: NSPoint(x: 820, y: 734), controlPoint1: NSPoint(x: 764, y: 755), controlPoint2: NSPoint(x: 778, y: 740))
sparkle.curve(to: NSPoint(x: 758, y: 672), controlPoint1: NSPoint(x: 778, y: 729), controlPoint2: NSPoint(x: 764, y: 714))
sparkle.curve(to: NSPoint(x: 696, y: 734), controlPoint1: NSPoint(x: 752, y: 714), controlPoint2: NSPoint(x: 738, y: 729))
sparkle.curve(to: NSPoint(x: 758, y: 797), controlPoint1: NSPoint(x: 738, y: 740), controlPoint2: NSPoint(x: 752, y: 755))
sparkle.close()
NSColor(red: 0.97, green: 0.86, blue: 0.60, alpha: 1).setFill()
sparkle.fill()

NSGraphicsContext.restoreGraphicsState()
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
