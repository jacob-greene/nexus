#!/usr/bin/env bash
# arm-watcher-supervisor.sh — arm the watcher supervisor as a persistent
# longjob-watch in the CALLING session (your-org/nexus-code#1532). Run by the
# orchestrator; idempotent, so every surface that used to say "arm the
# supervisor Monitor" can simply say "run this".
#
# The supervisor is `monitor/watcher-supervise-probe.sh` run by the session's
# plugin dispatcher every INTERVAL seconds. The plugin dispatcher is not bound
# by the 30-minute Monitor cap and polls independently of the orchestrator's
# turns, and the probe revives a dead watcher itself, so no re-arm lease and
# no turn is needed (measurements: the probe's header).
#
# Watch shape, each flag chosen here, none upstream convention:
#   --persistent        emit on every transition and never retire on one
#   --ttl 0             no 7-day expiry
#   --max-events 100000 the per-watch cap RETIRES a watch; a supervisor must
#                       not retire after four watcher deaths (2 events each)
#   --unknown-max 100000 an unknown streak PARKS a watch; the probe never
#                       answers unknown except on a probe timeout
#   --no-declare        a supervisor is not a wait: declaring it would make
#                       the orchestrator read idle-orphan-async forever
#   --interval 30       the watcher reads the supervisor heartbeat as stale
#                       after 90 s; 30 s keeps three ticks inside that
#
# Exit: 0 armed (newly, or already) · 3 NOT ARMED — the plugin dispatcher is
#       not serving this session; stdout prints the fallback Monitor lease
#       (re-arm it on every expiry) · 2 usage / no session · other = add's rc.
set -uo pipefail
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_nexus-root.sh
source "$_here/_nexus-root.sh"
_root=$(nexus_primary_root "${NEXUS_ROOT:-$_here/..}") || _root=$(cd "$_here/.." && pwd)
[[ -n "$_root" ]] || _root=$(cd "$_here/.." && pwd)
LJ="${ARM_SUPERVISOR_LONGJOB_BIN:-$_here/longjob-watch.sh}"
ID=watcher-supervisor
INTERVAL="${ARM_SUPERVISOR_INTERVAL:-30}"

case "${1:-}" in
    -h|--help) sed -n '2,/^set -uo pipefail/{/^set -uo pipefail/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    "") ;;
    *) echo "arm-watcher-supervisor: unexpected argument '$1'" >&2; exit 2 ;;
esac

_fallback() {
    # shellcheck source=watcher/_lib.sh
    source "$_here/watcher/_lib.sh" 2>/dev/null
    echo "FALLBACK — arm the 30-minute Monitor lease instead, and re-arm it on every expiry:"
    if declare -F _supervisor_monitor_command >/dev/null; then
        printf '  %s\n' "$(_supervisor_monitor_command "$_root")"
    else
        printf '  Monitor({command: "until ! %s/monitor/watcher-supervise-tick.sh; do sleep 15; done"})\n' "$_root"
    fi
}

# Already there and live? A retired spec (capped, parked, expired) is removed
# and re-added; a live one is left alone, but the dispatcher's arming is still
# checked, because a watch in a spool nobody polls supervises nothing.
spec=$("$LJ" show "$ID" 2>/dev/null); show_rc=$?
if (( show_rc == 0 )); then
    if [[ "$(printf '%s' "$spec" | jq -r '.retired // false' 2>/dev/null)" == true ]]; then
        "$LJ" rm "$ID" >/dev/null 2>&1 || true
    else
        # `status` prints `dispatcher=<armed|stale|dead|absent|muted|disabled>`.
        # `muted` still PROBES (a muted dispatcher logs instead of printing), so
        # the supervisor still revives; only the wake is lost.
        # Read the whole status (no early-closing reader: #622 class) and keep
        # the FIRST `dispatcher=` word.
        verdict=""
        while IFS= read -r _l; do
            [[ -z "$verdict" && "$_l" == dispatcher=* ]] || continue
            verdict=${_l#dispatcher=}; verdict=${verdict%% *}
        done < <("$LJ" status 2>/dev/null)
        if [[ "$verdict" == armed || "$verdict" == muted ]]; then
            echo "watcher supervisor: already ARMED as longjob watch '$ID' (persistent, every ${INTERVAL}s)."
            exit 0
        fi
        # Present but the dispatcher is not armed: report, and fall back.
        echo "watcher supervisor: watch '$ID' exists but this session's dispatcher is NOT ARMED (dispatcher=${verdict:-unknown})."
        _fallback
        exit 3
    fi
fi

out=$("$LJ" add "cmd:$_here/watcher-supervise-probe.sh" --id "$ID" --persistent \
        --interval "$INTERVAL" --ttl 0 --max-events 100000 --unknown-max 100000 \
        --no-declare --desc "watcher supervisor (#1532): revives a dead watcher, no turn needed" 2>&1)
rc=$?
printf '%s\n' "$out"
case "$rc" in
    0) echo "watcher supervisor: ARMED as persistent longjob watch '$ID' (every ${INTERVAL}s). No re-arm is needed; it lives as long as this claude process." ;;
    3) if grep -q 'dispatcher: MUTED' <<<"$out"; then
           # A muted dispatcher still PROBES, so the probe still revives; only
           # the wake line is withheld. Keep the watch; say so.
           echo "watcher supervisor: ARMED as '$ID', but this session's dispatcher is MUTED — revivals still run, their wake lines are withheld until: $LJ unmute"
           exit 0
       fi
       "$LJ" rm "$ID" >/dev/null 2>&1 || true
       _fallback ;;
esac
exit "$rc"
