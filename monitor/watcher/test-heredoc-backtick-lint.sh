#!/usr/bin/env bash
# test-heredoc-backtick-lint.sh — no BODY line of a heredoc whose delimiter is
# UNQUOTED may carry an unescaped backtick (your-org/nexus-code#1555; the #1157
# BACKTICK-SUBSTITUTION class, reaching fixture stubs and usage text).
#
# An unquoted delimiter makes bash EXPAND the body, so a backticked word — the
# most natural thing to write in an explanatory comment inside a generated stub
# — is COMMAND-SUBSTITUTED when the heredoc is evaluated: the word is run, its
# text is deleted from what gets written, `cat` still returns 0, and the only
# evidence is one `command not found` on stderr. When the word IS a command it
# runs for real; #1117 was this construct reaching the operator's live tmux.
#
# WHY A LINT AND NOT JUST THE FIX. On enrolment this found SEVEN sites in four
# files, and the two that were reported are not the instructive ones:
#   - monitor/spawn-worker.sh's --help text ran `ng wrap-up` on every usage
#     print — PRODUCT code, in a heredoc whose other backticks were escaped;
#   - monitor/watcher/test-respawn.sh carried, twice, a comment reading "NO
#     BACKTICKS IN THIS HEREDOC … six `command not found` lines" — the warning
#     against the defect WAS the defect, which is what a convention enforced by
#     prose looks like after one edit.
# And the cost is not the noise: test-cc-auto-update.sh's 19 stray stderr lines
# landed AFTER its failing assertion and filled run-tests.sh's 20-line failure
# tail exactly, so a promotion blocker was unreadable for an evening (#1561).
#
# THE PARSER IS THE SHARED ONE (`shf_expanding_heredoc_bodies`, the same awk as
# `shf_strip_heredocs` in another mode). A naive `<<WORD` regex was measured
# while writing this: 425 "hits" in 16 files, 418 of them prose, arithmetic
# shifts and `<<` inside quoted strings.
#
# ERROR DIRECTION, stated because this is a predicate over source text:
#   UNDER-reports (a) a file the shared parser cannot parse — those are counted
#     and must be EXACTLY strip-heredocs-failsafe.manifest's set, so a parse
#     that newly fails reddens here instead of shrinking the population; (b) a
#     heredoc fed to something other than a shell evaluation of this file
#     (`bash -c "$(cat <<EOF …)"` assembled at runtime); (c) `$(…)` in a body,
#     which is the same hazard in its DELIBERATE spelling and is out of scope —
#     authors write `$(…)` in an expanding heredoc on purpose, and nobody writes
#     a backtick there on purpose.
#   OVER-reports a body that WANTS its backticks substituted. None exists in the
#     tree at enrolment; the exemption is the in-line marker
#     `heredoc-backtick: intended <why>` on the offending line.
#
# Population: every tracked shell file, by predicate (a *.sh glob misses
# monitor/ng), declared for `ng guards-for-diff`.
# Run: bash monitor/watcher/test-heredoc-backtick-lint.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
# shellcheck source=monitor/shell-files.sh
. "$REPO_ROOT/monitor/shell-files.sh"

