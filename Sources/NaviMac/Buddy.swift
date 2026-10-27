import AppKit
import QuartzCore

/// The companion, Navi (short for navigator): a small point of light that rests as a calm dot beside
/// the pointer and opens into a soft four-ray spark when it has something to
/// show: travelling, drawing or speaking. It glides to what it's showing and
/// draws the marks itself, its tip leading. Its character is in the quality of
/// its movement, not in tricks:
/// - follows the mouse on a soft spring (response 0.25 s, damping 0.7), trailing a touch
/// - travels on a gentle arc after a small wind-up, narrowing along its path like a quick
///   stroke, and settles without snapping
/// - while drawing it travels each stroke at handwriting pace, tip first
/// - its light rests low, brightens to listen, shimmers to think and lifts with each spoken word
/// - confidence shows in pace: after a correction it moves and draws a little more carefully
/// - it lets go the moment the mouse moves on its way back, and Reduce Motion calms it
/// It is click-through, and its frame timer runs only while something is moving.
final class Buddy {
    typealias State = Shell.LightState

    private let panel: NSPanel
    private static let box: CGFloat = 120
    private let host = NSView(frame: NSRect(x: 0, y: 0, width: Buddy.box, height: Buddy.box))
    private let drift = CALayer()          // a faint hover: it is never quite still (after Navi)
    private let halo = CAGradientLayer()   // the light
    private let body = CALayer()           // rotated and stretched; holds the shape
    private let nib = CAShapeLayer()       // the dot / spark itself
    private var open: CGFloat = 0          // 0 = a dot, 1 = a spark; eases towards its target
    private var lift: CGFloat = 0          // a brief opening on each spoken word
    private var monitors: [Any] = []
    private(set) var state = State.idle

    /// 1 is sure of itself; lower after a correction, drifting back up over a few answers.
    var confidence: CGFloat = 1
    /// Where the nib is and whether it is travelling, for the ink motes it leaves behind.
    var onMove: ((NSPoint, Bool) -> Void)?

    /// What the light says about what it's showing.
    typealias Tint = Shell.LightTint
    /// The light's current colour, for the caption it lights.
    private(set) var tintColor = OverlayView.ink
    /// Where the light is now (global AppKit points), or nil while it's hidden.
    var tip: NSPoint? { monitors.isEmpty || resting ? nil : position }

    /// Out of sight, but still riding the pointer, so it can appear in place at once.
    private(set) var resting = false
    private var restWork: DispatchWorkItem?

    // Motion.
    private enum Mode { case following, moving, parked }
    private var mode = Mode.following
    private var position = NSPoint.zero     // the nib's tip, global AppKit points
    private var velocity = CGVector.zero
    private var tick: Timer?
    private var path: [Leg] = []            // queued movement, played in order
    private var returning = false
    private var mouseAtReturn = NSPoint.zero
    private var angle: CGFloat = Buddy.restAngle
    private var stretch: CGFloat = 0        // 0 at rest; up to ~0.15 when travelling fast

    /// One piece of movement along a polyline: a flight arc or a traced stroke.
    private struct Leg {
        var points: [NSPoint]
        var lengths: [CGFloat]              // cumulative
        var duration: TimeInterval
        var began: Date?
        var easeInOut: Bool                 // flights ease; traces run at an even hand speed
        var done: (() -> Void)?
    }

