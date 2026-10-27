import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Prompt {
    /// One turn's content from any shell's screenshots.
    public static func turn(shots: [any Shell.Screenshot], context: String?, gesture: String?, message: String,
                            extras: [String] = []) -> [[String: Any]] {
        let screens = shots.compactMap { shot in
            shot.jpeg().map { Screen(index: shot.index, hasCursor: shot.hasCursor, width: Int(shot.pixelSize.width),
                                     height: Int(shot.pixelSize.height), jpeg: $0) }
        }
        return turn(screens: screens, displays: shots.count, context: context, gesture: gesture, message: message, extras: extras)
    }
}

/// The engine's half of a turn and of a lesson: running a turn end to end, arming
/// steps, judging clicks, looking again, pausing and ending. The shell watches
/// (clicks, keys, windows, scrolls) and reports here; the engine decides.
extension Tutor.Engine {
    var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// Starts a new generation: anything still running for an older one goes quiet.
    @discardableResult
    public func bump() -> Int {
        currentGeneration += 1
        return currentGeneration
    }

    // MARK: A whole turn

    /// Sends one turn and plays the reply as beats while it streams in, then takes the
    /// lesson's next move: arm the step, pause for work the app can't see, or finish.
    @MainActor
    public func runTurn(_ content: [[String: Any]], shots: [any Shell.Screenshot], goal: String, anchor: CGPoint, gen: Int,
                        explain: Bool = false, kind: Conversation.Kind = .lessonStep, asked: String? = nil,
                        learns: Bool = false, site: String? = nil) async throws {
        earlyTarget = nil
        // A new question puts away an offer still waiting (its answer will never come);
        // a lesson's own follow-up turns leave it be.
        if case .question = kind { actions?.cancelOffer() }
        actExpiry?.cancel()
        opened = []
        // A new question starts afresh: an offer left unanswered no longer holds the next one back.
        if case .question = kind { downloadPending = false }
        scrollStep = nil
        scrollSeeking = nil
        scrollStarted = nil
        typeStep = nil
        typedWork?.cancel()
        overlay.clearAll()
        host?.showWorking("Looking…", at: anchor)
        Owl.shared.set(.thinking)
        light.set(.thinking)
        let speak = host?.prepareTurn() ?? false

        stepReply = ""
        // A question may pick up a kept lesson: as soon as the reply says so, it's that lesson again.
        if case .question = kind, lesson == nil { onPartial = { [weak self] in self?.adoptBookmark(from: $0) } } else { onPartial = nil }
        onEarlyStep = { [weak self] partial in self?.stepReply = partial; self?.armEarly(partial, shots: shots, goal: goal) }
        onReply = { [weak self] reply in
            guard let self else { return }
            self.stepReply = reply
            if case .question = kind { self.adoptBookmark(from: reply) }
            self.armEarly(reply, shots: shots, goal: goal)
            // Things to keep (a command to copy, a note, a reminder) are kept as the reply lands,
            // only on a turn the user asked, and a note or reminder only when they asked for one.
            for k in TagParser.parse(reply).keeps {
                guard Tutor.mayKeep(k, asked: asked) else {
                    trace("Not kept (\(k.kind.rawValue)): \(asked == nil ? "Navi's own follow-up turn" : "the user didn't ask for one")")
                    continue
                }
                self.actions?.keep(k) { [weak self] said, problem in
                    if let said {
                        trace("Kept (\(k.kind.rawValue)): \(said)", content: true)
                        if k.kind == .copy { self?.caption.setKicker(k.copiedKicker) }
                    } else { trace("Couldn't keep (\(k.kind.rawValue)): \(problem ?? "?")") }
                }
            }
            var inLesson = self.lesson != nil
            if case .lessonStep = kind { inLesson = true }
            self.armActEarly(reply, inLesson: inLesson, goal: goal)
            self.practiceMoves.note(reply)
            if case .question(let q) = kind {
                self.keepTopic(reply, question: true)
                self.noteRepeat(q)
            } else {
                self.keepTopic(reply, question: false)
            }
            if let tone = TagParser.mood(reply) { Owl.shared.tone(tone) }
            if learns { self.learn(from: reply, host: site) }
        }
        guard let played = try await playTurn(content, shots: shots, anchor: anchor, gen: gen, explain: explain,
                                              kind: kind, speak: speak) else { return }
        let shown = played.shown
        var step = played.step
        // In a lesson, "click …" marked with a POINT is a step all the same: arm it, so the
        // click moves things on instead of waiting on the card.
        if step == nil, lesson != nil, Tutor.asksToClick(shown),
           case .point(let p, let label, let n)? = TagParser.parse(played.reply).annotations.last(where: { if case .point = $0 { return true }; return false }) {
            let shot = Self.shot(n, in: shots)
            let asked = shot.global(Tutor.clamp(p, in: shot.pixelSize))
            let place = await targetPlace(asked, radius: Walkthrough.Step.radius(image: 74, scale: shot.scale), on: shot.screenID)
            overlay.drawTarget(place.center, radius: place.radius, label: label, snapped: place.outline, hover: false, on: shot.screenID, delay: 0)
            trace("A click marked with POINT: armed as a step.")
            step = Walkthrough.Step(center: place.center, radius: place.radius, label: label ?? "the target", hover: false,
                                    display: shot.screenID, sentence: shown, armedAt: Date())
        }

        light.set(.idle)
        let parsed = TagParser.parse(played.reply)
        var inLesson = lesson != nil
        if case .lessonStep = kind { inLesson = true }
        let next = Tutor.afterAnswer(hasStep: step != nil, stepsLeft: lesson?.stepsLeft ?? Walkthrough.maxSteps,
                                     drew: parsed.annotations.contains { !$0.isAction }, said: shown, inLesson: inLesson)
        // A step's instruction stays until it's taken: they'll move towards it.
        caption.answerDone(holdUntilStep: next == .armStep || next == .waitForScroll || next == .waitForTyping)
        beatsPlaying = false
        host?.answerShown(played, shots: shots, anchor: anchor)
        // It ended on a practice question to answer in words: the answer line opens for it,
        // and the question stays up while they think and type.
        let answerWanted = step == nil && TagParser.beats(played.reply).last?.practice == true && !speak
        if answerWanted { caption.takeAnswer(); trace("Practice: the answer line is open.") }

        // The lesson: arm the step, keep a paused lesson for "continue", or finish.
        switch next {
        case .armStep:
            guard let step else { break }
            if lesson == nil { lesson = Walkthrough(goal: goal) }
            arm(step)
            watch?.rememberLook(of: step, in: shots)
            if !step.quiz {
                light.fly(to: step.center, clear: step.radius)   // waits beside the step until it's taken
                // Say plainly that it's their move, and what it is.
                caption.setKicker("YOUR MOVE · " + (step.hover ? "REST THE POINTER ON " : "CLICK ") + step.label.uppercased())
            }
        case .waitForContinue:
            // A manual-work step: pause the lesson until they say "continue".
            if lesson == nil { lesson = Walkthrough(goal: goal) }
            lesson?.record("Was shown a manual step: \(shown.prefix(120))")
            trace("Lesson paused for \"continue\".")
            // Instead of having to say "continue": the card offers "I did it".
            if let pid = frontApp()?.pid, pid != ownPID { lessonApp = pid }
            showPause(kicker: "When you're ready", text: shown, on: screens.screenUnderPointer())
        case .waitForScroll:
            // Their move is a scroll: it moves on when they scroll the app, so no "continue".
            // Only for a while: reading-scrolls later don't count.
            if lesson == nil { lesson = Walkthrough(goal: goal) }
            if let pid = frontApp()?.pid, pid != ownPID { lessonApp = pid }
            let display = scrollStep?.display ?? screens.screenUnderPointer()
            lessonScreen = display
            // Usually armed already, when the reply arrived; the window runs from now.
            scrollStep = (Date().addingTimeInterval(Tutor.scrollWindow), display)
            if scrollSeeking == nil { scrollSeeking = Tutor.scrollTarget(shown) }
            expireAct(after: Tutor.scrollWindow, text: shown, display: display)
            host?.setEscape(true)
            caption.setKicker("YOUR MOVE · SCROLL" + (scrollSeeking.map { " TO " + $0.uppercased() } ?? ""))
            trace("Scroll step: waiting up to \(Int(Tutor.scrollWindow))s for a scroll.")
        case .waitForTyping:
            // Their move is typing: once they've typed in the lesson's app and paused, look again.
            if lesson == nil { lesson = Walkthrough(goal: goal) }
            if let pid = frontApp()?.pid, pid != ownPID { lessonApp = pid }
            let display = typeStep?.display ?? screens.screenUnderPointer()
            lessonScreen = display
            typeStep = (Date().addingTimeInterval(Tutor.scrollWindow * 2), display)
            expireAct(after: Tutor.scrollWindow * 2, text: shown, display: display)
            host?.setEscape(true)
            caption.setKicker("YOUR MOVE · TYPE IT IN")
            trace("Typing step: waiting for them to type.")
        case .finish where !opened.isEmpty && errandLooks < Tutor.errandChain:
            break   // it opened something to carry on from: the look below continues the lesson
        case .finish:
            if let l = lesson {
                trace("Lesson finished.")
                if Tutor.celebrates(stepsTaken: l.stepsTaken) { Owl.shared.react(.celebrate, for: 2.2) }
            }
            endLesson(clear: false, finished: true)
        case .carryOn:
            // Past the step limit a reply that still gives a step can't be armed: the lesson
            // ends here rather than hanging on a ring nothing answers; its marks stay as an answer.
            if step != nil, lesson != nil {
                trace("A step past the limit: ending the lesson.")
                endLesson(clear: false)
            }
        }
        // The lesson's plan and name, for the pill and for keeping it if it's put down.
        if let l = lesson {
            if let o = TagParser.outline(played.reply) { l.outline = o }
            if let topic { l.title = topic }
        }
        host?.turnFinished(played, speak: speak, answerWanted: answerWanted, gen: gen)
        // It opened a page or file and stopped there: look at what opened and carry on.
        if !opened.isEmpty, step == nil, next != .waitForScroll, next != .waitForTyping, next != .waitForContinue {
            let things = opened
            opened = []
            carryOn(Tutor.openedEvent(things))
        }
    }

