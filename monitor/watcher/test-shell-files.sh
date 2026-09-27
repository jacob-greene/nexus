#!/usr/bin/env bash
# test-shell-files.sh — the shared shell-file derivation (your-org/nexus-code#792).
#
# `monitor/shell-files.sh` answers ONE question — "is this file a shell file?" —
# for the two cc-harness kill guards and the watcher's ambient-option scope
# guard. Before it existed the question had four independent implementations
# and four different answers, and three of them were blind to `monitor/ng`.
#
# WHAT THIS SUITE IS ACTUALLY FOR, stated because it is not the obvious thing:
# it is not here to check that `shf_class` returns the right string. It is here
# to pin the property the whole issue turns on —
#
#   **an extensionless executable added TOMORROW is covered with nobody
#   remembering to add it.**
#
# The rejected fix was `find … \( -name '*.sh' -o -name 'ng' \)`, a one-element
# allowlist. It passes any test that only asks about files that exist today. So
# the decisive fixtures below plant files under names that appear NOWHERE in
# this repo — `brand-new-tool`, `future-thing` — and a list-based enumerator
# cannot pass them however long the list.
#
# ASSERTION SHAPE. Almost every assertion here is POSITIVE: it names something
# that must be FOUND. `#793`(b) is the reason — a guard built out of absences
# ("X is not in the output") is satisfied by an enumerator that produced no
# output at all, which is the exact failure being guarded against. Where an
# absence IS the property under test (a non-script must not be classified), it
# is paired with a positive twin on byte-identical content, so the pair can only
# both pass if the classifier genuinely discriminates.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_self_dir/../.." && pwd)
LIB="$REPO_ROOT/monitor/shell-files.sh"

