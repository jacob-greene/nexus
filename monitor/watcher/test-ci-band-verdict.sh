#!/usr/bin/env bash
# test-ci-band-verdict.sh — CI's band-verdict step renders a band that did not
# finish as NO VERDICT, distinct from a RED, and never as green
# (your-org/nexus-code#1474, the CI half).
#
# EVERY LOG JUDGED HERE IS WRITTEN BY THE REAL RUNNER, and the truncated ones
# are truncated the way CI truncates them: `timeout` over the whole band, the
# exact wrapper tests.yml puts around each run step. A hand-typed `END rc=4`
# would test the reader against its author's memory of the runner; this tests
# it against what the runner does when the bound fires.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_self_dir/_test_helpers.sh"

CIV="$_self_dir/ci-band-verdict.sh"
th_scrub_inherited_runner_env "$_self_dir/run-tests.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cibandverdict.XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
# A COPY of the runner, outside any repository. In place, its tree-drift check
# watches THIS checkout, and a band launched while anyone edits it ends
# `END rc=5` (tree-changed) — measured here, 2 of 3 runs, which turned the
# complete-red control into a no-verdict. Outside a repository the runner
# reports `ref=UNKNOWN` and skips the check; nothing this suite asserts depends on it.
mkdir -p "$WORK/rt/monitor/watcher"
cp "$_self_dir/run-tests.sh" "$WORK/rt/monitor/watcher/" || th_abort "copy runner"
cp "$_self_dir/../_tmux_socket.sh" "$_self_dir/../repo-root.sh" "$WORK/rt/monitor/" || th_abort "copy runner deps"
RUNNER="$WORK/rt/monitor/watcher/run-tests.sh"
FX="$WORK/fx"; mkdir -p "$FX"
export NEXUS_TEST_STATE_DIR="$WORK/state"

