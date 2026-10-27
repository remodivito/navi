import AppKit

/// The "Connect to Claude" part of the setup window: one row for Claude Code
/// and one for an API key, each with its live status, a radio to use it, and,
/// when it needs the user, the one next step under it. Claude Code's step is one
/// button, Connect Claude (`ConnectClaude`): install if needed, then sign in in the
/// browser. Terminal stays as the fallback, one link away.
final class ConnectionSection: NSStackView {
    /// The user picked a connection (AppController starts it).
    var onChoose: ((Backend) -> Void)?
    /// The section changed height (a step appeared or went away).
    var onResize: (() -> Void)?

    private static let textWidth: CGFloat = 310
    private static let indent: CGFloat = 38
    private static let green = NSColor(calibratedRed: 60 / 255, green: 200 / 255, blue: 168 / 255, alpha: 1)   // step green
    private static let amber = NSColor(calibratedRed: 1, green: 0.72, blue: 0.35, alpha: 1)
    static let loginCommand = "claude auth login --claudeai"
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    private let cliRow = Row(name: "Claude Code", backend: .cli)
    private let keyRow = Row(name: "Anthropic API key", backend: .api)

    // Claude Code's next step.
    private let cliStep = NSStackView()
    private let cliChip = CommandChip()
    private let cliHint = ConnectionSection.label("", size: 12, color: Look.faintText)
    private lazy var openTerminal = InkButton("Open Terminal", target: self, action: #selector(openTerminalApp))
    private lazy var installGuide = InkButton("Install guide", target: self, action: #selector(openInstallGuide))
    private lazy var locate = InkButton("Locate claude…", target: self, action: #selector(locateClaude))
    private lazy var tryAgain = InkButton("Try again", target: self, action: #selector(recheck))
    private lazy var connect = InkButton("Connect Claude", role: .primary, target: self, action: #selector(connectClaude))
    private lazy var terminalWay = InkButton("Use Terminal instead", target: self, action: #selector(useTerminal))
    /// Connect Claude's progress, what went wrong last, and whether they chose Terminal instead.
    private var connecting: ConnectClaude.Stage?
    private var connectProblem: String?
    private var showTerminal = false

    // The key's entry and its saved state.
    private let keyStep = NSStackView()
    private let keyField = KeyField()
    private lazy var checkKey = InkButton("Check key", target: self, action: #selector(saveKey))
    private let keyError = ConnectionSection.label("", size: 12, color: ConnectionSection.amber)
    private let keyFooter = NSTextField(labelWithString: "")
    private let keySaved = NSStackView()
    private lazy var addKey = InkButton("Add a key…", target: self, action: #selector(showKeyEntry))
    private lazy var replaceKey = InkButton("Replace", target: self, action: #selector(showKeyEntry))
    private lazy var removeKey = InkButton("Remove", target: self, action: #selector(removeSavedKey))
    private var editingKey = false
    private var checking = false

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0

        addArrangedSubview(Self.sectionLabel("CONNECT TO CLAUDE"))
        setCustomSpacing(14, after: arrangedSubviews.last!)

        for row in [cliRow, keyRow] {
            row.radio.target = self
            row.radio.action = #selector(choose(_:))
            row.use.target = self
            row.use.action = #selector(choose(_:))
        }

        addArrangedSubview(cliRow)
        setCustomSpacing(10, after: cliRow)
        cliStep.orientation = .vertical
        cliStep.alignment = .leading
        cliStep.spacing = 8
        cliStep.edgeInsets = NSEdgeInsets(top: 0, left: Self.indent, bottom: 0, right: 0)
        let cliButtons = NSStackView(views: [connect, terminalWay, cliChip, openTerminal, installGuide, locate, tryAgain])
        cliButtons.spacing = 8
        cliStep.addArrangedSubview(cliButtons)
        cliHint.preferredMaxLayoutWidth = 420
        cliStep.addArrangedSubview(cliHint)
        addArrangedSubview(cliStep)
        setCustomSpacing(18, after: cliStep)

        addArrangedSubview(keyRow)
        setCustomSpacing(10, after: keyRow)
        keyStep.orientation = .vertical
        keyStep.alignment = .leading
        keyStep.spacing = 8
        keyStep.edgeInsets = NSEdgeInsets(top: 0, left: Self.indent, bottom: 0, right: 0)
        keyField.onSubmit = { [weak self] in self?.saveKey() }
        keyField.onPaste = { [weak self] in self?.saveKey() }
        let entry = NSStackView(views: [keyField, checkKey])
        entry.spacing = 8
        keyStep.addArrangedSubview(entry)
        keyError.preferredMaxLayoutWidth = 420
        keyStep.addArrangedSubview(keyError)
        keyFooter.allowsEditingTextAttributes = true
        keyFooter.isSelectable = true
        let link = NSMutableAttributedString(string: "Get a key ↗", attributes: [
            .font: Look.ui(12, .medium), .foregroundColor: OverlayView.ink,
            .link: URL(string: "https://platform.claude.com/settings/keys")!])
        link.append(NSAttributedString(string: "   Stored only in your Mac's Keychain, and sent only to Anthropic.",
                                       attributes: [.font: Look.ui(12), .foregroundColor: Look.faintText]))
        keyFooter.attributedStringValue = link
        keyStep.addArrangedSubview(keyFooter)
        addArrangedSubview(keyStep)
        keySaved.spacing = 8
        keySaved.edgeInsets = NSEdgeInsets(top: 0, left: Self.indent, bottom: 0, right: 0)
        keySaved.addArrangedSubview(addKey)
        keySaved.addArrangedSubview(replaceKey)
        keySaved.addArrangedSubview(removeKey)
        addArrangedSubview(keySaved)

        MainActor.assumeIsolated {
            Connection.shared.onChange.append { [weak self] in self?.update() }
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Redraws every status from `Connection.shared`'s last answer.
    func update() {
        MainActor.assumeIsolated { render(Connection.shared) }
    }

    @MainActor private func render(_ c: Connection) {
        let chosen = Settings.shared.backend
        let wasHidden = (cliStep.isHidden, keyStep.isHidden, keySaved.isHidden, keyError.isHidden)

        // Claude Code.
        var cliText: String, cliIcon: Icon
        var cliReady = false
        cliChip.isHidden = true
        [openTerminal, installGuide, locate, tryAgain, connect, terminalWay].forEach { $0.isHidden = true }
        cliHint.stringValue = ""
        switch c.claudeCode {
        case .checking:
            (cliText, cliIcon) = ("Looking for Claude Code on this Mac…", .checking)
        case .ready(let s):
            cliReady = true
            cliText = s.billsAPI ? "Signed in with a Console account, so answers are billed to the API."
                                 : "Connected · \(s.planName). No key needed."
            cliIcon = .ready
        case .problem(let p, _):
            (cliText, cliIcon) = (p.sentence, .needsYou)
            let oneClick = !showTerminal && [.notSignedIn, .signInExpired, .notInstalled].contains(p)
            if oneClick { offerConnect(install: p == .notInstalled) }
            switch oneClick ? nil : p {
            case .notSignedIn?, .signInExpired?:
                cliChip.command = Self.loginCommand
                cliChip.isHidden = false
                openTerminal.isHidden = false
                cliHint.stringValue = "Run this in Terminal and sign in with your Claude account. Navi will notice as soon as you have. "
                    + "To stop it signing out, set up Navi's own sign-in in Navi's Settings."
            case .notInstalled?:
                cliChip.command = Self.installCommand
                cliChip.isHidden = false
                installGuide.isHidden = false
                openTerminal.isHidden = false   // the command above runs there
                locate.isHidden = false
                cliHint.stringValue = "Or use an API key below."
            case .unresponsive?:
                tryAgain.isHidden = false
                locate.isHidden = false
                openTerminal.isHidden = false
                // The usual cause: a Claude Code from before the commands Navi asks it.
                cliHint.stringValue = "If it's an older Claude Code, update it: run claude update in Terminal, then Try again."
            default:
                break
            }
        }
        // A failure seen on a real ask outranks the last probe.
        if cliReady, let p = c.problem(for: .cli) {
            (cliText, cliIcon) = (p.sentence, .needsYou)
            if p == .signInExpired {
                if showTerminal {
                    cliChip.command = Self.loginCommand
                    cliChip.isHidden = false
                    openTerminal.isHidden = false
                } else {
                    offerConnect(install: false)
                }
            }
        }
        if cliReady, chosen != .cli, c.problem(for: .cli) == nil { cliText += " Not in use." }
        cliRow.set(detail: cliText, icon: cliIcon, chosen: chosen == .cli, canUse: cliReady)
        cliStep.isHidden = cliChip.isHidden && tryAgain.isHidden && connect.isHidden

        // API key.
        var keyText: String, keyIcon: Icon
        var keyReady = false, fromEnvironment = false
        switch c.apiKey {
        case .none:
            (keyText, keyIcon) = ("Pay as you go with a key from your Claude Console account.", .none)
        case .checking:
            (keyText, keyIcon) = ("Checking the key with Anthropic…", .checking)
        case .ready(let masked, let env):
            keyReady = true
            fromEnvironment = env
            keyText = env ? "Using \(masked) from your environment (ANTHROPIC_API_KEY)."
                          : "Key \(masked) works · saved in your Keychain."
            keyIcon = .ready
        case .problem(let p, let masked):
            (keyText, keyIcon) = ("Saved key \(masked): " + p.sentence, .problem)
        }
        if let p = c.problem(for: .api), keyReady {
            (keyText, keyIcon) = (p.sentence, .problem)
        }
        if keyReady, chosen != .api, c.problem(for: .api) == nil { keyText += " Not in use." }
        keyRow.set(detail: keyText, icon: keyIcon, chosen: chosen == .api, canUse: keyReady)
        // The field shows only when it's wanted: asked for, or the key is the
        // chosen connection and doesn't work yet. Otherwise one quiet button.
        let entering = editingKey || checking || (chosen == .api && !keyReady)
        keyStep.isHidden = !entering
        keySaved.isHidden = entering
        addKey.isHidden = keyReady && !fromEnvironment
        replaceKey.isHidden = !keyReady || fromEnvironment
        removeKey.isHidden = !keyReady || fromEnvironment
        keyError.isHidden = keyError.stringValue.isEmpty
        checkKey.isEnabled = !checking
        keyField.isEnabled = !checking

        if wasHidden != (cliStep.isHidden, keyStep.isHidden, keySaved.isHidden, keyError.isHidden) { onResize?() }
    }

    /// The one button, its words while it works, and Terminal one link away.
    private func offerConnect(install: Bool) {
        connect.isHidden = false
        switch connecting {
        case .installing?: connect.title = "Installing…"
        case .signingIn?: connect.title = "Waiting for your browser…"
        case nil: connect.title = connectProblem != nil ? "Try again" : install ? "Connect Claude" : "Sign in"
        }
        connect.isEnabled = connecting == nil
        terminalWay.isHidden = connecting != nil
        cliHint.stringValue = connectProblem ?? {
            switch connecting {
            case .installing?: return "Downloading Claude Code from claude.ai and setting it up. This takes about a minute."
            case .signingIn?: return "Sign in with your Claude account in the browser, then come back here."
            case nil: return install
                ? "Installs Claude Code from claude.ai, then your browser opens so you can sign in. Needs a Claude plan (Pro or above). Or use an API key below."
                : "Your browser opens so you can sign in with your Claude plan. Navi's sign-in lasts about a year."
            }
        }()
    }

    // MARK: Actions

    @objc private func connectClaude() {
        connectProblem = nil
        ConnectClaude.run(stage: { [weak self] s in
            self?.connecting = s
            self?.update()
            self?.onResize?()
        }, done: { [weak self] problem in
            guard let self else { return }
            self.connecting = nil
            self.connectProblem = problem
            if problem == nil, !Settings.shared.backendChosen || Settings.shared.backend != .cli { self.onChoose?(.cli) }
            self.update()
            self.onResize?()
        })
    }

    @objc private func useTerminal() {
        showTerminal = true
        update()
        onResize?()
    }

    @objc private func choose(_ sender: NSButton) {
        let b: Backend = sender.tag == 1 ? .api : .cli
        onChoose?(b)
        update()
    }

    @objc private func saveKey() {
        let key = keyField.value
        guard !checking, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        checking = true
        keyError.stringValue = ""
        update()
        Task { @MainActor in
            let problem = await Connection.shared.saveKey(key)
            checking = false
            if let problem {
                keyError.stringValue = problem.sentence
            } else {
                keyField.value = ""
                editingKey = false
                // A first working key while Claude Code isn't ready: use it.
                if Connection.shared.problem(for: .cli) != nil || !Settings.shared.backendChosen {
                    onChoose?(.api)
                }
            }
            update()
            onResize?()
        }
    }

    @objc private func showKeyEntry() {
        editingKey = true
        update()
        window?.makeFirstResponder(keyField.field)
    }

    @objc private func removeSavedKey() {
        MainActor.assumeIsolated { Connection.shared.removeKey() }
        editingKey = false
        update()
    }

    @objc private func openTerminalApp() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    @objc private func openInstallGuide() {
        NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/setup")!)
    }

    @objc private func locateClaude() {
        let panel = NSOpenPanel()
        panel.message = "Choose the claude program (often in ~/.local/bin)."
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let path = panel.url?.path else { return }
            Settings.shared.claudePath = path
            self?.recheck()
        }
    }

    @objc private func recheck() {
        MainActor.assumeIsolated { Connection.shared.refresh() }
    }

    // MARK: Pieces

    enum Icon {
        case ready, needsYou, problem, checking, none
        var image: NSImage? {
            switch self {
            case .ready: return NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Connected")
            case .needsYou: return NSImage(systemSymbolName: "circle", accessibilityDescription: "Needs you")
            case .problem: return NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Problem")
            case .checking: return NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Checking")
            case .none: return nil
            }
        }
        var tint: NSColor {
            switch self {
            case .ready: return ConnectionSection.green
            case .problem: return ConnectionSection.amber
            case .needsYou, .checking, .none: return Look.faintText
            }
        }
    }

    /// One connection, laid out like a permission row: a radio where the
    /// permission's symbol goes, name and status, the status icon, then "Use".
    private final class Row: NSStackView {
        let radio = NSButton()
        let use = InkButton("Use", target: nil, action: nil)
        private let text = NSTextField(wrappingLabelWithString: "")
        private let status = NSImageView()
        private let name: String

        init(name: String, backend: Backend) {
            self.name = name
            super.init(frame: .zero)
            orientation = .horizontal
            alignment = .centerY
            spacing = 14
            radio.isBordered = false
            radio.imagePosition = .imageOnly
            radio.tag = backend == .api ? 1 : 0
            radio.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            radio.widthAnchor.constraint(equalToConstant: 24).isActive = true
            use.tag = radio.tag
            text.preferredMaxLayoutWidth = ConnectionSection.textWidth - 10
            text.widthAnchor.constraint(equalToConstant: ConnectionSection.textWidth).isActive = true
            status.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            status.widthAnchor.constraint(equalToConstant: 20).isActive = true
            use.widthAnchor.constraint(equalToConstant: 64).isActive = true
            [radio, text, status, use].forEach { addArrangedSubview($0) }
        }

        required init?(coder: NSCoder) { fatalError() }

        func set(detail: String, icon: Icon, chosen: Bool, canUse: Bool) {
            let attr = NSMutableAttributedString(string: name, attributes: [.font: Look.ui(13, .medium), .foregroundColor: Look.warmWhite])
            attr.append(NSAttributedString(string: "\n" + detail, attributes: [.font: Look.ui(12), .foregroundColor: Look.softText]))
            text.attributedStringValue = attr
            status.image = icon.image
            status.contentTintColor = icon.tint
            radio.image = NSImage(systemSymbolName: chosen ? "largecircle.fill.circle" : "circle",
                                  accessibilityDescription: chosen ? "In use" : "Use \(name)")
            radio.contentTintColor = chosen ? OverlayView.ink : Look.faintText
            radio.isEnabled = !chosen
            radio.toolTip = chosen ? "In use" : "Use \(name)"
            // Switching is one click on a ready row; an unready row can still
            // be chosen with its radio, so its next step shows as the problem.
            use.isHidden = chosen || !canUse
            alphaValue = chosen ? 1 : 0.75
        }
    }

    /// A shell command in mono on a slightly lighter ink, with a copy button.
    private final class CommandChip: NSView {
        private let label = NSTextField(labelWithString: "")
        private let copy = NSButton()
        var command = "" { didSet { label.stringValue = command } }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            layer?.cornerRadius = 8
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1
            layer?.borderColor = Look.Pane.hairline.cgColor
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = Look.warmWhite
            label.isSelectable = true
            copy.isBordered = false
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            copy.contentTintColor = Look.softText
            copy.target = self
            copy.action = #selector(copyCommand)
            copy.toolTip = "Copy"
            let row = NSStackView(views: [label, copy])
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                heightAnchor.constraint(equalToConstant: 30),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func copyCommand() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copy.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
            copy.contentTintColor = ConnectionSection.green
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
                self?.copy.contentTintColor = Look.softText
            }
        }
    }

    /// A secure field on ink with a reveal eye. A pasted key is checked at once.
    private final class KeyField: NSView, NSTextFieldDelegate {
        let field = NSSecureTextField()
        private let plain = NSTextField()
        private let eye = NSButton()
        var onSubmit: (() -> Void)?
        var onPaste: (() -> Void)?
        private var lastLength = 0

        var value: String {
            get { (plain.isHidden ? field : plain).stringValue }
            set { field.stringValue = newValue; plain.stringValue = newValue; lastLength = newValue.count }
        }

        var isEnabled = true { didSet { field.isEnabled = isEnabled; plain.isEnabled = isEnabled } }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            layer?.cornerRadius = 8
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1
            layer?.borderColor = Look.Pane.hairline.cgColor
            for f in [field, plain] as [NSTextField] {
                f.isBordered = false
                f.drawsBackground = false
                f.focusRingType = .none
                f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                f.textColor = Look.warmWhite
                f.placeholderAttributedString = NSAttributedString(string: "sk-ant-…", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Look.faintText])
                f.delegate = self
                f.target = self
                f.action = #selector(submit)
                f.cell?.isScrollable = true
                f.cell?.usesSingleLineMode = true
            }
            plain.isHidden = true
            eye.isBordered = false
            eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show key")
            eye.contentTintColor = Look.softText
            eye.target = self
            eye.action = #selector(toggleReveal)
            let row = NSStackView(views: [field, plain, eye])
            row.spacing = 6
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                heightAnchor.constraint(equalToConstant: 30), widthAnchor.constraint(equalToConstant: 300),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func submit() { onSubmit?() }

        @objc private func toggleReveal() {
            let showing = plain.isHidden
            let v = value
            plain.isHidden = !showing
            field.isHidden = showing
            value = v
            eye.image = NSImage(systemSymbolName: showing ? "eye.slash" : "eye", accessibilityDescription: showing ? "Hide key" : "Show key")
        }

        func controlTextDidChange(_ obj: Notification) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let jumped = v.count - lastLength > 20
            lastLength = v.count
            if jumped, v.hasPrefix("sk-ant-") { onPaste?() }
        }
    }

    private static func label(_ s: String, size: CGFloat, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = Look.ui(size)
        l.textColor = color
        return l
    }

    static func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: Look.ui(11, .semibold), .foregroundColor: Look.faintText, .kern: 1.2])
        return l
    }
}
