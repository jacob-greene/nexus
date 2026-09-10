#!/usr/bin/env bash
# Tests for the permission-dialog assertion in
# monitor/cc-harness/_lib.sh: cch_has_permission_dialog and
# cch_assert_permission_dialog (your-org/nexus-code#158, Part B).
#
# Run: bash monitor/test-cch-permission-dialog.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Terms, defined on first use:
#
#   Harness     monitor/cc-harness, the scenario runner that drives the
#               real `claude` binary against an auth-free mock backend.
#   Scenario    one harness test case.
#   Probe       a script that drives an agent pane and reads its state.
#   Frame       one `tmux capture-pane` of a worker window, plain text.
#   Vacuous     a control arm that passes without exercising the
#   control    mechanism it controls for.
#
# WHY THIS SUITE EXISTS. The assertion's job is to FAIL when a probe
# expected a permission dialog and captured a frame without one. An
# assertion that only ever runs against frames that do carry the dialog
# is itself a vacuous control. So the bulk of this suite is negative:
# frames that look dialog-adjacent and must NOT match.
#
# The positive fixtures are VERBATIM captures from the real binary,
# recorded 2026-09-10 against Claude Code 2.1.220 through
# monitor/watcher/test-integration/test-realmodel-permission-dialog.sh.
# The negative fixtures are the frames most likely to produce a false
# pass: an idle REPL, the folder-trust dialog, an AskUserQuestion chip
# bar, prose describing the dialog, and a dialog frame with the chevron
# removed.
#
# Hermetic: no tmux, no claude binary, no mock backend, no tmpdir.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$_test_dir/cc-harness/_lib.sh"
# shellcheck source=cc-harness/_lib.sh
. "$LIB"

