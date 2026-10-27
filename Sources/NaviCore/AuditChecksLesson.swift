import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Checks added by the 2026-10-24 audit, one failing check per defect fixed.
/// Kept apart from the older check files so parallel fixes don't collide.
public enum AuditChecksLesson {
    /// A pause card that keeps what it was asked to show.
    final class CardRecorder: Shell.PauseCard {
        var kicker: String?
        var text: String?
        var isShown = false
        func show(kicker: String, text: String, on screen: ScreenID) { (self.kicker, self.text, isShown) = (kicker, text, true) }
        func hide() { isShown = false }
    }

    /// A host that keeps what it was told went wrong.
    final class HostRecorder: Shell.Host {
        var failures: [String] = []
        func showWorking(_ status: String, at p: CGPoint) {}
        func fail(_ error: Error, at p: CGPoint) { failures.append(error.localizedDescription) }
        func setEscape(_ on: Bool) {}
        func clearScreen() {}
        func restSoon(after delay: TimeInterval) {}
        func refreshFrontApp() {}
        func prepareTurn() -> Bool { false }
        func answerShown(_ played: Tutor.Engine.Played, shots: [any Shell.Screenshot], anchor: CGPoint) {}
        func turnFinished(_ played: Tutor.Engine.Played, speak: Bool, answerWanted: Bool, gen: Int) {}
        func lessonEnded() {}
        func chooseFiles() {}
    }

    /// Errands that keep a download offer open until the check answers it.
    final class ErrandsRecorder: Shell.Actions {
        var opened: [String] = []
        var offers: [(url: String, done: (String?, String?) -> Void)] = []
        func open(_ target: String, with app: String?) -> String? { opened.append(target); return nil }
        func offerDownload(_ url: String, done: @escaping (String?, String?) -> Void) { offers.append((url, done)) }
    }

