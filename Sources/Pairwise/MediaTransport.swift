import Foundation
import Darwin

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

    // Special stream byte for in-band keyframe requests.
    private static let keyframeRequestStream: UInt8 = 200

    func start() {
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
        }
        remoteAddr = nil
    }

    /// Point outgoing media at the peer.
    func setRemote(host: String) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Ports.media.bigEndian
        var resolved = in_addr()
        if inet_pton(AF_INET, host, &resolved) == 1 {
            addr.sin_addr = resolved
        } else {
            // Resolve hostname
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, &hints, &result) == 0, let res = result {
                defer { freeaddrinfo(result) }
                res.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    addr.sin_addr = sin.pointee.sin_addr
                }
            } else {
                PWLog("could not resolve media host \(host)")
                return
            }
        }
        PWLog("media remote set to \(host)")
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

    // MARK: - Receive path

    private func drainSocket() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            handleDatagram(Data(bytes: buffer, count: n))
        }
    }

    private func handleDatagram(_ d: Data) {
        guard d.count >= MediaPacket.headerSize else { return }
        guard d.readBE(UInt16.self, at: 0) == MediaPacket.magic else { return }

        let streamByte = d[d.startIndex + 2]
        if streamByte == MediaTransport.keyframeRequestStream {
            if let s = MediaStream(rawValue: d[d.startIndex + 3]) {
                kfReqInCounter.tick("stream \(s)")
                onKeyframeRequest?(s)
            }
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
