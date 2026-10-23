#!/usr/bin/env bash
# monitor/watcher/test-watcher-supervise-probe.sh — the watcher supervisor as a
# persistent longjob-watch (your-org/nexus-code#1532):
#   P*  monitor/watcher-supervise-probe.sh — the cmd-probe vocabulary (alive →
#       1, down → 2, never 0/3), one detached revival per outage, a revival
#       that SURVIVES the dispatcher's probe timeout killing the probe;
#   A*  monitor/arm-watcher-supervisor.sh against a stub longjob-watch — the
#       watch shape it asks for, idempotence, retired → re-added, NOT ARMED →
#       exit 3 + the Monitor-lease fallback, MUTED → kept;
#   E*  END TO END on the real longjob-watch.sh dispatcher (hermetic state):
#       a watcher killed five times is revived five times with NO turn taken,
#       and the watch is still live after ten events — past the default
#       per-watch cap of 8 that would RETIRE an ordinary persistent watch.
#       E0 is that potency control: the same rig with the default cap retires.
#
# HERMETIC: NEXUS_STATE_DIR is a temp dir, the session key is pinned
# (NEXUS_LONGJOB_KEY), the tick and the revive are stubs driven by a file, and
# every dispatcher is this suite's own child, killed by recorded pid.
#
# MUTATION FLIP SET, predicted before the first mutation run:
#   FLIPS    probe `if (( tick_rc == 0 ))` arm (P1, P2 red); probe `exit 2` after
#            launch → any other code (P2 red); the in-flight lock probe (P3: two
#            revivals); arm helper `--max-events 100000` (E1: watch retired at the
#            cap); `--no-declare` (A1 shape assertion).
#   NO FLIP  the arm helper's `--desc` text (nothing reads it).
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
PROBE="$REPO_ROOT/monitor/watcher-supervise-probe.sh"
ARM="$REPO_ROOT/monitor/arm-watcher-supervisor.sh"
LJ="$REPO_ROOT/monitor/longjob-watch.sh"
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
WORK=$(mktemp -d -t wsp-test-XXXXXX)
DPIDS=()
cleanup() { local p; for p in "${DPIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"; mkdir -p "$NEXUS_STATE_DIR"
unset NEXUS_WORKER_WINDOW NEXUS_ORCHESTRATOR_WINDOW NEXUS_LONGJOB_WINDOW CLAUDE_CODE_SESSION_ID NEXUS_LONGJOB_SESSION_ID 2>/dev/null || true

# Stubs. The tick exits 1 while $WORK/down exists; the revive clears it after
# $REVIVE_SLEEP seconds and records each call.
cat > "$WORK/tick" <<'EOF'
#!/usr/bin/env bash
[[ -e "$WSP_DOWN" ]] && exit 1; exit 0
EOF
cat > "$WORK/revive" <<'EOF'
#!/usr/bin/env bash
echo "call $(date +%s)" >> "$WSP_CALLS"
sleep "${REVIVE_SLEEP:-0}"
rm -f "$WSP_DOWN"
EOF
chmod +x "$WORK/tick" "$WORK/revive"
export SUPERVISE_TICK_BIN="$WORK/tick" SUPERVISE_REVIVE_BIN="$WORK/revive"
export WSP_DOWN="$WORK/down" WSP_CALLS="$WORK/calls"
REVLOG="$NEXUS_STATE_DIR/watcher-supervisor-revive.log"
ncalls() { [[ -f "$WSP_CALLS" ]] && wc -l < "$WSP_CALLS" | tr -d ' ' || echo 0; }
# wait_for <seconds> <command…> — poll a predicate with a deadline.
wait_for() { local d=$(( $(date +%s) + $1 )); shift; until "$@"; do (( $(date +%s) >= d )) && return 1; sleep 0.5; done; }

echo "=== P: the probe's vocabulary ==="
rm -f "$WSP_DOWN" "$WSP_CALLS"
out=$("$PROBE"); rc=$?
(( rc == 1 )) && [[ "$out" == *alive* ]] && [[ "$(ncalls)" == 0 ]] \
    && ok "P1 watcher alive → exit 1 (running), no revival" || bad "P1 rc=$rc out=$out calls=$(ncalls)"

touch "$WSP_DOWN"
out=$("$PROBE"); rc=$?
(( rc == 2 )) && [[ "$out" == *"revival launched"* ]] && ok "P2 watcher down → exit 2 (failed), revival launched" || bad "P2 rc=$rc out=$out"
wait_for 10 test ! -e "$WSP_DOWN" && [[ "$(ncalls)" == 1 ]] && grep -q 'revive end rc=0' "$REVLOG" \
    && ok "P2 the detached revival ran once and logged its exit status" || bad "P2 calls=$(ncalls) log=$(cat "$REVLOG" 2>/dev/null)"

rm -f "$WSP_CALLS"; touch "$WSP_DOWN"
REVIVE_SLEEP=4 "$PROBE" >/dev/null
wait_for 5 test -s "$WSP_CALLS"
out=$(REVIVE_SLEEP=4 "$PROBE"); rc=$?
(( rc == 2 )) && [[ "$out" == *"already in flight"* ]] && ok "P3 a second probe during a revival reports it in flight (exit 2)" || bad "P3 rc=$rc out=$out"
wait_for 10 test ! -e "$WSP_DOWN"
[[ "$(ncalls)" == 1 ]] && ok "P3 exactly one revival per outage" || bad "P3 calls=$(ncalls)"

# P4: the dispatcher runs each probe under `timeout` (30 s by default). A
# revival that outlives the probe must not be killed with it.
rm -f "$WSP_CALLS"; touch "$WSP_DOWN"
REVIVE_SLEEP=3 timeout -k 1 1 "$PROBE" >/dev/null 2>&1
wait_for 10 test ! -e "$WSP_DOWN" && [[ "$(ncalls)" == 1 ]] \
    && ok "P4 a revival outlives the probe's timeout kill" || bad "P4 calls=$(ncalls) down=$([[ -e $WSP_DOWN ]] && echo yes)"

# P5: the revive DAEMONIZES a long-lived child (as revive-watcher.sh does:
# the restarted watcher outlives it). That child must NOT inherit the revive
# lock, or every later outage reads "already in flight" and is never revived.
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "call $(date +%s)" >> "$WSP_CALLS"' \
    'setsid sleep 30 </dev/null >/dev/null 2>&1 &' \
    'echo $! >> "$WSP_DAEMONS"' \
    'rm -f "$WSP_DOWN"' > "$WORK/revive-daemon"
chmod +x "$WORK/revive-daemon"
export WSP_DAEMONS="$WORK/daemons"
rm -f "$WSP_CALLS" "$REVLOG"; touch "$WSP_DOWN"
SUPERVISE_REVIVE_BIN="$WORK/revive-daemon" "$PROBE" >/dev/null
wait_for 10 test ! -e "$WSP_DOWN"
wait_for 5 grep -q 'revive end' "$REVLOG"
touch "$WSP_DOWN"
out=$(SUPERVISE_REVIVE_BIN="$WORK/revive-daemon" "$PROBE"); rc=$?
wait_for 10 test ! -e "$WSP_DOWN"
[[ "$out" == *"revival launched"* ]] && [[ "$(ncalls)" == 2 ]] \
    && ok "P5 a revive that daemonizes a child does not pin the lock: the next outage is revived" \
    || bad "P5 second outage not revived: out=$out calls=$(ncalls)"
while read -r _p; do kill "$_p" 2>/dev/null; done < "$WSP_DAEMONS"

# P6-P9: ONE REVIVAL PER STATE CHANGE, NOT ONE PER POLL (skeptic F1 on #1635:
# 4 polls -> 4 revive runs while revive refused). A revive stub with a chosen
# exit code that leaves the watcher DOWN; each case polls FIVE times and counts
# revive runs AND revive-log lines.
printf '%s\n' '#!/usr/bin/env bash' 'echo "call $(date +%s)" >> "$WSP_CALLS"' 'exit "${WSP_REVIVE_RC:-0}"' > "$WORK/revive-rc"
chmod +x "$WORK/revive-rc"
S="$NEXUS_STATE_DIR"
fresh() { rm -f "$WSP_CALLS" "$REVLOG" "$S/watcher-supervisor-revive.last" "$S/watcher-supervisor-revive.latched" "$S/watcher-stop-requested"; touch "$WSP_DOWN"; }
# Assign, then validate the SHAPE: `grep -c … || echo 0` prints "0" TWICE on an
# existing empty file (grep -c prints 0 AND exits 1) — count-fallback-lint.
loglines() { local n; n=$(grep -c . "$REVLOG" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
# poll5 <revive-rc> — five polls, each waiting for any revive it launched to end
poll5() {
    local i
    for i in 1 2 3 4 5; do
        LAST_OUT=$(WSP_REVIVE_RC="$1" SUPERVISE_REVIVE_BIN="$WORK/revive-rc" SUPERVISE_REVIVE_BACKOFF=600 "$PROBE"); LAST_RC=$?
        wait_for 5 bash -c '! [ -e "$1" ] || ! flock -n "$1" true' _ "$S/watcher-supervisor-revive.lock" >/dev/null 2>&1
        sleep 0.3
    done
}

# P6 intentional stop: five polls, ZERO revive runs, ZERO revive-log lines.
fresh; touch "$S/watcher-stop-requested"; poll5 0
[[ $LAST_RC == 2 && "$LAST_OUT" == *"INTENTIONAL stop"* && "$(ncalls)" == 0 && "$(loglines)" == 0 ]] \
    && ok "P6 intentional stop: 5 polls -> 0 revive runs, 0 log lines" \
    || bad "P6 rc=$LAST_RC calls=$(ncalls) log=$(loglines) out=$LAST_OUT"

# P7 crash-loop guard (exit 3): five polls -> ONE revive run (2 log lines: its
# start and end), then LATCHED; the guard is a STOP, not a rate limit.
fresh; poll5 3
[[ $LAST_RC == 0 && "$LAST_OUT" == *"ORCHESTRATOR MUST ACT"* && "$(ncalls)" == 1 && "$(loglines)" == 2 ]] \
    && ok "P7 crash-loop guard (revive exit 3): 5 polls -> 1 revive run, then LATCHED and answering done (the one wake)" \
    || bad "P7 rc=$LAST_RC calls=$(ncalls) log=$(loglines) out=$LAST_OUT"
# …and the latch lifts only on a STATE CHANGE: the watcher seen alive, then a
# new outage with no refusal is revived.
# The call counter is RESET first: without that, a mutant that never latched
# (so part 1 already left 2 calls) satisfied "calls == 2" with NO new revival
# (mutation-gate, latch if-false: predicted flip, did not — a vacuous pass).
latched_before=$([[ -e "$S/watcher-supervisor-revive.latched" ]] && echo yes || echo no)
rm -f "$WSP_DOWN"; "$PROBE" >/dev/null
cleared=$([[ -e "$S/watcher-supervisor-revive.latched" ]] && echo no || echo yes)
rm -f "$WSP_CALLS"; touch "$WSP_DOWN"
SUPERVISE_REVIVE_BIN="$WORK/revive-rc" "$PROBE" >/dev/null; wait_for 10 test "$(ncalls)" = 1
[[ "$latched_before" == yes && "$cleared" == yes && "$(ncalls)" == 1 ]] \
    && ok "P7 …the latch clears once the watcher is seen alive, and the next outage is revived" \
    || bad "P7 latch lifecycle wrong: latched_before=$latched_before cleared_on_alive=$cleared new_revives=$(ncalls)"

# P8 read-only state dir (exit 4): same stop.
fresh; poll5 4
[[ $LAST_RC == 0 && "$(ncalls)" == 1 && "$(loglines)" == 2 ]] \
    && ok "P8 read-only state dir (revive exit 4): 5 polls -> 1 revive run, then LATCHED (done)" \
    || bad "P8 rc=$LAST_RC calls=$(ncalls) log=$(loglines)"

# P9 alive-and-advancing refusal (exit 5) is NOT latched (ncbundle4sk B1): the
# tick keeps saying DOWN, revive says 5, the probe BACKS OFF — one revive per
# window, and it never answers `running` (no fake recovery). Then the watcher
# TRULY dies (revive would now restart it): the next revive after the window
# fires and restores it.
fresh; poll5 5
[[ $LAST_RC == 2 && "$LAST_OUT" == *"backing off"* && "$(ncalls)" == 1 && "$(loglines)" == 2 ]] \
    && ok "P9 alive-and-advancing (revive exit 5) under a persistent tick-DOWN: 5 polls -> 1 revive run, backing off, NEVER reported running" \
    || bad "P9 rc=$LAST_RC calls=$(ncalls) log=$(loglines) out=$LAST_OUT"
[[ ! -e "$S/watcher-supervisor-revive.latched" ]] \
    && ok "P9 …and exit 5 writes NO latch" || bad "P9 exit 5 latched"
rm -f "$WSP_CALLS"
WSP_REVIVE_RC=0 SUPERVISE_REVIVE_BIN="$WORK/revive-rc" SUPERVISE_REVIVE_BACKOFF=0 "$PROBE" >/dev/null
wait_for 10 test "$(ncalls)" = 1
[[ "$(ncalls)" == 1 ]] \
    && ok "P9 …the watcher then truly dies: after one backoff window a revive DOES follow" \
    || bad "P9 no revive after the window: calls=$(ncalls)"

# P10 a FAILED restart (other non-zero) backs off inside the window and is
# retried after it — recovery is not latched off for a transient failure.
fresh; poll5 1
n_in=$(ncalls)
WSP_REVIVE_RC=1 SUPERVISE_REVIVE_BIN="$WORK/revive-rc" SUPERVISE_REVIVE_BACKOFF=0 "$PROBE" >/dev/null; wait_for 10 test "$(ncalls)" = 2
[[ "$n_in" == 1 && "$(ncalls)" == 2 && "$LAST_OUT" == *"backing off"* ]] \
    && ok "P10 a failed restart (revive exit 1): 1 run per backoff window, retried after it" \
    || bad "P10 in-window=$n_in after=$(ncalls) out=$LAST_OUT"
rm -f "$S/watcher-supervisor-revive.last" "$S/watcher-supervisor-revive.latched"

echo "=== A: arm-watcher-supervisor.sh against a stub longjob-watch ==="
# The stub records argv, and answers from files: $WORK/lj.show (spec JSON, or
# absent → rc 2), $WORK/lj.verdict (the dispatcher= word), $WORK/lj.addrc.
cat > "$WORK/lj" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LJ_ARGV"
case "$1" in
  show) [[ -f "$LJ_W/lj.show" ]] && { cat "$LJ_W/lj.show"; exit 0; }; echo "no such watch" >&2; exit 2 ;;
  status) printf 'dispatcher=%s  stub\n' "$(cat "$LJ_W/lj.verdict")"; exit 0 ;;
  rm) rm -f "$LJ_W/lj.show"; echo removed; exit 0 ;;
  add) rc=$(cat "$LJ_W/lj.addrc")
       case "$rc" in 0) echo "dispatcher: ARMED — stub";; 3) cat "$LJ_W/lj.addmsg";; esac
       exit "$rc" ;;
