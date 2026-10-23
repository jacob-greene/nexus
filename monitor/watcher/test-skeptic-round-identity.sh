#!/usr/bin/env bash
# AN AWAIT MUST SAY WHY IT ENDED, AND A ROUND MUST BE OPENABLE WITHOUT A SPAWN
# (your-org/nexus-code#1537, #1538, and four failures measured 2026-09-17/18).
#
# Run: bash monitor/watcher/test-skeptic-round-identity.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ── THE DEFECT FAMILY ───────────────────────────────────────────────────────
#
# Three writers remove the skeptic-pending marker — a verdict wrap-up, `close`
# and `resolve` — and `await` mapped the first observable of ANY of them onto
# exit 10 or 11, whose legends both say "proceed to retire". So:
#
#   · a channel CLOSING read as a verdict ARRIVING (`promote`: exit 11 off a
#     DONE written by reconcile/close, ledger `standing_stale=1`);
#   · `ng skeptic-arm` re-armed the LEDGER without the MARKER the staleness
#     guard reads, so a correctly-armed second pass saw the previous round's
#     DONE at exit 10 (#1537, ~54 minutes on `proj-fig-a`);
#   · a retained skeptic re-tasked by `ng send` opened no round at all (#1538);
#   · a worker with nothing armed looped on exit 4 forever (`testinfra`);
#   · a declined depth-2 left the declined skeptic awaiting a reviewer that was
#     never coming (`promotesk`, `killsafesk`).
#
# ── THE DIRECTION EVERY ARM HERE PINS ───────────────────────────────────────
#
# These are gates on RETIREMENT and on a review being DONE. Each fix may only
# turn a "done" into a "not done". The MUST-NOT-FLIP controls below are the
# legacy shapes (no ledger, a real verdict) that have to keep their old codes.
#
# HERMETIC: `NEXUS_STATE_DIR` is a scratch dir. The live skeptic channel is in
# use by other workers while this runs; nothing here may touch it.

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

# DECLARED to the guards-for-diff index: these are the files whose edit must
# select this suite. It reads them by EXECUTING them, so the population is the
# execution surface, named rather than globbed.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$NG" "$SC" "$RC" "$OBLIG" \
        "$REPO_ROOT/monitor/_obligations.sh" \
        "$REPO_ROOT/monitor/spawn-worker.sh"
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-skround-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/.state"
PEND="$STATE/skeptic/pending"
mkdir -p "$PEND" "$WORK/reports"
export NEXUS_STATE_DIR="$STATE" NEXUS_ROOT="$WORK"
unset NEXUS_WORKER_WINDOW NEXUS_LOCALS
th_pin_ng_state "$NG" "$STATE"

# FAIL CLOSED IF THE PIN DID NOT TAKE: every path below must resolve under WORK.
case "$("$SC" dir pin-probe 2>/dev/null)" in
    "$STATE"/*) : ;;
    *) th_abort "skeptic-channel.sh did not resolve its state dir under the fixture ($STATE) — refusing to run against a live channel" ;;
esac

# _aw <task> [timeout] — run await, leave stdout in $WORK/out, stderr in
# $WORK/err, print the rc. The rc is read on the very next statement.
_aw() {
    local rc=0
    "$SC" await "$1" --timeout "${2:-1}" --interval 1 >"$WORK/out" 2>"$WORK/err" </dev/null || rc=$?
    printf '%s' "$rc"
}
_arm() {   # _arm <task> <body> → arms reports/<task>.md with that body
    printf '%s\n' "$2" > "$WORK/reports/$1.md"
    "$NG" skeptic-arm "$1" --report "$WORK/reports/$1.md" --state-dir "$STATE" >/dev/null 2>&1
}
_sha() { sha256sum < "$WORK/reports/$1.md" | awk '{print $1}'; }
_verdict() {   # a `discharged … attributed` row against the CURRENT bytes
    printf 'discharged\t%s\t%s\tcredible\t1537\t%ssk\tattributed\n' \
        "$(_sha "$1")" "$(date -Is)" "$1" >> "$PEND/.$1.ledger"
}
_field() { sed -n "s/.*[[:space:]]$2=\([^[:space:]][^[:space:]]*\).*/\1/p" <<<" $1"; }

# ═══ 0. MUST-NOT-FLIP: the legacy shapes keep their codes ════════════════════
"$SC" init legacy >/dev/null
"$SC" close legacy >/dev/null
assert_eq "CONTROL no ledger: a fresh close is still exit 10" "$(_aw legacy)" "10"
assert_eq "CONTROL …and stdout is still the bare DONE token" "$(sed -n 1p "$WORK/out")" "DONE"
assert_contains "…but a ledger-less 10 now says it is UNVERIFIED" "$(cat "$WORK/err")" "UNVERIFIED"

printf '1' > "$PEND/legacy11"
"$SC" init legacy11 >/dev/null
( sleep 2; rm -f "$PEND/legacy11" ) &
assert_eq "CONTROL no ledger: a marker that vanishes mid-wait is still exit 11" "$(_aw legacy11 6)" "11"
wait

# A REAL verdict followed by a close is the ordinary ending, and stays 10.
_arm real "round one"
_verdict real
"$SC" close real >/dev/null
assert_eq "CONTROL verdict recorded then close: exit 10" "$(_aw real)" "10"
assert_not_contains "…and it is NOT flagged unverified" "$(cat "$WORK/err")" "UNVERIFIED"

