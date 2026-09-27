#!/usr/bin/env bash
# Schema smoke-test for the two Claude Code --settings files:
#   monitor/orchestrator-settings.json
#   monitor/worker-settings.json
#
# Every spawned claude (orchestrator via watcher/entry.sh + _respawn.sh,
# workers via spawn-worker.sh) is launched with one of these files. A
# malformed file or a dropped key degrades silently: Claude Code ignores
# unparseable settings, hooks stop firing, and the watcher loses its
# liveness signals without any error. This test pins the load-bearing
# top-level schema so an accidental edit fails CI instead.
#
# Pinned per file:
#   - parses as valid JSON (jq)
#   - skipDangerousModePermissionPrompt == true   (unattended spawning)
#   - hooks is a top-level object                  (watcher monitoring)
#   - env.DISABLE_AUTOUPDATER == "1"               (top-level env block;
#     silences the built-in npm auto-updater + its "Auto-update failed"
#     banner — irrelevant to the project-local pin managed by the
#     cc-update loop, see skills/nexus.cc-update/GUIDE.md)
#   - syncClaudeAiSkills == false, syncClaudeAiPlugins == false
#     (your-org/nexus-code#1600). Since 2.1.275 Claude Code syncs the skills
#     and plugins enabled on a signed-in claude.ai account into every session,
#     and the keys are an OPT-OUT: an ABSENT key means sync is ON. So the
#     probe below distinguishes "absent" from "false" — jq's `// empty` would
#     read a correct `false` as missing. Restore per operator via the untracked
#     overlay (`*-settings.local.json`, see monitor/README.md).
#
# Mirrors the test pattern in test-block-askuserquestion-hook.sh
# (zero-dep, hand-rolled assertions).
#
# Run: bash monitor/watcher/test-settings-json.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s (got %q)\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s: got %q, want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# jq is a hard runtime dependency of the settings files themselves
# (every worker hook command pipes through jq), so requiring it here
# adds no new dependency.
command -v jq >/dev/null 2>&1 || { echo "jq not found — required by this test and by the hooks under test" >&2; exit 1; }

for name in orchestrator worker; do
    SETTINGS="$_repo_root/monitor/$name-settings.json"
    echo "=== $name-settings.json: valid JSON + load-bearing top-level keys ==="
    [[ -f "$SETTINGS" ]] || { echo "settings file missing: $SETTINGS" >&2; exit 1; }

    if jq -e . "$SETTINGS" >/dev/null 2>&1; then
        printf '  PASS: parses as valid JSON\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: does not parse as valid JSON\n' >&2
        FAIL=$(( FAIL + 1 ))
        continue
    fi

    skip_prompt=$(jq -r '.skipDangerousModePermissionPrompt' "$SETTINGS")
    hooks_type=$(jq -r '.hooks | type' "$SETTINGS")
    autoupdater=$(jq -r '.env.DISABLE_AUTOUPDATER // empty' "$SETTINGS")
    env_type=$(jq -r '.env | type' "$SETTINGS")

    assert_eq "skipDangerousModePermissionPrompt is true"      "$skip_prompt" "true"
    assert_eq "hooks is a top-level object"                    "$hooks_type"  "object"
    assert_eq "env is a top-level object (sibling of hooks)"   "$env_type"    "object"
    assert_eq "env.DISABLE_AUTOUPDATER is \"1\""               "$autoupdater" "1"
    for k in syncClaudeAiSkills syncClaudeAiPlugins; do
        v=$(jq -r --arg k "$k" 'if has($k) then (.[$k] | tostring) else "ABSENT" end' "$SETTINGS")
        assert_eq "$k is false (absent = account sync ON, #1600)" "$v" "false"
    done
done

# ---- Orchestrator-liveness heartbeat hooks -----------------------------
#
# The orchestrator-liveness state machine treats the
# `orchestrator-heartbeat` file's mtime as Signal 1 (turn-ended).
# The Stop hook bumps it at turn-END; the PostToolUse hook bumps it
# per-tool-use so a long *active* turn looks alive mid-flight (closes
# the "Stop hasn't fired yet" gap that contributed to the 2026-06-05
# false-positive respawn). Both must touch the SAME file the watcher
# reads, or the witness silently goes dark.
echo "=== orchestrator-settings.json: heartbeat hooks (liveness Signal 1) ==="
ORCH="$_repo_root/monitor/orchestrator-settings.json"
stop_touches_hb=$(jq -r '[.hooks.Stop[]?.hooks[]?.command
    | select(test("orchestrator-heartbeat"))] | length > 0' "$ORCH")
post_touches_hb=$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command
    | select(test("orchestrator-heartbeat"))] | length > 0' "$ORCH")
assert_eq "Stop hook touches orchestrator-heartbeat"        "$stop_touches_hb" "true"
assert_eq "PostToolUse hook touches orchestrator-heartbeat" "$post_touches_hb" "true"

# ---- turn-failure classification reaches the ORCHESTRATOR (#1520) -------
#
# The writer and its clear land TOGETHER or not at all: a writer with no
# clear leaves a stale marker that gates liveness until the freshness window
# lapses; a clear with no writer is inert. Both halves are asserted, and the
# worker file is the positive control that the jq shape is right.
echo "=== orchestrator-settings.json: turn-failure writer + clear (your-org/nexus-code#1520) ==="
orch_sf_tf=$(jq -r '[.hooks.StopFailure[]?.hooks[]?.command
    | select(test("turn-failure-emit.sh"))] | length' "$ORCH")
orch_stop_tf=$(jq -r '[.hooks.Stop[]?.hooks[]?.command
    | select(test("stamp-clear.sh turn-failure$"))] | length' "$ORCH")
orch_sf_ol=$(jq -r '[.hooks.StopFailure[]?.hooks[]?.command
    | select(test("over-limit-emit.sh"))] | length' "$ORCH")
WRK="$_repo_root/monitor/worker-settings.json"
wrk_sf_tf=$(jq -r '[.hooks.StopFailure[]?.hooks[]?.command
    | select(test("turn-failure-emit.sh"))] | length' "$WRK")
assert_eq "orchestrator StopFailure runs turn-failure-emit.sh (exactly once)" "$orch_sf_tf" "1"
assert_eq "orchestrator Stop clears the turn-failure stamp (exactly once)"     "$orch_stop_tf" "1"
assert_eq "orchestrator StopFailure still runs over-limit-emit.sh (rate_limit stays that hook's)" "$orch_sf_ol" "1"
assert_eq "positive control: the worker file wires the same writer"           "$wrk_sf_tf" "1"

# ---- Summary -----------------------------------------------------------
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
