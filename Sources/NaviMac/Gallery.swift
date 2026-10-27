#if DEBUG
import AppKit

/// The polish reel: `Navi --gallery <out-dir>`.
///
/// Covers the main display with a calm mock app and plays every state of
/// Navi and its marks in order (resting, listening, thinking, pointing,
/// explaining into the notch, a lesson step, a hover step, an error), with
/// canned replies. It records the display to `reel.mov` and saves a still
/// at each key moment, so each round of polish is judged on the same footage.
@MainActor
final class Gallery {
    private let app: AppController
    private let out: URL
    private var backdrop: NSWindow?
    private var mock: MockApp?
    private var recorder: Process?
    private var stills = 0
    /// Real replies from `--practice-check`, played instead of the canned ones (`--live <replies.json>`).
    private let live: [String: String] = {
        guard let i = CommandLine.arguments.firstIndex(of: "--live"), CommandLine.arguments.count > i + 1,
              let d = FileManager.default.contents(atPath: CommandLine.arguments[i + 1]) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: String] ?? [:]
    }()

    init(app: AppController, out: String) {
        self.app = app
        self.out = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: self.out, withIntermediateDirectories: true)
    }

    func run() async {
        guard ScreenTakeover.confirm("Run the gallery?", takes: "about 5 minutes",
                                     doing: "it covers the main display with a mock app, plays every state of Navi and records it.") else { exit(0) }
        let saved = (Settings.shared.showInRecordings, Settings.shared.buddy)
        Settings.shared.showInRecordings = true
        app.applySharing()
        app.setBuddy(true)
        let screen = NSScreen.screens[0]
        let home = NSEvent.mouseLocation
        showBackdrop(on: screen)
        move(to: point(0.5, 0.7))
        await wait(1)
        record(seconds: CommandLine.arguments.contains("--only") ? 300 : 300)
        await wait(1)

        await scene("Resting, then following the pointer") {
            await self.wait(1.2)
            for i in 0...40 {
                let t = Double(i) / 40
                self.move(to: self.point(0.3 + 0.4 * t, 0.7 - 0.25 * sin(t * .pi)))
                await self.wait(0.03)
            }
            await self.wait(1)
            self.still("resting")
        }
        await scene("Listening") {
            self.app.testBuddy.set(.listening)
            let words = "where do I change the export format".split(separator: " ")
            for i in 1...words.count {
                self.app.testCaption.show(words.prefix(i).joined(separator: " "), style: .listening, at: NSEvent.mouseLocation)
                await self.wait(0.25)
            }
            await self.wait(0.6)
            self.still("listening")
        }
        await scene("Thinking") {
            self.app.testBuddy.set(.thinking)
            self.app.testCaption.show("Looking…", style: .status, at: NSEvent.mouseLocation)
            await self.wait(1.2)
            self.still("thinking")
            await self.wait(1)
            self.app.testCaption.hide()
            self.app.testBuddy.set(.idle)
        }
        await scene("Pointing, spoken") {
            guard let m = self.mock else { return }
            self.ask("[POINT:\(self.px(self.mid(m.export))):Export:screen1] The Export button saves a copy in the format you pick.", voice: true)
            await self.wait(2.6)
            self.still("pointing")
            await self.waitUntil(10) { !self.app.testSpeaking }
            await self.wait(1)
        }
        await scene("Explaining, typed: builds up, then moves into the notch") {
            guard let m = self.mock else { return }
            let a = m.triangle[0], b = m.triangle[1], c = m.triangle[2]
            let reply = [
                "[SHAPE:polygon:\(self.px(a));\(self.px(b));\(self.px(c)):triangle:screen1] This is a right triangle, so Pythagoras applies.",
                "[SHAPE:circle:\(self.px(b));\(self.px(NSPoint(x: b.x + 18, y: b.y))):right angle:screen1] The square corner is the right angle.",
                "[SHAPE:arrow:\(self.px(NSPoint(x: c.x + 70, y: c.y - 10)));\(self.px(NSPoint(x: (a.x + c.x) / 2 + 12, y: (a.y + c.y) / 2 + 8))):hypotenuse c:screen1] The long side opposite it is the hypotenuse, c.",
                "[SHAPE:line:\(self.px(NSPoint(x: a.x, y: a.y - 12)));\(self.px(NSPoint(x: b.x, y: b.y - 12))):leg a:screen1] The two shorter sides are the legs, a and b.",
                "[WRITE:\(self.px(NSPoint(x: b.x + 40, y: c.y - 6))):a² + b² = c²:screen1] Square both legs and add them.",
                "[WRITE:\(self.px(NSPoint(x: b.x + 40, y: c.y - 6))):3² + 4² = c²:screen1] Here the legs are 3 and 4.",
                "[WRITE:\(self.px(NSPoint(x: b.x + 40, y: c.y - 6))):9 + 16 = c²:screen1] Three squared is 9, four squared is 16.",
                "[WRITE:\(self.px(NSPoint(x: b.x + 40, y: c.y - 6))):25 = c²:screen1] Together that's 25.",
                "[WRITE:\(self.px(NSPoint(x: b.x + 40, y: c.y - 46))):so c = 5:screen1] With legs of 3 and 4, the long side is 5.",
            ].joined(separator: "\n")
            self.ask(reply, question: "explain pythagoras")
            await self.waitUntil(12) { self.app.testCaption.snapshot.words.contains("corner") }
            self.still("explaining-floating")
            await self.waitUntil(20) { self.app.testCaption.isDocked }
            await self.wait(1.5)
            self.still("explaining-docked")
            await self.waitUntil(30) { self.app.testCaption.snapshot.words.contains("5.") }
            await self.wait(3)
            self.still("explaining-end")
        }
        await scene("A lesson step") {
            guard let m = self.mock else { return }
            self.ask("[TARGET:\(self.px(self.mid(m.field))),40:file name:screen1] Click the file name field to rename the export.")
            await self.wait(3.5)
            self.still("lesson-target")
            await self.wait(1.5)
        }
        await scene("A hover step") {
            guard let m = self.mock else { return }
            self.ask("[HOVER:\(self.px(self.mid(m.formatMenu))),36:Format menu:screen1] Rest the pointer on Format to see the options.")
            await self.wait(3.5)
            self.still("lesson-hover")
            await self.wait(1)
        }
        // Practice moves: one scene each, after a one-line explanation, as they'd really arrive.
        await practice("predict") { m, at in
            "[SHAPE:polygon:\(m.tri):triangle:screen1] Legs of 3 and 4 give a long side of 5.\n"
            + "[TRY:predict] [WRITE:\(at(0)):6² + 8² = ?:screen1] Before working it out: if both legs doubled, what do you think happens to the long side?"
        }
        await practice("your turn") { m, at in
            "[WRITE:\(at(0)):a² + b² = c²:screen1] Square the legs, add them, then take the square root.\n"
            + "[TRY:your turn] [WRITE:\(at(1)):5² + 12² = c²:screen1] Your turn: with legs of 5 and 12, what's c?"
        }
        await scene("Practice: point (a miss, a hint, then the answer)") {
            guard let m = self.mock else { return }
            let t = m.triangle, hyp = NSPoint(x: (t[0].x + t[2].x) / 2, y: (t[0].y + t[2].y) / 2)
            let leg = NSPoint(x: (t[0].x + t[1].x) / 2, y: t[0].y)
            let quiz = "[QUIZ:\(self.px(hyp)),70:hypotenuse:screen1]"
            self.ask(self.live["point"] ?? "[SHAPE:polygon:\(self.tri(m)):triangle:screen1] This is a right triangle.\n"
                     + "[TRY:point] \(quiz) Which side is the hypotenuse? Click it.", question: "explain pythagoras")
            if self.live["point"] != nil {
                // Claude's own question: just show it.
                await self.waitUntil(30) { self.app.testArmed }
                await self.wait(2.5)
                self.still("practice-point-ask")
                return
            }
            await self.waitUntil(15) { self.app.testArmed }
            await self.wait(1.5)
            self.still("practice-point-ask")
            self.app.fake = FakeBackend(reply: "[SHAPE:circle:\(self.px(t[1]));\(self.px(NSPoint(x: t[1].x + 22, y: t[1].y))):right angle:screen1] Close, but that one touches the square corner. "
                                        + "The hypotenuse is across from it.\n\(quiz) Try again.")
            self.move(to: leg)
            await self.wait(0.4)
            self.app.testClick(at: leg)
            await self.waitUntil(15) { self.app.testArmed }
            await self.wait(2.5)
            self.still("practice-point-hint")
            self.app.fake = FakeBackend(reply: "[SHAPE:line:\(self.px(t[0]));\(self.px(t[2])):hypotenuse:screen1] Yes, that's it: the longest side, opposite the right angle.")
            self.move(to: hyp)
            await self.wait(0.4)
            self.app.testClick(at: hyp)
            await self.wait(4)
            self.still("practice-point-right")
        }
        await practice("gap") { m, at in
            "[WRITE:\(at(0)):a² + b² = c²:screen1] The squares of the legs add up to the square of the long side.\n"
            + "[TRY:gap] [WRITE:\(at(0)):3² + 4² = ___:screen1] So for this triangle, what goes in the gap?"
        }
        await practice("mistake") { m, at in
            "[SHAPE:polygon:\(m.tri):triangle:screen1] Here the legs are 3 and 4.\n"
            + "[TRY:mistake] [WRITE:\(at(0)):3 + 4 = 7, so c = 7:screen1] Someone worked it out like this. What did they forget?"
        }
        await practice("say it") { m, at in
            "[SHAPE:line:\(m.hyp):hypotenuse:screen1] The hypotenuse is always the longest side.\n"
            + "[TRY:say it] In your own words, why can't a leg ever be longer than it?"
        }
        await practice("new numbers") { m, at in
            "[WRITE:\(at(0)):3² + 4² = 5²:screen1] Nine and sixteen make twenty-five, exactly five squared.\n"
            + "[TRY:new numbers] [WRITE:\(at(0)):6² + 8² = c²:screen1] Same shape, every side doubled. What's c now?"
        }
        await scene("Paused lesson card") {
            guard let m = self.mock else { return }
            self.ask("[TARGET:\(self.px(self.mid(m.formatMenu))),40:format menu:screen1] Open the Format menu, since that's where the file type is chosen.")
            await self.waitUntil(15) { self.app.testArmed }
            await self.wait(1.5)
            self.app.testPause()
            await self.wait(1.2)
            self.still("paused-card")
            await self.wait(0.5)
        }
        await scene("Owl moods") {
            // Every mood, large, plus the menu bar icon at real size.
            let moods = Owl.Mood.allCases
            let cell: CGFloat = 130, cols = 6
            let rows = (moods.count + cols - 1) / cols
            let size = NSSize(width: CGFloat(cols) * cell + 40, height: CGFloat(rows) * cell + 90)
            let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.sharingType = .readOnly
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.backgroundColor = NSColor(calibratedRed: 18 / 255, green: 18 / 255, blue: 22 / 255, alpha: 1)
            let v = NSView(frame: NSRect(origin: .zero, size: size))
            for (i, m) in moods.enumerated() {
                let o = OwlView(pixel: 6)
                o.fixed = m
                let x = 20 + CGFloat(i % cols) * cell, y = size.height - 60 - CGFloat(i / cols + 1) * cell + 20
                o.frame = NSRect(x: x + (cell - 96) / 2, y: y + 22, width: 96, height: 90)
                let l = NSTextField(labelWithString: m.rawValue)
                l.font = Look.ui(12, .medium); l.textColor = Look.warmWhite.withAlphaComponent(0.6); l.alignment = .center
                l.frame = NSRect(x: x, y: y, width: cell, height: 16)
                v.addSubview(o); v.addSubview(l)
            }
            let icon = NSImageView(image: OwlView.menuBarImage())
            icon.contentTintColor = .white
            icon.frame = NSRect(x: 20, y: size.height - 40, width: 18, height: 17)
            let il = NSTextField(labelWithString: "menu bar (real size)")
            il.font = Look.ui(11); il.textColor = Look.warmWhite.withAlphaComponent(0.5)
            il.frame = NSRect(x: 46, y: size.height - 39, width: 200, height: 15)
            v.addSubview(icon); v.addSubview(il)
            w.contentView = v
            let sc = NSScreen.screens[0].frame
            w.setFrameOrigin(NSPoint(x: sc.midX - size.width / 2, y: sc.midY - size.height / 2))
            w.orderFrontRegardless()
            await self.wait(1.4)
            self.still("owl-moods")
            w.orderOut(nil)
        }
        await scene("Mark mode") {
            guard let m = self.mock else { return }
            self.app.startMarking()
            await self.wait(0.8)
            let c = self.mid(m.formatMenu)
            // A wobbly hand-drawn loop, the way a mouse really draws one.
            self.app.markMode.testDraw((0...46).map { i in
                let a = Double(i) / 46 * 2.15 * .pi, wob = 1 + 0.08 * sin(Double(i) * 1.7)
                return NSPoint(x: c.x + 92 * wob * cos(a) + Double(i % 3), y: c.y + 32 * wob * sin(a) - Double(i) * 0.15) })
            await self.wait(0.4)
            self.still("mark-freehand")
            await self.wait(0.35)
            self.still("mark-morph")
            await self.wait(0.8)
            let f = m.field
            self.app.markMode.testDraw((0...24).map { NSPoint(x: f.minX + Double($0) * f.width / 24, y: f.minY - 6 + Double($0 % 3) * 1.2) })
            await self.wait(1.4)
            self.still("mark-drawing")
            self.app.fake = FakeBackend(reply: "[TOPIC:Export settings] [POINT:\(self.px(c)):format:screen1] Your 1 is the file type: PNG keeps every pixel, JPEG makes it smaller. Your 2 is the name the file will get.")
            self.app.markMode.finish()
            self.app.testSubmit("")
            await self.wait(6)
            self.still("mark-answer")
        }
        await scene("A tour inside a highlight") {
            guard let m = self.mock else { return }
            let r = m.field.union(m.formatMenu).union(m.export).insetBy(dx: -20, dy: -24)
            let tl = self.px(NSPoint(x: r.minX, y: r.maxY)), br = self.px(NSPoint(x: r.maxX, y: r.minY))
            let a = tl.split(separator: ","), b = br.split(separator: ",")
            self.ask("[HIGHLIGHT:\(a[0]),\(a[1]),\(Int(b[0])! - Int(a[0])!),\(Int(b[1])! - Int(a[1])!):export:screen1] "
                     + "You give it a [@\(self.px(self.mid(m.field)))]name, pick a [@\(self.px(self.mid(m.formatMenu)))]format, then press [@\(self.px(self.mid(m.export)))]Export.")
            for i in 1...5 {
                await self.wait(1.5)
                self.still("tour-\(i)")
            }
        }
        await scene("Mark under the notch") {
            let sc = NSScreen.screens[0].frame
            let tl = self.px(NSPoint(x: sc.midX - 160, y: sc.maxY - 40)), br = self.px(NSPoint(x: sc.midX + 160, y: sc.maxY - 110))
            let a = tl.split(separator: ","), b = br.split(separator: ",")
            let hl = "[HIGHLIGHT:\(a[0]),\(a[1]),\(Int(b[0])! - Int(a[0])!),\(Int(b[1])! - Int(a[1])!):toolbar:screen1]"
            self.ask("This is the first sentence.\nHere is the second one.\n\(hl) The toolbar at the very top holds the tools.\nAnd a fourth sentence to finish.")
            await self.waitUntil(30) { self.app.testCaption.snapshot.words.contains("finish.") }
            await self.wait(1)
            self.still("notch-stays-clear")
        }
        await scene("Highlight an area") {
            guard let m = self.mock else { return }
            let r = m.field.union(m.formatMenu).insetBy(dx: -20, dy: -24)
            let tl = self.px(NSPoint(x: r.minX, y: r.maxY)), br = self.px(NSPoint(x: r.maxX, y: r.minY))
            let a = tl.split(separator: ","), b = br.split(separator: ",")
            let w = Int(b[0])! - Int(a[0])!, h = Int(b[1])! - Int(a[1])!
            self.ask("[HIGHLIGHT:\(a[0]),\(a[1]),\(w),\(h):export options:screen1] These two boxes decide what the exported file is called and what kind of file it is.")
            await self.wait(3)
            self.still("highlight-roam-1")
            await self.wait(1.4)
            self.still("highlight-roam-2")
            await self.wait(2)
        }
        await scene("Early click on a step") {
            guard let m = self.mock else { return }
            self.ask("The export settings are open, and the name you give here becomes the file's name on disk, so pick something you'll recognise later.\n"
                     + "[TARGET:\(self.px(self.mid(m.field))),40:file name:screen1] Click the file name field.")
            await self.waitUntil(15) { self.app.testArmed }
            await self.wait(1.5)
            self.still("early-before-click")
            self.app.fake = FakeBackend(reply: "[HOVER:\(self.px(self.mid(m.formatMenu))),36:Format menu:screen1] Now rest the pointer on Format to see the options.")
            self.app.testClick(at: self.mid(m.field))
            await self.wait(0.6)
            self.still("early-thinking")
            await self.wait(4)
        }
        await scene("Topic pill and type bar") {
            guard let m = self.mock else { return }
            let t = m.triangle
            self.ask("[TOPIC:Pythagoras] [SHAPE:polygon:\(self.tri(m)):triangle:screen1] The squares on the two legs add up to the square on the long side.\n"
                     + "[WRITE:\(self.px(NSPoint(x: t[1].x + 40, y: t[2].y - 6))):a² + b² = c²:screen1] That's Pythagoras.", question: "explain pythagoras")
            await self.wait(0.5)
            self.still("owl-thinking")
            await self.waitUntil(20) { self.app.testCaption.snapshot.words.contains("Pythagoras.") }
            self.still("owl-answer")
            await self.wait(1.5)
            self.app.testClear()
            await self.wait(1.2)
            self.still("topic-pill")
            self.app.typeNow()
            await self.wait(0.8)
            self.still("type-bar")
        }
        await scene("Something went wrong") {
            self.app.testCaption.show("Couldn't reach Claude. Check your connection and try again.", style: .status, at: NSEvent.mouseLocation)
            await self.wait(1.5)
            self.still("error")
            await self.wait(1)
        }

        app.escape()
        await wait(1)
        recorder?.waitUntilExit()
        backdrop?.orderOut(nil)
        Settings.shared.showInRecordings = saved.0
        app.applySharing()
        app.setBuddy(saved.1)
        move(to: home)
        print("Reel and \(stills) stills in \(out.path)")
        exit(0)
    }

    // MARK: Pieces

    /// The mock's triangle, as tag points.
    struct Marks { let tri: String, hyp: String }
    private func tri(_ m: MockApp) -> String { m.triangle.map(px).joined(separator: ";") }

    /// A practice move scene: the reply, a still once the question is up, and a still a moment later.
    private func practice(_ move: String, _ reply: @escaping (Marks, (Int) -> String) -> String) async {
        await scene("Practice: \(move)") {
            guard let m = self.mock else { return }
            let t = m.triangle
            let marks = Marks(tri: self.tri(m), hyp: "\(self.px(t[0]));\(self.px(t[2]))")
            let at: (Int) -> String = { row in self.px(NSPoint(x: t[1].x + 40, y: t[2].y - 6 - CGFloat(row) * 44)) }
            let text = self.live[move] ?? reply(marks, at)
            self.ask(text, question: "explain pythagoras")
            let last = text.split(separator: " ").last.map(String.init) ?? ""
            await self.waitUntil(70) { self.app.testCaption.snapshot.words.contains(last) }
            await self.wait(2.5)
            self.still("practice-\(move.replacingOccurrences(of: " ", with: "-"))")
            await self.wait(1)
        }
    }

    private func scene(_ title: String, _ body: () async -> Void) async {
        if let i = CommandLine.arguments.firstIndex(of: "--only"), CommandLine.arguments.count > i + 1,
           !title.lowercased().contains(CommandLine.arguments[i + 1].lowercased()) { return }
        trace("Gallery: \(title)")
        mock?.title = title
        mock?.needsDisplay = true
        await body()
        app.escape()
        await wait(0.9)
    }

    private func showBackdrop(on screen: NSScreen) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.ignoresMouseEvents = true
        let m = MockApp(frame: NSRect(origin: .zero, size: screen.frame.size))
        w.contentView = m
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        backdrop = w
        mock = m
    }

    private func ask(_ reply: String, voice: Bool = false, question: String = "gallery") {
        app.fake = FakeBackend(reply: reply)
        app.ask(question, byVoice: voice)
    }

    private func record(seconds: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-v", "-V", "\(seconds)", "-D", "1", out.appendingPathComponent("reel.mov").path]
        try? p.run()
        recorder = p
    }

    private func still(_ name: String) {
        stills += 1
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-D", "1", "-t", "png", out.appendingPathComponent(String(format: "%02d-%@.png", stills, name)).path]
        try? p.run()
        p.waitUntilExit()
    }

    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private func waitUntil(_ limit: Double, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(limit)
        while !done() && Date() < end { await wait(0.1) }
    }

    private func move(to p: NSPoint) {
        let top = NSScreen.screens[0].frame.maxY
        let cg = CGPoint(x: p.x, y: top - p.y)
        CGWarpMouseCursorPosition(cg)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func point(_ fx: Double, _ fy: Double) -> NSPoint {
        let f = NSScreen.screens[0].frame
        return NSPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)
    }

    private func mid(_ r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }

    /// A global point as "x,y" in the main display's screenshot pixels.
    private func px(_ p: NSPoint) -> String {
        let s = NSScreen.screens[0]
        let scale = min(1, Capture.maxLongEdge / max(s.frame.width, s.frame.height))
        return "\(Int((p.x - s.frame.minX) * scale)),\(Int((s.frame.maxY - p.y) * scale))"
    }
}

