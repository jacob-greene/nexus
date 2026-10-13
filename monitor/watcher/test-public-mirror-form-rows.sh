#!/usr/bin/env bash
# test-public-mirror-form-rows.sh — the public mirror's separator and shape
# deny rows must catch every form they are written to catch.
#
# POTENCY OF THE REAL DICTIONARY'S FORM ROWS (your-org/nexus-code#1761).
# A deny row with a separator class (`a[-_ ]?b`) is a claim about every
# separator a writer might use; the dot form was missing, so `a.b` shipped.
# And the shape rows for sample identifiers are only worth anything if each
# actually fires. Every planted token is DERIVED from the row at run time —
# this file ships to the public mirror and must not name a dictionary value
# (the same discipline as test-public-mirror-dictionary-coverage.sh), so rows
# are reported by mapping LINE number only.
#
#   S1  >= 1 separator-class row exists          (non-vacuity)
#   S2  each separator form (none - _ space .) of each such row FAILS the gate
#   D1  >= 1 digit-shape row exists              (non-vacuity; base: 0)
#   D2  a token synthesised from each digit-shape row FAILS the gate
#
# Run: bash monitor/watcher/test-public-mirror-form-rows.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Exit 77 = declined to run.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
GATE="$SRC_ROOT/monitor/public-mirror/leak-gate.sh"
REAL_MAP="$SRC_ROOT/monitor/public-mirror/mapping.tsv"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[ -r "$GATE" ] || { echo "missing $GATE" >&2; exit 1; }
[ -r "$REAL_MAP" ] || { printf 'DECLINED (exit 77): no mapping at %s\n' "$REAL_MAP" >&2; exit 77; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pmfr.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
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

# ---- the real dictionary's form rows -------------------------------------
# A row of the separator shape: LITERAL [class]? LITERAL, optional \b anchors.
# The class is read from the row, so a widened class is tested as widened.
SEPS=( '' '-' '_' ' ' '.' )
n_sep_rows=0
while IFS=$'\t' read -r ln pat; do
    core=${pat#\\b}; core=${core%\\b}
    # Parsed with parameter expansion, NOT a `[[ =~ ]]` regex: the inline form
    # needs a `[^]]` bracket expression, and it matched under bash 4.4 but not
    # under the CI runner's bash 5.x (S1 found 0 rows while the independent awk
    # count found 1). Splitting on the literal `[` and `]?` has no dialect.
    case "$core" in *'['*']?'*) : ;; *) continue ;; esac
    a=${core%%\[*}; _rest=${core#*\[}; b=${_rest#*\]\?}
    [[ -n "$a" && -n "$b" && "$a" != *[!A-Za-z0-9]* && "$b" != *[!A-Za-z0-9]* ]] || continue
    n_sep_rows=$((n_sep_rows+1))
    missed=""
    for s in "${SEPS[@]}"; do
        mkrepo "$WORK/sep" "context ${a}${s}${b} context" || { missed="$missed fixture"; continue; }
        run_gate "$REAL_MAP" "$WORK/sep"
        [ "$GRC" -eq 1 ] || missed="$missed [${s:-none}]=rc$GRC"
    done
    if [ -z "$missed" ]; then
        pass "S2: mapping line $ln catches every separator form (none - _ space .)"
    else
        fail "S2: mapping line $ln misses separator form(s):$missed"
    fi
done < <(awk -F'\t' '$1=="deny"{print NR "\t" $2}' "$REAL_MAP")
(( n_sep_rows >= 1 )) && pass "S1: $n_sep_rows separator-class deny row(s) found (non-vacuous)" \
                      || fail "S1: no separator-class deny row found — S2 tested nothing"

# A digit-shape row: optional \b, a LITERAL prefix, [0-9]{n} or [0-9]{n,},
# optional \b. Synthesise the minimum-length all-zero token.
n_digit_rows=0
while IFS=$'\t' read -r ln pat; do
    core=${pat#\\b}; core=${core%\\b}
    [[ "$core" =~ ^([A-Za-z_]+)\[0-9\]\{([0-9]+),?\}$ ]] || continue
    n_digit_rows=$((n_digit_rows+1))
    tok="${BASH_REMATCH[1]}$(printf '%0*d' "${BASH_REMATCH[2]}" 0)"
    if mkrepo "$WORK/dig" "see ${tok} here"; then
        run_gate "$REAL_MAP" "$WORK/dig"
        [ "$GRC" -eq 1 ] && pass "D2: mapping line $ln fires on a synthesised token of its shape" \
                         || fail "D2: mapping line $ln did not fire on a synthesised token (rc=$GRC)"
    else
        fail "D2: fixture for mapping line $ln could not be built"
    fi
done < <(awk -F'\t' '$1=="deny"{print NR "\t" $2}' "$REAL_MAP")
(( n_digit_rows >= 1 )) && pass "D1: $n_digit_rows digit-shape deny row(s) found (non-vacuous)" \
                        || fail "D1: no digit-shape deny row found — sample-ID shapes are unguarded"

# The row counts, enumerated INDEPENDENTLY of the two loops above (awk over
# the deny column, not the loops' own counters), so a loop that silently
# skipped a row is a census mismatch rather than a smaller green.
_rows_sep=$(awk -F'\t' '$1=="deny"{p=$2; sub(/^\\b/,"",p); sub(/\\b$/,"",p); if (p ~ /^[A-Za-z0-9]+\[[^]]+\]\?[A-Za-z0-9]+$/) n++} END{print n+0}' "$REAL_MAP")
_rows_dig=$(awk -F'\t' '$1=="deny"{p=$2; sub(/^\\b/,"",p); sub(/\\b$/,"",p); if (p ~ /^[A-Za-z_]+\[0-9\]\{[0-9]+,?\}$/) n++} END{print n+0}' "$REAL_MAP")
# THE ASSERTION TOTAL IS EXACT: an assertion that silently stops running (a
# section that aborted, a loop over an empty set) is a red, not a smaller green.
EXPECTED=$(( 2 + _rows_sep + _rows_dig ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: assertion census %d != EXPECTED %d — an assertion did not run, or one was added without updating EXPECTED\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
