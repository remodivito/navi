import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Checks added by the 2026-10-24 audit, one failing check per defect fixed.
/// Kept apart from the older check files so parallel fixes don't collide.
///
/// The `claude -p` backend is exercised against small shell scripts that speak
/// stream-json, stood in for `claude` through `ClaudeAccess.locator`, so the
/// process handling runs for real on any platform with /bin/sh.
public enum AuditChecksClaude {
    /// Stands a script in for `claude`.
    final class StubLocator: Shell.ClaudeLocator {
        let exe: String
        init(_ exe: String) { self.exe = exe }
        func executable() -> String? { exe }
        func path(for exe: String, inherited: String?) -> String { inherited ?? "/usr/bin:/bin" }
    }

    /// Writes a stub `claude` that reads one turn from stdin, then runs `body`
    /// (sh, with $line holding the turn). Returns its path.
    static func stub(_ name: String, _ body: String) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-audit-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".sh")
        let script = "#!/bin/sh\nIFS= read -r line\n" + body + "\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    static func delta(_ text: String) -> String {
        let obj: [String: Any] = ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": text]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }
    static func result(_ text: String, error: Bool = false) -> String {
        let obj: [String: Any] = ["type": "result", "subtype": error ? "error" : "success", "is_error": error, "result": text, "duration_ms": 1, "usage": [String: Any]()]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }
    /// A sh line that prints `s` followed by a newline, whatever it contains.
    static func echo(_ s: String) -> String { "printf '%s\\n' '" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// One turn through a CLI backend on `script` (a fresh one unless given); the
    /// reply or the error.
    @MainActor
    static func turn(_ script: String, _ backend: CLIBackend? = nil, onText: @escaping (String) -> Void = { _ in }) async -> Result<String, Error> {
        ClaudeAccess.locator = StubLocator(script)
        // A one-off backend isn't shut down: the stubs exit by themselves.
        let b = backend ?? CLIBackend()
        do { return .success(try await b.send([Prompt.text("hello")], onText: onText)) } catch { return .failure(error) }
    }

    @MainActor
    public static func run(_ check: (String, Bool) -> Void) async {
        let savedLocator = ClaudeAccess.locator
        defer { ClaudeAccess.locator = savedLocator }

        // MARK: The deny list: what `claude -p` may never read for Navi.
        // Tried against the real Claude Code (2.1.310) with canary files: a rule covers
        // the `~` form, the absolute path and a symlink into the folder, and Grep and
        // Glob are refused along with Read. What isn't listed is read, so the list
        // has to name every place secrets live. A bare `**/.env` only covered files
        // under the working directory (a temp folder): ~/project/.env was read.
        let off = CLIBackend.offLimits
        func denied(_ pattern: String) -> Bool {
            ["Read", "Grep", "Glob"].allSatisfy { off.contains("\($0)(\(pattern))") }
        }
        check("deny list: keys, clouds and shells' credentials",
              ["~/.ssh/**", "~/.gnupg/**", "~/.aws/**", "~/.azure/**", "~/.kube/**", "~/.docker/**", "~/.netrc",
               "~/.config/gh/**", "~/.config/gcloud/**", "~/.config/op/**", "~/.git-credentials", "~/.npmrc", "~/.pypirc",
               "~/.cargo/credentials*", "~/.gem/credentials", "~/.composer/auth.json", "~/.terraform.d/**"].allSatisfy(denied))
        check("deny list: Claude Code's own files, including ~/.claude.json beside the folder, and other agents' sign-ins",
              ["~/.claude/**", "~/.claude.json*", "~/.cursor/**", "~/.codex/**", "~/.gemini/**"].allSatisfy(denied))
        check("deny list: shell histories",
              ["~/.zsh_history", "~/.bash_history", "~/.zsh_sessions/**", "~/.local/share/fish/**", "~/.python_history", "~/.node_repl_history"].allSatisfy(denied))
        check("deny list: Keychains, cookies, accounts, mail, messages, browsers and sandboxed app data",
              ["~/Library/Keychains/**", "//Library/Keychains/**", "~/Library/Cookies/**", "~/Library/HTTPStorages/**", "~/Library/Accounts/**",
               "~/Library/Mail/**", "~/Library/Messages/**", "~/Library/Safari/**", "~/Library/Containers/**", "~/Library/Group Containers/**",
               "~/Library/Preferences/**",
               "~/Library/Application Support/Google/Chrome/**", "~/Library/Application Support/Firefox/**",
               "~/Library/Application Support/BraveSoftware/**", "~/Library/Application Support/Microsoft Edge/**",
               "~/Library/Application Support/Arc/**", "~/Library/Application Support/Chromium/**", "~/Library/Application Support/Vivaldi/**",
               "~/Library/Application Support/Slack/**", "~/Library/Application Support/discord/**", "~/Library/Application Support/Signal/**",
               "~/Library/Application Support/Telegram Desktop/**", "~/Library/Application Support/1Password/**",
               "~/Library/Application Support/Bitwarden/**"].allSatisfy(denied))
        check("deny list: secret files wherever they are, anchored at the root rather than the working directory",
              !off.contains("(**/") &&
              ["//**/.env", "//**/.env.*", "//**/*.env", "//**/.envrc", "//**/*.pem", "//**/*.key", "//**/*.p12", "//**/*.pfx", "//**/*.kdbx", "//**/*.ppk",
               "//**/*.keychain-db", "//**/*.ovpn", "//**/credentials*", "//**/id_rsa*", "//**/id_ed25519*", "//**/id_ecdsa*", "//**/id_dsa*"].allSatisfy(denied))
        // Claude Code splits the list on commas and spaces outside parentheses, so every
        // rule must be a Tool(pattern) with its spaces inside the parentheses.
        check("deny list: every rule is Tool(pattern), spaces only inside the parentheses",
              off.split(separator: ",").allSatisfy { $0.range(of: #"^(Read|Grep|Glob)\([^()]+\)$"#, options: .regularExpression) != nil })

        // MARK: Redaction: nothing token-shaped reaches a log, a transcript or the caption.
        let token = "sk-ant-oat01-" + String(repeating: "Ab3_", count: 20) + "x-9Q"   // 97 characters, like a real one
        func leaks(_ s: String) -> Bool {
            // A fragment this long is enough to recognise the token.
            s.range(of: #"[A-Za-z0-9_\-]{24,}"#, options: .regularExpression) != nil || s.contains("Ab3_Ab3_Ab3_Ab3_")
        }
        // setup-token prints the token in a pseudo-terminal that wraps it ("\r\n " or
        // a plain line break, padded or not), and a wrapped token is exactly the one
        // that misses `token(in:)` and ends up in the `.noToken` tail that's logged.
        let wraps = ["\r\n ", "\n", " ", "\r\n", "\r "]
        check("setup-token output: a token wrapped by the terminal is redacted whole",
              wraps.allSatisfy { wrap in
                  [40, 60, 78, 90].allSatisfy { at in
                      let out = "Use this token:\n\n" + token.prefix(at) + wrap + token.dropFirst(at) + "\n\nSuccessfully set up."
                      return !leaks(SignIn.redacted(out))
                  }
              })
        check("setup-token output: a token wrapped at a line break is still found",
              ["\r\n ", "\n", "\r "].allSatisfy { wrap in
                  SignIn.token(in: "Token:\n\n" + token.prefix(70) + wrap + token.dropFirst(70) + "\n\nDone.") == token
              } && SignIn.token(in: "Token:\n\n\(token)\n\nSuccessfully") == token)
        check("setup-token output: a token broken by a space isn't guessed at (the next word must not be glued on)",
              SignIn.token(in: "Token:\n\n" + token.prefix(70) + " " + token.dropFirst(70) + "\n\nDone.") == nil)
        let shapes = ["sk-ant-api03-" + String(repeating: "Q7", count: 40),
                      "ghp_" + String(repeating: "a1", count: 18), "github_pat_" + String(repeating: "Z9", count: 20),
                      "xoxb-123456789012-" + String(repeating: "k", count: 24), "AKIAIOSFODNN7EXAMPLE",
                      "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig", "_authToken=NPMTOKEN123456", "password: hunter2hunter2",
                      "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"]
        check("Redact.secrets: every common token shape goes",
              shapes.allSatisfy { s in
                  let r = Redact.secrets(in: "claude said: \(s) and stopped")
                  return !r.contains(s.split(separator: " ").last.map(String.init) ?? s) && r.contains("claude said")
              } && !Redact.secrets(in: shapes[8]).contains("b3BlbnNzaC1"))
        check("Redact.secrets: ordinary error text keeps its meaning",
              Redact.secrets(in: "Invalid OAuth token · Please run /login").contains("/login")
              && Redact.secrets(in: "You've hit your limit · resets 3pm (Europe/London)") == "You've hit your limit · resets 3pm (Europe/London)")

        // MARK: The `claude -p` process, run against stubs.
        // On Apple platforms these always run. Elsewhere they run only when asked
        // (NAVI_CHECK_PROCESSES=1): Linux's swift-corelibs can bring libdispatch down
        // on a fast run of spawn-and-exit cycles, a Foundation bug seen on the untouched
        // core too, and the Windows session needs a check run that is never flaky.
        #if canImport(Darwin)
        let runsProcesses = FileManager.default.isExecutableFile(atPath: "/bin/sh")
        #else
        let runsProcesses = ProcessInfo.processInfo.environment["NAVI_CHECK_PROCESSES"] != nil
        #endif
        if runsProcesses {

            // What claude is started with: no key in its environment, no saved
            // sessions, read-only tools only, and the deny list.
            let dump = stub("dump", """
                printf '%s\\n' "$@" > "$0.args"
                env > "$0.env"
                \(echo(delta("ok")))
                \(echo(result("ok")))
                """)
            setenv("ANTHROPIC_API_KEY", "sk-ant-api03-NOT-FOR-CLAUDE-P", 1)
            let parentHasKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil
            _ = await turn(dump)
            let args = (try? String(contentsOfFile: dump + ".args", encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            let env = (try? String(contentsOfFile: dump + ".env", encoding: .utf8)) ?? ""
            unsetenv("ANTHROPIC_API_KEY")
            check("claude -p never sees an API key", parentHasKey && !args.isEmpty && !env.contains("ANTHROPIC_API_KEY="))
            check("claude -p saves no sessions and runs no hooks", args.contains("--no-session-persistence") && args.contains("--setting-sources"))
            let tools = args.firstIndex(of: "--tools").map { args[$0 + 1] } ?? "?"
            check("claude -p gets read-only tools and the deny list",
                  Set(tools.split(separator: ",").map(String.init)).isSubset(of: ["WebSearch", "Read", "Glob", "Grep"])
                  && args.firstIndex(of: "--disallowedTools").map { args[$0 + 1] } == CLIBackend.offLimits)

            // A reply split anywhere: inside a JSON line and inside a UTF-8 character.
            let head = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","#
            let split = stub("split", """
                printf '%s' '\(head)' ; sleep 0.2 ; printf '%s\\n' '"text":"caf"}}}'
                printf '%s' '\(head)"text":"' ; printf '\\303' ; sleep 0.2 ; printf '\\251 done"}}}\\n'
                \(echo(result("café done")))
                """)
            var heard: [String] = []
            let r1 = await turn(split) { heard.append($0) }
            check("stream-json lines split across chunks, even mid-character, arrive whole",
                  (try? r1.get()) == "café done" && heard.last == "café done")

            // A process that answers and exits at once (bad sign-in): the answer must not be
            // lost to the exit being noticed first.
            let quick = stub("quick", """
                \(echo(result("Invalid API key · Please run /login", error: true)))
                exit 1
                """)
            // (Before the fix 2 of 12 runs lost it. A few runs here, spaced out: Linux's
            // Foundation can bring libdispatch down on a fast run of spawn-and-exit cycles.)
            var kept = 0
            for _ in 0..<4 {
                if case .failure(let e) = await turn(quick), ConnectionProblem(error: e) == .signInExpired { kept += 1 }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            check("an error result printed just before exit is kept, every time (4 runs)", kept == 4)

            // Cancelling mid-turn: the caller gets CancellationError, hears nothing after,
            // and the next ask works on the replacement process.
            let slow = stub("slow", """
                \(echo(delta("First")))
                sleep 2
                \(echo(delta(" and second")))
                \(echo(result("First and second")))
                """)
            ClaudeAccess.locator = StubLocator(slow)
            let b = CLIBackend()
            var afterCancel = false
            var cancelled = false
            let t = Task { @MainActor in
                do { _ = try await b.send([Prompt.text("hello")], onText: { _ in if cancelled { afterCancel = true } }) }
                catch is CancellationError { return true } catch { return false }
                return false
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            cancelled = true
            t.cancel()
            let sawCancel = await t.value
            try? await Task.sleep(nanoseconds: 100_000_000)
            let r4 = await turn(slow, b)
            check("cancel mid-turn: CancellationError, silence after, and the next ask works", sawCancel && !afterCancel && (try? r4.get()) == "First and second")
            b.shutdown()

            // A flood on stderr doesn't wedge the turn.
            let noisy = stub("noisy", """
                head -c 300000 /dev/zero | tr '\\0' 'x' >&2
                \(echo(delta("ok")))
                \(echo(result("ok")))
                """)
            let r5 = await turn(noisy)
            check("300 KB on stderr doesn't block the answer", (try? r5.get()) == "ok")

            // Claude Code's last words on stderr are what the user sees, however they're
            // written: a chunk boundary inside a character must not drop the chunk.
            let utf8err = stub("utf8err", """
                printf '\\342\\200' >&2
                sleep 0.2
                printf '\\224 Not logged in \\303\\240 la Claude\\n' >&2
                exit 1
                """)
            let r2 = await turn(utf8err)
            check("a stderr message split mid-character still reaches the user",
                  { if case .failure(let e) = r2 { return e.localizedDescription.contains("Claude Code needs you to sign in") }; return false }())

            // A token on stderr (Claude Code echoing what it was given) never reaches the error.
            let leaky = stub("leaky", """
                printf 'Invalid OAuth token: %s\\n' '\(token)' >&2
                exit 1
                """)
            let r3 = await turn(leaky)
            check("a token in claude's stderr is redacted before it can reach the transcript or caption",
                  { if case .failure(let e) = r3 { return !leaks(e.localizedDescription) && !leaks(String(describing: e)) }; return false }())

            // A result that carries its reasons in `errors` (error_during_execution,
            // error_max_turns) rather than `result`: the reason is what tells a plan
            // limit from anything else.
            let errs = CLIBackend.result(from: ["type": "result", "subtype": "error_during_execution", "is_error": true,
                                                 "errors": ["You've hit your limit · resets 3pm (Europe/London)"]])
            check("a result with only an `errors` list keeps the reason",
                  { if case .failure(let e)? = errs { return ConnectionProblem(error: e) == .planLimit("at 3pm") }; return false }())
        }

        // MARK: Error → sentence mappings
        // The API's mid-stream overload event arrived as a raw "Stream error: Overloaded".
        check("an overloaded stream is 'busy', not a raw stream error",
              ConnectionProblem(error: ClaudeError.stream("Overloaded")) == .busy
              && ClaudeError.stream("Overloaded").localizedDescription == ConnectionProblem.busy.spoken
              && ConnectionProblem(error: ClaudeError.stream("something else")) == nil)
        // A Claude Code from before --effort or --disable-slash-commands exits at once
        // with commander's "unknown option"; the first-time user needs told to update.
        check("an old Claude Code that doesn't know Navi's flags says to update",
              ConnectionProblem(cliText: "error: unknown option '--effort'")?.sentence.contains("update") == true)
        // "529" matched inside any number: a stderr line with a timing or an address said "busy".
        check("'529' inside another number isn't a busy signal", ConnectionProblem(cliText: "request took 1529ms") == nil
              && ConnectionProblem(cliText: "API Error: 529 overloaded") == .busy && ConnectionProblem(cliText: "status 529") == .busy)
    }
}
