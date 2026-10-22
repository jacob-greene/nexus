# shellcheck shell=bash
# monitor/longjob-probes.d/slurm.sh — longjob-watch subject probe: a Slurm job.
#
# THE PROBE CONTRACT (every file in this directory implements it, and adding
# a subject kind means adding ONE file here — the dispatcher never learns the
# kind's name):
#
#   lj_probe_main <target> <spec-json>      → prints  "<state>|<detail>"
#     state ∈ pending | running | done | failed | unknown
#
#   `unknown` is the FIFTH answer and it is not `running`. It means "I could
#   not tell", and the dispatcher's policy for it is a bounded retry and then
#   an EMIT (your-org/nexus-code#1535) — never silence. A probe that cannot
#   answer must say so rather than guess in either direction.
#
# Subject target: a Slurm job id (`123`, `123_4`, `123+1`) — the shape is
# `lj_slurm_jobid_valid` below, and `0` is not one.
#
# STATE VOCABULARY — read from `man sacct` "JOB STATE CODES" on slurm 25.11.5
# (2026-09-15), NOT from memory. `sacct --helpstates` is not whitelisted by the
# sandbox chaperon, so the man page is the enumerable source here:
#   BOOT_FAIL CANCELLED COMPLETED DEADLINE FAILED NODE_FAIL OUT_OF_MEMORY PENDING
#   PREEMPTED RUNNING REQUEUED RESIZING REVOKED SUSPENDED TIMEOUT
# plus the transient states `squeue` and older `sacct` builds surface and this
# workspace's orphan-async resolver already maps: COMPLETING CONFIGURING
# SIGNALING STAGE_OUT RESV_DEL_HOLD SPECIAL_EXIT.
#
# THE DEFAULT ARM IS `failed`, NEVER `running`. A state this file has not
# heard of is EMITTED (as a terminal, so the agent reads it) rather than
# assumed transient — the failure direction of "assume still running" is a
# worker asleep forever, and the cost of the other direction is one wake.
# Slurm appends a reason to some states (`CANCELLED by 1234`), so the match is
# on the leading word.
#
# A job that NEVER APPEARS: `sacct` returns nothing for a job id that was never
# accepted (a failed submission whose id the caller nevertheless recorded), and
# ALSO for a few seconds after a real submission (accounting lag). Both read as
# `unknown|no accounting row`; the dispatcher's bounded unknown-retry turns the
# first into an UNKNOWN emit after `unknown_max` polls and lets the second
# resolve on its own. `squeue` is consulted as a second source before saying
# unknown, because a queued job is visible there before accounting has it.

# AN ARRAY (or het job) IS A SET, NOT A ROW (your-org/nexus-code#1629). For an
# array id `sacct -X` prints ONE ROW PER TASK (plus a collapsed row for tasks
# still pending); this probe used to keep the FIRST line only, so the first
# task's COMPLETED emitted DONE while its siblings ran, and after two of them
# had FAILED. Every row is classified now: any pending/running row -> the set is
# not terminal; all terminal and ANY failed (or unrecognised) -> failed; all
# COMPLETED -> done. A single-row job prints exactly what it printed before.
# Classified inline (no `$(…)` per row): an array can have thousands of tasks.

# THE ONE JOB-ID SHAPE (your-org/nexus-code#1727). `lj_slurm_jobid_valid` is
# the single predicate behind all three places a Slurm id is accepted: this
# probe, `longjob-watch.sh add slurm:<id>`, and the auto-arm loop in
# `monitor/hooks/async-launch-detect.sh` (both SOURCE this file for it, so the
# three cannot drift apart). It used to be three copies of `^[0-9][0-9_.+]*$`,
# which accepts `0`: a `jid=$(sbatch --parsable …); echo $?` call printed `0`,
# the hook armed `auto-slurm-0`, and `sacct -j 0` answered with UNRELATED jobs,
# so the watch never reached a verdict about the job that was submitted — a
# ~9.5 h stall, measured. Slurm never assigns job id 0, and no real id has a
# leading zero.
#
# Accepted: a POSITIVE integer with no leading zero, optionally ONE array
# (`_N`) or het (`+N`) component, optionally ONE numeric step (`.N`) —
# `123456`, `123456_3`, `123456+0`, `123456.0`. The component numbers
# may be 0 (array tasks and het components start at 0). Every accepted string
# was also accepted by the old pattern: this only narrows.
LJ_SLURM_JOBID_ERE='^[1-9][0-9]*([_+][0-9]+)?([.][0-9]+)?$'
lj_slurm_jobid_valid() { [[ "${1:-}" =~ $LJ_SLURM_JOBID_ERE ]]; }

# lj_slurm_squeue_state <id> — the queue state of <id> from `squeue -u`,
# empty when the job is not listed (or squeue failed). `-u` and never `-j`:
# see the call site (your-org/nexus-code#1744). LJ_SQUEUE_USER is a test seam.
lj_slurm_squeue_state() {
    local target="$1" user="${LJ_SQUEUE_USER:-${USER:-$(id -un 2>/dev/null)}}"
    [[ -n "$user" ]] || return 0
    squeue -u "$user" -h -o '%i %T' 2>/dev/null | awk -v t="$target" '
        $1 == t || index($1, t "_") == 1 || index($1, t "+") == 1 { print $2; exit }'
}