# ═══ 1. A CLOSED CHANNEL IS NOT A VERDICT (failure 3) ════════════════════════
_arm closed "never reviewed"
assert_file_exists "skeptic-arm wrote the pending marker (#1537)" "$PEND/closed"
( sleep 2; "$SC" close closed >/dev/null ) &
_rc=$(_aw closed 8); wait
assert_eq "close with NO verdict on the ledger, seen MID-WAIT: exit 14, not 11" "$_rc" "14"
assert_eq "…stdout token is ENDED-WITHOUT-VERDICT" "$(sed -n 1p "$WORK/out")" "ENDED-WITHOUT-VERDICT"
assert_contains "…and the cause is named as a close" "$(cat "$WORK/err")" "cause=close"
assert_eq "…re-entering gives the same answer (never a late 10)" "$(_aw closed)" "14"

# promote's exact ledger: verdict on sha A, re-armed with sha B, then closed.
_arm promote "bytes A"
_verdict promote
"$SC" close promote >/dev/null
_arm promote "bytes B"
_ev=$("$NG" skeptic-evidence promote --state-dir "$STATE" 2>/dev/null | sed -n 1p)
assert_eq "FIXTURE reproduces the measured ledger: standing_stale=1" "$(_field "$_ev" standing_stale)" "1"
"$SC" close promote >/dev/null
assert_eq "re-armed with a different sha, then closed: exit 14 (the standing verdict is about OTHER bytes)" \
    "$(_aw promote)" "14"

# ═══ 2. skeptic-arm OPENS THE ROUND (#1537) ══════════════════════════════════
_arm rearm "round one"
_verdict rearm
"$SC" close rearm >/dev/null
assert_no_file "close removed the marker (precondition)" "$PEND/rearm"
assert_file_exists "…and left a DONE (precondition)" "$STATE/skeptic/rearm/DONE"
_arm rearm "round two — amended"
assert_file_exists "a re-arm after close RESTORES the marker await's guard reads" "$PEND/rearm"
assert_no_file "…and archives the previous round's DONE" "$STATE/skeptic/rearm/DONE"
assert_eq "so the armed second pass WAITS (exit 4) instead of reading round one's DONE" "$(_aw rearm)" "4"
assert_contains "status shows the round open" "$("$SC" status rearm)" "done=0"
assert_contains "…with the marker field set" "$("$SC" status rearm)" "marker=1"

# rc 3 (already outstanding) must restore a MISSING marker and archive nothing.
rm -f "$PEND/rearm"
_rc=0; "$NG" skeptic-arm rearm --report "$WORK/reports/rearm.md" --state-dir "$STATE" >/dev/null 2>&1 || _rc=$?
assert_eq "re-arming the SAME outstanding bytes is still rc 3" "$_rc" "3"
assert_file_exists "…and it restores the missing marker" "$PEND/rearm"
# an existing marker's depth is another writer's choice and is never rewritten
printf '2' > "$PEND/depth2"; _arm depth2 "x"
assert_eq "an EXISTING marker's content is left alone" "$(cat "$PEND/depth2")" "2"

# ═══ 3. A DELIVERED DONE IS NOT NEWS (#1538) ═════════════════════════════════
_arm retained "pass one"
_verdict retained
"$SC" close retained >/dev/null
assert_eq "first await consumes the close: exit 10" "$(_aw retained)" "10"
assert_contains "status records the delivery" "$("$SC" status retained)" "done_delivered=1"
# the skeptic is RETAINED and re-tasked by `ng send`: nothing on disk changes.
assert_eq "re-tasked with no round opened: the SAME DONE is exit 15, not a second 10" "$(_aw retained)" "15"
assert_eq "…stdout token NO-ROUND-OPEN" "$(sed -n 1p "$WORK/out")" "NO-ROUND-OPEN"
assert_contains "…naming the verb that opens a round" "$(cat "$WORK/err")" "skeptic-arm"
# an open request still reaches the worker — 15 must not eat protocol traffic
printf 'q\n' > "$WORK/q.md"
"$SC" ask retained q --file "$WORK/q.md" >/dev/null 2>&1 || true
if compgen -G "$STATE/skeptic/retained/*.open.md" >/dev/null; then
    assert_eq "an OPEN request on a stale-DONE channel is still acked (exit 0)" "$(_aw retained)" "0"
else
    th_abort "fixture: could not file a request with \`ask\` — the ack-before-15 arm did not run"
fi
# a genuinely NEW close is news again
"$SC" close retained >/dev/null
assert_eq "a NEW close after the delivered one is exit 10 again" "$(_aw retained)" "10"

# ═══ 4. NOTHING ARMED: the wait ends loudly (failure 1) ══════════════════════
"$SC" init stranded >/dev/null
assert_eq "no marker, no arm, no sentinel: timeout is exit 15, not 'exit 4, re-enter'" "$(_aw stranded)" "15"
assert_contains "…and it says so at entry, not only at the timeout" "$(cat "$WORK/err")" "NO ROUND IS OPEN"
# MUST-NOT-FLIP: a marker means a round IS open, so the timeout stays 4.
printf '1' > "$PEND/parked"; "$SC" init parked >/dev/null
assert_eq "CONTROL marker present: timeout is still exit 4" "$(_aw parked)" "4"
# MUST-NOT-FLIP: an outstanding arm with a hand-removed marker is NOT 'no round'.
_arm armedonly "x"; rm -f "$PEND/armedonly"
assert_eq "CONTROL outstanding arm, marker gone: still exit 4 (doubt keeps waiting)" "$(_aw armedonly)" "4"

