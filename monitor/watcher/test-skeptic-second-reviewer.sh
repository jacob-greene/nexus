#!/usr/bin/env bash
# Unit tests for the second-live-reviewer refusal in monitor/spawn-worker.sh
# (your-org/nexus-code#1858).
#
# Run: bash monitor/watcher/test-skeptic-second-reviewer.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. `_obl_supersedes` rule 2 (monitor/_obligations.sh) decides a
# subject-less pair of reviewers of one target by whether the EARLIER one had
# delivered a verdict before the later one was pinned. For a RETAINED reviewer
# that errs toward VOID (ncbundle31-sk F2): gate-sk files REVISE on `pipe` and
# is kept for the delta; alerts-sk is pinned to `pipe` for a different PR; and
# gate-sk's edge reads void-superseded, retirable while still owed. The fix
# refuses the spawn that would create that pair unless --skeptic-subject is
# passed.
#
# BOTH DIRECTIONS, EVERY TIME (the test-skeptic-self-spawn.sh discipline). A
# guard on the path the orchestrator takes for every skeptic must be shown to
# ALLOW the neighbouring shapes, so every REFUSE case is paired with an ALLOW
# case that differs in one variable, and the ALLOW case asserts a composed
# prompt on stdout, not merely exit 0.
#
# NO TMUX IS TOUCHED: every launcher call carries --print-prompt, and the
# refusal fires before composition. Edges are opened with obligations.sh
# directly, with --at and OBL_NOW_OVERRIDE so the ORDER of opens and verdicts is
# exact rather than a same-second tie (which rule 2 treats conservatively and
# would make the probe vacuous).
#
# Env robustness: every launcher call runs under `env -u CLAUDE_SESSION_ID
# -u NEXUS_WORKER_WINDOW` with NEXUS_ROOT and NEXUS_STATE_DIR pinned to the
# fixture, so a worker running this suite cannot leak its own identity or
# ledger into it.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_REAL="$_test_dir/../spawn-worker.sh"
SKILL_REAL="$_test_dir/../../skills/nexus.worker-defaults/SKILL.md"

. "$_test_dir/_test_helpers.sh"
PASS=0
FAIL=0

# ---- fixture ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SPAWN_TMP="$WORK/spawn-tmp"; mkdir -p "$SPAWN_TMP"; export TMPDIR="$SPAWN_TMP"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" \
         "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports"

cp "$SCRIPT_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh"
cp "$_test_dir/../guard-block.sh.in" "$FAKE_NEXUS/monitor/guard-block.sh.in"
for _dep in _claude-bin.sh _tmux-window.sh _fm_lib.sh _channel_lib.sh _bookkeeping.sh \
            _requests_dir.sh _obligations.sh; do
    cp "$_test_dir/../$_dep" "$FAKE_NEXUS/monitor/$_dep"
done
for _exe in request-channel.sh obligations.sh; do
    cp "$_test_dir/../$_exe" "$FAKE_NEXUS/monitor/$_exe"
    chmod +x "$FAKE_NEXUS/monitor/$_exe"
done
cp "$SKILL_REAL" "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md"

mkdir -p "$FAKE_NEXUS/node_modules/.bin"
printf '#!/bin/bash\necho "stub-claude: $*"\n' > "$FAKE_NEXUS/node_modules/.bin/claude"
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"
cat > "$FAKE_NEXUS/monitor/worker-settings.json" <<'EOF'
{ "skipDangerousModePermissionPrompt": true, "hooks": {} }
EOF

SCRIPT="$FAKE_NEXUS/monitor/spawn-worker.sh"
OBLIG="$FAKE_NEXUS/monitor/obligations.sh"
WORKDIR="$WORK/worker-tree"; mkdir -p "$WORKDIR"
PROMPT_FILE="$WORK/task-prompt.txt"
printf 'TASK_PROMPT_TOKEN_1858\n\nReview the thing.\n' > "$PROMPT_FILE"

# The creditor-absence probe asks tmux which windows exist; a creditor missing
# from tmux reads void-creditor-absent. OBL_TMUX_WINDOWS is the ledger's own
# test seam (monitor/_obligations.sh:_obl_tmux_windows), exported so it reaches
# BOTH this suite's ledger reads AND the launcher's, whatever tmux server the
# runner happens to be inside (or none, on CI).
export OBL_TMUX_WINDOWS=$'pipe\npapercuts\nfresh\nother\nroot\nsk1\nsk2\nsk3\nperf-sk'

# Each case gets its OWN state dir, so no case can be decided by an edge a
# previous case left behind.
STATE=""
new_state() { STATE="$WORK/state-$1"; mkdir -p "$STATE/windows"; }

