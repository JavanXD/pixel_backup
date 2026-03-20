import UserNotifications
import AppKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    // nil when running without a bundle (e.g. `swift run`) — all calls below are no-ops in that case
    private let center: UNUserNotificationCenter?

    private override init() {
        // UNUserNotificationCenter.current() throws an assertion if the process
        // has no bundle identifier, which happens when launched via `swift run`.
        if Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
        super.init()
        center?.delegate = self
    }

    // MARK: - Permission

    func requestPermission() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    // MARK: - Completion notification

    func sendCompletion(filesCopied: Int, gb: Double, failed: Int) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = failed > 0
            ? L10n("notification.backup.title.with_errors")
            : L10n("notification.backup.title.success")
        content.body = failed > 0
            ? L10n("notification.backup.body.with_errors", filesCopied, gb, failed)
            : L10n("notification.backup.body.success", filesCopied, gb)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "backup-complete-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil   // deliver immediately
        )
        center.add(request)
    }

    // MARK: - Delegate: show notification even when app is in foreground

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Clicking the notification brings the app to front
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows { window.makeKeyAndOrderFront(nil) }
        completionHandler()
    }
}
