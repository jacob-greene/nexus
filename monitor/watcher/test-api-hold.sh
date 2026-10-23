#!/usr/bin/env bash
# test-api-hold.sh — your-org/nexus-code#1845, the API-unreachable hold.
#
# 2026-10-15: a site DNS failure (EAI_AGAIN) crashed every agent's turn, the
# orchestrator's included, and nothing resumed them for ~5 h, because the one
# actor that pastes a resume was down for the same reason. These parts each pin
# one thing that can independently rot:
#
#   A  CLASSIFIER. The harness reports EAI_AGAIN and an Anthropic 500 with the
#      SAME token (`server_error`), so the class must come from the message.
#      Carries the negative controls: a 500, an auth expiry, a rate limit.
#   B  ENTRY. Two sessions → held; the orchestrator alone → held. NEGATIVE
#      CONTROLS: ONE worker → not held; two sessions with a NON-transport error
#      (a 500) → not held; a stale marker → not held.
#   C  WHILE HELD. The gate answers 0, a crashed worker is protected from the
#      idle-too-long promotion, orchestrator-liveness files no resubmit and no
#      respawn, the summary alert is queued UNSENT, a failing probe changes
#      nothing, and no paste happens.
#   D  THE RESUME. On a positive probe: exactly one nudge per crashed window,
#      the ORCHESTRATOR FIRST; none to a window with a typed draft, with
#      queued input, or that never crashed. The alert row goes `handed-off`,
#      never `sent`. A second step pastes nothing (one per window per hold),
#      and the markers this hold counted cannot re-enter it.
#   E  ORCHESTRATOR DOWN. The orchestrator crashed, takes NO turn, and its own
#      paste FAILS — and the workers are still nudged, in the same step. The
#      whole resume is the watcher's process writing to tmux.
#   F  POTENCY. The same fixture with the hold disabled reproduces today's
#      behaviour: no hold, no paste, liveness unaffected, and the idle row
#      still tells the orchestrator to PASTE (the per-window `interrupted`
#      row) — so the suite can tell the two apart.
#   G  BOUNDS. The ceiling fails the gates OPEN but still nudges on recovery;
#      a row nobody steps releases; a flapping API cannot re-nudge a window
#      inside the minimum interval; a cleared marker exits the hold.
#   H  THE PROBE's rc is classified as a SET, through a PATH-front fake curl.
#   I  THE HOOK records `prompt_id`, and its marker classifies `transport`.
#   J  WIRING. main.sh carries the arm on every emit paste site.
#
# No real tmux and no real `claude`: the production functions are driven
# directly against a temporary STATE_DIR, with the pane, paste and probe seams
# replaced by recorders.
#
# Run: bash monitor/watcher/test-api-hold.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MON="$REPO_ROOT/monitor"

# ---- POPULATION DECLARATION (your-org/nexus-code#1078) --------------------
# What this suite READS: the module, its classifier, the hook it relies on,
# the liveness gate, the idle render, the config defaults, and main.sh's
# wiring (part J greps it).
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        "$_test_dir/_api_hold.sh" \
        "$MON/hooks/_cause_classify.sh" \
        "$MON/hooks/turn-failure-emit.sh" \
        "$_test_dir/_orchestrator_liveness.sh" \
        "$_test_dir/_idle_probe.sh" \
        "$_test_dir/_config.sh" \
        "$_test_dir/main.sh"
}
gp_handle "$@"

. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0; SKIP=0

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-api-hold.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR/turn-failure"
export STATE_DIR
# Pin the hook's state dir so part I can never write the checkout's own state.
export NEXUS_STATE_DIR="$STATE_DIR"
TARGET=orchestrator

. "$_test_dir/_api_hold.sh"

