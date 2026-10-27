import AppKit

/// The app's floating surfaces share one material: Navi's own ink pane (no
/// system glass), so they look the same on every platform. Returns the view to
/// put in the window and the view to put things in.
enum Glass {
    static func make(size: NSSize, radius: CGFloat) -> (outer: NSView, content: NSView) {
        let outer = NSView(frame: NSRect(origin: .zero, size: size))
        outer.wantsLayer = true
        outer.appearance = NSAppearance(named: .darkAqua)   // controls and system colours read on dark
        let content = NSView(frame: outer.bounds)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        let sheen = Look.Pane.style(content.layer!, radius: radius)
        sheen.frame = CGRect(x: 0, y: size.height - Look.Pane.sheenDepth, width: size.width, height: Look.Pane.sheenDepth)
        outer.addSubview(content)
        return (outer, content)
    }

    /// The one button style on a pane: tinted with Navi's ink when it's the action.
    static func style(_ b: NSButton) {
        b.bezelStyle = .rounded
    }
}

/// Borderless panels refuse key status by default; these need typing.
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// A capsule of glass floating above everything.
    func styleAsHUD(size: NSSize) -> NSView {
        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let (outer, content) = Glass.make(size: size, radius: size.height / 2)
        contentView = outer
        return content
    }
}

/// The type-a-question box. Opens the moment the hotkey (or Fn) is tapped and
/// takes the keys straight away. Navi's light sits at the start of the line,
/// and the topic in hand, if any, at the end, with × to start fresh.
final class PromptPanel: KeyablePanel, NSTextFieldDelegate, NSWindowDelegate {
    let field = NSTextField()
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// × on the topic chip: forget the topic and start fresh.
    var onClearTopic: (() -> Void)?
    /// The Mark button: draw on the screen to show what you mean.
    var onMark: (() -> Void)?
    /// The paperclip: choose files for this conversation.
    var onAttach: (() -> Void)?
    /// Files dropped on the bar, for this conversation.
    var onDropFiles: (([URL]) -> Void)?
    private let clip = NSButton()
    /// Over the bar while files are dragged across it: says what dropping does.
    private let dropHint = NSView()
    /// How many marks are waiting to go with the question.
    private(set) var markCount = 0
    private let markButton = NSButton()

    private static let size = NSSize(width: 640, height: 60)
    /// Navi's face at the start of the line.
    private let owl = OwlView(pixel: 2)
    private let chip = NSButton()
    private let hint = NSTextField(labelWithString: "↩")
    private var content: NSView!

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Stays up when they switch apps to look something up (decision 11): AppKit hiding it
        // behind the controller's back left Esc grabbed and a lesson's typing flag stuck.
        hidesOnDeactivate = false
        let (outer, inner) = Glass.make(size: Self.size, radius: 20)
        contentView = outer
        content = inner

        owl.frame = NSRect(x: 12, y: (Self.size.height - 30) / 2, width: 32, height: 30)
        inner.addSubview(owl)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Look.ui(18)
        field.textColor = Look.warmWhite
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        chip.isBordered = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 13
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        chip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        chip.target = self
        chip.action = #selector(clearTopic)
        chip.toolTip = "What this conversation is about, and its files. × starts a new conversation."

