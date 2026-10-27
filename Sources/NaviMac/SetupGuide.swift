import AppKit
import AVFoundation
import Speech

/// Setup, taught the way Navi teaches anything: a caption-style pane docked beside
/// System Settings, one sentence at a time with the thing to do lit in step green,
/// Navi's light and pen showing the way on Settings itself, and an ink tick as each
/// step lands. It notices each permission by itself and moves on; it remembers
/// where it got to across a reopen (it just asks macOS again).
final class SetupGuide: NSPanel {
    enum Step: Int, CaseIterable {
        case clicks, screen, claude, voice

        var title: String {
            switch self {
            case .clicks: "Accessibility"
            case .screen: "Screen Recording"
            case .claude: "Claude"
            case .voice: "Microphone · optional"
            }
        }
        var permission: OnboardingWindow.Permission? {
            switch self {
            case .clicks: OnboardingWindow.permissions.first { $0.pane == "Privacy_Accessibility" }
            case .screen: OnboardingWindow.permissions.first { $0.pane == "Privacy_ScreenCapture" }
            case .claude: nil
            case .voice: OnboardingWindow.permissions.first { $0.pane == "Privacy_Microphone" }
            }
        }
        /// Asking and being told, for the step's sentence: (before the lit words, lit, after).
        var ask: (String, String, String) {
            switch self {
            case .clicks: ("First, switch me on in ", "Accessibility", ", so I notice your clicks in lessons.")
            case .screen: ("Now drag me into ", "Screen Recording", " and switch me on, so I can see what you see.")
            case .claude: ("Let's connect ", "Claude", ": your Claude Code sign-in, or an API key.")
            case .voice: ("Want to talk to me too? Turn on the ", "Microphone", ", or skip it for now.")
            }
        }
        var done: String {
            switch self {
            case .clicks: "Clicks: on."
            case .screen: "I can see your screen now."
            case .claude: "Claude is connected."
            case .voice: "I can hear you now."
            }
        }
        static let required: [Step] = [.clicks, .screen, .claude]
    }

    var onDone: (() -> Void)?
    /// Opens the connection choices (Claude Code or a key), for the Claude step.
    var onConnect: (() -> Void)?
    /// Navi's light and pen: where to fly, what to ring and point at (global AppKit points).
    var light: ((NSPoint?) -> Void)?
    var marks: ((_ ring: NSRect?, _ arrow: (NSPoint, NSPoint)?, _ note: String?) -> Void)?

    private var current: Step?
    private var skippedVoice = false
    private var dropped = false
    private var ringed = false
    private var looks = 0
    private var ticks = 0
    /// Screen Recording: where Navi's switch is, when it went into the list, and whether
    /// the guide is now offering to reopen (macOS applies the switch only after a restart).
    private var switchRect: NSRect?
    private var droppedAt: Date?
    private var offeringReopen = false
    private var timer: Timer?
    private var finished = false

