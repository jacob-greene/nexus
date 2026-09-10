#!/usr/bin/env bash
# monitor/cc-harness/_lib.sh — shared library for the real-binary CC
# test harness. Boots the *real* `claude` against the auth-free mock
# backend (mock-backend.py) in a dedicated, isolated tmux socket, then
# drives it and classifies its panes with the production
# monitor/pane-state.sh.
#
# This is the complement to monitor/watcher/test-integration/_harness.sh:
# that harness drives a fully *fake* `claude` shim (stub-claude.sh); this
# one drives the *real* binary so the actual boot / hook / tool-loop /
# pane-rendering surface is exercised. The mock supplies the "model"
# (canned or control-file-injected responses) with NO Anthropic auth and
# NO network egress.
#
# Globals set by cch_setup (exported for child processes):
#   CCH_DIR        tmpdir root for this run
#   CCH_CFG        isolated CLAUDE_CONFIG_DIR (no real creds ever live here)
#   CCH_WORKDIR    pinned project cwd for the booted claude (pre-trusted)
#   CCH_STATE_DIR  $CCH_DIR/state (NEXUS_STATE_DIR for pane-state)
#   CCH_SOCKET     tmux -L socket name (isolated; never the live session)
#   CCH_SESSION    tmux session name
#   CCH_MOCK_PORT  port the mock bound (discovered when launched with :0)
#   CCH_MOCK_PID   pid of the mock backend
#   CCH_CONTROL    path to the injectable control.json
#   CCH_TMUXWRAP   PATH-shadow tmux wrapper that injects -L $CCH_SOCKET
#   CLAUDE_BIN     resolved real claude binary (override to gate a candidate)
#
# Conventions mirror _harness.sh: cch_tmux for socket-scoped tmux,
# wait_for/hold_false for polling predicates, assert_* from
# _test_helpers.sh.

set -uo pipefail

_cch_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CCH_REPO_ROOT=$(cd "$_cch_self_dir/../.." && pwd)

# trash_path: rename-aside instead of unlink for teardown, so a still-
# releasing claude config dir over NFS can't make `rm` fail with
# `.nfs`/"Directory not empty".
# shellcheck source=../_trash.sh
. "$CCH_REPO_ROOT/monitor/_trash.sh"
CCH_MOCK_PY="$_cch_self_dir/mock-backend.py"
CCH_PANE_STATE="$CCH_REPO_ROOT/monitor/pane-state.sh"

# Resolve the REAL tmux executable, ignoring any shell alias/function
# (`type -P` returns the PATH binary only). The agent-sandbox ships an
# aliased `tmux='tmux -2'`; a bare `command -v tmux` would capture the
# alias and produce a broken wrapper.
_cch_real_tmux() {
    local t
    t=$(type -P tmux 2>/dev/null) && [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    for c in /usr/bin/tmux /usr/local/bin/tmux; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return; }
    done
    return 1
}

# Resolve the real python3.
_cch_python() {
    command -v python3 2>/dev/null || command -v python 2>/dev/null
}

# Skip-gate. Scenarios call this BEFORE cch_setup so the skip path is
# cheap. Gated on RUN_CC_HARNESS=1 (separate axis from RUN_INTEGRATION,
# since this suite additionally needs node + a real claude binary).
#
# Exit code: 0 normally (so the fast-loop runner monitor/watcher/
# run-tests.sh — which counts rc==0 as PASS — treats a self-skip as a
# clean non-failure, matching SLOW_TESTS / RUN_INTEGRATION). BUT under the
# pre-update gate (CCH_GATE=1) a skip is NOT benign: it means the gate
# could not actually validate the candidate, so it must NOT be confused
# with a pass. There we exit 77 (the autotools "SKIP" sentinel) so
# gate.sh can fail RED on any skip — the exact green-via-skip hole B12
# closes (your-org/your-nexus#236 U12). 77 is unused by these scenarios'
# real pass/fail paths.
cch_skip_if_disabled() {
    local why=""
    if [[ "${RUN_CC_HARNESS:-0}" != "1" ]]; then
        why="set RUN_CC_HARNESS=1 to enable"
    elif ! _cch_real_tmux >/dev/null; then
        why="tmux not on PATH"
    elif ! command -v node >/dev/null 2>&1; then
        why="node not on PATH"
    elif ! _cch_python >/dev/null; then
        why="python3 not on PATH"
    elif ! cch_resolve_claude >/dev/null 2>&1; then
        why="no claude binary (run monitor/install-claude-local.sh, or set CLAUDE_BIN)"
    fi
    if [[ -n "$why" ]]; then
        echo "skipped: $(basename "${0}") ($why)"
        [[ "${CCH_GATE:-0}" == "1" ]] && exit 77
        exit 0
    fi
}

