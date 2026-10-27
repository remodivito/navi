import Foundation

/// The quick way to type to Navi: a tap of one key on its own (right ⌥ by
/// default), or a double tap, chosen in the menu. ⌃⌥Space stays as the chord.
///
/// A tap only counts when the key goes down and up within 0.35 s with nothing
/// else pressed in between, so ⌥ and ⌘ shortcuts keep working. Watching
/// modifier keys needs only the Accessibility permission Navi already has.
///
/// This is the decision alone, on key codes and a platform-neutral modifier set,
/// so it can be tested and shared; the shell watches the keys and feeds it
/// (`TapTrigger` on the Mac). The key codes are the Mac's virtual key codes.
public final class TapDecider {
    /// The modifier keys that matter to a tap, whatever the platform calls them.
    public struct Mods: OptionSet, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Mods(rawValue: 1)
        public static let control = Mods(rawValue: 2)
        public static let option = Mods(rawValue: 4)
        public static let command = Mods(rawValue: 8)
        public static let function = Mods(rawValue: 16)
        /// The Help key flag, which the Mac reports with some keyboards.
        public static let help = Mods(rawValue: 32)
    }

    public enum Mode: String, CaseIterable {
        case rightOption, rightCommand, doubleCommand, doubleOption, fn, off

        public var title: String {
            switch self {
            case .rightOption: return "Tap right ⌥"
            case .rightCommand: return "Tap right ⌘"
            case .doubleCommand: return "Double-tap ⌘"
            case .doubleOption: return "Double-tap ⌥"
            case .fn: return "Tap Fn"
            case .off: return "Off (the shortcut only)"
            }
        }

        /// The keys (virtual key codes) that count for this mode.
        public var keys: Set<UInt16> {
            switch self {
            case .rightOption: return [61]
            case .rightCommand: return [54]
            case .doubleCommand: return [54, 55]
            case .doubleOption: return [58, 61]
            case .fn: return [63]
            case .off: return []
            }
        }

        public var flag: Mods {
            switch self {
            case .rightOption, .doubleOption: return .option
            case .rightCommand, .doubleCommand: return .command
            case .fn: return .function
            case .off: return []
            }
        }

        public var double: Bool { self == .doubleCommand || self == .doubleOption }
    }

    public var mode: Mode = .rightOption
    public var onTrigger: (() -> Void)?

    public init() {}

    public static let tapLimit: TimeInterval = 0.35
    public static let doubleWindow: TimeInterval = 0.4

    private var downAt: Date?
    private var dirty = false
    private var lastTap: Date?

    /// The decision, separate from the events so it can be tested.
    /// `mods` are the modifiers held after the change (Caps Lock and the keypad flag left out).
    public func flags(keyCode: UInt16, mods: Mods, at now: Date = Date()) {
        guard mode != .off else { return }
        if mode.keys.contains(keyCode) {
            if mods.contains(mode.flag) {
                // Pressed. Only a press on its own can become a tap.
                let others = mods.subtracting(mode == .fn ? [.function] : [mode.flag, .function])
                downAt = others.isEmpty ? now : nil
                dirty = !others.isEmpty
            } else if let down = downAt {
                // Released.
                downAt = nil
                if !dirty && now.timeIntervalSince(down) < Self.tapLimit { tapped(at: now) } else { lastTap = nil }
            }
        } else if downAt != nil {
            dirty = true   // another modifier joined in: a shortcut, not a tap
        } else if !mods.isEmpty {
            lastTap = nil
        }
    }

    /// Any key or click while the key is down (or between the taps of a double) means it wasn't a tap.
    public func otherKey() {
        if downAt != nil { dirty = true }
        lastTap = nil
    }

    private func tapped(at now: Date) {
        guard mode.double else { return onTrigger?() ?? () }
        if let last = lastTap, now.timeIntervalSince(last) < Self.doubleWindow {
            lastTap = nil
            onTrigger?()
        } else {
            lastTap = now
        }
    }

    /// Forgets a half-made tap (the shell stopped watching).
    public func reset() {
        downAt = nil
        lastTap = nil
    }
}
