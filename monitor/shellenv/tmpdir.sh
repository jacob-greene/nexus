# nexus agent shells — GUARANTEE a usable TMPDIR (your-org/nexus-code#1628),
# and one local time zone for every runtime (TZ/TZDIR, at the end of this file).
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
# WHAT. Only when TMPDIR is unset or EMPTY (or, from a launcher, inherited from
# this managed tree — see PER AGENT below): use <base>/claude-<uid>/tmp, created
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
#
# PER AGENT, NOT PER UID (nexus-code bundle 21). The per-uid directory is shared
# by every agent of this user, and generic scratch names collide: measured
# 2026-10-08, a skeptic and its lead both wrote `$TMPDIR/wrap2.out` at the same
# moment, and the interleaved file showed the skeptic posting the lead's
# comment. So when an agent LAUNCHER sources this (it exports
# NEXUS_TMPDIR_AGENT=<window name>), the value is <base>/claude-<uid>/tmp/
# agent-<key>, keyed on the window name so a resumed or respawned agent in the
# same window finds its own scratch again. A launcher RE-DERIVES an inherited
# TMPDIR that is this nexus-managed tree (the shared dir, or another agent's
# agent-* dir: a worker spawned by a worker); any other preset TMPDIR is still
# the caller's choice and left alone. The key is reduced to [A-Za-z0-9._-]; a
# key over 20 characters becomes its first 12 plus `-<cksum>`, so two long
# names sharing a prefix stay distinct and the leaf stays short: a tmux socket
# a suite makes under $TMPDIR has 107 bytes in all, and
# /tmp/claude-<uid>/tmp/agent-<key>/tmp.XXXXXXXXXX/tmux-<uid>/ is already
# ~55 bytes plus the key before the socket's own name. In-process
# sub-agents share their parent's shell, so they share its TMPDIR: they need
# `mktemp` names, which no environment variable can provide.
_nx_tk=''
_nx_tprev=''
if [ -n "${NEXUS_TMPDIR_AGENT:-}" ]; then
    _nx_tk=$(printf '%s' "$NEXUS_TMPDIR_AGENT" | tr -c 'A-Za-z0-9._-' '_')
    if [ "${#_nx_tk}" -gt 20 ]; then
        _nx_tk="$(printf '%s' "$_nx_tk" | cut -c1-12)-$(printf '%s' "$NEXUS_TMPDIR_AGENT" | cksum | cut -d' ' -f1)"
    fi
    _nx_tu=${UID:-}
    [ -n "$_nx_tu" ] || _nx_tu=$(id -u 2>/dev/null)
    _nx_tm="${NEXUS_TMPDIR_BASE:-/tmp}/claude-$_nx_tu/tmp"
    # Compare without trailing slashes: an inherited `/tmp/claude-<uid>/tmp/`
    # is the same managed dir (skeptic F4b on PR #1784; it used to be kept).
    _nx_tcur=${TMPDIR:-}
    while [ "${_nx_tcur%/}" != "$_nx_tcur" ]; do _nx_tcur=${_nx_tcur%/}; done
    case "$_nx_tcur" in
        "$_nx_tm/agent-$_nx_tk") ;;                       # already ours: keep
        "$_nx_tm"|"$_nx_tm/agent-"*) _nx_tprev=$TMPDIR; TMPDIR='' ;;   # inherited managed value: re-derive
    esac
    unset _nx_tu _nx_tm _nx_tcur
