import Foundation
import Darwin

/// UDP hole punching for rendezvous calls: both sides exchange candidate
/// endpoints (LAN IPs + STUN-discovered public mapping) over the rendezvous
/// relay, then fire probe packets at every candidate simultaneously. Each
/// side's outbound probes open its own NAT for the peer's inbound ones; the
/// first candidate that answers becomes the media path.
final class HolePuncher {
    private let transport: MediaTransport
    private let candidates: [MediaCandidate]
    private let queue = DispatchQueue(label: "pairwise.punch")
    private var timer: DispatchSourceTimer?
    private var selected: (ip: String, port: UInt16)?
    private var elapsed = 0.0

    private static let probeInterval = 0.25
    private static let timeout = 10.0
    /// Keep probing briefly after we lock a path so the peer (who may not
    /// have received anything yet) can lock one too.
    private static let lingerAfterSelect = 2.0

    /// Fired once, on the main thread, with the working endpoint (already set
    /// as the transport's remote).
    var onEstablished: ((String, UInt16) -> Void)?
    /// Fired once, on the main thread, if nothing answered within the timeout.
    var onFailed: (() -> Void)?

    init(transport: MediaTransport, candidates: [MediaCandidate]) {
        self.transport = transport
        self.candidates = candidates
    }

    func start() {
        PWLog("punch: starting against \(candidates.map { "\($0.ip):\($0.port)" }.joined(separator: ", "))")
        transport.onPunchPacket = { [weak self] isAck, ip, port in
            guard let self else { return }
            // Any punch packet proves the path works inbound. Answer probes
            // so the peer learns their outbound path works too.
            if !isAck { self.transport.sendPunch(ack: true, toIP: ip, port: port) }
            self.queue.async { self.handleResponse(ip: ip, port: port) }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.probeInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        transport.onPunchPacket = nil
    }

    private func tick() {
        elapsed += Self.probeInterval
        if let sel = selected {
            // Linger: keep answering-by-probing so the peer converges.
            if elapsed >= Self.lingerAfterSelect {
                timer?.cancel()
                timer = nil
                transport.onPunchPacket = nil
            } else {
                transport.sendPunch(ack: false, toIP: sel.ip, port: sel.port)
            }
            return
        }
        if elapsed >= Self.timeout {
            PWLog("punch: FAILED after \(Int(Self.timeout))s")
            timer?.cancel()
            timer = nil
            transport.onPunchPacket = nil
            DispatchQueue.main.async { self.onFailed?() }
            return
        }
        for c in candidates {
            transport.sendPunch(ack: false, toIP: c.ip, port: c.port)
        }
    }

    private func handleResponse(ip: String, port: UInt16) {
        guard selected == nil else { return }
        selected = (ip, port)
        elapsed = 0  // reuse the timer for the linger period
        PWLog("punch: path established via \(ip):\(port)")
        transport.setRemote(host: ip, port: port)
        DispatchQueue.main.async { self.onEstablished?(ip, port) }
    }

    // MARK: - Candidate gathering

    /// Collect this machine's plausible UDP endpoints: every non-loopback
    /// IPv4 interface address at the media port, plus the STUN-discovered
    /// public mapping. Completion on the main thread.
    static func gatherCandidates(transport: MediaTransport,
                                 completion: @escaping ([MediaCandidate]) -> Void) {
        var candidates = localIPv4Addresses().map { MediaCandidate(ip: $0, port: Ports.media) }
        transport.discoverPublicAddress { publicEndpoint in
            if let e = publicEndpoint,
               !candidates.contains(where: { $0.ip == e.ip && $0.port == e.port }) {
                candidates.append(MediaCandidate(ip: e.ip, port: e.port))
            }
            PWLog("punch: local candidates \(candidates.map { "\($0.ip):\($0.port)" }.joined(separator: ", "))")
            completion(candidates)
        }
    }

    private static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var addr = in_addr()
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr = $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            guard !ip.hasPrefix("169.254.") else { continue }  // link-local noise
            if !addresses.contains(ip) { addresses.append(ip) }
        }
        return addresses
    }
}
