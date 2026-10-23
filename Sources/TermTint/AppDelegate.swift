import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = HoverEngine()
    private let switcher = Switcher()
    private var menuBar: MenuBarController?
    private var permissionCheck: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(engine: engine)

        switcher.entriesProvider = { [engine] in engine.switcherEntries() }
        switcher.onActivate = { [engine] ref in engine.activate(ref) }
        switcher.onVisibilityChange = { [engine] visible in engine.setSuspended(visible) }
        switcher.isOverlayEnabled = { [engine] in engine.isEnabled }
        switcher.setOverlayEnabled = { [engine] enabled in engine.setEnabled(enabled) }
        switcher.onToggleMinimize = { [engine] ref in engine.toggleMinimize(ref) }
        switcher.onToggleFreeze = { [engine] ref in engine.toggleFreeze(ref) }
        switcher.onToggleMark = { [engine] ref in engine.toggleMark(ref) }
        switcher.onRestoreAll = { [engine] in engine.restoreAllMinimized() }
        switcher.onMinimizeFrozen = { [engine] in engine.minimizeAllFrozen() }
        switcher.onApplyPending = { [engine] in engine.applyPendingWindowStates() }

        if AXIsProcessTrusted() {
            start()
        } else {
            requestPermission()
        }
    }

    private func start() {
        engine.start()
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
