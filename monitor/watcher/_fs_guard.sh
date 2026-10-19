#!/usr/bin/env bash
# _fs_guard.sh — keep the watcher ALIVE and HONEST when the project
# filesystem goes read-only (your-org/nexus-code#473).
#
# Sourced by monitor/watcher/main.sh after _lib.sh. Side-effect-free:
# function definitions plus in-memory incident state, nothing else — so
# tests can source it, drive it against a 0555 fixture, and observe every
# transition without a real read-only mount.
#
# Depends (at CALL time, not source time) on:
#   _nexus_dir_writable, _nexus_critical_alarm, _nexus_rofs_alarm_text,
#   _nexus_github_incident_escalate, _nexus_fs_incident_record,
#   _nexus_fs_incident_close_comment   (all monitor/watcher/_lib.sh)
#   log, STATE_DIR, NEXUS_ROOT, TARGET (main.sh)
#   _idle_list_worker_windows (monitor/watcher/_idle_probe.sh; the worker
#   broadcast, your-org/nexus-code#1724 — skipped and logged when absent)
#
# THE POINT. On 2026-06-29 and again on 2026-07-09 the project tree went
# read-only and the watcher did not degrade — it vanished. Both incidents
# run the same script: `version_check` sees drifted sources, fires
# `launcher.sh --replace`, the launcher SIGTERMs the incumbent, and the
# successor dies in `>>"$LOGFILE"` — a FRESH open() — before `main.sh`
# executes one line. The incumbent it replaced was fine: it held its log
# fd from before the remount and had been logging normally throughout.
#
# So the guard has two halves, and both matter:
#   * do not die   — degrade, keep looping, keep something alive that can
#                    observe the condition and notice recovery;
#   * do not lie   — probe with a fresh open() every cycle, never through
#                    a held fd, which would report healthy mid-outage.

# Incident state, held IN MEMORY, deliberately. There is nowhere to write a
# rate-limit cursor during the incident — that is the whole condition — and
# the process dies with the incident anyway, so a file would buy nothing and
# cost a write we cannot make. FS_ESCALATED is what makes the alert fire
# exactly once: an alert that repeats every cycle is an alert that gets muted.
#
# `:=` so a test (or a re-source) may seed them without being clobbered.
: "${FS_DEGRADED:=0}"         # 1 while the project FS is not writable
: "${FS_ONSET:=0}"            # epoch of the first cycle whose probe FAILED
: "${FS_LAST_OK:=0}"          # epoch of the last cycle whose probe SUCCEEDED
: "${FS_ESCALATED:=0}"        # 1 once this incident has been escalated
: "${FS_CHANNELS:=}"          # escalation channels that actually delivered
: "${FS_DEGRADED_CYCLES:=0}"
# The repeating DEGRADED note (your-org/nexus-code#1724), in memory like the
# rest: the next epoch a note is due, the current gap, and how many went out.
: "${FS_NOTE_NEXT:=0}"
: "${FS_NOTE_GAP:=0}"
: "${FS_NOTE_COUNT:=0}"
# The worker broadcast's carry-over queue (skeptic F4 on #1799): pane names,
# newline-separated, still owed the current broadcast; see _fs_broadcast_drain.
# FS_BC_STOPPED = a STOP was broadcast this incident (so a heal owes RESUME).
: "${FS_BC_QUEUE:=}"
: "${FS_BC_KIND:=}"
: "${FS_BC_TEXT:=}"
: "${FS_BC_N:=0}"
: "${FS_BC_OK:=0}"
: "${FS_BC_STOPPED:=0}"
_FS_GUARD_MONITOR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)

