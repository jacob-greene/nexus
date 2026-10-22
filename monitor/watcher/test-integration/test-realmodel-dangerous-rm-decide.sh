#!/usr/bin/env bash
# test-realmodel-dangerous-rm-decide.sh — real-binary scenario for Claude
# Code's dangerous-rm permission prompt and the nexus's answer to it,
# monitor/hooks/dangerous-rm-decide.sh (your-org/nexus-code#1632, design per
# PR #1633: the orchestrator's own request is DENIED; a worker's is forwarded
# to the orchestrator, answered with `ng decision-answer`, and DENIED on
# timeout).
#
# WHY THIS EXISTS. The prompt shows even under --dangerously-skip-permissions
# (a bypass-immune check), and from 2.1.281 it auto-denies after 2 minutes. The
# gate never drove it before: the cc-auto-update evaluator found the 2.1.281
# change by a hand-driven probe. This scenario is the gated form.
#
# WHAT IT ASSERTS, on the candidate binary. The dialog renders IN PARALLEL with
# the hook (measured), so a decided arm is judged by its OUTCOME — the tool
# result the model received and the fixture — not by the absence of a dialog.
#   O1   orchestrator mode, `rm -rf .`: the deny MESSAGE reaches the model as
#        the tool result, the command did not run, the ledger says so.
#   W1   worker mode, `rm -rf .`, answered `allow` by the REAL
#        `ng decision-answer` from another session: it RAN (the transcript
#        carries rm's own "refusing to remove '.'"), ledger `allow`.
#   W2   worker mode, answered `deny --reason`: the reason reaches the model,
#        it did not run.
#   W3   worker mode, NO answer, wait 15 s: the timeout deny reaches the model
#        well inside the 2-minute countdown, and the request is closed.
#   W4   (from 2.1.281) the substitution class, answered `allow`: the fixture
#        is REMOVED — the one arm whose effect is a real deletion.
#   NC-1 behaviour stripped: no hook → the dangerous-rm prompt renders.
#   NC-2 MUST NOT FLIP: a non-rm Bash prompt (PreToolUse `ask`) with the worker
#        hook wired still renders, files NO request, and the command does not run.
#   NC-3 MUST NOT FLIP: the same for a Write prompt.
# A recorder PermissionRequest hook proves each request reached the hook
# layer, so a silent arm cannot be explained by "no request".
#
# FIXTURES ONLY. Every rm target is a directory this scenario creates inside
# the harness tmpdir, or `.`, which GNU rm refuses. Nothing else is removed.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips with exit 77 — a skip is RED for the gate, never a pass.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
if ! command -v jq >/dev/null 2>&1; then
    echo "skipped: $(basename "$0") (jq not on PATH — the production hook needs it)"
    exit 77
fi

cch_setup
PASS=0; FAIL=0

PROD_HOOK="$CCH_REPO_ROOT/monitor/hooks/dangerous-rm-decide.sh"
NG="$CCH_REPO_ROOT/monitor/ng"
[[ -x "$PROD_HOOK" ]] || { echo "FATAL: production hook missing: $PROD_HOOK" >&2; exit 1; }
STATE="$CCH_DIR/state"; mkdir -p "$STATE"
LEDGER="$STATE/dangerous-rm-decisions.tsv"
PRLOG="$CCH_DIR/permreq-seen"; mkdir -p "$PRLOG"

echo "=== real-binary dangerous-rm prompt: decided by the nexus hook, and nothing else is (#1632) ==="
echo "    claude:  $CLAUDE_BIN"
echo "    version: $("$CLAUDE_BIN" --version 2>/dev/null || echo '?')"

