#!/usr/bin/env bash
set -euo pipefail

# Resumable Pixel -> Mac photo/video backup over adb
# Usage:
#   chmod +x pixel_backup.sh
#   ./pixel_backup.sh
#
# Destination defaults to:
#   ~/Pictures/pixel_backup
#
# Requirements:
#   - adb installed and in PATH
#   - USB debugging enabled on phone
#   - phone unlocked
#
# Notes:
#   - Safe to rerun
#   - Skips files already copied with matching size
#   - Retries failed files once at the end
#   - Creates a manifest + log files locally

# Base destination; each device gets its own subdirectory by default
DEST_ROOT_BASE="${DEST_ROOT_BASE:-${HOME}/Pictures/pixel_backup}"

# Device targeting:
#   DEVICE_SERIAL=<serial>         # target one specific device
#   DEVICE_SELECTION=auto|all|first
DEVICE_SERIAL="${DEVICE_SERIAL:-}"
DEVICE_SELECTION="${DEVICE_SELECTION:-auto}"
SEPARATE_DEVICE_DIRS="${SEPARATE_DEVICE_DIRS:-1}"

# Optional override to scan custom directories (colon-separated)
# Example: REMOTE_DIRS_CSV="/sdcard/DCIM:/sdcard/Pictures"
REMOTE_DIRS_CSV="${REMOTE_DIRS_CSV:-}"

# Set per-device at runtime
CURRENT_SERIAL=""
CURRENT_DEVICE_NAME=""
DEST_ROOT=""
TMP_DIR=""
MANIFEST=""
FAILED=""
LOG=""
RUN_MANIFEST=""
BOOTSTRAP_LOG="${DEST_ROOT_BASE}/.transfer_meta/bootstrap.log"

# Reliability tuning knobs (override via env vars)
MAX_PULL_ATTEMPTS="${MAX_PULL_ATTEMPTS:-3}"
MAX_ADB_RECOVERY_ATTEMPTS="${MAX_ADB_RECOVERY_ATTEMPTS:-3}"
ADB_WAIT_SECONDS="${ADB_WAIT_SECONDS:-20}"
HEALTHCHECK_INTERVAL_SECONDS="${HEALTHCHECK_INTERVAL_SECONDS:-30}"

# Disk safety knobs
# PRECHECK_FREE_SPACE=1: fast free-space sanity check before copying (no full file scan).
# PRECHECK_FREE_SPACE=2: full per-file pending estimate (slow on large libraries, use with care).
PRECHECK_FREE_SPACE="${PRECHECK_FREE_SPACE:-1}"
# Minimum free GB required before starting (mode 1) or buffer on top of pending estimate (mode 2).
FREE_SPACE_BUFFER_GB="${FREE_SPACE_BUFFER_GB:-10}"
# Cap full-estimate precheck time (mode 2 only).
PRECHECK_MAX_SECONDS="${PRECHECK_MAX_SECONDS:-120}"

# Runtime operator feedback
SHOW_RUNTIME_HINTS="${SHOW_RUNTIME_HINTS:-1}"
LAST_HEALTH_HINT_TS=0

# Progress and runtime guardrails
PROGRESS_EVERY_FILES="${PROGRESS_EVERY_FILES:-200}"
CHECK_FREE_SPACE_DURING_COPY="${CHECK_FREE_SPACE_DURING_COPY:-1}"
RUNTIME_FREE_SPACE_WARN_GB="${RUNTIME_FREE_SPACE_WARN_GB:-15}"
RUNTIME_FREE_SPACE_STOP_GB="${RUNTIME_FREE_SPACE_STOP_GB:-2}"

# Per-device counters
FILES_SEEN=0
FILES_SKIPPED=0
FILES_COPIED=0
FILES_FAILED=0
BYTES_COPIED=0
SKIP_STREAK=0   # consecutive skips since last copy/fail — batched in log

# Main Android folders to copy, relative to the storage root.
# Storage root is auto-detected at runtime (/sdcard or /storage/emulated/0).
REMOTE_DIRS=(
  "DCIM"
  "Pictures"
  "Movies"
  "Download"
)

if [[ -n "${REMOTE_DIRS_CSV}" ]]; then
  IFS=':' read -r -a REMOTE_DIRS <<< "${REMOTE_DIRS_CSV}"
fi

# Resolved at runtime
DEVICE_STORAGE_ROOT=""