esac
EOF
chmod +x "$WORK/lj"
export ARM_SUPERVISOR_LONGJOB_BIN="$WORK/lj" LJ_W="$WORK" LJ_ARGV="$WORK/lj.argv"
arm_reset() { rm -f "$WORK/lj.show" "$LJ_ARGV"; echo armed > "$WORK/lj.verdict"; echo 0 > "$WORK/lj.addrc"; echo "dispatcher: NOT ARMED (dead) — stub" > "$WORK/lj.addmsg"; }

arm_reset
out=$("$ARM"); rc=$?
addline=$(grep '^add ' "$LJ_ARGV")
(( rc == 0 )) && [[ "$out" == *ARMED* ]] && ok "A1 absent → added, exit 0" || bad "A1 rc=$rc out=$out"
shape_ok=1
for f in "cmd:$REPO_ROOT/monitor/watcher-supervise-probe.sh" "--id watcher-supervisor" --persistent "--ttl 0" \
         "--max-events 100000" "--unknown-max 100000" --no-declare "--interval 30"; do
    [[ "$addline" == *"$f"* ]] || { shape_ok=0; bad "A1 add argv lacks '$f': $addline"; }
done
(( shape_ok )) && ok "A1 the watch shape: persistent, no TTL, uncapped, undeclared, 30 s"

