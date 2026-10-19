#!/usr/bin/env bash
# test-skeptic-resolve-scoped.sh — a resolve settles the review it NAMES, and a
# declined request does not discharge a live review (your-org/nexus-code#1848).
#
# THE DEFECT. `skeptic-channel.sh resolve <target>` settled EVERY live edge
# naming the target as creditor, cleared the target's marker, closed its ledger
# and released its await. Measured 2026-10-16: a worker had two skeptics,
# `gate-sk` (proj-x #275) and later `alerts-sk` (#276). Resolving after gate-sk's
# verdict credited alerts-sk's edge before alerts-sk had a verdict. And
# `ng request reply --status declined` on a duplicate spawn request discharged
# a skeptic that was still reviewing (ncbundle29).
#
# WHY THE INCIDENT HAD ONE LIVE EDGE, NOT TWO. Edges superseded by TIME
# (`_obligations.sh`, release 1): a LATER edge from a DIFFERENT reviewer to the
# same creditor voided the earlier one, so alerts-sk's later edge had voided
# gate-sk's and the live set was {alerts-sk} — the OTHER reviewer. #1849 fixed
# that rule (a later edge supersedes only on a HANDOVER), so part A now rebuilds
# the incident shape and finds BOTH live, and part A2 is the control that a real
# handover still frees the earlier reviewer. Part B keeps the same-second tie,
# which was the only two-live shape before #1849.
#
# HERMETIC: NEXUS_STATE_DIR is a scratch dir; OBL_TMUX_WINDOWS is
# obligations.sh's own seam for "which windows are live", so no tmux server.
#
# Run: bash monitor/watcher/test-skeptic-resolve-scoped.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
NG="$REPO_ROOT/monitor/ng"
SC="$REPO_ROOT/monitor/skeptic-channel.sh"
RC="$REPO_ROOT/monitor/request-channel.sh"
OBLIG="$REPO_ROOT/monitor/obligations.sh"
for _x in "$NG" "$SC" "$RC" "$OBLIG"; do [[ -x "$_x" ]] || th_abort "not executable: $_x"; done

. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$SC" "$RC" "$OBLIG" "$REPO_ROOT/monitor/_obligations.sh"
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-resolve-scoped-XXXXXX)
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

# The live-window set ACCUMULATES across fixtures: replacing it would make an
# earlier fixture's windows read as gone (void-creditor-absent).
LIVE_WINDOWS=()
live() { LIVE_WINDOWS+=("$@"); LIVE=("OBL_TMUX_WINDOWS=$(printf '%s\n' "${LIVE_WINDOWS[@]}")"); }
target() {   # target <t> — a marker, an empty ledger, a channel
    "$SC" init "$1" >/dev/null
    printf '2' > "$PEND/$1"
    : > "$PEND/.$1.ledger"
    live "$1"
}
open_edge() {   # open_edge <reviewer> <target> [<opened-at epoch>]
    # `--at` is obligations.sh's own replay seam: supersession is an ORDERING
    # question, so the order is stated, not raced against the wall clock (a
    # first cut slept to the next second and, under load, also retried for a
    # same-second tie — and the tie arm then SKIPPED on a loaded host).
    "$OBLIG" open --debtor "$1" --creditor "$2" --kind skeptic-verdict --by fixture ${3:+--at "$3"} >/dev/null 2>&1 \
        || th_abort "fixture: could not open the $1 -> $2 edge"
    live "$1"
}
T0=$(( $(date +%s) - 3600 ))
edge() { env "${LIVE[@]}" "$OBLIG" state "$1__$2__skeptic-verdict" 2>/dev/null | sed -n 's/.* \(state=[a-z-]*\) .*/\1/p'; }
res() {   # res <target> <args…> — rc on stdout; stdout/stderr in $WORK/out, $WORK/err
    local t="$1"; shift; local rc=0
    env "${LIVE[@]}" "$SC" resolve "$t" "$@" >"$WORK/out" 2>"$WORK/err" || rc=$?
    printf '%s' "$rc"
}
released() { [[ -e "$STATE/skeptic/$1/RELEASED" ]] && echo released || echo not-released; }
marker()   { [[ -e "$PEND/$1" ]] && echo marker || echo no-marker; }
ledger_resolved() { grep -c '^resolved' "$PEND/.$1.ledger" 2>/dev/null || true; }
GATE_REASON="gate-sk verdict on proj-x PR 275 is credible (the incident's own reason)"
# THE READER THE NEXT WRAP-UP CONSULTS (ng:_wrapup_skeptic_step), plucked from
# ng itself rather than re-stated: a `none` answer is "this gate was not
# resolved, so a wrap-up ARMS"; `resolved` is "#815: ALREADY RESOLVED — NOT
# RE-ARMING". F1 (ncbundle30-sk) is the partial path answering `resolved`.
eval "$(awk '/^_skeptic_resolution_state\(\) \{/,/^}/' "$NG")"
declare -F _skeptic_resolution_state >/dev/null || th_abort "could not pluck _skeptic_resolution_state from $NG"
rstate() { _skeptic_resolution_state "$PEND" "$1" "$1" | awk '{print $1}'; }