# Resolve the claude binary. Honors CLAUDE_BIN (the pre-update gate sets
# this to a candidate-version install in a throwaway prefix); else the
# project-local install. Echoes the path; rc=1 if none found.
cch_resolve_claude() {
    if [[ -n "${CLAUDE_BIN:-}" ]] && [[ -x "$CLAUDE_BIN" ]]; then
        printf '%s' "$CLAUDE_BIN"; return 0
    fi
    local local_bin="$CCH_REPO_ROOT/node_modules/.bin/claude"
    if [[ -x "$local_bin" ]]; then
        printf '%s' "$local_bin"; return 0
    fi
    return 1
}

# Bring up the run: tmpdir, mock backend, isolated config + tmux socket.
cch_setup() {
    CLAUDE_BIN=$(cch_resolve_claude) || { echo "cch_setup: no claude binary" >&2; return 1; }
    export CLAUDE_BIN

    CCH_DIR=$(mktemp -d -t cc-harness-XXXXXX)
    CCH_CFG="$CCH_DIR/cfg"
    CCH_WORKDIR="$CCH_DIR/proj"
    CCH_STATE_DIR="$CCH_DIR/state"
    CCH_CONTROL="$CCH_DIR/control.json"
    CCH_LOG="$CCH_DIR/requests.log"
    CCH_SOCKET="cch-$$-$RANDOM"
    CCH_SESSION="cch-$$-$RANDOM"
    mkdir -p "$CCH_CFG" "$CCH_WORKDIR" "$CCH_STATE_DIR" "$CCH_DIR/.bin"

    # Pre-seed config so the real binary skips ALL first-run gates:
    #   theme picker -> theme + hasCompletedOnboarding
    #   folder trust -> per-project projects.<cwd>.hasTrustDialogAccepted
    # (custom-API-key dialog is avoided by using ANTHROPIC_AUTH_TOKEN
    # rather than ANTHROPIC_API_KEY — see cch_boot_worker.)
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg wd "$CCH_WORKDIR" '{
            theme: "dark", hasCompletedOnboarding: true,
            bypassPermissionsModeAccepted: true,
            projects: { ($wd): {
                hasTrustDialogAccepted: true,
                hasCompletedProjectOnboarding: true, allowedTools: [] } }
        }' > "$CCH_CFG/.claude.json"
    else
        printf '{"theme":"dark","hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true,"projects":{"%s":{"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true,"allowedTools":[]}}}\n' \
            "$CCH_WORKDIR" > "$CCH_CFG/.claude.json"
    fi

    # Default control directive: single-shot canned text.
    cch_control '{"mode":"text","text":"MOCK_OK_HELLO"}'

    # Start the mock on an ephemeral port; discover what it bound.
    local py; py=$(_cch_python)
    local port_file="$CCH_DIR/mock.port"
    MOCK_DIR="$CCH_DIR" MOCK_LOG="$CCH_LOG" MOCK_CONTROL="$CCH_CONTROL" \
        MOCK_PORT_FILE="$port_file" \
        "$py" "$CCH_MOCK_PY" 0 >"$CCH_DIR/mock.stderr" 2>&1 &
    CCH_MOCK_PID=$!
    local waited=0
    while [[ ! -s "$port_file" ]]; do
        sleep 0.1; waited=$((waited+1))
        if (( waited > 50 )); then
            echo "cch_setup: mock backend never advertised a port" >&2
            cat "$CCH_DIR/mock.stderr" >&2 || true
            return 1
        fi
        kill -0 "$CCH_MOCK_PID" 2>/dev/null || {
            echo "cch_setup: mock backend died on startup" >&2
            cat "$CCH_DIR/mock.stderr" >&2 || true
            return 1
        }
    done
    CCH_MOCK_PORT=$(<"$port_file")

    # PATH-shadow tmux wrapper so pane-state.sh's bare `tmux` calls hit
    # our isolated socket. Resolve the real tmux at write time.
    local real_tmux; real_tmux=$(_cch_real_tmux)
    CCH_TMUXWRAP="$CCH_DIR/.bin/tmux"
    printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$real_tmux" "$CCH_SOCKET" > "$CCH_TMUXWRAP"
    chmod +x "$CCH_TMUXWRAP"

    # Bring up the isolated server with a detached scratch window. -f
    # /dev/null ignores the operator's personal tmux.conf.
    cch_tmux -f /dev/null new-session -d -s "$CCH_SESSION" \
        -x 120 -y 40 -c "$CCH_WORKDIR" 'sleep 36000'

    export CCH_DIR CCH_CFG CCH_WORKDIR CCH_STATE_DIR CCH_CONTROL CCH_LOG \
           CCH_SOCKET CCH_SESSION CCH_MOCK_PORT CCH_MOCK_PID CCH_TMUXWRAP

    trap cch_teardown EXIT
}

