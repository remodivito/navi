import AppKit
import Carbon.HIToolbox

/// Ties it together. Hold the shortcut and talk (marking things with the
/// pointer if you like), then let go: the reply plays as beats, each one a
/// drawing plus the sentence spoken while it is up, with the companion cursor
/// flying to it. "How do I…" questions become lessons: one TARGET at a time,
/// advancing when you click it. Tap the shortcut to type instead; double-tap
/// it to talk hands-free; hold ⌃⌥D to dictate into the focused field.
/// Everything here runs on the main thread.
final class AppController: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private var overlays: OverlayManager!
    private var menuBar: MenuBar!
    private let panel = PromptPanel()
    private let recorder = ShortcutRecorder()
    private let gesture = GestureTracker()
    private lazy var transcriber: Transcriber = Voice.make()
    private let narrator = Narrator()
    private var buddy: Buddy!
    private var onboarding: OnboardingWindow?
    private var setupGuide: SetupGuide?

    private let cli = CLIBackend()
    private let api = APIBackend()
    /// What each turn carries: fresh for a new topic, a recap and the newest screen otherwise.
    private let conversation = Conversation()
    /// Set by the test harness to play a canned reply instead of calling Claude.
    var fake: ChatBackend?
    private var backend: ChatBackend { fake ?? (settings.backend == .api ? api : cli) }

    private var hotkey: Hotkey?
    private var dictationKey: Hotkey?
    private var escKey: Hotkey?

    // The current press.
    private var pressedAt: Date?
    private var shotsTask: Task<[ScreenShot], Error>?
    private var contextTask: Task<AX.FrontContext, Never>?
    /// When `shotsTask` was started: a pre-capture is only "the screen now" for a little while.
    private var shotsAt = Date.distantPast
    private var frontApp: NSRunningApplication?
    private var listenTask: Task<Void, Never>?
    private var listening = false
    private var pendingGesture: [NSPoint]?
    /// Bumped by every press, Esc and cancel: a release still flushing the voice is ignored.
    private var pressGen = 0
    private var lastTap: Date?
    private var doubleTapping = false

    // The current answer. Bumping `generation` drops callbacks from an older turn.
    private var turn: Task<Void, Never>? { get { engine.turn } set { engine.turn = newValue } }
    private var generation: Int { engine.currentGeneration }
    private var clearTimer: Timer?
    /// Navi's words, riding beside it.
    private let caption = Caption()

    // Teaching.
    private var lesson: Walkthrough? { get { engine.lesson } set { engine.lesson = newValue } }
    // A lesson that waits when they step away, and looks again when they're back.
    private let pauseCard = PauseCard()
    /// Opening, keeping and downloading for the engine; Esc cancels a download (decision 13).
    private lazy var errands = MacErrands(caption: caption)

    // MARK: A sign-in of Navi's own

    /// Navi gets its own long-lived Claude Code token (`claude setup-token`, about a
    /// year, on the user's plan), kept in Navi's Keychain entry. Then it never shares
    /// the sign-in the Claude app and other sessions refresh, which kept getting lost.
    func keepSignedIn() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep Navi signed in"
        alert.informativeText = "Your browser will open so you can approve a sign-in just for Navi. It uses your Claude plan, "
            + "lasts about a year, stays in your Keychain, and other Claude apps can't log it out."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Paste a token instead…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn: return pasteToken()
        default: return
        }
        let at = NSEvent.mouseLocation
        Owl.shared.set(.thinking)
        showBubble("Approve Navi's sign-in in your browser…", at: at, style: .status)
        SignIn.run { [weak self] result in
            guard let self else { return }
            Owl.shared.set(.idle)
            switch result {
            case .success(let token):
                // Only "signed in" once the Keychain really has it (an unsigned build, a locked or refused Keychain).
                guard Keychain.setClaudeToken(token) else {
                    trace("Sign-in: the Keychain wouldn't save the token.")
                    Owl.shared.react(.sorry, for: 3)
                    self.showBubble(Self.keychainRefused, at: at, style: .status)
                    self.scheduleClear(after: 8)
                    return
                }
                trace("Sign-in: saved Navi's own token.")
                self.cli.reset()
                MainActor.assumeIsolated { Connection.shared.refresh() }
                Owl.shared.react(.happy, for: 2)
                self.showBubble("Navi has its own sign-in now, good for about a year.", at: at, style: .status)
                self.scheduleClear(after: 5)
            case .failure(let f):
                trace("Sign-in: no token (\(Redact.secrets(in: String(describing: f)))).")
                self.hideBubble()
                self.pasteToken(note: "Navi couldn't pick the token up by itself. Run claude setup-token in Terminal and paste what it prints.")
            }
        }
    }

    /// The fallback: run `claude setup-token` yourself and paste the token.
    private func pasteToken(note: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Paste the token here"
        while true {
            let alert = NSAlert()
            alert.messageText = "Keep Navi signed in"
            alert.informativeText = (note.map { $0 + "\n\n" } ?? "")
                + "1. In Terminal, run:  claude setup-token\n2. Approve it in your browser.\n3. Paste the token it prints below."
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Copy the command")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { continue }
                guard Keychain.setClaudeToken(token) else {
                    trace("Sign-in: the Keychain wouldn't save the pasted token.")
                    let failed = NSAlert()
                    failed.messageText = "Navi couldn't keep the token"
                    failed.informativeText = Self.keychainRefused
                    failed.runModal()
                    return
                }
                trace("Saved Navi's own Claude Code token.")
                cli.reset()
                MainActor.assumeIsolated { Connection.shared.refresh() }
                return
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("claude setup-token", forType: .string)
                continue
            default:
                return
            }
        }
    }

    static let keychainRefused = "macOS wouldn't save the token in your Keychain, so Navi isn't signed in with it. "
        + "If a Keychain prompt appeared, choose Allow and try again."

    func removeOwnSignIn() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove Navi's own sign-in?"
        alert.informativeText = "Navi will go back to using the Claude Code sign-in it shares with other Claude apps."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Keychain.removeClaudeToken()
        trace("Removed Navi's own Claude Code token.")
        cli.reset()
        MainActor.assumeIsolated { Connection.shared.refresh() }
    }

    // MARK: Topic
    /// The topic lives in the engine; the pill is the Mac's.
    private let topicPill = TopicPill()
    /// The pill's words: the topic, and the step for a lesson.
    var topicPillText: String? { engine.pillText }

    // MARK: Mark mode

    let markMode = MarkMode()
    private var panelOpenedAt = Date.distantPast

    /// Draw on the screen to show what you mean; the type bar waits for the question.
    func startMarking() {
        if !panel.isVisible { typeNow() }
        topicPill.hide()
        markMode.begin()
    }

    /// Navi is working on the next thing. If an answer is showing it stays up,
    /// dimmed, with the owl thinking; otherwise a status says what's happening.
    // The wait's status line (Tutor.WaitLine): what's up, a line waiting its turn, and "Still thinking…".
    private var waitLine = Tutor.WaitLine()
    private var waitWork: DispatchWorkItem?
    private var stillWork: DispatchWorkItem?

    /// Puts a line of the wait up now, or once the current one has had its time.
    private func wantWaitLine(_ line: String) {
        guard !engine.beatsPlaying, engine.waitingForReply else { return }
        switch waitLine.want(line, at: Date()) {
        case .show:
            showWorking(line, at: NSEvent.mouseLocation)
        case .later(let delay):
            waitWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let next = self.waitLine.waiting else { return }
                self.wantWaitLine(next)
            }
            waitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .ignore:
            break
        }
    }

    private func endWait() {
        waitLine.end()
        waitWork?.cancel()
        stillWork?.cancel()
    }

    func showWorking(_ status: String, at anchor: NSPoint) {
        waitLine.shown(status, at: Date())
        clearTimer?.invalidate()
        Owl.shared.set(.thinking)
        refreshEscape()   // a new turn: any scroll or typing step from before is gone
        if caption.awaitNext() { return }
        showBubble(status, at: anchor, style: .status)
    }




    /// The pill shows once the answer has cleared, while nothing else is at the top of the screen.
    private func showTopicPill() {
        guard let text = topicPillText, !caption.isShowing, !pauseCard.isShown, !panel.isVisible else { return }
        topicPill.show(text, on: Capture.screenUnderMouse())
    }
    // The lesson's state lives in the engine (NaviCore).
    private var lessonApp: pid_t? { engine.lessonApp }
    private var stepLabel: String? { engine.stepLabel }
    private var lessonPaused: Bool { engine.lessonPaused }
    private var lookPending: Bool { engine.lookPending }
    private var typingIntoLesson = false
    /// While an answer's sentences are still appearing, and the latest one.
    private var beatsPlaying: Bool { get { engine.beatsPlaying } set { engine.beatsPlaying = newValue } }
    private var lastSentence: String { get { engine.lastSentence } set { engine.lastSentence = newValue } }
    private var stepMonitor: Any?
    private var stepTimer: Timer?
    private var graceUntil: Date? { get { engine.graceUntil } set { engine.graceUntil = newValue } }
    private var actWatch: Any?

    /// Whether the last question was spoken. Typed questions don't get the
    /// "muted, so answering in text" notice: text is what they expect.
    private var askedByVoice = false
    private var mutedNoticeShown = false
    private var lastAnswer = ""
    private lazy var mutedNotice: MutedNotice = {
        let n = MutedNotice()
        n.onUnmute = { [weak self] in
            Audio.unmute()
            // Say the answer that was just silenced.
            guard let self, !self.lastAnswer.isEmpty else { return }
            Task { @MainActor in await self.narrator.speak(self.lastAnswer) }
        }
        return n
    }()

    // Hands-free conversation.
    private var handsFree = false
    private var autoListen: Task<Void, Never>?

    // Dictation.
    private var dictating = false

    // Screen changes under the drawing.
    private var gestureBegan = Date.distantPast
    private var answerStarted = Date.distantPast

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        HistoryWindow.onResume = { [weak self] id in self?.resumeLesson(id) }
        // The conversation is kept between launches (text only), so a restart loses nothing.
        conversation.store = NaviFiles.support.appendingPathComponent("conversation.json")
        ConnectClaude.onConnected = { [weak self] in self?.cli.reset() }
        HistoryWindow.onAttach = { [weak self] urls, id in self?.attach(urls, to: .kept(id), announce: false) }
        // One companion at a time. The installed app wins: a second copy of it quits,
        // and test copies (the bare debug binary) give way to it.
        let isApp = Bundle.main.bundlePath.hasSuffix(".app")
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != getpid()
                && ([Bundle.main.bundleIdentifier, CarryOver.oldIdentifier].contains($0.bundleIdentifier)
                    || ["ScreenPointer", "Navi"].contains($0.executableURL?.lastPathComponent ?? ""))
        }
        let otherApps = others.filter { $0.bundleURL?.pathExtension == "app" }
        // Scripted test runs (--demo-…, --fake-reply) may run next to the real app during development.
        let scriptedTest = CommandLine.arguments.contains { $0.hasPrefix("--demo-") || $0 == "--fake-reply" || $0 == "--stress" || $0 == "--gallery" || $0 == "--history-sample" }
        if !isApp && !scriptedTest && !others.isEmpty || isApp && !otherApps.isEmpty {
            trace("Another Navi is already running, so this copy is quitting.")
            NSApp.terminate(nil)
            return
        }


        overlays = OverlayManager()
        overlays.onDisplaysChanged = { [weak self] changed in self?.displaysChanged(changed) }
        buddy = Buddy()
        menuBar = MenuBar(app: self)
        registerHotkey()
        fn.onPress = { [weak self] in self?.hotkeyDown() }
        fn.onRelease = { [weak self] in self?.hotkeyUp() }
        fn.onCancel = { [weak self] in self?.cancelPress() }
        fn.holdTalks = settings.fnKey
        if settings.fnKey { fn.start() }
        tapTrigger.mode = TapTrigger.Mode(rawValue: settings.typeTrigger) ?? .rightOption
        tapTrigger.onTrigger = { [weak self] in self?.typeNow() }
        tapTrigger.start()
        dictationKey = Hotkey(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey) { [weak self] down in
            down ? self?.dictateDown() : self?.dictateUp()
        }
        panel.onSubmit = { [weak self] q in
            guard let self else { return }
            let marks = self.markMode.marks
            self.markMode.finish()
            self.ask(q.isEmpty && !marks.isEmpty ? "Explain what I marked." : q, marks: marks)
        }
        panel.onMark = { [weak self] in self?.startMarking() }
        markMode.onChange = { [weak self] marks in self?.panel.setMarks(marks) }
        markMode.onDone = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refocusBar()
        }
        panel.onCancel = { [weak self] in
            guard let self else { return }
            // Typing from a paused lesson's card: closing the field keeps the lesson.
            if self.typingIntoLesson { self.typingIntoLesson = false; return }
            self.escape()
        }
        pauseCard.onChoose = { [weak self] c in self?.engine.pauseChoice(c) }
        // A practice answer, typed under the question, goes back as their reply.
        caption.onAnswer = { [weak self] text in
            self?.caption.endAnswer()
            self?.ask(text)
        }
        caption.onHelp = { [weak self] help in
            self?.caption.endAnswer()
            switch help {
            case .hint: self?.ask("Give me a hint for this one, but don't tell me the answer yet.")
            case .showMe: self?.ask("Show me the answer and how to get there.")
            }
        }
        caption.onAnswerCancel = { [weak self] in self?.escape() }
        topicPill.onClear = { [weak self] in self?.engine.clearTopic() }
        topicPill.onOpen = { [weak self] in self?.typeNow() }
        panel.onClearTopic = { [weak self] in self?.engine.clearTopic() }
        panel.onAttach = { [weak self] in self?.chooseFiles() }
        panel.onDropFiles = { [weak self] urls in
            guard let self else { return }
            self.attach(urls, to: .current, announce: false, openTyping: false)
            self.panel.showTopic(self.topicPillText)
        }
        pauseCard.onType = { [weak self] in
            guard let self else { return }
            self.typingIntoLesson = true
            self.panel.show(on: Capture.screenUnderMouse(), markedSomething: false, topic: self.topicPillText, app: self.frontApp?.localizedName)
        }
        narrator.onWord = { [weak self] word in
            self?.buddy.pulse()
            self?.caption.spoke(word)
        }
        caption.keepClear = { [weak self] in (self?.overlays.occupied() ?? []) + (self?.markMode.marks.map { $0.rect.insetBy(dx: -14, dy: -14) } ?? []) }
        caption.bloom = { [weak self] in
            guard let buddy = self?.buddy, let p = buddy.tip else { return nil }
            return (p, buddy.tintColor)
        }
        if settings.speak, Narrator.kokoroVoice != nil { KokoroVoice.shared.load() }
        buddy.onMove = { [weak self] p, moving in
            self?.caption.nudge()
            guard let self, !Buddy.reduceMotion else { return }
            for v in self.overlays.views { v.trail(at: .zero, on: false) }
            if moving, let (view, local) = self.overlays.locate(p) { view.trail(at: local, on: true) }
        }
        watchScreenChanges()
        buddy.setEnabled(settings.buddy)
        if settings.buddy && !settings.naviAlways { buddy.rest() }   // present when needed
        // Test runs (gallery, stress, demos) never start `claude`: extra processes starting
        // together can race to refresh the shared Claude Code sign-in and lose it.
        let scripted = CommandLine.arguments.contains { $0.hasPrefix("--demo-") || ["--gallery", "--stress", "--fake-reply"].contains($0) }
        if settings.backend == .cli, fake == nil, !scripted { cli.prewarm() }
        Connection.shared.onChange.append { [weak self] in self?.menuBar.updateIcon(); SettingsWindow.refresh() }
        MainActor.assumeIsolated { Connection.shared.refresh() }
        if settings.voice { prepareVoice() }
        trace("Launch \(Bundle.main.bundlePath) pid \(getpid())")
        if !scripted { CrashReports.start(); Updates.start() }
        LoginItem.setUpOnce()
        trace("Permissions: " + OnboardingWindow.permissions.map { "\($0.name)=\($0.granted() ? "yes" : "no")" }.joined(separator: ", "))
        if !scripted, !settings.onboarded || !AX.trusted || !CGPreflightScreenCaptureAccess() { showSetup() }
        trace("Navi running. Tap \(settings.hotkeyLabel) to type a question\(settings.voice ? ", hold to talk, ⌃⌥D dictates" : ""). Esc stops.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Audio.restore()
        cli.shutdown()
    }

    /// Hold Fn to talk, tap to type (with the shortcut still working too).
    private let fn = FnKey()

    func setFnKey(_ on: Bool) {
        settings.fnKey = on
        fn.holdTalks = on
        on ? fn.start() : fn.stop()
    }

    private let tapTrigger = TapTrigger()

    func setTypeTrigger(_ mode: TapTrigger.Mode) {
        settings.typeTrigger = mode.rawValue
        tapTrigger.mode = mode
        trace("Type to Navi with: \(mode.title)")
    }

    /// Straight to typing (a tap of Fn): the type bar opens at once and takes
    /// the keys, with the screen grabbed before it appears.
    func typeNow() {
        // A second tap straight after the first: draw on the screen instead.
        if panel.isVisible, Date().timeIntervalSince(panelOpenedAt) < 0.5 { return startMarking() }
        // The bar is still up (they went to another app): bring it back to the keys.
        if panel.isVisible, !markMode.isDrawing { return refocusBar() }
        guard pressedAt == nil, !panel.isVisible, !dictating else { return }
        panelOpenedAt = Date()
        Owl.shared.appear()
        buddy.summon()
        stopHandsFree()
        reset()
        if AX.passwordFieldFocused {
            showBubble("A password field is focused, so I won't look at your screen.", at: NSEvent.mouseLocation, style: .status)
            scheduleClear(after: 3)
            return
        }
        frontApp = currentFrontApp()
        shotsTask = Task { try await Capture.takeAll() }
        shotsAt = Date()
        let app = frontApp, wantContext = settings.context
        contextTask = Task.detached { wantContext ? AX.frontContext(for: app) : AX.FrontContext() }
        setEscape(true)
        topicPill.hide()
        panel.show(on: Capture.screenUnderMouse(), markedSomething: false, topic: topicPillText, app: frontApp?.localizedName)
    }

    /// The type bar takes the keys again.
    private func refocusBar() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.field)
    }

    /// Fn turned out to be part of a combo (Fn+arrow…): undo the press quietly.
    private func cancelPress() {
        guard pressedAt != nil else { return }
        pressedAt = nil
        pressGen += 1
        gesture.stop()
        if listening { transcriber.cancel(); stopListeningUI() }
        shotsTask?.cancel()
        overlays.clearAll()
        hideBubble()
        setEscape(false)
        restNaviSoon(0.5)
    }

    private func registerHotkey() {
        hotkey = nil
        hotkey = Hotkey(keyCode: settings.hotkeyCode, modifiers: settings.hotkeyMods) { [weak self] down in
            down ? self?.hotkeyDown() : self?.hotkeyUp()
        }
        if hotkey?.isRegistered != true { trace("Couldn't register \(settings.hotkeyLabel); another app may own it.") }
    }

    /// Esc is only grabbed while something of ours is live, so it doesn't
    /// steal the key from other apps the rest of the time.
    func setEscape(_ on: Bool) {
        escWanted = on
        refreshEscape()
    }
    /// Whether Esc should stop Navi now (what the engine and the controller asked for).
    private var escWanted = false
    /// The first Esc of a possible double-Esc during a lesson step.
    private var lastLessonEsc = Date.distantPast

    /// While a lesson step waits in the user's app, a single Esc is theirs (closing a menu,
    /// a sheet, Quick Look) and isn't taken; two within half a second end the lesson
    /// (decision 9), seen by a monitor that only listens. Otherwise Esc is Navi's.
    private func refreshEscape() {
        // Without Accessibility the listening monitor sees no keys, so Navi keeps Esc as before.
        let grab = escWanted && !(AX.trusted && Self.lessonKeepsEsc(waiting: lessonWaiting, paused: lessonPaused, barOpen: panel.isVisible))
        if grab, escKey == nil {
            escKey = Hotkey(keyCode: kVK_Escape, modifiers: 0) { [weak self] down in if down { self?.escape() } }
        } else if !grab {
            escKey = nil
        }
    }

    /// Whether Esc belongs to the user's app: a step waiting there, with no Navi panel open.
    static func lessonKeepsEsc(waiting: Bool, paused: Bool, barOpen: Bool) -> Bool {
        waiting && !paused && !barOpen
    }

    /// Esc seen (not taken) while the user's app has it.
    private func lessonEscPressed() {
        guard escWanted, escKey == nil else { return }
        let now = Date()
        if now.timeIntervalSince(lastLessonEsc) < 0.5 {
            lastLessonEsc = .distantPast
            trace("Double Esc: ending the lesson.")
            return escape()
        }
        lastLessonEsc = now
        refreshEscape()   // the step may have been taken meanwhile
        guard caption.isShowing else { return }
        let before = caption.kicker, hint = "ESC AGAIN TO END THE LESSON"
        caption.setKicker(hint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.caption.kicker == hint else { return }
            self.caption.setKicker(before)
        }
    }

    // MARK: Press and release

    private func hotkeyDown() {
        buddy.summon()
        guard pressedAt == nil, !dictating else { return }
        // A second tap soon after the first starts a hands-free conversation, with voice on.
        // With voice off it's just another tap (decision 15): nothing would be listening.
        if settings.voice, let lastTap, Date().timeIntervalSince(lastTap) < 0.45 {
            panel.orderOut(nil)
            doubleTapping = true
            self.lastTap = nil
            return
        }
        stopHandsFree()
        reset()
        if AX.passwordFieldFocused {
            showBubble("A password field is focused, so I won't look at your screen.", at: NSEvent.mouseLocation, style: .status)
            scheduleClear(after: 3)
            return
        }
        pressedAt = Date()
        pressGen += 1
        frontApp = currentFrontApp()
        // Grab the screen now, before the bubble or panel appear.
        shotsTask = Task { try await Capture.takeAll() }
        shotsAt = Date()
        let app = frontApp, wantContext = settings.context
        contextTask = Task.detached { wantContext ? AX.frontContext(for: app) : AX.FrontContext() }
        setEscape(true)

        gesture.onUpdate = { [weak self] pts in self?.drawGestureTrail(pts) }
        gesture.start()
        if settings.voice { startListening() }
    }

    private func hotkeyUp() {
        if doubleTapping {
            doubleTapping = false
            startHandsFree()
            return
        }
        guard let pressedAt else { return }
        self.pressedAt = nil
        let held = Date().timeIntervalSince(pressedAt)
        let pts = gesture.stop()
        let marked = GestureTracker.isMeaningful(pts) ? pts : nil
        if marked == nil { overlays.clearAll() }

        // A quick tap types: open the bar now, before anything else, so no keys are lost.
        // A second tap (hands-free) closes it again in hotkeyDown.
        if held < 0.35 && marked == nil {
            hideBubble()
            lastTap = Date()
            Owl.shared.appear()
            topicPill.hide()
            panel.show(on: Capture.screenUnderMouse(), markedSomething: false, topic: topicPillText, app: frontApp?.localizedName)
            if listening { transcriber.cancel(); stopListeningUI() }
            return
        }
        let gen = pressGen
        Task { @MainActor in
            var spoken = ""
            if self.listening {
                await self.listenTask?.value
                spoken = await self.transcriber.stop()
                // Esc or a new press during the flush: its words aren't sent, and the new
                // press keeps its own listening state.
                guard gen == self.pressGen else { return }
                self.stopListeningUI()
            }
            if !spoken.isEmpty {
                self.ask(spoken, gesture: marked, byVoice: true)
            } else {
                // A hold with no speech (perhaps a gesture): type instead.
                self.hideBubble()
                self.pendingGesture = marked
                self.panel.show(on: Capture.screenUnderMouse(), markedSomething: marked != nil, topic: self.topicPillText, app: self.frontApp?.localizedName)
            }
        }
    }

    private func startListening() {
        Owl.shared.set(.listening)
        listening = true
        if settings.duck { Audio.duck() }
        buddy.set(.listening)
        let hints = Voice.hints(app: frontApp)
        // Only show "Listening" if they're actually holding, not on a quick tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.pressedAt != nil, self.listening else { return }
            self.showBubble("", at: NSEvent.mouseLocation, style: .listening)
        }
        listenTask = Task { @MainActor in
            if let problem = await Voice.authorize() {
                self.stopListeningUI()
                self.showBubble(problem, at: NSEvent.mouseLocation, style: .status)
                return
            }
            // A quick tap or Esc came while permission was being checked: don't open the mic.
            guard self.listening else { return }
            do {
                try await self.transcriber.start(hints: hints) { text in
                    DispatchQueue.main.async {
                        guard self.pressedAt != nil else { return }
                        self.showBubble(text, at: NSEvent.mouseLocation, style: .listening)
                    }
                }
            } catch {
                self.stopListeningUI()
                trace("Voice failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopListeningUI() {
        listening = false
        if Owl.shared.state == .listening { Owl.shared.set(.idle) }
        Audio.restore()
        MicLevel.reset()
        if buddy.state == .listening { buddy.set(.idle) }
    }

    func prepareVoice() {
        Task { await Voice.prepare() }
    }

    private func drawGestureTrail(_ pts: [NSPoint]) {
        for screen in NSScreen.screens {
            let local = pts.filter { NSMouseInRect($0, screen.frame, false) }
                .map { CGPoint(x: $0.x - screen.frame.minX, y: $0.y - screen.frame.minY) }
            if local.count > 1 { overlays.view(for: screen)?.showGesture(local) }
        }
    }

    private func currentFrontApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
    }

    // MARK: Asking

    /// While they're trying it themselves, every turn says so.
    private var tryFirst: Bool { get { engine.tryFirst } set { engine.tryFirst = newValue } }

    /// The screenshot a tag's screen number means; 0 is the one with the cursor.
    static func shot(_ n: Int, in shots: [ScreenShot]) -> ScreenShot {
        Tutor.shot(n, in: shots, index: \.index, hasCursor: \.hasCursor)
    }


    /// A question, typed or spoken (`byVoice`), with a pointer gesture or Mark-mode marks.
    /// The engine decides what it means; the Mac supplies the screens, the app's context
    /// (both often grabbed when typing began) and the marks drawn into the screenshots.
    func ask(_ question: String, gesture marked: [NSPoint]? = nil, byVoice: Bool = false, marks: [Mark] = []) {
        let fromCard = typingIntoLesson
        typingIntoLesson = false
        askedByVoice = byVoice
        let marked = marked ?? pendingGesture
        pendingGesture = nil
        frontApp = frontApp ?? currentFrontApp()
        frontApp?.activate(options: [])   // give focus back after the panel
        let anchor = NSEvent.mouseLocation
        // The screens grabbed when typing began, unless that was long ago.
        let fresh = Date().timeIntervalSince(shotsAt) < 90
        let shotsTask = fresh ? self.shotsTask : nil, contextTask = fresh ? self.contextTask : nil
        if !fresh { self.shotsTask?.cancel() }
        self.shotsTask = nil
        self.contextTask = nil
        let app = frontApp, wantContext = settings.context
        let annotate: (([any Shell.Screenshot]) async -> Tutor.Engine.Marked)? = marked == nil && marks.isEmpty ? nil : { shots in
            await Self.annotate(shots.compactMap { $0 as? ScreenShot }, gesture: marked, marks: marks, app: app)
        }
        engine.ask(Tutor.Engine.Asking(question: question, fromCard: fromCard, anchor: anchor, screenshots: {
            var shots: [ScreenShot]
            if let shotsTask { shots = try await shotsTask.value } else { shots = try await Capture.takeAll() }
            #if DEBUG
            // Test harness: SP_DEMO_IMAGE=<file> stands in for the cursor screen's capture.
            if let path = ProcessInfo.processInfo.environment["SP_DEMO_IMAGE"], let img = Self.demoImage(path, like: shots[0].image) {
                shots[0].image = img
            }
            #endif
            return shots
        }, context: {
            let ctx: AX.FrontContext
            if let contextTask { ctx = await contextTask.value }
            else { ctx = wantContext ? await Task.detached { AX.frontContext(for: app) }.value : AX.FrontContext() }
            return (ctx.text, ctx.host)
        }, marks: annotate))
    }

    /// The user's pointer gesture, or Mark mode's marks, drawn into the screenshots and
    /// described, with the controls under each and a close-up of each mark.
    static func annotate(_ input: [ScreenShot], gesture marked: [NSPoint]?, marks: [Mark],
                         app: NSRunningApplication?) async -> Tutor.Engine.Marked {
        var shots = input
        var gestureText: String?
        var extras: [String] = []
        if let marked, let shot = GestureTracker.shot(for: marked, in: shots),
           let i = shots.firstIndex(where: { $0.index == shot.index }) {
            shots[i].image = Capture.burn(gesture: marked, into: shot)
            gestureText = GestureTracker.describe(marked, on: shot)
            let box = Self.bounds(marked)
            let pid = app?.processIdentifier
            let found = await Task.detached { AX.elements(in: box, frontPID: pid) }.value
            if let note = Tutor.elementsNote(found) { extras.append(note) }
        }
        // Marks from Mark mode: drawn into the screenshots, numbered, described in
        // words with the controls inside each, plus a close-up of each one.
        var closeUps: [[String: Any]] = []
        if !marks.isEmpty {
            var lines: [String] = []
            let pid = app?.processIdentifier
            for (i, s) in shots.enumerated() {
                let here = marks.enumerated().filter { NSMouseInRect(NSPoint(x: $0.element.rect.midX, y: $0.element.rect.midY), s.screen.frame, false) }
                guard !here.isEmpty else { continue }
                shots[i].image = Mark.burn(here.map(\.element), into: s)
                for (n, m) in here {
                    let rect = m.rect
                    let found = await Task.detached { AX.elements(in: rect, frontPID: pid) }.value
                    lines.append(m.describe(n + 1, on: shots[i], elements: found))
                    if let crop = m.closeUp(from: shots[i]), let jpeg = Capture.jpeg(crop) {
                        closeUps.append(Prompt.text("Close-up of mark \(n + 1) (from screen \(s.index)):"))
                        closeUps.append(Prompt.image(jpeg))
                    }
                }
            }
            gestureText = Tutor.marksNote(lines)
            trace("Asked with \(marks.count) mark(s).")
        }
        return Tutor.Engine.Marked(shots: shots, note: gestureText, extras: extras, closeUps: closeUps)
    }

    #if DEBUG
    static func demoImage(_ path: String, like shot: CGImage) -> CGImage? {
        guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: shot.width, height: shot.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        return ctx.makeImage()
    }
    #endif

    private static func bounds(_ pts: [NSPoint]) -> NSRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }


    /// Why we shouldn't talk out loud right now, if there is a reason.
    private enum Quiet: String { case sharing = "screen sharing", call = "on a call", muted = "Mac muted" }

    /// Why a spoken answer shouldn't be read aloud right now. Calls and
    /// screen sharing stay quiet silently; a muted Mac gets an
    /// Unmute notice, once per session.
    private func quietReason() -> Quiet? {
        if Audio.screenShared { return .sharing }
        if Audio.micBusyElsewhere { return .call }
        if Audio.outputSilent { return .muted }
        return nil
    }


    // MARK: Beats

    /// The teaching engine (NaviCore): plays replies as beats through the shell protocols.
    private lazy var engine: Tutor.Engine = {
        let e = Tutor.Engine(overlay: overlays, light: buddy, caption: caption, ui: MacUIReader(), screens: MacScreens(),
                             voice: narrator, settings: settings)
        e.send = { [unowned self] content, kind, onText in
            try await self.conversation.send(content, kind: kind, via: self.backend, onText: onText)
        }
        e.host = self
        e.watch = self
        e.pauseCard = pauseCard
        e.actions = errands
        // A web lookup can take ten seconds: say that's what the wait is.
        NotificationCenter.default.addObserver(forName: .naviLookingUp, object: nil, queue: .main) { [weak self] note in
            guard let self, !self.engine.beatsPlaying else { return }
            let web = (note.object as? String)?.lowercased().hasPrefix("web") ?? true
            self.showWorking(web ? "Looking it up…" : "Checking your Mac…", at: NSEvent.mouseLocation)
        }
        // Before the first words, the status says what Claude is really doing (Tutor.WaitLine).
        NotificationCenter.default.addObserver(forName: .naviWaiting, object: nil, queue: .main) { [weak self] note in
            guard let self, let w = note.object as? Shell.Waiting else { return }
            if w == .sent {
                self.stillWork?.cancel()
                let still = DispatchWorkItem { [weak self] in self?.wantWaitLine(Tutor.WaitLine.still) }
                self.stillWork = still
                DispatchQueue.main.asyncAfter(deadline: .now() + Tutor.WaitLine.stillAfter, execute: still)
            }
            guard self.waitLine.showing != Tutor.WaitLine.still else { return }
            self.wantWaitLine(Tutor.WaitLine.line(for: w))
        }
        e.topicPill = topicPill
        e.conversation = conversation
        e.frontApp = { [unowned self] in
            self.frontApp.map { Shell.AppInfo(bundleID: $0.bundleIdentifier, name: $0.localizedName, pid: $0.processIdentifier) }
        }
        e.onBeatStart = { [unowned self] in   // the answer is here; clicks from now on are the lesson's
            self.stopActWatch()
            self.endWait()
        }
        return e
    }()

    static func ringLooksLikeSize(_ pts: [CGPoint], _ shot: ScreenShot) -> Bool { Tutor.ringLooksLikeSize(pts, in: shot.pixelSize) }

    /// Every coordinate is clamped into the screenshot before mapping.
    static func clamp(_ p: CGPoint, _ shot: ScreenShot) -> CGPoint { Tutor.clamp(p, in: shot.pixelSize) }

    // MARK: Bubble

    private func showBubble(_ text: String, at global: NSPoint, style: Caption.Style) {
        caption.show(text, style: style, at: global)
    }

    private func hideBubble() { caption.hide() }

    // MARK: Typing and dictation

    private func type(_ t: TypeRequest, shots: [ScreenShot], reply: String, anchor: NSPoint) {
        let shot = Self.shot(t.screen, in: shots)
        let point = t.at.map { shot.globalPoint($0) }
        frontApp?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let outcome = AX.insert(t.text, at: point, frontPID: self.frontApp?.processIdentifier)
            self.showBubble(reply.isEmpty ? outcome.message : "\(reply) \(outcome.message)", at: anchor, style: .answer)
        }
    }

    /// Hold ⌃⌥D and talk: the words go into the focused field.
    private func dictateDown() {
        // Text-first: no microphone unless voice is switched on.
        guard settings.voice, !dictating, pressedAt == nil, !listening else { return }
        if AX.passwordFieldFocused { return }
        dictating = true
        frontApp = currentFrontApp()
        if settings.duck { Audio.duck() }
        buddy.set(.listening)
        showBubble("", at: NSEvent.mouseLocation, style: .listening)
        let hints = Voice.hints(app: frontApp)
        listenTask = Task { @MainActor in
            if let problem = await Voice.authorize() {
                self.showBubble(problem, at: NSEvent.mouseLocation, style: .status)
                return
            }
            guard self.dictating else { return }   // let go or Esc while permission was checked
            try? await self.transcriber.start(hints: hints) { text in
                DispatchQueue.main.async {
                    if self.dictating { self.showBubble(text, at: NSEvent.mouseLocation, style: .listening) }
                }
            }
        }
    }

    private func dictateUp() {
        guard dictating else { return }
        dictating = false
        Task { @MainActor in
            await self.listenTask?.value
            let text = await self.transcriber.stop()
            Audio.restore()
            MicLevel.reset()
            self.buddy.set(.idle)
            guard !text.isEmpty else { return self.hideBubble() }
            self.frontApp?.activate(options: [])
            try? await Task.sleep(nanoseconds: 150_000_000)
            let outcome = AX.insert(text, at: nil, frontPID: self.frontApp?.processIdentifier)
            self.showBubble(outcome == .copied ? outcome.message : "✓ \(text)", at: NSEvent.mouseLocation, style: .status)
            self.scheduleClear(after: 2)
        }
    }

    // MARK: Lessons





    func stopActWatch() {
        if let actWatch { NSEvent.removeMonitor(actWatch) }
        actWatch = nil
    }


    // MARK: Dialogs over a step

    /// On-screen windows and the watch for a new one over the step: NaviCore's `Tutor`.
    typealias ScreenWindow = Tutor.ScreenWindow
    typealias DialogWatch = Tutor.DialogWatch

    private var dialogWatch: DialogWatch?
    private var dialogTimer: Timer?

    static func onScreenWindows() -> [ScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? CGWindowID, let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (w[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 else { return nil }
            let title = w[kCGWindowName as String] as? String ?? ""
            return ScreenWindow(id: id, pid: pid, layer: w[kCGWindowLayer as String] as? Int ?? 0,
                                bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0),
                                name: title.isEmpty ? (w[kCGWindowOwnerName as String] as? String ?? "a window") : title)
        }
    }




    // MARK: Screen changes

    /// When the screen moves under the drawing (a scroll, another
    /// app, another Space), the marks are wrong, so clear them and let the voice
    /// carry on. A lesson step is re-placed after a scroll and paused after a switch.
    private func watchScreenChanges() {
        // Typing steps in lessons: only when a key is pressed and in which app, never which key.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return }
            if e.keyCode == UInt16(kVK_Escape), e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, !e.isARepeat {
                self.lessonEscPressed()
            }
            guard self.engine.typeStep != nil, !e.modifierFlags.contains(.command) else { return }
            self.engine.typed(returnKey: e.keyCode == 36, pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self else { return }
            // Trackpad gestures report when they begin; a plain wheel has no phase, so each tick counts.
            if e.phase == .began || (e.phase.isEmpty && e.momentumPhase.isEmpty) { self.gestureBegan = Date() }
            // A scroll that started before this answer appeared is the user finishing what they were
            // doing, not moving the screen under the drawing.
            guard self.gestureBegan >= self.answerStarted else { return }
            // A mouse wheel reports lines, a trackpad points: about ten points to a line.
            let lines = abs(e.scrollingDeltaY) + abs(e.scrollingDeltaX)
            self.engine.scrolled(e.hasPreciseScrollingDeltas ? lines : lines * 10)
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            let name = app.localizedName ?? "another app"
            let there = Self.screen(ofFrontWindowOf: app.processIdentifier).map(Capture.displayID)
            self.engine.appCameForward(pid: app.processIdentifier, name: name, display: there)
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.spaceChanged()
        }
    }


    /// Displays changed under a lesson (decision 14): marks stay where they were, and Navi
    /// looks again only if the armed step's own display moved or resized. If that display
    /// is gone, the lesson waits on the card ("I did it" looks again).
    private func displaysChanged(_ changed: Set<CGDirectDisplayID>) {
        guard let step = lesson?.armed, changed.contains(step.display) else { return }
        if Capture.screen(step.display) == nil {
            trace("The step's display went away: pausing the lesson.")
            engine.pauseLesson(why: "the step's display went away")
        } else {
            trace("The step's display changed: looking again.")
            _ = engine.lookAgain(Tutor.spaceEvent(step.label), why: "its display changed")
        }
    }

    /// The display holding an app's frontmost window, if it has one on screen.
    static func screen(ofFrontWindowOf pid: pid_t) -> NSScreen? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0   // window bounds use top-left coordinates
        let centre = NSPoint(x: x + width / 2, y: top - (y + height / 2))
        return NSScreen.screens.first { NSMouseInRect(centre, $0.frame, false) }
    }


    // MARK: Did the step move?

    /// What the area around the armed step looked like when it was armed.
    private var stepLook: (image: CGImage, display: CGDirectDisplayID)?
    /// The whole screen then, for noticing keyboard shortcuts.
    private var screenLook: CGImage?

    func rememberLook(of step: Walkthrough.Step, in shots: [any Shell.Screenshot]) {
        guard let shot = shots.compactMap({ $0 as? ScreenShot }).first(where: { step.isOn($0.screen) }) else { return }
        stepLook = Self.crop(shot, around: step.center).map { ($0, step.display) }
        screenLook = Self.thumb(shot.image, 64, 40)
    }

    /// A grayscale patch, 120 pt square, around a global point.
    static func crop(_ shot: ScreenShot, around p: NSPoint) -> CGImage? {
        let c = shot.pixel(p), half = 60 / shot.scale
        let r = CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2)
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        guard !r.isEmpty, let part = shot.image.cropping(to: r.integral) else { return nil }
        return thumb(part, 16, 16)
    }

    static func thumb(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Whether two small grayscale images differ noticeably (mean difference over ~5%).
    static func differs(_ a: CGImage, _ b: CGImage, threshold: Double = 12) -> Bool {
        func bytes(_ i: CGImage) -> [UInt8] {
            guard let t = thumb(i, 16, 16), let d = t.dataProvider?.data as Data? else { return [] }
            return [UInt8](d)
        }
        let x = bytes(a), y = bytes(b)
        guard x.count == y.count, !x.isEmpty else { return true }
        let total = zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(x.count) > threshold
    }


    /// A ⌘ shortcut or Return in the lesson's app may have done the step without a click:
    /// if the screen changed, look again.
    private func keyPressedDuringStep(_ e: NSEvent) {
        guard let step = lesson?.armed, let home = lessonApp, NSWorkspace.shared.frontmostApplication?.processIdentifier == home,
              e.modifierFlags.contains(.command) || e.keyCode == 36 else { return }
        keyLookWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lesson?.armed?.armedAt == step.armedAt else { return }
            Task { @MainActor in
                guard let shots = try? await Capture.takeAll(), let shot = shots.first(where: { step.isOn($0.screen) }),
                      let before = self.screenLook, let now = Self.thumb(shot.image, 64, 40), Self.differs(before, now, threshold: 6) else { return }
                trace("A key changed the screen during \"\(step.label)\": looking again.", content: true)
                _ = self.engine.lookAgain(Tutor.shortcutEvent(step.label), why: "a shortcut")
            }
        }
        keyLookWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    private var keyLookWork: DispatchWorkItem?
    private var keyMonitor: Any?

    /// The process that owns the topmost window under a point (AppKit global coordinates).
    static func windowOwner(at p: NSPoint) -> pid_t? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let q = CGPoint(x: p.x, y: top - p.y)   // window bounds use top-left coordinates
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(q) else { continue }
            return w[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }



    // MARK: Away and back

    /// A fresh screenshot and the lesson's next move: the step again, or the next one.
    /// A request to Claude is in flight: a fresh look would only collide with it
    /// (and its answer already sees the new screen).
    private var waitingForReply: Bool { engine.waitingForReply }







    // MARK: Hands-free

    /// Double-tap: talk without holding the key. After each answer it listens
    /// again; with headphones you can cut in while it is speaking.
    private func startHandsFree() {
        guard settings.voice else { trace("Hands-free needs voice, which is off."); return }
        reset()
        handsFree = true
        frontApp = currentFrontApp()
        setEscape(true)
        showBubble("Hands-free: just talk. Esc to stop.", at: NSEvent.mouseLocation, style: .status)
        listenHandsFree()
    }

    #if DEBUG
    func demoHandsFree() { startHandsFree() }
    func demoScroll() { engine.scrolled(60, anyWindow: true) }
    #endif

    private func stopHandsFree() {
        handsFree = false
        autoListen?.cancel()
        autoListen = nil
        if listening && pressedAt == nil && !dictating {
            transcriber.cancel()
            stopListeningUI()
        }
    }

    /// Listens until the user pauses for 1.2 s, then asks. Gives up after 8 s
    /// of silence (and leaves hands-free). Speech while an answer is playing
    /// interrupts it.
    private func listenHandsFree() {
        guard handsFree, settings.voice, autoListen == nil, !listening else { return }
        listening = true
        let hints = Voice.hints(app: frontApp)
        autoListen = Task { @MainActor in
            defer { self.autoListen = nil }
            if let problem = await Voice.authorize() {
                self.stopListeningUI()
                self.handsFree = false
                self.showBubble(problem, at: NSEvent.mouseLocation, style: .status)
                return
            }
            guard self.handsFree, !Task.isCancelled else { return self.stopListeningUI() }
            var heard = "", lastChange = Date(), started = Date()
            do {
                try await self.transcriber.start(hints: hints) { text in
                    DispatchQueue.main.async {
                        guard self.handsFree, text != heard else { return }
                        heard = text
                        lastChange = Date()
                        if self.narrator.isSpeaking, !text.isEmpty {
                            // Barge-in: stop talking and let them finish.
                            self.narrator.stop()
                            self.turn?.cancel()
                            _ = self.engine.bump()
                        }
                        if !self.narrator.isSpeaking { self.buddy.set(.listening) }
                        self.showBubble(text, at: NSEvent.mouseLocation, style: .listening)
                    }
                }
            } catch {
                self.stopListeningUI()
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !heard.isEmpty && Date().timeIntervalSince(lastChange) > 1.2 { break }
                // Time spent waiting for or hearing an answer doesn't count as silence.
                if self.narrator.isSpeaking || self.buddy.state == .thinking { started = Date() }
                if heard.isEmpty && Date().timeIntervalSince(started) > 8 {
                    self.transcriber.cancel()
                    self.stopListeningUI()
                    self.handsFree = false
                    self.showBubble("Hands-free off.", at: NSEvent.mouseLocation, style: .status)
                    self.scheduleClear(after: 2)
                    return
                }
            }
            if Task.isCancelled { return }
            let text = await self.transcriber.stop()
            self.stopListeningUI()
            if !text.isEmpty { self.ask(text, byVoice: true) }
        }
    }

    // MARK: Clearing and cancelling

    func fail(_ error: Error, at anchor: NSPoint) {
        trace("Failed: \(Swift.type(of: error))")
        // The detail can carry Claude Code's stderr, which can echo the question.
        trace("Failed: \(Redact.secrets(in: String(describing: error).prefix(400).description))", content: true)
        stopActWatch()   // a later click mustn't start a surprise "they acted again" turn
        buddy.set(.idle)
        Owl.shared.set(.idle)
        Owl.shared.react(.sorry, for: 3)
        buddy.comeBack()
        let (sentence, setup) = Self.sentence(for: error, screenRecording: CGPreflightScreenCaptureAccess())
        showBubble(sentence, at: anchor, style: .status)
        scheduleClear(after: 8)
        if setup { showSetup() }
    }

    /// A plain sentence for what went wrong, never Apple's or Claude Code's raw text (that's
    /// traced), and whether the setup guide should open to fix it.
    static func sentence(for error: Error, screenRecording: Bool) -> (String, setup: Bool) {
        let ns = error as NSError
        // ScreenCaptureKit: no permission yet (-3801), or granted but not yet relaunched.
        if ns.domain.contains("SCStreamError") || ns.domain == "Capture" {
            if !screenRecording || ns.code == -3801 {
                return ("Navi can't see your screen yet. Turn on Screen Recording for Navi in System Settings, then quit and reopen Navi.", true)
            }
            return ("Navi couldn't see your screen just then. Try again in a moment.", false)
        }
        if let known = ConnectionProblem(error: error) { return (known.spoken, false) }
        switch error {
        case ClaudeCLIError.failed(let m) where m.contains("already running"):
            return ("Navi is still finishing the last answer. Try again in a moment.", false)
        case ClaudeCLIError.failed, ClaudeCLIError.exited:
            return ("Claude Code stopped before it answered. Try again; if it keeps happening, check the connection in Navi's Settings.", false)
        case ClaudeError.http(let code, _):
            return ("Claude's service answered with an error (\(code)). Try again in a moment.", false)
        case ClaudeError.stream:
            return ("The answer was cut off. Try asking again.", false)
        default: break
        }
        if error is LocalizedError { return (error.localizedDescription, false) }
        if ns.domain == NSURLErrorDomain { return ("Navi couldn't reach Claude. Check your internet connection.", false) }
        return ("Something went wrong on the way. Try again.", false)
    }

    private func scheduleClear(after seconds: TimeInterval) {
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.clearScreen() }
    }

    /// Clears drawings and the bubble, but keeps an armed lesson step.
    func clearScreen() {
        clearTimer?.invalidate()
        if !markMode.isDrawing { markMode.clear() }
        // A step still waiting on the user (a click, a scroll, typing, or the pause card): its
        // sentence stays up until it's taken (decision 10), and Esc stays Navi's.
        let waiting = lessonWaiting || lessonPaused
        if !waiting { Owl.shared.settle() }
        if !(waiting && caption.style == .answer) { caption.clear() }
        if lesson?.armed == nil { buddy.comeBack(); buddy.tint(.ink) }
        if lesson?.armed != nil {
            overlays.views.forEach { $0.fadeDrawings() }
        } else {
            overlays.clearAll()
        }
        if !waiting, !handsFree { setEscape(false) } else { refreshEscape() }
        restNaviSoon()
        showTopicPill()
    }

    /// Setup was opened once this session for a lesson that needs Accessibility.
    private var accessibilityNagged = false

    /// A lesson step is armed and waiting for the user: a click, a scroll or typing.
    private var lessonWaiting: Bool { lesson?.armed != nil || engine.scrollStep != nil || engine.typeStep != nil }

    /// Stops the current answer before a new press.
    private func reset() {
        stopActWatch()
        // Screens grabbed for a question that never came aren't sent with a later one.
        shotsTask?.cancel(); shotsTask = nil
        contextTask?.cancel(); contextTask = nil
        typingIntoLesson = false
        turn?.cancel()
        turn = nil
        engine.bump()
        narrator.stop()
        // Scroll and typing steps too: a scroll while the new question is prepared mustn't take one.
        engine.disarmAll()
        clearTimer?.invalidate()
        overlays.clearAll()
        caption.hide()
        panel.orderOut(nil)
        pendingGesture = nil
        buddy.comeBack()
        buddy.set(.idle)
    }

    /// One gesture cancels everything: listening, the model, the voice, the
    /// drawings, a lesson and hands-free.
    func escape() {
        // Esc while drawing just finishes drawing; the question is still to come.
        if markMode.isDrawing { return markMode.finish() }
        markMode.clear()
        let panelWasOpen = panel.isVisible
        stopHandsFree()
        if listening || dictating { transcriber.cancel(); dictating = false; stopListeningUI() }
        gesture.stop()
        pressedAt = nil
        pressGen += 1
        reset()
        errands.cancel()
        engine.endLesson(clear: true)
        setEscape(false)
        if panelWasOpen { frontApp?.activate(options: []) }
        restNaviSoon(1)
        trace("Escape: stopped everything.")
    }

    // MARK: Menu actions

    /// Whether a lesson is going now (dropped files go straight into it).
    var inLesson: Bool { engine.lesson != nil }

    /// Files dropped on Navi or added in History. Secrets are refused (beeped, never kept);
    /// with nothing left to attach, false.
    @discardableResult
    func attach(_ urls: [URL], to target: Tutor.Engine.AttachTarget, announce: Bool = true, openTyping: Bool = true) -> Bool {
        let fine = urls.filter { !MacErrands.isSecret($0) }
        if fine.count < urls.count {
            NSSound.beep()
            trace("Not attached: \(urls.count - fine.count) file(s) in a private place (keys, keychains, mail…).")
        }
        guard !fine.isEmpty else { return false }
        engine.attach(fine.map(\.path), to: target, announce: announce)
        // Outside a lesson, they'll want to ask about it: the ask bar opens, showing the files.
        if openTyping, target == .current, !inLesson { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.typeNow() } }
        return true
    }

    /// The ask bar's paperclip: files or folders for this conversation, then back to typing.
    func chooseFiles() {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.prompt = "Add"
        open.message = "Lecture slides, a practical, notes or a whole folder: Navi uses them for the rest of this conversation."
        NSApp.activate(ignoringOtherApps: true)
        let chosen = open.runModal() == .OK ? open.urls : []
        if !chosen.isEmpty { attach(chosen, to: .current, announce: false, openTyping: false) }
        panel.showTopic(topicPillText)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.field)
    }

    /// Picks a kept lesson up again (the menu's Carrying on, or History).
    func resumeLesson(_ id: String) {
        reset()
        engine.resume(id)
    }

    func newConversation() {
        // The answer in flight stops too, whichever backend: otherwise its reply re-creates
        // the lesson and re-arms a step in the "fresh" conversation.
        reset()
        cli.reset()
        api.reset()
        conversation.reset()
        engine.endLesson(clear: true)
        engine.clearTopic()
        setEscape(false)
        restNaviSoon(1)
    }

    func setBackend(_ b: Backend) {
        MainActor.assumeIsolated { Connection.shared.choose(b) }
        if b == .cli { cli.prewarm() }
    }

    /// Coming back from Terminal after `claude auth login`, for instance.
    func applicationDidBecomeActive(_ note: Notification) {
        MainActor.assumeIsolated { Connection.shared.refresh() }
    }

    func setModel(_ m: String) {
        settings.model = m
        newConversation()
    }

    func setEffort(_ e: String) {
        settings.effort = e
        newConversation()
    }

    func setBuddy(_ on: Bool) {
        settings.buddy = on
        buddy.setEnabled(on)
        if on && !settings.naviAlways && !busy { buddy.rest() }
    }

    func setNaviAlways(_ on: Bool) {
        settings.naviAlways = on
        on ? buddy.summon() : buddy.rest(after: 1)
    }

    /// Something is on screen or under way: Navi shouldn't fade.
    private var busy: Bool { turn != nil || lesson != nil || handsFree || listening }

    /// Navi present when needed: after a quiet spell it fades, unless it should always show.
    private func restNaviSoon(_ delay: TimeInterval = 3) {
        guard !settings.naviAlways, lesson?.armed == nil, !handsFree else { return }
        buddy.rest(after: delay)
    }

    func previewVoice(_ id: String) {
        settings.voiceID = id
        narrator.stop()
        let name = Narrator.voiceName
        Task { @MainActor in await self.narrator.speak("Hi, I'm \(name). I'll talk you through things.") }
    }

    func applySharing() {
        overlays.applySharing()
        buddy.applySharing()
        caption.applySharing()
    }

    func openSkillsFolder() {
        Skills.migrate()
        try? FileManager.default.createDirectory(at: Skills.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Skills.folder)
    }

    /// Setup: the guide pane beside System Settings, which teaches each step with
    /// Navi's light and pen. The full window (`showConnection`) holds the connection choices.
    func showSetup() {
        let g = setupGuide ?? SetupGuide()
        setupGuide = g
        g.onConnect = { [weak self] in self?.showConnection() }
        g.onDone = { [weak self] in self?.overlays.clearAll(); self?.buddy.comeBack() }
        g.light = { [weak self] p in
            guard let self else { return }
            if let p { self.buddy.fly(to: p, clear: 14) } else { self.buddy.comeBack() }
        }
        g.marks = { [weak self] ring, arrow, note in
            guard let self else { return }
            self.overlays.clearAll()
            if let ring, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: ring.midX, y: ring.midY)) }) {
                let id = Capture.displayID(screen)
                self.overlays.drawTarget(CGPoint(x: ring.midX, y: ring.midY), radius: hypot(ring.width, ring.height) / 2 + 4,
                                         label: "my switch", snapped: ring, hover: false, on: id, delay: 0)
            }
            if let (from, to) = arrow, let screen = NSScreen.screens.first(where: { $0.frame.contains(to) }) {
                let id = Capture.displayID(screen)
                let wait = self.buddy.trace([from, to])
                self.overlays.setStrokeTime(self.buddy.traceTime([from, to]), on: id)
                self.overlays.drawShape(.arrow, [from, to], label: nil, on: id, delay: wait)
                if let note {
                    let at = CGPoint(x: to.x - 40, y: to.y - 36)
                    self.overlays.write(note, at: self.overlays.writeSpot(note, at: at, on: id), anchor: at, on: id, delay: wait + 0.4)
                }
            }
        }
        g.present()
    }

    func showConnection() {
        let w = onboarding ?? OnboardingWindow(hotkeyLabel: settings.hotkeyLabel)
        w.onDone = { [weak self] in self?.settings.onboarded = true }
        w.connection.onChoose = { [weak self] in self?.setBackend($0) }
        onboarding = w
        w.present()
    }

    func recordShortcut() {
        hotkey = nil   // so pressing the current combo gets recorded, not triggered
        recorder.onDone = { [weak self] code, mods, label in
            guard let self else { return }
            self.settings.hotkeyCode = code
            self.settings.hotkeyMods = mods
            self.settings.hotkeyLabel = label
            self.registerHotkey()
        }
        recorder.onCancel = { [weak self] in self?.registerHotkey() }
        recorder.begin()
    }
}

