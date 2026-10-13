#!/usr/bin/env bash
# _degraded-rundir.sh — WHERE degraded-mode state lives when the project tree
# is read-only (your-org/nexus-code#1724). Sourced; defines one function and
# nothing else. Readers and writers (the watcher's _fs_guard.sh, `ng degraded
# status`, the sandbox-notify wrapper) all resolve through it, so they agree.
#
# THE RULE (operator, 2026-10-10, #1724 comment c6105428034): degraded mode
# writes SMALL STATE only (a status file, paste locks, cooldown stamps, a
# decision log), and only under the session-managed scratch tree, never a
# hardcoded location: the nexus runs for many users, and nobody may assume
# which directories are writable on their host. So the answer is DERIVED from
# $TMPDIR, which monitor/shellenv/tmpdir.sh manages for every agent shell and
# launcher.
#
# WHY NOT JUST "$TMPDIR/nexus-degraded". $TMPDIR is PER AGENT
# (<base>/claude-<uid>/tmp/agent-<key>), and the watcher inherits whichever
# agent last restarted it (measured 2026-10-10: the live watcher's TMPDIR was
# `…/agent-cc-auto-update`). A per-process answer would put the watcher's
# status where `ng degraded status`, run from another agent, never looks. So a
# TMPDIR that is a per-agent leaf of the managed tree maps to that tree's
# shared root; the root itself is used as is; any other TMPDIR (a caller's own
# choice) is used as is.
#
#   nexus_degraded_rundir   -> prints the run dir path; creates nothing (the
#                              TMPDIR fallback below may create the managed
#                              tree itself, 0700, exactly as every agent shell
#                              does). rc 1 (prints nothing) only when no
#                              managed place can be established; guessing one
#                              is what this file exists to stop.
#
# NO TMPDIR AT ALL is the WATCHER's normal state, not an edge case (skeptic N2
# on #1799, measured on the live watcher 2026-10-12: its environ has no
# TMPDIR). It is setsid-launched, never under a claude parent, so bash_env.sh
# never sources tmpdir.sh for it, and the same holds for `ng degraded status`
# typed into an operator's own shell. So an unset TMPDIR is DERIVED with the
# SAME code every agent shell runs (monitor/shellenv/tmpdir.sh), in a SUBSHELL
# so the caller's environment (TMPDIR, TZ) never shifts. That is the managed
# tree's single definition, not a new literal; when it cannot establish a
# private dir it says so on stderr (#1628) and this returns rc 1.
# NEXUS_DEGRADED_RUNDIR overrides the whole derivation (tests, operators).
nexus_degraded_rundir() {
    if [ -n "${NEXUS_DEGRADED_RUNDIR:-}" ]; then
        printf '%s' "$NEXUS_DEGRADED_RUNDIR"; return 0
    fi
    local t="${TMPDIR:-}" te=''
    if [ -z "$t" ]; then
        te="${BASH_SOURCE[0]%/*}/shellenv/tmpdir.sh"
        [ -r "$te" ] || te="${NEXUS_ROOT:-}/monitor/shellenv/tmpdir.sh"
        [ -r "$te" ] || return 1
        # No agent key: the watcher's own path, and the shared root directly.
        t=$( unset NEXUS_TMPDIR_AGENT; . "$te" >/dev/null; printf '%s' "${TMPDIR:-}" )
        [ -n "$t" ] || return 1
    fi
    while [ "${t%/}" != "$t" ]; do t=${t%/}; done
    # Only when the LAST component is `agent-<key>` and its parent is the
    # managed `…/claude-<uid>/tmp`: a dir merely NESTED below an agent leaf (a
    # suite's mktemp dir) is a caller's own TMPDIR and is used as is.
    case "${t##*/}" in
        agent-*) case "${t%/*}" in */claude-*/tmp) t=${t%/*} ;; esac ;;
    esac
    printf '%s/nexus-degraded' "$t"
}
