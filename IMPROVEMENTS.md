# Improvement Log

This document records every meaningful change made to `pixel_backup.sh` during development, including the problem it solved, the root cause, and what was done. Organised chronologically by topic.

---

## 1. Dependency check and error on missing `adb`

**Problem:** Script failed silently or with a confusing error when `adb` was not installed.

**Fix:** Added `require_cmd` for all external tools the script depends on (`adb`, `awk`, `sed`, `stat`, `mkdir`, `dirname`, `basename`, `cut`, `sort`, `wc`, `tr`, `sleep`, `date`, `df`). If any is missing the script exits immediately with a clear message.

**Install fix for macOS:**
```bash
brew install android-platform-tools
```

---

## 2. Reliability and self-healing

**Problem:** The original script had no recovery logic. A single USB hiccup, device lock, or ADB disconnect would abort the whole run.

**Fixes:**
- Added `recover_adb()`: retries `adb start-server`, `adb reconnect`, and `adb wait-for-device` up to `MAX_ADB_RECOVERY_ATTEMPTS` times with exponential backoff.
- Added `wait_for_device()`: polls `adb get-state` up to `ADB_WAIT_SECONDS` before giving up.
- Added `ensure_device_ready()`: checks immediately if device is ready; only enters recovery if it is not (avoids unnecessary recovery noise on healthy runs).
- Per-file retry loop in `copy_one()`: retries each file up to `MAX_PULL_ATTEMPTS` times. On each failure, removes the partial local file, attempts ADB recovery, then sleeps with increasing backoff before retrying.
- End-of-run retry pass: `retry_failed_once()` re-attempts all files that ended in `failed.tsv` after the main copy loop.

**Tuning:**
```bash
MAX_PULL_ATTEMPTS=5 MAX_ADB_RECOVERY_ATTEMPTS=5 ADB_WAIT_SECONDS=60 ./pixel_backup.sh
```

---

## 3. `set -euo pipefail` + `trap ERR`

**Problem:** Silent failures; partial-state errors could propagate undetected.

**Fix:**
- `set -euo pipefail` causes the script to exit on any unhandled error, unset variable, or failed pipe stage.
- `trap 'on_error "$?" "$LINENO"' ERR` logs the line number and exit code whenever the script aborts unexpectedly.

---

## 4. Bootstrap logging (log before device paths exist)

**Problem:** `log()` always wrote to `${LOG}` via `tee`. Before a device was identified, `LOG` was empty, causing `tee: : No such file or directory` spam on every startup log line.

**Root cause:** Early calls like `die "No online adb devices found"` happened before per-device paths were initialised.

**Fix:** Made `log()` three-tier:
1. If `LOG` is set, write there (normal operation).
2. If not, write to `BOOTSTRAP_LOG` (`~/Pictures/pixel_backup/.transfer_meta/bootstrap.log`).
3. If neither, fall back to stdout only.

`on_error()` also adapts its message to point at whichever log is available.

---

## 5. Multi-device support

**Problem:** Script assumed exactly one device. With multiple devices connected, `adb` commands were ambiguous and could target the wrong device.

**Fixes:**
- All `adb` calls go through `adb_for_device()` which always passes `-s ${CURRENT_SERIAL}`.
- `adb_for_device` also redirects stdin from `/dev/null` — critical for preventing `adb shell` calls inside read loops from consuming the listing stream (which caused corrupted filenames).
- Added `resolve_target_devices()` with three modes:
  - `auto` (default): exactly one device required; aborts with guidance if multiple are connected.
  - `all`: processes every online device sequentially.
  - `first`: uses the first device returned by `adb devices`.
  - `DEVICE_SERIAL=<serial>`: explicit override, ignores selection mode.
- Each device runs through its own `run_for_current_device()` loop with isolated paths and counters.
- Per-device output directories: `DEST_ROOT_BASE/<model>_<serial>/` to prevent cross-device file collisions.

---

## 6. Per-device output isolation

**Problem:** Multiple devices writing to the same destination could overwrite each other's files (both phones may have `/sdcard/DCIM/Camera/IMG_001.jpg`).

**Fix:** `SEPARATE_DEVICE_DIRS=1` (default) namespaces output under `YYYY-MM-DD_<model>_<serial>/`. Set `SEPARATE_DEVICE_DIRS=0` to use a shared root (with a startup warning logged when multiple devices are selected).

Example folder name: `2026-03-19_Pixel_10_Pro_XL_59110DLCQ002SF`

