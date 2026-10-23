import AppKit
import Carbon.HIToolbox

/// ⌥Tab overview: every Terminal window as a real list, grouped by role and
/// coloured like its overlay. Hold ⌥, press Tab to walk the list, let go to
/// jump to the window you landed on.
final class Switcher {

    struct Entry {
        let ref: WindowRef
        let name: String
        let caption: String
        let tint: Tint
        let role: Role
        let isFocused: Bool
        /// "arbeitet" / "fertig vor 4 Min." / leer
        let activity: String
        let isWorking: Bool
        /// Finished, and you have not looked at it since.
        let isUnseen: Bool
        /// Sitting in the Dock — still listed, so old projects stay findable.
        let isMinimized: Bool
        /// Paused with SIGSTOP — the row button thaws it again.
        let isFrozen: Bool
    }

    var entriesProvider: (() -> [Entry])?
    var onActivate: ((WindowRef) -> Void)?
    /// Lets the hover overlay stand down while the overview is open.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Reads and flips the overlay's on/off state for the switch in the footer.
    var isOverlayEnabled: (() -> Bool)?
    var setOverlayEnabled: ((Bool) -> Void)?
    /// Clicking a row's colour dot puts that window away or brings it back.
    var onToggleMinimize: ((WindowRef) -> Void)?
    /// Clicking a row's freeze button pauses that session or lets it run on.
    var onToggleFreeze: ((WindowRef) -> Void)?
    /// Brings every minimised window back.
    var onRestoreAll: (() -> Void)?
    /// Puts every paused window into the Dock.
    var onMinimizeFrozen: (() -> Void)?
    /// Called once the overview is closed, so window changes are applied while
    /// no modifier key is held.
    var onApplyPending: (() -> Void)?

    private let panel: SwitcherPanel
    private let view = SwitcherView()
    private var hotKeys: [GlobalHotKey] = []
    private var monitors: [Any] = []

    private var entries: [Entry] = []
    private var selection = 0
    private var isShowing = false
    private var previousApp: NSRunningApplication?

    private static let roleOrder: [Role] = [.claude, .codex, .other, .shell]

    init() {
        panel = SwitcherPanel(view: view)
        view.onHover = { [weak self] index in self?.hover(index) }
        view.onClick = { [weak self] index in self?.click(index) }
        view.onToggle = { [weak self] in self?.toggleOverlay() }
        view.onDotClick = { [weak self] index in self?.toggleMinimize(index) }
        view.onFreezeClick = { [weak self] index in self?.toggleFreeze(index) }
        view.onRestoreAll = { [weak self] in self?.restoreAll() }
        view.onMinimizeFrozen = { [weak self] in self?.minimizeFrozen() }
    }

    private func minimizeFrozen() {
        guard isShowing else { return }
        onMinimizeFrozen?()
        refreshEntries()
    }

    private func restoreAll() {
        guard isShowing else { return }
        onRestoreAll?()
        refreshEntries()
    }

    /// Unlike minimising, this is carried out at once: it signals a process
    /// rather than asking Terminal to move a window, so ⌥ being held is
    /// harmless.
    private func toggleFreeze(_ index: Int) {
        guard isShowing, entries.indices.contains(index) else { return }
        onToggleFreeze?(entries[index].ref)
        selection = index
        refreshEntries()
    }

    private func toggleMinimize(_ index: Int) {
        guard isShowing, entries.indices.contains(index) else { return }
        onToggleMinimize?(entries[index].ref)
        selection = index
        refreshEntries()
    }

    private func refreshEntries() {
        entries = sorted(entriesProvider?() ?? [])
        guard !entries.isEmpty else { return }
        selection = min(selection, entries.count - 1)
        view.configure(entries: entries, selected: selection)
        view.setMinimizedCount(entries.filter(\.isMinimized).count)
        view.setFrozenCount(entries.filter { $0.isFrozen && !$0.isMinimized }.count)
        view.needsDisplay = true
    }

    /// Flips the overlay on or off without closing the overview, so the switch
    /// can be seen moving.
    private func toggleOverlay() {
        guard isShowing else { return }
        let next = !(isOverlayEnabled?() ?? true)
        setOverlayEnabled?(next)
        view.setOverlayEnabled(next)
    }

