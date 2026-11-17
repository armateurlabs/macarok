import AppKit
import SwiftUI

/// A monochrome person-and-waves template that follows native menu and control appearances.
enum PodcastSourceIcon {
    static let image = make(size: 18)
    /// Matches the visual size of the SF Symbols in the Settings toolbar.
    static let settingsImage = make(size: 22)

    /// Drawn on an 18-point grid and scaled, so every size keeps the same proportions.
    static func make(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = NSAffineTransform()
            scale.scale(by: size / 18)
            scale.concat()
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()
            let center = NSPoint(x: 9, y: 10)
            for radius in [CGFloat(7), CGFloat(4.5)] {
                let wave = NSBezierPath()
                wave.lineWidth = 1.3
                wave.lineCapStyle = .round
                wave.appendArc(withCenter: center, radius: radius, startAngle: 225, endAngle: 315, clockwise: true)
                wave.stroke()
            }

            NSBezierPath(ovalIn: NSRect(x: 7.35, y: 8.65, width: 3.3, height: 3.3)).fill()
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 9, y: 7.5))
            body.curve(to: NSPoint(x: 11.1, y: 5.4), controlPoint1: NSPoint(x: 10.8, y: 7.5), controlPoint2: NSPoint(x: 11.35, y: 6.75))
            body.line(to: NSPoint(x: 10.3, y: 1.8))
            body.curve(to: NSPoint(x: 9, y: 0.7), controlPoint1: NSPoint(x: 10.15, y: 1.1), controlPoint2: NSPoint(x: 9.8, y: 0.7))
            body.curve(to: NSPoint(x: 7.7, y: 1.8), controlPoint1: NSPoint(x: 8.2, y: 0.7), controlPoint2: NSPoint(x: 7.85, y: 1.1))
            body.line(to: NSPoint(x: 6.9, y: 5.4))
            body.curve(to: NSPoint(x: 9, y: 7.5), controlPoint1: NSPoint(x: 6.65, y: 6.75), controlPoint2: NSPoint(x: 7.2, y: 7.5))
            body.close()
            body.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Podcasts"
        return image
    }
}

extension Image {
    static var podcast: Image { Image(nsImage: PodcastSourceIcon.image).renderingMode(.template) }
    /// Empty states draw their icon at a fixed size instead of scaling with the font.
    static var podcastLarge: Image { Image(nsImage: PodcastSourceIcon.make(size: 40)).renderingMode(.template) }
}