---

## 7. Storage root auto-detection

**Problem:** Hard-coded `/sdcard/DCIM` paths failed or appeared empty on some devices, especially when USB mode was set to Charging-only. On Pixel phones without a physical SD card, `/sdcard` is a symlink to `/storage/emulated/0`.

**Root cause:** `/sdcard` exists as a symlink on all modern Android phones — it always points to internal storage. However, if USB mode is not "File Transfer", the path is mounted but empty.

**Fix:** Added `resolve_storage_root()`:
- Probes `/sdcard`, `/storage/emulated/0`, `/storage/self/primary` in order.
- Verifies the path is non-empty (an empty root indicates Charging-only USB mode).
- Logs which root was found; falls back to `/sdcard` with a clear hint if none work.

Added `resolve_remote_dirs()`:
- Resolves each configured folder name against the detected storage root.
- Logs `OK` or `SKIP` per directory.
- Hard-aborts if **zero** directories are accessible, with an explicit hint to switch USB mode to File Transfer.

---

## 8. Hidden file and directory filtering

**Problem:** Android stores system/cache data in hidden paths (names starting with `.`). Copying these wastes time and bandwidth and is never what the user wants.

**Common hidden paths on Android:**
- `.thumbnails/` — camera thumbnail cache
- `.trashed/` — recently deleted files
- `.nomedia` — media scanner suppression marker
- Any `.`-prefixed system or temp file

**Fix:** Added `-not -path '*/.*'` to the `find` command in `list_remote_files()`. This excludes any file whose name or any ancestor directory starts with `.`, evaluated entirely on-device before any data crosses the USB connection.

---

## 9. Eliminated per-file shell loop for file listing (major speed fix)

**Problem:** The original `list_remote_files()` ran one `adb shell` per file to get its size using `wc -c`. For a DCIM folder with 5,000 files this meant 5,000 individual adb round-trips before any copying started.

**Root cause of `wc -c` slowness:** `wc -c` reads the entire file content to count bytes — for a 10MB photo this means 10MB of file I/O just to get a size. Multiplied across thousands of files this could take 10–30+ minutes.

**Fixes applied in order:**

### Step 1: Move listing to on-device shell (single adb call)
Replaced the Mac-side `while read | adb shell wc` loop with a single `adb shell` invocation that runs `find | while read | stat` entirely on the device. Reduced from N adb calls to 1.

### Step 2: `wc -c` → `stat -c '%s'`
`stat` reads only the inode (file metadata), not the file content. O(1) per file regardless of size. Falls back to `wc -c` if `stat` is unavailable on older devices.

### Step 3: Eliminate the shell loop entirely
Replaced the on-device `while read` loop with:
```bash
find "$dir" -type f -not -path '*/.*' -printf '%s\t%p\n' 2>/dev/null \
|| find "$dir" -type f -not -path '*/.*' -exec stat -c '%s\t%n' {} + 2>/dev/null
```
- `find -printf`: built into `find`, zero subprocesses, zero shell overhead — the fastest possible.
- `find -exec stat {} +`: batches multiple files per `stat` invocation (the `+` form), so roughly one subprocess per 100 files instead of per file.
- The `||` only triggers if `-printf` is unsupported (older Android/BusyBox).

**Speed comparison for 5,000 files:**

| Method | Subprocesses | Estimated time |
|---|---|---|
| `wc -c` per file via adb | 5,000 adb calls | 10–30 min |
| On-device loop + `stat` | 1 adb call, 5,000 forks | 2–5 min |
| `find -printf` | 1 adb call, 0 forks | 10–30 sec |

---

## 10. stdin isolation for `adb` inside read loops

**Problem:** Corrupted filenames during file listing — paths appeared truncated or garbled:
```
/system/bin/sh: can't open IM/Camera/PXL_20251020...jpg: No such file or directory
```

**Root cause:** `adb shell` reads from stdin by default. When called inside a `while read` loop that is itself reading from an adb stream, the inner `adb shell` consumed bytes from the outer stream, mangling filenames into random fragments.

**Fix:** `adb_for_device()` now always redirects stdin from `/dev/null`:
```bash
adb_for_device() {
  adb -s "${CURRENT_SERIAL}" "$@" < /dev/null
}
```
This is applied to all adb calls globally, preventing any adb invocation from accidentally consuming pipeline data.

---

## 11. Disk space safety

### Pre-copy disk check (three modes)

