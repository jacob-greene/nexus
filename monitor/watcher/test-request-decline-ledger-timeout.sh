#!/usr/bin/env bash
# test-request-decline-ledger-timeout.sh — a spawn-skeptic DECLINE must have a
# working path when the obligation ledger is slow (your-org/nexus-code#1771).
#
# THE DEFECT. `ng request reply <id> --status declined` on a spawn-skeptic
# request whose gate is already discharged:
#   · without --skeptic-resolved, `resolve` finds nothing to discharge and the
#     reply says "re-run with --skeptic-resolved";
#   · with it, `release` could not read the ledger (rc 124, a timeout), folded
#     that into its "review is pending" rc 7, and the reply said "drop
#     --skeptic-resolved".
# Two refusals, each naming the other as the remedy.
#
# THE FIX THIS PINS. `release` retries a TIMED-OUT read a bounded number of
# times (SKEPTIC_RELEASE_PROBE_TIMEOUTS, one timeout per attempt) and, if the
# doubt survives, exits 8 (could not determine) rather than 7 (pending). The
# reply maps 8 to a terminal refusal naming ONE remedy (the same command again),
# never the other verb. The fail-closed intent of #1537's release check stands:
# a probe that cannot answer is still a refusal, and a POSITIVELY pending review
# is still rc 7 with its old message (the MUST-NOT-FLIP arm).
#
# THE TIMEOUT IS REAL, NOT STUBBED: a 0.001s bound on the real `ng` and the real
# `obligations.sh` (both bash scripts that cannot start in 1 ms), so the rc is
# `timeout`'s own 124. Both knobs are set: SKEPTIC_RESOLVE_DISPOSITION_TIMEOUT
# is the one the pre-fix `release` honoured for `ng skeptic-obligations`, which
# is what lets this suite reproduce the ping-pong on the unfixed tree.
#
# HERMETIC: NEXUS_STATE_DIR is a scratch dir; nothing touches a live channel.
#
# Run: bash monitor/watcher/test-request-decline-ledger-timeout.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
NG="$REPO_ROOT/monitor/ng"
SC="$REPO_ROOT/monitor/skeptic-channel.sh"
RC="$REPO_ROOT/monitor/request-channel.sh"
OBLIG="$REPO_ROOT/monitor/obligations.sh"

[[ -x "$NG" ]]    || th_abort "monitor/ng not executable at $NG"
[[ -x "$SC" ]]    || th_abort "monitor/skeptic-channel.sh not executable at $SC"
[[ -x "$RC" ]]    || th_abort "monitor/request-channel.sh not executable at $RC"
[[ -x "$OBLIG" ]] || th_abort "monitor/obligations.sh not executable at $OBLIG"

. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$SC" "$RC" "$OBLIG" "$REPO_ROOT/monitor/_obligations.sh"
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-decline-to-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/.state"
PEND="$STATE/skeptic/pending"
mkdir -p "$PEND" "$WORK/reports"
export NEXUS_STATE_DIR="$STATE" NEXUS_ROOT="$WORK"
unset NEXUS_WORKER_WINDOW NEXUS_LOCALS SKEPTIC_RELEASE_PROBE_TIMEOUTS SKEPTIC_RESOLVE_DISPOSITION_TIMEOUT
th_pin_ng_state "$NG" "$STATE"