#if DEBUG
/// Read-only handles for the GUI stress test (`--stress`).
extension AppController {
    var testCaption: Caption { caption }
    var testBuddy: Buddy { buddy }
    var testOverlays: OverlayManager { overlays }
    var testSpeaking: Bool { narrator.isSpeaking }
    /// The answer clearing on its own (reading time over).
    func testClear() { clearScreen() }
    /// The type bar's ↩, as if pressed with `text` in it.
    func testSubmit(_ text: String) { panel.orderOut(nil); panel.onSubmit?(text) }
    static var tryFirstNoteForTests: String { Tutor.tryFirstNote }
    func testPause() { engine.pauseLesson(why: "gallery") }
    var testPauseCard: PauseCard { pauseCard }
    /// A click on the armed step, as if the user made it (practice questions in the gallery).
    func testClick(at p: NSPoint) { graceUntil = nil; engine.stepClicked(at: p) }
    var testArmed: Bool { lesson?.armed != nil }
    /// Opens a surface for a look: PROMPT, MUTED, RECORDER (demo scripts).
    func demoShow(_ what: String) {
        switch what {
        case "PROMPT": panel.show(on: Capture.screenUnderMouse(), markedSomething: false, topic: topicPillText, app: frontApp?.localizedName)
        case "MUTED": mutedNotice.show(on: Capture.screenUnderMouse())
        case "RECORDER": recorder.begin()
        default: break
        }
    }
}
#endif

