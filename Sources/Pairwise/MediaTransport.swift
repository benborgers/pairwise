import Foundation
import Darwin
import Security

/// A complete, reassembled media frame.
struct MediaFrame {
    var stream: MediaStream
    var isKeyframe: Bool
    var sequence: UInt32
    var timestampUs: UInt64
    var data: Data
}

/// UDP media transport over a plain BSD socket for minimum overhead.
/// Both peers bind Ports.media and exchange datagrams directly (true P2P).
final class MediaTransport {
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "pairwise.media.recv", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "pairwise.media.send", qos: .userInteractive)
    private var remoteAddr: sockaddr_in?

    var onFrame: ((MediaFrame) -> Void)?
    /// Fired (on an internal queue) when the peer asks for a fresh keyframe.
    var onKeyframeRequest: ((MediaStream) -> Void)?
    /// Fired (on an internal queue) for hole-punch probes/acks, with the
    /// sender's observed source address. Set only while a punch is running.
    var onPunchPacket: ((_ isAck: Bool, _ ip: String, _ port: UInt16) -> Void)?

    private var reassembly: [UInt8: [UInt32: PartialFrame]] = [:]
    private var lastDelivered: [UInt8: UInt32] = [:]

    private let sendCounters: [UInt8: PWCounter] = [
        0: PWCounter("udp sent audio frames", every: 500),
        1: PWCounter("udp sent camera frames", every: 100),
        2: PWCounter("udp sent screen frames", every: 200),
    ]
    private let recvCounters: [UInt8: PWCounter] = [
        0: PWCounter("udp recv audio frames", every: 500),
        1: PWCounter("udp recv camera frames", every: 100),
        2: PWCounter("udp recv screen frames", every: 200),
    ]
    private let recvPacketCounter = PWCounter("udp recv datagrams", every: 2000)
    private let kfReqOutCounter = PWCounter("keyframe requests sent", every: 10)
    private let kfReqInCounter = PWCounter("keyframe requests received", every: 10)

    private struct PartialFrame {
        var fragments: [Data?]
        var received: Int
        var isKeyframe: Bool
        var timestampUs: UInt64
        var createdAt: UInt64  // mach time ns
    }

    // Special stream bytes for in-band non-media packets.
    private static let keyframeRequestStream: UInt8 = 200
    private static let punchProbeStream: UInt8 = 201
    private static let punchAckStream: UInt8 = 202

    // Pending STUN queries: transaction ID → completion (receive queue).
    private var stunCompletions: [Data: (String, UInt16) -> Void] = [:]
    // Last keyframe request per stream, for throttling (receive queue).
    private var lastKfRequestNs: [UInt8: UInt64] = [:]

    func start() {
        guard fd < 0 else { return }  // idempotent: rendezvous calls start early
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { PWLog("UDP socket failed"); return }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bufSize: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Ports.media.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            PWLog("UDP bind FAILED: \(String(cString: strerror(errno)))")
            close(fd); fd = -1
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainSocket() }
        source.resume()
        readSource = source
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 { close(fd); fd = -1 }
        queue.async { [weak self] in
            self?.reassembly.removeAll()
            self?.lastDelivered.removeAll()
            self?.stunCompletions.removeAll()
            self?.lastKfRequestNs.removeAll()
        }
        onPunchPacket = nil
        remoteAddr = nil
    }

    /// Resolve a hostname or dotted-quad to an IPv4 address (blocking).
    private static func resolveIPv4(_ host: String) -> in_addr? {
        var resolved = in_addr()
        if inet_pton(AF_INET, host, &resolved) == 1 { return resolved }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let res = result else { return nil }
        defer { freeaddrinfo(result) }
        var out = in_addr()
        res.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            out = sin.pointee.sin_addr
        }
        return out
    }

    private static func makeAddr(_ ip: in_addr, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = ip
        return addr
    }

    /// Point outgoing media at the peer. Direct-IP calls use the default
    /// media port; hole-punched paths pass the NAT-observed port.
    func setRemote(host: String, port: UInt16 = Ports.media) {
        guard let ip = Self.resolveIPv4(host) else {
            PWLog("could not resolve media host \(host)")
            return
        }
        PWLog("media remote set to \(host):\(port)")
        let addr = Self.makeAddr(ip, port: port)
        sendQueue.async { [weak self] in self?.remoteAddr = addr }
    }

    /// Packetize and send a full encoded frame.
    func sendFrame(stream: MediaStream, isKeyframe: Bool, sequence: UInt32,
                   timestampUs: UInt64, data: Data) {
        let packets = MediaPacket.packetize(stream: stream, isKeyframe: isKeyframe,
                                            sequence: sequence, timestampUs: timestampUs, frame: data)
        sendCounters[stream.rawValue]?.tick("seq \(sequence), \(packets.count) pkts, key=\(isKeyframe)")
        sendQueue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            guard var addr = self.remoteAddr else {
                if stream != .audio { PWLog("DROP send \(stream): no remote address set") }
                return
            }
            for pkt in packets {
                pkt.withUnsafeBytes { raw in
                    _ = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(self.fd, raw.baseAddress, raw.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    func requestKeyframe(_ stream: MediaStream) {
        // Called for every frame dropped while desynced (up to 60/s); the
        // sender can't usefully produce keyframes anywhere near that fast.
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastKfRequestNs[stream.rawValue], now &- last < 250_000_000 { return }
        lastKfRequestNs[stream.rawValue] = now
        kfReqOutCounter.tick("stream \(stream)")
        var d = Data()
        d.appendBE(MediaPacket.magic)
        d.append(MediaTransport.keyframeRequestStream)
        d.append(stream.rawValue)
        // Pad to header size so parse-side length checks pass.
        d.append(Data(count: MediaPacket.headerSize - d.count))
        sendQueue.async { [weak self] in
            guard let self, self.fd >= 0, var addr = self.remoteAddr else { return }
            d.withUnsafeBytes { raw in
                _ = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(self.fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    // MARK: - Hole punching

    /// Fire a raw datagram at an arbitrary endpoint (punch probes/acks).
    private func sendRaw(_ d: Data, to addr: sockaddr_in) {
        sendQueue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var a = addr
            d.withUnsafeBytes { raw in
                _ = withUnsafePointer(to: &a) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(self.fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    func sendPunch(ack: Bool, toIP ip: String, port: UInt16) {
        guard let resolved = Self.resolveIPv4(ip) else { return }
        var d = Data()
        d.appendBE(MediaPacket.magic)
        d.append(ack ? MediaTransport.punchAckStream : MediaTransport.punchProbeStream)
        d.append(Data(count: MediaPacket.headerSize - d.count))
        sendRaw(d, to: Self.makeAddr(resolved, port: port))
    }

    // MARK: - STUN (RFC 5389 binding request, IPv4)

    /// Ask public STUN servers what this socket's UDP endpoint looks like
    /// from the internet. Must run on the already-bound media socket so the
    /// discovered mapping is the one the peer's packets will hit.
    func discoverPublicAddress(completion: @escaping ((ip: String, port: UInt16)?) -> Void) {
        let servers: [(String, UInt16)] = [
            ("stun.cloudflare.com", 3478),
            ("stun.l.google.com", 19302),
        ]
        var txID = Data(count: 12)
        txID.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }

        var request = Data()
        request.appendBE(UInt16(0x0001))       // binding request
        request.appendBE(UInt16(0))            // no attributes
        request.appendBE(UInt32(0x2112A442))   // magic cookie
        request.append(txID)

        var done = false
        queue.async { [weak self] in
            guard let self else { return }
            self.stunCompletions[txID] = { ip, port in
                guard !done else { return }
                done = true
                PWLog("STUN: public endpoint \(ip):\(port)")
                DispatchQueue.main.async { completion((ip, port)) }
            }
        }
        for (host, port) in servers {
            sendQueue.async { [weak self] in
                guard let self, self.fd >= 0, let ip = Self.resolveIPv4(host) else { return }
                var addr = Self.makeAddr(ip, port: port)
                request.withUnsafeBytes { raw in
                    _ = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(self.fd, raw.baseAddress, raw.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.stunCompletions[txID] = nil
            guard !done else { return }
            done = true
            PWLog("STUN: no response from any server")
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// Parse a STUN binding success response; returns true if the datagram
    /// was STUN (and thus not a media packet).
    private func handlePossibleStun(_ d: Data) -> Bool {
        guard d.count >= 20, d[d.startIndex] & 0xC0 == 0,
              d.readBE(UInt32.self, at: 4) == 0x2112A442 else { return false }
        let txID = d.subdata(in: (d.startIndex + 8)..<(d.startIndex + 20))
        guard let completion = stunCompletions[txID] else { return true }
        guard d.readBE(UInt16.self, at: 0) == 0x0101 else { return true }  // binding success

        var offset = 20
        while offset + 4 <= d.count {
            let attrType = d.readBE(UInt16.self, at: offset)
            let attrLen = Int(d.readBE(UInt16.self, at: offset + 2))
            let valueStart = offset + 4
            guard valueStart + attrLen <= d.count else { break }
            if attrType == 0x0020, attrLen >= 8, d[d.startIndex + valueStart + 1] == 0x01 {
                // XOR-MAPPED-ADDRESS, IPv4: un-XOR with the magic cookie.
                let port = d.readBE(UInt16.self, at: valueStart + 2) ^ 0x2112
                let raw = d.readBE(UInt32.self, at: valueStart + 4) ^ 0x2112A442
                let ip = "\(raw >> 24).\((raw >> 16) & 0xFF).\((raw >> 8) & 0xFF).\(raw & 0xFF)"
                stunCompletions[txID] = nil
                completion(ip, port)
                return true
            }
            offset = valueStart + (attrLen + 3) & ~3  // attributes pad to 4
        }
        return true
    }

    // MARK: - Receive path

    private func drainSocket() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var src = sockaddr_in()
        while true {
            var slen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &slen)
                }
            }
            guard n > 0 else { break }
            handleDatagram(Data(bytes: buffer, count: n), from: src)
        }
    }

    private func handleDatagram(_ d: Data, from src: sockaddr_in) {
        guard d.count >= MediaPacket.headerSize else { return }
        guard d.readBE(UInt16.self, at: 0) == MediaPacket.magic else {
            _ = handlePossibleStun(d)
            return
        }

        let streamByte = d[d.startIndex + 2]
        if streamByte == MediaTransport.keyframeRequestStream {
            if let s = MediaStream(rawValue: d[d.startIndex + 3]) {
                kfReqInCounter.tick("stream \(s)")
                onKeyframeRequest?(s)
            }
            return
        }
        if streamByte == MediaTransport.punchProbeStream || streamByte == MediaTransport.punchAckStream {
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = src.sin_addr
            inet_ntop(AF_INET, &addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            onPunchPacket?(streamByte == MediaTransport.punchAckStream,
                           String(cString: ipBuf), UInt16(bigEndian: src.sin_port))
            return
        }

        guard let pkt = MediaPacket.parse(d) else { return }
        recvPacketCounter.tick()
        let sKey = pkt.stream.rawValue

        // Drop frames older than what we've already delivered (with wraparound slack).
        if let last = lastDelivered[sKey], pkt.sequence <= last, last - pkt.sequence < 1 << 30 {
            // A large backward jump isn't a stale packet — it's a stream
            // whose encoder was rebuilt and restarted its numbering (current
            // senders carry sequences across rebuilds, but 1.3-and-earlier
            // peers restart at 0). A keyframe far behind us is that restart's
            // first frame; resync instead of dropping video until the new
            // stream catches up. Small backward jumps stay treated as the
            // reordered/duplicate packets they are.
            let backward = last - pkt.sequence
            guard backward >= 1000 || (pkt.isKeyframe && backward >= 30) else { return }
            PWLog("stream \(sKey) sequence reset \(last) -> \(pkt.sequence); resyncing")
            reassembly[sKey] = nil
            lastDelivered[sKey] = nil
        }

        let fragCount = Int(pkt.fragmentCount)
        guard fragCount > 0, Int(pkt.fragmentIndex) < fragCount, fragCount <= 4096 else { return }

        var partial = reassembly[sKey]?[pkt.sequence]
            ?? PartialFrame(fragments: Array(repeating: nil, count: fragCount),
                            received: 0, isKeyframe: pkt.isKeyframe,
                            timestampUs: pkt.timestampUs,
                            createdAt: DispatchTime.now().uptimeNanoseconds)
        guard partial.fragments.count == fragCount else { return }
        if partial.fragments[Int(pkt.fragmentIndex)] == nil {
            partial.fragments[Int(pkt.fragmentIndex)] = pkt.payload
            partial.received += 1
        }
        partial.isKeyframe = partial.isKeyframe || pkt.isKeyframe

        if partial.received == fragCount {
            var whole = Data()
            for f in partial.fragments { whole.append(f!) }
            reassembly[sKey]?[pkt.sequence] = nil
            lastDelivered[sKey] = pkt.sequence
            pruneStale(streamKey: sKey, deliveredSeq: pkt.sequence)
            recvCounters[sKey]?.tick("seq \(pkt.sequence), key=\(partial.isKeyframe)")
            onFrame?(MediaFrame(stream: pkt.stream, isKeyframe: partial.isKeyframe,
                                sequence: pkt.sequence, timestampUs: partial.timestampUs,
                                data: whole))
        } else {
            reassembly[sKey, default: [:]][pkt.sequence] = partial
            // Prune anything that has lingered incomplete for > 1s.
            let now = DispatchTime.now().uptimeNanoseconds
            if let entries = reassembly[sKey], entries.count > 64 {
                reassembly[sKey] = entries.filter { now - $0.value.createdAt < 1_000_000_000 }
            }
        }
    }

    private func pruneStale(streamKey: UInt8, deliveredSeq: UInt32) {
        guard let entries = reassembly[streamKey], !entries.isEmpty else { return }
        reassembly[streamKey] = entries.filter { $0.key > deliveredSeq }
    }
}