# --time IS NOT A BOUND HERE (your-org/nexus-code#1841). `scontrol show
# config` reported `OverTimeLimit = 2160 min` (2026-10-15): Slurm lets a job
# run up to 36 h past its --time, and a `--time 06:00:00` job ran 13 h 52 m.
# So a RUNNING row whose ElapsedRaw (seconds) exceeds its TimelimitRaw
# (minutes) carries LJ_SLURM_OVERTIME_MARK in its detail; the dispatcher keys
# its ONE overtime warning per watch on that literal (longjob-watch.sh,
# `.overtime_warned`). A limit that is not an integer (UNLIMITED,
# Partition_Limit, blank, an old two-field row) is no limit: no mark.
LJ_SLURM_OVERTIME_MARK='PAST ITS --time'
_lj_hm() { printf '%dh%02dm' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )); }
# _lj_slurm_overtime <elapsed-seconds> <limit-minutes> → the clause, or nothing
_lj_slurm_overtime() {
    [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ ]] || return 0
    (( $1 > $2 * 60 )) || return 0
    printf '%s: elapsed %s > limit %s, and OverTimeLimit lets Slurm continue it (scontrol show config | grep OverTimeLimit)' \
        "$LJ_SLURM_OVERTIME_MARK" "$(_lj_hm "$1")" "$(_lj_hm $(( $2 * 60 )))"
}

# THE PAYLOAD'S OWN EXIT CODE OUTRANKS SLURM (your-org/nexus-code#1841). A node
# whose resolver failed (`getaddrinfo` for the controller) held jobs RUNNING or
# COMPLETING after their payload had exited, so a watch on Slurm state alone
# slept on a finished job. `add slurm:<id> --payload-rc <file>` records an
# absolute path in `.payload_rc`; the job script's last lines write the real
# step's rc there (`echo "$rc" > FILE; exit "$rc"`). When the file holds an
# integer the payload is over: RUNNING/COMPLETING (or no answer from Slurm)
# becomes done/failed by that rc, flagged `RUNNING after payload end`. A file
# that is not an integer 0..255 is REFUSED, never read as a number: `unknown`
# while Slurm says the job is live (so the bounded unknown retry rides out a
# torn write and then EMITS), and an `IGNORED` note beside a terminal Slurm
# verdict. A pending job keeps its pending (an rc before the job ran is stale).
lj_probe_main() {
    local target="$1" spec="${2:-}" verdict prc="" v="" st det
    verdict=$(_lj_slurm_verdict "$target")
    [[ -n "$spec" ]] && prc=$(printf '%s' "$spec" | jq -r '.payload_rc // empty' 2>/dev/null)
    if [[ -z "$prc" || ! -e "$prc" ]] || ! lj_slurm_jobid_valid "$target"; then
        printf '%s' "$verdict"; return 0
    fi
    st="${verdict%%|*}"; det="${verdict#*|}"
    { IFS= read -r v < "$prc"; } 2>/dev/null || true
    v="${v%$'\r'}"; v="${v%%[[:space:]]}"
    # An exit code is 0..255; a longer digit string would wrap in (( )).
    if [[ ! "$v" =~ ^[0-9]{1,3}$ ]] || (( 10#$v > 255 )); then
        case "$st" in
            done|failed) printf '%s|%s; payload-rc file %s IGNORED: holds '"'"'%s'"'"', not an exit code' "$st" "$det" "$prc" "${v:0:40}" ;;
            pending) printf '%s' "$verdict" ;;
            *) printf 'unknown|payload-rc file %s holds '"'"'%s'"'"', not an exit code (0..255) — refused; Slurm says: %s' "$prc" "${v:0:40}" "$det" ;;
        esac
        return 0
    fi
    local pst=done; (( 10#$v == 0 )) || pst=failed
    case "$st" in
        running|unknown)
            # The verdict leads: _probe cuts a detail at 400 chars, and a
            # deep path must not push it past the cut.
            printf '%s|payload rc=%s: RUNNING after payload end (Slurm still says %s) — the allocation is held; read the output, then scancel %s (rc from %s)' \
                "$pst" "$v" "${det%%;*}" "$target" "$prc" ;;
        done)
            if [[ "$pst" == failed ]]; then printf 'failed|payload rc=%s (from %s) although Slurm says %s' "$v" "$prc" "$det"
            else printf 'done|%s; payload rc=0' "$det"; fi ;;
        failed) printf 'failed|%s; payload rc=%s' "$det" "$v" ;;
        *) printf '%s' "$verdict" ;;
    esac
    return 0
}

