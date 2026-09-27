#!/usr/bin/env bash
# Mirror-only files are carried IN SOURCE and linted there
# (your-org/nexus-code#1557).
#
# Run: bash monitor/watcher/test-public-mirror-overlay-files.sh
# Expected: ALL TESTS PASSED, exit 0.
#
# THE CLASS THIS REMOVES. A file that exists only in the published mirror is
# outside the population of every source-side lint, so each rule added to
# `lint-workflows.py` silently widened what the mirror could get wrong — TD001,
# then AU001 on `pages.yml`, two syncs apart, each caught only because a sync
# happened to run. The remedy is the overlay `file` verb: the file lives under
# `monitor/public-mirror/overlay/files/<public path>` and `build.sh` installs it.
# This suite is the other half — it lints every carried workflow on every run.
#
# THREE PARTS, each answering a different question:
#
#   §1  the REAL manifest: every `file` row follows the `files/<TARGET>` layout,
#       nothing under overlay/files/ is orphaned (carried but never shipped),
#       and every carried workflow lints clean. TODAY THE POPULATION IS ZERO —
#       `pages.yml` has not been pasted in yet (its content lives only on the
#       mirror, which agents may not read) — and the suite says so out loud.
#   §2  the same checker and lint arm on FIXTURES, so a zero in §1 is readable:
#       the enumeration counts a planted row, the layout and orphan checks fire,
#       a clean workflow lints 0 and a planted AU001 lints 1.
#   §3  `build.sh`'s `file` verb in throwaway `git init` repos under mktemp —
#       NEVER against this checkout (#1001).
#
# COVERAGE BOUNDARY. §1 lints the carried file PRE-scrub; the mirror publishes
# it post-scrub. The scrub substitutes identifiers only, so a lint verdict that
# turned on an identifier would differ — none of today's rules does.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
TOOLKIT="$REPO_ROOT/monitor/public-mirror"
LINT="$REPO_ROOT/monitor/lint-workflows.py"
PY="${PYTHON:-python3}"

