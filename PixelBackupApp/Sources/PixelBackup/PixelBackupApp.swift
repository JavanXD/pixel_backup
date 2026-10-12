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
        // Note: MenuBarExtra removed — AppDelegate owns an NSStatusItem and pops
        // the menu in the button's coordinate space (avoids wrong-display menus).
    }
}
