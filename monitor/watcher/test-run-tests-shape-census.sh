#!/usr/bin/env bash
# TWO WAYS THE RUNNER COULD ANSWER ABOUT LESS THAN IT SAID IT DID.
# (your-org/nexus-code#1618, #1620)
#
# §A — A DECIMAL IS NOT `^[0-9]+$` IN BASH ARITHMETIC (#1618). The #1616 shape
# check on NEXUS_ASSERT_ACCOUNTING_FLOOR admitted a leading zero, which bash
# reads as OCTAL: `010` made the floor EIGHT, and `08` made `(( n >= 08 ))` an
# arithmetic ERROR — a FALSE test, so the broken-accounting detector was
# SKIPPED (fail-open). §A walks the THRESHOLD rather than re-deriving the
# value: #1618's first verification printed the effective floor as
# `$((10#$v))`, i.e. normalised its input exactly as the FIX would, and so
# measured the fixed behaviour while testing unfixed code. Nothing below does
# arithmetic on a value under test; every case observes whether the detector
# FIRED, or what the runner REFUSED. The sweep #1616 asked for covers every
# `(( ))` in the runner fed from the environment or argv — the table is in
# run-tests.sh above `_rt_is_decimal` — and each member has a case here.
#
# §B — A TRACKED SUITE NO ROOT WALKS (#1620). Every reporting path in the
# runner is downstream of selection, so a suite outside every root appeared
# ZERO times in a band log. The census names it, reddens the run, and keeps
# "filtered out by --filter" apart from "walked by no root". §B3: a file that
# is DELIBERATELY unwalked (a fixture or stub with a `test-*.sh` name) is
# declared, one `path|reason` row per file, in census-exclusions.manifest — and
# the declaration is VISIBLE (`excluded=N`, an `EXCLUDED:` line per row) and
# RE-CHECKED (a reasonless, malformed, duplicate or STALE row, or an untracked
# manifest, is itself red), so the list cannot grow into the invisible
# exclusion #1078/#1620 are about. Driven against
# FIXTURE REPOSITORIES holding a copy of the runner under test, never against
# this repo's own tree, whose census is empty by construction and therefore
# cannot show that the census can fire.
#
# Run: bash monitor/watcher/test-run-tests-shape-census.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
RUNNER="$_test_dir/run-tests.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$RUNNER" "$_test_dir/band-verdict.sh" "$_test_dir/_test_helpers.sh"; }
gp_handle "$@"