// MARK: - The engine's host and lesson watch

extension AppController: Shell.Host, Shell.LessonWatch {
    func restSoon(after delay: TimeInterval) { restNaviSoon(delay) }
    func refreshFrontApp() { frontApp = currentFrontApp() }
    func lessonEnded() { typingIntoLesson = false; stopActWatch() }

    /// Typed questions are answered in text; a spoken one
    /// is read aloud unless the Mac is on a call, sharing its screen or muted.
    func prepareTurn() -> Bool {
        var quiet = askedByVoice && settings.speak ? quietReason() : nil
        #if DEBUG
        if CommandLine.arguments.contains(where: { $0 == "--stress" || $0 == "--gallery" }) { quiet = nil }   // the stress test speaks even on a muted Mac
        #endif
        let speak = settings.speak && askedByVoice && quiet == nil
        if let quiet { trace("Quiet: \(quiet.rawValue)") }
        if quiet == .muted, !mutedNoticeShown {
            mutedNoticeShown = true
            mutedNotice.show(on: Capture.screenUnderMouse())
        }
        if handsFree && speak && Audio.headphones { listenHandsFree() }   // lets the user cut in
        answerStarted = Date()
        return speak
    }


    func answerShown(_ played: Tutor.Engine.Played, shots: [any Shell.Screenshot], anchor: CGPoint) {
        let parsed = TagParser.parse(played.reply)
        lastAnswer = played.shown
        if played.shown.isEmpty && parsed.typing == nil { hideBubble() }
        if let typing = parsed.typing { type(typing, shots: shots.compactMap { $0 as? ScreenShot }, reply: played.shown, anchor: anchor) }
    }

