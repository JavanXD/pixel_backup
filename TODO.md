# TODO

Remaining work across the project. Everything already implemented is tracked in `CHANGELOG.md`.

---

## Shell Script

---

## macOS App

### Pause / disk safety (QA)
- [ ] Pause mid-transfer → Resume continues and skips already-copied files
- [ ] Low-disk soft-pause: with destination under `RUNTIME_FREE_SPACE_STOP_GB`, transfer pauses (not crash) and Resume works after freeing space
- [ ] Low-disk warn does not spam a banner per file (at most once per healthcheck interval)
- [ ] Continue unfinished: an older dated incomplete folder for the connected device shows "Continue Unfinished" and writes into that folder (not today's)
- [ ] History → Continue / Add to resumes into the chosen dated folder

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
- [x] Enrol at [developer.apple.com](https://developer.apple.com) ($99/yr)
  *(Team `23KDS46W6C` — same personal team as ClipDictate; keychain has `Apple Development: Javan Rasokat (3AD66N4HYL)`)*
- [ ] Register bundle ID `com.pixelbackup.app` in the Developer Portal
  *(not verified locally — confirm under Certificates, Identifiers & Profiles → Identifiers)*
- [ ] Create a **Developer ID Application** certificate (not Mac App Distribution)
  *(not in keychain; ClipDictate also still uses Apple Development only — no `Developer ID Application: …` identity found)*
- [ ] Export certificate as `.p12` with a password
  *(no Developer ID `.p12` found under Projects / Downloads / Documents / Desktop; only unrelated Endor/pynt certs)*

### Step 3 — Add CI/CD secrets to GitHub repository
> Settings → Secrets and variables → Actions → New repository secret
>
> Needs the Developer ID `.p12` from Step 2. `NOTARY_TEAM` for this account is `23KDS46W6C`.

| Secret name | Value |
|---|---|
| `DEVELOPER_ID_APP` | `Developer ID Application: Your Name (TEAMID)` |
| `DEVELOPER_ID_CERT_P12` | `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | Password used when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any strong password (used only in CI keychain) |
| `APPLE_ID` | Your Apple ID email |
| `NOTARY_TEAM` | `23KDS46W6C` |
| `NOTARY_PASSWORD` | App-specific password from [appleid.apple.com](https://appleid.apple.com) |

### Step 4 — Universal binary (arm64 + x86_64)
- [x] Update `release.yml` CI to build a fat/universal binary (`swift build` per arch + `lipo`)

### Step 5 — Version injection in CI
- [x] Update `release.yml` to write the tag version into `Info.plist` before building
  (`CFBundleShortVersionString` from tag, `CFBundleVersion` from `github.run_number`)

### Step 6 — Privacy manifest
- [x] Add `PrivacyInfo.xcprivacy` to `Sources/PixelBackup/Resources/`
  *(included via Package.swift `.copy("Resources")`; also copied explicitly by `build.sh` / release assemble)*

### Step 7 — Pre-release checklist
- [ ] Gatekeeper check after signing: `spctl --assess --type execute --verbose PixelBackup.app`
  *(runs automatically in CI after notarization when secrets are present)*
- [ ] Smoke-test the DMG on a clean machine (no Xcode, no `adb` in PATH)
- [x] Update `CHANGELOG.md` — `1.1.0` cut for pause/disk/continue; other items remain under Unreleased
- [ ] Publish release: `git tag v1.1.0 && git push origin v1.1.0`

---

## GitHub Repository Polish

### Trust & security
- [x] Add **notarization** to CI *(already in `release.yml`; activates when Step 3 secrets are set)*
- [x] Document the **ad-hoc fallback** in README (right-click → Open on first launch)
- [x] Note in README that corporate MDM-managed Macs ("App Store only") should use the shell script

### Auto-update
- [x] In-app update check (`UpdateChecker` → GitHub releases API + dismissible banner)

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
`adb -s <serial> pull …` works identically over USB and WiFi. **Implemented** in
`DeviceManager` + pairing sheet; remaining items are device QA only.

### How wireless ADB works (background)

| Mode | Android version | Needs USB first? |
|---|---|---|
| **TCP/IP mode** | Any (with USB debugging) | Yes — once to run `adb tcpip 5555`, then USB-free forever |
| **Wireless Debugging** | Android 11+ | No — fully wireless including pairing |

In both cases the device shows up in `adb devices` as `<ip>:<port>` (e.g. `192.168.1.10:5555`).
The `:` in the serial is already handled correctly by `sanitize_name()` in the shell script.

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