# overlay_file_rows <manifest> -> "TARGET<TAB>SOURCE<TAB>NF" per `file` row.
# Comments stripped exactly as build.sh strips them.
overlay_file_rows() {
    [ -r "$1" ] || return 0
    grep -v '^[[:space:]]*#' "$1" | awk -F'\t' '$1=="file"{print $2 "\t" $3 "\t" NF}'
}
# carried_files <overlay_dir> -> every regular file under files/, as files/<rel>.
carried_files() {
    [ -d "$1/files" ] || return 0
    ( cd "$1" && find files -type f -print | sort )
}
is_workflow_target() { case "$1" in .github/workflows/*/*) return 1;; .github/workflows/*.yml|.github/workflows/*.yaml) return 0;; esac; return 1; }

. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' monitor/public-mirror/build.sh monitor/public-mirror/scrub.pl \
        monitor/public-mirror/overlay/manifest.tsv monitor/lint-workflows.py
    carried_files "$TOOLKIT/overlay" | sed 's|^|monitor/public-mirror/overlay/|'
}
gp_handle "$@"

for f in build.sh scrub.pl overlay/manifest.tsv; do
    [[ -r "$TOOLKIT/$f" ]] || { echo "missing $TOOLKIT/$f" >&2; exit 2; }
done
[[ -r "$LINT" ]] || { echo "missing $LINT" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl not installed (scrub.pl needs it)"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 77; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pmfiles.XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# check_layout <manifest> <overlay_dir> -> one violation per line, empty = clean.
#   * a `file` row must have exactly three fields and SOURCE == files/<TARGET>
#     (so a workflow row cannot sit outside the directory the lint reads);
#   * every file under overlay/files/ must be named by a row (an orphan LOOKS
#     carried and linted, and never ships).
check_layout() {
    local manifest="$1" odir="$2" t s nf
    while IFS=$'\t' read -r t s nf; do
        [ "$nf" = 3 ] || { echo "malformed row ($nf fields): file $t $s"; continue; }
        [ "$s" = "files/$t" ] || echo "layout: row for $t names SOURCE $s, want files/$t"
        [ -f "$odir/$s" ] || echo "missing: row for $t names SOURCE $s, which does not exist"
    done < <(overlay_file_rows "$manifest")
    local named; named=$(overlay_file_rows "$manifest" | cut -f2)
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        grep -qxF -- "$c" <<<"$named" || echo "orphan: $c is carried under overlay/ but no \`file\` row installs it"
    done < <(carried_files "$odir")
}

# lint_as_published <odir> <target>... -> sets LINT_RC and LINT_OUT. Call it
# directly, never in $( ): a subshell would lose both.
# The workflows are laid into a scratch root at their PUBLISHED path, with the
# repo's other top-level entries symlinked beside them, so lint-workflows.py's
# PF rule (which resolves `run:` edges against the workflow dir's grandparent)
# resolves against the real tree rather than against overlay/files/.
LINT_RC=; LINT_OUT=
_lr_n=0
lint_as_published() {
    local odir="$1"; shift
    _lr_n=$((_lr_n+1))
    local root="${WORK:?}/lintroot.$_lr_n" t e rp wp gp
    # A FRESH root, and `ln -sn`: `ln -s D root/x` onto an existing
    # link-to-a-directory creates the new link INSIDE D — i.e. inside the REAL
    # tree (an early draft called this in $( ), reused the root, and planted
    # config/config, monitor/monitor … in the worktree). Refuse, never follow.
    [ ! -e "$root" ] && [ ! -L "$root" ] || { echo "lint root already exists: $root" >&2; exit 2; }
    mkdir -p "$root/.github/workflows" || { echo "cannot create lint root $root" >&2; exit 97; }
    # The root must resolve INSIDE $WORK and OUTSIDE the repo, or every `ln`
    # below plants a self-link in the real tree. Refuse at 97, like
    # th_require_fixture_repo, so it cannot read as an assertion failure.
    rp=$(cd "$root" && pwd -P); wp=$(cd "$WORK" && pwd -P); gp=$(cd "$REPO_ROOT" && pwd -P)
    case "$rp/" in "$wp"/?*/) ;; *) echo "REFUSED: lint root $rp is not under \$WORK ($wp)" >&2; exit 97;; esac
    case "$rp/" in "$gp"/*) echo "REFUSED: lint root $rp is inside the repo ($gp)" >&2; exit 97;; esac
    for e in "$REPO_ROOT"/* "$REPO_ROOT"/.[!.]*; do
        [ -e "$e" ] || continue
        case "${e##*/}" in .git|.github) continue;; esac
        ln -sn -- "$e" "$root/${e##*/}" || { echo "cannot link $e into the lint root" >&2; exit 2; }
    done
    for t in "$@"; do cp -- "$odir/files/$t" "$root/$t"; done
    LINT_OUT=$("$PY" "$LINT" "$root/.github/workflows" 2>&1); LINT_RC=$?
}

CLEAN_WF='name: pages
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Install test runtime deps (jq + tmux + zsh)
        run: |
          # published by fixtureorg
          sudo rm -f /etc/apt/sources.list.d/google-chrome*
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends jq tmux zsh
'
# The #1557 body verbatim in shape: a bare `sudo apt-get update` with no
# earlier narrowing of /etc/apt/sources.list.d/ in the same body.
AU001_WF=$(printf '%s' "$CLEAN_WF" | grep -vF 'sources.list.d')

# ── §1  THE REAL MANIFEST ───────────────────────────────────────────────
echo '=== §1 the real manifest: layout, orphans, and a lint of every carried workflow ==='
REAL_M="$TOOLKIT/overlay/manifest.tsv"
viol=$(check_layout "$REAL_M" "$TOOLKIT/overlay")
assert_eq "§1 every file row follows files/<TARGET>, and nothing under overlay/files/ is orphaned" "$viol" ""
n_rows=$(overlay_file_rows "$REAL_M" | grep -c . || true)
real_wf=()
while IFS=$'\t' read -r t s nf; do
    is_workflow_target "$t" && real_wf+=("$t")