    private func hover(_ index: Int) {
        guard isShowing, entries.indices.contains(index), index != selection else { return }
        selection = index
        view.select(index)
    }

    private func click(_ index: Int) {
        guard isShowing, entries.indices.contains(index) else { return }
        selection = index
        dismiss(activating: true)
    }

    func start() {
        hotKeys = [
            GlobalHotKey(keyCode: GlobalHotKey.tabKey, modifiers: GlobalHotKey.option) { [weak self] in
                self?.step(by: 1)
            },
            GlobalHotKey(keyCode: GlobalHotKey.tabKey, modifiers: GlobalHotKey.optionShift) { [weak self] in
                self?.step(by: -1)
            },
        ].compactMap { $0 }
    }

    var isVisible: Bool { isShowing }

    // MARK: - Driving

    private func step(by delta: Int) {
        Log.write("⌥Tab empfangen (offen=\(isShowing))")
        if isShowing {
            guard !entries.isEmpty else { return }
            selection = (selection + delta + entries.count) % entries.count
            view.select(selection)
            return
        }
        show(startingOffset: delta)
    }

    private func show(startingOffset: Int) {
        entries = sorted(entriesProvider?() ?? [])
        Log.write("  Übersicht: \(entries.count) Einträge")
        guard !entries.isEmpty else {
            Log.write("  Übersicht: keine Einträge — wird nicht geöffnet")
            return
        }

        let focused = entries.firstIndex(where: \.isFocused) ?? 0
        selection = (focused + startingOffset + entries.count) % entries.count

        view.configure(entries: entries, selected: selection)
        view.setMinimizedCount(entries.filter(\.isMinimized).count)
        view.setFrozenCount(entries.filter { $0.isFrozen && !$0.isMinimized }.count)
        view.setOverlayEnabled(isOverlayEnabled?() ?? true)
        panel.present(size: view.fittingSize)

        previousApp = NSWorkspace.shared.frontmostApplication
        panel.makeKeyAndOrderFront(nil)
        if !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }

        isShowing = true
        Log.write("  Übersicht geöffnet, Größe \(Int(view.fittingSize.width))x\(Int(view.fittingSize.height))")
        onVisibilityChange?(true)
        installMonitors()
    }

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(event)
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(event)
        } as Any)
        // A click anywhere outside the overview closes it without switching.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss(activating: false)
        } as Any)
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isShowing else { return false }
        switch Int(event.keyCode) {
        case kVK_Tab:
            step(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case kVK_Escape:
            dismiss(activating: false)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            dismiss(activating: true)
            return true
        case kVK_UpArrow:
            step(by: -1)
            return true
        case kVK_DownArrow:
            step(by: 1)
            return true
        case kVK_Space:
            toggleOverlay()
            return true
        default:
            return false
        }
    }

    private func handleFlags(_ event: NSEvent) {
        guard isShowing, !event.modifierFlags.contains(.option) else { return }
        dismiss(activating: true)
    }

    private func dismiss(activating: Bool) {
        guard isShowing else { return }
        isShowing = false
        onVisibilityChange?(false)
        removeMonitors()
        panel.dismiss()

        let target = entries.indices.contains(selection) ? entries[selection] : nil
        entries = []

        if activating, let target {
            onActivate?(target.ref)
        } else if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
        onApplyPending?()
    }

    private func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            let left = Self.roleOrder.firstIndex(of: lhs.role) ?? Self.roleOrder.count
            let right = Self.roleOrder.firstIndex(of: rhs.role) ?? Self.roleOrder.count
            if left != right { return left < right }
            // Parked sessions sink to the bottom of their own family, so the
            // ones still running stay together at the top where you look.
            if lhs.isFrozen != rhs.isFrozen { return !lhs.isFrozen }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - Panel

final class SwitcherPanel: NSPanel {

    init(view: SwitcherView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Without this the panel inherits the light system appearance and the
        // frosted material washes out.
        appearance = NSAppearance(named: .darkAqua)
        level = .popUpMenu
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        alphaValue = 0
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(size: CGSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        setFrame(CGRect(origin: origin, size: size), display: false)
        contentView?.needsDisplay = true

        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        alphaValue = 0
        orderOut(nil)
    }
}

// MARK: - List

final class SwitcherView: NSView {

