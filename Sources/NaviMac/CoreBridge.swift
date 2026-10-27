import AppKit

// Thin Mac extensions of NaviCore types: the parts that need Core Graphics
// paths, AppKit colours or screens. The logic they wrap stays in the core.

extension Skills {
    /// Prompt text for the front app, or nil when no skill applies.
    static func context(for app: NSRunningApplication?, host: String?) -> String? {
        context(bundleID: app?.bundleIdentifier, appName: app?.localizedName, host: host)
    }
}

extension Sketch {
    static func path(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        if let first = pts.first {
            path.move(to: first)
            path.addLines(between: pts)
        }
        return path
    }
}
