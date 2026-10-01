#!/usr/bin/env bash
# Tests for the session-identity half of monitor/watcher/_over_limit.sh
# (issue #161): an over-limit stamp must not outlive the session it
# describes.
#
# The defect: a context rotation retires the orchestrator session and
# cold-spawns a replacement into a tmux window of the SAME name. Every
# identity test in the module was a name lookup, so the row survived.
# The fresh session then received its predecessor's usage-limit
# recovery brief, and a rotation inside a live hold handed it the
# predecessor's emit suppression as well.
#
# Coverage:
#   - the row carries the session that owned the pane when stamped
#   - a rotation drops the row with NO paste and NO brief
#   - the same session still gets its genuine recovery brief
#   - the pause predicate stops suppressing on a rotated row, without
#     waiting for the wake loop
#   - the drop retires the hook-written per-window JSON stamp
#   - the drop REMOVES the state file rather than truncating it
#   - an unknown session id on either side never drops a hold
#   - eight-field rows written by an older revision still parse
#
# Every assertion here is mutation-tested: see the mutation table in
# the pull request for #161. Run one against a mutated module with
#
#   OVER_LIMIT_SRC=/path/to/mutant.sh bash test-over-limit-rotation.sh
#
# Run: bash monitor/watcher/test-over-limit-rotation.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
# OVER_LIMIT_SRC points the suite at a MUTATED copy of the module,
# which is how these assertions are shown to pin the module rather than
# the fixtures. Default is the module in THIS checkout — resolved from
# the test's own path, never from $NEXUS_ROOT, so the suite cannot
# silently measure a different clone.
HELPER="${OVER_LIMIT_SRC:-$_repo_root/monitor/watcher/_over_limit.sh}"
IDLE="$_repo_root/monitor/watcher/_idle_probe.sh"
LIB="$_repo_root/monitor/watcher/_lib.sh"
[[ -f "$HELPER" ]] || { echo "helper not found: $HELPER" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
export STATE_DIR

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# Stubbed tmux (same shape as test-over-limit.sh). MOCK_TMUX_WINDOWS is
# `<name>|<idx>`, newline-separated.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
fmt_three() {
    local act_default
    act_default="${MOCK_TMUX_ACTIVITY_EPOCH:-$(date +%s)}"
    printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" \
        | awk -F'|' -v act="$act_default" \
            'NF>=2 && $1 != "" { printf "%s|%s|%s\n", $1, act, $2 }'
}
case "${1:-}" in
    list-windows)
        F=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -F) F="$2"; shift 2 ;;
                *)  shift ;;
            esac
        done
        if [[ "$F" == *'#{window_activity}'* && "$F" == *'#{window_index}'* ]]; then
            fmt_three
        elif [[ "$F" == *'#{window_index}'* ]]; then
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" \
                | awk -F'|' 'NF>=2 && $1 != "" { printf "%s|%s\n", $1, $2 }'
        else
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" \
                | awk -F'|' 'NF>=1 && $1 != "" { print $1 }'
        fi
        ;;
    *) :;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# Stubbed pane-state.sh. Reads MOCK_PANE_STATE_<idx> and the optional
# MOCK_PANE_RESET_AT_<idx> for the over-limit branch.
cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
while [[ "${1:-}" == --* ]]; do
    shift 2 2>/dev/null || break
done
win="${1:-}"
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
reset_key="MOCK_PANE_RESET_AT_${win//[^a-zA-Z0-9_]/_}"
state="${!key:-busy}"
reset_at="${!reset_key:-}"
if [[ -n "$reset_at" ]]; then
    printf 'state=%s active=0 window=%s name=stub reset_at=%s\n' \
        "$state" "$win" "$reset_at"
else
    printf 'state=%s active=0 window=%s name=stub\n' "$state" "$win"
fi
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"
mkdir -p "$WORK/monitor"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"
chmod +x "$WORK/monitor/pane-state.sh"
NEXUS_ROOT="$WORK"
export NEXUS_ROOT

PASTE_LOG="$WORK/paste.log"
LOG_LOG="$WORK/log.log"
LAST_BODY="$WORK/last-body.txt"
: > "$PASTE_LOG"; : > "$LOG_LOG"; : > "$LAST_BODY"
test_log() { printf '%s\n' "$*" >> "$LOG_LOG"; }
test_paste() {
    local win="$1" body="$2"
    printf '%s\n' "$win" >> "$PASTE_LOG"
    cat "$body" > "$LAST_BODY" 2>/dev/null
    return "${PASTE_RC:-0}"
}
export -f test_log test_paste

