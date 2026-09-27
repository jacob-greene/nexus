#!/usr/bin/env bash
# leak-gate.sh — fail (nonzero) if any denied internal token survives in the
# tracked tree. Patterns are read from the mapping file (`deny`/`keep` lines);
# this script hardcodes NO identifiers, so its own public copy is clean.
#
#   leak-gate.sh <mapping.tsv> [<repo-dir>] [--allow-unstaged] [--commit <sha>]
#
# Exit 0 = clean. Exit 1 = leak (offending lines printed). Exit 2 = usage, and
#          (with --commit) REFUSED: the sha does not resolve to a commit, or
#          <repo-dir> is not a git work tree.
# Exit 5 = REFUSED: the index and the working tree disagree, so this gate cannot
#          say which artifact it is vouching for. See below. With --commit,
#          also: the commit's TREE is not the index this gate scanned.
# Exit 6 = REFUSED: the index holds an entry whose PUBLISHED content this gate
#          cannot read, so a PASS would describe a smaller population than the
#          one being shipped. See the index-entry scan below.
#
# --commit <sha> — the mirror is published as ONE commit per sync, so that
# commit's MESSAGE and IDENTITIES are published bytes too, and the tree scan
# never reads them (your-org/nexus-code#979, #1006). With --commit the gate
# ALSO screens every published header of the commit object — author and
# committer (name AND email), any extra header (encoding, mergetag, …) — and
# the FULL message, against the same deny/keep patterns. Only `tree`/`parent`
# are skipped: they are object ids, not authored text.
#
# SCOPE: metadata + the tree BY BINDING, not by a second scan. The commit's
# tree must be byte-identical to the INDEX (`git diff-index --cached`), which
# is the population every check below already scans (the exit-5 refusal pins
# the index to the working tree). So a PASS with --commit says: this commit's
# metadata is clean AND its tree is the one this run scanned. A commit whose
# tree differs is REFUSED (exit 5), never scanned separately — a second,
# independent tree scanner would be a second gate to keep in sync with this
# one. Without --commit, behaviour is unchanged.
set -uo pipefail
export LC_ALL=C
ALLOW_UNSTAGED=0
COMMIT_MODE=0
COMMIT=""
args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --allow-unstaged) ALLOW_UNSTAGED=1 ;;
        --commit)
            [ "$#" -ge 2 ] || { echo "leak-gate: --commit needs a <sha>" >&2; exit 2; }
            COMMIT_MODE=1; COMMIT="$2"; shift ;;
        *) args+=("$1") ;;
    esac
    shift
done
set -- ${args[@]+"${args[@]}"}
MAP="${1:?usage: leak-gate.sh <mapping.tsv> [repo-dir] [--allow-unstaged] [--commit <sha>]}"
DIR="${2:-.}"
cd "$DIR"

# --commit: resolve FIRST, and fail closed. A sha that does not name a commit
# in THIS repository is a refusal, never a skipped check — `git rev-parse` on a
# typo would otherwise leave nothing to screen, and "nothing screened" must not
# print PASS. `^{commit}` also refuses a tree or blob id passed by mistake.
if [ "$COMMIT_MODE" -eq 1 ]; then
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "LEAK GATE: REFUSED — --commit needs a git work tree; $DIR is not one." >&2
        exit 2
    fi
    if [ -z "$COMMIT" ] || ! COMMIT_SHA=$(git rev-parse --verify --quiet "${COMMIT}^{commit}" 2>/dev/null) \
       || [ -z "$COMMIT_SHA" ]; then
        echo "LEAK GATE: REFUSED — --commit '$COMMIT' does not resolve to a commit in $DIR." >&2
        echo "  Nothing was screened; this is not a PASS." >&2
        exit 2
    fi
fi

