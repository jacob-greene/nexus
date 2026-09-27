#!/usr/bin/env bash
# The index's blind spot, NAMED where it can be. (your-org/nexus-code#1301 item 1)
#
# Run: bash monitor/watcher/test-guards-for-diff-sweepers.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS FILE EXISTS. `ng guards-for-diff` prints its blind spot as a count —
# "N of M tracked test suites do not declare a population" — and a suite that
# declares nothing appears in NEITHER `SELECTED` nor `CONSIDERED AND EXCLUDED`,
# so its silence is indistinguishable from a considered exclusion. On
# 2026-09-05 that hid the only guard with something to say about a change.
# `#1301` asked for the suites to be NAMED per diff and recorded the obstacle:
# readership is not derivable without a declaration, and "does the suite mention
# the changed path?" fails on the motivating case — a lint that enumerates by
# shebang names no path.
#
# That case is what the predicate keys on. A suite that names no path reads your
# diff because it SWEEPS the tree; sweeping is visible in its own CODE lines. So
# `guards-for-diff.sh` now names every UNDECLARED suite whose code carries a
# sweep construct — a LOWER bound on the class and an UPPER bound per member,
# both stated in the output. This suite pins the predicate's five edges:
#
#   an undeclared sweeper                        NAMED
#   a sweep construct in a COMMENT only          not named  (description != thing)
#   `ls-files --error-unmatch` (one named path)  not named  (existence != sweep)
#   a DECLARING suite that also sweeps           not named  (it is already visible)
#   a `find … -name '*'` over a FIXTURE dir      not named  (the arm was measured
#                                                at 36 hits, 13 of 13 read being
#                                                fixture finds, and dropped)
#
# It deliberately does NOT live in test-guards-for-diff.sh: that suite is the
# longest pole in the band (900 s+ on a quiet 12-core box), and these cases need
# three index-only calls over an eight-suite fixture list.
#
# §4-§5 ARE your-org/nexus-code#1615, here for the same reason — seconds, not
# the 900 s pole. `test-claude-md-block-coverage.sh --population` cost 136 s
# cold / 17 s warm against the index's 180 s per-probe bound, so the index
# REFUSED intermittently on an idle board. Measured cause: git 2.17.1's
# `grep -I` LOADS each untracked file WHOLE before its NUL sniff (strace: 5.533
# GB read of one 5.54 GB `.h5ad`), so the probe read all 44.9 GB of the
# primary clone's untracked `artifacts/` per call; the fix pre-sniffs 8000
# bytes and reads 0.233 GB for the byte-identical answer. §4 pins that the
# probe no longer reads such a file AND that the answer did not move; §5 pins
# that the index says WHICH kind of refusal it is when a probe does not answer.

set -uo pipefail
_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_test_dir/../.." && pwd)"
INDEX="$REPO_ROOT/monitor/guards-for-diff.sh"

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    # §4 RUNS the block-coverage probe, so its bytes can change this verdict.
    printf '%s\n' "monitor/guards-for-diff.sh" "monitor/watcher/test-guards-for-diff-sweepers.sh" \
        "monitor/watcher/test-claude-md-block-coverage.sh"
}
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=35   # counted BEFORE the census assertion itself

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gfdsw-$$-XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── fixture suites, handed to the index by absolute path via --suites-from ──
# The declaring fixtures source a COPY of the protocol library placed under
# $WORK/monitor/: the library derives its repository root from ITS OWN location
# and adds ITSELF to every declared population, so a copy makes $WORK a
# self-consistent root. The fixtures live in $WORK and NOT in the checkout on
# purpose — planting `test-*.sh` files into a live tree is how one suite reddens
# another that is enumerating it at that moment (your-org/nexus-code#1511).
mkdir -p "$WORK/monitor" && cp "$REPO_ROOT/monitor/_guard_population.sh" "$WORK/monitor/" \
    || { echo "cannot stage the protocol library" >&2; exit 2; }
