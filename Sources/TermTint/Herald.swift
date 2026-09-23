import AppKit

/// Announces, in the manner the court expects, that a session has finished.
///
/// Driven entirely by the activity transition the app already detects — no
/// timer of its own beyond the one that dismisses a banner again.
final class Herald {

    /// Jump to the window when its banner is clicked.
    var onSelect: ((WindowRef) -> Void)?

    private var banners: [BannerPanel] = []
    private var lastPhrase = -1

    /// Deliberately overdone. A notification you smirk at gets read; a polite
    /// one gets ignored after a week.
    private static let phrases = [
        "👑 Eure Allerhöchste Hoheit, es ist vollbracht.",
        "🙇 Der Diener kniet: erledigt.",
        "🫅 Untertänigst zu Euren Füßen niedergelegt.",
        "🤴 Euer Wille geschehe — er geschah.",
        "📜 Hiermit sei verkündet: vollendet.",
        "🎺 Fanfare! Das Werk ist getan.",
        "🏰 Das Reich meldet Vollzug.",
        "🫡 Befehl ausgeführt, Durchlaucht.",
        "👑 Majestät mögen geruhen hinzusehen.",
        "🛐 Wir harren Eures gnädigen Blickes.",
        "📈 Deliverable ausgeliefert, Synergien gehoben.",
        "💰 ROI realisiert. Erbitte Freigabe.",
        "📊 Alle KPI grün, Stakeholder selig.",
        "💼 Wertschöpfungskette geschlossen, Hoheit.",
        "🤝 Win-win: Ihr habt Zeit, ich hab fertig.",
        "🏦 Soll gleich Haben. Buchung abgeschlossen.",
        "💸 Das Invest hat sich amortisiert.",
        "📎 Best Practice implementiert, Excellence erreicht.",
        "🚀 Skaliert, ausgerollt, abgeschlossen. Nächstes Quartal?",
        "🧾 Aufwand verbucht, Nutzen Euer.",
    ]

    private static let maxVisible = 4

    func announce(name: String, tint: Tint, ref: WindowRef) {
        let panel = BannerPanel(phrase: nextPhrase(), name: name, tint: tint)
        panel.onClick = { [weak self, weak panel] in
            guard let panel else { return }
            self?.onSelect?(ref)
            self?.dismiss(panel)
        }
        panel.onExpire = { [weak self, weak panel] in
            guard let panel else { return }
            self?.dismiss(panel)
        }

        banners.insert(panel, at: 0)
        while banners.count > Self.maxVisible, let oldest = banners.last {
            dismiss(oldest)
        }
        layoutBanners()
        panel.appear()
    }

    private func nextPhrase() -> String {
        // Never the same line twice in a row — a herald who repeats himself
        // stops being read.
        var index = Int.random(in: 0..<Self.phrases.count)
        if index == lastPhrase { index = (index + 1) % Self.phrases.count }
        lastPhrase = index
        return Self.phrases[index]
    }

    private func dismiss(_ panel: BannerPanel) {
        guard let position = banners.firstIndex(of: panel) else { return }
        banners.remove(at: position)
        panel.vanish()
        layoutBanners()
    }

    private func layoutBanners() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        var top = area.maxY - BannerPanel.margin
        for panel in banners {
            let frame = CGRect(x: area.maxX - BannerPanel.size.width - BannerPanel.margin,
                               y: top - BannerPanel.size.height,
                               width: BannerPanel.size.width,
                               height: BannerPanel.size.height)
            panel.move(to: frame)
            top = frame.minY - 10
        }
    }
}

// MARK: - Banner

final class BannerPanel: NSPanel {

    static let size = CGSize(width: 392, height: 96)
    static let margin: CGFloat = 16
    private static let lifetime: TimeInterval = 7

    var onClick: (() -> Void)?
    var onExpire: (() -> Void)?

    private let banner: BannerView
    private var expiry: DispatchWorkItem?

    init(phrase: String, name: String, tint: Tint) {
        banner = BannerView(phrase: phrase, name: name, tint: tint)
        super.init(contentRect: CGRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        level = .popUpMenu
        isMovable = false
        hidesOnDeactivate = false
        // Visible wherever the user happens to be — including over a full
        // screen app, which is exactly where you are when you stopped looking.
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        alphaValue = 0
        contentView = banner
        banner.onClick = { [weak self] in self?.onClick?() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func move(to frame: CGRect) {
        guard frame != self.frame else { return }
        if isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                animator().setFrame(frame, display: false)
            }
        } else {
            setFrame(frame, display: false)
        }
    }

    func appear() {
        // Slide in from the right edge, so it reads as arriving.
        let target = frame
        setFrame(target.offsetBy(dx: 26, dy: 0), display: false)
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: false)
        }

        let work = DispatchWorkItem { [weak self] in self?.onExpire?() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: work)
    }

    func vanish() {
        expiry?.cancel()
        expiry = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

final class BannerView: NSView {

    var onClick: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let wash = NSView()
    private let accent = NSView()
    /// Subviews always paint over their parent's own drawing, so the text
    /// needs a view of its own, stacked above the frosted layer. Drawing it
    /// in `BannerView` itself left the card blank.
    private let content: ContentView
    private var tracking: NSTrackingArea?

    init(phrase: String, name: String, tint: Tint) {
        content = ContentView(phrase: phrase, name: name)
        super.init(frame: CGRect(origin: .zero, size: BannerPanel.size))

        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = tint.edge.cgColor

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        wash.wantsLayer = true
        wash.layer?.backgroundColor = tint.base.withAlphaComponent(0.20).cgColor
        wash.autoresizingMask = [.width, .height]
        addSubview(wash)

        // A slim bar in the window's own colour: the same cue as the overlay.
        accent.wantsLayer = true
        accent.layer?.backgroundColor = tint.base.withAlphaComponent(0.95).cgColor
        accent.layer?.cornerRadius = 2.5
        addSubview(accent)

        // The click has to be handled by the topmost view — anything below it
        // never sees the mouse.
        content.onClick = { [weak self] in self?.onClick?() }
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        effect.frame = bounds
        wash.frame = bounds
        accent.frame = CGRect(x: 16, y: 18, width: 5, height: bounds.height - 36)
        content.frame = bounds
        content.textLeft = accent.frame.maxX + 14
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { content.isHot = true }
    override func mouseExited(with event: NSEvent) { content.isHot = false }

    // MARK: - Text

    private final class ContentView: NSView {

        var onClick: (() -> Void)?
        var textLeft: CGFloat = 52 { didSet { needsDisplay = true } }
        var isHot = false { didSet { needsDisplay = true } }

        private let phrase: String
        private let name: String

        init(phrase: String, name: String) {
            self.phrase = phrase
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("unsupported") }

        // The banner never becomes key, so the very first click must count.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { }
        override func mouseUp(with event: NSEvent) { onClick?() }

        override func draw(_ dirtyRect: NSRect) {
            if isHot {
                NSColor(white: 1, alpha: 0.06).setFill()
                bounds.fill()
            }

            let width = bounds.width - textLeft - 18

            NSAttributedString(string: phrase, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.62),
            ]).draw(with: CGRect(x: textLeft, y: bounds.height - 40, width: width, height: 18),
                    options: [.usesLineFragmentOrigin])

            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: name.isEmpty ? "Ohne Namen" : name, attributes: [
                .font: BannerView.rounded(size: 18, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.96),
                .paragraphStyle: style,
            ]).draw(with: CGRect(x: textLeft, y: 22, width: width, height: 26),
                    options: [.usesLineFragmentOrigin])
        }
    }

    static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