done < <(overlay_file_rows "$REAL_M")
if (( ${#real_wf[@]} == 0 )); then
    printf '  NOTE: 0 overlay workflows carried (%s file row(s) in the manifest).\n' "$n_rows"
    printf '        .github/workflows/pages.yml is STILL MIRROR-ONLY and unlinted by source\n'
    printf '        until the operator pastes it into overlay/files/.github/workflows/ and\n'
    printf '        adds its `file` row (monitor/public-mirror/README.md). §2 proves this\n'
    printf '        zero comes from a live enumeration, not a blind one.\n'
    printf '  PASS: §1 0 carried workflows — nothing to lint today (stated, not assumed)\n'; _th_pass
else
    lint_as_published "$TOOLKIT/overlay" "${real_wf[@]}"
    if [ "$LINT_RC" = 0 ]; then
        printf '  PASS: §1 %d carried workflow(s) lint clean: %s\n' "${#real_wf[@]}" "${real_wf[*]}"; _th_pass
    else
        printf '  FAIL: §1 carried workflow lint rc %s (0 wanted):\n%s\n' "$LINT_RC" "$LINT_OUT" >&2; _th_fail
    fi
fi

# ── §2  THE SAME CHECKER, ON FIXTURES ───────────────────────────────────
echo '=== §2 the enumeration, layout/orphan checks and lint arm fire on fixtures ==='
FO="$WORK/fixoverlay"
mkdir -p "$FO/files/.github/workflows" "$FO/files/docs"
printf '%s' "$CLEAN_WF" > "$FO/files/.github/workflows/pages.yml"
printf 'doc\n' > "$FO/files/docs/extra.md"
printf '# file\t.github/workflows/commented.yml\tfiles/.github/workflows/commented.yml\n' > "$FO/manifest.tsv"
printf 'file\t.github/workflows/pages.yml\tfiles/.github/workflows/pages.yml\n' >> "$FO/manifest.tsv"
printf 'file\tdocs/extra.md\tfiles/docs/extra.md\n' >> "$FO/manifest.tsv"
printf 'consumer\tREADME.md\t-\n' >> "$FO/manifest.tsv"
fx_wf=()
while IFS=$'\t' read -r t s nf; do is_workflow_target "$t" && fx_wf+=("$t"); done < <(overlay_file_rows "$FO/manifest.tsv")
assert_eq "§2 enumeration: 1 workflow row (a commented row and a non-workflow row are not counted)" "${#fx_wf[@]}" "1"
assert_eq "§2 a well-formed fixture overlay has no layout violations" "$(check_layout "$FO/manifest.tsv" "$FO")" ""

lint_as_published "$FO" "${fx_wf[@]}"
assert_rc "§2 a CLEAN carried workflow lints rc 0" "$LINT_RC" "0"
printf '%s' "$AU001_WF" > "$FO/files/.github/workflows/pages.yml"
lint_as_published "$FO" "${fx_wf[@]}"
assert_rc       "§2 a planted AU001 (bare apt-get update) lints rc 1" "$LINT_RC" "1"
assert_contains "§2 …and the finding is AU001, on pages.yml" "$LINT_OUT" "AU001: pages.yml"

printf 'file\t.github/workflows/stray.yml\tstray.yml\n' >> "$FO/manifest.tsv"
printf 'x\n' > "$FO/stray.yml"
printf 'x\n' > "$FO/files/.github/workflows/orphan.yml"
viol=$(check_layout "$FO/manifest.tsv" "$FO")
assert_contains "§2 a row whose SOURCE escapes files/<TARGET> is flagged" "$viol" "layout: row for .github/workflows/stray.yml"
assert_contains "§2 a carried file no row installs is flagged as an orphan" "$viol" "orphan: files/.github/workflows/orphan.yml"

# ── §3  build.sh's `file` VERB, IN THROWAWAY REPOS ──────────────────────
#
# Toolkit copied to pm/ inside each fixture, overlay at pm/overlay/ and
# EXCLUDED — the production shape, so "the source copy is dropped and the
# installed copy survives" is tested rather than assumed.
fixture() {   # <name> <manifest-body> -> repo path
    local repo="$WORK/$1"
    mkdir -p "$repo/pm/overlay/files/.github/workflows" "$repo/secret"
    cp "$TOOLKIT/scrub.pl" "$TOOLKIT/build.sh" "$repo/pm/"
    cat > "$repo/pm/mapping.tsv" <<'MAP'
map	fixtureorg	public-org	<public-org>
deny	fixtureorg
keep	public-org
exclude	pm/mapping.tsv
exclude	pm/overlay
exclude	secret
MAP
    printf '%s' "$2" > "$repo/pm/overlay/manifest.tsv"
    printf '%s' "$CLEAN_WF" > "$repo/pm/overlay/files/.github/workflows/pages.yml"
    printf 'source file that must not be shadowed\n' > "$repo/existing.txt"
    printf 'excluded\n' > "$repo/secret/keep.txt"
    ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
        && git add -A && git commit -qm init ) >/dev/null 2>&1
    printf '%s' "$repo"
}
run_build() {   # <repo> <args...> -> "<rc>|<output>"
    local repo="$1"; shift
    th_require_fixture_repo "$repo" "build.sh fixture"
    local o rc
    o=$( cd "$repo" && bash pm/build.sh "$@" 2>&1 ); rc=$?
    printf '%s|%s' "$rc" "$o"
}
ROW=$'file\t.github/workflows/pages.yml\tfiles/.github/workflows/pages.yml\n'

echo '=== §3a a file row installs the carried file at its public path ==='
r=$(fixture install "$ROW")
out=$(run_build "$r" --yes)
assert_eq          "§3a build exits 0"                                "${out%%|*}" "0"
assert_contains    "§3a …reporting the install"                       "${out#*|}" "overlay file installed at .github/workflows/pages.yml"
assert_contains    "§3a …and the verified count"                      "${out#*|}" "1 overlay file(s) installed + verified"
assert_file_exists "§3a the file is at TARGET"                        "$r/.github/workflows/pages.yml"
assert_contains    "§3a …SCRUBBED (it went through the scrub loop)"   "$(cat "$r/.github/workflows/pages.yml" 2>/dev/null)" "published by <public-org>"
assert_not_contains "§3a …with no denied token left"                  "$(cat "$r/.github/workflows/pages.yml" 2>/dev/null)" "fixtureorg"
tracked=$(git -C "$r" ls-files -- .github/workflows/pages.yml)
assert_eq          "§3a …and in the INDEX, so write-tree publishes it" "$tracked" ".github/workflows/pages.yml"
assert_no_file     "§3a the overlay source copy is dropped (excluded)" "$r/pm/overlay"

echo '=== §3b a missing SOURCE exits 4 ==='
r=$(fixture nosrc $'file\t.github/workflows/pages.yml\tfiles/.github/workflows/nope.yml\n')
out=$(run_build "$r" --yes)
assert_eq       "§3b missing SOURCE exits 4"      "${out%%|*}" "4"
assert_contains "§3b …naming the missing SOURCE"   "${out#*|}" "SOURCE missing"
assert_no_file  "§3b …and nothing was installed"   "$r/.github/workflows/pages.yml"

echo '=== §3c a TARGET that exists in source is refused (no shadowing) ==='
r=$(fixture shadow $'file\texisting.txt\tfiles/.github/workflows/pages.yml\n')
out=$(run_build "$r" --yes)
assert_eq       "§3c existing TARGET exits 4"             "${out%%|*}" "4"
assert_contains "§3c …refusing to shadow a source file"    "${out#*|}" "refusing to shadow a source file"
assert_eq       "§3c …and the source file is untouched"    "$(cat "$r/existing.txt")" "source file that must not be shadowed"

echo '=== §3d malformed rows and unsafe targets exit 4 ==='
r=$(fixture trunc $'file\t.github/workflows/pages.yml\n')
out=$(run_build "$r" --yes)
assert_eq       "§3d a truncated row (no SOURCE) exits 4"  "${out%%|*}" "4"
assert_contains "§3d …as malformed"                       "${out#*|}" "malformed overlay file row"
r=$(fixture extra $'file\t.github/workflows/pages.yml\tfiles/.github/workflows/pages.yml\tsurplus\n')
out=$(run_build "$r" --yes)
assert_eq       "§3d a row with an extra field exits 4"   "${out%%|*}" "4"
r=$(fixture escape $'file\t../escape.txt\tfiles/.github/workflows/pages.yml\n')
out=$(run_build "$r" --yes)
assert_eq       "§3d a ../ TARGET exits 4"                "${out%%|*}" "4"
assert_no_file  "§3d …and nothing was written outside the tree" "$WORK/escape.txt"
r=$(fixture typo $'flie\t.github/workflows/pages.yml\tfiles/.github/workflows/pages.yml\n')
out=$(run_build "$r" --yes)
assert_eq       "§3d a misspelt verb exits 4 (not a silent skip)" "${out%%|*}" "4"
assert_contains "§3d …naming the unknown verb"            "${out#*|}" "unknown overlay manifest verb 'flie'"

echo '=== §3e a TARGET that would not reach the output exits 4 ==='
r=$(fixture swallowed $'file\tsecret/new.yml\tfiles/.github/workflows/pages.yml\n')
out=$(run_build "$r" --yes)
assert_eq       "§3e an excluded TARGET exits 4"          "${out%%|*}" "4"
assert_contains "§3e …refused at install, by name"        "${out#*|}" "inside the excluded path secret"
r=$(fixture renamed "$ROW")
printf 'rename\t.github/workflows/pages.yml\t.github/workflows/moved.yml\n' > "$r/pm/overlay/renames.tsv"
( cd "$r" && git add -A && git commit -qm renames ) >/dev/null 2>&1
out=$(run_build "$r" --yes)
assert_eq       "§3e a TARGET renamed away exits 4"       "${out%%|*}" "4"
assert_contains "§3e …because the file did not survive"   "${out#*|}" "overlay file absent from the output: .github/workflows/pages.yml"

echo '=== §3f controls: consumer/comment rows still build; the dry run counts file rows ==='
r=$(fixture nofile $'# file\tx.yml\tfiles/x.yml\nconsumer\tREADME.md\t-\n')
out=$(run_build "$r" --yes)
assert_eq       "§3f a manifest with only consumer + comment rows exits 0" "${out%%|*}" "0"
assert_contains "§3f …installing nothing"                  "${out#*|}" "0 overlay file(s) installed + verified"
r=$(fixture dry "$ROW")
out=$(run_build "$r")
assert_eq       "§3f without --yes it is a dry run (exit 6)" "${out%%|*}" "6"
assert_contains "§3f …announcing the file row"              "${out#*|}" "would install : 1 overlay file(s)"
assert_no_file  "§3f …and installing nothing"               "$r/.github/workflows/pages.yml"

echo '=== §3g a STAGED, uncommitted overlay edit still drops cleanly (--allow-dirty) ==='
# The dictionary-coverage suite `git add`s the author's uncommitted diff before
# building, so an overlay edit (e.g. adding a `file` row) is STAGED; the scrub
# then rewrites it, and a plain `git rm --cached` refuses the drop — exit 3 on a
# correct build. Found by that suite on this change's own manifest edit.
r=$(fixture staged "$ROW")
printf '# a note naming fixtureorg\n' >> "$r/pm/overlay/manifest.tsv"
git -C "$r" add -- pm/overlay/manifest.tsv
out=$(run_build "$r" --yes --allow-dirty)
assert_eq       "§3g a staged overlay edit builds (exit 0, not 3)" "${out%%|*}" "0"
# The INDEX, not the disk: `rm -rf` empties the disk even when the index drop
# fails, so an on-disk check cannot see this defect (a mutation round measured it).
assert_eq       "§3g …and the overlay is dropped from the INDEX"   "$(git -C "$r" ls-files -- pm/overlay)" ""

# ── LEAK DETECTOR ───────────────────────────────────────────────────────
# An early draft of lint_as_published planted <entry>/<entry> self-links in the
# real tree (every top-level dir, tracked and ignored alike). Assert none exist.
echo '=== leak detector: no <entry>/<entry> self-link in the repo ==='
leaks=""
for e in "$REPO_ROOT"/* "$REPO_ROOT"/.[!.]*; do
    [ -d "$e" ] && [ ! -L "$e" ] || continue
    [ -L "$e/${e##*/}" ] && leaks+=" ${e#$REPO_ROOT/}/${e##*/}"
done
assert_eq "no top-level <entry>/<entry> self-link exists in the repo" "$leaks" ""

# EXPECTED-COUNT GUARD.
#   §1 2 · §2 7 · §3a 8 · §3b 3 · §3c 3 · §3d 7 · §3e 4 · §3f 5 · §3g 2 · leak 1
EXPECTED=$(( 2 + 7 + 8 + 3 + 3 + 7 + 4 + 5 + 2 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
