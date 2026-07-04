import AppKit

/// Incoming-call panel: floats above everything, rings until answered.
final class RingWindow: NSPanel {
    private var ringTimer: Timer?
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?

    init(callerName: String) {
        let size = NSSize(width: 320, height: 140)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 60,
                           width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .hudWindow
        content.state = .active

        let icon = NSImageView(frame: NSRect(x: size.width / 2 - 16, y: 96, width: 32, height: 32))
        icon.image = NSImage(systemSymbolName: "phone.arrow.down.left.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemGreen
        icon.symbolConfiguration = .init(pointSize: 24, weight: .medium)
        content.addSubview(icon)

        let label = NSTextField(labelWithString: "\(callerName) is calling…")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 62, width: size.width - 20, height: 24)
        content.addSubview(label)

        let decline = NSButton(title: "Decline", target: self, action: #selector(declineTapped))
        decline.bezelStyle = .rounded
        decline.frame = NSRect(x: 40, y: 16, width: 110, height: 32)
        decline.keyEquivalent = "\u{1b}"
        content.addSubview(decline)

        let accept = NSButton(title: "Accept", target: self, action: #selector(acceptTapped))
        accept.bezelStyle = .rounded
        accept.frame = NSRect(x: size.width - 150, y: 16, width: 110, height: 32)
        accept.keyEquivalent = "\r"
        accept.bezelColor = .systemGreen
        content.addSubview(accept)

        contentView = content
    }

    func startRinging() {
        orderFrontRegardless()
        playRing()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.playRing()
        }
    }

    private func playRing() {
        NSSound(named: "Submarine")?.play()
    }

    func stopRinging() {
        ringTimer?.invalidate()
        ringTimer = nil
        orderOut(nil)
    }

    @objc private func acceptTapped() { stopRinging(); onAccept?() }
    @objc private func declineTapped() { stopRinging(); onDecline?() }
}

/// Small "calling…" feedback panel on the caller's side.
final class OutgoingCallWindow: NSPanel {
    var onCancel: (() -> Void)?

    init(calleeName: String) {
        let size = NSSize(width: 280, height: 110)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 60,
                           width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .modalPanel
        isFloatingPanel = true

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .hudWindow
        content.state = .active

        let label = NSTextField(labelWithString: "Calling \(calleeName)…")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 62, width: size.width - 20, height: 24)
        content.addSubview(label)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: size.width / 2 - 55, y: 16, width: 110, height: 32)
        content.addSubview(cancel)

        contentView = content
    }

    @objc private func cancelTapped() { onCancel?() }
}
