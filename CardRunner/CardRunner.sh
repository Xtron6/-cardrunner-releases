#!/bin/zsh
# or whatever you're using as the interpreter

# Ensure standard Unix tools are available to the script
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

CARDRUNNER_VERSION="v1.0"   # overridden at runtime by --app-version from Swift

# ── cardcopy binary selection ────────────────────────────────────────────────
# cardcopy is CardRunner's native copy engine (fcopyfile + polling thread).
# It lives in the same Resources/ folder as this script and is the only
# supported copy path. There is no fallback — if cardcopy is missing the
# ingest fails loudly rather than silently using a slower engine.
_BUNDLED_CARDCOPY="$(dirname "$0")/cardcopy"
if [[ -x "$_BUNDLED_CARDCOPY" ]]; then
    CARDCOPY_BIN="$_BUNDLED_CARDCOPY"
else
    echo "COPY_ERROR reason=cardcopy_missing"
    echo "cardcopy binary not found in app bundle — reinstall CardRunner." >&2
    exit 1
fi

# ===========================================================
#  CardRunner Ingest Engine – GUI-Optimized (no interactive mode)
# ===========================================================
#  Flags (used by the SwiftUI GUI):
#     --card <path>       e.g. /Volumes/Gallo1Card
#     --primary <path>    e.g. /Volumes/Gallo\ 8TB
#     --project <name>    e.g. 251118_BigTenIndyCar3DProject
#     --dest-root <path>  bypass --primary/--project; use this folder directly as the
#                         ingest base (date subfolders are still created inside it)
#     --subfolder <name>  e.g. clips (default if omitted)
#     --cardlabel <name>  override folder name under date (e.g. Steadicam)
#     --latest <N>        copy newest N .mp4 first (best-effort)
#     --dry-run           simulate, no write, no eject
#     --today-only        only ingest media modified today (local time)
#     --auto-eject        eject card after ingest completes (if not dry-run)
#     --winter-olympics   use Olympics folder structure
#     --olympics-code <code> folder code used in day folder name (e.g. TUWE, CURL, etc.)
#
#  Copies ONLY video files:
#     .mp4, .mov, .mxf, .crm, .r3d
#
#  Emits for the GUI:
#     PROGRESS_META media_total=... bytes_total=... new_files=... bytes_new=...
#     PROGRESS_FILE size=NN path/to/file.ext
#     PROGRESS_SUMMARY avg_mb=NN duration_sec=NN new_files=NN
#     PROGRESS_DEST /absolute/path/to/dest
# ===========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Central log directory (avoid writing into the app bundle so code signing/notarization stays valid)
LOG_DIR="$HOME/Library/Logs/CardRunner"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Daily log files — one per calendar day, kept for 7 days.
# Older files are deleted automatically on each run so disk use stays bounded.
LOG_FILE="${LOG_DIR}/cardrunner_$(date +%Y%m%d).log"
find "$LOG_DIR" -name "cardrunner_[0-9]*.log"    -mtime +7 -delete 2>/dev/null || true
find "$LOG_DIR" -name "cardrunner*.log.gz"        -mtime +7 -delete 2>/dev/null || true

CARD_PATH=""
PRIMARY_ROOT=""
PROJECT_NAME=""
DEST_ROOT=""      # when set, overrides PRIMARY_ROOT/PROJECT_NAME as the base dest
SUBFOLDER=""
CARDLABEL=""
IGNORE_MANIFEST="no"   # --ignore-manifest: re-copy files even if the card manifest says already-ingested
LATEST_COUNT=0
DRY_RUN="no"
TODAY_ONLY="no"      # legacy — still honoured; sets DATE_FROM to today
DATE_FROM=""         # YYYYMMDD — lower bound: only ingest files on or after this date
DATE_TO=""           # YYYYMMDD — upper bound: only ingest files on or before this date (range mode)
DATES_LIST=""        # comma-separated YYYYMMDD values — exact dates to ingest (multi-select picker)
AUTO_EJECT="no"
WINTER_OLYMPICS_MODE="no"
COPY_XML="no"
INCLUDE_PROXIES="no"
VERIFY="no"
FULL_VERIFY="no"
RENAME_TEMPLATE=""   # e.g. "{cardname}_{original}" — empty = no rename
DATE_FORMAT="%y%m%d"  # folder date format; default = YYMMDD (e.g. 260411)
DATE_OVERRIDE=""      # YYYYMMDD: use this date for all dest folders (wrong-clock cameras)
BROADCAST_DAY_HOUR=0  # 0 = disabled; >0 = clips before this hour use previous calendar day
FINDER_TAG_COLOR=""   # empty = disabled; "green", "orange", "purple"
TRANSFER_REPORT="no"
SECONDARY_ROOTS=()  # repeated --secondary mirror targets; empty = single-dest (N-way mirror)
REEL_FILTER=()      # array of top-level reel folder names to include (empty = all)
REEL_MULTI="no"     # yes = multiple reels; inject reel name as subfolder in dest path
MODE="video"    # "video" or "photo"; default is video
SORT_ORDER="oldest"  # "oldest" | "newest" — dispatch order for the final file queue
SCAFFOLD_FOLDERS=""  # pipe-separated folder names to mkdir -p in PROJECT_ROOT at ingest start

# Global ingest manifest — tracks every file ever copied from each card so
# re-ingesting an unformatted card into a new project doesn't re-copy clips
# that were already offloaded to a different destination.
GLOBAL_MANIFEST_DIR="$HOME/Library/Application Support/CardRunner/manifests"
CARD_MANIFEST=""    # set per-run by init_card_manifest()

OLYMPICS_CODE="TUWE"   # middle segment for Olympics day folders

# Per-file date-based routing globals
PROJECT_ROOT=""
STANDARD_SUBROOT=""
DEST_FRIENDLY=""
PROJECT_CODE=""

typeset -A OLY_DAY_CACHE
OLY_MAX_DAY=0

# Rename-on-ingest: maps original rel path → new basename (populated at copy time)
typeset -A _rename_map

# -----------------------------------------------------------
# Helpers
# -----------------------------------------------------------

