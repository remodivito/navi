import Foundation

public enum Backend: String {
    case cli, api
}

/// UserDefaults-backed preferences, edited from the menu bar.
///
/// The hotkey defaults are the Mac's Carbon key code and modifier mask, written
/// as plain numbers so the core needs no Carbon. A Windows shell would read
/// them as its own (or keep its hotkey elsewhere); everything else is shared.
public final class Settings {
    public static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        Self.registerShortcutDefault(d)
        d.register(defaults: [
            "backend": NaviFiles.environment("BACKEND") == "api" ? "api" : "cli",
            "backendChosen": NaviFiles.environment("BACKEND") != nil,
            "claudePath": "",
            "model": "sonnet",
            "effort": "medium",
            "voice": true,
            "sketch": true,
            "snap": false,
            "speak": false,
            "buddy": true,
            "naviAlways": false,
            "fnKey": false,
            "fnTap": false,
            "typeTrigger": "rightOption",
            "followUpMinutes": 2.0,
            "duck": true,
            "handsFree": false,
            "voiceID": "",
            "onboarded": false,
            "context": true,
            "readFiles": true,
            "showInRecordings": false,
        ])
        // Text first (2026-10-22): Navi writes rather than speaks, and Fn doesn't
        // talk, for now. Switch both off once for anyone who had them on.
        if !d.bool(forKey: "textFirst") {
            d.set(false, forKey: "speak")
            d.set(false, forKey: "fnKey")
            d.set(true, forKey: "textFirst")
        }
        // Voice switches were briefly in Settings and turning them on crashed the mic
        // (2026-10-24): text-first again, voice off.
        if !d.bool(forKey: "voiceOffAgain") {
            d.set(false, forKey: "voice")
            d.set(false, forKey: "speak")
            d.set(false, forKey: "handsFree")
            d.set(true, forKey: "voiceOffAgain")
        }
        // Fn clashed with the Globe key: tapping right ⌥ replaces it (2026-10-22).
        if !d.bool(forKey: "tapTriggerMoved") {
            d.set(false, forKey: "fnTap")
            d.set("rightOption", forKey: "typeTrigger")
            d.set(true, forKey: "tapTriggerMoved")
        }
        // Someone who picked a backend before connections were detected keeps it.
        if let saved = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ""),
           saved["backendChosen"] == nil, saved["backend"] != nil {
            d.set(true, forKey: "backendChosen")
        }
    }

    /// The shortcut for anyone who never chose one: ⌃⌥N (2026-10-26). It was ⌃⌥Space,
    /// which is macOS's own "Select the previous input source". A default only, so
    /// a shortcut someone recorded (saved in their defaults) is kept.
    public static func registerShortcutDefault(_ d: UserDefaults) {
        d.register(defaults: [
            "hotkeyCode": 45,                  // kVK_ANSI_N
            "hotkeyMods": 4096 | 2048,         // Carbon controlKey | optionKey
            "hotkeyLabel": "⌃⌥N",
        ])
    }

    public var hotkeyCode: Int { get { d.integer(forKey: "hotkeyCode") } set { d.set(newValue, forKey: "hotkeyCode") } }
    public var hotkeyMods: Int { get { d.integer(forKey: "hotkeyMods") } set { d.set(newValue, forKey: "hotkeyMods") } }
    public var hotkeyLabel: String { get { d.string(forKey: "hotkeyLabel") ?? "" } set { d.set(newValue, forKey: "hotkeyLabel") } }

    public var backend: Backend {
        get { Backend(rawValue: d.string(forKey: "backend") ?? "") ?? .cli }
        set { d.set(newValue.rawValue, forKey: "backend") }
    }
    /// False until the user picks a connection or the first run picks one that
    /// works (see `Connection.chooseOnFirstRun`).
    public var backendChosen: Bool { get { d.bool(forKey: "backendChosen") } set { d.set(newValue, forKey: "backendChosen") } }
    /// A `claude` the user located by hand; "" means search for it.
    public var claudePath: String { get { d.string(forKey: "claudePath") ?? "" } set { d.set(newValue, forKey: "claudePath") } }
    /// "" means the backend's default (Claude Code's own setting, or Opus 5.5 for the API).
    public var model: String { get { d.string(forKey: "model") ?? "" } set { d.set(newValue, forKey: "model") } }
    public var effort: String { get { d.string(forKey: "effort") ?? "medium" } set { d.set(newValue, forKey: "effort") } }

    public var voice: Bool { get { d.bool(forKey: "voice") } set { d.set(newValue, forKey: "voice") } }
    public var sketch: Bool { get { d.bool(forKey: "sketch") } set { d.set(newValue, forKey: "sketch") } }
    public var snap: Bool { get { d.bool(forKey: "snap") } set { d.set(newValue, forKey: "snap") } }
    public var context: Bool { get { d.bool(forKey: "context") } set { d.set(newValue, forKey: "context") } }
    /// Read answers aloud.
    public var speak: Bool { get { d.bool(forKey: "speak") } set { d.set(newValue, forKey: "speak") } }
    /// The blue companion cursor that follows the pointer.
    public var buddy: Bool { get { d.bool(forKey: "buddy") } set { d.set(newValue, forKey: "buddy") } }
    /// Navi always beside the pointer, rather than appearing when needed.
    public var naviAlways: Bool { get { d.bool(forKey: "naviAlways") } set { d.set(newValue, forKey: "naviAlways") } }
    /// Hold Fn (Globe) to talk, tap it to type, as well as the shortcut.
    /// The quick way to type to Navi (TapTrigger.Mode), as well as the shortcut.
    public var typeTrigger: String { get { d.string(forKey: "typeTrigger") ?? "rightOption" } set { d.set(newValue, forKey: "typeTrigger") } }
    /// Tap Fn to type (holding it is left to other apps, like Wispr Flow). Replaced by `typeTrigger`.
    public var fnTap: Bool { get { d.bool(forKey: "fnTap") } set { d.set(newValue, forKey: "fnTap") } }
    /// How long after an answer a question still counts as a follow-up.
    public var followUpMinutes: Double { get { d.double(forKey: "followUpMinutes") } set { d.set(newValue, forKey: "followUpMinutes") } }
    public var fnKey: Bool { get { d.bool(forKey: "fnKey") } set { d.set(newValue, forKey: "fnKey") } }
    /// Lower other audio while the user is talking.
    public var duck: Bool { get { d.bool(forKey: "duck") } set { d.set(newValue, forKey: "duck") } }
    /// After an answer, keep listening for a follow-up (headphones only).
    public var handsFree: Bool { get { d.bool(forKey: "handsFree") } set { d.set(newValue, forKey: "handsFree") } }
    /// AVSpeechSynthesisVoice identifier; "" picks the best installed English voice.
    public var voiceID: String { get { d.string(forKey: "voiceID") ?? "" } set { d.set(newValue, forKey: "voiceID") } }
    public var onboarded: Bool { get { d.bool(forKey: "onboarded") } set { d.set(newValue, forKey: "onboarded") } }
    /// Claude may look, read-only, at installed apps, files and past conversations.
    public var readFiles: Bool { get { d.bool(forKey: "readFiles") } set { d.set(newValue, forKey: "readFiles") } }
    public var showInRecordings: Bool { get { d.bool(forKey: "showInRecordings") } set { d.set(newValue, forKey: "showInRecordings") } }
}
