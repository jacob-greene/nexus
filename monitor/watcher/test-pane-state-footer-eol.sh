#!/usr/bin/env bash
# Unit tests for pane-state.sh `_footer_handle_counts`: a handle count whose
# right-hand boundary is the END OF THE ROW (your-org/nexus-code#1866).
#
# Run: bash monitor/watcher/test-pane-state-footer-eol.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. Up to Claude Code 2.1.301 the `← for agents` hint always followed
# the footer's tasks pill, so every count had a ` · ` after it, and the parser
# required one. 2.1.302 hides the hint 10 s after a session opens; under vim
# INSERT or a configured `statusLine` nothing else follows the pill, so the
# footer ends at the count and the parser read 0. The footer is a Monitor
# handle's ONLY channel (#1374), so a worker parked on a `Monitor` read `idle`,
# which is on the kill allowlist.
#
# THE TABLE is literal footer lines, inside a realistic capture (transcript,
# input-box rule, prompt, rule, footer) unless the case is about the shape of
# the capture itself. It keeps the potency control #1866's probe used
# (`· 1 shell, 2 monitors` with and without the hint). The MUST-FIX rows are
# the ones the base parser (414bd080) gets wrong; every other row is the same
# on both, and the NEGATIVE rows are what an end-of-row match must NOT take:
# a transcript line ending in a count. Potency: PANE_STATE_SH=<another tree's
# pane-state.sh> runs this table against that parser instead.
#
# The functions are read OUT of pane-state.sh (sourcing it would run its main
# body), the same way the #1866 probe and the realmodel scenario read them.

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0

# The parser this table pins, so `ng guards-for-diff` selects it on any edit
# to pane-state.sh (the population is the default tree, not an override), and
# the two captures L15/L16 read (#1870).
_PS_DEFAULT="$_test_dir/../pane-state.sh"
_FX_READ=(working-background-bare-chevron-657.ansi working-background-monitor-shifttab-derived-657.ansi
          working-background-narrow45-realmodel-302.ansi working-background-narrow35-realmodel-302.ansi
          idle-narrow30-realmodel-302.ansi idle-effort-session-realmodel-302.ansi)
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$_PS_DEFAULT"; printf "$_test_dir/fixtures/%s\n" "${_FX_READ[@]}"; }
gp_handle "$@"

PANE_STATE_SH="${PANE_STATE_SH:-$_PS_DEFAULT}"
[[ -r "$PANE_STATE_SH" ]] || th_abort "cannot read $PANE_STATE_SH"
_fn=$(mktemp "${TMPDIR:-/tmp}/footeol.XXXXXX") || th_abort "mktemp failed"
trap 'rm -f "$_fn"' EXIT
grep '^_FOOTER_RULE=' "$PANE_STATE_SH" > "$_fn"
for _f in _strip_ansi _bottom_rows _footer_rows _footer_handle_counts; do
    awk -v f="$_f" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}/ {p=0}' "$PANE_STATE_SH" >> "$_fn"
done
. "$_fn"
declare -F _footer_handle_counts >/dev/null || th_abort "no _footer_handle_counts in $PANE_STATE_SH"

RULE='────────────────────────────────────────'
MODE='  -- INSERT -- ⏵⏵ bypass permissions on'
# A realistic capture: transcript above the box, the box, then the footer row(s).
cap() {   # <transcript-row> <footer-row> [<second footer row>]
    printf '%s\n%s\n❯ \n%s\n%s\n' "$1" "$RULE" "$RULE" "$2"
    [[ -z "${3:-}" ]] || printf '%s\n' "$3"
}
row() {   # <label> <want "mon bg"> <capture>
    assert_eq "$1" "$(_footer_handle_counts "$3")" "$2"
}

echo '=== the 2.1.301 layout (hint present) is unchanged ==='
row "L1 '· 1 shell, 2 monitors · ← for agents' (the #1866 probe's control)" "2 1" \
    "$(cap '● done' "$MODE · 1 shell, 2 monitors · ← for agents")"