# ═══ 5. resolve RELEASES THE AWAIT, as a RESOLUTION (failure 2, #1537 shape 3)
_arm declined "a skeptic's own report, depth-2 declined"
"$SC" resolve declined --reason "depth-2 review declined: the depth-1 verdict stands" >/dev/null 2>&1
assert_file_exists "resolve writes the RELEASED sentinel" "$STATE/skeptic/declined/RELEASED"
assert_contains "…stamped as a resolution, never a verdict" "$(cat "$STATE/skeptic/declined/RELEASED")" "kind: resolution"
assert_no_file "…and never a DONE" "$STATE/skeptic/declined/DONE"
assert_eq "a RE-ENTERED await (which never saw the marker) ends: exit 14" "$(_aw declined)" "14"
assert_contains "…cause=resolve" "$(cat "$WORK/err")" "cause=resolve"
assert_contains "…carrying the orchestrator's reason" "$(cat "$WORK/err")" "depth-1 verdict stands"
assert_not_contains "resolve no longer claims the window is retirable" \
    "$("$SC" resolve declined --reason "second resolve, same decline as before" --disposition 2>&1)" "can now be retired"
# a new round makes the old RELEASED stale
_arm declined "amended after the decline"
assert_no_file "a new round archives the prior RELEASED" "$STATE/skeptic/declined/RELEASED"

# ═══ 6. release: ends a WAIT, never a GATE ═══════════════════════════════════
_rel() { local rc=0; "$SC" release "$1" --reason "asserting the gate is already discharged" >"$WORK/out" 2>"$WORK/err" || rc=$?; printf '%s' "$rc"; }
printf '1' > "$PEND/pend1"
assert_eq "release REFUSES (7) while a pending marker exists" "$(_rel pend1)" "7"
assert_no_file "…and writes nothing" "$STATE/skeptic/pend1/RELEASED"
_arm pend2 "x"; rm -f "$PEND/pend2"
assert_eq "release REFUSES (7) while an armed artefact is outstanding" "$(_rel pend2)" "7"
_arm clear "x"; _verdict clear; "$SC" close clear >/dev/null
assert_eq "release succeeds on a discharged gate" "$(_rel clear)" "0"
assert_file_exists "…writing RELEASED" "$STATE/skeptic/clear/RELEASED"
assert_eq "release from inside a worker session is refused" \
    "$(NEXUS_WORKER_WINDOW=w "$SC" release clear --reason "a worker may not end its own wait" >/dev/null 2>&1; echo $?)" "1"
# rc 1 is ALSO what an unknown verb returns, so the rc alone passed against the
# pre-fix tree. The message is what pins that the REFUSAL ran.
assert_contains "…by the worker-session guard, not by accident" \
    "$(NEXUS_WORKER_WINDOW=w "$SC" release clear --reason "a worker may not end its own wait" 2>&1 || true)" "may not end its own wait"

# ═══ 7. A DECLINED DEPTH-2 CLOSES THAT CHAIN — and only a discharged one ═════
# `ng request reply <id> --status declined --skeptic-resolved` skips `resolve`,
# so it used to touch nothing the declined skeptic's own await reads.
_mkreq() {   # _mkreq <origin> → a CLAIMED spawn-skeptic request id
    local id
    id=$(bash "$RC" file --origin "$1" --kind spawn-skeptic --slug "d2-$1" \
            --reply required --message "fixture: depth-2 review of $1" 2>/dev/null) || return 1
    mv "$STATE/requests/$id.new.md" "$STATE/requests/$id.claimed.md" || return 1
    sed -i 's/^state: new/state: claimed/' "$STATE/requests/$id.claimed.md" || return 1
    printf '%s' "$id"
}
_state_of() { local f; for f in "$STATE/requests/$1".*.md; do [[ -e "$f" ]] && { f=${f%.md}; printf '%s' "${f##*.}"; return; }; done; printf absent; }
_reply() { local rc=0; bash "$RC" reply "$@" --no-publish >"$WORK/out" 2>"$WORK/err" || rc=$?; printf '%s' "$rc"; }

# the skeptic `d2sk` delivered its own verdict wrap-up: its gate is discharged
# (no marker, nothing outstanding), and it is awaiting a depth-2 reviewer.
"$SC" init d2sk >/dev/null
_id=$(_mkreq d2sk) || th_abort "fixture: could not file+claim a spawn-skeptic request"
assert_eq "POSITIVE CONTROL: the request is claimed" "$(_state_of "$_id")" "claimed"
assert_eq "declined + --skeptic-resolved on a DISCHARGED gate succeeds" \
    "$(_reply "$_id" --status declined --skeptic-resolved --message "depth-2 declined: the depth-1 verdict is sufficient here")" "0"
assert_file_exists "…and RELEASES the declined skeptic's own channel" "$STATE/skeptic/d2sk/RELEASED"
assert_eq "…so its re-entered await ENDS (14) instead of waiting for nobody" "$(_aw d2sk)" "14"

