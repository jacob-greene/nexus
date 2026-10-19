#!/usr/bin/env bash
# degraded-relocate.sh — `ng degraded enter|exit`: move the nexus's small,
# write-critical state out of a read-only project tree and back again
# (your-org/nexus-code#1724, pieces A and B).
#
# WHY. During a read-only incident (your-nexus#386: the project tree's rw bind
# detaches from the filer, once for ~18 h) every write under monitor/.state
# fails. Two of those writes stop the board: `ng send` refuses to deliver
# because it cannot stamp the delivery ledger (machine-input.tsv), and the
# request inbox cannot take a request or a reply. The orchestrator used to
# relocate both by hand with ad-hoc symlinks and an ad-hoc rollback. This does
# it as one recorded act.
#
# A SANDBOX RESTART DISCARDS WHAT WAS STAGED (skeptic on #1830). The run dir
# is under the managed $TMPDIR, which the operator constraint of 2026-10-10
# requires (small state only, no hardcoded location) — and that is a tmpfs a
# sandbox restart wipes. Every recorded RO incident so far ended in a restart,
# not an in-process heal. So: a ledger row or a request written while
# relocated reaches the tree ONLY if `exit` runs before the restart. After a
# restart the pointer and the staged copies are gone, `exit` finds nothing to
# do (rc 0), and nothing can report the loss. The ledger rows are delivery
# provenance (losing them makes the watcher misattribute those pastes); a lost
# request is lost work. `enter` says this when it runs, and the watcher's heal
# path names `exit` as owed while a pointer is in force. And `enter` leaves a
# LOSS MARKER outside the run dir ($CLAUDE_CONFIG_DIR, see
# _degraded-pointer.sh), so `exit` after a restart says LOST at rc 5 instead
# of "nothing to do" at rc 0, and the watcher says it at its next start.
#
# A SECOND ENTER NEVER ERASES AN UNACKNOWLEDGED LOSS (the #1724 residual). A
# marker found at `enter` with no pointer in force IS such a loss; `enter`
# appends it to the lost record (nexus_degraded_lost_path) before writing its
# own, and proceeds. Refusing instead would block the relocation that keeps
# ng send and the inbox working in the next outage, to protect a few lines of
# evidence that appending protects anyway. Every loss stays listed (status,
# exit rc 5, the watcher) until one `exit --ack-loss` clears them all.
#
# THE REGISTERED SURFACES, and the only ones:
#   ledger    machine-input.tsv — resolved by monitor/_ledger_path.sh
#   requests  the request inbox — resolved by monitor/_requests_dir.sh
# Each resolver consults ONE pointer reader (monitor/_degraded-pointer.sh), per
# call, so writers and readers (the watcher's delivery guard included) move
# together and a running watcher follows on its next cycle without a restart.
# Adding a surface means routing its resolver through that reader and adding
# it to `_surfaces` below; test-degraded-enter-exit.sh enumerates the real list.
#
# WHERE THINGS GO (operator constraint, 2026-10-10, #1724): small
# state only, under the degraded run dir (monitor/_degraded-rundir.sh, derived
# from the session-managed $TMPDIR), never a hardcoded fallback. Results wait;
# nothing large is staged. The pointer is a file in that run dir, OUTSIDE the
# possibly-read-only tree:
#   <rundir>/<key>.relocate    the pointer (key = the canonical state dir)
#   <rundir>/<key>.d/          the relocated surfaces + requests.base
#
# enter   probes the surfaces' home locations; relocates each one that is not
#         writable (all of them with --force); copies its current content out
#         (reads still work on a read-only mount), so the guard's history
#         continues; records the inbox's BASE checksums for the merge back;
#         writes the pointer LAST, so a failed enter leaves nothing in force.
# exit    requires --probes consecutive OK probes of the home locations,
#         --interval seconds apart (incidents flapped 4x in 4 h), then merges
#         back with NO CLOBBER:
#           ledger    append-only: rows the tree lacks are appended, ordered by
#                     their epoch (column 2); no existing row is rewritten
#           requests  three-way per file against the base taken at enter: a
#                     file changed only while relocated is copied home, one
#                     removed only while relocated (a state rename) is removed
#                     at home, one the TREE changed is kept, and one BOTH
#                     changed is a CONFLICT
#         Any conflict refuses the exit with an itemised list and changes
#         nothing (unless --force). Then the pointer is removed, the merge runs
#         once more to catch a write that raced the removal, and the relocated
#         dir is kept as <key>.exited-<ts> for audit. Anything still not home
#         is listed as STILL STAGED.
#
# Usage:
#   degraded-relocate.sh enter [--force] [--timeout S] [--max-kb K]
#   degraded-relocate.sh exit  [--force] [--timeout S] [--probes N] [--interval S] [--ack-loss]
#
#   --force      enter: relocate every surface even if it probes writable.
#                exit: merge what does not conflict, remove the pointer anyway,
#                and list the conflicts as STILL STAGED.
#   --timeout S  the per-probe and per-copy bound (default 10)
#   --max-kb K   enter: refuse to copy an inbox larger than K KiB (default
#                51200): small state only
#   --probes N   exit: consecutive OK probes required (default 3)
#   --interval S exit: seconds between probes (default 20)
#   --ack-loss   exit: acknowledge EVERY relocation a sandbox restart WIPED
#                (exit 5 below) and clear the marker and the lost record.
#                Nothing is restored.
#
# Exit codes:
#   0  done (enter: relocated, or already in force; exit: merged home, or
#      nothing was in force)
#   1  refused, nothing changed: enter found every surface writable (no
#      --force) or a stale relocation dir; exit found a probe not OK or a
#      conflict (no --force); or a copy/merge step failed
#   2  bad usage, or a surface location the resolvers refuse
#   3  could not act: no degraded run dir resolvable, or no `timeout`
#   4  exit with --force completed, but items remain STILL STAGED (listed)
#   5  exit: NO pointer, but the loss marker (or the lost record) says one or
#      more were in force — a sandbox restart wiped the run dir, and whatever
#      was written while relocated is LOST. Lists each, with since when;
#      repeats until --ack-loss. (With a pointer in force, a clean exit is
#      rc 0 and WARNS that earlier losses are still unacknowledged.)
#  64  a value-taking flag given LAST with no value (#924)

