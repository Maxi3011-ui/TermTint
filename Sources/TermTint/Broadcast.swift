import AppKit
import Carbon.HIToolbox

/// Rundruf: one line of text, sent to several chats at once.
///
/// Twenty parallel sessions often need the same sentence — "lies die Regeln
/// neu", "commit und push". Typing it twenty times is the whole problem. The
/// field stays a palette: it takes the keyboard without activating TermTint,
/// so the terminal you are looking at keeps its own focus, and it only shows
/// itself while Terminal is the app in front.
final class Broadcast: NSObject, NSTextFieldDelegate {

    struct Target {
        let name: String
        let windowID: Int
        let tint: Tint
        let role: Role
        let isMarked: Bool
        let isMinimized: Bool
    }

    /// Every window TermTint knows, in the order the overview would show them.
    var targetsProvider: (() -> [Target])?

    private let panel = BroadcastPanel()
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let followBox = NSButton()
    private let list = NSStackView()
    private let quick = NSStackView()
    private var targets: [Target] = []
    private var checkboxes: [NSButton] = []
    private var hotKey: GlobalHotKey?

    /// Which chats are ticked by hand. Kept by name, because that is what
    /// survives a restart of Terminal — window ids do not, and a recycled id
    /// would aim the next broadcast at a window nobody picked.
    private var chosen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "broadcast") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "broadcast") }
    }

    /// Follow the red dots instead of a hand-picked list. Then the recipients
    /// are whatever is marked right now — marking a chat adds it, taking the
    /// dot off removes it, and nothing has to be kept in two places.
    private var followsMarks: Bool {
        get { UserDefaults.standard.bool(forKey: "broadcastFollowsMarks") }
        set { UserDefaults.standard.set(newValue, forKey: "broadcastFollowsMarks") }
    }

    /// Whether the field is wanted at all. It hides and comes back with
    /// Terminal, so "is it on screen" is no answer to "did he open it".
    private var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "broadcastOpen") }
        set { UserDefaults.standard.set(newValue, forKey: "broadcastOpen") }
    }

    var isVisible: Bool { isOn }

    /// Where the field is, for anything that must keep out of its way. Nil
    /// while it is not on screen.
    var panelFrame: CGRect? { panel.isVisible ? panel.frame : nil }

    override init() {
        super.init()
        build()

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }
        Log.write("Rundruf: ⌥⌘A \(hotKey == nil ? "NICHT registriert (belegt?)" : "registriert")")

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appActivated(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Second, independent signal: Terminal stepping down. If the one
        // notification is ever missed, the field must still get out of the way.
        workspace.addObserver(self, selector: #selector(appDeactivated(_:)),
                              name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(marksChanged),
                                               name: HoverEngine.marksChanged, object: nil)

        if isOn { syncVisibility(front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    }

    // MARK: - Opening and closing

    func toggle() {
        isOn ? close() : open()
    }

    func open() {
        isOn = true
        reload()
        showPanel()
        panel.makeFirstResponder(field)
    }

    func close() {
        isOn = false
        panel.orderOut(nil)
    }

    /// Only while Terminal is in front — the field is for the terminals, not
    /// something to lie over every other app.
    ///
    /// The app comes out of the notification itself, never from
    /// `frontmostApplication`: at this moment that property still names the
    /// *previous* app, so switching from Terminal to the browser read back
    /// "Terminal", the field stayed lying there, and no further notification
    /// ever came to correct it.
    @objc private func appActivated(_ note: Notification) {
        syncVisibility(front: Self.app(in: note))
    }

    @objc private func appDeactivated(_ note: Notification) {
        guard Self.app(in: note) == "com.apple.Terminal" else { return }
        // Who takes over is only known a moment later, from the activation
        // notification. Until then the field is wrong where it is.
        syncVisibility(front: nil)
    }

    private static func app(in note: Notification) -> String? {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier
    }

    private func syncVisibility(front: String?) {
        guard isOn else { return panel.orderOut(nil) }
        let wanted = front == "com.apple.Terminal" || front == Bundle.main.bundleIdentifier
        Log.write("Rundruf: vorne \(front ?? "—") -> \(wanted ? "zeigen" : "ausblenden")")
        guard wanted else { return panel.orderOut(nil) }
        if !panel.isVisible { reload() }
        showPanel()
    }

    private func showPanel() {
        if panel.frame.origin == .zero { panel.center() }
        panel.orderFrontRegardless()
        Log.write("Rundruf: sichtbar mit \(panel.frame.size)")
    }

    // MARK: - Recipients

    @objc private func marksChanged() {
        guard panel.isVisible else { return }
        reload()
    }

    /// Rebuilt every time it is shown: windows come and go, and a tick on a
    /// chat that is gone would send nothing while looking as if it had.
    private func reload() {
        targets = targetsProvider?() ?? []
        let follow = followsMarks
        followBox.state = follow ? .on : .off
        for case let button as NSButton in quick.views { button.isEnabled = !follow }

        list.setViews([], in: .leading)
        checkboxes = []

        for target in targets {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY

            let box = NSButton(checkboxWithTitle: target.name.isEmpty ? "Ohne Namen" : target.name,
                               target: self, action: #selector(tick(_:)))
            box.tag = checkboxes.count
            box.font = .systemFont(ofSize: 12)
            // While the red dots are in charge, the ticks show what that
            // means rather than pretending to be editable.
            box.state = (follow ? target.isMarked : chosen.contains(target.name)) ? .on : .off
            box.isEnabled = !follow
            checkboxes.append(box)

            row.addView(DotView(color: target.tint.base.withAlphaComponent(0.9)), in: .leading)
            if target.isMarked { row.addView(DotView(color: .systemRed), in: .leading) }
            row.addView(box, in: .leading)

            if target.isMinimized {
                let tag = NSTextField(labelWithString: "im Dock")
                tag.font = .systemFont(ofSize: 10)
                tag.textColor = .tertiaryLabelColor
                row.addView(tag, in: .leading)
            }

            list.addView(row, in: .leading)
        }

        updateStatus()
    }

    @objc private func tick(_ sender: NSButton) {
        guard targets.indices.contains(sender.tag) else { return }
        let name = targets[sender.tag].name
        var set = chosen
        if sender.state == .on { set.insert(name) } else { set.remove(name) }
        chosen = set
        updateStatus()
    }

    /// The tie-in with the red dots: on, the recipients are the marked chats
    /// and follow every dot you set; off, your own ticks count again — and
    /// they were kept while the dots were in charge, so they come back
    /// exactly as they were.
    @objc private func toggleFollow() {
        followsMarks = followBox.state == .on
        reload()
    }

    @objc private func chooseAll() {
        chosen = Set(targets.map(\.name))
        reload()
    }

    @objc private func chooseMarked() {
        chosen = Set(targets.filter(\.isMarked).map(\.name))
        reload()
    }

    @objc private func chooseNone() {
        chosen = []
        reload()
    }

    private var selectedTargets: [Target] {
        guard !followsMarks else { return targets.filter(\.isMarked) }
        let set = chosen
        return targets.filter { set.contains($0.name) }
    }

    private func updateStatus() {
        let count = selectedTargets.count
        let source = followsMarks ? " (rot)" : ""
        switch count {
        case 0: status.stringValue = followsMarks ? "Kein Chat rot markiert" : "Niemand ausgewählt"
        case 1: status.stringValue = "Enter → 1 Chat" + source
        default: status.stringValue = "Enter → \(count) Chats" + source
        }
        status.textColor = .secondaryLabelColor
    }

    // MARK: - Sending

    @objc private func send() {
        let text = field.stringValue
        let receivers = selectedTargets
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !receivers.isEmpty else {
            status.stringValue = followsMarks ? "Erst einen Chat rot markieren" : "Erst Chats auswählen"
            status.textColor = .systemOrange
            return
        }

        field.stringValue = ""
        status.stringValue = "schickt …"
        status.textColor = .secondaryLabelColor

        let ids = receivers.map(\.windowID)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sent = Self.deliver(text, to: ids)
            DispatchQueue.main.async {
                guard let self else { return }
                if sent == receivers.count {
                    self.status.stringValue = "✓ an \(sent) Chats"
                    self.status.textColor = .secondaryLabelColor
                } else {
                    self.status.stringValue = "nur \(sent) von \(receivers.count) erreicht"
                    self.status.textColor = .systemOrange
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

    // MARK: - Layout

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))

        field.placeholderString = "Prompt an die ausgewählten Chats …"
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(send)
        field.delegate = self

        status.font = .systemFont(ofSize: 11)

        followBox.setButtonType(.switch)
        followBox.title = "Den roten Punkten folgen"
        followBox.font = .systemFont(ofSize: 12)
        followBox.target = self
        followBox.action = #selector(toggleFollow)

        quick.setViews([button("Alle", #selector(chooseAll)),
                        button("Rot übernehmen", #selector(chooseMarked)),
                        button("Keiner", #selector(chooseNone))], in: .leading)
        quick.spacing = 6

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = list

        for view in [field, status, followBox, quick, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),

            followBox.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            followBox.leadingAnchor.constraint(equalTo: field.leadingAnchor),

            quick.topAnchor.constraint(equalTo: followBox.bottomAnchor, constant: 6),
            quick.leadingAnchor.constraint(equalTo: field.leadingAnchor),

            scroll.topAnchor.constraint(equalTo: quick.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            // A stack view inside a scroll view has no width of its own: left
            // to itself it collapses, and the list looks empty even though the
            // rows are there.
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            // Without these the content's "fitting size" is 24 x 126: every
            // field in it may shrink to nothing, and AppKit sizes the window
            // to exactly that when it is first shown — which is how the panel
            // came up as a bare vertical strip.
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        panel.contentView = content
        // The window owns its size; the content follows. Left to auto layout,
        // the window resizes itself to the content instead.
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        panel.setFrameAutosaveName("Rundruf")
        Log.write("Rundruf: Rahmen \(panel.frame.size), passend \(content.fittingSize)")
        // A remembered frame is a convenience, never an order. The panel once
        // came back 24 points wide — a bare strip — and restored that
        // faithfully on every launch. Anything smaller than it can sensibly
        // be is thrown away.
        if panel.frame.width < BroadcastPanel.minimum.width
            || panel.frame.height < BroadcastPanel.minimum.height {
            panel.setContentSize(NSSize(width: 360, height: 320))
            panel.center()
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let item = NSButton(title: title, target: self, action: action)
        item.bezelStyle = .rounded
        item.controlSize = .small
        item.font = .systemFont(ofSize: 11)
        return item
    }
}

/// A plain coloured dot — the window's own colour, so a row is recognised
/// without reading it.
private final class DotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Takes the keyboard without activating TermTint, so the terminal in front
/// keeps its own cursor, and stays put across desks.
final class BroadcastPanel: NSPanel {

    /// Below this the field is not a field any more.
    static let minimum = NSSize(width: 300, height: 220)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        title = "An alle"
        minSize = Self.minimum
        isFloatingPanel = true
        // Above the hover overlay. Both at .floating meant the two had no
        // defined order, and the milky veil could end up lying on top of the
        // field — the field is in front, so it has to be the higher level.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
}
