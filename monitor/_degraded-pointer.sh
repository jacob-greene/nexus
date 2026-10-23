#!/usr/bin/env bash
# _degraded-pointer.sh — the ONE reader of the degraded-mode RELOCATION POINTER
# (your-org/nexus-code#1724, piece A). Sourced; defines functions only.
#
# WHAT IT IS. `ng degraded enter` (monitor/degraded-relocate.sh) moves small,
# write-critical state surfaces out of a read-only project tree: today the
# delivery ledger (machine-input.tsv) and the request inbox. It records where
# each one went in a pointer FILE in the degraded run dir
# (monitor/_degraded-rundir.sh: derived from the session-managed $TMPDIR, never
# a hardcoded location, operator 2026-10-10). The pointer lives OUTSIDE the
# tree on purpose: a symlink swap inside a read-only tree is impossible.
#
# ONE READER. Every surface resolver (monitor/_ledger_path.sh for the ledger,
# monitor/_requests_dir.sh for the inbox) asks this file, and nothing else
# opens the pointer. A writer relocated while a reader still composes the old
# path silently disables the lost-instruction guard, so the pointer has one
# interpretation, here.
#
# PER CALL, NEVER CACHED. The pointer is read on EVERY resolution. The watcher
# sources its helpers once at startup, so a resolved path held in a variable
# would never see `enter` or `exit`; a file read per call does. What IS cached
# is only the run dir's PATH (a pure function of NEXUS_DEGRADED_RUNDIR and
# TMPDIR, re-derived when either changes), because deriving it with no TMPDIR
# (the watcher's normal state) sources monitor/shellenv/tmpdir.sh in a
# subshell. Call `nexus_degraded_pointer_warm` once at top level in a hot
# process so `$(…)` callers inherit the cached path.
#
# KEYED BY THE STATE DIR. The run dir is shared by every nexus (and every test
# fixture) of one uid, so the pointer is named after the CANONICAL state dir
# (`cd && pwd -P`: send.sh, paste-followup.sh and the watcher spell it
# differently). A fixture's state dir therefore never matches the live
# pointer (the your-org/nexus-code#833 class), and the pointer also records
# `state_dir=` and is ignored, loudly, if that line disagrees.
#
# FAST PATH. With no `*.relocate` file in the run dir (normal operation) the
# answer is "not relocated" without a fork; canonicalising costs one subshell
# and happens only while some pointer exists.
#
#   nexus_degraded_relocated <state_dir> <surface>
#       -> prints the relocated path, rc 0
#          rc 1, prints nothing: not relocated (or no run dir resolvable)
#          rc 2, stderr: a pointer exists for this state dir but is unusable
#            for <surface> (a relative path, or one outside the run dir);
#            callers must not silently fall back to the tree
#   nexus_degraded_pointer_path <state_dir>  -> where the pointer is / would be; rc 1 no run dir
#   nexus_degraded_reloc_dir <state_dir>     -> the relocation dir beside it;     rc 1 no run dir
#   nexus_degraded_canon <dir>               -> canonical spelling (physical when it exists)
#   nexus_degraded_pointer_warm              -> caches the run dir path in this shell
#   nexus_degraded_marker_path <state_dir>   -> the restart-surviving loss marker; rc 1 none defined
#   nexus_degraded_lost_path <state_dir>     -> the append-only record of earlier losses; rc 1 none defined
#   nexus_degraded_lost_records <state_dir>  -> one line per UNACKNOWLEDGED loss; rc 1 none

[[ -n "${_NEXUS_DEGRADED_POINTER_LIB:-}" ]] && return 0
_NEXUS_DEGRADED_POINTER_LIB=1

if ! declare -F nexus_degraded_rundir >/dev/null 2>&1; then
    # shellcheck source=monitor/_degraded-rundir.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_degraded-rundir.sh"
fi

_NDP_RD="" _NDP_RD_FOR=$'\001unset'
# _ndp_rundir — sets _NDP_RD (no fork once cached); rc 1 when unresolvable.
_ndp_rundir() {
    local k="${NEXUS_DEGRADED_RUNDIR:-}|${TMPDIR:-}"
    if [[ "$k" != "$_NDP_RD_FOR" ]]; then
        _NDP_RD=$(nexus_degraded_rundir 2>/dev/null) || _NDP_RD=""
        _NDP_RD_FOR="$k"
    fi
    [[ -n "$_NDP_RD" ]]
}
nexus_degraded_pointer_warm() { _ndp_rundir; return 0; }