arm_reset; echo '{"retired": false}' > "$WORK/lj.show"
out=$("$ARM"); rc=$?
(( rc == 0 )) && ! grep -q '^add ' "$LJ_ARGV" && [[ "$out" == *"already ARMED"* ]] \
    && ok "A2 live watch + armed dispatcher → no-op, exit 0" || bad "A2 rc=$rc out=$out argv=$(cat "$LJ_ARGV")"

arm_reset; echo '{"retired": true}' > "$WORK/lj.show"
out=$("$ARM"); rc=$?
(( rc == 0 )) && grep -q '^rm watcher-supervisor' "$LJ_ARGV" && grep -q '^add ' "$LJ_ARGV" \
    && ok "A3 retired watch → removed and re-added" || bad "A3 rc=$rc argv=$(cat "$LJ_ARGV")"

arm_reset; echo 3 > "$WORK/lj.addrc"
out=$("$ARM"); rc=$?
(( rc == 3 )) && [[ "$out" == *FALLBACK* && "$out" == *"watcher-supervise-tick.sh"* ]] && grep -q '^rm watcher-supervisor' "$LJ_ARGV" \
    && ok "A4 NOT ARMED → exit 3, the Monitor-lease fallback printed, the dead watch removed" || bad "A4 rc=$rc out=$out"

