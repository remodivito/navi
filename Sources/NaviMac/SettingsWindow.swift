import AppKit

/// Navi's settings: one page of short cards under kicker headings, in Navi's ink,
/// with the Claude connection first and lit by the lamp. Everything that used to
/// crowd the menu bar menu lives here; the menu keeps only what's used every day.
final class SettingsWindow: NSWindow {
    private static var shown: SettingsWindow?
    /// The Advanced card, unfolded (for as long as Navi runs).
    private static var showAdvanced = false
    private weak var app: AppController?
    private let stack = NSStackView()
    private let width: CGFloat = 520

    static func show(app: AppController) {
        let w = shown ?? SettingsWindow(app: app)
        shown = w
        w.rebuild()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Esc closes Settings, as it would a sheet.
    override func cancelOperation(_ sender: Any?) { close() }

    /// Rebuilds the cards if the window is open (a connection changed, say).
    /// Deferred: a control asking for it is still mid-click, and mustn't be torn down under itself.
    static func refresh() { DispatchQueue.main.async { shown?.rebuild() } }

    private init(app: AppController) {
        self.app = app
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680), styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Navi Settings"
        isReleasedWhenClosed = false
        Look.inkWindow(self)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 22, bottom: 22, right: 22)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedView()
        doc.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: width), doc.widthAnchor.constraint(equalToConstant: width),
            doc.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
        ])
        scroll.documentView = doc
        // Pin the page to the scroll view's top: left to its own devices it has no size.
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        contentView = scroll
        Look.addSheen(to: scroll)
        center()
    }

    private func rebuild() {
        guard let app else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let s = Settings.shared
        stack.addArrangedSubview(header())

        // Claude: how Navi reaches it. Lit by the lamp: nothing works without it.
        let c = MainActor.assumeIsolated { Connection.shared }
        let problem = MainActor.assumeIsolated { c.activeProblem }
        let status = MainActor.assumeIsolated { c.statusLine }
        stack.addArrangedSubview(card("CLAUDE", lit: true, [
            row(s.backend == .cli ? "Claude Code" : "Anthropic API key", detail: status,
                control: problem == nil ? chip("Connected") : button("Fix…") { app.showConnection() }),
            row("Connect with", control: popup(["Claude Code", "API key"], selected: s.backend == .cli ? 0 : 1) { i in
                app.setBackend(i == 0 ? .cli : .api); Self.refresh()
            }),
            row("Model", control: popup(["Default", "Opus", "Sonnet", "Haiku"],
                                        selected: ["", "opus", "sonnet", "haiku"].firstIndex(of: s.model) ?? 0) { i in
                app.setModel(["", "opus", "sonnet", "haiku"][i])
            }),
            row("Thinking", detail: "More is slower, and a little better", control: popup(["Low", "Medium", "High"],
                selected: ["low", "medium", "high"].firstIndex(of: s.effort) ?? 1) { i in app.setEffort(["low", "medium", "high"][i]) }),
            row("Navi's own sign-in", detail: "Kept in your Keychain, so Navi stays signed in",
                control: Keychain.claudeToken == nil ? button("Set up…") { app.keepSignedIn() } : button("Remove…") { app.removeOwnSignIn(); Self.refresh() }),
            row("Connection details", control: button("Open…") { app.showConnection() }),
        ]))

        // Asking: the shortcut, typing and talking.
        let trigger = TapTrigger.Mode(rawValue: s.typeTrigger) ?? .rightOption
        let asking = [
            row("Shortcut", detail: Hotkey.isTaken(keyCode: s.hotkeyCode, modifiers: s.hotkeyMods)
                    ? "Another app owns this key: choose a different one" : "Tap it to type a question",
                control: button("\(s.hotkeyLabel) · Change…") { app.recordShortcut() }),
            row("Type to Navi with", detail: TapTrigger.conflict(trigger),
                control: popup(TapTrigger.Mode.allCases.map(\.title), selected: TapTrigger.Mode.allCases.firstIndex(of: trigger) ?? 0) { i in
                    app.setTypeTrigger(TapTrigger.Mode.allCases[i]); Self.refresh()
                }),
        ]
        // Voice (talking, reading aloud) is off while Navi is text-first: no switches for it.
        stack.addArrangedSubview(card("ASKING", asking))

        stack.addArrangedSubview(card("ON SCREEN", [
            row("Show Navi's light", detail: "The light that follows the pointer", control: toggle(s.buddy) { app.setBuddy($0) }),
        ]))

        let allowed = OnboardingWindow.permissions.filter { $0.pane != "Privacy_SpeechRecognition" && $0.pane != "Privacy_Microphone" }
            .allSatisfy { $0.granted() }
        stack.addArrangedSubview(card("PRIVACY", [
            row("Send app and document context", detail: "The app's name, its window and a short excerpt",
                control: toggle(s.context) { s.context = $0 }),
            row("Let Claude look at your Mac", detail: "Read-only: installed apps, files you mention, your past conversations. Keys and passwords are off limits.",
                control: toggle(s.readFiles) { s.readFiles = $0; app.newConversation() }),
            row("Permissions", detail: "Screen Recording and Accessibility", control: allowed ? chip("All on") : button("Set up…") { app.showSetup() }),
            row("History", detail: "Your conversations from the last 7 days", control: button("Open…") { HistoryWindow.show() }),
        ]))

        stack.addArrangedSubview(card("TEACHING", [
            row("Skills", detail: "What Navi knows about your apps, and learns as it teaches", control: button("Open folder…") { app.openSkillsFolder() }),
            row("Saved notes", detail: "What you ask Navi to keep goes in Notes, in a Navi folder",
                control: button("Open Notes…") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app")) }),
        ]))

        stack.addArrangedSubview(card("GENERAL", [
            // The switch shows what macOS says, not what was asked for: put back if it didn't take.
            row("Open at login", detail: LoginItem.awaitingApproval ? "Waiting for your OK in System Settings › Login Items" : nil,
                control: toggle(LoginItem.isOn) { if !LoginItem.set($0) { Self.refresh() } }),
            row("Crash reports", detail: "Kept on your Mac, never sent. Attach one to an issue if you'd like to help.",
                control: button("Show…") {
                    if let latest = CrashReports.reports().first { NSWorkspace.shared.activateFileViewerSelecting([latest]) }
                    else { NSWorkspace.shared.open(CrashReports.folder) }
                }),
            row("Report a problem", detail: "Opens a new issue on GitHub with your version filled in. Nothing is sent until you submit it.",
                control: button("Report…") { ReportProblem.open() }),
            row(Updates.versionLabel, detail: Updates.available ? "Updates are signed and checked before they install" : nil,
                control: Updates.available ? button("Check for updates") { Updates.checkNow() } : label("dev build", size: 12.5, colour: Look.softText)),
            row("Check for updates automatically", control: toggle(Updates.automatic) { Updates.automatic = $0 }),
        ]))

        // Fine-tuning that the defaults already get right: last, and folded until asked for.
        let fold = row("Fine-tuning", detail: "Strokes, snapping, the pointer and screen recordings",
                       control: button(Self.showAdvanced ? "Hide" : "Show…") { Self.showAdvanced.toggle(); Self.refresh() })
        stack.addArrangedSubview(card("ADVANCED", [fold] + (Self.showAdvanced ? [
            row("Hand-drawn strokes", control: toggle(s.sketch) { s.sketch = $0 }),
            row("Snap to buttons and fields", detail: "Experimental", control: toggle(s.snap) { s.snap = $0 }),
            row("Keep Navi beside the pointer", control: toggle(s.naviAlways) { app.setNaviAlways($0) }),
            row("Show Navi in screen recordings", control: toggle(s.showInRecordings) { s.showInRecordings = $0; app.applySharing() }),
        ] : [])))
        DispatchQueue.main.async { [weak self] in self?.fitHeight() }
    }

    private func fitHeight() {
        stack.layoutSubtreeIfNeeded()
        let h = min(stack.fittingSize.height, ((screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 60)
        var f = frame
        let newH = frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: h)).height
        f.origin.y += f.height - newH
        f.size = NSSize(width: frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: h)).width, height: newH)
        setFrame(f, display: true)
    }

    // MARK: Pieces

    private func header() -> NSView {
        let owl = OwlView(pixel: 2)
        let name = label("Navi", size: 18, weight: .semibold)
        let sub = label("Everything in one place, nothing more than a scroll away", size: 12.5, colour: Look.softText)
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let h = NSStackView(views: [owl, text])
        h.spacing = 10
        h.alignment = .centerY
        return h
    }

    /// A card: a kicker heading, then its rows.
    private func card(_ kicker: String, lit: Bool = false, _ rows: [NSView]) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.cornerCurve = .continuous
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
        v.layer?.borderWidth = 1
        v.layer?.borderColor = (lit ? NSColor(calibratedRed: 1, green: 0.84, blue: 0.59, alpha: 0.35) : NSColor.white.withAlphaComponent(0.07)).cgColor
        if lit {
            v.layer?.shadowColor = NSColor(calibratedRed: 1, green: 0.84, blue: 0.59, alpha: 1).cgColor
            v.layer?.shadowOpacity = 0.12
            v.layer?.shadowRadius = 14
            v.layer?.shadowOffset = .zero
        }
        let k = NSTextField(labelWithAttributedString: NSAttributedString(string: kicker, attributes: [
            .font: Look.ui(10.5, .semibold), .foregroundColor: Look.faintText, .kern: 1.3]))
        let inner = NSStackView(views: [k] + rows)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        inner.setCustomSpacing(6, after: k)
        inner.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: v.topAnchor, constant: 12), inner.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14), inner.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            v.widthAnchor.constraint(equalToConstant: width - 44),
        ])
        rows.forEach { $0.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true }
        return v
    }

    /// One setting: its name and a line of detail on the left, its control on the right.
    private func row(_ title: String, detail: String? = nil, control: NSView) -> NSView {
        let t = label(title, size: 13, weight: .medium)
        let left = NSStackView(views: [t])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 1
        if let detail {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = Look.ui(11.5)
            d.textColor = Look.softText
            d.preferredMaxLayoutWidth = 300
            left.addArrangedSubview(d)
        }
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let r = NSStackView(views: [left, control])
        r.alignment = .centerY
        r.spacing = 12
        r.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return r
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, colour: NSColor = Look.warmWhite) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Look.ui(size, weight)
        l.textColor = colour
        return l
    }

    private func chip(_ text: String) -> NSView {
        let l = label(text, size: 11.5, weight: .semibold, colour: NSColor(calibratedRed: 0.5, green: 0.88, blue: 0.79, alpha: 1))
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor(calibratedRed: 51 / 255, green: 184 / 255, blue: 158 / 255, alpha: 0.15).cgColor
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9), l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 3), l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
        ])
        return box
    }

    private func toggle(_ on: Bool, _ changed: @escaping (Bool) -> Void) -> NSView {
        let sw = ClosureSwitch()
        sw.state = on ? .on : .off
        sw.controlSize = .small
        sw.onChange = { changed($0) }
        return sw
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSView {
        let b = ClosureButton(title, action)
        return b
    }

    private func popup(_ items: [String], selected: Int, _ chose: @escaping (Int) -> Void) -> NSView {
        let p = ClosurePopUp(items: items, selected: selected, chose)
        return p
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private final class ClosureSwitch: NSSwitch {
    var onChange: ((Bool) -> Void)?
    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { onChange?(state == .on) }
}

private final class ClosureButton: InkButton {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title, target: nil, action: nil)
        target = self
        action = #selector(go)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func go() { run() }
}

private final class ClosurePopUp: NSPopUpButton {
    private let chose: (Int) -> Void
    init(items: [String], selected: Int, _ chose: @escaping (Int) -> Void) {
        self.chose = chose
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        selectItem(at: selected)
        controlSize = .small
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { chose(indexOfSelectedItem) }
}
