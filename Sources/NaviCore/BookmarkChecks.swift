import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Checks for kept lessons: the store, the tags, and putting a lesson down and
/// picking it up again on the fake shell.
public enum BookmarkChecks {
    @MainActor
    public static func run(_ check: (String, Bool) -> Void) async {
        // Tags
        let outlined = "[TOPIC:QGIS buffers] [OUTLINE:Add the roads layer | Open Buffer | Set 500 m] [TARGET:10,10,20:Layer] Open the Layer menu."
        check("bookmarks: an outline is read, step by step", TagParser.outline(outlined) == ["Add the roads layer", "Open Buffer", "Set 500 m"])
        check("bookmarks: an outline and a resume aren't read out",
              TagParser.parse(outlined).text == "Open the Layer menu." && TagParser.parse("[RESUME:ab12cd34] Next, open Buffer.").text == "Next, open Buffer.")
        check("bookmarks: a resume names its bookmark", TagParser.resume("[RESUME: AB12cd34 ] Next.") == "ab12cd34" && TagParser.resume("Next.") == nil)
        check("bookmarks: the pill counts against the plan", Tutor.pillText(topic: "QGIS", stepsTaken: 4, of: 12) == "QGIS · step 5 of 12"
              && Tutor.pillText(topic: "QGIS", stepsTaken: 4, of: 0) == "QGIS · step 5")

        // The store
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("navi-bookmark-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = Bookmarks(file: file)
        check("bookmarks: none means nothing in the prompt", store.promptNote() == nil)
        let b = Bookmark(title: "QGIS practical 3", goal: "buffer the roads", outline: ["a", "b", "c", "d"], done: ["a", "b"],
                         next: "Open Buffer", stuckOn: ["the Vector menu"], app: "QGIS", bundleID: "org.qgis.qgis", files: ["/tmp/practical3.pdf"])
        store.keep(b)
        check("bookmarks: progress reads against the plan", b.progress == "step 3 of 4")
        let note = store.promptNote() ?? ""
        check("bookmarks: the prompt lists it with its id, where it stopped, help and files",
              note.contains("[\(b.id)]") && note.contains("Stopped at: Open Buffer") && note.contains("Needed help with: the Vector menu")
              && note.contains("/tmp/practical3.pdf") && note.contains("[RESUME:id]"))
        check("bookmarks: kept on disk, and read back", Bookmarks(file: file).get(b.id)?.done == ["a", "b"])
        store.keep(Bookmark(title: "secret", goal: "use token=abc123def456 here"))
        check("bookmarks: secrets are redacted before they're kept", store.all.first?.goal.contains("abc123def456") == false)
        for i in 0..<Bookmarks.limit + 2 { store.keep(Bookmark(title: "t\(i)", goal: "g")) }
        check("bookmarks: at most \(Bookmarks.limit), newest first", store.all.count == Bookmarks.limit && store.all.first?.title == "t\(Bookmarks.limit + 1)")
        var old = Bookmark(title: "old", goal: "g")
        old.lastUsed = Date().addingTimeInterval(-Bookmarks.expiry - 60)
        store.keep(old)
        check("bookmarks: unused for 30 days, it goes", store.get(old.id) == nil)
        store.removeAll()

        // A lesson resumed carries its steps, plan and a fresh step allowance
        let l = Walkthrough(resuming: b)
        check("bookmarks: a resumed lesson has its steps, plan and help notes",
              l.stepsTaken == 2 && l.outline.count == 4 && l.stepsLeft == Walkthrough.maxSteps && l.message(event: "x").contains("They needed help with"))
        check("bookmarks: one step isn't worth keeping; two are", !{ let w = Walkthrough(goal: "g"); w.record("a"); return w.worthKeeping }()
              && { let w = Walkthrough(goal: "g"); w.record("a"); w.record("b"); return w.worthKeeping }())

        // On the fake shell
        func engine(_ replies: [String]) -> (Tutor.Engine, FakeShell) {
            let fake = FakeShell(screens: 1)
            let e = Tutor.Engine(overlay: fake.overlay, light: fake.light, caption: fake.caption, ui: fake.ui, screens: fake.screens, voice: nil)
            e.wait = { _ in }
            e.host = fake.host
            e.watch = fake.watch
            e.pauseCard = fake.pause
            e.topicPill = fake.pill
            e.frontApp = { fake.ui.app }
            e.actions = fake.errands
            e.bookmarks = store
            var queue = replies
            e.send = { _, _, onText in
                let r = queue.isEmpty ? "" : queue.removeFirst()
                onText(r)
                try? await Task.sleep(nanoseconds: 2_000_000)
                return r
            }
            return (e, fake)
        }
        let shots: [any Shell.Screenshot] = [FakeShell.Shot(screenID: 1, index: 1, hasCursor: true, origin: .zero)]
        func settle(_ e: Tutor.Engine) async {
            for _ in 0..<6 { await e.turn?.value; try? await Task.sleep(nanoseconds: 10_000_000) }
        }

        // Two steps in, then Stop on the card: kept, said so, and "Don't keep this" drops it.
        do {
            let (e, fake) = engine(["[TOPIC:Saving maps] [OUTLINE:File | Export | Save] [TARGET:200,100,30:File] Open File.",
                                    "[TARGET:200,140,30:Export] Choose Export.", "[TARGET:200,180,30:Save] Click Save."])
            try? await e.runTurn([], shots: shots, goal: "save the map", anchor: .zero, gen: e.bump(), kind: .question("save the map"), asked: "save the map")
            for _ in 0..<2 {
                e.graceUntil = nil
                if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
                await settle(e)
            }
            check("bookmarks: the plan reaches the lesson and the pill", e.lesson?.outline == ["File", "Export", "Save"] && e.pillText == "Saving maps · step 3 of 3")
            e.pauseLesson(why: "test")
            e.pauseChoice(.stop)
            let kept = store.all.first
            check("bookmarks: Stop keeps a lesson two steps in", kept?.title == "Saving maps" && kept?.done.count == 2 && kept?.next == "Click Save.")
            check("bookmarks: and says so, with Don't keep this", fake.caption.kicker == "KEPT · SAVING MAPS" && fake.caption.link == "Don't keep this")
            fake.caption.clickLink()
            check("bookmarks: Don't keep this drops it", store.all.isEmpty)
        }

        // A question that carries a kept lesson on picks it up; finishing closes it.
        do {
            store.keep(b)
            let (e, fake) = engine(["[RESUME:\(b.id)] [TARGET:200,100,30:Buffer] Next, open Buffer.", "All done: your roads are buffered."])
            try? await e.runTurn([], shots: shots, goal: "where was I with the buffer", anchor: .zero, gen: e.bump(),
                                 kind: .question("where was I with the buffer"), asked: "where was I with the buffer")
            check("bookmarks: a RESUME reply picks the lesson up where it was",
                  e.lesson?.bookmarkID == b.id && e.lesson?.stepsTaken == 2 && e.lesson?.armed != nil && e.topic == "QGIS practical 3")
            check("bookmarks: the caption says it's picking up, with Start fresh instead",
                  fake.log.contains("kicker PICKING UP · QGIS PRACTICAL 3") && fake.caption.link == "Start fresh instead")
            check("bookmarks: picking up counts a session", store.get(b.id)?.sessions == 2)
            if let s = e.lesson?.armed { e.stepClicked(at: s.center) }
            await settle(e)
            check("bookmarks: finishing a kept lesson closes its bookmark", e.lesson == nil && store.get(b.id) == nil)
        }

        // A RESUME naming no kept lesson changes nothing; a lesson under way is never swapped.
        do {
            let (e, _) = engine(["[RESUME:nothere1] [TARGET:200,100,30:File] Open File."])
            try? await e.runTurn([], shots: shots, goal: "save", anchor: .zero, gen: e.bump(), kind: .question("save"), asked: "save")
            check("bookmarks: an unknown RESUME is ignored", e.lesson != nil && e.lesson?.bookmarkID == nil)
        }

        // Attaching: into the lesson going now (kept with it), a kept one, or the next question.
        do {
            check("attach: files in a few words", Tutor.filesInWords(["/a/practical3.pdf"]) == "practical3.pdf"
                  && Tutor.filesInWords(["/a/x.pdf", "/a/y.pdf"]) == "x.pdf and y.pdf" && Tutor.filesInWords(["1", "2", "3"]) == "3 files")
            let (e, fake) = engine(["[TOPIC:Buffers] [TARGET:200,100,30:Layer] Open Layer.", "unused"])
            try? await e.runTurn([], shots: shots, goal: "buffer", anchor: .zero, gen: e.bump(), kind: .question("buffer"), asked: "buffer")
            e.attach(["/tmp/practical3.pdf"], to: .current)
            check("attach: into the lesson going now, and said", e.lesson?.files == ["/tmp/practical3.pdf"]
                  && fake.caption.kicker == "ADDED TO · BUFFERS" && e.lesson?.message(event: "x").contains("/tmp/practical3.pdf") == true)
            check("attach: a lesson with files is worth keeping, one step or none", e.endLesson(clear: true)?.files == ["/tmp/practical3.pdf"])
            let id = store.all.first?.id ?? ""
            e.attach(["/tmp/notes.md", "/tmp/practical3.pdf"], to: .kept(id), announce: false)
            check("attach: into a kept lesson, without doubles", store.get(id)?.files == ["/tmp/practical3.pdf", "/tmp/notes.md"])
            store.removeAll()

            let (q, qfake) = engine(["It's about map projections.", "Buffers come in lecture 5."])
            let conv = Conversation()
            q.conversation = conv
            q.attach(["/tmp/lecture4.pdf"], to: .current)   // no lesson: it belongs to the conversation
            check("attach: with no lesson, to the conversation", conv.files == ["/tmp/lecture4.pdf"]
                  && qfake.caption.kicker == "ADDED TO · THIS CONVERSATION" && q.pillText == "This conversation · 1 file")
            var sent: [[String: Any]] = []
            let reply = q.send
            q.send = { content, kind, onText in sent += content; return try await reply(content, kind, onText) }
            for question in ["what's this lecture about", "and where are buffers?"] {
                sent = []
                q.ask(Tutor.Engine.Asking(question: question, fromCard: false, anchor: .zero, screenshots: { shots }, context: { (nil, nil) }))
                await settle(q)
                let texts = sent.compactMap { $0["text"] as? String }.joined(separator: "\n")
                check("attach: \"\(question)\" carries the conversation's files", texts.contains("/tmp/lecture4.pdf"))
            }
            q.clearTopic()
            check("attach: ending the conversation lets the files go", conv.files.isEmpty && q.pillText == nil)
        }

        // The conversation lasts: a fresh Claude process still gets the recap, it's kept between
        // launches, it knows a long break, and its recap stays a fixed size.
        do {
            final class Backend: ChatBackend {
                var sent: [[[String: Any]]] = []
                var holds = false
                func send(_ content: [[String: Any]], onText: @escaping (String) -> Void) async throws -> String {
                    sent.append(content); holds = true; return "[TOPIC:Buffers] Use Vector › Geoprocessing › Buffer."
                }
                func reset() { holds = false }
                var holdsHistory: Bool { holds }
            }
            let store = FileManager.default.temporaryDirectory.appendingPathComponent("navi-conv-check-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: store) }
            let c = Conversation()
            c.history = nil
            c.store = store
            let b = Backend()
            _ = try? await c.send([Prompt.text("how do I buffer roads?")], kind: .question("how do I buffer roads?"), via: b, onText: { _ in })
            c.addFiles(["/tmp/Practical 3.pdf"])
            b.holds = false   // Claude Code's process went idle and was dropped
            _ = try? await c.send([Prompt.text("and for rivers?")], kind: .question("and for rivers?"), via: b, onText: { _ in })
            let second = (b.sent.last ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            check("conversation: a fresh process still gets the recap, hours later", second.contains("User: how do I buffer roads?")
                  && second.contains("You: Use Vector › Geoprocessing › Buffer."))
            let again = Conversation()
            again.history = nil
            again.store = store
            check("conversation: kept between launches, with its files", again.questions == 2 && again.files == ["/tmp/Practical 3.pdf"] && !again.isAfterBreak)
            check("conversation: never screenshots on disk", !((try? String(contentsOf: store, encoding: .utf8)) ?? "").contains("base64"))
            // A saved conversation from five hours ago.
            if var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: store))) as? [String: Any],
               var turns = json["turns"] as? [[String: Any]] {
                let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5 * 3600))
                for i in turns.indices { turns[i]["at"] = old }
                json["turns"] = turns
                try? JSONSerialization.data(withJSONObject: json).write(to: store)
            }
            let later = Conversation()
            later.history = nil
            later.store = store
            check("conversation: after four hours it's a break", later.isAfterBreak)
            check("conversation: the recap after a break says to say where they'd got to",
                  Conversation.recap(later.exchanges, lesson: false).contains("hours ago"))
            let many = (0..<40).map { Conversation.Exchange(said: "q\($0)", reply: String(repeating: "Answer \($0). More words here. ", count: 30),
                                                             at: Date(), asked: "question number \($0) about buffers") }
            let recap = Conversation.recap(many, lesson: false)
            check("conversation: forty questions still make a recap of fixed size", recap.count < Conversation.recapBudget + 200
                  && recap.contains("Earlier, in brief:") && recap.contains("question number 39"))
            later.end()
            check("conversation: ending it forgets everything, on disk too", later.isEmpty && later.startFresh && !FileManager.default.fileExists(atPath: store.path))
            check("conversation: an open PDF or slides can be offered; other files can't",
                  Tutor.openDocument(in: "Frontmost app: Preview\nOpen document: /Users/a/Lecture 5.pdf") == "/Users/a/Lecture 5.pdf"
                  && Tutor.openDocument(in: "Open document: /Users/a/photo.png") == nil && Tutor.openDocument(in: nil) == nil)
            let needing = "[POINT:10,10:Layers] Buffers live under Vector.\n[MATERIAL:Lecture 4 slides]"
            check("material: an answer that needed their slides says so, and the tag is never shown",
                  TagParser.material(needing) == "Lecture 4 slides" && !TagParser.beats(needing).map(\.text).joined().contains("MATERIAL")
                  && TagParser.material("Buffers live under Vector.") == nil)
            check("material: the offer reads as a sentence and keeps capitals",
                  Tutor.materialLink("Lecture 4 slides") == "Add your lecture 4 slides to this conversation…"
                  && Tutor.materialLink("GIS notes") == "Add your GIS notes to this conversation…"
                  && Tutor.materialLink("your assignment brief") == "Add your assignment brief to this conversation…")
            check("material: only asked for when Navi can read files",
                  Prompt.system(for: .mac, tools: .all).contains("[MATERIAL:")
                  && !Prompt.system(for: .mac, tools: Prompt.tools(cli: false, readFiles: true)).contains("[MATERIAL:"))
        }

        // From the menu: the lesson comes back and Navi looks again.
        do {
            store.keep(b)
            let (e, fake) = engine(["You'd added the roads layer. [TARGET:200,100,30:Buffer] Open Buffer."])
            fake.ui.app = Shell.AppInfo(bundleID: "org.qgis.qgis", name: "QGIS", pid: 42)
            e.resume(b.id)
            await settle(e)
            check("bookmarks: resuming from the menu restores the lesson and arms the next step",
                  e.lesson?.bookmarkID == b.id && e.lesson?.armed != nil && fake.log.contains("working Picking up QGIS practical 3…"))
            store.removeAll()
        }
    }
}
