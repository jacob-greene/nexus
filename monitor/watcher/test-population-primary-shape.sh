#!/usr/bin/env bash
# test-population-primary-shape.sh — no guard's `--population` probe may depend
# on what sits under `work/` or `reports/` (your-org/nexus-code#1588, the guard
# `#1487` closed without).
#
# ---------------------------------------------------------------------------
# THE DEFECT
# ---------------------------------------------------------------------------
#
# Every suite in this repo runs in a CLONE, where `work/` holds one
# `.gitignore`. The selector (`monitor/guards-for-diff.sh`) also runs at
# wrap-up time in the PRIMARY nexus, where `work/` holds every analysis tree the
# operator has — 1,143 directories when `#1588` was measured. A probe that walks
# its repo root is therefore correct and fast in every tree it is ever TESTED
# in, and wrong and unbounded in the one tree where it is USED:
#
#   * `#1487` — `test-claude-md-block-coverage.sh` walked `-- .`. Fixed at that
#     call site, 2026-09-08.
#   * `#1588` — `tee-reopen-lint.sh` arrived ONE DAY LATER with the same walk
#     via `shf_find0 "$ROOT"`. In the primary its probe hit the selector's
#     180 s bound with zero lines, so `ng wrap-up`'s guards pre-flight REFUSED
#     on every primary-clone wrap-up for nine days, unnamed.
#
# Two occurrences, one fix each, no guard: the third was a matter of time. This
# suite is that guard. It is keyed on the TREE SHAPE, the axis the mechanism
# varies on, because no amount of re-running a probe in a clone can see it.
#
# ---------------------------------------------------------------------------
# THE INSTRUMENT IS THE INDEX ITSELF — deliberately not a copy of it
# ---------------------------------------------------------------------------
#
# The fixture is a copy of THIS working tree with a primary-shaped, IGNORED
# `work/` and `reports/` planted into it. The selector is then asked, inside
# that fixture, which guards read the PLANTED paths (`--changed-files`). On a
# correct tree the answer is exit 3, *no registered guard reads your diff*: a
# planted analysis file is nobody's population. A guard whose probe leaks into
# `work/` is SELECTED, by name.
#
# That reuses the selector's own declaring-suite enumeration and its own
# per-probe 180 s bound. A second implementation of "which suites declare"
# would drift, and then this suite would certify a list rather than the index.
#
# ---------------------------------------------------------------------------
# COVERAGE BOUNDARY — which direction each half errs in
# ---------------------------------------------------------------------------
#
#   ANSWER check (selection). Sees a probe whose OUTPUT contains a planted
#     path. BLIND to a probe that walks `work/` and then filters its output
#     (`… | grep '^monitor/'`): correct answer, unbounded cost — and cost was
#     `#1588`'s actual symptom. Errs toward PASSING such a probe.
#   TRAVERSAL tripwire (a PATH-front `find` that records any invocation whose
#     output names a planted path). Sees exactly the walk-then-filter shape the
#     answer check misses. BLIND to a walker that is not `find` resolved via
#     PATH: `grep -r`, `ls -R`, a `**` globstar, an absolute `/usr/bin/find`.
#     Errs toward PASSING those.
#
#   A walker that is both non-`find` AND output-filtered is seen by neither.
#   Stated rather than papered over; the controls below prove each half can go
#   red, and prove the tripwire catches what the answer check cannot.
#
# Run: bash monitor/watcher/test-population-primary-shape.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Cost is one selector pass
# (~2 min at load 30 on the reporting host; every probe runs once).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SELECTOR_REL=monitor/guards-for-diff.sh

# ---------------------------------------------------------------------------
# POPULATION DECLARATION. Above the first thing this suite prints: `gp_handle`
# EXITS when it handles the flag, and anything printed before it is read as a
# population row.
#
# The bytes this suite reads to reach its verdict are the selector, the shared
# enumerator whose walk was `#1588`, and EVERY declaring guard — it runs each of
# their probes, so an edit to any of them can change this verdict. The
# declaring set comes from the same two-token predicate the selector uses; it
# is restated here only for the DECLARATION, never for the verdict, which asks
# the selector. If the two drift this suite over- or under-SELECTS itself; it
# cannot mis-judge a probe.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    # Two batched `grep -lF` passes (argument order kept) instead of two greps
    # per suite — ~1,000 forks per probe (bundle-0923). Same predicate: a file
    # carrying BOTH tokens; `xargs` execs the grep BINARY, never a shell function.
    ( cd "$REPO_ROOT" && git ls-files -z -- ':(glob)**/test-*.sh' 2>/dev/null \
        | xargs -0 -r grep -lF -e 'gp_handle "$@"' -- 2>/dev/null \
        | tr '\n' '\0' | xargs -0 -r grep -lF -e 'gp_population()' -- 2>/dev/null )
    printf '%s\n' "$SELECTOR_REL" monitor/shell-files.sh
}
gp_handle "$@"

