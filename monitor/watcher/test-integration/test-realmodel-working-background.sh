#!/usr/bin/env bash
# test-realmodel-working-background.sh — a pane parked on a background handle
# must classify `working-background`, read the way production reads it, through
# the REAL binary's footer (your-org/nexus-code#1866).
#
# WHY THIS EXISTS
#
# `working-background` is the classification that keeps a worker waiting on a
# background shell or a `Monitor` OFF the kill allowlist, and until this file
# the cc-harness gate did not cover it (gate-coverage listed it UNCOVERED). That
# gap let 2.1.302 pass the gate GREEN while breaking it: 2.1.302 hides the
# `← for agents` footer hint 10 s after a session opens, the footer then ENDS at
# the last handle count (`· 1 shell`, `· 2 monitors`), and
# `_footer_handle_counts` required a separator AFTER the count. Under vim
# INSERT or a configured `statusLine` (production has both) nothing follows the
# count, so it read 0.
#
# WHAT IS MEASURED, AND THE BOUNDARY
#
# The mock issues one `Bash run_in_background` call, so the real binary draws a
# real `1 shell` pill. The scenario waits past the hint window, then asserts:
#
#   A. the live verdict is `working-background` (this one is RESCUED by the
#      process tree for a shell, which is why it is not the whole test);
#   B. the FOOTER channel alone reads the count — `_footer_handle_counts`, read
#      out of production pane-state.sh, returns bg=1 on the real capture, and
#      pane-state on the saved capture (`--fixture`: no process tree, footer
#      only) says `working-background`. The footer is a Monitor's ONLY channel
#      (#1374), so this is the arm that would have caught #1866;
#   C. the same with the hint STRIPPED from the real bytes, so the end-of-row
#      layout is gated whichever release is installed (on 2.1.301 the real
#      footer keeps the hint);
#   D. the MONITOR half, derived: `1 shell` rewritten to `1 monitor` in those
#      real bytes classifies `working-background` with NO `bg_cpu` field (the
#      Monitor arm, never orphan-graced). A real `Monitor` cannot be armed under
#      the mock — the tool is GrowthBook-gated off for a third-party provider
#      (`No such tool available: Monitor`, measured on #1866) — so this is a
#      rendering derived from the measured layout, not an observed Monitor pill.
#      The two kinds share one pill renderer (`local_bash` with kind `monitor`,
#      read from the 2.1.302 bundle on #1866);
#   E. a NEGATIVE: the same capture with the pill removed classifies `idle`, so
#      B-D track the pill and not something else on the screen.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary); self-skips
# otherwise. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

PANE_STATE="$CCH_REPO_ROOT/monitor/pane-state.sh"
echo "=== real-binary harness: working-background through the footer (#1866) ==="
echo "    claude:  $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null))"

# The PRODUCTION parser, read out of pane-state.sh rather than re-typed, so
# this cannot pass on a spelling the classifier would not accept.
_fn=$(mktemp "${TMPDIR:-/tmp}/wbfoot.XXXXXX")
grep '^_FOOTER_RULE=' "$PANE_STATE" > "$_fn"
for _f in _bottom_rows _footer_rows _footer_handle_counts; do
    awk -v f="$_f" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}/ {p=0}' "$PANE_STATE" >> "$_fn"
done
. "$_fn"; rm -f "$_fn"
declare -F _footer_handle_counts >/dev/null || { echo "FAIL: could not read _footer_handle_counts out of $PANE_STATE" >&2; exit 1; }

strip() { sed -E $'s/\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)//g; s/\x1b\\[[0-9;?]*[a-zA-Z]//g'; }

# pane-state on a saved capture: no pane, no process tree, no heartbeat — the
# footer is the only source, exactly as for a Monitor handle.
classify_file() {
    env -u TMUX "$PANE_STATE" --fixture "$1" --window 1 --name wb --active 0 \
        --heartbeat-file "$CCH_DIR/no-heartbeat.json" --now "$(date +%s)" 2>&1
}

# After the one tool call, switch the mock back to plain text so the follow-up
# request ends the turn instead of issuing the tool again.
HOOK="$CCH_DIR/disarm.sh"; SET="$CCH_DIR/wb-settings.json"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %%s %q > %q\nexit 0\n' \
    '{"mode":"text","text":"bg started"}' "$CCH_CONTROL" > "$HOOK"
chmod +x "$HOOK"
jq -n --arg h "$HOOK" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$h}]}]}}' > "$SET"

boot=$(date +%s)
win=$(CCH_SETTINGS="$SET" cch_boot_worker wb)
[[ -n "$win" ]] || { echo "FAIL: worker window never appeared" >&2; exit 1; }
wait_for "worker boots to idle" 40 -- cch_state_is "$win" idle