mk() { cat > "$WORK/$1"; }
mk fx-declares.sh <<EOF
#!/usr/bin/env bash
. "$WORK/monitor/_guard_population.sh"
gp_population() { printf '%s\n' "CLAUDE.md"; }
gp_handle "\$@"
exit 0
EOF
mk fx-declares-and-sweeps.sh <<EOF
#!/usr/bin/env bash
. "$WORK/monitor/_guard_population.sh"
gp_population() { printf '%s\n' "CLAUDE.md"; }
gp_handle "\$@"
git ls-files -- '*.sh' | wc -l
EOF
mk fx-sweeper.sh <<'EOF'
#!/usr/bin/env bash
# an undeclared lint over every tracked shell file
while IFS= read -r f; do :; done < <(git ls-files -- '*.sh')
EOF
mk fx-sweeper-shf.sh <<'EOF'
#!/usr/bin/env bash
for f in monitor/*; do shf_is_shell "$f" || continue; done
EOF
mk fx-comment-only.sh <<'EOF'
#!/usr/bin/env bash
# this suite used to run `git ls-files -- '*.sh'` and shf_is_shell; it no longer does
echo "ALL TESTS PASSED (1 assertions)"
EOF
mk fx-error-unmatch.sh <<'EOF'
#!/usr/bin/env bash
git ls-files --error-unmatch monitor/ng >/dev/null 2>&1 && echo tracked
EOF
mk fx-find-in-fixture.sh <<'EOF'
#!/usr/bin/env bash
# a `find` over the suite's OWN scratch dir — the shape 36 real suites have
n=$(find "$WORK" -maxdepth 1 -name '*.log' | wc -l)
EOF
mk fx-plain.sh <<'EOF'
#!/usr/bin/env bash
echo "ALL TESTS PASSED (1 assertions)"
EOF
printf '%s\n' "$WORK"/fx-*.sh > "$WORK/suites"
# The protocol checks that every declared path EXISTS under its root.
: > "$WORK/CLAUDE.md"

run_index() {   # <changed-file> -> OUT, RC   (index only: no --run)
    printf '%s\n' "$1" > "$WORK/changed"
    OUT=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed" --suites-from "$WORK/suites" 2>&1)
    RC=$?
}
named() { grep -E "^        .*/$1\$" <<<"$OUT" | grep -c .; }

echo '=== §1 a diff a declaring guard READS (exit 0): the sweepers are named beside the count ==='
run_index "CLAUDE.md"
assert_eq       "§1 rc 0 — a declaring guard reads the diff" "$RC" "0"
assert_contains "§1 the aggregate count line is unchanged" "$OUT" "6 of 8 tracked test suites do not declare a population"
assert_contains "§1 the sweepers are counted as AT LEAST" "$OUT" "AT LEAST 2 of those undeclared suites SWEEP THE TREE"
assert_eq       "§1 an undeclared git-ls-files sweeper is NAMED" "$(named fx-sweeper.sh)" "1"
assert_eq       "§1 an undeclared shf_is_shell sweeper is NAMED" "$(named fx-sweeper-shf.sh)" "1"
assert_eq       "§1 a sweep construct in a COMMENT only is NOT named" "$(named fx-comment-only.sh)" "0"
assert_eq       "§1 \`ls-files --error-unmatch\` (one named path) is NOT named" "$(named fx-error-unmatch.sh)" "0"
assert_eq       "§1 a suite with no sweep is NOT named" "$(named fx-plain.sh)" "0"
assert_eq       "§1 a \`find\` inside the suite's own fixture dir is NOT named (the dropped arm stays dropped)" "$(named fx-find-in-fixture.sh)" "0"
assert_eq       "§1 a DECLARING suite that also sweeps is NOT named — it is already visible" "$(named fx-declares-and-sweeps.sh)" "0"
assert_contains "§1 the error direction is stated in the output itself" "$OUT" "A LOWER BOUND on the class"

echo '=== §2 a diff NO declaring guard reads (exit 3): the same names, where the silence is total ==='
run_index "no/such/changed-file.txt"
assert_eq       "§2 rc 3 — no registered guard reads the diff" "$RC" "3"
assert_eq       "§2 the undeclared sweeper is named at exit 3 too" "$(named fx-sweeper.sh)" "1"

echo '=== §3 nothing to name -> nothing printed (no empty heading) ==='
printf '%s\n' "$WORK/fx-declares.sh" "$WORK/fx-plain.sh" > "$WORK/suites"
run_index "CLAUDE.md"
assert_not_contains "§3 with no undeclared sweeper the block is absent" "$OUT" "SWEEP THE TREE"
assert_contains     "§3 …while the aggregate line still prints" "$OUT" "1 of 2 tracked test suites do not declare a population"