arm_reset; echo '{"retired": false}' > "$WORK/lj.show"; echo dead > "$WORK/lj.verdict"
out=$("$ARM"); rc=$?
(( rc == 3 )) && [[ "$out" == *FALLBACK* ]] && ok "A5 live watch but dispatcher dead → exit 3 + fallback" || bad "A5 rc=$rc out=$out"

arm_reset; echo 3 > "$WORK/lj.addrc"; echo "dispatcher: MUTED — stub" > "$WORK/lj.addmsg"
out=$("$ARM"); rc=$?
(( rc == 0 )) && [[ "$out" == *MUTED* ]] && ! grep -q '^rm ' "$LJ_ARGV" \
    && ok "A6 MUTED dispatcher → kept (it still probes), exit 0" || bad "A6 rc=$rc out=$out"
unset ARM_SUPERVISOR_LONGJOB_BIN

echo "=== E: end to end on the real dispatcher ==="
export MONITOR_LONGJOB_POLL_SECONDS=5 MONITOR_LONGJOB_EMIT_MIN_GAP_MS=100
rm -f "$WSP_DOWN" "$WSP_CALLS" "$REVLOG"
# e2e <key> <cycles> [extra add args] — one dispatcher, the watch armed by the
# helper (E1) or added with the default cap (E0), then <cycles> outages.
start_dispatcher() {
    NEXUS_LONGJOB_KEY="$1" "$LJ" dispatch > "$WORK/out-$1.txt" 2> "$WORK/err-$1.txt" &
    DPIDS+=("$!"); disown "$!" 2>/dev/null
    wait_for 20 test -f "$NEXUS_STATE_DIR/longjob/$1/dispatcher.json"
}
outage() {   # one kill → revival → back up
    touch "$WSP_DOWN"
    wait_for 40 test ! -e "$WSP_DOWN" || return 1
    return 0
}
spec_retired() { jq -r '.retired // false' "$NEXUS_STATE_DIR/longjob/$1/watches/watcher-supervisor.json" 2>/dev/null; }

