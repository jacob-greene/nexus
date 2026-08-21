#!/usr/bin/env bash
# Tests for the nexus skeptic protocol (skills/nexus.skeptic), PR #285:
#   - monitor/skeptic-channel.sh — the worker↔skeptic comms channel:
#     the WORKER-run await→ack→answer→re-await loop, the DONE sentinel
#     terminal exit (10), atomic-rename race safety, the skeptic-side
#     await-answer / reconcile / close, and the nudge guards (rate-limit,
#     pane-state skip, name→index fail-safe).
#   - monitor/ng `_wrapup_skeptic_step` — wrap-up enforcement: require
#     emits + sets pending; auto presents/records a decision; deny
#     skips; the skeptic role path logs a verdict and applies the
#     bounded-recursion decision (second-pass / escalate / terminate).
#
# The PostToolUse autodetect hook was removed in PR #285 (it only fired
# while the worker issued tool calls, but a worker is idle exactly when a
# skeptic probes its result — the worker-run await loop replaces it).
#
# Run: bash monitor/watcher/test-skeptic-channel.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Hermetic: NEXUS_STATE_DIR points every component at a temp dir; the
# nudge's paste + pane-state helpers are injected via SKEPTIC_PASTE_BIN
# / SKEPTIC_PANESTATE_BIN stubs, so no tmux and no real Claude pane.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
CHAN="$_repo_root/monitor/skeptic-channel.sh"
NG="$_repo_root/monitor/ng"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }
assert_contains() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1" "missing [$3] in <<$2>>"; }
assert_not_contains() { grep -qF -- "$3" <<<"$2" && bad "$1" "unexpected [$3] in <<$2>>" || ok "$1"; }
assert_file()    { [[ -f "$2" ]] && ok "$1" || bad "$1" "missing file $2"; }
assert_nofile()  { [[ ! -e "$2" ]] && ok "$1" || bad "$1" "unexpected file $2"; }