# MUST-NOT-FLIP: the same reply while d2pend's review is PENDING is REFUSED and
# the request does not transition (order is the guarantee, #665).
"$SC" init d2pend >/dev/null; printf '2' > "$PEND/d2pend"
_id=$(_mkreq d2pend) || th_abort "fixture: could not file+claim the second request"
assert_eq "declined + --skeptic-resolved with a PENDING marker is refused (6)" \
    "$(_reply "$_id" --status declined --skeptic-resolved --message "asserting discharged while it is in fact still pending")" "6"
assert_eq "…the request is left CLAIMED" "$(_state_of "$_id")" "claimed"
assert_no_file "…nothing was released" "$STATE/skeptic/d2pend/RELEASED"
assert_file_exists "…and the pending marker still gates retirement" "$PEND/d2pend"

# ═══ 8. `window`: a skeptic is found by its ROLE RECORD, not its name (#1536) ═
mkdir -p "$STATE/windows"
printf '{"window":"w242sk","spawned_at":"2026-09-15T14:38:06-07:00","skeptic_role":true,"skeptic_target":"w242","skeptic_orig":"w242"}\n' > "$STATE/windows/w242sk.json"
printf '{"window":"w242","skeptic_role":false}\n' > "$STATE/windows/w242.json"
# `tmux` is an EXPORTED BASH FUNCTION here, never a planted shim FILE on PATH: a
# hand-written `tmux` executable is exactly what monitor/tmuxwrap's gate 3 can
# mistake for a safe mock and then follow to the OPERATOR'S BOARD (#1105), and
# test-tmux-shim-gate3-safety.sh refuses one. The function cannot reach any
# server at all — it only ever prints a fixture file — and it is scoped to the
# `_win` subshell so no other command in this suite sees it.
_win() {
    local rc=0
    (   tmux() { [[ "${1:-}" == list-windows && "${TMUX_FIXTURE_ANSWERS:-1}" == 1 ]] && cat "$WORK/tmux-names"; }
        export -f tmux; export WORK
        "$SC" window "$1" >"$WORK/out" 2>"$WORK/err"
    ) || rc=$?
    printf '%s' "$rc"
}
printf 'w242\nw242sk\n' > "$WORK/tmux-names"
assert_eq "the OLD predicate cannot see this window (the defect, pinned)" \
    "$(grep -c skeptic "$WORK/tmux-names" || true)" "0"
assert_eq "window finds the \`<target>sk\` skeptic by its record: rc 0" "$(_win w242)" "0"
assert_contains "…naming it, live" "$(cat "$WORK/out")" "skeptic=w242sk target=w242 spawned_at=2026-09-15T14:38:06-07:00 live=1"
printf 'w242\nw242sk-old\n' > "$WORK/tmux-names"
assert_eq "a PREFIX neighbour is not the window (exact match): rc 1" "$(_win w242)" "1"
assert_contains "…reported as recorded-but-not-live (rc 1 alone is also an unknown verb's)" "$(cat "$WORK/out")" "skeptic=w242sk target=w242 spawned_at=2026-09-15T14:38:06-07:00 live=0"
assert_eq "a target with no skeptic record: rc 1" "$(_win nobody)" "1"
assert_contains "…said positively" "$(cat "$WORK/err")" "no provenance record names nobody"
assert_eq "tmux not answering is COULD-NOT-TELL (3), never 'none'" "$(TMUX_FIXTURE_ANSWERS=0 _win w242)" "3"

# ═══ 9. A REUSED WINDOW NAME DOES NOT MERGE UNRELATED ROUNDS (#1252) ═════════
_rot() { local rc=0; "$NG" skeptic-ledger-rotate "$1" --state-dir "$STATE" >"$WORK/out" 2>"$WORK/err" || rc=$?; printf '%s' "$rc"; }
_evf() { _field "$("$NG" skeptic-evidence "$1" --state-dir "$STATE" 2>/dev/null | sed -n 1p)" "$2"; }
assert_eq "no ledger on the key: rc 3, nothing to rotate" "$(_rot neverseen)" "3"
# last week's task on the name `reused`: reviewed, closed, settled.
_arm reused "last week's task"; _verdict reused; "$SC" close reused >/dev/null
assert_eq "POSITIVE CONTROL: the old session's verdict is on the key" "$(_evf reused verdicts)" "1"
assert_eq "a fully SETTLED ledger rotates on a fresh spawn: rc 0" "$(_rot reused)" "0"
assert_no_file "…the key's ledger is gone" "$PEND/.reused.ledger"
assert_eq "…ARCHIVED, not deleted" "$(find "$STATE/skeptic/.archive" -maxdepth 1 -name 'reused.ledger-*' | wc -l)" "1"
# this week's unrelated task on the same name
_arm reused "this week's unrelated task"
assert_eq "the new session's round does NOT inherit last week's verdict" "$(_evf reused verdicts)" "0"
assert_eq "…and counts exactly ONE arm, not a union" "$("$NG" skeptic-obligations reused --state-dir "$STATE" 2>/dev/null | grep -c '^arm ' || true)" "1"
# MUST-NOT-ROTATE: an OUTSTANDING obligation is inherited, never dropped.
assert_eq "an OUTSTANDING arm REFUSES rotation (5)" "$(_rot reused)" "5"
assert_file_exists "…and the ledger is KEPT" "$PEND/.reused.ledger"
assert_contains "…saying the new session inherits it" "$(cat "$WORK/err")" "inherits the obligation"
# MUST-NOT-ROTATE: settled ledger but a pending marker on the name.
_arm markered "x"; _verdict markered; "$SC" close markered >/dev/null; printf '1' > "$PEND/markered"
assert_eq "a pending MARKER refuses rotation (5) even over a settled ledger" "$(_rot markered)" "5"
assert_file_exists "…ledger kept" "$PEND/.markered.ledger"
# spawn-worker calls it on a FRESH spawn only.
assert_eq "spawn-worker.sh invokes the rotation, gated on NOT --resume" \
    "$(grep -B3 'skeptic-ledger-rotate "\$WINDOW_NAME"' "$REPO_ROOT/monitor/spawn-worker.sh" | grep -o 'if \[ -z "\$RESUME_TARGET" \]' | wc -l | tr -d ' ')" "1"

