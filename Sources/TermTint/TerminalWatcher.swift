import AppKit
import ApplicationServices

/// Hashable wrapper so AX window elements can key a dictionary.
struct WindowRef: Hashable {
    let element: AXUIElement

    static func == (lhs: WindowRef, rhs: WindowRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

enum Geo {
    /// AX reports screen coordinates with the origin at the top-left of the
    /// primary display; Cocoa uses the bottom-left. Flipping through the
    /// primary screen's height is what keeps overlays aligned on secondary
    /// displays too.
    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The way back, for telling a window where to go.
    static func axRect(fromCocoa rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

enum AX {
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        (copy(element, attribute) as? NSNumber)?.boolValue ?? false
    }

    /// Only a definitively invalid element counts as gone. A busy or briefly
    /// unreachable app must not look like a closed window, or the window's
    /// name and colour get thrown away and come back as a fresh one.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
            != .invalidUIElement
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let posRef = copy(window, kAXPositionAttribute),
              let sizeRef = copy(window, kAXSizeAttribute),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 1, size.height > 1 else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

/// Tracks Terminal.app's windows purely through Accessibility notifications —
/// no timers, no polling. Emits coarse events; the hover engine owns the state.
final class TerminalWatcher {
    enum Event {
        case listChanged            // windows appeared or disappeared
        case geometryChanged(WindowRef)
        case titleChanged(WindowRef)
    }

    static let bundleID = "com.apple.Terminal"

    var onEvent: ((Event) -> Void)?
    private(set) var pid: pid_t?

    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var observedWindows: Set<WindowRef> = []
    /// Title changes are only worth hearing about for the window on screen.
    /// Claude Code animates a spinner in its title, so subscribing to all of
    /// them means constant traffic for text nobody is looking at.
    private var titleObserved: WindowRef?

    private let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]
    private let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        // Needed for every window, not just the visible one: the spinner glyph
        // in the title is how we learn that a session started or stopped work.
        kAXTitleChangedNotification,
    ]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        attachIfPossible()
    }

    /// A failed query and "there are no windows" look the same if you only
    /// return a dictionary — and mistaking the first for the second wipes every
    /// known window. Right after launch, and occasionally while Terminal is
    /// busy, the query really does fail.
    enum Snapshot {
        case ok([WindowRef: (frame: CGRect, title: String, minimized: Bool)])
        case unavailable(String)
    }

    /// Current windows, keyed by element, with frames already in Cocoa space.
    func snapshot() -> Snapshot {
        guard let appElement else { return .unavailable("keine Verbindung zu Terminal") }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success else { return .unavailable("AX-Fehler \(status.rawValue)") }
        guard let raw = value as? [AXUIElement] else { return .unavailable("unerwartete Antwort") }

        var result: [WindowRef: (CGRect, String, Bool)] = [:]
        for window in raw {
            // Minimised windows stay in the list — the overview shows them, and
            // reading the flag here is what keeps it off the hot path when the
            // overview opens.
            guard AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole else { continue }
            let minimized = AX.bool(window, kAXMinimizedAttribute)
            // A geometry read can fail on its own; .zero tells the caller to
            // keep whatever it already knows instead of dropping the window.
            let frame = AX.frame(of: window).map(Geo.cocoaRect(fromAX:)) ?? .zero
            let title = AX.string(window, kAXTitleAttribute) ?? ""
            result[WindowRef(element: window)] = (frame, title, minimized)
        }
        syncObservedWindows(to: Set(result.keys))
        return .ok(result)
    }

    func frame(of ref: WindowRef) -> CGRect? {
        AX.frame(of: ref.element).map(Geo.cocoaRect(fromAX:))
    }

    func title(of ref: WindowRef) -> String {
        AX.string(ref.element, kAXTitleAttribute) ?? ""
    }

    /// Follow title changes for exactly one window — the one being shown.
    func observeTitle(of ref: WindowRef?) {
        guard let observer, titleObserved != ref else { return }
        if let previous = titleObserved {
            AXObserverRemoveNotification(observer, previous.element, kAXTitleChangedNotification as CFString)
        }
        if let ref {
            AXObserverAddNotification(observer, ref.element, kAXTitleChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
        titleObserved = ref
    }

    /// Terminal keeps the window's working directory in the proxy icon, which
    /// Accessibility exposes as the window's document.
    func directory(of ref: WindowRef) -> String? {
        guard let raw = AX.string(ref.element, kAXDocumentAttribute),
              let url = URL(string: raw), url.isFileURL
        else { return nil }
        var path = url.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? nil : path
    }

    /// Accessibility hit test: which element would actually receive a click at
    /// this screen point. Unlike the window list, this respects Spaces and
    /// Stage Manager, where off-stage windows are still reported as on screen
    /// and would otherwise look like they cover everything.
    enum Hit {
        case window(WindowRef)
        case otherApp
        case unavailable
    }

    private lazy var systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // Never let an unresponsive app stall the pointer handling.
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    func hitTest(atCocoa point: CGPoint) -> Hit {
        guard let pid else { return .unavailable }
        let flipTop = NSScreen.screens.first?.frame.maxY ?? 0

        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide,
                                                     Float(point.x),
                                                     Float(flipTop - point.y),
                                                     &element)
        guard status == .success, let element else { return .unavailable }

        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success else { return .unavailable }
        // Our own click-through overlay must never count as something on top.
        if owner == ProcessInfo.processInfo.processIdentifier { return .unavailable }
        guard owner == pid else { return .otherApp }

        if let window = AX.copy(element, kAXWindowAttribute),
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            return .window(WindowRef(element: window as! AXUIElement))
        }
        if AX.string(element, kAXRoleAttribute) == kAXWindowRole {
            return .window(WindowRef(element: element))
        }
        return .unavailable
    }

    /// Height of the window's title bar, derived from where the close button
    /// sits. Falls back to the standard height if the button is unavailable.
    func titleBarHeight(of ref: WindowRef) -> CGFloat {
        let fallback: CGFloat = 28
        guard let windowFrame = AX.frame(of: ref.element),
              let button = AX.copy(ref.element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID(),
              let buttonFrame = AX.frame(of: button as! AXUIElement)
        else { return fallback }

        // AX coordinates run top-down, so the inset above the button is the
        // same as the inset below it.
        let inset = buttonFrame.minY - windowFrame.minY
        let height = inset * 2 + buttonFrame.height
        return (height > 12 && height < 80) ? height : fallback
    }

    /// The window Terminal itself considers focused.
    var focusedWindow: WindowRef? {
        guard let appElement, let value = AX.copy(appElement, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return WindowRef(element: value as! AXUIElement)
    }

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID
    }

    func isMinimized(_ ref: WindowRef) -> Bool {
        AX.bool(ref.element, kAXMinimizedAttribute)
    }

    /// Moves and resizes a window. Position is set first and again afterwards:
    /// Terminal snaps the size to whole character cells, and resizing around a
    /// fixed centre can shift the origin out from under us.
    func setFrame(_ cocoa: CGRect, for ref: WindowRef) {
        let rect = Geo.axRect(fromCocoa: cocoa)
        var origin = CGPoint(x: rect.minX, y: rect.minY)
        var size = CGSize(width: rect.width, height: rect.height)
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(ref.element, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(ref.element, kAXSizeAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(ref.element, kAXPositionAttribute as CFString, value)
        }
    }

    func setMinimized(_ minimized: Bool, for ref: WindowRef) {
        AXUIElementSetAttributeValue(ref.element,
                                     kAXMinimizedAttribute as CFString,
                                     minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Brings a window forward, the way the ⌥Tab overview expects.
    func raise(_ ref: WindowRef) {
        // A minimised window has to come out of the Dock first, otherwise
        // raising it does nothing at all.
        if AX.bool(ref.element, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(ref.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(ref.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(ref.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
    }

    // MARK: - Attachment

    @objc private func appLaunched(_ note: Notification) {
        guard runningApp(from: note)?.bundleIdentifier == Self.bundleID else { return }
        attachIfPossible()
    }

    @objc private func appTerminated(_ note: Notification) {
        guard runningApp(from: note)?.bundleIdentifier == Self.bundleID else { return }
        detach()
        onEvent?(.listChanged)
    }

    private func runningApp(from note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func attachIfPossible() {
        guard observer == nil else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID)
            .first(where: { !$0.isTerminated })
        else { return }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<TerminalWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.handle(notification as String, element)
        }
        guard AXObserverCreate(app.processIdentifier, callback, &newObserver) == .success,
              let newObserver
        else { return }

        pid = app.processIdentifier
        // Bound every query, so a busy Terminal can never stall the pointer
        // handling or the overview.
        AXUIElementSetMessagingTimeout(element, 0.4)
        appElement = element
        observer = newObserver
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in appNotifications {
            AXObserverAddNotification(newObserver, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(newObserver),
                           .defaultMode)
        onEvent?(.listChanged)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        observer = nil
        appElement = nil
        pid = nil
        observedWindows.removeAll()
        titleObserved = nil
    }

    private func syncObservedWindows(to live: Set<WindowRef>) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for ref in live.subtracting(observedWindows) {
            for name in windowNotifications {
                AXObserverAddNotification(observer, ref.element, name as CFString, refcon)
            }
        }
        if let observed = titleObserved, !live.contains(observed) { titleObserved = nil }
        for ref in observedWindows.subtracting(live) {
            for name in windowNotifications {
                AXObserverRemoveNotification(observer, ref.element, name as CFString)
            }
        }
        observedWindows = live
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        let ref = WindowRef(element: element)
        switch notification {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            onEvent?(.geometryChanged(ref))
        case kAXTitleChangedNotification:
            onEvent?(.titleChanged(ref))
        default:
            onEvent?(.listChanged)
        }
    }
}