# obl <args...> — the ledger CLI against the current case's state dir.
obl() { env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE" "$OBLIG" "$@"; }

# edge_state <debtor> <creditor> — the derived state word of that edge.
edge_state() {
    local row
    row=$(obl list --all --debtor "$1" --creditor "$2" --kind skeptic-verdict --tsv 2>/dev/null)
    printf '%s' "${row%%$'\t'*}"
}

# spawn <script> <window> <target> [extra args...] — compose a reviewer's prompt.
spawn_with() {
    local script="$1" win="$2" target="$3"; shift 3
    env -u CLAUDE_SESSION_ID -u NEXUS_WORKER_WINDOW \
        -u NEXUS_SKEPTIC_SELF_SPAWN -u NEXUS_SKEPTIC_SELF_SPAWN_REASON \
        NEXUS_ROOT="$FAKE_NEXUS" NEXUS_STATE_DIR="$STATE" \
        "$script" -n "$win" -c "$WORKDIR" -p "$PROMPT_FILE" \
        --skeptic-role --skeptic-target "$target" --print-prompt "$@"
}
spawn() { spawn_with "$SCRIPT" "$@"; }

T0=1800000000     # gate-sk / sk900 pinned
T1=$(( T0 + 100 ))  # its verdict (REVISE) filed
T2=$(( T0 + 200 ))  # the second reviewer pinned

# <window> <target> [subject] — an earlier reviewer that delivered round 1.
delivered_reviewer() {
    local -a sub=()
    [[ -n "${3:-}" ]] && sub=(--subject "$3")
    obl open --debtor "$1" --creditor "$2" --kind skeptic-verdict --round 1 \
        --at "$T0" ${sub[@]+"${sub[@]}"} --by test >/dev/null || th_abort "fixture open failed for $1"
    OBL_NOW_OVERRIDE="$T1" obl note --debtor "$1" --creditor "$2" --verdict \
        --text "round 1 REVISE" >/dev/null || th_abort "fixture verdict failed for $1"
}

# ---- P1: the ncbundle31-sk F2 probe, refused at spawn --------------------

echo '=== P1: retained reviewer gate-sk is LIVE on pipe; alerts-sk without a subject -> REFUSED (exit 29) ==='
new_state p1
delivered_reviewer gate-sk pipe
assert_eq "P1 precondition: gate-sk's edge is live before the spawn" "$(edge_state gate-sk pipe)" "live"
out=$(spawn alerts-sk pipe 2>&1); rc=$?
assert_eq       "P1 exit code is 29"                 "$rc" "29"
assert_contains "P1 names the issue"                 "$out" "your-org/nexus-code#1858"
assert_contains "P1 names the live reviewer"         "$out" "gate-sk"
assert_contains "P1 names the remedy flag"           "$out" "--skeptic-subject"
assert_not_contains "P1 composed NO prompt"          "$out" "TASK_PROMPT_TOKEN_1858"
assert_eq "P1 gate-sk's edge is still live after the refusal" "$(edge_state gate-sk pipe)" "live"

# ---- P1-WHY: what the refusal prevents, measured on the real ledger ------
#
# Opening alerts-sk's edge WITHOUT subjects (what the launcher used to do)
# voids gate-sk. This pins the premise: if rule 2 ever stops voiding this
# shape, the refusal is no longer needed and this assertion says so.
echo '=== P1-WHY: without the refusal, a subject-less second edge voids gate-sk ==='
obl open --debtor alerts-sk --creditor pipe --kind skeptic-verdict --round 1 \
    --at "$T2" --by test >/dev/null
assert_eq "P1-WHY gate-sk reads void-superseded once a subject-less edge opens" \
    "$(edge_state gate-sk pipe)" "void-superseded"

# ---- P2: the same probe with subjects on both edges ---------------------

echo '=== P2: same probe, subjects on BOTH edges -> ALLOWED, and both stay live ==='
new_state p2
delivered_reviewer gate-sk pipe 'proj#275'
out=$(spawn alerts-sk pipe --skeptic-subject 'proj#276' 2>"$WORK/p2.err"); rc=$?
err=$(cat "$WORK/p2.err")
assert_eq       "P2 exit code is 0"                  "$rc" "0"
assert_contains "P2 composed the prompt"             "$out" "TASK_PROMPT_TOKEN_1858"
assert_not_contains "P2 no refusal on stderr"        "$err" "REFUSING"
assert_not_contains "P2 no subject-less WARNING"     "$err" "carry NO subject"
# What the launcher opens next (the --print-prompt seam stops before it):
obl open --debtor alerts-sk --creditor pipe --kind skeptic-verdict --round 1 \
    --at "$T2" --subject 'proj#276' --by test >/dev/null
assert_eq "P2 gate-sk stays live (different subject = concurrent)"  "$(edge_state gate-sk pipe)"   "live"
assert_eq "P2 alerts-sk is live"                                     "$(edge_state alerts-sk pipe)" "live"

# ---- P3: the sk900 -> sk911 handover control ----------------------------

echo '=== P3: sk900 delivered and its pairing was settled; sk911 needs NO subject ==='
new_state p3
delivered_reviewer sk900 papercuts
obl settle --debtor sk900 --creditor papercuts --kind skeptic-verdict \
    --reason "handed over: sk911 replaces sk900 for the same review" --by test >/dev/null || th_abort "fixture settle failed"
assert_eq "P3 precondition: sk900's edge is settled" "$(edge_state sk900 papercuts)" "settled"
out=$(spawn sk911 papercuts 2>"$WORK/p3.err"); rc=$?
assert_eq       "P3 exit code is 0"                  "$rc" "0"
assert_contains "P3 composed the prompt"             "$out" "TASK_PROMPT_TOKEN_1858"
assert_not_contains "P3 no refusal"                  "$(cat "$WORK/p3.err")" "REFUSING"

echo '=== P3b: no edge at all on the target -> ALLOWED ==='
new_state p3b
out=$(spawn first-sk fresh 2>&1); rc=$?
assert_eq       "P3b exit code is 0"                 "$rc" "0"
assert_contains "P3b composed the prompt"            "$out" "TASK_PROMPT_TOKEN_1858"

# ---- P4: a subject on the NEW edge only -> allowed, with a WARNING -------

echo '=== P4: live reviewer has NO subject, new spawn passes one -> ALLOWED with a WARNING ==='
new_state p4
delivered_reviewer gate-sk pipe
out=$(spawn alerts-sk pipe --skeptic-subject 'proj#276' 2>"$WORK/p4.err"); rc=$?
err=$(cat "$WORK/p4.err")
assert_eq       "P4 exit code is 0"                  "$rc" "0"
assert_contains "P4 composed the prompt"             "$out" "TASK_PROMPT_TOKEN_1858"
assert_contains "P4 WARNING names the subject-less reviewer" "$err" "carry NO subject: gate-sk"
assert_contains "P4 WARNING states the void consequence"     "$err" "void-superseded"

# ---- P5: only OTHER targets / the same window / a dead edge -> allowed ---

echo '=== P5: a live reviewer of a DIFFERENT target does not count ==='
new_state p5
delivered_reviewer gate-sk other
out=$(spawn alerts-sk pipe 2>&1); rc=$?
assert_eq "P5 exit code is 0 (gate-sk reviews 'other', not 'pipe')" "$rc" "0"

echo '=== P6: the live edge is THIS window'"'"'s own (a respawn) -> ALLOWED ==='
new_state p6
delivered_reviewer alerts-sk pipe
out=$(spawn alerts-sk pipe 2>&1); rc=$?
assert_eq       "P6 exit code is 0"                  "$rc" "0"
assert_contains "P6 composed the prompt"             "$out" "TASK_PROMPT_TOKEN_1858"

echo '=== P7: two live reviewers -> the refusal names BOTH ==='
new_state p7
delivered_reviewer gate-sk pipe
obl open --debtor perf-sk --creditor pipe --kind skeptic-verdict --round 1 \
    --at "$T0" --by test >/dev/null
out=$(spawn alerts-sk pipe 2>&1); rc=$?
assert_eq       "P7 exit code is 29"                 "$rc" "29"
assert_contains "P7 names gate-sk"                   "$out" "gate-sk"
assert_contains "P7 names perf-sk"                   "$out" "perf-sk"

# ---- P8: an unreadable ledger proceeds with a NOTE (positive identification only)

echo '=== P8: obligations.sh missing -> ALLOWED with a NOTE, never a silent pass ==='
new_state p8
delivered_reviewer gate-sk pipe
P8_NEXUS="$WORK/nexus-p8"
cp -R "$FAKE_NEXUS" "$P8_NEXUS"
rm -f "$P8_NEXUS/monitor/obligations.sh"
out=$(env -u CLAUDE_SESSION_ID -u NEXUS_WORKER_WINDOW \
        NEXUS_ROOT="$P8_NEXUS" NEXUS_STATE_DIR="$STATE" \
        "$P8_NEXUS/monitor/spawn-worker.sh" -n alerts-sk -c "$WORKDIR" -p "$PROMPT_FILE" \
        --skeptic-role --skeptic-target pipe --print-prompt 2>&1); rc=$?
assert_eq       "P8 exit code is 0"                  "$rc" "0"
assert_contains "P8 says the check did not run"      "$out" "second-reviewer check did not run"

# ---- D: the recursive spawn's CHAIN-ROOT edge (ncbundle32-sk R1) ---------
#
# `--skeptic-target sk1 --skeptic-orig root` opens sk2->sk1 AND a subject-less
# chain-root edge sk2->root. Before the fix nothing checked root's reviewers,
# and rule 2 read sk2->root as sk1's replacement, voiding sk1->root once sk1
# had delivered. The launcher's own edges are opened here by hand, exactly as
# its edge block opens them (the --print-prompt seam stops before it).
T3=$(( T0 + 300 ))
chain_edges() {   # <debtor> <target> <root> <at>: what spawn-worker opens for a recursive skeptic
    obl open --debtor "$1" --creditor "$2" --kind skeptic-verdict --round 2 --at "$4" --by test >/dev/null || th_abort "chain edge $1->$2"
    obl open --debtor "$1" --creditor "$3" --kind skeptic-verdict --round 2 --at "$4" --by test >/dev/null || th_abort "chain-root edge $1->$3"
}

echo '=== D1: standard depth 2 (sk2 on sk1, root=root) -> ALLOWED, and sk1->root stays LIVE ==='
new_state d1
delivered_reviewer sk1 root
out=$(spawn sk2 sk1 --skeptic-orig root 2>"$WORK/d1.err"); rc=$?
assert_eq       "D1 exit code is 0 (ng's own recursion form is never refused)" "$rc" "0"
assert_contains "D1 composed the prompt"             "$out" "TASK_PROMPT_TOKEN_1858"
assert_not_contains "D1 no refusal"                  "$(cat "$WORK/d1.err")" "REFUSING"
chain_edges sk2 sk1 root "$T2"
assert_eq "D1 sk1->root stays live: a chain link is not a handover (was void-superseded)" "$(edge_state sk1 root)" "live"
assert_eq "D1 sk2->root is live"                     "$(edge_state sk2 root)" "live"

echo '=== D1-WHY: the same root edge WITHOUT the sk2->sk1 link voids sk1 (the arm is load-bearing) ==='
new_state d1why
delivered_reviewer sk1 root
obl open --debtor sk2 --creditor root --kind skeptic-verdict --round 2 --at "$T2" --by test >/dev/null
assert_eq "D1-WHY sk1->root reads void-superseded when sk2 does not review sk1" "$(edge_state sk1 root)" "void-superseded"

echo '=== D2: depth 3 (sk3 on sk2, root=root) -> ALLOWED; sk1->root and sk2->root both stay LIVE ==='
new_state d2
delivered_reviewer sk1 root
chain_edges sk2 sk1 root "$T2"
OBL_NOW_OVERRIDE=$(( T2 + 50 )) obl note --debtor sk2 --creditor sk1 --verdict --text "round 2 CHECK" >/dev/null
OBL_NOW_OVERRIDE=$(( T2 + 50 )) obl note --debtor sk2 --creditor root --verdict --text "round 2 CHECK" >/dev/null
out=$(spawn sk3 sk2 --skeptic-orig root 2>"$WORK/d2.err"); rc=$?
assert_eq       "D2 exit code is 0 (sk1 is in sk2's chain, so not an outside reviewer)" "$rc" "0"
assert_not_contains "D2 no refusal"                  "$(cat "$WORK/d2.err")" "REFUSING"
chain_edges sk3 sk2 root "$T3"
assert_eq "D2 sk1->root stays live (sk3 reviews sk1 through sk2)" "$(edge_state sk1 root)" "live"
assert_eq "D2 sk2->root stays live"                  "$(edge_state sk2 root)" "live"

echo '=== D3: a reviewer OUTSIDE the chain is live on root -> REFUSED (29), and a subject does not clear it ==='
new_state d3
delivered_reviewer sk1 root
delivered_reviewer perf-sk root
out=$(spawn sk2 sk1 --skeptic-orig root 2>&1); rc=$?
assert_eq       "D3 exit code is 29"                 "$rc" "29"
assert_contains "D3 names the outside reviewer"      "$out" "perf-sk"
assert_contains "D3 says it is outside the chain"    "$out" "outside this chain"
assert_not_contains "D3 does not count the chain's own sk1" "$out" "sk1 (edge"
assert_not_contains "D3 composed NO prompt"          "$out" "TASK_PROMPT_TOKEN_1858"
out=$(spawn sk2 sk1 --skeptic-orig root --skeptic-subject 'sk1-report' 2>&1); rc=$?
assert_eq       "D3 still 29 with --skeptic-subject (the root edge carries none)" "$rc" "29"

echo '=== D4: the D3 outsider settled -> ALLOWED ==='
new_state d4
delivered_reviewer sk1 root
delivered_reviewer perf-sk root
obl settle --debtor perf-sk --creditor root --kind skeptic-verdict \
    --reason "perf review finished and accepted by the worker" --by test >/dev/null || th_abort "fixture settle failed"
out=$(spawn sk2 sk1 --skeptic-orig root 2>&1); rc=$?
assert_eq       "D4 exit code is 0"                  "$rc" "0"
assert_contains "D4 composed the prompt"             "$out" "TASK_PROMPT_TOKEN_1858"

# ---- D5-D9: a STALE edge from a REUSED window name is not a chain link (#1865)
#
# Window names are reused (the real ledger has cifixsk->cifix from one task and
# cifixsk->cifix2 from a later one). obl_reviews used to count a link in ANY
# state and from ANY time, so an edge left by an earlier, unrelated task kept a
# reviewer live through a genuine handover. A link now counts only if it was
# opened at or after the judged edge's FIRST open. Each case is paired with a
# control that differs in that one timestamp.
TSTALE=$(( T0 - 1000 ))   # an earlier task, long before sk1 took the review on

echo '=== D5: old->sk1 left by an EARLIER task; old then takes root over -> sk1->root is VOIDED (handover) ==='
new_state d5
obl open --debtor old --creditor sk1 --kind skeptic-verdict --round 1 --at "$TSTALE" --by test >/dev/null || th_abort "stale edge"
delivered_reviewer sk1 root
obl open --debtor old --creditor root --kind skeptic-verdict --round 1 --at "$T2" --subject 'root-report' --by test >/dev/null || th_abort "handover edge"
assert_eq "D5 sk1->root reads void-superseded: a stale, still-open edge from a reused name is not a chain (was live)" \
    "$(edge_state sk1 root)" "void-superseded"
d5_root=$(obl list --all --debtor sk1 --creditor root --kind skeptic-verdict --tsv 2>/dev/null | cut -f5)
obl reviews old sk1 --since-edge "$d5_root" >/dev/null 2>&1; rc=$?
assert_eq "D5 reviews --since-edge <sk1->root> says no for the stale link" "$rc" "1"
obl reviews old sk1 >/dev/null 2>&1; rc=$?
assert_eq "D5 reviews WITHOUT a bound still says yes (the any-time reading is unchanged)" "$rc" "0"

echo '=== D5-CONTROL: the SAME edges, old->sk1 opened AFTER sk1 took root on -> a chain link, sk1->root LIVE ==='
new_state d5c
delivered_reviewer sk1 root
obl open --debtor old --creditor sk1 --kind skeptic-verdict --round 1 --at "$(( T0 + 50 ))" --by test >/dev/null || th_abort "link edge"
obl open --debtor old --creditor root --kind skeptic-verdict --round 1 --at "$T2" --subject 'root-report' --by test >/dev/null || th_abort "root edge"
assert_eq "D5-CONTROL sk1->root stays live when the link postdates sk1's edge" "$(edge_state sk1 root)" "live"

echo '=== D6: a SETTLED stale edge (the real-ledger shape) is not a chain link either ==='
new_state d6
obl open --debtor old --creditor sk1 --kind skeptic-verdict --round 1 --at "$TSTALE" --by test >/dev/null || th_abort "stale edge"
obl settle --debtor old --creditor sk1 --kind skeptic-verdict --reason "earlier task accepted" --by test >/dev/null || th_abort "settle stale"
delivered_reviewer sk1 root
obl open --debtor old --creditor root --kind skeptic-verdict --round 1 --at "$T2" --subject 'root-report' --by test >/dev/null || th_abort "handover edge"
assert_eq "D6 sk1->root reads void-superseded with a settled stale edge" "$(edge_state sk1 root)" "void-superseded"

echo '=== D7: a RE-ARMED root edge keeps the links it already had (the bound is its FIRST open) ==='
# sk1->root opens at T0; sk2 reviews sk1 from T2; sk1's root edge is re-armed at
# T2+10 and sk1 files a verdict at T2+20; sk3 then joins at depth 3 at T3. The
# genuine link sk2->sk1 predates the re-arm. Bounded by the CURRENT open it
# would be dropped and sk1->root voided (M6 below); bounded by the FIRST open it
# is kept.
new_state d7
delivered_reviewer sk1 root
chain_edges sk2 sk1 root "$T2"
obl open --debtor sk1 --creditor root --kind skeptic-verdict --round 2 --at "$(( T2 + 10 ))" --by test >/dev/null || th_abort "re-arm"
OBL_NOW_OVERRIDE=$(( T2 + 20 )) obl note --debtor sk1 --creditor root --verdict --text "round 2 REVISE" >/dev/null || th_abort "verdict"
chain_edges sk3 sk2 root "$T3"
assert_eq "D7 sk1->root stays live after a re-arm (sk3 reviews sk1 through sk2)" "$(edge_state sk1 root)" "live"

echo '=== D8: the launcher refusal applies the same bound (a stale sk1->perf-sk edge does not hide an outsider) ==='
new_state d8
obl open --debtor sk1 --creditor perf-sk --kind skeptic-verdict --round 1 --at "$TSTALE" --by test >/dev/null || th_abort "stale edge"
delivered_reviewer sk1 root
delivered_reviewer perf-sk root
out=$(spawn sk2 sk1 --skeptic-orig root 2>&1); rc=$?
assert_eq       "D8 exit code is 29: perf-sk is outside the chain despite the stale edge (was 0)" "$rc" "29"
assert_contains "D8 names the outside reviewer"      "$out" "perf-sk"
new_state d8c
delivered_reviewer sk1 root
delivered_reviewer perf-sk root
obl open --debtor sk1 --creditor perf-sk --kind skeptic-verdict --round 1 --at "$(( T0 + 50 ))" --by test >/dev/null || th_abort "link edge"
out=$(spawn sk2 sk1 --skeptic-orig root 2>&1); rc=$?
assert_eq       "D8-CONTROL exit code is 0 when sk1's edge on perf-sk postdates perf-sk's on root" "$rc" "0"

echo '=== D9: reviews rejects an unknown flag and an unknown --since-edge (no silent any-time answer) ==='
new_state d9
delivered_reviewer sk1 root
out=$(obl reviews sk1 root --bogus x 2>&1); rc=$?
assert_eq       "D9 an unknown flag exits 1"         "$rc" "1"
assert_contains "D9 names it"                        "$out" "unknown flag: --bogus"
out=$(obl reviews sk1 root --since-edge no__such__edge 2>&1); rc=$?
assert_eq       "D9 an unknown --since-edge exits 1" "$rc" "1"
assert_contains "D9 says so"                         "$out" "no such obligation"

# ---- D10/D11: SAME-PAIR reuse — a declared residual, KEPT (#1868 item 3) ---
#
# When the SAME (debtor, creditor) pair is reused by a later task, obl_open
# APPENDS to the one record, so its FIRST `opened_at` is the earlier task's and
# the #1865 bound loosens back toward the any-time reading: a stale link from
# that earlier task counts again and keeps the reviewer LIVE (D10).
#
# WHY IT IS KEPT. The tightening that suggests itself — bound by the first open
# since the record's last SETTLEMENT — cannot tell a reused pair from a pair
# that was settled and RE-ARMED inside one review: both are a `settled_at`
# followed by an `opened_at` in the same file. The open blocks are NOT
# identical (#1870 item 2): each carries its own `round`, and in these fixtures
# D10 re-opens at round 1 while D11 re-opens at round 2. That difference is a
# property of the FIXTURES, not of production: in the live ledger a genuine
# in-review re-arm re-opens at round 1 (21 of 22 re-opens after a settlement
# carry no higher round, measured 2026-10-17), so a round test would void it.
# D11 is the re-armed shape, and there the tightening drops a GENUINE link and
# voids a reviewer still owed a verdict, the dangerous direction. M7 below
# builds that tightening and shows it flipping BOTH cases. The residual errs
# live (a reviewer kept, never one wrongly retired), so it stays declared.
echo '=== D10: the SAME pair sk1->root reused from an earlier task; its stale old->sk1 link still counts (residual, LIVE) ==='
new_state d10
obl open --debtor sk1 --creditor root --kind skeptic-verdict --round 1 --at "$TSTALE" --by test >/dev/null || th_abort "earlier-task edge"
obl open --debtor old --creditor sk1 --kind skeptic-verdict --round 1 --at "$(( TSTALE + 10 ))" --by test >/dev/null || th_abort "earlier-task link"
obl settle --debtor old --creditor sk1 --kind skeptic-verdict --reason "earlier task accepted" --by test >/dev/null || th_abort "settle link"
obl settle --debtor sk1 --creditor root --kind skeptic-verdict --reason "earlier task accepted" --by test >/dev/null || th_abort "settle edge"
delivered_reviewer sk1 root
obl open --debtor old --creditor root --kind skeptic-verdict --round 1 --at "$T2" --subject 'root-report' --by test >/dev/null || th_abort "handover edge"
assert_eq "D10 sk1->root reads LIVE: the reused pair's first open is the earlier task's (declared residual)" \
    "$(edge_state sk1 root)" "live"
echo '=== D10-CONTROL: the same edges with no earlier sk1->root -> the bound applies, VOID ==='
new_state d10c
obl open --debtor old --creditor sk1 --kind skeptic-verdict --round 1 --at "$(( TSTALE + 10 ))" --by test >/dev/null || th_abort "earlier-task link"
obl settle --debtor old --creditor sk1 --kind skeptic-verdict --reason "earlier task accepted" --by test >/dev/null || th_abort "settle link"
delivered_reviewer sk1 root
obl open --debtor old --creditor root --kind skeptic-verdict --round 1 --at "$T2" --subject 'root-report' --by test >/dev/null || th_abort "handover edge"
assert_eq "D10-CONTROL sk1->root reads void-superseded: only the pair's REUSE made D10 live" \
    "$(edge_state sk1 root)" "void-superseded"
echo '=== D11: sk1->root SETTLED and RE-ARMED inside one review keeps its genuine link (LIVE) ==='
d11_fixture() {
    delivered_reviewer sk1 root
    chain_edges sk2 sk1 root "$T2"
    obl settle --debtor sk1 --creditor root --kind skeptic-verdict --reason "round 1 verdict accepted by the worker" --by test >/dev/null || th_abort "settle"
    obl open --debtor sk1 --creditor root --kind skeptic-verdict --round 2 --at "$(( T2 + 10 ))" --by test >/dev/null || th_abort "re-arm"
    OBL_NOW_OVERRIDE=$(( T2 + 20 )) obl note --debtor sk1 --creditor root --verdict --text "round 2 REVISE" >/dev/null || th_abort "verdict"
    chain_edges sk3 sk2 root "$T3"
}
new_state d11
d11_fixture
assert_eq "D11 sk1->root stays live after a settle + re-arm (sk3 reviews sk1 through sk2)" "$(edge_state sk1 root)" "live"

# ---- potency: the refusal and the self-window skip are each load-bearing --

echo '=== M: mutants of the guard flip the cases that pin them ==='
mutant() {   # <name> <python-replace-old> <python-replace-new>
    local m="$FAKE_NEXUS/monitor/spawn-worker-mut-$1.sh"   # beside its helpers: the launcher sources them from its own dir
    MUT_SRC="$SCRIPT" MUT_DST="$m" MUT_OLD="$2" MUT_NEW="$3" python3 - <<'PY' || return 1
import os
s = open(os.environ["MUT_SRC"]).read()
old = os.environ["MUT_OLD"]
assert s.count(old) == 1, "mutation anchor not unique: %r (%d)" % (old, s.count(old))
open(os.environ["MUT_DST"], "w").write(s.replace(old, os.environ["MUT_NEW"]))
PY
    chmod +x "$m"
    printf '%s' "$m"
}
new_state m1
delivered_reviewer gate-sk pipe
m1=$(mutant noexit $'            exit 29\n' $'            :\n') || th_abort "mutant M1 could not be built"
spawn_with "$m1" alerts-sk pipe >/dev/null 2>&1
assert_eq "M1 killed: with the exit removed, P1 is no longer refused" "$?" "0"
m2=$(mutant noself '[ -n "${_lr_d:-}" ] && [ "$_lr_d" != "$WINDOW_NAME" ] || continue' \
                   '[ -n "${_lr_d:-}" ] || continue') || th_abort "mutant M2 could not be built"
new_state m2
delivered_reviewer alerts-sk pipe
spawn_with "$m2" alerts-sk pipe >/dev/null 2>&1
assert_eq "M2 killed: without the self-window skip, P6 is refused" "$?" "29"

m3=$(mutant nocrexit '            exit 29   # the chain-root refusal (ncbundle32-sk R1)' '            :') || th_abort "mutant M3 could not be built"
new_state m3
delivered_reviewer sk1 root
delivered_reviewer perf-sk root
spawn_with "$m3" sk2 sk1 --skeptic-orig root >/dev/null 2>&1
assert_eq "M3 killed: with the chain-root exit removed, D3 is no longer refused" "$?" "0"
# M4: the LEDGER arm, in its own copy of the nexus (obligations.sh sources the
# _obligations.sh beside it). Neutered, D1's sk1->root goes back to void.
M4_NEXUS="$WORK/nexus-m4"; cp -R "$FAKE_NEXUS" "$M4_NEXUS"
MUT_F="$M4_NEXUS/monitor/_obligations.sh" python3 - <<'PY' || th_abort "mutant M4 could not be built"
import os
p = os.environ["MUT_F"]; s = open(p).read()
old = '        if obl_reviews "$sd" "$odebtor" "$debtor" "$kind" "${_first_open:-$opened_at}"; then\n'
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, '        if false; then\n'))
PY
new_state m4
delivered_reviewer sk1 root
chain_edges sk2 sk1 root "$T2"
m4_row=$(env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE" "$M4_NEXUS/monitor/obligations.sh" list --all --debtor sk1 --creditor root --kind skeptic-verdict --tsv 2>/dev/null)
assert_eq "M4 killed: without the chain-link arm, D1's sk1->root reads void-superseded" "${m4_row%%$'\t'*}" "void-superseded"
# M5: the #1865 bound, neutered (no <since> passed). D5's stale link counts
# again and sk1->root goes back to live.
M5_NEXUS="$WORK/nexus-m5"; cp -R "$FAKE_NEXUS" "$M5_NEXUS"
MUT_F="$M5_NEXUS/monitor/_obligations.sh" python3 - <<'PY' || th_abort "mutant M5 could not be built"
import os
p = os.environ["MUT_F"]; s = open(p).read()
old = 'obl_reviews "$sd" "$odebtor" "$debtor" "$kind" "${_first_open:-$opened_at}"; then\n'
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, 'obl_reviews "$sd" "$odebtor" "$debtor" "$kind"; then\n'))
PY
new_state m5
obl open --debtor old --creditor sk1 --kind skeptic-verdict --round 1 --at "$TSTALE" --by test >/dev/null || th_abort "stale edge"
delivered_reviewer sk1 root
obl open --debtor old --creditor root --kind skeptic-verdict --round 1 --at "$T2" --subject 'root-report' --by test >/dev/null || th_abort "handover edge"
m5_row=$(env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE" "$M5_NEXUS/monitor/obligations.sh" list --all --debtor sk1 --creditor root --kind skeptic-verdict --tsv 2>/dev/null)
assert_eq "M5 killed: without the #1865 bound, D5's sk1->root reads live again" "${m5_row%%$'\t'*}" "live"
# M6: bound by the CURRENT open instead of the FIRST. D7 goes void.
M6_NEXUS="$WORK/nexus-m6"; cp -R "$FAKE_NEXUS" "$M6_NEXUS"
MUT_F="$M6_NEXUS/monitor/_obligations.sh" python3 - <<'PY' || th_abort "mutant M6 could not be built"
import os
p = os.environ["MUT_F"]; s = open(p).read()
old = '"${_first_open:-$opened_at}"; then\n'
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, '"$opened_at"; then\n'))
PY
new_state m6
delivered_reviewer sk1 root
chain_edges sk2 sk1 root "$T2"
obl open --debtor sk1 --creditor root --kind skeptic-verdict --round 2 --at "$(( T2 + 10 ))" --by test >/dev/null || th_abort "re-arm"
OBL_NOW_OVERRIDE=$(( T2 + 20 )) obl note --debtor sk1 --creditor root --verdict --text "round 2 REVISE" >/dev/null || th_abort "verdict"
chain_edges sk3 sk2 root "$T3"
m6_row=$(env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE" "$M6_NEXUS/monitor/obligations.sh" list --all --debtor sk1 --creditor root --kind skeptic-verdict --tsv 2>/dev/null)
assert_eq "M6 killed: bounded by the CURRENT open, D7's sk1->root reads void-superseded" "${m6_row%%$'\t'*}" "void-superseded"

# M7: the tightening D10's comment REJECTS — bound by the first open since the
# record's last settlement. It fixes D10 (void) and breaks D11 (void): the
# ledger cannot tell a reused pair from a settled-and-re-armed one.
M7_NEXUS="$WORK/nexus-m7"; cp -R "$FAKE_NEXUS" "$M7_NEXUS"
MUT_F="$M7_NEXUS/monitor/_obligations.sh" python3 - <<'PY' || th_abort "mutant M7 could not be built"
import os
p = os.environ["MUT_F"]; s = open(p).read()
old = """    awk -F'\\t' '$1 == "opened_at" && $2 ~ /^[0-9]+$/ { if (m == "" || $2 + 0 < m + 0) m = $2 }"""
assert s.count(old) == 1, s.count(old)
new = """    awk -F'\\t' '$1 == "settled_at" && $2 != "" { m = "" }
                 $1 == "opened_at" && $2 ~ /^[0-9]+$/ { if (m == "" || $2 + 0 < m + 0) m = $2 }"""
open(p, "w").write(s.replace(old, new))
PY
m7_state() { env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE" "$M7_NEXUS/monitor/obligations.sh" list --all --debtor sk1 --creditor root --kind skeptic-verdict --tsv 2>/dev/null; }
new_state m7a
obl open --debtor sk1 --creditor root --kind skeptic-verdict --round 1 --at "$TSTALE" --by test >/dev/null || th_abort "earlier-task edge"
obl open --debtor old --creditor sk1 --kind skeptic-verdict --round 1 --at "$(( TSTALE + 10 ))" --by test >/dev/null || th_abort "earlier-task link"
obl settle --debtor old --creditor sk1 --kind skeptic-verdict --reason "earlier task accepted" --by test >/dev/null || th_abort "settle link"
obl settle --debtor sk1 --creditor root --kind skeptic-verdict --reason "earlier task accepted" --by test >/dev/null || th_abort "settle edge"
delivered_reviewer sk1 root
obl open --debtor old --creditor root --kind skeptic-verdict --round 1 --at "$T2" --subject 'root-report' --by test >/dev/null || th_abort "handover edge"
m7a_row=$(m7_state)
assert_eq "M7 (episode bound) closes D10: the reused pair's stale link no longer counts" "${m7a_row%%$'\t'*}" "void-superseded"
new_state m7b
d11_fixture
m7b_row=$(m7_state)
assert_eq "M7 (episode bound) BREAKS D11: a genuine link is dropped and a reviewer still owed is voided" "${m7b_row%%$'\t'*}" "void-superseded"

# ---- the assertion COUNT, compared EXACTLY (#821 axis B) -----------------
EXPECTED_ASSERTIONS=74   # +5: same-pair reuse kept as a residual (D10, D10-CONTROL, D11, M7 x2, #1868 item 3); +15: #1865 stale chain links (D5-D9, M5, M6)
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
