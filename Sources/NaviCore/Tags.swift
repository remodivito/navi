import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// One visual instruction parsed from Claude's reply. Coordinates are in the
/// pixel space of the named screenshot (top-left origin). Screen 1 is the
/// screen the cursor was on.
public enum Annotation: Equatable {
    case point(CGPoint, label: String?, screen: Int)
    case shape(ShapeKind, [CGPoint], label: String?, screen: Int)
    case target(CGPoint, radius: CGFloat, label: String?, screen: Int)
    /// Like a target, but the step advances when the pointer rests on it.
    case hover(CGPoint, radius: CGFloat, label: String?, screen: Int)
    /// A work area: top-left corner plus size, in screenshot pixels.
    case highlight(CGRect, label: String?, screen: Int)
    /// Handwritten text (a formula, a worked example, a note) whose top-left is at the point.
    case write(CGPoint, text: String, screen: Int)
    /// A practice question: "click the …". Like a target, but nothing is drawn
    /// and nothing points at it; the app grades the click.
    case quiz(CGPoint, radius: CGFloat, label: String?, screen: Int)
    /// An errand, not a drawing: open a web page, an app, or a file (in `app`, if named).
    case open(String, app: String?)
    /// An errand that asks first: download a file (http or https).
    case download(String)
    /// "Show me": a ghost pointer acts out a drag from the first point to the last.
    /// Nothing is clicked or moved; it's for motions Navi can't watch.
    case demo([CGPoint], label: String?, screen: Int)

    public var screen: Int {
        switch self {
        case .point(_, _, let s), .shape(_, _, _, let s), .target(_, _, _, let s), .hover(_, _, _, let s),
             .highlight(_, _, let s), .write(_, _, let s), .quiz(_, _, _, let s), .demo(_, _, let s): return s
        case .open, .download: return TagParser.cursorScreen
        }
    }

    /// Opening or downloading something: done, not drawn.
    public var isAction: Bool {
        switch self { case .open, .download: return true; default: return false }
    }

    public var label: String? {
        switch self {
        case .point(_, let l, _), .shape(_, _, let l, _), .target(_, _, let l, _), .hover(_, _, let l, _),
             .highlight(_, let l, _), .quiz(_, _, let l, _), .demo(_, let l, _): return l
        case .write(_, let text, _): return text
        case .open, .download: return nil
        }
    }

    /// Advances a walkthrough when the user acts on it.
    public var isStep: Bool {
        switch self { case .target, .hover, .quiz: return true; default: return false }
    }
}

/// One spoken sentence and the drawing that goes with it. A reply plays as
/// beats: draw, say that beat's words, then the next.
public struct Beat: Equatable {
    public var text: String
    public var annotation: Annotation?
    /// Part of the practice line ([TRY:…]): the user's turn to think.
    public var practice = false
    /// Where Navi's light points as words are read ("[@x,y]gain"): no ink, just attention.
    public var stops: [Stop] = []

    public struct Stop: Equatable {
        /// Which word of `text` (split on spaces) the light arrives with.
        public let word: Int
        /// Screenshot pixels, on the beat's screen.
        public let point: CGPoint

        public init(word: Int, point: CGPoint) { (self.word, self.point) = (word, point) }
    }

    public init(text: String, annotation: Annotation?, practice: Bool = false, stops: [Stop] = []) {
        (self.text, self.annotation, self.practice, self.stops) = (text, annotation, practice, stops)
    }
}

public enum ShapeKind: String, Equatable {
    case line, arrow, circle, curve, polygon
}

/// Text Claude wants typed into a field: `[TYPE]<<<text>>>` or `[TYPE:x,y]<<<text>>>`.
public struct TypeRequest: Equatable {
    public var text: String
    public var at: CGPoint?
    public var screen: Int

    public init(text: String, at: CGPoint?, screen: Int) { (self.text, self.at, self.screen) = (text, at, screen) }
}

public struct ParsedReply: Equatable {
    public var annotations: [Annotation]
    public var typing: TypeRequest?
    public var text: String
    /// Things to keep: copied to the clipboard, saved as a note, set as a reminder.
    public var keeps: [Keep]

    public init(annotations: [Annotation], typing: TypeRequest?, text: String, keeps: [Keep] = []) {
        (self.annotations, self.typing, self.text, self.keeps) = (annotations, typing, text, keeps)
    }
}

