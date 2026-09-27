#!/usr/bin/env bash
# test-claude-md-fallback-collapse.sh — execute CLAUDE.md's FALLBACK-COLLAPSE
# block (your-org/nexus-code#1496).
#
# WHY THIS SUITE EXISTS. `CLAUDE.md`'s authority rests on its blocks being
# EXECUTED rather than asserted. This one pins the entry "a `||` fallback is a
# claim that every failure the callee can report means the same thing", whose
# dangerous member is a DISABLED CHECK rather than a wrong count.
#
# WHAT IS ACTUALLY PINNED — the four forms, each by its documented output:
#
#   1 COLLAPSE      `v=$(f) || v=NONE` prints v=NONE for rc 2 — and, derived
#                   here rather than trusted from the comment, for rc 1 too.
#   2 DISCRIMINATOR `if v=$(f); then rc=0; else rc=$?; fi` keeps rc=2, and
#                   the same form fed rc 1 reports rc=1: the two worlds the
#                   collapse merged are separable again.
#   3 DISABLED      `w=$(false || true)` then `[[ -n "$w" && 9 != "$w" ]]`
#                   prints `verified` — a comparison that cannot fail.
#   4 SHAPE         validating the value's SHAPE refuses the empty value:
#                   `unresolvable`, rc 3.
#
# CONTROLS, because "the commands ran" proves nothing:
#   A — the extracted form count is PINNED at 4. A botched extraction yielding
#       zero forms would satisfy every assertion below by having none to make.
#   B — POSITIVE CONTROL for form 3: the SAME comparison with its source
#       rewritten from `false || true` to a callee that yields `8` must print
#       MISMATCH. Without it, `verified` could be a comparison that never
#       fires for any input, and the "disabled by the collapse" reading would
#       be unearned.
#   C — form 4's shape test ACCEPTS a real version (no output, rc 0), so its
#       rc 3 on the empty value is a refusal of the shape, not of everything.
#
# AND THE PROSE'S TWO CODE CLAIMS, witnessed rather than trusted:
#   * `monitor/_cc-version.sh:cc_version_read_local_pin` returns 1 for an
#     ABSENT pin file AND for an EMPTY or WHITESPACE one — driven against a
#     fixture pin path, so the "no rc can separate them" claim is measured.
#   * the rollback's `now_pin` block in `monitor/cc-auto-update-apply.sh`
#     checks the world with `[[ -e "$pin_path" ]]` and uses `<unreadable>` —
#     STRUCTURAL (the text of the block), because driving the rollback needs
#     an install. Stated as structural so it is not read as behavioural.
#
# NOT COVERED, declared rather than implied: the entry's "11 of 13 sites were
# harmless" and "five of these in one diff" are historical counts from the
# PR `#1493` sweep; no in-repo fixture can re-derive them.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
CCV="$REPO_ROOT/monitor/_cc-version.sh"
APPLY="$REPO_ROOT/monitor/cc-auto-update-apply.sh"

# ── this suite DECLARES its own population (the --population protocol) ──────
# Declared at birth (your-org/nexus-code#1219's rule for CLAUDE.md block
# suites): CLAUDE.md is the document this suite EXECUTES, _cc-version.sh is
# sourced and driven, and cc-auto-update-apply.sh is READ for its now_pin
# block — an edit to any of them can change the verdict. `gp_handle` adds this
# suite's own path and `monitor/_guard_population.sh`; it EXITS on
# --population, so it sits above the first line of output.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/_cc-version.sh \
        monitor/cc-auto-update-apply.sh \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage FALLBACK-COLLAPSE   # the entry's UNCHECKED share, in this suite's own output (#1239)

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
BEGIN_MARK='<!-- BEGIN FALLBACK-COLLAPSE -->'
END_MARK='<!-- END FALLBACK-COLLAPSE -->'

