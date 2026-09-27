#!/usr/bin/env bash
# monitor/tmux-server-path.sh — make a tmux SERVER's global PATH front the nexus
# tmux shim, so shell text the SERVER runs is judged too (your-org/nexus-code#1583).
#
#   monitor/tmux-server-path.sh --check [-S <socket> | -L <name>]
#   monitor/tmux-server-path.sh --apply [-S <socket> | -L <name>]
#
# WHY. monitor/tmuxwrap/tmux judges what an agent TYPES. It cannot follow shell
# text the server executes itself: `run-shell`, `#()` in a format,
# `default-command`, the command of new-window / split-window / respawn-*,
# `pipe-pane`, a hook that runs a shell. Those shells take their PATH from the
# server's GLOBAL environment. Measured 2026-09-18 on the live board:
# `tmux show-environment -g PATH` fronts agent-sandbox's own tmux (a thin
# `exec /usr/bin/tmux -f <conf>` wrapper), so a `tmux kill-server` inside such
# a shell reaches the real binary unjudged. Measured on a hermetic server with
# the board's PATH: `run-shell 'tmux kill-server'` killed it; with this
# directory's shim prepended to that server's PATH, the same command was
# REFUSED and the server lived (the job's environment carries $TMUX, so the
# shim identifies the server as the board).
#
# WHAT IT CHANGES. `--apply` rewrites ONE value, the server's global PATH, so
# the shim directory comes first; later panes, jobs and format commands inherit
# it. Existing panes keep the PATH they were started with. The shim passes every
# non-lethal command through unchanged, so nothing else about those shells
# changes. Reversible: `tmux set-environment -g PATH <old value>`, and `--apply`
# prints the old value first.
#
# EXIT CODES — three-valued on purpose; "could not tell" is never "no":
#   0  --check: the first PATH entry holding an executable `tmux` IS the shim
#      directory. --apply: the same, after the rewrite (verified by re-reading).
#   1  --check: it is not (the winning `tmux` is printed).
#   2  usage.
#   3  the server's PATH could not be read (no server on that socket, or tmux
#      answered in a shape this script does not parse). Nothing was changed.
#
# NOT A GUARANTEE. A shell that names a tmux by absolute path (`/usr/bin/tmux
# kill-server`) is not routed through PATH at all. The shim is defence in depth
# against ACCIDENTS, which is the same boundary its own header states.
#
# WHAT IT CLOSES, EXACTLY: a DIRECT `tmux <kill>` in server-run SHELL text. It
# does NOT close the command CARRIERS (if-shell's commands, source-file,
# set-hook, bind-key, …): their payload is tmux command text the server parses
# INSIDE itself, with no PATH lookup, so fronting PATH never reaches it. The
# shim judges that payload directly, for every caller (#1583, semisplitsk2 F4).
#
# WHAT UNDOES IT, SILENTLY (semisplitsk2 F5) — none of these is refused:
#   * `tmux set-environment -g PATH <anything>`;
#   * a command-alias, or a sourced config line, whose leading word is
#     `PATH=<value>`: tmux 2.6's cmd_string_split `environ_put`s a leading
#     NAME=value word into the server's GLOBAL environment (measured with a
#     marker variable, `zp=ZZSK2=1 list-windows`);
#   * a server restart: the global environment is rebuilt from the launcher's
#     (reason 3 in monitor/install-shell-hook.sh's own header).
# So `--check` is the thing to re-run, not a memory of having applied it.
#
# RUN IT FROM THE PRIMARY CLONE. `--apply` fronts THIS script's own shim
# directory. Run from a secondary clone or worktree, it fronts a path that
# dangles the moment that clone is removed; the server's shells then fall
# through to the next `tmux` on PATH, unjudged, with nothing to say so.

set -u
_sp_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
_sp_shim_dir="$_sp_self_dir/tmuxwrap"
[ -x "$_sp_shim_dir/tmux" ] || { echo "tmux-server-path: no executable shim at $_sp_shim_dir/tmux" >&2; exit 2; }

