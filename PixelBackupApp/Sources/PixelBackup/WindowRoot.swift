import SwiftUI

/// Root view for each window. Owns its own BackupManager so every window
/// operates completely independently of every other window.
struct WindowRoot: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @StateObject private var backupManager = BackupManager()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environmentObject(deviceManager)
            .environmentObject(backupManager)
            .frame(minWidth: 760, minHeight: 560)
            // Bridge from AppKit status-item menu → SwiftUI openWindow.
            // Only the frontmost window responds (others ignore it too, but
            // SwiftUI deduplicates window openings automatically).
            .onReceive(NotificationCenter.default.publisher(for: .openNewWindow)) { _ in
                openWindow(id: "main")
            }
    }
}
