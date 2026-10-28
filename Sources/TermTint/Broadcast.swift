import AppKit
import Carbon.HIToolbox

/// Rundruf: one line of text, sent to several chats at once.
///
/// Twenty parallel sessions often need the same sentence — "lies die Regeln
/// neu", "commit und push". Typing it twenty times is the whole problem.
///
/// Who gets it is not picked in here. The red dots on the windows already are
/// that list: you point at the terminals you mean and set their dot, exactly
/// as for everything else TermTint does with a handful of windows at once.
/// A second list of checkboxes beside them would only be a second truth.
///
/// The bar stays a palette: it takes the keyboard without activating TermTint,
/// so the terminal you are looking at keeps its own cursor, and it shows
/// itself only while Terminal is the app in front.
final class Broadcast: NSObject, NSTextFieldDelegate {

    struct Target {
        let name: String
        let windowID: Int
        let tint: Tint
        let role: Role
        let isMarked: Bool
        let isMinimized: Bool
    }

    var targetsProvider: (() -> [Target])?

    /// The window the bar hangs under: the terminal with the keyboard. It is
    /// not a window of its own standing over everything — it belongs to the
    /// terminal you are working in and goes where that goes.
    var anchorProvider: (() -> CGRect?)?

    private let panel = BroadcastPanel()
    private let view = BroadcastView()
    private var targets: [Target] = []
    private var hotKey: GlobalHotKey?