[[ -r "$RUNNER" ]] || { echo "missing runner: $RUNNER" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git absent — §B needs fixture repositories"; echo "ALL TESTS PASSED"; exit 77; }

WORK=$(mktemp -d) || { echo "FAIL: mktemp for the fixture"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# Every inner run starts from a KNOWN environment: the inputs this suite varies
# are removed first — so a case's own value goes AFTER `rt`, never before it
# (`X=1 rt …` is unset again by the `env -u`; the first draft of §A1 did that
# and its floor-8 MUST-NOT-FLIP is what caught it) — so an outer band's value (CI sets NEXUS_TEST_DEADLINE_SCALE)
# cannot decide a case. The nproc guard is off for speed except where probed.
rt() {
    env -u KEEP_LOGS_DIR -u NEXUS_TEST_REQUIRE_RUN -u NEXUS_TEST_REQUIRE_MEASURED \
        -u NEXUS_TEST_REQUIRE_CI_PARITY -u NEXUS_TEST_TIMEOUT -u NEXUS_ASSERT_ACCOUNTING_FLOOR \
        -u NEXUS_TEST_DEADLINE_SCALE -u NEXUS_TEST_NPROC_HEADROOM NEXUS_TEST_NPROC_GUARD=off "$@"
}
FIRED='ASSERTION ACCOUNTING IS BROKEN'

# ── §A fixtures ─────────────────────────────────────────────────────────
mkdir -p "$WORK/nc"
# A pass that declares NO count reads as `?` — the population the accounting
# detector counts. Twenty of them, so a floor of 20 (the fallback) can be met.
for i in $(seq -w 1 20); do
    printf '#!/usr/bin/env bash\necho "ALL TESTS PASSED"\nexit 0\n' > "$WORK/nc/test-nc-$i.sh"
done
NC8=("$WORK"/nc/test-nc-0[1-8].sh)
NC20=("$WORK"/nc/test-nc-*.sh)
(( ${#NC8[@]} == 8 && ${#NC20[@]} == 20 )) || { echo "FAIL: fixture glob (${#NC8[@]}/${#NC20[@]})"; exit 1; }
cat > "$WORK/ok.sh" <<'OK'
#!/usr/bin/env bash
printf '%s' "${NEXUS_TEST_DEADLINE_SCALE-UNSET}" > "${SEEN_FILE:-/dev/null}"
echo "  PASS: ok"
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
OK
cat > "$WORK/test-slow.sh" <<'SLOW'
#!/usr/bin/env bash
sleep 8
echo "  PASS: slow"
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
SLOW
chmod +x "$WORK"/nc/*.sh "$WORK/ok.sh" "$WORK/test-slow.sh"

echo '=== §A1: the accounting floor, walked across its threshold (#1618) ==='
# MUST-NOT-FLIP, first: the threshold is where it should be for well-formed
# values. Eight no-count passes fire the detector at a floor of 8 and not at 9.
OUT=$(rt NEXUS_ASSERT_ACCOUNTING_FLOOR=8 bash "$RUNNER" "${NC8[@]}" 2>&1)
assert_contains     "A1 MUST-NOT-FLIP: floor 8, 8 no-count passes -> the detector FIRES"      "$OUT" "$FIRED"
OUT=$(rt NEXUS_ASSERT_ACCOUNTING_FLOOR=9 bash "$RUNNER" "${NC8[@]}" 2>&1)
assert_not_contains "A1 MUST-NOT-FLIP: floor 9, 8 no-count passes -> it does not"            "$OUT" "$FIRED"
# `010` was OCTAL EIGHT: it fired on 8 files, exactly as floor 8 did above. Now
# rejected into the fallback (20), so 8 files do not reach it.
OUT=$(rt NEXUS_ASSERT_ACCOUNTING_FLOOR=010 bash "$RUNNER" "${NC8[@]}" 2>&1)
assert_not_contains "A1 floor 010 is not read as octal 8 (8 no-count passes do not fire it)" "$OUT" "$FIRED"
assert_contains     "A1 …and the rejection is SAID"                                          "$OUT" "NEXUS_ASSERT_ACCOUNTING_FLOOR=010 is not a non-negative integer — using 20"
# `08` was an arithmetic ERROR: the test read false and the detector was
# SKIPPED however many files qualified. Now it falls back to 20, and 20 fire it.
OUT=$(rt NEXUS_ASSERT_ACCOUNTING_FLOOR=08 bash "$RUNNER" "${NC20[@]}" 2>&1)
assert_contains     "A1 floor 08 no longer SKIPS the detector (20 no-count passes fire it)"  "$OUT" "$FIRED"
assert_not_contains "A1 …and no arithmetic error reached the log"                            "$OUT" "value too great for base"

echo '=== §A2: every other environment/argv value that reaches (( )) (#1618 sweep) ==='
# The refusals: rc 2 BEFORE any dispatch, so no END marker and no row.
_refused() {  # <label> <needle> <cmd…>
    local label="$1" needle="$2"; shift 2
    OUT=$("$@" 2>&1); RC=$?
    assert_rc       "A2 $label is REFUSED (rc 2)" "$RC" "2"
    assert_contains "A2 …$label: the refusal names the value" "$OUT" "$needle"
}
_refused "--timeout 08"                     "got 08 /"              rt bash "$RUNNER" --timeout 08 "$WORK/ok.sh"
_refused "NEXUS_TEST_TIMEOUT=010"           "got 010 /"             rt NEXUS_TEST_TIMEOUT=010 bash "$RUNNER" "$WORK/ok.sh"
_refused "--max-seconds 010"                "/ 010;"                rt bash "$RUNNER" --max-seconds 010 "$WORK/ok.sh"
_refused "--jobs 010"                       "got 010;"              rt bash "$RUNNER" --jobs 010 "$WORK/ok.sh"
# A WORD in a require-flag was a VARIABLE NAME to `(( require_run == 1 ))`, and
# under `set -u` it killed the runner AFTER every suite ran — no END marker.
_refused "NEXUS_TEST_REQUIRE_RUN=yes"       "NEXUS_TEST_REQUIRE_RUN=yes is not 0 or 1"       rt NEXUS_TEST_REQUIRE_RUN=yes bash "$RUNNER" "$WORK/ok.sh"
_refused "NEXUS_TEST_REQUIRE_MEASURED=08"   "NEXUS_TEST_REQUIRE_MEASURED=08 is not 0 or 1"   rt NEXUS_TEST_REQUIRE_MEASURED=08 bash "$RUNNER" "$WORK/ok.sh"
_refused "NEXUS_TEST_REQUIRE_CI_PARITY=true" "NEXUS_TEST_REQUIRE_CI_PARITY=true is not 0 or 1" rt NEXUS_TEST_REQUIRE_CI_PARITY=true bash "$RUNNER" "$WORK/ok.sh"

# A DIGIT BOUND (#1618 residual): bash arithmetic WRAPS at 2^64, rc 0, so
# `18446744073709551616` read as 0 — the per-test timeout DISABLED, and an 8 s
# suite under it ran to completion. Walked across the chosen 18-digit bound.
_refused "--timeout 2^64 (wraps to 0)"      "got 18446744073709551616 /" rt bash "$RUNNER" --timeout 18446744073709551616 "$WORK/test-slow.sh"
_refused "NEXUS_TEST_TIMEOUT 19 digits"     "got 1000000000000000000 /"  rt NEXUS_TEST_TIMEOUT=1000000000000000000 bash "$RUNNER" "$WORK/ok.sh"
OUT=$(rt bash "$RUNNER" --timeout 999999999999999999 "$WORK/ok.sh" 2>&1); RC=$?
assert_rc "A2 MUST-NOT-FLIP: an 18-digit timeout is still accepted (rc 0)" "$RC" "0"

# The fallbacks: the run proceeds, the value is named.
OUT=$(rt NEXUS_TEST_NPROC_GUARD=on NEXUS_TEST_NPROC_HEADROOM=08 bash "$RUNNER" "$WORK/ok.sh" 2>&1); RC=$?
assert_contains "A2 NEXUS_TEST_NPROC_HEADROOM=08 falls back to 2048, said"  "$OUT" "NEXUS_TEST_NPROC_HEADROOM=08 is not a decimal integer (no leading zero) — using 2048"
assert_contains "A2 …and the run still reaches its verdict"                  "$OUT" "=== run-tests: END rc=0 (COMPLETE and green) ==="
# DEADLINE_SCALE: the runner's header and the SUITE must agree. `08` is ignored
# AND removed from the suite's environment, so "derived" is true of both.
OUT=$(rt NEXUS_TEST_DEADLINE_SCALE=08 SEEN_FILE="$WORK/seen-08" bash "$RUNNER" "$WORK/ok.sh" 2>&1)
assert_contains "A2 NEXUS_TEST_DEADLINE_SCALE=08 is named as IGNORED"        "$OUT" "NEXUS_TEST_DEADLINE_SCALE=08 is not a decimal integer (no leading zero) — IGNORED"
assert_eq       "A2 …and the SUITE no longer receives it"                    "$(cat "$WORK/seen-08" 2>/dev/null)" "UNSET"
OUT=$(rt NEXUS_TEST_DEADLINE_SCALE=2 SEEN_FILE="$WORK/seen-2" bash "$RUNNER" "$WORK/ok.sh" 2>&1)
assert_contains "A2 MUST-NOT-FLIP: a valid scale is still explicit"          "$OUT" "deadline-scale=2 (explicit)"
assert_eq       "A2 MUST-NOT-FLIP: …and still reaches the suite"             "$(cat "$WORK/seen-2" 2>/dev/null)" "2"
# MUST-NOT-FLIP: well-formed values across every checked input, one clean run.
OUT=$(rt NEXUS_TEST_REQUIRE_CI_PARITY=0 NEXUS_TEST_REQUIRE_MEASURED=0 NEXUS_TEST_REQUIRE_RUN=0 \
      bash "$RUNNER" --jobs 2 --timeout 60 --max-seconds 0 "$WORK/ok.sh" 2>&1); RC=$?
assert_rc "A2 MUST-NOT-FLIP: well-formed values everywhere run clean (rc 0)" "$RC" "0"

# A ceiling-overrides ROW: `0600` compared as octal 384 in `(( cand > run ))`
# and was then handed to `timeout` as 600 — a 600 s ceiling nobody wrote. Now
# the row is ignored and the run's own ceiling (3 s) applies to an 8 s suite.
printf 'test-slow.sh\t0600\n' > "$WORK/ceil.tsv"
OUT=$(rt NEXUS_TEST_CEILING_FILE="$WORK/ceil.tsv" bash "$RUNNER" --timeout 3 "$WORK/test-slow.sh" 2>&1)
assert_contains "A2 a leading-zero ceiling override is ignored: the run's 3 s ceiling applies" "$OUT" "  TIMEOUT  test-slow.sh"

echo '=== §A3: th_deadline reads NEXUS_TEST_DEADLINE_SCALE by the same shape (#1618) ==='
# A SUITE RUN DIRECTLY never passes through the runner's unset, so the helper
# needs the check too. Observed as the deadline it RETURNS for a 30 s base, at
# NEXUS_TEST_JOBS=1 (derived scale 1 on any host) — never recomputed here.
_thd() {  # <scale-or-empty> -> "rc=<rc> out=<deadline>"
    local o rc
    o=$(env -u NEXUS_TEST_DEADLINE_SCALE NEXUS_TEST_JOBS=1 ${1:+NEXUS_TEST_DEADLINE_SCALE=$1} \
        bash -c '. "$1"; th_deadline 30' _ "$_test_dir/_test_helpers.sh" 2>/dev/null); rc=$?
    printf 'rc=%s out=%s' "$rc" "$o"
}
assert_eq "A3 scale 08 no longer kills the caller: the derived deadline comes back" "$(_thd 08)"  "rc=0 out=30"
assert_eq "A3 scale 010 is not octal 8 (was 240 s for a 30 s base)"               "$(_thd 010)" "rc=0 out=30"
assert_eq "A3 MUST-NOT-FLIP: a valid scale still multiplies"                       "$(_thd 2)"   "rc=0 out=60"
assert_eq "A3 MUST-NOT-FLIP: 0 still means derive"                                 "$(_thd 0)"   "rc=0 out=30"
assert_eq "A3 MUST-NOT-FLIP: unset still means derive"                             "$(_thd '')"  "rc=0 out=30"
# The digit bound: 2^64+2 WRAPPED to scale 2 (60 s) — a garbage string read as
# well-formed. Now derived. An 18-digit scale is still honoured.
assert_eq "A3 a 20-digit scale does not wrap to 2 (was 60 s)"                     "$(_thd 18446744073709551618)" "rc=0 out=30"
assert_eq "A3 MUST-NOT-FLIP: an 18-digit scale still multiplies"                   "$(_thd 100000000000000000)"   "rc=0 out=3000000000000000000"

# ── §B fixtures: a repository holding a copy of the runner under test ──────
# Copied from THIS tree (so a mutation of run-tests.sh is what the fixture
# runs), plus the two siblings it sources/executes.
_mkrepo() {  # <dir> <commit-runner:0|1> <git:0|1> <suite-rel…>
    local d="$1" commit_runner="$2" use_git="$3"; shift 3
    local ok='#!/usr/bin/env bash\necho "  PASS: ok"\necho "=== summary: 1 passed, 0 failed ==="\necho "ALL TESTS PASSED"\n'
    local s
    mkdir -p "$d/monitor/watcher"
    cp "$RUNNER" "$d/monitor/watcher/run-tests.sh"
    cp "$_test_dir/../_tmux_socket.sh" "$_test_dir/../repo-root.sh" "$d/monitor/"
    for s in "$@"; do mkdir -p "$d/$(dirname "$s")"; printf "$ok" > "$d/$s"; chmod +x "$d/$s"; done
    (( use_git )) || return 0
    git -C "$d" init -q || { echo "FAIL: git init $d"; exit 1; }
    th_require_fixture_repo "$d" "census fixture"
    if (( commit_runner )); then git -C "$d" add -A
    else git -C "$d" add -- "$@"; fi
    git -C "$d" -c user.email=fixture@example.invalid -c user.name=fixture commit -qm fixture \
        || { echo "FAIL: fixture commit in $d"; exit 1; }
}
SUITES=(monitor/watcher/test-fx-ok.sh monitor/watcher/test-fx-other.sh monitor/cc-harness/test-fx-h.sh)
LOST=monitor/newdir/test-fx-lost.sh

echo '=== §B1: a tracked suite no root walks is NAMED, and the run is RED (#1620) ==='
_mkrepo "$WORK/r1" 1 1 "${SUITES[@]}" "$LOST"
OUT=$(rt bash "$WORK/r1/monitor/watcher/run-tests.sh" --filter fx-ok 2>&1); RC=$?
assert_rc       "B1 an unreachable tracked suite reddens the run (rc 1)" "$RC" "1"
assert_contains "B1 …and NAMES it"                                       "$OUT" "    UNREACHABLE: $LOST"
assert_contains "B1 …with the census numbers on one line"                "$OUT" "tracked=4 walked-by-a-root=3 excluded=0 UNREACHABLE=1; this run selected=1"
assert_contains "B1 …and a verdict marker (a red, not an abort)"          "$OUT" "=== run-tests: END rc=1 (COMPLETE and RED) ==="
# FILTERED OUT IS NOT UNREACHABLE: test-fx-other is in a root, just not selected.
assert_not_contains "B1 a suite filtered OUT by --filter is NOT named unreachable" "$OUT" "UNREACHABLE: monitor/watcher/test-fx-other.sh"
assert_contains     "B1 …and the line says the selection was a filter's"           "$OUT" "(by --filter fx-ok — a suite filtered OUT is walked, NOT unreachable)"
# monitor/cc-harness/ IS A ROOT: its suite is walked, listed, never unreachable.
assert_not_contains "B1 monitor/cc-harness/ is a root: its suite is not unreachable" "$OUT" "UNREACHABLE: monitor/cc-harness/test-fx-h.sh"
OUT=$(rt bash "$WORK/r1/monitor/watcher/run-tests.sh" --list 2>&1)
assert_contains "B1 …and --list selects it"                                       "$OUT" "test-fx-h.sh"
# band-verdict.sh reads the row-less red and points at the census.
rt bash "$WORK/r1/monitor/watcher/run-tests.sh" --filter fx-ok > "$WORK/b1.log" 2>&1
OUT=$(bash "$_test_dir/band-verdict.sh" "$WORK/b1.log" 2>&1); RC=$?
assert_rc       "B1 band-verdict reads the census red as a VERDICT, red (rc 1)" "$RC" "1"
assert_contains "B1 …and its sentence names the census as a row-less red"       "$OUT" "UNREACHABLE-SUITE (1 tracked suite(s) no root walks)"

echo '=== §B2: negative controls — the census is empty, or NOT TAKEN and said so ==='
_mkrepo "$WORK/r2" 1 1 "${SUITES[@]}"
OUT=$(rt bash "$WORK/r2/monitor/watcher/run-tests.sh" --filter fx-ok 2>&1); RC=$?
assert_rc       "B2 MUST-NOT-FLIP: every tracked suite under a root -> green (rc 0)" "$RC" "0"
assert_contains "B2 MUST-NOT-FLIP: …and the census says zero, not nothing"           "$OUT" "tracked=3 walked-by-a-root=3 excluded=0 UNREACHABLE=0"
# Explicit paths walk no root: the census is not taken, and says so.
OUT=$(rt bash "$WORK/r1/monitor/watcher/run-tests.sh" "$WORK/r1/monitor/watcher/test-fx-ok.sh" 2>&1); RC=$?
assert_rc       "B2 explicit paths: no root was walked, so no census red (rc 0)" "$RC" "0"
assert_contains "B2 …and the line says NOT TAKEN and why"                        "$OUT" "suite census (#1620): NOT TAKEN — explicit paths were given"
# Not a git checkout: there is no tracked set.
_mkrepo "$WORK/r3" 1 0 "${SUITES[@]}" "$LOST"
OUT=$(rt bash "$WORK/r3/monitor/watcher/run-tests.sh" --filter fx-ok 2>&1); RC=$?
assert_rc       "B2 a non-git tree: rc 0 (nothing tracked to be unreachable from)" "$RC" "0"
assert_contains "B2 …and the census is NOT TAKEN, named"                           "$OUT" "suite census (#1620): NOT TAKEN — no tracked set to compare against"
# POSITIVE CONTROL: a repo in which the RUNNER is untracked is not "this tree";
# its list would say "0 unreachable" about the wrong population.
_mkrepo "$WORK/r4" 0 1 "${SUITES[@]}" "$LOST"
OUT=$(rt bash "$WORK/r4/monitor/watcher/run-tests.sh" --filter fx-ok 2>&1); RC=$?
assert_rc       "B2 runner untracked: the census refuses to vouch (rc 0, no red)" "$RC" "0"
assert_contains "B2 …and says why"                                               "$OUT" "this runner is not in the tracked list"

echo '=== §B3: a deliberately unwalked file is DECLARED, visibly, and every row is re-checked (#1620) ==='
# The skeptic's case: a STAGED stub under monitor/watcher/fixtures/ (a directory
# that already holds stubs) reddened every root-walking run, rc 1, with no way
# to say "this is not a suite". One fixture repo, the manifest rewritten per case.
FX=monitor/watcher/fixtures/test-fixture.sh
MF=monitor/watcher/census-exclusions.manifest
_mkrepo "$WORK/r5" 1 1 "${SUITES[@]}"
mkdir -p "$WORK/r5/monitor/watcher/fixtures"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/r5/$FX"
git -C "$WORK/r5" add -- "$FX" || { echo "FAIL: staging $FX"; exit 1; }
R5="$WORK/r5/monitor/watcher/run-tests.sh"
_r5() { OUT=$(rt bash "$R5" --filter fx-ok 2>&1); RC=$?; }
# MUST-NOT-FLIP: FAIL-CLOSED IS KEPT. No manifest, so no exclusion: the staged
# stub is unreachable and the run is red, exactly as before the mechanism.
_r5
assert_rc       "B3 MUST-NOT-FLIP: no manifest -> the staged stub still reddens the run (rc 1)" "$RC" "1"
assert_contains "B3 MUST-NOT-FLIP: …named UNREACHABLE"                                         "$OUT" "    UNREACHABLE: $FX"
assert_contains "B3 MUST-NOT-FLIP: …and an absent manifest is zero exclusions"                 "$OUT" "tracked=4 walked-by-a-root=3 excluded=0 UNREACHABLE=1"
# WITH A ROW: green, and the exclusion is on the census line and printed.
printf '# header\n\n%s | stub executed by test-fx-ok.sh, never a suite\n' "$FX" > "$WORK/r5/$MF"
git -C "$WORK/r5" add -- "$MF" || { echo "FAIL: staging $MF"; exit 1; }
_r5
assert_rc           "B3 a declared exclusion turns the stub's red green (rc 0)"   "$RC" "0"
assert_contains     "B3 …and the census line COUNTS it"                          "$OUT" "tracked=4 walked-by-a-root=3 excluded=1 UNREACHABLE=0; this run selected=1"
assert_contains     "B3 …and PRINTS the path with its reason"                     "$OUT" "    EXCLUDED: $FX — stub executed by test-fx-ok.sh, never a suite"
assert_not_contains "B3 …and it is no longer named unreachable"                   "$OUT" "UNREACHABLE: $FX"
# A REASONLESS ROW IS REFUSED: not applied, so the stub stays unreachable too.
printf '%s |   \n' "$FX" > "$WORK/r5/$MF"
_r5
assert_rc       "B3 a reasonless row is refused: red (rc 1)"            "$RC" "1"
assert_contains "B3 …named with its manifest line"                     "$OUT" "EXCLUSION REFUSED (manifest line 1): $FX has NO REASON"
assert_contains "B3 …and NOT applied: the stub is still unreachable"   "$OUT" "    UNREACHABLE: $FX"
# A row with no separator, and a duplicate row, are refused the same way.
printf '%s\n%s|stub\n%s|again\n' "$FX" "$FX" "$FX" > "$WORK/r5/$MF"
_r5
assert_rc       "B3 a malformed/duplicate manifest is red (rc 1)"      "$RC" "1"
assert_contains "B3 …a row with no | is refused"                        "$OUT" "EXCLUSION REFUSED (manifest line 1): no \`|\`"
assert_contains "B3 …a second row for one path is refused"              "$OUT" "EXCLUSION REFUSED (manifest line 3): $FX already excluded at line 2"
# STALE: a row naming a path that is not a tracked test-*.sh, and a row naming
# a WALKED suite — both describe a tree that is not this one. The live row
# beside them still applies, so the stale rows are the ONLY reason for the red.
printf '%s|stub\nmonitor/watcher/fixtures/test-gone.sh|was a stub\nmonitor/watcher/test-fx-ok.sh|walked anyway\n' "$FX" > "$WORK/r5/$MF"
_r5
assert_rc           "B3 a stale row is red (rc 1)"                                   "$RC" "1"
assert_contains     "B3 …a path no longer tracked is flagged STALE"                  "$OUT" "STALE EXCLUSION (manifest line 2): monitor/watcher/fixtures/test-gone.sh is not a tracked test-*.sh"
assert_contains     "B3 …a row naming a WALKED suite is flagged STALE"               "$OUT" "STALE EXCLUSION (manifest line 3): monitor/watcher/test-fx-ok.sh is WALKED by a root"
assert_not_contains "B3 MUST-NOT-FLIP: …while the live row still applies"           "$OUT" "UNREACHABLE: $FX"
assert_contains     "B3 …and the run still reaches a verdict marker"                 "$OUT" "=== run-tests: END rc=1 (COMPLETE and RED) ==="
# An UNTRACKED manifest would exclude here and not on CI: refused whole.
_mkrepo "$WORK/r6" 1 1 "${SUITES[@]}" "$FX"
printf '%s|stub executed by a suite\n' "$FX" > "$WORK/r6/$MF"
OUT=$(rt bash "$WORK/r6/monitor/watcher/run-tests.sh" --filter fx-ok 2>&1); RC=$?
assert_rc       "B3 an UNTRACKED manifest is refused: red (rc 1)"  "$RC" "1"
assert_contains "B3 …and says why: NOT TRACKED, absent on CI"      "$OUT" "is NOT TRACKED — its rows would not exist on CI"
assert_contains "B3 …and applies no row"                           "$OUT" "    UNREACHABLE: $FX"

EXPECTED=79
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
