# Changelog

All notable changes to Pixel Backup are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added
- Real-time transfer speed (MB/s) and ETA displayed in the progress view
- Elapsed time counter (`Xm Ys elapsed`) during active backups
- Current filename shown live under the progress bar while copying
- Free disk space indicator on the destination picker (colour-coded: red <5 GB, orange <20 GB)
- Last backup summary strip on config panel (date, file count, GB — read from manifest, not filesystem scan)
- "Try Again" / "New Backup" button on failed and cancelled states
- `⌘Return` keyboard shortcut to start a backup from the config panel
- `+` toolbar button to open a new independent window when only one window is open
- USB debugging step-by-step inline guide shown when no device is detected
- Music and Backups added as default copy folders
- Custom folder paths: add any Android path via the UI (shown as purple pills)
- Drag-and-drop destination folder onto the window or destination picker row
- History view shows "Folder moved or deleted" warning for stale entries
- English, German, Spanish, and French localization
- `--help` flag on `pixel_backup.sh` prints all environment variable parameters

### Changed
- Backup history now reads `.transfer_meta/manifest.tsv` instead of walking every file — critical performance fix for large backups (18k stat() calls → 1 file read)
- Multiple independent windows (`⌘N`) — each window owns its own `BackupManager` so two devices can be backed up simultaneously
- Menu bar replaced SwiftUI `MenuBarExtra` with `NSApplicationDelegate`-managed `NSStatusItem` — fixes context menu appearing on the wrong display in multi-monitor setups
- Backup folder names are now dated: `YYYY-MM-DD_DeviceName_Serial/`
- `sanitize_name()` now strips Unicode, emoji, and multi-byte characters; TCP/IP serials (containing colons) are sanitised for use in macOS paths

### Fixed
- App crash near backup summary caused by `@MainActor` isolation: `DispatchQueue.main.async` replaced with `Task { @MainActor in }` in termination handler
- Thread-safety warning in `readabilityHandler` — buffer access confined to a dedicated serial `DispatchQueue`
- `NotificationManager` crash when running via `swift run` without a bundle identifier
- Off-screen windows (e.g. from a disconnected external monitor) are relocated to the main display on launch and focus
- **Cancel crash**: if the user started a new backup while a previously-cancelled process was still winding down, `handleTermination` would call `process?.standardOutput = nil` on the *new* (running) process — Foundation raises an exception for this. The pipe is now disconnected inside the `terminationHandler` closure (where `proc` is the already-terminated instance), and a `backupID` UUID guards against stale terminations ever touching a newer backup's state
- **Cancelled summary not shown**: clicking Cancel while the script was in progress showed only the raw log tail; `handleTermination(exit 130)` now parses the partial summary that `on_interrupt()` prints and transitions to `.done(summary:)` with `wasCancelled = true` — so the structured SummaryCard appears with a "Backup Cancelled" header and a "Back" button
- **State race after completion**: log-line tasks still queued on the main actor when `handleTermination` fires could overwrite `.done(summary:)` with `.failed`; `isTerminating` flag prevents this
- **`readabilityHandler` resource leak**: the pipe's file handle handler was never set to `nil` after process exit; it is now cleared at the start of `handleTermination`

---

## [0.1.0] — 2026-03-19

### Added
- `pixel_backup.sh` core script
  - ADB auto-recovery (reconnect loop, device state detection)
  - Per-file retries with configurable backoff
  - Skip-on-size-match to avoid duplicating already-copied files
  - Pre-copy disk space check (fast mode and full-estimate mode)
  - Runtime disk space guard (warn and abort at configurable thresholds)
  - Bootstrap logging with fallback to stdout before log file is initialised
  - Multi-device support (`DEVICE_SELECTION=auto/all/first`, `DEVICE_SERIAL`)
  - Separate dated per-device destination folders
  - Runtime operator hints (phone locked, USB mode, unauthorized, offline)
  - Hidden file and directory exclusion
  - Storage root auto-detection (`/sdcard`, `/storage/emulated/0`, `/storage/self/primary`)
  - Graceful `Ctrl+C` handling with partial summary and temp file cleanup
  - `find -printf` for fast on-device file listing (no per-file `stat` shell loop)
  - Per-device manifests, run manifests, failure log, and transfer log
- Native macOS SwiftUI app (macOS 13+)
  - Device picker with auto-select and live refresh
  - Folder selection with toggles for built-in paths
  - Destination path picker with `NSOpenPanel`
  - Live log view with colour-coded log levels
  - Backup summary card (files copied, GB, failures)
  - Backup history view with dated folder list
  - System notification on backup completion
  - Menu bar mode — app stays running after window close
  - Bundled `adb` binary — no separate install required
  - `adb` not found onboarding guide (`SetupGuideView`)
