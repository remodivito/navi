import Foundation

/// Finds the `claude` binary and asks it, read-only, whether it is signed in.
/// Never runs `claude auth login` and never reads Claude Code's credentials.
enum ClaudeCode {
    /// The login shell's answer to `command -v claude`, found once per launch.
    /// Apps opened from Finder get only /usr/bin:/bin:/usr/sbin:/sbin, so nvm,
    /// volta and friends are invisible without asking the shell.
    private(set) static var shellPath: String?

    /// Install locations in the order they're tried after a chosen path.
    static func candidates() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var c: [String] = []
        if !Settings.shared.claudePath.isEmpty { c.append(Settings.shared.claudePath) }
        if let p = env["CLAUDE_PATH"] { c.append(p) }
        c += ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
              "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
              "\(home)/.volta/bin/claude"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            c += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/claude" }
        }
        c += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        if let shellPath { c.append(shellPath) }
        return c
    }

    static func executable() -> String? {
        candidates().first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// An npm install is a node script: put its own bin directory first so
    /// `node` resolves even with Finder's short PATH.
    static func path(for exe: String, inherited: String?) -> String {
        (exe as NSString).deletingLastPathComponent + ":" + (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// The environment `claude` runs in, for the probe and for `claude -p`.
    static func environment(for exe: String) -> [String: String] { ClaudeAccess.environment(for: exe) }

    enum Probe: Equatable {
        case notInstalled
        case unresponsive(path: String)
        case found(ClaudeCodeStatus)
    }

    static func probe() async -> Probe {
        if executable() == nil, shellPath == nil, let found = await askLoginShell() {
            shellPath = found
            trace("Connection: found claude via the login shell")
        }
        guard let exe = executable() else { return .notInstalled }
        let env = environment(for: exe)
        guard let v = await run(exe, ["--version"], env: env, timeout: 5), v.status == 0 else {
            return .unresponsive(path: exe)
        }
        let version = v.out.split(separator: " ").first.map(String.init) ?? v.out
        // Exit 1 means signed out, and the JSON is still printed.
        guard let s = await run(exe, ["auth", "status", "--json"], env: env, timeout: 5),
              let start = s.out.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(s.out[start...].utf8)) as? [String: Any] else {
            return .unresponsive(path: exe)
        }
        return .found(ClaudeCodeStatus(path: exe, version: version.trimmingCharacters(in: .whitespacesAndNewlines),
                                       loggedIn: obj["loggedIn"] as? Bool ?? false,
                                       authMethod: obj["authMethod"] as? String ?? "none",
                                       subscription: obj["subscriptionType"] as? String))
    }

    private static func askLoginShell() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let r = await run(shell, ["-ilc", "command -v claude"], env: nil, timeout: 3) else { return nil }
        return r.out.split(separator: "\n").map(String.init).last { $0.hasPrefix("/") }
    }

    /// Runs a command off the main thread; nil if it couldn't start or timed out.
    private static func run(_ exe: String, _ args: [String], env: [String: String]?,
                            timeout: TimeInterval) async -> (status: Int32, out: String)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let env { p.environment = env }
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                // SIGTERM can be ignored (a shell waiting on its .zshrc, a wedged network call):
                // SIGKILL two seconds later, so the reads below always end.
                let kill = DispatchWorkItem {
                    guard p.isRunning else { return }
                    p.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                kill.cancel()
                guard p.terminationReason == .exit else { cont.resume(returning: nil); return }
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// The live state of both connections, for the setup window and the menu.
/// Probes run in the background; readers get the last answer and never wait.
/// All state lives on the main queue.
@MainActor
final class Connection {
    static let shared = Connection()

    enum CLIState: Equatable {
        case checking
        case ready(ClaudeCodeStatus)
        case problem(ConnectionProblem, ClaudeCodeStatus?)
    }

    enum KeyState: Equatable {
        case none
        case checking
        /// `fromEnvironment`: ANTHROPIC_API_KEY, used only when no key is saved.
        case ready(masked: String, fromEnvironment: Bool)
        case problem(ConnectionProblem, masked: String)
    }

    private(set) var claudeCode: CLIState = .checking
    private(set) var apiKey: KeyState = .none
    /// A failure seen on a real ask (expired sign-in, plan limit), cleared by
    /// the next answer or a fresh probe.
    private(set) var runtimeProblem: (Backend, ConnectionProblem)?

    /// Called on the main queue whenever anything above changes.
    var onChange: [() -> Void] = []
    private var probing: Task<Void, Never>?
    /// Which probe is current: one that outlived the ceiling doesn't overwrite a later answer.
    private var probeGen = 0
    /// However a probe hangs (a child keeping its pipe open), "Looking for Claude Code…" ends.
    static let probeCeiling: TimeInterval = 20

    private init() {}

    /// The problem with the connection in use, if any.
    var activeProblem: ConnectionProblem? { problem(for: Settings.shared.backend) }

    /// What's wrong with one connection, whether or not it's in use.
    func problem(for b: Backend) -> ConnectionProblem? {
        if let (rb, p) = runtimeProblem, rb == b { return p }
        switch b {
        case .cli:
            if case .problem(let p, _) = claudeCode { return p }
        case .api:
            switch apiKey {
            case .none: return .noKey
            case .problem(let p, _): return p
            default: break
            }
        }
        return nil
    }

    /// One line for the menu: "Claude Code · Max plan", or what's wrong.
    var statusLine: String {
        if let p = activeProblem { return p.sentence }
        switch Settings.shared.backend {
        case .cli:
            if case .ready(let s) = claudeCode { return "Claude Code · " + s.planName }
            return "Looking for Claude Code…"
        case .api:
            if case .ready(let masked, let env) = apiKey { return "API key " + masked + (env ? " (from environment)" : "") }
            return "Checking your API key…"
        }
    }

    /// Re-checks both. Calls while one is running share it.
    func refresh() {
        guard probing == nil else { return }
        probeGen += 1
        let gen = probeGen
        probing = Task { [weak self] in
            async let cli = ClaudeCode.probe()
            async let key = Self.checkSavedKey()
            let (c, k) = await (cli, key)
            guard let self, gen == self.probeGen else { return }
            self.probing = nil
            self.claudeCode = Self.state(c)
            if let k { self.apiKey = k }
            if case .ready = self.claudeCode, self.runtimeProblem?.0 == .cli { self.runtimeProblem = nil }
            trace("Connection: \(self.claudeCode.traceText), key \(self.apiKey.traceText)")
            self.chooseOnFirstRun()
            self.changed()
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.probeCeiling * 1_000_000_000))
            guard let self, gen == self.probeGen, self.probing != nil else { return }
            trace("Connection: the probe took over \(Int(Self.probeCeiling))s; calling Claude Code unresponsive.")
            self.probeGen += 1   // its late answer is dropped; the next refresh starts afresh
            self.probing = nil
            if case .checking = self.claudeCode { self.claudeCode = .problem(.unresponsive, nil) }
            self.changed()
        }
    }

    /// Checks a pasted key against Anthropic and saves it only if it works.
    /// Returns the problem, or nil once it's saved.
    func saveKey(_ raw: String) async -> ConnectionProblem? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .noKey }
        apiKey = .checking
        changed()
        if let p = await Self.check(key) {
            apiKey = Keychain.apiKey.map { .ready(masked: Keychain.masked($0), fromEnvironment: false) } ?? .none
            changed()
            return p
        }
        guard Keychain.setAPIKey(key) else {
            apiKey = .none
            changed()
            return .other("macOS wouldn't save the key in your Keychain.")
        }
        apiKey = .ready(masked: Keychain.masked(key), fromEnvironment: false)
        if runtimeProblem?.0 == .api { runtimeProblem = nil }
        trace("Connection: API key saved to the Keychain")
        changed()
        return nil
    }

    func removeKey() {
        Keychain.removeAPIKey()
        apiKey = Self.environmentKey.map { .ready(masked: Keychain.masked($0), fromEnvironment: true) } ?? .none
        trace("Connection: API key removed")
        changed()
    }

    /// The user picked a connection: theirs from now on.
    func choose(_ b: Backend) {
        Settings.shared.backend = b
        Settings.shared.backendChosen = true
        changed()
    }

    /// A real ask failed or worked; keeps the status honest between probes.
    nonisolated static func report(_ result: Result<Void, Error>, via b: Backend) {
        Task { @MainActor in shared.note(result, via: b) }
    }

    private func note(_ result: Result<Void, Error>, via b: Backend) {
        switch result {
        case .success:
            guard runtimeProblem?.0 == b else { return }
            runtimeProblem = nil
        case .failure(let e):
            guard let p = ConnectionProblem(error: e) else { return }
            switch p {
            case .busy, .unreachable, .other: return   // passing trouble, not a connection state
            default: break
            }
            runtimeProblem = (b, p)
            trace("Connection: an ask failed: \(p.sentence)")
            refresh()
        }
        changed()
    }

    /// First run only: Claude Code if it's signed in, else a working saved key.
    /// After that the user's choice stands; billing never switches by itself.
    private func chooseOnFirstRun() {
        let s = Settings.shared
        guard !s.backendChosen else { return }
        if case .ready = claudeCode {
            s.backend = .cli
        } else if case .ready = apiKey {
            s.backend = .api
        } else {
            return
        }
        s.backendChosen = true
        trace("Connection: first run chose \(s.backend.rawValue)")
    }

    private func changed() { onChange.forEach { $0() } }

    private static func state(_ p: ClaudeCode.Probe) -> CLIState {
        switch p {
        case .notInstalled: return .problem(.notInstalled, nil)
        case .unresponsive: return .problem(.unresponsive, nil)
        case .found(let s): return s.loggedIn ? .ready(s) : .problem(.notSignedIn, s)
        }
    }

    nonisolated private static var environmentKey: String? {
        ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The key the API backend uses: the saved one, else the environment's.
    nonisolated static var currentKey: String? { Keychain.apiKey ?? environmentKey }

    private static func checkSavedKey() async -> KeyState? {
        guard let key = currentKey else { return KeyState.none }
        let masked = Keychain.masked(key), env = Keychain.apiKey == nil
        switch await check(key) {
        case nil: return .ready(masked: masked, fromEnvironment: env)
        // Offline or busy says nothing about the key: keep what we knew.
        case .unreachable?, .busy?: return .ready(masked: masked, fromEnvironment: env)
        case let p?: return .problem(p, masked: masked)
        }
    }

    /// `GET /v1/models`: free, uses no tokens, and fails exactly as a bad key
    /// would on a real ask. A key with no credit may still pass; that shows up
    /// on the first ask instead.
    static func check(_ key: String) async -> ConnectionProblem? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        req.timeoutInterval = 15
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Rate-limited still means the key itself works.
            if status == 429 { return nil }
            return ConnectionProblem(status: status, body: String(decoding: data, as: UTF8.self))
        } catch {
            return .unreachable
        }
    }
}

private extension Connection.CLIState {
    var traceText: String {
        switch self {
        case .checking: return "checking"
        case .ready(let s): return "claude \(s.version) ready (\(s.authMethod), \(s.subscription ?? "-"))"
        case .problem(let p, _): return "claude: \(p.sentence)"
        }
    }
}

private extension Connection.KeyState {
    var traceText: String {
        switch self {
        case .none: return "none"
        case .checking: return "checking"
        case .ready(_, let env): return env ? "ready (environment)" : "ready (Keychain)"
        case .problem(let p, _): return p.sentence
        }
    }
}
