import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// The teaching decisions, apart from any platform: what the user's words
/// mean, how long things hold, what a lesson does when something changes, and
/// the notes that go to Claude. AppController (the Mac shell) asks these; a
/// Windows shell asks the same ones.
public enum Tutor {
    // MARK: What their words mean

    /// "New question", "start over": the words that drop the topic.
    public static func wantsFresh(_ q: String) -> Bool {
        let s = q.lowercased()
        return ["new question", "start over", "start fresh", "something else", "different question", "forget that",
                "new topic", "change of topic"].contains { s.contains($0) }
    }

    /// "No, the other one" and the like: the last answer missed.
    public static func isCorrection(_ q: String) -> Bool {
        let s = q.lowercased()
        return ["no,", "no ", "not that", "wrong", "other one", "that's not", "thats not", "nope", "try again"]
            .contains { s.hasPrefix($0) || s.contains(" " + $0) }
    }

    /// "Let me try": they want to do it themselves, with Navi checking. There's no
    /// switch for it in the interface, just these words.
    public static func wantsToTry(_ q: String) -> Bool {
        let s = q.lowercased()
        return ["let me try", "let me do it", "let me have a go", "i'll try", "i will try", "i want to try",
                "can i try", "i'll have a go", "let me give it a go", "let me give it a try"].contains { s.contains($0) }
    }

    /// "Save that as a note", "remind me tomorrow": the user's own words asking Navi to
    /// keep something. A NOTE or REMIND is only kept when they did (decision 2, 2026-10-26).
    public static func asksToKeep(_ q: String, _ kind: Keep.Kind) -> Bool {
        let s = " " + q.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        func word(_ w: String) -> Bool { s.range(of: "[^a-z]" + w + "[^a-z]", options: .regularExpression) != nil }
        switch kind {
        case .copy: return true
        case .remind: return word("remind") || word("reminder") || word("reminders")
        case .note:
            return word("note") || word("notes") || word("jot")
                || ["write it down", "write that down", "write this down", "save it", "save that", "save this",
                    "keep it", "keep that", "keep this", "make a note", "for later"].contains { s.contains($0) }
        }
    }

    /// Whether the user asked to keep anything at all (a note or a reminder).
    public static func asksToKeep(_ q: String) -> Bool { asksToKeep(q, .note) || asksToKeep(q, .remind) }

    /// Whether a keep in a reply may run. `asked` is the user's own words for this turn,
    /// or nil for Navi's own follow-up turns (an errand's look, a look again, a step's
    /// next turn), which are steered by what's on screen, not by the user: nothing is
    /// kept there, not even a COPY. A NOTE or REMIND needs the user to have asked for one.
    public static func mayKeep(_ k: Keep, asked: String?) -> Bool {
        guard let asked else { return false }
        return asksToKeep(asked, k.kind)
    }

    /// Words that carry on a paused lesson rather than start a new question.
    public static func isContinuation(_ q: String) -> Bool {
        let s = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let starts = ["continue", "next", "done", "ok", "okay", "go on", "keep going", "carry on", "what now",
                      "what next", "and then", "then what", "i did it", "finished", "ready"]
        return starts.contains { s == $0 || s.hasPrefix($0 + " ") } || s.contains("next step")
    }

    /// "Explain this"-type questions, which should get a drawn explanation.
    public static func wantsExplanation(_ q: String) -> Bool {
        let s = q.lowercased()
        let cues = ["explain", "what is this", "what's this", "what am i looking at", "what are these", "what are those",
                    "how does this work", "how does it work", "how do these", "what does this", "what do these",
                    "walk me through", "tell me about", "overview", "break down", "break it down", "what's going on",
                    "what is going on", "how is this", "what's on my screen", "what is on my screen"]
        return cues.contains { s.contains($0) }
    }

    /// Whether "let me try" is on after this question: they said it, or it carries on
    /// while they keep going; any other question turns it off.
    public static func tryFirst(after q: String, was: Bool) -> Bool {
        if wantsToTry(q) { return true }
        return isContinuation(q) ? was : false
    }

    /// Whether a lesson in progress carries on with this question, rather than ending
    /// for a new one. `fromCard`: typed from the pause card.
    public static func carriesOnLesson(_ q: String, stale: Bool, fromCard: Bool) -> Bool {
        !stale && (isContinuation(q) || wantsToTry(q) || fromCard)
    }

