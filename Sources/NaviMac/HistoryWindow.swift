import AppKit
import SwiftUI

/// Menu → History…: kept lessons and threads on the left; on the right, a kept
/// lesson's bookmark (to read, carry on or delete), or the selected thread's turns,
/// each with what was sent, the screenshots (dev builds) with the reply's marks
/// redrawn on them, the reply, and tokens and timing.
enum HistoryWindow {
    private static var window: NSWindow?
    /// Picks a kept lesson up, and adds files to one (the app sets them).
    static var onResume: ((String) -> Void)?
    static var onAttach: (([URL], String) -> Void)?

    static func close() { window?.orderOut(nil) }

    static func show(_ history: History = .shared) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Navi History"
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("NaviHistory")
            Look.inkWindow(w)
            window = w
        }
        // A new view each time, so the list is current. Setting the controller
        // resizes the window to the view's minimum, so put the frame back.
        let frame = window?.frame
        window?.contentViewController = NSHostingController(rootView: HistoryView(history: history)
            .frame(minWidth: 820, minHeight: 520)
            .font(.custom("Figtree", size: 13))
            .foregroundStyle(Ink.text)
            .background(Ink.pane)
            .preferredColorScheme(.dark))
        if let frame, frame.width >= 820 { window?.setFrame(frame, display: false) }
        else { window?.setContentSize(NSSize(width: 1100, height: 720)); window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        trace("History window at \(window.map { NSStringFromRect($0.frame) } ?? "-")")
    }
}

/// Navi's ink-pane look in SwiftUI.
private enum Ink {
    static let pane = Color(nsColor: Look.Pane.fill.withAlphaComponent(1))
    static let text = Color(nsColor: Look.warmWhite)
    static let soft = Color(nsColor: Look.softText)
}

private struct HistoryView: View {
    let history: History
    @State private var threads: [History.Thread] = []
    @State private var kept: [Bookmark] = []
    @State private var selected: String?
    @State private var confirmClear = false

    /// Kept lessons are selected as "kept:<id>", threads by their own id.
    private static let keptPrefix = "kept:"

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                if !kept.isEmpty {
                    Section("Kept lessons") {
                        ForEach(kept, id: \.id) { b in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.title).lineLimit(2)
                                Text("\(b.progress)\(b.app.map { " · \($0)" } ?? "") · \(MenuBar.when(b.lastUsed))")
                                    .font(.caption).foregroundStyle(Ink.soft)
                            }
                            .padding(.vertical, 5)
                            .tag(Self.keptPrefix + b.id)
                        }
                    }
                }
                Section(kept.isEmpty ? "" : "Conversations") {
                    ForEach(threads) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).lineLimit(2)
                            Text("\(t.updated.formatted(date: .abbreviated, time: .shortened)) · \(t.turns) turn\(t.turns == 1 ? "" : "s") · \(t.tokens / 1000)k tokens")
                                .font(.caption).foregroundStyle(Ink.soft)
                            if !t.preview.isEmpty {
                                Text(t.preview).font(.caption).foregroundStyle(Ink.soft).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(t.id)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.pane)
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(History.keepsScreenshots
                         ? "Dev build: screenshots are kept for 7 days."
                         : "Text only, kept for 7 days. This build doesn't save screenshots.")
                        .font(.caption).foregroundStyle(Ink.soft)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.folder]) }
                        Button("Clear History…") { confirmClear = true }.disabled(threads.isEmpty)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.pane)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
            }
        } detail: {
            if let sel = selected, sel.hasPrefix(Self.keptPrefix), let b = kept.first(where: { Self.keptPrefix + $0.id == sel }) {
                BookmarkView(bookmark: b, carryOn: {
                    HistoryWindow.close()
                    HistoryWindow.onResume?(b.id)
                }, add: { urls in
                    HistoryWindow.onAttach?(urls, b.id)
                    kept = Bookmarks.shared.all
                }, removeFile: { f in
                    var changed = b
                    changed.files.removeAll { $0 == f }
                    Bookmarks.shared.keep(changed)
                    kept = Bookmarks.shared.all
                }, forget: {
                    Bookmarks.shared.remove(b.id)
                    kept = Bookmarks.shared.all
                    selected = kept.first.map { Self.keptPrefix + $0.id } ?? threads.first?.id
                })
                .background(Ink.pane)
            } else if let id = selected, let t = history.transcript(id) {
                TranscriptView(transcript: t, shots: history.shotsFolder(id))
                    .background(Ink.pane)
            } else {
                Text(threads.isEmpty ? "Nothing yet. Ask something with the shortcut." : "Pick a conversation.")
                    .foregroundStyle(Ink.soft)
            }
        }
        .onAppear {
            threads = history.threads()
            kept = Bookmarks.shared.all
            selected = kept.first.map { Self.keptPrefix + $0.id } ?? threads.first?.id
        }
        .confirmationDialog("Delete all saved conversations?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) {
                history.clear()
                threads = []
                selected = nil
            }
        }
    }
}

