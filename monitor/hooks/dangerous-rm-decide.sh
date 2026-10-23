#!/usr/bin/env bash
# dangerous-rm-decide.sh — `PermissionRequest` hook that DECIDES Claude Code's
# dangerous-`rm` permission prompt instead of leaving it to its 2-minute
# countdown (your-org/nexus-code#1632).
#
# WHY. Claude Code shows "Dangerous rm operation …" even under
# `--dangerously-skip-permissions`: the binary marks the check `bypassImmune`
# (2.1.281 bundle: `dangerousRemoval:{bypassImmune:!0,…}`). From 2.1.281 an
# unanswered prompt is DENIED after 2 minutes. Operator decision on PR #1633:
#   * a WORKER's request is FORWARDED to the orchestrator, which decides;
#   * the ORCHESTRATOR's own request is DENIED, with a message telling it to
#     delegate — a dangerous rm is not orchestration.
# Deny is the fail-safe everywhere: this hook never allows by default.
#
# WHY A PermissionRequest HOOK. Measured on the real 2.1.281 binary
# (test-realmodel-dangerous-rm-decide.sh is the gated form): a PermissionRequest
# answer decides the prompt; a PreToolUse `permissionDecision` and a
# `permissions.allow` rule do NOT (bypass-immune). A deny `message` reaches the
# model verbatim as the tool result.
#
# TIMING, MEASURED (2.1.281). The dialog and its countdown render IN PARALLEL
# with this hook, not after it: a hook that answers at 45 s or 90 s decides the
# prompt, and one still running at ~120 s LOSES — the built-in countdown denies
# first and the late answer is ignored. So the worker wait is bounded well
# inside 120 s (default 100 s, NEXUS_DRM_WAIT_S), and the settings entry gives
# the hook a `timeout` above that. The generic `permission_prompt` Notification
# also fires (~6 s in); the watcher suppresses that row while a request is open.
#
# SCOPE — THE PREDICATE. The payload carries no decision reason (keys measured:
# cwd, effort, hook_event_name, permission_mode, permission_suggestions,
# prompt_id, session_id, tool_input, tool_name, transcript_path), so the class
# is inferred. The hook acts only when ALL hold:
#   1. hook_event_name == PermissionRequest and tool_name == Bash;
#   2. permission_mode == bypassPermissions — in bypass mode a Bash prompt comes
#      only from a bypass-immune check or a PreToolUse `ask` (no nexus hook asks);
#   3. the command contains `rm` or `rmdir` as a WORD.
# Anything else: no output, exit 0 — the prompt is shown exactly as before.
# Every failure path (no jq, unreadable payload, no state dir) falls to that
# same no-answer, never to an allow.
#
# WORKER FLOW (--mode worker):
#   1. write <state>/decisions/<window>.<fp>.json, kind `dangerous_rm`, with the
#      window, full command, cwd, the classifier line captured from this pane,
#      a per-request NONCE, the requesting session and a deadline; fp is derived
#      from the nonce, so every request is its own row;
#   2. touch <state>/decisions/.urgent — a compose_emit nudge source, so the row
#      is pasted within one render tick instead of the 60 s cadence;
#   3. poll <state>/decisions/answers/<window>.<fp>.json (written by the
#      orchestrator-only `ng decision-answer`) until the deadline;
#   4. accept an answer only if its fp AND nonce match this request and it was
#      NOT written from the requesting Claude session; else keep waiting (a
#      self-answer is refused outright, with a deny);
#   5. answer allow / deny (with the orchestrator's reason), or deny on timeout;
#   6. tombstone the request (`.handled.json`, outcome recorded) and append one
#      row to <state>/dangerous-rm-decisions.tsv.
#
# SELF-APPROVAL BOUNDARY, stated honestly. The worker runs as the SAME uid as
# the orchestrator and can write the answer file itself. What stops an
# ACCIDENTAL or STALE answer: the per-request nonce and fp; `ng decision-answer`
# refusing inside a worker session; and this hook refusing an answer stamped
# with the requesting session's id. What does NOT stop a deliberate forgery: a
# process that writes the JSON by hand with another session id. The ledger
# records who answered (window, session, pane) so a forgery is at least
# attributable. The kernel sandbox, not this protocol, is the hard boundary.
#
# HEARTBEAT. With `--heartbeat` this hook also stands in for the
# `worker-heartbeat.sh permission_prompt` entry it replaced (hooks for one event
# run in parallel, so a separate entry could race the outcome): it stamps
# `permission_prompt` (→ pane-state `blocked`) for EVERY prompt it does not
# decide and while it waits, and `busy` once it has decided.
#
# Usage (settings.json):
#   dangerous-rm-decide.sh --mode worker --heartbeat      (worker-settings.json)
#   dangerous-rm-decide.sh --mode orchestrator            (orchestrator-settings.json)