    /// How carefully the pen moves after this question: more care after a correction,
    /// growing back towards 1 with each question that isn't one.
    public static func confidence(after q: String, was c: Double) -> Double {
        isCorrection(q) ? 0.75 : min(1, c + 0.1)
    }

    // MARK: Reading and pacing

    /// How long a sentence holds before the next one: reading at a calm pace,
    /// about two and a half words a second (while also looking at the drawing),
    /// plus a moment to take in the mark, up to 12 s.
    public static func readingTime(words: Int) -> TimeInterval {
        min(10, Double(words) / 4 + 0.8)   // about 240 words a minute, plus a moment to look
    }

    /// How long an answer stays up once it's done. With no voice, long enough to
    /// read; spoken, a little after the voice ends.
    public static func answerHold(words: Int, speaking: Bool) -> TimeInterval {
        let read = max(10, Double(words) * 0.45 + 5)
        return speaking ? max(4, read - Double(words) * 0.3) : read
    }

    /// How long drawings stay after the voice ends: a diagram of several parts a little longer.
    public static func drawingsLinger(drawings: Int) -> TimeInterval { drawings >= 3 ? 4 : 1.5 }

    /// How fast a typed answer reveals: as fast as the reply arrived (about 5.5
    /// characters a word), or 6 words a second until there's enough to tell.
    public static func revealRate(chars: Int, since start: Date?, now: Date = Date()) -> Double {
        guard let start, chars > 40 else { return 6 }
        return Double(chars) / 5.5 / max(0.2, now.timeIntervalSince(start))
    }

    // MARK: Explanations

    /// Roughly where an annotation sits, in screenshot pixels.
    public static func spot(of a: Annotation) -> CGPoint {
        switch a {
        case .point(let p, _, _), .target(let p, _, _, _), .hover(let p, _, _, _), .write(let p, _, _), .quiz(let p, _, _, _): return p
        case .highlight(let r, _, _): return CGPoint(x: r.midX, y: r.midY)
        case .shape(_, let pts, _, _): return pts.first ?? .zero
        case .demo(let pts, _, _): return pts.first ?? .zero
        case .open, .download: return .zero
        }
    }

    /// Whether a reply is a real drawn explanation: at least three drawings, and
    /// something constructed rather than only marks on what's there. Returns what's
    /// missing otherwise.
    public static func explanationGap(_ reply: String) -> String? {
        let marks = TagParser.parse(reply).annotations.filter { !$0.isAction }
        var missing: [String] = []
        if marks.count < 3 { missing.append("it had \(marks.count) drawing\(marks.count == 1 ? "" : "s"), it needs 3 to 7 beats") }
        // Drawing the idea needs something constructed, not only marks on what's already there.
        let constructed = marks.contains {
            switch $0 {
            case .write: return true
            case .shape(let k, _, _, _): return k != .circle
            default: return false
            }
        }
        if !constructed { missing.append("nothing was drawn to teach the idea, only things on screen were marked: add constructions, arrows or written working") }
        return missing.isEmpty ? nil : missing.joined(separator: "; ")
    }

    /// What to send when an explanation came back too thin (see `explanationGap`).
    public static func redrawNote(_ gap: String) -> String {
        "That reply didn't work as an explanation: \(gap). Redo it for the same screen as a drawn explanation in "
            + "3 to 7 beats that builds the idea: constructions, arrows for what leads to what, and the key working written with WRITE."
    }

    // MARK: Geometry on the screenshot

    /// Every coordinate is clamped into the screenshot before mapping.
    public static func clamp(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
    }

    /// A ring wider than a third of the screen almost always means the model wrote a
    /// width and height where the edge point goes: draw that box instead.
    public static func ringLooksLikeSize(_ pts: [CGPoint], in size: CGSize) -> Bool {
        guard pts.count == 2 else { return false }
        let r = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
        return r > min(size.width, size.height) / 3 && pts[1].x > 0 && pts[1].y > 0
    }

    /// A highlight about one line of text tall (points) gets a highlighter swept along
    /// it, and the light runs along the line; anything bigger is an area.
    public static func highlightIsLine(_ r: CGRect) -> Bool {
        r.height <= 44 && r.width >= r.height * 3
    }

