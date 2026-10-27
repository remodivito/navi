import AppKit
import ScreenCaptureKit
import AVFoundation
import Speech

/// First-run setup: how Navi connects to Claude (`ConnectionSection`), then
/// one row per permission with its live status and a button that asks for it
/// and opens the right pane of System Settings, then a line on how to try it. Reopened from the menu ("Setup and permissions…").
final class OnboardingWindow: NSWindow {
    struct Permission {
        let name: String
        let why: String
        let granted: () -> Bool
        let ask: () -> Void
        let pane: String
    }

    static let permissions: [Permission] = [
        Permission(name: "Screen Recording", why: "to see your screen when you ask",
                   granted: { CGPreflightScreenCaptureAccess() },
                   ask: {
                       // Only from a click while Navi is in front: asked from the background,
                       // macOS refuses silently ("does not allow prompting") and lists nothing.
                       trace("Asking macOS for Screen Recording.")
                       _ = CGRequestScreenCaptureAccess()
                       // Asking ScreenCaptureKit too makes sure macOS lists Navi in the pane,
                       // ready to switch on (the older call alone sometimes doesn't).
                       Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
                   },
                   pane: "Privacy_ScreenCapture"),
        Permission(name: "Microphone", why: "to hear you while you hold the shortcut",
                   granted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
                   ask: { AVCaptureDevice.requestAccess(for: .audio) { _ in } },
                   pane: "Privacy_Microphone"),
        Permission(name: "Speech Recognition", why: "to turn what you say into text, on your Mac",
                   granted: { SFSpeechRecognizer.authorizationStatus() == .authorized },
                   ask: {
                       if Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil {
                           SFSpeechRecognizer.requestAuthorization { _ in }
                       }
                   },
                   pane: "Privacy_SpeechRecognition"),
        Permission(name: "Accessibility", why: "to watch for clicks in lessons, read app context and type for you",
                   granted: { AX.trusted },
                   ask: { AX.requestTrust() },
                   pane: "Privacy_Accessibility"),
    ]

    private var statusIcons: [NSImageView] = []
    private var buttons: [NSButton] = []
    private var timer: Timer?
    private var relaunchButton = NSButton()
    private var ticks = 0
    let connection = ConnectionSection()
    var onDone: (() -> Void)?

    /// One symbol per permission, shown beside its name.
    private static let symbols = ["rectangle.dashed.badge.record", "mic", "waveform", "accessibility", "globe"]

    init(hotkeyLabel: String) {
        let size = NSSize(width: 560, height: 700)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Set up Navi"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating
        Look.inkWindow(self)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 52, left: 44, bottom: 36, right: 44)

