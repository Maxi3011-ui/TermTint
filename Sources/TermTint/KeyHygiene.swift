import Foundation

/// Guards the fallback key that names, marks and places are filed under.
///
/// A window is remembered twice: by its window id, which is exact, and by
/// working directory plus session name, which is what survives a restart of
/// Terminal. The second key is only worth anything when the session name says
/// something. If it is just the running program — `zsh`, `claude`, `node` —
/// then every window in the same folder shares one key, and they start
/// inheriting each other's name, each other's red dot and each other's place
/// in the layout. That happened: a chat was suddenly called after a different
/// one, carried a mark nobody set, and the arrangement came out scrambled.
enum KeyHygiene {

    /// Names that identify a program, not a session.
    private static let programs: Set<String> = [
        "zsh", "-zsh", "bash", "sh", "fish", "nu", "csh", "tcsh", "login",
        "tmux", "screen", "claude", "codex", "node", "deno", "bun",
        "python", "python3", "ruby", "perl", "php", "swift", "go", "cargo",
        "cat", "less", "more", "tail", "head", "grep", "watch", "top", "htop",
        "vim", "nvim", "nano", "emacs", "ssh", "scp", "git", "gh", "npm",
        "npx", "yarn", "pnpm", "make", "cmake", "docker", "brew", "pip",
        "caffeinate", "sudo", "env", "ls", "man",
    ]

    /// True when the session name cannot tell two windows apart.
    static func isGeneric(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return true }
        if trimmed == NSUserName().lowercased() { return true }
        if programs.contains(trimmed) { return true }
        // A bare path is the working directory over again, not a name.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return true }
        return false
    }

    /// Entries written before this was guarded still poison every lookup, so
    /// they are thrown out once at startup.
    /// - Parameter liveWindowIDs: every window Terminal still has, minimised
    ///   ones included. Anything filed under an id that is not in there
    ///   belongs to a window that is gone — and the window server hands those
    ///   ids out again. A new window then inherits a dead one's name, its red
    ///   dot and its place in the layout, which is how a chat ended up named
    ///   after a different one and marked without anybody marking it.
    static func prune(liveWindowIDs: Set<Int>) {
        let defaults = UserDefaults.standard

        func dead(_ key: String) -> Bool {
            guard key.hasPrefix("win:"), let id = Int(key.dropFirst(4)) else { return false }
            return !liveWindowIDs.contains(id)
        }
        func drop(_ key: String) -> Bool { isPoisoned(key) || dead(key) }

        let droppedLabels = LabelStore.prune(drop)
        if droppedLabels > 0 {
            Log.write("Namensspeicher: \(droppedLabels) tote oder mehrdeutige Einträge entfernt")
        }

        if let marked = defaults.stringArray(forKey: "marked") {
            let kept = marked.filter { !drop($0) }
            if kept.count != marked.count {
                defaults.set(kept, forKey: "marked")
                Log.write("Markierungen: \(marked.count - kept.count) tote oder mehrdeutige Einträge entfernt")
            }
        }

        if var slots = defaults.dictionary(forKey: "slots") {
            let dropped = slots.keys.filter(drop)
            for key in dropped { slots.removeValue(forKey: key) }
            if !dropped.isEmpty {
                defaults.set(slots, forKey: "slots")
                Log.write("Plätze: \(dropped.count) tote oder mehrdeutige Einträge entfernt")
            }
        }
    }

    private static func isPoisoned(_ key: String) -> Bool {
        guard key.hasPrefix("dir:") else { return false }
        let parts = key.dropFirst(4).components(separatedBy: "\n")
        // "dir:<path>" without a session name at all, or with a useless one.
        guard parts.count == 2 else { return true }
        return isGeneric(parts[1])
    }
}
