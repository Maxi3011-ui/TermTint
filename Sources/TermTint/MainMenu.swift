import AppKit

/// A menu bar nobody ever sees.
///
/// TermTint runs as an accessory app, so this menu is never drawn. It is
/// installed anyway, because the standard text shortcuts are not built into
/// text fields — they come from the Edit menu. Without it, ⌘V pasted nothing
/// into the name field, ⌘A selected nothing, and ⌃⌘Space opened no emoji
/// picker: the whole point of `orderFrontCharacterPalette:` is that it lives
/// in a menu. So a name could only ever be typed on the keyboard, and an emoji
/// could not get in at all.
enum MainMenu {

    static func install() {
        let main = NSMenu()

        // AppKit treats the first entry as the application menu. It stays
        // empty on purpose — there is nothing here worth a menu item, and the
        // menu bar never shows up anyway.
        main.addItem(withTitle: "TermTint", action: nil, keyEquivalent: "")
            .submenu = NSMenu(title: "TermTint")

        let edit = NSMenu(title: "Bearbeiten")
        // Undo travels the responder chain as `undo:`; there is no Swift
        // selector for it.
        add(to: edit, "Widerrufen", Selector(("undo:")), "z")
        add(to: edit, "Wiederholen", Selector(("redo:")), "Z")
        edit.addItem(.separator())
        add(to: edit, "Ausschneiden", #selector(NSText.cut(_:)), "x")
        add(to: edit, "Kopieren", #selector(NSText.copy(_:)), "c")
        add(to: edit, "Einsetzen", #selector(NSText.paste(_:)), "v")
        add(to: edit, "Alles auswählen", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        // The system shortcut for the picker is this menu item. ⌃⌘Space is
        // delivered to it, not to the text field.
        let palette = NSMenuItem(title: "Emoji & Symbole",
                                 action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
                                 keyEquivalent: " ")
        palette.keyEquivalentModifierMask = [.control, .command]
        edit.addItem(palette)

        let editItem = NSMenuItem(title: "Bearbeiten", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private static func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
    }
}
