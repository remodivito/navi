import AppKit

/// Mark mode: the screen becomes a page you can draw on. While it's on, a
/// clear layer over every display takes the mouse, so drawing never presses
/// a button underneath; the cursor is a pen, the screen dims a touch, and
/// a hint says what to do. Each stroke is tidied into a clean, numbered mark
/// in the user's own ink (screenshots get them in magenta, for Claude). Esc (or Done) finishes; the marks stay up, no
/// longer taking the mouse, until the question is answered.
final class MarkMode {
    private(set) var marks: [Mark] = []
    private(set) var isDrawing = false
    var onChange: (([Mark]) -> Void)?
    /// Esc or Done: back to the question.
    var onDone: (() -> Void)?

    private var layers: [NSPanel] = []
    private var canvases: [MarkCanvas] = []
    private let hint = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var keys: [Any] = []

    /// On screen: a soft lavender, light and fine (screenshots burn them in magenta).
    static let ink = Look.userInk

    /// Starts drawing (or carries on adding marks).
    func begin() {
        guard !isDrawing else { return }   // a second start would stack key monitors and cursors
        isDrawing = true
        buildLayers()
        for (panel, canvas) in zip(layers, canvases) {
            panel.ignoresMouseEvents = false
            canvas.drawing = true
            panel.orderFrontRegardless()
        }
        showHint()
        NSCursor.crosshair.push()
        keys = [NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) },
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) == true ? nil : e }].compactMap { $0 }
        trace("Mark mode on.")
    }

    /// Done drawing: the marks stay visible but no longer take the mouse.
    func finish() {
        guard isDrawing else { return }
        isDrawing = false
        layers.forEach { $0.ignoresMouseEvents = true }
        canvases.forEach { $0.drawing = false }
        hint.orderOut(nil)
        NSCursor.pop()
        keys.forEach { NSEvent.removeMonitor($0) }
        keys = []
        trace("Mark mode off: \(marks.count) mark(s).")
        onDone?()
    }

    /// Everything gone (asked and answered, or cancelled).
    func clear() {
        if isDrawing { finish() }
        marks = []
        canvases.forEach { $0.sync() }
        layers.forEach { $0.orderOut(nil) }
        onChange?(marks)
    }

    func undo() {
        guard !marks.isEmpty else { return }
        marks.removeLast()
        canvases.forEach { $0.sync() }
        onChange?(marks)
    }

    @discardableResult
    private func key(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { DispatchQueue.main.async { self.finish() }; return true }   // Esc
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "z" { DispatchQueue.main.async { self.undo() }; return true }
        return false
    }

    fileprivate func add(_ stroke: [NSPoint]) {
        guard let m = Mark.tidy(stroke) else { return }
        marks.append(m)
        canvases.forEach { $0.sync() }
        trace("Marked \(marks.count): \(m.verb).")
        onChange?(marks)
    }

    private func buildLayers() {
        guard layers.count != NSScreen.screens.count else {
            for (panel, screen) in zip(layers, NSScreen.screens) { panel.setFrame(screen.frame, display: false) }
            return
        }
        layers.forEach { $0.orderOut(nil) }
        layers = []
        canvases = []
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .screenSaver   // the type bar sits above, so it stays clickable
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.hidesOnDeactivate = false
            p.acceptsMouseMovedEvents = true
            p.sharingType = Settings.shared.showInRecordings ? .readOnly : .none
            let c = MarkCanvas(frame: NSRect(origin: .zero, size: screen.frame.size), mode: self)
            p.contentView = c
            p.setFrame(screen.frame, display: false)
            layers.append(p)
            canvases.append(c)
        }
    }

    private func showHint() {
        let text = "Circle, underline, draw an arrow or tap  ·  ⌘Z undo  ·  esc when done"
        let label = NSTextField(labelWithString: text)
        label.font = Look.ui(12.5, .medium)
        label.textColor = Look.warmWhite
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: 30)
        let (outer, content) = Glass.make(size: size, radius: 15)
        label.frame.origin = NSPoint(x: 16, y: (size.height - label.frame.height) / 2)
        content.addSubview(label)
        hint.contentView = outer
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hint.ignoresMouseEvents = true
        let s = Capture.screenUnderMouse()
        let top = s.frame.maxY - max(s.safeAreaInsets.top, NSStatusBar.system.thickness) - 14
        hint.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
        hint.orderFrontRegardless()
    }

    fileprivate var allMarks: [Mark] { marks }

    #if DEBUG
    /// A stroke as if drawn with the mouse (the gallery).
    func testDraw(_ stroke: [NSPoint]) {
        guard let first = stroke.first, let i = NSScreen.screens.firstIndex(where: { NSMouseInRect(first, $0.frame, false) }),
              canvases.indices.contains(i) else { return add(stroke) }
        canvases[i].replay(stroke)
    }
    #endif
}

/// One display's drawing layer: a smoothed, softly glowing line while you
/// draw, which morphs into the tidy mark when you let go (the freehand fades
/// as the clean shape draws itself in), then the marks with a soft glow,
/// a light fill and a numbered badge, like a highlighter pen.
private final class MarkCanvas: NSView {
    weak var mode: MarkMode?
    var drawing = false {
        didSet {
            layer?.backgroundColor = (drawing ? NSColor.black.withAlphaComponent(0.06) : .clear).cgColor
            window?.invalidateCursorRects(for: self)
        }
    }
    private var stroke: [NSPoint] = []
    private let live = CAShapeLayer()
    private var shown: [CALayer] = []

