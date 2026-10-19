#!/usr/bin/env bash
# test-urgent-decision-surface.sh — a forwarded dangerous-rm request reaches
# the orchestrator WITHOUT waiting on the compose_emit body
# (your-org/nexus-code#1768).
#
# THE DEFECT. A worker's dangerous-rm request (#1632) blocks it until the
# orchestrator answers, and its hook DENIES at a 100 s deadline (Claude Code's
# 2-minute countdown is the hard cap, so the deadline cannot grow under load).
# The request was pasted only inside the compose_emit body, AFTER that body's
# full-state, prelude and compose_report renders — each bounded at 20 s + 2 s
# per window — so under load it arrived with ~55 s left and timed out.
#
# THE FIX, and what this suite pins:
#   (A) render_urgent_decisions (_idle_probe.sh) renders ONLY the open
#       dangerous-rm requests — no tombstoned, expired, resolved or dead-window
#       row, no other decision kind — with no pane probe, and is a no-op once
#       the hook's `.urgent` stamp is old or absent. Its block is the same one
#       render_pending_decisions emits (one shared renderer).
#   (B) _v2_task_decision_surface (main.sh) pastes a MINIMAL emit carrying the
#       request — no workspace prelude, no snapshot, zero pane probes — once
#       per request; a failed paste is retried, a held target is not pasted
#       (and nothing is recorded, so the paste follows the lift), an rc-4
#       paste is never re-pasted (#1539).
#   (C) main.sh registers it as its own async task at ≤ 10 s, so it never
#       waits on compose_emit's in-flight run.
#
# Run: bash monitor/watcher/test-urgent-decision-surface.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

# Population (your-org/nexus-code#803): the files whose bytes this verdict reads.
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$MAIN_SH" "$_test_dir/_idle_probe.sh"; }
gp_handle "$@"

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 77; }

PASS=0; FAIL=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-uds-XXXXXX") || exit 1
trap 'rm -rf "${WORK:?}"' EXIT

export STATE_DIR="$WORK/state"
DEC="$STATE_DIR/decisions"
mkdir -p "$DEC" "$WORK/bin"
# Live windows: wa, we, wb, wc, wd. `wz` is deliberately absent (dead window).
printf '#!/usr/bin/env bash\n[[ "$1" == list-windows ]] && printf "wa\\nwe\\nwb\\nwc\\nwd\\n"\nexit 0\n' > "$WORK/bin/tmux"
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
export MONITOR_PENDING_PANE_GATE=false

now=$(date +%s)
# drm <window> <fp> <deadline-offset> [extra-jq] — a forwarded request file.
drm() {
    jq -n --arg w "$1" --arg fp "$2" --argjson dl $(( now + $3 )) \
        '{kind:"dangerous_rm", window:$w, fingerprint:$fp, nonce:"00112233aabbccdd",
          command:"rm -rf \"$(printf %s /x/t)\"", cwd:"/work/synthetic",
          classifier:"Dangerous rm operation on statically-unresolvable target",
          deadline_epoch:$dl, prompt_excerpt:"dangerous rm awaiting an orchestrator decision", unresolved:true}' \
        | jq "${4:-.}" > "$DEC/$1.$2.json"
}
drm wa aaaaaaaaaaaa 80                                   # OPEN — the one row
drm wb bbbbbbbbbbbb 80                                   # tombstoned sibling
printf '{}' > "$DEC/wb.bbbbbbbbbbbb.handled.json"
drm wc cccccccccccc -1                                   # past its deadline
drm wd dddddddddddd 80 '.resolved = true'                # resolved
drm wz ffffffffffff 80                                   # dead window
jq -n '{kind:"permission_prompt", window:"we", fingerprint:"eeeeeeeeeeee", prompt_excerpt:"Claude needs your permission"}' \
    > "$DEC/we.eeeeeeeeeeee.json"                        # another kind
printf '%s wa.aaaaaaaaaaaa\n' "$now" > "$DEC/.urgent"

# shellcheck source=_idle_probe.sh
. "$_test_dir/_idle_probe.sh" >/dev/null 2>&1
declare -F render_urgent_decisions >/dev/null 2>&1 \
    || printf '  NOTE: render_urgent_decisions is not defined — every (A)/(B) row below will fail\n' >&2