# ---------------------------------------------------------------------------
# THE DEGRADED NOTE — the watcher keeps TALKING while it cannot operate
# (your-org/nexus-code#1724). The one-shot escalation below fires at onset;
# an 18 h incident then went silent for 18 h. Every degraded cycle now asks
# whether a short note is due, on a DOUBLING backoff (first after
# MONITOR_FS_DEGRADED_NOTE_BASE_SECONDS, default 300; capped at
# MONITOR_FS_DEGRADED_NOTE_MAX_SECONDS, default 3600), so it never stops while
# the condition holds and never floods (the #1713 lesson).
#
# WHERE IT GOES, and what it must never do. It is delivered through the SAME
# paste path as every emit (`paste_to_target`): the typed/undecidable-input
# refusal (an operator draft is never typed over), the overlay and dead-pane
# refusals, the Enter handling and the submit receipt all apply. That path's
# only writes (its per-target lock and the deferral counter) live under
# $STATE_DIR, which is the very directory that failed, so for this one call
# STATE_DIR points at a private run dir outside the tree. When the pane
# refuses, NOTHING is typed: the note survives in the watcher log (a held fd)
# and in the status file `ng degraded status` reads. There is no raw
# `send-keys` fallback, on purpose.
#
# The status file lives in the degraded run dir (mode 0700), resolved by
# monitor/_degraded-rundir.sh from the session-managed $TMPDIR, never a
# hardcoded path (operator, 2026-10-10, #1724): small state only, and the
# scratch tree is never the detached mount. A sandbox restart wiping it loses
# only a live status, never a record. NEXUS_DEGRADED_RUNDIR overrides.
# shellcheck source=../_degraded-rundir.sh
. "$_FS_GUARD_MONITOR_DIR/_degraded-rundir.sh"
_fs_rundir_path() {   # -> the run dir's path, or rc 1 (no managed place); creates nothing
    nexus_degraded_rundir
}
_fs_status_path() {   # <state_dir> -> its status file's path, or rc 1; creates nothing
    local d; d=$(_fs_rundir_path) || return 1
    printf '%s/%s.status' "$d" "$(printf '%s' "${1:?}" | tr -c 'A-Za-z0-9._-' '_')"
}
_fs_rundir() {   # -> the run dir (created 0700), or rc 1
    local d; d=$(_fs_rundir_path) || return 1
    ( umask 077; mkdir -p "$d" ) 2>/dev/null
    [[ -d "$d" && -w "$d" ]] || return 1
    printf '%s' "$d"
}
_fs_status_file() {   # <state_dir> -> path of its status file (run dir created)
    _fs_rundir >/dev/null || return 1
    _fs_status_path "$1"
}

# _fs_note_due <now> — 0 when a note is due now; advances the backoff.
_fs_note_due() {
    local now="${1:?now}" base="${MONITOR_FS_DEGRADED_NOTE_BASE_SECONDS:-300}" cap="${MONITOR_FS_DEGRADED_NOTE_MAX_SECONDS:-3600}"
    [[ "$base" =~ ^[0-9]+$ ]] && (( base > 0 )) || base=300
    [[ "$cap" =~ ^[0-9]+$ ]] && (( cap >= base )) || cap=$(( base > 3600 ? base : 3600 ))
    if (( FS_NOTE_NEXT == 0 )); then
        FS_NOTE_GAP=$base; FS_NOTE_NEXT=$(( FS_ONSET + base ))
    fi
    (( now >= FS_NOTE_NEXT )) || return 1
    FS_NOTE_GAP=$(( FS_NOTE_GAP * 2 )); (( FS_NOTE_GAP > cap )) && FS_NOTE_GAP=$cap
    FS_NOTE_NEXT=$(( now + FS_NOTE_GAP ))
    return 0
}

# _fs_probe_detail — "<VERDICT> <detail>" for $STATE_DIR from degraded-probe.sh
# (EROFS / ENOSPC / EACCES / HANG / …), bounded; "UNKNOWN probe unavailable"
# when the probe itself cannot run.
_fs_probe_detail() {
    local probe="$_FS_GUARD_MONITOR_DIR/degraded-probe.sh" row v d
    [[ -r "$probe" ]] || { printf 'UNKNOWN degraded-probe.sh unavailable'; return 0; }
    # CAPTURE, THEN MATCH: no early-exit reader on the producer's pipe (#682).
    local raw line
    raw=$(bash "$probe" --timeout "${MONITOR_FS_DEGRADED_PROBE_TIMEOUT:-3}" \
            --surface "state=$STATE_DIR" 2>/dev/null)
    row=""
    while IFS= read -r line; do
        [[ "$line" == "surface=state "* ]] && { row="$line"; break; }
    done <<<"$raw"
    v=$(sed -n 's/.* verdict=\([A-Z]*\).*/\1/p' <<<"$row")
    d=$(sed -n 's/.* detail=//p' <<<"$row")
    printf '%s %s' "${v:-UNKNOWN}" "${d:-no detail}"
}

# _fs_status_write <key=value>... — rewrite the status file (best-effort).
_fs_status_write() {
    local f; f=$(_fs_status_file "$STATE_DIR") || return 1
    { printf '%s\n' "$@"; printf 'updated=%s\n' "$(date +%s 2>/dev/null)"; } > "$f.tmp" 2>/dev/null \
        && mv -f "$f.tmp" "$f" 2>/dev/null
}