cch_teardown() {
    if [[ -n "${CCH_TMUXWRAP:-}" && -x "${CCH_TMUXWRAP:-}" ]]; then
        cch_tmux kill-server 2>/dev/null || true
    fi
    if [[ -n "${CCH_MOCK_PID:-}" ]]; then
        kill "$CCH_MOCK_PID" 2>/dev/null || true
    fi
    if [[ -n "${CCH_DIR:-}" && -d "${CCH_DIR:-}" ]]; then
        # Move the run dir aside (rename) instead of rm: the killed claude
        # may still be releasing its config dir, and over NFS unlink would
        # silly-rename open files to `.nfs*` and make rm report "Directory
        # not empty". A same-fs rename always succeeds regardless of holders;
        # the entry is reaped later by `_trash.sh --clear`. Fall back to the
        # old settle+retry rm if trashing is unavailable.
        trash_path "$CCH_DIR" >/dev/null 2>&1 \
            || { sleep 0.3; rm -rf "$CCH_DIR" 2>/dev/null \
                || { sleep 0.7; rm -rf "$CCH_DIR" 2>/dev/null || true; }; }
    fi
}

# Socket-scoped tmux (uses the real binary directly with -L).
cch_tmux() {
    local real_tmux; real_tmux=$(_cch_real_tmux)
    "$real_tmux" -L "$CCH_SOCKET" "$@"
}

# Write a control directive (JSON string) for the mock's NEXT request.
cch_control() {
    printf '%s\n' "$1" > "$CCH_CONTROL"
}

