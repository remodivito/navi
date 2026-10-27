import Foundation

/// The type bar's placeholder: a small, rotating set that fits the moment (the
/// time of day, the app in front, the topic in hand, or what's been marked),
/// never the same one twice in a row.
public enum Greeting {
    private static var last = ""

    /// `fits`: whether a line fits the bar as it's laid out (a topic chip takes room).
    public static func pick(app: String? = nil, topic: String? = nil, marked: Bool = false, now: Date = Date(),
                            fits: (String) -> Bool = { _ in true }) -> String {
        let all = choices(app: app, topic: topic, marked: marked, now: now)
        let fitting = all.filter(fits)
        let options = fitting.isEmpty ? [all.min { $0.count < $1.count } ?? "Ask Navi"] : fitting
        let fresh = options.filter { $0 != last }
        let pick = (fresh.isEmpty ? options : fresh).randomElement() ?? "Ask Navi about your screen"
        last = pick
        return pick
    }

    /// Plain lines that say what you can do, never quiz you or chirp: no "Make sense?",
    /// no time-of-day banter.
    public static func choices(app: String?, topic: String?, marked: Bool, now: Date) -> [String] {
        if marked { return ["Ask about what you marked, or press ↩", "Press ↩ and I'll explain what you marked"] }
        if let topic { return ["Ask a follow-up", "Ask a follow-up, or something new", "More on \(topic), or something new"] }
        var list = ["Ask Navi", "Ask about your screen", "Ask how to do something"]
        if let app, !["Finder", "ScreenPointer", "Navi", "loginwindow", "Windows Explorer", "File Explorer", "NaviWin"].contains(app) {
            list += ["Ask about \(app)", "Ask how to do something in \(app)"]
        }
        return list
    }
}
