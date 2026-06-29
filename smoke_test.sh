#!/bin/zsh
# ============================================================================
#  CardRunner — pre-release smoke test
# ----------------------------------------------------------------------------
#  Proves the ingest path actually works BEFORE a build reaches a real shoot.
#  Builds synthetic camera cards, runs the REAL CardRunner.sh + cardcopy engine
#  against them into throwaway destinations, and asserts that files truly landed
#  and the app reported the correct success/failure.
#
#  This exists because a one-line shell bug (zsh `int()` needing zsh/mathfunc)
#  once silently broke EVERY transfer in a shipped build. This catches that
#  class of bug on your desk instead of in the field.
#
#  Usage:   ./smoke_test.sh
#  Exit:    0 = all checks passed (safe to ship),  1 = something failed.
# ============================================================================

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INGEST="$SCRIPT_DIR/CardRunner/CardRunner.sh"
CARDCOPY="$SCRIPT_DIR/CardRunner/cardcopy"

PASS=0
FAIL=0
GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RST=$'\e[0m'

ok()   { print -r -- "  ${GREEN}✓${RST} $1"; (( PASS++ )); }
bad()  { print -r -- "  ${RED}✗ $1${RST}"; (( FAIL++ )); }
info() { print -r -- "${DIM}$1${RST}"; }

# Make a synthetic card directory with $1 video files under a $2 subpath.
# Files get today's mtime (fresh), so --today-only matches them.
make_files() {
  local dir="$1" count="$2" prefix="${3:-XG_TEST}"
  mkdir -p "$dir"
  local i
  for (( i = 1; i <= count; i++ )); do
    head -c 1048576 /dev/urandom > "$dir/${prefix}_$(printf '%04d' $i).MP4"
  done
}

# Run an ingest. $1=card root, $2=dest root. Remaining args passed through.
# Captures combined stdout+stderr into $RUN_OUT and the exit code into $RUN_EC.
run_ingest() {
  local card="$1" dest="$2"; shift 2
  RUN_OUT="$(mktemp /tmp/cr_smoke_out.XXXXXX)"
  /bin/zsh "$INGEST" --app-version vSMOKE --card "$card" \
    --dest-root "$dest" --primary "$dest" --today-only "$@" > "$RUN_OUT" 2>&1
  RUN_EC=$?
}

# Assert a grep pattern is present / absent in the captured run output.
out_has()    { grep -q "$1" "$RUN_OUT"; }
field()      { grep -oE "$1=[0-9]+" "$RUN_OUT" | head -1 | cut -d= -f2; }

print -r -- "${BOLD}CardRunner smoke test${RST}"
info "ingest: $INGEST"
info "engine: $CARDCOPY"
print -r -- ""

# ── Check 0: the copy engine itself is sane ─────────────────────────────────
print -r -- "${BOLD}[0] copy engine${RST}"
if [[ -x "$CARDCOPY" ]] && "$CARDCOPY" --version >/dev/null 2>&1; then
  ok "cardcopy present and --version returns 0 ($("$CARDCOPY" --version 2>/dev/null))"
else
  bad "cardcopy missing or --version failed — the engine is broken"
fi

# ── Check 1: fresh copy of a normal card ────────────────────────────────────
print -r -- "${BOLD}[1] fresh copy (DCIM card, 5 clips)${RST}"
C1="$(mktemp -d /tmp/cr_card1.XXXXXX)"; D1="$(mktemp -d /tmp/cr_dest1.XXXXXX)"
make_files "$C1/DCIM/100MEDIA" 5
run_ingest "$C1" "$D1"
landed=$(find "$D1" -type f -name '*.MP4' | wc -l | tr -d ' ')
(( RUN_EC == 0 ))                 && ok "exit code 0"                       || bad "exit code was $RUN_EC (expected 0)"
out_has "PHASE done"              && ok "reported PHASE done"               || bad "did not report PHASE done"
! out_has "PHASE failed"          && ok "did not report PHASE failed"       || bad "reported PHASE failed on a good copy"
[[ "$landed" == "5" ]]            && ok "all 5 files landed at destination" || bad "only $landed/5 files landed"
[[ "$(field new_files)" == "5" ]] && ok "new_files=5"                       || bad "new_files=$(field new_files) (expected 5)"

