#!/usr/bin/env bash
# THE RUN-LOG HEADER NAMES THE TREE IT IS A CLAIM ABOUT.
# (your-org/nexus-code#1465)
#
# WHY THIS FILE EXISTS. `run-tests.sh`'s header recorded nproc, the test count
# and the interpreter, and NOT the ref — so a suite log carried to another
# checkout silently described a different tree, with nothing in the log to
# say so. A suite result is a property of a tree (CLAUDE.md, count-provenance),
# and the runner now prints one line:
#
#     === tree: ref=<40-hex> branch=<b> dirty=<yes|no> worktree=<linked|main> ===
#
# THE ASSERTION THAT MATTERS IS THE NEGATIVE ONE. `git -C <dir>` on a directory
# that is not its own repository WALKS UP and answers about the enclosing one at
# rc 0 (#1196) — and a runner copied into an un-versioned fixture under some
# checkout is exactly that shape. So beyond "the sha is the fixture's HEAD",
# this suite plants the runner BELOW a repository root and in a plain directory
# and requires `ref=UNKNOWN (…)` with the enclosing sha ABSENT. A header that
# printed a plausible, borrowed sha would pass every positive check here and be
# the defect the line exists to prevent.
#
# THE RUNNER IS COPIED INTO EACH FIXTURE, as test-helper-honesty.sh does: it
# derives its repo root from its own location (`_RT_REPO_ROOT`), never from
# `$PWD`, so a copy inside the fixture reports the FIXTURE's tree. The runner's
# state dir is pinned under the fixture (NEXUS_TEST_STATE_DIR) so nothing lands
# in $HOME.
#
# Run: bash monitor/watcher/test-run-tests-header-ref.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
RUNNER="$_test_dir/run-tests.sh"
RR="$REPO_ROOT/monitor/repo-root.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$RUNNER"; }
gp_handle "$@"

