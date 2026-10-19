#!/usr/bin/env bash
# monitor/watcher/test-longjob-watch.sh — the longjob-watch dispatcher, part 1
# (your-org/nexus-code#1535): the five-answer probe contract across every
# shipped subject kind, the dispatcher's emit policy (terminal-only by
# default, transitions on request, dedup, per-watch and per-session caps,
# unknown → bounded retry → UNKNOWN emit, TTL → EXPIRED), the NEVER-EXIT
# property (alive after every watch retired), the emit path recording its
# own failure, the ledger verdicts `status` derives, the declare-wait bridge,
# `await` as the fallback wake, `resolve` for the orphan-async resolver, and
# the resolver's `longjob` arm end to end.
#
# HERMETIC: NEXUS_STATE_DIR is a temp dir, the session key is pinned via
# NEXUS_LONGJOB_KEY, `sacct`/`squeue` are PATH-front stubs driven by a file,
# `async-run.sh` is a stub under a fixture NEXUS_ROOT, the dispatcher is this
# suite's own child (killed by pid it recorded, never by name).
#
# POTENCY CONTROLS (a test asserting "no event was emitted" passes just as
# happily when the emitter was never wired): every negative assertion here
# sits beside a positive one on the SAME rig differing by one flag —
# `--notify terminal` prints nothing on pending→running while
# `--notify transitions` prints exactly one line; the MUTED rig proves the
# cap by printing the cap line and NOT the third event, on a dispatcher that
# was shown to print the first two; and the "alive after all retire" check is
# shown able to fail by killing the dispatcher and re-running the same probe.
#
# MUTATION FLIP SET, predicted BEFORE the first run (monitor/mutation-gate.sh
# --suite <this> --list, then --line N on monitor/longjob-watch.sh):
#   FLIPS   the `retired` jq predicate line (every dispatcher case goes red,
#           the #1 bug this suite was born from); the `unknown` streak
#           comparison `(( streak >= umax ))` (UNKNOWN never emitted);
#           the `EMITTED >= SESSION_MAX_EVENTS` cap line (MUTED never printed
#           AND the third event printed); the `[[ "$new_state" != "$prev" ]]`
#           dedup on persistent watches (duplicate line); `trap '' PIPE`
#           (the closed-stdout rig kills the dispatcher: alive check red);
#           the ttl comparison (EXPIRED never emitted).
#   NO FLIP the `_lj_plugin_log`-style side channels this suite does not read,
#           the `note:` text of a pid: add, the `sed -n '2,110p'` usage arm,
#           and the LEDGER_FRESH_SECONDS +30 slack (this suite's stale ledger
#           is 10 000 s old, far outside any plausible slack) — the last is
#           the deliberate should-NOT-flip case.
#
# SPLIT (your-org/nexus-code#1877): the ledger, kill-switch, single-writer,
# owner (#1623), chaperon back-off (#1728), --for-lead (#1794) and usage cases
# moved VERBATIM to test-longjob-watch-ledger.sh, and the rig both share lives
# in _longjob-watch-rig.sh. The flip set below was predicted for the undivided
# suite; every FLIPS line drives a case that stayed in THIS file.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_longjob-watch-rig.sh
. "$_test_dir/_longjob-watch-rig.sh"
probe() { NEXUS_ROOT="$FROOT" "$LJ" probe "$@"; }

echo "=== probe contract: cmd: exit status vocabulary ==="
[[ "$(probe cmd:'exit 0')" == done\|* ]]    && ok "cmd rc 0 → done"    || bad "cmd rc 0: $(probe cmd:'exit 0')"
[[ "$(probe cmd:'exit 1')" == running\|* ]] && ok "cmd rc 1 → running" || bad "cmd rc 1"
[[ "$(probe cmd:'exit 2')" == failed\|* ]]  && ok "cmd rc 2 → failed"  || bad "cmd rc 2"
[[ "$(probe cmd:'exit 3')" == unknown\|* ]] && ok "cmd rc 3 → unknown" || bad "cmd rc 3"
[[ "$(probe cmd:'exit 7')" == failed\|* ]]  && ok "cmd rc 7 (outside the vocabulary) → failed: the default arm EMITS" || bad "cmd rc 7: $(probe cmd:'exit 7')"
out=$(MONITOR_LONGJOB_PROBE_TIMEOUT_SECONDS=2 probe cmd:'sleep 30')
[[ "$out" == unknown\|*"timed out"* ]] && ok "a probe exceeding the probe timeout → unknown (not running)" || bad "timeout: $out"
[[ "$(probe nosuch:x)" == unknown\|*"no probe for kind"* ]] && ok "an unknown kind → unknown with the reason" || bad "unknown kind: $(probe nosuch:x)"

echo "=== probe contract: slurm via stubbed sacct/squeue ==="
: > "$LJ_SQUEUE_FILE"
for pair in 'COMPLETED|0:0=done' 'FAILED|1:0=failed' 'TIMEOUT|0:0=failed' 'OUT_OF_MEMORY|0:125=failed' 'CANCELLED by 123|0:0=failed' 'NODE_FAIL|0:0=failed' 'RUNNING|0:0=running' 'PENDING|0:0=pending' 'COMPLETING|0:0=running' 'SOME_NEW_STATE|0:0=failed'; do
    row="${pair%=*}"; want="${pair#*=}"
    printf '%s\n' "$row" > "$LJ_SACCT_FILE"
    got=$(probe slurm:12345); [[ "$got" == "$want"\|* ]] && ok "sacct '$row' → $want" || bad "sacct '$row' → $got (want $want)"
done
: > "$LJ_SACCT_FILE"
got=$(probe slurm:12345); [[ "$got" == unknown\|*"no accounting row"* ]] && ok "no sacct row and no squeue row → unknown (never running)" || bad "empty sacct: $got"
printf '12345 PENDING\n' > "$LJ_SQUEUE_FILE"
got=$(probe slurm:12345); [[ "$got" == pending\|*squeue* ]] && ok "no sacct row but squeue PENDING → pending (second source consulted)" || bad "squeue fallback: $got"
# #1744: the second source is `squeue -u` filtered by id, never `squeue -j`.
printf '99 RUNNING\n123450 RUNNING\n12345_[3-9] PENDING\n12345_1 RUNNING\n' > "$LJ_SQUEUE_FILE"
got=$(probe slurm:12345); [[ "$got" == pending\|*squeue* ]] && ok "#1744: an array parent's pending remainder is found in squeue -u output" || bad "#1744 array parent: $got"
got=$(probe slurm:1234); [[ "$got" == unknown\|* ]] && ok "#1744: id 1234 is NOT a prefix match for 123450 / 12345_* (exact id or <id>_/<id>+ only)" || bad "#1744 prefix collision: $got"
printf '77 RUNNING\n12345 RUNNING\n' > "$LJ_SQUEUE_FILE"
got=$(probe slurm:12345); [[ "$got" == running\|*squeue* ]] && ok "#1744: a job on a later squeue -u row is found (filter, not head -1)" || bad "#1744 later row: $got"
: > "$LJ_SQUEUE_FILE"
got=$(probe slurm:abc); [[ "$got" == unknown\|* ]] && ok "a non-numeric slurm target → unknown" || bad "bad jobid: $got"

echo "=== #1727: job id 0 is not a job — never polled, never added ==="
# `sacct -j 0` answers about UNRELATED jobs, so a watch on slurm:0 never reached
# a verdict about the submitted one (~9.5 h stall). The sacct stub logs every
# call; the legit-id row beside it is the potency control for that log.
: > "$LJ_SACCT_CALLS"; : > "$LJ_SACCT_FILE"
got=$(probe slurm:0)
[[ "$got" == unknown\|*"not a Slurm job id"* ]] && ok "#1727 probe slurm:0 → unknown (not a Slurm job id)" || bad "#1727 probe slurm:0: $got"
[[ ! -s "$LJ_SACCT_CALLS" ]] && ok "#1727 probe slurm:0 never runs sacct" || bad "#1727 sacct was polled for job 0: $(cat "$LJ_SACCT_CALLS")"
: > "$LJ_SACCT_CALLS"
probe slurm:123456 >/dev/null
[[ "$(grep -o -e '-j 123456' "$LJ_SACCT_CALLS" | wc -l | tr -d ' ')" == 1 ]] && ok "#1727 CONTROL: probe slurm:123456 polls sacct exactly once (the call log is live)" || bad "#1727 sacct log control: $(cat "$LJ_SACCT_CALLS")"
for _bad_id in 0 007 0_1; do
    _o=$("$LJ" add "slurm:$_bad_id" --id "w1727-bad" --no-first-probe 2>&1); _rc=$?
    [[ $_rc -eq 2 && "$_o" == *"positive Slurm job id"* && ! -e "$SPOOL/watches/w1727-bad.json" ]] \
        && ok "#1727 add slurm:$_bad_id is refused with a clear message (rc 2, no spec written)" || bad "#1727 add slurm:$_bad_id rc=$_rc: $_o"
    rm -f "$SPOOL/watches/w1727-bad.json"   # a wrongly accepted add must not cascade into later status/active counts
done
for _good_id in 123456 123456_3 123456_0 123456+0 123456.0; do
    _o=$("$LJ" add "slurm:$_good_id" --id "w1727-ok" --no-declare --no-first-probe 2>&1); _rc=$?
    [[ ( $_rc -eq 0 || $_rc -eq 3 ) && -f "$SPOOL/watches/w1727-ok.json" ]] \
        && ok "#1727 CONTROL: add slurm:$_good_id is accepted (rc $_rc, spec written)" || bad "#1727 legit id $_good_id refused rc=$_rc: $_o"
    rm -f "$SPOOL/watches/w1727-ok.json"
done
: > "$LJ_SACCT_CALLS"