# ---- recording seams ------------------------------------------------------
LOGF="$WORK/log"; PASTES="$WORK/pastes"; ALERTS="$WORK/alerts"; BELLS="$WORK/bells"
: > "$LOGF"; : > "$PASTES"; : > "$ALERTS"; : > "$BELLS"
rec_log()   { printf '%s\n' "$1" >> "$LOGF"; }
rec_bell()  { printf '%s\n' "$1" >> "$BELLS"; }
rec_alert() { printf '%s\t%s\n' "$1" "${2:-}" >> "$ALERTS"; [[ "$1" == standing ]] && return 1; return 0; }
# MOCK_PASTE_FAIL names windows whose paste returns 4 (Enter sent, not seen).
rec_paste() {
    printf '%s\n' "$1" >> "$PASTES"; cp "$2" "$WORK/body.$1" 2>/dev/null
    [[ " ${MOCK_PASTE_FAIL:-} " == *" $1 "* ]] && return 4
    return 0
}
# MOCK_PANE rows: `<window>|<rc>|<pane-state line>`; an unlisted window is rc 3.
mock_pane() {
    local row; row=$(printf '%s\n' "${MOCK_PANE:-}" | awk -F'|' -v k="$1" '$1 == k {print; exit}')
    [[ -n "$row" ]] || return 3
    local rc; rc=$(cut -d'|' -f2 <<<"$row")
    printf '%s' "$(cut -d'|' -f3- <<<"$row")"
    return "$rc"
}
# MOCK_PROBE: `<verdict>\t<detail>`.
mock_probe() { printf '%s' "${MOCK_PROBE:-probe-error	unset}"; }
_API_HOLD_LOG_FN=rec_log
_API_HOLD_ALERT_FN=rec_bell
_API_HOLD_OPERATOR_ALERT_FN=rec_alert
_API_HOLD_PASTE_FN=rec_paste
_API_HOLD_PANE_FN=mock_pane
_API_HOLD_PROBE_FN=mock_probe
# Fast probe spacing so a test probe is never refused for being too soon.
export MONITOR_API_HOLD_PROBE_INTERVAL_SECONDS=0

EAI="API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)"
E500="API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment."

now=$(date +%s)
# plant <window> <ts> <error> <msg> [session]
plant() {
    jq -nc --argjson ts "$2" --arg e "$3" --arg m "$4" --arg s "${5:-sess-$1}" --arg w "$1" \
        '{ts:$ts,error:$e,category:"transient",recovery:"paste",last_msg:$m,session_id:$s,prompt_id:("p-"+$w),window:$w,hook_event_name:"StopFailure"}' \
        > "$STATE_DIR/turn-failure/$1.json"
}
reset() {
    rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR/turn-failure"
    : > "$LOGF"; : > "$PASTES"; : > "$ALERTS"; : > "$BELLS"; rm -f "$WORK"/body.*
    MOCK_PANE=""; MOCK_PROBE=$'probe-error\tunset'; MOCK_PASTE_FAIL=""
    unset MONITOR_API_HOLD_ENABLED MONITOR_API_HOLD_MAX_HOLD_SECONDS
}
n_pastes() { grep -c . "$PASTES" 2>/dev/null || true; }
held() { if _api_hold_active; then echo held; else echo released; fi; }
IDLE="state=idle active=0 input=blank"

command -v jq >/dev/null 2>&1 || { th_skip "jq unavailable — the sensor needs it"; th_summary_and_exit; }

# ════════════════════════════════════════════════════════════════════════════
echo '=== A classifier: transport vs server vs other ==='
assert_eq "A EAI_AGAIN copy under token server_error → transport" "$(cause_classify_class server_error "$EAI")" transport
assert_eq "A ENOTFOUND → transport" "$(cause_classify_class '' 'getaddrinfo ENOTFOUND api.anthropic.com')" transport
assert_eq "A ECONNRESET → transport" "$(cause_classify_class unknown 'read ECONNRESET')" transport
assert_eq "A token connection_error → transport" "$(cause_classify_class connection_error '')" transport
assert_eq "A NEG a real 500 copy → server, NOT transport" "$(cause_classify_class server_error "$E500")" server
assert_eq "A NEG overloaded → server" "$(cause_classify_class overloaded_error 'Overloaded')" server
assert_eq "A NEG auth expiry → other" "$(cause_classify_class authentication_failed 'Login expired · Please run /login')" other
assert_eq "A NEG empty → other" "$(cause_classify_class '' '')" other
# The existing category axis is UNCHANGED for the EAI_AGAIN payload (#1050):
assert_eq "A the category axis still says transient:paste for it" "$(cause_classify_error server_error "$EAI" | tr '\t' :)" transient:paste

# ════════════════════════════════════════════════════════════════════════════
echo '=== B entry ==='
reset
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 20 )) server_error "$EAI"
_api_hold_step "$TARGET"
assert_eq "B two sessions with transport errors → HELD" "$(held)" held
assert_eq "B …the crashed set holds both windows" "$(cut -f1 "$STATE_DIR/api-hold-crashed.tsv" | paste -sd, -)" "w1,w2"
assert_contains "B …the ENGAGED line is logged" "$(cat "$LOGF")" "api-hold: ENGAGED"
assert_eq "B …the bell rang once" "$(grep -c . "$BELLS")" 1
assert_contains "B …the operator alert is RAISED on key api-unreachable" "$(cat "$ALERTS")" "raise	api-unreachable"
assert_eq "B …the prompt id was recorded with the window" "$(awk -F'\t' '$1=="w1"{print $3}' "$STATE_DIR/api-hold-crashed.tsv")" p-w1

