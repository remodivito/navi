import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// Checks for what the core split added: the shared files, the tutor's rules
/// pulled out of AppController, and the tap decision on neutral modifiers.
enum NewCoreChecks {
    static func run(_ check: (String, Bool) -> Void) {
        // Shared files
        check("the shared folder is found", SharedFiles.folder != nil)
        let tokenData = SharedFiles.data("design-tokens.json")
        let decoded = tokenData.flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
        check("design-tokens.json reads", decoded != nil)
        check("design-tokens.json matches the built-in values", decoded == Tokens.fallback && Tokens.shared == Tokens.fallback)
        // Split in two: one expression here takes the Linux compiler too long to type-check.
        let hexColour: (Double, Double, Double, Double) = Colour(hex: "#F5F3EE", alpha: 0.62).components
        let hexWanted: (Double, Double, Double, Double) = (245 / 255, 243 / 255, 238 / 255, 0.62)
        let rgbColour: (Double, Double, Double, Double) = Colour(rgb: [0.24, 0.52, 1.0]).components
        let rgbWanted: (Double, Double, Double, Double) = (0.24, 0.52, 1.0, 1)
        check("token colours read hex and fractions", hexColour == hexWanted && rgbColour == rgbWanted)
        let owlData = SharedFiles.data("owl.json")
        let owl = owlData.flatMap { try? JSONDecoder().decode(Owl.Sprite.self, from: $0) }
        check("owl.json reads as a 12×11 grid", owl?.isValid == true)
        check("owl.json matches the built-in owl", owl == Owl.builtIn && Owl.sprite == Owl.builtIn)
        check("every owl letter has a colour", Owl.body.joined().allSatisfy { $0 == "." || Owl.colours[$0] != nil }
              && ["Y", "q", "z", "c", "r"].allSatisfy { Owl.colours[Character($0)] != nil })
        check("a misshapen owl is refused", !Owl.Sprite(grid: ["B"], palette: [:], origin: [0, 0], canvas: [1, 1]).isValid)
        let grammar = SharedFiles.data("tags.md").map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("tags.md describes every tag", ["POINT", "SHAPE", "TARGET", "HOVER", "HIGHLIGHT", "WRITE", "QUIZ", "TYPE", "TRY", "TOPIC", "MOOD", "OUTLINE", "RESUME", "[@"]
              .allSatisfy { grammar.contains($0) })

        // The wait's status line
        do {
            typealias W = Tutor.WaitLine
            let t0 = Date()
            var w = W()
            w.shown("Looking…", at: t0)
            check("wait: the lines are true stages", W.line(for: .sent) == "Reading your screen…"
                  && W.line(for: .thinking(tokens: 50)) == "Thinking…" && W.line(for: .thinking(tokens: 900)) == "Thinking it through…")
            let first = w.want("Reading your screen…", at: t0.addingTimeInterval(0.2))
            if case .later(let d) = first { check("wait: a new line waits until the last has been up long enough", abs(d - (W.hold - 0.2)) < 0.001) }
            else { check("wait: a new line waits until the last has been up long enough", false) }
            check("wait: a later stage replaces one still waiting, without a second timer",
                  w.want("Thinking…", at: t0.addingTimeInterval(0.4)) == .ignore && w.waiting == "Thinking…")
            check("wait: once the hold is over it shows", w.want("Thinking…", at: t0.addingTimeInterval(0.8)) == .show)
            w.shown("Thinking…", at: t0.addingTimeInterval(0.8))
            check("wait: the same line again changes nothing", w.want("Thinking…", at: t0.addingTimeInterval(3)) == .ignore)
            w.end()
            check("wait: after the answer, nothing is held", w.showing == nil && w.want("Thinking…", at: t0.addingTimeInterval(3)) == .show)
            check("wait: still thinking says only that", W.still == "Still thinking…")
        }

        // The tutor's rules
        check("try first: on when asked, kept while carrying on, off for a new question",
              Tutor.tryFirst(after: "let me try", was: false) && Tutor.tryFirst(after: "next", was: true)
              && !Tutor.tryFirst(after: "next", was: false) && !Tutor.tryFirst(after: "how do I export", was: true))
        check("a lesson carries on for continue, try or the card, not a new question or when stale",
              Tutor.carriesOnLesson("continue", stale: false, fromCard: false) && Tutor.carriesOnLesson("where is it", stale: false, fromCard: true)
              && !Tutor.carriesOnLesson("how do I export", stale: false, fromCard: false) && !Tutor.carriesOnLesson("continue", stale: true, fromCard: false))
        check("a correction slows the pen; others restore it", Tutor.confidence(after: "no, the other one", was: 1) == 0.75
              && abs(Tutor.confidence(after: "where is export", was: 0.75) - 0.85) < 1e-9 && Tutor.confidence(after: "ok", was: 0.95) == 1)
        check("after an answer: a step is armed while steps remain",
              Tutor.afterAnswer(hasStep: true, stepsLeft: 3, drew: true, said: "Click Save.") == .armStep
              && Tutor.afterAnswer(hasStep: true, stepsLeft: 0, drew: true, said: "Done.") == .carryOn)
        check("after an answer: manual work waits for continue; nothing drawn finishes",
              Tutor.afterAnswer(hasStep: false, stepsLeft: 5, drew: true, said: "Drag it, then say Continue.") == .waitForContinue
              && Tutor.afterAnswer(hasStep: false, stepsLeft: 5, drew: false, said: "All done.") == .finish)
        check("three steps or more is a celebration", Tutor.celebrates(stepsTaken: 3) && !Tutor.celebrates(stepsTaken: 2))
        check("answers hold long enough to read", Tutor.answerHold(words: 10, speaking: false) == 10
              && Tutor.answerHold(words: 40, speaking: false) == 23 && abs(Tutor.answerHold(words: 40, speaking: true) - 11) < 1e-9)
        check("a diagram lingers after the voice", Tutor.drawingsLinger(drawings: 3) == 4 && Tutor.drawingsLinger(drawings: 1) == 1.5)
        let began = Date()
        check("typed answers reveal at the reply's pace", Tutor.revealRate(chars: 10, since: began) == 6
              && abs(Tutor.revealRate(chars: 110, since: began, now: began.addingTimeInterval(2)) - 10) < 1e-9)
        var moves = Tutor.PracticeMoves()
        for r in ["[TRY:predict] a", "[TRY:gap] b", "[TRY:point] c", "[TRY:predict] d", "[TRY:mistake] e", "[TRY:say it] f", "no move"] { moves.note(r) }
        check("practice moves keep the last four, newest last", moves.recent == ["point", "predict", "mistake", "say it"]
              && moves.note?.hasSuffix("point, predict, mistake, say it.") == true && Tutor.PracticeMoves().note == nil)
        check("turn notes come in order", Tutor.extras(notes: "N", recentMoves: moves, tryFirst: true, topic: "T").count == 4
              && Tutor.extras(notes: nil, recentMoves: Tutor.PracticeMoves(), tryFirst: false).isEmpty
              && Tutor.extras(notes: nil, recentMoves: Tutor.PracticeMoves(), tryFirst: true, topic: "Maps") == [Tutor.tryFirstNote, "Current topic: Maps. The earlier turns are about it."])
        check("a question takes the reply's topic; a step keeps the old one",
              Tutor.topic(after: "Here.", question: true, current: "Old") == nil
              && Tutor.topic(after: "Next.", question: false, current: "Old") == "Old"
              && Tutor.topic(after: "[TOPIC:New] Next.", question: false, current: "Old") == "New")
        check("the pill names the topic and the next step", Tutor.pillText(topic: "QGIS", stepsTaken: 2) == "QGIS · step 3"
              && Tutor.pillText(topic: "QGIS", stepsTaken: 0) == "QGIS" && Tutor.pillText(topic: nil, stepsTaken: 4) == nil)
        var repeats = Tutor.RepeatWatch()
        check("the same question three times is noticed, once", !repeats.note("Where is it?") && !repeats.note("where is it")
              && repeats.note("WHERE is it!") && !repeats.note("where is it"))
        check("coordinates clamp into the screenshot", Tutor.clamp(CGPoint(x: -4, y: 900), in: CGSize(width: 100, height: 800)) == CGPoint(x: 0, y: 800))
        check("a ring as wide as the screen is a box", Tutor.ringLooksLikeSize([CGPoint(x: 400, y: 300), CGPoint(x: 700, y: 500)], in: CGSize(width: 1200, height: 800))
              && !Tutor.ringLooksLikeSize([CGPoint(x: 400, y: 300), CGPoint(x: 440, y: 300)], in: CGSize(width: 1200, height: 800)))
        let shots = [(1, false), (2, true)]
        check("screen 0 is the cursor's, others by number", Tutor.shot(0, in: shots, index: \.0, hasCursor: \.1).0 == 2
              && Tutor.shot(1, in: shots, index: \.0, hasCursor: \.1).0 == 1 && Tutor.shot(7, in: shots, index: \.0, hasCursor: \.1).0 == 2)
        check("lesson events name the step", Tutor.stepEvent("Save", hovered: false, step: 2) == "the user clicked \"Save\" (step 2)."
              && Tutor.stepLog("Save", hovered: true, quiz: nil) == "Hovered over \"Save\"" && Tutor.quizEvent("c", right: true).contains("found it themselves"))
        var binding = Tutor.ColourBinding(on: true, count: 4)
        check("explanation colours go in order and stay", binding.index(for: .point(.zero, label: "leg a", screen: 0)) == 0
              && binding.index(for: .point(.zero, label: "b", screen: 0)) == 1 && binding.index(for: .point(.zero, label: "Leg A", screen: 0)) == 0
              && binding.index(for: .write(.zero, text: "a + b", screen: 0)) == nil && binding.letterIndex == ["a": 0, "b": 1])
        var off = Tutor.ColourBinding(on: false, count: 4)
        check("pointing answers stay ink (no colour index)", off.index(for: .point(.zero, label: "a", screen: 0)) == nil)

        // The prompt's turn, from encoded screens
        let jpeg = Data([0xFF, 0xD8])
        let turn = Prompt.turn(screens: [Prompt.Screen(index: 1, hasCursor: false, width: 10, height: 20, jpeg: jpeg),
                                         Prompt.Screen(index: 2, hasCursor: true, width: 30, height: 40, jpeg: jpeg)],
                               context: "QGIS", gesture: nil, message: "where?", extras: ["note"])
        check("a turn labels each screen, then context, extras and the question",
              (turn[0]["text"] as? String) == "Screen 1 of 2 (no cursor): 10×20 px"
              && (turn[2]["text"] as? String) == "Screen 2 of 2 (the cursor is here): 30×40 px"
              && (turn[4]["text"] as? String) == "Context from the user's \(Platform.current.computer):\nQGIS" && (turn.last?["text"] as? String) == "where?" && turn.count == 8
              && ((turn[6]["text"] as? String)?.hasPrefix("Now: ") ?? false))
        check("one screen is the user's screen", Prompt.label(index: 1, hasCursor: true, of: 1) == "Screen 1 (the cursor is here)")

        // The tap decision on neutral modifiers
        let decider = TapDecider()
        var taps = 0
        decider.onTrigger = { taps += 1 }
        let t0 = Date()
        decider.flags(keyCode: 61, mods: .option, at: t0); decider.flags(keyCode: 61, mods: [], at: t0.addingTimeInterval(0.1))
        decider.flags(keyCode: 61, mods: [.option, .shift], at: t0.addingTimeInterval(1)); decider.flags(keyCode: 61, mods: [], at: t0.addingTimeInterval(1.1))
        check("the core's tap decision: right ⌥ alone taps, with ⇧ it doesn't", taps == 1)

        // Claude's connection: Navi's token goes to `claude`, an API key never does.
        final class TestSecrets: Shell.Secrets { var claudeToken: String? = "sk-ant-oat01-test"; var apiKey: String? = nil }
        final class TestLocator: Shell.ClaudeLocator {
            func executable() -> String? { "/opt/claude/bin/claude" }
            func path(for exe: String, inherited: String?) -> String { "/opt/claude/bin:" + (inherited ?? "") }
        }
        let (oldSecrets, oldLocator) = (ClaudeAccess.secrets, ClaudeAccess.locator)
        ClaudeAccess.secrets = TestSecrets()
        ClaudeAccess.locator = TestLocator()
        #if !os(Windows)   // setenv is POSIX; Windows checks the token and PATH only
        setenv("ANTHROPIC_API_KEY", "sk-ant-api-should-not-pass", 1)
        #endif
        let env = ClaudeAccess.environment(for: "/opt/claude/bin/claude")
        #if !os(Windows)
        unsetenv("ANTHROPIC_API_KEY")
        #endif
        check("claude gets Navi's own token and its PATH, never an API key",
              env["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-test" && env["ANTHROPIC_API_KEY"] == nil
              && env["PATH"]?.hasPrefix("/opt/claude/bin:") == true && ClaudeAccess.executable() == "/opt/claude/bin/claude")
        (ClaudeAccess.secrets, ClaudeAccess.locator) = (oldSecrets, oldLocator)

        // A mark dropped mid-sentence keeps the sentence whole.
        let split = TagParser.beats("Almost. This key won't be shown again, so [TARGET:889,752,45:copy key] click Copy key first and paste it somewhere safe. Then press Done.")
        check("a mark mid-sentence doesn't split the sentence",
              split.count == 2 && split[0].text == "Almost. This key won't be shown again, so click Copy key first and paste it somewhere safe."
              && split[1].text == "Then press Done." && split[1].annotation == nil)
        let ended = TagParser.beats("Open the menu. [POINT:10,10:menu] It's here.")
        check("a mark after a full sentence still starts its own beat", ended.count == 2 && ended[0].text == "Open the menu.")

        // The shell protocols: a shell with no screen at all can play every part.
        let fake = FakeShell(screens: 2)
        let overlay: any Shell.Overlay = fake.overlay
        overlay.drawTarget(CGPoint(x: 1600, y: 300), radius: 30, label: "Export", snapped: nil, hover: false, on: 2, delay: 0)
        check("an overlay through the protocol draws a step on the right display",
              fake.log.last == "target 1600,300 r30 Export on 2" && overlay.hasDrawings && overlay.markAreas.count == 1)
        let caption: any Shell.Caption = fake.caption
        var lit = 0
        caption.onWordLit = { _ in lit += 1 }
        caption.read("Click Export to save it.", named: ["Export"], at: .zero, near: nil, wordsPerSecond: 6,
                     colour: nil, practice: false, stay: false, pauses: [])
        check("a caption through the protocol reads a sentence and reports each word", lit == 5 && caption.isShowing)
        var answer: String?, help: Shell.AnswerHelp?
        caption.onAnswer = { answer = $0 }
        caption.onHelp = { help = $0 }
        caption.takeAnswer()
        fake.caption.type("13")
        fake.caption.ask(.hint)
        check("Your turn's answer line reports the answer and a request for a hint",
              caption.answering && answer == "13" && help == .hint)
        let shot: any Shell.Screenshot = FakeShell.Shot(screenID: 2, index: 2, hasCursor: false, origin: CGPoint(x: 1440, y: 0))
        let spot = CGPoint(x: 100, y: 200)
        check("a screenshot maps pixels to global points and back", shot.pixel(shot.global(spot)) == spot
              && shot.global(spot) == CGPoint(x: 1490, y: 800))
        let screens: any Shell.ScreenSource = fake.screens
        check("screens report their frames, and none for a display that's gone",
              screens.frame(of: 2) == CGRect(x: 1440, y: 0, width: 1440, height: 900) && screens.frame(of: 3) == nil)
    }
}
