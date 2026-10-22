#!/usr/bin/env bash
# Tests for monitor/hooks/async-launch-detect.sh — the PostToolUse
# Bash hook that auto-detects async-launch commands (sbatch, srun
# --no-block, nohup &) and writes a (kind, id, desc) entry to the
# worker heartbeat's `external_waits` array. Part of issue #183.
#
# Run: bash monitor/watcher/test-async-launch-detect.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HOOK="$_repo_root/monitor/hooks/async-launch-detect.sh"
PATTERNS_DEFAULT="$_repo_root/monitor/async-launch-patterns.conf"

# The SHARED assertion ledger (your-org/nexus-code#805). The in-memory counters
# die in a subshell; the ledger is a file and survives, so a FAILING assertion
# counted inside `( … )` or `$( … )` still reddens the suite. `ok`/`bad` keep
# their signatures and delegate, so every call site below is unchanged.
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s
' "$1"; _th_pass; }
bad() { printf '  FAIL: %s — %s
' "$1" "${2:-}" >&2; _th_fail; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# This suite asserts the WAIT records only. The hook's auto-armed longjob
# watch (and, since your-org/nexus-code#1727, its NOT-ARMED notice on stdout)
# is covered in test-pane-state-longjob-discount.sh; left on here, an inherited
# NEXUS_ROOT would make every slurm case run THAT root's longjob-watch.sh.
export MONITOR_LONGJOB_AUTO_WATCH=false

[[ -x "$HOOK" ]] || { echo "missing hook: $HOOK" >&2; exit 1; }
[[ -f "$PATTERNS_DEFAULT" ]] || { echo "missing default patterns: $PATTERNS_DEFAULT" >&2; exit 1; }

hb_file="$WORK/.state/heartbeat/testw.json"

reset_hb() { rm -f "$hb_file"; rm -rf "$WORK/.state/heartbeat"; }

# Fire the hook with a synthesised PostToolUse payload and the
# default patterns file. Reads the resulting external_waits.
fire_hook() { fire_hook_as Bash "$@"; }

# Same, with the TOOL NAME as the first argument. `Monitor` carries
# .tool_input.command into the same shell, so it can launch the very async
# work this hook exists to detect (your-org/nexus-code#936).
fire_hook_as() {
    local tool="$1" cmd="$2" stdout="$3"
    jq -nc \
        --arg tool "$tool" --arg cmd "$cmd" --arg out "$stdout" \
        '{hook_event_name:"PostToolUse",tool_name:$tool,tool_input:{command:$cmd},tool_response:{stdout:$out}}' \
      | env -u NEXUS_WORKER_WINDOW \
          NEXUS_STATE_DIR="$WORK/.state" \
          NEXUS_WORKER_WINDOW=testw \
          NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" \
          bash "$HOOK"
}

# Same, but under a wall-clock bound. The pipeline's status is `timeout`'s,
# which is the one this assertion is about (rc 124 = it wedged).
fire_hook_timed() {   # <seconds> <cmd>
    local secs="$1" cmd="$2"
    jq -nc --arg tool Bash --arg cmd "$cmd" --arg out "" \
        '{hook_event_name:"PostToolUse",tool_name:$tool,tool_input:{command:$cmd},tool_response:{stdout:$out}}' \
      | env -u NEXUS_WORKER_WINDOW \
          NEXUS_STATE_DIR="$WORK/.state" \
          NEXUS_WORKER_WINDOW=testw \
          NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" \
          timeout "$secs" bash "$HOOK"
}

read_waits() {
    if [[ -f "$hb_file" ]]; then
        jq -c '.external_waits // []' "$hb_file" 2>/dev/null
    else
        echo "[]"
    fi
}

echo "=== default pattern set: sbatch / srun --no-block / nohup ==="

# (1) sbatch with id in stdout.
reset_hb
fire_hook "sbatch run.sh" "Submitted batch job 12345678"
got=$(read_waits)
if jq -e '. == [{kind:"slurm",id:"12345678",desc:"sbatch"}]' <<<"$got" >/dev/null; then
    ok "sbatch run.sh → kind=slurm id=12345678"
else
    bad "sbatch basic" "got=$got"
fi

# (2) sbatch --array with array job id.
reset_hb
fire_hook "sbatch --array=1-10 --wrap='echo hi'" "Submitted batch job 12345679_1"
got=$(read_waits)
id=$(jq -r '.[0].id' <<<"$got")
if [[ "$id" == "12345679_1" ]]; then
    ok "sbatch --array → array id captured"
else
    bad "sbatch array" "got=$got"
fi

# (3) Repeat same sbatch — idempotent on (kind, id).
reset_hb
fire_hook "sbatch run.sh" "Submitted batch job 12345678"
fire_hook "sbatch run.sh" "Submitted batch job 12345678"
got=$(read_waits)
count=$(jq 'length' <<<"$got")
if [[ "$count" == "1" ]]; then
    ok "repeat sbatch with same id → single entry"
else
    bad "repeat sbatch idempotent" "count=$count"
fi

# (4) Non-launch command does not write the heartbeat.
reset_hb
fire_hook "ls -la /tmp" "file1\nfile2"
if [[ ! -f "$hb_file" ]]; then
    ok "ls -la does not create heartbeat"
else
    bad "ls leaked file" "exists: $(cat "$hb_file")"
fi

# (5) Comment in command does not false-match (echo "sbatch run.sh" must not match).
reset_hb
fire_hook 'echo "sbatch run.sh"' "sbatch run.sh"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "echo \"sbatch run.sh\" does not false-match"
else
    bad "echo false-match" "got=$got"
fi

# (6) sbatchX (no word boundary) does not match.
reset_hb
fire_hook "sbatchx --foo" "garbage"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "sbatchx → no match (word-boundary anchor)"
else
    bad "sbatchx false-match" "got=$got"
fi

# (7) nohup with trailing & → synthetic id, kind=nohup.
reset_hb
fire_hook "nohup ./long_job.sh > out.log &" ""
got=$(read_waits)
kind=$(jq -r '.[0].kind' <<<"$got")
id=$(jq -r '.[0].id' <<<"$got")
if [[ "$kind" == "nohup" ]] && [[ "$id" == syn-* ]]; then
    ok "nohup & → kind=nohup synthetic id"
else
    bad "nohup" "got=$got"
fi

# (8) nohup without backgrounding (no trailing &) → no match.
reset_hb
fire_hook "nohup echo hi" "hi"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "nohup foreground → no match"
else
    bad "nohup foreground" "got=$got"
fi

# (9) srun --no-block with id in stdout.
reset_hb
fire_hook "srun --no-block --partition=campus-new -n 1 ./script.sh" \
          "Submitted job 12345299"
got=$(read_waits)
kind=$(jq -r '.[0].kind' <<<"$got")
id=$(jq -r '.[0].id' <<<"$got")
if [[ "$kind" == "slurm-srun-async" ]] && [[ "$id" == "12345299" ]]; then
    ok "srun --no-block → kind=slurm-srun-async id captured"
else
    bad "srun --no-block" "got=$got"
fi

# (10) plain srun (no --no-block) → no match. Hooks should not
#      add a wait for synchronous srun calls.
reset_hb
fire_hook "srun --partition=campus-new -n 1 ./script.sh" \
          "Submitted job 12345311"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "srun without --no-block → no match"
else
    bad "srun no --no-block" "got=$got"
fi

echo
echo "=== dismissed_waits filter ==="

# (11) After dismissal, re-detected (kind, id) is NOT re-added.
reset_hb
fire_hook "sbatch run.sh" "Submitted batch job 99"
# Manually inject a dismissal (mimics declare-no-wait.sh effect).
jq -c '.external_waits = [] | .dismissed_waits = [{kind:"slurm",id:"99"}]' \
    "$hb_file" > "$hb_file.tmp" && mv "$hb_file.tmp" "$hb_file"
fire_hook "sbatch run.sh" "Submitted batch job 99"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "dismissed (slurm,99) → hook skips re-add"
else
    bad "dismissed filter" "got=$got"
fi

echo
echo "=== degraded modes ==="

# Cases 12-14 exercise the hook's EARLY-EXIT paths, which by design
# (hot-path discipline) exit before reading stdin. Feed the payload
# via herestring, not a pipe: a pipe's writer races the reader's
# early exit, and under CPU load the echo can be scheduled after the
# hook is gone — SIGPIPE on the writer, which `set -o pipefail`
# surfaces as rc=141 despite the hook itself exiting 0 (reproduced in
# the R3-tail proof campaign at load ~40). A herestring is fully
# materialized by the shell before the hook runs, so no race exists.

# (12) Non-Bash tool — hook no-ops.
reset_hb
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
    NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" \
    bash "$HOOK" \
    <<<'{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/x"},"tool_response":{}}'
if [[ ! -f "$hb_file" ]]; then
    ok "non-Bash tool → hook no-ops"
else
    bad "non-Bash leaked" "$(cat "$hb_file")"
fi

# (13) Missing NEXUS_WORKER_WINDOW → silent no-op (hook hot-path
#      discipline; never block claude's turn).
reset_hb
out_err=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" \
        NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" \
        bash "$HOOK" 2>&1 \
        <<<'{"tool_name":"Bash","tool_input":{"command":"sbatch run.sh"},"tool_response":{"stdout":"Submitted batch job 1"}}')
rc=$?
if (( rc == 0 )) && [[ -z "$out_err" ]] && [[ ! -f "$hb_file" ]]; then
    ok "missing NEXUS_WORKER_WINDOW → silent no-op (exit 0)"
else
    bad "missing window" "rc=$rc out=$out_err"
fi

# (14) Missing patterns file → silent no-op.
reset_hb
out_err=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        NEXUS_ASYNC_PATTERNS="/no/such/file" \
        bash "$HOOK" 2>&1 \
        <<<'{"tool_name":"Bash","tool_input":{"command":"sbatch run.sh"},"tool_response":{"stdout":"Submitted batch job 1"}}')
rc=$?
if (( rc == 0 )) && [[ -z "$out_err" ]] && [[ ! -f "$hb_file" ]]; then
    ok "missing patterns file → silent no-op"
else
    bad "missing patterns" "rc=$rc out=$out_err"
fi

echo
echo "=== adding a new pattern is data-only ==="

# (15) Custom pattern via NEXUS_ASYNC_PATTERNS override.
custom="$WORK/custom-patterns.conf"
cat > "$custom" <<'EOF'
# Custom kind for testing.
mykind|^[[:space:]]*launchmybatch\b|My job ID ([A-Z0-9]+)|mybatch launcher
EOF
reset_hb
echo '{"tool_name":"Bash","tool_input":{"command":"launchmybatch --opt x"},"tool_response":{"stdout":"My job ID ABC123 queued"}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        NEXUS_ASYNC_PATTERNS="$custom" \
        bash "$HOOK"
got=$(read_waits)
if jq -e '. == [{kind:"mykind",id:"ABC123",desc:"mybatch launcher"}]' <<<"$got" >/dev/null; then
    ok "custom pattern → data-only extensibility"
else
    bad "custom pattern" "got=$got"
fi

# (16) Empty id_regex with custom kind synthesizes an id.
custom2="$WORK/custom2.conf"
cat > "$custom2" <<'EOF'
fireforget|\bfireforget\b||fireforget launcher
EOF
reset_hb
echo '{"tool_name":"Bash","tool_input":{"command":"fireforget some args"},"tool_response":{"stdout":""}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        NEXUS_ASYNC_PATTERNS="$custom2" \
        bash "$HOOK"
got=$(read_waits)
kind=$(jq -r '.[0].kind' <<<"$got")
id=$(jq -r '.[0].id' <<<"$got")
if [[ "$kind" == "fireforget" ]] && [[ "$id" == syn-* ]]; then
    ok "empty id_regex → synthetic id"
else
    bad "empty id_regex" "got=$got"
fi

echo
echo "=== tool reachability: Monitor carries commands too (#936) ==="
#
# The detector populates `external_waits`, which pane-state turns into
# `idle-orphan-async` — the state for a worker that ended its turn with async
# work in flight and no resume armed. It was gated to `Bash` at BOTH layers
# (the worker-settings matcher and the check below), so async work launched
# through `Monitor` was invisible to the detector for that exact failure mode.
#
# Measured live before this change: a real `Monitor` call whose command string
# carried a matching `nohup … &` moved the universal heartbeat's `last_tool`
# to `Monitor` while `external_waits` stayed `[]` — the hook was never
# consulted. Same command through `Bash` recorded `kind=nohup`.

reset_hb
fire_hook_as Monitor "sbatch run.sh" "Submitted batch job 771001"
got=$(read_waits)
if jq -e '. == [{kind:"slurm",id:"771001",desc:"sbatch"}]' <<<"$got" >/dev/null; then
    ok "Monitor + sbatch is DETECTED (was invisible)"
else
    bad "Monitor + sbatch" "$got"
fi

reset_hb
fire_hook_as Monitor "nohup ./long.sh > out 2>&1 &" ""
got=$(read_waits)
if jq -e '.[0].kind == "nohup"' <<<"$got" >/dev/null; then
    ok "Monitor + nohup is DETECTED"
else
    bad "Monitor + nohup" "$got"
fi

