#!/usr/bin/env bash
# artifact-link-check.sh — warn when a GitHub-bound body carries a claude.ai
# Artifact link and NO nexus asset link (your-org/nexus-code#1856).
#
# THE DEFECT. Agents published review material as claude.ai Artifacts and
# posted only the Artifact link on a GitHub thread. The operator reading on
# GitHub cannot open those links ("We cannot view anthropic artifacts here.
# Everything has to be uploaded as a nexus asset."), so the deliverable existed
# only on a surface its reader cannot reach. Nothing errored: the comment
# posted, assert-bot-author passed, and the thread simply lacked its content.
# Measured 2026-10-16 in one nexus: three deliverables in one day, each
# needing a follow-up upload.
#
# THE RULE, and only this: a body that names `claude.ai/artifact/` or
# `claude.ai/code/artifact/` and contains NO nexus asset link — a
# `https://github.com/<owner>/<repo>/(blob|raw)/<ref>/assets/…` URL, the shape
# `ng upload` prints — is flagged. An Artifact BESIDE an asset is fine: it is
# an optional extra, never the only copy.
#
# A WARNING, NEVER A REFUSAL, and it never changes an exit code. The comment
# is still worth posting, and a guard that blocked a publish would be worked
# around rather than read. It is loud (stderr, names `ng upload`) because the
# failure it catches is silent by construction.
#
# ERROR DIRECTION, stated. The asset test is PRESENCE of any asset link, not a
# pairing of each Artifact with its copy, so a body with two Artifacts and one
# asset for only one of them passes: it errs toward SILENCE. A non-nexus
# GitHub-viewable copy (a gist, a `user-attachments` image) is not recognised,
# so such a body warns: it errs toward NOISE there. Both are deliberate; the
# measured incidents were all Artifact-only bodies.
#
# Use:
#   source monitor/artifact-link-check.sh; alc_warn "<body>" "<where>"   # rc 0 always
#   alc_flags "<body>"        # rc 0 = flagged, rc 1 = clean (no output)
#   monitor/artifact-link-check.sh [--where <label>] [<file>|-]   # CLI: rc 0 clean, 3 flagged,
#                             2 usage/unreadable, 64 argument loop made no progress (#924)

# The patterns are plain EREs evaluated by bash's own [[ =~ ]], so the answer
# does not depend on which `grep` a shell function routes to (CLAUDE.md, the
# ugrep wrapper entries).
ALC_ARTIFACT_RE='claude\.ai/(code/)?artifact/'
ALC_ASSET_RE='github\.com/[^/[:space:]]+/[^/[:space:]]+/(blob|raw)/[^/[:space:]]+/assets/'

alc_flags() {
    local body="${1-}"
    [[ "$body" =~ $ALC_ARTIFACT_RE ]] || return 1
    [[ "$body" =~ $ALC_ASSET_RE ]] && return 1
    return 0
}

alc_warn() {
    local body="${1-}" where="${2:-this GitHub body}"
    alc_flags "$body" || return 0
    {
        printf 'WARNING (your-org/nexus-code#1856): %s links a claude.ai Artifact and carries NO nexus asset link.\n' "$where"
        printf '  A GitHub reader cannot open claude.ai Artifacts, so the deliverable is missing for them.\n'
        printf '  Upload it as a nexus asset and link THAT:  monitor/ng upload <file> [--issue N]\n'
        printf '  md, SVG and PNG render on GitHub; raw HTML does NOT, so ship an .md (or images) beside any HTML.\n'
        printf '  An Artifact link may stay as an optional extra, never as the only copy.\n'
    } >&2
    return 0
}

# CLI only when executed, never when sourced.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Argument-loop progress guard (your-org/nexus-code#924): a loop that did
    # not consume an argument would spin forever; refuse instead.
    _argloop_stuck() {
        printf 'artifact-link-check: option %s made no progress (argument loop made no progress)\n' "${1-}" >&2
        exit 64
    }
    where=""
    src=""
    _argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
        case "$1" in
            --where) where="${2:-}"; shift 2 || { echo "artifact-link-check: --where needs a value" >&2; exit 2; } ;;
            -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) [[ -z "$src" ]] || { echo "artifact-link-check: one input only" >&2; exit 2; }
               src="$1"; shift ;;
        esac
    done
    if [[ -z "$src" || "$src" == "-" ]]; then
        body=$(cat)
    else
        [[ -r "$src" ]] || { echo "artifact-link-check: cannot read $src" >&2; exit 2; }
        body=$(<"$src")
    fi
    if alc_flags "$body"; then
        alc_warn "$body" "${where:-${src:-stdin}}"
        exit 3
    fi
    exit 0
fi