_lj_slurm_verdict() {
    local target="$1"
    # Refused BEFORE `sacct` runs: `sacct -j 0` is not a question about any job.
    lj_slurm_jobid_valid "$target" || { printf 'unknown|not a Slurm job id: %s (never polled)' "$target"; return 0; }
    command -v sacct >/dev/null 2>&1 || { printf 'unknown|sacct not on PATH'; return 0; }
    local out rc state exit_code el="" tl="" ot="" ef err=""
    # stderr is KEPT (to a private file) so a chaperon failure can say so: the
    # dispatcher backs off on it (your-org/nexus-code#1728).
    ef=$(mktemp "${TMPDIR:-/tmp}/lj-sacct-err.XXXXXX" 2>/dev/null) || ef=""
    out=$(sacct -X -n -P -o State,ExitCode,ElapsedRaw,TimelimitRaw -j "$target" 2>"${ef:-/dev/null}"); rc=$?
    if [[ -n "$ef" ]]; then { IFS= read -r err < "$ef"; } 2>/dev/null; rm -f "$ef"; fi
    if (( rc != 0 )); then
        printf 'unknown|sacct rc=%s%s' "$rc" "${err:+: ${err:0:160}}"; return 0
    fi
    local rows="$out"
    out="${out%%$'\n'*}"
    if [[ -z "$out" ]]; then
        local sq
        if command -v squeue >/dev/null 2>&1; then
            # NEVER `squeue -j <id>` (your-org/nexus-code#1744): in this
            # sandbox it returns EMPTY at rc 0 for a job that IS queued on
            # ~25% of calls, in bursts, while the unfiltered `squeue -u` lists
            # the job on 40/40. Ask for OUR jobs and filter by id here. The id
            # matches exactly, or as the parent of an array task (`<id>_N`,
            # `<id>_[..]`) or a het component (`<id>+N`). An empty answer
            # still maps to `unknown` below, never to done.
            sq=$(lj_slurm_squeue_state "$target")
            if [[ -n "$sq" ]]; then
                case "${sq%% *}" in
                    PENDING|CONFIGURING|REQUEUED|RESV_DEL_HOLD) printf 'pending|squeue %s (not yet in accounting)' "$sq"; return 0 ;;
                    RUNNING|COMPLETING|SUSPENDED|SIGNALING|STAGE_OUT|RESIZING) printf 'running|squeue %s (not yet in accounting)' "$sq"; return 0 ;;
                    *) printf 'failed|squeue reports unrecognised state %s and sacct has no row' "$sq"; return 0 ;;
                esac
            fi
        fi
        printf 'unknown|no accounting row for job %s (submission failed, accounting lag, or not this cluster)' "$target"
        return 0
    fi
    if [[ "$rows" == *$'\n'* ]]; then
        local line c n=0 np=0 nr=0 nd=0 nf=0 first_bad=''
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            n=$((n + 1))
            IFS='|' read -r c exit_code el tl _ <<< "$line"
            case "${c%% *}" in
                PENDING|CONFIGURING|REQUEUED|RESV_DEL_HOLD) np=$((np + 1)) ;;
                RUNNING|COMPLETING|SUSPENDED|SIGNALING|STAGE_OUT|RESIZING)
                    nr=$((nr + 1))
                    [[ -n "$ot" ]] || ot=$(_lj_slurm_overtime "$el" "$tl") ;;
                COMPLETED) nd=$((nd + 1)) ;;
                *)  # the known failure states AND the unrecognised default arm
                    nf=$((nf + 1)); [[ -n "$first_bad" ]] || first_bad="$c exit=$exit_code" ;;
            esac
        done <<< "$rows"
        local tally="array/het set of $n rows: $nd completed, $nf failed, $nr running, $np pending"
        if (( nr > 0 )); then
            printf 'running|%s%s%s' "$tally" "${first_bad:+ (first failure so far: $first_bad)}" "${ot:+; a running row is $ot}"
        elif (( np > 0 )); then
            printf 'pending|%s%s' "$tally" "${first_bad:+ (first failure so far: $first_bad)}"
        elif (( nf > 0 )); then
            printf 'failed|%s; first failure: %s' "$tally" "$first_bad"
        else
            printf 'done|COMPLETED %s' "$tally"
        fi
        return 0
    fi
    IFS='|' read -r state exit_code el tl _ <<< "$out"
    case "${state%% *}" in
        PENDING|CONFIGURING|REQUEUED|RESV_DEL_HOLD)
            printf 'pending|%s' "$state" ;;
        RUNNING|COMPLETING|SUSPENDED|SIGNALING|STAGE_OUT|RESIZING)
            ot=$(_lj_slurm_overtime "$el" "$tl")
            printf 'running|%s%s' "$state" "${ot:+; $ot}" ;;
        COMPLETED)
            printf 'done|COMPLETED exit=%s' "$exit_code" ;;
        FAILED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|DEADLINE|PREEMPTED|CANCELLED|REVOKED|SPECIAL_EXIT)
            printf 'failed|%s exit=%s' "$state" "$exit_code" ;;
        *)
            printf 'failed|unrecognised Slurm state %s exit=%s (not in this probe'"'"'s table — treated as terminal so it is READ, not slept through)' "$state" "$exit_code" ;;
    esac
    return 0
}