/// `Navi --practice-check <out-dir>`: asks real Claude (the app's
/// `claude -p` backend and system prompt) to explain on the gallery's mock
/// screen and end with each practice move in turn, checks the structure of
/// each reply, and saves them as `replies.json` for `--gallery … --live`.
@MainActor
enum PracticeCheck {
    static let moves = ["predict", "your turn", "point", "gap", "mistake", "say it", "new numbers"]

    static func run(out: String) async {
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screen = NSScreen.screens[0]
        let mock = MockApp(frame: NSRect(origin: .zero, size: screen.frame.size))
        let scale = min(1, Capture.maxLongEdge / max(screen.frame.width, screen.frame.height))
        let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
        guard let rep = mock.bitmapImageRepForCachingDisplay(in: mock.bounds) else { return }
        mock.cacheDisplay(in: mock.bounds, to: rep)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!, jpeg = Capture.jpeg(img)!
        try? jpeg.write(to: dir.appendingPathComponent("screen.jpg"))
        let size = CGSize(width: w, height: h)

        if CommandLine.arguments.contains("--styles") {
            await styles(jpeg: jpeg, w: w, h: h)
            return
        }
        let cli = CLIBackend()
        cli.prewarm()
        var replies: [String: String] = [:]
        var failures = 0
        for move in moves {
            cli.reset()
            let conv = Conversation()
            let q = "Explain Pythagoras' theorem using the triangle on my screen."
            let content: [[String: Any]] = [
                Prompt.text("Screen 1 (the cursor is here): \(w)×\(h) px"), Prompt.image(jpeg),
                Prompt.text("(Test run: for this answer, use the practice move \"\(move)\".)"), Prompt.text(q)]
            let t0 = Date()
            let reply: String
            do { reply = try await conv.send(content, kind: .question(q), via: cli, onText: { _ in }) }
            catch { print("✗ \(move): \(error)"); failures += 1; continue }
            replies[move] = reply
            let beats = TagParser.beats(reply), practice = beats.filter(\.practice)
            let marks = TagParser.parse(reply).annotations
            func points(_ a: Annotation) -> [CGPoint] {
                switch a {
                case .point(let p, _, _), .target(let p, _, _, _), .hover(let p, _, _, _), .write(let p, _, _), .quiz(let p, _, _, _): return [p]
                case .shape(_, let ps, _, _): return ps
                case .highlight(let r, _, _): return [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
                case .demo(let ps, _, _): return ps
                case .open, .download: return []
                }
            }
            let inBounds = marks.allSatisfy { a in points(a).allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x <= size.width && $0.y <= size.height } }
            let questions = practice.map { $0.text.filter { $0 == "?" }.count }.reduce(0, +)
            var checks: [(String, Bool)] = [
                ("names the move", TagParser.practiceMove(reply) == move),
                ("has a practice line", !practice.isEmpty),
                ("marker never shown", !beats.contains { $0.text.contains("TRY") }),
                ("at most two questions", questions <= 2),
                ("comes last", beats.last?.practice == true),
                ("marks on screen", inBounds),
                ("explanation is drawn", Tutor.explanationGap(reply) == nil),
            ]
            switch move {
            case "point": checks.append(("asks with QUIZ", practice.contains { if case .quiz? = $0.annotation { return true }; return false }))
            case "gap": checks.append(("leaves a blank", practice.contains { $0.text.contains("_") } || reply.contains("_")))
            default: break
            }
            let bad = checks.filter { !$0.1 }
            failures += bad.count
            print(String(format: "%@ %@ (%.1fs)%@", bad.isEmpty ? "✓" : "✗", move, Date().timeIntervalSince(t0),
                         bad.isEmpty ? "" : ": " + bad.map(\.0).joined(separator: ", ")))
            print(reply.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
        }
        cli.shutdown()
        if let d = try? JSONSerialization.data(withJSONObject: replies, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("replies.json"))
        }
        print(failures == 0 ? "All \(moves.count) moves passed." : "\(failures) check(s) failed.")
    }
}