# ---- REFUSE TO VOUCH FOR AN ARTIFACT THAT IS NOT THE ONE BEING SHIPPED ------
#
# This gate reads the WORKING TREE (`git grep`, below). The publish path reads
# the INDEX (`git write-tree` -> `git commit-tree` -> push). `build.sh` scrubs
# the working tree and does not stage. So when the two disagree, a PASS here is
# a statement about a tree nobody is going to push — and it says PASS rather
# than saying it cannot tell.
#
# Measured on a fully-fixed tree (your-org/nexus-code#979 F2): run the recipe,
# omit `git add -A`, and this gate returns 0 while the tree `git write-tree`
# produces carries 512 leaking files. The documented remedy was a README line,
# and a documented step that silently ships 512 unscrubbed files when skipped —
# on a surface whose failure mode is a PERMANENT PUBLIC DISCLOSURE — is not a
# remedy. Nothing here depends on operator judgement, so it is mechanical.
#
# `--allow-unstaged` is for the legitimate other caller: a test or an operator
# deliberately scanning a working copy that is not bound for publication. It
# says so loudly, so the two cases never share a spelling.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # `git diff --quiet` compares the INDEX against the WORKING TREE, which is
    # exactly the disagreement that matters. NOT `--cached`: that compares the
    # index against HEAD, and after a correct `git add -A` of a scrubbed tree
    # those differ by the entire scrub — checking it refuses the right answer.
    if ! git diff --quiet 2>/dev/null; then
        if [ "$ALLOW_UNSTAGED" -eq 1 ]; then
            echo "leak-gate: NOTE — index and working tree differ; this verdict covers the WORKING TREE only, not what \`git write-tree\` would record." >&2
        else
            echo "LEAK GATE: REFUSED — the index and the working tree disagree." >&2
            echo "  This gate reads the working tree; the publish path (git write-tree) reads the index." >&2
            echo "  A PASS here would describe a tree that is not the one you would ship." >&2
            echo "  If you are publishing:      git add -A   (then re-run this gate)" >&2
            echo "  If you are scanning a copy: re-run with --allow-unstaged" >&2
            exit 5
        fi
    fi
fi

DENY=$(awk -F'\t' '$1=="deny"{print $2}' "$MAP" | paste -sd'|')
KEEP=$(awk -F'\t' '$1=="keep"{print $2}' "$MAP" | paste -sd'|')
[ -n "$DENY" ] || { echo "leak-gate: empty denylist in $MAP" >&2; exit 2; }

