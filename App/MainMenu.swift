import AppKit
import Sparkle

/// Programmatic main menu — the app's keyboard-shortcut registry. Items whose
/// actions aren't implemented yet (palette, quick open, …) stay auto-disabled
/// until their milestone lands, but the shortcuts are reserved here from day 1.
@MainActor
enum MainMenu {
    static func build(updaterController: SPUStandardUpdaterController? = nil) -> NSMenu {
        let main = NSMenu()

        // App
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Noiets",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        if let updaterController {
            let check = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            check.target = updaterController
            appMenu.addItem(check)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Noiets", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem({ let i = NSMenuItem(title: "Hide Others",
                                             action: #selector(NSApplication.hideOtherApplications(_:)),
                                             keyEquivalent: "h")
                          i.keyEquivalentModifierMask = [.command, .option]; return i }())
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Noiets", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Noiets"))

        // File
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Note", action: Selector(("newNote:")), keyEquivalent: "n")
        file.addItem({ let i = NSMenuItem(title: "New Folder", action: Selector(("newFolder:")), keyEquivalent: "n")
                       i.keyEquivalentModifierMask = [.command, .shift]; return i }())
        file.addItem(.separator())
        file.addItem(withTitle: "Save", action: Selector(("saveNote:")), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem({ let i = NSMenuItem(title: "Reveal in Finder", action: Selector(("revealInFinder:")), keyEquivalent: "r")
                       i.keyEquivalentModifierMask = [.command, .option]; return i }())
        // Deliberately no key equivalent: deleting a note should be a
        // considered action (menu or context menu), not a stray ⌘⌫.
        file.addItem(NSMenuItem(title: "Move to Trash", action: Selector(("moveNoteToTrash:")), keyEquivalent: ""))
        file.addItem(.separator())
        file.addItem({ let i = NSMenuItem(title: "Export as HTML…", action: Selector(("exportHTML:")), keyEquivalent: "e")
                       i.keyEquivalentModifierMask = [.command, .shift]; return i }())
        file.addItem(.separator())
        file.addItem({ let i = NSMenuItem(title: "Change Vault…", action: Selector(("changeVault:")), keyEquivalent: "o")
                       i.keyEquivalentModifierMask = [.command, .control]; return i }())
        main.addItem(submenu(file, title: "File"))

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem({ let i = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
                       i.keyEquivalentModifierMask = [.command, .shift]; return i }())
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem({ let i = NSMenuItem(title: "Find in Note…",
                                          action: #selector(NSResponder.performTextFinderAction(_:)),
                                          keyEquivalent: "f")
                       i.tag = NSTextFinder.Action.showFindInterface.rawValue; return i }())
        edit.addItem({ let i = NSMenuItem(title: "Search Vault…", action: Selector(("searchVault:")), keyEquivalent: "f")
                       i.keyEquivalentModifierMask = [.command, .shift]; return i }())
        main.addItem(submenu(edit, title: "Edit"))

        // View
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: Selector(("toggleSidebarPane:")), keyEquivalent: "s")
        view.addItem({ let i = NSMenuItem(title: "Toggle Backlinks", action: Selector(("toggleRightPanel:")), keyEquivalent: "0")
                       i.keyEquivalentModifierMask = [.command, .option]; return i }())
        main.addItem(submenu(view, title: "View"))

        // Navigate
        let nav = NSMenu(title: "Navigate")
        nav.addItem(withTitle: "Quick Open…", action: Selector(("quickOpen:")), keyEquivalent: "o")
        nav.addItem(withTitle: "Command Palette…", action: Selector(("commandPalette:")), keyEquivalent: "p")
        main.addItem(submenu(nav, title: "Navigate"))

        // Window
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
