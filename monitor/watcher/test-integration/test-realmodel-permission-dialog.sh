#!/usr/bin/env bash
# Real-binary scenario: Claude Code's tool-permission dialog, and how
# monitor/pane-state.sh classifies it.
#
# KNOWN-FAILING BY DESIGN. The classification assertions in this file
# fail against the detector as it ships today. That is the point:
# your-org/nexus-code#157 reports that pane-state carries exactly ONE
# question literal (`Do you want to proceed?`), so both file-edit dialog
# shapes fall through and classify `empty` — the state
# retire-preflight.sh reads as safe to kill. The failures are marked
# XFAIL and do not turn the suite red; see "Expected-fail marker" below.
#
# Terms, defined on first use:
#
#   Harness      monitor/cc-harness, the scenario runner that drives the
#                real `claude` binary against an auth-free mock backend.
#   Scenario     one harness test case. This file is one.
#   Probe        a script that drives an agent pane and reads its state.
#   Frame        one `tmux capture-pane` of a worker window, plain text.
#   Vacuous      a control arm that passes without exercising the
#   control      mechanism it controls for.
#   XFAIL        an assertion known to fail, recorded as such. An XFAIL
#                that starts passing is reported as XPASS and FAILS the
#                run, so the marker cannot outlive the bug.
#
# WHAT IT ESTABLISHES.
#
#   1. The harness can now paint a real permission dialog at all. Before
#      your-org/nexus-code#158 it could not: cch_boot_worker always passed
#      `--dangerously-skip-permissions`, which is exactly the flag that
#      suppresses the dialog.
#   2. The default boot is unchanged. Arm A drives the SAME tool_use
#      through a default worker and gets no dialog. It differs from arm B
#      in one thing only, the CCH_SKIP_PERMISSIONS knob.
#   3. A frame with no dialog is caught, loudly. Arm B asserts on its own
#      idle frame BEFORE driving any tool, and requires the assertion to
#      fail. A probe that silently accepted that frame is the exact defect
#      #158 Part B is about.
#   4. pane-state misclassifies both dialog shapes. Asserted, marked
#      XFAIL, and the captured frame is printed so the reader sees the
#      bytes the classifier was given.
#
# EXPECTED-FAIL MARKER. `xfail_assert` inverts the exit meaning of the
# classification checks only:
#
#   assertion fails -> XFAIL, does not fail the run (the state today)
#   assertion passes -> XPASS, FAILS the run (fix #157, then delete the
#                       marker and use ok()/bad() like every other check)
#
# Everything else in this file — the capability, the default-unchanged
# control, the dialog assertion, the negative control — is a hard
# assertion with no marker. Set CCH_NO_XFAIL=1 to run the classification
# checks as hard assertions too, which is how you watch this scenario go
# red today and green after the #157 fix.
#
# NOT IN THE PRE-UPDATE GATE. monitor/cc-harness/gate.sh deliberately
# does not list this scenario: a gate entry that is XFAIL-marked tells an
# operator nothing about a candidate release. Add it there in the same
# change that fixes #157 and removes the marker.
set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../../.." && pwd)
# shellcheck source=/dev/null
. "$_self_dir/../../cc-harness/_lib.sh"

