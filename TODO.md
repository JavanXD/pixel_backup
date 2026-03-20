# TODO

Remaining work across the project. Everything already implemented is tracked in `CHANGELOG.md`.

---

## Shell Script

---

## macOS App

### Device Testing
- [ ] Verify resume / skip logic — run a second time; already-copied files must be SKIP, not re-copied
- [ ] Test cancel — press Cancel mid-transfer; confirm partial files are cleaned up and the SummaryCard appears with "Backup Cancelled" header showing files copied so far
- [ ] Test on Apple Silicon Mac (M-series)
- [ ] Test on Intel Mac (pre-2021)

---

## Distribution — GitHub Releases (recommended path)

This is the right distribution path for this app. The App Store requires a fully sandboxed app,
which is architecturally incompatible with executing a bundled `adb` binary and writing to
user-chosen folders (see **App Store** section below for details).

### Step 2 — Apple Developer Program
- [ ] Enrol at [developer.apple.com](https://developer.apple.com) ($99/yr)
- [ ] Register bundle ID `com.pixelbackup.app` in the Developer Portal
- [ ] Create a **Developer ID Application** certificate (not Mac App Distribution)
- [ ] Export certificate as `.p12` with a password

### Step 3 — Add CI/CD secrets to GitHub repository
> Settings → Secrets and variables → Actions → New repository secret

| Secret name | Value |
|---|---|
| `DEVELOPER_ID_APP` | `Developer ID Application: Your Name (TEAMID)` |
| `DEVELOPER_ID_CERT_P12` | `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | Password used when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any strong password (used only in CI keychain) |
| `APPLE_ID` | Your Apple ID email |
| `NOTARY_TEAM` | 10-character Team ID from developer.apple.com |
| `NOTARY_PASSWORD` | App-specific password from [appleid.apple.com](https://appleid.apple.com) |

### Step 4 — Universal binary (arm64 + x86_64)
- [ ] Update `release.yml` CI to build a fat/universal binary so the DMG runs on both
  Apple Silicon and Intel Macs without separate downloads:
  ```yaml
  - name: Build universal binary
    run: |
      swift build -c release --arch arm64  --package-path PixelBackupApp
      swift build -c release --arch x86_64 --package-path PixelBackupApp
      lipo -create -output PixelBackupApp/.build/release/PixelBackup \
        PixelBackupApp/.build/arm64-apple-macosx/release/PixelBackup \
        PixelBackupApp/.build/x86_64-apple-macosx/release/PixelBackup
  ```

### Step 5 — Version injection in CI
- [ ] Update `release.yml` to write the tag version into `Info.plist` before building,
  so `CFBundleShortVersionString` and `CFBundleVersion` match the release tag:
  ```yaml
  - name: Inject version
    run: |
      /usr/libexec/PlistBuddy -c \
        "Set :CFBundleShortVersionString ${{ steps.version.outputs.version }}" \
        PixelBackupApp/Sources/PixelBackup/Info.plist
      /usr/libexec/PlistBuddy -c \
        "Set :CFBundleVersion ${{ github.run_number }}" \
        PixelBackupApp/Sources/PixelBackup/Info.plist
  ```

### Step 6 — Privacy manifest
- [ ] Add `PrivacyInfo.xcprivacy` to `Sources/PixelBackup/Resources/` — required by Apple
  since May 2024 for any app using `UserDefaults`, file-system APIs, or network access.
  Minimum content (no data collected, no tracking):
  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>NSPrivacyTracking</key><false/>
      <key>NSPrivacyTrackingDomains</key><array/>
      <key>NSPrivacyCollectedDataTypes</key><array/>
      <key>NSPrivacyAccessedAPITypes</key>
      <array>
          <dict>
              <key>NSPrivacyAccessedAPIType</key>
              <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
              <key>NSPrivacyAccessedAPITypeReasons</key>
              <array><string>CA92.1</string></array>
          </dict>
      </array>
  </dict>
  </plist>
  ```
- [ ] Add `PrivacyInfo.xcprivacy` to the `resources` list in `Package.swift`

### Step 7 — Pre-release checklist
- [ ] Gatekeeper check after signing: `spctl --assess --type execute --verbose PixelBackup.app`
- [ ] Smoke-test the DMG on a clean machine (no Xcode, no `adb` in PATH)
- [ ] Update `CHANGELOG.md` — move Unreleased items under the new version heading
- [ ] Publish release: `git tag v1.0.0 && git push origin v1.0.0`

---

## GitHub Repository Polish

### Trust & security
- [ ] Add **notarization** to CI (secrets in Step 3 above) — this is what makes the DMG open
  without any warning on personal Macs running default Gatekeeper settings ("identified developers")
- [ ] Document the **ad-hoc fallback** clearly in README for users who download before notarization
  is set up: right-click → Open on first launch (one-time bypass, fully safe)
- [ ] Note in README that corporate MDM-managed Macs ("App Store only" policy via Jamf/Kandji)
  **cannot** open any non-App-Store app — users in that situation should use the shell script
  directly: `brew install android-platform-tools && ./pixel_backup.sh`

### Auto-update
- [ ] Add an **in-app update check** — on launch, query the GitHub releases API
  (`https://api.github.com/repos/OWNER/REPO/releases/latest`) and show a dismissible banner
  if a newer version tag exists. No telemetry — purely a version string comparison.
  This replaces the need for Sparkle (heavy) for a simple personal tool.

### Discoverability & installation
- [ ] Add a **Homebrew cask** once a notarized DMG release exists:
  create `homebrew-cask/Casks/pixel-backup.rb` and submit a PR to
  [homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask).
  This lets users install with `brew install --cask pixel-backup` — the most
  trusted installation path short of the App Store for macOS power users.
- [ ] Add additional screenshots to `docs/screenshots/` — progress view, backup history, dark mode
  (GitHub shows these in the repo and they improve click-through from search results)

---

## Wireless ADB Support

Wireless ADB lets the app back up a phone over the local network — no USB cable required.
The existing backup engine already works with TCP serials (e.g. `192.168.1.10:5555`) because
`adb -s <serial> pull …` works identically over USB and WiFi. **No changes are needed to
`BackupManager` or `pixel_backup.sh`.** All work is in the device-discovery / connection layer.

### How wireless ADB works (background)

There are two modes:

| Mode | Android version | Needs USB first? |
|---|---|---|
| **TCP/IP mode** | Any (with USB debugging) | Yes — once to run `adb tcpip 5555`, then USB-free forever |
| **Wireless Debugging** | Android 11+ | No — fully wireless including pairing |

In both cases the device shows up in `adb devices` as `<ip>:<port>` (e.g. `192.168.1.10:5555`).
The `:` in the serial is already handled correctly by `sanitize_name()` in the shell script.

---

---

### Testing checklist
- [ ] TCP/IP mode: connect USB → `adb tcpip 5555` in Terminal → unplug → app shows device
- [ ] Wireless Debugging pairing (Android 11+): pair via sheet → connect → backup runs
- [ ] Auto-reconnect: connect wirelessly → quit app → reopen → device re-appears automatically
- [ ] App restart persistence: saved address survives quit/relaunch
- [ ] Disconnect button removes the saved address and drops the ADB connection
- [ ] Colon-in-serial: backup destination folder name must not contain raw `:` (already handled by `sanitize_name()` in the script — verify)

---

## Future Ideas

- [ ] Scheduled / automatic backups via `LaunchAgent`

---

## How to open the app

```bash
cd PixelBackupApp
swift run
# or open in Xcode:
open Package.swift
```

> The `adb` binary at `Sources/PixelBackup/Resources/adb` is already bundled locally.
> It is excluded from git (binary file). CI downloads it automatically.
> To refresh it locally:
> ```bash
> curl -L -o /tmp/pt.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
> unzip -j /tmp/pt.zip platform-tools/adb -d PixelBackupApp/Sources/PixelBackup/Resources/
> chmod +x PixelBackupApp/Sources/PixelBackup/Resources/adb
> ```