cch_control "$(jq -nc '{mode:"tool_use", tool:{name:"Bash", input:{command:"sleep 300", run_in_background:true, description:"bg sleep"}}}')"
cch_send "$win" "start a background sleep"
has_shell_pill() { grep -qE '·[[:space:]]+1[[:space:]]+shell' <<<"$(cch_capture "$win")"; }
wait_for "the real footer draws a 1 shell pill" 40 -- has_shell_pill

# Past the 2.1.302 hint window (10 s after the session opened), with margin.
while (( $(date +%s) < boot + 16 )); do sleep 1; done
hint_gone() { ! grep -qF 'for agents' <<<"$(cch_capture "$win")"; }
for _i in $(seq 1 20); do hint_gone && break; sleep 0.5; done
if hint_gone; then layout="hint-absent (end-of-row pill)"; else layout="hint-present"; fi
echo "    layout:  $layout"

# A. live
wait_for "A live verdict is working-background" 20 -- cch_state_is "$win" working-background

# B. footer only, on the real bytes
real="$CCH_DIR/wb-real.ansi"
cch_tmux capture-pane -t "$CCH_SESSION:$win" -e -p -J -S -25 > "$real" 2>/dev/null
footer_row=$(strip < "$real" | grep -E '·[[:space:]]+1[[:space:]]+shell' | tail -1)
echo "    footer:  ${footer_row#"${footer_row%%[![:space:]]*}"}"
assert_eq "B footer parser on the real capture reads bg=1" \
    "$(_footer_handle_counts "$(strip < "$real")")" "0 1"
assert_contains "B pane-state on the real capture, footer only, is working-background" \
    "$(classify_file "$real")" "state=working-background"

# C. the end-of-row layout, whichever release is installed
nohint="$CCH_DIR/wb-nohint.ansi"
sed -E $'s/ ·((\x1b\\[[0-9;]*m)| )*← for agents.*$//' "$real" > "$nohint"
assert_not_contains "C the stripped capture carries no hint" "$(strip < "$nohint")" "for agents"
assert_eq "C footer parser with the hint gone still reads bg=1" \
    "$(_footer_handle_counts "$(strip < "$nohint")")" "0 1"
assert_contains "C pane-state with the hint gone is working-background" \
    "$(classify_file "$nohint")" "state=working-background"

# D. the Monitor half, derived from the same real bytes
mon="$CCH_DIR/wb-monitor.ansi"
# ONLY the footer row is rewritten (the LAST row carrying the pill). The
# spinner row above can read `· 1 shell still running` for a while after the
# call, and rewriting that too would hand the derived capture to the spinner's
# `N monitor still running` arm, which passes on a parser that misses the pill
# (measured: it did, against base pane-state).
on_footer_row() {   # <sed-expr> <in> — apply the expression to the last pill row only
    local n; n=$(strip < "$2" | grep -nE '·[[:space:]]+1[[:space:]]+shell' | tail -1 | cut -d: -f1)
    [[ "$n" =~ ^[0-9]+$ ]] || { cat "$2"; return 0; }
    sed -E "${n}${1}" "$2"
}
on_footer_row 's/1 shell/1 monitor/' "$nohint" > "$mon"
assert_eq "D exactly one row names a monitor: the footer (the spinner row was not rewritten)" \
    "$(strip < "$mon" | grep -c 'monitor')" "1"
assert_eq "D footer parser reads the derived end-of-row monitor pill (mon=1)" \
    "$(_footer_handle_counts "$(strip < "$mon")")" "1 0"
d_out=$(classify_file "$mon")
assert_contains "D a monitor-only end-of-row footer is working-background" "$d_out" "state=working-background"
assert_not_contains "D a monitor-driven verdict carries no bg_cpu (never orphan-graced)" "$d_out" "bg_cpu="

# E. negative: no pill, same screen
nopill="$CCH_DIR/wb-nopill.ansi"
on_footer_row $'s/ ·((\x1b\\[[0-9;]*m)| )*1 shell.*$//' "$nohint" > "$nopill"
# The FOOTER row only: the transcript above says `Ran 1 shell command`, which is
# prose the parser must not count (no `·` before it) and is left in place.
assert_not_contains "E the pill is gone from the footer row" \
    "$(strip < "$nopill" | grep -v '^[[:space:]]*$' | tail -1)" "shell"
assert_contains "E the same capture with no pill is idle" "$(classify_file "$nopill")" "state=idle"

if [[ -n "${CCH_WB_SAVE_DIR:-}" ]]; then
    mkdir -p "$CCH_WB_SAVE_DIR" && cp "$real" "$nohint" "$mon" "$nopill" "$CCH_WB_SAVE_DIR/"
fi

cch_kill_claude "$win"
# The assertion COUNT, compared exactly: a stage that stops running is a red,
# not a shorter green. 2 waits + A 1 + B 2 + C 3 + D 4 + E 2.
EXPECTED_ASSERTIONS=14
assert_eq "assertion count is exactly what this scenario declares" "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS"
th_summary_and_exit
