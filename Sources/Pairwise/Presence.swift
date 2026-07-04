import Foundation
import Network

/// Tracks which peers currently have Pairwise running, by attempting a quick
/// TCP connection to their control port. Probes run when the menu opens;
/// results are cached and pushed to the UI as they land.
final class PresenceStore {
    static let shared = PresenceStore()

    /// host → last known reachability.
    private(set) var online: [String: Bool] = [:]
    /// Fired on the main thread whenever any peer's status changes.
    var onChanged: (() -> Void)?

    private var inFlight: Set<String> = []

    func refresh(hosts: [String]) {
        for host in hosts where !inFlight.contains(host) {
            inFlight.insert(host)
            probe(host: host) { [weak self] reachable in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight.remove(host)
                    if self.online[host] != reachable {
                        self.online[host] = reachable
                        self.onChanged?()
                    }
                }
            }
        }
    }

    /// A peer is "online" if something accepts TCP on the Pairwise control
    /// port. The connection is cancelled as soon as it becomes ready — the
    /// remote side just sees a channel open and close before any invite.
    private func probe(host: String, completion: @escaping (Bool) -> Void) {
        let conn = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Ports.control)!),
            using: .tcp)
        var finished = false
        let finish: (Bool) -> Void = { reachable in
            guard !finished else { return }
            finished = true
            conn.cancel()
            completion(reachable)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { finish(false) }
    }
}