    static let followOffset = CGVector(dx: 22, dy: -26)   // beside and below the pointer
    /// Leaning up and to the left, tip towards the pointer, like a pen held to write.
    static let restAngle: CGFloat = 0.62
    /// The light's core: a warm lamp white.
    static let lamp = Look.colour(Tokens.shared.colours.lamp)            // #FFF7EA
    /// The warm glow just around the core; the outer glow takes the tint.
    static let lampGlow = Look.colour(Tokens.shared.colours.lampGlow)    // #FFF1DA
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        host.wantsLayer = true
        build()
        applySharing()
    }

    func applySharing() { panel.sharingType = Settings.shared.showInRecordings ? .readOnly : .none }

    // MARK: Present when needed

    /// Blooms into view beside the pointer: a fraction of a second, from a point.
    func summon() {
        restWork?.cancel()
        restWork = nil
        guard resting, !monitors.isEmpty else { return }
        resting = false
        if mode != .moving { position = followTarget(); place() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drift.transform = CATransform3DMakeScale(0.3, 0.3, 1)
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Self.reduceMotion ? 0.1 : Look.Motion.base
            c.timingFunction = Look.Motion.settle
            panel.animator().alphaValue = 1
        }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1
        grow.duration = Self.reduceMotion ? 0.1 : Look.Motion.base
        grow.timingFunction = Look.Motion.settle
        drift.transform = CATransform3DIdentity
        drift.add(grow, forKey: "summon")
        startTick()
    }

    /// Fades back out of sight after `delay`, unless summoned again first.
    func rest(after delay: TimeInterval = 0) {
        restWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.resting, !self.monitors.isEmpty else { return }
            self.resting = true
            NSAnimationContext.runAnimationGroup { c in
                c.duration = Self.reduceMotion ? 0.1 : Look.Motion.gentle
                self.panel.animator().alphaValue = 0
            }
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.5
            shrink.duration = Look.Motion.gentle
            self.drift.add(shrink, forKey: "rest")
        }
        restWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Showing

    func setEnabled(_ on: Bool) {
        if on {
            guard monitors.isEmpty else { return }
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouseMoved(); return e }) { monitors.append(l) }
            position = followTarget()
            place()
            panel.orderFrontRegardless()
            set(.idle, force: true)
        } else {
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors = []
            stopTick()
            panel.orderOut(nil)
        }
    }

    private func followTarget() -> NSPoint {
        let m = NSEvent.mouseLocation
        // Near the right or bottom edge it moves to the other side of the pointer.
        guard let f = (NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first)?.frame
        else { return m }   // no display for a moment
        let dx = m.x + Self.followOffset.dx + 30 > f.maxX ? -Self.followOffset.dx : Self.followOffset.dx
        let dy = m.y + Self.followOffset.dy - 30 < f.minY ? -Self.followOffset.dy : Self.followOffset.dy
        return NSPoint(x: m.x + dx, y: m.y + dy)
    }

    private func mouseMoved() {
        switch mode {
        case .following:
            startTick()
        case .moving where returning:
            // On its way back it gives way to the mouse at once.
            let m = NSEvent.mouseLocation
            if hypot(m.x - mouseAtReturn.x, m.y - mouseAtReturn.y) > 60 {
                path = []
                returning = false
                mode = .following
                startTick()
            }
        default:
            break
        }
    }

    // MARK: Moving

    /// How long a flight from where it is (or will be) to `p` takes.
    func flightTime(to p: NSPoint) -> TimeInterval {
        if Self.reduceMotion { return 0.15 }
        let from = path.last?.points.last ?? position
        let d = hypot(p.x - from.x, p.y - from.y)
        return d < 2 ? 0 : min(max(Double(d) / 750, 0.5), 1.2) / Double(max(0.6, confidence))
    }

    /// How long tracing `pts` takes at handwriting pace.
    func traceTime(_ pts: [NSPoint]) -> TimeInterval {
        if Self.reduceMotion { return 0.2 }
        let len = zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        return min(max(Double(len) / 480, 0.45), 1.9) / Double(max(0.6, confidence))
    }

    /// Glides to just beside `p` (global AppKit point) and waits there.
    /// `clear` is the radius of what it's showing: it waits just outside it,
    /// below and to the right, so it never sits on the words of a control.
    func fly(to p: NSPoint, clear: CGFloat = 16) {
        guard !monitors.isEmpty else { return }
        let off = clear * 0.72 + 8
        let target = NSPoint(x: p.x + off, y: p.y - off)
        if mode == .parked, path.isEmpty, hypot(position.x - target.x, position.y - target.y) < 2 { return }
        if let last = path.last?.points.last, hypot(last.x - target.x, last.y - target.y) < 2 { return }
        returning = false
        path = []
        enqueueFlight(to: target, done: nil)
        enqueuePark()
    }

    /// Glides to the start of a stroke, then travels along it tip first, as if
    /// drawing it. Returns the wait before the stroke itself begins, so the ink
    /// can start then.
    @discardableResult
    func trace(_ pts: [NSPoint]) -> TimeInterval {
        guard !monitors.isEmpty, let first = pts.first else { return 0 }
        returning = false
        path = []
        let wait = flightTime(to: first)
        enqueueFlight(to: first, done: nil)
        if pts.count > 1 { path.append(Self.leg(pts, duration: traceTime(pts), ease: false)) }
        enqueuePark()
        return wait
    }

    /// A tour stop: glides slowly to just beside `p` (a control being named), then
    /// gives one soft pulse there. Light only: nothing is drawn.
    func glide(to p: NSPoint) {
        guard !monitors.isEmpty else { return }
        let target = NSPoint(x: p.x + 7, y: p.y - 7)
        returning = false
        path = []
        enqueueFlight(to: target, slow: true) { [weak self] in self?.touch() }
        enqueuePark()
    }

    /// One soft pulse of the halo where the light has arrived.
    private func touch() {
        guard !Self.reduceMotion else { return }
        let p = CABasicAnimation(keyPath: "transform.scale")
        p.fromValue = 1
        p.toValue = 1.9
        p.autoreverses = true
        p.duration = 0.45
        p.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(p, forKey: "touch")
    }

    /// Wanders slowly inside an area once it's outlined, the way a finger moves
    /// over a region on a slide while you talk about it, then rests in the middle.
    func roam(in r: NSRect) {
        guard !monitors.isEmpty, !Self.reduceMotion, r.width > 40, r.height > 30 else { return }
        if let last = path.last, last.duration == 0 { path.removeLast() }   // drop the park after the outline
        let start = path.last?.points.last ?? position
        let marks: [(CGFloat, CGFloat)] = [(0.5, 0.5), (0.25, 0.62), (0.45, 0.78), (0.74, 0.66), (0.7, 0.34), (0.38, 0.3), (0.5, 0.5)]
        var key = [start] + marks.map { NSPoint(x: r.minX + r.width * $0.0, y: r.minY + r.height * $0.1) }
        key = [key[0]] + key + [key[key.count - 1]]
        // A smooth loop through the key points (Catmull-Rom), not a zigzag.
        var pts: [NSPoint] = []
        for i in 1..<(key.count - 2) {
            let p0 = key[i - 1], p1 = key[i], p2 = key[i + 1], p3 = key[i + 2]
            for s in 0..<12 {
                let t = CGFloat(s) / 12, t2 = t * t, t3 = t2 * t
                func c(_ a: CGFloat, _ b: CGFloat, _ cc: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3)
                }
                pts.append(NSPoint(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        pts.append(key[key.count - 2])
        path.append(Self.leg(pts, duration: min(7, max(4.5, Double(r.width + r.height) / 180)), ease: true))
        enqueuePark()
    }

    /// Back to riding beside the mouse.
    func comeBack() {
        guard mode != .following, !returning else { return }
        returning = true
        mouseAtReturn = NSEvent.mouseLocation
        path = []
        enqueueFlight(to: followTarget()) { [weak self] in
            self?.returning = false
            self?.mode = .following
            self?.velocity = .zero
        }
        mode = .moving
        startTick()
    }

    private func enqueueFlight(to end: NSPoint, slow: Bool = false, done: (() -> Void)?) {
        let start = path.last?.points.last ?? position
        let d = hypot(end.x - start.x, end.y - start.y)
        guard d > 1 else { done?(); return }
        // A gentle arc, bowing upward a little, after a short wind-up away from the target.
        let mid = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + min(d * 0.12, 50))
        let ux = (end.x - start.x) / d, uy = (end.y - start.y) / d
        let windup = NSPoint(x: start.x - ux * min(6, d * 0.05), y: start.y - uy * min(6, d * 0.05))
        var pts = [start, windup]
        for i in 1...24 {
            let t = CGFloat(i) / 24, u = 1 - t
            pts.append(NSPoint(x: u * u * windup.x + 2 * u * t * mid.x + t * t * end.x,
                               y: u * u * windup.y + 2 * u * t * mid.y + t * t * end.y))
        }
        var leg = Self.leg(pts, duration: flightTime(to: end) * (slow ? 1.5 : 1), ease: true)
        leg.done = done
        path.append(leg)
        mode = .moving
        startTick()
    }

    private func enqueuePark() {
        var leg = Self.leg([path.last?.points.last ?? position], duration: 0, ease: false)
        leg.done = { [weak self] in self?.mode = .parked }
        path.append(leg)
        mode = .moving
        startTick()
    }

    private static func leg(_ pts: [NSPoint], duration: TimeInterval, ease: Bool) -> Leg {
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(pts, pts.dropFirst()) { lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y)) }
        return Leg(points: pts, lengths: lengths, duration: duration, began: nil, easeInOut: ease, done: nil)
    }

    // MARK: The frame loop

    private func startTick() {
        guard tick == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    /// How open the spark should be now: closed at rest, open on the move.
    private var openTarget: CGFloat {
        if mode == .moving { return 1 }
        let base: CGFloat
        switch state {
        case .idle: base = 0
        case .listening: base = 0.3
        case .thinking: base = 0.45
        case .speaking: base = 0.55
        }
        return min(1, base + lift)
    }

    private func updateShape() {
        let target = openTarget
        lift *= 0.9
        guard abs(open - target) > 0.002 else { return }
        open += (target - open) * 0.14
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nib.path = Self.bloomPath(open, centre: Self.box / 2)
        CATransaction.commit()
    }

    private var shapeSettled: Bool { abs(open - openTarget) < 0.003 && lift < 0.01 }

    private func step() {
        let dt: CGFloat = 1.0 / 60
        updateShape()
        switch mode {
        case .parked:
            settlePose(towards: Self.restAngle)
            if abs(angle - Self.restAngle) < 0.005 && stretch < 0.003 && shapeSettled { stopTick() }
        case .following:
            // A soft spring: response 0.25 s, damping 0.7.
            let target = followTarget()
            let k: CGFloat = (2 * .pi / 0.25) * (2 * .pi / 0.25), c: CGFloat = 4 * .pi * 0.7 / 0.25
            velocity.dx += (k * (target.x - position.x) - c * velocity.dx) * dt
            velocity.dy += (k * (target.y - position.y) - c * velocity.dy) * dt
            position.x += velocity.dx * dt
            position.y += velocity.dy * dt
            let speed = hypot(velocity.dx, velocity.dy)
            onMove?(position, false)
            stretch += (min(0.08, speed / 9000) - stretch) * 0.25
            settlePose(towards: Self.restAngle)
            place()
            if hypot(target.x - position.x, target.y - position.y) < 0.3, speed < 2, stretch < 0.003, shapeSettled {
                position = target
                place()
                stopTick()
            }
        case .moving:
            guard !path.isEmpty else { mode = .parked; return }
            if path[0].began == nil { path[0].began = Date() }
            let leg = path[0]
            let raw = leg.duration > 0 ? min(1, CGFloat(Date().timeIntervalSince(leg.began!) / leg.duration)) : 1
            let t = leg.easeInOut ? raw * raw * (3 - 2 * raw) : raw
            let before = position
            position = Self.point(along: leg, at: t)
            let dx = position.x - before.x, dy = position.y - before.y
            let speed = hypot(dx, dy) / dt
            stretch += (min(0.15, speed / 7000) - stretch) * 0.35
            // Tip first along the way; the nib's tip points up at angle 0.
            if hypot(dx, dy) > 0.5 { settlePose(towards: atan2(dy, dx) - .pi / 2, rate: 0.35) }
            place()
            onMove?(position, speed > 120)
            if raw >= 1 {
                let done = path.removeFirst().done
                done?()
                if path.isEmpty && mode == .moving { mode = .parked; onMove?(position, false) }
            }
        }
        applyPose()
    }

    private static func point(along leg: Leg, at t: CGFloat) -> NSPoint {
        guard leg.points.count > 1, let total = leg.lengths.last, total > 0 else { return leg.points.last ?? .zero }
        let target = t * total
        var i = 1
        while i < leg.lengths.count - 1 && leg.lengths[i] < target { i += 1 }
        let a = leg.points[i - 1], b = leg.points[i]
        let seg = leg.lengths[i] - leg.lengths[i - 1]
        let f = seg > 0 ? (target - leg.lengths[i - 1]) / seg : 1
        return NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// Eases the angle towards a target the short way round and relaxes the
    /// stretch: nothing ever snaps.
    private func settlePose(towards target: CGFloat, rate: CGFloat = 0.15) {
        var d = target - angle
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        angle += d * rate
        if mode != .moving { stretch *= 0.85 }
    }

    private func place() {
        // The panel is centred on the nib's tip.
        panel.setFrameOrigin(NSPoint(x: position.x - Self.box / 2, y: position.y - Self.box / 2))
    }

    private func applyPose() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Narrower and longer along its direction of travel, like a quick stroke.
        body.setAffineTransform(CGAffineTransform(rotationAngle: angle).scaledBy(x: 1 - stretch, y: 1 + stretch * 1.6))
        CATransaction.commit()
    }

    // MARK: Light

    func set(_ s: State) { set(s, force: false) }

    private func set(_ s: State, force: Bool) {
        guard s != state || force else { return }
        state = s
        startTick()   // ease the shape towards this state's openness
        nib.removeAnimation(forKey: "turn")
        if s == .thinking, !Self.reduceMotion {
            // A slow turn of the half-open spark while it thinks.
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = Double.pi / 2
            turn.duration = 1.6
            turn.repeatCount = .infinity
            nib.add(turn, forKey: "turn")
        }
        halo.removeAllAnimations()
        let (level, scale): (Float, CGFloat) = {
            switch s {
            case .idle: return (0.35, 0.55)   // quiet at rest
            case .listening: return (0.95, 1.05)
            case .thinking: return (0.7, 0.95)
            case .speaking: return (0.8, 1)
            }
        }()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        halo.opacity = level
        halo.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
        guard !Self.reduceMotion else { return }
        switch s {
        case .idle:
            // A slow breath of light, barely there.
            halo.add(Self.pulse(from: 0.28, to: 0.42, duration: 3.2), forKey: "breath")
        case .thinking:
            // The light gathers and eases.
            halo.add(Self.pulse(from: 0.45, to: 0.9, duration: 0.9), forKey: "shimmer")
        case .listening, .speaking:
            break   // steady; `pulse()` lifts it with each spoken word
        }
    }

    private static func pulse(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    /// Tints the light by what it's showing, blending over a moment as Navi's
    /// colour does: ink for pointing, a fresher green for a step to take, a
    /// warmer violet while explaining an idea.
    func tint(_ t: Tint) {
        let c: NSColor
        switch t {
        case .ink: c = OverlayView.ink
        case .step: c = NSColor(calibratedRed: 0.2, green: 0.72, blue: 0.62, alpha: 1)
        case .idea: c = NSColor(calibratedRed: 0.5, green: 0.42, blue: 0.95, alpha: 1)
        }
        glow(c)
    }

    /// Colours the light's glow (and the core's rim) without changing what it
    /// means: used to bind it to the thing it's drawing in an explanation.
    func glow(_ c: NSColor) {
        tintColor = c
        CATransaction.begin()
        CATransaction.setAnimationDuration(Look.Motion.gentle)
        halo.colors = [c.withAlphaComponent(0.46).cgColor, c.withAlphaComponent(0.15).cgColor, c.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }

    /// A soft lift of the light on each spoken word.
    func pulse() {
        guard state == .speaking, !Self.reduceMotion else { return }
        lift = 0.3
        startTick()
        let p = CABasicAnimation(keyPath: "opacity")
        p.fromValue = 1
        p.toValue = 0.8
        p.duration = 0.28
        p.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(p, forKey: "word")
    }

    // MARK: Drawing

    /// Four points joined by curves. Closed (0) the curves bow outwards into a
    /// dot of radius 3.8; open (1) the rays reach 7.6 and the sides pinch in to
    /// a soft spark with rounded tips.
    static func bloomPath(_ open: CGFloat, centre c: CGFloat) -> CGPath {
        let o = max(0, min(1, open))
        let ray = 3.8 + 3.8 * o
        let waist = ray * (1.41 - 1.2 * o)     // the curves' control radius: round when closed, pinched when open
        let p = CGMutablePath()
        for i in 0..<4 {
            let a = CGFloat(i) * .pi / 2, b = a + .pi / 4, n = a + .pi / 2
            let tip = CGPoint(x: c + cos(a) * ray, y: c + sin(a) * ray)
            if i == 0 { p.move(to: tip) }
            p.addQuadCurve(to: CGPoint(x: c + cos(n) * ray, y: c + sin(n) * ray),
                           control: CGPoint(x: c + cos(b) * waist, y: c + sin(b) * waist))
        }
        p.closeSubpath()
        return p
    }

    private func build() {
        let c = Self.box / 2
        // The light: a soft radial glow in the ink colour, centred on the nib's body.
        let glow = Self.box * 0.62
        halo.type = .radial
        halo.colors = [OverlayView.ink.withAlphaComponent(0.46).cgColor, OverlayView.ink.withAlphaComponent(0.15).cgColor,
                       OverlayView.ink.withAlphaComponent(0).cgColor]
        halo.locations = [0, 0.35, 1]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.frame = CGRect(x: c - glow / 2, y: c - glow / 2, width: glow, height: glow)
        halo.opacity = 0.35
        drift.frame = host.bounds
        host.layer?.addSublayer(drift)
        drift.addSublayer(halo)
        if !Self.reduceMotion {
            // A small, slow loop of about 1.5 pt: alive, not busy.
            let loop = CAKeyframeAnimation(keyPath: "position")
            loop.path = CGPath(ellipseIn: CGRect(x: c - 1.5, y: c - 1, width: 3, height: 2), transform: nil)
            loop.duration = 5.5
            loop.repeatCount = .infinity
            loop.calculationMode = .paced
            drift.add(loop, forKey: "hover")
        }

        // The shape: a dot that blooms into a soft spark, centred on the panel.
        body.frame = host.bounds
        drift.addSublayer(body)
        nib.frame = host.bounds
        nib.path = Self.bloomPath(0, centre: c)
        nib.fillColor = Self.lamp.cgColor          // a lamp-white core; the colour lives in the glow
        nib.shadowColor = Self.lampGlow.cgColor
        nib.shadowOpacity = 0.9
        nib.shadowRadius = 4
        nib.shadowOffset = .zero
        body.addSublayer(nib)
        applyPose()
    }
}