    init(frame: NSRect, mode: MarkMode) {
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
        live.fillColor = nil
        live.strokeColor = MarkMode.ink.cgColor
        live.lineWidth = 2.5
        live.lineCap = .round
        live.lineJoin = .round
        Self.glow(live)
        layer?.addSublayer(live)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if drawing { addCursorRect(bounds, cursor: .crosshair) } }

    private static func glow(_ l: CALayer) {
        l.shadowColor = MarkMode.ink.cgColor
        l.shadowOpacity = 0.8
        l.shadowRadius = 6
        l.shadowOffset = .zero
    }

    private func global(_ e: NSEvent) -> NSPoint {
        guard let w = window else { return e.locationInWindow }
        return NSPoint(x: e.locationInWindow.x + w.frame.minX, y: e.locationInWindow.y + w.frame.minY)
    }
    private func local(_ p: NSPoint) -> CGPoint {
        guard let w = window else { return p }
        return CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY)
    }

    /// A smooth curve through the points (midpoint quadratics): no corners from mouse sampling.
    private func smooth(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        guard pts.count > 2 else { pts.dropFirst().forEach { p.addLine(to: $0) }; return p }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    override func mouseDown(with e: NSEvent) {
        guard drawing else { return }
        stroke = [global(e)]
        live.removeAllAnimations()
        live.opacity = 1
        live.path = smooth(stroke.map(local))
    }

    override func mouseDragged(with e: NSEvent) {
        guard drawing else { return }
        let p = global(e)
        if let last = stroke.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
        stroke.append(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.path = smooth(stroke.map(local))
        CATransaction.commit()
    }

    override func mouseUp(with e: NSEvent) {
        guard drawing, !stroke.isEmpty else { return }
        // The freehand fades while the tidy shape draws itself in over it.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Buddy.reduceMotion ? 0.01 : 0.3
        live.opacity = 0
        live.add(fade, forKey: "fade")
        mode?.add(stroke)
        stroke = []
    }

    #if DEBUG
    /// Shows `stroke` as if just drawn, then lets go 0.6 s later (the gallery).
    func replay(_ pts: [NSPoint]) {
        stroke = pts
        live.removeAllAnimations()
        live.opacity = 1
        live.path = smooth(pts.map(local))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.3
            self.live.opacity = 0
            self.live.add(fade, forKey: "fade")
            self.mode?.add(self.stroke)
            self.stroke = []
        }
    }
    #endif

    /// Brings the drawn marks up to date: new ones draw in, removed ones fade.
    func sync() {
        let marks = mode?.allMarks ?? []
        while shown.count > marks.count {
            let gone = shown.removeLast()
            CATransaction.begin()
            CATransaction.setCompletionBlock { gone.removeFromSuperlayer() }
            gone.opacity = 0
            CATransaction.commit()
        }
        for i in shown.count..<marks.count { add(marks[i], number: i + 1) }
    }

    private func add(_ m: Mark, number: Int) {
        let group = CALayer()
        group.frame = bounds
        let ink = MarkMode.ink
        let path = m.path(local)
        let calm = Buddy.reduceMotion
        if m.kind == .ring || m.kind == .scribble {
            // A light fill, like a highlighter, so the area reads as chosen.
            let fill = CAShapeLayer()
            fill.path = path
            fill.fillColor = ink.withAlphaComponent(0.07).cgColor
            fill.strokeColor = nil
            fill.opacity = calm ? 1 : 0
            group.addSublayer(fill)
            if !calm {
                let f = CABasicAnimation(keyPath: "opacity")
                f.fromValue = 0; f.toValue = 1; f.beginTime = CACurrentMediaTime() + 0.15; f.duration = 0.3
                f.fillMode = .forwards; f.isRemovedOnCompletion = false
                fill.add(f, forKey: "in")
            }
        }
        let line = CAShapeLayer()
        line.path = path
        // A tap is a small ring with a bright centre, not a filled blot.
        line.fillColor = m.kind == .point ? ink.withAlphaComponent(0.18).cgColor : nil
        line.strokeColor = ink.cgColor
        line.lineWidth = 2.5
        line.lineCap = .round
        line.lineJoin = .round
        Self.glow(line)
        group.addSublayer(line)
        if !calm && m.kind != .point {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.32
            draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            line.add(draw, forKey: "draw")
        }
        // The number: a small disc in the ink with a white hairline, popping in once drawn.
        let c = local(m.badge)
        let badge = CALayer()
        badge.frame = CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)
        badge.cornerRadius = 9
        badge.backgroundColor = ink.cgColor
        badge.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        badge.borderWidth = 1.5
        Self.glow(badge)
        let text = CATextLayer()
        text.string = NSAttributedString(string: "\(number)", attributes: [.font: Look.ui(10.5, .semibold), .foregroundColor: NSColor.white])
        text.alignmentMode = .center
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.frame = CGRect(x: 0, y: 2.5, width: 18, height: 14)
        badge.addSublayer(text)
        group.addSublayer(badge)
        if !calm {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.2
            pop.toValue = 1
            pop.damping = 12
            pop.beginTime = CACurrentMediaTime() + 0.25
            pop.duration = pop.settlingDuration
            pop.fillMode = .backwards
            badge.add(pop, forKey: "pop")
        }
        layer?.insertSublayer(group, below: live)
        shown.append(group)
    }
}
