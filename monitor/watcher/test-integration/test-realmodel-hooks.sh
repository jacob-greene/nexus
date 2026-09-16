#!/usr/bin/env bash
# test-realmodel-hooks.sh — closes the 2d hole the cc-harness gate leaves
# open.
#
# The gate's scenarios boot the candidate WITHOUT `--settings`
# (cch_boot_worker is documented "renderer-path only (no --settings
# hooks)"), so the hook-event contract the whole nexus control surface
# rides on is never exercised against the candidate. A renamed event, a
# changed matcher schema, or a dropped exit-2 block would pass the gate
# green and silently disable the watcher's eyes.
#
# This scenario boots the REAL candidate with a `--settings` file whose
# hooks write marker files, drives a tool call from the mock, and asserts:
#   * UserPromptSubmit, PreToolUse and Stop hooks still FIRE
#   * a PreToolUse hook that exits 2 still BLOCKS the tool call
#     (the load-bearing AskUserQuestion guard, monitor/hooks/block-askuserquestion.sh)
#   * the `"matcher"` regex-alternation syntax still selects
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.
#
# Run: RUN_CC_HARNESS=1 CLAUDE_BIN=<candidate> bash test-realmodel-hooks.sh
set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../../.." && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

cch_skip_if_disabled
cch_setup
trap cch_teardown EXIT

echo "=== real-binary harness: hook + settings contract (2d) ==="
echo "    claude:  $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>&1 | head -1))"

MK="$CCH_DIR/hookmarks"; mkdir -p "$MK"
SETTINGS="$CCH_DIR/hook-settings.json"
cat > "$SETTINGS" <<JSON
{
  "skipDangerousModePermissionPrompt": true,
  "env": { "DISABLE_AUTOUPDATER": "1" },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "touch $MK/userpromptsubmit" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash|Write|Edit|NotebookEdit",
        "hooks": [ { "type": "command",
                     "command": "touch $MK/pretooluse-matched; echo 'BLOCKED-BY-TEST-HOOK' >&2; exit 2" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "touch $MK/posttooluse-bash" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "touch $MK/stop" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "touch $MK/notification" } ] }
    ]
  }
}
JSON

# Boot with --settings. cch_boot_worker deliberately omits it, so the
# launch line is reproduced here with the flag added.
WIN=hooks
printf -v launch 'env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q \
ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 \
TERM=%q %q --settings %q --dangerously-skip-permissions' \
    "$CCH_CFG" "$PATH" "$CCH_CFG" \
    "http://127.0.0.1:$CCH_MOCK_PORT" "${TERM:-xterm-256color}" "$CLAUDE_BIN" "$SETTINGS"

cch_tmux new-window -d -t "$CCH_SESSION": -n "$WIN" -c "$CCH_WORKDIR" "$launch"
IDX=$(cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' \
    | awk -v n="$WIN" '$1==n {print $2; exit}')
[[ -n "$IDX" ]] || { bad "window did not open"; echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1; }
cch_tmux set-option -t "$CCH_SESSION:$IDX" -w remain-on-exit on 2>/dev/null

wait_for "candidate booted to idle WITH --settings" 60 -- cch_state_is "$IDX" idle \
    || { cch_capture "$IDX" | tail -15 >&2; echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1; }

# Ask the mock to answer the next request with a Bash tool_use block.
cch_control '{"mode":"tool_use","text":"running it","tool":{"name":"Bash","input":{"command":"echo hook-contract-probe"}}}'

PROMPT="$CCH_DIR/hook-prompt.txt"
printf 'run the probe command\n' > "$PROMPT"
export PATH="$CCH_DIR/.bin:$PATH"
# shellcheck source=/dev/null
. "$REPO_ROOT/monitor/watcher/_respawn.sh" >/dev/null 2>&1
_respawn_paste_prompt_file "$CCH_SESSION:$IDX" "$PROMPT" \
    && ok "prompt pasted and submitted" || bad "paste helper returned non-zero"

_mark() { [[ -e "$MK/$1" ]]; }
wait_for "UserPromptSubmit hook FIRED" 30 -- _mark userpromptsubmit
wait_for "PreToolUse hook FIRED and its matcher regex selected Bash" 45 -- _mark pretooluse-matched

# The exit-2 block is the load-bearing contract: if it stopped blocking,
# the orchestrator's AskUserQuestion guard is silently dead. A blocked
# call must NOT reach PostToolUse.
sleep 6
if _mark posttooluse-bash; then
    bad "PreToolUse exit 2 did NOT block — the tool ran (PostToolUse fired)"
else
    ok "PreToolUse exit 2 still BLOCKS the tool call (no PostToolUse)"
fi

# Control: the marker directory must not report a hook that was never
# wired, so an `[[ -e ]]` that always succeeds cannot fake the passes.
if _mark neverwired; then
    bad "control: an unwired hook marker exists — the assertion is not specific"
else
    ok "control: an unwired hook marker does not exist"
fi

# Let the turn actually END: while the control file still says
# `tool_use`, the mock re-emits the blocked call on every request and the
# turn never reaches Stop. That is a HARNESS artifact, not a candidate
# defect — switch the mock back to plain text, then assert Stop.
cch_control '{"mode":"text","text":"done"}'
wait_for "Stop hook FIRED at turn end" 90 -- _mark stop

echo "    markers present: $(ls "$MK" 2>/dev/null | tr '\n' ' ')"
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
