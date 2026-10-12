import AppKit

extension Notification.Name {
    /// Posted by the AppKit status-item menu so SwiftUI can open a new window.
    static let openNewWindow = Notification.Name("PixelBackup.openNewWindow")
}

// MARK: -

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    /// Retained menu shown via click handler (never assigned to `statusItem.menu`
    /// permanently — that path can open on the wrong display with multiple monitors).
    private var statusMenu: NSMenu!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        observeCoordinator()
        rescueOffScreenWindows()

        // Best-effort: show a dismissible update banner if a newer GitHub release exists.
        UpdateChecker.shared.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        rescueOffScreenWindows()
    }

    /// Keep the app alive when the last window closes so the menu-bar icon
    /// remains active during long background transfers.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - NSStatusItem
    //
    // Do not set `statusItem.menu` permanently. With multiple displays (or a
    // key window on another screen), AppKit can present that menu on the wrong
    // display. Instead, handle the button click and pop the menu up in the
    // status-item button's coordinate space so it tracks the icon.

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu = buildMenu()
        statusMenu.delegate = self
        updateStatusIcon(running: false)

        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        // Highlight while open; menuDidClose clears it.
        button.isHighlighted = true

        // Anchor in the button's local space so the menu opens under the icon
        // on whichever display hosts the menu bar item.
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
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
        statusItem?.button?.isHighlighted = true
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.button?.isHighlighted = false
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
