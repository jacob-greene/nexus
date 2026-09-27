#!/usr/bin/env bash
# A KILLED run must not read as a result. (your-org/nexus-code#1474, local form)
#
# Run: bash monitor/watcher/test-run-tests-runner-signal.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS FILE EXISTS. `#1474` is about CI: a band killed at its 40-minute
# ceiling is `cancelled`, carries no verdict, and renders as `fail`. With the
# CI budget gone the LOCAL band is the only evidence there is, and the same
# defect was sitting in it, worse. Measured at `d5874b26`, six 4-second
# fixtures, the RUNNER sent SIGTERM at 6 s:
#
#   --jobs 1   rc 143, the log: 1 PASS line, 0 FAIL lines, no summary, no banner
#   --jobs 4   rc 143, and the dispatch children LIVED ON as orphans, appending
#              PASS lines to the log of a dead runner — 6 of 6 PASS, 0 FAIL, no
#              summary. A killed run that reads as a complete green.
#
# Both halves of the fix are pinned here, each against the behaviour it
# replaced:
#
#   the TRAPS       the runner records TERM/INT/HUP instead of dying. A group
#                   signal now reaches the `#1083` banner and exit 4; a pid-only
#                   signal stops a serial run at the next test boundary (exit 4)
#                   and is deferred past a parallel batch (no orphans, complete
#                   verdict, and a NOTE saying the signal arrived).
#   the END MARKER  for the death no trap can see. §4 SIGKILLs the runner and
#                   pins that the marker is ABSENT — the control without which
#                   "the marker is present" would be a property of every log.
#
# WHAT THIS SUITE CANNOT REACH (skills/nexus.self-fix, "the axis your harness
# cannot reach"): every runner here is launched as a BACKGROUND job of a
# non-interactive shell, so it has no controlling terminal and SIGINT is
# ignored on entry; the INT trap is installed and not driven. TERM is the
# signal `timeout`, Slurm and a harness stop actually send.

set -uo pipefail
_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$_test_dir/run-tests.sh"

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "monitor/watcher/run-tests.sh" "monitor/watcher/test-run-tests-runner-signal.sh"
}
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=51   # counted BEFORE the census assertion itself

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rtsig-$$-XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# mk_fixtures <dir> <n> <seconds> — n passing tests, each recording that it
# STARTED and that it FINISHED. The done-markers are how "did work continue
# after the runner exited" is asked: by FILE, never by matching process argv —
# a predicate keyed on a string matches every agent whose prompt quotes it.
mk_fixtures() {
    local dir="$1" n="$2" secs="$3" i
    mkdir -p "$dir/marks"
    for (( i = 1; i <= n; i++ )); do
        cat > "$dir/test-sig$i.sh" <<EOF
#!/usr/bin/env bash
: > "$dir/marks/started.$i"
sleep $secs
: > "$dir/marks/done.$i"
echo "ALL TESTS PASSED (1 assertions)"
EOF
    done
}
count() { find "$1/marks" -name "$2.*" 2>/dev/null | grep -c .; }

# launch <dir> <log> <args…> — start the runner in the background, wait until
# the first fixture has STARTED (so the signal lands mid-sweep on any host,
# however loaded), and leave its pid in RPID.
RPID=0
LAUNCH_PREFIX=()      # §3 sets this to `setsid`, so the runner LEADS a process group
launch() {
    local dir="$1" log="$2"; shift 2
    NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$dir/state" \
        "${LAUNCH_PREFIX[@]}" bash "$RUNNER" "$@" "$dir"/test-sig*.sh > "$log" 2>&1 < /dev/null &
    RPID=$!
    local i
    for (( i = 0; i < 600; i++ )); do
        [[ "$(count "$dir" started)" -ge 1 ]] && return 0
        kill -0 "$RPID" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}
last_line() { tail -n 1 "$1"; }

# ── §1  SERIAL, signal to the runner pid alone ──────────────────────────────
echo '=== §1 --jobs 1: a TERMed runner stops at the test boundary and SAYS it measured a subset ==='
D="$WORK/s1"; mk_fixtures "$D" 3 2
launch "$D" "$D/log" --jobs 1 || echo "  (launch did not reach a started fixture)" >&2
kill -TERM "$RPID" 2>/dev/null; wait "$RPID"; rc=$?
assert_eq       "§1 the runner exits 4 (NOT A VERDICT), not 143 and not 0" "$rc" "4"
assert_contains "§1 the cause is named BEFORE the accounting" "$(cat "$D/log")" "THE RUNNER RECEIVED SIGTERM"
assert_contains "§1 the shortfall is named" "$(cat "$D/log")" "selected test(s) UNREPORTED"
assert_contains "§1 the LAST line is the END marker, and it says rc=4" "$(last_line "$D/log")" "=== run-tests: END rc=4 (NOT A VERDICT"
assert_eq       "§1 the sweep really stopped: fewer tests started than were selected" \
    "$(( $(count "$D" started) < 3 ))" "1"