# ── Check 2: re-insert the same card → nothing re-copies (dest skips) ────────
print -r -- "${BOLD}[2] idempotent re-copy (dest skips)${RST}"
run_ingest "$C1" "$D1"
(( RUN_EC == 0 ))                       && ok "exit code 0"                  || bad "exit code was $RUN_EC"
[[ "$(field new_files)" == "0" ]]       && ok "new_files=0 (nothing re-copied)" || bad "new_files=$(field new_files) (expected 0)"
[[ "$(field dest_exists)" == "5" ]]     && ok "5 skipped as already present"     || bad "dest_exists=$(field dest_exists) (expected 5)"

# ── Check 3: proxy/sub files are skipped AND counted (accounting balances) ───
print -r -- "${BOLD}[3] proxy skip accounting (Sony M4ROOT)${RST}"
C3="$(mktemp -d /tmp/cr_card3.XXXXXX)"; D3="$(mktemp -d /tmp/cr_dest3.XXXXXX)"
make_files "$C3/PRIVATE/M4ROOT/CLIP" 3 XG_FX3        # 3 main clips
make_files "$C3/PRIVATE/M4ROOT/SUB"  2 XG_FX3PROXYS03 # 2 proxy clips (S03 + SUB/)
run_ingest "$C3" "$D3"
landed3=$(find "$D3" -type f -name '*.MP4' | wc -l | tr -d ' ')
found=$(field media_total); new=$(field new_files); proxy=$(field proxy)
(( RUN_EC == 0 ))                  && ok "exit code 0"                     || bad "exit code was $RUN_EC"
[[ "$landed3" == "3" ]]            && ok "3 main clips landed (proxies excluded)" || bad "$landed3 landed (expected 3)"
[[ "$proxy" == "2" ]]              && ok "proxy=2 counted in SKIP_SUMMARY" || bad "proxy=$proxy (expected 2)"
# found = new + all skips  → the books must balance
manifest=$(field manifest); destx=$(field dest_exists); today=$(field today_filter); wrong=$(field wrong_mode); missing=$(field missing)
total_skips=$(( ${manifest:-0} + ${destx:-0} + ${today:-0} + ${wrong:-0} + ${proxy:-0} + ${missing:-0} ))
[[ $(( ${new:-0} + total_skips )) == "${found:-0}" ]] \
  && ok "accounting balances: found=$found = new=$new + skipped=$total_skips" \
  || bad "accounting does NOT balance: found=$found, new=$new, skipped=$total_skips"

# ── Check 4: broadcast-day filter must not drop post-midnight footage ────────
print -r -- "${BOLD}[4] broadcast-day date filter (footage-loss regression)${RST}"
# A clip shot at 01:00 belongs to the PREVIOUS broadcast day when the cutoff hour
# is 05:00. If you select that previous day, the clip must still be ingested.
# Before the fix the scan compared raw mtime and silently excluded it.
C4="$(mktemp -d /tmp/cr_card4.XXXXXX)"
YESTERDAY="$(date -v-1d +%Y%m%d)"
mkdir -p "$C4/DCIM/100MEDIA"
head -c 1048576 /dev/urandom > "$C4/DCIM/100MEDIA/XG_LATE_0001.MP4"
touch -t "$(date +%Y%m%d)0100" "$C4/DCIM/100MEDIA/XG_LATE_0001.MP4"  # today 01:00

# 4a: WITHOUT broadcast hour, selecting yesterday must NOT match a today-01:00 clip
D4a="$(mktemp -d /tmp/cr_dest4a.XXXXXX)"
run_ingest "$C4" "$D4a" --dates "$YESTERDAY"
[[ "$(field new_files)" == "0" ]] \
  && ok "control: clip excluded without broadcast offset (filter works)" \
  || bad "control failed: new_files=$(field new_files) (expected 0)"

# 4b: WITH broadcast hour 5, that same clip belongs to yesterday → must ingest
D4b="$(mktemp -d /tmp/cr_dest4b.XXXXXX)"
run_ingest "$C4" "$D4b" --dates "$YESTERDAY" --broadcast-day-hour 5
landed4=$(find "$D4b" -type f -name '*.MP4' | wc -l | tr -d ' ')
(( RUN_EC == 0 ))                 && ok "exit code 0"                                  || bad "exit code was $RUN_EC"
[[ "$(field new_files)" == "1" ]] && ok "post-midnight clip INCLUDED via broadcast shift" || bad "footage dropped: new_files=$(field new_files) (expected 1)"
[[ "$landed4" == "1" ]]           && ok "1 file landed at destination"                || bad "$landed4 landed (expected 1)"