log() {
  local msg
  msg="$(printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  if [[ -n "${LOG}" ]]; then
    printf '%s\n' "${msg}" | tee -a "${LOG}"
    return 0
  fi
  if [[ -n "${BOOTSTRAP_LOG}" ]]; then
    mkdir -p "$(dirname "${BOOTSTRAP_LOG}")" 2>/dev/null || true
    printf '%s\n' "${msg}" | tee -a "${BOOTSTRAP_LOG}"
    return 0
  fi
  printf '%s\n' "${msg}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1"
    exit 1
  }
}

die() {
  log "FATAL $*"
  exit 1
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  log "ERROR Script aborted at line ${line_no} (exit=${exit_code})"
  if [[ -n "${LOG}" ]]; then
    echo "The transfer stopped unexpectedly. See log: ${LOG}"
  elif [[ -n "${BOOTSTRAP_LOG}" ]]; then
    echo "The transfer stopped unexpectedly. See bootstrap log: ${BOOTSTRAP_LOG}"
  else
    echo "The transfer stopped unexpectedly."
  fi
}

on_interrupt() {
  echo ""
  log "INTERRUPTED  Transfer cancelled by user (Ctrl+C)."
  cleanup_temp_files
  if [[ -n "${MANIFEST}" && -f "${MANIFEST}" ]]; then
    log "Partial progress saved — rerun to resume."
    summary 2>/dev/null || true
  fi
  exit 130
}

cleanup_temp_files() {
  rm -f "${TMP_DIR}"/listing_copy_"${CURRENT_SERIAL}"_*.tsv \
        "${TMP_DIR}"/listing_precheck_"${CURRENT_SERIAL}"_*.tsv 2>/dev/null || true
}

trap 'on_error "$?" "$LINENO"' ERR
trap 'on_interrupt' INT TERM

require_cmd adb
require_cmd awk
require_cmd sed
require_cmd stat
require_cmd mkdir
require_cmd dirname
require_cmd basename
require_cmd cut
require_cmd sort
require_cmd wc
require_cmd tr
require_cmd sleep
require_cmd date
require_cmd df

adb_for_device() {
  # Prevent adb commands from consuming caller stdin (important inside read loops).
  adb -s "${CURRENT_SERIAL}" "$@" < /dev/null
}

adb_device_transport_state() {
  adb devices | awk -v s="${CURRENT_SERIAL}" '$1==s {print $2}'
}

device_lock_state() {
  # Best-effort lock detection. Not all Android builds expose the same commands.
  local out

  out="$(adb_for_device shell "cmd window is-keyguard-locked 2>/dev/null" 2>/dev/null | tr -d '\r[:space:]' || true)"
  case "${out}" in
    true|1) echo "locked"; return 0 ;;
    false|0) echo "unlocked"; return 0 ;;
  esac

  out="$(adb_for_device shell "dumpsys window 2>/dev/null | grep -E 'isStatusBarKeyguard|mShowingLockscreen' | head -n 1" 2>/dev/null | tr -d '\r' || true)"
  if [[ "${out}" == *"=true"* ]]; then
    echo "locked"
    return 0
  elif [[ "${out}" == *"=false"* ]]; then
    echo "unlocked"
    return 0
  fi

  echo "unknown"
}