assert_eq       "§1 nothing was left running: every test that started also finished" \
    "$(count "$D" started)" "$(count "$D" done)"

# ── §1b  THE LOCAL GATE IS NOT EVALUATED ON A PARTIAL RUN (skeptic F2, #1558) ─
# A known-local-red row makes a failing set "CLEAR for the local gate" — and that
# sentence was printed on a run cut short by a signal, about the subset it had
# measured, one line above the run's own NOT A VERDICT.
echo '=== §1b a known-local-red failure + a TERM: the gate line says NOT EVALUATED, never CLEAR ==='
D="$WORK/s1b"; mk_fixtures "$D" 3 2
printf '#!/usr/bin/env bash\necho "  FAIL: planted"; exit 1\n' > "$D/test-sig0.sh"
# The runner tags a failure `<parent-dir>/<file>`, so the row names the fixture dir.
printf '%s/test-sig0.sh\tload\t#1317\tplanted for the gate check\n' "$(basename "$D")" > "$D/klr.tsv"
NEXUS_KNOWN_LOCAL_RED="$D/klr.tsv" launch "$D" "$D/log" --jobs 1 || echo "  (launch did not reach a started fixture)" >&2
kill -TERM "$RPID" 2>/dev/null; wait "$RPID"; rc=$?
assert_eq       "§1b the run is NOT A VERDICT (rc 4)" "$rc" "4"
assert_contains "§1b the gate line says NOT EVALUATED and names the cause" "$(cat "$D/log")" "LOCAL GATE: NOT EVALUATED — this run is INCOMPLETE (the runner received SIGTERM"
assert_not_contains "§1b …and never CLEAR" "$(cat "$D/log")" "CLEAR for the local gate"
# CONTROL: the same planted failure on an UNDISTURBED run is still partitioned and cleared.
D2="$WORK/s1c"; mk_fixtures "$D2" 1 0; cp "$D/test-sig0.sh" "$D2/"
printf '%s/test-sig0.sh\tload\t#1317\tplanted for the gate check\n' "$(basename "$D2")" > "$D2/klr.tsv"
NEXUS_KNOWN_LOCAL_RED="$D2/klr.tsv" NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$D2/state" \
    bash "$RUNNER" --jobs 1 "$D2"/test-sig*.sh > "$D2/log" 2>&1 < /dev/null
rc=$?
assert_eq       "§1b CONTROL: undisturbed, the run is RED (rc 1)" "$rc" "1"
assert_contains "§1b CONTROL: …and the known-local-red partition still CLEARS it" "$(cat "$D2/log")" "CLEAR for the local gate"

# ── §1c  THE OTHER TWO ARMS OF "INCOMPLETE" (skeptic round 2, G3) ─────────────
# §1b isolates the runner-signal arm only; a mutant deleting the budget arm or
# the signalled-children arm survived it. Each gets a case in which IT is the
# reason — no runner signal involved.
echo '=== §1c a BUDGET stop with a known-local-red failure: NOT EVALUATED (exit 3) ==='
D="$WORK/s1c-budget"; mk_fixtures "$D" 2 2
printf '#!/usr/bin/env bash\necho "  FAIL: planted"; exit 1\n' > "$D/test-sig0.sh"
printf '%s/test-sig0.sh\tload\t#1317\tplanted\n' "$(basename "$D")" > "$D/klr.tsv"
NEXUS_KNOWN_LOCAL_RED="$D/klr.tsv" NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$D/state" \
    bash "$RUNNER" --jobs 1 --max-seconds 1 "$D"/test-sig*.sh > "$D/log" 2>&1 < /dev/null
rc=$?
assert_eq       "§1c the budget stopped the run (rc 3)" "$rc" "3"
assert_contains "§1c the gate line names the budget" "$(cat "$D/log")" "LOCAL GATE: NOT EVALUATED — this run is INCOMPLETE (the --max-seconds budget"
assert_not_contains "§1c budget: …and never CLEAR" "$(cat "$D/log")" "CLEAR for the local gate"