# THE OVER-FIRE CONTROL, and it is the half that decides whether widening is
# safe. Widening a hook means it fires on more surfaces for every worker on
# the board; a guard that over-fires gets suppressed, which removes it.
# `Monitor`'s DOCUMENTED uses are waits and tails — none is a launch, so none
# records an external wait and none can become `idle-orphan-async`.
for _c in \
    'until [ -f "$SENTINEL" ]; do sleep 30; done' \
    'tail -f build.log' \
    'until ! kill -0 "$pid" 2>/dev/null; do sleep 15; done' \
    'while true; do gh api repos/o/r/actions/runs; sleep 60; done'
do
    reset_hb
    fire_hook_as Monitor "$_c" ""
    got=$(read_waits)
    if [[ "$got" == "[]" ]]; then
        ok "documented Monitor use records NOTHING: ${_c:0:40}"
    else
        bad "over-fire on a documented Monitor use: ${_c:0:40}" "$got"
    fi
done

# The gate still DISCRIMINATES — it did not become "any tool".
reset_hb
fire_hook_as Read "sbatch run.sh" "Submitted batch job 999999"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "a tool that carries no shell command is still ignored (Read)"
else
    bad "gate no longer discriminates" "$got"
fi

echo "=== your-org/nexus-code#948: POSITION, not MENTION ==="

# The defect: these rows match command TEXT, and prose about a launch is
# command text. Three waits were registered in one day by two windows that
# were WRITING ABOUT the detector — the population most likely to type such a
# command is the agent maintaining it. A detector that fires on documentation
# of the thing it detects gets suppressed, which removes it entirely.
#
# Every case below is passed as a shell variable rather than typed into a
# heredoc argv, for the same reason this suite exists.

_case() {   # _case <label> <expect: fire|quiet> <command>
    local label="$1" expect="$2" cmd="$3"
    reset_hb
    fire_hook "$cmd" "" >/dev/null 2>&1
    local got n
    got=$(read_waits); n=$(jq -r 'length' <<<"$got")
    if [[ "$expect" == fire && "$n" -ge 1 ]] || [[ "$expect" == quiet && "$n" -eq 0 ]]; then
        ok "$label"
    else
        bad "$label" "expected $expect, got $got"
    fi
}

# TWO KINDS OF NOT-CAUGHT, AND ONLY ONE OF THEM IS A `_case`
# (your-org/nexus-code#1269).
#
# `_case … quiet` on a GENUINE LAUNCH asserts a miss is CORRECT. That is the
# right shape for an UNDECIDABLE shape — one no command-text regex can separate
# from prose — because there the miss is the design and silently trading it away
# is what the assertion exists to prevent.
#
# It is the WRONG shape for a launch that is merely NOT COVERED YET. Nine such
# arms were pinned that way, and the consequence is the defect this issue names:
# a genuine repair turns the suite RED, so an improvement has to argue with a
# green test before it can ship. Five of the nine were closed by one change.
#
# `_gap` is the shape for those. It records the CURRENT answer without asserting
# that it is correct, and the falsifiable part is the LEDGER below: the suite
# asserts how many gaps are still open. Close one and the ledger — not the arm —
# goes red, with a message saying to decrement it and move the arm into the
# covered bucket. Widening the rows therefore never requires DELETING an
# assertion, which is what the pins forced.
#
# A REGRESSION is caught in the same place from the other side: a covered launch
# falling back into a gap reddens both its `fire` assertion and this ledger.
_GAPS_OPEN=0
_gap() {    # _gap <label> <command> — a genuine launch not covered YET
    local label="$1" cmd="$2"
    reset_hb
    fire_hook "$cmd" "" >/dev/null 2>&1
    local n; n=$(jq -r 'length' <<<"$(read_waits)")
    if (( n == 0 )); then
        _GAPS_OPEN=$(( _GAPS_OPEN + 1 ))
        ok "GAP still open: $label"
    else
        ok "GAP CLOSED (now caught) — decrement _EXPECTED_OPEN_GAPS: $label"
    fi
}

# --- PROSE must never register a wait (the #948 false positives) ----------
_case "prose: grep of the pattern does not fire"      quiet 'while true; do grep "srun --no-block" log; done'
_case "prose: echo mentioning the pattern"            quiet 'echo SK-PROBE srun --no-block'
_case "prose: heredoc writing a report"               quiet 'cat > r.md <<EOF
we detect srun --no-block launches
EOF'
_case "prose: a comment naming the pattern"           quiet '# note: srun --no-block is the pattern'
_case "prose: mention after a separator"              quiet 'echo a; echo "srun --no-block is documented"'
_case "prose: sbatch named in a grep"                 quiet 'grep "sbatch" log'

# --- GENUINE launches must still register --------------------------------
_case "launch: srun at start of command"              fire  'srun --no-block ./job.sh'
_case "launch: srun with flags before --no-block"     fire  'srun -N1 --no-block ./job.sh'
_case "launch: srun after cd &&"                      fire  'cd /tmp && srun --no-block ./job.sh'
_case "launch: srun after a semicolon"                fire  'echo hi; srun --no-block ./job.sh'
_case "launch: sbatch at start of command"            fire  'sbatch job.sh'

# `cd … && sbatch` was a live FALSE NEGATIVE before #948 — the sbatch row was
# anchored-only. Fixed here as a side effect of applying the same two-row
# treatment to both slurm rows.
_case "launch: sbatch after cd && (was a false negative)" fire 'cd /tmp && sbatch job.sh'

# --- THE DECLARED BOUNDARY, asserted so it cannot be traded away silently --
#
# ONLY the UNDECIDABLE shape is pinned here. A quoted launch is textually
# identical to prose at the boundary that would recover it: adding `"` to the
# position class recovers `bash -c "srun --no-block …"` and re-admits
# `grep "srun --no-block"` in the SAME edit (measured). Pinning it as `quiet`
# is therefore an assertion about the design, and a widening that breaks it
# should have to argue.
#
# The contrast that makes this a real boundary rather than an excuse: the
# UNQUOTED sibling `eval srun --no-block ./j.sh` IS caught, from the same row
# (asserted below). The line is quoting, not wrapper-ness.
_case "BOUNDARY: quoted launch is NOT caught (undecidable)"  quiet 'bash -c "srun --no-block ./job.sh"'

# NOT the same thing, and it used to be filed as if it were
# (your-org/nexus-code#1269). This one is a GAP, not a boundary: it is not
# undecidable, and its stated cause was WRONG. It was pinned as "needs a
# literal `|`" — but `|` is expressible now (`\x7c`), and with `|` in the
# position class this payload STILL misses, because the word after the pipe is
# `xargs`, not the launcher. A fix for the named cause would not have moved it.
_gap 'after a pipe INTO a wrapper: | xargs ... srun' 'echo x | xargs -I{} srun --no-block ./job.sh'

# --- Every row must parse to exactly FOUR fields --------------------------
#
# A literal `|` inside a regex is silently shredded by the field split: the
# row's cmd_re becomes a fragment, it matches nothing, and a detector row is
# disabled with no error — a silent zero inside a safety detector. The header
# forbids it; nothing enforced it until now.
bad_rows=$(awk -F'|' '!/^[[:space:]]*#/ && NF>1 && NF!=4 {print NR":"NF}' "$PATTERNS_DEFAULT")
if [[ -z "$bad_rows" ]]; then
    ok "every pattern row parses to exactly 4 fields"
else
    bad "pattern rows malformed" "rows with NF!=4: $bad_rows"
fi

# Non-vacuity for the assertion above: a planted bad row MUST be detected.
_bad_conf=$(mktemp)
printf 'k|[;&|]+foo|id|d\n' > "$_bad_conf"
planted=$(awk -F'|' '!/^[[:space:]]*#/ && NF>1 && NF!=4 {print NR":"NF}' "$_bad_conf")
if [[ -n "$planted" ]]; then
    ok "control: a row containing a literal | IS caught by the parse check"
else
    bad "parse check is vacuous" "planted bad row was not detected"
fi
rm -f "$_bad_conf"

# And the consequence, executed: such a row fires on nothing at all.
_shred_conf=$(mktemp)
printf 'slurm-srun-async|[;&|]+[[:space:]]*srun\\b[^&]*--no-block\\b|Submitted job ([0-9_]+)|srun --no-block\n' > "$_shred_conf"
reset_hb
jq -nc --arg cmd 'srun --no-block ./job.sh' \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:""}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        NEXUS_ASYNC_PATTERNS="$_shred_conf" bash "$HOOK" >/dev/null 2>&1
shred_got=$(read_waits)
if [[ "$(jq -r 'length' <<<"$shred_got")" -eq 0 ]]; then
    ok "a shredded row silently detects NOTHING — even a real launch"
else
    bad "shredded row" "expected no detection, got=$shred_got"
fi
rm -f "$_shred_conf"

# --- …and the OTHER half: `\x7c` says `|` without writing one -----------
#
# The two assertions above are true and were being over-read. "A literal `|` is
# shredded" is a fact about this repo's FILE FORMAT; it was doing duty as
# "this detector cannot express `|`", which is a claim about the regex LANGUAGE
# and is false. That over-reading cost the `||` position, and the suite proved
# the shredding in one place while pinning its consequence in another
# (your-org/nexus-code#1269). The hook decodes `\x7c` to `|` AFTER the split.
#
# Both readings of `|` are tested, because the escape buys both and a test of
# only one would leave the other unguarded.

# (i) `|` as a CHARACTER — a `||` position, the shape that was pinned as
#     inexpressible.
_esc_conf=$(mktemp)
printf 'escchar|[\\x7c][\\x7c][[:space:]]*srun\\b[^&]*--no-block\\b||escaped pipe position\n' > "$_esc_conf"
reset_hb
jq -nc --arg cmd 'false || srun --no-block ./job.sh' \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:""}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        NEXUS_ASYNC_PATTERNS="$_esc_conf" bash "$HOOK" >/dev/null 2>&1
if [[ "$(jq -r '.[0].kind' <<<"$(read_waits)")" == "escchar" ]]; then
    ok "escape: \\x7c as a CHARACTER matches a || position"
else
    bad "escape as character" "got=$(read_waits)"
fi
rm -f "$_esc_conf"

# (ii) `|` as the ALTERNATION OPERATOR, with a control that can FIRE.
#      A row matching only `alphaonly` or `betaonly` is fed `betaonly`: it can
#      match ONLY if the token became an alternation.
#
#      The control had to be MEASURED rather than reasoned. The obvious control
#      — feed the literal text `alphaonly\x7cbetaonly` — is DECORATION: measured
#      on glibc ERE, an undecoded `\x7c` is not an escape at all and collapses
#      to the literal characters `x7c`, so that subject matches under NEITHER
#      hook and the assertion passes for free. The subject that discriminates
#      is `alphaonlyx7cbetaonly`, with NO backslash: it matches the UNDECODED
#      row and must not match the decoded one. Verified against a
#      decode-stripped hook — the control fires there, which is the only thing
#      that makes it a control rather than a passing line
#      (your-org/nexus-code#1304).
_alt_conf=$(mktemp)
printf 'escalt|^(alphaonly\\x7cbetaonly)$||escaped alternation\n' > "$_alt_conf"
_esc_fire() {   # _esc_fire <conf> <command> -> prints the wait count
    reset_hb
    jq -nc --arg cmd "$2" \
        '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:""}}' \
      | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
            NEXUS_ASYNC_PATTERNS="$1" bash "$HOOK" >/dev/null 2>&1
    jq -r 'length' <<<"$(read_waits)"
}
if [[ "$(_esc_fire "$_alt_conf" 'betaonly')" == "1" ]]; then
    ok "escape: \\x7c as ALTERNATION matches the second branch"
else
    bad "escape as alternation" "betaonly did not match"
fi
# The control, in the direction that CAN fire.
if [[ "$(_esc_fire "$_alt_conf" 'alphaonlyx7cbetaonly')" == "0" ]]; then
    ok "control: the token was DECODED, not read as the literal chars x7c"
else
    bad "escape control" "matched 'alphaonlyx7cbetaonly' — the decode did not run"
fi
rm -f "$_alt_conf"

# --- THE COUPLING THE ESCAPE CREATES, asserted rather than assumed -------
#
# The escape makes the conf and the hook VERSION-LOCKED, and the failure
# direction is the silent one. Measured: strip the decode from the hook and run
# the suite unchanged against the shipped conf — 31 assertions fail, because
# every position row now spells its separator class with `\x7c`. In production
# there is no suite; a conf deployed against a hook that predates the decode
# would just stop detecting most launches, at rc 0, which is the manufactured-
# success direction this detector exists to prevent.
#
# They ship in the same commit, so this is a redeploy-skew guard, not a
# correctness one. It costs one grep.
# Keyed on BEHAVIOUR, not on the decoder's variable NAME: a name-based probe
# would false-red on a rename that changed nothing, and this repo has an
# expensive history with predicates that key on a string instead of the thing.
_skew_conf=$(mktemp)
printf 'skewprobe|^(alphaonly\\x7cbetaonly)$||skew probe\n' > "$_skew_conf"
_hook_decodes=$([[ "$(_esc_fire "$_skew_conf" 'betaonly')" == "1" ]] && echo yes || echo no)
rm -f "$_skew_conf"
if grep -qF 'x7c' "$PATTERNS_DEFAULT"; then
    if [[ "$_hook_decodes" == yes ]]; then
        ok "conf uses the escape and this hook decodes it (no deploy skew)"
    else
        bad "conf/hook skew" "the shipped conf spells rows with the escape but this hook does not decode it — most rows would silently match nothing"
    fi