    /// A step can be clicked as soon as the reply arrives, not only once the
    /// sentences before it have been read: someone who knows where it is
    /// shouldn't have to wait (a quick click used to go unnoticed).
    func armEarly(_ reply: String, shots: [any Shell.Screenshot], goal: String) {
        guard (lesson?.stepsLeft ?? Walkthrough.maxSteps) > 0, lesson?.armed == nil else { return }
        for a in TagParser.parse(reply).annotations {
            let p: CGPoint, r: CGFloat, label: String?, hover: Bool
            switch a {
            case .target(let pp, let rr, let l, _): (p, r, label, hover) = (pp, rr, l, false)
            case .hover(let pp, let rr, let l, _): (p, r, label, hover) = (pp, rr, l, true)
            default: continue
            }
            let shot = Self.shot(a.screen, in: shots)
            let step = Walkthrough.Step(center: shot.global(Tutor.clamp(p, in: shot.pixelSize)), radius: Walkthrough.Step.radius(image: r, scale: shot.scale),
                                        label: label ?? "the next step", hover: hover, display: shot.screenID, sentence: "", armedAt: Date())
            if lesson == nil { lesson = Walkthrough(goal: goal) }
            arm(step)
            watch?.rememberLook(of: step, in: shots)
            trace("Armed early: \"\(step.label)\" can be clicked before its sentence is read.")
            // And drawn at once, not when its sentence comes round: the ring is up as soon
            // as the reply names it (the light still goes there at its beat).
            earlyTarget = step.center
            Task { @MainActor in
                let place = await self.targetPlace(step.center, radius: step.radius, on: step.display)
                guard self.lesson?.armed?.center == step.center, self.earlyTarget == step.center else { return }
                self.overlay.setInk(nil, letters: [:], on: step.display)
                self.overlay.drawTarget(place.center, radius: place.radius, label: label, snapped: place.outline, hover: hover,
                                        on: step.display, delay: 0)
            }
            return
        }
    }