# ---- --commit: THE COMMIT'S METADATA, AND ITS TREE BY BINDING ---------------
#
# The sync publishes ONE commit on top of the public HEAD. Its message and its
# author/committer identities ship verbatim, and no tree scan reads them: an
# operator's private address in the committer line, or an internal issue ref
# in the message body, passed every check in this file. (your-org/nexus-code
# #979, #1006.) Screening lives HERE rather than in the recipe so the recipe
# cannot forget it.
if [ "$COMMIT_MODE" -eq 1 ]; then
    # Binding: the tree this run scans is the WORKING TREE, pinned to the INDEX
    # by the exit-5 check above — unless --allow-unstaged waived that pin, in
    # which case the scanned tree is not the index and cannot vouch for a
    # commit made from it. Both equalities are required; neither is implied.
    if ! git diff --quiet 2>/dev/null; then
        echo "LEAK GATE: REFUSED — --commit with an index that differs from the working tree." >&2
        echo "  This run scans the working tree; the commit records a tree built from the index." >&2
        exit 5
    fi
    git diff-index --cached --quiet "$COMMIT_SHA" -- 2>/dev/null; _bind_rc=$?
    if [ "$_bind_rc" -ne 0 ]; then
        echo "LEAK GATE: REFUSED — commit ${COMMIT_SHA}'s tree is not the index this gate scans (diff-index rc=$_bind_rc)." >&2
        echo "  A PASS would vouch for a tree nobody scanned. Re-run on the tree the commit was made from." >&2
        exit 5
    fi

    # Every header except the object-id ones, then the whole message. An ident
    # is split into NAME and EMAIL so the report names the field; the trailing
    # timestamp is digits and is not screened. A header that does not parse as
    # an ident is screened WHOLE rather than skipped.
    #
    # Read the object into a variable FIRST: a `< <(git cat-file …)` whose
    # producer failed would feed an empty stream and screen nothing — a PASS
    # over zero fields. Both identity headers must then actually be SEEN.
    # `-e` before each pattern: a deny/keep regex beginning with `-` would
    # otherwise be read as an OPTION (CLAUDE.md, DASH-PATTERN-OPTION).
    if ! _raw=$(git cat-file commit "$COMMIT_SHA" 2>/dev/null); then
        echo "LEAK GATE: REFUSED — cannot read commit object ${COMMIT_SHA}." >&2
        exit 2
    fi
    _ident_re='^(.*) <([^>]*)>( .*)?$'
    meta_hits=""
    _in_msg=0; _n=0; _hdr=""; _seen=""
    while IFS= read -r _l; do   # herestring below: the final line is always terminated
        if [ "$_in_msg" -eq 0 ]; then
            if [ -z "$_l" ]; then _in_msg=1; continue; fi
            case "$_l" in
                " "*) _fields=("${_hdr}	${_l# }") ;;   # continuation of the previous header
                *)
                    _hdr=${_l%% *}; _val=${_l#* }
                    [ "$_val" = "$_l" ] && _val=""
                    case "$_hdr" in
                        tree|parent) continue ;;
                        author|committer)
                            _seen="${_seen} ${_hdr}"
                            if [[ "$_val" =~ $_ident_re ]]; then
                                _fields=("${_hdr}.name	${BASH_REMATCH[1]}" "${_hdr}.email	${BASH_REMATCH[2]}")
                            else
                                _fields=("${_hdr}	${_val}")
                            fi ;;
                        *) _hdr="header.${_hdr}"; _fields=("${_hdr}	${_val}") ;;
                    esac ;;
            esac
        else
            _n=$((_n+1)); _fields=("message:${_n}	${_l}")
        fi
        for _f in "${_fields[@]}"; do
            _txt=${_f#*	}
            grep -qiE -e "$DENY" <<<"$_txt" || continue
            if [ -n "$KEEP" ] && grep -qE -e "$KEEP" <<<"$_txt"; then continue; fi
            meta_hits="${meta_hits}${_f%%	*}:${_txt}
"
        done
    done <<<"$_raw"
    case "$_seen" in
        *" author"*" committer"*) : ;;
        *)  echo "LEAK GATE: REFUSED — commit ${COMMIT_SHA}: author/committer headers not found; nothing was screened." >&2
            exit 2 ;;
    esac
    meta_hits=$(printf '%s\n' "$meta_hits" | sed '/^$/d')
    if [ -n "$meta_hits" ]; then
        echo "LEAK GATE: FAIL — denied token in commit ${COMMIT_SHA} METADATA (message / author / committer ship verbatim)"
        printf '%s\n' "$meta_hits"
        exit 1
    fi
fi

# Dictionary guard: the `exclude` paths hold the ONE un-scrubbed copy of the
# internal dictionary (it names every source identifier by design). It must
# never appear in a tree bound for publication. build.sh drops it; this is the
# independent second check so the gate catches a leaked dictionary even when run
# on a hand-assembled tree. (your-org/nexus-code#537)
excl_present=0
while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    if [ -e "$ex" ]; then
        echo "LEAK GATE: FAIL — excluded internal-dictionary path present: $ex"
        excl_present=$((excl_present+1))
    fi
done < <(awk -F'\t' '$1=="exclude"{print $2}' "$MAP")
[ "$excl_present" -eq 0 ] || exit 1