else
    ok "conf uses no escape; no decoder required"
fi

echo "=== #948 round 2: the population, not just the instrument ==="

# The first round measured 6 command shapes with two matchers that AGREED.
# Both matchers were `bash [[ =~ ]]` — the hook's own inner step
# (async-launch-detect.sh:136) — so they shared an engine AND whole-string
# semantics. Agreement between them could not surface a whole-string blind
# spot, and did not. A third matcher with LINE semantics (`grep -E`)
# disagreed, which is how the newline case was found.

# --- the newline blind spot: NOT a regex problem -------------------------
# `=~` anchors ^ to the whole subject, so a launch on line 2 was invisible.
# The hook now tests each LINE. Multi-line Bash calls are a routine agent
# shape, so this covers a large share of real launches.
_nl_cmd=$'cd /tmp\nsrun --no-block ./j.sh'
_case "launch on line 2 of a multi-line command"      fire  "$_nl_cmd"
_case "prose on line 2 does not fire"                 quiet $'cd /tmp\necho "srun --no-block is documented"'

# Witness the MECHANISM, not just the outcome: whole-string matching cannot
# see it, line-based matching can. If someone reverts the per-line loop this
# assertion explains why the case above broke.
_re='^[[:space:]]*srun\b[^&]*--no-block\b'
if [[ "$_nl_cmd" =~ $_re ]]; then
    bad "whole-string =~ blind spot" "expected NO match against the whole string"
else
    ok "mechanism: whole-string =~ cannot see a launch on line 2"
fi
# Herestring, not `printf … | grep -Eq` — your-org/nexus-code#622's lint bans
# the pipe form: `grep -q` exits on first match without draining, the writer
# takes EPIPE, and under pipefail that inverts the verdict exactly when the
# thing under test is TRUE. A herestring has no pipe. Same subject: `<<<` adds
# the trailing newline `printf '%s\n'` did.
if grep -Eq "$_re" <<<"$_nl_cmd"; then
    ok "mechanism: line-based matching DOES see it"
else
    bad "line-based matching" "expected a match on line 2"
fi

# --- shell-grammar positions recovered this round ------------------------
_case "launch in a subshell ( … )"                    fire  '( srun --no-block ./j.sh )'
_case "launch in a brace group { … ; }"               fire  '{ srun --no-block ./j.sh; }'
_case "launch in a command substitution"              fire  'out=$(srun --no-block ./j.sh)'
# Backticks stay OUT of the position class: markdown inline code makes a
# backtick a prose character in this repo. `!` was given up in the same edit
# for the same reason — WRONGLY, as it turns out. `!` is a prose character only
# where it ABUTS a word (`run it!sbatch style`); a command-position `!` is
# followed by WHITESPACE, and requiring that separates the two cleanly. Now
# covered, with the prose form still quiet two sections below.
_case "! negation IS caught (whitespace-required, so prose stays out)" fire '! srun --no-block ./j.sh'
_case "launch in a for/do loop (canonical slurm idiom)" fire 'for i in 1 2; do sbatch job.sh; done'
_case "launch after then"                             fire  'if true; then sbatch job.sh; fi'

# --- group A positions RECOVERED by the `\x7c` escape --------------------
# `||` was pinned as "needs a literal |, which the field split shreds". The
# shredding is real; the conclusion was not. `|` is the FIELD SEPARATOR, which
# is a property of this repo's own file format, not of the regex language — so
# the row that could not be written was a self-inflicted limitation, and the
# suite proved the shredding in one place while pinning its consequence in
# another. The hook now decodes `\x7c` after the split.
_case "after || IS caught (\x7c escape)"              fire  'false || srun --no-block ./j.sh'
_case "after || IS caught, sbatch too"                 fire  'test -f j.sh || sbatch job.sh'

# --- B1: TRANSPARENT PREFIX wrappers, RECOVERED --------------------------
# The wrapper set is open and cannot be completed. That was used to justify
# covering NONE of it, which does not follow for a detector whose expensive
# failure is the miss. It splits: where the launcher is a BARE WORD after the
# wrapper's option words, position is decidable; where it is inside QUOTES, it
# is not. The first half is now an explicit allowlist plus a prefix grammar
# admitting only flags, bare numeric durations and assignments.
_case "var-assignment prefix IS caught (POSIX grammar, no name list)" fire 'FOO=1 srun --no-block ./j.sh'
_case "timeout wrapper IS caught"                     fire  'timeout 60 srun --no-block ./j.sh'
_case "nice wrapper IS caught"                        fire  'nice -n 10 sbatch job.sh'
_case "env wrapper IS caught"                         fire  'env FOO=1 sbatch job.sh'
_case "eval, UNQUOTED, IS caught"                     fire  'eval srun --no-block ./j.sh'
_case "prefixes compose with a separator position"    fire  'cd /tmp && OMP_NUM_THREADS=8 sbatch job.sh'

# THE PREFIX GRAMMAR IS WHAT KEEPS THIS FROM BEING A RE-UNANCHORING, and it is
# the assertion that decides whether the allowlist was safe. Admitting an
# arbitrary intervening WORD would be #948 again: every "we do sbatch nightly"
# sentence sits after some word. Only flags, numbers and assignments may
# intervene, so a wrapper name followed by PROSE does not reach the launcher.
_case "wrapper name + PROSE does not fire"            quiet 'timeout 60 echo we do sbatch nightly'
_case "wrapper name in a comment body does not fire"  quiet \
    "gh issue comment 1 --body 'we now cover timeout 60 srun --no-block prefixes'"

# --- B2: QUOTED command — still undecidable, still pinned ----------------
_case "BOUNDARY: bash -c wrapper is NOT caught"       quiet 'bash -c "srun --no-block ./j.sh"'
_case "BOUNDARY: eval QUOTED is NOT caught"           quiet 'eval "srun --no-block ./j.sh"'

# --- GAPS: not undecidable, not covered — DECLINED BY MEASUREMENT --------
# A single `|` as a position character is expressible now. It is declined, and
# the reason is this file's own rule about the backtick: a character that
# commonly abuts a command name IN WRITING is not a separator. In this repo a
# markdown table is how commands get documented, so `| srun --no-block | … |`
# is a launch position AND a table cell. Measured: adding `|` fires on a bare
# table row. `||` is not such a character, which is why it was admitted above.
_gap 'direct pipe into the launcher: ... | srun'      'cat ids.txt | srun --no-block ./j.sh'
_gap 'direct pipe into sbatch: ... | sbatch'          'cat list | sbatch job.sh'

# Found while fixing your-org/nexus-code#1864: the dry-run fix counts these as
# sbatch invocations, but no row matches the position, so on their own they arm
# nothing. Neither is undecidable; neither is covered yet.
_gap 'escaped command word: \sbatch job.sh'           '\sbatch job.sh'
_gap 'the command builtin: command sbatch job.sh'     'command sbatch job.sh'

# The consequence of that decline, asserted from the other side so the trade is
# visible in one place: a markdown table row must stay QUIET.
_case "markdown table row does not fire (why a bare pipe is declined)" quiet \
    "$(printf 'cat > t.md <<EOF\n| srun --no-block | fire and forget |\nEOF')"

# --- KNOWN FALSE POSITIVES, declared rather than hidden ------------------
# Pinned as `fire` because they DO fire. If a later change silences them the
# assertion fails and the improvement gets noticed rather than assumed.
#
# residual — the old unanchored row fired on this too:
_case "KNOWN FP: prose after a separator (residual, srun)"  fire 'echo a; srun --no-block is what the row matches'
# WERE KNOWN FPs, CLOSED BY your-org/nexus-code#1832: the hook now blanks
# the body of every quoted string before any row is tried, so a separator
# INSIDE a quote is no longer a separator. The sbatch separator row (which
# lacks srun's `[^&]*--no-block` constraint) and the `||` position
# (your-org/nexus-code#1269) introduced these two; both are prose in QUOTES.
_case "FIXED (#1832): quoted prose after a separator (sbatch)" quiet \
    "git commit -m 'two rows now; sbatch after a separator is matched'"
_case "FIXED (#1832): quoted prose carrying a literal ||" quiet \
    "echo 'either you sbatch it || srun --no-block it'"

echo "=== #948 round 3: a separator class must not contain PROSE characters ==="

# Round 2 put a BACKTICK (and `)` and `!`) in the separator class. Markdown
# inline code is how every report, PR body, issue comment and commit message
# in this repo names a command, so `` `sbatch` `` matched. That revision fired
# on 11 of 13 realistic prose bodies — including its own PR description —
# reproducing #948 at HIGHER frequency than the defect it fixed, because the
# original only ever reached the srun row.
#
# These assertions exist so a future widening cannot re-introduce it silently.
_case "backtick in a commit message does not fire"  quiet \
    "git commit -m 'the \`sbatch\` row now matches after a separator'"
_case "backtick in a gh comment body does not fire" quiet \
    "gh issue comment 948 --body 'we widened the \`srun --no-block\` row'"
_case "backtick in a heredoc report does not fire"  quiet \
    "$(printf 'cat > r.md <<EOF\nuse `sbatch` to submit\nEOF')"
_case "brace in prose does not fire"                quiet "echo 'the {sbatch} placeholder'"
_case "bang in prose does not fire"                 quiet "echo 'run it!sbatch style'"

# The keyword rows are GATED on a real separator, so plain English cannot
# reach them. Ungated, `\bdo[[:space:]]+sbatch\b` matches this sentence.
_case "English 'we do sbatch runs' does not fire"   quiet \
    'echo "we do sbatch runs on this cluster every night"'

# …and the launch forms they exist for still fire.
_case "for/do loop still fires"                     fire  'for i in 1 2; do sbatch job.sh; done'
_case "if/then still fires"                         fire  'if true; then sbatch job.sh; fi'
_case "brace group WITH whitespace still fires"     fire  '{ sbatch job.sh; }'
_case "subshell paren still fires"                  fire  '( sbatch job.sh )'

# WAS UNDECIDABLE to a regex over raw text: a literal `; then sbatch`,
# textually identical to a real `if …; then sbatch …`. It is inside QUOTES,
# and since your-org/nexus-code#1832 quoted text is masked before matching.
_case "FIXED (#1832): '; then sbatch' in quoted prose is quiet" quiet \
    'echo "if it is a batch job; then sbatch is the row that matches"'

# WAS A KNOWN FALSE POSITIVE, CLOSED BY your-org/nexus-code#1312.
#
# Per-line matching made a HEREDOC BODY a scanning surface, so a document
# written with `cat > r.md <<EOF` whose text names a launch at the start of a
# line registered a wait. Measured in the wild: a session that ran no Slurm
# job accumulated five `syn-…` waits and was woken by the orphan-async loop
# 308 s later. The hook now blanks the body of a heredoc whose governing
# command is a named DATA CONSUMER — and ONLY then.
_case "FIXED (#1312): heredoc doc containing an indented launch is quiet" quiet \
    "$(printf 'cat > r.md <<EOF\n    sbatch job.sh\nEOF')"
_case "FIXED (#1312): heredoc doc with an UNindented launch is quiet" quiet \
    "$(printf 'cat > r.md <<EOF\nsbatch job.sh\nEOF')"
_case "FIXED (#1312): python3 heredoc prose naming srun is quiet" quiet \
    "$(printf "python3 - <<'PY'\nsrun --no-block was never invoked here\nPY")"

# THE MISS DIRECTION IS THE EXPENSIVE ONE, so the arms that keep the mask from
# becoming a blanket heredoc skip are asserted here, not argued in a comment.
# Each is a heredoc body that GENUINELY EXECUTES; each must still fire.
_case "#1312 arm: bash <<EOF executes its body — still fires"   fire \
    "$(printf "bash <<'EOF'\nsbatch job.sh\nEOF")"
_case "#1312 arm: sh <<EOF executes its body — still fires"     fire \
    "$(printf "sh <<'EOF'\ncd /tmp\nsbatch job.sh\nEOF")"
_case "#1312 arm: zsh <<EOF executes its body — still fires"    fire \
    "$(printf "zsh <<'EOF'\nsrun --no-block ./j.sh\nEOF")"
_case "#1312 arm: ssh host <<EOF launches remotely — still fires" fire \
    "$(printf "ssh node01 <<'EOF'\nsbatch job.sh\nEOF")"
# A data consumer PIPED INTO A SHELL: `cat` is on the allowlist, so only the
# `|` guard saves this one. Deleting that guard is a silent miss.
_case "#1312 arm: cat <<EOF | bash — the pipe guard keeps it firing" fire \
    "$(printf "cat <<'EOF' | bash\nsbatch job.sh\nEOF")"
# An UNKNOWN command keeps TODAY's behaviour: the default arm is DO NOT MASK,
# so the allowlist can never be incomplete in the expensive direction.
_case "#1312 arm: an unknown heredoc consumer is NOT masked"    fire \
    "$(printf "myrunner <<'EOF'\nsbatch job.sh\nEOF")"
