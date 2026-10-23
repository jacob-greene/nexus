#!/usr/bin/env bash
# test-fs-degraded-note.sh — the watcher keeps TALKING while the project tree
# is read-only, through the normal paste path, and never types over an
# operator draft (your-org/nexus-code#1724).
#
#   N1  the note's backoff: first after BASE, then doubling, capped — never
#       silent while the condition holds, never every cycle.
#   N2  a due note names the failing path and its errno (EROFS here, via the
#       probe's writer seam), goes through the paste function with STATE_DIR
#       pointed at the private run dir (NOT the read-only tree) in
#       no-liveness-stamp mode, and the status file records it.
#   N3  THE REFUSAL, through the REAL paste_to_target (main.sh) + pd_deliver
#       (_paste-deliver.sh): an operator draft in the box (input=typed, and
#       input=? undecidable) means NO keystrokes reach tmux, and the refusal is
#       in the log and the status file. N3c is the positive control: a clear
#       box IS pasted into, so N3a/b's silence is the refusal, not a dead rig.
#   N4  the one-shot escalation's last-resort pane notice takes the same path:
#       with every out-of-band channel down and a draft in the box, it types
#       NOTHING (it used to `send-keys -l` the alarm and press Enter).
#   N5  `ng degraded status` (degraded-status.sh) reports the watcher's last
#       word and a live probe, exits 1 while the watcher says degraded, and
#       creates nothing when there is no status file.
#
# Run: bash monitor/watcher/test-fs-degraded-note.sh

set -uo pipefail
if [[ -z "${_FSNOTE_TEST_REEXEC:-}" ]]; then
    export _FSNOTE_TEST_REEXEC=1
    exec env -u NEXUS_ROOT -u NEXUS_LOCALS -u NEXUS_STATE_DIR -u TMUX -u NEXUS_DEGRADED_RUNDIR \
        bash "${BASH_SOURCE[0]}" "$@"
fi

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_dir/.." && pwd)

WORK=$(mktemp -d)
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
if [[ "$(id -u)" == "0" ]]; then
    th_skip "read-only fixtures" "running as root: a 0555 dir is still writable"
    th_summary_and_exit
fi

export NEXUS_DEGRADED_RUNDIR="$WORK/run"   # never the operator's /tmp run dir
LOG="$WORK/watcher.log"; : > "$LOG"
log() { printf '%s\n' "$*" >> "$LOG"; }

# tmux on PATH (a PROGRAM, not a function: pd_pane_verdict refuses to trust a
# function-shadowed tmux). Logs every call; answers list-windows with the target.
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_CALLS:-/dev/null}"
case "$1" in
    list-windows) printf 'orchestrator\n' ;;
    display-message|display) printf '0\n' ;;
esac
exit 0
EOF
# A pane-state stand-in for PD_PANE_STATE_BIN: answers whatever $PS_LINE says.
cat > "$STUB/pane-state" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${PS_LINE:-state=idle active=0 input=blank}"
EOF
chmod +x "$STUB/tmux" "$STUB/pane-state"
export PATH="$STUB:$PATH"
export PD_PANE_STATE_BIN="$STUB/pane-state"

source "$_dir/_lib.sh"
source "$_dir/_fs_guard.sh"

reset_note() { FS_DEGRADED=1; FS_ONSET=$1; FS_NOTE_NEXT=0; FS_NOTE_GAP=0; FS_NOTE_COUNT=0; }

echo '=== N1: backoff — first after BASE, doubling, capped, never silent ==='
export MONITOR_FS_DEGRADED_NOTE_BASE_SECONDS=300 MONITOR_FS_DEGRADED_NOTE_MAX_SECONDS=1200
reset_note 1000
seq_out=""
for t in 1000 1299 1300 1301 1899 1900 3099 3100 4299 4300; do
    if _fs_note_due "$t"; then seq_out+="$t:Y "; else seq_out+="$t:n "; fi
