import Foundation

/// What a window is doing right now, derived from the spinner glyph in its
/// title. The point is the pause between "I told Claude to do something" and
/// "it is done": you should be able to see which window wants you without
/// reading any of them.
struct Activity {

    /// A glyph that changed this recently means the spinner is still turning.
    static let workingWindow: TimeInterval = 3

    var marker: String?
    var markerChangedAt = Date()
    /// The very first glyph we see says nothing about activity — only a
    /// *change* does. Without this every window would look freshly started
    /// after a restart, complete with an unread dot.
    private var hasSeenMarker = false
    var isWorking = false
    var finishedAt: Date?
    /// Set when a window stops working, cleared once you have looked at it.
    var hasUnseenResult = false

    /// - Returns: true when the window just started working.
    mutating func noteMarker(_ new: String?, now: Date = Date()) -> Bool {
        guard new != marker || !hasSeenMarker else { return false }
        let isFirst = !hasSeenMarker
        hasSeenMarker = true
        marker = new
        markerChangedAt = now
        guard new != nil, !isFirst else { return false }
        let wasWorking = isWorking
        isWorking = true
        hasUnseenResult = false
        finishedAt = nil
        return !wasWorking
    }

    /// Call regularly while something is working. Returns true when this
    /// window has just finished.
    mutating func refresh(now: Date = Date()) -> Bool {
        guard isWorking, now.timeIntervalSince(markerChangedAt) >= Self.workingWindow else { return false }
        isWorking = false
        finishedAt = markerChangedAt
        hasUnseenResult = true
        return true
    }

    /// Short, glanceable state — "arbeitet", "fertig vor 4 Min.".
    var text: String {
        if isWorking { return "arbeitet" }
        guard let finishedAt else { return "" }
        return "fertig " + Self.relative(to: finishedAt)
    }

    static func relative(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<45: return "gerade eben"
        case ..<5400:
            let minutes = max(1, Int((Double(seconds) / 60).rounded()))
            return "vor \(minutes) Min."
        default:
            let hours = Int((Double(seconds) / 3600).rounded())
            return "vor \(hours) Std."
        }
    }
}