nexus_degraded_canon() {
    local d="${1:?dir required}" p
    if [[ -d "$d" ]] && p=$(cd -- "$d" 2>/dev/null && pwd -P) && [[ -n "$p" ]]; then
        printf '%s' "$p"; return 0
    fi
    while [[ "$d" == *//* ]]; do d=${d//\/\//\/}; done
    while [[ "$d" == */ && "$d" != / ]]; do d=${d%/}; done
    printf '%s' "$d"
}

# The key spelling mirrors _fs_status_path's (watcher/_fs_guard.sh), done in
# pure bash so the hot path forks nothing.
_ndp_key() { local s="$1"; printf '%s' "${s//[^A-Za-z0-9._-]/_}"; }

nexus_degraded_pointer_path() {
    _ndp_rundir || return 1
    printf '%s/%s.relocate' "$_NDP_RD" "$(_ndp_key "$(nexus_degraded_canon "${1:?state_dir required}")")"
}
nexus_degraded_reloc_dir() {
    _ndp_rundir || return 1
    printf '%s/%s.d' "$_NDP_RD" "$(_ndp_key "$(nexus_degraded_canon "${1:?state_dir required}")")"
}

# nexus_degraded_marker_path <state_dir> -> where `enter` leaves its LOSS
# MARKER; rc 1 (prints nothing) when no persistent place is defined.
#
# WHY A SECOND FILE (skeptic F1 on #1830). The pointer and the staged copies
# live in the run dir, a tmpfs a sandbox restart wipes — and every recorded RO
# incident ended in a restart. Without a trace that survives, `exit` after a
# restart finds no pointer and says "nothing to do" at rc 0 while ledger rows
# and requests are gone. The marker is that trace: a few lines, never data.
#
# WHERE: $CLAUDE_CONFIG_DIR, the Claude Code harness's own state dir, which the
# harness sets for every session and which monitor/README.md already relies on
# as persistent and sandbox-writable. Used ONLY when set: there is no $HOME or
# other fallback, so nothing is hardcoded (operator constraint, 2026-10-10).
# Unset -> rc 1, and `enter` says loss detection is unavailable.
nexus_degraded_marker_path() {
    [[ -n "${CLAUDE_CONFIG_DIR:-}" && "${CLAUDE_CONFIG_DIR}" == /* ]] || return 1
    printf '%s/nexus-degraded/%s.entered' "$CLAUDE_CONFIG_DIR" \
        "$(_ndp_key "$(nexus_degraded_canon "${1:?state_dir required}")")"
}

# nexus_degraded_lost_path <state_dir> -> beside the marker, the APPEND-ONLY
# record of earlier losses; rc 1 when no marker place is defined.
#
# WHY A THIRD FILE (the residual on #1724 after #1830). One marker holds ONE
# relocation. `enter` while an earlier loss was still unacknowledged used to
# overwrite it, and that relocation's clean exit then removed the only trace,
# so the first loss was never reported. `enter` now appends the stale marker
# here (one tab-separated line) before writing its own, and is NOT refused for
# it: during an outage that enter is what keeps ng send and the inbox working.
# Only `exit --ack-loss` clears this file.
nexus_degraded_lost_path() {
    local m
    m=$(nexus_degraded_marker_path "${1:?state_dir required}") || return 1
    printf '%s.lost' "${m%.entered}"
}

# nexus_degraded_lost_records <state_dir> -> one line per UNACKNOWLEDGED loss,
# tab-separated key=value fields (entered= among them): every line of the lost
# record, then the marker itself when it is NOT the live relocation's. The
# marker is live when a pointer is in force and the two carry the same `id=`
# (a marker with no id= predates the field and is taken as live, as before).
# rc 1, prints nothing: no loss, or no marker place defined. The ONE reader:
# exit, ack, status and the watcher all ask this.
nexus_degraded_lost_records() {
    local sd="${1:?state_dir required}" m l p mid pid any=1
    m=$(nexus_degraded_marker_path "$sd") || return 1
    l="${m%.entered}.lost"
    if [[ -s "$l" ]]; then
        awk 'NF' "$l"; any=0
    fi
    if [[ -f "$m" ]]; then
        p=$(nexus_degraded_pointer_path "$sd" 2>/dev/null) || p=""
        if [[ -n "$p" && -f "$p" ]]; then
            mid=$(awk -F= '$1 == "id" { print substr($0, 4); exit }' "$m" 2>/dev/null)
            pid=$(awk -F= '$1 == "id" { print substr($0, 4); exit }' "$p" 2>/dev/null)
            # Live only when the ids MATCH, both empty included: an id-less
            # marker (written before ids existed) beside an id'd pointer is an
            # EARLIER relocation's, kept when its append failed (ncbundle27-sk F2).
            [[ "$mid" == "$pid" ]] && return $any
        fi
        # An empty marker (a torn write) is still a loss: it says so, undated.
        awk 'NF { printf "%s%s", (n++ ? "\t" : ""), $0 } END { print (n ? "" : "entered=?") }' "$m"; any=0
    fi
    return $any
}

nexus_degraded_relocated() {
    local sd="${1:?state_dir required}" surface="${2:?surface required}"
    _ndp_rundir || return 1
    local f any=""
    for f in "$_NDP_RD"/*.relocate; do [[ -f "$f" ]] && { any=1; break; }; done
    [[ -n "$any" ]] || return 1
    local canon ptr
    canon=$(nexus_degraded_canon "$sd")
    ptr="$_NDP_RD/$(_ndp_key "$canon").relocate"
    [[ -f "$ptr" ]] || return 1
    local k v rec_sd="" val="" seen=""
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        case "$k" in
            state_dir) rec_sd="$v" ;;
            "$surface") val="$v"; seen=1 ;;
        esac
    done < "$ptr"
    if [[ "$rec_sd" != "$canon" ]]; then
        printf 'degraded pointer %s records state_dir=%s, not %s — ignored for %s (your-org/nexus-code#1724)\n' \
            "$ptr" "${rec_sd:-<none>}" "$canon" "$surface" >&2
        return 2
    fi
    [[ -n "$seen" ]] || return 1
    if [[ "$val" != /* || "$val" != "$_NDP_RD"/* || "$val" == *"/../"* ]]; then
        printf 'degraded pointer %s: %s=%s is not a path inside the run dir %s — REFUSED, not falling back to the tree (your-org/nexus-code#1724)\n' \
            "$ptr" "$surface" "$val" "$_NDP_RD" >&2
        return 2
    fi
    printf '%s' "$val"
}