done
assert_eq "N1 due exactly at onset+300, +600, then every 1200 (cap)" "$seq_out" \
    "1000:n 1299:n 1300:Y 1301:n 1899:n 1900:Y 3099:n 3100:Y 4299:n 4300:Y "
reset_note 0; n=0
for (( t = 0; t <= 18 * 3600; t += 15 )); do _fs_note_due "$t" && n=$((n + 1)); done
# 300, 900, 2100, then every 1200 s up to 64800: 3 + floor((64800-2100)/1200) = 55.
assert_eq "N1 an 18 h incident gets 55 notes at 15 s cycles (not 1, not 4320)" "$n" "55"

echo '=== N2: a due note names path + errno and pastes with a PRIVATE STATE_DIR ==='
RO_STATE="$WORK/nexus/monitor/.state"; mkdir -p "$RO_STATE"; chmod 0555 "$RO_STATE"
cat > "$WORK/erofs-writer" <<'EOF'
#!/usr/bin/env bash
echo "bash: $1: Read-only file system" >&2; exit 1
EOF
chmod +x "$WORK/erofs-writer"
stub_paste() {
    printf 'target=%s state_dir=%s mode=%s\n' "$1" "$STATE_DIR" "${3:-}" > "$WORK/paste.args"
    cp "$2" "$WORK/paste.body"
    return "${STUB_PASTE_RC:-0}"
}
reset_note 1000
STATE_DIR="$RO_STATE" TARGET=orchestrator FS_NOTE_PASTE_FN=stub_paste \
    NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_degraded_note_tick 1300
body=$(cat "$WORK/paste.body" 2>/dev/null)
assert_contains "N2 the note names the failing path" "$body" "$RO_STATE"
assert_contains "N2 …and its errno" "$body" "EROFS"
assert_contains "N2 …and where the detail lives" "$body" "ng degraded status"
assert_contains "N2 …and carries an emit signature (receipt-checkable)" "$body" "nexus-emit-sig "
args=$(cat "$WORK/paste.args" 2>/dev/null)
assert_contains "N2 pasted to the target" "$args" "target=orchestrator"
assert_contains "N2 with STATE_DIR = the private run dir, never the read-only tree" "$args" "state_dir=$WORK/run/paste-state"
assert_contains "N2 in no-liveness-stamp mode" "$args" "mode=no-liveness-stamp"
sf=$(_fs_status_path "$RO_STATE")
assert_contains "N2 status file: mode" "$(cat "$sf" 2>/dev/null)" "mode=degraded"
assert_contains "N2 status file: verdict" "$(cat "$sf" 2>/dev/null)" "verdict=EROFS"
assert_contains "N2 status file: delivery" "$(cat "$sf" 2>/dev/null)" "delivery=delivered"
assert_contains "N2 the log line says it went out" "$(cat "$LOG")" "DEGRADED note #1 (EROFS) — delivered"

echo '=== N3: the REAL paste path refuses an operator draft — nothing typed ==='
# main.sh runs its loop at source time, so extract the two functions (the
# test-paste-dead-pane-guard.sh device).
eval "$(sed -n '/^paste_to_target() {/,/^}/p;/^_paste_to_target_unlocked() {/,/^}/p' "$_dir/main.sh")"
declare -F paste_to_target >/dev/null && declare -F _paste_to_target_unlocked >/dev/null \
    && ok=yes || ok=no
assert_eq "N3 fixture: main.sh's paste_to_target was extracted" "$ok" "yes"
# A live pane (the dead-pane guard is not under test here) and no @id lookup.
_tmux_pane_is_dead() { NEXUS_PANE_LIVE_VERDICT=live; return 1; }
resolve_window_id() { return 1; }
source "$MON/_paste-deliver.sh"
export PD_SUBMIT_TIMEOUT_MS=300 PD_ENTER_RETRY_MAX=0