[[ -x "$CHAN" ]] || { echo "missing $CHAN" >&2; exit 1; }
[[ -x "$NG" ]]   || { echo "missing $NG" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/.state"

# ============================================================
echo '=== channel: worker await → ack → answer → re-await lifecycle ==='
# ============================================================
TASK=worker-alpha
"$CHAN" init "$TASK" >/dev/null
p1=$("$CHAN" ask "$TASK" why-lr --message "Why lr=1e-4 when spec says 5e-5?")
assert_contains "ask writes req-001 .open.md" "$p1" "req-001-why-lr.open.md"
assert_file "req-001 file exists" "$p1"
p2=$("$CHAN" ask "$TASK" repro --message "Repro the 0% baseline on a known case.")
assert_contains "ask auto-increments to req-002" "$p2" "req-002-repro.open.md"
assert_eq "status: 2 open" "$("$CHAN" status "$TASK")" "open=2 ack=0 answered=0 total=2 done=0"

# Atomic publish: ask builds a temp then renames; no temp ever matches
# the *.open.md glob the worker acts on (partial-write race guard).
assert_eq "ask leaves no temp visible to the open glob" \
    "$(cd "$(dirname "$p1")" && ls .req-* 2>/dev/null | wc -l | tr -d ' ')" "0"

# WORKER await: acks every open request (rename .open.md → .ack.md),
# prints the ack paths, exits 0. --once = single poll, no blocking.
awk_out=$("$CHAN" await "$TASK" --once); rc=$?
assert_eq "worker await acks open reqs -> exit 0" "$rc" "0"
assert_contains "await acked req-001 (→ .ack.md)" "$awk_out" "req-001-why-lr.ack.md"
assert_contains "await acked req-002 (→ .ack.md)" "$awk_out" "req-002-repro.ack.md"
assert_nofile "open file gone after ack (the rename IS the signal)" "$p1"
assert_eq "status: 2 ack after await" "$("$CHAN" status "$TASK")" "open=0 ack=2 answered=0 total=2 done=0"

# Bug 1: the worker acking via await stamps the machine-input ledger so a
# UserPromptSubmit around the exchange is attributed to the protocol, not
# misread as a fresh operator submit (retire-preflight check 2). The window
# column is the RAW task-id (matches retire-preflight's `$1 == w` lookup).
MI="$NEXUS_STATE_DIR/machine-input.tsv"
assert_contains "await ack stamps machine-input (skeptic-await-ack)" \
    "$(grep -F "$TASK" "$MI" 2>/dev/null)" $'\tskeptic-await-ack'
assert_contains "await ack stamp keyed on the raw task-id window" \
    "$(awk -F'\t' '$1=="'"$TASK"'" && $3=="skeptic-await-ack"' "$MI" 2>/dev/null)" "$TASK"

# Worker answers req 1 by bare number: ack → answered (the rename signal).
ans=$("$CHAN" answer "$TASK" 1 --message "Confirmed config drift; fixed to 5e-5.")
assert_contains "answer renames .ack.md → .answered.md" "$ans" "req-001-why-lr.answered.md"
assert_file "answered file present" "$ans"
assert_contains "answered file carries response" "$(cat "$ans")" "Confirmed config drift"
assert_contains "answered file flips state" "$(cat "$ans")" "state: answered"
assert_eq "status after one answer" "$("$CHAN" status "$TASK")" "open=0 ack=1 answered=1 total=2 done=0"
# Bug 1: answering also stamps the ledger (src skeptic-answer).
assert_contains "answer stamps machine-input (skeptic-answer)" \
    "$(grep -F "$TASK" "$MI" 2>/dev/null)" $'\tskeptic-answer'

# Double-answer is refused (one answer per request).
if "$CHAN" answer "$TASK" 1 --message "again" >/dev/null 2>&1; then
    bad "double-answer refused" "answer of an already-answered req succeeded"
else
    ok "double-answer refused"
fi

# A direct answer of a still-acked req also works (worker answers req-002).
ans2=$("$CHAN" answer "$TASK" 2 --message "Repro confirmed on the toy case.")
assert_contains "answer req-002 → answered" "$ans2" "req-002-repro.answered.md"
assert_eq "status all answered" "$("$CHAN" status "$TASK")" "open=0 ack=0 answered=2 total=2 done=0"

# Skeptic await-answer returns immediately for an already-answered request.
aw=$("$CHAN" await-answer "$TASK" 1 --timeout 2 --interval 1)
assert_contains "await-answer resolves answered req" "$aw" "req-001-why-lr.answered.md"

# --- DONE sentinel: worker await exits with the distinct terminal code 10 ---
"$CHAN" close "$TASK" >/dev/null
assert_file "close drops DONE sentinel" "$NEXUS_STATE_DIR/skeptic/$TASK/DONE"
done_out=$("$CHAN" await "$TASK" --once); rc=$?
assert_eq "await sees DONE -> exit 10 (terminal)" "$rc" "10"
assert_contains "await prints DONE" "$done_out" "DONE"
assert_eq "status reports done=1" "$("$CHAN" status "$TASK")" "open=0 ack=0 answered=2 total=2 done=1"

# --- await re-entry: a fresh open request after a prior ack is picked up ---
DTASK=worker-delta
"$CHAN" ask "$DTASK" later --message "follow-up after the worker re-entered" >/dev/null
"$CHAN" await "$DTASK" --once >/dev/null
assert_eq "re-await acks the new request" "$("$CHAN" status "$DTASK")" "open=0 ack=1 answered=0 total=1 done=0"
# await with NO request and NO DONE times out (exit 4) so the worker re-enters.
ETASK=worker-empty
"$CHAN" init "$ETASK" >/dev/null
"$CHAN" await "$ETASK" --timeout 1 --interval 1 >/dev/null 2>&1
assert_eq "await with nothing pending -> exit 4 (re-enter)" "$?" "4"

# poll on a never-initialised task is silent + rc 0 (no channel yet).
empty=$("$CHAN" poll task-never-seen); rc=$?
assert_eq "poll missing channel -> rc 0" "$rc" "0"
assert_eq "poll missing channel -> empty" "$empty" ""

# ============================================================
echo '=== Bug 2: close clears the skeptic-pending marker (worker idle) ==='
# ============================================================
# When the skeptic closes the channel its verdict exists, so the
# require-gate is satisfied. Marker clearance must NOT depend on the
# worker still being live in its await loop: a stalled/idled worker (no
# await running here — we never call `await`) would otherwise keep the
# marker forever and show `parked-awaiting-skeptic` indefinitely, even
# after its PR merged. close must remove it unconditionally.
CTASK=worker-closemark
CPEND="$NEXUS_STATE_DIR/skeptic/pending/$CTASK"
mkdir -p "$NEXUS_STATE_DIR/skeptic/pending"
echo 1 > "$CPEND"                      # ng wrap-up's require gate set this
assert_file "close: pending marker present before close" "$CPEND"
"$CHAN" close "$CTASK" >/dev/null      # worker is NOT in an await loop
assert_file "close still drops DONE sentinel" "$NEXUS_STATE_DIR/skeptic/$CTASK/DONE"
assert_nofile "close clears the pending marker (worker idle)" "$CPEND"
# Idempotent: closing again with no marker is harmless.
"$CHAN" close "$CTASK" >/dev/null
assert_nofile "second close keeps marker cleared" "$CPEND"

# ============================================================
echo '=== skeptic reconcile: ack gate + bounded fail-loud ==='
# ============================================================
# All requests acked/answered → reconcile returns 0 promptly.
RTASK=worker-recon
"$CHAN" ask "$RTASK" q1 --message "q1" >/dev/null
"$CHAN" await "$RTASK" --once >/dev/null         # acks q1
"$CHAN" reconcile "$RTASK" --interval 1 --max-iter 2 --no-nudge >/dev/null 2>&1
assert_eq "reconcile all-acked -> rc 0" "$?" "0"
# A still-open (never-acked) request → reconcile fails loud (exit 6).
"$CHAN" ask "$RTASK" q2 --message "q2 never acked" >/dev/null
recon_err=$("$CHAN" reconcile "$RTASK" --interval 1 --max-iter 2 --no-nudge 2>&1); rc=$?
assert_eq "reconcile un-acked -> rc 6 (fail loud)" "$rc" "6"
assert_contains "reconcile names the un-acked request" "$recon_err" "req-002-q2.open.md"

# ============================================================
echo '=== nudge: guards (no-open / rate-limit / busy / paste) ==='
# ============================================================
# Stub paste + pane-state.
PASTE_LOG="$WORK/paste.log"
PANEARG_LOG="$WORK/panearg.log"
cat > "$WORK/paste-stub.sh" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$PASTE_LOG"
exit 0
STUB
chmod +x "$WORK/paste-stub.sh"
# The pane-state stub ENFORCES the F1 contract: cmd_nudge must hand it a
# window INDEX (digits, or session:idx) — never the window NAME, because
# pane-state.sh is index-keyed and a name leaking through silently
# disables the busy/user-typing guard. The stub logs the token it
# received and, when handed a non-index (the pre-fix bug), emits a
# `name-leaked` sentinel state matching NO skip case — so the busy-skip
# assertions below go RED on a revert of the name→index fix (the
# mutation the skeptic required a test to catch).
mk_panestate() { # $1 = state value to emit when the arg IS index-shaped
    cat > "$WORK/panestate-stub.sh" <<STUB
#!/usr/bin/env bash
arg="\$1"
printf '%s\n' "\$arg" >> "$PANEARG_LOG"
if [[ ! "\$arg" =~ ^([0-9]+|[^:]+:[0-9]+)\$ ]]; then
    echo "state=name-leaked active=0"
    exit 0
fi
echo "state=$1 active=0"
exit 0
STUB
    chmod +x "$WORK/panestate-stub.sh"
}
export SKEPTIC_PASTE_BIN="$WORK/paste-stub.sh"
export SKEPTIC_PANESTATE_BIN="$WORK/panestate-stub.sh"
# Test seam: inject the name→index resolution (the hermetic suite has no
# live tmux window matching the synthetic task name).
export SKEPTIC_WINDOW_INDEX=7

# No open requests → nudge is a no-op (rc 0), no paste.
NTASK=worker-nudge
"$CHAN" init "$NTASK" >/dev/null
: > "$PASTE_LOG"
"$CHAN" nudge "$NTASK" >/dev/null 2>&1
assert_eq "nudge with no open reqs -> rc 0" "$?" "0"
assert_eq "nudge with no open reqs -> no paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"

"$CHAN" ask "$NTASK" challenge --message "defend this claim" >/dev/null
# Busy pane → skip (rc 5), no paste. Doubles as the F1 mutation catcher:
# revert the name→index fix and the stub sees the NAME → `name-leaked` →
# no skip → these two go red.
mk_panestate busy
: > "$PASTE_LOG"; : > "$PANEARG_LOG"
"$CHAN" nudge "$NTASK" >/dev/null 2>&1
assert_eq "nudge to busy pane -> rc 5 (skip)" "$?" "5"
assert_eq "nudge to busy pane -> no paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"
# The guard handed pane-state.sh an INDEX, not the window name (F1).
assert_eq "nudge passes an index to pane-state (F1 contract)" \
    "$(tail -1 "$PANEARG_LOG")" "7"
# Bug A: a busy-skipped nudge STAMPS machine-input so the worker's
# protocol pane-churn (under load) is machine-attributed, not mis-seeded
# as a false operator-engaged mark. Delivery is deferred, attribution is
# not.
assert_contains "busy-skip nudge stamps machine-input (skeptic-nudge-busy-skip)" \
    "$(grep -F "$NTASK" "$NEXUS_STATE_DIR/machine-input.tsv" 2>/dev/null)" \
    $'\tskeptic-nudge-busy-skip'

# Bug A guard: a USER-TYPING pane is the OPERATOR — skip WITHOUT a stamp
# (a stamp here would mask the operator's own submit → false NEGATIVE).
UTTASK=worker-usertyping
"$CHAN" init "$UTTASK" >/dev/null
"$CHAN" ask "$UTTASK" q --message "open q" >/dev/null
mk_panestate user-typing
: > "$PASTE_LOG"
"$CHAN" nudge "$UTTASK" >/dev/null 2>&1
assert_eq "user-typing pane -> rc 5 (skip)" "$?" "5"
assert_eq "user-typing pane -> no paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"
assert_not_contains "user-typing pane -> NO machine-input stamp (operator must register)" \
    "$(grep -F "$UTTASK" "$NEXUS_STATE_DIR/machine-input.tsv" 2>/dev/null)" \
    "$UTTASK"

# Idle pane → paste fires (rc 0).
mk_panestate idle
: > "$PASTE_LOG"; : > "$PANEARG_LOG"
out=$("$CHAN" nudge "$NTASK" 2>&1); rc=$?
assert_eq "nudge to idle pane -> rc 0" "$rc" "0"
assert_eq "nudge to idle pane -> one paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "1"
assert_contains "paste carries await instruction" "$(cat "$PASTE_LOG")" "skeptic-channel.sh await"

# Immediately again → rate-limited (rc 5), no second paste.
"$CHAN" nudge "$NTASK" >/dev/null 2>&1
assert_eq "second nudge within interval -> rc 5 (rate-limited)" "$?" "5"
assert_eq "rate-limited nudge -> still one paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "1"

# --force overrides the rate-limit (and bypasses the pane-state guard).
"$CHAN" nudge "$NTASK" --force >/dev/null 2>&1
assert_eq "forced nudge -> rc 0" "$?" "0"
assert_eq "forced nudge -> second paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "2"

# Fail-safe: when the window index can't be resolved (no seam, no live
# tmux window of that name) the guard SKIPS rather than pasting blind.
unset SKEPTIC_WINDOW_INDEX
URTASK="unresolvable-nudge-$$"
"$CHAN" init "$URTASK" >/dev/null
"$CHAN" ask "$URTASK" q --message "open q" >/dev/null
mk_panestate idle
: > "$PASTE_LOG"
"$CHAN" nudge "$URTASK" >/dev/null 2>&1
assert_eq "unresolvable window -> rc 5 (fail-safe skip)" "$?" "5"
assert_eq "unresolvable window -> no paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"

# ============================================================
echo '=== reconcile drives the nudge (guards honoured) ==='
# ============================================================
# reconcile nudges a worker that left a request un-acked. It reuses
# cmd_nudge, so the SAME guards apply: a busy/user-typing pane is never
# steamrolled; an idle pane is woken.
export SKEPTIC_WINDOW_INDEX=7
RNTASK=worker-recon-nudge
"$CHAN" init "$RNTASK" >/dev/null
"$CHAN" ask "$RNTASK" still-open --message "never acked" >/dev/null

# Busy pane → reconcile's nudge is skipped (no paste), and reconcile
# still fails loud (exit 6) since the request stays un-acked.
mk_panestate busy
: > "$PASTE_LOG"
"$CHAN" reconcile "$RNTASK" --grace 0 --interval 1 --max-iter 1 >/dev/null 2>&1
assert_eq "reconcile: busy pane NOT steamrolled (no paste)" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"

# Idle pane → reconcile's nudge fires a paste (worker woken). Fresh
# RNTASK2 so the per-window rate-limit stamp from earlier doesn't apply.
mk_panestate idle
RNTASK2=worker-recon-nudge2
"$CHAN" init "$RNTASK2" >/dev/null
"$CHAN" ask "$RNTASK2" still-open --message "never acked" >/dev/null
: > "$PASTE_LOG"
"$CHAN" reconcile "$RNTASK2" --grace 0 --interval 1 --max-iter 1 >/dev/null 2>&1
assert_eq "reconcile: idle pane nudged (one paste)" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "1"

unset SKEPTIC_WINDOW_INDEX SKEPTIC_PASTE_BIN SKEPTIC_PANESTATE_BIN

# ============================================================
echo '=== wrap-up skeptic step: require / auto / deny / role ==='
# ============================================================
# The operator-context waive (F3) must run with NO NEXUS_WORKER_WINDOW —
# a worker cannot self-waive. Unset any inherited value (this suite may
# run inside a worker session whose window name is exported) so the
# operator-context assertions exercise the operator path, not the
# worker-refusal path.
unset NEXUS_WORKER_WINDOW
# Source ng (guarded main) to exercise the internal helper directly.
# shellcheck disable=SC1090
source "$NG"
PEND="$NEXUS_STATE_DIR/skeptic/pending"

# Helper to write a provenance record for a window.
mk_prov() { # window mode depth role target [orig]
    local d="$NEXUS_STATE_DIR/windows"; mkdir -p "$d"
    jq -n --arg w "$1" --arg m "$2" --argjson dp "$3" \
          --argjson r "$4" --arg t "$5" --arg o "${6:-}" \
        '{window:$w, skeptic_mode:$m, skeptic_depth:$dp, skeptic_role:$r, skeptic_target:$t, skeptic_orig:$o}' \
        > "$d/${1//[^a-zA-Z0-9_-]/_}.json"
}

# --- require: emits SKEPTIC REQUIRED + sets pending marker ---
mk_prov w-req require 0 false ""
out=$(_wrapup_skeptic_step 42 w-req your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "require -> rc 0" "$rc" "0"
assert_contains "require -> emits SKEPTIC REQUIRED" "$out" "SKEPTIC REQUIRED"
assert_contains "require -> CONSEQUENCE line" "$out" "CONSEQUENCE: a skeptic MUST validate"
assert_contains "require -> emits spawn cmd at depth 1" "$out" "--skeptic-depth 1"
assert_not_contains "require -> first skeptic spawn cmd is non-recursive (no --skeptic-orig)" "$out" "--skeptic-orig"
assert_file "require -> pending marker set" "$PEND/w-req"

# --- require + --skeptic-decision deny is REFUSED ---
_wrapup_skeptic_step 42 w-req your-org/your-nexus 0 deny "trivial" "" "" "" "" "" >/dev/null 2>&1
assert_eq "require + decision deny -> rc 1 (refused)" "$?" "1"

# --- require waived by operator clears the marker ---
out=$(_wrapup_skeptic_step 42 w-req your-org/your-nexus 0 "" "" "operator says fine" "" "" "" ""); rc=$?
assert_eq "waive -> rc 0" "$rc" "0"
assert_contains "waive -> WAIVED block" "$out" "WAIVED"
assert_nofile "waive -> pending marker cleared" "$PEND/w-req"

# --- F3: waive is REFUSED from a worker context (operator-only) ---
# A spawned worker runs with NEXUS_WORKER_WINDOW exported; the operator
# session does not. The waive must be refused in worker context and the
# pending marker must survive — a worker cannot self-waive.
mk_prov w-req2 require 0 false ""
_wrapup_skeptic_step 42 w-req2 your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1  # set the marker
assert_file "F3 setup -> pending marker set" "$PEND/w-req2"
NEXUS_WORKER_WINDOW=w-req2 _wrapup_skeptic_step 42 w-req2 your-org/your-nexus 0 "" "" "worker self-waive" "" "" "" "" >/dev/null 2>&1
assert_eq "F3 waive from worker context -> rc 1 (refused)" "$?" "1"
assert_file "F3 waive refused -> pending marker survives" "$PEND/w-req2"
# The SAME waive from operator context (no NEXUS_WORKER_WINDOW) succeeds.
out=$(_wrapup_skeptic_step 42 w-req2 your-org/your-nexus 0 "" "" "operator override" "" "" "" ""); rc=$?
assert_eq "F3 waive from operator context -> rc 0" "$rc" "0"
assert_nofile "F3 operator waive -> pending marker cleared" "$PEND/w-req2"

# --- deny at spawn: skips, no marker ---
mk_prov w-deny deny 0 false ""
out=$(_wrapup_skeptic_step 7 w-deny your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "deny -> rc 0" "$rc" "0"
assert_contains "deny -> DENIED AT SPAWN" "$out" "DENIED AT SPAWN"
assert_contains "deny -> CONSEQUENCE line" "$out" "CONSEQUENCE: skeptic was waived at spawn"
assert_nofile "deny -> no pending marker" "$PEND/w-deny"

# --- auto, no decision: ENFORCED BY DEFAULT (rc 1), prints heuristic +
#     consequence. enforce_auto_decision now defaults true, so an
#     undecided auto wrap-up FAILS. Revert the code default to false and
#     this goes red (config does not define the key, so the code default
#     is authoritative here). ---
mk_prov w-auto auto 0 false ""
out=$(_wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "auto undecided (default enforce on) -> rc 1" "$rc" "1"
assert_contains "auto undecided -> DECISION REQUIRED" "$out" "SKEPTIC DECISION REQUIRED"
assert_contains "auto undecided -> CONSEQUENCE line" "$out" "CONSEQUENCE: you must record a skeptic decision"
assert_contains "auto undecided -> shows heuristic" "$out" "blast radius"

# --- auto, enforce explicitly OFF via env: advisory (rc 0). The env
#     override must win over the (now true) default. ---
out=$(MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 _wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "auto undecided + enforce off (env) -> rc 0 (advisory)" "$rc" "0"

# --- auto, enforce explicitly on via env: rc 1 ---
out=$(MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=1 _wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "auto undecided + enforce on (env) -> rc 1" "$rc" "1"

# --- auto + decision require but NO rationale: rc 1 ---
_wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 require "" "" "" "" "" "" >/dev/null 2>&1
assert_eq "auto require w/o rationale -> rc 1" "$?" "1"

# --- auto + decision require WITH rationale: sets marker ---
out=$(_wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 require "touched shared infra" "" "" "" "" ""); rc=$?
assert_eq "auto require w/ rationale -> rc 0" "$rc" "0"
assert_contains "auto require -> SKEPTIC REQUIRED" "$out" "SKEPTIC REQUIRED"
assert_file "auto require -> pending marker" "$PEND/w-auto"

# --- auto + decision deny WITH rationale: skips ---
mk_prov w-auto2 auto 0 false ""
out=$(_wrapup_skeptic_step 9 w-auto2 your-org/your-nexus 0 deny "one-line doc typo" "" "" "" "" ""); rc=$?
assert_eq "auto deny w/ rationale -> rc 0" "$rc" "0"
assert_contains "auto deny -> NOT WARRANTED" "$out" "NOT WARRANTED"
assert_nofile "auto deny -> no marker" "$PEND/w-auto2"

# ============================================================
echo '=== wrap-up role path: verdict + bounded recursion ==='
# ============================================================
# Pre-set a pending marker for the reviewed window; the skeptic's
# verdict should clear it.
mkdir -p "$PEND"; echo 1 > "$PEND/orig-task"

# clean verdict (credible, 0 findings) at depth 1 -> terminates, clears marker.
out=$(_wrapup_skeptic_step 50 sk-w1 your-org/your-nexus 1 "" "" "" credible orig-task 1 0); rc=$?
assert_eq "role credible -> rc 0" "$rc" "0"
assert_contains "role credible -> TERMINATES" "$out" "TERMINATES"
assert_nofile "role verdict clears reviewed marker" "$PEND/orig-task"

# suspect verdict at depth 1 -> second pass recommended at depth 2.
out=$(_wrapup_skeptic_step 50 sk-w2 your-org/your-nexus 1 "" "" "" suspect orig-task 1 0); rc=$?
assert_eq "role suspect depth1 -> rc 0" "$rc" "0"
assert_contains "role suspect -> SECOND-PASS" "$out" "SECOND-PASS SKEPTIC RECOMMENDED"
assert_contains "role suspect -> next depth 2" "$out" "--skeptic-depth 2"

# suspect verdict AT the cap -> escalate, no further spawn. Pin the cap
# explicitly (cap=2 via env) so the at-cap behaviour is asserted
# generically, independent of the default value.
out=$(MONITOR_SKEPTIC_MAX_DEPTH=2 _wrapup_skeptic_step 50 sk-w3 your-org/your-nexus 1 "" "" "" suspect orig-task 2 3); rc=$?
assert_eq "role suspect at cap (cap=2) -> rc 0" "$rc" "0"
assert_contains "role suspect at cap -> ESCALATE" "$out" "MAX SKEPTIC DEPTH REACHED"

# (c) DEFAULT CAP IS NOW 3. A suspect at depth 2 is BELOW the cap, so it
# recommends a second pass at depth 3 (NOT escalate). Revert max_depth to
# 2 and this goes red — depth 2 would hit the cap and escalate. Config
# does not define the key, so the code default is authoritative here.
out=$(_wrapup_skeptic_step 50 sk-w3b your-org/your-nexus 1 "" "" "" suspect orig-task 2 0); rc=$?
assert_contains "default cap 3: suspect depth2 -> SECOND-PASS (not escalate)" "$out" "SECOND-PASS SKEPTIC RECOMMENDED"
assert_contains "default cap 3: suspect depth2 -> next depth 3" "$out" "--skeptic-depth 3"
# And AT the new default cap (depth 3) the chain terminates by escalating
# — the termination guarantee holds generically at the configured max.
out=$(_wrapup_skeptic_step 50 sk-w3c your-org/your-nexus 1 "" "" "" suspect orig-task 3 0); rc=$?
assert_contains "default cap 3: suspect depth3 (at cap) -> ESCALATE" "$out" "MAX SKEPTIC DEPTH REACHED"

# credible but many findings (>= threshold) -> still a second pass.
out=$(_wrapup_skeptic_step 50 sk-w4 your-org/your-nexus 1 "" "" "" credible orig-task 0 3); rc=$?
assert_contains "role credible w/ findings -> SECOND-PASS" "$out" "SECOND-PASS SKEPTIC RECOMMENDED"

# --- F4: a 0-threshold is floored to 1 — a clean 0-findings credible
#     pass TERMINATES (does not recommend a second pass). Without the
#     floor, findings(0) >= thresh(0) would be true and recurse.
out=$(MONITOR_SKEPTIC_FINDINGS_THRESHOLD=0 _wrapup_skeptic_step 50 sk-w6 your-org/your-nexus 1 "" "" "" credible orig-task 1 0); rc=$?
assert_eq "F4 thresh=0 clean pass -> rc 0" "$rc" "0"
assert_contains "F4 thresh=0 clean pass -> TERMINATES (floored)" "$out" "TERMINATES"

# role without verdict -> rc 1.
_wrapup_skeptic_step 50 sk-w5 your-org/your-nexus 1 "" "" "" "" orig-task 1 0 >/dev/null 2>&1
assert_eq "role without verdict -> rc 1" "$?" "1"

# ============================================================
echo '=== Change 2: recursive skeptic sees the WHOLE chain + breaks ties ==='
# ============================================================
# A RECURSIVE (second-or-later) skeptic reviewing the prior skeptic
# `sk-w1` with chain-root `orig-task`. Markers: both reviewed (sk-w1)
# and original (orig-task) live before the verdict; self is sk-w2.
#
# A returned verdict satisfies the require-gate, so the verdict path now
# clears ALL chain markers (reviewed + orig + self) regardless of whether a
# second pass is RECOMMENDED. The block for a genuinely-spawned second pass
# is RE-established by spawn-worker.sh at that spawn — never speculatively
# here (that speculative re-assertion was the marker LEAK: a declined
# recommendation stranded the markers and wedged retire-preflight forever).
mkdir -p "$PEND"; echo 1 > "$PEND/sk-w1"; echo 1 > "$PEND/orig-task"
out=$(_wrapup_skeptic_step 50 sk-w2 your-org/your-nexus 1 "" "" "" suspect sk-w1 2 0 orig-task); rc=$?
assert_eq        "recursive suspect depth2 -> rc 0"                 "$rc" "0"
assert_contains  "recursive -> SECOND-PASS at depth 3"             "$out" "--skeptic-depth 3"
assert_contains  "recursive -> spawn cmd threads --skeptic-orig"   "$out" "--skeptic-orig orig-task"
assert_contains  "recursive -> reviews the WHOLE chain"            "$out" "WHOLE chain"
assert_contains  "recursive -> names the original worker"          "$out" "original worker \`orig-task\`"
assert_contains  "recursive -> ADJUDICATE / break the tie"         "$out" "ADJUDICATE"
assert_contains  "recursive -> prior skeptic enters await on self" "$out" "await sk-w2"
assert_contains  "recursive -> do NOT close the original channel"  "$out" "do NOT close the original worker"
assert_nofile    "recursive -> self (sk-w2) marker cleared on verdict (no leak)" "$PEND/sk-w2"
assert_nofile    "recursive -> ORIGINAL worker marker cleared on verdict (no leak)" "$PEND/orig-task"
assert_nofile    "recursive -> reviewed prior skeptic released"    "$PEND/sk-w1"

# First skeptic recommending a second pass: it reviewed orig-task2
# directly (reviewed == orig == orig-task2), but the NEXT skeptic's target
# is THIS skeptic (sk-first) — distinct from the original — so the emitted
# spawn cmd is recursive and threads --skeptic-orig orig-task2. Both the
# original's and the skeptic's own markers are CLEARED on the verdict (the
# recommendation alone leaves nothing parked; spawn-worker.sh re-stamps the
# block iff the orchestrator actually spawns the next skeptic).
mkdir -p "$PEND"; echo 1 > "$PEND/orig-task2"
out=$(_wrapup_skeptic_step 50 sk-first your-org/your-nexus 1 "" "" "" suspect orig-task2 1 0); rc=$?
assert_eq        "first-skeptic suspect -> rc 0"                   "$rc" "0"
assert_contains  "first-skeptic -> SECOND-PASS at depth 2"         "$out" "--skeptic-depth 2"
assert_contains  "first-skeptic -> threads original as --skeptic-orig" "$out" "--skeptic-orig orig-task2"
assert_nofile    "first-skeptic -> original marker cleared on verdict (no leak)" "$PEND/orig-task2"
assert_nofile    "first-skeptic -> self marker cleared on verdict (no leak)" "$PEND/sk-first"

# Chain TERMINATION (clean verdict) releases BOTH the reviewed window and
# the original worker.
mkdir -p "$PEND"; echo 1 > "$PEND/sk-w1b"; echo 1 > "$PEND/orig-taskb"
out=$(_wrapup_skeptic_step 50 sk-w2b your-org/your-nexus 1 "" "" "" credible sk-w1b 2 0 orig-taskb); rc=$?
assert_contains  "termination -> TERMINATES"                       "$out" "TERMINATES"
assert_nofile    "termination -> reviewed released"                "$PEND/sk-w1b"
assert_nofile    "termination -> ORIGINAL worker released"         "$PEND/orig-taskb"

# Escalation AT the cap also releases the original worker (chain over).
mkdir -p "$PEND"; echo 1 > "$PEND/orig-taskc"
out=$(MONITOR_SKEPTIC_MAX_DEPTH=2 _wrapup_skeptic_step 50 sk-w2c your-org/your-nexus 1 "" "" "" suspect sk-w1c 2 3 orig-taskc); rc=$?
assert_contains  "escalate-at-cap -> MAX DEPTH"                    "$out" "MAX SKEPTIC DEPTH REACHED"
assert_nofile    "escalate-at-cap -> ORIGINAL worker released"     "$PEND/orig-taskc"

# ============================================================
echo '=== LEAK regression: substantive-minor verdict + close → NO manual rm ==='
# ============================================================
# The bug: a `check`/substantive-but-minor verdict (findings>=1) RECOMMENDS
# a second pass. The OLD verdict path then speculatively parked the skeptic's
# OWN marker AND re-asserted the target's. When the orchestrator declined the
# (merely recommended) second pass, nothing cleared them → retire-preflight
# reported safe=0 on a DONE skeptic and its target forever, until a hand `rm`.
#
# Three cases, end-to-end, with NO manual rm anywhere:
#   (a) require gate sets the target marker (preflight WOULD block — safe=0).
#   (b) skeptic returns a `check` verdict (findings>=1, second pass merely
#       RECOMMENDED) → BOTH the target's and the skeptic's OWN markers are
#       gone, and a follow-up `close` is idempotent (no resurrection).
#   (c) a genuinely-pending skeptic (require set, NO verdict yet) keeps the
#       target marker live — the safety still has teeth.

# (a) require gate writes the target marker (the block that retire-preflight
#     check 1b honours; see test-retire-preflight.sh 9b for the safe=0 read).
mk_prov leak-target require 0 false ""
_wrapup_skeptic_step 70 leak-target your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null
assert_file   "(a) require gate -> target marker live (would block retire)" "$PEND/leak-target"

# Simulate the orchestrator spawning the skeptic: it (re-)stamps the target
# marker (spawn-worker.sh does this in production — covered by
# test-spawn-worker.sh). The skeptic's OWN window is leak-target-skeptic.
echo 0 > "$PEND/leak-target"            # spawn re-stamp (idempotent here)

# (b) the skeptic returns a `check` verdict with findings=2 (substantive →
#     a second pass is RECOMMENDED) at depth 0. Verdict path must clear BOTH
#     the reviewed target AND the skeptic's own marker — no leak, no rm.
out=$(_wrapup_skeptic_step 70 leak-target-skeptic your-org/your-nexus 1 "" "" "" check leak-target 0 2); rc=$?
assert_eq     "(b) check verdict -> rc 0"                          "$rc" "0"
assert_contains "(b) check w/ findings -> SECOND-PASS recommended" "$out" "SECOND-PASS SKEPTIC RECOMMENDED"
assert_nofile "(b) check verdict clears the TARGET marker (no rm)" "$PEND/leak-target"
assert_nofile "(b) check verdict clears the SKEPTIC's OWN marker (no rm)" "$PEND/leak-target-skeptic"

# (b cont.) the orchestrator declines the second pass and closes the chain;
# close is idempotent and must not resurrect either marker.
"$CHAN" close leak-target >/dev/null
assert_nofile "(b) close after verdict keeps TARGET marker cleared"     "$PEND/leak-target"
assert_nofile "(b) close after verdict keeps SKEPTIC's OWN marker cleared" "$PEND/leak-target-skeptic"

# (c) NEGATIVE CONTROL: a still-pending skeptic (require set, verdict NOT yet
#     returned) MUST keep the marker live — over-clearing would break the
#     gate. No verdict call here, so the marker persists.
mk_prov leak-pending require 0 false ""
_wrapup_skeptic_step 71 leak-pending your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null
assert_file   "(c) still-pending skeptic -> target marker stays live (gate has teeth)" "$PEND/leak-pending"

# ============================================================
echo '=== provenance reader: defaults + parse ==='
# ============================================================
prov=$(_skeptic_provenance ""); assert_eq "empty window -> default prov" "$prov" $'auto\t0\tfalse\t\t'
mk_prov w-pp require 2 false ""
prov=$(_skeptic_provenance w-pp); assert_eq "reads mode+depth" "$prov" $'require\t2\tfalse\t\t'
# orig field threads through provenance (Change 2): a recursive skeptic
# records the chain root so its wrap-up can target the whole chain.
mk_prov w-pp2 require 2 true sk-prior orig-task
prov=$(_skeptic_provenance w-pp2); assert_eq "reads orig (chain root)" "$prov" $'require\t2\ttrue\tsk-prior\torig-task'

# ============================================================
echo '=== await heartbeat: touch -c, never CREATES an absent pending marker ==='
# ============================================================
# Regression for the TOCTOU the heartbeat would otherwise lose: the
# verdict's `rm -f` of the skeptic-pending marker can land while the worker
# is still in `await` (the skeptic's close/DONE comes only AFTER the rm).
# A plain `touch` would recreate the just-cleared marker, and since
# retire-preflight check 1b tests existence (not mtime) that would strand
# the worker un-retireable. `touch -c` makes the heartbeat a no-op on an
# absent marker. Validated through the public `await --once` path, which
# calls _await_heartbeat exactly once per poll.
HBTASK="hb-nocreate-$$"
hb_marker="$NEXUS_STATE_DIR/skeptic/pending/$HBTASK"
rm -f "$hb_marker"
"$CHAN" await "$HBTASK" --once >/dev/null 2>&1
assert_nofile "await heartbeat does NOT create an absent pending marker (touch -c)" "$hb_marker"
# Positive: an EXISTING marker survives the heartbeat — the parked worker
# stays gated (the heartbeat refreshes, never removes).
mkdir -p "$(dirname "$hb_marker")"; printf '1' > "$hb_marker"
"$CHAN" await "$HBTASK" --once >/dev/null 2>&1
assert_file "await heartbeat preserves an existing pending marker" "$hb_marker"
rm -f "$hb_marker"

# ============================================================
echo '=== #469: skeptic gate must not fail OPEN on a re-wrap (stale DONE) ==='
# ============================================================
# A channel is reused across rounds. Round 1's `close` leaves a DONE
# sentinel; a later `ng wrap-up --skeptic-decision require` opens round 2
# by writing a fresh pending marker. If the stale DONE survives, the
# worker's next `await` returns exit 10 instantly and it retires believing
# an independent skeptic validated it — when none ever spawned.
#
# BOTH DIRECTIONS. Every assertion below FAILS on pre-fix source:
#   - guard 2 (await): pre-fix returns 10 on a stale DONE.
#   - guard 1 (wrap-up): pre-fix leaves the stale DONE in place.
# Reproduce the pre-fix failures with:
#   git stash push monitor/skeptic-channel.sh monitor/ng \
#     && bash monitor/watcher/test-skeptic-channel.sh; git stash pop

# Helpers: age a file into the past so the mtime ordering is unambiguous
# regardless of the filesystem's timestamp granularity.
age_file() { touch -d "@$(( $(date +%s) - ${2:-60} ))" "$1"; }

STASK="w469-restale"
sdir="$NEXUS_STATE_DIR/skeptic/$STASK"
smark="$NEXUS_STATE_DIR/skeptic/pending/$STASK"
mkdir -p "$sdir" "$NEXUS_STATE_DIR/skeptic/pending"

# --- guard 2: await refuses a DONE older than the pending marker ---
# Round 1 closed 60s ago; round 2's require-gate marker is fresh.
#
# The marker is written DIRECTLY here, not through `ng wrap-up`. That is
# deliberate: it is the exact shape spawn-worker.sh (~:1457) produces when
# the orchestrator spawns a skeptic itself — a fresh pending marker, no
# wrap-up, no DONE reset. Guard 1 cannot see that path. This section is
# therefore the ONLY coverage of it, and it is why guard 2 is not
# redundant with guard 1.
printf 'round-1 verdict\n' > "$sdir/DONE"; age_file "$sdir/DONE" 60
printf '1' > "$smark"                                   # fresh: mtime = now
out=$("$CHAN" await "$STASK" --once 2>&1); rc=$?
[[ "$rc" != 10 ]] && ok "stale DONE + newer marker -> await does NOT exit 10 (gate stays closed)" \
                  || bad "stale DONE + newer marker -> await does NOT exit 10 (gate stays closed)" \
                         "got rc=10: pre-fix behaviour, the worker would retire unvalidated"
assert_eq "stale DONE -> await returns 4 (re-enter, nothing pending)" "$rc" "4"
assert_contains "stale DONE -> await says so on stderr" "$out" "older than its pending marker"

# The blocking (non---once) path must also refuse it, not exit 10 at once.
out=$("$CHAN" await "$STASK" --timeout 1 --interval 1 2>&1); rc=$?
assert_eq "stale DONE -> blocking await times out (4), never 10" "$rc" "4"

# The marker must survive: the worker is still gated for retire-preflight.
assert_file "stale DONE -> pending marker survives await" "$smark"

# --- guard 2, other direction: a GENUINE round-2 close does release ---
# `close` writes a fresh DONE and removes the marker; await must exit 10.
"$CHAN" close "$STASK" >/dev/null
assert_nofile "round-2 close clears the pending marker" "$smark"
out=$("$CHAN" await "$STASK" --once); rc=$?
assert_eq "round-2 close -> await exits 10 (terminal)" "$rc" "10"
assert_contains "round-2 close -> await prints DONE" "$out" "DONE"

# --- no regression: first-round DONE with NO marker is still terminal ---
# `-nt` is true when the sentinel exists and the marker does not, so the
# ordinary single-round path is untouched.
NTASK="w469-firstround"
mkdir -p "$NEXUS_STATE_DIR/skeptic/$NTASK"
"$CHAN" close "$NTASK" >/dev/null
rm -f "$NEXUS_STATE_DIR/skeptic/pending/$NTASK"
"$CHAN" await "$NTASK" --once >/dev/null; rc=$?
assert_eq "first-round DONE, no marker -> await still exits 10" "$rc" "10"

# --- and a DONE NEWER than a leftover marker is terminal (fail-safe) ---
# If close published DONE but its marker unlink lost, the round is still
# over. Terminal, not a hang.
LTASK="w469-leftover"
mkdir -p "$NEXUS_STATE_DIR/skeptic/$LTASK"
"$CHAN" close "$LTASK" >/dev/null                       # DONE = now, unlinks marker
printf '1' > "$NEXUS_STATE_DIR/skeptic/pending/$LTASK"  # simulate a lost unlink
age_file "$NEXUS_STATE_DIR/skeptic/pending/$LTASK" 60   # ...predating the close
"$CHAN" await "$LTASK" --once >/dev/null; rc=$?
assert_eq "DONE newer than a leftover marker -> terminal (10), not a hang" "$rc" "10"

# --- guard 1: wrap-up --skeptic-decision require CLEARS a prior DONE ---
# `_wrapup_skeptic_step` is sourced from ng above. A require decision opens
# a new round, so the previous round's sentinel must not survive it.
RTASK=w469-rewrap
mk_prov "$RTASK" require 0 false ""
mkdir -p "$NEXUS_STATE_DIR/skeptic/$RTASK"
printf 'round-1 verdict\n' > "$NEXUS_STATE_DIR/skeptic/$RTASK/DONE"
age_file "$NEXUS_STATE_DIR/skeptic/$RTASK/DONE" 60
_wrapup_skeptic_step 469 "$RTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
assert_nofile "wrap-up require -> clears the prior round's DONE" "$NEXUS_STATE_DIR/skeptic/$RTASK/DONE"
assert_file   "wrap-up require -> writes a fresh pending marker" "$PEND/$RTASK"
# End-to-end: after the re-wrap the worker's await must BLOCK, not retire.
"$CHAN" await "$RTASK" --once >/dev/null 2>&1; rc=$?
assert_eq "re-wrap -> await no longer terminal (gate held)" "$rc" "4"

# --- no regression: a first-round require on a virgin channel still works ---
VTASK=w469-virgin
mk_prov "$VTASK" require 0 false ""
_wrapup_skeptic_step 469 "$VTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
assert_file   "first-round require -> pending marker set" "$PEND/$VTASK"
assert_nofile "first-round require -> no DONE conjured" "$NEXUS_STATE_DIR/skeptic/$VTASK/DONE"

# ============================================================
echo
echo '=== #511: reset ARCHIVES stale sentinels (not bare-rm), incl. verdicts ==='
# ============================================================
# The archive-instead-of-rm upgrade of guard 1. A completed round leaves a
# DONE close-marker AND a req-NNN-*.answered.md verdict; `reset` must sweep
# BOTH into <channel>/.stale-archive-<ts>/ so the next `require` round is
# clean and the forensic trail survives.
XTASK=w511-reset
XDIR="$NEXUS_STATE_DIR/skeptic/$XTASK"
mkdir -p "$XDIR"
printf 'closed by prior fire\n'  > "$XDIR/DONE"
printf 'verdict: credible\n'     > "$XDIR/req-001-verdict.answered.md"
printf 'a still-open request\n'  > "$XDIR/req-002-open.open.md"   # current round — must survive
out=$("$CHAN" reset "$XTASK"); rc=$?
assert_eq "reset exits 0" "$rc" "0"
assert_nofile "reset moved DONE out of the channel root"            "$XDIR/DONE"
assert_nofile "reset moved the .answered.md verdict out"           "$XDIR/req-001-verdict.answered.md"
assert_file   "reset LEFT the current round's open request"        "$XDIR/req-002-open.open.md"
arch=$(ls -d "$XDIR"/.stale-archive-* 2>/dev/null | head -1)
assert_file   "archived DONE lives under .stale-archive-*"          "$arch/DONE"
assert_file   "archived verdict lives under .stale-archive-*"       "$arch/req-001-verdict.answered.md"
assert_contains "reset reports what it archived" "$out" "archived 2 stale sentinel(s)"

# reset on a channel with nothing stale is an idempotent no-op (rc 0).
"$CHAN" reset "$XTASK" >/dev/null 2>&1; rc=$?
assert_eq "reset is idempotent (no-op rc 0 when nothing stale)" "$rc" "0"
# reset on a never-seen channel is also a clean no-op (no dir conjured).
"$CHAN" reset w511-never-seen >/dev/null 2>&1; rc=$?
assert_eq "reset on an absent channel -> no-op rc 0" "$rc" "0"
assert_nofile "reset does not conjure an absent channel dir" "$NEXUS_STATE_DIR/skeptic/w511-never-seen"

# End-to-end: wrap-up require now ARCHIVES the prior DONE (guard 1 upgraded
# from bare rm) — the DONE is gone from the channel root AND recoverable.
ATASK=w511-wrapup-archive
mk_prov "$ATASK" require 0 false ""
mkdir -p "$NEXUS_STATE_DIR/skeptic/$ATASK"
printf 'round-1 verdict\n' > "$NEXUS_STATE_DIR/skeptic/$ATASK/DONE"
printf 'verdict: credible\n' > "$NEXUS_STATE_DIR/skeptic/$ATASK/req-001-v.answered.md"
age_file "$NEXUS_STATE_DIR/skeptic/$ATASK/DONE" 60
_wrapup_skeptic_step 511 "$ATASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
assert_nofile "wrap-up require -> prior DONE gone from channel root" "$NEXUS_STATE_DIR/skeptic/$ATASK/DONE"
aarch=$(ls -d "$NEXUS_STATE_DIR/skeptic/$ATASK"/.stale-archive-* 2>/dev/null | head -1)
assert_file "wrap-up require -> prior DONE ARCHIVED (recoverable)" "$aarch/DONE"
assert_file "wrap-up require -> fresh pending marker set" "$PEND/$ATASK"

# ============================================================
echo
echo '=== re-wrap-up guard: a completed pass is NOT re-opened ==='
# ============================================================
# A `require` worker whose skeptic pass ALREADY returned a verdict wakes
# (the verdict cleared its marker) and re-runs wrap-up on the same result.
# The require branch used to be unconditional, so the re-wrap filed a
# duplicate spawn-skeptic request, RE-ARMED the skeptic-pending marker
# (a hard retire gate -> retire-preflight safe=0 on a validated worker),
# and `reset` archived the completed round's channel (`total=5` -> `1`,
# reading as UNSTARTED). The guard keys on the last round-lifecycle event
# in the action log: a verdict newest means there is no round to open.
GTASK=rewrap-guard
GSK=rewrap-guard-skeptic
mk_prov "$GTASK" require 0 false ""
mk_prov "$GSK"   require 1 true "$GTASK" "$GTASK"

# Round 1: worker wrap-up arms the gate and logs skeptic-request.
_wrapup_skeptic_step 900 "$GTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
assert_file "round 1 -> pending marker armed" "$PEND/$GTASK"
assert_eq "round 1 -> request intent signalled" "${_SK_SPAWN_REQ:-0}" "1"

# The channel carries the round's traffic: 2 asked, 1 answered.
"$CHAN" init "$GTASK" >/dev/null 2>&1
"$CHAN" ask "$GTASK" q1 --message "why?"  >/dev/null
"$CHAN" ask "$GTASK" q2 --message "how?"  >/dev/null
"$CHAN" answer "$GTASK" 1 --message "because" >/dev/null
g_before=$("$CHAN" status "$GTASK")
assert_eq "channel carries the round's traffic" "$g_before" "open=1 ack=0 answered=1 total=2 done=0"

# The skeptic returns a verdict — clears the worker's marker (existing
# behaviour) and logs skeptic-verdict, which is what the guard reads.
_wrapup_skeptic_step 900 "$GSK" your-org/your-nexus 1 "" "" "" credible "$GTASK" 1 0 "$GTASK" >/dev/null 2>&1
assert_nofile "verdict -> worker's marker cleared" "$PEND/$GTASK"

# THE RE-WRAP-UP. Not in a command substitution: cmd_wrap_up calls the
# step directly and the _SK_SPAWN_* request-intent globals must survive.
_wrapup_skeptic_step 900 "$GTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" > "$WORK/rewrap.out" 2>&1
rc=$?
g_out=$(cat "$WORK/rewrap.out")
assert_eq "re-wrap -> rc 0 (wrap-up still completes)" "$rc" "0"
assert_contains "re-wrap -> announces ALREADY VALIDATED" "$g_out" "SKEPTIC: ALREADY VALIDATED"
assert_contains "re-wrap -> reports the prior verdict"   "$g_out" "verdict : credible"
assert_contains "re-wrap -> names the escape hatch"      "$g_out" "--skeptic-new-round"
assert_not_contains "re-wrap -> does NOT claim a skeptic is required" "$g_out" "SKEPTIC REQUIRED"
assert_nofile "re-wrap -> pending marker NOT re-armed (no bogus retire gate)" "$PEND/$GTASK"
assert_eq "re-wrap -> no duplicate request intent" "${_SK_SPAWN_REQ:-0}" "0"
assert_eq "re-wrap -> channel left intact (counters unchanged)" "$("$CHAN" status "$GTASK")" "$g_before"
assert_eq "re-wrap -> channel NOT archived" \
    "$(ls -d "$NEXUS_STATE_DIR/skeptic/$GTASK"/.stale-archive-* 2>/dev/null | wc -l)" "0"

# --- escape hatch: --skeptic-new-round opens a genuine second round ---
# positionals: issue window repo | role decision rationale waive verdict
#              target depth findings orig contradicted NEW_ROUND
_wrapup_skeptic_step 900 "$GTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" "" "" 1 \
    > "$WORK/newround.out" 2>&1
n_out=$(cat "$WORK/newround.out")
assert_contains "--skeptic-new-round -> SKEPTIC REQUIRED (round re-opened)" "$n_out" "SKEPTIC REQUIRED"
assert_file "--skeptic-new-round -> pending marker re-armed" "$PEND/$GTASK"
assert_eq "--skeptic-new-round -> request intent signalled" "${_SK_SPAWN_REQ:-0}" "1"
assert_eq "--skeptic-new-round -> completed round's channel archived" \
    "$(ls -d "$NEXUS_STATE_DIR/skeptic/$GTASK"/.stale-archive-* 2>/dev/null | wc -l)" "1"

# --- after a forced new round, the NEXT re-wrap is a normal require ---
# The last round-lifecycle event is now skeptic-request (that round is
# still open), so the guard must NOT fire — it keys on a verdict being
# newest, not on a verdict merely existing.
rm -f "$PEND/$GTASK"
_wrapup_skeptic_step 900 "$GTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" > "$WORK/open.out" 2>&1
assert_contains "open round -> guard does not fire (still SKEPTIC REQUIRED)" \
    "$(cat "$WORK/open.out")" "SKEPTIC REQUIRED"
assert_file "open round -> marker re-armed as before" "$PEND/$GTASK"

# --- the guard is reversible via config/env ---
DTASK=rewrap-guard-off
DSK=rewrap-guard-off-skeptic
mk_prov "$DTASK" require 0 false ""
mk_prov "$DSK"   require 1 true "$DTASK" "$DTASK"
_wrapup_skeptic_step 901 "$DTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
_wrapup_skeptic_step 901 "$DSK" your-org/your-nexus 1 "" "" "" credible "$DTASK" 1 0 "$DTASK" >/dev/null 2>&1
MONITOR_SKEPTIC_REWRAP_GUARD=0 \
    _wrapup_skeptic_step 901 "$DTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" \
    > "$WORK/guardoff.out" 2>&1
assert_contains "MONITOR_SKEPTIC_REWRAP_GUARD=0 -> pre-fix behaviour restored" \
    "$(cat "$WORK/guardoff.out")" "SKEPTIC REQUIRED"
assert_file "guard off -> marker re-armed (the old, buggy path)" "$PEND/$DTASK"

# --- a window with no skeptic history is untouched by the guard ---
FTASK=rewrap-guard-virgin
mk_prov "$FTASK" require 0 false ""
_wrapup_skeptic_step 902 "$FTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" > "$WORK/virgin.out" 2>&1
assert_contains "no skeptic history -> first-round require unaffected" \
    "$(cat "$WORK/virgin.out")" "SKEPTIC REQUIRED"
assert_file "no skeptic history -> pending marker set" "$PEND/$FTASK"

# --- deny / auto-deny paths are untouched (guard is require-only) ---
NTASK=rewrap-guard-deny
NSK=rewrap-guard-deny-skeptic
mk_prov "$NTASK" auto 0 false ""
mk_prov "$NSK"   require 1 true "$NTASK" "$NTASK"
_wrapup_skeptic_step 903 "$NTASK" your-org/your-nexus 0 require "infra" "" "" "" "" "" >/dev/null 2>&1
_wrapup_skeptic_step 903 "$NSK" your-org/your-nexus 1 "" "" "" credible "$NTASK" 1 0 "$NTASK" >/dev/null 2>&1
out=$(_wrapup_skeptic_step 903 "$NTASK" your-org/your-nexus 0 deny "trivial follow-up" "" "" "" "" "" 2>&1)
assert_contains "deny after a verdict -> still takes the deny path" "$out" "SKEPTIC: NOT WARRANTED"
assert_nofile "deny after a verdict -> no marker" "$PEND/$NTASK"

# ============================================================
echo
echo '=== re-wrap-up guard: scoped to the CURRENT LIFE of a window name ==='
# ============================================================
# The guard keys on a tmux WINDOW NAME, and window names are RECYCLED for
# unrelated tasks after a retire. Unfloored, a brand-new task spawned into
# a recycled name reads the PREVIOUS task's verdict as "newest", the guard
# fires, and its `require` gate is never armed: no marker, no
# spawn-skeptic request, no skeptic, no error — a SILENT require -> deny
# downgrade, strictly worse than the fail-closed bug the guard fixes.
#
# The floor is the window's most recent FRESH `spawn` action-log event
# (`spawn-worker.sh` writes it as the lifecycle-birth anchor). These cases
# are modelled on the live log shapes: `mouse-bm` (one verdict, then a
# fresh spawn whose worker DID need a skeptic) and `cc-auto-update` (one
# verdict, then a daily cron re-spawning the same name for weeks).

# Helper: the fresh-spawn anchor spawn-worker.sh seeds on a real birth.
# `mode` absent == fresh; `mode=resume` == same task continued.
spawn_ev() { # window [mode]
    local -a x=( --extra "window=$1" --extra "workdir=/tmp/$1"
                 --extra "kind=task" --extra "skeptic-mode=require" )
    [[ -n "${2:-}" ]] && x+=( --extra "mode=$2" )
    ( cmd_log_action monitor --event spawn "${x[@]}" ) >/dev/null 2>&1
}

# --- CASE 1: mouse-bm — verdict, then a FRESH spawn into the same name ---
RTASK=recycled-name
RSK=recycled-name-skeptic
mk_prov "$RTASK" require 0 false ""
mk_prov "$RSK"   require 1 true "$RTASK" "$RTASK"

# Task A: born, wraps up require, skeptic returns a verdict. Round closed.
spawn_ev "$RTASK"
_wrapup_skeptic_step 910 "$RTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
_wrapup_skeptic_step 910 "$RSK" your-org/your-nexus 1 "" "" "" credible "$RTASK" 1 0 "$RTASK" >/dev/null 2>&1
assert_nofile "task A: verdict cleared the marker (round closed)" "$PEND/$RTASK"

# Sanity: with only task A's history, the newest lifecycle event IS the
# verdict — i.e. the guard is correctly armed right up to the respawn.
assert_contains "task A: newest lifecycle event is the verdict" \
    "$(_skeptic_last_round_event "$RTASK")" "skeptic-verdict"

# The window retires; the NAME is recycled for an unrelated task B.
rm -rf "$NEXUS_STATE_DIR/skeptic/$RTASK"
spawn_ev "$RTASK"
assert_contains "task B: a fresh spawn resets the discriminator" \
    "$(_skeptic_last_round_event "$RTASK")" "spawn"

# Task B's FIRST-EVER wrap-up. It has never been validated by anyone.
_wrapup_skeptic_step 911 "$RTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" \
    > "$WORK/recycled.out" 2>&1
r_out=$(cat "$WORK/recycled.out")
assert_contains "recycled name: task B still gets SKEPTIC REQUIRED" "$r_out" "SKEPTIC REQUIRED"
assert_not_contains "recycled name: task B NOT waved through as validated" \
    "$r_out" "ALREADY VALIDATED"
assert_file "recycled name: task B's require gate IS armed" "$PEND/$RTASK"
assert_eq "recycled name: task B's spawn-skeptic request IS filed" "${_SK_SPAWN_REQ:-0}" "1"

# --- CASE 2: auto -> require is downgraded too, not just spawn-mode require ---
# Every one of the six real suppressions on the live log was an `auto`
# worker that DECIDED require, so this is the dominant exposure.
ATASK2=recycled-auto
ASK2=recycled-auto-skeptic
mk_prov "$ATASK2" auto 0 false ""
mk_prov "$ASK2"   require 1 true "$ATASK2" "$ATASK2"
spawn_ev "$ATASK2"
_wrapup_skeptic_step 912 "$ATASK2" your-org/your-nexus 0 require "infra" "" "" "" "" "" >/dev/null 2>&1
_wrapup_skeptic_step 912 "$ASK2" your-org/your-nexus 1 "" "" "" check "$ATASK2" 1 0 "$ATASK2" >/dev/null 2>&1
rm -rf "$NEXUS_STATE_DIR/skeptic/$ATASK2"
spawn_ev "$ATASK2"
_wrapup_skeptic_step 913 "$ATASK2" your-org/your-nexus 0 require "new task, touched infra" "" "" "" "" "" \
    > "$WORK/recycled-auto.out" 2>&1
a2_out=$(cat "$WORK/recycled-auto.out")
assert_contains "recycled name: auto->require decision is HONOURED" "$a2_out" "SKEPTIC REQUIRED"
assert_not_contains "recycled name: auto->require not silently downgraded" \
    "$a2_out" "ALREADY VALIDATED"
assert_file "recycled name: auto->require gate armed" "$PEND/$ATASK2"

# --- CASE 3: cc-auto-update — ONE verdict must not suppress N later runs ---
# The live shape: a daily cron re-spawns the same window name. One verdict
# on day 1 suppressed 13 consecutive daily runs.
CTASK=cron-recycled
CSK=cron-recycled-skeptic
mk_prov "$CTASK" require 0 false ""
mk_prov "$CSK"   require 1 true "$CTASK" "$CTASK"
spawn_ev "$CTASK"
_wrapup_skeptic_step 914 "$CTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
_wrapup_skeptic_step 914 "$CSK" your-org/your-nexus 1 "" "" "" credible "$CTASK" 1 0 "$CTASK" >/dev/null 2>&1
c_armed=0
for c_day in 1 2 3; do
    rm -rf "$NEXUS_STATE_DIR/skeptic/$CTASK" "$PEND/$CTASK"
    spawn_ev "$CTASK"
    _wrapup_skeptic_step "91$c_day" "$CTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
    [[ -f "$PEND/$CTASK" ]] && c_armed=$(( c_armed + 1 ))
done
assert_eq "daily cron re-spawn: every run arms its own gate (3/3)" "$c_armed" "3"

# --- CASE 4: the #68 fix still holds — a re-wrap-up in the SAME life ---
# No fresh spawn between the verdict and the re-wrap-up, so the verdict is
# still newest and the guard must fire exactly as #69 intends.
STASK=samelife-rewrap
SSK=samelife-rewrap-skeptic
mk_prov "$STASK" require 0 false ""
mk_prov "$SSK"   require 1 true "$STASK" "$STASK"
spawn_ev "$STASK"
_wrapup_skeptic_step 920 "$STASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
_wrapup_skeptic_step 920 "$SSK" your-org/your-nexus 1 "" "" "" credible "$STASK" 1 0 "$STASK" >/dev/null 2>&1
_wrapup_skeptic_step 920 "$STASK" your-org/your-nexus 0 "" "" "" "" "" "" "" \
    > "$WORK/samelife.out" 2>&1
assert_contains "same life: re-wrap-up still guarded (#68 fix intact)" \
    "$(cat "$WORK/samelife.out")" "SKEPTIC: ALREADY VALIDATED"
assert_nofile "same life: marker NOT re-armed" "$PEND/$STASK"
assert_eq "same life: no duplicate request intent" "${_SK_SPAWN_REQ:-0}" "0"

# --- CASE 5: a RESUME is not a new life — the guard must still fire ---
# `verdict -> resume -> re-wrap-up` is a live shape of the #68 bug: the
# worker is the SAME task, woken by --resume. Excluding resumes from the
# floor is what keeps #69 working across a respawn.
UTASK=resume-rewrap
USK=resume-rewrap-skeptic
mk_prov "$UTASK" require 0 false ""
mk_prov "$USK"   require 1 true "$UTASK" "$UTASK"
spawn_ev "$UTASK"
_wrapup_skeptic_step 921 "$UTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
_wrapup_skeptic_step 921 "$USK" your-org/your-nexus 1 "" "" "" credible "$UTASK" 1 0 "$UTASK" >/dev/null 2>&1
spawn_ev "$UTASK" resume
assert_contains "resume does NOT reset the discriminator" \
    "$(_skeptic_last_round_event "$UTASK")" "skeptic-verdict"
_wrapup_skeptic_step 921 "$UTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" \
    > "$WORK/resumed.out" 2>&1
assert_contains "resumed worker: re-wrap-up still guarded (#68 fix intact)" \
    "$(cat "$WORK/resumed.out")" "SKEPTIC: ALREADY VALIDATED"
assert_nofile "resumed worker: marker NOT re-armed" "$PEND/$UTASK"

# --- CASE 6: an OPEN round survives a fresh spawn without being re-closed ---
# Round open (request logged, no verdict yet) and the window is respawned
# fresh. The discriminator is a spawn, not a verdict, so the guard does
# not fire and the re-wrap-up re-opens — the pre-#69, fail-CLOSED
# direction. Asserted so the choice is pinned, not accidental.
OTASK=openround-respawn
mk_prov "$OTASK" require 0 false ""
spawn_ev "$OTASK"
_wrapup_skeptic_step 922 "$OTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
spawn_ev "$OTASK"
rm -f "$PEND/$OTASK"
_wrapup_skeptic_step 922 "$OTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" \
    > "$WORK/openround.out" 2>&1
assert_contains "open round + fresh respawn -> fails CLOSED (re-opens)" \
    "$(cat "$WORK/openround.out")" "SKEPTIC REQUIRED"
assert_file "open round + fresh respawn -> gate armed" "$PEND/$OTASK"

# --- CASE 7: window names that are prefixes of one another don't collide ---
# `<name>` and `<name>-skeptic` run concurrently by construction, and the
# spawn clause matches `.window`, a field the skeptic's own spawn also
# carries. Exact `==` only.
PTASK=prefixcol
mk_prov "$PTASK" require 0 false ""
mk_prov "$PTASK-skeptic" require 1 true "$PTASK" "$PTASK"
spawn_ev "$PTASK"
_wrapup_skeptic_step 923 "$PTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
_wrapup_skeptic_step 923 "$PTASK-skeptic" your-org/your-nexus 1 "" "" "" credible "$PTASK" 1 0 "$PTASK" >/dev/null 2>&1
# The skeptic's OWN fresh spawn must not clear the reviewed worker's floor.
spawn_ev "$PTASK-skeptic"
assert_contains "sibling window's spawn does not reset the target's floor" \
    "$(_skeptic_last_round_event "$PTASK")" "skeptic-verdict"
_wrapup_skeptic_step 923 "$PTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" \
    > "$WORK/prefix.out" 2>&1
assert_contains "prefix sibling: reviewed worker still guarded" \
    "$(cat "$WORK/prefix.out")" "SKEPTIC: ALREADY VALIDATED"

# --- CASE 8: the prefilter must not drop events jq needs ---
# `_skeptic_last_round_event` greps before it parses. A fresh `spawn`
# happens to carry a `skeptic-mode` extra today, so the OLD prefilter
# (`"skeptic-`) would let it through by accident; a resume carries no
# such field. Pin the prefilter to the `event` field so neither the
# match nor the exclusion depends on an unrelated script's extras.
XTASK=prefilter-probe
mk_prov "$XTASK" require 0 false ""
( cmd_log_action monitor --event spawn --extra "window=$XTASK" --extra "kind=task" ) >/dev/null 2>&1
assert_contains "spawn with NO skeptic-* extras is still seen" \
    "$(_skeptic_last_round_event "$XTASK")" "spawn"
( cmd_log_action monitor --event spawn --extra "window=$XTASK" --extra "mode=resume" \
    --extra "skeptic-mode=require" ) >/dev/null 2>&1
assert_contains "resume carrying a skeptic-* extra is still excluded" \
    "$(_skeptic_last_round_event "$XTASK")" $'spawn\t-\t-'
assert_eq "resume did not become the newest lifecycle event" \
    "$(_skeptic_last_round_event "$XTASK" | cut -f4)" \
    "$(grep -F '"event":"spawn"' "$NEXUS_STATE_DIR/action-log.jsonl" \
       | jq -r --arg w "$XTASK" 'select(.window==$w and ((.mode//"")!="resume")) | .ts' | tail -1)"

# --- CASE 9: a window with no lifecycle history at all ---
# rc 1 / empty, and the guard leaves a first-round require alone.
assert_eq "no lifecycle history -> rc 1" \
    "$(_skeptic_last_round_event no-such-window-anywhere >/dev/null 2>&1; echo $?)" "1"

# ============================================================
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
