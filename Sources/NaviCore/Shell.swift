import Foundation

/// An opaque display id: `CGDirectDisplayID` on the Mac, an `HMONITOR`-derived id on Windows.
public typealias ScreenID = UInt32

/// What each platform's app (the shell) does for the shared teaching engine.
///
/// The engine (`Tutor.Engine`, moving out of the Mac's AppController next) decides
/// what to say and draw; it reaches the screen only through these protocols, so the
/// same flow runs on the Mac (AppKit) and on Windows (DirectComposition).
///
/// Rules for every protocol here:
/// - Coordinates are the shell's **global points**, origin bottom-left (AppKit's
///   convention; Windows flips at its edge). A `ScreenID` says which display.
/// - Every call is made on the main thread.
/// - Colours are the core's `Colour`; the shell turns them into its own.
/// - `delay` is how long to wait before a mark starts drawing (so it lands with its words).
/// - Voice is optional (`Voice`): Navi is text first. There's no
///   listening protocol yet.
///
public enum Shell {

    // MARK: Screens

    /// A captured display, as the engine needs it. The shell keeps the pixels.
    public protocol Screenshot {
        var screenID: ScreenID { get }
        /// Display order, 1-based, as the model is told.
        var index: Int { get }
        var hasCursor: Bool { get }
        var pixelSize: CGSize { get }
        /// Points per pixel.
        var scale: CGFloat { get }
        /// A screenshot pixel (origin top-left) as a global point.
        func global(_ pixel: CGPoint) -> CGPoint
        /// A global point as a screenshot pixel.
        func pixel(_ global: CGPoint) -> CGPoint
        /// 0 (dark) to 1 (light) around a pixel: light pages get darker ink.
        func lightness(near pixel: CGPoint) -> Double
        /// The image to send to Claude.
        func jpeg() -> Data?
    }

    public protocol ScreenSource: AnyObject {
        /// Every display, without Navi's own windows in them.
        func captureAll() async throws -> [any Screenshot]
        func screenUnderPointer() -> ScreenID
        /// The display's frame in global points; nil if it's gone.
        func frame(of screen: ScreenID) -> CGRect?
        /// Waits until the screen stops changing, up to `timeout`; true if it settled.
        func waitForSettle(_ screen: ScreenID, timeout: TimeInterval) async -> Bool
        /// Where the pointer is now.
        func pointerLocation() -> CGPoint
    }

    // MARK: Drawing

    /// The marks layer, one per display.
    public protocol Overlay: AnyObject {
        /// `snapped`: the control the point was snapped to, if snapping found one.
        func drawPoint(_ p: CGPoint, label: String?, snapped: CGRect?, on screen: ScreenID, delay: TimeInterval)
        /// A lesson step (TARGET), or something to rest the pointer on (HOVER).
        func drawTarget(_ p: CGPoint, radius: CGFloat, label: String?, snapped: CGRect?, hover: Bool, on screen: ScreenID, delay: TimeInterval)
        func drawHighlight(_ r: CGRect, label: String?, on screen: ScreenID, delay: TimeInterval)
        func drawShape(_ kind: ShapeKind, _ points: [CGPoint], label: String?, on screen: ScreenID, delay: TimeInterval)
        /// "Show me": a ghost pointer presses at the first point, drags to the last and lets go, a few times.
        func drawDemo(_ points: [CGPoint], label: String?, on screen: ScreenID, delay: TimeInterval)
        /// Handwriting at `p` (where `writeSpot` put it); `anchor` is where it was asked for.
        func write(_ text: String, at p: CGPoint, anchor: CGPoint?, on screen: ScreenID, delay: TimeInterval)
        /// Where writing asked for at `p` will actually sit (moved off other marks).
        func writeSpot(_ text: String, at p: CGPoint, on screen: ScreenID) -> CGPoint
        /// When a line of working is already written at `p`, transforms it into `text` in
        /// place (the terms that carry over slide) and returns the line's frame; else nil.
        func transformWrite(at p: CGPoint, to text: String, on screen: ScreenID) -> CGRect?
        /// How wide `text` is in the handwriting.
        func writingWidth(_ text: String) -> CGFloat
        /// How long the next stroke on `screen` takes to draw, so the ink keeps pace with the light.
        func setStrokeTime(_ seconds: TimeInterval, on screen: ScreenID)
        /// The ink for the next marks, and the colours of letters in writing ("a" in gold).
        func setInk(_ ink: Colour?, letters: [Character: Colour], on screen: ScreenID)
        /// Clears lesson step marks only.
        func clearSteps()
        /// The armed step was just taken: acknowledged on the spot, then gone.
        func stepTaken()
        /// Lets explanation marks fade out.
        func fadeDrawings()
        func clearAll()
        var hasDrawings: Bool { get }
        /// Whether marks are showing on one display.
        func hasDrawings(on screen: ScreenID) -> Bool
        /// Where marks are now (global points), so words and panels avoid them.
        var markAreas: [CGRect] { get }
    }

