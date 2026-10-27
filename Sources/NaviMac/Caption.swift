import AppKit
import QuartzCore

/// Navi's words: a small pane of Liquid Glass (a dark visual-effect pane
/// before macOS 26) that travels beside the light,
/// lit on the corner nearest it and joined to it by a fine thread of its
/// colour. Spoken sentences are laid out in full straight away as a faint
/// ghost, so the pane doesn't grow word by word, and each word lights up as
/// the voice reaches it, arriving in Navi's colour and cooling to white. The words that name
/// the thing on screen keep a little of that colour, matching the mark.
/// It rides with the companion, but it is never a speech balloon with a tail:
/// the light is the speaker.
final class Caption {
    enum Style { case answer, status, listening }

    /// Where Navi is and what colour its light is, or nil when it's hidden.
    var bloom: (() -> (point: NSPoint, tint: NSColor)?)?
    /// What's drawn on screen (global points), so the words don't cover it.
    var keepClear: (() -> [NSRect])?

    private let panel: AnswerPanel
    private let root = NSView()
    private var glass: NSView!                // casts the pane's shadow
    private var topSheen: CAGradientLayer!
    private let sheen = NSView()              // in (or over) the glass: light and words
    private let glow = CAGradientLayer()      // Navi's light falling on the glass
    private let words = CALayer()
    private let shimmer = CAGradientLayer()   // sweeps "Looking…" while it works
    private let thread = CAShapeLayer()

    private struct Word { let text: String; let key: String; let layer: CATextLayer; var lit: Bool; let named: Bool; var colour: NSColor? = nil }
    /// The colour bound to the thing this sentence names (explanations), if any.
    private var namedColour: NSColor?
    private var items: [Word] = []
    private(set) var style = Style.answer
    private var voiced = false
    private var revealTimer: Timer?
    private var lastLit = Date()

    // Placement, in global AppKit points.
    private var origin = NSPoint.zero         // the glass's bottom-left, on a soft spring
    private var velocity = CGVector.zero
    private var size = CGSize.zero            // eased towards `target`
    private var targetSize = CGSize.zero
    private var anchor = NSPoint.zero         // where to sit when Navi is hidden
    private var corner = 0                    // which side of Navi it hangs on; see `target`
    private var placed = false
    /// Whether the caption is on screen (floating or in the notch).
    var isShowing: Bool { placed }
    private var tick: Timer?
    private var still = 0
    private var lastNavi = NSPoint.zero
    private var doneAt: NSPoint?              // where the mouse was when the answer ended
    private var doneTime = Date.distantPast
    private let prior = CATextLayer()         // what was said before, faded above
    private var history: [String] = []        // this answer's earlier sentences
    private var hold: NSPoint?                // where it sits while there's text to read
    private var dockScreen: NSScreen?         // set once a long answer moves into the notch
    private var dockTimer: Timer?
    private var priorHeight: CGFloat = 0
    private let notchShape = CAShapeLayer()   // the docked panel, shaped like the notch it grows from
    private let pip = CALayer()               // Navi's light, beside the line being said (now the owl's place)
    /// Navi's face: in front for a status ("Looking…"), in the back seat beside an answer.
    private let owl = OwlView(pixel: 1.5, compact: true)
    private var sizeVelocity = CGVector.zero
    private var collapsing = false
    /// The second half of a docked collapse; something shown meanwhile cancels it.
    private var collapseWork: DispatchWorkItem?
    private var shownPrior = ""
    // The thread is a small soft rope (global points), so it trails, sways and settles.
    private var rope: [NSPoint] = []
    private var ropePrev: [NSPoint] = []
    private var ropeAttach: NSPoint?
    private var ropeEnergy: CGFloat = 0
    private let threadFade = CAGradientLayer()   // bright at the light, softer at the pane
    private var mouseWatch: [Any] = []
    private var shownGen = 0

    // Sizes from the design tokens (Look.caption).
    static let maxWidth = CGFloat(Look.caption.maxWidth)
    static let pad = CGSize(width: Look.caption.padX, height: Look.caption.padY)
    static let radius = CGFloat(Look.caption.radius)
    static let gap = CGFloat(Look.caption.gap)              // between Navi and the glass
    static let font = Look.ui(CGFloat(Look.caption.fontSize), .medium)
    static let bold = Look.ui(CGFloat(Look.caption.fontSize), .semibold)
    static let lineHeight = CGFloat(Look.caption.lineHeight)
    static let dockWidth = CGFloat(Look.caption.dockWidth)
    static let priorFont = Look.ui(CGFloat(Look.caption.priorFontSize))
    static let ghost = Float(Look.caption.ghost)

    init() {
        panel = AnswerPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = root
        root.wantsLayer = true
        root.alphaValue = 0

        sheen.wantsLayer = true
        let s = sheen.layer!
        // Navi's own ink pane, the same on every platform (no system glass).
        glass = NSView()
        glass.wantsLayer = true
        Look.Pane.shadow(glass.layer!)
        root.addSubview(glass)
        topSheen = Look.Pane.style(s, radius: Self.radius)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 0.45, 1]
        s.addSublayer(glow)
        notchShape.fillColor = NSColor.black.cgColor
        notchShape.opacity = 0
        s.insertSublayer(notchShape, at: 0)
        pip.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        pip.cornerRadius = 3.5
        pip.shadowOffset = .zero
        pip.shadowRadius = 5
        pip.shadowOpacity = 0.9
        pip.opacity = 0
        prior.isWrapped = true
        prior.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        s.addSublayer(prior)
        s.addSublayer(words)
        s.addSublayer(pip)
        pip.isHidden = true
        sheen.addSubview(owl)
        root.addSubview(sheen)

        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [NSColor(white: 1, alpha: 0.4).cgColor, NSColor.white.cgColor, NSColor(white: 1, alpha: 0.4).cgColor]

