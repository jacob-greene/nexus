#!/usr/bin/env bash
# test-worker-floor-synthetic-fixtures.sh — the synthetic-fixture rule must
# reach every spawned worker, and the self-fix skill must carry the stand-in
# table a suite author consults (your-org/nexus-code#1762).
#
# WHY A TEST FOR PROSE. The rule's whole value is that it is IN the injected
# floor at the moment a worker pastes a captured pane into a fixture. The
# floor is extracted by spawn-worker.sh with an H2-bounded awk, so a rule that
# lands under the wrong heading, or after a stray `## `, is never injected
# while the file still "contains" it. This suite extracts the floor with the
# SAME awk program, read out of spawn-worker.sh rather than copied, so the
# two cannot drift apart.
#
#   W1  spawn-worker.sh's floor extraction program is found (non-vacuity)
#   W2  the extracted floor carries the rule (its issue tag and the stand-ins)
#   W3  the self-fix skill carries the stand-in table under its suite section
#   W4  the floor's own stand-in examples do not trip the leak gate's
#       sample-ID shape rows: the rule must not teach a value the gate refuses
#   W5  the extracted floor carries the sbatch-argument rule (#1778): no
#       multi-GB file as an sbatch argument, no `sbatch --wait` (#1728)
#   W6  the extracted floor carries the Slurm job-I/O rule (#1778): no
#       scratchpad/$TMPDIR in a job, the wrapper ends with the real rc
#   W7  the sbatch rule names the MEASURED mechanism (`bash -s --` + the
#       Falcon LSM reading the first positional) and the remedies (a FILE,
#       a python shebang), says the wrapper DROPS exported env, and does
#       NOT prescribe `--export=NAME=…` (unverified through the wrapper).
#       The Falcon attribution is INFERENCE in the source report, so the floor
#       must say so, and must not offer the unmeasured "pass the DIRECTORY"
#       (bundle 22, skeptic F1 on PR #1784)
#   W8  the floor says $TMPDIR is per agent only when a launcher set it,
#       and prescribes mktemp names (bundle 21)
#   W9  the floor says a success-only wait never wakes on an abort and
#       names the failure arm (bundle 21)
#   W10 the floor says to do read-only aggregation in Python or a script
#       FILE, never a `bash -c '<script>'`, and to hand that rule to
#       in-process sub-agents (bundle 22)
#
# Run: bash monitor/watcher/test-worker-floor-synthetic-fixtures.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
SPAWN="$SRC_ROOT/monitor/spawn-worker.sh"
FLOOR_FILE="$SRC_ROOT/skills/nexus.worker-defaults/SKILL.md"
SELFFIX="$SRC_ROOT/skills/nexus.self-fix/SKILL.md"
MAP="$SRC_ROOT/monitor/public-mirror/mapping.tsv"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

for f in "$SPAWN" "$FLOOR_FILE" "$SELFFIX"; do
    [ -r "$f" ] || { echo "missing $f" >&2; exit 1; }
done

