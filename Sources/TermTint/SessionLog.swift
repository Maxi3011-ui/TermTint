import Foundation

/// Answers the one question the window title cannot: is this session still
/// working?
///
/// The spinner glyph in the title stands still during long steps, which is why
/// announcements kept firing too early. The conversation file, by contrast, is
/// written continuously while a session works. Measured here: a working
/// session had been written 4 seconds ago, a waiting one 1320 seconds.
final class SessionLog {

    /// No writes for this long means the session really has come to rest.
    static let quietThreshold: TimeInterval = 20

    /// One small file per live session, holding its name, its id and its
    /// working directory. The name here is exactly what the window title
    /// shows — generated or set with /rename — so the mapping survives a
    /// rename. Matching on the generated title alone did not.
    private static let registry = "~/.claude/sessions"
    private static let claudeProjects = "~/.claude/projects"
    private static let rebuildInterval: TimeInterval = 10

    private let queue = DispatchQueue(label: "eu.lecon.termtint.sessionlog", qos: .utility)
    private var index: [String: URL] = [:]
    private var builtAt: Date?
    private var isBuilding = false

    /// Three distinct answers. Collapsing "not built yet" into "no such
    /// session" would silence every announcement on the first attempt, before
    /// the index has ever finished building.
    enum Liveness {
        /// Seconds since the session file was last written to.
        case quiet(TimeInterval)
        /// The index is current and holds no session of that name.
        case unknown
        /// The index has not finished building — ask again shortly.
        case pending
    }

    /// Never blocks: a stale index refreshes in the background while this
    /// answers from what it already has.
    func liveness(for name: String) -> Liveness {
        refreshIfNeeded()

        var url: URL?
        var ready = false
        queue.sync {
            url = index[name]
            ready = builtAt != nil
        }
        guard ready else { return .pending }
        guard let url,
              let modified = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        else { return .unknown }
        return .quiet(Date().timeIntervalSince(modified))
    }

    /// Called only while an announcement is pending, so nothing runs at idle.
    private func refreshIfNeeded() {
        var needsBuild = false
        queue.sync {
            guard !isBuilding else { return }
            if let builtAt, Date().timeIntervalSince(builtAt) < Self.rebuildInterval { return }
            isBuilding = true
            needsBuild = true
        }
        guard needsBuild else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let fresh = Self.buildIndex()
            self.index = fresh
            self.builtAt = Date()
            self.isBuilding = false
        }
    }

    // MARK: - Building

    private static func buildIndex() -> [String: URL] {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSString(string: registry).expandingTildeInPath)
        guard let entries = try? manager.contentsOfDirectory(at: base,
                                                             includingPropertiesForKeys: nil)
        else { return [:] }

        var result: [String: URL] = [:]
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["name"] as? String, !name.isEmpty,
                  let id = object["sessionId"] as? String, !id.isEmpty,
                  let transcript = transcript(for: id)
            else { continue }
            result[name] = transcript
        }
        return result
    }

    /// The conversation file a session writes to while it works.
    private static func transcript(for sessionId: String) -> URL? {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSString(string: claudeProjects).expandingTildeInPath)
        guard let projects = try? manager.contentsOfDirectory(at: base,
                                                              includingPropertiesForKeys: nil)
        else { return nil }
        for project in projects {
            let candidate = project.appendingPathComponent("\(sessionId).jsonl")
            if manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
