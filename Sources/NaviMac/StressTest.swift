#if DEBUG
import AppKit

/// A GUI stress test: `Navi --stress <out-dir>`.
///
/// Drives the real app with canned replies (no model) through the situations
/// that break overlays: interruptions, rapid re-asks, long answers, screen
/// edges and corners, crowded marks, a second display, the mouse moving
/// away, the companion turned off, a flood of live transcript. After each it
/// checks what's on screen: is the caption where it should be, on screen,
/// near Navi, off the marks, fully lit, gone when it should be gone, and
/// idle when nothing moves. Screenshots of every display go to the out
/// directory with a report. It moves the real mouse pointer and speaks.
@MainActor
final class StressTest {
    private let app: AppController
    private let out: URL
    private var report: [String] = []
    private var failures = 0
    private var shots = 0

    init(app: AppController, out: String) {
        self.app = app
        self.out = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: self.out, withIntermediateDirectories: true)
    }

    func run() async {
        guard ScreenTakeover.confirm("Run the stress test?", takes: "about 3 minutes",
                                     doing: "it asks with canned replies, moves the real pointer to every display's corners and takes screenshots.") else { exit(0) }
        let saved = (Settings.shared.showInRecordings, Settings.shared.buddy)
        Settings.shared.showInRecordings = true   // so screenshots include the overlays
        app.applySharing()
        app.setBuddy(true)
        let home = NSEvent.mouseLocation
        await wait(1.5)

        await scenario("typed one-beat answer") { await self.typedOneBeat() }
        await scenario("spoken two beats light every word") { await self.spokenTwoBeats() }
        await scenario("Esc mid-sentence clears everything") { await self.escapeMidSentence() }
        await scenario("rapid re-asks keep one caption") { await self.rapidReasks() }
        await scenario("long typed answer stays readable") { await self.longAnswer() }
        await scenario("corners of every display") { await self.corners() }
        await scenario("crowded marks") { await self.crowded() }
        await scenario("moving away dismisses a finished answer") { await self.moveAway() }
        await scenario("companion off: caption at the pointer") { await self.companionOff() }
        await scenario("flood of live transcript") { await self.transcriptFlood() }
        await scenario("scroll mid-answer") { await self.scrollMidAnswer() }
        await scenario("idle costs nothing") { await self.idle() }
        await scenario("long answer docks into the notch") { await self.docking() }

        app.escape()
        Settings.shared.showInRecordings = saved.0
        app.applySharing()
        app.setBuddy(saved.1)
        move(to: home)
        report.append("\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        let text = report.joined(separator: "\n")
        try? text.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(text)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Scenarios

    private func typedOneBeat() async {
        let s = screenUnderMouse()
        move(to: point(s, 0.35, 0.55))
        let mark = point(s, 0.45, 0.5)
        ask("[POINT:\(px(mark, s)):Export] Export is in the File menu, near the bottom.")
        await wait(2)
        auditCaption(visible: true, words: 9)
        capture("typed")
    }

    private func spokenTwoBeats() async {
        let s = screenUnderMouse()
        let a = point(s, 0.3, 0.4), b = point(s, 0.6, 0.62)
        ask("[POINT:\(px(a, s)):Layers] The Layers panel lists everything on the canvas.\n"
            + "[SHAPE:circle:\(px(b, s));\(px(NSPoint(x: b.x + 40, y: b.y), s)):Export] Export saves a copy when you're done.", voice: true)
        await wait(1.6)
        let early = app.testCaption.snapshot
        check("words light gradually, not all at once", early.lit < early.words.count, "\(early.lit)/\(early.words.count) lit early")
        capture("spoken-mid")
        await waitUntil(12) { self.app.testCaption.snapshot.words.first == "Export" }
        await waitUntil(3) { self.app.testSpeaking }
        await wait(1)
        auditCaption(visible: true, tag: "beat 2")
        capture("spoken-beat2")
        await waitUntil(8) { !self.app.testSpeaking }
        await wait(0.6)
        let done = app.testCaption.snapshot
        check("all words lit after speaking", done.lit == done.words.count, "\(done.lit)/\(done.words.count)")
        auditCaption(visible: true)
        capture("spoken-end")
    }

    private func escapeMidSentence() async {
        let s = screenUnderMouse()
        ask("[POINT:\(px(point(s, 0.5, 0.5), s)):Inspector] The inspector shows the settings for whatever you select, one section at a time.", voice: true)
        await wait(1.8)
        app.escape()
        await wait(0.6)
        check("speech stopped", !app.testSpeaking)
        check("no marks left", app.testOverlays.occupied().isEmpty, "\(app.testOverlays.occupied().count) left")
        auditCaption(visible: false)
    }

    private func rapidReasks() async {
        let s = screenUnderMouse()
        for i in 0..<6 {
            ask("[POINT:\(px(point(s, 0.2 + Double(i) * 0.1, 0.5), s)):Item \(i)] This is answer number \(i), and it is the one on screen.")
            await wait(0.25)
        }
        await wait(2)
        let snap = app.testCaption.snapshot
        check("caption shows only the last answer", snap.words.joined(separator: " ").contains("number 5"), snap.words.joined(separator: " "))
        check("one mark per final answer", app.testOverlays.occupied().count <= 2, "\(app.testOverlays.occupied().count) marks")
        auditCaption(visible: true)
        capture("rapid")
    }

    private func longAnswer() async {
        let s = screenUnderMouse()
        let long = (1...12).map { "Sentence \($0) explains another part of how the export settings fit together." }.joined(separator: " ")
        ask("[POINT:\(px(point(s, 0.5, 0.5), s)):Settings] " + long)
        await wait(5)
        let snap = app.testCaption.snapshot
        check("width capped", snap.frame.width <= Caption.maxWidth + Caption.pad.width * 2 + 1, "\(Int(snap.frame.width)) pt")
        auditCaption(visible: true)
        capture("long")
    }

    private func corners() async {
        for (n, screen) in NSScreen.screens.enumerated() {
            let f = screen.visibleFrame
            for (name, fx, fy) in [("bottom-left", 0.02, 0.03), ("bottom-right", 0.97, 0.03), ("top-left", 0.02, 0.96), ("top-right", 0.97, 0.96)] {
                let m = NSPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)
                move(to: m)
                await wait(0.7)
                ask("[POINT:\(px(NSPoint(x: m.x + (fx > 0.5 ? -30 : 30), y: m.y), screen)):Corner] Here is something tucked right into the \(name) corner of display \(n + 1).")
                await wait(2.2)
                auditCaption(visible: true, tag: "display \(n + 1) \(name)")
                if name == "top-right" || name == "bottom-left" { capture("corner-d\(n + 1)-\(name)") }
            }
        }
        app.escape()
    }

    private func crowded() async {
        let s = screenUnderMouse()
        let c = point(s, 0.5, 0.5)
        move(to: NSPoint(x: c.x - 20, y: c.y + 20))
        await wait(0.6)
        var beats: [String] = []
        for (dx, dy) in [(60, -40), (60, 40), (-60, -40), (-60, 40), (120, 0), (0, -90)] {
            let p = NSPoint(x: c.x + CGFloat(dx), y: c.y + CGFloat(dy))
            beats.append("[SHAPE:circle:\(px(p, s));\(px(NSPoint(x: p.x + 28, y: p.y), s)):Part]")
        }
        ask(beats.joined(separator: "\n") + "\n[POINT:\(px(c, s)):Centre] All six parts surround the centre control.")
        await waitUntil(15) { self.app.testCaption.snapshot.words.first == "All" }
        await wait(1.5)
        auditCaption(visible: true, maxOverlap: 0.12, near: 260)
        capture("crowded")
        app.escape()
    }

    private func moveAway() async {
        let s = screenUnderMouse()
        let p = point(s, 0.4, 0.5)
        move(to: p)
        ask("[POINT:\(px(point(s, 0.45, 0.45), s)):Save] Save is the first button in the toolbar.")
        await wait(2)
        auditCaption(visible: true)
        move(to: NSPoint(x: p.x + 400, y: p.y - 150))
        await wait(0.4)
        move(to: NSPoint(x: p.x + 420, y: p.y - 160))
        await wait(0.8)
        auditCaption(visible: false, tag: "after moving away")
    }

    private func companionOff() async {
        app.setBuddy(false)
        let s = screenUnderMouse()
        let mouse = point(s, 0.3, 0.3)
        move(to: mouse)
        ask("[POINT:\(px(point(s, 0.6, 0.6), s)):Share] Share sends a link to anyone you choose.")
        await wait(2)
        let snap = app.testCaption.snapshot
        check("no thread without the companion", snap.threadOpacity == 0)
        check("caption near the pointer", snap.frame.insetBy(dx: -90, dy: -90).contains(mouse), "frame \(snap.frame) mouse \(mouse)")
        auditCaption(visible: true)
        capture("companion-off")
        app.setBuddy(true)
        app.escape()
    }

    private func transcriptFlood() async {
        let words = "could you show me where the export settings went after the last update please".split(separator: " ")
        for i in 1...words.count * 4 {
            app.testCaption.show(words.prefix(i / 4 + 1).joined(separator: " "), style: .listening, at: NSEvent.mouseLocation)
            await wait(0.02)
        }
        await wait(0.8)
        let snap = app.testCaption.snapshot
        check("final transcript shown in full", snap.words.count == words.count && snap.lit == words.count, "\(snap.lit)/\(snap.words.count)")
        auditCaption(visible: true)
        capture("transcript")
        app.testCaption.hide()
    }

    private func scrollMidAnswer() async {
        let s = screenUnderMouse()
        ask("[POINT:\(px(point(s, 0.5, 0.4), s)):Header] The header stays put while the list scrolls underneath it, which keeps the totals in view.", voice: true)
        await wait(1.5)
        app.demoScroll()
        await wait(1)
        check("marks cleared by the scroll", app.testOverlays.occupied().isEmpty, "\(app.testOverlays.occupied().count) left")
        check("narration carries on", app.testSpeaking)
        auditCaption(visible: true)
        app.escape()
    }

    private func docking() async {
        let s = screenUnderMouse()
        let beats = (1...4).map { "[POINT:\(px(point(s, 0.2 + Double($0) * 0.12, 0.45), s)):Part \($0)] Part \($0) is where the next piece of the explanation lives." }
        ask(beats.joined(separator: "\n"))
        await waitUntil(30) { self.app.testCaption.isDocked }
        check("docked by the third sentence", app.testCaption.isDocked)
        await wait(1.5)
        let snap = app.testCaption.snapshot
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(snap.frame) }
        check("hangs from the top centre of its screen", screen.map { abs(snap.frame.maxY - $0.frame.maxY) < 2 && abs(snap.frame.midX - $0.frame.midX) < 2 } ?? false, "\(snap.frame)")
        check("no thread while docked", snap.threadOpacity == 0)
        capture("docked")
        await waitUntil(40) { self.app.testCaption.snapshot.words.first == "Part" && self.app.testCaption.snapshot.words.contains("4") }
        await wait(8)
        check("stays up after the answer ends", app.testCaption.snapshot.shown)
        app.escape()
        await wait(0.6)
        check("Esc puts it away", !app.testCaption.snapshot.shown || app.testCaption.snapshot.alpha < 0.05)
    }

    private func idle() async {
        let s = screenUnderMouse()
        ask("[POINT:\(px(point(s, 0.5, 0.5), s)):Done] That's the button you want.")
        await wait(3)
        check("caption's frame timer stops when still", !app.testCaption.snapshot.ticking)
        app.escape()
        await wait(1)
    }

    // MARK: Checks

    private func scenario(_ name: String, _ body: () async -> Void) async {
        if let i = CommandLine.arguments.firstIndex(of: "--only"), CommandLine.arguments.count > i + 1,
           !name.contains(CommandLine.arguments[i + 1]) { return }
        report.append("\n## \(name)")
        trace("Stress: \(name)")
        await body()
        app.escape()
        await wait(0.8)
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        report.append("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
    }

    /// The caption is shown (or not), fully on one screen, beside Navi and clear of the marks.
    private func auditCaption(visible: Bool, words: Int? = nil, maxOverlap: CGFloat = 0.12, near: CGFloat = 70, tag: String = "") {
        let s = app.testCaption.snapshot
        let t = tag.isEmpty ? "" : "[\(tag)] "
        guard visible else {
            check("\(t)caption hidden", !s.shown || s.alpha < 0.05, "shown \(s.shown) alpha \(s.alpha)")
            return
        }
        check("\(t)caption shown", s.shown && s.alpha > 0.9, "shown \(s.shown) alpha \(s.alpha)")
        if let words { check("\(t)all \(words) words", s.words.count == words, "\(s.words.count)") }
        let f = s.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(f) }
        check("\(t)on one screen, inside its usable area", onScreen, "\(f)")
        if let b = s.bloom {
            let dx = max(f.minX - b.x, 0, b.x - f.maxX), dy = max(f.minY - b.y, 0, b.y - f.maxY)
            check("\(t)beside Navi", hypot(dx, dy) < near, "\(Int(hypot(dx, dy))) pt away")
        }
        let covered = app.testOverlays.occupied().reduce(CGFloat(0)) { sum, r in
            let i = f.intersection(r)
            return sum + (i.isNull ? 0 : i.width * i.height)
        }
        let fraction = covered / max(1, f.width * f.height)
        check("\(t)clear of marks", fraction <= maxOverlap, String(format: "%.0f%% over marks", fraction * 100))
    }

    // MARK: Driving

    private func ask(_ reply: String, voice: Bool = false) {
        app.fake = FakeBackend(reply: reply)
        app.ask("stress", byVoice: voice)
    }

    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private func waitUntil(_ limit: Double, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(limit)
        while !done() && Date() < end { await wait(0.1) }
    }

    /// Moves the real pointer (global AppKit point) and posts a move so the companion follows.
    private func move(to p: NSPoint) {
        let top = NSScreen.screens[0].frame.maxY
        let cg = CGPoint(x: p.x, y: top - p.y)
        CGWarpMouseCursorPosition(cg)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func screenUnderMouse() -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.screens[0]
    }

    private func point(_ s: NSScreen, _ fx: Double, _ fy: Double) -> NSPoint {
        NSPoint(x: s.visibleFrame.minX + s.visibleFrame.width * fx, y: s.visibleFrame.minY + s.visibleFrame.height * fy)
    }

    /// A global point as "x,y" in screen 1's screenshot pixels (screen 1 is the one with the pointer).
    private func px(_ p: NSPoint, _ s: NSScreen) -> String {
        let scale = min(1, Capture.maxLongEdge / max(s.frame.width, s.frame.height))
        return "\(Int((p.x - s.frame.minX) * scale)),\(Int((s.frame.maxY - p.y) * scale))"
    }

    private func capture(_ tag: String) {
        shots += 1
        let files = NSScreen.screens.indices.map { out.appendingPathComponent(String(format: "%02d-%@-d%d.jpg", shots, tag, $0 + 1)).path }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-t", "jpg"] + files
        try? p.run()
        p.waitUntilExit()
    }
}
#endif
