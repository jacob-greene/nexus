#!/usr/bin/env bash
# monitor/shell-files.sh — ONE definition of "which files under this repo are
# shell (or, more broadly, script) files", DERIVED from each file rather than
# listed (your-org/nexus-code#792).
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS
# ---------------------------------------------------------------------------
#
# `monitor/` contains executable shell files with NO `.sh` extension — `ng`
# (the largest shell file in the repo and the most-invoked entry point),
# `ghwrap/gh`, `pipwrap/pip`, `notifywrap/sandbox-notify`, `client/nexus-*`,
# `git-https-setup` — and four zsh startup files whose names begin with a dot
# and end in nothing (`shellenv/.zshenv`, `.zshrc`, `.zprofile`, `.zlogin`).
# Every enumerator that globbed the `*.sh` family was blind to all of them.
#
# Two of those enumerators are the KILL GUARDS (`cc-harness/lint-no-mass-kill.sh`,
# `cc-harness/lint-no-tmux-server-kill.sh`). Ending the tmux server ends the
# session bwrap holds open, so it takes down the watcher, every worker and every
# registered service at once, and the operator cannot restart the nexus
# (`#644`: five tear-downs in 33 minutes). A kill-scanner that cannot read
# `monitor/ng` is a hole in the one guard whose failure is unrecoverable.
#
# ---------------------------------------------------------------------------
# LIST VS DERIVATION — the actual point
# ---------------------------------------------------------------------------
#
# The in-tree "fix" that prompted `#792` was
# `find … \( -name '*.sh' -o -name 'ng' \)`. That is a ONE-ELEMENT ALLOWLIST.
# It closed the single node its author needed and stayed blind to the other
# ten, and it has the property `#770` gap 3 was filed about: **a list rots, a
# derivation does not.** Copying that pattern into the kill guards would have
# written the same defect with a longer list.
#
# The test this file is built to pass is therefore not "does it see `ng` today"
# but: **does a NINTH extensionless executable added tomorrow get covered
# without anybody remembering?** For arms 1 and 2 below the answer is yes,
# automatically, and `test-shell-files.sh` plants exactly that file and proves
# it. Arm 3 is the one honest exception and is argued for on its own terms.
#
# ---------------------------------------------------------------------------
# THE DERIVATION — three arms, and why the third is allowed to be a list
# ---------------------------------------------------------------------------
#
#   1. EXTENSION — `.sh` / `.bash` / `.zsh` / `.ksh`. Not redundant with arm 2:
#      a SOURCED library is not executable and frequently carries no shebang
#      at all (`watcher/_lib.sh`, `cc-harness/_lib.sh`, this file's own callers'
#      helpers). Dropping arm 1 would lose the majority of the corpus.
#
#   2. SHEBANG — the first line is `#!` and the interpreter it names (after
#      resolving `env`, and skipping `env`'s own `-S`/`-i`/`VAR=` arguments) has
#      a basename in the shell vocabulary. This is the arm that makes the
#      enumeration self-maintaining: it is what actually DEFINES "this file is
#      run by a shell", it is a property of the file rather than of a registry,
#      and a new extensionless executable is covered the moment it is written,
#      because a file without a shebang is not an executable script in the
#      first place.
#
#   3. SHELL STARTUP-FILE NAME — `.zshenv`, `.bashrc`, `.profile`, and the rest
#      of that family. These carry no extension AND no shebang, because they are
#      never executed: the shell sources them by NAME. Arms 1 and 2 cannot
#      reach them even in principle.
#
#      This arm IS a list, so it owes an argument. The argument is that its
#      vocabulary is fixed by the SHELLS — bash's and zsh's startup sequences
#      are documented, closed sets that this repo does not get a vote in — not
#      by what files this repo happens to contain. That is a categorically
#      different object from `-o -name 'ng'`, which enumerated one repo's
#      current inventory. The failure mode of a rotting list is "we added a file
#      and forgot"; that cannot happen here, because adding a file cannot add a
#      startup-file NAME. `test-shell-files.sh` pins the vocabulary so growing
#      it is a deliberate, reviewed edit.
#
# ---------------------------------------------------------------------------
# COVERAGE BOUNDARY (on the axis the MECHANISM varies on, stated so it can be
# disagreed with — and pinned as data by `test-shell-files.sh`, not left here
# as prose, because prose cannot be made to fail):
#
#   Membership is decided from a file's NAME and its FIRST LINE. So this
#   correctly classifies a file whose shell-ness is declared. It CANNOT
#   classify shell-ness that is declared somewhere else:
#
#     * a file executed as `bash somefile` with no shebang and no shell name —
#       shell-ness lives in the CALLER, not the file. Errs toward EXCLUDING.
#     * a shebang naming a wrapper that in turn runs a shell
#       (`#!/usr/bin/env my-runner`). Errs toward EXCLUDING.
#     * shell embedded in another language (a heredoc in a `.py`, a `system()`
#       in a `.pl`). Out of scope by construction — `shf_class` reports the
#       HOST language, and the `script` class exists so a text-regex lint can
#       still scan those files.
#     * a file whose first line is not its shebang (there is no such thing —
#       the kernel requires byte 0).
#     * an interpreter outside the declared vocabulary — `#!/usr/bin/env fish`,
#       `nu`, `elvish`. Errs toward EXCLUDING, and deliberately: the consumers
#       that matter PARSE bash/POSIX shell syntax, so classifying a fish script
#       as `shell` would feed a scanner a grammar it does not implement. Zero
#       occurrences on this tree. If one appears, the question to answer is
#       whether the scanner can read it, not whether to widen the list.
#
#   All three reachable gaps err toward excluding, which is the UNSAFE
#   direction for a guard, so they are named here rather than left for the next
#   skeptic. Measured on this tree 2026-08-07: zero occurrences of any of them,
#   and `test-shell-files.sh` RE-MEASURES the first against the live tree on
#   every CI run — a count of executable-but-unclassified files, not a fixture —
#   so this paragraph's number cannot quietly go stale.
#
#   That live count is here because the sentence was false when first written
#   (`#799` skeptic, F-3): it promised a re-measurement and pointed at an
#   assertion that only exercised the CLASSIFIER on a planted fixture, which is
#   the definition of the gap rather than a count of its occurrences. A prose
#   promise about a check that does not exist, in the file arguing prose cannot
#   be made to fail. The claim was true — 0 of 514, verified independently —
#   which is exactly what makes the missing check easy to not notice.
#
# ---------------------------------------------------------------------------
# NON-VACUITY — the property a shared enumerator most needs
#
# An enumerator broken into finding NOTHING makes every consumer report a clean
# sweep. That is the dominant defect class in this repo (silence read as
# absence), and it is why `shf_require_floor` exists and why every consumer
# calls it. A floor is the right shape here precisely because it does NOT rot
# in the direction that matters: adding files never trips it, so nobody is ever
# tempted to bump it reflexively.
#
# ---------------------------------------------------------------------------
# Usage — source it, or run it:
#
#   . monitor/shell-files.sh
#   shf_class <path>                     -> shell|python|perl|awk|"" (rc 1)
#   shf_is_shell <path>                  -> rc 0 if arm 1/2/3 matches
#   shf_is_script <path>                 -> rc 0 if shell, python or perl
#   shf_find0 <root> [shell|script|all]  -> NUL-separated paths
#   shf_count <root> [class]             -> how many
#   shf_require_floor <root> <class> <min> <label>   -> rc 1 + stderr if short
#
#   bash monitor/shell-files.sh [--class shell|script|all] [root]   # list them
#   bash monitor/shell-files.sh --classify <path>                   # one file
#   bash monitor/shell-files.sh --extensionless [root]  # the #792 population

