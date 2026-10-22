#!/usr/bin/env bash
# Tests for run-tests.sh's bounded, resumable, honest-accounting mode
# (your-org/nexus-code#499).
#
# The defect: the watcher suite outgrew any single bounded invocation
# (~175 tests, dozens past a 10-minute tool ceiling) and the runner had
# no per-test timeout, no resumability, and no way to distinguish "never
# ran" from "passed" — so every "ran the full suite" claim was an
# assertion of a state that was never established. Contracts under test:
#
#   T1  --timeout: a hanging test is terminated, PRINTED as TIMEOUT,
#       tallied as TIMEOUT (never a pass, never omitted), exit 1.
#   T2  --state ledger: every completed test appends path/status/wall;
#       the summary accounts for the FULL selection.
#   T3  --resume: recorded tests are skipped; the sweep completes across
#       two invocations and only then reads green (exit 0).
#   T4  --max-seconds: the runner stops cleanly between tests, reports
#       the unaccounted remainder, exits 3 with a resume hint — and a
#       green-so-far ledger with unrun tests is NOT exit 0.
#   T5  a ledger containing a FAIL yields exit 1 even when complete.
#
# Hermetic: fixture "tests" are trivial scripts in a temp dir, invoked
# by explicit path (the runner accepts explicit paths); the runner's
# last-failures state is scoped via NEXUS_TEST_STATE_DIR; the nproc
# guard is left on (it is relative and harmless here).
#
# Run: bash monitor/watcher/test-run-tests-bounded.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$_test_dir/run-tests.sh"

PASS=0
FAIL=0
SKIP=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