# ═══ A. THE INCIDENT SHAPE: gate-sk, then alerts-sk a minute later ══════════
# Since your-org/nexus-code#1849 a later edge voids an earlier one only on a
# HANDOVER, so the incident shape — gate-sk still mid-review when alerts-sk is
# pinned — leaves BOTH live. That is the fix #1848 could not make: naming
# gate-sk now settles gate-sk's own edge instead of being refused.
target pipe
open_edge gate-sk pipe "$T0"
open_edge alerts-sk pipe $(( T0 + 60 ))
assert_eq "#1849: gate-sk's edge is STILL LIVE beside alerts-sk's later one" "$(edge gate-sk pipe)" "state=live"
assert_eq "…and so is alerts-sk's" "$(edge alerts-sk pipe)" "state=live"
assert_eq "INCIDENT: resolve pipe citing gate-sk, no --reviewer: REFUSED (rc 9)" "$(res pipe --reason "$GATE_REASON")" "9"
assert_contains "…printing the exact command for gate-sk" "$(cat "$WORK/err")" "ng skeptic resolve pipe --reviewer gate-sk --reason"
assert_contains "…and for alerts-sk" "$(cat "$WORK/err")" "ng skeptic resolve pipe --reviewer alerts-sk --reason"
assert_eq "…the marker is untouched" "$(marker pipe)" "marker"
assert_eq "…no await was released" "$(released pipe)" "not-released"
assert_no_file "…and nothing went on the audit trail" "$PEND/.pipe.cleared-rationale"
assert_eq "INCIDENT: resolve pipe --reviewer gate-sk: rc 0" "$(res pipe --reviewer gate-sk --reason "$GATE_REASON")" "0"
assert_eq "…gate-sk's edge is SETTLED" "$(edge gate-sk pipe)" "state=settled"
assert_eq "…alerts-sk's edge is STILL LIVE (the incident settled it)" "$(edge alerts-sk pipe)" "state=live"
assert_eq "…the marker is LEFT for alerts-sk" "$(marker pipe)" "marker"
assert_eq "…no await was released" "$(released pipe)" "not-released"
assert_eq "resolve pipe --reviewer alerts-sk (its own verdict landed): rc 0" "$(res pipe --reviewer alerts-sk --reason "alerts-sk verdict on proj-x PR 276 is credible")" "0"
assert_eq "…alerts-sk's edge is SETTLED" "$(edge alerts-sk pipe)" "state=settled"
assert_eq "…and, as the last live review, the whole gate: marker cleared" "$(marker pipe)" "no-marker"
assert_eq "…await released" "$(released pipe)" "released"
assert_eq "…ledger closed" "$(ledger_resolved pipe)" "1"

