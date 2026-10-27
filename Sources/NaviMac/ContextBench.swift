import AppKit

#if DEBUG
/// `Navi --context-bench <screenshot.jpg> [compact keep legacy]`:
/// runs a 6-step lesson and a 4-question follow-up chain on the real
/// `claude -p` backend in each mode and prints latency and input tokens.
enum ContextBench {
    static func run(jpegPath: String, modes: [Conversation.Mode]) async {
        guard let jpeg = FileManager.default.contents(atPath: jpegPath),
              let img = NSImage(data: jpeg)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("can't read \(jpegPath)"); return
        }
        func turn(_ message: String) -> [[String: Any]] {
            [Prompt.text("Screen 1 (cursor is here): \(img.width)×\(img.height) px"), Prompt.image(jpeg), Prompt.text(message)]
        }
        var rows: [String] = ["mode\tscenario\tturn\taction\tfirst_text\tfirst_tag\tdone\tcontext_tokens\tnew\tcache_read\tcache_write\tout"]
        for mode in modes {
            let cli = CLIBackend()
            cli.prewarm()
            for scenario in ["lesson", "followups"] {
                cli.reset()   // each scenario starts clean, on the warm spare
                let conv = Conversation()
                conv.mode = mode
                conv.history = nil
                try? await Task.sleep(nanoseconds: 3_000_000_000)   // the user pressing and talking
                var lesson: Walkthrough?
                let questions = ["Where is the Wi-Fi status in the menu bar?", "no, the other one, the battery",
                                 "and what about the clock?", "why is that one on the right?"]
                let count = scenario == "lesson" ? 6 : questions.count
                for i in 0..<count {
                    let content: [[String: Any]]
                    let kind: Conversation.Kind
                    if scenario == "lesson" {
                        if let l = lesson {
                            content = turn(l.message(event: "the user clicked \"\(l.log.last ?? "")\" (step \(l.stepsTaken))."))
                            kind = .lessonStep
                        } else {
                            let goal = "How do I change my desktop wallpaper? Teach me step by step."
                            lesson = Walkthrough(goal: goal)
                            content = turn(goal)
                            kind = .question(goal)
                        }
                    } else {
                        content = turn(questions[i])
                        kind = .question(questions[i])
                    }
                    do {
                        let reply = try await conv.send(content, kind: kind, via: cli) { _ in }
                        let label = TagParser.parse(reply).annotations.compactMap { a -> String? in
                            if case .target(_, _, let l, _) = a { return l } else { return nil }
                        }.first
                        lesson?.record("Clicked \"\(label ?? "the target")\"")
                        let st = cli.lastStats ?? TurnStats(usage: nil)
                        func f(_ t: TimeInterval?) -> String { t.map { String(format: "%.2f", $0) } ?? "-" }
                        let action = i == 0 ? "fresh" : (mode == .compact ? "compact" : "keep")
                        rows.append("\(mode)\t\(scenario)\t\(i + 1)\t\(action)\t\(f(st.firstText))\t\(f(st.firstTag))\t\(f(st.total))\t"
                                    + "\(st.contextTokens)\t\(st.input)\t\(st.cacheRead)\t\(st.cacheWrite)\t\(st.output)")
                        print(rows.last!)
                    } catch {
                        print("error: \(error)")
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)   // settle after the click, or the next question
                }
            }
            cli.shutdown()
        }
        print("\n" + rows.joined(separator: "\n"))
    }
}
#endif