reset
plant "$TARGET" $(( now - 30 )) server_error "$EAI"
_api_hold_step "$TARGET"
assert_eq "B the orchestrator ALONE → HELD" "$(held)" held
assert_eq "B …and the row records the orchestrator as crashed" "$(cut -f5 "$STATE_DIR/api-hold.tsv")" 1

reset
plant w1 $(( now - 30 )) server_error "$EAI"
_api_hold_step "$TARGET"
assert_eq "B NEG ONE worker alone → not held (its existing owner keeps it)" "$(held)" released
assert_eq "B NEG …and no alert was raised" "$(grep -c raise "$ALERTS" || true)" 0

reset
plant w1 $(( now - 30 )) server_error "$E500"
plant w2 $(( now - 20 )) server_error "$E500"
_api_hold_step "$TARGET"
assert_eq "B NEG two sessions with a real 500 (an API-side outage) → not held" "$(held)" released

reset
plant w1 $(( now - 3600 )) server_error "$EAI"
plant w2 $(( now - 3600 )) server_error "$EAI"
_api_hold_step "$TARGET"
assert_eq "B NEG transport markers older than the signal window → not held" "$(held)" released

reset
plant w1 $(( now - 30 )) server_error "$EAI" same-session
plant w2 $(( now - 20 )) server_error "$EAI" same-session
_api_hold_step "$TARGET"
assert_eq "B NEG two windows of ONE session count once → not held" "$(held)" released

# ════════════════════════════════════════════════════════════════════════════
echo '=== C while held ==='
reset
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 20 )) server_error "$EAI"
MOCK_PANE="$TARGET|0|$IDLE
w1|0|$IDLE
w2|0|$IDLE"
_api_hold_step "$TARGET"
MOCK_PROBE=$'unreachable\tdns curl_rc=6'
_api_hold_probe_step
_api_hold_step "$TARGET"
assert_eq "C a failing probe keeps the hold" "$(held)" held
assert_eq "C …and NOTHING is pasted while held" "$(n_pastes)" 0
assert_eq "C the probe result is recorded" "$(cut -f2 "$STATE_DIR/api-hold-probe.tsv")" unreachable
if _api_hold_window_awaiting_nudge w1; then pass_=1; else pass_=0; fi
assert_eq "C a crashed worker is protected from the idle-too-long promotion" "$pass_" 1
if _api_hold_window_awaiting_nudge w9; then pass_=1; else pass_=0; fi
assert_eq "C NEG a window that did not crash is NOT protected" "$pass_" 0
assert_eq "C the summary alert is queued UNSENT" "$(cut -f3 "$STATE_DIR/api-hold-alerts.tsv")" UNSENT
assert_contains "C the render note tells the orchestrator NOT to paste" "$(_api_hold_render_notes)" "do NOT paste one now"

# Orchestrator-liveness: past grace, a lost paste would normally resubmit.
. "$_test_dir/_orchestrator_liveness.sh" 2>/dev/null || true
if declare -F _orchestrator_liveness_decide >/dev/null 2>&1; then
    lp="$WORK/lp"; printf '%s\n' "$(( now - 600 ))" > "$lp"
    v=$(_orchestrator_liveness_decide "$WORK/hb" "$WORK/pr" "$lp" "$WORK/pin" "$WORK/us" "$WORK/rm" \
        120 150 300 1800 "$REPO_ROOT" "$WORK/home" 2>/dev/null); rc=$?
    assert_contains "C liveness verdict is healthy reason=api-unreachable (no resubmit, no respawn)" "$v" "healthy reason=api-unreachable"
    assert_eq "C …with rc 1 (no action)" "$rc" 1
else
    fail_msg="could not source _orchestrator_liveness.sh"; printf '  FAIL: C %s\n' "$fail_msg" >&2; _th_fail; _th_fail
fi

