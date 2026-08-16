import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService`. The app registers itself, so there is no
/// installer and nothing to leave behind: removing Wooosh.app removes the login
/// item with it.
enum LoginItem {

    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func register() -> Bool {
        guard SMAppService.mainApp.status != .enabled else { return true }
        do {
            try SMAppService.mainApp.register()
            Log.shared.info("Als Anmeldeobjekt registriert")
            return true
        } catch {
            Log.shared.warn("Registrierung als Anmeldeobjekt fehlgeschlagen: \(error.localizedDescription)")
            return false
        }
    }

    static func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            Log.shared.info("Als Anmeldeobjekt abgemeldet")
        } catch {
            Log.shared.warn("Abmelden fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// `SMAppService` needs a stable location. An app still sitting in
    /// ~/Downloads may be re-quarantined or moved out from under the
    /// registration, so the setup window nudges the user to /Applications.
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(Paths.home.path + "/Applications/")
    }
}
