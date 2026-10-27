import Foundation

/// Keeps a `claude -p` process alive and feeds it turns over stream-json,
/// so each ask skips start-up. Uses your Claude Code login, not an API key.
///
/// Two processes: the active one holds the conversation, and once it has had
/// a turn a spare one is started beside it with no history. `reset()` swaps
/// the spare in, so a fresh context (a new topic, a compacted lesson step, the
/// idle timeout, a cancel) never waits for start-up. An idle `claude -p` is
/// ~55 MB. All state lives on the main queue.
public final class CLIBackend: ChatBackend {
    public init() {}
    /// Idle time after which the conversation is dropped.
    public static let staleAfter: TimeInterval = 15 * 60

    /// One `claude -p` process and its pipes.
    private final class Slot {
        let process: Process
        let stdin: FileHandle
        let args: [String]
        let spawnedAt = Date()
        var buffer = Data()
        /// The last of stderr, kept as bytes: a chunk can end inside a character.
        var stderrBytes = Data()
        var stderrTail: String { String(decoding: stderrBytes, as: UTF8.self) }
        public var hasHistory = false
        /// How it ended: its exit status, whether each pipe has closed, and whether that's been dealt with.
        var exitStatus: Int32?
        var outClosed = false, errClosed = false, ended = false
        init(process: Process, stdin: FileHandle, args: [String]) {
            self.process = process
            self.stdin = stdin
            self.args = args
        }
    }

    private var active: Slot?
    private var spare: Slot?
    private var lastUsed = Date.distantPast
    private var staleTimer: Timer?
    private var shutDown = false

    private var continuation: CheckedContinuation<String, Error>?
    private var streamed = ""
    private var onText: ((String) -> Void)?

    /// Tokens and timing of the last finished turn.
    public private(set) var lastStats: TurnStats?

    // Debug timing, see `Timing`.
    private var turnAt = Date.distantPast
    private var firstTextAt: Date?
    private var firstTagAt: Date?

    public static func executable() -> String? { ClaudeAccess.executable() }

