#!/usr/bin/env bash
# test-operator-alert.sh — the text-carrying, turn-independent operator alert
# (`monitor/watcher/_operator_alert.sh`; your-org/nexus-code#1548, #1533, #1534).
#
# The thing this module exists to guarantee is that a condition the watcher
# alone can see reaches a human through legs that need NO model turn and NO
# operator credential: a durable record, the `watcher ALERT:` bell, a push, and
# a bot-authored GitHub issue. Every leg must FAIL OPEN — a notifier that can
# break its caller is worse than silence (#1553) — and the cadence must be one
# announcement, reminders on a slow clock, one clear (#976).
#
# HERMETIC. `NEXUS_ROOT` points at a throwaway tree; the push command is a
# RECORDER; `gh` and `mint-token.sh` are stubs first on PATH; nothing here can
# ring a real bell, page a phone or file an issue. The network legs run
# DETACHED in production, so the assertions on them POLL the recorder files.
#
# MUTATION PREDICTIONS, written before the run (your-org/nexus-code#1510):
#   M1 delete `(( now - last < reminder )) && return 0`  → §2 FLIPS (a second
#      raise inside the window rings again), §3 unchanged, §1/§4 unchanged.
#   M2 delete the `began` create branch of the GitHub leg → §1 "filed" FLIPS;
#      §3 reminder then reports no-open-issue (FLIPS); §4 close FLIPS.
#   M3 make `_operator_alert_raise` `return 1` on an unwritable dir → §9 FLIPS,
#      nothing else (the fail-open guarantee is only asserted there).
#   M4 drop the `NEXUS_NOTIFY_QUIET` gate in `_operator_alert_network` → §7
#      FLIPS (a push is recorded under QUIET); §1 unchanged.
#   Must-NOT-flip on any of M1–M4: §5 (bad key), §6 (warning does not ring).
#   §23/§24 (your-org/nexus-code#1567 G2/G4) carry their own predictions inline.

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
. "$_test_dir/_test_helpers.sh"

MODULE="$_test_dir/_operator_alert.sh"

# ---- POPULATION DECLARATION (your-org/nexus-code#1078) --------------------
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$MODULE"; }
gp_handle "$@"