set -u

mode="" heartbeat=0
while (( $# > 0 )); do
    case "$1" in
        --mode)      mode="${2:-}"; shift 2 || shift ;;
        --heartbeat) heartbeat=1; shift ;;
        *)           shift ;;
    esac
done

payload=$(head -c 262144 2>/dev/null || true)

_hb() {  # forward the payload to the heartbeat helper, if asked to
    (( heartbeat )) || return 0
    local helper="${NEXUS_ROOT:-}/monitor/worker-heartbeat.sh"
    [[ -n "${NEXUS_ROOT:-}" && -x "$helper" ]] || return 0
    printf '%s' "$payload" | "$helper" "$1" >/dev/null 2>&1 || true
}

# _drd_is_rm_word <command> — rc 0 iff rm/rmdir appears as a word. Word
# boundaries exclude [A-Za-z0-9_.-], so `--rm`, `rm.sh`, `farm`, `rmdir2` do
# not match while `/bin/rm`, `\rm`, `"rm"`, `$(rm …)`, `xargs rm` and
# `sh -c "rm …"` do.
_drd_is_rm_word() {
    local re='(^|[^A-Za-z0-9_.-])(rm|rmdir)([^A-Za-z0-9_.-]|$)'
    [[ "$1" =~ $re ]]
}

cmd="" sid="" cwd=""
in_class() {
    command -v jq >/dev/null 2>&1 || return 1
    [[ -n "$payload" ]] || return 1
    local ev tool pmode
    ev=$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null) || return 1
    tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || return 1
    pmode=$(jq -r '.permission_mode // empty' <<<"$payload" 2>/dev/null) || return 1
    [[ "$ev" == "PermissionRequest" && "$tool" == "Bash" && "$pmode" == "bypassPermissions" ]] || return 1
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) || return 1
    [[ -n "$cmd" ]] || return 1
    sid=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
    cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)
    _drd_is_rm_word "$cmd"
}

answer() {  # <allow|deny> [message]
    if [[ "$1" == allow ]]; then
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    else
        jq -cn --arg m "$2" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
    fi
}

# Out of class, or a mode this hook does not know: no answer at all.
if ! in_class || [[ "$mode" != worker && "$mode" != orchestrator ]]; then
    _hb permission_prompt
    exit 0
fi

