import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Whole answers played through the engine on the fake shell, with scripted
/// replies from "Claude": what's drawn, said and armed, in order. No screen, no
/// waiting, on any platform (`navi-core-check` runs them).
public enum EngineChecks {
    @MainActor
    public static func run(_ check: (String, Bool) -> Void) async {
        /// A fresh engine on a fake shell, answering every turn with `reply`
        /// (streamed in two halves, as a real reply arrives in pieces).
        func setUp(_ reply: String) -> (Tutor.Engine, FakeShell) {
            let fake = FakeShell(screens: 1)
            let e = Tutor.Engine(overlay: fake.overlay, light: fake.light, caption: fake.caption, ui: fake.ui,
                                 screens: fake.screens, voice: nil)
            e.wait = { _ in }
            e.send = { _, _, onText in
                // Streamed: the shell hears each piece before the reply is complete.
                onText(String(reply.prefix(reply.count / 2)))
                try? await Task.sleep(nanoseconds: 5_000_000)
                onText(reply)
                try? await Task.sleep(nanoseconds: 5_000_000)
                return reply
            }
            return (e, fake)
        }
        func play(_ e: Tutor.Engine, _ fake: FakeShell, explain: Bool = false) async -> Tutor.Engine.Played? {
            let shots: [any Shell.Screenshot] = [FakeShell.Shot(screenID: 1, index: 1, hasCursor: true, origin: .zero)]
            return try? await e.playTurn([], shots: shots, anchor: CGPoint(x: 700, y: 450), gen: 0, explain: explain,
                                         kind: .lessonStep, speak: false)
        }
        func said(_ fake: FakeShell) -> [String] { fake.log.filter { $0.hasPrefix("say ") } }

        // A lesson step: the target is drawn, its sentence read, and the step comes back to be armed.
        do {
            let (e, fake) = setUp("[TARGET:200,100,30:Export] Click Export, since that saves the map.")
            var early = false
            e.onEarlyStep = { _ in early = true }
            let played = await play(e, fake)
            check("engine: a lesson step is drawn and its sentence read",
                  fake.log.contains { $0.hasPrefix("target 100,850 r28 Export") } && said(fake) == ["say Click Export, since that saves the map."])
            check("engine: the step comes back to be armed, on the right display", played?.step?.label == "Export" && played?.step?.display == 1)
            check("engine: a step is armed as soon as its tag arrives", early)
        }

        // An explanation: several beats in order, docking from the third sentence.
        do {
            let (e, fake) = setUp("""
            [SHAPE:line:100,800;500,800:leg a] This side is a.
            [SHAPE:line:500,800;500,400:leg b] This side is b.
            [WRITE:600,300:a² + b² = c²] So a squared plus b squared is c squared.
            """)
            let played = await play(e, fake, explain: true)
            check("engine: an explanation's beats play in order", said(fake) == ["say This side is a.", "say This side is b.",
                                                                               "say So a squared plus b squared is c squared."])
            check("engine: marks come before their words", (fake.log.firstIndex { $0.hasPrefix("shape line") } ?? 99) < (fake.log.firstIndex { $0.hasPrefix("say ") } ?? 0))
            check("engine: the answer docks from the third sentence", fake.caption.isDocked && played?.drawings == 3)
            check("engine: explanation marks get their own colours", fake.log.contains { $0.hasPrefix("ink #") })
        }

        // A tour: the light visits each anchor as its word lights.
        do {
            let (e, fake) = setUp("[HIGHLIGHT:100,100,600,200:mixer] Each strip has [@200,150]gain and a [@400,150]fader.")
            _ = await play(e, fake)
            check("engine: a tour glides to each stop", fake.log.filter { $0.hasPrefix("glide") }.count == 2)
        }

        // Your turn: the practice question is flagged, and no step is armed.
        do {
            let (e, fake) = setUp("""
            [WRITE:200,200:a² + b² = c²] Square the legs, add them, then take the root.
            [TRY:your turn] [WRITE:200,300:5² + 12² = c²] Your turn: with legs of 5 and 12, what's c?
            """)
            let played = await play(e, fake)
            check("engine: Your turn is flagged as practice", said(fake).last?.hasPrefix("say (your turn)") == true && played?.step == nil)
        }

        // A click-the-answer question: nothing drawn where the answer is.
        do {
            let (e, fake) = setUp("[TRY:point] [QUIZ:300,300,40:hypotenuse] Which side is the hypotenuse? Click it.")
            let played = await play(e, fake)
            check("engine: a quiz arms a step without drawing the answer",
                  played?.step?.quiz == true && !fake.log.contains { $0.hasPrefix("target") || $0.hasPrefix("point") }
                  && fake.caption.practiceHow == "click it on screen")
        }

        // Superseded: a newer generation makes the rest of the answer stale.
        do {
            let (e, fake) = setUp("[POINT:100,100:a] First. [POINT:200,200:b] Second.")
            var gen = 0
            e.generation = { gen }
            e.onReply = { _ in gen = 1 }
            let played = await play(e, fake)
            check("engine: a newer turn stops the old one's words", played == nil && said(fake).count <= 1)
        }

        // MARK: Lessons

        /// An engine on a fake shell for a lesson: its host, watch, pause card and pill
        /// are the fake's, and "Claude" answers each turn with the next of `replies`.
        func lessonSetUp(_ replies: [String]) -> (Tutor.Engine, FakeShell) {
            let fake = FakeShell(screens: 1)
            let e = Tutor.Engine(overlay: fake.overlay, light: fake.light, caption: fake.caption, ui: fake.ui,
                                 screens: fake.screens, voice: nil)
            e.wait = { _ in }
            e.host = fake.host
            e.watch = fake.watch
            e.pauseCard = fake.pause
            e.topicPill = fake.pill
            e.frontApp = { fake.ui.app }
            e.actions = fake.errands
            var queue = replies
            e.send = { _, _, onText in
                let r = queue.isEmpty ? "" : queue.removeFirst()
                onText(r)
                try? await Task.sleep(nanoseconds: 2_000_000)
                return r
            }
            return (e, fake)
        }
        let lessonShots: [any Shell.Screenshot] = [FakeShell.Shot(screenID: 1, index: 1, hasCursor: true, origin: .zero)]
        func start(_ e: Tutor.Engine) async {
            try? await e.runTurn([], shots: lessonShots, goal: "save the map", anchor: .zero, gen: e.bump())
        }

        // A lesson: each step is armed and watched; a click on it takes the next; no step ends it.
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:Export] Click Export, since that saves the map.",
                                          "[TARGET:400,300,30:PNG] Now choose PNG.",
                                          "That's it: your map is saved."])
            await start(e)
            check("lesson: the caption says it's their move, and what", fake.caption.kicker == "YOUR MOVE · CLICK EXPORT")
            check("prompt: asking for help with a task gets a lesson", Prompt.system.contains("\"help me…\""))
            check("lesson: the step is armed and watched", e.lesson?.armed?.label == "Export" && fake.watch.watching?.label == "Export"
                  && e.lessonApp == 42 && e.lessonScreen == 1)
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await e.turn?.value
            check("lesson: a click on the step takes the next one", e.lesson?.armed?.label == "PNG" && e.lesson?.stepsTaken == 1)
            e.graceUntil = nil
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await e.turn?.value
            check("lesson: a reply with no step finishes the lesson", e.lesson == nil && fake.log.contains("lesson ended"))
        }

        // A click marked with a POINT in a lesson is armed as a step, not left waiting on the card.
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:folder] Open the folder.", "[POINT:300,200:model file] Click the model file.", "Done."])
            await start(e)
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await e.turn?.value
            check("lesson: a POINT that says click is armed as a step", e.lesson?.armed?.label == "model file" && !fake.pause.isShown)
        }
        check("lesson: what counts as asking to click", Tutor.asksToClick("Click Save.") && Tutor.asksToClick("Double-click it.")
              && !Tutor.asksToClick("No need to click anything.") && !Tutor.asksToClick("The clicked file is open."))

        // A double-click step: one click selects, so only the double-click takes it.
        do {
            let (e, _) = lessonSetUp(["[TARGET:200,100,30:mujoco dmg] Double-click the disk image to open it.", "[TARGET:400,300,30:MuJoCo] Now drag MuJoCo."])
            await start(e)
            if let s = e.lesson?.armed { e.stepClicked(at: s.center, clicks: 1) }
            check("double-click step: a single click doesn't take it", e.lesson?.armed?.label == "mujoco dmg" && e.lesson?.stepsTaken == 0)
            if let s = e.lesson?.armed { e.stepClicked(at: s.center, clicks: 2) }
            await e.turn?.value
            check("double-click step: the double-click does", e.lesson?.stepsTaken == 1)
        }

        // A miss in the lesson's app: judge by the screen, so look again (once).
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:Export] Click Export.", "[TARGET:200,100,30:Export] It's still here: click Export."])
            await start(e)
            e.stepClicked(at: CGPoint(x: 1300, y: 100))
            await e.turn?.value
            check("lesson: a miss in the app looks again", e.looksThisStep == 1 && fake.log.contains("working Looking again…")
                  && e.lesson?.armed?.label == "Export")
        }

        // A click in another app: the lesson pauses on its card; Stop ends it.
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:Export] Click Export."])
            await start(e)
            fake.ui.owner = 99
            e.stepClicked(at: CGPoint(x: 1300, y: 100))
            check("lesson: a click in another app pauses it on the card", e.lessonPaused && fake.pause.isShown && e.lesson?.armed == nil)
            e.pauseChoice(.stop)
            check("lesson: Stop on the card ends it", e.lesson == nil && !fake.pause.isShown && fake.log.contains("clear screen"))
        }

        // Work the app can't see: the lesson waits on the card for "I did it".
        do {
            let (e, fake) = lessonSetUp(["[HIGHLIGHT:100,100,400,200:slider] Drag the slider until it looks right, then say continue."])
            await start(e)
            check("lesson: a manual step waits on the card", e.lessonPaused && fake.log.contains("pause card: When you're ready"))
        }

        // A step that's a scroll: it waits for a scroll in the lesson's app, then moves on.
        do {
            let (e, fake) = lessonSetUp(["[POINT:300,500:Export] Scroll down to Export, near the bottom of the panel.",
                                          "[TARGET:300,200,30:Export] There it is: click Export."])
            await start(e)
            check("scroll step: a scroll instruction waits for a scroll, not for continue",
                  e.scrollStep != nil && !e.lessonPaused && fake.caption.kicker == "YOUR MOVE · SCROLL TO EXPORT")
            fake.ui.owner = 99
            e.scrolled(80)
            check("scroll step: scrolling another app doesn't count", e.scrollStep != nil && e.rePlaceWork == nil)
            fake.ui.owner = 42
            e.scrolled(15)
            check("scroll step: a nudge of the wheel doesn't count", e.rePlaceWork == nil)
            fake.ui.shows = false
            e.scrolled(60)
            e.scrollPaused()
            try? await Task.sleep(nanoseconds: 30_000_000)
            check("scroll step: while what they're scrolling to isn't in view, it waits quietly",
                  e.scrollStep != nil && fake.caption.kicker == "KEEP SCROLLING · EXPORT" && e.lesson?.stepsTaken == 0)
            fake.ui.shows = true
            e.scrolled(60)
            e.scrollPaused()
            try? await Task.sleep(nanoseconds: 30_000_000)
            await e.turn?.value
            check("scroll step: scrolling the app moves on to the next step", e.scrollStep == nil && e.lesson?.armed?.label == "Export"
                  && e.lesson?.stepsTaken == 1)
        }
        // A scroll while Navi is still reading the instruction counts: it's armed when the reply arrives.
        do {
            let (e, _) = lessonSetUp(["[POINT:300,500:Export] Scroll down to Export.", "[TARGET:300,200,30:Export] Click Export."])
            e.armActEarly("[POINT:300,500:Export] Scroll down to Export.", inLesson: true, goal: "export")
            check("scroll step: armed as the reply arrives, before it's read", e.scrollStep != nil)
        }
        // A typing step: typing in the lesson's app, then a pause, moves on; and nothing waits silently.
        do {
            let (e, fake) = lessonSetUp(["[POINT:642,286:search] Type export in the search field.",
                                          "[TARGET:300,200,30:Export Vocabulary] Click Export Vocabulary."])
            await start(e)
            check("typing step: a typing instruction waits for typing, and says so",
                  e.typeStep != nil && fake.caption.kicker == "YOUR MOVE · TYPE IT IN")
            e.typed(returnKey: false, pid: 99)
            check("typing step: typing in another app doesn't count", e.typedWork == nil)
            e.typed(returnKey: true, pid: 42)
            e.typedWork?.perform()
            await e.turn?.value
            check("typing step: typing in the app moves on", e.typeStep == nil && e.lesson?.armed?.label == "Export Vocabulary")
        }
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:General] Click General.",
                                          "[HIGHLIGHT:760,425,420,300:list] Have a look through these rows."])
            await start(e)
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await e.turn?.value
            check("lesson: a step Navi can't see waits on the card, never silently", e.lessonPaused && fake.pause.isShown)
        }
        // Errands: an open runs straight away, then Navi looks again and carries on from it.
        do {
            let (e, fake) = lessonSetUp(["[OPEN:https://github.com/apirrone/Open_Duck_Mini] I'll open the repo so we can find the model.",
                                          "[TARGET:300,200,30:model file] There it is: open_duck_mini_v2.xml."])
            await start(e)
            await e.turn?.value
            check("errands: an open runs at once", fake.log.contains("open https://github.com/apirrone/Open_Duck_Mini"))
            check("errands: then it looks again and carries on from the page", e.lesson?.armed?.label == "model file" && e.errandLooks == 1)
            e.errandUntil = Date().addingTimeInterval(5)
            e.appCameForward(pid: 7, name: "Safari", display: 1)
            check("errands: the browser coming forward is the errand, not them leaving", !e.lessonPaused && e.lessonApp == 7)
        }
        do {
            let (e, fake) = lessonSetUp(["[DOWNLOAD:https://raw.githubusercontent.com/a/b/main/model.xml] Shall I grab the model?",
                                          "[OPEN:~/Downloads/model.xml|MuJoCo] Opening it in MuJoCo.", "It's open."])
            await start(e)
            await e.turn?.value
            await e.turn?.value
            check("errands: a download is offered, and once saved Navi carries on",
                  fake.log.contains("offer download https://raw.githubusercontent.com/a/b/main/model.xml")
                  && fake.log.contains("open ~/Downloads/model.xml in MuJoCo"))
            check("errands: a chain of errands stops after three looks", e.errandLooks <= Tutor.errandChain)
        }
        check("errands: the tags parse whole links and an app", TagParser.parse("[OPEN:https://a.com/x?y=1:2|Safari] [OPEN:MuJoCo] [DOWNLOAD:ftp://x] [DOWNLOAD:https://a.com/f.xml]").annotations
              == [.open("https://a.com/x?y=1:2", app: "Safari"), .open("MuJoCo", app: nil), .download("https://a.com/f.xml")])
        check("errands: a lookup's sources, links and code ticks aren't shown",
              TagParser.beats("The file is in the [Open Duck repo](https://github.com/a/b). Run `walk.py`.\n\nSources:\n- [A](https://a.com)\n- [B](https://b.com)\n")
                .map(\.text) == ["The file is in the Open Duck repo. Run walk.py."])
        do {
            let parsed = TagParser.parse("I've copied it.\n[COPY]<<<python walk.py --onnx ~/Downloads/a.onnx>>>\n[NOTE:Open Duck]<<<Weights go in Downloads.>>>\n[REMIND:2026-10-30 09:00]<<<Practise MuJoCo>>>")
            check("keeps: copy, note and reminder blocks are read, and kept out of the words",
                  parsed.keeps == [Keep(kind: .copy, detail: nil, text: "python walk.py --onnx ~/Downloads/a.onnx"),
                                   Keep(kind: .note, detail: "Open Duck", text: "Weights go in Downloads."),
                                   Keep(kind: .remind, detail: "2026-10-30 09:00", text: "Practise MuJoCo")]
                  && parsed.text == "I've copied it.")
            check("show me: a ghost drag parses with its points", TagParser.parse("[SHOWME:100,200;600,400:drag to Applications]").annotations
                  == [.demo([CGPoint(x: 100, y: 200), CGPoint(x: 600, y: 400)], label: "drag to Applications", screen: 0)])
        }
        check("errands: the words around an errand are kept, the tag isn't",
              TagParser.beats("[OPEN:https://a.com] I'll open the page.").first?.text == "I'll open the page.")
        check("review fixes: an apostrophe isn't a quote", Tutor.scrollTarget("Scroll down to Export, it's near the bottom; you'll see it") == "Export")
        check("review fixes: typing means an instruction to type, not the word",
              Tutor.asksToType("Type export in the search field.") && Tutor.asksToType("Then enter your name.")
              && !Tutor.asksToType("Pick the file type you want.") && !Tutor.asksToType("Open the Type menu.")
              && !Tutor.asksToType("Press Enter to confirm."))
        do {
            let (e, _) = lessonSetUp(["[TARGET:200,100,30:Export] Click Export."])
            await start(e)
            e.scrollStep = (Date().addingTimeInterval(60), 1)
            e.errandLooks = 3
            if let s = e.lesson?.armed { e.arm(s) }
            check("review fixes: arming a click step clears a scroll step", e.scrollStep == nil)
        }
        check("scroll step: what it's scrolling to is read from the instruction",
              Tutor.scrollTarget("Scroll down to Rendering, where the Camera dropdown lives.") == "Rendering"
              && Tutor.scrollTarget("Scroll up in the left panel until you see the Group enable section.") == "Group enable"
              && Tutor.scrollTarget("Scroll down until you see \"Hot Corners\".") == "Hot Corners"
              && Tutor.scrollTarget("Scroll down a bit more.") == nil)
        check("scroll step: only an instruction to scroll counts",
              Tutor.asksToScroll("Scroll down to Export.") && Tutor.asksToScroll("Keep scrolling until you see Layers.")
              && !Tutor.asksToScroll("No need to scroll: it's right here.") && !Tutor.asksToScroll("Click the scrollbar's arrow."))
        check("scroll step: not outside a lesson",
              Tutor.afterAnswer(hasStep: false, stepsLeft: 5, drew: true, said: "Scroll down to see the rest.") == .carryOn
              && Tutor.afterAnswer(hasStep: false, stepsLeft: 5, drew: true, said: "Scroll down to Export.", inLesson: true) == .waitForScroll)

        // MARK: Asking and the topic

        /// Asks `q` and waits for the whole turn; returns what was sent to Claude.
        func ask(_ e: Tutor.Engine, _ q: String, marks: Tutor.Engine.Marked? = nil, fromCard: Bool = false) async -> [[String: Any]] {
            var sent: [[String: Any]] = []
            let reply = e.send
            // The question's own turn (an explanation may be followed by a redraw request).
            e.send = { content, kind, onText in if sent.isEmpty { sent = content }; return try await reply(content, kind, onText) }
            e.ask(Tutor.Engine.Asking(question: q, fromCard: fromCard, anchor: .zero, screenshots: { lessonShots },
                                      context: { ("Frontmost app: QGIS", nil) }, marks: marks.map { m in { _ in m } }))
            await e.turn?.value
            e.send = reply
            return sent
        }
        func texts(_ content: [[String: Any]]) -> [String] { content.compactMap { $0["text"] as? String } }

        // A topic is named, carries into the next question, and "new question" clears it.
        do {
            let (e, _) = lessonSetUp(["[TOPIC:Pythagoras] [WRITE:200,200:a² + b² = c²] The long side squared is the sum of the others squared.",
                                       "[TOPIC:Pythagoras] The 3-4-5 triangle is the classic example.", "Sure, what would you like to know?"])
            let conversation = Conversation()
            e.conversation = conversation
            _ = await ask(e, "why is the long side special?")
            check("ask: Claude's topic is kept", e.topic == "Pythagoras" && e.pillText == "Pythagoras")
            let second = await ask(e, "and an example?")
            check("ask: a follow-up carries the topic to Claude", texts(second).contains { $0.contains("Pythagoras") }
                  && texts(second).last == "and an example?")
            _ = await ask(e, "new question: something else")
            check("ask: \"new question\" clears the topic and starts fresh", e.topic == nil && conversation.startFresh)
        }

        // "Let me try" carries a lesson on with the user doing the steps; an unrelated question ends it.
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:Export] Click Export.", "[TARGET:400,300,30:PNG] Your turn: pick the format.",
                                          "Coffee is brewed from roasted beans."])
            _ = await ask(e, "how do I save the map")
            _ = await ask(e, "let me try")
            check("ask: \"let me try\" carries the lesson on, the user trying", e.tryFirst && e.lesson != nil && e.lesson?.armed?.label == "PNG")
            _ = await ask(e, "what's coffee made of?")
            check("ask: an unrelated question ends the lesson", e.lesson == nil && fake.log.contains("lesson ended"))
        }

        // Mark mode: the marks are described and their close-ups go just before the question.
        do {
            let (e, _) = lessonSetUp(["That's the layer's symbol."])
            let marked = Tutor.Engine.Marked(shots: lessonShots, note: "The user marked: 1: circled the area (10, 10)–(50, 50)",
                                             closeUps: [Prompt.text("Close-up of mark 1 (from screen 1):")])
            let sent = await ask(e, "what's this?", marks: marked)
            let t = texts(sent)
            check("ask: marks are described, close-ups just before the question",
                  t.contains { $0.hasPrefix("The user marked") } && t.suffix(2).first?.hasPrefix("Close-up of mark 1") == true && t.last == "what's this?")
        }

        // MARK: The screen moving

        // Scrolling the app under an answer's marks puts them away; scrolling another window doesn't.
        do {
            let (e, fake) = lessonSetUp(["[POINT:200,100:Export] Export is here."])
            _ = await ask(e, "where is export?")
            fake.ui.owner = 99
            e.scrolled(40)
            check("screen: scrolling another window leaves the marks", !fake.log.contains("fade"))
            fake.ui.owner = 42
            e.scrolled(40)
            check("screen: scrolling the app puts the marks away", fake.log.contains("fade"))
        }

        // During a lesson: a scroll that didn't move the step keeps it; one that did re-places it.
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:Export] Click Export.", "[TARGET:200,400,30:Export] Export moved down: click it."])
            await start(e)
            fake.watch.moved = false
            e.scrolled(40)
            try? await Task.sleep(nanoseconds: 900_000_000)
            check("screen: a scroll that didn't move the step keeps it", e.lesson?.armed?.label == "Export" && e.lookPending == false
                  && !fake.log.contains("working Looking again…"))
            fake.watch.moved = true
            e.scrolled(40)
            try? await Task.sleep(nanoseconds: 900_000_000)
            await e.turn?.value
            check("screen: a scroll that moved the step looks again and re-places it", fake.log.contains("working Looking again…")
                  && e.lesson?.armed?.center.y == 700)
        }

        // Another app comes forward mid-answer (no lesson): the rest stops and the marks go.
        do {
            let (e, fake) = lessonSetUp(["[POINT:200,100:Export] Export is here."])
            _ = await ask(e, "where is export?")
            e.beatsPlaying = true
            e.appCameForward(pid: 7, name: "Safari", display: 1)
            check("screen: switching app mid-answer stops it and puts the marks away", !e.beatsPlaying && fake.log.contains("fade"))
        }
    }
}
