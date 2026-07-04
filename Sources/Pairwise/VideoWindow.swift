import AppKit
import AVFoundation

/// The floating peer-video window: always on top, square, draggable by its
/// top bar. When the cursor is over the video area the window turns
/// translucent and becomes click-through, so it never blocks your work.
final class VideoWindow: NSWindow {
    private let barHeight: CGFloat = 26
    private let videoView = VideoDisplayView(gravity: .resizeAspectFill)
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private var mouseMonitors: [Any] = []
    private var isGhosted = false
    private let micButton = NSButton()
    private let cameraButton = NSButton()
    private let shareButton = NSButton()

    var onHangUp: (() -> Void)?
    var onToggleMic: (() -> Void)?
    var onToggleCamera: (() -> Void)?
    var onToggleScreenShare: (() -> Void)?

    /// For excluding this window from screen capture.
    var windowID: CGWindowID { CGWindowID(windowNumber) }

    init(peerName: String) {
        let side: CGFloat = 240
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.maxX - side - 24, y: screen.maxY - side - barHeight - 24,
                           width: side, height: side + barHeight)
        super.init(contentRect: frame, styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isMovable = false  // we drag via the bar ourselves

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor

        // Top drag bar
        let bar = DragBarView(frame: NSRect(x: 0, y: side, width: side, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor

        nameLabel.stringValue = peerName
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.frame = NSRect(x: 10, y: 5, width: side - 116, height: 16)
        nameLabel.autoresizingMask = [.width]
        bar.addSubview(nameLabel)

        // Controls, right to left: hang up, screen share, camera, mic.
        func addBarButton(_ button: NSButton, x: CGFloat, tint: NSColor, action: Selector) {
            button.frame = NSRect(x: x, y: 4, width: 18, height: 18)
            button.bezelStyle = .circular
            button.isBordered = false
            button.contentTintColor = tint
            button.target = self
            button.action = action
            button.autoresizingMask = [.minXMargin]
            bar.addSubview(button)
        }
        let hangUpButton = NSButton()
        hangUpButton.image = NSImage(systemSymbolName: "phone.down.fill", accessibilityDescription: "Hang up")
        addBarButton(hangUpButton, x: side - 26, tint: .systemRed, action: #selector(hangUpTapped))
        addBarButton(shareButton, x: side - 50, tint: .white, action: #selector(shareTapped))
        addBarButton(cameraButton, x: side - 74, tint: .white, action: #selector(cameraTapped))
        addBarButton(micButton, x: side - 98, tint: .white, action: #selector(micTapped))
        updateControls(micOn: true, cameraOn: true, sharingScreen: false)

        // Video area
        videoView.frame = NSRect(x: 0, y: 0, width: side, height: side)
        videoView.autoresizingMask = [.width, .height]

        placeholderLabel.stringValue = String(peerName.prefix(1)).uppercased()
        placeholderLabel.font = .systemFont(ofSize: 64, weight: .medium)
        placeholderLabel.textColor = NSColor(white: 0.45, alpha: 1)
        placeholderLabel.alignment = .center
        placeholderLabel.frame = NSRect(x: 0, y: side / 2 - 40, width: side, height: 80)
        placeholderLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]

        container.addSubview(videoView)
        container.addSubview(placeholderLabel)
        container.addSubview(bar)
        contentView = container

        installMouseTracking()
    }

    override var canBecomeKey: Bool { true }

    @objc private func hangUpTapped() { onHangUp?() }
    @objc private func micTapped() { onToggleMic?() }
    @objc private func cameraTapped() { onToggleCamera?() }
    @objc private func shareTapped() { onToggleScreenShare?() }

    /// Reflect local call state in the bar buttons.
    func updateControls(micOn: Bool, cameraOn: Bool, sharingScreen: Bool) {
        micButton.image = NSImage(systemSymbolName: micOn ? "mic.fill" : "mic.slash.fill",
                                  accessibilityDescription: micOn ? "Mute microphone" : "Unmute microphone")
        micButton.contentTintColor = micOn ? .white : .systemRed
        cameraButton.image = NSImage(systemSymbolName: cameraOn ? "video.fill" : "video.slash.fill",
                                     accessibilityDescription: cameraOn ? "Turn camera off" : "Turn camera on")
        cameraButton.contentTintColor = cameraOn ? .white : .systemRed
        shareButton.image = NSImage(systemSymbolName: "rectangle.inset.filled.and.person.filled",
                                    accessibilityDescription: sharingScreen ? "Stop sharing screen" : "Share my screen")
        shareButton.contentTintColor = sharingScreen ? .systemYellow : .white
    }

    func enqueue(_ sb: CMSampleBuffer) {
        videoView.enqueue(sb)
        if !placeholderLabel.isHidden { placeholderLabel.isHidden = true }
    }

    func setCameraOff() {
        videoView.flush()
        placeholderLabel.isHidden = false
    }

    // MARK: - Hover ghosting

    private func installMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.updateGhosting() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            mouseMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            handler(event); return event
        }
        if let local { mouseMonitors.append(local) }
        // Also poll at low frequency to catch cases monitors miss.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self, self.isVisible else { timer.invalidate(); return }
            self.updateGhosting()
        }
    }

    private func updateGhosting() {
        guard isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let f = frame
        let barRect = NSRect(x: f.minX, y: f.maxY - barHeight, width: f.width, height: barHeight)
        let videoRect = NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height - barHeight)

        let overVideo = videoRect.contains(mouse)
        let overBar = barRect.contains(mouse)

        let shouldGhost = overVideo && !overBar
        if shouldGhost != isGhosted {
            isGhosted = shouldGhost
            ignoresMouseEvents = shouldGhost
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = shouldGhost ? 0.3 : 1.0
            }
        }
    }

    func teardown() {
        for m in mouseMonitors { NSEvent.removeMonitor(m) }
        mouseMonitors.removeAll()
        orderOut(nil)
    }
}

/// The bar that drags the whole window.
private final class DragBarView: NSView {
    private var dragOffset: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
    }
}
