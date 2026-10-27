import Foundation

/// Where Navi keeps its files: one folder of its own in Application Support, and
/// its log. Earlier builds used a ScreenPointer folder; it moves over the
/// first time, so history and skills carry on.
public enum NaviFiles {
    public static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Navi", isDirectory: true)
        let old = base.appendingPathComponent("ScreenPointer", isDirectory: true)
        if !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: folder)
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// ~/Library/Logs/Navi.log (the app's own log; a terminal run prints instead).
    public static let log: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Navi.log")

    /// ~/Library/Logs/Navi.previous.log: the log before it last reached 2 MB.
    public static let previousLog: URL = log.deletingLastPathComponent().appendingPathComponent("Navi.previous.log")

    /// A developer setting from the environment: NAVI_<name>, or the older SCREENPOINTER_<name>.
    public static func environment(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env["NAVI_" + name] ?? env["SCREENPOINTER_" + name]
    }
}
