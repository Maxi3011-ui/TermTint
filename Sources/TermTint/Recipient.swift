import AppKit

/// Who the next broadcast goes to.
///
/// Deliberately *not* the red dot: that one is Maxi's own "this is what I am
/// working on right now", and other things read it (the phone calls, the
/// overview, bringing windows forward). Tying the recipients to it would give
/// one decision two jobs. This is its own choice, made the same way — by
/// pointing at the windows themselves.
enum RecipientStore {

    private static let defaultsKey = "broadcastWindows"

    static func isChosen(anyOf keys: [String]) -> Bool {
        guard !keys.isEmpty else { return false }
        let stored = all()
        return keys.contains { stored.contains($0) }
    }

    static func set(_ chosen: Bool, for keys: [String]) {
        guard !keys.isEmpty else { return }
        var stored = all()
        for key in keys {
            if chosen { stored.insert(key) } else { stored.remove(key) }
        }
        UserDefaults.standard.set(Array(stored), forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }
}

enum RecipientLook {
    static let blue = NSColor(calibratedRed: 0.29, green: 0.66, blue: 1.0, alpha: 1)
}

/// The picking mode: while it runs, every terminal wears one of these — a
/// sheet over the whole window that catches the click itself, so tapping a
/// window picks it instead of typing into it. Tap, tap, tap, ⏎, done.
final class PickVeil: NSPanel {

    var onClick: (() -> Void)?
    /// ⏎ or esc: the picking is over.
    var onFinish: (() -> Void)?

    private let veil = PickVeilView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        veil.onClick = { [weak self] in self?.onClick?() }
        veil.onFinish = { [weak self] in self?.onFinish?() }
        contentView = veil
    }

    // It has to take the keyboard, otherwise ⏎ would land in the terminal
    // underneath and send an empty line to the session there.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(over frame: CGRect, name: String, tint: Tint, windowID: Int, chosen: Bool) {
        veil.name = name
        veil.tint = tint
        veil.chosen = chosen
        if self.frame != frame { setFrame(frame, display: true) }
        order(.above, relativeTo: windowID)
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}

private final class PickVeilView: NSView {

    var onClick: (() -> Void)?
    var onFinish: (() -> Void)?
    var name = ""
    var tint = Tint(hue: 0.1, role: .shell)
    var chosen = false { didSet { if chosen != oldValue { needsDisplay = true } } }
    private var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) { hot = true }
    override func mouseExited(with event: NSEvent) { hot = false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 53: onFinish?()   // ⏎, enter, esc
        default: NSSound.beep()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let corner: CGFloat = 10
        let sheet = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                 xRadius: corner, yRadius: corner)
        if chosen {
            tint.base.withAlphaComponent(hot ? 0.42 : 0.34).setFill()
        } else {
            NSColor(white: 0, alpha: hot ? 0.28 : 0.42).setFill()
        }
        sheet.fill()

        if chosen {
            RecipientLook.blue.setStroke()
            sheet.lineWidth = 3
            sheet.stroke()
        }

        let badge = CGRect(x: bounds.midX - 22, y: bounds.midY - 4, width: 44, height: 44)
        if chosen {
            RecipientLook.blue.setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor.white.setStroke()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: badge.minX + 13, y: badge.midY + 1))
            tick.line(to: CGPoint(x: badge.midX - 1, y: badge.minY + 13))
            tick.line(to: CGPoint(x: badge.maxX - 11, y: badge.maxY - 13))
            tick.lineWidth = 4
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            tick.stroke()
        } else {
            NSColor(white: 1, alpha: hot ? 0.9 : 0.55).setStroke()
            let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2.5
            ring.setLineDash([5, 4], count: 2, phase: 0)
            ring.stroke()
        }

        let label = (name.isEmpty ? "Ohne Namen" : name) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.95),
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: badge.minY - 26),
                   withAttributes: attributes)

        let hint = "antippen · ⏎ fertig" as NSString
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(white: 1, alpha: 0.55),
        ]
        let hintSize = hint.size(withAttributes: small)
        hint.draw(at: CGPoint(x: bounds.midX - hintSize.width / 2, y: badge.minY - 46),
                  withAttributes: small)
    }
}
