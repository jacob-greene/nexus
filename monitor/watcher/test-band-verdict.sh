#!/usr/bin/env bash
# test-band-verdict.sh — band-verdict.sh reads a run-tests.sh LOG and refuses to
# call a killed, orphaned, interrupted or mixed-tree run a verdict; and the
# runner's RED END marker says when a red is only TIME.
# (your-org/nexus-code#1474, the local form.)
#
# EVERY LOG JUDGED HERE IS WRITTEN BY THE REAL RUNNER, INSIDE THIS SUITE. A
# reader tested against hand-typed specimens passes for as long as its author's
# memory of the format holds, and the format is the runner's to change. So the
# three base logs come from `run-tests.sh` over planted fixtures, and every
# corruption is DERIVED from the real green one (its END line dropped, a row
# appended after it, its rc rewritten, a row removed). If the runner reworded
# its marker or its rows, the GREEN control below goes red first and says so.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_self_dir/_test_helpers.sh"

RUNNER="$_self_dir/run-tests.sh"
READER="$_self_dir/band-verdict.sh"
# The outer band's runner inputs (KEEP_LOGS_DIR, --require-*, a ceiling file)
# are not this suite's inner runs' policy (#1571 F5). Before anything is set.
th_scrub_inherited_runner_env "$RUNNER"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bandverdict.XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
FX="$WORK/fx"; mkdir -p "$FX"
export NEXUS_TEST_STATE_DIR="$WORK/state"

printf '#!/usr/bin/env bash\necho "  PASS: fine"\necho "=== summary: 1 passed, 0 failed ==="\necho "ALL TESTS PASSED"\nexit 0\n' > "$FX/test-bv-ok-a.sh"
cp "$FX/test-bv-ok-a.sh" "$FX/test-bv-ok-b.sh"
printf '#!/usr/bin/env bash\necho "working"\nsleep 60\n' > "$FX/test-bv-slow.sh"
printf '#!/usr/bin/env bash\necho "  FAIL: broken — got x want y" >&2\nexit 1\n' > "$FX/test-bv-red.sh"
chmod +x "$FX"/*.sh

_band() {   # <log> <runner args…> ; sets BAND_RC
    local _log="$1"; shift
    env -u NEXUS_ROOT -u NEXUS_LOCALS bash "$RUNNER" --timeout 2 "$@" </dev/null >"$_log" 2>&1
    BAND_RC=$?
}
_read() {   # <log> ; sets LINE (the machine line), OUT (everything), RC
    OUT=$(bash "$READER" "$1" 2>&1); RC=$?
    LINE=$(printf '%s\n' "$OUT" | sed -n 1p)
}

echo "=== 1. three REAL logs: green, red by assertion, red by TIME ==="
_band "$WORK/green.log" "$FX/test-bv-ok-a.sh" "$FX/test-bv-ok-b.sh"
assert_rc "control: the runner calls two passing fixtures green" "$BAND_RC" "0"
_read "$WORK/green.log"
assert_rc       "a COMPLETE green log is rc 0" "$RC" "0"
assert_contains "…and the line says so, with the counts reconciled" "$LINE" "verdict=green class=complete end_rc=0 selected=2 reported=2 pass=2"

_band "$WORK/red.log" "$FX/test-bv-ok-a.sh" "$FX/test-bv-red.sh"
_read "$WORK/red.log"
assert_rc       "a COMPLETE red log is rc 1" "$RC" "1"
assert_contains "…red by ASSERTION, named as about the tree" "$OUT" "red by ASSERTION (these are about the tree):"
# BYTE-IDENTICAL when nothing timed out: two other suites assert this exact text.
assert_contains "MUST-NOT-FLIP: with no TIMEOUT the runner's RED marker is unchanged" \
    "$(sed -n '$p' "$WORK/red.log")" "=== run-tests: END rc=1 (COMPLETE and RED) ==="

_band "$WORK/timeout.log" --jobs 2 "$FX/test-bv-ok-a.sh" "$FX/test-bv-slow.sh"
assert_contains "the runner's RED marker says a red is ONLY TIME (#1474)" \
    "$(sed -n '$p' "$WORK/timeout.log")" "=== run-tests: END rc=1 (COMPLETE and RED — 1 TIMED OUT (no verdict about them), 0 failed) ==="
_read "$WORK/timeout.log"
assert_rc       "a red by TIME is still rc 1 (every caller reads 1 as do-not-merge)" "$RC" "1"
assert_contains "…but it is named APART from an assertion failure" "$OUT" "NO VERDICT about these — they ran out of their ceiling"
assert_contains "…with the suite" "$OUT" "    test-bv-slow.sh"
assert_contains "…and the line separates the two counts" "$LINE" "fail=0 timeout=1"
_band "$WORK/both.log" "$FX/test-bv-ok-a.sh" "$FX/test-bv-slow.sh" "$FX/test-bv-red.sh"
assert_contains "one of each: the marker counts both" \
    "$(sed -n '$p' "$WORK/both.log")" "1 TIMED OUT (no verdict about them), 1 failed) ==="

echo "=== 2. the same green log, damaged the ways a band gets damaged ==="
sed '$d' "$WORK/green.log" > "$WORK/killed.log"
_read "$WORK/killed.log"
assert_rc       "NO END marker (SIGKILL, a wall-clock kill, still running) is rc 4, not green" "$RC" "4"
assert_contains "…said as a SUBSET, with every row a PASS" "$OUT" "those rows are a SUBSET (2 PASS among them proves nothing about the rest)"
assert_contains "…and the line carries no verdict" "$LINE" "verdict=none class=no-end-marker end_rc=none"

{ cat "$WORK/green.log"; printf '  PASS  %-45s  %6ss %s\n' test-bv-orphan.sh 1.00 "3 assertions"; } > "$WORK/orphans.log"
_read "$WORK/orphans.log"
assert_rc       "a row AFTER the END marker (#1474's orphaned dispatch children) is rc 4" "$RC" "4"
assert_contains "…classified as such" "$LINE" "verdict=none class=rows-after-end"

for _pair in '3|incomplete' '4|signalled' '5|tree-changed' '42|aborted'; do
    _rc=${_pair%%|*}; _cls=${_pair#*|}
    sed "s/END rc=0 (COMPLETE and green)/END rc=$_rc (rewritten)/" "$WORK/green.log" > "$WORK/rc$_rc.log"
    _read "$WORK/rc$_rc.log"
    assert_eq "END rc=$_rc is NOT a verdict: rc 4, class $_cls" "$RC|$(printf '%s' "$LINE" | sed -n 's/.* class=\([a-z-]*\) .*/\1/p')" "4|$_cls"
