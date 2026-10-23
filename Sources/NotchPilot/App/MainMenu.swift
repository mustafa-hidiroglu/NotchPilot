import AppKit

/// The main menu of an `.accessory` app is never displayed, but AppKit still routes key
/// equivalents through it. Without an Edit menu, Command-C/V/X/A/Z do nothing in the
/// Settings window and in the island's question field.
@MainActor
enum MainMenu {
    static func install(settingsTarget: AnyObject, settingsAction: Selector) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "NotchPilot")
        let settings = NSMenuItem(title: "Settings…", action: settingsAction, keyEquivalent: ",")
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit NotchPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