**Problem:** On a 200GB transfer, running out of disk mid-run causes partial files, wasted time, and churn.

**Fix:** Added `precheck_free_space()` with three modes:

- **Mode 0** (`PRECHECK_FREE_SPACE=0`): skip entirely.
- **Mode 1** (default): single `df` call at startup. Aborts if free space is below `FREE_SPACE_BUFFER_GB`. Fast, instant, no device scan needed.
- **Mode 2** (`PRECHECK_FREE_SPACE=2`): full per-file pending estimate — scans device files, subtracts already-done, compares against free space + buffer. Slow on large libraries; cap with `PRECHECK_MAX_SECONDS`.

### Runtime disk guard

Added `runtime_free_space_guard()` called before each file copy and on the progress heartbeat:
- Warns when free space drops below `RUNTIME_FREE_SPACE_WARN_GB` (default 15GB).
- Aborts when free space drops critically low: `RUNTIME_FREE_SPACE_STOP_GB` (default 2GB).

This catches disk pressure caused by other processes filling the Mac while the transfer is running.

---

## 12. Runtime operator feedback and state-aware hints

**Problem:** During a long transfer (potentially hours), the user had no visibility into what was happening or why things were slow/failing. Phone lock, USB mode changes, and authorization prompts happened silently.

**Fixes:**

### State-aware guidance
Added `print_state_guidance()` + `runtime_hint()` with per-state messages that only fire when something is actually wrong (healthy device = no noise):

| State | Message shown |
|---|---|
| `unauthorized` | Unlock phone and accept USB debugging prompt; restart adb if prompt doesn't appear |
| `offline` | Replug cable/port; avoid hubs; switch USB mode to File Transfer |
| `missing` | No device visible; check cable/debugging/trust prompt; run `adb devices` |
| `locked` | Unlock phone; optional keep-awake command for long runs |
| `ready` (healthy) | No hint printed |

Hints are throttled by `HEALTHCHECK_INTERVAL_SECONDS` (default 30s) to avoid log spam during repeated recovery attempts.

### Progress heartbeat
Added periodic `PROGRESS` log lines every `PROGRESS_EVERY_FILES` files (default 200):
```
[10:35:12] PROGRESS seen=400 copied=312 skipped=82 failed=6 copied_gb=3.21
```

### High-failure warning
After every 25 consecutive failures, prints a `HINT` with likely causes (phone lock, unstable cable, USB mode, low storage).

### Scan heartbeat
`process_dir()` now logs:
- Before scan: `"Scanning /sdcard/DCIM (building file list on device, may take a moment for large folders)..."`
- After scan: `"Scan complete: 4821 files found in /sdcard/DCIM"`

---

## 13. Phone auto-lock handling

**Problem:** Android auto-lock during a long transfer interrupts ADB access or makes file operations unreliable.

**Recommended mitigation (not automated — requires user action):**

Before a long run, in Developer Options:

- **Stay Awake**: keeps screen on while charging over USB, preventing auto-lock.
- **Default USB configuration → File Transfer**: persists USB mode across reconnects.
- **Disable adb authorization timeout**: prevents re-auth prompts from interrupting the run.

The script detects the lock state via `device_lock_state()` and prints a hint when locked is detected during a recovery attempt.

---

## 14. USB mode guidance

**Problem:** The three USB modes on Pixel phones have significantly different behaviours for ADB transfers and cause confusing failures.

**Correct setting:** `File Transfer / Android Auto`

| Mode | Storage access | Use? |
|---|---|---|
| File Transfer / Android Auto | Full filesystem via MTP + ADB daemon access | Yes |
| PTP | Camera roll only, blocks other folders | No — limits scan scope |
| MIDI | No storage access | No |

The script's `resolve_storage_root()` detects when storage is empty (Charging-only symptom) and prints:
```
HINT  On the phone: pull down notification bar -> tap USB notification -> select 'File Transfer'.
```

---

## 15. Run-level manifest and per-run stats

**Problem:** `manifest.tsv` was append-only across all runs — no way to see what was done in the current run vs. historically.

**Fix:** Added `manifest_run.tsv` — cleared and rebuilt each run, records only files successfully copied in that run. Summary now shows both:
```
Copied this run : 312 files (3.21 GB)
Copied total    : 4821 files (47.33 GB)
```

---

## 16. Skip logic and no quality loss guarantee

**What the script does (and does not do):**