# ═══ A2. CONTROL: a genuine HANDOVER still frees the earlier reviewer ════════
# The `sk900` accumulation case the supersession rule exists for: the earlier
# reviewer DELIVERED, and only then was a new one pinned. Without this the
# #1849 fix could be "never supersede", which bricks every retained reviewer.
target hand
open_edge old-sk hand "$T0"
OBL_NOW_OVERRIDE=$(( T0 + 30 )) "$OBLIG" note --debtor old-sk --verdict --text "round 1 verdict filed" >/dev/null 2>&1 \
    || th_abort "fixture: could not record old-sk's verdict"
open_edge new-sk hand $(( T0 + 60 ))
assert_eq "A2 CONTROL: a reviewer pinned AFTER old-sk delivered supersedes it" "$(edge old-sk hand)" "state=void-superseded"
assert_eq "A2 …and the new one is live" "$(edge new-sk hand)" "state=live"

# ═══ B. TWO LIVE AT ONCE (a same-second tie): --reviewer settles ONE ═════════
# A same-second tie is the only way two reviewers are live together
# (`_obligations.sh` release 1 supersedes only on a STRICTLY later edge).
_tie=tie
target "$_tie"
open_edge a-sk "$_tie" "$T0"; open_edge b-sk "$_tie" "$T0"
if true; then
    assert_eq "B CONTROL: two live reviewers on one target ($_tie)" "$(edge a-sk "$_tie"):$(edge b-sk "$_tie")" "state=live:state=live"
    assert_eq "B no --reviewer: REFUSED (rc 9)" "$(res "$_tie" --reason "the a-sk verdict covers PR 275 only")" "9"
    assert_contains "…one exact command per live reviewer (a-sk)" "$(cat "$WORK/err")" "--reviewer a-sk --reason"
    assert_contains "…one exact command per live reviewer (b-sk)" "$(cat "$WORK/err")" "--reviewer b-sk --reason"
    assert_eq "B --reviewer a-sk with a whole-gate flag while b-sk is live: refused (rc 1)" \
        "$(res "$_tie" --reviewer a-sk --reason "the a-sk verdict covers PR 275 only" --delta-owed "a delta review must still cover the F1 fix")" "1"
    assert_eq "…a-sk's edge is still live after that refusal" "$(edge a-sk "$_tie")" "state=live"
    assert_eq "B --reviewer a-sk: rc 0" "$(res "$_tie" --reviewer a-sk --reason "the a-sk verdict covers PR 275 only")" "0"
    assert_eq "…a-sk's edge is SETTLED" "$(edge a-sk "$_tie")" "state=settled"
    assert_eq "…b-sk's edge is STILL LIVE" "$(edge b-sk "$_tie")" "state=live"
    assert_eq "…the marker is LEFT for b-sk" "$(marker "$_tie")" "marker"
    assert_eq "…the await is NOT released" "$(released "$_tie")" "not-released"
    assert_eq "…the ledger is NOT closed" "$(ledger_resolved "$_tie")" "0"
    assert_contains "…the output names what was left live" "$(cat "$WORK/out")" "still LIVE and untouched: b-sk"
    # F1 (ncbundle30-sk, your-org/nexus-code#1852): the partial path wrote the
    # whole-gate `.cleared-rationale`, so the next wrap-up read the gate as
    # RESOLVED and would not re-arm while b-sk's review was still owed.
    assert_no_file "F1 …and the gate's resolution record is NOT written while b-sk is live" "$PEND/.$_tie.cleared-rationale"
    assert_eq "F1 …so the reader the next wrap-up consults answers 'none': a re-wrap-up RE-ARMS" "$(rstate "$_tie")" "none"
    assert_file_exists "F1 …the partial resolve's audit goes to its own file" "$PEND/.$_tie.reviewer-resolutions"
    assert_eq "F1 the LAST reviewer's resolve: rc 0" "$(res "$_tie" --reviewer b-sk --reason "the b-sk verdict covers PR 276, the last review")" "0"
    # The resolution RECORD, not the reader's verdict: with the marker now gone
    # the reader calls `_skeptic_last_chain_event_epoch` (the action log), which
    # this hermetic fixture does not carry, so it would answer `unknown`. The
    # partial-path assertion above is sound because that arm returns `none`
    # before reaching the helper.
    assert_file_exists "F1 …NOW the gate's resolution record is written (the last live edge settled)" "$PEND/.$_tie.cleared-rationale"