echo '=== §1c a dispatch CHILD signalled (runner untouched) with a known-local-red failure: NOT EVALUATED (exit 4) ==='
D="$WORK/s1c-child"; mk_fixtures "$D" 2 1
printf '#!/usr/bin/env bash\necho "  FAIL: planted"; exit 1\n' > "$D/test-sig0.sh"
# The fixture TERMs its own parent — the `bash -c` dispatch child at --jobs 2 —
# which records itself and leaves by exit 90 (#1083). The runner is not signalled.
printf '#!/usr/bin/env bash\nkill -TERM "$PPID"; sleep 2; echo "ALL TESTS PASSED (1 assertions)"\n' > "$D/test-sig5.sh"
printf '%s/test-sig0.sh\tload\t#1317\tplanted\n' "$(basename "$D")" > "$D/klr.tsv"
NEXUS_KNOWN_LOCAL_RED="$D/klr.tsv" NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$D/state" \
    bash "$RUNNER" --jobs 2 "$D"/test-sig*.sh > "$D/log" 2>&1 < /dev/null
rc=$?
assert_eq       "§1c a signalled dispatch child makes the run NOT A VERDICT (rc 4)" "$rc" "4"
assert_contains "§1c the gate line names the signalled child" "$(cat "$D/log")" "LOCAL GATE: NOT EVALUATED — this run is INCOMPLETE (1 dispatch child(ren) killed by a signal)"
assert_not_contains "§1c child: …and never CLEAR" "$(cat "$D/log")" "CLEAR for the local gate"

# ── §1d  --state/--resume: the gate partitions the LEDGER'S failing set (G2) ──
# Leg 1 records an UNEXPLAINED red and budget-stops; leg 2 resumes and records a
# known red. The whole sweep is 1 unexplained + 1 known: BLOCKED — not "1 of 1
# CLEAR" from the resuming leg's own sidecars.
echo '=== §1d a resumed sweep is partitioned as a WHOLE, not per invocation ==='
D="$WORK/s1d"; mk_fixtures "$D" 1 2
printf '#!/usr/bin/env bash\necho "  FAIL: unexplained"; exit 1\n' > "$D/test-sig0.sh"
printf '#!/usr/bin/env bash\necho "  FAIL: known"; exit 1\n' > "$D/test-sig9.sh"
printf '%s/test-sig9.sh\tload\t#1317\tplanted\n' "$(basename "$D")" > "$D/klr.tsv"
NEXUS_KNOWN_LOCAL_RED="$D/klr.tsv" NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$D/state" \
    bash "$RUNNER" --jobs 1 --state "$D/ledger.tsv" --max-seconds 1 "$D"/test-sig*.sh > "$D/log1" 2>&1 < /dev/null
rc=$?
assert_eq       "§1d leg 1 budget-stops (rc 3) with the unexplained red recorded" "$rc" "3"
assert_contains "§1d leg 1: NOT EVALUATED" "$(cat "$D/log1")" "LOCAL GATE: NOT EVALUATED"
NEXUS_KNOWN_LOCAL_RED="$D/klr.tsv" NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$D/state" \
    bash "$RUNNER" --jobs 1 --state "$D/ledger.tsv" --resume "$D"/test-sig*.sh > "$D/log2" 2>&1 < /dev/null
rc=$?
assert_eq       "§1d leg 2 completes RED (rc 1)" "$rc" "1"
assert_contains "§1d leg 2 partitions BOTH ledger reds: 1 of 2 unexplained" "$(cat "$D/log2")" "UNEXPLAINED (1 of 2 failures"
assert_contains "§1d …and BLOCKS" "$(cat "$D/log2")" "LOCAL GATE: BLOCKED"
assert_not_contains "§1d …never '1 of 1 CLEAR' from this leg's sidecars alone" "$(cat "$D/log2")" "CLEAR for the local gate"