# _fs_note_deliver <text> — paste the note through paste_to_target with a
# private STATE_DIR. Prints the delivery word; never types anything itself.
_fs_note_deliver() {   # <text> [target, default $TARGET]
    local text="$1" target="${2:-${TARGET:-}}" fn="${FS_NOTE_PASTE_FN:-paste_to_target}" rd body rc=0
    declare -F "$fn" >/dev/null 2>&1 || { printf 'not-delivered (no paste path loaded)'; return 0; }
    [[ -n "$target" ]] || { printf 'not-delivered (no target)'; return 0; }
    rd=$(_fs_rundir) || { printf 'not-delivered (no writable run dir)'; return 0; }
    mkdir -p "$rd/paste-state" 2>/dev/null
    body="$rd/note.$$.${RANDOM}.md"
    { printf '%s\n' "$text"; printf -- '--- nexus-emit-sig %s %s ---\n' "$(date -Is)" "fsnote$$${RANDOM}"; } > "$body" 2>/dev/null \
        || { printf 'not-delivered (cannot stage the body)'; return 0; }
    STATE_DIR="$rd/paste-state" "$fn" "$target" "$body" no-liveness-stamp; rc=$?
    rm -f "$body" 2>/dev/null
    case "$rc" in
        0) printf 'delivered' ;;
        7) printf 'refused (input box holds typed or undecidable text, or an overlay is up; nothing typed)' ;;
        6) printf 'not-submitted (left for the operator; not re-pasted)' ;;
        2) printf 'not-delivered (target window absent)' ;;
        5) printf 'not-delivered (target is a dead pane)' ;;
        4) printf 'unconfirmed (pasted and Enter sent; no receipt; not re-pasted)' ;;
        *) printf 'not-delivered (paste rc %s; retried at the next note)' "$rc" ;;
    esac
}

# _fs_degraded_note_tick <now> — called once per degraded cycle.
_fs_degraded_note_tick() {
    local now="${1:-$(date +%s)}" dur pd verdict detail text delivery
    dur=$(( now - FS_ONSET )); (( dur < 0 )) && dur=0
    _fs_note_due "$now" || return 0
    FS_NOTE_COUNT=$(( FS_NOTE_COUNT + 1 ))
    pd=$(_fs_probe_detail); verdict="${pd%% *}"; detail="${pd#* }"
    text="[nexus watcher] DEGRADED for ${dur}s: cannot write ${STATE_DIR} (${verdict}: ${detail}). The loop is alive; the scheduler is suspended. Next note in ${FS_NOTE_GAP}s. Details: monitor/ng degraded status"
    delivery=$(_fs_note_deliver "$text")
    log "fs-guard: DEGRADED note #${FS_NOTE_COUNT} (${verdict}) — ${delivery}"
    _fs_status_write mode=degraded "state_dir=$STATE_DIR" "onset=$FS_ONSET" \
        "verdict=$verdict" "detail=$detail" "notes=$FS_NOTE_COUNT" "last_note=$now" \
        "next_note=$FS_NOTE_NEXT" "delivery=$delivery" || true
}

# _fs_broadcast_workers <stop|resume> <seconds> — tell every live WORKER
# pane, once per transition, that the tree went read-only (stop and wait) or
# healed (resume). your-org/nexus-code#1724, operator 2026-10-09: "The workers
# may be informed to stop and wait for restart before commencing their work,
# so they don't all have to find out the hard way." Before this, each worker
# discovered the outage by its own failing write, and `ng send` could not
# broadcast for the orchestrator (its ledger is on the same tree).
#
# Same delivery path as the DEGRADED note (_fs_note_deliver: the draft,
# overlay and dead-pane refusals all apply, writes go to the private run dir),
# so a worker with an operator draft in its box gets NOTHING typed. These
# pastes carry no ledger stamp (the ledger is what failed), so a worker's
# submit of one can read as operator input until the tree heals. Set
# MONITOR_FS_DEGRADED_BROADCAST=0 to turn the broadcast off.
#
# RESUME IS NOT GUARANTEED, and the STOP text says so (skeptic F2 on
# your-org/nexus-code#1799): all 18 RO onsets in this nexus's watcher.log
# (2026-09-28..10-10) ended in a sandbox restart, never an in-process heal,
# and a restarted watcher starts with FS_DEGRADED=0 and a wiped run dir. So a
# session resumed after a restart must read that as RESUME.
# _fs_relocation_in_force -> the pointer path, rc 0, when `ng degraded enter`
# (#1724) is still in force for $STATE_DIR; rc 1 otherwise (or no resolver).
# A heal does NOT undo a relocation: the ledger and inbox stay in the run dir,
# a tmpfs a sandbox restart wipes, until someone runs `ng degraded exit`, and
# nothing else prompts that (skeptic on #1830). So the heal says it.
_fs_relocation_in_force() {
    declare -F nexus_degraded_pointer_path >/dev/null 2>&1 || return 1
    local p
    p=$(nexus_degraded_pointer_path "$STATE_DIR" 2>/dev/null) || return 1
    [[ -n "$p" && -f "$p" ]] || return 1
    printf '%s' "$p"
}
FS_RELOC_PTR=""

