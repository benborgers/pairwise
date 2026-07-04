import AppKit
import PWShim

/// Sharer-side reminder that the screen is being shared: yellow L-shaped
/// marks in the four screen corners. Click-through, above everything, and
/// excluded from capture so the viewer never sees them.
final class ScreenShareIndicatorWindow: NSWindow {
    var windowID: CGWindowID { CGWindowID(windowNumber) }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = CornerMarksView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                   displayCornerRadius: screen.pwDisplayCornerRadius)
        view.autoresizingMask = [.width, .height]
        contentView = view
        isReleasedWhenClosed = false
    }
}

private extension NSScreen {
    /// Physical rounded-corner radius of the panel: MacBook built-in displays
    /// report their real radius, external displays 0. Private key, so read
    /// defensively and fall back to square corners if it ever goes away.
    var pwDisplayCornerRadius: CGFloat {
        var radius: CGFloat = 0
        _ = PWTryCatch({
            radius = (self.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 0
        }, nil)
        return radius
    }
}

private final class CornerMarksView: NSView {
    private let displayCornerRadius: CGFloat

    init(frame: NSRect, displayCornerRadius: CGFloat) {
        self.displayCornerRadius = displayCornerRadius
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let length: CGFloat = 28
        let thickness: CGFloat = 4
        let inset = thickness / 2
        let b = bounds
        NSColor.systemYellow.setStroke()

        // (corner, horizontal direction, vertical direction, follows panel curve).
        // Only the top corners of MacBook panels are rounded; the bottom edge
        // is square, as is every corner of an external display (radius 0).
        for (corner, dx, dy, rounded) in [
            (NSPoint(x: b.minX, y: b.minY), CGFloat(1), CGFloat(1), false),   // bottom left
            (NSPoint(x: b.maxX, y: b.minY), CGFloat(-1), CGFloat(1), false),  // bottom right
            (NSPoint(x: b.minX, y: b.maxY), CGFloat(1), CGFloat(-1), true),   // top left
            (NSPoint(x: b.maxX, y: b.maxY), CGFloat(-1), CGFloat(-1), true),  // top right
        ] {
            // Stroke centerline runs inset from the screen edge: down one arm,
            // around the panel's corner arc, and out the other arm.
            let r = rounded ? max(displayCornerRadius - inset, 0) : 0
            let path = NSBezierPath()
            path.move(to: NSPoint(x: corner.x + dx * inset, y: corner.y + dy * length))
            if r > 0 {
                let center = NSPoint(x: corner.x + dx * (inset + r), y: corner.y + dy * (inset + r))
                path.line(to: NSPoint(x: corner.x + dx * inset, y: center.y))
                path.appendArc(withCenter: center, radius: r,
                               startAngle: dx > 0 ? 180 : 0,
                               endAngle: dy > 0 ? 270 : 90,
                               clockwise: (dx > 0) != (dy > 0))
                path.line(to: NSPoint(x: corner.x + dx * length, y: corner.y + dy * inset))
            } else {
                path.line(to: NSPoint(x: corner.x + dx * inset, y: corner.y + dy * inset))
                path.line(to: NSPoint(x: corner.x + dx * length, y: corner.y + dy * inset))
            }
            path.lineWidth = thickness
            path.stroke()
        }
    }
}