# ═══ 10. A PROMISED DELTA REVIEW DOES NOT EVAPORATE (#1573 instance 5) ═══════
# `killsafe`, 2026-09-18: resolved with "… a DELTA review will follow", fixed four
# kill-direction findings, ran a plain wrap-up → #815 (correctly) did not re-arm,
# no request was filed, and the window read "can retire". The promise was prose.
_res() { local rc=0; "$SC" resolve "$@" >"$WORK/out" 2>"$WORK/err" || rc=$?; printf '%s' "$rc"; }
_wrap() {   # _wrap <window> → "marker=<y/n> reqs=<n> owed=<y/n> DELTA=<n> R815=<n>"
    bash -c '
        set -uo pipefail
        NG="$1"; ST="$2"; WK="$3"; win="$4"
        export NEXUS_STATE_DIR="$ST"
        source "$NG" >/dev/null 2>&1
        STATE_DIR="$ST"; P="$STATE_DIR/skeptic/pending"; K=$(wk_encode "$win")
        mkdir -p "$STATE_DIR/requests"
        [ "${5:-}" = keep ] || printf -- "---\nproject: %s\ndisposition: no-further-pass\n---\nthe report\nplus the kill-direction fixes\n" "$win" > "$WK/reports/$win.md"
        _SK_REPORT_PATH="$WK/reports/$win.md"
        # NOT `out=$(…)`: the step signals "file a spawn-skeptic request" by
        # setting _SK_SPAWN_REQ, and a command substitution would lose it.
        _SK_SPAWN_REQ=0
        _wrapup_skeptic_step 1573 "$win" owner/repo 0 require "why" "" "" "" "" "" "" "" "" >"$WK/wrap.out" 2>&1
        out=$(cat "$WK/wrap.out")
        printf "marker=%s reqs=%s owed=%s DELTA=%s R815=%s V984=%s\n" \
            "$([ -e "$P/$K" ] && echo y || echo n)" "${_SK_SPAWN_REQ:-0}" \
            "$([ -e "$P/.$K.delta-owed" ] && echo y || echo n)" \
            "$(printf "%s" "$out" | grep -c "A DELTA REVIEW IS OWED" || true)" \
            "$(printf "%s" "$out" | grep -c "ALREADY RESOLVED" || true)" \
            "$(printf "%s" "$out" | grep -c "ALREADY VALIDATED" || true)"
    ' _ "$NG" "$STATE" "$WORK" "$1" "${2:-}" 2>/dev/null
}
_round1() {   # a reviewed-with-findings round 1 on <window>, marker live
    printf -- '---\nproject: %s\ndisposition: no-further-pass\n---\nthe report\n' "$1" > "$WORK/reports/$1.md"
    "$NG" skeptic-arm "$1" --report "$WORK/reports/$1.md" --state-dir "$STATE" >/dev/null 2>&1
    printf 'discharged\t%s\t%s\tcheck\t1573\t%ssk\tattributed\n' "$(_sha "$1")" "$(date -Is)" "$1" >> "$PEND/.$1.ledger"
}

# MUST-NOT-FLIP — #815 stands: a plain resolution is NOT reversed by a wrap-up.
_round1 plain815
assert_eq "CONTROL resolve without the flag succeeds" \
    "$(_res plain815 --reason "round one adjudicated: findings accepted as they stand" --disposition)" "0"
_w=$(_wrap plain815)
assert_contains "CONTROL #815: a plain resolution is still NOT re-armed by the worker's wrap-up" "$_w" "marker=n reqs=0"
assert_contains "CONTROL …via the #815 suppression itself" "$_w" "R815=1"

# the promise, as prose only: LOUD at resolve time.
_round1 prose
_res prose --reason "round one resolved. A DELTA review of the kill-direction fixes will follow." --disposition >/dev/null
assert_contains "a --reason that READS as a promise, with no record, WARNS" "$(cat "$WORK/err")" "reads as a PROMISE"

# the promise, as a RECORD.
_round1 killsafe
assert_eq "resolve --delta-owed succeeds" \
    "$(_res killsafe --reason "round one resolved on the record; fixes are pending" --disposition --delta-owed "the kill-direction fixes F1-F4, including the fail-open")" "0"
assert_file_exists "…and records the owed delta" "$PEND/.killsafe.delta-owed"
assert_no_file "…while releasing the CURRENT wait (marker gone)" "$PEND/killsafe"
assert_eq "release REFUSES (7) while a delta is owed" "$(_rel killsafe)" "7"
assert_eq "a later resolve that would EVAPORATE it as a side effect is REFUSED" \
    "$(_res killsafe --reason "a routine decline arriving through request reply")" "1"