# E0 potency control: an ordinary persistent watch with the DEFAULT per-watch
# cap (8) retires once its outages have produced 8 events — so E1's "still
# live after 10 events" is a statement about the helper's flags, not the rig.
start_dispatcher e0
NEXUS_LONGJOB_KEY=e0 "$LJ" add "cmd:$PROBE" --id watcher-supervisor --persistent --interval 5 --ttl 0 --no-declare >/dev/null
for i in 1 2 3 4 5; do outage || bad "E0 outage $i: not revived"; wait_for 20 grep -q "transition failed → running" "$WORK/out-e0.txt"; sleep 6; done
[[ "$(spec_retired e0)" == true ]] && ok "E0 control: the default cap RETIRES an ordinary persistent watch after 5 outages" \
    || bad "E0 control did not retire (retired=$(spec_retired e0)) — E1 would prove nothing"
kill "${DPIDS[-1]}" 2>/dev/null
rm -f "$WSP_DOWN" "$WSP_CALLS"

start_dispatcher e1
out=$(NEXUS_LONGJOB_KEY=e1 ARM_SUPERVISOR_INTERVAL=5 "$ARM"); rc=$?
(( rc == 0 )) && ok "E1 armed on a live dispatcher (rc 0)" || bad "E1 arm rc=$rc out=$out"
revived=0
for i in 1 2 3 4 5; do outage && revived=$(( revived + 1 )); sleep 6; done
(( revived == 5 )) && [[ "$(ncalls)" -ge 5 ]] && ok "E1 five outages, five revivals, no turn taken" || bad "E1 revived=$revived calls=$(ncalls)"
wait_for 20 test "$(grep -c 'failed → running' "$WORK/out-e1.txt")" -ge 5
nf=$(grep -cE 'persistent: (pending|running) → failed' "$WORK/out-e1.txt"); nr=$(grep -c 'failed → running' "$WORK/out-e1.txt")
(( nf >= 5 && nr >= 5 )) && ok "E1 every outage woke the session twice (down, then up): $nf + $nr lines" || bad "E1 lines: failed=$nf running=$nr"
[[ "$(spec_retired e1)" == false ]] && ok "E1 the watch is still LIVE after $(( nf + nr )) events (> default cap 8)" || bad "E1 watch retired=$(spec_retired e1)"
[[ -f "$NEXUS_STATE_DIR/longjob/e1/dispatcher.json" ]] && kill -0 "${DPIDS[-1]}" 2>/dev/null && ok "E1 dispatcher still alive" || bad "E1 dispatcher gone"