    func turnFinished(_ played: Tutor.Engine.Played, speak: Bool, answerWanted: Bool, gen: Int) {
        // Drawings clear when spoken narration stops; with no voice, leave them
        // up long enough to read.
        let words = played.shown.split(separator: " ").count
        if speak {
            // Drawings build into one picture while it talks; a diagram of several
            // parts stays up a little longer once the narration ends.
            let linger = Tutor.drawingsLinger(drawings: played.drawings)
            DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.overlays.views.forEach { $0.fadeDrawings() }
            }
        }
        if !answerWanted { scheduleClear(after: Tutor.answerHold(words: words, speaking: speak)) }
        // Clicks reach Navi without Accessibility, keys don't: a typing step would wait forever.
        if engine.typeStep != nil, !AX.trusted {
            trace("Accessibility is off: the typing step can't see keys.")
            caption.setKicker("ACCESSIBILITY IS OFF · NAVI CAN'T SEE YOUR TYPING")
            if !accessibilityNagged { accessibilityNagged = true; showSetup() }
        }
        // With the setting on and headphones in, every answer opens a follow-up window.
        if !handsFree, settings.handsFree, settings.voice, Audio.headphones { handsFree = true }
        if handsFree && autoListen == nil { listenHandsFree() }
    }

    /// Watches a step: clicks and keys, the pointer resting on a HOVER, and a window
    /// popping up over it, all reported to the engine.
    func watch(_ step: Walkthrough.Step) {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.keyPressedDuringStep(e) }
        stepMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            self?.engine.stepClicked(at: NSEvent.mouseLocation, clicks: e.clickCount)
        }
        if step.hover {
            stepTimer = Timer.scheduledTimer(withTimeInterval: Walkthrough.HoverRest.interval, repeats: true) { [weak self] _ in
                self?.engine.hoverSample(at: NSEvent.mouseLocation)
            }
        }
        // A dialog or new window popping up over the step (from the lesson's app or the
        // system) gets a fresh look, without waiting for a click.
        if lessonApp != nil {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let centre = CGPoint(x: step.center.x, y: top - step.center.y)
            dialogWatch = DialogWatch(baseline: Set(Self.onScreenWindows().map(\.id)))
            dialogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let s = self.lesson?.armed, s.armedAt == step.armedAt,
                      let w = self.dialogWatch?.sample(Self.onScreenWindows(), centre: centre, ownPID: getpid(), now: Date()) else { return }
                trace("A window appeared over \"\(s.label)\": \(w.name) (pid \(w.pid), layer \(w.layer)).", content: true)
                self.engine.dialogAppeared(w.name)
            }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--demo-click-steps") {
            // Test harness: take the step 3 s after it is armed, as a click on its centre.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let s = self.lesson?.armed, s.armedAt == step.armedAt else { return }
                self.engine.stepClicked(at: s.center)
            }
        }
        #endif
        refreshEscape()   // a single Esc is the app's again while the step waits (decision 9)
    }

    func stopWatching() {
        // After the engine has cleared the armed step (it calls this first).
        DispatchQueue.main.async { [weak self] in self?.refreshEscape() }
        dialogTimer?.invalidate()
        dialogTimer = nil
        dialogWatch = nil
        if let stepMonitor { NSEvent.removeMonitor(stepMonitor) }
        stepMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keyLookWork?.cancel()
        stepTimer?.invalidate()
        stepTimer = nil
    }

    /// Compares the area around the step now with when it was armed.
    func stepMoved(_ step: Walkthrough.Step) async -> Bool? {
        guard let shots = try? await Capture.takeAll() else { return nil }
        if let old = stepLook, let shot = shots.first(where: { Capture.displayID($0.screen) == old.display }),
           let now = Self.crop(shot, around: step.center), !Self.differs(old.image, now) {
            return false
        }
        return true
    }

    func watchForActing(_ acted: @escaping () -> Void) {
        stopActWatch()
        actWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in acted() }
    }
}
