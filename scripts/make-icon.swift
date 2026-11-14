import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/Macarok.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func renderIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current?.imageInterpolation = .high
    context.cgContext.scaleBy(x: scale, y: scale)
    let background = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968), xRadius: 213, yRadius: 213)
    NSColor(calibratedRed: 0.075, green: 0.20, blue: 0.32, alpha: 1).setFill()
    background.fill()
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.74, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.26, blue: 0.43, alpha: 1))!
    gradient.draw(in: background, angle: 70)
    NSColor.white.withAlphaComponent(0.16).setStroke()
    let disc = NSBezierPath(ovalIn: NSRect(x: 166, y: 166, width: 692, height: 692))
    disc.lineWidth = 3; disc.stroke()
    for inset in [25.0, 52.0] {
        let groove = NSBezierPath(ovalIn: NSRect(x: 166 + inset, y: 166 + inset, width: 692 - inset * 2, height: 692 - inset * 2))
        groove.lineWidth = 2; groove.stroke()
    }
    NSColor(calibratedRed: 0.88, green: 0.96, blue: 1, alpha: 1).setStroke()
    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: 290, y: 360)); mark.line(to: NSPoint(x: 290, y: 660))
    mark.line(to: NSPoint(x: 512, y: 440)); mark.line(to: NSPoint(x: 734, y: 660))
    mark.line(to: NSPoint(x: 734, y: 360)); mark.lineWidth = 66
    mark.lineCapStyle = .round; mark.lineJoinStyle = .round; mark.stroke()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let name = "icon_\(points)x\(points)\(multiplier == 2 ? "@2x" : "").png"
        try renderIcon(size: points * multiplier).write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Support/AppIcon.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
