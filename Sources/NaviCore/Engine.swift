import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Tutor {
    /// Explanation colours, 3Blue1Brown-style: each labelled thing gets the next
    /// colour in order of introduction and keeps it for the whole answer.
    /// `nil` means the shell's ordinary ink.
    public struct Quantities {
        /// Blue, gold, red, then green (only past three things, never in lessons): design-tokens.json, explanation.
        public static var palette: [(dark: Colour, light: Colour)] { Tokens.shared.explanation.map { ($0.dark, $0.light) } }
        private var binding: ColourBinding
        public var on: Bool { binding.on }

        public init(on: Bool) { binding = ColourBinding(on: on, count: Self.palette.count) }

        /// The colour to draw `a` in; `lightPage` picks the deeper version.
        public mutating func colour(for a: Annotation, lightPage: Bool = false) -> Colour? {
            guard let i = binding.index(for: a) else { return nil }
            return lightPage ? Self.palette[i].light : Self.palette[i].dark
        }

        /// Letter colours for a formula on a light or dark page.
        public func letters(lightPage: Bool) -> [Character: Colour] {
            binding.letterIndex.mapValues { lightPage ? Self.palette[$0].light : Self.palette[$0].dark }
        }

        /// The colour of the thing a beat names, for the (always dark) caption.
        public func colour(named label: String?) -> Colour? {
            binding.index(named: label).map { Self.palette[$0].dark }
        }
    }

    /// The teaching engine: plays Claude's reply as beats on any shell.
    ///
    /// Each beat is drawn (the light traces the mark, the ink follows), its words
    /// are read in the caption, and the next beat waits until they've been read.
    /// It reaches the screen only through the `Shell` protocols. More of the flow
    /// (asking, lesson steps, pauses) lives here too.
    public final class Engine {
        let overlay: any Shell.Overlay
        let light: any Shell.Companion
        let caption: any Shell.Caption
        let ui: any Shell.UIReader
        let screens: any Shell.ScreenSource
        let voice: (any Shell.Voice)?
        let settings: Settings

        /// The current generation: a newer one (a step taken early, a new question)
        /// makes everything still running for an older one stale. `bump()` starts one.
        public internal(set) var currentGeneration = 0
        /// How the engine reads the generation (tests can stand in their own).
        public lazy var generation: () -> Int = { [unowned self] in self.currentGeneration }
        /// The request or look in flight; cancelled when something newer starts.
        public var turn: Task<Void, Never>?

        // The app around the engine and the shell's watch over a lesson (the shell owns them).
        public weak var host: (any Shell.Host)?
        public weak var watch: (any Shell.LessonWatch)?
        public var pauseCard: (any Shell.PauseCard)?
        public var topicPill: (any Shell.TopicPill)?

        // The lesson.
        public var lesson: Walkthrough?
        /// The app the lesson is in, and the display its steps are on.
        public var lessonApp: Int32?
        public var lessonScreen: ScreenID?
        /// The last step given, for the paused card and for "look again".
        public var stepLabel: String?
        public internal(set) var lessonPaused = false
        /// Fresh looks after clicks elsewhere in the app, per step, so it can't loop.
        public var looksThisStep = 0
        public internal(set) var lookPending = false
        /// What to say when the lesson app comes forward after a card choice.
        public var pendingLookEvent: String?
        /// Clicks just after a step is taken belong to it, not to the next.
        public var graceUntil: Date?
        var hoverRest = Walkthrough.HoverRest()
        var expiry: Timer?
        var pauseExpiry: Timer?
        /// How long a step's result took to settle, for apps that needed more than
        /// `settleFirst` last time. In memory only.
        var slowSettles: [String: TimeInterval] = [:]
        /// Errands: opening pages, apps and files, and downloads after asking.
        public var actions: (any Shell.Actions)?
        /// What this turn opened, so the next look can carry on from it; and how many
        /// looks in a row have followed an errand (a chain stops at three).
        var opened: [String] = []
        var errandLooks = 0
        /// Until when an app coming forward is Navi's own errand (the page it opened),
        /// not the user moving on: the answer keeps going and the look follows them.
        var errandUntil: Date?
        /// Ends a scroll or typing step that's waited too long (onto the card).
        var actExpiry: DispatchWorkItem?
        /// How many errands one reply may run: more than this is a page talking, not teaching.
        public static let opensPerReply = 2, downloadsPerReply = 1
        var errandsThisReply = (opens: 0, downloads: 0)
        /// A download offered and not yet answered: no other is offered until it is.
        var downloadPending = false
        /// Counts the user's questions, so a download that lands after a new one stays quiet.
        var questionsAsked = 0
        /// The reply that gave the step now armed, for how it's to be done ("double-click").
        var stepReply = ""
        /// The target this turn's reply named, drawn as soon as it arrived (where it was asked for).
        var earlyTarget: CGPoint?
        /// While they're trying it themselves, every turn says so.
        public var tryFirst = false
        /// The last few practice moves, so Navi varies them rather than repeating one.
        public var practiceMoves = Tutor.PracticeMoves()

        // The topic.
        /// What Navi is talking about, named by Claude ([TOPIC:…]). While it's set,
        /// a question carries on from the last; the pill shows it once the answer clears.
        public internal(set) var topic: String?
        var topicTimer: Timer?
        var repeats = Tutor.RepeatWatch()
        // The screen moving under the drawing.
        var scrolledBy: CGFloat = 0
        var rePlaceWork: DispatchWorkItem?
        /// A scroll step: until when it waits for the scroll, and on which display.
        public var scrollStep: (until: Date, display: ScreenID)?
        /// What a scroll step is scrolling to ("Rendering"), read off the screen to know
        /// they're there; and when the scrolling began.
        public var scrollSeeking: String?
        var scrollStarted: Date?
        /// A typing step, the same way; `typedWork` fires once the typing pauses.
        public var typeStep: (until: Date, display: ScreenID)?
        var typedWork: DispatchWorkItem?

        // Kept lessons.
        /// Where lessons put down partway are kept (tests stand in their own).
        public var bookmarks = Bookmarks.shared
        /// The last question asked, so "Start fresh instead" can ask it again without picking anything up.
        var lastAsking: Asking?
        /// The next question doesn't offer Claude the kept lessons.
        var skipBookmarks = false
        /// Files dropped on Navi with no lesson to add them to: they go with the next question.
        public internal(set) var pendingFiles: [String] = []
        /// What the last answer said it needed of theirs ([MATERIAL:…]), to offer adding it.
        var material: String?
        /// Each piece of the reply as it streams in (picking up a kept lesson as soon as it says so).
        public var onPartial: ((_ partial: String) -> Void)?

        /// The conversation, so clearing the topic starts the next turn fresh.
        public weak var conversation: Conversation?
        /// The app being taught, for snapping marks to its controls.
        public var frontApp: () -> Shell.AppInfo? = { nil }
        /// Called as each beat starts (the answer is here: clicks from now on are the lesson's).
        public var onBeatStart: (() -> Void)?
        /// How the engine waits (for reading time, or the pen to touch down). Tests shorten it.
        public var wait: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

        /// Whether an answer's beats are playing, and the last sentence said.
        public var beatsPlaying = false
        public var lastSentence = ""
        /// This answer's colours (on only for explanations).
        public var quantities = Quantities(on: false)

        /// Whether the light traced the last mark itself (so it needn't fly to it).
        public private(set) var drewWithTrace = false
        private var traceEnds = Date.distantPast
        private var strokeStarts = Date.distantPast

        public init(overlay: any Shell.Overlay, light: any Shell.Companion, caption: any Shell.Caption,
                    ui: any Shell.UIReader, screens: any Shell.ScreenSource, voice: (any Shell.Voice)?, settings: Settings = .shared) {
            (self.overlay, self.light, self.caption, self.ui, self.screens, self.voice, self.settings) =
                (overlay, light, caption, ui, screens, voice, settings)
        }

        /// What one turn's beat player has done so far.
        public final class Turn {
            /// The generation this answer belongs to; a newer one makes its beats stale.
            public var gen = 0
            public var queued = 0
            public var done = false
            /// The reply broke off: what's still queued stays unsaid.
            public var failed = false
            public var chain: Task<Void, Never>?
            public var shown = ""
            public var step: Walkthrough.Step?
            public var drawings = 0
            public var sentences = 0
            /// How fast the reply arrived, so typed answers reveal at that pace.
            public var streamStart: Date?
            public var streamChars = 0
            public var wordsPerSecond: Double { Tutor.revealRate(chars: streamChars, since: streamStart) }
            /// The first beat's drawing, started as soon as its tag is complete
            /// (before its sentence has finished streaming).
            public var early: Task<(CGPoint, Walkthrough.Step?)?, Never>?
            public init() {}
        }

        /// The screenshot a tag's screen number means; 0 is the one with the cursor.
        public static func shot(_ n: Int, in shots: [any Shell.Screenshot]) -> any Shell.Screenshot {
            Tutor.shot(n, in: shots, index: { $0.index }, hasCursor: { $0.hasCursor })
        }

        // MARK: A turn

        /// Sends a turn to Claude: `content`, as `kind`, streaming the reply's text to `onText`.
        /// The shell supplies it (its conversation and backend).
        public var send: (_ content: [[String: Any]], _ kind: Conversation.Kind,
                          _ onText: @escaping (String) -> Void) async throws -> String = { _, _, _ in "" }
        /// Whether a reply is still on its way (a look again mustn't start another).
        public private(set) var waitingForReply = false
        /// The first beat is a lesson step: arm it as soon as its tag arrives.
        public var onEarlyStep: ((_ partial: String) -> Void)?
        /// The whole reply has arrived (its beats may still be playing).
        public var onReply: ((_ reply: String) -> Void)?

        /// What a turn's playback came to.
        public struct Played {
            public let reply: String
            public let shown: String
            public let step: Walkthrough.Step?
            public let drawings: Int
        }

        /// Sends one turn and plays the reply as beats while it streams in: each beat
        /// is drawn, the light flies to it, and its sentence is read before the next
        /// beat starts. A thin explanation is redrawn once. Returns nil if a newer
        /// generation took over; what happens next (arming a step, pausing, clearing)
        /// is still the shell's for now.
        @MainActor
        public func playTurn(_ content: [[String: Any]], shots: [any Shell.Screenshot], anchor: CGPoint, gen: Int,
                             explain: Bool, kind: Conversation.Kind, speak: Bool) async throws -> Played? {
            quantities = Quantities(on: explain)
            errandsThisReply = (0, 0)
            let t = Turn()
            t.gen = gen
            let enqueue: (Beat) -> Void = { [weak self] beat in
                let previous = t.chain
                t.chain = Task { @MainActor in
                    await previous?.value
                    guard let self, gen == self.generation(), !t.failed else { return }
                    let early = t.early
                    t.early = nil
                    if let s = await self.play(beat, shots: shots, anchor: anchor, turn: t, speak: speak, drawn: early) { t.step = s }
                }
            }

            waitingForReply = true
            defer { waitingForReply = false }
            var reply: String
            do {
                reply = try await send(content, kind) { partial in
                    DispatchQueue.main.async {
                        guard gen == self.generation(), !t.done else { return }
                        if t.streamStart == nil { t.streamStart = Date() }
                        self.onPartial?(partial)
                        t.streamChars = partial.count
                        let beats = TagParser.beats(partial)
                        if t.queued == 0, t.early == nil, let first = beats.first, let a = first.annotation {
                            let shot = Self.shot(a.screen, in: shots)
                            t.early = Task { @MainActor in
                                self.drewWithTrace = false   // the last answer's stroke doesn't keep the light from flying here
                                let r = await self.draw(a, shot: shot, sentence: "")
                                if let r, !self.drewWithTrace { self.light.fly(to: r.0, clear: r.1?.radius ?? 16) }
                                return r
                            }
                            trace("First pointer drawn early.")
                            if case .target = a { self.onEarlyStep?(partial) }
                            if case .hover = a { self.onEarlyStep?(partial) }
                        }
                        while t.queued < beats.count - 1 { enqueue(beats[t.queued]); t.queued += 1 }
                    }
                }
            } catch {
                // The reply broke off: the error is shown, so the beats already queued don't
                // carry on being read underneath it.
                t.done = true
                t.failed = true
                throw error
            }
            guard gen == generation() else { return nil }
            waitingForReply = false
            t.done = true
            let beats = TagParser.beats(reply)
            while t.queued < beats.count { enqueue(beats[t.queued]); t.queued += 1 }
            trace("Claude:\n\(reply)\n", content: true)
            onReply?(reply)
            await t.chain?.value
            guard gen == generation() else { return nil }
            if explain, let gap = Tutor.explanationGap(reply) {
                // Check the structure in code and redo it once with a precise note. Playback isn't held for this, so good answers lose no time.
                trace("Explanation too thin (\(gap)); redrawing.")
                let note = Tutor.redrawNote(gap)
                if let retry = try? await send([Prompt.text(note)], .retry, { _ in }), gen == generation(),
                   TagParser.parse(retry).annotations.count > TagParser.parse(reply).annotations.count {
                    reply = retry
                    overlay.fadeDrawings()
                    let more = TagParser.beats(retry)
                    t.queued = 0
                    for b in more { enqueue(b) }
                    trace("Claude (redrawn):\n\(retry)\n", content: true)
                    await t.chain?.value
                }
                guard gen == generation() else { return nil }
            }
            return Played(reply: reply, shown: t.shown, step: t.step, drawings: t.drawings)
        }

        // MARK: Beats

        /// Draws one beat, flies the light to it and shows its words, then waits
        /// for them to be read. Returns the step if the beat was a TARGET, HOVER or QUIZ.
        @MainActor
        public func play(_ beat: Beat, shots: [any Shell.Screenshot], anchor: CGPoint, turn t: Turn, speak: Bool,
                         drawn: Task<(CGPoint, Walkthrough.Step?)?, Never>? = nil) async -> Walkthrough.Step? {
            onBeatStart?()
            if case .write? = beat.annotation { Owl.shared.set(.writing) } else if Owl.shared.state != .listening { Owl.shared.set(.idle) }
            var step: Walkthrough.Step?
            var near: CGPoint?
            if let drawn {
                // Already on screen; the step just needs this beat's sentence.
                if let (point, _) = await drawn.value { near = point }
                if let (_, s) = await drawn.value, let s {
                    step = Walkthrough.Step(center: s.center, radius: s.radius, label: s.label, hover: s.hover,
                                            display: s.display, sentence: beat.text, armedAt: Date())
                    step?.quiz = s.quiz
                }
            } else if let a = beat.annotation {
                let shot = Self.shot(a.screen, in: shots)
                drewWithTrace = false
                if let (point, s) = await draw(a, shot: shot, sentence: beat.text) {
                    if !drewWithTrace { light.fly(to: point, clear: s?.radius ?? 16) }   // a traced mark already has the nib on it
                    step = s
                    near = point
                }
                // The mark leads its words: they start just after the pen touches down.
                let lead = min(0.9, strokeStarts.timeIntervalSinceNow + 0.12)
                if drewWithTrace, lead > 0 { await wait(lead) }
            }
            // Taken early (or superseded), or the reply broke off: this answer's remaining words are stale.
            guard t.gen == generation(), !t.failed else { return nil }
            if beat.annotation != nil { caption.floatIfCovering() }
            if !beat.text.isEmpty {
                t.shown += (t.shown.isEmpty ? "" : " ") + beat.text
                beatsPlaying = true
                lastSentence = beat.text
                t.sentences += 1
                // Like subtitles: the pane shows what is being said now, the previous sentence
                // faded above it. From the third sentence the answer moves into the notch,
                // if that wouldn't cover the work.
                if t.sentences >= 3, !caption.isDocked { caption.dockIfClear() }
                let named = beat.annotation?.label.map { $0.split(separator: " ").map(String.init) } ?? []
                let bound = quantities.colour(named: beat.annotation?.label)
                // A tour: the light glides to each anchored control as its word lights.
                if beat.stops.isEmpty {
                    caption.onWordLit = nil
                } else {
                    let shot = Self.shot(beat.annotation?.screen ?? TagParser.cursorScreen, in: shots), stops = beat.stops
                    caption.onWordLit = { [weak self] i in
                        guard let self, let s = stops.first(where: { $0.word == i }) else { return }
                        trace("Tour: word \(i), light to \(Int(s.point.x)),\(Int(s.point.y))")
                        self.light.glide(to: shot.global(Tutor.clamp(s.point, in: shot.pixelSize)))
                    }
                }
                // A practice question with nothing drawn keeps the pane where it was.
                let stay = step?.quiz == true || (beat.practice && beat.annotation == nil)
                // Say how to answer: a click on screen, or (the answer line opens once the reply ends) typed.
                caption.practiceHow = step?.quiz == true ? "click it on screen" : nil
                let practice = beat.practice || step?.quiz == true
                if speak {
                    caption.say(beat.text, named: named, at: anchor, near: near, colour: bound, practice: practice, stay: stay)
                } else {
                    caption.read(beat.text, named: named, at: anchor, near: near, wordsPerSecond: t.wordsPerSecond, colour: bound,
                                 practice: practice, stay: stay, pauses: Set(beat.stops.map(\.word)))
                    // Time to read it (and for the pen to finish) before the next beat.
                    let words = beat.text.split(separator: " ").count
                    let readUntil = Date().addingTimeInterval(Tutor.readingTime(words: words)
                        + Double(beat.stops.count) * Tokens.shared.caption.tourPause)
                    let left = max(readUntil, traceEnds).timeIntervalSinceNow
                    if left > 0 { await wait(left) }
                }
                trace("Beat: \(beat.annotation.map { "\($0)" } ?? "(no drawing)") → \"\(beat.text)\"", content: true)
                if speak, let voice {
                    light.set(.speaking)
                    let started = Date()
                    await voice.speak(beat.text)
                    caption.voiceDone()
                    trace(String(format: "Spoke beat in %.1fs", Date().timeIntervalSince(started)))
                }
            }
            if beat.annotation != nil { t.drawings += 1 }
            return step
        }

        // MARK: Drawing

        /// Where a target's ring goes and how far round it a click counts: moved onto the
        /// control if snapping is on, else left where asked with the ring hugging the
        /// control under it (clicks anywhere on that control count).
        @MainActor
        func targetPlace(_ asked: CGPoint, radius: CGFloat, on screen: ScreenID) async -> (center: CGPoint, radius: CGFloat, outline: CGRect?) {
            let found = await ui.snap(asked, on: screen, app: frontApp())
            if settings.snap, let rect = found {
                return (CGPoint(x: rect.midX, y: rect.midY), max(radius, hypot(rect.width, rect.height) / 2 + 6), rect)
            }
            guard let rect = Tutor.outline(found, around: asked, radius: radius) else { return (asked, radius, nil) }
            let far = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
                .map { hypot($0.x - asked.x, $0.y - asked.y) }.max() ?? 0
            return (asked, max(radius, far + 2), rect)
        }

        /// Draws an annotation; returns the global point the light should go to,
        /// and the lesson step if it is a TARGET, HOVER or QUIZ.
        @MainActor
        public func draw(_ a: Annotation, shot: any Shell.Screenshot, sentence: String) async -> (CGPoint, Walkthrough.Step?)? {
            guard screens.frame(of: shot.screenID) != nil else { return nil }
            let screen = shot.screenID
            // One meaning, one colour: in an explanation each named thing keeps its colour
            // across its mark, its label, the light, the caption word and formula letters.
            let lightPage = shot.lightness(near: Tutor.spot(of: a)) > 0.55
            let colour = quantities.colour(for: a, lightPage: lightPage)
            overlay.setInk(colour, letters: quantities.letters(lightPage: lightPage), on: screen)
            if quantities.on, let colour { light.glow(quantities.colour(named: a.label) ?? colour) }
            // Snapping (off by default: the eval found it loses more hits than it saves).
            let snapOn = settings.snap, app = frontApp()
            func snapped(_ g: CGPoint) async -> CGRect? {
                snapOn ? await ui.snap(g, on: screen, app: app) : nil
            }
            func global(_ p: CGPoint) -> CGPoint { shot.global(Tutor.clamp(p, in: shot.pixelSize)) }

            switch a {
            case .open(let target, let app):
                guard errandsThisReply.opens < Self.opensPerReply else {
                    trace("Not opening \(target): this reply has opened enough.", content: true)
                    return nil
                }
                errandsThisReply.opens += 1
                if let problem = actions?.open(target, with: app) {
                    trace("Couldn't open \(target): \(problem)", content: true)
                } else {
                    trace("Opened \(target)\(app.map { " in \($0)" } ?? "")", content: true)
                    opened.append(target + (app.map { " in \($0)" } ?? ""))
                    // A file opened in a lesson belongs to it, and goes with its bookmark.
                    if let l = lesson, target.hasPrefix("/") || target.hasPrefix("~"), !l.files.contains(target) { l.files.append(target) }
                    errandUntil = Date().addingTimeInterval(Tutor.errandSettle)
                }
                return nil
            case .demo(let pts, let label, _):
                let g = pts.map(global)
                overlay.drawDemo(g, label: label, on: screen, delay: 0)
                return (g.last ?? .zero, nil)
            case .download(let url):
                // One offer at a time: the shell has one offer row, and a second would replace
                // the first with its answer never coming.
                guard errandsThisReply.downloads < Self.downloadsPerReply, !downloadPending else {
                    trace("Not offering \(url): \(downloadPending ? "an offer is still waiting for an answer" : "this reply has offered one already").", content: true)
                    return nil
                }
                errandsThisReply.downloads += 1
                downloadPending = true
                let asked = questionsAsked
                actions?.offerDownload(url) { [weak self] path, problem in
                    guard let self else { return }
                    self.downloadPending = false
                    // A download that lands after they've asked something new doesn't cut into it;
                    // the lesson's own follow-up turns still carry on from it.
                    guard asked == self.questionsAsked else { trace("Download finished after a new question: not carrying on."); return }
                    if let path { self.carryOn(Tutor.downloadedEvent(path)) }
                    else if let problem { trace("Download of \(url) didn't happen: \(problem)", content: true) }
                }
                return nil
            case .quiz(let p, let r, let label, _):
                // A practice question: nothing drawn and Navi doesn't move towards it, so
                // the answer isn't given away. The click is graded when it comes.
                let g = global(p)
                light.tint(.step)
                var step = Walkthrough.Step(center: g, radius: Walkthrough.Step.radius(image: r, scale: shot.scale), label: label ?? "the answer",
                                            hover: false, display: screen, sentence: sentence, armedAt: Date())
                step.quiz = true
                drewWithTrace = true   // so the caller doesn't fly Navi to it
                return (screens.pointerLocation(), step)

            case .point(let p, let label, _):
                var g = global(p)
                let rect = await snapped(g)
                if let rect { g = CGPoint(x: rect.midX, y: rect.midY) }
                overlay.drawPoint(g, label: label, snapped: rect, on: screen, delay: 0)
                return (g, nil)

            case .target(let p, let r, let label, _), .hover(let p, let r, let label, _):
                let hover: Bool
                if case .hover = a { hover = true } else { hover = false }
                let asked = global(p)
                let place = await targetPlace(asked, radius: Walkthrough.Step.radius(image: r, scale: shot.scale), on: screen)
                // Drawn already, the moment the reply named it (`armEarly`).
                if earlyTarget != asked {
                    overlay.drawTarget(place.center, radius: place.radius, label: label, snapped: place.outline, hover: hover, on: screen, delay: 0)
                }
                light.tint(.step)
                let step = Walkthrough.Step(center: place.center, radius: place.radius, label: label ?? "the target", hover: hover,
                                            display: screen, sentence: sentence, armedAt: Date())
                return (place.center, step)

            case .highlight(let r, let label, _):
                let a = global(CGPoint(x: r.minX, y: r.minY))
                let b = global(CGPoint(x: r.maxX, y: r.maxY))
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: max(1, abs(b.x - a.x)), height: max(1, abs(b.y - a.y)))
                // The light draws the outline itself, then the area fills in.
                let e = rect.insetBy(dx: -5, dy: -5)
                // Same corner order as the overlay draws it, so ink and light move together.
                // A line of text: the light runs along it as the highlighter sweeps behind.
                let wait = Tutor.highlightIsLine(rect)
                    ? traceStroke([CGPoint(x: e.minX, y: rect.midY), CGPoint(x: e.maxX, y: rect.midY)], on: screen)
                    : traceStroke([CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.maxX, y: e.maxY),
                                   CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.minX, y: e.minY)], on: screen)
                overlay.drawHighlight(rect, label: label, on: screen, delay: wait)
                light.roam(in: rect)
                return (CGPoint(x: rect.midX, y: rect.midY), nil)

            case .write(let p, let text, _):
                let asked = global(p)
                // The next step of working written where the last one is transforms it in
                // place; the pen hovers just above while the terms move.
                if let line = overlay.transformWrite(at: asked, to: text, on: screen) {
                    drewWithTrace = false
                    return (CGPoint(x: line.midX - 16, y: line.maxY + 26), nil)
                }
                let g = overlay.writeSpot(text, at: asked, on: screen)
                // The words come from the light's tip as it writes along the line.
                let width = overlay.writingWidth(text)
                let wait = traceStroke([CGPoint(x: g.x, y: g.y - 20), CGPoint(x: g.x + width, y: g.y - 20)], on: screen)
                overlay.write(text, at: g, anchor: asked, on: screen, delay: wait)
                return (CGPoint(x: g.x + width, y: g.y - 20), nil)

            case .shape(.circle, let pts, let label, let n) where Tutor.ringLooksLikeSize(pts, in: shot.pixelSize):
                // A ring wider than a third of the screen almost always means the model
                // wrote a width and height where the edge point goes: draw that box instead.
                let c = pts[0], size = pts[1]
                let box = CGRect(x: c.x - size.x / 2, y: c.y - size.y / 2, width: size.x, height: size.y)
                trace("Ring read as a \(Int(size.x))×\(Int(size.y)) box")
                return await draw(.highlight(box, label: label, screen: n), shot: shot, sentence: sentence)

            case .shape(let kind, let pts, let label, _):
                let points = pts.map(global)
                let wait = traceStroke(Sketch.polyline(kind, points, sketchy: false), on: screen)
                overlay.drawShape(kind, points, label: label, on: screen, delay: wait)
                // The eye goes to a circle's centre and an arrow's tip.
                let focus = kind == .circle ? points[0] : kind == .arrow ? points[points.count - 1]
                    : CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                return (focus, nil)
            }
        }

        /// The light glides to the start of a stroke and travels along it; the ink is
        /// timed to follow right behind. Returns the delay before the ink starts.
        private func traceStroke(_ pts: [CGPoint], on screen: ScreenID) -> TimeInterval {
            drewWithTrace = settings.buddy && pts.count > 1
            guard drewWithTrace else { overlay.setStrokeTime(0.5, on: screen); return 0 }
            let stroke = light.traceTime(pts)
            overlay.setStrokeTime(stroke, on: screen)
            let wait = light.trace(pts)
            traceEnds = Date().addingTimeInterval(wait + stroke)
            strokeStarts = Date().addingTimeInterval(wait)
            return wait
        }
    }
}