PASS=0; FAIL=0; SKIP=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$label (got '$got')"; else fail "$label: got '$got', want '$want'"; fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/opalert-XXXXXX") || th_abort "mktemp failed"
# §24 leaves `sleep` sentinels by design; reap them even on an abort.
cleanup() {
    if declare -F g4_reap >/dev/null 2>&1; then g4_reap g4-key; g4_reap g4-main-key; fi
    chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT

# ---- fixture: a throwaway nexus root, stubs on PATH, recorders -------------
# The module keeps a fallback memo under $TMPDIR (F2); pin it into the fixture
# so a suite run can neither read nor leave a memo where a watcher would look.
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export NEXUS_ROOT="$WORK/root"
mkdir -p "$NEXUS_ROOT/monitor" "$WORK/bin" "$WORK/state"
export STATE_DIR="$WORK/state"
unset NEXUS_NOTIFY_QUIET
export MONITOR_REPO="acme/nexus-fixture" MONITOR_USER_LOGIN="operator-fixture"
export GH_CALLS="$WORK/gh-calls" GH_ISSUES="$WORK/gh-issues.tsv" PUSH_CALLS="$WORK/push-calls"
: > "$GH_CALLS"; : > "$PUSH_CALLS"; : > "$GH_ISSUES"
gh_reset() { : > "$GH_CALLS"; : > "$GH_ISSUES"; rm -f "$STATE_DIR"/operator-alert/*.ghcomment 2>/dev/null; }

# The push RECORDER stands in for monitor/notify.sh: same argv contract.
cat > "$WORK/bin/notify-recorder" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PUSH_CALLS"
exit "${PUSH_RC:-0}"
EOF
chmod +x "$WORK/bin/notify-recorder"
export _OPERATOR_ALERT_PUSH_CMD="$WORK/bin/notify-recorder"

# The mint stub prints a token and touches nothing.
cat > "$WORK/bin/mint-token.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ghs_fixture_token\n'
EOF
chmod +x "$WORK/bin/mint-token.sh"
export NEXUS_MINT_TOKEN_BIN="$WORK/bin/mint-token.sh"

# The `gh` stub: records every call; the open-issues list is a file the CREATE
# arm rewrites, so a second raise finds the issue the first one filed — the
# same network-side idempotency the real module relies on.
# The `gh` stub keeps a tiny ISSUE TABLE (`number\tstate\ttitle`) so the
# module's network-side idempotency is exercised for real: a create appends,
# a PATCH flips state, the open/closed lists are derived from it. GH_FAIL=1
# makes every call fail (unreachable / rate-limited), rc 1 with a 403 body.
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
if [[ "${GH_FAIL:-0}" == 1 ]]; then printf '{"message":"API rate limit exceeded"}\n'; exit 1; fi
_list() {   # <state>
    awk -F'\t' -v st="$1" 'BEGIN{printf "["} $2==st {if(n++)printf ","; printf "{\"number\":%s,\"title\":\"%s\",\"pull_request\":null}", $1, $3} END{print "]"}' "$GH_ISSUES"
}
case "$*" in
    *"/issues?state=open"*)   _list open ;;
    *"/issues?state=closed"*) _list closed ;;
    *"-X POST /repos/"*"/issues -f title="*)
        t=$(printf '%s\n' "$@" | sed -n 's/^title=//p')
        n=$(( 40 + $(grep -c . "$GH_ISSUES" 2>/dev/null || true) + 1 ))
        printf '%s\topen\t%s\n' "$n" "$t" >> "$GH_ISSUES"
        printf '{"number":%s}\n' "$n" ;;
    *"-X PATCH /repos/"*"/issues/"*" -f state="*)
        n=$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9]*\) .*|\1|p')
        st=$(printf '%s\n' "$@" | sed -n 's/^state=//p')
        awk -F'\t' -v OFS='\t' -v n="$n" -v st="$st" '$1==n {$2=st} {print}' "$GH_ISSUES" > "$GH_ISSUES.tmp" && mv "$GH_ISSUES.tmp" "$GH_ISSUES"
        printf '{"number":%s,"state":"%s"}\n' "$n" "$st" ;;
    *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

LOGCAP="$WORK/log"; BELLCAP="$WORK/bell"; : > "$LOGCAP"; : > "$BELLCAP"
_rec_log()  { printf '%s\n' "$1" >> "$LOGCAP"; }
_rec_bell() { printf '%s\n' "$1" >> "$BELLCAP"; }
export _OPERATOR_ALERT_LOG_FN=_rec_log _OPERATOR_ALERT_BELL_FN=_rec_bell
export MONITOR_OPERATOR_ALERT_NET_TIMEOUT_SECONDS=20
# The network legs run INLINE for §1–§13 so every assertion is deterministic;
# §14 drops the seam and pins the production default (detached).
export _OPERATOR_ALERT_NETWORK_SYNC=1
# §1–§16 run with the clear hold-down OFF so a clear finalises on its first
# call; §17 turns it on and drives the flap.
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
# …and with the comment cap OFF, so the reminder/clear comments in §3/§4 are
# observable; §18 turns the cap on.
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=0

# shellcheck source=_operator_alert.sh
source "$MODULE" || th_abort "could not source $MODULE"

JSONL="$STATE_DIR/operator-alerts.jsonl"
# `grep -c` prints `0` AND exits 1 on no match, so `|| echo 0` would print a
# second zero into an arithmetic context (the #725 shape). Validate the shape.
count_lines() { local n; n=$(grep -c . "$1" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
wait_lines() {   # <file> <n> [max_s] — polls; inline mode returns at once
    local f="$1" n="$2" max="${3:-15}" i
    for (( i = 0; i < max * 4; i++ )); do
        (( $(count_lines "$f") >= n )) && return 0
        sleep 0.25
    done
    return 1
}
# A recorded gh call carries the ISSUE BODY, which spans lines; count CALLS.
count_gh() { local n; n=$(grep -c '^api ' "$GH_CALLS" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
wait_gh() {   # <n> [max_s]
    local n="$1" max="${2:-15}" i
    for (( i = 0; i < max * 4; i++ )); do (( $(count_gh) >= n )) && return 0; sleep 0.25; done
    return 1
}
jsonl_count() { local n; n=$(grep -c "\"event\":\"$1\"" "$JSONL" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }

echo "=== 1. first raise: record + log + bell + push(emergency) + issue FILED ==="
_operator_alert raise auth-expired critical "RUN /login in the orchestrator window — the session is logged out"
rc=$?
assert_eq "1 raise returns 0" "$rc" 0
[[ -f "$STATE_DIR/operator-alert/auth-expired.stamp" ]] && pass "1 the key is STANDING (stamp written)" || fail "1 no stamp"
assert_eq "1 one raise row in the durable record" "$(jsonl_count raise)" 1
grep -q '"kind":"began"' "$JSONL" && pass "1 …of kind began" || fail "1 kind is not began"
grep -q 'RUN /login' "$JSONL" && pass "1 the record carries the TEXT (the leg #1533 says the bell cannot)" || fail "1 message absent from the record"
grep -q 'operator-alert: RAISED key=auth-expired' "$LOGCAP" && pass "1 watcher log names the raise" || fail "1 no log line"
assert_eq "1 the bell rang ONCE (critical)" "$(count_lines "$BELLCAP")" 1
grep -q 'RUN /login' "$BELLCAP" && pass "1 bell leg received the text (it is _watcher_alert's job to log it)" || fail "1 bell text missing"
wait_lines "$PUSH_CALLS" 1 && pass "1 push leg fired" || fail "1 push leg never fired"
grep -q -- '--priority emergency' "$PUSH_CALLS" && pass "1 push priority is EMERGENCY for critical" || fail "1 push priority: $(cat "$PUSH_CALLS")"
grep -q -- '--require-delivery' "$PUSH_CALLS" && pass "1 push asks for a loud failure (--require-delivery)" || fail "1 no --require-delivery"
wait_gh 3 && pass "1 github leg ran (open list, closed list, create)" || fail "1 github leg: $(cat "$GH_CALLS")"
grep -q -- '-X POST /repos/acme/nexus-fixture/issues -f title=operator-alert: auth-expired' "$GH_CALLS" \
    && pass "1 an issue titled 'operator-alert: auth-expired' was FILED on the nexus repo" \
    || fail "1 no create call: $(cat "$GH_CALLS")"
grep -q 'body=@operator-fixture' "$GH_CALLS" && pass "1 the issue body @-pings the operator" || fail "1 no @-ping"
wait_lines "$JSONL" 4 && true
grep -q '"event":"push".*"rc":"0"' "$JSONL" && pass "1 push outcome recorded (rc 0)" || fail "1 push outcome not recorded: $(cat "$JSONL")"
grep -q '"event":"github".*"action":"filed".*"issue":"41"' "$JSONL" && pass "1 github outcome recorded (filed #41)" || fail "1 github outcome not recorded: $(cat "$JSONL")"
grep -q 'API acceptance, not device delivery' "$JSONL" && pass "1 the push record states what rc 0 does and does not prove" || fail "1 push record over-claims"

echo "=== 2. a raise INSIDE the reminder window is silent — no ring, no push, no record ==="
_operator_alert raise auth-expired critical "RUN /login (repeat)"
sleep 1
assert_eq "2 still exactly one raise row" "$(jsonl_count raise)" 1
assert_eq "2 the bell did not ring again" "$(count_lines "$BELLCAP")" 1
assert_eq "2 no second push" "$(count_lines "$PUSH_CALLS")" 1
assert_eq "2 no further github calls" "$(count_gh)" 3

echo "=== 3. past the reminder window: a REMINDER rings and comments, never re-files ==="
export MONITOR_OPERATOR_ALERT_REMINDER_SECONDS=1
sleep 2
_operator_alert raise auth-expired critical "RUN /login (still)"
assert_eq "3 second raise row" "$(jsonl_count raise)" 2
grep -q '"kind":"continues"' "$JSONL" && pass "3 …of kind continues" || fail "3 not a continues row"
grep -q 'REMINDER #2' "$LOGCAP" && pass "3 log says REMINDER #2" || fail "3 no reminder log line"
assert_eq "3 the bell rang again (reminder)" "$(count_lines "$BELLCAP")" 2
wait_lines "$PUSH_CALLS" 2 && pass "3 reminder push fired" || fail "3 no reminder push"
wait_gh 4 && true
assert_eq "3 exactly ONE issue was ever created" "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=' "$GH_CALLS")" 1
grep -q -- '-X POST /repos/acme/nexus-fixture/issues/41/comments -f body=@operator-fixture still standing' "$GH_CALLS" \
    && pass "3 the reminder is a COMMENT on the open issue" || fail "3 no reminder comment: $(cat "$GH_CALLS")"
unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS

echo "=== 4. clear: stamp gone, duration recorded, routine push, issue CLOSED, no bell ==="
_operator_alert raise auth-expired critical "x" >/dev/null   # inside window: silent
_operator_alert clear auth-expired "the operator ran /login; the board resumed"
rc=$?
assert_eq "4 clear returns 0" "$rc" 0
[[ ! -f "$STATE_DIR/operator-alert/auth-expired.stamp" ]] && pass "4 the key is no longer standing" || fail "4 stamp survived clear"
assert_eq "4 one clear row" "$(jsonl_count clear)" 1
grep -q '"event":"clear".*"duration_s":"[0-9]*"' "$JSONL" && pass "4 clear row carries the duration" || fail "4 no duration"
assert_eq "4 the bell did NOT ring on clear" "$(count_lines "$BELLCAP")" 2
wait_lines "$PUSH_CALLS" 3 && pass "4 clear pushed" || fail "4 no clear push"
grep -q -- '--priority routine' <<<"$(tail -n1 "$PUSH_CALLS")" && pass "4 …at ROUTINE priority" || fail "4 clear push priority: $(tail -n1 "$PUSH_CALLS")"
wait_gh 7 && true
grep -q -- '-X PATCH /repos/acme/nexus-fixture/issues/41 -f state=closed' "$GH_CALLS" \
    && pass "4 the issue was CLOSED" || fail "4 no close call: $(cat "$GH_CALLS")"
grep -q 'body=✅ cleared' "$GH_CALLS" && pass "4 …with a cleared comment" || fail "4 no cleared comment"
_operator_alert clear auth-expired "again"
assert_eq "4 clearing a key that is not standing records nothing" "$(jsonl_count clear)" 1
if _operator_alert standing auth-expired; then fail "4 'standing' still true after clear"; else pass "4 'standing' is false after clear"; fi

echo "=== 5. a malformed key is REFUSED, and refuses loudly ==="
: > "$LOGCAP"
_operator_alert raise 'Bad Key/../x' critical "m"
rc=$?
assert_eq "5 raise with a bad key still returns 0 (fail-open)" "$rc" 0
grep -q 'REFUSED raise' "$LOGCAP" && pass "5 the refusal is logged" || fail "5 refusal silent"
[[ -z "$(ls "$STATE_DIR"/operator-alert/*.stamp 2>/dev/null)" ]] && pass "5 no stamp written for a bad key" || fail "5 stamp written: $(ls "$STATE_DIR"/operator-alert/)"

echo "=== 6. warning severity: recorded, pushed routine, filed — NOT rung ==="
: > "$BELLCAP"; : > "$PUSH_CALLS"; gh_reset
_operator_alert raise service-health:jupyter warning "service jupyter DOWN while the orchestrator cannot be told"
assert_eq "6 warning does not ring the bell" "$(count_lines "$BELLCAP")" 0
wait_lines "$PUSH_CALLS" 1 && pass "6 warning pushes" || fail "6 no push"
grep -q -- '--priority routine' "$PUSH_CALLS" && pass "6 …at ROUTINE priority" || fail "6 wrong priority"
wait_gh 2 && pass "6 warning files an issue too" || fail "6 no github leg"
_operator_alert clear service-health:jupyter "recovered"
if _operator_alert standing service-health:jupyter; then fail "6 still standing"; else pass "6 cleared"; fi

echo "=== 7. NEXUS_NOTIFY_QUIET=1 disables BOTH network legs, and says so ==="
: > "$PUSH_CALLS"; : > "$GH_CALLS"; : > "$BELLCAP"
NEXUS_NOTIFY_QUIET=1 _operator_alert raise quiet-key critical "under a test harness"
sleep 1
assert_eq "7 no push under QUIET" "$(count_lines "$PUSH_CALLS")" 0
assert_eq "7 no github call under QUIET" "$(count_gh)" 0
grep -q '"event":"network-skipped".*"reason":"NEXUS_NOTIFY_QUIET"' "$JSONL" && pass "7 the skip is RECORDED with its reason" || fail "7 skip not recorded"
assert_eq "7 the bell leg is not gated by QUIET here (the wrapper owns that gate)" "$(count_lines "$BELLCAP")" 1
NEXUS_NOTIFY_QUIET=1 _operator_alert clear quiet-key "done"

echo "=== 8. no timeout on PATH: network legs SKIPPED, not run unbounded (#1553 F2) ==="
: > "$PUSH_CALLS"; : > "$GH_CALLS"
# A PATH holding every tool the module needs EXCEPT timeout.
NOTMO="$WORK/bin-no-timeout"; mkdir -p "$NOTMO"
for t in date tr sed mkdir cut rm grep cat sleep dirname basename; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$NOTMO/$t"
done
ln -sf "$WORK/bin/gh" "$NOTMO/gh"; ln -sf "$WORK/bin/notify-recorder" "$NOTMO/notify-recorder"
if PATH="$NOTMO" command -v timeout >/dev/null 2>&1; then
    fail "8 fixture: timeout still resolvable on the stripped PATH"
else
    pass "8 fixture: timeout is absent from the stripped PATH"
fi
PATH="$(th_hermetic_path "$NOTMO" "$WORK")" _operator_alert raise notmo-key critical "no timeout available"
sleep 1
assert_eq "8 no push without timeout" "$(count_lines "$PUSH_CALLS")" 0
assert_eq "8 no github call without timeout" "$(count_gh)" 0
grep -q '"reason":"no-timeout-on-PATH"' "$JSONL" && pass "8 the skip names the missing bound" || fail "8 skip reason absent"
_operator_alert clear notmo-key "x" >/dev/null 2>&1

echo "=== 9. FAIL-OPEN: an unwritable state dir loses the record, never the caller or the bell ==="
: > "$BELLCAP"
RO="$WORK/ro"; mkdir -p "$RO"; chmod 500 "$RO"
if [[ -w "$RO" ]]; then
    th_skip "9 unwritable-dir arm" "running as a user who can write a mode-500 dir (root?)"
else
    STATE_DIR="$RO" _operator_alert raise ro-key critical "state dir is read-only"
    rc=$?
    assert_eq "9 raise returns 0 with an unwritable state dir" "$rc" 0
    assert_eq "9 the bell still rang" "$(count_lines "$BELLCAP")" 1
    [[ ! -e "$RO/operator-alerts.jsonl" ]] && pass "9 (and no record could be written — the record is the leg that was lost, not the bell)" || fail "9 a record was written into a mode-500 dir?"
fi
chmod 700 "$RO" 2>/dev/null || true

echo "=== 10. push command missing: recorded as push-skipped, everything else proceeds ==="
gh_reset
_OPERATOR_ALERT_PUSH_CMD="$WORK/no-such-notify" _operator_alert raise nopush-key critical "m"
wait_gh 2 && pass "10 github leg still ran" || fail "10 github leg did not run"
wait_lines "$JSONL" 1 && true
sleep 0.5
grep -q '"event":"push-skipped".*"reason":"no-notify-cmd"' "$JSONL" && pass "10 push-skipped recorded with reason" || fail "10 push skip not recorded"
_operator_alert clear nopush-key "x" >/dev/null 2>&1

echo "=== 11. since/standing verbs ==="
_operator_alert raise since-key critical "m" >/dev/null 2>&1
s=$(_operator_alert since since-key)
[[ "$s" =~ ^[0-9]+$ ]] && pass "11 since prints the first-raised epoch ($s)" || fail "11 since printed '$s'"
if _operator_alert standing since-key; then pass "11 standing is true while raised"; else fail "11 standing false while raised"; fi
if _operator_alert since no-such-key >/dev/null; then fail "11 since on an unknown key returned 0"; else pass "11 since on an unknown key returns non-zero"; fi
_operator_alert clear since-key "x" >/dev/null 2>&1

echo "=== 12. board context: the supervisor's arm state rides on the message ==="
_watcher_heartbeat_age() {   # fixture: age of a file, 1e9 when absent (the real helper's contract)
    [[ -f "$1" ]] || { printf '%d' 1000000000; return 0; }
    printf '%d' $(( $(date +%s) - $(date +%s -r "$1") ))
}
HB="$WORK/sup-hb"
WATCHER_SUPERVISOR_HEARTBEAT="$HB" ctx=$(_operator_alert_context)
[[ "$ctx" == *"UNARMED (no heartbeat)"* ]] && pass "12 no heartbeat → UNARMED (no heartbeat)" || fail "12 got '$ctx'"
: > "$HB"
WATCHER_SUPERVISOR_HEARTBEAT="$HB" ctx=$(_operator_alert_context)
[[ "$ctx" == *"ARMED (heartbeat"* ]] && pass "12 fresh heartbeat → ARMED" || fail "12 got '$ctx'"
touch -d '10 minutes ago' "$HB"
WATCHER_SUPERVISOR_HEARTBEAT="$HB" ctx=$(_operator_alert_context)
[[ "$ctx" == *"UNARMED for "* ]] && pass "12 stale heartbeat → UNARMED for Ns" || fail "12 got '$ctx'"
ctx=$(WATCHER_SUPERVISOR_HEARTBEAT= _operator_alert_context)
[[ -z "$ctx" ]] && pass "12 no heartbeat path configured → empty clause" || fail "12 got '$ctx'"

echo "=== 13. the record is one JSON object per line (every row parses) ==="
if command -v python3 >/dev/null 2>&1; then
    bad=$(python3 -c '
import json,sys
n=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: json.loads(line)
    except Exception: n+=1
print(n)' "$JSONL")
    assert_eq "13 unparseable rows in operator-alerts.jsonl" "$bad" 0
else
    th_skip "13 jsonl parse check" "python3 absent"
fi

echo "=== 15. notify: an EVENT — record + bell + push, no stamp, no issue ==="
: > "$BELLCAP"; : > "$PUSH_CALLS"; gh_reset
_operator_alert notify auth-dialog-escaped critical "the watcher sent Escape into an abandoned /login"
assert_eq "15 notify records an event row" "$(jsonl_count notify)" 1
assert_eq "15 critical notify rings" "$(count_lines "$BELLCAP")" 1
wait_lines "$PUSH_CALLS" 1 && pass "15 notify pushes" || fail "15 no push"
grep -q -- '--priority emergency' "$PUSH_CALLS" && pass "15 …at emergency priority" || fail "15 priority: $(cat "$PUSH_CALLS")"
assert_eq "15 notify files NO issue (an event has nothing to close)" "$(count_gh)" 0
[[ ! -e "$STATE_DIR/operator-alert/auth-dialog-escaped.stamp" ]] && pass "15 notify leaves no stamp" || fail "15 stamp written by notify"
if _operator_alert standing auth-dialog-escaped; then fail "15 an event reads as standing"; else pass "15 an event is not a standing condition"; fi

echo "=== 16. due: the cheap pre-check a 5 s caller uses before composing a message ==="
if _operator_alert due due-key; then pass "16 an unraised key is due"; else fail "16 unraised key not due"; fi
_operator_alert raise due-key critical "m" >/dev/null 2>&1
if _operator_alert due due-key; then fail "16 a just-raised key is due inside the reminder window"; else pass "16 inside the reminder window the key is NOT due"; fi
export MONITOR_OPERATOR_ALERT_REMINDER_SECONDS=1; sleep 2
if _operator_alert due due-key; then pass "16 past the reminder window the key is due again"; else fail "16 not due past the window"; fi
unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS
if _operator_alert due 'Bad Key'; then fail "16 a bad key reads as due"; else pass "16 a bad key is never due"; fi
_operator_alert clear due-key "x" >/dev/null 2>&1

echo "=== 17. a FLAPPING condition files ONE issue: hold-down absorbs fast flaps, slow flaps REOPEN ==="
gh_reset; : > "$BELLCAP"; : > "$PUSH_CALLS"
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=3
# Six fast flaps (raise, clear, raise, clear …) well inside the 3 s hold-down.
for i in 1 2 3 4 5 6; do
    _operator_alert raise flap-key critical "the condition (flap $i)"
    _operator_alert clear flap-key "absent (flap $i)"
done
assert_eq "17 six fast flaps CREATED exactly one issue" "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=' "$GH_CALLS")" 1
assert_eq "17 …and CLOSED nothing (every clear was still pending)" "$(grep -c -- '-f state=closed' "$GH_CALLS")" 0
assert_eq "17 …and rang ONCE" "$(count_lines "$BELLCAP")" 1
assert_eq "17 …and pushed ONCE" "$(count_lines "$PUSH_CALLS")" 1
assert_eq "17 the flaps are RECORDED (5 cancelled pending clears)" "$(jsonl_count flap)" 5
if _operator_alert standing flap-key; then pass "17 the key is still standing through the flaps"; else fail "17 key lost"; fi
# Now the condition stays absent past the hold-down: the clear finalises.
sleep 4
_operator_alert clear flap-key "absent for good"
assert_eq "17 a clear past the hold-down FINALISES (one close)" "$(grep -c -- '-f state=closed' "$GH_CALLS")" 1
if _operator_alert standing flap-key; then fail "17 still standing after the finalised clear"; else pass "17 …and the key is no longer standing"; fi
# A SLOW flap: the condition returns after the issue was closed → REOPEN, never a second issue.
_operator_alert raise flap-key critical "the condition is back"
assert_eq "17 the return REOPENS the closed issue" "$(grep -c -- '-f state=open' "$GH_CALLS")" 1
assert_eq "17 …and STILL only one issue was ever created" "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=' "$GH_CALLS")" 1
grep -q '"action":"reopened"' "$JSONL" && pass "17 the reopen is recorded" || fail "17 no reopen record"
assert_eq "17 the issue table holds ONE row for the key" "$(grep -c 'operator-alert: flap-key' "$GH_ISSUES")" 1
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
_operator_alert clear flap-key "x" >/dev/null 2>&1

echo "=== 17b. the PRODUCTION call shape — `due && raise` — absorbs flaps too (skeptic oplivesk F1) ==="
# Every production caller gates the raise on `due`. The first cut of `due`
# ignored a pending clear, so the cancellation in `raise` was unreachable and
# the pending clear finalised across a condition that was PRESENT. §17 above
# calls raise directly and could not see it; this drives the real shape.
gh_reset; : > "$BELLCAP"; : > "$PUSH_CALLS"
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=3
flaps_before=$(jsonl_count flap)
prod_raise() { if _operator_alert due "$1"; then _operator_alert raise "$1" critical "$2"; fi; }
for i in 1 2 3 4 5 6 7 8 9 10; do
    prod_raise dueflap-key "the condition (flap $i)"
    _operator_alert clear dueflap-key "absent (flap $i)"
done
# WHICH of these discriminate (skeptic oplivesk2 G3, measured under mutant N1):
# the bell / push / close counts below stay GREEN with the F1 fix reverted,
# because this loop finishes inside the 3 s hold-down so nothing can finalise
# either way. They are regression pins on the healthy shape, not the kill.
# The assertions that DIE under N1 are the flap-record count and the
# "present across the hold-down" arm further down.
assert_eq "17b ten due-gated flaps rang ONCE (was 4)" "$(count_lines "$BELLCAP")" 1
assert_eq "17b …pushed ONCE (was 7)" "$(count_lines "$PUSH_CALLS")" 1
assert_eq "17b …closed NOTHING (was 3 close+reopen)" "$(grep -c -- '-f state=closed' "$GH_CALLS")" 0
assert_eq "17b …created exactly one issue" "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=' "$GH_CALLS")" 1
assert_eq "17b …and recorded 9 flaps (was 0)" "$(( $(jsonl_count flap) - flaps_before ))" 9
# The condition is PRESENT across the hold-down: due-gated raises must keep
# cancelling, so a clear can never finalise over a standing condition.
prod_raise dueflap-key "present"; sleep 4; prod_raise dueflap-key "still present"
_operator_alert clear dueflap-key "first absent after a long presence"
if _operator_alert standing dueflap-key; then pass "17b a single clear after a long PRESENCE only starts the hold-down"; else fail "17b the clear finalised at once — a stale pending mark survived the presence"; fi
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
_operator_alert clear dueflap-key "x" >/dev/null 2>&1

echo "=== 18. comment rate cap: reminders comment at most once per interval; close/reopen never capped ==="
gh_reset
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=3600 MONITOR_OPERATOR_ALERT_REMINDER_SECONDS=1
_operator_alert raise cap-key critical "m"            # files (the body counts as the first comment)
sleep 2; _operator_alert raise cap-key critical "m"   # reminder #2
sleep 2; _operator_alert raise cap-key critical "m"   # reminder #3
assert_eq "18 two reminders inside the interval posted NO comment" "$(grep -c -- '/issues/41/comments' "$GH_CALLS")" 0
assert_eq "18 …and both were recorded as capped" "$(jsonl_count github-comment-capped)" 2
assert_eq "18 …while the bell still rang for each reminder (the cap is on GitHub comments only)" "$(jsonl_count raise)" "$(( $(jsonl_count raise) ))"
_operator_alert clear cap-key "done"
assert_eq "18 the close is NOT capped (state changes always land)" "$(grep -c -- '-X PATCH /repos/acme/nexus-fixture/issues/41 -f state=closed' "$GH_CALLS")" 1
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=0; unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS

echo "=== 19. GitHub unreachable / rate-limited: recorded as github-failed; record + bell already landed; rc 0 ==="
gh_reset; : > "$BELLCAP"
GH_FAIL=1 _operator_alert raise ghdown-key critical "github is down"
rc=$?
assert_eq "19 raise returns 0 with GitHub failing" "$rc" 0
assert_eq "19 the bell rang anyway" "$(count_lines "$BELLCAP")" 1
grep -q '"event":"raise".*"key":"ghdown-key"' "$JSONL" && pass "19 the durable record landed" || fail "19 no record"
grep -q '"event":"github-failed".*"reason":"list-failed"' "$JSONL" && pass "19 the failure is RECORDED with its reason (list-failed)" || fail "19 no github-failed record: $(tail -n3 "$JSONL")"
assert_eq "19 no issue was created" "$(grep -c . "$GH_ISSUES")" 0
GH_FAIL=1 _operator_alert clear ghdown-key "x" >/dev/null 2>&1

echo "=== 20. the dedup state survives the DISK IT LIMITS: read-only state dir (skeptic oplivesk F2) ==="
# Measured by the skeptic: RO state dir, 20 cycles → 20 bells + 20 emergency pushes.
: > "$BELLCAP"; : > "$PUSH_CALLS"; gh_reset
RO2="$WORK/ro2"; mkdir -p "$RO2"; chmod 500 "$RO2"
if [[ -w "$RO2" ]]; then
    th_skip "20 read-only state dir" "this user can write a mode-500 dir"
else
    for i in $(seq 1 20); do
        if STATE_DIR="$RO2" _operator_alert due ro2-key; then STATE_DIR="$RO2" _operator_alert raise ro2-key critical "state dir is read-only"; fi
    done
    assert_eq "20 twenty cycles on a read-only state dir rang ONCE (was 20)" "$(count_lines "$BELLCAP")" 1
    assert_eq "20 …and pushed ONCE (was 20)" "$(count_lines "$PUSH_CALLS")" 1
    # …and a DIRECT raise (no `due` in front) must be just as quiet: the memo is
    # consulted inside `raise` too. A mutation round found the due-gated loop
    # above stays green with the raise-side memo removed — `due` shields it.
    for i in $(seq 1 20); do STATE_DIR="$RO2" _operator_alert raise ro2-key critical "state dir is read-only (direct)"; done
    assert_eq "20 twenty more DIRECT raises on the read-only dir did not ring again" "$(count_lines "$BELLCAP")" 1
    assert_eq "20 …nor push again" "$(count_lines "$PUSH_CALLS")" 1
    if STATE_DIR="$RO2" _operator_alert standing ro2-key; then pass "20 a memo-only key still reads as STANDING"; else fail "20 memo-only key not standing"; fi
    STATE_DIR="$RO2" _operator_alert clear ro2-key "writable again"
    if STATE_DIR="$RO2" _operator_alert standing ro2-key; then fail "20 memo-only key survived clear"; else pass "20 …and clears"; fi
fi
chmod 700 "$RO2" 2>/dev/null || true

echo "=== 21. a ZERO-BYTE UNWRITABLE stamp (the ENOSPC shape) with the issue open: no comment storm ==="
# Measured by the skeptic: 20 cycles → 20 pushes + 20 GitHub COMMENTS (720/h).
gh_reset; : > "$BELLCAP"; : > "$PUSH_CALLS"
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=3600
printf '77\topen\toperator-alert: enospc-key\n' >> "$GH_ISSUES"
mkdir -p "$STATE_DIR/operator-alert"
: > "$STATE_DIR/operator-alert/enospc-key.stamp"; chmod 400 "$STATE_DIR/operator-alert/enospc-key.stamp"
: > "$STATE_DIR/operator-alert/enospc-key.ghcomment"; chmod 400 "$STATE_DIR/operator-alert/enospc-key.ghcomment"
if [[ -w "$STATE_DIR/operator-alert/enospc-key.stamp" ]]; then
    th_skip "21 unwritable stamp" "this user can write a mode-400 file"
else
    for i in $(seq 1 20); do
        if _operator_alert due enospc-key; then _operator_alert raise enospc-key critical "disk full"; fi
    done
    assert_eq "21 twenty cycles over an unwritable zero-byte stamp pushed ONCE (was 20)" "$(count_lines "$PUSH_CALLS")" 1
    n_c=$(grep -c -- '/issues/77/comments' "$GH_CALLS"); [[ "$n_c" =~ ^[0-9]+$ ]] || n_c=0
    if (( n_c <= 1 )); then pass "21 …and posted $n_c GitHub comment(s), not 20"; else fail "21 $n_c comments in 20 cycles"; fi
    assert_eq "21 …and rang ONCE" "$(count_lines "$BELLCAP")" 1
fi
chmod 600 "$STATE_DIR"/operator-alert/enospc-key.* 2>/dev/null; rm -f "$STATE_DIR"/operator-alert/enospc-key.*
_operator_alert_memo_clear enospc-key
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=0

echo "=== 22. two INSTANCES sharing \$TMPDIR do not silence each other (skeptic oplivesk2 G1) ==="
# The fallback memo lives under $TMPDIR, which every nexus instance on a host
# shares. Keyed on the alert key alone, instance A's memo made instance B's
# FIRST raise of the same key read as "announced recently" → a SILENT raise.
: > "$BELLCAP"; : > "$PUSH_CALLS"; gh_reset
# PREDICTED before running, with the namespace reverted: B's `due` reads not
# due, B's raise is silent (bell stays 1, push stays 1, no stamp in B), and the
# "repeat in A" count follows B's; A's own first raise must NOT flip.
RA="$WORK/rootA"; RB="$WORK/rootB"; IA="$RA/monitor/.state"; IB="$RB/monitor/.state"; mkdir -p "$IA" "$IB"
_a() { NEXUS_ROOT="$RA" STATE_DIR="$IA" MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false "$@"; }
_b() { NEXUS_ROOT="$RB" STATE_DIR="$IB" MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false "$@"; }
_a _operator_alert raise shared-key critical "instance A is logged out"
assert_eq "22 instance A's raise rings" "$(count_lines "$BELLCAP")" 1
assert_eq "22 …and pushes" "$(count_lines "$PUSH_CALLS")" 1
if _b _operator_alert due shared-key; then pass "22 the SAME key is still DUE in instance B (A's memo does not reach it)"; else fail "22 instance B reads the key as not due — A's \$TMPDIR memo leaked across instances"; fi
_b _operator_alert raise shared-key critical "instance B is logged out"
assert_eq "22 instance B's FIRST raise rings too (was SILENT)" "$(count_lines "$BELLCAP")" 2
assert_eq "22 …and PUSHES too (two distinct roots, one \$TMPDIR)" "$(count_lines "$PUSH_CALLS")" 2
[[ -f "$IB/operator-alert/shared-key.stamp" ]] && pass "22 …and B wrote its own stamp" || fail "22 no stamp in B"
assert_eq "22 …while a REPEAT in A is still silent (the namespace did not break dedup)" \
    "$(_a _operator_alert raise shared-key critical "again" >/dev/null 2>&1; count_lines "$BELLCAP")" 2
# The ROOT alone must discriminate: same (relative) state dir string, distinct roots.
: > "$BELLCAP"
NEXUS_ROOT="$RA" STATE_DIR="rel-state" MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false _operator_alert_memo_set rootkey 1 >/dev/null 2>&1
na=$(NEXUS_ROOT="$RA" STATE_DIR="rel-state" _operator_alert_memo_path rootkey raise); nb=$(NEXUS_ROOT="$RB" STATE_DIR="rel-state" _operator_alert_memo_path rootkey raise)
if [[ "$na" != "$nb" ]]; then pass "22 distinct ROOTS with an identical state-dir string get distinct memo files"; else fail "22 root does not discriminate: $na"; fi
rm -f "$na" "$nb"
_a _operator_alert clear shared-key "x" >/dev/null 2>&1
_b _operator_alert clear shared-key "x" >/dev/null 2>&1

echo "=== 23. the CLEAR TRANSITION hook fires ONCE per transition (your-org/nexus-code#1567 G2) ==="
# main.sh pulls the next emit forward on this hook, so it must fire on the
# first "absent" (not 300 s later at finalisation), and exactly once: a caller
# says "absent" every cycle, and a per-call hook would re-fire compose_emit
# every 5 s for the whole hold-down.
CLEAREDCAP="$WORK/cleared"; : > "$CLEAREDCAP"
_rec_cleared() { printf '%s %s\n' "$1" "$2" >> "$CLEAREDCAP"; }
_OPERATOR_ALERT_CLEARED_FN=_rec_cleared
export MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false MONITOR_OPERATOR_ALERT_PUSH_ENABLED=false
# (a) no hold-down: the finalising clear IS the transition.
_operator_alert raise hook-key critical "m"
first=$(_operator_alert since hook-key)
_operator_alert clear hook-key "gone"
assert_eq "23 no hold-down: the clear fires the hook once, with the first-raised epoch" "$(cat "$CLEAREDCAP")" "hook-key $first"
_operator_alert clear hook-key "still gone"
assert_eq "23 …and a clear of a key no longer standing does not fire it again" "$(count_lines "$CLEAREDCAP")" 1
# (b) with a hold-down: fires when the hold-down STARTS, not on the repeats inside it, not at finalisation.
: > "$CLEAREDCAP"; export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=2
_operator_alert raise hook-key critical "m"
_operator_alert clear hook-key "absent 1"
assert_eq "23 hold-down: the FIRST absent fires the hook (the transition)" "$(count_lines "$CLEAREDCAP")" 1
_operator_alert clear hook-key "absent 2"; _operator_alert clear hook-key "absent 3"
assert_eq "23 hold-down: repeat absents inside the hold-down do NOT" "$(count_lines "$CLEAREDCAP")" 1
sleep 3; _operator_alert clear hook-key "absent, finalising"
if _operator_alert standing hook-key; then fail "23 hold-down: the clear did not finalise"; else pass "23 hold-down: the clear finalised"; fi
assert_eq "23 hold-down: finalisation does NOT fire it a second time" "$(count_lines "$CLEAREDCAP")" 1
# (c) a flap cancels the pending clear; the NEXT first-absent is a new transition.
: > "$CLEAREDCAP"
_operator_alert raise hook-key critical "m"; _operator_alert clear hook-key "a"
_operator_alert raise hook-key critical "back"; _operator_alert clear hook-key "a again"
assert_eq "23 flap: each first-absent after a raise fires once (2)" "$(count_lines "$CLEAREDCAP")" 2
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
_operator_alert clear hook-key "x" >/dev/null 2>&1
# (d) a hook that FAILS cannot fail the caller (fail-open, #1553).
_rec_cleared_fail() { return 7; }
_OPERATOR_ALERT_CLEARED_FN=_rec_cleared_fail
_operator_alert raise hook-key critical "m"; _operator_alert clear hook-key "gone"; rc=$?
assert_eq "23 a failing hook still leaves clear at rc 0" "$rc" 0
_OPERATOR_ALERT_CLEARED_FN=_operator_alert_cleared_noop
unset MONITOR_OPERATOR_ALERT_GITHUB_ENABLED MONITOR_OPERATOR_ALERT_PUSH_ENABLED

echo "=== 24. NOTHING persistable + a SUBSHELL caller: ONE GitHub attempt, not one per cycle (your-org/nexus-code#1567 G4) ==="
# State dir AND $TMPDIR unwritable, and the caller in a subshell (the async
# service_health and self-heal callers), so every store the cadence reads is
# lost: each cycle reads as a FIRST raise. PREDICTED before running, with the
# sentinel removed: the gh call count is 3 + 19 = 22 (the first cycle files:
# open list, closed list, create; each later one re-lists and reuses) — against
# 3 with it. MUST NOT FLIP: the main-shell caller row (its in-process memo
# already bounded it) and the push count (0 either way: #1566 skips the push).
RO3="$WORK/ro3"; ROT="$WORK/ro-tmp"; mkdir -p "$RO3" "$ROT"; chmod 500 "$RO3" "$ROT"
g4_sentinel_pids() {   # pids whose argv[0] is this key's sentinel — exact match, never a substring
    local want f a0
    want=$(STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert_sentinel_name "$1")
    for f in /proc/[0-9]*/cmdline; do
        { IFS= read -r -d '' a0 < "$f"; } 2>/dev/null || continue
        [[ "$a0" == "$want" ]] && { f="${f#/proc/}"; printf '%s\n' "${f%/cmdline}"; }
    done
}
g4_reap() { local p; for p in $(g4_sentinel_pids "$1"); do kill "$p" 2>/dev/null; done; }
if [[ -w "$RO3" || -w "$ROT" ]]; then
    th_skip "24 nothing-persistable arm" "this user can write a mode-500 dir"
elif [[ ! -r /proc/self/cmdline ]]; then
    th_skip "24 nothing-persistable arm" "no /proc: the sentinel cannot be observed (the module then attempts every cycle — the pre-fix cost)"
else
    gh_reset; : > "$PUSH_CALLS"
    for i in $(seq 1 20); do
        ( if STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert due g4-key; then
              STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert raise g4-key critical "nothing can be persisted"
          fi )
    done
    assert_eq "24 twenty SUBSHELL cycles with nothing persistable made ONE GitHub attempt (3 calls; was 22)" "$(count_gh)" 3
    assert_eq "24 …and it FILED the issue on that attempt (the degraded path still reaches the operator)" \
        "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=operator-alert: g4-key' "$GH_CALLS")" 1
    assert_eq "24 …and pushed nothing (the push is the repeatable leg; #1566)" "$(count_lines "$PUSH_CALLS")" 0
    assert_eq "24 the attempt is held by exactly ONE live sentinel process" "$(g4_sentinel_pids g4-key | grep -c .)" 1
    # The sentinel IS the memory: once it is gone the next first raise attempts
    # again (one list read, REUSES the open issue — never a second one).
    g4_reap g4-key; sleep 0.3
    ( STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert raise g4-key critical "sentinel expired" )
    assert_eq "24 with the sentinel gone the next cycle attempts again (+1 list read)" "$(count_gh)" 4
    assert_eq "24 …and REUSES the open issue (still one created)" "$(grep -c -- '-f title=operator-alert: g4-key' "$GH_CALLS")" 1
    g4_reap g4-key
    # B1 (skeptic on PR #1630): the watcher raises from its MAIN process while
    # holding the instance flock on INSTANCE_LOCK_FD, and the sentinel used to
    # inherit that fd — pinning the lock after the raiser died, so a restarted
    # watcher could not start. Fixture lock only: a subshell takes an flock,
    # raises once with nothing persistable, and exits; the lock must be free.
    G4LOCK="$WORK/g4-instance.lock"; : > "$G4LOCK"
    gh_reset
    ( exec 7>"$G4LOCK"; flock -n 7 || exit 9; INSTANCE_LOCK_FD=7
      STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert raise g4-lock critical "lock holder raises" )
    sleep 0.3
    if flock -n "$G4LOCK" true; then g4_free=free; else g4_free=HELD; fi
    assert_eq "24 B1 the raiser's instance flock is FREE once it exits (the sentinel does not inherit it)" "$g4_free" free
    g4_fds=$(for p in $(g4_sentinel_pids g4-lock); do ls /proc/"$p"/fd 2>/dev/null; done | sort -n | tr '\n' ' ')
    assert_eq "24 B1 the sentinel holds only fds 0 1 2" "$g4_fds" "0 1 2 "
    g4_reap g4-lock
    # CONTROL (must not flip): a MAIN-SHELL caller in the same configuration was
    # already bounded by its in-process memo — one attempt, 20 cycles.
    gh_reset
    for i in $(seq 1 20); do
        if STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert due g4-main-key; then
            STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert raise g4-main-key critical "nothing can be persisted"
        fi
    done
    assert_eq "24 control: a main-shell caller makes one attempt too (3 calls)" "$(count_gh)" 3
    g4_reap g4-main-key
    STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert_memo_clear g4-main-key
fi
chmod 700 "$RO3" "$ROT" 2>/dev/null || true

echo "=== 14. the PRODUCTION default is DETACHED: raise returns before a slow push leg finishes ==="
: > "$PUSH_CALLS"
cat > "$WORK/bin/notify-slow" <<'EOF'
#!/usr/bin/env bash
sleep 3
printf '%s\n' "$*" >> "$PUSH_CALLS"
exit 0
EOF
chmod +x "$WORK/bin/notify-slow"
t0=$(date +%s%N)
_OPERATOR_ALERT_NETWORK_SYNC=0 MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false \
    _OPERATOR_ALERT_PUSH_CMD="$WORK/bin/notify-slow" _operator_alert raise detached-key critical "slow leg"
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if (( ms < 1500 )); then pass "14 raise returned in ${ms} ms while the push leg sleeps 3 s (detached)"; else fail "14 raise BLOCKED for ${ms} ms on the push leg — the watcher's 5 s task would stall on the network"; fi
wait_lines "$PUSH_CALLS" 1 8 && pass "14 …and the detached push still landed" || fail "14 the detached push never landed"
_OPERATOR_ALERT_NETWORK_SYNC=0 MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false MONITOR_OPERATOR_ALERT_PUSH_ENABLED=false \
    _operator_alert clear detached-key "x" >/dev/null 2>&1

# Reap anything the detached legs left (they exit on their own; this is belt
# and braces so the suite never leaves a child behind).
wait 2>/dev/null || true
th_summary_and_exit
