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

PATH="$ORIG_PATH"

printf '\n%s\n' "-------------------------------------------"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "SOME TESTS FAILED" >&2
exit 1
