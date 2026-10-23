import AppKit

/// Lets other programs on this Mac trigger the two things one would otherwise
/// click: marking a session and fetching the marked ones forward.
///
/// Deliberately the dullest transport there is — a drop folder. A caller
/// writes one line into a file in `~/.termtint/eingang/`, TermTint reads it,
/// acts, and answers in `~/.termtint/antwort/<id>`. No port, no socket,
/// nothing reachable from outside this Mac. The `tools/termtint` script wraps
/// it into a normal command with an exit code.
///
/// Watched through the file system, not polled.
final class CommandInbox {

    enum Outcome {
        case ok(String)
        case notFound
        case ambiguous
    }

    /// Mark or unmark the window belonging to a tty.
    var onMark: ((String, Bool) -> Outcome)?
    /// Fetch every marked window forward; returns how many.
    var onFront: (() -> Int)?

    private let inbox: URL
    private let outbox: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".termtint")
        inbox = base.appendingPathComponent("eingang")
        outbox = base.appendingPathComponent("antwort")
    }

    func start() {
        let manager = FileManager.default
        try? manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? manager.createDirectory(at: outbox, withIntermediateDirectories: true)
        descriptor = open(inbox.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.write("Ablagekorb lässt sich nicht öffnen")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source.resume()
        self.source = source
        Log.write("Ablagekorb bereit: \(inbox.path)")
        drain()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func drain() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        else { return }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? manager.removeItem(at: file)
            run(text.trimmingCharacters(in: .whitespacesAndNewlines),
                id: file.lastPathComponent)
        }
    }

    /// One line: "<verb> [argument]". The file name is the ticket number the
    /// answer is filed under.
    private func run(_ line: String, id: String) {
        guard !line.isEmpty else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch verb {
        case "mark", "markiere":
            answer(id, mark(argument, true))
        case "unmark", "demarkiere":
            answer(id, mark(argument, false))
        case "raise-marked", "front", "vorn":
            let count = onFront?() ?? 0
            write(id, ok: true, text: "ok: \(count) markierte Fenster nach vorn")
        default:
            write(id, ok: false, text: "fehler: unbekannter Befehl \(verb)")
        }
    }

    private func mark(_ tty: String, _ marked: Bool) -> Outcome {
        guard !tty.isEmpty else { return .notFound }
        return onMark?(tty, marked) ?? .notFound
    }

    private func answer(_ id: String, _ outcome: Outcome) {
        switch outcome {
        case .ok(let name):
            write(id, ok: true, text: "ok: \(name)")
        case .notFound:
            write(id, ok: false, text: "fehler: kein Fenster zu diesem Terminal gefunden")
        case .ambiguous:
            write(id, ok: false, text: "fehler: mehrdeutig, nichts geändert")
        }
    }

    private func write(_ id: String, ok: Bool, text: String) {
        Log.write("Ablagekorb [\(id)]: \(text)")
        let body = (ok ? "0 " : "1 ") + text + "\n"
        try? body.write(to: outbox.appendingPathComponent(id), atomically: true, encoding: .utf8)
    }
}