echo "=== #1629: a Slurm ARRAY is a SET — terminal only when EVERY task is ==="
# sacct -X prints one row per array task; the probe used to read the FIRST row
# only, so the first task's COMPLETED emitted DONE while its siblings ran, and
# after two of them had FAILED 139 (worker-a, 2026-09-23, arrays 4200102/4200101).
: > "$LJ_SQUEUE_FILE"
_arr() { printf '%s\n' "$@" > "$LJ_SACCT_FILE"; probe slurm:4200102; }
got=$(_arr 'COMPLETED|0:0' 'RUNNING|0:0' 'PENDING|0:0')
[[ "$got" == running\|* ]] && ok "#1629 array: first task COMPLETED, a sibling RUNNING → running, never done" || bad "#1629 completed+running: $got"
got=$(_arr 'COMPLETED|0:0' 'COMPLETED|0:0' 'PENDING|0:0')
[[ "$got" == pending\|* ]] && ok "#1629 array: completed tasks + a PENDING remainder → pending, never done" || bad "#1629 completed+pending: $got"
got=$(_arr 'COMPLETED|0:0' 'FAILED|139:0' 'COMPLETED|0:0' 'FAILED|139:0')
[[ "$got" == failed\|*"2 failed"*"FAILED exit=139:0"* ]] && ok "#1629 array: all terminal, two FAILED 139 → failed, naming the count and the first failure" || bad "#1629 failed set: $got"
got=$(_arr 'FAILED|139:0' 'RUNNING|0:0')
[[ "$got" == running\|*"first failure so far: FAILED exit=139:0"* ]] && ok "#1629 array: a failure while siblings still RUN → running (not terminal yet), the failure named" || bad "#1629 failed+running: $got"
got=$(_arr 'COMPLETED|0:0' 'SOME_NEW_STATE|0:0')
[[ "$got" == failed\|* ]] && ok "#1629 array: an UNRECOGNISED member state keeps the default arm → failed" || bad "#1629 unrecognised: $got"
got=$(_arr 'COMPLETED|0:0' 'COMPLETED|0:0' 'COMPLETED|0:0')
[[ "$got" == "done|COMPLETED array/het set of 3 rows: 3 completed, 0 failed, 0 running, 0 pending" ]] && ok "#1629 array: every task COMPLETED → done (control)" || bad "#1629 all completed: $got"
printf 'COMPLETED|0:0\n' > "$LJ_SACCT_FILE"
got=$(probe slurm:12345)
[[ "$got" == "done|COMPLETED exit=0:0" ]] && ok "#1629 a SINGLE-row job prints exactly what it printed before (control)" || bad "#1629 single row: $got"
: > "$LJ_SACCT_FILE"

echo "=== probe contract: asyncrun via stubbed async-run.sh ==="
[[ "$(probe asyncrun:tok-live)" == running\|* ]] && ok "live → running" || bad "asyncrun live"
[[ "$(probe asyncrun:tok-ok)"   == done\|* ]]    && ok "settled rc=0 → done" || bad "asyncrun ok"
[[ "$(probe asyncrun:tok-bad)"  == failed\|* ]]  && ok "settled rc=2 → failed" || bad "asyncrun bad"
[[ "$(probe asyncrun:tok-gone)" == failed\|died* ]] && ok "gone → failed|died (truncated, never done)" || bad "asyncrun gone: $(probe asyncrun:tok-gone)"
[[ "$(probe asyncrun:tok-none)" == unknown\|* ]] && ok "no disposition → unknown" || bad "asyncrun none"

echo "=== probe contract: pid with identity ==="
sleep 300 & SP=$!; DPIDS+=("$SP")
st=$(awk '{print $22}' "/proc/$SP/stat")
[[ "$(probe pid:$SP:$st)" == running\|* ]] && ok "alive pid with matching start-time → running" || bad "pid running"
[[ "$(probe pid:$SP:999)" == done\|*RECYCLED* ]] && ok "alive pid with a DIFFERENT start-time → done (recycled), never running" || bad "pid recycled: $(probe pid:$SP:999)"
[[ "$(probe pid:$SP)" == unknown\|* ]] && ok "a bare occupied pid (no identity) → unknown" || bad "bare pid"
kill "$SP"; wait "$SP" 2>/dev/null
[[ "$(probe pid:$SP:$st)" == done\|*"NOT retained"* ]] && ok "gone pid → done and says the exit status is not retained" || bad "pid gone: $(probe pid:$SP:$st)"

echo "=== probe contract: file predicates ==="
[[ "$(probe file:$WORK/nofile)" == pending\|* ]] && ok "absent file, exists → pending" || bad "file absent"
touch "$WORK/f1"; [[ "$(probe file:$WORK/f1)" == done\|* ]] && ok "present file, exists → done" || bad "file present"
printf 'abc\n' > "$WORK/f2"
[[ "$(probe file:$WORK/f2 --when grew --size0 4)" == running\|* ]] && ok "grew: size == size0 → running" || bad "grew running"
[[ "$(probe file:$WORK/f2 --when grew --size0 1)" == done\|* ]]    && ok "grew: size > size0 → done" || bad "grew done"
[[ "$(probe file:$WORK/f2 --when match --pattern '^ab')" == done\|* ]]  && ok "match: hit → done" || bad "match hit"
[[ "$(probe file:$WORK/f2 --when match --pattern 'zzz')" == running\|* ]] && ok "match: no hit → running" || bad "match miss"
[[ "$(probe file:$WORK/f2 --when match --pattern '(')" == failed\|* ]]   && ok "match: bad regex → failed (cannot evaluate), not silence" || bad "match bad regex: $(probe file:$WORK/f2 --when match --pattern '(')"

echo "=== file match: a FAILURE ARM by default, so an abort wakes the waiter (bundle 21) ==="
# Measured 2026-10-08: a wait on a deploy's success line slept ~2 h while the
# deploy ABORTed. `add --when match` now carries a default failure arm, counted
# only on lines written after `add`; `await` (the unarmed fallback) is the
# end-to-end reader, because it probes the subject from the stored spec.
printf 'start\nold ABORT from yesterday\n' > "$WORK/fa1.log"
out=$("$LJ" add file:"$WORK/fa1.log" --when match --pattern '^stamp ' --id fa1 --interval 5 2>&1)
[[ "$out" == *"first probe: running|"* ]] && ok "fail-arm: an ABORT line written BEFORE add does not fire (first probe running)" || bad "fail-arm pre-add line: $out"
[[ "$out" == *"failure arm: /"*"(the default;"* ]] && ok "fail-arm: add prints the default failure arm it stored" || bad "fail-arm add output: $out"
[[ "$(jq -r .lines0 "$SPOOL/watches/fa1.json")" == 2 && -n "$(jq -r '.fail_pattern // empty' "$SPOOL/watches/fa1.json")" ]] \
    && ok "fail-arm: the spec records lines0=2 and a non-empty fail_pattern" || bad "fail-arm spec: $(jq -c '{lines0,fail_pattern}' "$SPOOL/watches/fa1.json")"
printf 'deploy ABORT: lock held by another build\n' >> "$WORK/fa1.log"
out=$("$LJ" await fa1 --timeout 12 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"FAILURE arm"*"line 3"* ]] && ok "fail-arm: await on a success-only pattern returns FAILED (rc 1) on a new ABORT line, naming it — not a timeout" \
    || bad "fail-arm await: rc=$rc (4 = slept through the abort) $out"
"$LJ" rm fa1 >/dev/null
printf 'stamp v1\nlater ERROR in a cleanup step\n' > "$WORK/fa2.log"
[[ "$(probe file:$WORK/fa2.log --when match --pattern '^stamp ')" == done\|* ]] && ok "fail-arm: a success line BEFORE the failure line → done (first in file order wins)" || bad "fail-arm success-first: $(probe file:$WORK/fa2.log --when match --pattern '^stamp ')"
printf 'deploy ABORT\nstamp v1\n' > "$WORK/fa3.log"
[[ "$(probe file:$WORK/fa3.log --when match --pattern '^stamp ')" == failed\|* ]] && ok "fail-arm: a failure line BEFORE the success line → failed" || bad "fail-arm failure-first: $(probe file:$WORK/fa3.log --when match --pattern '^stamp ')"
# A SHORT custom arm here, not the default: the probe detail is cut at 400
# chars and the default arm's ~190-char ERE is echoed in it, so under a long
# $TMPDIR (a mutation-gate copy) the cut ate the "stamp v1" tail and this case
# went red on an unmutated tree (measured, bundle 23). The claim is about the
# F2 clause, not about the default arm.
[[ "$(probe file:$WORK/fa3.log --when match --pattern '^stamp ' --fail-pattern ABORT)" == *"a success line ALSO appears later, at line 2: stamp v1"* ]] \
    && ok "fail-arm: the LATER success line is SAID in the detail (skeptic F2 on #1784)" || bad "fail-arm F2: $(probe file:$WORK/fa3.log --when match --pattern '^stamp ' --fail-pattern ABORT)"
[[ "$(probe file:$WORK/fa3.log --when match --pattern '^zzz')" != *"ALSO appears later"* ]] \
    && ok "fail-arm: with NO success line, no 'success also appears' claim (control)" || bad "fail-arm F2 control: $(probe file:$WORK/fa3.log --when match --pattern '^zzz')"
[[ "$(probe file:$WORK/fa3.log --when match --pattern '^zzz' --fail-pattern none)" == running\|* ]] && ok "fail-arm: --fail-pattern none drops the arm (running)" || bad "fail-arm none"
[[ "$(probe file:$WORK/fa3.log --when match --pattern '^zzz' --fail-pattern 'BOOM')" == running\|* ]] && ok "fail-arm: a custom --fail-pattern REPLACES the default (ABORT ignored)" || bad "fail-arm custom ignores default"
printf 'BOOM\n' >> "$WORK/fa3.log"
[[ "$(probe file:$WORK/fa3.log --when match --pattern '^zzz' --fail-pattern 'BOOM')" == failed\|* ]] && ok "fail-arm: a custom --fail-pattern fires on its own line" || bad "fail-arm custom fires"
[[ "$(probe file:$WORK/fa3.log --when match --pattern '^zzz' --lines0 99)" == failed\|* ]] && ok "fail-arm: a file SHORTER than lines0 (rotated) is read from line 1" || bad "fail-arm rotation: $(probe file:$WORK/fa3.log --when match --pattern '^zzz' --lines0 99)"
# Skeptic F3 on #1784: Slurm/OOM abort shapes WITHOUT an `error:` prefix,
# which the bundle-21 default left `running`.
for _l in '*** JOB 1234567 ON node01 CANCELLED AT 2026-10-08T10:00:00 DUE TO TIME LIMIT ***' \
          'line 3:  4242 Killed                  python x.py' \
          'slurmstepd: Detected 1 oom-kill event(s) in StepId=1234567.batch' \
          'Detected 1 oom_kill event in StepId=1234567.batch' \
          'State: OUT_OF_MEMORY (exit code 0)'; do
    printf '%s\n' "$_l" > "$WORK/fa7.log"
    [[ "$(probe file:$WORK/fa7.log --when match --pattern '^zzz')" == failed\|* ]] \
        && ok "fail-arm F3: the default fires on '${_l:0:38}…'" || bad "fail-arm F3: $_l → $(probe file:$WORK/fa7.log --when match --pattern '^zzz')"