runtime_hint() {
  local reason="$1"
  local now tstate lstate

  [[ "${SHOW_RUNTIME_HINTS}" == "1" ]] || return 0
  now="$(date +%s)"
  if (( now - LAST_HEALTH_HINT_TS < HEALTHCHECK_INTERVAL_SECONDS )); then
    return 0
  fi
  LAST_HEALTH_HINT_TS="$now"

  tstate="$(adb_device_transport_state)"
  lstate="$(device_lock_state)"

  case "${reason}" in
    connectivity)
      log "HINT  Device health serial=${CURRENT_SERIAL} transport=${tstate:-missing} lock=${lstate}"
      if [[ "${tstate:-}" == "unauthorized" ]]; then
        log "HINT  State=unauthorized -> unlock phone and accept 'Allow USB debugging'."
        log "HINT  If prompt does not appear: disconnect/reconnect USB cable and run: adb kill-server && adb start-server"
      elif [[ "${tstate:-}" == "offline" ]]; then
        log "HINT  State=offline -> USB link unstable. Replug cable/port, avoid hubs, and keep phone unlocked."
        log "HINT  Switch USB mode on phone to File Transfer (not Charging-only)."
      elif [[ "${tstate:-}" == "missing" || -z "${tstate:-}" ]]; then
        log "HINT  State=missing -> no device seen by adb. Check cable, port, USB debugging, and device trust prompt."
        log "HINT  Run 'adb devices' to verify serial visibility."
      elif [[ "${lstate}" == "locked" ]]; then
        log "HINT  State=locked -> unlock phone now; long transfers are unreliable while locked."
        log "HINT  Optional for long runs: adb -s ${CURRENT_SERIAL} shell svc power stayon usb"
      else
        log "HINT  State=ready -> device looks healthy. If progress stalls, keep phone awake and use direct USB."
      fi
      ;;
    low_disk)
      log "HINT  Low free disk space detected at destination. Free space may be insufficient for remaining files."
      log "HINT  Free space on Mac or stop other large writes, then rerun."
      ;;
    high_failures)
      log "HINT  Failure count is rising. Possible causes: phone lock, unstable cable/hub, storage full, or flaky USB mode."
      log "HINT  Keep phone unlocked, reconnect cable directly, and verify free space."
      ;;
  esac
}

print_state_guidance() {
  local tstate lstate
  tstate="$(adb_device_transport_state)"
  lstate="$(device_lock_state)"
  # Only log full state + hint when something is actually wrong
  if [[ "${tstate:-}" != "device" || "${lstate}" == "locked" ]]; then
    log "STATE serial=${CURRENT_SERIAL} transport=${tstate:-missing} lock=${lstate}"
    runtime_hint "connectivity"
  fi
}

sanitize_name() {
  local raw="$1"
  local result
  # Normalise a raw string for safe use in file/directory names:
  #  1. Remove all bytes outside printable ASCII (0x20-0x7E):
  #     - \000-\037 : control chars (includes CR, LF, tab)
  #     - \177-\377 : DEL and every high byte (covers all multi-byte UTF-8
  #                   sequences, so emoji, accented chars, CJK, etc. are
  #                   stripped rather than left as garbage byte sequences)
  #  2. Force LC_ALL=C so [A-Za-z0-9] strictly means ASCII in sed.
  #  3. Replace every run of non-[A-Za-z0-9._-] chars with a single underscore.
  #  4. Collapse consecutive underscores; strip leading/trailing underscores.
  #  5. Cap at 64 characters to keep paths sane.
  #  6. Fall back to "unknown_device" if nothing printable remains.
  result="$(printf '%s' "$raw" \
    | tr -d '\000-\037\177-\377' \
    | LC_ALL=C sed -E 's/[^A-Za-z0-9._-]+/_/g; s/_+/_/g; s/^_+//; s/_+$//' \
    | cut -c1-64)"
  printf '%s' "${result:-unknown_device}"
}

list_online_devices() {
  adb devices | awk 'NR>1 && $2=="device" {print $1}'
}

resolve_target_devices() {
  local -a online
  local count
  while IFS= read -r serial; do
    [[ -z "${serial:-}" ]] && continue
    online+=("${serial}")
  done < <(list_online_devices)
  count="${#online[@]}"

  if [[ -n "${DEVICE_SERIAL}" ]]; then
    TARGET_DEVICE_SERIALS=("${DEVICE_SERIAL}")
    return 0
  fi

  case "${DEVICE_SELECTION}" in
    all)
      if (( count == 0 )); then
        die "No online adb devices found."
      fi
      TARGET_DEVICE_SERIALS=("${online[@]}")
      ;;
    first)
      if (( count == 0 )); then
        die "No online adb devices found."
      fi
      TARGET_DEVICE_SERIALS=("${online[0]}")
      ;;
    auto)
      if (( count == 0 )); then
        die "No online adb devices found."
      elif (( count > 1 )); then
        echo "Multiple devices detected:"
        printf '  - %s\n' "${online[@]}"
        echo
        echo "Set one of:"
        echo "  DEVICE_SERIAL=<serial> ./pixel_backup.sh"
        echo "  DEVICE_SELECTION=all ./pixel_backup.sh"
        die "Ambiguous target device."
      else
        TARGET_DEVICE_SERIALS=("${online[0]}")
      fi
      ;;
    *)
      die "Invalid DEVICE_SELECTION='${DEVICE_SELECTION}'. Use auto|all|first."
      ;;
  esac
}