assert_file_exists "…and the record survives it" "$PEND/.killsafe.delta-owed"
_w=$(_wrap killsafe)
assert_contains "the worker's PLAIN wrap-up now ARMS and files the request" "$_w" "marker=y reqs=1"
assert_contains "…saying why, and NOT via #815's suppression" "$_w" "DELTA=1 R815=0"
assert_contains "…and the promise is handed to the marker (record consumed)" "$_w" "owed=n"
assert_eq "…kept for the audit trail, not deleted" "$(find "$PEND" -maxdepth 1 -name '.killsafe.delta-owed.armed-*' | wc -l)" "1"

# explicit withdrawal is the only other way out.
_round1 withdrawn
_res withdrawn --reason "round one resolved on the record; fixes are pending" --disposition --delta-owed "the follow-up fixes to the parser arm" >/dev/null
assert_eq "resolve --withdraw-delta succeeds" "$(_res withdrawn --reason "the fixes were dropped from scope; nothing to review" --withdraw-delta)" "0"
assert_no_file "…and removes the live record" "$PEND/.withdrawn.delta-owed"
assert_contains "…after which #815 applies again" "$(_wrap withdrawn)" "marker=n reqs=0"

# ═══ 11. skprotosk round-1 findings F1-F5 (PR #1580 review) ═══════════════
# F1 — an OUTSTANDING arm means no verdict covers the current bytes, whatever
# the standing verdict says. Ledger: verdict on A, then arm B with no close.
_arm f1 "bytes A"; _verdict f1
_arm f1 "bytes B"
_ev=$("$NG" skeptic-evidence f1 --state-dir "$STATE" 2>/dev/null | sed -n 1p)
assert_eq "F1 FIXTURE: an arm is outstanding (open=1)" "$(_field "$_ev" open)" "1"
"$SC" close f1 >/dev/null
assert_eq "F1 close over an OUTSTANDING arm: exit 14, not 10" "$(_aw f1)" "14"
# The `open>0` arm on its own, driven through the REAL classifier on the exact
# evidence line skprotosk measured (standing_stale=? so the stale arm cannot
# fire): a prior verdict attributed to OTHER bytes with an arm outstanding.
_vc() { { sed -n '/^_await_verdict_class()/,/^}/p' "$SC"; printf '_await_verdict_class %q\n' "$1"; } | bash; }
assert_eq "F1 classifier: open=1 with a prior verdict on other bytes is NONE, whatever standing_stale says" \
    "$(_vc "window=x key=x ledger=present evidence=prior-verdict-other-artefact verdicts=1 matched=0 unmatched=0 superseded=0 standing_stale=? open=1")" "none"
assert_eq "F1 classifier CONTROL: open=0 with standing_stale=? is UNCONFIRMED (exit code stands)" \
    "$(_vc "window=x key=x ledger=present evidence=attributed verdicts=1 standing_stale=? open=0")" "unconfirmed"
assert_eq "F1 classifier CONTROL: open=0 with standing_stale=0 is CURRENT" \
    "$(_vc "window=x key=x ledger=present evidence=attributed verdicts=1 standing_stale=0 open=0")" "current"
# F1 CONTROL: the ordinary single round (verdict, nothing outstanding,
# standing_stale=?) keeps 10 and says the ledger cannot confirm the bytes.
_arm f1c "only round"; _verdict f1c; "$SC" close f1c >/dev/null
assert_eq "F1 CONTROL: verdict + nothing outstanding is still exit 10" "$(_aw f1c)" "10"
assert_contains "F1 CONTROL: …and the note says the bytes are unconfirmed, not UNVERIFIED" \
    "$(cat "$WORK/err")" "cannot confirm it is about the CURRENT bytes"
assert_not_contains "F1 CONTROL: …" "$(cat "$WORK/err")" "UNVERIFIED"

# F2 — a depth-1 skeptic awaiting on its OWN window after a RECOMMENDED next
# pass: no marker, no arm, only an open spawn-skeptic request naming it.
"$SC" init f2sk >/dev/null
mkdir -p "$STATE/requests"
printf -- '---\nrequest: 20260918T000000Z-f2sk-skeptic-d2\norigin: f2sk\nkind: spawn-skeptic\nstate: new\n---\n\nspawn-skeptic: validate f2sk\n' \
    > "$STATE/requests/20260918T000000Z-f2sk-skeptic-d2.new.md"
assert_eq "F2 an OPEN spawn-skeptic request naming the task is a pending round: timeout 4, not 15" "$(_aw f2sk)" "4"
assert_contains "F2 …naming the request" "$(cat "$WORK/err")" "20260918T000000Z-f2sk-skeptic-d2"
mv "$STATE/requests/20260918T000000Z-f2sk-skeptic-d2.new.md" "$STATE/requests/20260918T000000Z-f2sk-skeptic-d2.done.md"
assert_eq "F2 CONTROL: once the request is done and nothing armed, it is 15 again" "$(_aw f2sk)" "15"

