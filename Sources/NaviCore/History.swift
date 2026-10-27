import Foundation

/// What was actually sent to Claude and what came back, one thread per
/// context (see `Conversation`), kept for a week so a slow or odd answer can
/// be looked at afterwards. `thread-history.json` is the index, `transcript-<id>.json` holds one
/// thread's turns, rewritten after every turn.
///
/// Screenshots are only written by dev builds (`SP_DEV_SCREENSHOTS`, defined
/// by Package.swift when a `.dev-build` file sits next to it). Other builds,
/// including anything open-sourced, keep text only: the code that writes
/// images isn't compiled in.
public final class History {
    public static let shared = History()
    public static let keepFor: TimeInterval = 7 * 24 * 3600

    public static var keepsScreenshots: Bool {
        #if SP_DEV_SCREENSHOTS
        return true
        #else
        return false
        #endif
    }

    public struct Thread: Codable, Identifiable, Equatable {
        public let id: String
        public var title: String
        public var preview: String
        public let started: Date
        public var updated: Date
        public var turns: Int
        public var tokens: Int
    }

    public struct Shot: Codable, Equatable {
        /// File name inside the thread's folder; nil when screenshots aren't kept.
        public var file: String?
        /// The label sent with it ("Screen 1 (cursor is here): 1568×1015 px", "Previous screen 1 …").
        public let label: String
        /// The screen its tags refer to; 0 for a previous turn's screenshot.
        public let screen: Int
        public let width: Int
        public let height: Int
    }

    public struct Turn: Codable, Identifiable, Equatable {
        public let id: Int
        public let at: Date
        public let kind: String
        public let action: String
        /// Every text block sent, in order; screenshots appear as "[screenshot]".
        public let sent: [String]
        public let shots: [Shot]
        public var reply: String
        public var error: String?
        public var tokensIn: Int?
        public var tokensOut: Int?
        public var firstText: Double?
        public var firstTag: Double?
        public var total: Double?
    }

    public struct Transcript: Codable {
        /// The file format. Files written before the field count as 1.
        public static let currentVersion = 1
        public var version: Int
        public let id: String
        public var turns: [Turn]

        public init(id: String, turns: [Turn]) {
            (self.version, self.id, self.turns) = (Self.currentVersion, id, turns)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            id = try c.decode(String.self, forKey: .id)
            turns = try c.decode([Turn].self, forKey: .turns)
        }
    }

    /// thread-history.json: `{"version":1,"threads":[…]}`.
    /// Earlier builds wrote a bare array of threads; that still reads.
    public struct Index: Codable {
        public static let currentVersion = 1
        public var version: Int
        public var threads: [Thread]
        public init(threads: [Thread]) { (self.version, self.threads) = (Self.currentVersion, threads) }
    }

    /// The threads in an index file, in either form; nil if it isn't one.
    public static func readIndex(_ data: Data) -> [Thread]? {
        if let index = try? decoder.decode(Index.self, from: data) { return index.threads }
        return try? decoder.decode([Thread].self, from: data)
    }

    public let folder: URL
    private let queue = DispatchQueue(label: "Navi.history")
    /// Written from whatever thread a turn finishes on (Conversation.send isn't
    /// main-actor bound) and read by the History window on main, so every touch
    /// goes through `lock`.
    private var index: [Thread] = []
    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    public init(folder: URL? = nil) {
        self.folder = folder ?? NaviFiles.support.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        index = (try? Data(contentsOf: indexURL)).flatMap(Self.readIndex) ?? []
        prune()
        sweepOrphans()
        // Outside development, no screenshot is kept: any left from a dev build go at once.
        if !Self.keepsScreenshots { Self.purgeScreenshots(in: self.folder) }
    }