adb_state() {
  adb_for_device get-state 2>/dev/null || true
}

wait_for_device() {
  local deadline now state
  deadline=$(( $(date +%s) + ADB_WAIT_SECONDS ))
  while true; do
    state="$(adb_state)"
    if [[ "$state" == "device" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now >= deadline )); then
      return 1
    fi
    sleep 1
  done
}

recover_adb() {
  local attempt state
  for (( attempt=1; attempt<=MAX_ADB_RECOVERY_ATTEMPTS; attempt++ )); do
    log "ADB recovery attempt ${attempt}/${MAX_ADB_RECOVERY_ATTEMPTS}"
    adb start-server >/dev/null 2>&1 || true
    adb reconnect >/dev/null 2>&1 || true
    adb_for_device wait-for-device >/dev/null 2>&1 || true
    if wait_for_device; then
      log "ADB connection healthy."
      return 0
    fi
    state="$(adb_state)"
    log "ADB not ready (state=${state:-unknown})."
    runtime_hint "connectivity"
    sleep "$attempt"
  done
  return 1
}

ensure_device_ready() {
  local state
  log "Checking adb connection for serial=${CURRENT_SERIAL}..."
  state="$(adb_state)"
  if [[ "$state" == "device" ]]; then
    log "ADB connection healthy."
    return 0
  fi
  # Device not immediately ready — print guidance and attempt recovery
  print_state_guidance
  if ! recover_adb; then
    echo "adb does not see a ready device."
    echo "Check:"
    echo "  1. Pixel connected by USB"
    echo "  2. USB debugging enabled"
    echo "  3. Phone unlocked"
    echo "  4. 'Allow USB debugging' accepted on the phone"
    die "Unable to establish a stable adb connection."
  fi
}

resolve_storage_root() {
  local candidate out
  local -a candidates=("/sdcard" "/storage/emulated/0" "/storage/self/primary")

  for candidate in "${candidates[@]}"; do
    out="$(adb_for_device shell "[ -d \"$candidate\" ] && echo yes || echo no" 2>/dev/null \
          | tr -d '\r[:space:]' || true)"
    if [[ "$out" == "yes" ]]; then
      # Verify it actually contains something (catches mounted-but-empty USB-Charging mode)
      local count
      count="$(adb_for_device shell "ls \"$candidate\" 2>/dev/null | wc -l" \
               | tr -d '\r[:space:]' || true)"
      if [[ "${count:-0}" -gt 0 ]]; then
        DEVICE_STORAGE_ROOT="$candidate"
        log "Storage root resolved: ${DEVICE_STORAGE_ROOT}"
        return 0
      else
        log "WARN  Path $candidate exists but appears empty (USB mode may be Charging-only)."
      fi
    fi
  done

  log "WARN  Could not resolve a readable storage root on device."
  log "HINT  On the phone: pull down notification bar -> tap USB notification -> select 'File Transfer'."
  log "HINT  Checked paths: ${candidates[*]}"
  DEVICE_STORAGE_ROOT="/sdcard"
  return 1
}