# The OPENING line is never masked, so a heredoc-fed launcher still fires
# while its job-script body (which may name `srun` steps) does not.
_case "#1312 arm: sbatch <<EOF fires from the OPENER"           fire \
    "$(printf "sbatch <<'EOF'\nsrun ./step.sh\nEOF")"
# An UNTERMINATED heredoc means the parse was wrong: mask nothing, scan all.
_case "#1312 arm: unterminated heredoc masks NOTHING"           fire \
    "$(printf 'cat > r.md <<EOF\nsbatch job.sh\n')"
# `<<` in ARITHMETIC is a left shift, not a heredoc — the trap
# `th_strip_heredocs` documents. Nothing after it may be swallowed.
_case "#1312 arm: a left shift does not open a heredoc"         fire \
    "$(printf 'n=$(( 1 << 4 ))\nsbatch job.sh')"
# A `<<` inside a QUOTED ARGUMENT is text, not a redirection operator. Getting
# this wrong QUIETS a launch: the phantom delimiter opens a heredoc whose body
# swallows the real `sbatch` on the next line. Measured — with the quote-parity
# arm disabled this input goes from firing to silent.
_case "#1312 arm: a << inside a quoted argument opens no heredoc" fire \
    "$(printf 'git commit -m "cat <<EOF"\nsbatch job.sh\nEOF')"
# A `<<<` herestring is not a heredoc either.
_case "#1312 arm: a herestring does not open a heredoc"         fire \
    "$(printf 'grep -q x <<< "$v"\nsbatch job.sh')"
# And the launch OUTSIDE a masked heredoc is untouched.
_case "#1312 arm: a launch AFTER a masked heredoc still fires"  fire \
    "$(printf "cat > job.sh <<'EOF'\n#!/bin/bash\necho work\nEOF\nsbatch job.sh")"

# THE HOT PATH IS AN ASSERTION, NOT A HOPE (your-org/nexus-code#1312).
# A hook that wedges BLOCKS claude's turn, so a parser added here has to be
# bounded, and the bound has to be checked. The first version of the mask
# re-scanned the accumulated prefix on every `<<`, i.e. O(occurrences x line
# length): measured on this host, a synthetic `echo a<<b a<<b …` line took
# 10.5 s at 200 occurrences and did not finish inside 100 s at 600, against a
# flat ~0.16 s for the unpatched hook. Nothing in the suite noticed, because
# every other assertion is about the ANSWER and this failure is about the TIME.
_wedge_cmd="echo $(for _i in $(seq 1 400); do printf 'a<<b '; done)"
reset_hb
fire_hook_timed 25 "$_wedge_cmd" >/dev/null 2>&1
_wedge_rc=$?
if (( _wedge_rc != 124 )); then
    ok "hot path: 400 \`<<\` occurrences on one line do not wedge the hook"
else
    bad "hot path WEDGED" "the heredoc mask did not finish in 25 s on a 400-occurrence line — it is quadratic again"
fi

# KNOWN FALSE POSITIVE that the #1312 mask deliberately does NOT clear, so the
# boundary is visible rather than argued. A heredoc opened INSIDE a command
# substitution sits after an odd number of `"`, and the quote-parity arm
# therefore declines to treat it as an opener at all. Erring that way can only
# leave a false positive standing; erring the other way masks something a shell
# will run. Pinned as `fire` so a later widening has to notice it.
_hd_substcmd=$(cat <<'CASE'
jq -n --arg b "$(cat <<'EOF'
srun --no-block ./j.sh
EOF
)" '{body:$b}'
CASE
)
_case "KNOWN FP (#1312): heredoc opened inside a command substitution" fire "$_hd_substcmd"

# NON-VACUITY. Every `quiet` above would also pass against a hook that never
# fires at all, so the mask is exercised from the other side: the SAME body,
# under a consumer the allowlist does not name, must FIRE. If the assertion
# pair ever agrees, the mask has become a blanket skip (or a no-op) and the
# suite says which.
_hd_body=$(printf 'sbatch job.sh')
_case "#1312 non-vacuity: masked under cat"     quiet "$(printf 'cat > r.md <<EOF\n%s\nEOF' "$_hd_body")"
_case "#1312 non-vacuity: SAME body, unmasked under an unknown consumer" fire \
    "$(printf 'myrunner <<EOF\n%s\nEOF' "$_hd_body")"

# …and the benefit per-line matching pays for, so the trade is visible in
# one place rather than argued in a comment.
_case "…and per-line matching still buys the multi-line launch" fire \
    "$(printf 'cd /tmp\nsbatch job.sh')"


echo "=== ONE WAIT PER JOB, NOT ONE PER CALL (your-org/nexus-code#1071) ==="
# A submission GRID is a single Bash call whose stdout carries N success lines.
# Before this, the hook took the FIRST id and the other N-1 jobs were invisible;
# a call it could not id at all got a `syn-` token with no job behind it, which
# nothing can look up. That is precisely the wait the watcher's wake loop
# reports as `unresolvable` — so per-call tokenisation was manufacturing the
# unrecoverable case at exactly the shape (a dose grid) that is COMMON for this
# kind of work.
reset_hb
_grid_out=$(for i in $(seq 3000100 3000114); do echo "Submitted batch job $i"; done)
fire_hook 'for i in $(seq 1 15); do sbatch j.sh; done' "$_grid_out"
got=$(read_waits)
n=$(jq 'length' <<<"$got")
if [[ "$n" == "15" ]]; then
    ok "a 15-job grid in ONE call registers 15 waits, not 1"
else
    bad "grid tokenisation" "got $n waits, expected 15 — got=$got"
fi
if jq -e 'map(.id) == ["3000100","3000101","3000102","3000103","3000104","3000105","3000106","3000107","3000108","3000109","3000110","3000111","3000112","3000113","3000114"]' <<<"$got" >/dev/null; then
    ok "…and every id is the REAL job id, in order"
else
    bad "grid ids" "got=$(jq -c 'map(.id)' <<<"$got")"
fi
if jq -e 'map(.id) | map(select(startswith("syn-"))) | length == 0' <<<"$got" >/dev/null; then
    ok "…and NOT a single unresolvable syn- token"
else
    bad "grid produced a syn- token" "got=$(jq -c 'map(.id)' <<<"$got")"
fi

# Idempotence must survive the change: re-firing the same grid must not stack.
fire_hook 'for i in $(seq 1 15); do sbatch j.sh; done' "$_grid_out"
n=$(jq 'length' <<<"$(read_waits)")
if [[ "$n" == "15" ]]; then
    ok "re-firing the grid stays at 15 (idempotent per id)"
else
    bad "grid idempotence" "n=$n"
fi

# DISMISSAL IS PER ID, not per call. Dismissing one job of a grid must leave
# the other fourteen registered — the opposite would make `declare-no-wait`
# on a grid a blunt instrument that silently clears live work, which is the
# dangerous direction `#1071` names.
reset_hb
NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
    bash "$_test_dir/../declare-no-wait.sh" slurm 3000101 >/dev/null 2>&1
fire_hook 'for i in $(seq 1 15); do sbatch j.sh; done' "$_grid_out"
got=$(read_waits)
n=$(jq 'length' <<<"$got")
if [[ "$n" == "14" ]] && jq -e 'map(.id) | index("3000101") | not' <<<"$got" >/dev/null; then
    ok "dismissing ONE grid job leaves the other 14 registered"
else
    bad "per-id dismissal" "n=$n got=$(jq -c 'map(.id)' <<<"$got")"
fi

# The no-id path is unchanged: still exactly one synthetic token, still
# `syn-`-prefixed. That prefix is now load-bearing — the wake loop's resolver
# checks it FIRST and reports `unresolvable` rather than rounding an
# unlookuppable id to "finished".
reset_hb
fire_hook "nohup ./producer.py &" ""
got=$(read_waits)
if jq -e 'length == 1 and (.[0].id | startswith("syn-"))' <<<"$got" >/dev/null; then
    ok "a nohup with no id still yields exactly one syn- token"
else
    bad "nohup syn token" "got=$got"
fi


echo "=== F2: `sbatch --parsable` prints a BARE id, and used to mint a syn- ==="
# Skeptic F2 on your-org/nexus-code#1071, CONFIRMED, and this is the mechanism
# that ACTUALLY produced the observed `slurm:syn-…` tokens — observed live: a
# single `sbatch --parsable` minted `slurm:syn-0d1713a9e039` in a real worker
# heartbeat on the very branch that added the multi-id fix. The per-call ->
# per-job fix only ever concerned stdout that ALREADY carried canonical lines,
# where the old code yielded a real (first) id and never a `syn-`. Two different
# paths; neither subsumes the other.
reset_hb
fire_hook "sbatch --parsable job.sh" "2345678"
got=$(read_waits)
if jq -e '. == [{kind:"slurm",id:"2345678",desc:"sbatch --parsable"}]' <<<"$got" >/dev/null; then
    ok "sbatch --parsable → the REAL id, not a syn- token"
else
    bad "parsable bare id" "got=$got"
fi

reset_hb
_par_out=$(seq 2300001 2300005)
fire_hook 'for i in $(seq 1 5); do sbatch --parsable j.sh; done' "$_par_out"
got=$(read_waits)
if jq -e 'map(.id) == ["2300001","2300002","2300003","2300004","2300005"]' <<<"$got" >/dev/null; then
    ok "a parsable LOOP registers every real id"
else
    bad "parsable loop" "got=$(jq -c 'map(.id)' <<<"$got")"
fi

# `--parsable` may append `;<cluster>`.
reset_hb
fire_hook "sbatch --parsable j.sh" "2345678;cluster"
if [[ "$(jq -r '.[0].id' <<<"$(read_waits)")" == "2345678" ]]; then
    ok "the ;<cluster> suffix is stripped from a parsable id"
else
    bad "parsable cluster suffix" "got=$(read_waits)"
fi

# PHANTOM IDS (your-org/nexus-code#1629). The id field was `^([0-9_]+)`,
# leading digits only, so any other stdout line of the same call that merely
# BEGAN with digits became a job id: one call armed ten phantom watches,
# 121..661, beside the real job id (synthetic here: 4200001) (worker-a-sk, 2026-09-23). The field now
# anchors the whole line, as `--parsable` prints it.
reset_hb
# (An sbatch-ONLY call: since your-org/nexus-code#1727 a bare number is never
# trusted from a substituted sbatch, NOR from a call that runs another command
# beside it (`sbatch --parsable j.sh; grep -n x f` now declares a syn- wait and
# prints NOT ARMED, asserted in test-pane-state-longjob-discount.sh). The
# ANCHOR is what this case pins: line-numbered lines never become ids.)
fire_hook "sbatch --parsable j.sh" $'121:x = 1\n489:  x\n4200001\n542: done'
got=$(read_waits)
if jq -e 'map(.id) == ["4200001"]' <<<"$got" >/dev/null; then
    ok "#1629 line-numbered output beside a parsable id registers ONLY the real id"
else
    bad "#1629 phantom ids from line-numbered output" "got=$(jq -c 'map(.id)' <<<"$got")"
fi
reset_hb
fire_hook "sbatch --parsable j.sh" "2345678 jobs queued"
got=$(read_waits)
if jq -e 'length == 1 and (.[0].id | startswith("syn-"))' <<<"$got" >/dev/null; then
    ok "#1629 a line that only BEGINS with digits is not a parsable id (syn- fallback)"
else
    bad "#1629 digits-then-words line read as an id" "got=$got"
fi
reset_hb
fire_hook "sbatch --parsable j.sh" "2345678  "
if [[ "$(jq -r '.[0].id' <<<"$(read_waits)")" == "2345678" ]]; then
    ok "#1629 trailing whitespace after a parsable id is still accepted (control)"
else
    bad "#1629 trailing whitespace" "got=$(read_waits)"
fi

# JOB ID 0, AND A BARE NUMBER FROM INSIDE `$(…)` (your-org/nexus-code#1727).
# `jid=$(sbatch --parsable j.sh); echo $?` printed `0`, and `0` became the job
# id: `sacct -j 0` then answered about unrelated jobs for ~9.5 h. Two
# independent guards, one case each: the job-id predicate refuses `0` on a
# plain --parsable call, and a substituted sbatch's call reads NO bare number —
# the `1` below is a valid id SHAPE, so only the substitution rule stops it.
reset_hb
fire_hook "sbatch --parsable j.sh" "0" >/dev/null
got=$(read_waits)
if jq -e 'length == 1 and (.[0].id | startswith("syn-"))' <<<"$got" >/dev/null; then
    ok "#1727 a bare 0 is not a job id (syn- fallback, no slurm:0 wait)"
else
    bad "#1727 job id 0 accepted" "got=$got"
fi
reset_hb
fire_hook 'J=$(sbatch --parsable j.sh); echo $?' "1" >/dev/null
got=$(read_waits)
if jq -e 'length == 1 and (.[0].id | startswith("syn-"))' <<<"$got" >/dev/null; then
    ok "#1727 inside \$(…) the bare number printed by \`echo \$?\` is not read as the job id"
else
    bad "#1727 substituted sbatch read a bare number as its id" "got=$got"
fi