row "L5 '· 1 monitor · ← for agents'" "1 0" \
    "$(cap '● done' "$MODE · 1 monitor · ← for agents")"
row "L6 '· 2 shells · ↓ to manage' (non-vim, no statusLine: a later item exists)" "0 2" \
    "$(cap '● done' "  ⏵⏵ bypass permissions on · 2 shells · ↓ to manage")"

echo '=== MUST-FIX: the 2.1.302 layout (the pill ends the row) ==='
row "L2 '· 1 shell, 2 monitors' at end of row (the probe's control, hint gone)" "2 1" \
    "$(cap '● done' "$MODE · 1 shell, 2 monitors")"
row "L3 '· 2 monitors' at end of row — the Monitor-only wait #1866 is about" "2 0" \
    "$(cap '● done' "$MODE · 2 monitors")"
row "L4 '· 1 shell' at end of row (the measured 2.1.302 footer)" "0 1" \
    "$(cap '● done' "$MODE · 1 shell")"
row "L7 trailing padding after the count is still end of row" "1 0" \
    "$(cap '● done' "$MODE · 1 monitor          ")"
row "L8 a shell after another pill item ('· 1 subagent, 1 shell')" "0 1" \
    "$(cap '● done' "$MODE · 1 subagent, 1 shell")"
row "L9 no input-box rule in the capture: the bottom row is the footer" "1 0" \
    "$(printf '● done\n%s\n' "$MODE · 1 monitor")"
row "L13 a statusLine row BELOW the footer row" "1 0" \
    "$(cap '● done' "$MODE · 1 monitor" '  [proj-x] main ✓')"

echo '=== NEGATIVE: an end-of-row count in the TRANSCRIPT is not a handle ==='
row "L10 transcript row ending '· 2 monitors' above the box, footer with no pill" "0 0" \
    "$(cap '● Two waits armed · 2 monitors' "$MODE")"
row "L11 no rule: a transcript row ending ', 2 monitors' above a pill-less bottom row" "0 0" \
    "$(printf '● armed the queue, 2 monitors\n%s\n' "$MODE")"
row "L12a '· 2 monitorsx' is not a count" "0 0" \
    "$(cap '● done' "$MODE · 2 monitorsx")"
row "L12b '· 1 shell command' is not a count" "0 0" \
    "$(cap '● done' "$MODE · 1 shell command")"
row "L14 pass 1 still wins: a 2.1.301 footer beside an end-of-row transcript count" "0 1" \
    "$(cap '● note · 3 shells' "$MODE · 1 shell · ← for agents")"

echo '=== #1870 item 1 MUST-FIX: a `(` or a column gap after the count ==='
# A real v2.1.220 capture puts `(shift+tab to cycle)` right after the pill, so
# the count is followed by `(`, not by `·`, `,` or end of row. The base parser
# took the shell there and MISSED the monitor. The capture is read through the
# production `_strip_ansi`, so the real bytes are what is parsed.
_fx="$_test_dir/fixtures"
fx() { _strip_ansi < "$_fx/$1"; }
for _x in "${_FX_READ[@]}"; do [[ -r "$_fx/$_x" ]] || th_abort "fixture missing: $_x"; done
row "L15 the real v2.1.220 capture: '· 1 shell, 1 monitor (shift+tab to cycle) · ← for agents'" "1 1" \
    "$(fx working-background-bare-chevron-657.ansi)"
row "L16 the same capture, Monitor-only (derived): '· 1 monitor (shift+tab to cycle) · …' — base reads 0 0, idle" "1 0" \
    "$(fx working-background-monitor-shifttab-derived-657.ansi)"
row "L17 '· 1 shell, 1 monitor (shift+tab to cycle)' at end of row (skeptic S1)" "1 1" \
    "$(cap '● done' "$MODE · 1 shell, 1 monitor (shift+tab to cycle)")"
row "L18 '· 1 monitor (shift+tab to cycle)' at end of row (skeptic S1b, the kill direction)" "1 0" \
    "$(cap '● done' "$MODE · 1 monitor (shift+tab to cycle)")"
