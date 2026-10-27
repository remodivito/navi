import AppKit
import QuartzCore

/// The shared look: every surface draws its lines, fills,
/// depth and motion from here rather than choosing its own. The values come
/// from NaviCore's `Tokens` (Resources/Shared/design-tokens.json), so both
/// platforms share them; this turns them into AppKit and Core Animation terms.
enum Look {
    private static let t = Tokens.shared

    /// A token colour as a Mac colour.
    static func colour(_ c: Colour) -> NSColor {
        let v = c.components
        return NSColor(calibratedRed: CGFloat(v.r), green: CGFloat(v.g), blue: CGFloat(v.b), alpha: CGFloat(v.a))
    }

    /// A token curve (cubic Bézier control points) as a timing function.
    static func curve(_ p: [Double]) -> CAMediaTimingFunction {
        let c = p.count == 4 ? p.map { Float($0) } : [0.25, 0.1, 0.25, 1]   // CSS "ease" if the file is wrong
        return CAMediaTimingFunction(controlPoints: c[0], c[1], c[2], c[3])
    }

    enum Line {
        /// Traced marks: rings, arrows, lines, outlines.
        static let mark = CGFloat(t.line.mark)
        /// The pen's faint second pass, for the hand-drawn look.
        static let echo = CGFloat(t.line.echo)
        static let echoAlpha = CGFloat(t.line.echoAlpha)
        /// Fine lines: target, hover and pulse rings, highlight edges.
        static let fine = CGFloat(t.line.fine)
        /// Dashes on a click target, marching slowly; hovers are true dots.
        static let targetDash: [NSNumber] = t.line.targetDash.map { NSNumber(value: $0) }
        static let hoverDash: [NSNumber] = t.line.hoverDash.map { NSNumber(value: $0) }
        static let marchPeriod: CFTimeInterval = t.line.marchPeriod
    }

    /// A click target breathes: grows a little and back, softly glowing.
    enum Breath {
        static let scale = CGFloat(t.line.breathScale)
        static let period: CFTimeInterval = t.line.breathPeriod
        static let opacity = Float(t.line.breathOpacity)
        static let glow = CGFloat(t.line.glow)
    }

    /// The tint inside rings, targets and highlights.
    static let fillAlpha = CGFloat(t.line.fillAlpha)

    /// One lift for marks and labels: soft, slightly below.
    static func lift(_ l: CALayer) {
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = Float(t.lift.opacity)
        l.shadowRadius = CGFloat(t.lift.radius)
        l.shadowOffset = CGSize(width: 0, height: t.lift.offsetY)
    }

    enum Motion {
        /// A tap or press, a word lifting.
        static let quick: CFTimeInterval = t.motion.quick
        /// Things appearing and fading.
        static let base: CFTimeInterval = t.motion.base
        /// Colour changes, the spotlight, words cooling.
        static let gentle: CFTimeInterval = t.motion.gentle
        /// Arriving: fast out, soft landing.
        static let settle = curve(t.motion.settle)
    }

