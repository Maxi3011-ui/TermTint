import Foundation

/// Opt-in trace of the hover decisions, for diagnosing "the overlay did not
/// show up" without guessing. Enable with:
///
///     defaults write eu.lecon.termtint debug -bool YES
///
/// Off by default and free when off — nothing is formatted, nothing is written.
enum Log {
    static let isEnabled = UserDefaults.standard.bool(forKey: "debug")

    private static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TermTint.log")
    private static let queue = DispatchQueue(label: "eu.lecon.termtint.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(formatter.string(from: Date()))  \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
