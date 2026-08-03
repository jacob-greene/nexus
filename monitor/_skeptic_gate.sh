# shellcheck shell=bash
# monitor/_skeptic_gate.sh — THE derivation of "is this window's retire
# gate armed?".  One definition, every caller delegates to it.
#
# == Why this file exists (jacob-greene/nexus#16, rounds 1-3) ==
#
# Four sites independently decided whether a worker window was still
# gated by a required-skeptic pass, and they had already drifted apart:
#
#     monitor/ng                     [[ -e marker ]]
#     monitor/retire-preflight.sh    [[ -f marker ]] && ! orphaned
#     monitor/watcher/_idle_probe.sh [[ -e marker ]] (+ its own freshness)
#     monitor/spawn-worker.sh        its own path sanitizer, for the write
#
# Three consecutive rounds of fixes on #16 each re-introduced the same
# error class — a branch asserting a gate state it never actually
# checked — because "gated" was a hand-copied expression rather than a
# named predicate.  Round 1 keyed the re-wrap guard on the DONE
# sentinel (which no writer ties to the gate); round 2 re-keyed it onto
# the marker file but kept `-e` and no liveness test, so a marker left
# behind by a dead reviewer read as "a live reviewer holds this window".
#
# THE definition, and the only one: a window is GATED exactly when
# `monitor/retire-preflight.sh` check 1b would refuse to kill it.  That
# is the gate — nothing else holds a window back — so every other site
# asking "is it gated?" is asking about retire-preflight's answer, and
# should therefore ask retire-preflight's question rather than
# re-derive it.  `-f marker && ! orphaned`, where "orphaned" is the
# idle probe's own emit/exemption-fidelity rule.
#
# == The safety property is AGREEMENT, not local conservatism ==
#
# The two consumers move in opposite directions on the same answer:
#
#     retire-preflight   gated -> REFUSE the kill      (blocks)
#     ng wrap-up         gated -> proceed with hand-off (permits)
#
# so there is no single "conservative" fallback that is safe for both.
# What is unsafe is DISAGREEMENT: `ng` saying "armed, a reviewer will
# see this" while retire-preflight says "not gated, retire allowed"
# strands a `require`-mandated worker exactly as #16/#469 describe.
# Hence one shared derivation and ONE degraded-mode rule (below), so
# the two sites are wrong together or right together, never split.
#
# == States ==
#
# skeptic_gate_state prints one of these and sets rc 0 when the state
# BLOCKS retirement (i.e. the window is genuinely gated):
#
#   absent        rc 1  no marker file at all.
#   live          rc 0  marker + a live skeptic window names this
#                       window (action-log `skeptic-spawn` whose
#                       skeptic window is still alive, or the
#                       `<window>-skeptic` fallback name).
#   grace         rc 0  marker, no live skeptic yet, still inside the
#                       orphan grace since the skeptic was REQUIRED —
#                       the orchestrator may still be spawning.
#   stale         rc 0  marker older than the await-hang window (the
#                       worker's await loop stopped refreshing it).
#                       retire-preflight treats this as a genuine
#                       no-go, so it is gated.
#   orphaned      rc 1  marker fresh, NO live skeptic, past the grace.
#                       retire-preflight lets the window retire on
#                       this (with a loud note), so nothing
#                       effectively gates it.
#   unclassified  rc 0  marker present and liveness could not be
#                       DETERMINED — either the idle-probe helpers would
#                       not load, or they loaded and tmux did not answer
#                       (no server / unreachable socket / no tmux binary;
#                       jacob-greene/nexus#31).  DEGRADED MODE:
#                       retire-preflight's own probe-missing fallback is
#                       likewise "refuse the kill", so both sites treat
#                       it as gated and stay in agreement.
#
#                       NB the two failures are one class on purpose.
#                       `orphaned` is the only marker-present state that
#                       lets a kill through, so it must be reachable ONLY
#                       from a CHECKED absence of a reviewer.  Anything
#                       that merely failed to check lands here.
#
# Callers that only need the boolean use skeptic_gate_blocks_retire.
# Callers that print a message to an agent MUST use the state name and
# say only what that state actually establishes — `live` is the ONLY
# state in which "a reviewer is holding this window" is a checked fact.

# Idempotent load guard: this file is sourced from main.sh, from
# _idle_probe.sh (for standalone/test use) and from ng.
[[ -n "${_SKEPTIC_GATE_SH_LOADED:-}" ]] && return 0
_SKEPTIC_GATE_SH_LOADED=1

_SKEPTIC_GATE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) \
    || _SKEPTIC_GATE_DIR=""