WORK=$(mktemp -d -t nexus-runner-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_TEST_STATE_DIR="$WORK/runner-state"

FIX="$WORK/fixture"
mkdir -p "$FIX"
printf '#!/bin/bash\nexit 0\n'              > "$FIX/ok-a.sh"
printf '#!/bin/bash\nexit 0\n'              > "$FIX/ok-b.sh"
printf '#!/bin/bash\nexit 1\n'              > "$FIX/red.sh"
printf '#!/bin/bash\nsleep 60\n'            > "$FIX/hang.sh"
printf '#!/bin/bash\nsleep 2; exit 0\n'     > "$FIX/slow-ok.sh"
# A test that DECLINES TO RUN: exit 77 (your-org/nexus-code#568 A6).
printf '#!/bin/bash\necho "skipped: needs a thing this host lacks"\nexit 77\n' > "$FIX/skip.sh"
# T7 (your-org/nexus-code#752) — the three FAILURE-REPORTING SHAPES a suite can
# have. `red.sh` above is already the third (silent on both streams).
#   red-stdout.sh  announces its verdict on STDOUT only. This is the #752 shape:
#                  test-respawn-loop-integration.sh's terminal `echo "FAIL: guard
#                  did not trip within deadline"` carries no `>&2`, so its .err
#                  was 0 bytes and the band summary printed `rc=1` and nothing.
#   red-stderr.sh  announces on STDERR, the shape the runner already handled.
#                  Kept so the fix cannot regress the path that worked.
printf '#!/bin/bash\necho "VERDICT-ON-STDOUT: the guard did not trip"\nexit 1\n' > "$FIX/red-stdout.sh"
printf '#!/bin/bash\necho "VERDICT-ON-STDERR: assertion 3 failed" >&2\nexit 1\n' > "$FIX/red-stderr.sh"
#   red-evicted.sh  the #1561 shape: the FAIL line is written EARLY and 25 lines
#                  of unrelated stderr follow it, so a 20-line tail is filled
#                  entirely with noise and the assertion is evicted.
#   red-evicted-stdout.sh  the same, with the assertion on STDOUT and the noise
#                  on stderr — the residual `_rt_failure_tail`'s own header
#                  used to DISCLOSE rather than close.
#   red-flood.sh   45 failing assertions, to exercise the cap.
{
    printf '#!/bin/bash\n'
    printf 'echo "  FAIL: EVICTED-ASSERTION capture not written (seen=0)" >&2\n'
    printf 'for i in $(seq 1 25); do echo "noise-line-$i: list-windows: command not found" >&2; done\n'
    printf 'exit 1\n'
} > "$FIX/red-evicted.sh"
{
    printf '#!/bin/bash\n'
    printf 'echo "  FAIL: STDOUT-ASSERTION under stderr noise"\n'
    printf 'for i in $(seq 1 25); do echo "noise-line-$i" >&2; done\n'
    printf 'exit 1\n'
} > "$FIX/red-evicted-stdout.sh"
{
    printf '#!/bin/bash\n'
    printf 'for i in $(seq 1 45); do echo "  FAIL: flood-$i" >&2; done\n'
    printf 'exit 1\n'
} > "$FIX/red-flood.sh"
chmod +x "$FIX"/*.sh

# `-u KEEP_LOGS_DIR`: a band run with --keep-logs EXPORTS it, and a nested runner
# that inherits it takes the "logs are already durable" path — so T7g/T7i, which
# pin the NO --keep-logs behaviour, were green alone and red in-band (#1561).
run() { OUT=$(env -u KEEP_LOGS_DIR bash "$RUNNER" "$@" 2>&1); RC=$?; }

# ---- T1: timeouts are terminated, named, tallied — never passes ----------
echo '=== T1: --timeout turns a hang into a LOUD TIMEOUT, exit 1 ==='
run --timeout 2 --state "$WORK/t1.tsv" "$FIX/ok-a.sh" "$FIX/hang.sh"
assert_eq       "T1 exit 1 (a timeout is a failure)"       "$RC" "1"
assert_contains "T1 prints the TIMEOUT row"                "$OUT" "TIMEOUT  hang.sh"
assert_contains "T1 summary counts it as TIMEOUT"          "$OUT" "1 TIMEOUT"
assert_contains "T1 timeout listed, marked not-a-pass"     "$OUT" "NOT passes"
assert_eq       "T1 ledger records TIMEOUT" \
    "$(awk -F'\t' '$1 ~ /hang.sh/ {print $2}' "$WORK/t1.tsv")" "TIMEOUT"
assert_eq       "T1 ledger records the pass" \
    "$(awk -F'\t' '$1 ~ /ok-a.sh/ {print $2}' "$WORK/t1.tsv")" "PASS"

# ---- T2/T3: ledger + resume complete a sweep across invocations ----------
echo '=== T2/T3: --state + --resume finish the sweep across two invocations ==='
run --state "$WORK/t2.tsv" "$FIX/ok-a.sh"
assert_eq "T2 first invocation green so far but selection=1, exit 0" "$RC" "0"
run --state "$WORK/t2.tsv" --resume "$FIX/ok-a.sh" "$FIX/ok-b.sh"
assert_eq       "T3 second invocation exit 0 (sweep complete, all green)" "$RC" "0"
assert_contains "T3 announced the resume skip"    "$OUT" "resume: 1 already recorded"
assert_contains "T3 ledger accounts for both"     "$OUT" "2 PASS, 0 SKIP, 0 ENVSKIP, 0 FAIL, 0 TIMEOUT, 0 not yet run"
assert_eq       "T3 ok-a ran exactly once (skipped on resume)" \
    "$(grep -c 'ok-a.sh' "$WORK/t2.tsv")" "1"
# T3b — resume on a FULLY-recorded ledger: the counts must read zero
# remaining and "running 0 tests" (the `("${filtered[@]:-}")` expansion
# used to leave one empty element, printing "1 remaining / running 1
# tests" while running nothing — skeptic finding on #499. A runner whose
# own counts lie is disqualified from being the honesty mechanism).
run --state "$WORK/t2.tsv" --resume "$FIX/ok-a.sh" "$FIX/ok-b.sh"
assert_eq       "T3b fully-recorded resume exits 0"        "$RC" "0"
assert_contains "T3b reports zero remaining"               "$OUT" "; 0 remaining"
assert_contains "T3b runs zero tests (no phantom element)" "$OUT" "running 0 tests"
assert_eq       "T3b ledger unchanged (nothing double-counted)" \
    "$(wc -l < "$WORK/t2.tsv" | tr -d ' ')" "2"

# ---- T4: budget stop is INCOMPLETE (exit 3), never green ------------------
echo '=== T4: --max-seconds stops between tests; unrun tests block green ==='
run --state "$WORK/t4.tsv" --max-seconds 1 "$FIX/slow-ok.sh" "$FIX/ok-b.sh"
assert_eq       "T4 exit 3 (incomplete)"           "$RC" "3"
assert_contains "T4 says INCOMPLETE"               "$OUT" "INCOMPLETE"
assert_contains "T4 names the unaccounted count"   "$OUT" "1 not yet run"
assert_contains "T4 prescribes resuming"           "$OUT" "Resume with the SAME command"
run --state "$WORK/t4.tsv" --resume --max-seconds 30 "$FIX/slow-ok.sh" "$FIX/ok-b.sh"
assert_eq "T4 resumed invocation completes green (exit 0)" "$RC" "0"

# ---- T5: a complete ledger with a FAIL is exit 1 --------------------------
echo '=== T5: complete-but-red ledger exits 1 ==='
run --state "$WORK/t5.tsv" "$FIX/ok-a.sh" "$FIX/red.sh"
assert_eq       "T5 exit 1"                    "$RC" "1"
assert_contains "T5 ledger shows the fail"     "$OUT" "1 PASS, 0 SKIP, 0 ENVSKIP, 1 FAIL, 0 TIMEOUT, 0 not yet run"

# ---- T5b: SKIP is a THIRD outcome — not a pass, not a failure -------------
# your-org/nexus-code#568 A6. `status=PASS` whenever `rc == 0` meant every
# self-skipping test tallied as a pass: 13 structurally-skipping tests sat in
# the default band and three printed the literal `ALL TESTS PASSED` after ZERO
# checks. A green count was therefore never a coverage claim, and nothing in
# the output said so. Exit 77 (the autotools convention) now records SKIP.
echo '=== T5b: exit 77 records SKIP — green, but never counted as evidence ==='
run --state "$WORK/t5b.tsv" "$FIX/ok-a.sh" "$FIX/skip.sh"
assert_eq       "T5b a SKIP does not turn the run red"  "$RC" "0"
assert_contains "T5b prints a SKIP row"                 "$OUT" "SKIP  skip.sh"
assert_contains "T5b row carries the test's own reason" "$OUT" "needs a thing this host lacks"
assert_contains "T5b summary counts it separately"      "$OUT" "1 PASS, 1 SKIP, 0 ENVSKIP, 0 FAIL, 0 TIMEOUT, 0 not yet run"
assert_contains "T5b states the PASS count is not coverage over it" \
    "$OUT" "DECLINED TO RUN"
assert_contains "T5b lists the skipped path"            "$OUT" "SKIPPED (declined to run"
assert_eq       "T5b ledger records SKIP, not PASS" \
    "$(awk -F'\t' '$1 ~ /skip.sh/ {print $2}' "$WORK/t5b.tsv")" "SKIP"
# A SKIP must not be re-selected by --failed-only: it did not fail.
run --state "$WORK/t5b.tsv" --resume "$FIX/ok-a.sh" "$FIX/skip.sh"
assert_eq       "T5b a recorded SKIP is not re-run on resume" \
    "$(grep -c 'skip.sh' "$WORK/t5b.tsv")" "1"

# ---- T6: the nproc guard budgets TASKS, not processes (#506) ---------------
# RLIMIT_NPROC is checked against the uid's TASK (thread) count; a single
# node/claude process holds up to ~1000 threads, so the old guard's
# `ps -o pid=` PROCESS count under-counted ~7-9x and a small
# NEXUS_TEST_NPROC_HEADROOM produced a cap below the fork floor — every
# test died with fork:EAGAIN (a confirmation hazard). Post-fix the cap is
# probed-task-floor + headroom, so a small headroom still runs a trivial
# test to completion, and the floor the banner reports must be the TASK
# count, not the process count.
# Headroom 64: enough for the runner's own post-cap fork bursts (a floor+8
# cap completes but crawls through bash's EAGAIN retry backoff under
# ambient churn).
#
# HOW THIS IS MEASURED, and why the obvious way does not work
# (your-org/nexus-code#585). The discriminator used to be
# `cap > 2 * process_count`, resting on the premise that tasks outnumber
# processes ~7-9x "because one node/claude process holds ~1000 threads".
# That is a property of a developer workstation running a nexus worker
# (measured 1489 tasks / 186 processes = 8.0x), NOT of the environment. A CI
# runner has no fat multithreaded process, so tasks ≈ processes, and the two
# sides of the comparison collide: it went red on an exact tie (cap 82 vs
# 2x41 procs = 82), flipping green on re-run with no code change, because
# `t6_procs` counts whatever else the suite happens to co-schedule at
# `--jobs 4`. The assertion was comparing a STABLE quantity (the cap,
# derived from the probed floor) against a SCHEDULING-DEPENDENT one.
#
# Widening the multiplier or the headroom would have converted a real
# fragility into a silent one. The noun was the problem, not the constant:
# where tasks ≈ processes the two nouns are INDISTINGUISHABLE, so no
# assertion phrased over ambient counts can discriminate there — and the
# pre-fix guard genuinely was not broken on such a host.
#
# So MANUFACTURE the condition instead of hoping for it: park N threads in
# ONE process for the duration of the probe. That establishes a known
# task-minus-process gap of ~N on ANY host, runner included, and the
# assertion becomes "the reported floor exceeds the PROCESS count by a
# large fraction of the gap we deliberately created" — a claim about the
# noun, decided by a margin (N/2) that dwarfs both the probe's 32-wide
# binary-search granularity and any plausible co-scheduling churn.
#
# T6b EARNED ITS KEEP IMMEDIATELY: it is the regression test for the
# elided-fork bug in the guard's own probe. On bash 5.2 (every current
# runner) `( ulimit -Su N; /bin/true )` is exec'd in place of the subshell,
# so no child is created, RLIMIT_NPROC is never exercised, every candidate
# "succeeds", and the search collapses to its lower bound. The guard
# reported "probed task floor 23" on a runner whose real floor was 566 and
# then hit `fork: Resource temporarily unavailable` at the resulting cap of
# 87 — the #506 hazard exactly, masked in normal use only because the
# default headroom (2048) is big enough to hide a garbage floor. The old
# `2 * procs` discriminator could never have caught it: 23 > 2 * 14 is
# true. See run-tests.sh's _probe_ok for the fix and the measurement.
echo '=== T6: small headroom is usable; cap derives from the task floor ==='

T6_THREADS=512
t6_farm_pid=""
t6_farm_ready=0
t6_farm_why=""

# Signal the farm only while it is still OUR child: pid_max on the lab boxes
# is small and a parallel suite recycles PIDs in under a minute, so killing a
# recorded-but-exited PID can signal a stranger (_test_helpers.sh documents
# the same hazard). This file keeps its own assertions inline for
# self-containment, so the guard is inline too.
#
# The `wait` is not incidental: bash announces an asynchronously-reaped job on
# stderr ("Terminated  python3 …"), and for a job started from a heredoc that
# notice carries the ENTIRE script body into the test's output. Reaping the
# job explicitly, inside a redirected group, keeps it quiet.
t6_stop_farm() {
    [[ -n "${t6_farm_pid:-}" ]] || return 0
    local st rest ppid
    if st=$(cat "/proc/$t6_farm_pid/stat" 2>/dev/null); then
        rest="${st##*) }"
        read -r _ ppid _ <<<"$rest"
        [[ "$ppid" == "$$" ]] && { kill "$t6_farm_pid"; wait "$t6_farm_pid"; } 2>/dev/null
    fi
    t6_farm_pid=""
}
trap 't6_stop_farm; rm -rf "$WORK"' EXIT

if command -v python3 >/dev/null 2>&1; then
    # 256 KiB stacks: 512 threads costs ~128 MiB of VIRTUAL address space and
    # a negligible RSS, so this is safe on a 2-vCPU/7 GiB runner. Threads are
    # tasks, so they count against RLIMIT_NPROC exactly as the kernel's fork
    # check does — which is the entire point.
    # In a FILE, not a backgrounded heredoc: bash's job notice quotes the whole
    # command line, and for a heredoc job that means the entire script body.
    cat > "$WORK/t6-farm.py" <<'PY'
import sys, threading
n = int(sys.argv[1])
threading.stack_size(262144)
up, stop = threading.Semaphore(0), threading.Event()
def hold():
    up.release()
    stop.wait(300)          # hard-bounded: the farm cannot outlive the test by long
for _ in range(n):
    threading.Thread(target=hold, daemon=True).start()
for _ in range(n):
    up.acquire()            # every thread is genuinely alive before we say READY
print("READY", flush=True)
stop.wait(300)
PY
    python3 "$WORK/t6-farm.py" "$T6_THREADS" > "$WORK/t6-farm.out" 2>&1 &
    t6_farm_pid=$!
    for _ in $(seq 1 150); do
        grep -q READY "$WORK/t6-farm.out" 2>/dev/null && { t6_farm_ready=1; break; }
        kill -0 "$t6_farm_pid" 2>/dev/null || break
        sleep 0.2
    done
    (( t6_farm_ready )) || t6_farm_why="thread farm never reported READY: $(tr '\n' ' ' < "$WORK/t6-farm.out" 2>/dev/null)"
else
    t6_farm_why="python3 absent — cannot park $T6_THREADS threads in one process"
fi

# Run the guard WHILE the farm is alive, so the probe sees those tasks.
t6_ok=0
for attempt in 1 2 3; do
    OUT=$(NEXUS_TEST_NPROC_HEADROOM=64 bash "$RUNNER" --state "$WORK/t6-$attempt.tsv" "$FIX/ok-a.sh" 2>&1); RC=$?
    (( RC == 0 )) && { t6_ok=1; break; }
done
# Measure both nouns for OUR uid in the same window as the probe, then release.
t6_procs=$(ps -o  pid= -u "$(id -u)" 2>/dev/null | grep -c .)
t6_tasks=$(ps -Lo pid= -u "$(id -u)" 2>/dev/null | grep -c .)
t6_stop_farm

assert_eq "T6 headroom=64 run completes green (cap clears the true fork floor)" "$t6_ok" "1"

t6_cap=$(sed   -n 's/.*capped at \([0-9]*\).*/\1/p'            <<<"$OUT" | head -1)
t6_floor=$(sed -n 's/.*probed task floor \([0-9]*\).*/\1/p'    <<<"$OUT" | head -1)

# T6a — the banner's own accounting must hold: the cap IS floor + headroom.
# Environment-independent, and it is what makes the floor the auditable
# quantity rather than the cap. An absent banner is a failure, not a skip:
# it means the guard never engaged.
#
# A PASS LABEL IS A NAME, NOT A MEASUREMENT (your-org/nexus-code#1617, as #1574 did
# for test-cc-auto-update.sh). T6a, T6b and the two T6d labels below carried the
# PROBED floor, the host's task counts and a wall time, so they relabelled between
# two runs of one tree — a plain diff of two label lists read `4 LOST / 9 NEW` for
# an additive change. The values now print on a `note:` line beside the verdict;
# the FAIL messages keep them, because a FAIL is read, not paired.
printf '  note: T6a cap %s, probed floor %s, headroom 64\n' "$t6_cap" "$t6_floor"
if [[ "$t6_cap" =~ ^[0-9]+$ && "$t6_floor" =~ ^[0-9]+$ ]] && (( t6_cap == t6_floor + 64 )); then
    printf '  PASS: T6a cap == probed floor + headroom 64 (banner accounting is honest)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: T6a cap %q / floor %q do not reconcile with headroom 64 (banner absent or wrong)\n' \
        "$t6_cap" "$t6_floor" >&2
    FAIL=$(( FAIL + 1 ))
fi

# T6b — the noun. With ~T6_THREADS tasks deliberately parked in one process,
# a task-derived floor clears the PROCESS count by ~gap; a process-derived
# one cannot clear it at all. Margin gap/2 ≫ the 32-wide search granularity.
#
# THE VERDICT IS A FUNCTION, AND THAT IS THE FIX (your-org/nexus-code#925).
# This used to be an if/else whose `else` was reached by TWO different
# outcomes — a floor that is a number and too low (the real finding), and a
# floor that is not a number at all (no measurement happened) — while the
# message asserted the first: `floor '' is process-scale … still counting the
# wrong noun`. Observed with the floor as the EMPTY STRING. Neither "is
# process-scale" nor "counts the wrong noun" is established by an absent
# value; a reader who trusts it goes hunting in the floor computation for a
# defect that may not be there.
#
# That is this repo's dominant defect class — absence reported as a finding —
# inside a guard whose own job is to catch it, and it is the same remedy
# `_merge_ref_base` took for a non-numeric `total_count`: a value the parse
# cannot read is `unread`, never a verdict about what it would have said.
#
# Extracted to a pure classifier so the distinction is TESTABLE rather than
# merely correct: the synthetic cases below drive it with the empty floor that
# produced the report, which no live run can be made to reproduce on demand.
#
# _t6b_verdict <farm_ready> <floor> <procs> <tasks> <threads>
#   -> unmeasured | skip | task-scale | process-scale
_t6b_verdict() {
    local ready="${1-}" floor="${2-}" procs="${3-}" tasks="${4-}" threads="${5-}"
    # Inputs the arm's own arithmetic needs. Checked BEFORE any (( )) touches
    # them: `(( x >= 1 ))` on a non-numeric x is a bash `set -u` fatal and a
    # silent 0 elsewhere, which is the #903 total_count trap one file over.
    if ! [[ "$procs" =~ ^[0-9]+$ && "$tasks" =~ ^[0-9]+$ && "$threads" =~ ^[0-9]+$ ]]; then
        printf 'unmeasured'; return
    fi
    local gap=$(( tasks - procs ))
    if [[ "$ready" != 1 ]] || (( gap < threads / 2 )); then printf 'skip'; return; fi
    # The discriminator IS decidable here — so an unreadable floor is the one
    # thing left unmeasured, and it is reported as that and nothing more.
    if ! [[ "$floor" =~ ^[0-9]+$ ]]; then printf 'unmeasured'; return; fi
    if (( floor >= procs + gap / 2 )); then printf 'task-scale'; else printf 'process-scale'; fi
}

t6_gap=$(( t6_tasks - t6_procs ))
case "$(_t6b_verdict "$t6_farm_ready" "$t6_floor" "$t6_procs" "$t6_tasks" "$T6_THREADS")" in
    task-scale)
        printf '  note: T6b floor %s (procs=%s tasks=%s gap=%s, needed >= %s)\n' \
            "$t6_floor" "$t6_procs" "$t6_tasks" "$t6_gap" "$(( t6_procs + t6_gap / 2 ))"
        printf '  PASS: T6b the floor counts TASKS not processes\n'
        PASS=$(( PASS + 1 )) ;;
    process-scale)
        # The floor IS a number and it IS too low. Only this arm has earned the
        # noun claim, so only this arm makes it.
        printf '  FAIL: T6b floor %s is process-scale (procs=%s tasks=%s gap=%s, needed >= %s) — still counting the wrong noun\n' \
            "$t6_floor" "$t6_procs" "$t6_tasks" "$t6_gap" "$(( t6_procs + t6_gap / 2 ))" >&2
        FAIL=$(( FAIL + 1 )) ;;
    unmeasured)
        # NOT a finding, and deliberately not a FAIL: nothing was measured, so
        # there is nothing to conclude about the noun. Counted as a SKIP so the
        # summary reports it as NOT COVERED rather than as a pass.
        SKIP=$(( ${SKIP:-0} + 1 ))
        printf '  SKIP: T6b UNMEASURED — the floor is %q, not a number, so the task-vs-process\n' "$t6_floor" >&2
        printf '        question was never asked. This is NOT a claim that the floor is\n' >&2
        printf '        process-scale or that anything counts the wrong noun (procs=%q tasks=%q).\n' \
            "$t6_procs" "$t6_tasks" >&2 ;;
    *)
        # Loud, counted, and it names the numbers so the reader can act. The
        # alternative — asserting over ambient counts anyway — is exactly the
        # tie-on-a-runner flake this replaced.
        SKIP=$(( ${SKIP:-0} + 1 ))
        printf '  SKIP: T6b task-vs-process discriminator — %s (procs=%s tasks=%s gap=%s, need gap >= %s)\n' \
            "${t6_farm_why:-manufactured task/process gap did not materialise}" \
            "$t6_procs" "$t6_tasks" "$t6_gap" "$(( T6_THREADS / 2 ))" >&2 ;;
