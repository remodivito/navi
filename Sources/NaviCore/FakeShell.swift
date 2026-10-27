import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A shell with no screen: it records what the engine asks of it, in order.
/// It's the reference for what the protocols need (it compiles with Foundation
/// alone, so on every platform), and the engine's flow is tested against it.
public final class FakeShell {
    /// One request, as text: "draw point 10,20 label Add on 1".
    public private(set) var log: [String] = []
    public func clearLog() { log = [] }
    fileprivate func note(_ s: String) { log.append(s) }

    public let screens: Screens
    public let overlay: Overlay
    public let light: Light
    public let caption: Caption
    public let pause: Pause
    public let pill: Pill
    public let ui: UI
    public let host: Host
    public let watch: Watch
    public let errands: Errands

    public init(screens count: Int = 1) {
        screens = Screens(count: count)
        overlay = Overlay()
        light = Light()
        caption = Caption()
        pause = Pause()
        pill = Pill()
        ui = UI()
        host = Host()
        watch = Watch()
        errands = Errands()
        [screens as Part, overlay, light, caption, pause, pill, ui, host, watch, errands].forEach { $0.shell = self }
    }

    /// Each fake part writes into its shell's log.
    public class Part {
        fileprivate weak var shell: FakeShell?
        func note(_ s: String) { shell?.note(s) }
    }

    private static func p(_ p: CGPoint) -> String { "\(Int(p.x)),\(Int(p.y))" }

    /// 1440×900 points per display, side by side, screenshots at 2×.
    public struct Shot: Shell.Screenshot {
        public var screenID: ScreenID
        public var index: Int
        public var hasCursor: Bool
        public var origin: CGPoint
        public var pixelSize: CGSize { CGSize(width: 2880, height: 1800) }
        public var scale: CGFloat { 0.5 }
        public func global(_ pixel: CGPoint) -> CGPoint { CGPoint(x: origin.x + pixel.x * scale, y: origin.y + 900 - pixel.y * scale) }
        public func pixel(_ global: CGPoint) -> CGPoint { CGPoint(x: (global.x - origin.x) / scale, y: (origin.y + 900 - global.y) / scale) }
        public func lightness(near pixel: CGPoint) -> Double { 0.9 }
        public func jpeg() -> Data? { Data([0xFF, 0xD8]) }
    }

    public final class Screens: Part, Shell.ScreenSource {
        let count: Int
        public var pointerScreen: ScreenID = 1
        init(count: Int) { self.count = count }
        public func captureAll() async throws -> [any Shell.Screenshot] {
            note("capture")
            return (1...count).map { Shot(screenID: ScreenID($0), index: $0, hasCursor: ScreenID($0) == pointerScreen, origin: CGPoint(x: CGFloat($0 - 1) * 1440, y: 0)) }
        }
        public func screenUnderPointer() -> ScreenID { pointerScreen }
        public func frame(of screen: ScreenID) -> CGRect? {
            screen >= 1 && Int(screen) <= count ? CGRect(x: CGFloat(screen - 1) * 1440, y: 0, width: 1440, height: 900) : nil
        }
        public func waitForSettle(_ screen: ScreenID, timeout: TimeInterval) async -> Bool { true }
        public var pointer = CGPoint(x: 700, y: 450)
        public func pointerLocation() -> CGPoint { pointer }
    }