draft_case() {   # <label> <pane-state line>
    reset_note 1000; : > "$LOG"
    export TMUX_CALLS="$WORK/tmux-$1.log"; : > "$TMUX_CALLS"
    PS_LINE="$2" STATE_DIR="$RO_STATE" TARGET=orchestrator \
        NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_degraded_note_tick 1300
}
for c in "a|state=user-typing active=1 input=typed" "b|state=user-typing active=1 input=?" "d|state=busy active=1 input=typed"; do
    lbl="${c%%|*}"; line="${c#*|}"
    draft_case "$lbl" "$line"
    typed=$(grep -cE '^(send-keys|paste-buffer|load-buffer|set-buffer)' "$TMUX_CALLS")
    assert_eq "N3$lbl ($line): NO keystroke or buffer reached tmux" "$typed" "0"
    assert_contains "N3$lbl the refusal is logged" "$(cat "$LOG")" "refused"
    assert_contains "N3$lbl …and recorded for ng degraded status" "$(cat "$(_fs_status_path "$RO_STATE")")" "delivery=refused"
done
# N3c: positive control — a clear box IS pasted into, through the same rig.
draft_case c "state=idle active=0 input=blank"
pasted=$(grep -cE '^(paste-buffer|load-buffer)' "$TMUX_CALLS")
assert_eq "N3c control: a CLEAR box is pasted into (the rig can type)" "$([[ $pasted -ge 1 ]] && echo yes || echo "no ($pasted)")" "yes"
assert_not_contains "N3c …and is not reported refused" "$(cat "$LOG")" "refused"

echo '=== N4: the escalation last resort types NOTHING over a draft ==='
_reset() { FS_DEGRADED=0; FS_ESCALATED=0; FS_CHANNELS=''; FS_DEGRADED_CYCLES=0; FS_ONSET=0; }
_reset; : > "$LOG"
export TMUX_CALLS="$WORK/tmux-n4.log"; : > "$TMUX_CALLS"
# Every out-of-band channel down: no sandbox-notify on PATH, GitHub refused.
_nexus_critical_alarm() { return 1; }
_nexus_github_incident_escalate() { return 1; }
PS_LINE="state=user-typing active=1 input=typed" STATE_DIR="$RO_STATE" \
    NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator _fs_escalate_once
typed=$(grep -cE '^(send-keys|paste-buffer|load-buffer)' "$TMUX_CALLS")
assert_eq "N4 no send-keys/paste reached tmux over an operator draft" "$typed" "0"
assert_contains "N4 the last-resort refusal is logged" "$(cat "$LOG")" "last-resort pane notice — refused"
assert_not_contains "N4 the refused notice is not credited as a channel" "$FS_CHANNELS" "tmux-paste"

echo '=== N5: ng degraded status ==='
chmod 0755 "$RO_STATE"
FR="$WORK/nexus"; mkdir -p "$FR/monitor/.state/skeptic/pending" "$FR/monitor/.state/longjob" \
    "$FR/monitor/.state/requests" "$FR/reports" "$FR/work"
out=$(NEXUS_ROOT="$FR" NEXUS_STATE_DIR="$RO_STATE" bash "$MON/degraded-status.sh" 2>&1); rc=$?
assert_eq "N5 the watcher's last word is DEGRADED ⇒ rc 1 even though the probe is OK now" "$rc" "1"
assert_contains "N5 shows the watcher's status file" "$out" "mode=degraded"
assert_contains "N5 shows the live probe" "$out" "summary:"
assert_contains "N5 says the two disagree" "$out" "last word is DEGRADED but every surface probes OK"
STATE_DIR="$RO_STATE" _fs_status_write mode=ok "state_dir=$RO_STATE"
out=$(NEXUS_ROOT="$FR" NEXUS_STATE_DIR="$RO_STATE" bash "$MON/degraded-status.sh" 2>&1); rc=$?
assert_eq "N5 watcher ok + probe OK ⇒ rc 0" "$rc" "0"
out=$(NEXUS_DEGRADED_RUNDIR="$WORK/never" NEXUS_ROOT="$FR" NEXUS_STATE_DIR="$RO_STATE" \
      bash "$MON/degraded-status.sh" 2>&1); rc=$?
