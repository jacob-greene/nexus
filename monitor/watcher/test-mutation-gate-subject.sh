#!/usr/bin/env bash
# `mutation-gate.sh --subject`: mutate the CODE UNDER TEST, not the suite.
# (your-org/nexus-code#1519; provenance half: your-org/nexus-code#1510)
#
# Run: bash monitor/watcher/test-mutation-gate-subject.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS FILE EXISTS. `mutation-gate.sh --suite` mutates and runs THE SAME
# FILE, so it answers "is this assertion reached" and never "would this suite
# catch a defect". `#1518`'s hand-rolled subject sweep found three assertions
# that were green for the wrong reason, all one shape: AN ASSERTION THAT NAMES
# ONE GUARD AND IS DEFENDED BY A DIFFERENT ONE. No suite-mutation round can see
# that shape, because every such assertion IS reached.
#
# THE FIXTURE REPRODUCES THAT SHAPE ON PURPOSE. `lib/hold.sh:escapes` has a
# GRACE guard (age < 300) and a THRESHOLD guard (age < 3600). The fixture suite
# asserts "a fresh hold does not escape" with age 60 — named for the threshold,
# defended by the grace — plus one ISOLATING assertion at age 1000. So:
#
#   mutant                     predicted flip set                 must NOT flip
#   delete THRESHOLD guard     {past grace…, one second under…}   a fresh hold…
#   delete GRACE guard         {} — SURVIVES (nothing isolates it) everything
#   knob `if` -> if-true       {knob off refuses}                 knob on passes
#   knob `if` -> if-false      {knob on passes}                   knob off refuses
#
# Every prediction above is handed to the tool as a `--predict` file written
# BEFORE the run, and the second row is the point: a round in which everything
# dies is as uninformative as one in which nothing does.
#
# WHAT THIS SUITE CANNOT REACH, declared rather than assumed benign
# (skills/nexus.self-fix, "the axis your harness cannot reach"): the tree copy
# is exercised on an EIGHT-FILE fixture repository, so it says nothing about the
# cost or fidelity of copying this repository — that is measured by running the
# tool against a real subject, not here. And every fixture subject is SOURCED
# by its suite; an EXECUTED subject takes the same witness path and is not
# separately driven.

set -uo pipefail
_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_test_dir/../.." && pwd)"
GATE="$REPO_ROOT/monitor/mutation-gate.sh"

# Declared to the `guards-for-diff` index: a FIXED population — the tool, the
# two libraries it sources or calls in subject mode, and this file.
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "monitor/mutation-gate.sh" "monitor/shell-files.sh" \
                  "monitor/repo-root.sh" "monitor/watcher/test-mutation-gate-subject.sh" \
                  "monitor/watcher/mutation-provenance.tsv"
}
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=127   # counted BEFORE the census assertion itself

