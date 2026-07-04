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
    private var control: ControlChannel?

    // Media
    private let transport = MediaTransport()
    private let audio = AudioPipeline()
    private let camera = CameraCapture()
    private var cameraEncoder: VideoEncoder?
    private let screenCapture = ScreenShareCapture()
    private var screenEncoder: VideoEncoder?
    private let cameraUnpacker = VideoFrameUnpacker()
    private let screenUnpacker = VideoFrameUnpacker()
    private var lastCameraSeq: UInt32?
    private var lastScreenSeq: UInt32?
    private let unpackOkCounter = PWCounter("video frames displayed", every: 100)
    private let unpackDropCounter = PWCounter("video frames dropped pre-decode", every: 30)

    // UI
    private var videoWindow: VideoWindow?
    private var ringWindow: RingWindow?
    private var outgoingWindow: OutgoingCallWindow?
    private var screenViewer: ScreenViewerWindow?
    private var annotationOverlay: AnnotationOverlayWindow?

    // Local toggles
    private(set) var cameraOn = true
    private(set) var micOn = true
    private(set) var sharingScreen = false
    private var remoteSharingScreen = false
    private var remoteScreenAspect = 16.0 / 10.0

    init() {
        listener.onIncoming = { [weak self] channel in self?.handleIncoming(channel) }
        listener.start()
        wireTransport()
    }

    // MARK: - Outgoing call

    func call(peer: Peer) {
        guard case .idle = state else { return }
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
                    channel.send(.invite(name: Identity.displayName))
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
        // Wait for the invite to learn the caller's name.
        channel.onMessage = { [weak self] msg in
            guard let self else { return }
            if case .invite(let name) = msg {
                self.presentRing(for: channel, callerName: name)
            }
        }
        channel.onClosed = { [weak self] in
            self?.ringWindow?.stopRinging()
            self?.ringWindow = nil
            if case .ringing = self?.state ?? .idle { self?.state = .idle }
        }
        control = channel
    }

    private func presentRing(for channel: ControlChannel, callerName: String) {
        state = .ringing(callerName: callerName)
        let ring = RingWindow(callerName: callerName)
        ring.onAccept = { [weak self] in
            guard let self else { return }
            self.ringWindow = nil
            channel.send(.accept(name: Identity.displayName))
            self.beginCall(peerName: callerName, channel: channel)
        }
        ring.onDecline = { [weak self] in
            guard let self else { return }
            self.ringWindow = nil
            channel.send(.decline)
            channel.close()
            self.control = nil
            self.state = .idle
        }
        ring.startRinging()
        ringWindow = ring
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Established call

    private func wireControl(_ channel: ControlChannel, peerName: String) {
        channel.onMessage = { [weak self] msg in
            guard let self else { return }
            switch msg {
            case .accept(let name):
                if case .dialing = self.state {
                    self.beginCall(peerName: name.isEmpty ? peerName : name, channel: channel)
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

    private func beginCall(peerName: String, channel: ControlChannel) {
        outgoingWindow?.orderOut(nil)
        outgoingWindow = nil
        state = .inCall(peerName: peerName)
        PWLog("call started with \(peerName) at \(channel.remoteHost)")
        wireControl(channel, peerName: peerName)

        transport.start()
        transport.setRemote(host: channel.remoteHost)

        // Audio both ways.
        audio.micEnabled = micOn
        audio.onEncodedFrame = { [weak self] data, seq, ts in
            self?.transport.sendFrame(stream: .audio, isKeyframe: false,
                                      sequence: seq, timestampUs: ts, data: data)
        }
        audio.start()

        // Camera out.
        if cameraOn { startCamera() }

        // Peer video window.
        let window = VideoWindow(peerName: peerName)
        window.onHangUp = { [weak self] in self?.hangUp() }
        window.orderFrontRegardless()
        videoWindow = window

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

        audio.stop()
        camera.stop()
        cameraEncoder?.invalidate()
        cameraEncoder = nil
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
        remoteSharingScreen = false

        state = .idle
    }

    // MARK: - Toggles

    func toggleCamera() {
        cameraOn.toggle()
        if case .inCall = state {
            if cameraOn { startCamera() } else {
                camera.stop()
                cameraEncoder?.invalidate()
                cameraEncoder = nil
            }
            sendLocalState()
        }
        onStateChanged?()
    }

    func toggleMic() {
        micOn.toggle()
        audio.micEnabled = micOn
        if case .inCall = state { sendLocalState() }
        onStateChanged?()
    }

    func toggleScreenShare() {
        if sharingScreen {
            stopScreenShareInternal()
            sendLocalState()
            onStateChanged?()
        } else {
            startScreenShare()
        }
    }

    // MARK: - Camera pipeline

    private func startCamera() {
        let encoder = VideoEncoder(config: .init(width: 1280, height: 720, fps: 30,
                                                 bitrate: 1_200_000, keyframeInterval: 2))
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
        screenCapture.excludedWindowIDs = [overlay.windowID]

        let encoder = VideoEncoder(config: .init(width: 2560, height: 1600, fps: 60,
                                                 bitrate: 8_000_000, keyframeInterval: 4))
        encoder.onEncodedFrame = { [weak self] data, key, seq, ts in
            self?.transport.sendFrame(stream: .screen, isKeyframe: key,
                                      sequence: seq, timestampUs: ts, data: data)
        }
        screenEncoder = encoder
        screenCapture.onPixelBuffer = { [weak self] pb, pts in
            self?.screenEncoder?.encode(pixelBuffer: pb, presentationTime: pts)
        }
        screenCapture.onStopped = { [weak self] in
            guard let self, self.sharingScreen else { return }
            self.stopScreenShareInternal()
            self.sendLocalState()
            self.onStateChanged?()
        }
        screenCapture.start { [weak self] ok in
            guard let self else { return }
            if ok {
                self.sharingScreen = true
                self.sendLocalState()
            } else {
                self.annotationOverlay?.close()
                self.annotationOverlay = nil
                self.screenEncoder?.invalidate()
                self.screenEncoder = nil
                self.showError("Screen recording permission is required to share your screen. Grant it in System Settings → Privacy & Security → Screen Recording.")
            }
            self.onStateChanged?()
        }
    }

    private func stopScreenShareInternal() {
        screenCapture.stop()
        screenEncoder?.invalidate()
        screenEncoder = nil
        annotationOverlay?.close()
        annotationOverlay = nil
        sharingScreen = false
    }

    // MARK: - Remote state

    private func handleRemoteState(cameraOn: Bool, sharingScreen: Bool,
                                   screenAspect: Double, peerName: String) {
        PWLog("remote state: camera=\(cameraOn) screen=\(sharingScreen) aspect=\(String(format: "%.2f", screenAspect))")
        if !cameraOn { videoWindow?.setCameraOff() }
        remoteScreenAspect = screenAspect

        if sharingScreen && !remoteSharingScreen {
            remoteSharingScreen = true
            screenUnpacker.reset()
            lastScreenSeq = nil
            let viewer = ScreenViewerWindow(peerName: peerName, aspect: screenAspect)
            viewer.onStroke = { [weak self] points, strokeID in
                self?.control?.send(.annotationStroke(points: points, colorIndex: 0, strokeID: strokeID))
            }
            viewer.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            screenViewer = viewer
        } else if !sharingScreen && remoteSharingScreen {
            remoteSharingScreen = false
            screenViewer?.close()
            screenViewer = nil
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
        // A gap in sequence numbers means we lost a frame; decoding subsequent
        // deltas would corrupt, so resync on the next keyframe.
        if let last = lastSeq, frame.sequence != last &+ 1, !frame.isKeyframe {
            unpackDropCounter.tick("\(frame.stream) gap \(last)->\(frame.sequence)")
            unpacker.reset()
            lastSeq = nil
            transport.requestKeyframe(frame.stream)
            return
        }
        if unpacker.needsKeyframe && !frame.isKeyframe {
            unpackDropCounter.tick("\(frame.stream) waiting for keyframe, got seq \(frame.sequence)")
            transport.requestKeyframe(frame.stream)
            return
        }
        lastSeq = frame.sequence
        if let sb = unpacker.unpack(frame: frame) {
            unpackOkCounter.tick("\(frame.stream)")
            deliver(sb)
        } else {
            unpackDropCounter.tick("\(frame.stream) unpack returned nil, seq \(frame.sequence), key=\(frame.isKeyframe)")
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