# NARROW ON PURPOSE. A general bare-numeric id rule would register stray output
# as a job id, and a WRONG id is strictly worse than a `syn-` — `sacct` may
# resolve it to ANOTHER job's COMPLETED and tell the worker its data is good,
# which is the exact failure this issue exists to prevent. So a plain `sbatch`
# must NOT gain the bare-id reading.
reset_hb
fire_hook "sbatch job.sh" "2345678"
got=$(read_waits)
if jq -e 'length == 1 and (.[0].id | startswith("syn-"))' <<<"$got" >/dev/null; then
    ok "a plain sbatch does NOT read bare numeric stdout as a job id"
else
    bad "plain sbatch must not gain bare-id reading" "got=$got"
fi

# …and the canonical path is untouched.
reset_hb
fire_hook "sbatch job.sh" "Submitted batch job 999"
if [[ "$(jq -r '.[0].id' <<<"$(read_waits)")" == "999" ]]; then
    ok "the canonical Submitted-batch-job path is unchanged"
else
    bad "canonical path regressed" "got=$(read_waits)"
fi

# A SIDE EFFECT WORTH PINNING: `nohup` is in the B1 allowlist, so a nohup
# wrapping a REAL launcher now resolves to that launcher's id instead of the
# nohup row's synthetic token. Measured before/after on the same payload:
#   before  [{"kind":"nohup","id":"syn-f8c17b31f1aa",...}]
#   after   [{"kind":"slurm","id":"42","desc":"sbatch"}]
# That is the `#1071` failure mode shrinking rather than a cosmetic relabel: a
# `syn-` id has no job behind it, the wake loop reports it `unresolvable`, and
# the operator's only escape is `declare-no-wait.sh`. A real job id is
# lookuppable. Ordering does it — the launcher rows precede the nohup row.
reset_hb
fire_hook 'nohup sbatch j.sh &' 'Submitted batch job 42'
if jq -e '. == [{kind:"slurm",id:"42",desc:"sbatch"}]' <<<"$(read_waits)" >/dev/null; then
    ok "nohup wrapping a launcher yields the REAL id, not a syn- token"
else
    bad "nohup + launcher" "got=$(read_waits)"
fi

# …and a nohup wrapping NOTHING the rows know is untouched: still the nohup row.
reset_hb
fire_hook 'nohup ./long.sh > out.log &' ''
if jq -e '.[0].kind == "nohup" and (.[0].id | startswith("syn-"))' <<<"$(read_waits)" >/dev/null; then
    ok "…and a plain nohup is still kind=nohup with a syn- id"
else
    bad "plain nohup regressed" "got=$(read_waits)"
fi

# SIX COPIES OF ONE REGEX MUST STAY ONE REGEX.
#
# The B1 transparent-prefix group is repeated verbatim in six rows (two
# positions x three launcher variants). Six hand-maintained copies of a regex
# drift, and the drift direction that matters is silent: a row whose prefix
# group lost a branch stops matching that shape and reports NOTHING. Extract
# them and require they be identical — the count is asserted too, so a row
# added without the group, or one deleted, is also a red.
_pre_groups=$(sed -n 's/.*\(((timeout[^)]*)\[\[:space:\]\]+[^|]*\)+.*/\1/p' "$PATTERNS_DEFAULT" | sort -u | wc -l)
_pre_rows=$(grep -cF 'timeout\x7cnice' "$PATTERNS_DEFAULT")
if [[ "$_pre_rows" == "6" ]] && [[ "$_pre_groups" == "1" ]]; then
    ok "the B1 prefix group is byte-identical across all 6 rows that carry it"
else
    bad "prefix group drifted" "rows carrying it: $_pre_rows (expected 6); distinct spellings: $_pre_groups (expected 1)"
fi

# your-org/nexus-code#1868 left an UNQUOTED `$(cat <<EOF` whose closing `)`
# carries the output into a shell on a LATER line as a gap. #1870 item 5 closed
# it; the cases are in the #1870 section below. What is left of the family is a
# DATAFLOW member: the value is captured by an assignment the mask allows, and
# run later through the variable. Following a variable to its use is out of
# reach for a per-command text scan.
_gap "#1870 x=\$(cat <<EOF … EOF) && \$x: the captured value runs later, through the variable" \
    "$(printf 'x=$(cat <<EOF\nsbatch job.sh\nEOF\n) && $x')"

# GAP LEDGER (your-org/nexus-code#1269). The falsifiable half of `_gap`.
#
# Each `_gap` arm records the current answer without asserting it is correct;
# this ledger is what makes the set of open gaps a RATCHET. Close one and this
# assertion — not the arm — goes red, and the fix is to decrement a number and
# move the arm into the covered bucket. That is the difference from a pin: a
# widening never has to DELETE an assertion, which is what made a genuine
# repair turn this suite red for nine arms at once.
#
# It catches the other direction too: a covered launch falling back into a gap
# reddens both its own `fire` assertion and this count.
_EXPECTED_OPEN_GAPS=6   # #1870: echo $(cat <<EOF …) | bash CLOSED, x=$(cat <<EOF …) && $x opened; +1: echo $(cat <<EOF …) | bash (#1868); +2: \sbatch and command sbatch (found with #1864)
if (( _GAPS_OPEN == _EXPECTED_OPEN_GAPS )); then
    ok "gap ledger: exactly $_EXPECTED_OPEN_GAPS declared gaps still open"
else
    bad "gap ledger drifted" \
        "$_GAPS_OPEN gaps open, expected $_EXPECTED_OPEN_GAPS — if coverage IMPROVED, decrement _EXPECTED_OPEN_GAPS and move the arm to a _case ... fire; if it REGRESSED, a covered launch is being missed"
fi

# COUNT GUARD. This suite had none; a case that stops running would otherwise
# show up as a smaller green.
# ── your-org/nexus-code#1439: the row records WHO launched it ────────────────
echo "=== #1832 command position: quoted text is not a command; sbatch spoke first ==="
# (A) A worker that ran no Slurm job got `slurm:syn-…` from a COMMIT MESSAGE:
# per-line matching made line 3 of the quoted message a line start. Quoted
# bodies and comments are masked before any row is tried, so none of these
# may register a wait.
_case "#1832 multi-line commit message naming sbatch is quiet" quiet \
    "$(printf 'git commit -m "fix: rename\n\nsbatch job names in code are now stable"')"
_case "#1832 echo of a quoted launch is quiet"            quiet 'echo "x && sbatch y.sh"'
_case "#1832 ng send --message naming sbatch is quiet"    quiet \
    "ng send w1 --message 'please run; sbatch j.sh later'"
_case "#1832 quoted string with a newline-led sbatch is quiet" quiet \
    "$(printf "printf '%%s\\\\n' 'a\nsbatch j.sh'")"
_case "#1832 heredoc body naming sbatch is quiet"         quiet \
    "$(printf "cat > notes.md <<'EOF'\nthen; sbatch j.sh\nEOF")"
_case "#1832 a trailing comment naming sbatch is quiet"   quiet 'ls # then; sbatch j.sh'
_case "#1832 parenthesised mention in quotes is quiet"    quiet "echo 'call it (sbatch) for short'"
# …and every real launch position still fires, quotes ELSEWHERE notwithstanding.
_case "#1832 sbatch x.sh fires"                           fire  'sbatch x.sh'
_case "#1832 env A=1 sbatch fires"                        fire  'env A=1 sbatch x.sh'
_case "#1832 timeout 5 sbatch fires"                      fire  'timeout 5 sbatch x.sh'
_case "#1832 quoted ARGUMENTS of a real sbatch still fire" fire 'sbatch --job-name="w1 run" --wrap="a; b" x.sh'
_case "#1832 a runner's quoted command is NOT masked"     fire  "ssh node01 'cd /data/proj-x && sbatch j.sh'"
_case "#1832 a commit message BEFORE a real launch does not hide it" fire \
    "$(printf 'git commit -m "msg"\nsbatch j.sh')"
_case "#1832 an unterminated quote falls back to scanning everything" fire \
    "$(printf 'echo "oops\nsbatch j.sh')"

_ids_are() {   # <label> <cmd> <stdout> <expected ids as JSON array, or "syn">
    local label="$1" cmd="$2" out="$3" want="$4" got
    reset_hb
    fire_hook "$cmd" "$out" >/dev/null 2>&1
    got=$(jq -c 'map(.id)' <<<"$(read_waits)")
    if [[ "$want" == syn ]]; then
        if jq -e 'length == 1 and (.[0] | startswith("syn-"))' <<<"$got" >/dev/null; then ok "$label"; else bad "$label" "got=$got"; fi
    elif jq -e --argjson w "$want" '. == $w' <<<"$got" >/dev/null; then
        ok "$label"
    else
        bad "$label" "want=$want got=$got"
    fi
}
_ids_are "#1832 cd d && sbatch --parsable j.sh reads the bare id" \
    'cd d && sbatch --parsable j.sh' '1234567' '["1234567"]'
_ids_are "#1832 jid=\$(sbatch --parsable …) stays a syn- wait (#1727 unchanged)" \
    'jid=$(sbatch --parsable j.sh)' '' syn
# Was a `syn-` pin; since #1859 the echoed variable is read back by position.
_ids_are "#1832/#1859 jid=\"\$(sbatch --parsable …)\"; echo \"\$jid\" in double quotes reads the echoed id" \
    'jid="$(sbatch --parsable j.sh)"; echo "$jid"' '1234567' '["1234567"]'
# (B) sbatch --parsable FIRST, other commands after: stdout's first line is
# sbatch's, so it is the id — this was a `syn-` wait (observed 3x).
_ids_are "#1832 sbatch --parsable a.sh; echo done → the real id, not syn-" \
    'sbatch --parsable a.sh; echo done' "$(printf '1234567\ndone')" '["1234567"]'
_ids_are "#1832 a later grep -c is not a vouching echo: syn-, as on dev (declared cost)" \
    'sbatch --parsable a.sh 2>&1; grep -c x f' "$(printf '1234567\n3')" syn
_ids_are "#1832 echo hi; sbatch b.sh reads the Submitted line" \
    'echo hi; sbatch b.sh' "$(printf 'hi\nSubmitted batch job 1234568')" '["1234568"]'
# The guards on that rule, each a way the first line could be someone else's.
_ids_are "#1832 guard: a FAILED sbatch (error in stdout) does not lend its slot to grep" \
    'sbatch --parsable a.sh; grep -c x f' "$(printf 'sbatch: error: Batch job submission failed\n3')" syn
reset_hb
jq -nc --arg cmd 'sbatch --parsable a.sh; grep -c x f' \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:"3",stderr:"sbatch: error: Batch job submission failed"}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
      NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" bash "$HOOK" >/dev/null 2>&1
if jq -e 'length == 1 and (.[0].id | startswith("syn-"))' <<<"$(read_waits)" >/dev/null; then
    ok "#1832 guard: a FAILED sbatch (error in stderr) does not lend its slot to grep"
else
    bad "#1832 guard: stderr sbatch error" "got=$(read_waits)"
fi
_ids_are "#1832 guard: a printing command BEFORE sbatch keeps it distrusted" \
    'grep -c x f; sbatch --parsable a.sh' "$(printf '1\n1234567')" syn
_ids_are "#1832 guard: a backgrounded sbatch can be overtaken" \
    'sbatch --parsable a.sh & echo 5' "$(printf '5\n1234567')" syn
_ids_are "#1832 guard: a loop repeats, so one sbatch in the text is not one run" \
    'for f in a b; do sbatch --parsable "$f"; echo x; done' "$(printf '1234567\nx')" syn
_ids_are "#1832 control: | tee after sbatch keeps the first-line reading" \
    'sbatch --parsable a.sh | tee id.txt; echo done' "$(printf '1234567\ndone')" '["1234567"]'
_ids_are "#1832 guard: | tee then echo 5 is not vouched (echo of a digit)" \
    'sbatch --parsable a.sh | tee id.txt; echo 5' "$(printf '1234567\n5')" syn

# ncbundle27-sk F1: a sbatch that fails SILENTLY on stdout lends stdout's first
# line to the next printer, and its failure text is open-ended. So the first
# printer after sbatch must be an `echo <word>` whose line is never an integer.
_ids_are "#1832 F1 repro: timeout kills sbatch, echo \$? prints 124 → never slurm:124" \
    'timeout 60 sbatch --parsable j.sh; echo $?' '124' syn
_ids_are "#1832 F1 repro: wc -l < ids.txt prints 42 → never slurm:42" \
    'sbatch --parsable j.sh; wc -l < ids.txt' '42' syn
_ids_are "#1832 F1 repro: the ORIGINAL #1727 core fixture (stdout just '1') → never slurm:1" \
    'sbatch --parsable j.sh; grep -c x f' '1' syn
_ids_are "#1832 F1 invariant: a SILENT failure before echo done reads no id" \
    'sbatch --parsable a.sh; echo done' 'done' syn
_ids_are "#1832 F1 guard (wrapper, isolated): timeout … sbatch; echo done is refused" \
    'timeout 60 sbatch --parsable a.sh; echo done' "$(printf '1234567\ndone')" syn
_ids_are "#1832 F1 guard: a QUOTED echo is masked, so not vouched (declared cost)" \
    'sbatch --parsable a.sh; echo "done"' "$(printf '1234567\ndone')" syn
_ids_are "#1832 F1 guard: source after sbatch can print anything" \
    'sbatch --parsable a.sh; source env.sh; echo done' "$(printf '7\ndone')" syn
