#!/usr/bin/env bash
# The public-mirror build never rewrites a binary and never ships a scrubbed
# file that stopped parsing (your-org/nexus-code#1812).
#
# Run: bash monitor/watcher/test-public-mirror-verify-build.sh
# Expected: ALL TESTS PASSED, exit 0.
#
# THE INCIDENT. build.sh ran the case-insensitive text scrub over every tracked
# file, binaries included. A three-character dictionary token matched twice
# inside a JPEG's compressed data, 8 bytes were inserted, and the mirror shipped
# a corrupt image for weeks with every gate green: the leak gate reads for
# DENIED tokens, and a corrupted image carries fewer of those, not more.
#
#   §1  a binary carrying a dictionary token (in ANY case) is copied VERBATIM
#       and the build passes when the binary is reviewed at its blob sha;
#   §2  an UNREVIEWED binary, or one reviewed at a different sha, stops the
#       build (exit 11) and names the file — a binary is a human decision;
#   §3  a scrub that breaks a shell / Python / JSON / YAML file stops the
#       build (exit 10) and names the file and the kind;
#   §4  a file whose SOURCE already fails to parse is not reported (no false
#       red on deliberate fixtures);
#   §5  verify-build.py on its own catches a rewritten binary — the check is
#       independent of build.sh's skip, so a future regression in the skip
#       cannot pass silently.
#
# All fixtures are throwaway `git init` repos under mktemp — NEVER this
# checkout (#1001). The vocabulary is invented for this file.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
TOOLKIT="$REPO_ROOT/monitor/public-mirror"

. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' monitor/public-mirror/build.sh monitor/public-mirror/scrub.pl \
        monitor/public-mirror/verify-build.py monitor/public-mirror/binaries.tsv
}
gp_handle "$@"

for f in build.sh scrub.pl verify-build.py binaries.tsv; do
    [[ -r "$TOOLKIT/$f" ]] || { echo "missing $TOOLKIT/$f" >&2; exit 2; }
done
command -v perl    >/dev/null 2>&1 || { echo "SKIP: perl not installed (scrub.pl needs it)"; exit 77; }
command -v git     >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed (verify-build.py needs it)"; exit 77; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pmverify.XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# fixture <name> -> repo path. A committed, clean repo with a copy of the
# toolkit, a synthetic dictionary, a text file and a BINARY file that both
# carry the dictionary token (the binary in mixed case, as the JPEG did).
fixture() {
    local repo="$WORK/$1"
    mkdir -p "$repo/pm"
    cp "$TOOLKIT/scrub.pl" "$TOOLKIT/build.sh" "$TOOLKIT/verify-build.py" "$repo/pm/"
    printf 'map\tqzx\tpublic-thing\n' > "$repo/pm/mapping.tsv"
    printf 'deny\tqzxorg\nexclude\tpm/mapping.tsv\n' >> "$repo/pm/mapping.tsv"
    printf 'a qzx reference\n' > "$repo/note.txt"
    printf '\x89IMG\x00\x01QzX\x02\x00\xffqZx\x7f\x00tail' > "$repo/pic.bin"
    ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
        && git add -A && git commit -qm init ) >/dev/null 2>&1
    printf '%s' "$repo"
}
review() {   # review <repo> -> write pm/binaries.tsv for pic.bin at its blob
    local sha; sha=$(git -C "$1" rev-parse HEAD:pic.bin)
    printf 'binary\tpic.bin\t%s\tfixture\n' "$sha" > "$1/pm/binaries.tsv"
    ( cd "$1" && git add -A && git commit -qm review ) >/dev/null 2>&1
}
run_build() {   # <repo> -> "<rc>|<output>"
    local o rc
    o=$( cd "$1" && bash pm/build.sh --yes 2>&1 ); rc=$?
    printf '%s|%s' "$rc" "$o"
}

# ── §1 ───────────────────────────────────────────────────────────────────
echo '=== §1 a reviewed binary carrying the token ships byte-identical ==='
r1=$(fixture r1); review "$r1"
before=$(git -C "$r1" rev-parse HEAD:pic.bin)
out=$(run_build "$r1")
assert_eq       "§1 build exits 0"                               "${out%%|*}" "0"
assert_eq       "§1 the binary's bytes are unchanged"            "$(git -C "$r1" hash-object pic.bin)" "$before"
assert_contains "§1 control: the TEXT file was scrubbed"         "$(cat "$r1/note.txt")" "public-thing"
assert_contains "§1 the build says what it checked"              "${out#*|}" "1 binary file(s) byte-checked"