# Build the launch command string for a harness worker. THE SINGLE
# CONSTRUCTION SITE — every scenario must reach the launch string through
# here, never by copying the `printf -v launch` block. Two scenarios
# copied that block on 2026-09-09 (both working on your-org/nexus-code#157)
# because the only way to drop one flag was to reproduce all of it.
# Duplicated launch flags drift silently from the production spawn flags,
# so a scenario ends up gating a boot the watcher never performs.
#
# env -i gives a hermetic child: only the vars claude needs. PATH must
# carry node (claude is a node program) — pass the harness PATH through.
# ANTHROPIC_AUTH_TOKEN (bearer) instead of ANTHROPIC_API_KEY avoids the
# interactive custom-API-key approval dialog.
#
# CCH_SKIP_PERMISSIONS (default 1) is the one knob:
#
#   1 (default)  append `--dangerously-skip-permissions`, exactly as
#                every scenario booted before this knob existed.
#   0            omit it, so the real binary renders its permission
#                dialog when the mock drives a file-writing tool. That
#                flag is precisely what suppresses the dialog, so no
#                harness scenario could paint one until now
#                (your-org/nexus-code#158).
#
# WHY AN ENV KNOB AND NOT A `cch_boot_prompting_worker` VARIANT: a
# separate function would need its own copy of the launch string — the
# defect this change exists to remove — unless it delegated here anyway.
# One knob keeps ONE construction site. `cch_boot_prompting_worker` still
# exists below, but only as a one-line wrapper that sets the knob, so a
# call site can read as prose without a second copy of the flags.
#
# The knob is read at call time, not at source time, so a scenario may
# boot a default worker and a prompting worker in the same run.
cch_launch_cmd() {
    # A separate `%s` tail rather than a literal inside the format string:
    # with CCH_SKIP_PERMISSIONS unset the expansion is byte-for-byte the
    # pre-knob string. monitor/test-cch-launch-string.sh proves
    # that against the flag's construction site at c9c07bc.
    local skip_flag=' --dangerously-skip-permissions'
    [[ "${CCH_SKIP_PERMISSIONS:-1}" == "0" ]] && skip_flag=''
    local launch
    printf -v launch 'env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q \
ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 \
TERM=%q %q%s' \
        "$CCH_CFG" "$PATH" "$CCH_CFG" \
        "http://127.0.0.1:$CCH_MOCK_PORT" "${TERM:-xterm-256color}" \
        "$CLAUDE_BIN" "$skip_flag"
    printf '%s' "$launch"
}