    /// Errands: opening things, and downloading after asking. Opening is immediate;
    /// a download is offered in the caption first, and an installer or app is only
    /// ever shown in Finder, never opened.
    public protocol Actions: AnyObject {
        /// Opens a web page, an app (by name), or a file (in `app`, if given).
        /// Returns why it couldn't, or nil once it's open.
        func open(_ target: String, with app: String?) -> String?
        /// Offers the file in the caption; `done` gets the saved path, or nil if
        /// they said no or it failed (with why).
        func offerDownload(_ url: String, done: @escaping (_ path: String?, _ problem: String?) -> Void)
        /// Keeps something: copies it, saves it as a note, or sets a reminder. `done` gets
        /// a few words for the caption ("Copied", "Saved to Notes"), or why it couldn't.
        func keep(_ k: Keep, done: @escaping (_ said: String?, _ problem: String?) -> Void)
    }

    /// What Navi's light is doing.
    public enum LightState: Equatable { case idle, listening, thinking, speaking }
    /// The light's colour: ink for drawing, step for a lesson step, idea for explaining.
    public enum LightTint: Equatable { case ink, step, idea }

    /// Navi's light (Buddy on the Mac).
    public protocol Companion: AnyObject {
        /// 0…1: how sure Navi is; a low value makes the light hesitate.
        var confidence: CGFloat { get set }
        func set(_ state: LightState)
        /// Flies to just beside `p`, keeping `clear` points away from it.
        func fly(to p: CGPoint, clear: CGFloat)
        /// Traces a stroke; returns how long until the pen reaches its start.
        @discardableResult func trace(_ points: [CGPoint]) -> TimeInterval
        /// How long a stroke takes at hand speed.
        func traceTime(_ points: [CGPoint]) -> TimeInterval
        /// A tour stop: a slow glide and one soft pulse, no ink.
        func glide(to p: CGPoint)
        /// Wanders inside a highlight while its sentence is read.
        func roam(in r: CGRect)
        func tint(_ tint: LightTint)
        /// Takes on the colour of the thing being explained.
        func glow(_ colour: Colour)
        func summon()
        func comeBack()
        func rest(after delay: TimeInterval)
    }

    // MARK: Words

    /// Navi's words: the caption, floating beside the light or docked at the top.
    public protocol Caption: AnyObject {
        /// A status line ("Looking…") near `p`.
        func show(status: String, at p: CGPoint)
        /// One sentence of an answer, lit word by word. `named` are the words naming what's
        /// drawn (they keep `colour`); `pauses` are word indices where a tour stop waits.
        func read(_ sentence: String, named: [String], at p: CGPoint, near: CGPoint?, wordsPerSecond: Double,
                  colour: Colour?, practice: Bool, stay: Bool, pauses: Set<Int>)
        /// A sentence about to be spoken, laid out faintly; the shell's voice lights it word by word.
        /// Only used when the shell has a `Voice`.
        func say(_ sentence: String, named: [String], at p: CGPoint, near: CGPoint?, colour: Colour?, practice: Bool, stay: Bool)
        /// The voice finished the sentence: light any words left.
        func voiceDone()
        /// Called with each word's index as it lights (tour stops follow it).
        var onWordLit: ((Int) -> Void)? { get set }
        /// After "Your turn", how to answer ("click it on screen"); nil says nothing more.
        var practiceHow: String? { get set }
        /// What Navi is waiting for, shown above the words ("YOUR MOVE · CLICK EXPORT"); nil clears it.
        func setKicker(_ text: String?)
        /// The answer has finished; `holdUntilStep` keeps a step's words up until it's taken.
        func answerDone(holdUntilStep: Bool)
        /// Between answers: keeps the last words up, dimmed; false if nothing was showing.
        func awaitNext() -> Bool
        /// Moves into the top panel unless it would cover a mark; true if it moved.
        @discardableResult func dockIfClear() -> Bool
        /// Floats again if a new mark landed under the top panel.
        func floatIfCovering()
        func hide()
        var isShowing: Bool { get }
        var isDocked: Bool { get }

