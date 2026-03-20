# Pixel Backup — macOS App

A native macOS app that wraps `pixel_backup.sh` in a polished SwiftUI interface. No terminal, no configuration files — plug in your Pixel phone and press Start.

---

## Stack

| | |
|---|---|
| Language | Swift 5.9 |
| UI framework | SwiftUI (macOS 13 Ventura+) |
| Build system | Swift Package Manager |
| Minimum OS | macOS 13 Ventura |
| Bundled tools | `adb` (Google platform-tools), `pixel_backup.sh` |
| Localisation | English, German, Spanish, French |

The app has no third-party dependencies. Everything is Swift standard library, AppKit, UserNotifications, and SwiftUI.

---

## How it works

`pixel_backup.sh` does all the heavy lifting — device communication, file listing, copy, retry, and skip logic. The app's job is to:

1. Resolve `adb` (bundled binary, falling back to Homebrew)
2. Run `adb devices` every 4 seconds to detect connected phones
3. Launch `pixel_backup.sh` as a child process with the user's configuration passed as environment variables
4. Stream stdout/stderr line by line, parse the structured log output, and drive the UI state machine
5. Send a system notification and update the menu bar icon when done

The script exits with code `0` (success), `130` (cancelled via SIGINT), or non-zero (error). The app maps these to its `BackupState` enum.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  PixelBackupApp  (@main, App)                           │
│  ┌──────────────┐   ┌────────────────┐                  │
│  │ DeviceManager│   │  BackupManager │                  │
│  │              │   │                │                  │
│  │ adb devices  │   │ Process()      │                  │
│  │ every 4s     │   │ stdout pipe    │                  │
│  │ connect/pair │   │ state machine  │                  │
│  └──────┬───────┘   └───────┬────────┘                  │
│         │ [AndroidDevice]   │ [BackupState, Progress]   │
│         └─────────┬─────────┘                           │
│                   ▼                                     │
│            ContentView                                  │
│         ┌──────────────────────────────────┐            │
│         │  config panel  │  progress view  │            │
│         │  summary card  │  history sheet  │            │
│         └──────────────────────────────────┘            │
│                                                         │
│  MenuBarExtra  ──────────────────── menu bar icon       │
│  NotificationManager ────────────── UNUserNotification  │
└─────────────────────────────────────────────────────────┘
```

### Core classes

**`DeviceManager`** — `@MainActor ObservableObject`
Resolves `adb` at startup (bundled → Homebrew Apple Silicon → Homebrew Intel → PATH). Runs `adb devices` on a 4-second timer (`poll()`) and fetches each device's model name via `adb shell getprop ro.product.model`. Sets `adbAvailable` which gates the whole UI.

Wireless ADB methods:
- `connect(address:)` — runs `adb connect <ip:port>`, persists the address in `UserDefaults` on success
- `pair(address:code:)` — runs `adb pair <ip:port> <code>` for the Android Wireless Debugging pairing flow
- `disconnect(serial:)` — runs `adb disconnect` and removes the address from the saved list
- `savedWirelessAddresses` — persisted array of known addresses; `poll()` silently attempts reconnect for any that are offline

**`BackupManager`** — `@MainActor ObservableObject`
Owns the `Process` that runs `pixel_backup.sh`. Feeds configuration as environment variables (`DEVICE_SERIAL`, `DEST_ROOT_BASE`, `REMOTE_DIRS_CSV`, etc.). Reads stdout/stderr through a `Pipe` with a `readabilityHandler`, splits on newlines, and feeds each line to `LogParser`. Publishes:
- `state: BackupState` — the current state machine position
- `progress: BackupProgress` — seen / copied / skipped / failed / GB
- `speedMBps: Double` — rolling 60-second throughput window
- `etaSeconds: Int?` — estimated time remaining
- `logLines: [LogLine]` — capped at 500 lines for the live log view
- `hints: [String]` — HINT/WARN lines surfaced as dismissable banners

**`LogParser`** — stateless utility
Parses raw log lines into typed `LogLine` values. Extracts:
- `PROGRESS seen=N copied=N skipped=N failed=N copied_gb=N.NN` → `BackupProgress`
- `HINT` / `WARN` body text
- `Scan complete: N files in /path` → scan file count
- `Scanning /path` → current directory being scanned
- Final summary block → `BackupSummary`

**`NotificationManager`** — singleton
Requests `UNUserNotificationCenter` permission once on first backup start. Fires a banner notification on completion with file count and GB. Notification click brings the app window to front.

---

## State machine

```
idle
  └─▶ resolvingDevice   (adb health check running)
        └─▶ scanning(dir:)  (find listing a remote folder)
              └─▶ copying      (adb pull in progress)
                    ├─▶ retrying     (second pass for failed files)
                    │     └─▶ finishing
                    │             └─▶ done(summary:)  ──▶ idle
                    ├─▶ failed(message:)
                    └─▶ cancelled
```

---

## Data flow: script → UI

```
pixel_backup.sh stdout
        │
        ▼
  Pipe readabilityHandler  (background thread)
        │  raw String
        ▼
  LogParser.parse()        (background thread)
        │  LogLine
        ▼
  DispatchQueue.main.async
        │
        ▼
  BackupManager.handleLogLine()
        ├── .progress  → update BackupProgress + rolling speed window
        ├── .hint/warn → append to hints[]
        ├── .fatal     → transition state to .failed
        └── .info      → detect "Starting transfer" / "Scanning" / "Retrying"
                ▼
        @Published properties → SwiftUI renders
