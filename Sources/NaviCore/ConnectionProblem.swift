import Foundation

/// Why a connection to Claude isn't working, with the one sentence the user
/// sees for it.
public enum ConnectionProblem: Equatable {
    case notInstalled, notSignedIn, unresponsive, signInExpired
    /// The plan's usage limit; the reset time as the CLI gave it, when it did.
    case planLimit(String?)
    case noKey, keyRejected, keyForbidden, noCredit, unreachable, busy
    case other(String)

    public var sentence: String {
        switch self {
        case .notInstalled: return "Claude Code isn't installed on this \(Platform.current.computer)."
        case .notSignedIn: return "Claude Code is installed but not signed in."
        case .unresponsive: return "Found Claude Code, but it didn't respond."
        case .signInExpired: return "Claude Code needs you to sign in again (Navi's own sign-in, in Settings, stops this happening)."
        case .planLimit(let reset?): return "Your Claude plan's limit resets \(reset)."
        case .planLimit(nil): return "You've reached your Claude plan's limit for now."
        case .noKey: return "No API key saved yet."
        case .keyRejected: return "Anthropic didn't accept this key. Check it was copied in full."
        case .keyForbidden: return "This key can't use the models. Check its workspace in the Console."
        case .noCredit: return "Your Anthropic account is out of credit."
        case .unreachable: return "Couldn't reach Anthropic just now."
        case .busy: return "Claude is busy right now. Try again in a moment."
        case .other(let msg): return String(msg.prefix(300))
        }
    }

    /// What Navi says in the caption when an ask fails for this reason.
    public var spoken: String {
        switch self {
        case .planLimit, .busy, .unreachable, .other: return sentence
        default: return "I can't reach Claude. " + sentence + " It's in Settings."
        }
    }

    /// Recognises auth and limit failures in `claude -p` output or stderr.
    public init?(cliText t: String) {
        let s = t.lowercased()
        if s.contains("hit your limit") || s.contains("usage limit") || s.contains("limit reached") {
            self = .planLimit(Self.resetTime(t))
        } else if s.contains("/login") || s.contains("not logged in") || s.contains("login expired")
                    || s.contains("oauth token") || s.contains("authentication_error") || s.contains("invalid api key")
                    || s.contains("failed to authenticate") || s.contains("oauth session") {
            self = .signInExpired
        } else if s.contains("overloaded") || s.range(of: #"\b529\b"#, options: .regularExpression) != nil {
            self = .busy
        } else if s.contains("unknown option") || s.contains("unknown argument") {
            // A Claude Code from before the flags Navi passes (--effort, --disable-slash-commands).
            self = .other("This Claude Code is too old for Navi. Update it (`claude update`), then try again.")
        } else {
            return nil
        }
    }

    /// Maps a Messages API error response by its `error.type`.
    public init?(status: Int, body: String) {
        let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        let type = err?["type"] as? String ?? ""
        let message = err?["message"] as? String ?? ""
        switch (status, type) {
        case (200..<300, _): return nil
        case (401, _), (_, "authentication_error"): self = .keyRejected
        case (403, _), (_, "permission_error"): self = .keyForbidden
        case (402, _), (_, "billing_error"): self = .noCredit
        // What the API actually sends when credit runs out (see Zed's anthropic.rs).
        case (400, _) where message.lowercased().contains("credit balance"): self = .noCredit
        case (429, _), (529, _), (500..., _): self = .busy
        default: self = .other("API error \(status): \(message.isEmpty ? body : message)")
        }
    }

    public init?(error: Error) {
        switch error {
        case ClaudeCLIError.notFound: self = .notInstalled
        case ClaudeCLIError.failed(let m), ClaudeCLIError.exited(let m):
            guard let p = ConnectionProblem(cliText: m) else { return nil }
            self = p
        case ClaudeError.noKey: self = .noKey
        // The API can fail mid-stream, most often with an overload.
        case ClaudeError.stream(let m):
            guard let p = ConnectionProblem(cliText: m) else { return nil }
            self = p
        case ClaudeError.http(let code, let body):
            guard let p = ConnectionProblem(status: code, body: body) else { return nil }
            self = p
        case let e as URLError where e.code != .cancelled: self = .unreachable
        default: return nil
        }
    }

    /// "at 3 pm" from "resets 3pm (Europe/London)", or from the older
    /// "Claude AI usage limit reached|1761058800" form.
    public static func resetTime(_ t: String) -> String? {
        if let bar = t.range(of: #"\|(\d{9,})"#, options: .regularExpression),
           let epoch = TimeInterval(t[bar].dropFirst()) {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "at " + f.string(from: Date(timeIntervalSince1970: epoch))
        }
        guard let r = t.range(of: #"resets? (at )?[0-9][^·\n(]*"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let time = t[r].replacingOccurrences(of: #"^resets? (at )?"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return time.isEmpty ? nil : "at " + time
    }
}

/// What `claude auth status --json` said, without the account's identity:
/// Navi shows the plan, never the email.
public struct ClaudeCodeStatus: Equatable {
    public var path: String
    public var version: String
    public var loggedIn: Bool
    /// none, claude.ai, oauth_token, api_key, api_key_helper or third_party.
    public var authMethod: String
    /// pro, max, team, enterprise…, when signed in with a plan.
    public var subscription: String?

    public init(path: String, version: String, loggedIn: Bool, authMethod: String, subscription: String?) {
        (self.path, self.version, self.loggedIn, self.authMethod, self.subscription) = (path, version, loggedIn, authMethod, subscription)
    }

    /// True when Claude Code's own sign-in bills the API rather than a plan.
    public var billsAPI: Bool { authMethod == "api_key" || authMethod == "api_key_helper" }

    public var planName: String {
        if billsAPI { return "Console account (API billing)" }
        if authMethod == "third_party" { return "cloud provider" }
        guard let s = subscription, !s.isEmpty else { return "Claude plan" }
        return s.prefix(1).uppercased() + s.dropFirst() + " plan"
    }
}
