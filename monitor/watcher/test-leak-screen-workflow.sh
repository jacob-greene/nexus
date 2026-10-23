#!/usr/bin/env bash
# test-leak-screen-workflow.sh — the per-PR leak screen must exist as its own
# check, run the build-then-gate suite, and never turn "did not run" into a
# pass (your-org/nexus-code#1759).
#
# The step's `run:` body is READ OUT OF the workflow file and EXECUTED against
# a stub suite in a throwaway directory, so this tests what CI will run, not a
# copy of it:
#
#   L1  .github/workflows/leak-screen.yml exists and parses
#   L2  it triggers on pull_request with no paths:/branches: filter (a leak
#       can land in any tracked byte, on a PR against any base)
#   L3  the job installs nothing (no apt-get) and is not a matrix (CI budget)
#   L4  its step runs test-public-mirror-dictionary-coverage.sh
#   L5  suite rc 0  -> step rc 0
#   L6  suite rc 1  -> step rc 1   (a leak is red)
#   L7  suite rc 77 -> step NON-ZERO (a decline is the screen not running)
#   L8  no mapping.tsv -> step rc 0 with a notice, and the suite NOT run
#       (the public mirror has no dictionary by design)
#
# Run: bash monitor/watcher/test-leak-screen-workflow.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
WF="$SRC_ROOT/.github/workflows/leak-screen.yml"
SUITE_REL="monitor/watcher/test-public-mirror-dictionary-coverage.sh"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lsw.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
cleanup(){ [ -n "${WORK:-}" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

# One python pass extracts every fact the bash below asserts on. A missing
# file or a parse error leaves facts.txt without its `ok` line, so L1 fails
# and every later assertion fails with it rather than being skipped.
python3 - "$WF" > "$WORK/facts.txt" 2>"$WORK/facts.err" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print("ok")
on = wf.get("on", wf.get(True))            # PyYAML reads a bare `on:` key as True
pr = on.get("pull_request") if isinstance(on, dict) else None
print("pr=%s" % ("yes" if isinstance(on, dict) and "pull_request" in on else "no"))
filt = isinstance(pr, dict) and any(k in pr for k in ("paths", "paths-ignore", "branches", "branches-ignore"))
print("filter=%s" % ("yes" if filt else "no"))
jobs = wf.get("jobs", {})
print("njobs=%d" % len(jobs))
job = next(iter(jobs.values()))
print("matrix=%s" % ("yes" if "matrix" in (job.get("strategy") or {}) else "no"))
runs = [s.get("run", "") for s in job.get("steps", []) if "run" in s]
print("apt=%s" % ("yes" if any("apt-get" in r for r in runs) else "no"))
body = next((r for r in runs if "test-public-mirror-dictionary-coverage.sh" in r), "")
print("hasstep=%s" % ("yes" if body else "no"))
PY
fact(){ awk -F= -v k="$1" '$1==k{print $2; exit}' "$WORK/facts.txt"; }

# The step body itself, written into $WORK (never the caller's cwd).
( cd "$WORK" && python3 - "$WF" >/dev/null 2>&1 <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
job = next(iter(wf["jobs"].values()))
body = next((s["run"] for s in job["steps"] if "test-public-mirror-dictionary-coverage.sh" in s.get("run", "")), "")
open("step.sh", "w").write(body)
PY
)

if grep -qx ok "$WORK/facts.txt"; then
    pass "L1: leak-screen.yml exists and parses"
else
    fail "L1: leak-screen.yml missing or unparseable: $(tr '\n' ' ' < "$WORK/facts.err" 2>/dev/null)"
fi
if [ "$(fact pr)" = yes ] && [ "$(fact filter)" = no ]; then
    pass "L2: triggers on every pull_request (no paths:/branches: filter)"
else
    fail "L2: pull_request=$(fact pr) filter=$(fact filter) (want yes/no)"
fi
if [ "$(fact apt)" = no ] && [ "$(fact matrix)" = no ] && [ "$(fact njobs)" = 1 ]; then
    pass "L3: one job, no matrix, no apt-get"
else
    fail "L3: jobs=$(fact njobs) matrix=$(fact matrix) apt=$(fact apt) (want 1/no/no)"
fi
if [ "$(fact hasstep)" = yes ] && [ -s "$WORK/step.sh" ]; then
    pass "L4: a step runs $SUITE_REL"
else
    fail "L4: no step runs $SUITE_REL"
fi

# run_step <suite-rc|absent> <with-mapping 0|1> -> SRC (step rc), SOUT, RAN
run_step(){
    local rc=$1 withmap=$2 d="$WORK/run"
    rm -rf -- "$d"; mkdir -p "$d/monitor/watcher" "$d/monitor/public-mirror"
    printf '#!/usr/bin/env bash\ntouch "%s/ran"\nexit %s\n' "$d" "$rc" > "$d/$SUITE_REL"
    [ "$withmap" = 1 ] && printf 'deny\tzarquon\n' > "$d/monitor/public-mirror/mapping.tsv"
    SOUT=$(cd "$d" && bash -e "$WORK/step.sh" 2>&1); SRC=$?
    RAN=no; [ -e "$d/ran" ] && RAN=yes
    return 0
}

run_step 0 1
[ "$SRC" -eq 0 ] && [ "$RAN" = yes ] && pass "L5: suite rc 0 -> step rc 0" \
    || fail "L5: suite rc 0 -> step rc $SRC ran=$RAN (want 0/yes)"
run_step 1 1
[ "$SRC" -eq 1 ] && [ "$RAN" = yes ] && pass "L6: suite rc 1 -> step rc 1 (a leak is red)" \
    || fail "L6: suite rc 1 -> step rc $SRC ran=$RAN (want 1/yes; rc 1 without the suite running is vacuous)"
run_step 77 1
[ "$SRC" -ne 0 ] && grep -q 'DECLINED' <<<"$SOUT" && pass "L7: suite rc 77 -> step rc $SRC, named DECLINED (not a pass)" \
    || fail "L7: suite rc 77 -> step rc $SRC (want non-zero, named): $SOUT"
run_step 0 0
[ "$SRC" -eq 0 ] && [ "$RAN" = no ] && grep -q 'nothing to screen' <<<"$SOUT" \
    && pass "L8: no dictionary -> step rc 0 with a notice, suite not run" \
    || fail "L8: no dictionary -> step rc $SRC ran=$RAN (want 0/no + notice): $SOUT"

# THE ASSERTION TOTAL IS EXACT: an assertion that silently stops running (a
# section that aborted, a loop over an empty set) is a red, not a smaller green.
EXPECTED=8
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: assertion census %d != EXPECTED %d — an assertion did not run, or one was added without updating EXPECTED\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
