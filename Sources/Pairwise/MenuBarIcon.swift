import AppKit

/// The pear menu bar glyph, drawn from bezier paths so it stays crisp at any
/// backing scale and renders as a template image (auto light/dark).
/// Shape traces Apple's 🍐 emoji silhouette: a fat round body whose lean
/// comes from the short neck sitting offset to the right, plus a stem drawn
/// deliberately thick so it still reads at menu bar size.
enum MenuBarIcon {
    static let pear: NSImage = {
        // Design canvas is 1024×1024, y-down.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
            NSColor.black.set()

            let body = NSBezierPath()
            body.move(to: NSPoint(x: 530, y: 210))
            body.curve(to: NSPoint(x: 712, y: 225),
                       controlPoint1: NSPoint(x: 555, y: 155), controlPoint2: NSPoint(x: 690, y: 160))
            body.curve(to: NSPoint(x: 830, y: 560),
                       controlPoint1: NSPoint(x: 728, y: 330), controlPoint2: NSPoint(x: 800, y: 420))
            body.curve(to: NSPoint(x: 620, y: 930),
                       controlPoint1: NSPoint(x: 855, y: 720), controlPoint2: NSPoint(x: 780, y: 880))
            body.curve(to: NSPoint(x: 210, y: 810),
                       controlPoint1: NSPoint(x: 480, y: 975), controlPoint2: NSPoint(x: 300, y: 940))
            body.curve(to: NSPoint(x: 300, y: 430),
                       controlPoint1: NSPoint(x: 130, y: 690), controlPoint2: NSPoint(x: 175, y: 540))
            body.curve(to: NSPoint(x: 530, y: 210),
                       controlPoint1: NSPoint(x: 390, y: 350), controlPoint2: NSPoint(x: 505, y: 300))
            body.close()
            body.fill()

            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 618, y: 215))
            stem.curve(to: NSPoint(x: 685, y: 62),
                       controlPoint1: NSPoint(x: 630, y: 160), controlPoint2: NSPoint(x: 650, y: 110))
            stem.lineWidth = 62
            stem.lineCapStyle = .round
            stem.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pairwise"
        return image
    }()
}