# ── Check 5: spot-check verification path works (now on by default) ──────────
print -r -- "${BOLD}[5] spot-check verification${RST}"
C5="$(mktemp -d /tmp/cr_card5.XXXXXX)"; D5="$(mktemp -d /tmp/cr_dest5.XXXXXX)"
make_files "$C5/DCIM/100MEDIA" 4
run_ingest "$C5" "$D5" --verify
(( RUN_EC == 0 ))        && ok "exit code 0 with --verify"          || bad "exit code was $RUN_EC with --verify"
out_has "VERIFY_PASS"    && ok "VERIFY_PASS emitted (checksums OK)" || bad "no VERIFY_PASS — verify did not run/pass"
! out_has "VERIFY_FAIL"  && ok "no VERIFY_FAIL on good files"       || bad "VERIFY_FAIL on known-good files"

# ── Check 6: two ingests in parallel don't clobber each other (Phase 2) ──────
print -r -- "${BOLD}[6] concurrent ingests to two destinations${RST}"
C6a="$(mktemp -d /tmp/cr_card6a.XXXXXX)"; D6a="$(mktemp -d /tmp/cr_dest6a.XXXXXX)"
C6b="$(mktemp -d /tmp/cr_card6b.XXXXXX)"; D6b="$(mktemp -d /tmp/cr_dest6b.XXXXXX)"
make_files "$C6a/DCIM/100MEDIA" 6 XG_CARDA
make_files "$C6b/DCIM/100MEDIA" 6 XG_CARDB
O6a="$(mktemp /tmp/cr_smoke_out.XXXXXX)"; O6b="$(mktemp /tmp/cr_smoke_out.XXXXXX)"
# Launch both at once (background), like two cards mounted together to two drives.
/bin/zsh "$INGEST" --app-version vSMOKE --card "$C6a" --dest-root "$D6a" --primary "$D6a" --today-only > "$O6a" 2>&1 &
p1=$!
/bin/zsh "$INGEST" --app-version vSMOKE --card "$C6b" --dest-root "$D6b" --primary "$D6b" --today-only > "$O6b" 2>&1 &
p2=$!
wait $p1; e1=$?
wait $p2; e2=$?
la=$(find "$D6a" -type f -name '*.MP4' | wc -l | tr -d ' ')
lb=$(find "$D6b" -type f -name '*.MP4' | wc -l | tr -d ' ')
(( e1 == 0 && e2 == 0 ))           && ok "both parallel runs exited 0"            || bad "exit codes: A=$e1 B=$e2"
grep -q "PHASE done" "$O6a" && grep -q "PHASE done" "$O6b" && ok "both reported PHASE done" || bad "a parallel run did not finish"
[[ "$la" == "6" && "$lb" == "6" ]] && ok "both cards landed all 6 files (no temp-file clobbering)" || bad "landed A=$la B=$lb (expected 6 each)"

# ── Check 8: N-way mirror — files land on the primary AND every mirror ────────
print -r -- "${BOLD}[8] N-way mirror — primary + all mirrors${RST}"
C8="$(mktemp -d /tmp/cr_card8.XXXXXX)"
P8="$(mktemp -d /tmp/cr_prim8.XXXXXX)"
M8a="$(mktemp -d /tmp/cr_mir8a.XXXXXX)"
M8b="$(mktemp -d /tmp/cr_mir8b.XXXXXX)"
make_files "$C8/DCIM/100MEDIA" 4 XG_MIR
RUN_OUT="$(mktemp /tmp/cr_smoke_out.XXXXXX)"
/bin/zsh "$INGEST" --app-version vSMOKE --card "$C8" \
  --primary "$P8" --project SMOKE --today-only \
  --secondary "$M8a" --secondary "$M8b" > "$RUN_OUT" 2>&1