PASS=0; FAIL=0; XFAIL=0
ok()  { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

# xfail_assert <rc-of-the-assertion> <label>
# rc 0 means the assertion HELD. Under the marker that is an XPASS and a
# hard failure, because the bug it records is fixed.
xfail_assert() {
    local rc="$1"; shift
    if [[ "${CCH_NO_XFAIL:-0}" == "1" ]]; then
        (( rc == 0 )) && ok "$*" || bad "$*"
        return
    fi
    if (( rc == 0 )); then
        printf '  XPASS: %s\n' "$*" >&2
        printf '         This assertion is marked XFAIL for your-org/nexus-code#157.\n' >&2
        printf '         It now passes. Delete the marker and gate on it.\n' >&2
        FAIL=$((FAIL+1))
    else
        printf '  XFAIL: %s (known: your-org/nexus-code#157)\n' "$*"
        XFAIL=$((XFAIL+1))
    fi
}

cch_skip_if_disabled

echo "=== real-binary harness: tool-permission dialog ==="
printf '    claude:  %s\n' "$(cch_resolve_claude)"

cch_setup || exit 1

# The two tool_use directives. `Write` and `Edit` render DIFFERENT
# question literals — "Do you want to create <f>?" and "Do you want to
# make this edit to <f>?" — which is why #157 needs at least two more
# literals, not one.
# Each arm gets its OWN target file. The mock replays whatever directive
# is current for EVERY request, including the tool_result follow-up, so a
# worker mid-turn keeps re-driving the same tool. Two arms sharing one
# path collide on it, and the loser reports "Error writing file" instead
# of asking.
NEW_FILE_A="$CCH_WORKDIR/arm-a-new.txt"
NEW_FILE_B="$CCH_WORKDIR/arm-b-new.txt"
OLD_FILE="$CCH_WORKDIR/arm-b-existing.txt"
printf 'original\n' > "$OLD_FILE"

write_directive() {
    printf '{"mode":"tool_use","tool":{"name":"Write","input":{"file_path":"%s","content":"hello from the mock\\n"}}}' \
        "$1"
}
edit_directive() {
    printf '{"mode":"tool_use","tool":{"name":"Edit","input":{"file_path":"%s","old_string":"original","new_string":"edited"}}}' \
        "$OLD_FILE"
}

# Stop a worker re-driving the tool. Escape interrupts the turn; the
# control file goes back to plain text so the next request it makes is
# answered with a sentence, not another tool_use.
quiesce() {
    cch_control '{"mode":"text","text":"MOCK_OK_HELLO"}'
    cch_tmux send-keys -t "$CCH_SESSION:$1" Escape
    sleep 2
}

# Poll until the pane settles (idle or blocked), up to ~30s.
settle() {
    local win="$1" i st=""
    for i in $(seq 1 15); do
        sleep 2
        st=$(cch_state "$win")
        [[ "$st" == "idle" || "$st" == "blocked" ]] && break
    done
    printf '%s' "$st"
}

# ---------------------------------------------------------------------
# Arm A — DEFAULT boot. The control, and it is not vacuous: it drives
# the SAME Write tool_use as arm B. The only difference is the knob.
# ---------------------------------------------------------------------
echo
echo "--- arm A: default boot (CCH_SKIP_PERMISSIONS unset) ---"
WIN_A=$(cch_boot_worker default-perms)
[[ -n "$WIN_A" ]] || { bad "arm A: window did not open"; echo "=== summary: $PASS passed, $FAIL failed, $XFAIL xfail ==="; exit 1; }
ST_A=$(settle "$WIN_A")
[[ "$ST_A" == "idle" ]] && ok "arm A boots to idle" || bad "arm A booted '$ST_A' — expected idle"

cch_control "$(write_directive "$NEW_FILE_A")"
cch_send "$WIN_A" "Please write the file."
sleep 8
FRAME_A=$(cch_capture "$WIN_A")
if cch_has_permission_dialog "$FRAME_A"; then
    bad "arm A painted a permission dialog — the default boot changed"
else
    ok "arm A paints NO permission dialog (--dangerously-skip-permissions still in effect)"
fi
if [[ -s "$NEW_FILE_A" ]]; then
    ok "arm A wrote the file without asking (the tool ran unattended)"
else
    bad "arm A neither asked nor wrote — the mock never drove the tool"
fi
# Arm A is still looping on the tool. Stop it before arm B starts, so the
# two workers never contend for the mock or the filesystem.
quiesce "$WIN_A"

# ---------------------------------------------------------------------
# Arm B — PROMPTING boot, via the knob. No copied launch string.
# ---------------------------------------------------------------------
echo
echo "--- arm B: prompting boot (cch_boot_prompting_worker) ---"
WIN_B=$(cch_boot_prompting_worker prompting-perms)
[[ -n "$WIN_B" ]] || { bad "arm B: window did not open"; echo "=== summary: $PASS passed, $FAIL failed, $XFAIL xfail ==="; exit 1; }
ST_B=$(settle "$WIN_B")
[[ "$ST_B" == "idle" ]] && ok "arm B boots to idle" || bad "arm B booted '$ST_B' — expected idle"

# NEGATIVE CONTROL, run before any tool is driven. This idle frame is
# known to carry no dialog. The assertion MUST reject it. If it accepts
# anything, every dialog claim below is worthless.
echo
echo "--- negative control: assert against a frame known to have no dialog ---"
FRAME_IDLE_B=$(cch_capture "$WIN_B")
if cch_assert_permission_dialog "$FRAME_IDLE_B" "a dialog that was never painted" 2>/dev/null; then
    bad "the assertion ACCEPTED an idle frame — it proves nothing"
else
    ok "the assertion rejects an idle frame (rc=1, diagnostic on stderr)"
fi

# ---------------------------------------------------------------------
# The two dialog shapes.
# ---------------------------------------------------------------------
probe_dialog() {
    local win="$1" shape="$2" directive="$3" frame state
    echo
    echo "--- $shape dialog ---"
    cch_control "$directive"
    cch_send "$win" "Please $shape the file."

    # Hard assertion, no marker: either the harness painted a dialog or
    # this scenario has established nothing.
    if frame=$(cch_wait_permission_dialog "$win" 40); then
        ok "$shape: the harness painted a real permission dialog"
    else
        cch_assert_permission_dialog "$frame" "the $shape permission dialog" || true
        bad "$shape: no permission dialog appeared within 40s"
        return
    fi

    echo "    frame handed to pane-state.sh:"
    sed 's/^/      | /' <<<"$frame" | grep -v '^      | *$'

    state=$(cch_pane_state "$win")
    printf '    pane-state: %s\n' "$state"

    # XFAIL: this is #157. `blocked` is the correct answer — an overlay
    # is up and the worker cannot proceed unattended. Today the detector
    # returns `empty`, the state retire-preflight reads as safe to kill.
    [[ "$state" == *"state=blocked"* ]]
    xfail_assert $? "$shape: pane-state classifies the dialog blocked (got: ${state%% *})"

    # Dismiss so the next shape starts from a clean REPL, and stop the
    # mock re-driving the same tool.
    quiesce "$win"
}

probe_dialog "$WIN_B" Write "$(write_directive "$NEW_FILE_B")"
probe_dialog "$WIN_B" Edit  "$(edit_directive)"

echo
echo "=== summary: $PASS passed, $FAIL failed, $XFAIL xfail ==="
if (( XFAIL > 0 )); then
    echo "    $XFAIL known failure(s) recorded against your-org/nexus-code#157."
    echo "    Run with CCH_NO_XFAIL=1 to see them as hard failures."
fi
[[ "$FAIL" -eq 0 ]]
