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
                Log.shared.debug("Mitteilungen nicht verfügbar: \(error.localizedDescription)")
            } else {
                Log.shared.debug("Mitteilungen erlaubt: \(granted)")
            }
        }
    }

    static func notifyAccessBlocked() {
        let content = UNMutableNotificationContent()
        content.title = "Wooosh braucht noch eine Freigabe"
        content.body = """
            Ohne Festplattenvollzugriff kann Wooosh den iCloud-Cache nicht aufräumen. \
            Zum Einrichten hier klicken.
            """
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: blockedIdentifier,
            content: content,
            trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.shared.debug("Mitteilung nicht zustellbar: \(error.localizedDescription)")
            }
        }
    }

    static func clearAccessBlocked() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [blockedIdentifier])
    }
}
