import AppKit

/// Hold Fn (the Globe key) to talk to Navi, tap it to type: like Wispr Flow.
///
/// The system hotkey API can't register Fn on its own, so this watches the
/// modifier flags (covered by the Accessibility permission Navi already has).
/// Fn is also the key for Fn+arrows, Fn+Delete and the F-keys, so any other key
/// pressed while it's held turns the press into a combo and cancels it quietly.
final class FnKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Another key joined in (Fn+arrow and so on): undo the press without a trace.
    var onCancel: (() -> Void)?
    /// A quick tap of Fn on its own (under 0.35 s, no other key): open typing.
    var onTap: (() -> Void)?
    /// Whether holding Fn talks (onPress and onRelease); taps work either way.
    var holdTalks = false

    private var monitors: [Any] = []
    private var down = false
    private var combo = false
    private var downAt = Date.distantPast

    func start() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        let key: (NSEvent) -> Void = { [weak self] _ in self?.otherKey() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        down = false
    }

    /// A press starts only from the Fn key itself (key code 63): arrow and
    /// function keys also set the Fn flag on some keyboards.
    private func flagsChanged(_ e: NSEvent) {
        if !down && e.keyCode != 63 { return }
        flags(e.modifierFlags)
    }

    /// The decision, separate from the event so it can be tested.
    func flags(_ raw: NSEvent.ModifierFlags) {
        let mods = raw.intersection(.deviceIndependentFlagsMask)
        // Fn alone. Fn with Shift, Control and so on is someone else's shortcut.
        let fnAlone = mods.contains(.function) && mods.subtracting([.function, .capsLock, .numericPad]).isEmpty
        if fnAlone && !down {
            down = true
            combo = false
            downAt = Date()
            if holdTalks { onPress?() }
        } else if !mods.contains(.function) && down {
            down = false
            guard !combo else { return }
            if holdTalks { onRelease?() } else if Date().timeIntervalSince(downAt) < Self.tapLimit { onTap?() }
        } else if down && !fnAlone && !combo {
            combo = true
            if holdTalks { onCancel?() }
        }
    }

    func otherKey() {
        guard down, !combo else { return }
        combo = true
        if holdTalks { onCancel?() }
    }

    static let tapLimit: TimeInterval = 0.35

    /// Whether macOS leaves the Globe key alone ("Press 🌐 key to: Do Nothing").
    /// Otherwise a tap also opens emoji, switches input source or starts dictation.
    static var globeIsFree: Bool {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int == 0
    }
}
