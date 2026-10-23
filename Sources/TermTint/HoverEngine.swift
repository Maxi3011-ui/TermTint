import AppKit

/// Owns per-window state and decides what the single overlay panel shows.
/// Everything here is driven by events — there is no polling timer anywhere.
final class HoverEngine {

    struct WindowState {
        var frame: CGRect
        var title: String
        var titleBarHeight: CGFloat = 28
        /// Derived from the window title; overridden the moment the user types.
        var autoName: String = ""
        var manualName: String?
        var commandName: String = ""
        /// Working directory, used to find the name again after a restart.
        var directory: String?
        /// The window server's own id — unique and stable while the window
        /// lives, which is what makes names survive a restart of this app.
        var windowID: Int?
        var role: Role = .shell
        /// False while the window is minimised or otherwise not listed. The
        /// state is kept either way so the name survives.
        var isOnScreen = true
        /// Sitting in the Dock. Kept here rather than queried on demand, so
        /// opening the overview never waits on Accessibility.
        var isMinimized = false
        /// Working / finished / not yet looked at.
        var activity = Activity()
        /// A tool role recolours the window once, then the colour is fixed for
        /// the window's life — colours must not flicker with the foreground
        /// process.
        var roleLocked: Bool = false
        var tint: Tint
        /// Set by a click, cleared when the pointer leaves and comes back.
        var dismissed: Bool = false
        /// A red dot you set by hand — see Marker.swift.
        var isMarked = false
        /// The session's tty, looked up when it is first needed for freezing.
        var tty: String?

        var displayName: String { manualName ?? autoName }

        /// The group header already names the role, so the row only adds the
        /// automatic label when a hand-typed name is hiding it.
        var switcherCaption: String {
            guard manualName != nil, !autoName.isEmpty, autoName != manualName else { return "" }
            return autoName
        }

        /// Second line: the role, plus the automatic label when a hand-typed
        /// name is covering it. Never repeats what is already on screen.
        var caption: String {
            let base = role.isTool ? role.label : (commandName.isEmpty ? role.label : commandName)
            var text: String
            if manualName != nil, !autoName.isEmpty, autoName != manualName, autoName != base {
                text = "\(base) · \(autoName)"
            } else {
                text = base
            }
            if text == displayName { text = "" }
            let state = activity.text
            guard !state.isEmpty else { return text }
            return text.isEmpty ? state : text + " · " + state
        }
    }

    private(set) var isEnabled = true
    /// True while the ⌥Tab overview is open — the hover overlay stays out of
    /// the way instead of reacting to the pointer crossing the list.
    private var isSuspended = false

    private let watcher = TerminalWatcher()
    private let herald = Herald()
    private let sessionLog = SessionLog()
    private let panel = OverlayPanel()
    private let freezer = Freezer()
    private let freezeButton = FreezeButtonPanel()
    private let markButton = MarkButtonPanel()
    /// What each window looked like before an arrangement was applied, so the
    /// same button can undo it.
    private var snapshots: [Arrangement: [WindowRef: CGRect]] = [:]
    /// Runs only while a veil or a mark dot is on screen.
    private var attachmentTicker: Timer?
    private var markDots: [WindowRef: MarkDot] = [:]
    private var veils: [WindowRef: FreezeVeil] = [:]

    private var states: [WindowRef: WindowState] = [:]
    private var hovered: WindowRef?
    private var editing: WindowRef?
    private var previousApp: NSRunningApplication?

    private var monitors: [Any] = []
    /// Crossing from one window into the next leaves the pointer over nothing
    /// for the width of the window borders — measured at 5 to 45 ms. Hiding
    /// right away starts a fade-out that then collides with the fade-in for
    /// the next window. A short grace period removes the whole race: if a new
    /// window shows up in time, the overlay simply moves there.
    private var activityTimer: Timer?
    /// Minimise changes waiting for the overview to close.
    private var pendingMinimize: [WindowRef: Bool] = [:]
    private var pendingHide: DispatchWorkItem?
    private static let hideGrace: TimeInterval = 0.09

    private var reattemptTimer: Timer?
    private var reattempts = 0
    private static let maxReattempts = 12

    private var windowList: [[String: Any]] = []
    private var windowListStamp: TimeInterval = -1

    private static let listTTL: TimeInterval = 0.2
    private static let matchTolerance: CGFloat = 6

    // MARK: - Lifecycle