```

---

## Script integration

The script is configured entirely through environment variables — no config files, no command-line args. `BackupManager` sets:

| Variable | Source |
|---|---|
| `DEVICE_SERIAL` | selected device serial |
| `DEST_ROOT_BASE` | user-chosen destination root |
| `REMOTE_DIRS_CSV` | enabled folder toggles (`DCIM:Pictures`) |
| `PROGRESS_EVERY_FILES` | `50` (more frequent than CLI default of 200) |
| `PRECHECK_FREE_SPACE` | `1` (fast mode) |
| `SHOW_RUNTIME_HINTS` | `1` |
| `HEALTHCHECK_INTERVAL_SECONDS` | `30` |
| `PATH` | prefixed with the directory containing the bundled `adb` |

Cancel is implemented by calling `process.interrupt()` which sends SIGINT to the process group, triggering the script's `on_interrupt()` trap handler for a clean partial summary and graceful exit.

---

## Source layout

```
PixelBackupApp/
├── Package.swift                     SPM manifest (macOS 13+, defaultLocalization: "en")
├── PixelBackup.entitlements          sandbox=false, cs.disable-library-validation
├── build.sh                          assemble + ad-hoc or Developer ID sign + auto-install to /Applications
├── notarize.sh                       xcrun notarytool submit + staple
└── Sources/PixelBackup/
    ├── Info.plist                    bundle metadata, usage descriptions
    ├── AppDelegate.swift             prevents quit on window close (menu bar mode)
    ├── PixelBackupApp.swift          @main, WindowGroup + MenuBarExtra
    ├── ContentView.swift             root view — routes between screens
    ├── Models.swift                  AndroidDevice, BackupState, BackupProgress,
    │                                 BackupSummary, LogLine, RemoteFolder
    ├── LogParser.swift               parses structured script output
    ├── DeviceManager.swift           adb resolution, device list, wireless connect/pair/disconnect, auto-reconnect
    ├── BackupManager.swift           subprocess, log streaming, state machine,
    │                                 rolling speed + ETA, cancel
    ├── NotificationManager.swift     UNUserNotificationCenter wrapper
    ├── L10n.swift                    NSLocalizedString(bundle: .module) helper
    ├── en.lproj/Localizable.strings  English
    ├── de.lproj/Localizable.strings  German
    ├── es.lproj/Localizable.strings  Spanish
    ├── fr.lproj/Localizable.strings  French
    ├── Resources/
    │   ├── adb                       bundled Google platform-tools binary
    │   └── pixel_backup.sh           bundled backup script
    └── Views/
        ├── DeviceSectionView.swift   device picker, wireless connect section, offline device list, USB mode reminder
        ├── WirelessPairingSheet.swift Android Wireless Debugging pairing flow (two-step: pair + connect)
        ├── FolderSelectionView.swift DCIM / Pictures / Movies / Download toggles
        ├── DestinationPickerView.swift NSOpenPanel + drag-and-drop folder target
        ├── HintBannerView.swift      dismissable HINT/WARN banners
        ├── BackupProgressSection.swift progress bar, counters, MB/s, ETA, log tail
        ├── LogView.swift             colour-coded auto-scrolling log
        ├── SummaryCard.swift         post-backup stats, Open Folder / View Log
        ├── BackupHistoryView.swift   list of YYYY-MM-DD_* folders with file counts
        ├── MenuBarStatusView.swift   menu bar dropdown — status, speed, cancel
        └── SetupGuideView.swift      shown when adb cannot be found
```

---

## UI screens

**Config** — device picker (auto-refreshes; wireless devices show a Wi-Fi icon, USB devices a cable icon), "Connect wirelessly" expandable section (IP entry, Connect button, Android Wireless Debugging pairing sheet), folder toggles (DCIM / Pictures / Documents / Movies / Download, persisted), destination folder (NSOpenPanel or drag-and-drop onto the window), Start Backup button.

**Progress** — live log stream, progress bar, counters (seen / copied / skipped / failed), GB copied, rolling MB/s and ETA, dismissable hint banners, Cancel button. Backup continues even if the window is closed — status stays visible in the menu bar.

**Summary** — files and GB copied this run, all-time totals, failed count, Open Folder and View Log buttons, New Backup to return to config.

**History** — sheet opened from the toolbar clock icon. Lists every `YYYY-MM-DD_DeviceName_Serial` folder in the backup root with file count and total size. Open-in-Finder per entry.

**Setup guide** — shown automatically when `adb` is not found anywhere. Step-by-step Homebrew install instructions with a one-click copy button and a Retry Detection button.

**Menu bar** — permanent icon in the system menu bar. Shows current state label, live file counters and MB/s while copying, Open / Cancel / Quit. App stays alive after the main window is closed so long transfers can run unattended.

---

## Localisation

All user-visible strings go through `L10n("key")` (computed properties, notification content) or SwiftUI `Text("literal")` (which uses `LocalizedStringKey` automatically). Adding a new language requires only dropping a new `xx.lproj/Localizable.strings` file into the Sources directory — no code changes needed.

---

## Entitlements and sandboxing

The app runs **without the App Store sandbox** (`com.apple.security.app-sandbox = false`). This is required because:

- It spawns child processes (`/bin/bash`, `adb`)
- It writes to arbitrary user-chosen directories
- The bundled `adb` binary is signed by Google, not by the app's certificate

For Mac App Store distribution the backup logic would need to be rewritten natively in Swift to satisfy sandbox requirements. Direct distribution (Developer ID + Notarization) is the realistic path.