    @MainActor
    public static func run(_ check: (String, Bool) -> Void) async {
        /// An engine on a fake shell for a lesson, as EngineChecks builds one: "Claude"
        /// answers each turn with the next of `replies`.
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
        let shots: [any Shell.Screenshot] = [FakeShell.Shot(screenID: 1, index: 1, hasCursor: true, origin: .zero)]
        func start(_ e: Tutor.Engine) async {
            try? await e.runTurn([], shots: shots, goal: "save the map", anchor: .zero, gen: e.bump())
        }
        /// Waits for the turn in flight and any it starts in turn (an errand's follow-up look).
        func drain(_ e: Tutor.Engine) async {
            for _ in 0..<6 {
                await e.turn?.value
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func said(_ fake: FakeShell) -> [String] { fake.log.filter { $0.hasPrefix("say ") } }

        // A password field has focus: the looks the engine takes itself, after a
        // step, after an errand and on coming back, don't capture the screen; they say so
        // instead, and the lesson survives to carry on with "continue".
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:password] Click the password field.", "unused", "unused"])
            let host = HostRecorder()
            await start(e)
            e.host = host
            fake.ui.passwordFieldFocused = true
            fake.clearLog()
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await e.turn?.value
            check("password: a step taken on a password field isn't followed by a capture",
                  !fake.log.contains("capture") && host.failures.count == 1 && e.lesson != nil)
            check("password: the refusal is the sentence the Mac uses",
                  host.failures.last == "A password field is focused, so I won't look at your screen.")
            fake.clearLog()
            e.lookAgain("the user came back", why: "test")
            await e.turn?.value
            check("password: a look again doesn't capture either", !fake.log.contains("capture") && host.failures.count == 2)
            fake.clearLog()
            e.carryOn("you opened a page")
            await e.turn?.value
            check("password: an errand's follow-up look doesn't capture either", !fake.log.contains("capture") && host.failures.count == 3)
        }

        // A reply opens at most two things and offers at most one download, and no download
        // is offered while an earlier offer is still waiting for an answer: a page that gets
        // into the chain can't open ten tabs or stack offers.
        do {
            let (opener, _) = lessonSetUp(["[OPEN:https://a.com] [OPEN:https://b.com] [OPEN:https://c.com] Opening three pages."])
            let tabs = ErrandsRecorder()
            opener.actions = tabs
            await start(opener)
            opener.turn?.cancel()
            check("errands: at most two opens in one reply", tabs.opened == ["https://a.com", "https://b.com"])

            let (e, _) = lessonSetUp(["[DOWNLOAD:https://x.com/a.xml] [DOWNLOAD:https://x.com/b.xml] Shall I grab both?",
                                      "[DOWNLOAD:https://x.com/c.xml] And this one?", "Saved."])
            let errands = ErrandsRecorder()
            e.actions = errands
            await start(e)
            check("errands: at most one download offer in one reply", errands.offers.map(\.url) == ["https://x.com/a.xml"])
            await start(e)
            check("errands: no new offer while one is still waiting", errands.offers.count == 1)
            errands.offers.first?.done("/Users/me/Downloads/a.xml", nil)
            await drain(e)
            check("errands: once answered, the download is carried on from", e.errandLooks == 1)
        }

        // Errands come in chains of three in a row; once the user takes a step by hand, the
        // count starts again. It didn't: after three errands early in a lesson, a later
        // [OPEN] opened the page and then ended the lesson instead of looking at it.
        do {
            let (e, _) = lessonSetUp(["[OPEN:https://a.com] Opening A.", "[OPEN:https://b.com] Opening B.", "[OPEN:https://c.com] Opening C.",
                                      "[TARGET:200,100,30:Export] Click Export.",
                                      "[OPEN:https://d.com] I'll open the docs for the next part.",
                                      "[TARGET:300,200,30:Save] Click Save."])
            await start(e)
            await drain(e)
            check("errands: three looks in a row arm the step", e.lesson?.armed?.label == "Export" && e.errandLooks == 3)
            e.graceUntil = nil
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await drain(e)
            check("errands: a step taken by hand starts the chain afresh", e.lesson?.armed?.label == "Save" && e.lesson?.stepsTaken == 1)
        }

        // A question (no lesson) whose reply opens a page: the look that follows is still
        // an answer, not a lesson step, so it doesn't leave a "When you're ready" card and
        // a lesson whose goal is the errand's own note.
        do {
            let (e, fake) = lessonSetUp(["[OPEN:https://mujoco.org] I'll open the download page.",
                                         "[POINT:300,200:Download] The download link is here."])
            e.ask(Tutor.Engine.Asking(question: "where do I download mujoco?", fromCard: false, anchor: .zero,
                                      screenshots: { shots }, context: { (nil, nil) }))
            await drain(e)
            check("errands: a question's follow-up look isn't a lesson step",
                  fake.log.contains("open https://mujoco.org") && e.lesson == nil && !fake.pause.isShown)
        }

        // The step limit: a reply that still gives a TARGET past the fifteenth step can't be
        // armed, so the lesson ends there (the words aren't held for a step that isn't coming).
        do {
            let (e, fake) = lessonSetUp(Array(repeating: "[TARGET:200,100,30:Next] Click Next.", count: Walkthrough.maxSteps + 1))
            await start(e)
            for _ in 0..<Walkthrough.maxSteps {
                e.graceUntil = nil
                if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
                await e.turn?.value
            }
            check("lesson: a step past the limit ends the lesson rather than leaving it hanging",
                  e.lesson == nil && fake.log.contains("lesson ended") && fake.log.last(where: { $0.hasPrefix("done") }) == "done")
        }

        // A typing step when the lesson has no app yet (Navi's own window was in front
        // when the reply arrived): typing anywhere but Navi counts.
        do {
            let (e, _) = lessonSetUp(["[POINT:642,286:search] Type export in the search field.", "[TARGET:300,200,30:Export] Click Export."])
            await start(e)
            e.lessonApp = nil
            e.typed(returnKey: false, pid: ProcessInfo.processInfo.processIdentifier)
            check("typing step: typing into Navi itself never counts", e.typedWork == nil)
            e.typed(returnKey: true, pid: 42)
            check("typing step: with no lesson app known, typing in the app in front counts", e.typedWork != nil)
            e.typedWork?.cancel()
        }

        // The reply breaks off (the connection dropped mid-stream): the error is shown, and
        // the sentences already queued don't keep being read underneath it.
        do {
            let fake = FakeShell(screens: 1)
            let e = Tutor.Engine(overlay: fake.overlay, light: fake.light, caption: fake.caption, ui: fake.ui,
                                 screens: fake.screens, voice: nil)
            e.wait = { _ in try? await Task.sleep(nanoseconds: 30_000_000) }
            struct Dropped: Error {}
            e.send = { _, _, onText in
                onText("[POINT:100,100:a] One. [POINT:200,200:b] Two. [POINT:300,300:c] Three.")
                throw Dropped()
            }
            let played = try? await e.playTurn([], shots: shots, anchor: .zero, gen: 0, explain: false, kind: .lessonStep, speak: false)
            try? await Task.sleep(nanoseconds: 150_000_000)
            check("turn: a reply that breaks off stops its queued words", played == nil && said(fake).isEmpty)
        }

        // A look refused for a password field leaves the lesson on its card, so there's a way
        // on ("I did it") without having to know to type "continue".
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:password] Click the password field.", "unused"])
            await start(e)
            fake.ui.passwordFieldFocused = true
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await e.turn?.value
            check("password: after the refusal the lesson waits on its card",
                  e.lessonPaused && fake.pause.isShown && fake.log.contains("pause card: Paused · password"))
        }

        // A turn still being worked out (an errand's follow-up waiting for the page) is cancelled
        // when a step, a look or another errand replaces it, not left to run to its next
        // generation check with a request that would only be thrown away.
        do {
            let (e, _) = lessonSetUp(["[TARGET:200,100,30:Export] Click Export.", "[TARGET:200,100,30:Export] Click Export.",
                                      "[TARGET:200,100,30:Export] Click Export.", "[TARGET:200,100,30:Export] Click Export."])
            await start(e)
            /// Starts an errand look (it waits 0.4 s for the page first), supersedes it, and
            /// reports whether the superseded turn ended at once.
            func supersededQuickly(_ supersede: () -> Void) async -> Bool {
                e.errandLooks = 0
                e.carryOn("you opened a page")
                let first = e.turn
                supersede()
                let t0 = Date()
                await first?.value
                let quick = Date().timeIntervalSince(t0) < 0.25
                await drain(e)
                return quick
            }
            let byLook = await supersededQuickly { e.lookAgain("the user came back", why: "test") }
            let byErrand = await supersededQuickly { e.carryOn("you opened another page") }
            let byStep = await supersededQuickly { e.graceUntil = nil; if let s = e.lesson?.armed { e.stepClicked(at: s.center) } }
            check("turn: a look again cancels the turn it supersedes", byLook)
            check("turn: an errand's look cancels the turn it supersedes", byErrand)
            check("turn: a step taken cancels the turn it supersedes", byStep)
        }

        // A scroll step re-armed while the screen was being read: the reading of the old
        // screen doesn't take the new step.
        do {
            let (e, fake) = lessonSetUp(["[POINT:300,500:Export] Scroll down to Export.", "[TARGET:300,200,30:Export] Click Export."])
            await start(e)
            fake.ui.shows = true
            e.scrollPaused()   // reads the screen; the result lands on the next turn of the main actor
            e.scrollStep = (Date().addingTimeInterval(Tutor.scrollWindow), 1)   // a fresh step, as a new reply arms one
            try? await Task.sleep(nanoseconds: 30_000_000)
            check("scroll step: a reading for the old step doesn't take the new one", e.scrollStep != nil && e.lesson?.stepsTaken == 0)
        }

        // The first mark of an answer is drawn as soon as its tag arrives; the light flies to
        // it even when the answer before ended with a traced stroke.
        do {
            let fake = FakeShell(screens: 1)
            let e = Tutor.Engine(overlay: fake.overlay, light: fake.light, caption: fake.caption, ui: fake.ui,
                                 screens: fake.screens, voice: nil)
            e.wait = { _ in }
            var reply = "[WRITE:600,300:a² + b² = c²] So a squared plus b squared is c squared."
            e.send = { _, _, onText in onText(reply); try? await Task.sleep(nanoseconds: 2_000_000); return reply }
            _ = try? await e.playTurn([], shots: shots, anchor: .zero, gen: 0, explain: true, kind: .question("x"), speak: false)
            fake.clearLog()
            reply = "[POINT:100,100:Export] Export is here."
            _ = try? await e.playTurn([], shots: shots, anchor: .zero, gen: 0, explain: false, kind: .question("y"), speak: false)
            check("turn: the light flies to an early-drawn first mark after a traced answer", fake.log.contains("fly 50,850"))
        }

        // Paused while the step's sentence is still being read (it was armed as its tag
        // arrived): the card shows the instruction, not a blank.
        do {
            let (e, _) = lessonSetUp([])
            let card = CardRecorder()
            e.pauseCard = card
            let reply = "[TARGET:200,100,30:Export] Click Export to save the map."
            e.stepReply = reply
            e.armEarly(reply, shots: shots, goal: "save the map")
            e.pauseLesson(why: "switched to Slack")
            check("pause: the card for a step armed early shows its words", card.isShown && card.text == "Click Export to save the map.")
        }
    }
}
