import AppKit
import NaviCore

/// Navi has to live in Applications before setup. macOS ties Screen Recording,
/// Accessibility and the login item to where an app is: opened straight from the disk
/// image (or from the random App Translocation copy macOS makes of a downloaded app),
/// every grant points at a path that disappears when the image is ejected.
/// So, before anything else, Navi offers to move itself, relaunches from
/// /Applications and ejects the image.
enum Relocation {
    static let destination = URL(fileURLWithPath: "/Applications/Navi.app")

    /// Whether an app bundle at `path` has to move before it runs.
    /// Only app bundles: the bare debug binary runs from anywhere.
    static func needsMove(path: String, translocated: Bool) -> Bool {
        guard path.hasSuffix(".app") || path.hasSuffix(".app/") else { return false }
        return translocated || path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// Whether `path` is an app in /Applications (where open at login may point).
    static func inApplications(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        return p.hasPrefix("/Applications/") && p.hasSuffix(".app")
    }

    /// The disk image volume (`/Volumes/Name`) a path is on, if any.
    static func volume(of path: String) -> String? {
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/" + parts[1]
    }

    static var needed: Bool { needsMove(path: Bundle.main.bundlePath, translocated: isTranslocated(Bundle.main.bundleURL)) }

    // MARK: App Translocation (Security's SecTranslocate, looked up at run time: it isn't in the Swift overlay)

    private typealias IsTranslocatedFn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
    private typealias OriginalPathFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    private static let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    static func isTranslocated(_ url: URL) -> Bool {
        guard let sym = dlsym(security, "SecTranslocateIsTranslocatedURL") else { return url.path.contains("/AppTranslocation/") }
        var result = false
        _ = unsafeBitCast(sym, to: IsTranslocatedFn.self)(url as CFURL, &result, nil)
        return result
    }

    /// Where a translocated app really is (on the disk image, usually).
    static func originalURL(of url: URL) -> URL? {
        guard isTranslocated(url), let sym = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        return unsafeBitCast(sym, to: OriginalPathFn.self)(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    // MARK: Moving

    enum Failure: Error {
        case notNavi, stillRunning, couldNotCopy(String)
        var words: String {
            switch self {
            case .notNavi: "There's a different app called Navi in Applications. Move it aside, then try again."
            case .stillRunning: "Another copy of me is open from Applications. Quit it, then try again."
            case .couldNotCopy: "I couldn't copy myself there. Drag me into Applications in Finder instead."
            }
        }
    }

    /// Copies this Navi into /Applications (an older Navi there goes to the Bin first),
    /// ready to open from there. Runs off the main thread.
    static func copyIn(from source: URL, original: URL) throws {
        let fm = FileManager.default
        let dest = destination
        if original.standardizedFileURL.path != dest.path {
            if fm.fileExists(atPath: dest.path) {
                let id = Bundle(url: dest)?.bundleIdentifier
                guard id == Bundle.main.bundleIdentifier || id == CarryOver.oldIdentifier else { throw Failure.notNavi }
                if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == dest }) {
                    running.terminate()
                    for _ in 0..<50 where !running.isTerminated { Thread.sleep(forTimeInterval: 0.1) }
                    guard running.isTerminated else { throw Failure.stillRunning }
                }
                do { try fm.trashItem(at: dest, resultingItemURL: nil) }
                catch { throw Failure.couldNotCopy("the old copy couldn't go to the Bin: \(error.localizedDescription)") }
            }
            try run("/usr/bin/ditto", [source.path, dest.path])
        }
        // A copy made by a program keeps the download's quarantine, and macOS would
        // translocate it all over again. The user has already opened this one.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        guard Bundle(url: dest)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw Failure.couldNotCopy("the copy in Applications isn't readable")
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure.couldNotCopy(error.localizedDescription) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let said = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.couldNotCopy("\(tool) said: \(said.prefix(200))")
        }
    }

    /// Whether `volume` is a mounted disk image (not a real disk, which isn't ours to eject).
    static func isDiskImage(_ volume: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["info", "-plist"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return false }
        return images.contains { image in
            (image["system-entities"] as? [[String: Any]] ?? []).contains { ($0["mount-point"] as? String) == volume }
        }
    }

