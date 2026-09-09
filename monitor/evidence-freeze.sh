#!/usr/bin/env bash
# monitor/evidence-freeze.sh — freeze an artefact into durable evidence
# storage so that a later overwrite CANNOT pass the integrity check.
#
# WHY. A freeze is the copy that proves, afterwards, that nothing was
# lost. The hand-rolled form every worker prompt has carried so far is:
#
#     cp -p <artefact> "$EV/<name>"
#     cd "$EV" && md5sum *.ipynb > MANIFEST.md5 && md5sum -c MANIFEST.md5
#
# Run twice, that destroys the baseline AND refreshes the checksum that
# would have caught it, so `md5sum -c` reports OK on the substituted
# bytes. `cp -p` compounds it: the copy keeps the SOURCE mtime, so the
# replaced file does not even look freshly written. That sequence
# destroyed an 11,648,117-byte baseline (`fb2c326b…`) on 2026-09-09; it
# is unrecoverable. The three properties this script enforces are each
# the inverse of one of those mistakes:
#
#   1. REFUSE TO CLOBBER. An existing target is an error, never an
#      overwrite. The first freeze under a name wins.
#   2. READ-ONLY COPIES (mode 0440). A later `cp` over a frozen file
#      fails with EACCES instead of succeeding quietly.
#   3. APPEND-ONLY MANIFEST. `MANIFEST.md5` is left mode 0440, so a
#      wholesale `md5sum … > MANIFEST.md5` fails with EACCES. This
#      script appends (`>>`) under a brief chmod, and refuses to append
#      a name the manifest already records.
#
# It also copies WITHOUT `-p`, so the frozen file's mtime is the time
# the freeze happened — the evidence a reader needs.
#
# WHAT THIS DOES NOT PREVENT. Mode 0440 stops a WRITE to a frozen file.
# It does not stop an UNLINK: the evidence directory itself is mode
# 0770, so the owning uid can `rm` a freeze and its manifest, recreate
# both, and `--verify` then reports clean on the new bytes. The guard
# closes the accidental path — the two incident commands now fail with
# EACCES — not a deliberate remove-and-recreate. `test-evidence-freeze.sh`
# case 10 pins that limit so nobody reads the suite as proof of
# impossibility. Closing it means holding the evidence DIRECTORY
# read-only between freezes, which also blocks every other write into
# the directory (sub-directories, READMEs). That is a policy decision
# for the operator, not a silent addition here.
#
# Usage:
#   evidence-freeze.sh <source> --task <slug> [--as <name>]
#   evidence-freeze.sh <source> --dir <evidence-dir> [--as <name>]
#   evidence-freeze.sh --verify (--task <slug> | --dir <evidence-dir>)
#
#   --task <slug>   evidence dir is $STATE_DIR/evidence/<slug> (created
#                   if missing). The usual form; <slug> is the task or
#                   window name.
#   --dir <path>    an explicit evidence directory (created if missing).
#   --as <name>     frozen name (default: the source's basename). Give
#                   a name that marks the pass, e.g. `nb.PRE_FIXPASS.ipynb`.
#   --verify        check every manifest entry, plus the mode-0440 and
#                   manifest-coverage invariants. Writes nothing.
#
# Exit codes:
#   0  frozen (or verified clean)
#   2  bad usage / unreadable source
#   3  target already exists — REFUSED (nothing was written)
#   4  MANIFEST.md5 already records that name, or cannot be appended to
#   5  --verify found a mismatch, a missing file, or a broken invariant
#
# Env seams (tests): NEXUS_STATE_DIR / NEXUS_ROOT resolve the state dir,
# exactly as pane-state.sh and retire-preflight.sh resolve it.

set -uo pipefail

usage() {
    sed -n '/^# Usage:/,/^#   5 /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || self_dir="."

# ---- resolve STATE_DIR (mirrors pane-state.sh / retire-preflight.sh) ------
if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    STATE_DIR="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    STATE_DIR="$NEXUS_ROOT/monitor/.state"
else
    STATE_DIR="$self_dir/.state"
fi

MANIFEST_NAME="MANIFEST.md5"

src=""
task=""
dir=""
as_name=""
mode="freeze"

while (( $# )); do
    case "$1" in
        --task)    task="${2:-}"; shift 2 || usage ;;
        --dir)     dir="${2:-}";  shift 2 || usage ;;
        --as)      as_name="${2:-}"; shift 2 || usage ;;
        --verify)  mode="verify"; shift ;;
        -h|--help) usage ;;
        --)        shift; src="${1:-}"; break ;;
        -*)        usage ;;
        *)         src="$1"; shift ;;
    esac
done

[[ -n "$task" || -n "$dir" ]] || usage
[[ -z "$task" || -z "$dir" ]] || {
    echo "evidence-freeze: give --task OR --dir, not both" >&2; exit 2; }
[[ -n "$dir" ]] || dir="$STATE_DIR/evidence/$task"

