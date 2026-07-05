import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let callController = CallController()
    private var presenceItems: [String: NSMenuItem] = [:]  // peer presenceKey → menu line
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var selfTestPipeline: AudioPipeline?
    private var selfTestTransport: MediaTransport?

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
            // 8s: long enough for the AEC watchdog (2.5s after engine start)
            // to fire and the fallback engine to accumulate audible capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let result = "AUDIO_SELFTEST: \(frames) encoded frames, \(pipeline.debugTapCount) tap callbacks, capture rms \(String(format: "%.6f", pipeline.debugCaptureRMS)) in 8s"
                NSLog("Pairwise: %@", result)
                try? result.write(toFile: "/tmp/pairwise_selftest.txt", atomically: true, encoding: .utf8)
                pipeline.stop()
                exit(frames > 0 ? 0 : 1)
            }
            return
        }
        // Headless hole-punch smoke test: prints this machine's media
        // candidates (LAN + STUN public mapping) and exits.
        if ProcessInfo.processInfo.environment["PAIRWISE_STUN_SELFTEST"] == "1" {
            let transport = MediaTransport()
            selfTestTransport = transport
            transport.start()
            HolePuncher.gatherCandidates(transport: transport) { candidates in
                print("STUN_SELFTEST: \(candidates.map { "\($0.ip):\($0.port)" }.joined(separator: ", "))")
                exit(candidates.isEmpty ? 1 : 0)
            }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.pear
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
            for (key, item) in self.presenceItems {
                item.image = Self.presenceDot(online: PresenceStore.shared.online[key])
            }
        }

        // Warm the voice-processing probe so call audio starts instantly.
        DispatchQueue.global(qos: .utility).async { AudioPipeline.warmUpProbe() }
    }

    private func refreshStatusIcon() {
        switch callController.state {
        case .idle:
            statusItem.button?.image = MenuBarIcon.pear
        case .dialing, .ringing:
            statusItem.button?.image = NSImage(systemSymbolName: "phone.badge.waveform.fill",
                                               accessibilityDescription: "Pairwise")
        case .inCall:
            statusItem.button?.image = NSImage(systemSymbolName: "phone.connection.fill",
                                               accessibilityDescription: "Pairwise")
        }
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
                    item.image = Self.presenceDot(online: PresenceStore.shared.online[peer.presenceKey])
                    item.representedObject = peer.id
                    menu.addItem(item)
                    presenceItems[peer.presenceKey] = item

                    // Holding ⌥ flips the call line into a remove action.
                    let remove = NSMenuItem(title: "Remove \(peer.name)", action: #selector(removePeer(_:)), keyEquivalent: "")
                    remove.target = self
                    remove.representedObject = peer.id
                    remove.isAlternate = true
                    remove.keyEquivalentModifierMask = .option
                    remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                    menu.addItem(remove)
                }
                // Code peers get presence pushed from their rendezvous room.
                PresenceStore.shared.refresh(hosts: peers.filter { $0.code == nil }.map(\.host))
                menu.addItem(.separator())
            }
            menu.addItem(makeItem(title: "Add Peer…", symbol: "plus", action: #selector(addPeer)))
        }

        menu.addItem(.separator())
        menu.addItem(microphoneItem())
        menu.addItem(cameraItem())
        menu.addItem(shareResolutionItem())

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

    // MARK: - Device settings menus

    private func microphoneItem() -> NSMenuItem {
        let sub = NSMenu()
        let selected = DeviceSettings.micUID
        let def = NSMenuItem(title: "System Default", action: #selector(selectMic(_:)), keyEquivalent: "")
        def.target = self
        def.state = selected == nil ? .on : .off
        sub.addItem(def)
        let devices = AudioInputDevices.all()
        if !devices.isEmpty { sub.addItem(.separator()) }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = selected == device.uid ? .on : .off
            sub.addItem(item)
        }
        let root = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        root.submenu = sub
        return root
    }

    private func cameraItem() -> NSMenuItem {
        let sub = NSMenu()
        let selected = DeviceSettings.cameraUID
        let auto = NSMenuItem(title: "Automatic", action: #selector(selectCamera(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = selected == nil ? .on : .off
        sub.addItem(auto)
        let cameras = CameraCapture.availableCameras()
        if !cameras.isEmpty { sub.addItem(.separator()) }
        for camera in cameras {
            let item = NSMenuItem(title: camera.name, action: #selector(selectCamera(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = camera.uid
            item.state = selected == camera.uid ? .on : .off
            sub.addItem(item)
        }
        let root = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        root.submenu = sub
        return root
    }

    private static let shareResolutionChoices: [(title: String, cap: Int)] = [
        ("Native", 0),
        ("High (2560 px)", 2560),
        ("Medium (1920 px)", 1920),
        ("Low (1280 px)", 1280),
    ]

    private func shareResolutionItem() -> NSMenuItem {
        let sub = NSMenu()
        let selected = DeviceSettings.screenShareMaxDimension
        for choice in Self.shareResolutionChoices {
            let item = NSMenuItem(title: choice.title, action: #selector(selectShareResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.cap
            item.state = selected == choice.cap ? .on : .off
            sub.addItem(item)
        }
        let root = NSMenuItem(title: "Screen Share Resolution", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "square.resize", accessibilityDescription: nil)
        root.submenu = sub
        return root
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        DeviceSettings.micUID = sender.representedObject as? String
        callController.micDeviceChanged()
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        DeviceSettings.cameraUID = sender.representedObject as? String
        callController.cameraDeviceChanged()
    }

    @objc private func selectShareResolution(_ sender: NSMenuItem) {
        DeviceSettings.screenShareMaxDimension = (sender.representedObject as? Int) ?? 2560
        callController.screenShareResolutionChanged()
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
        alert.informativeText = "Enter a name, plus either the peer's IP address or a shared code you both add (any word you agree on, e.g. ben-jerome)."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 240, height: 58))
        stack.orientation = .vertical
        stack.spacing = 8
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameField.placeholderString = "Name"
        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        hostField.placeholderString = "IP address or shared code"
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(hostField)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let target = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !target.isEmpty {
                // Dots/colons mean an address (IPv4, IPv6, hostname); anything
                // else is treated as a rendezvous room code.
                if target.contains(".") || target.contains(":") {
                    PeerStore.shared.add(name: name, host: target)
                } else {
                    PeerStore.shared.add(name: name, host: "", code: target.lowercased())
                }
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
