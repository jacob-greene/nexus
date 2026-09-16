#!/usr/bin/env bash
# test-realmodel-vipaste.sh — closes the 2c hole the cc-harness gate
# leaves open.
#
# The gate's over-limit scenario asserts "recovery brief pasted on wake"
# against a STUBBED paste function (`_ol_test_paste` writes to a log), so
# no real paste ever reaches a real TUI. VI-mode drift in a Claude Code
# release would therefore pass the gate green and only surface in
# production, where a lost paste reads as a silent worker.
#
# This scenario runs the PRODUCTION paste helper
# (`_respawn_paste_prompt_file` from monitor/watcher/_respawn.sh — the
# `send-keys i BSpace` + `load-buffer` + `paste-buffer` + `Enter`
# sequence) against the REAL candidate binary booted on the auth-free
# mock, and asserts the text both LANDS in the prompt and SUBMITS.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.
#
# Run: RUN_CC_HARNESS=1 CLAUDE_BIN=<candidate> bash test-realmodel-vipaste.sh
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

echo "=== real-binary harness: VI-safe paste (2c) ==="
echo "    claude:  $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>&1 | head -1))"

WIN=$(cch_boot_worker vipaste)
[[ -n "$WIN" ]] || { echo "boot failed" >&2; exit 1; }

wait_for "candidate booted to idle" 60 -- cch_state_is "$WIN" idle \
    || { cch_capture "$WIN" | tail -15 >&2; echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1; }

MARKER="NEXUSVIPASTE-$$-canary"
PROMPT="$CCH_DIR/vipaste-prompt.txt"
printf 'Reply with exactly: %s\n' "$MARKER" > "$PROMPT"

# Source the production respawn helper and drive it through the harness's
# PATH-shadow tmux wrapper, so its bare `tmux` calls hit the isolated
# socket. This is the real sequence the watcher uses for every spawn and
# follow-up.
export PATH="$CCH_DIR/.bin:$PATH"
# shellcheck source=/dev/null
. "$REPO_ROOT/monitor/watcher/_respawn.sh" >/dev/null 2>&1

if declare -F _respawn_paste_prompt_file >/dev/null; then
    ok "production paste helper _respawn_paste_prompt_file is loadable"
else
    bad "could not load _respawn_paste_prompt_file from _respawn.sh"; exit 1
fi

if _respawn_paste_prompt_file "$CCH_SESSION:$WIN" "$PROMPT"; then
    ok "paste sequence (i BSpace + paste-buffer + Enter) returned 0"
else
    bad "paste sequence returned non-zero"
fi

# The prompt must have SUBMITTED: the pane goes busy, then the mock's
# reply carries the marker back. Either signal alone would be weak —
# a marker echoed in the input box without submitting is a lost paste.
_marker_rendered() { cch_capture "$WIN" | command grep -qF "$MARKER"; }
wait_for "pasted text reached the live TUI (marker rendered)" 30 -- _marker_rendered \
    || cch_capture "$WIN" | tail -15 >&2

# STRONGER than "the log is non-empty": the boot itself issues requests
# (session title, etc.), so a size check would pass without any submit.
# Assert the MARKER TEXT crossed the wire as a user message.
_mock_saw_marker() { command grep -qF "$MARKER" "$CCH_LOG" 2>/dev/null; }
wait_for "the paste SUBMITTED (marker text reached the mock as a request)" 60 -- _mock_saw_marker \
    || { echo "    requests seen: $(wc -l < "$CCH_LOG" 2>/dev/null)" >&2; }

# Control for that assertion: a string never pasted must NOT be in the log.
if command grep -qF "NEXUSVIPASTE-never-pasted" "$CCH_LOG" 2>/dev/null; then
    bad "control: an unpasted string appeared in the request log"
else
    ok "control: an unpasted string is absent from the request log"
fi

# Negative control: a marker that was never pasted must not appear.
if cch_capture "$WIN" | command grep -qF "NEXUSVIPASTE-never-pasted"; then
    bad "control: an unpasted marker appeared — the assertion is not specific"
else
    ok "control: an unpasted marker does not appear"
fi

echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
