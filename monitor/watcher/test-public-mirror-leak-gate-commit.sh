#!/usr/bin/env bash
# test-public-mirror-leak-gate-commit.sh — `leak-gate.sh --commit <sha>` must
# screen the published COMMIT'S metadata, not only its tree.
#
# THE HOLE THIS FILLS (your-org/nexus-code#1006 item 1, spec from #979). The
# public mirror is published as ONE commit on top of the public HEAD per sync
# (`commit-tree -p <public-HEAD>`, fast-forward). That commit's message and its
# author/committer identities ship verbatim, and every check the gate had read
# only the TREE — so a private address in the committer line, or an internal
# token in the message body, passed a gate that printed PASS.
#
# WHAT THIS ASSERTS, against the REAL, UNMODIFIED gate with a SYNTHETIC
# dictionary (`zarquon`, a nonsense token in no real mapping; the dictionary
# lives OUTSIDE every fixture repo so it is never itself a hit):
#
#   A. clean message + clean identities           -> rc 0, and the PASS names
#                                                    the commit.
#   B. denied token in the message BODY (line 3)  -> rc 1, field `message:3`.
#   C. denied token in the AUTHOR EMAIL only      -> rc 1, field `author.email`.
#   D. denied token in the COMMITTER NAME only    -> rc 1, field `committer.name`,
#                                                    and author NOT named.
#   E. keep-listed use of the token in a message  -> rc 0 (the keep list applies
#                                                    to metadata as to content).
#   F. an EXTRA header (hand-built object) and an UNTERMINATED final message
#      line each carrying the token               -> rc 1 naming each field.
#   G. unresolvable sha / a TREE id / empty value / missing value / non-git
#      dir                                        -> REFUSED rc 2, never PASS.
#   H. a commit whose tree is NOT the index       -> REFUSED rc 5 (the tree is
#      vouched for by BINDING to the scanned index, not by a second scan).
#   I. clean metadata but a leaking TREE          -> rc 1: --commit adds to the
#                                                    content scan, never
#                                                    replaces it.
#   J. NO --commit on a repo whose HEAD metadata leaks -> rc 0 with the exact
#      historical PASS line and nothing else: the old behaviour is untouched.
#
# Identities are set per commit through GIT_AUTHOR_*/GIT_COMMITTER_* in the
# command's own environment (they outrank config, so an ambient value cannot
# leak in) — never through the global git config.
#
# Run: bash monitor/watcher/test-public-mirror-leak-gate-commit.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Exit 77 = declined to run.

set -uo pipefail
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
GATE="$SRC_ROOT/monitor/public-mirror/leak-gate.sh"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
decline(){ printf 'DECLINED (exit 77): %s\n' "$1" >&2; exit 77; }