row "L19 '· 2 shells (shift+tab to cycle)'" "0 2" \
    "$(cap '● done' "$MODE · 2 shells (shift+tab to cycle)")"
row "L20 a column gap, then the right-aligned area: '· 1 monitor      12% until auto-compact' (skeptic S3)" "1 0" \
    "$(cap '● done' "$MODE · 1 monitor                    12% until auto-compact")"
row "L21 a column gap after a shell count" "0 1" \
    "$(cap '● done' "$MODE · 1 shell      12% until auto-compact")"

echo '=== #1870 item 1 NEGATIVE: the wider boundary stays on footer rows, and one space is not a gap ==='
row "L22 a transcript row '· 1 monitor (see above)' above the box is not a handle" "0 0" \
    "$(cap '● armed · 1 monitor (see above)' "$MODE")"
row "L23 '· 1 monitor is armed' (one space, then text) is not a count" "0 0" \
    "$(cap '● done' "$MODE · 1 monitor is armed")"
row "L24 a transcript row with a column gap above the box is not a handle" "0 0" \
    "$(cap '● waits · 2 monitors        armed' "$MODE")"

echo '=== #1870 item 4: what pass 1 decides that pass 2 cannot ==='
# Pass 2 subsumes pass 1 on every FOOTER row, so L1, L5 and L6 pin the 2.1.301
# OUTPUT, not pass 1 (the bundle 34 skeptic: deleting either pass-1 arm
# survives them). Measured over the 113-capture fixture corpus at 2a5c2146:
# deleting either pass-1 bounded arm changes 0 of 113 readings. What pass 1
# alone contributes is scope: it reads all 15 bottom rows, and pass 2 reads
# only the footer rows. These rows put a bounded count on a row that is NOT a
# footer row (no rule, and a statusLine row below), so only pass 1 can take
# it. The layout is synthetic; it is here so a deleted pass-1 arm goes red.
row "P1a pass-1 monitor arm: no rule, the bounded pill is NOT the bottom row" "2 1" \
    "$(printf '● done\n%s\n%s\n' "$MODE · 1 shell, 2 monitors · ← for agents" '  [proj-x] main ✓')"
row "P1b pass-1 shell arm: no rule, '· 2 shells ·' is NOT the bottom row" "0 2" \
    "$(printf '● done\n%s\n%s\n' "$MODE · 2 shells · ← for agents" '  [proj-x] main ✓')"

echo '=== the bundle 34 skeptic table: the shapes it reads correctly ==='
# The ncbundle34 skeptic's 16 footer shapes (S1..S15, S1b), every one in this
# file: S1/S1b/S3 are L17/L18/L20 above, S4/S10/S15 are K1-K3 below.
SL='  ◯ Opus 5 │ v2.1.302 │ ███▊░ 440K/1.0M │ $22.95'
row "S2 a statusLine row ABOVE the footer row, the pill at end of row" "2 1" \
    "$(cap '● done' "$SL" "$MODE · 1 shell, 2 monitors")"
row "S5 another item before the pill: '· PR #512 · 1 monitor'" "1 0" \
    "$(cap '● done' "$MODE · PR #512 · 1 monitor")"
row "S6 a trailing BLANK row after the footer" "1 1" \
    "$(cap '● done' "$MODE · 1 shell, 1 monitor" "")"
row "S7 a transcript ', 3 monitors' and a footer row '· 2 build'" "0 0" \
    "$(cap '● note, 3 monitors' "$MODE" '  · 2 build')"
row "S8 a transcript 'still running' phrase that is not the spinner, beside a real pill" "1 0" \
    "$(cap '● 1 shell still running, then 2 monitors' "$MODE · 1 monitor")"
row "S9 the monitor count LAST: '· 2 shells, 1 monitor'" "1 2" \
    "$(cap '● done' "$MODE · 2 shells, 1 monitor")"
row "S11 no rule, the pill row then a trailing blank row" "1 1" \
    "$(printf '%s\n' '● x' "$MODE · 1 shell, 1 monitor" '')"
row "S12 one trailing space after the count" "1 0" \
    "$(cap '● done' "$MODE · 1 monitor ")"
