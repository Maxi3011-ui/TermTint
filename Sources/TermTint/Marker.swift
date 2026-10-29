import AppKit

/// A red dot you put on a window yourself — "this is the one I care about".
///
/// Independent of everything TermTint works out on its own (role, colour,
/// activity): those answer what a window *is*, this one answers what *you*
/// decided about it. It therefore has to be visible without hovering, which is
/// what `MarkDot` is for.
enum MarkStore {

    private static let defaultsKey = "marked"

    static func isMarked(anyOf keys: [String]) -> Bool {
        guard !keys.isEmpty else { return false }
        let stored = all()
        return keys.contains { stored.contains($0) }
    }

    static func set(_ marked: Bool, for keys: [String]) {
        guard !keys.isEmpty else { return }
        var stored = all()
        for key in keys {
            if marked { stored.insert(key) } else { stored.remove(key) }
        }
        UserDefaults.standard.set(Array(stored), forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static var count: Int { all().count }

    private static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }
}

/// The colour of a mark, shared by the dot on the window, the button in the
/// overlay and the one in each row of the overview.
enum MarkLook {
    static let red = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.27, alpha: 1)
}

/// The part that works when you are *not* hovering: a small red dot pinned to
/// the right end of the window's title bar, stacked directly above its own
/// window so it disappears along with it.
final class MarkDot: NSPanel {

    static let size: CGFloat = 13

    /// Clicking the dot takes the mark off — everywhere, not just here.
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        let view = MarkDotView()
        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// - Parameters:
    ///   - frame: the Terminal window in Cocoa coordinates
    ///   - windowID: its window server id, to stack the dot right above it
    /// Where the dot belongs for a given window — asked from outside too,
    /// to find out whether that spot is covered by something in front.
    static func spot(over frame: CGRect, titleBarHeight: CGFloat) -> CGRect {
        let bar = max(titleBarHeight, size + 6)
        return CGRect(x: frame.maxX - 14 - size,
                      y: frame.maxY - bar / 2 - size / 2,
                      width: size, height: size)
    }

    func show(over frame: CGRect, titleBarHeight: CGFloat, windowID: Int) {
        let spot = Self.spot(over: frame, titleBarHeight: titleBarHeight)
        if frame.width > Self.size * 4, self.frame != spot {
            setFrame(spot, display: true)
        }
        order(.above, relativeTo: windowID)
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}

private final class MarkDotView: NSView {

    var onClick: (() -> Void)?
    private var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    // Without this the first click would only bring the panel forward and be
    // swallowed — the dot has to work on the very first press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { hot = true }
    override func mouseExited(with event: NSEvent) { hot = false }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 1.5, dy: 1.5)
        // A dark ring first, so the dot stays legible on a light title bar too.
        NSColor(white: 0, alpha: 0.35).setStroke()
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -0.75, dy: -0.75))
        ring.lineWidth = 1.5
        ring.stroke()
        MarkLook.red.setFill()
        NSBezierPath(ovalIn: dot).fill()
        guard hot else { return }
        // A hint that it does something: a white core under the pointer.
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: 3, dy: 3)).fill()
    }
}

/// The round toggle that sits next to the freeze button in the overlay.
final class MarkButtonPanel: NSPanel {

    static let size = CGSize(width: 30, height: 30)

    var onClick: (() -> Void)?
    private let button = MarkButtonView()

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Just above the overlay, same as the freeze button.
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

    func show(at slot: CGRect, marked: Bool) {
        button.marked = marked
        if frame != slot { setFrame(slot, display: true) }
        orderFront(nil)
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}

private final class MarkButtonView: NSView {

    var onClick: (() -> Void)?
    var marked = false { didSet { if marked != oldValue { needsDisplay = true } } }
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

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds)
        if marked {
            MarkLook.red.withAlphaComponent(hot ? 1 : 0.88).setFill()
            circle.fill()
        } else {
            NSColor(white: 1, alpha: hot ? 0.22 : 0.13).setFill()
            circle.fill()
            // Hollow outline: the mark you could set, not one you have.
            MarkLook.red.withAlphaComponent(hot ? 0.95 : 0.65).setStroke()
            let inner = NSBezierPath(ovalIn: bounds.insetBy(dx: 9, dy: 9))
            inner.lineWidth = 1.8
            inner.stroke()
        }
        guard marked else { return }
        NSColor(white: 1, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 10.5, dy: 10.5)).fill()
    }
}