# E2. ONE WAKE PER LATCH ENTRY, on the real dispatcher (ncbundle4sk B2): a
#     crash-loop refusal must reach the orchestrator exactly once — the
#     failed→done transition — and stay silent while latched.
kill "${DPIDS[-1]}" 2>/dev/null
rm -f "$WSP_DOWN" "$WSP_CALLS" "$REVLOG" "$S/watcher-supervisor-revive.last" "$S/watcher-supervisor-revive.latched"
# The dispatcher runs the probe with ITS environment, so the revive stub and
# its exit code are exported before it starts.
export SUPERVISE_REVIVE_BIN="$WORK/revive-rc" WSP_REVIVE_RC=3
start_dispatcher e2
out=$(NEXUS_LONGJOB_KEY=e2 ARM_SUPERVISOR_INTERVAL=5 "$ARM"); rc=$?
(( rc == 0 )) || bad "E2 arm rc=$rc out=$out"
touch "$WSP_DOWN"
# Six poll intervals: the revive, the latch entry, then four latched polls.
wait_for 60 grep -q 'ORCHESTRATOR MUST ACT' "$WORK/out-e2.txt"
sleep 25
n_wake=$(grep -c 'ORCHESTRATOR MUST ACT' "$WORK/out-e2.txt" 2>/dev/null); [[ "$n_wake" =~ ^[0-9]+$ ]] || n_wake=0
[[ "$n_wake" == 1 && "$(ncalls)" == 1 ]] \
    && ok "E2 a crash-loop latch produces EXACTLY ONE wake (failed→done) and one revive over ~6 polls" \
    || bad "E2 wakes=$n_wake revives=$(ncalls) (want 1/1): $(tail -3 "$WORK/out-e2.txt")"
