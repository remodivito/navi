import AppKit
import Sparkle

/// Updates, through Sparkle: once a day Navi checks the appcast on its GitHub releases
/// (SUFeedURL in Info.plist) and, when there's a newer version, offers it. Every update
/// is signed with Navi's EdDSA key (SUPublicEDKey) and Apple-notarised, and Sparkle
/// refuses one that isn't. Only the installed app checks; a debug run never does.
enum Updates {
    private static var controller: SPUStandardUpdaterController?

    /// At launch, in the real app only.
    static func start() {
        guard Bundle.main.bundlePath.hasSuffix(".app"), Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        trace("Updates: checking \(automatic ? "daily" : "only when asked").")
    }

    static var available: Bool { controller != nil }

    /// "Check for updates" in Settings.
    static func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    static var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// "Navi 0.4.0 beta": the version as people see it.
    static var versionLabel: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let stage = Bundle.main.object(forInfoDictionaryKey: "NaviReleaseStage") as? String
        return "Navi \(v)" + (stage.map { " \($0)" } ?? "")
    }
}

/// "Report a problem…": a new GitHub issue with the version, macOS and the kind of
/// connection filled in, and nothing else. Nothing is sent until they press Submit there.
enum ReportProblem {
    static let repo = "https://github.com/remodivito/navi"

    static func open(crashSummary: String? = nil) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let connection = Settings.shared.backend == .cli ? "Claude Code" : "API key"
        var body = """
        **What happened**


        **What you expected**


        **How to make it happen again (if you know)**


        ---
        \(Updates.versionLabel) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(connection)
        """
        if let crashSummary { body += "\n\n**Crash summary**\n```\n\(crashSummary)\n```" }
        var c = URLComponents(string: repo + "/issues/new")!
        c.queryItems = [URLQueryItem(name: "labels", value: crashSummary == nil ? "bug" : "crash"),
                        URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
        trace("Report a problem: opened a new issue page\(crashSummary == nil ? "" : " with the crash summary").")
    }
}