# _fs_relocation_lost_check — ONCE per watcher process, on a writable cycle: a
# loss marker with no pointer means `ng degraded enter` was never exited and a
# sandbox restart wiped the run dir (skeptic F1 on #1830). A restarted watcher
# starts with FS_DEGRADED=0 and never sees a heal, so the heal path cannot
# report this; its first writable cycle can. Read through
# nexus_degraded_lost_records (the one reader), which also returns the losses
# a later `enter` appended to the lost record: those are reported even while
# a NEW relocation is in force (the #1724 residual).
FS_LOSS_CHECKED=0
_fs_relocation_lost_check() {
    (( FS_LOSS_CHECKED )) && return 0
    FS_LOSS_CHECKED=1
    declare -F nexus_degraded_lost_records >/dev/null 2>&1 || return 0
    local recs n p first now=""
    recs=$(nexus_degraded_lost_records "$STATE_DIR" 2>/dev/null) || return 0
    n=$(grep -c . <<<"$recs")
    (( n > 0 )) || return 0
    p=$(nexus_degraded_pointer_path "$STATE_DIR" 2>/dev/null) || p=""
    [[ -n "$p" && -f "$p" ]] && now=" A newer relocation is in force now: run monitor/ng degraded exit to bring it home first; the loss is listed again after."
    if (( n == 1 )); then
        first="a degraded relocation (ng degraded enter) was never exited, and the run dir that held it was wiped"
    else
        first="${n} degraded relocations (ng degraded enter) were never exited, and the run dirs that held them were wiped"
    fi
    log "fs-guard: LOST — ${n} degraded relocation(s) never exited, run dir gone (marker/lost record under ${CLAUDE_CONFIG_DIR:-?}/nexus-degraded); their staged ledger rows and requests did not reach the tree"
    _fs_note_deliver "[nexus watcher] LOST: ${first}, almost certainly by a sandbox restart. Ledger rows and requests written while in force are gone. Run monitor/ng degraded exit for what and since when, then --ack-loss.${now}" \
        || log "fs-guard: WARN the LOST note did not reach ${TARGET:-the orchestrator}"
}

_fs_broadcast_workers() {
    local kind="$1" secs="${2:-0}" text name _a _i
    [[ "${MONITOR_FS_DEGRADED_BROADCAST:-1}" == 0 ]] && return 0
    declare -F "${FS_WORKER_LIST_FN:-_idle_list_worker_windows}" >/dev/null 2>&1 || {
        log "fs-guard: worker broadcast ($kind) skipped — no worker lister loaded"; return 0; }
    if [[ "$kind" == stop ]]; then
        text="[nexus watcher] The project tree is READ-ONLY (cannot write ${STATE_DIR}). Writes, commits, pushes, ng send, ng longjob and test runs in the tree will fail until the sandbox is restarted from outside. STOP starting new work that writes there: record your resume point in your context, do not retry failing writes in a loop, and WAIT. Continue when EITHER a RESUME note arrives OR your session is resumed after a sandbox restart (the usual end of an outage: a restarted watcher cannot send RESUME). Reach the orchestrator with SendMessage. Details: monitor/ng degraded status"
    else
        text="[nexus watcher] RESUME: the project tree is writable again after ${secs}s read-only. Re-run any write that failed during the outage (reports, commits, ledger rows), check that files you staged elsewhere are copied back, then continue your task."
        [[ -n "$FS_RELOC_PTR" ]] && text="$text A degraded relocation (ng degraded enter) is still in force, so the ledger and inbox are still written outside the tree; the orchestrator owes monitor/ng degraded exit."
    fi
    # A transition supersedes whatever the previous one left queued: a STOP
    # still owed when the tree heals is moot (they all get RESUME), and vice
    # versa. Said out loud, so a short tally is never mistaken for refusals.
    if [[ -n "$FS_BC_QUEUE" ]]; then
        log "fs-guard: worker broadcast (${FS_BC_KIND}) superseded by ($kind) — $(printf '%s\n' "$FS_BC_QUEUE" | grep -c .) undelivered pane(s) dropped"
    fi
    FS_BC_QUEUE=""
    while IFS=$'\t' read -r name _a _i; do
        [[ -n "$name" ]] || continue
        FS_BC_QUEUE+="$name"$'\n'
    done < <("${FS_WORKER_LIST_FN:-_idle_list_worker_windows}" 2>/dev/null)
    FS_BC_KIND="$kind"; FS_BC_TEXT="$text"; FS_BC_N=0; FS_BC_OK=0
    _fs_broadcast_drain
    return 0
}