# Resolve the state dir the same way every consumer does. STATE_DIR (set
# by ng, retire-preflight and the watcher) wins; then NEXUS_STATE_DIR;
# then the canonical location under NEXUS_ROOT (spawn-worker.sh's
# context, where STATE_DIR is not set). Empty when none resolve.
skeptic_gate_state_dir() {
    if [[ -n "${STATE_DIR:-}" ]]; then
        printf '%s' "$STATE_DIR"
    elif [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
        printf '%s' "$NEXUS_STATE_DIR"
    elif [[ -n "${NEXUS_ROOT:-}" ]]; then
        printf '%s' "$NEXUS_ROOT/monitor/.state"
    else
        printf ''
    fi
}

# The path sanitizer. Every site that names a marker file — readers AND
# writers — goes through this, so they cannot disagree about WHICH file
# they mean.
skeptic_gate_safe() { printf '%s' "${1//[^a-zA-Z0-9_-]/_}"; }

# Absolute path of <window>'s pending marker. Empty when no state dir
# resolves (callers must treat empty as "cannot answer").
skeptic_gate_marker() {
    local sd; sd=$(skeptic_gate_state_dir)
    [[ -n "$sd" ]] || { printf ''; return 1; }
    printf '%s/skeptic/pending/%s' "$sd" "$(skeptic_gate_safe "${1:-}")"
}

# The directory writers create before writing a marker.
skeptic_gate_pending_dir() {
    local sd; sd=$(skeptic_gate_state_dir)
    [[ -n "$sd" ]] || { printf ''; return 1; }
    printf '%s/skeptic/pending' "$sd"
}

# rc 0 iff the marker FILE exists. `-f`, not `-e`: retire-preflight
# check 1b tests `-f`, so a directory at that path counts as no marker
# there and must count as no marker everywhere.
skeptic_gate_marker_present() {
    local m; m=$(skeptic_gate_marker "${1:-}") || return 1
    [[ -n "$m" && -f "$m" ]]
}

# Load the idle-probe helpers on demand. The liveness/grace primitives
# (_idle_skeptic_live_window, _idle_skeptic_request_epoch,
# _idle_skeptic_hang_seconds, _idle_skeptic_orphan_grace) live there
# because the watcher owns them; this lib is the classifier that
# combines them. Tried at most once — a missing probe degrades to
# `unclassified`, it does not retry per call.
_skeptic_gate_load_probe() {
    declare -F _idle_skeptic_live_window >/dev/null 2>&1 && return 0
    [[ -n "${_SKEPTIC_GATE_PROBE_TRIED:-}" ]] && return 1
    _SKEPTIC_GATE_PROBE_TRIED=1
    local cand
    for cand in \
        "${NEXUS_ROOT:+$NEXUS_ROOT/monitor/watcher/_idle_probe.sh}" \
        "${_SKEPTIC_GATE_DIR:+$_SKEPTIC_GATE_DIR/watcher/_idle_probe.sh}"
    do
        [[ -n "$cand" && -r "$cand" ]] || continue
        # shellcheck disable=SC1090
        source "$cand" 2>/dev/null || continue
        declare -F _idle_skeptic_live_window >/dev/null 2>&1 && return 0
    done
    return 1
}

# skeptic_gate_state <window> [now_epoch] [live_window_names]
#
# Prints the state name; rc 0 when the state BLOCKS retirement.
# $3 (newline-separated live tmux window names) is passed straight
# through to the liveness helper so the watcher's per-cycle snapshot is
# reused instead of re-querying tmux per window.
skeptic_gate_state() {
    local name="${1:?window required}" now="${2:-}" live="${3:-}"
    local marker; marker=$(skeptic_gate_marker "$name")
    if [[ -z "$marker" || ! -f "$marker" ]]; then
        printf 'absent'; return 1
    fi
    if ! _skeptic_gate_load_probe; then
        # Degraded: marker present, liveness unknowable here. Gated, in
        # step with retire-preflight's own probe-missing fallback.
        printf 'unclassified'; return 0
    fi
    [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)

    local hang mtime age
    hang=$(_idle_skeptic_hang_seconds)
    mtime=$(date +%s -r "$marker" 2>/dev/null || echo 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    age=$(( now - mtime ))
    if (( age > hang )); then
        # The await loop stopped refreshing it. NOT orphaned (that class
        # is reserved for a marker the orchestrator must act on); the
        # window lapses through normal idle classification, and
        # retire-preflight still refuses the kill.
        printf 'stale'; return 0
    fi

    # Tri-state (jacob-greene/nexus#31). rc 1 and rc 2 are DIFFERENT
    # answers and must not collapse: rc 1 is "I asked tmux and no skeptic
    # is alive", which walks on to grace/orphaned; rc 2 is "I could not
    # ask", which establishes nothing about liveness and therefore cannot
    # be allowed to reach `orphaned` — the single marker-present state
    # that takes the gate DOWN. It belongs in `unclassified`, the class
    # this ladder already has for "marker present, liveness unknowable
    # here", which both consumers already fail CLOSED on and already
    # describe honestly to the agent.
    _idle_skeptic_live_window "$name" "$live"
    case $? in
        0) printf 'live';         return 0 ;;
        2) printf 'unclassified'; return 0 ;;
    esac

    local req grace
    req=$(_idle_skeptic_request_epoch "$name")
    [[ "$req" =~ ^[0-9]+$ ]] || req=0
    (( req == 0 )) && req="$mtime"
    grace=$(_idle_skeptic_orphan_grace)
    if (( now - req <= grace )); then
        printf 'grace'; return 0
    fi
    printf 'orphaned'; return 1
}

# rc 0 iff retire-preflight check 1b would refuse to retire <window>.
skeptic_gate_blocks_retire() {
    skeptic_gate_state "$@" >/dev/null
}

# rc 0 iff <window>'s marker is ORPHANED — fresh, no live skeptic, past
# the grace. The actionable class: the orchestrator must either spawn
# the skeptic or clear the marker.
skeptic_gate_orphaned() {
    [[ "$(skeptic_gate_state "$@")" == orphaned ]]
}

# rc 0 iff <window> is PARKED awaiting a skeptic and therefore exempt
# from idle classification: a marker that is fresh AND either has a live
# skeptic or is still inside the spawn grace.
skeptic_gate_parked() {
    case "$(skeptic_gate_state "$@")" in
        live|grace) return 0 ;;
        *)          return 1 ;;
    esac
}
