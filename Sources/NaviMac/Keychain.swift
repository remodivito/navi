import Foundation
import Security

/// The Anthropic API key, kept only in the macOS Keychain: never in
/// UserDefaults, a file, a log or a trace.
///
/// It goes in the data protection keychain when the app's signature allows it
/// (no access prompts, `WhenUnlockedThisDeviceOnly`, never synced). A build
/// without the keychain entitlement gets errSecMissingEntitlement there, so
/// it falls back to the login keychain rather than anywhere else (TN3137).
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "io.github.remodivito.navi"
    private static let account = "anthropic-api-key"

    /// Navi's own long-lived Claude Code token (`claude setup-token`), so its sign-in
    /// never depends on the shared one other Claude apps refresh and can lose.
    private static let tokenAccount = "claude-code-oauth-token"

    private static func base(dataProtection: Bool, account: String = account) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    static var apiKey: String? { read(account) }

    static var claudeToken: String? { read(tokenAccount) }

    @discardableResult
    static func setClaudeToken(_ token: String) -> Bool { write(token, account: tokenAccount, label: "Navi: Claude Code token") }

    static func removeClaudeToken() {
        forget(tokenAccount)
        for dp in [true, false] { SecItemDelete(base(dataProtection: dp, account: tokenAccount) as CFDictionary) }
    }

    /// Scripted runs (gallery, self-test, demos) never touch the Keychain: they run
    /// as a different binary, so every read would ask for the user's password.
    private static let off = CommandLine.arguments.contains {
        $0.hasPrefix("--demo-") || ["--gallery", "--stress", "--fake-reply", "--selftest"].contains($0)
    }

    /// What's been read this launch (nil inside: looked, nothing there), so each
    /// secret is asked for at most once rather than for every claude process.
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    private static func read(_ account: String) -> String? {
        if off { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[account] { return known }
        let found = lookUp(account)
        cache[account] = .some(found)
        return found
    }

    private static func forget(_ account: String) {
        lock.lock()
        cache[account] = nil
        lock.unlock()
    }

    private static func lookUp(_ account: String) -> String? {
        for dp in [true, false] {
            var q = base(dataProtection: dp, account: account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
                return key
            }
        }
        return nil
    }

    /// Moves Navi's sign-in token and API key from the entries the old identifier made,
    /// once, so a new identifier doesn't mean signing in again. Reading them may ask
    /// for the password one last time (they belong to the old identity). Nothing is logged.
    static func carryOver(from oldService: String) {
        guard !off, service != oldService else { return }
        for (acct, label) in [(tokenAccount, "Navi: Claude Code token"), (account, "Navi: Anthropic API key")] {
            guard lookUp(acct) == nil else { continue }
            let old: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: oldService,
                                      kSecAttrAccount as String: acct]
            var q = old
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data, let secret = String(data: data, encoding: .utf8), !secret.isEmpty else { continue }
            if write(secret, account: acct, label: label) {
                SecItemDelete(old as CFDictionary)
                trace("Keychain: carried \(acct == tokenAccount ? "Navi's sign-in" : "the API key") across to the new identifier.")
            }
        }
    }

    /// Replaces any saved key. False if neither keychain would take it.
    @discardableResult
    static func setAPIKey(_ key: String) -> Bool { write(key, account: account, label: "Navi: Anthropic API key") }

    private static func write(_ secret: String, account: String, label: String) -> Bool {
        if off { return false }
        forget(account)
        for dp in [true, false] { SecItemDelete(base(dataProtection: dp, account: account) as CFDictionary) }
        let data = Data(secret.utf8)
        var q = base(dataProtection: true, account: account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrLabel as String] = label
        if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return true }
        var legacy = base(dataProtection: false, account: account)
        legacy[kSecValueData as String] = data
        legacy[kSecAttrLabel as String] = label
        return SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess
    }

    static func removeAPIKey() {
        forget(account)
        for dp in [true, false] { SecItemDelete(base(dataProtection: dp) as CFDictionary) }
    }

    /// "sk-ant-…a1B2": enough to recognise a key, never enough to use it.
    static func masked(_ key: String) -> String {
        let prefix = key.hasPrefix("sk-ant-") ? "sk-ant-" : String(key.prefix(3))
        return prefix + "…" + key.suffix(4)
    }
}