    private let kicker = NSTextField(labelWithString: "")
    private let words = NSTextField(wrappingLabelWithString: "")
    private let prior = NSTextField(wrappingLabelWithString: "")
    private var rows: [Step: (mark: StepMark, label: NSTextField)] = [:]
    private let later = InkButton("Later", target: nil, action: nil)
    private let main = InkButton("Open Settings", role: .primary, target: nil, action: nil)
    private static let width: CGFloat = 288
    static let stepGreen = NSColor(calibratedRed: 51 / 255, green: 184 / 255, blue: 158 / 255, alpha: 1)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300), styleMask: [.borderless, .nonactivatingPanel],
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

    override var canBecomeKey: Bool { true }

    // MARK: Layout

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let owl = OwlView(pixel: 1.4)
        kicker.font = Look.ui(10.5, .semibold)
        kicker.textColor = Look.faintText
        let head = NSStackView(views: [owl, kicker])
        head.spacing = 8
        head.alignment = .centerY
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(9, after: head)

        for (label, size, colour) in [(prior, 13.0, Look.faintText), (words, 15.5, Look.warmWhite)] {
            label.font = Look.ui(size, label === words ? .medium : .regular)
            label.textColor = colour
            label.preferredMaxLayoutWidth = Self.width - 32
            label.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
            stack.addArrangedSubview(label)
        }
        stack.setCustomSpacing(3, after: prior)
        stack.setCustomSpacing(14, after: words)

        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = NSColor.white.withAlphaComponent(0.07)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rule.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        stack.addArrangedSubview(rule)
        stack.setCustomSpacing(8, after: rule)

        for step in Step.allCases {
            let mark = StepMark()
            let label = NSTextField(labelWithString: step.title)
            label.font = Look.ui(12.5, .medium)
            let row = NSStackView(views: [mark, label])
            row.spacing = 9
            row.alignment = .centerY
            row.heightAnchor.constraint(equalToConstant: 24).isActive = true
            stack.addArrangedSubview(row)
            rows[step] = (mark, label)
        }

        later.target = self
        later.action = #selector(laterPressed)
        main.target = self
        main.action = #selector(mainPressed)
        let footer = NSStackView(views: [NSView(), later, main])
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(footer)

        let size = stack.fittingSize
        let (outer, content) = Glass.make(size: NSSize(width: Self.width, height: size.height), radius: 18)
        // Nearly opaque: it sits over whatever's open for minutes at a time, unlike a caption.
        content.layer?.backgroundColor = Look.Pane.fill.withAlphaComponent(0.985).cgColor
        stack.frame = content.bounds
        stack.autoresizingMask = [.width, .height]
        content.addSubview(stack)
        contentView = outer
        setContentSize(NSSize(width: Self.width, height: size.height))
    }

    private func fit() {
        guard let outer = contentView, let content = outer.subviews.first, let stack = content.subviews.first else { return }
        stack.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height
        guard abs(h - frame.height) > 0.5 else { return }
        var f = frame
        f.origin.y += f.height - h
        f.size.height = h
        setFrame(f, display: true)
    }

    // MARK: Flow

    static func isDone(_ step: Step) -> Bool {
        switch step {
        case .claude: MainActor.assumeIsolated { Connection.shared.activeProblem == nil && Connection.shared.claudeCode != .checking }
        default: step.permission?.granted() ?? true
        }
    }

    /// Claude Code isn't installed or isn't signed in, and there's no working key: one button does it.
    static var oneClickClaude: Bool {
        MainActor.assumeIsolated {
            if case .problem(let p, _) = Connection.shared.claudeCode, [.notInstalled, .notSignedIn, .signInExpired].contains(p) {
                if case .ready = Connection.shared.apiKey { return false }
                return true
            }
            return false
        }
    }

    private var claudeChecking: Bool { MainActor.assumeIsolated { Connection.shared.claudeCode == .checking } }

    static var needed: Bool { Step.required.contains { !isDone($0) } }

    func present() {
        finished = false
        for step in Step.allCases where Self.isDone(step) { rows[step]?.mark.state = .done(animated: false) }
        move()
        dock()
        orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// The first step still to do (the optional voice step last, once, unless skipped).
    private func next() -> Step? {
        if let s = Step.required.first(where: { !Self.isDone($0) }) { return s }
        return !skippedVoice && !Self.isDone(.voice) ? .voice : nil
    }

    private func move() {
        let before = current
        current = next()
        dropped = false
        ringed = false
        switchRect = nil
        droppedAt = nil
        offeringReopen = false
        marks?(nil, nil, nil)
        DragTile.hide()
        for step in Step.allCases {
            guard let row = rows[step] else { continue }
            let done = Self.isDone(step) || (step == .voice && skippedVoice)
            if done { if case .done = row.mark.state {} else { row.mark.state = .done(animated: true) } }
            else { row.mark.state = step == current ? .now : .waiting }
            row.label.textColor = step == current ? Look.warmWhite : done ? Look.softText : Look.faintText
        }
        if let before, before != current, Self.isDone(before) {
            Owl.shared.react(.happy)
            prior.stringValue = before.done
        }
        guard let step = current else { return finish() }
        let n = (Step.required.firstIndex(of: step) ?? Step.required.count - 1) + 1
        kicker.attributedStringValue = Self.kick(step == .voice ? "SETTING UP · LAST ONE" : "SETTING UP · \(n) OF \(Step.required.count)")
        say(step.ask)
        later.title = step == .voice ? "Skip" : "Later"
        main.title = step == .claude ? (Self.oneClickClaude ? "Connect Claude" : "Choose…") : step == .voice ? "Turn on" : "Open Settings"
        if step == .claude, claudeChecking { main.title = "Checking…" }
        if step == .claude, Self.oneClickClaude, !claudeChecking {
            say(("Let's connect ", "Claude", ". I'll install what's needed, then your browser opens so you can sign in."))
        }
        fit()
        light?(nil)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        kicker.attributedStringValue = Self.kick("ALL SET")
        words.attributedStringValue = Self.sentence(("Tap ", Settings.shared.hotkeyLabel, " and ask me anything. Drop slides or notes on the ask bar and I'll use them too."))
        later.isHidden = true
        main.title = "Done"
        fit()
        Owl.shared.react(.proud, for: 2)
        marks?(nil, nil, nil)
        light?(nil)
        Settings.shared.onboarded = true
        LoginItem.setupFinished()
        trace("Setup: all set.")
    }

    private func tick() {
        dock()
        guard let step = current else { return }
        if Self.isDone(step) { trace("Setup: \(step) done."); return move() }
        ticks += 1
        // The Claude step depends on what's done in Terminal or a browser, and this pane
        // never makes Navi active (so nothing else looks again): look every 4 seconds.
        if step == .claude, ticks % 8 == 0 { MainActor.assumeIsolated { Connection.shared.refresh() } }
        if step == .claude, main.title == "Checking…", !claudeChecking { move() }
        guard step == .screen else { return }
        // Screen Recording only applies after a restart: once the switch reads on (or a
        // while after the drop, in case it can't be read), offer to reopen.
        if !offeringReopen, ticks % 2 == 0 {
            if let r = switchRect, Self.switchIsOn(at: r) == true { return offerReopen(switchOn: true) }
            if let d = droppedAt, Date().timeIntervalSince(d) > 20 { return offerReopen(switchOn: false) }
        }
        guard dropped, !ringed else { return }
        // Dropped in: ring Navi's switch in the list so it's obvious what's left. (The
        // search walks Settings' window, so not every tick.)
        looks += 1
        guard looks % 3 == 1, let sw = AX.settingsSwitch(named: "Navi") else { return }
        ringed = true
        switchRect = sw
        marks?(sw, nil, nil)
        light?(NSPoint(x: sw.maxX, y: sw.midY))
    }

    private func offerReopen(switchOn: Bool) {
        offeringReopen = true
        trace("Setup: offering to reopen for Screen Recording (switch \(switchOn ? "reads on" : "not read")).")
        prior.stringValue = switchOn ? "My switch is on." : "Navi is in the list."
        say(switchOn ? ("macOS applies it once I restart: ", "reopen me", ".")
                     : ("Once my switch is on, ", "reopen me", " so macOS applies it."))
        main.title = "Reopen Navi"
        fit()
    }

    /// Whether the switch at `rect` (global AppKit points) in System Settings reads on;
    /// nil if what's there can't be read as a switch.
    private static func switchIsOn(at rect: NSRect) -> Bool? {
        guard let top = NSScreen.screens.first?.frame.maxY else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(rect.midX), Float(top - rect.midY), &found) == .success,
              var el = found else { return nil }
        let toggles: Set<String> = [kAXCheckBoxRole, "AXSwitch", "AXToggle"]
        for _ in 0..<2 {
            var role: CFTypeRef?, value: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
               let r = role as? String, toggles.contains(r),
               AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
               let n = value as? NSNumber {
                return n.intValue == 1
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
            el = p as! AXUIElement
        }
        return nil
    }

    @objc private func mainPressed() {
        guard let step = current else { orderOut(nil); timer?.invalidate(); onDone?(); return }
        if step == .screen, offeringReopen {
            trace("Setup: reopening so Screen Recording applies.")
            return Relocation.relaunch(Bundle.main.bundleURL)
        }
        switch step {
        case .claude:
            guard Self.oneClickClaude, !ConnectClaude.running else { onConnect?(); return }
            main.isEnabled = false
            later.isHidden = true
            ConnectClaude.run(stage: { [weak self] s in
                guard let self else { return }
                self.main.title = s == .installing ? "Installing…" : "Waiting for your browser…"
                self.say(s == .installing ? ("Installing ", "Claude Code", " from claude.ai. About a minute.")
                                          : ("Now sign in with your ", "Claude account", " in your browser, then come back."))
                self.fit()
            }, done: { [weak self] problem in
                guard let self else { return }
                self.main.isEnabled = true
                self.later.isHidden = false
                if let problem {
                    self.prior.stringValue = problem
                    self.main.title = "Other ways…"
                    self.fit()
                } else {
                    self.move()
                }
            })
        case .voice:
            NSApp.activate(ignoringOtherApps: true)
            OnboardingWindow.permissions.filter { $0.pane == "Privacy_Microphone" || $0.pane == "Privacy_SpeechRecognition" }.forEach { $0.ask() }
        default:
            guard let p = step.permission else { return }
            // From a click, with Navi in front: macOS only shows its prompt then.
            NSApp.activate(ignoringOtherApps: true)
            p.ask()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(p.pane)") { NSWorkspace.shared.open(url) }
            if step == .screen { showTile() }
            for delay in [0.6, 1.4] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pointAtSettings() } }
        }
    }

    @objc private func laterPressed() {
        if current == .voice { skippedVoice = true; return move() }
        timer?.invalidate()
        marks?(nil, nil, nil)
        light?(nil)
        DragTile.hide()
        orderOut(nil)
        trace("Setup: later (it opens again next launch).")
    }

    override func close() {
        timer?.invalidate()
        DragTile.hide()
        super.close()
    }

    // MARK: Showing the way

    private func showTile() {
        DragTile.show(above: frame) { [weak self] in
            self?.dropped = true
            self?.droppedAt = Date()
            self?.prior.stringValue = "Navi is in the list. macOS asks to reopen me once it's on."
            self?.say(("That's me. Now flip ", "my switch", "."))
            self?.marks?(nil, nil, nil)
        }
    }

    /// The light flies to Settings and the pen draws the way: for Screen Recording, an
    /// arrow from the tile into the list; otherwise a ring round Navi's switch.
    private func pointAtSettings() {
        guard let step = current, let s = DragTile.settingsFrame() else { return }
        if step == .screen, !dropped, let tile = DragTile.frame {
            let to = NSPoint(x: s.minX + s.width * 0.62, y: s.maxY - s.height * 0.42)
            let from = NSPoint(x: tile.minX - 6, y: tile.midY)
            marks?(nil, (from, to), "drop me here")
            light?(to)
        } else if let sw = AX.settingsSwitch(named: "Navi") {
            if step == .screen { switchRect = sw }
            marks?(sw, nil, nil)
            light?(NSPoint(x: sw.maxX, y: sw.midY))
        }
    }

    /// Beside System Settings while it's open (to its right, else its left);
    /// otherwise wherever it was left.
    private func dock() {
        guard let s = DragTile.settingsFrame(), let screen = NSScreen.screens.first(where: { $0.frame.intersects(s) }) ?? NSScreen.main else {
            // Top right, under the menu bar: clear of macOS's own prompts in the middle.
            if !isVisible || frame.origin == .zero, let v = NSScreen.main?.visibleFrame {
                setFrameOrigin(NSPoint(x: v.maxX - frame.width - 20, y: v.maxY - frame.height - 20))
            }
            return
        }
        let v = screen.visibleFrame
        let x = s.maxX + 14 + frame.width <= v.maxX ? s.maxX + 14 : max(v.minX + 8, s.minX - 14 - frame.width)
        let y = min(v.maxY - frame.height - 8, s.maxY - frame.height - 120)
        let target = NSPoint(x: x, y: max(v.minY + 8, y))
        if hypot(frame.minX - target.x, frame.minY - target.y) > 1 { setFrameOrigin(target) }
        DragTile.follow(above: frame)
    }

    // MARK: Words

    private func say(_ s: (String, String, String)) {
        words.attributedStringValue = Self.sentence(s)
        // The lit words cool after a moment, keeping a touch of their colour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.words.attributedStringValue.string == Self.sentence(s).string else { return }
            self.words.attributedStringValue = Self.sentence(s, cool: true)
        }
        fit()
    }

    static func sentence(_ s: (String, String, String), cool: Bool = false) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: Look.ui(15.5, .medium), .foregroundColor: Look.warmWhite]
        let out = NSMutableAttributedString(string: s.0, attributes: base)
        var lit = base
        lit[.foregroundColor] = cool ? stepGreen.blended(withFraction: 0.35, of: Look.warmWhite) ?? stepGreen : stepGreen
        if !cool {
            let glow = NSShadow()
            glow.shadowColor = stepGreen.withAlphaComponent(0.6)
            glow.shadowBlurRadius = 8
            lit[.shadow] = glow
        }
        out.append(NSAttributedString(string: s.1, attributes: lit))
        out.append(NSAttributedString(string: s.2, attributes: base))
        return out
    }

    private static func kick(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Look.ui(10.5, .semibold), .foregroundColor: Look.faintText, .kern: 1.3])
    }
}

