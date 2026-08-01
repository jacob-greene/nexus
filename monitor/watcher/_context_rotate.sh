#!/usr/bin/env bash
# Context-budget rotation directive — the watcher half of issue #1.
#
# WHY THE WATCHER AND NOT JUST THE PROMPT. The orchestrator prompt does
# carry the rotation procedure (agent-prompt.md, "Session rotation"), but
# a prompt rule is a rule the agent has to REMEMBER while its context is
# large and its attention is thinnest — precisely the failure mode the
# rule exists to prevent. The watcher already wakes the orchestrator on
# every state change; measuring the context there and putting the number
# IN the wake makes the check deterministic instead of aspirational.
#
# RENDER-ONLY. `_context_rotate_emit_section` is NOT a gate trigger: it
# never causes an emit on an otherwise-quiet workspace. It rides the
# emits the orchestrator was already receiving. This matters for the very
# cost it is trying to reduce — a rotation nag that generated its own
# wakes would spend tokens to save tokens. Same discipline as the
# `--- arm watcher supervisor ---` standing reminder.
#
# Because the section is carried INTO the emit-dedup stable hash (it is
# not on the bypass allowlist), an unchanged directive on an otherwise
# unchanged body is collapsed by the content-hash gate rather than
# re-pasted. A genuinely new figure (the number moved) hashes
# differently and surfaces.
#
# Functions:
#   _context_rotate_emit_section <state_dir> <nexus_root> [target_window]
#       → stdout: the section BODY (no header) when the orchestrator is
#         at/over threshold; empty otherwise. Never fails the caller.
#
# Side-effect-free on source: function definitions only.
#
# Caller globals (read at CALL time, not source time):
#   MONITOR_CONTEXT_ROTATION_ENABLED             master switch
#   MONITOR_CONTEXT_ROTATION_ORCHESTRATOR_TOKENS threshold
#   MONITOR_CONTEXT_ROTATION_LIMIT_TOKENS        ceiling (pct only)
#   TARGET                                       orchestrator window name
#   log                                          watcher logger (optional)

# Emit the rotate-session directive body, or nothing.
#
# Fail-safe in every direction: a missing helper, an unresolvable
# session, a transcript with no usage record, or a disabled knob all
# produce empty output and exit 0. A watcher must never wedge on a
# cost-optimisation probe.
_context_rotate_emit_section() {
    local state_dir="${1:-}" nexus_root="${2:-}" target="${3:-${TARGET:-orchestrator}}"

    local enabled="${MONITOR_CONTEXT_ROTATION_ENABLED:-true}"
    [[ "$enabled" == "true" ]] || return 0

    local threshold="${MONITOR_CONTEXT_ROTATION_ORCHESTRATOR_TOKENS:-250000}"
    [[ "$threshold" =~ ^[0-9]+$ ]] || return 0
    (( threshold > 0 )) || return 0

    local helper="$nexus_root/monitor/context-usage.sh"
    [[ -x "$helper" ]] || return 0

    local out rc=0
    out=$(NEXUS_ROOT="$nexus_root" NEXUS_STATE_DIR="$state_dir" \
          "$helper" --window "$target" --threshold "$threshold" 2>/dev/null) || rc=$?

    # rc 10 == at/over threshold. 0 == under (nothing to say). Anything
    # else is an unresolved read: stay silent rather than nag on a guess.
    (( rc == 10 )) || return 0

    local tokens pct limit
    tokens=$(sed -n 's/.*\btokens=\([0-9]*\).*/\1/p' <<<"$out")
    limit=$(sed -n 's/.*\blimit=\([0-9]*\).*/\1/p' <<<"$out")
    [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
    [[ "$limit"  =~ ^[0-9]+$ ]] && (( limit > 0 )) || limit=1000000

    # BUCKET THE RENDERED FIGURE. The exact live count drifts on every
    # single wake, and this body is hashed by `_compose_emit_stable_hash`
    # for the emit-dedup gate and the full-state canonical check. An
    # exact figure here would make EVERY emit unique while the
    # orchestrator sits over threshold — the gate could never collapse a
    # repeat, so a feature meant to cut wakes would manufacture them.
    # It would also disarm the resurface fix (issue #3), whose
    # all-repeats bodies fall through to that same hash gate expecting a
    # match.
    #
    # Rounding to the nearest 25k means the body changes only when the
    # context has materially moved — which IS new information — a
    # handful of times per session instead of every wake. `pct` is
    # derived from the BUCKET, not the raw count, so the two can never
    # disagree and drift independently. `monitor/ng context` is there
    # when the exact number is wanted.
    #
    # Same rule `_emit_dedup.sh` states from the other direction ("ANY
    # renderer change that adds a time-derived token to an emit row MUST
    # extend this list") and that _context_scan.sh applies to its rows.
    # Bucketing is preferred over extending the strip here because the
    # strip lives in the most-diverged file in the tree.
    local bucket=25000 bucketed
    bucketed=$(( ( (tokens + bucket / 2) / bucket ) * bucket ))
    (( bucketed > 0 )) || bucketed="$bucket"
    pct=$(( bucketed * 100 / limit ))

    # The LOG carries the exact figure — it is not hashed, so precision
    # there is free and useful for post-hoc audit.
    if declare -F log >/dev/null 2>&1; then
        log "context-rotation: orchestrator at ${tokens} tokens (~${bucketed} bucketed, ${pct}% of ${limit}, threshold ${threshold}) — rendering rotate directive"
    fi

    # Every figure below is the BUCKETED one — see the note above. No
    # raw token count may appear in this body.
    printf 'orchestrator context: ~%s tokens (~%s%% of %s); rotation threshold %s.\n' \
        "$bucketed" "$pct" "$limit" "$threshold"
    printf '(`monitor/ng context` for the exact figure.)\n'
    printf 'Every message re-reads the whole conversation, so this wake and\n'
    printf 'every wake after it is billed at this size. ROTATE NOW rather than\n'
    printf 'processing the rest of this emit at that price:\n'
    printf '  1. finish or safely park any in-flight write\n'
    printf '  2. monitor/ng report-init orchestrator-rotation   # then fill it in\n'
    printf '     SUBSTANTIVELY — it is the entire state transfer\n'
    printf '  3. monitor/ng log-action monitor --event rotate-session \\\n'
    printf '       --extra tokens=$(monitor/ng context --format json | jq .tokens) \\\n'
    printf '       --extra threshold=%s\n' "$threshold"
    printf '  4. monitor/watcher/spawn-fresh-orchestrator.sh --target %s \\\n' "$target"
    printf '       --rotation <report-path> --reason "context rotation"\n'
    printf 'NOT `ng respawn` — that RESUMES the session and carries this context\n'
    printf 'forward, rotating nothing. `--rotation` cold-spawns and refuses to\n'
    printf 'run without a readable report: a bare kill is not a rotation.\n'
    printf 'See agent-prompt.md "Session rotation (context budget)".\n'
}