[[ -x "$GATE" ]] || { echo "missing/non-executable $GATE" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mgsubj-$$-XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── the fixture repository ─────────────────────────────────────────────────
FX="$WORK/fx"
mkdir -p "$FX/lib" "$FX/t" "$WORK/elsewhere" "$WORK/tmp"
cat > "$FX/lib/hold.sh" <<'EOF'
#!/usr/bin/env bash
# fixture subject: a hold that escapes after a threshold, never inside a grace.
# escapes <age>: rc 0 = escaped.  The call to knob_gate below is mentioned here.
escapes() {
    local age="$1"
    (( age < 300 )) && return 1
    (( age < 3600 )) && return 1
    return 0
}
knob_gate() {
    if [[ "$1" == on ]]; then
        return 0
    fi
    return 1
}
chained() {
    true &&
        return 0
}
capped() {
    if [[ "$3" == 1 ]] \
       && (( $1 >= $2 )); then
        return 0
    fi
    return 1
}
EOF
cat > "$FX/t/test-hold.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_d/../lib/hold.sh"
P=0; F=0
ck() { if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; P=$((P+1)); else printf '  FAIL: %s — got %s want %s\n' "$1" "$2" "$3" >&2; F=$((F+1)); fi; }
escapes 60;   ck "a fresh hold does not escape" "$?" 1
escapes 1000; ck "past grace, under the threshold does not escape" "$?" 1
escapes 3599; ck "one second under the threshold does not escape" "$?" 1
escapes 4000; ck "an old hold escapes" "$?" 0
knob_gate on;  ck "knob on passes" "$?" 0
knob_gate off; ck "knob off refuses" "$?" 1
capped 2 5 1; ck "under the cap the arm still defers" "$?" 1
capped 5 5 1; ck "at the cap the veto expires" "$?" 0
capped 9 5 0; ck "a non-overridable arm never expires" "$?" 1
printf '=== summary: %d passed, %d failed ===\n' "$P" "$F"
[ "$F" -eq 0 ]
EOF
# A suite that resolves the subject from SOMEWHERE ELSE — the inert-mutant shape.
cat > "$FX/t/test-elsewhere.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "${FX_ELSEWHERE:?}/hold.sh"
escapes 1000; rc=$?
if [ "$rc" = 1 ]; then printf '  PASS: elsewhere: past grace does not escape\n'; else printf '  FAIL: elsewhere: past grace does not escape — got %s want 1\n' "$rc" >&2; fi
printf '=== summary: %d passed, %d failed ===\n' "$(( rc == 1 ))" "$(( rc != 1 ))"
[ "$rc" = 1 ]
EOF
# A suite that executes the tree's subject on its FIRST run only, and the copy
# elsewhere ever after — so the BASELINE arm leaves a witness and the MUTANT arm
# does not. It isolates the second witness guard, which the suite above cannot:
# there the baseline guard always fires first (the #1519 shape, in this tool).
cat > "$FX/t/test-first-run-only.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -e "${FX_MARK:?}" ]; then . "${FX_ELSEWHERE:?}/hold.sh"; else . "$_d/../lib/hold.sh"; : > "$FX_MARK"; fi
escapes 1000; rc=$?
if [ "$rc" = 1 ]; then printf '  PASS: first-run-only: past grace does not escape\n'; else printf '  FAIL: first-run-only: past grace does not escape — got %s want 1\n' "$rc" >&2; fi
printf '=== summary: %d passed, %d failed ===\n' "$(( rc == 1 ))" "$(( rc != 1 ))"
[ "$rc" = 1 ]
EOF
# A suite whose FAIL text is FREE-FORM — it does not repeat the PASS label —
# and one of whose PASS labels embeds a VALUE. This is how the largest suite in
# this repository (test-cc-auto-update.sh) reports, so a flip set keyed on
# `FAIL: <the same label>` alone would call every one of its kills VANISHED.
cat > "$FX/t/test-freeform.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_d/../lib/hold.sh"
F=0
escapes 1000; rc=$?
if [ "$rc" = 1 ]; then echo "  PASS: FF-O1: past grace the hold still holds"; else echo "  FAIL: FF-O1: the hold escaped early (rc=$rc)" >&2; F=$((F+1)); fi
echo "  PASS: FF-O2: the probe ran and answered (rc=$rc)"
escapes 3599
if [ "$?" = 1 ]; then echo "  PASS: one second under the threshold holds"; else echo "  FAIL: boundary broke" >&2; F=$((F+1)); fi
# Two cases whose ids share a prefix, and whose FAIL lines appear in the order
# that makes a GREEDY pairing cross them: the first FAIL shares MORE characters
# with the OTHER case's label ("FF-Q: an ") than with its own ("FF-Q: a").
escapes 2000
if [ "$?" = 1 ]; then echo "  PASS: FF-Q: a hold under the cap holds"; else echo "  FAIL: FF-Q: an early escape under the cap" >&2; F=$((F+1)); fi
escapes 3000
if [ "$?" = 1 ]; then echo "  PASS: FF-Q: an hour-old hold holds"; else echo "  FAIL: FF-Q: an hour-old hold escaped" >&2; F=$((F+1)); fi
printf '%d passed, %d failed\n' "$(( 5 - F ))" "$F"
[ "$F" -eq 0 ]
EOF
# A suite that REWRITES ITS OWN PREDICTION FILE while it runs — in the BASELINE
# arm too. The prediction the author registered must be what is evaluated and
# recorded, whatever the file says afterwards (skeptic F1 on #1558).
cat > "$FX/t/test-tamper.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_d/../lib/hold.sh"
printf '%s\n' '+a case that does not exist' > "${FX_PREDICT_TAMPER:?}"
escapes 1000; rc=$?
if [ "$rc" = 1 ]; then printf '  PASS: T1: past grace holds\n'; else printf '  FAIL: T1: past grace holds — got %s want 1\n' "$rc" >&2; fi
printf '=== summary: %d passed, %d failed ===\n' "$(( rc == 1 ))" "$(( rc != 1 ))"
[ "$rc" = 1 ]
EOF
# …and one that reaches into the TOOL'S OWN WORKDIR and overwrites the snapshot
# the tool took (skeptic round 2, G1): the tree copies live under that workdir,
# two levels up from the suite. A wrong prediction must not become "confirmed"
# this way; the run must be refused, not scored.
cat > "$FX/t/test-tamper-snap.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_d/../lib/hold.sh"
[ -f "$_d/../../predict.snap" ] && printf '%s\n' '+T1: past grace holds' > "$_d/../../predict.snap"
escapes 1000; rc=$?
if [ "$rc" = 1 ]; then printf '  PASS: T1: past grace holds\n'; else printf '  FAIL: T1: past grace holds — got %s want 1\n' "$rc" >&2; fi
printf '=== summary: %d passed, %d failed ===\n' "$(( rc == 1 ))" "$(( rc != 1 ))"
[ "$rc" = 1 ]
EOF
printf 'not shell at all\n' > "$FX/lib/notes.txt"
cp "$FX/lib/hold.sh" "$WORK/elsewhere/hold.sh"
export FX_ELSEWHERE="$WORK/elsewhere"
(
    cd "$FX" && git init -q . && git add -A . \
    && git -c user.name=fixture -c user.email=fixture@invalid -c core.hooksPath=/dev/null \
           -c commit.gpgsign=false commit -q -m fixture
) >/dev/null 2>&1
th_require_fixture_repo "$FX" "the subject-mutation fixture"

SUBJ="$FX/lib/hold.sh"; SUITE="$FX/t/test-hold.sh"
_line() { grep -n -F -- "$1" "$SUBJ" | cut -d: -f1 | sed -n 1p; }
L_GRACE=$(_line '(( age < 300 )) && return 1')
L_THRESH=$(_line '(( age < 3600 )) && return 1')
L_IF=$(_line 'if [[ "$1" == on ]]; then')
L_COMMENT=$(_line '# escapes <age>')
L_CONT=$(_line 'true &&')
L_CAP1=$(_line 'if [[ "$3" == 1 ]] \')
L_CAP2=$(_line '&& (( $1 >= $2 )); then')
for _v in L_GRACE L_THRESH L_IF L_COMMENT L_CONT L_CAP1 L_CAP2; do
    [[ "${!_v}" =~ ^[0-9]+$ ]] || { echo "fixture line $_v not found" >&2; exit 2; }
done
SUBJ_SHA=$(sha256sum "$SUBJ" | cut -d' ' -f1)

# run <name> <args…> — captures stdout+stderr to $WORK/<name>.log, rc to RC.
RC=0
run() {
    local name="$1"; shift
    # A PRIVATE TMPDIR for the tool: §7 asserts it leaves no workdir behind, and
    # under a bare run `${TMPDIR:-/tmp}` is a directory other agents' gates share.
    TMPDIR="$WORK/tmp" "$GATE" "$@" > "$WORK/$name.log" 2>&1
    RC=$?
}
out() { cat "$WORK/$1.log"; }

# ── §1  KILL: the threshold guard, and the case that must NOT flip ──────────
echo '=== §1 delete the THRESHOLD guard: killed, by the ISOLATING case only ==='
printf '%s\n' '+past grace, under the threshold' '+one second under the threshold' '-a fresh hold does not escape' '-an old hold escapes' > "$WORK/p1"
run s1 --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --predict "$WORK/p1" --record "$WORK/ledger.tsv"
assert_eq       "§1 rc 0 (killed-by-assertion, prediction confirmed)" "$RC" "0"
assert_contains "§1 verdict is killed-by-assertion" "$(out s1)" "VERDICT: killed-by-assertion"
assert_contains "§1 the isolating case is in the flip set" "$(out s1)" "FLIPPED: past grace, under the threshold does not escape"
assert_not_contains "§1 the case NAMED for the threshold but defended by the grace did NOT flip" \
    "$(out s1)" "FLIPPED: a fresh hold does not escape"
assert_contains "§1 the flip set is exactly the two isolating cases" "$(out s1)" "flip set — 2 case(s)"
assert_contains "§1 the prediction is reported confirmed" "$(out s1)" "PREDICTION: confirmed"
assert_contains "§1 the DIFF of the edit is printed, not a hash" "$(out s1)" "> # "
assert_contains "§1 the uncopied gitignored population is stated" "$(out s1)" "gitignored path(s) NOT copied"

# ── §1b  FREE-FORM FAIL TEXT: the flip set is "stopped passing", with evidence ─
echo '=== §1b a suite whose FAIL text does not repeat the PASS label ==='
printf '%s\n' '+FF-O1: past grace' '+one second under the threshold holds' '+FF-Q: a hold under the cap' '+FF-Q: an hour-old hold' '-FF-O2: the probe ran' > "$WORK/p1b"
run s1b --suite "$FX/t/test-freeform.sh" --subject "$SUBJ" --line "$L_THRESH" --predict "$WORK/p1b"
assert_eq       "§1b rc 0: killed, and the prediction holds" "$RC" "0"
assert_contains "§1b a case whose FAIL text differs is FLIPPED, paired by its case-id PREFIX" "$(out s1b)" "[paired by PREFIX with: FAIL: FF-O1: the hold escaped early"
assert_contains "§1b a case no FAIL line resembles is FLIPPED by COUNT, and says so" "$(out s1b)" "[by COUNT only"
assert_contains "§1b a PASS label that merely embeds a changed value is RELABELLED, not flipped" "$(out s1b)" "RELABELLED: FF-O2: the probe ran and answered (rc=1)"
assert_not_contains "§1b …so nothing is reported VANISHED" "$(out s1b)" "VANISHED:"
assert_contains "§1b the bare \`N passed, M failed\` footer is read as a declared total" "$(out s1b)" "declared assertions=5"
# GLOBAL best-first pairing: each FF-Q case is shown beside ITS OWN failure. A
# greedy pairing in FAIL-line order crosses these two (measured on the first
# real run of this tool, on two `#1113` cases of test-cc-auto-update.sh).
assert_contains "§1b shared-prefix cases are NOT cross-paired (1/2)" \
    "$(out s1b | grep -A1 -F 'FLIPPED: FF-Q: an hour-old hold holds' | tail -n 1)" "FAIL: FF-Q: an hour-old hold escaped"
assert_contains "§1b shared-prefix cases are NOT cross-paired (2/2)" \
    "$(out s1b | grep -A1 -F 'FLIPPED: FF-Q: a hold under the cap holds' | tail -n 1)" "FAIL: FF-Q: an early escape under the cap"

# ── §2  SURVIVE, as predicted: nothing isolates the grace guard ─────────────
echo '=== §2 delete the GRACE guard: SURVIVES — the #1519 shape, measured ==='
printf '%s\n' '-a fresh hold does not escape' '-past grace, under the threshold' > "$WORK/p2"
run s2 --suite "$SUITE" --subject "$SUBJ" --line "$L_GRACE" --predict "$WORK/p2" --record "$WORK/ledger.tsv"
assert_eq       "§2 rc 4 (survived, prediction confirmed)" "$RC" "4"
assert_contains "§2 verdict is survived" "$(out s2)" "VERDICT: survived"
assert_contains "§2 the survivor is WITNESSED: the suite provably executed the mutated subject" "$(out s2)" "PROVABLY executed"
assert_contains "§2 …and names the different-guard shape" "$(out s2)" "DIFFERENT guard"
assert_contains "§2 an empty flip set is not reported as a kill" "$(out s2)" "PREDICTION: confirmed"

# ── §3  A REFUTED PREDICTION is its own exit code ───────────────────────────
echo '=== §3 a wrong model of the suite exits 6, verdict intact ==='
printf '%s\n' '+a fresh hold does not escape' > "$WORK/p3"
run s3 --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --predict "$WORK/p3"
assert_eq       "§3 rc 6 (verdict rendered, prediction REFUTED)" "$RC" "6"
assert_contains "§3 the verdict is still printed" "$(out s3)" "VERDICT: killed-by-assertion"
assert_contains "§3 the refuted line is named" "$(out s3)" "REFUTED    +a fresh hold does not escape"
assert_contains "§3 a prediction with no must-NOT-flip line is called out" "$(out s3)" "names no case that must NOT flip"
printf '%s\n' '-past grace, under the threshold' > "$WORK/p3b"
run s3b --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --predict "$WORK/p3b"
assert_eq       "§3 a must-NOT-flip case that flipped is rc 6 too" "$RC" "6"
# EXHAUSTIVE: naming ONE of the two cases that flip is a wrong model of the suite.
printf '%s\n' '+past grace, under the threshold' '-a fresh hold does not escape' > "$WORK/p3e"
run s3e --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --predict "$WORK/p3e"
assert_eq       "§3 a flip the prediction did not name is rc 6" "$RC" "6"
assert_contains "§3 …and the unforeseen member is named" "$(out s3e)" "UNPREDICTED  one second under the threshold does not escape"
printf '%s\n' '+no such case anywhere' > "$WORK/p3c"
run s3c --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --predict "$WORK/p3c"
assert_eq       "§3 a prediction naming NO baseline case is REFUSED (rc 3), not vacuously confirmed" "$RC" "3"
assert_contains "§3 …and says why" "$(out s3c)" "names NO baseline case"
assert_not_contains "§3 …before any mutant ran" "$(out s3c)" "=== mutant ==="
run s3d --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH"
assert_contains "§3 with no --predict the tool says a verdict is rationalisable after the fact" "$(out s3d)" "no --predict was registered"

# ── §3f  THE PREDICTION IS WHAT WAS REGISTERED, not what the file says later ─
echo '=== §3f a suite that rewrites its own --predict file mid-run cannot launder the prediction ==='
printf '%s\n' '+T1: past grace holds' > "$WORK/p3f"
p3f_blob=$(git hash-object "$WORK/p3f")
export FX_PREDICT_TAMPER="$WORK/p3f"
run s3f --suite "$FX/t/test-tamper.sh" --subject "$SUBJ" --line "$L_THRESH" --predict "$WORK/p3f" --record "$WORK/ledger-tamper.tsv"
assert_eq       "§3f rc 0: the REGISTERED prediction (which holds) is what was evaluated" "$RC" "0"
assert_contains "§3f …and the tool says the file changed under it" "$(out s3f)" "CHANGED while the run was in progress"
assert_contains "§3f the snapshot's blob is printed" "$(out s3f)" "snapshot blob $p3f_blob"
assert_eq       "§3f …and recorded in the ledger row, column 13" "$(awk -F'\t' '!/^#/{print $13}' "$WORK/ledger-tamper.tsv" | sort -u)" "$p3f_blob"
assert_eq       "§3f control: the file on disk really was rewritten by the suite" "$(cat "$WORK/p3f")" "+a case that does not exist"
unset FX_PREDICT_TAMPER
# G1: a suite that overwrites the tool's OWN snapshot file (with the prediction
# that would have held) is REFUSED — not confirmed, not recorded. The registered
# prediction is VALID but WRONG (`-` on the case that flips), so the run reaches
# scoring — where the memory-held copy says REFUTED and the altered file says
# confirmed — and the integrity refusal is what decides.
printf '%s\n' '-T1: past grace holds' > "$WORK/p3g"
run s3g --suite "$FX/t/test-tamper-snap.sh" --subject "$SUBJ" --line "$L_THRESH" --predict "$WORK/p3g" --record "$WORK/ledger-snap.tsv"
assert_eq       "§3f G1: a run that rewrote the tool's snapshot is REFUSED (rc 3), never confirmed" "$RC" "3"
assert_contains "§3f G1: …and says the snapshot in the workdir was altered" "$(out s3g)" "SNAPSHOT in this tool's workdir was altered"
assert_no_file  "§3f G1: …and nothing was recorded" "$WORK/ledger-snap.tsv"
# G8: the file is read ONCE. A process substitution can be read only once, so
# a tool that read it twice hashed a second, EMPTY read while the verdict used
# the first (measured: "confirmed" beside the empty blob e69de29b…).
p3h_text=$'+past grace, under the threshold\n+one second under the threshold\n-a fresh hold does not escape\n'
p3h_blob=$(printf '%s' "$p3h_text" | git hash-object --stdin)
run s3h --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --predict <(printf '%s' "$p3h_text") --record "$WORK/ledger-psub.tsv"
assert_eq       "§3f G8: a --predict given as a process substitution is evaluated (rc 0, confirmed)" "$RC" "0"
assert_contains "§3f G8: …confirmed, from the one read" "$(out s3h)" "PREDICTION: confirmed"
assert_eq       "§3f G8: …and the ledger's column 13 is the blob of THAT text, not of an empty second read" \
    "$(awk -F'\t' '!/^#/{print $13}' "$WORK/ledger-psub.tsv" | sort -u)" "$p3h_blob"
run s3i --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --predict /dev/null
assert_eq       "§3f G8: an EMPTY --predict is REFUSED at registration (rc 3)" "$RC" "3"
assert_contains "§3f G8: …and says so" "$(out s3i)" "snapshot is EMPTY"
# (#1564 G12) NON-EMPTY ON DISK, EMPTY AS A PREDICTION. Validation is per LINE,
# so a comments-only file validated with zero iterations — and on the SURVIVING
# mutant (§2's grace guard) the check then found nothing refuted and the ledger
# recorded `survived … confirmed`: a prediction of nothing, scored as correct.
# Driven on the survivor because that is the arm where it scored; on a killed
# mutant the exhaustive-set rule already refutes it.
printf '%s\n' '# I expect this to survive, probably' '' '   # (no +/- lines at all)' > "$WORK/p3j"
run s3j --suite "$SUITE" --subject "$SUBJ" --line "$L_GRACE" --predict "$WORK/p3j" --record "$WORK/ledger-empty.tsv"
assert_eq       "§3f G12: a comments-only --predict is REFUSED (rc 3), not validated vacuously" "$RC" "3"
assert_contains "§3f G12: …and says why" "$(out s3j)" "holds NO prediction lines"
assert_not_contains "§3f G12: …it is never SCORED" "$(out s3j)" "PREDICTION: confirmed"
assert_eq       "§3f G12: …and nothing is recorded as a confirmed survivor" \
    "$( n=0; [[ -f "$WORK/ledger-empty.tsv" ]] && { n=$(grep -c 'confirmed' "$WORK/ledger-empty.tsv") || n=0; }; echo "$n" )" "0"
# MUST-NOT-FLIP: comments BESIDE real lines are still fine — §2's prediction
# with a comment and a blank added is evaluated exactly as §2 was.
printf '%s\n' '# the grace guard is unisolated' '' '-a fresh hold does not escape' '-past grace, under the threshold' > "$WORK/p3k"
run s3k --suite "$SUITE" --subject "$SUBJ" --line "$L_GRACE" --predict "$WORK/p3k"
assert_eq       "§3f G12 control: comments beside real prediction lines are still evaluated (rc 4, as §2)" "$RC" "4"

# ── §4  THE INERT MUTANT is a REFUSAL, never a survivor ─────────────────────
echo '=== §4 a suite that reads the subject from ELSEWHERE: REFUSED, not survived ==='
run s4 --suite "$FX/t/test-elsewhere.sh" --subject "$SUBJ" --line "$L_THRESH"
assert_eq       "§4 rc 3 (REFUSED)" "$RC" "3"
assert_contains "§4 names the cause" "$(out s4)" "NEVER EXECUTED the copy of the subject"
assert_not_contains "§4 no verdict was rendered" "$(out s4)" "VERDICT:"
assert_not_contains "§4 refused BEFORE the mutant was built" "$(out s4)" "=== mutant ==="
# The control: WITHOUT the witness the same run is the false survivor the
# witness exists to prevent — and it must be labelled unusable, rc 5, not 4.
run s4b --suite "$FX/t/test-elsewhere.sh" --subject "$SUBJ" --line "$L_THRESH" --no-load-witness
assert_eq       "§4 --no-load-witness: the inert mutant is survived-UNWITNESSED, rc 5 — never rc 4" "$RC" "5"
assert_contains "§4 …and the verdict says it is not evidence" "$(out s4b)" "VERDICT: survived-unwitnessed"
# …while a REAL kill needs no witness: only the mutation differs between arms.
run s4c --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --no-load-witness
assert_eq       "§4 --no-load-witness: a kill is still a kill (rc 0)" "$RC" "0"

# THE SECOND WITNESS GUARD, isolated: the baseline executes the subject copy,
# the mutant arm does not. A green mutant there is not a survivor either.
export FX_MARK="$WORK/first-run.mark"; rm -f "$FX_MARK"
run s4d --suite "$FX/t/test-first-run-only.sh" --subject "$SUBJ" --line "$L_THRESH"
assert_eq       "§4 the MUTANT arm skipping the subject is REFUSED (rc 3), though the baseline loaded it" "$RC" "3"
assert_contains "§4 …and the refusal names the MUTANT arm" "$(out s4d)" "MUTANT arm never executed the subject copy"
assert_not_contains "§4 …with no survivor verdict" "$(out s4d)" "VERDICT: survived"

# ── §5  THE PREDICATE APPLIES TO THE SUBJECT ────────────────────────────────
echo '=== §5 comment, continuation and `if` lines of the SUBJECT are refused ==='
run s5a --suite "$SUITE" --subject "$SUBJ" --line "$L_COMMENT"
assert_eq       "§5 a COMMENT line is REFUSED (rc 3) — a mutant there changes nothing" "$RC" "3"
assert_contains "§5 …with the reason" "$(out s5a)" "already a comment"
run s5b --suite "$SUITE" --subject "$SUBJ" --line "$L_CONT"
assert_eq       "§5 a line ending in && is REFUSED (rc 3) — the #1032 promotion hazard" "$RC" "3"
assert_contains "§5 …naming the token" "$(out s5b)" "continuation token: &&"
run s5c --suite "$SUITE" --subject "$SUBJ" --line "$L_IF"
assert_eq       "§5 DELETING an \`if\` line is REFUSED (rc 3)" "$RC" "3"
run s5d --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --mode if-true
assert_eq       "§5 --mode if-true on a line that is not an \`if\` is REFUSED (rc 3)" "$RC" "3"
assert_contains "§5 …and says what the if-* modes accept" "$(out s5d)" "single-line"
run s5e --suite "$SUITE" --subject "$FX/lib/notes.txt" --line 1
assert_eq       "§5 a NON-SHELL subject is REFUSED (rc 3): the predicate is a shell predicate" "$RC" "3"
assert_contains "§5 …and says so" "$(out s5e)" "not a SHELL file"
run s5f --suite "$SUITE" --subject "$WORK/elsewhere/hold.sh" --line "$L_THRESH"
assert_eq       "§5 a subject outside the suite's repository is a usage error (rc 2)" "$RC" "2"
run s5g --suite "$SUITE" --line 5 --mode if-true
assert_eq       "§5 an if-* mode without --subject is a usage error (rc 2)" "$RC" "2"

# ── §6  WEAKENING A GUARD: both directions, each with its non-flipper ───────
echo '=== §6 if-true (eager) and if-false (lazy) flip OPPOSITE cases ==='
printf '%s\n' '+knob off refuses' '-knob on passes' '-a fresh hold does not escape' > "$WORK/p6t"
run s6t --suite "$SUITE" --subject "$SUBJ" --line "$L_IF" --mode if-true --predict "$WORK/p6t" --record "$WORK/ledger.tsv"
assert_eq       "§6 if-true: rc 0, prediction confirmed" "$RC" "0"
assert_contains "§6 if-true flips the REFUSING case" "$(out s6t)" "FLIPPED: knob off refuses"
assert_not_contains "§6 if-true does NOT flip the passing case" "$(out s6t)" "FLIPPED: knob on passes"
assert_contains "§6 the rewritten condition is shown" "$(out s6t)" "if true; then"
printf '%s\n' '+knob on passes' '-knob off refuses' > "$WORK/p6f"
run s6f --suite "$SUITE" --subject "$SUBJ" --line "$L_IF" --mode if-false --predict "$WORK/p6f"
assert_eq       "§6 if-false: rc 0, prediction confirmed" "$RC" "0"
assert_contains "§6 if-false flips the PASSING case" "$(out s6f)" "FLIPPED: knob on passes"
assert_not_contains "§6 if-false does NOT flip the refusing case" "$(out s6f)" "FLIPPED: knob off refuses"

# ── §6b  A COMPOUND, MULTI-LINE CONDITION: --mode subst ─────────────────────
# The shape `#1510`'s O1 needs and the if-* modes refuse: the comparison sits
# on the SECOND line of an `if` that the first line continues into.
echo '=== §6b subst: weaken a comparison INSIDE a multi-line condition ==='
run s6c --suite "$SUITE" --subject "$SUBJ" --line "$L_CAP2" --mode if-true
assert_eq       "§6b the if-* modes REFUSE the second line of a compound condition (rc 3)" "$RC" "3"
printf '%s\n' '+under the cap the arm still defers' '-at the cap the veto expires' '-a non-overridable arm never expires' > "$WORK/p6s"
run s6s --suite "$SUITE" --subject "$SUBJ" --line "$L_CAP2" --mode subst --from '>= $2' --to '>= 1' --predict "$WORK/p6s"
assert_eq       "§6b EAGER (cap -> 1): rc 0, prediction confirmed" "$RC" "0"
assert_contains "§6b …flips the under-the-cap case" "$(out s6s)" "FLIPPED: under the cap the arm still defers"
assert_not_contains "§6b …and NOT the non-overridable one, which a different conjunct defends" "$(out s6s)" "FLIPPED: a non-overridable arm never expires"
printf '%s\n' '+at the cap the veto expires' '-under the cap the arm still defers' > "$WORK/p6b"
run s6b --suite "$SUITE" --subject "$SUBJ" --line "$L_CAP2" --mode subst --from '>=' --to '>' --predict "$WORK/p6b"
assert_eq       "§6b BOUNDARY (>= -> >): rc 0, only the at-the-cap case flips" "$RC" "0"
run s6d --suite "$SUITE" --subject "$SUBJ" --line "$L_CAP1" --mode subst --from '== 1' --to '== 0'
assert_eq       "§6b a line ENDING IN A BACKSLASH is mutable under subst (rc 0) — nothing is removed" "$RC" "0"
assert_contains "§6b …and it flips the case that conjunct defends" "$(out s6d)" "FLIPPED: at the cap the veto expires"
run s6e --suite "$SUITE" --subject "$SUBJ" --line "$L_CAP2" --mode subst --from '>= $2' --to '>= 1 )); then yes yes #'
assert_eq       "§6b a rewrite that changes the line's STRUCTURE is REFUSED (rc 3)" "$RC" "3"
assert_contains "§6b …naming what would change" "$(out s6e)" "its structure would not be the old line"
assert_not_contains "§6b …before anything ran" "$(out s6e)" "=== baseline"
run s6f2 --suite "$SUITE" --subject "$SUBJ" --line "$L_CAP2" --mode subst --from 'no such text' --to 'x'
assert_eq       "§6b a --from that is not on the line is REFUSED (rc 3)" "$RC" "3"
run s6g --suite "$SUITE" --subject "$SUBJ" --line "$L_CAP1" --mode subst --from '\' --to '&&'
assert_eq       "§6b rewriting the CONTINUATION itself is REFUSED (rc 3)" "$RC" "3"
run s6h --suite "$SUITE" --subject "$SUBJ" --line "$L_CAP2" --mode subst --from '>= $2'
assert_eq       "§6b subst without --to is a usage error (rc 2)" "$RC" "2"

# ── §7  THE TRACKED SUBJECT IS NEVER EDITED ─────────────────────────────────
echo '=== §7 after every arm above: subject byte-identical, tree clean, nothing left behind ==='
assert_eq "§7 the tracked subject is byte-identical after every experiment above" \
    "$(sha256sum "$SUBJ" | cut -d' ' -f1)" "$SUBJ_SHA"
assert_empty "§7 the fixture repository's working tree is clean" \
    "$(git -C "$FX" status --porcelain --ignored)"
assert_empty "§7 no .mutgate-* file left beside the suite or the subject" \
    "$(find "$FX" -name '.mutgate-*' -print)"
assert_empty "§7 no mutgate workdir left in the tool's TMPDIR" \
    "$(find "$WORK/tmp" -maxdepth 1 -name 'mutgate-*' -print)"
# A caller-named --workdir keeps its CAPTURES and loses the tree copies.
run s7 --suite "$SUITE" --subject "$SUBJ" --line "$L_THRESH" --workdir "$WORK/wd"
assert_file_exists "§7 a named --workdir keeps the mutant capture" "$WORK/wd/mutant.out"
assert_empty "§7 …and not the two tree copies" "$(find "$WORK/wd" -maxdepth 1 \( -name t0 -o -name t1 \) -print)"

# ── §8  --list offers the SUBJECT's lines ───────────────────────────────────
echo '=== §8 --list in subject mode ==='
run s8 --suite "$SUITE" --subject "$SUBJ" --list
assert_eq       "§8 rc 0" "$RC" "0"
assert_contains "§8 lists the threshold guard by its line number" "$(out s8)" "$(printf '%s\t' "$L_THRESH")"
assert_not_contains "§8 does NOT offer the comment line" "$(out s8)" "$(printf '%s\t# escapes' "$L_COMMENT")"
assert_contains "§8 offers the \`if\` line under the if-* heading" "$(out s8)" "1 if-line(s)"

# ── §9  PROVENANCE: green is not guarded (#1510) ────────────────────────────
echo '=== §9 the ledger, and the report that reads it back ==='
assert_eq "§9 three recorded rounds wrote 2 kill rows + 1 survivor row + 1 kill row" \
    "$(grep -vc '^#' "$WORK/ledger.tsv")" "4"
assert_eq "§9 the survivor is on file against NO case" \
    "$(awk -F'\t' '$2=="survived"{print $10}' "$WORK/ledger.tsv")" "-"
assert_eq "§9 a row carries the prediction outcome" \
    "$(awk -F'\t' '$2=="killed-by-assertion" && $8=="delete"{print $12}' "$WORK/ledger.tsv" | sort -u)" "confirmed"
run s9 --provenance "$WORK/ledger.tsv" --suite "$SUITE"
assert_eq       "§9 rc 4: not every case is guarded" "$RC" "4"
assert_contains "§9 a killed case reads GUARDED" "$(out s9)" "GUARDED        past grace, under the threshold does not escape"
assert_contains "§9 a case no mutant ever killed reads NEVER-KILLED, though it PASSES" "$(out s9)" "NEVER-KILLED   a fresh hold does not escape"
assert_contains "§9 the tally" "$(out s9)" "9 case(s) — 3 GUARDED, 0 GUARDED-STALE, 6 NEVER-KILLED"
# THE GENERATOR: a case added AFTER the round inherits its green, and a suite
# edit makes every earlier kill stale. Both must now be VISIBLE.
cp "$SUITE" "$WORK/suite.orig"
sed -i 's|^printf .=== summary|escapes 9999; ck "a case added after the round" "$?" 0\n&|' "$SUITE"
run s9b --provenance "$WORK/ledger.tsv" --suite "$SUITE"
assert_contains "§9 a case added after the round is NEVER-KILLED, not silently green" "$(out s9b)" "NEVER-KILLED   a case added after the round"
assert_contains "§9 earlier kills are STALE once the suite changed" "$(out s9b)" "GUARDED-STALE  past grace, under the threshold does not escape"
assert_contains "§9 …and the report says WHAT changed" "$(out s9b)" "the suite changed since"
cat "$WORK/suite.orig" > "$SUITE"
# --labels-from reads the cases from a capture instead of running the suite.
bash "$SUITE" > "$WORK/cap.out" 2>/dev/null
run s9c --provenance "$WORK/ledger.tsv" --suite "$SUITE" --labels-from "$WORK/cap.out"
assert_contains "§9 --labels-from gives the same tally without a run" "$(out s9c)" "9 case(s) — 3 GUARDED, 0 GUARDED-STALE, 6 NEVER-KILLED"
assert_not_contains "§9 …and really did not run the suite" "$(out s9c)" "=== running"

# ── §9d  THE TRACKED LEDGER ─────────────────────────────────────────────────
# monitor/watcher/mutation-provenance.tsv is written only by `--record`. A
# malformed row is read by `--provenance` as "no such kill", i.e. NEVER-KILLED —
# a silent loss of evidence in the quiet direction — so its shape is pinned.
echo '=== §9d the tracked provenance ledger is well-formed, and carries the #1510 instance ==='
LEDGER="$REPO_ROOT/monitor/watcher/mutation-provenance.tsv"
_rows=$(grep -v '^#' "$LEDGER" 2>/dev/null | grep -c .)
assert_eq "§9d non-vacuity: the ledger has rows (a check over none would assert nothing)" "$(( _rows > 0 ))" "1"
assert_empty "§9d every row has exactly 13 tab-separated fields" \
    "$(awk -F'\t' '!/^#/ && NF != 13 { print NR": "NF" fields" }' "$LEDGER")"
assert_empty "§9d every verdict is one the tool can write" \
    "$(awk -F'\t' '!/^#/ && $2 !~ /^(killed-by-assertion|survived|killed-unattributable|survived-unwitnessed)$/ { print NR": "$2 }' "$LEDGER")"
assert_empty "§9d every prediction outcome is one the tool can write" \
    "$(awk -F'\t' '!/^#/ && $12 !~ /^(confirmed|refuted|none)$/ { print NR": "$12 }' "$LEDGER")"
assert_empty "§9d every suite and subject a row names EXISTS in this tree" \
    "$(awk -F'\t' '!/^#/ { print $3; if ($5 != "-") print $5 }' "$LEDGER" | sort -u \
        | while IFS= read -r _f; do [ -f "$REPO_ROOT/$_f" ] || printf '%s\n' "$_f"; done)"
# THE INSTANCE `#1510` WAS FILED ABOUT: `O1` of test-cc-auto-update.sh had no
# killing mutant across three rounds. The eager-direction mutant on the cap
# comparison (`streak >= CAP` -> `streak >= 1`, --mode subst) is on file.
assert_eq "§9d #1510: O1 has a recorded kill (the eager cap mutant three rounds never ran)" \
    "$(awk -F'\t' '!/^#/ && $2 == "killed-by-assertion" && $3 == "monitor/watcher/test-cc-auto-update.sh" && index($10, "#1492 O1:") == 1' "$LEDGER" | wc -l | tr -d ' ')" "1"

# ── §10  SUITE MODE IS UNCHANGED, and now prints a flip set too ─────────────
echo '=== §10 --suite alone still mutates the suite, in place beside it ==='
L_CK=$(grep -n -F 'escapes 4000; ck' "$SUITE" | cut -d: -f1)
run s10 --suite "$SUITE" --line "$L_CK" --match 'ck '
assert_contains "§10 a deleted suite line survives or is killed, but is never a subject verdict" "$(out s10)" "VERDICT:"
assert_not_contains "§10 no tree copy is made in suite mode" "$(out s10)" "gitignored path(s) NOT copied"
_help=$("$GATE" --help 2>&1 || true)
assert_contains "§10 --help states the two questions" "$_help" "would this suite CATCH A DEFECT"
assert_contains "§10 --help documents exit 6" "$_help" "PREDICTION REFUTED"

# ── §11  A LINKED WORKTREE is an acceptable root ────────────────────────────
# repo-root.sh says `verdict=no kind=linked-worktree` for one (its git dir is the
# main repository's). This tool only READS the working tree, so it accepts that
# kind rather than sending the caller to make a fresh clone (skeptic round 3).
echo '=== §11 the subject in a LINKED WORKTREE of the fixture repo ==='
WT="$WORK/fx-wt"
git -C "$FX" worktree add --detach "$WT" HEAD > /dev/null 2>&1 || { echo "  (could not add a worktree)" >&2; }
run s11 --suite "$WT/t/test-hold.sh" --subject "$WT/lib/hold.sh" --line "$L_THRESH"
assert_eq       "§11 a linked worktree is accepted: the same mutant is killed (rc 0)" "$RC" "0"
assert_not_contains "§11 …with no root refusal" "$(out s11)" "not its own repository root"
# (#1564 G13) …accepted by its KIND FIELD, asked for, not by a glob over a verdict
# line that also carries paths. A static pin, and said to be one: `git rev-parse
# --show-toplevel` only ever hands this check a real root or a linked worktree,
# so no fixture can drive a refused tree whose PATH contains the text.
assert_eq "§11 G13: the root check no longer globs the whole verdict line" \
    "$(grep -o -F '*kind=linked-worktree*)' "$GATE" | wc -l | tr -d ' ')" "0"
assert_eq "§11 G13: …it asks repo-root.sh for the kind and compares for equality" \
    "$(grep -o -F '[ "$rr_kind" = linked-worktree ] && rr_ok=1' "$GATE" | wc -l | tr -d ' ')" "1"
git -C "$FX" worktree remove --force "$WT" > /dev/null 2>&1 || true

# ASSERTION CENSUS — the exact-count guard (your-org/nexus-code#807).
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
