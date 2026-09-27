#!/usr/bin/env bash
# monitor/watcher/test-resume-env-strip.sh — a Claude Code TOOL SHELL does not
# inherit the resume-picker thresholds (your-org/nexus-code#1613).
#
# claude-loop.sh and spawn-worker.sh's resume launcher set
# CLAUDE_CODE_RESUME_THRESHOLD_MINUTES / CLAUDE_CODE_RESUME_TOKEN_THRESHOLD in
# the inline per-child form, because claude reads them from its own env. claude
# then hands its env to every Bash tool shell, so every resumed or resurrected
# session exported the pair into every suite and band it ran — and
# test-claude-loop.sh's clean-parent assertion went red for a reason unrelated
# to the code under test. The fix is in the per-command shell prelude
# (monitor/shellenv/bash_env.sh for bash, monitor/shellenv/.zshenv for zsh):
# strip the pair when the shell's PARENT is the `claude` process.
#
# The rig stands a bash script NAMED `claude` in for the claude process: a
# shebang script's /proc comm is its basename, so a shell it spawns sees
# exactly the parent comm a real tool shell sees (measured on this host:
# /proc/$PPID/comm = `claude` from a live tool shell).
#
# POTENCY CONTROL: the identical script under another name (`launcher`) must
# leave the pair in place. That is the case the inline form depends on: a bash
# wrapper or stub launched as `VAR=v "$CLAUDE_BIN"` runs this same prelude, and
# stripping there would remove the suppression before the real binary sees it.
# So a green on the strip cases alone could come from an unconditional unset;
# the control is what pins the condition.
#
# Hermetic: HOME points at an empty dir so the operator's ~/.zshenv is not
# sourced, NEXUS_PREV_BASH_ENV is empty so no Lmod chain runs, NEXUS_ROOT is
# unset so no PATH fronting runs.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SHELLENV="$REPO_ROOT/monitor/shellenv"
# Born PROTECTED (test-summary-honesty-manifest.sh: ledger=yes, count=exact):
# the tally goes through the helper ledger, which survives a subshell.
. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0; SKIP=0
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
WORK=$(mktemp -d -t resume-strip-XXXXXX) || { echo "FAIL: mktemp" >&2; exit 1; }
th_trap_exit 'rm -rf "$WORK"'
mkdir -p "$WORK/home" "$WORK/as-claude" "$WORK/as-launcher"

# The stand-in parent: runs "$@" (a shell command) and nothing else.
for d in as-claude/claude as-launcher/launcher; do
    printf '#!/bin/bash\nexec_child() { "$@"; }\nexec_child "$@"\n' > "$WORK/$d"
    chmod +x "$WORK/$d"
done
# Sanity: the stand-in's comm is what the prelude will read.
c=$("$WORK/as-claude/claude" bash -c 'read -r x < /proc/$PPID/comm; printf %s "$x"')
[[ "$c" == claude ]] && ok "rig: a child of the stand-in reads parent comm 'claude'" || bad "rig: parent comm read '$c' (the rig cannot reach the axis)"

PROBE='printf "%s|%s|%s" "${CLAUDE_CODE_RESUME_THRESHOLD_MINUTES-unset}" "${CLAUDE_CODE_RESUME_TOKEN_THRESHOLD-unset}" "${CLAUDE_CODE_OTHER-unset}"'

# run <parent> <shell> [<env assignments>…] → the child's view
run() {
    local parent="$1" sh="$2"; shift 2
    env -i HOME="$WORK/home" PATH="/usr/bin:/bin" \
        BASH_ENV="$SHELLENV/bash_env.sh" NEXUS_PREV_BASH_ENV= ZDOTDIR="$SHELLENV" \
        CLAUDE_CODE_OTHER=keep "$@" \
        "$parent" "$sh" -c "$PROBE" 2>"$WORK/err"
}
BOTH=( CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=999999999 CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=999999999999 )

echo "=== bash tool shell (parent = claude) ==="
r=$(run "$WORK/as-claude/claude" bash "${BOTH[@]}")
[[ "$r" == "unset|unset|keep" ]] && ok "bash under claude: both thresholds stripped, an unrelated CLAUDE_CODE_* var kept" || bad "bash under claude: got '$r' (want unset|unset|keep)"
[[ ! -s "$WORK/err" ]] && ok "bash under claude: prelude silent on stderr" || bad "bash under claude stderr: $(cat "$WORK/err")"
r=$(run "$WORK/as-claude/claude" bash CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=5)
[[ "$r" == "unset|unset|keep" ]] && ok "bash under claude: ONE var set is stripped too" || bad "bash one var: got '$r'"
# THE PRELUDE'S LAST STATUS IS THE SHELL'S FIRST `$?` (skeptic item 10 on
# your-org/nexus-code#1626). This block is the TAIL of bash_env.sh, so whatever
# its last command returns is what `$?` reads before the caller has run
# anything — and nothing above pins it: a mutant ending the strip block in
# `false` survived at 10/0, every row still green. A caller that tests `$?`
# first (a `|| exit` idiom, a status-reporting wrapper) would read a failure it
# never had. On the STRIP path specifically, because that is the one path whose
# commands (`read`, `unset`) are new; the no-vars path never enters the block.
r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" BASH_ENV="$SHELLENV/bash_env.sh" NEXUS_PREV_BASH_ENV= \
    "${BOTH[@]}" "$WORK/as-claude/claude" bash -c 'printf "%s|%s" "$?" "${CLAUDE_CODE_RESUME_THRESHOLD_MINUTES-unset}"')
