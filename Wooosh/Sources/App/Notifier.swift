import Foundation
import UserNotifications

/// System notifications for the case that matters: Wooosh is running but cannot
/// do its job because Full Disk Access is missing.
///
/// At login the app starts without opening a window, so without this the user
/// would have no way of knowing it is idling. The setup window remains the
/// primary channel — notifications can be refused or silenced, so nothing
/// depends on them being delivered.
enum Notifier {

    private static let blockedIdentifier = "wooosh.access.blocked"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                Log.shared.debug("Notifications not available: \(error.localizedDescription)")
            } else {
                Log.shared.debug("Mitteilungen erlaubt: \(granted)")
            }
        }
    }

    static func notifyAccessBlocked() {
        let content = UNMutableNotificationContent()
        content.title = "Wooosh still needs permission"
        content.body = """
            Without Full Disk Access, Wooosh cannot clear the iCloud cache. \
            Click here to set it up.
            """
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: blockedIdentifier,
            content: content,
            trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.shared.debug("Notification could not be delivered: \(error.localizedDescription)")
            }
        }
    }

    static func clearAccessBlocked() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [blockedIdentifier])
    }
}