set -u
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() { sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924): a value-taking flag
# given LAST must not spin. Full rationale: monitor/ng.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

verb="${1:-}"
case "$verb" in
    enter|exit) shift ;;
    -h|--help) usage ;;
    *) echo "degraded-relocate: the first argument must be enter or exit (see --help)" >&2; exit 2 ;;
esac

force=0 timeout_s=10 max_kb=51200 probes=3 interval=20 ack_loss=0
_argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --force)    force=1; shift ;;
        --timeout)  [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "degraded-relocate: --timeout wants a positive integer" >&2; exit 2; }
                    timeout_s=$2; shift 2 ;;
        --max-kb)   [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "degraded-relocate: --max-kb wants a positive integer" >&2; exit 2; }
                    max_kb=$2; shift 2 ;;
        --probes)   [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "degraded-relocate: --probes wants a positive integer" >&2; exit 2; }
                    probes=$2; shift 2 ;;
        --interval) [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "degraded-relocate: --interval wants a non-negative integer" >&2; exit 2; }
                    interval=$2; shift 2 ;;
        --ack-loss) ack_loss=1; shift ;;
        -h|--help)  usage ;;
        *) echo "degraded-relocate: unknown argument (see --help)" >&2; exit 2 ;;
    esac
done

root="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"
STATE_DIR="${NEXUS_STATE_DIR:-$root/monitor/.state}"
export NEXUS_ROOT="$root"

# shellcheck source=monitor/_ledger_path.sh
. "$_self_dir/_ledger_path.sh"
# shellcheck source=monitor/_requests_dir.sh
. "$_self_dir/_requests_dir.sh"

command -v timeout >/dev/null 2>&1 || { echo "degraded-relocate: no \`timeout\` on PATH — refusing to touch a possibly-hung mount unbounded" >&2; exit 3; }