assert_eq "N5 no status file ⇒ rc 0 (probe OK)" "$rc" "0"
assert_eq "N5 …and the run dir was NOT created (status writes nothing)" "$([[ -e "$WORK/never" ]] && echo created || echo absent)" "absent"
out=$(bash "$MON/ng" degraded status --help 2>&1); rc=$?
assert_eq "N5 ng routes 'degraded status' (usage rc 2, not 'not implemented')" "$rc" "2"

echo '=== N6: onset broadcasts STOP to every worker pane, heal broadcasts RESUME (#1724) ==='
# N6-N9 pin the STOP to the FIRST degraded cycle; the default onset hysteresis
# (2 cycles, skeptic note on #1799) is N10's subject.
export MONITOR_FS_BROADCAST_ONSET_CYCLES=1
# The operator's 2026-10-09 ask: tell workers to stop and wait, so they do not
# each find out by a failing write. Workers come from the watcher's own lister
# (seamed); delivery is the same refusal-respecting paste path as N2.
chmod 0555 "$RO_STATE"
bc_paste() {
    printf '%s|%s|%s\n' "$1" "$STATE_DIR" "$(head -1 "$2")" >> "$WORK/bc.log"
    [[ "$1" == w2 ]] && return 7    # w2 has an operator draft: refused, nothing typed
    return 0
}
bc_workers() { printf 'w1\t0\t1\nw2\t0\t2\nw3-sk\t0\t3\n'; }
_reset; : > "$LOG"; : > "$WORK/bc.log"
_nexus_critical_alarm() { return 0; }
STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
    FS_NOTE_PASTE_FN=bc_paste FS_WORKER_LIST_FN=bc_workers \
    NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_guard_tick >/dev/null
bc=$(cat "$WORK/bc.log")
# Count WORKER targets only. The one-shot escalation's last-resort notice to
# the ORCHESTRATOR also goes through this paste function whenever no
# out-of-band channel answered — correctly — and whether one answers depends
# on the caller's PATH (an agent shell's BASH_ENV prelude puts sandbox-notify
# there; CI has none). Counting every READ-ONLY line was green in every agent
# shell and red in all four CI bands at 7ebd7d29 (4 vs 3, and 1 vs 0 in N7).
assert_eq "N6 onset: one STOP paste per worker pane (3)" \
    "$(grep -vc '^orchestrator|' <<<"$bc")" "3"
assert_contains "N6 the STOP note tells the worker to WAIT" "$bc" "w1|$WORK/run/paste-state|[nexus watcher] The project tree is READ-ONLY"
assert_contains "N6 …and pastes with the PRIVATE run dir, never the read-only tree" "$bc" "w3-sk|$WORK/run/paste-state|"
# Skeptic F2 on #1799: every recorded outage ended in a sandbox restart, which
# never sends RESUME, so the STOP note must say a resumed session counts.
assert_contains "N6 the STOP note says a session resumed after a sandbox restart means continue" \
    "$(grep '^w1|' "$WORK/bc.log")" "OR your session is resumed after a sandbox restart"
assert_contains "N6 the refused pane is logged as refused (nothing typed)" "$(cat "$LOG")" "worker broadcast (stop) to w2 — refused"
assert_contains "N6 the tally names delivered of total" "$(cat "$LOG")" "worker broadcast (stop): 2 of 3 worker pane(s) delivered"
# A second degraded cycle must NOT re-broadcast (once per transition).
: > "$WORK/bc.log"
STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
    FS_NOTE_PASTE_FN=bc_paste FS_WORKER_LIST_FN=bc_workers \
    NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_guard_tick >/dev/null
assert_eq "N6 a second degraded cycle does not re-broadcast STOP" "$(grep -vc '^orchestrator|' "$WORK/bc.log")" "0"
# Heal: RESUME to every worker.
chmod 0755 "$RO_STATE"; : > "$WORK/bc.log"
_nexus_fs_incident_record() { return 0; }; _nexus_fs_incident_close_comment() { return 0; }
STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
    FS_NOTE_PASTE_FN=bc_paste FS_WORKER_LIST_FN=bc_workers _fs_guard_tick >/dev/null
