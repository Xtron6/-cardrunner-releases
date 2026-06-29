#!/bin/bash
# cardrunner_benchmark.sh — head-to-head copy throughput test on macOS
#
# Compares CardRunner's engine against the tools Finder/macOS use under the hood:
#   • cardcopy (no-verify)   ← CardRunner's default fast path
#   • cardcopy (verify on)   ← shows the cost of per-file SHA-256
#   • cp                     ← plain BSD copy
#   • ditto                  ← the copy engine Finder/Migration Assistant use
#   • rsync -a               ← CardRunner's OLD engine (v1.0), for reference
#
# USAGE:
#   ./cardrunner_benchmark.sh [SOURCE_DIR] [DEST_DIR]
#
#   SOURCE_DIR  folder to copy FROM. For a real-world result, point this at a
#               mounted card, e.g. "/Volumes/Untitled/DCIM" or "/Volumes/Untitled".
#               If omitted, a ~6 GB synthetic dataset is generated (see note on caching).
#   DEST_DIR    folder to copy INTO. Defaults to a temp folder on your home volume.
#               For a real-world result, point this at your offload drive,
#               e.g. "/Volumes/Gallo 8TB".
#
# EXAMPLES:
#   ./cardrunner_benchmark.sh "/Volumes/Untitled" "/Volumes/Gallo 8TB"
#   ./cardrunner_benchmark.sh                # synthetic data → home folder
#
# NOTE ON CACHING: copying FROM a real card is the most honest test, because the
# source can't sit in macOS's RAM cache. If you use synthetic data on your internal
# SSD, the OS may serve the second+ runs from cache and inflate the numbers. Run with
# CLEAR_CACHE=1 (will prompt for sudo to run `purge`) to reduce that effect.

set -u
SRC="${1:-}"
DEST_BASE="${2:-$HOME/CardRunnerBench}"
CLEAR_CACHE="${CLEAR_CACHE:-0}"

# ── locate the cardcopy binary ──────────────────────────────────────────────
find_cardcopy() {
  local candidates=(
    "$(dirname "$0")/CardRunner/cardcopy"
    "$(dirname "$0")/cardcopy/cardcopy"
    "/Applications/CardRunner.app/Contents/Resources/cardcopy"
    "$HOME/Library/Developer/Xcode/DerivedData"/CardRunner-*/Build/Products/Release/CardRunner.app/Contents/Resources/cardcopy
  )
  for c in "${candidates[@]}"; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  # last resort: search the app folder
  local found
  found=$(/usr/bin/find "$(dirname "$0")" -name cardcopy -type f -perm +111 2>/dev/null | head -1)
  [[ -n "$found" ]] && { echo "$found"; return 0; }
  return 1
}
CARDCOPY="$(find_cardcopy || true)"
if [[ -z "${CARDCOPY:-}" ]]; then
  echo "⚠  Could not find the cardcopy binary. Edit CARDCOPY= at the top of this script"
  echo "   to point at it (e.g. /Applications/CardRunner.app/Contents/Resources/cardcopy)."
  echo "   Continuing with cp / ditto / rsync only."
fi

# ── high-resolution timer ───────────────────────────────────────────────────
now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time;print(int(time.time()*1000))'
  elif perl -MTime::HiRes=time -e 1 >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

clear_cache() {
  sync
  if [[ "$CLEAR_CACHE" == "1" ]]; then
    sudo purge 2>/dev/null && echo "   (cache purged)" || echo "   (purge unavailable; numbers may be cache-warmed)"
  fi
}

# ── build synthetic dataset if no source given ──────────────────────────────
TMP_SRC=""
if [[ -z "$SRC" ]]; then
  TMP_SRC="$(mktemp -d /tmp/ccbench_src.XXXXXX)"
  SRC="$TMP_SRC"
  echo "No SOURCE_DIR given — generating ~6 GB synthetic dataset in $SRC ..."
  # 6 x ~1 GB "video" files
  for i in 1 2 3 4 5 6; do
    dd if=/dev/urandom of="$SRC/CLIP_$(printf '%02d' $i).MP4" bs=1m count=1024 status=none
  done
  # 200 x ~2 MB "photo/raw" files (small-file stress)
  for i in $(seq 1 200); do
    dd if=/dev/urandom of="$SRC/IMG_$(printf '%04d' $i).ARW" bs=1m count=2 status=none
  done
  echo "   done."
