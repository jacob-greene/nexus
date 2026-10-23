#!/usr/bin/env bash
# watcher-supervise-probe.sh — the watcher supervisor as a longjob-watch
# `cmd:` probe (your-org/nexus-code#1532).
#
# WHY THIS EXISTS. The supervisor used to be a model-armed `Monitor` whose
# until-loop ran watcher-supervise-tick.sh. Since Claude Code 2.1.271 a
# `Monitor` expires after at most 30 minutes, so the supervisor became a lease
# the orchestrator renewed ~48x/day, and the lease lapsed whenever the
# orchestrator could not take a turn: 7 h 13 m on 2026-09-17 (login expiry).
# The operator ruled out an svc-registered supervisor (it shares the watcher's
# own failure modes) and asked whether the longjob plugin could carry a
# supervisor owned by the orchestrator. It can, measured 2026-09-25:
#
#   * the orchestrator's plugin dispatcher had run continuously for 257,521 s
#     (~71.5 h) polling every 20 s — the plugin monitor is NOT subject to the
#     30-minute Monitor cap;
#   * a `--persistent` cmd watch delivered running→failed, failed→running and a
#     SECOND running→failed on the real 2.1.28x host, i.e. it survives its own
#     fire and never retires.
#
# The dispatcher is a child of the orchestrator's claude PROCESS, not of its
# turns, so polling continues while the orchestrator is logged out, over its
# limit, or mid-long-turn. That is only worth anything if the REVIVAL also
# needs no turn — so this probe revives the watcher itself (detached, below),
# and the orchestrator is woken by the transition for the record, not as the
# revival mechanism.
#
# Contract: longjob-probes.d/cmd.sh's exit vocabulary.
#   exit 1  running  — watcher alive (UP/BUSY); the tick touched the
#                      supervisor heartbeat, so the watcher reads "armed".
#   exit 2  failed   — watcher DOWN or WEDGED. A revival (revive-watcher.sh,
#                      which keeps its own crash-loop guard, intentional-stop
#                      respect and alive-and-advancing refusal) has been
#                      launched, or one is already in flight.
#   exit 0  done     — ONLY while automatic revival is LATCHED OFF (revive exit
#                      3 crash-loop guard / 4 read-only state dir). The watch is
#                      always --persistent (arm-watcher-supervisor.sh), so `done`
#                      never retires it; the failed→done TRANSITION is the ONE
#                      wake that tells the orchestrator it must act, and further
#                      latched polls stay `done` and emit nothing (ncbundle4sk B2).
#   Never 3 (unknown PARKS a watch after unknown_max polls).
#
# The revival is launched under `setsid` so the dispatcher's per-probe
# `timeout` (30 s) cannot kill a restart mid-way, and under a subshell-held
# `flock -n` so at most one is in flight however many polls see the watcher
# down — with the lock fd closed for the revive, so the watcher it launches
# never inherits (and never pins) the lock. Its output
# and exit status go to $STATE_DIR/watcher-supervisor-revive.log.
#
# Env (tests): NEXUS_STATE_DIR, SUPERVISE_TICK_BIN, SUPERVISE_REVIVE_BIN.
set -uo pipefail
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_nexus-root.sh
source "$_here/_nexus-root.sh"
_root=$(nexus_primary_root "${NEXUS_ROOT:-$_here/..}") || _root=$(cd "$_here/.." && pwd)
[[ -n "$_root" ]] || _root=$(cd "$_here/.." && pwd)
STATE_DIR="${NEXUS_STATE_DIR:-$_root/monitor/.state}"
TICK="${SUPERVISE_TICK_BIN:-$_here/watcher-supervise-tick.sh}"
REVIVE="${SUPERVISE_REVIVE_BIN:-$_here/revive-watcher.sh}"
LOCK="$STATE_DIR/watcher-supervisor-revive.lock"
LOG="$STATE_DIR/watcher-supervisor-revive.log"
# ONE REVIVAL PER OUTAGE, NOT ONE PER POLL (skeptic ncbundle4sk F1 on #1635:
# measured 4 polls -> 4 revive runs while revive refused). The flock stops
# CONCURRENT revivals; these three stop REPEATED ones:
#   STOP     watcher-stop-requested exists (svc.sh stop watcher): an intentional
#            stop is never fought — no revive at all, same rule revive-watcher.sh
#            applies, but without re-running it every poll.
#   LATCH    the last revive refused for a STANDING reason: 3 (crash-loop
#            guard) or 4 (read-only state dir) — "a human or the orchestrator
#            must act". No automatic retry until the tick sees the watcher ALIVE
#            again, so the crash-loop guard stays a STOP rather than a rate
#            limit; the latched poll answers `done` (exit 0), which is ONE wake.
#   BACKOFF  any other non-zero exit, INCLUDING 5 (revive found the watcher
#            alive and advancing while the tick said down): no relaunch within
#            SUPERVISE_REVIVE_BACKOFF seconds of that revive's end, then retry —
#            revive-watcher.sh re-verifies progress on every run. 5 is NOT
#            latched (ncbundle4sk B1): a latch would read healthy until a tick-UP,
#            so a watcher that then truly died would never be revived. We chose
#            600 s, the crash-loop guard's own window.
STOP_SENTINEL="$STATE_DIR/watcher-stop-requested"
LAST="$STATE_DIR/watcher-supervisor-revive.last"     # "<end-epoch> <rc>"
LATCH="$STATE_DIR/watcher-supervisor-revive.latched"
BACKOFF="${SUPERVISE_REVIVE_BACKOFF:-600}"
[[ "$BACKOFF" =~ ^[0-9]+$ ]] || BACKOFF=600