if ! PTR=$(nexus_degraded_pointer_path "$STATE_DIR") || [[ -z "$PTR" ]]; then
    echo "degraded-relocate: REFUSED — no degraded run dir can be resolved (no managed \$TMPDIR; see monitor/_degraded-rundir.sh). Nothing was relocated: there is no place the operator constraint allows (your-org/nexus-code#1724)." >&2
    exit 3
fi
RD=${PTR%/*}
RDIR=$(nexus_degraded_reloc_dir "$STATE_DIR")
MARK=$(nexus_degraded_marker_path "$STATE_DIR") || MARK=""
LOSTF=$(nexus_degraded_lost_path "$STATE_DIR") || LOSTF=""

# _loss_list -> one "  LOST — relocation entered <when> …" line per
# UNACKNOWLEDGED loss (nexus_degraded_lost_records, the one reader); prints
# nothing when there is none.
_loss_list() {
    local rec at when rdir
    while IFS= read -r rec; do
        [[ -n "$rec" ]] || continue
        at=$(awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i ~ /^entered=/) { print substr($i, 9); exit } }' <<<"$rec")
        rdir=$(awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i ~ /^relocated=/) { print substr($i, 11); exit } }' <<<"$rec")
        if [[ "$at" =~ ^[0-9]+$ ]]; then
            when=$(date -d "@$at" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "epoch $at")
        else
            when="at an unrecorded time"
        fi
        printf '  LOST — relocation entered %s%s\n' "$when" "${rdir:+ (staged in $rdir)}"
    done < <(nexus_degraded_lost_records "$STATE_DIR" 2>/dev/null)
}

# The registered surfaces. ONE list; the suite enumerates it.
_surfaces() { printf '%s\n' ledger requests; }

# _probe_one <name> <dir> -> the verdict word (OK / EROFS / … / ERROR). A
# missing dir is probed at its parent: a request inbox that was never created
# is writable exactly when its parent is.
_probe_one() {
    local name="$1" dir="$2" out
    [[ -d "$dir" ]] || dir=${dir%/*}
    out=$(NEXUS_ROOT="$root" NEXUS_STATE_DIR="$STATE_DIR" bash "$_self_dir/degraded-probe.sh" \
          --timeout "$timeout_s" --surface "$name=$dir" 2>&1)
    case "$?" in 2|3) printf 'ERROR'; return 0 ;; esac
    out=${out#*verdict=}; printf '%s' "${out%% *}"
}

# _sums <dir> -> "relpath<TAB>sha256" per regular file, sorted; probe litter skipped.
_sums() {
    local d="$1"
    [[ -d "$d" ]] || return 0
    ( cd "$d" && find . -type f ! -name '.degraded-probe.*' ! -name '*.degraded-merge.*' -print0 \
        | xargs -0 -r sha256sum ) | awk '{ h = substr($0, 1, 64); p = substr($0, 67); sub(/^\.\//, "", p); print p "\t" h }' | LC_ALL=C sort
}

# _pointer_get <key> -> value from the pointer file
_pointer_get() { _K="$1" awk 'index($0, ENVIRON["_K"] "=") == 1 { print substr($0, length(ENVIRON["_K"]) + 2); exit }' "$PTR" 2>/dev/null; }

# ---------------------------------------------------------------- enter ----
if [[ "$verb" == enter ]]; then
    if [[ -f "$PTR" ]]; then
        echo "already in degraded mode: the pointer $PTR is in force (nothing changed)"
        sed 's/^/  /' "$PTR"
        exit 0
    fi
    ledger_home=$(nexus_ledger_tree_path "$STATE_DIR")
    # The relocated copy keeps the home file's NAME; the name comes from the
    # resolver, never a second literal (the suite's one-composer lint).
    ledger_rel="$RDIR/${ledger_home##*/}"
    req_src=$(nexus_requests_dir_source "$STATE_DIR") || exit 2
    req_home=$(nexus_requests_dir "$STATE_DIR") || exit 2

    v_ledger=$(_probe_one ledger "${ledger_home%/*}")
    v_req=$(_probe_one requests "$req_home")
    echo "probe: ledger dir ${ledger_home%/*} → $v_ledger; request inbox $req_home → $v_req"
    do_ledger=0 do_req=0
    [[ "$v_ledger" != OK || $force == 1 ]] && do_ledger=1
    [[ "$v_req" != OK || $force == 1 ]] && do_req=1
    if (( do_req )) && [[ "$req_src" == env ]]; then
        echo "requests: NOT relocated — NEXUS_REQUESTS_DIR is set in this shell, and the environment outranks the pointer (a process without it, the watcher included, would split from one with it). Unset it and re-run to relocate the inbox."
        do_req=0
    fi
    if (( do_ledger + do_req == 0 )); then
        echo "degraded-relocate: REFUSED — nothing to relocate: every surface probes writable (use --force to enter anyway)" >&2
        exit 1
    fi
    if [[ -e "$RDIR" ]]; then
        echo "degraded-relocate: REFUSED — a relocation dir already exists with no pointer in force: $RDIR (a crashed enter?). Inspect it, then remove it; nothing was changed." >&2
        exit 1
    fi
    if (( do_req )) && [[ -d "$req_home" ]]; then
        kb=$(timeout -k 2 "$timeout_s" du -sk "$req_home" 2>/dev/null | awk '{ print $1 }')
        if ! [[ "$kb" =~ ^[0-9]+$ ]]; then
            echo "degraded-relocate: REFUSED — could not size the inbox $req_home within ${timeout_s}s; nothing was changed" >&2; exit 1
        fi
        if (( kb > max_kb )); then
            echo "degraded-relocate: REFUSED — the inbox $req_home is ${kb} KiB, over --max-kb ${max_kb}: degraded mode stages small state only; nothing was changed" >&2; exit 1
        fi
    fi
    ( umask 077; mkdir -p "$RD" && mkdir "$RDIR" ) 2>/dev/null \
        || { echo "degraded-relocate: cannot create $RDIR — nothing was relocated" >&2; exit 1; }
    _fail() { echo "degraded-relocate: $* — rolled back, nothing was relocated" >&2; rm -rf -- "$RDIR"; exit 1; }
    if (( do_ledger )); then
        if [[ -f "$ledger_home" ]]; then
            timeout -k 2 "$timeout_s" cp -p -- "$ledger_home" "$ledger_rel" \
                || _fail "could not copy the ledger $ledger_home out"
        else
            : > "$ledger_rel" || _fail "could not create $ledger_rel"
        fi
    fi
    if (( do_req )); then
        ( umask 077; mkdir "$RDIR/requests" ) || _fail "could not create $RDIR/requests"
        if [[ -d "$req_home" ]]; then
            timeout -k 2 "$timeout_s" cp -pR -- "$req_home/." "$RDIR/requests/" \
                || _fail "could not copy the inbox $req_home out"
        fi
        _sums "$RDIR/requests" > "$RDIR/requests.base" || _fail "could not record the inbox's base checksums"
    fi
    # ONE epoch and an id shared by the pointer and the marker: the id is how
    # the lost-record reader tells the live relocation's marker from a stale one.
    ent=$(date +%s); rid="$ent.$$.${RANDOM}"
    tmp="$RD/.relocate.$$"
    {
        echo "# nexus degraded-mode relocation pointer (your-org/nexus-code#1724); written by \`ng degraded enter\`, removed by \`ng degraded exit\`"
        echo "state_dir=$(nexus_degraded_canon "$STATE_DIR")"
        echo "entered=$ent"
        echo "id=$rid"
        if (( do_ledger )); then echo "ledger=$ledger_rel"; echo "ledger.home=$ledger_home"; fi
        if (( do_req )); then echo "requests=$RDIR/requests"; echo "requests.home=$req_home"; fi
    } > "$tmp" && mv -f -- "$tmp" "$PTR" || { rm -f -- "$tmp"; _fail "could not write the pointer $PTR"; }
    if [[ -n "$MARK" ]]; then
        keep_mark=0
        if [[ -f "$MARK" ]]; then
            # No pointer was in force (checked at the top), so this marker is an
            # UNACKNOWLEDGED LOSS. Append it to the lost record before the
            # marker is rewritten; if that append fails, keep the old marker
            # (it carries no matching id, so it still reads as a loss) and leave
            # this relocation without one, rather than erase the evidence.
            if awk -v a="$ent" 'NF { printf "%s%s", (n++ ? "\t" : ""), $0 } END { printf "%sarchived=%s\n", (n ? "\t" : ""), a }' "$MARK" >> "$LOSTF" 2>/dev/null; then
                echo "WARNING: an EARLIER relocation was never exited and a restart wiped it — that loss is UNACKNOWLEDGED. It is preserved in $LOSTF, not erased by this enter; it stays listed (ng degraded status, ng degraded exit) until ng degraded exit --ack-loss." >&2
                _loss_list >&2
            else
                keep_mark=1
                echo "WARNING: an EARLIER relocation's loss is UNACKNOWLEDGED and could not be appended to $LOSTF; its marker $MARK is KEPT, so THIS relocation has no loss marker and a restart that wipes it will go UNREPORTED" >&2
            fi
        fi
        if (( keep_mark )); then
            :
        elif ( umask 077; mkdir -p -- "${MARK%/*}" ) 2>/dev/null \
           && printf 'state_dir=%s\nentered=%s\nid=%s\npointer=%s\nrelocated=%s\n' \
                "$(nexus_degraded_canon "$STATE_DIR")" "$ent" "$rid" "$PTR" "$RDIR" > "$MARK" 2>/dev/null; then
            :
        else
            echo "WARNING: could not write the loss marker $MARK — a restart that wipes the run dir will go UNREPORTED" >&2
        fi
    else
        echo "WARNING: CLAUDE_CONFIG_DIR is not set, so no loss marker was left — a restart that wipes the run dir will go UNREPORTED" >&2
    fi
    echo "ENTERED degraded mode. Pointer: $PTR"
    (( do_ledger )) && echo "  ledger    $ledger_home  →  $ledger_rel"
    (( do_req ))    && echo "  requests  $req_home  →  $RDIR/requests"
    echo "Every writer and reader (ng send, paste-followup, the watcher's delivery guard, the request channel) resolves through the pointer per call; a running watcher follows on its next cycle. Leave with: ng degraded exit"
    echo "WARNING: the relocated copies live in $RD, under \$TMPDIR — a sandbox restart wipes them. Anything written while relocated reaches the tree ONLY if \`ng degraded exit\` runs BEFORE a restart; after one it is gone and nothing reports the loss."
    exit 0
