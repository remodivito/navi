import AppKit

/// What Navi is still talking about, as a small pill under the menu bar (or
/// notch). It's the one sign that a question will carry on from the last: while
/// it's there, follow-ups continue; × or "new question" starts fresh. Quick
/// answers never get one, and it fades when the follow-up window closes.
final class TopicPill {
    var onClear: (() -> Void)?
    /// A click on the name: ask a follow-up.
    var onOpen: (() -> Void)?
    var isShown: Bool { panel.isVisible && !fadingOut }
    /// A fade-out under way; `show()` during it brings the pill back instead of losing it.
    private var fadingOut = false
    private var hideGen = 0

    private let panel: NSPanel
    private let name = NSButton()
    private let close = NSButton()
    private let owl = OwlView(pixel: 1.5, compact: true)

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
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
        Look.Pane.style(root.layer!, radius: 14)
        owl.frame = NSRect(x: 9, y: 6, width: 18, height: 16.5)
        root.addSubview(owl)
        for b in [name, close] {
            b.isBordered = false
            b.target = self
            root.addSubview(b)
        }
        name.action = #selector(open)
        close.action = #selector(clear)
        close.toolTip = "Start fresh"
        close.attributedTitle = NSAttributedString(string: "×", attributes: [
            .font: Look.ui(14, .medium), .foregroundColor: Look.warmWhite.withAlphaComponent(0.5)])
    }

    @objc private func open() { onOpen?() }
    @objc private func clear() { onClear?() }

    func show(_ text: String, on screen: NSScreen) {
        name.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Look.ui(12.5, .medium), .foregroundColor: Look.warmWhite.withAlphaComponent(0.82)])
        let tw = min(280, ceil(name.attributedTitle.size().width) + 4)
        let w = 32 + tw + 8 + 22, h: CGFloat = 28
        name.frame = NSRect(x: 32, y: 4, width: tw, height: 20)
        close.frame = NSRect(x: w - 28, y: 4, width: 20, height: 20)
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) - 8
        panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: top - h, width: w, height: h), display: true)
        panel.sharingType = Settings.shared.showInRecordings ? .readOnly : .none
        hideGen += 1   // a fade-out still finishing mustn't order it out now
        guard !panel.isVisible || fadingOut else { return }
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

    func hide() {
        guard panel.isVisible, !fadingOut else { return }
        fadingOut = true
        hideGen += 1
        let gen = hideGen
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Look.Motion.base
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGen == gen else { return }
            self.fadingOut = false
            self.panel.orderOut(nil)
        })
    }
}
