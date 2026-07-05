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
    private let url: URL

    /// The log self-truncates to the newest `maxLines` lines, with some slack
    /// so the rewrite doesn't happen on every append.
    private let maxLines = 1000
    private let truncateSlack = 200
    private var lineCount = 0

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        url = dir.appendingPathComponent("Pairwise.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        truncate()
        append("---- Pairwise launched (pid \(ProcessInfo.processInfo.processIdentifier)) ----")
    }

    func append(_ message: String) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            let line = "\(self.formatter.string(from: Date())) \(message)\n"
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
                self.lineCount += 1
                if self.lineCount > self.maxLines + self.truncateSlack {
                    self.truncate()
                }
            }
        }
    }

    /// Rewrite the file keeping only the newest `maxLines` lines, then reopen
    /// the write handle (the atomic rewrite replaces the underlying file).
    private func truncate() {
        try? handle?.close()
        handle = nil
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
            let kept = lines.suffix(maxLines)
            let out = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
            try? out.data(using: .utf8)?.write(to: url, options: .atomic)
            lineCount = kept.count
        } else {
            lineCount = 0
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
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
