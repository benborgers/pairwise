import AppKit
import AVFoundation

/// Owns the whole call lifecycle: signaling, media pipelines, and windows.
final class CallController {
    enum State {
        case idle
        case dialing(peerName: String)
        case ringing(callerName: String)
        case inCall(peerName: String)
    }

    private(set) var state: State = .idle {
        didSet { onStateChanged?() }
    }
    var onStateChanged: (() -> Void)?

    // Signaling
    private let listener = ControlListener()
    private var control: SignalingChannel?
    /// One persistent room connection per code peer (presence + relay).
    private var rendezvous: [String: RendezvousClient] = [:]

    // Media
    private let transport = MediaTransport()
    private var puncher: HolePuncher?
    /// Candidates from a relay invite, held until the user accepts.
    private var pendingRemoteCandidates: [MediaCandidate]?

    /// Where the media stream should go once a call is established.
    private enum MediaDestination {
        case direct(host: String)
        case punch(remoteCandidates: [MediaCandidate])
    }
    private let audio = AudioPipeline()
    private let camera = CameraCapture()
    private var cameraEncoder: VideoEncoder?
    private let screenCapture = ScreenShareCapture()
    private var screenEncoder: VideoEncoder?
    private let cameraUnpacker = VideoFrameUnpacker()
    private let screenUnpacker = VideoFrameUnpacker()
    private var lastCameraSeq: UInt32?
    private var lastScreenSeq: UInt32?
    // Encoders rebuilt mid-call (camera toggle, device change, re-share)
    // must continue the previous sequence numbering — the receiver treats
    // backward-running sequences as stale packets and drops them.
    private var cameraSeqNext: UInt32 = 0
    private var screenSeqNext: UInt32 = 0
    private let cameraOkCounter = PWCounter("camera frames displayed", every: 100)
    private let screenOkCounter = PWCounter("screen frames displayed", every: 100)
    private let cameraDropCounter = PWCounter("camera frames dropped pre-decode", every: 30)
    private let screenDropCounter = PWCounter("screen frames dropped pre-decode", every: 30)

    // UI
    private var videoWindow: VideoWindow?
    private var ringWindow: RingWindow?
    private var outgoingWindow: OutgoingCallWindow?
    private var screenViewer: ScreenViewerWindow?
    private var annotationOverlay: AnnotationOverlayWindow?
    private var shareIndicator: ScreenShareIndicatorWindow?

    // Local toggles
    private(set) var cameraOn = true
    private(set) var micOn = true
    private(set) var sharingScreen = false
    private var remoteSharingScreen = false
    private var remoteCameraOn = true
    private var remoteScreenAspect = 16.0 / 10.0

    init() {
        listener.onIncoming = { [weak self] channel in self?.handleIncoming(channel) }
        listener.start()
        wireTransport()
        syncRendezvousRooms()
        PeerStore.shared.onChanged = { [weak self] in self?.syncRendezvousRooms() }
    }

    // MARK: - Rendezvous rooms

    /// Keep one live room connection per code peer so incoming calls ring
    /// and the menu shows presence; drop rooms whose peer was removed.
    private func syncRendezvousRooms() {
        let codes = Set(PeerStore.shared.peers.compactMap(\.code))
        for (code, client) in rendezvous where !codes.contains(code) {
            client.shutdown()
            rendezvous[code] = nil
        }
        for code in codes where rendezvous[code] == nil {
            let client = RendezvousClient(code: code)
            client.onPresenceChanged = { [weak client] in
                guard let client else { return }
                PresenceStore.shared.setOnline(key: client.code, online: client.peerPresent)
            }
            client.onIncomingSignal = { [weak self, weak client] msg in
                guard let self, let client else { return }
                self.handleRelaySignal(client: client, message: msg)
            }
            rendezvous[code] = client
            client.connect()
        }
    }

