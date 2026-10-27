import Foundation

/// Navi's own long-lived Claude Code sign-in, in one click.
///
/// Claude Code's shared sign-in is a rotating token several Claude apps refresh,
/// and it keeps getting lost. `claude setup-token` makes a token that lasts about a
/// year, on the user's own plan, for tools like Navi. When the user clicks "Keep
/// Navi signed in", Navi runs it (only then), the browser opens to Claude's usual
/// sign-in, and the token it prints is kept in Navi's Keychain entry. Claude Code
/// itself still makes every request; Navi just hands it the token.
///
/// The core keeps what any platform needs: finding the token in the terminal's
/// output, and redacting it for the log. Running the command is the shell's
/// job (`SignIn.run`, in SignInRun.swift on the Mac).
public enum SignIn {
    public enum Failure: Error { case notInstalled, noToken(String), timedOut }

    /// Terminal output without colour codes and cursor movement.
    public static func clean(_ s: String) -> String {
        let ansi = try! NSRegularExpression(pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*\x07|[@-Z\\-_])"#)
        return ansi.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    /// The output with any token taken out, safe to log: a short tail only.
    /// The terminal wraps the token across lines, so the pieces are joined up
    /// again first (as `token(in:)` does), and anything else long and
    /// token-shaped goes too: a leftover fragment, or the sign-in link's code.
    public static func redacted(_ output: String) -> String {
        var t = clean(output)
            .replacingOccurrences(of: #"\r+\n?\r* (?=[A-Za-z0-9_\-])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: "", options: .regularExpression)
            // A long run broken by spaces (a wrap the pseudo-terminal padded) is one run again.
            .replacingOccurrences(of: #"(?<=[A-Za-z0-9_\-]{20}) +(?=[A-Za-z0-9_\-]{8})"#, with: "", options: .regularExpression)
        t = Redact.secrets(in: t).replacingOccurrences(of: #"[A-Za-z0-9_\-]{24,}"#, with: "…", options: .regularExpression)
        return String(t.suffix(300))
    }

    /// The token in `setup-token`'s output, if it's there yet. It may be wrapped
    /// across lines by the terminal, so line breaks inside it are joined up.
    public static func token(in output: String) -> String? {
        let text = clean(output)
        let pattern = try! NSRegularExpression(pattern: #"sk-ant-oat[0-9]{2}-[A-Za-z0-9_\-]{20,}"#)
        // A wrap in the pseudo-terminal shows up as a carriage return and the line's
        // one-space indent ("…ADl5xb\r FWle…"); the next paragraph starts without one.
        let rejoined = text.replacingOccurrences(of: #"\r+\n?\r* (?=[A-Za-z0-9_\-])"#, with: "", options: .regularExpression)
        // Join single line breaks (a wrap) but not blank lines (a new paragraph after the token).
        let unix = text.replacingOccurrences(of: "\r", with: "")
        let joined = unix.replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n+"#, with: " ", options: .regularExpression)
        for candidate in [text, rejoined, joined] {
            let ns = candidate as NSString
            // A real token is about a hundred characters; a shorter match is a wrapped fragment.
            if let m = pattern.firstMatch(in: candidate, range: NSRange(location: 0, length: ns.length)), m.range.length >= 80 {
                return ns.substring(with: m.range)
            }
        }
        return nil
    }
}

/// Secrets taken out of text before it can reach a log, a transcript or the
/// caption: Claude Code's stderr, for one, is handed a token and
/// could echo it. Over-redacting a word is fine; leaking one is not.
public enum Redact {
    /// Each shape and what stands in for it.
    static let shapes: [(pattern: String, replacement: String, options: String.CompareOptions)] = [
        (#"sk-ant-[A-Za-z0-9_\-]+"#, "sk-ant-…", [.regularExpression]),
        (#"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#, "$1_…", [.regularExpression]),
        (#"github_pat_[A-Za-z0-9_]{16,}"#, "github_pat_…", [.regularExpression]),
        (#"xox[abeprs]-[A-Za-z0-9\-]{8,}"#, "xox…", [.regularExpression]),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "AKIA…", [.regularExpression]),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#, "-----PRIVATE KEY…-----", [.regularExpression]),
        (#"(authorization:\s*bearer\s+)\S+"#, "$1…", [.regularExpression, .caseInsensitive]),
        // key=value and key: value, for any name ending in key, secret, token or password.
        (#"((?:key|secret|token|password)\s*[=:]\s*)\S+"#, "$1…", [.regularExpression, .caseInsensitive]),
    ]

    public static func secrets(in text: String) -> String {
        shapes.reduce(text) { t, s in t.replacingOccurrences(of: s.pattern, with: s.replacement, options: s.options) }
    }

    /// A file whose name looks like it holds secrets (.env, credentials, a key): its
    /// contents are never excerpted for Claude or History (decision 3, 2026-10-26).
    public static func isSecretFile(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix(".env") || n.hasSuffix(".env") || n.contains(".env.") || n.contains("secret") || n.contains("credential")
            || n.hasSuffix(".pem") || n.hasSuffix(".key") || n.hasSuffix(".p12") || n.hasSuffix(".pfx")
            || ["id_rsa", "id_ed25519", "id_ecdsa", ".netrc", ".npmrc", ".pgpass"].contains(n)
    }

    /// An open document's excerpt, safe to send and keep: nil for a secret-shaped file
    /// name, otherwise the text with any secrets in it redacted.
    public static func excerpt(_ text: String, fileName: String) -> String? {
        isSecretFile(fileName) ? nil : secrets(in: text)
    }

    /// Selected text, safe to send and keep: secrets in it are redacted.
    public static func selection(_ text: String) -> String { secrets(in: text) }
}