# -----------------------------------------------------------
# Proxy detection
# Returns 0 (true) if the relative path looks like an in-camera proxy.
#   - Sony: base filename ends with S03 before the extension
#           e.g. XG_FX3_0106S03.MP4
#   - Generic: file lives inside a Proxy/, PROXY/, Sub/, or SUBCLIP/ folder
# -----------------------------------------------------------
is_proxy_file() {
  local rel="$1"
  local base="${rel##*/}"
  local name_no_ext="${base%.*}"

  # Sony S03 proxy (case-insensitive)
  local upper_name="${(U)name_no_ext}"
  if [[ "$upper_name" == *S03 ]]; then
    return 0
  fi

  # Folder-based proxy (Canon, Blackmagic, Panasonic, etc.)
  case "$rel" in
    */Proxy/*|*/PROXY/*|*/proxy/*|*/Sub/*|*/SUB/*|*/SUBCLIP/*|*/subclip/*)
      return 0 ;;
  esac

  return 1
}

human_mb() {
  local b=$1
  echo $(((b + 524288) / 1048576))
}

log_line() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"; }

# Phase timing helpers — stamp start/end of each major phase so the log shows
# exactly how long scanning, building, and copying each took.  Diagnoses slow
# starts, stuck builds, and large-card overhead without needing to re-run.
_PHASE_START_T=0
phase_start() {
  _PHASE_START_T=$(date +%s)
  log_line "PHASE_START $1"
}
phase_end() {
  local elapsed=$(( $(date +%s) - _PHASE_START_T ))
  log_line "PHASE_END $1 (${elapsed}s)"
}

# Tag the first file of a new-batch transfer with a color using the same
# com.apple.metadata:_kMDItemUserTags xattr format that macOS "Customize Folder" writes.
# This produces actual folder/file icon tinting in Finder (Sonoma+) — not just a dot label.
# Color is controlled by $FINDER_TAG_COLOR ("red","orange","yellow","green","blue","purple","gray").
# Finder label indices: 1=gray, 2=green, 3=purple, 4=blue, 5=yellow, 6=red, 7=orange
# Only fires when $FINDER_TAG_COLOR is set, $DRY_RUN != "yes", and the path exists.
add_green_finder_tag() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  [[ "$DRY_RUN" == "yes" ]] && return 0
  [[ -z "$FINDER_TAG_COLOR" ]] && return 0

  local color_name label_index
  case "$FINDER_TAG_COLOR" in
    red)    color_name="Red";    label_index=6 ;;
    orange) color_name="Orange"; label_index=7 ;;
    yellow) color_name="Yellow"; label_index=5 ;;
    green)  color_name="Green";  label_index=2 ;;
    blue)   color_name="Blue";   label_index=4 ;;
    purple) color_name="Purple"; label_index=3 ;;
    gray)   color_name="Gray";   label_index=1 ;;
    *)      color_name="Green";  label_index=2 ;;
  esac

  log_line "FINDER_TAG: color=${FINDER_TAG_COLOR} index=${label_index} file=$(basename "$file")"

  # Write _kMDItemUserTags as a binary plist — exact same format as "Customize Folder".
  # Uses python3 (always present on macOS) + ctypes setxattr — no Finder dependency.
  python3 - "$file" "$color_name" "$label_index" 2>/dev/null <<'PYEOF'
import plistlib, sys, ctypes
path, name, idx = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = plistlib.dumps([f"{name}\n{idx}"], fmt=plistlib.FMT_BINARY)
libc = ctypes.CDLL(None)
ret = libc.setxattr(path.encode(), b"com.apple.metadata:_kMDItemUserTags",
                    data, len(data), 0, 0)
sys.exit(0 if ret == 0 else 1)
PYEOF
  local _py_exit=$?
  [[ $_py_exit -ne 0 ]] && log_line "FINDER_TAG_ERROR: setxattr failed (exit=${_py_exit}) for $(basename "$file")"
}

# Returns true (0) if the given directory already contains at least one media file.
# Checks two levels deep (-maxdepth 2) so that files inside a Proxies/ subfolder
# are still detected as "existing media" for the green-tag subsequent-transfer logic.
dest_has_existing_media() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  find "$dir" -maxdepth 2 -type f \( \
    -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mxf" -o \
    -iname "*.r3d" -o -iname "*.braw" -o -iname "*.ari" -o \
    -iname "*.arx" -o -iname "*.mts" -o -iname "*.m2ts" -o \
    -iname "*.cr3" -o -iname "*.nef" -o \
    -iname "*.arw" -o -iname "*.jpg" -o -iname "*.jpeg" \
  \) 2>/dev/null | grep -q .
}

friendly_name() {
  local raw="$1"
  # Keep letters, digits, hyphens, underscores — strip spaces, slashes, colons, etc.
  # A7-IV-01 → A7-IV-01  (was incorrectly becoming A7IV01 before this fix)
  local cleaned="${raw//[^A-Za-z0-9_-]/}"
  # Strip leading/trailing hyphens that stripping other chars might leave behind
  cleaned="${cleaned##-}"
  cleaned="${cleaned%%-}"
  [[ -z "$cleaned" ]] && cleaned="Card"
  echo "$cleaned"
}

# Create a temp reference file set to midnight on the given YYYYMMDD date.
# Usage: make_date_ref YYYYMMDD outfile
# If YYYYMMDD is empty, defaults to today.
make_date_ref() {
  local ymd="${1:-$(date +%Y%m%d)}"
  local ref="$2"
  touch -t "${ymd}0000" "$ref"
}
# Legacy alias kept for any external callers
make_midnight_ref() { make_date_ref "$(date +%Y%m%d)" "$1"; }

# make_date_ref_next_day YYYYMMDD outfile
# Creates a reference file at midnight of the DAY AFTER the given date.
# Used as the upper-bound sentinel: -not -newer ref = mtime <= end of that day.
make_date_ref_next_day() {
  local ymd="$1"
  local ref="$2"
  local next
  next=$(date -j -v+1d -f "%Y%m%d" "$ymd" "+%Y%m%d" 2>/dev/null \
         || date -d "${ymd:0:4}-${ymd:4:2}-${ymd:6:2} +1 day" "+%Y%m%d")
  touch -t "${next}0000" "$ref"
}

# Append files matching a SINGLE exact date to an existing list file.
# Usage: _append_files_for_date YYYYMMDD src outfile mode [copy_xml]
#   mode    = "video" | "photo"
#   copy_xml = "yes" | "" (optional, defaults to $COPY_XML global)
_append_files_for_date() {
  local ymd="$1" src="$2" outfile="$3" mode="$4"
  local ref ref_next
  ref="$(mktemp /tmp/cardrunner_dt_lo.XXXXXX)"
  ref_next="$(mktemp /tmp/cardrunner_dt_hi.XXXXXX)"
  make_date_ref          "$ymd" "$ref"
  make_date_ref_next_day "$ymd" "$ref_next"

  if [[ "$mode" == "photo" ]]; then
    if [[ "$COPY_XML" == "yes" ]]; then
      find "$src" -type f -newer "$ref" ! -newer "$ref_next" \
        ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
        \( \
          -iname '*.jpg'  -o -iname '*.jpeg' -o \
          -iname '*.png'  -o -iname '*.tif'   -o -iname '*.tiff' -o \
          -iname '*.heic' -o -iname '*.heif'  -o \
          -iname '*.dng'  -o -iname '*.cr2'   -o -iname '*.cr3'  -o \
          -iname '*.nef'  -o -iname '*.arw'   -o -iname '*.raf'  -o \
          -iname '*.rw2'  -o -iname '*.orf'   -o -iname '*.sr2'  -o \
          -iname '*.3fr' -o -iname '*.fff'   -o \
          -iname '*.iiq' -o -iname '*.mos'   -o \
          -iname '*.rwl' -o -iname '*.mrw'   -o \
          -iname '*.nrw' -o -iname '*.pef'   -o \
          -iname '*.srw' -o -iname '*.dcr'   -o -iname '*.kdc'  -o \
          -iname '*.xml'  -o -iname '*.xmp' \
        \) \
        | while IFS= read -r f; do echo "${f#$src/}" >> "$outfile"; done
    else
      find "$src" -type f -newer "$ref" ! -newer "$ref_next" \
        ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
        \( \
          -iname '*.jpg'  -o -iname '*.jpeg' -o \
          -iname '*.png'  -o -iname '*.tif'   -o -iname '*.tiff' -o \
          -iname '*.heic' -o -iname '*.heif'  -o \
          -iname '*.dng'  -o -iname '*.cr2'   -o -iname '*.cr3'  -o \
          -iname '*.nef'  -o -iname '*.arw'   -o -iname '*.raf'  -o \
          -iname '*.rw2'  -o -iname '*.orf'   -o -iname '*.sr2'  -o \
          -iname '*.3fr' -o -iname '*.fff'   -o \
          -iname '*.iiq' -o -iname '*.mos'   -o \
          -iname '*.rwl' -o -iname '*.mrw'   -o \
          -iname '*.nrw' -o -iname '*.pef'   -o \
          -iname '*.srw' -o -iname '*.dcr'   -o -iname '*.kdc'  -o \
          -iname '*.xmp' \
        \) \
        | while IFS= read -r f; do echo "${f#$src/}" >> "$outfile"; done
    fi
  else
    # video
    if [[ "$COPY_XML" == "yes" ]]; then
      find "$src" -type f -newer "$ref" ! -newer "$ref_next" \
        ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
        \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mxf' -o -iname '*.crm' -o -iname '*.r3d' \
           -o -iname '*.braw' \
           -o -iname '*.ari' -o -iname '*.arx' \
           -o -iname '*.mts' -o -iname '*.m2ts' \
           -o -iname '*.avi' -o -iname '*.mkv' \
           -o -iname '*.dng' -o -iname '*.cdng' -o -iname '*.raw' \
           -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' -o -iname '*.m2v' \
           -o -iname '*.insv' -o -iname '*.360' -o -iname '*.lrv' \
           -o -iname '*.cine' -o -iname '*.mp' \
           -o -iname '*.xml' \) \
        | while IFS= read -r f; do echo "${f#$src/}" >> "$outfile"; done
    else
      find "$src" -type f -newer "$ref" ! -newer "$ref_next" \
        ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
        \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mxf' -o -iname '*.crm' -o -iname '*.r3d' \
           -o -iname '*.braw' \
           -o -iname '*.ari' -o -iname '*.arx' \
           -o -iname '*.mts' -o -iname '*.m2ts' \
           -o -iname '*.avi' -o -iname '*.mkv' \
           -o -iname '*.dng' -o -iname '*.cdng' -o -iname '*.raw' \
           -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' -o -iname '*.m2v' \
           -o -iname '*.insv' -o -iname '*.360' -o -iname '*.lrv' \
           -o -iname '*.cine' -o -iname '*.mp' \) \
        | while IFS= read -r f; do echo "${f#$src/}" >> "$outfile"; done
    fi
  fi
  rm -f "$ref" "$ref_next"
}

# Detect media source dir on card
# Looks for Sony structure first, then other camera layouts, then generic media dir
# Detect media source dir on card
# Handles common Sony / CFexpress layouts, then falls back to scanning the whole card.
# Detect media source dir on card
# For Sony / CFexpress cards with M4ROOT / XDROOT, just scan the whole card root
# so we pick up both folders. For generic stills layouts, prefer DCIM.
# Detect media source dir on card
# For Sony / CFexpress cards (M4ROOT / XDROOT anywhere on the card),
# just scan the card root so we pick up all lanes. For generic stills
# cards, prefer DCIM. Otherwise fall back to the card root.
detect_src_dir() {
  local root="$1"

  # Always scan from the card root so we never miss cinema-format content.
  #
  # The old logic returned card/DCIM when a DCIM folder existed, which broke
  # cameras that store footage OUTSIDE DCIM — Canon R5C (XF-AVC MXF under
  # /CONTENTS/CLIPS001/), Blackmagic (BRAW under /DCIM/../Footage/), and any
  # camera that writes both stills (DCIM) and cinema clips (elsewhere) to the
  # same card.  The file-type filter (-iname '*.mxf' etc.) is already the
  # correct gate for what gets picked up — restricting the scan root caused
  # silent data loss with no error or warning to the operator.
  echo "$root"
  return 0
}

# Build list of VIDEO files for current card (optionally today-only, optionally with XML)
_build_media_file_list_video() {
  local src="$1"
  local outfile="$2"

  : > "$outfile"

  if [[ -n "$DATES_LIST" ]]; then
    # Multi-date picker: iterate each selected date, append matching files.
    # Log per-date file count so the log can confirm every date's contribution.
    local _d
    local _dates_arr=("${(@s:,:)DATES_LIST}")
    for _d in "${_dates_arr[@]}"; do
      # Skip empty tokens produced by a trailing comma (e.g. "20260515,")
      # to prevent make_date_ref from defaulting to today's date.
      [[ -z "$_d" ]] && continue
      _validate_date "$_d" || { log_line "DATE_FILES: date=$_d mode=video skipped=invalid_format"; continue; }
      local _before _after _date_count
      _before=$(wc -l < "$outfile" | tr -d ' ')
      _append_files_for_date "$_d" "$src" "$outfile" "video"
      _after=$(wc -l < "$outfile" | tr -d ' ')
      _date_count=$(( _after - _before ))
      log_line "DATE_FILES: date=$_d mode=video files=$_date_count"
    done
  elif [[ -n "$DATE_FROM" ]]; then
      local ref ref_to upper_pred
      ref="$(mktemp /tmp/cardrunner_midnight.XXXXXX)"
      make_date_ref "$DATE_FROM" "$ref"

      # Optional upper bound (range mode)
      if [[ -n "$DATE_TO" ]]; then
        ref_to="$(mktemp /tmp/cardrunner_midnight_to.XXXXXX)"
        make_date_ref_next_day "$DATE_TO" "$ref_to"
        upper_pred="-not -newer $ref_to"
      else
        ref_to=""; upper_pred=""
      fi

      if [[ "$COPY_XML" == "yes" ]]; then
        find "$src" -type f -newer "$ref" ${upper_pred} \
          ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
          \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mxf' -o -iname '*.crm' -o -iname '*.r3d' \
             -o -iname '*.braw' \
             -o -iname '*.ari' -o -iname '*.arx' \
             -o -iname '*.mts' -o -iname '*.m2ts' \
             -o -iname '*.xml' \) \
          | while IFS= read -r f; do
              echo "${f#$src/}" >> "$outfile"
            done
      else
        find "$src" -type f -newer "$ref" ${upper_pred} \
          ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
          \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mxf' -o -iname '*.crm' -o -iname '*.r3d' \
             -o -iname '*.braw' \
             -o -iname '*.ari' -o -iname '*.arx' \
             -o -iname '*.mts' -o -iname '*.m2ts' \) \
          | while IFS= read -r f; do
              echo "${f#$src/}" >> "$outfile"
            done
      fi

      rm -f "$ref" "$ref_to"
    else
      if [[ "$COPY_XML" == "yes" ]]; then
        find "$src" -type f \
          ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
          \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mxf' -o -iname '*.crm' -o -iname '*.r3d' \
             -o -iname '*.braw' \
             -o -iname '*.ari' -o -iname '*.arx' \
             -o -iname '*.mts' -o -iname '*.m2ts' \
             -o -iname '*.xml' \) \
          | while IFS= read -r f; do
              echo "${f#$src/}" >> "$outfile"
            done
      else
        find "$src" -type f \
          ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
          \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mxf' -o -iname '*.crm' -o -iname '*.r3d' \
             -o -iname '*.braw' \
             -o -iname '*.ari' -o -iname '*.arx' \
             -o -iname '*.mts' -o -iname '*.m2ts' \) \
          | while IFS= read -r f; do
              echo "${f#$src/}" >> "$outfile"
            done
      fi
    fi

  # Apply reel filter: keep only files whose first path component is in REEL_FILTER.
  if (( ${#REEL_FILTER[@]} > 0 )); then
    local _reel_tmp
    _reel_tmp="$(mktemp /tmp/cardrunner_reelfilter.XXXXXX)"
    local _rf
    for _rf in "${REEL_FILTER[@]}"; do
      [[ -z "$_rf" ]] && continue
      awk -v r="${_rf}/" 'substr($0,1,length(r))==r' "$outfile" >> "$_reel_tmp" || true
    done
    mv "$_reel_tmp" "$outfile"
  fi
}

# Build list of PHOTO files for current card (optionally today-only, optionally with XML)
_build_media_file_list_photo() {
  local src="$1"
  local outfile="$2"

  : > "$outfile"

  if [[ -n "$DATES_LIST" ]]; then
    # Multi-date picker: iterate each selected date, append matching files.
    # Log per-date file count so the log can confirm every date's contribution.
    local _d
    local _dates_arr=("${(@s:,:)DATES_LIST}")
    for _d in "${_dates_arr[@]}"; do
      # Skip empty tokens produced by a trailing comma (e.g. "20260515,")
      # to prevent make_date_ref from defaulting to today's date.
      [[ -z "$_d" ]] && continue
      _validate_date "$_d" || { log_line "DATE_FILES: date=$_d mode=photo skipped=invalid_format"; continue; }
      local _before _after _date_count
      _before=$(wc -l < "$outfile" | tr -d ' ')
      _append_files_for_date "$_d" "$src" "$outfile" "photo"
      _after=$(wc -l < "$outfile" | tr -d ' ')
      _date_count=$(( _after - _before ))
      log_line "DATE_FILES: date=$_d mode=photo files=$_date_count"
    done
  elif [[ -n "$DATE_FROM" ]]; then
      local ref ref_to upper_pred
      ref="$(mktemp /tmp/cardrunner_midnight.XXXXXX)"
      make_date_ref "$DATE_FROM" "$ref"

      # Optional upper bound (range mode)
      if [[ -n "$DATE_TO" ]]; then
        ref_to="$(mktemp /tmp/cardrunner_midnight_to.XXXXXX)"
        make_date_ref_next_day "$DATE_TO" "$ref_to"
        upper_pred="-not -newer $ref_to"
      else
        ref_to=""; upper_pred=""
      fi

      if [[ "$COPY_XML" == "yes" ]]; then
        find "$src" -type f -newer "$ref" ${upper_pred} \
          ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
          \( \
            -iname '*.jpg'  -o -iname '*.jpeg' -o \
            -iname '*.png'  -o -iname '*.tif'   -o -iname '*.tiff' -o \
            -iname '*.heic' -o -iname '*.heif'  -o \
            -iname '*.dng'  -o -iname '*.cr2'   -o -iname '*.cr3'  -o \
            -iname '*.nef'  -o -iname '*.arw'   -o -iname '*.raf'  -o \
            -iname '*.rw2'  -o -iname '*.orf'   -o -iname '*.sr2'  -o \
            -iname '*.xml'  -o -iname '*.xmp' \
          \) \
          | while IFS= read -r f; do
              echo "${f#$src/}" >> "$outfile"
            done
      else
        find "$src" -type f -newer "$ref" ${upper_pred} \
          ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
          \( \
            -iname '*.jpg'  -o -iname '*.jpeg' -o \
            -iname '*.png'  -o -iname '*.tif'   -o -iname '*.tiff' -o \
            -iname '*.heic' -o -iname '*.heif'  -o \
            -iname '*.dng'  -o -iname '*.cr2'   -o -iname '*.cr3'  -o \
            -iname '*.nef'  -o -iname '*.arw'   -o -iname '*.raf'  -o \
            -iname '*.rw2'  -o -iname '*.orf'   -o -iname '*.sr2'  -o \
            -iname '*.xmp' \
          \) \
          | while IFS= read -r f; do
              echo "${f#$src/}" >> "$outfile"
            done
      fi

      rm -f "$ref" "$ref_to"
    else
      if [[ "$COPY_XML" == "yes" ]]; then
        find "$src" -type f \
          ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
          \( \
            -iname '*.jpg'  -o -iname '*.jpeg' -o \
            -iname '*.png'  -o -iname '*.tif'   -o -iname '*.tiff' -o \
            -iname '*.heic' -o -iname '*.heif'  -o \
            -iname '*.dng'  -o -iname '*.cr2'   -o -iname '*.cr3'  -o \
            -iname '*.nef'  -o -iname '*.arw'   -o -iname '*.raf'  -o \
            -iname '*.rw2'  -o -iname '*.orf'   -o -iname '*.sr2'  -o \
            -iname '*.xml'  -o -iname '*.xmp' \
          \) \
          | while IFS= read -r f; do
              echo "${f#$src/}" >> "$outfile"
            done
      else
        find "$src" -type f \
          ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
        ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
          \( \
            -iname '*.jpg'  -o -iname '*.jpeg' -o \
            -iname '*.png'  -o -iname '*.tif'   -o -iname '*.tiff' -o \
            -iname '*.heic' -o -iname '*.heif'  -o \
            -iname '*.dng'  -o -iname '*.cr2'   -o -iname '*.cr3'  -o \
            -iname '*.nef'  -o -iname '*.arw'   -o -iname '*.raf'  -o \
            -iname '*.rw2'  -o -iname '*.orf'   -o -iname '*.sr2'  -o \
            -iname '*.xmp' \
          \) \
          | while IFS= read -r f; do
              echo "${f#$src/}" >> "$outfile"
            done
      fi
    fi

  # Apply reel filter: keep only files whose first path component is in REEL_FILTER.
  if (( ${#REEL_FILTER[@]} > 0 )); then
    local _reel_tmp
    _reel_tmp="$(mktemp /tmp/cardrunner_reelfilter.XXXXXX)"
    local _rf
    for _rf in "${REEL_FILTER[@]}"; do
      [[ -z "$_rf" ]] && continue
      awk -v r="${_rf}/" 'substr($0,1,length(r))==r' "$outfile" >> "$_reel_tmp" || true
    done
    mv "$_reel_tmp" "$outfile"
  fi
}

# Wrapper: choose video or photo list based on MODE
build_media_file_list() {
  local src="$1"
  local outfile="$2"

  case "$MODE" in
    photo)
      _build_media_file_list_photo "$src" "$outfile"
      ;;
    *)
      # default: video
      _build_media_file_list_video "$src" "$outfile"
      ;;
  esac
}

# -----------------------------------------------------------
# Single-pass card scanner (perf: replaces multi-find + stat batch)
# -----------------------------------------------------------
# Walks the card with ONE `find` traversal and classifies + stats every file
# in ONE python3 pass.  This replaces the former 2–6 separate full-card scans
# (base list build + wrong-mode count + date-filter accounting re-scan(s) +
# one find PER selected date for the multi-date picker) AND the separate
# python stat batch.
#
# Writes matched files (mode-matched AND date-passed, reel-filtered) to $2 as:
#     relpath \t size \t mtime          (one record per line)
# Prints ONE summary line to stdout (consumed by run_ingest):
#     matched=<n> wrong_mode=<n> date_excluded=<n> bytes_total=<n>
#
# Parity with the legacy find logic:
#   - exclusion paths: THMBNL, .Spotlight-V100, .Trashes, .fseventsd
#   - date filter uses RAW mtime (broadcast-day shift is applied later, in
#     resolve_dest_dir_for_file routing — NOT in the inclusion filter)
#   - lower date bound is strict (mtime > local midnight), upper bound is the
#     whole day (mtime <= midnight of the following day) — matches `find -newer`
#   - proxies are NOT filtered here (the new-list loop still handles that)
#   - reel filter (first path component) restricts the matched set, exactly as
#     the legacy reel-filter grep did
#
# NOTE: uses one canonical photo extension set for every date mode.  The legacy
# code drifted — the multi-date picker matched Phase One/Hasselblad/Pentax RAW
# (3fr/fff/iiq/mos/rwl/mrw/nrw/pef/srw/dcr/kdc) that the single-date and "all"
# paths silently dropped.  Unifying fixes that latent data-loss inconsistency.
scan_card_files() {
  local src="$1" outfile="$2"
  : > "$outfile"

  # Reel filter → CSV for the python pass
  local _reels_csv="" _r
  if (( ${#REEL_FILTER[@]} > 0 )); then
    for _r in "${REEL_FILTER[@]}"; do
      [[ -z "$_r" ]] && continue
      _reels_csv+="${_r},"
    done
  fi

  # ── ONE traversal: write all file paths (NUL-delimited) to a temp file ──
  # NUL-delimiting handles spaces AND the rare newline-in-filename case safely.
  local _paths
  _paths="$(mktemp /tmp/cardrunner_scanpaths.XXXXXX)"
  find "$src" -type f \
    ! -path '*/PRIVATE/THMBNL/*' ! -path '*/THMBNL/*' \
    ! -path '*/.Spotlight-V100/*' ! -path '*/.Trashes/*' ! -path '*/.fseventsd/*' \
    -print0 > "$_paths" 2>/dev/null

  # ── ONE python pass: classify by extension, date-filter on mtime, stat ──
  # Script comes from the heredoc (stdin); paths are read from the file arg, so
  # stdin is free for the script.  Config is passed via CR_* environment vars.
  CR_SRC="$src" CR_MODE="$MODE" CR_COPY_XML="$COPY_XML" \
  CR_DATE_FROM="$DATE_FROM" CR_DATE_TO="$DATE_TO" CR_DATES_LIST="$DATES_LIST" \
  CR_REELS="$_reels_csv" CR_BCAST_HOUR="$BROADCAST_DAY_HOUR" \
  python3 - "$outfile" "$_paths" 2>/dev/null << 'PYEOF'
import sys, os, time, datetime

outfile    = sys.argv[1]
paths_file = sys.argv[2]

src        = os.environ.get("CR_SRC", "")
mode       = os.environ.get("CR_MODE", "video")
copy_xml   = os.environ.get("CR_COPY_XML", "no") == "yes"
date_from  = os.environ.get("CR_DATE_FROM", "").strip()
date_to    = os.environ.get("CR_DATE_TO", "").strip()
dates_list = [d for d in os.environ.get("CR_DATES_LIST", "").split(",") if d.strip()]
reels      = [r for r in os.environ.get("CR_REELS", "").split(",") if r]
try:
    bcast_hour = int(os.environ.get("CR_BCAST_HOUR", "0") or "0")
except ValueError:
    bcast_hour = 0

VIDEO = {"mp4","mov","mxf","crm","r3d","braw","ari","arx","mts","m2ts","avi","mkv",
         "dng","cdng","raw","mpg","mpeg","ts","m2v","insv","360","lrv","cine","mp"}
PHOTO = {"jpg","jpeg","png","tif","tiff","heic","heif","dng","cr2","cr3","nef","arw",
         "raf","rw2","orf","sr2","3fr","fff","iiq","mos","rwl","mrw","nrw","pef",
         "srw","dcr","kdc"}

if mode == "photo":
    mode_set, opp_set = set(PHOTO), set(VIDEO)
    if copy_xml:
        mode_set |= {"xml", "xmp"}
else:
    mode_set, opp_set = set(VIDEO), set(PHOTO)
    if copy_xml:
        mode_set |= {"xml"}

def midnight(ymd):
    return int(time.mktime(datetime.datetime(int(ymd[0:4]), int(ymd[4:6]), int(ymd[6:8])).timetuple()))

def next_midnight(ymd):
    d = datetime.date(int(ymd[0:4]), int(ymd[4:6]), int(ymd[6:8])) + datetime.timedelta(days=1)
    return int(time.mktime(d.timetuple()))

# Build the set of allowed [lo, hi) windows. Lower bound strict, upper inclusive
# of the whole day — identical to `find -newer ref ! -newer ref_next`.
windows = []
if dates_list:
    for d in dates_list:
        try:
            windows.append((midnight(d), next_midnight(d)))
        except Exception:
            pass
elif date_from:
    try:
        lo = midnight(date_from)
        hi = next_midnight(date_to) if date_to else None
        windows.append((lo, hi))
    except Exception:
        pass

# Broadcast-day shift — MUST match the routing logic in run_ingest (a clip whose
# local hour is before BROADCAST_DAY_HOUR belongs to the previous broadcast day).
# Without applying it here too, a date-filtered scan would EXCLUDE post-midnight
# clips of the selected broadcast day that routing would have filed under that day
# — i.e. silently drop footage. Apply the same shift before the window test.
def broadcast_shift(mt):
    if bcast_hour > 0 and datetime.datetime.fromtimestamp(mt).hour < bcast_hour:
        return mt - 86400
    return mt

def date_pass(mt):
    if not windows:
        return True
    mt = broadcast_shift(mt)
    for lo, hi in windows:
        if mt > lo and (hi is None or mt <= hi):
            return True
    return False

src_prefix = src + "/"
matched = wrong = dateexcl = 0
bytes_total = 0

try:
    with open(paths_file, "rb") as pf:
        data = pf.read()
except Exception:
    data = b""

with open(outfile, "w") as out:
    for pb in data.split(b"\0"):
        if not pb:
            continue
        path = os.fsdecode(pb)
        rel = path[len(src_prefix):] if path.startswith(src_prefix) else path
        base = rel.rsplit("/", 1)[-1]
        ext = base.rsplit(".", 1)[-1].lower() if "." in base else ""
        if ext in mode_set:
            # Reel filter restricts the matched set (and thus date_excluded),
            # matching the legacy reel-filter grep applied to the file list.
            if reels and rel.split("/", 1)[0] not in reels:
                continue
            try:
                st = os.stat(path)
            except OSError:
                continue
            mt = int(st.st_mtime)
            if date_pass(mt):
                out.write("%s\t%d\t%d\n" % (rel, st.st_size, mt))
                matched += 1
                bytes_total += st.st_size
            else:
                dateexcl += 1
        elif ext in opp_set:
            wrong += 1

sys.stdout.write("matched=%d wrong_mode=%d date_excluded=%d bytes_total=%d\n"
                 % (matched, wrong, dateexcl, bytes_total))
PYEOF
  local _rc=$?
  rm -f "$_paths"
  return $_rc
}

count_list() {
  local list="$1"
  # Use awk to avoid BSD grep \s incompatibility
  awk 'NF > 0' "$list" 2>/dev/null | wc -l | tr -d ' ' || echo 0
}

# -----------------------------------------------------------
# Olympics day cache and per-file destination helpers
# -----------------------------------------------------------
# Create companion folders in the project root (project scaffold feature).
# Called once per ingest after PROJECT_ROOT is set; also called when a new
# project folder is created from the UI.  Skipped in dry-run mode.
ensure_project_scaffold() {
  local project_root="$1"
  [[ -z "$SCAFFOLD_FOLDERS" || -z "$project_root" ]] && return
  [[ "$DRY_RUN" == "yes" ]] && return
  local _sfolder _sfolders _created=0
  IFS='|' read -ra _sfolders <<< "$SCAFFOLD_FOLDERS"
  for _sfolder in "${_sfolders[@]}"; do
    # strip leading/trailing whitespace
    _sfolder="${_sfolder#"${_sfolder%%[![:space:]]*}"}"
    _sfolder="${_sfolder%"${_sfolder##*[![:space:]]}"}"
    # Reject path-escape names: a scaffold folder must be a single component that stays
    # inside project_root. Anything containing '/' or '.'/'..' could mkdir outside the
    # project (e.g. "../../X" → a folder on another part of the drive).
    if [[ "$_sfolder" == */* || "$_sfolder" == "." || "$_sfolder" == ".." ]]; then
      log_line "SCAFFOLD SKIPPED: rejected unsafe folder name '$_sfolder'"
      continue
    fi
    if [[ -n "$_sfolder" && ! -d "${project_root}/${_sfolder}" ]]; then
      mkdir -p "${project_root}/${_sfolder}"
      (( _created++ ))
    fi
  done
  # Only log when folders were actually new — avoids "created" spam on every
  # ingest for a project whose scaffold already exists.
  (( _created > 0 )) && log_line "SCAFFOLD: created ${_created} folder(s) in $(basename "$project_root")"
}

