# nexus agent ZDOTDIR — .zshenv (sourced on EVERY zsh invocation).
#
# The nexus launchers export ZDOTDIR=$NEXUS_ROOT/monitor/shellenv for agent
# (worker + orchestrator) processes (see monitor/locals-env.sh, full mode).
# Every `zsh -c` the Claude Code Bash tool runs sources this file. We keep it
# TRANSPARENT — source the operator's real ~/.zshenv first so nothing is lost
# — then FORCE the WHOLE nexus toolchain to the FRONT of PATH: the bot-default
# `gh` wrapper dir (monitor/ghwrap) AND the nexus-provisioned `locals/bin`
# (uv, python, ng, claude, …).
#
# WHY force-front HERE (and not only in locals-env). ~/.zshenv, sourced on the
# line just below, re-prepends linuxbrew/system paths on EVERY zsh invocation —
# burying the process-wide prepend locals-env did at launch. This per-command
# re-assertion runs AFTER that late modification, so the nexus copies win. It
# started as a `gh`-only fix (the PATH race the old function shim worked around;
# operator request your-org/nexus-code PR #349 comment 4795415597), then
# generalized to ALL of locals/bin — `uv`/`claude`/`ng`/… were still resolving
# to linuxbrew/system copies in a live agent shell, a latent reproducibility gap
# (operator request PR #349 comment 4799289032; this is the follow-up PR).
# `typeset -U path` de-dups, keeping our front copies and dropping the buried
# ones. Order: ghwrap leads (so a bare `gh` hits the bot-default wrapper even if
# a real `gh` ever lands in locals/bin), locals/bin directly behind it.
#
# zsh sources .zshenv before .zshrc/.zprofile/.zlogin, so the front-of-PATH
# entries are in scope for interactive and login agent shells too. The sibling
# proxy rc files (.zshrc/.zprofile/.zlogin) re-source the operator's real ones
# so those shells are not stripped of their config.
#
# Agent-spawn-scoped ONLY: this file is reached solely because the nexus
# launchers export ZDOTDIR for agent processes. The operator's bare interactive
# shell sources their real ~/.zshenv (not this one), so their PATH — where
# homebrew shadowing nexus tools is deliberately fine — is untouched.
[ -r "$HOME/.zshenv" ] && . "$HOME/.zshenv"
# Force the nexus toolchain to the FRONT of PATH after ~/.zshenv's linuxbrew
# re-prepend. Shared with the .zshrc/.zprofile/.zlogin proxies via one snippet
# so the four cannot drift (your-org/nexus-code#578). $ZDOTDIR is this file's
# own directory — reliable in a startup file, where ${0} is the shell name,
# not the file path (so ${0:A:h} would resolve to the zsh binary's dir).
[ -r "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh" ] && . "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh"

# STRIP the resume-picker thresholds from a Claude Code TOOL SHELL
#   (your-org/nexus-code#1613). claude-loop.sh and spawn-worker.sh's resume
#   launcher set CLAUDE_CODE_RESUME_THRESHOLD_MINUTES / _TOKEN_THRESHOLD in
#   the inline per-child form, and that form is REQUIRED: claude reads them
#   from its own process env to suppress the stale-large-session picker. But
#   claude hands its env to every Bash tool shell, so every resumed or
#   resurrected session exported the pair into every command, suite and band
#   it ran, and test-claude-loop.sh's clean-parent assertion went red for a
#   reason unrelated to the code under test. So this is fixed at the shell,
#   not at the launcher: the launcher cannot hand claude a variable its
#   children will not inherit.
#
#   KEYED ON THE PARENT BEING `claude`, not unconditional. The bash prelude (bash_env.sh) also
#   runs at the start of a bash WRAPPER or stub launched as
#   `VAR=v "$CLAUDE_BIN"` (test-claude-loop.sh's stub is exactly that), and
#   stripping there would remove the suppression before the real binary
#   sees it. A tool shell's parent is the claude process (measured:
#   /proc/$PPID/comm = `claude`); a wrapper's parent is the launcher
#   (`claude-loop.sh`, `bash`). Boundary: an install whose process is not
#   named `claude` (a node-run cli.js reads `node`) is not stripped, which
#   is the pre-#1613 behaviour, not a new failure. A builtin `read`, no fork,
#   and silent on every path, because this runs in every zsh.
if [ -n "${CLAUDE_CODE_RESUME_THRESHOLD_MINUTES+x}${CLAUDE_CODE_RESUME_TOKEN_THRESHOLD+x}" ]; then
    _nx_pcomm=''
    { read -r _nx_pcomm < "/proc/$PPID/comm"; } 2>/dev/null || :
    if [ "$_nx_pcomm" = claude ]; then
        unset CLAUDE_CODE_RESUME_THRESHOLD_MINUTES CLAUDE_CODE_RESUME_TOKEN_THRESHOLD
    fi
    unset _nx_pcomm
fi

# GUARANTEE a usable TMPDIR in a Claude Code TOOL SHELL (your-org/nexus-code#1628).
#   Same block as bash_env.sh, and keyed on the parent being `claude` for the
#   same reasons (see there). $ZDOTDIR is this file's own directory.
if [ -z "${TMPDIR:-}" ]; then
    _nx_pcomm=''
    { read -r _nx_pcomm < "/proc/$PPID/comm"; } 2>/dev/null || :
    if [ "$_nx_pcomm" = claude ] && [ -r "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/tmpdir.sh" ]; then
        . "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/tmpdir.sh"
    fi
    unset _nx_pcomm
fi
