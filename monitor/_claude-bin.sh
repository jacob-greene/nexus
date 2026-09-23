#!/bin/bash
# monitor/_claude-bin.sh — shared $CLAUDE_BIN resolver for spawn surfaces.
#
# Sourced by every script that spawns a `claude` process. Resolves the
# binary path in this order:
#   1. CLAUDE_BIN env var (operator override).
#   2. `nexus.claude_bin` in config/nexus.yml — operator-local pin to a
#      claude install OUTSIDE the repo (a native Claude Code install,
#      e.g. ~/.local/bin/claude). See "Why a config key" below.
#   3. $NEXUS_ROOT/node_modules/.bin/claude — project-local npm install,
#      managed by monitor/install-claude-local.sh.
#   4. `claude` on PATH (legacy system install). Suppressed when
#      CLAUDE_BIN_NO_PATH is set — see below.
# Fails loud if none are found; see "Exit codes" at the end.
#
# CLAUDE_BIN_NO_PATH exists for exactly one caller:
# monitor/link-nexus-tools.sh, which WRITES `locals/bin/claude` — and
# `locals/bin` is at the FRONT of every agent's PATH. Letting that
# caller consume lookup 4 is circular: `command -v claude` would find
# the very link it is about to rewrite, and the linker would point the
# link at itself. Any caller that is a PATH *producer* must set this.
#
# Why a config key for lookup 2 (your-org/nexus-code, native-install
# switch). An operator who runs the NATIVE Claude Code install wants
# every spawn surface on it, and wants the npm tree gone. Three
# properties are needed and only a config key has all three:
#   - It must OUTRANK node_modules. Lookup 3 previously came first, so
#     a re-appearing node_modules (a stray `npm install`, a fresh
#     bootstrap) would silently take the workspace back to the npm
#     binary with no error anywhere.
#   - It must be OPERATOR-LOCAL. config/nexus.yml is gitignored; this
#     tracked file is shared by every operator, so an absolute path
#     like /home/<someone>/.local/bin/claude can never live in source.
#   - It must reach the surfaces $CLAUDE_BIN does not. An env export
#     only covers processes that inherit it; the cc-update scripts run
#     from the watcher and previously hard-coded the npm path.
# The lookup is SOFT on the loader (config/load.sh needs python3 +
# pyyaml): a loader failure degrades to lookups 3/4, exactly the
# pre-change behaviour. It is HARD on the value: a key that is set but
# does not resolve to an executable is a fatal error, never a silent
# fall-through to node_modules — the whole point is that the operator's
# choice cannot be quietly overridden.
#
# Why a shared helper: keeping the resolver in one file means future
# changes (e.g. a third lookup path, version-floor check) land in one
# place instead of drifting across spawn-worker.sh, entry.sh, main.sh,
# spawn-fresh-orchestrator.sh, bootstrap-install.sh, and claude-loop.sh.
#
# Why baked into heredocs at write time: every spawn surface writes a
# /tmp launcher script and tmux-spawns it. The launcher's heredoc is
# unquoted, so $CLAUDE_BIN interpolates at write time and the launcher
# contains the absolute path verbatim. This avoids re-resolving inside
# the launcher's shell (which may not have NEXUS_ROOT set yet).
#
# Caller contract: $NEXUS_ROOT must be set before sourcing. The helper
# is destructive on failure (calls `exit`) — that's intentional, a
# spawn surface that can't find claude has no recovery path. Callers
# that need to survive a failure probe it in a subshell first (see
# monitor/watcher/_respawn.sh and monitor/bootstrap-install.sh).
#
# Exit codes (a subshell probe reads these):
#   0  resolved; $CLAUDE_BIN exported.
#   1  nothing found by any lookup. RECOVERABLE — bootstrap-install.sh
#      answers this by installing the project-local npm copy.
#   2  `nexus.claude_bin` is set but does not resolve to an executable.
#      NOT recoverable by installing: the operator named a binary and
#      it is wrong, so re-creating node_modules would override a
#      deliberate choice instead of honouring it. Callers must refuse.

if [[ -z "${NEXUS_ROOT:-}" ]]; then
    echo "_claude-bin.sh: NEXUS_ROOT must be set before sourcing" >&2
    exit 1
fi

if [[ -z "${CLAUDE_BIN:-}" ]]; then
    # Lookup 2 — operator-local config pin. Soft on the loader (a
    # missing python3/pyyaml prints nothing and yields ""), hard on a
    # set-but-broken value (die rather than fall back to npm).
    _cb_cfg=""
    _cb_rc=0
    if [[ -x "$NEXUS_ROOT/config/load.sh" ]]; then
        _cb_cfg=$("$NEXUS_ROOT/config/load.sh" nexus.claude_bin "" 2>/dev/null) || _cb_rc=$?
        # load.sh exit 3 = no pyyaml-capable python3. That is a broken
        # loader, not "the key is unset", and the difference is invisible
        # downstream: we would fall through to the npm tree and the
        # operator would never learn their pin was ignored. Warn, once per
        # resolution, and carry on — degrading is still better than
        # refusing to spawn over a missing python module.
        if (( _cb_rc == 3 )); then
            echo "_claude-bin.sh: WARNING config/load.sh cannot read yaml (no pyyaml)" >&2
            echo "  nexus.claude_bin, if set, is being IGNORED. Install pyyaml for the" >&2
            echo "  python3 on PATH, or set CLAUDE_BIN explicitly." >&2
        fi
        (( _cb_rc == 0 )) || _cb_cfg=""
    fi
    # Trim surrounding whitespace (a trailing newline survives $( ) only
    # if embedded, but a stray space in the yaml value would not).
    _cb_cfg="${_cb_cfg#"${_cb_cfg%%[![:space:]]*}"}"
    _cb_cfg="${_cb_cfg%"${_cb_cfg##*[![:space:]]}"}"

    if [[ -n "$_cb_cfg" ]]; then
        if [[ -x "$_cb_cfg" ]]; then
            CLAUDE_BIN="$_cb_cfg"
        else
            echo "_claude-bin.sh: nexus.claude_bin is set but not executable" >&2
            echo "  config/nexus.yml nexus.claude_bin = $_cb_cfg" >&2
            echo "  Fix the path or clear the key; refusing to silently fall" >&2
            echo "  back to $NEXUS_ROOT/node_modules/.bin/claude." >&2
            unset _cb_cfg _cb_rc
            exit 2
        fi
    elif [[ -x "$NEXUS_ROOT/node_modules/.bin/claude" ]]; then
        CLAUDE_BIN="$NEXUS_ROOT/node_modules/.bin/claude"
    elif [[ -z "${CLAUDE_BIN_NO_PATH:-}" ]] && command -v claude >/dev/null 2>&1; then
        CLAUDE_BIN="$(command -v claude)"
    else
        echo "_claude-bin.sh: no claude binary found" >&2
        echo "  Looked for: config/nexus.yml nexus.claude_bin (unset/empty)" >&2
        echo "              $NEXUS_ROOT/node_modules/.bin/claude" >&2
        if [[ -n "${CLAUDE_BIN_NO_PATH:-}" ]]; then
            echo "              (PATH lookup suppressed: CLAUDE_BIN_NO_PATH)" >&2
        else
            echo "              claude on PATH" >&2
        fi
        echo "  Either set nexus.claude_bin to a native install, or run:" >&2
        echo "  $NEXUS_ROOT/monitor/install-claude-local.sh" >&2
        unset _cb_cfg _cb_rc
        exit 1
    fi
    unset _cb_cfg _cb_rc
fi
export CLAUDE_BIN
