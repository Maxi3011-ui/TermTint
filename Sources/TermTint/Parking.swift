import AppKit

/// Parking is what freezing cannot be: a parked session costs nothing at all.
///
/// A frozen session stands still but keeps its memory — a few hundred megabytes
/// each, which with twenty of them fills the swap file. Parking ends the Claude
/// process and closes the window, and keeps only what is needed to bring the
/// chat back exactly as it was: the session id, the folder, the name, the
/// colour, the red dot and where the window stood. The conversation itself is
/// safe on disk in `~/.claude/projects`; `claude --resume <id>` reads it back.
///
/// The list of parked sessions is kept until a session is fetched back or
/// taken off the list by hand. It never thins out on its own.
struct ParkedSession: Codable, Equatable {
    /// The Claude session id — what `--resume` takes.
    var id: String
    /// What the window was called in TermTint.
    var name: String
    /// True when that name was typed by hand rather than taken from the chat.
    var manual: Bool
    /// The folder the session was started in. Resuming only works from there.
    var directory: String
    var hue: Double
    var marked: Bool
    /// Terminal's own window bounds: left, top, right, bottom.
    var bounds: [Int]
    /// Switches the session was started with and should get again.
    var flags: [String]
    var parkedAt: Date
    /// The name the chat itself carries when it was given by hand with
    /// /rename. Other programs address the session by it, so it is handed
    /// back on resuming rather than left to chance.
    var sessionName: String?
}

enum ParkStore {

    private static let key = "parkedSessions"

