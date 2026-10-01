#!/usr/bin/env bash
# Tests for monitor/cc-harness/_lib.sh::cch_launch_cmd — the single
# construction site for a harness worker's launch command string.
#
# Run: bash monitor/test-cch-launch-string.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#158 added the
# CCH_SKIP_PERMISSIONS knob so a scenario can boot a worker WITHOUT
# `--dangerously-skip-permissions` (that flag is what suppresses the
# permission dialog). The knob's hard constraint is that the DEFAULT
# launch string does not change: every pre-existing scenario, and the
# pre-update gate that runs them, must boot exactly the command they
# booted before.
#
# "Does not change" is asserted by MEASUREMENT, not by reading the diff.
# The suite reconstructs the pre-knob launch string from the flag's
# construction site at BASELINE_REF, feeds both the old and the new
# builder the same inputs, and compares the two strings byte for byte.
#
# Terms, defined on first use:
#
#   Harness        monitor/cc-harness, the scenario runner that drives the
#                  real `claude` binary against an auth-free mock backend.
#   Scenario       one harness test case.
#   Launch string  the single shell command tmux runs in a worker window.
#   Baseline       the launch string as built at BASELINE_REF, before the
#                  knob existed.
#
# The suite is hermetic: no tmux, no claude binary, no mock backend. It
# needs `git` to read the two baseline blobs.
#
# A SHALLOW CLONE MUST NOT TURN INTO A FALSE PASS. CI checks out with
# depth 1, so the baseline commits are usually absent. This suite used to
# print `skipped:` and exit 0 there, before any assertion ran: twelve
# assertions lost and the run still reported green. That is the failure
# class gate.sh's exit-77 sentinel exists for. Now:
#
#   1. The whitelist check (section 3) needs no git, so it runs FIRST and
#      always runs.
#   2. A missing baseline is fetched by its full SHA from `origin`
#      (self-repair). This works on a GitHub depth-1 checkout.
#   3. If it is still unreachable, every baseline assertion is counted as
#      a FAILURE, and the suite exits 1. There is no skip path.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/.." && pwd)
LIB="$_test_dir/cc-harness/_lib.sh"

# The commit the knob was written against. The baseline is read from git,
# not transcribed here, so this suite cannot drift from what actually
# shipped.
#
# Full SHAs, not short ones: the self-repair fetch below can only ask a
# remote for a full object name.
BASELINE_REF="c9c07bc01d92bc02e48ec3ea5cfdc6758941af29"
BASELINE_PATH="monitor/cc-harness/_lib.sh"

# The commit where `main` added the settings-file argument (the hook and
# VI-paste scenarios boot through it), immediately before this branch
# folded that argument into cch_launch_cmd. Read for the same reason as
# BASELINE_REF: the settings shape is measured, not transcribed.
SETTINGS_REF="d079074f0edc7a71408a691addcf7425e11810c2"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n    got:  <<%s>>\n    want: <<%s>>\n' \
            "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- fixed inputs --------------------------------------------------------
# Deliberately awkward values. The launch string interpolates several of
# them through printf's %q, so a space and an embedded quote both have to
# survive identically through both builders. Equal-under-easy-inputs
# would prove much less.
#
# FAKE_PATH is applied only INSIDE the two builder calls, never to this
# script's own environment: both builders use printf alone, but this
# suite needs a working `grep`, `git` and `awk`.
CCH_CFG='/tmp/cc harness/cfg "odd"'
FAKE_PATH='/usr/bin:/opt/node bin:/x'
CCH_MOCK_PORT='54321'
CLAUDE_BIN='/tmp/cc harness/node_modules/.bin/claude'
TERM='xterm-256color'
export CCH_CFG CCH_MOCK_PORT CLAUDE_BIN TERM

# ---- whitelist: no scenario rebuilds the launch string -------------------
# Runs first, because it needs no git: a missing baseline below must not
# take this assertion down with it.
echo "=== no scenario rebuilds the launch string ==="

