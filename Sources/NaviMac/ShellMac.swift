import AppKit
import NaviCore

// The Mac's side of the shell protocols (NaviCore/Shell.swift): the AppKit
// classes that already do the work, conforming directly where their shape
// matches, plus small adapters where it doesn't. AppController still calls the
// classes directly for now; the engine will call them through these.

extension Capture {
    /// The display with this id, if it's still connected.
    static func screen(_ id: ScreenID) -> NSScreen? {
        NSScreen.screens.first { displayID($0) == id }
    }
}

extension ScreenShot: Shell.Screenshot {
    var screenID: ScreenID { Capture.displayID(screen) }
    func global(_ pixel: CGPoint) -> CGPoint { globalPoint(pixel) }
    func lightness(near pixel: CGPoint) -> Double { Double(lightness(around: pixel)) }
    func jpeg() -> Data? { Capture.jpeg(image) }
}

/// Screens through ScreenCaptureKit.
final class MacScreens: Shell.ScreenSource {
    func captureAll() async throws -> [any Shell.Screenshot] { try await Capture.takeAll() }
    func screenUnderPointer() -> ScreenID { Capture.displayID(Capture.screenUnderMouse()) }
    func frame(of screen: ScreenID) -> CGRect? { Capture.screen(screen)?.frame }
    func waitForSettle(_ screen: ScreenID, timeout: TimeInterval) async -> Bool {
        guard let s = Capture.screen(screen) else { return true }
        return await Capture.waitForSettle(screen: s, timeout: timeout)
    }
    func pointerLocation() -> CGPoint { NSEvent.mouseLocation }
}

extension OverlayManager: Shell.Overlay {
    /// The display's canvas and how to turn global points into its own.
    private func canvas(_ screen: ScreenID) -> (OverlayView, (CGPoint) -> CGPoint)? {
        guard let s = Capture.screen(screen), let v = view(for: s) else { return nil }
        let f = s.frame
        return (v, { CGPoint(x: $0.x - f.minX, y: $0.y - f.minY) })
    }
    private func local(_ r: CGRect?, _ map: (CGPoint) -> CGPoint) -> CGRect? {
        r.map { CGRect(origin: map($0.origin), size: $0.size) }
    }
    private var sketchy: Bool { Settings.shared.sketch }

    func drawPoint(_ p: CGPoint, label: String?, snapped: CGRect?, on screen: ScreenID, delay: TimeInterval) {
        guard let (v, map) = canvas(screen) else { return }
        v.drawPoint(map(p), label: label, snapped: local(snapped, map), delay: delay)
    }
    func drawTarget(_ p: CGPoint, radius: CGFloat, label: String?, snapped: CGRect?, hover: Bool, on screen: ScreenID, delay: TimeInterval) {
        guard let (v, map) = canvas(screen) else { return }
        v.drawTarget(map(p), radius: radius, label: label, snapped: local(snapped, map), delay: delay, hover: hover)
    }
    func drawHighlight(_ r: CGRect, label: String?, on screen: ScreenID, delay: TimeInterval) {
        guard let (v, map) = canvas(screen), let lr = local(r, map) else { return }
        v.drawHighlight(lr, label: label, sketchy: sketchy, delay: delay)
    }
    func drawShape(_ kind: ShapeKind, _ points: [CGPoint], label: String?, on screen: ScreenID, delay: TimeInterval) {
        guard let (v, map) = canvas(screen) else { return }
        v.drawShape(kind, points.map(map), label: label, sketchy: sketchy, delay: delay)
    }
    func drawDemo(_ points: [CGPoint], label: String?, on screen: ScreenID, delay: TimeInterval) {
        guard let (v, map) = canvas(screen) else { return }
        v.drawDemo(points.map(map), label: label, delay: delay)
    }
    func write(_ text: String, at p: CGPoint, anchor: CGPoint?, on screen: ScreenID, delay: TimeInterval) {
        guard let (v, map) = canvas(screen) else { return }
        v.drawWrite(text, at: map(p), anchor: anchor.map(map), delay: delay)
    }
    func transformWrite(at p: CGPoint, to text: String, on screen: ScreenID) -> CGRect? {
        guard let s = Capture.screen(screen), let (v, map) = canvas(screen),
              let line = v.transformWrite(at: map(p), to: text) else { return nil }
        return line.offsetBy(dx: s.frame.minX, dy: s.frame.minY)
    }
    func writingWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: OverlayView.writingFont(size: 28)]).width
    }
    func setStrokeTime(_ seconds: TimeInterval, on screen: ScreenID) {
        canvas(screen)?.0.strokeTime = seconds
    }
    func writeSpot(_ text: String, at p: CGPoint, on screen: ScreenID) -> CGPoint {
        guard let s = Capture.screen(screen), let (v, map) = canvas(screen) else { return p }
        let spot = v.writeSpot(text, at: map(p))
        return CGPoint(x: spot.x + s.frame.minX, y: spot.y + s.frame.minY)
    }
    func setInk(_ ink: Colour?, letters: [Character: Colour], on screen: ScreenID) {
        guard let (v, _) = canvas(screen) else { return }
        v.markInk = ink.map(Look.colour) ?? OverlayView.ink
        v.letterColours = letters.mapValues(Look.colour)
    }
    func clearSteps() { views.forEach { $0.clearSteps() } }
    func stepTaken() { views.forEach { $0.stepTaken() } }
    func fadeDrawings() { views.forEach { $0.fadeDrawings() } }
    var hasDrawings: Bool { views.contains { $0.hasDrawings } }
    func hasDrawings(on screen: ScreenID) -> Bool { canvas(screen)?.0.hasDrawings == true }
    var markAreas: [CGRect] { occupied() }
}