    /// Navi's interface face: Figtree (SIL Open Font License, bundled), the same
    /// on every platform. Falls back to the system font if it can't be loaded.
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        _ = fontsRegistered
        let d = NSFontDescriptor(fontAttributes: [.family: "Figtree", .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        if let f = NSFont(descriptor: d, size: size), f.familyName == "Figtree" { return f }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// Navi's own surface, the same on every platform (no system blur): a warm
    /// near-black at 95%, a hairline inside the edge, a faint sheen at the top.
    enum Pane {
        static let fill = colour(t.pane.fill)
        static let hairline = colour(t.pane.hairline)
        static let sheen = colour(t.pane.sheen)
        static let sheenDepth = CGFloat(t.pane.sheenDepth)
        static let catchRadius = CGFloat(t.pane.catchRadius)
        static let catchAlpha = CGFloat(t.pane.catchAlpha)

        /// Styles `l` as an ink pane and adds its top sheen (returned, to size with it).
        @discardableResult
        static func style(_ l: CALayer, radius: CGFloat) -> CAGradientLayer {
            l.backgroundColor = fill.cgColor
            l.cornerRadius = radius
            l.cornerCurve = .continuous
            l.masksToBounds = true
            l.borderWidth = 1
            l.borderColor = hairline.cgColor
            let g = CAGradientLayer()
            g.colors = [sheen.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
            g.startPoint = CGPoint(x: 0.5, y: 1)
            g.endPoint = CGPoint(x: 0.5, y: 0)
            l.addSublayer(g)
            return g
        }

        /// The soft shadow under a pane, drawn by a separate layer so the pane can clip.
        static func shadow(_ l: CALayer) {
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = Float(t.pane.shadow.opacity)
            l.shadowRadius = CGFloat(t.pane.shadow.radius)   // 11 ≈ blur 22
            l.shadowOffset = CGSize(width: 0, height: t.pane.shadow.offsetY)
        }
    }

    /// Text that's secondary on the pane, and quieter still.
    static let softText = colour(t.colours.softText)
    static let faintText = colour(t.colours.faintText)

    /// Gives a normal window Navi's look: the ink pane as its background (opaque,
    /// since a window has nothing behind it to show), a title bar that melts into
    /// it, dark controls, and the faint top sheen.
    static func inkWindow(_ w: NSWindow) {
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = true
        w.backgroundColor = Pane.fill.withAlphaComponent(1)
        w.isMovableByWindowBackground = true
    }

    /// The faint sheen across the top of an ink window's content view.
    static func addSheen(to view: NSView) {
        view.wantsLayer = true
        let g = CAGradientLayer()
        g.colors = [Pane.sheen.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 1)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        g.frame = CGRect(x: 0, y: view.bounds.height - 80, width: view.bounds.width, height: 80)
        g.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]
        view.layer?.addSublayer(g)
    }

    /// The pen's blue, the gesture trail and the user's own marks.
    static let ink = colour(t.colours.ink)
    static let gestureInk = colour(t.colours.gestureInk)
    static let userMark = colour(t.colours.userMark)
    static let userInk = colour(t.colours.userInk)
    static let marker = colour(t.colours.marker)

    /// The caption's sizes (design-tokens.json, caption).
    static let caption = t.caption

    /// Text on the ink pane: a warm white rather than a clinical one.
    static let warmWhite = colour(t.colours.warmWhite)   // #F5F3EE

    /// Registers the bundled fonts (Resources/Fonts) for this process, from the
    /// app bundle or, in a debug build, the source tree. Nothing is installed.
    static let fontsRegistered: Void = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
        guard let dir = [bundled, source].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return trace("Bundled fonts not found; using system fonts.")
        }
        for f in files where f.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }()
}

/// A capsule button in Navi's look: Figtree on ink. `.primary` is the one
/// action that matters (ink blue); `.quiet` is everything else.
class InkButton: NSButton {
    enum Role { case primary, quiet }
    private let role: Role

    init(_ title: String, role: Role = .quiet, target: AnyObject?, action: Selector?) {
        self.role = role
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Look.ui(13, .medium),
            .foregroundColor: role == .primary ? NSColor.white : Look.warmWhite])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = attributedTitle.size()
        return NSSize(width: ceil(s.width) + 30, height: 30)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override var isHighlighted: Bool { didSet { refresh() } }
    override var isEnabled: Bool { didSet { refresh() } }
    /// A new title keeps the button's own type (a plain one would fall back to the system font).
    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: Look.ui(13, .medium),
                .foregroundColor: role == .primary ? NSColor.white : Look.warmWhite])
            invalidateIntrinsicContentSize()
        }
    }

    /// Navi's cards float without being the active window: the first click is a press, not just a focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Hover lifts the button a little, so it's plainly clickable.
    private var hovering = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    private func refresh() {
        let base: NSColor = role == .primary ? OverlayView.ink
            : NSColor.white.withAlphaComponent(isHighlighted ? 0.26 : hovering ? 0.17 : 0.09)
        let c = role == .primary && isHighlighted ? base.blended(withFraction: 0.18, of: .black) ?? base
            : role == .primary && hovering ? base.blended(withFraction: 0.12, of: .white) ?? base : base
        layer?.backgroundColor = c.cgColor
        layer?.borderWidth = role == .quiet ? 1 : 0
        layer?.borderColor = Look.Pane.hairline.cgColor
        alphaValue = isEnabled ? 1 : 0.4
    }
}