/// A kept lesson's bookmark: the plan with what's done, where it stopped, where they
/// needed help and its files, with Carry on and Delete.
private struct BookmarkView: View {
    let bookmark: Bookmark
    let carryOn: () -> Void
    let add: ([URL]) -> Void
    let removeFile: (String) -> Void
    let forget: () -> Void
    @State private var confirmForget = false
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("KEPT LESSON · \(bookmark.progress.uppercased())").font(.caption.weight(.semibold)).kerning(1.1)
                        .foregroundStyle(Color(nsColor: Buddy.lamp))
                    Text(bookmark.title).font(.title2.weight(.medium))
                    Text(bookmark.goal).foregroundStyle(Ink.soft).textSelection(.enabled)
                }
                if !bookmark.outline.isEmpty {
                    section("The plan") {
                        ForEach(Array(bookmark.outline.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: i < bookmark.done.count ? "checkmark" : i == bookmark.done.count ? "arrow.right" : "circle")
                                    .font(.caption).frame(width: 14)
                                    .foregroundStyle(i == bookmark.done.count ? Color(nsColor: Buddy.lamp) : Ink.soft)
                                Text(step).foregroundStyle(i < bookmark.done.count ? Ink.soft : Ink.text)
                            }
                        }
                    }
                } else if !bookmark.done.isEmpty {
                    section("Done so far") {
                        ForEach(Array(bookmark.done.enumerated()), id: \.offset) { _, step in Text(step).foregroundStyle(Ink.soft) }
                    }
                }
                if let next = bookmark.next { section("Stopped at") { Text(next).textSelection(.enabled) } }
                if !bookmark.stuckOn.isEmpty {
                    section("Needed help with") { ForEach(bookmark.stuckOn, id: \.self) { Text($0) } }
                }
                section("Files") {
                    ForEach(bookmark.files, id: \.self) { f in
                        HStack(spacing: 8) {
                            Button((f as NSString).lastPathComponent) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (f as NSString).expandingTildeInPath)])
                            }
                            .buttonStyle(.link)
                            .help(f)
                            Button { removeFile(f) } label: { Image(systemName: "xmark").font(.caption2) }
                                .buttonStyle(.borderless).foregroundStyle(Ink.soft).help("Remove from this lesson")
                        }
                    }
                    Text(bookmark.files.isEmpty ? "Drop lecture slides, practicals or a whole folder here, or on Navi's owl in the menu bar."
                                                : "Drop more here, or on Navi's owl in the menu bar.")
                        .font(.caption).foregroundStyle(Ink.soft)
                    Button("Add files…") { choose() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(dropping ? Color(nsColor: Buddy.lamp) : Color.white.opacity(0.08),
                                                                           style: StrokeStyle(lineWidth: 1, dash: dropping ? [] : [4, 3])))
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    let found = Dropped()
                    let group = DispatchGroup()
                    for p in providers {
                        group.enter()
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { found.add(url) }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) { if !found.urls.isEmpty { add(found.urls) } }
                    return true
                }
                Text("Kept as text only, until it's finished or goes unused for 30 days. Navi offers to pick it up when you ask about it.")
                    .font(.caption).foregroundStyle(Ink.soft)
                HStack {
                    Button("Carry on", action: carryOn).keyboardShortcut(.defaultAction)
                    Button("Delete…") { confirmForget = true }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Delete this kept lesson?", isPresented: $confirmForget) {
            Button("Delete", role: .destructive, action: forget)
        }
    }

    /// Files or folders, from an Open panel.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Lecture slides, practicals, notes: anything this lesson should use."
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Ink.soft)
            content()
        }
    }
}

/// URLs arriving from a drop, one provider at a time on any thread.
private final class Dropped: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func add(_ u: URL) { lock.lock(); list.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
}

private struct TranscriptView: View {
    let transcript: History.Transcript
    let shots: URL

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                ForEach(transcript.turns) { TurnView(turn: $0, shots: shots) }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
    }
}

private struct TurnView: View {
    let turn: History.Turn
    let shots: URL
    @State private var showSent = false