_hb_population() {   # every tracked shell file, by predicate
    ( cd "$REPO_ROOT" && git ls-files | while IFS= read -r f; do shf_is_shell "$f" && printf '%s\n' "$f"; done; return 0 )
}
# The lint over ONE file. stdout: `file:line: text` per offending body line.
# rc 0 = parsed (hits or none); rc 3 = the shared parser refused the file, and
# an empty stdout then means NOTHING — the caller must count it, not skip it.
_hb_lint() {   # <file>
    local f="$1" body rc
    body=$(shf_expanding_heredoc_bodies "$f" 2>/dev/null); rc=$?
    (( rc == 0 )) || return 3
    [[ -n "$body" ]] || return 0
    awk -F'\t' -v f="$f" '
        { t = $0; sub(/^[0-9]+\t/, "", t); raw = t
          if (t ~ /heredoc-backtick: intended [^[:space:]]/) next
          gsub(/\\\\/, "", t); gsub(/\\`/, "", t)       # an escaped backtick is literal
          if (index(t, "`")) printf "%s:%d: %s\n", f, $1, raw }' <<<"$body"
    return 0
}
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { _hb_population; printf '%s\n' monitor/shell-files.sh monitor/watcher/_shell_quotes.awk monitor/watcher/strip-heredocs-failsafe.manifest; }
gp_handle "$@"

WORK=$(mktemp -d -t nxhdbt-XXXXXX); trap 'rm -rf "$WORK"' EXIT

echo '=== positive control: the lint SEES a planted site, and ONLY the expanding one ==='
# The plant is written through a QUOTED delimiter so this file does not contain
# the construct it hunts as CODE; the corpus pass below still excludes this file
# for the reason test-backtick-label-lint.sh excludes its own source.
cat > "$WORK/planted.sh" <<'FIX'
#!/usr/bin/env bash
cat > stub <<EOF
# asks the board with `list-windows -a`
echo "an escaped \`word\` is literal"
echo "exempt `date` here"   # heredoc-backtick: intended the stub wants today's date
EOF
cat > stub2 <<'EOF'
# a QUOTED delimiter: `nothing here is expanded`
EOF
cat > stub3 <<-TABBED
	# a dash-form body with `a backtick`
	TABBED
x=$(( 1 << 3 )); echo "a shift is not a heredoc `but this is not a body`"
FIX
hits=$(_hb_lint "$WORK/planted.sh"); hrc=$?
assert_eq "planted: the file parses (rc 0)" "$hrc" "0"
assert_eq "planted: exactly the two expanding-body backtick lines are flagged" "$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l | tr -d ' ')" "2"
assert_contains "planted: the unquoted <<EOF comment line" "$hits" 'planted.sh:3:'
assert_contains "planted: the <<-TABBED body line"         "$hits" 'planted.sh:11:'
assert_not_contains "planted: an ESCAPED backtick is not flagged"            "$hits" 'planted.sh:4:'
assert_not_contains "planted: the marker-exempted line is not flagged"       "$hits" 'planted.sh:5:'
assert_not_contains "planted: a QUOTED-delimiter body is not flagged"        "$hits" 'planted.sh:8:'
assert_not_contains "planted: a backtick OUTSIDE any heredoc is not flagged" "$hits" 'planted.sh:13:'

echo '=== the hazard is REAL: the planted shape deletes its text at rc 0 ==='
# Not a lint assertion — the measurement the lint rests on. If bash ever stopped
# substituting here, the lint would be policing a non-defect.
( cd "$WORK" && bash -c 'cat > out.txt <<EOF
asks with `nx-hdbt-no-such-command -a` here
EOF
echo "rc=$?" >> out.txt' 2>"$WORK/planted.err" )
assert_eq "measured: the backticked text is DELETED from the written file, and cat says rc=0" \
    "$(tr '\n' '|' < "$WORK/out.txt")" "asks with  here|rc=0|"
assert_contains "measured: the only evidence is on stderr" "$(cat "$WORK/planted.err")" "nx-hdbt-no-such-command"

echo '=== a file the parser REFUSES is counted, never read as clean ==='
printf '#!/usr/bin/env bash\ncat <<NEVERCLOSED\n# a `backtick` in a body with no terminator\n' > "$WORK/unterminated.sh"
_hb_lint "$WORK/unterminated.sh" >/dev/null; urc=$?
assert_eq "unterminated heredoc: rc 3, not an empty 'no hits'" "$urc" "3"

echo '=== the corpus ==='
n=0; all=""; refused=""
while IFS= read -r f; do
    [[ -n "$f" && -f "$REPO_ROOT/$f" ]] || continue
    [[ "$f" == monitor/watcher/test-heredoc-backtick-lint.sh ]] && continue
    n=$((n+1))
    h=$(cd "$REPO_ROOT" && _hb_lint "$f"); rc=$?
    if (( rc != 0 )); then refused+="$f"$'\n'; continue; fi
    [[ -n "$h" ]] && all+="$h"$'\n'
done < <(_hb_population)
assert_eq "population is non-vacuous (>= 400 shell files)" "$(( n >= 400 ))" "1"
want_refused=$(grep -v '^[[:space:]]*#' "$_test_dir/strip-heredocs-failsafe.manifest" | sed '/^[[:space:]]*$/d' | sed 's/::.*$//' | LC_ALL=C sort)
assert_eq "the files the parser refused are EXACTLY the failsafe manifest's set (a new refusal is a shrunken population)" \
    "$(printf '%s' "$refused" | sed '/^$/d' | LC_ALL=C sort)" "$want_refused"
assert_eq "#1555 no tracked shell file carries an unescaped backtick in an EXPANDING heredoc body${all:+ — offenders:
$all}" "$(printf '%s' "$all" | grep -c . || true)" "0"
echo
EXPECTED=14
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
