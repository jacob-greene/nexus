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
    pct=$(sed -n 's/.*\bpct=\([0-9]*\).*/\1/p' <<<"$out")
    limit=$(sed -n 's/.*\blimit=\([0-9]*\).*/\1/p' <<<"$out")
    [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
    [[ "$pct"    =~ ^[0-9]+$ ]] || pct=0
    [[ "$limit"  =~ ^[0-9]+$ ]] || limit=0

    if declare -F log >/dev/null 2>&1; then
        log "context-rotation: orchestrator at ${tokens} tokens (${pct}% of ${limit}, threshold ${threshold}) — rendering rotate directive"
    fi

    printf 'orchestrator context: %s tokens (%s%% of %s); rotation threshold %s.\n' \
        "$tokens" "$pct" "$limit" "$threshold"
    printf 'Every message re-reads the whole conversation, so this wake and\n'
    printf 'every wake after it is billed at this size. ROTATE NOW rather than\n'
    printf 'processing the rest of this emit at that price:\n'
    printf '  1. finish or safely park any in-flight write\n'
    printf '  2. monitor/ng report-init orchestrator-rotation   # then fill it in\n'
    printf '     SUBSTANTIVELY — it is the entire state transfer\n'
    printf '  3. monitor/ng log-action monitor --event rotate-session \\\n'
    printf '       --extra tokens=%s --extra threshold=%s\n' "$tokens" "$threshold"
    printf '  4. monitor/watcher/spawn-fresh-orchestrator.sh --target %s \\\n' "$target"
    printf '       --rotation <report-path> --reason "context rotation at %s tokens"\n' "$tokens"
    printf 'NOT `ng respawn` — that RESUMES the session and carries this context\n'
    printf 'forward, rotating nothing. `--rotation` cold-spawns and refuses to\n'
    printf 'run without a readable report: a bare kill is not a rotation.\n'
    printf 'See agent-prompt.md "Session rotation (context budget)".\n'
}