# Sourced by lints and by test suites; must not impose its own shell options on
# a caller (that is your-org/nexus-code#721's leak class, gated by
# watcher/test-ambient-shell-option-scope.sh P2). It therefore sets none.

# Interpreter basenames, by class. Kept as three flat strings rather than
# associative arrays so this file is sourceable from bash 3.2-era callers.
_SHF_SHELL_INTERP=' sh bash zsh ksh ksh93 dash ash mksh '
_SHF_PY_INTERP=' python python2 python3 '
_SHF_PERL_INTERP=' perl '
_SHF_AWK_INTERP=' awk gawk mawk nawk '

# Arm 3. Fixed by the SHELLS' documented startup sequences, not by this repo's
# inventory — see the header. Pinned by test-shell-files.sh.
_SHF_STARTUP_NAMES=' .zshenv .zshrc .zprofile .zlogin .zlogout .bashrc .bash_profile .bash_login .bash_logout .profile .kshrc .shrc .shinit '

# Directories never worth descending into. `.state` is runtime scratch that can
# hold thousands of fetched assets and log files; it does not exist in a CI
# checkout but does locally, and reading a first line from each is the
# difference between a lint that runs and one nobody waits for.
#
# A real ARRAY, not a space-separated string, unlike the vocabularies above
# which are only ever `case`-matched. This one is iterated, and zsh does not
# word-split an unquoted parameter — `for d in $STRING` would run ONCE with the
# whole string as the pattern, prune nothing, and descend into `.state` with no
# error. That is a workspace-wide trap and it costs nothing to be immune to it.
_SHF_PRUNE_DIRS=( .git node_modules .state .venv __pycache__ )