# Boot the real claude in a new tmux window against the mock. Echoes the
# new window's index. Renderer-path only (no --settings hooks) so this
# exercises pane-state's renderer classification; a heartbeat-substrate
# variant is a documented follow-up.
#
#   cch_boot_worker <window-name> [workdir]
#
# `workdir` defaults to $CCH_WORKDIR, the pre-trusted project dir. A
# scenario that needs a different cwd (an untrusted nested repo, say)
# passes it here instead of rebuilding the launch string.
cch_boot_worker() {
    local name="$1" workdir="${2:-$CCH_WORKDIR}"
    local launch
    launch=$(cch_launch_cmd)

    cch_tmux new-window -d -t "$CCH_SESSION": -n "$name" -c "$workdir" "$launch"
    local idx
    idx=$(cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' \
        | awk -v n="$name" '$1==n {print $2; exit}')
    # remain-on-exit keeps the dead pane (and its last frame) around after
    # the inner REPL exits, so pane-state's process-liveness gate can
    # emit `absent` instead of the window vanishing — mirrors how the
    # production watcher configures worker windows.
    [[ -n "$idx" ]] && cch_tmux set-option -t "$CCH_SESSION:$idx" -w remain-on-exit on 2>/dev/null
    printf '%s' "$idx"
}

# Boot a worker WITHOUT `--dangerously-skip-permissions`, so the real
# binary renders its permission dialog when the mock drives a
# file-writing tool. Same arguments as cch_boot_worker. A one-line
# wrapper on purpose: readable at the call site, no second copy of the
# launch flags.
cch_boot_prompting_worker() {
    CCH_SKIP_PERMISSIONS=0 cch_boot_worker "$@"
}

# Run the production pane-state.sh against a live window via the wrapper.
cch_pane_state() {
    local window="$1"
    PATH="$CCH_DIR/.bin:$PATH" NEXUS_STATE_DIR="$CCH_STATE_DIR" \
        "$CCH_PANE_STATE" "$CCH_SESSION:$window"
}

# Convenience: just the state= token.
cch_state() {
    cch_pane_state "$1" | sed -n 's/.*state=\([^ ]*\).*/\1/p'
}

# Capture a window's pane (plain text, last 25 rows like pane-state).
cch_capture() {
    cch_tmux capture-pane -t "$CCH_SESSION:$1" -p -J -S -25 2>/dev/null
}

# --- permission-dialog assertion (your-org/nexus-code#158, Part B) --------
#
# THE PROBLEM THIS SOLVES. A scenario that expects Claude Code's
# tool-permission dialog and paints none still reads a plausible pane
# state, so the run looks like a pass. That happened three times: the
# 2.1.263 evaluation, the 2.1.267 evaluation, and the published #157
# script, whose control arm ran `Bash true` and therefore exercised
# nothing. A convention written down twice and broken three times needs
# a mechanism. These helpers ARE the mechanism, and they are deliberately
# generic — any scenario that drives a file-writing tool can use them.
#
# WHAT IT ASSERTS ON, and why not the obvious thing. It does NOT key on
# the option-2 text (`Yes, allow all edits during this session
# (shift+tab)`). That literal changed between cc 2.1.220 and 2.1.267, and
# the same instability broke the folder-trust detector at 2.1.260. It
# keys instead on the parts that held across both releases and across
# both dialog shapes (`Write` -> "Do you want to create …?", `Edit` ->
# "Do you want to make this edit to …?"):
#
#   1. a first option row `1. Yes`, with or without the chevron;
#   2. a numbered decline row, `N. No`;
#   3. the two footer phrases `Esc to cancel` and `Tab to amend`;
#   4. LIVENESS: a chevron sitting on a NUMBERED option row.
#
# It does NOT key on the question literal either. That is the whole point
# of the exercise: monitor/pane-state.sh carries exactly one question
# literal and therefore misses both file-edit shapes (#157). An assertion
# built on the same literal could never catch that.
#
# The two footer phrases are matched SEPARATELY, not as one string. The
# release under probe joins them with U+00B7 surrounded by plain spaces;
# a future release that changes the separator must not silently turn this
# assertion off.
#
# Requirement 4 is what stops prose from matching. An agent transcript
# quoting this comment, or a report describing the dialog, carries the
# words but never a chevron-selected numbered option row. It mirrors the
# liveness leg of `pane-state.sh::_has_trust_overlay`.
#
# Requirement 3 is what separates this from the folder-trust dialog,
# whose footer is `Enter to confirm · Esc to cancel` — no `Tab to amend`.

# CO-LOCATION. The five legs are NOT matched independently across the
# whole frame. They were at first, and that was a false-positive hole:
# a transcript quoting the dialog prose satisfies legs 1, 2 and 3 on its
# own, so ANY unrelated live chevron row elsewhere in the same 25-row
# capture — an AskUserQuestion menu, say — completed the match with no
# dialog present. Found by the nexus-158 skeptic, request 001.
#
# The frame is therefore reduced to a WINDOW first, anchored on the LAST
# row carrying `Esc to cancel`:
#
#   legs 1, 2 and 4 must all land in the eight rows ABOVE the anchor;
#   leg 3b (`Tab to amend`) must land at the anchor or within two rows.
#
# Above-only for the option rows is what closes the hole: a menu pasted
# BELOW a quoted footer cannot lend its chevron to the match. Eight rows
# is generous against the measured dialog, whose option rows sit two to
# four rows above the footer, and it tolerates a longer option list.
#
# Two rows of slack for `Tab to amend` rather than requiring the same
# row: both measured releases render one footer row, but a narrow pane
# could wrap it.
#
# Rows are tagged `A|` (above the anchor) or `B|` (anchor and below) so
# the caller can apply a leg to one region or to the window as a whole.
_cch_dialog_window() {
    local plain="$1"
    awk '
        { line[NR] = $0; if (index($0, "Esc to cancel")) anchor = NR }
        END {
            if (!anchor) exit 1
            start = anchor - 8; if (start < 1) start = 1
            stop  = anchor + 2; if (stop > NR)  stop  = NR
            for (i = start; i <= stop; i++)
                print (i < anchor ? "A|" : "B|") line[i]
        }
    ' <<<"$plain"
}

# Predicate. rc 0 if the frame carries a live tool-permission dialog.
# Silent: for scenarios that need to branch rather than fail.

# ORDERING, within the window. The chevron row must sit AT or BELOW the
# `1. Yes` row. Constraining every leg to the eight rows above the anchor
# still left the mirror of the original hole open: a live menu drawn
# ABOVE a quoted dialog lends its chevron to option rows it has nothing
# to do with, and both land in the same window. Found by the nexus-158
# skeptic, request 002.
#
#     ❯ 1. Blue                      <- live menu, unrelated
#       2. Green
#      ⎿ docs quote the dialog:
#            1. Yes                  <- quoted, not live
#            3. No
#            Esc to cancel · Tab to amend
#
# A real selection only ever moves DOWN the option list from `1. Yes`, so
# this rule costs nothing legitimate: the chevron on option 1, 2 or 3 of
# a real dialog all still match.
# ONE OVERLAY, not "legs somewhere in a window". The two rules above
# constrain WHERE each leg may sit relative to the anchor. Neither
# requires the legs to BELONG TO THE SAME overlay, so each round of
# fixing closed one arrangement and left the next one open. The
# nexus-158 skeptic found three arrangements in three tries, which is
# what independent greps over a shared window will always produce.
# Request 004 named the property that closes the class instead of the
# instance, and this is it.
#
# A rendered option list has structure that prose plus an unrelated menu
# never has:
#
#   CONTIGUITY  the numbered option rows are consecutive lines;
#   ALIGNMENT   their `N.` tokens start in the SAME column.
#
# So the frame is scanned for maximal RUNS of consecutive numbered option
# rows, and one single run must carry all of: the `1. Yes` row, an
# `N. No` row, a chevron, and the chevron at or below the `1. Yes` row.
#
# This rejects the interleaved shape, where a live menu row sits between
# two quoted option rows. Those three rows are consecutive, but the
# menu row's number starts in a different column, so they are not one
# option list:
#
#      ⎿ docs quote the dialog:
#           1. Yes            <- column 12
#     ❯ 2. Blue               <- column 7, so not the same list
#           3. No             <- column 12
#           Esc to cancel · Tab to amend
#
# EXACT `1. Yes`. The first option row of the permission dialog is the
# bare word `Yes` and nothing else, measured on 2.1.173 and 2.1.220.
# The folder-trust dialog's is `1. Yes, I trust this folder`. Requiring
# the exact row rejects the trust dialog on its own merits, rather than
# relying on `Tab to amend` being absent — which the skeptic showed can
# be borrowed from an adjacent line of unrelated text.
_cch_option_run_ok() {
    local above="$1"
    awk '
        function digitcol(s,   p) { p = match(s, /[0-9]+\./); return p }
        { line[NR] = $0 }
        END {
            opt  = "^[ \t]*(❯[ \t]+)?[0-9]+\\.[ \t]"
            yes  = "^[ \t]*(❯[ \t]+)?1\\.[ \t]+Yes[ \t]*$"
            no   = "^[ \t]*(❯[ \t]+)?[0-9]+\\.[ \t]+No[ \t]*$"
            chev = "❯[ \t]+[0-9]+\\."
            i = 1
            while (i <= NR) {
                if (line[i] !~ opt) { i++; continue }
                j = i
                while (j + 1 <= NR && line[j + 1] ~ opt) j++
                col = -1; aligned = 1
                haveyes = 0; haveno = 0; havechev = 0; yidx = 0; cidx = 0
                for (k = i; k <= j; k++) {
                    c = digitcol(line[k])
                    if (col < 0) col = c
                    else if (c != col) aligned = 0
                    if (!haveyes  && line[k] ~ yes)  { haveyes = 1;  yidx = k }
                    if (             line[k] ~ no)     haveno = 1
                    if (!havechev && line[k] ~ chev) { havechev = 1; cidx = k }
                }
                if (aligned && haveyes && haveno && havechev && cidx >= yidx)
                    exit 0
                i = j + 1
            }
            exit 1
        }
    ' <<<"$above"
}

cch_has_permission_dialog() {
    local plain="$1" window above whole
    window=$(_cch_dialog_window "$plain") || return 1
    [[ -n "$window" ]] || return 1
    above=$(grep '^A|' <<<"$window" | sed 's/^A|//')
    whole=$(sed 's/^[AB]|//' <<<"$window")
    _cch_option_run_ok "$above" \
        && grep -qF 'Tab to amend' <<<"$whole"
}

# Assertion. rc 0 if the frame carries the dialog; otherwise rc 1 AND a
# loud diagnostic on stderr naming which leg failed, with the frame
# quoted so a CI log carries the evidence.
#
#   cch_assert_permission_dialog "$frame" "<what the probe expected>"
#
# rc 1 rather than `exit 1`: a scenario tallies it through its own
# ok()/bad() pair, exactly like every other assertion in the suite. The
# loudness is the stderr diagnostic plus the non-zero return.
cch_assert_permission_dialog() {
    local plain="$1" label="${2:-permission dialog}"
    if cch_has_permission_dialog "$plain"; then
        return 0
    fi
    {
        printf 'cch_assert_permission_dialog: NO PERMISSION DIALOG IN FRAME\n'
        printf '  expected: %s\n' "$label"
        printf '  missing legs:\n'
        # Each leg is reported against the SAME region the predicate
        # tests it in, so the diagnostic cannot say a leg is present
        # while the predicate rejects it for being in the wrong place.
        local window above whole
        window=$(_cch_dialog_window "$plain") || window=""
        above=$(grep '^A|' <<<"$window" 2>/dev/null | sed 's/^A|//')
        whole=$(sed 's/^[AB]|//' <<<"$window" 2>/dev/null)
        if [[ -z "$window" ]]; then
            printf '    - the footer phrase `Esc to cancel` (no anchor row, so no window)\n'
        else
            if ! _cch_option_run_ok "$above"; then
                printf '    - one contiguous, column-aligned run of numbered option\n'
                printf '      rows, in the 8 rows above the footer, carrying ALL of:\n'
                printf '      an exact `1. Yes` row, an `N. No` row, and a chevron\n'
                printf '      at or below the `1. Yes` row.\n'
                # Which individual pieces are present at all, purely to
                # orient the reader. These are NOT the predicate: a leg
                # can be present here and still not belong to any single
                # option run.
                printf '      present somewhere in that region:'
                grep -qE '^[[:space:]]*(❯[[:space:]]+)?1\.[[:space:]]+Yes[[:space:]]*$' <<<"$above" \
                    && printf ' `1. Yes`'
                grep -qE '^[[:space:]]*(❯[[:space:]]+)?[0-9]+\.[[:space:]]+No[[:space:]]*$' <<<"$above" \
                    && printf ' `N. No`'
                grep -qE '❯[[:space:]]+[0-9]+\.' <<<"$above" \
                    && printf ' a chevron row'
                printf '\n'
            fi
            grep -qF 'Tab to amend' <<<"$whole" \
                || printf '    - the footer phrase `Tab to amend`, at or near the footer\n'
        fi
        printf '  frame captured:\n'
        sed 's/^/    | /' <<<"$plain"
    } >&2
    return 1
}

# Poll a window until its pane carries a permission dialog. Echoes the
# frame it settled on (dialog present or not) so the caller can assert
# and report on the SAME bytes it waited for. rc 0 if the dialog
# appeared, 1 on timeout.
#
#   frame=$(cch_wait_permission_dialog "$win" 20) || ...
#
# Never treat a timeout as benign: a probe that expected a dialog and
# timed out has established nothing about the pane it goes on to classify.
cch_wait_permission_dialog() {
    local window="$1" timeout_s="${2:-25}" waited=0 frame=""
    while (( waited < timeout_s )); do
        frame=$(cch_capture "$window")
        if cch_has_permission_dialog "$frame"; then
            printf '%s' "$frame"
            return 0
        fi
        sleep 1; waited=$((waited+1))
    done
    printf '%s' "$frame"
    return 1
}

# Send a prompt the way the watcher injects: type the text, then Enter
# as a separate key (mirrors the send-keys paste-to-target path).
cch_send() {
    local window="$1" text="$2"
    cch_tmux send-keys -t "$CCH_SESSION:$window" "$text"
    sleep 0.4
    cch_tmux send-keys -t "$CCH_SESSION:$window" Enter
}

# Kill the inner claude process for a window (simulate a crash) so the
# pane goes to state=absent under remain-on-exit. PID-SCOPED ONLY: walks the
# pane shell's descendant tree by parent-PID and TERMs each node. NEVER use a
# cmdline-pattern kill (`pkill -f`) here — every nexus agent runs the SAME
# project-local claude binary inside ONE shared sandbox PID namespace, so a
# command-line match SIGTERMs the whole control plane at once (crash
# postmortem 2026-05-29; reports/nexus_2026-05-29_142117_crash-postmortem-pkill-mass-kill.md).
# lint-no-mass-kill.sh enforces this ban.
cch_kill_claude() {
    local window="$1" pane_pid
    pane_pid=$(cch_tmux display-message -p -t "$CCH_SESSION:$window" '#{pane_pid}' 2>/dev/null)
    [[ -n "$pane_pid" ]] || return 1
    _cch_kill_tree "$pane_pid"
}

# Collect a PID and all its descendants, leaves first, via `pgrep -P`
# (parent-PID) walks only — never by command-line pattern.
_cch_tree_pids() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _cch_tree_pids "$child"
    done
    printf '%s\n' "$pid"
}