row "S13 '· 3 monitors · ↓ to manage'" "3 0" \
    "$(cap '● done' "$MODE · 3 monitors · ↓ to manage")"
row "S14 a transcript ', 4 monitors' above a real end-of-row pill" "1 1" \
    "$(cap '● the build, 4 monitors' "$MODE · 1 shell, 1 monitor")"

echo '=== the bundle 34 skeptic table: residuals, pinned at their CURRENT reading ==='
# Each is a reading this parser gets wrong, kept visible rather than argued.
# K1 errs toward a kill.
#
# K1 is a layout the renderer does not draw. MEASURED (#1873 N5), not assumed:
# the real 2.1.302 binary (sha256 60d7eb7f…), booted through cc-harness with
# two background shells, captured at pane widths 117, 80, 60, 45, 35, 30, 25
# and 20. At every width the footer was ONE row and the pane's last row; the
# renderer drops whole words to fit and never continues onto a second row.
#
# What that truncation does instead was K4 here, and is FIXED (#1876): see
# the narrow-pane section below.
row "K1 KNOWN MISS (contrived): a footer wrapped across two rows, '· 1 shell,' / '2 monitors' (S4)" "0 1" \
    "$(cap '● done' "$MODE · 1 shell," "2 monitors")"
row "K2 KNOWN FALSE COUNT (safe direction): a row below the rule ending '· 2 monitors' (S10)" "2 0" \
    "$(cap '● done' "$MODE" '  /tasks   List background tasks · 2 monitors')"
row "K3 KNOWN FALSE COUNT (safe direction): pass 1 takes a transcript '· 7 shells,' over the footer (S15)" "1 7" \
    "$(cap '● the build · 7 shells,' "$MODE · 1 shell, 1 monitor")"

echo '=== MUST-FIX: a narrow pane drops the pill noun (#1876) ==='
# The renderer fits the footer to one row by dropping words from the end: at
# 45 columns `· 2`, at 35 `bypass      · 2`, below ~30 no pill at all, only the
# spinner row wrapped as `  · 2 shells still running`. The base parser
# (99e40fa5) reads `0 0` on all of them. A bare count is read as a MONITOR,
# the kind that holds the pane. The F rows read the REAL captures. The 30-
# column one stays `0 0` (K5 below): see the comment above _FOOTER_RULE.
_fx() { cat "$_test_dir/fixtures/$1-narrow$2-realmodel-302.ansi"; }
row "N1 '· 2' bare at end of the footer row (the 45-column truncation)" "2 0" \
    "$(cap '● done' "$MODE · 2")"
row "N2 '· 1 shell, 2': the monitor noun dropped after a shell" "2 1" \
    "$(cap '● done' "$MODE · 1 shell, 2")"
row "F45 the real 45-column capture" "2 0" "$(_fx working-background 45)"
row "F35 the real 35-column capture: column gap, then the bare count" "2 0" "$(_fx working-background 35)"

echo '=== negative: a bare count the narrow-pane arms must NOT take ==='
row "B1 a TRANSCRIPT row ending '· 2' above the box (footer rows only)" "0 0" \
    "$(cap '● the answer · 2' "$MODE")"
row "B2 a footer row with '· 2' mid-row, followed by a word" "0 0" \
    "$(cap '● done' "$MODE · 2 build")"
row "B3 a footer row ending '#512' (a PR item, not a bare count)" "0 0" \
    "$(cap '● done' "$MODE · PR #512")"
row "B4 the real /effort session: the '● high · /effort' badge row is not a count (#1844)" "0 0" \
    "$(cat "$_test_dir/fixtures/idle-effort-session-realmodel-302.ansi")"

echo '=== residual: below ~30 columns the pill is gone (#1876) ==='
row "K5 KNOWN MISS (shells, unreliable path only): the real 30-column capture, '· 2 shells still running' above the box" "0 0" \
    "$(_fx idle 30)"

EXPECTED_ASSERTIONS=49
assert_eq "assertion count is exactly what this suite declares" "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS"
th_summary_and_exit