done

grep -v '^  PASS  test-bv-ok-b' "$WORK/green.log" > "$WORK/short.log"
_read "$WORK/short.log"
assert_rc       "a COMPLETE marker over a SHORT row set is REFUSED (rc 2), not believed" "$RC" "2"
# The first cut printed `verdict=green` here and refused on the next line.
assert_contains "…and the machine line does NOT say green while refusing" "$LINE" "verdict=none class=rows-mismatch"

# A GREEN MARKER OVER A RED ROW (skeptic round 1). DERIVED from the real green
# log by SUBSTITUTING one PASS row for a TIMEOUT/FAIL row, so `reported` still
# equals `selected` and the rows-mismatch arm CANNOT be what fires — this is the
# new conjunct or nothing. No runner in this tree emits such a log (a timeout
# forces rc 1 in both accounting arms, pinned by the real timeout log above), so
# it can only be built this way, and the point is that the reader must not need
# the producer to be well behaved.
sed 's|^  PASS  test-bv-ok-b\.sh .*|  TIMEOUT  test-bv-ok-b.sh                            2.00s  (ceiling 2s +15s KILL grace; rc=124 — NOT a pass; see #499)|' \
    "$WORK/green.log" > "$WORK/green-with-timeout.log"
_read "$WORK/green-with-timeout.log"
assert_rc       "a green marker beside a TIMEOUT row is REFUSED (rc 2), never green" "$RC" "2"
assert_contains "…and the machine line carries NO verdict" "$LINE" "verdict=none class=marker-rows-contradiction"
assert_contains "…and the row is counted, so the refusal can name it" "$LINE" "timeout=1"
assert_contains "…and it says no runner here can emit that pair" "$OUT" "No runner in this tree can produce that"
# THE SAME ARM ON THE OTHER ROW TYPE. This comment used to claim the substitution
# "keeps the row count WRONG" and "still lands on rows-mismatch", and the code
# below does NEITHER: a substitution PRESERVES the count, and the assertion names
# marker-rows-contradiction. Both claims were false — the label and the
# computation beneath it had drifted apart, in the block written to close a label
# defect, and the skeptic caught it. It is worth keeping for what it ACTUALLY
# does: a FAIL row reaches the new arm exactly as a TIMEOUT row does, so the arm
# is not keyed to one spelling.
sed 's|^  PASS  test-bv-ok-b\.sh .*|  FAIL  test-bv-ok-b.sh                               2.00s  rc=1|' \
    "$WORK/green.log" > "$WORK/green-with-fail.log"