done
# …and a `set -x` trace line never counts, under the default or a custom arm.
printf '+ grep -q ERROR build.log\n++ echo FATAL\n' > "$WORK/fa8.log"
[[ "$(probe file:$WORK/fa8.log --when match --pattern '^zzz')" == running\|* ]] \
    && ok "fail-arm F3: xtrace lines ('+ grep -q ERROR', '++ echo FATAL') do not fire" || bad "fail-arm xtrace: $(probe file:$WORK/fa8.log --when match --pattern '^zzz')"
[[ "$(probe file:$WORK/fa8.log --when match --pattern '^zzz' --fail-pattern 'FATAL')" == running\|* ]] \
    && ok "fail-arm F3: an xtrace line does not fire a CUSTOM arm either" || bad "fail-arm xtrace custom: $(probe file:$WORK/fa8.log --when match --pattern '^zzz' --fail-pattern 'FATAL')"
printf 'ERROR: real failure\n' >> "$WORK/fa8.log"
[[ "$(probe file:$WORK/fa8.log --when match --pattern '^zzz')" == failed\|*"at line 3"* ]] \
    && ok "fail-arm F3: a real failure AFTER xtrace lines fires, at its own line number (3)" || bad "fail-arm xtrace then real: $(probe file:$WORK/fa8.log --when match --pattern '^zzz')"
# Skeptic N2 on PR #1786: the SUCCESS arm skips xtrace lines too.
printf '+ [[ $st == COMPLETED ]]\n' > "$WORK/fa9.log"
[[ "$(probe file:$WORK/fa9.log --when match --pattern 'COMPLETED' --fail-pattern none)" == running\|* ]] \
    && ok "success arm: an xtrace line naming the success word does NOT read done (skeptic N2)" || bad "success xtrace: $(probe file:$WORK/fa9.log --when match --pattern 'COMPLETED' --fail-pattern none)"
printf 'State: COMPLETED\n' >> "$WORK/fa9.log"
[[ "$(probe file:$WORK/fa9.log --when match --pattern 'COMPLETED' --fail-pattern none)" == done\|*"State: COMPLETED"* ]] \
    && ok "success arm: the real success line after an xtrace line reads done, naming the REAL line" || bad "success after xtrace: $(probe file:$WORK/fa9.log --when match --pattern 'COMPLETED' --fail-pattern none)"
# Bundle 23: the SUCCESS arm is scoped to lines written after `add` too. An OLD
# success line already in an append-only log used to read `done` on the FIRST
# probe — a false wake. `resolve` probes the STORED spec, so it is the reader.
for _fa in default none; do
    _fx=(); [[ "$_fa" == none ]] && _fx=(--fail-pattern none)
    printf 'stamp v0 from yesterday\nother\n' > "$WORK/fs-$_fa.log"
    out=$("$LJ" add file:"$WORK/fs-$_fa.log" --when match --pattern '^stamp ' --id "fs-$_fa" --interval 5 "${_fx[@]}" 2>&1)
    [[ "$out" == *"first probe: running|"* && "$(jq -r .lines0 "$SPOOL/watches/fs-$_fa.json")" == 2 ]] \
        && ok "success arm ($_fa fail arm): a success line written BEFORE add does not read done (first probe running, lines0=2)" \
        || bad "success arm pre-add ($_fa): lines0=$(jq -r .lines0 "$SPOOL/watches/fs-$_fa.json") $out"
    # Skeptic F1 on #1799: not counted must never be SILENT. If that pre-add line
    # is THIS job's own success, a quiet watch waits out its TTL (a lost wake).
    [[ "$out" == *"WARNING: a line matching /^stamp / is ALREADY in $WORK/fs-$_fa.log at line 1, written BEFORE this add"*"monitor/ng longjob rm fs-$_fa"* && "$out" != *"--lines0"* ]] \
        && ok "success arm ($_fa fail arm): add WARNS that a pre-add line (line 1) matches and is not counted, naming a remedy that runs (longjob rm), never add --lines0" \
        || bad "success arm pre-add warning ($_fa): $out"
    [[ "$("$LJ" resolve "fs-$_fa")" == running\|*"PRE-ADD MATCH at line 1"*"stamp v0 from yesterday"*"ng longjob rm"* && "$("$LJ" resolve "fs-$_fa")" != *"--lines0"* ]] \
        && ok "success arm ($_fa fail arm): the running detail names the PRE-ADD MATCH and its line, never 'no line matching … yet'" \
        || bad "success arm pre-add detail ($_fa): $("$LJ" resolve "fs-$_fa")"
    [[ "$("$LJ" resolve "fs-$_fa")" == running\|* ]] \
        && ok "success arm ($_fa fail arm): the stored spec still reads running with only the OLD success line" \
        || bad "success arm resolve pre-append ($_fa): $("$LJ" resolve "fs-$_fa")"
    printf 'stamp v1\n' >> "$WORK/fs-$_fa.log"
    _r=$("$LJ" resolve "fs-$_fa")
    [[ "$_r" == terminal\|done* ]] \
        && ok "success arm ($_fa fail arm): a success line appended AFTER add reads done (must-not-flip control)" \
        || bad "success arm post-append ($_fa): $_r"
    [[ "$_r" == *"stamp v1"* && "$_r" != *"stamp v0"* ]] \
        && ok "success arm ($_fa fail arm): the done detail names the NEW line, never the pre-add one" \
        || bad "success arm post-append detail ($_fa): $_r"
    "$LJ" rm "fs-$_fa" >/dev/null
done
# Must-not-fire control for the F1 warning: no pre-add match, no WARNING.
printf 'other\nunrelated\n' > "$WORK/fs-nw.log"
out=$("$LJ" add file:"$WORK/fs-nw.log" --when match --pattern '^stamp ' --id fs-nw --interval 5 2>&1)
[[ "$out" == *"first probe: running|"* && "$out" != *"WARNING: a line matching"* && "$out" != *"PRE-ADD MATCH"* ]] \
    && ok "success arm: NO pre-add-match warning when nothing before the add matches (control)" || bad "success arm warning control: $out"
"$LJ" rm fs-nw >/dev/null
# Skeptic N1 on #1799: the WARNING's remedy must RUN. The old text said
# "re-add with --lines0 0", which `add` rejects (unknown option) and which a
# text-only assertion could never notice. So EXECUTE the printed command, word
# for word, from the repo root as the agent would.
printf 'stamp v0 from yesterday\n' > "$WORK/fs-rm.log"
out=$("$LJ" add file:"$WORK/fs-rm.log" --when match --pattern '^stamp ' --id fs-rm --interval 5 2>&1)
_rem=''; [[ "$out" =~ (monitor/ng longjob rm [A-Za-z0-9._-]+) ]] && _rem="${BASH_REMATCH[1]}"
_rem_out=''; _rem_rc=none
if [[ -n "$_rem" ]]; then read -r -a _rem_cmd <<<"$_rem"; _rem_out=$(cd "$REPO_ROOT" && "${_rem_cmd[@]}" 2>&1); _rem_rc=$?; fi
[[ "$_rem" == "monitor/ng longjob rm fs-rm" && "$_rem_rc" == 0 && "$_rem_out" == *"removed fs-rm"* && ! -f "$SPOOL/watches/fs-rm.json" ]] \
    && ok "success arm: the WARNING's printed remedy RUNS (rc 0, 'removed fs-rm', the watch is gone)" \
    || bad "success arm remedy run: rem='$_rem' rc=$_rem_rc out=$_rem_out spec=$([[ -f "$SPOOL/watches/fs-rm.json" ]] && echo present || echo gone)"
"$LJ" rm fs-rm >/dev/null 2>&1
# The one-shot probe keeps its deliberate --lines0 0 default (whole file), and
# a file SHORTER than lines0 (rotated) is read from line 1 by the success arm.
printf 'stamp v0\n' > "$WORK/fs-p.log"
[[ "$(probe file:$WORK/fs-p.log --when match --pattern '^stamp ')" == done\|* ]] \
    && ok "success arm: one-shot probe with no --lines0 reads the whole file (deliberate default)" || bad "success probe default"
[[ "$(probe file:$WORK/fs-p.log --when match --pattern '^stamp ' --lines0 1)" == running\|* ]] \
    && ok "success arm: probe --lines0 1 reproduces a watch added now (running)" || bad "success probe lines0=1: $(probe file:$WORK/fs-p.log --when match --pattern '^stamp ' --lines0 1)"
[[ "$(probe file:$WORK/fs-p.log --when match --pattern '^stamp ' --lines0 99)" == done\|* ]] \
    && ok "success arm: a file SHORTER than lines0 (rotated) is read from line 1" || bad "success rotation: $(probe file:$WORK/fs-p.log --when match --pattern '^stamp ' --lines0 99)"
# Line numbers stay ABSOLUTE once the success arm reads from lines0+1: with a
# failure line BEFORE the new success line, the F2 detail names the real line.
printf 'old\nold\nERROR new\nstamp v2\n' > "$WORK/fs-l.log"
# (a short --fail-pattern for the same 400-char-cut reason as the F2 case)
[[ "$(probe file:$WORK/fs-l.log --when match --pattern '^stamp ' --fail-pattern ERROR --lines0 2)" == failed\|*"at line 3"*"at line 4: stamp v2"* ]] \
    && ok "success arm: line numbers stay absolute under lines0 (failure line 3, later success line 4)" \
    || bad "success arm absolute lines: $(probe file:$WORK/fs-l.log --when match --pattern '^stamp ' --fail-pattern ERROR --lines0 2)"
