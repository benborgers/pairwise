import Foundation

struct Peer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String  // IP address or hostname (empty for room-code peers)
    /// Rendezvous room code: set for peers reached via the rendezvous worker
    /// (hole-punched P2P) instead of a direct IP.
    var code: String?

    /// Key for presence lookups (direct peers: host; code peers: the room).
    var presenceKey: String { code ?? host }
}

final class PeerStore {
    static let shared = PeerStore()
    private let key = "pairwise.peers"
    private(set) var peers: [Peer] = []
    /// Fired after any add/remove so rendezvous rooms can be (dis)connected.
    var onChanged: (() -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Peer].self, from: data) {
            peers = decoded
        }
    }

    func add(name: String, host: String, code: String? = nil) {
        peers.append(Peer(name: name, host: host, code: code))
        save()
        onChanged?()
    }

    func remove(id: UUID) {
        peers.removeAll { $0.id == id }
        save()
        onChanged?()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Fallback name sent in invites, shown only when the receiver has no locally
/// stored name for the caller's address.
enum Identity {
    static var systemName: String {
        NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    }
}
