#!/usr/bin/env bash
# Cross-backup reduce: hardlink / APFS-clone identical files between two dated
# backup folders (same device). Default pair is target + previous complete.
#
# Locked design:
#   - Does NOT touch pixel_backup.sh pull/copy — separate post-backup step
#   - Default: previous complete same-device backup when only one folder is given
#   - Optional explicit pair via --canonical / --older (UI or CLI)
#   - Canonical keeps physical bytes; the reduce/older side gets links for matches
#   - Each dated folder stays a full browsable tree
#   - In-place replace; never delete the last real (canonical) copy
#   - SHA-256 required on apply; dry-run estimates candidates
#   - Skip .transfer_meta; refuse incomplete backups by default
#   - Idempotent via .transfer_meta/dedupe_state
#
# Usage:
#   ./dedupe_backups.sh --dry-run /path/to/YYYY-MM-DD_Device_Serial
#   ./dedupe_backups.sh --apply  /path/to/YYYY-MM-DD_Device_Serial
#   ./dedupe_backups.sh --dry-run --canonical /path/newer --older /path/older
#   ./dedupe_backups.sh --dry-run --base ~/Pictures/pixel_backup --folder 2026-03-19_Pixel_…
#
set -euo pipefail

MODE="dry-run"
FORCE_INCOMPLETE=0
ALLOW_RERUN=0
BASE_OVERRIDE=""
FOLDER_NAME=""
TARGET_ARG=""
CANONICAL_OVERRIDE=""
OLDER_OVERRIDE=""

usage() {
  cat <<'EOF'
dedupe_backups.sh — Reduce cross-backup duplicates between same-device backups

USAGE
  ./dedupe_backups.sh [--dry-run|--apply] <backup_folder>
  ./dedupe_backups.sh [--dry-run|--apply] --canonical <DIR> --older <DIR>
  ./dedupe_backups.sh [--dry-run|--apply] --base <DEST_ROOT_BASE> --folder <YYYY-MM-DD_…>

  Default mode is --dry-run (estimate only; no changes).

WHAT IT DOES
  With one folder: finds the previous complete dated backup with the same device
  suffix. That target is the canonical baseline (keeps physical bytes). Matching
  files in the older folder (same relative path + size + SHA-256) are replaced
  in place with an APFS clone of the canonical file when possible, otherwise a
  hardlink. Both trees stay fully browsable.

  With --canonical and --older: uses that explicit pair (roles as given — does
  not reorder by date). Same device suffix and same volume still required.

  Skips .transfer_meta. Refuses incomplete backups unless --force-incomplete.
  Writes state under the older/reduce folder's .transfer_meta/.

OPTIONS
  --dry-run              Estimate candidates and reclaimable bytes (default)
  --apply                Perform in-place clone/hardlink replace (hashes always)
  --canonical DIR        Baseline folder that keeps real bytes
  --older DIR            Folder to reduce (matching files become links)
  --base DIR             Destination root containing dated backup folders
  --folder NAME          Dated folder name under --base (implies canonical)
  --force-incomplete     Allow reduce when run_status is not "complete"
  --force                Re-run even if dedupe_state says already reduced
  -h, --help             Show this help

EXIT CODES
  0  success (including "already reduced" / nothing to do)
  1  usage / validation error
  2  no previous complete backup found
  3  incomplete backup refused
  4  not same volume / link method unavailable
EOF
}

log() { printf '%s\n' "$*"; }
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

die() {
  log "ERROR $*"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --force-incomplete) FORCE_INCOMPLETE=1; shift ;;
    --force) ALLOW_RERUN=1; shift ;;
    --base) BASE_OVERRIDE="${2:-}"; shift 2 ;;
    --folder) FOLDER_NAME="${2:-}"; shift 2 ;;
    --canonical) CANONICAL_OVERRIDE="${2:-}"; shift 2 ;;
    --older|--reduce) OLDER_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *)
      if [[ -n "${TARGET_ARG}" ]]; then
        die "Unexpected extra argument: $1"
      fi
      TARGET_ARG="$1"
      shift
      ;;
  esac