    /// Where a target's ring is drawn when snapping is off: round the control under the
    /// point, if there is one about the target's size, so the ring hugs it. Clicks are
    /// judged as before (the eval found moving the target loses more than it saves).
    public static func outline(_ rect: CGRect?, around p: CGPoint, radius: CGFloat) -> CGRect? {
        guard let rect, rect.insetBy(dx: -4, dy: -4).contains(p), rect.width >= 12, rect.height >= 12,
              hypot(rect.width, rect.height) / 2 <= radius * 2.5 else { return nil }
        return rect
    }

    /// The screenshot a tag's screen number means; 0 is the one with the cursor.
    public static func shot<S>(_ n: Int, in shots: [S], index: (S) -> Int, hasCursor: (S) -> Bool) -> S {
        shots.first { n == TagParser.cursorScreen ? hasCursor($0) : index($0) == n } ?? shots.first(where: hasCursor) ?? shots[0]
    }

    // MARK: Notes that go with a turn

    /// While they're trying it themselves, every turn says so.
    public static let tryFirstNote = "TRY FIRST: the user asked to try it themselves. In a task, say only the goal of the next step in "
        + "words and mark it with QUIZ instead of TARGET or HOVER: nothing drawn on it, nothing said about where it is. If they miss, "
        + "the app tells you: first a hint in words, then a light HIGHLIGHT on the area where it lives, and only after that show "
        + "it with a TARGET. For an idea, give them a problem to work out instead of explaining further."

    /// The notes that go with every turn after the app's own context: the teaching
    /// notes, recent practice moves, "try first", and the topic (questions only).
    public static func extras(notes: String?, recentMoves: PracticeMoves, tryFirst: Bool, topic: String? = nil) -> [String] {
        var out: [String] = []
        if let notes { out.append(notes) }
        if let recent = recentMoves.note { out.append(recent) }
        if tryFirst { out.append(tryFirstNote) }
        if let topic { out.append("Current topic: \(topic). The earlier turns are about it.") }
        return out
    }

    /// The accessibility names found inside a region the user marked with the gesture.
    public static func elementsNote(_ found: [String]) -> String? {
        found.isEmpty ? nil : "Accessibility data inside the highlighted region (use these exact strings when relevant, "
            + "don't re-read them from the image): " + found.joined(separator: "; ") + "."
    }

    /// How marks from Mark mode are described: one line per mark (`Mark.describe`).
    public static func marksNote(_ lines: [String]) -> String {
        "The user marked things on screen in magenta, numbered in the order they drew them. "
            + "Treat them as exactly what they mean; they're the user's marks, not part of the interface. "
            + "Refer to them by number (\"your 1\").\n" + lines.joined(separator: "\n")
    }

    /// The last few practice moves, so Navi varies them rather than repeating one.
    public struct PracticeMoves: Equatable {
        public private(set) var recent: [String] = []
        public init() {}

        /// Notes the move a reply used ([TRY:…]), keeping the last four, newest last.
        public mutating func note(_ reply: String) {
            guard let move = TagParser.practiceMove(reply) else { return }
            recent = Array((recent.filter { $0 != move } + [move]).suffix(4))
        }

        public var note: String? {
            recent.isEmpty ? nil : "Practice moves used recently (if you add practice, choose a different one): " + recent.joined(separator: ", ") + "."
        }
    }

    // MARK: Topics

    /// The topic after an answer: a question takes the reply's [TOPIC] (or none); a
    /// lesson step keeps the current one unless the reply names a new one.
    public static func topic(after reply: String, question: Bool, current: String?) -> String? {
        question ? TagParser.topic(reply) : (TagParser.topic(reply) ?? current)
    }

    /// The pill's words: the topic, and the step for a lesson.
    public static func pillText(topic: String?, stepsTaken: Int?, of total: Int? = nil, files: Int = 0) -> String? {
        let attached = files == 1 ? "1 file" : files > 1 ? "\(files) files" : nil
        guard let topic else { return attached.map { "This conversation · \($0)" } }
        var text = topic
        if let n = stepsTaken, n > 0 {
            text += total.map { $0 > n ? " · step \(n + 1) of \($0)" : " · step \(n + 1)" } ?? " · step \(n + 1)"
        }
        return text + (attached.map { " · " + $0 } ?? "")
    }

