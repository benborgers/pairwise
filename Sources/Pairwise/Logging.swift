import Foundation

/// File-backed logging: unified log drops NSLog output from ad-hoc-signed
/// apps, so diagnostics go to ~/Library/Logs/Pairwise.log where they can
/// actually be read (and texted by remote testers).
func PWLog(_ message: String) {
    NSLog("Pairwise: %@", message)
    PWLogFile.shared.append(message)
}

final class PWLogFile {
    static let shared = PWLogFile()
    private let queue = DispatchQueue(label: "pairwise.logfile", qos: .utility)
    private var handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        let url = dir.appendingPathComponent("Pairwise.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        append("---- Pairwise launched (pid \(ProcessInfo.processInfo.processIdentifier)) ----")
    }

    func append(_ message: String) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            let line = "\(self.formatter.string(from: Date())) \(message)\n"
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}

/// Rate-limited counter: logs on the 1st event and every `every`-th after.
final class PWCounter {
    private var count = 0
    private let label: String
    private let every: Int

    init(_ label: String, every: Int) {
        self.label = label
        self.every = every
    }

    /// Returns the new count; logs when due.
    @discardableResult
    func tick(_ detail: @autoclosure () -> String = "") -> Int {
        count += 1
        if count == 1 || count % every == 0 {
            let d = detail()
            PWLog("\(label): \(count)\(d.isEmpty ? "" : " (\(d))")")
        }
        return count
    }

    var value: Int { count }
}