# The awk program between `floor_body=$(awk '` and the closing `' "$FLOOR_FILE")`.
prog=$(awk '
  /^floor_body=\$\(awk '\''$/ { on=1; next }
  on && /^'\'' "\$FLOOR_FILE"\)$/ { exit }
  on { print }
' "$SPAWN")
if grep -q 'Worker floor' <<<"$prog"; then
    pass "W1: spawn-worker.sh's floor extraction program found"
else
    fail "W1: could not read the floor extraction program out of spawn-worker.sh"
fi

floor=$(awk "$prog" "$FLOOR_FILE")
if grep -qF '#1762' <<<"$floor" && grep -qF 'SAMPLE_A' <<<"$floor" \
   && grep -qF 'SYNTHETIC stand-ins' <<<"$floor"; then
    pass "W2: the injected floor carries the synthetic-fixture rule"
else
    fail "W2: the synthetic-fixture rule is not in the floor spawn-worker.sh injects"
fi

section=$(awk '
  /^## Writing a test suite here/ { on=1; next }
  on && /^## /                    { exit }
  on                              { print }
' "$SELFFIX")
if grep -qF '#1762' <<<"$section" && grep -qE '^\| sample ID \|' <<<"$section" \
   && grep -qE '^\| hostname \|' <<<"$section"; then
    pass "W3: the self-fix suite-writing section carries the stand-in table"
else
    fail "W3: the stand-in table is missing from the self-fix suite-writing section"
fi

# W4: the stand-ins the floor and table recommend, against the deny rows that
# are SHAPES (a regex class), read from the dictionary at run time. Value rows
# cannot match these nonsense stand-ins, and naming them here would publish
# them. A missing dictionary (a fresh operator's clone) is reported, not
# skipped: the assertion count below stays exact either way.
if [ -r "$MAP" ]; then
    shapes=$(awk -F'\t' '$1=="deny" && $2 ~ /[[{]/ {print $2}' "$MAP" | paste -sd'|')
    stand=$( { printf '%s\n' "$floor"; printf '%s\n' "$section"; } \
             | grep -oE 'SAMPLE_[A-Z]|proj-x|node01|1234567|192\.0\.2\.[0-9]+' | sort -u)
    if [ -z "$stand" ]; then
        fail "W4: no stand-in values found to check — the extraction above read nothing"
    elif [ -n "$shapes" ] && grep -qiE -e "$shapes" <<<"$stand"; then
        fail "W4: a recommended stand-in matches a leak-gate shape row"
    else
        pass "W4: none of the $(grep -c . <<<"$stand") recommended stand-ins trips a leak-gate shape row"
    fi
else
    pass "W4: no mapping.tsv in this clone — shape rows not checkable here (reported, not skipped)"
fi

# W5: the same extraction, for the Slurm launch rule (your-org/nexus-code#1778).
if grep -qF '#1778' <<<"$floor" && grep -qF 'sbatch` ARGUMENT' <<<"$floor" \
   && grep -qF 'sbatch --wait' <<<"$floor"; then
    pass "W5: the injected floor carries the sbatch-argument / no --wait rule"
else
    fail "W5: the sbatch-argument rule is not in the floor spawn-worker.sh injects"
fi

# W6: the job-I/O / honest-exit rule, same extraction (your-org/nexus-code#1778).
if grep -qF 'must not read or write the session scratchpad' <<<"$floor" \
   && grep -qF 'COMPLETED 0:0' <<<"$floor" && grep -qF '/loc/scratch' <<<"$floor"; then
    pass "W6: the injected floor carries the Slurm job-I/O / real-rc rule"
else
    fail "W6: the Slurm job-I/O rule is not in the floor spawn-worker.sh injects"
fi

# W7: the mechanism and the remedies, not the first (wrong) account. The
# source report's own workaround was `--export=NAME=path`, and a separate
# measurement found the wrapper drops exported env, so the floor must not
# hand it out as the fix.
if grep -qF 'bash -s -- <args>' <<<"$floor" && grep -qF 'Falcon' <<<"$floor" \
   && grep -qF 'FIRST POSITIONAL' <<<"$floor" && grep -qF 'python-shebang' <<<"$floor" \
   && grep -qF 'DROPS the submitting shell' <<<"$floor" && grep -qF 'UNVERIFIED' <<<"$floor" \
   && grep -qF 'BY INFERENCE' <<<"$floor" && ! grep -qF 'pass the DIRECTORY' <<<"$floor" \
   && ! grep -qF -e '--export=' <<<"$floor"; then
    pass "W7: the sbatch rule names the measured mechanism and remedies, and never prescribes --export="
else
    fail "W7: the sbatch rule lacks the mechanism/remedy wording, or prescribes --export="
fi

# W8: per-agent TMPDIR, and the mktemp rule for what it cannot cover.
if grep -qF 'PER AGENT only if a launcher set it' <<<"$floor" && grep -qF 'agent-<window>' <<<"$floor" \
   && grep -qF 'mktemp "${TMPDIR:?}/' <<<"$floor"; then
    pass "W8: the floor carries the per-agent TMPDIR rule and the mktemp remedy"
else
    fail "W8: the per-agent TMPDIR rule is not in the injected floor"
fi

# W9: the success-only wait.
if grep -qF 'matches only the SUCCESS line never wakes on an abort' <<<"$floor" \
   && grep -qF -e '--fail-pattern' <<<"$floor"; then
    pass "W9: the floor carries the success-only-wait rule and names --fail-pattern"
else
    fail "W9: the success-only-wait rule is not in the injected floor"
fi

# W10: the `bash -c` permission-dialog rule (bundle 22).
if grep -qF 'never in a' <<<"$floor" && grep -qF "\`bash -c '<script>'\`" <<<"$floor" \
   && grep -qF 'PERMISSION DIALOG' <<<"$floor" && grep -qF 'in-process' <<<"$floor" \
   && grep -qF 'sub-agent' <<<"$floor" && grep -qF 'bash "$f"' <<<"$floor"; then
    pass "W10: the floor carries the bash -c / Python-aggregation rule and the sub-agent hand-off"
else
    fail "W10: the bash -c / Python-aggregation rule is not in the injected floor"
fi

# THE ASSERTION TOTAL IS EXACT: an assertion that silently stops running (a
# section that aborted, a loop over an empty set) is a red, not a smaller green.
EXPECTED=10
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: assertion census %d != EXPECTED %d — an assertion did not run, or one was added without updating EXPECTED\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