ensure_olympics_day_scaffold() {
  local day_root="$1"
  mkdir -p "$day_root/Photo"
  mkdir -p "$day_root/Video"
  mkdir -p "$day_root/Mobile"
  mkdir -p "$day_root/Exports"
  mkdir -p "$day_root/Digital Assets"
  mkdir -p "$day_root/Project Files"
}

init_olympics_day_cache() {
  local project_root="$1"
  local code="$2"

  # Reset cache
  OLY_DAY_CACHE=()
  OLY_MAX_DAY=0

  # Scan all existing day folders like "26.02.03 - TUWE - Day 6"
  while IFS= read -r d; do
    local base date_part day_num existing existing_day
    base="$(basename "$d")"

    # Enforce "<dd.mm.yy> - CODE - Day N" pattern
    case "$base" in
      ??\.??\.??\ -\ ${code}\ -\ Day\ *)
        ;;
      *)
        continue
        ;;
    esac

    date_part="${base%% - ${code} - Day *}"
    day_num=$(echo "$base" | sed -E 's/.* - '"$code"' - Day ([0-9]+)/\1/')

    [[ -z "$date_part" || -z "$day_num" ]] && continue

    # Per-date mapping: keep the *smallest* day number we find
    # so that all media for that date keeps going into the same day folder.
    existing="${OLY_DAY_CACHE[$date_part]}"
    if [[ -z "$existing" ]]; then
      OLY_DAY_CACHE["$date_part"]="$base"
    else
      existing_day=$(echo "$existing" | sed -E 's/.* - '"$code"' - Day ([0-9]+)/\1/')
      if (( day_num < existing_day )); then
        OLY_DAY_CACHE["$date_part"]="$base"
      fi
    fi

    # Track global max day index for creating new days later
    if (( day_num > OLY_MAX_DAY )); then
      OLY_MAX_DAY=$day_num
    fi
  done < <(find "$project_root" -maxdepth 1 -type d -name "* - ${code} - Day *" 2>/dev/null)
}

get_olympics_day_folder_for_date() {
  local date_dots="$1"      # e.g. "26.02.03"
  local project_root="$2"
  local code="$3"

  # 1) If we already know which folder to use for this date, just reuse it.
  if [[ -n "${OLY_DAY_CACHE[$date_dots]}" ]]; then
    echo "${OLY_DAY_CACHE[$date_dots]}"
    return 0
  fi

  # 2) Try to find an existing day folder for this date on disk
  local existing base day_num
  existing=$(find "$project_root" -maxdepth 1 -type d \
               -name "${date_dots} - ${code} - Day *" 2>/dev/null \
             | sort | head -n 1)

  if [[ -n "$existing" ]]; then
    base="$(basename "$existing")"
    day_num=$(echo "$base" | sed -E 's/.* - '"$code"' - Day ([0-9]+)/\1/')

    # Keep global max in sync so that *new* dates get the next day index
    if [[ -n "$day_num" && "$day_num" -gt "$OLY_MAX_DAY" ]]; then
      OLY_MAX_DAY=$day_num
    fi

    OLY_DAY_CACHE["$date_dots"]="$base"
    echo "$base"
    return 0
  fi

  # 3) No folder yet for this date → atomically allocate the next Day N.
  # Two-card simultaneous ingest race: both processes read OLY_MAX_DAY=6,
  # both try to create Day 7.  Fix: grab a per-project lock file (noclobber
  # is atomic on local filesystems), then re-scan OLY_MAX_DAY from disk while
  # holding the lock so the second process sees the folder the first just made.
  local _oly_lock="${project_root}/.cardrunner_oly.lock"
  local _li=0
  until ( set -C; echo "$$" > "$_oly_lock" ) 2>/dev/null; do
    sleep 0.2
    (( ++_li >= 25 )) && break   # give up after ~5 s; stale-lock guard below
  done
  # Stale-lock recovery: steal lock if the locking PID is no longer alive
  if (( _li >= 25 )); then
    local _stale_pid
    _stale_pid="$(cat "$_oly_lock" 2>/dev/null || echo 0)"
    if ! kill -0 "$_stale_pid" 2>/dev/null; then
      ( set -C; echo "$$" > "$_oly_lock" ) 2>/dev/null || true
    fi
  fi
  # Re-scan from disk while holding lock (state may have changed while we waited)
  local _locked_max=0
  local _oly_scan_tmp
  _oly_scan_tmp="$(mktemp /tmp/cardrunner_oly_scan.XXXXXX)"
  find "$project_root" -maxdepth 1 -type d -name "* - ${code} - Day *" 2>/dev/null > "$_oly_scan_tmp"
  while IFS= read -r _ld; do
    local _dn
    _dn=$(basename "$_ld" | sed -E 's/.* - '"$code"' - Day ([0-9]+)$/\1/')
    [[ "$_dn" =~ ^[0-9]+$ ]] && (( _dn > _locked_max )) && _locked_max=$_dn
  done < "$_oly_scan_tmp"
  rm -f "$_oly_scan_tmp"
  (( _locked_max++ ))
  OLY_MAX_DAY=$_locked_max
  local folder_name="${date_dots} - ${code} - Day ${OLY_MAX_DAY}"
  # Create the folder while holding the lock so no other process can grab the same number
  mkdir -p "${project_root}/${folder_name}" 2>/dev/null || true
  rm -f "$_oly_lock"
  OLY_DAY_CACHE["$date_dots"]="$folder_name"
  echo "$folder_name"
}

# -----------------------------------------------------------
# Olympics per-day ingest manifest helpers
# -----------------------------------------------------------

get_olympics_day_root_for_file() {
  # Given a *source file path* on the card, return the Olympics day root
  # folder, e.g. /Volumes/Gallo 8TB/26.02.18 - TUWE - Day 8
  local src_file="$1"

  local epoch file_date_dots
  epoch=$(stat -f %m "$src_file" 2>/dev/null || date +%s)

  if (( BROADCAST_DAY_HOUR > 0 )); then
    local file_hour
    file_hour=$(date -r "$epoch" +%-H 2>/dev/null || echo 12)
    if (( file_hour < BROADCAST_DAY_HOUR )); then
      epoch=$(( epoch - 86400 ))
    fi
  fi

  file_date_dots=$(date -r "$epoch" +%y.%m.%d 2>/dev/null || date +%y.%m.%d)

  local day_folder_name day_root
  day_folder_name="$(get_olympics_day_folder_for_date "$file_date_dots" "$PROJECT_ROOT" "$PROJECT_CODE")"
  day_root="${PROJECT_ROOT}/${day_folder_name}"
  echo "$day_root"
}

is_already_ingested_olympics() {
  # Returns 0 (true) if this rel path+size combo has already been ingested today
  # in Winter Olympics mode; 1 (false) otherwise.
  local src="$1"   # card root
  local rel="$2"   # path relative to src

  local src_file="$src/$rel"
  [[ ! -f "$src_file" ]] && return 1

  local size day_root manifest key
  size=$(stat -f %z "$src_file" 2>/dev/null || echo 0)
  day_root="$(get_olympics_day_root_for_file "$src_file")"
  manifest="${day_root}/.cardrunner_ingest_db"

  [[ ! -f "$manifest" ]] && return 1

  key="${rel}|${size}"
  if grep -Fxq "$key" "$manifest" 2>/dev/null; then
    return 0   # already ingested
  else
    return 1
  fi
}

record_ingested_olympics() {
  # Append this file's rel path+size to the per-day Olympics manifest
  local src="$1"
  local rel="$2"

  local src_file="$src/$rel"
  [[ ! -f "$src_file" ]] && return

  local size day_root manifest key
  size=$(stat -f %z "$src_file" 2>/dev/null || echo 0)
  day_root="$(get_olympics_day_root_for_file "$src_file")"
  manifest="${day_root}/.cardrunner_ingest_db"

  key="${rel}|${size}"
  echo "$key" >> "$manifest"
}

# -----------------------------------------------------------
# Global per-card ingest manifest helpers
# -----------------------------------------------------------
# Each card gets one manifest file named by its volume UUID (or card-name
# fallback) stored at ~/Library/Application Support/CardRunner/manifests/.
# Format: one entry per line — "basename|filesize|timestamp|dest_path"
#
# Before copying a file we check if basename+filesize already appears in
# the manifest (meaning it was ingested on a previous run, possibly to a
# different project folder).  After a successful copy group we append
# all newly copied files so future runs skip them.
# -----------------------------------------------------------

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # Control characters are rare but legal in macOS filenames (e.g. pasted from
  # another OS, or a card with odd metadata) — escape per JSON spec so a stray
  # newline/tab doesn't corrupt the manifest structure.
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  printf '%s' "$s"
}

_get_card_uuid() {
  # Try diskutil first (most reliable — persists across mounts).
  local uuid
  uuid=$(diskutil info "$CARD_PATH" 2>/dev/null \
         | awk '/Volume UUID/ { print $NF }')
  if [[ -n "$uuid" && "$uuid" != "N/A" ]]; then
    echo "$uuid"
    return
  fi
  # Fallback: sanitised card volume name
  echo "${CARD_PATH##*/}" | tr -cd 'A-Za-z0-9_-'
}

init_card_manifest() {
  mkdir -p "$GLOBAL_MANIFEST_DIR" 2>/dev/null || true
  local card_id safe_id
  card_id="$(_get_card_uuid)"
  safe_id="${card_id//[^A-Za-z0-9_-]/_}"
  CARD_MANIFEST="${GLOBAL_MANIFEST_DIR}/${safe_id}.tsv"
  touch "$CARD_MANIFEST" 2>/dev/null || true
  _prune_card_manifest "$CARD_MANIFEST"
}

# Prune old/excess entries from a manifest file so grep stays fast.
# Keeps entries from the last 90 days, hard-caps at 10,000 lines.
# (2,000 was too low for a DIT doing 300+ files/day — fills in ~6 days.)
_prune_card_manifest() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 0

  local line_count
  line_count=$(wc -l < "$manifest" 2>/dev/null || echo 0)

  # Nothing to do if small and all entries are recent
  (( line_count <= 100 )) && return 0

  # Cutoff: 90 days ago in ISO format (YYYY-MM-DDTHH:MM:SS)
  local cutoff
  cutoff=$(date -v-90d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
        || date -d '90 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
        || echo "1970-01-01T00:00:00")

  local tmp
  tmp="$(mktemp /tmp/cardrunner_manifest_prune.XXXXXX)"

  # Keep lines where the timestamp field (4th field, |-delimited) >= cutoff
  awk -F'|' -v cutoff="$cutoff" '
    NF >= 4 && $4 >= cutoff { print }
    NF < 4                  { print }   # malformed lines: keep to be safe
  ' "$manifest" > "$tmp"

  # Hard cap: if still over 10,000 lines, keep the most recent 10,000
  local pruned_count
  pruned_count=$(wc -l < "$tmp" 2>/dev/null || echo 0)
  if (( pruned_count > 10000 )); then
    tail -10000 "$tmp" > "${tmp}.cap" && mv "${tmp}.cap" "$tmp"
  fi

  # Atomic replace
  mv "$tmp" "$manifest" 2>/dev/null || rm -f "$tmp"
}

is_already_ingested_global() {
  # Returns 0 (true) if this exact file (rel path + size + mtime) from this
  # card was previously ingested. Using all three prevents false matches between
  # different cameras that happen to produce same-named, same-size files.
  [[ -z "$CARD_MANIFEST" || ! -f "$CARD_MANIFEST" ]] && return 1
  local src_root="$1" rel="$2"
  local src_file="$src_root/$rel"
  [[ ! -f "$src_file" ]] && return 1
  local size mtime
  size=$(stat -f %z "$src_file" 2>/dev/null || echo 0)
  mtime=$(stat -f %m "$src_file" 2>/dev/null || echo 0)
  # Key: rel path (no pipes) + size + mtime — unique across any camera
  grep -qF "${rel}|${size}|${mtime}|" "$CARD_MANIFEST" 2>/dev/null
}

record_ingested_global() {
  # Append newly copied files to the card manifest. Only called after a
  # confirmed successful copy — never on failure.
  # $1 = src root, $2 = .rels file listing relative paths, $3 = dest dir
  #
  # Performance: loads the manifest into an associative array ONCE, then does
  # O(1) in-memory lookups instead of one grep-per-file (which was O(n×m) and
  # caused the 99% hang on cards with large manifests).
  [[ -z "$CARD_MANIFEST" || "$DRY_RUN" == "yes" ]] && return
  local src="$1" rels_file="$2" dest_dir="$3"
  local ts
  ts=$(date +%Y-%m-%dT%H:%M:%S)

  # Use the manifest key set pre-loaded once before the group loop.
  # _MANIFEST_LOADED_KEYS is a typeset -g array owned by run_ingest.

  # Batch-fetch size+mtime via python3 (F6: was perl, which fails silently on
  # some machines due to Time::HiRes / locale / sandbox issues). Uses temp files
  # instead of process substitution — process substitution silently produces 0
  # bytes when launched via NSTask on macOS 26.4.1.
  typeset -A _rec_size _rec_mtime
  local _ri_stat_in _ri_stat_out
  _ri_stat_in="$(mktemp /tmp/cardrunner_ri_in.XXXXXX)"
  _ri_stat_out="$(mktemp /tmp/cardrunner_ri_out.XXXXXX)"
  while IFS= read -r -d '' _rp; do
    [[ -n "$_rp" ]] && printf '%s/%s\n' "$src" "$_rp"
  done < "$rels_file" > "$_ri_stat_in"
  python3 - "$_ri_stat_in" "$_ri_stat_out" << 'PYEOF' 2>/dev/null
import sys, os
with open(sys.argv[1]) as inf, open(sys.argv[2], 'w') as outf:
    for line in inf:
        path = line.rstrip('\n')
        if not path:
            continue
        try:
            s = os.stat(path)
            outf.write(f"{path}|{s.st_size}|{int(s.st_mtime)}\n")
        except Exception:
            pass
PYEOF
  if [[ -s "$_ri_stat_out" ]]; then
    while IFS='|' read -r abs_path fsize fmtime; do
      [[ -z "$abs_path" ]] && continue
      local _rel="${abs_path#${src}/}"
      _rec_size[$_rel]="$fsize"
      _rec_mtime[$_rel]="$fmtime"
    done < "$_ri_stat_out"
  fi
  rm -f "$_ri_stat_in" "$_ri_stat_out"

  # Collect all new entries, then write in a single append (no per-file I/O)
  local _new_entries=""
  while IFS= read -r -d '' rel; do
    [[ -z "$rel" ]] && continue
    local src_file="$src/$rel"
    [[ ! -f "$src_file" ]] && continue
    local size="${_rec_size[$rel]:-0}"
    local mtime="${_rec_mtime[$rel]:-0}"
    # Fallback to stat if Perl fetch somehow missed this file
    if [[ "$size" == "0" && "$mtime" == "0" ]]; then
      size=$(stat -f %z "$src_file" 2>/dev/null || echo 0)
      mtime=$(stat -f %m "$src_file" 2>/dev/null || echo 0)
    fi
    local key="${rel}|${size}|${mtime}|"
    # NOTE: the subscript MUST be quoted. In zsh an unquoted associative
    # subscript containing '|' never matches a key set with a quoted subscript,
    # so an unquoted lookup here silently returns "absent" and the dedup fails.
    if [[ -z "${_MANIFEST_LOADED_KEYS["$key"]+x}" ]]; then
      _MANIFEST_LOADED_KEYS["$key"]=1   # prevent duplicates within this batch
      _new_entries+="${key}${ts}|${dest_dir}"$'\n'
    fi
  done < "$rels_file"

  # Single write for the entire batch
  [[ -n "$_new_entries" ]] && printf '%s' "$_new_entries" >> "$CARD_MANIFEST"
}

