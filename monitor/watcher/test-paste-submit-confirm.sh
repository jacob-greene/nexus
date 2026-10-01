#!/usr/bin/env bash
# Hermetic tests for the watcher's paste submit confirmation
# (jacob-greene/nexus#221): `_paste_input_holds_sig`,
# `_paste_submit_confirm`, and their call in `paste_to_target`
# (monitor/watcher/main.sh).
#
# Background: Claude Code 2.1.277 onward swallows the first Enter after
# a small multi-line plain paste. The emit text lands (the signature is
# visible) but sits in the input box unsent, so the watcher reported a
# good paste and the orchestrator never saw it. The fix presses Enter
# once more when the signature is still on or below the input chevron.
#
# `tmux` is a shell-function stub. The pane it renders depends on how
# many Enters the stub has seen, so each case models one TUI behaviour.
#
# Run: bash monitor/watcher/test-paste-submit-confirm.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_main_sh="$_test_dir/main.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

NBSP=$'\xc2\xa0'
SIG="nexus-emit-sig 2026-09-25T17:53:39-07:00 1a3bcc"
BODY="$WORK/body.txt"
printf '=== nexus state changed (poll-full-state) ===\nworkspace: 1 busy\n--- %s ---\n' "$SIG" > "$BODY"

ENTERS="$WORK/enters"
LOGF="$WORK/log"
MODE=""          # healthy | swallow-one | never

# Pane with the emit still in the input box (below the chevron).
pane_stuck() {
    printf '● earlier reply\n'
    printf '────────\n'
    printf '❯%s=== nexus state changed (poll-full-state) ===\n' "$NBSP"
    printf '  workspace: 1 busy\n'
    printf '  --- %s ---\n' "$SIG"
    printf '────────\n'
    printf '  ⏵⏵ auto mode on\n'
}
# Pane after a submit: the emit is echoed ABOVE a fresh empty input row.
pane_submitted() {
    printf '❯%s=== nexus state changed (poll-full-state) ===\n' "$NBSP"
    printf '  --- %s ---\n' "$SIG"
    printf '✻ Working…\n'
    printf '────────\n'
    printf '❯%s\n' "$NBSP"
    printf '────────\n'
}

tmux() {
    local verb="$1"; shift
    case "$verb" in
        list-windows) printf 'orchestrator\n' ;;
        send-keys)
            [[ "${!#}" == "Enter" ]] && echo x >> "$ENTERS"
            return 0 ;;
        load-buffer|paste-buffer|delete-buffer) return 0 ;;
        capture-pane)
            local n; n=$(wc -l < "$ENTERS")
            case "$MODE" in
                healthy)     (( n >= 1 )) && pane_submitted || pane_stuck ;;
                swallow-one) (( n >= 2 )) && pane_submitted || pane_stuck ;;
                never)       pane_stuck ;;
            esac ;;
        *) return 0 ;;
    esac
}
sleep() { :; }
log() { printf '%s\n' "$*" >> "$LOGF"; }
resolve_window_id() { printf '@1\n'; }
_orchestrator_refresh_pin() { :; }
_orchestrator_record_paste() { :; }
ORCH_PIN_FILE="$WORK/pin"
ORCH_LAST_PASTE_FILE="$WORK/last-paste.ts"
TARGET=orchestrator

for fn in _paste_input_holds_sig _paste_submit_confirm paste_to_target; do
    body=$(sed -n "/^${fn}() {/,/^}/p" "$_main_sh")
    if [[ -z "$body" ]]; then
        fail "extract ${fn}() from main.sh"; echo "FAILED"; exit 1
    fi
    eval "$body"
done

run_case() {
    MODE="$1"; : > "$ENTERS"; : > "$LOGF"
    paste_to_target orchestrator "$BODY"
    RC=$?
    N_ENTER=$(wc -l < "$ENTERS")
}

echo '=== detector: _paste_input_holds_sig ==='
: > "$ENTERS"
MODE=never
_paste_input_holds_sig @1 "$SIG"; assert_eq "signature below the chevron reads as pending" "$?" "0"
MODE=healthy; echo x > "$ENTERS"
_paste_input_holds_sig @1 "$SIG"; assert_eq "signature echoed above an empty input row reads as submitted" "$?" "1"
tmux() { [[ "$1" == capture-pane ]] && printf '❯%s[Pasted text #1 +40 lines]\n' "$NBSP"; return 0; }
_paste_input_holds_sig @1 "$SIG"; assert_eq "collapsed [Pasted text #N] placeholder reads as pending" "$?" "0"
tmux() { [[ "$1" == capture-pane ]] && printf 'no chevron here\n  --- %s ---\n' "$SIG"; return 0; }
_paste_input_holds_sig @1 "$SIG"; assert_eq "no input chevron at all reads as not pending" "$?" "1"
# Restore the stateful stub.
tmux() {
    local verb="$1"; shift
    case "$verb" in
        list-windows) printf 'orchestrator\n' ;;
        send-keys) [[ "${!#}" == "Enter" ]] && echo x >> "$ENTERS"; return 0 ;;
        capture-pane)
            local n; n=$(wc -l < "$ENTERS")
            case "$MODE" in
                healthy)     (( n >= 1 )) && pane_submitted || pane_stuck ;;
                swallow-one) (( n >= 2 )) && pane_submitted || pane_stuck ;;
                never)       pane_stuck ;;
            esac ;;
        *) return 0 ;;
    esac
}

echo '=== paste_to_target: healthy TUI (first Enter submits) ==='
run_case healthy
assert_eq "rc 0" "$RC" "0"
assert_eq "exactly one Enter sent" "$N_ENTER" "1"
assert_eq "no paste-submit log line" "$(wc -l < "$LOGF")" "0"

echo '=== paste_to_target: first Enter swallowed (Claude Code >= 2.1.277) ==='
run_case swallow-one
assert_eq "rc 0 (text landed; no caller re-pastes)" "$RC" "0"
assert_eq "one retry Enter sent (2 total)" "$N_ENTER" "2"
if grep -q 'retried Enter submitted' "$LOGF"; then pass "logs the rescued submit"; else fail "logs the rescued submit"; fi

echo '=== paste_to_target: never submits (retry is bounded) ==='
run_case never
assert_eq "rc 0 (liveness state machine is the backstop)" "$RC" "0"
assert_eq "still only one retry Enter (2 total)" "$N_ENTER" "2"
if grep -q 'still unsubmitted' "$LOGF"; then pass "logs the unrescued paste"; else fail "logs the unrescued paste"; fi

echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
echo "FAILED"; exit 1