headers() { sed -n 's/^window=\([^ ]*\) fp=\([^ ]*\) kind=\([^ ]*\).*/\1 \2 \3/p' <<<"$1" | tr '\n' ';'; }

echo '=== (A) render_urgent_decisions: only OPEN dangerous-rm requests ==='
u=$(render_urgent_decisions 2>/dev/null)
assert_eq       "A1 exactly one row, the open request (no tombstoned/expired/resolved/dead/other-kind)" \
                "$(headers "$u")" "wa aaaaaaaaaaaa dangerous_rm;"
assert_contains "A2 the row carries the exact answer verb, nonce included" "$u" \
                "answer=ng decision-answer wa aaaaaaaaaaaa allow|deny --nonce 00112233aabbccdd"
assert_contains "A3 and the seconds left before the hook denies" "$u" "s  (then the worker hook DENIES)"
assert_contains "A4 and the file to read" "$u" "file=$DEC/wa.aaaaaaaaaaaa.json"
# Parity: the same block render_pending_decisions puts in the compose body
# (deadline-in dropped — the two renders may straddle a second).
p=$(render_pending_decisions 2>/dev/null)
blk_p=$(awk '/^window=wa fp=aaaaaaaaaaaa kind=dangerous_rm/{on=1} on&&/^window=/&&!/fp=aaaaaaaaaaaa/{on=0} on' <<<"$p" | grep -v 'deadline-in=')
blk_u=$(grep -v 'deadline-in=' <<<"$u")
assert_eq       "A5 one shared renderer: the fast-path block equals the compose-body block" "$blk_u" "$blk_p"
touch -d '-20 minutes' "$DEC/.urgent"
assert_eq       "A6 stale .urgent stamp → no render at all (the 5 s fire is a stat)" \
                "$(render_urgent_decisions 2>/dev/null | wc -c | tr -d ' ')|$(declare -F render_urgent_decisions >/dev/null && echo def)" "0|def"
rm -f "$DEC/.urgent"
assert_eq       "A7 no .urgent stamp → no render" \
                "$(render_urgent_decisions 2>/dev/null | wc -c | tr -d ' ')|$(declare -F render_urgent_decisions >/dev/null && echo def)" "0|def"
printf '%s x\n' "$now" > "$DEC/.urgent"

echo '=== (B) _v2_task_decision_surface: a minimal, sweep-free paste ==='
_extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }
eval "$(_extract_fn "$MAIN_SH" _decision_surface_record)"
eval "$(_extract_fn "$MAIN_SH" _v2_task_decision_surface)"
TARGET=orchestrator
tmp_dir="$WORK/tmp"; mkdir -p "$tmp_dir"
log() { :; }
_ensure_watcher_tmp_dir() { mkdir -p "$tmp_dir"; }
ARCH="$WORK/archive.log"; : > "$ARCH"
archive_emit() { printf '%s\n' "${2:-}" >> "$ARCH"; printf '%s/archive-fake.md\n' "$WORK"; }
PASTES="$WORK/pastes"; mkdir -p "$PASTES"
PASTE_RC=0
paste_with_retry() { local n; n=$(find "$PASTES" -type f | wc -l); cp "$2" "$PASTES/p$(( n + 1 ))"; return "$PASTE_RC"; }
npastes() { find "$PASTES" -type f | wc -l | tr -d ' '; }
HELD=1
_over_limit_orchestrator_paused() { (( HELD == 0 )); }
_auth_hold_active() { return 1; }
_api_hold_active() { return 1; }   # your-org/nexus-code#1845: the fourth hold arm
OK=0; BAD=0
_emit_delivery_ok()   { OK=$(( OK + 1 )); }
_emit_delivery_fail() { BAD=$(( BAD + 1 )); }
# Canaries: the fast path must NEVER probe a pane or render the workspace.
PROBES="$WORK/probes.log"
_idle_pane_state_line()       { echo probe >> "$PROBES"; printf 'state=idle active=0\n'; }
render_idle_prelude()         { echo prelude >> "$PROBES"; printf '0 busy\n'; }
render_full_state_snapshot()  { echo snapshot >> "$PROBES"; }
_compose_emit_record_emit()   { echo ring >> "$PROBES"; }