        hint.font = Look.ui(13, .medium)
        hint.textColor = Look.warmWhite.withAlphaComponent(0.3)
        hint.alignment = .right
        markButton.isBordered = false
        markButton.wantsLayer = true
        markButton.layer?.cornerRadius = 13
        markButton.image = NSImage(systemSymbolName: "scribble", accessibilityDescription: "Mark something on screen")
        markButton.contentTintColor = Look.warmWhite.withAlphaComponent(0.6)
        markButton.imagePosition = .imageLeading
        markButton.imageHugsTitle = true   // the squiggle sits beside its word, the pair centred
        markButton.target = self
        markButton.action = #selector(mark)
        markButton.toolTip = "Circle, underline or point at something on screen (double-tap right ⌥)"
        clip.isBordered = false
        clip.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Add files to this conversation")
        clip.contentTintColor = Look.warmWhite.withAlphaComponent(0.6)
        clip.target = self
        clip.action = #selector(attach)
        clip.toolTip = "Add files to this conversation: lecture slides, a practical, notes, a folder. You can also drop them here."
        [field, chip, hint, markButton, clip].forEach { inner.addSubview($0) }
        dropHint.wantsLayer = true
        dropHint.layer?.cornerRadius = 16
        // Lamp amber, as the caption's kicker: it's Navi saying what will happen.
        let amber = NSColor(calibratedRed: 1, green: 0.84, blue: 0.59, alpha: 1)
        dropHint.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.985).cgColor
        dropHint.layer?.borderWidth = 1.5
        dropHint.layer?.borderColor = amber.withAlphaComponent(0.75).cgColor
        let dropLabel = NSTextField(labelWithString: "Drop to add to this conversation")
        dropLabel.font = Look.ui(16, .medium)
        dropLabel.textColor = amber
        dropLabel.alignment = .center
        dropLabel.frame = NSRect(x: 0, y: (Self.size.height - 8 - 22) / 2, width: Self.size.width - 8, height: 22)
        dropHint.frame = NSRect(x: 4, y: 4, width: Self.size.width - 8, height: Self.size.height - 8)
        dropHint.addSubview(dropLabel)
        dropHint.isHidden = true
        inner.addSubview(dropHint)
        // The window hands drags to its delegate: files dropped anywhere on the bar.
        registerForDraggedTypes([.fileURL])
        delegate = self
        setMarks([])
    }

    @objc private func attach() { onAttach?() }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        setDropHint(true)
        return .link
    }
    func draggingExited(_ sender: NSDraggingInfo?) { setDropHint(false) }
    func setDropHint(_ on: Bool) { dropHint.isHidden = !on }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHint.isHidden = true
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    /// ⌘V with files copied in Finder adds them to the conversation, rather than typing their names.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v",
           let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onDropFiles?(urls)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The conversation chip, after files were added while the bar is open.
    func showTopic(_ topic: String?) { layOut(topic: topic) }

    @objc private func mark() { onMark?() }

    /// How wide a placeholder line is in the bar's font, so a long one isn't cut off.
    private static func placeholderWidth(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: Look.ui(18)]).width)
    }

    /// Shows the marks waiting to go ("2 marks") and the placeholder for them.
    func setMarks(_ marks: [Mark]) {
        markCount = marks.count
        let title = marks.isEmpty ? " Mark" : marks.count == 1 ? " 1 \(marks[0].verb)" : " \(marks.count) marks"
        markButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Look.ui(12.5, .medium), .foregroundColor: marks.isEmpty ? Look.warmWhite.withAlphaComponent(0.6) : NSColor(calibratedRed: 0.97, green: 0.78, blue: 0.89, alpha: 1)])
        markButton.contentTintColor = marks.isEmpty ? Look.warmWhite.withAlphaComponent(0.6) : MarkMode.ink
        markButton.layer?.backgroundColor = marks.isEmpty ? NSColor.clear.cgColor : MarkMode.ink.withAlphaComponent(0.16).cgColor
        if !marks.isEmpty, field.stringValue.isEmpty {
            let room = field.frame.width - 8
            field.placeholderAttributedString = NSAttributedString(string: Greeting.pick(marked: true) { Self.placeholderWidth($0) <= room }, attributes: [
                .font: Look.ui(18), .foregroundColor: Look.warmWhite.withAlphaComponent(0.36)])
        }
        layOut(topic: chip.isHidden ? nil : currentTopic)
    }
    private var currentTopic: String?

    @objc private func clearTopic() {
        onClearTopic?()
        layOut(topic: nil)
    }

    /// `topic`: what Navi is still talking about (the pill), shown with × to drop it.
    func show(on screen: NSScreen, markedSomething: Bool, topic: String? = nil, app: String? = nil) {
        field.stringValue = ""
        owl.tucked = false
        layOut(topic: topic)
        let room = field.frame.width - 8
        let hintText = Greeting.pick(app: app, topic: topic, marked: markedSomething) { Self.placeholderWidth($0) <= room }
        field.placeholderAttributedString = NSAttributedString(string: hintText, attributes: [
            .font: Look.ui(18), .foregroundColor: Look.warmWhite.withAlphaComponent(0.36)])
        let target = NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.frame.minY + 140)
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setFrameOrigin(NSPoint(x: target.x, y: target.y - (calm ? 0 : 8)))
        alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.insertionPointColor = Look.warmWhite
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Look.Motion.quick
            c.timingFunction = Look.Motion.settle
            animator().alphaValue = 1
            animator().setFrameOrigin(target)
        }
    }

    private func layOut(topic: String?) {
        currentTopic = topic
        let w = Self.size.width, h = Self.size.height
        var right = w - 22
        hint.frame = NSRect(x: right - 20, y: (h - 18) / 2, width: 20, height: 18)
        right -= 30
        let mw = max(70, ceil(markButton.attributedTitle.size().width) + 34)
        markButton.frame = NSRect(x: right - mw, y: (h - 26) / 2, width: mw, height: 26)
        right -= mw + 6
        clip.frame = NSRect(x: right - 26, y: (h - 26) / 2, width: 26, height: 26)
        right -= 26 + 8
        if let topic {
            chip.attributedTitle = NSAttributedString(string: topic + "  ×", attributes: [
                .font: Look.ui(12.5, .medium), .foregroundColor: Look.warmWhite.withAlphaComponent(0.72)])
            let cw = min(220, ceil(chip.attributedTitle.size().width) + 24)
            chip.frame = NSRect(x: right - cw, y: (h - 26) / 2, width: cw, height: 26)
            chip.isHidden = false
            right -= cw + 12
        } else {
            chip.isHidden = true
        }
        field.frame = NSRect(x: 52, y: (h - 24) / 2, width: right - 52, height: 24)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        // The caret in Navi's warm white, not the system blue.
        (field.currentEditor() as? NSTextView)?.insertionPointColor = Look.warmWhite
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            orderOut(nil)
            // With marks waiting, an empty ↩ means "explain what I marked".
            if !text.isEmpty || markCount > 0 { onSubmit?(text) } else { onCancel?() }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            orderOut(nil)
            onCancel?()
            return true
        }
        return false
    }
}

