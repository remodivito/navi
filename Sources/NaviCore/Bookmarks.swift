import Foundation

/// A lesson put down partway, to pick up later: where it was going, where it got to,
/// and where they got stuck. Text only, never screenshots. Kept in bookmarks.json in
/// Navi's folder, redacted like History, until the lesson is finished, they say not
/// to keep it, or it goes unused for `Bookmarks.expiry`.
public struct Bookmark: Codable, Equatable {
    public var id: String
    /// What the pill and the menu call it ("QGIS practical 3").
    public var title: String
    public var goal: String
    /// The rough plan Claude gave ([OUTLINE:…]); empty if it gave none.
    public var outline: [String]
    /// The steps taken, as the lesson logged them.
    public var done: [String]
    /// The step they stopped at, in its own words ("Open the Vector menu").
    public var next: String?
    /// Where they needed help: "Show me again" or "I'm stuck" on a step.
    public var stuckOn: [String]
    /// The app the lesson was in.
    public var app: String?
    public var bundleID: String?
    /// Files that belong to it: attached, or opened along the way.
    public var files: [String]
    public var created: Date
    public var lastUsed: Date
    /// How many times it's been picked up again.
    public var sessions: Int

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), title: String, goal: String,
                outline: [String] = [], done: [String] = [], next: String? = nil, stuckOn: [String] = [],
                app: String? = nil, bundleID: String? = nil, files: [String] = [], created: Date = Date(),
                lastUsed: Date = Date(), sessions: Int = 1) {
        (self.id, self.title, self.goal, self.outline, self.done, self.next, self.stuckOn) = (id, title, goal, outline, done, next, stuckOn)
        (self.app, self.bundleID, self.files, self.created, self.lastUsed, self.sessions) = (app, bundleID, files, created, lastUsed, sessions)
    }

    /// "step 5 of 12", or "step 5" without an outline.
    public var progress: String {
        let n = done.count + 1
        return outline.count >= n ? "step \(n) of \(outline.count)" : "step \(n)"
    }

    /// What Claude is told about it on a question turn, so it can tell whether the
    /// question carries it on: a few lines, enough to give the next step straight away.
    public var promptLines: String {
        var lines = ["- [\(id)] \(title)" + (app.map { " (in \($0))" } ?? "") + ", \(progress)"]
        lines.append("  Goal: \(goal)")
        if !outline.isEmpty { lines.append("  Plan: " + outline.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")) }
        if !done.isEmpty { lines.append("  Done: " + done.suffix(4).joined(separator: "; ")) }
        if let next { lines.append("  Stopped at: \(next)") }
        if !stuckOn.isEmpty { lines.append("  Needed help with: " + stuckOn.suffix(3).joined(separator: "; ")) }
        if !files.isEmpty { lines.append("  Files: " + files.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

/// The bookmarks, newest first. Every read and write goes through `lock`: a turn can
/// finish on any thread, and the menu and History read on main.
public final class Bookmarks {
    /// The user's own; the self-tests swap in a store of their own first (`useScratch`).
    public static var shared = Bookmarks(file: NaviFiles.support.appendingPathComponent("bookmarks.json"))

    /// For the self-tests: a throwaway store, so no check ever touches the user's lessons.
    public static func useScratch() {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("navi-bookmarks-\(UUID().uuidString).json")
        shared = Bookmarks(file: f)
    }
    /// Unused this long, a bookmark goes.
    public static let expiry: TimeInterval = 30 * 24 * 3600
    /// At most this many; the oldest goes first.
    public static let limit = 8
    /// Lessons shorter than this aren't worth keeping (unless Claude gave an outline).
    public static let minSteps = 2

    private let file: URL
    private let lock = NSLock()
    private var items: [Bookmark] = []
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            items = (try? d.decode([Bookmark].self, from: data)) ?? []
        }
        locked { expire() }
    }

    /// Changes elsewhere (the menu, History) listen for this.
    public static let changed = Notification.Name("NaviBookmarksChanged")

    public var all: [Bookmark] { locked { expire(); return items } }

    public func get(_ id: String) -> Bookmark? { all.first { $0.id == id } }

    /// Adds or replaces it, newest first. Its words are redacted before they reach the disk.
    public func keep(_ b: Bookmark) {
        var b = b
        b.title = Redact.secrets(in: b.title)
        b.goal = Redact.secrets(in: b.goal)
        b.done = b.done.map { Redact.secrets(in: $0) }
        b.next = b.next.map { Redact.secrets(in: $0) }
        b.stuckOn = b.stuckOn.map { Redact.secrets(in: $0) }
        locked {
            items.removeAll { $0.id == b.id }
            items.insert(b, at: 0)
            if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
            save()
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    public func remove(_ id: String) {
        locked {
            items.removeAll { $0.id == id }
            save()
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    public func removeAll() {
        locked { items = []; save() }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// What a question turn carries: the bookmarks, and how to pick one up. Nil when there are none.
    public func promptNote() -> String? {
        let list = all
        guard !list.isEmpty else { return nil }
        return "Lessons they put down partway and may want to carry on (most recent first):\n"
            + list.map(\.promptLines).joined(separator: "\n")
            + "\nOnly if this question clearly carries one of them on, begin your reply with [RESUME:id] "
            + "(its id in brackets above), then give the next step from what's on screen now, as in any lesson."
    }

    // Callers hold `lock`.
    private func expire() {
        let before = items.count
        items.removeAll { Date().timeIntervalSince($0.lastUsed) > Self.expiry }
        if items.count != before { save() }
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(items) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
