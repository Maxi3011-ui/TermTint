import Foundation

/// Remembers hand-typed names so they come back after a restart.
///
/// Two keys are written for every name:
///
/// * the window's own id, which is exact and unique and survives a restart of
///   this app for as long as the Terminal window itself lives;
/// * its working directory plus automatic label, as a fallback for when
///   Terminal itself was restarted and the window ids are all new.
///
/// The fallback alone is not enough, and not just in theory: several Claude
/// sessions commonly run from the same folder — often the home directory — and
/// two of them can even carry the same session name, at which point one window
/// silently overwrites the other's name.
enum LabelStore {

    struct Label: Codable {
        var name: String
        var hue: Double
        var directory: String?
        var updated: Date
    }

    private static let defaultsKey = "labels"
    private static let limit = 200

    /// Exact identity, valid while the Terminal window exists.
    static func windowKey(_ id: Int) -> String { "win:\(id)" }

    /// Best-effort identity, valid across a restart of Terminal.
    /// Returns nil unless the session name actually identifies the session.
    /// A key built from the running program instead — `zsh`, `claude` — is
    /// shared by every window in the same folder, and they then inherit each
    /// other's name, mark and place. See KeyHygiene.
    static func pathKey(directory: String?, autoName: String) -> String? {
        guard let directory, !directory.isEmpty,
              !KeyHygiene.isGeneric(autoName) else { return nil }
        return "dir:" + directory + "\n" + autoName
    }

    static func label(for key: String) -> Label? {
        all()[key]
    }

    static func remember(_ name: String, hue: Double, directory: String?, for keys: [String]) {
        var store = all()
        let label = Label(name: name, hue: hue, directory: directory, updated: Date())
        for key in keys { store[key] = label }
        if store.count > limit {
            let keep = store.sorted { $0.value.updated > $1.value.updated }.prefix(limit)
            store = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        write(store)
    }

    /// Throws out every entry the test accepts. The store is kept as one JSON
    /// blob, so it cannot be weeded through UserDefaults directly.
    @discardableResult
    static func prune(_ shouldDrop: (String) -> Bool) -> Int {
        var store = all()
        let dropped = store.keys.filter(shouldDrop)
        guard !dropped.isEmpty else { return 0 }
        for key in dropped { store.removeValue(forKey: key) }
        write(store)
        return dropped.count
    }

    static func forget(_ keys: [String]) {
        var store = all()
        for key in keys { store.removeValue(forKey: key) }
        write(store)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func all() -> [String: Label] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Label].self, from: data)
        else { return [:] }

        // The first version wrote bare paths; keep those names working.
        return decoded.reduce(into: [:]) { result, entry in
            let key = entry.key.hasPrefix("win:") || entry.key.hasPrefix("dir:")
                ? entry.key
                : "dir:" + entry.key
            result[key] = entry.value
        }
    }

    private static func write(_ store: [String: Label]) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