# ── §2 ───────────────────────────────────────────────────────────────────
echo '=== §2 an unreviewed or changed binary stops the build (exit 11) ==='
r2=$(fixture r2)
out=$(run_build "$r2")
assert_eq       "§2 no review row: exit 11"                      "${out%%|*}" "11"
assert_contains "§2 …naming the file as UNREVIEWED"              "${out#*|}" "UNREVIEWED  pic.bin"
r2b=$(fixture r2b)
printf 'binary\tpic.bin\t%040d\tstale\n' 0 > "$r2b/pm/binaries.tsv"
( cd "$r2b" && git add -A && git commit -qm stale ) >/dev/null 2>&1
out=$(run_build "$r2b")
assert_eq       "§2 review at another sha: exit 11"              "${out%%|*}" "11"
assert_contains "§2 …naming it CHANGED"                          "${out#*|}" "CHANGED     pic.bin"

# ── §3 ───────────────────────────────────────────────────────────────────
echo '=== §3 a scrub that breaks a parseable file stops the build (exit 10) ==='
# The replacement carries an unbalanced `(`: legal in prose, fatal in code.
for kind in sh py json yml; do
    r=$(fixture "r3$kind"); review "$r"
    printf 'map\tqzx\tpublic(thing\n' > "$r/pm/mapping.tsv"
    printf 'exclude\tpm/mapping.tsv\n' >> "$r/pm/mapping.tsv"
    case $kind in
        sh)   printf '#!/usr/bin/env bash\necho qzx\n'     > "$r/code.sh" ;;
        py)   printf 'x = 1 + qzx\n'                       > "$r/code.py" ;;
        json) printf '{"qzx": 1}\n'                        > "$r/code.json"
              printf 'map\t"qzx"\tqzx\n' > "$r/pm/mapping.tsv"   # strip the quotes: key becomes bare
              printf 'exclude\tpm/mapping.tsv\n' >> "$r/pm/mapping.tsv" ;;
        yml)  printf 'a: [qzx]\n'                          > "$r/code.yml"
              printf 'map\tqzx]\tqzx\n' > "$r/pm/mapping.tsv"    # drop the closing bracket
              printf 'exclude\tpm/mapping.tsv\n' >> "$r/pm/mapping.tsv" ;;
    esac
    ( cd "$r" && git add -A && git commit -qm code ) >/dev/null 2>&1
    out=$(run_build "$r")
    assert_eq       "§3 $kind: exit 10"                          "${out%%|*}" "10"
    assert_contains "§3 $kind: …naming the file"                 "${out#*|}" "code.$kind"
done

# ── §4 ───────────────────────────────────────────────────────────────────
echo '=== §4 a file that did not parse in SOURCE is not a regression ==='
r4=$(fixture r4); review "$r4"
printf '#!/usr/bin/env bash\nif then qzx\n' > "$r4/fixture-broken.sh"
( cd "$r4" && git add -A && git commit -qm broken ) >/dev/null 2>&1
out=$(run_build "$r4")
assert_eq       "§4 build exits 0"                               "${out%%|*}" "0"
assert_not_contains "§4 …and reports no regression"              "${out#*|}" "PARSE REGRESSION"

# ── §5 ───────────────────────────────────────────────────────────────────
echo '=== §5 verify-build.py alone catches a rewritten binary ==='
r5=$(fixture r5); review "$r5"
perl -0777 -pi -e 's/qzx/public-thing/gi' "$r5/pic.bin"     # what the old build did
o5=$( cd "$r5" && python3 pm/verify-build.py pm/binaries.tsv 2>&1 ); rc5=$?
assert_eq       "§5 exit 11"                                     "$rc5" "11"
assert_contains "§5 …naming the file as REWRITTEN"               "$o5" "REWRITTEN   pic.bin"
o5c=$( cd "$r1" && git add -A >/dev/null 2>&1; python3 pm/verify-build.py /nonexistent.tsv 2>&1 ); rc5c=$?
assert_eq       "§5 control: an absent list is 'nothing reviewed', so a binary still fails (11)" "$rc5c" "11"

# EXPECTED-COUNT GUARD.
#   §1 4 · §2 4 · §3 8 · §4 2 · §5 3
EXPECTED=$(( 4 + 4 + 8 + 2 + 3 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