[ -r "$GATE" ] || decline "missing $GATE"
command -v git >/dev/null 2>&1 || decline "git not on PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pmcommit.XXXXXX") || decline "mktemp failed"
cleanup(){ [ -n "${WORK:-}" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

MAP="$WORK/synthetic-map.tsv"
{
  printf 'deny\tzarquon\n'
  printf 'keep\tzarquon-public/assets\n'
} > "$MAP"

CLEAN_ID=(fixture fixture@example.invalid fixture fixture@example.invalid)

# mkcommit <an> <ae> <cn> <ce> <msg> -> prints the new commit's sha. Built from
# the CURRENT index with HEAD as parent, exactly as the sync recipe does.
mkcommit(){
  local tree
  tree=$(git -C "$REPO" write-tree) || return 1
  env GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" \
      GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
      git -C "$REPO" commit-tree "$tree" -p HEAD -m "$5"
}

# run_gate <args...> -> sets GRC and GOUT. rc captured BEFORE any pipe.
run_gate(){
  GOUT=$(bash "$GATE" "$MAP" "$REPO" "$@" 2>&1); GRC=$?
  return 0
}
has(){ grep -qF -e "$1" <<<"$GOUT"; }

# ------------------------------------------------------------- fixture -----
REPO="$WORK/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q . ) || decline "git init failed"
th_require_fixture_repo "$REPO" "leak-gate commit fixture"
printf 'ordinary public content\n' > "$REPO/plain.txt"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=fixture@example.invalid -c user.name=fixture \
    commit -q -m base >/dev/null 2>&1
if git -C "$REPO" rev-parse --verify --quiet HEAD >/dev/null \
   && git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet; then
  pass "fixture: one clean commit, index == working tree == HEAD"
else
  fail "fixture malformed — every verdict below would be meaningless"
fi

# ------------------------------------------------------------------ A ------
C=$(mkcommit "${CLEAN_ID[@]}" $'Sync public mirror\n\nplain body text')
run_gate --commit "$C"
if (( GRC == 0 )) && has "commit $C: metadata clean"; then
  pass "A: clean message and identities -> rc 0, PASS names the commit"
else
  fail "A: want rc 0 naming the commit, got $GRC (out: $GOUT)"
fi

# ------------------------------------------------------------------ B ------
C=$(mkcommit "${CLEAN_ID[@]}" $'Sync public mirror\n\nsee the zarquon tracker for details')
run_gate --commit "$C"
if (( GRC == 1 )) && has 'METADATA' && has 'message:3:'; then
  pass "B: denied token in the message BODY -> rc 1, field message:3"
else
  fail "B: want rc 1 naming message:3, got $GRC (out: $GOUT)"
fi

# ------------------------------------------------------------------ C ------
C=$(mkcommit fixture 'someone@zarquon.example' fixture fixture@example.invalid 'Sync public mirror')
run_gate --commit "$C"
if (( GRC == 1 )) && has 'author.email:' && ! has 'committer.'; then
  pass "C: denied token in the AUTHOR EMAIL -> rc 1, field author.email only"
else
  fail "C: want rc 1 naming author.email only, got $GRC (out: $GOUT)"
fi

# ------------------------------------------------------------------ D ------
C=$(mkcommit fixture fixture@example.invalid 'Zarquon Operator' fixture@example.invalid 'Sync public mirror')
run_gate --commit "$C"
if (( GRC == 1 )) && has 'committer.name:' && ! has 'author.'; then
  pass "D: denied token in the COMMITTER NAME -> rc 1, field committer.name only"
else
  fail "D: want rc 1 naming committer.name only, got $GRC (out: $GOUT)"
fi

# ------------------------------------------------------------------ E ------
C=$(mkcommit "${CLEAN_ID[@]}" $'Sync public mirror\n\nassets from zarquon-public/assets')
run_gate --commit "$C"
if (( GRC == 0 )); then
  pass "E: keep-listed use of the token in the message -> rc 0"
else
  fail "E: want rc 0 (keep list applies to metadata), got $GRC (out: $GOUT)"
fi

# ------------------------------------------------------------------ F ------
# A hand-built object: `git commit-tree` cannot write an extra header or an
# unterminated final line, and both are published bytes.
_tree=$(git -C "$REPO" write-tree)
_head=$(git -C "$REPO" rev-parse HEAD)
C=$(printf 'tree %s\nparent %s\nauthor fixture <fixture@example.invalid> 1700000000 +0000\ncommitter fixture <fixture@example.invalid> 1700000000 +0000\nx-origin zarquon-internal\n\nSync public mirror\n\nlast line zarquon' \
      "$_tree" "$_head" | git -C "$REPO" hash-object -t commit -w --stdin 2>/dev/null)
if [ -n "$C" ] && [ "$(git -C "$REPO" cat-file commit "$C" | tail -c 1 | od -An -c | tr -d ' ')" != '\n' ]; then
  pass "F: fixture object built, final message line unterminated"
else
  fail "F: could not build the hand-made commit object (sha='$C')"
fi
run_gate --commit "$C"
if (( GRC == 1 )) && has 'header.x-origin:' && has 'message:3:'; then
  pass "F: extra header AND unterminated final line are both screened -> rc 1"
else
  fail "F: want rc 1 naming header.x-origin and message:3, got $GRC (out: $GOUT)"
fi

# ------------------------------------------------------------------ G ------
run_gate --commit 0123456789abcdef0123456789abcdef01234567
if (( GRC == 2 )) && has 'REFUSED' && ! has 'LEAK GATE: PASS'; then
  pass "G: unresolvable sha -> REFUSED rc 2, no PASS"
else
  fail "G: unresolvable sha: want rc 2 REFUSED, got $GRC (out: $GOUT)"
fi
run_gate --commit "$_tree"
if (( GRC == 2 )) && has 'REFUSED'; then
  pass "G: a TREE id is not a commit -> REFUSED rc 2"
else
  fail "G: tree id: want rc 2, got $GRC (out: $GOUT)"
fi
run_gate --commit ''
if (( GRC == 2 )) && has 'REFUSED'; then
  pass "G: empty --commit value -> REFUSED rc 2"
else
  fail "G: empty value: want rc 2, got $GRC (out: $GOUT)"
fi
run_gate --commit
if (( GRC == 2 )) && ! has 'LEAK GATE: PASS'; then
  pass "G: --commit with no value -> rc 2"
else
  fail "G: missing value: want rc 2, got $GRC (out: $GOUT)"
fi
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"; printf 'x\n' > "$NOGIT/f.txt"
GOUT=$(bash "$GATE" "$MAP" "$NOGIT" --commit HEAD 2>&1); GRC=$?
if (( GRC == 2 )) && has 'needs a git work tree'; then
  pass "G: --commit outside a git work tree -> REFUSED rc 2"
else
  fail "G: non-git dir: want rc 2, got $GRC (out: $GOUT)"
fi

# ------------------------------------------------------------------ H ------
# A clean-metadata commit whose tree carries one more file than the index.
printf 'extra\n' > "$REPO/extra.txt"
git -C "$REPO" add extra.txt
C=$(mkcommit "${CLEAN_ID[@]}" 'Sync public mirror')
git -C "$REPO" rm -q --cached extra.txt; rm -f "$REPO/extra.txt"
run_gate --commit "$C"
if (( GRC == 5 )) && has "tree is not the index"; then
  pass "H: commit tree != scanned index -> REFUSED rc 5"
else
  fail "H: want rc 5, got $GRC (out: $GOUT)"
fi
# …and --allow-unstaged cannot license a commit verdict over a dirty tree.
C=$(mkcommit "${CLEAN_ID[@]}" 'Sync public mirror')
printf 'unstaged edit\n' >> "$REPO/plain.txt"
run_gate --allow-unstaged --commit "$C"
git -C "$REPO" checkout -q -- plain.txt
if (( GRC == 5 )) && has 'index that differs from the working tree'; then
  pass "H: --allow-unstaged + --commit over a dirty tree -> REFUSED rc 5"
else
  fail "H: allow-unstaged: want rc 5, got $GRC (out: $GOUT)"
fi

# ------------------------------------------------------------------ I ------
printf 'the zarquon host\n' > "$REPO/leaky.txt"
git -C "$REPO" add leaky.txt
C=$(mkcommit "${CLEAN_ID[@]}" 'Sync public mirror')
run_gate --commit "$C"
if (( GRC == 1 )) && has 'leaky.txt' && ! has 'METADATA'; then
  pass "I: clean metadata over a leaking tree -> rc 1 from the content scan"
else
  fail "I: want rc 1 naming leaky.txt, got $GRC (out: $GOUT)"
fi
git -C "$REPO" rm -q -f leaky.txt

# ------------------------------------------------------------------ J ------
# Move HEAD onto a commit whose metadata leaks; without --commit the gate
# must answer exactly as it always has — about the tree, and only the tree.
C=$(mkcommit fixture 'x@zarquon.example' fixture fixture@example.invalid $'zarquon subject\n\nzarquon body')
git -C "$REPO" update-ref HEAD "$C"
run_gate
if (( GRC == 0 )) && [ "$GOUT" = "LEAK GATE: PASS — zero denied tokens (keep-list applied)" ]; then
  pass "J: no --commit -> old behaviour, exact historical PASS line only"
else
  fail "J: want rc 0 and the historical PASS line only, got $GRC (out: $GOUT)"
fi
run_gate --commit HEAD
if (( GRC == 1 )) && has 'message:1:' && has 'author.email:'; then
  pass "J: the same HEAD with --commit -> rc 1 (J's PASS is not a blind gate)"
else
  fail "J: potency control: want rc 1, got $GRC (out: $GOUT)"
fi

# --- assertion-count guard ------------------------------------------------
# A VERDICT IS NOT A COUNT: a suite that silently stopped running arms would
# report green over less than it claims. Pin the total.
# 1 (fixture) + A1 + B1 + C1 + D1 + E1 + F2 + G5 + H2 + I1 + J2 + this one = 19.
EXPECTED_ASSERTIONS=19
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} + 1 ))
if (( TOTAL_ASSERTIONS == EXPECTED_ASSERTIONS )); then
  pass "assertion total is exactly $EXPECTED_ASSERTIONS — no arm was silently skipped"
else
  fail "assertion total $TOTAL_ASSERTIONS != expected $EXPECTED_ASSERTIONS — an arm ran short or was skipped"
fi

th_summary_and_exit