    public final class Overlay: Part, Shell.Overlay {
        public private(set) var marks: [CGRect] = []
        public func drawPoint(_ pt: CGPoint, label: String?, snapped: CGRect?, on screen: ScreenID, delay: TimeInterval) {
            marks.append(CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20))
            note("point \(FakeShell.p(pt)) \(label ?? "-") on \(screen)")
        }
        public func drawTarget(_ pt: CGPoint, radius: CGFloat, label: String?, snapped: CGRect?, hover: Bool, on screen: ScreenID, delay: TimeInterval) {
            marks.append(CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2))
            note("\(hover ? "hover" : "target") \(FakeShell.p(pt)) r\(Int(radius)) \(label ?? "-") on \(screen)")
        }
        public func drawHighlight(_ r: CGRect, label: String?, on screen: ScreenID, delay: TimeInterval) {
            marks.append(r); note("highlight \(FakeShell.p(r.origin)) \(label ?? "-") on \(screen)")
        }
        public func drawShape(_ kind: ShapeKind, _ points: [CGPoint], label: String?, on screen: ScreenID, delay: TimeInterval) {
            note("shape \(kind.rawValue) \(points.map(FakeShell.p).joined(separator: ";")) \(label ?? "-") on \(screen)")
        }
        public func write(_ text: String, at pt: CGPoint, anchor: CGPoint?, on screen: ScreenID, delay: TimeInterval) { note("write \"\(text)\" at \(FakeShell.p(pt)) on \(screen)") }
        public func transformWrite(at pt: CGPoint, to text: String, on screen: ScreenID) -> CGRect? { nil }
        public func writingWidth(_ text: String) -> CGFloat { CGFloat(text.count) * 12 }
        public func setStrokeTime(_ seconds: TimeInterval, on screen: ScreenID) {}
        public func writeSpot(_ text: String, at pt: CGPoint, on screen: ScreenID) -> CGPoint { pt }
        public func setInk(_ ink: Colour?, letters: [Character: Colour], on screen: ScreenID) { note("ink \(ink.map { "#" + ($0.hex ?? "rgb").replacingOccurrences(of: "#", with: "") } ?? "default")") }
        public func clearSteps() { note("clear steps") }
        public func stepTaken() { note("step taken") }
        public func fadeDrawings() { note("fade") }
        public func clearAll() { marks = []; note("clear all") }
        public var hasDrawings: Bool { !marks.isEmpty }
        public func hasDrawings(on screen: ScreenID) -> Bool { !marks.isEmpty }
        public var markAreas: [CGRect] { marks }
    }

    public final class Light: Part, Shell.Companion {
        public var confidence: CGFloat = 1
        public private(set) var state = Shell.LightState.idle
        public func set(_ state: Shell.LightState) { self.state = state; note("light \(state)") }
        public func fly(to pt: CGPoint, clear: CGFloat) { note("fly \(FakeShell.p(pt))") }
        public func trace(_ points: [CGPoint]) -> TimeInterval { note("trace \(points.count) points"); return 0 }
        public func traceTime(_ points: [CGPoint]) -> TimeInterval { 0 }
        public func glide(to pt: CGPoint) { note("glide \(FakeShell.p(pt))") }
        public func roam(in r: CGRect) { note("roam") }
        public func tint(_ tint: Shell.LightTint) { note("tint \(tint)") }
        public func glow(_ colour: Colour) { note("glow") }
        public func summon() { note("summon") }
        public func comeBack() { note("come back") }
        public func rest(after delay: TimeInterval) { note("rest") }
    }

    public final class Caption: Part, Shell.Caption {
        public private(set) var lines: [String] = []
        public private(set) var isShowing = false
        public private(set) var isDocked = false
        public private(set) var answering = false
        public var onWordLit: ((Int) -> Void)?
        public var practiceHow: String?
        public private(set) var kicker: String?
        public func setKicker(_ text: String?) { kicker = text; if let text { note("kicker \(text)") } }
        public var onAnswer: ((String) -> Void)?
        public var onHelp: ((Shell.AnswerHelp) -> Void)?
        public var onAnswerCancel: (() -> Void)?
        public func show(status: String, at pt: CGPoint) { isShowing = true; note("status \(status)") }
        public func read(_ sentence: String, named: [String], at pt: CGPoint, near: CGPoint?, wordsPerSecond: Double,
                         colour: Colour?, practice: Bool, stay: Bool, pauses: Set<Int>) {
            isShowing = true
            lines.append(sentence)
            note("say \(practice ? "(your turn) " : "")\(sentence)")
            for i in sentence.split(separator: " ").indices { onWordLit?(i) }
        }
        public func say(_ sentence: String, named: [String], at pt: CGPoint, near: CGPoint?, colour: Colour?, practice: Bool, stay: Bool) {
            isShowing = true; lines.append(sentence); note("say aloud \(sentence)")
        }
        public func voiceDone() {}
        public func answerDone(holdUntilStep: Bool) { note(holdUntilStep ? "done, holding" : "done") }
        public func awaitNext() -> Bool { isShowing }
        public func dockIfClear() -> Bool { isDocked = true; return true }
        public func floatIfCovering() {}
        public func hide() { isShowing = false; isDocked = false; answering = false; note("hide") }
        public func takeAnswer() { answering = true; note("answer line") }
        public func endAnswer() { answering = false }
        /// What the user would do: type an answer, ask for help, or press Esc.
        public func type(_ answer: String) { onAnswer?(answer) }
        public func ask(_ help: Shell.AnswerHelp) { onHelp?(help) }
        public func escape() { onAnswerCancel?() }
        /// The link offered under the words, and what the user would do: click it.
        public private(set) var link: String?
        private var linkAction: (() -> Void)?
        public func link(_ title: String, action: @escaping () -> Void) { link = title; linkAction = action; note("link \(title)") }
        public func endLink() { link = nil; linkAction = nil }
        public func clickLink() { let a = linkAction; endLink(); a?() }
    }

    public final class Pause: Part, Shell.PauseCard {
        public private(set) var isShown = false
        public func show(kicker: String, text: String, on screen: ScreenID) { isShown = true; note("pause card: \(kicker)") }
        public func hide() { isShown = false }
    }

    public final class Pill: Part, Shell.TopicPill {
        public private(set) var isShown = false
        public func show(_ topic: String, on screen: ScreenID) { isShown = true; note("pill \(topic)") }
        public func hide() { isShown = false }
    }

    public final class UI: Part, Shell.UIReader {
        public var app: Shell.AppInfo? = Shell.AppInfo(bundleID: "org.qgis.qgis", name: "QGIS", pid: 42)
        public var passwordFieldFocused = false
        public func frontApp() -> Shell.AppInfo? { app }
        public func context(for app: Shell.AppInfo?) async -> (text: String?, host: String?) { ("Frontmost app: \(app?.name ?? "unknown")", nil) }
        public func snap(_ pt: CGPoint, on screen: ScreenID, app: Shell.AppInfo?) async -> CGRect? { nil }
        public func insert(_ text: String, at pt: CGPoint?, app: Shell.AppInfo?) -> String? { note("type \"\(text)\""); return nil }
        /// Which app owns the window under the pointer (the lesson's app unless a test says otherwise).
        public var owner: Int32? = 42
        public func windowOwner(at pt: CGPoint) -> Int32? { owner }
        public func frontmostPID() -> Int32? { app?.pid }
        public func bundleID(of pid: Int32) -> String? { pid == app?.pid ? app?.bundleID : nil }
        /// What reading the screen finds (nil: can't tell).
        public var shows: Bool? = nil
        public func screenShows(_ words: String, on screen: ScreenID) async -> Bool? { note("read screen for \(words)"); return shows }
        public func isBrowser(_ app: Shell.AppInfo?) -> Bool { false }
        public func pageLoading(pid: Int32) async -> Bool { false }
        public func activate(pid: Int32) { note("activate \(pid)") }
        public var appVersion: String? = "3.34.2"
        public func version(of app: Shell.AppInfo?) -> String? { appVersion }
    }

    public final class Host: Part, Shell.Host {
        public var speak = false
        public func showWorking(_ status: String, at pt: CGPoint) { note("working \(status)") }
        public func fail(_ error: Error, at pt: CGPoint) { note("fail") }
        public func setEscape(_ on: Bool) {}
        public func clearScreen() { note("clear screen") }
        public func restSoon(after delay: TimeInterval) {}
        public func refreshFrontApp() {}
        public func prepareTurn() -> Bool { speak }
        public func answerShown(_ played: Tutor.Engine.Played, shots: [any Shell.Screenshot], anchor: CGPoint) {}
        public func turnFinished(_ played: Tutor.Engine.Played, speak: Bool, answerWanted: Bool, gen: Int) { note("turn finished") }
        public func lessonEnded() { note("lesson ended") }
        public func chooseFiles() { note("choose files") }
    }

    public final class Errands: Part, Shell.Actions {
        /// What the next download offer is answered with (a saved path, or nil for "Not now").
        public var downloadAnswer: String? = "/Users/me/Downloads/model.xml"
        public func open(_ target: String, with app: String?) -> String? {
            note("open \(target)\(app.map { " in \($0)" } ?? "")")
            return nil
        }
        public func keep(_ k: Keep, done: @escaping (String?, String?) -> Void) {
            note("keep \(k.kind.rawValue) \(k.detail ?? "") \(k.text)")
            done("kept", nil)
        }
        public func offerDownload(_ url: String, done: @escaping (String?, String?) -> Void) {
            note("offer download \(url)")
            done(downloadAnswer, downloadAnswer == nil ? "they said not now" : nil)
        }
    }

    public final class Watch: Part, Shell.LessonWatch {
        public private(set) var watching: Walkthrough.Step?
        public private(set) var acted: (() -> Void)?
        public func watch(_ step: Walkthrough.Step) { watching = step; note("watch \(step.label)") }
        public func stopWatching() { watching = nil }
        public func watchForActing(_ acted: @escaping () -> Void) { self.acted = acted }
        public func stopActWatch() { acted = nil }
        public func rememberLook(of step: Walkthrough.Step, in shots: [any Shell.Screenshot]) {}
        /// What the next "did the step move?" check finds.
        public var moved: Bool? = true
        public func stepMoved(_ step: Walkthrough.Step) async -> Bool? { moved }
    }
}