    // MARK: Steps

    public func arm(_ step: Walkthrough.Step) {
        Owl.shared.set(.pointing)
        disarmStep()
        // A click step replaces any scroll or typing step from the same reply.
        scrollStep = nil
        typeStep = nil
        actExpiry?.cancel()
        lesson?.armed = step
        host?.setEscape(true)
        hoverRest = Walkthrough.HoverRest()
        expiry = Timer.scheduledTimer(withTimeInterval: Walkthrough.idleLimit, repeats: false) { [weak self] _ in self?.endLesson(clear: true) }
        if let app = frontApp(), app.pid != ownPID { lessonApp = app.pid; lesson?.app = app }
        lessonScreen = step.display
        stepLabel = step.label
        watch?.watch(step)
        trace("Armed \(step.quiz ? "QUIZ" : step.hover ? "HOVER" : "TARGET") \"\(step.label)\" r=\(Int(step.radius))pt (step \((lesson?.stepsTaken ?? 0) + 1))", content: true)
    }

    /// A click anywhere while a step is armed.
    public func stepClicked(at p: CGPoint, clicks: Int = 1) {
        guard let s = lesson?.armed else { return }
        // A double-click step: the first click only selects, so wait for the double-click.
        if clicks < 2, Tutor.asksToDoubleClick(stepReply), s.judge(click: p, graceUntil: nil) == .hit {
            trace("A single click on a double-click step: waiting for the double-click.")
            return
        }
        let owner = ui.windowOwner(at: p)
        trace("Click at \(Int(p.x)),\(Int(p.y)) on pid \(owner.map { String($0) } ?? "none") (lesson app \(lessonApp.map { String($0) } ?? "none")) with \"\(s.label)\" armed", content: true)
        switch s.judge(click: p, graceUntil: graceUntil) {
        case .hit where s.quiz: advance(s, hovered: false, quiz: true)
        case .miss where s.quiz: advance(s, hovered: false, quiz: false)
        case .hit: advance(s, hovered: false)
        case .ignore: break
        case .miss:
            // Judge by the screen, not the click: they may have done it another way.
            let onLessonScreen = (screens.frame(of: s.display) ?? screens.frame(of: screens.screenUnderPointer()))?.contains(p) ?? false
            switch Tutor.reaction(to: .miss, inLessonApp: owner != nil && owner == lessonApp,
                                  onLessonScreen: onLessonScreen, paused: lessonPaused, looks: looksThisStep) {
            case .look:
                if lookAgain(Tutor.missEvent(s.label), why: "clicked elsewhere in the app") { looksThisStep += 1; Owl.shared.react(.confused) }
            case .pause: pauseLesson(why: "clicked in another app")
            case .ignore: trace("Clicked elsewhere again: staying on the step (look limit or another display).")
            }
        case .expired:
            trace("Step expired: ending the lesson.")
            endLesson(clear: true)
        }
    }

    /// Where the pointer is, sampled while a HOVER step is armed.
    public func hoverSample(at p: CGPoint) {
        guard let s = lesson?.armed, s.hover else { return }
        if hoverRest.sample(p, on: s) { advance(s, hovered: true) }
    }

    /// A window appeared over the armed step: a fresh look, within the look limit.
    public func dialogAppeared(_ window: String) {
        guard let s = lesson?.armed else { return }
        guard !lessonPaused, looksThisStep < Tutor.maxLooks else {
            trace("Not looking again for the window: look limit or paused.")
            return
        }
        if lookAgain(Tutor.dialogEvent(s.label, window: window), why: "a window appeared over the step") { looksThisStep += 1 }
    }