fi

# ----------------------------------------------------------------- exit ----
if [[ ! -f "$PTR" ]]; then
    losses=$(_loss_list)
    if [[ -n "$losses" ]]; then
        n_loss=$(grep -c . <<<"$losses")
        if (( ack_loss )); then
            rm -f -- "$MARK" "${LOSTF:-$MARK}" && {
                echo "loss acknowledged: ${n_loss} relocation(s) recorded as LOST; marker $MARK and record ${LOSTF:-<none>} cleared. Nothing was restored."
                printf '%s\n' "$losses"; exit 0; }
            echo "degraded-relocate: could not clear $MARK / $LOSTF" >&2; exit 1
        fi
        echo "degraded-relocate: ${n_loss} relocation(s) no longer in force were never exited: the run dir that held them ($RD) was wiped, almost certainly by a sandbox restart." >&2
        printf '%s\n' "$losses" >&2
        echo "  Every delivery-ledger row and request written between each entry and the restart that followed it is GONE: it never reached $STATE_DIR. Expect pastes from those windows to read as operator input, and re-file any request made then." >&2
        echo "  Marker: $MARK; lost record: ${LOSTF:-<none>}. Acknowledge all with: ng degraded exit --ack-loss" >&2
        exit 5
    fi
    echo "not in degraded mode for $STATE_DIR (no pointer at $PTR); nothing to do"
    exit 0