# This suite copies the working tree through git's index. A tree that is not
# its OWN repository root would make `git ls-files` answer about an ENCLOSING
# repository (your-org/nexus-code#1196) — decline rather than certify that.
#
# KEYED ON `kind`, NOT ON `verdict` — and the line is KEPT when the predicate
# exits 1. `repo-root.sh`'s `verdict=yes` means "owns its own .git", so a LINKED
# WORKTREE answers `verdict=no kind=linked-worktree` at rc 1. But a linked
# worktree IS its own top level, `git ls-files` there describes THAT tree, and
# it is exactly where a band is supposed to run (your-org/nexus-code#1586). The
# first cut read `verdict=yes` and discarded the line on rc 1, so this suite
# declined to run in the one place it most needs to — caught by running the
# selected guards from a detached worktree. Same two kinds `run-tests.sh`'s
# `_rt_tree_line` accepts.
_rr=$(bash "$REPO_ROOT/monitor/repo-root.sh" "$REPO_ROOT" 2>/dev/null) || true
_rr_kind=$(sed -n 's/^verdict=[^ ]* kind=\([^ ]*\).*/\1/p' <<<"$_rr")
case "$_rr_kind" in
    root|linked-worktree) ;;
    *) # DECLINED, exit 77 — not a pass (your-org/nexus-code#1145, #568 A6).
       echo "SKIP: REPO_ROOT is not the top of a git work tree (kind=${_rr_kind:-?}) — the fixture copy is built from git's file list and would describe ANOTHER repository"
       exit 77 ;;
esac

WORK=$(mktemp -d -t pps-XXXXXX)
TREE="$WORK/tree"
th_trap_exit 'rm -rf "$WORK"'

# How many analysis trees to plant. WE CHOSE 60, it is not a convention: the
# verdict is set membership, not timing, so the count only has to make the
# fixture unmistakably primary-SHAPED (many sibling trees, several file kinds
# each) while keeping the build to about a second. `#1588`'s reproduction used
# 400 to show the cost scaling (4.9 s -> 17.5 s); that number is evidence in
# the issue, not a requirement of this check.
N_PLANTED=60
PLANT_TAG=pps-planted

echo '=== build: a copy of THIS working tree, as its own repository ==='
mkdir -p "$TREE"
# Tracked + written-and-not-yet-committed, minus ignored: the working tree the
# probes would see, so an uncommitted edit to a probe is what gets tested.
# `--no-recursion` because a nested repository is listed as one `dir/` entry.
_copy_rc=0
( cd "$REPO_ROOT" \
  && git ls-files -z --cached --others --exclude-standard \
     | while IFS= read -r -d '' _f; do
           [[ -e "$_f" || -L "$_f" ]] && printf '%s\0' "$_f"
       done \
     | tar --null --no-recursion -T - -cf - ) | tar -xf - -C "$TREE" || _copy_rc=$?
_n_copied=$(find "$TREE" -type f | wc -l)
assert_eq "the working tree copied without error" "$_copy_rc" "0"
assert_eq "…and the copy is non-vacuous (got $_n_copied files)" "$(( _n_copied >= 500 ? 1 : 0 ))" "1"

git -C "$TREE" init -q >/dev/null 2>&1
th_require_fixture_repo "$TREE"
git -C "$TREE" add -A >/dev/null 2>&1
# `-c`, never the global config (your-org/nexus-code#1244); hooksPath pinned so
# an operator-global hook cannot run inside a fixture.
git -C "$TREE" -c user.name=pps-fixture -c user.email=pps-fixture@invalid \
    -c core.hooksPath=/dev/null commit -q -m 'primary-shape fixture' >/dev/null 2>&1
assert_eq "the fixture has a HEAD commit" \
    "$(git -C "$TREE" rev-parse --verify --quiet HEAD >/dev/null 2>&1; echo $?)" "0"

