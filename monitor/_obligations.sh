#!/usr/bin/env bash
# _obligations.sh — the OBLIGATION EDGE: a first-class record that one
# window OWES something to another (your-org/nexus-code#845).
#
# ── The defect this exists for ────────────────────────────────────────────
#
# A worker that finishes a round PARKS awaiting its skeptic's verdict. Its
# skeptic — correctly pinned across rounds rather than retired — IDLES
# awaiting a delta it has not been told exists. Neither side can release the
# other, and nothing surfaces the pair as blocked. `#845` measured seven
# occurrences in one session; the longest ran 4h 6m.
#
# Both windows were behaving CORRECTLY. A worker may not paste into a window
# it did not create, and every observed worker respected that. The
# dependency lived in exactly one place — the orchestrator's head — and the
# tooling could not see it. Two more instances on 2026-08-14, both the
# orchestrator's own:
#
#   1. `tmuxwrap`/`sk897`, 2h 18m. The orchestrator promised sk897 "when
#      tmuxwrap fixes F8 I will send the new head". tmuxwrap pushed and
#      parked. sk897 idled under an explicit instruction to wait. Neither
#      side could DETECT the problem: tmuxwrap had no reason to think its
#      push was unrouted, and sk897 had been told to sit still.
#   2. `papercuts`/`sk911`, worse. The orchestrator RETIRED sk911 while it
#      still owed papercuts a delta re-run. papercuts then pushed its fix to
#      a reviewer that no longer existed. A `window-retain` had been logged
#      for sk911 — and `retire-preflight` still reported `safe=1`, because it
#      answers "is anyone typing", not "does this window still owe or is it
#      owed something".
#
# That second instance is the design constraint. Any fix that still requires
# the orchestrator to REMEMBER fails the same way — the orchestrator's did,
# twice in one session, after writing the lesson down in between. So the
# dependency has to be a RECORD, written by the mechanism that already knows
# it, at the moment it becomes true.
#
# ── What an obligation is ─────────────────────────────────────────────────
#
# A directed edge:  DEBTOR ──owes(kind)──▶ CREDITOR
#
#   debtor    the window that owes the work (the skeptic).
#   creditor  the window that is blocked until it arrives (the target).
#   kind      what is owed. `skeptic-verdict` today; the vocabulary is open
#             and the gate below is default-DENY over it, so an unrecognised
#             kind refuses rather than waves through.
#
# The edge is NOT a second source of truth about whether the creditor is
# blocked — `skeptic/pending/<creditor>` already says that, and duplicating
# it is how two copies of a state vocabulary drift (the `over-limit` lesson
# in _bookkeeping.sh). The edge adds exactly ONE fact the pending marker
# cannot carry: **WHO owes it.** That is the fact `retire-preflight` needed
# and did not have.
#
# It follows that liveness is DERIVED, not stored. An edge is live while the
# creditor's own blocking condition is live; it needs no explicit settlement
# to become void when the creditor is released by any of the half-dozen
# paths that already release it (a verdict, a waive, `ng skeptic resolve`, a
# retirement). Storing a second boolean and keeping it in sync would be a
# reconciliation problem, and every mechanism that clears a marker today
# would have had to learn about this file.
#
# ── Storage ───────────────────────────────────────────────────────────────
#
# One APPEND-ONLY record per edge at
#   $STATE_DIR/obligations/<debtor>__<creditor>__<kind>.rec
# holding `key<TAB>value` lines. LAST occurrence of a scalar key wins; the
# earlier ones are the audit trail. Nothing is ever rewritten, so there is no
# read-modify-write race and no temp-file dance — a reopen for round 2 is an
# append, and round 1's record survives beneath it.
#
# The id is STABLE (a pure function of the triple), which is the load-bearing
# choice: reopening the same edge for a new round must not create a SECOND
# live record, or settling round 2 would leave round 1 blocking forever and
# the retire gate becomes a brick. A brick trains its own bypass — the
# reasoning that produced `ng skeptic resolve` (#577).
#
# No `jq`. Records are read with `awk`, so the lib works in the fixture trees
# that carry `ng` and `_bookkeeping.sh` and nothing else (the #646 lesson:
# scoping a precondition wider than its consumer turns an absent optional
# file into a total outage).
#
# Error reporting convention matches _bookkeeping.sh: a failing predicate
# sets $OBL_ERR and returns non-zero, printing nothing itself.

[[ -n "${_OBLIGATIONS_SH_LOADED:-}" ]] && return 0
_OBLIGATIONS_SH_LOADED=1

OBL_ERR=""
# Set by obl_state to a caller-printable explanation of the verdict.
OBL_DETAIL=""

# ---------------------------------------------------------------------------
# Vocabulary
# ---------------------------------------------------------------------------

# Kinds this file knows how to derive a release for. An edge of any OTHER
# kind can only be released EXPLICITLY (obl_settle) or by the creditor
# window positively vanishing — it never gets the marker-derived release,
# because this file does not know what would clear it. Default-deny applied
# to the kind axis.
_OBL_KNOWN_KINDS=(skeptic-verdict)

# The states obl_state can return, and whether each RELEASES a retirement.
#
# ── THE LIFECYCLE CORRECTION (your-org/nexus-code#845, sk926) ─────────────
#
# The first version of this file settled an edge on the DEBTOR'S FIRST
# VERDICT, and additionally derived a release from the creditor's
# skeptic-pending marker going absent. Both fire at the same instant,
# because filing a verdict is what clears the marker. So the edge existed
# only over `[spawn -> first verdict]`.
#
# THE HAZARD BEGINS WHERE THAT INTERVAL ENDS. Replaying the recorded
# timeline (monitor/watcher/fixtures/incident-845-timelines.jsonl):
#
#     08:58:04  skeptic-spawn   sk911 -> papercuts     edge opens
#     09:19:36  skeptic-verdict sk911 -> papercuts     edge CLOSED here
#     09:21:21  window-retain   sk911                  <- the retirement
#     10:41:37  skeptic-spawn   sk911b -> papercuts    a THIRD reviewer
#
# `papercuts` was still being worked at 10:55. The gate returned `safe=1`
# for the very incident it was written for, and the suite that said
# otherwise planted a fixture the incident was never in.
#
# THE MODEL WAS WRONG, NOT THE CODE. A verdict discharges ONE ROUND; it does
# not end the PAIRING. A retained reviewer is the designated reviewer for
# the next round too — that is precisely why it is retained rather than
# retired — so it is owed again the moment its target pushes a delta, and
# there is no instant in between at which destroying it is safe.
#
# So the edge now tracks the PAIRING and ends only on a signal that the
# pairing is over. A round's verdict is RECORDED on the edge (audit) and
# releases nothing.
#
# RELEASING states must each assert, POSITIVELY, that this reviewer is no
# longer the one this target depends on:
#   settled               an explicit, audited settlement is on the record.
#   void-pairing-closed   the reviewer ran `skeptic-channel.sh close` on the
#                         creditor's channel AFTER this edge was last opened.
#                         That is the protocol's OWN end-of-pairing signal —
#                         "the skeptic closed the channel; the worker can
#                         stop looping and retire". The mtime comparison
#                         mirrors `await`'s stale-DONE rule (#469): a DONE
#                         from a previous round must not release a pairing
#                         re-armed since.
#   void-superseded       a LATER edge pins a DIFFERENT reviewer to the same
#                         creditor AND it is a HANDOVER of the same review,
#                         not a concurrent review of something else. The
#                         earlier reviewer is free — without this, every
#                         skeptic a target ever had accumulates as
#                         un-retirable (`sk900` in the recorded timeline).
#                         See `_obl_supersedes` for what counts as a
#                         handover (your-org/nexus-code#1849): a later edge
#                         alone is NOT one.
#   void-creditor-absent  the creditor window is positively not in tmux. A
#                         window that does not exist depends on nobody.
#
# GONE, and its absence is the fix: `void-creditor-clear`. The creditor's
# pending marker is cleared by the FIRST verdict, so keying a release on it
# guaranteed the edge was closed at the exact moment the hazard began.
#
# Everything else BLOCKS, including `unknown` and including any state a
# future revision adds. The dangerous act at this gate is destroying a
# reviewer somebody is still waiting on, so doubt must not authorise it.
_OBL_RELEASING_STATES=(settled void-pairing-closed void-superseded void-creditor-absent)