# The xtrace filter is a second grep: a BAD failure pattern must still read as
# rc 2 (cannot evaluate), never as the second grep's "no match".
out=$( . "$REPO_ROOT/monitor/longjob-probes.d/file.sh"; lj_probe_main "$WORK/fa8.log" '{"when":"match","pattern":"zzz","fail_pattern":"(","lines0":0}' )
[[ "$out" == failed\|*"grep rc=2 evaluating the failure arm"* ]] \
    && ok "fail-arm: a bad failure pattern in a stored spec → failed (cannot evaluate), not running" || bad "fail-arm bad stored pattern: $out"
printf 'ERRORS: 0\n0 failed, 12 passed\n' > "$WORK/fa4.log"
[[ "$(probe file:$WORK/fa4.log --when match --pattern '^zzz')" == running\|* ]] && ok "fail-arm: the default does not fire on 'ERRORS: 0' or '0 failed' (control)" || bad "fail-arm benign summary: $(probe file:$WORK/fa4.log --when match --pattern '^zzz')"
"$LJ" add file:"$WORK/fa4.log" --when match --pattern x --fail-pattern '(' --id fa5 >/dev/null 2>&1; rc=$?
(( rc == 2 )) && [[ ! -e "$SPOOL/watches/fa5.json" ]] && ok "fail-arm: an invalid --fail-pattern is refused at add (rc 2), no watch written" || bad "fail-arm invalid: rc=$rc"
"$LJ" add slurm:1234567 --fail-pattern x --id fa6 >/dev/null 2>&1; rc=$?
(( rc == 2 )) && ok "fail-arm: --fail-pattern on a non-file subject → rc 2" || bad "fail-arm on slurm: rc=$rc"

echo "=== dispatch refuses arguments at once (never a silent forever loop) ==="
# bundle-2609: `dispatch --repo x` used to run the dispatcher forever, which
# held test-ng-flag-order.sh's per-sub-verb sweep past a 2400 s ceiling.
out=$(timeout 20 "$LJ" dispatch --repo x 2>&1 </dev/null); rc=$?
(( rc == 2 )) && [[ "$out" == *"takes no arguments"* ]] && ok "dispatch with an argument → rc 2 at once, names the refusal" || bad "dispatch with an argument: rc=$rc (124 = still running at 20 s) out=$out"

echo "=== status/add before any dispatcher: NOT ARMED is said, rc 3 ==="
out=$("$LJ" status 2>&1); rc=$?
(( rc == 3 )) && [[ "$out" == *"dispatcher=absent"* ]] && ok "status: absent ledger → rc 3, says absent" || bad "status absent: rc=$rc $out"
out=$("$LJ" add file:"$WORK/never" --id unarmed 2>&1); rc=$?
(( rc == 3 )) && [[ "$out" == *"WILL NOT WAKE YOU"* && "$out" == *"await unarmed"* ]] && ok "add in an unarmed session: rc 3, says the watch will NOT wake you and names the await fallback" || bad "add unarmed: rc=$rc $out"
"$LJ" rm unarmed >/dev/null

echo "=== add on an UNWRITABLE spool: a loud refusal, NOTHING watched, a runnable fallback (#1724) ==="
# A degraded read-only tree used to give `add: cannot write spec` — no path,
# no reason, rc 2 like a usage slip. The seam is the suite's own: a private
# NEXUS_STATE_DIR whose spool parent (case 1) or watches dir (case 2) is 0555.
_ro="$WORK/rostate"; mkdir -p "$_ro/longjob/k2/watches" "$_ro/heartbeat"; chmod 0555 "$_ro/longjob/k2/watches"
mkdir -p "$_ro/longjob-p"; chmod 0555 "$_ro/longjob-p"
if [[ -w "$_ro/longjob/k2/watches" ]]; then
    printf '  SKIP: a 0555 directory is writable here (root?) — the unwritable-spool cases are unmeasured\n'
else
    printf 'stamp v0\n' > "$WORK/ro.log"
    # case 1: the SPOOL cannot be created (its parent is 0555)
    chmod 0555 "$_ro/longjob"
    out=$(NEXUS_STATE_DIR="$_ro" NEXUS_LONGJOB_KEY=k1 "$LJ" add file:"$WORK/ro.log" --when match --pattern '^stamp ' --id ro1 2>&1); rc=$?
    chmod 0755 "$_ro/longjob"
    (( rc == 2 )) && [[ "$out" == *"add REFUSED — cannot write the spool directory $_ro/longjob/k1/watches: Permission denied"* && "$out" == *"NOTHING IS WATCHED"* ]] \
        && ok "#1724 spool cannot be created: rc 2, names the path and the reason, says NOTHING IS WATCHED" || bad "#1724 case 1: rc=$rc $out"
    [[ ! -e "$_ro/longjob/k1" ]] && ok "#1724 case 1: no spool, no spec was left behind" || bad "#1724 case 1 left: $(ls -R "$_ro/longjob/k1" 2>&1)"
    # case 2: the spool exists, the spec write fails
    out=$(NEXUS_STATE_DIR="$_ro" NEXUS_LONGJOB_KEY=k2 "$LJ" add file:"$WORK/ro.log" --when match --pattern '^stamp ' --id ro2 2>&1); rc=$?
    (( rc == 2 )) && [[ "$out" == *"add REFUSED — cannot write the watch spec $_ro/longjob/k2/watches/ro2.json: Permission denied"* && "$out" == *"shell said:"* && "$out" == *"NOTHING IS WATCHED"* ]] \
        && ok "#1724 spec write fails: rc 2, names the spec path, the reason and the shell's own error text" || bad "#1724 case 2: rc=$rc $out"
    [[ -z "$(ls -A "$_ro/longjob/k2/watches")" && "$out" != *"added ro2"* && "$out" != *"dispatcher:"* ]] \
        && ok "#1724 case 2: nothing recorded, and no 'added' / dispatcher line that could read as success" || bad "#1724 case 2 residue: $(ls -A "$_ro/longjob/k2/watches") $out"
    [[ "$out" == *"run_in_background: true AND timeout: "* && "$out" == *" probe file:"*"--lines0 1"* && "$out" == *"failed) echo \"FAILED"* && "$out" != *"longjob-watch.sh await"* ]] \
        && ok "#1724: the fallback is a probe loop with a FAILED arm (lines0 kept), never \`await\` (which needs a registered watch)" || bad "#1724 fallback text: $out"
    # The printed loop RUNS: a success line written after the refused add ends it DONE, rc 0.
    _loop=$(grep -E '^    d=\$\(\(SECONDS\+' <<<"$out" | sed 's/^    //'); _lf="$WORK/ro-loop.sh"; printf '%s\n' "$_loop" > "$_lf"
    printf 'stamp v1\n' >> "$WORK/ro.log"
    _lo=$(NEXUS_ROOT="$FROOT" timeout 60 bash "$_lf" 2>&1); rc=$?
    (( rc == 0 )) && [[ "$_lo" == "DONE done|"*"stamp v1"* ]] \
        && ok "#1724: the printed fallback loop runs as printed and ends DONE on the NEW success line (rc 0)" || bad "#1724 loop: rc=$rc out=$_lo loop=$_loop"
    # POTENCY: the same add on a WRITABLE spool records the watch (so the refusals above are the 0555, not the command).
    chmod 0755 "$_ro/longjob/k2/watches"
    out=$(NEXUS_STATE_DIR="$_ro" NEXUS_LONGJOB_KEY=k2 "$LJ" add file:"$WORK/ro.log" --when match --pattern '^stamp ' --id ro2 2>&1); rc=$?
    (( rc == 0 || rc == 3 )) && [[ -f "$_ro/longjob/k2/watches/ro2.json" && "$out" != *"REFUSED"* ]] \
        && ok "#1724 POTENCY: the same add on a writable spool records the watch (rc $rc)" || bad "#1724 potency: rc=$rc $out"
fi
chmod -R u+w "$_ro" 2>/dev/null

echo "=== ledger verdicts: dead / stale, from planted ledgers ==="
mkdir -p "$SPOOL"
jq -n '{version:2, service:"polling", pid:999999, pid_start:"1", last_poll:0, active:0, poll_seconds:5, muted:0}' > "$SPOOL/dispatcher.json"
out=$("$LJ" status 2>&1); [[ "$out" == *"dispatcher=dead"* ]] && ok "ledger with a gone pid → dead" || bad "dead: $out"
myst=$(awk '{print $22}' /proc/$$/stat)
jq -n --arg p "$$" --arg s "$myst" '{version:2, service:"polling", pid:($p|tonumber), pid_start:$s, last_poll:(now|floor - 10000), active:0, poll_seconds:5, muted:0}' > "$SPOOL/dispatcher.json"
out=$("$LJ" status 2>&1); [[ "$out" == *"dispatcher=stale"* ]] && ok "ledger with a LIVE pid but a 10 000 s old poll → stale (alive is not polling)" || bad "stale: $out"
rm -f "$SPOOL/dispatcher.json"