[[ "$r" == "0|unset" ]] && ok "bash under claude: the STRIP path leaves \$? = 0 at shell start" || bad "bash strip path \$?: got '$r' (want 0|unset)"

echo "=== bash wrapper/stub (parent = a launcher) — the inline form must still arrive ==="
r=$(run "$WORK/as-launcher/launcher" bash "${BOTH[@]}")
[[ "$r" == "999999999|999999999999|keep" ]] && ok "bash under a launcher: both thresholds KEPT (control)" || bad "bash under launcher: got '$r'"

echo "=== zsh tool shell (parent = claude) ==="
if command -v zsh >/dev/null 2>&1; then
    r=$(run "$WORK/as-claude/claude" zsh "${BOTH[@]}")
    [[ "$r" == "unset|unset|keep" ]] && ok "zsh under claude: both thresholds stripped, unrelated var kept" || bad "zsh under claude: got '$r' (want unset|unset|keep)"
    [[ ! -s "$WORK/err" ]] && ok "zsh under claude: prelude silent on stderr" || bad "zsh under claude stderr: $(cat "$WORK/err")"
    r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" ZDOTDIR="$SHELLENV" NEXUS_PREV_BASH_ENV= \
        "${BOTH[@]}" "$WORK/as-claude/claude" zsh -c 'printf "%s|%s" "$?" "${CLAUDE_CODE_RESUME_THRESHOLD_MINUTES-unset}"')
    [[ "$r" == "0|unset" ]] && ok "zsh under claude: the STRIP path leaves \$? = 0 at shell start" || bad "zsh strip path \$?: got '$r' (want 0|unset)"
    r=$(run "$WORK/as-launcher/launcher" zsh "${BOTH[@]}")
    [[ "$r" == "999999999|999999999999|keep" ]] && ok "zsh under a launcher: both thresholds KEPT (control)" || bad "zsh under launcher: got '$r'"
else
    printf '  SKIP: no zsh on this host; the .zshenv arm is unmeasured here\n'
    _th_skip; _ZSH_ARM_SKIPPED=1
fi

echo "=== a stripped tool shell hands a CLEAN env to its children (the suite-in-a-band case) ==="
r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" BASH_ENV="$SHELLENV/bash_env.sh" NEXUS_PREV_BASH_ENV= \
    CLAUDE_CODE_OTHER=keep "${BOTH[@]}" "$WORK/as-claude/claude" bash -c "bash -c '$PROBE'")
[[ "$r" == "unset|unset|keep" ]] && ok "grandchild of claude (e.g. bash test-claude-loop.sh) sees neither var" || bad "grandchild: got '$r'"

echo "=== set -eu callers survive the prelude ==="
r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" BASH_ENV="$SHELLENV/bash_env.sh" NEXUS_PREV_BASH_ENV= \
    "$WORK/as-launcher/launcher" bash -euc 'echo alive' 2>&1)
[[ "$r" == alive ]] && ok "bash -eu with neither var set and a non-claude parent: prelude does not abort the shell" || bad "set -eu: got '$r'"
# …and WITH the pair set under a claude parent, which is the only input that
# walks the strip block: the row above never enters it, so a `-u` hazard added
# there (an unguarded expansion of a variable `read` may leave unset) was
# unreachable from this section.
r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" BASH_ENV="$SHELLENV/bash_env.sh" NEXUS_PREV_BASH_ENV= \
    "${BOTH[@]}" "$WORK/as-claude/claude" bash -euc 'printf "alive|%s" "${CLAUDE_CODE_RESUME_THRESHOLD_MINUTES-unset}"' 2>&1)
[[ "$r" == "alive|unset" ]] && ok "bash -eu with both vars set under claude: the STRIP path does not abort the shell" || bad "set -eu strip path: got '$r' (want alive|unset)"

# EXACT COUNT: 13 assertions, 9 when the zsh arm (4 assertions) is skipped.
EXPECTED=13; (( ${_ZSH_ARM_SKIPPED:-0} )) && EXPECTED=9
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