    func start() {
        panel.overlay.onCommit = { [weak self] name in self?.finishEditing(saving: name) }
        panel.overlay.onEndEditing = { [weak self] in self?.finishEditing(saving: nil) }

        herald.onSelect = { [weak self] ref in self?.activate(ref) }
        freezeButton.onClick = { [weak self] in
            guard let self, let hovered = self.hovered else { return }
            self.toggleFreeze(hovered)
        }
        markButton.onClick = { [weak self] in
            guard let self, let hovered = self.hovered else { return }
            self.toggleMark(hovered)
        }
        watcher.onEvent = { [weak self] event in self?.handle(event) }
        watcher.start()
        refreshWindows()
        restoreFrozen()
        installMonitors()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in
            self?.pointerMoved()
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.pointerClicked()
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.keyPressed()
        } as Any)
        // Switching desks, hiding or activating an app moves windows out from
        // under their veils and mark dots without the Accessibility API saying
        // a word. Those panels would stay lying on an empty desktop.
        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.activeSpaceDidChangeNotification,
                                          NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.didHideApplicationNotification,
                                          NSWorkspace.didUnhideApplicationNotification] {
            monitors.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshAttachments()
            } as Any)
        }

        // Local counterparts, for the brief moment our own panel is key while editing.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            self?.pointerMoved()
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.localClick()
            return event
        } as Any)
    }

    // MARK: - Menu bar commands

    var windowCount: Int { states.values.filter(\.isOnScreen).count }

    /// Rows for the ⌥Tab overview.
    func switcherEntries() -> [Switcher.Entry] {
        // Names are only refreshed on demand, since title changes are no
        // longer observed for windows that are not on screen.
        for ref in Array(states.keys) {
            applyTitle(watcher.title(of: ref), to: ref)
            // Notifications can lag a beat behind; the overview must be right
            // the moment it opens. Bounded by the messaging timeout.
            states[ref]?.isMinimized = watcher.isMinimized(ref)
        }
        let focused = watcher.focusedWindow
        // Minimised windows stay in the list — that is often exactly the old
        // project you are looking for.
        return states.map { ref, state in
            Switcher.Entry(ref: ref,
                           name: state.displayName,
                           caption: state.switcherCaption,
                           tint: state.tint,
                           role: state.role,
                           isFocused: ref == focused,
                           activity: state.activity.text,
                           isWorking: state.activity.isWorking,
                           isUnseen: state.activity.hasUnseenResult,
                           // The attribute is authoritative and immediate;
                           // waiting for our own bookkeeping to catch up only
                           // adds a race.
                           isMinimized: state.isMinimized,
                           isFrozen: freezer.isFrozen(state.tty),
                           isMarked: state.isMarked)
        }
    }

    /// Puts a window away or brings it back, without switching to it.
    ///
    /// The change is recorded here, not carried out. The overview is open only
    /// while ⌥ is held, and ⌥ is macOS's own "minimise every window" gesture —
    /// asking Terminal to minimise one window in that moment took the whole set
    /// with it. The list updates immediately, the windows follow once the key
    /// is released.
    func toggleMinimize(_ ref: WindowRef) {
        guard let state = states[ref] else { return }
        let minimized = state.isMinimized
        Log.write("Vorgemerkt: \(state.displayName) -> \(minimized ? "zurückholen" : "minimieren")")
        pendingMinimize[ref] = !minimized
        states[ref]?.isMinimized = !minimized
        states[ref]?.isOnScreen = minimized
        if ref == hovered { hovered = nil; hideNow() }
    }

    /// Brings every minimised window back out of the Dock — recorded now,
    /// carried out once the overview closes, for the same reason as above.
    func restoreAllMinimized() {
        for ref in Array(states.keys) where states[ref]?.isMinimized == true {
            pendingMinimize[ref] = false
            states[ref]?.isMinimized = false
            states[ref]?.isOnScreen = true
        }
    }

    /// Puts every paused session into the Dock. Deferred like every other
    /// minimise: ⌥ is still held while the overview is open, and that is
    /// macOS's own "minimise everything" gesture.
    func minimizeAllFrozen() {
        for ref in Array(states.keys) {
            guard let state = states[ref], !state.isMinimized,
                  freezer.isFrozen(state.tty) else { continue }
            Log.write("Vorgemerkt: \(state.displayName) -> minimieren (eingefroren)")
            pendingMinimize[ref] = true
            states[ref]?.isMinimized = true
        }
    }

    /// Runs once the overview is gone *and* ⌥ is actually released — closing
    /// with Escape leaves the key down, and applying then would trigger the
    /// system's minimise-everything gesture again.
    func applyPendingWindowStates(attempt: Int = 0) {
        guard !pendingMinimize.isEmpty else { return }

        if NSEvent.modifierFlags.contains(.option), attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.applyPendingWindowStates(attempt: attempt + 1)
            }
            return
        }

        let work = pendingMinimize
        pendingMinimize.removeAll()
        for (ref, minimized) in work {
            watcher.setMinimized(minimized, for: ref)
        }
    }

    func activate(_ ref: WindowRef) {
        states[ref]?.activity.hasUnseenResult = false
        watcher.raise(ref)
        if let hovered { states[hovered]?.dismissed = false }
        pointerMoved(force: true)
    }

    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            if editing != nil { panel.overlay.cancelEditing() }
            hovered = nil
            hideNow()
        } else {
            pointerMoved(force: true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            pointerMoved(force: true)
        } else {
            if editing != nil { panel.overlay.cancelEditing() }
            hovered = nil
            hideNow()
        }
    }

    func reshuffleColors() {
        var used: [Role: [CGFloat]] = [:]
        for ref in Array(states.keys) {
            guard let role = states[ref]?.role else { continue }
            let tint = Palette.tint(for: role, avoiding: used[role, default: []])
            used[role, default: []].append(tint.hue)
            states[ref]?.tint = tint
            remember(ref)
        }
        redrawHovered()
    }

    /// Drops hand-typed names, both the live ones and everything remembered.
    func clearNames() {
        for ref in Array(states.keys) { states[ref]?.manualName = nil }
        LabelStore.clear()
        redrawHovered()
    }

    // MARK: - Watcher events

    private func handle(_ event: TerminalWatcher.Event) {
        switch event {
        case .listChanged:
            Log.write("Ereignis: Fensterliste geändert")
            refreshWindows()

        case .geometryChanged(let ref):
            guard let frame = watcher.frame(of: ref) else { refreshWindows(); return }
            states[ref]?.frame = frame
            invalidateWindowList()
            if ref == hovered { panel.place(at: frame) }
            pointerMoved()
            updateOcclusion()
            refreshAttachments()

        case .titleChanged(let ref):
            guard states[ref] != nil else { return }
            // Claude Code animates a spinner in its window title, so this
            // fires several times a second. Redrawing only when the visible
            // text really changed keeps the overlay perfectly still.
            let changed = applyTitle(watcher.title(of: ref), to: ref)
            if changed, ref == hovered { redrawHovered() }
        }
    }

    private func refreshWindows() {
        let live: [WindowRef: (frame: CGRect, title: String, minimized: Bool)]
        switch watcher.snapshot() {
        case .ok(let windows):
            // An empty answer is only believable when we do not already know
            // about live windows. Terminal occasionally returns success with
            // an empty list while windows are plainly there; taking that at
            // face value blanks every overlay until the next event.
            if windows.isEmpty, states.keys.contains(where: { AX.isAlive($0.element) }) {
                Log.write("Fensterliste leer, obwohl Fenster leben — wird erneut versucht")
                scheduleReattempt(reason: "leere Liste trotz lebender Fenster")
                return
            }
            live = windows
            if windows.isEmpty && states.isEmpty {
                scheduleReattempt(reason: "Fensterliste leer")
            } else {
                cancelReattempt()
            }
        case .unavailable(let reason):
            if watcher.pid == nil {
                // Terminal itself is gone; nothing left to remember.
                states.removeAll()
                hovered = nil
                hideNow()
                return
            }
            // Keep what we know rather than blanking every overlay.
            Log.write("Fensterliste nicht abrufbar (\(reason)) — bisheriger Stand bleibt")
            scheduleReattempt(reason: reason)
            return
        }

        for (ref, info) in live {
            if states[ref] != nil {
                if info.frame != .zero { states[ref]?.frame = info.frame }
                states[ref]?.isMinimized = info.minimized
                states[ref]?.isOnScreen = !info.minimized
                applyTitle(info.title, to: ref)
            } else if info.frame != .zero || info.minimized {
                // A minimised window reports no usable geometry. Skipping it
                // here meant a window already in the Dock at launch never
                // showed up in the overview at all.
                var fresh = makeState(for: ref, frame: info.frame, title: info.title)
                fresh.isMinimized = info.minimized
                fresh.isOnScreen = !info.minimized
                states[ref] = fresh
            }
        }

        for ref in Array(states.keys) where live[ref] == nil {
            // Minimised, on another Space, or momentarily unreadable — all of
            // these are still the same window. Forgetting it here would reset
            // the name the user typed and hand out a new colour. Only a dead
            // element means the window is really closed.
            if AX.isAlive(ref.element) {
                states[ref]?.isOnScreen = false
                if ref == hovered {
                    hovered = nil
                    hideNow()
                }
                continue
            }
            if let tty = states[ref]?.tty, freezer.isFrozen(tty) { freezer.thaw(tty) }
            states.removeValue(forKey: ref)
            if ref == editing { panel.overlay.cancelEditing() }
            if ref == hovered {
                Log.write("  ausblenden: Fenster geschlossen")
                hovered = nil
                hideNow()
            }
        }

        invalidateWindowList()
        pointerMoved(force: true)
        refreshAttachments()
    }

    /// Retries a failed or suspiciously empty window query a few times, then
    /// gives up until the next real event. Runs only while something is wrong.
    private func scheduleReattempt(reason: String) {
        guard reattempts < Self.maxReattempts, reattemptTimer == nil else { return }
        reattempts += 1
        Log.write("erneuter Versuch \(reattempts)/\(Self.maxReattempts) (\(reason))")
        reattemptTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.reattemptTimer = nil
            self?.refreshWindows()
        }
    }

    private func cancelReattempt() {
        reattemptTimer?.invalidate()
        reattemptTimer = nil
        reattempts = 0
    }

    @objc private func appActivated() {
        Log.write("App-Wechsel")
        // Another app may now sit on top of the hovered window.
        invalidateWindowList()
        pointerMoved(force: true)
        updateOcclusion()
        refreshAttachments()
    }

    @objc private func screensChanged() {
        refreshWindows()
    }

    // MARK: - Role and automatic naming

    private func makeState(for ref: WindowRef, frame: CGRect, title: String) -> WindowState {
        let parsed = TerminalTitle.parse(title)
        let role = parsed.map(TerminalTitle.role(for:)) ?? .other
        var state = WindowState(frame: frame,
                                title: title,
                                tint: Palette.tint(for: role, avoiding: hues(of: role)))
        state.role = role
        state.roleLocked = role.isTool
        state.titleBarHeight = watcher.titleBarHeight(of: ref)
        state.autoName = parsed.map(TerminalTitle.autoName(for:)) ?? ""
        state.commandName = parsed?.commandName ?? ""
        state.directory = watcher.directory(of: ref)
        state.windowID = windowID(matching: frame)
        if let parsed, state.activity.noteMarker(TerminalTitle.marker(of: parsed)) {
            startActivityTicker()
        }

        if let stored = storedLabel(for: state) {
            state.manualName = stored.name
            // Only reuse the colour if it still belongs to this role's family;
            // otherwise a window that changed tools would look wrong.
            if role.hues.contains(CGFloat(stored.hue)) {
                state.tint = Tint(hue: CGFloat(stored.hue), role: role)
            }
        }
        // A mark is a decision about the window, so it comes back with it.
        state.isMarked = MarkStore.isMarked(anyOf: markKeys(for: state))
        return state
    }

    /// Exact match by window id first. The directory-based fallback is only
    /// used when no live window already carries that name, so two windows that
    /// happen to share a folder and a session name cannot both claim it.
    private func storedLabel(for state: WindowState) -> LabelStore.Label? {
        if let id = state.windowID,
           let stored = LabelStore.label(for: LabelStore.windowKey(id)),
           stored.directory == nil || stored.directory == state.directory {
            return stored
        }
        guard let key = LabelStore.pathKey(directory: state.directory, autoName: state.autoName),
              let stored = LabelStore.label(for: key),
              !states.values.contains(where: { $0.manualName == stored.name })
        else { return nil }
        return stored
    }

    /// The window server id for a window we know by its frame.
    private func windowID(matching frame: CGRect) -> Int? {
        guard let terminalPID = watcher.pid else { return nil }
        for entry in currentWindowList() {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == terminalPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw),
                  Geo.cocoaRect(fromAX: bounds).isClose(to: frame, within: Self.matchTolerance)
            else { continue }
            return entry[kCGWindowNumber as String] as? Int
        }
        return nil
    }

    /// - Returns: whether anything the overlay actually shows changed.
    @discardableResult
    private func applyTitle(_ title: String, to ref: WindowRef) -> Bool {
        guard var state = states[ref], state.title != title || state.autoName.isEmpty else { return false }
        let before = (state.displayName, state.caption, state.tint.hue)
        let beforeAuto = state.autoName
        state.title = title

        guard let parsed = TerminalTitle.parse(title) else {
            states[ref] = state
            return false
        }
        state.autoName = TerminalTitle.autoName(for: parsed)
        state.commandName = parsed.commandName
        if state.activity.noteMarker(TerminalTitle.marker(of: parsed)) {
            startActivityTicker()
        }

        // Only an upgrade to a tool role repaints a window, and only once.
        let role = TerminalTitle.role(for: parsed)
        if !state.roleLocked, role.isTool {
            state.role = role
            state.roleLocked = true
            state.tint = Palette.tint(for: role, avoiding: hues(of: role, excluding: ref))
        } else if !state.roleLocked, role == .shell || role == .other {
            state.role = state.role == .shell || state.role == .other ? state.role : role
        }
        states[ref] = state
        // The fallback key contains the automatic name, so a session that
        // renames itself would otherwise leave the stored entry behind.
        if state.manualName != nil, state.autoName != beforeAuto { remember(ref) }
        return before != (state.displayName, state.caption, state.tint.hue)
    }

    private func hues(of role: Role, excluding ref: WindowRef? = nil) -> [CGFloat] {
        states.compactMap { key, value in
            guard key != ref, value.role == role else { return nil }
            return value.tint.hue
        }
    }

    // MARK: - Pointer

    /// - Parameter force: re-check stacking order even if the pointer is still
    ///   inside the window we already show. Normal mouse moves skip that check,
    ///   which keeps hovering down to a couple of rectangle tests.
    private func pointerMoved(force: Bool = false) {
        guard isEnabled, !isSuspended, editing == nil else { return }
        let point = NSEvent.mouseLocation

        // Fast path: still inside the same window, and no other window's frame
        // reaches this point. Overlapping frames must take the full check —
        // otherwise moving into a window stacked on top of the hovered one
        // would silently keep showing the old overlay.
        if !force, let current = hovered,
           states[current]?.frame.contains(point) == true,
           !states.contains(where: { $0.key != current && $0.value.isOnScreen && $0.value.frame.contains(point) }) {
            updateHotState(at: point)
            return
        }

        let target = windowUnderPointer(point)
        if Log.isEnabled {
            Log.write("move \(Int(point.x)),\(Int(point.y)) fenster=\(states.count) "
                + "kandidaten=\(states.filter { $0.value.frame.contains(point) }.count) "
                + "ziel=\(target == nil ? "nil" : "ja") vorher=\(hovered == nil ? "nil" : "ja") force=\(force)")
        }
        guard target != hovered || force else { return }

        if let previous = hovered, previous != target { states[previous]?.dismissed = false }
        hovered = target
        if let target { applyTitle(watcher.title(of: target), to: target) }

        guard let target, let state = states[target] else {
            scheduleHide()
            return
        }

        cancelHide()
        show(target, state)
        updateHotState(at: point)
    }

    /// Runs only while at least one session is working, then stops itself —
    /// so an idle Mac stays at zero.
    private func startActivityTicker() {
        guard activityTimer == nil else { return }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickActivity()
        }
    }

    private func tickActivity() {
        var busy = false
        var displayChanged = false
        var toAnnounce: [WindowRef] = []

        for ref in Array(states.keys) {
            guard var state = states[ref] else { continue }
            if state.activity.refresh() { displayChanged = true }
            // The window title only gets us as far as "the spinner stopped".
            // Whether the session is really finished is decided by its session
            // file, which keeps being written during long steps.
            let liveness = state.activity.isSettling
                ? sessionLog.liveness(for: state.autoName)
                : SessionLog.Liveness.pending
            if state.activity.claimAnnouncement(liveness: liveness) { toAnnounce.append(ref) }
            // Keep ticking while a finish is still waiting out its settle
            // window, otherwise the announcement would never be reached.
            if state.activity.isWorking || state.activity.isSettling { busy = true }
            states[ref] = state
        }

        if !busy {
            activityTimer?.invalidate()
            activityTimer = nil
        }

        if announcementsEnabled {
            for ref in toAnnounce {
                guard let state = states[ref] else { continue }
                herald.announce(name: state.displayName, tint: state.tint, ref: ref)
            }
        }
        if displayChanged { redrawHovered() }
    }

    /// Whether finished sessions are announced. Remembered across restarts.
    var announcementsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "announce") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "announce") }
    }

    private func scheduleHide() {
        guard pendingHide == nil else { return }
        Log.write("  Ziel verloren — Schonfrist läuft")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHide = nil
            guard self.hovered == nil else { return }
            Log.write("  ausblenden: Zeiger hat alle Fenster verlassen")
            self.freezeButton.hide()
            self.markButton.hide()
            self.panel.fadeOut()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideGrace, execute: work)
    }

    /// Hides at once and drops any pending grace period.
    private func hideNow() {
        cancelHide()
        freezeButton.hide()
        markButton.hide()
        panel.hideImmediately()
    }

    private func cancelHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    private func updateHotState(at point: CGPoint) {
        guard let hovered, states[hovered]?.dismissed == false else { return }
        let local = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        panel.overlay.setHot(panel.overlay.nameHitRect.contains(local))
    }

    private func show(_ ref: WindowRef, _ state: WindowState) {
        guard !state.dismissed else {
            Log.write("  ausblenden: Fenster ist abgewählt")
            freezeButton.hide()
            markButton.hide()
            panel.fadeOut()
            return
        }
        Log.write("  einblenden: \(state.displayName)")
        states[ref]?.activity.hasUnseenResult = false
        panel.place(at: state.frame)
        panel.overlay.configure(tint: state.tint,
                                role: state.role,
                                name: state.displayName,
                                caption: state.caption,
                                titleBarHeight: state.titleBarHeight)
        panel.overlay.setOcclusion(occluders(for: state.frame))
        panel.overlay.layoutSubtreeIfNeeded()
        panel.fadeIn()
        placeFreezeButton(for: state)
    }

    private func placeFreezeButton(for state: WindowState) {
        let slot = panel.overlay.freezeSlot
        guard slot != .zero, editing == nil else {
            freezeButton.hide()
            markButton.hide()
            return
        }
        freezeButton.show(at: slot.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
                          frozen: freezer.isFrozen(state.tty), tint: state.tint)
        let mark = panel.overlay.markSlot
        guard mark != .zero else { markButton.hide(); return }
        markButton.show(at: mark.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
                        marked: state.isMarked)
    }

    private func updateOcclusion() {
        guard let hovered, let state = states[hovered], !state.dismissed else { return }
        panel.overlay.setOcclusion(occluders(for: state.frame))
        panel.overlay.layoutSubtreeIfNeeded()
        placeFreezeButton(for: state)
    }

    /// Areas of the hovered window covered by windows in front of it, in the
    /// overlay's own coordinates. The overlay is cut away there so it never
    /// paints over something that is actually on top.
    private func occluders(for frame: CGRect) -> [CGRect] {
        guard let terminalPID = watcher.pid else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [CGRect] = []

        for entry in currentWindowList() {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw)
            else { continue }

            // Windows reported on screen but invisible (Stage Manager, other
            // Spaces) must never cut a hole into the overlay.
            guard entry[kCGWindowIsOnscreen as String] as? Bool == true,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
            else { continue }

            let cocoa = Geo.cocoaRect(fromAX: bounds)
            // The list runs front to back: once we reach our own window,
            // everything left is behind it.
            if pid == terminalPID, cocoa.isClose(to: frame, within: Self.matchTolerance) { break }

            let overlap = cocoa.intersection(frame)
            guard !overlap.isNull, overlap.width > 2, overlap.height > 2 else { continue }

            // No hit test here, deliberately. Asking the system what a click
            // would hit sounds safer but is wrong at exactly this moment: the
            // overlay itself already covers the area, so the answer is neither
            // "that other app" nor "Terminal", and treating that uncertainty as
            // "do not clip" let the overlay paint straight over the window in
            // front of it. The list order above already settles the question.
            // The whole window, not just the overlapping piece: the overlay
            // has to cut around its rounded corners, and that is only possible
            // while we still know where its real edges are. Whatever sticks
            // out beyond us is clipped by our own bounds anyway.
            result.append(CGRect(x: cocoa.minX - frame.minX,
                                 y: cocoa.minY - frame.minY,
                                 width: cocoa.width,
                                 height: cocoa.height))
        }
        return result
    }

    private func redrawHovered() {
        guard let hovered, let state = states[hovered] else { return }
        show(hovered, state)
    }

    private func pointerClicked() {
        // A click usually raises a window, and that changes nothing the
        // watcher reports — not the list, not the geometry, not the title. The
        // little mark dots would stay buried under the window they belong to,
        // which looks exactly as if clicking one had removed it. So re-stack
        // them once the raise has gone through.
        if !markDots.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.updateMarkDots()
            }
        }

        guard isEnabled, !isSuspended, editing == nil,
              let hovered, states[hovered]?.dismissed == false
        else { return }

        if nameWasHit() {
            beginEditing(hovered)
        } else if freezer.isFrozen(states[hovered]?.tty) {
            return
        } else {
            states[hovered]?.dismissed = true
            hideNow()
        }
    }

    /// Typing in the window you are hovering hides the overlay — the keystroke
    /// itself is only observed, never swallowed, so it lands in the terminal.
    private func keyPressed() {
        guard isEnabled, !isSuspended, editing == nil,
              let hovered, states[hovered]?.dismissed == false,
              watcher.isFrontmost, watcher.focusedWindow == hovered
        else { return }
        Log.write("  ausblenden: Tastendruck")
        states[hovered]?.dismissed = true
        hideNow()
    }

    /// While editing, a click outside the name field commits.
    private func localClick() {
        guard editing != nil, !nameWasHit() else { return }
        panel.overlay.commitEditing()
    }

    private func nameWasHit() -> Bool {
        let point = NSEvent.mouseLocation
        let local = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        return panel.overlay.nameHitRect.contains(local)
    }

    // MARK: - Editing

    private func beginEditing(_ ref: WindowRef) {
        guard states[ref] != nil else { return }
        editing = ref
        freezeButton.hide()
        markButton.hide()
        previousApp = NSWorkspace.shared.frontmostApplication

        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        if !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        // Automatic labels start empty so you can type straight away.
        panel.overlay.beginEditing(prefill: states[ref]?.manualName ?? "")
    }

    private func finishEditing(saving name: String?) {
        guard let ref = editing else { return }
        editing = nil
        if let name {
            // An empty entry hands the window back to its automatic label.
            states[ref]?.manualName = name.isEmpty ? nil : name
            remember(ref)
            renameSession(ref, to: name)
        }

        panel.ignoresMouseEvents = true
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil

        if hovered == ref, let state = states[ref] { show(ref, state) }
        pointerMoved(force: true)
    }

    /// Stores or drops the hand-typed name for this window, so it is found
    /// again the next time a window with the same directory and label appears.
    private func remember(_ ref: WindowRef) {
        guard var state = states[ref] else { return }
        state.directory = watcher.directory(of: ref) ?? state.directory
        if state.windowID == nil { state.windowID = windowID(matching: state.frame) }
        states[ref] = state

        var keys: [String] = []
        if let id = state.windowID { keys.append(LabelStore.windowKey(id)) }
        if let path = LabelStore.pathKey(directory: state.directory, autoName: state.autoName) {
            keys.append(path)
        }
        guard !keys.isEmpty else { return }

        if let name = state.manualName {
            LabelStore.remember(name, hue: Double(state.tint.hue),
                                directory: state.directory, for: keys)
        } else {
            LabelStore.forget(keys)
        }
    }

    /// Carries the name over into the Claude session, so the chat is called
    /// the same thing. Only for Claude windows — other programs would simply
    /// try to run "/rename" as a command.
    private func renameSession(_ ref: WindowRef, to name: String) {
        guard renameSessionsEnabled,
              let state = states[ref],
              state.role == .claude,
              !name.isEmpty,
              name != state.autoName
        else { return }
        SessionRenamer.rename(inWindowTitled: state.title, to: name)
    }

    /// Off by default is wrong here — the point is that it just happens — but
    /// it has to be switchable, since it types into a live session.
    var renameSessionsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "renameSessions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "renameSessions") }
    }

    // MARK: - Freezing

    var frozenCount: Int { freezer.count }

    func thawAll() {
        freezer.thawAll()
        for ref in Array(states.keys) where states[ref]?.activity.isFrozen == true {
            states[ref]?.activity.thaw()
        }
        refreshAttachments()
        redrawHovered()
    }

    /// The two keys a mark is filed under — the same pair as a name, so it
    /// survives a restart of this app and, as far as it can, of Terminal.
    private func markKeys(for state: WindowState) -> [String] {
        var keys: [String] = []
        if let id = state.windowID { keys.append(LabelStore.windowKey(id)) }
        if let path = LabelStore.pathKey(directory: state.directory, autoName: state.autoName) {
            keys.append(path)
        }
        return keys
    }

    /// Sets or clears the red dot. Reached from the button in the overlay and
    /// from the one in each row of the ⌥Tab overview.
    func toggleMark(_ ref: WindowRef) {
        guard var state = states[ref] else { return }
        if state.windowID == nil { state.windowID = windowID(matching: state.frame) }
        state.isMarked.toggle()
        states[ref] = state
        MarkStore.set(state.isMarked, for: markKeys(for: state))
        Log.write("Markierung: \(state.displayName) -> \(state.isMarked ? "gesetzt" : "entfernt")")
        updateMarkDots()
        if hovered == ref { placeFreezeButton(for: state) }
        redrawHovered()
    }

    var markedCount: Int { states.values.filter(\.isMarked).count }

    func clearAllMarks() {
        for ref in Array(states.keys) { states[ref]?.isMarked = false }
        MarkStore.clear()
        updateMarkDots()
        redrawHovered()
    }

    /// Brings every marked window to the front and lays them out so they
    /// cover the screen without overlapping — the point of marking a handful
    /// of windows is usually to work with all of them at once.
    func isArrangementActive(_ kind: Arrangement) -> Bool { snapshots[kind] != nil }

    /// Remembers where the given windows are, so the next press can undo it.
    private func remember(_ kind: Arrangement, _ refs: [WindowRef]) {
        var frames: [WindowRef: CGRect] = [:]
        for ref in refs { frames[ref] = states[ref]?.frame }
        snapshots[kind] = frames
    }

    /// Puts the windows back and forgets the arrangement.
    private func undo(_ kind: Arrangement) {
        guard let frames = snapshots.removeValue(forKey: kind) else { return }
        for (ref, frame) in frames where states[ref] != nil {
            watcher.setFrame(frame, for: ref)
            states[ref]?.frame = frame
        }
        Log.write("Anordnung zurückgenommen: \(frames.count) Fenster")
        refreshAttachments()
    }

    func raiseAllMarked() {
        if isArrangementActive(.tileMarked) { undo(.tileMarked); return }
        let marked = states.filter { $0.value.isMarked }
        guard !marked.isEmpty else { return }

        // Keep the reading order people already have in their head: top row
        // first, left to right.
        let ordered = marked.sorted { lhs, rhs in
            if abs(lhs.value.frame.maxY - rhs.value.frame.maxY) > 40 {
                return lhs.value.frame.maxY > rhs.value.frame.maxY
            }
            return lhs.value.frame.minX < rhs.value.frame.minX
        }

        for (ref, _) in ordered {
            pendingMinimize[ref] = false
            states[ref]?.isMinimized = false
            states[ref]?.isOnScreen = true
            watcher.raise(ref)
        }

        remember(.tileMarked, ordered.map(\.key))
        let area = tilingScreen().visibleFrame
        let frames = Tiling.grid(count: ordered.count, in: area)
        for (index, entry) in ordered.enumerated() where index < frames.count {
            watcher.setFrame(frames[index], for: entry.key)
            states[entry.key]?.frame = frames[index]
        }
        Log.write("Markierte angeordnet: \(ordered.count) auf \(Int(area.width))x\(Int(area.height))")
        refreshAttachments()
    }

    /// Every visible window onto one screen, however small they end up. No
    /// sorting beyond reading order — the point is to see all of them at once.
    func tileAllWindows() {
        if isArrangementActive(.tileAll) { undo(.tileAll); return }
        let visible = states.filter { $0.value.isOnScreen && !$0.value.isMinimized }
        guard !visible.isEmpty else { return }

        let ordered = visible.sorted { lhs, rhs in
            if abs(lhs.value.frame.maxY - rhs.value.frame.maxY) > 40 {
                return lhs.value.frame.maxY > rhs.value.frame.maxY
            }
            return lhs.value.frame.minX < rhs.value.frame.minX
        }
        remember(.tileAll, ordered.map(\.key))

        let area = tilingScreen().visibleFrame
        let frames = Tiling.grid(count: ordered.count, in: area)
        for (index, entry) in ordered.enumerated() where index < frames.count {
            watcher.setFrame(frames[index], for: entry.key)
            states[entry.key]?.frame = frames[index]
        }
        Log.write("Alle angeordnet: \(ordered.count) auf \(Int(area.width))x\(Int(area.height))")
        refreshAttachments()
    }

    /// Every window back to the size a freshly opened one would have. Only the
    /// size — nothing is moved, because that is what was asked for.
    ///
    /// Set in columns and rows rather than points: that is how Terminal itself
    /// thinks about it, so the result matches a new window exactly, whatever
    /// the font or the display.
    func resizeAllToDefault() {
        if isArrangementActive(.defaultSize) { undo(.defaultSize); return }
        let visible = states.filter { $0.value.isOnScreen && !$0.value.isMinimized }
        guard !visible.isEmpty else { return }
        remember(.defaultSize, Array(visible.keys))

        let source = """
        tell application "Terminal"
          set c to number of columns of default settings
          set r to number of rows of default settings
          repeat with w in windows
            try
              set number of columns of w to c
              set number of rows of w to r
            end try
          end repeat
          return (c as text) & "x" & (r as text)
        end tell
        """
        var error: NSDictionary?
        let answer = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let error {
            Log.write("Standardgröße fehlgeschlagen: \(error[NSAppleScript.errorMessage] ?? error)")
            snapshots[.defaultSize] = nil
            NSSound.beep()
            return
        }
        Log.write("Standardgröße gesetzt (\(answer ?? "?")) für \(visible.count) Fenster")
        // The frames we hold are stale now; let the watcher tell us the truth.
        refreshWindows()
    }

    /// The screen you are looking at, which is the one the pointer is on.
    private func tilingScreen() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Pauses a session or lets it run on. Reached from the button in the
    /// overlay and from the one in each row of the ⌥Tab overview.
    func toggleFreeze(_ ref: WindowRef) {
        guard var state = states[ref] else { return }
        if state.windowID == nil { state.windowID = windowID(matching: state.frame) }
        // Tabs can be switched, so the tty is looked up fresh on every click.
        guard let id = state.windowID, let tty = Freezer.ttys()[id] else {
            Log.write("Einfrieren: kein tty für das Fenster gefunden")
            NSSound.beep()
            return
        }
        state.tty = tty
        if freezer.isFrozen(tty) {
            freezer.thaw(tty)
            state.activity.thaw()
        } else {
            freezer.freeze(tty)
            if freezer.isFrozen(tty) { state.activity.freeze() }
        }
        states[ref] = state
        refreshAttachments()
        redrawHovered()
    }

    /// Sessions TermTint froze before it was restarted stay frozen — find
    /// their windows again so they keep their veil and button state.
    private func restoreFrozen() {
        guard freezer.count > 0 else { return }
        let ttys = Freezer.ttys()
        for ref in Array(states.keys) {
            guard let id = states[ref]?.windowID ?? states[ref].flatMap({ windowID(matching: $0.frame) }),
                  let tty = ttys[id] else { continue }
            states[ref]?.windowID = id
            states[ref]?.tty = tty
            if freezer.isFrozen(tty) { states[ref]?.activity.freeze() }
        }
        // Frozen sessions whose window is gone would hang around forever.
        let open = Set(ttys.values)
        if !ttys.isEmpty {
            for tty in freezer.frozen.keys where !open.contains(tty) { freezer.thaw(tty) }
        }
        refreshAttachments()
    }

    /// Window ids the window server is showing on the current Space right
    /// now. The stored flags are not enough: minimising a window or switching
    /// desks changes nothing the watcher reports, and a veil or a mark dot
    /// whose window went away stays lying on the desktop.
    /// Veils and mark dots together, off one list.
    private func refreshAttachments() {
        let visible = visibleWindowIDs()
        updateVeils(visible: visible)
        updateMarkDots(visible: visible)
        syncAttachmentTicker()
    }

    private func visibleWindowIDs() -> Set<Int> {
        let wanted = Set(states.values.compactMap { state -> Int? in
            guard state.isMarked || freezer.isFrozen(state.tty) else { return nil }
            return state.windowID
        })
        guard !wanted.isEmpty else { return [] }
        // The on-screen listing is the only one that reliably says what is
        // actually showing: asking about single windows by id returns a
        // description even for a minimised one, without the "is on screen"
        // flag, which made every veil vanish at once.
        invalidateWindowList()
        var result: Set<Int> = []
        for entry in currentWindowList() {
            guard let id = entry[kCGWindowNumber as String] as? Int, wanted.contains(id) else { continue }
            result.insert(id)
        }
        return result
    }

    /// Terminal does not reliably announce a window being minimised — measured
    /// on this machine: minimising posts no Accessibility notification at all,
    /// and switching desks posts nothing either. A veil or a mark dot would
    /// then stay lying on an empty desktop, which is what happened.
    ///
    /// So their visibility is checked rather than awaited. The check runs only
    /// while something is actually attached, asks about those few windows
    /// alone, and stops itself as soon as the last one is gone — at rest there
    /// is still no timer anywhere.
    private func syncAttachmentTicker() {
        let needed = !veils.isEmpty || !markDots.isEmpty
        if needed, attachmentTicker == nil {
            let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
                self?.refreshAttachments()
            }
            timer.tolerance = 0.4
            RunLoop.main.add(timer, forMode: .common)
            attachmentTicker = timer
            Log.write("Anhänger-Prüfung gestartet")
        } else if !needed, attachmentTicker != nil {
            attachmentTicker?.invalidate()
            attachmentTicker = nil
            Log.write("Anhänger-Prüfung beendet")
        }
    }

    /// The dot has to be visible when nothing is hovered, so it is its own
    /// little window stacked directly above the one it belongs to.
    private func updateMarkDots(visible: Set<Int>? = nil) {
        let onScreen = visible ?? visibleWindowIDs()
        for (ref, state) in states {
            guard state.isMarked, state.isOnScreen, !state.isMinimized,
                  let id = state.windowID, onScreen.contains(id) else {
                markDots[ref]?.hide()
                if !state.isMarked { markDots[ref] = nil }
                continue
            }
            let dot = markDots[ref] ?? MarkDot()
            dot.onClick = { [weak self] in self?.toggleMark(ref) }
            markDots[ref] = dot
            dot.show(over: state.frame, titleBarHeight: state.titleBarHeight, windowID: id)
        }
        for ref in markDots.keys where states[ref] == nil {
            markDots[ref]?.hide()
            markDots[ref] = nil
        }
    }

    /// Driven by the same events as everything else: list, focus, geometry
    /// and app changes. Stacking each veil right above its own window keeps it
    /// below whatever lies on top of that window.
    private func updateVeils(visible: Set<Int>? = nil) {
        let onScreen = visible ?? visibleWindowIDs()
        for (ref, state) in states {
            let frozen = freezer.isFrozen(state.tty)
            guard frozen, state.isOnScreen, !state.isMinimized,
                  let id = state.windowID, onScreen.contains(id) else {
                veils[ref]?.hide()
                if !frozen { veils[ref] = nil }
                continue
            }
            let veil = veils[ref] ?? FreezeVeil()
            veils[ref] = veil
            veil.show(over: state.frame, titleBarHeight: state.titleBarHeight, windowID: id)
        }
        for ref in veils.keys where states[ref] == nil {
            veils[ref]?.hide()
            veils[ref] = nil
        }
    }

    // MARK: - Hit testing

    /// A Terminal window only counts when it is genuinely the frontmost thing
    /// under the pointer — otherwise a window lying on top of it gets labelled.
    private func windowUnderPointer(_ point: CGPoint) -> WindowRef? {
        let candidates = states.filter { $0.value.isOnScreen && $0.value.frame.contains(point) }
        guard !candidates.isEmpty else { return nil }

        // Ask the system what a click here would actually hit. This is the only
        // answer that stays correct with Spaces and Stage Manager.
        let started = Log.isEnabled ? ProcessInfo.processInfo.systemUptime : 0
        let hit = watcher.hitTest(atCocoa: point)
        if Log.isEnabled {
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
            switch hit {
            case .window(let ref):
                Log.write(String(format: "  AX-Treffer: Fenster, bekannt=%@, %.1f ms",
                                 states[ref] != nil ? "ja" : "nein", ms))
            case .otherApp:
                Log.write(String(format: "  AX-Treffer: fremde App, %.1f ms", ms))
            case .unavailable:
                Log.write(String(format: "  AX-Treffer: nicht verfügbar, %.1f ms", ms))
            }
        }
        switch hit {
        case .window(let ref):
            if states[ref] != nil { return ref }
        case .otherApp:
            return nil
        case .unavailable:
            break
        }

        // Fallback: topmost Terminal window at this point, ignoring other
        // apps entirely. Permissive on purpose — showing the overlay one time
        // too many beats not showing it when it is wanted.
        if let match = match(candidates, at: point) { return match }
        invalidateWindowList()
        return match(candidates, at: point)
    }


    /// Topmost Terminal window at this point, ignoring every other app.
    private func match(_ candidates: [WindowRef: WindowState], at point: CGPoint) -> WindowRef? {
        guard let terminalPID = watcher.pid else { return nil }
        let flipTop = NSScreen.screens.first?.frame.maxY ?? 0
        let quartz = CGPoint(x: point.x, y: flipTop - point.y)

        for entry in currentWindowList() {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == terminalPID,
                  let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw),
                  bounds.contains(quartz)
            else { continue }
            let cocoa = Geo.cocoaRect(fromAX: bounds)
            if let hit = candidates.first(where: { $0.value.frame.isClose(to: cocoa, within: Self.matchTolerance) }) {
                return hit.key
            }
        }
        return nil
    }


    /// Fetched only when the hover target may have changed, then cached
    /// briefly — never polled.
    private func currentWindowList() -> [[String: Any]] {
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowListStamp < Self.listTTL { return windowList }
        windowList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]]) ?? []
        windowListStamp = now
        return windowList
    }

    private func invalidateWindowList() {
        windowListStamp = -1
        windowList = []
    }
}

private extension CGRect {
    func isClose(to other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