# ════════════════════════════════════════════════════════════════════════════
echo '=== D the resume ==='
reset
plant "$TARGET" $(( now - 40 )) server_error "$EAI"
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 25 )) server_error "$EAI"
plant w3 $(( now - 20 )) server_error "$EAI"
plant w4 $(( now - 15 )) server_error "$EAI"
MOCK_PANE="$TARGET|0|$IDLE
w1|0|$IDLE
w2|0|state=user-typing active=0 input=typed
w3|0|state=busy active=0 queued=1 input=blank
w4|0|state=autosuggest-only active=0 input=ghost
w9|0|$IDLE"
_api_hold_step "$TARGET"
assert_eq "D precondition: held" "$(held)" held
MOCK_PROBE=$'reachable\thttp=404'
_api_hold_probe_step
_api_hold_step "$TARGET"
assert_eq "D a positive probe RELEASES the hold" "$(held)" released
assert_eq "D the ORCHESTRATOR is nudged FIRST" "$(sed -n 1p "$PASTES")" "$TARGET"
assert_eq "D exactly the eligible crashed windows, once each, in order" "$(paste -sd, - < "$PASTES")" "$TARGET,w1,w4"
assert_not_contains "D NEG no nudge into a typed operator draft (w2)" "$(cat "$PASTES")" w2
assert_not_contains "D NEG no nudge where input is queued (w3)" "$(cat "$PASTES")" w3
assert_not_contains "D NEG no nudge to a window that never crashed (w9)" "$(cat "$PASTES")" w9
assert_contains "D the worker nudge names the outage and asks to continue" "$(cat "$WORK/body.w1")" "your last turn did not complete"
assert_contains "D the orchestrator nudge carries the summary" "$(cat "$WORK/body.$TARGET")" "pasting a resume into: w1, w4"
assert_contains "D …and names the skipped draft window with its reason" "$(cat "$WORK/body.$TARGET")" "w2 (input=typed"
assert_eq "D the alert row is handed-off, never 'sent'" "$(cut -f3 "$STATE_DIR/api-hold-alerts.tsv")" handed-off
assert_not_contains "D NEG no row anywhere claims SENT" "$(cat "$STATE_DIR/api-hold-alerts.tsv")" "	sent"
assert_contains "D the operator alert is CLEARED" "$(cat "$ALERTS")" "clear	api-unreachable"
assert_contains "D …and the summary is handed to notify" "$(cat "$ALERTS")" "notify	api-unreachable-resolved"
assert_contains "D the ledger records the skip and its reason" "$(cat "$STATE_DIR/api-hold-nudged.tsv")" "skipped queued=1"
_api_hold_step "$TARGET"; _api_hold_step "$TARGET"
assert_eq "D a later step pastes NOTHING more (one per window per hold)" "$(n_pastes)" 3
assert_eq "D …and the markers this hold counted cannot RE-ENTER it" "$(held)" released
assert_contains "D the render note now says the watcher already pasted" "$(_api_hold_render_notes)" "do NOT paste another"

# ════════════════════════════════════════════════════════════════════════════
echo '=== E orchestrator down: no orchestrator turn, its own paste FAILS ==='
reset
plant "$TARGET" $(( now - 40 )) server_error "$EAI"
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 25 )) server_error "$EAI"
MOCK_PANE="$TARGET|0|$IDLE
w1|0|$IDLE
w2|0|$IDLE"
MOCK_PASTE_FAIL="$TARGET"
_api_hold_step "$TARGET"
MOCK_PROBE=$'reachable\thttp=404'
_api_hold_probe_step
_api_hold_step "$TARGET"
assert_eq "E the orchestrator was tried first, then BOTH workers, in one step" "$(paste -sd, - < "$PASTES")" "$TARGET,w1,w2"
assert_contains "E the orchestrator's failed paste is recorded as failed, not nudged" \
    "$(awk -F'\t' -v t="$TARGET" '$1==t {print $4}' "$STATE_DIR/api-hold-nudged.tsv")" "failed paste rc=4"
assert_eq "E the workers' nudges are recorded nudged" \
    "$(awk -F'\t' '$1 ~ /^w/ && $4=="nudged"' "$STATE_DIR/api-hold-nudged.tsv" | grep -c .)" 2