# PATH check. `git grep` reads file CONTENTS; a denied identifier sitting in a
# file NAME was invisible to this gate entirely, and the only thing keeping such
# names off the mirror was an operator remembering to rename by hand. Found by a
# mutant: deleting a `rename` row from the build's rename manifest left the
# abbreviation in two basenames and every check stayed green.
# (your-org/nexus-code#979 §2)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    path_hits=$(git ls-files | grep -inE "$DENY" 2>/dev/null)
else
    path_hits=$(find . -path ./.git -prune -o -type f -print 2>/dev/null | grep -inE "$DENY" 2>/dev/null)
fi
[ -n "$KEEP" ] && path_hits=$(printf '%s\n' "$path_hits" | grep -vE "$KEEP")
path_hits=$(printf '%s\n' "$path_hits" | sed '/^$/d')
if [ -n "$path_hits" ]; then
    echo "LEAK GATE: FAIL — denied token in a file PATH (rename it; contents are not the only surface)"
    printf '%s\n' "$path_hits"
    exit 1
fi

# ---- EVERY PUBLISHED BYTE, NOT EVERY BYTE `git grep` HAPPENS TO READ --------
#
# The content scan below is `git grep`, which reads the working tree's REGULAR
# files. The publish path is `git write-tree`, which records EVERY index entry
# — including entries whose content `git grep` never opens. A tracked SYMLINK
# is the live instance: its blob content IS its target path, `git write-tree`
# publishes that blob verbatim, and BOTH `git grep` and `git grep --cached`
# return nothing for it. Measured on a synthetic dictionary: a link whose
# target carried a denied token passed this gate clean, printed
# "PASS — zero denied tokens", and the published blob still read the denied
# path. Three defensible choices lined up to produce it — build.sh skips
# symlinks (writing through one corrupts its target), this gate's PATH check
# reads only the link's own NAME, and git grep does not read symlink content.
# (your-org/nexus-code#1294)
#
# Keyed on the PROPERTY — *can this gate READ the bytes this entry publishes?*
# — and NOT on a file-type enumeration, so the next object type git learns to
# record is a REFUSAL rather than a silent pass. That makes this an ALLOWLIST
# of modes whose content is demonstrably scanned, with a default-DENY arm. The
# arms are literal equality over disjoint mode values, so no SAFE arm can
# shadow the DENY arm and no reordering changes the verdict
# (your-org/nexus-code#1121).
#
#   100644 / 100755  regular blob   -> read by the `git grep` below. Binary
#                                      files included: without `-I` git grep
#                                      reports "Binary file X matches", which
#                                      lands in $hits. Do NOT add `-I`.
#   120000           symlink        -> git grep reads NOTHING. Scanned here,
#                                      directly against the blob.
#   anything else    (160000 gitlink, or a mode that does not exist yet)
#                                   -> REFUSED. A submodule's content is not in
#                                      this tree at all and cannot be vouched
#                                      for from here.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    sym_hits=""
    unreadable=""
    while IFS= read -r _ent; do
        [ -n "$_ent" ] || continue
        # `git ls-files -s` prints: <mode> SP <sha> SP <stage> TAB <path>
        _mode=${_ent%% *}
        _rest=${_ent#* }
        _sha=${_rest%% *}
        _path=${_ent#*$'\t'}
        case "$_mode" in
            100644|100755) : ;;
            120000)
                # A symlink's blob content IS its target path. Read the blob,
                # not the link: following the link would read the TARGET FILE,
                # which is a different question and is not what gets published.
                if ! _tgt=$(git cat-file blob "$_sha" 2>/dev/null); then
                    unreadable="${unreadable}${_path}	mode=${_mode} blob=${_sha} (unreadable)
"
                elif grep -qiE "$DENY" <<<"$_tgt"; then
                    sym_hits="${sym_hits}${_path} -> ${_tgt}
"
                fi
                ;;
            *)
                unreadable="${unreadable}${_path}	mode=${_mode} (content not scannable by this gate)