esac

# T6c — the classifier itself, driven with synthetic inputs. THE EMPTY FLOOR IS
# THE POINT: it is the value that produced `#925`'s misreport, and no live run
# can be made to yield it on demand, so the only way it is ever covered is here.
_t6c() {   # <want> <label> <args...>
    local want="$1" label="$2"; shift 2
    local got; got=$(_t6b_verdict "$@")
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: T6c %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: T6c %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 ))
    fi
}
_t6c unmeasured    "an EMPTY floor is UNMEASURED, never a noun verdict (#925's own observation)" 1 ''    100 1000 64
_t6c unmeasured    "…and so is a non-numeric floor"                                              1 'n/a' 100 1000 64
_t6c process-scale "a numeric floor at process scale IS the finding — the arm still fires"       1 '105' 100 1000 64
_t6c task-scale    "a task-derived floor passes"                                                 1 '600' 100 1000 64
_t6c skip          "no manufactured gap → skip, not a verdict"                                   1 '600' 100 100  64
_t6c skip          "farm not ready → skip"                                                       0 '600' 100 1000 64
_t6c unmeasured    "unreadable procs/tasks are UNMEASURED before any arithmetic touches them"    1 '600' ''  1000 64

# ---- T6d: the floor search runs in ONE helper process (#1474, plan item 1) ---
#
# Each FAILING shell probe costs ~15 s of bash's own EAGAIN retry backoff, the
# search fails about three, and so every runner invocation paid ~45 s before its
# first test (measured 45.79 s against 0.41 s with the guard off). The helper
# does the same bisection with direct fork() calls. Asserted: it is the DEFAULT
# instrument, it is FAST, it AGREES with the shell probe it replaces, and the
# shell probe is still reachable — a guard that silently disengaged when an
# optional interpreter was missing would be #863 again.
echo '=== T6d: the fork-floor search is one helper process, and agrees with the shell probe ==='
_t6d_floor() { local f; f=$(sed -n 's/.*probed task floor \([0-9]*\).*/\1/p' <<<"$1"); printf '%s' "${f%%$'\n'*}"; }
t6d_t0=$SECONDS
OUT=$(NEXUS_TEST_NPROC_GUARD=on bash "$RUNNER" "$FIX/ok-a.sh" 2>&1); t6d_rc=$?
t6d_helper_wall=$(( SECONDS - t6d_t0 ))
t6d_helper_floor=$(_t6d_floor "$OUT")
assert_eq       "T6d the default run is green"                         "$t6d_rc" "0"
if command -v python3 >/dev/null 2>&1; then
    assert_contains "T6d the banner names the helper as the instrument" "$OUT" "probe=helper) ==="
    # 20 s: a third of ONE failing shell probe pair, and ~30x the measured helper
    # wall (0.6 s at load 34) — a bound on the instrument, not on the host.
    printf '  note: T6d the helper-probed run took %ss\n' "$t6d_helper_wall"
    assert_eq "T6d the helper-probed run finishes in under 20 s (was ~45 s)" \
        "$(( t6d_helper_wall < 20 ))" "1"
    OUT=$(NEXUS_TEST_NPROC_GUARD=on NEXUS_TEST_NPROC_PROBE=shell bash "$RUNNER" "$FIX/ok-a.sh" 2>&1); t6d_rc=$?
    t6d_shell_floor=$(_t6d_floor "$OUT")
    assert_eq       "T6d MUST-NOT-FLIP: the shell probe is still reachable and still green" "$t6d_rc" "0"
    assert_contains "T6d …and says it was the instrument" "$OUT" "probe=shell) ==="
    # AGREEMENT, with a tolerance that is about the HOST, not the instruments:
    # the uid's task count moved 800 -> 1330 between two consecutive probes when
    # this was measured, and both instruments tracked it (906/904, 1433/1391).
    # A garbage floor is off by an order of magnitude (23 against 566, #597),
    # which a factor-of-two band catches and ambient churn does not trip.
    if [[ "$t6d_helper_floor" =~ ^[0-9]+$ && "$t6d_shell_floor" =~ ^[0-9]+$ ]] \
       && (( t6d_helper_floor * 2 >= t6d_shell_floor && t6d_shell_floor * 2 >= t6d_helper_floor )); then
        printf '  note: T6d floors: helper %s, shell %s\n' "$t6d_helper_floor" "$t6d_shell_floor"
        printf '  PASS: T6d the two instruments agree on the floor (within 2x)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: T6d the helper floor %q and the shell floor %q disagree by more than 2x\n' "$t6d_helper_floor" "$t6d_shell_floor" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  SKIP: T6d helper timing/agreement — python3 absent, so the shell probe IS the default here\n' >&2
    SKIP=$(( SKIP + 4 ))