echo '=== plant: a primary-shaped, IGNORED work/ and reports/ ==='
: > "$WORK/planted.list"
for (( i = 1; i <= N_PLANTED; i++ )); do
    d="work/$PLANT_TAG-$i"
    mkdir -p "$TREE/$d/scripts" "$TREE/$d/monitor/watcher" "$TREE/$d/skills/x"
    printf '#!/usr/bin/env bash\necho hi | tee -a log\n' > "$TREE/$d/scripts/run.sh"
    printf '#!/usr/bin/env bash\necho t\n'               > "$TREE/$d/monitor/watcher/test-$PLANT_TAG.sh"
    printf '#!/bin/bash\necho tool\n'                    > "$TREE/$d/tool"
    printf '# planted\n'                                 > "$TREE/$d/CLAUDE.md"
    printf '# skill\n'                                   > "$TREE/$d/skills/x/SKILL.md"
    printf 'print(1)\n'                                  > "$TREE/$d/scripts/a.py"
    printf '%s\n' "$d/scripts/run.sh" "$d/monitor/watcher/test-$PLANT_TAG.sh" "$d/tool" \
                  "$d/CLAUDE.md" "$d/skills/x/SKILL.md" "$d/scripts/a.py" >> "$WORK/planted.list"
    printf '# report %s\n' "$i" > "$TREE/reports/$PLANT_TAG-$i.md"
    printf '%s\n' "reports/$PLANT_TAG-$i.md" >> "$WORK/planted.list"
done
# THE SHAPE PRECONDITION. The fixture is primary-shaped only if git IGNORES the
# plant, exactly as the primary's `work/.gitignore` does. If this were 0 for a
# different reason — the plant landed nowhere — everything below would pass
# vacuously, so the plant's existence is asserted beside it.
assert_eq "the plant exists (planted $(wc -l < "$WORK/planted.list") paths)" \
    "$(( $(wc -l < "$WORK/planted.list") == N_PLANTED * 7 ? 1 : 0 ))" "1"
assert_eq "…and git ignores ALL of it, as the primary's work/.gitignore does" \
    "$(git -C "$TREE" status --porcelain | grep -c . || true)" "0"

# ---------------------------------------------------------------------------
# THE TRAVERSAL TRIPWIRE: a PATH-front `find` that runs the real one unchanged
# and records the invocation when its OUTPUT names a planted path. Output is
# buffered to a file so NUL-separated streams pass through byte-exact; a
# population is finite, so nothing here relies on streaming.
# ---------------------------------------------------------------------------
REAL_FIND=$(type -P find) || th_abort "no find on PATH"
mkdir -p "$WORK/shim"
TRIP_LOG="$WORK/find-trip.log"; : > "$TRIP_LOG"
cat > "$WORK/shim/find" <<SHIM
#!/usr/bin/env bash
_o=\$(mktemp "$WORK/find-out.XXXXXX") || exec "$REAL_FIND" "\$@"
"$REAL_FIND" "\$@" > "\$_o"; _rc=\$?
if LC_ALL=C command grep -aqF -- "$PLANT_TAG" "\$_o"; then
    printf 'find\tcwd=%s\targv=%s\n' "\$PWD" "\$*" >> "$TRIP_LOG"
fi
cat "\$_o"; rm -f "\$_o"
exit \$_rc
SHIM
chmod +x "$WORK/shim/find"

# _select <suites-from|-> -> runs the fixture's selector over the PLANTED
# paths. Sets SEL_RC, SEL_OUT (selected guard commands), SEL_ERR (its stderr).
# rc is read on the very next line (your-org/nexus-code#1202), and the bound is
# the helper's, scaled — an outer bound that fires first would replace the
# selector's own well-typed refusal with a wrapper status (#1248), so it sits
# far above one full pass.
_select() {
    local -a extra=()
    [[ "$1" == - ]] || extra=( --suites-from "$1" )
    : > "$TRIP_LOG"
    SEL_OUT=$(cd "$TREE" && env -u NEXUS_ROOT -u NEXUS_LOCALS PATH="$WORK/shim:$PATH" \
        timeout -k 15 "$(th_deadline 1200)" bash "$TREE/$SELECTOR_REL" --quiet \
            --changed-files "$WORK/planted.list" "${extra[@]}" 2>"$WORK/sel.err" </dev/null)
    SEL_RC=$?
    SEL_ERR=$(cat "$WORK/sel.err")
}