"
                ;;
        esac
    done < <(git ls-files -s)

    [ -n "$KEEP" ] && sym_hits=$(printf '%s\n' "$sym_hits" | grep -vE "$KEEP")
    sym_hits=$(printf '%s\n' "$sym_hits" | sed '/^$/d')
    if [ -n "$sym_hits" ]; then
        echo "LEAK GATE: FAIL — denied token in a tracked SYMLINK TARGET"
        echo "  (git write-tree publishes a symlink's blob verbatim, and that blob IS this path)"
        printf '%s\n' "$sym_hits"
        exit 1
    fi

    unreadable=$(printf '%s\n' "$unreadable" | sed '/^$/d')
    if [ -n "$unreadable" ]; then
        echo "LEAK GATE: REFUSED — the index holds entries whose published content this gate cannot read." >&2
        printf '%s\n' "$unreadable" >&2
        echo "  A PASS here would be a claim about a SMALLER population than the one being published." >&2
        echo "  Teach this gate to read the mode, or drop the entry from the tree before publishing." >&2
        exit 6
    fi
else
    # NON-GIT TREE — the fallback the other two checks already have
    # (your-org/nexus-code#1294, reopened). Both the PATH check above and the
    # CONTENT check below fall back to `find`/`grep -r` when there is no index,
    # because a hand-assembled tree is a SUPPORTED mode of this gate and its
    # own comments say so. The symlink check had no such arm, so in exactly
    # that mode it scanned file NAMES and file CONTENTS and silently skipped
    # symlink TARGETS — #1294's hole, surviving inside #1294's own fix.
    #
    # Latent rather than live: no in-tree caller runs this gate outside a git
    # checkout today. Restored rather than declared out of scope, because an
    # asymmetry between three checks in one file is not a scope decision anyone
    # made — and the direction is the bad one, a silently smaller population
    # under a clean verdict.
    #
    # WHAT THIS ARM CANNOT DO, said rather than implied: with no index there
    # are no MODES to partition, so the exit-6 "cannot read this entry"
    # refusal has no analogue here. A non-git tree therefore gets symlink
    # coverage but NOT the unreadable-mode guarantee. That is a real gap in a
    # mode nothing currently uses; it is written down so the next reader does
    # not have to re-derive which half is missing.
    sym_hits=$(find . -path ./.git -prune -o -type l -print 2>/dev/null \
        | while IFS= read -r _l; do
              [ -n "$_l" ] || continue
              printf '%s -> %s\n' "$_l" "$(readlink "$_l" 2>/dev/null)"
          done | grep -inE "$DENY" 2>/dev/null)
    [ -n "$KEEP" ] && sym_hits=$(printf '%s\n' "$sym_hits" | grep -vE "$KEEP")
    sym_hits=$(printf '%s\n' "$sym_hits" | sed '/^$/d')
    if [ -n "$sym_hits" ]; then
        echo "LEAK GATE: FAIL — denied token in a SYMLINK TARGET (non-git tree)"
        echo "  (the link's target path is the byte sequence a publish would carry)"
        printf '%s\n' "$sym_hits"
        exit 1
    fi
fi

hits=$(git grep -inE "$DENY" -- . 2>/dev/null)
# also scan any file present but untracked (a hand-assembled tree may not be a
# git checkout); fall back to a plain recursive grep when git-grep finds nothing
if [ -z "$hits" ] && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    hits=$(grep -rinE "$DENY" --exclude-dir=.git . 2>/dev/null)
fi
[ -n "$KEEP" ] && hits=$(printf '%s\n' "$hits" | grep -vE "$KEEP")
hits=$(printf '%s\n' "$hits" | sed '/^$/d')

if [ -n "$hits" ]; then
    echo "LEAK GATE: FAIL"
    printf '%s\n' "$hits"
    exit 1
fi
echo "LEAK GATE: PASS — zero denied tokens (keep-list applied)"
if [ "$COMMIT_MODE" -eq 1 ]; then
    echo "LEAK GATE: PASS — commit ${COMMIT_SHA}: metadata clean, and its tree is the index scanned above"
fi
exit 0