fi
# Is the marker THIS relocation's? Only then does a clean exit remove it; a
# stale one (an earlier loss whose append failed at enter) stays a loss.
mark_live=0
if [[ -n "$MARK" && -f "$MARK" ]]; then
    _mid=$(awk -F= '$1 == "id" { print substr($0, 4); exit }' "$MARK" 2>/dev/null)
    # Ids must MATCH, both empty included (ncbundle27-sk F2): an id-less marker
    # beside an id'd pointer is an earlier loss, never this relocation's.
    [[ "$_mid" == "$(_pointer_get id)" ]] && mark_live=1
fi
L_REL=$(_pointer_get ledger) L_HOME=$(_pointer_get ledger.home)
Q_REL=$(_pointer_get requests) Q_HOME=$(_pointer_get requests.home)
for v in "$L_REL" "$L_HOME" "$Q_REL" "$Q_HOME"; do
    [[ -z "$v" || "$v" == /* ]] || { echo "degraded-relocate: REFUSED — the pointer $PTR holds a relative path ($v); fix it by hand" >&2; exit 2; }
done

i=1
while (( i <= probes )); do
    bad=""
    if [[ -n "$L_REL" ]]; then v=$(_probe_one ledger "${L_HOME%/*}"); [[ "$v" == OK ]] || bad+=" ledger:${L_HOME%/*}=$v"; fi
    if [[ -n "$Q_REL" ]]; then v=$(_probe_one requests "$Q_HOME");    [[ "$v" == OK ]] || bad+=" requests:$Q_HOME=$v"; fi
    if [[ -n "$bad" ]]; then
        echo "degraded-relocate: REFUSED — probe $i/$probes is not OK:$bad. The pointer stays in force; nothing was merged (sustained health is required, the incidents flapped)." >&2
        exit 1
    fi
    echo "probe $i/$probes: home locations writable"
    (( i < probes && interval > 0 )) && sleep "$interval"
    i=$(( i + 1 ))
done

# _plan_requests -> "COPY|DELETE|CONFLICT<TAB>relpath[<TAB>reason]" lines
_plan_requests() {
    [[ -n "$Q_REL" ]] || return 0
    local b="$RDIR/requests.base" r o
    r=$(mktemp "$RD/.sums-r.XXXXXX") && o=$(mktemp "$RD/.sums-o.XXXXXX") || return 1
    _sums "$Q_REL" > "$r"; _sums "$Q_HOME" > "$o"
    [[ -f "$b" ]] || : > "$b"
    awk -F'\t' -v B="$b" -v R="$r" -v O="$o" '
        FILENAME == B { base[$1] = $2; all[$1] = 1; next }
        FILENAME == R { rel[$1] = $2;  all[$1] = 1; next }
        FILENAME == O { home[$1] = $2; next }
        END {
            for (p in all) {
                bb = (p in base) ? base[p] : "-"; rr = (p in rel) ? rel[p] : "-"; oo = (p in home) ? home[p] : "-"
                if (rr == oo || rr == bb) continue
                if (oo == bb) { print ((rr == "-") ? "DELETE" : "COPY") "\t" p; continue }
                print "CONFLICT\t" p "\t" ((oo == "-") ? "removed in the tree" : "changed in the tree") \
                      " and " ((rr == "-") ? "removed" : "changed") " while relocated"
            }
        }' "$b" "$r" "$o" | LC_ALL=C sort -t$'\t' -k2,2
    rm -f -- "$r" "$o"
}

# _merge -> applies the ledger append and the non-conflicting inbox actions;
# prints one line per action; rc 1 when a step failed. CONFLICTS (global) gets
# the conflict lines. Copies run before deletes, so a state rename that fails
# half-way leaves BOTH files at home (re-shown) rather than neither (lost).
CONFLICTS=""
_merge() {
    local fail=0 new plan line kind rel
    if [[ -n "$L_REL" && -f "$L_REL" ]]; then
        # getline, not the NR==FNR idiom: an EMPTY or absent home ledger makes
        # NR==FNR true for the second file too, and every relocated row would
        # be swallowed as "already home".
        new=$(_H="$L_HOME" awk 'BEGIN { h = ENVIRON["_H"]; while ((getline l < h) > 0) seen[l] = 1 }
                                !($0 in seen) { seen[$0] = 1; print }' "$L_REL" \
              | LC_ALL=C sort -s -t$'\t' -k2,2n)
        if [[ -n "$new" ]]; then
            if printf '%s\n' "$new" >> "$L_HOME"; then
                echo "  ledger: appended $(printf '%s\n' "$new" | wc -l | tr -d ' ') row(s) to $L_HOME"
            else
                echo "  ledger: FAILED to append to $L_HOME" >&2; fail=1
            fi
        fi
    fi
    plan=$(_plan_requests) || { echo "  requests: FAILED to compute the merge plan" >&2; return 1; }
    CONFLICTS=$(printf '%s\n' "$plan" | awk -F'\t' '$1 == "CONFLICT"')
    while IFS=$'\t' read -r kind rel _; do
        [[ "$kind" == COPY ]] || continue
        ( umask 077; mkdir -p -- "$(dirname -- "$Q_HOME/$rel")" ) 2>/dev/null
        if cp -p -- "$Q_REL/$rel" "$Q_HOME/$rel.degraded-merge.$$" && mv -f -- "$Q_HOME/$rel.degraded-merge.$$" "$Q_HOME/$rel"; then
            echo "  requests: copied home $rel"
        else
            rm -f -- "$Q_HOME/$rel.degraded-merge.$$"; echo "  requests: FAILED to copy home $rel" >&2; fail=1
        fi
    done <<< "$plan"
    while IFS=$'\t' read -r kind rel _; do
        [[ "$kind" == DELETE ]] || continue
        if rm -f -- "$Q_HOME/$rel"; then echo "  requests: removed at home $rel (renamed or removed while relocated)"
        else echo "  requests: FAILED to remove $rel at home" >&2; fail=1; fi
    done <<< "$plan"
    return $fail
}

# Pass 0: a dry plan, so a conflict refuses BEFORE anything is written.
if [[ -n "$Q_REL" ]]; then
    plan0=$(_plan_requests) || { echo "degraded-relocate: could not compute the merge plan; nothing changed" >&2; exit 1; }
    c0=$(printf '%s\n' "$plan0" | awk -F'\t' '$1 == "CONFLICT"')
    if [[ -n "$c0" && $force == 0 ]]; then
        echo "degraded-relocate: REFUSED — the inbox has CONFLICTS (both the tree and the relocated copy changed). Nothing was merged; the pointer stays in force. Resolve each, or re-run with --force to merge the rest and leave these STILL STAGED:" >&2
        printf '%s\n' "$c0" | awk -F'\t' '{ printf "  CONFLICT %s — %s\n", $2, $3 }' >&2
        exit 1
    fi
fi

echo "merging home:"
_merge || { echo "degraded-relocate: a merge step FAILED (above); the pointer stays in force — re-run \`ng degraded exit\` (the merge is idempotent)" >&2; exit 1; }
rm -f -- "$PTR" || { echo "degraded-relocate: could not remove the pointer $PTR — still in degraded mode" >&2; exit 1; }
echo "pointer removed: writers and readers resolve to the tree again"
echo "catch-up merge (a write that raced the pointer removal):"
_merge; late_rc=$?
staged="$CONFLICTS"
ts=$(date +%Y%m%dT%H%M%S)
kept="${RDIR%.d}.exited-$ts"
mv -- "$RDIR" "$kept" 2>/dev/null || kept="$RDIR"
(( mark_live )) && rm -f -- "$MARK"
echo "EXITED degraded mode. The relocated copy is kept for audit at $kept"
losses=$(_loss_list)
if [[ -n "$losses" ]]; then
    echo "WARNING: earlier relocation(s) wiped by a restart are still UNACKNOWLEDGED (this exit did not touch them):" >&2
    printf '%s\n' "$losses" >&2
    echo "  Acknowledge with: ng degraded exit --ack-loss" >&2
fi
if [[ -n "$staged" || $late_rc != 0 ]]; then
    echo "STILL STAGED (not home; the copies are under $kept/requests):"
    [[ -n "$staged" ]] && printf '%s\n' "$staged" | awk -F'\t' '{ printf "  CONFLICT %s — %s\n", $2, $3 }'
    (( late_rc != 0 )) && echo "  a catch-up merge step failed (above)"
    exit 4
fi
exit 0