PASS=0
FAIL=0
should_match() {
    local label="$1" frame="$2"
    if cch_has_permission_dialog "$frame"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected a match, got none\n' "$label" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
should_not_match() {
    local label="$1" frame="$2"
    if cch_has_permission_dialog "$frame"; then
        printf '  FAIL: %s — matched, but this frame carries no dialog\n' "$label" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

# ---- fixtures ------------------------------------------------------------

# Verbatim capture: the `Write` permission dialog. Question literal
# "Do you want to create <file>?".
read -r -d '' FRAME_WRITE <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.220
▝▜█████▛▘  Opus 5 (1M context) · API Usage Billing
  ▘▘ ▝▝    /tmp/cc-harness-opA6ZL/proj

❯ Please Write the file.

● Write(probe-new.txt)

────────────────────────────────────────────────────────────────────────
 Create file
 probe-new.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  1 hello from the mock
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create probe-new.txt?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No

 Esc to cancel · Tab to amend
EOF

# Verbatim capture: the `Edit` permission dialog. Different question
# literal — "Do you want to make this edit to <file>?" — same shape.
read -r -d '' FRAME_EDIT <<'EOF'
● Update(probe-existing.txt)
  ⎿  User rejected write to probe-new.txt

❯ Please Edit the file.

────────────────────────────────────────────────────────────────────────
 Edit file
 probe-existing.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 1 -original
 1 +edited
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to make this edit to probe-existing.txt?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No

 Esc to cancel · Tab to amend
EOF

# A two-option dialog: the decline row is `2. No`, not `3. No`. The
# assertion must not hard-code the number 3.
FRAME_TWO_OPTION=${FRAME_WRITE/   2. Yes, allow all edits during this session (shift+tab)
   3. No/   2. No}

# Verbatim capture: an idle REPL, the frame a probe gets when it forgot
# to drive a tool at all. THE negative control this whole mechanism
# exists for.
read -r -d '' FRAME_IDLE <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.220
▝▜█████▛▘  Opus 5 (1M context) · API Usage Billing
  ▘▘ ▝▝    /tmp/cc-harness-6Z8Rod/proj

────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
EOF

# The folder-trust dialog. Numbered `1. Yes` / `2. No` rows, a chevron,
# and `Esc to cancel` — everything but `Tab to amend`. It is a DIFFERENT
# overlay with a different recovery path (pane-state's _has_trust_overlay,
# _unstick.sh case T), so a permission-dialog probe that accepted it
# would be asserting on the wrong thing.
read -r -d '' FRAME_TRUST <<'EOF'
 Accessing workspace:
 /tmp/cc-harness-opA6ZL/parent/work/child
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel
EOF

# The AskUserQuestion chip bar. Numbered options and a chevron, no
# permission footer.
read -r -d '' FRAME_ASKUQ <<'EOF'
 Which color should the demo use?
 ❯ 1. Blue
   2. Green
   3. No
   Type something.
   Chat about this
EOF

# Prose describing the dialog — an agent transcript quoting the shape,
# or this very source file scrolling past in a pane. Carries every
# phrase, never a chevron-selected numbered row.
read -r -d '' FRAME_PROSE <<'EOF'
● Read(monitor/cc-harness/_lib.sh)
  ⎿  The permission dialog renders as:
       Do you want to create <file>?
       1. Yes
       2. Yes, allow all edits during this session (shift+tab)
       3. No
       Esc to cancel · Tab to amend
     pane-state classifies it `empty` today.
EOF

# The dialog with the chevron stripped. Stands in for a stale or
# half-drawn frame: the words are there, the selection is not.
FRAME_NO_CHEVRON=${FRAME_WRITE/ ❯ 1. Yes/   1. Yes}

# The nexus-158 skeptic's request 001. The prose fixture satisfies the
# option rows and both footer phrases on its own; only the chevron leg
# rejected it. So appending ANY unrelated live chevron row to the same
# 25-row capture completed the match, with no dialog present. Two shapes,
# both reachable in one frame:
#
#   a) an AskUserQuestion menu drawn under the transcript;
#   b) a bare chevron row whose number is not even `1.`.
#
# The fix is co-location: the option rows and the chevron must sit in the
# eight rows ABOVE the footer, so a menu BELOW a quoted footer cannot
# lend its chevron. These two fixtures are the regression test for it.
read -r -d '' FRAME_PROSE_PLUS_MENU <<EOF
$FRAME_PROSE
 Which color should the demo use?
 ❯ 1. Blue
   2. Green
EOF

read -r -d '' FRAME_PROSE_PLUS_CHEVRON <<EOF
$FRAME_PROSE
 ❯ 2. something unrelated
EOF

# ---- positive: real frames must match ------------------------------------
echo "=== frames that DO carry a permission dialog ==="
should_match "Write dialog (\"Do you want to create …?\")"          "$FRAME_WRITE"
should_match "Edit dialog (\"Do you want to make this edit …?\")"   "$FRAME_EDIT"
should_match "two-option dialog (decline row is \`2. No\`)"          "$FRAME_TWO_OPTION"

# ---- negative controls: the point of the exercise ------------------------
echo
echo "=== frames that DO NOT — the assertion must fail loud on these ==="
should_not_match "idle REPL (the probe drove no tool at all)"        "$FRAME_IDLE"
should_not_match "folder-trust dialog (no \`Tab to amend\` footer)"   "$FRAME_TRUST"
should_not_match "AskUserQuestion chip bar"                          "$FRAME_ASKUQ"
should_not_match "prose describing the dialog (no live chevron)"     "$FRAME_PROSE"
should_not_match "dialog frame with the chevron stripped"            "$FRAME_NO_CHEVRON"
should_not_match "empty frame"                                       ""
should_not_match "prose + an AskUserQuestion menu below it"          "$FRAME_PROSE_PLUS_MENU"
should_not_match "prose + a bare unrelated chevron row below it"     "$FRAME_PROSE_PLUS_CHEVRON"

# Co-location, stated directly: the same real dialog still matches when
# unrelated content sits below it, and stops matching when its option
# rows are pushed far above the footer.
read -r -d '' FRAME_DIALOG_PLUS_NOISE <<EOF
$FRAME_WRITE
 ⎿  some later transcript line
 ❯ 9. an unrelated menu row
EOF
should_match "real dialog still matches with noise below it"         "$FRAME_DIALOG_PLUS_NOISE"

read -r -d '' FRAME_OPTIONS_FAR_ABOVE <<EOF
$FRAME_WRITE
 filler 1
 filler 2
 filler 3
 filler 4
 filler 5
 filler 6
 filler 7
 filler 8
 Esc to cancel · Tab to amend
EOF
should_not_match "options pushed out of the window above the footer"  "$FRAME_OPTIONS_FAR_ABOVE"

# ---- the assertion wrapper is loud --------------------------------------
echo
echo "=== cch_assert_permission_dialog is loud on a frame without one ==="

# Non-zero return. A scenario that ignores this is ignoring an explicit
# failure, not being silently misled.
cch_assert_permission_dialog "$FRAME_IDLE" "a Write permission dialog" >/dev/null 2>&1
rc=$?
if (( rc == 1 )); then
    printf '  PASS: returns 1 on a frame with no dialog\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: returned %d on a frame with no dialog — expected 1\n' "$rc" >&2
    FAIL=$(( FAIL + 1 ))
fi

cch_assert_permission_dialog "$FRAME_WRITE" "a Write permission dialog" >/dev/null 2>&1
rc=$?
if (( rc == 0 )); then
    printf '  PASS: returns 0 on a frame with the dialog\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: returned %d on a real dialog frame — expected 0\n' "$rc" >&2
    FAIL=$(( FAIL + 1 ))
fi

# The diagnostic goes to stderr, names the missing legs, and quotes the
# frame. A CI log that only keeps stderr must still carry the evidence.
DIAG=$(cch_assert_permission_dialog "$FRAME_IDLE" "a Write permission dialog" 2>&1 >/dev/null)
# An idle frame has no `Esc to cancel` anchor at all, so there is no
# window to test the other legs in. The diagnostic says exactly that
# rather than listing four legs it never looked for.
for needle in \
    'NO PERMISSION DIALOG IN FRAME' \
    'expected: a Write permission dialog' \
    'no anchor row, so no window' \
    'bypass permissions on'
do
    if grep -qF -- "$needle" <<<"$DIAG"; then
        printf '  PASS: diagnostic carries %q\n' "$needle"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: diagnostic missing %q\n    in: <<%s>>\n' "$needle" "$DIAG" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# A frame that HAS the anchor but not the option rows gets the per-leg
# report, tested against the region the predicate actually uses.
DIAG2=$(cch_assert_permission_dialog "$FRAME_OPTIONS_FAR_ABOVE" "a Write permission dialog" 2>&1 >/dev/null)
for needle in \
    'an option row `1. Yes`, in the 8 rows above the footer' \
    'a chevron on a numbered option row above the footer'
do
    if grep -qF -- "$needle" <<<"$DIAG2"; then
        printf '  PASS: per-leg diagnostic carries %q\n' "$needle"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: per-leg diagnostic missing %q\n    in: <<%s>>\n' "$needle" "$DIAG2" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# Silence on success: a passing assertion must not spam a scenario log.
QUIET=$(cch_assert_permission_dialog "$FRAME_WRITE" "x" 2>&1)
if [[ -z "$QUIET" ]]; then
    printf '  PASS: silent when the dialog is present\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: printed on success: <<%s>>\n' "$QUIET" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary -------------------------------------------------------------
echo
printf 'cch-permission-dialog: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