    /// `quiz`: the answer to a practice question ([QUIZ]), right (true) or not (false).
    public func advance(_ s: Walkthrough.Step, hovered: Bool, actedAgain: Bool = false, quiz: Bool? = nil, event override: String? = nil) {
        guard let lesson else { return }
        if !actedAgain {
            errandLooks = 0   // a step taken: errands may chain again
            trace("Step taken: \(hovered ? "hovered" : "clicked") \"\(s.label)\"\(quiz.map { $0 ? " (right answer)" : " (not the answer)" } ?? "")", content: true)
            disarmStep()
            looksThisStep = 0
            errandLooks = 0   // they've taken a step by hand: errands may chain again from here
            Owl.shared.react(quiz == false ? .confused : .happy)
            graceUntil = Date().addingTimeInterval(1.4)
            lesson.record(Tutor.stepLog(s.label, hovered: hovered, quiz: quiz))
        }
        // While the follow-up is worked out, a further click means the screen has moved
        // on: the request in flight is replaced with a fresh look (once per step).
        watch?.stopActWatch()
        if !actedAgain {
            watch?.watchForActing { [weak self] in
                guard let self, Date() > (self.graceUntil ?? .distantPast), self.lesson != nil else { return }
                trace("They acted again while it was thinking: replacing the request with a fresh look.")
                self.watch?.stopActWatch()
                self.turn?.cancel()
                self.advance(s, hovered: hovered, actedAgain: true, event: override)
            }
        }
        if actedAgain { overlay.clearSteps() } else { overlay.stepTaken() }
        let anchor = screens.pointerLocation()
        host?.showWorking("Got it…", at: anchor)
        light.set(.thinking)
        voice?.stop()
        let gen = bump()
        let bundle = lessonApp.flatMap { ui.bundleID(of: $0) }
        turn?.cancel()   // whatever was still being worked out is superseded by this
        turn = Task { @MainActor in
            do {
                // Wait for the screen to settle and, in a browser, for the page to finish loading.
                // A slow app gets longer: up to 10 s, starting longer if it was slow last time.
                var t0 = Date()
                // A double-click opens something (a file, a disk image) that can take a moment to appear.
                if Tutor.asksToDoubleClick(self.stepReply) { try await Task.sleep(nanoseconds: 800_000_000) }
                let first = Tutor.settleTimeout(remembered: bundle.flatMap { self.slowSettles[$0] })
                if !(await self.screens.waitForSettle(s.display, timeout: first)), !Task.isCancelled, first < Tutor.settleMost {
                    trace(String(format: "Still changing after %.0fs: waiting up to %.0fs.", first, Tutor.settleMost))
                    Owl.shared.set(.thinking)
                    _ = await self.screens.waitForSettle(s.display, timeout: Tutor.settleMost - Date().timeIntervalSince(t0))
                }
                let settled = Date().timeIntervalSince(t0)
                if let bundle, !Task.isCancelled { self.slowSettles[bundle] = Tutor.rememberedSettle(took: settled) }
                self.host?.refreshFrontApp()
                t0 = Date()
                if let app = self.frontApp(), self.ui.isBrowser(app) {
                    let deadline = Date().addingTimeInterval(10)
                    var loaded = false
                    while Date() < deadline, await self.ui.pageLoading(pid: app.pid) {
                        loaded = true
                        try await Task.sleep(nanoseconds: 300_000_000)
                    }
                    if loaded { _ = await self.screens.waitForSettle(s.display, timeout: 2) }
                }
                let loading = Date().timeIntervalSince(t0)
                guard gen == self.generation() else { return }
                t0 = Date()
                let shots = try await self.captureScreens()
                let captured = Date().timeIntervalSince(t0)
                t0 = Date()
                let (context, host) = await self.readContext()
                trace(String(format: "Step prep: settle %.2fs, page load %.2fs, capture %.2fs, context %.2fs",
                             settled, loading, captured, Date().timeIntervalSince(t0)))
                var event = override ?? quiz.map { Tutor.quizEvent(s.label, right: $0) } ?? Tutor.stepEvent(s.label, hovered: hovered, step: lesson.stepsTaken)
                if actedAgain { event += Tutor.actedAgainNote }
                // A target they clicked or rested on: this look can see whether it worked, so it may teach a skill.
                let learns = override == nil && quiz == nil
                let content = Prompt.turn(shots: shots, context: context, gesture: nil, message: lesson.message(event: event, learn: learns),
                                          extras: self.extras(host: host))
                try await self.runTurn(content, shots: shots, goal: lesson.goal, anchor: anchor, gen: gen, learns: learns, site: host)
            } catch is CancellationError {
            } catch {
                if gen == self.generation() { self.turnFailed(error, at: anchor) }
            }
        }
    }

    /// A lesson's look went wrong: say so. A look refused for a password field leaves the
    /// lesson on its card, so "I did it" carries it on once the field is done with.
    func turnFailed(_ error: Error, at anchor: CGPoint) {
        watch?.stopActWatch()   // the turn is over: a later click mustn't start a surprise one (M36)
        host?.fail(error, at: anchor)
        if error is PasswordFieldFocused, lesson != nil, !lessonPaused {
            showPause(kicker: stepLabel.map { "Paused · \($0)" } ?? "Paused", text: lastSentence, on: screens.screenUnderPointer())
        }
    }