PATH="$STUB_DIR:$PATH"
export PATH

# shellcheck disable=SC1090
source "$LIB"
# shellcheck disable=SC1090
source "$IDLE"
# shellcheck disable=SC1090
source "$HELPER"
_OVER_LIMIT_LOG_FN=test_log
_OVER_LIMIT_PASTE_FN=test_paste

# --- identity fixtures ------------------------------------------------
#
# Two claude session ids. S1 is the predecessor that hit the limit; S2
# is the replacement a rotation cold-spawns into the same window.
S1='11111111-1111-4111-8111-111111111111'
S2='22222222-2222-4222-8222-222222222222'

# The StopFailure hook's per-window stamp (monitor/hooks/over-limit-emit.sh).
write_stamp() { # window session_id
    local win="$1" sid="$2"
    mkdir -p "$STATE_DIR/over-limit"
    printf '{"ts": %s, "session_id": "%s", "error_type": "rate_limit", "error_message": "You have hit your weekly limit", "reset_at": "3am_America/Los_Angeles", "window": "%s", "hook_event_name": "StopFailure"}\n' \
        "$(date +%s)" "$sid" "$win" > "$STATE_DIR/over-limit/$win.json"
}
# The UserPromptSubmit pin (monitor/hooks/orchestrator-session-pin.sh).
write_pin() { printf '%s\n' "$1" > "$STATE_DIR/orchestrator-session-id"; }
# The worker heartbeat (monitor/worker-heartbeat.sh).
write_heartbeat() { # window session_id
    mkdir -p "$STATE_DIR/heartbeat"
    printf '{"ts": %s, "event": "turn_end", "session_id": "%s", "window": "%s"}\n' \
        "$(date +%s)" "$2" "$1" > "$STATE_DIR/heartbeat/$1.json"
}

reset_state() {
    : > "$PASTE_LOG"; : > "$LOG_LOG"; : > "$LAST_BODY"
    rm -f "$STATE_DIR/over-limit-state.tsv"
    rm -rf "$STATE_DIR/over-limit" "$STATE_DIR/heartbeat"
    rm -f "$STATE_DIR/orchestrator-session-id"
    unset PASTE_RC
}

# Rewrite the timing fields (5,6,7) of every row in place, leaving the
# identity fields exactly as the module wrote them. Borrowed from the
# reproduction harness attached to #161.
retime_rows() { # reset_epoch first_seen next_attempt
    local path; path=$(_over_limit_state_path)
    awk -F'\t' -v OFS='\t' -v re="$1" -v fs="$2" -v na="$3" \
        '{ $5=re; $6=fs; $7=na; print }' "$path" > "$path.tmp" \
        && mv "$path.tmp" "$path"
}

row_field() { awk -F'\t' -v n="$2" 'NR==1 {print $n}' <<<"$1"; }

NOW=$(date +%s)
HOLD=5628   # the duration reported by the 2026-09-10 field occurrence

echo "=== module under test: $HELPER ==="

# ---------------------------------------------------------------------
echo '=== the row records the session that owned the pane ==='
reset_state
export MOCK_TMUX_WINDOWS='orchestrator|0'
export MOCK_PANE_STATE_0='over-limit'
export MOCK_PANE_RESET_AT_0='3am_America/Los_Angeles'
write_pin "$S1"
write_stamp "orchestrator" "$S1"
_over_limit_scan_panes "orchestrator"
row=$(_over_limit_load "_orchestrator")
assert_eq "R1 row keeps the _orchestrator key" "$(row_field "$row" 1)" "_orchestrator"
assert_eq "R2 row records the suspended session id" "$(row_field "$row" 9)" "$S1"

echo '=== the session id falls back to the live pin when no stamp exists ==='
reset_state
write_pin "$S1"
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
row=$(_over_limit_load "_orchestrator")
assert_eq "R3 pin supplies the id when the hook wrote no stamp" \
    "$(row_field "$row" 9)" "$S1"

