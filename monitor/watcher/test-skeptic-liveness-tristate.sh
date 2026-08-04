#!/usr/bin/env bash
# The three-arm table for the skeptic-liveness probe
# (jacob-greene/nexus#31), made executable.
#
# THE DEFECT: `_idle_skeptic_live_window` inferred liveness from an EMPTY
# tmux window list and threw tmux's exit status away with `2>/dev/null`,
# so "I asked and no skeptic is live" and "I could not ask" were the same
# rc 1. They point opposite ways at the retire gate.
#
# THE TEST: hold the ON-DISK state IDENTICAL across three arms — fresh
# skeptic-pending marker, a `skeptic-spawn` event naming a skeptic window
# that is GENUINELY ALIVE, and a request timestamp past the orphan grace
# — and vary ONLY whether tmux answers:
#
#     arm                     probe rc   gate-state       gate
#     tmux answers            0          live             GATED
#     tmux absent (rc 127)    2          unclassified     GATED   <- was orphaned
#     tmux exits 1 (no srv)   2          unclassified     GATED   <- was orphaned
#
# `gate-state` is skeptic_gate_state's own answer (monitor/_skeptic_gate.sh),
# i.e. the SHARED derivation that retire-preflight.sh check 1b and
# `ng wrap-up`'s re-wrap guard both consume. Asserting the state NAME (not
# just the boolean) is the point: `unclassified` and `orphaned` are both
# marker-present states, they differ only in what was established, and
# only `orphaned` lets a kill through.
#
# Before the fix the bottom two rows read `orphaned`, the ONE
# marker-present state retire-preflight.sh check 1b does not block on —
# so a tmux misread retired a worker whose reviewer was alive.
#
# Every arm calls the predicates with an EMPTY live-window list, which is
# exactly how retire-preflight.sh and `ng` call them (they pass no window
# snapshot, so the probe must query tmux itself). The watcher's own
# per-cycle snapshot path is covered by arm 4.
#
# Run: bash monitor/watcher/test-skeptic-liveness-tristate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR/skeptic/pending"
export STATE_DIR
# No config/load.sh reachable → hang 600, orphan grace 600 (defaults).
unset NEXUS_ROOT MONITOR_SKEPTIC_AWAIT_HANG_SECONDS \
      MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS 2>/dev/null || true

ORIG_PATH="$PATH"

# ---- arm machinery -------------------------------------------------------
# Three PATHs that differ ONLY in `tmux`. Each is a farm of the utilities
# this code path uses (grep/sed/awk/date), so the arms are otherwise
# identical environments; the ABSENT arm is simply the farm with no tmux
# in it, so the shell's own PATH lookup fails with rc 127 — the real
# absence mechanism, not a stub pretending to be one.
farm() {
    local d="$1" t p; mkdir -p "$d"
    for t in grep sed awk date cat touch rm mkdir env bash; do
        p=$(PATH="$ORIG_PATH" command -v "$t" 2>/dev/null) || continue
        ln -sf "$p" "$d/$t"
    done
}

NOTMUX_DIR="$WORK/bin-notmux"; farm "$NOTMUX_DIR"

STUB_DIR="$WORK/bin-answers"; farm "$STUB_DIR"
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

FAIL_DIR="$WORK/bin-exit1"; farm "$FAIL_DIR"
# `tmux list-windows` with no server: nothing on stdout, a diagnosis on
# stderr, exit 1. Verified against the tmux on this host.
cat > "$FAIL_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'no server running on /tmp/tmux-0/default\n' >&2
exit 1
STUB
chmod +x "$FAIL_DIR/tmux"

# shellcheck source=_idle_probe.sh
source "$PROBE"
# _idle_probe.sh sources the shared gate lib on load; assert it, because
# every gate-state assertion below depends on it.
if ! declare -F skeptic_gate_state >/dev/null 2>&1; then
    echo "harness: skeptic_gate_state not defined after sourcing the probe" >&2
    exit 2
fi

ACTION_LOG="$STATE_DIR/action-log.jsonl"
NOW=$(date +%s)