# F3 — --withdraw-delta with nothing live is refused and writes nothing.
_round1 f3; _res f3 --reason "round one adjudicated: findings accepted as they stand" --disposition >/dev/null
_n3=$(grep -c '^resolved' "$PEND/.f3.ledger")
assert_eq "F3 --withdraw-delta with NO owed delta is refused (1)" \
    "$(_res f3 --reason "withdrawing a promise that was never made" --withdraw-delta)" "1"
assert_eq "F3 …and appends no resolved row" "$(grep -c '^resolved' "$PEND/.f3.ledger")" "$_n3"
assert_contains "F3 …saying so" "$(cat "$WORK/err")" "nothing to withdraw"

# F4 — an owed delta with a BYTE-IDENTICAL report (fixes went into code).
_round1 f4
_res f4 --reason "round one resolved on the record; fixes are pending" --disposition --delta-owed "the code fixes; the report itself did not change" >/dev/null
_w=$(_wrap f4 keep)
assert_contains "F4 byte-identical report + owed delta: ARMS and requests (the #984 suppression is bypassed too)" "$_w" "marker=y reqs=1"
assert_contains "F4 …record consumed" "$_w" "owed=n"
# F4 CONTROL: byte-identical WITHOUT an owed delta is still suppressed (#984).
_round1 f4c
# (the marker here pre-exists from skeptic-arm; #984 files no request and says why)
_w=$(_wrap f4c keep)
assert_contains "F4 CONTROL: byte-identical, nothing owed: #984 still suppresses (no request)" "$_w" "reqs=0"
assert_contains "F4 CONTROL: …via the ALREADY VALIDATED banner" "$_w" "V984=1"

# F5 — a verdict from a report OLDER than the round it discharges is refused.
_f5() {   # _f5 <report-mtime-spec> → "rc=<n> discharged=<n>"
    local w="$WORK/f5"; rm -rf "$w"; mkdir -p "$w/state/skeptic/pending" "$w/reports"
    printf 'armed\t%s\t%s\t1580\t/r/target.md\n' "$(printf target | sha256sum | awk '{print $1}')" "$(date -Is)" > "$w/state/skeptic/pending/.f5t.ledger"
    printf -- '---\nproject: f5sk\nstatus: completed\ndisposition: no-further-pass\n---\n\n# r\n\n## Summary\n\nverdict\n' > "$w/reports/sk.md"
    touch -d "$1" "$w/reports/sk.md"
    env -u NEXUS_WORKER_WINDOW bash -c '
        set -uo pipefail
        export NEXUS_STATE_DIR="$2/state"
        source "$1" >/dev/null 2>&1
        STATE_DIR="$2/state"
        _SK_REPORT_PATH="$2/reports/sk.md"
        _wrapup_skeptic_step 1580 f5sk owner/repo 1 "" "" "" credible f5t 1 "0" "" "" "" "" >"$2/out" 2>&1
        rc=$?
        printf "rc=%s discharged=%s\n" "$rc" "$(grep -c "^discharged" "$2/state/skeptic/pending/.f5t.ledger" || true)"
    ' _ "$NG" "$w" 2>/dev/null
}
assert_eq "F5 a skeptic report OLDER than the round it discharges: REFUSED, nothing recorded" \
    "$(_f5 '2 hours ago')" "rc=1 discharged=0"
assert_contains "F5 …saying a NEW report is required" "$(cat "$WORK/f5/out")" "NEW report"
assert_eq "F5 CONTROL: a report written after the arm discharges normally" \
    "$(_f5 '1 hour')" "rc=0 discharged=1"

# ═══ 12. merge4sk (2026-09-18): a verdict naming NO artefact, and the reader that no-ops
# 12a — a skeptic-role wrap-up that would record sha=- while the target has
# arms outstanding is REFUSED, naming the arms and the flag to pass.
_f6() {   # _f6 <subject-arg> → "rc=<n> rows=<discharged rows>"
    local w="$WORK/f6"; rm -rf "$w"; mkdir -p "$w/state/skeptic/pending" "$w/reports"
    printf 'a-bytes\n' > "$w/reports/a.md"; printf 'b-bytes\n' > "$w/reports/b.md"
    printf 'armed\t%s\t2026-09-18T10:00:00-07:00\t1580\t%s\n' "$(sha256sum < "$w/reports/a.md" | awk '{print $1}')" "$w/reports/a.md" > "$w/state/skeptic/pending/.f6t.ledger"
    # SAME issue on both arms: an issue-narrowable pair is attributed by issue,
    # and a DIFFERENT issue trips the older STALE SPAWN STAMP refusal first.
    printf 'armed\t%s\t2026-09-18T10:00:01-07:00\t1580\t%s\n' "$(sha256sum < "$w/reports/b.md" | awk '{print $1}')" "$w/reports/b.md" >> "$w/state/skeptic/pending/.f6t.ledger"
    printf -- '---\nproject: f6sk\nstatus: completed\ndisposition: no-further-pass\n---\n\n# r\n\n## Summary\n\nverdict\n' > "$w/reports/sk.md"
    env -u NEXUS_WORKER_WINDOW bash -c '
        set -uo pipefail
        export NEXUS_STATE_DIR="$2/state"
        source "$1" >/dev/null 2>&1
        STATE_DIR="$2/state"
        _SK_REPORT_PATH="$2/reports/sk.md"
        _SK_SUBJECT_ARG="$3"
        _wrapup_skeptic_step 1580 f6sk owner/repo 1 "" "" "" credible f6t 1 "0" "" "" "" "" >"$2/out" 2>&1
        rc=$?
        printf "rc=%s rows=%s\n" "$rc" "$(grep -c "^discharged" "$2/state/skeptic/pending/.f6t.ledger" || true)"
    ' _ "$NG" "$w" "$1" 2>/dev/null
}
assert_eq "12a two arms outstanding, no subject named: the sha=- verdict is REFUSED, nothing recorded" \
    "$(_f6 "")" "rc=1 rows=0"