_sp_mode=""; _sp_sock=()
while [ $# -gt 0 ]; do
    case "$1" in
        --check|--apply) _sp_mode="${1#--}"; shift ;;
        -S|-L) [ $# -ge 2 ] || { echo "tmux-server-path: $1 needs a value" >&2; exit 2; }
               _sp_sock=("$1" "$2"); shift 2 ;;
        -h|--help) sed -n '2,59p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "tmux-server-path: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
[ -n "$_sp_mode" ] || { echo "usage: tmux-server-path.sh --check|--apply [-S socket | -L name]" >&2; exit 2; }

# The REAL tmux for our own two calls: first PATH candidate that is not a script,
# so this helper never depends on the shim it is installing (same rule as the
# tmux-touching suites' _nx_real_tmux_bin).
_sp_real=""
_sp_rest="$PATH:"
while [ -n "$_sp_rest" ]; do
    _sp_d="${_sp_rest%%:*}"; _sp_rest="${_sp_rest#*:}"
    [ -n "$_sp_d" ] && [ -x "$_sp_d/tmux" ] && [ ! -d "$_sp_d/tmux" ] || continue
    _sp_magic=$(head -c 2 -- "$_sp_d/tmux" 2>/dev/null) || continue
    [ "$_sp_magic" = '#!' ] || { _sp_real="$_sp_d/tmux"; break; }
done
[ -n "$_sp_real" ] || { echo "tmux-server-path: no real tmux BINARY on PATH" >&2; exit 3; }

_sp_read() {   # -> _sp_path (the server's global PATH); rc 3 when it cannot be read
    local out
    out=$("$_sp_real" ${_sp_sock[@]+"${_sp_sock[@]}"} show-environment -g PATH 2>/dev/null) || return 3
    case "$out" in PATH=*) _sp_path="${out#PATH=}"; return 0 ;; esac
    return 3
}
_sp_winner() {  # <path> -> _sp_win: the directory whose `tmux` that PATH selects ("" if none)
    local rest="$1:" d
    _sp_win=""
    while [ -n "$rest" ]; do
        d="${rest%%:*}"; rest="${rest#*:}"
        [ -n "$d" ] && [ -x "$d/tmux" ] && [ ! -d "$d/tmux" ] || continue
        _sp_win="$d"; return 0
    done
    return 0
}
_sp_is_shim() { [ -n "$1" ] && [ "$1/tmux" -ef "$_sp_shim_dir/tmux" ]; }

_sp_read || { echo "tmux-server-path: could not read the server's global PATH (no server on that socket?) — nothing changed" >&2; exit 3; }
_sp_winner "$_sp_path"
if _sp_is_shim "$_sp_win"; then
    echo "tmux-server-path: OK — the server's global PATH selects the shim ($_sp_win/tmux)"
    exit 0
fi
if [ "$_sp_mode" = check ]; then
    echo "tmux-server-path: NOT FRONTED — the server's global PATH selects ${_sp_win:-no tmux at all}${_sp_win:+/tmux}, not $_sp_shim_dir/tmux"
    exit 1
fi

# --apply: prepend the shim dir, dropping any existing copy of it further down.
_sp_new="$_sp_shim_dir"
_sp_rest="$_sp_path:"
while [ -n "$_sp_rest" ]; do
    _sp_d="${_sp_rest%%:*}"; _sp_rest="${_sp_rest#*:}"
    [ -n "$_sp_d" ] || continue
    [ "$_sp_d" -ef "$_sp_shim_dir" ] && continue
    _sp_new="$_sp_new:$_sp_d"
done
echo "tmux-server-path: previous global PATH (to revert: tmux set-environment -g PATH '<this>'):"
printf '  %s\n' "$_sp_path"
"$_sp_real" ${_sp_sock[@]+"${_sp_sock[@]}"} set-environment -g PATH "$_sp_new" 2>/dev/null \
    || { echo "tmux-server-path: set-environment FAILED — nothing changed" >&2; exit 3; }
_sp_read || { echo "tmux-server-path: applied, but the PATH could not be re-read to verify" >&2; exit 3; }
_sp_winner "$_sp_path"
if _sp_is_shim "$_sp_win"; then
    echo "tmux-server-path: APPLIED — the server's global PATH now selects the shim ($_sp_win/tmux)"
    exit 0
fi
echo "tmux-server-path: applied, but the re-read PATH still selects ${_sp_win:-no tmux}/tmux" >&2
exit 1
