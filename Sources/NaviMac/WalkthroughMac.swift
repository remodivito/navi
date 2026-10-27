import AppKit

/// The Mac's side of a lesson step: its screen, from the display id the core keeps.
extension Walkthrough.Step {
    init(center: NSPoint, radius: CGFloat, label: String, hover: Bool, screen: NSScreen, sentence: String, armedAt: Date) {
        self.init(center: center, radius: radius, label: label, hover: hover, display: Capture.displayID(screen),
                  sentence: sentence, armedAt: armedAt)
    }

    /// The screen the step is on (the main one if it has since been unplugged).
    var screen: NSScreen {
        NSScreen.screens.first { Capture.displayID($0) == display } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func isOn(_ screen: NSScreen) -> Bool { Capture.displayID(screen) == display }
}

extension AX {
    /// True while the front browser tab is still loading, read from the web
    /// area's loading progress (Safari, WebKit apps) or loaded flag (Chromium).
    static func pageLoading(pid: pid_t) -> Bool {
        guard trusted else { return false }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let window: AXUIElement = attr(root, kAXFocusedWindowAttribute) else { return false }
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let el = queue.removeFirst()
            visited += 1
            if let role: String = attr(el, kAXRoleAttribute), role == "AXWebArea" {
                if let progress: NSNumber = attr(el, "AXLoadingProgress") { return progress.doubleValue < 0.999 }
                if let loaded: NSNumber = attr(el, "AXLoaded") { return !loaded.boolValue }
                return false
            }
            if let children: [AXUIElement] = attr(el, kAXChildrenAttribute) { queue.append(contentsOf: children.prefix(30)) }
        }
        return false
    }

    /// Named elements inside a region the user marked (AppKit global rect),
    /// found by hit-testing a grid of points, at most `limit`, each as role,
    /// name and value.
    static func elements(in rect: NSRect, frontPID: pid_t?, limit: Int = 6) -> [String] {
        guard trusted, rect.width > 2, rect.height > 2 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        let steps = 5
        for iy in 0..<steps {
            for ix in 0..<steps {
                let p = NSPoint(x: rect.minX + rect.width * (CGFloat(ix) + 0.5) / CGFloat(steps),
                                y: rect.minY + rect.height * (CGFloat(iy) + 0.5) / CGFloat(steps))
                guard let el = element(at: p, frontPID: frontPID) else { continue }
                let role: String = attr(el, kAXRoleDescriptionAttribute) ?? attr(el, kAXRoleAttribute) ?? "element"
                let name: String = attr(el, kAXTitleAttribute) ?? attr(el, kAXDescriptionAttribute) ?? ""
                let value: String? = attr(el, kAXValueAttribute)
                var text = name.isEmpty ? "a \(role)" : "a \(role) \"\(name.prefix(80))\""
                if let value, !value.isEmpty, value != name { text += " (value: \"\(value.prefix(80))\")" }
                if let url: URL = attr(el, kAXURLAttribute) { text += " → \(url.absoluteString.prefix(120))" }
                guard !name.isEmpty || value?.isEmpty == false, seen.insert(text).inserted else { continue }
                out.append(text)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