# obl_blocks_retirement <state>
#   rc 0 → this state BLOCKS retiring the debtor.
#   rc 1 → it releases.
obl_blocks_retirement() {
    local state="${1-}" s
    # An EMPTY vocabulary blocks everything, which looks exactly like a very
    # strict gate and is actually a broken one. That is not hypothetical: a
    # refactor deleted this array and every `void-*` state silently began
    # blocking; only the CONTROL cases in test-obligations.sh caught it,
    # because the regression cases all expect a refusal and a
    # refuse-everything gate satisfies them. Fail loud instead.
    if (( ${#_OBL_RELEASING_STATES[@]} == 0 )); then
        OBL_ERR="_OBL_RELEASING_STATES is empty — the release vocabulary is missing, so this gate would refuse EVERY retirement while looking merely strict"
        printf 'obligations: %s\n' "$OBL_ERR" >&2
        return 0
    fi
    for s in "${_OBL_RELEASING_STATES[@]}"; do
        [[ "$state" == "$s" ]] && return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Paths and ids
# ---------------------------------------------------------------------------

# The window-name sanitiser used repo-wide for names that must be safe as a
# single path component (spawn-worker.sh, skeptic-channel.sh `_safe`).
# obl_safe — the OBLIGATION store's own filename encoder. Lossy by
# construction, and DELIBERATELY LEFT THAT WAY: it is baked into `obl_id`, so
# every one of the records already on disk is named with it. Changing it would
# not migrate them, it would ORPHAN them — a lookup would compute a new id and
# find nothing, silently. It is safe here precisely because both ends of an
# obligation-store path are this same function.
#
# IT MUST NEVER ADDRESS ANOTHER STORE. Use `obl_chan_key` for that — see below.
obl_safe() { printf '%s' "${1//[^a-zA-Z0-9_-]/_}"; }

# ── ADDRESSING THE SKEPTIC STORE (your-org/nexus-code#941, missed site) ──────
#
# The skeptic channel encodes window names with `wk_encode` (percent-encoding,
# INJECTIVE). `obl_safe` flattens to `_` (LOSSY). They agree only on names
# already inside `[A-Za-z0-9_-]`, and they disagree on every other name:
#
#     window name          obl_safe               wk_encode
#     cc-update-2.1.183    cc-update-2_1_183      cc-update-2%2E1%2E183
#     foo.bar              foo_bar                foo%2Ebar
#     a+b                  a_b                    a%2Bb
#
# So a cross-store read built with `obl_safe` addresses a directory
# `skeptic-channel.sh` never created. The consequence is NOT a loud failure:
# `_obl_done_identity` finds no DONE, returns `none`, and `obl_state`'s
# "release 2: the reviewer CLOSED the pairing" can then never fire — the edge
# is held open forever and the retirement gate stays shut on a window whose
# review genuinely finished.
#
# This is not a new defect class. `#941` replaced exactly this
# `${w//[^a-zA-Z0-9_-]/_}` form everywhere else, and `_channel_lib.sh` states
# the rule this site was missing: "a writer and a reader disagreeing about the
# key is the very defect this closes, and a silent fallback would recreate it
# exactly when nobody is watching."
#
# LATENT, NOT LIVE, and said plainly so nobody reads more into it than was
# measured: `find <state>/skeptic -maxdepth 1 -type d -name '*%*'` returns 0
# today (positive control: the same finder sees `w39`). No window currently in
# the skeptic store has a name the two encoders disagree on. The mechanism that
# mints such names is real, though — `monitor/_tmux-window.sh`'s whole header is
# about `cc-update-2.1.183`, a DOTTED window name (`#323`).
#
# FAIL CLOSED, never a fallback, following `async-run.sh` and `_channel_lib.sh`
# verbatim: a silent degrade to `obl_safe` here would be this very bug,
# reintroduced at the one moment nobody is looking.
if ! declare -F wk_encode >/dev/null 2>&1; then
    _obl_wk_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_bookkeeping.sh"
    if [[ -r "$_obl_wk_lib" ]]; then
        # shellcheck source=monitor/_bookkeeping.sh
        source "$_obl_wk_lib"
    else
        printf '%s: cannot load the window-key encoder from %s — refusing rather than using a lossy key\n' \
            "${BASH_SOURCE[0]##*/}" "$_obl_wk_lib" >&2
        return 2 2>/dev/null || exit 2
    fi
fi

# obl_chan_key <window> — the key by which the SKEPTIC store names this
# window. Any path this file builds under `<state>/skeptic/` uses this, and
# any path under `<state>/obligations/` uses `obl_safe`. One rule, stated so
# the next reader does not have to infer which encoder a given path wants:
# ADDRESS A STORE WITH THAT STORE'S OWN ENCODER.
obl_chan_key() { wk_encode "${1-}"; }

# obl_id <debtor> <creditor> <kind>
obl_id() {
    printf '%s__%s__%s' "$(obl_safe "${1-}")" "$(obl_safe "${2-}")" "$(obl_safe "${3-}")"
}

# obl_dir <state-dir>
obl_dir() { printf '%s/obligations' "${1-}"; }

# obl_path <state-dir> <id>
obl_path() { printf '%s/obligations/%s.rec' "${1-}" "${2-}"; }

# ---------------------------------------------------------------------------
# Record I/O
# ---------------------------------------------------------------------------

# Values are single-line: newlines and tabs are folded to spaces on write so
# a `key<TAB>value` line can never be split by a multi-line detail string.
# Silent truncation is the alternative and it is worse — a detail that ends
# mid-sentence still reads as a complete one.
_obl_flatten() { printf '%s' "${1-}" | tr '\n\t' '  '; }

# _obl_now — the epoch this file stamps a VERDICT with. OBL_NOW_OVERRIDE is the
# REPLAY seam, the same role `obl_open`'s <at-epoch> plays for an open: since
# your-org/nexus-code#1849 supersession compares a verdict's time with two
# opens, so a replay that stamped verdicts with the replay's own clock would
# place every recorded verdict AFTER every recorded open and answer a
# different question. Anything not epoch-shaped is ignored.
_obl_now() {
    if [[ "${OBL_NOW_OVERRIDE:-}" =~ ^[0-9]{9,11}$ ]]; then printf '%s' "$OBL_NOW_OVERRIDE"; else date +%s; fi
}

# obl_get <state-dir> <id> <key>
# Print the LAST value for <key>, or nothing. rc 1 if the record is missing
# or unreadable — distinct from "present with an empty value".
obl_get() {
    local sd="${1-}" id="${2-}" key="${3-}" f
    f=$(obl_path "$sd" "$id")
    [[ -r "$f" ]] || return 1
    awk -F'\t' -v k="$key" '$1 == k { v = $2 } END { if (v != "") print v }' "$f" 2>/dev/null
    return 0
}

# _obl_done_identity <state-dir> <creditor> — `<mtime>:<inode>` of the
# creditor's DONE sentinel, or `0:0` when there is none.
#
# IDENTITY, NOT TIME, and the difference is load-bearing twice over.
# `opened_at` and `stat -c %Y` are both second-resolution, so a reopen and a
# close landing in the same second are indistinguishable by timestamp — and the two readings
# that ambiguity has to separate are "the pairing was closed AFTER this round
# was armed" (release) and "this is the PREVIOUS round's sentinel" (#469, do
# not release). Neither direction of a `>=`/`>` tie-break is safe: one lets a
# stale DONE retire a live reviewer, the other bricks a fast chain forever.
#
# `skeptic-channel.sh close` publishes DONE with `mktemp` + `mv -f`, so every
# close produces a NEW INODE. Comparing the identity captured at open against
# the identity now answers "has a close happened since this edge was armed?"
# exactly, at any clock resolution.
_obl_done_identity() {
    local sd="${1-}" creditor="${2-}" f
    f="$sd/skeptic/$(obl_chan_key "$creditor")/DONE"
    [[ -e "$f" ]] || { printf 'none'; return 0; }
    local sum ino
    # CONTENT, then inode. NOT mtime — that was the first version and this
    # file's own test 9a caught it: `touch` on a stale sentinel changed
    # `mtime:inode` and therefore RELEASED a pairing nobody had closed. A
    # bare touch is not exotic (a `find -exec touch`, a restore, a filesystem
    # migration), and the release it manufactures retires a live reviewer on
    # the PREVIOUS round's sentinel — the #469 failure this comparison exists
    # to prevent, reintroduced by the comparison itself.
    #
    # `cmd_close` writes a fresh `closed: <ISO>` line each time, so the
    # CONTENT changes on every genuine close; and it publishes with `mktemp` +
    # `mv -f`, so the INODE changes too. Either difference releases, so two
    # closes inside one second (identical ISO seconds) are still caught by the
    # inode, and a recycled inode is still caught by the content. Neither
    # signal alone covers both, which is why both are carried.
    sum=$(cksum < "$f" 2>/dev/null | awk '{print $1 "-" $2}') || sum=""
    [[ -n "$sum" ]] || sum="nocksum"
    ino=$(stat -c %i "$f" 2>/dev/null) || ino=0
    [[ "$ino" =~ ^[0-9]+$ ]] || ino=0
    printf '%s:%s' "$sum" "$ino"
}

_obl_open_err() { OBL_ERR="${1-}"; printf 'obligations: %s\n' "${1-}" >&2; }

# obl_open <state-dir> <debtor> <creditor> <kind> <round> <opened-by> <detail> [<at-epoch>] [<subject>]
#
# <subject> is WHAT this reviewer is pinned to — a PR, a report, a round —
# free text, compared literally (your-org/nexus-code#1849). It is written on
# EVERY open, empty when not given, so a reopen without one CLEARS a previous
# subject: a re-armed round re-tasks the reviewer, and the spawn-time stamp is
# then stale (the #963 lesson). An empty subject means "not recorded", never
# "the same as any other".
#
# Opens the edge, or REOPENS it for a new round. Reopening appends a fresh
# `opened_at` and an EMPTY `settled_at`, which is what makes the last-wins
# read report it live again — the round-1 settlement stays visible above it
# as history.
#
# Prints the id on stdout — and THEREFORE reports its errors on STDERR
# rather than through $OBL_ERR, which is the deviation from the house
# convention and the reason for it. A function whose success value rides
# stdout is always called as `$( … )`, a SUBSHELL, so a global set inside it
# is discarded before the caller can read it: the refusal arrived as an empty
# message. $OBL_ERR is still set, for a same-process caller.
obl_open() {
    local sd="${1-}" debtor="${2-}" creditor="${3-}" kind="${4-}"
    local round="${5-}" by="${6-}" detail="${7-}" at="${8-}" subject="${9-}"
    if [[ -z "$sd" || -z "$debtor" || -z "$creditor" || -z "$kind" ]]; then
        _obl_open_err "obl_open requires <state-dir> <debtor> <creditor> <kind>"
        return 1
    fi
    if [[ "$debtor" == "$creditor" ]]; then
        # A self-edge would block the window on itself forever with no
        # counterpart able to settle it. Refuse rather than write a record
        # whose only exit is the manual override.
        _obl_open_err "refusing a self-obligation: debtor and creditor are both '$debtor' — such an edge blocks the window on itself with no counterpart able to settle it"
        return 1
    fi
    [[ "$round" =~ ^[0-9]+$ ]] || round=0
    local dir id f now
    dir=$(obl_dir "$sd")
    mkdir -p "$dir" 2>/dev/null || { _obl_open_err "cannot create $dir"; return 1; }
    id=$(obl_id "$debtor" "$creditor" "$kind")
    f=$(obl_path "$sd" "$id")
    # <at-epoch> stamps `opened_at` with a supplied time instead of now. Two
    # real callers, neither of them a test convenience:
    #   * the recorded-incident REPLAY, which must reproduce the ORDER of the
    #     real events — supersession is an ordering question, and collapsing
    #     a two-hour handover into one second answers a different one;
    #   * BACKFILL of pairs that were already live when this shipped, which
    #     have to carry their real spawn time or they would all tie.
    # Anything non-numeric falls back to now rather than to 0: a zero here
    # would make the edge supersedable by everything.
    now=$(date +%s)
    [[ "$at" =~ ^[0-9]+$ ]] && now="$at"
    # One printf, one append. On a regular file an O_APPEND write of this
    # size is atomic, so a concurrent reader never observes half a block.
    {
        printf 'id\t%s\n'         "$id"
        printf 'debtor\t%s\n'     "$(_obl_flatten "$debtor")"
        printf 'creditor\t%s\n'   "$(_obl_flatten "$creditor")"
        printf 'kind\t%s\n'       "$(_obl_flatten "$kind")"
        printf 'round\t%s\n'      "$round"
        printf 'opened_at\t%s\n'  "$now"
        printf 'opened_by\t%s\n'  "$(_obl_flatten "$by")"
        printf 'detail\t%s\n'     "$(_obl_flatten "$detail")"
        printf 'done_baseline\t%s\n' "$(_obl_done_identity "$sd" "$creditor")"
        printf 'subject\t%s\n'    "$(_obl_flatten "$subject")"
        printf 'settled_at\t\n'
        printf 'settled_by\t\n'
        printf 'settled_reason\t\n'
    } >> "$f" 2>/dev/null || { _obl_open_err "cannot append to $f"; return 1; }
    printf '%s' "$id"
}

# obl_settle <state-dir> <id> <settled-by> <reason>
#
# Records an explicit settlement. The reason is MANDATORY and lands in the
# audit trail: this is the release valve on a gate that refuses irreversible
# kills, and an unexplained release is indistinguishable from the `rm` the
# whole verb family exists to replace (#577).
obl_settle() {
    local sd="${1-}" id="${2-}" by="${3-}" reason="${4-}" f now
    [[ -n "$sd" && -n "$id" ]] || { OBL_ERR="obl_settle requires <state-dir> <id>"; return 1; }
    [[ -n "$reason" ]] || { OBL_ERR="obl_settle requires a reason"; return 1; }
    f=$(obl_path "$sd" "$id")
    [[ -f "$f" ]] || { OBL_ERR="no such obligation: $id"; return 1; }
    now=$(date +%s)
    {
        printf 'settled_at\t%s\n'     "$now"
        printf 'settled_by\t%s\n'     "$(_obl_flatten "$by")"
        printf 'settled_reason\t%s\n' "$(_obl_flatten "$reason")"
    } >> "$f" 2>/dev/null || { OBL_ERR="cannot append to $f"; return 1; }
    return 0
}

# obl_preserve_pairing_closures <state-dir> <creditor> <by>
#
# DURABLY RECORD every release this creditor's DONE sentinel is granting,
# BEFORE something destroys the sentinel. Prints one settled id per line.
#
# WHY (your-org/nexus-code#1270 residual A). `void-pairing-closed` is DERIVED on
# every read, from `_obl_done_identity` — i.e. from a FILE. `dir:skeptic/{s}` is
# in BK_RETIRE_SURFACES, so `ng retire-window` `rm -rf`s the whole channel. The
# instant the sentinel goes, `_obl_done_identity` answers `none` again, `none`
# MATCHES the baseline captured at open, and "has a close happened since this
# edge was armed?" answers NO once more. The release is SILENTLY REVOKED: the
# edge reads `live`, and its DEBTOR — a DIFFERENT window, which did nothing —
# becomes un-retirable. Measured at 0b82ffb2, creditor a live tmux window:
#
#   open dbt -> cred                       ->  live                 gate rc 1
#   skeptic-channel.sh close cred          ->  void-pairing-closed  gate rc 0
#   bk_prune_window_state <st> cred        ->  DONE present -> ABSENT
#   re-read                                ->  live                 gate rc 1
#
# NOT HYPOTHETICAL, and the reason is the creditor NAME. The revoked edge only
# stays blocked while that name is live in tmux — otherwise `void-creditor-absent`
# releases it anyway — and this workspace REUSES names: 916 of 2319 distinct
# spawned window names (39.5%) were spawned more than once, skeptic windows among
# them (`methods-skeptic`, 6 spawns over 16.2 days). action-log.jsonl, events
# `spawn`+`skeptic-spawn`, 29,731 lines, 0 unparseable.
#
# THE LEDGER IS THE DURABLE ACCOUNT. `ng retire-window` says exactly that when it
# declines to prune it. This makes the claim TRUE for the one fact the ledger was
# deriving from a destroyable file, by writing down the settlement that the
# sentinel already justifies.
#
# IT RECORDS ONLY WHAT IS ALREADY TRUE. An edge is settled here ONLY when
# `obl_state` says `void-pairing-closed` RIGHT NOW — the sentinel is positively
# present AND post-dates the arm. Nothing is inferred from an ABSENCE, so this is
# not the automatic close #962 forbids: the pairing's own end-of-pairing signal is
# on disk, and this copies it somewhere that survives the teardown.
#
# EVERY FAILURE DIRECTION IS CONSERVATIVE. An unreadable ledger, a failed settle,
# a creditor that matches nothing: each leaves the edge deriving its state exactly
# as it does today, which BLOCKS. A missed preservation costs a refused
# retirement; a wrong one would destroy a live pairing, and this cannot produce
# one — it never settles an edge that is not already releasing.
obl_preserve_pairing_closures() {
    local sd="${1-}" creditor="${2-}" by="${3-}" id st c
    [[ -n "$sd" && -n "$creditor" ]] || {
        OBL_ERR="obl_preserve_pairing_closures requires <state-dir> <creditor>"
        return 1
    }
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        c=$(obl_get "$sd" "$id" creditor) || continue
        [[ "$c" == "$creditor" ]] || continue
        # `cut -f1`, matching cmd_list: obl_state prints `<state><TAB><detail>`.
        st=$(obl_state "$sd" "$id" | cut -f1) || continue
        [[ "$st" == "void-pairing-closed" ]] || continue
        obl_settle "$sd" "$id" "${by:-obl_preserve_pairing_closures}" \
            "pairing already closed: the DONE sentinel for '$creditor' had released this edge, and the teardown of '$creditor' destroys that sentinel — recorded here so the release survives it (your-org/nexus-code#1270)" \
            || continue
        printf '%s\n' "$id"
    done < <(obl_ids "$sd")
    return 0
}

# _obl_scalars <state-dir> <id>
#
# Every scalar of a record in ONE awk pass, ONE VALUE PER LINE, fixed order:
#   debtor creditor kind round opened_at settled_at settled_by settled_reason
#   detail done_baseline subject verdict_at
#
# APPEND new fields at the END: callers read a PREFIX of these lines, so a
# field inserted mid-list would shift every later read (#1849 added the last
# two).
#
# LINES, not a TSV row, and that is not a style choice. `IFS=$'\t' read -r a b
# c …` COLLAPSES runs of tabs, because TAB is IFS *whitespace* — so a record
# with an empty `settled_at` shifts every later field left by one and
# `done_baseline` lands in `settled_at`. Measured while writing this: every
# unsettled edge read as `state=settled … settled at 0:0`, i.e. the gate
# released everything, and 32 of 67 assertions went red. Successive `read`s
# from one fd have no delimiter semantics to get wrong, and an empty line
# reads as an empty value.
#
# THE COST THIS EXISTS TO REMOVE (your-org/nexus-code#926 D1). `obl_get` is
# one `awk` process per KEY, and `obl_state` needs six of them; the
# supersession scan then re-read three more per candidate edge over the whole
# ledger. Measured on a ledger rebuilt from this workspace's own history (629
# edges): `obl_blocking_for_debtor` took **16-18s**, and **7.1s even for a
# window that owes nothing** — the outer scan alone. That cost is paid
# SYNCHRONOUSLY before every `tmux kill-window` on this board, and it grows
# forever because the ledger is deliberately never pruned.
#
# Twelve seconds is already past the point where an operator under load starts
# wanting to skip the gate, and a safety gate people route around is worse
# than one that is merely slow. So the growth is what is fixed, not the
# constant: one process per RECORD instead of one per KEY, and — see
# `_obl_ids_matching` — only the records that can possibly match are read at
# all.
#
# Values cannot contain a TAB (`_obl_flatten` folds them on write), so the
# field split is unambiguous.
_obl_scalars() {
    local sd="${1-}" id="${2-}" f
    f=$(obl_path "$sd" "$id")
    [[ -r "$f" ]] || return 1
    awk -F'\t' '
        $1 == "debtor"         { debtor = $2 }
        $1 == "creditor"       { creditor = $2 }
        $1 == "kind"           { kind = $2 }
        $1 == "round"          { round = $2 }
        $1 == "opened_at"      { opened_at = $2 }
        $1 == "settled_at"     { settled_at = $2 }
        $1 == "settled_by"     { settled_by = $2 }
        $1 == "settled_reason" { settled_reason = $2 }
        $1 == "detail"         { detail = $2 }
        $1 == "done_baseline"  { done_baseline = $2 }
        $1 == "subject"        { subject = $2 }
        $1 == "verdict_at"     { verdict_at = $2 }
        END {
            printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n",
                debtor, creditor, kind, round, opened_at,
                settled_at, settled_by, settled_reason, detail, done_baseline,
                subject, verdict_at
        }' "$f" 2>/dev/null
}

# _obl_ids_matching <state-dir> <find-name-glob>
#
# Ids whose FILENAME matches the glob. The id is
# `safe(debtor)__safe(creditor)__safe(kind)` and `obl_safe` emits only
# `[A-Za-z0-9_-]`, so a glob over the name carries no metacharacter hazard and
# — critically — cannot produce a FALSE NEGATIVE: a record with debtor W is
# always named `safe(W)__…`, so `safe(W)__*` selects it.
#
# It CAN produce false positives (a debtor literally named `a__papercuts`
# matches `*__papercuts__*`), so every caller re-confirms against the record's
# own field. Prefilter for speed, field for truth — an enumeration that feeds
# a KILL GATE may narrow only where narrowing is provably lossless.
_obl_ids_matching() {
    local sd="${1-}" glob="${2-}" dir p b
    dir=$(obl_dir "$sd")
    [[ -d "$dir" ]] || return 0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        b=$(basename "$p")
        printf '%s\n' "${b%.rec}"
    done < <(find "$dir" -maxdepth 1 -type f -name "$glob" 2>/dev/null | sort)
}

# _obl_first_opened <state-dir> <id>
#
# The EARLIEST `opened_at` in the record: when this debtor first took this
# review on. The record is append-only and a re-armed round appends a new block,
# so last-wins `opened_at` is the CURRENT round's start, not this. Prints
# nothing when the record has no numeric `opened_at`.
_obl_first_opened() {
    local f; f=$(obl_path "${1-}" "${2-}")
    [[ -r "$f" ]] || return 0
    awk -F'\t' '$1 == "opened_at" && $2 ~ /^[0-9]+$/ { if (m == "" || $2 + 0 < m + 0) m = $2 }
                 END { if (m != "") print m }' "$f" 2>/dev/null
}

# obl_reviews <state-dir> <from> <to> <kind> [since]
#
# rc 0 → <from> REVIEWS <to>, directly or through a chain: a path of one or
# more <kind> edges from -> x -> … -> to exists in the ledger, in ANY state
# (a settled link is still a link). rc 1 → no such path within the bound.
# Used to tell a CHAIN LINK from a REPLACEMENT (ncbundle32-sk R1): sk3, spawned
# on sk2 with chain root w, reviews sk2 and, through sk2->sk1, sk1 as well, so
# its chain-root edge on w must not supersede sk1's or sk2's.
#
# [since] — an epoch (your-org/nexus-code#1865). With it, a hop counts only if
# its edge's CURRENT `opened_at` (last wins) is at or after <since>. obl_state
# passes the FIRST `opened_at` of the edge it is judging (`_obl_first_opened`),
# so a chain link must have been opened after that reviewer first took the
# review on. Window names are reused: the real ledger holds `cifixsk->cifix`
# from one task and `cifixsk->cifix2` from a later one, and without the bound an
# edge left by the earlier task read as a chain link and kept a reviewer live
# through a genuine handover. WHY THE LOWER BOUND AND NOT AN UPPER ONE ("opened
# at or before the later root edge"): a re-armed round APPENDS a fresh
# `opened_at`, so a genuine link re-opened after its chain-root edge would fail
# an upper bound and the reviewer would be voided, the dangerous direction. The
# lower bound uses the judged edge's FIRST open for the same reason: a re-armed
# root keeps the links it already had. A hop with no numeric `opened_at` counts.
# RESIDUAL, live direction: a stale edge whose CURRENT open is later than the
# judged edge's first open (the name was reused AFTER the review began) still
# counts, and keeps the reviewer live. And when the SAME (debtor, creditor) pair
# is reused, the judged record's first `opened_at` is the EARLIER task's, which
# loosens the bound back toward the old any-time reading (also live). KEPT on
# purpose (#1868 item 3): bounding by the first open since the last settlement
# would close it, but for a pair settled and RE-ARMED inside one review that
# bound drops a genuine link and voids a reviewer still owed. The two shapes
# are NOT recorded identically (#1870 item 2): every open block carries its own
# `round`, `subject` and `detail`. But `round` is no discriminator in
# production. Measured on the live ledger (447 records, 2026-10-17): 21 of 22
# re-opens after a settlement carry a round no higher than the open before
# them, including a genuine in-review re-arm (`ng wrap-up (require re-arm)`
# re-opens at round 1). A "round did not increase => reused" test would void
# that reviewer. Pinned both ways, with the settlement tightening built as
# mutant M7, in test-skeptic-second-reviewer.sh D10/D11.
#
# ERROR DIRECTION, stated. Bounded at 8 hops (recursion is capped well below
# that), so a longer chain reads "not a reviewer" and its root edge falls back
# to rule 2, i.e. today's behaviour. Each hop confirms debtor AND creditor from
# the RECORD, never from the filename, because obl_safe is lossy (`a.b` and
# `a_b` share a filename) and a `__` inside a window name would let a prefix
# glob match a different window. A loop in the ledger terminates on the
# visited set.
obl_reviews() {
    local sd="${1-}" from="${2-}" to="${3-}" kind="${4-}" since="${5-}"
    [[ -n "$from" && -n "$to" && -n "$kind" ]] || return 1
    [[ "$since" =~ ^[0-9]+$ ]] || since=""
    local frontier="$from" next hop=0 x id d c o visited=$'\n'"$from"$'\n'
    while [[ -n "$frontier" ]] && (( hop < 8 )); do
        hop=$(( hop + 1 )); next=""
        while IFS= read -r x; do
            [[ -n "$x" ]] || continue
            while IFS= read -r id; do
                [[ -n "$id" ]] || continue
                d=$(obl_get "$sd" "$id" debtor); [[ "$d" == "$x" ]] || continue
                [[ "$(obl_get "$sd" "$id" kind)" == "$kind" ]] || continue
                c=$(obl_get "$sd" "$id" creditor); [[ -n "$c" ]] || continue
                if [[ -n "$since" ]]; then
                    o=$(obl_get "$sd" "$id" opened_at)
                    [[ "$o" =~ ^[0-9]+$ ]] && (( o < since )) && continue
                fi
                [[ "$c" == "$to" ]] && return 0
                [[ "$visited" == *$'\n'"$c"$'\n'* ]] && continue
                visited+="$c"$'\n'; next+="$c"$'\n'
            done < <(_obl_ids_matching "$sd" "$(obl_safe "$x")__*__$(obl_safe "$kind").rec")
        done <<< "$frontier"
        frontier="$next"
    done
    return 1
}

# obl_note <state-dir> <id> <text> [verdict]
#
# With a 4th argument `verdict`, also appends `verdict_at<TAB><epoch>`: a
# scalar, last wins, read by `_obl_supersedes` as "this reviewer delivered a
# round at <epoch>". A SEPARATE KEY rather than a pattern over the `event`
# text, because a field that SELECTS is not a label (#1050): prose in `event`
# can be reworded by anyone, and a supersession rule matching it would change
# behaviour on a wording edit.
#
# Append a ROUND EVENT to the edge's audit trail. Deliberately writes a
# non-scalar key (`event`), so it accumulates and can never be mistaken for
# a settlement by the last-wins scalar read — the whole point being that a
# delivered round is recorded WITHOUT releasing the pairing.
obl_note() {
    local sd="${1-}" id="${2-}" text="${3-}" mark="${4-}" f now
    [[ -n "$sd" && -n "$id" ]] || { OBL_ERR="obl_note requires <state-dir> <id>"; return 1; }
    f=$(obl_path "$sd" "$id")
    [[ -f "$f" ]] || { OBL_ERR="no such obligation: $id"; return 1; }
    now=$(_obl_now)
    if [[ "$mark" == verdict ]]; then
        printf 'event\t%s %s\nverdict_at\t%s\n' "$now" "$(_obl_flatten "$text")" "$now" >> "$f" 2>/dev/null \
            || { OBL_ERR="cannot append to $f"; return 1; }
    else
        printf 'event\t%s %s\n' "$now" "$(_obl_flatten "$text")" >> "$f" 2>/dev/null \
            || { OBL_ERR="cannot append to $f"; return 1; }
    fi
    return 0
}

# obl_ids <state-dir> — every recorded edge id, one per line.
#
# NO GLOB PATHSPEC ANYWHERE NEAR THIS. `find` with an explicit `-name`, read
# through a `while read`, because the repo's own dominant defect class is a
# confident zero from an enumeration (#618/#707/#770/#814) and this
# enumeration feeds a GATE: an empty answer here reads as "nobody is owed
# anything" and authorises a kill.
obl_ids() {
    local sd="${1-}" dir
    dir=$(obl_dir "$sd")
    [[ -d "$dir" ]] || return 0
    local p b
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        b=$(basename "$p")
        printf '%s\n' "${b%.rec}"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.rec' 2>/dev/null | sort)
}

# ---------------------------------------------------------------------------
# The verdict
# ---------------------------------------------------------------------------

# _obl_tmux_windows — every live tmux window NAME, one per line. Empty
# output means "could not look", NEVER "there are none": this process is
# itself running inside a tmux window whenever tmux is the environment, so a
# genuinely empty list is not a state that occurs.
#
# OBL_TMUX_WINDOWS is the test seam — a newline-separated list injected
# directly, so the suite exercises the absence LOGIC rather than a stub of
# tmux. Set it to a single space to simulate "tmux answered nothing".
_obl_tmux_windows() {
    if [[ -n "${OBL_TMUX_WINDOWS+x}" ]]; then
        printf '%s' "$OBL_TMUX_WINDOWS"
        return 0
    fi
    command -v tmux >/dev/null 2>&1 || return 0
    tmux list-windows -a -F '#{window_name}' 2>/dev/null
}

# _obl_verdict <state> <detail> — emit the one-line answer. Folds the detail
# to a single line for the same reason _obl_flatten exists: a caller splits
# this on TAB, and a newline in the middle would silently truncate the
# explanation an operator is meant to act on.
_obl_verdict() {
    OBL_DETAIL="${2-}"
    printf '%s\t%s' "${1-}" "$(printf '%s' "${2-}" | tr '\n\t' '  ')"
}

# _obl_supersedes <opened_at> <subject> <verdict_at> <later-opened_at> <later-subject>
#
# rc 0 → the LATER edge is a HANDOVER of this one's review, so this one is
# void-superseded; rc 1 → it is a CONCURRENT review and frees nothing. Sets
# $_OBL_SUPERSEDE_WHY either way (a global: called in-process, never in `$( )`).
# The caller has already established: same creditor, different debtor, and the
# later edge STRICTLY later.
#
# THE DEFECT (your-org/nexus-code#1849). This used to be "strictly later ⇒
# superseded", keyed on the creditor and the second, with nothing about WHAT
# was under review. Measured 2026-10-16: `gate-sk` was reviewing proj-x #275 when
# `alerts-sk` was pinned to the same target for #276. gate-sk's edge read
# `void-superseded` mid-review, so it was retirable, the live set was
# {alerts-sk}, and a resolve written for gate-sk's verdict settled alerts-sk's
# edge (#1848). A worker with N concurrent reviews had N−1 voided.
#
# THE RULE — what separates the two shapes, and only what is on the record:
#
#   1. BOTH edges carry a subject (`--skeptic-subject` at spawn): the SAME
#      subject is a handover, a DIFFERENT one is concurrent. Literal compare.
#   2. Otherwise the subject cannot be compared, so the rule asks the one fact
#      that tells a handover from a concurrent review without it: had THIS
#      reviewer DELIVERED a verdict since its edge was last opened, BEFORE the
#      later reviewer was pinned? `sk900` filed at 07:16 and `sk911` was
#      spawned at 08:58 — a reviewer that delivered and was then REPLACED.
#      `gate-sk` had delivered nothing when `alerts-sk` arrived — a reviewer
#      still mid-review. Both inequalities are STRICT, so a same-second
#      verdict counts for nothing: the doubtful arm keeps the edge LIVE.
#
# WHY NOT THE ARM LEDGER'S SUBJECT. The obvious default — stamp each edge with
# the target's latest armed sha at spawn — was measured against the incident's
# own ledger and does not separate it: `proj-y-pipe` armed twice, both
# times for one report path, and every one of its reviewers from accshard-sk
# to bound-sk2 was spawned against the SAME last arm. Every edge would carry
# one subject and every later one would supersede, exactly as before.
#
# ERROR DIRECTION, stated — rule 2 errs BOTH ways (ncbundle31-sk F2).
#   LIVE: a reviewer abandoned mid-review and replaced, with no subjects
#   recorded, stays a debtor until `ng skeptic close`, a resolve naming it, or
#   `ng obligation settle`. A refused retirement, recoverable by an audited verb.
#   VOID: a RETAINED reviewer that delivered round N (say REVISE) and is waiting
#   for the delta is, by `ng`'s own account, the designated reviewer for round
#   N+1. If a DIFFERENT review of the same target is then pinned with no
#   subjects, this edge reads `void-superseded` and the retained reviewer is
#   retirable while it is still owed. Nothing on a subject-less record
#   separates that from the sk900 -> sk911 handover, so the rule cannot; the
#   remedy is a subject on both edges (`spawn-worker.sh --skeptic-subject`),
#   under which rule 1 decides and this case stays LIVE. Since
#   your-org/nexus-code#1858 `spawn-worker.sh --skeptic-role` REFUSES (exit 29)
#   to open a second live edge on a target without that flag. That narrows the
#   shape to: an edge opened outside the launcher; a subject on the NEW edge
#   only (allowed with a warning: that is the handover case); and, before
#   ncbundle32-sk R1, the launcher's OWN depth-2 chain-root edge (sk2->w,
#   which never carries a subject). The chain-root case is now closed twice:
#   obl_state skips a later edge whose debtor holds a review edge on this
#   debtor (a chain link, not a replacement), and spawn-worker.sh refuses a
#   depth-2 spawn while ANOTHER reviewer (not the chain's own target) holds a
#   live edge on the root, where no subject can help. The VOID error is
#   strictly narrower than the pre-#1849 rule, which voided it AND every
#   concurrent review with no verdict at all.
_OBL_SUPERSEDE_WHY=""
_obl_supersedes() {
    local at="${1-}" sub="${2-}" vat="${3-}" lat="${4-}" lsub="${5-}"
    if [[ -n "$sub" && -n "$lsub" ]]; then
        if [[ "$sub" == "$lsub" ]]; then
            _OBL_SUPERSEDE_WHY="both edges name the same subject '$sub'"; return 0
        fi
        _OBL_SUPERSEDE_WHY="subject '$lsub' is not this edge's '$sub'"; return 1
    fi
    if [[ "$vat" =~ ^[0-9]+$ && "$at" =~ ^[0-9]+$ && "$lat" =~ ^[0-9]+$ ]] \
        && (( vat > at && vat < lat )); then
        _OBL_SUPERSEDE_WHY="this reviewer filed a verdict at $vat, after its edge opened at $at and before the later one at $lat"; return 0
    fi
    _OBL_SUPERSEDE_WHY="no subject on both edges, and no verdict from this reviewer between its open ($at) and the later pin ($lat): still mid-review"
    return 1
}

# obl_state <state-dir> <id>
#
# Print ONE line: `<state><TAB><detail>`, where <state> is exactly one of
#   settled | live | void-pairing-closed | void-superseded |
#   void-creditor-absent | unknown
# Always rc 0 — the VERDICT is the answer, and collapsing "could not tell"
# into a non-zero rc is how a blind probe ends up indistinguishable from a
# clean one.
#
# THE DETAIL RIDES STDOUT, not a global. $OBL_DETAIL is set too, for a
# caller in the same process, but every real caller reads this through
# `$(...)` — a SUBSHELL — so a global would arrive empty at exactly the
# sites that print the refusal an operator has to act on. Callers do:
#     IFS=$'\t' read -r st detail <<<"$(obl_state "$sd" "$id")"
obl_state() {
    local sd="${1-}" id="${2-}" _prefix=""
    OBL_DETAIL=""
    local f; f=$(obl_path "$sd" "$id")
    if [[ ! -r "$f" ]]; then
        _obl_verdict unknown "obligation record $id is missing or unreadable at $f"; return 0
    fi

    # ONE read for the whole record (your-org/nexus-code#926 D1).
    local debtor creditor kind round settled_at settled_by settled_reason
    local detail_txt opened_at baseline subject verdict_at
    {   read -r debtor;     read -r creditor;       read -r kind
        read -r round;      read -r opened_at;      read -r settled_at
        read -r settled_by; read -r settled_reason;  read -r detail_txt
        read -r baseline;   read -r subject;        read -r verdict_at
    } < <(_obl_scalars "$sd" "$id")

    if [[ -n "$settled_at" ]]; then
        _obl_verdict settled "settled at $settled_at by ${settled_by:-unknown}: ${settled_reason:-<no reason recorded>}"; return 0
    fi

    if [[ -z "$creditor" ]]; then
        _obl_verdict unknown "record $id names no creditor — cannot establish whether anyone is waiting"; return 0
    fi
    [[ "$opened_at" =~ ^[0-9]+$ ]] || opened_at=0

    # --- release 1: the pairing was HANDED OVER to a later reviewer -------
    # `sk900` held `papercuts` before `sk911` did. Once a later edge pins a
    # DIFFERENT reviewer to the same creditor FOR THE SAME REVIEW, the earlier
    # reviewer has stopped being the one that target depends on, and holding
    # it open would accumulate every skeptic a target ever had as
    # un-retirable. A later edge is NECESSARY and NOT SUFFICIENT
    # (your-org/nexus-code#1849): `_obl_supersedes` decides.
    #
    # Scoped by FILENAME to the edges that name this creditor, not by a scan
    # of the whole ledger (#926 D1): the supersession loop used to be the
    # dominant cost and it re-read every record three times.
    local other od odebtor ocreditor osubject _o1 _o2 _o3 _o4 _o5 _o6 _o7 _o8 _o9 _concurrent=""
    local _first_open
    while IFS= read -r other; do
        [[ -n "$other" && "$other" != "$id" ]] || continue
        {   read -r odebtor; read -r ocreditor; read -r _o1
            read -r _o2;     read -r od;        read -r _o3
            read -r _o4;     read -r _o5;       read -r _o6
            read -r _o7;     read -r osubject
        } < <(_obl_scalars "$sd" "$other")
        [[ "$ocreditor" == "$creditor" ]] || continue
        [[ -n "$odebtor" && "$odebtor" != "$debtor" ]] || continue
        [[ "$od" =~ ^[0-9]+$ ]] || continue
        # STRICTLY later. Two edges stamped in the same second do not
        # supersede each other in either direction — the conservative arm,
        # since "which of these two is the current reviewer" is exactly what
        # a tie fails to answer, and the wrong answer retires a live one.
        (( od > opened_at )) || continue
        # A CHAIN LINK IS NOT A HANDOVER (ncbundle32-sk R1). A depth-2 skeptic
        # spawned with `--skeptic-target sk1 --skeptic-orig w` opens TWO edges:
        # sk2->sk1 and a subject-less chain-root edge sk2->w. Without this arm
        # rule 2 read the chain-root edge as sk1's replacement and voided
        # sk1->w the moment sk1 had delivered — the F2 shape, made by the
        # launcher itself. The test is STRUCTURAL: the later debtor reviews
        # THIS debtor through a chain of review edges (obl_reviews: transitive,
        # so depth 3's root edge spares sk1 as well as sk2; no label field).
        # Any state counts: a settled sk2->sk1 is still a chain.
        # Only links opened since this debtor first took the review on count
        # (#1865): a reused window name leaves stale edges in the ledger.
        [[ -n "${_first_open+x}" ]] || _first_open=$(_obl_first_opened "$sd" "$id")
        if obl_reviews "$sd" "$odebtor" "$debtor" "$kind" "${_first_open:-$opened_at}"; then
            _concurrent="${_concurrent:+$_concurrent, }$odebtor (a chain link: it reviews '$debtor' through '$kind' edges, so it does not replace it)"
            continue
        fi
        if _obl_supersedes "$opened_at" "$subject" "$verdict_at" "$od" "$osubject"; then
            _obl_verdict void-superseded "a later reviewer ('$odebtor') is pinned to '$creditor' (edge $other opened at $od, after this one at $opened_at) and it is a handover: $_OBL_SUPERSEDE_WHY"
            return 0
        fi
        _concurrent="${_concurrent:+$_concurrent, }$odebtor ($_OBL_SUPERSEDE_WHY)"
    done < <(_obl_ids_matching "$sd" "*__$(obl_safe "$creditor")__*.rec")
    [[ -n "$_concurrent" ]] && _prefix="later reviewer(s) of '$creditor' review CONCURRENTLY and do not free this one: $_concurrent; "

    # --- release 2: the reviewer CLOSED the pairing -----------------------
    # `skeptic-channel.sh close <target>` drops a DONE sentinel, and the
    # protocol already defines it as "the skeptic closed the channel; stop
    # looping and proceed to retire". That is the end-of-pairing signal, and
    # it is the ONLY per-round event that means it — a VERDICT does not,
    # which is the whole #845 correction.
    #
    # Compared against the identity captured when this edge was last opened,
    # not against a clock. A channel is REUSED across rounds, so the previous
    # round's DONE is still sitting there when a new round is armed; `await`
    # refuses such a sentinel by an mtime comparison (#469) and this refuses
    # it by inode, which is exact where second-resolution mtimes tie. See
    # `_obl_done_identity`.
    local now_identity
    # An OLD record predating this field has an empty baseline. Treat that as
    # `none` — "there was no sentinel when this edge was armed" — so any DONE
    # present now releases it. The alternative (treat unknown as "matches")
    # would brick every pre-existing edge permanently.
    [[ -n "$baseline" ]] || baseline="none"
    now_identity=$(_obl_done_identity "$sd" "$creditor")
    if [[ "$now_identity" != "none" ]]; then
        if [[ "$now_identity" != "$baseline" ]]; then
            _obl_verdict void-pairing-closed "the reviewer closed '$creditor''s channel after this edge was armed (DONE identity $now_identity, was $baseline at open) — the pairing is over"
            return 0
        fi
        _prefix="a DONE sentinel exists for '$creditor' but it PREDATES this edge — it is the previous round's, unchanged since this pairing was re-armed (#469 stale-DONE rule); "
    fi

    # An unrecognised kind gets no kind-specific handling. The vocabulary is
    # deliberately open, but this file cannot say what would end such a
    # pairing, so only the kind-agnostic releases above and below apply.
    local known=0 k
    for k in "${_OBL_KNOWN_KINDS[@]}"; do
        [[ "$kind" == "$k" ]] && known=1
    done
    (( known == 0 )) && _prefix="${_prefix}kind '$kind' has no kind-specific release in _obligations.sh; "

    # --- release 3: the creditor window is positively gone ----------------
    local wins; wins=$(_obl_tmux_windows)
    if [[ -z "${wins//[[:space:]]/}" ]]; then
        # Could not look. NOT a release — an unreadable window list is the
        # `unknown (no tmux on PATH — could NOT look)` case ng's own
        # `_live_skeptic_window` names, and it must not manufacture an
        # absence. The pairing is unclosed and unsuperseded, so it stands.
        _obl_verdict live "${_prefix}the pairing is neither closed nor superseded; tmux could not be listed, so the creditor's window existence was not checked"; return 0
    fi
    local w found=0
    while IFS= read -r w; do
        [[ "$w" == "$creditor" ]] && { found=1; break; }
    done <<<"$wins"
    if (( found == 0 )); then
        _obl_verdict void-creditor-absent "${_prefix}creditor window '$creditor' is not present in tmux — a window that does not exist depends on nobody, so this edge is void"
        return 0
    fi

    _obl_verdict live "${_prefix}reviewer still PAIRED to '$creditor' (round ${round:-?}): the creditor is live in tmux, the pairing has not been closed with \`ng skeptic close $creditor\`, no later reviewer supersedes it, and no settlement is on the record${detail_txt:+ — $detail_txt}"; return 0
}

# obl_blocking_for_debtor <state-dir> <window>
#
# Print `<id>\t<state>\t<creditor>\t<detail>` for every edge on which
# <window> is the DEBTOR and whose state BLOCKS retirement. Empty output
# means no edge blocks — which is a real answer only because obl_ids
# enumerates with `find` and obl_state defaults to `unknown` (which blocks).
obl_blocking_for_debtor() {
    local sd="${1-}" window="${2-}" id st detail debtor creditor _r
    [[ -n "$window" ]] || return 0
    # Prefiltered by FILENAME (#926 D1). Before this, a window that owes
    # NOTHING still cost a full ledger scan — 7.1s on a 629-edge ledger,
    # paid synchronously before every kill on this board. The prefilter is a
    # sound superset (see `_obl_ids_matching`) and the debtor field is
    # re-confirmed below, so nothing is narrowed away.
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        { read -r debtor; read -r creditor; } < <(_obl_scalars "$sd" "$id")
        [[ "$debtor" == "$window" ]] || continue
        IFS=$'\t' read -r st detail <<<"$(obl_state "$sd" "$id")"
        obl_blocks_retirement "$st" || continue
        printf '%s\t%s\t%s\t%s\n' "$id" "$st" "$creditor" "$detail"
    done < <(_obl_ids_matching "$sd" "$(obl_safe "$window")__*.rec")
    return 0
}

# obl_live_pairs <state-dir>
#
# Print `<id>\t<debtor>\t<creditor>\t<kind>\t<round>\t<opened_at>` for every
# edge whose state is `live`. The operator-facing "who is waiting on whom"
# view, and the join a future watcher emit would read.
obl_live_pairs() {
    local sd="${1-}" id st
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        st=$(obl_state "$sd" "$id" | cut -f1)
        [[ "$st" == "live" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" \
            "$(obl_get "$sd" "$id" debtor)" \
            "$(obl_get "$sd" "$id" creditor)" \
            "$(obl_get "$sd" "$id" kind)" \
            "$(obl_get "$sd" "$id" round)" \
            "$(obl_get "$sd" "$id" opened_at)"
    done < <(obl_ids "$sd")
}
