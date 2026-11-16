import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Support/AppIconArtwork.png")
let sourceData = try Data(contentsOf: sourceURL)
guard let sourceBitmap = NSBitmapImageRep(data: sourceData),
      sourceBitmap.pixelsWide == sourceBitmap.pixelsHigh,
      sourceBitmap.pixelsWide >= 1024,
      let sourceCGImage = sourceBitmap.cgImage else {
    fputs("Support/AppIconArtwork.png must be a square PNG at least 1024 pixels wide.\n", stderr)
    exit(1)
}
let source = NSImage(cgImage: sourceCGImage,
                     size: NSSize(width: sourceCGImage.width, height: sourceCGImage.height))
let iconset = root.appendingPathComponent(".build/Macarok.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func renderIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current?.imageInterpolation = .high
    // Apply the app tile's export mask consistently at every scale. The artwork's
    // generated exterior is not part of the icon; retain its internal colors and layout.
    let inset = CGFloat(size) * 0.055
    let tile = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2,
                      height: CGFloat(size) - inset * 2)
    NSBezierPath(roundedRect: tile, xRadius: CGFloat(size) * 0.19,
                 yRadius: CGFloat(size) * 0.19).addClip()
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                from: NSRect(origin: .zero, size: source.size), operation: .copy, fraction: 1)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let name = "icon_\(points)x\(points)\(multiplier == 2 ? "@2x" : "").png"
        let png = try renderIcon(size: points * multiplier)
        try png.write(to: iconset.appendingPathComponent(name))
        if points == 512 && multiplier == 2 {
            try png.write(to: root.appendingPathComponent("Support/AppIcon.png"))
        }
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Support/AppIcon.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
