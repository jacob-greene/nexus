#!/usr/bin/env bash
# test-public-mirror-leak-gate-fail-closed.sh — the public mirror's leak gate
# must REFUSE when it cannot scan, and its separator/shape rows must catch
# every form they are written to catch.
#
# FAIL CLOSED (your-org/nexus-code#1760). leak-gate.sh joins the deny
# rows into ONE alternation and discards grep's stderr. A row that does not
# compile makes grep exit 2 with an EMPTY stdout, which is exactly what "no
# hits" looks like, so one malformed row disarmed EVERY row and the gate
# printed PASS. A bad `keep` row is the same hole from the other side: the
# `grep -vE` that discounts kept lines exits 2 printing nothing, deleting every
# hit. Driven against the REAL gate with a SYNTHETIC dictionary:
#
#   F1  clean tree, valid map            -> rc 0   (control: not an always-fail)
#   F2  planted token, valid map         -> rc 1   (control: the gate is live)
#   F3  planted token + bad DENY row     -> rc 7   (base: rc 0, PASS)
#   F4  clean tree + bad DENY row        -> rc 7   (base: rc 0, PASS)
#   F5  planted token + bad KEEP row     -> rc 7   (base: rc 0 — the hit is deleted)
#   F6  the refusal names the mapping LINE and does not quote the pattern
#
#
# Run: bash monitor/watcher/test-public-mirror-leak-gate-fail-closed.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Exit 77 = declined to run.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
GATE="$SRC_ROOT/monitor/public-mirror/leak-gate.sh"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[ -r "$GATE" ] || { echo "missing $GATE" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pmfc.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
cleanup(){ [ -n "${WORK:-}" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

# mkrepo <dir> [<file-content>] — a fixture repo that is its OWN root, with
# one committed file. Verified: a silent `git init` failure would leave the
# gate scanning the ENCLOSING repository (CLAUDE.md: git -C walks UP).
mkrepo(){
  local d=$1 content=${2:-ordinary content}
  rm -rf -- "$d"; mkdir -p "$d" || return 1
  ( cd "$d" \
      && git init -q . \
      && git config --local user.email fixture@example.invalid \
      && git config --local user.name fixture \
      && printf '%s\n' "$content" > f.txt \
      && git add -A && git commit -q -m fixture ) >/dev/null 2>&1 || return 1
  th_require_fixture_repo "$d" "leak-gate fixture"
}

# run_gate <map> <dir> -> GRC, GOUT. rc captured BEFORE any pipe.
run_gate(){ GOUT=$(bash "$GATE" "$1" "$2" 2>&1); GRC=$?; return 0; }

# ---- synthetic dictionary ----------------------------------------------------
# `zarquon` is a nonsense token in no real mapping.
GOOD="$WORK/good.tsv"
printf 'deny\tzarquon\n' > "$GOOD"
BADDENY="$WORK/bad-deny.tsv"
{ printf 'deny\tzarquon\n'; printf 'deny\tunclosed(group\n'; } > "$BADDENY"
BADKEEP="$WORK/bad-keep.tsv"
{ printf 'deny\tzarquon\n'; printf 'keep\t[unclosed-class\n'; } > "$BADKEEP"

mkrepo "$WORK/clean" 'nothing to see' || { fail "fixture clean could not be built"; th_summary_and_exit; }
mkrepo "$WORK/dirty" 'a zarquon slipped in' || { fail "fixture dirty could not be built"; th_summary_and_exit; }

run_gate "$GOOD" "$WORK/clean"
[ "$GRC" -eq 0 ] && pass "F1: clean tree + valid map PASSES (rc 0)" \
                 || fail "F1: clean tree + valid map rc=$GRC (want 0): $GOUT"

run_gate "$GOOD" "$WORK/dirty"
[ "$GRC" -eq 1 ] && pass "F2: planted token + valid map FAILS (rc 1) — the gate is live" \
                 || fail "F2: planted token + valid map rc=$GRC (want 1): $GOUT"

run_gate "$BADDENY" "$WORK/dirty"
[ "$GRC" -eq 7 ] && pass "F3: an uncompilable DENY row is REFUSED (rc 7), not a PASS over a planted token" \
                 || fail "F3: uncompilable deny row + planted token rc=$GRC (want 7) — one bad row disarms every row: $GOUT"

run_gate "$BADDENY" "$WORK/clean"
[ "$GRC" -eq 7 ] && pass "F4: an uncompilable DENY row is REFUSED on a clean tree too (rc 7)" \
                 || fail "F4: uncompilable deny row on a clean tree rc=$GRC (want 7): $GOUT"
F4OUT=$GOUT

run_gate "$BADKEEP" "$WORK/dirty"
[ "$GRC" -eq 7 ] && pass "F5: an uncompilable KEEP row is REFUSED (rc 7), not allowed to delete the hit" \
                 || fail "F5: uncompilable keep row + planted token rc=$GRC (want 7): $GOUT"

if grep -q 'deny@line2' <<<"$F4OUT" && ! grep -qF 'unclosed(group' <<<"$F4OUT"; then
    pass "F6: the refusal names the mapping line (deny@line2) without quoting the pattern"
else
    fail "F6: refusal text does not name the line, or quotes the pattern: $F4OUT"
fi

# THE ASSERTION TOTAL IS EXACT: an assertion that silently stops running (a
# section that aborted, a loop over an empty set) is a red, not a smaller green.
EXPECTED=6
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: assertion census %d != EXPECTED %d — an assertion did not run, or one was added without updating EXPECTED\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