        /// Your turn: an answer line under the question, taking the keys without
        /// bringing Navi forward. The shell reports what happens through these.
        func takeAnswer()
        func endAnswer()
        var answering: Bool { get }
        var onAnswer: ((String) -> Void)? { get set }
        var onHelp: ((AnswerHelp) -> Void)? { get set }
        var onAnswerCancel: (() -> Void)? { get set }
        /// A small link under the words ("Don't keep this", "Start fresh instead"), offered for a
        /// few seconds; `endLink` takes it away early.
        func link(_ title: String, action: @escaping () -> Void)
        func endLink()
    }

    /// Asking for help under a practice question.
    public enum AnswerHelp: Equatable { case hint, showMe }

    /// The card a paused lesson shows: I did it · Show me again · I'm stuck · Stop.
    public protocol PauseCard: AnyObject {
        func show(kicker: String, text: String, on screen: ScreenID)
        func hide()
        var isShown: Bool { get }
    }

    /// The pill under the top edge naming the current topic; × clears it, a click opens typing.
    public protocol TopicPill: AnyObject {
        func show(_ topic: String, on screen: ScreenID)
        func hide()
        var isShown: Bool { get }
    }

    // MARK: The app in front

    /// The app being learned.
    public struct AppInfo: Equatable {
        public var bundleID: String?
        public var name: String?
        public var pid: Int32
        public init(bundleID: String?, name: String?, pid: Int32) { (self.bundleID, self.name, self.pid) = (bundleID, name, pid) }
    }

    /// Reading the app in front through the platform's accessibility API
    /// (AX on the Mac, UI Automation on Windows).
    public protocol UIReader: AnyObject {
        func frontApp() -> AppInfo?
        /// A short description of the app and document for the prompt, and the web host if it's a browser.
        func context(for app: AppInfo?) async -> (text: String?, host: String?)
        /// The control under `p`, if it can be found (for snapping marks).
        func snap(_ p: CGPoint, on screen: ScreenID, app: AppInfo?) async -> CGRect?
        /// Types into the focused field (or the one at `p`); nil on success, else why not.
        func insert(_ text: String, at p: CGPoint?, app: AppInfo?) -> String?
        /// A password field has focus: Navi doesn't look.
        var passwordFieldFocused: Bool { get }
        /// The process owning the topmost ordinary window under `p`.
        func windowOwner(at p: CGPoint) -> Int32?
        /// The process of the app in front.
        func frontmostPID() -> Int32?
        func bundleID(of pid: Int32) -> String?
        func isBrowser(_ app: AppInfo?) -> Bool
        /// Whether a browser's page is still loading.
        func pageLoading(pid: Int32) async -> Bool
        /// Brings an app forward.
        func activate(pid: Int32)
        /// Whether `words` can be read on `screen` now (on-device text recognition);
        /// nil if it can't tell. Lets a scroll step see it's arrived without asking Claude.
        func screenShows(_ words: String, on screen: ScreenID) async -> Bool?
        /// The app's version ("14.2"), for tagging what Navi learns in it; nil if unknown.
        func version(of app: AppInfo?) -> String?
    }

    // MARK: The app around the engine

    /// What the person chose on a paused lesson's card.
    public enum PauseChoice: Int, CaseIterable {
        case didIt, showAgain, stuck, stop
        public var title: String { ["I did it", "Show me again", "I'm stuck", "Stop"][rawValue] }
    }