resolve_remote_dirs() {
  local raw_dirs=("${REMOTE_DIRS[@]}")
  local resolved=()
  local d full any_found=0

  log "Verifying remote directories on device (storage root=${DEVICE_STORAGE_ROOT})..."
  for d in "${raw_dirs[@]}"; do
    # Accept already-absolute paths (user-provided via REMOTE_DIRS_CSV)
    if [[ "$d" == /* ]]; then
      full="$d"
    else
      full="${DEVICE_STORAGE_ROOT}/${d}"
    fi

    local out
    out="$(adb_for_device shell "[ -d \"$full\" ] && echo yes || echo no" 2>/dev/null \
           | tr -d '\r[:space:]' || true)"
    if [[ "$out" == "yes" ]]; then
      log "OK    Remote dir found: $full"
      resolved+=("$full")
      any_found=1
    else
      log "SKIP  Remote dir not found, skipping: $full"
    fi
  done

  if (( any_found == 0 )); then
    log "WARN  None of the configured remote directories exist on the device."
    log "HINT  Is USB mode set to File Transfer? On the phone: notification bar -> USB -> File Transfer."
    log "HINT  To scan custom paths use: REMOTE_DIRS_CSV='/sdcard/MyFolder:/sdcard/Other' ./pixel_backup.sh"
    die "No scannable directories found on device. Aborting."
  fi

  REMOTE_DIRS=("${resolved[@]}")
  log "Directories to scan: ${REMOTE_DIRS[*]}"
}

get_device_name() {
  local model serial_short safe
  model="$(adb_for_device shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)"
  serial_short="$(echo "${CURRENT_SERIAL}" | cut -c1-8)"
  if [[ -z "${model}" ]]; then
    model="android_${serial_short}"
  fi
  safe="$(sanitize_name "${model}")"
  if [[ -z "${safe}" ]]; then
    safe="android_${serial_short}"
  fi
  echo "${safe}"
}

setup_device_paths() {
  local run_date safe_serial
  run_date="$(date '+%Y-%m-%d')"
  # Sanitize the serial too — TCP/IP adb serials contain colons
  # (e.g. "192.168.1.5:5555") which are illegal in macOS paths.
  safe_serial="$(sanitize_name "${CURRENT_SERIAL}")"
  if [[ "${SEPARATE_DEVICE_DIRS}" == "1" ]]; then
    DEST_ROOT="${DEST_ROOT_BASE}/${run_date}_${CURRENT_DEVICE_NAME}_${safe_serial}"
  else
    DEST_ROOT="${DEST_ROOT_BASE}"
  fi
  TMP_DIR="${DEST_ROOT}/.transfer_meta"
  MANIFEST="${TMP_DIR}/manifest.tsv"
  FAILED="${TMP_DIR}/failed.tsv"
  LOG="${TMP_DIR}/transfer.log"
  RUN_MANIFEST="${TMP_DIR}/manifest_run.tsv"

  mkdir -p "${DEST_ROOT}" "${TMP_DIR}"
  touch "${MANIFEST}" "${RUN_MANIFEST}" "${FAILED}" "${LOG}"
}

bytes_to_gb() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1024/1024/1024}'
}

free_bytes_dest() {
  # Use POSIX output (-P) and 1K blocks, then convert to bytes.
  df -kP "${DEST_ROOT}" | awk 'NR==2 {print $4 * 1024}'
}

runtime_free_space_guard() {
  local free_bytes warn_bytes stop_bytes free_gb
  [[ "${CHECK_FREE_SPACE_DURING_COPY}" == "1" ]] || return 0

  free_bytes="$(free_bytes_dest)"
  warn_bytes=$((RUNTIME_FREE_SPACE_WARN_GB * 1024 * 1024 * 1024))
  stop_bytes=$((RUNTIME_FREE_SPACE_STOP_GB * 1024 * 1024 * 1024))
  free_gb="$(bytes_to_gb "$free_bytes")"

  if (( free_bytes <= stop_bytes )); then
    runtime_hint "low_disk"
    die "Destination free space critically low (${free_gb} GB). Aborting to avoid partial-run churn."
  fi
  if (( free_bytes <= warn_bytes )); then
    log "WARN  Low destination free space: ${free_gb} GB remaining."
    runtime_hint "low_disk"
  fi
}

report_progress_if_needed() {
  local copied_gb
  if (( FILES_SEEN > 0 && FILES_SEEN % PROGRESS_EVERY_FILES == 0 )); then
    copied_gb="$(bytes_to_gb "${BYTES_COPIED}")"
    log "PROGRESS seen=${FILES_SEEN} copied=${FILES_COPIED} skipped=${FILES_SKIPPED} failed=${FILES_FAILED} copied_gb=${copied_gb}"
    runtime_free_space_guard
  fi
}

estimate_pending_bytes_for_dir() {
  local dir="$1"
  local sum=0
  local rsize remote
  local listing_file

  listing_file="${TMP_DIR}/listing_precheck_${CURRENT_SERIAL}_$$.tsv"
  if ! list_remote_files "$dir" > "${listing_file}"; then
    rm -f "${listing_file}" 2>/dev/null || true
    return 1
  fi

  while IFS=$'\t' read -r rsize remote; do
    [[ -z "${rsize:-}" || -z "${remote:-}" ]] && continue
    if ! already_done "$remote" "$rsize"; then
      sum=$((sum + rsize))
    fi
  done < "${listing_file}"

  rm -f "${listing_file}" 2>/dev/null || true
  echo "$sum"
}

precheck_free_space() {
  local free_bytes buffer_bytes free_gb buffer_gb

  case "${PRECHECK_FREE_SPACE}" in
    0)
      log "Disk precheck disabled."
      return 0
      ;;
    1)
      # Fast mode: just verify minimum headroom exists before starting.
      free_bytes="$(free_bytes_dest)"
      buffer_bytes=$((FREE_SPACE_BUFFER_GB * 1024 * 1024 * 1024))
      free_gb="$(bytes_to_gb "$free_bytes")"
      buffer_gb="$(bytes_to_gb "$buffer_bytes")"
      log "Disk precheck (fast) free=${free_gb}GB required_min=${buffer_gb}GB"
      if (( free_bytes < buffer_bytes )); then
        echo "Insufficient free space at destination: ${DEST_ROOT}"
        echo "Available        : ${free_gb} GB"
        echo "Minimum required : ${buffer_gb} GB (FREE_SPACE_BUFFER_GB)"
        echo
        echo "Free up space or set FREE_SPACE_BUFFER_GB lower, then retry."
        die "Aborting: not enough free space at destination."
      fi
      ;;
    2)
      # Full estimate mode: scan all files on device to compute pending bytes.
      # Slow on large libraries — use PRECHECK_MAX_SECONDS to cap scan time.
      local pending_bytes=0 dir dir_pending
      local pending_gb required_bytes required_gb
      local precheck_started precheck_now

      precheck_started="$(date +%s)"
      log "Disk precheck (full estimate) scanning remote files..."
      for dir in "${REMOTE_DIRS[@]}"; do
        precheck_now="$(date +%s)"
        if (( PRECHECK_MAX_SECONDS > 0 && precheck_now - precheck_started >= PRECHECK_MAX_SECONDS )); then
          log "WARN  Precheck exceeded ${PRECHECK_MAX_SECONDS}s; skipping remaining estimation."
          log "HINT  Continuing with runtime free-space guardrails. Raise PRECHECK_MAX_SECONDS for full estimate."
          return 0
        fi
        if ! remote_dir_exists "$dir"; then
          log "WARN  Remote directory missing during precheck, skipping: $dir"
          continue
        fi
        if ! dir_pending="$(estimate_pending_bytes_for_dir "$dir")"; then
          runtime_hint "connectivity"
          die "Device disconnected during precheck while scanning ${dir}."
        fi
        pending_bytes=$((pending_bytes + dir_pending))
      done

      free_bytes="$(free_bytes_dest)"
      buffer_bytes=$((FREE_SPACE_BUFFER_GB * 1024 * 1024 * 1024))
      required_bytes=$((pending_bytes + buffer_bytes))
      pending_gb="$(bytes_to_gb "$pending_bytes")"
      free_gb="$(bytes_to_gb "$free_bytes")"
      buffer_gb="$(bytes_to_gb "$buffer_bytes")"
      required_gb="$(bytes_to_gb "$required_bytes")"

      log "Disk precheck (full) pending=${pending_gb}GB free=${free_gb}GB buffer=${buffer_gb}GB required=${required_gb}GB"
      if (( free_bytes < required_bytes )); then
        echo "Insufficient disk space at destination: ${DEST_ROOT}"
        echo "Pending estimate : ${pending_gb} GB"
        echo "Safety buffer    : ${buffer_gb} GB"
        echo "Required total   : ${required_gb} GB"
        echo "Available        : ${free_gb} GB"
        echo
        echo "Free up space or reduce scope (REMOTE_DIRS_CSV), then retry."
        die "Aborting before copy due to insufficient destination disk space."
      fi
      ;;
    *)
      log "WARN  Unknown PRECHECK_FREE_SPACE value '${PRECHECK_FREE_SPACE}'. Use 0, 1 (default), or 2."
      ;;
  esac
}

remote_dir_exists() {
  local remote_dir="$1"
  local out
  out="$(adb_for_device shell "[ -d \"$remote_dir\" ] && echo yes || echo no" 2>/dev/null | tr -d '\r[:space:]' || true)"
  [[ "$out" == "yes" ]]
}

# List remote files with sizes.
# Output format:  SIZE<TAB>/path/to/file
#
# Hidden files and hidden directories (name starts with '.') are excluded.
# This skips .thumbnails, .trashed, .nomedia, and any other system/temp paths.
#
# Speed strategy (no per-file shell loop):
#   1. find -printf: zero subprocesses, entirely within find (fastest)
#   2. find -exec stat {} +: batched stat calls (one call per group, not per file)
# The || fallback activates only if -printf is unsupported on the device.
list_remote_files() {
  local remote_dir="$1"
  adb_for_device shell "
    find \"$remote_dir\" -type f -not -path '*/.*' -printf '%s\t%p\n' 2>/dev/null \
    || find \"$remote_dir\" -type f -not -path '*/.*' -exec stat -c '%s\t%n' {} + 2>/dev/null
  " 2>/dev/null | tr -d '\r'
}

# Convert /sdcard/... -> DEST_ROOT/sdcard/...
local_path_for_remote() {
  local remote="$1"
  printf '%s/%s\n' "${DEST_ROOT}" "${remote#/}"
}

# macOS stat size
local_size() {
  local file="$1"
  stat -f%z "$file" 2>/dev/null || echo ""
}

already_done() {
  local remote="$1"
  local rsize="$2"
  local local_path
  local lsize

  local_path="$(local_path_for_remote "$remote")"
  if [[ -f "$local_path" ]]; then
    lsize="$(local_size "$local_path")"
    if [[ "$lsize" == "$rsize" ]]; then
      return 0
    fi
  fi
  return 1
}

record_manifest() {
  local remote="$1"
  local rsize="$2"
  local local_path="$3"
  printf '%s\t%s\t%s\n' "$rsize" "$remote" "$local_path" >> "${MANIFEST}"
}

copy_one() {
  local remote="$1"
  local rsize="$2"
  local local_path
  local local_dir
  local copied_size
  local attempt

  local_path="$(local_path_for_remote "$remote")"
  local_dir="$(dirname "$local_path")"
  mkdir -p "$local_dir"

  if already_done "$remote" "$rsize"; then
    FILES_SKIPPED=$((FILES_SKIPPED + 1))
    SKIP_STREAK=$((SKIP_STREAK + 1))
    return 0
  fi

  # Flush any accumulated skip streak before copying
  if (( SKIP_STREAK > 0 )); then
    log "SKIP  ${SKIP_STREAK} file(s) already present, skipped."
    SKIP_STREAK=0
  fi

  for (( attempt=1; attempt<=MAX_PULL_ATTEMPTS; attempt++ )); do
    runtime_free_space_guard
    log "COPY  $remote (attempt ${attempt}/${MAX_PULL_ATTEMPTS})"
    if adb_for_device pull -a "$remote" "$local_path" >> "${LOG}" 2>&1; then
      copied_size="$(local_size "$local_path")"
      if [[ "$copied_size" == "$rsize" ]]; then
        record_manifest "$remote" "$rsize" "$local_path"
        printf '%s\t%s\t%s\n' "$rsize" "$remote" "$local_path" >> "${RUN_MANIFEST}"
        log "OK    $remote"
        FILES_COPIED=$((FILES_COPIED + 1))
        BYTES_COPIED=$((BYTES_COPIED + rsize))
        return 0
      fi
      log "BADSIZE $remote expected=$rsize got=${copied_size:-missing}"
    else
      log "FAIL  $remote (attempt ${attempt})"
    fi

    # Self-heal: clean up partial copy, recover adb, then retry with backoff.
    rm -f "$local_path" 2>/dev/null || true
    recover_adb || true
    sleep "$attempt"
  done

  printf '%s\t%s\n' "$rsize" "$remote" >> "${FAILED}"
  FILES_FAILED=$((FILES_FAILED + 1))
  if (( FILES_FAILED > 0 && FILES_FAILED % 25 == 0 )); then
    runtime_hint "high_failures"
  fi
  return 1
}

process_dir() {
  local dir="$1"
  local listing_file file_count
  if ! remote_dir_exists "$dir"; then
    log "WARN  Remote directory missing, skipping: $dir"
    return 0
  fi
  log "Scanning $dir (building file list on device, may take a moment for large folders)..."
  listing_file="${TMP_DIR}/listing_copy_${CURRENT_SERIAL}_$$.tsv"
  if ! list_remote_files "$dir" > "${listing_file}"; then
    runtime_hint "connectivity"
    rm -f "${listing_file}" 2>/dev/null || true
    die "Failed to scan remote directory ${dir}; device may be disconnected."
  fi

  file_count="$(wc -l < "${listing_file}" | tr -d ' ')"
  log "Scan complete: ${file_count} files found in ${dir}"

  while IFS=$'\t' read -r rsize remote; do
    [[ -z "${rsize:-}" || -z "${remote:-}" ]] && continue
    FILES_SEEN=$((FILES_SEEN + 1))
    copy_one "$remote" "$rsize" || true
    report_progress_if_needed
  done < "${listing_file}"

  rm -f "${listing_file}" 2>/dev/null || true

  # Flush any trailing skip streak at end of directory
  if (( SKIP_STREAK > 0 )); then
    log "SKIP  ${SKIP_STREAK} file(s) already present, skipped."
    SKIP_STREAK=0
  fi
}

retry_failed_once() {
  local tmp_retry
  tmp_retry="${TMP_DIR}/failed_retry.tsv"
  : > "$tmp_retry"

  if [[ ! -s "${FAILED}" ]]; then
    return 0
  fi

  log "Retrying failed files once..."
  while IFS=$'\t' read -r rsize remote; do
    if ! copy_one "$remote" "$rsize"; then
      printf '%s\t%s\n' "$rsize" "$remote" >> "$tmp_retry"
    fi
  done < <(sort -u "${FAILED}")

  mv "$tmp_retry" "${FAILED}"
}

summary() {
  local total_files copied_files failed_files total_size_gb
  local run_copied run_size_gb

  copied_files="$(wc -l < "${MANIFEST}" | tr -d ' ')"
  failed_files="$(wc -l < "${FAILED}" | tr -d ' ')"
  run_copied="$(wc -l < "${RUN_MANIFEST}" | tr -d ' ')"

  total_size_gb="$(
    awk -F '\t' '{sum += $1} END {printf "%.2f", sum/1024/1024/1024}' "${MANIFEST}" 2>/dev/null
  )"
  run_size_gb="$(
    awk -F '\t' '{sum += $1} END {printf "%.2f", sum/1024/1024/1024}' "${RUN_MANIFEST}" 2>/dev/null
  )"

  echo
  echo "Done for device ${CURRENT_SERIAL} (${CURRENT_DEVICE_NAME})."
  echo "Copied this run : ${run_copied} files (${run_size_gb} GB)"
  echo "Copied total    : ${copied_files} files (${total_size_gb} GB)"
  echo "Failed files : ${failed_files}"
  echo "Manifest     : ${MANIFEST}"
  echo "Run manifest : ${RUN_MANIFEST}"
  echo "Failures     : ${FAILED}"
  echo "Log          : ${LOG}"
}

