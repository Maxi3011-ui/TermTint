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
    private let list = NSStackView()
    private var targets: [Target] = []
    private var checkboxes: [NSButton] = []
    private var hotKey: GlobalHotKey?

    /// Which chats are ticked. Kept by name, because that is what survives a
    /// restart of Terminal — window ids do not, and a recycled id would aim
    /// the next broadcast at a window nobody picked.
    private var chosen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "broadcast") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "broadcast") }
    }

    /// Whether the field is wanted at all. It hides and comes back with
    /// Terminal, so "is it on screen" is no answer to "did he open it".
    private var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "broadcastOpen") }
        set { UserDefaults.standard.set(newValue, forKey: "broadcastOpen") }
    }

    var isVisible: Bool { isOn }

    override init() {
        super.init()
        build()

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appChanged),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)

        if isOn { syncVisibility() }
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
    @objc private func appChanged() {
        syncVisibility()
    }

    private func syncVisibility() {
        guard isOn else { return panel.orderOut(nil) }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if bundle == "com.apple.Terminal" || bundle == Bundle.main.bundleIdentifier {
            if !panel.isVisible { reload() }
            showPanel()
        } else {
            panel.orderOut(nil)
        }
    }

    private func showPanel() {
        if panel.frameAutosaveName.isEmpty || panel.frame.origin == .zero {
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    // MARK: - Recipients

    /// Rebuilt every time it is shown: windows come and go, and a tick on a
    /// chat that is gone would send nothing while looking as if it had.
    private func reload() {
        targets = targetsProvider?() ?? []
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
            box.state = chosen.contains(target.name) ? .on : .off
            box.font = .systemFont(ofSize: 12)
            checkboxes.append(box)

            let dot = DotView(color: target.tint.base.withAlphaComponent(0.9))
            row.addView(dot, in: .leading)
            row.addView(box, in: .leading)

            if target.isMarked {
                row.addView(DotView(color: .systemRed), in: .leading)
            }
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
        let set = chosen
        return targets.filter { set.contains($0.name) }
    }

    private func updateStatus() {
        let count = selectedTargets.count
        switch count {
        case 0: status.stringValue = "Niemand ausgewählt"
        case 1: status.stringValue = "Enter → 1 Chat"
        default: status.stringValue = "Enter → \(count) Chats"
        }
        status.textColor = .secondaryLabelColor
    }

    // MARK: - Sending

    @objc private func send() {
        let text = field.stringValue
        let receivers = selectedTargets
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !receivers.isEmpty else {
            status.stringValue = "Erst Chats auswählen"
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))

        field.placeholderString = "Prompt an die ausgewählten Chats …"
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(send)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 11)
        status.translatesAutoresizingMaskIntoConstraints = false

        let all = button("Alle", #selector(chooseAll))
        let red = button("Rot", #selector(chooseMarked))
        let none = button("Keiner", #selector(chooseNone))
        let quick = NSStackView(views: [all, red, none])
        quick.spacing = 6
        quick.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [field, status, quick, scroll] { content.addSubview(view) }

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),

            quick.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            quick.leadingAnchor.constraint(equalTo: field.leadingAnchor),

            scroll.topAnchor.constraint(equalTo: quick.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualTo: content.heightAnchor, multiplier: 0.3),
        ])

        panel.contentView = content
        panel.setFrameAutosaveName("Rundruf")
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

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        title = "An alle"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
}
