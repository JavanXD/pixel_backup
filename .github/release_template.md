## Download

| File | Description |
|---|---|
| `PixelBackup-{version}.dmg` | macOS app — drag to Applications and run |
| `pixel_backup.sh` | Shell script — works standalone with `adb` in PATH |

**System requirements:** macOS 13 Ventura or later · Apple Silicon and Intel

---

## Install

1. Download `PixelBackup-{version}.dmg`
2. Open the DMG and drag **PixelBackup** to your **Applications** folder
3. Launch from Applications (or Spotlight)

> **"App can't be opened" warning?**
> Right-click (Control-click) the app icon → **Open**. You only need to do this once.
> This prompt does not appear on notarized releases.

---

## Shell script (no installer)

```bash
brew install android-platform-tools
chmod +x pixel_backup.sh
./pixel_backup.sh --help
```

No DMG, no trust decisions, works on any macOS with `bash` and `adb`.

---

## What's new

<!-- release notes auto-inserted from CHANGELOG.md by the release workflow -->