run_for_current_device() {
  ensure_device_ready
  CURRENT_DEVICE_NAME="$(get_device_name)"
  setup_device_paths

  resolve_storage_root || true   # soft-fail; guidance already logged
  resolve_remote_dirs            # hard-fail if nothing found

  log "Starting transfer..."
  log "Device serial=${CURRENT_SERIAL} name=${CURRENT_DEVICE_NAME}"
  log "Destination root=${DEST_ROOT}"
  log "Runtime hints enabled=${SHOW_RUNTIME_HINTS} interval=${HEALTHCHECK_INTERVAL_SECONDS}s"
  log "Progress settings every_files=${PROGRESS_EVERY_FILES} runtime_disk_check=${CHECK_FREE_SPACE_DURING_COPY}"
  : > "${FAILED}"
  : > "${RUN_MANIFEST}"
  FILES_SEEN=0
  FILES_SKIPPED=0
  FILES_COPIED=0
  FILES_FAILED=0
  BYTES_COPIED=0
  SKIP_STREAK=0
  precheck_free_space

  if [[ "${SEPARATE_DEVICE_DIRS}" != "1" && "${#TARGET_DEVICE_SERIALS[@]}" -gt 1 ]]; then
    log "WARN  Multiple devices with SEPARATE_DEVICE_DIRS=0 may mix paths in one destination."
    log "WARN  Recommended: leave SEPARATE_DEVICE_DIRS=1 to avoid collisions."
  fi

  for dir in "${REMOTE_DIRS[@]}"; do
    process_dir "$dir"
  done

  retry_failed_once
  cleanup_temp_files
  summary
}

declare -a TARGET_DEVICE_SERIALS=()
resolve_target_devices

for serial in "${TARGET_DEVICE_SERIALS[@]}"; do
  CURRENT_SERIAL="${serial}"
  run_for_current_device
done