# The duplication this knob exists to remove. A scenario that only
# wants a different cwd, or one flag dropped, must NOT rebuild the
# launch string — that is what two agents did on 2026-09-09 and what
# the knob plus the workdir argument now make unnecessary.
#
# The check is a closed whitelist of the files allowed to carry a
# `printf -v launch` statement. A new copy therefore fails here, in
# the fast test loop, instead of drifting silently from the production
# spawn flags. Each exemption is justified:
#
#   _lib.sh          the one construction site (cch_launch_cmd).
#   apispoof         adds the hook substrate: NEXUS_* env plus
#                    `--settings <file>`. A genuinely different launch
#                    shape, not a copy made to drop a flag. Folding
#                    the hook substrate into cch_launch_cmd is a
#                    follow-up, deliberately not done here.
#   overlimit        same hook substrate, plus a pinned TZ and
#                    CLAUDE_CODE_MAX_RETRIES.
#   this file        quotes the statement inside an awk range, to read
#                    the baseline out of git.
#
# demo.sh writes `printf -v LAUNCH` (upper case) and does not source
# _lib.sh at all; it is a standalone human-facing demo.
#
# Use `command grep -r`: the bundled `grep` shell function honours
# .gitignore and would return an empty, exit-1 result that reads
# identically to a true negative.
mapfile -t builders < <(
    command grep -rl --include='*.sh' -- 'printf -v launch' \
        "$REPO_ROOT/monitor" 2>/dev/null | sort
)
expected=(
    "$_test_dir/cc-harness/_lib.sh"
    "$_test_dir/test-cch-launch-string.sh"
    "$_test_dir/watcher/test-integration/test-realmodel-apispoof.sh"
    "$_test_dir/watcher/test-integration/test-realmodel-overlimit.sh"
)
assert_eq "only the whitelisted files build a launch string" \
    "$(printf '%s\n' "${builders[@]}")" "$(printf '%s\n' "${expected[@]}")"

# ---- the baseline builders, read from git -------------------------------
# Read <ref>:<path>. If the commit is absent (a shallow clone), fetch it
# once by full SHA from origin and retry. Prints the blob; returns 1 if
# it is still unreachable.
read_blob() {
    local ref="$1" path="$2"
    if ! git -C "$REPO_ROOT" cat-file -e "$ref^{commit}" 2>/dev/null; then
        git -C "$REPO_ROOT" fetch --quiet --no-tags --depth=1 origin "$ref" \
            >/dev/null 2>&1 || true
    fi
    git -C "$REPO_ROOT" show "$ref:$path" 2>/dev/null
}

# Extract the `printf -v launch ... "$CLAUDE_BIN"` statement verbatim from
# the baseline blob. This is the pre-knob code path, evaluated, not a
# transcription of it.
BASELINE_BLOCK=""
read_baseline_block() {
    local blob
    blob=$(read_blob "$BASELINE_REF" "$BASELINE_PATH") || return 1
    BASELINE_BLOCK=$(awk '/^    printf -v launch /,/"\$CLAUDE_BIN"$/' <<<"$blob")
    [[ -n "$BASELINE_BLOCK" ]] || return 1
    # Guard the extraction itself: if the awk range ever matches the wrong
    # region, the flag would be absent and every comparison below would
    # pass vacuously.
    grep -qF -- '--dangerously-skip-permissions' <<<"$BASELINE_BLOCK" || return 1
    grep -qF -- 'ANTHROPIC_BASE_URL' <<<"$BASELINE_BLOCK" || return 1
}

# The settings-file builder as `main` shipped it: from `local
# settings_arg` to the closing `"$settings_arg"` argument.
SETTINGS_BLOCK=""
read_settings_block() {
    local blob
    blob=$(read_blob "$SETTINGS_REF" "$BASELINE_PATH") || return 1
    SETTINGS_BLOCK=$(awk '/^    local settings_arg=""/,/"\$settings_arg"$/' <<<"$blob")
    [[ -n "$SETTINGS_BLOCK" ]] || return 1
    grep -qF -- '--settings' <<<"$SETTINGS_BLOCK" || return 1
    grep -qF -- '--dangerously-skip-permissions' <<<"$SETTINGS_BLOCK" || return 1
}