    /// The app the engine runs in: its status line, errors, Escape, clearing up, and
    /// the parts of a turn that are the platform's own (voice notices, typing, timers).
    public protocol Host: AnyObject {
        /// Navi is working ("Looking…"): keeps the last answer up, dimmed, if there is one.
        func showWorking(_ status: String, at p: CGPoint)
        func fail(_ error: Error, at p: CGPoint)
        /// Whether Escape stops Navi.
        func setEscape(_ on: Bool)
        func clearScreen()
        /// Puts Navi's light away after a moment.
        func restSoon(after delay: TimeInterval)
        /// The app in front may have changed: read it again.
        func refreshFrontApp()
        /// Before an answer plays: returns whether to read it aloud.
        func prepareTurn() -> Bool
        /// The answer has been shown: typing a [TYPE], hiding an empty caption.
        func answerShown(_ played: Tutor.Engine.Played, shots: [any Screenshot], anchor: CGPoint)
        /// After the answer and the lesson's next move: clearing later, hands-free.
        func turnFinished(_ played: Tutor.Engine.Played, speak: Bool, answerWanted: Bool, gen: Int)
        /// The lesson has ended.
        func lessonEnded()
        /// Lets them pick files or folders for this conversation (a MATERIAL offer).
        func chooseFiles()
    }

    /// The shell's watch over a lesson step: it reports clicks (`stepClicked`), the
    /// pointer resting on a HOVER (`hoverSample`), keys and new windows to the engine,
    /// and remembers how the step looked, to notice when it moves.
    public protocol LessonWatch: AnyObject {
        func watch(_ step: Walkthrough.Step)
        func stopWatching()
        /// A click while the next step is being worked out means they've moved on.
        func watchForActing(_ acted: @escaping () -> Void)
        func stopActWatch()
        func rememberLook(of step: Walkthrough.Step, in shots: [any Screenshot])
        /// After a scroll: whether the area around the step looks different from when it
        /// was armed (a page moved, not a map zooming under a toolbar); nil if it can't tell.
        func stepMoved(_ step: Walkthrough.Step) async -> Bool?
    }

    // MARK: Voice

    /// Reading answers aloud. Optional: Navi is text first, and a shell without
    /// a voice simply never gets asked to speak.
    public protocol Voice: AnyObject {
        func speak(_ text: String) async
        func stop()
    }

    // MARK: Keys

    /// The typing key (a tap of right ⌥ on the Mac by default). Escape stays the
    /// shell's own business: it reaches the engine as an event.
    public protocol Hotkey: AnyObject {
        var onTap: (() -> Void)? { get set }
        func start()
        func stop()
    }
}

public extension Shell.Overlay {
    /// A shell without its own acknowledgement just clears the step.
    func stepTaken() { clearSteps() }
}

public extension Notification.Name {
    /// Claude started a tool (a web search, reading a file): the wait is a lookup, worth
    /// saying so. The object is the tool's name.
    static let naviLookingUp = Notification.Name("NaviLookingUp")
    /// Where the wait for an answer has got to: the object is a `Shell.Waiting`.
    /// Posted from whatever thread the backend reads on.
    static let naviWaiting = Notification.Name("NaviWaiting")
}

public extension Shell {
    /// What Claude has said, before its first words, about what it's doing. Claude
    /// doesn't share what it's thinking, only that it is and roughly how much.
    enum Waiting: Equatable {
        /// The question has gone; Claude is reading the screenshot and the prompt.
        case sent
        /// Claude is thinking: a running estimate of its thinking so far, in tokens.
        case thinking(tokens: Int)
    }
}

public extension Shell.UIReader {
    /// A shell that can't read the screen leaves it to Claude.
    func screenShows(_ words: String, on screen: ScreenID) async -> Bool? { nil }
}

public extension Shell.Caption {
    /// A shell without links just doesn't offer them.
    func link(_ title: String, action: @escaping () -> Void) {}
    func endLink() {}
}

public extension Shell.Actions {
    func keep(_ k: Keep, done: @escaping (String?, String?) -> Void) { done(nil, "not available here") }
    /// Puts away an offer still waiting for an answer (a new turn has started).
    func cancelOffer() {}
}

public extension Shell.Overlay {
    /// "Show me": a shell without a ghost pointer draws the motion as an arrow.
    func drawDemo(_ points: [CGPoint], label: String?, on screen: ScreenID, delay: TimeInterval) {
        drawShape(.arrow, points, label: label, on: screen, delay: delay)
    }
}
