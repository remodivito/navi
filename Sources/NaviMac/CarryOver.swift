import Foundation
import NaviCore

/// Navi's identifier changed from the prototype's (`local.screenpointer.prototype`)
/// to its own (`io.github.remodivito.navi`), and macOS keys settings and the Keychain
/// by identifier. The first launch under the new one brings them across, once.
/// (Screen Recording and Accessibility can't be carried: macOS asks for those again.)
enum CarryOver {
    static let oldIdentifier = "local.screenpointer.prototype"

    static func run() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let id = Bundle.main.bundleIdentifier, id != oldIdentifier else { return }
        let d = UserDefaults.standard
        let done = "carriedOverFromPrototype"
        guard !d.bool(forKey: done) else { return }
        d.set(true, forKey: done)
        let old = oldIdentifier as CFString
        if let keys = CFPreferencesCopyKeyList(old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
           let values = CFPreferencesCopyMultiple(keys as CFArray, old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] {
            // Open at login is registered per identifier: the new one sets itself up afresh.
            for (k, v) in values where k != "loginItemSetUp" { d.set(v, forKey: k) }
            trace("Carried \(values.count) settings across from the prototype's identifier.")
        }
        Keychain.carryOver(from: oldIdentifier)
    }
}
