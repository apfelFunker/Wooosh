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
            Log.shared.info("Registered as a login item")
            return true
        } catch {
            Log.shared.warn("Could not register as a login item: \(error.localizedDescription)")
            return false
        }
    }

    static func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            Log.shared.info("Removed as a login item")
        } catch {
            Log.shared.warn("Could not remove the login item: \(error.localizedDescription)")
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