# ════════════════════════════════════════════════════════════════════════════
echo '=== F potency: the same fixture with the hold DISABLED is today’s behaviour ==='
reset
export MONITOR_API_HOLD_ENABLED=false
plant "$TARGET" $(( now - 40 )) server_error "$EAI"
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 25 )) server_error "$EAI"
MOCK_PANE="$TARGET|0|$IDLE
w1|0|$IDLE
w2|0|$IDLE"
_api_hold_step "$TARGET"
MOCK_PROBE=$'reachable\thttp=404'
_api_hold_probe_step
_api_hold_step "$TARGET"
assert_eq "F disabled: no hold" "$(held)" released
assert_eq "F disabled: NO paste (the orchestrator was the only one who could)" "$(n_pastes)" 0
assert_eq "F disabled: no render note" "$(_api_hold_render_notes)" ""
if declare -F _orchestrator_liveness_decide >/dev/null 2>&1; then
    v=$(_orchestrator_liveness_decide "$WORK/hb" "$WORK/pr" "$lp" "$WORK/pin" "$WORK/us" "$WORK/rm" \
        120 150 300 1800 "$REPO_ROOT" "$WORK/home" 2>/dev/null)
    assert_not_contains "F disabled: liveness is NOT gated by the hold" "$v" "api-unreachable"
else
    _th_fail
fi
# The idle render, through the production renderer: with the hold off the row
# is today's "PASTE a resume nudge"; with a hold open it is the watcher's note.
_render_ok=0
if ( . "$_test_dir/_idle_probe.sh" ) >/dev/null 2>&1; then
    . "$_test_dir/_idle_probe.sh" >/dev/null 2>&1 && _render_ok=1
fi
if (( _render_ok )) && declare -F render_idle_section >/dev/null 2>&1; then
    list_idle_transitions() { printf 'w1\tinterrupted\t120\ttransient:paste\n'; }
    out=$(render_idle_section 2>/dev/null)
    assert_contains "F disabled: the row is today's 'PASTE a resume nudge'" "$out" "PASTE a resume nudge"
    unset MONITOR_API_HOLD_ENABLED
    _api_hold_step "$TARGET"   # re-enters on the same markers (none were counted by an exit)
    out=$(render_idle_section 2>/dev/null)
    assert_contains "F enabled + held: the SAME row now says the watcher owns the resume" "$out" "do NOT paste one now"
    assert_not_contains "F enabled + held: …and no longer tells the orchestrator to paste" "$out" "PASTE a resume nudge"
else
    th_skip "F render: _idle_probe.sh could not be sourced standalone here"
    th_skip "F render (held arm)"
    th_skip "F render (held arm, negative)"
    unset MONITOR_API_HOLD_ENABLED
fi

# ════════════════════════════════════════════════════════════════════════════
echo '=== G bounds ==='
reset
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 20 )) server_error "$EAI"
MOCK_PANE="w1|0|$IDLE
w2|0|$IDLE"
_api_hold_step "$TARGET"
# Age the hold past the ceiling by rewriting `entered`.
IFS=$'\t' read -r id en t0 ls orch < "$STATE_DIR/api-hold.tsv"
printf '%s\t%s\t%s\t%s\t%s\n' "$id" $(( now - 50000 )) "$t0" "$now" "$orch" > "$STATE_DIR/api-hold.tsv"
assert_eq "G past the ceiling the gate FAILS OPEN" "$(held)" released
if _api_hold_window_awaiting_nudge w1; then pass_=1; else pass_=0; fi
assert_eq "G …but the crashed worker is still owed (and protected for) its nudge" "$pass_" 1
MOCK_PROBE=$'unreachable\tdns'
_api_hold_probe_step; _api_hold_step "$TARGET"
assert_contains "G …the crossing is logged" "$(cat "$LOGF")" "ceiling CROSSED"
MOCK_PROBE=$'reachable\thttp=404'
sleep 1; _api_hold_probe_step; _api_hold_step "$TARGET"
assert_eq "G …and on recovery the nudges still go out" "$(paste -sd, - < "$PASTES")" "w1,w2"

reset
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 20 )) server_error "$EAI"
_api_hold_step "$TARGET"
IFS=$'\t' read -r id en t0 ls orch < "$STATE_DIR/api-hold.tsv"
printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$en" "$t0" $(( now - 5000 )) "$orch" > "$STATE_DIR/api-hold.tsv"
assert_eq "G a row nobody has stepped for > staleness RELEASES" "$(held)" released

