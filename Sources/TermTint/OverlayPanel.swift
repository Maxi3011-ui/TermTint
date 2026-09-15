import AppKit

/// One panel is reused for the whole app — only ever one window is hovered.
final class OverlayPanel: NSPanel {

    let overlay = OverlayView(frame: .zero)

    /// Every fade gets a token. A completion handler only acts if it is still
    /// the current one — otherwise a fade-out that was already superseded by a
    /// new fade-in would order the panel out again, a few dozen milliseconds
    /// after it appeared. That is exactly what a very brief flicker looks like
    /// when moving quickly from one window into the next.
    private var fadeToken = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        alphaValue = 0

        overlay.autoresizingMask = [.width, .height]
        contentView = overlay
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func place(at frame: CGRect) {
        guard frame != self.frame else { return }
        setFrame(frame, display: false)
    }

    func fadeIn() {
        fadeToken &+= 1
        orderFront(nil)
        guard alphaValue < 1 else { return }
        animate(to: 1, duration: 0.12)
    }

    func fadeOut(completion: (() -> Void)? = nil) {
        fadeToken &+= 1
        let token = fadeToken
        guard isVisible, alphaValue > 0 else {
            orderOut(nil)
            completion?()
            return
        }
        animate(to: 0, duration: 0.09) { [weak self] in
            guard let self, self.fadeToken == token else { return }
            self.orderOut(nil)
            completion?()
        }
    }

    func hideImmediately() {
        fadeToken &+= 1
        alphaValue = 0
        orderOut(nil)
    }

    private func animate(to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = alpha
        }, completionHandler: completion)
    }
}
