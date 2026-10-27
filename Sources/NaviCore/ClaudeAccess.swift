import Foundation

extension Shell {
    /// Where secrets live: the Keychain on the Mac, Credential Manager on Windows.
    /// Never files, logs or the repo.
    public protocol Secrets: AnyObject {
        /// Navi's own long-lived Claude Code token (`claude setup-token`), if it has one.
        var claudeToken: String? { get }
        /// An Anthropic API key, if one was saved.
        var apiKey: String? { get }
    }

    /// Finding Claude Code on this machine.
    public protocol ClaudeLocator: AnyObject {
        /// The `claude` to run, or nil when it isn't installed.
        func executable() -> String?
        /// The PATH to run `exe` with, given the inherited one (an npm install needs its
        /// own bin directory first, so `node` resolves).
        func path(for exe: String, inherited: String?) -> String
    }
}

/// How the Claude backends reach the platform: its secrets, where `claude` is, and
/// where to report whether a request worked. The shell sets these at launch.
public enum ClaudeAccess {
    public static var secrets: (any Shell.Secrets)?
    public static var locator: (any Shell.ClaudeLocator)?
    /// A real request worked or failed (keeps the connection status honest).
    public static var report: (Result<Void, Error>, Backend) -> Void = { _, _ in }

    public static func executable() -> String? { locator?.executable() }

    /// The environment `claude` runs in, for the probe and for `claude -p`.
    public static func environment(for exe: String) -> [String: String] {
        environment(for: exe, inheriting: ProcessInfo.processInfo.environment)
    }

    /// The same, from a given inherited environment (for checks).
    public static func environment(for exe: String, inheriting inherited: [String: String]) -> [String: String] {
        var env = inherited
        // Never let an API key in the environment turn plan usage into API billing.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        // Nor a bearer token meant for something else (decision 5): it's kept only alongside
        // ANTHROPIC_BASE_URL, where a company gateway needs it.
        if env["ANTHROPIC_BASE_URL"]?.isEmpty ?? true { env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN") }
        // Navi's own long-lived token, if it has one: then its `claude` never reads or
        // refreshes the shared Claude Code sign-in, so it can't be logged out by (or log out)
        // the Claude app and other sessions.
        if let token = secrets?.claudeToken { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        if let locator { env["PATH"] = locator.path(for: exe, inherited: env["PATH"]) }
        return env
    }

    private static var environmentKey: String? {
        ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The key the API backend uses: the saved one, else the environment's.
    public static var apiKey: String? { secrets?.apiKey ?? environmentKey }
}