extension Buddy: Shell.Companion {
    func glow(_ colour: Colour) { glow(Look.colour(colour)) }
}

extension Caption: Shell.Caption {
    func show(status: String, at p: CGPoint) { show(status, style: .status, at: p) }
    func read(_ sentence: String, named: [String], at p: CGPoint, near: CGPoint?, wordsPerSecond: Double,
              colour: Colour?, practice: Bool, stay: Bool, pauses: Set<Int>) {
        let ink: NSColor? = colour.map(Look.colour)
        read(sentence, named: named, at: p, near: near, wordsPerSecond: wordsPerSecond, colour: ink,
             practice: practice, stay: stay, pauses: pauses)
    }
}

extension Caption {
    func say(_ sentence: String, named: [String], at p: CGPoint, near: CGPoint?, colour: Colour?, practice: Bool, stay: Bool) {
        let ink: NSColor? = colour.map(Look.colour)
        say(sentence, named: named, at: p, near: near, colour: ink, practice: practice, stay: stay)
    }
}

extension Narrator: Shell.Voice {}

extension PauseCard: Shell.PauseCard {
    func show(kicker: String, text: String, on screen: ScreenID) {
        show(kicker: kicker, text: text, on: Capture.screen(screen) ?? Capture.screenUnderMouse())
    }
}

extension TopicPill: Shell.TopicPill {
    func show(_ topic: String, on screen: ScreenID) {
        show(topic, on: Capture.screen(screen) ?? Capture.screenUnderMouse())
    }
}

/// The app in front, through the Accessibility API.
final class MacUIReader: Shell.UIReader {
    private func running(_ app: Shell.AppInfo?) -> NSRunningApplication? {
        app.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
    }
    func frontApp() -> Shell.AppInfo? {
        NSWorkspace.shared.frontmostApplication.map {
            Shell.AppInfo(bundleID: $0.bundleIdentifier, name: $0.localizedName, pid: $0.processIdentifier)
        }
    }
    func context(for app: Shell.AppInfo?) async -> (text: String?, host: String?) {
        let a = running(app)
        let c = await Task.detached { AX.frontContext(for: a) }.value
        return (c.text, c.host)
    }
    func snap(_ p: CGPoint, on screen: ScreenID, app: Shell.AppInfo?) async -> CGRect? {
        guard let s = Capture.screen(screen) else { return nil }
        let pid = app?.pid
        return await Task.detached { AX.snap(p, on: s, frontPID: pid) }.value
    }
    func insert(_ text: String, at p: CGPoint?, app: Shell.AppInfo?) -> String? {
        let outcome = AX.insert(text, at: p, frontPID: app?.pid)
        switch outcome {
        case .typed, .pasted: return nil
        default: return outcome.message
        }
    }
    var passwordFieldFocused: Bool { AX.passwordFieldFocused }
    func windowOwner(at p: CGPoint) -> Int32? { AppController.windowOwner(at: p) }
    func frontmostPID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func bundleID(of pid: Int32) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
    func isBrowser(_ app: Shell.AppInfo?) -> Bool { AX.isBrowser(running(app)) }
    /// Off the main thread: Accessibility calls can block on a busy app.
    func pageLoading(pid: Int32) async -> Bool { await Task.detached { AX.pageLoading(pid: pid) }.value }
    func activate(pid: Int32) { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
    func version(of app: Shell.AppInfo?) -> String? {
        running(app)?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }
    func screenShows(_ words: String, on screen: ScreenID) async -> Bool? {
        guard let s = Capture.screen(screen) else { return nil }
        return await Capture.shows(words, on: s)
    }
}

extension TapTrigger: Shell.Hotkey {
    var onTap: (() -> Void)? {
        get { onTrigger }
        set { onTrigger = newValue }
    }
}

/// Navi's secrets, in the Keychain.
final class MacSecrets: Shell.Secrets {
    var claudeToken: String? { Keychain.claudeToken }
    var apiKey: String? { Keychain.apiKey }
}

/// Claude Code on a Mac: the usual install places, and its own bin directory on the PATH.
final class MacClaudeLocator: Shell.ClaudeLocator {
    func executable() -> String? { ClaudeCode.executable() }
    func path(for exe: String, inherited: String?) -> String { ClaudeCode.path(for: exe, inherited: inherited) }
}

extension ClaudeAccess {
    /// The Mac's secrets, locator and status report; set before any request.
    static func useMac() {
        secrets = MacSecrets()
        locator = MacClaudeLocator()
        report = { result, backend in Connection.report(result, via: backend) }
    }
}
