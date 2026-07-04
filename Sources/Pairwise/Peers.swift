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

/// Fallback name sent in invites, shown only when the receiver has no locally
/// stored name for the caller's address.
enum Identity {
    static var systemName: String {
        NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    }
}