    private func handleRelaySignal(client: RendezvousClient, message: ControlMessage) {
        guard case .invite(let name, let candidates) = message else { return }
        guard case .idle = state else {
            client.sendSignal(.decline)
            return
        }
        let channel = client.makeChannel()
        control = channel
        pendingRemoteCandidates = candidates
        // Until the call starts, watch for the caller giving up. (TCP calls
        // get this for free from the connection dropping; the relay channel
        // outlives a cancelled ring.)
        channel.onMessage = { [weak self] msg in
            guard let self, case .ringing = self.state, case .hangup = msg else { return }
            self.abortRing(channel)
        }
        channel.onClosed = { [weak self] in
            guard let self, case .ringing = self.state else { return }
            self.abortRing(channel)
        }
        let local = PeerStore.shared.peers.first { $0.code == client.code }?.name
        presentRing(for: channel, callerName: local ?? name)
    }

    private func abortRing(_ channel: SignalingChannel) {
        ringWindow?.stopRinging()
        ringWindow = nil
        channel.close()
        control = nil
        pendingRemoteCandidates = nil
        state = .idle
    }

    // MARK: - Outgoing call

    func call(peer: Peer) {
        guard case .idle = state else { return }

        if let code = peer.code {
            guard let client = rendezvous[code] else { return }
            guard client.peerPresent else {
                showError("\(peer.name) isn't online right now (their Pairwise isn't connected).")
                return
            }
            state = .dialing(peerName: peer.name)
            let outgoing = OutgoingCallWindow(calleeName: peer.name)
            outgoing.onCancel = { [weak self] in self?.hangUp() }
            outgoing.orderFrontRegardless()
            outgoingWindow = outgoing

            // Bind the media socket now: candidates (STUN mapping included)
            // are only meaningful for the socket that will carry media.
            transport.start()
            HolePuncher.gatherCandidates(transport: transport) { [weak self] candidates in
                guard let self, case .dialing = self.state else { return }
                let channel = client.makeChannel()
                self.control = channel
                self.wireControl(channel, peerName: peer.name)
                channel.send(.invite(name: Identity.systemName, candidates: candidates))
            }
            return
        }

        state = .dialing(peerName: peer.name)
        let outgoing = OutgoingCallWindow(calleeName: peer.name)
        outgoing.onCancel = { [weak self] in self?.hangUp() }
        outgoing.orderFrontRegardless()
        outgoingWindow = outgoing

        ControlChannel.dial(host: peer.host) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let channel):
                    guard case .dialing = self.state else { channel.close(); return }
                    self.control = channel
                    self.wireControl(channel, peerName: peer.name)
                    channel.send(.invite(name: Identity.systemName))
                case .failure(let error):
                    self.teardown()
                    self.showError("Couldn't reach \(peer.name): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Incoming call

    private func handleIncoming(_ channel: ControlChannel) {
        guard case .idle = state else {
            channel.send(.decline)
            channel.close()
            return
        }
        // Wait for the invite to learn the caller's name. Prefer the name WE
        // gave this peer when adding them; the name in the invite (the
        // caller's macOS account name) is only a fallback for unknown hosts.
        channel.onMessage = { [weak self] msg in
            guard let self else { return }
            if case .invite(let name, _) = msg {
                let local = PeerStore.shared.peers.first { $0.host == channel.remoteHost }?.name
                self.presentRing(for: channel, callerName: local ?? name)
            }
        }
        channel.onClosed = { [weak self] in
            self?.ringWindow?.stopRinging()
            self?.ringWindow = nil
            if case .ringing = self?.state ?? .idle { self?.state = .idle }
        }
        control = channel
    }

    private func presentRing(for channel: SignalingChannel, callerName: String) {
        state = .ringing(callerName: callerName)
        let ring = RingWindow(callerName: callerName)
        ring.onAccept = { [weak self] in
            guard let self else { return }
            self.ringWindow = nil
            if channel.isRelay {
                // Gather our candidates before accepting so the accept can
                // carry them; then both sides punch simultaneously.
                self.transport.start()
                HolePuncher.gatherCandidates(transport: self.transport) { [weak self] candidates in
                    guard let self, case .ringing = self.state else { return }
                    channel.send(.accept(name: Identity.systemName, candidates: candidates))
                    self.beginCall(peerName: callerName, channel: channel,
                                   media: .punch(remoteCandidates: self.pendingRemoteCandidates ?? []))
                }
            } else {
                channel.send(.accept(name: Identity.systemName))
                self.beginCall(peerName: callerName, channel: channel,
                               media: .direct(host: channel.remoteHost))
            }
        }
        ring.onDecline = { [weak self] in
            guard let self else { return }
            self.ringWindow = nil
            channel.send(.decline)
            channel.close()
            self.control = nil
            self.pendingRemoteCandidates = nil
            self.state = .idle
        }
        ring.startRinging()
        ringWindow = ring
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Established call

    private func wireControl(_ channel: SignalingChannel, peerName: String) {
        channel.onMessage = { [weak self] msg in
            guard let self else { return }
            switch msg {
            case .accept(_, let candidates):
                if case .dialing = self.state {
                    // Keep the name the user entered for this peer; the accept
                    // payload's name is ignored.
                    let media: MediaDestination = channel.isRelay
                        ? .punch(remoteCandidates: candidates ?? [])
                        : .direct(host: channel.remoteHost)
                    self.beginCall(peerName: peerName, channel: channel, media: media)
                }
            case .decline:
                if case .dialing = self.state {
                    self.teardown()
                    self.showError("\(peerName) declined the call.")
                }
            case .hangup:
                self.teardown()
            case .state(let cameraOn, _, let sharingScreen, let screenAspect):
                self.handleRemoteState(cameraOn: cameraOn, sharingScreen: sharingScreen,
                                       screenAspect: screenAspect, peerName: peerName)
            case .annotationStroke(let points, _, let strokeID):
                self.annotationOverlay?.applyStroke(points: points, strokeID: strokeID)
            case .ping:
                channel.send(.pong)
            default:
                break
            }
        }
        channel.onClosed = { [weak self] in
            self?.teardown()
        }
    }

    private func beginCall(peerName: String, channel: SignalingChannel, media: MediaDestination) {
        outgoingWindow?.orderOut(nil)
        outgoingWindow = nil
        state = .inCall(peerName: peerName)
        wireControl(channel, peerName: peerName)

        transport.start()
        switch media {
        case .direct(let host):
            PWLog("call started with \(peerName) at \(host)")
            transport.setRemote(host: host)
        case .punch(let remoteCandidates):
            PWLog("call started with \(peerName) via rendezvous; punching")
            // Media pipelines start now; frames sent before the punch
            // completes are dropped (no remote yet) and recover via the
            // keyframe-request path within a second of the path opening.
            let p = HolePuncher(transport: transport, candidates: remoteCandidates)
            p.onEstablished = { [weak self] _, _ in self?.puncher = nil }
            p.onFailed = { [weak self] in
                guard let self, case .inCall = self.state else { return }
                self.hangUp()
                self.showError("Couldn't establish a direct connection to \(peerName). Both NATs may be blocking UDP hole punching.")
            }
            p.start()
            puncher = p
        }
        pendingRemoteCandidates = nil

        // Audio both ways.
        audio.micEnabled = micOn
        audio.onEncodedFrame = { [weak self] data, seq, ts in
            self?.transport.sendFrame(stream: .audio, isKeyframe: false,
                                      sequence: seq, timestampUs: ts, data: data)
        }
        audio.start()

        // Camera out. Fresh call, fresh sequence spaces (the peer's transport
        // starts empty too).
        cameraSeqNext = 0
        screenSeqNext = 0
        if cameraOn { startCamera() }

        // Peer video window.
        let window = VideoWindow(peerName: peerName)
        window.onHangUp = { [weak self] in self?.hangUp() }
        window.onToggleMic = { [weak self] in self?.toggleMic() }
        window.onToggleCamera = { [weak self] in self?.toggleCamera() }
        window.onToggleScreenShare = { [weak self] in self?.toggleScreenShare() }
        window.orderFrontRegardless()
        videoWindow = window
        refreshVideoWindowControls()

        cameraUnpacker.reset()
        screenUnpacker.reset()
        lastCameraSeq = nil
        lastScreenSeq = nil

        sendLocalState()
    }

    func hangUp() {
        control?.send(.hangup)
        teardown()
    }

    private func teardown() {
        if case .inCall = state { PWLog("call ended") }
        control?.close()
        control = nil
        puncher?.stop()
        puncher = nil
        pendingRemoteCandidates = nil

        audio.stop()
        camera.stop()
        retireCameraEncoder()
        stopScreenShareInternal()
        transport.stop()

        videoWindow?.teardown()
        videoWindow = nil
        ringWindow?.stopRinging()
        ringWindow = nil
        outgoingWindow?.orderOut(nil)
        outgoingWindow = nil
        screenViewer?.close()
        screenViewer = nil
        updateActivationPolicy()
        remoteSharingScreen = false
        remoteCameraOn = true

        state = .idle
    }

    // MARK: - Toggles

    private func refreshVideoWindowControls() {
        videoWindow?.updateControls(micOn: micOn, cameraOn: cameraOn, sharingScreen: sharingScreen)
    }

    func toggleCamera() {
        cameraOn.toggle()
        PWLog("camera toggled \(cameraOn ? "ON" : "OFF")")
        if case .inCall = state {
            if cameraOn { startCamera() } else {
                camera.stop()
                retireCameraEncoder()
            }
            sendLocalState()
        }
        refreshVideoWindowControls()
        onStateChanged?()
    }

    func toggleMic() {
        micOn.toggle()
        audio.micEnabled = micOn
        if case .inCall = state { sendLocalState() }
        refreshVideoWindowControls()
        onStateChanged?()
    }

    func toggleScreenShare() {
        if sharingScreen {
            stopScreenShareInternal()
            sendLocalState()
            refreshVideoWindowControls()
            onStateChanged?()
        } else {
            startScreenShare()
        }
    }

    // MARK: - Device settings

    /// The mic choice is applied when the audio engine is built, so a
    /// mid-call change needs an engine rebuild.
    func micDeviceChanged() {
        guard case .inCall = state else { return }
        audio.restart()
    }

    func cameraDeviceChanged() {
        guard case .inCall = state, cameraOn else { return }
        camera.stop()
        retireCameraEncoder()
        startCamera()
    }

    func screenShareResolutionChanged() {
        guard case .inCall = state, sharingScreen else { return }
        stopScreenShareInternal()
        startScreenShare()
    }

    // MARK: - Camera pipeline

    /// Fold a retiring encoder's sequence position back into the counter the
    /// next encoder will start from, so numbering never runs backward.
    private func retireCameraEncoder() {
        if let encoder = cameraEncoder { cameraSeqNext = encoder.nextSequence }
        cameraEncoder?.invalidate()
        cameraEncoder = nil
    }

    private func startCamera() {
        let encoder = VideoEncoder(config: .init(width: 1280, height: 720, fps: 30,
                                                 bitrate: 1_200_000, keyframeInterval: 2),
                                   firstSequence: cameraSeqNext)
        encoder.onEncodedFrame = { [weak self] data, key, seq, ts in
            self?.transport.sendFrame(stream: .camera, isKeyframe: key,
                                      sequence: seq, timestampUs: ts, data: data)
        }
        cameraEncoder = encoder
        camera.onPixelBuffer = { [weak self] pb, pts in
            self?.cameraEncoder?.encode(pixelBuffer: pb, presentationTime: pts)
        }
        camera.start()
    }

    // MARK: - Screen share pipeline

    private func startScreenShare() {
        guard let screen = NSScreen.main else { return }
        let overlay = AnnotationOverlayWindow(screen: screen)
        overlay.orderFrontRegardless()
        annotationOverlay = overlay

        let indicator = ScreenShareIndicatorWindow(screen: screen)
        indicator.orderFrontRegardless()
        shareIndicator = indicator

        // Local-only chrome stays out of the outgoing stream: annotation
        // strokes, the sharing indicator, and the floating peer-video window
        // (otherwise the viewer sees their own face in the shared screen).
        var excluded: Set<CGWindowID> = [overlay.windowID, indicator.windowID]
        if let videoWindow { excluded.insert(videoWindow.windowID) }
        screenCapture.excludedWindowIDs = excluded

        screenCapture.onPixelBuffer = { [weak self] pb, pts in
            self?.screenEncoder?.encode(pixelBuffer: pb, presentationTime: pts)
        }
        screenCapture.onStopped = { [weak self] in
            guard let self, self.sharingScreen else { return }
            self.stopScreenShareInternal()
            self.sendLocalState()
            self.refreshVideoWindowControls()
            self.onStateChanged?()
        }
        screenCapture.start { [weak self] ok in
            guard let self else { return }
            if ok {
                // The encoder matches what the stream actually captures
                // (which follows the user's resolution setting), with bitrate
                // tiered to the pixel count.
                let size = self.screenCapture.capturedSize
                let longSide = max(size.width, size.height)
                let bitrate = longSide <= 1280 ? 2_500_000 : longSide <= 1920 ? 4_000_000 : 6_000_000
                PWLog("screen share started: capture \(Int(size.width))x\(Int(size.height)), seq from \(self.screenSeqNext)")
                let encoder = VideoEncoder(config: .init(width: Int32(size.width), height: Int32(size.height),
                                                         fps: 60, bitrate: bitrate, keyframeInterval: 4),
                                           firstSequence: self.screenSeqNext)
                encoder.onEncodedFrame = { [weak self] data, key, seq, ts in
                    self?.transport.sendFrame(stream: .screen, isKeyframe: key,
                                              sequence: seq, timestampUs: ts, data: data)
                }
                self.screenEncoder = encoder
                self.sharingScreen = true
                self.sendLocalState()
                self.refreshVideoWindowControls()
            } else {
                self.annotationOverlay?.close()
                self.annotationOverlay = nil
                self.shareIndicator?.close()
                self.shareIndicator = nil
                self.screenEncoder?.invalidate()
                self.screenEncoder = nil
                self.showError("Screen recording permission is required to share your screen. Grant it in System Settings → Privacy & Security → Screen Recording.")
            }
            self.onStateChanged?()
        }
    }

    private func stopScreenShareInternal() {
        if sharingScreen { PWLog("screen share stopped") }
        screenCapture.stop()
        if let encoder = screenEncoder { screenSeqNext = encoder.nextSequence }
        screenEncoder?.invalidate()
        screenEncoder = nil
        annotationOverlay?.close()
        annotationOverlay = nil
        shareIndicator?.close()
        shareIndicator = nil
        sharingScreen = false
    }

    // MARK: - Remote state

    private func handleRemoteState(cameraOn: Bool, sharingScreen: Bool,
                                   screenAspect: Double, peerName: String) {
        PWLog("remote state: camera=\(cameraOn) screen=\(sharingScreen) aspect=\(String(format: "%.2f", screenAspect))")
        remoteCameraOn = cameraOn
        if !cameraOn { videoWindow?.setCameraOff() }
        remoteScreenAspect = screenAspect

        if sharingScreen && !remoteSharingScreen {
            // Only one person shares at a time. A new share takes over: if we
            // were the one sharing, ours stops (the peer does the same when
            // we start while they're sharing).
            if self.sharingScreen {
                PWLog("share taken over by \(peerName); stopping local share")
                stopScreenShareInternal()
                sendLocalState()
                refreshVideoWindowControls()
                onStateChanged?()
            }
            remoteSharingScreen = true
            screenUnpacker.reset()
            lastScreenSeq = nil
            let viewer = ScreenViewerWindow(peerName: peerName, aspect: screenAspect)
            viewer.onStroke = { [weak self] points, strokeID in
                self?.control?.send(.annotationStroke(points: points, colorIndex: 0, strokeID: strokeID))
            }
            screenViewer = viewer
            updateActivationPolicy()
            viewer.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            PWLog("screen viewer opened (aspect \(String(format: "%.2f", screenAspect)))")
        } else if !sharingScreen && remoteSharingScreen {
            remoteSharingScreen = false
            screenViewer?.close()
            screenViewer = nil
            updateActivationPolicy()
            PWLog("screen viewer closed")
        }
    }

    /// A Dock icon exists only while watching a share, so ⌘-tab can reach the
    /// viewer window; the rest of the time Pairwise stays a menu bar app.
    private func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = screenViewer != nil ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func sendLocalState() {
        var aspect = 16.0 / 10.0
        if screenCapture.capturedSize.width > 0 {
            aspect = screenCapture.capturedSize.width / screenCapture.capturedSize.height
        }
        control?.send(.state(cameraOn: cameraOn, micOn: micOn,
                             sharingScreen: sharingScreen, screenAspect: aspect))
    }

    // MARK: - Incoming media

    private func wireTransport() {
        transport.onKeyframeRequest = { [weak self] stream in
            DispatchQueue.main.async {
                switch stream {
                case .camera: self?.cameraEncoder?.forceKeyframe()
                case .screen: self?.screenEncoder?.forceKeyframe()
                case .audio: break
                }
            }
        }
        transport.onFrame = { [weak self] frame in
            guard let self else { return }
            switch frame.stream {
            case .audio:
                self.audio.playReceived(frame.data)
            case .camera:
                // Frames still in flight after the peer said "camera off"
                // would re-hide the placeholder and leave a frozen last frame.
                guard self.remoteCameraOn else { return }
                self.handleVideoFrame(frame, unpacker: self.cameraUnpacker,
                                      lastSeq: &self.lastCameraSeq) { sb in
                    DispatchQueue.main.async { self.videoWindow?.enqueue(sb) }
                }
            case .screen:
                self.handleVideoFrame(frame, unpacker: self.screenUnpacker,
                                      lastSeq: &self.lastScreenSeq) { sb in
                    DispatchQueue.main.async { self.screenViewer?.enqueue(sb) }
                }
            }
        }
    }

    private func handleVideoFrame(_ frame: MediaFrame, unpacker: VideoFrameUnpacker,
                                  lastSeq: inout UInt32?, deliver: (CMSampleBuffer) -> Void) {
        let okCounter = frame.stream == .camera ? cameraOkCounter : screenOkCounter
        let dropCounter = frame.stream == .camera ? cameraDropCounter : screenDropCounter
        // A gap in sequence numbers means we lost a frame; decoding subsequent
        // deltas would corrupt, so resync on the next keyframe.
        if let last = lastSeq, frame.sequence != last &+ 1, !frame.isKeyframe {
            dropCounter.tick("gap \(last)->\(frame.sequence)")
            unpacker.reset()
            lastSeq = nil
            transport.requestKeyframe(frame.stream)
            return
        }
        if unpacker.needsKeyframe && !frame.isKeyframe {
            dropCounter.tick("waiting for keyframe, got seq \(frame.sequence)")
            transport.requestKeyframe(frame.stream)
            return
        }
        lastSeq = frame.sequence
        if let sb = unpacker.unpack(frame: frame) {
            okCounter.tick()
            deliver(sb)
        } else {
            dropCounter.tick("unpack returned nil, seq \(frame.sequence), key=\(frame.isKeyframe)")
        }
    }

    // MARK: - Errors

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Pairwise"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
