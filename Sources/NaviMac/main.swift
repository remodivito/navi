import AppKit

// The app itself is AppController; this file is the entry point.

/// Plays a canned reply as if Claude were streaming it, for testing the UI
/// without a model: `--fake-reply <file>`.
/// Several replies separated by a line of `===` are played one per turn.
final class FakeBackend: ChatBackend {
    private var replies: [String]
    init(reply: String) {
        replies = reply.components(separatedBy: "\n===\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    func reset() {}
    func send(_ content: [[String: Any]], onText: @escaping (String) -> Void) async throws -> String {
        let said = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        trace("Sent \(content.filter { $0["type"] as? String == "image" }.count) screenshot(s) and: \(said.last ?? "")", content: true)
        let reply = replies.count > 1 ? replies.removeFirst() : (replies.first ?? "")
        var sent = ""
        for ch in reply {
            sent.append(ch)
            if sent.count % 6 == 0 {
                onText(sent)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        onText(sent)
        return reply
    }
}

// MARK: - Entry

// Claude's connection (in NaviCore) reaches the Keychain and Claude Code through these,
// for every mode below (the app, galleries).
// A pipe to claude that closed mid-write is an error to handle, not a reason to die.
signal(SIGPIPE, SIG_IGN)
ClaudeAccess.useMac()
// The first launch under Navi's own identifier brings the prototype's settings and sign-in across.
CarryOver.run()

#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--cli-timing"), CommandLine.arguments.count > i + 1 {
    // Debug: time the warm `claude -p` path without the hotkey.
    // `--cli-timing <screenshot.jpg> [runs]`; a reset between runs checks
    // that the replacement process is warm by the next ask.
    let path = CommandLine.arguments[i + 1]
    let runs = CommandLine.arguments.count > i + 2 ? Int(CommandLine.arguments[i + 2]) ?? 5 : 5
    let cli = CLIBackend()
    Task { @MainActor in
        guard let jpeg = FileManager.default.contents(atPath: path) else { print("can't read \(path)"); exit(1) }
        let content = [Prompt.text("Screen 1 (cursor is here)"), Prompt.image(jpeg),
                       Prompt.text("Where is the Apple menu? Point at it.")]
        cli.prewarm()
        for run in 1...runs {
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // the user pressing and talking
            print("run \(run)")
            do { print(try await cli.send(content) { _ in }.prefix(80)) } catch { print("error: \(error)") }
            cli.reset()
        }
        cli.shutdown()
        exit(0)
    }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--context-bench"), CommandLine.arguments.count > i + 1 {
    // Debug: `--context-bench <screenshot.jpg> [compact keep legacy]`, see ContextBench.
    let modes = CommandLine.arguments.dropFirst(i + 2).compactMap(Conversation.Mode.init(rawValue:))
    Task { @MainActor in
        await ContextBench.run(jpegPath: CommandLine.arguments[i + 1], modes: modes.isEmpty ? [.legacy, .keep, .compact] : modes)
        exit(0)
    }
    RunLoop.main.run()
}
#endif

// Speaks each line after --say in turn with the chosen voice, tracing each
// word as it starts, then quits.
if let i = CommandLine.arguments.firstIndex(of: "--say"), CommandLine.arguments.count > i + 1 {
    let lines = Array(CommandLine.arguments.dropFirst(i + 1))
    Task { @MainActor in
        let narrator = Narrator()
        let start = Date()
        narrator.onWord = { print(String(format: "%5.2f s  %@", Date().timeIntervalSince(start), $0)) }
        for line in lines {
            await narrator.speak(line)
            print(String(format: "-- line done at %.2f s", Date().timeIntervalSince(start)))
        }
        print(String(format: "done at %.2f s with %@", Date().timeIntervalSince(start), Narrator.voiceName))
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

// Opened from the disk image, or from the copy macOS translocates a download to:
// before anything else, Navi moves itself into Applications and reopens from there
// (permissions and open at login are tied to where it lives). Nothing else starts.
if Relocation.needed {
    let mover = NSApplication.shared
    let relocation = RelocationDelegate()
    mover.delegate = relocation
    mover.setActivationPolicy(.accessory)
    MainMenu.install()
    mover.run()
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
#if DEBUG
// Test harness: `--fake-reply <file>` swaps Claude for a canned reply, and
// `--demo-ask "<question>"` asks once, two seconds after launch, without the hotkey.
if let i = CommandLine.arguments.firstIndex(of: "--fake-reply"), CommandLine.arguments.count > i + 1,
   let text = try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8) {
    controller.fake = FakeBackend(reply: text)
}
if let i = CommandLine.arguments.firstIndex(of: "--demo-ask"), CommandLine.arguments.count > i + 1 {
    let q = CommandLine.arguments[i + 1]
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { controller.ask(q) }
}
// `--install-claude-into <folder>`: Connect Claude's install step, into a throwaway
// home folder, to check it works without a terminal. Prints the outcome and quits.
if let i = CommandLine.arguments.firstIndex(of: "--install-claude-into"), CommandLine.arguments.count > i + 1 {
    ConnectClaude.install(home: CommandLine.arguments[i + 1]) { problem in
        print(problem.map { "FAILED: \($0)" } ?? "INSTALLED")
        exit(problem == nil ? 0 : 1)
    }
    RunLoop.main.run()
}
// `--render-askbar <png>`: the ask bar with a conversation chip and the paperclip, drawn
// off screen to a picture (nothing appears), to check its layout.
if let i = CommandLine.arguments.firstIndex(of: "--render-askbar"), CommandLine.arguments.count > i + 1 {
    let bar = PromptPanel()
    bar.showTopic("GIS coursework · 2 files")
    bar.field.placeholderString = "Ask about anything on screen"
    if CommandLine.arguments.contains("--dragging") { bar.setDropHint(true) }
    if let v = bar.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}
// `--history-sample`: the History window on made-up conversations and a kept lesson,
// to look at its design without touching the real ones.
if CommandLine.arguments.contains("--history-sample") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { HistorySample.show() }
}
// `--gallery <out-dir>`: the polish reel (see Gallery.swift).
if let i = CommandLine.arguments.firstIndex(of: "--gallery"), CommandLine.arguments.count > i + 1 {
    let dir = CommandLine.arguments[i + 1]
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await Gallery(app: controller, out: dir).run()
    }
}
#if DEBUG
// `--practice-check <out-dir>`: each practice move from real Claude (see Gallery.swift).
if let i = CommandLine.arguments.firstIndex(of: "--practice-check"), CommandLine.arguments.count > i + 1 {
    Task { @MainActor in
        await PracticeCheck.run(out: CommandLine.arguments[i + 1])
        exit(0)
    }
    RunLoop.main.run()
}
#endif
// `--stress <out-dir>`: the GUI stress test (see StressTest.swift).
if let i = CommandLine.arguments.firstIndex(of: "--stress"), CommandLine.arguments.count > i + 1 {
    let dir = CommandLine.arguments[i + 1]
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await StressTest(app: controller, out: dir).run()
    }
}
// `--demo-script <file>`: lines of "<seconds after launch> <question>", or "<seconds> ESC".
if let i = CommandLine.arguments.firstIndex(of: "--demo-script"), CommandLine.arguments.count > i + 1,
   let script = try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8) {
    for line in script.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let t = Double(parts[0]) else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            switch parts[1] {
            case "ESC": controller.escape()
            case "HANDSFREE": controller.demoHandsFree()
            case "SCROLL": controller.demoScroll()
            case "HISTORY": HistoryWindow.show()
            case "SETUP": controller.showSetup()
            case "PROMPT", "MUTED", "RECORDER": controller.demoShow(parts[1])
            case let q where q.hasPrefix("VOICE "): controller.ask(String(q.dropFirst(6)), byVoice: true)
            default: controller.ask(parts[1])
            }
        }
    }
}
#endif
app.delegate = controller
app.setActivationPolicy(.accessory)
// The standard editing keys (⌘V in the type bar and the key field), ⌘, and ⌘Q.
MainMenu.install()
// A shortcut another app owns is said on screen, with the way to change it.
ShortcutNotice.watch()
app.run()