iso() { date -d "@$1" -Is 2>/dev/null || date -Is; }
mk_marker() { local f="$STATE_DIR/skeptic/pending/${1//[^a-zA-Z0-9_-]/_}"; : > "$f"; touch -d "@$2" "$f"; }
log_request() { printf '{"ts":"%s","agent":"monitor","event":"skeptic-request","target-window":"%s","depth":"1"}\n' "$(iso "$2")" "$1" >> "$ACTION_LOG"; }
log_spawn()   { printf '{"ts":"%s","agent":"monitor","event":"skeptic-spawn","window":"%s","target-window":"%s","orig-window":"%s","depth":"1"}\n' "$(iso "$3")" "$2" "$1" "$1" >> "$ACTION_LOG"; }

# ---- THE on-disk state. Identical for every arm. -------------------------
WIN=wkr
mk_marker   "$WIN" "$NOW"                              # marker FRESH
log_request "$WIN" "$(( NOW - 1200 ))"                 # required 20 min ago (> 600 grace)
log_spawn   "$WIN" "$WIN-skeptic" "$(( NOW - 1100 ))"  # a real skeptic WAS spawned
# ...and that skeptic window is genuinely alive whenever tmux can say so.
export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr\nwkr-skeptic'

# ---- the arm table -------------------------------------------------------
# run_arm <path-dir> <label> <expected-probe-rc> <expected-orphaned:yes|no>
#         <expected-gate-state>
run_arm() {
    local dir="$1" label="$2" want_rc="$3" want_orphan="$4" want_state="$5"
    local rc
    (
        PATH="$dir"
        # Self-check: the arm must actually be the arm it claims to be.
        case "$label" in
            *absent*) command -v tmux >/dev/null 2>&1 && exit 90 ;;
            *)        command -v tmux >/dev/null 2>&1 || exit 91 ;;
        esac
        _idle_skeptic_live_window "$WIN" ""
        exit $?
    )
    rc=$?
    case "$rc" in
        90) bad "$label: arm setup broken — tmux is reachable in the ABSENT arm"; return ;;
        91) bad "$label: arm setup broken — no tmux in the arm's PATH"; return ;;
    esac
    if [[ "$rc" == "$want_rc" ]]; then
        ok "$label: _idle_skeptic_live_window rc $rc (want $want_rc)"
    else
        bad "$label: _idle_skeptic_live_window rc $rc, want $want_rc"
    fi

    # Same arm, now through the two predicates the gate consumers use.
    local orph parked
    ( PATH="$dir"; _idle_skeptic_orphaned "$WIN" "$NOW" "" ); orph=$?
    ( PATH="$dir"; _idle_skeptic_parked   "$WIN" "$NOW" "" ); parked=$?
    if [[ "$want_orphan" == yes ]]; then
        (( orph == 0 )) && ok "$label: orphaned (marker does NOT block the kill)" \
                        || bad "$label: expected ORPHANED, got rc $orph"
    else
        (( orph != 0 )) && ok "$label: NOT orphaned → marker still GATES the kill" \
                        || bad "$label: expected NOT orphaned (gate must hold), got orphaned"
    fi
    printf '       (parked rc=%s)\n' "$parked"

    # The SHARED derivation both gate consumers actually call.
    local state blocks
    state=$( PATH="$dir"; skeptic_gate_state "$WIN" "$NOW" "" ); blocks=$?
    [[ "$state" == "$want_state" ]] \
        && ok "$label: skeptic_gate_state = $state" \
        || bad "$label: skeptic_gate_state = $state, want $want_state"
    if [[ "$want_orphan" == yes ]]; then
        (( blocks != 0 )) && ok "$label: gate does NOT block retire (rc 1)" \
                          || bad "$label: gate blocked retire, expected it not to"
    else
        (( blocks == 0 )) && ok "$label: gate BLOCKS retire (rc 0)" \
                          || bad "$label: gate did not block retire, expected it to"
    fi
}

echo "=== arm 1: tmux ANSWERS — reviewer visible → live, GATED ==="
run_arm "$STUB_DIR"   "arm1/tmux-answers" 0 no live

echo "=== arm 2: tmux ABSENT (rc 127) — nothing established → GATED ==="
run_arm "$NOTMUX_DIR" "arm2/tmux-absent"  2 no unclassified

echo "=== arm 3: tmux EXITS 1 (no server) — nothing established → GATED ==="
run_arm "$FAIL_DIR"   "arm3/tmux-exit1"   2 no unclassified

