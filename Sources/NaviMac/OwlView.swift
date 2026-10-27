import AppKit

extension Owl {
    /// The owl's palette as Mac colours (from owl.json, via `Owl.colours`).
    static let palette: [Character: NSColor] = colours.mapValues(Look.colour)
}

/// Draws the owl. `compact` shows just the owl (no room for sparks), for small
/// places; `tucked` puts it in the back seat: its head only, dimmed, beside
/// text rather than leading it.
final class OwlView: NSView {
    /// Points per sprite pixel.
    var pixel: CGFloat { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    let compact: Bool
    /// Back seat: head only, dimmed (there's something to read).
    var tucked = false {
        didSet {
            guard tucked != oldValue else { return }
            NSAnimationContext.runAnimationGroup { c in
                c.duration = Look.Motion.quick
                animator().alphaValue = tucked ? 0.55 : 1
            }
            needsDisplay = true
        }
    }
    /// A fixed mood instead of the shared one (the gallery, previews).
    var fixed: Owl.Mood?
    private var timer: Timer?

    init(pixel: CGFloat, compact: Bool = false) {
        self.pixel = pixel
        self.compact = compact
        super.init(frame: .zero)
        wantsLayer = true
        setFrameSize(intrinsicContentSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        compact ? NSSize(width: 12 * pixel, height: 11 * pixel)
            : NSSize(width: CGFloat(Owl.canvas.w) * pixel, height: CGFloat(Owl.canvas.h) * pixel)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        // Twenty frames a second: pixel motion holds still between steps, but pops stay crisp.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirty: NSRect) {
        let owl = Owl.shared
        let mood = fixed ?? owl.mood
        let t = Date().timeIntervalSince(fixed == nil ? owl.animationStart : owl.clock)
        let f = Owl.frame(mood, at: t, still: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let ox = compact ? 0 : Owl.origin.x, oy = compact ? 0 : Owl.origin.y
        let rows = tucked ? 5 : f.grid.count
        for (y, row) in f.grid.prefix(rows).enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                Owl.palette[ch]?.setFill()
                NSRect(x: CGFloat(x + ox + f.dx) * pixel, y: CGFloat(y + oy + (tucked ? 0 : f.dy)) * pixel, width: pixel, height: pixel).fill()
            }
        }
        guard !compact, !tucked else { return }
        for e in f.extras where e.y >= 0 && e.x >= 0 && e.x < Owl.canvas.w {
            Owl.palette[e.c]?.setFill()
            NSRect(x: CGFloat(e.x + f.dx) * pixel, y: CGFloat(e.y + f.dy) * pixel, width: pixel, height: pixel).fill()
        }
    }

    /// The menu bar's owl: a template silhouette (body solid, face and eyes cut out),
    /// so it takes the menu bar's own colour like any system icon.
    static func menuBarImage(pixel: CGFloat = 1.5) -> NSImage {
        let rows = Owl.body
        let img = NSImage(size: NSSize(width: 12 * pixel, height: 11 * pixel), flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where "BbYkw".contains(ch) {
                    NSRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Navi"
        return img
    }
}