assert_eq "N6 heal: one RESUME paste per worker pane" "$(grep -c 'RESUME: the project tree is writable again' "$WORK/bc.log")" "3"

echo '=== N7: MONITOR_FS_DEGRADED_BROADCAST=0 turns it off; a missing lister is logged, not fatal ==='
chmod 0555 "$RO_STATE"; _reset; : > "$LOG"; : > "$WORK/bc.log"
STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator MONITOR_FS_DEGRADED_BROADCAST=0 \
    FS_NOTE_PASTE_FN=bc_paste FS_WORKER_LIST_FN=bc_workers \
    NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_guard_tick >/dev/null
assert_eq "N7 broadcast off: no worker paste" "$(grep -vc '^orchestrator|' "$WORK/bc.log")" "0"
_reset; : > "$LOG"
STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
    FS_NOTE_PASTE_FN=bc_paste FS_WORKER_LIST_FN=no_such_lister_fn \
    NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_guard_tick >/dev/null
assert_contains "N7 no lister: skipped and logged" "$(cat "$LOG")" "worker broadcast (stop) skipped — no worker lister loaded"
chmod 0755 "$RO_STATE"

echo '=== N8: the degraded run dir is DERIVED from the managed $TMPDIR, never a literal path (#1724) ==='
# Operator, 2026-10-10 (#1724): small state only, under the
# session-managed scratch tree; no hardcoded location. Run in subshells with
# the suite's own NEXUS_DEGRADED_RUNDIR override removed.
rd() { ( unset NEXUS_DEGRADED_RUNDIR; [ "$1" = - ] && unset TMPDIR || export TMPDIR="$1"; nexus_degraded_rundir; echo "|rc=$?" ); }
M="$WORK/base/claude-1000/tmp"
assert_eq "N8 a per-agent leaf maps to the managed tree's shared root (watcher and agents agree)" "$(rd "$M/agent-w1")" "$M/nexus-degraded|rc=0"
assert_eq "N8 …with a trailing slash too" "$(rd "$M/agent-w1-sk/")" "$M/nexus-degraded|rc=0"
assert_eq "N8 the managed root itself is used as is" "$(rd "$M")" "$M/nexus-degraded|rc=0"
assert_eq "N8 a caller's own TMPDIR is used as is (the fallback lives UNDER \$TMPDIR)" "$(rd "$WORK/own-tmp")" "$WORK/own-tmp/nexus-degraded|rc=0"
# No TMPDIR is the WATCHER's state (skeptic N2 on #1799): derived by the same
# tmpdir.sh every agent shell runs, under a fixture base so the real
# /tmp/claude-<uid> is never touched.
assert_eq "N8 no TMPDIR and no override: DERIVED from the managed tree (tmpdir.sh), the watcher's case" \
    "$( NEXUS_TMPDIR_BASE="$WORK/tb8" rd - )" "$WORK/tb8/claude-$(id -u)/tmp/nexus-degraded|rc=0"
out=$( NEXUS_TMPDIR_BASE=rel rd - 2>"$WORK/n8.err" )
assert_eq "N8 no managed place can be established (unusable base): rc 1, NO path is guessed" "$out" "|rc=1"
assert_contains "N8 …and the refusal is LOUD, naming #1628" "$(cat "$WORK/n8.err")" "your-org/nexus-code#1628"
assert_eq "N8 NEXUS_DEGRADED_RUNDIR overrides the derivation" "$( NEXUS_DEGRADED_RUNDIR=/x/y TMPDIR="$M/agent-w1" nexus_degraded_rundir )" "/x/y"
# Mechanism has no literal fallback left: a status path with no managed place is a REFUSAL.
out=$( unset NEXUS_DEGRADED_RUNDIR TMPDIR; export NEXUS_TMPDIR_BASE=rel; _fs_status_path "$RO_STATE" 2>/dev/null; echo "|rc=$?" )
assert_eq "N8 _fs_status_path refuses (rc 1, no path) when there is no managed place" "$out" "|rc=1"
assert_eq "N8 no hardcoded /tmp/nexus-degraded fallback remains in the resolver or its users" \
    "$(grep -lE '/tmp/nexus-degraded' "$MON/_degraded-rundir.sh" "$_dir/_fs_guard.sh" "$MON/degraded-status.sh" "$MON/notifywrap/sandbox-notify" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo '=== N9: the WATCHER shape (no TMPDIR, no override, no agent key) still delivers end to end (#1724, skeptic N2) ==='