# ---- arm 4: the CONTROL. rc 1 must still mean rc 1. ----------------------
# Fail-closed is only correct if it is NARROW: an answering tmux that
# genuinely shows no skeptic must still produce rc 1 and `orphaned`, or
# the fix has simply disabled the orphan class.
echo "=== arm 4 (control): tmux answers, skeptic window GONE → rc 1, orphaned ==="
(
    PATH="$STUB_DIR"
    export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr'   # skeptic really died
    _idle_skeptic_live_window "$WIN" ""
    exit $?
)
rc4=$?
(( rc4 == 1 )) && ok "control: asked, none alive → rc 1 (not folded into 2)" \
               || bad "control: expected rc 1, got $rc4"
(
    PATH="$STUB_DIR"
    export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr'
    _idle_skeptic_orphaned "$WIN" "$NOW" ""
)
orph4=$?
(( orph4 == 0 )) && ok "control: dead skeptic past grace → still ORPHANED" \
                 || bad "control: expected orphaned, got rc $orph4"
state4=$( PATH="$STUB_DIR"; export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr'; skeptic_gate_state "$WIN" "$NOW" "" )
[[ "$state4" == orphaned ]] \
    && ok "control: skeptic_gate_state = orphaned (class not disabled)" \
    || bad "control: skeptic_gate_state = $state4, want orphaned"

# ---- arm 5: a caller-supplied window list never consults tmux -----------
# The watcher passes its per-cycle snapshot as $3. That list IS an answer
# tmux already gave, so the probe must trust it even where tmux itself is
# unreachable — otherwise the whole poll degrades to `unknown`.
echo "=== arm 5: caller-supplied snapshot, tmux ABSENT → still decides ==="
(
    PATH="$NOTMUX_DIR"
    _idle_skeptic_live_window "$WIN" $'orchestrator\nwkr\nwkr-skeptic'
)
rc5=$?
(( rc5 == 0 )) && ok "supplied snapshot naming the skeptic → rc 0 (live), no tmux call" \
               || bad "supplied snapshot: expected rc 0, got $rc5"
(
    PATH="$NOTMUX_DIR"
    _idle_skeptic_live_window "$WIN" $'orchestrator\nwkr'
)
rc5b=$?
(( rc5b == 1 )) && ok "supplied snapshot without the skeptic → rc 1 (asked, none alive)" \
                || bad "supplied snapshot: expected rc 1, got $rc5b"

# ---- arm 6: the ladder must not kill a `set -e` caller -----------------
# rc 1 — "asked tmux, no skeptic alive" — is the ORDINARY answer on this
# path, not a failure. A bare `_idle_skeptic_live_window …; case $?` would
# make it one: a simple command returning non-zero terminates a `set -e`
# caller outright, so skeptic_gate_state would die BEFORE printing any
# state at all, and its caller would read an EMPTY string where it
# expects one of the six names — an unknown state that matches no arm of
# any consumer's dispatch. The `if` this tri-state rewrite replaced was
# errexit-exempt by construction; the replacement has to keep that
# property. `monitor/spawn-worker.sh` already runs `set -euo pipefail`
# and already sources this lib.
#
# BEHAVIOURAL, not textual: each arm runs the derivation as a BARE simple
# command inside a genuinely errexit-armed shell (an `if`/`&&`/`$(…)`
# wrapper here would suppress errexit for its whole dynamic extent and
# the test would pass on the broken code), drives the rc-1 path, and
# checks that execution REACHED the line after the call.
echo "=== arm 6 (regression): rc 1 must not abort a set -e caller ==="

GRACE_WIN=wkr-in-grace
mk_marker   "$GRACE_WIN" "$NOW"                  # fresh marker
log_request "$GRACE_WIN" "$(( NOW - 60 ))"       # required 1 min ago → INSIDE grace
# No skeptic-spawn event, and tmux lists no `-skeptic` window, so the
# liveness probe answers rc 1 and the grace ladder decides.

ARM6_OUT="$WORK/arm6.out"

# The tree under test is resolved from THIS FILE's location and from
# nothing else. Every nexus agent runs with an ambient NEXUS_ROOT pointing
# at the primary clone, and these libs prefer `$NEXUS_ROOT/monitor/…` over
# their own directory when they resolve each other (see
# `_skeptic_gate_load_probe` and retire-preflight.sh's gate_lib pick) — so
# a suite that does not pin the root can green up against a tree it never
# edited. The driver re-sources from $OWN_TREE explicitly, defeats the
# libs' idempotent load guards so the re-source actually takes, re-exports
# NEXUS_ROOT to match, and pins the two tunables the ladder reads so no
# tree's config/load.sh can move the grace boundary under the fixture.
OWN_TREE=$(cd "$_test_dir/../.." && pwd)

# Rewrite <src> to <dst> with the errexit-safe status capture UNDONE —
# the shape this fix replaced: a bare `_idle_skeptic_live_window …`
# followed by `case $? in`. Keyed on the OPERATION (a guarded call whose
# status is captured into a variable, and the `case` that reads it), not
# on that variable's spelling. Writes its edit count to <cntfile> so an
# inert transform is caught instead of silently producing a decoy that is
# identical to the real thing.
revert_fix() {
    awk -v cnt="$3" '
        {
            line = $0
            if (line ~ /_idle_skeptic_live_window/ &&
                match(line, /[ \t]*\|\|[ \t]*[A-Za-z_][A-Za-z0-9_]*=\$\?[ \t]*$/)) {
                var = substr(line, RSTART, RLENGTH)
                sub(/^[ \t]*\|\|[ \t]*/, "", var); sub(/=\$\?[ \t]*$/, "", var)
                line = substr(line, 1, RSTART - 1)
                captured[var] = 1
                n++
            } else if (match(line, /^[ \t]*case[ \t]+\$[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]*$/)) {
                v = line
                sub(/^[ \t]*case[ \t]+\$/, "", v); sub(/[ \t]+in[ \t]*$/, "", v)
                if (v in captured) { sub(/\$[A-Za-z_][A-Za-z0-9_]*/, "$?", line); n++ }
            }
            print line
        }
        END { print n + 0 > cnt }
    ' "$1" > "$2"
}

DECOY="$WORK/decoy-tree"
mkdir -p "$DECOY/monitor/watcher"
cp "$OWN_TREE/monitor/watcher/_idle_probe.sh" "$DECOY/monitor/watcher/_idle_probe.sh"
revert_fix "$OWN_TREE/monitor/_skeptic_gate.sh" \
           "$DECOY/monitor/_skeptic_gate.sh" "$WORK/decoy.count"
DECOY_EDITS=$(cat "$WORK/decoy.count")

# Run <fn> <args…> as a BARE simple command under `set -euo pipefail`,
# against the libs in <tree>. Echoes "reached <rc>" iff control returned
# from the call; nothing if errexit killed the shell mid-derivation.
# Anything the callee printed lands in $ARM6_OUT, so the state NAME stays
# assertable even when the call itself legitimately returns non-zero.
under_errexit_in() {
    local tree="$1"; shift
    : > "$ARM6_OUT"
    (
        set -uo pipefail
        PATH="$STUB_DIR"
        export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr\nwkr-in-grace'
        export NEXUS_ROOT="$tree"
        export MONITOR_SKEPTIC_AWAIT_HANG_SECONDS=600
        export MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS=600
        # shellcheck disable=SC1090
        source "$tree/monitor/watcher/_idle_probe.sh" >/dev/null 2>&1
        # The gate lib is idempotent-guarded and _idle_probe.sh only pulls
        # it in when it is not already defined; clear the guard and source
        # it directly so <tree>'s copy is genuinely the one under test.
        unset _SKEPTIC_GATE_SH_LOADED
        # shellcheck disable=SC1090
        source "$tree/monitor/_skeptic_gate.sh" >/dev/null 2>&1
        set -euo pipefail
        "$@" > "$ARM6_OUT"         # <- bare. errexit is live on this line.
        printf 'reached %s\n' "$?"
    ) 2>/dev/null
}

# 6a CONTROL — proves errexit is actually armed in the driver. A window
# with NO marker returns rc 1 from the marker check, a path that never
# reaches the liveness call. That bare rc 1 MUST kill the subshell. If
# this reports "reached", the harness tests nothing and every assertion
# below is vacuous.
ctl=$(under_errexit_in "$OWN_TREE" skeptic_gate_state no-such-window "$NOW" "")
[[ -z "$ctl" ]] \
    && ok "control: errexit IS armed (a bare rc 1 kills the caller)" \
    || bad "control: harness is not errexit-armed — got '$ctl'; every arm-6 assertion is vacuous"

# 6b THE derivation both consumers call, on the rc-1 path, inside the
# grace window: must print `grace`, return 0, and leave the caller alive.
got=$(under_errexit_in "$OWN_TREE" skeptic_gate_state "$GRACE_WIN" "$NOW" "")
printed=$(cat "$ARM6_OUT")
[[ "$got" == "reached 0" ]] \
    && ok "skeptic_gate_state: rc-1 liveness → caller survives" \
    || bad "skeptic_gate_state: caller did not survive the rc-1 path (got '${got:-<killed>}', want 'reached 0')"
[[ "$printed" == grace ]] \
    && ok "skeptic_gate_state: rc-1 liveness → printed 'grace'" \
    || bad "skeptic_gate_state: printed '${printed:-<nothing>}', want 'grace' (an empty state matches no consumer's dispatch)"

# 6c …and past the grace, where the answer is `orphaned` — the one state
# that takes the gate DOWN, and the one state that is rc 1. Survival is
# NOT the observable here: `orphaned` returns 1 by contract, so a bare
# call under `set -e` is killed by the function's own honest verdict no
# matter what this file does. What must differ is whether the verdict was
# REACHED — i.e. whether anything was printed before control left.
under_errexit_in "$OWN_TREE" skeptic_gate_state "$WIN" "$NOW" "" >/dev/null
printed=$(cat "$ARM6_OUT")
[[ "$printed" == orphaned ]] \
    && ok "skeptic_gate_state: rc-1 liveness past grace → printed 'orphaned'" \
    || bad "skeptic_gate_state past grace: printed '${printed:-<nothing>}', want 'orphaned' (killed before it could classify)"

# 6d the two probe wrappers, same property. They reach the ladder through
# a command substitution today, which is errexit-exempt on its own — so
# these are a guard against a future rewrite that drops that, not a
# restatement of 6b.
got=$(under_errexit_in "$OWN_TREE" _idle_skeptic_parked "$GRACE_WIN" "$NOW" "")
[[ "$got" == "reached 0" ]] \
    && ok "_idle_skeptic_parked: rc-1 liveness → grace, caller survives" \
    || bad "_idle_skeptic_parked: caller did not survive the rc-1 path (got '${got:-<killed>}', want 'reached 0')"

got=$(under_errexit_in "$OWN_TREE" _idle_skeptic_orphaned "$WIN" "$NOW" "")
[[ "$got" == "reached 0" ]] \
    && ok "_idle_skeptic_orphaned: rc-1 liveness → orphaned, caller survives" \
    || bad "_idle_skeptic_orphaned: caller did not survive the rc-1 path (got '${got:-<killed>}', want 'reached 0')"

# ---- 6e the NEGATIVE arm: the same assertions must FAIL on a tree
# without the fix. Without this, 6b/6c pass on any tree whose libs merely
# load — including the primary clone's — and the arm certifies nothing
# about the file in THIS working tree.
(( DECOY_EDITS >= 2 )) \
    && ok "decoy fixture: reverted $DECOY_EDITS guarded-capture sites" \
    || bad "decoy fixture is INERT ($DECOY_EDITS edits, want >= 2) — 6e proves nothing; the transform no longer matches the code"

# The decoy must still be a WORKING lib, or 6e would pass for the wrong
# reason (a syntax error aborts just as an errexit trip does).
bash -n "$DECOY/monitor/_skeptic_gate.sh" 2>/dev/null \
    && ok "decoy fixture: still parses" \
    || bad "decoy fixture: does not parse — 6e cannot distinguish errexit from a broken copy"

under_errexit_in "$DECOY" skeptic_gate_state "$GRACE_WIN" "$NOW" "" >/dev/null
printed=$(cat "$ARM6_OUT")
[[ -z "$printed" ]] \
    && ok "NEGATIVE: same arm against a tree WITHOUT the fix → no state printed (guard discriminates)" \
    || bad "NEGATIVE: unfixed tree still printed '$printed' — this guard passes regardless of the code it reads"

under_errexit_in "$DECOY" skeptic_gate_state "$WIN" "$NOW" "" >/dev/null
printed=$(cat "$ARM6_OUT")
[[ -z "$printed" ]] \
    && ok "NEGATIVE: unfixed tree past grace → killed before it could classify" \
    || bad "NEGATIVE: unfixed tree still printed '$printed' — this guard passes regardless of the code it reads"

PATH="$ORIG_PATH"

printf '\n%s\n' "-------------------------------------------"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "SOME TESTS FAILED" >&2
exit 1