done

abs_dir() {
  local p="$1"
  [[ -d "${p}" ]] || die "Not a directory: ${p}"
  (cd "${p}" && pwd -P)
}

# ─── Resolve target / pair ────────────────────────────────────────────────────

resolve_target() {
  if [[ -n "${FOLDER_NAME}" ]]; then
    [[ -n "${BASE_OVERRIDE}" ]] || die "--folder requires --base"
    TARGET="${BASE_OVERRIDE%/}/${FOLDER_NAME}"
  elif [[ -n "${TARGET_ARG}" ]]; then
    TARGET="${TARGET_ARG}"
  elif [[ -n "${CANONICAL_OVERRIDE}" ]]; then
    TARGET="${CANONICAL_OVERRIDE}"
  else
    die "Missing backup folder. See --help."
  fi
  TARGET="$(abs_dir "${TARGET}")"
  DEST_ROOT_BASE="$(dirname "${TARGET}")"
  TARGET_NAME="$(basename "${TARGET}")"
}

resolve_pair() {
  if [[ -n "${CANONICAL_OVERRIDE}" ]]; then
    CANONICAL="$(abs_dir "${CANONICAL_OVERRIDE}")"
  else
    CANONICAL="${TARGET}"
  fi
  CANONICAL_NAME="$(basename "${CANONICAL}")"
  DEST_ROOT_BASE="$(dirname "${CANONICAL}")"
  SUFFIX="$(device_suffix "${CANONICAL_NAME}")"

  if [[ -n "${OLDER_OVERRIDE}" ]]; then
    OLDER="$(abs_dir "${OLDER_OVERRIDE}")"
    OLDER_NAME="$(basename "${OLDER}")"
    local older_suffix
    older_suffix="$(device_suffix "${OLDER_NAME}")"
    [[ "${older_suffix}" == "${SUFFIX}" ]] \
      || die "Folders are not the same device (suffix '${older_suffix}' vs '${SUFFIX}')"
    [[ "${OLDER}" != "${CANONICAL}" ]] \
      || die "Canonical and older/reduce folders must be different"
  else
    PREVIOUS_NAME=""
    PREVIOUS=""
    if ! find_previous "${CANONICAL_NAME}" "${SUFFIX}" "${DEST_ROOT_BASE}"; then
      log "ERROR No previous same-device backup found under ${DEST_ROOT_BASE}"
      exit 2
    fi
    OLDER="${PREVIOUS}"
    OLDER_NAME="${PREVIOUS_NAME}"
  fi
}

