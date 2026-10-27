import AppKit
import NaviCore

/// Said on screen when Navi's shortcut can't be registered (another app owns the
/// key): one line in the caption's style, under the menu bar, with the way to
/// choose another. It goes once the shortcut registers.
final class ShortcutNotice: NSPanel {
    private static var shown: ShortcutNotice?
    private let words = NSTextField(wrappingLabelWithString: "")
    private static let width: CGFloat = 320

    /// Says so for the shortcut the user has, when its registration fails; hides when it works.
    static func watch() {
        Hotkey.onRegistered = { combo, ok in
            let s = Settings.shared
            guard combo.keyCode == s.hotkeyCode, combo.modifiers == s.hotkeyMods else { return }
            DispatchQueue.main.async { ok ? hide() : show(label: s.hotkeyLabel) }
        }
    }

    static func show(label: String) {
        let n = shown ?? ShortcutNotice()
        shown = n
        n.words.attributedStringValue = SetupGuide.sentence(("Another app already uses ", label, ", so it can't reach me."))
        n.fit()
        if let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            n.setFrameOrigin(NSPoint(x: v.maxX - n.frame.width - 20, y: v.maxY - n.frame.height - 20))
        }
        n.orderFrontRegardless()
        trace("Shortcut \(label) is taken: said so on screen.")
    }

    static func hide() {
        shown?.orderOut(nil)
        shown = nil
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        build()
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let owl = OwlView(pixel: 1.4)
        let kicker = NSTextField(labelWithAttributedString: NSAttributedString(string: "SHORTCUT", attributes: [
            .font: Look.ui(10.5, .semibold), .foregroundColor: Look.faintText, .kern: 1.3]))
        let head = NSStackView(views: [owl, kicker])
        head.spacing = 8
        head.alignment = .centerY
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(9, after: head)

        words.preferredMaxLayoutWidth = Self.width - 32
        words.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        stack.addArrangedSubview(words)
        stack.setCustomSpacing(14, after: words)

        let later = InkButton("Not now", target: self, action: #selector(laterPressed))
        let change = InkButton("Change shortcut", role: .primary, target: self, action: #selector(changePressed))
        let footer = NSStackView(views: [NSView(), later, change])
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        stack.addArrangedSubview(footer)

        let (outer, content) = Glass.make(size: NSSize(width: Self.width, height: 120), radius: 18)
        content.layer?.backgroundColor = Look.Pane.fill.withAlphaComponent(0.985).cgColor
        stack.frame = content.bounds
        stack.autoresizingMask = [.width, .height]
        content.addSubview(stack)
        contentView = outer
    }

    private func fit() {
        guard let stack = contentView?.subviews.first?.subviews.first else { return }
        stack.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: Self.width, height: stack.fittingSize.height))
    }

    @objc private func laterPressed() { Self.hide() }

    @objc private func changePressed() {
        Self.hide()
        (NSApp.delegate as? AppController)?.recordShortcut()
    }
}
