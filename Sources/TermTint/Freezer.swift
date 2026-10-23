import AppKit

/// Pauses a whole Terminal session with SIGSTOP and lets it continue with
/// SIGCONT — for the many Claude sessions that should stay open but need not
/// run. A frozen session uses no CPU; macOS compresses or swaps its memory
/// once something else needs it.
///
/// Sessions are keyed by tty, which is what really identifies them: the
/// window element is only the way there.
final class Freezer {

    private struct Proc {
        let pid: pid_t
        let ppid: pid_t
        let tty: String
        let stat: String
        let command: String
    }

    /// tty → frozen pids, in the order they were stopped.
    private(set) var frozen: [String: [pid_t]]

    private static let storeKey = "frozenSessions"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: [Int]] ?? [:]
        frozen = stored.mapValues { $0.map(pid_t.init) }
        // After a crash or restart of TermTint, keep only what is really still
        // stopped — anything else is a stale entry.
        let live = Dictionary(Self.processes().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for (tty, pids) in frozen where !pids.contains(where: { live[$0]?.stat.hasPrefix("T") == true }) {
            frozen[tty] = nil
        }
        save()
    }

    var count: Int { frozen.count }

    func isFrozen(_ tty: String?) -> Bool {
        guard let tty else { return false }
        return frozen[tty] != nil
    }

    /// Parents before children. The order is the whole trick: stop only the
    /// foreground program and zsh notices, takes the terminal back and the
    /// job is broken for good. With the shell stopped first it never sees it.
    func freeze(_ tty: String) {
        guard frozen[tty] == nil else { return }
        var pids: [pid_t] = []
        for proc in Self.session(on: tty) where proc.command != "login" {
            if kill(proc.pid, SIGSTOP) == 0 { pids.append(proc.pid) }
        }
        guard !pids.isEmpty else { return }
        frozen[tty] = pids
        save()
        Log.write("eingefroren: \(tty), \(pids.count) Prozesse")
    }

    /// Children first, the shell last, then a resize signal so the program
    /// redraws whatever it would have shown in the meantime.
    func thaw(_ tty: String) {
        guard let pids = frozen[tty] else { return }
        for pid in pids.reversed() { kill(pid, SIGCONT) }
        for proc in Self.processes() where pids.contains(proc.pid) && proc.stat.contains("+") {
            kill(proc.pid, SIGWINCH)
        }
        frozen[tty] = nil
        save()
        Log.write("aufgetaut: \(tty)")
    }

    func thawAll() {
        for tty in Array(frozen.keys) { thaw(tty) }
    }

    /// The tty behind each Terminal window, by window server id. Asked once per
    /// click or start — never polled.
    static func ttys() -> [Int: String] {
        let source = """
        tell application "Terminal"
          set out to ""
          repeat with w in windows
            try
              set out to out & (id of w) & " " & (tty of selected tab of w) & linefeed
            end try
          end repeat
          return out
        end tell
        """
        var error: NSDictionary?
        guard let text = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            if let error { Log.write("tty-Abfrage fehlgeschlagen: \(error[NSAppleScript.errorMessage] ?? error)") }
            return [:]
        }
        var result: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let id = Int(parts[0]) { result[id] = String(parts[1]) }
        }
        return result
    }

    // MARK: - Processes

    private func save() {
        UserDefaults.standard.set(frozen.mapValues { $0.map(Int.init) }, forKey: Self.storeKey)
    }

    private static func processes() -> [Proc] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,tty=,stat=,uid=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let uid = getuid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = pid_t(f[0]), let ppid = pid_t(f[1]),
                  UInt32(f[4]) == uid else { return nil }
            return Proc(pid: pid, ppid: ppid, tty: String(f[2]), stat: String(f[3]), command: String(f[5]))
        }
    }

    /// Everything on the tty plus all descendants (MCP servers, tool shells),
    /// sorted by depth so parents always come first.
    private static func session(on tty: String) -> [Proc] {
        let short = tty.replacingOccurrences(of: "/dev/", with: "")
        let all = processes()
        let own = ProcessInfo.processInfo.processIdentifier
        let parent = Dictionary(all.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        let children = Dictionary(grouping: all, by: \.ppid)

        func depth(_ pid: pid_t) -> Int {
            var d = 0, current = pid
            while let next = parent[current], d < 64 { d += 1; current = next }
            return d
        }

        var queue = all.filter { $0.tty == short && $0.pid != own }
        var seen = Set<pid_t>()
        var result: [Proc] = []
        while !queue.isEmpty {
            let proc = queue.removeFirst()
            guard proc.pid != own, seen.insert(proc.pid).inserted else { continue }
            result.append(proc)
            queue.append(contentsOf: children[proc.pid] ?? [])
        }
        return result.sorted { depth($0.pid) < depth($1.pid) }
    }
}