_v2_task_decision_surface
b1=$(cat "$PASTES/p1" 2>/dev/null)
assert_eq       "B1 one paste" "$(npastes)" "1"
assert_contains "B2 standard header, reason urgent-decision" "$b1" "=== nexus state changed at"
assert_contains "B3 reason tag" "$b1" "(urgent-decision) ==="
assert_contains "B4 the pending-decisions section" "$b1" "--- pending decisions ---"
assert_eq       "B5 carrying exactly the open request" "$(headers "$b1")" "wa aaaaaaaaaaaa dangerous_rm;"
assert_contains "B6 sig trailer (paste verification)" "$b1" "--- nexus-emit-sig "
assert_eq       "B7 no workspace prelude / snapshot section in the body" \
                "$(grep -cE '^workspace:|--- workspace snapshot ---' <<<"${b1:-workspace:}")" "0"
assert_eq       "B8 zero pane probes, zero renders, no dedup-ring entry" "$(cat "$PROBES" 2>/dev/null)" ""
assert_eq       "B9 delivery-ok accounted, archived once" "$OK|$(grep -c urgent-decision "$ARCH")" "1|1"

_v2_task_decision_surface
assert_eq       "B10 the same request is fast-pasted ONCE (still 1 paste)" "$(npastes)|$OK" "1|1"

drm we 111111111111 80
_v2_task_decision_surface
assert_eq       "B11 a NEW request pastes, carrying only itself" \
                "$(npastes)|$(headers "$(cat "$PASTES/p2" 2>/dev/null)")" "2|we 111111111111 dangerous_rm;"

drm wa 222222222222 80
PASTE_RC=1
_v2_task_decision_surface
PASTE_RC=0
_v2_task_decision_surface
assert_eq       "B12 a failed paste is retried on the next fire (fail counted)" \
                "$(npastes)|$BAD|$(headers "$(cat "$PASTES/p4" 2>/dev/null)")" "4|1|wa 222222222222 dangerous_rm;"

drm wa 333333333333 80
HELD=0
_v2_task_decision_surface
assert_eq       "B13 a HELD target: no paste, no archive" "$(npastes)|$(grep -c urgent-decision "$ARCH")" "4|4"
HELD=1
_v2_task_decision_surface
assert_eq       "B14 and the paste follows the lift" \
                "$(npastes)|$(headers "$(cat "$PASTES/p5" 2>/dev/null)")" "5|wa 333333333333 dangerous_rm;"

drm wa 444444444444 80
PASTE_RC=4
_v2_task_decision_surface
PASTE_RC=0
_v2_task_decision_surface
assert_eq       "B15 rc 4 (the Enter went out, #1539) is never re-pasted" "$(npastes)" "6"

rm -f "$DEC"/*.json
_v2_task_decision_surface
assert_eq       "B16 all requests closed → the surfaced record is cleared" \
                "$( [[ -e "$STATE_DIR/urgent-decisions-surfaced.tsv" ]] && echo present || echo gone)|$(npastes)" "gone|6"

echo '=== (C) registration: its own async task, at most 10 s ==='
reg=$(sed -E 's/[[:space:]]+/ /g' "$MAIN_SH" | grep -E '^ ?_schedule_task decision_surface ' || true)
assert_contains "C1 registered, async" "$reg" "_v2_task_decision_surface --class medium --async"
ival=$(awk '{print $3}' <<<"$reg")
assert_eq       "C2 cadence ≤ 10 s" "$( [[ "$ival" =~ ^[0-9]+$ ]] && (( ival <= 10 )) && echo ok || echo "bad:${ival}")" "ok"

# ASSERTION CENSUS: a row that stops running is a red, not a smaller green.
# A 7 + B 16 + C 2 = 25.
_EXPECTED_ASSERTIONS=25
assert_eq "assertion count reconciles ($_EXPECTED_ASSERTIONS)" "$(( PASS + FAIL ))" "$_EXPECTED_ASSERTIONS"

th_summary_and_exit