case "$("$SC" dir pin-probe 2>/dev/null)" in
    "$STATE"/*) : ;;
    *) th_abort "skeptic-channel.sh did not resolve its state dir under the fixture ($STATE) — refusing to run against a live channel" ;;
esac

_mkreq() {   # _mkreq <origin> → a CLAIMED spawn-skeptic request id
    local id
    id=$(bash "$RC" file --origin "$1" --kind spawn-skeptic --slug "d2-$1" \
            --reply required --message "fixture: depth-2 review of $1" 2>/dev/null) || return 1
    mv "$STATE/requests/$id.new.md" "$STATE/requests/$id.claimed.md" || return 1
    sed -i 's/^state: new/state: claimed/' "$STATE/requests/$id.claimed.md" || return 1
    printf '%s' "$id"
}
_state_of() { local f; for f in "$STATE/requests/$1".*.md; do [[ -e "$f" ]] && { f=${f%.md}; printf '%s' "${f##*.}"; return; }; done; printf absent; }
# _reply [VAR=val …] -- <reply args…> — rc on stdout, stderr in $WORK/err.
_reply() {
    local -a envs=(); while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
    local rc=0
    env "${envs[@]}" bash "$RC" reply "$@" --no-publish >"$WORK/out" 2>"$WORK/err" || rc=$?
    printf '%s' "$rc"
}
_rel() {     # _rel <task> [VAR=val …] — rc on stdout, stderr in $WORK/err
    local task="$1"; shift; local rc=0
    env "$@" "$SC" release "$task" --reason "asserting the gate is already discharged" >"$WORK/out" 2>"$WORK/err" || rc=$?
    printf '%s' "$rc"
}
SLOW=(SKEPTIC_RESOLVE_DISPOSITION_TIMEOUT=0.001 "SKEPTIC_RELEASE_PROBE_TIMEOUTS=0.001 0.001")
MSG="depth-2 declined: the depth-1 verdict is sufficient for this change"

# ═══ 0. POSITIVE CONTROL: an unloaded ledger releases a discharged gate ══════
"$SC" init ctl >/dev/null
assert_eq "CONTROL: release on a discharged gate, ledger answering: rc 0" "$(_rel ctl)" "0"
assert_file_exists "…writing RELEASED" "$STATE/skeptic/ctl/RELEASED"

# ═══ 1. release: a timed-out ledger is DOUBT (8), not PENDING (7) ════════════
"$SC" init slow >/dev/null
assert_eq "release with every ledger read timing out: rc 8 (could not determine), not 7" "$(_rel slow "${SLOW[@]}")" "8"
assert_contains "…the timed-out read was RETRIED (bounded)" "$(cat "$WORK/err")" "attempt 1 of 2"
assert_contains "…the refusal says it could not determine" "$(cat "$WORK/err")" "COULD NOT DETERMINE"
assert_no_file "…and nothing was released" "$STATE/skeptic/slow/RELEASED"

# ═══ 2. the reply: a terminal refusal naming ONE remedy, never the other verb ═
"$SC" init d2a >/dev/null
_id=$(_mkreq d2a) || th_abort "fixture: could not file+claim a spawn-skeptic request"
assert_eq "POSITIVE CONTROL: the request is claimed" "$(_state_of "$_id")" "claimed"
assert_eq "declined + --skeptic-resolved, ledger timing out: refused (6)" \
    "$(_reply "${SLOW[@]}" -- "$_id" --status declined --skeptic-resolved --message "$MSG")" "6"
assert_not_contains "…and it does NOT send the caller to drop --skeptic-resolved (the ping-pong)" \
    "$(cat "$WORK/err")" "Drop --skeptic-resolved"
assert_contains "…it names the one remedy: the same command again" "$(cat "$WORK/err")" "Re-run THIS SAME command"
assert_eq "…the request is left CLAIMED" "$(_state_of "$_id")" "claimed"
assert_no_file "…nothing was released" "$STATE/skeptic/d2a/RELEASED"

# ═══ 3. a read that times out ONCE completes the decline on the retry ════════
assert_eq "declined + --skeptic-resolved, first ledger read times out, second answers: rc 0" \
    "$(_reply "SKEPTIC_RELEASE_PROBE_TIMEOUTS=0.001 60" -- "$_id" --status declined --skeptic-resolved --message "$MSG")" "0"
assert_contains "…via a retry, not a lucky first read" "$(cat "$WORK/err")" "attempt 1 of 2"
assert_eq "…the request is REPLIED" "$(_state_of "$_id")" "replied"
assert_file_exists "…and the declined skeptic's channel is RELEASED" "$STATE/skeptic/d2a/RELEASED"

# ═══ 4. MUST-NOT-FLIP: a POSITIVELY pending review is still 7, not retried ═══
"$SC" init d2p >/dev/null; printf '2' > "$PEND/d2p"
assert_eq "release with a pending marker AND a slow ledger: still rc 7 (pending wins over doubt)" "$(_rel d2p "${SLOW[@]}")" "7"
assert_not_contains "…not retried: a positive answer is an answer" "$(cat "$WORK/err")" "retrying"
_id=$(_mkreq d2p) || th_abort "fixture: could not file+claim the pending request"
assert_eq "declined + --skeptic-resolved with a PENDING marker: refused (6)" \
    "$(_reply "${SLOW[@]}" -- "$_id" --status declined --skeptic-resolved --message "asserting discharged while it is in fact still pending")" "6"
assert_contains "…with the PENDING remedy (drop the flag, resolve decides)" "$(cat "$WORK/err")" "Drop --skeptic-resolved"
assert_eq "…the request is left CLAIMED" "$(_state_of "$_id")" "claimed"
assert_file_exists "…and the marker still gates retirement" "$PEND/d2p"

# ═══ 5. the schedule is validated, never silently defaulted ══════════════════
assert_eq "a malformed SKEPTIC_RELEASE_PROBE_TIMEOUTS is refused (rc 1)" \
    "$(_rel ctl "SKEPTIC_RELEASE_PROBE_TIMEOUTS=soon")" "1"
assert_contains "…naming the bad entry" "$(cat "$WORK/err")" "not a number of seconds"

# ═══ 6. a review pending ONLY via a live obligation EDGE: the remedy WORKS ════
# The residual of #1771 (after PR #1774). `release` reads a live creditor edge
# as PENDING (rc 7, "drop --skeptic-resolved"), while `resolve` did not read
# edges at all and answered "nothing to resolve … re-run with
# --skeptic-resolved". Here the refusal's remedy is FOLLOWED, and must land.
# OBL_TMUX_WINDOWS is obligations.sh's own seam for "which windows are in tmux",
# so the edge is `live` without a tmux server.
LIVE=("OBL_TMUX_WINDOWS=$(printf 'e1\ne1-sk')")
"$SC" init e1 >/dev/null
"$OBLIG" open --debtor e1-sk --creditor e1 --kind skeptic-verdict --by fixture >/dev/null 2>&1 \
    || th_abort "fixture: could not open the e1-sk -> e1 obligation edge"
assert_eq "POSITIVE CONTROL: the edge is live and is the ONLY thing pending (no marker)" \
    "$(env "${LIVE[@]}" "$OBLIG" state e1-sk__e1__skeptic-verdict 2>/dev/null | sed -n 's/.* \(state=[a-z-]*\) .*/\1/p'):$([[ -e "$PEND/e1" ]] && echo marker || echo nomarker)" \
    "state=live:nomarker"