echo "=== dispatcher: terminal-only default, transitions on request, unknown parking, TTL, never exit ==="
: > "$LJ_SACCT_FILE"; : > "$LJ_SQUEUE_FILE"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out1.txt" 2> "$WORK/err1.txt" &
D1=$!; DPIDS+=("$D1")
_wait_for 30 _armed "$SPOOL" "$D1" || bad "D1 rig: the dispatcher never armed"
out=$("$LJ" add file:"$WORK/w1" --id w1 --interval 5 --desc "the w1 file" 2>&1); rc=$?
(( rc == 0 )) && [[ "$out" == *"dispatcher: ARMED"* ]] && ok "add with a live dispatcher: rc 0, says ARMED and that ending the turn is safe" || bad "add armed: rc=$rc $out"
[[ "$out" == *"first probe: pending|"* ]] && ok "add runs a synchronous first probe and shows it" || bad "first probe missing: $out"
"$LJ" add cmd:"test -e $WORK/w2 && exit 0; exit 1" --id w2 --interval 5 --notify transitions >/dev/null
"$LJ" add cmd:"test -e $WORK/w3 && exit 0; exit 1" --id w3 --interval 5 >/dev/null
# FREEZE the dispatcher across add w4 → add w5 → status (#1834). w4 parks
# after 2 unknown polls and w5 EXPIRES after its 4 s TTL, so `active_watches=5`
# is true only if no pass runs between their `add` and the `status` read: a
# clock race, not a property of `status`. bundle-1005a widened w5's TTL from
# 1 s to 4 s for exactly this read (PR 1745, `active_watches=4` at 684 s), and
# it failed again at 876 s (zsh jobs-4) and 1005 s (bash 4.4) with the ledger
# saying `armed … polled 2s ago` and `active_watches=4` under a 67% PSI CPU
# stall. A STOPPED dispatcher runs no pass, so the count is exact with no
# deadline; the freeze is a few commands long against the 3×5+30 = 45 s
# staleness window, and w1–w3 (pending/running) cannot retire on their own.
# A pass already running when the STOP lands enumerated its files before w4
# existed, so it cannot probe w4 or w5 when it resumes inside that pass.
kill -STOP "$D1"
[[ "$(awk '{print $3}' "/proc/$D1/stat" 2>/dev/null)" == T ]] && ok "#1834 rig: the dispatcher is frozen (state T) across the add → status window" || bad "#1834 rig: the dispatcher did not stop: $(cat "/proc/$D1/stat" 2>&1)"
"$LJ" add slurm:777 --id w4 --interval 5 --unknown-max 2 >/dev/null
# w5's TTL (4 s) now only has to expire, which it does on the first pass
# after the CONT (the `_wait_for … w5 expired` below); that is what w5 tests.
"$LJ" add cmd:'exit 1' --id w5 --interval 5 --ttl 4 >/dev/null
out=$("$LJ" status)
kill -CONT "$D1"
[[ "$out" == *"dispatcher=armed"* && "$out" == *"active_watches=5"* ]] && ok "status: armed, 5 active" || bad "status armed: $out"
# first poll(s): w2/w3 pending→running (w2 prints, w3 does not), w4 unknown #1,
# w5 expired. w5 sorts last, so the pass that expires it has probed w2 already.
_wait_for 60 _reason_is "$SPOOL" w5 expired
[[ "$(jq -r '.retired_reason' "$SPOOL/watches/w5.json")" == expired ]] && ok "w5 retired: expired" || bad "w5 not yet expired"
# F1 below needs w1 and w2 to go terminal in ONE pass, so the two touches must
# land BETWEEN passes. A pass probes in file order (w1 before w2); a touch that
# lands MID-pass, after w1's probe and before w2's, makes w2 DONE one pass
# AHEAD of w1 — measured on CI as `w1@…938 w2@…933` (#1703), and reproduced
# with a slow probe sorted between them. So wait for the dispatcher's
# pass-END ledger write (note exactly "ok"; mid-pass writes say "mid-pass"),
# after which it sleeps poll_seconds (5) before the next pass starts.
lp0=$(jq -r '.last_poll // 0' "$SPOOL/dispatcher.json" 2>/dev/null); [[ "$lp0" =~ ^[0-9]+$ ]] || lp0=0
edge=0
for _ in $(seq 1 150); do
    read -r lp note < <(jq -r '"\(.last_poll) \(.note)"' "$SPOOL/dispatcher.json" 2>/dev/null) || true
    [[ "${note:-}" == ok && "${lp:-0}" =~ ^[0-9]+$ ]] && (( lp > lp0 )) && { edge=1; break; }
    sleep 0.2
