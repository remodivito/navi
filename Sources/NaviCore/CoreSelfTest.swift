import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// The checks on NaviCore's logic, without XCTest. `--selftest` runs these first,
/// then the Mac app's own; a Windows shell can run the same function.
public enum CoreSelfTest {
    public static func run(_ check: (String, Bool) -> Void) {
        // Tags
        let reply = """
        [POINT:120,210:Add button]
        [SHAPE:circle:400,300;440,300:the chart]
        [SHAPE:arrow:10,10; 50.5,60 :drag here]
        Click Add, then drag the chart.
        """
        let r = TagParser.parse(reply)
        check("three annotations", r.annotations.count == 3)
        check("point", r.annotations.first == .point(CGPoint(x: 120, y: 210), label: "Add button", screen: 0))
        check("circle", r.annotations[1] == .shape(.circle, [CGPoint(x: 400, y: 300), CGPoint(x: 440, y: 300)], label: "the chart", screen: 0))
        check("arrow with spaces and decimals", r.annotations[2] == .shape(.arrow, [CGPoint(x: 10, y: 10), CGPoint(x: 50.5, y: 60)], label: "drag here", screen: 0))
        check("text stripped of tags", r.text == "Click Add, then drag the chart.")

        let bare = TagParser.parse("[point:5,6] Here.")
        check("no label, lowercase tag", bare.annotations == [.point(CGPoint(x: 5, y: 6), label: nil, screen: 0)] && bare.text == "Here.")

        let bad = TagParser.parse("[SHAPE:polygon:1,1;2,2:too few] [SHAPE:arrow:1,1] [POINT:x,y] [TARGET:1,2] Nothing to draw.")
        check("malformed tags ignored", bad.annotations.isEmpty && bad.text == "Nothing to draw.")

        let inline = TagParser.parse("Look here [POINT:1,2:a] and there [SHAPE:line:0,0;9,9].")
        check("inline tags keep order and tidy spacing", inline.annotations.count == 2 && inline.text == "Look here and there.")

        let screens = TagParser.parse("[POINT:10,20:Save:screen2]\n[TARGET:5,6,30:screen3]\n[POINT:1,1:screen 2]")
        check("screen suffix with label", screens.annotations.first == .point(CGPoint(x: 10, y: 20), label: "Save", screen: 2))
        check("target with screen, no label", screens.annotations[1] == .target(CGPoint(x: 5, y: 6), radius: 30, label: nil, screen: 3))
        check("screen suffix with a space", screens.annotations[2].screen == 2)

        let typed = TagParser.parse("Drafted it.\n[TYPE:300,400:screen2]<<<\nHi Sam,\nSounds good.\n>>>")
        check("type block parsed", typed.typing == TypeRequest(text: "Hi Sam,\nSounds good.", at: CGPoint(x: 300, y: 400), screen: 2))
        check("type block hidden from text", typed.text == "Drafted it.")
        check("type without coordinates", TagParser.parse("[TYPE]<<<hello>>>").typing == TypeRequest(text: "hello", at: nil, screen: 0))

        let streaming = TagParser.parse("[POINT:10,20:Save]\nClick Save [SHAPE:arrow:1,2;3")
        check("streaming: finished tag drawn, unfinished hidden", streaming.annotations.count == 1 && streaming.text == "Click Save")
        let streamingType = TagParser.parse("Here you go [TYPE]<<<Dear te")
        check("streaming: open TYPE block hidden", streamingType.text == "Here you go" && streamingType.typing == nil)

        // The tag grammar: HIGHLIGHT, HOVER, default radius, POINT:none
        let hh = TagParser.parse("[HIGHLIGHT:10,20,100,50:work area] [HOVER:5,6:menu] [TARGET:7,8:save] [POINT:none] [HIGHLIGHT:1,2,3,4]")
        check("highlight parsed", hh.annotations.first == .highlight(CGRect(x: 10, y: 20, width: 100, height: 50), label: "work area", screen: 0))
        check("hover with default radius 74", hh.annotations.count > 1 && hh.annotations[1] == .hover(CGPoint(x: 5, y: 6), radius: 74, label: "menu", screen: 0))
        check("target with default radius 74", hh.annotations.count > 2 && hh.annotations[2] == .target(CGPoint(x: 7, y: 8), radius: 74, label: "save", screen: 0))
        check("POINT:none and label-less HIGHLIGHT draw nothing", hh.annotations.count == 3)

        // Beats: tag-first lines, text-then-tag, a plain tail
        let beats = TagParser.beats("[TARGET:120,210,40:add] Click Add Modifier.\n[POINT:5,6:knob] Then this knob.\nThat's it.")
        check("three beats", beats.count == 3)
        check("tag-first beat takes its line", beats.first?.text == "Click Add Modifier." && beats.first?.annotation?.isStep == true)
        check("second beat", beats.count > 1 && beats[1].text == "Then this knob." && beats[1].annotation?.label == "knob")
        check("plain tail beat", beats.last == Beat(text: "That's it.", annotation: nil))
        let ownLine = TagParser.beats("[HIGHLIGHT:0,38,264,977:sidebar]\nOn the left is the sidebar.\n\n[SHAPE:arrow:1,2;3,4:to]\nIt leads here.")
        check("tag on its own line takes the next line", ownLine.count == 2 && ownLine[0].text == "On the left is the sidebar."
            && ownLine[0].annotation?.label == "sidebar" && ownLine[1].text == "It leads here.")
        let preface = TagParser.beats("I think you mean the panel.\n[HIGHLIGHT:1,2,3,4:panel] This is the panel.\n[POINT:5,6:x] And this.")
        check("preface line is its own beat", preface.count == 3 && preface[0].annotation == nil
            && preface[1].text == "This is the panel." && preface[1].annotation?.label == "panel")
        let inlineBeats = TagParser.beats("Open the File menu [POINT:10,10:File] and pick Export [POINT:40,90:Export].")
        check("text-then-tag beats", inlineBeats.count == 2 && inlineBeats[0].text == "Open the File menu" && inlineBeats[1].text == "and pick Export.")
        let streamingBeats = TagParser.beats("[POINT:1,2:a] First.\n[TARGET:3,4")
        check("streaming: unfinished tag left out", streamingBeats.count == 1 && streamingBeats[0].text == "First.")
        check("tags stripped from beat text", TagParser.beats("Say [HOVER:1,2,3:x] hi").allSatisfy { !$0.text.contains("[") })

        // Lesson rules
        check("radius clamps to 28…180 pt", Walkthrough.Step.radius(image: 5, scale: 2) == 28 && Walkthrough.Step.radius(image: 500, scale: 2) == 180
            && Walkthrough.Step.radius(image: 40, scale: 2) == 80)
        let t0 = Date()
        let step = Walkthrough.Step(center: CGPoint(x: 100, y: 100), radius: 40, label: "Save", hover: false, display: 1, sentence: "", armedAt: t0)
        check("click inside the radius hits", step.judge(click: CGPoint(x: 130, y: 100), now: t0, graceUntil: nil) == .hit)
        check("click outside misses", step.judge(click: CGPoint(x: 160, y: 100), now: t0, graceUntil: nil) == .miss)
        check("clicks in the 1.4 s grace are ignored", step.judge(click: CGPoint(x: 100, y: 100), now: t0, graceUntil: t0.addingTimeInterval(1.4)) == .ignore)
        check("targets last 5 minutes, not 90 s", step.judge(click: CGPoint(x: 100, y: 100), now: t0.addingTimeInterval(91), graceUntil: nil) == .hit
              && step.judge(click: CGPoint(x: 100, y: 100), now: t0.addingTimeInterval(301), graceUntil: nil) == .expired)
        let icon = Walkthrough.Step(center: CGPoint(x: 300, y: 300), radius: 28, label: "Zoom In", hover: false, display: 1, sentence: "", armedAt: t0)
        check("small icons forgive a click 34 pt off", icon.judge(click: CGPoint(x: 334, y: 300), now: t0, graceUntil: nil) == .hit
              && icon.judge(click: CGPoint(x: 360, y: 300), now: t0, graceUntil: nil) == .miss)

        var rest = Walkthrough.HoverRest()
        var fired = 0
        for i in 1...20 { if rest.sample(CGPoint(x: 105, y: 95), on: step) { fired = i; break } }
        check("hover fires after 2 s of rest (17 samples of 0.12 s)", fired == 17)
        var rest2 = Walkthrough.HoverRest()
        _ = rest2.sample(CGPoint(x: 105, y: 95), on: step)
        check("moving off resets the hover", !rest2.sample(CGPoint(x: 400, y: 400), on: step) && rest2.rested == 0)

        let lesson = Walkthrough(goal: "export a PDF")
        lesson.record("Clicked \"File\"")
        let msg = lesson.message(event: "the user clicked \"Export\" (step 2).")
        check("lesson message has goal, log and event", msg.contains("Goal: export a PDF") && msg.contains("1. Clicked \"File\"") && msg.contains("Just now: the user clicked"))
        for _ in 0..<14 { lesson.record("x") }
        check("15-step limit says wrap up", lesson.stepsLeft == 0 && lesson.message(event: "e").contains("step limit"))
        check("continuation words", Tutor.isContinuation("Continue") && Tutor.isContinuation("ok, done") == false
            && Tutor.isContinuation("next step please") && Tutor.isContinuation("done") && !Tutor.isContinuation("how do I export"))

        // Explanations must be drawn, not summarised
        check("explain intent", Tutor.wantsExplanation("Explain what I'm looking at") && Tutor.wantsExplanation("how does this work?")
            && !Tutor.wantsExplanation("where is the save button"))
        check("one highlight is too thin", Tutor.explanationGap("[HIGHLIGHT:1,2,3,4:x] It's a chat.") != nil)
        check("frame, parts and a connector pass", Tutor.explanationGap(
            "[HIGHLIGHT:0,0,100,100:app] The app.\n[SHAPE:circle:10,10;20,10:a] A part.\n[SHAPE:arrow:10,10;50,50:to b] Leads here.") == nil)
        check("only marking what's there is flagged", Tutor.explanationGap(
            "[HIGHLIGHT:0,0,100,100:app] A.\n[SHAPE:circle:10,10;20,10:a] B.\n[POINT:5,5:c] C.")?.contains("constructions") == true)
        check("written working counts as constructed", Tutor.explanationGap(
            "[SHAPE:polygon:1,1;5,1;5,5:sq] A.\n[WRITE:10,10:3² + 4² = 25] B.\n[POINT:5,5:c] C.") == nil)
        check("WRITE parses, keeps colons", TagParser.parse("[WRITE:10,20:ratio 1:2]").annotations.first == .write(CGPoint(x: 10, y: 20), text: "ratio 1:2", screen: 0))

        // Skills
        let note = Skills.parse("apps: Finder, com.apple.finder\nsites: docs.google.com\n\nThe sidebar is on the left.", name: "Finder")
        check("skill header parsed", note.apps == ["finder", "com.apple.finder"] && note.sites == ["docs.google.com"]
              && note.body == "The sidebar is on the left." && !note.byNavi)
        check("skill matches by bundle id", Skills.matching([note], bundleID: "com.apple.finder", appName: nil, host: nil).count == 1)
        check("skill matches a subdomain", Skills.matching([note], bundleID: nil, appName: nil, host: "x.docs.google.com").count == 1)
        check("skill ignores other apps", Skills.matching([note], bundleID: "com.apple.Safari", appName: "Safari", host: "google.com").isEmpty)
        SkillChecks.files(check)

        // The prompt names the computer
        let macPrompt = Prompt.system(for: .mac), winPrompt = Prompt.system(for: .windows)
        check("the Mac prompt is the Mac's", macPrompt.contains("at their Mac,") && macPrompt.contains("the Mac's display order")
              && !macPrompt.contains("ON WINDOWS"))
        check("the Windows prompt never mentions a Mac", winPrompt.contains("at their PC,") && winPrompt.contains("Windows' display order")
              && winPrompt.hasSuffix("right-clicking opens a menu of actions for the thing under the pointer.") && !winPrompt.contains("Mac"))

        // The owl
        let soon = Date().addingTimeInterval(1)
        check("a reaction shows over the state", Owl.resolve(state: .thinking, reaction: (.happy, soon), now: Date()) == .happy)
        check("listening is never interrupted", Owl.resolve(state: .listening, reaction: (.happy, soon), now: Date()) == .listening)
        check("a finished reaction gives way", Owl.resolve(state: .idle, reaction: (.happy, Date().addingTimeInterval(-1)), now: Date()) == .idle)
        check("every mood draws a full owl", Owl.Mood.allCases.allSatisfy { m in [0, 0.7, 2.3].allSatisfy { t in
            let f = Owl.frame(m, at: t); return f.grid.count == 11 && f.grid.allSatisfy { $0.count == 12 } } })
        check("Reduce Motion: expressions but no movement", Owl.Mood.allCases.allSatisfy { let f = Owl.frame($0, at: 0.3, still: true); return f.dx == 0 && f.dy == 0 })
        check("MOOD is read and never shown", TagParser.mood("[MOOD:wow] [POINT:1,2:x] Look at this!") == "wow"
              && TagParser.beats("[MOOD:wow] [POINT:1,2:x] Look at this!").first?.text == "Look at this!")

        // Topics
        check("TOPIC is read and never shown", TagParser.topic("[TOPIC:Pythagoras] [WRITE:1,2:a² + b² = c²] Square both legs.") == "Pythagoras"
              && TagParser.beats("[TOPIC:Pythagoras] [WRITE:1,2:a² + b² = c²] Square both legs.").first?.text == "Square both legs."
              && !TagParser.parse("[TOPIC:QGIS: first project]\nClick here.").text.contains("TOPIC"))
        check("no TOPIC, no topic", TagParser.topic("[POINT:1,2:export] Here.") == nil)
        check("new question starts fresh", Tutor.wantsFresh("ok new question: where's export?") && !Tutor.wantsFresh("why is that?"))

        // Tours: the light points as words are read
        let tour = TagParser.beats("[HIGHLIGHT:1,2,300,400:strip] Each strip has [@97,80]gain at the top, [@97,114] pan below it.")
        check("anchors become stops on their words", tour.first?.stops == [Beat.Stop(word: 3, point: CGPoint(x: 97, y: 80)), Beat.Stop(word: 7, point: CGPoint(x: 97, y: 114))])
        check("anchors never show", tour.first?.text == "Each strip has gain at the top, pan below it." && !TagParser.parse("See [@1,2]here.").text.contains("@"))
        check("a half-streamed anchor is hidden", TagParser.beats("Look at [@97,8").first?.text == "Look at")

        // Mark mode: rough strokes become clean marks
        let loop = (0...36).map { i -> CGPoint in let a = Double(i) / 36 * 2 * .pi; return CGPoint(x: 300 + 60 * cos(a) + Double(i % 3), y: 300 + 40 * sin(a)) }
        check("a rough loop becomes a ring", Mark.tidy(loop)?.kind == .ring)
        check("a flat straight stroke is an underline", Mark.tidy((0...20).map { CGPoint(x: 100 + Double($0) * 8, y: 200 + Double($0 % 2)) })?.kind == .underline)
        check("a stroke that goes somewhere is an arrow", Mark.tidy((0...20).map { CGPoint(x: 100 + Double($0) * 6, y: 200 + Double($0) * 5) })?.kind == .arrow)
        check("a tap is a point", Mark.tidy([CGPoint(x: 50, y: 50), CGPoint(x: 52, y: 51)])?.kind == .point)
        check("a zigzag is a scribble", Mark.tidy((0...40).map { CGPoint(x: 100 + Double($0 % 2) * 60, y: 100 + Double($0)) })?.kind == .scribble)
        check("nothing is no mark", Mark.tidy([]) == nil)
        // Sign-in failures say what to do
        check("an expired Claude Code sign-in is recognised", ConnectionProblem(cliText: "Failed to authenticate: OAuth session expired and could not be refreshed") == .signInExpired)

        // Navi's own sign-in: the token in setup-token's output
        // A made-up token, built in pieces so secret scanners don't mistake it for a real one.
        let tok = "sk-ant-" + "oat01-" + String(repeating: "Ab3_dE-fGh", count: 9)
        check("the token is found among colour codes", SignIn.token(in: "\u{1B}[32m✓ Long-lived token created\u{1B}[0m\n\n" + tok + "\n\nStore this token securely.") == tok)
        check("a token wrapped by the terminal is joined up", SignIn.token(in: "Your token:\n" + tok.prefix(60) + "\n" + tok.dropFirst(60) + "\n") == tok)
        check("a wrapped token doesn't swallow the next paragraph", SignIn.token(in: tok.prefix(60) + "\r\n" + tok.dropFirst(60) + "\r\n\r\nStore this token securely.") == tok)
        // What setup-token really printed in an 80-column pseudo-terminal (with a made-up token).
        let real = "✓Long-livedauthenticationtokencreatedsuccessfully!\r\r Your OAuth token (valid for 1 year):\r\r " + tok.prefix(77)
            + "\r " + tok.dropFirst(77) + "\rStore thistoken securely. You won't be able to see t again.\r\r"
        check("a token wrapped with a carriage return and indent is joined up", SignIn.token(in: real) == tok)
        check("logged output never holds the token", !SignIn.redacted(real).contains(String(tok.prefix(20))))
        check("no token yet, no token", SignIn.token(in: "Opening browser to sign in…") == nil)

        // Greetings
        let noon = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        check("greetings mention the app in front", Greeting.choices(app: "QGIS", topic: nil, marked: false, now: noon).contains("Ask about QGIS"))
        check("a topic gets follow-up greetings", Greeting.choices(app: nil, topic: "Pythagoras", marked: false, now: noon).contains("More on Pythagoras, or something new"))
        check("never the same greeting twice in a row", Greeting.pick(now: noon) != Greeting.pick(now: noon))
        check("a greeting that doesn't fit the bar isn't picked",
              (0..<20).allSatisfy { _ in Greeting.pick(topic: "Pythagoras", now: noon) { $0.count <= 22 }.count <= 22 })
        check("with no room at all, the shortest greeting still shows",
              Greeting.pick(topic: "Pythagoras", now: noon) { _ in false } == "Ask a follow-up")
        check("greetings don't quiz or chirp", !(Greeting.choices(app: "QGIS", topic: "Pythagoras", marked: false, now: noon)
              + Greeting.choices(app: "QGIS", topic: nil, marked: false, now: noon)).contains { $0.contains("Make sense") || $0.contains("!") })

        // Reading pace
        check("a 15-word sentence holds about 4.5 s", abs(Tutor.readingTime(words: 15) - 4.55) < 0.01)
        check("long sentences cap at 10 s", Tutor.readingTime(words: 60) == 10)

        // Away and back
        typealias R = Tutor.Reaction

        func react(_ c: Tutor.Change, app: Bool, screen: Bool = true, paused: Bool = false, looks: Int = 0) -> R {
            Tutor.reaction(to: c, inLessonApp: app, onLessonScreen: screen, paused: paused, looks: looks)
        }
        check("leaving for another app pauses", react(.switched, app: false) == .pause)
        check("coming back to a paused lesson looks again", react(.switched, app: true, paused: true) == .look)
        check("an app on another display leaves the lesson alone", react(.switched, app: false, screen: false) == .ignore)
        check("going full screen in the lesson app looks again", react(.space, app: true) == .look)
        check("a Space change to elsewhere pauses", react(.space, app: false) == .pause)
        check("a click elsewhere in the app looks again", react(.miss, app: true) == .look)
        check("looks stop after three", react(.miss, app: true, looks: 3) == .ignore)
        check("a click in another app pauses", react(.miss, app: false) == .pause)

        // A dialog over the step
        typealias W = Tutor.ScreenWindow
        let main = W(id: 1, pid: 50, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), name: "QGIS")
        let dialog = W(id: 2, pid: 50, layer: 0, bounds: CGRect(x: 300, y: 200, width: 600, height: 400), name: "Data Source Manager")
        let aside = W(id: 3, pid: 50, layer: 0, bounds: CGRect(x: 900, y: 600, width: 200, height: 100), name: "Aside")
        let tip = W(id: 4, pid: 50, layer: 0, bounds: CGRect(x: 480, y: 380, width: 60, height: 20), name: "tooltip")
        let menu = W(id: 5, pid: 50, layer: 101, bounds: CGRect(x: 400, y: 300, width: 300, height: 300), name: "menu")
        let ours = W(id: 6, pid: 99, layer: 0, bounds: CGRect(x: 400, y: 300, width: 300, height: 300), name: "caption")
        let alert = W(id: 7, pid: 77, layer: 8, bounds: CGRect(x: 400, y: 300, width: 300, height: 200), name: "SecurityAgent")
        let centre = CGPoint(x: 500, y: 400)
        func over(_ ws: [W], _ base: Set<UInt32> = [1]) -> W? { Tutor.newWindowOver(centre, in: ws, baseline: base, ownPID: 99) }
        check("a new dialog over the step is seen", over([dialog, main]) == dialog)
        check("the step's own window isn't", over([main]) == nil)
        check("a dialog already there when armed isn't", over([dialog, main], [1, 2]) == nil)
        check("a new window elsewhere isn't", over([aside, main]) == nil)
        check("tooltips, menus and our own windows aren't", over([tip, menu, ours, main]) == nil)
        check("a system alert over the step is seen", over([alert, main]) == alert)
        var watch = Tutor.DialogWatch(baseline: [1])
        let t = Date()
        let first = watch.sample([dialog, main], centre: centre, ownPID: 99, now: t)
        let early = watch.sample([dialog, main], centre: centre, ownPID: 99, now: t.addingTimeInterval(0.5))
        let reported = watch.sample([dialog, main], centre: centre, ownPID: 99, now: t.addingTimeInterval(1.0))
        let again = watch.sample([dialog, main], centre: centre, ownPID: 99, now: t.addingTimeInterval(1.5))
        check("a dialog is reported after it stays 0.8 s, once", first == nil && early == nil && reported == dialog && again == nil)
        var flick = Tutor.DialogWatch(baseline: [1])
        _ = flick.sample([dialog, main], centre: centre, ownPID: 99, now: t)
        _ = flick.sample([main], centre: centre, ownPID: 99, now: t.addingTimeInterval(0.5))
        check("a window that flickers away starts the wait again", flick.sample([dialog, main], centre: centre, ownPID: 99, now: t.addingTimeInterval(1.0)) == nil)