# The interpreter a shebang names, reduced to a basename. Empty (rc 1) when the
# file has no shebang.
#
# NO `head -c 200`: this is called once per file over a ~500-file tree by
# several consumers, and a subprocess apiece is what turned a sibling
# classifier into a 26-second run (early-exit-readers.sh:113).
#
# AND NO `read -n 200` EITHER (your-org/nexus-code#1338). `-n` is a BASH
# spelling. Under zsh it is accepted, succeeds at rc 0, and yields an EMPTY
# string — so the shebang test below fails and this function reports "no
# shebang" for a file that has one. Measured on this host:
#
#     bash -c 'IFS= read -r -n 200 f < probe.sh; echo "rc=$? [$f]"'
#       -> rc=0 [#!/usr/bin/env bash]
#     zsh  -c 'IFS= read -r -n 200 f < probe.sh; echo "rc=$? [$f]"'
#       -> rc=0 []                      <-- rc 0. SILENT. Not an error.
#
# The victims are precisely the safety surface: the extension arm still finds
# every `*.sh`, so only the shebang arm fails, and every EXTENSIONLESS shell
# file in this repo is a PATH-front shim or a default-deny guard — `monitor/ng`,
# `ghwrap/gh`, `pipwrap/pip`, `tmuxwrap/tmux`, `proc-kill-authorized`,
# `proc-exists-authorized`, `git-https-setup`, `notifywrap/sandbox-notify` and
# the two `client/` entry points. `shf_is_shell monitor/ng` measured rc 0 under
# bash and rc 1 under zsh.
#
# zsh's equivalent is `-k`, which bash rejects (rc 2), so there is no shared
# flag. A plain line read is correct in BOTH and needs no flag at all; the
# 200-char bound is then re-imposed by parameter expansion. What that trades
# away is the guarantee that a binary file with no newline cannot make the read
# large — `read` still stops at the first newline, so the exposure is one
# pathological FIRST LINE rather than a whole file. Measured over the 724 files
# under `monitor/` at `bbf8985b`, the longest first line is 297 bytes.
# The classifier's two readers exist twice: the printing form (`shf_interpreter`,
# `shf_class`) for callers, and a `_var` form that sets `_SHF_INTERP` /
# `_SHF_CLS` instead of printing. shf_find0 calls the `_var` form because a
# `$(…)` per file is a FORK per file — two for an extensionless script — and
# that fork was most of every sweeping lint's cost (measured at load ~50: the
# ~720-file `monitor/` population took 4.0 s to enumerate, nearly all of it in
# subshells). The printing forms are thin wrappers, so there is ONE classifier.
_shf_interp_var() {   # <path> -> sets _SHF_INTERP; rc 1 (and empty) for none
    local first='' word='' tok rest saw_env=0
    _SHF_INTERP=''
    IFS= read -r first < "$1" 2>/dev/null
    first=${first:0:200}
    case "$first" in '#!'*) ;; *) return 1 ;; esac
    first=${first#'#!'}
    # Strip a leading CR so a CRLF file does not yield an interpreter of
    # `bash<CR>`, which would match nothing and silently exclude the file.
    first=${first%$'\r'}

    # Tokenise WITHOUT relying on unquoted-parameter word splitting. This used
    # to be `set -- $first`, carrying an explicit `# shellcheck disable=SC2086`
    # because the split was deliberate — and it is a BASH-only split. Measured:
    #
    #     first="/usr/bin/env bash"; set -- $first
    #       bash -> argc 2, $1=/usr/bin/env, $2=bash
    #       zsh  -> argc 1, $1="/usr/bin/env bash"
    #
    # so under zsh `${1##*/}` yields `env bash`, which matches no vocabulary and
    # excludes the file — a DIFFERENT silent under-count from the one the read
    # above used to cause. Fixing only the read would therefore have swapped one
    # confident wrong answer for another, which is the whole lesson of `#1338`:
    # hardening one site is not hardening the file. zsh's `${=first}` is a
    # syntax error under bash, so there is no one-token fix; this loop is the
    # form that is identical in both shells.
    rest=${first//$'\t'/ }
    while [ -n "$rest" ]; do
        tok=${rest%% *}
        if [ "$tok" = "$rest" ]; then rest=''; else rest=${rest#* }; fi
        [ -n "$tok" ] || continue          # collapse runs of blanks
        if [ "$saw_env" = 1 ]; then
            # `env` may carry its own options and VAR=value assignments before
            # the command. Skip them; `#!/usr/bin/env -S bash -e` is the shape
            # that matters and it is why this is a loop rather than one shift.
            #
            # TWO SPELLINGS OF THAT SAME SHAPE CARRY THE COMMAND INSIDE THE
            # OPTION TOKEN (your-org/nexus-code#1409): GNU env accepts
            # `--split-string=bash -e` and the attached short form `-Sbash -e`.
            # A bare `-*|*=*` skip swallowed the command WITH the option, ran
            # out of tokens, and returned rc 1 — EXCLUDING the file, the unsafe
            # direction for a kill-guard population. Peel the command out of
            # the token first; the detached `-S bash` and `--split-string bash`
            # forms still take the skip-then-read path below.
            case "$tok" in
                --split-string=?*) tok=${tok#--split-string=} ;;
                -S?*)              tok=${tok#-S} ;;
                -*|*=*)            continue ;;
            esac
            word=${tok##*/}
            break
        fi
        word=${tok##*/}
        if [ "$word" = env ]; then saw_env=1; word=''; continue; fi
        break
    done
    [[ -n "$word" ]] || return 1
    _SHF_INTERP=$word
}
shf_interpreter() {   # <path>
    _shf_interp_var "$1" || return 1
    printf '%s' "$_SHF_INTERP"
}

# The class of one file: shell | python | perl | awk | "" (rc 1 for none).
_shf_class_var() {   # <path> -> sets _SHF_CLS; rc 1 (and empty) for none
    local p="$1" base interp
    _SHF_CLS=''
    [[ -f "$p" ]] || return 1
    base=${p##*/}

    # Arm 0 — TRANSIENT JUNK, excluded before anything else.
    #
    # An extension glob got this for free: `foo.sh~` and `.nfs0000000782…` do
    # not match `*.sh`. A shebang derivation does NOT, because these files are
    # byte-copies of real shell files and carry a real shebang. That difference
    # bit immediately: an NFS silly-rename artifact (created when a file is
    # unlinked while another process holds it open) entered the population
    # mid-run and made `aso-unresolved-sources.manifest` disagree with itself
    # between two invocations seconds apart.
    #
    # A manifest keyed on the worktree must not move because of an editor
    # backup or a stale NFS handle. Nobody maintains these files; they are not
    # part of anybody's answer to "what shell code is in this repo".
    case "$base" in
        .nfs????????*|*~|.#*|*.orig|*.rej|*.bak|*.swp|*.tmp) return 1 ;;
    esac

    # Arm 1 — extension.
    case "$base" in
        *.sh|*.bash|*.zsh|*.ksh) _SHF_CLS=shell; return 0 ;;
        *.py)                    _SHF_CLS=python; return 0 ;;
        *.pl|*.pm)               _SHF_CLS=perl;   return 0 ;;
        *.awk)                   _SHF_CLS=awk;    return 0 ;;
    esac

    # Arm 3 — a shell startup file, sourced by NAME and so carrying neither an
    # extension nor a shebang. Checked before arm 2 only because it is a cheap
    # string test; the two cannot both match.
    case "$_SHF_STARTUP_NAMES" in
        *" $base "*) _SHF_CLS=shell; return 0 ;;
    esac

    # Arm 2 — shebang. The self-maintaining arm: this is what covers an
    # extensionless executable added tomorrow, with nobody remembering.
    _shf_interp_var "$p" || return 1
    interp=$_SHF_INTERP
    case "$_SHF_SHELL_INTERP" in *" $interp "*) _SHF_CLS=shell;  return 0 ;; esac
    case "$_SHF_PY_INTERP"    in *" $interp "*) _SHF_CLS=python; return 0 ;; esac
    case "$_SHF_PERL_INTERP"  in *" $interp "*) _SHF_CLS=perl;   return 0 ;; esac
    case "$_SHF_AWK_INTERP"   in *" $interp "*) _SHF_CLS=awk;    return 0 ;; esac
    return 1
}

shf_class() {   # <path>
    _shf_class_var "$1" || return 1
    printf '%s' "$_SHF_CLS"
}

shf_is_shell()  { _shf_class_var "$1" && [[ "$_SHF_CLS" == shell ]]; }

# Any interpreted script. The broader class exists for text-regex lints
# (`lint-no-mass-kill.sh`) whose ban is language-independent — a `killall` is a
# `killall` in perl too — as distinct from scanners that parse shell syntax.
shf_is_script() {
    _shf_class_var "$1" || return 1
    case "$_SHF_CLS" in shell|python|perl) return 0 ;; *) return 1 ;; esac
}

