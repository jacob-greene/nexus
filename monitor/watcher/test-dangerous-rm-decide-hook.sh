#!/usr/bin/env bash
# test-dangerous-rm-decide-hook.sh — the dangerous-rm decision protocol
# (your-org/nexus-code#1632, design per PR #1633):
#   monitor/hooks/dangerous-rm-decide.sh   the PermissionRequest hook
#   ng decision-answer                     the orchestrator's answer verb
#   render_pending_decisions               the watcher row it surfaces as
#
# The live-board risk is an answer broader than the class, or an answer the
# orchestrator never gave. So most rows are MUST-NOT-FLIP: another tool,
# another permission mode, another hook event, a Bash command with no rm word,
# a malformed payload, no jq — each must produce EMPTY stdout AND file no
# request. The worker rows drive the REAL verb for allow/deny, and show that a
# timeout, a self-answer and a mismatched nonce all DENY. Deny is the only
# default this hook has.
#
# The real-binary behaviour (the prompt is decided, the deny message reaches
# the model, a late answer loses to the 2-minute countdown) is gated separately
# by monitor/watcher/test-integration/test-realmodel-dangerous-rm-decide.sh.
#
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
HOOK="$REPO_ROOT/monitor/hooks/dangerous-rm-decide.sh"
NG="$REPO_ROOT/monitor/ng"

# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