echo '=== §4 block-coverage --population does not READ an untracked binary, and its answer is unchanged (#1615) ==='
# A fixture repository with its own CLAUDE.md, one marker, and a reader of each
# kind git's `-I` rule distinguishes. The subject is COPIED in: the suite
# derives its root from its own location, and a fixture is the only root where
# a planted 1 TiB file is not somebody else's data.
BC="$WORK/bc"
mkdir -p "$BC/monitor/watcher" || { echo "cannot stage the block-coverage fixture" >&2; exit 2; }
cp "$REPO_ROOT/monitor/_guard_population.sh" "$BC/monitor/" \
    && cp "$REPO_ROOT/monitor/watcher/test-claude-md-block-coverage.sh" "$BC/monitor/watcher/" \
    || { echo "cannot copy the block-coverage subject" >&2; exit 2; }
printf '# fx\n<!-- BEGIN FX-MARK -->\n```\ntrue\n```\n<!-- END FX-MARK -->\n' > "$BC/CLAUDE.md"
printf 'extract FX-MARK\n' > "$BC/reader-tracked.sh"
git -C "$BC" init -q && th_require_fixture_repo "$BC"
git -C "$BC" add CLAUDE.md reader-tracked.sh monitor \
    && git -C "$BC" -c user.email=fx@fx -c user.name=fx commit -qm fx \
    || { echo "cannot commit the block-coverage fixture" >&2; exit 2; }
printf 'extract FX-MARK\n' > "$BC/reader-untracked.sh"          # #1054: an UNSTAGED reader counts
printf '\0extract FX-MARK\n' > "$BC/nul-head.bin"               # git -I skips it: NUL in the first 8000 bytes
{ printf 'extract FX-MARK\n'; head -c 7984 /dev/zero | tr '\0' 'a'; printf '\0'; } > "$BC/nul-at-8001.txt"
printf '\0extract FX-MARK\n' > "$BC/forced-text.dat"            # NUL head, but a named diff driver says TEXT
printf '\0extract FX-MARK\n' > "$BC/set-diff.dat"               # NUL head, but a bare `diff` (SET) says TEXT
# `diff` SET is userdiff's driver_true, binary = 0: FORCED TEXT, like the named
# driver above but with no config at all. The prefilter once withheld it as if
# `set` meant "sniff" (your-org/nexus-code#1615, skeptic item 8 on #1626).
printf 'forced-text.dat diff=fxtext\nset-diff.dat diff\n' > "$BC/.gitattributes"
git -C "$BC" config diff.fxtext.binary false
# 1 TiB, SPARSE: costs no disk, and git 2.17.1 would try to LOAD it whole.
# Under the `ulimit -v` below that allocation fails deterministically — on any
# overcommit mode, so the pre-fix probe can never be the thing that pages a
# shared node — and git dies; the pre-fix pipeline's `2>/dev/null … || true`
# then hands back whatever git had printed before dying, at rc 0. In
# production the same load is the 136 s read, not a death; the death is how a
# fixture makes "the probe loaded it" OBSERVABLE in milliseconds.
#
# WHAT GIT HAD PRINTED IS A RACE unless pinned, and the first cut of this case
# SURVIVED its own mutation because of it: threaded `git grep` finished the
# readers on other threads before the fatal load. So `grep.threads 1`
# (sequential: tracked files, then untracked in path order) and a name that
# sorts BEFORE every untracked reader — the pre-fix walk now dies before it
# reaches any of them, every time.
git -C "$BC" config grep.threads 1
truncate -s 1T "$BC/0-huge.h5ad" 2>/dev/null
# BOTH halves, because the first cut asserted only "sparse" and a file that was
# never created passes that: under a `ulimit -f` (mutation-gate sets one)
# `truncate` fails, the plant is absent, and every case below goes green about
# a tree without the thing it tests. Measured — it is how this case first
# survived its own mutation.
assert_eq "§4 precondition: the planted file EXISTS at 1 TiB apparent size and is SPARSE" \
    "$(stat -c %s "$BC/0-huge.h5ad" 2>/dev/null):$(( $(du -k "$BC/0-huge.h5ad" 2>/dev/null | cut -f1) + 0 < 1024 ))" \
    "1099511627776:1"
[[ $(head -c 8000 "$BC/nul-at-8001.txt" | tr -dc '\0' | wc -c) == 0 && $(wc -c < "$BC/nul-at-8001.txt") == 8001 ]] \
    || { echo "fixture nul-at-8001.txt is not 8000 NUL-free bytes + a NUL" >&2; exit 2; }
