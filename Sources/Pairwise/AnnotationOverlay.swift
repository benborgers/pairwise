import AppKit

/// Sharer-side overlay: a transparent, click-through window covering the
/// shared display that renders the remote peer's annotation strokes.
/// Its window ID is excluded from screen capture so strokes aren't echoed.
final class AnnotationOverlayWindow: NSWindow {
    private let strokesView = OverlayStrokesView()

    var windowID: CGWindowID {
        CGWindowID(windowNumber)
    }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        strokesView.frame = NSRect(origin: .zero, size: screen.frame.size)
        strokesView.autoresizingMask = [.width, .height]
        contentView = strokesView
        isReleasedWhenClosed = false
    }

    /// Add or extend a stroke; points are normalized top-left-origin coords.
    func applyStroke(points: [AnnotationPoint], strokeID: UInt64) {
        strokesView.applyStroke(points: points, strokeID: strokeID)
    }
}

private final class OverlayStrokesView: NSView {
    private struct Stroke {
        var points: [AnnotationPoint]
        var lastUpdated: CFTimeInterval
    }

    private var strokes: [UInt64: Stroke] = [:]
    private var fadeTimer: Timer?

    func applyStroke(points: [AnnotationPoint], strokeID: UInt64) {
        strokes[strokeID] = Stroke(points: points, lastUpdated: CACurrentMediaTime())
        startFadeTimerIfNeeded()
        needsDisplay = true
    }

    private func startFadeTimerIfNeeded() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.strokes = self.strokes.filter { now - $0.value.lastUpdated < 3.0 }
            if self.strokes.isEmpty {
                self.fadeTimer?.invalidate()
                self.fadeTimer = nil
            }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        let b = bounds
        for (_, stroke) in strokes {
            guard stroke.points.count > 1 else { continue }
            let age = now - stroke.lastUpdated
            let alpha = max(0, 1.0 - age / 3.0)
            let path = NSBezierPath()
            path.lineWidth = 5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let pts = stroke.points.map { p in
                NSPoint(x: p.x * b.width, y: (1.0 - p.y) * b.height)
            }
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.line(to: p) }
            NSColor.systemYellow.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
    }
}