# Every case above pins NEXUS_DEGRADED_RUNDIR, which is exactly why a resolver
# that returned rc 1 without TMPDIR stayed green while the live watcher (no
# TMPDIR in its environ) would deliver NOTHING. This runs the onset tick and a
# due note in the watcher's environment shape: TMPDIR, NEXUS_DEGRADED_RUNDIR,
# NEXUS_TMPDIR_AGENT, BASH_ENV and TZ all unset, a fixture NEXUS_TMPDIR_BASE.
D9="$WORK/tb9/claude-$(id -u)/tmp/nexus-degraded"
bc9_paste() { printf '%s|%s|%s\n' "$1" "$STATE_DIR" "$(head -1 "$2")" >> "$WORK/bc9.log"; return 0; }
bc9n_paste() { printf 'target=%s state_dir=%s\n' "$1" "$STATE_DIR" >> "$WORK/bc9n.log"; return 0; }
bc9_workers() { printf 'w1\t0\t1\nw2\t0\t2\n'; }
_reset; : > "$LOG"; : > "$WORK/bc9.log"; : > "$WORK/bc9n.log"; chmod 0555 "$RO_STATE"
(
    unset NEXUS_DEGRADED_RUNDIR TMPDIR NEXUS_TMPDIR_AGENT BASH_ENV TZ
    export NEXUS_TMPDIR_BASE="$WORK/tb9"
    STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
        FS_NOTE_PASTE_FN=bc9_paste FS_WORKER_LIST_FN=bc9_workers \
        NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_guard_tick >/dev/null
    reset_note 1000
    STATE_DIR="$RO_STATE" TARGET=orchestrator FS_NOTE_PASTE_FN=bc9n_paste \
        NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_degraded_note_tick 1300
    printf 'TMPDIR=%s TZ=%s\n' "${TMPDIR-<unset>}" "${TZ-<unset>}" > "$WORK/n9.env"
)
chmod 0755 "$RO_STATE"
_n9_status="$D9/$(printf '%s' "$RO_STATE" | tr -c 'A-Za-z0-9._-' '_').status"
assert_eq "N9 the status file is written under the DERIVED run dir" "$([[ -s "$_n9_status" ]] && echo written || echo "absent: $_n9_status")" "written"
assert_contains "N9 the worker STOP broadcast reaches every worker (2 of 2)" "$(cat "$LOG")" "worker broadcast (stop): 2 of 2 worker pane(s) delivered"
assert_contains "N9 …pasting with the derived run dir's paste state" "$(cat "$WORK/bc9.log")" "w1|$D9/paste-state|"
assert_contains "N9 the due note is DELIVERED to the orchestrator from the derived run dir" "$(cat "$WORK/bc9n.log")" "target=orchestrator state_dir=$D9/paste-state"
assert_contains "N9 the caller's TMPDIR is still unset afterwards (the derivation ran in a subshell)" "$(cat "$WORK/n9.env")" "TMPDIR=<unset> "
assert_contains "N9 the caller's TZ is still unset afterwards (tmpdir.sh's TZ export did not leak)" "$(cat "$WORK/n9.env")" "TZ=<unset>"