# Whether a class string is wanted under a filter.
_shf_wanted() {   # <class> <filter>
    case "$2" in
        all)    [[ -n "$1" ]] ;;
        script) case "$1" in shell|python|perl) return 0 ;; *) return 1 ;; esac ;;
        *)      [[ "$1" == "$2" ]] ;;
    esac
}

# Every matching file under <root>, NUL-separated.
#
# NUL rather than newline because consumers feed this straight to `xargs -0` and
# `while read -d ''`, and a newline-separated list is a silent-truncation
# hazard the moment a path contains whitespace. Symlinks are excluded by
# `-type f` — `pipwrap/pip3` is a symlink to `pipwrap/pip` and scanning both
# would double-report every hit in it.
#
# THE POPULATION IS THE REPOSITORY'S OWN FILES, NOT WHATEVER SITS UNDER <root>
# (your-org/nexus-code#1588). This used to be a bare `find` walk pruned by
# `_SHF_PRUNE_DIRS` alone, and that list has no `work/`. In a clone that is
# harmless: `work/` holds one `.gitignore`. In a PRIMARY nexus `work/` holds
# every analysis tree the operator has — 1,143 directories when measured — and
# a consumer rooted at the repo root (`tee-reopen-lint.sh`) classified every
# file in all of them. Measured 2026-09-19 at `17f1f926` on a fixture with 400
# planted `work/proj-N/` trees (2,401 files): that lint's population went
# 715 -> 1,915 and its probe 4.9 s -> 17.5 s; in the real primary it hit the
# selector's 180 s bound with ZERO lines, so `ng guards-for-diff` REFUSED on
# every primary-clone wrap-up. `#1487` was the same defect in another probe,
# fixed at that one call site — which is why the fix now lives HERE, where
# every consumer inherits it.
#
# So: ask git. `--cached --others --exclude-standard` is "tracked, plus written
# and not yet committed, minus ignored" — the WORKING-TREE reading the
# `--population` protocol specifies (guard-populations.manifest: a file written
# and not yet committed is legitimately in a population), and it never descends
# an ignored directory, so its cost does not grow with `work/`.
#
# AND THE WALK STAYS, AS A FALLBACK, BECAUSE GIT-ONLY WOULD BE A SILENT ZERO.
# Fixture roots are routinely plain directories, and two shapes make git answer
# NOTHING at rc 0 for a directory full of files:
#   * <root> is not inside any work tree  -> `git` errors, no list;
#   * <root> is inside one but IGNORED by it (a scratch dir under an ignored
#     path) -> measured on git 2.17.1: `ls-files --others` prints 0 lines.
# `_shf_git_enumerable` tests for exactly those two and sends them to the walk.
# It does NOT use `--is-inside-work-tree` alone, which certifies a walked-up
# ENCLOSING repository as fine (your-org/nexus-code#1196) — the ignore check is
# what makes the walk-up case safe rather than merely detected.
_shf_git_enumerable() {   # <root> -> rc 0 iff git can enumerate <root> faithfully
    [ -d "$1" ] || return 1
    command -v git >/dev/null 2>&1 || return 1
    [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 1
    # rc 0 = ignored, 1 = NOT ignored, 128 = could not tell. Only a positive
    # "not ignored" selects git; "ignored" AND "could not tell" take the walk.
    # The status is captured on the same line as the command that sets it —
    # anything between the two is a write to `$?` (your-org/nexus-code#1202).
    local ign=0
    git -C "$1" check-ignore -q . >/dev/null 2>&1 || ign=$?
    if [ "$ign" -ne 1 ]; then
        return 1
    fi
    return 0
}

# One repo-relative path -> rc 0 iff a `_SHF_PRUNE_DIRS` name is one of its
# components. The walk prunes those by `-name` at any depth; the git arm has
# to say the same thing about a path string or the two arms disagree.
_shf_pruned_component() {   # <relative-path>
    local d
    for d in "${_SHF_PRUNE_DIRS[@]}"; do
        case "/$1" in */"$d"/*) return 0 ;; esac
    done
    return 1
}

# THE OPT-IN: `shf_find0 <root> <filter> ignored-under-monitor`
# (your-org/nexus-code#1594 item 1).
#
# The git arm above answers "tracked, plus untracked, MINUS IGNORED", and that
# minus is right for every consumer that asks about the repository's code. It
# is wrong for exactly two: the KILL GUARDS (`cc-harness/lint-no-mass-kill.sh`,
# `lint-no-tmux-server-kill.sh`). A kill guard exists to catch what nobody
# reviewed, and an ignored path is unreviewed by definition. The root
# `.gitignore` carries UNANCHORED `bin/`, `logs/`, `nexus/`, `_ignore/` and
# `.config/`, so `monitor/cc-harness/bin/x.sh` or `monitor/logs/x.sh` holding
# `pkill -f claude` was invisible to both guards the cc-update gate runs.
#
# So a caller may opt in to the ignored files too — but ONLY those under
# `monitor/` (measured from the REPOSITORY root, not from <root>). Outside
# `monitor/` the ignored set of a primary nexus is `work/` and `reports/`,
# which is precisely the population #1588 removed; that must not come back
# through this door, and the default (no third argument) is unchanged.
#
# `_SHF_PRUNE_DIRS` STILL APPLIES, AND `.state` IN PARTICULAR STAYS PRUNED.
# `monitor/.state/` is runtime state written by the nexus's own services, not
# code anyone runs as a script: measured in the operator's primary 2026-09-24,
# 30,676 ignored files under `monitor/.state`, against 4 ignored entries
# anywhere else under `monitor/`. Classifying those is the #1588 cost again
# (a cold `git ls-files --ignored` over them took 22 s before classification),
# and the walk arm has always pruned it, so the two arms keep agreeing.
#
# HOW: a pruned `find` walk of the `monitor/` scope — the very walk the
# fallback arm below has always done, with the same `_SHF_PRUNE_DIRS` — piped
# through ONE `git check-ignore -z --stdin`, which keeps only the ignored
# paths. `check-ignore` never reports a TRACKED file, so nothing the first
# `ls-files` already listed comes out twice. Measured on the same primary:
# 0.03 s, 3 ignored files, none of them under `.state`.
#
# NOT `ls-files --others --ignored --directory`, which looks like the cheap way
# to prune and is a SILENT ZERO. Measured on git 2.17.1 (this host): with an
# UNTRACKED directory `monitor/new/` holding an untracked `a.sh` and an ignored
# `bin/k.sh`, `--directory` omits `monitor/new/bin/k.sh` with or without
# `--no-empty-directory` — and it omits an all-ignored `monitor/cc-harness/`
# without that flag — while the plain form lists it. The plain form, in turn,
# descends `.state` (30,676 files) and pathspec `:(exclude)` does not stop the
# descent, only the printing.
_SHF_OPT_IGNORED_MONITOR=ignored-under-monitor

# NUL-separated, <root>-RELATIVE paths of the ignored files under the repo's
# `monitor/` that lie beneath <root>. rc != 0 iff git failed (`check-ignore`
# exits 1 for "none ignored", which is an answer, and 128 for "could not
# tell"). A `find` that cannot read a subdirectory degrades exactly as the
# fallback walk does.
_shf_ignored_under_monitor0() {   # <root>
    local root="$1" pfx scope sub rc
    local -a prune=()
    pfx=$(git -C "$root" rev-parse --show-prefix 2>/dev/null) || return 1
    case "$pfx" in
        monitor/*)  scope=$root ;;              # <root> is monitor/ or below it
        '')         scope=$root/monitor ;;      # <root> is the repo top
        *)          return 0 ;;                 # <root> is elsewhere: nothing to add
    esac
    [ -d "$scope" ] || return 0
    for sub in "${_SHF_PRUNE_DIRS[@]}"; do prune+=( -name "$sub" -o ); done
    # The status is read on the line that sets it: the pipeline's status is
    # `check-ignore`'s, its last command, which is the one that can fail.
    find "$scope" \( "${prune[@]}" -false \) -prune -o -type f -print0 2>/dev/null \
      | while IFS= read -r -d '' sub; do printf '%s\0' "${sub#"$root"/}"; done \
      | git -C "$root" check-ignore -z --stdin 2>/dev/null; rc=$?
    [ "$rc" -le 1 ]
}

shf_find0() {   # <root> [class-filter=shell] [ignored-under-monitor]
    local root="$1" filter="${2:-shell}" opt="${3:-}" f d rel prev='' failed=0
    local -a prune=()
    case "$opt" in
        ''|"$_SHF_OPT_IGNORED_MONITOR") ;;
        *)  printf 'shf_find0: unknown option %s (only %s is defined)\n' "$opt" "$_SHF_OPT_IGNORED_MONITOR" >&2
            return 2 ;;
    esac
    # `find dir/` prints `dir/x`; a git-relative path joined onto `dir/` would
    # print `dir//x`, and consumers strip the root with `${f#"$ROOT"/}`.
    [ "$root" != / ] && root=${root%/}

    if _shf_git_enumerable "$root"; then
        # The sentinel is how a FAILED `git ls-files` stays visible: a pipeline
        # reports its LAST command's status, so without it a git that died
        # half-way would leave a truncated, plausible population at rc 0
        # (your-org/nexus-code#928, #935 mode 2).
        #
        # The consumer is an EXPLICIT SUBSHELL `( … )`, never `{ …; }`: zsh runs
        # the LAST element of a pipeline in the CURRENT shell, so an `exit`
        # inside braces would terminate the CALLER — and this file is sourced
        # by zsh callers on purpose (test-shell-files.sh pins the parity).
        #
        # The opt-in's producer appends to the same stream; its own git failure
        # emits the same sentinel, so a truncation there is just as loud.
        { git -C "$root" ls-files -z --cached --others --exclude-standard 2>/dev/null \
            || printf 'SHF-GIT-LS-FILES-FAILED\0'
          if [ -n "$opt" ]; then
              _shf_ignored_under_monitor0 "$root" || printf 'SHF-GIT-LS-FILES-FAILED\0'
          fi; } \
          | ( while IFS= read -r -d '' rel; do
                  if [ "$rel" = SHF-GIT-LS-FILES-FAILED ]; then failed=1; continue; fi
                  # An unmerged path is listed once per stage, adjacently.
                  [ "$rel" = "$prev" ] && continue
                  prev=$rel
                  _shf_pruned_component "$rel" && continue
                  f="$root/$rel"
                  # `find -type f` excluded symlinks for free; `[[ -f ]]` in
                  # shf_class FOLLOWS them, and `pipwrap/pip3` -> `pip` would
                  # be scanned twice.
                  [ -L "$f" ] && continue
                  _shf_class_var "$f" || continue
                  _shf_wanted "$_SHF_CLS" "$filter" && printf '%s\0' "$f"
              done
              if [ "$failed" = 1 ]; then
                  printf 'shf_find0: `git ls-files` FAILED under %s — this population is TRUNCATED, not complete.\n' "$root" >&2
                  exit 3
              fi
              exit 0 )
        return $?
    fi

    for d in "${_SHF_PRUNE_DIRS[@]}"; do prune+=( -name "$d" -o ); done
    find "$root" \( "${prune[@]}" -false \) -prune -o -type f -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do
            _shf_class_var "$f" || continue
            _shf_wanted "$_SHF_CLS" "$filter" && printf '%s\0' "$f"
        done
}

shf_count() {   # <root> [class-filter]
    shf_find0 "$1" "${2:-shell}" | tr -dc '\0' | wc -c | tr -d ' '
}

# NON-VACUITY. Every consumer calls this before trusting a clean result.
#
# The floor is checked against the REAL tree, never against a fixture root — a
# fixture legitimately holds two files. Consumers therefore pass their own root
# and their own minimum, and the minimum is set well below the true count so
# ordinary deletions never trip it: it is a broken-enumerator alarm, not an
# inventory.
shf_require_floor() {   # <root> <class-filter> <min> <label>
    local n; n=$(shf_count "$1" "$2")
    if (( n < $3 )); then
        {
            echo "$4: shell-file enumeration returned $n $2 files under $1,"
            echo "  below the floor of $3. An enumerator broken into finding nothing"
            echo "  makes every consumer report a CLEAN SWEEP — which is the failure"
            echo "  this floor exists to make loud (your-org/nexus-code#792)."
        } >&2
        return 1
    fi
    return 0
}

# --- CLI -------------------------------------------------------------------
# Guarded so sourcing does not run it. `${BASH_SOURCE[0]}` differs from `$0`
# exactly when this file is sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _shf_root=""; _shf_filter="shell"; _shf_mode="list"
    while (( $# )); do
        case "$1" in
            --class)          _shf_filter="$2"; shift 2 ;;
            --classify)       _shf_mode="classify"; _shf_root="$2"; shift 2 ;;
            --extensionless)  _shf_mode="extensionless"; shift ;;
            -h|--help)        sed -n '2,120p' "$0"; exit 0 ;;
            -*)               echo "unknown option: $1" >&2; exit 2 ;;
            *)                _shf_root="$1"; shift ;;
        esac
    done
    case "$_shf_mode" in
        classify)
            shf_class "$_shf_root" || { echo "(not a script)"; exit 1; }
            echo ;;
        extensionless)
            # The #792 population: shell files no `*.sh`-family glob can see.
            _shf_root="${_shf_root:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
            shf_find0 "$_shf_root" shell \
              | while IFS= read -r -d '' f; do
                    case "${f##*/}" in *.sh|*.bash|*.zsh|*.ksh) continue ;; esac
                    printf '%s\n' "$f"
                done | LC_ALL=C sort ;;
        *)
            _shf_root="${_shf_root:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
            shf_find0 "$_shf_root" "$_shf_filter" \
              | while IFS= read -r -d '' f; do printf '%s\n' "$f"; done \
              | LC_ALL=C sort ;;
    esac