_ids_are "#1832 F1 control: && echo submitted vouches" \
    'sbatch --parsable a.sh && echo submitted' "$(printf '1234567\nsubmitted')" '["1234567"]'
_ids_are "#1832 F1 control: cd between sbatch and the echo is quiet" \
    'sbatch --parsable a.sh; cd d; echo done' "$(printf '1234567\ndone')" '["1234567"]'
# ncbundle27-sk R1: `&&` (or `then`) SKIPS the echo exactly when sbatch fails,
# so a conditional echo vouches only when nothing after it can print.
_ids_are "#1832 R1 repro: sbatch && echo ok; grep -c x f (stdout '1') → never slurm:1" \
    'sbatch --parsable j.sh && echo ok; grep -c x f' '1' syn
_ids_are "#1832 R1 repro: sbatch && cd /d && echo ok; wc -l < f (stdout '7') → never slurm:7" \
    'sbatch --parsable j.sh && cd /d && echo ok; wc -l < f' '7' syn
_ids_are "#1832 R1 guard: an echo opened by else never runs after the then-branch sbatch" \
    'if true; then sbatch --parsable j.sh; else echo ok; fi; grep -c x f' '1' syn
_ids_are "#1832 R1 control: sbatch; echo ok inside one then-branch still vouches" \
    'if true; then sbatch --parsable j.sh; echo ok; fi; grep -c x f' "$(printf '1234567\nok\n1')" '["1234567"]'
_ids_are "#1832 R1 control: an UNCONDITIONAL ; echo vouches despite a later printer" \
    'sbatch --parsable j.sh; echo ok; grep -c x f' "$(printf '1234567\nok\n1')" '["1234567"]'
reset_hb
jq -nc --arg cmd 'sbatch --parsable a.sh; echo done' \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:"1234567\ndone",stderr:"warning: something"}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
      NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" bash "$HOOK" >/dev/null 2>&1
if jq -e 'length == 1 and (.[0].id | startswith("syn-"))' <<<"$(read_waits)" >/dev/null; then
    ok "#1832 F1 guard (separated stderr, isolated): any stderr refuses the first-line rule"
else
    bad "#1832 F1 guard: separated stderr" "got=$(read_waits)"
fi
# The skeptic's stub repro as observed: the stub's error on stderr matches
# neither `sbatch:` token, stdout is grep's count alone.
reset_hb
jq -nc --arg cmd 'sbatch --parsable j.sh; grep -c done log' \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:"3",stderr:"error: chaperon is not responding"}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
      NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" bash "$HOOK" >/dev/null 2>&1
if jq -e 'length == 1 and (.[0].id | startswith("syn-"))' <<<"$(read_waits)" >/dev/null; then
    ok "#1832 F1 repro: a stub's unrecognised stderr, then grep -c → never slurm:3"
else
    bad "#1832 F1 repro: stub stderr" "got=$(read_waits)"
fi

# An in-process subagent fires this hook under the PARENT's window, so the
# wait lands on a heartbeat whose transcript cannot explain it. The payload's
# transcript_path (a subagent's is its own file) and, where the harness sets
# it, agent_id are recorded on the row as `launcher`.
echo "=== #1439 launcher identity on the row ==="
fire_hook_launcher() {   # <cmd> <transcript_path|""> <agent_id|"">
    jq -nc --arg cmd "$1" --arg tp "$2" --arg ag "$3" \
        '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:""}}
         + (if $tp == "" then {} else {transcript_path:$tp} end)
         + (if $ag == "" then {} else {agent_id:$ag} end)' \
      | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
          NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" bash "$HOOK"
}
reset_hb
fire_hook_launcher 'nohup "$L/run1.sh" > /dev/null 2>&1 &' \
    "$HOME/.claude/projects/-p/abcd-1234/subagents/agent-a1b2c3.jsonl" "a1b2c3"
got=$(read_waits)
assert_eq "#1439 a subagent launch records agent id AND transcript on the row" \
    "$(jq -r '.[0].launcher' <<<"$got")" "a1b2c3/agent-a1b2c3"
reset_hb
fire_hook_launcher 'nohup "$L/run2.sh" > /dev/null 2>&1 &' \
    "$HOME/.claude/projects/-p/abcd-1234.jsonl" ""
got=$(read_waits)
assert_eq "#1439 a parent-transcript launch records the transcript basename" \
    "$(jq -r '.[0].launcher' <<<"$got")" "abcd-1234"
reset_hb
fire_hook_launcher 'nohup "$L/run3.sh" > /dev/null 2>&1 &' "" ""
got=$(read_waits)
assert_eq "#1439 CONTROL: no identity in the payload → no launcher field (not an empty string)" \
    "$(jq -r '.[0] | has("launcher")' <<<"$got")" "false"

echo "=== #1854: a dry run arms nothing; an id sbatch wrote to a file is TRACKED ==="
# Synthetic stand-ins for the four measured 2026-10-16 commands (sha1 of each
# real command matched its syn- id); paths, ids and node names replaced.
_ids() { read_waits | jq -r '[.[].id] | join(",")'; }
_k1854() {   # <label> <want: id | syn | none> <cmd> <stdout>
    reset_hb; fire_hook "$3" "$4" >/dev/null 2>&1
    local got; got=$(_ids)
    case "$2" in
        none) assert_eq "$1" "$got" "" ;;
        syn)  if [[ "$got" == syn-* && "$got" != *,* ]]; then ok "$1"; else bad "$1" "got=[$got] want a single syn- wait"; fi ;;
        *)    assert_eq "$1" "$got" "$2" ;;
    esac
}
# (a) DRY RUNS — no job exists, so no wait of any kind.
_k1854 "#1854a sbatch --test-only arms NOTHING" none \
    'sbatch --test-only --job-name=p --wrap="b.sh 9900"' 'sbatch: Job 1234567 to start at 2026-10-18T21:10:20 using 8 processors on nodes node01'
_k1854 "#1854a the measured probe shape (test-only after && inside a longer call) arms NOTHING" none \
    'EX=$(x/exclude_nodes.sh); rc=$?; echo "exclude rc=$rc: $EX"; [[ $rc == 0 && -n $EX ]] && sbatch --test-only --job-name=p --exclude="$EX" --wrap="'"'"'b.sh'"'"' 9900"; echo "test-only rc=$?"' \
    $'exclude rc=0: node01\nsbatch: Job 1234567 to start at 2026-10-18T21:10:20\ntest-only rc=0'
_k1854 "#1854a sbatch --help arms NOTHING" none 'sbatch --help' 'Usage: sbatch [OPTIONS(0)...] [ : [OPTIONS(N)...]] script(0) [args(0)...]'
_k1854 "#1854a MUST-FIRE: --test-only AFTER the script is the job's own argument — a real submit" 1234567 \
    'sbatch job.sh --test-only' 'Submitted batch job 1234567'
_k1854 "#1854a MUST-FIRE: a dry sbatch beside a real one still tracks the real one" 1234568 \
    'sbatch --test-only a.sh; sbatch b.sh' $'sbatch: Job 1 to start at x\nSubmitted batch job 1234568'
# (b) THE FILE-THEN-cat SHAPE: tracked, but only on a printed rc=0.
_k1854 "#1854b EX=\$(…) && sbatch --parsable > F; echo rc; cat F → TRACKED slurm id" 1234567 \
    'P=/data/proj-x/p; EX=$(x/exclude_nodes.sh) && sbatch --parsable --job-name=p --exclude="$EX" --wrap="'"'"'$W/b.sh'"'"' 9900 -- bash '"'"'$P/probe.sh'"'"'" > $P/JOBID.txt; echo "sbatch rc=$?"; cat $P/JOBID.txt' \
    $'sbatch rc=0\n1234567'
_k1854 "#1854b a long && chain with an echo BEFORE sbatch → TRACKED" 1234568 \
    'C=/data/proj-x/c; [[ ! -e $C ]] && mkdir $C && cd /data/proj-x && [[ $(git rev-parse HEAD) == $S ]] && [[ -z $(git status --porcelain) ]] && EX=$(x/exclude_nodes.sh) && echo "re-asserted: clean; excludes=$EX" && sbatch --parsable --job-name=c --wrap="$PWD/b.sh 3300 $C/ok -- bash $PWD/j.sh $S" > $C/JOBID.txt; echo "rc=$?"; cat $C/JOBID.txt' \
    $'re-asserted: clean; excludes=node01\nrc=0\n1234568'
_k1854 "#1854b the hold-test shape (pipes inside \$(…), printf > file earlier) → TRACKED" 1234569 \
    'H=/data/proj-x/h; mkdir "$H" && printf '"'"'PROBE-ONLY.\n'"'"' > $H/README && chmod 444 $H/README; EX=$(x/exclude_nodes.sh 2>/dev/null); [ -z "$EX" ] && EX=$(cd /data/proj-x && git show s:f.txt | command grep -vE '"'"'^(#|$)'"'"' | cut -f1 | paste -sd,); echo "exclude=$EX"; SBATCH_HOLD=1 sbatch --parsable --job-name=h --wrap="timeout 60 bash -c '"'"'hostname'"'"'" > $H/JOBID.txt; echo "sbatch rc=$?"; cat $H/JOBID.txt' \
    $'exclude=node01\nsbatch rc=0\n1234569'
_k1854 "#1854b NEGATIVE: rc=1 printed (sbatch skipped or failed; F holds an OLD id) → syn, never the stale id" syn \
    'EX=$(x.sh) && sbatch --parsable --wrap=b > $P/JOBID.txt; echo "sbatch rc=$?"; cat $P/JOBID.txt' $'sbatch rc=1\n7654321'
_k1854 "#1854b NEGATIVE: an || in the call (rc=0 no longer proves sbatch ran) → syn" syn \
    'test -e x || sbatch --parsable --wrap=b > F; echo "rc=$?"; cat F' $'rc=0\n1234567'
_k1854 "#1854b NEGATIVE: an if-branch around sbatch → syn" syn \
    'if test -e x; then sbatch --parsable --wrap=b > F; fi; echo "rc=$?"; cat F' $'rc=0\n1234567'
_k1854 "#1854b NEGATIVE: the echo expands another variable (it can print an integer line) → syn" syn \
    'sbatch --parsable --wrap=b > F; echo "rc=$? $X"; cat F' $'rc=0 \n1234567'
_k1854 "#1854b NEGATIVE: cat of a DIFFERENT file → syn" syn \
    'sbatch --parsable --wrap=b > F; echo "rc=$?"; cat G' $'rc=0\n1234567'
_k1854 "#1854b NEGATIVE: an APPEND (>>) keeps old ids → syn" syn \
    'sbatch --parsable --wrap=b >> F; echo "rc=$?"; cat F' $'rc=0\n1234567'
_k1854 "#1854b NEGATIVE: no rc echo between sbatch and cat → syn" syn \
    'sbatch --parsable --wrap=b > F; cat F; echo "rc=$?"' $'1234567\nrc=0'
_k1854 "#1854b PIN: an && chain with 'Submitted batch job' was already tracked, and stays so" 1234570 \
    'git add f && sbatch job.sh' 'Submitted batch job 1234570'
_k1854 "#1854b PIN: …and read back through > F; cat F" 1234571 \
    'sbatch job.sh > F; cat F' 'Submitted batch job 1234571'

echo "=== #1859: a substituted sbatch whose variable is echoed is TRACKED; a dry flag after an option VALUE arms nothing ==="
# (a) jid=$(sbatch --parsable …) puts the id in the VARIABLE. Echoed as the
# call's last and only printing command, the id is read back; every other shape
# keeps the syn- wait (a loud miss, never a guessed id).
_k1859() { _k1854 "$@"; }
_k1859 "#1859a jid=\$(sbatch --parsable …); echo \"\$jid\" → TRACKED" 1234567 \
    'jid=$(sbatch --parsable -p part-x job.sh); echo "$jid"' '1234567'
_k1859 "#1859a no later echo → still a syn- wait (nothing on stdout to read)" syn \
    'jid=$(sbatch --parsable -p part-x job.sh)' ''
_k1859 "#1859a NEGATIVE: TWO substituted sbatches, one echoed → syn, never attributed" syn \
    'a=$(sbatch --parsable a.sh); b=$(sbatch --parsable b.sh); echo "$a"' '1234567'
_k1859 "#1859a cd && jid=\$(…) && printf '%s\\n' \"\${jid}\" → TRACKED" 1234568 \
    'cd /data/proj-x && jid=$(sbatch --parsable --wrap="a; b" job.sh) && printf '"'"'%s\n'"'"' "${jid}"' '1234568'
_k1859 "#1859a echo with literal text around the variable → TRACKED, text stripped by position" 1234569 \
    'jid="$(sbatch --parsable job.sh)"; echo "submitted ${jid}."' 'submitted 1234569.'
_k1859 "#1859a NEGATIVE: sbatch failed, the echo printed an empty line → syn" syn \
    'jid=$(sbatch --parsable job.sh); echo "$jid"' ''
_k1859 "#1859a NEGATIVE: another printing command (grep -c) before the echo → syn" syn \
    'jid=$(sbatch --parsable job.sh); grep -c x f; echo "$jid"' $'3\n1234567'
_k1859 "#1859a NEGATIVE: the echo is not the last command → syn" syn \
    'jid=$(sbatch --parsable job.sh); echo "$jid"; echo done' $'1234567\ndone'