echo '=== N10: onset HYSTERESIS — a one-probe transient pastes NO worker; the 2nd failed probe does (#1799) ==='
unset MONITOR_FS_BROADCAST_ONSET_CYCLES
h_paste() { printf '%s|%s\n' "$1" "$(head -1 "$2")" >> "$WORK/h.log"; return 0; }
h_workers() { printf 'w1\t0\t1\nw2\t0\t2\n'; }
h_tick() {
    STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
        FS_NOTE_PASTE_FN=h_paste FS_WORKER_LIST_FN=h_workers \
        NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_guard_tick >/dev/null
}
_reset; FS_BC_QUEUE=""; FS_BC_STOPPED=0; : > "$LOG"; : > "$WORK/h.log"
chmod 0555 "$RO_STATE"; h_tick
assert_eq "N10 first failed probe: NO worker paste" "$(grep -vc '^orchestrator|' "$WORK/h.log")" "0"
chmod 0755 "$RO_STATE"; h_tick
assert_eq "N10 healed after one probe: no RESUME either" "$(grep -vc '^orchestrator|' "$WORK/h.log")" "0"
assert_contains "N10 …and the log says why" "$(cat "$LOG")" "no STOP was broadcast, so no RESUME is owed"
_reset; : > "$WORK/h.log"
chmod 0555 "$RO_STATE"; h_tick; h_tick
assert_eq "N10 second consecutive failed probe: STOP to both workers" \
    "$(grep -c '^w[12]|\[nexus watcher\] The project tree is READ-ONLY' "$WORK/h.log")" "2"
chmod 0755 "$RO_STATE"; h_tick
assert_eq "N10 …and the heal then owes and sends RESUME to both" "$(grep -c '^w[12]|\[nexus watcher\] RESUME' "$WORK/h.log")" "2"

echo '=== N11: the broadcast is BOUNDED per tick and the rest CARRIED, in order (#1799 F4) ==='
s_paste() { printf '%s|%s\n' "$1" "$(head -1 "$2")" >> "$WORK/s.log"; sleep 1; return 0; }
s_workers() { printf 'w1\t0\t1\nw2\t0\t2\nw3\t0\t3\nw4\t0\t4\n'; }
s_tick() {
    STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
        MONITOR_FS_BROADCAST_ONSET_CYCLES=1 MONITOR_FS_BROADCAST_BUDGET_SECONDS=1 \
        FS_NOTE_PASTE_FN=s_paste FS_WORKER_LIST_FN=s_workers \
        NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_guard_tick >/dev/null
}
_reset; FS_BC_QUEUE=""; FS_BC_STOPPED=0; : > "$LOG"; : > "$WORK/s.log"
chmod 0555 "$RO_STATE"; s_tick
n1=$(grep -c '^w[0-9]|' "$WORK/s.log")
assert_eq "N11 onset tick stops at the 1 s budget (1 pane, the rest owed)" "$n1" "1"
assert_contains "N11 …and logs the carry" "$(cat "$LOG")" "3 carried to the next tick"
s_tick; s_tick; s_tick
assert_eq "N11 later ticks drain it: w1..w4, each once, in order" \
    "$(grep -o '^w[0-9]' "$WORK/s.log" | tr '\n' ' ')" "w1 w2 w3 w4 "
assert_contains "N11 the tally comes when the queue drains" "$(cat "$LOG")" "worker broadcast (stop): 4 of 4 worker pane(s) delivered"
# A heal with STOPs still queued drops them and RESUMEs everyone, never a STOP after it.
_reset; FS_BC_QUEUE=""; FS_BC_STOPPED=0; : > "$LOG"; : > "$WORK/s.log"
s_tick
chmod 0755 "$RO_STATE"; : > "$WORK/s.log"; s_tick; s_tick; s_tick; s_tick
assert_eq "N11 heal mid-STOP: no STOP is pasted after the heal" "$(grep -c 'READ-ONLY' "$WORK/s.log")" "0"
assert_eq "N11 …every worker gets RESUME" "$(grep -c '|\[nexus watcher\] RESUME' "$WORK/s.log")" "4"
assert_contains "N11 …and the dropped STOPs are said out loud" "$(cat "$LOG")" "superseded by (resume) — 3 undelivered pane(s) dropped"