        // Slow apps
        check("settle starts at 4 s", Tutor.settleTimeout(remembered: nil) == 4)
        check("a slow app starts a little longer", Tutor.settleTimeout(remembered: 6.5) == 7.5)
        check("never more than 10 s", Tutor.settleTimeout(remembered: 9.8) == 10)
        check("a quick settle is forgotten", Tutor.rememberedSettle(took: 1.2) == nil && Tutor.rememberedSettle(took: 6.5) == 6.5)

        // "Let me try"
        check("let me try is heard", Tutor.wantsToTry("Let me try it") && Tutor.wantsToTry("ok can I try?")
              && Tutor.wantsToTry("I'll have a go"))
        check("other questions aren't", !Tutor.wantsToTry("how do I add a buffer") && !Tutor.wantsToTry("try the other menu"))

        // Practice moves
        let tried = TagParser.parse("Nice.\n[TRY:your turn] Now find the hypotenuse of a 6, 8 triangle.")
        check("TRY names the move", TagParser.practiceMove("ok\n[TRY:Your Turn] go") == "your turn")
        check("TRY is never shown", !tried.text.contains("TRY") && tried.text.hasSuffix("6, 8 triangle."))
        check("no TRY, no move", TagParser.practiceMove("Just an answer.") == nil)
        let quiz = TagParser.parse("[QUIZ:300,200,40:the save button:screen1] Which one saves?")
        check("QUIZ parses as an invisible step", quiz.annotations.first == .quiz(CGPoint(x: 300, y: 200), radius: 40, label: "the save button", screen: 1) && quiz.annotations.first?.isStep == true)
        check("QUIZ beat keeps its question", TagParser.beats("[TRY:point] [QUIZ:1,2,30:x] Which one saves?").first?.text == "Which one saves?")