_id=$(_mkreq e1) || th_abort "fixture: could not file+claim the edge-pending request"
assert_eq "declined + --skeptic-resolved on a live edge: refused (6)" \
    "$(_reply "${LIVE[@]}" -- "$_id" --status declined --skeptic-resolved --message "$MSG")" "6"
assert_contains "…naming ONE remedy: drop --skeptic-resolved" "$(cat "$WORK/err")" "Drop --skeptic-resolved"
# FOLLOWING that remedy (no flag) used to be accepted and SETTLED the live edge.
# Since your-org/nexus-code#1848 that is refused — a decline of the REQUEST must
# not discharge a review a live skeptic is still doing — and the refusal must
# not reopen #1771's ping-pong: it names two NEW remedies, neither of which is
# the flag the previous refusal told the caller to drop.
assert_eq "following that remedy (no flag) on a LIVE reviewer: refused (6) since #1848" \
    "$(_reply "${LIVE[@]}" -- "$_id" --status declined --message "$MSG")" "6"
assert_not_contains "…and does NOT send the caller back to --skeptic-resolved (the ping-pong)" \
    "$(cat "$WORK/err")" "re-run with --skeptic-resolved"
assert_contains "…it names the covered-by-the-live-review remedy" "$(cat "$WORK/err")" "--status spawned --worker <that live reviewer>"
assert_contains "…and the deliberate abandoning remedy" "$(cat "$WORK/err")" "--settle-live-reviewer"
assert_eq "…the request is left CLAIMED" "$(_state_of "$_id")" "claimed"
assert_contains "…and the live edge is NOT settled" \
    "$(env "${LIVE[@]}" "$OBLIG" state e1-sk__e1__skeptic-verdict 2>/dev/null)" "state=live"
