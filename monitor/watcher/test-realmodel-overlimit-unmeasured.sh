#!/usr/bin/env bash
# A sub-check that could not run is UNMEASURED — never a pass.
# (your-org/nexus-code#1530)
#
# Run: bash monitor/watcher/test-realmodel-overlimit-unmeasured.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS FILE EXISTS. `test-integration/test-realmodel-overlimit.sh` needs a
# real `claude` binary, so its blank-frame branch cannot be driven in the unit
# band — and in 88 recorded real runs it was never taken at all. That branch
# printed a `note:` and let the scenario finish GREEN with its DISCRIMINATING
# sub-check (the renderer scrape: what production reads WITHOUT a stamp) never
# run. `cc-harness/gate.sh` reads that scenario, so a blank frame on the wrong
# day was a GATE GREEN resting on the stamp path alone.
#
# The sub-check now lives in `test-integration/_renderer_scrape_check.sh` with
# THREE outcomes, and this suite drives all three against stubbed capture and
# classifier functions: no binary, no tmux, no sleep.
#
# WHAT THIS SUITE CANNOT REACH, declared (skills/nexus.self-fix): whether the
# REAL frame paints within the bound. That is a property of the binary and the
# host; §4 pins only that the scenario is WIRED to the three-outcome check and
# can no longer leave by 0 when it was unmeasured. The gate's half — rc 69 is
# RED and named UNMEASURED — is pinned in test-cc-gate.sh (3b). SCOPE: that is
# gate.sh's reading of 69. run-tests.sh reads 69 as ENVSKIP (reported, not a
# pass, not red), so the cc-harness CI job's band stays green on an unmeasured
# scrape — your-org/nexus-code#1563, not this suite's claim (skeptic F3 on #1558).

set -uo pipefail
_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$_test_dir/test-integration/_renderer_scrape_check.sh"
SCENARIO="$_test_dir/test-integration/test-realmodel-overlimit.sh"

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "monitor/watcher/test-integration/_renderer_scrape_check.sh" \
                  "monitor/watcher/test-integration/test-realmodel-overlimit.sh" \
                  "monitor/watcher/test-realmodel-overlimit-unmeasured.sh"
}
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=22   # counted BEFORE the census assertion itself