# _fs_broadcast_drain — deliver the queued broadcast for at most
# MONITOR_FS_BROADCAST_BUDGET_SECONDS (default 30) of this tick, at least one
# pane per call, and CARRY the rest to the next tick (skeptic F4 on
# your-org/nexus-code#1799). Each pane is one full paste_to_target — lock,
# paste, submit confirmation, Enter — measured at ~3.0 s per pane through the
# real chain on a throwaway tmux server (plain panes, no session id); the
# primitive's documented worst case is ~9 s plus a 3 s render re-look, under
# a 20 s lock wait. Serial and unbounded, a 20-pane board stalled the tick
# for a minute or more, and at HEAL that stall is the scheduler's first tick.
# Kept in-process rather than in a background child on purpose: the queue is
# what keeps STOP and RESUME to one pane in order, and what lets a heal drop
# the STOPs not yet sent. Called from _fs_guard_tick every cycle; a no-op
# when nothing is queued.
_fs_broadcast_drain() {
    [[ -n "$FS_BC_QUEUE" ]] || return 0
    local budget="${MONITOR_FS_BROADCAST_BUDGET_SECONDS:-30}" t0=$SECONDS name d left
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=30
    while [[ -n "$FS_BC_QUEUE" ]]; do
        name="${FS_BC_QUEUE%%$'\n'*}"; FS_BC_QUEUE="${FS_BC_QUEUE#*$'\n'}"
        [[ -n "$name" ]] || continue
        FS_BC_N=$(( FS_BC_N + 1 ))
        d=$(_fs_note_deliver "$FS_BC_TEXT" "$name")
        [[ "$d" == delivered ]] && FS_BC_OK=$(( FS_BC_OK + 1 ))
        log "fs-guard: worker broadcast (${FS_BC_KIND}) to ${name} — ${d}"
        if [[ -n "$FS_BC_QUEUE" ]] && (( SECONDS - t0 >= budget )); then
            left=$(printf '%s' "$FS_BC_QUEUE" | grep -c .)
            log "fs-guard: worker broadcast (${FS_BC_KIND}): ${budget}s tick budget spent after ${FS_BC_N} pane(s); ${left} carried to the next tick"
            return 0
        fi
    done
    log "fs-guard: worker broadcast (${FS_BC_KIND}): ${FS_BC_OK} of ${FS_BC_N} worker pane(s) delivered"
    FS_BC_KIND=""; FS_BC_TEXT=""
    return 0
}

