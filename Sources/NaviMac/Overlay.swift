import AppKit
import QuartzCore

/// Full-screen, transparent, click-through window that floats above everything,
/// including full-screen apps. Clicks fall straight through to the app below.
final class OverlayWindow: NSWindow {
    let canvas: OverlayView

    init(screen: NSScreen) {
        canvas = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = canvas
        setFrame(screen.frame, display: true)
    }
}

/// One overlay per display, rebuilt when displays change.
final class OverlayManager {
    private var windows: [CGDirectDisplayID: OverlayWindow] = [:]

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    /// Displays whose overlay went away or moved (a resolution change, a display unplugged or
    /// rearranged); marks on the others are kept as they were (decision 14).
    var onDisplaysChanged: ((Set<CGDirectDisplayID>) -> Void)?

    /// Displays changed: keep each surviving display's window and what's drawn on it (the Dock
    /// or the menu bar showing and hiding changes nothing); a new display gets a window.
    func rebuild() {
        var kept: [CGDirectDisplayID: OverlayWindow] = [:]
        var changed = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let id = Capture.displayID(screen)
            if let w = windows[id] {
                if w.frame != screen.frame {
                    w.setFrame(screen.frame, display: true)
                    w.canvas.frame = NSRect(origin: .zero, size: screen.frame.size)
                    changed.insert(id)
                }
                kept[id] = w
            } else {
                let w = OverlayWindow(screen: screen)
                w.sharingType = Settings.shared.showInRecordings ? .readOnly : .none
                kept[id] = w
            }
        }
        for (id, w) in windows where kept[id] == nil {
            w.orderOut(nil)
            changed.insert(id)
        }
        windows = kept
        if !changed.isEmpty { onDisplaysChanged?(changed) }
    }

    func view(for screen: NSScreen) -> OverlayView? {
        guard let w = windows[Capture.displayID(screen)] else { return nil }
        if !w.isVisible { w.orderFrontRegardless() }
        return w.canvas
    }

    func clearAll() { windows.values.forEach { $0.canvas.clear() } }

    var views: [OverlayView] { windows.values.map(\.canvas) }

    func applySharing() {
        windows.values.forEach { $0.sharingType = Settings.shared.showInRecordings ? .readOnly : .none }
    }

    /// AppKit global point → (view, view-local point).
    /// Everything drawn now, in global AppKit points: marks and their labels.
    func occupied() -> [NSRect] {
        windows.values.flatMap { w in w.canvas.occupied.map { $0.offsetBy(dx: w.frame.minX, dy: w.frame.minY) } }
    }

    func locate(_ p: NSPoint) -> (OverlayView, CGPoint)? {
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? Capture.screenUnderMouse()
        guard let v = view(for: screen) else { return nil }
        return (v, CGPoint(x: p.x - screen.frame.minX, y: p.y - screen.frame.minY))
    }
}

final class OverlayView: NSView {
    static let ink = Look.ink
    /// Handwriting for WRITE marks: Patrick Hand (bundled; see `Look.registerFonts`).
    static func writingFont(size: CGFloat) -> NSFont {
        _ = Look.fontsRegistered
        return NSFont(name: "PatrickHand-Regular", size: size) ?? .systemFont(ofSize: size - 2, weight: .medium)
    }

    static let gestureInk = Look.gestureInk

    /// The colour the next marks are drawn in: ink blue ("look here"), or a
    /// quantity colour bound to the thing being explained.
    var markInk = OverlayView.ink
    /// Letters in written formulas that name a coloured thing ("a" → gold).
    var letterColours: [Character: NSColor] = [:]

    /// Lines of working written so far, so the next step written in the same
    /// place transforms them rather than appearing beside them.
    private struct Written {
        var anchor: CGPoint          // where it was asked to go (view-local, top-left)
        var origin: CGPoint          // where it sits (bottom-left of the text)
        var height: CGFloat
        var text: String
        var single: CATextLayer?     // as first written (one layer, revealed by the pen)
        var tokens: [CATextLayer]    // once transformed: one layer per term
        var rect: CGRect
    }
    private var written: [Written] = []

    private var annotationLayers: [CALayer] = []
    private var stepLayers: [CALayer] = []        // armed TARGET / HOVER: kept until the step is taken
    private var highlightLayers: [CALayer] = []   // HIGHLIGHT areas: fade soon after their sentence
    private enum Group { case drawing, step, highlight }
    private var group = Group.drawing
    private var gestureLayer: CAShapeLayer?
    private var labelRects: [CGRect] = []

