#!/usr/bin/env bash
# degraded-status.sh — `ng degraded status`: is this nexus in degraded mode,
# what did the watcher last say about it, and is the tree writable NOW
# (your-org/nexus-code#1724). Read-only: it writes nothing anywhere.
#
# TWO SOURCES, printed separately because they can disagree:
#   watcher:  the status file the watcher keeps in its run dir OUTSIDE the
#             tree (monitor/_degraded-rundir.sh: derived from the managed
#             $TMPDIR; NEXUS_DEGRADED_RUNDIR overrides) — mode, onset, the errno of
#             its last note, how many notes went out and whether each was
#             delivered or refused. This is where a note the orchestrator pane
#             REFUSED (an operator draft in the box) can still be read.
#   probe:    degraded-probe.sh over the registered surfaces, run now.
# plus the relocation pointer `ng degraded enter` writes, when one is in force.
# A watcher that last said `degraded` while the probe now says OK has not yet
# run its next cycle; the line says so rather than picking one.
#
# Usage: degraded-status.sh [--timeout S]
#
# Exit codes (the probe's vocabulary, so a caller tests one thing):
#   0  every surface writable now, and the watcher is not reporting degraded
#   1  a surface is not OK now, OR the watcher's last word is `degraded`
#   2  bad usage
#  64  a value-taking flag given LAST with no value (the argument-loop
#      backstop every tool here shares, your-org/nexus-code#924)
#   3  could not probe (no `timeout`, no surfaces) — neither OK nor degraded

set -u
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
timeout_s=5
# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924): a value-taking flag
# given LAST must not spin. Full rationale: monitor/ng.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}
_argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --timeout) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "degraded-status: --timeout wants a positive integer" >&2; exit 2; }
                   timeout_s=$2; shift 2 ;;
        -h|--help) sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
        *) echo "degraded-status: unknown argument: ${1:0:60}" >&2; exit 2 ;;
    esac
done

root="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"
STATE_DIR="${NEXUS_STATE_DIR:-$root/monitor/.state}"

# shellcheck source=watcher/_fs_guard.sh
. "$_self_dir/watcher/_fs_guard.sh"

wmode=""
sf=$(_fs_status_path "$STATE_DIR")
echo "watcher:"
if [[ -n "$sf" && -f "$sf" ]]; then
    upd=$(sed -n 's/^updated=//p' "$sf" | head -1)
    age=""; [[ "$upd" =~ ^[0-9]+$ ]] && age=" ($(( $(date +%s) - upd ))s ago)"
    wmode=$(sed -n 's/^mode=//p' "$sf" | head -1)
    echo "  status file: $sf$age"
    sed 's/^/  /' "$sf"
else
    echo "  no status file for $STATE_DIR (the watcher has not been degraded since the run dir was last cleared)"
fi

# THE RELOCATION POINTER (`ng degraded enter|exit`, degraded-relocate.sh): read
# through the same resolver the surfaces use, so this line and the writers
# cannot disagree about whether a relocation is in force.
echo "relocation:"
# shellcheck source=_degraded-pointer.sh
. "$_self_dir/_degraded-pointer.sh"
if _ptr=$(nexus_degraded_pointer_path "$STATE_DIR") && [[ -f "$_ptr" ]]; then
    _ent=$(awk -F= '$1 == "entered" { print substr($0, 9); exit }' "$_ptr")
    _age=""; [[ "$_ent" =~ ^[0-9]+$ ]] && _age=" (entered $(( $(date +%s) - _ent ))s ago)"
    echo "  IN FORCE: $_ptr$_age — leave with \`ng degraded exit\`"
    grep -v '^#' "$_ptr" | sed 's/^/  /'
else
    echo "  none: every surface resolves to the tree"
fi
# Relocations a restart WIPED before they were exited, not yet acknowledged —
# listed even while a newer relocation is in force (the #1724 residual).
_lost=$(nexus_degraded_lost_records "$STATE_DIR" 2>/dev/null) || _lost=""
while IFS= read -r _rec; do
    [[ -n "$_rec" ]] || continue
    _at=$(awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i ~ /^entered=/) { print substr($i, 9); exit } }' <<<"$_rec")
    if [[ "$_at" =~ ^[0-9]+$ ]]; then _w=$(date -d "@$_at" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "epoch $_at"); else _w="at an unrecorded time"; fi
    echo "  LOST (unacknowledged): relocation entered $_w — its staged writes never reached the tree; acknowledge with \`ng degraded exit --ack-loss\`"
done <<<"$_lost"

echo "probe:"
NEXUS_ROOT="$root" NEXUS_STATE_DIR="$STATE_DIR" bash "$_self_dir/degraded-probe.sh" --timeout "$timeout_s" | sed 's/^/  /'
prc=${PIPESTATUS[0]}

if [[ "$wmode" == degraded && "$prc" == 0 ]]; then
    echo "note: the watcher's last word is DEGRADED but every surface probes OK now; the watcher clears it on its next cycle."
fi
(( prc == 3 )) && exit 3
(( prc != 0 )) && exit 1
[[ "$wmode" == degraded ]] && exit 1
exit 0
