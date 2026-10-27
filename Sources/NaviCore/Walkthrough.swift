import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// A step-by-step lesson in progress: the goal, the steps taken so far and
/// the step that is armed now. The log and the goal last across pauses, up
/// to 15 steps a sitting. A lesson put down partway is kept as a `Bookmark`
/// and can be picked up again (`init(resuming:)`).
public final class Walkthrough {
    public static let maxSteps = 15
    /// A paused lesson (waiting for "continue") is put away after this long (and kept, if it's worth it).
    public static let idleLimit: TimeInterval = 5 * 60

    public let goal: String
    public private(set) var log: [String] = []
    public private(set) var lastActivity = Date()
    public var armed: Step?
    /// The rough plan, if Claude gave one ([OUTLINE:…]).
    public var outline: [String] = []
    /// Steps this sitting may take: 15 more than were done before it.
    public private(set) var limit = Walkthrough.maxSteps
    /// The bookmark it was picked up from, or was kept as.
    public var bookmarkID: String?
    /// Its name (the topic), for the bookmark.
    public var title: String?
    /// Steps they needed help with ("Show me again", "I'm stuck").
    public private(set) var stuckOn: [String] = []
    /// Files that belong to it (opened along the way, or attached to its bookmark).
    public var files: [String] = []
    /// The app it's in, for the bookmark.
    public var app: Shell.AppInfo?

    public init(goal: String) { self.goal = goal }

    /// Picks a kept lesson up again: its goal, plan, steps done and files.
    public init(resuming b: Bookmark) {
        goal = b.goal
        log = b.done
        outline = b.outline
        bookmarkID = b.id
        title = b.title
        stuckOn = b.stuckOn
        files = b.files
        app = Shell.AppInfo(bundleID: b.bundleID, name: b.app, pid: 0)
        limit = b.done.count + Self.maxSteps
    }

    public var stepsTaken: Int { log.count }
    public var stepsLeft: Int { max(0, limit - log.count) }

    /// Whether putting it down should keep it: a few steps in, or with a plan to follow.
    public var worthKeeping: Bool {
        log.count >= Bookmarks.minSteps || (!outline.isEmpty && log.count >= 1) || bookmarkID != nil || !files.isEmpty
    }

    public func stuck(on step: String) {
        if stuckOn.last != step { stuckOn.append(step) }
        lastActivity = Date()
    }

    /// The bookmark for it as it stands; `next` is the step it stopped at.
    public func bookmark(next: String?, existing: Bookmark?) -> Bookmark {
        var b = existing ?? Bookmark(title: title ?? String(goal.prefix(40)), goal: goal)
        if let bookmarkID { b.id = bookmarkID }
        if let title { b.title = title }
        b.outline = outline
        b.done = log
        b.next = next
        b.stuckOn = stuckOn
        b.app = app?.name ?? b.app
        b.bundleID = app?.bundleID ?? b.bundleID
        b.files = files
        b.lastUsed = Date()
        return b
    }
    public var isStale: Bool { Date().timeIntervalSince(lastActivity) > Self.idleLimit }

    public func record(_ line: String) {
        log.append(line)
        lastActivity = Date()
    }

    public func touch() { lastActivity = Date() }

