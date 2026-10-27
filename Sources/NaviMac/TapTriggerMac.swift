import AppKit

/// Watches the keys for the quick way to type to Navi and hands them to the
/// core's `TapDecider`, which decides what counts as a tap.
final class TapTrigger {
    typealias Mode = TapDecider.Mode
    static let tapLimit = TapDecider.tapLimit
    static let doubleWindow = TapDecider.doubleWindow

    private let decider = TapDecider()
    var mode: Mode { get { decider.mode } set { decider.mode = newValue } }
    var onTrigger: (() -> Void)? { get { decider.onTrigger } set { decider.onTrigger = newValue } }

    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flags(keyCode: e.keyCode, mods: e.modifierFlags) }
        let key: (NSEvent) -> Void = { [weak self] _ in self?.otherKey() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: key) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: { key($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        decider.reset()
    }

    /// AppKit's flags in the core's terms.
    static func mods(_ raw: NSEvent.ModifierFlags) -> TapDecider.Mods {
        let f = raw.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        var m: TapDecider.Mods = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.function) { m.insert(.function) }
        if f.contains(.help) { m.insert(.help) }
        return m
    }

    func flags(keyCode: UInt16, mods raw: NSEvent.ModifierFlags, at now: Date = Date()) {
        decider.flags(keyCode: keyCode, mods: Self.mods(raw), at: now)
    }

    func otherKey() { decider.otherKey() }

    /// Why a mode might clash on this Mac, if it might; Navi never changes the setting itself.
    static func conflict(_ mode: Mode) -> String? {
        guard mode == .fn else { return nil }
        var notes: [String] = []
        if !FnKey.globeIsFree { notes.append("The Globe key also opens emoji or switches input: set Keyboard › Press 🌐 key to › Do Nothing.") }
        if NSWorkspace.shared.runningApplications.contains(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains("wispr") }) {
            notes.append("Wispr Flow also uses Fn.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