        let spark = NSImageView(image: NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) ?? NSImage())
        spark.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        spark.contentTintColor = OverlayView.ink
        stack.addArrangedSubview(spark)
        stack.setCustomSpacing(14, after: spark)

        let heading = NSTextField(labelWithString: "Set up Navi")
        heading.font = Look.ui(24, .semibold)
        heading.textColor = Look.warmWhite
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(8, after: heading)
        let sub = NSTextField(wrappingLabelWithString: "Navi needs a way to reach Claude, and a few permissions to see your screen and hear you. Each Allow button asks macOS and opens the right page in System Settings.")
        sub.font = Look.ui(13)
        sub.textColor = Look.softText
        sub.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(30, after: sub)

        stack.addArrangedSubview(connection)
        stack.setCustomSpacing(30, after: connection)
        connection.onResize = { [weak self] in self?.fit() }
        stack.addArrangedSubview(ConnectionSection.sectionLabel("PERMISSIONS"))
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)

        for (i, p) in Self.permissions.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 14
            let symbol = NSImageView(image: NSImage(systemSymbolName: Self.symbols[i], accessibilityDescription: nil) ?? NSImage())
            symbol.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            symbol.contentTintColor = Look.softText
            symbol.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let text = NSTextField(wrappingLabelWithString: "")
            let attr = NSMutableAttributedString(string: p.name, attributes: [.font: Look.ui(13, .medium), .foregroundColor: Look.warmWhite])
            attr.append(NSAttributedString(string: "\n" + p.why.prefix(1).uppercased() + p.why.dropFirst(),
                                           attributes: [.font: Look.ui(12), .foregroundColor: Look.softText]))
            text.attributedStringValue = attr
            text.preferredMaxLayoutWidth = 300
            text.widthAnchor.constraint(equalToConstant: 310).isActive = true
            let status = NSImageView()
            status.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            status.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let button = InkButton("Allow", target: self, action: #selector(allow(_:)))
            button.tag = i
            button.widthAnchor.constraint(equalToConstant: 64).isActive = true
            [symbol, text, status, button].forEach { row.addArrangedSubview($0) }
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(20, after: row)
            statusIcons.append(status)
            buttons.append(button)
        }

        let tryIt = NSTextField(wrappingLabelWithString: "Then tap \(hotkeyLabel) and ask \u{201C}where\u{2019}s the Apple menu?\u{201D} Press Esc to stop anything.")
        tryIt.font = Look.ui(12)
        tryIt.textColor = Look.softText
        tryIt.preferredMaxLayoutWidth = 460
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(tryIt)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)

        let done = InkButton("Done", role: .primary, target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        relaunchButton = InkButton("Quit and Reopen", target: self, action: #selector(relaunch))
        relaunchButton.toolTip = "macOS applies some permissions, such as Screen Recording, only after Navi reopens."
        let note = NSTextField(labelWithString: "Some permissions apply only after reopening.")
        note.font = Look.ui(11)
        note.textColor = Look.faintText
        let footer = NSStackView(views: [note, NSView(), relaunchButton, done])
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: 472).isActive = true
        stack.addArrangedSubview(footer)

        contentView = stack
        setContentSize(size)
        Look.addSheen(to: stack)
        fit()
        center()
        refresh()
    }

    /// Grows or shrinks the window to its content, keeping the top edge still,
    /// as the connection's next steps come and go.
    private func fit() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let h = max(520, content.fittingSize.height + 24)   // + room above the footer
        var f = frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 560, height: h)))
        f.origin = NSPoint(x: frame.minX, y: frame.maxY - f.height)
        setFrame(f, display: true, animate: isVisible)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        Connection.shared.refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    static var allGranted: Bool { permissions.allSatisfy { $0.granted() } }

    private func refresh() {
        // While Claude Code needs the user (signing in in Terminal, say),
        // look again every couple of seconds so the row turns green by itself.
        ticks += 1
        if ticks % 2 == 0, case .problem = Connection.shared.claudeCode { Connection.shared.refresh() }
        for (i, p) in Self.permissions.enumerated() {
            let ok = p.granted()
            statusIcons[i].image = NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "circle", accessibilityDescription: ok ? "Granted" : "Not granted")
            statusIcons[i].contentTintColor = ok ? NSColor(calibratedRed: 60 / 255, green: 200 / 255, blue: 168 / 255, alpha: 1) : Look.faintText   // step green
            buttons[i].isHidden = ok
            if ok, p.pane == "Privacy_ScreenCapture" { DragTile.hide() }
        }
    }

    @objc private func allow(_ sender: NSButton) {
        let p = Self.permissions[sender.tag]
        p.ask()
        if let url = URL(string: p.pane.hasPrefix("x-apple") ? p.pane : "x-apple.systempreferences:com.apple.preference.security?\(p.pane)") {
            NSWorkspace.shared.open(url)
        }
        // Screen Recording: macOS doesn't list Navi by itself, so hand over a tile to drop in.
        if p.pane == "Privacy_ScreenCapture" { DragTile.show() }
    }

    /// Starts a fresh copy a moment after this one quits, so permissions
    /// granted meanwhile take effect.
    @objc private func relaunch() {
        // Reopens only once this process has gone (a fixed sleep raced a slow quit).
        Relocation.relaunch(Bundle.main.bundleURL)
    }

    @objc private func finish() {
        timer?.invalidate()
        orderOut(nil)
        onDone?()
    }

    override func close() {
        timer?.invalidate()
        super.close()
    }
}