# No skip path. An unreachable baseline is a FAILURE: the suite cannot
# measure what it claims, so it must not report green.
summary() {
    echo
    printf 'cch-launch-string: %d passed, %d failed\n' "$PASS" "$FAIL"
    if (( FAIL == 0 )); then
        echo "ALL TESTS PASSED"
        exit 0
    fi
    exit 1
}
unreachable() {
    printf '  FAIL: cannot read %s at %s, even after a fetch from origin.\n' \
        "$BASELINE_PATH" "$1" >&2
    printf '        Every assertion that compares against it is counted as failed.\n' >&2
    printf '        In CI, check actions/checkout fetch-depth in tests.yml.\n' >&2
    FAIL=$(( FAIL + 1 ))
}
if ! read_baseline_block; then
    unreachable "$BASELINE_REF"
    summary
fi

launch_baseline() {
    local PATH="$FAKE_PATH" launch=""
    eval "$BASELINE_BLOCK"
    printf '%s' "$launch"
}

# ---- the new builder -----------------------------------------------------
# shellcheck source=cc-harness/_lib.sh
. "$LIB"

launch_new() {
    local PATH="$FAKE_PATH"
    cch_launch_cmd
}

BASELINE=$(launch_baseline)

echo
echo "=== cch_launch_cmd: default is byte-for-byte the pre-knob string ==="

# 1. Knob unset — the state every existing scenario runs in.
unset CCH_SKIP_PERMISSIONS
assert_eq "knob unset -> identical to baseline" "$(launch_new)" "$BASELINE"

# 2. Knob explicitly 1 — the documented default, spelled out.
CCH_SKIP_PERMISSIONS=1
assert_eq "CCH_SKIP_PERMISSIONS=1 -> identical to baseline" \
    "$(launch_new)" "$BASELINE"

# 3. Any value that is not exactly `0` keeps the safe default. A typo
#    must not silently strip the flag from a gate scenario.
for v in "" "no" "false" "00" "0 " "2"; do
    CCH_SKIP_PERMISSIONS="$v"
    assert_eq "CCH_SKIP_PERMISSIONS=$(printf '%q' "$v") -> keeps the flag" \
        "$(launch_new)" "$BASELINE"
done

echo
echo "=== cch_launch_cmd: the knob removes exactly one flag ==="

CCH_SKIP_PERMISSIONS=0
PROMPTING=$(launch_new)

# 4. The prompting string is the baseline minus the flag and nothing
#    else. Asserted as an exact string equality against a value derived
#    from the baseline, so any other drift (a reordered env var, a lost
#    quote) fails here rather than passing a substring check.
assert_eq "CCH_SKIP_PERMISSIONS=0 -> baseline minus the flag, nothing else" \
    "$PROMPTING" "${BASELINE% --dangerously-skip-permissions}"

# 5. Spelled out the other way: the flag is gone.
if grep -qF -- '--dangerously-skip-permissions' <<<"$PROMPTING"; then
    printf '  FAIL: knob=0 still carries --dangerously-skip-permissions\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: knob=0 drops --dangerously-skip-permissions\n'; PASS=$(( PASS + 1 ))
fi

# 6. Reading the knob at CALL time, not at source time, is what lets one
#    scenario boot both a default and a prompting worker.
unset CCH_SKIP_PERMISSIONS
assert_eq "knob is re-read per call -> back to baseline" \
    "$(launch_new)" "$BASELINE"

echo
echo "=== cch_launch_cmd: a settings file keeps main's shape ==="

# 7. The settings-file form (hook and VI-paste scenarios) must boot
#    exactly what `main` booted before the merge folded its argument into
#    cch_launch_cmd. Same awkward inputs, plus a settings path with a
#    space so %q quoting is exercised.
SETTINGS_FILE='/tmp/cc harness/settings "v".json'
if ! read_settings_block; then
    unreachable "$SETTINGS_REF"
else
    launch_settings_main() {
        local PATH="$FAKE_PATH" launch="" settings="$SETTINGS_FILE"
        eval "$SETTINGS_BLOCK"
        printf '%s' "$launch"
    }
    SETTINGS_MAIN=$(launch_settings_main)
    unset CCH_SKIP_PERMISSIONS
    assert_eq "settings file -> identical to main's settings form" \
        "$(PATH="$FAKE_PATH" cch_launch_cmd "$SETTINGS_FILE")" "$SETTINGS_MAIN"
    # An empty settings argument is the renderer path, not `--settings ''`.
    assert_eq "empty settings argument -> identical to baseline" \
        "$(PATH="$FAKE_PATH" cch_launch_cmd "")" "$BASELINE"
fi

# ---- summary -------------------------------------------------------------
summary