    /// Deletes transcripts and shot folders the index doesn't list. Expiry only
    /// removes what the index knows, so a thread the index lost (the index file was
    /// corrupted, or its write failed after the transcript's) would otherwise stay
    /// for good. Run at launch, before any write.
    private func sweepOrphans() {
        let known = Set(index.map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files {
            let name = url.lastPathComponent
            let id: String
            if name.hasPrefix("transcript-"), name.hasSuffix(".json") {
                id = String(name.dropFirst("transcript-".count).dropLast(".json".count))
            } else if name.hasPrefix("shots-") {
                id = String(name.dropFirst("shots-".count))
            } else {
                continue
            }
            if !known.contains(id) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Deletes every image under `folder` (screenshots saved by a dev build); returns how many.
    @discardableResult
    public static func purgeScreenshots(in folder: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        for case let url as URL in files where ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased()) {
            if (try? FileManager.default.removeItem(at: url)) != nil { n += 1 }
        }
        return n
    }

    private var indexURL: URL { folder.appendingPathComponent("thread-history.json") }
    private func transcriptURL(_ id: String) -> URL { folder.appendingPathComponent("transcript-\(id).json") }
    public func shotsFolder(_ id: String) -> URL { folder.appendingPathComponent("shots-\(id)", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Writing (main thread; files are written on a background queue)

    /// Starts a thread and returns its id. Old threads expire first: Navi runs for
    /// weeks at a time, so expiry can't wait for the next launch.
    public func begin(title: String, now: Date = Date()) -> String {
        prune(now: now)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let id = f.string(from: now) + "-" + UUID().uuidString.prefix(4).lowercased()
        locked {
            index.insert(Thread(id: id, title: String(title.prefix(120)), preview: "", started: now, updated: now,
                                turns: 0, tokens: 0), at: 0)
        }
        return id
    }

    /// Records one turn: the content as sent, and the reply or the error. Secrets in any
    /// of it (a token in selected text, a key in a document's excerpt) are redacted
    /// before it reaches the disk (decision 3).
    public func record(thread id: String, kind: String, action: String, content: [[String: Any]],
                reply rawReply: String?, error: Error?, stats: TurnStats?) {
        let reply = rawReply.map { Redact.secrets(in: $0) }
        guard let turnNo = locked({ index.first { $0.id == id }.map { $0.turns + 1 } }) else { return }
        var sent: [String] = []
        var shots: [Shot] = []
        var jpegs: [(String, String)] = []   // file name, base64
        var lastLabel = ""
        for block in content {
            if let t = block["text"] as? String {
                sent.append(Redact.secrets(in: t))
                lastLabel = t
            } else if block["type"] as? String == "image" {
                sent.append("[screenshot]")
                let (screen, w, h) = Self.parse(label: lastLabel)
                var shot = Shot(file: nil, label: lastLabel, screen: screen, width: w, height: h)
                #if SP_DEV_SCREENSHOTS
                if let data = (block["source"] as? [String: Any])?["data"] as? String {
                    let name = "\(turnNo)-\(shots.count + 1).jpg"
                    shot.file = name
                    jpegs.append((name, data))
                }
                #endif
                shots.append(shot)
            }
        }
        var turn = Turn(id: turnNo, at: Date(), kind: kind, action: action, sent: sent, shots: shots,
                        reply: reply ?? "", error: error.map { Redact.secrets(in: $0.localizedDescription) })
        if let stats {
            turn.tokensIn = stats.contextTokens
            turn.tokensOut = stats.output
            turn.firstText = stats.firstText
            turn.firstTag = stats.firstTag
            turn.total = stats.total
        }
        let preview = reply.map { String(TagParser.parse($0).text.prefix(160)) }
        let snapshot: [Thread]? = locked {
            // The thread may have been cleared while the turn was in flight.
            guard let i = index.firstIndex(where: { $0.id == id }) else { return nil }
            index[i].turns = turnNo
            index[i].updated = Date()
            index[i].tokens += stats?.contextTokens ?? 0
            if let preview { index[i].preview = preview }
            return index
        }
        guard let snapshot else { return }
        let folder = shotsFolder(id), transcript = transcriptURL(id), indexURL = indexURL
        queue.async {
            if !jpegs.isEmpty {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, b64) in jpegs {
                    try? Data(base64Encoded: b64)?.write(to: folder.appendingPathComponent(name))
                }
            }
            var t = (try? Self.decoder.decode(Transcript.self, from: Data(contentsOf: transcript))) ?? Transcript(id: id, turns: [])
            t.turns.append(turn)
            try? Self.encoder.encode(t).write(to: transcript, options: .atomic)
            try? Self.encoder.encode(Index(threads: snapshot)).write(to: indexURL, options: .atomic)
        }
    }

    /// "Screen 2 of 2 (the cursor is here): 1568×1015 px" → (2, 1568, 1015); a
    /// "Previous screen …" label gets screen 0 so no marks land on it.
    public static func parse(label: String) -> (Int, Int, Int) {
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let screen = label.hasPrefix("Screen ") ? (numbers.first ?? 1) : 0
        let dims = numbers.count >= 2 ? Array(numbers.suffix(2)) : [0, 0]
        return (screen, dims[0], dims[1])
    }

    // MARK: Reading

    public func threads() -> [Thread] {
        prune()
        queue.sync {}   // let pending writes land first
        return locked { index }
    }

    public func transcript(_ id: String) -> Transcript? {
        queue.sync { try? Self.decoder.decode(Transcript.self, from: Data(contentsOf: transcriptURL(id))) }
    }

    // MARK: Clearing

    /// Drops threads not touched for a week.
    public func prune(now: Date = Date()) {
        let old: [Thread] = locked {
            let old = index.filter { now.timeIntervalSince($0.updated) > Self.keepFor }
            index.removeAll { old.contains($0) }
            return old
        }
        guard !old.isEmpty else { return }
        delete(old.map(\.id))
    }

    public func clear() {
        let all: [String] = locked {
            let all = index.map(\.id)
            index = []
            return all
        }
        delete(all)
    }

    private func delete(_ ids: [String]) {
        let snapshot = locked { index }, indexURL = indexURL
        let urls = ids.flatMap { [transcriptURL($0), shotsFolder($0)] }
        queue.async {
            for u in urls { try? FileManager.default.removeItem(at: u) }
            try? Self.encoder.encode(Index(threads: snapshot)).write(to: indexURL, options: .atomic)
        }
    }
}