    private var asked: String { turn.sent.last ?? "" }
    private var marks: [Annotation] { TagParser.parse(turn.reply).annotations }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header).font(.caption.monospaced()).foregroundStyle(Ink.soft)
            Text(asked).font(.title3.weight(.medium)).textSelection(.enabled)

            DisclosureGroup("Everything sent (\(turn.sent.count) blocks)", isExpanded: $showSent) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(turn.sent.enumerated()), id: \.offset) { _, block in
                        Text(block).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .font(.caption)

            ForEach(Array(turn.shots.enumerated()), id: \.offset) { _, shot in
                if let file = shot.file, let image = NSImage(contentsOf: shots.appendingPathComponent(file)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shot.label).font(.caption).foregroundStyle(Ink.soft)
                        MarkedShot(image: image, shot: shot, marks: marks.filter { $0.screen == shot.screen || ($0.screen == TagParser.cursorScreen && shot.label.contains("cursor")) })
                    }
                } else {
                    Text("[\(shot.label)]").font(.caption).foregroundStyle(Ink.soft)
                }
            }

            if let error = turn.error {
                Text("Error: \(error)").foregroundStyle(.red).textSelection(.enabled)
            }
            if !turn.reply.isEmpty {
                Text(TagParser.parse(turn.reply).text).textSelection(.enabled)
                Text(turn.reply).font(.caption.monospaced()).foregroundStyle(Ink.soft).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: String {
        func s(_ t: Double?) -> String { t.map { String(format: "%.1fs", $0) } ?? "-" }
        var parts = ["#\(turn.id)", turn.at.formatted(date: .omitted, time: .standard), "\(turn.kind) → \(turn.action)",
                     "\(turn.shots.count) screenshot\(turn.shots.count == 1 ? "" : "s")"]
        if let i = turn.tokensIn { parts.append("in \(i) / out \(turn.tokensOut ?? 0) tokens") }
        parts.append("first text \(s(turn.firstText)), first mark \(s(turn.firstTag)), done \(s(turn.total))")
        return parts.joined(separator: " · ")
    }
}

/// A screenshot with the reply's marks drawn over it, in its own pixel coordinates.
private struct MarkedShot: View {
    let image: NSImage
    let shot: History.Shot
    let marks: [Annotation]

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 900)
            .overlay {
                GeometryReader { geo in
                    Canvas { ctx, size in
                        let w = CGFloat(shot.width > 0 ? shot.width : Int(image.size.width))
                        let h = CGFloat(shot.height > 0 ? shot.height : Int(image.size.height))
                        let sx = size.width / w, sy = size.height / h
                        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * sx, y: q.y * sy) }
                        for mark in marks { draw(mark, in: &ctx, p: p, scale: sx) }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func draw(_ mark: Annotation, in ctx: inout GraphicsContext, p: (CGPoint) -> CGPoint, scale: CGFloat) {
        let color = Color.orange
        let line = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
        var labelAt: CGPoint?
        switch mark {
        case .point(let c, _, _):
            let q = p(c)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(color))
            labelAt = q
        case .target(let c, let r, _, _), .hover(let c, let r, _, _), .quiz(let c, let r, _, _):
            let q = p(c), rr = max(6, r * scale)
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2)), with: .color(color),
                       style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            labelAt = CGPoint(x: q.x, y: q.y - rr)
        case .highlight(let r, _, _):
            let rect = CGRect(origin: p(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale))
            ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.18)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color), style: line)
            labelAt = rect.origin
        case .write(let at, let text, _):
            ctx.draw(Text(text).font(.system(size: 14, weight: .semibold)).foregroundColor(color), at: p(at), anchor: .topLeading)
        case .open, .download:
            break   // errands aren't drawn
        case .demo(let pts, _, _):
            var path = Path()
            path.addLines(pts.map(p))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, dash: [4, 4]))
        case .shape(let kind, let pts, _, _):
            let q = pts.map(p)
            var path = Path()
            switch kind {
            case .circle where q.count >= 2:
                let r = hypot(q[1].x - q[0].x, q[1].y - q[0].y)
                path.addEllipse(in: CGRect(x: q[0].x - r, y: q[0].y - r, width: r * 2, height: r * 2))
            case .polygon:
                path.addLines(q)
                path.closeSubpath()
            case .curve where q.count >= 3:
                // The curve passes through the middle point.
                let control = CGPoint(x: 2 * q[1].x - (q[0].x + q[2].x) / 2, y: 2 * q[1].y - (q[0].y + q[2].y) / 2)
                path.move(to: q[0])
                path.addQuadCurve(to: q[2], control: control)
            default:
                path.addLines(q)
            }
            ctx.stroke(path, with: .color(color), style: line)
            if kind == .arrow, q.count >= 2, let tip = q.last {
                let from = q[q.count - 2]
                let a = atan2(tip.y - from.y, tip.x - from.x)
                var head = Path()
                for da in [CGFloat.pi * 0.85, -CGFloat.pi * 0.85] {
                    head.move(to: tip)
                    head.addLine(to: CGPoint(x: tip.x + 12 * cos(a + da), y: tip.y + 12 * sin(a + da)))
                }
                ctx.stroke(head, with: .color(color), style: line)
            }
            labelAt = q.first
        }
        if let at = labelAt, let label = mark.label, !label.isEmpty {
            ctx.draw(Text(label).font(.caption.bold()).foregroundColor(.white),
                     at: CGPoint(x: at.x + 8, y: at.y - 8), anchor: .bottomLeading)
        }
    }
}