echo '=== N12: a heal with `ng degraded enter` still in force owes `ng degraded exit` (#1830 skeptic) ==='
# A heal does not undo a relocation: the ledger and inbox stay on the run dir's
# tmpfs until someone runs `exit`, and a later restart drops them. The heal is
# the one moment the watcher knows the tree is back, so it says so: to the
# orchestrator directly, and in the workers' RESUME.
# shellcheck source=../_ledger_path.sh
. "$MON/_ledger_path.sh"
_n12_cycle() {   # one onset + one heal through the real tick
    chmod 0555 "$RO_STATE"; _reset; : > "$LOG"; : > "$WORK/bc.log"
    STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator MONITOR_FS_BROADCAST_ONSET_CYCLES=1 \
        FS_NOTE_PASTE_FN=bc_paste FS_WORKER_LIST_FN=bc_workers \
        NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_guard_tick >/dev/null
    chmod 0755 "$RO_STATE"; : > "$WORK/bc.log"
    [[ "${1:-}" == pointer ]] && printf 'state_dir=%s\n' "$(cd "$RO_STATE" && pwd -P)" > "$n12_ptr"
    STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
        FS_NOTE_PASTE_FN=bc_paste FS_WORKER_LIST_FN=bc_workers _fs_guard_tick >/dev/null
}
n12_ptr=$(nexus_degraded_pointer_path "$RO_STATE"); mkdir -p "${n12_ptr%/*}"; rm -f "$n12_ptr"
_n12_cycle
assert_not_contains "N12 control: a heal with NO pointer says nothing about degraded exit" "$(cat "$WORK/bc.log")" "degraded exit"
_n12_cycle pointer
assert_contains "N12 pointer in force: the orchestrator is told the exit is owed" "$(grep '^orchestrator|' "$WORK/bc.log")" "Run monitor/ng degraded exit now"
assert_contains "N12 …and the workers' RESUME says so too" "$(grep '^w1|' "$WORK/bc.log")" "owes monitor/ng degraded exit"
assert_contains "N12 …and the watcher log records it" "$(cat "$LOG")" "relocation still in force"
rm -f "$n12_ptr"

echo '=== N13: a watcher that starts after a restart reports an unexited relocation as LOST (#1830 skeptic F1) ==='
# A restarted watcher begins with FS_DEGRADED=0, so it never sees a heal; the
# loss marker (outside the wiped run dir) is what it can see, once.
export CLAUDE_CONFIG_DIR="$WORK/ccd"
n13_mk=$(nexus_degraded_marker_path "$RO_STATE"); mkdir -p "${n13_mk%/*}"
chmod 0755 "$RO_STATE"; rm -f "$n12_ptr"
_n13_tick() {
    : > "$LOG"; : > "$WORK/bc.log"; FS_DEGRADED=0
    STATE_DIR="$RO_STATE" NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator \
        FS_NOTE_PASTE_FN=bc_paste FS_WORKER_LIST_FN=bc_workers _fs_guard_tick >/dev/null
}
rm -f "$n13_mk"; FS_LOSS_CHECKED=0; _n13_tick
assert_not_contains "N13 control: no marker → no LOST note" "$(cat "$WORK/bc.log")" "LOST"
printf 'state_dir=%s\nentered=1700000000\n' "$RO_STATE" > "$n13_mk"; FS_LOSS_CHECKED=0; _n13_tick
assert_contains "N13 marker, no pointer → the orchestrator is told LOST" "$(grep '^orchestrator|' "$WORK/bc.log")" "LOST: a degraded relocation"
_n13_tick
assert_not_contains "N13 …once per watcher process, not every cycle" "$(cat "$WORK/bc.log")" "LOST"
rm -f "$n13_mk"

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact): a
# dropped or added assertion is a FAIL, never a quieter green.
#   N1 2 | N2 11 | N3 fixture 1 + 3 drafts x 3 + N3c 2 | N4 3 | N5 8 | N6 8 | N7 2 | N8 10 | N9 6 | N10 5 | N11 7. The root path
#   exits at its th_skip before any assertion, so it never reaches this guard.
EXPECTED=$(( 2 + 11 + 12 + 3 + 8 + 8 + 2 + 10 + 6 + 5 + 7 + 4 + 3 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
