import Foundation

/// Signaling transport a call runs over: TCP direct to the peer's IP
/// (ControlChannel) or relayed through the rendezvous worker (RelayChannel).
protocol SignalingChannel: AnyObject {
    var onMessage: ((ControlMessage) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    /// Peer's IP for direct channels; informational for relay channels.
    var remoteHost: String { get }
    /// Relay calls carry hole-punch candidates and skip direct-IP wiring.
    var isRelay: Bool { get }
    func send(_ message: ControlMessage)
    func close()
}

extension ControlChannel: SignalingChannel {
    var isRelay: Bool { false }
}

enum RendezvousConfig {
    /// The deployed worker (server/ in this repo). Overridable for testing:
    /// `defaults write dev.benborgers.pairwise pairwise.rendezvousURL wss://...`
    static var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "pairwise.rendezvousURL"),
           let url = URL(string: s) {
            return url
        }
        return URL(string: "wss://pairwise-rendezvous.benborgers.workers.dev")!
    }

    /// Stable per-install ID so the server can tell a reconnect from a
    /// second machine trying to join the room.
    static var clientID: String {
        let key = "pairwise.clientID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

/// Persistent WebSocket to one rendezvous room (one per room-code peer).
/// Provides presence (is the other side connected?) and relays
/// ControlMessages during ring + call. Reconnects forever with backoff.
final class RendezvousClient: NSObject {
    let code: String

    /// Main thread: other-side presence changed (for the menu dot).
    var onPresenceChanged: (() -> Void)?
    /// Main thread: a signal arrived while no call channel exists —
    /// normally an invite that should start a ring.
    var onIncomingSignal: ((ControlMessage) -> Void)?

    private(set) var peerPresent = false

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .ephemeral)
    private var shutDown = false
    private var reconnectDelay: TimeInterval = 1
    private var reconnectScheduled = false
    private var keepaliveTimer: Timer?
    private weak var channel: RelayChannel?
    /// Pending "the call is dead" verdict; a rejoin within the grace period
    /// (peer's WS blipped, ours reconnected) cancels it.
    private var channelDeathTimer: DispatchWorkItem?

    private static let channelDeathGrace: TimeInterval = 12

    init(code: String) {
        self.code = code
        super.init()
    }

    // MARK: - Connection lifecycle

    func connect() {
        guard !shutDown, task == nil else { return }
        var components = URLComponents(url: RendezvousConfig.baseURL.appendingPathComponent("room/\(code)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: Identity.systemName),
            URLQueryItem(name: "id", value: RendezvousConfig.clientID),
        ]
        let t = session.webSocketTask(with: components.url!)
        task = t
        t.resume()
        receiveLoop(t)
        DispatchQueue.main.async { [weak self] in self?.startKeepalive() }
        PWLog("rendezvous[\(code)]: connecting")
    }

    /// Permanently stop (peer removed). The room stays available for the
    /// other side; we just leave.
    func shutdown() {
        shutDown = true
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        // The worker answers without waking the Durable Object; this keeps
        // NAT/edge idle timers from reaping the socket.
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.task?.send(.string(#"{"type":"ping"}"#)) { _ in }
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, self.task === t else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    DispatchQueue.main.async { self.handle(text) }
                }
                self.receiveLoop(t)
            case .failure(let error):
                DispatchQueue.main.async { self.handleDisconnect(error) }
            }
        }
    }

    private func handleDisconnect(_ error: Error) {
        guard !shutDown else { return }
        task = nil
        setPeerPresent(false)
        scheduleChannelDeath()
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        PWLog("rendezvous[\(code)]: disconnected (\((error as NSError).code)), retrying in \(Int(reconnectDelay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.reconnectDelay = min(self.reconnectDelay * 2, 15)
            self.connect()
        }
    }

    // MARK: - Server messages (main thread)

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "peers":
            reconnectDelay = 1  // a served message means the connection is good
            let peers = obj["peers"] as? [[String: Any]] ?? []
            setPeerPresent(!peers.isEmpty)
        case "joined":
            setPeerPresent(true)
        case "left":
            setPeerPresent(false)
            scheduleChannelDeath()
        case "signal":
            guard let payload = obj["payload"],
                  let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                  let msg = try? JSONDecoder().decode(ControlMessage.self, from: payloadData) else { return }
            if let channel {
                channel.deliver(msg)
            } else {
                onIncomingSignal?(msg)
            }
        default:
            break
        }
    }

    private func setPeerPresent(_ present: Bool) {
        if present {
            channelDeathTimer?.cancel()
            channelDeathTimer = nil
        }
        guard peerPresent != present else { return }
        peerPresent = present
        PWLog("rendezvous[\(code)]: peer \(present ? "online" : "offline")")
        onPresenceChanged?()
    }

    /// The peer vanished (or we lost the server). If a call is up, give the
    /// connection a grace period to come back before ending it — media is
    /// P2P and unaffected by a signaling blip.
    private func scheduleChannelDeath() {
        guard channel != nil, channelDeathTimer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.channelDeathTimer = nil
            self.channel?.declareClosed()
        }
        channelDeathTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.channelDeathGrace, execute: work)
    }

    // MARK: - Signaling

    func sendSignal(_ message: ControlMessage) {
        guard let payloadData = try? JSONEncoder().encode(message),
              let payloadObj = try? JSONSerialization.jsonObject(with: payloadData),
              let data = try? JSONSerialization.data(withJSONObject: ["type": "signal", "payload": payloadObj]),
              let text = String(data: data, encoding: .utf8) else { return }
        guard let task else {
            PWLog("rendezvous[\(code)]: dropped signal while disconnected")
            return
        }
        task.send(.string(text)) { [weak self] error in
            if let error, let self {
                PWLog("rendezvous[\(self.code)]: send failed: \(error.localizedDescription)")
            }
        }
    }

    func makeChannel() -> RelayChannel {
        let ch = RelayChannel(client: self)
        channel = ch
        return ch
    }

    fileprivate func channelWentAway(_ ch: RelayChannel) {
        guard channel === ch else { return }
        channel = nil
        channelDeathTimer?.cancel()
        channelDeathTimer = nil
    }
}

/// A call's signaling channel over the rendezvous relay. Thin adapter: the
/// underlying room socket outlives the call (it also carries presence).
final class RelayChannel: SignalingChannel {
    var onMessage: ((ControlMessage) -> Void)?
    var onClosed: (() -> Void)?
    let remoteHost = "rendezvous"
    var isRelay: Bool { true }

    private weak var client: RendezvousClient?
    private var closed = false

    init(client: RendezvousClient) {
        self.client = client
    }

    func send(_ message: ControlMessage) {
        guard !closed else { return }
        client?.sendSignal(message)
    }

    func close() {
        guard !closed else { return }
        closed = true
        client?.channelWentAway(self)
    }

    /// Main thread; the peer left the room (beyond grace) — surface as a
    /// normal channel close so the call tears down.
    func declareClosed() {
        guard !closed else { return }
        closed = true
        client?.channelWentAway(self)
        onClosed?()
    }

    fileprivate func deliver(_ message: ControlMessage) {
        guard !closed else { return }
        onMessage?(message)
    }
}
