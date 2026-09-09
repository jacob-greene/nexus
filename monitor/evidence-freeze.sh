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
# impossibility.
#
# Two different options close that gap. The operator picks one; this
# script implements neither, because the choice is a policy decision.
#
#   A. HOLD THE DIRECTORY READ-ONLY between freezes. Removing a file
#      needs write permission on the DIRECTORY, never on the file, so
#      this is the only local file mode that stops the unlink. It also
#      blocks every other write into the directory (sub-directories,
#      README notes), and the owning uid can chmod the directory back.
#      Under one uid it adds a command; it is not a boundary.
#   B. RECORD EACH FREEZE OUT OF BAND, and make `--verify` cross-check
#      the directory manifest against that record. Directory
#      permissions do not change at all. Two candidate records:
#      `monitor/.state/action-log.jsonl` (or a dedicated
#      `freeze-log.jsonl`), which already carries an
#      `artefact-collision` event with `live-md5` and `reviewed-md5`
#      fields; or a bot comment on the issue, which this uid cannot
#      rewrite and whose edits carry a visible history. Tampering then
#      needs a consistent edit in two places.
#
# Neither option is free. A is intrusive and defeated by one `chmod`.
# B is the only genuinely out-of-band form available here, and it costs
# a schema plus a cross-check. What this script DOES deliver today is
# the cheap partial: `--verify` refuses a directory that holds a
# regular file the manifest does not record (exit 6, below).
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
#   6  --verify found a regular file the manifest does not record
#   7  a mode this script promises could not be set (see MODE CHECKS)
#
# EXIT 6, AND WHAT IT DOES AND DOES NOT LOOK AT. `--verify` checks
# REGULAR FILES AT THE TOP LEVEL of the evidence directory only. It
# does not descend into sub-directories, and it exempts no name. That
# scope is the manifest's own scope: `md5sum <name>` records a bare
# name in one directory, so a name in a sub-directory could not be
# recorded even in principle. The rule is deliberately name-blind. A
# README exemption would be a hole any file could enter through, and
# an unrecorded note is exactly the thing a reader should be told
# about. Evidence directories do legitimately carry notes — the
# incident night's own additive note is one — so expect exit 6 on a
# directory that was never fully frozen. The remedy is to freeze the
# file, which records it. Exit 5 wins if both fire, because a broken
# invariant is the graver finding.
#
# MODE CHECKS. A `chmod` can fail. This script therefore reads the mode
# back with `stat` after setting it, and exits 7 rather than printing
# `mode 0440` over an unverified property. That failure is the exact
# shape of the incident this guard exists to prevent: a success message
# standing in for a check nobody ran.
#
# Env seams (tests): NEXUS_STATE_DIR / NEXUS_ROOT resolve the state dir,
# exactly as pane-state.sh and retire-preflight.sh resolve it.

set -uo pipefail

