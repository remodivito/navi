import Foundation

/// Timestamped line on stdout, for following a session (and for tests).
/// Lives in the core so the teaching logic can log the same way on any platform.
///
/// `content: true` marks a line that carries the user's words or Claude's (a question,
/// a reply, a beat's sentence, a label or link Claude chose). Those still print, but only
/// development builds keep them in Navi.log; other builds log events and timings only
/// (decision 4, 2026-10-26).
public func trace(_ s: String, content: Bool = false) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(f.string(from: Date()))] \(s)"
    print(line)
    fflush(stdout)
    // The app bundle has no terminal, so it also keeps ~/Library/Logs/Navi.log.
    guard Bundle.main.bundlePath.hasSuffix(".app"), Trace.keeps(content: content) else { return }
    Trace.append(line, to: NaviFiles.log, previous: NaviFiles.previousLog)
}

/// Navi.log: what it keeps, its size and its permissions.
public enum Trace {
    /// Whether the log keeps the user's words and Claude's: development builds (a
    /// `.dev-build` file next to Package.swift) only.
    public static var logsContent: Bool = {
        #if SP_DEV_SCREENSHOTS
        return true
        #else
        return false
        #endif
    }()

    /// Whether a line goes into the log file.
    public static func keeps(content: Bool) -> Bool { !content || logsContent }

    /// Past this, the log moves to Navi.previous.log (replacing an older one) and starts afresh.
    public static let rotateAt: UInt64 = 2 * 1024 * 1024

    private static let lock = NSLock()

    /// Appends `line` to the log at `url`, rotating it to `previous` once it reaches
    /// `rotateAt`. The file is created readable by the user alone (0600), and an older
    /// log with looser permissions is tightened.
    public static func append(_ line: String, to url: URL, previous: URL, rotateAt limit: UInt64 = rotateAt) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size >= limit {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
        }
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else if let perms = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, perms & 0o077 != 0 {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
    }
}