- `adb pull -a` copies raw file bytes with timestamps preserved. No transcoding, no re-encoding, no format conversion. JPEG/HEIC/MP4/RAW files arrive byte-for-byte identical to the originals.
- Skip logic: a file is skipped if a local copy exists at the expected path **and** its size matches the remote size exactly. No size match = re-copy.
- Validation: after each copy, local size is compared to remote size. Mismatch triggers retry.
- Current limitation: size-only validation (not a cryptographic checksum). A same-size corruption would not be detected. This is an acceptable trade-off for speed on large libraries; `PRECHECK_FREE_SPACE=2` can be used for a full scan pass.

---

## 17. Remaining bugs fixed on review

### Stale `pixel_pull.sh` references inside script
Two `echo` lines in `resolve_target_devices()` and one `log` line in `resolve_remote_dirs()` still referenced `pixel_pull.sh` after the rename. Fixed to `pixel_backup.sh`.

### `retry_failed_once` subshell counter loss
`sort -u "${FAILED}" | while ...` runs the `while` loop in a subshell (bash pipeline semantics). Counter updates (`FILES_COPIED`, `FILES_FAILED`, `BYTES_COPIED`) inside `copy_one` during the retry phase were silently discarded.

**Fix:** Changed to process substitution so the loop runs in the current shell:
```bash
while IFS=$'\t' read -r rsize remote; do
  ...
done < <(sort -u "${FAILED}")
```

### Ctrl+C / SIGTERM — no cleanup, no summary, no guidance
Killing the script mid-transfer left temp listing files behind and printed nothing useful.

**Fix:** Added `on_interrupt()` handler hooked to `INT` and `TERM` signals:
- Logs a clear interruption message
- Cleans up temp listing files
- Prints a partial summary if a device session was active
- Reminds user to rerun to resume
- Exits with code 130 (standard Ctrl+C convention)

### Temp listing files left behind on kill
`listing_copy_*.tsv` and `listing_precheck_*.tsv` temp files were only cleaned inside `process_dir` on normal flow. An unexpected exit left them in `.transfer_meta/`.

**Fix:** Added `cleanup_temp_files()` called from:
- `on_interrupt()` (Ctrl+C / SIGTERM)
- End of `run_for_current_device()` (normal exit)

### SKIP log flood on large resume runs
For a backup folder where most files are already done, every skipped file produced a `SKIP /sdcard/DCIM/Camera/PXL_...jpg` log line. A 4,800-file resume produced 4,800 log lines before copying anything, making actual copy/fail events hard to find.

**Fix:** Skip lines are now batched. Consecutive skips are counted silently and flushed as a single line when a copy or directory boundary is reached:
```
[10:35:01] SKIP  4823 file(s) already present, skipped.
[10:35:01] COPY  /sdcard/DCIM/Camera/PXL_20260319_new.jpg (attempt 1/3)
```

---

## Summary of all tunable parameters

| Parameter | Default | Purpose |
|---|---|---|
| `DEST_ROOT_BASE` | `~/Pictures/pixel_backup` | Base destination |
| `DEVICE_SERIAL` | empty | Target specific device |
| `DEVICE_SELECTION` | `auto` | `auto` / `all` / `first` |
| `SEPARATE_DEVICE_DIRS` | `1` | Per-device subdirectories |
| `REMOTE_DIRS_CSV` | empty | Custom scan paths (colon-separated) |
| `MAX_PULL_ATTEMPTS` | `3` | Per-file retry limit |
| `MAX_ADB_RECOVERY_ATTEMPTS` | `3` | ADB recovery loop limit |
| `ADB_WAIT_SECONDS` | `20` | Device ready wait timeout |
| `SHOW_RUNTIME_HINTS` | `1` | Enable operator hint messages |
| `HEALTHCHECK_INTERVAL_SECONDS` | `30` | Min seconds between repeated hints |
| `PROGRESS_EVERY_FILES` | `200` | Progress log interval |
| `CHECK_FREE_SPACE_DURING_COPY` | `1` | Runtime disk guard |
| `RUNTIME_FREE_SPACE_WARN_GB` | `15` | Warn threshold |
| `RUNTIME_FREE_SPACE_STOP_GB` | `2` | Abort threshold |
| `PRECHECK_FREE_SPACE` | `1` | `0`=off, `1`=fast, `2`=full estimate |
| `FREE_SPACE_BUFFER_GB` | `10` | Minimum free space headroom |
| `PRECHECK_MAX_SECONDS` | `120` | Full-estimate timeout (mode 2) |
