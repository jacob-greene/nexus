#!/usr/bin/env bash
# Tests for bootstrap-recover.sh's READ-ONLY-incident wake (skeptic F2
# residual on your-org/nexus-code#1799).
#
# At a read-only onset the watcher pastes every worker "STOP … WAIT for a
# RESUME note" (monitor/watcher/_fs_guard.sh:_fs_broadcast_workers). Incidents
# here end in a sandbox restart, which never sends the RESUME, and a worker
# idle at onset has an idle heartbeat, so `spawn-worker.sh --resume` sends it
# no nudge. Recovery must notice the outstanding STOP in watcher.log and
# resume that worker with `--nudge-ro`.
#
# Strategy: source the REAL bootstrap-recover.sh (sourcing runs no main) in a
# subshell with NEXUS_STATE_DIR pointed at a per-case fixture, a stub
# spawn-worker that records its argv, and `_recover_window_exists` stubbed
# false; seed watcher.log (+ .1) and the action log; call `recover_worker`.
# Hermetic: no tmux, no network, no real state dir.
#
# Cases:
#   R1. STOP delivered, no RESUME, spawn BEFORE the STOP  → --nudge-ro.
#   R2. STOP then RESUME delivered                         → no nudge.
#   R3. STOP, then a spawn (resume) event AFTER it         → no nudge (once only).
#   R4. STOP refused (nothing typed)                       → no nudge.
#   R5. STOP only in the rotated watcher.log.1             → --nudge-ro.
#   R6. a SIBLING with a shared stem (w1-sk) got the STOP  → w1 not nudged.
#   R7. STOP unconfirmed (pasted, Enter, no receipt)       → --nudge-ro.
#   R8. STOP, then a RESUME that was REFUSED               → --nudge-ro.
#   R9. no watcher log at all                              → no nudge.
#   R10. the line written by the REAL _fs_broadcast_workers is parsed.
#
# Run: bash monitor/watcher/test-bootstrap-recover-ro-nudge.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_real_test_dir/_test_helpers.sh"
REAL_RECOVER="$_real_test_dir/../bootstrap-recover.sh"

. "$_real_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        monitor/bootstrap-recover.sh \
        monitor/watcher/_fs_guard.sh \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"

fail() { echo "  FAIL: $*"; _th_fail; }
pass() { echo "  PASS: $*"; _th_pass; }

[[ -r "$REAL_RECOVER" ]] || th_abort "cannot read $REAL_RECOVER"

new_case() {
    CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/recover-ro-$1-XXXXXX") || th_abort "mktemp failed"
    SD="$CASE_ROOT/state"
    mkdir -p "$SD" "$CASE_ROOT/config"
    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$CASE_ROOT/config/load.sh"
    chmod +x "$CASE_ROOT/config/load.sh"
    : > "$SD/action-log.jsonl"
    STUB="$CASE_ROOT/spawn-worker-stub.sh"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$CASE_ROOT/argv" > "$STUB"
    chmod +x "$STUB"
}
end_case() { rm -rf "$CASE_ROOT"; }

# ev <ts> <event> <window> [extra-json]
ev() {
    printf '{"ts":"%s","agent":"monitor","event":"%s","window":"%s"%s}\n' \
        "$1" "$2" "$3" "${4:-}" >> "$SD/action-log.jsonl"
}
# bc <ts> <stop|resume> <window> <delivery> [file-suffix] — one broadcast line,
# byte-for-byte the shape _fs_broadcast_workers logs.
bc() {
    printf '[%s] fs-guard: worker broadcast (%s) to %s — %s\n' "$1" "$2" "$3" "$4" \
        >> "$SD/watcher.log${5:-}"
}

# run_recover <window> — ARGV = the stub's recorded argv, ERR = [recover] log.
run_recover() {
    : > "$CASE_ROOT/argv"
    (
        export NEXUS_ROOT="$CASE_ROOT" NEXUS_STATE_DIR="$SD" \
               NEXUS_SERVICES_REGISTRY="$CASE_ROOT/no-registry" \
               RECOVER_SPAWN_WORKER_BIN="$STUB"
        # shellcheck disable=SC1090
        source "$REAL_RECOVER" || exit 90
        _recover_window_exists() { return 1; }
        recover_worker "$1" >/dev/null
    ) 2>"$CASE_ROOT/err"
    ARGV=$(cat "$CASE_ROOT/argv")
    ERR=$(cat "$CASE_ROOT/err")
}

expect_nudge() {   # <label> <yes|no>
    local has=no
    [[ " $ARGV " == *" --nudge-ro "* ]] && has=yes
    if [[ -z "$ARGV" ]]; then
        fail "$1 — the spawn-worker stub was never called; err: $(tr '\n' '|' <<<"$ERR")"
    elif [[ "$has" == "$2" ]]; then
        pass "$1"
    else
        fail "$1 — want --nudge-ro=$2, argv [$ARGV]; err: $(tr '\n' '|' <<<"$ERR")"
    fi
}

