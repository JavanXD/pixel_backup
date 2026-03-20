import AppKit

extension Notification.Name {
    /// Posted by the AppKit status-item menu so SwiftUI can open a new window.
    static let openNewWindow = Notification.Name("PixelBackup.openNewWindow")
}

// MARK: -

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        observeCoordinator()
        rescueOffScreenWindows()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        rescueOffScreenWindows()
    }

    /// Keep the app alive when the last window closes so the menu-bar icon
    /// remains active during long background transfers.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - NSStatusItem (AppKit — always anchors menu to icon on correct display)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(running: false)
        statusItem?.menu = buildMenu()
        statusItem?.menu?.delegate = self
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Row 0: dynamic status label (updated in menuWillOpen)
        let statusRow = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Pixel Backup",
                              action: #selector(openMainWindow),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let newWin = NSMenuItem(title: "New Window",
                                action: #selector(requestNewWindow),
                                keyEquivalent: "n")
        newWin.keyEquivalentModifierMask = .command
        newWin.target = self
        menu.addItem(newWin)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Pixel Backup",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    // Refresh the status label just before the menu appears.
    func menuWillOpen(_ menu: NSMenu) {
        let count = BackupCoordinator.shared.runningCount
        let label: String
        switch count {
        case 0:  label = "Idle"
        case 1:  label = "1 backup running…"
        default: label = "\(count) backups running…"
        }
        menu.items.first?.title = label
    }

    private func updateStatusIcon(running: Bool) {
        let name = running ? "arrow.down.circle" : "iphone.and.arrow.forward"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Pixel Backup")
        img?.isTemplate = true   // adapts to light/dark menu bar automatically
        statusItem?.button?.image = img
    }

    // MARK: - Actions

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Bring the frontmost app window into view; if none exists, open a new one.
        let appWindows = NSApp.windows.filter { $0.canBecomeKey && $0.isVisible }
        if let w = appWindows.first {
            w.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .openNewWindow, object: nil)
        }
    }

    @objc private func requestNewWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's openWindow is only callable from a view, so we bridge via
        // NotificationCenter. WindowRoot observes this and calls openWindow(id:).
        NotificationCenter.default.post(name: .openNewWindow, object: nil)
    }

    // MARK: - Observe coordinator for icon updates

    private func observeCoordinator() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onBackupCountChanged(_:)),
            name: .backupCountChanged,
            object: nil
        )
    }

    @objc private func onBackupCountChanged(_ note: Notification) {
        let count = (note.object as? Int) ?? 0
        updateStatusIcon(running: count > 0)
    }

    // MARK: - Off-screen rescue

    /// If a window's frame doesn't intersect any visible screen, move it to
    /// the center of the main screen (handles disconnected external displays).
    private func rescueOffScreenWindows() {
        let screens = NSScreen.screens
        for window in NSApp.windows where window.isVisible || window.isMiniaturized {
            let onScreen = screens.contains { $0.visibleFrame.intersects(window.frame) }
            guard !onScreen else { continue }
            if let mainScreen = NSScreen.main {
                window.setFrameOrigin(NSPoint(
                    x: mainScreen.visibleFrame.midX - window.frame.width  / 2,
                    y: mainScreen.visibleFrame.midY - window.frame.height / 2
                ))
            }
        }
    }
}
