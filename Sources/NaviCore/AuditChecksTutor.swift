import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Checks added by the 2026-10-24 audit, one failing check per defect fixed.
/// Kept apart from the older check files so parallel fixes don't collide.
public enum AuditChecksTutor {
    @MainActor
    public static func run(_ check: (String, Bool) -> Void) async {
        rules(check)
        await engine(check)
    }

    /// The tutor's rules, the notes and the conversation.
    static func rules(_ check: (String, Bool) -> Void) {
        // The same question three times means the same words, digits included: three
        // different sums aren't a repeat, so the owl isn't grumpy at someone practising.
        do {
            var w = Tutor.RepeatWatch()
            _ = w.note("what is 7 × 8")
            _ = w.note("what is 9 × 6")
            check("repeat watch: different sums aren't the same question", !w.note("what is 5 × 5"))
            _ = w.note("what's 7+8?")
            _ = w.note("what's 7-8?")
            check("repeat watch: the same numbers with different operators aren't either", !w.note("what's 7×8?"))
            _ = w.note("where is export?")
            _ = w.note("Where is export")
            check("repeat watch: the same words three times are", w.note("where is export?!"))
        }

        // "Type" the verb is a typing step; "type" the noun isn't, nor "don't type".
        check("typing step: asks to type", Tutor.asksToType("Type export in the search field.") && Tutor.asksToType("Now enter your name and press Return.")
              && Tutor.asksToType("Search for Rendering in the box at the top."))
        check("typing step: the file type isn't typing", !Tutor.asksToType("Choose the file type from the dropdown.")
              && !Tutor.asksToType("This type of layer has no attributes.") && !Tutor.asksToType("Pick a type of chart from the list."))
        check("typing step: told not to type isn't typing", !Tutor.asksToType("Don't type anything yet: click Save.")
              && !Tutor.asksToType("Press the Enter key to confirm."))

        // What a scroll is scrolling to: an apostrophe in the sentence isn't a quote.
        check("scroll target: apostrophes aren't quotes", Tutor.scrollTarget("Scroll down until you see the Camera's settings, where it's set.") == "Camera"
              && Tutor.scrollTarget("Scroll down to 'Advanced' near the bottom.") == "Advanced"
              && Tutor.scrollTarget("Scroll down to \"Export Settings\".") == "Export Settings")

        // A skill saved with a byte-order mark or CRLF line ends (some Windows editors) still applies.
        let bom = Skills.parse("\u{FEFF}apps: Finder\nsites:\n\nThe sidebar is on the left.", name: "Finder")
        check("skills: a byte-order mark doesn't hide the header", bom.apps == ["finder"] && bom.body == "The sidebar is on the left.")
        let crlf = Skills.parse("apps: Finder\r\nsites: example.com\r\n\r\nBody line.\r\nSecond.", name: "n")
        check("skills: CRLF files parse without doubled blank lines", crlf.apps == ["finder"] && crlf.sites == ["example.com"] && crlf.body == "Body line.\nSecond.")

        // Edges that hold: infinities clamp to the edge, degenerate shapes stay finite, a
        // lost key-up doesn't stop the next tap, and a recap of nothing is just the preamble.
        let inf = Tutor.clamp(CGPoint(x: CGFloat.infinity, y: -CGFloat.infinity), in: CGSize(width: 100, height: 100))
        check("clamp: infinities land on the edge", inf == CGPoint(x: 100, y: 0))
        let dup = CGPoint(x: 50, y: 50)
        check("sketch: a ring on two identical points is finite", Sketch.polyline(.circle, [dup, dup], sketchy: true).allSatisfy { $0.x.isFinite && $0.y.isFinite })
        check("sketch: a curve through identical points is finite", Sketch.polyline(.curve, [dup, dup, dup], sketchy: false).allSatisfy { $0.x.isFinite && $0.y.isFinite })
        check("mark: nothing, a tap and a dot", Mark.tidy([]) == nil && Mark.tidy([dup])?.kind == .point && Mark.tidy([dup, dup])?.kind == .point)
        do {
            let d = TapDecider()
            var fired = 0
            d.onTrigger = { fired += 1 }
            let t0 = Date()
            d.flags(keyCode: 61, mods: [.option], at: t0)                       // down, release lost
            d.flags(keyCode: 61, mods: [.option], at: t0.addingTimeInterval(5))   // down again
            d.flags(keyCode: 61, mods: [], at: t0.addingTimeInterval(5.1))        // up
            check("tap: a lost key-up doesn't stop the next tap", fired == 1)
            d.flags(keyCode: 61, mods: [.option], at: t0.addingTimeInterval(6))
            d.otherKey()
            d.flags(keyCode: 61, mods: [], at: t0.addingTimeInterval(6.1))
            check("tap: a key pressed while it's down means a shortcut", fired == 1)
        }
        check("conversation: a recap of nothing is just the preamble", Conversation.recap([], lesson: false).hasPrefix("Earlier in this conversation")
              && Conversation.recap([], lesson: true).hasPrefix("Earlier in this conversation"))
    }

    /// Engine flows on the fake shell.
    @MainActor
    static func engine(_ check: (String, Bool) -> Void) async {
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

        // a password field has focus after the step (an unlock prompt), so the
        // lesson's next look doesn't capture the screen.
        do {
            let (e, fake) = lessonSetUp(["[TARGET:200,100,30:Unlock] Click the padlock to unlock the pane.", "[TARGET:400,300,30:Switch] Turn it on."])
            try? await e.runTurn([], shots: shots, goal: "allow screen recording", anchor: .zero, gen: e.bump())
            fake.clearLog()
            fake.ui.passwordFieldFocused = true
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await e.turn?.value
            check("password field: a lesson step's look doesn't capture the screen", !fake.log.contains("capture") && fake.log.contains("fail"))
            fake.clearLog()
            fake.ui.passwordFieldFocused = false
            _ = e.lookAgain(Tutor.backEvent("Unlock"), why: "check")
            await e.turn?.value
            check("password field: once it's gone, looks capture again", fake.log.contains("capture"))
        }
    }
}