    /// The app's description for the prompt (if context is on), with secrets redacted, and its web host.
    @MainActor
    func readContext() async -> (text: String?, host: String?) {
        guard settings.context else { return (nil, nil) }
        let ctx = await ui.context(for: frontApp())
        return (ctx.text.map { Redact.secrets(in: $0) }, ctx.host)   // selected text, a document's start (decision 3)
    }

    /// The skills, recent practice moves and "trying it themselves" for a lesson turn.
    func extras(host: String?) -> [String] {
        let app = frontApp()
        var out = Tutor.extras(notes: Skills.context(bundleID: app?.bundleID, appName: app?.name, host: host, version: ui.version(of: app)),
                               recentMoves: practiceMoves, tryFirst: tryFirst)
        if let files = conversation?.files, !files.isEmpty { out.append(Tutor.givenFilesNote(files)) }
        return out
    }

    /// What a step taught, kept as a skill for the app (or the site, in a browser). Only on the
    /// look after a step they took, which shows whether it worked; a quiet kicker says so.
    func learn(from reply: String, host: String?) {
        let facts = TagParser.skills(reply)
        guard !facts.isEmpty, let app = frontApp(), app.pid != ownPID, host != nil || !ui.isBrowser(app) else { return }
        let kept = Skills.learn(facts, appName: app.name, bundleID: app.bundleID, version: ui.version(of: app), host: host)
        for f in kept { trace("Learned (\(host ?? app.name ?? "?")): \(f.task): \(f.how)", content: true) }
        if kept.count < facts.count { trace("Skills: \(facts.count - kept.count) not kept (failed the check).") }
        if let f = kept.first { caption.setKicker("NAVI LEARNED · " + f.task.uppercased()) }
    }

    public func disarmStep() {
        watch?.stopWatching()
        expiry?.invalidate()
        expiry = nil
        lesson?.armed = nil
    }

    /// Disarms everything waiting on the user: the click step, a scroll or typing step and
    /// their timers, and the "they acted again" watch. For a new question, and for a shell
    /// stopping the current answer before a new press: a scroll in the lesson's app while the
    /// next question is being typed mustn't take a stale step and replace the question (M35).
    public func disarmAll() {
        disarmStep()
        scrollStep = nil
        scrollSeeking = nil
        scrollStarted = nil
        typeStep = nil
        typedWork?.cancel()
        typedWork = nil
        actExpiry?.cancel()
        watch?.stopActWatch()
    }

