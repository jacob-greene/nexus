#!/usr/bin/env bash
# Bounded comment resurfacing (issue #3).
#
# THE BUG, PRECISELY. An eligible-but-unprocessed GitHub comment
# re-emits forever. Two gates should have stopped it and neither does:
#
#   1. `_filter_emit_cooldown` (_emit_filters.sh) drops a comment block
#      only while its body-SHA is unchanged AND its last stamp is
#      younger than MONITOR_EMIT_COOLDOWN_SECONDS (default 300). So it
#      is not a cap — it is a *rate*: one re-emit per comment per 300 s,
#      forever. 12/hour. Over the 2026-07-31 observation window that is
#      exactly the 54 emits recorded for id=5147150803.
#
#   2. The content-hash dedup gate WOULD have collapsed those identical
#      bodies — except `_compose_emit_should_bypass_dedup` bypasses it
#      for ANY body carrying an `id=<digits>` row in the
#      `--- eligible github comments ---` section. Its docstring
#      justifies the bypass on the grounds that gh comments are
#      "deduped at the source ... so by the time one reaches here it is
#      genuinely new". That invariant holds for a FIRST emit and is
#      false for every resurface: the resurface path deliberately
#      re-injects an already-seen id. So the one gate that could have
#      collapsed the repeat is switched off by the repeat itself.
#
# The compounding failure mode the issue names — "the harder an item is
# to clear, the more times it is re-billed" — is that interaction. Each
# resurface landing on a live orchestrator is a full-price wake (1-7M
# tokens at the contexts orchestrators actually reach) carrying
# information the orchestrator has already seen.
#
# THE FIX, three parts matching the issue's three proposals:
#
#   1. CAP. Count emits per (id, body-SHA) in the existing
#      `emit-history/comment-<id>.meta`. Past
#      `MONITOR_RESURFACE_MAX_REPEATS` (default 4) the block is dropped
#      and the id recorded to `resurface-dropped.tsv` + logged to
#      `watcher-unstick.log`. Silently dropping is the risk; the log
#      line and the one-shot emit section are what make it safe.
#
#   2. BACKOFF. Between repeats the effective cooldown doubles —
#      300s, 600s, 1200s, ... capped at
#      MONITOR_RESURFACE_BACKOFF_MAX_SECONDS (default 3600). A stuck
#      item therefore costs a geometric, not linear, number of wakes
#      before the cap ends it. Same shape as
#      `_full_state_effective_floor`'s idle backoff.
#
#   3. NO-NEW-INFORMATION. `_resurface_body_is_all_repeats` lets the
#      dedup bypass distinguish a genuinely-new comment from a
#      resurface. Only a first-time id still bypasses; a body whose
#      comment rows are ALL repeats falls through to the content-hash
#      gate, which collapses it if nothing else in the emit changed.
#
# An EDITED comment resets the count — a new body-SHA is new
# information and must resurface promptly. That is the same principle
# `_filter_emit_cooldown` already applies, extended to the counter.
#
# Side-effect-free on source: function definitions only.
#
# Caller globals (read at CALL time):
#   STATE_DIR                              monitor/.state
#   MONITOR_RESURFACE_MAX_REPEATS          cap (0 = uncapped, legacy)
#   MONITOR_RESURFACE_BACKOFF_MAX_SECONDS  backoff ceiling (0 = no backoff)
#   log                                    watcher logger (optional)

_RESURFACE_DROPPED_TSV="resurface-dropped.tsv"

# Effective cooldown for the Nth repeat: base * 2^(emits-1), capped.
#   $1 base cooldown seconds   $2 emits so far (0 = never emitted)
# Returns the base unchanged when backoff is disabled or emits < 1, so
# the pre-#3 cadence is exactly recoverable via config.
_resurface_effective_cooldown() {
    local base="${1:-300}" emits="${2:-0}"
    [[ "$base"  =~ ^[0-9]+$ ]] || base=300
    [[ "$emits" =~ ^[0-9]+$ ]] || emits=0
    local max="${MONITOR_RESURFACE_BACKOFF_MAX_SECONDS:-3600}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=3600
    if (( max <= 0 || base <= 0 || emits < 1 )); then
        printf '%s' "$base"; return 0
    fi
    # Double per repeat, CLAMPING at max rather than stopping at the
    # last value below it — the documented ladder is 300, 600, 1200,
    # 2400, 3600, … and must actually reach the ceiling.
    local eff="$base" i=1
    while (( i < emits )); do
        eff=$(( eff * 2 )); i=$(( i + 1 ))
        if (( eff >= max )); then eff="$max"; break; fi
    done
    printf '%s' "$eff"
}

# True (0) when this id has already been emitted at least
# MONITOR_RESURFACE_MAX_REPEATS times for the SAME body.
#   $1 emits so far
_resurface_is_capped() {
    local emits="${1:-0}"
    local max="${MONITOR_RESURFACE_MAX_REPEATS:-4}"
    [[ "$max"   =~ ^[0-9]+$ ]] || max=4
    [[ "$emits" =~ ^[0-9]+$ ]] || emits=0
    (( max > 0 )) || return 1           # 0 = uncapped (legacy behaviour)
    (( emits >= max ))
}