state_dir="${NEXUS_STATE_DIR:-${NEXUS_ROOT:+$NEXUS_ROOT/monitor/.state}}"
window="${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-}}"
[[ -n "$window" ]] || window=$([[ "$mode" == orchestrator ]] && echo orchestrator || echo unknown-window)
flat=${cmd//$'\t'/ }; flat=${flat//$'\n'/ }

ledger() {  # <outcome> <fp> <answered_by> <waited_s> [reason]
    [[ -n "$state_dir" ]] && mkdir -p "$state_dir" 2>/dev/null || return 0
    local r=${5:-}; r=${r//$'\t'/ }; r=${r//$'\n'/ }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$mode" "$window" "${sid:--}" \
        "$1" "${2:--}" "${3:--}" "$4" "${flat:0:400}${r:+ | reason: ${r:0:200}}" \
        >> "$state_dir/dangerous-rm-decisions.tsv" 2>/dev/null || true
}

# ---- orchestrator: deny, and say why ---------------------------------------
if [[ "$mode" == orchestrator ]]; then
    ledger deny-orchestrator - - 0
    answer deny "Dangerous rm denied in the ORCHESTRATOR (your-org/nexus-code#1632): a dangerous rm is not orchestration. Delegate it to a worker (spawn one, or hand it to the worker that owns the path). A worker's dangerous rm is forwarded to you as a pending decision, which you answer with: ng decision-answer <window> <fp> allow|deny --nonce <nonce>."
    exit 0
fi

# ---- worker: forward to the orchestrator and wait --------------------------
# FAIL CLOSED on an empty or missing session_id (skeptic finding 2, PR #1633):
# the self-answer check compares the answerer's session with the requester's,
# and with no requester id it cannot run — so no answer could be trusted.
# Deny at once rather than forward a request that can never be allowed.
if [[ -z "$sid" ]]; then
    ledger deny-no-session - - 0
    _hb busy
    jq -cn --arg m "Dangerous rm DENIED: the permission request carried no session id, so an orchestrator answer could not be checked against self-approval (your-org/nexus-code#1632). Rewrite it with an explicit literal target, or ask the orchestrator first (SendMessage) and retry." \
        '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
    exit 0
fi

_hb permission_prompt   # blocked while it waits (the dialog is up in parallel)

wait_s="${NEXUS_DRM_WAIT_S:-100}"
[[ "$wait_s" =~ ^[0-9]+$ ]] || wait_s=100
poll_s="${NEXUS_DRM_POLL_S:-1}"
timeout_msg="No orchestrator decision within ${wait_s}s, so this dangerous rm was DENIED (your-org/nexus-code#1632). Rewrite it with an explicit literal target (an absolute path, or \${VAR:?} so an empty variable fails instead of widening the removal), or ask the orchestrator first (SendMessage) and retry."

if [[ -z "$state_dir" ]] || ! mkdir -p "$state_dir/decisions/answers" 2>/dev/null; then
    ledger deny-no-state - - 0
    answer deny "Dangerous rm DENIED: the nexus decision channel is unavailable (no state dir), so it could not be forwarded to the orchestrator (your-org/nexus-code#1632). $timeout_msg"
    exit 0
fi
dec="$state_dir/decisions"

nonce=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || nonce=$(printf '%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM)
fp=$(printf '%s|dangerous_rm|%s' "$window" "$nonce" | sha1sum | cut -c1-12)
req="$dec/$window.$fp.json"
ans="$dec/answers/$window.$fp.json"
t0=$(date +%s)
deadline=$(( t0 + wait_s ))

# The classifier line is on the PANE, not in the payload. Capture it from our
# own pane (a tmux READ), polling briefly because the dialog renders in
# parallel with this hook. Best-effort: absent TMUX_PANE, it says so.
classifier="(not captured: no TMUX_PANE)"
if [[ -n "${TMUX_PANE:-}" ]] && command -v tmux >/dev/null 2>&1; then
    classifier="(not captured: the dialog did not render within 6s)"
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        # `sed -n 1p` rather than `grep -m1`: a reader that closes the pipe
        # early can turn the writer's EPIPE into a false status (#622).
        line=$(tmux capture-pane -p -J -t "$TMUX_PANE" 2>/dev/null | grep -F -e 'Dangerous ' | sed -n 1p)
        if [[ -n "$line" ]]; then
            classifier=$(sed 's/^[[:space:]│]*//; s/[[:space:]]*$//' <<<"$line"); break
        fi
        sleep 0.5
    done
fi

tmp="$req.tmp.$$"
if ! jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg w "$window" --arg s "$sid" \
        --arg fp "$fp" --arg nonce "$nonce" --arg cmd "$cmd" --arg cwd "$cwd" \
        --arg cls "$classifier" --argjson dl "$deadline" --argjson wait "$wait_s" \
        '{ts:$ts, window:$w, session_id:$s, kind:"dangerous_rm", fingerprint:$fp, nonce:$nonce,
          command:$cmd, cwd:$cwd, classifier:$cls, deadline_epoch:$dl, wait_seconds:$wait,
          prompt_excerpt:("dangerous rm awaiting an orchestrator decision: " + $cmd),
          tool_context:"", unresolved:true}' > "$tmp" 2>/dev/null \
   || ! mv "$tmp" "$req" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    ledger deny-no-state - - 0
    answer deny "Dangerous rm DENIED: the request could not be written to the nexus decision channel (your-org/nexus-code#1632). $timeout_msg"
    exit 0
fi
printf '%s %s\n' "$(date +%s)" "$window.$fp" > "$dec/.urgent" 2>/dev/null || true

close_req() {  # <outcome> — tombstone the request with its outcome
    local out="$dec/$window.$fp.handled.json"
    jq --arg o "$1" --argjson t "$(date +%s)" '. + {outcome:$o, closed_epoch:$t, unresolved:false}' \
        "$req" > "$out.tmp.$$" 2>/dev/null && mv "$out.tmp.$$" "$out" 2>/dev/null
    rm -f "$req" "$out.tmp.$$" 2>/dev/null
    rm -f "$ans" 2>/dev/null
}

while :; do
    if [[ -f "$ans" ]]; then
        a_fp=$(jq -r '.fingerprint // empty' "$ans" 2>/dev/null)
        a_nonce=$(jq -r '.nonce // empty' "$ans" 2>/dev/null)
        a_dec=$(jq -r '.decision // empty' "$ans" 2>/dev/null)
        a_sid=$(jq -r '.answered_by_session // empty' "$ans" 2>/dev/null)
        a_by=$(jq -r '"\(.answered_by_window // "-")/\(.answered_by_session // "-")/\(.answered_by_pane // "-")"' "$ans" 2>/dev/null)
        a_reason=$(jq -r '.reason // empty' "$ans" 2>/dev/null)
        waited=$(( $(date +%s) - t0 ))
        if [[ "$a_fp" == "$fp" && "$a_nonce" == "$nonce" ]]; then
            if [[ -n "$sid" && "$a_sid" == "$sid" ]]; then
                close_req deny-self-answer
                ledger deny-self-answer "$fp" "$a_by" "$waited"
                _hb busy
                answer deny "Dangerous rm DENIED: the answer to this request came from the REQUESTING session itself, and a worker may not approve its own dangerous rm (your-org/nexus-code#1632). $timeout_msg"
                exit 0
            fi
            case "$a_dec" in
                allow)
                    close_req allow; ledger allow "$fp" "$a_by" "$waited" "$a_reason"; _hb busy
                    answer allow; exit 0 ;;
                deny)
                    close_req deny; ledger deny "$fp" "$a_by" "$waited" "$a_reason"; _hb busy
                    answer deny "The orchestrator DENIED this dangerous rm${a_reason:+: $a_reason} (your-org/nexus-code#1632). Rewrite it with an explicit literal target, or ask the orchestrator before retrying."
                    exit 0 ;;
            esac
        fi
        # A malformed or mismatched answer is not a decision: discard it and
        # keep waiting, so it cannot shadow a real answer written after it.
        rm -f "$ans" 2>/dev/null
    fi
    (( $(date +%s) >= deadline )) && break
    sleep "$poll_s"
done

close_req deny-timeout
ledger deny-timeout "$fp" - "$wait_s"
_hb busy
answer deny "$timeout_msg"
exit 0