_read "$WORK/green-with-fail.log"
assert_rc       "a green marker beside a FAIL row is REFUSED too" "$RC" "2"
assert_contains "…as the same class, so the arm is not keyed to TIMEOUT alone" "$LINE" "class=marker-rows-contradiction"
# THE DISCRIMINATOR the comment above used to promise, and the only case that
# makes the ARM ORDER checkable rather than asserted: make BOTH conditions true —
# a green marker, a FAIL row, AND a row count that no longer matches the header.
# rows-mismatch runs first, so it must win. Without this, the two arms are only
# ever exercised one at a time and nothing pins which precedes which.
sed -e 's|^  PASS  test-bv-ok-b\.sh .*|  FAIL  test-bv-ok-b.sh                               2.00s  rc=1|' \
    -e '/^  PASS  test-bv-ok-a\.sh /d' \
    "$WORK/green.log" > "$WORK/green-fail-and-short.log"
_read "$WORK/green-fail-and-short.log"
assert_rc       "both conditions true: still rc 2" "$RC" "2"
assert_contains "…and ROWS-MISMATCH wins, as the arm order predicts" "$LINE" "class=rows-mismatch"
assert_contains "…with the counts that make it the right answer" "$LINE" "selected=2 reported=1 pass=0 fail=1"
# MUST-NOT-FLIP: the real green log has neither, and is still green.
_read "$WORK/green.log"
assert_rc "MUST-NOT-FLIP: the untouched green log is still rc 0" "$RC" "0"

# WHY THAT REFUSAL IS A GUARD AGAINST DRIFT AND NOT AGAINST A LIVE DEFECT — as a
# TEST, not as a claim in a comment. The refusal's rationale rests on "no runner
# in this tree can emit a green marker beside a TIMEOUT row", and that is a claim
# about a PRODUCER, i.e. exactly the kind that rots. It was handed to me by a
# reader of the two accounting arms; I re-derived it by OBSERVING each arm, and it
# is pinned here so it cannot rot silently. The ledger arm is the one the case
# above does not reach: `_band` passes no `--state`.
_band "$WORK/to-nonledger.log" --jobs 2 "$FX/test-bv-ok-a.sh" "$FX/test-bv-slow.sh"
assert_rc       "REACHABILITY, non-ledger arm: a real TIMEOUT forces runner rc 1" "$BAND_RC" "1"
_band "$WORK/to-ledger.log" --state "$WORK/reach-ledger.tsv" --jobs 2 "$FX/test-bv-ok-a.sh" "$FX/test-bv-slow.sh"
assert_rc       "REACHABILITY, LEDGER arm: the same, so neither arm can emit rc 0 with a TIMEOUT" "$BAND_RC" "1"
assert_contains "…and the ledger arm's marker says so too" \
    "$(sed -n '$p' "$WORK/to-ledger.log")" "=== run-tests: END rc=1 (COMPLETE and RED — 1 TIMED OUT (no verdict about them), 0 failed) ==="

