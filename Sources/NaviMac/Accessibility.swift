import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility helpers: snapping pointers to real controls, reading the
/// front document for context, and typing into fields. All of these need the
/// Accessibility permission and quietly do nothing without it.
enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// A password field has the keys: the focused element's own role first
    /// (a secure field, even in an app that doesn't turn secure input on), then secure input
    /// (which some apps leave on, and which needs no Accessibility).
    static var passwordFieldFocused: Bool {
        if trusted {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            if let focused: AXUIElement = attr(system, kAXFocusedUIElementAttribute) {
                AXUIElementSetMessagingTimeout(focused, 0.2)
                if isSecure(role: attr(focused, kAXRoleAttribute), subrole: attr(focused, kAXSubroleAttribute)) { return true }
            }
        }
        return IsSecureEventInputEnabled()
    }

    /// AppKit's secure fields report the role; web and Catalyst ones often only the subrole.
    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    // MARK: Coordinates

    /// AX uses top-left global coordinates anchored on the primary screen.
    static func axPoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    static func appKitRect(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Attributes

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    /// Element at a global AppKit point. Falls back to asking the front app
    /// directly if the system-wide hit test lands on our own overlay.
    static func element(at p: NSPoint, frontPID: pid_t?) -> AXUIElement? {
        let q = axPoint(p)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var el: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(q.x), Float(q.y), &el) == .success,
           let el, pid(el) != getpid() { return el }
        guard let frontPID else { return nil }
        let app = AXUIElementCreateApplication(frontPID)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var hit: AXUIElement?
        return AXUIElementCopyElementAtPosition(app, Float(q.x), Float(q.y), &hit) == .success ? hit : nil
    }

    // MARK: Snapping

    /// If the point sits on a real control, returns that control's frame
    /// (AppKit global) so the drawing can lock onto it. The rule lives in
    /// `SnapRule` so the eval scores exactly this behaviour.
    static func snap(_ p: NSPoint, on screen: NSScreen, frontPID: pid_t?) -> NSRect? {
        guard trusted, var el = element(at: p, frontPID: frontPID) else { return nil }
        let screenArea = screen.frame.width * screen.frame.height
        for _ in 0..<SnapRule.maxClimb {
            if let role: String = attr(el, kAXRoleAttribute), let f = frame(el),
               SnapRule.isSnappable(role: role, frame: f, screenArea: screenArea) {
                return appKitRect(f)
            }
            guard let parent: AXUIElement = attr(el, kAXParentAttribute) else { break }
            el = parent
        }
        return nil
    }

    /// The on/off switch for `name` in System Settings' open list (Screen Recording,
    /// Accessibility and so on), in AppKit coordinates, so setup can ring it.
    static func settingsSwitch(named name: String) -> NSRect? {
        guard trusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        let toggles: Set<String> = [kAXCheckBoxRole, "AXSwitch", "AXToggle"]
        func label(_ el: AXUIElement) -> String {
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attr(el, $0) as String? }.joined(separator: " ")
        }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 4000 {
            let (el, depth) = queue.removeFirst()
            seen += 1
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            if toggles.contains(role), label(el).contains(name), let f = frame(el) { return appKitRect(f) }
            // A row: the app's name as text, with its switch beside it.
            if role == kAXStaticTextRole, (attr(el, kAXValueAttribute) as String?) == name,
               let parent: AXUIElement = attr(el, kAXParentAttribute) {
                var level = parent
                for _ in 0..<3 {
                    let kids: [AXUIElement] = attr(level, kAXChildrenAttribute) ?? []
                    if let sw = kids.first(where: { toggles.contains((attr($0, kAXRoleAttribute) as String?) ?? "") }), let f = frame(sw) {
                        return appKitRect(f)
                    }
                    guard let up: AXUIElement = attr(level, kAXParentAttribute) else { break }
                    level = up
                }
            }
            if depth < 30 { queue += ((attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []).map { ($0, depth + 1) } }
        }
        return nil
    }

    // MARK: Context

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "html", "css",
        "c", "h", "m", "cpp", "rs", "go", "rb", "java", "kt", "sh", "toml", "csv", "xml", "sql",
    ]

    /// What's in front: app, window, document, URL, selected text and a short
    /// excerpt of a plain-text document. Returns nil when there's nothing useful.
    static func context(for app: NSRunningApplication?) -> String? { frontContext(for: app).text }

    struct FrontContext {
        var text: String?
        /// The front browser page's host, for matching skills.
        var host: String?
    }

    static func frontContext(for app: NSRunningApplication?) -> FrontContext {
        guard trusted, let app else { return FrontContext() }
        var host: String?
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        var lines = ["Frontmost app: \(app.localizedName ?? "unknown")"]

        if let window: AXUIElement = attr(root, kAXFocusedWindowAttribute) {
            if let title: String = attr(window, kAXTitleAttribute), !title.isEmpty { lines.append("Window title: \(title)") }
            if let doc: String = attr(window, kAXDocumentAttribute), let url = URL(string: doc) {
                lines.append("Open document: \(url.isFileURL ? url.path : doc)")
                if let excerpt = excerpt(url) { lines.append("Document start:\n\"\"\"\n\(excerpt)\n\"\"\"") }
            }
            if isBrowser(app), let url = webURL(in: window) {
                lines.append("Page URL: \(url)")
                host = URL(string: url)?.host
            }
        }
        if let focused: AXUIElement = attr(root, kAXFocusedUIElementAttribute),
           let selected: String = attr(focused, kAXSelectedTextAttribute),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Secrets in the selection (a key, a token) never leave the Mac.
            lines.append("Selected text:\n\"\"\"\n\(Redact.selection(String(selected.prefix(2000))))\n\"\"\"")
        }
        return FrontContext(text: lines.count > 1 ? lines.joined(separator: "\n") : nil, host: host)
    }

    /// Only browsers have a page URL worth searching the window for; in heavy apps
    /// like DaVinci Resolve that search is slow and finds nothing.
    static func isBrowser(_ app: NSRunningApplication?) -> Bool {
        let id = app?.bundleIdentifier?.lowercased() ?? ""
        return ["com.apple.safari", "com.google.chrome", "company.thebrowser", "org.mozilla.firefox", "com.microsoft.edgemac",
                "com.brave.browser", "com.operasoftware", "com.vivaldi", "com.kagi.kagimacos", "ai.perplexity.comet"]
            .contains { id.hasPrefix($0) }
    }

    /// The start of a plain-text document, with secrets taken out.
    static func excerpt(_ url: URL) -> String? {
        guard url.isFileURL, textExtensions.contains(url.pathExtension.lowercased()),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // The core's rule: no excerpt for a secret-shaped file name, secrets redacted otherwise.
        return Redact.excerpt(String(text.prefix(3000)), fileName: url.lastPathComponent)
    }

    /// Breadth-first search for a web area's URL, with a visit budget so a
    /// huge tree can't stall us.
    private static func webURL(in window: AXUIElement) -> String? {
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let el = queue.removeFirst()
            visited += 1
            if let role: String = attr(el, kAXRoleAttribute), role == "AXWebArea" {
                if let url: URL = attr(el, kAXURLAttribute) { return url.absoluteString }
            }
            if let children: [AXUIElement] = attr(el, kAXChildrenAttribute) { queue.append(contentsOf: children.prefix(40)) }
        }
        return nil
    }

    // MARK: Typing

    enum InsertOutcome {
        case typed, pasted, copied, refusedSecure

        var message: String {
            switch self {
            case .typed, .pasted: return "Typed it in."
            case .copied: return "Copied to your clipboard. Press ⌘V to paste it."
            case .refusedSecure: return "That looks like a password field, so I left it alone."
            }
        }
    }

    private static let singleLineRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox"]

    /// Puts text into a field: direct AX insertion first, then paste with the
    /// clipboard restored, then clipboard only.
    static func insert(_ text: String, at point: NSPoint?, frontPID: pid_t?) -> InsertOutcome {
        if passwordFieldFocused { return .refusedSecure }
        guard trusted else { return copyOnly(text) }

        var target: AXUIElement?
        if let point, let el = element(at: point, frontPID: frontPID) {
            // Check before focusing: focusing a password field can itself pop up autofill.
            let role: String? = attr(el, kAXRoleAttribute), subrole: String? = attr(el, kAXSubroleAttribute)
            if isSecure(role: role, subrole: subrole) { return .refusedSecure }
            target = el
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        if target == nil {
            let system = AXUIElementCreateSystemWide()
            target = attr(system, kAXFocusedUIElementAttribute)
        }

        var body = text
        if let target {
            let role: String? = attr(target, kAXRoleAttribute)
            let subrole: String? = attr(target, kAXSubroleAttribute)
            if isSecure(role: role, subrole: subrole) { return .refusedSecure }
            if let role, singleLineRoles.contains(role) {
                body = text.components(separatedBy: .newlines).joined(separator: " ")
            }
            // Many apps report success here but do nothing, so check the value changed.
            let before: String? = attr(target, kAXValueAttribute)
            if AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, body as CFString) == .success {
                let after: String? = attr(target, kAXValueAttribute)
                if let after, after != before, after.contains(body.prefix(20)) { return .typed }
            }
        }
        return paste(body)
    }

    private static func copyOnly(_ text: String) -> InsertOutcome {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .copied
    }

    private static func paste(_ text: String) -> InsertOutcome {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the app time to read the clipboard, then put the user's back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, d) in dict { item.setData(d, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        return .pasted
    }
}