fi
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
    # The per-agent leaf, created only under a shared dir that passes every
    # check below, and held to the same checks itself.
    if [ -n "$_nx_tk" ] && [ "$_nx_ok" = 1 ]; then
        _nx_ok=0
        _nx_mode=''
        [ -d "$_nx_td" ] && _nx_mode=$(stat -c '%a' "$_nx_td" 2>/dev/null)
        if [ -d "$_nx_td" ] && [ ! -L "$_nx_td" ] && [ ! -L "$_nx_tp" ] && [ -O "$_nx_td" ] \
           && [ -O "$_nx_tp" ] && [ "$_nx_mode" = 700 ] && [ ! -L "$_nx_td/agent-$_nx_tk" ]; then
            _nx_ok=1
            _nx_tp=$_nx_td
            _nx_td="$_nx_td/agent-$_nx_tk"
            [ -d "$_nx_td" ] || ( umask 077 && mkdir "$_nx_td" ) 2>/dev/null || :
        fi
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
    elif [ -n "$_nx_tprev" ]; then
        # Re-deriving failed: keep the inherited (shared, but usable) value
        # rather than leave the agent with none, and say so.
        TMPDIR=$_nx_tprev
        export TMPDIR
        printf '%s\n' "nexus: no per-agent temp dir could be established at '$_nx_td'; keeping the shared TMPDIR '$TMPDIR' — scratch names can collide with other agents', so use mktemp" >&2
    else
        printf '%s\n' "nexus: TMPDIR is unset and no private temp dir could be established at '$_nx_td' — \$TMPDIR/x would resolve to /x (your-org/nexus-code#1628). Set TMPDIR to a directory you own." >&2
    fi
    unset _nx_tb _nx_tu _nx_tp _nx_td _nx_ok _nx_mode
fi
unset _nx_tk _nx_tprev

# ONE LOCAL TIME ZONE FOR EVERY RUNTIME IN THE AGENT (nexus-code bundle 22).
# With TZ unset, the system glibc reads /etc/localtime (PDT here), but the
# linuxbrew glibc that a brew Python, or a venv built on it, links does NOT: its
# compiled zone dir (…/Cellar/glibc/<v>/share/zoneinfo) does not exist, so it
# answers UTC. Measured 2026-10-09: an agent stamped a deploy's end with the
# venv Python, compared it with deploy.log's local times, and its wait could
# never fire. The form matters, measured 2026-10-10 in PDT and on a January
# date (skeptic B2 on PR #1786):
#   TZ unset                         brew Python UTC; node, system Python, date right
#   TZ=:/etc/localtime (a PATH)      brew and system Python right; NODE/ICU WRONG
#                                    (a fixed GMT-0800 all year, zone `undefined`)
#   TZ=America/Los_Angeles           node and system Python right; brew Python
#                                    UTC under the label `America`
#   TZDIR=<zoneinfo> TZ=<zone name>  ALL FOUR right, in summer and in winter
# So the zone NAME is derived from where /etc/localtime points, and exported
# with the matching TZDIR (or under an operator's different TZDIR that carries
# the same name). The `:path` form remains only as the fallback (link outside a
# zoneinfo dir, or a different TZDIR lacking the zone), where it still fixes
# the libc case. Set only when TZ is UNSET: an empty TZ is the caller's explicit
# UTC, and any set value is the caller's choice. NEXUS_TZ_LOCALTIME overrides
# the path so a suite can use a fixture. Slurm jobs do not get this prelude.
_nx_tzf=${NEXUS_TZ_LOCALTIME:-/etc/localtime}
if [ -z "${TZ+x}" ] && [ -e "$_nx_tzf" ]; then
    _nx_tzr=$(readlink -f "$_nx_tzf" 2>/dev/null)
    _nx_tzd=''
    _nx_tzn=''
    case "$_nx_tzr" in
        */zoneinfo/?*) _nx_tzd="${_nx_tzr%%/zoneinfo/*}/zoneinfo"; _nx_tzn=${_nx_tzr#"$_nx_tzd"/} ;;
    esac
    if [ -n "$_nx_tzn" ] && [ -f "$_nx_tzd/$_nx_tzn" ] \
       && { [ -z "${TZDIR:-}" ] || [ "$TZDIR" = "$_nx_tzd" ]; }; then
        TZ=$_nx_tzn
        TZDIR=$_nx_tzd
        export TZ TZDIR
    # A DIFFERENT TZDIR already exported is the operator's: keep it, and still
    # use the zone NAME when that tree carries it (your-org/nexus-code#1791 R2),
    # because the `:path` form below is the one node reads as a fixed offset.
    elif [ -n "$_nx_tzn" ] && [ -n "${TZDIR:-}" ] && [ -f "$TZDIR/$_nx_tzn" ]; then
        TZ=$_nx_tzn
        export TZ
    else
        TZ=":$_nx_tzf"
        export TZ
    fi
    unset _nx_tzr _nx_tzd _nx_tzn
fi
unset _nx_tzf
