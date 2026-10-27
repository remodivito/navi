import Foundation
import NaviCore
import ServiceManagement

/// Navi opens when you log in: switched on once setup has finished, and only for the
/// copy in /Applications (anywhere else the login item would point at a path that goes
/// away). After that it's the user's choice, in Settings or System Settings.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    /// macOS wants the user's OK in System Settings › Login Items first.
    static var awaitingApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Switches it on or off; true only if it now is what was asked. When macOS wants
    /// the user's approval, Login Items settings open so they can give it.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            trace("Open at login couldn't be \(on ? "switched on" : "switched off"): \(error.localizedDescription)")
            if on, awaitingApproval { SMAppService.openSystemSettingsLoginItems() }
            return false
        }
        if on, awaitingApproval {
            trace("Open at login: waiting for approval in Login Items settings.")
            SMAppService.openSystemSettingsLoginItems()
            return false
        }
        trace("Open at login: \(on ? "on" : "off")")
        return isOn == on
    }

    /// At launch. Never registers on a first launch: only once the setup guide has
    /// finished (`setupFinished`), so this just catches a finish that happened while
    /// Navi wasn't yet in /Applications.
    static func setUpOnce() {
        guard UserDefaults.standard.bool(forKey: "setupGuideFinished") else { return }
        switchOnOnce()
    }

    /// The setup guide reached "All set": open at login comes on, once.
    static func setupFinished() {
        UserDefaults.standard.set(true, forKey: "setupGuideFinished")
        switchOnOnce()
    }

    /// Debug builds and scripted runs aren't an app bundle, so they never register;
    /// nor does a copy outside /Applications.
    private static func switchOnOnce() {
        let d = UserDefaults.standard
        guard Relocation.inApplications(Bundle.main.bundlePath), !d.bool(forKey: "loginItemSetUp") else { return }
        d.set(true, forKey: "loginItemSetUp")
        set(true)
    }
}