fi

# ---- T7: a red must print the failing test's OWN diagnosis ------------------
#
# your-org/nexus-code#752. The runner tailed `.err` alone, which is a PROXY for
# "show what the test said about its failure". For any suite that reports its
# verdict on stdout the proxy returns nothing, silently — and the band summary
# renders a bare `rc=1`. That is what happened to
# test-respawn-loop-integration.sh on BOTH attempts of run 31153179861: 0-byte
# .err, 10,563-byte .out ending in its verdict, and a day spent triaging a red
# whose cause was already on disk.
#
# NOT tested by asserting "stderr is where verdicts go" — that would re-encode
# the proxy. The property asserted is that the TEXT THE TEST EMITTED reaches the
# summary, whichever stream carried it.
echo '=== T7: a FAIL surfaces the test'"'"'s own diagnosis from either stream ==='

run --state "$WORK/t7.tsv" "$FIX/red-stdout.sh"
assert_eq       "T7a stdout-only red still exits 1"            "$RC" "1"
assert_contains "T7a the STDOUT verdict reaches the summary"   "$OUT" "VERDICT-ON-STDOUT: the guard did not trip"
assert_contains "T7a the summary names which stream it read"   "$OUT" "stderr empty — stdout tail follows"

run --state "$WORK/t7b.tsv" "$FIX/red-stderr.sh"
assert_contains "T7b the STDERR verdict still reaches the summary" "$OUT" "VERDICT-ON-STDERR: assertion 3 failed"
# No regression: when stderr HAS the diagnosis, the stdout-fallback banner must
# not appear. Otherwise the label stops meaning anything.
if [[ "$OUT" == *"stderr empty"* ]]; then
    printf '  FAIL: T7b stderr-carrying red wrongly announced the stdout fallback\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7b stderr-carrying red does NOT announce the stdout fallback\n'
    PASS=$(( PASS + 1 ))
