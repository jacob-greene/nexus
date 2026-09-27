#!/usr/bin/env bash
# Hermetic unit tests for the silent-watcher hardening (nexus-code#236).
#
# Covers the four failure modes that let a heartbeating watcher go silently
# undetected on 2026-06-18, and the operator's reports/worktree confounder:
#
#   1. BOUNDED, NOISE-FREE snapshot — snapshot_local stays O(1)-ish under a
#      simulated 200-worktree / 2000-report load (git off by default), and a
#      report rewrite (mtime churn) does NOT change the change-detection
#      snapshot, while a NEW final report DOES (signal preserved). A budgeted
#      git scan that overruns degrades to a stable sentinel, never a stall.
#   2. LOUD + recovered paste delivery — _emit_delivery_fail tracks
#      consecutive failures, ignores rc=2 (target-missing = orchestrator path),
#      escalates LOUDLY, and self-heals past the limit. _emit_delivery_ok
#      resets.
#   3. EMIT-FUNCTIONAL liveness — _watcher_emit_functional flags a
#      heartbeat-fresh-but-emit-cycle-stale watcher as DEAD, and the real
#      watcher-supervise-tick.sh exits non-zero for it (end-to-end).
#   4. STORM-PROOF recovery — _watcher_self_heal_restart honours the master
#      switch, the restart cooldown, and the loop guard (never storms), and
#      the functional_check handler only self-heals on the WATCHER-FAULT
#      (delivery-stale) case, never the orchestrator-fault one.
#   5. RECOVERY FROM A LOGOUT pastes within one cycle (your-org/nexus-code#1567
#      G2): the auth-expired clear transition pulls compose_emit forward, and
#      forces a full-state emit only when the latest paste's turn FAILED.
#
# Hand-rolled harness (matches test-lib.sh): mock externals as bash
# functions, extract the main.sh functions under test by name, stub the
# version-restart guards so each branch is exercised deterministically.
#
# Run: bash monitor/watcher/test-watcher-robustness.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"
LIB_SH="$_test_dir/_lib.sh"
SUPERVISE_TICK="$_test_dir/../watcher-supervise-tick.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq()       { local v="${2:0:60}"; [[ "$2" == "$3" ]] && pass "$1 (=${v})" || fail "$1: got '${2:0:200}' want '${3:0:200}'"; }
assert_ne()       { [[ "$2" != "$3" ]] && pass "$1" || fail "$1: '$2' should differ from '$3'"; }
assert_contains() { [[ -n "$3" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2; [[ -n "$3" && "$2" == *"$3"* ]] && pass "$1" || fail "$1: '$2' missing '$3'"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1: '$2' should NOT contain '$3'"; }
assert_rc()       { assert_eq "$1" "$2" "$3"; }

# Extract a top-level shell function from a file by name (no `^}` may appear
# mid-body — verified for all functions under test).
_extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }

# ---------------------------------------------------------------------------
echo '=== mode #1: bounded, noise-free snapshot_local ==='

# Mock tmux: a fixed window list (the genuine local-state signal).
tmux() {
    case "$1 $2" in
        "list-windows -F")
            printf 'orchestrator bell=0\nworker-a bell=0\nworker-b bell=1\n' ;;
        *) return 0 ;;
    esac
}
export -f tmux 2>/dev/null || true

eval "$(_extract_fn "$MAIN_SH" snapshot_local)"
SNAPSHOT_LOCAL_FORMAT_TAG='# snapshot-format=v2 test'

ROOT=$(mktemp -d)
mkdir -p "$ROOT/reports" "$ROOT/work"
# 2000 reports (1900 final + 100 interim) + 200 git worktrees.
for i in $(seq 1 1900); do : > "$ROOT/reports/proj_2026-01-01_00-00-${i}_final.md"; done
for i in $(seq 1 100);  do : > "$ROOT/reports/proj_2026-01-01_00-00-${i}-interim.md"; done
for i in $(seq 1 200);  do mkdir -p "$ROOT/work/wt$i/.git"; done

export NEXUS_ROOT="$ROOT"
# Leave MONITOR_SNAPSHOT_GIT_ENABLED UNSET so the snapshot exercises the
# real `:-false` default (proves git is off WITHOUT an explicit override).
unset MONITOR_SNAPSHOT_GIT_ENABLED

_t0=$(date +%s)
snap=$(snapshot_local)
_t1=$(date +%s)
elapsed=$(( _t1 - _t0 ))

assert_contains "snapshot has format tag"        "$snap" "snapshot-format=v2"
assert_contains "snapshot has tmux section"      "$snap" "--- tmux ---"
assert_contains "snapshot has reports section"   "$snap" "--- reports ---"
assert_not_contains "git section OFF by default" "$snap" "--- git ---"
# No mtimes: reports lines are bare basenames, never '<name>.md <float>'.
if grep -qE '\.md [0-9]+\.[0-9]+$' <<<"$snap"; then
    fail "reports section must NOT embed mtimes"
else
    pass "reports section carries no mtimes (churn-proof)"
fi
assert_not_contains "interim reports excluded"   "$snap" "interim"
# Boundedness: 200 worktrees + 2000 reports must not take long with git off.
# Bound raised 10 s → 60 s (the your-org/nexus-code#557 class review).
# This is a genuine COMPLEXITY assertion: with git off, snapshot_local must
# not walk 200 worktrees x 2000 reports. A regression there is not "a bit
# slower", it is minutes-to-unbounded, so 60 s separates the two outcomes
# just as cleanly as 10 s did — while no longer doubling as a wall-clock
# bet on how much CPU this test happens to get.
if (( elapsed <= 60 )); then pass "snapshot bounded under load (${elapsed}s <= 60s)"; \
    else fail "snapshot too slow under load: ${elapsed}s"; fi