    /// Opens `app` once this process has gone (so `open` can't just bring the dying
    /// copy forward), ejects `eject` if given, and quits.
    static func relaunch(_ app: URL, eject: String? = nil) {
        guard app.pathExtension == "app" else { return NSApp.terminate(nil) }   // the bare debug binary: just quit
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        /usr/bin/open "$2"
        if [ -n "$3" ]; then sleep 1; /usr/bin/hdiutil detach "$3" -quiet || true; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(getpid()), app.path, eject ?? ""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// The app's delegate while Navi still has to move: just the pane below.
final class RelocationDelegate: NSObject, NSApplicationDelegate {
    private var pane: RelocationPane?

    func applicationDidFinishLaunching(_ note: Notification) {
        trace("Running from \(Bundle.main.bundlePath): asking to move to Applications first.")
        let p = RelocationPane()
        pane = p
        NSApp.activate(ignoringOtherApps: true)
        p.present()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// "ONE THING FIRST": the setup guide's caption-style pane, asking to move.
final class RelocationPane: NSPanel {
    private let words = NSTextField(wrappingLabelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let quit = InkButton("Quit", target: nil, action: nil)
    private let moveButton = InkButton("Move to Applications", role: .primary, target: nil, action: nil)
    private static let width: CGFloat = 320

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        build()
    }

    override var canBecomeKey: Bool { true }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let owl = OwlView(pixel: 1.4)
        let kicker = NSTextField(labelWithAttributedString: NSAttributedString(string: "ONE THING FIRST", attributes: [
            .font: Look.ui(10.5, .semibold), .foregroundColor: Look.faintText, .kern: 1.3]))
        let head = NSStackView(views: [owl, kicker])
        head.spacing = 8
        head.alignment = .centerY
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(9, after: head)

        words.attributedStringValue = SetupGuide.sentence(("I need to live in your ", "Applications", " folder before we start."))
        reason.stringValue = "macOS ties Screen Recording and Accessibility to where I live, and this copy disappears when the disk image is ejected."
        reason.font = Look.ui(13)
        reason.textColor = Look.softText
        for label in [words, reason] {
            label.preferredMaxLayoutWidth = Self.width - 32
            label.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
            stack.addArrangedSubview(label)
        }
        stack.setCustomSpacing(6, after: words)
        stack.setCustomSpacing(14, after: reason)

        quit.target = self
        quit.action = #selector(quitPressed)
        quit.keyEquivalent = "\u{1b}"
        moveButton.target = self
        moveButton.action = #selector(movePressed)
        moveButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), quit, moveButton])
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        stack.addArrangedSubview(footer)

        let size = stack.fittingSize
        let (outer, content) = Glass.make(size: NSSize(width: Self.width, height: size.height), radius: 18)
        content.layer?.backgroundColor = Look.Pane.fill.withAlphaComponent(0.985).cgColor
        stack.frame = content.bounds
        stack.autoresizingMask = [.width, .height]
        content.addSubview(stack)
        contentView = outer
        setContentSize(NSSize(width: Self.width, height: size.height))
    }

    func present() {
        if let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.midY - frame.height / 2 + v.height * 0.12))
        }
        Owl.shared.appear()
        makeKeyAndOrderFront(nil)
    }

    private func fit() {
        guard let stack = contentView?.subviews.first?.subviews.first else { return }
        stack.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height
        var f = frame
        f.origin.y += f.height - h
        f.size.height = h
        setFrame(f, display: true)
    }

    @objc private func quitPressed() { NSApp.terminate(nil) }

    @objc private func movePressed() {
        if moveButton.title == "Show in Finder" {
            NSWorkspace.shared.activateFileViewerSelecting([Relocation.originalURL(of: Bundle.main.bundleURL) ?? Bundle.main.bundleURL])
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            return NSApp.terminate(nil)
        }
        moveButton.isEnabled = false
        quit.isEnabled = false
        reason.stringValue = "Moving…"
        fit()
        let source = Bundle.main.bundleURL
        let original = Relocation.originalURL(of: source) ?? source
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<Void, Error> { try Relocation.copyIn(from: source, original: original) }
            let volume = Relocation.volume(of: original.path).flatMap { Relocation.isDiskImage($0) ? $0 : nil }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success:
                    trace("Moved to \(Relocation.destination.path); reopening from there\(volume.map { " and ejecting \($0)" } ?? "").")
                    Relocation.relaunch(Relocation.destination, eject: volume)
                case .failure(let error):
                    let failure = error as? Relocation.Failure ?? .couldNotCopy(error.localizedDescription)
                    if case .couldNotCopy(let why) = failure { trace("Couldn't move to Applications: \(why)") }
                    self?.failed(failure.words)
                }
            }
        }
    }

    private func failed(_ words: String) {
        reason.stringValue = words
        quit.isEnabled = true
        moveButton.isEnabled = true
        moveButton.title = "Show in Finder"
        moveButton.attributedTitle = NSAttributedString(string: "Show in Finder", attributes: [.font: Look.ui(13, .medium), .foregroundColor: NSColor.white])
        moveButton.invalidateIntrinsicContentSize()
        fit()
    }
}