_t0=$SECONDS
BC_OUT=$( ulimit -v 4194304; timeout 120 bash "$BC/monitor/watcher/test-claude-md-block-coverage.sh" --population 2>"$WORK/bc.err" ); BC_RC=$?
_bc_secs=$(( SECONDS - _t0 ))
bc_has() { grep -cxF -- "$1" <<<"$BC_OUT"; }
assert_eq "§4 the probe answers rc 0 with a 1 TiB untracked binary in the tree" "$BC_RC" "0"
assert_eq "§4 …inside 60 s (it reads 8000 bytes of the binary, not 1 TiB)" "$(( _bc_secs < 60 ))" "1"
assert_eq "§4 a TRACKED reader is in the population" "$(bc_has reader-tracked.sh)" "1"
assert_eq "§4 an UNTRACKED text reader is in the population (#1054 preserved)" "$(bc_has reader-untracked.sh)" "1"
assert_eq "§4 a NUL at byte 8001 is TEXT to git, so that file is IN the population" "$(bc_has nul-at-8001.txt)" "1"
assert_eq "§4 a NUL-headed file a named diff driver forces to TEXT is IN the population" "$(bc_has forced-text.dat)" "1"
assert_eq "§4 a NUL-headed file whose diff attribute is SET (forced text) is IN the population" "$(bc_has set-diff.dat)" "1"
assert_eq "§4 a NUL-headed untracked file is NOT in the population (git -I skipped it before too)" "$(bc_has nul-head.bin)" "0"
assert_eq "§4 the sparse binary is NOT in the population" "$(bc_has 0-huge.h5ad)" "0"
# EQUIVALENCE, derived independently: the historical single walk over the SAME
# tree with only the unloadable file moved aside. Keyed on the corpus (the
# population minus what gp_handle and the suite itself add), as sets.
mv "$BC/0-huge.h5ad" "$WORK/huge.h5ad.aside"
git -C "$BC" grep -I -l --untracked -F -e FX-MARK -- . 2>/dev/null \
    | grep -vxF -e CLAUDE.md -e monitor/watcher/test-claude-md-block-coverage.sh | sort -u > "$WORK/bc.ref"
grep -vxF -e CLAUDE.md -e monitor/watcher/test-claude-md-block-coverage.sh -e monitor/_guard_population.sh \
    <<<"$BC_OUT" | sort -u > "$WORK/bc.got"
assert_eq "§4 the reference walk found the 5 readers (a potency check on the comparison below)" \
    "$(grep -c . "$WORK/bc.ref")" "5"
assert_eq "§4 the corpus EQUALS the historical single-walk answer on the same tree" \
    "$(comm -3 "$WORK/bc.ref" "$WORK/bc.got" | tr '\n\t' '| ')" ""
rm -f "$WORK/huge.h5ad.aside"

echo '=== §5 a probe that does not answer: the refusal says WHICH kind (#1615) ==='
# rc 124 from the probe ITSELF, not a real 180 s wait — the proxy the index's
# own comment declares (a probe exiting 124 reads as a timeout), used here to
# keep the case at seconds.
mkdir -p "$WORK/p5"
for _rc in 124 3; do
    cat > "$WORK/p5/fx-probe-$_rc.sh" <<FXEOF
#!/usr/bin/env bash
gp_population() { :; }
[[ "\${1:-}" == --population ]] && { echo "probe says $_rc" >&2; exit $_rc; }
gp_handle "\$@"
FXEOF
done
printf '%s\n' "$WORK/p5/fx-probe-124.sh" > "$WORK/suites"
run_index "CLAUDE.md"
assert_eq           "§5 rc 124 probe: the index REFUSES (exit 2)" "$RC" "2"
assert_contains     "§5 rc 124 probe: the first line is unchanged (ng wrap-up quotes it)" "$OUT" "fx-probe-124.sh --population failed (rc 124)."
assert_contains     "§5 rc 124 probe: named a TIMEOUT, with the bound" "$OUT" "TIMEOUT, not a probe error: no answer within the 180 s per-probe bound"
assert_contains     "§5 rc 124 probe: says a retry may succeed" "$OUT" "RETRY MAY SUCCEED"
assert_not_contains "§5 rc 124 probe: NOT called a probe error" "$OUT" "PROBE ERROR"
printf '%s\n' "$WORK/p5/fx-probe-3.sh" > "$WORK/suites"
run_index "CLAUDE.md"
assert_eq           "§5 rc 3 probe: the index REFUSES (exit 2)" "$RC" "2"
assert_contains     "§5 rc 3 probe: named a PROBE ERROR" "$OUT" "PROBE ERROR, not a timeout: the probe itself exited 3"
assert_not_contains "§5 rc 3 probe: NOT called a timeout" "$OUT" "TIMEOUT"

# ASSERTION CENSUS — the exact-count guard (your-org/nexus-code#807).
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