# Reports section is a BOUNDED, deterministic summary, NOT a full dump:
#   * an exact total count of the 1900 FINAL reports (interim excluded), and
#   * at most N recent basenames (default 20) — never the 1900-line list
#     that flapped a giant per-poll diff at this corpus size (reportscan).
assert_contains "reports total count emitted" "$snap" "reports-total: 1900"
nlisted=$(printf '%s\n' "$snap" | grep -c '_final\.md$')
if (( nlisted >= 1 && nlisted <= 20 )); then \
    pass "reports listing bounded (${nlisted} basenames in [1,20], not the full 1900)"; \
    else fail "reports listing NOT bounded: ${nlisted} basenames emitted"; fi
# Stability: same file set -> byte-identical reports section across composes
# (deterministic LC_ALL=C sort + count). No flap == no spurious diff/emit.
snap2=$(snapshot_local)
assert_eq "snapshot deterministic across repeated composes (no flap)" "$snap" "$snap2"

echo '=== mode #1: confounder — report rewrite does NOT churn the snapshot ==='
base=$(snapshot_local)
sleep 1
# Rewrite an existing final report (mtime advances). Old behaviour embedded
# %T@, so this changed the snapshot -> a churn-only emit. New behaviour: no.
: > "$ROOT/reports/proj_2026-01-01_00-00-1_final.md"
after_rewrite=$(snapshot_local)
assert_eq "report rewrite leaves snapshot IDENTICAL (no churn emit)" \
    "$after_rewrite" "$base"
# A genuinely NEW final report IS a state transition -> snapshot changes.
: > "$ROOT/reports/proj_2026-01-01_00-00-NEW_final.md"
after_add=$(snapshot_local)
assert_ne "NEW final report DOES change snapshot (signal preserved)" \
    "$after_add" "$base"

echo '=== mode #1: git scan budget — overrun degrades to sentinel, no stall ==='
GITBIN=$(mktemp -d)
cat > "$GITBIN/git" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$GITBIN/git"
_t0=$(date +%s)
snap_g=$(PATH="$GITBIN:$PATH" MONITOR_SNAPSHOT_GIT_ENABLED=true \
    MONITOR_SNAPSHOT_GIT_TIMEOUT_SECONDS=1 snapshot_local 2>/dev/null)
_t1=$(date +%s); gelapsed=$(( _t1 - _t0 ))
assert_contains "git overrun emits stable sentinel" "$snap_g" "git listing unavailable"
if (( gelapsed <= 5 )); then pass "git scan bounded by budget (${gelapsed}s, loop NOT blocked)"; \
    else fail "git scan not bounded: ${gelapsed}s"; fi
rm -rf "$GITBIN" "$ROOT"
unset -f tmux

# ---------------------------------------------------------------------------
echo '=== mode #2: loud + recovered emit delivery ==='

STATE=$(mktemp -d)
export STATE_DIR="$STATE"
export TARGET="orchestrator"
export EMIT_LAST_DELIVERY_FILE="$STATE/watcher-last-emit-delivery.ts"
export EMIT_DELIVERY_FAIL_FILE="$STATE/watcher-emit-delivery-fail.count"
export MONITOR_EMIT_DELIVERY_FAIL_LIMIT=3

# Stubs: capture log + alert + self-heal invocations; no real restart.
LOGCAP="$STATE/log.txt"; : > "$LOGCAP"
log() { printf '%s\n' "$*" >> "$LOGCAP"; }
SELFHEAL_CALLS="$STATE/selfheal.txt"; : > "$SELFHEAL_CALLS"
_watcher_self_heal_restart() { printf '%s\n' "$1" >> "$SELFHEAL_CALLS"; }

eval "$(_extract_fn "$MAIN_SH" _watcher_alert)"
eval "$(_extract_fn "$MAIN_SH" _emit_delivery_ok)"
eval "$(_extract_fn "$MAIN_SH" _emit_delivery_fail)"

# rc=2 (target missing) is the orchestrator-respawn path — never a delivery fault.
_emit_delivery_fail 2
assert_no_count() { [[ ! -f "$EMIT_DELIVERY_FAIL_FILE" ]] && pass "$1" || fail "$1 (counter=$(cat "$EMIT_DELIVERY_FAIL_FILE"))"; }
assert_no_count "rc=2 does NOT count toward delivery failure"
assert_eq "rc=2 triggers no self-heal" "$(wc -l < "$SELFHEAL_CALLS")" "0"

# rc=3 failures: increment, alert loudly, self-heal AT the limit (not before).
_emit_delivery_fail 3
assert_eq "1st rc=3 failure counted"  "$(cat "$EMIT_DELIVERY_FAIL_FILE")" "1"
assert_eq "no self-heal before limit" "$(wc -l < "$SELFHEAL_CALLS")" "0"
_emit_delivery_fail 3
_emit_delivery_fail 3
assert_eq "3rd consecutive failure hits limit" "$(cat "$EMIT_DELIVERY_FAIL_FILE")" "3"
assert_eq "self-heal fired exactly once at limit" "$(wc -l < "$SELFHEAL_CALLS")" "1"
assert_contains "delivery failure alerted LOUDLY" "$(cat "$LOGCAP")" "ALERT"
assert_contains "alert names UNDELIVERED" "$(cat "$LOGCAP")" "UNDELIVERED"
# A success resets the counter and stamps the delivery clock.
OPA_CALLS="$STATE/opalert.txt"; : > "$OPA_CALLS"
_operator_alert() { printf '%s\n' "$*" >> "$OPA_CALLS"; return 0; }
_emit_delivery_ok
assert_no_count "success clears the failure counter"
[[ -f "$EMIT_LAST_DELIVERY_FILE" ]] && pass "success stamps delivery clock" || fail "delivery clock not stamped"
# #1572: a delivery is the "absent" signal for the loop-guard operator alert.
assert_contains "success CLEARS the loop-guard operator alert (#1572)" "$(cat "$OPA_CALLS")" "clear watcher-self-heal-loop-guard"

