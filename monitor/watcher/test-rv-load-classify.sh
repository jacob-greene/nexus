#!/usr/bin/env bash
# test-rv-load-classify.sh — the `load` arm's verdict of
# test-integration/test-realmodel-respawn-verify.sh, driven as a UNIT on
# synthetic traces (your-org/nexus-code#1795).
#
# That scenario needs a real Claude Code binary and the mock backend
# (RUN_CC_HARNESS=1), so the default band never runs it. Its new three-way
# verdict — waited / UNMEASURED / fail — is extracted into
# test-integration/_rv_load_classify.sh precisely so it can be measured here.
#
# The traces below use the subject log lines of the #1795 red runs VERBATIM
# (gate-control-2.1.295.log, 2026-10-10) and of the green 2.1.296 re-gate, plus
# the shapes the split must keep RED: the pre-#1674 strict check that gave up
# on INDETERMINATE, and an Enter pressed on an INDETERMINATE box that the fixed
# typed-retry log text would hide.
#
# Run: bash monitor/watcher/test-rv-load-classify.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLASSIFY="$_test_dir/test-integration/_rv_load_classify.sh"
SCENARIO="$_test_dir/test-integration/test-realmodel-respawn-verify.sh"
SUBJECT="$_test_dir/_respawn.sh"

# The population: the unit, the scenario that sources it, and the production
# file whose log wording the unit keys on.
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$CLASSIFY" "$SCENARIO" "$SUBJECT" "$_test_dir/_test_helpers.sh"; }
gp_handle "$@"

[[ -r "$CLASSIFY" ]] || { echo "FAIL: missing $CLASSIFY" >&2; exit 1; }
. "$CLASSIFY"

W=$(mktemp -d) || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$W"; _th_reap_own_tmp' EXIT

INDET_ENTER="LOG post-paste verify: no submit-evidence after 1s (last state='empty'); state='empty' is INDETERMINATE (not 'the box is clear') — pressing ONE Enter, the pre-#1596 behaviour narrowed to no-evidence, unsubmitted; box: ''; retrying Enter once"
HEAD_LINES="LOG spawned new 'orchestrator' window via /x/nexus-respawn-launch-AAAA.sh (mode=resume sid=00000000-0000-0000-0000-000000000001)
PS state=unknown active=1
LOG input-ready probe timed out after 0s (last state='unknown'); attempting paste anyway
PS state=empty active=1
PS state=empty active=1"

verdict() { rv_load_classify "$1" | cut -d' ' -f1; }

# 1. THE #1795 RED SHAPE: the strict check's first reading is the rendered brief.
cat > "$W/red" <<EOF
$HEAD_LINES
$INDET_ENTER
PS state=empty active=1
PS state=user-typing active=1 input=typed
PS state=user-typing active=1 input=typed
LOG post-paste verify: state=user-typing input=typed — the brief is IN the input box, unsubmitted; re-sending Enter (typed-retry 1, budget 120s)
PS state=busy active=1
LOG post-paste verify (after 1 typed-retry): state=busy — turn submitted
EOF
assert_eq "the #1795 red shape (box rendered before the strict check looked) is UNMEASURED" "$(verdict "$W/red")" "unmeasured"

# 2. The INDETERMINATE Enter itself submitted: the strict check never ran.
cat > "$W/first" <<EOF
$HEAD_LINES
$INDET_ENTER
PS state=busy active=1
LOG post-paste verify (after retry): state=busy — turn submitted
EOF
assert_eq "submission on the INDETERMINATE Enter itself is UNMEASURED" "$(verdict "$W/first")" "unmeasured"

# 2b. A LIGHTER LOAD: the first check found the brief already rendered and its
#     Enter submitted — no INDETERMINATE reading reached any check. The LOG
#     lines and readings are the 2.1.296 run with RV_LOAD_MB=200 (2026-10-12).
POS_ENTER="LOG post-paste verify: no submit-evidence after 1s (last state='empty'); the brief is IN the input box (pd_box_is_ours), unsubmitted; box: '=== orchestrator recovery brief (load) ==='; retrying Enter once"
cat > "$W/light" <<EOF
$HEAD_LINES
PS state=user-typing active=0 window=1 name=orchestrator input=typed content_hash=2665622047
$POS_ENTER
PS state=busy active=0 window=1 name=orchestrator input=blank content_hash=2821134606
LOG post-paste verify (after retry): state=busy — turn submitted
EOF
assert_eq "a lighter load (first check saw the rendered brief; its Enter submitted) is UNMEASURED" "$(verdict "$W/light")" "unmeasured"
sed 's/^PS state=user-typing active=0 window=1 name=orchestrator input=typed .*/PS state=empty active=0 window=1 name=orchestrator/' "$W/light" > "$W/light-blind"
assert_eq "POTENCY: a first-check Enter logged as 'the brief is IN the input box' but earned by an INDETERMINATE reading is a FAIL" "$(verdict "$W/light-blind")" "fail"