echo '=== a refresh does not erase a known session id ==='
reset_state
write_pin "$S1"
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
rm -f "$STATE_DIR/orchestrator-session-id"
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
row=$(_over_limit_load "_orchestrator")
assert_eq "R4 refresh with no readable id keeps the recorded one" \
    "$(row_field "$row" 9)" "$S1"

echo '=== backoff carries the session id through a rewrite ==='
reset_state
write_pin "$S1"
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
_over_limit_apply_backoff "_orchestrator" "orchestrator" "orchestrator" "3am" \
    "$(( NOW + 600 ))" "$(( NOW - 60 ))" 1 "$NOW"
row=$(_over_limit_load "_orchestrator")
assert_eq "R5 backoff rewrite preserves the session id" \
    "$(row_field "$row" 9)" "$S1"
assert_eq "R5b backoff rewrite still preserves attempts" \
    "$(row_field "$row" 8)" "1"

# ---------------------------------------------------------------------
echo '=== ROTATION: a replaced session gets no inherited brief ==='
reset_state
export MOCK_TMUX_WINDOWS='orchestrator|0'
export MOCK_PANE_STATE_0='over-limit'
export MOCK_PANE_RESET_AT_0='3am_America/Los_Angeles'
write_pin "$S1"
write_stamp "orchestrator" "$S1"
_over_limit_scan_panes "orchestrator"
# Age the hold so the wake is due, exactly as the field occurrence had it.
retime_rows $(( NOW - 300 )) $(( NOW - HOLD )) $(( NOW - 1 ))
# THE ROTATION. The session is replaced; the window name is not. The
# cold-spawned session pins its own id on its first turn and probes idle.
write_pin "$S2"
export MOCK_PANE_STATE_0='idle'
unset MOCK_PANE_RESET_AT_0
: > "$PASTE_LOG"; : > "$LOG_LOG"; : > "$LAST_BODY"
_over_limit_process_wakes "orchestrator"
pastes=$(cat "$PASTE_LOG"); logs=$(cat "$LOG_LOG"); body=$(cat "$LAST_BODY")
assert_empty "T1 the fresh session receives NO paste" "$pastes"
assert_not_contains "T2 no usage-limit recovery brief is composed" \
    "$body" "WATCHER: USAGE-LIMIT RECOVERY"
assert_contains "T3 the drop is logged as a session replacement" \
    "$logs" "no longer occupies the pane"
if _over_limit_load "_orchestrator" >/dev/null 2>&1; then
    printf '  FAIL: T4 the inherited row is dropped\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T4 the inherited row is dropped\n'; PASS=$(( PASS + 1 ))
fi
# A repair must REMOVE the file: callers use `[[ -f <path> ]]` as the
# "are there any rows?" probe, so an empty file reads as "rows exist".
assert_no_file "T5 the state file is removed, not truncated" \
    "$(_over_limit_state_path)"
assert_no_file "T6 the per-window JSON stamp is retired with the row" \
    "$STATE_DIR/over-limit/orchestrator.json"

echo '=== ROTATION: the check does not wait for the wake to come due ==='
reset_state
write_pin "$S1"
write_stamp "orchestrator" "$S1"
export MOCK_TMUX_WINDOWS='orchestrator|0'
export MOCK_PANE_STATE_0='over-limit'
export MOCK_PANE_RESET_AT_0='3am_America/Los_Angeles'
_over_limit_scan_panes "orchestrator"
# A LIVE hold: the deadline is an hour out, so the wake is NOT due.
retime_rows $(( NOW + 3600 )) $(( NOW - 600 )) $(( NOW + 3900 ))
if _over_limit_orchestrator_paused; then
    printf '  PASS: T7 the live hold suppresses its own session\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: T7 the live hold suppresses its own session\n' >&2; FAIL=$(( FAIL + 1 ))
fi
write_pin "$S2"          # the rotation lands INSIDE the hold
if _over_limit_orchestrator_paused; then
    printf '  FAIL: T8 a rotated row stops suppressing at once\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T8 a rotated row stops suppressing at once\n'; PASS=$(( PASS + 1 ))
fi
export MOCK_PANE_STATE_0='idle'
unset MOCK_PANE_RESET_AT_0
: > "$PASTE_LOG"; : > "$LOG_LOG"
_over_limit_process_wakes "orchestrator"
if _over_limit_load "_orchestrator" >/dev/null 2>&1; then
    printf '  FAIL: T9 the not-yet-due row is dropped on rotation\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T9 the not-yet-due row is dropped on rotation\n'; PASS=$(( PASS + 1 ))