# #1572 — a LOGGED-OUT orchestrator is not a watcher fault. 3,004 consecutive
# rc=4 during a logout drove the watcher's own self-heal into its loop guard.
# Each of the two existing logout signals, alone, exempts the failure. The
# pane arm is stubbed here; the typed-marker arm is tested against the REAL
# module below (a constant stub of it is what hid #1626 F2).
: > "$SELFHEAL_CALLS"; : > "$LOGCAP"; rm -f "$EMIT_DELIVERY_FAIL_FILE"
_auth_hold_expiry_standing() { return "$EXPIRY_STANDING"; }
EXPIRY_STANDING=0
for _i in 1 2 3 4; do _emit_delivery_fail 4; done
assert_no_count "logout (pane expiry row) rc=4 x4 is NOT counted (#1572)"
assert_eq "logout (pane expiry row): no self-heal (#1572)" "$(wc -l < "$SELFHEAL_CALLS")" "0"
assert_contains "logout exemption is logged as an ORCHESTRATOR fact" "$(cat "$LOGCAP")" "NOT counted toward self-heal"
# CONTROL: with neither signal, the very same rc=4 streak is counted and heals.
EXPIRY_STANDING=1; : > "$SELFHEAL_CALLS"; rm -f "$EMIT_DELIVERY_FAIL_FILE"
for _i in 1 2 3; do _emit_delivery_fail 4; done
assert_eq "control: no logout signal => rc=4 x3 IS counted" "$(cat "$EMIT_DELIVERY_FAIL_FILE")" "3"
assert_eq "control: no logout signal => self-heal fires at the limit" "$(wc -l < "$SELFHEAL_CALLS")" "1"

# #1572 typed-marker arm, against the REAL module (skeptic verdict on
# your-org/nexus-code#1626, finding 2). The rows above stub the predicate to a
# constant, which is why they could not see that the raw sensor has no
# ceiling: it stays CURRENT while `ts >= last_paste_ts`, and a failing
# delivery never moves last_paste_ts. So here `_auth_hold.sh` is SOURCED and
# the marker is a real file; only the pane arm stays stubbed (to "not
# standing"), so the typed arm is the one under test.
# shellcheck source=/dev/null
source "$_test_dir/_auth_hold.sh"
_auth_hold_expiry_standing() { return 1; }
unset MONITOR_AUTH_HOLD_MAX_HOLD_SECONDS MONITOR_ORCH_TURN_FAILURE_GATE_SECONDS MONITOR_AUTH_HOLD_ENABLED
export ORCH_LAST_PASTE_FILE="$STATE/orchestrator-last-paste.ts"
_rb_now=$(date +%s)
plant_marker() {   # <age_s> — last paste 800 s BEFORE the marker, so it reads current via ts >= last_paste
    mkdir -p "$STATE/turn-failure"
    printf '{"ts":%s,"error":"authentication_failed","category":"auth","recovery":"operator","last_msg":"Login expired","window":"%s","hook_event_name":"StopFailure"}\n' \
        "$(( _rb_now - $1 ))" "$TARGET" > "$STATE/turn-failure/$TARGET.json"
    printf '%s\n' "$(( _rb_now - $1 - 800 ))" > "$ORCH_LAST_PASTE_FILE"
}
reset_counting() { : > "$SELFHEAL_CALLS"; : > "$LOGCAP"; rm -f "$EMIT_DELIVERY_FAIL_FILE"; }
# (i) FRESH marker (60 s): exempt — the #1572 behaviour is kept.
reset_counting; plant_marker 60
for _i in 1 2 3 4; do _emit_delivery_fail 3; done
assert_no_count "real module: FRESH auth marker (60s) => rc=3 x4 NOT counted (#1572)"
assert_eq "real module: FRESH auth marker => no self-heal" "$(wc -l < "$SELFHEAL_CALLS")" "0"
# (ii) marker current ONLY via ts >= last_paste, but under the ceiling (7000 s):
# still exempt. Pins that the cap is max_hold, not the 600 s freshness window.
reset_counting; plant_marker 7000
_auth_hold_turn_failure_marker "$TARGET" >/dev/null && pass "precondition: 7000s marker reads CURRENT to the raw sensor" \
    || fail "precondition: 7000s marker should read current (ts >= last paste)"
for _i in 1 2 3; do _emit_delivery_fail 3; done
assert_no_count "real module: marker 7000s old (< max_hold 7200) => still NOT counted"
# (iii) STALE marker (72 h), still current to the raw sensor: the exemption
# FAILS OPEN and counting, ALERT and self-heal resume — the skeptic's repro.
reset_counting; plant_marker $(( 72 * 3600 ))
_auth_hold_turn_failure_marker "$TARGET" >/dev/null && pass "precondition: 72h marker reads CURRENT to the raw sensor (the uncapped hazard)" \
    || fail "precondition: 72h marker should read current to the raw sensor"
for _i in 1 2 3 4 5; do _emit_delivery_fail 3; done
assert_eq "real module: STALE auth marker (72h) => rc=3 x5 IS counted (skeptic #1626 F2)" "$(cat "$EMIT_DELIVERY_FAIL_FILE" 2>/dev/null)" "5"
assert_eq "real module: STALE auth marker => ALERT on every failure" "$(command grep -c 'ALERT' "$LOGCAP")" "5"
assert_eq "real module: STALE auth marker => self-heal fires (limit 3: calls 3,4,5)" "$(wc -l < "$SELFHEAL_CALLS")" "3"
assert_contains "real module: the fail-open is LOGGED, naming max_hold" "$(cat "$LOGCAP")" "older than max_hold=7200s"
# (iv) the ceiling is the MODULE's knob, not a copy: lowering it re-classifies (ii).
reset_counting; plant_marker 7000
MONITOR_AUTH_HOLD_MAX_HOLD_SECONDS=3600 _emit_delivery_fail 3
assert_eq "real module: max_hold knob=3600 => the 7000s marker IS counted" "$(cat "$EMIT_DELIVERY_FAIL_FILE" 2>/dev/null)" "1"
# (v) NO marker: counts (control for the whole block).
reset_counting; rm -f "$STATE/turn-failure/$TARGET.json"
for _i in 1 2 3; do _emit_delivery_fail 3; done
assert_eq "real module: NO marker => rc=3 x3 IS counted" "$(cat "$EMIT_DELIVERY_FAIL_FILE" 2>/dev/null)" "3"
assert_eq "real module: NO marker => self-heal at the limit" "$(wc -l < "$SELFHEAL_CALLS")" "1"
unset ORCH_LAST_PASTE_FILE
rm -rf "$STATE"
unset -f log _watcher_self_heal_restart _watcher_alert _emit_delivery_ok _emit_delivery_fail \
    _operator_alert _auth_hold_expiry_standing _auth_hold_turn_failure_marker plant_marker reset_counting

