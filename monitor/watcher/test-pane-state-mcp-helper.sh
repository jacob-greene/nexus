#!/usr/bin/env bash
# test-pane-state-mcp-helper.sh — an MCP server's helper shell is not a
# background TASK shell; a real task shell, blocked or not, still is
# (your-org/nexus-code#1851).
#
# THE DEFECT. `_pane_background_shells` counted every shell below claude as a
# background-shell ROOT, at any depth. An MCP server launched as
# `npm exec <pkg>` runs `sh -c <bin>` for its whole life, static and at 0 CPU,
# so the full-state emit flagged its window `idle-awaiting-job … WEDGED?` on
# every snapshot (measured 2026-10-16 on a live window:
# `bg_cmd=sh:sh_-c_notion-mcp-server`, the longjob dispatcher ALREADY excluded,
# `bg_longjob=1`). #1851 blamed the dispatcher because the row printed no child.
#
# THE DISCRIMINATOR IS THE SESSION. Claude Code launches tool and monitor shells
# DETACHED (each a session leader); MCP servers stay in claude's session. The
# fix skips a shell that sits under a NON-shell direct child of claude in
# claude's own session, and only once the walk has SEEN claude detach a shell.
#
# REAL PROCESSES, NOT A STUB: `claude` and `npm` are copies of bash under those
# names, so `/proc/<pid>/stat` reports the comm the census keys on, and
# `setsid` makes a real session leader. Every foreground is a builtin `read` on
# a FIFO opened read-write, so nothing forks and nothing exits until cleanup.
#
# Driven through `pane-state.sh --pane-pid`, the shipped entry point.
#
# Cases, and the PREDICTED FLIP for "delete the #1851 skip" (mutation pair):
#   M1  helper + a detached tool shell     count 1  → FLIPS to 2
#   M2  + a blocked SAME-SESSION direct tool shell        count 2 (must not flip)
#   M3  helper alone, no detached shell (gate off)        count 1 (must not flip)
#   M4  a helper whose wrapper LEFT claude's session      count 2 (must not flip)
#
# Run: bash monitor/watcher/test-pane-state-mcp-helper.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
_M_HELPER_REL=monitor/pane-state.sh
HELPER="$_repo_root/$_M_HELPER_REL"
_M_FIX_REL=monitor/watcher/fixtures/idle-empty-synthetic.ansi

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$_M_HELPER_REL" "$_M_FIX_REL"; }
gp_handle "$@"

. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=9
PASS=0
FAIL=0

ck() { if [[ "$2" == "$3" ]]; then printf '  PASS: %s (%s)\n' "$1" "$2"; _th_pass; else printf '  FAIL: %s — got %s want %s\n' "$1" "$2" "$3" >&2; _th_fail; fi; }

command -v pgrep >/dev/null 2>&1 || th_abort "pgrep required"
command -v setsid >/dev/null 2>&1 || th_abort "setsid required"
[[ -r /proc/$$/stat ]] || th_abort "/proc not readable"