fi

# A test that says nothing at all must SAY that it said nothing. A blank gap
# under a FAIL row is indistinguishable from the #752 bug it just fixed.
run --state "$WORK/t7c.tsv" "$FIX/red.sh"
assert_contains "T7c a genuinely silent red is named as silent" \
    "$OUT" "(test emitted nothing on either stream)"

# T7d — THE PARALLEL PATH. `run_one` is dispatched through `xargs … bash -c`
# when --jobs > 1, and a child shell inherits exported FUNCTIONS only. An
# unexported `_rt_failure_tail` is `command not found` there — a red that prints
# no diagnosis, i.e. #752 reproduced inside its own fix. This cannot be covered
# by test-assertion-accounting.sh section 6 (the established guard for missing
# parallel helpers): every fixture it builds exits 0, so the FAIL arm this
# function lives on never executes there.
run --jobs 2 --state "$WORK/t7d.tsv" "$FIX/red-stdout.sh" "$FIX/red-stderr.sh"
assert_contains "T7d --jobs 2: stdout verdict survives the parallel dispatcher" \
    "$OUT" "VERDICT-ON-STDOUT: the guard did not trip"
assert_contains "T7d --jobs 2: stderr verdict survives the parallel dispatcher" \
    "$OUT" "VERDICT-ON-STDERR: assertion 3 failed"
if [[ "$OUT" == *"command not found"* ]]; then
    printf '  FAIL: T7d --jobs 2 emitted "command not found" — a helper is missing from the parallel children\n' >&2
    grep -m2 'command not found' <<<"$OUT" | sed 's/^/      /' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7d --jobs 2: no "command not found" in the run\n'
    PASS=$(( PASS + 1 ))
fi

# T7e — A FAILING SUITE MUST NOT BE ABLE TO EVICT ITS OWN ASSERTION
# (your-org/nexus-code#1561). The tail is positional; the assertion is not.
# POSITIVE CONTROL FIRST: the fixture must really push the assertion out of a
# 20-line tail, or "the assertion reached the summary" proves nothing about
# eviction — `noise-line-6` is the first line INSIDE a 20-line tail of 26, and
# `noise-line-5` the last one OUTSIDE it.
run --state "$WORK/t7e.tsv" "$FIX/red-evicted.sh"
# The tail line carries its SUITE since #1571 F4's residual (`<suite>| <line>`).
# BOTH halves of this control name the owned shape: left on the bare one, the
# NEGATIVE half below would pass VACUOUSLY — a string the runner can no longer
# print is absent whether or not the fixture still evicts anything.
assert_contains "T7e control: the fixture's noise fills the tail (line 6 shown)" "$OUT" "    red-evicted.sh| noise-line-6:"
if [[ "$OUT" == *"red-evicted.sh| noise-line-5:"* ]]; then
    printf '  FAIL: T7e control: noise-line-5 is inside the tail — the fixture no longer evicts anything\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7e control: noise-line-5 is OUTSIDE the tail, so the assertion above it is too\n'
    PASS=$(( PASS + 1 ))
fi
assert_contains "T7e the evicted assertion still reaches the summary" \
    "$OUT" "FAIL: EVICTED-ASSERTION capture not written (seen=0)"
assert_contains "T7e …with its line number, which says how far above the tail it sat" \
    "$OUT" "    red-evicted.sh:1:  FAIL: EVICTED-ASSERTION"
assert_contains "T7e the tail states how much it left out" "$OUT" "stderr: last 20 of 26 lines"

# T7f — the assertion on STDOUT while stderr carries only noise. Before #1561
# `_rt_failure_tail` returned after the stderr tail and never opened `.out`.
run --state "$WORK/t7f.tsv" "$FIX/red-evicted-stdout.sh"
assert_contains "T7f a stdout assertion is surfaced even when stderr is non-empty" \
    "$OUT" "FAIL: STDOUT-ASSERTION under stderr noise"
assert_contains "T7f …and is attributed to stdout" "$OUT" "failing-assertion line(s) on stdout"

# T7g — the full log of a red is KEPT without --keep-logs, and the row says
# where. The kept file must be the WHOLE stream (26 lines), not the tail.
run --state "$WORK/t7g.tsv" "$FIX/red-evicted.sh"
t7g_path=$(sed -n 's/^    full logs (kept): \(.*\)\.{out,err}$/\1/p' <<<"$OUT"); t7g_path=${t7g_path%%$'\n'*}
if [[ -n "$t7g_path" && -f "$t7g_path.err" ]]; then
    assert_eq "T7g the kept stderr is the WHOLE stream, not the tail" \
        "$(wc -l < "$t7g_path.err" | tr -d ' ')" "26"
    assert_eq "T7g the kept log lives under the runner's state dir" \
        "$([[ "$t7g_path" == "$NEXUS_TEST_STATE_DIR/failed-logs/"* ]] && echo yes || echo no)" "yes"
else
    printf '  FAIL: T7g no kept-log path printed for a red (got %q)\n' "$t7g_path" >&2
    FAIL=$(( FAIL + 1 ))