# ---------------------------------------------------------------------------
# THE PAGE — Pushover → ntfy → SMTP via monitor/notify.sh (RO7, 2026-10-12).
# A 4 h 45 m read-only incident (03:42–08:28) escalated via
# [sandbox-notify,github-issue,tmux-display] and NEVER PAGED the operator: no
# leg of this escalation called notify.sh, the one channel that reaches a phone
# at 03:42. notify.sh itself needs nothing writable in the tree (measured: rc 0
# and the push delivered from a chmod a-w copy), so the page is DELIVERED FIRST
# and the only state it keeps — a rate stamp — is written AFTER, outside the
# tree (the degraded run dir), and best-effort: no state write can suppress it.
#
# THE BOUND. The fire-once latch resets on every recovery, so a tree that
# flaps RO/RW would page per flap. A page is therefore suppressed while the
# LAST page is younger than MONITOR_FS_PUSH_MIN_INTERVAL_SECONDS (default 1800,
# chosen: RO8 recurred 4 h 52 m after RO7's onset and must page; a flap every
# few seconds pages at most twice an hour). "Last" is the MAX of this process's
# memory and the stamp, so an unwritable run dir still bounds the one process
# that escalates; a stamp that cannot be READ never suppresses (send is the
# safe direction). Emergency priority, so the email leg fires too.
# Knobs: MONITOR_OPERATOR_ALERT_PUSH_ENABLED (the operator's one push switch),
# NEXUS_FS_PUSH_CMD (default $NEXUS_ROOT/monitor/notify.sh; tests stub it),
# MONITOR_FS_PUSH_TIMEOUT_SECONDS (default 45). NEXUS_NOTIFY_QUIET=1 skips it.
: "${FS_PUSH_LAST:=0}"
_fs_push_stamp_path() {
    local d; d=$(_fs_rundir_path) || return 1
    printf '%s/%s.push' "$d" "$(printf '%s' "${STATE_DIR:-.}" | tr -c 'A-Za-z0-9._-' '_')"
}
# _fs_push_page <text> — rc 0 iff a notify.sh backend accepted the page. Sets
# FS_PUSH_VERDICT (delivered|throttled|skipped:<why>|failed:rc=<n>) rather than
# printing it: a command-substitution caller would run it in a SUBSHELL and lose FS_PUSH_LAST.
_fs_push_page() {
    local text="$1" cmd tmo iv now last st sf rc
    cmd="${NEXUS_FS_PUSH_CMD:-${NEXUS_ROOT:-}/monitor/notify.sh}"
    case "${MONITOR_OPERATOR_ALERT_PUSH_ENABLED:-true}" in
        false|0|no|off|FALSE|NO|OFF) FS_PUSH_VERDICT='skipped:disabled'; return 1 ;;
    esac
    [[ "${NEXUS_NOTIFY_QUIET:-0}" == 1 ]] && { FS_PUSH_VERDICT='skipped:NEXUS_NOTIFY_QUIET'; return 1; }
    [[ -x "$cmd" ]] || { FS_PUSH_VERDICT='skipped:no-notify-cmd'; return 1; }
    command -v timeout >/dev/null 2>&1 || { FS_PUSH_VERDICT='skipped:no-timeout-on-PATH'; return 1; }
    iv="${MONITOR_FS_PUSH_MIN_INTERVAL_SECONDS:-1800}"; [[ "$iv" =~ ^[0-9]+$ ]] || iv=1800
    tmo="${MONITOR_FS_PUSH_TIMEOUT_SECONDS:-45}";      [[ "$tmo" =~ ^[0-9]+$ ]] && (( tmo > 0 )) || tmo=45
    now=$(date +%s 2>/dev/null || echo 0)
    last=$FS_PUSH_LAST; [[ "$last" =~ ^[0-9]+$ ]] || last=0
    sf=$(_fs_push_stamp_path 2>/dev/null) || sf=''
    st=''; [[ -n "$sf" ]] && { IFS= read -r st < "$sf"; } 2>/dev/null
    [[ "$st" =~ ^[0-9]+$ ]] && (( st > last )) && last=$st
    if (( last > 0 && now >= last && now - last < iv )); then
        FS_PUSH_VERDICT='throttled'; return 1
    fi
    # DELIVERY FIRST. No --email-status-file: that is a write, and the only
    # place a caller usually points it is the tree that just died.
    timeout "$tmo" "$cmd" "nexus: project FS READ-ONLY — restart the sandbox" "$text" \
        --priority emergency --require-delivery --quiet >/dev/null 2>&1
    rc=$?
    (( rc == 0 )) || { FS_PUSH_VERDICT="failed:rc=$rc"; return 1; }
    # State AFTER delivery, best-effort, never in the tree.
    FS_PUSH_LAST=$now
    if [[ -n "$sf" ]] && _fs_rundir >/dev/null 2>&1; then
        { printf '%s\n' "$now" > "$sf"; } 2>/dev/null || true
    fi
    FS_PUSH_VERDICT=delivered
    return 0
}

