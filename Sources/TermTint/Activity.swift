import Foundation

/// What a window is doing right now, derived from the spinner glyph in its
/// title. The point is the pause between "I told Claude to do something" and
/// "it is done": you should be able to see which window wants you without
/// reading any of them.
struct Activity {

    /// A glyph that changed this recently means the spinner is still turning.
    /// Short, because the overview should react quickly.
    static let workingWindow: TimeInterval = 3

    /// How long the glyph must stand still before the session file is even
    /// consulted. Only a first filter now — the file decides.
    static let settleWindow: TimeInterval = 8

    /// A burst of work shorter than this is not worth interrupting anyone for.
    static let minimumWork: TimeInterval = 6

    var marker: String?
    var markerChangedAt = Date()
    /// The very first glyph we see says nothing about activity — only a
    /// *change* does. Without this every window would look freshly started
    /// after a restart, complete with an unread dot.
    private var hasSeenMarker = false
    private var workStartedAt: Date?
    private var announced = true

    var isWorking = false
    var finishedAt: Date?
    /// Set when a window stops working, cleared once you have looked at it.
    var hasUnseenResult = false

    /// True while a finish is waiting out the settle window. The ticker has to
    /// keep running until then, so it cannot be folded into `isWorking`.
    var isSettling: Bool { !announced && !isWorking && finishedAt != nil }

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
        if !wasWorking {
            workStartedAt = now
            announced = false
        }
        return !wasWorking
    }

    /// Call regularly while something is working. Returns true when this
    /// window has just finished, for display purposes.
    mutating func refresh(now: Date = Date()) -> Bool {
        guard isWorking, now.timeIntervalSince(markerChangedAt) >= Self.workingWindow else { return false }
        isWorking = false
        finishedAt = markerChangedAt
        hasUnseenResult = true
        return true
    }

    /// How long to keep waiting for a session to go quiet before giving up.
    /// Without this a session that never rests would hold the ticker open.
    static let giveUpAfter: TimeInterval = 600

    /// Returns true exactly once, and only when the session really has come to
    /// rest. The still spinner alone is not enough — it stands still during
    /// long steps too, which is what made announcements fire too early.
    mutating func claimAnnouncement(liveness: SessionLog.Liveness,
                                    now: Date = Date()) -> Bool {
        guard !announced, !isWorking, let finishedAt else { return false }
        // Cheap gate first: no point touching files while the spinner still
        // turned a moment ago.
        guard now.timeIntervalSince(markerChangedAt) >= Self.settleWindow else { return false }

        guard let start = workStartedAt,
              finishedAt.timeIntervalSince(start) >= Self.minimumWork
        else {
            announced = true
            return false
        }

        if now.timeIntervalSince(finishedAt) >= Self.giveUpAfter {
            announced = true
            return false
        }

        switch liveness {
        case .pending:
            // Index still building — keep the claim open and ask again.
            return false
        case .unknown:
            // No session file for this window. Silence beats guessing.
            announced = true
            return false
        case .quiet(let seconds):
            guard seconds >= SessionLog.quietThreshold else { return false }
            announced = true
            return true
        }
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
