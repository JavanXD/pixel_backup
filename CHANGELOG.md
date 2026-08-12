# Changelog

All notable changes to Pixel Backup are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---
## Docs Update Rules

When something changes, update the file that matches the intent:

- `CHANGELOG.md` (user-visible release notes)
  - Add new bullets under `## [Unreleased]` → `### Added` / `### Changed` / `### Fixed`.
  - Keep this section accurate because the GitHub release workflow pulls the text from `CHANGELOG.md` and publishes it as the GitHub Release body.
  - Before cutting a release (tag `vX.Y.Z`): move all `## [Unreleased]` bullets into the new version heading, then leave `## [Unreleased]` ready for the next cycle.

- `TODO.md` (remaining work / checklists)
  - Mark tasks as done or remove them when you fully implement and verify them.
  - If something is “implemented but not yet released”, keep it in `CHANGELOG.md` and leave TODO focused on what’s still left.

- `IMPROVEMENTS.md` (deep development notes + rationale)
  - Use for deeper “why/how” documentation and technical decisions (problem → root cause → fix).
  - Prefer `CHANGELOG.md` for short, user-facing statements instead of copying long technical writeups here.

---

## [Unreleased]

### Added
- `PrivacyInfo.xcprivacy` privacy manifest (UserDefaults CA92.1; no tracking / no collected data)
- `Documents` added as a default copy folder
- App icon — custom 1024×1024 design with all required macOS sizes bundled as `AppIcon.icns`
- `build.sh` now auto-installs the built `.app` to `/Applications` after every build (removes the old copy first to prevent nesting)
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
- Release CI builds a universal binary (arm64 + x86_64 via `lipo`) and injects the tag version into `Info.plist`
- Backup history now reads `.transfer_meta/manifest.tsv` instead of walking every file — critical performance fix for large backups (18k stat() calls → 1 file read)
- Multiple independent windows (`⌘N`) — each window owns its own `BackupManager` so two devices can be backed up simultaneously
- Menu bar replaced SwiftUI `MenuBarExtra` with `NSApplicationDelegate`-managed `NSStatusItem` — fixes context menu appearing on the wrong display in multi-monitor setups
- Backup folder names are now dated: `YYYY-MM-DD_DeviceName_Serial/`
- `sanitize_name()` now strips Unicode, emoji, and multi-byte characters; TCP/IP serials (containing colons) are sanitised for use in macOS paths

### Fixed
- Crash on backup end (`NOCOPY_SETTER_IMPL` / SIGABRT): `terminationHandler` no longer clears `Process.standardOutput`/`standardError` while `NSFileHandle` fd-monitoring is still active; the pipe is detached via `readabilityHandler = nil` on the main actor instead
- App crash near backup summary caused by `@MainActor` isolation: `DispatchQueue.main.async` replaced with `Task { @MainActor in }` in termination handler
- Thread-safety warning in `readabilityHandler` — buffer access confined to a dedicated serial `DispatchQueue`
- `NotificationManager` crash when running via `swift run` without a bundle identifier
- Off-screen windows (e.g. from a disconnected external monitor) are relocated to the main display on launch and focus
- **Cancel crash**: stale terminations from a previously cancelled process cannot touch a newer backup (`backupID` guard); pipe teardown happens only on the main actor after detaching the file-handle reader
- **Cancelled summary not shown**: clicking Cancel while the script was in progress showed only the raw log tail; `handleTermination(exit 130)` now parses the partial summary that `on_interrupt()` prints and transitions to `.done(summary:)` with `wasCancelled = true` — so the structured SummaryCard appears with a "Backup Cancelled" header and a "Back" button
- **State race after completion**: log-line tasks still queued on the main actor when `handleTermination` fires could overwrite `.done(summary:)` with `.failed`; `isTerminating` flag prevents this
- **`readabilityHandler` resource leak**: the pipe's file handle handler was never set to `nil` after process exit; it is now cleared at the start of `handleTermination`

---

## [1.1.0] — 2026-08-12

### Added
- Pause and Resume during an active backup (soft pause: stops cleanly, Resume skips already-copied files)
- Soft-pause when destination free space drops below the critical threshold (exit 75) instead of aborting
- Continue unfinished backups from a previous date — resume into the old dated folder instead of creating today's new one (config banner + History Continue)
- `DEST_ROOT_OVERRIDE` env var / `.transfer_meta/run_status` so runs can target an existing folder and record complete/paused/interrupted/failed

### Changed
- Low-disk runtime warnings are throttled (once per healthcheck interval) so they no longer spam every file
- Hint banners in the app dedupe identical messages
- Critically low destination space soft-pauses with a Resume path instead of a fatal abort

### Fixed
- Low-disk WARN spam during transfer: each file under the warn threshold produced a new hint banner; warnings are now throttled and banners dedupe identical text
- Critically low destination disk no longer fatal-aborts the backup; the run soft-pauses so progress is kept and Resume can continue after freeing space

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
- **Wireless ADB support** — connect to any Android device over Wi-Fi without a USB cable:
  - "Connect wirelessly" expandable section in the device panel: enter an IP address and tap Connect
  - Saved addresses persist across app restarts and auto-reconnect every poll cycle
  - Android Wireless Debugging pairing flow (Settings → Developer options → Wireless debugging → Pair device with pairing code) via a dedicated `WirelessPairingSheet`
  - Connected wireless devices show a Wi-Fi icon; USB devices show a cable icon
  - Disconnect button per wireless device; offline saved addresses shown as "reconnecting…" with a remove button
