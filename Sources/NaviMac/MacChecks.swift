import AppKit

/// Self-tests for the Mac's side of the core split: the look comes from the
/// shared tokens, and the thin wrappers hand the core what it expects.
enum MacChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let t = Tokens.shared
        check("errands: installers, scripts and downloaded apps are only shown, never opened",
              MacErrands.mustNotOpen(URL(fileURLWithPath: "/Users/x/Downloads/Setup.pkg"))
              && MacErrands.mustNotOpen(URL(fileURLWithPath: "/Users/x/Downloads/Tool.app"))
              && MacErrands.mustNotOpen(URL(fileURLWithPath: "/Users/x/Downloads/run.command"))
              && !MacErrands.mustNotOpen(URL(fileURLWithPath: "/Applications/Safari.app"))
              && !MacErrands.mustNotOpen(URL(fileURLWithPath: "/Users/x/Downloads/model.xml")))
        if let report = CrashReports.reports().first {
            check("crash reports: a report sums up as what crashed, then Navi's frames", CrashReports.summary(of: report).hasPrefix("Navi "))
        }
        check("review fixes: links to elsewhere, executables and '..' tricks are only shown",
              MacErrands.mustNotOpen(URL(fileURLWithPath: "/Users/x/Downloads/a.webloc"))
              && MacErrands.mustNotOpen(URL(fileURLWithPath: "/Applications/../Users/x/Downloads/Evil.app"))
              && MacErrands.mustNotOpen(URL(fileURLWithPath: "/bin/ls"))
              && MacErrands.runsScripts(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")))
        check("review fixes: secret files are off limits anywhere on disk",
              CLIBackend.offLimits.contains("Read(//**/.env)") && CLIBackend.offLimits.contains("Read(~/.claude.json*)"))
        check("audit: a download name can't leave Downloads", MacErrands.safeName("..%2FLibrary%2FLaunchAgents%2Fx.plist") == "x.plist"
              && MacErrands.safeName("..") == "download" && MacErrands.safeName(".hidden") == "hidden")
        check("audit: the RFC 5987 file name wins", MacErrands.fileName(for: URL(string: "https://a.com/dl")!,
              response: HTTPURLResponse(url: URL(string: "https://a.com/dl")!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Disposition": "attachment; filename=\"x\"; filename*=UTF-8''model%20v2.xml"])) == "model v2.xml")
        let home = FileManager.default.homeDirectoryForCurrentUser
        check("audit: secret files aren't opened", MacErrands.isSecret(home.appendingPathComponent(".ssh/id_ed25519"))
              && MacErrands.isSecret(URL(fileURLWithPath: "/tmp/project/.env")) && !MacErrands.isSecret(home.appendingPathComponent("Downloads/model.xml")))
        check("audit: plain http isn't downloaded", { var said: String?
            MacErrands(caption: Caption()).offerDownload("http://a.com/x.zip") { _, p in said = p }
            return said?.contains("https") == true }())
        check("keeps: reminder times are read", MacErrands.date("2026-10-30 09:00") != nil && MacErrands.date("2026-10-30") != nil
              && MacErrands.date("next Friday") == nil)
        check("errands: Settings panes open, other schemes don't",
              MacErrands(caption: Caption()).open("tel:123", with: nil) != nil && MacErrands(caption: Caption()).open("ftp://x.com/a", with: nil) != nil)
        check("errands: a GitHub file page downloads as the raw file",
              MacErrands.direct(URL(string: "https://github.com/apirrone/Open_Duck_Mini/blob/v2/mini_bdx/robots/open_duck_mini_v2.xml")!).absoluteString
              == "https://raw.githubusercontent.com/apirrone/Open_Duck_Mini/v2/mini_bdx/robots/open_duck_mini_v2.xml")
        check("errands: only web links are opened, and apps are found by name",
              MacErrands(caption: Caption()).open("file:///etc/passwd", with: nil) != nil && MacErrands.application("Safari") != nil
              && MacErrands.application("No Such App Here") == nil)
        do {
            // Decision 3: document excerpts are redacted, and secret-looking files give none.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-check-\(getpid())")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let plain = dir.appendingPathComponent("notes.md"), secret = dir.appendingPathComponent("secrets.json")
            try? "api_key = sk-ant-abc123XYZ\nhello".write(to: plain, atomically: true, encoding: .utf8)
            try? "{}".write(to: secret, atomically: true, encoding: .utf8)
            let ex = AX.excerpt(plain) ?? ""
            check("audit: document excerpts are redacted, secret-looking files give none",
                  ex.contains("hello") && !ex.contains("abc123XYZ") && AX.excerpt(secret) == nil)
            try? FileManager.default.removeItem(at: dir)
        }
        check("audit: a secure field is known by its role or its subrole", AX.isSecure(role: "AXSecureTextField", subrole: nil)
              && AX.isSecure(role: "AXTextField", subrole: "AXSecureTextField") && !AX.isSecure(role: "AXTextField", subrole: nil))
        do {
            // M33: raw errors become plain sentences.
            let sck = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
            let (s1, setup1) = AppController.sentence(for: sck, screenRecording: true)
            let (s2, _) = AppController.sentence(for: ClaudeCLIError.exited("Error: ENOENT something /usr/lib/x"), screenRecording: true)
            let (s3, _) = AppController.sentence(for: ClaudeCLIError.failed("a turn is already running"), screenRecording: true)
            let (s4, setup4) = AppController.sentence(for: NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3802), screenRecording: true)
            check("audit: capture and Claude Code errors are said in plain words",
                  s1.contains("Screen Recording") && setup1 && !s2.contains("ENOENT") && s3.contains("finishing")
                  && !s4.contains("SCStream") && !setup4)
        }
        check("audit: Esc cancels an offer or download, and the engine hears it once", {
            var heard: [String?] = []
            let e = MacErrands(caption: Caption())
            e.offerDownload("https://127.0.0.1:9/x.zip") { _, p in heard.append(p) }
            e.cancel(); e.cancel()
            return heard == ["cancelled"]
        }())
        check("audit: a keep that failed says so, naming the setting to change",
              MacErrands.couldNotKeep(.note, MacErrands.notesDenied).hasPrefix("COULDN'T SAVE TO NOTES · ALLOW NAVI")
              && MacErrands.couldNotKeep(.remind, "x") == "COULDN'T SET THE REMINDER · X")
        check("decision 11: the type bar stays up when they switch apps", !PromptPanel().hidesOnDeactivate)
        check("decision 9: a single Esc is the app's while a step waits there, Navi's on its own panels",
              AppController.lessonKeepsEsc(waiting: true, paused: false, barOpen: false)
              && !AppController.lessonKeepsEsc(waiting: true, paused: false, barOpen: true)
              && !AppController.lessonKeepsEsc(waiting: false, paused: true, barOpen: false)
              && !AppController.lessonKeepsEsc(waiting: false, paused: false, barOpen: false))
        check("Look's lines and motion come from the tokens", Look.Line.mark == CGFloat(t.line.mark) && Look.Line.targetDash == [10, 7]
              && Look.Motion.base == t.motion.base && Look.fillAlpha == CGFloat(t.line.fillAlpha))
        func same(_ a: NSColor, _ r: Double, _ g: Double, _ b: Double, _ al: Double) -> Bool {
            guard let c = a.usingColorSpace(.genericRGB) else { return false }
            return abs(c.redComponent - r) < 0.002 && abs(c.greenComponent - g) < 0.002 && abs(c.blueComponent - b) < 0.002 && abs(c.alphaComponent - al) < 0.002
        }
        check("the pen and the pane keep their colours", same(OverlayView.ink, 0.24, 0.52, 1, 1) && same(Look.Pane.fill, 18 / 255, 18 / 255, 22 / 255, 0.95)
              && same(Look.warmWhite, 245 / 255, 243 / 255, 238 / 255, 1) && same(Buddy.lamp, 1, 247 / 255, 234 / 255, 1))
        check("the caption's sizes come from the tokens", Caption.maxWidth == 292 && Caption.pad == CGSize(width: 15, height: 12)
              && Caption.font.pointSize == 15 && Caption.tourPause == 1.7)
        check("the settle curve is the token's", { var c: [Float] = [0, 0]; Look.Motion.settle.getControlPoint(at: 1, values: &c); return c == [0.2, 0.8] }())
        check("the owl's Mac palette covers every letter", Owl.colours.keys.allSatisfy { Owl.palette[$0] != nil }
              && same(Owl.palette["B"]!, 0x93 / 255.0, 0x5C / 255.0, 0x40 / 255.0, 1))
        check("the right ⌥ flag reaches the core as option", TapTrigger.mods([.option, .capsLock]) == .option
              && TapTrigger.mods([.command, .function, .numericPad]) == [.command, .function])
        if let screen = NSScreen.screens.first {
            let step = Walkthrough.Step(center: .zero, radius: 30, label: "x", hover: false, screen: screen, sentence: "", armedAt: Date())
            check("a step finds its screen again by display id", step.isOn(screen) && step.screen == screen)
        }
        // Your turn: the answer line sends what's typed (not an empty line), and Esc cancels.
        let row = AnswerRow(frame: NSRect(x: 0, y: 0, width: 240, height: AnswerRow.height))
        var sent: [String] = [], cancelled = false
        row.onSubmit = { sent.append($0) }
        row.onCancel = { cancelled = true }
        let tv = NSTextView()
        _ = row.control(row.field, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        row.field.stringValue = " 13 "
        _ = row.control(row.field, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        _ = row.control(row.field, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check("the answer line sends a typed answer, skips an empty one, and Esc cancels", sent == ["13"] && cancelled)
        let p = AnswerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.ignoresMouseEvents = true
        let before = p.canBecomeKey
        p.ignoresMouseEvents = false
        check("the caption only takes the keys while an answer is being typed", !before && p.canBecomeKey)
        // The Mac's classes are the shell protocols' Mac side (ShellMac.swift).
        let macShell: [Any.Type] = [MacScreens.self as any Shell.ScreenSource.Type, OverlayManager.self as any Shell.Overlay.Type,
                                    Buddy.self as any Shell.Companion.Type, Caption.self as any Shell.Caption.Type,
                                    PauseCard.self as any Shell.PauseCard.Type, TopicPill.self as any Shell.TopicPill.Type,
                                    MacUIReader.self as any Shell.UIReader.Type, TapTrigger.self as any Shell.Hotkey.Type]
        check("the Mac provides every shell protocol", macShell.count == 8)
        if let main = NSScreen.screens.first {
            check("a display id finds its screen again", Capture.screen(Capture.displayID(main)) == main)
        }
        let closed = Caption.notchPath(width: 200, height: 32, open: 0).boundingBox
        let opened = Caption.notchPath(width: 200, height: 120, open: 1).boundingBox
        let snapped = Caption.pixelSnapped(NSRect(x: 10.3, y: 20.8, width: 100.4, height: 40.1), scale: 2)
        check("the caption sits on whole device pixels", snapped == NSRect(x: 10.5, y: 21, width: 100, height: 40))
        check("the notch panel starts with the notch's small shoulders and grows into its own",
              closed.width == 208 && opened.width == 220)
        _ = NSApplication.shared
        MainMenu.install()
        let edit = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        check("audit M25: the main menu gives Navi's windows ⌘V, ⌘C, ⌘A and ⌘Z",
              ["v", "c", "a", "z"].allSatisfy { k in edit?.items.contains { $0.keyEquivalent == k } == true }
              && edit?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true)
        check("decision 7: Navi on the disk image or translocated moves first; installed or the debug binary doesn't",
              Relocation.needsMove(path: "/Volumes/Navi/Navi.app", translocated: false)
              && Relocation.needsMove(path: "/private/var/folders/x/T/AppTranslocation/1234-AB/d/Navi.app", translocated: false)
              && Relocation.needsMove(path: "/Users/x/Downloads/Navi.app", translocated: true)
              && !Relocation.needsMove(path: "/Applications/Navi.app", translocated: false)
              && !Relocation.needsMove(path: "/Volumes/Code/navi/.build/debug", translocated: false)
              && !Relocation.isTranslocated(Bundle.main.bundleURL))
        check("decision 7: the image to eject is the volume the app was on",
              Relocation.volume(of: "/Volumes/Navi 1.0/Navi.app") == "/Volumes/Navi 1.0" && Relocation.volume(of: "/Applications/Navi.app") == nil)
        let suite = "navi-selftest-shortcut-\(getpid())"
        if let fresh = UserDefaults(suiteName: suite) {
            Settings.registerShortcutDefault(fresh)
            let newDefault = fresh.integer(forKey: "hotkeyCode") == 45 && fresh.integer(forKey: "hotkeyMods") == 4096 | 2048
                && fresh.string(forKey: "hotkeyLabel") == "⌃⌥N"
            fresh.set(49, forKey: "hotkeyCode")
            fresh.set("⌃⌥Space", forKey: "hotkeyLabel")
            Settings.registerShortcutDefault(fresh)
            check("decision 8: ⌃⌥N is the default, and a shortcut someone chose is kept",
                  newDefault && fresh.integer(forKey: "hotkeyCode") == 49 && fresh.string(forKey: "hotkeyLabel") == "⌃⌥Space")
            fresh.removePersistentDomain(forName: suite)
        }
        // Two registrations of one key in one app: the second is refused, and that's remembered.
        let first = Hotkey(keyCode: 0x2F, modifiers: 4096 | 2048 | 512) { _ in }   // ⌃⌥⇧. (nothing uses it)
        var heard: Bool?
        let saved = Hotkey.onRegistered
        Hotkey.onRegistered = { _, ok in heard = ok }
        let second = Hotkey(keyCode: 0x2F, modifiers: 4096 | 2048 | 512) { _ in }
        Hotkey.onRegistered = saved
        check("audit M47: a key that can't be registered is known, and said",
              first.isRegistered && (!second.isRegistered && heard == false && Hotkey.isTaken(keyCode: 0x2F, modifiers: 4096 | 2048 | 512)))
        withExtendedLifetime((first, second)) {}
        // The public export's allow-list (from the source tree): the product only.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let list = try? String(contentsOf: repo.appendingPathComponent("PUBLIC-INCLUDE.txt"), encoding: .utf8) {   // public-ok
            let entries = list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let privateOnes = ["docs/", "research/", "eval/", "marketing/", "design/", "ROADMAP", "GOLDENS", "AUDIT", "DESIGN-PRINCIPLES",   // public-ok
                               "VISUAL-SPEC", "WINDOWS-PLAN", "PUBLIC-", "export-public"]   // public-ok
            check("decision 23: the public export is an allow-list of the product, with no docs, research or planning",
                  ["Sources/", "Resources/", "Package.swift", "README.md", "LICENSE"].allSatisfy(entries.contains)
                  && !entries.contains { e in privateOnes.contains { e.hasPrefix($0) || e.contains("/" + $0) } }
                  && entries.filter { $0.hasSuffix(".md") }.allSatisfy { ["README.md", "THIRD_PARTY_NOTICES.md"].contains($0) }
                  && !FileManager.default.fileExists(atPath: repo.appendingPathComponent("PUBLIC-EXCLUDE.txt").path))
        }
        check("decision 6: open at login only from /Applications",
              Relocation.inApplications("/Applications/Navi.app") && !Relocation.inApplications("/Volumes/Navi/Navi.app")
              && !Relocation.inApplications("/Users/x/source/navi/Navi.app") && !Relocation.inApplications("/Applications/../tmp/Navi.app"))
    }
}
