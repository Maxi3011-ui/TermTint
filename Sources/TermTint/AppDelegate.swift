import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = HoverEngine()
    private let switcher = Switcher()
    private let inbox = CommandInbox()
    private let broadcast = Broadcast()
    private var menuBar: MenuBarController?
    private var permissionCheck: Timer?


    /// Two copies of TermTint draw two of everything: two red dots, two freeze
    /// buttons, two overlays fighting over the same window. It happened because
    /// a run straight from the build folder survived an install into
    /// /Applications. Whoever starts last wins — that is the fresh build.
    private static func endOtherCopies() {
        guard let me = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: me)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        for other in others { other.terminate() }
        // terminate() is a polite request; a copy that ignores it would keep
        // drawing, so after a moment the unpolite one follows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for other in others where !other.isTerminated { other.forceTerminate() }
        }
        Log.write("Start: \(others.count) weitere Kopie(n) von TermTint beendet")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.endOtherCopies()
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()
        broadcast.targetsProvider = { [engine] in engine.broadcastTargets() }
        engine.ownPanelFrame = { [broadcast] in broadcast.panelFrame }
        broadcast.anchorProvider = { [engine] in engine.focusedTerminalFrame() }
        engine.onLayoutChanged = { [broadcast] in broadcast.redock() }
        broadcast.onPicking = { [engine] on in engine.setPicking(on) }
        engine.onPickingFinished = { [broadcast] in broadcast.pickingFinished() }
        menuBar = MenuBarController(engine: engine, broadcast: broadcast)

        switcher.entriesProvider = { [engine] in engine.switcherEntries() }
        switcher.onActivate = { [engine] ref in engine.activate(ref) }
        switcher.onVisibilityChange = { [engine] visible in engine.setSuspended(visible) }
        switcher.isOverlayEnabled = { [engine] in engine.isEnabled }
        switcher.setOverlayEnabled = { [engine] enabled in engine.setEnabled(enabled) }
        switcher.onToggleMinimize = { [engine] ref in engine.toggleMinimize(ref) }
        switcher.onToggleFreeze = { [engine] ref in engine.toggleFreeze(ref) }
        switcher.onPark = { [engine] ref in engine.park(ref) }
        switcher.onUnpark = { [engine] session in engine.unpark(session) }
        switcher.onToggleMark = { [engine] ref in engine.toggleMark(ref) }
        switcher.onRestoreAll = { [engine] in engine.restoreAllMinimized() }
        switcher.onMinimizeFrozen = { [engine] in engine.minimizeAllFrozen() }
        switcher.onRaiseMarked = { [engine] in engine.raiseAllMarked() }
        switcher.onTileAll = { [engine] in engine.tileAllWindows() }
        switcher.onDefaultSize = { [engine] in engine.resizeAllToDefault() }
        switcher.onBroadcast = { [broadcast] in broadcast.open() }
        switcher.activeArrangements = { [engine] in
            Set([Arrangement.tileAll, .defaultSize].filter(engine.isArrangementActive))
        }
        switcher.onApplyPending = { [engine] in engine.applyPendingWindowStates() }

        if AXIsProcessTrusted() {
            start()
        } else {
            requestPermission()
        }
    }

    private func start() {
        engine.start()
        inbox.onMark = { [engine] tty, marked in engine.setMark(tty: tty, marked: marked) }
        inbox.onFront = { [engine] in engine.frontMarked() }
        inbox.onPark = { [engine] tty in engine.park(tty: tty) }
        inbox.onUnpark = { [engine] text in engine.unpark(matching: text) }
        inbox.onListParked = { [engine] in
            engine.parkedSessions.map { "\($0.id)\t\($0.name)\t\($0.directory)" }
        }
        inbox.start()

        switcher.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionCheck?.invalidate()
        // Never leave a session stopped behind with nobody to wake it.
        engine.thawAll()
    }

    /// The only timer in the app, and it stops the moment access is granted.
    private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        permissionCheck = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionCheck = nil
            self?.start()
        }
    }
}