reset
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 20 )) server_error "$EAI"
MOCK_PANE="w1|0|$IDLE
w2|0|$IDLE"
_api_hold_step "$TARGET"
rm -f "$STATE_DIR/turn-failure/w2.json"     # w2 completed a turn
_api_hold_step "$TARGET"
assert_eq "G a cleared marker (a turn SUCCEEDED) exits the hold with no probe" "$(held)" released
assert_eq "G …w1 is nudged, w2 (recovered) is not" "$(paste -sd, - < "$PASTES")" "w1"
# Flap (skeptic ncbundle29-sk F1, your-org/nexus-code#1847): w1's nudged turn
# fails again at once. That is a NEW crash, so the new hold owes w1 a nudge,
# whatever the cross-hold interval says. The first cut asserted the opposite
# ("w1 is NOT re-nudged inside the minimum interval"), and so pinned the
# stranded board as correct.
sleep 1
plant w1 $(( $(date +%s) )) server_error "$EAI"
plant w3 $(( $(date +%s) )) server_error "$EAI"
MOCK_PANE="w1|0|$IDLE
w3|0|$IDLE"
assert_not_contains "G flap: once w1 crashes AGAIN, the note no longer says do NOT paste another for it" \
    "$(_api_hold_render_notes | awk -F'\t' '$1 == "w1"')" "do NOT paste another"
_api_hold_step "$TARGET"
assert_eq "G flap: a fresh failure re-enters a NEW hold" "$(held)" held
MOCK_PROBE=$'reachable\thttp=404'
_api_hold_probe_step; _api_hold_step "$TARGET"
assert_eq "G flap: on the REAL recovery the re-crashed w1 IS nudged again, and w3" "$(paste -sd, - < "$PASTES")" "w1,w1,w3"
# The interval still bounds what it exists for: a nudge whose turn has NOT
# failed again (marker no newer than the nudge) satisfies across holds.
_last_e=$(awk -F'\t' '$1 == "w1" && $4 == "nudged" {e = $3} END {print e}' "$STATE_DIR/api-hold-nudged.tsv")
if _api_hold_already_nudged w1 999 "$(date +%s)" "$_last_e"; then pass_=1; else pass_=0; fi
assert_eq "G interval: a marker no newer than the last nudge is satisfied by it (another hold)" "$pass_" 1
if _api_hold_already_nudged w1 999 "$(date +%s)" $(( _last_e + 1 )); then pass_=1; else pass_=0; fi
assert_eq "G interval: a marker NEWER than the last nudge is owed a nudge (another hold)" "$pass_" 0

# EXIT 3, the fail-safe (ncbundle29-sk F2): an orchestrator turn completing
# after entry is recovery for everyone, even with a probe still failing.
reset
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 20 )) server_error "$EAI"
MOCK_PANE="w1|0|$IDLE
w2|0|$IDLE"
touch -d "@$(( now - 600 ))" "$STATE_DIR/orchestrator-heartbeat"
_api_hold_step "$TARGET"
MOCK_PROBE=$'unreachable\tdns'; _api_hold_probe_step; _api_hold_step "$TARGET"
assert_eq "G fail-safe NEG: an orchestrator heartbeat OLDER than entry does not release" "$(held)" held
touch -d "@$(( $(date +%s) + 2 ))" "$STATE_DIR/orchestrator-heartbeat"
_api_hold_step "$TARGET"
assert_eq "G fail-safe: an orchestrator turn completing after entry RELEASES with the probe still failing" "$(held)" released
assert_eq "G fail-safe: …and the crashed workers are nudged" "$(paste -sd, - < "$PASTES")" "w1,w2"

