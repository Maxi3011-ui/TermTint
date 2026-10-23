import Foundation

/// The place a window keeps in any arrangement.
///
/// Tiling used to read the order off the current positions, so every run
/// could come out different — move one window, add one, and the whole grid
/// reshuffles. That defeats the point: people remember *where* a session sits
/// far better than what it is called, and a layout that rearranges itself
/// throws that memory away every time.
///
/// So the order is remembered instead, under the same key pair as names and
/// marks. A window that has been placed once keeps its rank; a new one goes to
/// the end rather than pushing everything along.
enum SlotStore {

    private static let defaultsKey = "slots"
    private static let limit = 200

    static func rank(anyOf keys: [String]) -> Int? {
        let stored = all()
        for key in keys {
            if let rank = stored[key] { return rank }
        }
        return nil
    }

    static func put(_ rank: Int, for keys: [String]) {
        guard !keys.isEmpty else { return }
        var stored = all()
        for key in keys { stored[key] = rank }
        if stored.count > limit {
            // Drop the ones furthest back; they are the least likely to be
            // part of the layout anybody remembers.
            let keep = stored.sorted { $0.value < $1.value }.prefix(limit)
            stored = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    static var highest: Int { all().values.max() ?? -1 }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func all() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
    }
}