extension PracticeCheck {
    /// `--practice-check <dir> --styles`: an app task, the same task after "let me
    /// try", and an idea, each checked for the teaching it should get.
    static func styles(jpeg: Data, w: Int, h: Int) async {
        let cli = CLIBackend()
        cli.prewarm()
        let task = "How do I export these as JPEG instead?"
        let cases: [(String, [String], String, (String) -> [(String, Bool)])] = [
            ("app task", [], task, { r in
                let a = TagParser.parse(r).annotations
                return [("a step to click", a.contains { if case .target = $0 { return true }; if case .hover = $0 { return true }; return false }),
                        ("no practice", TagParser.practiceMove(r) == nil)]
            }),
            ("let me try", [AppController.tryFirstNoteForTests], "Let me try it myself: how do I export these as JPEG?", { r in
                let a = TagParser.parse(r).annotations
                return [("asks with QUIZ", a.contains { if case .quiz = $0 { return true }; return false }),
                        ("doesn't give it away", !a.contains { if case .target = $0 { return true }; if case .point = $0 { return true }; return false })]
            }),
            ("idea", [], "Explain Pythagoras' theorem using the triangle on my screen.", { r in
                [("ends with practice", TagParser.beats(r).last?.practice == true)]
            }),
        ]
        var failures = 0
        for (name, extras, q, checks) in cases {
            cli.reset()
            var content: [[String: Any]] = [Prompt.text("Screen 1 (the cursor is here): \(w)×\(h) px"), Prompt.image(jpeg)]
            content += extras.map { Prompt.text($0) }
            content.append(Prompt.text(q))
            let reply: String
            do { reply = try await Conversation().send(content, kind: .question(q), via: cli, onText: { _ in }) }
            catch { print("✗ \(name): \(error)"); failures += 1; continue }
            let bad = checks(reply).filter { !$0.1 }
            failures += bad.count
            print("\(bad.isEmpty ? "✓" : "✗") \(name)\(bad.isEmpty ? "" : ": " + bad.map(\.0).joined(separator: ", "))")
            print(reply.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
        }
        cli.shutdown()
        print(failures == 0 ? "All styles passed." : "\(failures) check(s) failed.")
    }
}

/// A quiet, generic app window to draw on: a sidebar, a diagram, a field,
/// a menu and two buttons. Positions are global points for the replies.
private final class MockApp: NSView {
    var title = ""
    private(set) var export = NSRect.zero, field = NSRect.zero, formatMenu = NSRect.zero
    private(set) var triangle: [NSPoint] = []
    private var win = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        let w: CGFloat = min(1080, frame.width - 160), h: CGFloat = min(660, frame.height - 200)
        win = NSRect(x: (frame.width - w) / 2, y: (frame.height - h) / 2 - 20, width: w, height: h)
        let main = NSRect(x: win.minX + 220, y: win.minY, width: win.width - 220, height: win.height - 52)
        export = NSRect(x: win.maxX - 120, y: win.minY + 24, width: 96, height: 32)
        field = NSRect(x: main.minX + 32, y: win.maxY - 130, width: 300, height: 30)
        formatMenu = NSRect(x: main.minX + 360, y: win.maxY - 130, width: 140, height: 30)
        let base = NSPoint(x: main.minX + 60, y: win.minY + 110)
        triangle = [base, NSPoint(x: base.x + 300, y: base.y), NSPoint(x: base.x + 300, y: base.y + 225)]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Global (screen) coordinates of a view rect, for the gallery's replies.
    private func global(_ r: NSRect) -> NSRect { window.map { r.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY) } ?? r }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        export = global(export); field = global(field); formatMenu = global(formatMenu)
        triangle = triangle.map { p in window.map { NSPoint(x: p.x + $0.frame.minX, y: p.y + $0.frame.minY) } ?? p }
    }
    private func local(_ r: NSRect) -> NSRect { window.map { r.offsetBy(dx: -$0.frame.minX, dy: -$0.frame.minY) } ?? r }
    private func local(_ p: NSPoint) -> NSPoint { window.map { NSPoint(x: p.x - $0.frame.minX, y: p.y - $0.frame.minY) } ?? p }

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill(); bounds.fill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor.white.setFill(); NSBezierPath(roundedRect: win, xRadius: 14, yRadius: 14).fill()
        NSGraphicsContext.restoreGraphicsState()
        let grey = NSColor(calibratedWhite: 0.97, alpha: 1)
        grey.setFill(); NSBezierPath(roundedRect: NSRect(x: win.minX, y: win.minY, width: 220, height: win.height), xRadius: 14, yRadius: 14).fill()
        func text(_ s: String, _ p: NSPoint, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular, _ c: NSColor = .darkGray) {
            (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c])
        }
        for (i, name) in ["General", "Export", "Layers", "Colour", "Shortcuts"].enumerated() {
            if i == 1 { NSColor(calibratedWhite: 0.88, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: win.minX + 12, y: win.maxY - 92 - CGFloat(i) * 34, width: 196, height: 28), xRadius: 7, yRadius: 7).fill() }
            text(name, NSPoint(x: win.minX + 28, y: win.maxY - 86 - CGFloat(i) * 34))
        }
        text("Export settings", NSPoint(x: win.minX + 252, y: win.maxY - 40), 17, .semibold, .black)
        let f = local(field), m = local(formatMenu), e = local(export)
        NSColor(calibratedWhite: 0.8, alpha: 1).setStroke()
        let fp = NSBezierPath(roundedRect: f, xRadius: 6, yRadius: 6); fp.lineWidth = 1; fp.stroke()
        text("Holiday photos", NSPoint(x: f.minX + 10, y: f.minY + 7), 13, .regular, .gray)
        let mp = NSBezierPath(roundedRect: m, xRadius: 6, yRadius: 6); mp.stroke()
        text("Format: PNG  ⌄", NSPoint(x: m.minX + 12, y: m.minY + 7))
        NSColor(calibratedRed: 0.2, green: 0.47, blue: 0.95, alpha: 1).setFill(); NSBezierPath(roundedRect: e, xRadius: 7, yRadius: 7).fill()
        text("Export", NSPoint(x: e.minX + 26, y: e.minY + 8), 13, .medium, .white)
        let c = NSRect(x: e.minX - 104, y: e.minY, width: 92, height: 32)
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill(); NSBezierPath(roundedRect: c, xRadius: 7, yRadius: 7).fill()
        text("Cancel", NSPoint(x: c.minX + 24, y: c.minY + 8))
        let t = triangle.map(local)
        let tri = NSBezierPath(); tri.move(to: t[0]); tri.line(to: t[1]); tri.line(to: t[2]); tri.close()
        NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.97, alpha: 1).setFill(); tri.fill()
        NSColor(calibratedWhite: 0.35, alpha: 1).setStroke(); tri.lineWidth = 1.5; tri.stroke()
        text("3", NSPoint(x: (t[0].x + t[1].x) / 2, y: t[0].y - 22)); text("4", NSPoint(x: t[1].x + 10, y: (t[1].y + t[2].y) / 2))
        text(title, NSPoint(x: 40, y: 40), 15, .medium, NSColor(calibratedWhite: 0.45, alpha: 1))
    }
}

/// Gallery and stress runs draw on the real display and move the real pointer, so
/// they ask first, every time, and say for how long.
@MainActor
enum ScreenTakeover {
    static func confirm(_ title: String, takes: String, doing: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "Navi will take over your screen for \(takes): \(doing) Keep your hands off the keyboard and mouse until it's done."
        a.addButton(withTitle: "Run")
        a.addButton(withTitle: "Cancel")
        let ok = a.runModal() == .alertFirstButtonReturn
        trace("\(title) \(ok ? "Run." : "Cancelled.")")
        return ok
    }
}
#endif