fi

# ---------------------------------------------------------------------------
# shf_strip_heredocs <file> — the file's source with heredoc BODIES blanked.
# MOVED here from monitor/watcher/_test_helpers.sh (your-org/nexus-code#806,
# rehomed for #1227). The header there is the authority on WHY; this is the
# same function, in the shared predicate rather than in a test helper, because
# `shf_strip_comments` below needs it and a PRODUCTION predicate must not
# depend on a TEST helper. `th_strip_heredocs` is now a forwarder, so there is
# still exactly ONE implementation — the `#838`/`#842` "second, wrong copy"
# mistake is what a COPY here would have been.
#
# Blanked, not deleted: line numbers must survive, because every consumer
# reports `file:line`.
#
# THE FAIL-SAFE IS PART OF THE CONTRACT. On an UNTERMINATED heredoc at EOF it
# concludes it mis-parsed, discards its own output, emits the file UNSTRIPPED
# and says so on STDERR at rc 0. Callers that must not go quietly blind check
# stderr, not just rc (undefined-helper-lint.sh:382 does; copy that shape).
_SHF_QUOTES_AWK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/watcher/_shell_quotes.awk"
shf_strip_heredocs() { _shf_heredoc_view strip "$1"; }

# shf_expanding_heredoc_bodies <file> — `<line>TAB<text>` for every BODY line of
# a heredoc whose delimiter is UNQUOTED, i.e. the lines the shell EXPANDS
# (parameter, arithmetic and COMMAND substitution) before the text is written
# anywhere (your-org/nexus-code#1555). It is the COMPLEMENT of the view above
# and deliberately the SAME parser in another mode, not a second one: the
# arithmetic-shift and quoted-`<<` traps that parser's header records are
# exactly the ones a fresh scanner walks into (measured while writing this — a
# naive `<<WORD` regex enrolled 425 lines across 16 files, 423 of them prose).
#
# FAIL DIRECTION: on an unterminated heredoc the parser concludes it mis-parsed.
# The strip view answers by emitting the file UNSTRIPPED (over-report); this
# view cannot over-report usefully, so it emits NOTHING on stdout, says so on
# stderr and returns 3 — a caller that treats an empty answer as "no expanding
# heredocs" without reading rc is making the silent-zero mistake on purpose.
shf_expanding_heredoc_bodies() { _shf_heredoc_view bodies "$1"; }

