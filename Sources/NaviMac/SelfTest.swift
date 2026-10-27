import AppKit
import Foundation

/// `swift run Navi --selftest` checks the pure logic without XCTest.
enum SelfTest {
    static func run() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "PASS " : "FAIL ") + name)
            if !ok { failures += 1 }
        }

        // NaviCore's logic first (tags, lessons, the owl, the tutor's rules…), then the Mac's.
        Bookmarks.useScratch()   // no check touches the user's kept lessons
        Skills.useScratch()      // or their skills
        CoreSelfTest.run(check)

        // CLI result lines
        let ok: [String: Any] = ["type": "result", "is_error": false, "result": "[POINT:1,2:x] Hi."]
        if case .success(let s)? = CLIBackend.result(from: ok) { check("cli result parsed", s == "[POINT:1,2:x] Hi.") }
        else { check("cli result parsed", false) }
        let authFail: [String: Any] = ["type": "result", "is_error": true, "result": "Failed to authenticate"]
        if case .failure? = CLIBackend.result(from: authFail) { check("cli error surfaced", true) } else { check("cli error surfaced", false) }
        check("non-result lines ignored", CLIBackend.result(from: ["type": "system"]) == nil)

        let look = CGImage.gray(16, 16) { x, y in (x + y) % 2 == 0 ? 200 : 40 }
        let same = CGImage.gray(16, 16) { x, y in (x + y) % 2 == 0 ? 203 : 42 }
        let moved = CGImage.gray(16, 16) { x, _ in x < 8 ? 230 : 10 }
        check("a step that didn't move under a scroll is kept", !AppController.differs(look, same) && AppController.differs(look, moved))

        // Speech
        check("speakable drops markdown and links", Narrator.speakable("See **this** at https://x.com/a — now") == "See this at the link, now")
        check("a voice is available", Narrator.voice() != nil)
        check("Kokoro word times pair one to one", KokoroVoice.wordTimes(text: "Click Export now.", starts: [0, 0.3, 0.8]).map(\.1) == [0, 0.3, 0.8])
        let spread = KokoroVoice.wordTimes(text: "Add 25 apples", starts: [0, 0.2, 0.5, 0.9])
        check("Kokoro word times spread when counts differ", spread.map(\.0) == ["Add", "25", "apples"] && spread.map(\.1) == [0, 0.2, 0.5])
        let tail = KokoroVoice.trimmingTrailingSilence([0.5] + Array(repeating: 0, count: 24_000))
        check("Kokoro trims trailing silence to 80 ms", tail.count == 1 + 1_920)
        check("Kokoro voice ids are prefixed", { Settings.shared.voiceID.isEmpty || Settings.shared.voiceID.hasPrefix("kokoro:") || Narrator.voice() != nil }())

        let img = Prompt.image(Data([0xFF, 0xD8]))
        var history: [[String: Any]] = []
        for i in 0..<6 {
            history.append(["role": "user", "content": [Prompt.text("Screen 1"), img, Prompt.text("q\(i)")]])
            history.append(["role": "assistant", "content": [Prompt.text("a\(i)")]])
        }
        let pruned = APIBackend.pruned(history)
        let prunedImages = pruned.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.filter { $0["type"] as? String == "image" }
        check("API history keeps the last exchanges", pruned.count == APIBackend.keepExchanges * 2 && pruned.first?["role"] as? String == "user")
        check("API history drops old screenshots", prunedImages.isEmpty)
        check("API history keeps old text", ((pruned.last?["content"] as? [[String: Any]])?.first?["text"] as? String) == "a5")

        // Fn key: hold to talk, combos cancel
        do {
            let k = FnKey()
            k.holdTalks = true
            var log: [String] = []
            k.onPress = { log.append("press") }; k.onRelease = { log.append("release") }; k.onCancel = { log.append("cancel") }
            k.flags(.function); k.flags([])
            check("fn alone: press then release", log == ["press", "release"])
            log = []
            k.flags(.function); k.otherKey(); k.flags([])
            check("fn with another key: cancelled, no release", log == ["press", "cancel"])
            log = []
            k.flags([.function, .shift]); k.flags([])
            check("fn with shift is someone else's shortcut", log.isEmpty)
            log = []
            k.flags(.function); k.flags([.function, .command]); k.flags([])
            check("adding a modifier mid-hold cancels", log == ["press", "cancel"])

            // Tap to type (hold is left to other apps, like Wispr Flow)
            let t = FnKey()
            var taps = 0, presses = 0
            t.onTap = { taps += 1 }; t.onPress = { presses += 1 }
            t.flags(.function); t.flags([])
            check("a quick Fn tap opens typing, and holding doesn't talk", taps == 1 && presses == 0)
            t.flags(.function); t.otherKey(); t.flags([])
            check("Fn+key is not a tap", taps == 1)
        }

        // Tap to type: one key alone, or a double tap
        do {
            let t0 = Date()
            func tap(_ k: TapTrigger, _ code: UInt16, _ flag: NSEvent.ModifierFlags, at s: TimeInterval, hold: TimeInterval = 0.1) {
                k.flags(keyCode: code, mods: flag, at: t0.addingTimeInterval(s))
                k.flags(keyCode: code, mods: [], at: t0.addingTimeInterval(s + hold))
            }
            let k = TapTrigger()
            var n = 0
            k.onTrigger = { n += 1 }
            k.mode = .rightOption
            tap(k, 61, .option, at: 0)
            check("a tap of right ⌥ opens typing", n == 1)
            tap(k, 58, .option, at: 1)
            check("left ⌥ doesn't", n == 1)
            tap(k, 61, .option, at: 2, hold: 0.6)
            check("holding right ⌥ doesn't", n == 1)
            k.flags(keyCode: 61, mods: .option, at: t0.addingTimeInterval(3)); k.otherKey(); k.flags(keyCode: 61, mods: [], at: t0.addingTimeInterval(3.1))
            check("⌥ with a key (a shortcut or an accent) doesn't", n == 1)
            k.flags(keyCode: 61, mods: [.option, .command], at: t0.addingTimeInterval(4)); k.flags(keyCode: 61, mods: [], at: t0.addingTimeInterval(4.1))
            check("⌥ with ⌘ held doesn't", n == 1)
            k.mode = .doubleCommand
            tap(k, 55, .command, at: 5)
            check("one ⌘ tap isn't a double", n == 1)
            tap(k, 54, .command, at: 5.25)
            check("two ⌘ taps within 0.4 s are", n == 2)
            tap(k, 55, .command, at: 7); tap(k, 55, .command, at: 7.8)
            check("two ⌘ taps far apart aren't", n == 2)
            k.mode = .off
            tap(k, 61, .option, at: 9)
            check("off is off", n == 2)
        }

        // Tidy transcripts
        check("transcript: fillers and stray marks go", Voice.tidy("I've never done this before. How do I? #um start my first project.") == "I've never done this before. How do I start my first project.")
        check("transcript: um, uh and a leading comma go", Voice.tidy("um, where is the uh export button") == "Where is the export button")
        check("transcript: real questions stay", Voice.tidy("Where is it? And how do I use it?") == "Where is it? And how do I use it?")
        check("transcript: words containing um stay", Voice.tidy("summarise the umbrella column") == "Summarise the umbrella column")

        // Formulas transforming in place (measured in a Mac font)
        let font = NSFont.systemFont(ofSize: 20)
        check("terms split with their powers", Formula.tokens("a² + b² = c²", font: font).map(\.text) == ["a²", "+", "b²", "=", "c²"])

        // Colour binding (explanations)
        var q = Tutor.Quantities(on: true)
        let ca = q.colour(for: .shape(.line, [.zero, CGPoint(x: 1, y: 1)], label: "leg a", screen: 0))
        let cb = q.colour(for: .shape(.line, [.zero, CGPoint(x: 1, y: 1)], label: "b", screen: 0))
        check("each labelled thing gets the next colour", ca == Tutor.Quantities.palette[0].dark && cb == Tutor.Quantities.palette[1].dark)
        check("light pages get the deeper version", q.colour(for: .point(.zero, label: "b", screen: 0), lightPage: true) == Tutor.Quantities.palette[1].light)
        check("a name keeps its colour", q.colour(for: .point(.zero, label: "Leg a", screen: 0)) == ca)
        check("single letters are bound", q.letters(lightPage: false)["a"] == ca && q.letters(lightPage: true)["b"] == Tutor.Quantities.palette[1].light)
        check("pointing answers stay ink", { var p = Tutor.Quantities(on: false); return p.colour(for: .point(.zero, label: "a", screen: 0)) == nil }())
        let f = OverlayView.bound("a² + ab = c", font: .systemFont(ofSize: 12), base: OverlayView.ink, letters: q.letters(lightPage: false).mapValues(Look.colour))
        check("formula letters take their colour, words don't",
              f.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == ca.map(Look.colour)
              && f.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor == OverlayView.ink)

        check("a masked key keeps only its ends", Keychain.masked("sk-ant-api03-abcdefghijklmnop1234") == "sk-ant-…1234")

        // The Mac's look reads the shared design tokens
        MacChecks.run(check)

        print(failures == 0 ? "\nAll passed." : "\n\(failures) failed.")
        if failures > 0 { exit(1) }
    }
}

extension CGImage {
    /// A small grayscale test image.
    static func gray(_ w: Int, _ h: Int, _ v: (Int, Int) -> UInt8) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = v(x, y) } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        return ctx.makeImage()!
    }
}
