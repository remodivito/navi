import Foundation

/// Tokens and timing for one turn, as the backend reported them.
public struct TurnStats {
    public var input = 0, cacheRead = 0, cacheWrite = 0, output = 0
    public var firstText: TimeInterval?, firstTag: TimeInterval?, total: TimeInterval?

    public init(usage: [String: Any]?) {
        input = usage?["input_tokens"] as? Int ?? 0
        cacheRead = usage?["cache_read_input_tokens"] as? Int ?? 0
        cacheWrite = usage?["cache_creation_input_tokens"] as? Int ?? 0
        output = usage?["output_tokens"] as? Int ?? 0
    }

    /// Everything the model read this turn: system prompt, history and the new turn.
    public var contextTokens: Int { input + cacheRead + cacheWrite }

    public var summary: String {
        func s(_ t: TimeInterval?) -> String { t.map { String(format: "%.2fs", $0) } ?? "-" }
        return "in \(contextTokens) tokens (\(input) new + \(cacheRead) cache read + \(cacheWrite) cache write), "
            + "out \(output); first text \(s(firstText)), first tag \(s(firstTag)), done \(s(total))"
    }
}

/// One conversation that lasts as long as the user's work does: it carries on until
/// they start fresh (× on the topic, New conversation, "new question"), however long
/// the gaps between questions. It lives here, in Navi, not in Claude's process: each
/// fresh process gets a recap, so a long break, a sleep or a restart (it's saved,
/// `store`) loses nothing. It decides what each turn carries into the model, so
/// context stays useful but small:
/// - Only the newest screenshot goes, plus the previous one for a question asked
///   within two minutes, so "no, the other one" works after the screen moved.
/// - Earlier turns go as a text recap of fixed size: the last few in full, older
///   ones a line each. The model uses it only if the question refers to it.
/// - After `longBreak` the recap says so, and the app offers to start fresh.
/// - Files given to the conversation go with every question, by name.
/// - A lesson step keeps the text of recent turns but only the newest screenshot.
/// - Lessons carry their own state (goal and step log, see `Walkthrough`), so
///   a step needs only the last reply from the history.
///
/// The API backend strips old screenshots from its own message list. The CLI
/// can't edit the history inside `claude -p`, so there "compact" swaps in the
/// warm spare process and opens with a short text recap instead.
public final class Conversation {
    public enum Kind {
        /// Something the user asked outside a lesson.
        case question(String)
        /// A lesson step: a click, a hover, a scroll or "continue".
        case lessonStep
        /// A correction sent straight after a reply (the explanation redraw).
        case retry
    }

    /// `compact` is the app's behaviour. `keep` (fresh topics only) and
    /// `legacy` (one conversation) exist to measure against:
    /// NAVI_CONTEXT=keep|legacy.
    public enum Mode: String { case compact, keep, legacy }

    private enum Action: String { case fresh, keep, compact }

    public struct Exchange {
        public let said: String
        public var reply: String
        public let at: Date
        /// That turn's screenshots, with their "Screen N" labels (not saved to disk).
        public var shots: [[String: Any]] = []
        /// The question itself, for a question (a lesson step's message is long and isn't one).
        public var asked: String?

        public init(said: String, reply: String, at: Date, shots: [[String: Any]] = [], asked: String? = nil) {
            (self.said, self.reply, self.at, self.shots, self.asked) = (said, reply, at, shots, asked)
        }
    }

    /// After this long without a question, the next one says what it's carrying on from.
    public static let longBreak: TimeInterval = 4 * 3600
    /// Questions within this long also get the previous screenshot.
    public static let quickFollowUp: TimeInterval = 120
    /// The recap's turns in full; older ones get a line each, within `recapBudget` characters.
    public static let recapTurns = 5
    public static let recapBudget = 6000
    /// Turns remembered at most.
    public static let keepTurns = 40

    /// Files given to this conversation (dropped on Navi, the paperclip, an offered document).
    public private(set) var files: [String] = []
    /// What it's about, as Claude last named it.
    public var topic: String? { didSet { if topic != oldValue { save() } } }
    /// Documents already offered (once each), so Navi doesn't ask again.
    public private(set) var offered: Set<String> = []
    /// When it began.
    public private(set) var started: Date?
    /// Where it's kept between launches (the app sets it; checks and benches leave it nil).
    public var store: URL? { didSet { load() } }

    /// Questions asked so far.
    public var questions: Int { exchanges.filter { $0.asked != nil }.count }
    /// The last question was long enough ago that this one picks the conversation up again.
    public var isAfterBreak: Bool { exchanges.last.map { Date().timeIntervalSince($0.at) >= Self.longBreak } ?? false }
    public var isEmpty: Bool { exchanges.isEmpty && files.isEmpty }

    public func addFiles(_ paths: [String]) {
        for p in paths where !files.contains(p) { files.append(p) }
        if started == nil { started = Date() }
        save()
    }

    public func removeFile(_ path: String) {
        files.removeAll { $0 == path }
        save()
    }

    public func markOffered(_ path: String) {
        offered.insert(path)
        save()
    }