# Device suffix after YYYY-MM-DD_ — same for all backups of that device/model/serial.
device_suffix() {
  local name="$1"
  if [[ ! "${name}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_.+ ]]; then
    die "Folder name is not a dated backup: ${name}"
  fi
  printf '%s\n' "${name:11}"
}

is_complete() {
  local folder="$1"
  local status_file="${folder}/.transfer_meta/run_status"
  if [[ -f "${status_file}" ]]; then
    local status
    status="$(tr -d '[:space:]' < "${status_file}" || true)"
    [[ "${status}" == "complete" ]] && return 0
    return 1
  fi
  # Legacy: no run_status — treat as complete only if a non-empty manifest exists
  # and there is no obvious incomplete marker in the log tail (matches app heuristics loosely).
  local manifest="${folder}/.transfer_meta/manifest.tsv"
  [[ -s "${manifest}" ]] || return 1
  local logf="${folder}/.transfer_meta/transfer.log"
  if [[ -f "${logf}" ]]; then
    if tail -n 120 "${logf}" | grep -Eiq 'PAUSED|INTERRUPTED|FATAL |ERROR Script aborted|critically low|not enough free space|Aborting'; then
      return 1
    fi
  fi
  return 0
}

# List same-suffix dated folders, newest first (name sort works for YYYY-MM-DD_…).
list_same_device_folders() {
  local suffix="$1"
  local base="$2"
  local name
  # shellcheck disable=SC2012
  ls -1 "${base}" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_' | while IFS= read -r name; do
    [[ "${name:11}" == "${suffix}" ]] || continue
    [[ -d "${base}/${name}" ]] || continue
    printf '%s\n' "${name}"
  done | sort -r
}

find_previous() {
  local target_name="$1"
  local suffix="$2"
  local base="$3"
  local seen_target=0
  local name
  while IFS= read -r name; do
    if [[ "${seen_target}" -eq 1 ]]; then
      # Skip incomplete neighbors unless forced; keep searching older same-device folders.
      if is_complete "${base}/${name}" || [[ "${FORCE_INCOMPLETE}" -eq 1 ]]; then
        PREVIOUS_NAME="${name}"
        PREVIOUS="${base}/${name}"
        return 0
      fi
      log "WARN skipping incomplete previous candidate: ${name}"
      continue
    fi
    if [[ "${name}" == "${target_name}" ]]; then
      seen_target=1
    fi
  done < <(list_same_device_folders "${suffix}" "${base}")
  return 1
}

# Volume device id (same volume required for hardlink / clone).
vol_id() {
  stat -f '%d' "$1" 2>/dev/null || stat -c '%d' "$1"
}

file_size() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1"
}

file_inode() {
  stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"
}

sha256_file() {
  # Prefer shasum (macOS), then sha256sum, then openssl.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

# True when both paths have the same SHA-256. One shasum/sha256sum process for both
# files when possible (half the spawns vs hashing each path separately).
sha256_pair_match() {
  local a="$1" b="$2" out h1 h2
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "${a}" "${b}")" || return 1
    h1="$(printf '%s\n' "${out}" | awk 'NR==1 {print $1}')"
    h2="$(printf '%s\n' "${out}" | awk 'NR==2 {print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "${a}" "${b}")" || return 1
    h1="$(printf '%s\n' "${out}" | awk 'NR==1 {print $1}')"
    h2="$(printf '%s\n' "${out}" | awk 'NR==2 {print $1}')"
  else
    h1="$(openssl dgst -sha256 "${a}" | awk '{print $NF}')"
    h2="$(openssl dgst -sha256 "${b}" | awk '{print $NF}')"
  fi
  [[ -n "${h1}" && "${h1}" == "${h2}" ]]
}

hash_job_count() {
  if [[ -n "${DEDUPE_HASH_JOBS:-}" && "${DEDUPE_HASH_JOBS}" =~ ^[0-9]+$ && "${DEDUPE_HASH_JOBS}" -ge 1 ]]; then
    printf '%s\n' "${DEDUPE_HASH_JOBS}"
    return
  fi
  local n
  n="$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
  if [[ "${n}" =~ ^[0-9]+$ && "${n}" -ge 1 ]]; then
    printf '%s\n' "${n}"
  else
    printf '4\n'
  fi
}

progress_every() {
  local n="${PROGRESS_EVERY_FILES:-50}"
  if [[ "${n}" =~ ^[0-9]+$ && "${n}" -ge 1 ]]; then
    printf '%s\n' "${n}"
  else
    printf '50\n'
  fi
}

# Try APFS clone into dest path (must not exist). Returns 0 on success.
try_clone() {
  local src="$1" dest="$2"
  # macOS cp -c uses clonefile(2); fails (no silent full-copy fallback) when unsupported.
  if cp -c "${src}" "${dest}" 2>/dev/null; then
    return 0
  fi
  return 1
}

try_hardlink() {
  local src="$1" dest="$2"
  ln "${src}" "${dest}" 2>/dev/null
}

human_bytes() {
  local b="$1"
  if [[ "${b}" -ge 1073741824 ]]; then
    awk -v b="${b}" 'BEGIN { printf "%.2f GB", b/1073741824 }'
  elif [[ "${b}" -ge 1048576 ]]; then
    awk -v b="${b}" 'BEGIN { printf "%.1f MB", b/1048576 }'
  elif [[ "${b}" -ge 1024 ]]; then
    awk -v b="${b}" 'BEGIN { printf "%.0f KB", b/1024 }'
  else
    printf '%s B' "${b}"
  fi
}

read_dedupe_state() {
  local state_file="$1"
  STATE_STATUS=""
  STATE_CANONICAL=""
  if [[ -f "${state_file}" ]]; then
    # shellcheck disable=SC1090
    while IFS='=' read -r key val; do
      [[ -z "${key}" || "${key}" =~ ^# ]] && continue
      case "${key}" in
        status) STATE_STATUS="${val}" ;;
        canonical) STATE_CANONICAL="${val}" ;;
      esac
    done < "${state_file}"
  fi
}

write_dedupe_state() {
  local older_meta="$1"
  local canonical_name="$2"
  local previous_name="$3"
  local method="$4"
  local linked="$5"
  local skipped="$6"
  local reclaimed="$7"
  mkdir -p "${older_meta}"
  cat > "${older_meta}/dedupe_state" <<EOF
status=reduced
canonical=${canonical_name}
previous=${previous_name}
reduced_at=$(ts)
mode=${MODE}
method=${method}
files_linked=${linked}
files_skipped=${skipped}
bytes_reclaimed=${reclaimed}
EOF
  # Convenience marker for quick existence checks
  printf '%s\n' "${canonical_name}" > "${older_meta}/dedupe_reduced"
}

# ─── Main ────────────────────────────────────────────────────────────────────

resolve_target
resolve_pair

log "INFO canonical=${CANONICAL}"
log "INFO older=${OLDER}"
log "INFO device_suffix=${SUFFIX}"
log "INFO mode=${MODE}"

if ! is_complete "${CANONICAL}" && [[ "${FORCE_INCOMPLETE}" -ne 1 ]]; then
  log "ERROR Canonical/baseline backup looks incomplete (run_status != complete)."
  log "HINT  Finish the backup first, or pass --force-incomplete to override."
  exit 3
fi

if ! is_complete "${OLDER}" && [[ "${FORCE_INCOMPLETE}" -ne 1 ]]; then
  log "ERROR Reduce/older backup looks incomplete: ${OLDER_NAME}"
  log "HINT  Finish that backup first, or pass --force-incomplete to override."
  exit 3
fi

if [[ "$(vol_id "${CANONICAL}")" != "$(vol_id "${OLDER}")" ]]; then
  log "ERROR Backups are not on the same volume; hardlink/clone require same volume."
  exit 4
fi

OLDER_META="${OLDER}/.transfer_meta"
STATE_FILE="${OLDER_META}/dedupe_state"
read_dedupe_state "${STATE_FILE}"
if [[ "${STATE_STATUS}" == "reduced" && "${STATE_CANONICAL}" == "${CANONICAL_NAME}" && "${ALLOW_RERUN}" -ne 1 ]]; then
  log "OK already_reduced canonical=${CANONICAL_NAME} previous=${OLDER_NAME}"
  log "HINT Pass --force to re-scan and re-link if needed."
  exit 0
fi

CANDIDATES=0
ALREADY_LINKED=0
HASH_MISMATCH=0
MISSING_IN_CANONICAL=0
LINKED=0
SKIPPED=0
RECLAIMABLE=0
METHOD_USED=""   # clone | hardlink | mixed
CLONE_COUNT=0
HARDLINK_COUNT=0
ERRORS=0

LOG_FILE="${OLDER_META}/dedupe_log"
if [[ "${MODE}" == "apply" ]]; then
  mkdir -p "${OLDER_META}"
  {
    echo "==== dedupe apply $(ts) ===="
    echo "canonical=${CANONICAL}"
    echo "previous=${OLDER}"
  } >> "${LOG_FILE}"
fi

# Prefer clone when a probe works in the older folder's meta dir.
SUPPORTS_CLONE=0
probe_src="${CANONICAL}/.transfer_meta/run_status"
if [[ ! -f "${probe_src}" ]]; then
  # Any small file in canonical meta, or create a tiny probe from /dev/null via printf
  probe_src=""
fi
PROBE_DIR="${OLDER_META}"
mkdir -p "${PROBE_DIR}"
PROBE_SRC="${PROBE_DIR}/.dedupe_clone_probe_src"
PROBE_DST="${PROBE_DIR}/.dedupe_clone_probe_dst"
printf 'probe\n' > "${PROBE_SRC}"
rm -f "${PROBE_DST}"
if try_clone "${PROBE_SRC}" "${PROBE_DST}"; then
  SUPPORTS_CLONE=1
fi
rm -f "${PROBE_SRC}" "${PROBE_DST}"

if [[ "${SUPPORTS_CLONE}" -eq 1 ]]; then
  log "INFO link_method_preference=apfs_clone (fallback=hardlink)"
else
  log "INFO link_method_preference=hardlink"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dedupe.XXXXXX")"
cleanup_work() { rm -rf "${WORK_DIR}"; }
trap cleanup_work EXIT

CAND_FILE="${WORK_DIR}/candidates"   # lines: SIZE<TAB>REL
MATCH_FILE="${WORK_DIR}/matches"     # hash-verified candidates for apply
: > "${CAND_FILE}"
: > "${MATCH_FILE}"

PROGRESS_EVERY="$(progress_every)"

# Phase 1: walk older tree; collect path+size candidates (hash deferred on apply).
while IFS= read -r -d '' older_file; do
  rel="${older_file#"${OLDER}"/}"
  [[ "${rel}" == .transfer_meta/* ]] && continue
  [[ "${rel}" == .transfer_meta ]] && continue

  canonical_file="${CANONICAL}/${rel}"
  if [[ ! -f "${canonical_file}" ]]; then
    MISSING_IN_CANONICAL=$((MISSING_IN_CANONICAL + 1))
    continue
  fi
  # Skip if either side is not a regular file (e.g. symlink)
  [[ -f "${older_file}" && ! -L "${older_file}" ]] || continue
  [[ -f "${canonical_file}" && ! -L "${canonical_file}" ]] || continue

  osize="$(file_size "${older_file}")"
  csize="$(file_size "${canonical_file}")"
  if [[ "${osize}" != "${csize}" ]]; then
    continue
  fi

  # Same inode already shares storage
  if [[ "$(file_inode "${older_file}")" == "$(file_inode "${canonical_file}")" ]]; then
    ALREADY_LINKED=$((ALREADY_LINKED + 1))
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [[ "${MODE}" == "dry-run" ]]; then
    # Estimate: path+size match counts as candidate; hash deferred to apply.
    # Optional hash for accuracy when DEDUPE_HASH_ON_DRY_RUN=1.
    if [[ "${DEDUPE_HASH_ON_DRY_RUN:-0}" == "1" ]]; then
      if ! sha256_pair_match "${older_file}" "${canonical_file}"; then
        HASH_MISMATCH=$((HASH_MISMATCH + 1))
        continue
      fi
    fi
    CANDIDATES=$((CANDIDATES + 1))
    RECLAIMABLE=$((RECLAIMABLE + osize))
    # size= first so paths with spaces parse reliably (UI + logs).
    log "CANDIDATE size=${osize} ${rel}"
    continue
  fi

  CANDIDATES=$((CANDIDATES + 1))
  printf '%s\t%s\n' "${osize}" "${rel}" >> "${CAND_FILE}"
done < <(find "${OLDER}" -type f ! -path '*/.transfer_meta/*' -print0)

if [[ "${MODE}" == "dry-run" ]]; then
  log "SUMMARY mode=dry-run canonical=${CANONICAL_NAME} previous=${OLDER_NAME}"
  log "SUMMARY candidates=${CANDIDATES} already_linked=${ALREADY_LINKED} hash_mismatch=${HASH_MISMATCH} missing_in_canonical=${MISSING_IN_CANONICAL}"
  log "SUMMARY reclaimable_bytes=${RECLAIMABLE} reclaimable=$(human_bytes "${RECLAIMABLE}")"
  log "HINT Dry-run uses path+size for estimates. Apply always verifies SHA-256 before linking."
  log "HINT Run with --apply to reclaim space. Set DEDUPE_HASH_ON_DRY_RUN=1 for hashed estimates."
  exit 0
fi

# ─── Apply: parallel SHA-256 gate, then sequential clone/hardlink ─────────────
HASH_JOBS="$(hash_job_count)"
log "INFO apply_candidates=${CANDIDATES} hash_jobs=${HASH_JOBS}"

HASHED=0
if [[ "${CANDIDATES}" -gt 0 ]]; then
  HASH_WORKER="${WORK_DIR}/hash_worker.sh"
  cat > "${HASH_WORKER}" <<'WORKER'
#!/bin/bash
set -euo pipefail
line="$1"
size="${line%%	*}"
rel="${line#*	}"
older_file="${OLDER}/${rel}"
canonical_file="${CANONICAL}/${rel}"

pair_match() {
  local a="$1" b="$2" out h1 h2
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "${a}" "${b}")" || return 1
    h1="$(printf '%s\n' "${out}" | awk 'NR==1 {print $1}')"
    h2="$(printf '%s\n' "${out}" | awk 'NR==2 {print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "${a}" "${b}")" || return 1
    h1="$(printf '%s\n' "${out}" | awk 'NR==1 {print $1}')"
    h2="$(printf '%s\n' "${out}" | awk 'NR==2 {print $1}')"
  else
    h1="$(openssl dgst -sha256 "${a}" | awk '{print $NF}')"
    h2="$(openssl dgst -sha256 "${b}" | awk '{print $NF}')"
  fi
  [[ -n "${h1}" && "${h1}" == "${h2}" ]]
}

if pair_match "${older_file}" "${canonical_file}"; then
  printf 'MATCH\t%s\t%s\n' "${size}" "${rel}"
else
  printf 'MISMATCH\t%s\t%s\n' "${size}" "${rel}"
fi
WORKER
  chmod +x "${HASH_WORKER}"

  export OLDER CANONICAL
  while IFS= read -r result; do
    [[ -z "${result}" ]] && continue
    status="${result%%	*}"
    rest="${result#*	}"
    size="${rest%%	*}"
    rel="${rest#*	}"
    HASHED=$((HASHED + 1))
    if [[ "${status}" == "MATCH" ]]; then
      printf '%s\t%s\n' "${size}" "${rel}" >> "${MATCH_FILE}"
    else
      HASH_MISMATCH=$((HASH_MISMATCH + 1))
      log "SKIP hash_mismatch ${rel}"
      echo "SKIP hash_mismatch ${rel}" >> "${LOG_FILE}"
    fi
    if (( HASHED % PROGRESS_EVERY == 0 || HASHED == CANDIDATES )); then
      log "PROGRESS phase=hash hashed=${HASHED} candidates=${CANDIDATES} linked=${LINKED} skipped=${SKIPPED} reclaimable_bytes=${RECLAIMABLE} errors=${ERRORS} hash_mismatch=${HASH_MISMATCH}"
    fi
  done < <(
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && continue
      printf '%s\0' "${line}"
    done < "${CAND_FILE}" \
    | xargs -0 -P "${HASH_JOBS}" -I{} /bin/bash "${HASH_WORKER}" {}
  )
fi

# Phase 3: sequential in-place link (clone → hardlink). Linking stays single-threaded.
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line}" ]] && continue
  osize="${line%%	*}"
  rel="${line#*	}"
  older_file="${OLDER}/${rel}"
  canonical_file="${CANONICAL}/${rel}"

  parent="$(dirname "${older_file}")"
  tmp="${parent}/.dedupe_replace_$$.tmp"
  rm -f "${tmp}"
  linked_ok=0
  used=""

  if [[ "${SUPPORTS_CLONE}" -eq 1 ]] && try_clone "${canonical_file}" "${tmp}"; then
    if mv -f "${tmp}" "${older_file}"; then
      linked_ok=1
      used="clone"
      CLONE_COUNT=$((CLONE_COUNT + 1))
    else
      rm -f "${tmp}"
    fi
  fi

  if [[ "${linked_ok}" -eq 0 ]]; then
    rm -f "${tmp}"
    if try_hardlink "${canonical_file}" "${tmp}"; then
      if mv -f "${tmp}" "${older_file}"; then
        linked_ok=1
        used="hardlink"
        HARDLINK_COUNT=$((HARDLINK_COUNT + 1))
      else
        rm -f "${tmp}"
      fi
    else
      rm -f "${tmp}"
    fi
  fi

  if [[ "${linked_ok}" -eq 1 ]]; then
    LINKED=$((LINKED + 1))
    RECLAIMABLE=$((RECLAIMABLE + osize))
    log "OK ${used} ${rel}"
    echo "OK ${used} ${rel}" >> "${LOG_FILE}"
  else
    ERRORS=$((ERRORS + 1))
    log "FAIL link ${rel}"
    echo "FAIL link ${rel}" >> "${LOG_FILE}"
  fi

  match_total=$((HASHED - HASH_MISMATCH))
  total_linked_progress=$((LINKED + ERRORS))
  if (( total_linked_progress % PROGRESS_EVERY == 0 || total_linked_progress == match_total )); then
    log "PROGRESS phase=link hashed=${HASHED} candidates=${CANDIDATES} linked=${LINKED} skipped=${SKIPPED} reclaimable_bytes=${RECLAIMABLE} errors=${ERRORS} hash_mismatch=${HASH_MISMATCH}"
  fi
done < "${MATCH_FILE}"

if [[ "${CLONE_COUNT}" -gt 0 && "${HARDLINK_COUNT}" -gt 0 ]]; then
  METHOD_USED="mixed"
elif [[ "${CLONE_COUNT}" -gt 0 ]]; then
  METHOD_USED="clone"
elif [[ "${HARDLINK_COUNT}" -gt 0 ]]; then
  METHOD_USED="hardlink"
else
  METHOD_USED="none"
fi

write_dedupe_state "${OLDER_META}" "${CANONICAL_NAME}" "${OLDER_NAME}" \
  "${METHOD_USED}" "${LINKED}" "${SKIPPED}" "${RECLAIMABLE}"

{
  echo "SUMMARY linked=${LINKED} skipped=${SKIPPED} reclaimable_bytes=${RECLAIMABLE} method=${METHOD_USED} errors=${ERRORS}"
  echo "==== end $(ts) ===="
} >> "${LOG_FILE}"

log "SUMMARY mode=apply canonical=${CANONICAL_NAME} previous=${OLDER_NAME}"
log "SUMMARY linked=${LINKED} already_linked=${ALREADY_LINKED} hash_mismatch=${HASH_MISMATCH} errors=${ERRORS}"
log "SUMMARY reclaimable_bytes=${RECLAIMABLE} reclaimable=$(human_bytes "${RECLAIMABLE}") method=${METHOD_USED}"
log "OK reduced state written to ${STATE_FILE}"

if [[ "${ERRORS}" -gt 0 ]]; then
  exit 4
fi
exit 0