    /// What's drawn now, in this view's coordinates, for the caption to keep clear of.
    var occupied: [CGRect] {
        let marks = (annotationLayers + stepLayers + highlightLayers).filter { $0.opacity > 0.05 }.map { l -> CGRect in
            if let shape = l as? CAShapeLayer, let path = shape.path {
                return path.boundingBoxOfPath.offsetBy(dx: l.frame.minX, dy: l.frame.minY).insetBy(dx: -shape.lineWidth, dy: -shape.lineWidth)
            }
            return l.frame
        }
        // Full-screen layers (the lesson's dimming) aren't something to avoid.
        return labelRects + marks.filter { $0.width < bounds.width * 0.8 && $0.height < bounds.height * 0.8 }
    }
    /// How long each stroke takes to draw itself; set to the nib's tracing time
    /// so the ink appears right behind it.
    var strokeTime: CFTimeInterval = 0.5   // placed labels, so new ones don't land on them

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func clear() {
        (annotationLayers + stepLayers + highlightLayers).forEach { $0.removeFromSuperlayer() }
        annotationLayers = []
        stepLayers = []
        highlightLayers = []
        labelRects = []
        written = []
        clearGesture()
    }

    /// Fades out everything except an armed step, when the narration ends.
    func fadeDrawings() {
        fadeOut(annotationLayers + highlightLayers)
        annotationLayers = []
        highlightLayers = []
        labelRects = []
        written = []
        clearGesture()
    }

    private var motes: CAEmitterLayer?

    /// A few tiny ink motes left behind the nib while it travels; they drift
    /// down and fade, like the sparkles a fairy leaves (Navi's `SpawnSparkles`).
    func trail(at p: CGPoint, on: Bool) {
        let e = motes ?? {
            let e = CAEmitterLayer()
            e.emitterShape = .point
            e.renderMode = .unordered
            let cell = CAEmitterCell()
            cell.contents = Self.dot
            cell.birthRate = 26
            cell.lifetime = 0.9
            cell.lifetimeRange = 0.3
            cell.velocity = 6
            cell.velocityRange = 6
            cell.emissionRange = .pi * 2
            cell.yAcceleration = -14
            cell.scale = 0.22
            cell.scaleRange = 0.1
            cell.scaleSpeed = -0.15
            cell.alphaSpeed = -1.1
            cell.color = markInk.withAlphaComponent(0.8).cgColor
            e.emitterCells = [cell]
            e.birthRate = 0
            self.layer?.addSublayer(e)
            motes = e
            return e
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        e.emitterPosition = p
        e.birthRate = on ? 1 : 0
        CATransaction.commit()
    }

    private static let dot: CGImage? = {
        let size = 16
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }()

    var hasDrawings: Bool { !(annotationLayers.isEmpty && highlightLayers.isEmpty && stepLayers.isEmpty) }

    func clearSteps() {
        fadeOut(stepLayers)
        stepLayers = []
    }

    private func fadeOut(_ layers: [CALayer]) {
        guard !layers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { layers.forEach { $0.removeFromSuperlayer() } }
        for l in layers {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = l.presentation()?.opacity ?? l.opacity
            a.toValue = 0
            a.duration = Look.Motion.base
            l.opacity = 0
            l.add(a, forKey: "fadeOut")
        }
        CATransaction.commit()
    }

    // MARK: Gesture trail

    /// The pointer gesture as it's drawn: a fine glowing line whose newest part is
    /// brightest and whose older part fades back, gone a moment after the pointer stops
    /// (Claude sees the whole gesture in the screenshot either way).
    func showGesture(_ pts: [CGPoint]) {
        let layer = gestureLayer ?? {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.strokeColor = Self.gestureInk.withAlphaComponent(0.35).cgColor
            l.lineWidth = 2.5
            l.lineCap = .round
            l.lineJoin = .round
            let tail = CAShapeLayer()
            tail.fillColor = nil
            tail.strokeColor = Self.gestureInk.cgColor
            tail.lineWidth = 2.5
            tail.lineCap = .round
            tail.lineJoin = .round
            tail.shadowColor = Self.gestureInk.cgColor
            tail.shadowOpacity = 0.9
            tail.shadowRadius = 6
            tail.shadowOffset = .zero
            l.addSublayer(tail)
            self.layer?.addSublayer(l)
            gestureLayer = l
            return l
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "fadeOut")
        layer.opacity = 1
        layer.path = Sketch.path(pts)
        (layer.sublayers?.first as? CAShapeLayer)?.path = Sketch.path(Array(pts.suffix(28)))
        CATransaction.commit()
        gestureFade?.cancel()
        let fade = DispatchWorkItem { [weak self, weak layer] in
            guard let self, let layer, layer === self.gestureLayer else { return }
            self.gestureLayer = nil
            self.fadeOut([layer])
        }
        gestureFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: fade)
    }
    private var gestureFade: DispatchWorkItem?

