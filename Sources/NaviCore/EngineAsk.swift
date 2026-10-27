import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The engine's half of asking: what a question means for the topic and the
/// lesson, building the turn, and keeping the topic afterwards. The shell
/// supplies the screenshots, the app's context and the user's own marks.
extension Tutor.Engine {
    /// A question, and how to get what goes with it.
    public struct Asking {
        public var question: String
        /// Typed from a paused lesson's card: it carries the lesson on.
        public var fromCard: Bool
        /// Where the pointer was: status lines start near it.
        public var anchor: CGPoint
        /// The screens: grabbed when typing began (quicker), or now.
        public var screenshots: () async throws -> [any Shell.Screenshot]
        /// The app's description and web host: read when typing began, or now.
        public var context: () async -> (text: String?, host: String?)
        /// The user's own marks (a pointer gesture, Mark mode), drawn into the screenshots and described.
        public var marks: (([any Shell.Screenshot]) async -> Marked)?

        public init(question: String, fromCard: Bool, anchor: CGPoint,
                    screenshots: @escaping () async throws -> [any Shell.Screenshot],
                    context: @escaping () async -> (text: String?, host: String?),
                    marks: (([any Shell.Screenshot]) async -> Marked)? = nil) {
            (self.question, self.fromCard, self.anchor, self.screenshots, self.context, self.marks) =
                (question, fromCard, anchor, screenshots, context, marks)
        }
    }

    /// Screenshots with the user's marks drawn in, and what to tell Claude about them.
    public struct Marked {
        public var shots: [any Shell.Screenshot]
        /// The marks in words (the turn's gesture line).
        public var note: String?
        /// Further notes, such as the controls under a gesture.
        public var extras: [String]
        /// Close-ups of each mark, sent just before the question.
        public var closeUps: [[String: Any]]
        public init(shots: [any Shell.Screenshot], note: String?, extras: [String] = [], closeUps: [[String: Any]] = []) {
            (self.shots, self.note, self.extras, self.closeUps) = (shots, note, extras, closeUps)
        }
    }

    // MARK: Asking

    public func ask(_ a: Asking) {
        errandLooks = 0
        questionsAsked += 1
        lastAsking = a
        let offerBookmarks = !skipBookmarks
        skipBookmarks = false
        let question = a.question
        hidePause()
        light.summon()
        // After a correction the light moves and draws a little more carefully for a while.
        light.confidence = Tutor.confidence(after: question, was: light.confidence)
        turn?.cancel()
        voice?.stop()
        host?.showWorking("Looking…", at: a.anchor)
        Owl.shared.set(.thinking)
        light.set(.thinking)
        host?.setEscape(true)

        // Carry on a lesson only when the user says to; anything else is a new question.
        // "Let me try" carries on too, but they do the steps from now on.
        topicPill?.hide()
        if Tutor.wantsFresh(question) { clearTopic() }
        tryFirst = Tutor.tryFirst(after: question, was: tryFirst)
        if let l = lesson, !Tutor.carriesOnLesson(question, stale: l.isStale, fromCard: a.fromCard) { endLesson(clear: false) }
        disarmAll()   // scroll and typing steps too (M35)
        trace("Ask: \(question)", content: true)

        let gen = bump()
        turn = Task { @MainActor in
            do {
                // No password field is ever read: the core refuses here too, so
                // no shell can send a screenshot taken while one has focus (decision 16).
                if self.ui.passwordFieldFocused { throw PasswordFieldFocused() }
                var shots = try await a.screenshots()
                var gesture: String?
                var extras: [String] = []
                var closeUps: [[String: Any]] = []
                if let mark = a.marks {
                    let marked = await mark(shots)
                    shots = marked.shots
                    gesture = marked.note
                    extras = marked.extras
                    closeUps = marked.closeUps
                }
                let t0 = Date()
                var ctx = await a.context()
                ctx.text = ctx.text.map { Redact.secrets(in: $0) }   // selected text, a document's start (decision 3)
                trace(String(format: "Ask prep: waited %.2fs for app context", Date().timeIntervalSince(t0)))
                let app = self.frontApp()
                // A conversation picked up again (after a break, or a restart) still knows its topic.
                if self.topic == nil { self.topic = self.conversation?.topic }
                let afterBreak = self.conversation?.isAfterBreak == true
                let carriedTopic = self.topic
                extras += Tutor.extras(notes: Skills.context(bundleID: app?.bundleID, appName: app?.name, host: ctx.host, version: self.ui.version(of: app)),
                                       recentMoves: self.practiceMoves, tryFirst: self.tryFirst, topic: self.topic)
                // Outside a lesson, Claude sees the lessons kept from before and picks one up if this carries it on.
                if self.lesson == nil, offerBookmarks, let note = self.bookmarks.promptNote() { extras.append(note) }
                // The conversation's files go with every question; if this turns into a lesson, they're the lesson's too.
                let given = self.conversation?.files ?? self.pendingFiles
                if self.conversation == nil { self.pendingFiles = [] }
                if !given.isEmpty { extras.append(Tutor.givenFilesNote(given)) }
                let openDocument = Tutor.openDocument(in: ctx.text)

                let message: String
                if let l = self.lesson {
                    l.touch()
                    message = l.message(event: Tutor.saidEvent(question))
                } else {
                    message = question
                }
                guard gen == self.generation() else { return }
                var content = Prompt.turn(shots: shots, context: ctx.text, gesture: gesture, message: message, extras: extras)
                if !closeUps.isEmpty { content.insert(contentsOf: closeUps, at: content.count - 1) }
                let explain = self.lesson == nil && Tutor.wantsExplanation(question)
                self.light.tint(explain ? .idea : .ink)
                try await self.runTurn(content, shots: shots, goal: self.lesson?.goal ?? question, anchor: a.anchor, gen: gen,
                                       explain: explain, kind: self.lesson == nil ? .question(question) : .lessonStep,
                                       asked: question)
                if let l = self.lesson { for f in given where !l.files.contains(f) { l.files.append(f) } }
                guard gen == self.generation() else { return }
                self.afterAnswer(afterBreak: afterBreak, carriedTopic: carriedTopic, openDocument: openDocument)
            } catch is CancellationError {
            } catch {
                guard gen == self.generation() else { return }
                self.watch?.stopActWatch()   // a later click mustn't start a turn for this one (M36)
                self.host?.fail(error, at: a.anchor)
            }
        }
    }

