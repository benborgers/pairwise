import Foundation

struct Peer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String  // IP address or hostname
}

final class PeerStore {
    static let shared = PeerStore()
    private let key = "pairwise.peers"
    private(set) var peers: [Peer] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Peer].self, from: data) {
            peers = decoded
        }
    }

    func add(name: String, host: String) {
        peers.append(Peer(name: name, host: host))
        save()
    }

    func remove(id: UUID) {
        peers.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Local display name used when calling out.
enum Identity {
    static var displayName: String {
        if let stored = UserDefaults.standard.string(forKey: "pairwise.displayName"), !stored.isEmpty {
            return stored
        }
        return NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    }

    static func setDisplayName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "pairwise.displayName")
    }

    /// Best-effort local IPv4 addresses for display in the menu:
    /// LAN addresses (en*) first, then Tailscale (100.64/10 on utun*).
    static func localIPv4Addresses() -> [String] {
        var lan: [String] = []
        var tailscale: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            let isEn = name.hasPrefix("en")
            let isUtun = name.hasPrefix("utun")
            guard isEn || isUtun else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            if addr == "127.0.0.1" { continue }
            if isEn {
                lan.append(addr)
            } else if isTailscale(addr) {
                tailscale.append(addr)
            }
        }
        return lan + tailscale
    }

    /// Tailscale hands out addresses in the CGNAT range 100.64.0.0/10.
    static func isTailscale(_ addr: String) -> Bool {
        let parts = addr.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1])
    }
}