        thread.lineWidth = 0
        thread.shadowOffset = .zero
        thread.shadowRadius = 3
        thread.shadowOpacity = 0.8
        threadFade.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.35).cgColor]
        thread.mask = threadFade
        root.layer?.addSublayer(thread)
        answerRow.isHidden = true
        root.addSubview(answerRow)
        answerRow.onSubmit = { [weak self] text in self?.onAnswer?(text) }
        answerRow.onHelp = { [weak self] help in self?.onHelp?(help) }
        answerRow.onCancel = { [weak self] in self?.onAnswerCancel?() }
        offerRow.isHidden = true
        root.addSubview(offerRow)
        linkButton.isHidden = true
        linkButton.target = self
        linkButton.action = #selector(followLink)
        root.addSubview(linkButton)
        applySharing()
    }

    // MARK: Answering a practice question

    /// A practice question's answer line, under the question: type, ↩, or ask for help.
    private let answerRow = AnswerRow()
    /// Whether the answer line is open (the caption stays up while it is).
    private(set) var answering = false
    /// A file offered for download is showing under the words (its buttons take clicks).
    private(set) var offering = false
    let offerRow = OfferRow()
    /// Anything under the words that takes clicks keeps the caption up and solid.
    private var holding: Bool { answering || offering }
    var onAnswer: ((String) -> Void)?
    var onHelp: ((AnswerRow.Help) -> Void)?
    var onAnswerCancel: (() -> Void)?

    /// Opens the answer line under the question showing now and takes the keys,
    /// without bringing Navi's app forward.
    func takeAnswer() {
        guard placed, style == .answer, !items.isEmpty else { return }
        answering = true
        stopWatching()
        dockTimer?.invalidate()
        answerRow.reset()
        answerRow.isHidden = false
        panel.ignoresMouseEvents = false
        layout()
        panel.makeKey()
        panel.makeFirstResponder(answerRow.field)
    }

    /// Shows a file offered for download under the sentence offering it. The caption
    /// stays up (and solid under the pointer) until it's answered or put away.
    /// Returns false if there's no caption up to hold it.
    @discardableResult
    func offer(file: String, size: Int64?, from host: String) -> Bool {
        guard placed else { return false }
        offering = true
        stopWatching()
        dockTimer?.invalidate()
        offerRow.show(file: file, size: size, from: host)
        offerRow.isHidden = false
        panel.ignoresMouseEvents = false
        layout()
        return true
    }

    // MARK: A link under the words

    /// "Don't keep this", "Start fresh instead": small, under the words, for a few seconds.
    private let linkButton = LinkButton()
    private var linkAction: (() -> Void)?
    private var linkTimer: Timer?
    private var linking: Bool { linkAction != nil }
    static let linkHeight: CGFloat = 24

    func link(_ title: String, action: @escaping () -> Void) {
        guard placed else { return }
        linkAction = action
        linkButton.set(title)
        linkButton.isHidden = false
        panel.ignoresMouseEvents = false
        linkTimer?.invalidate()
        linkTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.endLink() }
        layout()
    }

    func endLink() {
        guard linking else { return }
        linkAction = nil
        linkTimer?.invalidate()
        linkButton.isHidden = true
        if !holding { panel.ignoresMouseEvents = true }
        if placed { layout() }
    }

    @objc private func followLink() {
        let action = linkAction
        endLink()
        action?()
    }

    /// Puts the offer away (answered, done, or the caption going away).
    func endOffer() {
        guard offering else { return }
        offering = false
        offerRow.isHidden = true
        if !answering && !linking { panel.ignoresMouseEvents = true }
        if placed { layout() }
    }

    /// Closes the answer line (sent, cancelled, or the caption going away).
    func endAnswer() {
        guard answering else { return }
        answering = false
        answerRow.isHidden = true
        if !offering && !linking { panel.ignoresMouseEvents = true }
        panel.resignKey()
        if placed { layout() }
    }

    func applySharing() { panel.sharingType = Settings.shared.showInRecordings ? .readOnly : .none }

    // MARK: Showing

    /// Shows text at once (status, your words while listening) or, for a
    /// typed answer, lights it word by word at reading pace. Words already
    /// shown that still match are kept, so streamed text only adds.
    func show(_ text: String, style: Style, at anchor: NSPoint) {
        practice = false
        status = nil
        set(Self.split(text), style: style, voiced: false, keys: [], anchor: anchor)
        if style == .answer { startReading() } else { light(upTo: items.count - 1) }
    }

    /// Lays out a sentence about to be spoken, unlit; `spoke` lights each
    /// word as the voice reaches it. `named` are the words that name the
    /// thing it's showing.
    func say(_ sentence: String, named: [String], at anchor: NSPoint, near: NSPoint? = nil, colour: NSColor? = nil, practice: Bool = false, stay: Bool = false) {
        settle(near, stay: stay)
        self.practice = practice
        status = nil
        namedColour = colour
        set(Self.split(sentence), style: .answer, voiced: true, keys: named.map(Self.key).filter { $0.count > 2 }, anchor: anchor, fresh: true)
        lastLit = Date()
        // If the voice stops reporting words, keep up at a speaking pace.
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastLit) > 1.1, let next = self.items.firstIndex(where: { !$0.lit }) else { return }
            self.light(upTo: next)
        }
    }

    /// A typed answer's sentence: lit word by word at `wordsPerSecond`, the
    /// pace the reply is arriving at, so it reads as live rather than replayed.
    func read(_ sentence: String, named: [String], at anchor: NSPoint, near: NSPoint? = nil, wordsPerSecond: Double, colour: NSColor? = nil,
              practice: Bool = false, stay: Bool = false, pauses: Set<Int> = []) {
        settle(near, stay: stay)
        self.practice = practice
        status = nil
        namedColour = colour
        set(Self.split(sentence), style: .answer, voiced: false, keys: named.map(Self.key).filter { $0.count > 2 }, anchor: anchor, fresh: true)
        light(upTo: -1)
        // The words already exist: show the sentence whole, in one quick sweep. Only a
        // tour reveals word by word, so each word lights as the light reaches its thing.
        if pauses.isEmpty {
            light(upTo: items.count - 1, stagger: 0.012)
            return
        }
        let step = 1 / min(max(wordsPerSecond, 5.5), 7)
        func next(after delay: TimeInterval) {
            revealTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self, let i = self.items.firstIndex(where: { !$0.lit }) else { return }
                self.light(upTo: i)
                next(after: step + (pauses.contains(i) ? Self.tourPause : 0))
            }
        }
        next(after: step)
    }

    /// How long the words wait at a tour stop: the light's glide plus a beat to look.
    static let tourPause: TimeInterval = Look.caption.tourPause

    /// While there's text to read the pane holds still beside what's being
    /// shown (`near`, a mark), instead of riding the light as it draws;
    /// the thread stretches to keep them joined. It glides once per sentence.
    /// `stay`: keep the pane where it is (a practice question has no mark to sit beside).
    private func settle(_ near: NSPoint?, stay: Bool = false) {
        if stay, hold != nil { return }
        hold = near.map { NSPoint(x: $0.x + 20, y: $0.y - 20) } ?? bloom?()?.point ?? hold
    }

    /// A longer answer moves into the notch: the pane glides up to the top of
    /// its screen and becomes a black panel growing down from the notch, with
    /// the whole answer so far.
    /// Where the notch panel would sit on `s`: generous, up to five lines deep.
    private func dockArea(on s: NSScreen) -> NSRect {
        let h = max(s.safeAreaInsets.top, 24) + 150, w = Self.dockWidth + 90
        return NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h)
    }

    private var dockTarget: NSScreen? {
        let b = hold ?? bloomPoint
        return NSScreen.screens.first { NSMouseInRect(b, $0.frame, false) } ?? NSScreen.main
    }

    /// Moves into the notch, unless the panel would cover something being shown
    /// (a toolbar button in a full-screen app, say). Returns whether it docked.
    @discardableResult
    func dockIfClear() -> Bool {
        guard dockScreen == nil, placed, let s = dockTarget else { return false }
        let area = dockArea(on: s)
        if keepClear?().contains(where: { $0.intersects(area) }) == true {
            trace("Not moving into the notch: it would cover what's being shown.")
            return false
        }
        dock()
        return true
    }

    /// In the notch, but a new mark landed under it: float again beside the work.
    func floatIfCovering() {
        guard let s = dockScreen, !collapsing, keepClear?().contains(where: { $0.intersects(dockArea(on: s)) }) == true else { return }
        trace("A mark landed under the notch panel: floating instead.")
        undock()
        layout()
        startTick()
    }

    func dock() {
        guard dockScreen == nil, placed else { return }
        let b = hold ?? bloomPoint
        let screen = NSScreen.screens.first { NSMouseInRect(b, $0.frame, false) } ?? NSScreen.main
        // The floating pane fades; the panel opens out of the notch in its place.
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            root.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.placed, self.dockScreen == nil else { return }
            self.dockScreen = screen
            self.glass.alphaValue = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let l = self.sheen.layer!
            l.backgroundColor = NSColor.clear.cgColor
            l.cornerRadius = 0
            l.masksToBounds = false
            l.borderWidth = 0
            self.topSheen.isHidden = true
            // With a notch it's pure black, melting into it; without one it's a
            // free-floating ink pane with its hairline and shadow.
            let notched = self.hasNotch
            self.notchShape.fillColor = (notched ? NSColor.black : Look.Pane.fill).cgColor
            self.notchShape.strokeColor = notched ? nil : Look.Pane.hairline.cgColor
            self.notchShape.lineWidth = notched ? 0 : 1
            if notched { self.notchShape.shadowOpacity = 0 } else { Look.Pane.shadow(self.notchShape) }
            self.glow.opacity = 0
            self.thread.opacity = 0
            self.notchShape.opacity = 1
            self.pip.opacity = 0
            self.words.opacity = 0
            self.prior.opacity = 0
            CATransaction.commit()
            self.layout()
            self.size = self.notchSize
            self.sizeVelocity = .zero
            self.frame()
            self.root.alphaValue = 1
            // Content arrives once the panel has mostly opened.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                CATransaction.begin()
                CATransaction.setAnimationDuration(Look.Motion.base)
                CATransaction.setAnimationTimingFunction(Look.Motion.settle)
                self.words.opacity = 1
                self.prior.opacity = 1
                self.pip.opacity = 1
                CATransaction.commit()
            }
            self.startTick()
        })
    }

    /// The notch's size on the docking screen, or a small pill where there's none.
    private var notchSize: CGSize {
        guard let s = dockScreen, hasNotch else { return CGSize(width: 44, height: 8) }   // the pill it closes into
        let l = s.auxiliaryTopLeftArea?.width ?? 0, r = s.auxiliaryTopRightArea?.width ?? 0
        return CGSize(width: s.frame.width - l - r, height: max(s.safeAreaInsets.top, 24))
    }

    /// Whether the docking screen has a camera notch to grow from.
    private var hasNotch: Bool {
        guard let s = dockScreen else { return false }
        return (s.auxiliaryTopLeftArea?.width ?? 0) > 0 && (s.auxiliaryTopRightArea?.width ?? 0) > 0 && s.safeAreaInsets.top > 0
    }

    /// Without a notch the panel floats this far below the top edge.
    private static let floatGap: CGFloat = 8

    /// Black, flush with the top of the screen (and a little beyond, so no
    /// gap can open), flaring into it with small concave shoulders like the
    /// notch's own, and rounded generously at the bottom.
    /// `open`: 0 at the notch's own size, 1 once it's grown. Closed, the corners and
    /// shoulders are the notch's own, so it starts and ends without bulging past it.
    static func notchPath(width w: CGFloat, height h: CGFloat, open: CGFloat = 1) -> CGPath {
        let o = min(max(open, 0), 1)
        let ear = 4 + 6 * o, r = min(8 + 16 * o, h / 2), top = h + 60
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -ear, y: top))
        p.addLine(to: CGPoint(x: w + ear, y: top))
        p.addLine(to: CGPoint(x: w + ear, y: h))
        p.addQuadCurve(to: CGPoint(x: w, y: h - ear), control: CGPoint(x: w, y: h))
        p.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: 0, y: 0), radius: r)
        p.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: 0, y: h), radius: r)
        p.addLine(to: CGPoint(x: 0, y: h - ear))
        p.addQuadCurve(to: CGPoint(x: -ear, y: h), control: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }

    var isDocked: Bool { dockScreen != nil }

    /// `r` on the device-pixel grid (half points on a Retina screen).
    static func pixelSnapped(_ r: NSRect, scale: CGFloat) -> NSRect {
        func s(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let x = s(r.minX), y = s(r.minY)
        return NSRect(x: x, y: y, width: s(r.maxX) - x, height: s(r.maxY) - y)
    }

    /// The docked panel's size in whole points, its width even so it centres
    /// exactly on the notch: it never shifts by a point as it grows.
    private var dockedSize: CGSize {
        CGSize(width: (size.width / 2).rounded() * 2, height: size.height.rounded())
    }

    /// The answer's display time is up: a floating pane goes, a docked one
    /// stays to be read until its own timer, the next question or Esc.
    func clear() {
        if isDocked { return }
        hide()
    }

    /// The voice reached `word`: light up to it (looking a few words ahead,
    /// since spoken and written forms differ: "3²", "e.g.").
    func spoke(_ word: String) {
        guard voiced, let next = items.firstIndex(where: { !$0.lit }) else { return }
        let w = Self.key(word)
        guard !w.isEmpty else { return }
        let ahead = items[next..<min(items.count, next + 5)]
        let hit = ahead.firstIndex { !$0.key.isEmpty && ($0.key == w || $0.key.hasPrefix(w) || w.hasPrefix($0.key)) } ?? next
        light(upTo: hit)
    }

    /// The sentence has been said: anything left unlit lights now.
    func voiceDone() {
        guard voiced else { return }
        light(upTo: items.count - 1)
    }

    /// The answer is over. From here, moving the mouse well away dismisses it,
    /// even while Navi stays parked by a mark.
    /// Called as each word lights (by index in the sentence): tours move the light with the words.
    var onWordLit: ((Int) -> Void)?

    /// Between answers: the last words stay up, a little dimmer, while the owl
    /// thinks about what's next, instead of switching to "Looking…". False when
    /// there's no answer showing to keep.
    func awaitNext() -> Bool {
        // Closing into the notch: say "Looking…" afresh rather than dim what's going.
        guard placed, !collapsing, style == .answer, !items.isEmpty else { return false }
        endAnswer()
        stopWatching()
        dockTimer?.invalidate()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Look.Motion.base)
        words.opacity = 0.55
        prior.opacity = 0.85   // keeps "Looking…" readable; the earlier lines are faint already
        CATransaction.commit()
        dimmed = true
        setKicker("LOOKING…")
        owl.alphaValue = 1
        return true
    }
    private var dimmed = false

    /// `holdUntilStep`: a lesson step's instruction, kept until the step is taken.
    func answerDone(holdUntilStep: Bool = false) {
        doneTime = Date()
        if holdUntilStep { return }
        if isDocked {
            dockTimer?.invalidate()
            dockTimer = Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { [weak self] _ in
                guard self?.holding == false else { return }
                self?.hide()
            }
            return
        }
        doneAt = NSEvent.mouseLocation
        guard mouseWatch.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) { mouseWatch.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouseMoved(); return e }) { mouseWatch.append(l) }
    }

    private func mouseMoved() {
        guard let at = doneAt, !holding else { return stopWatching() }
        let m = NSEvent.mouseLocation
        // Moving away puts it away, but only once there's been time to read it.
        let readFor = min(8, Double(items.count) / 3 + 1.5)
        guard Date().timeIntervalSince(doneTime) > readFor else { return }
        if hypot(m.x - at.x, m.y - at.y) > 280 { hide() }
    }

    private func stopWatching() {
        mouseWatch.forEach { NSEvent.removeMonitor($0) }
        mouseWatch = []
    }

    private func undock() {
        history = []
        hold = nil
        dockTimer?.invalidate()
        collapsing = false
        collapseWork?.cancel()   // gone already: a late second half mustn't hide what comes next
        collapseWork = nil
        guard dockScreen != nil else { return }
        dockScreen = nil
        glass.alphaValue = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let l = sheen.layer!
        l.backgroundColor = Look.Pane.fill.cgColor
        l.cornerRadius = Self.radius
        l.masksToBounds = true
        l.borderWidth = 1
        topSheen.isHidden = false
        glow.opacity = 1
        notchShape.opacity = 0
        pip.opacity = 0
        words.opacity = 1
        prior.opacity = 1
        shownPrior = ""
        CATransaction.commit()
    }

    func hide() {
        endAnswer()
        endOffer()
        endLink()
        if isDocked, placed, !collapsing {
            // Close back into the notch, then go.
            collapsing = true
            revealTimer?.invalidate()
            dockTimer?.invalidate()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            words.opacity = 0
            prior.opacity = 0
            pip.opacity = 0
            CATransaction.commit()
            targetSize = notchSize
            startTick()
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: work)
            return
        }
        revealTimer?.invalidate()
        revealTimer = nil
        doneAt = nil
        stopWatching()
        if dockScreen != nil { root.alphaValue = 0 }   // already closed into the notch
        undock()
        guard placed else { return }
        placed = false
        shownGen += 1
        let gen = shownGen
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Look.Motion.base
            root.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.shownGen == gen else { return }
            self.panel.orderOut(nil)
            self.items.forEach { $0.layer.removeFromSuperlayer() }
            self.items = []
            self.stopTick()
            self.stopWatchingTheWay()
        })
    }

    /// Navi moved: follow it.
    func nudge() {
        guard placed else { return }
        startTick()
    }

    // MARK: Words

    private static func split(_ text: String) -> [String] { text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
    private static func key(_ w: String) -> String { String(w.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }

    private func set(_ texts: [String], style: Style, voiced: Bool, keys: [String], anchor: NSPoint, fresh: Bool = false) {
        if dimmed {
            dimmed = false
            words.opacity = 1
            prior.opacity = 1
        }
        revealTimer?.invalidate()
        revealTimer = nil
        doneAt = nil
        if collapsing {
            // New words while the docked panel was closing: it opens again and stays.
            collapseWork?.cancel()
            collapseWork = nil
            collapsing = false
            CATransaction.begin()
            CATransaction.setAnimationDuration(Look.Motion.base)
            words.opacity = 1
            prior.opacity = 1
            pip.opacity = 1
            CATransaction.commit()
        }
        self.anchor = anchor
        if style == .answer && fresh && self.style == .answer && !items.isEmpty {
            history.append(items.map(\.text).joined(separator: " "))
        } else if style != .answer {
            history = []
            hold = nil
        }
        let keep = fresh || style != self.style || voiced != self.voiced ? 0 : zip(items, texts).prefix { $0.text == $1 }.count
        for w in items[keep...] { w.layer.removeFromSuperlayer() }
        items.removeLast(items.count - keep)
        self.style = style
        self.voiced = voiced
        for t in texts[keep...] {
            let l = CATextLayer()
            let k = Self.key(t)
            let named = keys.contains { k == $0 || (k.count > 3 && $0.hasPrefix(k)) }
            l.string = t
            l.font = named ? Self.bold : Self.font
            l.fontSize = Self.font.pointSize
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            // A sentence about to be spoken waits as a faint ghost, so the pane is never empty.
            l.opacity = voiced ? Self.ghost : 0
            items.append(Word(text: t, key: k, layer: l, lit: false, named: named, colour: named ? namedColour : nil))
            words.addSublayer(l)
        }
        if style == .listening && items.isEmpty { return set(["Listening…"], style: .listening, voiced: false, keys: [], anchor: anchor) }
        layout()
        updateShimmer()
        appear()
    }

    /// Wraps the words into lines; earlier sentences sit faded above them
    /// (just the last one while floating, all of them in the notch).
    /// This sentence is a practice question: it's their turn to think.
    private var practice = false
    /// What Navi is waiting for, shown above the words ("YOUR MOVE · CLICK EXPORT"); nil for none.
    private var status: String?
    /// The kicker showing now, if any.
    var kicker: String? { status }

    /// Shows what Navi is waiting for above the current words, or clears it.
    func setKicker(_ text: String?) {
        guard status != text else { return }
        status = text
        if placed { layout() }
    }
    /// How they answer it, after "Your turn" ("click it on screen"); nil says nothing more.
    var practiceHow: String?
    private static let kicker: [NSAttributedString.Key: Any] = [
        .font: Look.ui(10.5, .semibold), .kern: 1.1,
        .foregroundColor: NSColor(calibratedRed: 0.94, green: 0.67, blue: 0.37, alpha: 0.95),
        .paragraphStyle: { let p = NSMutableParagraphStyle(); p.paragraphSpacingBefore = 9; return p }(),
    ]

    private func layout() {
        let width = isDocked ? Self.dockWidth : Self.maxWidth
        let space = (" " as NSString).size(withAttributes: [.font: Self.font]).width
        var x: CGFloat = 0, line = 0, widest: CGFloat = 0
        var frames: [CGRect] = []
        for w in items {
            let wd = ceil((w.text as NSString).size(withAttributes: [.font: w.named ? Self.bold : Self.font]).width) + 1
            if x > 0 && x + wd > width { x = 0; line += 1 }
            frames.append(CGRect(x: x, y: CGFloat(line), width: wd, height: Self.lineHeight))
            widest = max(widest, x + wd)
            x += wd + space
        }
        let height = CGFloat(line + 1) * Self.lineHeight
        let earlier = isDocked ? history.suffix(3).joined(separator: "\n") : (history.last ?? "")
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 4
        let priorText = NSMutableAttributedString(string: earlier, attributes: [.font: Self.priorFont, .paragraphStyle: para,
                                                                              .foregroundColor: NSColor.white.withAlphaComponent(0.45)])
        // A small lamp-coloured line above the words says what Navi is waiting for:
        // "Your turn" on a practice question, "Your move" on a lesson step, "Looking…" while it works.
        let kickerLine = practice ? "YOUR TURN" + (practiceHow.map { " · " + $0.uppercased() } ?? "") : status
        if let kickerLine {
            priorText.append(NSAttributedString(string: (earlier.isEmpty ? "" : "\n") + kickerLine, attributes: Self.kicker))
        }
        let hasPrior = !earlier.isEmpty || kickerLine != nil
        let priorSize = !hasPrior ? .zero : priorText.boundingRect(with: CGSize(width: width, height: 2000), options: [.usesLineFragmentOrigin]).size
        priorHeight = !hasPrior ? 0 : ceil(priorSize.height) + 6
        if isDocked { widest = width } else { widest = max(widest, min(width, ceil(priorSize.width))) }
        if isDocked && earlier != shownPrior && !shownPrior.isEmpty && !Buddy.reduceMotion {
            // Earlier lines settle in with a soft crossfade as a new sentence takes the bright line.
            let t = CATransition()
            t.type = .fade
            t.duration = Look.Motion.base
            t.timingFunction = Look.Motion.settle
            prior.add(t, forKey: "slide")
        }
        shownPrior = earlier
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        prior.string = priorText
        prior.isHidden = !hasPrior
        words.frame.size = CGSize(width: widest, height: height)
        for (w, f) in zip(items, frames) {
            w.layer.frame = CGRect(x: f.minX, y: height - (f.minY + 1) * Self.lineHeight, width: f.width, height: f.height)
            w.layer.foregroundColor = colour(for: w).cgColor
        }
        CATransaction.commit()
        if answering { widest = max(widest, AnswerRow.minWidth) }
        if offering { widest = max(widest, OfferRow.minWidth) }
        if linking { widest = max(widest, linkButton.intrinsicContentSize.width) }
        targetSize = CGSize(width: max(widest, 24) + textX + padX,
                            height: topInset + priorHeight + height + bottomPad + (answering ? AnswerRow.height : 0)
                                + (offering ? OfferRow.height : 0) + (linking ? Self.linkHeight : 0))
        if !placed { size = targetSize }
        startTick()
    }

    /// Room at the top: the usual padding, or below the notch when docked.
    private var topInset: CGFloat {
        guard let s = dockScreen else { return Self.pad.height }
        return hasNotch ? s.safeAreaInsets.top + 14 : 16
    }
    /// Where text starts: docked, it leaves room for Navi's light on the left.
    /// The rope from Navi's light to the caption. Off: the caption holds still
    /// on its own while the light moves about (roaming a highlight, say).
    static let showsThread = false

    private var textX: CGFloat { isDocked ? 44 : Self.pad.width + (owlFront ? 24 : 0) }
    /// With nothing to read but a status, the owl leads the line; with an answer it steps back.
    private var owlFront: Bool { style != .answer }
    private var padX: CGFloat { isDocked ? 26 : Self.pad.width }
    private var bottomPad: CGFloat { isDocked ? 20 : Self.pad.height - 2 }

    private func colour(for w: Word) -> NSColor {
        switch style {
        case .listening: return NSColor.white.withAlphaComponent(0.72)
        case .status: return NSColor.white.withAlphaComponent(0.82)
        case .answer: return w.named ? (w.colour ?? tint).blended(withFraction: 0.35, of: Look.warmWhite) ?? tint : Look.warmWhite
        }
    }

    private var tint: NSColor { bloom?()?.tint ?? OverlayView.ink }

    private func startReading() {
        light(upTo: -1)
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: true) { [weak self] t in
            guard let self, let next = self.items.firstIndex(where: { !$0.lit }) else { t.invalidate(); return }
            self.light(upTo: next)
        }
    }

    /// Lights every unlit word up to `last`: each rises a touch and arrives in
    /// Navi's colour, cooling to its own over a moment.
    private func light(upTo last: Int, stagger: Double = 0.035) {
        guard last >= 0 else { return }
        let calm = Buddy.reduceMotion
        let warm = (tint.blended(withFraction: 0.35, of: .white) ?? tint).cgColor
        var n = 0
        for i in 0...min(last, items.count - 1) where !items[i].lit {
            items[i].lit = true
            onWordLit?(i)
            let l = items[i].layer
            let begin = CACurrentMediaTime() + Double(n) * stagger
            n += 1
            // The lit value and its fade-in go in one transaction: committed apart,
            // the word flashes fully lit for a frame before the fade starts.
            CATransaction.begin()
            defer { CATransaction.commit() }
            CATransaction.setDisableActions(true)
            l.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = voiced ? Self.ghost : 0
            fade.toValue = 1
            fade.duration = calm ? 0.1 : 0.22
            fade.beginTime = begin
            fade.fillMode = .backwards
            l.add(fade, forKey: "in")
            guard !calm, style == .answer else { continue }
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -3
            rise.toValue = 0
            rise.duration = Look.Motion.base
            rise.beginTime = begin
            rise.fillMode = .backwards
            rise.timingFunction = Look.Motion.settle
            l.add(rise, forKey: "rise")
            let cool = CABasicAnimation(keyPath: "foregroundColor")
            cool.fromValue = warm
            cool.toValue = colour(for: items[i]).cgColor
            cool.duration = Look.Motion.gentle
            cool.beginTime = begin
            cool.fillMode = .backwards
            l.add(cool, forKey: "cool")
        }
        lastLit = Date()
        if isDocked && n > 0 && !calm {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.55
            pulse.toValue = 1
            pulse.duration = 0.32
            pulse.timingFunction = Look.Motion.settle
            pip.add(pulse, forKey: "word")
        }
    }

    private func updateShimmer() {
        let working = style == .status && items.last?.text.hasSuffix("…") == true && !Buddy.reduceMotion
        guard working else { words.mask = nil; shimmer.removeAllAnimations(); return }
        shimmer.frame = words.bounds.insetBy(dx: -20, dy: 0)
        words.mask = shimmer
        guard shimmer.animation(forKey: "sweep") == nil else { return }
        let a = CABasicAnimation(keyPath: "locations")
        a.fromValue = [-0.6, -0.3, 0]
        a.toValue = [1, 1.3, 1.6]
        a.duration = 1.5
        a.repeatCount = .infinity
        shimmer.add(a, forKey: "sweep")
    }

    // MARK: Placement

    private func appear() {
        guard !placed else { return }
        placed = true
        shownGen += 1
        size = targetSize
        origin = target(for: hold ?? bloomPoint)
        // Arrive from the light: start a few points towards it and settle.
        let b = bloomPoint
        let c = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let d = max(1, hypot(c.x - b.x, c.y - b.y))
        origin.x -= (c.x - b.x) / d * 8
        origin.y -= (c.y - b.y) / d * 8
        velocity = .zero
        frame()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Look.Motion.base
            c.timingFunction = Look.Motion.settle
            root.animator().alphaValue = 1
        }
        startTick()
        watchTheWay()
    }

    // MARK: Out of the way

    /// While the words are up, they step aside for what the user is doing: almost
    /// gone while a menu is open (a menu-bar step drops its menu right where they
    /// sit), and see-through when the pointer comes near. Clicks pass through anyway;
    /// this keeps what's underneath visible.
    private var wayTimer: Timer?
    private var fadedTo: CGFloat = 1
    /// The words first appear right beside where the question was asked: the pointer
    /// only makes them fade once it has been away from them and comes back.
    private var pointerWasAway = false

    private func watchTheWay() {
        pointerWasAway = false
        guard wayTimer == nil else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkTheWay() }
        RunLoop.main.add(t, forMode: .common)
        wayTimer = t
    }

    private func stopWatchingTheWay() {
        wayTimer?.invalidate()
        wayTimer = nil
        fade(to: 1)
    }

    private func checkTheWay() {
        // The answer line takes clicks (Hint, Show me): it never fades from under the pointer.
        guard placed, !holding, !linking, !collapsing else { return fade(to: 1) }
        if Self.menuOpen() { return fade(to: 0.06) }
        let card = NSRect(origin: origin, size: isDocked ? dockedSize : size)
        let near = card.insetBy(dx: -36, dy: -36).contains(NSEvent.mouseLocation)
        if !near { pointerWasAway = true }
        fade(to: near && pointerWasAway ? 0.18 : 1)
    }

    private func fade(to alpha: CGFloat) {
        guard abs(fadedTo - alpha) > 0.01 else { return }
        fadedTo = alpha
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Buddy.reduceMotion ? 0 : (alpha < 1 ? 0.14 : Look.Motion.base)
            panel.animator().alphaValue = alpha
        }
    }

    /// Whether another app has a menu open (a menu bar, context or pop-up menu).
    static func menuOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow)), me = getpid()
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel && ($0[kCGWindowOwnerPID as String] as? pid_t) != me }
    }

    private var bloomPoint: NSPoint { bloom?()?.point ?? NSPoint(x: anchor.x + 22, y: anchor.y - 26) }

    /// Beside Navi, on whichever side keeps it on screen and off the marks
    /// and their labels: hanging down to the right by preference, then above
    /// right, below left, above left. When marks crowd round the light it
    /// steps further out, still tied to it by the thread. It only moves for a
    /// clearly better place, so it doesn't flicker between them.
    private func target(for b: NSPoint) -> NSPoint {
        if let d = dockScreen {
            // Hanging from the top centre, under the notch where there is one.
            return NSPoint(x: d.frame.midX - targetSize.width / 2, y: d.frame.maxY - targetSize.height - (hasNotch ? 0 : Self.floatGap))
        }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(b, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return origin }   // no display for a moment (one being unplugged): stay put
        let f = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let w = targetSize.width, h = targetSize.height
        let marks = keepClear?() ?? []
        func place(_ i: Int) -> NSPoint {
            let side = i % 4, out = CGFloat(i / 4) * 45   // how far beyond the usual gap
            let right = side == 0 || side == 1, below = side == 0 || side == 2
            let x = right ? b.x + Self.gap + out : b.x - Self.gap - w - out
            let y = below ? b.y - 10 - h - out : b.y + 14 + out
            return NSPoint(x: min(max(x, f.minX), f.maxX - w), y: min(max(y, f.minY), f.maxY - h))
        }
        func cost(_ i: Int) -> CGFloat {
            let p = place(i)
            let r = NSRect(origin: p, size: targetSize)
            let covered = marks.reduce(0) { $0 + { $0.isNull ? 0 : $0.width * $0.height }(r.intersection($1.insetBy(dx: -10, dy: -10))) }
            // Clamping onto the screen can drag it over Navi itself; that's as bad as a mark.
            let overNavi: CGFloat = r.insetBy(dx: -6, dy: -6).contains(b) ? w * h : 0
            return covered + overNavi + CGFloat(i % 4) * 30 + CGFloat(i / 4) * 260
        }
        let best = (0..<36).min { cost($0) < cost($1) }!
        if best != corner && cost(best) + 400 < cost(corner) { corner = best }
        return place(corner)
    }

    private func startTick() {
        still = 0
        guard tick == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    private func step() {
        guard placed else { return stopTick() }
        let dt: CGFloat = 1.0 / 60
        let b = bloomPoint
        if let d = dockScreen {
            // Docked: the size springs (opening with a slight overshoot) and the
            // top stays pinned to the screen's edge, centred on the notch.
            let response: CGFloat = 0.5, damping: CGFloat = 0.74
            let k = (2 * .pi / response) * (2 * .pi / response), c = 4 * .pi * damping / response
            if Buddy.reduceMotion { size = targetSize } else {
                sizeVelocity.dx += (k * (targetSize.width - size.width) - c * sizeVelocity.dx) * dt
                sizeVelocity.dy += (k * (targetSize.height - size.height) - c * sizeVelocity.dy) * dt
                size.width += sizeVelocity.dx * dt
                size.height += sizeVelocity.dy * dt
            }
            let settled = abs(targetSize.width - size.width) < 0.3 && abs(targetSize.height - size.height) < 0.3
                && hypot(sizeVelocity.dx, sizeVelocity.dy) < 1
            // Settled means exactly the target: a leftover fraction would round
            // differently on the next resize and nudge the panel a point sideways.
            if settled { size = targetSize; sizeVelocity = .zero }
            let shown = dockedSize
            origin = NSPoint(x: (d.frame.midX - shown.width / 2).rounded(), y: d.frame.maxY - shown.height - (hasNotch ? 0 : Self.floatGap))
            velocity = .zero
            frame()
            still = settled ? still + 1 : 0
            if still > 30 { stopTick() }
            return
        }
        size.width += (targetSize.width - size.width) * 0.25
        size.height += (targetSize.height - size.height) * 0.25
        if abs(targetSize.width - size.width) < 0.5 && abs(targetSize.height - size.height) < 0.5 { size = targetSize }
        let goal = target(for: hold ?? b)
        if Buddy.reduceMotion {
            origin = goal
        } else {
            // Softer than Navi's own spring (0.25 s), so the words trail the light.
            let response: CGFloat = 0.42, damping: CGFloat = 0.85
            let k = (2 * .pi / response) * (2 * .pi / response), c = 4 * .pi * damping / response
            velocity.dx += (k * (goal.x - origin.x) - c * velocity.dx) * dt
            velocity.dy += (k * (goal.y - origin.y) - c * velocity.dy) * dt
            origin.x += velocity.dx * dt
            origin.y += velocity.dy * dt
        }
        frame()
        let settled = hypot(goal.x - origin.x, goal.y - origin.y) < 0.3 && hypot(velocity.dx, velocity.dy) < 1
            && abs(targetSize.height - size.height) < 0.3 && abs(targetSize.width - size.width) < 0.3
            && hypot(b.x - lastNavi.x, b.y - lastNavi.y) < 0.1 && ropeEnergy < 0.03
        lastNavi = b
        still = settled ? still + 1 : 0
        if still > 30 { stopTick() }
    }

    /// Sizes the panel to hold the glass and the light, then lays out the
    /// glass, the light falling on it and the thread between them.
    private func frame() {
        let b = bloomPoint
        // Whole device pixels, so the words never shimmer between two of them.
        let card = Self.pixelSnapped(NSRect(origin: origin, size: isDocked ? dockedSize : size), scale: panel.backingScaleFactor)
        // The window holds just the pane (and Navi's light only when a thread joins them):
        // following the light's drift resized it every frame, and the words shivered.
        // While an offer or answer line takes clicks, the whole window does (transparent margins
        // too): docked, it then stops at the card's top and keeps only the notch's shoulders beside
        // it, so the menu bar around it still gets its clicks.
        let outer = isDocked && holding ? NSRect(x: card.minX - 10, y: card.minY - 24, width: card.width + 20, height: card.height + 24)
            : (isDocked ? card.union(card.offsetBy(dx: 0, dy: 40))
            : Self.showsThread ? card.union(NSRect(x: b.x - 4, y: b.y - 4, width: 8, height: 8)) : card).insetBy(dx: -24, dy: -24)
        if panel.frame != outer { panel.setFrame(outer, display: false) }
        let local = card.offsetBy(dx: -outer.minX, dy: -outer.minY)
        let lb = CGPoint(x: b.x - outer.minX, y: b.y - outer.minY)
        glass.frame = local
        // Never ask CoreGraphics for a corner larger than half the rect: it aborts.
        let cr = min(Self.radius, local.width / 2, local.height / 2)
        glass.layer?.shadowPath = isDocked ? nil : CGPath(roundedRect: CGRect(origin: .zero, size: local.size), cornerWidth: cr, cornerHeight: cr, transform: nil)
        sheen.frame = local
        let c = tint
        let hasNavi = bloom?() != nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The light on the glass: strongest at the corner nearest Navi.
        let reach = Look.Pane.catchRadius * 2
        glow.frame = CGRect(x: lb.x - local.minX - reach / 2, y: lb.y - local.minY - reach / 2, width: reach, height: reach)
        glow.colors = [c.withAlphaComponent(hasNavi ? Look.Pane.catchAlpha : 0.08).cgColor, c.withAlphaComponent(0.05).cgColor, c.withAlphaComponent(0).cgColor]
        let depth = min(Look.Pane.sheenDepth, local.height * 0.6)
        topSheen.frame = CGRect(x: 0, y: local.height - depth, width: local.width, height: depth)
        let top = local.height - topInset + 1
        prior.frame = CGRect(x: textX, y: top - priorHeight, width: local.width - textX - padX, height: priorHeight)
        words.frame.origin = CGPoint(x: textX, y: top - priorHeight - words.frame.height)
        if answering {
            answerRow.frame = NSRect(x: local.minX + textX, y: local.minY + bottomPad - 2,
                                     width: local.width - textX - padX, height: AnswerRow.height)
        }
        if offering {
            offerRow.frame = NSRect(x: local.minX + textX, y: local.minY + bottomPad - 2 + (answering ? AnswerRow.height : 0),
                                    width: local.width - textX - padX, height: OfferRow.height)
        }
        if linking {
            let w = linkButton.intrinsicContentSize.width
            linkButton.frame = NSRect(x: local.minX + textX - 2, y: local.minY + bottomPad - 4 + (answering ? AnswerRow.height : 0)
                                        + (offering ? OfferRow.height : 0), width: w, height: Self.linkHeight)
        }
        let os = owl.intrinsicContentSize
        owl.tucked = !owlFront
        if owlFront {
            owl.frame = NSRect(x: textX - 24, y: words.frame.maxY - Self.lineHeight / 2 - os.height / 2, width: os.width, height: os.height)
        } else if isDocked {
            owl.frame = NSRect(x: textX - 26, y: top - os.height - 3, width: os.width, height: os.height)
        } else {
            owl.frame = NSRect(x: 5, y: local.height - os.height - 4, width: os.width, height: os.height)
        }
        if isDocked {
            let opened = (local.height - notchSize.height) / 50
            notchShape.path = hasNotch ? Self.notchPath(width: local.width, height: local.height, open: opened)
                : { let r = min(18, local.width / 2, local.height / 2)
                    return CGPath(roundedRect: CGRect(origin: .zero, size: local.size), cornerWidth: r, cornerHeight: r, transform: nil) }()
            pip.position = CGPoint(x: textX - 15, y: words.frame.maxY - Self.lineHeight / 2)
            pip.backgroundColor = c.cgColor
            pip.shadowColor = c.cgColor
        }
        if words.mask != nil { shimmer.frame = words.bounds.insetBy(dx: -20, dy: 0) }

        // The thread: from the light to the nearest point on the pane. Its attach point
        // slides smoothly along the edge, and the rope between trails and settles.
        let r = Self.radius
        let end = CGPoint(x: min(max(lb.x, local.minX + r), local.maxX - r), y: min(max(lb.y, local.minY + r * 0.6), local.maxY - r * 0.6))
        let attachLocal = CGPoint(x: lb.x < local.minX ? local.minX + 1 : lb.x > local.maxX ? local.maxX - 1 : end.x,
                                  y: lb.y < local.minY ? local.minY + 1 : lb.y > local.maxY ? local.maxY - 1 : end.y)
        let attachGoal = NSPoint(x: attachLocal.x + outer.minX, y: attachLocal.y + outer.minY)
        let d = hypot(attachLocal.x - lb.x, attachLocal.y - lb.y)
        if Self.showsThread, hasNavi, d > 9, !isDocked {
            let attach: NSPoint
            if let a = ropeAttach, !rope.isEmpty {
                attach = NSPoint(x: a.x + (attachGoal.x - a.x) * 0.3, y: a.y + (attachGoal.y - a.y) * 0.3)
            } else { attach = attachGoal }
            ropeAttach = attach
            stepRope(from: b, to: attach)
            let pts = rope.map { CGPoint(x: $0.x - outer.minX, y: $0.y - outer.minY) }
            thread.frame = CGRect(origin: .zero, size: outer.size)
            thread.path = Self.ribbon(through: pts)
            thread.fillColor = c.withAlphaComponent(0.7).cgColor
            thread.shadowColor = c.cgColor
            thread.opacity = Float(min(1, (d - 9) / 18))
            threadFade.frame = thread.bounds
            let w = max(outer.width, 1), h = max(outer.height, 1)
            threadFade.startPoint = CGPoint(x: lb.x / w, y: lb.y / h)
            threadFade.endPoint = CGPoint(x: (attach.x - outer.minX) / w, y: (attach.y - outer.minY) / h)
        } else {
            thread.opacity = 0
            rope = []
            ropeAttach = nil
            ropeEnergy = 0
        }
        CATransaction.commit()
    }

    /// One step of the rope: Verlet points with a little gravity and damping,
    /// pinned at the light and the pane. It's slightly longer than the gap, so
    /// it hangs in a soft curve, trails when the light moves, and settles.
    private func stepRope(from a: NSPoint, to b: NSPoint) {
        let n = 14
        if rope.count != n {
            rope = (0..<n).map { i in let t = CGFloat(i) / CGFloat(n - 1); return NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
            ropePrev = rope
        }
        let d = hypot(b.x - a.x, b.y - a.y)
        let rest = (d + min(d * 0.04, 10)) / CGFloat(n - 1)
        let calm = Buddy.reduceMotion
        var energy: CGFloat = 0
        for i in 1..<(n - 1) {
            let vx = (rope[i].x - ropePrev[i].x) * 0.8, vy = (rope[i].y - ropePrev[i].y) * 0.8
            ropePrev[i] = rope[i]
            rope[i].x += calm ? 0 : vx
            rope[i].y += (calm ? 0 : vy) - 0.16          // a touch of gravity
            energy = max(energy, abs(vx) + abs(vy))
        }
        rope[0] = a
        rope[n - 1] = b
        for _ in 0..<10 {
            for i in 0..<(n - 1) {
                let dx = rope[i + 1].x - rope[i].x, dy = rope[i + 1].y - rope[i].y
                let len = hypot(dx, dy)
                guard len > rest, len > 0 else { continue }   // a rope only pulls; slack hangs
                let k = (len - rest) / len
                let firstFixed = i == 0, lastFixed = i + 1 == n - 1
                let share: CGFloat = firstFixed || lastFixed ? 1 : 0.5
                if !firstFixed { rope[i].x += dx * k * share; rope[i].y += dy * k * share }
                if !lastFixed { rope[i + 1].x -= dx * k * share; rope[i + 1].y -= dy * k * share }
            }
        }
        ropeEnergy = energy
    }

    /// A smooth ribbon through the rope's points (Catmull–Rom), tapering from
    /// the light (1.9 pt) to the pane (0.6 pt).
    private static func ribbon(through pts: [CGPoint]) -> CGPath {
        guard pts.count > 1 else { return CGMutablePath() }
        var smooth: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            for s in 0..<4 {
                let t = CGFloat(s) / 4, t2 = t * t, t3 = t2 * t
                func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                smooth.append(CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        smooth.append(pts[pts.count - 1])
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (i, p) in smooth.enumerated() {
            let a = smooth[max(i - 1, 0)], b = smooth[min(i + 1, smooth.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y, len = max(0.001, hypot(dx, dy))
            let t = CGFloat(i) / CGFloat(smooth.count - 1)
            let w = (1.9 - 1.3 * t) / 2
            left.append(CGPoint(x: p.x - dy / len * w, y: p.y + dx / len * w))
            right.append(CGPoint(x: p.x + dy / len * w, y: p.y - dx / len * w))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        // A rounded end at the light, so it reads as tied to it.
        if let first = smooth.first { path.addEllipse(in: CGRect(x: first.x - 1.1, y: first.y - 1.1, width: 2.2, height: 2.2)) }
        return path
    }
}

#if DEBUG
/// What the stress test checks.
extension Caption {
    struct Snapshot {
        let shown: Bool, alpha: CGFloat, frame: NSRect, words: [String], lit: Int
        let bloom: NSPoint?, ticking: Bool, threadOpacity: Float, settled: Bool
    }
    var snapshot: Snapshot {
        Snapshot(shown: placed && panel.isVisible, alpha: root.alphaValue, frame: NSRect(origin: origin, size: size),
                 words: items.map(\.text), lit: items.filter(\.lit).count, bloom: bloom?()?.point, ticking: tick != nil,
                 threadOpacity: thread.opacity, settled: hypot(velocity.dx, velocity.dy) < 1)
    }
}
#endif

/// The small link under the caption's words: soft text that lights to lamp colour under the pointer.
final class LinkButton: NSButton {
    private var hovering = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String) {
        title = text
        refresh()
        setAccessibilityLabel(text)
    }

    private func refresh() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Look.ui(12, .medium),
            .foregroundColor: hovering ? Buddy.lamp : Look.softText,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: (hovering ? Buddy.lamp : Look.softText).withAlphaComponent(0.5)])
    }

    override var intrinsicContentSize: NSSize {
        let s = attributedTitle.size()
        return NSSize(width: ceil(s.width) + 6, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
}