    static func all() -> [ParkedSession] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ParkedSession].self, from: data)
        else { return [] }
        return decoded
    }

    static func add(_ session: ParkedSession) {
        var list = all().filter { $0.id != session.id }
        list.append(session)
        write(list)
    }

    static func remove(_ id: String) {
        write(all().filter { $0.id != id })
    }

    private static func write(_ list: [ParkedSession]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum Parking {

    struct Refusal: Error {
        let text: String
    }

    /// Switches worth carrying over. Everything else on the command line
    /// belonged to that one start (`--resume`, a prompt) and must not repeat.
    private static let keptFlags = ["--dangerously-skip-permissions", "--chrome"]

    /// Records the session, then ends it and closes its window.
    ///
    /// The record is written first, so whatever goes wrong afterwards the chat
    /// is on the list. Ending the process is asked for politely; the window is
    /// closed once it has gone, off the main thread's time.
    static func park(tty: String, windowID: Int, name: String, manual: Bool,
                     hue: Double, marked: Bool,
                     done: @escaping () -> Void) -> Result<ParkedSession, Refusal> {
        guard let live = claudeSession(on: tty) else {
            return .failure(Refusal(text: "in diesem Fenster läuft keine Claude-Sitzung"))
        }
        guard live.status == "idle" || live.status == "waiting" else {
            return .failure(Refusal(text: "die Sitzung arbeitet gerade (\(live.status))"))
        }

        let session = ParkedSession(id: live.id,
                                    name: name.isEmpty ? live.name : name,
                                    manual: manual,
                                    directory: startDirectory(of: live.id) ?? live.directory,
                                    hue: hue,
                                    marked: marked,
                                    bounds: bounds(of: windowID),
                                    flags: keptFlags.filter(live.arguments.contains),
                                    parkedAt: Date(),
                                    sessionName: live.namedByHand && !live.name.isEmpty ? live.name : nil)
        ParkStore.add(session)

        kill(live.pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).async {
            var waited = 0
            while kill(live.pid, 0) == 0, waited < 60 {
                usleep(100_000)
                waited += 1
            }
            if kill(live.pid, 0) == 0 {
                kill(live.pid, SIGKILL)
                usleep(300_000)
            }
            DispatchQueue.main.async {
                closeWindow(windowID)
                done()
            }
        }
        return .success(session)
    }

    /// Opens a new Terminal window where the old one stood and resumes the
    /// chat in it. Returns the new window's id.
    static func resume(_ session: ParkedSession) -> Int? {
        let command = "cd \(shellQuoted(session.directory)) && claude --resume \(session.id)"
            + session.flags.map { " " + $0 }.joined()
            + (session.sessionName.map { " --name " + shellQuoted($0) } ?? "")
        var place = ""
        if session.bounds.count == 4 {
            place = "set bounds of window id wid to {\(session.bounds.map(String.init).joined(separator: ", "))}"
        }
        let source = """
        tell application "Terminal"
          do script "\(appleScriptEscaped(command))"
          set wid to id of front window
          \(place)
          activate
          return wid
        end tell
        """
        return run(source).flatMap { Int($0) }
    }

    // MARK: - The live session

    private struct Live {
        let pid: pid_t
        let id: String
        let name: String
        let directory: String
        let status: String
        let arguments: [String]
        let namedByHand: Bool
    }

    /// The interactive Claude session whose process sits on this tty, read
    /// from the small file Claude keeps per running session.
    private static func claudeSession(on tty: String) -> Live? {
        let short = tty.replacingOccurrences(of: "/dev/", with: "")
        let lines = shell("/bin/ps", ["-t", short, "-o", "pid=,args="])
            .split(separator: "\n")
        let registry = NSString(string: "~/.claude/sessions").expandingTildeInPath
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, let pid = pid_t(fields[0]) else { continue }
            let file = URL(fileURLWithPath: registry).appendingPathComponent("\(pid).json")
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["kind"] as? String == "interactive",
                  let id = object["sessionId"] as? String, !id.isEmpty
            else { continue }
            return Live(pid: pid,
                        id: id,
                        name: object["name"] as? String ?? "",
                        directory: object["cwd"] as? String ?? NSHomeDirectory(),
                        status: object["status"] as? String ?? "",
                        arguments: Array(fields.dropFirst(2)),
                        namedByHand: object["nameSource"] as? String == "user")
        }
        return nil
    }

    /// The folder the conversation is filed under. A session can wander into
    /// other folders while it works, but it is only found again from the one
    /// it was started in — and that one is in the first lines of its own file.
    private static func startDirectory(of id: String) -> String? {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath)
        guard let projects = try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        else { return nil }
        for project in projects {
            let file = project.appendingPathComponent("\(id).jsonl")
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let head = String(decoding: handle.readData(ofLength: 512 * 1024), as: UTF8.self)
            guard let pattern = try? NSRegularExpression(pattern: "\"cwd\":\"((?:[^\"\\\\]|\\\\.)*)\"")
            else { return nil }
            let range = NSRange(head.startIndex..., in: head)
            for match in pattern.matches(in: head, range: range) {
                guard let found = Range(match.range(at: 1), in: head) else { continue }
                let path = String(head[found]).replacingOccurrences(of: "\\/", with: "/")
                if folderName(for: path) == project.lastPathComponent { return path }
            }
            return nil
        }
        return nil
    }

    /// How Claude names the folder a project's conversations go into.
    private static func folderName(for path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            let plain = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            return plain ? Character(scalar) : "-"
        })
    }

    // MARK: - Terminal

    private static func bounds(of windowID: Int) -> [Int] {
        let source = """
        tell application "Terminal"
          set b to bounds of window id \(windowID)
          return ((item 1 of b) as text) & " " & (item 2 of b) & " " & (item 3 of b) & " " & (item 4 of b)
        end tell
        """
        let numbers = (run(source) ?? "").split(separator: " ").compactMap { Int($0) }
        return numbers.count == 4 ? numbers : []
    }

    /// A window with several tabs is left alone: closing it would take the
    /// other tabs' sessions with it.
    private static func closeWindow(_ windowID: Int) {
        let source = """
        tell application "Terminal"
          if exists window id \(windowID) then
            if (count of tabs of window id \(windowID)) is 1 then close window id \(windowID)
          end if
        end tell
        """
        _ = run(source)
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Log.write("Parken: AppleScript fehlgeschlagen: \(error[NSAppleScript.errorMessage] ?? error)")
            return nil
        }
        return result?.stringValue
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension ParkedSession {
    /// "heute geparkt", "seit 3 Tagen geparkt" — for the right-hand column.
    var since: String {
        let days = Calendar.current.dateComponents([.day],
                                                   from: Calendar.current.startOfDay(for: parkedAt),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<1: return "heute geparkt"
        case 1: return "seit gestern geparkt"
        case 2..<14: return "seit \(days) Tagen geparkt"
        default: return "seit \(days / 7) Wochen geparkt"
        }
    }

    /// The last part of the folder, unless that is just the home folder.
    var place: String {
        directory == NSHomeDirectory() ? "" : (directory as NSString).lastPathComponent
    }
}

enum ParkLook {
    /// The colour of parking — a calm blue, apart from the lilac of freezing.
    static let blue = NSColor(calibratedRed: 0.40, green: 0.63, blue: 0.99, alpha: 1)
}