usage() {
    sed -n '/^# Usage:/,/^#   7 /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Does the manifest already record this bare name? Both the freeze path
# and --verify ask this, so it is defined once, before either runs.
#
# Match the name field EXACTLY — a substring test would refuse
# `nb.ipynb.bak` because `nb.ipynb` is already recorded. Three name
# forms reach us, and all three mean the same file in this directory:
#   `<hash>  nb.txt`    GNU md5sum, text mode
#   `<hash> *nb.txt`    GNU md5sum, binary mode
#   `<hash>  ./nb.txt`  a manifest built by `md5sum ./*.txt`
# The third form is what a hand-rolled regeneration writes, so a
# manifest this script did not write is still read correctly.
_manifest_records() {
    local m="$1" n="$2"
    [[ -f "$m" ]] || return 1
    awk -v want="$n" '{ line = $0
                        sub(/^[^ ]+[ ]+/, "", line)
                        sub(/^\*/, "", line)
                        sub(/^\.\//, "", line)
                        if (line == want) found = 1 }
                      END { exit found ? 0 : 1 }' "$m"
}

# Read a mode back after setting it. A chmod can fail, and this script
# must never print a property it did not check.
_mode_is() {
    [[ "$(stat -c '%a' -- "$1" 2>/dev/null)" == "$2" ]]
}

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

    # Invariant 4: the manifest records every regular file that is here.
    # `md5sum -c` walks the manifest, so it is blind in the other
    # direction: bytes present under a name nobody recorded pass every
    # check above. Top level only, and no name is exempt — see "EXIT 6"
    # in the header for why.
    unrecorded=0
    while IFS= read -r path; do
        base="${path##*/}"
        [[ "$base" == "$MANIFEST_NAME" ]] && continue
        if ! _manifest_records "$manifest" "$base"; then
            echo "evidence-freeze: UNRECORDED file: $base ($MANIFEST_NAME does not list it)" >&2
            unrecorded=$(( unrecorded + 1 ))
        fi
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
    if (( unrecorded > 0 )); then
        echo "evidence-freeze: $unrecorded unrecorded file(s) in $dir — freeze them, or they are not evidence" >&2
        # Exit 5 wins if an invariant is already broken: it is graver.
        (( rc == 0 )) && rc=6
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

# `-m 0770` applies to directories this command CREATES, and leaves an
# existing directory's mode alone. Without it the mode is whatever the
# caller's umask leaves, which is not a mode any test can assert.
#
# THIS IS A FIXED MODE, AND IT CUTS BOTH WAYS. Measured old (umask-
# derived) against new (fixed) at each umask:
#
#     umask   old   new   direction
#     0007    770   770   unchanged — the umask in use here
#     0000    777   770   tightened
#     0022    755   770   `o` tightened, `g` GAINS w
#     0027    750   770   `g` GAINS w
#     0077    700   770   `g` GAINS rwx
#
# Under a restrictive umask this WIDENS the directory, and directory
# write permission is exactly what the remove-and-recreate bypass above
# needs. On this host nothing changes, because the umask is 0007 and the
# group is the operator's own. Elsewhere it would. `0700` would never
# widen, but it would break any setup that reads the state tree by
# group, so the fixed value is the operator's call, not this script's.
mkdir -p -m 0770 "$dir" || { echo "evidence-freeze: cannot create $dir" >&2; exit 2; }
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
# Read the mode back. A swallowed chmod failure would leave a WRITABLE
# freeze under a script that prints `mode 0440`. Nothing is recorded
# yet, so the safe answer is to undo the copy and fail loudly.
chmod 0440 -- "$target" 2>/dev/null
if ! _mode_is "$target" 440; then
    {
        echo "evidence-freeze: FAILED to set mode 0440 on $target"
        echo "  mode is now: $(stat -c '%a' -- "$target" 2>/dev/null || echo unreadable)"
        echo "  A writable freeze is not a freeze. The copy was removed; nothing was recorded."
    } >&2
    rm -f -- "$target"
    exit 7
fi

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
chmod 0440 -- "$manifest" 2>/dev/null

printf 'frozen %s -> %s\n' "$src" "$target"
printf 'md5    %s\n' "$(tail -1 "$manifest" | cut -d' ' -f1)"

# The freeze IS recorded by this point, so a failure here is not a
# reason to undo it. It is a reason not to claim the manifest is
# protected. Report the mode that is actually set.
if ! _mode_is "$manifest" 440; then
    {
        echo "evidence-freeze: FAILED to set mode 0440 on $manifest"
        echo "  mode is now: $(stat -c '%a' -- "$manifest" 2>/dev/null || echo unreadable)"
        echo "  The freeze is recorded. The manifest is NOT protected:"
        echo "  a stray 'md5sum … > $MANIFEST_NAME' would rewrite it."
    } >&2
    exit 7
fi
printf 'mode   0440 (read-only); %s is append-only\n' "$MANIFEST_NAME"
exit 0