_shf_heredoc_view() {
    local _mode="$1" f="$2"
    [[ -r "$f" ]] || return 1
    # The quote state machine is SHARED with uncounted-abort-lint.sh
    # (`_shell_quotes.awk`). It used to be inline here and a second, wrong copy
    # lived in the lint — a `sed` pair that paired any two apostrophes and ate
    # real code between them. One machine, two callers, is the point.
    local _q; _q="$(cat "$_SHF_QUOTES_AWK" 2>/dev/null)" || return 1
    [[ -n "$_q" ]] || return 1
    awk -v mode="$_mode" "$_q"'
    function push(d, dash_, quoted_) { n++; delim[n] = d; dsh[n] = dash_; qtd[n] = quoted_ }
    function scan(s,   i, L, j, d, dash_, q, arith, c2, c1, qm) {
        L = length(s); i = 1; arith = 0
        # Quote state from the SHARED machine. A `<<` inside a quoted string is
        # TEXT, not a redirection operator — monitor/test-conflict-marker-lint.sh
        # passes a single-quoted literal [cat <<EOF] to a helper as an argument.
        # The mask is consulted rather than a strip applied, because a heredoc
        # delimiter is usually QUOTED (<<[EOF]) and stripping quoted text would
        # delete the very delimiter this function exists to capture.
        qm = quote_mask(s)
        while (i <= L) {
            c1 = substr(s, i, 1)
            if (substr(qm, i, 1) == "1") { i++; continue }
            if (c1 == "#") break        # rest of the line is a comment
            c2 = substr(s, i, 2)
            # Track arithmetic context so a left shift is never read as a
            # heredoc. Both `$(( … ))` and a bare `(( … ))` command count.
            if (c2 == "((") { arith++; i += 2; continue }
            if (c2 == "))" && arith > 0) { arith--; i += 2; continue }
            if (c2 == "<<") {
                if (substr(s, i + 2, 1) == "<") { i += 3; continue }   # herestring
                if (arith > 0) { i += 2; continue }                    # left shift
                j = i + 2; dash_ = 0
                if (substr(s, j, 1) == "-") { dash_ = 1; j++ }
                while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
                q = substr(s, j, 1); d = ""; isq = (q == "\"" || q == "'"'"'" || q == "\\")
                if (q == "\"" || q == "'"'"'") {
                    j++
                    while (j <= L && substr(s, j, 1) != q) { d = d substr(s, j, 1); j++ }
                    j++
                } else {
                    if (q == "\\") j++
                    while (j <= L && substr(s, j, 1) ~ /[A-Za-z0-9_]/) { d = d substr(s, j, 1); j++ }
                }
                # Letter-or-underscore initial: rejects the numeric delimiter a
                # left shift like `(o1 << 24)` would otherwise manufacture.
                if (d ~ /^[A-Za-z_][A-Za-z0-9_]*$/) push(d, dash_, isq)
                i = j; continue
            }
            i++
        }
    }
    { raw[NR] = $0 }
    {
        if (n > 0) {
            t = $0
            if (dsh[1]) sub(/^\t+/, "", t)
            if (t == delim[1]) {
                for (k = 1; k < n; k++) { delim[k] = delim[k+1]; dsh[k] = dsh[k+1]; qtd[k] = qtd[k+1] }
                n--
            } else if (!qtd[1]) {
                nb++; bline[nb] = NR; btext[nb] = $0    # a body line the shell EXPANDS
            }
            out[NR] = ""        # body AND terminator are data, never code
            next
        }
        c = $0; sub(/^[ \t]+/, "", c)
        if (substr(c, 1, 1) != "#") scan($0)   # a comment cannot open a heredoc
        out[NR] = $0
    }
    END {
        if (n > 0) {
            printf("shf_strip_heredocs: %s: heredoc `%s` unterminated at EOF — ", FILENAME, delim[1]) > "/dev/stderr"
            if (mode == "bodies") {
                printf("mis-parse suspected, emitting NOTHING (rc 3): an empty answer here is NOT \"none\"\n") > "/dev/stderr"
                exit 3
            }
            printf("mis-parse suspected, emitting the file UNSTRIPPED\n") > "/dev/stderr"
            for (k = 1; k <= NR; k++) print raw[k]
            exit 0
        }
        if (mode == "bodies") { for (k = 1; k <= nb; k++) printf("%d\t%s\n", bline[k], btext[k]); exit 0 }
        for (k = 1; k <= NR; k++) print out[k]
    }
    ' "$f"
}

# ---------------------------------------------------------------------------
# shf_strip_comments <file>  — the file's CODE, with comment text removed.
# (your-org/nexus-code#1106)
# ---------------------------------------------------------------------------
#
# WHY THIS EXISTS. A predicate keyed on a STRING cannot tell the THING from the
# DESCRIPTION of the thing (`#1073`). Every lint in this tree that greps a file
# for a construct is enrolling files on the strength of text that may be a
# COMMENT — and a comment NAMING the construct is the most natural thing a
# maintainer writes, especially the comment explaining why the file
# deliberately does NOT use it. `#1106` is exactly that: `early-exit-readers.sh`
# put a file on the pipefail axis because a comment mentioned the option.
#
# `#1106` records that there was no shared primitive to reuse, which is why the
# defect was left open rather than folded into an unrelated PR. This is it.
#
# TWO THINGS IT MUST GET RIGHT, both of which the obvious one-liner does not:
#
#  1. `sed 's/#.*$//'` deletes a `#` INSIDE A STRING. `grep -qF "#N"` becomes
#     `grep -qF "`, so the remedy corrupts the very code it is filtering.
#     Comment detection needs the shell's quoting state, so this reuses the ONE
#     state machine (`_shell_quotes.awk`) rather than writing a second, wrong
#     one — which is the mistake `#842` made and `#838` is about.
#
#  2. `#` only starts a comment at the START OF A WORD. `echo a#b` prints
#     `a#b`; `${x#y}` is a parameter expansion. So the `#` must be at column 1
#     or preceded by whitespace or a command separator.
#
# AND THE CALLER MUST NOT PIPE INTO AN EARLY-EXITING READER. `#1106`'s own
# first measurement was wrong this way: `sed 's/#.*$//' "$f" | grep -qE '…'`
# under `pipefail` gives `grep -q` an early exit, `sed` takes SIGPIPE, and the
# pipeline returns 141 — reintroducing, inside the classifier, the early-exit
# defect the classifier exists to find. It reported 115 -> 81 rows, which reads
# as a large real effect and is an artefact. This function therefore returns
# the text on stdout for the caller to put in a VARIABLE, and every call site
# in this repo uses a herestring.
shf_strip_comments() {   # <file>  -> code-only text on stdout
    local f="$1" qawk _rc
    qawk=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/watcher/_shell_quotes.awk
    if [[ ! -r "$qawk" ]]; then
        printf 'shf_strip_comments: missing %s — refusing to fall back to a\n' "$qawk" >&2
        printf '  matcher that cannot tell a comment from a string.\n' >&2
        return 2
    fi
    # HEREDOC BODIES ARE BLANKED FIRST (your-org/nexus-code#1227).
    #
    # A heredoc body is DATA the file emits, not shell source, and feeding it to
    # `quote_mask` lets its prose set the quote state — the commonest apostrophe
    # in English is the one in a contraction, so one `orchestrator's` inside a
    # `<<MSG` opens a phantom string and every later `#` is read as quoted text
    # and EMITTED AS CODE. Measured at `0b82ffb2`: 589 of 2,057 leaked comment
    # lines across the corpus stop leaking when the bodies are blanked first,
    # `monitor/svc.sh` 57 -> 0 and `monitor/watcher/entry.sh` 82 -> 0. Quoted and
    # unquoted delimiters leak identically, so "a quoted delimiter is safe" does
    # not help.
    #
    # DIRECTION, measured rather than assumed. Restricted to lines that are NOT
    # heredoc bodies — the only population any consumer of this function can
    # legitimately want — blanking loses 541 lines, ALL of them comment lines,
    # and gains exactly 1 (`test-launcher-empty-target.sh:398`, a `# read the
    # status line` inside a quoted string that this function used to DELETE, so
    # the gain is a false negative repaired). ZERO lines of real code change.
    #
    # THE FAIL-SAFE PASSES THROUGH. When `shf_strip_heredocs` cannot parse a
    # file it emits it UNSTRIPPED and warns on stderr at rc 0; this function
    # then behaves exactly as it did before, which is the conservative
    # direction, and the warning reaches the caller's stderr rather than being
    # swallowed. Exactly one file trips it at `0b82ffb2`, and it is the one
    # already pinned in watcher/strip-heredocs-failsafe.manifest.
    local _view
    _view=$(mktemp) || {
        printf 'shf_strip_comments: mktemp failed — refusing to scan %s with\n' "$f" >&2
        printf '  heredoc bodies unblanked.\n' >&2
        return 2
    }
    if ! shf_strip_heredocs "$f" > "$_view"; then
        rm -f "$_view"
        printf 'shf_strip_comments: shf_strip_heredocs could not read %s\n' "$f" >&2
        return 2
    fi

    # CONCATENATED, not a second `-f`: `awk -f lib.awk '{prog}' file` treats the
    # program string as a DATA FILE and silently emits nothing.
    awk "$(cat "$qawk")"'
    {
        # CARRY THE QUOTE STATE ACROSS THE NEWLINE. Without this the mask is
        # computed per line, so a line that begins INSIDE an open string and
        # starts with `#` is read as a comment and DELETED — taking any real
        # code after the string closes with it. Measured before the fix:
        #     msg="hello
        #     # world" ; set -o pipefail
        # is `pipefail` ON in bash, matched in the raw text, and MISSED after
        # stripping. That is a FALSE NEGATIVE this helper introduced, which the
        # bare `grep` it replaced did not have (your-org/nexus-code#1127).
        #
        # AND THE CARRY MUST COME FROM THE CODE, NOT FROM THE WHOLE LINE
        # (your-org/nexus-code#1130). Taking `QM_END` from the full line lets
        # COMMENT PROSE change the quote state, and the commonest apostrophe in
        # English is the one in a contraction:
        #     # it doesn'"'"'t matter what the author says here
        #     # THIS LINE IS THEN INSIDE A STRING AND SURVIVES
        # Measured on this host: the second comment line is EMITTED AS CODE, and
        # every line after it until the apostrophe is balanced. The stripper
        # then leaks exactly the comment text it exists to remove, so `#1106`s
        # comment-blindness fix is silently defeated for any file whose comments
        # contain a contraction — which is most of them. Text after an unquoted
        # `#` is not shell input and cannot open a string, so the state is
        # recomputed over the retained CODE only. The `#1127` cross-line-string
        # case above is unaffected: there the `#` IS inside a string, nothing is
        # cut, and the code portion is the whole line.
        # CARRY THE `$( … )` NESTING TOO, NOT JUST THE QUOTE STATE
        # (your-org/nexus-code#1227). A line ending inside an open `$(`
        # continues as code, which `QM_END` already said — but the STACK that
        # tells the next line'"'"'s `)` what it closes was a function-local and
        # reset. `monitor/ng:1129` is exactly that shape, and the consequence
        # is not a lost `)`: the next `"` then OPENS a string instead of
        # closing one, so every later line reads as quoted, `#` is skipped as
        # text, and the rest of the file'"'"'s comments are EMITTED AS CODE.
        #
        # TWO ARRAY PAIRS, and this is load-bearing rather than tidiness. The
        # block scans twice — once over `$0` to place the cut, once over the
        # retained `code` to compute the state to carry — and awk passes arrays
        # BY REFERENCE. One pair would let the throwaway `$0` scan mutate the
        # nesting that the `code` scan must start from, so a `)` in COMMENT
        # PROSE could pop a real open substitution. The `$0` scan gets a
        # SCRATCH COPY (`_ss`/`_sd`); only the `code` scan touches the
        # persistent pair (`_ps`/`_pd`).
        for (_k in _ss) delete _ss[_k]
        for (_k in _sd) delete _sd[_k]
        for (_k = 1; _k <= carrysp; _k++) { _ss[_k] = _ps[_k]; _sd[_k] = _pd[_k] }
        m = quote_mask($0, carry, carrysp, _ss, _sd)
        cut = 0
        for (i = 1; i <= length($0); i++) {
            if (substr($0, i, 1) != "#")   continue
            if (substr(m,   i, 1) == "1")  continue     # inside a string
            if (i > 1) {
                p = substr($0, i - 1, 1)
                # `#` starts a comment only at the start of a WORD.
                #
                # `(` IS NOT A WORD SEPARATOR FOR THIS PURPOSE
                # (your-org/nexus-code#1227). It was in this class, and every
                # site it fired on at `0b82ffb2` was REAL CODE DESTROYED, not a
                # comment found — 8 cuts across 4 files, 7 of them an issue
                # reference `(#781)` inside a quoted `printf`, and the eighth
                # the ERE `^[[:space:]]*(#|$)` at labsh-supervised.sh:247, where
                # the `#` is genuinely UNQUOTED and genuinely NOT a comment.
                # bash parses that line; this function output does not, which is
                # how it was found. A real `( #comment` carries the SPACE and is
                # still caught by the space arm, so nothing is lost.
                #
                # DIRECTION: this trades a guaranteed FALSE NEGATIVE (real code
                # deleted, silently) for a possible FALSE POSITIVE (a comment
                # retained, loudly). Measured cost at `0b82ffb2`, alone: leaked
                # comment lines 2,057 -> 2,064 (+7, same 63 files), and one of
                # the six files whose stripped output no longer parses is
                # repaired. It is NOT free and is not claimed to be: not cutting
                # at `(#` moves the cut, which moves the carried state. The
                # trade is still right, because +7 retained comments is a
                # louder failure than one deleted `[[ =~ ]]` operand.
                if (p !~ /[ \t;&|]/) continue
            }
            cut = i; break
        }
        if (cut > 0) code = substr($0, 1, cut - 1); else code = $0
        # Recompute over the RETAINED CODE only, from the same start state,
        # then carry BOTH halves. Order matters: `carry`/`carrysp` are the
        # INPUTS here, so they are reassigned only after the call.
        quote_mask(code, carry, carrysp, _ps, _pd); carry = QM_END; carrysp = QM_SP
        print code
    }' "$_view"
    _rc=$?
    rm -f "$_view"
    return $_rc
}
