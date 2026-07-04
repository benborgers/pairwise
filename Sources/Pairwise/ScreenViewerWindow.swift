import AppKit
import AVFoundation

/// Window on the *viewer's* side showing the peer's shared screen.
/// Click-drag anywhere on the video to annotate; strokes are streamed to the
/// sharer live and fade out on both sides.
final class ScreenViewerWindow: NSWindow {
    private let videoView = VideoDisplayView(gravity: .resizeAspect)
    private let annotationView: ViewerAnnotationView

    /// Called with normalized points as a stroke is drawn / extended.
    var onStroke: ((_ points: [AnnotationPoint], _ strokeID: UInt64) -> Void)? {
        get { annotationView.onStroke }
        set { annotationView.onStroke = newValue }
    }

    init(peerName: String, aspect: Double) {
        // No .closable: losing this window mid-share is unrecoverable, so it
        // can only go away when the share (or call) ends.
        let style: NSWindow.StyleMask = [.titled, .miniaturizable, .resizable]
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Fill the visible screen area, preserving aspect — the video should
        // touch at least two opposite edges.
        let a = max(aspect, 0.2)
        let titleBar = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                          styleMask: style).height - 100
        var width = screen.width
        var height = width / a
        if height + titleBar > screen.height {
            height = screen.height - titleBar
            width = height * a
        }
        let frame = NSRect(x: screen.midX - width / 2,
                           y: screen.midY - (height + titleBar) / 2,
                           width: width, height: height)
        annotationView = ViewerAnnotationView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame,
                   styleMask: style,
                   backing: .buffered, defer: false)
        title = "\(peerName)'s Screen"
        contentAspectRatio = NSSize(width: aspect, height: 1)
        minSize = NSSize(width: 480, height: 480 / aspect)

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        videoView.frame = container.bounds
        videoView.autoresizingMask = [.width, .height]
        annotationView.frame = container.bounds
        annotationView.autoresizingMask = [.width, .height]
        annotationView.videoAspect = aspect
        container.addSubview(videoView)
        container.addSubview(annotationView)
        contentView = container
        isReleasedWhenClosed = false
    }

    func enqueue(_ sb: CMSampleBuffer) {
        videoView.enqueue(sb)
    }
}

/// Captures click-drags as annotation strokes over the aspect-fit video,
/// echoes them locally with a fade, and reports normalized points upstream.
final class ViewerAnnotationView: NSView {
    var onStroke: ((_ points: [AnnotationPoint], _ strokeID: UInt64) -> Void)?
    var videoAspect: Double = 1.6

    private var currentStroke: [NSPoint] = []       // view coordinates
    private var currentNormalized: [AnnotationPoint] = []
    private var currentStrokeID: UInt64 = 0
    private var fadingStrokes: [FadingStroke] = []
    private var fadeTimer: Timer?
    private var nextStrokeID: UInt64 = 1

    private struct FadingStroke {
        var points: [NSPoint]
        var bornAt: CFTimeInterval
    }

    /// The rectangle the aspect-fit video actually occupies inside this view.
    private var videoRect: NSRect {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return b }
        let viewAspect = b.width / b.height
        if viewAspect > videoAspect {
            let w = b.height * videoAspect
            return NSRect(x: (b.width - w) / 2, y: 0, width: w, height: b.height)
        } else {
            let h = b.width / videoAspect
            return NSRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
        }
    }

    private func normalize(_ p: NSPoint) -> AnnotationPoint? {
        let r = videoRect
        guard r.width > 0, r.height > 0 else { return nil }
        let x = (p.x - r.minX) / r.width
        let y = 1.0 - (p.y - r.minY) / r.height  // wire format is top-left origin
        guard x >= -0.01, x <= 1.01, y >= -0.01, y <= 1.01 else { return nil }
        return AnnotationPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        currentStroke = [p]
        currentNormalized = []
        currentStrokeID = nextStrokeID
        nextStrokeID += 1
        if let n = normalize(p) { currentNormalized.append(n) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !currentStroke.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentStroke.append(p)
        if let n = normalize(p) { currentNormalized.append(n) }
        // Stream incrementally so the sharer sees the stroke appear live.
        if currentNormalized.count % 3 == 0 {
            onStroke?(currentNormalized, currentStrokeID)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !currentStroke.isEmpty else { return }
        if !currentNormalized.isEmpty {
            onStroke?(currentNormalized, currentStrokeID)
        }
        fadingStrokes.append(FadingStroke(points: currentStroke, bornAt: CACurrentMediaTime()))
        currentStroke = []
        currentNormalized = []
        startFadeTimerIfNeeded()
        needsDisplay = true
    }

    private func startFadeTimerIfNeeded() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.fadingStrokes.removeAll { now - $0.bornAt > 3.0 }
            if self.fadingStrokes.isEmpty && self.currentStroke.isEmpty {
                self.fadeTimer?.invalidate()
                self.fadeTimer = nil
            }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        for stroke in fadingStrokes {
            let age = now - stroke.bornAt
            let alpha = max(0, 1.0 - age / 3.0)
            drawStroke(stroke.points, alpha: alpha)
        }
        if !currentStroke.isEmpty {
            drawStroke(currentStroke, alpha: 1.0)
        }
    }

    private func drawStroke(_ points: [NSPoint], alpha: Double) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        NSColor.systemYellow.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
}