fi

if [[ ! -d "$SRC" ]]; then echo "Source not found: $SRC"; exit 1; fi

# total bytes / file count of the source (top-level files + recursive)
read TOTAL_BYTES FILE_COUNT < <(
  /usr/bin/find "$SRC" -type f ! -name '.*' -exec stat -f%z {} + \
  | awk '{s+=$1; n++} END{print s+0, n+0}'
)
TOTAL_MB=$(awk "BEGIN{printf \"%.1f\", $TOTAL_BYTES/1048576}")

mkdir -p "$DEST_BASE" || { echo "Cannot create dest: $DEST_BASE"; exit 1; }
echo
echo "Source : $SRC"
echo "Dest   : $DEST_BASE"
echo "Data   : ${TOTAL_MB} MB across ${FILE_COUNT} files"
[[ -n "${CARDCOPY:-}" ]] && echo "cardcopy: $CARDCOPY ($("$CARDCOPY" --version 2>/dev/null))"
echo "------------------------------------------------------------------"
printf "%-26s %10s %16s\n" "METHOD" "TIME(s)" "THROUGHPUT(MB/s)"
echo "------------------------------------------------------------------"

# collect the source file list once (for cardcopy, which takes file args)
SRC_FILES=()
while IFS= read -r f; do SRC_FILES+=("$f"); done < <(/usr/bin/find "$SRC" -type f ! -name '.*')

run_method() {
  local label="$1"; shift
  local dest="$DEST_BASE/$(echo "$label" | tr ' /()' '____')"
  rm -rf "$dest"; mkdir -p "$dest"
  clear_cache
  local t0 t1 dt mbps
  t0=$(now_ms)
  "$@" "$dest" >/dev/null 2>"$DEST_BASE/.err_$$"
  local rc=$?
  t1=$(now_ms)
  dt=$(awk "BEGIN{printf \"%.2f\", ($t1-$t0)/1000}")
  if [[ $rc -ne 0 ]]; then
    printf "%-26s %10s %16s\n" "$label" "$dt" "ERR(rc=$rc)"
    head -1 "$DEST_BASE/.err_$$" | sed 's/^/    /'
  else
    mbps=$(awk "BEGIN{ if($dt>0) printf \"%.1f\", $TOTAL_MB/$dt; else print \"--\" }")
    printf "%-26s %10s %16s\n" "$label" "$dt" "$mbps"
  fi
  rm -rf "$dest" "$DEST_BASE/.err_$$"
}

# wrappers so each takes the destination as the LAST argument
cc_noverify() { "$CARDCOPY" --no-verify --partial-dir=.bench "${SRC_FILES[@]}" "$1/"; }
cc_verify()   { "$CARDCOPY"             --partial-dir=.bench "${SRC_FILES[@]}" "$1/"; }
do_cp()       { cp -R "$SRC"/. "$1/"; }
do_ditto()    { ditto "$SRC" "$1"; }
do_rsync()    { rsync -a "$SRC"/ "$1"/; }

if [[ -n "${CARDCOPY:-}" ]]; then
  run_method "cardcopy (no-verify)" cc_noverify
  run_method "cardcopy (verify on)" cc_verify
fi
run_method "cp -R"   do_cp
run_method "ditto"   do_ditto
run_method "rsync -a" do_rsync

echo "------------------------------------------------------------------"
echo "Tip: run 2–3 times. If 'cardcopy (no-verify)' is within ~10% of 'ditto',"
echo "you're hardware-bound (good). A big gap to ditto would point at a software issue."
[[ -n "$TMP_SRC" ]] && rm -rf "$TMP_SRC"