# Idempotent path segment append.
# If $cur already ends with /$seg, return it unchanged.
# This prevents double-segments when the user re-picks a folder that is
# already a CardRunner date or label folder (e.g. /Footage/Sunday/260517
# picked as custom dest → would produce /260517/260517 without this guard).
append_seg() {
  local cur="${1%/}" seg="$2"
  [[ "$cur" == *"/$seg" ]] && { echo "$cur"; return; }
  echo "$cur/$seg"
}

resolve_dest_dir_for_file() {
  local rel="$1"
  local src="$2"

  local src_file="$src/$rel"
  local epoch file_date_ymd file_date_dots

  if [[ -n "$DATE_OVERRIDE" ]]; then
    # Wrong-clock camera: use the real ingest date (passed by Swift) for all folders.
    # DATE_OVERRIDE is YYYYMMDD; convert to the configured DATE_FORMAT (default %y%m%d).
    file_date_ymd=$(date -j -f "%Y%m%d" "$DATE_OVERRIDE" +"$DATE_FORMAT" 2>/dev/null \
                    || echo "${DATE_OVERRIDE:2}")   # strip YYYY prefix as fallback → YYMMDD
    file_date_dots=$(date -j -f "%Y%m%d" "$DATE_OVERRIDE" +%y.%m.%d 2>/dev/null \
                    || echo "${DATE_OVERRIDE:2:2}.${DATE_OVERRIDE:4:2}.${DATE_OVERRIDE:6:2}")
  else
    epoch=$(stat -f %m "$src_file" 2>/dev/null || date +%s)

    # Broadcast-day routing: if the clip was shot before the configured cutoff hour
    # (e.g. 12:45am with a 4am cutoff), treat it as belonging to the previous calendar
    # day so a game that runs past midnight stays in one folder.
    if (( BROADCAST_DAY_HOUR > 0 )); then
      local file_hour
      file_hour=$(date -r "$epoch" +%-H 2>/dev/null || echo 12)
      if (( file_hour < BROADCAST_DAY_HOUR )); then
        epoch=$(( epoch - 86400 ))
      fi
    fi

    file_date_ymd=$(date -r "$epoch" +"$DATE_FORMAT" 2>/dev/null || date +"$DATE_FORMAT")
    file_date_dots=$(date -r "$epoch" +%y.%m.%d 2>/dev/null || date +%y.%m.%d)
  fi

  if [[ "$WINTER_OLYMPICS_MODE" == "yes" ]]; then
    local day_root lane_dir lane_root base_folder

    # Use the shared helper so Olympics day mapping stays consistent
    day_root="$(get_olympics_day_root_for_file "$src_file")"
    ensure_olympics_day_scaffold "$day_root"

    lane_dir="Video"
    if [[ "$MODE" == "photo" ]]; then
      lane_dir="Photo"
    fi

    lane_root="${day_root}/${lane_dir}"
    base_folder="$lane_root"
    if [[ -n "$DEST_FRIENDLY" ]]; then
      base_folder="${lane_root}/${DEST_FRIENDLY}"
    fi
    mkdir -p "$base_folder"
    echo "$base_folder"
  else
    local base_folder
    base_folder="$(append_seg "$STANDARD_SUBROOT" "$file_date_ymd")"
    # Reel-multi mode: inject the reel name (first path component) as a subfolder
    # so multiple reels from a wrong-clock camera land in separate subdirs.
    if [[ "$REEL_MULTI" == "yes" ]]; then
      local reel_seg="${rel%%/*}"
      [[ -n "$reel_seg" ]] && base_folder="$(append_seg "$base_folder" "$reel_seg")"
    fi
    if [[ -n "$DEST_FRIENDLY" ]]; then
      base_folder="$(append_seg "$base_folder" "$DEST_FRIENDLY")"
    fi
    mkdir -p "$base_folder"
    echo "$base_folder"
  fi
}