assert_eq "the ABANDONING remedy (--settle-live-reviewer) is accepted: rc 0" \
    "$(_reply "${LIVE[@]}" -- "$_id" --status declined --settle-live-reviewer --message "$MSG")" "0"
assert_eq "…the request is REPLIED" "$(_state_of "$_id")" "replied"
assert_contains "…and the edge the decline declined is SETTLED" \
    "$(env "${LIVE[@]}" "$OBLIG" state e1-sk__e1__skeptic-verdict 2>/dev/null)" "state=settled"
assert_contains "…on the audit trail, naming the edge" "$(cat "$PEND/.e1.cleared-rationale" 2>/dev/null)" "live obligation edge(s) naming e1 as creditor (#1771): e1-sk"

# MUST-NOT-FLIP: with NO edge, no marker and nothing outstanding, `resolve`
# still refuses "nothing to resolve" — reading edges did not make it a reflex.
"$SC" init e2 >/dev/null
_rc=0; env "${LIVE[@]}" "$SC" resolve e2 --reason "nothing is pending here at all, by construction" >"$WORK/out" 2>"$WORK/err" || _rc=$?
assert_eq "resolve with no edge and no marker: still refused (1)" "$_rc" "1"
assert_contains "…as nothing to resolve" "$(cat "$WORK/err")" "nothing to resolve"

# ═══ 7. resolve reports the settle's REAL outcome (skeptic nit on PR #1781) ═══
# The success line said the live edges "are settled" whatever the best-effort
# settle returned. Fault: the edge's record is made read-only, so the settle's
# append fails while the edge stays readable (and live).
"$SC" init e3 >/dev/null
"$OBLIG" open --debtor e3-sk --creditor e3 --kind skeptic-verdict --by fixture >/dev/null 2>&1 \
    || th_abort "fixture: could not open the e3-sk -> e3 obligation edge"
LIVE3=("OBL_TMUX_WINDOWS=$(printf 'e3\ne3-sk')")
chmod 444 "$STATE/obligations/e3-sk__e3__skeptic-verdict.rec"
# `--reviewer e3-sk`: since your-org/nexus-code#1848 a resolve with a live edge
# must name the review it settles, or it is refused before the settle runs.
_rc=0; env "${LIVE3[@]}" "$SC" resolve e3 --reviewer e3-sk --reason "the depth-1 verdict on e3 covers this change in full" >"$WORK/out" 2>"$WORK/err" || _rc=$?
assert_not_contains "settle FAILED: resolve does NOT claim the edges are settled" "$(cat "$WORK/out")" "are settled"
assert_contains "…it says they are NOT settled and names the hand remedy" "$(cat "$WORK/out")" "NOT settled: the settle failed"
assert_contains "…and the ledger agrees: the edge is still open" \
    "$(env "${LIVE3[@]}" "$OBLIG" state e3-sk__e3__skeptic-verdict 2>/dev/null)" "state=live"
chmod 644 "$STATE/obligations/e3-sk__e3__skeptic-verdict.rec"

# THE ASSERTION TOTAL IS EXACT: an assertion that silently stops running (a
# section that aborted, a loop over an empty set) is a red, not a smaller green.
EXPECTED=42
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: assertion census %d != EXPECTED %d — an assertion did not run, or one was added without updating EXPECTED\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
