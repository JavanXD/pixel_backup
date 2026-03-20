import Foundation

extension Notification.Name {
    /// Fired on the main thread whenever the running backup count changes.
    /// `object` is the new count as an `Int`.
    static let backupCountChanged = Notification.Name("PixelBackup.backupCountChanged")
}

/// Lightweight singleton that aggregates running-backup state across all windows.
/// Windows report start/finish here; AppDelegate observes via NotificationCenter.
@MainActor
final class BackupCoordinator: ObservableObject {

    static let shared = BackupCoordinator()
    private init() {}

    @Published private(set) var runningCount: Int = 0

    func didStart() {
        runningCount += 1
        notify()
    }

    func didFinish() {
        runningCount = max(0, runningCount - 1)
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .backupCountChanged, object: runningCount)
    }
}