[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rsc-$$-XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=monitor/watcher/test-integration/_renderer_scrape_check.sh
. "$LIB"

# The stubs. `rsc_check` calls `cch_capture` inside `$( )`, a SUBSHELL, so the
# capture count lives in a FILE — a shell variable would reset on every call and
# every frame would be "the first".
NOTICE="You've hit your weekly limit · resets 3am (America/Los_Angeles)"
PAINT_ON=1          # the capture number from which the frame carries the notice; 0 = never
CLASSIFIER_SAYS="over-limit"
cch_capture() {
    local n; n=$(( $(cat "$WORK/captures" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/captures"
    if (( PAINT_ON > 0 && n >= PAINT_ON )); then printf 'some transcript\n%s\n> \n' "$NOTICE"; else printf '\n\n\n'; fi
}
cch_pane_state() {
    echo "$*" >> "$WORK/classifier.calls"
    printf 'state=%s active=0 window=%s\n' "$CLASSIFIER_SAYS" "$1"
}
reset() { rm -f "$WORK/captures" "$WORK/classifier.calls"; }
export RSC_INTERVAL=0   # the unit suite must not sleep

# ── §1  painted at once ─────────────────────────────────────────────────────
echo '=== §1 the frame painted: the classifier is asked, and its answer decides ==='
reset; PAINT_ON=1; CLASSIFIER_SAYS="over-limit"
rsc_check 3 "$WORK/state" "$WORK/no-such-stamp.json"
assert_eq "§1 painted + over-limit -> pass" "$RSC_VERDICT" "pass"
assert_eq "§1 …on the FIRST capture" "$RSC_ATTEMPTS_USED" "1"
assert_contains "§1 the classifier was asked WITHOUT the stamp (the missing-stamp path is passed through)" \
    "$(cat "$WORK/classifier.calls")" "--over-limit-file $WORK/no-such-stamp.json"
reset; PAINT_ON=1; CLASSIFIER_SAYS="idle"
rsc_check 3 "$WORK/state" "$WORK/no-such-stamp.json"
assert_eq "§1 painted + the scrape says idle -> FAIL (the renderer-drift red this sub-check exists for)" "$RSC_VERDICT" "fail"
assert_eq "§1 …and the wrong state is kept for the diagnostic" "$RSC_STATE" "idle"

# ── §2  the retry earns its keep ────────────────────────────────────────────
echo '=== §2 a frame that paints LATE is measured, not skipped ==='
reset; PAINT_ON=3; CLASSIFIER_SAYS="over-limit"
RSC_ATTEMPTS=5 rsc_check 3 "$WORK/state" "$WORK/no-such-stamp.json"
assert_eq "§2 blank, blank, painted -> pass" "$RSC_VERDICT" "pass"
assert_eq "§2 …on the THIRD capture — the single capture the old code took would have skipped it" "$RSC_ATTEMPTS_USED" "3"

# ── §3  it never paints ─────────────────────────────────────────────────────
echo '=== §3 a frame that NEVER paints: UNMEASURED — not pass, not fail ==='
reset; PAINT_ON=0
RSC_ATTEMPTS=4 rsc_check 3 "$WORK/state" "$WORK/no-such-stamp.json"
assert_eq "§3 blank throughout -> unmeasured" "$RSC_VERDICT" "unmeasured"
assert_eq "§3 …after exactly the bound, no more (the wait is BOUNDED)" "$RSC_ATTEMPTS_USED" "4"
assert_no_file "§3 …and the classifier was never asked about a frame that was not there" "$WORK/classifier.calls"
reset; PAINT_ON=0
RSC_ATTEMPTS=garbage rsc_check 3 "$WORK/state" "$WORK/no-such-stamp.json"
assert_eq "§3 a non-numeric bound falls back to the default 20, it does not loop forever or zero times" "$RSC_ATTEMPTS_USED" "20"

# ── the exit code: FAIL outranks UNMEASURED outranks green ──────────────────
echo '=== §3b the scenario exit code ==='
assert_eq "§3b no failure, measured -> 0"               "$(rsc_exit_code 0 0)" "0"
assert_eq "§3b no failure, UNMEASURED -> 69 (ENVSKIP), never 0" "$(rsc_exit_code 0 1)" "69"
assert_eq "§3b a failure, measured -> 1"                "$(rsc_exit_code 2 0)" "1"
assert_eq "§3b a failure AND unmeasured -> 1: a red that WAS measured is not softened" "$(rsc_exit_code 1 1)" "1"

# ── §4  the scenario is WIRED to it ─────────────────────────────────────────
# Static, because the scenario needs a real binary. Read as CODE, comments
# stripped: the old `note:` text must be gone from what EXECUTES, and the
# scenario's header is free to go on describing it.
echo '=== §4 test-realmodel-overlimit.sh uses the three-outcome check and cannot leave by 0 when unmeasured ==='
code=$(grep -v -E '^[[:space:]]*#' "$SCENARIO")
assert_contains     "§4 the scenario sources the check"            "$code" '_renderer_scrape_check.sh'
assert_contains     "§4 …calls it"                                 "$code" 'rsc_check "$IDX"'
assert_contains     "§4 …has an UNMEASURED arm that records the outcome" "$code" 'UNMEASURED=1'
assert_contains     "§4 …and derives its exit from FAIL and UNMEASURED"  "$code" 'rsc_exit_code "$FAIL" "$UNMEASURED"'
assert_contains     "§4 …leaving by 69"                            "$code" 'exit 69'
assert_not_contains "§4 the branch that read 'could not measure' as fine is GONE" "$code" 'not exercisable this run'
# ORDER: the 69 exit must sit BEFORE `th_summary_and_exit`, which exits 0 on a
# run with no failure — after it, the unmeasured arm would be unreachable.
l69=$(grep -n -F 'exit 69' "$SCENARIO" | tail -n 1 | cut -d: -f1)
lsum=$(grep -n -E '^th_summary_and_exit' "$SCENARIO" | tail -n 1 | cut -d: -f1)
assert_eq "§4 the unmeasured exit precedes the green exit (else it is unreachable)" \
    "$(( ${l69:-0} > 0 && ${lsum:-0} > ${l69:-0} ))" "1"

# ASSERTION CENSUS — the exact-count guard (your-org/nexus-code#807).
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