# ---------------------------------------------------------------------------
echo '=== mode #3: HEARTBEAT is the proof-of-working-loop ==='
# Operator refinement (#317): the heartbeat is bumped ONLY at the end of a
# correct compose cycle — it doubles as the functional-liveness signal, and a
# deliberately-silent quiet workspace stays fresh (no emit-to-prove-liveness
# pressure). Verify the SHAPE of the implementation + the end-to-end behaviour.

# (a) No separate always-ticks heartbeat task (that's what masked the wedge).
if grep -qE '^_schedule_task[[:space:]]+heartbeat[[:space:]]' "$MAIN_SH"; then
    fail "a separate heartbeat task still exists (must be removed)"
else
    pass "no separate always-ticks heartbeat task"
fi
# (b) No leftover emit-functional machinery (folded into the heartbeat).
grep -q '_watcher_emit_functional' "$LIB_SH" \
    && fail "_watcher_emit_functional should be gone from _lib.sh" \
    || pass "_watcher_emit_functional removed (heartbeat IS the signal)"
grep -q 'watcher-last-emit-cycle' "$MAIN_SH" \
    && fail "stale watcher-last-emit-cycle reference remains" \
    || pass "no separate emit-cycle timestamp file"
# (c) compose_emit bumps the heartbeat at its cycle tail — AFTER the
#     emit-decision gate — so a QUIET (found-nothing) cycle, which falls
#     through that gate, still proves the loop works.
# STRUCTURAL, and it says so — a source-text check may SUPPLEMENT a
# behavioural one, never replace it (your-org/nexus-code#1016). What it can
# pin is CONTAINMENT: is the bump inside the gated block, or after it. What no
# text assertion here can pin is that the bump EXECUTES on a quiet cycle; that
# needs a driveable seam, and `_v2_task_compose_emit` does not have one.
#
# The old form compared `tail -1`'s line number against the GATE'S OPENING
# LINE. Measured on main.sh: the gate opens at 4390 and its block closes at
# 4575, inside a function spanning 4137-4593 — so a bump moved INSIDE the gated
# block still satisfied `bump > gate` while proving the exact opposite of the
# claim, since a quiet cycle falls THROUGH that gate and would never reach it.
# Anchoring on the block's CLOSING `fi` (matched by indentation) is what makes
# the assertion mean what its label says.
compose_body=$(_extract_fn "$MAIN_SH" _v2_task_compose_emit)
gate_ln=$(printf '%s\n' "$compose_body" | grep -nE 'local_diff.*\|\|.*gh_now' | head -1 | cut -d: -f1)
# the `fi` closing that gate: first one at the gate's own indentation
gate_end_ln=$(printf '%s\n' "$compose_body" | awk -v g="${gate_ln:-0}" '
    NR == g { match($0, /^[[:space:]]*/); ind = RLENGTH; next }
    NR >  g && ind != "" && $0 ~ /^[[:space:]]*fi[[:space:]]*$/ {
        match($0, /^[[:space:]]*/); if (RLENGTH == ind) { print NR; exit }
    }')
tail_bump_ln=$(printf '%s\n' "$compose_body" | grep -n 'bump_heartbeat' | tail -1 | cut -d: -f1)
# `^[0-9]+$`, not `[[ -n ]]`: an empty capture cannot arithmetic-evaluate, and
# `(( "" > "" ))` is a silent pass. This is the form test-watcher-supervise.sh
# uses and the reason it is the positive control for this shape.
if [[ "$gate_ln" =~ ^[0-9]+$ && "$gate_end_ln" =~ ^[0-9]+$ && "$tail_bump_ln" =~ ^[0-9]+$ ]] \
   && (( tail_bump_ln > gate_end_ln )); then
    pass "compose_emit bumps heartbeat AFTER the gate's closing fi (a quiet cycle reaches it)"
else
    fail "compose_emit must bump_heartbeat outside the emit-decision gate (gate=$gate_ln end=$gate_end_ln bump=$tail_bump_ln)"
fi
# (d) The inline full-state / prelude renders inside compose_emit are
#     wall-clock bounded (skeptic #2c) — they probe O(workers) panes and run in
#     the heartbeat-bumping cycle, so an unbounded slow render could stale the
#     heartbeat and trip a false supervisor restart.
if grep -q '_run_bounded[^>]*render_full_state_snapshot' <<<"$compose_body" \
   && grep -q '_run_bounded[^>]*render_idle_prelude' <<<"$compose_body"; then
    pass "compose_emit inline renders are wall-clock bounded (can't stale the heartbeat)"
else
    fail "compose_emit inline render_full_state_snapshot/render_idle_prelude must be _run_bounded"
fi

echo '=== mode #3: DEAD-cutoff margin (skeptic #2 — no false restart on transient) ==='
SUPSD=$(mktemp -d)
# A real "live watcher" process whose argv0 ends in monitor/watcher/main.sh
# so _watcher_pid_is_live_watcher accepts it.
bash -c 'exec -a "/x/monitor/watcher/main.sh" sleep 90' &
FAKE_WATCHER=$!
sleep 0.3
write_hb() { printf 'pid=%d\nts=%s\ntarget=orchestrator\n' "$FAKE_WATCHER" "$1" > "$SUPSD/watcher-heartbeat"; }
run_tick() { NEXUS_STATE_DIR="$SUPSD" MONITOR_INTERVAL=60 bash "$SUPERVISE_TICK" 2>"$SUPSD/tick.err"; }

# (unit) _watcher_alive's DEAD-cutoff override: a heartbeat aged 350s — INSIDE
# the async-watchdog window (5×interval=300s < 350 < DEAD_CUTOFF≈420s) — must
# read stale-but-alive (rc 1) WITH the override, but DOWN (rc 2) at the default
# 300s cutoff. This is the zero-margin bug the skeptic caught, fixed.
. "$LIB_SH"
write_hb "x"; touch -d '350 seconds ago' "$SUPSD/watcher-heartbeat" 2>/dev/null || true
_watcher_alive "$SUPSD" 60;      assert_rc "350s @ default cutoff(300) => DOWN(2)" "$?" "2"
_watcher_alive "$SUPSD" 60 420;  assert_rc "350s @ override cutoff(420) => stale-but-alive(1)" "$?" "1"

# (e2e) Fresh heartbeat (loop completed a cycle recently) => alive. NO emit
# file needed — a quiet workspace that never emits is still ALIVE.
write_hb "$(date -Is)"; touch "$SUPSD/watcher-heartbeat"
run_tick; assert_rc "fresh heartbeat (quiet but working) => alive" "$?" "0"
# (e2e) Heartbeat aged INTO the watchdog margin (350s): the watcher's own
# watchdog heals a single transient stall before the supervisor restarts it.
write_hb "x"; touch -d '350 seconds ago' "$SUPSD/watcher-heartbeat" 2>/dev/null || true
run_tick; assert_rc "heartbeat in watchdog margin (350s) => still alive (no false restart)" "$?" "0"
# (e2e) Persistent wedge past DEAD_CUTOFF => DOWN. The 8-min-silence fix.
write_hb "old"; touch -d '1 hour ago' "$SUPSD/watcher-heartbeat" 2>/dev/null || true
run_tick; rc=$?
assert_rc "persistent wedge (1h) => DOWN" "$rc" "1"
assert_contains "DOWN message names the watcher" "$(cat "$SUPSD/tick.err")" "watcher DOWN"
kill "$FAKE_WATCHER" 2>/dev/null; wait "$FAKE_WATCHER" 2>/dev/null
rm -rf "$SUPSD"

# ---------------------------------------------------------------------------
echo '=== mode #4: storm-proof self-heal chokepoint ==='
HS=$(mktemp -d)
export STATE_DIR="$HS"
export VERSION_STATE_DIR="$HS/version"; mkdir -p "$VERSION_STATE_DIR"
export TARGET="orchestrator"
export LOGFILE="$HS/watcher.log"
export WATCHER_REVIVED_MARKER="$HS/watcher-revived"
_script_dir="$_test_dir"
export MONITOR_VERSION_RESTART_COOLDOWN_SECONDS=600

HSLOG="$HS/log.txt"; : > "$HSLOG"
log() { printf '%s\n' "$*" >> "$HSLOG"; }
command() { builtin command "$@"; }   # keep `command -v sandbox-notify` real (absent)
# Stub the version-restart guards so we drive each branch deterministically.
COOLDOWN_OK=0 GUARD_OK=0
_version_cooldown_ok() { return "$COOLDOWN_OK"; }
_version_self_guard_ok() { return "$GUARD_OK"; }
RESTART_CALLS="$HS/restart.txt"; : > "$RESTART_CALLS"
_version_restart_self() { printf 'restart %s\n' "$3" >> "$RESTART_CALLS"; return 0; }

eval "$(_extract_fn "$MAIN_SH" _watcher_alert)"
eval "$(_extract_fn "$MAIN_SH" _watcher_self_heal_restart)"
# #1572: the operator-alert primitive, recorded. `due` answers yes, as the
# primitive does outside its reminder window.
HSOPA="$HS/opalert.txt"; : > "$HSOPA"
_operator_alert() { printf '%s\n' "$*" >> "$HSOPA"; return 0; }

# (a) enabled + cooldown ok + guard ok => restart fires + revived marker.
COOLDOWN_OK=0; GUARD_OK=0
MONITOR_WATCHER_SELF_HEAL_ENABLED=true MONITOR_VERSION_SELF_RESTART=true \
    _watcher_self_heal_restart "test-fault"
assert_eq "self-heal restart fires when allowed" "$(wc -l < "$RESTART_CALLS")" "1"
[[ -f "$WATCHER_REVIVED_MARKER" ]] && pass "revived marker left for successor" || fail "no revived marker"

# (b) inside cooldown => suppressed (no storm).
: > "$RESTART_CALLS"
COOLDOWN_OK=1; GUARD_OK=0
MONITOR_WATCHER_SELF_HEAL_ENABLED=true MONITOR_VERSION_SELF_RESTART=true \
    _watcher_self_heal_restart "test-fault"
assert_eq "cooldown suppresses restart (no storm)" "$(wc -l < "$RESTART_CALLS")" "0"
assert_contains "cooldown suppression logged" "$(cat "$HSLOG")" "cooldown"
assert_not_contains "control: neither a restart nor a cooldown pages the operator (#1572)" "$(cat "$HSOPA")" "raise"

# (c) loop guard tripped => suppressed.
: > "$RESTART_CALLS"; : > "$HSLOG"
COOLDOWN_OK=0; GUARD_OK=1
MONITOR_WATCHER_SELF_HEAL_ENABLED=true MONITOR_VERSION_SELF_RESTART=true \
    _watcher_self_heal_restart "test-fault"
assert_eq "loop guard suppresses restart" "$(wc -l < "$RESTART_CALLS")" "0"
assert_contains "guard suppression logged" "$(cat "$HSLOG")" "guard"
# #1572: "manual restart required" must REACH the operator, not only the log.
assert_contains "loop-guard trip RAISES a critical operator alert (#1572)" "$(cat "$HSOPA")" "raise watcher-self-heal-loop-guard critical"
assert_contains "…whose text says what to do first (#1572)" "$(cat "$HSOPA")" "RESTART THE WATCHER BY HAND"

# (d) master switch off => suppressed.
: > "$RESTART_CALLS"
COOLDOWN_OK=0; GUARD_OK=0
MONITOR_WATCHER_SELF_HEAL_ENABLED=false MONITOR_VERSION_SELF_RESTART=true \
    _watcher_self_heal_restart "test-fault"
assert_eq "self_heal_enabled=false suppresses restart" "$(wc -l < "$RESTART_CALLS")" "0"
unset -f command _operator_alert
rm -rf "$HS"

echo '=== mode #4: functional_check self-heals only on WATCHER-FAULT (loop-heartbeat re-aim) ==='
# Re-aimed (your-org/nexus-code quiet false-positive): a FIRED "stale"
# verdict only escalates to a watcher self-heal when there is POSITIVE
# evidence of a watcher fault — the loop-proof heartbeat is STALE
# (`_watcher_alive` >= 2) OR emits are generated-but-stuck (delivery-fail
# counter > 0). A merely STALE delivery clock on an otherwise-alive loop is
# a QUIET workspace, NOT a fault, and must NOT revive.
FC=$(mktemp -d)
export STATE_DIR="$FC"
export DIFF_DIR="$FC/diffs"; mkdir -p "$DIFF_DIR"
export REPO="owner/repo"; export BOT_LOGIN="bot"
export FUNCTIONAL_CHECK_STATE_FILE="$FC/fc.tsv"
export EMIT_LAST_DELIVERY_FILE="$FC/watcher-last-emit-delivery.ts"
export EMIT_DELIVERY_FAIL_FILE="$FC/watcher-emit-delivery-fail.count"
export INTERVAL=60
export MONITOR_FUNCTIONAL_SLA_SECONDS=600
export MONITOR_FUNCTIONAL_MAX_EMITS=5

FCLOG="$FC/log.txt"; : > "$FCLOG"
log() { printf '%s\n' "$*" >> "$FCLOG"; }
sandbox-notify() { :; }
# Force the decide step to report a stale verdict (the FIRED precondition).
_functional_check_decide() { echo "stale reason=all-emits-unprocessed-past-SLA n_emits=1 n_processed=0 n_stale=1 sla=600s"; return 0; }
# Shim the loop-liveness primitive — return the rc the scenario sets.
# 0=fresh(alive) 1=aging(alive) 2=DEAD 3=no-heartbeat.
FAKE_ALIVE_RC=0
_watcher_alive() { return "$FAKE_ALIVE_RC"; }
FCHEAL="$FC/heal.txt"; : > "$FCHEAL"
_watcher_self_heal_restart() { printf '%s\n' "$1" >> "$FCHEAL"; }

# The real (pure) classifier lives in _functional_check.sh — source it so
# `_v2_task_functional_check` exercises the REAL re-aimed decision.
# shellcheck source=_functional_check.sh
source "$_test_dir/_functional_check.sh"
# Re-stub decide AFTER sourcing (the source defines the real one).
_functional_check_decide() { echo "stale reason=all-emits-unprocessed-past-SLA n_emits=1 n_processed=0 n_stale=1 sla=600s"; return 0; }
eval "$(_extract_fn "$MAIN_SH" _v2_task_functional_check)"

reset_fc() { : > "$FCHEAL"; : > "$FCLOG"; rm -f "$EMIT_DELIVERY_FAIL_FILE"; FAKE_ALIVE_RC=0; }

# (A) Delivery FRESH, loop alive, no fails => orchestrator-fault => NO restart.
reset_fc
printf '%s\n' "$(date +%s)" > "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "A: fresh delivery (orch-fault) => NO self-heal" "$(wc -l < "$FCHEAL")" "0"
assert_contains "A: logged NOT a watcher fault" "$(cat "$FCLOG")" "NOT a watcher fault"

# (B) Delivery STALE, loop alive (fresh heartbeat), no fails => QUIET => NO
# restart. THIS is the false-positive the re-aim kills (was: self-heal).
reset_fc
printf '%s\n' "$(( $(date +%s) - 9999 ))" > "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "B: stale delivery + alive loop (QUIET) => NO self-heal" "$(wc -l < "$FCHEAL")" "0"
assert_contains "B: logged quiet (not watcher fault)" "$(cat "$FCLOG")" "quiet"

# (C) No delivery clock, loop alive, no fails => QUIET => NO restart
# (a never-emitted quiet workspace must not be read as a wedge).
reset_fc
rm -f "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "C: absent delivery clock + alive loop => NO self-heal" "$(wc -l < "$FCHEAL")" "0"

# (D) REAL WEDGE — loop-proof heartbeat DEAD (rc=2) => watcher-fault => restart,
# regardless of how the delivery clock looks.
reset_fc
FAKE_ALIVE_RC=2
printf '%s\n' "$(( $(date +%s) - 9999 ))" > "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "D: loop heartbeat DEAD (rc=2) => self-heal fires" "$(wc -l < "$FCHEAL")" "1"
assert_contains "D: logged WATCHER-FAULT" "$(cat "$FCLOG")" "WATCHER-FAULT"

# (E) REAL WEDGE — emits generated-but-stuck (delivery-fail counter > 0) =>
# watcher-fault => restart, even with a fresh-looking loop heartbeat.
reset_fc
FAKE_ALIVE_RC=0
printf '3\n' > "$EMIT_DELIVERY_FAIL_FILE"
printf '%s\n' "$(( $(date +%s) - 9999 ))" > "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "E: emits-generated-but-stuck (fail>0) => self-heal fires" "$(wc -l < "$FCHEAL")" "1"
assert_contains "E: logged WATCHER-FAULT" "$(cat "$FCLOG")" "WATCHER-FAULT"

unset -f _watcher_alive _watcher_self_heal_restart log _functional_check_decide
rm -rf "$FC"

# ---------------------------------------------------------------------------
echo '=== mode #5: recovery from a logout pastes within ONE cycle (your-org/nexus-code#1567 G2) ==='
# After a /login, the emit whose turn FAILED used to wait for the next paste —
# on a quiet board the full-state heartbeat, up to 1200 s. The fix: the
# `auth-expired` clear transition fires compose_emit at once and, when the
# latest paste is the one that failed, makes that compose a full-state one.
#
# Driven END TO END: the REAL `_operator_alert` clear → the REAL main.sh hook →
# the REAL scheduler → the REAL `_v2_task_compose_emit`, whose collaborators
# are stubbed. `paste_with_retry` is the recorder, and the dedup gate is
# stubbed to NEVER suppress, so "pastes nothing" cannot be the stub's doing: a
# compose that reached the paste ladder at all would be counted.
#
# PREDICTED before running, against the base (hook absent, CLEARED_FN no-op):
#   FLIP  "G2 pending: compose_emit pulled forward"      (next_fire stays 60)
#   FLIP  "G2 pending: ONE full-state paste"             (0 pastes)
#   FLIP  "G2 nothing pending: compose_emit pulled forward"
#   HOLD  "G2 control: quiet compose pastes nothing" and both "pastes nothing"
#         rows (nothing due ⇒ no paste, with or without the hook).
G2=$(mktemp -d)
export STATE_DIR="$G2/state" TARGET="orchestrator" NEXUS_NOTIFY_QUIET=1
mkdir -p "$STATE_DIR" "$G2/stage" "$G2/tmp"
V2_STAGE_DIR="$G2/stage"; tmp_dir="$G2/tmp"; emit_body="$G2/tmp/emit.md"
BASELINE="$STATE_DIR/last-snapshot.txt"; LAST_CHANGE="$STATE_DIR/last-change.txt"
FULL_STATE_STAMP="$STATE_DIR/last-full-state-emit.ts"
FULL_STATE_CANONICAL_CACHE="$STATE_DIR/last-full-state-canonical.txt"
FULL_STATE_IDLE_ANCHOR="$STATE_DIR/last-full-state-change.ts"
export ORCH_LAST_PASTE_FILE="$STATE_DIR/orchestrator-last-paste.ts"
# CHOSEN: a 300 s due-cadence under a 1200 s floor — the production shape the
# issue measured ("up to 1200 s"), so a quiet board's heartbeat is NOT due.
MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS=300 MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS=1200
MONITOR_FULL_STATE_RESTAT_WINDOWS=false MONITOR_IDLE_RESTAT_WINDOWS=false
RESPAWN_HISTORY="$G2/rh" RESPAWN_TRIPPED="$G2/rt" RESPAWN_CONSEC_COUNTER="$G2/rc" RESPAWN_SLOW_GRIND_TRIPPED="$G2/rs"
SERVICE_HEALTH_STATE_DIR="$G2" VERSION_STATE_DIR="$G2" REPORTS_ROLL_NOTICE_FILE="$G2/roll" WATCHER_SUPERVISOR_HEARTBEAT="$G2/hb"
NEXUS_ROOT="$G2"
# The operator alert keeps a fallback memo under $TMPDIR; pin it into the fixture.
_g2_saved_tmpdir="${TMPDIR-}"; export TMPDIR="$G2/tmp"
PASTES="$G2/pastes"; : > "$PASTES"; LOGCAP="$G2/log"; : > "$LOGCAP"
# The REAL modules first, so the stubs below win over anything they define.
# shellcheck source=/dev/null
source "$_test_dir/_scheduler.sh"
# shellcheck source=/dev/null
source "$_test_dir/_auth_hold.sh"
# shellcheck source=/dev/null
source "$_test_dir/_operator_alert.sh"
log() { printf '%s\n' "$*" >> "$LOGCAP"; }
_ensure_watcher_tmp_dir() { mkdir -p "$tmp_dir"; }
_progress_bump() { :; }; _cycle_bump() { :; }; bump_heartbeat() { :; }
_compose_gh_now() { :; }; _render_budget_seconds() { printf 5; }; _bounded_failure_log() { :; }
_run_bounded() { local o="$2"; shift 2; "$@" > "$o"; }
render_full_state_snapshot() { printf 'worker-a idle\nworker-b busy\n'; }
render_idle_prelude() { printf 'prelude\n'; }
_emit_volatile_strip() { cat; }
_full_state_effective_floor() { printf '%s' "$MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS"; }
_classify_diff() { return 0; }
_oneshot_reset() { :; }; _oneshot_defer() { :; }; _oneshot_commit() { :; }
_cc_update_emit_section() { :; }; _version_emit_section() { :; }; _service_health_emit_section() { :; }
_reports_roll_emit_section() { :; }; _supervisor_arm_emit_section() { :; }
compose_report() { printf 'reason=%s\n%s\n' "$1" "$6"; }
archive_emit() { printf '%s/archive.md' "$G2"; }
_compose_emit_should_suppress() { return 1; }     # NEVER suppress — see above
_over_limit_orchestrator_paused() { return 1; }; _auth_hold_active() { return 1; }
paste_with_retry() { printf '%s\n' "$(head -n1 "$2")" >> "$PASTES"; return 0; }
_emit_delivery_ok() { :; }; _compose_emit_record_emit() { :; }; requests_commit_emitted() { :; }
_respawn_loop_reset() { :; }; _respawn_consec_reset() { :; }
eval "$(_extract_fn "$MAIN_SH" _v2_task_compose_emit)"
eval "$(_extract_fn "$MAIN_SH" _operator_alert_cleared_to_watcher)"
_OPERATOR_ALERT_LOG_FN=log; _OPERATOR_ALERT_BELL_FN=log
if declare -F _operator_alert_cleared_to_watcher >/dev/null; then
    _OPERATOR_ALERT_CLEARED_FN=_operator_alert_cleared_to_watcher
else
    fail "G2: main.sh defines no _operator_alert_cleared_to_watcher (the clear-transition hook)"
fi
_g2_quiet_board() {   # a board with NOTHING due: snapshot == baseline, full-state inside its floor
    printf 'fmt v1\nworker-a\n' > "$V2_STAGE_DIR/snapshot_local.out"
    cp "$V2_STAGE_DIR/snapshot_local.out" "$BASELINE"
    date +%s > "$FULL_STATE_STAMP"
    printf 'prelude\n---snapshot---\nworker-a idle\nworker-b busy\n' > "$FULL_STATE_CANONICAL_CACHE"
    : > "$PASTES"
}
_g2_next_fire() { printf '%s' "${TASK_NEXT_FIRE[compose_emit]:-unset}"; }
_g2_cycle() {   # raise → clear (the transition) → one compose_emit iff the scheduler says it is due
    _scheduler_reset_for_tests
    _schedule_task compose_emit 60 _v2_task_compose_emit --class medium --async
    TASK_NEXT_FIRE[compose_emit]=60
    rm -rf "$STATE_DIR/operator-alert"; _operator_alert_memo_clear auth-expired
    _operator_alert raise auth-expired critical "logged out" >/dev/null 2>&1
    _operator_alert clear auth-expired "logged back in" >/dev/null 2>&1
    [[ "$(_g2_next_fire)" == 0 ]] && _v2_task_compose_emit
}
g2_now=$(date +%s)
plant_g2_marker() {   # <marker_ts> <last_paste_ts>
    mkdir -p "$STATE_DIR/turn-failure"
    printf '{"ts":%s,"error":"authentication_failed","category":"auth","recovery":"operator","last_msg":"Login expired","window":"%s","hook_event_name":"StopFailure"}\n' \
        "$1" "$TARGET" > "$STATE_DIR/turn-failure/$TARGET.json"
    printf '%s\n' "$2" > "$ORCH_LAST_PASTE_FILE"
}

# CONTROL: a quiet board's compose pastes nothing (the stubs cannot paste on their own).
_g2_quiet_board; _v2_task_compose_emit
assert_eq "G2 control: quiet compose pastes nothing" "$(wc -l < "$PASTES")" "0"

# (a) NOTHING pending: the last paste's turn did not fail (no marker).
_g2_quiet_board; rm -rf "$STATE_DIR/turn-failure"; printf '%s\n' "$(( g2_now - 100 ))" > "$ORCH_LAST_PASTE_FILE"
_g2_cycle
assert_eq "G2 nothing pending: compose_emit pulled forward to the next tick" "$(_g2_next_fire)" "0"
assert_eq "G2 nothing pending: a clear with nothing due pastes NOTHING" "$(wc -l < "$PASTES")" "0"
[[ -f "$FULL_STATE_STAMP" && -f "$FULL_STATE_CANONICAL_CACHE" ]] \
    && pass "G2 nothing pending: the full-state clock is left alone" || fail "G2 nothing pending: the hook touched the full-state clock"

# (b) a PENDING failed emit: the marker answers the latest paste (ts >= last paste).
_g2_quiet_board; plant_g2_marker "$(( g2_now - 90 ))" "$(( g2_now - 100 ))"
_g2_cycle
assert_eq "G2 pending: compose_emit pulled forward to the next tick" "$(_g2_next_fire)" "0"
assert_eq "G2 pending: ONE full-state paste in that one cycle" "$(cat "$PASTES")" "reason=poll-full-state"
assert_contains "G2 pending: the forced emit is LOGGED with its evidence" "$(cat "$LOGCAP")" "forcing a full-state emit"

# (c) the marker is OLDER than the latest paste — a later paste already landed,
# so nothing is pending even though the marker file still exists.
_g2_quiet_board; plant_g2_marker "$(( g2_now - 100 ))" "$(( g2_now - 90 ))"
_g2_cycle
assert_eq "G2 stale marker (ts < last paste): pastes NOTHING" "$(wc -l < "$PASTES")" "0"

# (d) another key's clear does nothing here (service-health / loop-guard keys).
_g2_quiet_board; plant_g2_marker "$(( g2_now - 90 ))" "$(( g2_now - 100 ))"
_scheduler_reset_for_tests; _schedule_task compose_emit 60 _v2_task_compose_emit --class medium --async
TASK_NEXT_FIRE[compose_emit]=60
_operator_alert raise service-health:x critical "down" >/dev/null 2>&1
_operator_alert clear service-health:x "up" >/dev/null 2>&1
assert_eq "G2 another key's clear leaves compose_emit's schedule alone" "$(_g2_next_fire)" "60"

unset -f log _ensure_watcher_tmp_dir _progress_bump _cycle_bump bump_heartbeat _compose_gh_now \
    _render_budget_seconds _bounded_failure_log _run_bounded render_full_state_snapshot render_idle_prelude \
    _emit_volatile_strip _full_state_effective_floor _classify_diff _oneshot_reset _oneshot_defer _oneshot_commit \
    _cc_update_emit_section _version_emit_section _service_health_emit_section _reports_roll_emit_section \
    _supervisor_arm_emit_section compose_report archive_emit _compose_emit_should_suppress \
    _over_limit_orchestrator_paused _auth_hold_active paste_with_retry _emit_delivery_ok \
    _compose_emit_record_emit requests_commit_emitted _respawn_loop_reset _respawn_consec_reset \
    _g2_quiet_board _g2_next_fire _g2_cycle plant_g2_marker
unset NEXUS_NOTIFY_QUIET ORCH_LAST_PASTE_FILE
if [[ -n "$_g2_saved_tmpdir" ]]; then export TMPDIR="$_g2_saved_tmpdir"; else unset TMPDIR; fi
rm -rf "$G2"

# ---------------------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