# The command-substitution class is NEW in 2.1.281 (measured: 2.1.280 raises
# no PermissionRequest for it and simply runs it). W4 needs that prompt to
# exist, so it runs from 2.1.281 on and is printed as not run below that.
CC_VER=$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p)
SUBST_PROMPTS=0
[[ -n "$CC_VER" && "$(printf '%s\n' 2.1.281 "$CC_VER" | sort -V | sed -n 1p)" == 2.1.281 ]] && SUBST_PROMPTS=1
echo "    substitution-class prompt expected: $SUBST_PROMPTS (candidate ${CC_VER:-?}, class added in 2.1.281)"

# PreToolUse helper: disarm the mock so the model call after the tool ends the
# turn; with $2=ask, also answer `ask` (the NC-2/NC-3 prompt source).
mk_ptu() {  # <path> <ask|none>
    {
        printf '#!/usr/bin/env bash\ncat >/dev/null\n'
        printf 'printf %%s %q > %q\n' '{"mode":"text","text":"probe done"}' "$CCH_CONTROL"
        [[ "$2" == ask ]] && printf 'printf %%s %q\n' \
            '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"nexus-1632 probe"}}'
        printf 'exit 0\n'
    } > "$1"; chmod +x "$1"
}
mk_rec() {  # <path> <arm> — one file per PermissionRequest the binary raised
    printf '#!/usr/bin/env bash\ncat > %q\nexit 0\n' "$PRLOG/$2.json" > "$1"; chmod +x "$1"
}
# settings <path> <ptu-hook> <recorder> <prod-mode: worker|orchestrator|none> <ptu-matcher>
settings() {
    local h=""
    case "$4" in
        worker)       h="$PROD_HOOK --mode worker --heartbeat" ;;
        orchestrator) h="$PROD_HOOK --mode orchestrator" ;;
    esac
    jq -n --arg p "$2" --arg r "$3" --arg h "$h" --arg m "$5" '{hooks:{
        PreToolUse: [ {matcher:$m, hooks:[{type:"command", command:$p}]} ],
        PermissionRequest: [ {hooks: ([{type:"command", command:$r}]
                                      + (if $h == "" then [] else [{type:"command", command:$h, timeout:115}] end))} ]
    }}' > "$1"
}