# 3. THE MEASURED SHAPE: the strict check waited (the 2.1.296 green re-gate).
cat > "$W/waited" <<EOF
$HEAD_LINES
$INDET_ENTER
PS state=empty active=1
LOG post-paste verify: state='empty' is INDETERMINATE (a resumed pane may still be loading) — no Enter on it; waiting for the box to read as the brief (budget 120s)
PS state=user-typing active=1 input=typed
LOG post-paste verify: state=user-typing input=typed — the brief is IN the input box, unsubmitted; re-sending Enter (typed-retry 1, budget 120s)
LOG post-paste verify (after 1 typed-retry): state=busy — turn submitted
EOF
assert_eq "the strict check that WAITED is classified waited" "$(verdict "$W/waited")" "waited"

# 4. POTENCY — the pre-#1674 subject: the strict check read `empty` and gave up.
cat > "$W/prefix" <<EOF
$HEAD_LINES
$INDET_ENTER
PS state=empty active=1
LOG post-paste verify: typed-retry stopped — state='empty' is INDETERMINATE (a resumed pane may still be loading) — no Enter on it
LOG post-paste verify (after retry): still no submit-evidence (last state='empty'); box: ''; reporting UNDELIVERED (rc 4)
EOF
assert_eq "POTENCY: a strict check that gave up on INDETERMINATE is a FAIL, not unmeasured" "$(verdict "$W/prefix")" "fail"

# 5. POTENCY — an Enter pressed on an INDETERMINATE box. The typed-retry log
#    line's text is FIXED (`state=user-typing input=typed`), so only the
#    reading that earned it can tell this from shape 1.
cat > "$W/blind" <<EOF
$HEAD_LINES
$INDET_ENTER
PS state=empty active=1
LOG post-paste verify: state=user-typing input=typed — the brief is IN the input box, unsubmitted; re-sending Enter (typed-retry 1, budget 120s)
LOG post-paste verify (after 1 typed-retry): state=busy — turn submitted
EOF
assert_eq "POTENCY: typed-retry 1 earned by an INDETERMINATE reading is a FAIL" "$(verdict "$W/blind")" "fail"

# 5b/5c. ONE GUARD EACH: a reading that fails only the STATE guard, and one
#    that fails only the INPUT guard (an autosuggest ghost). Synthetic on
#    purpose — each exists so that dropping one guard reddens this suite.
sed 's/^PS state=empty active=1$/PS state=unknown active=1 input=typed/' "$W/blind" > "$W/blind-state"
sed 's/^PS state=empty active=1$/PS state=user-typing active=1 input=ghost/' "$W/blind" > "$W/blind-input"
assert_eq "POTENCY: typed-retry 1 earned by a non-user-typing reading (input=typed) is a FAIL" "$(verdict "$W/blind-state")" "fail"
assert_eq "POTENCY: typed-retry 1 earned by user-typing with a GHOST input is a FAIL" "$(verdict "$W/blind-input")" "fail"

# 6. DEFAULT-DENY: shapes the split does not model are FAILs.
printf '%s\n' "$HEAD_LINES" "LOG post-paste verify: state=busy — turn submitted" > "$W/noindet"
assert_eq "no INDETERMINATE Enter and no waiting line (unrecognised) is a FAIL" "$(verdict "$W/noindet")" "fail"
printf '%s\n' "$HEAD_LINES" "$INDET_ENTER" > "$W/trunc"
assert_eq "an INDETERMINATE Enter with no verdict after it is a FAIL" "$(verdict "$W/trunc")" "fail"
printf '%s\n' "$HEAD_LINES" "$INDET_ENTER" "LOG post-paste verify: Enter retry failed (tmux send-keys rc!=0)" > "$W/other"
assert_eq "an unrecognised verdict after the INDETERMINATE Enter is a FAIL" "$(verdict "$W/other")" "fail"
: > "$W/empty"
assert_eq "an EMPTY trace is a FAIL, never unmeasured" "$(verdict "$W/empty")" "fail"
assert_eq "an UNREADABLE trace is a FAIL" "$(verdict "$W/does-not-exist")" "fail"

# 7. COUPLING: the unit keys on the subject's own log wording. A reword in
#    _respawn.sh would turn every run into the default-deny FAIL (loud), but
#    name it here first. `-F`: the strings carry `(`, `'` and `#`.
for _s in "waiting for the box to read as the brief" \
          "is INDETERMINATE (not 'the box is clear')" \
          "pressing ONE Enter" \
          "the brief is IN the input box (pd_box_is_ours)" \
          "retrying Enter once" \
          "the brief is IN the input box, unsubmitted; re-sending Enter (typed-retry " \
          "(after retry): state="; do
    if command grep -qF -- "$_s" "$SUBJECT"; then
        printf '  PASS: _respawn.sh still logs: %s\n' "$_s"; _th_pass
    else
        printf '  FAIL: _respawn.sh no longer logs: %s — rv_load_classify keys on it\n' "$_s" >&2; _th_fail
    fi
done

# 8. WIRING: the scenario sources the unit and routes UNMEASURED to exit 69.
_scn_code=$(command grep -vE '^[[:space:]]*#' "$SCENARIO")
assert_eq "the scenario sources _rv_load_classify.sh, classifies, and exits 69 on UNMEASURED" \
    "$(command grep -cF -e '_rv_load_classify.sh"' -e 'RV_LOAD_VERDICT=$(rv_load_classify' -e 'exit 69' <<<"$_scn_code")" "3"

EXPECTED=22
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
