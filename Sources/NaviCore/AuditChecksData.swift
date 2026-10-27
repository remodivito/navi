import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Checks added by the 2026-10-24 audit, one failing check per defect fixed.
/// Kept apart from the older check files so parallel fixes don't collide.
public enum AuditChecksData {
    @MainActor
    public static func run(_ check: (String, Bool) -> Void) async {
        // The owl's clock is wall time. When the clock is set back (the user changes
        // the time, NTP corrects it after sleep) `t` goes negative; the frame must
        // still come out rather than trap on an empty range. Before the fix this
        // check crashed the whole run instead of failing.
        let backwards = [Owl.Mood.thinking, .listening, .writing, .resting, .celebrate, .peek, .idle].map {
            Owl.frame($0, at: -0.7).grid.count == 11
        }
        check("owl frames survive a clock that went backwards", backwards.allSatisfy { $0 }
              && Owl.frame(.thinking, at: .nan).grid.count == 11 && Owl.frame(.writing, at: .infinity).grid.count == 11)

        // History: transcripts the index doesn't know (the index was corrupted, or
        // its write failed after the transcript's) would otherwise stay on disk for
        // good, since expiry only ever deletes what the index lists.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("navi-audit-history-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: tmp.appendingPathComponent("thread-history.json"))
        try? Data("{}".utf8).write(to: tmp.appendingPathComponent("transcript-orphan.json"))
        try? fm.createDirectory(at: tmp.appendingPathComponent("shots-orphan"), withIntermediateDirectories: true)
        let store = History(folder: tmp)
        check("history sweeps transcripts the index has lost", store.threads().isEmpty
              && !fm.fileExists(atPath: tmp.appendingPathComponent("transcript-orphan.json").path)
              && !fm.fileExists(atPath: tmp.appendingPathComponent("shots-orphan").path))

        // one versioned JSON file per topic. An older transcript without
        // the field still reads.
        let id = store.begin(title: "Where is Wi-Fi?")
        store.record(thread: id, kind: "question", action: "fresh", content: [Prompt.text("Where is Wi-Fi?")],
                     reply: "Top right.", error: nil, stats: nil)
        let raw = store.transcript(id).flatMap { _ in try? String(contentsOf: tmp.appendingPathComponent("transcript-\(id).json"), encoding: .utf8) } ?? ""
        let old = try? JSONDecoder().decode(History.Transcript.self, from: Data(#"{"id":"x","turns":[]}"#.utf8))
        check("transcripts carry a version and older ones still read", raw.contains("\"version\"") && old?.id == "x")

        // Expiry ran only when History was created, at launch. A menu bar app runs
        // for weeks, so a week-old discussion stayed until the next relaunch. Starting
        // a thread (and listing them) now expires the old ones first.
        let later = Date().addingTimeInterval(History.keepFor + 60)
        let next = store.begin(title: "And Bluetooth?", now: later)
        check("a week-old discussion goes when the next one starts, without a relaunch",
              store.threads().map(\.id) == [next] && store.transcript(id) == nil)
        try? fm.removeItem(at: tmp)

        // Conversation.send is not main-actor bound, so begin() and record() mutate
        // the index off the main thread while the History window reads it on main.
        // Hammering both at once: under `swift build --sanitize=thread` this check
        // reported two data races on the index before it was locked, none after.
        let tmp2 = fm.temporaryDirectory.appendingPathComponent("navi-audit-history-\(UUID().uuidString)", isDirectory: true)
        let busy = History(folder: tmp2)
        let writer = Task.detached {
            for n in 0..<400 {
                let t = busy.begin(title: "q\(n)")
                busy.record(thread: t, kind: "question", action: "fresh", content: [Prompt.text("q\(n)")], reply: "a", error: nil, stats: nil)
                if n % 50 == 49 { busy.clear() }
            }
        }
        var seen = 0
        for _ in 0..<4000 { seen = max(seen, busy.threads().count) }
        _ = await writer.value
        check("history survives a thread being recorded while the window reads", seen <= 400 && busy.threads().count <= 50)
        try? fm.removeItem(at: tmp2)

        // The decisions of 2026-10-26 (kept in their own file).
        await AuditChecksDecisions.run(check)
    }
}