/// A step's mark: a faint ring while it waits, Navi's light while it's the one to
/// do, and a tick written in ink once it's done (ink is what stays).
private final class StepMark: NSView {
    enum State: Equatable { case waiting, now, done(animated: Bool) }
    var state: State = .waiting { didSet { if state != oldValue { redraw() } } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        redraw()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func redraw() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let l = CAShapeLayer()
        l.frame = bounds
        switch state {
        case .waiting:
            l.path = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 10, height: 10), transform: nil)
            l.fillColor = nil
            l.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
            l.lineWidth = 1.2
        case .now:
            l.path = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 10, height: 10), transform: nil)
            l.fillColor = Buddy.lamp.cgColor
            l.shadowColor = OverlayView.ink.cgColor
            l.shadowOpacity = 1
            l.shadowRadius = 4
            l.shadowOffset = .zero
            if !Buddy.reduceMotion {
                let breathe = CABasicAnimation(keyPath: "shadowRadius")
                breathe.fromValue = 3
                breathe.toValue = 7
                breathe.duration = Look.Breath.period * 2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                l.add(breathe, forKey: "breathe")
            }
        case .done(let animated):
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 3.5, y: 9))
            p.addLine(to: CGPoint(x: 7.5, y: 5))
            p.addLine(to: CGPoint(x: 15, y: 13.5))
            l.path = p
            l.fillColor = nil
            l.strokeColor = OverlayView.ink.cgColor
            l.lineWidth = 2.6
            l.lineCap = .round
            l.lineJoin = .round
            if animated, !Buddy.reduceMotion {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.duration = 0.4
                l.add(draw, forKey: "write")
            }
        }
        layer?.addSublayer(l)
    }
}