printf '#!/usr/bin/env bash\necho "  PASS: fine"\necho "=== summary: 1 passed, 0 failed ==="\necho "ALL TESTS PASSED"\nexit 0\n' > "$FX/test-cbv-ok-a.sh"
cp "$FX/test-cbv-ok-a.sh" "$FX/test-cbv-ok-b.sh"
printf '#!/usr/bin/env bash\necho "working"\nsleep 60\n' > "$FX/test-cbv-slow.sh"
printf '#!/usr/bin/env bash\necho "  FAIL: broken — got x want y" >&2\nexit 1\n' > "$FX/test-cbv-red.sh"
chmod +x "$FX"/*.sh

# <log> <bound-seconds|none> <runner args…> ; sets RUN_RC. The CI shape: the
# runner under `timeout`, stdout+stderr into the band log. The 15 s bound is
# sized for a loaded host: the quick fixture must finish inside it (a 4 s bound
# at load 39 did not) and the 60 s one must not.
_band() {
    local _log="$1" _bound="$2"; shift 2
    RUN_RC=0
    if [[ "$_bound" == none ]]; then
        env -u NEXUS_ROOT -u NEXUS_LOCALS bash "$RUNNER" "$@" </dev/null >"$_log" 2>&1 || RUN_RC=$?
    else
        env -u NEXUS_ROOT -u NEXUS_LOCALS timeout --signal=TERM --kill-after=20s "${_bound}s" \
            bash "$RUNNER" "$@" </dev/null >"$_log" 2>&1 || RUN_RC=$?
    fi
}
# <log> <run-rc> ; sets OUT, RC, SUM (the step-summary text)
_civ() {
    local _sum="$WORK/summary.$RANDOM"; : > "$_sum"
    RC=0
    OUT=$(GITHUB_STEP_SUMMARY="$_sum" bash "$CIV" --band "unit suite (bash, jobs 4)" --run-rc "$2" "$1" 2>&1) || RC=$?
    SUM=$(cat "$_sum")
}

echo "=== 1. complete bands: GREEN and RED are verdicts ==="
_band "$WORK/green.log" none --timeout 5 --jobs 2 "$FX/test-cbv-ok-a.sh" "$FX/test-cbv-ok-b.sh"
assert_rc "control: the runner calls two passing fixtures green" "$RUN_RC" "0"
_civ "$WORK/green.log" "$RUN_RC"
assert_rc           "GREEN -> rc 0 (the only zero)" "$RC" "0"
assert_contains     "…summary says GREEN with the counts" "$SUM" "GREEN**: 2 of 2 selected suites reported"
assert_not_contains "…and no error annotation" "$OUT" "::error"

_band "$WORK/red.log" none --timeout 5 --jobs 2 "$FX/test-cbv-ok-a.sh" "$FX/test-cbv-red.sh"
_civ "$WORK/red.log" "$RUN_RC"
assert_rc       "RED -> rc 1" "$RC" "1"
assert_contains "…annotated with the RED title" "$OUT" "::error title=RED::unit suite (bash, jobs 4): 1 suite(s) failed an assertion, 0 timed out"
assert_contains "…and the summary calls it RED" "$SUM" "RED**: 1 failed, 0 timed out; 2 of 2 selected"
assert_not_contains "MUST-NOT-FLIP: a complete red is NOT titled NO VERDICT" "$OUT" "title=NO VERDICT"

echo "=== 2. the CI bound fires at --jobs 4: the runner's own END rc=4 is NO VERDICT ==="
_band "$WORK/bound-j4.log" 15 --jobs 4 "$FX/test-cbv-ok-a.sh" "$FX/test-cbv-slow.sh"
assert_rc       "control: timeout reports its own 124, not the runner's 4" "$RUN_RC" "124"
assert_contains "control: the runner trapped the group TERM and printed END rc=4" "$(sed -n '$p' "$WORK/bound-j4.log")" "=== run-tests: END rc=4 ("
_civ "$WORK/bound-j4.log" "$RUN_RC"
assert_rc       "bound fired -> rc 4, not 0 and not 1" "$RC" "4"
assert_contains "…titled NO VERDICT" "$OUT" "::error title=NO VERDICT::unit suite (bash, jobs 4): NO VERDICT (truncated/cancelled band), not a test failure"
assert_contains "…with reported/selected counts" "$OUT" "1 of 2 selected suites reported"
assert_contains "…and the summary names it" "$SUM" "no verdict** (truncated/cancelled band), not a test failure: 1 of 2 selected suites reported"
assert_not_contains "MUST-NOT-FLIP: a truncated band is NOT titled RED" "$OUT" "title=RED"
_civ "$WORK/bound-j4.log" ""
assert_rc "…and it is NO VERDICT from the LOG alone, with no run rc (the step was killed first)" "$RC" "4"

echo "=== 3. the bound fires at --jobs 1: a marker that says COMPLETE RED is overruled ==="
_band "$WORK/bound-j1.log" 15 --jobs 1 "$FX/test-cbv-ok-a.sh" "$FX/test-cbv-slow.sh"
assert_rc "control: timeout fired" "$RUN_RC" "124"
bv=$(bash "$_self_dir/band-verdict.sh" "$WORK/bound-j1.log" 2>/dev/null | sed -n 1p)
assert_contains "control: band-verdict ALONE reads this log as a complete red (the TERM-killed suite became a FAIL row)" "$bv" "verdict=red class=complete"
_civ "$WORK/bound-j1.log" "$RUN_RC"
assert_rc       "with the run rc, the fired bound makes it NO VERDICT (rc 4)" "$RC" "4"
assert_contains "…naming the override" "$OUT" "bound-fired (marker said complete)"
assert_contains "…and listing the FAIL row the stop itself produced" "$OUT" "FAIL rows recorded before the stop: test-cbv-slow.sh rc=143"
_civ "$WORK/bound-j1.log" "0"
assert_rc "MUST-NOT-FLIP: a run rc of 0 does not trigger the override" "$RC" "1"

echo "=== 4. no log, a contradictory log, bad usage ==="
_civ "$WORK/no-such.log" ""
assert_rc       "no band log -> rc 4" "$RC" "4"
assert_contains "…titled NO VERDICT, saying the band never ran" "$OUT" "::error title=NO VERDICT::unit suite (bash, jobs 4): no band log at"
cat "$WORK/green.log" "$WORK/green.log" > "$WORK/twice.log"
_civ "$WORK/twice.log" "0"
assert_rc       "a log band-verdict REFUSES -> rc 2" "$RC" "2"
assert_contains "…titled VERDICT REFUSED with the reason" "$OUT" "::error title=VERDICT REFUSED::unit suite (bash, jobs 4): band-verdict.sh REFUSED to read the band log (band-verdict.sh: REFUSED"
RC=0; bash "$CIV" --run-rc x "$WORK/green.log" >/dev/null 2>&1 || RC=$?
assert_rc "a non-numeric --run-rc is usage (rc 2), never a verdict" "$RC" "2"
RC=0; bash "$CIV" >/dev/null 2>&1 || RC=$?
assert_rc "no log argument is usage (rc 2)" "$RC" "2"

echo "=== 5. workflow-command escaping: a newline or % in the message cannot forge a second command ==="
RC=0; OUT=$(bash "$CIV" --band $'x%y\n::error title=RED::forged' "$WORK/no-such.log" 2>&1) || RC=$?
assert_eq "the whole annotation is ONE line" "$(printf '%s\n' "$OUT" | grep -c '^::')" "1"
assert_contains "…with % and LF encoded" "$OUT" "x%25y%0A::error title=RED::forged"

EXPECTED_ASSERTIONS=30
TOTAL_ASSERTIONS=$(( PASS + FAIL + ${SKIP:-0} ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