    /// The `model` from ~/.claude/settings.json, i.e. what `claude` uses by default.
    public static func userDefaultModel() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["model"] as? String
    }

    /// Whether the active process has had a turn, i.e. there is a conversation to drop.
    public var hasHistory: Bool { active?.hasHistory == true }
    public var holdsHistory: Bool { hasHistory && Date().timeIntervalSince(lastUsed) <= Self.staleAfter }

    /// Start the process ahead of time so the first ask is quick.
    public func prewarm() {
        shutDown = false
        if active?.process.isRunning != true { active = try? spawn() }
    }

    /// Drops the conversation. The spare (already warm) takes over when there
    /// is one; otherwise the replacement starts at once.
    public func reset() {
        shutDown = false
        // A process started with other settings (a tool switched off, say) is replaced even if it's fresh.
        let stale = active.map { $0.args != Self.arguments() } ?? false
        guard stale || continuation != nil || active?.hasHistory == true || active?.process.isRunning != true else { return }
        stop(error: continuation != nil ? CancellationError() : nil)
        if let s = spare, s.process.isRunning, s.args == Self.arguments() {
            spare = nil
            active = s
            Timing.log("swapped in the spare process (warm for \(Timing.ms(s.spawnedAt, Date())))")
        } else {
            discardSpare()
            prewarm()
        }
    }

    /// Stops both processes for good (app quitting); nothing is restarted.
    public func shutdown() {
        shutDown = true
        staleTimer?.invalidate()
        stop()
        discardSpare()
    }

    public func send(_ content: [[String: Any]], onText: @escaping (String) -> Void) async throws -> String {
        // Backstop for a timer that fired late (e.g. across sleep).
        if hasHistory, Date().timeIntervalSince(lastUsed) > Self.staleAfter { reset() }
        if active?.process.isRunning != true {
            Timing.log("cold start: no warm process")
            active = try spawn()
        }
        if continuation != nil {
            // A newer request (a step taken, a fresh look) replaces one still running:
            // drop the busy process for the warm spare rather than failing the new one.
            Timing.log("a newer turn replaces the one still running")
            finish(.failure(CancellationError()))
            reset()
            if active?.process.isRunning != true { active = try spawn() }
        }
        guard continuation == nil, let slot = active else { throw ClaudeCLIError.failed("a turn is already running") }
        lastUsed = Date()
        slot.hasHistory = true
        staleTimer?.invalidate()

        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var data = try JSONSerialization.data(withJSONObject: line)
        data.append(0x0A)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                self.streamed = ""
                self.onText = onText
                self.turnAt = Date()
                NotificationCenter.default.post(name: .naviWaiting, object: Shell.Waiting.sent)
                self.firstTextAt = nil
                self.firstTagAt = nil
                self.lastStats = nil
                Timing.log("turn sent; process warm for \(Timing.ms(slot.spawnedAt, self.turnAt))")
                slot.stdin.write(data)
            }
        } onCancel: {
            // There's no clean mid-turn interrupt over stdin, so drop this
            // process and let the warm spare take the next ask.
            DispatchQueue.main.async {
                self.finish(.failure(CancellationError()))
                if !self.shutDown { self.reset() } else { self.stop() }
            }
        }
    }

    /// After `staleAfter` of idle time, swap in a fresh process right away so
    /// the next ask after a break is still warm.
    private func armStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: Self.staleAfter, repeats: false) { [weak self] _ in
            guard let self, self.continuation == nil, self.hasHistory, !self.shutDown else { return }
            Timing.log("idle \(Int(Self.staleAfter))s: restarting for a fresh conversation")
            self.reset()
        }
    }

    /// Where secrets live: Claude's read tools never go there, whatever it's asked.
    /// Claude Code matches these against the resolved path (so `~`, the full path
    /// and a symlink all count) and refuses Grep and Glob there too; anything not
    /// listed it reads, so the list names every place a secret or a private
    /// record lives. Spaces are fine inside the parentheses.
    public static let offLimits = [
        // Keys, clouds, package registries, shells.
        "~/.ssh/**", "~/.gnupg/**", "~/.aws/**", "~/.azure/**", "~/.kube/**", "~/.docker/**", "~/.netrc",
        "~/.config/**", "~/.config/gh/**", "~/.config/gcloud/**", "~/.config/op/**", "~/.git-credentials", "~/.npmrc", "~/.pypirc",
        "~/.cargo/credentials*", "~/.gem/credentials", "~/.composer/auth.json", "~/.terraform.d/**",
        // Claude Code's own files (~/.claude.json sits beside the folder) and other agents' sign-ins.
        "~/.claude/**", "~/.claude.json*", "~/.cursor/**", "~/.codex/**", "~/.gemini/**",
        // Shell histories: commands with passwords typed into them.
        "~/.zsh_history", "~/.bash_history", "~/.zsh_sessions/**", "~/.local/share/fish/**", "~/.python_history", "~/.node_repl_history",
        // Keychains, cookies, accounts, mail, messages, browser profiles and sandboxed apps' data (Notes, WhatsApp, 1Password…).
        "~/Library/Keychains/**", "//Library/Keychains/**", "~/Library/Cookies/**", "~/Library/HTTPStorages/**", "~/Library/Accounts/**",
        "~/Library/Mail/**", "~/Library/Messages/**", "~/Library/Safari/**", "~/Library/Containers/**", "~/Library/Group Containers/**",
        "~/Library/Preferences/**",
        "~/Library/Application Support/Google/Chrome/**", "~/Library/Application Support/Firefox/**",
        "~/Library/Application Support/BraveSoftware/**", "~/Library/Application Support/Microsoft Edge/**",
        "~/Library/Application Support/Arc/**", "~/Library/Application Support/Chromium/**", "~/Library/Application Support/Vivaldi/**",
        "~/Library/Application Support/Slack/**", "~/Library/Application Support/discord/**", "~/Library/Application Support/Signal/**",
        "~/Library/Application Support/Telegram Desktop/**", "~/Library/Application Support/1Password/**",
        "~/Library/Application Support/Bitwarden/**",
        // Secret files wherever they are. A bare `**/` is relative to the working
        // directory (Navi's is a temp folder), so these start from the root (`//`).
        "//**/.env", "//**/.env.*", "//**/*.env", "//**/.envrc", "//**/*.pem", "//**/*.key", "//**/*.p12", "//**/*.pfx", "//**/*.kdbx", "//**/*.ppk",
        "//**/*.keychain-db", "//**/*.ovpn", "//**/credentials*", "//**/id_rsa*", "//**/id_ed25519*", "//**/id_ecdsa*", "//**/id_dsa*",
    ].flatMap { ["Read(\($0))", "Grep(\($0))", "Glob(\($0))"] }.joined(separator: ",")

    /// The command line for the current settings. A spare started with
    /// different settings (model, effort) isn't used.
    private static func arguments() -> [String] {
        let settings = Settings.shared
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",    // stream text as it's written
            "--system-prompt", Prompt.system(for: .current, tools: Prompt.tools(cli: true, readFiles: settings.readFiles)),
            // Web search, for real links (a page to open, a file to download); no fetch,
            // since opening the page and looking is quicker and shows them. And reading
            // the Mac, read-only: installed apps, local files, Navi's own past
            // conversations. Nothing that runs commands or writes; secrets are off limits.
            "--tools", settings.readFiles ? "WebSearch,Read,Glob,Grep" : "WebSearch",
            "--allowedTools", settings.readFiles ? "WebSearch,Read,Glob,Grep" : "WebSearch",
            "--disallowedTools", Self.offLimits,
            "--strict-mcp-config",           // skip MCP servers: faster start-up
            "--disable-slash-commands",
            "--no-session-persistence",
            // Skip user/project settings, so their hooks don't run on every
            // turn (~60 ms before the request, ~100 ms after). Sign-in is unaffected.
            "--setting-sources", "",
            "--effort", settings.effort,
        ]
        // Skipping settings also skips the user's default model, so pass it on.
        let model = settings.model.isEmpty ? userDefaultModel() : settings.model
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    private func spawn() throws -> Slot {
        guard let exe = Self.executable() else { throw ClaudeCLIError.notFound }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        let args = Self.arguments()
        p.arguments = args
        // Run somewhere neutral so no project CLAUDE.md gets pulled in.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        // No ANTHROPIC_API_KEY, so plan usage never turns into API billing.
        var env = ClaudeAccess.environment(for: exe)
        // Skips the post-turn summary request, which held back each result
        // by ~1 s (and used plan quota), plus telemetry.
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let slot = Slot(process: p, stdin: inPipe.fileHandleForWriting, args: args)

        // The exit can be noticed before the last of the output has been read, and a
        // process that prints an error and exits at once (a bad sign-in) would lose its
        // one line of explanation that way. So each pipe reads itself to its end, and
        // the exit is dealt with once both have closed (`ended`).
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak slot] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil }   // the end of its output
            DispatchQueue.main.async {
                guard let self, let slot else { return }
                if chunk.isEmpty { slot.outClosed = true; self.ended(slot) } else { self.consume(chunk, from: slot) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self, weak slot] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard let self, let slot else { return }
                if chunk.isEmpty { slot.errClosed = true; self.ended(slot) } else { slot.stderrBytes = (slot.stderrBytes + chunk).suffix(2000) }
            }
        }
        p.terminationHandler = { [weak self, weak slot] proc in
            DispatchQueue.main.async {
                guard let self, let slot else { return }
                slot.exitStatus = proc.terminationStatus
                self.ended(slot)
                // Should its output never close (something it started still holds the
                // pipe), don't wait for it beyond a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak slot] in
                    guard let self, let slot else { return }
                    slot.outClosed = true
                    slot.errClosed = true
                    self.ended(slot)
                }
            }
        }

        let t0 = Date()
        try p.run()
        Timing.log("spawned in \(Timing.ms(t0, Date()))")
        return slot
    }

    /// A process has exited and its output has all been read: the turn it was
    /// running fails with its last words, and it's replaced when that's wise.
    private func ended(_ slot: Slot) {
        guard let status = slot.exitStatus, slot.outClosed, slot.errClosed, !slot.ended else { return }
        slot.ended = true
        if spare === slot { spare = nil; return }
        guard active === slot else { return }
        active = nil
        let lived = Date().timeIntervalSince(slot.spawnedAt)
        Timing.log("process exited (\(status)) after \(Int(lived))s")
        // Its last words reach the caption and the transcript, so never a token.
        let words = Redact.secrets(in: slot.stderrTail)
        finish(.failure(ClaudeCLIError.exited(words.isEmpty ? "exit \(status)" : words)))
        // Replace it, unless it died straight away (bad login or
        // config): then the next ask restarts it and shows the error.
        if lived > 10, !shutDown { reset() }
    }

    /// Starts the spare once the active process has a conversation to lose.
    private func spawnSpare() {
        guard !shutDown, active?.hasHistory == true, spare?.process.isRunning != true else { return }
        spare = try? spawn()
    }

    private static func kill(_ slot: Slot) {
        (slot.process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (slot.process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        slot.process.terminationHandler = nil
        if slot.process.isRunning { slot.process.terminate() }
        try? slot.stdin.close()
    }

    private func discardSpare() {
        if let s = spare { Self.kill(s) }
        spare = nil
    }

    private func stop(error: Error? = nil) {
        // Detach the old pipes so late output can't leak into the next turn.
        if let a = active { Self.kill(a) }
        active = nil
        staleTimer?.invalidate()
        if let error { finish(.failure(error)) }
    }

    private func consume(_ chunk: Data, from slot: Slot) {
        guard !chunk.isEmpty else { return }
        slot.buffer.append(chunk)
        while let nl = slot.buffer.firstIndex(of: 0x0A) {
            let line = slot.buffer[slot.buffer.startIndex..<nl]
            slot.buffer = Data(slot.buffer[slot.buffer.index(after: nl)...])
            // A spare's start-up chatter, or a dropped process's last words.
            guard slot === active,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return }
            // After a web lookup the answer carries on in a new message: keep it on a new line.
            if event["type"] as? String == "message_start", !streamed.isEmpty, !streamed.hasSuffix("\n") { streamed += "\n" }
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any], block["type"] as? String == "thinking" {
                NotificationCenter.default.post(name: .naviWaiting, object: Shell.Waiting.thinking(tokens: 0))
            }
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any], (block["type"] as? String)?.hasSuffix("tool_use") == true {
                let name = block["name"] as? String ?? "?"
                Timing.log("tool: \(name)")
                NotificationCenter.default.post(name: .naviLookingUp, object: name)
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let t = delta["text"] as? String else { return }
            streamed += t
            let now = Date()
            if firstTextAt == nil {
                firstTextAt = now
                Timing.log("first text +\(Timing.ms(turnAt, now))")
            }
            if firstTagAt == nil, !TagParser.parse(streamed).annotations.isEmpty {
                firstTagAt = now
                Timing.log("first tag +\(Timing.ms(turnAt, now))")
            }
            onText?(streamed)
        case "system" where obj["subtype"] as? String == "thinking_tokens":
            // Claude Code's running estimate of the thinking so far (the thinking itself isn't shared).
            if let n = obj["estimated_tokens"] as? Int {
                NotificationCenter.default.post(name: .naviWaiting, object: Shell.Waiting.thinking(tokens: n))
            }
        case "result":
            let total = Date().timeIntervalSince(turnAt) * 1000
            let dur = obj["duration_ms"] as? Double ?? 0, api = obj["duration_api_ms"] as? Double ?? 0
            let model = (obj["modelUsage"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "?"
            Timing.log(String(format: "result +%.0fms (CLI duration %.0fms = API %.0fms + CLI overhead %.0fms) ",
                              total, dur, api, dur - api) + model)
            var stats = TurnStats(usage: obj["usage"] as? [String: Any])
            stats.firstText = firstTextAt.map { $0.timeIntervalSince(turnAt) }
            stats.firstTag = firstTagAt.map { $0.timeIntervalSince(turnAt) }
            stats.total = total / 1000
            lastStats = stats
            // The streamed text is the whole answer, including any words before a lookup;
            // the result holds only the last message.
            if let r = Self.result(from: obj) {
                if case .success = r, !streamed.isEmpty { finish(.success(streamed)) } else { finish(r) }
            }
        default:
            break
        }
    }

    public static func result(from obj: [String: Any]) -> Result<String, Error>? {
        guard obj["type"] as? String == "result" else { return nil }
        let text = obj["result"] as? String ?? ""
        if obj["is_error"] as? Bool == true || text.isEmpty {
            // A failure before the model answered (error_during_execution, error_max_turns)
            // has no `result`; its reasons are in `errors`.
            let reasons = (obj["errors"] as? [String])?.joined(separator: " ") ?? ""
            let why = !text.isEmpty ? text : !reasons.isEmpty ? reasons : (obj["subtype"] as? String ?? "error")
            return .failure(ClaudeCLIError.failed(Redact.secrets(in: why)))
        }
        return .success(text)
    }

    private func finish(_ result: Result<String, Error>) {
        guard let cont = continuation else { return }
        ClaudeAccess.report(result.map { _ in () }, .cli)
        continuation = nil
        onText = nil
        if active != nil {
            armStaleTimer()
            // Get the spare going while the answer plays, ready for the next fresh context.
            DispatchQueue.main.async { self.spawnSpare() }
        }
        cont.resume(with: result)
    }
}

/// Latency logs for the `claude -p` path: printed in debug builds, or in
/// any build with NAVI_TIMING=1.
enum Timing {
    // Always on: a few lines per question, and the app log is where slow answers get explained.
    static let enabled = true

    static func log(_ s: @autoclosure () -> String) {
        if enabled { trace("[cli-timing] \(s())") }
    }

    static func ms(_ a: Date, _ b: Date) -> String { "\(Int(b.timeIntervalSince(a) * 1000))ms" }
}