    /// The document open in the app in front, from the context Navi reads ("Open document: …"),
    /// when it's the kind of thing worth keeping for a conversation: slides, PDFs, documents, notes.
    /// The link offering to add what an answer needed: "Add your lecture slides…".
    public static func materialLink(_ what: String) -> String {
        var w = what.trimmingCharacters(in: .whitespaces)
        // "Lecture slides" reads as a sentence; "GIS notes" keeps its capitals.
        let first = w.prefix { $0 != " " }
        if first.count > 1, first.dropFirst().allSatisfy({ !$0.isUppercase }) { w = w.prefix(1).lowercased() + w.dropFirst() }
        if !w.lowercased().hasPrefix("your ") && !w.lowercased().hasPrefix("the ") { w = "your " + w }
        return "Add \(w) to this conversation…"
    }

    public static func openDocument(in context: String?) -> String? {
        guard let line = context?.split(separator: "\n").first(where: { $0.hasPrefix("Open document: ") }) else { return nil }
        let path = String(line.dropFirst("Open document: ".count)).trimmingCharacters(in: .whitespaces)
        let kinds: Set<String> = ["pdf", "key", "pptx", "ppt", "docx", "doc", "pages", "md", "txt", "rtf", "odt", "odp", "epub", "csv", "xlsx", "numbers", "ipynb"]
        guard path.hasPrefix("/"), kinds.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return path
    }

    /// Files they gave Navi for this conversation.
    public static func givenFilesNote(_ paths: [String]) -> String {
        "They've given you these for this conversation (read them when a question needs them; a folder, look inside): "
            + paths.joined(separator: ", ")
    }

    /// Dropped files in a few words: "practical3.pdf", "a.pdf and b.pdf", "the GIS folder", "4 files".
    public static func filesInWords(_ paths: [String]) -> String {
        func name(_ p: String) -> String {
            var dir: ObjCBool = false
            let n = (p as NSString).lastPathComponent
            return FileManager.default.fileExists(atPath: (p as NSString).expandingTildeInPath, isDirectory: &dir) && dir.boolValue
                ? "the \(n) folder" : n
        }
        switch paths.count {
        case 0: return "nothing"
        case 1: return name(paths[0])
        case 2: return "\(name(paths[0])) and \(name(paths[1]))"
        default: return "\(paths.count) files"
        }
    }

    // MARK: The wait

    /// The status line while Claude works on an answer: true stages only, from what
    /// Claude has said so far (it shares that it's thinking and roughly how much, never
    /// what). Each line stays up long enough to read; a stage that's already over by
    /// then is skipped, so a quick answer doesn't flash three lines past.
    public struct WaitLine {
        /// A line stays at least this long before the next replaces it.
        public static let hold: TimeInterval = 0.7
        /// After this long without the answer: "Still thinking…".
        public static let stillAfter: TimeInterval = 15
        public static let still = "Still thinking…"

        public enum Decision: Equatable { case show, later(TimeInterval), ignore }

        public private(set) var showing: String?
        private var shownAt = Date.distantPast
        public private(set) var waiting: String?

        public init() {}

        /// The line for a stage of the wait.
        public static func line(for w: Shell.Waiting) -> String {
            switch w {
            case .sent: return "Reading your screen…"
            case .thinking(let n): return n < 600 ? "Thinking…" : "Thinking it through…"
            }
        }

        /// A line was put up (by this, or by the app's own "Looking…").
        public mutating func shown(_ line: String, at now: Date) {
            showing = line
            shownAt = now
            waiting = nil
        }

        /// The wait wants `line` up: now, after the current one has had its time (the latest
        /// wanted wins), or not at all if it's already there or on its way.
        public mutating func want(_ line: String, at now: Date) -> Decision {
            guard line != showing else { waiting = nil; return .ignore }
            let left = Self.hold - now.timeIntervalSince(shownAt)
            if left <= 0 { return .show }
            let first = waiting == nil
            waiting = line
            return first ? .later(left) : .ignore
        }

