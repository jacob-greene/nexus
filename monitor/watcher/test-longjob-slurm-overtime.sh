#!/usr/bin/env bash
# monitor/watcher/test-longjob-slurm-overtime.sh — a watched Slurm job past its
# --time, and a payload that ended while Slurm still says RUNNING
# (your-org/nexus-code#1841).
#
# `scontrol show config` reported `OverTimeLimit = 2160 min` here: Slurm lets a
# job run 36 h past its --time, so --time is not a bound and a watch on Slurm
# state alone sleeps through it. Two behaviours are pinned:
#
#   * OVERTIME: a RUNNING job whose ElapsedRaw (s) exceeds TimelimitRaw (min)
#     prints ONE `OVERTIME (warned once)` line per watch, never one per poll,
#     and nothing for a job under its limit or with no integer limit
#     (UNLIMITED, blank, an old two-field row);
#   * PAYLOAD RC: `add slurm:<id> --payload-rc FILE` — once FILE holds 0..255
#     that rc ends the watch (`RUNNING after payload end`) while Slurm still
#     says RUNNING; anything else in FILE is REFUSED (unknown → bounded retry
#     → an UNKNOWN emit), never read as a number.
#   * MERGE (#1846 N4): with the launch hook's `auto-slurm-<id>` already live,
#     `add slurm:<id> --payload-rc FILE` attaches FILE to it instead of adding
#     a second watch; the reverse order adds nothing; the stale-rc refusal and
#     a conflicting rc file are still refused.
#
# HERMETIC: NEXUS_STATE_DIR is a temp dir, the session key is pinned, `sacct`
# and `squeue` are PATH-front stubs answering per job id from files, the
# dispatcher is this suite's own child (killed by the pid it recorded). Job ids
# are synthetic (1234567…).
#
# POTENCY: every "no warning" assertion runs on the SAME dispatcher pass set as
# a job that DOES warn, differing only in its Elapsed/Timelimit row.
#
# MUTATION FLIP SET (measured 2026-10-15, monitor/mutation-gate.sh --subject):
#   slurm.sh `(( $1 > $2 * 60 )) || return 0`, --mode delete → killed: O1b, O3
#     and P0 flip (every integer pair is marked);
#   slurm.sh the rc shape `if`, --mode if-false → killed, prediction confirmed:
#     the five P3 cases, P4 and both P8 flip; P2 and O2 do not;
#   longjob-watch.sh the `.overtime_warned=true` write commented out (by hand:
#     the gate does not list that line) → O2 reads 4 lines, not 1.
#   longjob-watch.sh the merge `if` (payload rc given, live watch found),
#     --mode if-false → killed: M1 x4 and M2 x2 flip (a second watch, rc file
#     not attached, no conflict refusal); the reverse-order `if` → killed: the
#     three M4 cases flip. M3 flips in neither, by design: the stale-rc
#     refusal runs BEFORE the merge (#1846 N4, measured 2026-10-15).
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LJ="$REPO_ROOT/monitor/longjob-watch.sh"
WORK=$(mktemp -d -t lj-overtime-XXXXXX)
D=""
cleanup() { [[ -n "$D" ]] && { th_kill_own_child "$D" CONT; th_kill_own_child "$D" TERM; }; rm -rf "$WORK"; }
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"; mkdir -p "$NEXUS_STATE_DIR"
export NEXUS_LONGJOB_KEY="t1"
export MONITOR_LONGJOB_POLL_SECONDS=5 MONITOR_LONGJOB_PROBE_TIMEOUT_SECONDS=10
unset NEXUS_WORKER_WINDOW NEXUS_ORCHESTRATOR_WINDOW NEXUS_LONGJOB_WINDOW CLAUDE_CODE_SESSION_ID NEXUS_LONGJOB_SESSION_ID MONITOR_LONGJOB_ENABLED 2>/dev/null || true
SPOOL="$NEXUS_STATE_DIR/longjob/t1"
FROOT="$WORK/froot"; mkdir -p "$FROOT/monitor"   # no config/load.sh: every knob at its default