fi
assert_empty "T10 dropping a not-yet-due row pastes nothing" "$(cat "$PASTE_LOG")"

# ---------------------------------------------------------------------
echo '=== NO rotation: a genuine recovery still gets its brief ==='
reset_state
write_pin "$S1"
write_stamp "orchestrator" "$S1"
export MOCK_TMUX_WINDOWS='orchestrator|0'
export MOCK_PANE_STATE_0='over-limit'
export MOCK_PANE_RESET_AT_0='3am_America/Los_Angeles'
_over_limit_scan_panes "orchestrator"
retime_rows $(( NOW - 300 )) $(( NOW - HOLD )) $(( NOW - 1 ))
# The SAME session recovers when the limit resets. The pin does not move.
export MOCK_PANE_STATE_0='idle'
unset MOCK_PANE_RESET_AT_0
: > "$PASTE_LOG"; : > "$LOG_LOG"; : > "$LAST_BODY"
_over_limit_process_wakes "orchestrator"
body=$(cat "$LAST_BODY")
assert_contains "N1 the same session is pasted its recovery brief" \
    "$(cat "$PASTE_LOG")" "orchestrator"
assert_contains "N2 the brief is the usage-limit recovery brief" \
    "$body" "WATCHER: USAGE-LIMIT RECOVERY"
# The duration must be computed from the row's own first_seen. Range-
# checked rather than pinned to a literal: the wake runs a second or
# two after the fixture is built, so an exact string is flaky. The
# window is tight enough that a constant would fall outside it.
_dur=$(sed -n 's/.*— \([0-9]*\)h \([0-9]*\)m \([0-9]*\)s.*/\1 \2 \3/p' <<<"$body" | head -n1)
read -r _dh _dm _ds <<<"${_dur:-}"
_dsecs=$(( ${_dh:-0} * 3600 + ${_dm:-0} * 60 + ${_ds:-0} ))
if (( _dsecs >= HOLD && _dsecs <= HOLD + 300 )); then
    printf '  PASS: N3 the brief reports the hold duration from first_seen\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: N3 the brief reports the hold duration from first_seen — got %ss, want %s..%ss\n' \
        "$_dsecs" "$HOLD" "$(( HOLD + 300 ))" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== NO rotation: a padded id is the SAME session, not a new one ==='
# The pin writer applies a canonical UUID shape guard; the stamp writer
# applies none, so a hook payload carrying a padded `session_id` reaches
# the row verbatim unless both readers normalise. Two spellings of one
# session must not read as a rotation: that drops a LIVE hold and
# resumes emits into a frozen pane. Skeptic finding, request 002.
reset_state
write_pin "$S1"
mkdir -p "$STATE_DIR/over-limit"
printf '{"ts": %s, "session_id": "%s ", "error_type": "rate_limit", "reset_at": "3am", "window": "orchestrator", "hook_event_name": "StopFailure"}\n' \
    "$(date +%s)" "$S1" > "$STATE_DIR/over-limit/orchestrator.json"
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
row=$(_over_limit_load "_orchestrator")
assert_eq "P1 a padded stamp id is stored normalised" "$(row_field "$row" 9)" "$S1"
if _over_limit_session_rotated "orchestrator" "orchestrator" "$S1 "; then
    printf '  FAIL: P2 a padded id does not read as a rotation\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: P2 a padded id does not read as a rotation\n'; PASS=$(( PASS + 1 ))
fi
if _over_limit_orchestrator_paused; then
    printf '  PASS: P3 the live hold survives a padded id\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: P3 the live hold survives a padded id\n' >&2; FAIL=$(( FAIL + 1 ))
fi

echo '=== NO evidence: an unknown id on either side holds the row ==='
reset_state
write_pin "$S1"
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
rm -f "$STATE_DIR/orchestrator-session-id"   # the pane names no session
if _over_limit_orchestrator_paused; then
    printf '  PASS: N4 an unreadable live id does not drop the hold\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: N4 an unreadable live id does not drop the hold\n' >&2; FAIL=$(( FAIL + 1 ))
