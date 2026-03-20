import SwiftUI

@main
struct PixelBackupApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // DeviceManager is shared — it only polls hardware, no per-transfer state.
    @StateObject private var deviceManager = DeviceManager()

    var body: some Scene {
        // WindowRoot creates a fresh BackupManager for every window/tab,
        // so each instance operates completely independently.
        WindowGroup(id: "main") {
            WindowRoot()
                .environmentObject(deviceManager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .newItem) {}

            CommandMenu("Backup") {
                Button("Refresh Devices") {
                    Task { await deviceManager.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        // Note: MenuBarExtra removed — the status item is managed directly by
        // AppDelegate using NSStatusItem so the menu always appears anchored
        // to the icon on the correct display (SwiftUI MenuBarExtra has a known
        // positioning bug on multi-display setups).
    }
}