        /// The answer is here, or the wait is over: nothing more to show.
        public mutating func end() { showing = nil; waiting = nil; shownAt = .distantPast }
    }

    /// What Claude hears when a kept lesson is picked up from the menu or History.
    public static let resumeEvent = "They've come back to this lesson after a break: it was kept from an earlier sitting. "
        + "The screen may look quite different now. In a few words say where they'd got to, then give the next step from what's on screen."

    /// The same question three times running: a rare grumpy look, as a wink.
    public struct RepeatWatch {
        private var recent: [String] = []
        public init() {}

        /// True on the third time running (and then it starts counting again). Digits and
        /// operators count as words: "what is 7 × 8" and "what is 7 + 8" are different questions.
        public mutating func note(_ q: String) -> Bool {
            let key = q.lowercased().filter { $0.isLetter || $0.isNumber || $0.isSymbol || $0 == " " }.trimmingCharacters(in: .whitespaces)
            recent = Array((recent + [key]).suffix(3))
            guard recent.count == 3, Set(recent).count == 1 else { return false }
            recent = []
            return true
        }
    }

    // MARK: After an answer

    /// What a finished answer means for the lesson.
    public enum AfterAnswer: Equatable {
        /// It gave a step: arm it and wait for the user.
        case armStep
        /// It showed work the app can't see finish: wait for "continue" (or "I did it").
        case waitForContinue
        /// A step that's a scroll ("scroll down to Export"): moving on when they scroll.
        case waitForScroll
        /// A step that's typing ("type export in the search field"): moving on once they've typed.
        case waitForTyping
        /// Nothing drawn: the lesson, if any, is over.
        case finish
        /// Drawings but no step: leave things as they are.
        case carryOn
    }

    public static func afterAnswer(hasStep: Bool, stepsLeft: Int, drew: Bool, said: String, inLesson: Bool = false) -> AfterAnswer {
        if hasStep && stepsLeft > 0 { return .armStep }
        if inLesson, stepsLeft > 0 {
            if asksToScroll(said) { return .waitForScroll }
            if asksToType(said) { return .waitForTyping }
            // Anything else they're to do in a lesson waits visibly on the card, never silently.
            if drew { return .waitForContinue }
        }
        if drew && said.lowercased().contains("continue") { return .waitForContinue }
        return drew ? .carryOn : .finish
    }