# ════════════════════════════════════════════════════════════════════════════
echo '=== H the probe classifies curl rc as a set, and a node probe sees NODE_OPTIONS ==='
FAKE="$WORK/bin"; mkdir -p "$FAKE"
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FAKE_CURL_OUT:-}" ]] && printf '%s' "$FAKE_CURL_OUT"
exit "${FAKE_CURL_RC:-0}"
EOF
chmod +x "$FAKE/curl"
probe_with() { FAKE_CURL_RC="$1" FAKE_CURL_OUT="${2:-}" PATH="$FAKE:$PATH" _api_hold_probe_curl | cut -f1; }
assert_eq "H rc 0 (any HTTP status) → reachable" "$(probe_with 0 404)" reachable
assert_eq "H rc 6 (could not resolve) → unreachable" "$(probe_with 6)" unreachable
assert_eq "H rc 7 (could not connect) → unreachable" "$(probe_with 7)" unreachable
assert_eq "H rc 28 (timeout) → unreachable" "$(probe_with 28)" unreachable
assert_eq "H NEG rc 3 (malformed URL) → probe-error, not a verdict" "$(probe_with 3)" probe-error
assert_eq "H NEG rc 124 (a wrapper status) → probe-error" "$(probe_with 124)" probe-error
# F2 (ncbundle29-sk): the harness is Node, and the 2026-10-15 fix was a
# Node-only resolver override. A fake `node` answers reachable ONLY when the
# override reaches it through NODE_OPTIONS, so the PLUMBING is what is tested.
cat > "$FAKE/node" <<'EOF'
#!/usr/bin/env bash
if [[ "${NODE_OPTIONS:-}" == *force-dns* ]]; then echo http=404; exit 0; fi
echo err=EAI_AGAIN; exit "${FAKE_NODE_RC:-6}"
EOF
chmod +x "$FAKE/node"
both_with() { FAKE_CURL_RC="$1" PATH="$FAKE:$PATH" _api_hold_probe_both | cut -f1; }
assert_eq "H both: curl dns-fail AND node with no override → unreachable" "$(unset NODE_OPTIONS; both_with 6)" unreachable
assert_eq "H both F2: curl dns-fail BUT node with NODE_OPTIONS=-r force-dns.js → reachable" "$(NODE_OPTIONS='-r /x/force-dns.js' both_with 6)" reachable
assert_eq "H both F2: …or with the probe_node_options knob instead of the env" "$(unset NODE_OPTIONS; MONITOR_API_HOLD_PROBE_NODE_OPTIONS='-r /x/force-dns.js' both_with 6)" reachable
assert_eq "H both NEG: two non-verdicts stay probe-error" "$(unset NODE_OPTIONS; FAKE_NODE_RC=3 both_with 3)" probe-error
# The REAL node, so the inline JS is shown to run: a local server answers, a
# reserved `.invalid` name does not resolve.
_rn=$(PATH="${PATH//$FAKE:/}" command -v node || true)
_port=$(th_alloc_port 18450 2>/dev/null || true)
if [[ -n "$_rn" && -n "$_port" ]]; then
    python3 -m http.server --bind 127.0.0.1 "$_port" >/dev/null 2>&1 &
    _srv=$!
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.3); sys.exit(0 if s.connect_ex(("127.0.0.1",int(sys.argv[1])))==0 else 1)' "$_port" && break
        python3 -c 'import time; time.sleep(0.3)'
    done
    assert_eq "H real node: a local HTTP server → reachable" \
        "$(unset NODE_OPTIONS; MONITOR_API_HOLD_PROBE_URL="http://127.0.0.1:$_port/" MONITOR_API_HOLD_PROBE_TIMEOUT_SECONDS=3 _api_hold_probe_node | cut -f1)" reachable
    assert_eq "H real node: an unresolvable .invalid host → unreachable" \
        "$(unset NODE_OPTIONS; MONITOR_API_HOLD_PROBE_URL="http://api-hold-test.invalid/" MONITOR_API_HOLD_PROBE_TIMEOUT_SECONDS=3 _api_hold_probe_node | cut -f1)" unreachable
    # F2b (skeptic delta verdict, your-org/nexus-code#1847): https.get resolves
    # through dns.lookup (libc getaddrinfo), which IGNORES dns.setServers, so a
    # force-dns.js-style override reaches only dns.resolve*. The stand-in for
    # 2026-10-15 breaks dns.lookup (EAI_AGAIN) and answers dns.resolve4 for a
    # reserved `.invalid` name with 127.0.0.1, the local server. Hermetic on
    # purpose: c-ares does not read /etc/hosts, so `localhost` would depend on
    # real DNS. The probe must answer reachable through the RESOLVE path. The
    # fake `node` above could never show this: it only saw NODE_OPTIONS.
    cat > "$WORK/brokenlibc.js" <<'EOF'
const dns = require("dns");
dns.lookup = (host, opts, cb) => { if (typeof opts === "function") cb = opts;
  const e = new Error("getaddrinfo EAI_AGAIN " + host); e.code = "EAI_AGAIN"; process.nextTick(() => cb(e)); };
dns.resolve4 = (h, cb) => process.nextTick(() => cb(null, ["127.0.0.1"]));
EOF
    cat > "$WORK/brokenboth.js" <<'EOF'
const dns = require("dns");
dns.lookup = (host, opts, cb) => { if (typeof opts === "function") cb = opts;
  const e = new Error("getaddrinfo EAI_AGAIN " + host); e.code = "EAI_AGAIN"; process.nextTick(() => cb(e)); };