    private enum Metrics {
        static let width: CGFloat = 480
        static let padding: CGFloat = 12
        static let headerHeight: CGFloat = 30
        static let rowHeight: CGFloat = 42
        static let corner: CGFloat = 16
        static let footerHeight: CGFloat = 48
    }

    var onHover: ((Int) -> Void)? {
        get { rows.onHover }
        set { rows.onHover = newValue }
    }
    var onClick: ((Int) -> Void)? {
        get { rows.onClick }
        set { rows.onClick = newValue }
    }
    var onToggle: (() -> Void)? {
        get { footer.onToggle }
        set { footer.onToggle = newValue }
    }
    var onDotClick: ((Int) -> Void)? {
        get { rows.onDotClick }
        set { rows.onDotClick = newValue }
    }

    var onFreezeClick: ((Int) -> Void)? {
        get { rows.onFreezeClick }
        set { rows.onFreezeClick = newValue }
    }
    var onRestoreAll: (() -> Void)? {
        get { footer.onRestoreAll }
        set { footer.onRestoreAll = newValue }
    }

    var onMinimizeFrozen: (() -> Void)? {
        get { footer.onMinimizeFrozen }
        set { footer.onMinimizeFrozen = newValue }
    }

    private let effect = NSVisualEffectView()
    private let scrim = NSView()
    private let rows = RowsView()
    private let footer = FooterView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        // Keeps text contrast identical no matter how bright the windows
        // behind the panel happen to be.
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.34).cgColor
        scrim.autoresizingMask = [.width, .height]
        addSubview(scrim)

        // Subviews always paint over their parent's own drawing, so the rows
        // need to be a view of their own, stacked above the frosted layer.
        rows.autoresizingMask = [.width, .height]
        addSubview(rows)

        addSubview(footer)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func configure(entries: [Switcher.Entry], selected: Int) {
        rows.configure(entries: entries, selected: selected)
    }

    func select(_ index: Int) {
        rows.select(index)
    }

    func setOverlayEnabled(_ enabled: Bool) {
        footer.setEnabled(enabled)
    }

    func setMinimizedCount(_ count: Int) {
        footer.setMinimizedCount(count)
    }

    func setFrozenCount(_ count: Int) {
        footer.setFrozenCount(count)
    }

