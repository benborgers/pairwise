import Foundation
import Network

/// Reliable signaling channel: length-prefixed JSON over TCP.
/// One side listens (always, for incoming calls); the caller dials.
final class ControlChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "pairwise.control")
    var onMessage: ((ControlMessage) -> Void)?
    var onClosed: (() -> Void)?
    private var closed = false

    /// Remote host, for wiring the media channel to the same peer.
    let remoteHost: String

    init(connection: NWConnection, remoteHost: String) {
        self.connection = connection
        self.remoteHost = remoteHost
    }

    static func dial(host: String, completion: @escaping (Result<ControlChannel, Error>) -> Void) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Ports.control)!)
        let params = NWParameters.tcp
        params.serviceClass = .responsiveData
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
        }
        let conn = NWConnection(to: endpoint, using: params)
        let channel = ControlChannel(connection: conn, remoteHost: host)
        var completed = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !completed { completed = true; completion(.success(channel)) }
            case .failed(let err):
                if !completed { completed = true; completion(.failure(err)) }
                else { channel.handleClosed() }
            case .waiting(let err):
                // NWConnection parks unreachable dials in .waiting and retries
                // forever; surface the failure instead of ringing into the void.
                if !completed {
                    completed = true
                    conn.cancel()
                    completion(.failure(err))
                }
            case .cancelled:
                channel.handleClosed()
            default: break
            }
        }
        conn.start(queue: channel.queue)
        channel.receiveLoop()
        return
    }

    /// Wrap an accepted inbound connection.
    static func accept(_ conn: NWConnection) -> ControlChannel {
        var host = "unknown"
        if case let .hostPort(h, _) = conn.endpoint {
            host = "\(h)"
            // Strip IPv6 scope suffix like "%en0"
            if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
        }
        let channel = ControlChannel(connection: conn, remoteHost: host)
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: channel.handleClosed()
            default: break
            }
        }
        conn.start(queue: channel.queue)
        channel.receiveLoop()
        return channel
    }

    func send(_ message: ControlMessage) {
        guard let body = try? JSONEncoder().encode(message) else { return }
        var frame = Data()
        frame.appendBE(UInt32(body.count))
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        closed = true
        connection.cancel()
    }

    private func handleClosed() {
        guard !closed else { return }
        closed = true
        DispatchQueue.main.async { self.onClosed?() }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 4, error == nil else {
                self?.handleClosed(); return
            }
            let length = Int(data.readBE(UInt32.self, at: 0))
            guard length > 0, length < 4_000_000 else { self.handleClosed(); return }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self, let body, body.count == length, error == nil else {
                    self?.handleClosed(); return
                }
                if let msg = try? JSONDecoder().decode(ControlMessage.self, from: body) {
                    DispatchQueue.main.async { self.onMessage?(msg) }
                }
                self.receiveLoop()
            }
        }
    }
}

/// Always-on TCP listener for incoming calls.
final class ControlListener {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pairwise.control.listener")
    var onIncoming: ((ControlChannel) -> Void)?

    func start() {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Ports.control)!) else {
            NSLog("Pairwise: failed to open control listener on \(Ports.control)")
            return
        }
        listener.newConnectionHandler = { [weak self] conn in
            let channel = ControlChannel.accept(conn)
            DispatchQueue.main.async { self?.onIncoming?(channel) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                NSLog("Pairwise: control listener failed: \(err)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }
}