_k1859 "#1859a NEGATIVE: the variable is reassigned before the echo → syn" syn \
    'jid=$(sbatch --parsable job.sh); jid=7654321; echo "$jid"' '7654321'
_k1859 "#1859a NEGATIVE: a default-expansion can assign it (\${jid:=…}) → syn" syn \
    'jid=$(sbatch --parsable job.sh); : "${jid:=7654321}"; echo "$jid"' '7654321'
# ncbundle32-sk R2: `+=` (and an array-element write) is a reassignment too.
# `export` is on the quiet list, so before the fix these attributed the
# APPENDED value: a wrong id where base armed `syn-`.
_k1859 "#1859a NEGATIVE: export jid+=0 appends before the echo → syn, never 12345670" syn \
    'jid=$(sbatch --parsable job.sh); export jid+=0; echo "$jid"' '12345670'
_k1859 "#1859a NEGATIVE: && export jid+=9 && echo → syn, never 12345679" syn \
    'jid=$(sbatch --parsable job.sh) && export jid+=9 && echo "$jid"' '12345679'
_k1859 "#1859a NEGATIVE: an exported array-element write (export jid[0]=…) → syn" syn \
    'jid=$(sbatch --parsable job.sh); export jid[0]=7654321; echo "$jid"' '7654321'
_k1859 "#1859a CONTROL: a plain export (no assignment) stays TRACKED" 1234567 \
    'jid=$(sbatch --parsable job.sh); export jid; echo "$jid"' '1234567'
_k1859 "#1859a NEGATIVE: a wrapper inside the substitution (timeout) → syn" syn \
    'jid=$(timeout 60 sbatch --parsable job.sh); echo "$jid"' '1234567'
_k1859 "#1859a NEGATIVE: || join (the echo runs only on failure) → syn" syn \
    'jid=$(sbatch --parsable job.sh) || echo "$jid"' '1234567'
# (b) the script is the first word that is neither an option nor its VALUE.
_k1859 "#1859b sbatch -p part-x --test-only job.sh arms NOTHING" none \
    'sbatch -p part-x --test-only job.sh' 'sbatch: Job 1234567 to start at 2026-10-18T21:10:20'
_k1859 "#1859b sbatch --partition part-x -J n --test-only job.sh arms NOTHING" none \
    'sbatch --partition part-x -J n --test-only job.sh' 'sbatch: Job 1234567 to start at 2026-10-18T21:10:20'
_k1859 "#1859b a short-option cluster ending in a value option (-Hp part-x) arms NOTHING" none \
    'sbatch -Hp part-x --test-only job.sh' 'sbatch: Job 1234567 to start at 2026-10-18T21:10:20'
_k1859 "#1859b MUST-FIRE: -p part-x job.sh --test-only — the flag is a job ARGUMENT" 1234570 \
    'sbatch -p part-x job.sh --test-only' 'Submitted batch job 1234570'
_k1859 "#1859b MUST-FIRE: an attached value (-ppart-x) is one word; job.sh then --test-only submits" 1234571 \
    'sbatch -ppart-x job.sh --test-only' 'Submitted batch job 1234571'
_k1859 "#1859b MUST-FIRE: -- ends the options, so a later --test-only is the script's" 1234572 \
    'sbatch -p part-x -- --test-only' 'Submitted batch job 1234572'

echo "=== #1864: dry-run detection is PER INVOCATION; a dry sbatch never hides a real one ==="
# Every pair below has the real job b.sh and the dry probe a.sh in both orders,
# joined by ; && and |, and then inside a substitution. The real job must keep a
# wait: its id where the output carries one, else a single syn- wait, NEVER
# nothing. Before the fix the substituted forms armed nothing: `_seg_word` read
# `jid=$(sbatch …` as an assignment, so the real sbatch was not counted and the
# call looked "all dry".
_k1864() { _k1854 "$@"; }
_k1864 "#1864 the issue's shape: dry ; jid=\$(sbatch --parsable) ; echo → a wait (was NOTHING)" syn \
    'sbatch --test-only a.sh; jid=$(sbatch --parsable b.sh); echo "$jid"' $'sbatch: Job 1 to start at x\n1234567'
_k1864 "#1864 reversed: jid=\$(sbatch --parsable) ; dry ; echo → a wait (was NOTHING)" syn \
    'jid=$(sbatch --parsable b.sh); sbatch --test-only a.sh; echo "$jid"' $'1234567\nsbatch: Job 1 to start at x'
_k1864 "#1864 dry ; jid=\$(sbatch --parsable), no echo → a syn- wait (was NOTHING)" syn \
    'sbatch --test-only a.sh; jid=$(sbatch --parsable b.sh)' 'sbatch: Job 1 to start at x'
_k1864 "#1864 real ; dry → the real id" 1234568 \
    'sbatch b.sh; sbatch --test-only a.sh' $'Submitted batch job 1234568\nsbatch: Job 1 to start at x'
_k1864 "#1864 dry && real → the real id" 1234568 \
    'sbatch --test-only a.sh && sbatch b.sh' $'sbatch: Job 1 to start at x\nSubmitted batch job 1234568'
_k1864 "#1864 real && dry → the real id" 1234568 \
    'sbatch b.sh && sbatch --test-only a.sh' $'Submitted batch job 1234568\nsbatch: Job 1 to start at x'
_k1864 "#1864 dry | cat ; real → the real id" 1234568 \
    'sbatch --test-only a.sh 2>&1 | cat; sbatch b.sh' $'sbatch: Job 1 to start at x\nSubmitted batch job 1234568'
_k1864 "#1864 real | cat ; dry | cat → the real id" 1234568 \
    'sbatch b.sh | cat; sbatch --test-only a.sh 2>&1 | cat' $'Submitted batch job 1234568\nsbatch: Job 1 to start at x'
_k1864 "#1864 \$(dry ; real) → the real id" 1234568 \
    'x=$(sbatch --test-only a.sh; sbatch b.sh); echo "$x"' 'Submitted batch job 1234568'
_k1864 "#1864 \$(dry && real), nothing printed → a syn- wait" syn \
    'x=$(sbatch --test-only a.sh && sbatch b.sh)' ''
_k1864 "#1864 \$(dry | cat) ; real → the real id" 1234568 \
    'x=$(sbatch --test-only a.sh 2>&1 | cat); sbatch b.sh' $'sbatch: Job 1 to start at x\nSubmitted batch job 1234568'
_k1864 "#1864 dry ; a real sbatch by PATH → the real id (was NOTHING)" 1234568 \
    'sbatch --test-only a.sh; /usr/bin/sbatch b.sh' $'sbatch: Job 1 to start at x\nSubmitted batch job 1234568'
# THREE REAL --parsable LINES IN ONE CALL (the orchestrator's question on the
# bundle-33 submission, whose replay reproduced its live `syn-b481c16d3c06`).
# Alone, each line arms its own id. Beside other printing commands (that call
# had `sed`, `chmod` and `grep -H`), a bare integer could be anyone's, so the
# #1727 rule distrusts every one: ONE syn- wait, never a guessed id. That is the
# designed loud miss, not a dry-run defect; `ng longjob add slurm:<id>` per job
# is the remedy the hook's notice names.
_k1864 "#1864 three sbatch --parsable lines alone → three ids" 1234567,1234568,1234569 \
    $'sbatch --parsable a.sh\nsbatch --parsable b.sh\nsbatch --parsable c.sh' $'1234567\n1234568\n1234569'
_k1864 "#1864 three sbatch --parsable lines after a grep -H → ONE syn- wait (the #1727 distrust, by design)" syn \
    $'grep -H "^ARM=" job-*.sh\nsbatch --parsable a.sh\nsbatch --parsable b.sh\nsbatch --parsable c.sh' $'job-a.sh:ARM=a\n1234567\n1234568\n1234569'
_k1864 "#1864 three plain sbatch lines after a grep -c → three ids (Submitted lines need no trust)" 1234567,1234568,1234569 \
    $'grep -c x f\nsbatch a.sh\nsbatch b.sh\nsbatch c.sh' $'3\nSubmitted batch job 1234567\nSubmitted batch job 1234568\nSubmitted batch job 1234569'
# ncbundle33-sk F1: a redirection GLUED to the real sbatch word. Without `<>`
# in the occurrence suffix class the real submit was not counted, so the dry
# probe made the call read dry-only and NOTHING armed (base too).
_k1864 "#1864 F1 dry ; sbatch<b.sh → the real id (was NOTHING)" 1234568 \
    'sbatch --test-only a.sh; sbatch<b.sh' $'sbatch: Job 1 to start at x\nSubmitted batch job 1234568'
_k1864 "#1864 F1 dry ; sbatch>o.txt b.sh → a syn- wait (was NOTHING)" syn \
    'sbatch --test-only a.sh; sbatch>o.txt b.sh' 'sbatch: Job 1 to start at x'
_k1864 "#1864 F1 control: a dry probe with its own redirections still arms NOTHING" none \
    'sbatch --test-only a.sh >o.txt 2>&1' ''
# The dry-only side stays dry-only: no wait of any kind.
_k1864 "#1864 a dry sbatch inside \$(…) arms NOTHING (was a syn- wait)" none \
    'x=$(sbatch --test-only a.sh 2>&1); echo "$x"' 'sbatch: Job 1234567 to start at x'
_k1864 "#1864 two dry sbatches arm NOTHING" none \
    'sbatch --test-only a.sh; sbatch -p part-x --test-only b.sh' ''
_k1864 "#1864 a LOOKUP of sbatch (command -v) is not an invocation: dry probe arms NOTHING" none \
    'command -v sbatch && sbatch --test-only a.sh' $'/usr/bin/sbatch\nsbatch: Job 1234567 to start at x'
_k1864 "#1864 a LOOKUP of sbatch (which) is not an invocation: dry probe arms NOTHING" none \
    'which sbatch; sbatch --test-only a.sh' $'/usr/bin/sbatch\nsbatch: Job 1234567 to start at x'
# `\sbatch job.sh` and `command sbatch job.sh` arm nothing on their own: no row
# matches those positions, dry probe or not. They are ledgered as row GAPS with
# the other `_gap` arms, not here.

echo "=== #1863: a pipe inside a COMPLETE \$(…) on a heredoc's line does not refuse the body mask ==="
# The live shape (syn-6e8d5003da37, recovered from a transcript by sha1): a
# test-case append whose body quotes an sbatch line. It submitted nothing. The
# live `ls` carried a glob; it is dropped here, because a glob beside a bare-form
# `ls` joins test-nullglob-bare-form-manifest's population, and the property
# under test is the PIPE inside the substitution, which is kept.
_hd1863=$(cat <<'CASE'
f=$(ls -t "${TMPDIR}" | head -1); cat >> "$f" <<'EOF'
_k1859 "x" 1234567 \
    'jid=$(sbatch --parsable job.sh); echo "$jid"' '1234567'
sbatch job.sh
EOF
CASE
)
_case "#1863 the recovered shape (\$(… | head) then cat >> <<'EOF', body names sbatch) is quiet" quiet "$_hd1863"
_case "#1863 minimal repro: f=\$(ls x | head -1); cat >> \"\$f\" <<'EOF' … is quiet" quiet \
    "$(printf 'f=$(ls x | head -1); cat >> "$f" <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF')"
_case "#1863 the same with backticks is quiet" quiet \
    "$(printf 'f=`ls x | head -1`; cat >> "$f" <<EOF\nsbatch job.sh\nEOF')"
_case "#1863 the substitution AS the redirect target is quiet" quiet \
    "$(printf 'cat >> "$(ls x | head -1)" <<EOF\nsbatch job.sh\nEOF')"
_case "#1863 an && join, body naming srun --no-block, is quiet" quiet \
    "$(printf 'f=$(ls x | head -1) && cat > "$f" <<EOF\nsrun --no-block ./j.sh\nEOF')"
# The pipe guard itself is untouched: a pipe OUTSIDE every complete
# substitution still refuses the mask, so an executed body still fires.
_case "#1863 arm: \$(… | …) ; cat <<EOF | bash still fires" fire \
    "$(printf 'f=$(ls x | head -1); cat <<EOF | bash\nsbatch job.sh\nEOF')"
_case "#1863 arm: cat <<EOF \$(… | …) | bash still fires" fire \
    "$(printf 'cat <<EOF $(ls x | head -1) | bash\nsbatch job.sh\nEOF')"
_case "#1863 arm: a \$( holding the opener is NOT removed — x=\$(cat <<EOF | bash still fires" fire \
    "$(printf 'x=$(cat <<EOF | bash\nsbatch job.sh\nEOF\n)')"
# A COMPLETE substitution that HOLDS the opener: bash ends that heredoc at the
# `)`, so the "body" lines run at TOP LEVEL. Removing the group would also
# remove its pipe and mask lines a shell executes.
_case "#1863 arm: a complete \$(… <<EOF | bash) holding the opener is NOT removed — still fires" fire \
    "$(printf 'y=$(cat <<EOF | bash)\nsbatch job.sh\nEOF')"
_case "#1863 arm: a pipe after an odd quote still refuses (quotes are not stripped)" fire \
    "$(printf 'cat <<EOF "it'"'"'s" | bash '"'"'x'"'"'\nsbatch job.sh\nEOF')"