    private var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "broadcastOpen") }
        set { UserDefaults.standard.set(newValue, forKey: "broadcastOpen") }
    }

    var isVisible: Bool { isOn }

    /// Where the bar sits, for anything that must keep out of its way.
    var panelFrame: CGRect? { panel.isVisible ? panel.frame : nil }

    override init() {
        super.init()
        panel.contentView = view
        panel.setContentSize(view.wantedSize)
        view.field.delegate = self
        view.field.target = self
        view.field.action = #selector(send)
        view.onClose = { [weak self] in self?.close() }

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appActivated(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Second, independent signal: Terminal stepping down. If the one
        // notification is ever missed, the bar must still get out of the way.
        workspace.addObserver(self, selector: #selector(appDeactivated(_:)),
                              name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(marksChanged),
                                               name: HoverEngine.marksChanged, object: nil)

        if isOn { syncVisibility(front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    }

    // MARK: - Opening and closing

    func toggle() { isOn ? close() : open() }

    func open() {
        isOn = true
        reload()
        showPanel()
        panel.makeFirstResponder(view.field)
    }

    func close() {
        isOn = false
        panel.orderOut(nil)
    }

    /// Only while Terminal is in front — the bar is for the terminals, not
    /// something to lie over every other app.
    ///
    /// The app comes out of the notification itself, never from
    /// `frontmostApplication`: at this moment that property still names the
    /// *previous* app, so switching from Terminal to the browser read back
    /// "Terminal" and the bar stayed lying there.
    @objc private func appActivated(_ note: Notification) {
        syncVisibility(front: Self.app(in: note))
    }

    @objc private func appDeactivated(_ note: Notification) {
        guard Self.app(in: note) == "com.apple.Terminal" else { return }
        syncVisibility(front: nil)
    }

    private static func app(in note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func syncVisibility(front: String?) {
        guard isOn else { return panel.orderOut(nil) }
        let wanted = front == "com.apple.Terminal" || front == Bundle.main.bundleIdentifier
        guard wanted else { return panel.orderOut(nil) }
        if !panel.isVisible { reload() }
        showPanel()
    }

    /// Follows the window it hangs under. Without one — no terminal focused,
    /// minimised, another desk — there is nothing to hang under, and the bar
    /// waits rather than floating around on its own.
    func redock() {
        guard isOn, let anchor = anchorProvider?() else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let size = view.wantedSize
        if panel.frame.size != size { panel.setContentSize(size) }
        let origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY + 12)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Bottom centre of the screen the pointer is on, like a notification
    /// bar — out of the way of the title bars, where the overlays live.
    /// Hangs the bar on the lower edge of the terminal you are working in.
    /// No remembered position, no window of its own to push around — it is
    /// part of that window for as long as it is the one in front.
    private func showPanel() {
        redock()
    }

    // MARK: - Recipients

    @objc private func marksChanged() {
        guard panel.isVisible else { return }
        reload()
    }

    private func reload() {
        targets = targetsProvider?() ?? []
        view.show(recipients: targets.filter(\.isMarked))
        redock()
    }

    private var recipients: [Target] { targets.filter(\.isMarked) }

    // MARK: - Sending

    @objc private func send() {
        let text = view.field.stringValue
        let receivers = recipients
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !receivers.isEmpty else {
            view.say(" Erst einen Chat mit dem roten Punkt markieren", warning: true)
            return
        }

        view.field.stringValue = ""
        let ids = receivers.map(\.windowID)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sent = Self.deliver(text, to: ids)
            DispatchQueue.main.async {
                guard let self else { return }
                if sent == receivers.count {
                    self.view.say("✓ an \(sent) \(sent == 1 ? "Chat" : "Chats")", warning: false)
                } else {
                    self.view.say("nur \(sent) von \(receivers.count) erreicht", warning: true)
                }
                Log.write("Rundruf: an \(sent)/\(receivers.count) Chats")
            }
        }
    }

    /// The text is handed over as an argument, never pasted into the script —
    /// a quote or a backslash in a prompt would otherwise break the script or,
    /// worse, change what it does.
    private static func deliver(_ text: String, to windowIDs: [Int]) -> Int {
        let script = """
        on run argv
          set t to item 1 of argv
          set n to 0
          tell application "Terminal"
            repeat with i from 2 to (count of argv)
              try
                do script t in selected tab of (window id ((item i of argv) as integer))
                set n to n + 1
              end try
            end repeat
          end tell
          return n
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, text] + windowIDs.map(String.init)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let answer = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(answer) ?? 0
    }

    // MARK: - Field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }
}

// MARK: - The bar itself

/// A slim HUD bar: one line to type in, underneath it who it goes to.
final class BroadcastView: NSView {

    private enum Metrics {
        static let width: CGFloat = 420
        static let padding: CGFloat = 14
        static let fieldHeight: CGFloat = 26
        static let gap: CGFloat = 10
        static let captionHeight: CGFloat = 14
        static let corner: CGFloat = 14
    }

    let field = NSTextField()
    private let caption = NSTextField(labelWithString: "")
    private let chips = ChipsView()
    private let effect = NSVisualEffectView()
    private let close = NSButton()

    var onClose: (() -> Void)?

    /// Grows with the number of recipients, never with the window.
    var wantedSize: CGSize {
        let chipsHeight = chips.height(forWidth: Metrics.width - Metrics.padding * 2)
        return CGSize(width: Metrics.width,
                      height: Metrics.padding * 2 + Metrics.fieldHeight + Metrics.gap
                          + chipsHeight + 6 + Metrics.captionHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Metrics.corner
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        addSubview(effect)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "An die markierten Chats …",
            attributes: [.font: NSFont.systemFont(ofSize: 14),
                         .foregroundColor: NSColor(white: 1, alpha: 0.35)])
        field.usesSingleLineMode = true
        addSubview(field)

        caption.font = .systemFont(ofSize: 11)
        caption.textColor = NSColor(white: 1, alpha: 0.45)
        addSubview(caption)

        addSubview(chips)

        close.isBordered = false
        close.bezelStyle = .inline
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "schließen")
        close.contentTintColor = NSColor(white: 1, alpha: 0.4)
        close.target = self
        close.action = #selector(closePressed)
        addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closePressed() { onClose?() }

    func show(recipients: [Broadcast.Target]) {
        chips.items = recipients.map { ($0.name.isEmpty ? "Ohne Namen" : $0.name, $0.tint.base) }
        switch recipients.count {
        case 0: say("Noch kein Chat markiert — roten Punkt am Fenster setzen", warning: false)
        case 1: say("⏎ schickt an 1 Chat", warning: false)
        case let count: say("⏎ schickt an \(count) Chats", warning: false)
        }
        needsLayout = true
    }

    func say(_ text: String, warning: Bool) {
        caption.stringValue = text
        caption.textColor = warning ? NSColor.systemOrange : NSColor(white: 1, alpha: 0.45)
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        let inner = bounds.insetBy(dx: Metrics.padding, dy: Metrics.padding)

        close.frame = CGRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 16, height: 16)

        field.frame = CGRect(x: inner.minX, y: inner.maxY - Metrics.fieldHeight,
                             width: inner.width - 20, height: Metrics.fieldHeight)

        let chipsHeight = chips.height(forWidth: inner.width)
        chips.frame = CGRect(x: inner.minX,
                             y: field.frame.minY - Metrics.gap - chipsHeight,
                             width: inner.width, height: chipsHeight)

        caption.frame = CGRect(x: inner.minX, y: inner.minY,
                               width: inner.width, height: Metrics.captionHeight)
    }

    /// The window's own colour next to each name, so the row of recipients is
    /// recognised the same way the overlays are.
    private final class ChipsView: NSView {

        var items: [(String, NSColor)] = [] { didSet { needsDisplay = true; needsLayout = true } }

        private enum Chip {
            static let height: CGFloat = 20
            static let spacing: CGFloat = 6
            static let inset: CGFloat = 8
            static let dot: CGFloat = 7
            static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        }

        private func width(of title: String) -> CGFloat {
            Chip.inset + Chip.dot + 5
                + ceil((title as NSString).size(withAttributes: [.font: Chip.font]).width)
                + Chip.inset
        }

        /// Wraps into as many lines as it takes — twenty marked chats must
        /// still be readable, not cut off at the edge.
        private func rows(forWidth available: CGFloat) -> [[(String, NSColor, CGFloat)]] {
            var result: [[(String, NSColor, CGFloat)]] = []
            var line: [(String, NSColor, CGFloat)] = []
            var x: CGFloat = 0
            for (title, colour) in items {
                let w = min(width(of: title), available)
                if !line.isEmpty, x + w > available {
                    result.append(line)
                    line = []
                    x = 0
                }
                line.append((title, colour, w))
                x += w + Chip.spacing
            }
            if !line.isEmpty { result.append(line) }
            return result
        }

        func height(forWidth available: CGFloat) -> CGFloat {
            let count = rows(forWidth: available).count
            guard count > 0 else { return Chip.height }
            return CGFloat(count) * Chip.height + CGFloat(count - 1) * Chip.spacing
        }

        override func draw(_ dirtyRect: NSRect) {
            let lines = rows(forWidth: bounds.width)
            guard !lines.isEmpty else { return }
            var y = bounds.maxY - Chip.height
            for line in lines {
                var x = bounds.minX
                for (title, colour, w) in line {
                    let rect = CGRect(x: x, y: y, width: w, height: Chip.height)
                    let path = NSBezierPath(roundedRect: rect, xRadius: Chip.height / 2,
                                            yRadius: Chip.height / 2)
                    NSColor(white: 1, alpha: 0.10).setFill()
                    path.fill()

                    let dot = CGRect(x: rect.minX + Chip.inset, y: rect.midY - Chip.dot / 2,
                                     width: Chip.dot, height: Chip.dot)
                    colour.withAlphaComponent(0.95).setFill()
                    NSBezierPath(ovalIn: dot).fill()

                    let text = title as NSString
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: Chip.font,
                        .foregroundColor: NSColor(white: 1, alpha: 0.85),
                    ]
                    let textRect = CGRect(x: dot.maxX + 5, y: rect.midY - 7,
                                          width: rect.maxX - Chip.inset - (dot.maxX + 5), height: 14)
                    text.draw(in: textRect, withAttributes: attributes)
                    x += w + Chip.spacing
                }
                y -= Chip.height + Chip.spacing
            }
        }
    }
}

/// Takes the keyboard without activating TermTint, so the terminal in front
/// keeps its own cursor, and stays put across desks.
final class BroadcastPanel: NSPanel {

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Without this the panel inherits the light system appearance and the
        // frosted material washes out.
        appearance = NSAppearance(named: .darkAqua)
        // Above the hover overlay. Both at .floating meant the two had no
        // defined order, and the milky veil could end up lying on top.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