# Population (your-org/nexus-code#803): the files whose bytes this verdict reads.
. "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() {
    printf '%s\n' "$HOOK" "$NG" \
        "$REPO_ROOT/monitor/worker-heartbeat.sh" \
        "$REPO_ROOT/monitor/worker-settings.json" \
        "$REPO_ROOT/monitor/orchestrator-settings.json" \
        "$_test_dir/_idle_probe.sh" \
        "$_test_dir/_compose_nudge.sh"
}
gp_handle "$@"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s (%s)\n' "$1" "${2:-}" >&2; _th_fail; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has() { if [[ -n "$3" ]] && grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing [$3] in [${2:0:300}]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 77; }
[[ -x "$HOOK" ]] || { echo "missing or not executable: $HOOK" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-drd-XXXXXX") || exit 1
trap 'rm -rf "${WORK:?}"' EXIT
ST="$WORK/state"

# payload <event> <tool> <mode> <command> [session]
payload() {
    local input
    if [[ "$2" == "Bash" || "$2" == "Monitor" ]]; then
        input=$(jq -nc --arg c "$4" '{command:$c}')
    else
        input=$(jq -nc --arg c "$4" '{file_path:"/x/f", content:$c}')
    fi
    jq -nc --arg e "$1" --arg t "$2" --arg m "$3" --arg s "${5:-sid-worker}" --argjson i "$input" \
        '{session_id:$s, hook_event_name:$e, tool_name:$t, permission_mode:$m, cwd:"/work/proj", tool_input:$i, permission_suggestions:[]}'
}
# run_hook <mode> <payload> [extra env…] — stdout of the hook, hermetic state
run_hook() {
    local m="$1" p="$2"; shift 2
    env -i PATH="$PATH" NEXUS_STATE_DIR="$ST" NEXUS_WORKER_WINDOW=w-test NEXUS_DRM_WAIT_S=2 "$@" \
        bash "$HOOK" --mode "$m" <<<"$p" 2>/dev/null
}
nreq() { local n=0 f; for f in "$ST"/decisions/*.json; do [[ -e "$f" && "$f" != *.handled.json ]] && n=$((n+1)); done; echo "$n"; }
expect_silent() {  # <label> <mode> <payload>   — MUST NOT FLIP: no answer, no request
    rm -rf "${ST:?}"; local out; out=$(run_hook "$2" "$3")
    if [[ -z "$out" && "$(nreq)" == 0 && ! -e "$ST/dangerous-rm-decisions.tsv" ]]; then ok "$1"
    else bad "$1" "want no answer and no request, got [${out:0:120}] requests=$(nreq)"; fi
}
behavior() { jq -r '.hookSpecificOutput.decision.behavior // empty' <<<"$1" 2>/dev/null; }
message()  { jq -r '.hookSpecificOutput.decision.message // empty' <<<"$1" 2>/dev/null; }

# first_open <glob…> — the first EXISTING match that is not a tombstone. A
# loop, not `ls <glob>`: under nullglob an unmatched glob leaves `ls` bare,
# and it lists the cwd instead of nothing.
first_open() { local f; for f in "$@"; do [[ -e "$f" && "$f" != *.handled.json ]] && { printf '%s' "$f"; return 0; }; done; return 0; }
first_any()  { local f; for f in "$@"; do [[ -e "$f" ]] && { printf '%s' "$f"; return 0; }; done; return 0; }
B=bypassPermissions
PR=PermissionRequest
SUB='rm -rf "$(printf %s /x/tgt)"'

echo '=== must NOT flip: out-of-class requests get no answer and file nothing (both modes) ==='
for m in worker orchestrator; do
    expect_silent "ctl.$m.nonrm.push: git push --force"       $m "$(payload $PR Bash $B 'git push --force origin x')"
    expect_silent "ctl.$m.nonrm.curl: curl … | sh"            $m "$(payload $PR Bash $B 'curl -s https://e.x/i.sh | sh')"
    expect_silent "ctl.$m.word.dockerrm: docker run --rm img" $m "$(payload $PR Bash $B 'docker run --rm img')"
    expect_silent "ctl.$m.word.farm: echo farm"               $m "$(payload $PR Bash $B 'echo farm')"
    expect_silent "ctl.$m.word.script: ./rm.sh"               $m "$(payload $PR Bash $B './rm.sh a')"
    expect_silent "ctl.$m.word.rmdir2: rmdir2 x"              $m "$(payload $PR Bash $B 'rmdir2 x')"
    expect_silent "ctl.$m.empty.cmd: empty command"           $m "$(payload $PR Bash $B '')"
    for t in Write Edit NotebookEdit Monitor WebFetch Task; do
        expect_silent "ctl.$m.tool.$t: $t carrying 'rm -rf .'" $m "$(payload $PR "$t" $B 'rm -rf .')"
    done
    for pm in default acceptEdits auto plan ''; do
        expect_silent "ctl.$m.mode.${pm:-empty}: rm -rf . in mode [${pm}]" $m "$(payload $PR Bash "$pm" 'rm -rf .')"
    done
    for e in PreToolUse PostToolUse Notification ''; do
        expect_silent "ctl.$m.event.${e:-empty}: rm -rf . on event [${e}]" $m "$(payload "$e" Bash $B 'rm -rf .')"
    done
done
expect_silent "ctl.fail.nopayload: empty stdin"                 worker ""
expect_silent "ctl.fail.garbage: not JSON"                      worker 'rm -rf . {{{'
full=$(payload $PR Bash $B 'rm -rf .')
expect_silent "ctl.fail.truncated: truncated JSON"              worker "${full:0:60}"
expect_silent "ctl.fail.nomode: in-class request with no --mode" '' "$(payload $PR Bash $B 'rm -rf .')"
nojq="$WORK/nojq-bin"; mkdir -p "$nojq"
for c in head date mkdir cat bash sleep od tr sha1sum cut sed grep; do
    p=$(command -v "$c") && ln -sf "$p" "$nojq/$c"
done
rm -rf "${ST:?}"
out=$(env -i PATH="$nojq" NEXUS_STATE_DIR="$ST" NEXUS_WORKER_WINDOW=w-test "$nojq/bash" "$HOOK" --mode worker \
        <<<"$(payload $PR Bash $B 'rm -rf .')" 2>/dev/null)
if [[ -z "$out" && "$(nreq)" == 0 ]]; then ok "ctl.fail.nojq: no jq → no answer, no request"; else bad "ctl.fail.nojq" "[$out]"; fi

echo '=== orchestrator: an in-class request is DENIED at once, with a delegate message ==='
for c in "$SUB" 'rm -rf .' '/bin/rm -r x' 'sh -c "rm -rf $1" _ x' 'rmdir d'; do
    rm -rf "${ST:?}"; t0=$(date +%s)
    out=$(run_hook orchestrator "$(payload $PR Bash $B "$c")")
    is  "orch.deny [$c]: behavior" "$(behavior "$out")" "deny"
    has "orch.msg [$c]: says delegate" "$(message "$out")" "not orchestration"
    is  "orch.nofile [$c]: no request filed (nothing to forward)" "$(nreq)" "0"
    is  "orch.fast [$c]: no wait" "$(( $(date +%s) - t0 <= 1 ))" "1"
done
has "orch.ledger: the deny is recorded" "$(cat "$ST/dangerous-rm-decisions.tsv" 2>/dev/null)" $'\tdeny-orchestrator\t'

echo '=== worker: no answer → DENY at the deadline, with a rewrite hint ==='
rm -rf "${ST:?}"; t0=$(date +%s)
out=$(run_hook worker "$(payload $PR Bash $B "$SUB")")
el=$(( $(date +%s) - t0 ))
is  "wk.timeout.deny: behavior" "$(behavior "$out")" "deny"
has "wk.timeout.msg: names the timeout and the rewrite" "$(message "$out")" "No orchestrator decision within 2s"
is  "wk.timeout.bounded: returned at the deadline (2..4 s)" "$(( el >= 2 && el <= 4 ))" "1"
is  "wk.timeout.closed: request tombstoned, none left open" "$(nreq)" "0"
tomb=$(first_any "$ST"/decisions/w-test.*.handled.json)
is  "wk.timeout.outcome: tombstone records deny-timeout" "$(jq -r .outcome "$tomb" 2>/dev/null)" "deny-timeout"
is  "wk.request.fields: command, cwd, kind, nonce and deadline are recorded" \
    "$(jq -r '[.kind, .command, .cwd, (.nonce|test("^[0-9a-f]{16}$")|tostring), (.deadline_epoch>0|tostring)]|join("|")' "$tomb" 2>/dev/null)" \
    "dangerous_rm|$SUB|/work/proj|true|true"
has "wk.urgent: the nudge stamp names the request" "$(cat "$ST/decisions/.urgent" 2>/dev/null)" "w-test."
has "wk.timeout.ledger" "$(cat "$ST/dangerous-rm-decisions.tsv" 2>/dev/null)" $'\tdeny-timeout\t'

# The classifier line lives on the PANE: with TMUX_PANE set the hook reads it
# (a tmux READ) and records it. Stub tmux renders a dialog line.
rm -rf "${ST:?}"; mkdir -p "$WORK/tbin"
printf '#!/usr/bin/env bash\n[[ "$1" == capture-pane ]] && printf " Bash command\\n │ Dangerous rm operation on working directory or its ancestor: /work/proj\\n Do you want to proceed?\\n"\nexit 0\n' > "$WORK/tbin/tmux"; chmod +x "$WORK/tbin/tmux"
env -i PATH="$WORK/tbin:$PATH" TMUX_PANE=%9 NEXUS_STATE_DIR="$ST" NEXUS_WORKER_WINDOW=w-test NEXUS_DRM_WAIT_S=1 \
    bash "$HOOK" --mode worker <<<"$(payload $PR Bash $B 'rm -rf .')" >/dev/null 2>&1
is  "wk.classifier: the classifier line is captured from the pane" \
    "$(jq -r .classifier "$(first_any "$ST"/decisions/w-test.*.handled.json)" 2>/dev/null)" \
    "Dangerous rm operation on working directory or its ancestor: /work/proj"

# answer_async <decision> <session> [reason] — the REAL verb, as the orchestrator
# would run it, once the worker's request appears.
answer_async() {
    ( for _ in $(seq 1 40); do
          f=$(first_open "$ST"/decisions/w-test.*.json)
          [[ -n "$f" ]] && break; sleep 0.1
      done
      fp=$(jq -r .fingerprint "$f"); nonce=$(jq -r .nonce "$f")
      env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$ST" CLAUDE_CODE_SESSION_ID="$2" NEXUS_ORCHESTRATOR_WINDOW=orch \
          bash "$NG" decision-answer w-test "$fp" "$1" --nonce "$nonce" ${3:+--reason "$3"} > "$WORK/verb.out" 2>&1
      echo "rc=$?" >> "$WORK/verb.out" ) &
}

echo '=== worker: the orchestrator ANSWERS allow → allow ==='
rm -rf "${ST:?}"; answer_async allow sid-orchestrator
out=$(run_hook worker "$(payload $PR Bash $B "$SUB")" NEXUS_DRM_WAIT_S=10); wait
is  "wk.allow: behavior" "$(behavior "$out")" "allow"
has "wk.allow.verb: the verb reported success" "$(cat "$WORK/verb.out")" "rc=0"
has "wk.allow.ledger: outcome allow, answered by orch/sid-orchestrator" "$(cat "$ST/dangerous-rm-decisions.tsv")" $'\tallow\t'
has "wk.allow.by: the answerer is recorded" "$(cat "$ST/dangerous-rm-decisions.tsv")" "orch/sid-orchestrator/"
is  "wk.allow.closed: request closed and answer consumed" "$(nreq)/$(ls "$ST/decisions/answers" | wc -l)" "0/0"

echo '=== worker: the orchestrator ANSWERS deny → deny, with its reason ==='
rm -rf "${ST:?}"; answer_async deny sid-orchestrator "the target is the shared cache"
out=$(run_hook worker "$(payload $PR Bash $B "$SUB")" NEXUS_DRM_WAIT_S=10); wait
is  "wk.deny: behavior" "$(behavior "$out")" "deny"
has "wk.deny.reason: the orchestrator's reason reaches the model" "$(message "$out")" "the target is the shared cache"

echo '=== worker: a SELF-answer (the requesting session) is refused with a deny ==='
rm -rf "${ST:?}"; answer_async allow sid-worker
out=$(run_hook worker "$(payload $PR Bash $B "$SUB" sid-worker)" NEXUS_DRM_WAIT_S=10); wait
is  "wk.self.deny: behavior" "$(behavior "$out")" "deny"
has "wk.self.msg: says why" "$(message "$out")" "REQUESTING session"
has "wk.self.ledger" "$(cat "$ST/dangerous-rm-decisions.tsv")" $'\tdeny-self-answer\t'

echo '=== worker: an EMPTY or missing session_id fails CLOSED, even against a real allow ==='
# Skeptic finding 2 on PR #1633: with no requester session the self-answer check
# was skipped, so an allow applied. Now nothing is forwarded and it is denied.
for variant in empty missing; do
    rm -rf "${ST:?}"; answer_async allow sid-orchestrator
    if [[ $variant == empty ]]; then p=$(payload $PR Bash $B "$SUB" | jq -c '.session_id=""')
    else p=$(payload $PR Bash $B "$SUB" | jq -c 'del(.session_id)'); fi
    out=$(run_hook worker "$p" NEXUS_DRM_WAIT_S=4); wait
    is  "wk.nosid.$variant: no allow without a requester session id" "$(behavior "$out")" "deny"
    has "wk.nosid.$variant.ledger: recorded as deny-no-session" "$(cat "$ST/dangerous-rm-decisions.tsv" 2>/dev/null)" $'\tdeny-no-session\t'
done

echo '=== worker: a mismatched nonce is not an answer — it times out to deny ==='
rm -rf "${ST:?}"
( for _ in $(seq 1 40); do f=$(first_open "$ST"/decisions/w-test.*.json); [[ -n "$f" ]] && break; sleep 0.1; done
  fp=$(jq -r .fingerprint "$f"); mkdir -p "$ST/decisions/answers"
  jq -n --arg fp "$fp" '{fingerprint:$fp, nonce:"0000000000000000", decision:"allow", answered_by_session:"sid-x"}' \
      > "$ST/decisions/answers/w-test.$fp.json" ) &
out=$(run_hook worker "$(payload $PR Bash $B "$SUB")" NEXUS_DRM_WAIT_S=3); wait
is  "wk.nonce.deny: a forged-nonce allow does not apply" "$(behavior "$out")" "deny"
has "wk.nonce.timeout: it is the timeout deny" "$(message "$out")" "No orchestrator decision"

echo '=== ng decision-answer refuses what it must ==='
rm -rf "${ST:?}"; mkdir -p "$ST/decisions"
jq -n '{kind:"dangerous_rm", window:"w9", fingerprint:"abcdefabcdef", nonce:"1111222233334444", deadline_epoch:9999999999}' \
    > "$ST/decisions/w9.abcdefabcdef.json"
NEXUS_STATE_DIR="$ST" NEXUS_WORKER_WINDOW=w9 bash "$NG" decision-answer w9 abcdefabcdef allow --nonce 1111222233334444 >/dev/null 2>&1
is  "verb.worker: refused inside a worker session (rc 3)" "$?" "3"
is  "verb.worker.nofile: and wrote nothing" "$(ls "$ST/decisions/answers" 2>/dev/null | wc -l | tr -d ' ')" "0"
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$ST" bash "$NG" decision-answer w9 abcdefabcdef allow --nonce 9999999999999999 >/dev/null 2>&1
is  "verb.nonce: a wrong nonce is refused (rc 5)" "$?" "5"
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$ST" bash "$NG" decision-answer w9 abcdefabcdef maybe --nonce 1111222233334444 >/dev/null 2>&1
is  "verb.decision: only allow|deny" "$(( $? != 0 ))" "1"
mv "$ST/decisions/w9.abcdefabcdef.json" "$ST/decisions/w9.abcdefabcdef.handled.json"
jq '. + {outcome:"deny-timeout"}' "$ST/decisions/w9.abcdefabcdef.handled.json" > "$WORK/t" && mv "$WORK/t" "$ST/decisions/w9.abcdefabcdef.handled.json"
vo=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$ST" bash "$NG" decision-answer w9 abcdefabcdef allow --nonce 1111222233334444 2>&1); vrc=$?
is  "verb.late: a closed request is TOO LATE (rc 4)" "$vrc" "4"
has "verb.late.msg: and names the outcome" "$vo" "deny-timeout"
jq -n '{kind:"permission_prompt", window:"w9", fingerprint:"123456123456"}' > "$ST/decisions/w9.123456123456.json"
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$ST" bash "$NG" decision-answer w9 123456123456 allow --nonce x >/dev/null 2>&1
is  "verb.kind: refuses a row that is not dangerous_rm" "$(( $? != 0 ))" "1"

echo '=== --heartbeat: out of class → permission_prompt; decided → busy ==='
hb_run() {  # <payload> <mode> → heartbeat state written for window w-hb
    rm -rf "${WORK:?}/hb"
    env -i PATH="$PATH" NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$WORK/hb" NEXUS_WORKER_WINDOW=w-hb NEXUS_DRM_WAIT_S=1 \
        bash "$HOOK" --mode "$2" --heartbeat <<<"$1" >/dev/null 2>&1
    jq -r '.state // empty' "$WORK/hb/heartbeat/w-hb.json" 2>/dev/null
}
is "hb.decided: a decided request (timeout deny) → busy" "$(hb_run "$(payload $PR Bash $B 'rm -rf .')" worker)" "busy"
is "hb.prompt: non-rm Bash prompt → permission_prompt (as before)" "$(hb_run "$(payload $PR Bash $B 'git push')" worker)" "permission_prompt"
is "hb.prompt.tool: non-Bash prompt → permission_prompt (as before)" "$(hb_run "$(payload $PR Write $B 'x')" worker)" "permission_prompt"

echo '=== wiring: worker forwards (no matcher, heartbeat for every prompt), orchestrator denies ==='
W="$REPO_ROOT/monitor/worker-settings.json"; O="$REPO_ROOT/monitor/orchestrator-settings.json"
is "wire.worker" "$(jq -r '[.hooks.PermissionRequest[] | select(has("matcher")|not) | .hooks[] | "\(.command) t=\(.timeout)"] | join("|")' "$W")" \
   '$NEXUS_ROOT/monitor/hooks/dangerous-rm-decide.sh --mode worker --heartbeat t=115'
is "wire.orch" "$(jq -r '[.hooks.PermissionRequest[] | select(.matcher=="Bash") | .hooks[] | "\(.command) t=\(.timeout)"] | join("|")' "$O")" \
   '$NEXUS_ROOT/monitor/hooks/dangerous-rm-decide.sh --mode orchestrator t=30'
is "wire.timeout: the worker hook timeout exceeds its 100 s default wait" "$(jq -r '.hooks.PermissionRequest[0].hooks[0].timeout > 100' "$W")" "true"
for f in "$W" "$O"; do
    is "wire.norule: $(basename "$f") carries no rm allow RULE" "$(jq -r '[.permissions.allow[]? | select(test("rm"))] | length' "$f")" "0"
    is "wire.noparallel: $(basename "$f") has no separate permission_prompt heartbeat" \
       "$(jq -r '[.hooks | to_entries[] | .value[] | .hooks[].command | select(test("worker-heartbeat.sh permission_prompt"))] | length' "$f")" "0"
done

echo '=== watcher: the request is a pending-decision row that cannot expire unseen ==='
R="$WORK/render"; mkdir -p "$R/bin" "$R/state/decisions"
printf '#!/usr/bin/env bash\n[[ "$1" == list-windows ]] && printf "wa|1\\nwb|2\\n"\nexit 0\n' > "$R/bin/tmux"; chmod +x "$R/bin/tmux"
now=$(date +%s)
jq -n --argjson dl $((now+80)) '{kind:"dangerous_rm", window:"wa", fingerprint:"aaaaaaaaaaaa", nonce:"0123456789abcdef",
    command:"rm -rf \"$(printf %s /x/t)\"", cwd:"/work/a", classifier:"Dangerous rm operation on statically-unresolvable target: command substitution output",
    deadline_epoch:$dl, prompt_excerpt:"dangerous rm awaiting an orchestrator decision", unresolved:true}' > "$R/state/decisions/wa.aaaaaaaaaaaa.json"
jq -n '{kind:"permission_prompt", window:"wa", fingerprint:"bbbbbbbbbbbb", prompt_excerpt:"Claude needs your permission to use Bash"}' > "$R/state/decisions/wa.bbbbbbbbbbbb.json"
jq -n '{kind:"permission_prompt", window:"wb", fingerprint:"cccccccccccc", prompt_excerpt:"Claude needs your permission to use Bash"}' > "$R/state/decisions/wb.cccccccccccc.json"
render() { ( PATH="$R/bin:$PATH"; export STATE_DIR="$R/state" MONITOR_PENDING_PANE_GATE=false
             . "$_test_dir/_idle_probe.sh" >/dev/null 2>&1; render_pending_decisions 2>/dev/null ); }
r1=$(render); r2=$(render)
has "rd.row: the request is emitted as kind=dangerous_rm"   "$r1" "window=wa fp=aaaaaaaaaaaa kind=dangerous_rm"
has "rd.command: with the FULL command"                     "$r1" 'command=rm -rf "$(printf %s /x/t)"'
has "rd.cwd: and the cwd"                                   "$r1" "cwd=/work/a"
has "rd.classifier: and the classifier line"                "$r1" "classifier=Dangerous rm operation on statically-unresolvable target"
has "rd.verb: and the exact answer verb, nonce included"    "$r1" "answer=ng decision-answer wa aaaaaaaaaaaa allow|deny --nonce 0123456789abcdef"
has "rd.nocooldown: re-emitted on the very next render"     "$r2" "kind=dangerous_rm"
is  "rd.suppress: the same window's permission_prompt row is suppressed" "$(grep -c 'fp=bbbbbbbbbbbb' <<<"$r1")" "0"
has "rd.ctl.otherwin: ANOTHER window's permission_prompt still emits (must not flip)" "$r1" "window=wb fp=cccccccccccc kind=permission_prompt"
jq --argjson dl $((now-60)) '.deadline_epoch=$dl' "$R/state/decisions/wa.aaaaaaaaaaaa.json" > "$R/t" && mv "$R/t" "$R/state/decisions/wa.aaaaaaaaaaaa.json"
rm -f "$R/state/pending-decisions-emit-state.tsv"
r3=$(render)
is  "rd.expired: a request past deadline+30s (killed hook) is not emitted" "$(grep -c 'kind=dangerous_rm' <<<"$r3")" "0"
has "rd.expired.unsuppress: and wa's permission_prompt row is no longer suppressed" "$r3" "fp=bbbbbbbbbbbb"

echo '=== watcher: the urgent stamp pulls compose_emit forward ==='
nd=$( . "$_test_dir/_compose_nudge.sh" >/dev/null 2>&1
      declare -A TASK_FN=([compose_emit]=x [pending_decisions]=x); _nd_fired=""
      _schedule_fire_now() { _nd_fired+="$1 "; }; _schedule_override() { :; }
      _compose_nudge_reset_for_tests
      u="$WORK/urgent"; printf 'x\n' > "$u"
      _compose_emit_nudge_check /nonexistent /nonexistent "" "$u"; echo "first=$? fired=[$_nd_fired]"
      _nd_fired=""; _compose_emit_nudge_check /nonexistent /nonexistent "" "$u"; echo "again=$? fired=[$_nd_fired]" )
has "nudge.fires: a new urgent stamp fires the render, then compose_emit" "$nd" "first=0 fired=[pending_decisions compose_emit ]"
has "nudge.once: an unchanged stamp does not fire again"       "$nd" "again=1 fired=[]"

# ASSERTION CENSUS: a row that stops running is a red, not a smaller green.
# nosid 2x2 = 4;
# ctl: 2 modes x (7 + 6 tools + 5 modes + 4 events) = 44, + 5 failure = 49;
# orch 5x4 + 1 = 21; timeout 8 + classifier 1; allow 5; deny 2; self 3; nonce 2; verb 7;
# heartbeat 3; wiring 3 + 2x2 = 7; render 10; nudge 2.  Total 124.
_EXPECTED_ASSERTIONS=124
if (( PASS + FAIL == _EXPECTED_ASSERTIONS )); then
    ok "assertion count reconciles ($_EXPECTED_ASSERTIONS)"
else
    bad "assertion count drifted" "ran $(( PASS + FAIL )), expected $_EXPECTED_ASSERTIONS"
fi

th_summary_and_exit