echo '=== R1: STOP delivered, no RESUME, spawned before → nudge ==='
new_case r1
ev 2026-10-12T07:00:00-07:00 spawn w1
bc 2026-10-12T08:35:40-07:00 stop w1 delivered
run_recover w1
expect_nudge 'R1 outstanding STOP → --nudge-ro' yes
if grep -qF -- "read-only STOP at 2026-10-12T08:35:40-07:00" <<<"$ERR"; then
    pass 'R1 the log names the STOP it acts on'
else
    fail "R1 log line missing; err: $(tr '\n' '|' <<<"$ERR")"
fi
end_case

echo '=== R2: STOP then RESUME delivered → no nudge ==='
new_case r2
ev 2026-10-12T07:00:00-07:00 spawn w1
bc 2026-10-12T08:35:40-07:00 stop w1 delivered
bc 2026-10-12T09:00:00-07:00 resume w1 delivered
run_recover w1
expect_nudge 'R2 RESUME delivered clears the STOP' no
end_case

echo '=== R3: a resume after the STOP already happened → no second nudge ==='
new_case r3
ev 2026-10-12T07:00:00-07:00 spawn w1
bc 2026-10-12T08:35:40-07:00 stop w1 delivered
ev 2026-10-12T10:00:00-07:00 spawn w1 ',"mode":"resume"'
run_recover w1
expect_nudge 'R3 a later spawn event consumes the STOP' no
end_case

echo '=== R4: STOP refused → no nudge ==='
new_case r4
ev 2026-10-12T07:00:00-07:00 spawn w1
bc 2026-10-12T08:35:40-07:00 stop w1 'refused (input box holds typed or undecidable text, or an overlay is up; nothing typed)'
run_recover w1
expect_nudge 'R4 a refused STOP was never seen' no
end_case

echo '=== R5: STOP only in the rotated log → nudge ==='
new_case r5
ev 2026-10-12T07:00:00-07:00 spawn w1
bc 2026-10-12T08:35:40-07:00 stop w1 delivered .1
bc 2026-10-12T08:35:40-07:00 stop w2 delivered
run_recover w1
expect_nudge 'R5 watcher.log.1 is read' yes
end_case

echo '=== R6: a shared-stem sibling got the STOP → w1 not nudged ==='
new_case r6
ev 2026-10-12T07:00:00-07:00 spawn w1
bc 2026-10-12T08:35:40-07:00 stop w1-sk delivered
run_recover w1
expect_nudge 'R6 w1-sk STOP does not count for w1' no
end_case

echo '=== R7: STOP unconfirmed → nudge ==='
new_case r7
ev 2026-10-12T07:00:00-07:00 spawn w1
bc 2026-10-12T08:35:40-07:00 stop w1 'unconfirmed (pasted and Enter sent; no receipt; not re-pasted)'
run_recover w1
expect_nudge 'R7 an unconfirmed STOP counts' yes
end_case

echo '=== R8: STOP, then a REFUSED resume → nudge ==='
new_case r8
ev 2026-10-12T07:00:00-07:00 spawn w1
bc 2026-10-12T08:35:40-07:00 stop w1 delivered
bc 2026-10-12T09:00:00-07:00 resume w1 'refused (input box holds typed or undecidable text, or an overlay is up; nothing typed)'
run_recover w1
expect_nudge 'R8 only a DELIVERED resume clears it' yes
end_case

echo '=== R9: no watcher log → no nudge (control) ==='
new_case r9
ev 2026-10-12T07:00:00-07:00 spawn w1
run_recover w1
expect_nudge 'R9 nothing to owe' no
end_case

echo '=== R10: the REAL broadcaster log line is what recovery parses ==='
# The ledger is a log FORMAT shared by two files. Produce it with the real
# _fs_broadcast_workers and main.sh's log() shape, so a reworded log line in
# _fs_guard.sh turns this red instead of silently disarming the wake.
new_case r10
ev 2026-10-12T07:00:00-07:00 spawn w1
(
    export NEXUS_DEGRADED_RUNDIR="$CASE_ROOT/run"
    log() { printf '[%s] %s\n' "$(date -Is)" "$*" >> "$SD/watcher.log"; }
    r10_paste() { return 0; }
    r10_workers() { printf 'w1\t0\t1\n'; }
    # shellcheck disable=SC1091
    source "$_real_test_dir/_fs_guard.sh" || exit 90
    STATE_DIR="$SD" FS_NOTE_PASTE_FN=r10_paste FS_WORKER_LIST_FN=r10_workers \
        _fs_broadcast_workers stop 0
) 2>/dev/null
run_recover w1
expect_nudge 'R10 a STOP logged by the real broadcaster is found' yes
end_case

EXPECTED_ASSERTIONS=11
if (( PASS + FAIL != EXPECTED_ASSERTIONS )); then
    fail "assertion total — ran $(( PASS + FAIL )), EXPECTED_ASSERTIONS=$EXPECTED_ASSERTIONS"
fi
th_summary_and_exit