# -----------------------------------------------------------
# Transfer verification (MD5 spot-check or full)
# -----------------------------------------------------------
# Spot-check mode: samples a size-scaled random subset of files.
# Full mode (FULL_VERIFY=yes): checksums every file in new_list.
# Both modes emit VERIFY_PROGRESS current=N total=N after each file (N/total
#   scoped to the sampled set in spot-check mode) so the GUI can animate.
# Both modes emit VERIFY_PASS or VERIFY_FAIL as a final summary line.
verify_transfer() {
  local src="$1"       # card root (e.g. /Volumes/Untitled)
  local list="$2"      # new_list file (relative paths)
  local checked=0 passed=0 failed=0 recovered=0 quarantined=0

  # Build the list of files to verify
  local files=()
  if [[ "$FULL_VERIFY" == "yes" ]]; then
    # Full mode: read every non-empty line
    while IFS= read -r rel; do
      [[ -z "${rel//[[:space:]]/}" ]] && continue
      files+=("$rel")
    done < "$list"
  else
    # Spot-check mode: sample a size-scaled random subset.
    # Target = max(20, ceil(10% of total candidates)), capped at 200 so huge
    # cards don't spend forever checksumming.  On a 2000-file card this lifts
    # coverage from <1% (fixed 10) to 10%.
    local _total_candidates _sample_target
    _total_candidates=$(awk 'NF>0' "$list" 2>/dev/null | wc -l | tr -d ' ')
    (( _sample_target = (_total_candidates + 9) / 10 ))   # ceil(10%)
    (( _sample_target < 20 ))  && _sample_target=20
    (( _sample_target > 200 )) && _sample_target=200
    while IFS= read -r rel; do
      [[ -z "${rel//[[:space:]]/}" ]] && continue
      files+=("$rel")
      (( ${#files[@]} >= _sample_target )) && break
    done < <(sort -R "$list" 2>/dev/null || cat "$list")
    log_line "spot-check: verifying ${#files[@]} of ${_total_candidates} files"
  fi

  local total=${#files[@]}

  for rel in "${files[@]}"; do
    local src_file="${src}/${rel}"
    [[ ! -f "$src_file" ]] && continue

    # Locate the copied file at its destination (account for rename-on-ingest)
    local dest_dir dest_file base_name
    dest_dir="$(resolve_dest_dir_for_file "$rel" "$src")"
    # Use renamed filename if one was recorded, else fall back to original
    base_name="${_rename_map[$rel]:-${rel##*/}}"
    dest_file="${dest_dir}/${base_name}"

    [[ ! -f "$dest_file" ]] && continue

    local src_md5 dst_md5
    src_md5=$(md5 -q "$src_file"  2>/dev/null)
    dst_md5=$(md5 -q "$dest_file" 2>/dev/null)

    (( checked++ ))
    if [[ "$src_md5" == "$dst_md5" && -n "$src_md5" ]]; then
      (( passed++ ))
    else
      # File-scoped recovery: the checksum mismatched, so attempt to re-copy this
      # single file from source to its known destination path and re-verify it.
      # A recovered file counts as a pass; only a still-mismatched (or failed)
      # re-copy is a true, eject-blocking failure (quarantine).
      log_line "VERIFY MISMATCH: $rel — src=$src_md5 dst=$dst_md5 — attempting single-file recovery"
      if cp -f "$src_file" "$dest_file" 2>/dev/null; then
        local re_dst_md5
        re_dst_md5=$(md5 -q "$dest_file" 2>/dev/null)
        if [[ "$src_md5" == "$re_dst_md5" && -n "$src_md5" ]]; then
          (( recovered++ ))
          echo "VERIFY_RECOVERED file=${base_name}"
          log_line "VERIFY RECOVERED: $rel — re-copied and now matches src=$src_md5"
        else
          (( failed++ ))
          (( quarantined++ ))
          echo "VERIFY_QUARANTINE file=${base_name}"
          log_line "VERIFY QUARANTINE: $rel — still mismatched after re-copy src=$src_md5 dst=$re_dst_md5"
        fi
      else
        (( failed++ ))
        (( quarantined++ ))
        echo "VERIFY_QUARANTINE file=${base_name}"
        log_line "VERIFY QUARANTINE: $rel — re-copy failed src=$src_md5"
      fi
    fi

    # Emit progress so the GUI can animate (spot-check and full mode alike)
    echo "VERIFY_PROGRESS current=${checked} total=${total}"
  done

  if (( checked == 0 )); then
    echo "VERIFY_SKIP reason=no_files_sampled"
  elif (( quarantined == 0 )); then
    # Zero unrecoverable failures — every mismatch (if any) was recovered.
    # This still PASSES so auto-eject is allowed.
    echo "VERIFY_PASS checked=$checked recovered=$recovered"
  else
    # At least one quarantined (unrecoverable) file — this FAILS and blocks eject.
    echo "VERIFY_FAIL checked=$checked failed=$quarantined recovered=$recovered"
  fi
}

# -----------------------------------------------------------
# Rename on ingest
# -----------------------------------------------------------
# Applies RENAME_TEMPLATE to each file in a destination group after copy.
# Supported tokens: {cardname} {original}
# Populates _rename_map[$rel]=new_basename so verify_transfer can find files.
apply_rename_group() {
  local dest_dir="$1"
  local rels_file="$2"
  local label="$3"   # CARDLABEL or cardname fallback

  # Safety check: if the template has no {original} token, every file in the
  # group would produce the same output name — the second mv silently overwrites
  # the first, destroying data.  Abort the rename for this group with a clear
  # error rather than silently clobbering files.
  local _file_count
  _file_count=$(awk 'NF>0' "$rels_file" 2>/dev/null | wc -l | tr -d ' ')
  if (( _file_count > 1 )) && [[ "$RENAME_TEMPLATE" != *"{original}"* ]]; then
    log_line "RENAME ABORTED: template '$RENAME_TEMPLATE' has no {original} token — applying it to $_file_count files would overwrite all but the last. Add {original} to make filenames unique."
    echo "RENAME_ERROR reason=no_original_token files=$_file_count template=$RENAME_TEMPLATE"
    return 1
  fi

  while IFS= read -r -d '' rel; do
    [[ -z "$rel" ]] && continue
    # If cardcopy collision-renamed this file, start from the renamed basename;
    # otherwise use the original basename from the card path.
    local base="${_rename_map[$rel]:-${rel##*/}}"
    local ext stem
    if [[ "$base" == *.* ]]; then
      ext="${base##*.}"
      stem="${base%.*}"
    else
      ext=""
      stem="$base"
    fi

    local src_file="${dest_dir}/${base}"
    [[ ! -f "$src_file" ]] && continue

    # Normalize template tokens to lowercase so {CardName}/{CARDNAME}/{Original} etc. all work
    local _tpl_norm
    _tpl_norm="$(echo "$RENAME_TEMPLATE" | tr '[:upper:]' '[:lower:]')"
    local new_name="$_tpl_norm"
    new_name="${new_name//\{cardname\}/$label}"
    new_name="${new_name//\{original\}/$stem}"

    # Always preserve original extension
    [[ -n "$ext" ]] && new_name="${new_name}.${ext}"

    # Guard: if the resolved name is still identical after substitution (e.g.
    # unrecognised token left as a literal), skip rather than mv to same path.
    if [[ "$new_name" != "$base" && -n "$new_name" ]]; then
      # Check for collision with an already-renamed file in this group
      if [[ -f "${dest_dir}/${new_name}" && "${dest_dir}/${new_name}" != "${dest_dir}/${base}" ]]; then
        log_line "RENAME SKIP: $new_name already exists in $dest_dir — keeping original name $base"
        continue
      fi
      local _mv_exit=0
      mv "$src_file" "${dest_dir}/${new_name}" 2>/dev/null || _mv_exit=$?
      if (( _mv_exit == 0 )); then
        _rename_map[$rel]="$new_name"
      else
        log_line "RENAME FAIL: $base → $new_name in $dest_dir (exit $_mv_exit) — original filename kept"
      fi
    fi
  done < "$rels_file"
}

# -----------------------------------------------------------
# Transfer Report (CSV)
# -----------------------------------------------------------
# Writes a CSV of every transferred file to {PROJECT_ROOT}/TransferReports/.
# Columns: filename, size_bytes, source_path, destination_path, copied_at
# Emits: TRANSFER_REPORT path=/absolute/path/to/report.csv
generate_transfer_report() {
  local src="$1"    # card media root
  local list="$2"   # new_list (relative paths of transferred files)
  local label="$3"  # cardname or CARDLABEL

  local report_dir="${PROJECT_ROOT}/TransferReports"
  mkdir -p "$report_dir" || return 1

  local timestamp
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  local report_file="${report_dir}/${timestamp}_${label}_report.csv"

  # Header
  printf 'filename,size_bytes,source_path,destination_path,copied_at\n' > "$report_file"

  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue

    local src_file="${src}/${rel}"
    [[ ! -f "$src_file" ]] && continue

    local dest_dir
    dest_dir="${_dest_dir_cache[$rel]:-$(resolve_dest_dir_for_file "$rel" "$src")}"

    # Account for files renamed during ingest
    local dest_basename="${_rename_map[$rel]:-${rel##*/}}"
    local dest_file="${dest_dir}/${dest_basename}"

    # Prefer size of the destination copy; fall back to source
    local size_bytes
    size_bytes="$(stat -f %z "$dest_file" 2>/dev/null || stat -f %z "$src_file" 2>/dev/null || echo 0)"

    # CSV-safe quoting: double any internal double-quotes
    printf '"%s",%s,"%s","%s","%s"\n' \
      "${dest_basename//\"/\"\"}" \
      "$size_bytes" \
      "${src_file//\"/\"\"}" \
      "${dest_file//\"/\"\"}" \
      "$now" >> "$report_file"
  done < "$list"

  echo "TRANSFER_REPORT path=$report_file"
}

# -----------------------------------------------------------
# Ingest Operation
# Validate YYYYMMDD format: 8 digits, month 01-12, day 01-31.
# Lightweight — does not verify day-in-month (e.g. Feb 31), just catches
# obvious malformed values like month=13 that would silently break touch -t.
_validate_date() {
  local d="$1"
  [[ "$d" =~ ^[0-9]{8}$ ]]          || return 1
  local mm="${d:4:2}" dd="${d:6:2}"
  (( 10#$mm >= 1 && 10#$mm <= 12 )) || return 1
  (( 10#$dd >= 1 && 10#$dd <= 31 )) || return 1
  return 0
}

# -----------------------------------------------------------

run_ingest() {
  local src dest friendly datecode
  local list_all new_list group_dir
  # Cache macOS version once — called from two separate log paths below
  local macos_ver
  macos_ver="$(sw_vers -productVersion 2>/dev/null || echo unknown)"

  # --dest-root bypasses PRIMARY_ROOT/PROJECT_NAME — validate accordingly
  if [[ -n "$DEST_ROOT" ]]; then
    if [[ -z "$CARD_PATH" ]]; then
      echo "❌ Missing required parameter: --card"
      return 1
    fi
  else
    if [[ -z "$CARD_PATH" || -z "$PRIMARY_ROOT" || -z "$PROJECT_NAME" ]]; then
      echo "❌ Missing required parameters (card, primary, project)."
      return 1
    fi
  fi

  if [[ ! -d "$CARD_PATH" ]]; then
    echo "❌ Card path not found: $CARD_PATH"
    return 1
  fi
  if [[ -n "$DEST_ROOT" ]]; then
    if [[ ! -d "$DEST_ROOT" ]]; then
      log_line "DEST MISSING: Custom destination not found or unmounted — $DEST_ROOT"
      echo "❌ Custom destination path not found: $DEST_ROOT"
      return 1
    fi
  elif [[ ! -d "$PRIMARY_ROOT" ]]; then
    log_line "DEST MISSING: Primary SSD not found or unmounted — $PRIMARY_ROOT"
    echo "❌ Primary SSD path not found: $PRIMARY_ROOT"
    return 1
  fi

  # Validate date format and range
  if [[ -n "$DATE_FROM" ]] && ! _validate_date "$DATE_FROM"; then
    echo "❌ Invalid --date-from: '$DATE_FROM' — must be YYYYMMDD (e.g. 20261225, month 01-12, day 01-31)"
    return 1
  fi
  if [[ -n "$DATE_TO" ]] && ! _validate_date "$DATE_TO"; then
    echo "❌ Invalid --date-to: '$DATE_TO' — must be YYYYMMDD (e.g. 20261225, month 01-12, day 01-31)"
    return 1
  fi
  if [[ -n "$DATE_FROM" && -n "$DATE_TO" && "$DATE_FROM" > "$DATE_TO" ]]; then
    echo "❌ Invalid date range: --date-from ($DATE_FROM) is after --date-to ($DATE_TO)"
    return 1
  fi

  echo "PHASE scanning"
  phase_start scanning
  src="$(detect_src_dir "$CARD_PATH")"
  if [[ -z "$src" ]]; then
    echo "❌ No media folder detected on: $CARD_PATH"
    echo "PROGRESS_META media_total=0"
    echo "PROGRESS_META bytes_total=0"
    echo "PROGRESS_META new_files=0"
    echo "PROGRESS_META bytes_new=0"
    return 1
  fi

  # Initialise the global per-card manifest so we can skip files that were
  # already ingested to any previous destination on any previous run.
  init_card_manifest

  # Register cleanup trap BEFORE any mktemp calls so temp files are removed even
  # if the script dies mid-function.  Single-quoted so variables expand at signal
  # time (not registration time) — handles whichever vars have been set so far.
  trap 'rm -f "${list_all:-}" "${new_list:-}"; [[ -n "${group_dir:-}" ]] && rm -rf "$group_dir"' EXIT INT TERM HUP

  local cardname dest_project_root
  cardname="$(basename "$CARD_PATH")"

  # Determine the friendly subfolder name (if any)
  # - If CARDLABEL is provided (custom card name toggle ON), use that.
  # - Else if we are in Winter Olympics mode, fall back to camera-based name.
  # - Else (normal mode with custom card name OFF), do NOT create a per-card subfolder.
  if [[ -n "$CARDLABEL" ]]; then
    friendly="$CARDLABEL"
  elif [[ "$WINTER_OLYMPICS_MODE" == "yes" ]]; then
    friendly="$(friendly_name "$cardname")"
  else
    friendly=""
  fi

  datecode="$(date +"$DATE_FORMAT")"  # still available if needed elsewhere

  DEST_FRIENDLY="$friendly"
  # Custom folder mode: use DEST_ROOT directly; otherwise build from SSD + project name
  if [[ -n "$DEST_ROOT" ]]; then
    PROJECT_ROOT="$DEST_ROOT"
  else
    PROJECT_ROOT="${PRIMARY_ROOT}/${PROJECT_NAME}"
  fi

  local open_dest

  if [[ "$WINTER_OLYMPICS_MODE" == "yes" ]]; then
    local project_root project_code
    project_root="$PROJECT_ROOT"
    mkdir -p "$project_root"
    ensure_project_scaffold "$project_root"

    if [[ -n "$OLYMPICS_CODE" ]]; then
      project_code="$OLYMPICS_CODE"
    else
      project_code="$PROJECT_NAME"
      if [[ "$PROJECT_NAME" == *"TUWE"* ]]; then
        project_code="TUWE"
      fi
    fi
    PROJECT_CODE="$project_code"

    init_olympics_day_cache "$project_root" "$project_code"
    open_dest="$project_root"
  else
    if [[ -n "$DEST_ROOT" ]]; then
      # Custom folder mode — footage goes directly into DEST_ROOT/DATE/
      # No clips/footage subfolder is ever created; only the date folder.
      STANDARD_SUBROOT="$PROJECT_ROOT"
      mkdir -p "$STANDARD_SUBROOT"
    else
      local sub
      sub="$SUBFOLDER"
      [[ -z "$sub" ]] && sub="clips"

      STANDARD_SUBROOT="${PROJECT_ROOT}/${sub}"
      mkdir -p "$STANDARD_SUBROOT"
      ensure_project_scaffold "$PROJECT_ROOT"
    fi
    open_dest="$STANDARD_SUBROOT"
  fi

  phase_end scanning

  # Log destination free space before the transfer so we can rule out "ran out
  # of room" problems after the fact, even if the disk was reformatted/swapped.
  local _dest_check_path="${DEST_ROOT:-${PRIMARY_ROOT}}"
  local _dest_free_gb
  _dest_free_gb=$(df -g "$_dest_check_path" 2>/dev/null | awk 'NR==2{print $4}' || echo "?")
  # Derive the real volume name via diskutil so the log always shows the mount
  # name ("MySSD"), not a deep subfolder ("sunday" / "Qualifying Week").
  local _vol_name
  _vol_name=$(diskutil info "$_dest_check_path" 2>/dev/null \
    | sed -n 's/^[[:space:]]*Volume Name:[[:space:]]*//p' | head -1 | xargs 2>/dev/null)
  [[ -z "$_vol_name" ]] && _vol_name="$(basename "$_dest_check_path")"
  log_line "DEST_SPACE: ${_dest_free_gb} GB free on ${_vol_name}"
  echo "DEST_FREE gb=${_dest_free_gb}"

  echo "PHASE building"
  phase_start building

  # Log the active date filter so every run is self-documenting in the log.
  # This is the primary audit trail for "which dates were selected and why".
  if [[ -n "$DATES_LIST" ]]; then
    local _n_dates=${#${(@s:,:)DATES_LIST}}
    log_line "DATE_FILTER: mode=multi-date dates=$DATES_LIST (${_n_dates} date(s) selected)"
  elif [[ "$TODAY_ONLY" == "yes" ]]; then
    log_line "DATE_FILTER: mode=today date=$DATE_FROM"
  elif [[ -n "$DATE_FROM" && -n "$DATE_TO" ]]; then
    log_line "DATE_FILTER: mode=range from=$DATE_FROM to=$DATE_TO"
  elif [[ -n "$DATE_FROM" ]]; then
    log_line "DATE_FILTER: mode=from date=$DATE_FROM"
  else
    log_line "DATE_FILTER: mode=all (no date restriction)"
  fi

  # Build the media file list + per-file metadata in a SINGLE card traversal.
  # One `find` walk piped into one python3 pass (scan_card_files) replaces the
  # former 2–6 separate full-card scans (base list + wrong-mode count +
  # date-filter accounting re-scans / per-date finds) and the separate stat
  # batch.  The legacy multi-find path is retained below as a safety fallback
  # that runs ONLY if the single-pass scanner fails to emit its summary line.
  list_all="$(mktemp /tmp/cardrunner_all.XXXXXX)"

  local media_count bytes_total
  local skip_wrong_mode=0 skip_today_filter=0 skip_dest_exists=0 skip_manifest=0
  # skip_proxy:   proxy/sub clips excluded because proxy copying is off (was silently
  #               dropped before — left found ≠ new + skipped in the stats).
  # skip_missing: files that were matched by the scan but no longer exist at copy time
  #               (card pulled / file deleted between scan and build). A footage-safety
  #               app must surface these loudly, not drop them without a trace.
  local skip_proxy=0 skip_missing=0

  # Caches consumed by the new-list / copy loops further down.
  typeset -A _mkdir_cache
  typeset -A _file_size _file_mtime _date_code_cache

  local _scan_meta _scan_counts
  _scan_meta="$(mktemp /tmp/cardrunner_scanmeta.XXXXXX)"
  _scan_counts="$(scan_card_files "$src" "$_scan_meta")"

  if [[ "$_scan_counts" == *matched=* ]]; then
    # ── Fast path: single-pass scan succeeded ───────────────────────────────
    media_count="${${_scan_counts##*matched=}%% *}"
    skip_wrong_mode="${${_scan_counts##*wrong_mode=}%% *}"
    skip_today_filter="${${_scan_counts##*date_excluded=}%% *}"
    bytes_total="${${_scan_counts##*bytes_total=}%% *}"
    : > "$list_all"
    while IFS=$'\t' read -r _mrel _msz _mmt; do
      [[ -z "$_mrel" ]] && continue
      _file_size[$_mrel]="$_msz"
      _file_mtime[$_mrel]="$_mmt"
      printf '%s\n' "$_mrel" >> "$list_all"
    done < "$_scan_meta"
    rm -f "$_scan_meta"
    log_line "SCAN: single-pass — matched=$media_count wrong_mode=$skip_wrong_mode date_excluded=$skip_today_filter bytes_total=$bytes_total"
  else
    # ── Fallback: legacy multi-find scan (proven path; runs only if the
    #    single-pass scanner errored out — python missing, sandbox, etc.).
    #    Diagnostic skip counts (wrong_mode / today_filter) are left at 0 here;
    #    correctness of the ingest itself is unaffected. ──────────────────────
    rm -f "$_scan_meta"
    log_line "SCAN_FALLBACK: single-pass scanner produced no summary — using legacy find scan"
    build_media_file_list "$src" "$list_all"
    media_count="$(count_list "$list_all")"

    if (( media_count > 0 )); then
      local _stat_in _stat_out
      _stat_in="$(mktemp /tmp/cardrunner_statin.XXXXXX)"
      _stat_out="$(mktemp /tmp/cardrunner_statout.XXXXXX)"
      awk -v src="$src" 'NF>0{print src"/"$0}' "$list_all" > "$_stat_in"
      python3 - "$_stat_in" "$_stat_out" << 'PYEOF' 2>/dev/null
import sys, os
in_file, out_file = sys.argv[1], sys.argv[2]
with open(in_file) as inf, open(out_file, 'w') as outf:
    for line in inf:
        path = line.rstrip('\n')
        if not path:
            continue
        try:
            s = os.stat(path)
            outf.write(f"{path}|{s.st_size}|{int(s.st_mtime)}\n")
        except Exception:
            pass
PYEOF
      if [[ -s "$_stat_out" ]]; then
        while IFS='|' read -r abs_path fsize fmtime; do
          [[ -z "$abs_path" ]] && continue
          local _rel="${abs_path#${src}/}"
          _file_size[$_rel]="$fsize"
          _file_mtime[$_rel]="$fmtime"
        done < "$_stat_out"
      fi
      rm -f "$_stat_in" "$_stat_out"
    fi

    bytes_total=0
    for _sz in ${(v)_file_size}; do (( bytes_total += _sz )); done
  fi

  # ── Fallback: if Perl stat pass produced no sizes, use direct stat calls ──
  # This handles cases where the perl pipe silently fails (exFAT volumes,
  # sandbox restrictions, or process-substitution edge cases when launched
  # from a GUI app).  Direct stat is slightly slower but guaranteed correct.
  if (( bytes_total == 0 && media_count > 0 )); then
    log_line "STAT_FALLBACK: python3 stat pass returned 0 bytes — using direct stat"
    bytes_total=0
    while IFS= read -r _fb_rel; do
      [[ -z "$_fb_rel" ]] && continue
      local _fb_size _fb_mtime
      _fb_size=$(stat -f %z "$src/$_fb_rel" 2>/dev/null || echo 0)
      _fb_mtime=$(stat -f %m "$src/$_fb_rel" 2>/dev/null || echo 0)
      _file_size[$_fb_rel]="$_fb_size"
      _file_mtime[$_fb_rel]="$_fb_mtime"
      (( bytes_total += _fb_size ))
    done < "$list_all"
    log_line "STAT_FALLBACK: computed bytes_total=${bytes_total}"
  fi

  # ── Pre-load manifest into associative array ─────────────────────────────
  # Replaces per-file grep on CARD_MANIFEST (N grep subprocesses → 0).
  typeset -A _manifest_cache
  if [[ -f "$CARD_MANIFEST" ]]; then
    while IFS='|' read -r mrel msz mmt _mrest; do
      [[ -n "$mrel" && -n "$msz" && -n "$mmt" ]] \
        && _manifest_cache["${mrel}|${msz}|${mmt}|"]=1
    done < "$CARD_MANIFEST"
  fi

  # Determine NEW files by comparing source list to destination contents
  new_list="$(mktemp /tmp/cardrunner_new.XXXXXX)"
  # Cache dest-dir results so the copy loop below reuses them without re-computing.
  typeset -A _dest_dir_cache
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local src_file="$src/$rel"
    # A file the scan matched but that has vanished by copy time. Don't drop it
    # silently — count it and log a WARN so a pulled-card / deleted-file situation
    # is visible in the log instead of looking like "everything copied".
    if [[ ! -f "$src_file" ]]; then
      (( skip_missing++ ))
      log_line "WARN SOURCE MISSING: matched at scan but gone at copy time: $rel"
      continue
    fi

    # Skip proxy files unless the user enabled proxy copying. Counted (not silent)
    # so found = new + skipped balances and the operator can see why the card's
    # total file count is higher than the number copied.
    if [[ "$INCLUDE_PROXIES" != "yes" ]] && is_proxy_file "$rel"; then
      (( skip_proxy++ ))
      continue
    fi

    # In Winter Olympics mode, first check the per-day ingest manifest.
    if [[ "$WINTER_OLYMPICS_MODE" == "yes" ]]; then
      if is_already_ingested_olympics "$src" "$rel"; then
        continue
      fi
    fi

    local dest_dir base_name dest_file

    if [[ "$WINTER_OLYMPICS_MODE" == "yes" ]]; then
      # Olympics: keep using the full function (complex day-routing logic).
      dest_dir="$(resolve_dest_dir_for_file "$rel" "$src")"
    else
      # Standard mode: resolve destination in-shell using pre-fetched mtime.
      # Avoids 1 stat + 2 date subprocesses per file.
      local _epoch="${_file_mtime[$rel]:-}"

      # XMP sidecar: borrow the paired photo's mtime so the sidecar lands
      # in the same date folder as its source image (e.g. DSCF1234.xmp →
      # same folder as DSCF1234.RAF).  Without this, the xmp's own mtime
      # might differ by seconds and route it to a different date bucket.
      if [[ "${rel:l}" == *.xmp ]]; then
        local _xmp_dir="${rel:h}"
        [[ "$_xmp_dir" == "." ]] && _xmp_dir=""
        local _xmp_stem="${${rel:t}%.*}"
        local _paired_epoch="" _try_ext
        for _try_ext in raf cr2 cr3 nef arw dng rw2 orf sr2 heic heif jpg jpeg png tif tiff \
                         RAF CR2 CR3 NEF ARW DNG RW2 ORF SR2 HEIC HEIF JPG JPEG PNG TIF TIFF; do
          local _try_rel="${_xmp_dir:+${_xmp_dir}/}${_xmp_stem}.${_try_ext}"
          if [[ -n "${_file_mtime[$_try_rel]:-}" ]]; then
            _paired_epoch="${_file_mtime[$_try_rel]}"
            break
          fi
        done
        [[ -n "$_paired_epoch" ]] && _epoch="$_paired_epoch"
      fi

      [[ -z "$_epoch" ]] && _epoch=$(stat -f %m "$src_file" 2>/dev/null || date +%s)

      # Broadcast-day shift (only active when BROADCAST_DAY_HOUR > 0)
      if (( BROADCAST_DAY_HOUR > 0 )); then
        local _fh
        _fh=$(date -r "$_epoch" +%-H 2>/dev/null || echo 12)
        (( _fh < BROADCAST_DAY_HOUR )) && _epoch=$(( _epoch - 86400 ))
      fi

      # Cache date strings by epoch — same-day files reuse one date call
      if [[ -z "${_date_code_cache[$_epoch]+x}" ]]; then
        _date_code_cache[$_epoch]="$(date -r "$_epoch" +"$DATE_FORMAT" 2>/dev/null || date +"$DATE_FORMAT")"
      fi
      local _fdate="${_date_code_cache[$_epoch]}"
      dest_dir="${STANDARD_SUBROOT}/${_fdate}"
      [[ -n "$DEST_FRIENDLY" ]] && dest_dir="${dest_dir}/${DEST_FRIENDLY}"
      # Only mkdir once per unique path — avoids one subprocess fork per file.
      if [[ -z "${_mkdir_cache[$dest_dir]+x}" ]]; then
        mkdir -p "$dest_dir"
        _mkdir_cache[$dest_dir]=1
      fi
    fi

    _dest_dir_cache[$rel]="$dest_dir"
    base_name="${rel##*/}"

    # Proxy files land in a Proxies/ subfolder — check that path for dedup.
    if is_proxy_file "$rel"; then
      dest_file="${dest_dir}/Proxies/${base_name}"
    else
      dest_file="${dest_dir}/${base_name}"
    fi

    # Dest-exists skip must compare SIZE, not just existence.  A truncated or
    # partial file already sitting at the destination (e.g. from an interrupted
    # earlier copy) would otherwise be masked forever.  Only treat the dest as a
    # valid duplicate when it exists AND its size matches the source; a size
    # mismatch means re-copy so the good source overwrites the bad dest.
    local _dest_dup=no
    if [[ -f "$dest_file" ]]; then
      local _src_sz="${_file_size[$rel]:-}" _dst_sz
      [[ -z "$_src_sz" || "$_src_sz" == "0" ]] && _src_sz=$(stat -f %z "$src_file" 2>/dev/null || echo 0)
      _dst_sz=$(stat -f %z "$dest_file" 2>/dev/null || echo -1)
      [[ "$_dst_sz" == "$_src_sz" ]] && _dest_dup=yes
    fi

    if [[ "$_dest_dup" != "yes" ]]; then
      # In-memory manifest lookup — replaces per-file grep + 2×stat.
      local _sz="${_file_size[$rel]:-0}" _mt="${_file_mtime[$rel]:-0}"
      # Subscript MUST be quoted — an unquoted '|'-containing key never matches
      # in zsh (keys are set with a quoted subscript), which would silently
      # disable manifest-based skipping and re-copy already-ingested files.
      # --ignore-manifest re-copies everything: skip the manifest check entirely so a card
      # that was already offloaded can be deliberately re-ingested (e.g. to a second drive).
      # The dest-exists check below still prevents copying ON TOP of an existing file.
      if [[ "$IGNORE_MANIFEST" != "yes" ]] && [[ "$WINTER_OLYMPICS_MODE" != "yes" ]] && \
         [[ -n "${_manifest_cache["${rel}|${_sz}|${_mt}|"]+x}" ]]; then
        (( skip_manifest++ ))
        continue
      elif [[ "$IGNORE_MANIFEST" != "yes" ]] && [[ "$WINTER_OLYMPICS_MODE" == "yes" ]]; then
        if is_already_ingested_global "$src" "$rel"; then
          (( skip_manifest++ ))
          continue
        fi
      fi
      echo "$rel" >> "$new_list"
    else
      (( skip_dest_exists++ ))
    fi
  done < "$list_all"

  # Emit skip summary
  (( skip_manifest   > 0 )) && log_line "MANIFEST SKIPS: $skip_manifest file(s) already ingested from this card"
  (( skip_dest_exists > 0 )) && log_line "DEST SKIPS: $skip_dest_exists file(s) already present at destination"
  (( skip_today_filter > 0 )) && log_line "DATE SKIPS: $skip_today_filter file(s) filtered by date"
  (( skip_wrong_mode  > 0 )) && log_line "MODE SKIPS: $skip_wrong_mode file(s) wrong type for mode=$MODE"
  (( skip_proxy       > 0 )) && log_line "PROXY SKIPS: $skip_proxy proxy/sub file(s) — proxy copying disabled"
  (( skip_missing     > 0 )) && log_line "MISSING SOURCES: $skip_missing file(s) matched at scan but missing at copy time — NOT copied"

  local new_count bytes_new
  new_count="$(count_list "$new_list")"

  # Compute bytes_new from pre-fetched sizes — no extra stat calls
  bytes_new=0
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    (( bytes_new += ${_file_size[$rel]:-0} ))
  done < "$new_list"

  # BUILD_STATS: single log line capturing everything needed to diagnose a slow
  # build on any future card size.  Shows file counts, skip breakdown, and how
  # long the build phase (scan + metadata fetch + new-list loop) actually took.
  phase_end building
  local _build_elapsed=$(( $(date +%s) - _PHASE_START_T ))
  local _unique_dirs=${#_mkdir_cache}
  log_line "BUILD_STATS: found=$media_count new=$new_count skipped=$(( skip_manifest + skip_dest_exists + skip_today_filter + skip_wrong_mode + skip_proxy + skip_missing )) dest_dirs=$_unique_dirs bytes_total=$bytes_total bytes_new=$bytes_new"

  echo "PROGRESS_META media_total=$media_count"
  echo "PROGRESS_META bytes_total=$bytes_total"
  echo "PROGRESS_META new_files=$new_count"
  echo "PROGRESS_META bytes_new=$bytes_new"
  echo "SKIP_SUMMARY manifest=$skip_manifest dest_exists=$skip_dest_exists today_filter=$skip_today_filter wrong_mode=$skip_wrong_mode proxy=$skip_proxy missing=$skip_missing"

  # ── Pre-flight free-space check (E1) ────────────────────────────────────────
  # Compare bytes_new against current destination free space BEFORE moving any bytes.
  # A mid-transfer DEST_FULL is handled correctly (partial dirs + manifest keep data
  # safe), but this gives the operator an instant "won't fit" refusal instead of a
  # minutes-long transfer that fails halfway. Dry-run and zero-byte cases skip it.
  if [[ "$DRY_RUN" != "yes" && new_count -gt 0 && bytes_new -gt 0 ]]; then
    local _pre_free_kb _pre_need_kb
    _pre_free_kb=$(df -k "${DEST_ROOT:-$PRIMARY_ROOT}" 2>/dev/null | awk 'NR==2{print $4}')
    _pre_need_kb=$(( (bytes_new / 1024) * 110 / 100 ))   # +10% headroom for metadata/overhead
    if [[ -n "$_pre_free_kb" && "$_pre_free_kb" -gt 0 ]] && (( _pre_need_kb > _pre_free_kb )); then
      local _pre_need_gb=$(( (_pre_need_kb + 1048575) / 1048576 ))
      local _pre_free_gb_val=$(( (_pre_free_kb + 1048575) / 1048576 ))
      log_line "ABORT: pre-flight space check — need ~${_pre_need_gb} GB, only ${_pre_free_gb_val} GB free"
      echo "DEST_INSUFFICIENT need_kb=$_pre_need_kb free_kb=$_pre_free_kb"
      rm -f "$list_all" "$new_list"
      return 1
    fi
  fi

  echo "PHASE copying"

  # -------------------------------------------------------
  # Real copy pass: FLATTEN into per-file destination dirs
  # -------------------------------------------------------
  log_line "Transfer starting: $new_count files"

  if (( new_count == 0 )); then
    # No files to copy — skip phase_start/phase_end entirely so the log
    # never shows an asymmetric or empty-timestamp PHASE_START copying.
    echo "PROGRESS_SUMMARY avg_mb=0 duration_sec=0 new_files=0"
    echo "PROGRESS_DEST $open_dest"
    rm -f "$list_all" "$new_list"
    local _now _tid
    _now="$(date '+%Y-%m-%d %H:%M:%S')"
    _tid="${$}_$(date +%s)"
    local _log_cardname="${cardname//|/-}" _log_friendly="${friendly//|/-}" _log_project="${PROJECT_NAME//|/-}"
    log_line "$_now | ID=$_tid | Version=$CARDRUNNER_VERSION | macOS=$macos_ver | Status=NoNewFiles | Mode=$MODE | Card=$_log_cardname | Friendly=$_log_friendly | Project=$_log_project | Subfolder=$SUBFOLDER | MediaTotal=$media_count | NewFiles=0 | NewMB=0 | DurationSec=0 | AvgMBps=0 | TodayOnly=$TODAY_ONLY | Dest=$open_dest | CopySec=0 | VerifySec=0 | EjectSec=0 | SourceProtocol=unknown | SourceLink=unknown | DestProtocol=unknown | DestLink=unknown | DestMedia=unknown"
    return 0
  fi

  # ── Sort the ingest queue by capture timestamp ─────────────────────────────
  # "oldest" (default): ascending mtime — earliest files first.
  # "newest": descending mtime — latest clips dispatched first so an editor can
  #   start cutting new material immediately while older footage continues copying.
  # Uses _file_mtime[] pre-fetched in the build phase so no extra stat calls are needed.
  if (( new_count > 1 )); then
    local _sort_in _sort_tmp
    _sort_in="$(mktemp /tmp/cardrunner_sort_in.XXXXXX)"
    _sort_tmp="$(mktemp /tmp/cardrunner_sort_out.XXXXXX)"
    while IFS= read -r _srel; do
      [[ -z "$_srel" ]] && continue
      printf '%s\t%s\n' "${_file_mtime[$_srel]:-0}" "$_srel" >> "$_sort_in"
    done < "$new_list"
    if [[ "$SORT_ORDER" == "newest" ]]; then
      sort -t$'\t' -k1,1rn "$_sort_in" | cut -f2- > "$_sort_tmp"
    else
      sort -t$'\t' -k1,1n  "$_sort_in" | cut -f2- > "$_sort_tmp"
    fi
    mv "$_sort_tmp" "$new_list"
    rm -f "$_sort_in"
    log_line "SORT_ORDER: $SORT_ORDER — $new_count files ordered by capture time"
  fi

  # ── Hardware-path diagnostics: background capture (NON-BLOCKING) ────────────
  # Negotiated link speed needs system_profiler, which is SLOW (1-3s). Kick it
  # off in the BACKGROUND right now so its cost fully overlaps the copy and can
  # NEVER delay or fail footage transfer. The tempfile is parsed at summary time
  # (bounded wait, then grep). Everything here degrades to "unknown" on failure.
  local _hw_tmp="" _hw_pid=""
  _hw_tmp="$(mktemp /tmp/cardrunner_hw.XXXXXX 2>/dev/null || true)"
  if [[ -n "$_hw_tmp" ]]; then
    { system_profiler SPUSBDataType SPThunderboltDataType 2>/dev/null > "$_hw_tmp"; } &
    _hw_pid=$!
  fi
  # Stash the SOURCE card's diskutil info NOW, before any auto-eject unmounts it —
  # querying it at summary time (post-eject) would return nothing and lose the exact
  # source (CFexpress) protocol/media we most want to diagnose. Best-effort.
  local _src_du="$(diskutil info "$CARD_PATH" 2>/dev/null || true)"

  # Files to copy — start the copy phase timer now.
  phase_start copying

  local START END DUR
  zmodload zsh/datetime 2>/dev/null
  zmodload zsh/mathfunc 2>/dev/null   # provides int() for the EPOCHREALTIME→ms math below
  START=$(( int(EPOCHREALTIME * 1000) ))

  local CARDCOPY_FLAGS=()
  # Log which cardcopy binary is in use so it's visible in every transfer log.
  local _cc_ver
  _cc_ver=$("$CARDCOPY_BIN" --version 2>/dev/null || echo "cardcopy (version unknown)")
  log_line "CARDCOPY_BIN: $CARDCOPY_BIN — $_cc_ver"

  # --ignore-existing: skip files already at destination (size+mtime match).
  # --partial-dir:     write to hidden staging folder; atomic rename on done.
  #                    Swift's cancelAllIngests() cleans these dirs on cancel.
  CARDCOPY_FLAGS+=( --ignore-existing --partial-dir=.cardrunner_partial )
  # Skip per-file SHA-256 in cardcopy unless full verify is requested.
  # Verify is opt-in; the default ingest path should not pay the ~1.3s/file cost.
  # (The separate verify_transfer pass below handles spot-check and full verify.)
  if [[ "$VERIFY" != "yes" && "$FULL_VERIFY" != "yes" ]]; then
    CARDCOPY_FLAGS+=( --no-verify )
  fi
  # Dry-run: skip the actual copy call entirely; the shell handles the no-op.

  # ── Group files by destination directory ────────────────────────────────
  # This collapses N files into one cardcopy call per unique destination folder.
  # For a single-day shoot that is almost always exactly ONE call,
  # eliminating per-process startup overhead entirely.
  local group_dir
  group_dir="$(mktemp -d /tmp/cardrunner_groups.XXXXXX)"

  local last_dest=""
  # Distinct destination CLIP folders this run writes to (Proxies/ subfolders
  # collapse into their parent). Size 1 = a single-day / single-folder offload →
  # F should open THAT folder (the .mp4s). Size >1 = multi-day → open the parent
  # that holds every date folder. Consumed at OPEN_TARGET below.
  local -A _clip_roots=()
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local src_file="$src/$rel"
    [[ ! -f "$src_file" ]] && continue

    local dest_dir
    # Use the cache populated during the new-list loop; fall back to a fresh
    # call only if somehow the key is missing (e.g. a file added mid-run).
    dest_dir="${_dest_dir_cache[$rel]:-$(resolve_dest_dir_for_file "$rel" "$src")}"

    # Proxy files go into a Proxies/ subfolder inside the normal destination.
    if is_proxy_file "$rel"; then
      dest_dir="${dest_dir}/Proxies"
      mkdir -p "$dest_dir"
    fi

    # Hash dest_dir into a collision-proof filename key.
    # Simple slash-replacement (e.g. /foo/bar → __foo__bar) has a known collision:
    # /foo__bar produces the same key, silently mixing two destinations.
    # md5 of the full path is unique for any two distinct strings.
    local key
    key="$(printf '%s' "$dest_dir" | md5)"
    printf '%s\0' "$src_file" >> "${group_dir}/${key}.srcs"
    printf '%s\0' "$rel"      >> "${group_dir}/${key}.rels"
    printf '%s'   "$dest_dir" >  "${group_dir}/${key}.dest"
    last_dest="$dest_dir"
    # Record the clip root (a Proxies/ group belongs to its parent date folder).
    _clip_roots["${dest_dir%/Proxies}"]=1
  done < "$new_list"

  # ── Load manifest once for all groups (avoids re-reading per group) ─────
  typeset -gA _MANIFEST_LOADED_KEYS=()
  if [[ -n "$CARD_MANIFEST" && -f "$CARD_MANIFEST" && "$DRY_RUN" != "yes" ]]; then
    while IFS='|' read -r _mk_rel _mk_sz _mk_mt _mk_rest; do
      [[ -n "$_mk_rel" ]] && _MANIFEST_LOADED_KEYS["${_mk_rel}|${_mk_sz}|${_mk_mt}|"]=1
    done < "$CARD_MANIFEST"
  fi

  # ── Correction manifest: generate a runID for this run and echo it to Swift
  # so ActiveIngest.runID can be recorded (used later if the operator retypes
  # the card name after copy — CorrectionLogic.swift moves files by manifest
  # instead of blind whole-folder rename). Entries accumulate below as copy
  # groups succeed; the JSON is written once after the group loop. Manifest
  # write failure is entirely non-fatal — best-effort correction aid, never
  # part of core copy safety.
  local _corr_run_id _corr_entries_file _corr_src_id
  _corr_run_id="corr-$(date +%Y%m%d%H%M%S)-$$"
  _corr_entries_file="$(mktemp /tmp/cardrunner_corr_entries.XXXXXX 2>/dev/null || true)"
  _corr_src_id="$(_get_card_uuid 2>/dev/null || echo unknown)"
  [[ "$DRY_RUN" != "yes" ]] && echo "RUN_ID ${_corr_run_id}"

  # ── One cardcopy call per destination group ─────────────────────────────
  local _failed_groups=0      # incremented if any PRIMARY copy group returns non-zero
  local _failed_secondaries=0 # N-way: incremented per MIRROR destination that fails
  local _committed_bytes=0    # F5: bytes from groups that completed successfully
  for _dest_file in "${group_dir}"/*.dest(N); do
    local _key_base="${_dest_file%.dest}"
    local _grp_dest _grp_srcs _grp_rels
    # Per-group flags: defer the manifest until the primary AND all mirrors succeed,
    # so a failed mirror leaves the files un-recorded → they retry on next insert.
    local _grp_primary_ok=0 _grp_sec_failed=0
    _grp_dest="$(cat "$_dest_file")"
    _grp_srcs="${_key_base}.srcs"
    _grp_rels="${_key_base}.rels"
    # Verify destination root still exists (could unmount between scan and copy)
    local _dest_check_root="${DEST_ROOT:-$PRIMARY_ROOT}"
    if [[ ! -d "$_dest_check_root" ]]; then
      log_line "DEST VANISHED: $_dest_check_root disappeared mid-transfer — aborting"
      echo "DEST_VANISHED path=$_dest_check_root"
      break
    fi

    # FOLDERSYNC_START emitted AFTER DEST_VANISHED check so FolderSync only
    # sees it when the destination is actually reachable and copying will proceed.
    [[ "$DRY_RUN" != "yes" ]] && log_line "FOLDERSYNC_START dest=$_grp_dest mode=$MODE"
    # Also emit to STDOUT so the app knows the EXACT date folder being written RIGHT
    # NOW — this makes F / Reveal open the active clips folder mid-transfer (the app's
    # FOLDERSYNC_START handler sets destPath). Skip Proxies/ groups so the live target
    # stays the real date folder, not its Proxies subfolder. OPEN_TARGET (at the end)
    # then settles the final single-day-folder vs multi-day-parent decision.
    [[ "$DRY_RUN" != "yes" && "$_grp_dest" != */Proxies ]] && echo "FOLDERSYNC_START dest=$_grp_dest mode=$MODE"

    mkdir -p "$_grp_dest"

    # Check BEFORE copying: if the dest folder already has media this is a
    # subsequent transfer into the same folder — tag its first file green.
    local _dest_had_media=false
    dest_has_existing_media "$_grp_dest" && _dest_had_media=true

    # Build source-path array then hand all files to a single cardcopy invocation.
    local _src_args=()
    while IFS= read -r -d '' _sf; do
      [[ -n "$_sf" ]] && _src_args+=("$_sf")
    done < "$_grp_srcs"

    if (( ${#_src_args[@]} > 0 )); then
      local _copy_exit=0
      local _copy_stderr_file
      _copy_stderr_file="$(mktemp /tmp/cardrunner_copy_err.XXXXXX)"

      if [[ "$DRY_RUN" == "yes" ]]; then
        # Dry-run: emit fake PROGRESS_FILE lines without moving any bytes.
        for _f in "${_src_args[@]}"; do
          local _sz=0
          _sz=$(stat -f%z "$_f" 2>/dev/null || echo 0)
          echo "PROGRESS_FILE size=${_sz} ${_f##*/}"
        done
      elif [[ "$_dest_had_media" == "true" ]]; then
        # ── Subsequent transfer: copy the chronologically OLDEST file first so
        # we can tag it the moment it lands — regardless of SORT_ORDER.
        # The tag marks the "batch start" at the top of the folder in Finder.
        # With Oldest-first this is _src_args[1]; with Newest-first it would
        # otherwise land on the wrong (most recent) clip. ────────────────────
        local _tag_rel="" _tag_src_file="" _oldest_mtime=9999999999
        while IFS= read -r -d '' _r; do
          [[ -z "$_r" ]] && continue
          local _mt="${_file_mtime[$_r]:-0}"
          if (( _mt < _oldest_mtime )); then
            _oldest_mtime=$_mt
            _tag_rel="$_r"
            _tag_src_file="$src/$_r"
          fi
        done < "$_grp_rels"

        # Rest = every file in the group except the tag file
        local _rest_src_files=()
        for _sf in "${_src_args[@]}"; do
          [[ "$_sf" != "$_tag_src_file" ]] && _rest_src_files+=("$_sf")
        done

        "$CARDCOPY_BIN" "${CARDCOPY_FLAGS[@]}" "$_tag_src_file" "$_grp_dest/" \
          2>"$_copy_stderr_file" || _copy_exit=$?

        if (( _copy_exit == 0 )); then
          # Tag file is fully written at its final path — apply colour immediately.
          if [[ -n "$_tag_rel" ]]; then
            local _tag_dest_file="${_grp_dest}/${_tag_rel##*/}"
            add_green_finder_tag "$_tag_dest_file"
            log_line "GREEN TAG: marked oldest file of batch (batch-start marker): $_tag_dest_file"
          fi

          # Copy the remaining files (if any) in a second cardcopy call.
          if (( ${#_rest_src_files[@]} > 0 )); then
            "$CARDCOPY_BIN" "${CARDCOPY_FLAGS[@]}" "${_rest_src_files[@]}" "$_grp_dest/" \
              2>>"$_copy_stderr_file" || _copy_exit=$?
          fi
        fi
      else
        # ── First transfer to this destination: copy everything in one call ──
        "$CARDCOPY_BIN" "${CARDCOPY_FLAGS[@]}" "${_src_args[@]}" "$_grp_dest/" \
          2>"$_copy_stderr_file" || _copy_exit=$?
      fi

      # Log any meaningful stderr (No space left, Permission denied, VERIFY_FAIL, COLLISION_RENAMED)
      if [[ -s "$_copy_stderr_file" ]]; then
        local _stderr_content
        _stderr_content="$(cat "$_copy_stderr_file")"

        # Collision renames: log each event and update _rename_map so that
        # verify_transfer and apply_rename_group find files at their actual
        # (renamed) destination paths rather than the original basename.
        # Without this, verify_transfer opens the WRONG dest file and produces
        # a false VERIFY_FAIL; apply_rename_group silently skips the file.
        if echo "$_stderr_content" | grep -q "^COLLISION_RENAMED "; then
          # Pass 1: collect ordered new-names per original basename.
          # Stored as pipe-delimited list "newname1|newname2|…" for each basename.
          typeset -A _coll_new_names=()
          while IFS= read -r _coll_line; do
            local _corig _cnew
            _corig="$(awk '{print $2}' <<< "$_coll_line")"
            _cnew="$(awk  '{print $3}' <<< "$_coll_line")"
            log_line "COLLISION_RENAMED: duplicate filename '$_corig' → saved as '$_cnew' in $_grp_dest"
            _coll_new_names[$_corig]+="${_cnew}|"
          done < <(grep "^COLLISION_RENAMED " <<< "$_stderr_content")

          # Pass 2: walk rels in copy order; occurrence 1 keeps the original name,
          # occurrences 2, 3, … consume successive new names from the list above.
          typeset -A _coll_count=() _coll_used=()
          while IFS= read -r -d '' _crel; do
            [[ -z "$_crel" ]] && continue
            local _cbn="${_crel##*/}"
            [[ -z "${_coll_new_names[$_cbn]+x}" ]] && continue
            _coll_count[$_cbn]=$(( ${_coll_count[$_cbn]:-0} + 1 ))
            if (( ${_coll_count[$_cbn]} > 1 )); then
              _coll_used[$_cbn]=$(( ${_coll_used[$_cbn]:-0} + 1 ))
              local _newname
              _newname="$(cut -d'|' -f"${_coll_used[$_cbn]}" <<< "${_coll_new_names[$_cbn]}")"
              [[ -n "$_newname" ]] && _rename_map[$_crel]="$_newname"
            fi
          done < "$_grp_rels"
        fi

        if echo "$_stderr_content" | grep -qi "no space left\|disk full\|ENOSPC"; then
          log_line "COPY ERROR: Destination full — no space left on $_grp_dest"
          echo "DEST_FULL dest=$_grp_dest"
        fi
        if echo "$_stderr_content" | grep -qi "permission denied\|operation not permitted"; then
          log_line "COPY ERROR: Permission denied writing to $_grp_dest"
          echo "PERMISSION_ERROR dest=$_grp_dest"
        fi
        if echo "$_stderr_content" | grep -q "^VERIFY_FAIL "; then
          local _failed_file
          _failed_file="$(grep '^VERIFY_FAIL ' "$_copy_stderr_file" | head -1 | awk '{print $2}')"
          log_line "VERIFY FAIL: checksum mismatch for ${_failed_file} — file may be corrupt"
          echo "VERIFY_FAIL file=${_failed_file} dest=$_grp_dest"
        fi
        if (( _copy_exit != 0 )); then
          local _first_err
          _first_err="$(grep -v '^$' "$_copy_stderr_file" | grep -v '^VERIFY_' | head -1)"
          [[ -n "$_first_err" ]] && log_line "COPY STDERR (exit $_copy_exit): $_first_err"
        fi
      fi
      rm -f "$_copy_stderr_file"

      if (( _copy_exit == 0 )); then
        last_dest="$_grp_dest"
        # Accumulate bytes that were actually written to disk (F5).
        # Using pre-fetched sizes avoids per-file stat calls here.
        while IFS= read -r -d '' _cb_rel; do
          [[ -z "$_cb_rel" ]] && continue
          (( _committed_bytes += ${_file_size[$_cb_rel]:-0} ))
        done < "$_grp_rels"
        # Primary copy confirmed. DEFER the manifest record until all mirrors for this
        # group also succeed (see after the mirror loop) — never mark files as ingested
        # if the copy failed (e.g. destination unmounted, card pulled) OR a mirror failed.
        _grp_primary_ok=1
        [[ "$DRY_RUN" != "yes" ]] && log_line "FOLDERSYNC_END dest=$_grp_dest status=ok"
      elif (( _copy_exit == 143 || _copy_exit == 130 )); then
        # Exit 143 = SIGTERM (user cancelled via CardRunner Stop button)
        # Exit 130 = SIGINT  (Ctrl-C or equivalent)
        # This is an intentional cancel — not a real error. Files will re-copy next ingest.
        (( _failed_groups++ ))
        log_line "TRANSFER CANCELLED: user stopped transfer for $_grp_dest — files will re-copy on next ingest"
        echo "TRANSFER_CANCELLED dest=$_grp_dest"
        [[ "$DRY_RUN" != "yes" ]] && log_line "FOLDERSYNC_END dest=$_grp_dest status=cancelled"
      else
        (( _failed_groups++ ))
        log_line "COPY ERROR: exit code $_copy_exit for dest $_grp_dest — manifest NOT updated, files will retry on next ingest"
        echo "COPY_ERROR dest=$_grp_dest exit=$_copy_exit"
        [[ "$DRY_RUN" != "yes" ]] && log_line "FOLDERSYNC_END dest=$_grp_dest status=error exit=$_copy_exit"
      fi
    fi

    # Rename files after copy if a template is set (skipped for dry runs).
    if [[ -n "$RENAME_TEMPLATE" && "$DRY_RUN" != "yes" ]]; then
      local _rename_label="${CARDLABEL:-$cardname}"
      apply_rename_group "$_grp_dest" "$_grp_rels" "$_rename_label"
    fi

    # Record every file this group actually copied for the correction manifest —
    # done HERE, after apply_rename_group, and reading through _rename_map, so the
    # recorded filename is the REAL on-disk name in both cases that can change it
    # after the primary copy succeeds: a cardcopy COLLISION_RENAMED (dual-slot/
    # chaptered DCIM duplicate basenames, handled earlier via stderr parsing) and
    # a RENAME_TEMPLATE substitution (apply_rename_group, just above). Without this,
    # CorrectionLogic.swift would look for the pre-rename basename on disk, find
    # nothing, and silently skip the entry instead of correcting it.
    # NOTE: this is a separate, secondary manifest from CARD_MANIFEST above — it
    # exists to let a post-copy folder rename move files by known identity instead
    # of a blind whole-folder move. It is keyed by relPath|size like CARD_MANIFEST
    # but written to a different file and must not be conflated with (or
    # substituted for) the re-ingest dedup manifest.
    if (( _grp_primary_ok == 1 )) && [[ -n "$_corr_entries_file" && "$DRY_RUN" != "yes" ]]; then
      {
        while IFS= read -r -d '' _ce_rel; do
          [[ -z "$_ce_rel" ]] && continue
          local _ce_size="${_file_size[$_ce_rel]:-0}"
          local _ce_fn="${_rename_map[$_ce_rel]:-${_ce_rel##*/}}"
          local _ce_label="${CARDLABEL:-$cardname}"
          printf '%s\t%s\t%s\t%s\t%s\n' "$_ce_rel" "$_ce_fn" "$_ce_size" "$_ce_label" "$_grp_dest"
        done < "$_grp_rels"
      } >> "$_corr_entries_file" 2>/dev/null || true
    fi

    # ── N-way mirror: copy the same source files to EACH secondary destination ──────
    # Each mirror dest is derived by prefix-swapping a SECONDARY root for PRIMARY_ROOT in
    # _grp_dest (leading prefix only, never global '//'). Custom-folder mode (DEST_ROOT
    # set) has an empty PRIMARY_ROOT, so the swap would mangle the path — mirroring is
    # skipped there as before.
    # SAFETY: a mirror that fails increments _failed_secondaries (→ non-zero exit + blocks
    # auto-eject) and sets _grp_sec_failed (→ withholds the manifest so the files retry).
    # The mirror copy reuses CARDCOPY_FLAGS, so --partial-dir atomicity AND inline verify
    # (when --verify is on) apply to each mirror just like the primary.
    if (( ${#SECONDARY_ROOTS[@]} > 0 )) && [[ "$DRY_RUN" != "yes" ]]; then
      if [[ -z "$PRIMARY_ROOT" || -n "$DEST_ROOT" ]]; then
        log_line "SECONDARY SKIPPED: mirror requires SSD mode (PRIMARY_ROOT set, DEST_ROOT empty)"
        echo "SECONDARY_ERROR reason=primary_root_empty"
        (( _failed_secondaries++ )); _grp_sec_failed=1
      elif [[ "$_grp_dest" != "$PRIMARY_ROOT" && "$_grp_dest" != "$PRIMARY_ROOT"/* ]]; then
        echo "SECONDARY_ERROR reason=path_mismatch"
        log_line "SECONDARY ERROR: dest '$_grp_dest' is not under PRIMARY_ROOT '$PRIMARY_ROOT' — skipping mirror"
        (( _failed_secondaries++ )); _grp_sec_failed=1
      else
        local _sec_root
        for _sec_root in "${SECONDARY_ROOTS[@]}"; do
          # Skip empty entries and any mirror that equals the primary (would copy onto itself).
          [[ -z "$_sec_root" || "$_sec_root" == "$PRIMARY_ROOT" ]] && continue
          if [[ ! -d "$_sec_root" ]]; then
            echo "SECONDARY_ERROR reason=not_mounted root=$_sec_root"
            log_line "SECONDARY ERROR: $_sec_root not mounted — mirror failed (card kept mounted)"
            (( _failed_secondaries++ )); _grp_sec_failed=1
            continue
          fi
          local _sec_dest="${_sec_root}${_grp_dest#$PRIMARY_ROOT}"
          mkdir -p "$_sec_dest"
          if (( ${#_src_args[@]} > 0 )); then
            local _sec_exit=0
            "$CARDCOPY_BIN" "${CARDCOPY_FLAGS[@]}" "${_src_args[@]}" "$_sec_dest/" || _sec_exit=$?
            if (( _sec_exit == 0 )); then
              echo "SECONDARY_PROGRESS dest=$_sec_dest"
              [[ -n "$RENAME_TEMPLATE" ]] && apply_rename_group "$_sec_dest" "$_grp_rels" "${CARDLABEL:-$cardname}"
            else
              log_line "SECONDARY COPY ERROR: exit code $_sec_exit for dest $_sec_dest"
              echo "SECONDARY_ERROR reason=copy_failed exit=$_sec_exit root=$_sec_root"
              (( _failed_secondaries++ )); _grp_sec_failed=1
            fi
          fi
        done
      fi
    fi

    # Manifest gate: record the per-card "ingested" entry ONLY when the primary AND every
    # mirror for this group succeeded. A failed mirror withholds the record so the files
    # re-copy (to all dests) on the next insert rather than being marked done.
    if [[ "$DRY_RUN" != "yes" ]] && (( _grp_primary_ok == 1 && _grp_sec_failed == 0 )); then
      record_ingested_global "$src" "$_grp_rels" "$_grp_dest"
    fi

    # Olympics per-file manifest recording (real copies only).
    if [[ "$WINTER_OLYMPICS_MODE" == "yes" && "$DRY_RUN" != "yes" ]]; then
      while IFS= read -r _rel; do
        record_ingested_olympics "$src" "$_rel"
      done < "$_grp_rels"
    fi
  done

  # ── Write correction manifest (best-effort, non-fatal) ──────────────────
  # Stored under the DESTINATION ROOT (not under {date}/{label}/) so it
  # survives a later rename of the label folder — that folder is exactly
  # what a correction move may relocate. Schema mirrors CorrectionManifest
  # in CorrectionLogic.swift; keep the two in lockstep if this changes.
  if [[ "$DRY_RUN" != "yes" && -n "$_corr_entries_file" && -s "$_corr_entries_file" ]]; then
    (
      local _corr_root="${DEST_ROOT:-$PRIMARY_ROOT}"
      if [[ -n "$_corr_root" ]]; then
        local _corr_dir="${_corr_root}/.cardrunner/manifests"
        mkdir -p "$_corr_dir" 2>/dev/null
        local _corr_file="${_corr_dir}/${_corr_run_id}.json"
        local _corr_ts
        _corr_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        {
          printf '{\n'
          printf '  "runID": "%s",\n' "$(_json_escape "$_corr_run_id")"
          printf '  "destPath": "%s",\n' "$(_json_escape "$last_dest")"
          printf '  "timestamp": "%s",\n' "$_corr_ts"
          printf '  "sourceVolume": "%s",\n' "$(_json_escape "$_corr_src_id")"
          printf '  "entries": [\n'
          local _corr_first=1
          while IFS=$'\t' read -r _ce_rel _ce_fn _ce_size _ce_label _ce_dest; do
            [[ -z "$_ce_rel" ]] && continue
            (( _corr_first )) || printf ',\n'
            _corr_first=0
            printf '    {"relPath": "%s", "filename": "%s", "size": %s, "hash": null, "label": "%s", "destPath": "%s"}' \
              "$(_json_escape "$_ce_rel")" "$(_json_escape "$_ce_fn")" "$_ce_size" \
              "$(_json_escape "$_ce_label")" "$(_json_escape "$_ce_dest")"
          done < "$_corr_entries_file"
          printf '\n  ]\n'
          printf '}\n'
        } > "$_corr_file" 2>/dev/null
      fi
    ) 2>/dev/null || true
  fi
  rm -f "$_corr_entries_file" 2>/dev/null

  rm -rf "$group_dir"

  # Signal the UI immediately — manifest write + any post-processing happens here
  echo "PHASE finalizing"
  phase_end copying

  END=$(( int(EPOCHREALTIME * 1000) ))
  local DUR_MS=$(( END - START ))      # milliseconds
  DUR=$(( DUR_MS / 1000 ))            # whole seconds (kept for duration_sec field)

  local MB_NEW AVG
  bytes_new="${bytes_new:-0}"   # guard against empty (e.g. stat failure)
  MB_NEW="$(human_mb "$bytes_new")"
  MB_NEW="${MB_NEW:-0}"
  # F5: compute speed from bytes actually committed to disk, not planned bytes.
  # bytes_new is set before copying starts, so a cancel/error after 2 seconds
  # with a 10 GB card would produce ~5 000 MB/s from planned bytes — impossible.
  # _committed_bytes is summed only from groups with _copy_exit==0, so the
  # numerator can never exceed what was genuinely written. Partial failures
  # still get a correct speed for the portion that did complete.
  local MB_COMMITTED
  MB_COMMITTED=$(( (_committed_bytes + 524288) / 1048576 ))
  AVG=0
  if [[ "$DRY_RUN" != "yes" ]] && (( DUR_MS > 0 && MB_COMMITTED > 0 )); then
    # Use millisecond duration to avoid rounding a 1.5-second transfer down
    # to 1 second, which inflates the speed reading by up to 2×.
    AVG=$(( (MB_COMMITTED * 1000) / DUR_MS ))
  fi

  # Spot-check checksums if verify is enabled (skipped for dry runs).
  # Capture output so we can detect VERIFY_FAIL and fold it into status_field —
  # previously verify_transfer printed to stdout but its result was never checked,
  # meaning a corrupted card still logged Status=OK.
  # _verify_effective is set only when a verification pass actually checksummed
  # at least one file and it passed (verify_transfer emits VERIFY_PASS only when
  # checked>0 && failed==0).  A VERIFY_SKIP (every sample skipped/not-found) or
  # verify being disabled entirely leaves it 0 — so a zero-integrity copy can
  # never satisfy the auto-eject gate below.
  local _verify_failed=0 _verify_effective=0
  # Phase-split timing (summary scope): wall seconds spent in verify + eject.
  # Default 0 so the summary logs 0 when a phase never ran.
  local _verify_secs=0 _eject_secs_log=0
  # Decide whether to run a verification pass.  Normally driven by the VERIFY
  # setting — but auto-eject FORCES at least a spot-check even when the operator
  # turned verification off.  Ejecting a card invites the operator to reformat
  # it, so the app must never bless (eject) a card it never checked.  "Auto-eject
  # on" therefore IMPLIES "verify at least a sample"; those two settings being
  # independent is the real bug this closes.  Coverage scales with card size, so
  # a forced spot-check on a normal card costs seconds (see verify_transfer).
  local _run_verify=no _forced_spotcheck=no
  if [[ "$VERIFY" == "yes" ]]; then
    _run_verify=yes
  elif [[ "$AUTO_EJECT" == "yes" ]]; then
    _run_verify=yes
    _forced_spotcheck=yes
  fi
  if [[ "$_run_verify" == "yes" && "$DRY_RUN" != "yes" ]]; then
    echo "PHASE verifying"
    local _verify_t0=$(date +%s)
    local _verify_out
    if [[ "$_forced_spotcheck" == "yes" ]]; then
      log_line "VERIFY FORCED: auto-eject is on with verification off — running a spot-check before eject"
      # Force spot-check mode regardless of any stale FULL_VERIFY state.
      local _saved_full_verify="$FULL_VERIFY"
      FULL_VERIFY=no
      _verify_out="$(verify_transfer "$src" "$new_list")"
      FULL_VERIFY="$_saved_full_verify"
    else
      _verify_out="$(verify_transfer "$src" "$new_list")"
    fi
    echo "$_verify_out"   # re-emit for Swift UI parsing
    echo "$_verify_out" | grep -q "^VERIFY_FAIL" && _verify_failed=1
    echo "$_verify_out" | grep -q "^VERIFY_PASS" && _verify_effective=1
    _verify_secs=$(( $(date +%s) - _verify_t0 ))
  fi
  # Generate transfer report before temp files are cleaned up (skipped for dry runs)
  if [[ "$TRANSFER_REPORT" == "yes" && "$DRY_RUN" != "yes" && "$new_count" -gt 0 ]]; then
    generate_transfer_report "$src" "$new_list" "${CARDLABEL:-$cardname}"
  fi

  echo "PROGRESS_SUMMARY avg_mb=$AVG duration_sec=$DUR new_files=$new_count"

  # Always emit the project-level parent folder (open_dest = STANDARD_SUBROOT),
  # not the last date-subfolder.  For a 3-day ingest, last_dest would be the
  # final day's folder; open_dest is the clips/ or footage/ root that contains
  # ALL date subfolders — the right place to open in Finder and the right dest
  # for FolderSync and log analytics to reference.
  echo "PROGRESS_DEST $open_dest"

  # OPEN_TARGET — the folder F / Reveal should open. PROGRESS_DEST (above) stays
  # the project parent for FolderSync + log analytics; this is the operator-facing
  # "take me to what I just offloaded" path. Single destination folder (a normal
  # single-day shoot) → open THAT clips folder so F lands on the .mp4s directly.
  # Multiple date folders in one run → open the parent that contains them all.
  local _open_target="$open_dest"
  if (( ${#_clip_roots[@]} == 1 )); then
    local _only_root
    for _only_root in "${(@k)_clip_roots}"; do _open_target="$_only_root"; done
  fi
  echo "OPEN_TARGET $_open_target"

  # Cleanup temp files
  rm -f "$list_all" "$new_list"

  # Auto-eject card only if requested, not dry-run, ALL copy groups succeeded,
  # AND verification passed.  Ejecting after a verify failure lets the operator
  # reformat the card before realising the only copy is corrupt — the exact
  # catastrophe the verify feature exists to prevent (E3).
  if [[ "$DRY_RUN" != "yes" && "$AUTO_EJECT" == "yes" \
        && _failed_groups -eq 0 && ${_verify_failed:-0} -eq 0 && ${_failed_secondaries:-0} -eq 0 \
        && ${_verify_effective:-0} -eq 1 ]]; then
    # Retry up to 3 times with a 4-second pause between attempts.
    # Spotlight and Finder often hold a handle on newly-written files for a
    # few seconds after transfer completes — a brief wait clears the lock.
    local _eject_exit=1 _eject_attempt=0 _eject_t0 _eject_secs
    _eject_t0=$(date +%s)
    while (( _eject_attempt < 3 && _eject_exit != 0 )); do
      (( _eject_attempt++ ))
      [[ $_eject_attempt -gt 1 ]] && sleep 4 && log_line "EJECT RETRY: attempt $_eject_attempt for $CARD_PATH"
      diskutil eject "$CARD_PATH" >/dev/null 2>&1; _eject_exit=$?
    done
    _eject_secs=$(( $(date +%s) - _eject_t0 ))
    _eject_secs_log=$_eject_secs   # surface eject phase duration to the summary line
    if (( _eject_exit != 0 )); then
      log_line "EJECT FAIL: diskutil eject returned exit $_eject_exit for $CARD_PATH after $_eject_attempt attempt(s), ${_eject_secs}s"
      echo "EJECT_FAILED card=$CARD_PATH"
    else
      # Log success + duration so the post-copy gap (OS write-cache flush / Spotlight
      # release on eject) is attributable in the log instead of looking like dead time.
      log_line "EJECT OK: $CARD_PATH ejected in ${_eject_secs}s (attempt $_eject_attempt)"
    fi
  elif [[ "$AUTO_EJECT" == "yes" \
          && ( _failed_groups -gt 0 || ${_verify_failed:-0} -ne 0 || ${_failed_secondaries:-0} -ne 0 ) ]]; then
    log_line "EJECT SKIPPED: copy/verify/mirror failure — card kept mounted for retry (failed_groups=$_failed_groups verify_failed=${_verify_failed:-0} mirror_failed=${_failed_secondaries:-0})"
    echo "EJECT_SKIPPED reason=verify_or_copy_failure"
  elif [[ "$DRY_RUN" != "yes" && "$AUTO_EJECT" == "yes" && ${_verify_effective:-0} -ne 1 ]]; then
    # Safety net: auto-eject forces a spot-check (above), so verification always
    # runs here — this branch only fires if that pass could verify NOTHING (every
    # sampled file skipped/not-found so checked==0, i.e. VERIFY_SKIP).  Refuse to
    # eject a card whose copy integrity was never actually confirmed — ejecting
    # would let the operator reformat before discovering nothing was verified.
    log_line "EJECT SKIPPED: verification could not confirm any files (verify_effective=0) — card kept mounted; copy integrity unconfirmed"
    echo "EJECT_SKIPPED reason=no_verification"
  fi

  local NOW_HUMAN log_dest transfer_id status_field
  NOW_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"
  # Short unique ID for this transfer run — PID + epoch avoids collisions
  # (epoch-only repeated every ~11.6 days when wrapped to 6 digits)
  transfer_id="${$}_$(date +%s)"
  # Use the project-level parent (open_dest) for the log Dest= field so multi-day
  # ingests show the common ancestor, not just whichever date subfolder happened
  # to be last in the copy loop.
  log_dest="$open_dest"
  if [[ "$DRY_RUN" == "yes" ]]; then
    status_field="DryRun"
  elif (( new_count == 0 )); then
    status_field="NoNewFiles"
  elif (( _failed_groups > 0 )); then
    status_field="PartialError(${_failed_groups}groups)"
  elif (( _verify_failed > 0 )); then
    status_field="VerifyFail"
  elif (( _failed_secondaries > 0 )); then
    status_field="MirrorFail(${_failed_secondaries})"
  else
    status_field="OK"
  fi
  # ── Hardware-path diagnostics: resolve values (best-effort, degrade to unknown)
  # diskutil is fast — call directly for Protocol + media (Solid State) on both
  # ends. Link speed is read from the backgrounded system_profiler tempfile after
  # a SHORT bounded wait so the summary can never hang. All wrapped so any failure
  # is a silent no-op leaving the value "unknown".
  local _src_proto="unknown" _src_link="unknown" _src_media="unknown"
  local _dest_proto="unknown" _dest_link="unknown" _dest_media="unknown"
  local _du_out="" _du_dev="" _du_ss=""
  # --- source (card/reader) ---
  _du_out="$_src_du"   # captured at copy start, before any auto-eject unmounted the card
  if [[ -n "$_du_out" ]]; then
    _src_proto="$(printf '%s\n' "$_du_out" | awk -F': *' '/^ *Protocol:/{print $2; exit}' 2>/dev/null)"
    _du_ss="$(printf '%s\n' "$_du_out" | awk -F': *' '/Solid State:/{print $2; exit}' 2>/dev/null)"
    [[ "$_du_ss" == "Yes" ]] && _src_media="SSD"
    [[ "$_du_ss" == "No"  ]] && _src_media="HDD"
  fi
  # --- destination drive (resolve mounted device via df; space-safe first field)
  _du_dev="$(df "${DEST_ROOT:-$PRIMARY_ROOT}" 2>/dev/null | awk 'NR==2{print $1}' 2>/dev/null || true)"
  _du_out="$(diskutil info "${_du_dev:-${DEST_ROOT:-$PRIMARY_ROOT}}" 2>/dev/null || true)"
  if [[ -n "$_du_out" ]]; then
    _dest_proto="$(printf '%s\n' "$_du_out" | awk -F': *' '/^ *Protocol:/{print $2; exit}' 2>/dev/null)"
    _du_ss="$(printf '%s\n' "$_du_out" | awk -F': *' '/Solid State:/{print $2; exit}' 2>/dev/null)"
    [[ "$_du_ss" == "Yes" ]] && _dest_media="SSD"
    [[ "$_du_ss" == "No"  ]] && _dest_media="HDD"
  fi
  # --- negotiated link speed from the backgrounded system_profiler capture ---
  if [[ -n "$_hw_pid" ]]; then
    # Bounded wait: system_profiler was launched at copy start and has almost
    # always finished by now; cap at ~3s so the summary NEVER hangs on it.
    local _hw_wait=0
    while kill -0 "$_hw_pid" 2>/dev/null && (( _hw_wait < 30 )); do
      sleep 0.1; (( _hw_wait++ ))
    done
    kill -0 "$_hw_pid" 2>/dev/null && kill "$_hw_pid" 2>/dev/null || true
    wait "$_hw_pid" 2>/dev/null || true
  fi
  # Map a protocol to a link speed ONLY when the relevant section yields exactly
  # one unique speed — an ambiguous/absent match logs "unknown" rather than guess.
  _hw_link_for() {
    local _proto="$1" _f="$2" _vals="" _n=0
    [[ -z "$_f" || ! -s "$_f" ]] && { printf 'unknown'; return; }
    case "$_proto" in
      *USB*)
        _vals="$(grep -Eo 'Speed: (Up to )?[0-9.]+ [MG]b/s' "$_f" 2>/dev/null | sed -E 's/^Speed: (Up to )?//' | sort -u)" ;;
      *Thunderbolt*|*PCI*|*PCI-Express*)
        _vals="$(grep -Eo '(Link Speed|Speed): [0-9.]+ [MG]b/s' "$_f" 2>/dev/null | sed -E 's/^(Link Speed|Speed): //' | sort -u)" ;;
      *)
        _vals="" ;;
    esac
    _n="$(printf '%s\n' "$_vals" | grep -c . 2>/dev/null)"
    if [[ "$_n" == "1" ]]; then printf '%s' "$_vals"; else printf 'unknown'; fi
  }
  _src_link="$(_hw_link_for "$_src_proto" "$_hw_tmp" 2>/dev/null || echo unknown)"
  _dest_link="$(_hw_link_for "$_dest_proto" "$_hw_tmp" 2>/dev/null || echo unknown)"
  [[ -n "$_hw_tmp" ]] && rm -f "$_hw_tmp" 2>/dev/null || true
  # Normalize empties to "unknown" and scrub any pipe (the log field separator).
  [[ -z "$_src_proto"  ]] && _src_proto="unknown";   _src_proto="${_src_proto//|/-}"
  [[ -z "$_src_link"   ]] && _src_link="unknown";    _src_link="${_src_link//|/-}"
  [[ -z "$_src_media"  ]] && _src_media="unknown";   _src_media="${_src_media//|/-}"
  [[ -z "$_dest_proto" ]] && _dest_proto="unknown";  _dest_proto="${_dest_proto//|/-}"
  [[ -z "$_dest_link"  ]] && _dest_link="unknown";   _dest_link="${_dest_link//|/-}"
  [[ -z "$_dest_media" ]] && _dest_media="unknown";  _dest_media="${_dest_media//|/-}"

  # Emit hardware link info to stdout so the Swift app can compute bottleneck descriptions.
  echo "SPEED_HARDWARE src_link=${_src_link} dest_link=${_dest_link}"

  local _log_cardname="${cardname//|/-}" _log_friendly="${friendly//|/-}" _log_project="${PROJECT_NAME//|/-}"
  log_line "$NOW_HUMAN | ID=$transfer_id | Version=$CARDRUNNER_VERSION | macOS=$macos_ver | Status=$status_field | Mode=$MODE | Card=$_log_cardname | Friendly=$_log_friendly | Project=$_log_project | Subfolder=$SUBFOLDER | MediaTotal=$media_count | NewFiles=$new_count | NewMB=$MB_NEW | DurationSec=$DUR | AvgMBps=$AVG | TodayOnly=$TODAY_ONLY | Dest=$log_dest | CopySec=$DUR | VerifySec=$_verify_secs | EjectSec=$_eject_secs_log | SourceProtocol=$_src_proto | SourceLink=$_src_link | DestProtocol=$_dest_proto | DestLink=$_dest_link | DestMedia=$_dest_media"

  # Propagate failure to the caller. A copy-group failure or a verify mismatch must
  # NEVER surface to the operator as "done / safe to eject" — emit a distinct phase
  # the Swift parser maps to an error state, and exit non-zero so the termination
  # handler's exitStatus gate also catches it even if the line is somehow missed.
  if (( _failed_groups > 0 || _verify_failed > 0 || _failed_secondaries > 0 )); then
    echo "PHASE failed groups=${_failed_groups} verify=${_verify_failed} mirror=${_failed_secondaries}"
    return 1
  fi

  echo "PHASE done"
  return 0
}

# -----------------------------------------------------------
# Flag parsing
# -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)            CARD_PATH="$2"; shift 2 ;;
    --primary)         PRIMARY_ROOT="$2"; shift 2 ;;
    --project)         PROJECT_NAME="$2"; shift 2 ;;
    --dest-root)       DEST_ROOT="$2"; shift 2 ;;
    --subfolder)       SUBFOLDER="$2"; shift 2 ;;
    --cardlabel)       CARDLABEL="$2"; shift 2 ;;
    --ignore-manifest) IGNORE_MANIFEST="yes"; shift 1 ;;
    --latest)          LATEST_COUNT="$2"; shift 2 ;;
    --dry-run)         DRY_RUN="yes"; shift 1 ;;
    --today-only)      DATE_FROM="$(date +%Y%m%d)"; TODAY_ONLY="yes"; shift 1 ;;
    --date-from)       DATE_FROM="$2"; shift 2 ;;
    --date-override)   DATE_OVERRIDE="$2"; shift 2 ;;
    --reels)           REEL_FILTER=("${(@s:,:)2}"); shift 2 ;;
    --reel-multi)      REEL_MULTI="yes"; shift 1 ;;
    --date-to)         DATE_TO="$2"; shift 2 ;;
    --dates)           DATES_LIST="$2"; shift 2 ;;
    --auto-eject)      AUTO_EJECT="yes"; shift 1 ;;
    --winter-olympics) WINTER_OLYMPICS_MODE="yes"; shift 1 ;;
    --olympics-code)
      OLYMPICS_CODE="$2"
      shift 2 ;;
    --include-xml)     COPY_XML="yes"; shift 1 ;;
    --include-proxies) INCLUDE_PROXIES="yes"; shift 1 ;;
    --verify)          VERIFY="yes"; shift 1 ;;
    --full-verify)     VERIFY="yes"; FULL_VERIFY="yes"; shift 1 ;;
    --date-format)        DATE_FORMAT="$2"; shift 2 ;;
    --broadcast-day-hour) BROADCAST_DAY_HOUR="$2"; shift 2 ;;
    --finder-tag-color)   FINDER_TAG_COLOR="$2"; shift 2 ;;
    --rename-template)  RENAME_TEMPLATE="$2"; shift 2 ;;
    --transfer-report)  TRANSFER_REPORT="yes"; shift 1 ;;
    --secondary)        SECONDARY_ROOTS+=("$2"); shift 2 ;;
    --scaffold)         SCAFFOLD_FOLDERS="$2"; shift 2 ;;
    --app-version)      CARDRUNNER_VERSION="$2"; shift 2 ;;
    --sort-order)      SORT_ORDER="$2"; shift 2 ;;
    --mode)
      MODE="$2"
      shift 2 ;;
    *)                 shift 1 ;;
  esac
done

# -----------------------------------------------------------
# Main
# -----------------------------------------------------------

run_ingest
exit $?
