import AppKit

/// Menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Status-bar menu: shortcut, connection, model, effort and feature toggles. Files
/// dropped on the owl go into the lesson going now, a kept one, or the next question.
final class MenuBar: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var app: AppController?

    init(app: AppController) {
        self.app = app
        super.init()
        item.button?.image = OwlView.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        // The status item's window passes drags to its delegate: that's how the owl takes a drop.
        item.button?.window?.registerForDraggedTypes([.fileURL])
        item.button?.window?.delegate = self
    }

    // MARK: Dropping files on the owl

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        item.button?.highlight(true)
        return .link
    }

    func draggingExited(_ sender: NSDraggingInfo?) { item.button?.highlight(false) }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        let urls = fileURLs(sender)
        guard let app, !urls.isEmpty else { return false }
        // Into the lesson going now; with none, they choose a kept lesson or the next question.
        if app.inLesson { return app.attach(urls, to: .current) }
        let kept = Bookmarks.shared.all
        guard !kept.isEmpty else { return app.attach(urls, to: .current) }
        DispatchQueue.main.async { self.chooseWhere(urls, kept: kept, app: app) }
        return true
    }

    /// "Add practical3.pdf to…": each kept lesson, or the next question.
    private func chooseWhere(_ urls: [URL], kept: [Bookmark], app: AppController) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let what = Tutor.filesInWords(urls.map(\.path))
        let header = NSMenuItem(title: "Add \(what) to…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for b in kept.prefix(6) {
            let i = ActionItem("\(b.title) · \(b.progress)") { app.attach(urls, to: .kept(b.id)) }
            i.indentationLevel = 1
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("This conversation") { app.attach(urls, to: .current) })
        guard let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    /// The icon carries a small hollow dot while the connection in use isn't working.
    func updateIcon() {
        let base = OwlView.menuBarImage()
        let broken = MainActor.assumeIsolated { Connection.shared.activeProblem != nil }
        guard broken else { item.button?.image = base; return }
        let size = base.size
        let badged = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let d: CGFloat = 5.5
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.maxX - d - 0.5, y: rect.maxY - d - 0.5, width: d, height: d))
            dot.lineWidth = 1.4
            NSColor.black.setStroke()
            dot.stroke()
            return true
        }
        badged.isTemplate = true
        badged.accessibilityDescription = "Navi: not connected"
        item.button?.image = badged
    }

    /// Only what's used every day; everything else is in Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let app else { return }
        let s = Settings.shared
        menu.removeAllItems()
        let ask = ActionItem("Ask Navi…") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { app.typeNow() }   // once the menu has closed
        }
        ask.toolTip = "Or tap \(s.hotkeyLabel)"
        menu.addItem(ask)
        if Hotkey.isTaken(keyCode: s.hotkeyCode, modifiers: s.hotkeyMods) {
            menu.addItem(ActionItem("○ \(s.hotkeyLabel) is taken by another app · Change…") { app.recordShortcut() })
        }
        menu.addItem(ActionItem("New conversation") { app.newConversation() })
        menu.addItem(ActionItem("History…") { HistoryWindow.show() })
        // Lessons put down partway, to pick up where they stopped.
        let kept = Bookmarks.shared.all
        if !kept.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Carrying on", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for b in kept.prefix(4) {
                let item = ActionItem("\(b.title) · \(b.progress) · \(Self.when(b.lastUsed))") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { app.resumeLesson(b.id) }   // once the menu has closed
                }
                item.toolTip = b.next.map { "Stopped at: \($0)" }
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(statusItem(app))
        menu.addItem(.separator())
        menu.addItem(ActionItem("Report a problem…") { ReportProblem.open() })
        let settings = ActionItem("Settings…") { SettingsWindow.show(app: app) }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = ActionItem("Quit Navi") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// "today", "yesterday", a weekday within the week, else the date.
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInYesterday(d) { return "yesterday" }
        let f = DateFormatter()
        f.dateFormat = Date().timeIntervalSince(d) < 6 * 24 * 3600 ? "EEE" : "d MMM"
        return f.string(from: d)
    }

    /// One line on how things stand: "● Claude Code · Max plan", or, when something
    /// needs the user (a permission off, Claude signed out), what's wrong and "Fix…".
    private func statusItem(_ app: AppController) -> NSMenuItem {
        MainActor.assumeIsolated {
            let c = Connection.shared
            if !AX.trusted || !CGPreflightScreenCaptureAccess() {
                return ActionItem("○ " + (AX.trusted ? "Screen Recording" : "Accessibility") + " is off · Fix…") { app.showSetup() }
            }
            if c.activeProblem != nil {
                let line = c.statusLine.hasSuffix(".") ? String(c.statusLine.dropLast()) : c.statusLine
                return ActionItem("○ " + line + " · Fix…") { app.showConnection() }
            }
            let line = NSMenuItem(title: "● " + c.statusLine, action: nil, keyEquivalent: "")
            line.isEnabled = false
            return line
        }
    }
}