    /// Ends it: the next question starts fresh, with nothing carried over.
    public func end() {
        reset()
        startFresh = true
    }

    public init() {}

    /// How long the topic pill stays up after an answer (Settings.followUpMinutes, 2 by default).
    public static var followUpWindow: TimeInterval { max(0.5, Settings.shared.followUpMinutes) * 60 }
    /// The next question starts fresh whatever its timing (× on the topic pill, "new question").
    public var startFresh = false

    public var mode = Mode(rawValue: NaviFiles.environment("CONTEXT") ?? "") ?? .compact
    public private(set) var exchanges: [Exchange] = []
    /// Screenshots in the backend's context from earlier turns.
    public private(set) var imagesHeld = 0
    private weak var lastBackend: AnyObject?
    private var turns = 0
    /// Where turns are recorded for the History window (nil in the bench).
    public var history: History? = .shared
    private var thread: String?

    /// Forget the conversation (the backends are reset by the caller).
    public func reset() {
        exchanges = []
        imagesHeld = 0
        thread = nil
        files = []
        offered = []
        started = nil
        topic = nil
        save()
    }

    public func send(_ content: [[String: Any]], kind: Kind, via backend: ChatBackend,
              onText: @escaping (String) -> Void) async throws -> String {
        if lastBackend !== backend {
            // Switched backends: whatever the other one held is stale.
            if lastBackend != nil { backend.reset() }
            reset()
            lastBackend = backend
        }
        turns += 1
        let current = Self.shots(in: content)
        let images = content.filter { $0["type"] as? String == "image" }.count
        let action = plan(kind, backend: backend)
        var content = content
        var recapChars = 0
        var previous = 0
        switch action {
        case .fresh:
            if !exchanges.isEmpty || startFresh { backend.reset() }
            startFresh = false
            reset()
        case .keep:
            break
        case .compact:
            let recap = Self.recap(exchanges, lesson: { if case .lessonStep = kind { return true }; return false }(), now: Date())
            recapChars = recap.count
            backend.reset()
            imagesHeld = 0
            content.insert(Prompt.text(recap), at: 0)
        }
        // A question asked within 120 s also gets the previous round's screenshots;
        // `keep` still holds them in the conversation.
        if case .question = kind, action == .compact || (action == .keep && backend.prunesInPlace),
           let last = exchanges.last, !last.shots.isEmpty, Date().timeIntervalSince(last.at) < Self.quickFollowUp {
            let age = Int(Date().timeIntervalSince(last.at))
            let at = content.firstIndex { ($0["text"] as? String)?.hasPrefix("Screen ") == true || $0["type"] as? String == "image" } ?? 0
            content.insert(contentsOf: Self.previousBlock(last.shots, age: age), at: at)
            previous = last.shots.filter { $0["type"] as? String == "image" }.count
        }
        // The API backend keeps only the newest screenshots itself.
        let inContext = (backend.prunesInPlace ? 0 : imagesHeld) + images + previous
        trace("[context] #\(turns) \(Self.name(kind)) → \(action.rawValue): \(images) screenshot(s) sent"
              + (previous > 0 ? " + \(previous) previous" : "") + ", \(inContext) in context, "
              + "\(exchanges.count) earlier turn(s) as \(action == .compact ? "a \(recapChars)-char recap" : "history")")

        if thread == nil, let history {
            let title: String
            if case .question(let q) = kind { title = q } else { title = content.last.flatMap { $0["text"] as? String } ?? "Lesson" }
            thread = history.begin(title: title)
        }
        let reply: String
        do {
            reply = try await backend.send(content, onText: onText)
        } catch {
            if let thread, !(error is CancellationError) {
                history?.record(thread: thread, kind: Self.name(kind), action: action.rawValue, content: content,
                                reply: nil, error: error, stats: nil)
            }
            throw error
        }
        if let thread {
            history?.record(thread: thread, kind: Self.name(kind), action: action.rawValue, content: content,
                            reply: reply, error: nil, stats: backend.lastStats)
        }

        if case .retry = kind, !exchanges.isEmpty {
            // A redraw replaces the reply it corrects.
            exchanges[exchanges.count - 1].reply = reply
        } else {
            let said = content.last.flatMap { $0["text"] as? String } ?? ""
            var asked: String?
            if case .question(let q) = kind { asked = q }
            exchanges.append(Exchange(said: said, reply: reply, at: Date(), shots: current, asked: asked))
            if exchanges.count > Self.keepTurns { exchanges.removeFirst(exchanges.count - Self.keepTurns) }
            if started == nil { started = Date() }
            // Only the latest turn's screenshots are ever sent again.
            for i in exchanges.indices.dropLast() { exchanges[i].shots = [] }
        }
        save()
        imagesHeld += images + previous
        if let stats = backend.lastStats { trace("[context] #\(turns) " + stats.summary) }
        return reply
    }

