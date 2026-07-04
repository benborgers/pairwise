import AppKit

/// Sharer-side reminder that the screen is being shared: opaque yellow marks
/// hugging the screen corners. Click-through, above everything, and excluded
/// from capture so the viewer never sees them.
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
                                   bezelPath: screen.pwBezelPath)
        view.autoresizingMask = [.width, .height]
        contentView = view
        isReleasedWhenClosed = false
    }
}

private extension NSScreen {
    /// Physical outline of the panel (rounded top corners, notch cutout) in
    /// screen-local points — private `bezelPath` method on MacBook built-in
    /// displays. Read defensively; nil means square corners (external
    /// displays, or the API going away).
    var pwBezelPath: NSBezierPath? {
        let selector = NSSelectorFromString("bezelPath")
        guard responds(to: selector),
              let path = perform(selector)?.takeUnretainedValue() as? NSBezierPath,
              let local = path.copy() as? NSBezierPath else { return nil }
        // Seen local so far, but localize if a screen ever reports globally.
        if frame.origin != .zero,
           abs(local.bounds.minX - frame.minX) < 1, abs(local.bounds.minY - frame.minY) < 1 {
            local.transform(using: AffineTransform(translationByX: -frame.minX, byY: -frame.minY))
        }
        // Sanity: the outline should span the whole panel.
        guard abs(local.bounds.width - frame.width) < 4,
              abs(local.bounds.height - frame.height) < 4 else {
            PWLog("bezelPath bounds \(local.bounds) don't match screen \(frame); ignoring")
            return nil
        }
        return local
    }
}

private final class CornerMarksView: NSView {
    private let bezelPath: NSBezierPath?

    init(frame: NSRect, bezelPath: NSBezierPath?) {
        self.bezelPath = bezelPath
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Long enough to cover a MacBook panel's full corner curve (~37 pt)
        // plus a stub of straight edge.
        let length: CGFloat = 44
        let thickness: CGFloat = 4
        let b = bounds
        NSColor.systemYellow.setStroke()

        let cornerBoxes = [
            NSRect(x: b.minX, y: b.minY, width: length, height: length),
            NSRect(x: b.maxX - length, y: b.minY, width: length, height: length),
            NSRect(x: b.minX, y: b.maxY - length, width: length, height: length),
            NSRect(x: b.maxX - length, y: b.maxY - length, width: length, height: length),
        ]

        if let bezel = bezelPath {
            // Stroke the panel outline itself, clipped to the corner boxes.
            // The stroke straddles the outline, so the outer half falls
            // beyond the physical edge and a `thickness` band remains inside,
            // matching the device's real corner curve exactly.
            bezel.lineWidth = thickness * 2
            for box in cornerBoxes {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: box).addClip()
                bezel.stroke()
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        } else {
            // Square L-marks for displays without a known panel outline.
            let inset = thickness / 2
            for (corner, dx, dy) in [
                (NSPoint(x: b.minX, y: b.minY), CGFloat(1), CGFloat(1)),
                (NSPoint(x: b.maxX, y: b.minY), CGFloat(-1), CGFloat(1)),
                (NSPoint(x: b.minX, y: b.maxY), CGFloat(1), CGFloat(-1)),
                (NSPoint(x: b.maxX, y: b.maxY), CGFloat(-1), CGFloat(-1)),
            ] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: corner.x + dx * inset, y: corner.y + dy * length))
                path.line(to: NSPoint(x: corner.x + dx * inset, y: corner.y + dy * inset))
                path.line(to: NSPoint(x: corner.x + dx * length, y: corner.y + dy * inset))
                path.lineWidth = thickness
                path.stroke()
            }
        }
    }
}
