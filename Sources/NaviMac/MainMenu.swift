import AppKit

/// Navi's main menu. Navi is a menu bar app, so it never shows a menu bar of its own,
/// but AppKit finds the standard editing keys through the main menu: without these
/// items ⌘V does nothing in the type bar, the API key field or the paste-the-token box.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let app = NSMenu(title: "Navi")
        app.addItem(withTitle: "About Navi", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(Actions.openSettings), keyEquivalent: ",")
        settings.target = Actions.shared
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Navi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addMenu(app)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addMenu(edit)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addMenu(window)

        NSApp.mainMenu = main
    }

    /// The menu's own actions, which need a target that outlives the menu.
    private final class Actions: NSObject {
        static let shared = Actions()
        @objc func openSettings() {
            guard let app = NSApp.delegate as? AppController else { return }
            SettingsWindow.show(app: app)
        }
    }
}

private extension NSMenu {
    func addMenu(_ submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