is_prompt() { grep -q 'Do you want to' <<<"$1" && grep -qE '❯[[:space:]]+[0-9]+\.' <<<"$1"; }
_tool_use_turns() {
    local n; n=$(grep -c 'mode=tool_use' "$CCH_LOG" 2>/dev/null || true)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"
}
# boot_arm <arm> <settings> <tool-json> <until: prompt|done> <max_s> [extra env]
#   → window index. Drives one tool call and watches until the dialog shows
#   (`prompt`, for the arms where nothing may decide it) or the turn ends
#   (`done`, for the arms the hook decides — the dialog renders meanwhile).
#   Writes <arm>.prompt (0|1: a dialog was SEEN at some point) and
#   <arm>.elapsed (seconds from the prompt send to the stop condition).
boot_arm() {
    local arm=$1 set=$2 tool=$3 until=$4 max=$5 extra=${6:-} idx i seen=0 cap t0 tu0
    idx=$(CCH_SETTINGS="$set" \
          CCH_EXTRA_ENV="NEXUS_ROOT=$(printf %q "$CCH_REPO_ROOT") NEXUS_STATE_DIR=$(printf %q "$STATE") NEXUS_WORKER_WINDOW=$arm $extra" \
          cch_boot_worker "$arm")
    # No `exit` here: boot_arm runs inside $( ), where an exit ends only the
    # subshell (your-org/nexus-code#1339). The caller checks via need_idx.
    [[ -n "$idx" ]] || return 1
    sleep 7
    tu0=$(_tool_use_turns)
    cch_control "$tool"
    cch_send "$idx" "run the probe tool call please"; t0=$(date +%s)
    for (( i = 1; i <= max; i++ )); do
        cap=$(cch_capture "$idx")
        is_prompt "$cap" && seen=1
        [[ "$until" == prompt && "$seen" == 1 ]] && break
        grep -q 'probe done' <<<"$cap" && break
        # A first prompt can be swallowed by REPL boot (measured once on
        # 2.1.281). If the mock has served no NEW tool_use by 15 s, re-send
        # once — the retry drive_until gives test-realmodel-pretooluse-hook.sh.
        if (( i == 15 )) && (( $(_tool_use_turns) == tu0 )); then
            echo "    ($arm: no tool_use served after 15 s; re-sending the prompt once)" >&2
            cch_send "$idx" "run the probe tool call please"
        fi
        sleep 1
    done
    printf '%s' "$(( $(date +%s) - t0 ))" > "$CCH_DIR/$arm.elapsed"
    sleep 2
    cch_capture "$idx" > "$CCH_DIR/$arm.capture"
    printf '%s' "$seen" > "$CCH_DIR/$arm.prompt"
    printf '%s' "$idx"
}
need_idx() { [[ -n "$1" ]] || { echo "FATAL: $2 window never appeared" >&2; exit 1; }; }
bash_tool() { jq -nc --arg c "$1" '{mode:"tool_use", tool:{name:"Bash", input:{command:$c}}}'; }
prompt_of() { cat "$CCH_DIR/$1.prompt" 2>/dev/null; }
elapsed_of() { cat "$CCH_DIR/$1.elapsed" 2>/dev/null; }
reached()   { [[ -s "$PRLOG/$1.json" ]] && echo yes || echo no; }
show()      { echo "    [$1 capture, prompt rows]"; grep -E 'Do you want|❯ [0-9]|Dangerous|Bash command|Create file' "$CCH_DIR/$1.capture" | sed 's/[[:space:]]*$//; s/^/      | /'; }
dismiss()   { [[ "$(prompt_of "$1")" == 1 ]] && cch_tmux send-keys -t "$CCH_SESSION:$2" Escape; return 0; }
# tool_result <arm> — every tool result the model received in that arm's session
tool_result() {
    local sid tr
    sid=$(jq -r '.session_id // empty' "$PRLOG/$1.json" 2>/dev/null)
    tr=$(find "$CCH_CFG/projects" -name "${sid:-none}.jsonl" 2>/dev/null | sed -n 1p)
    [[ -n "$tr" ]] || { echo "<no transcript>"; return 0; }
    jq -r 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | .content | if type=="string" then . else (map(.text? // "") | join(" ")) end' "$tr" 2>/dev/null
}
ledger_outcome() { awk -F'\t' -v w="$1" '$3==w {print $5}' "$LEDGER" 2>/dev/null | tail -1; }
open_requests() { local n=0 f; for f in "$STATE"/decisions/"$1".*.json; do [[ -e "$f" && "$f" != *.handled.json ]] && n=$((n+1)); done; echo "$n"; }
# first_open <glob…> — the first EXISTING match that is not a tombstone. A
# loop, not `ls <glob>`: under nullglob an unmatched glob leaves `ls` bare,
# and it lists the cwd instead of nothing.
first_open() { local f; for f in "$@"; do [[ -e "$f" && "$f" != *.handled.json ]] && { printf '%s' "$f"; return 0; }; done; return 0; }
first_any()  { local f; for f in "$@"; do [[ -e "$f" ]] && { printf '%s' "$f"; return 0; }; done; return 0; }
# answer_when_filed <arm> <allow|deny> [reason] — the orchestrator's move: wait
# for the worker's request, then run the REAL verb from a different session.
answer_when_filed() {
    ( local f="" i
      for (( i = 0; i < 600; i++ )); do
          f=$(first_open "$STATE"/decisions/"$1".*.json)
          [[ -n "$f" ]] && break; sleep 0.1
      done
      if [[ -z "$f" ]]; then
          echo "answerer: no request from $1" > "$CCH_DIR/$1.answer.log"
      else
          env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE" CLAUDE_CODE_SESSION_ID=harness-orchestrator \
              NEXUS_ORCHESTRATOR_WINDOW=harness-orch \
              bash "$NG" decision-answer "$1" "$(jq -r .fingerprint "$f")" "$2" --nonce "$(jq -r .nonce "$f")" \
              ${3:+--reason "$3"} > "$CCH_DIR/$1.answer.log" 2>&1
          echo "rc=$?" >> "$CCH_DIR/$1.answer.log"
      fi ) &
    ANS_PID=$!
}
# Wait for THE ANSWERER only. A bare `wait` also waits on the mock backend
# cch_setup runs in the background, and blocks forever (measured).
wait_answerer() { [[ -n "${ANS_PID:-}" ]] && wait "$ANS_PID" 2>/dev/null; ANS_PID=""; return 0; }

PTU="$CCH_DIR/ptu.sh";         mk_ptu "$PTU" none
PTU_ASK="$CCH_DIR/ptu-ask.sh"; mk_ptu "$PTU_ASK" ask

# ---- O1: orchestrator mode — deny, and the message reaches the model --------
echo; echo "--- O1: orchestrator mode, rm -rf . → deny with a delegate message ---"
mk_rec "$CCH_DIR/rec-o1.sh" o1; settings "$CCH_DIR/s-o1.json" "$PTU" "$CCH_DIR/rec-o1.sh" orchestrator Bash
idx=$(boot_arm o1 "$CCH_DIR/s-o1.json" "$(bash_tool 'rm -rf .')" done 45)
need_idx "$idx" o1
tr_o1=$(tool_result o1)
assert_eq "O1.reached: the binary raised a PermissionRequest" "$(reached o1)" "yes"
assert_eq "O1.msg: the delegate message reached the model as the tool result" \
    "$(grep -c 'not orchestration' <<<"$tr_o1" | awk '{print ($1>0)?"yes":"no"}')" "yes"
assert_eq "O1.notrun: rm never ran (no refusal from rm itself)" \
    "$(grep -c 'refusing to remove' <<<"$tr_o1" | awk '{print ($1>0)?"ran":"notrun"}')" "notrun"
assert_eq "O1.fast: decided long before the 2-minute countdown" "$(( $(elapsed_of o1) < 60 ))" "1"
assert_eq "O1.ledger" "$(ledger_outcome o1)" "deny-orchestrator"

# ---- W1: worker, answered allow → ran ----------------------------------------
echo; echo "--- W1: worker mode, rm -rf ., the orchestrator answers allow ---"
mk_rec "$CCH_DIR/rec-w1.sh" w1; settings "$CCH_DIR/s-w1.json" "$PTU" "$CCH_DIR/rec-w1.sh" worker Bash
answer_when_filed w1 allow
idx=$(boot_arm w1 "$CCH_DIR/s-w1.json" "$(bash_tool 'rm -rf .')" done 60)
need_idx "$idx" w1
wait_answerer
assert_eq "W1.verb: the real ng decision-answer succeeded" "$(grep -c '^rc=0$' "$CCH_DIR/w1.answer.log" 2>/dev/null)" "1"
assert_eq "W1.ran: the transcript carries rm's own refusal of '.' (it RAN)" \
    "$(tool_result w1 | grep -c 'refusing to remove' | awk '{print ($1>0)?"ran":"notrun"}')" "ran"
assert_eq "W1.ledger: allow, answered by the other session" \
    "$(awk -F'\t' '$3=="w1" && $5=="allow" && $7 ~ /harness-orchestrator/' "$LEDGER" | wc -l | tr -d ' ')" "1"
assert_eq "W1.closed: no request left open" "$(open_requests w1)" "0"

# ---- W2: worker, answered deny with a reason ---------------------------------
echo; echo "--- W2: worker mode, the orchestrator answers deny --reason ---"
mk_rec "$CCH_DIR/rec-w2.sh" w2; settings "$CCH_DIR/s-w2.json" "$PTU" "$CCH_DIR/rec-w2.sh" worker Bash
answer_when_filed w2 deny "NEXUS_PROBE_REASON not in this directory"
idx=$(boot_arm w2 "$CCH_DIR/s-w2.json" "$(bash_tool 'rm -rf .')" done 60)
need_idx "$idx" w2
wait_answerer
tr_w2=$(tool_result w2)
assert_eq "W2.reason: the orchestrator's reason reached the model" \
    "$(grep -c 'NEXUS_PROBE_REASON' <<<"$tr_w2" | awk '{print ($1>0)?"yes":"no"}')" "yes"
assert_eq "W2.notrun: rm never ran" "$(grep -c 'refusing to remove' <<<"$tr_w2" | awk '{print ($1>0)?"ran":"notrun"}')" "notrun"
assert_eq "W2.ledger" "$(ledger_outcome w2)" "deny"

# ---- W3: worker, no answer → timeout deny inside the countdown ---------------
echo; echo "--- W3: worker mode, NO answer, wait 15 s → timeout deny ---"
mk_rec "$CCH_DIR/rec-w3.sh" w3; settings "$CCH_DIR/s-w3.json" "$PTU" "$CCH_DIR/rec-w3.sh" worker Bash
idx=$(boot_arm w3 "$CCH_DIR/s-w3.json" "$(bash_tool 'rm -rf .')" done 70 "NEXUS_DRM_WAIT_S=15")
need_idx "$idx" w3
tr_w3=$(tool_result w3)
assert_eq "W3.msg: the timeout deny reached the model" \
    "$(grep -c 'No orchestrator decision within 15s' <<<"$tr_w3" | awk '{print ($1>0)?"yes":"no"}')" "yes"
assert_eq "W3.notbuiltin: it was OUR deny, not the built-in 2-minute one" \
    "$(grep -c 'built-in Claude Code safety check' <<<"$tr_w3" | awk '{print ($1>0)?"builtin":"ours"}')" "ours"
assert_eq "W3.bounded: decided well inside the countdown (< 60 s)" "$(( $(elapsed_of w3) < 60 ))" "1"
assert_eq "W3.ledger" "$(ledger_outcome w3)" "deny-timeout"
assert_eq "W3.closed: no request left open" "$(open_requests w3)" "0"

# ---- W4: substitution class, answered allow → the fixture is removed ---------
if (( SUBST_PROMPTS )); then
    echo; echo "--- W4: worker mode, rm -rf \"\$(…)\", answered allow → fixture removed ---"
    T4="$CCH_DIR/fixture-w4"; mkdir -p "$T4"; : > "$T4/keep"
    mk_rec "$CCH_DIR/rec-w4.sh" w4; settings "$CCH_DIR/s-w4.json" "$PTU" "$CCH_DIR/rec-w4.sh" worker Bash
    answer_when_filed w4 allow
    idx=$(boot_arm w4 "$CCH_DIR/s-w4.json" "$(bash_tool "rm -rf \"\$(printf %s $T4)\"")" done 60)
    need_idx "$idx" w4
    wait_answerer
    assert_eq "W4.reached: the substitution class raised a request" "$(reached w4)" "yes"
    assert_eq "W4.removed: the fixture was removed (allow took effect)" "$([[ -e "$T4" ]] && echo survived || echo removed)" "removed"
    assert_eq "W4.ledger" "$(ledger_outcome w4)" "allow"
else
    echo "  NOT RUN: W4 — ${CC_VER:-?} predates the substitution-class prompt"
fi

# ---- NC-1: behaviour stripped -------------------------------------------------
echo; echo "--- NC-1: rm -rf . with NO nexus hook (the prompt must render) ---"
mk_rec "$CCH_DIR/rec-nc1.sh" nc1; settings "$CCH_DIR/s-nc1.json" "$PTU" "$CCH_DIR/rec-nc1.sh" none Bash
idx=$(boot_arm nc1 "$CCH_DIR/s-nc1.json" "$(bash_tool 'rm -rf .')" prompt 45)
need_idx "$idx" nc1
assert_eq "NC1.prompt: without the hook the dangerous-rm prompt renders" "$(prompt_of nc1)" "1"
assert_eq "NC1.title: it is the dangerous-rm class" \
    "$(grep -c 'Dangerous rm operation' "$CCH_DIR/nc1.capture" | awk '{print ($1>0)?"danger":"other"}')" "danger"
show nc1; dismiss nc1 "$idx"

# ---- NC-2: MUST NOT FLIP — a non-rm Bash prompt ------------------------------
echo; echo "--- NC-2: a non-rm Bash prompt (PreToolUse ask) with the worker hook wired ---"
M2="$CCH_DIR/nc2-marker"
mk_rec "$CCH_DIR/rec-nc2.sh" nc2; settings "$CCH_DIR/s-nc2.json" "$PTU_ASK" "$CCH_DIR/rec-nc2.sh" worker Bash
idx=$(boot_arm nc2 "$CCH_DIR/s-nc2.json" "$(bash_tool "touch $M2")" prompt 45)
need_idx "$idx" nc2
sleep 3
assert_eq "NC2.reached: the request reached the hook layer" "$(reached nc2)" "yes"
assert_eq "NC2.prompt: the prompt STILL renders" "$(prompt_of nc2)" "1"
assert_eq "NC2.norequest: nothing was forwarded to the orchestrator" "$(first_any "$STATE"/decisions/nc2.*)" ""
assert_eq "NC2.notrun: the command did not run" "$([[ -e "$M2" ]] && echo ran || echo notrun)" "notrun"
show nc2; dismiss nc2 "$idx"

# ---- NC-3: MUST NOT FLIP — a non-Bash tool -----------------------------------
echo; echo "--- NC-3: a Write prompt (PreToolUse ask) with the worker hook wired ---"
M3="$CCH_DIR/nc3-written.txt"
mk_rec "$CCH_DIR/rec-nc3.sh" nc3; settings "$CCH_DIR/s-nc3.json" "$PTU_ASK" "$CCH_DIR/rec-nc3.sh" worker Write
idx=$(boot_arm nc3 "$CCH_DIR/s-nc3.json" \
      "$(jq -nc --arg f "$M3" '{mode:"tool_use", tool:{name:"Write", input:{file_path:$f, content:"rm -rf ."}}}')" prompt 45)
need_idx "$idx" nc3
sleep 3
assert_eq "NC3.reached: the request reached the hook layer" "$(reached nc3)" "yes"
assert_eq "NC3.prompt: the prompt STILL renders" "$(prompt_of nc3)" "1"
assert_eq "NC3.norequest: nothing was forwarded to the orchestrator" "$(first_any "$STATE"/decisions/nc3.*)" ""
assert_eq "NC3.notrun: the file was not written" "$([[ -e "$M3" ]] && echo ran || echo notrun)" "notrun"
show nc3; dismiss nc3 "$idx"

assert_eq "ledger.exact: every ledger row belongs to an arm the hook decided" \
    "$(awk -F'\t' '$3 !~ /^(o1|w1|w2|w3|w4)$/' "$LEDGER" 2>/dev/null | wc -l | tr -d ' ')" "0"

# ASSERTION CENSUS: an arm that stops running is a red, not a smaller green.
# O1 5, W1 4, W2 3, W3 5, NC-1 2, NC-2 4, NC-3 4, ledger 1 = 28 on every
# version, plus W4's 3 from 2.1.281.
_EXPECTED_ASSERTIONS=$(( 28 + 3 * SUBST_PROMPTS ))
assert_eq "assertion count reconciles" "$(( PASS + FAIL ))" "$_EXPECTED_ASSERTIONS"

cch_teardown
th_summary_and_exit
