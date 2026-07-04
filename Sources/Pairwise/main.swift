import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let callController = CallController()
    private var presenceItems: [String: NSMenuItem] = [:]  // peer host → menu line
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var selfTestPipeline: AudioPipeline?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PWLog("app ready — build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        // Headless audio smoke test: PAIRWISE_AUDIO_SELFTEST=1 starts the voice
        // pipeline at launch and exits, so audio-start crashes are catchable in CI.
        if ProcessInfo.processInfo.environment["PAIRWISE_AUDIO_SELFTEST"] == "1" {
            let pipeline = AudioPipeline()
            var frames = 0
            pipeline.onEncodedFrame = { _, _, _ in frames += 1 }
            pipeline.start()
            selfTestPipeline = pipeline
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let result = "AUDIO_SELFTEST: \(frames) encoded frames, \(pipeline.debugTapCount) tap callbacks in 4s"
                NSLog("Pairwise: %@", result)
                try? result.write(toFile: "/tmp/pairwise_selftest.txt", atomically: true, encoding: .utf8)
                pipeline.stop()
                exit(frames > 0 ? 0 : 1)
            }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Pairwise")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        callController.onStateChanged = { [weak self] in
            self?.refreshStatusIcon()
        }

        // Presence results land asynchronously while the menu is open;
        // repaint the dots in place.
        PresenceStore.shared.onChanged = { [weak self] in
            guard let self else { return }
            for (host, item) in self.presenceItems {
                item.image = Self.presenceDot(online: PresenceStore.shared.online[host])
            }
        }

        // Warm the voice-processing probe so call audio starts instantly.
        DispatchQueue.global(qos: .utility).async { AudioPipeline.warmUpProbe() }
    }

    private func refreshStatusIcon() {
        let symbol: String
        switch callController.state {
        case .idle: symbol = "person.2.fill"
        case .dialing, .ringing: symbol = "phone.badge.waveform.fill"
        case .inCall: symbol = "phone.connection.fill"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pairwise")
    }

    // MARK: - Menu

    private static func presenceDot(online: Bool?) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
            .applying(.init(paletteColors: [online == true ? .systemGreen : .systemGray]))
        return NSImage(systemSymbolName: "circle.fill",
                       accessibilityDescription: online == true ? "Online" : "Offline")?
            .withSymbolConfiguration(config)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        presenceItems.removeAll()

        switch callController.state {
        case .inCall(let peerName):
            let header = NSMenuItem(title: "In call with \(peerName)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            menu.addItem(makeItem(
                title: callController.micOn ? "Mute Microphone" : "Unmute Microphone",
                symbol: callController.micOn ? "mic.slash.fill" : "mic.fill",
                action: #selector(toggleMic)))
            menu.addItem(makeItem(
                title: callController.cameraOn ? "Turn Camera Off" : "Turn Camera On",
                symbol: callController.cameraOn ? "video.slash.fill" : "video.fill",
                action: #selector(toggleCamera)))
            menu.addItem(makeItem(
                title: callController.sharingScreen ? "Stop Sharing Screen" : "Share My Screen",
                symbol: "rectangle.inset.filled.and.person.filled",
                action: #selector(toggleScreenShare)))
            menu.addItem(.separator())
            let hangUp = makeItem(title: "Hang Up", symbol: "phone.down.fill", action: #selector(hangUp))
            menu.addItem(hangUp)

        case .dialing(let peerName):
            let header = NSMenuItem(title: "Calling \(peerName)…", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(makeItem(title: "Cancel Call", symbol: "phone.down.fill", action: #selector(hangUp)))

        case .ringing(let callerName):
            let header = NSMenuItem(title: "\(callerName) is calling…", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

        case .idle:
            let peers = PeerStore.shared.peers
            if peers.isEmpty {
                let empty = NSMenuItem(title: "No peers yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for peer in peers {
                    let item = NSMenuItem(title: "Call \(peer.name)", action: #selector(callPeer(_:)), keyEquivalent: "")
                    item.target = self
                    item.image = Self.presenceDot(online: PresenceStore.shared.online[peer.host])
                    item.representedObject = peer.id
                    menu.addItem(item)
                    presenceItems[peer.host] = item
                }
                PresenceStore.shared.refresh(hosts: peers.map(\.host))
                menu.addItem(.separator())
                let removeMenu = NSMenu()
                for peer in peers {
                    let item = NSMenuItem(title: "\(peer.name) (\(peer.host))", action: #selector(removePeer(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = peer.id
                    removeMenu.addItem(item)
                }
                let removeItem = NSMenuItem(title: "Remove Peer", action: nil, keyEquivalent: "")
                removeItem.submenu = removeMenu
                menu.addItem(removeItem)
            }
            menu.addItem(makeItem(title: "Add Peer…", symbol: "plus", action: #selector(addPeer)))
        }

        menu.addItem(.separator())
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let quit = NSMenuItem(title: "Quit Pairwise", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makeItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // MARK: - Actions

    @objc private func callPeer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let peer = PeerStore.shared.peers.first(where: { $0.id == id }) else { return }
        callController.call(peer: peer)
    }

    @objc private func removePeer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        PeerStore.shared.remove(id: id)
    }

    @objc private func addPeer() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Peer"
        alert.informativeText = "Enter a name and the peer's IP address (they need Pairwise running)."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 240, height: 58))
        stack.orientation = .vertical
        stack.spacing = 8
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameField.placeholderString = "Name"
        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        hostField.placeholderString = "IP address (e.g. 192.168.1.42)"
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(hostField)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !host.isEmpty {
                PeerStore.shared.add(name: name, host: host)
            }
        }
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    @objc private func toggleMic() { callController.toggleMic() }
    @objc private func toggleCamera() { callController.toggleCamera() }
    @objc private func toggleScreenShare() { callController.toggleScreenShare() }
    @objc private func hangUp() { callController.hangUp() }
    @objc private func quit() {
        callController.hangUp()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

// Child-process probe for voice-processing availability (see AudioPipeline).
if ProcessInfo.processInfo.environment["PAIRWISE_VP_PROBE"] == "1" {
    AudioPipeline.runVoiceProcessingProbe()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