    /// What to tell the model after something happened (a click on the
    /// target, a hover, or the user speaking). `learn`: they took the step
    /// themselves, so the reply may keep what it showed as a skill.
    public func message(event: String, learn: Bool = false) -> String {
        var lines = ["We are partway through teaching a task.", "Goal: \(goal)"]
        if !outline.isEmpty {
            lines.append("The plan: " + outline.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
                + " (change it with a new [OUTLINE:…] if the screen shows a better way).")
        }
        if !stuckOn.isEmpty { lines.append("They needed help with: " + stuckOn.suffix(3).joined(separator: "; ") + ". Go gently there.") }
        if !files.isEmpty { lines.append("Files for this lesson (read them if a step needs them): " + files.joined(separator: ", ")) }
        if log.isEmpty {
            lines.append("No steps done yet.")
        } else {
            lines.append("Done so far:")
            lines += log.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }
        lines.append("Just now: \(event)")
        lines.append("This is the screen now. Trust it over the history: count the last step as done unless the screen clearly shows it didn't work.")
        lines.append("If that step only opened something (a menu, a list, a panel) or toggled it, the next target is inside what opened, not the same opener again.")
        lines.append("Build on what earlier steps found. Don't send them back to a place they've already been unless the screen shows it's needed, and don't start a general tour.")
        lines.append("If you can't see what changed, give one short spoken nudge with no TARGET.")
        if learn { lines.append(Self.skillInvite) }
        lines.append(stepsLeft > 0
            ? "Then give only the next distinct step (\(stepsLeft) left at most), or say it's done if the goal is reached."
            : "That's the step limit: wrap up in one short sentence with no TARGET or HOVER.")
        return lines.joined(separator: "\n")
    }

    /// Asks for what the step showed about the app, as a [SKILL:…] tag (`Skills.learn`).
    public static let skillInvite = "If the screen shows that step worked and it taught something lasting about where things are in this app, "
        + "add one [SKILL:task | how] anywhere in the reply: the task in a few words, then where it's done by the app's own labels, "
        + "e.g. [SKILL:Export a PDF | File > Export as PDF…]. Only the app's layout: nothing from their document, nothing personal, "
        + "no quoted text. Leave it out when the step taught nothing new."

    // MARK: The armed step

    /// One TARGET or HOVER waiting for the user, in the shell's global
    /// coordinates (AppKit's on the Mac). `display` names the screen it's on
    /// (a CGDirectDisplayID on the Mac); the shell maps it back to a screen.
    public struct Step {
        public let center: CGPoint
        public let radius: CGFloat
        public let label: String
        public let hover: Bool
        public let display: UInt32
        public let sentence: String
        public let armedAt: Date
        /// A practice question ([QUIZ]): nothing drawn, the click is graded.
        public var quiz = false

        public init(center: CGPoint, radius: CGFloat, label: String, hover: Bool, display: UInt32, sentence: String, armedAt: Date) {
            (self.center, self.radius, self.label, self.hover, self.display, self.sentence, self.armedAt) =
                (center, radius, label, hover, display, sentence, armedAt)
        }

        /// The click radius: image radius × screen scale, clamped to 28…180 points.
        public static func radius(image r: CGFloat, scale: CGFloat) -> CGFloat {
            max(28, min(r * scale, 180))
        }

        public enum Click: Equatable { case hit, miss, ignore, expired }

        /// What a click at `p` means. Clicks during the grace period after a
        /// step starts are ignored; targets expire after 90 s.
        /// The smallest area that counts as a hit, whatever the step's radius.
        public static let minReach: CGFloat = 44

        public func judge(click p: CGPoint, now: Date = Date(), graceUntil: Date?) -> Click {
            if now.timeIntervalSince(armedAt) > Walkthrough.idleLimit { return .expired }
            if let g = graceUntil, now < g { return .ignore }
            // Small icons get a forgiving reach: Claude's aim can be a few dozen points off.
            return hypot(p.x - center.x, p.y - center.y) <= max(radius, Self.minReach) ? .hit : .miss
        }
    }

    /// Accumulates how long the pointer has rested on a HOVER step, sampled
    /// every 0.12 s; fires at 2 s.
    public struct HoverRest {
        public static let interval: TimeInterval = 0.12
        public static let needed: TimeInterval = 2.0
        public private(set) var rested: TimeInterval = 0

        public init() {}

        public mutating func sample(_ p: CGPoint, on step: Step) -> Bool {
            if hypot(p.x - step.center.x, p.y - step.center.y) <= step.radius { rested += Self.interval } else { rested = 0 }
            return rested >= Self.needed
        }
    }
}