# ---- verify mode ---------------------------------------------------------
# Three separate checks. Each can fail on its own, and each is reported,
# so one clean line never stands for an unrun check.
if [[ "$mode" == verify ]]; then
    [[ -d "$dir" ]] || { echo "evidence-freeze: no such evidence dir: $dir" >&2; exit 2; }
    manifest="$dir/$MANIFEST_NAME"
    [[ -f "$manifest" ]] || { echo "evidence-freeze: no $MANIFEST_NAME in $dir" >&2; exit 5; }
    rc=0

    if ( cd "$dir" && md5sum -c "$MANIFEST_NAME" ); then
        :
    else
        echo "evidence-freeze: CHECKSUM MISMATCH in $dir — a frozen file has changed" >&2
        rc=5
    fi

    # Invariant 2: every frozen file is read-only. A writable freeze is a
    # freeze the next `cp` overwrites in silence.
    while read -r _sum name; do
        [[ -n "${name:-}" ]] || continue
        name="${name#\*}"
        [[ -e "$dir/$name" ]] || continue
        if [[ -w "$dir/$name" ]]; then
            echo "evidence-freeze: WRITABLE freeze: $name (want mode 0440)" >&2
            rc=5
        fi
    done < "$manifest"

    # Invariant 3: the manifest is not writable, so it cannot be
    # regenerated by a stray redirect.
    if [[ -w "$manifest" ]]; then
        echo "evidence-freeze: WRITABLE $MANIFEST_NAME — a regeneration would not fail" >&2
        rc=5
    fi

    (( rc == 0 )) && echo "evidence-freeze: $dir verified clean"
    exit "$rc"
fi

# ---- freeze mode ---------------------------------------------------------
[[ -n "$src" ]] || usage
[[ -f "$src" ]] || { echo "evidence-freeze: not a readable file: $src" >&2; exit 2; }
[[ -n "$as_name" ]] || as_name=$(basename -- "$src")
case "$as_name" in
    */*|"") echo "evidence-freeze: --as takes a bare file name, not a path: $as_name" >&2; exit 2 ;;
    "$MANIFEST_NAME") echo "evidence-freeze: refusing to freeze over $MANIFEST_NAME" >&2; exit 2 ;;
esac

mkdir -p "$dir" || { echo "evidence-freeze: cannot create $dir" >&2; exit 2; }
target="$dir/$as_name"
manifest="$dir/$MANIFEST_NAME"

# 1. Refuse to clobber. Print the existing file's hash so the caller can
#    tell "already frozen, identical" from "a different artefact wants
#    this name" without touching anything.
if [[ -e "$target" ]]; then
    existing=$(md5sum < "$target" 2>/dev/null | cut -d' ' -f1)
    incoming=$(md5sum < "$src" 2>/dev/null | cut -d' ' -f1)
    {
        echo "evidence-freeze: REFUSED — $as_name already exists in $dir"
        echo "  existing: ${existing:-unreadable}"
        echo "  incoming: ${incoming:-unreadable}"
        echo "  A freeze is write-once. Pick a name that marks THIS pass, e.g."
        echo "  --as '${as_name%.*}.$(date +%Y%m%dT%H%M%S).${as_name##*.}'"
    } >&2
    exit 3
fi

# The manifest can record a name whose file was removed. Appending a
# second entry for it would leave two rows for one name, so refuse.
# Match the name field exactly — a substring test would refuse
# `nb.ipynb.bak` because `nb.ipynb` is already recorded.
_manifest_records() {
    local m="$1" n="$2"
    [[ -f "$m" ]] || return 1
    awk -v want="$n" '{ sub(/^[^ ]+  /, ""); sub(/^\*/, ""); if ($0 == want) found = 1 }
                      END { exit found ? 0 : 1 }' "$m"
}
if _manifest_records "$manifest" "$as_name"; then
    echo "evidence-freeze: REFUSED — $MANIFEST_NAME already records '$as_name' in $dir" >&2
    exit 4
fi

# 2. Copy WITHOUT -p: the frozen file's mtime must be the freeze time.
if ! cp -- "$src" "$target"; then
    echo "evidence-freeze: copy failed: $src -> $target" >&2
    rm -f -- "$target"
    exit 2
fi
chmod 0440 -- "$target" 2>/dev/null || true

# 3. Append to the manifest, never regenerate it. The manifest is held
#    read-only between appends, so a stray `md5sum … > MANIFEST.md5`
#    fails with EACCES rather than rewriting the record.
if [[ -f "$manifest" ]]; then
    chmod u+w -- "$manifest" 2>/dev/null || true
fi
if ! ( cd "$dir" && md5sum -- "$as_name" >> "$MANIFEST_NAME" ); then
    echo "evidence-freeze: could not append to $manifest — freeze left in place, NOT recorded" >&2
    chmod 0440 -- "$manifest" 2>/dev/null || true
    exit 4
fi
chmod 0440 -- "$manifest" 2>/dev/null || true

printf 'frozen %s -> %s\n' "$src" "$target"
printf 'md5    %s\n' "$(tail -1 "$manifest" | cut -d' ' -f1)"
printf 'mode   0440 (read-only); %s is append-only\n' "$MANIFEST_NAME"
exit 0