WORK=$(mktemp -d -t nexus-mcp-helper-XXXXXX)
ROOTS=()
_tree() { local p="$1" k; printf '%s\n' "$p"; for k in $(pgrep -P "$p" 2>/dev/null); do _tree "$k"; done; }
cleanup() {
    local r p
    # Freeze top-down, kill bottom-up: a parent killed first reparents its
    # children out of reach (your-org/nexus-code#1543).
    for r in ${ROOTS[@]+"${ROOTS[@]}"}; do
        for p in $(_tree "$r"); do kill -STOP "$p" 2>/dev/null; done
        for p in $(_tree "$r" | tac); do kill -KILL "$p" 2>/dev/null; done
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# THE SHIPPED ENTRY POINT, not extracted units. A suite that sed-extracts the
# census functions tests their TEXT; if a refactor stopped the pattern matching,
# it would test nothing, or an older copy, and stay green. So every reading below
# is `pane-state.sh --pane-pid <claude>` itself, over an idle fixture (an idle
# REPL is what makes the census run), with a scratch state dir and no heartbeat.
_M_FIX="$_repo_root/$_M_FIX_REL"
[[ -x "$HELPER" ]] || th_abort "not executable: $HELPER"
[[ -r "$_M_FIX" ]] || th_abort "fixture missing: $_M_FIX"
export NEXUS_STATE_DIR="$WORK/state"; mkdir -p "$NEXUS_STATE_DIR/heartbeat"
unset NEXUS_WORKER_WINDOW TMUX TMUX_PANE
cp "$(command -v bash)" "$WORK/claude" || th_abort "could not stage a fake claude"
cp "$(command -v bash)" "$WORK/npm"    || th_abort "could not stage a fake npm"
LIFE=$(( $(th_deadline 60) + 30 ))
mkfifo "$WORK/life.fifo"
HOLD="read -r -t $LIFE _ <> $WORK/life.fifo"
# /bin/sh is dash here, whose `read` has no `-t`: the helper's sh holds without
# one, and cleanup's SIGKILL ends it.
HOLD_SH="read -r _ <> $WORK/life.fifo; true"
# Pieces of a tree, each run from the fake claude's script:
HELPER_MCP="$WORK/npm -c 'sh -c \"$HOLD_SH\"; true'"                 # same session, non-shell → sh
DETACHED="setsid bash -c '$HOLD'"                            # a tool shell: its own session
BLOCKED="bash -c '$HOLD; true'"                              # a SAME-session tool shell, blocked
HELPER_LEFT="setsid $WORK/npm -c 'sh -c \"$HOLD_SH\"; true'"          # helper wrapper that left the session

plant() {   # <script pieces joined with ' & '> → sets CL (the claude pid)
    "$WORK/claude" -c "$1 & $HOLD" >/dev/null 2>&1 &
    CL=$!; ROOTS+=("$CL"); disown "$CL" 2>/dev/null || true
}
settle() {   # <claude pid> <n processes expected below it>
    local end=$(( $(date +%s) + 20 )) n=0
    while (( $(date +%s) < end )); do
        n=$(( $(_tree "$1" | wc -l) - 1 ))
        (( n >= $2 )) && return 0
        sleep 0.2
    done
    th_abort "TREE-PLANT TIMEOUT: claude $1 has $n descendants, want $2"
}
# One pane-state reading per case. `bg_shells` is printed only for a
# working-background verdict, so an absent field reads as 0: the census found
# no task shell and the pane fell through to the idle refinements.
_ps_line() { "$HELPER" --fixture "$_M_FIX" --name w1 --now "$(date +%s)" --pane-pid "$1" 2>/dev/null; }
_field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }
count() { local l c; l=$(_ps_line "$1"); c=$(_field "$l" bg_shells); printf '%s' "${c:-0}"; }
desc()  { local l; l=$(_ps_line "$1"); _field "$l" bg_cmd; }

echo "=== M0: the plant is what the case says it is ==="
plant "$HELPER_MCP & $DETACHED"; C1=$CL; settle "$C1" 3
_n=$(pgrep -P "$C1" -x npm); _s=$(pgrep -P "$_n" 2>/dev/null)
ck "M0 the helper's shell shares claude's session" \
   "$(awk '{print $6}' "/proc/$_s/stat")" "$(awk '{print $6}' "/proc/$C1/stat")"
_d=$(pgrep -P "$C1" -x bash)
ck "M0 the detached tool shell is its own session leader" "$(awk '{print $6}' "/proc/$_d/stat")" "$_d"

echo "=== M1: a helper's shell is NOT counted once claude is seen detaching ==="
ck "M1 one background-shell root (the tool shell), not two" "$(count "$C1")" "1"
ck "M1 the root named is not the helper's sh" "$([[ "$(desc "$C1")" == sh:* ]] && echo sh || echo not-sh)" "not-sh"

echo "=== M2: NEGATIVE — a blocked tool shell in claude's OWN session is still counted ==="
# The orchestrator's ask on #1851: the skip must not hide a real wedge. A DIRECT
# child of claude is never skipped, whatever its session.
plant "$HELPER_MCP & $DETACHED & $BLOCKED"; C2=$CL; settle "$C2" 4
ck "M2 the blocked same-session tool shell is counted beside the detached one" "$(count "$C2")" "2"
_b=$(for p in $(pgrep -P "$C2" -x bash); do [[ "$(awk '{print $6}' "/proc/$p/stat")" != "$p" ]] && echo "$p"; done)
ck "M2 …and it really is in claude's session (the case is not vacuous)" \
   "$(awk '{print $6}' "/proc/$_b/stat")" "$(awk '{print $6}' "/proc/$C2/stat")"

echo "=== M3: NEGATIVE — no detached shell seen, the skip is OFF (old count stands) ==="
plant "$HELPER_MCP"; C3=$CL; settle "$C3" 2
ck "M3 a helper alone, with no evidence that claude detaches shells, is still counted" "$(count "$C3")" "1"
ck "M3 …and it is the helper's sh that was counted" "$(desc "$C3" | cut -d: -f1)" "sh"

echo "=== M4: NEGATIVE — a non-shell whose wrapper LEFT claude's session is a launched job ==="
plant "$HELPER_LEFT & $DETACHED"; C4=$CL; settle "$C4" 3
ck "M4 a shell under a setsid'd non-shell child is counted (2 roots)" "$(count "$C4")" "2"

echo
_ran=$(( PASS + FAIL ))
if (( _ran == EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