# Record a dropped id, exactly once, and log it loudly. The TSV is the
# safety net that makes capping acceptable: a dropped item is visible
# to the operator, and `_resurface_dropped_emit_section` surfaces it
# once more in the next full-state emit so it is not lost entirely.
#   $1 id   $2 emits
_resurface_record_dropped() {
    local id="${1:-}" emits="${2:-0}"
    [[ -n "$id" ]] || return 0
    local state="${STATE_DIR:-}"
    [[ -n "$state" && -d "$state" ]] || return 0
    local tsv="$state/$_RESURFACE_DROPPED_TSV"

    # Once per id: a capped item is re-considered on every cycle, but it
    # must only ever be RECORDED (and logged) once.
    if [[ -f "$tsv" ]] && grep -q "^${id}"$'\t' "$tsv" 2>/dev/null; then
        return 0
    fi
    local now; now=$(date +%s)
    printf '%s\t%s\t%s\n' "$id" "$emits" "$now" >> "$tsv" 2>/dev/null || return 0

    local msg="resurface-cap: comment id=${id} dropped after ${emits} emits without being processed — it will NOT be re-emitted; see ${tsv}"
    if declare -F log >/dev/null 2>&1; then
        log "$msg"
    fi
    # Also to the unstick log, which is where the operator already
    # looks for "the watcher gave up on something" (issue #3 asks for
    # exactly this file).
    local unstick="$state/watcher-unstick.log"
    printf '[%s] %s\n' "$(date -Is)" "$msg" >> "$unstick" 2>/dev/null || true
    return 0
}

# Has this id already been dropped? Capped items must stay dropped
# across cycles without re-entering the emit stream.
_resurface_is_dropped() {
    local id="${1:-}"
    [[ -n "$id" ]] || return 1
    local state="${STATE_DIR:-}"
    [[ -n "$state" ]] || return 1
    local tsv="$state/$_RESURFACE_DROPPED_TSV"
    [[ -f "$tsv" ]] || return 1
    grep -q "^${id}"$'\t' "$tsv" 2>/dev/null
}

# Clear an id's dropped record — called when its body changes, so an
# operator EDITING a dropped comment revives it. Without this, editing
# a comment the watcher gave up on would have no effect, which would be
# a genuinely bad failure mode: the operator's only recourse would be
# to delete and repost.
_resurface_clear_dropped() {
    local id="${1:-}"
    [[ -n "$id" ]] || return 0
    local state="${STATE_DIR:-}"
    [[ -n "$state" ]] || return 0
    local tsv="$state/$_RESURFACE_DROPPED_TSV"
    [[ -f "$tsv" ]] || return 0
    grep -q "^${id}"$'\t' "$tsv" 2>/dev/null || return 0
    local tmp="$tsv.tmp.$$"
    grep -v "^${id}"$'\t' "$tsv" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$tsv" 2>/dev/null || rm -f "$tmp"
    if declare -F log >/dev/null 2>&1; then
        log "resurface-cap: comment id=${id} edited — dropped record cleared, it will resurface"
    fi
    return 0
}

# Proposal 3 — "an emit with no new information should not be sent at
# all". Returns 0 when the body's eligible-comments section contains at
# least one row AND every one of those ids is a REPEAT (already emitted
# at least once). The dedup-bypass caller uses this to stop resurfaces
# from switching off the content-hash gate, while leaving the bypass
# intact for genuinely-new comments.
#
# Returns 1 (not-all-repeats) when the section is absent, empty, or
# carries any first-time id — the conservative direction: on any doubt
# the bypass behaves exactly as it did before this change.
_resurface_body_is_all_repeats() {
    local body_file="${1:-}"
    [[ -f "$body_file" ]] || return 1
    local state="${STATE_DIR:-}"
    [[ -n "$state" ]] || return 1
    local hist="$state/emit-history"
    [[ -d "$hist" ]] || return 1

    local ids id meta emits
    ids=$(awk '
        /^--- eligible github comments ---$/ { sec = 1; next }
        /^--- /                              { sec = 0 }
        sec && match($0, /id=[0-9]+/) {
            print substr($0, RSTART + 3, RLENGTH - 3)
        }
    ' "$body_file" 2>/dev/null)
    [[ -n "$ids" ]] || return 1

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        meta="$hist/comment-$id.meta"
        emits=0
        if [[ -f "$meta" ]]; then
            emits=$(awk -F= '/^emits=/{print $2; exit}' "$meta" 2>/dev/null)
            [[ "$emits" =~ ^[0-9]+$ ]] || emits=0
        fi
        # emits<=1 means this id is being emitted for the first time
        # (the cooldown filter stamps emits=1 as it passes the block
        # through, just upstream of this check). Any first-timer makes
        # the body genuinely new.
        (( emits > 1 )) || return 1
    done <<<"$ids"
    return 0
}

# One-shot `--- resurface dropped ---` body. The issue's note: "a
# dropped item should also surface once in the next full-state emit so
# it is not lost entirely." Consumed on read — the TSV is truncated, so
# each dropped id is announced exactly once and the cap does not become
# its own standing nag.
_resurface_dropped_emit_section() {
    local state="${1:-${STATE_DIR:-}}"
    [[ -n "$state" ]] || return 0
    local tsv="$state/$_RESURFACE_DROPPED_TSV"
    [[ -s "$tsv" ]] || return 0

    local rows
    rows=$(awk -F'\t' '$1 != "" { printf "  comment id=%s — %s emits, never processed\n", $1, $2 }' "$tsv" 2>/dev/null)
    [[ -n "$rows" ]] || return 0

    # Consume: truncate before returning, so a failed paste costs the
    # announcement rather than turning it into a permanent nag. The TSV
    # is an announcement queue; watcher-unstick.log is the durable
    # record, and that one is append-only.
    : > "$tsv" 2>/dev/null || true

    printf 'The watcher stopped re-emitting these comments after\n'
    printf '%s unacknowledged repeats each. They are NOT handled:\n' "${MONITOR_RESURFACE_MAX_REPEATS:-4}"
    printf '%s\n' "$rows"
    printf 'Deal with each one directly, then react to close it out. Editing a\n'
    printf 'comment clears its dropped record and lets it resurface. The durable\n'
    printf 'record is monitor/.state/watcher-unstick.log.\n'
}
