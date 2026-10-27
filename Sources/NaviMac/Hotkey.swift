import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon, with press and release. Unlike an event tap,
/// this needs no Accessibility permission.
final class Hotkey {
    private static var handlers: [UInt32: (Bool) -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// `handler(true)` on press, `handler(false)` on release.
    init(keyCode: Int, modifiers: Int, handler: @escaping (Bool) -> Void) {
        Hotkey.installHandlerOnce()
        id = Hotkey.nextID
        Hotkey.nextID += 1
        Hotkey.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x5350_5452), id: id) // 'SPTR'
        status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        let combo = Combo(keyCode: keyCode, modifiers: modifiers)
        if isRegistered { Hotkey.taken.remove(combo) } else { Hotkey.taken.insert(combo) }
        Hotkey.onRegistered?(combo, isRegistered)
    }

    /// What RegisterEventHotKey said: `eventHotKeyExistsErr` when another app owns the key.
    private(set) var status: OSStatus = noErr
    var isRegistered: Bool { status == noErr && ref != nil }

    struct Combo: Hashable { let keyCode: Int; let modifiers: Int }
    /// Keys that couldn't be registered, last time they were tried.
    private(set) static var taken: Set<Combo> = []
    static func isTaken(keyCode: Int, modifiers: Int) -> Bool { taken.contains(Combo(keyCode: keyCode, modifiers: modifiers)) }
    /// Told after every registration, so a failure can be said on screen (main.swift).
    static var onRegistered: ((Combo, Bool) -> Void)?

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Hotkey.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { Hotkey.handlers[hk.id]?(pressed) }
            return noErr
        }, specs.count, &specs, nil, nil)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    static func label(for event: NSEvent) -> String {
        var s = ""
        let f = event.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let key: String
        switch Int(event.keyCode) {
        case kVK_Space: key = "Space"
        case kVK_Return: key = "Return"
        case kVK_Tab: key = "Tab"
        default: key = (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        return s + key
    }
}
