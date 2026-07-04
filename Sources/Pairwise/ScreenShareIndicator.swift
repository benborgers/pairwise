import AppKit

/// Sharer-side reminder that the screen is being shared: subtle yellow
/// L-shaped marks in the four screen corners. Click-through, above
/// everything, and excluded from capture so the viewer never sees them.
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
        let view = CornerMarksView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        contentView = view
        isReleasedWhenClosed = false
    }
}

private final class CornerMarksView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let length: CGFloat = 28
        let thickness: CGFloat = 4
        let b = bounds
        NSColor.systemYellow.withAlphaComponent(0.75).setFill()

        for (x, y, dx, dy) in [
            (b.minX, b.minY, 1.0, 1.0),   // bottom left
            (b.maxX, b.minY, -1.0, 1.0),  // bottom right
            (b.minX, b.maxY, 1.0, -1.0),  // top left
            (b.maxX, b.maxY, -1.0, -1.0), // top right
        ] {
            // Horizontal arm
            NSRect(x: dx > 0 ? x : x - length, y: dy > 0 ? y : y - thickness,
                   width: length, height: thickness).fill()
            // Vertical arm
            NSRect(x: dx > 0 ? x : x - thickness, y: dy > 0 ? y : y - length,
                   width: thickness, height: length).fill()
        }
    }
}