fi
# MUST-NOT: a GREEN run keeps nothing and creates no failed-logs run dir.
t7g_before=$(find "$NEXUS_TEST_STATE_DIR/failed-logs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
run --state "$WORK/t7g2.tsv" "$FIX/ok-a.sh"
t7g_after=$(find "$NEXUS_TEST_STATE_DIR/failed-logs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T7g a green run keeps no logs" "$t7g_after" "$t7g_before"
if [[ "$OUT" == *"full logs"* || "$OUT" == *"failing-assertion"* ]]; then
    printf '  FAIL: T7g a green run printed failure furniture\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7g a green run prints no failure furniture\n'; PASS=$(( PASS + 1 ))
fi

# T7j — A CEILING-OVERRIDE ROW APPLIES UNDER --jobs > 1 (your-org/nexus-code#1474).
# The row is looked up by BASENAME in the runner's REAL ceiling-overrides.tsv,
# through the runner's REAL path resolution — no `_RT_CEILING_FILE` handed in,
# because handing it in is exactly how the probe that "verified" this was
# blind. The fixture borrows the basename of a suite that has a row (3600 s),
# sleeps 3 s, and runs under --timeout 1: it passes only if the row is read.
mkdir -p "$WORK/ceil"
printf '#!/bin/bash\nsleep 3\necho "  PASS: slept"\necho "ALL TESTS PASSED (1 assertions)"\n' > "$WORK/ceil/test-guards-for-diff.sh"
cp "$FIX/ok-a.sh" "$WORK/ceil/test-ok-a.sh"
assert_eq "T7j control: the real manifest still carries a row for the borrowed basename" \
    "$(awk -F'\t' '!/^[[:space:]]*#/ && $1=="test-guards-for-diff.sh" && $2+0 > 600 {n++} END{print n+0}' "$_test_dir/ceiling-overrides.tsv")" "1"
OUT=$(env -u KEEP_LOGS_DIR -u _RT_CEILING_FILE -u NEXUS_TEST_CEILING_FILE bash "$RUNNER" --jobs 2 --timeout 1 "$WORK/ceil/test-guards-for-diff.sh" "$WORK/ceil/test-ok-a.sh" 2>&1); RC=$?
assert_eq "T7j --jobs 2: a suite with an override row is NOT cut off at the run ceiling (rc 0)" "$RC" "0"
if [[ "$OUT" == *"TIMEOUT  test-guards-for-diff.sh"* ]]; then
    printf '  FAIL: T7j --jobs 2: the override row was INERT — the suite was TIMEOUT-killed at the 1 s run ceiling\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7j --jobs 2: no TIMEOUT row for the overridden suite\n'; PASS=$(( PASS + 1 ))
fi
# MUST-NOT-FLIP: serially the row always applied (BASH_SOURCE is set there).
OUT=$(env -u KEEP_LOGS_DIR -u _RT_CEILING_FILE -u NEXUS_TEST_CEILING_FILE bash "$RUNNER" --jobs 1 --timeout 1 "$WORK/ceil/test-guards-for-diff.sh" 2>&1); RC=$?
assert_eq "T7j control: --jobs 1 honours the row too (it always did)" "$RC" "0"
# …and a suite WITHOUT a row is still cut off: the fix must not unbound anything.
printf '#!/bin/bash\nsleep 30\n' > "$WORK/ceil/test-no-row-here.sh"
OUT=$(env -u KEEP_LOGS_DIR -u _RT_CEILING_FILE -u NEXUS_TEST_CEILING_FILE bash "$RUNNER" --jobs 2 --timeout 1 "$WORK/ceil/test-no-row-here.sh" "$WORK/ceil/test-ok-a.sh" 2>&1); RC=$?
assert_contains "T7j control: a suite with NO row still TIMEOUTs at the run ceiling" "$OUT" "TIMEOUT  test-no-row-here.sh"

# T7k — (skeptic F3 on #1569) the runner's INTERNAL path is never inherited, and
# an unreadable file is SAID. A nested runner of another tree used to take the
# outer tree's rows through the exported internal name; and a missing file was
# answered by silently returning the run ceiling — the inert-rows defect's own
# shape, still armed for its next trigger.
OUT=$(_RT_CEILING_FILE=/nonexistent/inherited.tsv env -u KEEP_LOGS_DIR -u NEXUS_TEST_CEILING_FILE bash "$RUNNER" --jobs 2 --timeout 1 "$WORK/ceil/test-guards-for-diff.sh" "$WORK/ceil/test-ok-a.sh" 2>&1); RC=$?
assert_eq "T7k an INHERITED internal _RT_CEILING_FILE is ignored: the run uses its own tree's rows (rc 0)" "$RC" "0"
OUT=$(NEXUS_TEST_CEILING_FILE=/nonexistent/asked-for.tsv env -u KEEP_LOGS_DIR -u _RT_CEILING_FILE bash "$RUNNER" --jobs 2 --timeout 1 "$WORK/ceil/test-guards-for-diff.sh" "$WORK/ceil/test-ok-a.sh" 2>&1); RC=$?
assert_contains "T7k a caller-supplied file that is unreadable is SAID, by path" "$OUT" "ceiling overrides: /nonexistent/asked-for.tsv is NOT READABLE"
assert_contains "T7k …and the consequence still happens (the row is gone, the suite is cut off)" "$OUT" "TIMEOUT  test-guards-for-diff.sh"
# MUST-NOT-FLIP: a readable file prints no such line.
OUT=$(env -u KEEP_LOGS_DIR -u _RT_CEILING_FILE -u NEXUS_TEST_CEILING_FILE bash "$RUNNER" --jobs 1 "$FIX/ok-a.sh" 2>&1)
if [[ "$OUT" == *"NOT READABLE"* ]]; then
    printf '  FAIL: T7k a readable overrides file still printed the NOT READABLE line\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7k a readable overrides file prints no warning\n'; PASS=$(( PASS + 1 ))
fi

# T7l — (#1574 G2, G3) the file is judged by what it DOES. Each of these passes
# `[[ -r ]]`, so before #1574 each was SILENT and the suite was cut off at the
# run ceiling with nothing to say why. The realistic one is the first: a row
# typed with SPACES in a hand-maintained TSV.
_ceil_run() {   # <overrides-file> -> OUT, RC
    OUT=$(NEXUS_TEST_CEILING_FILE="$1" env -u KEEP_LOGS_DIR -u _RT_CEILING_FILE bash "$RUNNER" --jobs 2 --timeout 1 "$WORK/ceil/test-guards-for-diff.sh" "$WORK/ceil/test-ok-a.sh" 2>&1); RC=$?
}
printf '# a comment\ntest-guards-for-diff.sh 3600 typed with spaces\n' > "$WORK/ceil-spaces.tsv"
_ceil_run "$WORK/ceil-spaces.tsv"
assert_contains "T7l a SPACE-delimited row is called INERT, at startup"          "$OUT" "has 1 INERT row(s)"
assert_contains "T7l …and the offending line is NAMED by number"               "$OUT" "line 2: test-guards-for-diff.sh 3600 typed with spaces"
assert_contains "T7l …and the consequence still happens (the row never applied)" "$OUT" "TIMEOUT  test-guards-for-diff.sh"
assert_contains "T7l …and the note is REPEATED beside the verdict (G3), not only thousands of lines above it" \
    "$OUT" "NOTE (said at startup too): ceiling overrides:"
printf 'test-guards-for-diff.sh\t3600\r\n' > "$WORK/ceil-crlf.tsv"
_ceil_run "$WORK/ceil-crlf.tsv"
assert_contains "T7l a two-column CRLF row is INERT too (\`3600<CR>\` is not a number)" "$OUT" "has 1 INERT row(s)"
: > "$WORK/ceil-empty.tsv"
_ceil_run "$WORK/ceil-empty.tsv"
assert_contains "T7l an EMPTY file parses to ZERO usable rows, and says so"       "$OUT" "parsed to ZERO usable rows"
mkdir -p "$WORK/ceil-dir.tsv"
_ceil_run "$WORK/ceil-dir.tsv"
assert_contains "T7l a DIRECTORY passes \`[[ -r ]]\` and is still ZERO usable rows" "$OUT" "parsed to ZERO usable rows"
# MUST-NOT-FLIP: a well-formed row, with a trailing CR on a LATER column, is
# neither inert nor warned about — and it APPLIES (rc 0, no TIMEOUT).
printf 'test-guards-for-diff.sh\t3600\t12.5\ta note\r\n' > "$WORK/ceil-good.tsv"
_ceil_run "$WORK/ceil-good.tsv"
assert_eq           "T7l a well-formed row still APPLIES (rc 0)"                  "$RC" "0"
# The suite's own negative idiom: it defines `assert_eq`/`assert_contains` and
# NOT `assert_not_contains`. A first cut of these two rows called the helper
# anyway — rc 127, counted by nothing, and the suite still printed ALL TESTS
# PASSED with two assertions missing. Caught by arithmetic (84 + 10 != 92),
# because this suite carries no count guard.
for _neg in 'INERT row|T7l …with no warning at startup' 'NOTE (said at startup too)|T7l …and no note in the verdict section'; do
    if [[ "$OUT" == *"${_neg%%|*}"* ]]; then
        printf '  FAIL: %s — found %q\n' "${_neg#*|}" "${_neg%%|*}" >&2; FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "${_neg#*|}"; PASS=$(( PASS + 1 ))
    fi
done

# T7n — AN UNTERMINATED FINAL LINE IS STILL A LINE (#1571 F4 regression, caught by
# the rtev skeptic). The skeptic proved the construct and said reachability was
# UNMEASURED; this fixture makes it reachable by construction, which is the part
# that keeps the fix honest — a suite whose last write has no newline is exactly
# what a `printf` without `\n`, or a process killed mid-write, leaves behind.
#
# BOTH assertions are needed and they fail the same way alone: before the fix the
# loop DROPPED the line and `wc -l` MISSED it, so the header said 2 and the body
# printed 2 — internally consistent and both wrong. A reader checking one against
# the other got a false confirmation, so the count is asserted as well as the text.
{ printf '#!/usr/bin/env bash\n'
  printf 'printf "  FAIL: unterm-case — got x want y\\n" >&2\n'
  printf 'printf "noise-before-the-end\\n" >&2\n'
  printf 'printf "TAIL-LAST-NO-NEWLINE" >&2\n'
  printf 'exit 1\n'; } > "$FIX/red-unterminated.sh"
chmod +x "$FIX/red-unterminated.sh"
run --state "$WORK/t7n.tsv" "$FIX/red-unterminated.sh"
assert_contains "T7n the unterminated FINAL line is printed, with its suite" \
    "$OUT" "    red-unterminated.sh| TAIL-LAST-NO-NEWLINE"
assert_contains "T7n …and the header COUNTS it (3, not the 2 newlines)" \
    "$OUT" "--- red-unterminated.sh: stderr: all 3 line(s) ---"

# T7o — A NON-NUMERIC ACCOUNTING FLOOR MUST NOT KILL THE RUN (your-org/nexus-code
# #1616). `: "${NEXUS_ASSERT_ACCOUNTING_FLOOR:=20}"` guards UNSET, not SHAPE, so a
# leaked non-numeric value survived the default-assign and reached `(( … ))`, where
# bash reads the string as a VARIABLE NAME, finds it unset, and under `set -u`
# aborts the runner. Measured at the merge-base d58bc49a, in its own tree: the
# suite RAN (one PASS row) and the runner then died at `line 3839: SENT: unbound
# variable`, closing `STOPPED WITHOUT REACHING A VERDICT`.
#
# THAT IS THIS BUNDLE'S OWN SUBJECT, which is why the fix lives here rather than
# elsewhere: the log it leaves reads `selected=1 reported=1 pass=1` — every row
# present, none red — with NO END marker, so band-verdict.sh calls it
# `class=aborted` rc 4, while a reader grepping PASS rows would call it a pass.
# The bundle already DETECTS that shape; it should not also be able to CAUSE it.
printf '#!/usr/bin/env bash\necho "  PASS: ok"\necho "=== summary: 1 passed, 0 failed ==="\necho "ALL TESTS PASSED"\n' > "$FIX/floor-ok.sh"
chmod +x "$FIX/floor-ok.sh"
OUT=$(NEXUS_ASSERT_ACCOUNTING_FLOOR=SENT env -u KEEP_LOGS_DIR bash "$RUNNER" --timeout 60 "$FIX/floor-ok.sh" 2>&1); RC=$?
assert_eq       "T7o a NON-NUMERIC floor no longer aborts the runner (rc 0)" "$RC" "0"
assert_contains "T7o …the run reaches its VERDICT rather than dying without one" "$OUT" "=== run-tests: END rc=0 (COMPLETE and green) ==="
assert_contains "T7o …and the override is SAID, not silent"                      "$OUT" "is not a non-negative integer — using 20"
# MUST-NOT-FLIP: a well-formed floor is untouched and says nothing.
OUT=$(NEXUS_ASSERT_ACCOUNTING_FLOOR=25 env -u KEEP_LOGS_DIR bash "$RUNNER" --timeout 60 "$FIX/floor-ok.sh" 2>&1); RC=$?
assert_eq "T7o MUST-NOT-FLIP: a numeric floor still runs clean (rc 0)" "$RC" "0"
if [[ "$OUT" == *"is not a non-negative integer"* ]]; then
    printf '  FAIL: T7o a VALID floor was overridden — the guard fires on good input\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7o …and a VALID floor triggers no override message\n'; PASS=$(( PASS + 1 ))
fi

# T7h — the cap is bounded AND says what it dropped, first lines kept.
run --state "$WORK/t7h.tsv" "$FIX/red-flood.sh"
assert_contains "T7h the count is the TRUE total, not the cap" "$OUT" "45 failing-assertion line(s) on stderr"
# …and every line names its SUITE (#1571 F4), in the `grep -Hn` shape.
assert_contains "T7h the first failure is kept, and says whose it is" "$OUT" "    red-flood.sh:1:  FAIL: flood-1"
assert_contains "T7h the dropped remainder is counted"         "$OUT" "and 5 more (first 40 shown)"

# T7i — the parallel path again: three new helpers, each of which is `command
# not found` in an xargs child unless exported (T7d's hazard, new members).
run --jobs 2 --state "$WORK/t7i.tsv" "$FIX/red-evicted.sh" "$FIX/red-evicted-stdout.sh"
assert_contains "T7i --jobs 2: the evicted assertion survives the dispatcher" "$OUT" "FAIL: EVICTED-ASSERTION"
assert_contains "T7i --jobs 2: the kept-log line survives the dispatcher"     "$OUT" "full logs (kept):"
# THE POINT OF #1571 F4: at --jobs 2 the two reds' blocks INTERLEAVE, and each
# assertion line must still say whose it is. Asserted per line, for BOTH suites,
# and that NO assertion line is left bare — a bare one is the unattributable
# line the skeptic measured.
assert_contains "T7i --jobs 2: the stderr red's assertion line names its suite" "$OUT" "    red-evicted.sh:"
assert_contains "T7i --jobs 2: the stdout red's assertion line names its suite" "$OUT" "    red-evicted-stdout.sh:"
assert_eq       "T7i --jobs 2: NO failing-assertion line is left unattributed" \
    "$(grep -acE '^    [0-9]+:[[:space:]]*(FAIL|✗|not ok)' <<<"$OUT" || true)" "0"
# …AND THE TAIL (#1571 F4, the residual). e34a03ba attributed the assertion
# lines and left the tail bare: measured at d58bc49a, two reds at --jobs 2
# interleaved line by line and their tail lines had no owner. The tail is the
# ONLY evidence for a suite whose failure is not spelled `FAIL:`. Both fixtures
# write `noise-line-<i>` to stderr, so a bare one is countable — and the
# POSITIVE CONTROL comes first, because "0 bare lines" is also what a runner
# that printed no tail at all would score.
assert_contains "T7i --jobs 2: a tail line names its suite (stderr red)"  "$OUT" "    red-evicted.sh| noise-line-25"
assert_contains "T7i --jobs 2: a tail line names its suite (stdout red)"  "$OUT" "    red-evicted-stdout.sh| noise-line-25"
assert_contains "T7i --jobs 2: the tail HEADER names its suite too"       "$OUT" "--- red-evicted-stdout.sh: stderr: last 20 of"
assert_eq       "T7i --jobs 2: NO tail line is left unattributed" \
    "$(grep -acE '^    noise-line-[0-9]+' <<<"$OUT" || true)" "0"
if grep -qE '_rt_[a-z_]+: command not found' <<<"$OUT"; then
    printf '  FAIL: T7i --jobs 2: a #1561 helper is missing from the parallel children\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7i --jobs 2: no runner helper is "command not found"\n'; PASS=$(( PASS + 1 ))
fi

# T7m — (#1571 F5, the CLASS) the runner's caller-facing inputs do not reach the
# SUITE it launches. Measured at 4a2bc49b: 16 runner-nesting suites under an
# outer --keep-logs left 226 files in that dir where 32 were their own. Called
# DIRECTLY, not through `run`, which unsets KEEP_LOGS_DIR itself.
mkdir -p "$WORK/t7m-keep" "$WORK/t7m-fx"
printf '#!/usr/bin/env bash\nprintf "SAW keep=%%s rr=%%s rm=%%s ceil=%%s state=%%s slow=%%s\\n" "${KEEP_LOGS_DIR:-unset}" "${NEXUS_TEST_REQUIRE_RUN:-unset}" "${NEXUS_TEST_REQUIRE_MEASURED:-unset}" "${NEXUS_TEST_CEILING_FILE:-unset}" "${NEXUS_TEST_STATE_DIR:+set}" "${SLOW_TESTS:-unset}"\necho "  PASS: looked"\necho "=== summary: 1 passed, 0 failed ==="\necho "ALL TESTS PASSED"\n' > "$WORK/t7m-fx/test-t7m-env.sh"
cp "$WORK/t7m-fx/test-t7m-env.sh" "$WORK/t7m-fx/test-t7m-env-b.sh"; chmod +x "$WORK/t7m-fx"/*.sh
for _j in 1 2; do
    rm -f "$WORK/t7m-keep"/*
    SLOW_TESTS=1 NEXUS_TEST_CEILING_FILE="$WORK/ceil-good.tsv" env -u _RT_CEILING_FILE bash "$RUNNER" --jobs "$_j" --require-run \
        --keep-logs "$WORK/t7m-keep" "$WORK/t7m-fx/test-t7m-env.sh" "$WORK/t7m-fx/test-t7m-env-b.sh" >"$WORK/t7m.out" 2>&1
    _saw=$(cat "$WORK/t7m-keep/t7m-fx__test-t7m-env.sh.out" 2>/dev/null | grep -a '^SAW ' || true)
    assert_contains "T7m --jobs $_j: the suite does NOT inherit the outer --keep-logs / --require-run / ceiling file" \
        "$_saw" "SAW keep=unset rr=unset rm=unset ceil=unset"
    # MUST-NOT-FLIP: the keep-list still passes through (the helper's reasons).
    assert_contains "T7m --jobs $_j: …while NEXUS_TEST_STATE_DIR and the suite gates still reach it" \
        "$_saw" "state=set slow=1"
done
# THE RATCHET, AND ITS REACH STATED RATHER THAN IMPLIED. `_RT_SUITE_ENV_SCRUB` is
# hand-kept, and a hand-kept list is a denylist with a permissive default, so an
# input the derivation SEES must be classified here and a new one is red until
# somebody decides. UNDECIDED is a real class and says so: those inherit exactly
# as before this change.
#
# ERROR DIRECTION, because this ratchet is a predicate over source text and the
# first version of this comment claimed a reach it does not have (found by the
# rtev skeptic, delta 2). `th_runner_env_inputs` matches SIX NAME FAMILIES —
# NEXUS_TEST_*, KEEP_LOGS_DIR, RT_*, SLOW_TESTS, RUN_INTEGRATION, RUN_CC_HARNESS
# — so the ratchet covers "every input the DERIVATION SEES", NOT "every env input
# the runner reads". Measured with a `${NAME[:}#%/+=?-]}` probe over the same file:
# the derivation sees 15 of 28 OCCURRENCES IN THE FILE, so 13 are invisible here.
# OCCURRENCES IN THE FILE, not reads in the CODE, and the distinction is not
# pedantry: a grep counts comments. Exactly one token is comment-only —
# RUN_INTEGRATION, whose sole `${…}` form is documentation at run-tests.sh:659
# while its only real use greps a TEST FILE for the literal string — so the
# code-only figures are 14 of 27. **13 is invariant** (28-15 = 27-14) because that
# name is in BOTH sets and cancels, which is why the load-bearing number survives
# the correction while both absolutes were wrong. The
# caller-facing ones (no unconditional assignment anywhere, read with a default)
# are NEXUS_ASSERT_ACCOUNTING_FLOOR, NEXUS_CEILING_ADJACENT_PCT,
# NEXUS_CI_BASH_VERSION_FILE, NEXUS_KNOWN_LOCAL_RED, NEXUS_TMUX_SOCKET_CHECK and
# NEXUS_STATE_DIR; the rest are internals like PER_TEST_TIMEOUT and TALLY_FILE, or
# the deliberately handled TMPDIR/TMUX_TMPDIR, or the nexus prelude's BASH_ENV. An
# input added OUTSIDE the six families is therefore not red, not classified, and
# not a decision anybody is asked to make — the UNDER-covering direction, which is
# the safe one, but it must be said rather than left for a reader to discover.
#
# THE FIRST VERSION OF THIS NOTE SAID 27 AND 12, FROM A `${NAME:-}` PROBE — and it
# was itself an under-count by the very mechanism it exists to describe (the rtev
# skeptic's third delta). A `:-` probe cannot see a default-ASSIGN: the one name in
# the difference, NEXUS_ASSERT_ACCOUNTING_FLOOR, is read `: "${NAME:=20}"` at
# run-tests.sh:3925, and it is the WORST one to have missed — an inherited value
# WINS under `:=` (measured: 9999 survives), and raising it suppresses the
# broken-accounting detector at :3926 (`_n_pass_files >= FLOOR`), which is the
# fail-open direction. If you widen this measurement again, reconcile BY NAME and
# not by the delta: 27 was a strict SUBSET of 28, which is the only reason the
# single missing name could be identified at all.
#
# DELIBERATELY NOT WIDENED here: `th_scrub_inherited_runner_env` UNSETS everything
# the derivation returns minus its keep-list, so broadening the alternation to
# `NEXUS_[A-Z_]+` would start unsetting NEXUS_STATE_DIR and friends inside every
# nesting suite. That is a behavioural change with a blast radius of its own and
# belongs to a change that can measure it, not to a label fix.
_t7m_scrub=' KEEP_LOGS_DIR NEXUS_TEST_REQUIRE_MEASURED NEXUS_TEST_REQUIRE_RUN NEXUS_TEST_CEILING_FILE '
_t7m_keep=' NEXUS_TEST_JOBS NEXUS_TEST_DEADLINE_SCALE NEXUS_TEST_STATE_DIR SLOW_TESTS RUN_INTEGRATION RUN_CC_HARNESS '
_t7m_undecided=' NEXUS_TEST_NPROC_GUARD NEXUS_TEST_NPROC_HEADROOM NEXUS_TEST_NPROC_PROBE NEXUS_TEST_PRIVATE_ROOT_BASE NEXUS_TEST_REQUIRE_CI_PARITY NEXUS_TEST_SHELL NEXUS_TEST_TIMEOUT RT_FAILED_LOGS_DIR '
_t7m_unclassified=''; _t7m_n=0
while IFS= read -r _v; do
    [[ -n "$_v" ]] || continue
    _t7m_n=$(( _t7m_n + 1 ))
    case "$_t7m_scrub$_t7m_keep$_t7m_undecided" in *" $_v "*) ;; *) _t7m_unclassified+="$_v " ;; esac
done < <(bash -c '. "$1" >/dev/null 2>&1; th_runner_env_inputs "$2"' _ "$_test_dir/_test_helpers.sh" "$RUNNER")
# ^ In a SUBSHELL: this suite defines its own assert_* and does not source
#   _test_helpers.sh, so a bare `th_runner_env_inputs` here is rc 127, counted
#   by nothing — and the CONTROL below is what would have said so.
assert_eq "T7m ratchet: every input the DERIVATION SEES is classified (scrub / keep / undecided) — six name families, not every env input the runner reads" "$_t7m_unclassified" ""
# A derivation broken into finding nothing would pass the line above vacuously.
if (( _t7m_n >= 10 )); then
    printf '  PASS: T7m ratchet CONTROL: the derivation found %d inputs (floor 10)\n' "$_t7m_n"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: T7m ratchet CONTROL: the derivation found only %d inputs — the line above is vacuous\n' "$_t7m_n" >&2; FAIL=$(( FAIL + 1 ))
fi
for _v in $_t7m_scrub; do
    case " $(sed -n "s/^export _RT_SUITE_ENV_SCRUB='\(.*\)'\$/\1/p" "$RUNNER") " in *" $_v "*) ;; *) _t7m_unclassified+="MISSING-FROM-RUNNER:$_v " ;; esac
done
assert_eq "T7m ratchet: and the runner's own list carries every name this test calls scrubbed" "$_t7m_unclassified" ""

# ---- summary ---------------------------------------------------------------
echo
if (( SKIP > 0 )); then
    printf '=== summary: %d passed, %d failed, %d SKIPPED (precondition absent — NOT covered) ===\n' \
        "$PASS" "$FAIL" "$SKIP"
else
    printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
fi
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
