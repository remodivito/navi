// Runs NaviCore's self-tests without any platform shell, so the core can be
// checked on every platform: `swift run navi-core-check`. The engine checks
// play whole answers on the fake shell.
import Foundation
import NaviCore

var passed = 0
var failed = 0
func report(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if ok { passed += 1 } else { failed += 1 }
}
Bookmarks.useScratch()   // no check touches the user's kept lessons
Skills.useScratch()      // or their skills
CoreSelfTest.run(report)
Task { @MainActor in
    await EngineChecks.run(report)
    await AuditChecksLesson.run(report)
    await AuditChecksTutor.run(report)
    await AuditChecksTags.run(report)
    await AuditChecksClaude.run(report)
    await AuditChecksData.run(report)
    await BookmarkChecks.run(report)
    await SkillChecks.run(report)
    print("\(passed) PASS, \(failed) FAIL")
    exit(failed == 0 ? 0 : 1)
}
RunLoop.main.run()