fi

# ═══ C. --all-reviewers: the old behaviour, deliberately ═════════════════════
target allr; open_edge c-sk allr
assert_eq "C resolve allr --all-reviewers: rc 0" "$(res allr --all-reviewers --reason "every review of this target is abandoned on purpose")" "0"
assert_eq "…the edge is settled" "$(edge c-sk allr)" "state=settled"
assert_eq "…the marker is cleared" "$(marker allr)" "no-marker"

# ═══ D. the default CHANGED: one live reviewer now needs --reviewer ══════════
target one; open_edge d-sk one
assert_eq "D resolve one (a single live reviewer, no flag): REFUSED (rc 9) since #1848" "$(res one --reason "the d-sk verdict on this round is credible")" "9"
assert_eq "…its edge is still live" "$(edge d-sk one)" "state=live"
assert_eq "D resolve one --reviewer d-sk: rc 0" "$(res one --reviewer d-sk --reason "the d-sk verdict on this round is credible")" "0"
assert_eq "…its edge is settled" "$(edge d-sk one)" "state=settled"

# ═══ E. MUST-NOT-FLIP: no live edge, the marker-only resolve is unchanged ════
target bare
assert_eq "E resolve bare (marker, NO edge, no flag): rc 0, as before #1848" "$(res bare --reason "the verdict landed in a secondary clone's state dir")" "0"
assert_eq "…the marker is cleared" "$(marker bare)" "no-marker"

# ═══ F. --refuse-live-reviewer refuses on ANY live reviewer ══════════════════
target rl; open_edge f-sk rl
assert_eq "F resolve rl --refuse-live-reviewer --all-reviewers: REFUSED (rc 9)" "$(res rl --refuse-live-reviewer --all-reviewers --reason "declining a duplicate spawn request here")" "9"
assert_eq "…its edge is still live" "$(edge f-sk rl)" "state=live"

# ═══ G. the DECLINE path: a declined duplicate request keeps the live review ═
_mkreq() {
    local id
    id=$(bash "$RC" file --origin "$1" --kind spawn-skeptic --slug "dup-$1" \
            --reply required --message "fixture: a duplicate spawn request for $1" 2>/dev/null) || return 1
    mv "$STATE/requests/$id.new.md" "$STATE/requests/$id.claimed.md" || return 1
    sed -i 's/^state: new/state: claimed/' "$STATE/requests/$id.claimed.md" || return 1
    printf '%s' "$id"
}
_reply() { local rc=0; env "${LIVE[@]}" bash "$RC" reply "$@" --no-publish >"$WORK/out" 2>"$WORK/err" || rc=$?; printf '%s' "$rc"; }
MSG="duplicate request: the live reviewer already covers this round"
target dec; open_edge live-sk dec
_id=$(_mkreq dec) || th_abort "fixture: could not file+claim the spawn-skeptic request"
assert_eq "G declined while live-sk owes a verdict: REFUSED (6) — the ncbundle29 case" "$(_reply "$_id" --status declined --message "$MSG")" "6"
assert_eq "…live-sk's edge is still live" "$(edge live-sk dec)" "state=live"
assert_eq "…the marker is untouched" "$(marker dec)" "marker"
assert_eq "…no await was released" "$(released dec)" "not-released"
assert_eq "G the covered remedy (--status spawned --worker live-sk): rc 0" "$(_reply "$_id" --status spawned --worker live-sk --message "$MSG")" "0"
assert_eq "…and live-sk's edge is STILL live: its verdict discharges the gate" "$(edge live-sk dec)" "state=live"
target dec2; open_edge gone-sk dec2
_id=$(_mkreq dec2) || th_abort "fixture: could not file+claim the second request"
assert_eq "G declined --settle-live-reviewer (abandoned on purpose): rc 0" \
    "$(_reply "$_id" --status declined --settle-live-reviewer --message "the live review is abandoned: its window crashed and will not return")" "0"