    /// Whether a lesson's last words ask them to scroll ("Scroll down to Export"),
    /// rather than mention it ("no need to scroll").
    public static func asksToScroll(_ said: String) -> Bool {
        let s = said.lowercased()
        guard let r = s.range(of: #"\bscroll(ing)?\b"#, options: .regularExpression) else { return false }
        let before = s[s.startIndex..<r.lowerBound].suffix(14)
        return !["don't ", "no need to ", "without ", "not ", "no "].contains { before.hasSuffix($0) }
    }

    /// Whether a sentence tells them to click something (not "don't click").
    public static func asksToClick(_ said: String) -> Bool {
        let s = said.lowercased()
        guard let r = s.range(of: #"\b(double[- ]?|right[- ]?)?click\b"#, options: .regularExpression) else { return false }
        let before = s[s.startIndex..<r.lowerBound].suffix(14)
        return !["don't ", "no need to ", "not "].contains { before.hasSuffix($0) }
    }

    /// Whether the step's words ask for a double-click (opening a file, a disk image).
    public static func asksToDoubleClick(_ said: String) -> Bool {
        said.lowercased().range(of: #"double[- ]?click"#, options: .regularExpression) != nil
    }

    /// Whether a lesson's last words ask them to type something ("type export in the search
    /// field"), rather than name a type ("choose the file type") or tell them not to.
    public static func asksToType(_ said: String) -> Bool {
        let s = said.lowercased()
        guard !s.contains("enter key"), !s.contains("press enter"), !s.contains("hit enter") else { return false }
        var from = s.startIndex
        while let r = s.range(of: #"\b(type|enter|search for|fill in)\b"#, options: .regularExpression, range: from..<s.endIndex) {
            from = r.upperBound
            let before = s[s.startIndex..<r.lowerBound].suffix(14)
            if ["don't ", "no need to ", "not ", "never "].contains(where: { before.hasSuffix($0) }) { continue }
            // "The file type", "a type of chart": the noun, which asks for nothing.
            if s[r] == "type", s[r.upperBound...].hasPrefix(" of ")
                || ["the ", "a ", "this ", "that ", "each ", "any ", "of ", "file ", "data ", "font ", "layer ", "field ", "column ", "chart "]
                    .contains(where: { before.hasSuffix($0) }) { continue }
            return true
        }
        return false
    }

    /// How long a scroll step waits for the scroll before it stops watching (they can
    /// still say continue): long enough to read the sentence and find the page.
    public static let scrollWindow: TimeInterval = 45
    /// How far they must scroll (points) for it to count, so a nudge of the wheel doesn't.
    public static let scrollCounts: CGFloat = 40

    /// A lesson worth celebrating when it ends.
    public static func celebrates(stepsTaken: Int) -> Bool { stepsTaken >= 3 }

    // MARK: Lesson events (what Claude is told happened)

    public static func stepEvent(_ label: String, hovered: Bool, step: Int) -> String {
        "the user \(hovered ? "rested the pointer on" : "clicked") \"\(label)\" (step \(step))."
    }
    /// A practice question ([QUIZ]) answered: right, or not yet.
    public static func quizEvent(_ label: String, right: Bool) -> String {
        right ? "the user found it themselves: they clicked \(label). Confirm it briefly and warmly, then move on."
            : "the user clicked somewhere that isn't \(label). Don't reveal it yet: give one hint that narrows it down (in words or a light mark), and ask again with the same QUIZ. If this is their second miss, show it."
    }
    /// For when they carry on while it's thinking: the screen has moved past the step.
    public static let actedAgainNote = " They kept going while you were working this out, so go by this screenshot, not the last: "
        + "they may be a step or two ahead. Skip anything that already looks done and give the next step still to do, "
        + "or finish if it's all done."
    /// The lesson log's line for a step taken.
    public static func stepLog(_ label: String, hovered: Bool, quiz: Bool?) -> String {
        quiz.map { $0 ? "Answered the practice question correctly (\(label))" : "Clicked somewhere other than \(label) in a practice question" }
            ?? "\(hovered ? "Hovered over" : "Clicked") \"\(label)\""
    }
    public static func saidEvent(_ q: String) -> String { "the user said: \"\(q)\"" }

    public static func backEvent(_ label: String) -> String {
        "the user switched away and has now come back. If the step you last gave (\(label)) looks done on this screenshot, "
            + "give the next step; otherwise give it again in a few words."
    }
    public static func spaceEvent(_ label: String) -> String {
        "the window changed Space or went full screen, so everything moved. If the step you last gave (\(label)) looks done, "
            + "give the next step; otherwise give it again at its new position in a few words."
    }
    public static func missEvent(_ label: String) -> String {
        "the user clicked somewhere else in the app, not on \(label). They may have done it another way (a menu, a shortcut) "
            + "or be exploring. If the new screen shows it done, give the next step. If not, point at it again in one short "
            + "sentence, without repeating your earlier explanation."
    }
    public static func dialogEvent(_ label: String, window: String) -> String {
        "a dialog or new window (\(window)) appeared over the step (\(label)). If it needs dealing with first, say so in one "
            + "sentence and point at the button; otherwise give the step again in a few words."
    }
    public static func didItEvent(_ label: String) -> String {
        "the user says they did it (\(label)). Check the screenshot: if it's done, give the next step; if not, say kindly "
            + "what still looks different and point at it."
    }
    public static func showAgainEvent(_ label: String) -> String {
        "the user asked to see the step again (\(label)). Give it again with a TARGET, in a few words."
    }
    public static func stuckEvent(_ label: String) -> String {
        "the user says they're stuck on \(label). Show exactly where with a TARGET and one sentence of why."
    }
    /// After an errand: what was opened or saved, so Claude carries on from the new screen.
    public static func openedEvent(_ things: [String]) -> String {
        "you opened \(things.joined(separator: " and ")); it's in front now. Carry on from this screen: point at what they "
            + "need on it, or finish. Don't open it again."
    }
    public static func downloadedEvent(_ path: String) -> String {
        "the download finished: it's saved at \(path). Carry on: open it in the app it's for if that's the next step, "
            + "or say where it is and what to do with it."
    }
    /// System dialogs that come forward over whatever you're doing (password and
    /// keychain prompts, permission alerts): not a switch to another app.
    public static let systemDialogs: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.coreservices.uiagent", "com.apple.UserNotificationCenter",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.CoreLocationAgent", "com.apple.tccd",
    ]

    /// How long after an errand an app coming forward counts as the errand's doing.
    public static let errandSettle: TimeInterval = 6
    /// How many looks in a row may follow errands before Navi stops and waits.
    public static let errandChain = 3

    /// What a scroll instruction is scrolling to: "Scroll down to Rendering" → "Rendering",
    /// "Scroll up until you see the Camera dropdown" → "Camera". A quoted name wins.
    public static func scrollTarget(_ said: String) -> String? {
        // A quote stands on its own: the apostrophes in "the Camera's settings, where it's set" aren't one.
        if let q = said.range(of: #"(?<![\p{L}\d])["“']([^"”']{2,40})["”'](?![\p{L}\d])"#, options: .regularExpression) {
            return String(said[q]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' "))
        }
        guard let r = said.range(of: #"(?i)scroll(?:ing)?\b[^.;]*?\b(?:to|until you (?:see|reach|find|get to)|until)\s+(?:the\s+)?"#,
                                 options: .regularExpression) else { return nil }
        var rest = String(said[r.upperBound...])
        for stop in [",", ".", ";", " and ", " section", " heading", " folder", " setting", " option", " row", " panel", " tab", " button",
                     " dropdown", " menu", " which", " where", " so ", " near", " just", " in the", " at the", " below", " above"] {
            if let s = rest.range(of: stop, options: .caseInsensitive) { rest = String(rest[..<s.lowerBound]) }
        }
        var words = rest.trimmingCharacters(in: .whitespaces)
        if words.hasSuffix("'s") || words.hasSuffix("’s") { words = String(words.dropLast(2)) }   // "the Camera's settings" → Camera
        guard words.count >= 2, words.split(separator: " ").count <= 4, !["it", "them", "the bottom", "the top", "the end"].contains(words.lowercased())
        else { return nil }
        return words
    }

    /// While a scroll step's target isn't in view, how far (points) and how long the scrolling
    /// may go before Navi asks Claude again (they may be going the wrong way).
    public static let scrollGiveUp: CGFloat = 4000
    public static let scrollPatience: TimeInterval = 20
    /// How long scrolling must pause before Navi reads the screen.
    public static let scrollPause: TimeInterval = 1.0

    public static func scrolledToEvent(_ target: String) -> String {
        "the user scrolled and \(target) is now in view. Give the next step on it."
    }

    public static let scrollStepEvent = "the user scrolled as you asked. If the screen now shows what they were scrolling to, "
        + "give the next step; if it isn't in view yet, tell them to keep scrolling, in a few words."
    public static let typeStepEvent = "the user typed as you asked. If the screen shows it worked (results, the text in place), "
        + "give the next step; if not, say what to do in a few words."
    /// After the last key, how long typing must pause before it counts as done.
    public static let typingPause: TimeInterval = 1.2
    public static let scrolledEvent = "the user scrolled, so the page moved. If the step you last gave is still the next thing to do, "
        + "give it again at its new position; if the screen shows it's done, give the next step."
    public static func shortcutEvent(_ label: String) -> String {
        "the user pressed a keyboard shortcut and the screen changed. They may have done the step (\(label)) "
            + "with the keyboard. If it looks done, give the next step; if not, point at it again in a few words."
    }

    // MARK: Away and back

    /// What a change means for a lesson in progress.
    public enum Change { case switched, space, miss }
    public enum Reaction: Equatable { case look, pause, ignore }
    /// Fresh looks after clicks elsewhere in the app, per step, so it can't loop.
    public static let maxLooks = 3

    public static func reaction(to change: Change, inLessonApp: Bool, onLessonScreen: Bool, paused: Bool, looks: Int) -> Reaction {
        switch change {
        case .switched:
            if inLessonApp { return paused ? .look : .ignore }
            return onLessonScreen && !paused ? .pause : .ignore
        case .space:
            if inLessonApp { return .look }
            return paused ? .ignore : .pause
        case .miss:
            if inLessonApp { return looks < maxLooks ? .look : .ignore }
            return onLessonScreen ? .pause : .ignore
        }
    }

    // MARK: Slow apps

    public static let settleFirst: TimeInterval = 4
    public static let settleMost: TimeInterval = 10

    /// The first settle wait for an app: the usual 4 s, or a little over what it needed last time.
    public static func settleTimeout(remembered: TimeInterval?) -> TimeInterval {
        guard let r = remembered, r > settleFirst else { return settleFirst }
        return min(settleMost, r + 1)
    }

    /// What to remember after a settle: the time, if the app was slow; otherwise forget it.
    public static func rememberedSettle(took: TimeInterval) -> TimeInterval? { took > settleFirst ? took : nil }

    // MARK: Dialogs over a step

    /// An on-screen window (top-left coordinates). On the Mac, `id` is a
    /// CGWindowID and `pid` a pid_t; another shell uses its own handles.
    public struct ScreenWindow: Equatable {
        public let id: UInt32
        public let pid: Int32
        public let layer: Int
        public let bounds: CGRect
        public let name: String

        public init(id: UInt32, pid: Int32, layer: Int, bounds: CGRect, name: String) {
            (self.id, self.pid, self.layer, self.bounds, self.name) = (id, pid, layer, bounds, name)
        }
    }

    /// The topmost window over a step's centre, if it appeared after the step was armed.
    /// Normal, floating and modal-panel levels only (0…8), and big enough to be a
    /// dialog rather than a tooltip.
    public static func newWindowOver(_ centre: CGPoint, in windows: [ScreenWindow], baseline: Set<UInt32>, ownPID: Int32) -> ScreenWindow? {
        guard let top = windows.first(where: { $0.pid != ownPID && (0...8).contains($0.layer)
            && $0.bounds.width >= 80 && $0.bounds.height >= 40 && $0.bounds.contains(centre) }) else { return nil }
        return baseline.contains(top.id) ? nil : top
    }

    /// Watches for a new window over the armed step and reports it once it has
    /// stayed there for `debounce` seconds.
    public struct DialogWatch {
        public static let debounce: TimeInterval = 0.8
        public var baseline: Set<UInt32>
        public var seen: (id: UInt32, at: Date)?

        public init(baseline: Set<UInt32>) { self.baseline = baseline }

        public mutating func sample(_ windows: [ScreenWindow], centre: CGPoint, ownPID: Int32, now: Date) -> ScreenWindow? {
            guard let w = Tutor.newWindowOver(centre, in: windows, baseline: baseline, ownPID: ownPID) else { seen = nil; return nil }
            guard let seen, seen.id == w.id else { self.seen = (w.id, now); return nil }
            guard now.timeIntervalSince(seen.at) >= Self.debounce else { return nil }
            baseline.insert(w.id)   // once only
            self.seen = nil
            return w
        }
    }

    // MARK: Explanation colours

    /// Which explanation colour each labelled thing gets, 3Blue1Brown-style: the
    /// next colour in order of introduction, kept for the whole answer. Indices into
    /// `Tokens.explanation`; nil means the pen's ink. The shell turns them into colours.
    public struct ColourBinding {
        public let on: Bool
        public let count: Int
        public private(set) var byLabel: [String: Int] = [:]
        /// Single letters that name a coloured thing: "leg a", "side b", "c".
        public private(set) var letterIndex: [Character: Int] = [:]

        public init(on: Bool, count: Int = Tokens.shared.explanation.count) { (self.on, self.count) = (on, max(1, count)) }

        /// The colour index to draw `a` in, or nil for ink.
        public mutating func index(for a: Annotation) -> Int? {
            if case .write = a { return nil }   // formulas are ink, with their letters bound
            guard on, let label = a.label?.lowercased().trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
            if let known = byLabel[label] { return known }
            let i = byLabel.count % count
            byLabel[label] = i
            if let last = label.split(separator: " ").last, last.count == 1, let ch = last.first, ch.isLetter { letterIndex[ch] = i }
            return i
        }

        /// The colour index of the thing a beat names.
        public func index(named label: String?) -> Int? {
            guard on, let l = label?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
            return byLabel[l]
        }
    }
}