# Escalate the read-only condition exactly ONCE per incident, over channels
# that survive a read-only project FS, in preference order:
#   1. sandbox-notify  — pure PATH resolution + exec; no temp file, no cache
#   1b. a push PAGE    — monitor/notify.sh (Pushover/ntfy/email); see above
#   2. a GitHub issue  — mint-token.sh caches under $HOME/.claude, a
#                        DIFFERENT mount; a warm cache serves read-only
#   3. a tmux paste    — last resort, only if 1, 1b and 2 all failed
_fs_escalate_once() {
    (( FS_ESCALATED )) && return 0
    FS_ESCALATED=1
    local chans='' oob='' text
    text=$(_nexus_rofs_alarm_text "$STATE_DIR" "watcher main.sh")

    # `_nexus_critical_alarm` returns 0 whenever it RANG, but stderr is its
    # floor — it "rings" even on a host with no `sandbox-notify` binary, where
    # stderr goes to a log on the filesystem that just died. So track the
    # channels that actually reached a HUMAN OUT-OF-BAND (`oob`) separately
    # from what we report (`chans`). Only an empty `oob` justifies interrupting
    # the orchestrator's pane. Crediting stderr as delivery would leave a
    # notify-less host silently unescalated.
    if _nexus_critical_alarm "watcher-rofs" \
        "${MONITOR_ROFS_ALARM_THROTTLE_SECONDS:-120}" "$text"; then
        if command -v sandbox-notify >/dev/null 2>&1; then
            chans='sandbox-notify'; oob='sandbox-notify'
        else
            chans='stderr'   # logged, NOT delivered — deliberately not `oob`
        fi
    fi

    # The PAGE (RO7): the only leg that reaches a phone. Before GitHub, whose
    # mint + list + create can take far longer than a push.
    FS_PUSH_VERDICT=''
    if _fs_push_page "$text"; then
        chans="${chans:+$chans,}push"; oob="${oob:+$oob,}push"
    fi
    log "fs-guard: push page — ${FS_PUSH_VERDICT:-unknown}"

    if _nexus_github_incident_escalate "$NEXUS_ROOT" "$STATE_DIR" \
        "watcher main.sh (degraded)" \
        "watcher ALIVE in read-only degraded mode; no project-tree writes possible"; then
        chans="${chans:+$chans,}github-issue"
        oob="${oob:+$oob,}github-issue"
    fi

    # A status-line notice costs nothing and writes nothing. It is visible
    # only to someone already looking at the terminal, so it is not `oob`.
    if command -v tmux >/dev/null 2>&1; then
        tmux display-message "nexus: project FS READ-ONLY — restart the sandbox" \
            >/dev/null 2>&1 && chans="${chans:+$chans,}tmux-display"
    fi

    # Only if EVERY out-of-band channel failed do we interrupt the
    # orchestrator's pane — and through the SAME paste path as every emit,
    # with its writes redirected off the read-only tree (_fs_note_deliver,
    # your-org/nexus-code#1724). This used to be a raw `send-keys -l` + Enter,
    # which typed over an operator draft and submitted it. A refusal now types
    # nothing; the log line and `ng degraded status` carry the text.
    if [[ -z "$oob" ]]; then
        local _d; _d=$(_fs_note_deliver "$text")
        [[ "$_d" == delivered ]] && chans="${chans:+$chans,}tmux-paste"
        log "fs-guard: last-resort pane notice — ${_d}"
    fi

    FS_CHANNELS="${chans:-none}"
    log "fs-guard: escalated once via [${FS_CHANNELS}]"
    return 0
}