/// A block Claude hands over to keep: `[COPY]<<<text>>>`, `[NOTE:title]<<<body>>>`,
/// `[REMIND:2026-10-30 09:00]<<<what>>>` (when is optional).
public struct Keep: Equatable {
    public enum Kind: String { case copy = "COPY", note = "NOTE", remind = "REMIND" }
    public var kind: Kind
    /// The note's title, or when to be reminded (as written).
    public var detail: String?
    public var text: String

    /// What was kept, for the caption: its first 40 characters on one line ("…" if cut).
    public var preview: String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    /// The kicker once a COPY is on the clipboard: says what was copied, so a command
    /// put there is never a surprise.
    public var copiedKicker: String { "COPIED · " + preview }
}

/// Tag grammar:
///   [POINT:x,y:label]                   [POINT:none] draws nothing
///   [HIGHLIGHT:x,y,w,h:label]           a work area
///   [HOVER:x,y,r:label]                 hover-to-reveal step
///   [WRITE:x,y:text]                    handwritten text, top-left at x,y
///   [SHAPE:arrow:x1,y1;x2,y2:label]     line | arrow | curve | polygon take 2+ points (polygon 3+)
///   [SHAPE:circle:cx,cy;ex,ey:label]    centre, then a point on the ring
///   [TARGET:x,y,r:label]                click-to-advance target (r defaults to 74)
///   [QUIZ:x,y,r:label]                  a practice click, graded but not drawn
///   [TYPE:x,y]<<<text>>>                type into a field (coordinates optional)
///   [OPEN:https://…] [OPEN:App name] [OPEN:~/path|App]   open a page, an app, or a file (in an app)
///   [DOWNLOAD:https://…]                download a file, after asking
///   [SHOWME:x1,y1;x2,y2:label]          a ghost pointer acts out a drag (nothing is clicked)
///   [COPY]<<<text>>>  [NOTE:title]<<<body>>>  [REMIND:when]<<<what>>>   things to keep
/// Any drawing tag (and TYPE) may end with `:screenN`; OPEN, DOWNLOAD and the keeps take their
/// body whole. Labels are optional and can't contain colons.
public enum TagParser {
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"\[(POINT|SHAPE|TARGET|HOVER|HIGHLIGHT|WRITE|QUIZ|OPEN|DOWNLOAD|SHOWME):([^\]\n]*)\]"#, options: [.caseInsensitive])
    private static let typeRegex = try! NSRegularExpression(
        pattern: #"\[TYPE(?::([^\]\n]*))?\]\s*<<<\s*([\s\S]*?)\s*>>>"#, options: [.caseInsensitive])
    private static let keepRegex = try! NSRegularExpression(
        pattern: #"\[(COPY|NOTE|REMIND)(?::([^\]\n]*))?\]\s*<<<\s*([\s\S]*?)\s*>>>"#, options: [.caseInsensitive])
    // While streaming: a tag or a TYPE, COPY, NOTE or REMIND block that hasn't closed yet.
    private static let unfinishedType = try! NSRegularExpression(
        pattern: #"\[(?:TYPE|COPY|NOTE|REMIND)[^\]\n]*\]\s*(?:<<<(?![\s\S]*>>>)[\s\S]*)?$"#, options: [.caseInsensitive])
    private static let unfinishedTag = try! NSRegularExpression(
        pattern: #"\[[A-Za-z]*(?::[^\]\n]*)?$"#)
    private static let spaceBeforePunct = try! NSRegularExpression(pattern: #"\s+([.,!?;:])"#)

    /// The topic a reply names ("[TOPIC:Pythagoras]"), shown on the topic pill.
    public static func topic(_ reply: String) -> String? {
        let ns = reply as NSString
        guard let m = topicRegex.firstMatch(in: reply, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(40))
    }
    private static let topicRegex = try! NSRegularExpression(pattern: #"\[TOPIC:([^\]\n]+)\]\s*"#)
    private static func withoutTopic(_ s: String) -> String {
        var s = s
        for r in [topicRegex, moodRegex, outlineRegex, resumeRegex, skillRegex, materialRegex] {
            s = r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        return plain(s)
    }

    /// A lesson's rough plan ("[OUTLINE:Add the layer | Open Buffer | Set 500 m]"), if the reply gives one.
    public static func outline(_ reply: String) -> [String]? {
        let ns = reply as NSString
        guard let m = outlineRegex.firstMatch(in: reply, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let steps = ns.substring(with: m.range(at: 1)).split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { String($0.prefix(80)) }
        return steps.isEmpty ? nil : Array(steps.prefix(30))
    }
    private static let outlineRegex = try! NSRegularExpression(pattern: #"\[OUTLINE:([^\]\n]+)\]\s*"#)

    /// The kept lesson a reply picks up ("[RESUME:3fa9c2d1]"), if any.
    public static func resume(_ reply: String) -> String? {
        let ns = reply as NSString
        guard let m = resumeRegex.firstMatch(in: reply, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).lowercased()
    }
    private static let resumeRegex = try! NSRegularExpression(pattern: #"\[RESUME:\s*([A-Za-z0-9]+)\s*\]\s*"#)

    /// Something of theirs the answer needed and didn't have ("[MATERIAL:your lecture slides]"), if any.
    public static func material(_ reply: String) -> String? {
        let ns = reply as NSString
        guard let m = materialRegex.firstMatch(in: reply, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let what = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return what.isEmpty ? nil : String(what.prefix(40))
    }
    private static let materialRegex = try! NSRegularExpression(pattern: #"\s*\[MATERIAL:([^\]\n]+)\]"#)

    /// What a lesson step taught about the app ("[SKILL:Export a PDF | File > Export as PDF…]"):
    /// a task and how it's done, at most two a reply. Kept only after a step the user took (`Skills.learn`).
    public static func skills(_ reply: String) -> [Skills.Fact] {
        let ns = reply as NSString
        return skillRegex.matches(in: reply, range: NSRange(location: 0, length: ns.length)).compactMap { m -> Skills.Fact? in
            let parts = ns.substring(with: m.range(at: 1)).split(separator: "|", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return Skills.Fact(task: parts[0], how: parts[1])
        }.prefix(2).map { $0 }
    }
    private static let skillRegex = try! NSRegularExpression(pattern: #"\[SKILL:([^\]\n]+)\]\s*"#)

    // Web-search habits that don't belong in a caption read aloud: a list of sources,
    // markdown links (the words stay), code ticks and bold.
    private static let sourcesRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*\**Sources?\**:?\**[ \t]*\n(?:[ \t]*(?:[-*•].*)?(?:\n|$))*"#, options: [.caseInsensitive])
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((?:https?://|www\.)[^)\s]*\)"#)

    /// The reply as plain words: what a caption shows and a voice reads.
    static func plain(_ s: String) -> String {
        var s = sourcesRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        s = linkRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
        return s.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
    }

    /// Claude's pinch of tone for the owl ("[MOOD:wow]"), if any.
    public static func mood(_ reply: String) -> String? {
        let ns = reply as NSString
        guard let m = moodRegex.firstMatch(in: reply, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).lowercased()
    }
    private static let moodRegex = try! NSRegularExpression(pattern: #"\[MOOD:([A-Za-z]+)\]\s*"#)

    /// The practice move a reply used ("[TRY:predict]"), if any.
    public static func practiceMove(_ reply: String) -> String? {
        let ns = reply as NSString
        guard let m = practiceRegex.firstMatch(in: reply, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).lowercased().trimmingCharacters(in: .whitespaces)
    }
    /// Stands in for "[TRY:…]" while splitting beats (an invisible separator).
    private static let practiceMark = "\u{2063}"
    private static let practiceRegex = try! NSRegularExpression(pattern: #"\[TRY:([A-Za-z ]+)\]\s*"#)
    /// "[TRY:…]" only tells the app which move was used; it's never shown or spoken.
    private static func withoutPractice(_ s: String) -> String {
        let s = withoutTopic(s)
        return practiceRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    public static func parse(_ reply: String) -> ParsedReply {
        let reply = withoutPractice(reply)
        let ns = reply as NSString
        let full = NSRange(location: 0, length: ns.length)

        var annotations: [Annotation] = []
        for m in tagRegex.matches(in: reply, range: full) {
            let kind = ns.substring(with: m.range(at: 1)).uppercased()
            if let a = annotation(kind: kind, body: ns.substring(with: m.range(at: 2))) { annotations.append(a) }
        }

        var typing: TypeRequest?
        if let m = typeRegex.firstMatch(in: reply, range: full) {
            let text = ns.substring(with: m.range(at: 2))
            var at: CGPoint?
            var screen = cursorScreen
            if m.range(at: 1).location != NSNotFound {
                var comps = components(ns.substring(with: m.range(at: 1)))
                screen = popScreen(&comps)
                if let first = comps.first { let n = numbers(first); if n.count == 2 { at = CGPoint(x: n[0], y: n[1]) } }
            }
            if !text.isEmpty { typing = TypeRequest(text: text, at: at, screen: screen) }
        }

        var keeps: [Keep] = []
        for m in keepRegex.matches(in: reply, range: full) {
            guard let kind = Keep.Kind(rawValue: ns.substring(with: m.range(at: 1)).uppercased()) else { continue }
            let detail = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let text = ns.substring(with: m.range(at: 3))
            if !text.isEmpty { keeps.append(Keep(kind: kind, detail: detail?.isEmpty == true ? nil : detail, text: text)) }
        }
        var stripped = keepRegex.stringByReplacingMatches(in: reply, range: full, withTemplate: "")
        stripped = typeRegex.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "")
        for regex in [tagRegex, unfinishedType, unfinishedTag, anchorRegex, unfinishedAnchor] {
            stripped = regex.stringByReplacingMatches(
                in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "")
        }
        return ParsedReply(annotations: annotations, typing: typing, text: tidy(stripped), keeps: keeps)
    }

    /// Splits a reply into beats: text
    /// before a tag belongs to that tag; a tag that leads its line takes the
    /// words after it, up to the next tag or the end of the line. Unfinished
    /// tags at the end (while streaming) are left out.
    /// Whether `text` finishes a sentence (a full stop, question or exclamation mark, or a colon).
    static func endsSentence(_ text: String) -> Bool {
        text.range(of: #"[.!?…:](["”')\]]*)$"#, options: .regularExpression) != nil
    }

    public static func beats(_ reply: String) -> [Beat] {
        // The practice marker becomes an invisible boundary: no sentence runs across it,
        // and every beat from it on is practice.
        let clean = withoutTopic(reply)
        let reply = practiceRegex.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: (clean as NSString).length),
                                                           withTemplate: practiceMark)
        var body = keepRegex.stringByReplacingMatches(in: reply, range: NSRange(location: 0, length: (reply as NSString).length), withTemplate: "")
        body = typeRegex.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
        for regex in [unfinishedType, unfinishedTag] {
            body = regex.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
        }
        let ns = body as NSString
        let matches = tagRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        let practiceAt = ns.range(of: practiceMark).location
        var beats: [Beat] = []
        var cursor = 0
        /// Where a stretch's text really starts, past the line breaks and spaces before it.
        func textStart(_ from: Int) -> Int {
            let r = ns.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, range: NSRange(location: from, length: ns.length - from))
            return r.location == NSNotFound ? from : r.location
        }
        func add(_ text: String, _ a: Annotation?, from start: Int) {
            beats.append(Beat(text: text, annotation: a, practice: practiceAt != NSNotFound && start >= practiceAt))
        }
        /// Words before the practice point never share a beat with the question after it:
        /// they become their own beat (no drawing), and the cursor moves up to the point.
        func splitAtPractice(before limit: Int) {
            guard practiceAt != NSNotFound, cursor <= practiceAt, practiceAt < limit else { return }
            let lead = tidy(ns.substring(with: NSRange(location: cursor, length: practiceAt - cursor)))
            if !lead.isEmpty { add(lead, nil, from: textStart(cursor)) }
            cursor = practiceAt
        }
        for (i, m) in matches.enumerated() {
            guard m.range.location >= cursor else { continue }
            splitAtPractice(before: m.range.location)
            let a = annotation(kind: ns.substring(with: m.range(at: 1)).uppercased(), body: ns.substring(with: m.range(at: 2)))
            let pre = tidy(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            // A tag that starts its line is tag-first, whatever came before it; text
            // on earlier lines becomes its own beat with no drawing. The practice mark
            // starts a line too: "[TRY:gap] [WRITE:…] What goes in the blank?" is a tag-first
            // beat even when the sentence before it is plain text.
            let upTo = NSRange(location: 0, length: m.range.location)
            let newline = ns.range(of: "\n", options: .backwards, range: upTo).location
            let mark = ns.range(of: practiceMark, options: .backwards, range: upTo).location
            let lineStart = [newline, mark].filter { $0 != NSNotFound }.max() ?? NSNotFound
            let before = lineStart == NSNotFound ? ns.substring(to: m.range.location)
                : ns.substring(with: NSRange(location: lineStart + 1, length: m.range.location - lineStart - 1))
            let leadsLine = before.trimmingCharacters(in: .whitespaces).isEmpty
            if leadsLine && !pre.isEmpty { add(pre, nil, from: textStart(cursor)) }
            if !pre.isEmpty && !leadsLine {
                // A mark dropped mid-sentence ("…shown again, so [TARGET] click Copy key first.")
                // doesn't split the sentence: the rest of it, up to its full stop, joins this beat.
                var text = pre
                let start = textStart(cursor)
                cursor = NSMaxRange(m.range)
                if !endsSentence(pre) {
                    let nextTag = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
                    let nl = ns.range(of: "\n", options: [], range: NSRange(location: cursor, length: ns.length - cursor))
                    var limit = min(nextTag, nl.location == NSNotFound ? ns.length : nl.location)
                    if practiceAt != NSNotFound, practiceAt >= cursor { limit = min(limit, practiceAt) }
                    let rest = ns.substring(with: NSRange(location: cursor, length: limit - cursor))
                    let stop = rest.range(of: #"[.!?…](["”')\]]*)(\s|$)"#, options: .regularExpression)
                    let taken = stop.map { String(rest[..<$0.upperBound]) } ?? rest
                    let more = tidy(taken)
                    // Another mark before the sentence ends means each phrase points at its own
                    // thing ("Open File [POINT] and pick Export [POINT]."): keep those apart.
                    let anotherMarkFirst = stop == nil && limit == nextTag && nextTag < ns.length
                    if !more.isEmpty && !anotherMarkFirst {
                        let joiner = more.first.map { ".,;:!?…".contains($0) } == true ? "" : " "
                        text = tidy(pre + joiner + more)
                        cursor += (taken as NSString).length
                    }
                }
                add(text, a, from: start)
            } else {
                let after = NSMaxRange(m.range)
                let nextTag = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
                let nl = ns.range(of: "\n", options: [], range: NSRange(location: after, length: ns.length - after))
                let lineEnd = nl.location == NSNotFound ? ns.length : nl.location
                var end = max(after, min(nextTag, lineEnd))
                // A tag alone on its line: its sentence is on the following line(s).
                if tidy(ns.substring(with: NSRange(location: after, length: end - after))).isEmpty { end = max(after, nextTag) }
                if practiceAt != NSNotFound, practiceAt > after { end = min(end, practiceAt) }
                add(tidy(ns.substring(with: NSRange(location: after, length: end - after))), a, from: m.range.location)
                cursor = end
            }
        }
        splitAtPractice(before: ns.length)
        let tail = tidy(ns.substring(from: min(cursor, ns.length)))
        if !tail.isEmpty { add(tail, nil, from: textStart(min(cursor, ns.length))) }
        return beats.map(withStops).filter { !$0.text.isEmpty || $0.annotation != nil }
    }

    /// Takes the "[@x,y]" anchors out of a beat's words, remembering which word each
    /// one belongs to (the word it's attached to, or the next one).
    public static func withStops(_ beat: Beat) -> Beat {
        guard beat.text.contains("[@") else { return beat }
        var b = beat, words: [String] = [], pending: CGPoint?
        for token in beat.text.split(separator: " ").map(String.init) {
            let ns = token as NSString
            var anchor: CGPoint?
            for m in anchorRegex.matches(in: token, range: NSRange(location: 0, length: ns.length)) {
                if let x = Double(ns.substring(with: m.range(at: 1))), let y = Double(ns.substring(with: m.range(at: 2))),
                   isPixel(x), isPixel(y) { anchor = CGPoint(x: x, y: y) }
            }
            var word = anchorRegex.stringByReplacingMatches(in: token, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            word = unfinishedAnchor.stringByReplacingMatches(in: word, range: NSRange(location: 0, length: (word as NSString).length), withTemplate: "")
            if word.isEmpty {
                pending = anchor ?? pending
                continue
            }
            if let p = anchor ?? pending { b.stops.append(Beat.Stop(word: words.count, point: p)) }
            pending = nil
            words.append(word)
        }
        b.text = words.joined(separator: " ")
        return b
    }
    private static let anchorRegex = try! NSRegularExpression(pattern: #"\[@\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\]"#)
    private static let unfinishedAnchor = try! NSRegularExpression(pattern: #"\[@[^\]\s]*$"#)

    private static func tidy(_ s: String) -> String {
        let s = s.replacingOccurrences(of: practiceMark, with: " ")
        var t = tagRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        t = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return spaceBeforePunct.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "$1")
    }

    private static func annotation(kind: String, body: String) -> Annotation? {
        // Errands take their target whole: URLs and paths have colons of their own.
        if kind == "OPEN" || kind == "DOWNLOAD" {
            let parts = body.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = parts.first, !target.isEmpty else { return nil }
            if kind == "DOWNLOAD" {
                let lower = target.lowercased()
                return lower.hasPrefix("https://") || lower.hasPrefix("http://") ? .download(target) : nil
            }
            return .open(target, app: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
        }
        var comps = components(body)
        let segments = comps.count   // a label or a :screenN suffix counts as the second segment
        let screen = popScreen(&comps)
        guard !comps.isEmpty else { return nil }

        switch kind {
        case "SHOWME":
            let pts = comps[0].split(separator: ";").map { numbers(String($0)) }.filter { $0.count == 2 }.map { CGPoint(x: $0[0], y: $0[1]) }
            guard pts.count >= 2 else { return nil }
            return .demo(pts, label: label(comps.dropFirst()), screen: screen)
        case "POINT":
            if comps[0].lowercased() == "none" { return nil }
            let n = numbers(comps[0])
            guard n.count == 2 else { return nil }
            return .point(CGPoint(x: n[0], y: n[1]), label: label(comps.dropFirst()), screen: screen)

        case "TARGET", "HOVER", "QUIZ":
            // These need a label segment (it may be empty). A radius that isn't positive
            // counts as none: the step still exists, at the default size.
            let n = numbers(comps[0])
            guard segments >= 2, n.count == 2 || n.count == 3 else { return nil }
            let r = n.count == 3 && n[2] > 0 ? n[2] : 74   // the radius when none is given
            let p = CGPoint(x: n[0], y: n[1]), l = label(comps.dropFirst())
            if kind == "QUIZ" { return .quiz(p, radius: r, label: l, screen: screen) }
            return kind == "HOVER" ? .hover(p, radius: r, label: l, screen: screen) : .target(p, radius: r, label: l, screen: screen)

        case "WRITE":
            let n = numbers(comps[0])
            let text = comps.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            guard n.count == 2, !text.isEmpty else { return nil }
            return .write(CGPoint(x: n[0], y: n[1]), text: String(text.prefix(80)), screen: screen)

        case "HIGHLIGHT":
            let n = numbers(comps[0])
            guard segments >= 2, n.count == 4 else { return nil }
            let rect = CGRect(x: n[0], y: n[1], width: max(1, n[2]), height: max(1, n[3]))
            return .highlight(rect, label: label(comps.dropFirst()), screen: screen)

        case "SHAPE":
            guard comps.count >= 2, let shape = ShapeKind(rawValue: comps[0].lowercased()) else { return nil }
            let points = comps[1].split(separator: ";").compactMap { pair -> CGPoint? in
                let n = numbers(String(pair))
                return n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil
            }
            guard points.count >= (shape == .polygon ? 3 : 2) else { return nil }
            return .shape(shape, points, label: label(comps.dropFirst(2)), screen: screen)

        default:
            return nil
        }
    }

    private static func components(_ body: String) -> [String] {
        body.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Removes a trailing `screenN` component and returns N, or `cursorScreen`
    /// (0) when there is none: an unmarked tag goes on the screen with the cursor.
    /// The screen number an unmarked tag means: whichever has the cursor.
    public static let cursorScreen = 0

    private static func popScreen(_ comps: inout [String]) -> Int {
        guard let last = comps.last?.lowercased(), last.hasPrefix("screen"),
              let n = Int(last.dropFirst("screen".count).trimmingCharacters(in: .whitespaces)), n >= 1 else { return cursorScreen }
        comps.removeLast()
        return n
    }

    private static func numbers(_ s: String) -> [CGFloat] {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap { Double($0) }.filter(isPixel)
        return values.count == parts.count ? values.map { CGFloat($0) } : []
    }

    /// A number that could be a screenshot pixel. `Double("nan")`, "inf" and "1e30" all
    /// parse, and the engine turns coordinates into Int for traces and seeds, which traps
    /// on anything like that; the largest screenshot is a few thousand pixels across.
    private static func isPixel(_ v: Double) -> Bool { v.isFinite && abs(v) <= 100_000 }

    private static func label<S: Sequence>(_ rest: S) -> String? where S.Element == String {
        let s = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}
