# nexus agent shells — GUARANTEE a usable TMPDIR (your-org/nexus-code#1628).
#
# Sourced (never executed) by monitor/locals-env.sh (full mode: the launchers,
# so claude and everything below it inherit the value) and by the per-command
# preludes bash_env.sh / .zshenv (tool shells whose parent is claude, which
# covers sessions launched before this file existed). POSIX sh, identical under
# bash and zsh, no function definitions, silent on success.
#
# WHY. Claude Code does not set TMPDIR and this sandbox does not either: measured
# 2026-09-23, `TMPDIR` UNSET in the orchestrator's shell and in claude's own
# environ, on two deployments. So `$TMPDIR/x` is `/x` — the sandbox ROOT, which
# is writable — at rc 0 with nothing on stderr. It fired three times in one
# session (`/sk.py`, `/v3/`, `/v4/`), and the worker floor named `$TMPDIR` as
# the scratchpad. `rm -rf $TMPDIR/foo` is `rm -rf /foo`.
#
# WHAT. Only when TMPDIR is unset or EMPTY: use <base>/claude-<uid>/tmp, created
# 0700 if missing, and export it only if it and its parent are real directories
# (not symlinks) owned by this uid and writable. A TMPDIR that is already set
# is never touched, even if it looks wrong — that is the caller's choice.
# Existing `${TMPDIR:-/tmp}` callers keep working; they now land in a private
# directory instead of /tmp's top level.
#
# The base is `/tmp` (chosen: the sandbox's /tmp is private and already holds
# claude-<uid>/, the harness's own per-user dir). `NEXUS_TMPDIR_BASE` overrides
# it so tests can use a fixture directory; a RELATIVE base is refused.
#
# FAILURE IS LOUD. If no private directory can be established, TMPDIR stays
# unset and ONE line goes to stderr, in every shell that sources this, until it
# is fixed. A warning on every command is the point: the silent version of this
# failure is `/x`.
if [ -z "${TMPDIR:-}" ]; then
    _nx_tb=${NEXUS_TMPDIR_BASE:-/tmp}
    _nx_tu=${UID:-}
    [ -n "$_nx_tu" ] || _nx_tu=$(id -u 2>/dev/null)
    _nx_tp="$_nx_tb/claude-$_nx_tu"
    _nx_td="$_nx_tp/tmp"
    case "$_nx_tb" in
        /?*) _nx_ok=1 ;;
        *)   _nx_ok=0 ;;
    esac
    [ -n "$_nx_tu" ] || _nx_ok=0
    # Symlinks are refused BEFORE mkdir, so mkdir never writes THROUGH a
    # symlinked claude-<uid> (skeptic on PR #1630: measured, `tgt/tmp` was
    # created and only then rejected).
    if [ -L "$_nx_tp" ] || [ -L "$_nx_td" ]; then _nx_ok=0; fi
    if [ "$_nx_ok" = 1 ] && [ ! -d "$_nx_td" ]; then
        ( umask 077 && mkdir -p "$_nx_td" ) 2>/dev/null || :
    fi
    # A PRE-EXISTING dir must be private too: mode exactly 0700 (skeptic on
    # PR #1630: a 0777 one was accepted). One `stat` fork, and only on this
    # unset/empty path.
    _nx_mode=''
    [ "$_nx_ok" = 1 ] && [ -d "$_nx_td" ] && _nx_mode=$(stat -c '%a' "$_nx_td" 2>/dev/null)
    if [ "$_nx_ok" = 1 ] && [ -d "$_nx_td" ] && [ ! -L "$_nx_td" ] && [ ! -L "$_nx_tp" ] \
       && [ -O "$_nx_td" ] && [ -O "$_nx_tp" ] && [ -w "$_nx_td" ] && [ "$_nx_mode" = 700 ]; then
        TMPDIR=$_nx_td
        export TMPDIR
    else
        printf '%s\n' "nexus: TMPDIR is unset and no private temp dir could be established at '$_nx_td' — \$TMPDIR/x would resolve to /x (your-org/nexus-code#1628). Set TMPDIR to a directory you own." >&2
    fi
    unset _nx_tb _nx_tu _nx_tp _nx_td _nx_ok _nx_mode
fi