assert_contains "12a …by THIS refusal, not an older one" "$(cat "$WORK/f6/out")" "names NO artefact"
assert_contains "12a …naming the flag" "$(cat "$WORK/f6/out")" "--skeptic-subject"
assert_contains "12a …and the outstanding arms" "$(cat "$WORK/f6/out")" "$(sha256sum < "$WORK/f6/reports/b.md" | awk '{print $1}')"
assert_eq "12a CONTROL: the same verdict WITH --skeptic-subject <report> is recorded" \
    "$(_f6 "$WORK/f6/reports/b.md")" "rc=0 rows=1"
assert_contains "12a CONTROL: …attributed to what it named" \
    "$(cat "$WORK/f6/state/skeptic/pending/.f6t.ledger")" "asserted"
# MUST-NOT-FLIP: with NO arm at all there is nothing to name; the verdict is
# still recorded (the irreplaceable fact, test-skeptic-arm-recording.sh).
rm -f "$WORK/f6/state/skeptic/pending/.f6t.ledger"
_r=$(env -u NEXUS_WORKER_WINDOW bash -c '
        set -uo pipefail; export NEXUS_STATE_DIR="$2/state"; source "$1" >/dev/null 2>&1; STATE_DIR="$2/state"
        _SK_REPORT_PATH="$2/reports/sk.md"; _SK_SUBJECT_ARG=""
        _wrapup_skeptic_step 1580 f6sk owner/repo 1 "" "" "" credible f6t 1 "0" "" "" "" "" >/dev/null 2>&1
        printf "rc=%s rows=%s" "$?" "$(grep -c "^discharged" "$2/state/skeptic/pending/.f6t.ledger" || true)"
    ' _ "$NG" "$WORK/f6" 2>/dev/null)
assert_eq "12a CONTROL: no arm on record at all: still recorded as no-arm-on-record" "$_r" "rc=0 rows=1"

# 12b — the addendum: `resolve` without --disposition on a require window whose
# ledger holds only a sha=- discharge and a close used to say "no obligation is
# outstanding" and write NOTHING, while report-check's reader refused. The
# resolution record is what that reader consults; resolve now writes it.
mkdir -p "$STATE/windows"
printf '{"window":"merge4","skeptic_mode":"require","skeptic_role":false}\n' > "$STATE/windows/merge4.json"
printf 'discharged\t-\t2026-09-18T11:00:00-07:00\tcredible\t1580\tmerge4sk\tno-arm-on-record\n' > "$PEND/.merge4.ledger"
printf 'resolved\t-\t2026-09-18T11:01:00-07:00\tskeptic-channel.sh close\tchannel closed by the reviewer (end of pairing)\n' >> "$PEND/.merge4.ledger"
assert_eq "12b resolve WITHOUT --disposition on a require window with no resolution record: records it (rc 0)" \
    "$(_res merge4 --reason "merge4sk delivered credible with no artefact named; settling on the record")" "0"
assert_file_exists "12b …writing the record report-check reads" "$PEND/.merge4.cleared-rationale"
assert_contains "12b …and saying which reader it is for" "$(cat "$WORK/err")" "report-check"
# MUST-NOT-FLIP: an auto-mode window in the same ledger state is still "nothing to resolve".
printf '{"window":"auto4","skeptic_mode":"auto","skeptic_role":false}\n' > "$STATE/windows/auto4.json"
cp "$PEND/.merge4.ledger" "$PEND/.auto4.ledger"
assert_eq "12b CONTROL: an auto window in the same state is still refused (nothing to resolve)" \
    "$(_res auto4 --reason "there is nothing here for an operator to release")" "1"
assert_no_file "12b CONTROL: …and nothing is written" "$PEND/.auto4.cleared-rationale"

# ═══ 13. skprotosk delta G1: a SETTLEMENT is not a DECLINE ═══════════════════
# The 12b resolution (require window, completed round) wrote the record #815's
# suppression reads, so the worker's NEXT round of new work read "ALREADY
# RESOLVED — can retire". A settlement declined nothing; new work arms.
_w=$(_wrap merge4)
assert_contains "G1 after a settlement, a wrap-up of NEW work ARMS and requests" "$_w" "marker=y reqs=1"
assert_contains "G1 …and #815's suppression does not fire" "$_w" "R815=0"
assert_contains "G1 …the record says so" "$(cat "$PEND/.merge4.cleared-rationale")" "settles-completed-round"
# MUST-NOT-FLIP: a DECLINE (disposition resolve over a live round) still suppresses (#815).
_round1 decl815
_res decl815 --reason "round one adjudicated: findings accepted as they stand" --disposition >/dev/null
assert_contains "G1 CONTROL: a decline is still #815-suppressed" "$(_wrap decl815)" "marker=n reqs=0 owed=n DELTA=0 R815=1"

# ── ASSERTION-COUNT PIN ────────────────────────────────────────────────────
EXPECTED=132
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