// MARK: - Button

/// The one clickable piece TermTint shows: a small panel sitting on the
/// overlay, under the name. The overlay itself stays click-through.
final class FreezeButtonPanel: NSPanel {

    var onClick: (() -> Void)?
    private let button = FreezeButtonView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 150, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Just above the overlay, which sits at .floating.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        button.onClick = { [weak self] in self?.onClick?() }
        contentView = button
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(at slot: CGRect, frozen: Bool, tint: Tint) {
        button.frozen = frozen
        button.textColor = tint.textColor
        if frame != slot { setFrame(slot, display: true) }
        orderFront(nil)
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}

private final class FreezeButtonView: NSView {

    var onClick: (() -> Void)?
    var frozen = false { didSet { if frozen != oldValue { needsDisplay = true } } }
    var textColor: NSColor = .white { didSet { needsDisplay = true } }
    private var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { hot = true }
    override func mouseExited(with event: NSEvent) { hot = false }

    static let lilac = NSColor(calibratedRed: 0.62, green: 0.42, blue: 0.96, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Self.lilac.withAlphaComponent(hot ? 0.95 : 0.78).setFill()
        shape.fill()

        let label = frozen ? "Auftauen" : "Einfrieren"
        let symbol = frozen ? "play.fill" : "snowflake"
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let glyph: CGFloat = 13
        let gap: CGFloat = 6
        let startX = bounds.midX - (glyph + gap + textSize.width) / 2

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: glyph, weight: .semibold)) {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let h = glyph * image.size.height / max(image.size.width, 1)
            tinted.draw(in: CGRect(x: startX, y: bounds.midY - h / 2, width: glyph, height: h))
        }
        (label as NSString).draw(at: CGPoint(x: startX + glyph + gap, y: bounds.midY - textSize.height / 2),
                                 withAttributes: attributes)
    }
}

// MARK: - Veil

/// Milky sheet over the body of a frozen window, so it is obvious at a glance
/// which windows are paused. Purely visual and click-through; it sits directly
/// above its own Terminal window, below anything stacked on top of it.
final class FreezeVeil: NSPanel {

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none

        let root = NSView()
        root.wantsLayer = true
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.alphaValue = 0.88
        effect.autoresizingMask = [.width, .height]
        root.addSubview(effect)

        // A sibling on top of the blur — drawing into a view that has the
        // effect view as a child leaves the window blank.
        let label = NSTextField(labelWithString: "Eingefroren")
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.80, green: 0.70, blue: 1, alpha: 1)
        let icon = NSImageView(image: NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
        icon.contentTintColor = label.textColor
        let row = NSStackView(views: [icon, label])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        contentView = root
        effect.frame = root.bounds
    }

    /// - Parameters:
    ///   - frame: the Terminal window in Cocoa coordinates
    ///   - windowID: its window server id, to stack the veil right above it
    func show(over frame: CGRect, titleBarHeight: CGFloat, windowID: Int) {
        let body = CGRect(x: frame.minX, y: frame.minY,
                          width: frame.width, height: max(0, frame.height - titleBarHeight))
        if self.frame != body {
            setFrame(body, display: true)
            contentView?.subviews.first?.frame = contentView?.bounds ?? .zero
        }
        order(.above, relativeTo: windowID)
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}