_case "#1863 arm: \$(… | …) ; bash <<EOF still fires (bash is no data consumer)" fire \
    "$(printf 'f=$(ls x | head -1); bash <<EOF\nsbatch job.sh\nEOF')"
# ncbundle33-sk F2: a `$(` or backtick pair that is LITERAL text (behind an
# odd single quote, or escaped) is not a substitution, so the pipe it straddles
# must still refuse the mask.
_case "#1863 F2 arm: a single-quoted '\$(' … ')' straddling the pipe still fires" fire \
    "$(printf 'cat <<EOF '"'"'$('"'"' | bash '"'"')'"'"'\nsbatch job.sh\nEOF')"
_case "#1863 F2 arm: a single-quoted backtick pair straddling the pipe still fires" fire \
    "$(printf 'cat <<EOF '"'"'`'"'"' | bash '"'"'`'"'"'\nsbatch job.sh\nEOF')"
_case "#1863 F2 arm: an escaped \\\$( … ) straddling the pipe still fires" fire \
    "$(printf 'cat <<EOF \\$(x | bash)\nsbatch job.sh\nEOF')"
# The mask covers the BODY only: a real launch after the delimiter still fires.
_case "#1863 arm: a real sbatch AFTER the masked heredoc still fires" fire \
    "$(printf 'f=$(ls x | head -1); cat > "$f" <<'"'"'EOF'"'"'\nbody\nEOF\nsbatch job.sh')"
# Was a DECLARED RESIDUAL (a substitution holding a NESTED paren group is not
# removed, so its pipe refused the mask). Closed by #1868 item 2: that pipe sits
# LEFT of the opener, and only the text after the delimiter is read now.
_case "#1863 residual closed by #1868: \$(… | (…)) BEFORE the opener no longer refuses the mask" quiet \
    "$(printf 'f=$(ls x | (head -1)); cat > "$f" <<EOF\nsbatch job.sh\nEOF')"

echo "=== #1868: heredoc-mask residuals — quote WALK, pipes AFTER the opener only, bare subshells ==="
# Each MUST-FIX case below was run against the base hook (414bd080) and gave
# the OPPOSITE answer; each NEGATIVE gave the same answer on both. The report
# for this change carries that table.
#
# ITEM 1, the MISS direction. A `'` inside "…" is not a quote, but the parity
# count read it as one: `"'"'$(' | bash ')'` looked unquoted, the literal group
# was removed with the only pipe inside it, and a body bash runs was masked.
_case "#1868 item 1 MUST-FIX: \"'\" then a single-quoted '\$(' straddling | bash fires" fire \
    "$(printf 'cat <<EOF "'"'"'"'"'"'$('"'"' | bash '"'"')'"'"'\nsbatch job.sh\nEOF')"
_case "#1868 item 1 MUST-FIX: \"'\" then a single-quoted backtick pair straddling | bash fires" fire \
    "$(printf 'cat <<EOF "'"'"'"'"'"'`'"'"' | bash '"'"'`'"'"'\nsbatch job.sh\nEOF')"
# The same count decided whether a `<<` is an opener at all. Here it is TEXT
# (inside '…'), bash runs the next line as a command, and the parity read it
# as an opener and masked that line until `EOF`.
_case "#1868 item 1 MUST-FIX: a '<<EOF' that is text after \"'\" masks nothing (the next line runs)" fire \
    "$(printf 'cat "'"'"'" '"'"'<<EOF'"'"'\nsbatch job.sh\nEOF')"
_case "#1868 item 1 negative: a quoted apostrophe arg, no pipe, is still masked" quiet \
    "$(printf 'cat <<EOF "it'"'"'s ok" > f\nsbatch job.sh\nEOF')"
_case "#1868 item 1 negative: \"x\" then a real \$(… | …) after the opener is still removed" quiet \
    "$(printf 'cat <<EOF "x" $(ls x | head -1) > f\nsbatch job.sh\nEOF')"
# DECLARED RESIDUAL, false-positive side: the parity count is KEPT beside the
# walk (removal stops when EITHER says single-quoted), so a "'" before a real
# substitution still refuses the mask. Conservative by construction.
_case "KNOWN FP (#1868): \"'\" then a real \$(… | …) after the opener still refuses the mask" fire \
    "$(printf 'cat <<EOF "'"'"'" $(ls x | head -1) > f\nsbatch job.sh\nEOF')"
# ITEM 2, the false-alarm direction: only a pipe AFTER the delimiter counts.
_case "#1868 item 2 MUST-FIX: a pipe in an EARLIER pipeline does not refuse the mask" quiet \
    "$(printf 'a | tail -1 && cat > f <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF')"
_case "#1868 item 2 MUST-FIX: a pipe INTO the consumer (stdin replaced by the heredoc) does not refuse it" quiet \
    "$(printf 'x | cat > f <<EOF\nsbatch job.sh\nEOF')"
_case "#1868 item 2 arm: an earlier pipeline AND a later | bash still fires" fire \
    "$(printf 'a | tail -1 && cat <<EOF | bash\nsbatch job.sh\nEOF')"
_case "#1868 item 2 arm: a pipe after a redirect target still fires" fire \
    "$(printf 'cat <<EOF > f | bash\nsbatch job.sh\nEOF')"
_case "KNOWN FP (#1868): a pipe in a LATER pipeline on the opener line still refuses the mask" fire \
    "$(printf 'cat > f <<EOF; x | y\nsbatch job.sh\nEOF')"
# A BARE `( … )` subshell: its output leaves through a `)` on a later line.
_case "#1868 MUST-FIX: ( cat <<EOF … EOF ) | bash fires (the body runs)" fire \
    "$(printf '( cat <<EOF\nsbatch job.sh\nEOF\n) | bash')"
_case "#1868 negative: body=\$(cat <<'EOF' … ) is still masked (\$( is not a bare subshell)" quiet \
    "$(printf 'body=$(cat <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF\n)')"

echo "=== #1870 item 3: ANSI-C \$'…' quoting in the quote walk ==="
# Inside `$'…'` a backslash escapes the next character, so `$'\''` is ONE
# string. The walk read it as '…' closed early and a quote opened after it, so
# it came out UNQUOTED where bash is inside '…', removed a LITERAL `$(' … ')`
# pair with the only pipe in it, and masked a body bash runs (miss direction).
_case "#1870 item 3 MUST-FIX: \$'\\'' then a single-quoted '\$(' straddling | bash fires" fire \
    "$(printf '%s\nsbatch job.sh\nEOF' "cat <<EOF \$'\\'' '\$(' | bash ')'")"
_case "#1870 item 3 MUST-FIX: \$'\\'' then a single-quoted backtick pair straddling | bash fires" fire \
    "$(printf '%s\nsbatch job.sh\nEOF' "cat <<EOF \$'\\'' '\`' | bash '\`'")"
# The other direction, a false alarm on base: an ANSI-C string with an EVEN
# quote count before a REAL substitution. Base read the walk as inside '…' and
# kept the substitution's pipe; the walk now closes the string where bash does.
_case "#1870 item 3 MUST-FIX: \$'\\'\\'' then a real \$(… | …) after the opener is removed (masked)" quiet \
    "$(printf '%s\nsbatch job.sh\nEOF' "cat <<EOF \$'\\'\\'' \$(ls x | head -1) > f")"
# Only an ODD run of `$` opens ANSI-C: `$$'` is the PID, then an ordinary '…'.
_case "#1870 item 3 arm: \$\$'\$(' | bash ')' — the PID then a plain quote — still fires" fire \
    "$(printf '%s\nsbatch job.sh\nEOF' "cat <<EOF \$\$'\$(' | bash ')'")"
_case "#1870 item 3 arm: an escaped \\\$'\$(' | bash ')' is a plain quote and still fires" fire \
    "$(printf '%s\nsbatch job.sh\nEOF' "cat <<EOF \\\$'\$(' | bash ')'")"

echo "=== #1870 item 5: a \$(cat <<EOF whose value may run ==="
# The body of `$(cat <<EOF` becomes the substitution's VALUE, so what may run it
# is the command AROUND the `$(`. It is masked only as an assignment's value or
# as an argument of a named data consumer, and then only if the `)` that closes
# it, on a later line, carries no pipe.
_case "#1870 item 5 MUST-FIX: echo \$(cat <<EOF … EOF) | bash fires (was the #1868 gap)" fire \
    "$(printf 'echo $(cat <<EOF\nsbatch job.sh\nEOF\n) | bash')"
_case "#1870 item 5 MUST-FIX: \$(cat <<EOF … EOF) at COMMAND POSITION fires (the value is the command)" fire \
    "$(printf '$(cat <<EOF\nsbatch job.sh\nEOF\n)')"
_case "#1870 item 5 MUST-FIX: eval \$(cat <<EOF … EOF) fires" fire \
    "$(printf 'eval $(cat <<EOF\nsbatch job.sh\nEOF\n)')"
_case "#1870 item 5 MUST-FIX: a data consumer's \$(cat <<EOF, piped on the closing line, fires" fire \
    "$(printf 'gh api x --jq $(cat <<EOF\nsbatch job.sh\nEOF\n) | bash')"
_case "#1870 item 5 negative: export body=\$(cat <<'EOF' … ) is masked" quiet \
    "$(printf 'export body=$(cat <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF\n)')"
_case "#1870 item 5 negative: gh … --body \$(cat <<'EOF' … ) > f, no pipe on the close, is masked" quiet \
    "$(printf 'gh pr create --body $(cat <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF\n) > /dev/null')"
_case "#1870 item 5 negative: a pipe inside a complete \$(…) after the closing ) does not refuse it" quiet \
    "$(printf 'x=$(cat <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF\n) ; y=$(ls | head -1)')"
# The conservative arms. Each errs toward the false positive, by design.
_case "#1870 item 5 arm: a held body with no closing ) line is released and fires" fire \
    "$(printf 'x=$(cat <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF')"
# A closing `)` line that ENDS IN A BACKSLASH continues onto the next line, so
# a pipe there (`) \` / `  | bash`) is invisible to a decision that reads only
# the `)` line (#1873 N1). Such a line is undecided and releases the body
# verbatim; the cost is the false positive pinned after it.
_case "#1873 N1 MUST-FIX: a backslash-continued closing ) line whose pipe is on the NEXT line fires" fire \
    "$(printf 'gh api x --jq $(cat <<EOF\nsbatch job.sh\nEOF\n) \\\n  | bash')"
_case "KNOWN FP (#1873 N1): a backslash-continued closing ) line with NO pipe after it still fires" fire \
    "$(printf 'body=$(cat <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF\n) \\\n  && echo done')"
_case "#1873 N1 control: the same close WITHOUT the backslash, no pipe, is masked" quiet \
    "$(printf 'body=$(cat <<'"'"'EOF'"'"'\nsbatch job.sh\nEOF\n) && echo done')"
_case "KNOWN FP (#1870): a later opener on the same line releases the held \$(cat <<A body" fire \
    "$(printf 'x=$(cat <<'"'"'A'"'"'; cat > f <<'"'"'B'"'"'\nsbatch job.sh\nA\nbody\nB\n)')"

# THE VIEW IS BOUNDED at 8 per line (a view per opener costs removals x text
# length; unbounded, a contrived 20 KB line took 4.3 s against base's 0.75 s).
# Past the bound the raw text is the view, so a pipe inside a complete
# substitution refuses the mask again: the 9th opener here fires, and the same
# shape as the 1st opener is quiet. Pins the bound as a BEHAVIOUR, which a
# timing assertion under load could not.
_hd9=""; _hd9b=""
for _i in 1 2 3 4 5 6 7 8; do _hd9+="cat > f$_i <<a$_i; "; _hd9b+=$'\nx\na'"$_i"; done
_case "#1868 bound: the 9th data-consumer opener on a line reads the RAW text (\$(x | y) refuses)" fire \
    "${_hd9}cat <<a9 \$(x | y) > f9${_hd9b}"$'\nsbatch job.sh\na9'
_case "#1868 bound control: the same opener FIRST on its line is masked" quiet \
    "$(printf 'cat <<a9 $(x | y) > f9\nsbatch job.sh\na9')"

_EXPECTED_ASSERTIONS=282   # +3: #1873 N1 backslash-continued closing ) line (fire, known FP, control); +14: #1870 ANSI-C walk (5 cases) and $(cat <<EOF value (9 cases; the #1868 gap closed, the $x dataflow gap opened); +16: #1868 heredoc-mask residuals (15 cases, 1 gap); +40: #1864 per-invocation dry runs (+2 gaps), #1863 pipe inside a complete substitution; +4: ncbundle32-sk R2 (compound reassignment); +18: #1859 echoed substitution / option-value skip; +17: #1854 dry runs / file-then-cat attribution; +5: ncbundle27-sk R1 (conditional vouch); +12: ncbundle27-sk F1 (#1832 B invariant); +26: #1832 command position / spoke-first; +3: #1439 launcher identity on the row; +3: #1629 phantom parsable ids; +2: #1727 id 0 / $(…)
_ran=$(( PASS + FAIL + 1 ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    ok "every declared assertion executed ($_EXPECTED_ASSERTIONS)"
else
    bad "assertion count drifted" "ran $_ran, expected $_EXPECTED_ASSERTIONS"
fi

th_summary_and_exit
