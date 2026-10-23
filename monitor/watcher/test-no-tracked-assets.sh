#!/usr/bin/env bash
# The code repository must track nothing under `assets/`.
#
# `assets/` at the nexus root is the local clone of the operator's
# asset repository. `.gitignore` lists `/assets/`, but `git add -f` (or
# an upload that ran with the code repo as its git context) can still
# track a file there. A tracked file under `assets/` does two kinds of
# harm:
#
#   1. It publishes asset content on the code repository, which may be
#      public (jacob-greene/nexus#171: two tracked report files carried
#      internal identifiers).
#   2. Every fresh clone and worktree then holds a non-empty `assets/`
#      with no `.git`, so the first-run `git clone` in
#      monitor/upload-asset.sh fails (jacob-greene/nexus#102).
#
# Run: bash monitor/watcher/test-no-tracked-assets.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$_test_dir/../.." && pwd)

# ---- the `--population` protocol (your-org/nexus-code#803) ---------------
# What this guard reads: the git INDEX under assets/ (any tracked file there
# is the finding, so it is the population) and .gitignore. `_tracked_assets`
# is the one enumerator, shared with the check below.
_tracked_assets() { git -C "${1:-$ROOT}" ls-files -- assets; }
. "$_test_dir/../_guard_population.sh"
gp_population() {
    _tracked_assets 2>/dev/null | sed "s|^|$ROOT/|"
    printf '%s\n' "$ROOT/.gitignore"
}
gp_handle "$@"

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "SKIP: $ROOT is not a git checkout"
    echo "ALL TESTS PASSED"
    exit 0
fi

tracked=$(_tracked_assets)
pass=0
fail=0
if [[ -z "$tracked" ]]; then
    printf '  PASS: no tracked file under assets/\n'
    pass=1
else
    printf '  FAIL: tracked file(s) under assets/ (untrack with git rm --cached):\n'
    printf '%s\n' "$tracked" | sed 's/^/        /'
    fail=1
fi

if grep -qxF '/assets/' "$ROOT/.gitignore"; then
    printf '  PASS: .gitignore lists /assets/\n'
    pass=$((pass + 1))
else
    printf '  FAIL: .gitignore lists /assets/\n'
    fail=$((fail + 1))
fi

# PLANT (positive control): in a scratch repo with a tracked assets/ file,
# the same lister must report it, or the PASS above proves nothing.
_plant=$(mktemp -d)
git -C "$_plant" init -q
mkdir -p "$_plant/assets"; echo x > "$_plant/assets/planted.txt"
git -C "$_plant" add assets/planted.txt
assert_eq() {
    if [[ "$2" == "$3" ]]; then printf '  PASS: %s\n' "$1"; pass=$((pass + 1))
    else printf '  FAIL: %s — got %s want %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
assert_eq "PLANT: a planted tracked assets/ file is detected" \
    "$(_tracked_assets "$_plant")" "assets/planted.txt"
rm -rf "$_plant"

printf '\n=== summary: %d passed, %d failed ===\n' "$pass" "$fail"
if (( fail > 0 )); then
    echo "FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
