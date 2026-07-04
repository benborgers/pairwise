import Foundation

// MARK: - Ports

enum Ports {
    static let control: UInt16 = 47800  // TCP: signaling, state, annotations
    static let media: UInt16 = 47801    // UDP: audio / camera / screen frames
}

// MARK: - Control channel messages (length-prefixed JSON over TCP)

enum ControlMessage: Codable {
    case invite(name: String)
    case accept(name: String)
    case decline
    case hangup
    case state(cameraOn: Bool, micOn: Bool, sharingScreen: Bool, screenAspect: Double)
    case annotationStroke(points: [AnnotationPoint], colorIndex: Int, strokeID: UInt64)
    case ping
    case pong

    private enum CodingKeys: String, CodingKey {
        case type, name, cameraOn, micOn, sharingScreen, screenAspect, points, colorIndex, strokeID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "invite":
            self = .invite(name: try c.decode(String.self, forKey: .name))
        case "accept":
            self = .accept(name: try c.decode(String.self, forKey: .name))
        case "decline":
            self = .decline
        case "hangup":
            self = .hangup
        case "state":
            self = .state(
                cameraOn: try c.decode(Bool.self, forKey: .cameraOn),
                micOn: try c.decode(Bool.self, forKey: .micOn),
                sharingScreen: try c.decode(Bool.self, forKey: .sharingScreen),
                screenAspect: try c.decodeIfPresent(Double.self, forKey: .screenAspect) ?? 1.6
            )
        case "annotationStroke":
            self = .annotationStroke(
                points: try c.decode([AnnotationPoint].self, forKey: .points),
                colorIndex: try c.decode(Int.self, forKey: .colorIndex),
                strokeID: try c.decode(UInt64.self, forKey: .strokeID)
            )
        case "ping": self = .ping
        case "pong": self = .pong
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown type \(type)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .invite(let name):
            try c.encode("invite", forKey: .type)
            try c.encode(name, forKey: .name)
        case .accept(let name):
            try c.encode("accept", forKey: .type)
            try c.encode(name, forKey: .name)
        case .decline:
            try c.encode("decline", forKey: .type)
        case .hangup:
            try c.encode("hangup", forKey: .type)
        case .state(let cameraOn, let micOn, let sharingScreen, let screenAspect):
            try c.encode("state", forKey: .type)
            try c.encode(cameraOn, forKey: .cameraOn)
            try c.encode(micOn, forKey: .micOn)
            try c.encode(sharingScreen, forKey: .sharingScreen)
            try c.encode(screenAspect, forKey: .screenAspect)
        case .annotationStroke(let points, let colorIndex, let strokeID):
            try c.encode("annotationStroke", forKey: .type)
            try c.encode(points, forKey: .points)
            try c.encode(colorIndex, forKey: .colorIndex)
            try c.encode(strokeID, forKey: .strokeID)
        case .ping: try c.encode("ping", forKey: .type)
        case .pong: try c.encode("pong", forKey: .type)
        }
    }
}

/// Annotation coordinates normalized to [0,1] in the shared screen's space.
/// Origin: top-left.
struct AnnotationPoint: Codable {
    var x: Double
    var y: Double
}

// MARK: - Media packet format (UDP)
//
// All multi-byte fields big-endian.
//
//   0  u16  magic 0x5057 ("PW")
//   2  u8   stream (0 audio, 1 camera, 2 screen)
//   3  u8   flags (bit0: keyframe)
//   4  u32  frame sequence number
//   8  u16  fragment index
//  10  u16  fragment count
//  12  u64  capture timestamp, microseconds
//  20  ...  payload
//
// Video keyframe payloads are prefixed with parameter sets:
//   u8 count, then per set: u16 length + bytes. Frame data (AVCC,
//   4-byte-length-prefixed NALUs) follows. Delta frames are raw AVCC.

enum MediaStream: UInt8 {
    case audio = 0
    case camera = 1
    case screen = 2
}

struct MediaPacket {
    static let magic: UInt16 = 0x5057
    static let headerSize = 20
    /// Payload budget per datagram; keeps datagrams under typical MTU.
    static let maxPayload = 1200

    var stream: MediaStream
    var isKeyframe: Bool
    var sequence: UInt32
    var fragmentIndex: UInt16
    var fragmentCount: UInt16
    var timestampUs: UInt64
    var payload: Data

    func serialize() -> Data {
        var d = Data(capacity: MediaPacket.headerSize + payload.count)
        d.appendBE(MediaPacket.magic)
        d.append(stream.rawValue)
        d.append(isKeyframe ? 1 : 0)
        d.appendBE(sequence)
        d.appendBE(fragmentIndex)
        d.appendBE(fragmentCount)
        d.appendBE(timestampUs)
        d.append(payload)
        return d
    }

    static func parse(_ d: Data) -> MediaPacket? {
        guard d.count >= headerSize else { return nil }
        guard d.readBE(UInt16.self, at: 0) == magic else { return nil }
        guard let stream = MediaStream(rawValue: d[d.startIndex + 2]) else { return nil }
        let flags = d[d.startIndex + 3]
        return MediaPacket(
            stream: stream,
            isKeyframe: flags & 1 != 0,
            sequence: d.readBE(UInt32.self, at: 4),
            fragmentIndex: d.readBE(UInt16.self, at: 8),
            fragmentCount: d.readBE(UInt16.self, at: 10),
            timestampUs: d.readBE(UInt64.self, at: 12),
            payload: d.subdata(in: (d.startIndex + headerSize)..<d.endIndex)
        )
    }

    /// Split a full frame into MTU-sized packets.
    static func packetize(stream: MediaStream, isKeyframe: Bool, sequence: UInt32,
                          timestampUs: UInt64, frame: Data) -> [Data] {
        let count = max(1, (frame.count + maxPayload - 1) / maxPayload)
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let lo = i * maxPayload
            let hi = min(frame.count, lo + maxPayload)
            let pkt = MediaPacket(
                stream: stream, isKeyframe: isKeyframe, sequence: sequence,
                fragmentIndex: UInt16(i), fragmentCount: UInt16(count),
                timestampUs: timestampUs,
                payload: frame.subdata(in: frame.index(frame.startIndex, offsetBy: lo)..<frame.index(frame.startIndex, offsetBy: hi))
            )
            out.append(pkt.serialize())
        }
        return out
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    func readBE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var v: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            copyBytes(to: dst, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size))
        }
        return T(bigEndian: v)
    }
}