echo "=== 2b. a row-less census red names WHICH census defect it is (#1620, #1626 skeptic) ==="
# Two REAL logs from a copy of this runner in a fixture repository (the census
# walks a git tree's tracked set, so it cannot be taken over $FX). The census
# reddens for two reasons fixed in two different places; the reader used to call
# both "UNREACHABLE-SUITE", which sent a reader hunting for a lost suite when the
# only defect was a manifest row.
CR="$WORK/census-repo"
mkdir -p "$CR/monitor/watcher" "$CR/monitor/newdir"
cp "$RUNNER" "$CR/monitor/watcher/run-tests.sh"
cp "$_self_dir/../_tmux_socket.sh" "$_self_dir/../repo-root.sh" "$CR/monitor/"
cp "$FX/test-bv-ok-a.sh" "$CR/monitor/watcher/test-fx-ok.sh"
git -C "$CR" init -q || th_abort "git init $CR"
th_require_fixture_repo "$CR" "band-verdict census fixture"
_cr_commit() { git -C "$CR" add -A && git -C "$CR" -c user.email=fixture@example.invalid -c user.name=fixture commit -qm "$1" || th_abort "fixture commit: $1"; }
_cr_band() { env -u NEXUS_ROOT -u NEXUS_LOCALS bash "$CR/monitor/watcher/run-tests.sh" --timeout 2 --filter fx-ok </dev/null >"$1" 2>&1; BAND_RC=$?; }
# (a) a STALE manifest row, and nothing unreachable: the row names a WALKED suite.
printf 'monitor/watcher/test-fx-ok.sh|walked anyway\n' > "$CR/monitor/watcher/census-exclusions.manifest"
_cr_commit stale-row
_cr_band "$WORK/census-defect.log"
assert_rc "control: a stale census row reddens the real run" "$BAND_RC" "1"
_read "$WORK/census-defect.log"
assert_rc           "a census-manifest red is a VERDICT, red (rc 1)"                   "$RC" "1"
assert_contains     "…and the sentence names a CENSUS-EXCLUSION defect, with its count" "$OUT" "CENSUS-EXCLUSION-DEFECT (1 manifest row(s) REFUSED or STALE)"
assert_not_contains "…and does NOT call it an unreachable suite"                       "$OUT" "UNREACHABLE-SUITE"
# (b) the other reason: a tracked suite no root walks, and a clean manifest (none).
git -C "$CR" rm -q monitor/watcher/census-exclusions.manifest || th_abort "git rm manifest"
cp "$FX/test-bv-ok-a.sh" "$CR/monitor/newdir/test-fx-lost.sh"
_cr_commit unreachable
_cr_band "$WORK/census-unreach.log"
_read "$WORK/census-unreach.log"
assert_contains     "an unreachable suite is named UNREACHABLE-SUITE, with its count" "$OUT" "UNREACHABLE-SUITE (1 tracked suite(s) no root walks)"
assert_not_contains "MUST-NOT-FLIP: …and not a census-exclusion defect"                                 "$OUT" "CENSUS-EXCLUSION-DEFECT"

echo "=== 3. could not look is never an answer ==="
: > "$WORK/empty.log";            _read "$WORK/empty.log";   assert_rc "an EMPTY log is REFUSED (rc 2)" "$RC" "2"
echo "hello" > "$WORK/notalog";   _read "$WORK/notalog";     assert_rc "a file with no runner header is REFUSED (rc 2)" "$RC" "2"
cat "$WORK/green.log" "$WORK/green.log" > "$WORK/twice.log"; _read "$WORK/twice.log"; assert_rc "two runs in one file are REFUSED, not summed (rc 2)" "$RC" "2"
_read "$WORK/no-such-file";       assert_rc "an unreadable path is REFUSED (rc 2)" "$RC" "2"
bash "$READER" >/dev/null 2>&1;   assert_rc "no argument is usage (rc 3)" "$?" "3"

echo "=== 4. THE INVARIANT: the line says green only at rc 0, red only at rc 1 ==="
_viol=0
for _l in "$WORK"/*.log; do
    _read "$_l"
    _v=$(printf '%s' "$LINE" | sed -n 's/^verdict=\([a-z]*\) .*/\1/p')
    case "$RC:$_v" in 0:green|1:red|4:none|2:none|2:) ;; *) _viol=$(( _viol + 1 )); echo "  violation: $_l rc=$RC verdict=${_v:-<none>}" >&2 ;; esac
done
assert_eq "no log makes the machine line disagree with the exit code" "$_viol" "0"

EXPECTED_ASSERTIONS=48
TOTAL_ASSERTIONS=$(( PASS + FAIL + ${SKIP:-0} ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