[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^bash ')

# CONTROL A — pin the count. Counted with grep -c over a variable (no mapfile:
# this suite may be started from zsh, where mapfile is an rc-127 empty array).
FORM_COUNT=$(grep -c '^bash ' <<<"$FORMS")
assert_eq "extracted exactly 4 documented forms" "$FORM_COUNT" "4"
if [[ "$FORM_COUNT" != "4" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

FORM_COLLAPSE=$(sed -n '1p' <<<"$FORMS")
FORM_KEEP=$(sed -n '2p' <<<"$FORMS")
FORM_DISABLED=$(sed -n '3p' <<<"$FORMS")
FORM_SHAPE=$(sed -n '4p' <<<"$FORMS")

assert_contains "form 1 is the || collapse"            "$FORM_COLLAPSE" '|| v=NONE'
assert_contains "form 2 keeps the rc in an else arm"   "$FORM_KEEP"     'else rc=$?'
assert_contains "form 3 is the || true that disables"  "$FORM_DISABLED" 'false || true'
assert_contains "form 4 validates the SHAPE"           "$FORM_SHAPE"    '=~'

WORK=$(mktemp -d -t nexus-fallback-XXXXXX) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || th_abort "cannot cd into the fixture dir"

echo
echo '=== Form 1: the fallback COLLAPSES the callee vocabulary ==='
out1=$(eval "$FORM_COLLAPSE" 2>/dev/null); rc1=$?
assert_eq "form 1 prints v=NONE for a callee returning 2" "$out1" "v=NONE"
assert_eq "…and EXITS 0: nothing at the call site shows the collapse" "$rc1" "0"
# The comment's own claim, derived rather than trusted: the same line fed a
# callee returning 1 is byte-identical.
FORM_COLLAPSE_RC1=${FORM_COLLAPSE/return 2/return 1}
assert_not_contains "the rc-1 variant really changed the callee" "$FORM_COLLAPSE_RC1" 'return 2'
out1b=$(eval "$FORM_COLLAPSE_RC1" 2>/dev/null)
assert_eq "…and rc 1 gives the SAME v=NONE — two worlds, one value" "$out1b" "$out1"

echo
echo '=== Form 2: keeping the rc keeps the discriminator ==='
out2=$(eval "$FORM_KEEP" 2>/dev/null)
assert_eq "form 2 prints rc=2" "$out2" "rc=2"
FORM_KEEP_RC1=${FORM_KEEP/return 2/return 1}
out2b=$(eval "$FORM_KEEP_RC1" 2>/dev/null)
assert_eq "…and the rc-1 variant prints rc=1: the worlds are separable again" "$out2b" "rc=1"

echo
echo '=== Form 3: the sentinel DISABLES the check ==='
out3=$(eval "$FORM_DISABLED" 2>/dev/null); rc3=$?
assert_eq "form 3 prints verified — for an expectation it never had" "$out3" "verified"
assert_eq "…and exits 0" "$rc3" "0"
# CONTROL B — the comparison is LIVE when the source yields a value.
FORM_LIVE=${FORM_DISABLED/false || true/echo 8}
assert_not_contains "the control really replaced the fallback source" "$FORM_LIVE" 'false || true'
out3b=$(eval "$FORM_LIVE" 2>/dev/null)
assert_eq "CONTROL B: the same comparison fed 8 prints MISMATCH (the check is live)" "$out3b" "MISMATCH"

echo
echo '=== Form 4: validating the SHAPE refuses the empty value ==='
out4=$(eval "$FORM_SHAPE" 2>/dev/null); rc4=$?
assert_eq "form 4 prints unresolvable" "$out4" "unresolvable"
assert_eq "…with rc 3" "$rc4" "3"
FORM_SHAPE_OK=${FORM_SHAPE/w=\"\"/w=2.1.263}
assert_not_contains "the control really supplied a version" "$FORM_SHAPE_OK" 'w=""'
out4b=$(eval "$FORM_SHAPE_OK" 2>/dev/null); rc4b=$?
assert_eq "CONTROL C: a real version passes the shape test silently" "$out4b|$rc4b" "|0"

echo
echo '=== The prose: cc_version_read_local_pin collapses ABSENT and EMPTY ==='
[[ -r "$CCV" ]] || th_abort "missing $CCV"
_pin_probe() {   # <state: absent|empty|space|version> -> "<rc>|<stdout>"
    local pin="$WORK/pin-$1" o r
    rm -f "$pin"
    case "$1" in
        empty)   : > "$pin" ;;
        space)   printf '  \n\t\n' > "$pin" ;;
        version) printf '2.1.263\n' > "$pin" ;;
    esac
    o=$(NEXUS_CC_LOCAL_PIN="$pin" bash -c '. "$1"; cc_version_read_local_pin "$2"' _ "$CCV" "$WORK" 2>/dev/null)
    r=$?
    printf '%s|%s' "$r" "$o"
}
assert_eq "an ABSENT pin file returns 1"              "$(_pin_probe absent)"  "1|"
assert_eq "an EMPTY pin file (a torn write) returns 1" "$(_pin_probe empty)"   "1|"
assert_eq "a WHITESPACE-only pin file returns 1"      "$(_pin_probe space)"   "1|"
# Positive control: the reader is not simply broken.
assert_eq "a real pin returns 0 and the version"      "$(_pin_probe version)" "0|2.1.263"

echo
echo '=== The prose: the rollback fix checks the WORLD (structural) ==='
[[ -r "$APPLY" ]] || th_abort "missing $APPLY"
NOWPIN=$(awk '/local now_pin pin_path/ { inb = 1 } inb { print } inb && /now_pin" == "\$prior"/ { exit }' "$APPLY")
assert_contains "the now_pin block reads the pin through cc_version_read_local_pin" "$NOWPIN" 'cc_version_read_local_pin'
assert_contains "…checks EXISTENCE when the reader fails"       "$NOWPIN" '[[ -e "$pin_path" ]]'
assert_contains "…and uses the distinct third value"            "$NOWPIN" 'now_pin="<unreadable>"'

# ---- assertion-count guard (your-org/nexus-code#946 F6) -------------------
# A missing assert_* helper (a typo → rc 127) is counted by NOTHING: the suite
# would still print ALL TESTS PASSED with a quietly smaller total. No
# conditional arms, so the expectation is a constant.
EXPECTED_ASSERTIONS=27
TOTAL_ASSERTIONS=$(( PASS + FAIL ))
assert_eq "assertion TOTAL matches the EXPECTED total — no assertion silently dropped or added" \
          "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