    func clearGesture() {
        gestureLayer?.removeFromSuperlayer()
        gestureLayer = nil
    }

    // MARK: Annotations (all points are view-local, bottom-left origin)

    func drawPoint(_ p: CGPoint, label: String?, snapped: CGRect?, delay: CFTimeInterval) {
        if let snapped { addOutline(snapped, delay: delay) }
        addPulse(at: p, ringRadius: 22, delay: delay)
        if let label { addLabel(label, at: CGPoint(x: p.x + 18, y: p.y - 18), delay: delay) }
    }

    func drawTarget(_ p: CGPoint, radius: CGFloat, label: String?, snapped: CGRect?, delay: CFTimeInterval, hover: Bool = false) {
        group = .step
        defer { group = .drawing }
        // The ring hugs the control when there is one, else a circle round the point.
        let shape = snapped.map { $0.insetBy(dx: -4, dy: -4) }
            ?? CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        let corner = snapped == nil ? radius : min(10, shape.width / 2, shape.height / 2)
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: shape.size), cornerWidth: corner, cornerHeight: corner, transform: nil)
        // A faint tint inside, still while the ring breathes around it.
        let fill = CAShapeLayer()
        fill.name = Self.targetFill
        fill.frame = shape
        fill.path = path
        fill.fillColor = markInk.withAlphaComponent(Look.fillAlpha).cgColor
        add(fill)
        let ring = CAShapeLayer()
        ring.name = Self.targetRing
        ring.frame = shape
        ring.path = path
        ring.fillColor = nil
        ring.strokeColor = markInk.cgColor
        ring.lineWidth = Look.Line.fine
        ring.lineCap = .round
        if hover { ring.lineDashPattern = Look.Line.hoverDash }   // dots: rest the pointer here
        ring.shadowColor = markInk.cgColor
        ring.shadowOpacity = 0.9
        ring.shadowRadius = Look.Breath.glow
        ring.shadowOffset = .zero
        ring.opacity = Look.Breath.opacity
        add(ring)
        // It settles onto the control from a little larger, then breathes.
        for l in [fill, ring] { arrive(l, delay: delay) }
        if !Buddy.reduceMotion {
            // A control grows 8 points each side; a circle by the token's scale.
            let sx = snapped == nil ? Look.Breath.scale : min(1.6, 1 + 16 / max(1, shape.width))
            let sy = snapped == nil ? Look.Breath.scale : min(1.6, 1 + 16 / max(1, shape.height))
            breathe(ring, sx: sx, sy: sy, delay: delay + 0.35)
        }
        addLabel("\(hover ? "Hover" : "Click"): \(label ?? "here")", at: CGPoint(x: shape.maxX + 8, y: p.y - 8), delay: delay)
    }

    private static let targetFill = "targetFill", targetRing = "targetRing"

    /// Comes in from 1.2× to its place, fading up: fast out, soft landing.
    private func arrive(_ l: CALayer, delay: CFTimeInterval) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = Buddy.reduceMotion ? 1 : 1.2
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = l.opacity
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 0.35
        g.timingFunction = Look.Motion.settle
        g.beginTime = CACurrentMediaTime() + delay
        g.fillMode = .backwards
        l.add(g, forKey: "arrive")
    }

    /// Grows a little and back, dimming as it grows, for as long as it's up.
    private func breathe(_ l: CALayer, sx: CGFloat, sy: CGFloat, delay: CFTimeInterval) {
        let x = CABasicAnimation(keyPath: "transform.scale.x")
        x.fromValue = 1; x.toValue = sx
        let y = CABasicAnimation(keyPath: "transform.scale.y")
        y.fromValue = 1; y.toValue = sy
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = l.opacity; o.toValue = l.opacity * 0.4
        let g = CAAnimationGroup()
        g.animations = [x, y, o]
        g.duration = Look.Breath.period
        g.autoreverses = true
        g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        g.beginTime = CACurrentMediaTime() + delay
        l.add(g, forKey: "breathe")
    }

    /// The step was taken: the ring tightens onto the control as its tint flashes,
    /// then it's gone, all within half a second. Not removed by `clear()`, so a
    /// new turn starting at once doesn't cut it short.
    func stepTaken() {
        let layers = stepLayers
        stepLayers = []
        guard !layers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { layers.forEach { $0.removeFromSuperlayer() } }
        let calm = Buddy.reduceMotion
        for l in layers {
            let from = l.presentation()?.opacity ?? l.opacity
            l.removeAllAnimations()
            var parts: [CAAnimation] = []
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [from, from, 0]
            fade.keyTimes = [0, 0.45, 1]
            parts.append(fade)
            if !calm, l.name == Self.targetRing || l.name == Self.targetFill {
                let squeeze = CAKeyframeAnimation(keyPath: "transform.scale")
                squeeze.values = [1.04, 0.95, 1]
                squeeze.keyTimes = [0, 0.4, 1]
                parts.append(squeeze)
            }
            if let fill = l as? CAShapeLayer, fill.name == Self.targetFill {
                let flash = CAKeyframeAnimation(keyPath: "fillColor")
                flash.values = [markInk.withAlphaComponent(0.45).cgColor, markInk.withAlphaComponent(0.3).cgColor, markInk.withAlphaComponent(0).cgColor]
                flash.keyTimes = [0, 0.4, 1]
                parts.append(flash)
            }
            let g = CAAnimationGroup()
            g.animations = parts
            g.duration = calm ? 0.2 : 0.45
            g.timingFunction = Look.Motion.settle
            l.opacity = 0
            l.add(g, forKey: "taken")
        }
        CATransaction.commit()
    }

    /// "Show me": a ghost pointer presses at the start, drags along the points and lets go,
    /// three times, over a faint dotted trail. Nothing is clicked or moved: it's a picture
    /// of the motion, for drags Navi can't watch.
    func drawDemo(_ pts: [CGPoint], label: String?, delay: CFTimeInterval) {
        guard let first = pts.first, let last = pts.last else { return }
        let trail = CAShapeLayer()
        trail.path = Sketch.path(pts)
        trail.fillColor = nil
        trail.strokeColor = markInk.withAlphaComponent(0.55).cgColor
        trail.lineWidth = Look.Line.fine
        trail.lineCap = .round
        trail.lineDashPattern = Look.Line.hoverDash
        add(trail)
        animate(trail, "opacity", from: 0, to: 1, duration: Look.Motion.base, delay: delay)

        // The ghost: the arrow cursor, half see-through, with a ring that shows "held".
        let ghost = CALayer()
        let image = NSCursor.arrow.image
        ghost.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        ghost.bounds = CGRect(origin: .zero, size: image.size)
        ghost.anchorPoint = CGPoint(x: NSCursor.arrow.hotSpot.x / image.size.width, y: 1 - NSCursor.arrow.hotSpot.y / image.size.height)
        ghost.position = first
        ghost.opacity = 0
        let held = CAShapeLayer()
        held.path = CGPath(ellipseIn: CGRect(x: -11, y: -11, width: 22, height: 22), transform: nil)
        held.fillColor = markInk.withAlphaComponent(0.18).cgColor
        held.strokeColor = markInk.cgColor
        held.lineWidth = 1.5
        held.position = first
        held.opacity = 0
        add(held)
        add(ghost)

        // One pass: appear, press, drag, let go, fade (2.6 s), then a pause; three times.
        let pass: CFTimeInterval = 2.6, gap: CFTimeInterval = 0.7, times = Buddy.reduceMotion ? 1 : 3
        let route = CGMutablePath()
        route.move(to: first)
        pts.dropFirst().forEach { route.addLine(to: $0) }
        for layer in [ghost, held] as [CALayer] {
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = route
            move.calculationMode = .paced
            move.beginTime = 0.7
            move.duration = 1.2
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            move.fillMode = .both
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = layer === ghost ? [0, 0.85, 0.85, 0.85, 0] : [0, 0, 0.9, 0.9, 0]
            show.keyTimes = [0, 0.12, 0.25, 0.8, 1]
            show.duration = pass
            let g = CAAnimationGroup()
            g.animations = [move, show]
            g.duration = pass + gap
            g.repeatCount = Float(times)
            g.beginTime = CACurrentMediaTime() + delay + 0.3
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            layer.add(g, forKey: "demo")
        }
        _ = last
        if let label { addLabel(label, at: CGPoint(x: first.x + 16, y: first.y - 30), delay: delay) }
    }

    /// A formula with each standalone letter that names a coloured thing in
    /// that thing's colour (a² + b² = c² with a, b and c in their colours).
    static func bound(_ text: String, font: NSFont, base: NSColor, letters: [Character: NSColor]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: base])
        let chars = Array(text)
        var offset = 0
        for (i, ch) in chars.enumerated() {
            let len = String(ch).utf16.count
            defer { offset += len }
            guard let c = letters[Character(ch.lowercased())] else { continue }
            let before = i > 0 ? chars[i - 1] : " ", after = i + 1 < chars.count ? chars[i + 1] : " "
            guard !before.isLetter, !after.isLetter else { continue }
            out.addAttribute(.foregroundColor, value: c, range: NSRange(location: offset, length: len))
        }
        return out
    }

    /// Where written text with its top-left at `p` should go so it doesn't land
    /// on a label or earlier writing: it steps down below whatever is in the way.
    func writeSpot(_ text: String, at p: CGPoint) -> CGPoint {
        let size = NSAttributedString(string: text, attributes: [.font: Self.writingFont(size: 28)])
            .boundingRect(with: CGSize(width: 900, height: 200), options: [.usesLineFragmentOrigin]).size
        var top = p
        for _ in 0..<4 {
            let r = CGRect(x: top.x, y: top.y - ceil(size.height), width: ceil(size.width), height: ceil(size.height))
            guard let hit = labelRects.first(where: { $0.insetBy(dx: -4, dy: -4).intersects(r) }) else { break }
            top.y = hit.minY - 6
        }
        return top
    }

    /// Handwritten text with its top-left at `p` (view-local), revealed left to
    /// right as if being written.
    func drawWrite(_ text: String, at p: CGPoint, anchor: CGPoint? = nil, delay: CFTimeInterval) {
        let font = Self.writingFont(size: 28)
        let attr = Self.bound(text, font: font, base: markInk, letters: letterColours)
        let size = attr.boundingRect(with: CGSize(width: 900, height: 200), options: [.usesLineFragmentOrigin]).size
        var origin = CGPoint(x: p.x, y: p.y - ceil(size.height))
        origin.x = min(max(origin.x, 6), bounds.width - size.width - 6)
        origin.y = min(max(origin.y, 6), bounds.height - size.height - 6)
        let t = CATextLayer()
        t.string = attr
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.frame = CGRect(origin: origin, size: CGSize(width: ceil(size.width) + 2, height: ceil(size.height)))
        // A soft white halo keeps it readable on any background.
        t.shadowColor = NSColor.white.cgColor
        t.shadowOpacity = 1
        t.shadowRadius = 2.5
        t.shadowOffset = .zero
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 0.5)
        mask.frame = t.bounds
        t.mask = mask
        add(t)
        let reveal = CABasicAnimation(keyPath: "bounds.size.width")
        reveal.fromValue = 0
        reveal.toValue = t.bounds.width
        reveal.duration = strokeTime
        reveal.beginTime = CACurrentMediaTime() + delay
        reveal.fillMode = .backwards
        mask.add(reveal, forKey: "write")
        labelRects.append(t.frame)
        written.append(Written(anchor: anchor ?? p, origin: origin, height: ceil(size.height), text: text, single: t, tokens: [], rect: t.frame))
    }

    /// The written line at (or within a few points of) `anchor`, if there is one.
    func writtenRect(near anchor: CGPoint) -> CGRect? {
        written.first { hypot($0.anchor.x - anchor.x, $0.anchor.y - anchor.y) < 24 }?.rect
    }

    /// Transforms the line written at `anchor` into `text`: carried-over terms
    /// slide, changed ones crossfade in place, combining ones fold together.
    /// Returns the new line's frame, or nil if nothing is written there.
    @discardableResult
    func transformWrite(at anchor: CGPoint, to text: String) -> CGRect? {
        guard let i = written.firstIndex(where: { hypot($0.anchor.x - anchor.x, $0.anchor.y - anchor.y) < 24 }) else { return nil }
        var w = written[i]
        let font = Self.writingFont(size: 28)
        let oldTokens = Formula.tokens(w.text, font: font), newTokens = Formula.tokens(text, font: font)
        func tokenLayer(_ t: Formula.Token) -> CATextLayer {
            let l = CATextLayer()
            l.string = Self.bound(t.text, font: font, base: markInk, letters: letterColours)
            l.contentsScale = window?.backingScaleFactor ?? 2
            l.bounds = CGRect(x: 0, y: 0, width: ceil(t.width) + 2, height: w.height)
            l.anchorPoint = CGPoint(x: 0, y: 0)
            l.shadowColor = NSColor.white.cgColor
            l.shadowOpacity = 1
            l.shadowRadius = 2.5
            l.shadowOffset = .zero
            add(l)
            return l
        }
        func spot(_ t: Formula.Token) -> CGPoint { CGPoint(x: w.origin.x + t.x, y: w.origin.y) }
        // The first transform swaps the pen-written line for one layer per term, in place.
        var old = w.tokens
        if old.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            old = oldTokens.map { t in let l = tokenLayer(t); l.position = spot(t); return l }
            w.single?.removeFromSuperlayer()
            w.single = nil
            CATransaction.commit()
        }
        guard old.count == oldTokens.count else { return nil }
        let calm = Buddy.reduceMotion
        let dur = calm ? 0.15 : Formula.duration
        func slide(_ l: CALayer, from a: CGPoint, to b: CGPoint) {
            let anim = CAKeyframeAnimation(keyPath: "position")
            let path = CGMutablePath()
            path.move(to: a)
            let d = hypot(b.x - a.x, b.y - a.y)
            // Longer moves rise on a small arc, so terms pass over each other.
            path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + (d > 30 && !calm ? min(26, d * 0.3) * 2 : 0)))
            anim.path = path
            anim.duration = dur
            anim.timingFunction = Formula.smooth
            l.add(anim, forKey: "slide")
        }
        func fade(_ l: CALayer, _ values: [Float], _ times: [NSNumber], remove: Bool) {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = values
            a.keyTimes = times
            a.duration = dur
            l.add(a, forKey: "fade")
            l.opacity = values.last ?? 1
            if remove { DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.05) { l.removeFromSuperlayer() } }
        }
        var next = [CATextLayer?](repeating: nil, count: newTokens.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for step in Formula.plan(oldTokens.map(\.text), newTokens.map(\.text)) {
            switch step {
            case .move(let a, let b):
                let l = old[a], from = l.position, to = spot(newTokens[b])
                l.position = to
                slide(l, from: from, to: to)
                next[b] = l
            case .change(let a, let b):
                // Same slot, new value: the old fades out over the first 55%, the new in from 40%.
                let l = old[a], from = l.position, to = spot(newTokens[b])
                l.position = to
                slide(l, from: from, to: to)
                fade(l, [1, 0, 0], [0, 0.55, 1], remove: true)
                let n = tokenLayer(newTokens[b])
                n.position = to
                slide(n, from: from, to: to)
                fade(n, [0, 0, 1], [0, 0.4, 1], remove: false)
                next[b] = n
            case .fold(let from, let into):
                // Terms that combine gather at the centre of what they become, which grows out of them.
                let oldCentre = from.isEmpty ? nil : CGPoint(x: from.map { old[$0].position.x + old[$0].bounds.width / 2 }.reduce(0, +) / CGFloat(from.count), y: w.origin.y)
                let newCentre = into.isEmpty ? nil : CGPoint(x: into.map { spot(newTokens[$0]).x + newTokens[$0].width / 2 }.reduce(0, +) / CGFloat(into.count), y: w.origin.y)
                for a in from {
                    let l = old[a], start = l.position
                    let end = newCentre.map { CGPoint(x: $0.x - l.bounds.width / 2, y: $0.y) } ?? start
                    l.position = end
                    slide(l, from: start, to: end)
                    fade(l, [1, 0.6, 0], [0, 0.4, 0.75], remove: true)
                }
                for b in into {
                    let n = tokenLayer(newTokens[b])
                    let to = spot(newTokens[b])
                    let start = oldCentre.map { CGPoint(x: $0.x - n.bounds.width / 2, y: $0.y) } ?? to
                    n.position = to
                    slide(n, from: start, to: to)
                    fade(n, [0, 0, 1], [0, 0.35, 1], remove: false)
                    let grow = CABasicAnimation(keyPath: "transform.scale")
                    grow.fromValue = 0.6
                    grow.toValue = 1
                    grow.duration = dur
                    grow.timingFunction = Formula.smooth
                    n.add(grow, forKey: "grow")
                    next[b] = n
                }
            }
        }
        CATransaction.commit()
        let width = newTokens.last.map { $0.x + $0.width } ?? 0
        let rect = CGRect(x: w.origin.x, y: w.origin.y, width: ceil(width) + 2, height: w.height)
        labelRects.removeAll { $0 == w.rect }
        labelRects.append(rect)
        w.tokens = next.compactMap { $0 }
        w.text = text
        w.rect = rect
        written[i] = w
        return rect
    }

    /// A work area (view-local rect). A line of text gets a highlighter swept along
    /// it; anything bigger is lifted under a faint tinted glass with a softly glowing
    /// edge. Navi's light then roams inside it (`Buddy.roam`).
    func drawHighlight(_ r: CGRect, label: String?, sketchy: Bool, delay: CFTimeInterval) {
        group = .highlight
        defer { group = .drawing }
        if Tutor.highlightIsLine(r) { sweep(r, delay: delay) } else { lift(r, delay: delay) }
        if let label { addLabel(label, at: CGPoint(x: r.minX - 5, y: r.maxY + 30), delay: delay) }
    }

    /// The highlighter: a translucent band revealed left to right behind the light.
    /// Warm yellow, unless the thing highlighted has an explanation colour.
    private func sweep(_ r: CGRect, delay: CFTimeInterval) {
        let band = CALayer()
        band.frame = r.insetBy(dx: -4, dy: -2)
        band.cornerRadius = 5
        band.cornerCurve = .continuous
        band.backgroundColor = (markInk == Self.ink ? Look.marker : markInk.withAlphaComponent(0.32)).cgColor
        add(band)
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 0.5)
        mask.frame = band.bounds
        band.mask = mask
        let reveal = CABasicAnimation(keyPath: "transform.scale.x")
        reveal.fromValue = Buddy.reduceMotion ? 1 : 0.001
        reveal.toValue = 1
        reveal.duration = strokeTime
        reveal.beginTime = CACurrentMediaTime() + delay
        reveal.timingFunction = Look.Motion.settle
        reveal.fillMode = .backwards
        mask.add(reveal, forKey: "reveal")
    }

    /// Glass: a faint tint, an edge that draws itself in behind the light, and a glow
    /// that breathes slowly while it's up.
    private func lift(_ r: CGRect, delay: CFTimeInterval) {
        let e = r.insetBy(dx: -6, dy: -6)
        let corner = min(12, e.width / 2, e.height / 2)
        let fill = CAShapeLayer()
        fill.path = CGPath(roundedRect: e, cornerWidth: corner, cornerHeight: corner, transform: nil)
        fill.fillColor = markInk.withAlphaComponent(Look.fillAlpha).cgColor
        fill.opacity = 0
        add(fill)
        animate(fill, "opacity", from: 0, to: 1, duration: Look.Motion.base, delay: delay + strokeTime * 0.6)
        let edge = CAShapeLayer()
        edge.path = fill.path
        edge.fillColor = nil
        edge.strokeColor = markInk.withAlphaComponent(0.85).cgColor
        edge.lineWidth = 1.5
        edge.lineCap = .round
        edge.shadowColor = markInk.cgColor
        edge.shadowRadius = 12
        edge.shadowOffset = .zero
        edge.shadowOpacity = 0.5
        edge.strokeEnd = 0
        add(edge)
        animate(edge, "strokeEnd", from: 0, to: 1, duration: strokeTime, delay: delay)
        if !Buddy.reduceMotion {
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.5
            glow.toValue = 0.15
            glow.duration = Look.Breath.period * 2
            glow.autoreverses = true
            glow.repeatCount = .infinity
            glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.beginTime = CACurrentMediaTime() + delay + strokeTime
            edge.add(glow, forKey: "glow")
        }
    }

    func drawShape(_ kind: ShapeKind, _ pts: [CGPoint], label: String?, sketchy: Bool, delay: CFTimeInterval, width: CGFloat = Look.Line.mark) {
        let line = Sketch.polyline(kind, pts, sketchy: sketchy)
        let seed = Sketch.seed(pts)
        if sketchy {
            addStroke(Sketch.path(Sketch.jitter(line, seed: seed)), width: width, alpha: 1, delay: delay)
            addStroke(Sketch.path(Sketch.jitter(line, seed: seed + 7, amount: 2.2)), width: Look.Line.echo, alpha: Look.Line.echoAlpha, delay: delay + 0.05)
        } else {
            addStroke(Sketch.path(line), width: width, alpha: 1, delay: delay)
        }
        if kind == .arrow, pts.count >= 2 {
            addStroke(arrowHead(from: pts[pts.count - 2], to: pts[pts.count - 1]), width: width, alpha: 1, delay: delay + strokeTime * 0.95)
        }
        if let label, let anchor = labelAnchor(kind, pts) { addLabel(label, at: anchor, delay: delay) }
    }

    // MARK: Primitives

    private func add(_ layer: CALayer) {
        self.layer?.addSublayer(layer)
        switch group {
        case .drawing: annotationLayers.append(layer)
        case .step: stepLayers.append(layer)
        case .highlight: highlightLayers.append(layer)
        }
    }

    private func arrowHead(from a: CGPoint, to b: CGPoint) -> CGPath {
        let angle = atan2(b.y - a.y, b.x - a.x), len: CGFloat = 18, spread: CGFloat = .pi / 7
        let path = CGMutablePath()
        path.move(to: CGPoint(x: b.x - len * cos(angle - spread), y: b.y - len * sin(angle - spread)))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: b.x - len * cos(angle + spread), y: b.y - len * sin(angle + spread)))
        return path
    }

    private func labelAnchor(_ kind: ShapeKind, _ p: [CGPoint]) -> CGPoint? {
        if kind == .circle {
            let r = hypot(p[1].x - p[0].x, p[1].y - p[0].y)
            return CGPoint(x: p[0].x + r * 0.75, y: p[0].y - r * 0.75 - 8)
        }
        return p.last.map { CGPoint(x: $0.x + 12, y: $0.y - 12) }
    }

    /// A stroke that "draws itself" by animating strokeEnd.
    private func addStroke(_ path: CGPath, width: CGFloat, alpha: CGFloat, delay: CFTimeInterval) {
        let shape = CAShapeLayer()
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = markInk.withAlphaComponent(alpha).cgColor
        shape.lineWidth = width
        shape.lineCap = .round
        shape.lineJoin = .round
        Look.lift(shape)
        shape.strokeEnd = 0
        add(shape)
        // Drawn at an even hand speed, so the line keeps pace with the nib.
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0
        a.toValue = 1
        a.duration = strokeTime
        a.beginTime = CACurrentMediaTime() + delay
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        shape.add(a, forKey: "strokeEnd")
    }

    private func addOutline(_ rect: CGRect, delay: CFTimeInterval) {
        let shape = CAShapeLayer()
        shape.path = CGPath(roundedRect: rect.insetBy(dx: -4, dy: -4), cornerWidth: 7, cornerHeight: 7, transform: nil)
        shape.fillColor = markInk.withAlphaComponent(Look.fillAlpha).cgColor
        shape.strokeColor = markInk.cgColor
        shape.lineWidth = Look.Line.fine
        shape.opacity = 0
        add(shape)
        animate(shape, "opacity", from: 0, to: 1, duration: 0.25, delay: delay)
    }

    private func addPulse(at p: CGPoint, ringRadius: CGFloat, delay: CFTimeInterval) {
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: -6.5, y: -6.5, width: 13, height: 13), transform: nil)
        dot.position = p
        dot.fillColor = markInk.cgColor
        dot.strokeColor = NSColor.white.cgColor
        dot.lineWidth = 2
        Look.lift(dot)
        add(dot)
        arrive(dot, delay: delay)

        // A soft halo round the dot that breathes, like a click target's ring.
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: p.x - ringRadius, y: p.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
        ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: ring.frame.size), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = markInk.cgColor
        ring.lineWidth = Look.Line.fine
        ring.shadowColor = markInk.cgColor
        ring.shadowOpacity = 0.9
        ring.shadowRadius = Look.Breath.glow
        ring.shadowOffset = .zero
        ring.opacity = Look.Breath.opacity
        add(ring)
        arrive(ring, delay: delay)
        if !Buddy.reduceMotion { breathe(ring, sx: Look.Breath.scale, sy: Look.Breath.scale, delay: delay + 0.35) }
    }

    /// A small capsule in the ink colour, lit from above like the caption's glass.
    private func addLabel(_ text: String, at p: CGPoint, delay: CFTimeInterval) {
        let font = Look.ui(12.5, .semibold)
        // Quantity colours are light, so their labels take dark ink; ink blue keeps white.
        let c = markInk.usingColorSpace(.sRGB) ?? markInk
        let light = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        let textColour = light > 0.55 ? Look.Pane.fill.withAlphaComponent(1) : NSColor.white
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColour, .kern: 0.15])
        let size = attr.boundingRect(with: CGSize(width: 240, height: 200), options: [.usesLineFragmentOrigin]).size
        let pad = CGSize(width: 10, height: 5)
        let box = CGSize(width: ceil(size.width) + pad.width * 2, height: ceil(size.height) + pad.height * 2)
        var origin = CGPoint(x: p.x, y: p.y - box.height)
        origin.x = min(max(origin.x, 8), bounds.width - box.width - 8)
        origin.y = min(max(origin.y, 8), bounds.height - box.height - 8)
        // Step clear of labels already on screen: try below, then above, a few times.
        var frame = CGRect(origin: origin, size: box)
        for i in 1...8 where labelRects.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(frame) }) {
            let dy = (box.height + 6) * CGFloat((i + 1) / 2) * (i % 2 == 1 ? -1 : 1)
            frame.origin.y = min(max(origin.y + dy, 8), bounds.height - box.height - 8)
        }
        origin = frame.origin
        labelRects.append(CGRect(origin: origin, size: box))

        let bg = CAGradientLayer()
        bg.frame = CGRect(origin: origin, size: box)
        bg.colors = [(markInk.blended(withFraction: 0.18, of: .white) ?? markInk).cgColor, markInk.cgColor]
        bg.startPoint = CGPoint(x: 0.5, y: 1)
        bg.endPoint = CGPoint(x: 0.5, y: 0)
        bg.cornerRadius = min(box.height / 2, 12)
        bg.borderWidth = 0.5
        bg.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        Look.lift(bg)
        let t = CATextLayer()
        t.string = attr
        t.isWrapped = true
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.frame = CGRect(x: pad.width, y: pad.height, width: ceil(size.width) + 1, height: ceil(size.height))
        bg.addSublayer(t)
        bg.opacity = 0
        add(bg)
        animate(bg, "opacity", from: 0, to: 1, duration: Look.Motion.base, delay: delay)
    }

    private func animate(_ layer: CALayer, _ key: String, from: Any, to: Any, duration: CFTimeInterval, delay: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = CACurrentMediaTime() + delay
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: key)
    }
}