    /// After an errand (a page or file opened, a download saved): wait for it to appear,
    /// then a fresh look so Claude carries on from the new screen. At most
    /// `Tutor.errandChain` in a row before it waits for the user again.
    public func carryOn(_ event: String) {
        guard errandLooks < Tutor.errandChain else { trace("Errand chain at its limit: waiting for them."); return }
        errandLooks += 1
        let anchor = screens.pointerLocation()
        host?.showWorking("Looking…", at: anchor)
        light.set(.thinking)
        let gen = bump()
        let display = screens.screenUnderPointer()
        turn?.cancel()   // whatever was still being worked out is superseded by this
        turn = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)   // the page or app takes a moment to come forward
                _ = await self.screens.waitForSettle(display, timeout: 4)
                self.host?.refreshFrontApp()
                if let app = self.frontApp(), self.ui.isBrowser(app) {
                    let deadline = Date().addingTimeInterval(8)
                    while Date() < deadline, await self.ui.pageLoading(pid: app.pid) { try await Task.sleep(nanoseconds: 300_000_000) }
                    _ = await self.screens.waitForSettle(display, timeout: 2)
                }
                guard gen == self.generation() else { return }
                let shots = try await self.captureScreens()
                let (context, host) = await self.readContext()
                let message = self.lesson?.message(event: event) ?? "Just now: " + event
                let content = Prompt.turn(shots: shots, context: context, gesture: nil, message: message, extras: self.extras(host: host))
                trace("Carrying on after an errand (\(self.errandLooks) of \(Tutor.errandChain)).")
                // Outside a lesson the look is still part of the answer, not a lesson step: it
                // mustn't leave a "When you're ready" card or start a lesson whose goal is this note.
                try await self.runTurn(content, shots: shots, goal: self.lesson?.goal ?? event, anchor: anchor, gen: gen,
                                       kind: self.lesson == nil ? .question(event) : .lessonStep)
            } catch is CancellationError {
            } catch {
                if gen == self.generation() { self.turnFailed(error, at: anchor) }
            }
        }
    }

    /// A scroll or typing step is watched from the moment its reply arrives, not once
    /// its sentences have been read: they often act while Navi is still talking.
    func armActEarly(_ reply: String, inLesson: Bool, goal: String) {
        guard inLesson, scrollStep == nil, typeStep == nil, (lesson?.stepsLeft ?? Walkthrough.maxSteps) > 0 else { return }
        let parsed = TagParser.parse(reply)
        guard !parsed.annotations.contains(where: \.isStep) else { return }
        let scroll = Tutor.asksToScroll(parsed.text), type = !scroll && Tutor.asksToType(parsed.text)
        guard scroll || type else { return }
        if lesson == nil { lesson = Walkthrough(goal: goal) }
        if let pid = frontApp()?.pid, pid != ownPID { lessonApp = pid }
        let display = screens.screenUnderPointer()
        lessonScreen = display
        // Long enough to cover the reading as well as the doing.
        let until = Date().addingTimeInterval(Tutor.scrollWindow * 2)
        expireAct(after: until.timeIntervalSinceNow, text: parsed.text, display: display)
        if scroll {
            scrollStep = (until, display)
            scrolledBy = 0
            scrollSeeking = Tutor.scrollTarget(parsed.text)
            scrollStarted = nil
        } else { typeStep = (until, display) }
        trace("\(scroll ? "Scroll" : "Typing") step armed as the reply arrived.")
    }

    /// A scroll or typing step that runs out of time doesn't leave them stuck: it waits on
    /// the card ("I did it", "Show me again") like any step Navi can't see.
    func expireAct(after seconds: TimeInterval, text: String, display: ScreenID) {
        actExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.scrollStep != nil || self.typeStep != nil, self.lesson != nil else { return }
            trace("Scroll or typing step timed out: waiting on the card.")
            self.scrollStep = nil
            self.typeStep = nil
            self.showPause(kicker: "When you're ready", text: text, on: display)
        }
        actExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds), execute: work)
    }

    /// They scrolled during a scroll step: once the scrolling stops, move on as for a step.
    /// The scrolling paused. If Navi knows what they're scrolling to, it reads the screen:
    /// there → move on; not yet → wait quietly (no asking Claude mid-search), unless they've
    /// gone a long way or a long time without finding it.
    func scrollPaused() {
        guard let step = scrollStep else { return }
        guard let seeking = scrollSeeking else { return scrollStepTaken(found: nil) }
        let started = scrollStarted ?? Date()
        Task { @MainActor in
            let found = await self.ui.screenShows(seeking, on: step.display)
            // Taken, ended or re-armed meanwhile: a reading of the old screen doesn't take a newer step.
            guard let now = self.scrollStep, now.until == step.until, now.display == step.display else { return }
            if found == false, self.scrolledBy < Tutor.scrollGiveUp, Date().timeIntervalSince(started) < Tutor.scrollPatience {
                trace("Scrolled, but \"\(seeking)\" isn't in view yet: waiting quietly.", content: true)
                self.caption.setKicker("KEEP SCROLLING · " + seeking.uppercased())
                return
            }
            trace(found == true ? "\"\(seeking)\" is in view: moving on." : "Scroll step: asking again (\(found == nil ? "can't read the screen" : "not found after a long scroll")).", content: true)
            self.scrollStepTaken(found: found == true ? seeking : nil)
        }
    }

    func scrollStepTaken(found: String? = nil) {
        guard let (_, display) = scrollStep else { return }
        scrollStep = nil
        scrollSeeking = nil
        scrollStarted = nil
        scrolledBy = 0
        trace("Scroll step taken: moving on once it settles.")
        let s = Walkthrough.Step(center: screens.pointerLocation(), radius: 0, label: "the scroll", hover: false,
                                 display: display, sentence: "", armedAt: Date())
        advance(s, hovered: false, event: found.map(Tutor.scrolledToEvent) ?? Tutor.scrollStepEvent)
    }

    /// A key was pressed in `pid` (only the timing is used, never the key). During a typing
    /// step in the lesson's app, it moves on once the typing pauses, or soon after Return.
    public func typed(returnKey: Bool, pid: Int32?) {
        guard let step = typeStep else { return }
        guard Date() < step.until else { typeStep = nil; return }
        // Typing into Navi itself never counts; with no lesson app known yet (Navi's own
        // window was in front when the reply arrived), typing in the app in front does.
        guard let pid, pid != ownPID, lessonApp == nil || pid == lessonApp else { return }
        typedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let (_, display) = self.typeStep else { return }
            self.typeStep = nil
            self.typedWork = nil
            trace("Typing step taken: moving on once it settles.")
            let s = Walkthrough.Step(center: self.screens.pointerLocation(), radius: 0, label: "the typing", hover: false,
                                     display: display, sentence: "", armedAt: Date())
            self.advance(s, hovered: false, event: Tutor.typeStepEvent)
        }
        typedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (returnKey ? 0.3 : Tutor.typingPause), execute: work)
    }

    /// Ends the lesson. One put down partway is kept as a bookmark (returned); a finished
    /// one closes the bookmark it came from.
    @discardableResult
    public func endLesson(clear: Bool, finished: Bool = false) -> Bookmark? {
        let kept = lesson.flatMap { settleBookmark($0, finished: finished) }
        watch?.stopActWatch()   // no lesson to carry on: a later click starts nothing (M36)
        typeStep = nil
        typedWork?.cancel()
        scrollStep = nil
        disarmStep()
        lesson = nil
        hidePause()
        lessonApp = nil
        lessonScreen = nil
        stepLabel = nil
        looksThisStep = 0
        pendingLookEvent = nil
        host?.lessonEnded()
        if clear { host?.clearScreen() }
        return kept
    }

    // MARK: Away and back

    /// A fresh screenshot and the lesson's next move: the step again, or the next one.
    /// Not while a request to Claude is in flight: a fresh look would only collide
    /// with it (and its answer already sees the new screen).
    @discardableResult
    public func lookAgain(_ event: String, why: String, status: String = "Looking again…") -> Bool {
        guard let lesson, !lookPending else { return false }
        if waitingForReply {
            trace("Not looking again (\(why)): a request is already on its way.")
            return false
        }
        trace("Looking again (\(why)).")
        lookPending = true
        pendingLookEvent = nil
        hidePause()
        let screen = lesson.armed?.display ?? lessonScreen ?? screens.screenUnderPointer()
        disarmStep()
        overlay.clearSteps()
        let anchor = screens.pointerLocation()
        light.summon()
        light.set(.thinking)
        host?.showWorking(status, at: anchor)
        host?.setEscape(true)
        let gen = bump()
        turn?.cancel()   // whatever was still being worked out is superseded by this
        turn = Task { @MainActor in
            defer { self.lookPending = false }
            do {
                _ = await self.screens.waitForSettle(screen, timeout: 3)
                guard gen == self.generation() else { return }
                self.host?.refreshFrontApp()
                let shots = try await self.captureScreens()
                let (context, host) = await self.readContext()
                let content = Prompt.turn(shots: shots, context: context, gesture: nil, message: lesson.message(event: event),
                                          extras: self.extras(host: host))
                try await self.runTurn(content, shots: shots, goal: lesson.goal, anchor: anchor, gen: gen)
            } catch is CancellationError {
            } catch {
                if gen == self.generation() { self.turnFailed(error, at: anchor) }
            }
        }
        return true
    }

    /// They've stepped away: stop the rest of the answer, put the marks away, and
    /// leave the step on a card they can click to carry on.
    public func pauseLesson(why: String) {
        guard let lesson, !lessonPaused else { return }
        let label = lesson.armed?.label ?? stepLabel
        var sentence = lesson.armed?.sentence ?? lastSentence
        // A step armed as its tag arrived has no sentence yet: the card shows the reply's words so far.
        if sentence.isEmpty { sentence = TagParser.parse(stepReply).text }
        if sentence.isEmpty { sentence = lastSentence }
        let screen = lesson.armed?.display ?? lessonScreen ?? screens.screenUnderPointer()
        trace("Lesson paused (\(why)).")
        disarmStep()
        watch?.stopActWatch()
        turn?.cancel()
        bump()
        beatsPlaying = false
        overlay.clearSteps()
        overlay.fadeDrawings()
        caption.hide()
        light.set(.idle)
        light.comeBack()
        showPause(kicker: label.map { "Paused · \($0)" } ?? "Paused", text: sentence, on: screen)
    }

    public func showPause(kicker: String, text: String, on screen: ScreenID) {
        lessonPaused = true
        topicPill?.hide()
        pauseCard?.show(kicker: kicker, text: text, on: screen)
        pauseExpiry?.invalidate()
        pauseExpiry = Timer.scheduledTimer(withTimeInterval: Walkthrough.idleLimit, repeats: false) { [weak self] _ in
            trace("Paused lesson forgotten after \(Int(Walkthrough.idleLimit / 60)) minutes.")
            self?.endLesson(clear: true)
        }
    }

    public func hidePause() {
        lessonPaused = false
        pauseExpiry?.invalidate()
        pauseExpiry = nil
        pauseCard?.hide()
    }

    public func pauseChoice(_ c: Shell.PauseChoice) {
        trace("Paused card: \(c.title).")
        let label = stepLabel ?? "the last step"
        let event: String
        switch c {
        case .stop:
            if let kept = endLesson(clear: true) {
                announceKept(kept)
                host?.restSoon(after: 8)
            } else {
                host?.restSoon(after: 1)
            }
            return
        case .didIt: event = Tutor.didItEvent(label)
        case .showAgain: event = Tutor.showAgainEvent(label); lesson?.stuck(on: label)
        case .stuck: event = Tutor.stuckEvent(label); lesson?.stuck(on: label)
        }
        // Look at the lesson's app, not whatever they wandered off to.
        if let pid = lessonApp, ui.frontmostPID() != pid {
            pendingLookEvent = event
            // Answer the click at once: the card goes and Navi says it's looking, while
            // the lesson's app comes forward (the lesson stays paused until the look starts).
            pauseCard?.hide()
            host?.showWorking("Looking again…", at: screens.pointerLocation())
            ui.activate(pid: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.lessonPaused, let e = self.pendingLookEvent else { return }
                self.lookAgain(e, why: c.title)
            }
        } else {
            lookAgain(event, why: c.title)
        }
    }

    /// No lesson, but they've moved on mid-answer: stop the rest rather than keep going.
    public func stopPlayback(_ why: String) {
        trace("Stopped the rest of the answer (\(why)).")
        turn?.cancel()
        bump()
        beatsPlaying = false
        caption.hide()
        light.set(.idle)
    }

    // MARK: Kept lessons

    /// Keeps a lesson put down partway (or updates its bookmark); closes the bookmark of one
    /// that's finished. Returns what was kept.
    func settleBookmark(_ l: Walkthrough, finished: Bool) -> Bookmark? {
        if finished {
            if let id = l.bookmarkID {
                bookmarks.remove(id)
                trace("Kept lesson finished: its bookmark is closed.")
            }
            return nil
        }
        guard l.worthKeeping else { return nil }
        if l.title == nil { l.title = topic }
        var next = l.armed?.sentence ?? ""
        if next.isEmpty { next = TagParser.parse(stepReply).text }
        if next.isEmpty, let stepLabel { next = stepLabel }
        let b = l.bookmark(next: next.isEmpty ? nil : String(next.prefix(200)), existing: l.bookmarkID.flatMap(bookmarks.get))
        l.bookmarkID = b.id
        bookmarks.keep(b)
        trace("Lesson kept to pick up later: \(b.title), \(b.progress).", content: true)
        return b
    }

    /// A reply that starts [RESUME:id] picks that kept lesson up: it's the lesson from here,
    /// and the caption says so, with a way out.
    func adoptBookmark(from reply: String) {
        guard let id = TagParser.resume(reply), lesson?.bookmarkID != id, let b = bookmarks.get(id) else { return }
        // Only over a lesson that's just begun (a step armed from this same reply), never one under way.
        if let l = lesson, l.stepsTaken > 0 || l.bookmarkID != nil { return }
        let l = Walkthrough(resuming: b)
        l.armed = lesson?.armed
        lesson = l
        topic = b.title
        var used = b
        used.sessions += 1
        used.lastUsed = Date()
        bookmarks.keep(used)
        trace("Picked up a kept lesson: \(b.title), \(b.progress).", content: true)
        caption.setKicker("PICKING UP · " + b.title.uppercased())
        caption.link("Start fresh instead") { [weak self] in self?.startFreshInstead() }
    }

    /// "Start fresh instead": the lesson stays kept, and the question is asked again without it.
    func startFreshInstead() {
        trace("Start fresh instead: asking again without the kept lesson.")
        caption.endLink()
        endLesson(clear: true)
        clearTopic()
        guard let a = lastAsking else { return }
        skipBookmarks = true
        ask(a)
    }

    /// Picks a kept lesson up from the menu or History: its app forward, then a fresh look.
    public func resume(_ id: String) {
        guard let b = bookmarks.get(id) else { return }
        trace("Picking up \(b.title) from the menu.", content: true)
        endLesson(clear: true)
        let l = Walkthrough(resuming: b)
        lesson = l
        topic = b.title
        var used = b
        used.sessions += 1
        used.lastUsed = Date()
        bookmarks.keep(used)
        let look = { [weak self] in _ = self?.lookAgain(Tutor.resumeEvent, why: "picking up \(b.title)", status: "Picking up \(b.title)…") }
        // Its app first, if it isn't in front: opened like an errand, so it coming forward doesn't count as moving on.
        let front = frontApp()
        let inFront = (b.bundleID != nil && front?.bundleID == b.bundleID) || (b.app != nil && front?.name == b.app)
        if let name = b.app, !inFront, actions?.open(name, with: nil) == nil {
            errandUntil = Date().addingTimeInterval(Tutor.errandSettle)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: look)
        } else {
            look()
        }
    }

    /// A short note in the caption by the pointer, outside any answer.
    func note(kicker: String, _ text: String) {
        light.summon()
        caption.setKicker(kicker)
        caption.read(text, named: [], at: screens.pointerLocation(), near: nil,
                     wordsPerSecond: 40, colour: nil, practice: false, stay: true, pauses: [])
        caption.answerDone(holdUntilStep: false)
    }

    /// After "Stop" on the paused card: says the lesson's kept, with "Don't keep this".
    func announceKept(_ b: Bookmark) {
        note(kicker: "KEPT · " + b.title.uppercased(), "We stopped at \(b.progress). Ask about it any time and we'll carry on.")
        caption.link("Don't keep this") { [weak self] in
            self?.bookmarks.remove(b.id)
            trace("Kept lesson dropped: \(b.title).", content: true)
            self?.caption.hide()
        }
    }

    // MARK: Attaching files

    /// Where given files go: this conversation (and the lesson going now, if any), or a kept lesson.
    public enum AttachTarget: Equatable { case current, kept(String) }

    /// Adds files (or folders) to the conversation, so every question lists them for Claude
    /// to read, and to the lesson going now so its bookmark keeps them. The shell has
    /// already refused secrets. `announce`: say so in the caption.
    public func attach(_ paths: [String], to target: AttachTarget, announce: Bool = true) {
        guard !paths.isEmpty else { return }
        let what = Tutor.filesInWords(paths)
        var kicker: String, text: String
        switch target {
        case .current:
            if let c = conversation { c.addFiles(paths) } else { for p in paths where !pendingFiles.contains(p) { pendingFiles.append(p) } }
            if let l = lesson {
                for p in paths where !l.files.contains(p) { l.files.append(p) }
                if l.bookmarkID != nil { _ = settleBookmark(l, finished: false) }   // the bookmark has them too
            }
            kicker = "ADDED TO · " + (lesson?.title ?? topic ?? "this conversation").uppercased()
            text = lesson != nil ? "Added \(what). I'll use it as we go." : "Added \(what) to this conversation. Ask me about it."
        case .kept(let id):
            guard var b = bookmarks.get(id) else { return }
            for p in paths where !b.files.contains(p) { b.files.append(p) }
            b.lastUsed = Date()
            bookmarks.keep(b)
            kicker = "ADDED TO · " + b.title.uppercased()
            text = "Added \(what). It'll be there when we carry on."
        }
        trace("Attached \(paths.count) file(s) to \(target).", content: true)
        if !settings.readFiles { text += " Turn on Let Claude look at your \(Platform.current.computer) in Settings so I can read it." }
        if announce { note(kicker: kicker, text) }
    }
}