EC8=$?
(( EC8 == 0 ))             && ok "exit 0 with two --secondary mirrors"   || bad "exit $EC8 with mirrors"
out_has "PHASE done"       && ok "reported PHASE done"                   || bad "did not report PHASE done"
lp8=$(find "$P8" -type f -name '*.MP4' | wc -l | tr -d ' ')
l8a=$(find "$M8a" -type f -name '*.MP4' | wc -l | tr -d ' ')
l8b=$(find "$M8b" -type f -name '*.MP4' | wc -l | tr -d ' ')
[[ "$lp8" == 4 && "$l8a" == 4 && "$l8b" == 4 ]] && ok "all 4 files on primary + both mirrors" || bad "mirror mismatch primary=$lp8 m1=$l8a m2=$l8b"

# ── Check 9: a failing mirror FAILS the run; primary intact; card NOT ejected ─
# Guards the footage-safety fix: a silently-failing mirror must never report success.
print -r -- "${BOLD}[9] failing mirror fails the run (primary safe, no eject)${RST}"
C9="$(mktemp -d /tmp/cr_card9.XXXXXX)"
P9="$(mktemp -d /tmp/cr_prim9.XXXXXX)"
make_files "$C9/DCIM/100MEDIA" 3 XG_FAIL
RUN_OUT="$(mktemp /tmp/cr_smoke_out.XXXXXX)"
/bin/zsh "$INGEST" --app-version vSMOKE --card "$C9" \
  --primary "$P9" --project SMOKE --today-only --auto-eject \
  --secondary "/cr_no_such_mirror_$$" > "$RUN_OUT" 2>&1
EC9=$?
(( EC9 != 0 ))         && ok "non-zero exit on mirror failure ($EC9)"            || bad "FALSE SUCCESS: exit 0 despite failed mirror"
out_has "PHASE failed" && ok "reported PHASE failed"                            || bad "did not report PHASE failed"
lp9=$(find "$P9" -type f -name '*.MP4' | wc -l | tr -d ' ')
[[ "$lp9" == 3 ]]      && ok "primary copy intact (footage never lost on mirror failure)" || bad "primary lost files: $lp9/3"
out_has "EJECT_SKIPPED" && ok "card kept mounted (EJECT_SKIPPED) despite --auto-eject"     || bad "card eligible for eject after mirror failure"

# ── Check 7: no fatal shell errors slipped through any run ───────────────────
print -r -- "${BOLD}[7] no fatal shell errors${RST}"
# This is the exact class that broke every transfer: arithmetic/function errors
# that abort the script mid-copy.
fatal_seen=0
for f in /tmp/cr_smoke_out.*; do
  if grep -qiE "unknown function|command not found|parse error|bad math|division by zero|no such file or directory: .*cardcopy" "$f" 2>/dev/null; then
    fatal_seen=1
    grep -iE "unknown function|command not found|parse error|bad math|division by zero" "$f" | head -3 | sed 's/^/    /'
  fi
done
(( fatal_seen == 0 )) && ok "no fatal shell errors in any run" || bad "fatal shell error(s) detected (see above)"

# ── Cleanup ─────────────────────────────────────────────────────────────────
rm -rf /tmp/cr_card1.* /tmp/cr_dest1.* /tmp/cr_card3.* /tmp/cr_dest3.* \
       /tmp/cr_card4.* /tmp/cr_dest4a.* /tmp/cr_dest4b.* \
       /tmp/cr_card5.* /tmp/cr_dest5.* \
       /tmp/cr_card6a.* /tmp/cr_dest6a.* /tmp/cr_card6b.* /tmp/cr_dest6b.* \
       /tmp/cr_card8.* /tmp/cr_prim8.* /tmp/cr_mir8a.* /tmp/cr_mir8b.* \
       /tmp/cr_card9.* /tmp/cr_prim9.* \
       /tmp/cr_smoke_out.* 2>/dev/null

print -r -- ""
print -r -- "${BOLD}Result: ${GREEN}${PASS} passed${RST}${BOLD}, $([[ $FAIL -gt 0 ]] && print -n "${RED}")${FAIL} failed${RST}"
if (( FAIL > 0 )); then
  print -r -- "${RED}${BOLD}SMOKE TEST FAILED — do not ship this build.${RST}"
  exit 1
fi
print -r -- "${GREEN}${BOLD}All clear — ingest path verified end-to-end.${RST}"
exit 0