# ── §1e  A RUN WHOSE ACCOUNTING BROKE IS NOT A COMPLETE FAILING SET (G11, #1564) ─
# The partition used to re-derive "is this run complete" from its OWN copy of the
# exit section's conditions, and `_accounting_broken` was in the exit section
# only: a run that LOST a verdict (exit 1, #877) still had its surviving failing
# set partitioned, and a known-local-red row then printed `CLEAR for the local
# gate` over a set missing whatever the lost verdict was. The class is now
# decided once and both readers use it. Driven at `--jobs 2` (the serial arm
# ABORTS at 97 on a refused mktemp; the parallel arm is the one that records a
# lost verdict, #877) with a `mktemp -p` shim keyed on the DISPATCH CHILD'S ARGV
# — its parent's cmdline names the test — so it refuses test-sig1.sh's sidecar
# base and nothing else, whatever order the two children start in: the planted
# KNOWN red records, the other fixture loses its verdict.
echo '=== §1e a lost verdict + a known-local-red failure: NOT EVALUATED, never CLEAR (rc 1) ==='
D="$WORK/s1e"; mk_fixtures "$D" 1 0; mkdir -p "$D/bin"
printf '#!/usr/bin/env bash\necho "  FAIL: planted"; exit 1\n' > "$D/test-sig0.sh"
printf '%s/test-sig0.sh\tload\t#1317\tplanted\n' "$(basename "$D")" > "$D/klr.tsv"
REAL_MKTEMP=$(command -v mktemp)
{
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do'
    echo '    if [[ "$a" == "-p" ]]; then'
    echo '        _argv=$(tr "\0" " " </proc/$PPID/cmdline)'
    echo '        case "$_argv" in *test-sig1.sh*) echo "mktemp: (fixture) refusing -p for test-sig1.sh" >&2; exit 1 ;; esac'
    echo '    fi'
    echo 'done'
    printf 'exec %q "$@"\n' "$REAL_MKTEMP"
} > "$D/bin/mktemp"; chmod +x "$D/bin/mktemp"
PATH="$D/bin:$PATH" NEXUS_KNOWN_LOCAL_RED="$D/klr.tsv" NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$D/state" \
    bash "$RUNNER" --jobs 2 "$D"/test-sig*.sh > "$D/log" 2>&1 < /dev/null
rc=$?
# POSITIVE CONTROLS first: the shim must have bitten exactly as designed (the
# known red RECORDED, the other verdict LOST), or the absence of CLEAR below
# could simply mean nothing failed.
assert_contains "§1e control: the planted known red was recorded as a FAIL" "$(cat "$D/log")" "FAIL  test-sig0.sh"
assert_contains "§1e control: …and the accounting really broke" "$(cat "$D/log")" "ACCOUNTING INCOMPLETE"
assert_eq       "§1e broken accounting is RED (rc 1), not resumable (3) and not a signal (4)" "$rc" "1"
assert_contains "§1e the gate line says NOT EVALUATED and names the lost verdicts" "$(cat "$D/log")" "LOCAL GATE: NOT EVALUATED — this run is INCOMPLETE (the run's ACCOUNTING BROKE"
assert_not_contains "§1e …and never CLEAR" "$(cat "$D/log")" "CLEAR for the local gate"
# (§1b's CONTROL is the must-not-flip: the same planted red on an undisturbed run
# is still partitioned and CLEARED.)

# ── §2  PARALLEL, signal to the runner pid alone ────────────────────────────
echo '=== §2 --jobs 3: the signal is DEFERRED — no orphans, a complete verdict, and a note ==='
D="$WORK/s2"; mk_fixtures "$D" 3 2
launch "$D" "$D/log" --jobs 3 || echo "  (launch did not reach a started fixture)" >&2
kill -TERM "$RPID" 2>/dev/null; wait "$RPID"; rc=$?
# THE ORPHAN ASSERTION, taken the instant the runner returns. Before the fix the
# runner died at once and the children ran on: done < started at this moment.
assert_eq       "§2 when the runner returns, NO dispatched test is still running (no orphans)" \
    "$(count "$D" done)" "3"
assert_eq       "§2 the run completed, so it exits with the COMPLETE verdict (0)" "$rc" "0"
assert_contains "§2 …and says the signal arrived and was deferred" "$(cat "$D/log")" "DEFERRED it"
assert_not_contains "§2 …without calling a complete sweep a subset" "$(cat "$D/log")" "NOT A VERDICT"
assert_contains "§2 the LAST line is the END marker, rc=0" "$(last_line "$D/log")" "=== run-tests: END rc=0 (COMPLETE and green)"

# ── §3  GROUP signal — what `timeout`, Slurm and a harness stop send ────────
echo '=== §3 a process-GROUP TERM: the #1083 banner is finally PRINTED, exit 4 ==='
# Driven with `setsid` + `kill -- -PGID` rather than `timeout N`: the signal is
# the same one, and it is sent when a fixture has STARTED instead of after a
# wall-clock guess that a loaded host turns into a different experiment.
D="$WORK/s3"; mk_fixtures "$D" 3 30
LAUNCH_PREFIX=(setsid)
launch "$D" "$D/log" --jobs 3 || echo "  (launch did not reach a started fixture)" >&2
LAUNCH_PREFIX=()
kill -TERM -- "-$RPID" 2>/dev/null; wait "$RPID"; rc=$?
assert_eq       "§3 the runner exits 4 — before the fix it died 143 with the batch, silent" "$rc" "4"
assert_contains "§3 the runner survived to say the sweep was interrupted" "$(cat "$D/log")" "SWEEP INTERRUPTED"
assert_contains "§3 …names it not-a-verdict" "$(cat "$D/log")" "NOT A VERDICT"
assert_contains "§3 the LAST line is the END marker, rc=4" "$(last_line "$D/log")" "=== run-tests: END rc=4"
assert_eq       "§3 no fixture finished its 30 s — the batch really was killed" "$(count "$D" done)" "0"