    private func plan(_ kind: Kind, backend: ChatBackend) -> Action {
        if mode == .legacy { return .keep }
        let carry: Bool
        switch kind {
        case .retry: return .keep
        case .lessonStep: carry = true
        case .question:
            if startFresh { return .fresh }
            // The conversation carries on, however long the gap; whether a question follows
            // on is left to the model (see `recap`). A new process (after a break or a
            // restart) gets the recap too.
            carry = !exchanges.isEmpty
        }
        guard carry else { return .fresh }
        return mode == .compact && (imagesHeld > 0 || !backend.holdsHistory) ? .compact : .keep
    }

    private static func name(_ kind: Kind) -> String {
        switch kind {
        case .question: return "question"
        case .lessonStep: return "lesson step"
        case .retry: return "retry"
        }
    }

    /// A turn's screenshots, each after its "Screen N" label.
    public static func shots(in content: [[String: Any]]) -> [[String: Any]] {
        content.indices.flatMap { i -> [[String: Any]] in
            guard content[i]["type"] as? String == "image" else { return [] }
            if i > 0, let label = content[i - 1]["text"] as? String, label.hasPrefix("Screen ") { return [content[i - 1], content[i]] }
            return [content[i]]
        }
    }

    /// The previous turn's screenshots, relabelled so they can't be taken for the screen now.
    public static func previousBlock(_ shots: [[String: Any]], age: Int) -> [[String: Any]] {
        [Prompt.text("Previous screenshot(s), from \(age) s ago, before your last reply. History, not the present:")]
            + shots.map { b in
                guard let t = b["text"] as? String else { return b }
                return Prompt.text("Previous " + t.prefix(1).lowercased() + t.dropFirst())
            }
            + [Prompt.text("The screen now:")]
    }

    /// Text that stands in for the dropped turns: the last few in full, older ones a line
    /// each, within `recapBudget`. Replies go as their words (the marks were for screens
    /// long gone). A lesson message already holds the goal and the steps, so a step
    /// only needs the last reply.
    public static func recap(_ exchanges: [Exchange], lesson: Bool, now: Date = Date()) -> String {
        func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
        func words(_ reply: String) -> String { TagParser.parse(reply).text }
        if lesson, let last = exchanges.last {
            return "Your last reply, about the previous screenshot (no longer attached):\n" + clip(last.reply, 600)
        }
        var head = "Earlier in this conversation. Use it only if the new question clearly refers to it (\"it\", \"that\", "
            + "\"the other one\", \"continue\", or another obvious follow-up); if the question is unrelated, ignore it. "
            + "The latest screenshot is the screen now; anything older is history, not the present."
        if let last = exchanges.last, now.timeIntervalSince(last.at) >= longBreak {
            let hours = Int(now.timeIntervalSince(last.at) / 3600)
            head += " The last question was \(hours) hours ago: if this one carries on from it, start by saying in a few words "
                + "where they'd got to."
        }
        let recent = exchanges.suffix(recapTurns)
        var full: [String] = []
        for e in recent {
            full.append("User: " + clip(e.asked ?? e.said, 300))
            full.append("You: " + clip(words(e.reply), 600))
        }
        // Older turns, a line each, newest kept first if the budget runs out.
        var older: [String] = []
        var room = recapBudget - head.count - full.joined(separator: "\n").count
        for e in exchanges.dropLast(recent.count).reversed() {
            guard let asked = e.asked else { continue }   // lesson steps are in their lesson's own log
            let first = words(e.reply).split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            let line = "- " + clip(asked, 80) + " → " + clip(first, 120)
            guard room - line.count > 0 else { break }
            room -= line.count + 1
            older.insert(line, at: 0)
        }
        var lines = [head]
        if !older.isEmpty { lines.append("Earlier, in brief:"); lines += older; lines.append("Most recently:") }
        return (lines + full).joined(separator: "\n")
    }

    // MARK: Kept between launches

    private struct Saved: Codable {
        struct Turn: Codable { var asked: String?; var said: String; var reply: String; var at: Date }
        var turns: [Turn]
        var files: [String]
        var offered: [String]
        var topic: String?
        var started: Date?
    }

    private var loading = false

    /// Text only, redacted, readable by the user alone. Never screenshots.
    private func save() {
        guard let store, !loading else { return }
        if exchanges.isEmpty && files.isEmpty {
            try? FileManager.default.removeItem(at: store)
            return
        }
        let s = Saved(turns: exchanges.map { Saved.Turn(asked: $0.asked.map { Redact.secrets(in: $0) }, said: Redact.secrets(in: String($0.said.prefix(2000))),
                                                        reply: Redact.secrets(in: String($0.reply.prefix(4000))), at: $0.at) },
                      files: files, offered: Array(offered), topic: topic, started: started)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(s) else { return }
        try? data.write(to: store, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
    }

    private func load() {
        guard let store, let data = try? Data(contentsOf: store) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let s = try? d.decode(Saved.self, from: data) else { return }
        loading = true
        defer { loading = false }
        exchanges = s.turns.map { Exchange(said: $0.said, reply: $0.reply, at: $0.at, asked: $0.asked) }
        files = s.files
        offered = Set(s.offered)
        topic = s.topic
        started = s.started
    }
}