fi
reset_state
# A row from an older revision: eight fields, no session id at all.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles" \
    $(( NOW + 3600 )) $(( NOW - 600 )) $(( NOW + 3900 )) 0 \
    > "$(_over_limit_state_path)"
write_pin "$S2"
if _over_limit_orchestrator_paused; then
    printf '  PASS: N5 an eight-field legacy row still suppresses\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: N5 an eight-field legacy row still suppresses\n' >&2; FAIL=$(( FAIL + 1 ))
fi
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles"
row=$(_over_limit_load "_orchestrator")
assert_eq "N6 a legacy row's attempts field parses intact" "$(row_field "$row" 8)" "0"
assert_eq "N6b a legacy row's first_seen is preserved on refresh" \
    "$(row_field "$row" 6)" "$(( NOW - 600 ))"

# ---------------------------------------------------------------------
echo '=== WORKERS: a re-used window name does not inherit the hold ==='
reset_state
export MOCK_TMUX_WINDOWS=$'orchestrator|0\nnexus-158|3'
export MOCK_PANE_STATE_0='idle'
export MOCK_PANE_STATE_3='over-limit'
export MOCK_PANE_RESET_AT_3='3am_America/Los_Angeles'
write_heartbeat "nexus-158" "$S1"
write_stamp "nexus-158" "$S1"
_over_limit_scan_panes "orchestrator"
wrow=$(_over_limit_load "nexus-158")
assert_eq "W1 the worker row records its session id" "$(row_field "$wrow" 9)" "$S1"
retime_rows $(( NOW - 300 )) $(( NOW - HOLD )) $(( NOW - 1 ))
# The window is retired and a NEW worker takes the same name.
write_heartbeat "nexus-158" "$S2"
export MOCK_PANE_STATE_3='busy'
: > "$PASTE_LOG"; : > "$LOG_LOG"
_over_limit_process_wakes "orchestrator"
assert_empty "W2 the new occupant receives no wake paste" "$(cat "$PASTE_LOG")"
if _over_limit_load "nexus-158" >/dev/null 2>&1; then
    printf '  FAIL: W3 the stale worker row is dropped\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: W3 the stale worker row is dropped\n'; PASS=$(( PASS + 1 ))
fi

echo '=== WORKERS: a retired window retires its JSON stamp too ==='
reset_state
export MOCK_TMUX_WINDOWS=$'orchestrator|0\nnexus-158|3'
export MOCK_PANE_STATE_0='idle'
export MOCK_PANE_STATE_3='over-limit'
export MOCK_PANE_RESET_AT_3='3am_America/Los_Angeles'
_over_limit_scan_panes "orchestrator"
write_stamp "nexus-158" "$S1"
retime_rows $(( NOW - 300 )) $(( NOW - HOLD )) $(( NOW - 1 ))
export MOCK_TMUX_WINDOWS='orchestrator|0'   # the window leaves tmux
: > "$PASTE_LOG"; : > "$LOG_LOG"
_over_limit_process_wakes "orchestrator"
assert_contains "W4 the absent window drops its stamp" \
    "$(cat "$LOG_LOG")" "absent at wake; dropping stamp"
assert_no_file "W5 the absent window's JSON stamp is retired" \
    "$STATE_DIR/over-limit/nexus-158.json"

echo '=== the drop retires the stamp for a role-keyed row ==='
reset_state
write_pin "$S1"
write_stamp "orchestrator" "$S1"
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
_over_limit_drop "_orchestrator"
assert_no_file "D1 a key-only drop finds the window on the row" \
    "$STATE_DIR/over-limit/orchestrator.json"
assert_no_file "D2 the state file is removed by the drop" \
    "$(_over_limit_state_path)"

echo '=== the drop leaves another window'"'"'s stamp alone ==='
reset_state
write_pin "$S1"
write_stamp "orchestrator" "$S1"
write_stamp "nexus-158" "$S1"
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
_over_limit_record "nexus-158" "nexus-158" "worker" "3am"
_over_limit_drop "_orchestrator"
assert_file_exists "D3 a sibling window keeps its stamp" \
    "$STATE_DIR/over-limit/nexus-158.json"
assert_contains "D4 the sibling row survives" \
    "$(_over_limit_load "nexus-158")" "nexus-158"

th_summary_and_exit