echo '=== CONTROLS: each half of this check can go RED, and only when it should ==='
# Three planted guards, run through the SAME selector call as the real ones.
_guard() {   # <name> <population-body>
    cat > "$TREE/monitor/watcher/$1" <<GUARD
#!/usr/bin/env bash
_d=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=\$(cd "\$_d/../.." && pwd)
. "\$_d/../_guard_population.sh"
gp_population() {
$2
}
gp_handle "\$@"
echo "ALL TESTS PASSED"
GUARD
    printf 'monitor/watcher/%s\n' "$1" >> "$WORK/controls.list"
}
: > "$WORK/controls.list"
# (1) the #1588 shape: walks the root, prints what it finds.
_guard test-pps-ctl-naive.sh      '    find "$REPO_ROOT" -name "*.sh" -type f | sed "s|^$REPO_ROOT/||"'
# (2) walk-then-filter: a CORRECT answer at an unbounded cost.
_guard test-pps-ctl-postfilter.sh '    find "$REPO_ROOT" -name "*.sh" -type f | sed "s|^$REPO_ROOT/||" | command grep "^monitor/"'
# (3) the right form.
_guard test-pps-ctl-git.sh        '    git -C "$REPO_ROOT" ls-files -- "monitor/*.sh"'

_select "$WORK/controls.list"
assert_eq       "control: a selection over the three planted guards is rc 0 (one of them reads the plant)" "$SEL_RC" "0"
assert_contains "control (1) naive walker: SELECTED — the answer check can go red"          "$SEL_OUT" "test-pps-ctl-naive.sh"
assert_not_contains "control (2) walk-then-filter: NOT selected — the answer check is BLIND to it" "$SEL_OUT" "test-pps-ctl-postfilter.sh"
assert_not_contains "control (3) git enumerator: not selected"                              "$SEL_OUT" "test-pps-ctl-git.sh"
_trip=$(cat "$TRIP_LOG")
assert_contains "control (1) naive walker: the traversal tripwire fired, naming the walk's root" "$_trip" "argv=$TREE -name"
assert_eq       "control (2) walk-then-filter: the tripwire CATCHES what selection missed (2 walkers tripped)" \
    "$(grep -c . "$TRIP_LOG" || true)" "2"
# Remove the controls so the real pass below is about the real guards only.
while IFS= read -r _c; do rm -f "$TREE/$_c"; done < "$WORK/controls.list"

echo '=== THE CHECK: every real declaring guard, in the primary-shaped tree ==='
_select -
if [[ "$SEL_RC" != 3 ]]; then
    printf '  selector rc=%s in the primary-shaped fixture. Guards that read a PLANTED work/ or reports/ path:\n' "$SEL_RC" >&2
    printf '%s\n' "$SEL_OUT" | sed 's/^/      /' >&2
    printf '  selector stderr (a REFUSED line names a probe that errored or hit its 180 s bound):\n' >&2
    printf '%s\n' "$SEL_ERR" | sed -n '1,12s/^/      /p' >&2
    printf '  FIX: enumerate the repository`s own files (`git ls-files`, or `shf_find0`, which does), never a walk of the repo root (your-org/nexus-code#1588, #1487).\n' >&2
fi
assert_eq "no declaring guard's population contains a planted work/ or reports/ path (selector exit 3: nothing reads the plant)" \
    "$SEL_RC" "3"
assert_eq "…and it selected nothing" "$(printf '%s' "$SEL_OUT" | grep -c . || true)" "0"
if [[ -s "$TRIP_LOG" ]]; then
    printf '  a probe WALKED the plant (answer may be correct; the cost is unbounded in a primary):\n' >&2
    sed 's/^/      /' "$TRIP_LOG" >&2
fi
assert_eq "no probe's \`find\` traversed work/ or reports/ (the walk-then-filter shape)" \
    "$(grep -c . "$TRIP_LOG" || true)" "0"

# NON-VACUITY of the real pass. Exit 3 is also what a selector that probed
# NOTHING would say, so the probed count is read from its own report and held
# to a floor well under the live count (94 declaring at 17f1f926).
_full=$(cd "$TREE" && env -u NEXUS_ROOT -u NEXUS_LOCALS bash "$TREE/$SELECTOR_REL" \
    --changed-files "$WORK/planted.list" --suites-from <(printf 'monitor/watcher/test-tee-reopen-lint.sh\n') 2>&1 </dev/null)
assert_contains "the historical offender was actually PROBED in the fixture, and excluded" \
    "$_full" "test-tee-reopen-lint.sh"
_n_decl=$(gp_population | grep -c 'test-.*\.sh$' || true)
assert_eq "the declaring set the real pass covered clears a floor (got $_n_decl)" \
    "$(( _n_decl >= 50 ? 1 : 0 ))" "1"

EXPECTED_ASSERTIONS=16
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
assert_eq "assertion TOTAL matches the EXPECTED total — no assertion silently dropped or added" \
    "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