[[ "$(spec_retired e2)" == false ]] \
    && ok "E2 …and the persistent watch is NOT retired by answering done" \
    || bad "E2 watch retired=$(spec_retired e2)"
# The wake is composed HEAD-FIRST: the alert leads the line, so a DONE state
# word cannot be read as success (ncbundle4sk on #1635: it sat ~250 chars in).
wake=$(grep -m1 'ORCHESTRATOR MUST ACT' "$WORK/out-e2.txt")
pre="${wake%%ORCHESTRATOR MUST ACT*}"
[[ "$wake" == "longjob-watch: LATCHED — ORCHESTRATOR MUST ACT"* && ${#pre} -lt 80 ]] \
    && ok "E2 …the wake line LEADS with 'LATCHED — ORCHESTRATOR MUST ACT' (at char ${#pre})" \
    || bad "E2 wake not head-first (alert at char ${#pre}): ${wake:0:160}"
# A real recovery after the latch is ANNOUNCED once: latched (done) → UP emits
# exactly one RUNNING line, and nothing more while it stays up.
n_run0=$(grep -c 'RUNNING watcher-supervisor' "$WORK/out-e2.txt" 2>/dev/null); [[ "$n_run0" =~ ^[0-9]+$ ]] || n_run0=0
rm -f "$WSP_DOWN"
wait_for 40 grep -q 'RUNNING watcher-supervisor' "$WORK/out-e2.txt"
sleep 15
n_run=$(grep -c 'RUNNING watcher-supervisor' "$WORK/out-e2.txt" 2>/dev/null); [[ "$n_run" =~ ^[0-9]+$ ]] || n_run=0
[[ "$n_run0" == 0 && "$n_run" == 1 && ! -e "$S/watcher-supervisor-revive.latched" ]] \
    && ok "E2 …a real recovery after the latch emits EXACTLY ONE running line, and the latch clears" \
    || bad "E2 recovery lines before=$n_run0 after=$n_run latch=$([[ -e $S/watcher-supervisor-revive.latched ]] && echo present || echo gone)"

# --- assertion-count guard ------------------------------------------------
# A verdict is not a count: pin the total so a silently skipped arm is red.
# P 15 + A 7 + E 10 + this one = 33.
EXPECTED_ASSERTIONS=33
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} + 1 ))
if (( TOTAL_ASSERTIONS == EXPECTED_ASSERTIONS )); then
    ok "assertion total is exactly $EXPECTED_ASSERTIONS — no arm was silently skipped"
else
    bad "assertion total $TOTAL_ASSERTIONS != expected $EXPECTED_ASSERTIONS — an arm ran short or was skipped"
fi

th_summary_and_exit