# ---- PATH-front stubs: sacct answers per job id ----------------------------
STUB="$WORK/stub"; mkdir -p "$STUB" "$WORK/sacct"
cat > "$STUB/sacct" <<'EOF'
#!/usr/bin/env bash
# `sacct … -j <id>` → the contents of $LJ_SACCT_DIR/<id> (empty when absent).
id=""; while (( $# )); do [[ "$1" == -j ]] && { id="${2:-}"; break; }; shift; done
[[ -n "$id" && -f "$LJ_SACCT_DIR/$id" ]] && cat "$LJ_SACCT_DIR/$id"; exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/squeue"
chmod +x "$STUB/sacct" "$STUB/squeue"
export PATH="$STUB:$PATH" LJ_SACCT_DIR="$WORK/sacct"
row() { printf '%s\n' "$2" > "$WORK/sacct/$1"; }

echo "=== probe: elapsed against the time limit ==="
# shellcheck source=monitor/longjob-probes.d/slurm.sh
. "$REPO_ROOT/monitor/longjob-probes.d/slurm.sh"
row 1234567 'RUNNING|0:0|49920|360'       # 13 h 52 m on a 6 h --time: the #1841 job
row 1234568 'RUNNING|0:0|3600|360'        # 1 h of 6 h
row 1234569 'RUNNING|0:0|49920|UNLIMITED'
row 1234572 'RUNNING|0:0|49920|'
row 1234573 'RUNNING|0:0'                  # a row without the two time fields
got=$(lj_probe_main 1234567 '{}')
assert_contains "O1 elapsed 13h52m > limit 6h00m → running, carries the mark" "$got" "running|RUNNING; PAST ITS --time: elapsed 13h52m > limit 6h00m"
assert_contains "O1 the mark says OverTimeLimit lets it continue" "$got" "OverTimeLimit lets Slurm continue it"
assert_eq "O1b elapsed < limit → plain running, no mark" "$(lj_probe_main 1234568 '{}')" "running|RUNNING"
assert_eq "O1c UNLIMITED limit → no mark" "$(lj_probe_main 1234569 '{}')" "running|RUNNING"
assert_eq "O1d blank limit → no mark" "$(lj_probe_main 1234572 '{}')" "running|RUNNING"
assert_eq "O1e a two-field row → no mark (and still running)" "$(lj_probe_main 1234573 '{}')" "running|RUNNING"
printf 'COMPLETED|0:0|5|10\nRUNNING|0:0|99999|10\n' > "$WORK/sacct/1234574"
assert_contains "O1f an array set with a running row past its limit carries the mark" "$(lj_probe_main 1234574 '{}')" "a running row is PAST ITS --time"
row 1234575 'COMPLETED|0:0|99999|10'
assert_eq "O1g a COMPLETED row is reported as before, its time fields unread" "$(lj_probe_main 1234575 '{}')" "done|COMPLETED exit=0:0"

echo "=== probe: the payload's rc outranks RUNNING ==="
RC="$WORK/rc"
spec=$(jq -cn --arg f "$RC" '{payload_rc:$f}')
row 1234570 'RUNNING|0:0|100|360'
assert_eq "P0 no rc file yet → Slurm's answer" "$(lj_probe_main 1234570 "$spec")" "running|RUNNING"
printf '0\n' > "$RC"
assert_contains "P1 rc 0 while RUNNING → done, RUNNING after payload end" "$(lj_probe_main 1234570 "$spec")" "done|payload rc=0: RUNNING after payload end (Slurm still says RUNNING)"
printf '3\n' > "$RC"
got=$(lj_probe_main 1234570 "$spec")
assert_contains "P2 rc 3 while RUNNING → failed, names the rc" "$got" "failed|payload rc=3: RUNNING after payload end"
assert_contains "P2 suggests scancel of the job" "$got" "scancel 1234570"
for bad in abc '' 999 '-1' '3 4'; do
    printf '%s\n' "$bad" > "$RC"
    assert_contains "P3 rc file '$bad' while RUNNING → unknown, refused" "$(lj_probe_main 1234570 "$spec")" "unknown|payload-rc file $RC holds '$bad', not an exit code"
done
row 1234575 'COMPLETED|0:0|5|10'
printf 'abc\n' > "$RC"
assert_contains "P4 malformed rc beside a terminal Slurm verdict → that verdict, the file IGNORED" "$(lj_probe_main 1234575 "$spec")" "done|COMPLETED exit=0:0; payload-rc file $RC IGNORED"
printf '7\n' > "$RC"
assert_eq "P5 COMPLETED but payload rc 7 → failed" "$(lj_probe_main 1234575 "$spec")" "failed|payload rc=7 (from $RC) although Slurm says COMPLETED exit=0:0"
row 1234576 'PENDING|0:0|0|360'
assert_eq "P6 an rc file beside a PENDING job is not read (stale)" "$(lj_probe_main 1234576 "$spec")" "pending|PENDING"
rm -f "$RC"

echo "=== add --payload-rc: refusals ==="
mkdir -p "$SPOOL/watches"
out=$("$LJ" add slurm:1234570 --id wr1 --payload-rc rel/rc --no-declare --no-first-probe 2>&1); rc=$?
assert_eq "A1 a relative path is refused (rc 2)" "$rc" 2; assert_contains "A1 says absolute" "$out" "must be an absolute path"
printf '0\n' > "$WORK/stale.rc"
out=$("$LJ" add slurm:1234570 --id wr2 --payload-rc "$WORK/stale.rc" --no-declare --no-first-probe 2>&1); rc=$?
assert_eq "A2 an rc file that already exists is refused (rc 2)" "$rc" 2; assert_contains "A2 says stale" "$out" "already exists"
out=$("$LJ" add file:"$WORK/x" --id wr3 --payload-rc "$WORK/new.rc" --no-declare --no-first-probe 2>&1); rc=$?
assert_eq "A3 --payload-rc on a non-slurm subject is refused (rc 2)" "$rc" 2
assert_no_file "A1-A3 no spec was written" "$SPOOL/watches/wr1.json"

echo "=== add --payload-rc MERGES into the hook's auto watch (your-org/nexus-code#1846 N4) ==="
# The launch hook arms `auto-slurm-<id>` the moment it parses an sbatch; the
# agent's `add slurm:<id> --payload-rc F` then used to create a SECOND watch on
# the same job. Both orders are pinned, plus the refusals that must still fire
# with an auto watch in place. No dispatcher is running yet, so every add here
# ends NOT ARMED (rc 3) — which is the contract under test for a merge too.
_hook_add() { "$LJ" add "slurm:$1" --id "auto-slurm-$1" --desc "sbatch (auto-watched by async-launch-detect)" --no-declare --no-first-probe 2>&1; }
_n_on() { jq -r --arg t "$1" 'select(.kind=="slurm" and .target==$t and (.retired != true)) | .id' "$SPOOL"/watches/*.json 2>/dev/null | grep -c .; }
_hook_add 1234580 >/dev/null
out=$("$LJ" add slurm:1234580 --id wm --payload-rc "$WORK/m.rc" --no-declare --no-first-probe 2>&1); rc=$?
assert_eq "M1 auto watch exists → add --payload-rc leaves EXACTLY ONE watch on the job" "$(_n_on 1234580)" 1
assert_eq "M1 …that watch is the hook's, carrying the rc file" "$(jq -r .payload_rc "$SPOOL/watches/auto-slurm-1234580.json")" "$WORK/m.rc"
assert_no_file "M1 …and no second spec was written under the requested id" "$SPOOL/watches/wm.json"
assert_contains "M1 the add says which watch now carries the payload rc" "$out" "merged: slurm:1234580 was already watched by auto-slurm-1234580 — that watch now carries --payload-rc $WORK/m.rc"
assert_eq "M1 the add keeps its verdict contract: rc 3 with no dispatcher" "$rc" 3
assert_contains "M1 …and still prints the dispatcher verdict line" "$out" "dispatcher: NOT ARMED"
out=$("$LJ" add slurm:1234580 --payload-rc "$WORK/m2.rc" --no-declare --no-first-probe 2>&1); rc=$?
assert_eq "M2 a DIFFERENT rc file for an already-carried job is refused (rc 2)" "$rc" 2
assert_contains "M2 …naming the watch and the file it carries" "$out" "already watched by auto-slurm-1234580 carrying a DIFFERENT --payload-rc"
_hook_add 1234581 >/dev/null
printf '0\n' > "$WORK/stale2.rc"
out=$("$LJ" add slurm:1234581 --payload-rc "$WORK/stale2.rc" --no-declare --no-first-probe 2>&1); rc=$?
assert_eq "M3 the stale-rc refusal still fires with an auto watch in place (rc 2)" "$rc" 2
assert_contains "M3 …saying stale" "$out" "already exists"
assert_eq "M3 …and the auto watch was NOT given the stale file" "$(jq -r '.payload_rc // ""' "$SPOOL/watches/auto-slurm-1234581.json")" ""
"$LJ" add slurm:1234582 --id wpr2 --payload-rc "$WORK/m3.rc" --no-declare --no-first-probe >/dev/null 2>&1
out=$(_hook_add 1234582); rc=$?
assert_eq "M4 reverse order: payload watch exists → the hook's add creates no second watch" "$(_n_on 1234582)" 1
assert_no_file "M4 …no auto-slurm spec" "$SPOOL/watches/auto-slurm-1234582.json"
assert_contains "M4 …and says which watch carries the payload rc" "$out" "merged: slurm:1234582 is already watched by wpr2, which carries --payload-rc $WORK/m3.rc"
# Out of the dispatcher's way below: those job ids have no sacct row.
rm -f "$SPOOL"/watches/auto-slurm-123458?.json "$SPOOL/watches/wpr2.json"

echo "=== dispatcher: ONE overtime line per watch; the payload rc ends the watch ==="
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out.txt" 2> "$WORK/err.txt" &
D=$!; disown "$D" 2>/dev/null || true   # no "Terminated" job notice at cleanup
_armed() { [[ "$(jq -r '.service // empty' "$SPOOL/dispatcher.json" 2>/dev/null)" == polling ]]; }
_wait() { local dl=$(( SECONDS + $1 )); shift; until "$@"; do (( SECONDS >= dl )) && return 1; sleep 0.2; done; }
if _wait 30 _armed; then a=ok; else a="not armed: $(cat "$WORK/err.txt")"; fi
assert_eq "rig: the dispatcher armed" "$a" ok
row 1234570 'RUNNING|0:0|100|360'; row 1234571 'RUNNING|0:0|100|360'
"$LJ" add slurm:1234567 --id wot   --interval 5 --no-declare >/dev/null 2>&1
"$LJ" add slurm:1234568 --id wund  --interval 5 --no-declare >/dev/null 2>&1
"$LJ" add slurm:1234569 --id wunl  --interval 5 --no-declare >/dev/null 2>&1
"$LJ" add slurm:1234570 --id wprc  --interval 5 --no-declare --payload-rc "$WORK/p.rc" >/dev/null 2>&1
"$LJ" add slurm:1234571 --id wbad  --interval 5 --no-declare --payload-rc "$WORK/b.rc" --unknown-max 2 >/dev/null 2>&1
assert_eq "D0 add records the payload-rc path in the spec" "$(jq -r .payload_rc "$SPOOL/watches/wprc.json")" "$WORK/p.rc"
# The rc files appear only after the watches are live, as a job's last line would.
printf '3\n' > "$WORK/p.rc"; printf 'abc\n' > "$WORK/b.rc"
_retired() { [[ "$(jq -r .retired "$SPOOL/watches/$1.json" 2>/dev/null)" == true ]]; }
_wait 90 _retired wprc; _wait 90 _retired wbad
# Two more complete passes AFTER the first overtime line, so a per-poll
# re-emit would have had two chances to print.
_wait 60 grep -q 'OVERTIME' "$WORK/out.txt"
_lp() { jq -r '.last_poll // 0' "$SPOOL/dispatcher.json" 2>/dev/null; }
_after() { local l; l=$(_lp); [[ "$l" =~ ^[0-9]+$ ]] && (( l > $1 )) && [[ "$(jq -r '.note // ""' "$SPOOL/dispatcher.json" 2>/dev/null)" == ok ]]; }
t=$(_lp); _wait 60 _after "$t"; t=$(_lp); _wait 60 _after "$t"
n_ot=$(grep -c 'RUNNING wot .*OVERTIME (warned once)' "$WORK/out.txt")
assert_eq "O2 elapsed > limit: exactly ONE overtime line across ≥ 2 later passes" "$n_ot" 1
assert_contains "O2 the line says past its --time and that OverTimeLimit lets it continue" "$(grep 'RUNNING wot ' "$WORK/out.txt")" "OverTimeLimit lets Slurm continue it"
assert_eq "O2 the flag column is set" "$(jq -r .overtime_warned "$SPOOL/watches/wot.json")" true
assert_eq "O2 the watch is NOT retired (overtime is not terminal)" "$(jq -r .retired "$SPOOL/watches/wot.json")" false
assert_eq "O3 elapsed < limit: no line (same passes)" "$(grep -c ' wund ' "$WORK/out.txt")" 0
assert_eq "O4 UNLIMITED limit: no line (same passes)" "$(grep -c ' wunl ' "$WORK/out.txt")" 0
assert_eq "O3/O4 those watches were probed (running), not skipped" "$(jq -r .state "$SPOOL/watches/wund.json") $(jq -r .state "$SPOOL/watches/wunl.json")" "running running"
pl=$(grep 'FAILED wprc ' "$WORK/out.txt")
assert_contains "P7 payload rc 3 while Slurm says RUNNING → a FAILED terminal line" "$pl" "payload rc=3: RUNNING after payload end"
assert_eq "P7 the watch retired terminal" "$(jq -r .retired_reason "$SPOOL/watches/wprc.json")" terminal
bl=$(grep 'UNKNOWN wbad ' "$WORK/out.txt")
assert_contains "P8 a malformed rc file is refused LOUDLY: an UNKNOWN emit naming the content" "$bl" "holds 'abc', not an exit code"
assert_eq "P8 never a DONE/FAILED from a malformed rc" "$(grep -cE '(DONE|FAILED) wbad ' "$WORK/out.txt")" 0
echo "--- what the dispatcher printed:"; sed 's/^/    /' "$WORK/out.txt"
EXPECTED=53
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