assert_eq "…and that edge is settled" "$(edge gone-sk dec2)" "state=settled"

# ═══ H. F2 (ncbundle30-sk): an edge read that does not answer fails CLOSED ═══
# A 0.01 s bound on the real ledger read makes it time out (rc 124). Measured
# before the fix: rc 0, the live edge SETTLED, the marker removed, RELEASED
# written — the incident's act, on the decline path's own flag.
SLOW=(SKEPTIC_RESOLVE_DISPOSITION_TIMEOUT=0.01)
target slow; open_edge s-sk slow
res_slow() { local t="$1"; shift; local rc=0; env "${LIVE[@]}" "${SLOW[@]}" "$SC" resolve "$t" "$@" >"$WORK/out" 2>"$WORK/err" || rc=$?; printf '%s' "$rc"; }
assert_eq "H decline flag (--refuse-live-reviewer) with the ledger read timing out: REFUSED (rc 8)" "$(res_slow slow --refuse-live-reviewer --reason "declining a duplicate spawn request for slow")" "8"
assert_contains "…saying the live state CANNOT BE DETERMINED" "$(cat "$WORK/err")" "CANNOT BE DETERMINED"
assert_eq "…the live edge is NOT touched" "$(edge s-sk slow)" "state=live"
assert_eq "…the marker is NOT removed" "$(marker slow)" "marker"
assert_eq "…no await is released" "$(released slow)" "not-released"
assert_no_file "…and no resolution record is written" "$PEND/.slow.cleared-rationale"
assert_eq "H --reviewer with the ledger read timing out: also REFUSED (rc 8)" "$(res_slow slow --reviewer s-sk --reason "the s-sk verdict on this round is credible")" "8"
assert_eq "…the edge is still live" "$(edge s-sk slow)" "state=live"
# Its OWN target, so a mutant that wrongly settled s-sk above cannot flip it by
# shared state: this case must answer only "does an ANSWERING read still work".
target fastok; open_edge v-sk fastok
assert_eq "H MUST-NOT-FLIP: a ledger that ANSWERS: --reviewer v-sk settles it (rc 0)" "$(res fastok --reviewer v-sk --reason "the v-sk verdict on this round is credible")" "0"
assert_eq "…settled" "$(edge v-sk fastok)" "state=settled"
target slowall; open_edge t-sk slowall
assert_eq "H the documented exception: --all-reviewers proceeds with the read timing out (rc 0)" "$(res_slow slowall --all-reviewers --reason "every review of slowall is abandoned on purpose")" "0"
target slowdec; open_edge u-sk slowdec
_id=$(_mkreq slowdec) || th_abort "fixture: could not file+claim the slowdec request"
_rc=0; env "${LIVE[@]}" "${SLOW[@]}" bash "$RC" reply "$_id" --status declined --message "$MSG" --no-publish >"$WORK/out" 2>"$WORK/err" || _rc=$?
assert_eq "H the DECLINE path with the ledger read timing out: refused (6)" "$_rc" "6"
assert_contains "…naming ONE remedy, the same command again (no #1771 ping-pong)" "$(cat "$WORK/err")" "Re-run THIS SAME command"
assert_not_contains "…and NOT sending the caller to --skeptic-resolved" "$(cat "$WORK/err")" "re-run with --skeptic-resolved"
assert_eq "…u-sk's edge is still live" "$(edge u-sk slowdec)" "state=live"

EXPECTED=72   # +3: #1849 part A (both live; --reviewer gate-sk settles only its own edge) and the A2 handover control
if (( PASS + FAIL + SKIP != EXPECTED )); then
    printf '  FAIL: assertion census %d != EXPECTED %d — an assertion did not run, or one was added without updating EXPECTED\n' \
        "$(( PASS + FAIL + SKIP ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
