import AppKit
import ServiceManagement

final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine: HoverEngine
    private let menu = NSMenu()

    init(engine: HoverEngine) {
        self.engine = engine
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "square.text.square",
                                           accessibilityDescription: "TermTint")
        statusItem.button?.image?.isTemplate = true
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let trusted = AXIsProcessTrusted()
        if !trusted {
            let warning = NSMenuItem(title: "Bedienungshilfen freigeben …",
                                     action: #selector(openAccessibilitySettings),
                                     keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        let status = NSMenuItem(title: statusLine(trusted: trusted), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: engine.isEnabled ? "Pausieren" : "Aktivieren",
                                action: #selector(toggleEnabled),
                                keyEquivalent: "t")
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        menu.addItem(toggle)

        let shuffle = NSMenuItem(title: "Farben neu würfeln", action: #selector(reshuffle), keyEquivalent: "")
        shuffle.target = self
        shuffle.isEnabled = engine.windowCount > 0
        menu.addItem(shuffle)

        let announce = NSMenuItem(title: "Fertig-Meldungen", action: #selector(toggleAnnouncements), keyEquivalent: "")
        announce.target = self
        announce.state = engine.announcementsEnabled ? .on : .off
        menu.addItem(announce)

        let clear = NSMenuItem(title: "Alle Namen löschen", action: #selector(clearNames), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = engine.windowCount > 0
        menu.addItem(clear)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Bei Anmeldung starten", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "TermTint beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func statusLine(trusted: Bool) -> String {
        guard trusted else { return "Keine Berechtigung" }
        guard engine.isEnabled else { return "Pausiert" }
        switch engine.windowCount {
        case 0: return "Kein Terminal-Fenster"
        case 1: return "1 Fenster"
        case let count: return "\(count) Fenster"
        }
    }

    @objc private func toggleEnabled() {
        engine.setEnabled(!engine.isEnabled)
    }

    @objc private func reshuffle() {
        engine.reshuffleColors()
    }

    @objc private func toggleAnnouncements() {
        engine.announcementsEnabled = !engine.announcementsEnabled
    }

    @objc private func clearNames() {
        engine.clearNames()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