[[ -r "$RUNNER" ]] || { echo "missing runner: $RUNNER" >&2; exit 2; }
[[ -r "$RR" ]]     || { echo "missing predicate: $RR" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is required for this suite" >&2; exit 2; }

WORK=$(mktemp -d) || { echo "FAIL: mktemp for the fixture"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cwd" "$WORK/state"
export NEXUS_TEST_STATE_DIR="$WORK/state"
export NEXUS_TMUX_SOCKET_CHECK=off

# Fixture identity is passed PER COMMAND (`-c`), never written to any config
# file: the operator's global git config is writable and nothing validates a
# commit's author (your-org/nexus-code#1244).
fgit() { env -u GIT_DIR -u GIT_WORK_TREE git -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }

# mk_tree <dir> — a minimal monitor/ layout: the real runner, the real
# repo-root predicate beside it (the runner looks for `../repo-root.sh`), and
# one trivially passing suite for it to dispatch.
mk_tree() {
    mkdir -p "$1/monitor/watcher" || return 1
    cp "$RUNNER" "$1/monitor/watcher/run-tests.sh" || return 1
    cp "$RR" "$1/monitor/repo-root.sh" || return 1
    cat >"$1/monitor/watcher/test-trivial.sh" <<'T'
#!/usr/bin/env bash
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
exit 0
T
    chmod +x "$1/monitor/watcher/test-trivial.sh"
}

# tree_line <dir> — run the copied runner over its trivial suite from a
# DEDICATED cwd (never the repo, never the fixture: the line must come from
# the runner's own root, not from where it was invoked) and return the header
# line in TREE_LINE, with RUN_RC and RUN_OUT beside it. Globals, not a `$(…)`
# return: a command substitution runs in a subshell, and the rc read there
# would never reach the caller.
tree_line() {
    RUN_OUT=$( cd "$WORK/cwd" && bash "$1/monitor/watcher/run-tests.sh" --jobs 1 \
                 "$1/monitor/watcher/test-trivial.sh" 2>&1 )
    RUN_RC=$?
    TREE_LINE=$(grep -aE '^=== tree: ' <<<"$RUN_OUT")
}
# _lines_matching <literal> <text> — matching LINES of a literal, 0 on none.
_lines_matching() { grep -acF -- "$1" <<<"$2"; }

# ── A. a clean fixture repository at its own root ───────────────────────
REPO="$WORK/repo"
mkdir -p "$REPO" && fgit init -q "$REPO" && mk_tree "$REPO" \
    && fgit -C "$REPO" add -A && fgit -C "$REPO" commit -q -m 'fixture' \
    || { echo "FAIL: could not build the fixture repository" >&2; exit 1; }
th_require_fixture_repo "$REPO"

HEAD_SHA=$(fgit -C "$REPO" rev-parse HEAD)
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] && _th_pass || _th_fail
printf '  %s: CONTROL: the fixture HEAD is a full 40-hex sha (%s)\n' \
    "$( [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] && echo PASS || echo FAIL )" "$HEAD_SHA"
HEAD_BRANCH=$(fgit -C "$REPO" rev-parse --abbrev-ref HEAD)

tree_line "$REPO"; line=$TREE_LINE; rc=$RUN_RC
assert_eq "clean root: the runner itself ran green (rc)" "$rc" "0"
assert_eq "clean root: exactly ONE tree line in the header" \
    "$(_lines_matching '=== tree: ' "$RUN_OUT")" "1"
assert_contains "clean root: the line carries the fixture's FULL HEAD sha" \
    "$line" "ref=$HEAD_SHA"
assert_contains "clean root: branch is the checked-out branch name" \
    "$line" "branch=$HEAD_BRANCH"
assert_contains "clean root: dirty=no on a clean tree"     "$line" "dirty=no"
assert_contains "clean root: worktree=main in the main checkout" "$line" "worktree=main"

# ── B. an UNTRACKED file makes it dirty ─────────────────────────────────
# `--untracked-files=normal` is the whole point: a brand-new suite that has not
# been `git add`ed is in the population the runner just ran and in no commit.
: >"$REPO/monitor/watcher/test-untracked-new-suite.sh"
tree_line "$REPO"; line=$TREE_LINE
assert_contains "untracked file: dirty=yes"                    "$line" "dirty=yes"
assert_contains "untracked file: …and the ref is unchanged"    "$line" "ref=$HEAD_SHA"
rm -f "$REPO/monitor/watcher/test-untracked-new-suite.sh"

# ── C. detached HEAD ─────────────────────────────────────────────────────
fgit -C "$REPO" checkout -q --detach || { echo "FAIL: cannot detach" >&2; exit 1; }
tree_line "$REPO"; line=$TREE_LINE
assert_contains "detached HEAD: branch=detached"               "$line" "branch=detached"
assert_contains "detached HEAD: the ref is still the sha"      "$line" "ref=$HEAD_SHA"

# ── D. a LINKED worktree ─────────────────────────────────────────────────
# NO `-q`: absent at git 2.17.1, the default on this host (CLAUDE.md).
WT="$WORK/wt"
fgit -C "$REPO" worktree add "$WT" -b fixture-wt >/dev/null 2>&1 \
    || { echo "FAIL: git worktree add" >&2; exit 1; }
# The runner and the predicate are TRACKED, so the worktree already holds them.
tree_line "$WT"; line=$TREE_LINE
assert_contains "linked worktree: worktree=linked"             "$line" "worktree=linked"
assert_contains "linked worktree: branch is the worktree's branch" "$line" "branch=fixture-wt"
assert_contains "linked worktree: the ref is the shared HEAD"  "$line" "ref=$HEAD_SHA"

# ── E. BELOW a repository root — the walk-up trap ───────────────────────
# The runner's own root is `$REPO/nested`, which is inside the fixture repo
# but is not a repository. `git -C` here would answer with $HEAD_SHA at rc 0;
# the header must refuse it.
mk_tree "$REPO/nested" || { echo "FAIL: nested fixture" >&2; exit 1; }
tree_line "$REPO/nested"; line=$TREE_LINE
assert_contains "below a root: ref=UNKNOWN, naming the walk-up" \
    "$line" "ref=UNKNOWN (dir is not its own repository root"
assert_not_contains "below a root: the ENCLOSING repository's sha is NOT borrowed" \
    "$line" "$HEAD_SHA"

# ── F. not a repository at all ───────────────────────────────────────────
PLAIN="$WORK/plain"
mk_tree "$PLAIN" || { echo "FAIL: plain fixture" >&2; exit 1; }
env -u GIT_DIR -u GIT_WORK_TREE git -C "$PLAIN" rev-parse --show-toplevel >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && _th_pass || _th_fail
printf '  %s: CONTROL: the plain fixture has NO enclosing repository (git rc=%s)\n' \
    "$( [[ "$rc" -ne 0 ]] && echo PASS || echo FAIL )" "$rc"
tree_line "$PLAIN"; line=$TREE_LINE
assert_eq "not a repo: the line is exactly the UNKNOWN wording" \
    "$line" "=== tree: ref=UNKNOWN (not a git checkout) ==="

# ── G. git not on PATH ───────────────────────────────────────────────────
# A PATH-front `git` that behaves as an absent binary (rc 127, nothing on
# stdout). The runner and repo-root.sh both resolve `git` through PATH, so this
# is the "git unavailable" arm without touching the host.
mkdir -p "$WORK/nogit"
printf '#!/usr/bin/env bash\nexit 127\n' >"$WORK/nogit/git"
chmod +x "$WORK/nogit/git"
RUN_OUT=$( cd "$WORK/cwd" && PATH="$WORK/nogit:$PATH" \
             bash "$REPO/monitor/watcher/run-tests.sh" --jobs 1 \
                  "$REPO/monitor/watcher/test-trivial.sh" 2>&1 )
line=$(grep -aE '^=== tree: ' <<<"$RUN_OUT")
assert_contains "no usable git: ref=UNKNOWN, never a blank line" \
    "$line" "ref=UNKNOWN ("
assert_not_contains "no usable git: no sha is printed" "$line" "$HEAD_SHA"

# ── H. THE TREE IS RE-READ AT THE END (your-org/nexus-code#1586) ─────────
# The header has named the tree since #1465, and named it ONCE. A band launched
# from a clone that is being edited tests commit A for the early suites and
# commit B for the late ones; its failing set reads exactly like a clean one.
# So the runner now compares HEAD and the CONTENT of every tracked-modified
# path, start to end, and a drift is rc 5: NOT A VERDICT, outranking 0, 1, 3.
#
# Each planted suite mutates the FIXTURE repository while the copied runner is
# mid-run, which is the incident itself at the smallest scale that still has a
# "before" and an "after".
DR="$WORK/drift"
mkdir -p "$DR" && fgit init -q "$DR" && mk_tree "$DR" || { echo "FAIL: drift fixture" >&2; exit 1; }
printf 'v1\n' > "$DR/monitor/subject.sh"
_suite() {   # <name> <rc> <body…>  — a planted suite; ROOT is the fixture repo
    { printf '#!/usr/bin/env bash\nROOT=$(cd "$(dirname "$0")/../.." && pwd)\n'
      printf '%s\n' "${@:3}"
      if [[ "$2" == 0 ]]; then printf 'echo "=== summary: 1 passed, 0 failed ==="\necho "ALL TESTS PASSED"\nexit 0\n'
      else printf 'echo "  FAIL: planted red"\necho "=== summary: 0 passed, 1 failed ==="\nexit 1\n'; fi
    } > "$DR/monitor/watcher/$1"
    chmod +x "$DR/monitor/watcher/$1"
}
_suite test-h-edits-tracked.sh   0 'printf "edited-mid-run\n" >> "$ROOT/monitor/subject.sh"'
_suite test-h-commits.sh         0 'env -u GIT_DIR -u GIT_WORK_TREE git -C "$ROOT" -c user.name=fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null commit -q --allow-empty -m mid-run'
_suite test-h-leaves-untracked.sh 0 'printf "leaked\n" > "$ROOT/monitor/leaked-plant.txt"'
_suite test-h-plants-and-removes.sh 0 'printf "x\n" > "$ROOT/monitor/transient.txt"; rm -f "$ROOT/monitor/transient.txt"'
_suite test-h-red-and-edits.sh   1 'printf "edited-by-a-red-suite\n" >> "$ROOT/monitor/subject.sh"'
_suite test-h-red-only.sh        1 ':'
fgit -C "$DR" add -A && fgit -C "$DR" commit -q -m 'drift fixture' || { echo "FAIL: drift commit" >&2; exit 1; }
th_require_fixture_repo "$DR"
_restore() { fgit -C "$DR" checkout -q -- monitor/subject.sh; rm -f "$DR/monitor/leaked-plant.txt"; }
run_h() {   # <suite-basename…> -> RUN_OUT, RUN_RC, END_LINE
    local -a paths=(); local n
    for n in "$@"; do paths+=( "$DR/monitor/watcher/$n" ); done
    RUN_OUT=$( cd "$WORK/cwd" && bash "$DR/monitor/watcher/run-tests.sh" --jobs 1 "${paths[@]}" 2>&1 )
    RUN_RC=$?
    END_LINE=$(tail -n 1 <<<"$RUN_OUT")
}

run_h test-trivial.sh
assert_eq           "H1 nothing changes: rc 0 (MUST NOT FLIP)"                 "$RUN_RC" "0"
assert_not_contains "H1 …and no drift banner on a tree that held still"         "$RUN_OUT" "TREE CHANGED DURING RUN"
assert_contains     "H1 …and the closing marker is the ordinary green one"      "$END_LINE" "END rc=0 (COMPLETE and green"

run_h test-trivial.sh test-h-edits-tracked.sh
assert_eq       "H2 a TRACKED file edited mid-run: rc 5, not 0"                 "$RUN_RC" "5"
assert_contains "H2 …the banner says the verdict describes no single tree"      "$RUN_OUT" "TREE CHANGED DURING RUN — this verdict describes no single tree"
assert_contains "H2 …the path that moved is NAMED"                              "$RUN_OUT" "monitor/subject.sh"
assert_contains "H2 …and the LAST LINE says NOT A VERDICT (a reader of a truncated log has only that)" \
    "$END_LINE" "END rc=5 (NOT A VERDICT — the tree CHANGED during the run"
_restore

_h_before=$(fgit -C "$DR" rev-parse HEAD)
run_h test-h-commits.sh
assert_eq       "H3 HEAD moved mid-run (a commit): rc 5"                        "$RUN_RC" "5"
assert_contains "H3 …and the HEAD it STARTED at is named"                       "$RUN_OUT" "HEAD $_h_before"
assert_contains "H3 …beside the HEAD it ended at"                               "$RUN_OUT" "HEAD $(fgit -C "$DR" rev-parse HEAD)"

# THE CASE `dirty=yes` CANNOT SEE: dirty at the start, DIFFERENTLY dirty at the
# end. Both headers would print the same boolean.
printf 'dirty-before-the-run\n' >> "$DR/monitor/subject.sh"
run_h test-h-edits-tracked.sh
assert_contains "H4 CONTROL: the header already said dirty=yes at the start"    "$(grep -aE '^=== tree: ' <<<"$RUN_OUT")" "dirty=yes"
assert_eq       "H4 dirty at start and DIFFERENTLY dirty at end: rc 5 — content, not a boolean" "$RUN_RC" "5"
_restore

run_h test-h-leaves-untracked.sh
assert_eq           "H5 an UNTRACKED file left behind: the verdict STANDS (rc 0)" "$RUN_RC" "0"
assert_contains     "H5 …but it is said, loudly, by path"                        "$RUN_OUT" "monitor/leaked-plant.txt"
assert_not_contains "H5 …and it is NOT called a changed tree"                    "$RUN_OUT" "TREE CHANGED DURING RUN"
_restore

run_h test-h-plants-and-removes.sh
assert_eq           "H6 planted AND removed mid-run: rc 0"                       "$RUN_RC" "0"
assert_not_contains "H6 …with no note at all — only START and END are compared"  "$RUN_OUT" "UNTRACKED paths appeared"

run_h test-h-red-and-edits.sh
assert_eq       "H7 a RED suite on a tree that moved: rc 5, NOT 1 — a mixed tree is evidence for neither verdict" "$RUN_RC" "5"
_restore
run_h test-h-red-only.sh
assert_eq       "H8 CONTROL: a red suite on a tree that held still is still rc 1 — the re-check does not mask a red" "$RUN_RC" "1"

EXPECTED_ASSERTIONS=39
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