        let pb = TagParser.beats("[SHAPE:circle:1,2;3,4:x] Here it is.\n[TRY:your turn] [WRITE:5,6:2 + 2 = ?] Your turn: what's 2 + 2?")
        let own = TagParser.beats("[WRITE:1,2:25 = c²]\nSo c is 5.\n[TRY:predict] What if the legs doubled?")
        check("a practice line isn't swallowed by the tag above it", own.count == 2 && own[0].text == "So c is 5." && own[1].practice && !own[0].practice)
        let late = TagParser.beats("[SHAPE:line:1,2;3,4:c] The long side.\n[TRY:point] Click the hypotenuse.\n[QUIZ:5,6,30:hypotenuse]")
        check("a QUIZ after the question is still practice", late.count == 3 && late[1].practice && late[2].practice && !late[0].practice)
        check("practice marking survives an inline tag", TagParser.beats("[TRY:gap] [WRITE:1,2:3 + ___] What goes in the gap?").first?.practice == true)
        check("practice beats are marked, the explanation isn't", pb.count == 2 && !pb[0].practice && pb[1].practice)

        // Sketch
        let ring = Sketch.polyline(.circle, [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 100)], sketchy: false)
        let radii = ring.map { hypot($0.x - 100, $0.y - 100) }
        check("circle polyline stays on its radius", radii.allSatisfy { $0 > 37 && $0 < 41 })
        let line = Sketch.polyline(.line, [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0)], sketchy: true)
        let wobbled = Sketch.jitter(line, seed: 42)
        check("jitter is small", zip(line, wobbled).allSatisfy { abs($0.y - $1.y) < 3.5 && abs($0.x - $1.x) < 3.5 })
        check("jitter is deterministic", wobbled == Sketch.jitter(line, seed: 42))
        let curve = Sketch.polyline(.curve, [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)], sketchy: false)
        check("curve ends at its last point", curve.last.map { hypot($0.x - 100, $0.y) < 0.5 } ?? false)

        // Conversation context
        let turnContent = [Prompt.text("Screen 1 (cursor is here): 10×10 px"), Prompt.image(Data([0xFF, 0xD8])), Prompt.text("q")]
        let kept = Conversation.shots(in: turnContent)
        check("a turn's screenshots keep their labels", kept.count == 2 && (kept[0]["text"] as? String)?.hasPrefix("Screen 1") == true)
        let prev = Conversation.previousBlock(kept, age: 30)
        check("previous screenshot is relabelled", (prev[1]["text"] as? String)?.hasPrefix("Previous screen 1") == true
              && (prev.last?["text"] as? String) == "The screen now:")
        let ex = [Conversation.Exchange(said: "Where is Wi-Fi?", reply: "[POINT:10,10:Wi-Fi] Top right.", at: Date())]
        let recap = Conversation.recap(ex, lesson: false)
        check("recap keeps question and reply, the reply as its words", recap.contains("User: Where is Wi-Fi?") && recap.contains("You: Top right.")
              && !recap.contains("[POINT"))
        check("recap says to ignore it when unrelated", recap.contains("only if the new question clearly refers to it"))
        check("lesson recap is the last reply only", Conversation.recap(ex, lesson: true).hasSuffix("[POINT:10,10:Wi-Fi] Top right.")
              && !Conversation.recap(ex, lesson: true).contains("Where is Wi-Fi"))

        // History
        check("history label: screen and size", History.parse(label: "Screen 2 (cursor is here): 1568×1015 px") == (2, 1568, 1015))
        check("history label: previous screen gets no marks", History.parse(label: "Previous screen 1 (cursor is here): 10×20 px").0 == 0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sp-history-\(UUID().uuidString)")
        let store = History(folder: tmp)
        let tid = store.begin(title: "Where is Wi-Fi?")
        store.record(thread: tid, kind: "question", action: "fresh",
                     content: [Prompt.text("Screen 1 (cursor is here): 10×10 px"), Prompt.image(Data([0xFF, 0xD8])), Prompt.text("Where is Wi-Fi?")],
                     reply: "[POINT:1,2:Wi-Fi] Top right.", error: nil, stats: nil)
        let saved = store.transcript(tid)
        check("history records the turn", saved?.turns.count == 1 && saved?.turns.first?.sent.last == "Where is Wi-Fi?"
              && saved?.turns.first?.shots.first?.screen == 1)
        check("history screenshots only in dev builds", (saved?.turns.first?.shots.first?.file != nil) == History.keepsScreenshots)
        check("history index reloads", History(folder: tmp).threads().first?.preview == "Top right.")
        store.prune(now: Date().addingTimeInterval(History.keepFor + 60))
        check("history prunes after a week", store.threads().isEmpty && store.transcript(tid) == nil)
        let shotDir = tmp.appendingPathComponent("t1", isDirectory: true)
        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try? Data([1]).write(to: shotDir.appendingPathComponent("1-1.jpg"))
        try? Data([1]).write(to: shotDir.appendingPathComponent("notes.json"))
        check("release builds delete leftover screenshots, and only screenshots",
              History.purgeScreenshots(in: tmp) == 1 && FileManager.default.fileExists(atPath: shotDir.appendingPathComponent("notes.json").path))
        try? FileManager.default.removeItem(at: tmp)

        // Formulas transforming in place

        let p1 = Formula.plan(["a²", "+", "b²", "=", "c²"], ["3²", "+", "4²", "=", "c²"])
        check("changed terms crossfade, the rest slide", p1 == [.change(from: 0, to: 0), .move(from: 1, to: 1), .change(from: 2, to: 2), .move(from: 3, to: 3), .move(from: 4, to: 4)])
        let p2 = Formula.plan(["9", "+", "16", "=", "c²"], ["25", "=", "c²"])
        check("combining terms fold into the result", p2 == [.fold(from: [0, 1, 2], into: [0]), .move(from: 3, to: 1), .move(from: 4, to: 2)])

        // Connection problems from real CLI and API failures
        check("plan limit with its reset time", ConnectionProblem(cliText: "You've hit your limit · resets 3pm (Europe/London)") == .planLimit("at 3pm"))
        check("expired sign-in", ConnectionProblem(cliText: "Login expired · Please run /login") == .signInExpired)
        check("unrelated CLI failures aren't connection problems", ConnectionProblem(cliText: "some other failure") == nil)
        check("401 is a rejected key", ConnectionProblem(status: 401, body: #"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#) == .keyRejected)
        check("credit runs out as a 400", ConnectionProblem(status: 400, body: #"{"error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#) == .noCredit)
        check("auth status parses the plan, not the email", ClaudeCodeStatus(path: "", version: "", loggedIn: true, authMethod: "claude.ai", subscription: "max").planName == "Max plan")

        // Shared files: read at runtime, matching what's compiled in
        NewCoreChecks.run(check)
    }
}