# One probe per cycle. Returns 0 when the project FS is writable, 1 when it
# is not (the caller must then skip every project-tree write).
#
# The probe is a FRESH create+unlink (monitor/_fs_probe.sh). It must never
# become an append to a held fd: this very process holds `watcher.log` open,
# and that fd keeps working after the mount is detached — a probe through it
# would report HEALTHY during a total outage. That is the exact failure mode
# this guard exists to prevent.
_fs_guard_tick() {
    local now dur _bc_now=0 _bc_onset
    now=$(date +%s 2>/dev/null || echo 0)

    if _nexus_dir_writable "$STATE_DIR"; then
        if (( FS_DEGRADED )); then
            dur=$(( now - FS_ONSET )); (( dur < 0 )) && dur=0
            log "fs-guard: project FS is WRITABLE again after ${dur}s (${FS_DEGRADED_CYCLES} degraded cycles) — resuming normal operation"
            # Durable trace: the 2026-06-29 incident left no record and was
            # re-diagnosed from scratch ten days later.
            if _nexus_fs_incident_record "$STATE_DIR" "$FS_ONSET" "$FS_LAST_OK" \
                "$now" "$FS_CHANNELS" "watcher main.sh"; then
                log "fs-guard: incident recorded in $STATE_DIR/fs-incidents.jsonl"
            else
                log "fs-guard: WARN could not append the incident trace to $STATE_DIR/fs-incidents.jsonl"
            fi
            if _nexus_fs_incident_close_comment "$NEXUS_ROOT" "$dur" \
                "$FS_CHANNELS" "watcher main.sh"; then
                log "fs-guard: posted the recovery comment on the open incident issue"
            else
                log "fs-guard: recovery comment not posted (best-effort; the local trace stands)"
            fi
            _fs_status_write mode=ok "state_dir=$STATE_DIR" "recovered=$now" \
                "last_incident_seconds=$dur" "notes=$FS_NOTE_COUNT" || true
            if FS_RELOC_PTR=$(_fs_relocation_in_force); then
                log "fs-guard: healed with a degraded relocation still in force ($FS_RELOC_PTR) — \`ng degraded exit\` is owed"
                _fs_note_deliver "[nexus watcher] The project tree is writable again, but a degraded RELOCATION is still in force (pointer $FS_RELOC_PTR). The delivery ledger and/or request inbox are still being written to the degraded run dir, a tmpfs that a sandbox restart wipes. Run monitor/ng degraded exit now to merge them home." \
                    || log "fs-guard: WARN the relocation-owed note did not reach ${TARGET:-the orchestrator}"
            else
                FS_RELOC_PTR=""
            fi
            if (( FS_BC_STOPPED )); then
                _fs_broadcast_workers resume "$dur"; _bc_now=1
            else
                log "fs-guard: read-only for ${FS_DEGRADED_CYCLES} cycle(s) only — no STOP was broadcast, so no RESUME is owed"
            fi
            FS_BC_STOPPED=0; FS_RELOC_PTR=""
            FS_DEGRADED=0; FS_ESCALATED=0; FS_CHANNELS=''
            FS_DEGRADED_CYCLES=0; FS_ONSET=0
            FS_NOTE_NEXT=0; FS_NOTE_GAP=0; FS_NOTE_COUNT=0
        fi
        (( _bc_now )) || _fs_broadcast_drain
        _fs_relocation_lost_check
        FS_LAST_OK=$now
        return 0
    fi

    if (( ! FS_DEGRADED )); then
        FS_DEGRADED=1
        FS_ONSET=$now
        FS_DEGRADED_CYCLES=0
        FS_NOTE_NEXT=0; FS_NOTE_GAP=0; FS_NOTE_COUNT=0
        log "fs-guard: CRITICAL — the project FS is READ-ONLY (cannot write $STATE_DIR)."
        log "fs-guard: entering read-only DEGRADED mode. The loop stays alive; all project-tree writes are suspended."
        log "fs-guard: this cannot be repaired from inside the sandbox — it needs a restart from OUTSIDE. Never remount, bind, or unshare around it."
        _fs_escalate_once
        FS_BC_STOPPED=0
    fi
    FS_DEGRADED_CYCLES=$(( FS_DEGRADED_CYCLES + 1 ))
    # ONSET HYSTERESIS for the board-wide STOP (skeptic note on #1799): the
    # escalation above fires on the FIRST failed probe, but a paste into every
    # worker pane waits for MONITOR_FS_BROADCAST_ONSET_CYCLES consecutive
    # failed probes (default 2), so a one-probe transient pastes nobody. The
    # cost is one degraded poll (MONITOR_FS_DEGRADED_POLL_SECONDS, default
    # 15 s) of delay on a STOP for an incident that has, in every one of the
    # 18 recorded here, lasted until a sandbox restart.
    _bc_onset="${MONITOR_FS_BROADCAST_ONSET_CYCLES:-2}"
    [[ "$_bc_onset" =~ ^[0-9]+$ ]] && (( _bc_onset >= 1 )) || _bc_onset=2
    if (( ! FS_BC_STOPPED && FS_DEGRADED_CYCLES >= _bc_onset )); then
        FS_BC_STOPPED=1
        _fs_broadcast_workers stop 0; _bc_now=1
    fi
    (( _bc_now )) || _fs_broadcast_drain
    if (( FS_DEGRADED_CYCLES == 1 )); then
        _fs_status_write mode=degraded "state_dir=$STATE_DIR" "onset=$FS_ONSET" \
            "notes=0" "next_note=$(( FS_ONSET + ${MONITOR_FS_DEGRADED_NOTE_BASE_SECONDS:-300} ))" \
            "delivery=escalated once via [${FS_CHANNELS:-none}]" || true
    fi
    _fs_degraded_note_tick "$now"
    return 1
}