    // MARK: Looking at the screen

    /// A fresh look at the screen for a lesson turn. Never while a password field has
    /// focus: the look is refused and the user told why.
    func captureScreens() async throws -> [any Shell.Screenshot] {
        if ui.passwordFieldFocused { throw PasswordFieldFocused() }
        return try await screens.captureAll()
    }

    public struct PasswordFieldFocused: LocalizedError {
        public var errorDescription: String? { "A password field is focused, so I won't look at your screen." }
    }

    // MARK: The topic

    /// The pill's words: the topic, and the step for a lesson.
    public var pillText: String? {
        Tutor.pillText(topic: topic ?? conversation?.topic, stepsTaken: lesson?.stepsTaken, of: lesson?.outline.count, files: conversation?.files.count ?? 0)
    }

    /// Ends the conversation: the next question starts fresh, with no topic, recap or files.
    public func clearTopic() {
        guard topic != nil || topicPill?.isShown == true || conversation?.isEmpty == false else { return }
        trace("Conversation ended: the next question starts fresh.")
        topic = nil
        topicTimer?.invalidate()
        topicPill?.hide()
        pendingFiles = []
        conversation?.end()
    }

    /// After an answer: the topic is the conversation's until it ends; the pill shows for a while.
    func keepTopic(_ reply: String, question: Bool) {
        material = question ? TagParser.material(reply) : nil
        // A kept lesson just picked up keeps its own name unless the reply gives a new one.
        topic = Tutor.topic(after: reply, question: question, current: topic) ?? (lesson?.bookmarkID != nil ? lesson?.title : nil) ?? topic
        if let topic { conversation?.topic = topic }
        topicTimer?.invalidate()
        guard let topic else { topicPill?.hide(); return }
        trace("Topic: \(topic)", content: true)
        topicTimer = Timer.scheduledTimer(withTimeInterval: Conversation.followUpWindow, repeats: false) { [weak self] _ in
            guard let self, self.lesson?.armed == nil else { return }
            self.topicPill?.hide()
        }
    }

    /// After an answer to a question: say it's carrying on after a long break (with Start
    /// fresh), or offer the document they have open for the rest of the conversation.
    /// One link at most, and never over a step waiting to be taken.
    func afterAnswer(afterBreak: Bool, carriedTopic: String?, openDocument: String?) {
        guard lesson?.armed == nil, let c = conversation else { return }
        if afterBreak, let t = carriedTopic, topic == t {
            caption.setKicker("CARRYING ON · " + t.uppercased())
            caption.link("Start fresh") { [weak self] in
                guard let self, let a = self.lastAsking else { return }
                trace("Start fresh after a break: asking again in a new conversation.")
                self.clearTopic()
                self.ask(a)
            }
            return
        }
        guard settings.readFiles else { return }
        if let doc = openDocument, !c.files.contains(doc), !c.offered.contains(doc) {
            c.markOffered(doc)
            let name = (doc as NSString).lastPathComponent
            caption.link("Use \(name) for this conversation") { [weak self] in
                guard let self else { return }
                self.conversation?.addFiles([doc])
                self.caption.setKicker("ADDED · " + name.uppercased())
                trace("Open document added to the conversation.", content: true)
            }
            return
        }
        // The answer needed something of theirs: offer to add it, once for each thing.
        guard let what = material, !c.offered.contains("material:" + what.lowercased()) else { return }
        c.markOffered("material:" + what.lowercased())
        caption.link(Tutor.materialLink(what)) { [weak self] in
            trace("Material offer taken.")
            self?.host?.chooseFiles()
        }
    }

    /// The same question three times running: a rare grumpy look, as a wink.
    func noteRepeat(_ q: String) {
        if repeats.note(q) { Owl.shared.react(.grumpy, for: 2.5) }
    }
}