done
(( edge )) || bad "no pass-end ledger write within 30 s: the w1/w2 touches below may land mid-pass (F1 would then be a rig failure, not a pacing one)"
touch "$WORK/w1"; touch "$WORK/w2"
# next poll(s): w1 done, w2 done, w4 unknown #2 → UNKNOWN; wait for the pass END that retired the last of them
_wait_for 90 _retired_settled "$SPOOL" w1 w2 w4 || bad "D1 rig: w1/w2/w4 not all retired and settled within 90 s"
o=$(cat "$WORK/out1.txt")
grep -q '^longjob-watch: DONE w1 | record: monitor/longjob-watch.sh show w1 | file:.* \[desc: the w1 file\] — .*exists$' <<<"$o" && ok "w1: DONE line — pointer FIRST, then subject and desc, detail last" || bad "w1 line: $(grep 'DONE w1' <<<"$o")"
grep -q '^longjob-watch: RUNNING w2 | record: monitor/longjob-watch.sh show w2 | cmd:.*transition pending → running' <<<"$o" && ok "w2 (--notify transitions): pending→running printed" || bad "w2 transition missing"
grep -q '^longjob-watch: DONE w2 ' <<<"$o" && ok "w2: terminal DONE printed" || bad "w2 done missing"
! grep -q 'RUNNING w3' <<<"$o" && ok "w3 (default terminal): pending→running NOT printed — the negative whose positive control is w2 on the same rig" || bad "w3 printed a transition"
grep -q '^longjob-watch: UNKNOWN w4 | record: monitor/longjob-watch.sh show w4 | slurm:777 | PARKED after 2 consecutive unknown probes' <<<"$o" && ok "w4: UNKNOWN emitted after unknown_max=2 consecutive unknowns, watch parked" || bad "w4 unknown: $(grep 'UNKNOWN w4' <<<"$o")"
grep -q '^longjob-watch: EXPIRED w5 ' <<<"$o" && ok "w5: TTL 1 s → EXPIRED emitted" || bad "w5 expired missing"
grep -q '^longjob-watch: EXPIRED w5 | record: monitor/longjob-watch.sh show w5 | cmd:exit 1 | TTL reached' <<<"$o" && ok "F4: the record pointer comes first, then subject and action clause, the detail last" || bad "F4 line order: $(grep 'EXPIRED w5' <<<"$o")"
c=$(grep -c '^longjob-watch: ' <<<"$o"); (( c == 5 )) && ok "exactly 5 lines printed (w1, w2×2, w4, w5)" || bad "line count $c: $o"
[[ "$(jq -r .retired_reason "$SPOOL/watches/w4.json")" == unknown ]] && ok "w4 spec retired_reason=unknown" || bad "w4 spec"
[[ "$(jq -r '.state + "/" + .retired_reason' "$SPOOL/watches/w3.json")" == "running/" ]] && ok "w3 still active, state running (never printed, still tracked)" || bad "w3 spec: $(cat "$SPOOL/watches/w3.json")"
touch "$WORK/w3"; _wait_for 60 _retired_settled "$SPOOL" w3
grep -q '^longjob-watch: DONE w3 ' "$WORK/out1.txt" && ok "w3: DONE printed once its predicate held" || bad "w3 done missing"
# F4: a detail at the probe's own 400-char cap plus a long desc must still fit under the host's 500-char cut
# a 250-char target (in the HEAD) + a 200-char probe detail (the cmd probe's own cap) + a long desc: only the DETAIL may be trimmed
"$LJ" add cmd:"printf '%0400d' 0; exit 2 # $(printf 'x%.0s' $(seq 1 250))" --id w6 --interval 5 --desc "$(printf 'd%.0s' $(seq 1 120))" >/dev/null 2>&1
_wait_for 60 _retired_settled "$SPOOL" w6
l6=$(grep '^longjob-watch: FAILED w6 ' "$WORK/out1.txt"); (( ${#l6} > 0 && ${#l6} <= 480 )) && [[ "$l6" == *"| record: monitor/longjob-watch.sh show w6 |"* ]] && ok "F4: a 250-char target + 200-char detail + 120-char desc composes to ${#l6} chars ≤ 480 with the pointer intact (the head's elements are bounded; the adversarial shapes are in the D3 block)" || bad "F4 long line: ${#l6} chars: ${l6:0:120}…"
act=$("$LJ" status | grep active_watches); [[ "$act" == "active_watches=0" ]] && ok "every watch retired" || bad "$act"
if [[ -d "/proc/$D1" ]]; then ok "NEVER EXIT: dispatcher alive after every watch retired (pid $D1)"; else bad "dispatcher exited after the spool emptied"; fi
[[ -s "$WORK/err1.txt" ]] && bad "dispatcher wrote to stderr: $(head -3 "$WORK/err1.txt")" || ok "dispatcher wrote nothing to stderr"
e=$(grep -c $'\tdone\twritten\t\|\tunknown\twritten\t\|\tfailed\twritten\t' "$SPOOL/events.log"); (( e == 6 )) && ok "events.log records 6 WRITTEN terminal events (w1 w2 w3 w4 w5 w6; the word is written, never delivered — delivery is unobservable here)" || bad "events.log: $(cat "$SPOOL/events.log")"
! grep -q $'\t1\t' "$SPOOL/events.log" && ok "events.log carries no boolean printed=1 anywhere (skeptic F1: a record must not assert a delivery it cannot see)" || bad "a printed=1 row survives"
[[ "$(jq -r '.written' "$SPOOL/dispatcher.json")" == 7 ]] && [[ "$(jq -r '.emitted' "$SPOOL/dispatcher.json")" == null ]] && ok "ledger counts 'written' (7 = 6 terminal + w2's transition) and has no 'emitted' field" || bad "ledger fields: $(jq -c . "$SPOOL/dispatcher.json")"
# F1 pacing: w1 and w2 went terminal in the SAME poll pass; their lines must be ≥ 2 s apart
t1=$(awk -F'\t' '$2=="w1" && $3=="done"{print $1}' "$SPOOL/events.log"); t2=$(awk -F'\t' '$2=="w2" && $3=="done"{print $1}' "$SPOOL/events.log")
(( t2 - t1 >= 2 )) && ok "F1: two lines from ONE poll pass are paced ≥ 2 s apart (w1@$t1, w2@$t2) — the host's bucket refills 1 per 2 s, so a burst can never drain it" || bad "F1 pacing: w1@$t1 w2@$t2"
kill "$D1"; wait "$D1" 2>/dev/null
if [[ ! -d "/proc/$D1" ]]; then ok "POTENCY: the alive check reads a killed dispatcher as gone" ; else bad "alive check cannot fail"; fi
out=$("$LJ" status 2>&1); [[ "$out" == *"dispatcher=dead"* ]] && ok "status after the kill → dead" || bad "status dead: $out"

echo "=== dispatcher: persistent watch, dedup, per-watch cap, session cap + unmute ==="
export NEXUS_LONGJOB_KEY="t2"; SPOOL2="$NEXUS_STATE_DIR/longjob/t2"
NEXUS_ROOT="$FROOT" MONITOR_LONGJOB_SESSION_MAX_EVENTS=2 "$LJ" dispatch > "$WORK/out2.txt" 2> "$WORK/err2.txt" &
D2=$!; DPIDS+=("$D2"); _wait_for 30 _armed "$SPOOL2" "$D2" || bad "D2 rig: the dispatcher never armed"
# p1: persistent, level-triggered: failed while $WORK/down exists, running otherwise.
# Each step waits for ONE complete pass, begun after the change, that probed p1.
"$LJ" add cmd:"test -e $WORK/down && exit 2; exit 1" --id p1 --interval 5 --persistent >/dev/null
_poll_after "$SPOOL2" p1                          # poll 1: running (no print: not a transition from failed)
touch "$WORK/down"; _poll_after "$SPOOL2" p1      # poll 2: running→failed → print #1
_poll_after "$SPOOL2" p1                          # poll 3: failed again → DEDUP, no print
rm -f "$WORK/down"; _poll_after "$SPOOL2" p1      # poll 4: failed→running → print #2 (recovery)
touch "$WORK/down"; _poll_after "$SPOOL2" p1      # poll 5: running→failed → would be print #3 → SESSION CAP → MUTED line
o=$(cat "$WORK/out2.txt")
(( $(grep -c '^longjob-watch: FAILED p1 ' <<<"$o") == 1 )) && ok "persistent: running→failed printed exactly once (dedup on the repeated failed poll)" || bad "p1 failed count: $o"
grep -q '^longjob-watch: RUNNING p1 .*transition failed → running' <<<"$o" && ok "persistent: failed→running recovery printed" || bad "p1 recovery missing: $o"
grep -q '^longjob-watch: MUTED — this session.s event cap (2) is reached' <<<"$o" && ok "session cap: the MUTED line is printed once the cap is reached" || bad "muted line missing: $o"
(( $(grep -c '^longjob-watch: ' <<<"$o") == 3 )) && ok "exactly 3 lines: two events then the cap notice — the third event was NOT delivered" || bad "line count: $o"
grep -q $'\tfailed\tmuted\t' "$SPOOL2/events.log" && ok "the suppressed event is in events.log as muted" || bad "events.log lacks muted row: $(cat "$SPOOL2/events.log")"
[[ "$(jq -r .muted "$SPOOL2/dispatcher.json")" == 1 ]] && ok "ledger muted=1" || bad "ledger not muted"
"$LJ" status >/dev/null 2>&1; rc=$?; (( rc == 3 )) && ok "status while muted → rc 3 (not armed-and-well)" || bad "status muted rc=$rc"
# your-org/nexus-code#1790: this used to be `unmute; rm down` back to back,
# then a fixed number of polls. The unmute flag is read at the START of a pass
# and the subject is probed LATER in it, so when both landed inside one pass
# (after the flag check, before the probe) the recovery was probed while still
# muted — logged `muted`, never printed — and stored as `running`; the next
# pass cleared the mute but saw running → running, no transition, and nothing
# was ever printed again. The fix ORDERS the two by an EVENT: change the
# subject only once events.log says the flag was consumed. The deadlines are
# backstops that turn a hang into a red, never the mechanism. The "#1790
# forced interleaving" case below shows the old order failing and this one not.
_unmute_events() { grep -c $'\tdispatcher\tunmute\t' "$1/events.log" 2>/dev/null; }
_unmute_seen() { (( $(_unmute_events "$1") > $2 )); }
_n0=$(_unmute_events "$SPOOL2")
"$LJ" unmute >/dev/null
_wait_for 120 _unmute_seen "$SPOOL2" "$_n0" \
    || bad "post-unmute: the dispatcher never consumed the unmute flag (backstop 120 s): flag=$([ -f "$SPOOL2/unmute.flag" ] && echo still-present || echo consumed) now=$(date -u +%s)"
rm -f "$WORK/down"
# the recovery line must appear AFTER the MUTED line (order, not just presence)
_after_mute() { awk '/^longjob-watch: MUTED/{m=NR} /^longjob-watch: RUNNING p1 .*transition failed → running/{r=NR} END{exit !(m>0 && r>m)}' "$WORK/out2.txt"; }
_wait_for 120 _after_mute
# The diagnostic leads with flag= and now=: the CI runner truncates a long
# line, and #1790's copy lost exactly those two fields.
_after_mute && ok "after unmute the next transition is delivered again (a RUNNING line after the MUTED line)" || bad "post-unmute: flag=$([ -f "$SPOOL2/unmute.flag" ] && echo still-present || echo consumed) now=$(date -u +%s) ledger=$(jq -c '{muted,written,note,last_poll}' "$SPOOL2/dispatcher.json") events=$(cut -f1-4 "$SPOOL2/events.log" | tail -8 | tr '\n' '|') out2=$(tr '\n' '|' < "$WORK/out2.txt" | cut -c1-200)"
[[ -d "/proc/$D2" ]] && ok "persistent watch never retires and the dispatcher is still alive" || bad "D2 gone"
# per-watch cap on a fresh, unmuted dispatcher
kill "$D2"; wait "$D2" 2>/dev/null

echo "=== #1790 forced interleaving: unmute + subject change inside ONE pass ==="
# The deterministic reproduction for the post-unmute flake above. q1's probe
# BLOCKS while $WORK/r-hold exists (after touching r-blocked), so the case can
# act while the dispatcher is provably INSIDE a pass, past its flag check.
# OLD order (`unmute; change subject`, both mid-pass): the change is probed
# while still muted, logged `muted`, stored — and the pass that then clears
# the mute sees no transition, so the line is LOST for good. NEW order (change
# the subject only once events.log shows the flag consumed): delivered. Every
# wait keys on an event; the backstops only turn a hang into a red.
export NEXUS_LONGJOB_KEY="t2r"; SPOOLR="$NEXUS_STATE_DIR/longjob/t2r"
NEXUS_ROOT="$FROOT" MONITOR_LONGJOB_SESSION_MAX_EVENTS=1 "$LJ" dispatch > "$WORK/outr.txt" 2>/dev/null &
DR=$!; DPIDS+=("$DR")
_wait_for 60 test -f "$SPOOLR/dispatcher.json" || bad "#1790 rig: the dispatcher never wrote its ledger"
# The hold is BOUNDED (80 × 0.1 s, under the 10 s probe timeout): a case that
# dies mid-hold must not leave a probe spinning.
"$LJ" add cmd:"if [ -e $WORK/r-hold ]; then : > $WORK/r-blocked; n=0; while [ -e $WORK/r-hold ] && [ \$n -lt 80 ]; do sleep 0.1; n=\$((n+1)); done; fi; test -e $WORK/r-down && exit 2; exit 1" \
    --id q1 --interval 5 --persistent >/dev/null
_q1_state() { [[ "$(jq -r .state "$SPOOLR/watches/q1.json" 2>/dev/null)" == "$1" ]]; }
_outr_count() { grep -c "$1" "$WORK/outr.txt"; }
_outr_has() { (( $(_outr_count "$1") >= $2 )); }
_q1_probed_since() { (( $(jq -r .last_probe "$SPOOLR/watches/q1.json" 2>/dev/null) > $1 )); }
_q1_hold() {   # block q1's NEXT probe and return once the dispatcher is inside it
    rm -f "$WORK/r-blocked"; touch "$WORK/r-hold"
    _wait_for 60 test -e "$WORK/r-blocked" || bad "#1790 rig: q1's probe never reached the hold"
}
_wait_for 60 _q1_state running || bad "#1790 rig: q1 never probed running"
touch "$WORK/r-down"; _wait_for 60 _outr_has '^longjob-watch: FAILED q1 ' 1 || bad "#1790 rig: FAILED #1 never printed"
rm -f "$WORK/r-down"; _wait_for 60 _outr_has '^longjob-watch: MUTED' 1 || bad "#1790 rig: never muted (cap 1)"
# --- OLD order, forced: both actions land after the flag check of ONE pass.
# (reads BEFORE the hold: the window between r-blocked and the release must
# stay well inside the hold's 8 s bound)
_lp=$(jq -r .last_probe "$SPOOLR/watches/q1.json"); _n0=$(_unmute_events "$SPOOLR")
_q1_hold
"$LJ" unmute >/dev/null; touch "$WORK/r-down"
rm -f "$WORK/r-hold"
_wait_for 60 _unmute_seen "$SPOOLR" "$_n0" || bad "#1790 old order: flag never consumed"
_wait_for 60 _q1_probed_since "$_lp" || bad "#1790 old order: q1 never probed again"
_lp=$(jq -r .last_probe "$SPOOLR/watches/q1.json")
_wait_for 60 _q1_probed_since "$_lp"   # one more full pass, now UNMUTED
(( $(awk '/^longjob-watch: MUTED/{m=1} m && /^longjob-watch: FAILED q1 /{n++} END{print n+0}' "$WORK/outr.txt") == 0 )) \
    && grep -q $'\tq1\tfailed\tmuted\t' "$SPOOLR/events.log" \
    && ok "#1790 forced: the OLD order (unmute + change in one pass) LOSES the transition — logged muted, never printed, even after the mute cleared" \
    || bad "#1790 forced old order: the reproduction did not reproduce: out=$(tr '\n' '|' < "$WORK/outr.txt" | cut -c1-300) events=$(cut -f2-4 "$SPOOLR/events.log" | tail -6 | tr '\n' '|')"
# Re-mute: the fresh budget (1) is spent by the next line, the one after trips the cap.
rm -f "$WORK/r-down"; _wait_for 60 _outr_has '^longjob-watch: RUNNING q1 ' 1 || bad "#1790 rig: RUNNING after the unmute never printed"
touch "$WORK/r-down"; _wait_for 60 _outr_has '^longjob-watch: MUTED' 2 || bad "#1790 rig: never re-muted"
# --- NEW order, under the SAME forced block: the change waits for the event.
_n0=$(_unmute_events "$SPOOLR")
_q1_hold
"$LJ" unmute >/dev/null
rm -f "$WORK/r-hold"
_wait_for 60 _unmute_seen "$SPOOLR" "$_n0" || bad "#1790 new order: flag never consumed"
rm -f "$WORK/r-down"
_running_after_last_mute() { awk '/^longjob-watch: MUTED/{m=NR} /^longjob-watch: RUNNING q1 .*transition failed → running/{r=NR} END{exit !(m>0 && r>m)}' "$WORK/outr.txt"; }
_wait_for 60 _running_after_last_mute
_running_after_last_mute \
    && ok "#1790 forced: the NEW order (change the subject only after the unmute event) delivers the transition under the same forced block" \
    || bad "#1790 forced new order: flag=$([ -f "$SPOOLR/unmute.flag" ] && echo still-present || echo consumed) now=$(date -u +%s) events=$(cut -f2-4 "$SPOOLR/events.log" | tail -6 | tr '\n' '|') out=$(tr '\n' '|' < "$WORK/outr.txt" | cut -c1-300)"
kill "$DR"; wait "$DR" 2>/dev/null; rm -f "$WORK/r-hold" "$WORK/r-down" "$WORK/r-blocked"
export NEXUS_LONGJOB_KEY="t3"; SPOOL3="$NEXUS_STATE_DIR/longjob/t3"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out3.txt" 2>/dev/null &
D3=$!; DPIDS+=("$D3"); _wait_for 30 _armed "$SPOOL3" "$D3" || bad "t3 rig: the dispatcher never armed"
rm -f "$WORK/down"
"$LJ" add cmd:"test -e $WORK/down && exit 2; exit 1" --id c1 --interval 5 --persistent --max-events 1 >/dev/null
_poll_after "$SPOOL3" c1; touch "$WORK/down"; _poll_after "$SPOOL3" c1; rm -f "$WORK/down"
_wait_for 90 _retired_settled "$SPOOL3" c1   # the second transition trips the cap and retires c1
o=$(cat "$WORK/out3.txt")
(( $(grep -c '^longjob-watch: ' <<<"$o") == 1 )) && ok "per-watch cap 1: the first transition printed, the second suppressed" || bad "watch cap: $o"
[[ "$(jq -r .retired_reason "$SPOOL3/watches/c1.json")" == event-cap ]] && ok "watch retired with reason event-cap" || bad "cap retire reason: $(jq -c . "$SPOOL3/watches/c1.json")"
grep -q $'\tcapped\t' "$SPOOL3/events.log" && ok "the capped transition is logged as capped" || bad "no capped row"
echo "=== F7: agent watches are emitted before auto-* watches, whatever the alphabet says ==="
export NEXUS_LONGJOB_KEY="t7"; SPOOL7="$NEXUS_STATE_DIR/longjob/t7"
# both specs exist BEFORE the dispatcher starts, so its first pass sees both at once
"$LJ" add cmd:'exit 0' --id auto-slurm-1 --interval 5 --no-declare >/dev/null 2>&1   # sorts FIRST alphabetically
"$LJ" add cmd:'exit 0' --id zz-mine --interval 5 >/dev/null 2>&1                    # the agent's own, sorts LAST
NEXUS_ROOT="$FROOT" MONITOR_LONGJOB_SESSION_MAX_EVENTS=1 "$LJ" dispatch > "$WORK/out7.txt" 2>/dev/null &
D7=$!; DPIDS+=("$D7"); _wait_for 60 _retired_settled "$SPOOL7" auto-slurm-1 zz-mine
grep -q '^longjob-watch: DONE zz-mine ' "$WORK/out7.txt" && ! grep -q '^longjob-watch: DONE auto-slurm-1 ' "$WORK/out7.txt" && ok "F7: with a budget of 1 the agent's watch got the line and the auto-* one was muted" || bad "F7: $(cat "$WORK/out7.txt")"
kill "$D7"; wait "$D7" 2>/dev/null
echo "=== F6: a fatal error inside a poll pass does not kill the dispatcher ==="
export NEXUS_LONGJOB_KEY="t8"; SPOOL8="$NEXUS_STATE_DIR/longjob/t8"; mkdir -p "$SPOOL8/watches"
# a spec with a NON-NUMERIC interval (valid JSON, id matches the file) — the shape the skeptic measured killing the dispatcher on its first poll
jq -n '{id:"bad1", kind:"cmd", target:"exit 1", desc:"", session_key:"t8", added_at:0, interval:"abc", ttl:604800, notify:"terminal", persistent:false, max_events:8, unknown_max:5, when:"", pattern:"", size0:0, state:"pending", detail:"", last_probe:0, unknown_streak:0, events:0, retired:false, retired_reason:"", retired_at:0}' > "$SPOOL8/watches/bad1.json"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out8.txt" 2>/dev/null &
D8=$!; DPIDS+=("$D8"); _wait_for 60 _settled "$SPOOL8" bad1 0   # bad1 probed (last_probe was 0) and that pass ENDED
[[ -d "/proc/$D8" ]] && ok "F6: dispatcher alive after polling a spec with interval=\"abc\"" || bad "F6: dispatcher died on a non-numeric field"
grep -q $'\tcorrupt\t' "$SPOOL8/events.log" && ok "F6: the bad field is logged as corrupt and defaulted" || bad "F6 no corrupt row: $(cat "$SPOOL8/events.log")"
[[ "$(jq -r .note "$SPOOL8/dispatcher.json")" == ok ]] && ok "F6: the pass completed (ledger note ok) — validation, not the subshell, handled it" || bad "F6 note: $(jq -r .note "$SPOOL8/dispatcher.json")"
# the subshell isolation itself, with a POTENCY control: a pass that dies fatally leaves the loop alive
"$LJ" add cmd:'exit 0' --id ok1 --interval 5 >/dev/null 2>&1; _wait_for 60 grep -q '^longjob-watch: DONE ok1 ' "$WORK/out8.txt"
grep -q '^longjob-watch: DONE ok1 ' "$WORK/out8.txt" && ok "F6: a later, healthy watch is still served" || bad "F6: ok1 not served"
kill "$D8"; wait "$D8" 2>/dev/null
kill "$D3"; wait "$D3" 2>/dev/null

echo "=== the emit path records its own failure (stdout closed) ==="
export NEXUS_LONGJOB_KEY="t4"; SPOOL4="$NEXUS_STATE_DIR/longjob/t4"
NEXUS_ROOT="$FROOT" "$LJ" dispatch >&- 2>/dev/null &
D4=$!; DPIDS+=("$D4"); _wait_for 30 _armed "$SPOOL4" "$D4" || bad "t4 rig: the dispatcher never armed"
"$LJ" add cmd:'exit 0' --id e1 --interval 5 >/dev/null 2>&1
_ef_ge1() { local n; n=$(jq -r '.emit_failures // 0' "$1/dispatcher.json" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )); }
_wait_for 60 _ef_ge1 "$SPOOL4"   # the failed write is counted in the ledger AFTER the write; a dead dispatcher never gets here
[[ -d "/proc/$D4" ]] && ok "a CLOSED stdout does not kill the dispatcher (SIGPIPE ignored, printf rc read)" || bad "dispatcher died on closed stdout"
[[ "$(jq -r .emit_failures "$SPOOL4/dispatcher.json")" -ge 1 ]] && ok "ledger emit_failures ≥ 1" || bad "emit_failures: $(cat "$SPOOL4/dispatcher.json")"
grep -q 'EMIT-FAILED' "$SPOOL4/emit-failures.log" && ok "emit-failures.log names the undelivered line" || bad "emit-failures.log: $(cat "$SPOOL4/emit-failures.log" 2>&1)"
out=$("$LJ" status 2>&1); [[ "$out" == *"EMIT FAILURES"* ]] && ok "status surfaces the emit failures" || bad "status no emit failures: $out"
kill "$D4"; wait "$D4" 2>/dev/null

echo "=== …and a stdout whose READER has gone (SIGPIPE, the case a closed fd cannot reach) ==="
# `>&-` above yields EBADF on write — an rc, no signal — so it exercises the
# rc check and NOT `trap '' PIPE`. Measured: deleting the trap left every case
# above green (subject mutation M4). A pipe whose reader exited is the signal
# path: without the trap bash dies of SIGPIPE on the first emit.
export NEXUS_LONGJOB_KEY="t4p"; SPOOL4P="$NEXUS_STATE_DIR/longjob/t4p"
mkfifo "$WORK/pipe4"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/pipe4" 2>/dev/null &
D4P=$!; DPIDS+=("$D4P")
sleep 1 < "$WORK/pipe4"          # a reader opens the pipe for one second, then leaves
sleep 1
"$LJ" add cmd:'exit 0' --id p1 --interval 5 >/dev/null 2>&1
_wait_for 60 _ef_ge1 "$SPOOL4P"
[[ -d "/proc/$D4P" ]] && ok "an emit into a pipe with NO reader does not kill the dispatcher (trap '' PIPE)" || bad "dispatcher died of SIGPIPE (rc would be 141)"
[[ "$(jq -r .emit_failures "$SPOOL4P/dispatcher.json" 2>/dev/null)" -ge 1 ]] && ok "…and the EPIPE write is counted as an emit failure" || bad "emit_failures after SIGPIPE: $(cat "$SPOOL4P/dispatcher.json" 2>&1)"
kill "$D4P" 2>/dev/null; wait "$D4P" 2>/dev/null

echo "=== declare-wait bridge + resolve + the orphan-async longjob arm ==="
export NEXUS_LONGJOB_KEY="t5" NEXUS_WORKER_WINDOW="lj-win"; SPOOL5="$NEXUS_STATE_DIR/longjob/t5"
HB="$NEXUS_STATE_DIR/heartbeat/lj-win.json"
jq -n '{window:"lj-win", session_id:"11111111-2222-3333-4444-555555555555", state:"idle", external_waits:[]}' > "$HB"
"$LJ" add cmd:'exit 1' --id b1 --interval 5 >/dev/null 2>&1
[[ "$(jq -r '.external_waits[] | select(.kind=="longjob") | .id' "$HB")" == b1 ]] && ok "add declares an external wait kind=longjob id=<watch id> in the window's heartbeat" || bad "declare-wait: $(cat "$HB")"
[[ "$("$LJ" resolve b1)" == running\|* ]] && ok "resolve b1 (rc 1 probe) → running" || bad "resolve running: $("$LJ" resolve b1)"
"$LJ" add cmd:'exit 0' --id b2 --interval 5 >/dev/null 2>&1
[[ "$("$LJ" resolve b2)" == terminal\|done* ]] && ok "resolve b2 (rc 0 probe) → terminal|done" || bad "resolve terminal: $("$LJ" resolve b2)"
[[ "$("$LJ" resolve nope)" == unresolvable\|* ]] && ok "resolve of an unknown id → unresolvable" || bad "resolve nope"
# the resolver arm, driven through the REAL _orphan_async_resolve with a session-id-keyed spool
export NEXUS_LONGJOB_KEY="sid-11111111-2222-3333-4444-555555555555"
"$LJ" add cmd:'exit 0' --id r1 --interval 5 >/dev/null 2>&1
unset NEXUS_LONGJOB_KEY
STATE_DIR="$NEXUS_STATE_DIR"; export STATE_DIR
NEXUS_ROOT="$REPO_ROOT"; export NEXUS_ROOT
# shellcheck source=monitor/watcher/_orphan_async.sh
. "$_test_dir/_orphan_async.sh"
got=$(_orphan_async_resolve longjob r1 lj-win)
[[ "$got" == terminal\|done* ]] && ok "_orphan_async_resolve longjob → terminal via the heartbeat's session_id-keyed spool" || bad "resolver arm: $got"
got=$(_orphan_async_resolve longjob r-none lj-win)
[[ "$got" == unresolvable\|* ]] && ok "resolver arm: unknown watch → unresolvable (never terminal, never running)" || bad "resolver arm none: $got"
export NEXUS_LONGJOB_KEY="t5"
# retirement removes the wait: run a dispatcher on t5 and let b2 retire
NEXUS_ROOT="$FROOT" "$LJ" dispatch >/dev/null 2>&1 &
D5=$!; DPIDS+=("$D5")
# (the wait helper _retired_settled is defined at the top, #1317)
for i in $(seq 1 120); do _retired_settled "$SPOOL5" b2 && break; sleep 0.5; done
[[ -z "$(jq -r '.external_waits[] | select(.id=="b2") | .id' "$HB")" ]] && ok "retiring b2 removed its external wait" || bad "wait b2 still declared: $(cat "$HB")"
[[ "$(jq -r '.external_waits[] | select(.id=="b1") | .id' "$HB")" == b1 ]] && ok "the still-running b1 wait is still declared" || bad "b1 wait gone"
echo "=== F3: a NON-terminal retirement keeps the external wait (the backstop) ==="
"$LJ" add cmd:'exit 1' --id b3 --interval 5 --ttl 1 >/dev/null 2>&1
"$LJ" add cmd:'exit 3' --id b4 --interval 5 --unknown-max 1 >/dev/null 2>&1
for i in $(seq 1 120); do _retired_settled "$SPOOL5" b3 b4 && break; sleep 0.5; done   # was `sleep 7` (#1317; see _retired_settled)
[[ "$(jq -r .retired_reason "$SPOOL5/watches/b3.json")" == expired && "$(jq -r '.external_waits[] | select(.id=="b3") | .id' "$HB")" == b3 ]] && ok "F3: TTL expiry retires the WATCH but keeps the WAIT declared" || bad "F3 expired: $(jq -c . "$SPOOL5/watches/b3.json") waits=$(jq -c .external_waits "$HB")"
[[ "$(jq -r .retired_reason "$SPOOL5/watches/b4.json")" == unknown && "$(jq -r '.external_waits[] | select(.id=="b4") | .id' "$HB")" == b4 ]] && ok "F3: an unknown park keeps the wait declared too" || bad "F3 unknown: waits=$(jq -c .external_waits "$HB")"
[[ "$("$LJ" resolve b3)" == running\|* ]] && ok "F3: resolve on an expired watch probes the SUBJECT live (running), not the park" || bad "F3 resolve b3: $("$LJ" resolve b3)"
kill "$D5"; wait "$D5" 2>/dev/null

echo "=== await: the fallback wake (rc 0 / 1 / 4) ==="
export NEXUS_LONGJOB_KEY="t6"
"$LJ" add file:"$WORK/aw1" --id aw1 --interval 2 >/dev/null 2>&1
( sleep 3; touch "$WORK/aw1" ) &
"$LJ" await aw1 --timeout 30 >/dev/null; rc=$?; (( rc == 0 )) && ok "await → 0 when the file appears" || bad "await done rc=$rc"
"$LJ" add cmd:'exit 2' --id aw2 --interval 2 >/dev/null 2>&1
"$LJ" await aw2 --timeout 30 >/dev/null; rc=$?; (( rc == 1 )) && ok "await → 1 on failed" || bad "await failed rc=$rc"
"$LJ" add cmd:'exit 1' --id aw3 --interval 2 >/dev/null 2>&1
"$LJ" await aw3 --timeout 3 >/dev/null; rc=$?; (( rc == 4 )) && ok "await → 4 on timeout (never a silent 0)" || bad "await timeout rc=$rc"
# await has its OWN unknown-streak loop (a copy of the dispatcher's policy): a
# subject mutation of the dispatcher's `(( streak >= umax ))` first landed on
# THIS copy and the suite stayed green — because nothing drove it. Now it does.
"$LJ" add cmd:'exit 3' --id aw4 --interval 1 --unknown-max 2 >/dev/null 2>&1
"$LJ" await aw4 --timeout 20 >/dev/null; rc=$?; (( rc == 3 )) && ok "await → 3 after unknown_max consecutive unknown probes (parked, never 0 and never a hang)" || bad "await unknown rc=$rc"

echo "=== #1685: the fallback fits the harness's background time limit (default 30 min, ceiling 2 h) ==="
# Claude Code 2.1.285+ STOPS a run_in_background call at the call's own
# `timeout` and hands the agent a stop notice instead of await's typed rc. The
# printed fallback must therefore carry a Bash `timeout` that covers --timeout,
# fit the DEFAULT when the agent sets nothing, and refuse what no call can hold.
export NEXUS_LONGJOB_KEY="t1685"
LJ0=(env -u BASH_DEFAULT_TIMEOUT_MS -u BASH_MAX_TIMEOUT_MS "$LJ")   # the host defaults, whatever this shell carries
out=$("${LJ0[@]}" add file:"$WORK/never1685" --id fb1685 2>&1); rc=$?
ms=$(sed -n 's/.*run_in_background: true AND timeout: \([0-9][0-9]*\).*/\1/;T;p;q' <<<"$out")   # first match; no early-exit reader
s=$(sed -n 's/.*await fb1685 --timeout \([0-9][0-9]*\).*/\1/;T;p;q' <<<"$out")
if (( rc == 3 )) && [[ "$ms" =~ ^[0-9]+$ && "$s" =~ ^[0-9]+$ ]] && (( ms > s * 1000 && ms <= 1800000 )); then
    ok "#1685: NOT-ARMED prints a runnable await (--timeout $s) with a Bash timeout ($ms ms) above it and within the 30-min default"
else bad "#1685: NOT-ARMED fallback lacks a covering Bash timeout: rc=$rc ms='$ms' s='$s' out=$out"; fi
[[ "$out" == *"<status>killed</status>"* && "$out" == *"ng longjob"* ]] && ok "#1685: …and says a harness STOP notice is not a verdict, and that past the ceiling the route is ng longjob" || bad "#1685: stop-notice / ng longjob guidance missing: $out"
"${LJ0[@]}" rm fb1685 >/dev/null
"${LJ0[@]}" add cmd:'exit 0' --id dn1685 --interval 1 >/dev/null 2>&1
amax=$(( 7200 - MONITOR_LONGJOB_PROBE_TIMEOUT_SECONDS - 30 ))   # ceiling less one probe's slack
out=$("${LJ0[@]}" await dn1685 --timeout $(( amax + 1 )) 2>&1); rc=$?
(( rc == 2 )) && [[ "$out" == *"ng longjob"* ]] && ok "#1685: await --timeout $(( amax + 1 )) (past what one 2-h call can hold) → rc 2, routed to ng longjob" || bad "#1685: over-ceiling await: rc=$rc $out"
# Potency controls: the refusal is a BOUNDARY, not a blanket — the largest
# holdable value is accepted, and a raised BASH_MAX_TIMEOUT_MS raises it.
"${LJ0[@]}" await dn1685 --timeout "$amax" >/dev/null 2>&1; rc=$?; (( rc == 0 )) && ok "#1685: await --timeout $amax (ceiling less slack) is accepted" || bad "#1685: boundary await rc=$rc"
env -u BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS=14400000 "$LJ" await dn1685 --timeout 7200 >/dev/null 2>&1; rc=$?; (( rc == 0 )) && ok "#1685: BASH_MAX_TIMEOUT_MS=4h raises the cap (7200 accepted)" || bad "#1685: raised-ceiling await rc=$rc"
# The printed Bash timeout leaves slack for ONE probe, so await must not sleep
# a whole --interval past its deadline: a 2-s await on a 60-s interval ends in
# seconds with rc 4, not after 60 s (the outer 30 s bound reads 124 if it does).
"${LJ0[@]}" add file:"$WORK/never1685b" --id sl1685 --interval 60 >/dev/null 2>&1
timeout 30 "${LJ0[@]}" await sl1685 --timeout 2 >/dev/null 2>&1; rc=$?
(( rc == 4 )) && ok "#1685: await never sleeps past its deadline (rc 4 within the bound, interval 60 s)" || bad "#1685: await overslept its deadline: rc=$rc (124 = still sleeping at 30 s)"

echo "=== F3 wording: resolve on a retired watch names the watch as dead ==="
export NEXUS_LONGJOB_KEY="t5"
[[ "$("$LJ" resolve b3)" == running\|"watch retired (expired) — NOT being watched; subject: "* ]] && ok "F3: resolve on the expired b3 says 'watch retired (expired) — NOT being watched' before the live subject state" || bad "F3 wording: $("$LJ" resolve b3)"


echo; echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }; exit 1
