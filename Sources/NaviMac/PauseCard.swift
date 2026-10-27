import AppKit

/// A paused lesson, at the top of the screen: what the step was, and four
/// one-tap ways back in. It's the one part of Navi you can click, so you never
/// have to remember to say "continue". Clicking the words opens the type field.
final class PauseCard {
    typealias Choice = Shell.PauseChoice

    var onChoose: ((Choice) -> Void)?
    var onType: (() -> Void)?
    var isShown: Bool { panel.isVisible && !fadingOut }
    /// A fade-out under way; `show()` during it brings the card back instead of losing it.
    private var fadingOut = false
    private var hideGen = 0

    private let panel: NSPanel
    private let card = ClickView()
    private let kicker = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private var buttons: [InkButton] = []
    private let owl = OwlView(pixel: 1.25, compact: true)
    private static let width: CGFloat = 420

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        let root = NSView()
        root.wantsLayer = true
        panel.contentView = root
        card.wantsLayer = true
        Look.Pane.style(card.layer!, radius: 16)
        let shadow = NSView()
        shadow.wantsLayer = true
        shadow.layer?.backgroundColor = Look.Pane.fill.cgColor
        shadow.layer?.cornerRadius = 16
        Look.Pane.shadow(shadow.layer!)
        root.addSubview(shadow)
        root.addSubview(card)
        card.onClick = { [weak self] in self?.onType?() }

        kicker.font = Look.ui(10.5, .semibold)
        kicker.textColor = NSColor(calibratedRed: 0.94, green: 0.67, blue: 0.37, alpha: 0.95)
        text.font = Look.ui(13)
        text.textColor = Look.warmWhite.withAlphaComponent(0.62)
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        [kicker, text, owl].forEach { card.addSubview($0) }
        for c in Choice.allCases {
            let b = InkButton(c.title, role: .quiet, target: self, action: #selector(choose(_:)))
            b.tag = c.rawValue
            buttons.append(b)
            card.addSubview(b)
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let c = Choice(rawValue: sender.tag) else { return }
        onChoose?(c)
    }

    /// Shows the card under the menu bar (or notch) of `screen`.
    func show(kicker k: String, text t: String, on screen: NSScreen) {
        let pad: CGFloat = 16, w = Self.width
        kicker.attributedStringValue = NSAttributedString(string: k.uppercased(), attributes: [
            .font: Look.ui(10.5, .semibold), .kern: 1.1, .foregroundColor: kicker.textColor ?? .white])
        text.stringValue = t
        let textH = min(40, ceil(text.sizeThatFits(NSSize(width: w - pad * 2, height: 100)).height))
        var x = pad
        let rowH: CGFloat = 30, h = pad + 14 + 6 + textH + 12 + rowH + pad
        for b in buttons {
            let bw = b.intrinsicContentSize.width
            b.frame = NSRect(x: x, y: pad, width: bw, height: rowH)
            x += bw + 8
        }
        text.frame = NSRect(x: pad, y: pad + rowH + 12, width: w - pad * 2, height: textH)
        owl.frame = NSRect(x: pad, y: text.frame.maxY + 5, width: 15, height: 13.75)
        kicker.frame = NSRect(x: pad + 21, y: text.frame.maxY + 6, width: w - pad * 2 - 21, height: 14)
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) - 10
        panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: top - h, width: w, height: h), display: false)
        panel.contentView?.subviews.forEach { $0.frame = NSRect(x: 0, y: 0, width: w, height: h) }
        card.layer?.sublayers?.first(where: { $0 is CAGradientLayer })?.frame = CGRect(x: 0, y: h - 40, width: w, height: 40)
        panel.sharingType = Settings.shared.showInRecordings ? .readOnly : .none
        hideGen += 1   // a fade-out still finishing mustn't order it out now
        if !panel.isVisible || fadingOut {
            fadingOut = false
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { c in
                c.duration = Look.Motion.base
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard panel.isVisible, !fadingOut else { return }
        fadingOut = true
        hideGen += 1
        let gen = hideGen
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Look.Motion.quick
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGen == gen else { return }
            self.fadingOut = false
            self.panel.orderOut(nil)
        })
    }

    #if DEBUG
    /// The gallery's stand-in for a click on one of the replies.
    func testChoose(_ c: Choice) { onChoose?(c) }
    #endif
}

/// The card's background: a click on the words (not a button) opens typing.
private final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