/// "Press your new shortcut" box. Needs at least one of ⌘ ⌥ ⌃.
final class ShortcutRecorder: KeyablePanel {
    private var monitor: Any?
    var onDone: ((_ code: Int, _ mods: Int, _ label: String) -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let bg = styleAsHUD(size: frame.size)
        let label = NSTextField(labelWithString: "Press your new shortcut")
        label.font = Look.ui(15, .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 26, y: 18, width: 260, height: 20)
        let hint = NSTextField(labelWithString: "esc to cancel")
        hint.font = Look.ui(11, .medium)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        hint.frame = NSRect(x: 270, y: 20, width: 86, height: 16)
        [label, hint].forEach { bg.addSubview($0) }
    }

    func begin() {
        center()
        hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        // Clicking away cancels: left armed, the next key anywhere would become the shortcut.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in
            guard let self, self.monitor != nil else { return }
            self.finish()
            self.onCancel?()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.finish(); self.onCancel?(); return nil }   // Esc
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            // ⌃ or ⌥ (or ⌘⇧ together): a bare ⌘ shortcut would take ⌘C, ⌘V or ⌘Q from every app.
            let ok = !mods.intersection([.option, .control]).isEmpty || mods.isSuperset(of: [.command, .shift])
            guard ok else { NSSound.beep(); return nil }
            self.finish()
            self.onDone?(Int(e.keyCode), Hotkey.carbonModifiers(mods), Hotkey.label(for: e))
            return nil
        }
    }

    private var resignObserver: Any?

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        orderOut(nil)
    }
}

/// The muted-speaker notice: "Your Mac is muted" with an Unmute
/// button, near the top of the screen, gone after a few seconds. Clicking it
/// doesn't take focus from the app you're in.
final class MutedNotice: NSPanel {
    var onUnmute: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    init() {
        let size = NSSize(width: 316, height: 48)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let (outer, bg) = Glass.make(size: size, radius: size.height / 2)
        contentView = outer

        let icon = NSImageView(image: NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.frame = NSRect(x: 20, y: 14, width: 20, height: 20)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "Your Mac is muted")
        label.font = Look.ui(13, .medium)
        label.frame = NSRect(x: 46, y: 15, width: 140, height: 18)
        let unmute = NSButton(title: "Unmute", target: self, action: #selector(unmuteClicked))
        Glass.style(unmute)
        unmute.bezelColor = OverlayView.ink   // the one action here, so it's the coloured one
        unmute.controlSize = .regular
        unmute.frame = NSRect(x: 192, y: 9, width: 84, height: 30)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss") ?? NSImage(),
                             target: self, action: #selector(dismiss))
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        close.contentTintColor = .tertiaryLabelColor
        close.frame = NSRect(x: 280, y: 14, width: 20, height: 20)
        [icon, label, unmute, close].forEach { bg.addSubview($0) }
        sharingType = Settings.shared.showInRecordings ? .readOnly : .none
    }

    func show(on screen: NSScreen, for seconds: TimeInterval = 8) {
        let f = screen.visibleFrame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 10))
        orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func unmuteClicked() {
        orderOut(nil)
        onUnmute?()
    }

    @objc private func dismiss() { orderOut(nil) }
}