[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

TMP=$(mktemp -d -t shf-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ── THE TWO LIVE-TREE SWEEPS, AS NAMED ENUMERATORS ─────────────────────────
#
# Extracted (your-org/nexus-code#1301) so `gp_population` can CALL them rather
# than restate what they currently return. The protocol's one rule: a copy is a
# second implementation of the population, and a second implementation drifts —
# at which point the index reports, with total confidence, that this guard does
# not read a file it does read.
#
# This guard's population really is repo-wide, and that is exactly why it is
# worth declaring: `_shf_all_files` reads the first bytes of every executable
# regular file under `monitor/` in order to reach its shebang-gap verdict, so
# ADDING A FILE ANYWHERE UNDER `monitor/` can redden it. #1301's argument for
# enrolling this class is that declaring FEELS redundant for precisely the
# guards whose reach is widest, which is how they end up invisible to the index.
_shf_glob_files() {
    find "$REPO_ROOT/monitor" -type f \
        \( -name '*.sh' -o -name '*.zsh' -o -name '*.bash' \)
}
# NUL-separated: the sweep below feeds a `read -d ''` loop, and -print0 is why a
# filename containing a newline cannot split into two. `gp_population` converts;
# the ASSERTION path keeps the safe form.
_shf_all_files0() {
    find "$REPO_ROOT/monitor" \
        \( -name .git -o -name .state -o -name node_modules \) -prune -o \
        -type f -print0
}

# The four consumers §7 reads with `cat`, named once and reused there.
_SHF_CONSUMERS=(
    monitor/cc-harness/lint-no-tmux-server-kill.sh
    monitor/cc-harness/lint-no-mass-kill.sh
    monitor/watcher/test-ambient-shell-option-scope.sh
    monitor/watcher/early-exit-readers.sh
)

# `gp_handle` EXITS when it handles `--population`, so it stands above the first
# line of output: anything printed before it lands in the probe's stdout and is
# read as a population row (your-org/nexus-code#1193).
# shellcheck disable=SC1091
. "$_self_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$LIB"
    _shf_all_files0 | tr '\0' '\n'
    ( cd "$REPO_ROOT" && printf '%s\n' "${_SHF_CONSUMERS[@]}" )
}
gp_handle "$@"

_plant() {   # <name> <content> -> path
    printf '%s\n' "$2" > "$TMP/$1"
    printf '%s' "$TMP/$1"
}

# --- 1. the self-maintaining arm -------------------------------------------
echo "=== arm 2 (shebang): a file nobody enumerated is classified anyway ==="

# THE DECISIVE ONE. Nothing in this repo names `brand-new-tool`. A list cannot
# pass this; a derivation cannot fail it.
assert_eq "an extensionless bash executable nobody has heard of is 'shell'" \
    "$(shf_class "$(_plant brand-new-tool '#!/usr/bin/env bash
echo hi')")" shell

assert_eq "…and so is the next one, under a different unknown name" \
    "$(shf_class "$(_plant future-thing '#!/bin/sh
echo hi')")" shell

assert_eq "a direct #!/bin/bash path resolves" \
    "$(shf_class "$(_plant direct-bash '#!/bin/bash
:')")" shell
assert_eq "a zsh shebang resolves" \
    "$(shf_class "$(_plant zsh-tool '#!/usr/bin/env zsh
:')")" shell

# `env -S` is the shape that defeats a naive "the word after env" read: that
# read returns `-S`, matches no interpreter, and drops the file SILENTLY —
# which is the failure mode of the whole issue in miniature.
assert_eq "env -S does not swallow the interpreter" \
    "$(shf_class "$(_plant env-s-tool '#!/usr/bin/env -S bash -e
:')")" shell
assert_eq "an env VAR=value assignment does not swallow the interpreter" \
    "$(shf_class "$(_plant env-var-tool '#!/usr/bin/env LC_ALL=C bash
:')")" shell
# The two OTHER GNU spellings of `-S bash` carry the command INSIDE the option
# token (your-org/nexus-code#1409). Both used to return rc 1 — EXCLUDED, the
# unsafe direction — while the spaced `-S bash` control above passed, so a
# probe that tested only the control could not see them.
assert_eq "env --split-string=bash (long, attached) resolves the interpreter" \
    "$(shf_class "$(_plant env-split-long '#!/usr/bin/env --split-string=bash -e
:')")" shell
assert_eq "env -Sbash (short, attached) resolves the interpreter" \
    "$(shf_class "$(_plant env-s-attached '#!/usr/bin/env -Sbash -e
:')")" shell
assert_eq "env --split-string bash (long, detached) resolves the interpreter" \
    "$(shf_class "$(_plant env-split-detached '#!/usr/bin/env --split-string bash
:')")" shell
assert_eq "env -Spython3 (attached) resolves to python, not shell — the peel keeps the vocabulary" \
    "$(shf_class "$(_plant env-s-attached-py '#!/usr/bin/env -Spython3 -u
:')")" python

# A CRLF first line yields an interpreter of `bash<CR>` unless the CR is
# stripped, which matches nothing and excludes the file with no diagnostic.
printf '#!/usr/bin/env bash\r\n:\r\n' > "$TMP/crlf-tool"
assert_eq "a CRLF shebang still resolves (the CR is stripped)" \
    "$(shf_class "$TMP/crlf-tool")" shell

# --- 2. discrimination — inclusion must be EARNED --------------------------
echo "=== the classifier discriminates (it does not just say yes) ==="
#
# Each of these is byte-identical in body to something classified `shell`
# above. If the classifier were broken into accepting everything, arm-2's
# passes would be worthless — these are what make them mean something.
assert_eq "no shebang, no extension, no startup name => not a script" \
    "$(shf_class "$(_plant plain-notes 'echo hi')" || echo NONE)" NONE
assert_eq "a non-shell shebang => not 'shell'" \
    "$(shf_class "$(_plant ruby-tool '#!/usr/bin/env ruby
:')" || echo NONE)" NONE
assert_eq "a python shebang classifies as python, not shell" \
    "$(shf_class "$(_plant py-tool '#!/usr/bin/env python3
pass')")" python
assert_eq "a perl shebang classifies as perl, not shell" \
    "$(shf_class "$(_plant pl-tool '#!/usr/bin/env perl
1;')")" perl
assert_eq "a bare '#' comment first line is not a shebang" \
    "$(shf_class "$(_plant hash-only '# just a comment
5.2')" || echo NONE)" NONE

# Arm 0 — transient junk. An extension glob excluded these for free; a shebang
# derivation does not, because they are byte-copies carrying a real shebang.
# This is not hypothetical: an NFS silly-rename artifact entered the population
# mid-run and made the residue manifest disagree with itself between two
# invocations seconds apart.
for j in '.nfs00000007821bbd2e00060460' 'tool.sh~' 'tool.sh.orig' 'tool.sh.bak'; do
    assert_eq "transient junk '$j' is excluded despite a real shebang" \
        "$(shf_class "$(_plant "$j" '#!/usr/bin/env bash
:')" || echo NONE)" NONE
done

# `monitor/ci-bash-version` is the live instance of that last one: a data file
# whose first line is a comment. It must NOT enter any lint's population.
assert_eq "monitor/ci-bash-version (data, '#' but no '!') is not a script" \
    "$(shf_class "$REPO_ROOT/monitor/ci-bash-version" || echo NONE)" NONE

# --- 3. arm 1 (extension) ---------------------------------------------------
echo "=== arm 1 (extension): sourced libraries carry no shebang ==="
#
# Arm 2 alone would be a plausible-sounding and badly wrong derivation: the
# majority of this repo's shell corpus is SOURCED libraries, which are never
# executed and frequently have no shebang at all. This pins that arm 1 is
# load-bearing rather than legacy.
assert_eq "a .sh library with NO shebang is still 'shell'" \
    "$(shf_class "$(_plant lib_no_shebang.sh '_f() { :; }')")" shell
assert_eq "watcher/_lib.sh (real, sourced) is 'shell'" \
    "$(shf_class "$REPO_ROOT/monitor/watcher/_lib.sh")" shell

# --- 4. arm 3 (startup files) ----------------------------------------------
echo "=== arm 3 (startup names): no extension AND no shebang ==="
#
# The one arm that is a list, and it owes an argument (see the header): its
# vocabulary is fixed by bash's and zsh's documented startup sequences, which
# this repo does not get a vote in. Adding a FILE can never add a startup-file
# NAME, so it cannot rot the way `-o -name 'ng'` rotted. Pinned so that
# growing it is a deliberate, reviewed edit.
for n in .zshenv .zshrc .zprofile .zlogin .bashrc .bash_profile .profile; do
    assert_eq "startup file '$n' is 'shell'" \
        "$(shf_class "$(_plant "$n" 'export PATH=/x:$PATH')")" shell
done
# And the four live ones, by path, so this is a claim about the tree.
for n in .zshenv .zshrc .zprofile .zlogin; do
    assert_eq "the LIVE monitor/shellenv/$n is 'shell'" \
        "$(shf_class "$REPO_ROOT/monitor/shellenv/$n")" shell
done

# --- 5. the #792 population, on the real tree -------------------------------
echo "=== the eleven files every '*.sh' glob was blind to ==="
#
# Positive membership, one assertion per file. Listing them here is NOT the
# rotting kind of list: this is a test asserting that a DERIVATION covers known
# members, not an enumerator deriving its answer from a list. If a twelfth
# appears, the derivation covers it and this file simply does not mention it —
# which is the correct behaviour and the difference the whole issue is about.
_ext_less=$(bash "$LIB" --extensionless "$REPO_ROOT/monitor")
for f in ng ghwrap/gh pipwrap/pip notifywrap/sandbox-notify \
         client/nexus-request client/nexus-reply-watch git-https-setup \
         shellenv/.zshenv shellenv/.zshrc shellenv/.zprofile shellenv/.zlogin; do
    assert_contains "monitor/$f is in the derived shell population" \
        "$_ext_less" "monitor/$f"
done

# `pipwrap/pip3` is a SYMLINK to `pipwrap/pip`. Excluded by `-type f`, and
# deliberately: scanning both would double-report every hit in that file.
assert_not_contains "the pip3 SYMLINK is not double-counted" \
    "$_ext_less" "pipwrap/pip3"

# --- 6. NON-VACUITY ---------------------------------------------------------
echo "=== non-vacuity: an enumeration that found nothing must be LOUD ==="
#
# The floor is the backstop for every consumer. It is asserted in both
# directions, because a floor that cannot be observed failing is not evidence —
# the same argument the tmux lint's `--selftest` makes about itself.
_n_shell=$(shf_count "$REPO_ROOT/monitor" shell)
_n_script=$(shf_count "$REPO_ROOT/monitor" script)
_n_glob=$(_shf_glob_files | wc -l)

assert_eq "the derived population clears its floor" \
    "$(shf_require_floor "$REPO_ROOT/monitor" shell 300 t >/dev/null 2>&1 \
        && echo ok || echo short)" ok
assert_eq "…and the floor is observed FAILING when set above the truth" \
    "$(shf_require_floor "$REPO_ROOT/monitor" shell 99999 t >/dev/null 2>&1 \
        && echo ok || echo short)" short

# The derivation must be a strict SUPERSET of the old glob — never a
# replacement that quietly drops members. Sanity-checked against a known total
# rather than asserted, because a count behind a claim is exactly where this
# repo's silent zeros live.
assert_eq "the derived population strictly EXCEEDS the old *.sh glob ($_n_shell > $_n_glob)" \
    "$(( _n_shell > _n_glob ))" 1
assert_eq "the script class is at least the shell class ($_n_script >= $_n_shell)" \
    "$(( _n_script >= _n_shell ))" 1

_missing=0
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    shf_is_shell "$f" || { echo "    NOT covered: $f" >&2; _missing=$((_missing+1)); }
done < <(_shf_glob_files)
assert_eq "every file the OLD glob saw is still seen (no silent regression)" \
    "$_missing" 0

# THE DECLARED GAP, RE-MEASURED ON THE LIVE TREE (your-org/nexus-code#799
# skeptic, F-3). `shell-files.sh`'s boundary note names "executed as
# `bash somefile` with no shebang and no shell name" as its unsafe-direction
# gap and claims zero live occurrences. That claim used to point at the fixture
# assertion above — which exercises the CLASSIFIER on a planted file, i.e. it
# checks the gap EXISTS, not that nothing falls into it. A prose promise about
# a check that did not exist, in the file arguing prose cannot be made to fail.
#
# This is the check. An executable regular file that `shf_class` cannot
# classify is a candidate for the gap. Sanity-checked against a known total in
# the same breath, because a count behind a claim is exactly where this repo's
# silent zeros live: a broken scan would report `0 unclassified` AND
# `0 scanned`, and only the second number gives it away.
_unclassified=""; _scanned=0; _longest=0; _longest_path=""; _fl=""
while IFS= read -r -d '' f; do
    _scanned=$(( _scanned + 1 ))
    # THE READ BOUND, PINNED ON THE LIVE TREE (your-org/nexus-code#1407).
    #
    # `shf_interpreter` used to be `read -r -n 200`, whose comment promised
    # that "a binary file with no newline cannot make this read a gigabyte".
    # `-n` is a bash spelling that yields EMPTY under zsh (#1338), so the fix
    # reads a whole LINE and truncates afterwards — which drops that bound.
    # Measured on a 20 MB newline-free file: old 0.00s / 3,388 kB maxrss,
    # new 1.67s / 64,856 kB. Unreachable on today's corpus (longest first
    # line repo-wide 297 bytes; zero files without a newline) — and
    # "unreachable today" is a statement about the CORPUS, not the code.
    #
    # That promise now lives in PROSE, in the file whose own header argues
    # prose cannot be made to fail. This is the same shape as the #799 F-3
    # finding directly above, one release apart in the same file, so it gets
    # the same remedy: measure the live tree rather than a fixture.
    #
    # Measured with the SAME primitive the predicate uses, so this is the
    # actual exposure and not a proxy for it.
    IFS= read -r _fl < "$f" 2>/dev/null || _fl=""
    if (( ${#_fl} > _longest )); then _longest=${#_fl}; _longest_path="$f"; fi
    [[ -x "$f" ]] || continue
    shf_class "$f" >/dev/null 2>&1 || _unclassified+="$f"$'\n'
done < <(_shf_all_files0 2>/dev/null)
assert_eq "the live-tree sweep examined a real population (not a silent zero)" \
    "$(( _scanned > 400 ))" 1
assert_empty "no executable file on the tree falls into the declared shebang gap ($_scanned scanned)" \
    "$_unclassified"
# Ceiling with headroom over the measured 297, low enough that a vendored blob
# or captured binary fixture trips it. A ratchet, not an inventory: it fails
# when the corpus changes, which is the property the prose could not have.
assert_eq "no file's first line exceeds 4096 B, so the unbounded read stays bounded in fact (longest ${_longest} B at ${_longest_path:-none}; $_scanned scanned)" \
    "$(( _longest <= 4096 ))" 1

# --- 7. the consumers actually use it ---------------------------------------
echo "=== the shared helper is SHARED (not a fourth implementation) ==="
#
# `#775`'s lesson: two implementations of one notion drift into the identical
# bug, and they did. The point of this file is defeated if a consumer keeps its
# own `find`. So assert the consumers source it, and assert no consumer still
# carries the one-element allowlist that prompted the issue.
for c in "${_SHF_CONSUMERS[@]}"; do
    assert_contains "$c sources the shared enumerator" \
        "$(cat "$REPO_ROOT/$c")" 'shell-files.sh'
done

# The literal pattern `#792` was filed about, asserted absent from the
# consumers' CODE.
#
# DATA IS NOT CODE — and this assertion learned that the hard way, on its first
# run, against its own author. Every one of those files now DISCUSSES
# `-name 'ng'` in its header, because explaining why the one-element allowlist
# was rejected is the substance of the fix. Matching raw text therefore reported
# a violation in the very commit that removed the last real one. Full-line
# comments are stripped first, exactly as `_tmux_kill_scan.awk` and `_aso_code`
# do it, and for the same reason: making authors avoid naming a banned idiom in
# prose is how a guard decays into something people route around.
_strip_comments() { sed -E 's/^[[:space:]]*#.*$//' "$@"; }
_consumers=$(_strip_comments "$REPO_ROOT/monitor/cc-harness/lint-no-tmux-server-kill.sh" \
                             "$REPO_ROOT/monitor/cc-harness/lint-no-mass-kill.sh" \
                             "$REPO_ROOT/monitor/watcher/early-exit-readers.sh" \
                             "$REPO_ROOT/monitor/watcher/test-ambient-shell-option-scope.sh")
# Non-vacuity on the corpus itself: an empty haystack satisfies any
# `assert_not_contains`, which is the vacuity `#793`(b) is about. Pin that the
# strip left real code behind before trusting the absence below.
assert_eq "the corpus read for the next assertion is non-empty after stripping" \
    "$(( $(printf '%s' "$_consumers" | wc -c) > 20000 ))" 1
assert_contains "…and still contains real code" "$_consumers" 'shf_'
assert_not_contains "no consumer still carries the one-element allowlist" \
    "$_consumers" "-name 'ng'"

# ── BRACKET DEPTH SURVIVES THE NEWLINE (your-org/nexus-code#1227) ───────
# `quote_mask` carried the QUOTE state across lines (`inq0`/`QM_END`) but not
# the `$( … )` NESTING — `sp`/`stack`/`depth` were function-locals and reset on
# every call. The consequence is not a lost `)`: on the next line that `)` is
# read as an ordinary character, so the following `"` OPENS a string instead of
# CLOSING one, every later line reads as quoted, `#` is skipped as text, and
# THE REST OF THE FILE'S COMMENTS ARE EMITTED AS CODE. Measured before the fix:
# 2,661 comment lines across 81 of 584 shell files; `monitor/ng:1129` is the
# live instance and the issue's named fixture.
#
# KEYED ON THE INVARIANT THE ISSUE STATES, not on the carry's spelling: a file
# with an unbalanced `$(` at a line boundary must not have its subsequent
# comment lines classified as code.
_b1227="$TMP/b1227.sh"
cat > "$_b1227" <<'B1227'
#!/usr/bin/env bash
die "$(printf 'usage %s\nmore %s' \
        "$(f "$x")" "$x")"
# CANARY_1227_MUST_NOT_SURVIVE
echo hi
B1227
_out1227=$(shf_strip_comments "$_b1227" 2>/dev/null)
assert_not_contains "an open \$( at a newline does not leak later comments as code" \
    "$_out1227" "CANARY_1227_MUST_NOT_SURVIVE"
# NON-VACUITY: the same stripper must still emit the real code around it, or the
# absence above would be satisfied by an empty haystack (#793(b)).
assert_contains "…and the real code on both sides survives the strip" \
    "$_out1227" "echo hi"
assert_contains "…including the line that opens the substitution" \
    "$_out1227" "printf"

# ── A BACKSLASH OUTSIDE QUOTES ESCAPES THE NEXT CHARACTER (#1227 residue) ──
# The `'…'\''…'` idiom — close, escaped literal quote, reopen — carries an
# apostrophe through a single-quoted string. Read without the escape rule the
# scanner OPENS a string at the escaped quote and is inverted for the rest of
# the file: every later comment survives as code. Measured at 8ba5060e:
# monitor/ng:11436 carried this shape and the 33 column-0 comment lines after
# it were classified as code; corpus-wide the leak was concentrated in exactly
# the files dense with printf messages. Keyed on the invariant, not the
# spelling: after `\'` and `\"` OUTSIDE any quote, a comment is a comment.
_b1227b="$TMP/b1227-backslash.sh"
cat > "$_b1227b" <<'B1227B'
#!/usr/bin/env bash
printf '  ask %s to add %s to %s'\''s installation:\n' "$a" "$b" "$c"
# CANARY_1227B_MUST_NOT_SURVIVE
echo \" unbalanced-looking but escaped
# CANARY_1227C_MUST_NOT_SURVIVE
echo still_code
B1227B
_out1227b=$(shf_strip_comments "$_b1227b" 2>/dev/null)
assert_not_contains "a comment after the '\\'' idiom is stripped (the escaped quote opens nothing)" \
    "$_out1227b" "CANARY_1227B_MUST_NOT_SURVIVE"
assert_not_contains "a comment after an escaped double quote outside strings is stripped" \
    "$_out1227b" "CANARY_1227C_MUST_NOT_SURVIVE"
assert_contains "…and the real code around both survives the strip" \
    "$_out1227b" "echo still_code"
assert_contains "…including the printf carrying the idiom" \
    "$_out1227b" "installation"

# THE PER-LINE CONTRACT IS UNCHANGED, which is what keeps the three 1-arg and
# 2-arg callers (`_test_helpers.sh`, `uncounted-abort-lint.sh`,
# `test-tmux-socket-ceiling.sh`, `early-exit-readers.sh`) on their previous
# behaviour: `sp0`/`stack`/`depth` are OPTIONAL parameters, and awk gives an
# unsupplied parameter a fresh local.
_qawk="$REPO_ROOT/monitor/watcher/_shell_quotes.awk"
assert_eq "quote_mask(s) with no carry still masks a plain quoted span" \
    "$(awk "$(cat "$_qawk")"'BEGIN { print quote_mask("a \"b\" c") }')" \
    "0011100"
assert_eq "…and a 1-arg call reports sp 0, so a bare caller cannot inherit nesting" \
    "$(awk "$(cat "$_qawk")"'BEGIN { quote_mask("x=\"$(f\""); print QM_SP+0 }')" \
    "1"



# ---------------------------------------------------------------------------
# BOTH-SHELL AGREEMENT (your-org/nexus-code#1338).
# ---------------------------------------------------------------------------
# The predicate's whole job is to answer "what shell code is in this repo?", and
# `CLAUDE.md` prescribes it as THE population rule — "never by a filename glob".
# A population rule that answers differently depending on which shell sourced it
# is not one rule, it is two, and the divergence is SILENT: `read -r -n 200` is
# a bash spelling that zsh accepts at rc 0 while yielding an EMPTY string, so
# the shebang arm reported "no shebang" for every file that has one.
#
# The failure shape was a plausible UNDER-COUNT, not a zero — the extension arm
# still found every `*.sh`, so only EXTENSIONLESS files were lost, and in this
# repo every one of those is a PATH-front shim or a default-deny guard. Measured
# at `bbf8985b` before the fix: `shf_find0 monitor shell` returned 603 under
# bash and 593 under zsh, and the 10 missing were `monitor/ng`, `ghwrap/gh`,
# `pipwrap/pip`, `tmuxwrap/tmux`, `proc-kill-authorized`,
# `proc-exists-authorized`, `git-https-setup`, `notifywrap/sandbox-notify` and
# the two `client/` entry points.
#
# So this guard asserts AGREEMENT rather than any particular number — the
# property actually being claimed, and the one nothing checked before. It is
# deliberately a POSITIVE assertion in the sense of the header above: it
# requires a named interpreter to be FOUND under the second shell, so an
# enumerator that produced nothing cannot satisfy it.
_zsh_bin=$(command -v zsh 2>/dev/null || true)
if [[ -z "$_zsh_bin" ]]; then
    # NOT a silent pass. A skip that looks like a pass is the defect this file
    # exists to prevent, so the absence is recorded as a skip and named.
    th_skip "both-shell agreement" \
        "no zsh on this host (command -v zsh is empty) — the bash/zsh divergence axis #1338 is about is UNMEASURED here"
else
    _shf_probe=$(_plant 'shebang-only-tool' '#!/usr/bin/env bash')
    printf 'body\n' >> "$_shf_probe"

    # (a) The interpreter itself must agree, on the exact shape that used to
    #     return empty under zsh.
    assert_eq "both-shell: shf_interpreter agrees under bash" \
        "$(bash -c '. "$1"; shf_interpreter "$2"' _ "$LIB" "$_shf_probe")" "bash"
    assert_eq "both-shell: …and returns the SAME interpreter under zsh" \
        "$("$_zsh_bin" -c '. "$1"; shf_interpreter "$2"' _ "$LIB" "$_shf_probe")" "bash"

    # (b) An EXTENSIONLESS shim is the member class that was lost. `monitor/ng`
    #     is the sharpest — the main CLI, and the file `#1214` records a sibling
    #     predicate failing on for the same reason.
    _shf_ng="$REPO_ROOT/monitor/ng"
    if [[ -r "$_shf_ng" ]]; then
        assert_eq "both-shell: shf_is_shell finds monitor/ng under bash" \
            "$(bash -c '. "$1"; shf_is_shell "$2" && echo yes || echo no' _ "$LIB" "$_shf_ng")" "yes"
        assert_eq "both-shell: …and finds it under zsh too (#1338's headline victim)" \
            "$("$_zsh_bin" -c '. "$1"; shf_is_shell "$2" && echo yes || echo no' _ "$LIB" "$_shf_ng")" "yes"
    else
        th_skip "both-shell: the extensionless victim" \
            "$REPO_ROOT/monitor/ng is not readable — #1338's headline victim is UNMEASURED"
    fi

    # (c) THE POPULATION COUNT ITSELF must agree. This is the assertion that
    #     would have caught `#1338`, and it is kept off the whole repo tree
    #     (seconds per shell) by running over a planted directory that contains
    #     one member of each arm: extension, shebang-with-extension, and the
    #     extensionless shebang that is the lost class.
    _shf_pop="$TMP/pop"; mkdir -p "$_shf_pop"
    printf '#!/bin/sh\n:\n'          > "$_shf_pop/by-shebang-extless"
    printf '#!/usr/bin/env bash\n:\n'> "$_shf_pop/also-extless"
    printf ':\n'                     > "$_shf_pop/by-extension.sh"
    printf 'not a script\n'          > "$_shf_pop/plain.txt"
    _shf_count='n=0; while IFS= read -r -d "" f; do n=$((n+1)); done < <(shf_find0 "$2" shell); echo "$n"'
    _shf_nb=$(bash      -c ". \"\$1\"; $_shf_count" _ "$LIB" "$_shf_pop")
    _shf_nz=$("$_zsh_bin" -c ". \"\$1\"; $_shf_count" _ "$LIB" "$_shf_pop")
    # Pinned, not merely equal: two enumerators that both return 0 also "agree".
    assert_eq "both-shell: the planted population is 3 under bash" "$_shf_nb" "3"
    assert_eq "both-shell: …and the SAME 3 under zsh — counts agree" "$_shf_nz" "$_shf_nb"
fi

# ── shf_find0 ENUMERATES THE REPOSITORY, NOT THE DIRECTORY (#1588) ──────────
#
# `shf_find0` used to be a bare `find` walk. Rooted at a PRIMARY nexus it
# classified every file of every analysis tree under `work/`, and
# `ng guards-for-diff` refused on every primary-clone wrap-up. It now asks git,
# and keeps the walk as a fallback — because a git-ONLY enumerator returns
# NOTHING, at rc 0, for two ordinary fixture shapes. Each arm is pinned here
# with a case that must flip and a case that must not.
echo '=== shf_find0: the git arm excludes ignored trees; the walk survives where git would say nothing (#1588) ==='
_sf_list() { shf_find0 "$1" "${2:-shell}" | tr '\0' '\n' | sed "s|^$1/||" | sort | tr '\n' ' '; }

_PRIM="$TMP/prim"; mkdir -p "$_PRIM/monitor/pipwrap" "$_PRIM/work/proj-1/scripts" "$_PRIM/scratch" "$_PRIM/monitor/.state"
git -C "$_PRIM" init -q >/dev/null 2>&1
th_require_fixture_repo "$_PRIM"
printf '*\n!.gitignore\n'      > "$_PRIM/work/.gitignore"      # the primary's own rule, verbatim
printf '/scratch/\n'           > "$_PRIM/.gitignore"
printf '#!/usr/bin/env bash\n' > "$_PRIM/monitor/tracked.sh"
printf '#!/usr/bin/env bash\n' > "$_PRIM/monitor/pipwrap/pip"
ln -s pip "$_PRIM/monitor/pipwrap/pip3"
git -C "$_PRIM" add -A >/dev/null 2>&1
printf '#!/usr/bin/env bash\n' > "$_PRIM/monitor/written-not-committed.sh"   # untracked, NOT ignored
printf '#!/usr/bin/env bash\n' > "$_PRIM/work/proj-1/scripts/run.sh"         # the #1588 population
printf '#!/usr/bin/env bash\n' > "$_PRIM/scratch/in-ignored-root.sh"
printf '#!/usr/bin/env bash\n' > "$_PRIM/monitor/.state/runtime.sh"

# MUST FLIP under the old walk: the planted analysis tree is NOT in the answer.
assert_not_contains "git arm: an IGNORED work/<project> tree is not enumerated" \
    "$(_sf_list "$_PRIM")" "work/proj-1"
# MUST NOT FLIP: what the walk found that the repository really owns.
assert_contains "git arm: a TRACKED shell file is enumerated"                       "$(_sf_list "$_PRIM")" "monitor/tracked.sh"
assert_contains "git arm: a written-but-UNCOMMITTED file is enumerated (working-tree population, #1054)" \
    "$(_sf_list "$_PRIM")" "monitor/written-not-committed.sh"
assert_contains "git arm: an extensionless shebang file is enumerated"              "$(_sf_list "$_PRIM")" "monitor/pipwrap/pip "
assert_not_contains "git arm: a tracked SYMLINK is not enumerated twice through its target (find -type f parity)" \
    "$(_sf_list "$_PRIM")" "pip3"
assert_not_contains "git arm: a _SHF_PRUNE_DIRS component is pruned from a path string too" \
    "$(_sf_list "$_PRIM")" ".state/"
assert_eq "git arm: the whole answer, pinned — 3 files and nothing else" \
    "$(_sf_list "$_PRIM")" "monitor/pipwrap/pip monitor/tracked.sh monitor/written-not-committed.sh "
assert_eq "git arm: a SUBDIRECTORY root keeps the caller's prefix (consumers strip \"\$ROOT/\")" \
    "$(_sf_list "$_PRIM/monitor")" "pipwrap/pip tracked.sh written-not-committed.sh "
assert_eq "git arm: a trailing slash on the root does not print a doubled slash" \
    "$(shf_find0 "$_PRIM/monitor/" shell | tr '\0' '\n' | grep -c '//' || true)" "0"

# THE SILENT ZERO A GIT-ONLY ENUMERATOR WOULD HAND THESE TWO ROOTS. Both hold a
# shell file; git lists nothing for either, at rc 0.
assert_eq "precondition: git itself lists NOTHING under a root its repository ignores" \
    "$(git -C "$_PRIM/scratch" ls-files --cached --others --exclude-standard | grep -c . || true)" "0"
assert_eq "fallback: a root IGNORED by its enclosing repository is WALKED, not answered with zero" \
    "$(_sf_list "$_PRIM/scratch")" "in-ignored-root.sh "
_NOGIT="$TMP/nogit"; mkdir -p "$_NOGIT/sub"; printf '#!/bin/sh\n' > "$_NOGIT/sub/plain-dir.sh"
assert_eq "precondition: the plain-directory fixture is inside NO work tree" \
    "$(git -C "$_NOGIT" rev-parse --is-inside-work-tree 2>/dev/null || echo no)" "no"
assert_eq "fallback: a root in NO repository is WALKED" "$(_sf_list "$_NOGIT")" "sub/plain-dir.sh "

# A `git ls-files` that DIES must not leave a truncated, plausible population
# at rc 0 (#928, #935 mode 2). A PATH-front `git` that answers the two
# pre-checks and then fails the listing is the smallest honest way to get there.
mkdir -p "$TMP/gitshim"
cat > "$TMP/gitshim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == ls-files ]] && exit 128; done
exec "$(type -P git)" "\$@"
SHIM
chmod +x "$TMP/gitshim/git"
_sf_err=$( { PATH="$TMP/gitshim:$PATH" shf_find0 "$_PRIM" shell >/dev/null; } 2>&1 )
_sf_rc=$( PATH="$TMP/gitshim:$PATH" shf_find0 "$_PRIM" shell >/dev/null 2>&1; echo $? )
assert_eq       "a FAILED git listing is rc 3, not a quiet short population" "$_sf_rc" "3"
assert_contains "…and says the population is TRUNCATED"                      "$_sf_err" "TRUNCATED"

# zsh parity for the GIT arm. The both-shell case above runs over a plain
# directory and so only ever exercises the walk.
if _sf_zsh=$(type -P zsh 2>/dev/null) && [[ -n "$_sf_zsh" ]]; then
    _sf_cnt='n=0; while IFS= read -r -d "" f; do n=$((n+1)); done < <(shf_find0 "$2" shell); echo "$n"; echo survived'
    assert_eq "both-shell, git arm: zsh enumerates the same 3 — and the CALLING shell survives shf_find0's subshell exit" \
        "$("$_sf_zsh" -c ". \"\$1\"; $_sf_cnt" _ "$LIB" "$_PRIM" | tr '\n' ' ')" "3 survived "
else
    th_skip "both-shell, git arm" "zsh is not installed — the git arm's zsh parity is UNMEASURED"
fi

# ── THE KILL GUARDS' OPT-IN: ignored files under monitor/ (#1594 item 1) ────
#
# The git arm drops ignored files, and the root `.gitignore` ignores `bin/`,
# `logs/`, `.config/` … UNANCHORED, so `monitor/logs/k.sh` holding a mass-kill
# was invisible to both kill lints. They now pass `ignored-under-monitor`.
# The default must not move, and the opt-in must not reopen #1588: `work/`
# stays out, and `.state` stays pruned even though it is now ignored too.
echo '=== shf_find0 ignored-under-monitor: the kill guards read ignored monitor/ files; #1588 does not regress (#1594) ==='
_sf_list_opt() { shf_find0 "$1" "${2:-shell}" ignored-under-monitor | tr '\0' '\n' | sed "s|^$1/||" | sort | tr '\n' ' '; }
printf 'logs/\n.state/\n' >> "$_PRIM/.gitignore"
mkdir -p "$_PRIM/monitor/logs" "$_PRIM/monitor/newdir/logs"
printf '#!/usr/bin/env bash\n' > "$_PRIM/monitor/logs/k.sh"
printf '#!/usr/bin/env bash\n' > "$_PRIM/monitor/newdir/logs/deep.sh"   # ignored, inside an UNTRACKED dir
printf '#!/usr/bin/env bash\n' > "$_PRIM/monitor/logs/tracked-anyway.sh"
git -C "$_PRIM" add -f monitor/logs/tracked-anyway.sh >/dev/null 2>&1
assert_eq "precondition: git reports monitor/logs/k.sh as IGNORED" \
    "$(git -C "$_PRIM" check-ignore monitor/logs/k.sh)" "monitor/logs/k.sh"

# MUST FLIP without the fix (the opt-in did not exist; a third arg was ignored).
assert_contains "opt-in: an ignored monitor/logs/k.sh IS enumerated" \
    "$(_sf_list_opt "$_PRIM")" "monitor/logs/k.sh"
assert_contains "opt-in: an ignored file inside an UNTRACKED directory is enumerated (the ls-files --directory silent zero)" \
    "$(_sf_list_opt "$_PRIM")" "monitor/newdir/logs/deep.sh"
assert_contains "opt-in: a SUBDIRECTORY root below monitor/ sees it too, with the caller's prefix" \
    "$(_sf_list_opt "$_PRIM/monitor")" "logs/k.sh"
# MUST NOT FLIP.
assert_not_contains "default: the same ignored file is NOT enumerated without the opt-in" \
    "$(_sf_list "$_PRIM")" "monitor/logs/k.sh"
assert_not_contains "opt-in: work/<project> is STILL not enumerated (#1588 must not regress)" \
    "$(_sf_list_opt "$_PRIM")" "work/proj-1"
assert_not_contains "opt-in: an IGNORED .state is still pruned (runtime state, not code)" \
    "$(_sf_list_opt "$_PRIM")" ".state/"
assert_eq "opt-in: a TRACKED file under an ignored dir is listed ONCE, not twice" \
    "$(shf_find0 "$_PRIM" shell ignored-under-monitor | tr '\0' '\n' | grep -c '/tracked-anyway\.sh$' || true)" "1"
assert_eq "opt-in: the whole answer, pinned" \
    "$(_sf_list_opt "$_PRIM")" \
    "monitor/logs/k.sh monitor/logs/tracked-anyway.sh monitor/newdir/logs/deep.sh monitor/pipwrap/pip monitor/tracked.sh monitor/written-not-committed.sh "
_sf_orc=$( shf_find0 "$_PRIM" shell no-such-option >/dev/null 2>&1; echo $? )
assert_eq "an UNKNOWN option is refused at rc 2, not silently ignored" "$_sf_orc" "2"
# The opt-in's own git call failing must be as loud as the listing's. The shim
# fails only the `--stdin` form: `_shf_git_enumerable`'s own `check-ignore -q .`
# must still answer, or the root goes to the WALK and this case measures nothing.
mkdir -p "$TMP/gitshim-ci"
cat > "$TMP/gitshim-ci/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == --stdin ]] && exit 128; done
exec "$(type -P git)" "\$@"
SHIM
chmod +x "$TMP/gitshim-ci/git"
_sf_rc=$( PATH="$TMP/gitshim-ci:$PATH" shf_find0 "$_PRIM" shell ignored-under-monitor >/dev/null 2>&1; echo $? )
assert_eq "opt-in: a FAILED git check-ignore is rc 3, not a quiet short population" "$_sf_rc" "3"
if _sf_zsh=$(type -P zsh 2>/dev/null) && [[ -n "$_sf_zsh" ]]; then
    _sf_cnt='n=0; while IFS= read -r -d "" f; do n=$((n+1)); done < <(shf_find0 "$2" shell ignored-under-monitor); echo "$n"'
    assert_eq "both-shell, opt-in: zsh enumerates the same 6" \
        "$("$_sf_zsh" -c ". \"\$1\"; $_sf_cnt" _ "$LIB" "$_PRIM")" "6"
else
    th_skip "both-shell, opt-in" "zsh is not installed — the opt-in's zsh parity is UNMEASURED"
fi

# THE LINT, not just the enumerator: lint-no-mass-kill.sh run on a real git
# fixture whose `bin/` is ignored must go RED on the ignored plant. This case
# lives HERE rather than in the lint's own --selftest because the lint is in the
# cc-update gated population, where `test-cc-update-no-remote-code.sh` forbids a
# `git init` (git-verb-denied) — the selftest first carried it and turned that
# suite red. The same holds for lint-no-tmux-server-kill.sh, below.
_sf_lf="$TMP/lintfix"; mkdir -p "$_sf_lf"
if git -C "$_sf_lf" init -q 2>/dev/null; then
    mkdir -p "$_sf_lf/monitor/cc-harness/bin"
    printf 'bin/\n' > "$_sf_lf/.gitignore"
    printf '#!/usr/bin/env bash\npkill -f "node_modules/.bin/claude"\n' > "$_sf_lf/monitor/cc-harness/bin/k.sh"
    _sf_lout=$(bash "$REPO_ROOT/monitor/cc-harness/lint-no-mass-kill.sh" "$_sf_lf/monitor/cc-harness" 2>&1); _sf_lrc=$?
    assert_eq "lint-no-mass-kill: an untracked AND gitignored plant under monitor/ turns the lint RED (#1594)" "$_sf_lrc" "1"
    assert_contains "lint-no-mass-kill: …and names the ignored file" "$_sf_lout" "/bin/k.sh:"
else
    th_skip "lint-no-mass-kill ignored-plant case" "git init failed — case NOT run"
fi
_sf_tf="$TMP/lintfix-tmux"; mkdir -p "$_sf_tf"
if git -C "$_sf_tf" init -q 2>/dev/null; then
    mkdir -p "$_sf_tf/monitor/bin"
    printf 'bin/\n' > "$_sf_tf/.gitignore"
    printf '#!/usr/bin/env bash\ntmux kill-server\n' > "$_sf_tf/monitor/bin/k.sh"
    _sf_tout=$(bash "$REPO_ROOT/monitor/cc-harness/lint-no-tmux-server-kill.sh" "$_sf_tf/monitor" 2>&1); _sf_trc=$?
    assert_eq "lint-no-tmux-server-kill: an untracked AND gitignored plant under monitor/ turns the lint RED (#1594)" "$_sf_trc" "1"
    assert_contains "lint-no-tmux-server-kill: …and names the ignored file under its rule" "$_sf_tout" ":rule1-killserver-unscoped:"
else
    th_skip "lint-no-tmux-server-kill ignored-plant case" "git init failed — case NOT run"
fi

th_summary_and_exit