# TERM a PID subtree (leaves first), grant a short grace, then KILL any
# survivor. Scoped strictly to a one-shot snapshot of the subtree rooted
# at $1 — pid-scoped, never cmdline-matched (see cch_kill_claude above).
#
# The KILL escalation is load-bearing for the absent scenario: claude
# installs a graceful-shutdown SIGTERM handler, and on slow shared CI
# runners its teardown has been observed to outlive the scenario's 15 s
# `state=absent` window (cc-harness runs 26909460209 on dev and
# 27389919749 on PR 270 — identical flake signature on both sides of
# the #205 change; locally TERM→exit measures ~0.1 s). The scenario
# simulates a CRASH, so forcing the exit after a 2 s grace is faithful
# to the intent and removes the dependence on claude's teardown latency.
_cch_kill_tree() {
    local root="$1" pids pid alive i
    pids=$(_cch_tree_pids "$root")
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    for i in 1 2 3 4 5 6 7 8; do
        alive=0
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && { alive=1; break; }
        done
        (( alive )) || return 0
        sleep 0.25
    done
    for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
}

# ---- polling predicates (mirrors _harness.sh) ----------------------------
wait_for() {
    local label="$1" max="$2"; shift 2
    [[ "$1" == "--" ]] || { echo "wait_for: missing -- separator" >&2; return 2; }
    shift
    local deadline=$(( $(date +%s) + max )) attempts=0
    while (( $(date +%s) < deadline )); do
        if "$@" >/dev/null 2>&1; then
            printf '  PASS: %s (after %d polls)\n' "$label" "$attempts"
            : "${PASS:=0}"; PASS=$(( PASS + 1 )); return 0
        fi
        attempts=$(( attempts + 1 )); sleep 0.25
    done
    printf '  FAIL: %s — predicate never satisfied within %ds (%d polls)\n' \
        "$label" "$max" "$attempts" >&2
    printf '         last cmd: %s\n' "$*" >&2
    : "${FAIL:=0}"; FAIL=$(( FAIL + 1 )); return 1
}

# Predicate helper: pane state equals expected.
cch_state_is() {
    [[ "$(cch_state "$1")" == "$2" ]]
}