# ── §4  SIGKILL — the death no trap can see. The marker's ABSENCE is the signal ─
echo '=== §4 SIGKILL: no END marker — and the header already told the reader what that means ==='
D="$WORK/s4"; mk_fixtures "$D" 2 2
launch "$D" "$D/log" --jobs 1 || echo "  (launch did not reach a started fixture)" >&2
kill -KILL "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; rc=$?
assert_eq       "§4 the runner died of SIGKILL (137)" "$rc" "137"
assert_not_contains "§4 a KILLED log carries NO END marker — the control for every END assertion here" \
    "$(cat "$D/log")" "=== run-tests: END"
assert_contains "§4 …and its HEADER says what the absence means" "$(cat "$D/log")" "this log is a VERDICT only if it ENDS with the runner-s closing marker"
# The serial fixture the runner was waiting on is reparented, not killed; let it
# finish so this suite leaves nothing behind (2 s fixture, bounded wait).
for (( _i = 0; _i < 100; _i++ )); do [[ "$(count "$D" started)" == "$(count "$D" done)" ]] && break; sleep 0.1; done
assert_eq       "§4 (hygiene) the reparented fixture finished before this suite moved on" \
    "$(count "$D" started)" "$(count "$D" done)"

# ── §4b  AN UNTRAPPED FATAL SIGNAL: bash still runs the EXIT trap, with `$?` holding
#         the LAST COMPLETED command's status — 0 in the runner's wait-on-child shape ──
# The sharpest case in this file, found by a REFUTED mutation prediction. A
# marker derived from `$?` closes the log of a runner killed by SIGUSR1 with
# "END rc=0 (COMPLETE and green)". It must say the opposite, in words that a
# reader testing for the marker cannot mistake for it.
echo '=== §4b SIGUSR1 (untrapped): the EXIT path runs — and must NOT print a green END ==='
D="$WORK/s4b"; mk_fixtures "$D" 2 2
launch "$D" "$D/log" --jobs 1 || echo "  (launch did not reach a started fixture)" >&2
kill -USR1 "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; rc=$?
assert_eq       "§4b the runner died of SIGUSR1 (138)" "$rc" "138"
assert_not_contains "§4b a signal-killed runner prints NO END marker — above all not a green one" \
    "$(cat "$D/log")" "=== run-tests: END"
assert_contains "§4b …its last line says it stopped WITHOUT a verdict" "$(last_line "$D/log")" "STOPPED WITHOUT REACHING A VERDICT"
for (( _i = 0; _i < 100; _i++ )); do [[ "$(count "$D" started)" == "$(count "$D" done)" ]] && break; sleep 0.1; done

# ── §5  ORDINARY runs carry the marker too, with the right code ─────────────
echo '=== §5 an undisturbed run: END is the last line, and it carries the real rc ==='
D="$WORK/s5"; mk_fixtures "$D" 2 0
NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$D/state" bash "$RUNNER" --jobs 1 "$D"/test-sig*.sh > "$D/log" 2>&1 < /dev/null
rc=$?
assert_eq       "§5 green run exits 0" "$rc" "0"
assert_contains "§5 …and its LAST line is END rc=0" "$(last_line "$D/log")" "=== run-tests: END rc=0 (COMPLETE and green)"
assert_not_contains "§5 …with no signal note on a run nobody signalled" "$(cat "$D/log")" "RUNNER RECEIVED"
printf '#!/usr/bin/env bash\necho "  FAIL: planted"; exit 1\n' > "$D/test-sig9.sh"
NEXUS_TEST_NPROC_GUARD=off NEXUS_TEST_STATE_DIR="$D/state" bash "$RUNNER" --jobs 2 "$D"/test-sig*.sh > "$D/log2" 2>&1 < /dev/null
rc=$?
assert_eq       "§5 red run exits 1" "$rc" "1"
assert_contains "§5 …and its LAST line is END rc=1" "$(last_line "$D/log2")" "=== run-tests: END rc=1 (COMPLETE and RED)"
NEXUS_TEST_STATE_DIR="$D/state" bash "$RUNNER" --list > "$D/log3" 2>&1 < /dev/null
assert_not_contains "§5 --list is not a run and ends with no marker" "$(cat "$D/log3")" "run-tests: END"

# ASSERTION CENSUS — the exact-count guard (your-org/nexus-code#807).
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