dns.resolve4 = (h, cb) => { const e = new Error("queryA ESERVFAIL " + h); e.code = "ESERVFAIL"; process.nextTick(() => cb(e)); };
dns.resolve6 = (h, cb) => { const e = new Error("queryAAAA ESERVFAIL " + h); e.code = "ESERVFAIL"; process.nextTick(() => cb(e)); };
EOF
    _f2b=$(unset NODE_OPTIONS; MONITOR_API_HOLD_PROBE_URL="http://api-hold-test.invalid:$_port/" MONITOR_API_HOLD_PROBE_TIMEOUT_SECONDS=3 \
        MONITOR_API_HOLD_PROBE_NODE_OPTIONS="-r $WORK/brokenlibc.js" _api_hold_probe_node)
    assert_eq "H real node F2b: dns.lookup broken, dns.resolve working → reachable" "${_f2b%%$'\t'*}" reachable
    assert_contains "H real node F2b: …and it answered through the RESOLVE path" "$_f2b" "via=resolve"
    _f2b=$(unset NODE_OPTIONS; MONITOR_API_HOLD_PROBE_URL="http://api-hold-test.invalid:$_port/" MONITOR_API_HOLD_PROBE_TIMEOUT_SECONDS=3 \
        MONITOR_API_HOLD_PROBE_NODE_OPTIONS="-r $WORK/brokenboth.js" _api_hold_probe_node)
    assert_eq "H real node F2b NEG: BOTH resolution paths broken → unreachable" "${_f2b%%$'\t'*}" unreachable
    th_kill_own_child "$_srv" || kill "$_srv" 2>/dev/null
    wait "$_srv" 2>/dev/null
else
    th_skip "H real node: node or a free port unavailable"
    th_skip "H real node: .invalid (same precondition)"
    th_skip "H real node F2b: resolve path (same precondition)"
    th_skip "H real node F2b: via=resolve (same precondition)"
    th_skip "H real node F2b NEG (same precondition)"
fi
reset
plant w1 $(( now - 30 )) server_error "$EAI"
plant w2 $(( now - 20 )) server_error "$EAI"
_api_hold_step "$TARGET"
MOCK_PROBE=$'probe-error\tcurl_rc=3'
_api_hold_probe_step; _api_hold_step "$TARGET"
assert_eq "H NEG a probe-error neither exits nor changes the hold" "$(held)" held

# ════════════════════════════════════════════════════════════════════════════
echo '=== I the hook records prompt_id and its marker classifies transport ==='
reset
payload=$(jq -nc --arg m "$EAI" '{session_id:"s-1",prompt_id:"pid-77",error:"server_error",last_assistant_message:$m,hook_event_name:"StopFailure"}')
NEXUS_WORKER_WINDOW=w5 bash "$MON/hooks/turn-failure-emit.sh" <<<"$payload"
assert_eq "I the marker carries prompt_id" "$(jq -r .prompt_id "$STATE_DIR/turn-failure/w5.json" 2>/dev/null)" pid-77
assert_eq "I …its category axis is unchanged (transient)" "$(jq -r .category "$STATE_DIR/turn-failure/w5.json" 2>/dev/null)" transient
rows=$(_api_hold_scan_markers "$(date +%s)" 0)
assert_contains "I …and the hold's scanner reads it as transport" "$rows" "w5	"

# ════════════════════════════════════════════════════════════════════════════
echo '=== J main.sh wiring ==='
M="$_test_dir/main.sh"
assert_eq "J main.sh sources the module" "$(grep -c '^source "\$_script_dir/_api_hold.sh"' "$M")" 1
# One `elif _api_hold_active` per emit ladder (startup sweep, comment surface,
# compose_emit) plus the decision surface and the held-cache test.
assert_eq "J every emit ladder has the api-hold arm" "$(grep -c 'elif _api_hold_active; then' "$M")" 3
assert_eq "J the decision surface and the held full-state cache hold too" "$(grep -c '_auth_hold_active || _api_hold_active' "$M")" 2
assert_eq "J both scheduler tasks are registered" "$(grep -cE '^_schedule_task api_hold(_probe)? ' "$M")" 2
assert_contains "J the resume pastes through paste_with_retry" "$(grep -n '_api_hold_paste_via_watcher()' "$M")" "paste_with_retry"

# ---- assertion-count guard ------------------------------------------------
# A: 9  B: 13  C: 9  D: 18  E: 3  F: 7  G: 15  H: 16  I: 3  J: 5
EXPECTED=98
if (( PASS + FAIL + SKIP != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL + SKIP ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