    override var fittingSize: CGSize {
        CGSize(width: Metrics.width,
               height: rows.contentHeight + Metrics.padding * 2 + Metrics.footerHeight)
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        scrim.frame = bounds
        // This view is not flipped, so the footer sits at y = 0.
        footer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.footerHeight)
        rows.frame = CGRect(x: 0, y: Metrics.footerHeight,
                            width: bounds.width, height: bounds.height - Metrics.footerHeight)
    }

    // MARK: - Rows

    // MARK: - Footer

    /// A switch that puts the hover overlay on standby without leaving the
    /// overview — the overview itself keeps working, so it is also the way back.
    private final class FooterView: NSView {

        var onToggle: (() -> Void)?
        var onRestoreAll: (() -> Void)?
        var onMinimizeFrozen: (() -> Void)?

        private var isOn = true
        private var minimizedCount = 0
        /// Frozen and still on screen — the ones the button can put away.
        private var frozenCount = 0
        private var tracking: NSTrackingArea?

        /// The footer holds two different things — an action on the left and a
        /// setting on the right — so the pointer has to say which one it means.
        private enum Zone { case none, restore, freeze, toggle }
        private var hotZone: Zone = .none

        /// Animatable through the AppKit animator proxy, which needs both the
        /// dynamic property and a declared default animation.
        @objc dynamic private var knobOffset: CGFloat = 1 {
            didSet { needsDisplay = true }
        }

        override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
            key == "knobOffset" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
        }

        private enum Switch {
            static let width: CGFloat = 42
            static let height: CGFloat = 24
            static let inset: CGFloat = 3
        }

        func setEnabled(_ enabled: Bool) {
            guard enabled != isOn else { return }
            isOn = enabled
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().knobOffset = enabled ? 1 : 0
            }
        }

        /// The button only exists while there is something to bring back.
        func setMinimizedCount(_ count: Int) {
            guard count != minimizedCount else { return }
            minimizedCount = count
            needsDisplay = true
        }

        func setFrozenCount(_ count: Int) {
            guard count != frozenCount else { return }
            frozenCount = count
            needsDisplay = true
        }

        private var restoreTitle: String {
            minimizedCount > 1 ? "Alle einblenden (\(minimizedCount))" : "Alle einblenden"
        }

        private var restoreFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }

        private var restoreRect: CGRect {
            guard minimizedCount > 0 else { return .zero }
            return CGRect(x: Metrics.padding + 3, y: bounds.midY - 14,
                          width: pillWidth(for: restoreTitle), height: 28)
        }

        private var freezeTitleLong: String {
            frozenCount > 1 ? "Eingefrorene minimieren (\(frozenCount))" : "Eingefrorene minimieren"
        }

        /// Where the left-hand buttons end: the right-hand group owns
        /// everything past this, and the two must never meet.
        private var leftLimit: CGFloat {
            let switchX = bounds.maxX - Metrics.padding - 15 - Switch.width
            return switchX - 82 - 98 - 18
        }

        private func pillWidth(for title: String, glyph: Bool = false) -> CGFloat {
            ceil((title as NSString).size(withAttributes: [.font: restoreFont]).width)
                + 26 + (glyph ? 20 : 0)
        }

        /// Both buttons rarely show at once — minimising the frozen ones turns
        /// them into restorable ones. When it does happen there is no room for
        /// two full labels, so this one shrinks to a snowflake and a count.
        private var freezeIsCompact: Bool {
            guard minimizedCount > 0 else { return false }
            let start = restoreRect.maxX + 8
            return start + pillWidth(for: freezeTitleLong) > leftLimit
        }

        private var freezeTitle: String {
            freezeIsCompact ? "\(frozenCount)" : freezeTitleLong
        }

        private var freezeRect: CGRect {
            guard frozenCount > 0 else { return .zero }
            let start = minimizedCount > 0 ? restoreRect.maxX + 8 : Metrics.padding + 3
            return CGRect(x: start, y: bounds.midY - 14,
                          width: pillWidth(for: freezeTitle, glyph: true), height: 28)
        }

        // MARK: - Pointer

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .mouseEnteredAndExited,
                                                .activeAlways, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseEntered(with event: NSEvent) {
            updateZone(convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            updateZone(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) { setZone(.none) }

        override func mouseDown(with event: NSEvent) { }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if minimizedCount > 0, restoreRect.contains(point) {
                onRestoreAll?()
            } else if frozenCount > 0, freezeRect.contains(point) {
                onMinimizeFrozen?()
            } else {
                onToggle?()
            }
        }

        private func updateZone(_ point: CGPoint) {
            if minimizedCount > 0, restoreRect.contains(point) { setZone(.restore); return }
            if frozenCount > 0, freezeRect.contains(point) { setZone(.freeze); return }
            setZone(.toggle)
        }

        private func setZone(_ zone: Zone) {
            guard zone != hotZone else { return }
            hotZone = zone
            needsDisplay = true
        }

        // MARK: - Drawing

        override func draw(_ dirtyRect: NSRect) {
            let inset = Metrics.padding

            // Hairline between the list and the footer.
            NSColor(white: 1, alpha: 0.10).setFill()
            NSBezierPath(rect: CGRect(x: inset, y: bounds.maxY - 1,
                                      width: bounds.width - inset * 2, height: 1)).fill()

            let switchX = bounds.maxX - inset - 15 - Switch.width
            let stateRect = CGRect(x: switchX - 82, y: bounds.midY - 8, width: 70, height: 16)
            let labelRect = CGRect(x: stateRect.minX - 98, y: bounds.midY - 9, width: 90, height: 18)

            if hotZone == .toggle {
                let zone = CGRect(x: labelRect.minX - 10, y: 5,
                                  width: bounds.maxX - inset - (labelRect.minX - 10),
                                  height: bounds.height - 10)
                NSColor(white: 1, alpha: 0.07).setFill()
                NSBezierPath(roundedRect: zone, xRadius: 10, yRadius: 10).fill()
            }

            drawRight(labelRect: labelRect, stateRect: stateRect, switchX: switchX)
            drawRestoreButton()
            drawFreezeButton()
        }

        private func drawRight(labelRect: CGRect, stateRect: CGRect, switchX: CGFloat) {
            let right = NSMutableParagraphStyle()
            right.alignment = .right

            NSAttributedString(string: "Overlay", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.88),
                .paragraphStyle: right,
            ]).draw(with: labelRect, options: [.usesLineFragmentOrigin])

            NSAttributedString(string: isOn ? "aktiv" : "pausiert", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor(white: 1, alpha: 0.40),
                .paragraphStyle: right,
            ]).draw(with: stateRect, options: [.usesLineFragmentOrigin])

            let track = CGRect(x: switchX, y: bounds.midY - Switch.height / 2,
                               width: Switch.width, height: Switch.height)
            let trackPath = NSBezierPath(roundedRect: track,
                                         xRadius: Switch.height / 2, yRadius: Switch.height / 2)
            (isOn ? NSColor.systemGreen.withAlphaComponent(0.85)
                  : NSColor(white: 1, alpha: 0.16)).setFill()
            trackPath.fill()
            NSColor(white: 1, alpha: isOn ? 0.18 : 0.14).setStroke()
            trackPath.lineWidth = 1
            trackPath.stroke()

            let knobSize = Switch.height - Switch.inset * 2
            let travel = Switch.width - knobSize - Switch.inset * 2
            let knob = CGRect(x: track.minX + Switch.inset + travel * knobOffset,
                              y: track.midY - knobSize / 2,
                              width: knobSize, height: knobSize)
            NSColor(white: 1, alpha: 0.97).setFill()
            NSBezierPath(ovalIn: knob).fill()
        }

        private func drawRestoreButton() {
            guard minimizedCount > 0 else { return }
            let rect = restoreRect
            let hot = hotZone == .restore

            if hot {
                NSColor(white: 1, alpha: 0.12).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            }

            let centred = NSMutableParagraphStyle()
            centred.alignment = .center
            NSAttributedString(string: restoreTitle, attributes: [
                .font: restoreFont,
                .foregroundColor: NSColor(white: 1, alpha: hot ? 0.92 : 0.55),
                .paragraphStyle: centred,
            ]).draw(with: CGRect(x: rect.minX, y: rect.midY - 8,
                                 width: rect.width, height: 16),
                    options: [.usesLineFragmentOrigin])
        }

        /// Puts every paused session into the Dock in one go — the point of
        /// freezing a window is usually that you want it out of the way.
        private func drawFreezeButton() {
            guard frozenCount > 0 else { return }
            let rect = freezeRect
            let hot = hotZone == .freeze

            FreezeButtonPanel.lilac.withAlphaComponent(hot ? 0.34 : 0.20).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()

            let colour = NSColor(white: 1, alpha: hot ? 0.95 : 0.72)
            var textLeft = rect.minX + 13

            if let symbol = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
                let glyph = NSImage(size: symbol.size, flipped: false) { bounds in
                    symbol.draw(in: bounds)
                    colour.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                glyph.draw(in: CGRect(x: textLeft, y: rect.midY - symbol.size.height / 2,
                                      width: symbol.size.width, height: symbol.size.height))
                textLeft += symbol.size.width + 6
            }

            NSAttributedString(string: freezeTitle, attributes: [
                .font: restoreFont,
                .foregroundColor: colour,
            ]).draw(with: CGRect(x: textLeft, y: rect.midY - 8,
                                 width: rect.maxX - textLeft, height: 16),
                    options: [.usesLineFragmentOrigin])
        }
    }

    private final class RowsView: NSView {

        private enum Row {
            case header(Role)
            case entry(Switcher.Entry, index: Int)
        }

        private var rows: [Row] = []
        private var selected = 0
        private var tracking: NSTrackingArea?

        var onHover: ((Int) -> Void)?
        var onClick: ((Int) -> Void)?
        var onDotClick: ((Int) -> Void)?
        var onFreezeClick: ((Int) -> Void)?
        private var hotDot: Int?
        private var hotFreeze: Int?

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let overDot = dotIndex(at: point)
            let overFreeze = freezeIndex(at: point)
            if overDot != hotDot || overFreeze != hotFreeze {
                hotDot = overDot
                hotFreeze = overFreeze
                needsDisplay = true
            }
            guard let index = index(at: point) else { return }
            onHover?(index)
        }

        override func mouseExited(with event: NSEvent) {
            guard hotDot != nil || hotFreeze != nil else { return }
            hotDot = nil
            hotFreeze = nil
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            // Swallowed so the panel does not start a window drag.
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let dot = dotIndex(at: point) {
                onDotClick?(dot)
                return
            }
            if let freeze = freezeIndex(at: point) {
                onFreezeClick?(freeze)
                return
            }
            guard let index = index(at: point) else { return }
            onClick?(index)
        }

        /// Generous target around the little colour dot — 9 points is far too
        /// small to hit comfortably.
        private func dotIndex(at point: CGPoint) -> Int? {
            guard let index = index(at: point), let row = rowFrame(for: index) else { return nil }
            let target = CGRect(x: row.minX + 6, y: row.midY - 14, width: 27, height: 28)
            return target.contains(point) ? index : nil
        }

        /// Where the freeze button sits in a row: hard right, so the eye
        /// finds it in the same place in every line.
        static func freezeFrame(in row: CGRect) -> CGRect {
            CGRect(x: row.maxX - 12 - 22, y: row.midY - 11, width: 22, height: 22)
        }

        private func freezeIndex(at point: CGPoint) -> Int? {
            guard let index = index(at: point), let row = rowFrame(for: index) else { return nil }
            return Self.freezeFrame(in: row).insetBy(dx: -4, dy: -4).contains(point) ? index : nil
        }

        private func rowFrame(for index: Int) -> CGRect? {
            var y = Metrics.padding
            for row in rows {
                switch row {
                case .header:
                    y += Metrics.headerHeight
                case .entry(_, let candidate):
                    if candidate == index {
                        return CGRect(x: Metrics.padding, y: y,
                                      width: bounds.width - Metrics.padding * 2,
                                      height: Metrics.rowHeight)
                    }
                    y += Metrics.rowHeight
                }
            }
            return nil
        }

        /// Which entry sits under a point, using the same walk as drawing.
        private func index(at point: CGPoint) -> Int? {
            var y = Metrics.padding
            for row in rows {
                switch row {
                case .header:
                    y += Metrics.headerHeight
                case .entry(_, let index):
                    let frame = CGRect(x: Metrics.padding, y: y,
                                       width: bounds.width - Metrics.padding * 2,
                                       height: Metrics.rowHeight)
                    if frame.contains(point) { return index }
                    y += Metrics.rowHeight
                }
            }
            return nil
        }

        var contentHeight: CGFloat {
            rows.reduce(0) { total, row in
                switch row {
                case .header: return total + Metrics.headerHeight
                case .entry: return total + Metrics.rowHeight
                }
            }
        }

        func configure(entries: [Switcher.Entry], selected: Int) {
            self.selected = selected
            rows = []
            var lastRole: Role?
            for (index, entry) in entries.enumerated() {
                if entry.role != lastRole {
                    rows.append(.header(entry.role))
                    lastRole = entry.role
                }
                rows.append(.entry(entry, index: index))
            }
            needsDisplay = true
        }

        func select(_ index: Int) {
            selected = index
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            var y = Metrics.padding
            for row in rows {
                switch row {
                case .header(let role):
                    draw(header: role, atTop: y)
                    y += Metrics.headerHeight
                case .entry(let entry, let index):
                    draw(entry: entry, atTop: y, isSelected: index == selected, entryIndex: index)
                    y += Metrics.rowHeight
                }
            }
        }

        private func draw(header role: Role, atTop y: CGFloat) {
            let text = NSAttributedString(string: role.label.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: role.representativeColor.withAlphaComponent(0.85),
                .kern: 1.3,
            ])
            text.draw(with: CGRect(x: Metrics.padding + 14, y: y + 11,
                                   width: bounds.width - Metrics.padding * 2 - 14, height: 16),
                      options: [.usesLineFragmentOrigin])
        }

        private func draw(entry: Switcher.Entry, atTop y: CGFloat, isSelected: Bool, entryIndex: Int) {
            let row = CGRect(x: Metrics.padding, y: y,
                             width: bounds.width - Metrics.padding * 2,
                             height: Metrics.rowHeight)

            if isSelected {
                let highlight = NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: 2),
                                             xRadius: 10, yRadius: 10)
                entry.tint.base.withAlphaComponent(0.24).setFill()
                highlight.fill()
                entry.tint.base.withAlphaComponent(0.55).setStroke()
                highlight.lineWidth = 1
                highlight.stroke()
            }

            let dot = CGRect(x: row.minX + 15, y: row.midY - 4.5, width: 9, height: 9)
            if hotDot == entryIndex {
                NSColor(white: 1, alpha: 0.16).setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -7.5, dy: -7.5)).fill()
            }
            let dotColour = entry.tint.base.withAlphaComponent(entry.role == .shell ? 0.75 : 1)
            if entry.isMinimized {
                // Hollow instead of filled: present, but put away.
                dotColour.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            } else {
                dotColour.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }

            // Drawn before any early return below, so every row keeps its
            // button — including the ones with nothing to say on the right.
            let freeze = Self.freezeFrame(in: row)
            drawFreezeButton(in: freeze, frozen: entry.isFrozen, isHot: hotFreeze == entryIndex)

            let captionWidth: CGFloat = 168
            let captionRight = freeze.minX - 8
            let nameStyle = NSMutableParagraphStyle()
            nameStyle.lineBreakMode = .byTruncatingTail
            let name = NSAttributedString(string: entry.name.isEmpty ? "Ohne Namen" : entry.name, attributes: [
                .font: NSFont.systemFont(ofSize: 14.5, weight: isSelected ? .semibold : .medium),
                .foregroundColor: NSColor(white: 1,
                                          alpha: entry.name.isEmpty ? 0.45 : (entry.isMinimized ? 0.60 : 0.95)),
                .paragraphStyle: nameStyle,
            ])
            let nameLeft = dot.maxX + 13
            name.draw(with: CGRect(x: nameLeft, y: row.midY - 10,
                                   width: max(40, captionRight - captionWidth - 12 - nameLeft), height: 20),
                      options: [.usesLineFragmentOrigin])

            // Right column: what the session is doing beats what it is called.
            var text = entry.activity.isEmpty ? entry.caption : entry.activity
            if text.isEmpty, entry.isMinimized { text = "minimiert" }
            guard !text.isEmpty else { return }

            let captionStyle = NSMutableParagraphStyle()
            captionStyle.alignment = .right
            captionStyle.lineBreakMode = .byTruncatingHead
            let font = NSFont.systemFont(ofSize: 11.5,
                                         weight: entry.isUnseen ? .semibold : .regular)
            let colour: NSColor = entry.isUnseen
                ? NSColor(white: 1, alpha: 0.92)
                : NSColor(white: 1, alpha: entry.isWorking ? 0.55 : 0.42)
            let caption = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: captionStyle,
            ])
            let captionRect = CGRect(x: captionRight - captionWidth, y: row.midY - 8,
                                     width: captionWidth, height: 18)
            caption.draw(with: captionRect, options: [.usesLineFragmentOrigin])

            // An unread result gets a dot you cannot miss — that is the whole
            // point: knowing which window wants you without reading any of them.
            if entry.isUnseen {
                let width = min(captionWidth, ceil(caption.size().width))
                let dot = CGRect(x: captionRect.maxX - width - 15, y: row.midY - 3.5,
                                 width: 7, height: 7)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }

        /// Quiet until you need it: a pale snowflake normally, the full lilac
        /// of the overlay button once the session is actually paused.
        private func drawFreezeButton(in rect: CGRect, frozen: Bool, isHot: Bool) {
            if frozen {
                FreezeButtonPanel.lilac.withAlphaComponent(isHot ? 0.95 : 0.80).setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else if isHot {
                NSColor(white: 1, alpha: 0.14).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }

            let name = frozen ? "play.fill" : "snowflake"
            let colour: NSColor = frozen
                ? NSColor(white: 1, alpha: 0.98)
                : NSColor(white: 1, alpha: isHot ? 0.88 : 0.34)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: frozen ? "Auftauen" : "Einfrieren")?
                .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold))
            else { return }
            let glyph = NSImage(size: symbol.size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                colour.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            let size = symbol.size
            glyph.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
    }
}

extension Role {
    /// Colour that stands for the whole family, used for section headers.
    var representativeColor: NSColor {
        let hue = (hues.lowerBound + hues.upperBound) / 2
        return NSColor(calibratedHue: hue,
                       saturation: self == .shell ? 0.18 : 0.70,
                       brightness: 0.98,
                       alpha: 1)
    }
}