"$TICK" >/dev/null 2>&1
tick_rc=$?
if (( tick_rc == 0 )); then
    rm -f "$LATCH" 2>/dev/null   # seen alive: a later outage may be revived again
    echo "watcher alive"
    exit 1
fi

if [[ -e "$STOP_SENTINEL" ]]; then
    echo "watcher down (tick rc=$tick_rc) by INTENTIONAL stop ($STOP_SENTINEL) — not reviving"
    exit 2
fi
if [[ -e "$LATCH" ]]; then
    _lrc=$(cut -d' ' -f1 "$LATCH" 2>/dev/null)
    # `!! ` marks an ALERT: longjob-watch composes it at the HEAD of the wake
    # line, so a DONE state word can never be read as a success.
    case "${_lrc:-?}" in 3) _why="crash-loop guard" ;; 4) _why="read-only state dir" ;; *) _why="revive exit ${_lrc:-?}" ;; esac
    echo "!! LATCHED — ORCHESTRATOR MUST ACT: watcher down, auto-revival OFF ($_why); run $_here/revive-watcher.sh, see $LOG"
    exit 0
fi
if [[ -r "$LAST" ]]; then
    read -r _last_end _last_rc < "$LAST" 2>/dev/null || true
    if [[ "${_last_end:-}" =~ ^[0-9]+$ && "${_last_rc:-}" =~ ^[0-9]+$ ]] && (( _last_rc != 0 && _last_rc != 3 && _last_rc != 4 )); then
        _age=$(( $(date +%s) - _last_end ))
        if (( _age < BACKOFF )); then
            echo "watcher down (tick rc=$tick_rc); last revive exited $_last_rc ${_age}s ago — backing off (${BACKOFF}s) — see $LOG"
            exit 2
        fi
    fi
fi

# DOWN or WEDGED. Launch at most one detached revival.
if command -v flock >/dev/null 2>&1; then
    # Probe the lock first so a revival already in flight is REPORTED, not
    # just silently skipped by the detached child.
    # Subshell-scoped (the fd dies with the subshell, so no child inherits the
    # lock — the out-of-scope form of test-flock-fd-cloexec).
    if ! ( flock -n 9 ) 9>>"$LOCK" 2>/dev/null; then
        echo "watcher down (tick rc=$tick_rc); a revival is already in flight — see $LOG"
        exit 2
    fi
    # The lock is held by a SUBSHELL and the revive runs with fd 9 CLOSED
    # (`9>&-`). NOT `flock LOCK cmd`: measured (util-linux 2.42), its child
    # inherits the lock fd, so the watcher that revive-watcher.sh daemonizes
    # would hold the lock for its whole life and every LATER outage would read
    # "already in flight" and never be revived (the #494 flock-fd class).
    setsid bash -c '
        ( flock -n 9 || exit 0
          printf "%s revive start (tick rc=%s)\n" "$(date +%s)" "$2"
          "$1" 9>&-; rc=$?
          now=$(date +%s)
          printf "%s revive end rc=%s\n" "$now" "$rc"
          printf "%s %s\n" "$now" "$rc" > "$4.tmp" && mv -f "$4.tmp" "$4"
          case "$rc" in
              3|4) printf "%s %s\n" "$rc" "$now" > "$5" ;;
          esac
        ) 9>>"$3"
    ' _ "$REVIVE" "$tick_rc" "$LOCK" "$LAST" "$LATCH" >>"$LOG" 2>&1 </dev/null &
else
    setsid bash -c '
        printf "%s revive start (tick rc=%s, no flock)\n" "$(date +%s)" "$2"
        "$1"; rc=$?
        now=$(date +%s)
        printf "%s revive end rc=%s\n" "$now" "$rc"
        printf "%s %s\n" "$now" "$rc" > "$3.tmp" && mv -f "$3.tmp" "$3"
        case "$rc" in
            3|4) printf "%s %s\n" "$rc" "$now" > "$4" ;;
        esac
    ' _ "$REVIVE" "$tick_rc" "$LAST" "$LATCH" >>"$LOG" 2>&1 </dev/null &
fi
echo "watcher down (tick rc=$tick_rc); revival launched — see $LOG"
exit 2
