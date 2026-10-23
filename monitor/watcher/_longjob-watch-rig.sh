#!/usr/bin/env bash
# monitor/watcher/_longjob-watch-rig.sh — the SHARED hermetic rig of the two
# longjob-watch dispatcher suites, test-longjob-watch.sh (probe contract, emit
# policy, caps, never-exit, the declare-wait bridge, await) and
# test-longjob-watch-ledger.sh (ledger freshness, the kill switch, the single
# writer, the owner rules, chaperon back-off, --for-lead, usage refusals).
# They were ONE suite until it ran 757-874 s of its 900 s per-suite ceiling
# under full-run load (your-org/nexus-code#1877); the split moved sections
# verbatim, so the two suites' assertions together are exactly the original
# 281. SOURCED, never run: the caller sets `set -uo pipefail` and `_test_dir`
# first. Defines PASS/FAIL + ok/bad, WORK + its EXIT trap, DPIDS, the event
# waits, the PATH-front sacct/squeue stubs and the fixture NEXUS_ROOT.
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LJ="$REPO_ROOT/monitor/longjob-watch.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
WORK=$(mktemp -d -t lj-test-XXXXXX)
DPIDS=()
# ---- EVENT WAITS (your-org/nexus-code#1704) ----------------------------------
# The dispatcher rigs below used to wait with fixed `sleep 7` / `sleep 9` per
# poll (≈ 1.5–2 polls of slack each). The poll floor is 5 s inside
# longjob-watch.sh, so the interval cannot be lowered here; instead every wait
# keys on an EVENT the dispatcher writes, with a deadline that only turns a
# hang into a red (never a pass):
#   - a watch's .last_probe is the pass's START second (set by _update/_retire);
#   - the ledger's pass-END write has note exactly "ok" (mid-pass writes say
#     "ok (mid-pass …)"), and pass ends are ≥ poll_seconds (5 s) apart.
_wait_for() {   # <backstop-seconds> <cmd…> — true as soon as cmd is; false at the backstop
    local dl=$(( SECONDS + $1 )); shift
    until "$@"; do (( SECONDS >= dl )) && return 1; sleep 0.2; done
}
_armed() {   # <spool> [pid] — the dispatcher has armed (service=polling), optionally THIS pid
    [[ "$(jq -r '.service // empty' "$1/dispatcher.json" 2>/dev/null)" == polling ]] || return 1
    [[ -z "${2:-}" || "$(jq -r '.pid // empty' "$1/dispatcher.json" 2>/dev/null)" == "$2" ]]
}
_svc_is() { [[ "$(jq -r '.service // empty' "$1/dispatcher.json" 2>/dev/null)" == "$2" ]]; }
_reason_is() { [[ "$(jq -r '.retired_reason // empty' "$1/watches/$2.json" 2>/dev/null)" == "$3" ]]; }
_settled() {   # <spool> <id> <T> — <id> was probed in a pass that STARTED after second T, and that pass has ENDED
    local lp ll note
    lp=$(jq -r '.last_probe // 0' "$1/watches/$2.json" 2>/dev/null)
    [[ "$lp" =~ ^[0-9]+$ ]] && (( lp > $3 )) || return 1
    read -r ll note < <(jq -r '"\(.last_poll // 0) \(.note // "")"' "$1/dispatcher.json" 2>/dev/null) || return 1
    [[ "$note" == ok && "$ll" =~ ^[0-9]+$ ]] && (( ll >= lp ))
}
_poll_after() {   # <spool> <id> — wait for ONE complete pass, begun after now, that probed <id>
    local t; t=$(date +%s)
    _wait_for 90 _settled "$1" "$2" "$t" || bad "rig: no completed pass probing $2 within 90 s (since $t): $(jq -c '{state,last_probe}' "$1/watches/$2.json" 2>&1) ledger=$(jq -c '{last_poll,note}' "$1/dispatcher.json" 2>&1)"
}
_pass_end_after() {   # <spool> <after-second> [pid] — a pass-END write later than <after-second>; sets _PE_LAST
    local ll p note
    read -r ll p note < <(jq -r '"\(.last_poll // 0) \(.pid // 0) \(.note // "")"' "$1/dispatcher.json" 2>/dev/null) || return 1
    [[ "$note" == ok && "$ll" =~ ^[0-9]+$ ]] && (( ll > $2 )) || return 1
    [[ -z "${3:-}" || "$p" == "$3" ]] || return 1
    _PE_LAST=$ll
}
_passes_since() {   # <spool> <N> <T> [pid] — N distinct pass-END writes at or after second T (pass ends are ≥ 5 s apart)
    local prev=$(( $3 - 1 )) i
    for (( i = 0; i < $2; i++ )); do
        _wait_for 90 _pass_end_after "$1" "$prev" "${4:-}" || return 1
        prev=$_PE_LAST
    done
}
# A fixed `sleep 7` raced a 5 s poll cadence under load (`--jobs 6` band, one
# run, 1 red in 3 — `FAIL: F3 unknown`, your-org/nexus-code#1317). So wait
# until every named watch carries a retired_reason AND the dispatcher has
# finished the pass that retired it — its end-of-pass ledger write (note
# exactly "ok", last_poll ≥ the latest retired_at). The second half matters:
# the wait side of a retirement (_resolve_waits) and the line itself run AFTER
# _retire in the same pass, so stopping at the retired_reason alone would read
# mid-pass. On timeout the caller falls through and its assertions go red on
# their own evidence — a timeout never passes.
_retired_settled() {   # <spool> <id>…
    local sp="$1" id ra lp note maxra=0; shift
    for id in "$@"; do
        ra=$(jq -r 'if (.retired_reason // "") != "" then (.retired_at // 0) else empty end' "$sp/watches/$id.json" 2>/dev/null)
        [[ "$ra" =~ ^[0-9]+$ ]] || return 1
        (( ra > maxra )) && maxra=$ra
    done
    note=$(jq -r '.note // ""' "$sp/dispatcher.json" 2>/dev/null); lp=$(jq -r '.last_poll // 0' "$sp/dispatcher.json" 2>/dev/null)
    [[ "$note" == ok && "$lp" =~ ^[0-9]+$ ]] && (( lp >= maxra ))
}
_lines_ge() { (( $(grep -c "${3:-^longjob-watch: }" "$1" 2>/dev/null) >= $2 )); }   # <file> <n> [pattern]
_lp_gt() { local l; l=$(jq -r '.last_poll // 0' "$1/dispatcher.json" 2>/dev/null); [[ "$l" =~ ^[0-9]+$ ]] && (( l > $2 )); }
# SIGCONT first: a TERM sent to a STOPPED process stays pending until it is
# continued, so a run that dies inside the #1834 freeze window below would
# otherwise leave a stopped dispatcher behind forever.
# Multi-line on purpose: test-tmux-window-resolver's D1 awk scans this file as
# production shell and carries an unclosed one-line function into the NEXT
# file, so the rig's last function must close on a line of its own.
cleanup() {
    local p
    for p in "${DPIDS[@]:-}"; do [[ -n "$p" ]] && { kill -CONT "$p"; kill "$p"; } 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"; mkdir -p "$NEXUS_STATE_DIR/heartbeat"
export NEXUS_LONGJOB_KEY="t1"
export MONITOR_LONGJOB_POLL_SECONDS=5
export MONITOR_LONGJOB_PROBE_TIMEOUT_SECONDS=10
unset NEXUS_WORKER_WINDOW NEXUS_ORCHESTRATOR_WINDOW NEXUS_LONGJOB_WINDOW CLAUDE_CODE_SESSION_ID NEXUS_LONGJOB_SESSION_ID 2>/dev/null || true
SPOOL="$NEXUS_STATE_DIR/longjob/t1"

# ---- PATH-front stubs: sacct / squeue driven by files -----------------------
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/sacct" <<'EOF'
#!/usr/bin/env bash
# emits the contents of $LJ_SACCT_FILE (one "State|ExitCode" line, or empty);
# every call also appends its argv to $LJ_SACCT_CALLS, so a case can assert
# that sacct was NEVER asked (your-org/nexus-code#1727).
[[ -n "${LJ_SACCT_CALLS:-}" ]] && printf '%s\n' "$*" >> "$LJ_SACCT_CALLS"
# $LJ_SACCT_FAIL present: the sandbox chaperon's jam answer (#1728).
[[ -n "${LJ_SACCT_FAIL:-}" && -e "$LJ_SACCT_FAIL" ]] && { echo 'error: failed to read chaperon response (timeout or error)' >&2; exit 1; }
[[ -f "${LJ_SACCT_FILE:-}" ]] && cat "$LJ_SACCT_FILE"; exit 0
EOF
cat > "$STUB/squeue" <<'EOF'
#!/usr/bin/env bash
# $LJ_SQUEUE_FILE holds `squeue -u … -o '%i %T'` rows ("<id> <STATE>").
# A `-j` query returns EMPTY at rc 0 for a job that IS queued: that is the
# sandbox's measured behaviour on ~25% of calls (your-org/nexus-code#1744),
# made deterministic here so a probe still asking `-j` cannot pass.
for a in "$@"; do case "$a" in -j|-j*|--job*|--jobs*) exit 0 ;; esac; done
[[ -f "${LJ_SQUEUE_FILE:-}" ]] && cat "$LJ_SQUEUE_FILE"; exit 0
EOF
chmod +x "$STUB/sacct" "$STUB/squeue"
export PATH="$STUB:$PATH"
export LJ_SACCT_FILE="$WORK/sacct.out" LJ_SQUEUE_FILE="$WORK/squeue.out"
export LJ_SACCT_CALLS="$WORK/sacct.calls"

# ---- fixture NEXUS_ROOT with a stub async-run.sh ------------------------------
FROOT="$WORK/froot"; mkdir -p "$FROOT/monitor"
cat > "$FROOT/monitor/async-run.sh" <<'EOF'
#!/usr/bin/env bash
# --disposition-line <token> → canned answers keyed on the token
[[ "${1:-}" == --disposition-line ]] || exit 2
case "${2:-}" in
  tok-live)   printf 'live|running|pid=1 alive\n' ;;
  tok-ok)     printf 'settled|terminal|rc=0 elapsed=3s\n' ;;
  tok-quiet)  printf 'settled|terminal|rc=0 elapsed=3s out=0B err=0B NO-OUTPUT-CAPTURED: the job wrote NOTHING to either stream, so this rc is UNCORROBORATED — it is the status of the payload%ss LAST command, and a payload that redirects its own output leaves this surface blank. Find the payload%ss own log before treating this rc as a verdict on its work\n' "'" "'" ;;
  tok-bad)    printf 'settled|terminal|rc=2 elapsed=3s\n' ;;
  tok-gone)   printf 'gone|died|pid gone, no status file\n' ;;
  *)          printf '\n' ;;
esac
EOF
chmod +x "$FROOT/monitor/async-run.sh"
