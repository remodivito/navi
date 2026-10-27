import AppKit

/// Crash reports that stay on the Mac. macOS already writes one when Navi crashes
/// (~/Library/Logs/DiagnosticReports/Navi-*.ips); on the next launch Navi notices it
/// and offers to show it, so a tester can attach it to an issue. Nothing is sent.
/// An Objective-C exception's reason also goes into Navi.log before the app goes down.
enum CrashReports {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    private static let seenKey = "crashReportsSeenUntil"

    /// At launch: log exceptions, then look for a report from the last run.
    static func start() {
        NSSetUncaughtExceptionHandler { e in
            trace("Crash: \(e.name.rawValue): \(e.reason ?? "no reason")\n" + e.callStackSymbols.prefix(12).joined(separator: "\n"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { offerLatest() }
    }

    /// Navi's reports, newest first.
    static func reports() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("Navi-") && ["ips", "crash"].contains($0.pathExtension) }
            .sorted { modified($0) > modified($1) }
    }

    private static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The first few lines that say what happened: the exception and the top of Navi's own frames.
    static func summary(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return url.lastPathComponent }
        let body = text.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? text
        guard let d = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return url.lastPathComponent }
        let exc = (d["exception"] as? [String: Any]).map { "\($0["type"] ?? "?") \($0["signal"] ?? "")" } ?? "?"
        let version = (d["bundleInfo"] as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "?"
        var lines = ["Navi \(version) crashed: \(exc)"]
        if let threads = d["threads"] as? [[String: Any]], let images = d["usedImages"] as? [[String: Any]] {
            let faulting = d["faultingThread"] as? Int ?? 0
            let frames = (threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] : nil) ?? []
            for f in frames.prefix(16) {
                let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
                lines.append("  \(image)  \(f["symbol"] as? String ?? "?")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A report newer than the last one offered: say so once, with a way to show or copy it.
    private static func offerLatest() {
        guard let latest = reports().first else { return }
        let when = modified(latest)
        let seen = UserDefaults.standard.object(forKey: seenKey) as? Date ?? .distantPast
        guard when > seen, Date().timeIntervalSince(when) < 3 * 24 * 3600 else { return }
        UserDefaults.standard.set(when, forKey: seenKey)
        trace("Found a crash report from the last run: \(latest.lastPathComponent)")
        let alert = NSAlert()
        alert.messageText = "Navi quit unexpectedly last time"
        alert.informativeText = "Sorry about that. A crash report is saved on your Mac (nothing was sent). If you'd like to help fix it, "
            + "Report opens a GitHub issue with a short summary of the crash filled in, for you to look over and submit."
        alert.addButton(withTitle: "Report…")
        alert.addButton(withTitle: "Show report")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ReportProblem.open(crashSummary: summary(of: latest))
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        default: break
        }
    }
}
