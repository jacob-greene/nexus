#!/usr/bin/env bash
# monitor/hooks/async-launch-detect.sh
#
# Claude Code PostToolUse hook for the `Bash` matcher. Inspects the
# command the worker just ran and the stdout it produced; when one
# of the patterns in `monitor/async-launch-patterns.conf` fires,
# adds a (kind, id, desc) entry to the per-window heartbeat's
# `external_waits` array. The watcher's `pane-state.sh` classifier
# uses that array to emit `idle-orphan-async` against workers that
# launched async work but installed no resume mechanism (issue
# #183).
#
# Dismissed-launch escape hatch: if `(kind, id)` is already in the
# worker's `dismissed_waits` (set via `monitor/declare-no-wait.sh`),
# the launch is treated as deliberately fire-and-forget — no
# external_waits entry, no orphan-async signal. This lets a worker
# legitimately submit "set it and forget it" jobs without the
# watcher noising the operator.
#
# Data-driven: `monitor/async-launch-patterns.conf` is the pattern
# source. Adding a new launch class is a data edit, not a code
# change. See the conf file for the row format.
#
# Atomic write: read the heartbeat → mutate `external_waits` →
# write to `<file>.$$.tmp` → rename. The PostToolUse heartbeat
# hook (`monitor/worker-heartbeat.sh`) preserves `external_waits`
# and `dismissed_waits` across its own writes, so the two hooks
# can fire in either order within the same PostToolUse cycle.
#
# Hot-path discipline: every failure path exits 0 silently. A
# wedged hook would block claude's turn — degraded silently is
# better than blocking. The classifier's pane-footer fallback
# still works even without this hook.
#
# Inputs / env:
#   $NEXUS_WORKER_WINDOW   tmux window name (exported by
#                          spawn-worker.sh).
#   $NEXUS_STATE_DIR       override (test escape hatch).
#   $NEXUS_ROOT            fallback root; also the source of
#                          async-launch-patterns.conf.
#   $NEXUS_ASYNC_PATTERNS  optional override for the conf path
#                          (test escape hatch).
#
# Stdin: PostToolUse payload JSON. We read `.tool_input.command`
# and `.tool_response.stdout`. Cap reads at 64 KiB each (claude's
# stdout can be large; we only need the launcher's success line).

set -u

# Guard rails — these don't fire stderr; missing env on a hook
# means we silently no-op. The hook is best-effort.
window="${NEXUS_WORKER_WINDOW:-}"
[[ -n "$window" ]] || exit 0

if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# Resolve pattern conf path. Prefer the env override; else fall
# back to NEXUS_ROOT or a script-relative location.
if [[ -n "${NEXUS_ASYNC_PATTERNS:-}" ]]; then
    pattern_file="$NEXUS_ASYNC_PATTERNS"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    pattern_file="$NEXUS_ROOT/monitor/async-launch-patterns.conf"
else
    self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || self_dir="."
    pattern_file="$self_dir/../async-launch-patterns.conf"
fi
[[ -f "$pattern_file" ]] || exit 0

# Cap stdin at 64 KiB. claude's payloads are small (<2 KiB
# typical) but Bash tool_response.stdout can be arbitrary.
payload=$(head -c 65536 2>/dev/null || true)
[[ -n "$payload" ]] || exit 0

# Confirm this is a PostToolUse on Bash. The hook is configured
# with matcher="Bash" in worker-settings.json but a misconfigured
# install might funnel other tool calls here — defensively skip.
tool_name=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || tool_name=""
# WHO LAUNCHED IT (your-org/nexus-code#1439). An in-process subagent fires this
# hook under the PARENT's NEXUS_WORKER_WINDOW, so its wait lands on the parent's
# heartbeat, where the parent's own transcript can never explain it — one such
# wait cost a search over 32 transcripts and 16,471 Bash calls. The payload
# carries the launching transcript (a subagent's is its own file) and, on
# harness builds that set them, an agent id; record them on the row so the
# owner can find the command instead of proving a negative.
launcher=$(printf '%s' "$payload" | jq -r '
    [ (.agent_id // .agent_type // empty),
      ((.transcript_path // empty) | tostring | split("/") | last | sub("\\.jsonl$"; "")) ]
    | map(select(length > 0)) | join("/")' 2>/dev/null) || launcher=""
launcher="${launcher:0:120}"
[[ "$tool_name" == "Bash" || "$tool_name" == "Monitor" ]] || exit 0

command_str=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || command_str=""
[[ -n "$command_str" ]] || exit 0

# Cap stdout at 16 KiB. The launcher's "Submitted batch job N"
# line is in the first few hundred bytes; we don't need the tail.
#
# DO NOT ENABLE THE PIPE-STATUS SHELL OPTION IN THIS FILE, and do not "fix"
# the `|| stdout_str=""` arm below by adding it (your-org/nexus-code#1056
# skeptic pass). The arm reads the PIPELINE's status, so today it is dead —
# and its deadness is load-bearing. `head -c` deliberately closes the pipe
# once it has its 16 KiB; past that plus the pipe buffer, `jq`'s next write
# gets SIGPIPE and PIPESTATUS becomes `0 141 0`.
#
# IT IS A RACE, NOT A THRESHOLD, and that is the part worth carrying: whether
# `jq` is still writing when `head` exits depends on scheduling. Measured on
# this host, 20 runs per size, BASH_ENV present:
#
#     payload  70 000 bytes ->  0/20 fire
#     payload  79 000 bytes -> 11/20 fire      <- NON-DETERMINISTIC
#     payload  82 000 bytes -> 20/20 fire
#     payload 200 000 bytes -> 20/20 fire
#
# Certainty arrives around 16384 + 65536 = 81920 (head's 16 KiB plus the 64 KiB
# default pipe buffer), so the boundary moves with F_GETPIPE_SZ. Do not quote a
# single cutoff: two earlier attempts did, one by bisecting — and bisection
# assumes monotonicity, which this does not have, so it can only return an
# artefact. With the option OFF, as here, the truncation succeeds and the
# first 16 KiB is kept — which is exactly what this line wants. Turn the
# option ON and that same successful, deliberate truncation becomes rc 141,
# the arm fires, and `stdout_str` is BLANKED. `stdout_str` gates the job-id
# extraction below (the `[[ -n "$stdout_str" ]]` guard and the read loop), so
# the hook would silently stop recording async launches for every
# large-output Bash call — the precise failure it exists to prevent.
#
# The option is named here by description only, never by its literal token:
# `early-exit-readers.sh`'s axis predicate greps whole files for that string
# with no comment stripping, so writing it would enrol this file onto the
# axis (your-org/nexus-code#1106).
stdout_str=$(printf '%s' "$payload" | jq -r '.tool_response.stdout // empty' 2>/dev/null | head -c 16384) || stdout_str=""
# stderr is read for ONE purpose (your-org/nexus-code#1832): a build that
# SEPARATES it and sent anything refuses the first-line rule at
# `_parsable_sbatch_spoke_first`. This harness merges stderr into stdout and
# leaves this empty.
stderr_str=$(printf '%s' "$payload" | jq -r '.tool_response.stderr // empty' 2>/dev/null | head -c 16384) || stderr_str=""

# ---- HEREDOC BODY MASKING (your-org/nexus-code#1312) --------------------
#
# THE DEFECT. Per-line matching (your-org/nexus-code#948) is what recovers a
# launch on line 2 of a multi-line command, and it is also what made a HEREDOC
# BODY a scanning surface. This workspace writes documentation, PR bodies and
# python programs with heredocs constantly, so a body line reading
# `srun --no-block ./job.sh` — prose ABOUT the detector, or a python source
# line — occupies "start of line" exactly as a launch does. Measured in the
# wild: a session that ran no Slurm job at all accumulated five `syn-…` waits
# and was woken by the orphan-async loop 308 s later.
#
# WHY THIS IS NOT "SKIP HEREDOCS". A heredoc body is not uniformly data:
# `bash <<EOF … sbatch job.sh … EOF` GENUINELY EXECUTES its body, and so do
# `sh`, `zsh` and `ssh host <<EOF`. A blanket skip would convert a live
# detection into a SILENT MISS, which is the expensive direction — a missed
# launch lets a worker treat submitted work as finished.
#
# THE RULE IS AN ALLOWLIST WITH A DEFAULT OF **DO NOT MASK**, so every shape
# nobody thought of keeps TODAY's behaviour rather than losing it. A body is
# blanked only when the simple command governing the redirection is a named
# DATA CONSUMER — a program that writes its heredoc somewhere or parses it,
# and does not hand it to a shell. Anything else, including any command this
# list has never heard of, is scanned exactly as before. The denial side is
# therefore not a list that can be incomplete; it is the default arm.
#
# FOUR FURTHER CONSERVATIVE ARMS, each failing toward the FALSE POSITIVE:
#   * a `|` AFTER the delimiter on the opening line refuses the mask, because
#     `cat <<EOF | bash` is a data consumer feeding a shell — measured, it
#     still fires. A `|` to the opener's LEFT cannot carry its output and does
#     not count (#1868), nor does one inside a COMPLETE `$(…)` or backtick pair
#     (#1863, `_hd_pipe_view`). A data consumer inside a BARE `( … )` subshell
#     is never masked: its output leaves through a `)` on a later line (#1868);
#   * a data consumer inside a `$(` is masked only when the `$(` is an
#     assignment's value or an argument of a named data consumer, and only when
#     the later line holding its closing `)` carries no pipe and does not end
#     in a backslash continuation (#1870 item 5, #1873 N1). At
#     command position, under `eval`, or under any unknown command, the value
#     may be run. What remains is DATAFLOW (`x=$(cat <<EOF …) && $x`), a gap;
#   * a `<<` that either the quote WALK or the quote-parity count reads as
#     being inside a string, or that sits inside `((…))` (a LEFT SHIFT, not a
#     heredoc — the trap `th_strip_heredocs` documents), is not treated as an
#     opener at all;
#   * an UNTERMINATED heredoc at the end of the command means the parse was
#     wrong, so the ENTIRE mask is discarded and the original command text is
#     scanned. Loud-and-conservative is unavailable in a hook that must never
#     block a turn; conservative alone is what is left.
#
# HOT PATH. The whole pass is skipped unless the command contains `<<` at all
# (one bash pattern test), and within a line it iterates over `<<`
# OCCURRENCES via parameter expansion, never over characters — so a 16 KB
# single-line command with no heredoc costs one comparison. No EXTERNAL
# process is spawned — one subshell fork for the command substitution, and
# that only on a command that contains `<<`; every existing cost in this hook
# is a `jq` exec. Measured against the unpatched hook over 20 fires per shape:
# no separation at a short command, a 16 KB single-line command, or a heredoc
# command. `th_strip_heredocs` in `monitor/watcher/_test_helpers.sh` is the
# in-tree precedent for the state machine; it is a TEST helper that takes a
# FILE and sources a companion awk, so it is reused as a design, not as code.
#
# RESIDUAL FALSE NEGATIVE, declared rather than hidden: a data consumer that
# re-executes its own body as shell — a python heredoc holding a shell script
# in a triple-quoted string it later passes to `subprocess` — is masked and
# missed. `cat` and `tee` cannot do this by construction. The ones that CAN are
# more of this list than first written (your-org/nexus-code#1312 skeptic F4):
# `python`/`python3`, `awk`/`gawk`/`mawk` (`system()`, `| "sh"`), `sed`
# (GNU `e`), and the DATABASE clients — `sqlite3` (`.system` / `.shell`, and it
# IS installed on this host), `psql` (`\!`) and `mysql` (`\!`) — every one of
# which has a documented shell escape and every one of which is on the
# allowlist above. It is admitted knowingly: the reachable shape requires the
# launch to sit at column 0 inside that inner string, and the alternative is
# the measured, recurring false-positive class above. Anyone tightening this
# should REMOVE members from the allowlist rather than add a parser — the
# default arm is DO NOT MASK, so a shorter list is strictly safer.
#
# Space-delimited so the membership test is a substring match on
# " $word ", which cannot partial-match (`bash` never matches `sbatch`).
_HD_DATA_CMDS=' cat tee python python2 python3 jq sed awk gawk mawk grep egrep fgrep sort head tail wc tr nl fold column diff patch cmp base64 md5sum sha1sum sha256sum mail mailx sendmail gh ng git psql sqlite3 mysql curl wget expand pr uniq cut paste '

# THE PIPE ARM READS A VIEW OF THE LINE, NOT THE LINE (your-org/nexus-code#1863).
# The `|` refusal exists for `cat <<EOF | bash`: a pipe that carries the heredoc
# consumer's OUTPUT into something that may run it.
#
# ONLY THE TEXT AFTER THE OPENER'S DELIMITER IS READ (your-org/nexus-code#1868
# item 2). A data consumer's output leaves to the RIGHT; a `|` to its left is
# either an earlier pipeline (`a | tail -1 && cat > f <<'EOF'`) or a pipe INTO
# the consumer, whose stdin the heredoc replaces. Neither can run the body, and
# a `|` between the command word and `<<` would have made a different command
# word govern the redirection (`seg` below starts after it). Reading the whole
# line refused the mask for the earlier pipeline and armed a `syn-` wait for a
# body that only quoted `sbatch`.
#
# A `|` inside a COMPLETE command substitution in that text is yet another
# pipeline (`cat >> "$(ls x | head -1)" <<EOF` keeps its group on the left, but
# `cat <<EOF $(ls x | head -1) > f` has it on the right). So the view also has
# every COMPLETE `$(…)` and backtick pair removed, innermost first, as long as
# the removed text holds no `<<`. A group that holds an opener is kept. An
# UNBALANCED group (one the line does not close) is never removed, so its pipes
# still count. QUOTED STRINGS ARE NOT REMOVED, so a `|` inside a quote still
# refuses, as before.
#
# A GROUP INSIDE SINGLE QUOTES IS LITERAL TEXT, and removal STOPS there so the
# pipe it straddles still refuses (`cat <<EOF '$(' | bash ')'`, ncbundle33-sk
# F2). Whether a group sits inside single quotes is decided by a QUOTE WALK
# (`_hd_qwalk`), not by counting quotes: a `'` inside a double-quoted string is
# not a quote, and the count read `cat <<EOF "'"'$(' | bash ')'` as unquoted,
# removed the group, removed the only pipe with it, and masked a body bash runs
# (#1868 item 1, the miss direction). The old parity test is KEPT beside the
# walk, and removal stops when EITHER says single-quoted, so this view can only
# be more conservative than the one it replaced. Removal also stops right after
# a backslash, and behind any `$(` or backtick still left to the group's left
# (the walk cannot see inside an unremoved substitution, so it does not try).
# Every arm of this view can only REMOVE a pipe that belongs to another
# pipeline; any doubt leaves the pipe in place, which refuses the mask, the
# false-positive direction. Bounded at 64 removals, and it sets a variable
# rather than printing, so it costs no fork.
#
# _hd_qwalk <text> <state> → sets _hd_qs to the quote state at the END of
# <text>, entered in <state>: 0 unquoted, 1 inside '…', 2 inside "…", 3 inside
# an ANSI-C $'…', 9 gave up.
# ANSI-C QUOTING IS ITS OWN STATE (your-org/nexus-code#1870 item 3). Inside
# `$'…'` a backslash escapes the next character, so `$'\''` is ONE string
# holding a quote. Read as a plain '…', its escaped quote closed the string
# early and the quote after it opened a new one, so the walk came out of
# `cat <<EOF $'\'' '$(' | bash ')'` UNQUOTED where the shell is inside '…'.
# The literal `$(' … ')` pair was then removed with the only pipe in it, and a
# body bash runs was masked (the miss direction). A `$` that is itself escaped
# never reaches this test (the backslash arm consumes it), and `$$'` is the
# PID followed by an ordinary quote, so only an ODD run of `$` opens one.
# It JUMPS between quote and backslash characters with pattern expansion rather
# than stepping characters, so its cost is the number of quotes, not the length
# of the line (the hot-path rule above). Bounded at 512 jumps; past that the
# state is 9, which every caller treats as quoted (the conservative reading).
# It does not model a `"…"` nested inside `"$(…)"`; its callers pair it with
# the parity test for that reason.
_hd_qwalk() {
    local s="$1" st="${2:-0}" c p d n=0
    while (( n < 512 )); do
        n=$(( n + 1 ))
        case "$st" in
            1) [[ "$s" == *"'"* ]] || break
               s="${s#*"'"}"; st=0 ;;
            0) [[ "$s" == *[\"\'\\]* ]] || break
               p="${s%%[\"\'\\]*}"; s="${s#"$p"}"; c="${s:0:1}"; s="${s:1}"
               case "$c" in
                   "'") d="${p##*[!\$]}"; if (( ${#d} % 2 )); then st=3; else st=1; fi ;;
                   '"') st=2 ;;
                   *) s="${s:1}" ;;
               esac ;;
            3) [[ "$s" == *[\'\\]* ]] || break
               s="${s#"${s%%[\'\\]*}"}"; c="${s:0:1}"; s="${s:1}"
               case "$c" in "'") st=0 ;; *) s="${s:1}" ;; esac ;;
            2) [[ "$s" == *[\"\\]* ]] || break
               s="${s#"${s%%[\"\\]*}"}"; c="${s:0:1}"; s="${s:1}"
               case "$c" in '"') st=0 ;; *) s="${s:1}" ;; esac ;;
            *) break ;;
        esac
    done
    (( n < 512 )) || st=9
    _hd_qs="$st"
}

_hd_pipe_view() {   # <text after the delimiter> → sets _hd_pv: it minus its complete command substitutions
    local v="$1" g pre t n=0
    while (( n < 64 )); do
        n=$(( n + 1 ))
        if [[ "$v" =~ \$\([^\(\)]*\) ]] || [[ "$v" =~ \`[^\`]*\` ]]; then
            g="${BASH_REMATCH[0]}"
            [[ "$g" == *'<<'* ]] && break
            pre="${v%%"$g"*}"
            [[ "$pre" == *'\' ]] && break
            [[ "$pre" == *'$('* || "$pre" == *'`'* ]] && break
            t="${pre//[^\']/}"; (( ${#t} % 2 )) && break
            _hd_qwalk "$pre" 0; [[ "$_hd_qs" == 1 || "$_hd_qs" == 3 || "$_hd_qs" == 9 ]] && break
            v="${v/"$g"/_}"
        else
            break
        fi
    done
    _hd_pv="$v"
}

# Blank the bodies of data-consumer heredocs in $1; print the result.
# Never fails: on any doubt it prints its input unchanged.
_mask_heredoc_bodies() {
    local src="$1"
    # A HEAD INDEX, not an array shift. `arr=("${arr[@]:1}")` on a
    # one-element array expands to nothing, and under `set -u` that is an
    # UNBOUND VARIABLE error on bash before 4.4 — in a hook whose every
    # failure path exits 0 silently, i.e. a portability bug that would
    # present as the detector quietly not working on an older host.
    local -a d_delim=() d_dash=() d_mask=() d_hold=(); local hp=0
    local out="" line t rest pre delim dash cmdword seg segsub qd qs qw aop acl nopen nview lpipe abort=0
    local subst=0 pseg="" outer="" hold_m="" hold_o="" pend=0 hidx=-1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ${#d_delim[@]} > hp )); then
            t="$line"
            if (( d_dash[hp] )); then
                while [[ "$t" == "	"* ]]; do t="${t#	}"; done
            fi
            if [[ "$t" == "${d_delim[hp]}" ]]; then
                if (( d_hold[hp] )); then hold_m+=$'\n'; hold_o+=$'\n'; pend=1; else out+=$'\n'; fi
                hp=$(( hp + 1 ))
                continue
            fi
            if (( d_hold[hp] )); then
                hold_m+=$'\n'; hold_o+="$line"$'\n'
            elif (( d_mask[hp] )); then out+=$'\n'; else out+="$line"$'\n'; fi
            continue
        fi
        # THE CLOSING `)` OF A `$(cat <<EOF` (#1870 item 5). Its body was HELD,
        # and this line decides it: a `)` here whose remainder carries no pipe
        # releases the body masked; a pipe after the `)` (`) | bash`), or no
        # `)` at all (the close is somewhere this parse does not follow),
        # releases it verbatim, so it is scanned. So does a `)` line that ENDS
        # IN A BACKSLASH (#1873 N1): it continues onto a line this decision
        # does not read, where the pipe may sit (`) \` / `  | bash`), so it is
        # undecided. Only a backslash that is the LAST character continues a
        # line; `\\` (a literal backslash) is treated the same, erring toward
        # the false positive. (`bs` holds the backslash so the tested line
        # carries none at its end: mutation-gate.sh reads such a line as a
        # continuation and refuses it.)
        if (( pend )); then
            t="${line#"${line%%[![:space:]]*}"}"
            lpipe='|'
            if [[ "$t" == ')'* ]]; then
                t="${t:1}"
                if (( ${#t} <= 8192 )); then _hd_pipe_view "$t"; lpipe="$_hd_pv"; fi
                local bs='\'
                [[ "$t" == *"$bs" ]] && lpipe='|'
            fi
            if [[ "$lpipe" != *'|'* ]]; then out+="$hold_m"; else out+="$hold_o"; fi
            hold_m=""; hold_o=""; pend=0
        fi
        # The OPENING line is always emitted verbatim: `sbatch <<EOF` must
        # still fire from the opener even though its body is a job script.
        out+="$line"$'\n'
        [[ "$line" == *'<<'* ]] || continue
        # LINEAR, NOT QUADRATIC. An earlier form of this loop re-scanned the
        # whole accumulated prefix for quote parity and `((` depth on EVERY
        # `<<`, which is O(occurrences x line length). Measured on this host
        # against a synthetic `echo a<<b a<<b …` line: 200 occurrences took
        # 10.5 s and 600 did not finish inside 100 s, against a flat ~0.16 s
        # for the unpatched hook — a hook that WEDGES blocks claude's turn,
        # which is the exact hot-path objection your-org/nexus-code#1312
        # raised. The counters below are updated from the chunk just consumed,
        # so the whole line costs one pass. The `_hd_cap` arm is belt and
        # braces: past it, masking is abandoned entirely and the ORIGINAL text
        # is scanned, i.e. the hook degrades to its previous behaviour rather
        # than to a miss.
        qd=0; qs=0; qw=0; aop=0; acl=0; seg=""; segsub=0; subst=0; rest="$line"; nopen=0; nview=0; hidx=-1
        while [[ "$rest" == *'<<'* ]]; do
            nopen=$(( nopen + 1 ))
            if (( nopen > 64 )); then abort=1; break 2; fi
            pre="${rest%%'<<'*}"
            rest="${rest#*'<<'}"
            t="${pre//[^\"]/}"; qd=$(( qd + ${#t} ))
            t="${pre//[^\']/}"; qs=$(( qs + ${#t} ))
            _hd_qwalk "$pre" "$qw"; qw="$_hd_qs"
            t="${pre//'(('/}";   aop=$(( aop + (${#pre} - ${#t}) / 2 ))
            t="${pre//'))'/}";   acl=$(( acl + (${#pre} - ${#t}) / 2 ))
            # `seg` is the text since the last command separator — the simple
            # command that governs this redirection.
            # `segsub` = the command opens a BARE `( … )` subshell. Its output
            # leaves through the `)`, which sits on a LATER line this per-line
            # parse never reads (`( cat <<EOF` … `EOF` … `) | bash` runs the
            # body), so such an opener is never masked. A `$(` is not one: the
            # captured-text idiom `body=$(cat <<'EOF'` is this workspace's
            # commonest heredoc. A `$(` has its own arm (`subst`, #1870 item 5).
            pseg="$seg"
            if [[ "$pre" == *[\;\&\|\(]* ]]; then
                seg="${pre##*[;&|(]}"; t="${pre%"$seg"}"
                segsub=0; [[ "$t" == *'(' && "$t" != *'$(' ]] && segsub=1
                # `subst` = the command sits inside a `$(` (#1870 item 5), and
                # `outer` is the text of the simple command that `$(` is in.
                subst=0; outer=""
                if [[ "$t" == *'$(' ]]; then
                    subst=1; outer="${t:0:${#t}-2}"   # drop the `$(` (the test above proved it ends t)
                    if [[ "$outer" == *[\;\&\|\(]* ]]; then outer="${outer##*[;&|(]}"; else outer="$pseg$outer"; fi
                    outer="${outer#"${outer%%[![:space:]]*}"}"
                fi
            else
                seg+="$pre"
            fi
            # `<<<` is a herestring, not a heredoc.
            if [[ "$rest" == '<'* ]]; then rest="${rest#<}"; continue; fi
            # Inside a string ⇒ not an opener. Two readings, and EITHER one
            # skips: an odd quote count, or the quote walk (#1868 item 1: the
            # count alone reads a `'` inside "…" as a quote). Erring here can
            # only FAIL TO MASK, never mask something executable — but a
            # reading that wrongly says "unquoted" registers an opener that is
            # really text, which CAN mask the lines after it, so the union.
            if (( qd % 2 )) || (( qs % 2 )) || [[ "$qw" != 0 ]]; then continue; fi
            # `$(( a << b ))` is a LEFT SHIFT, not a heredoc.
            if (( aop > acl )); then continue; fi
            dash=0
            if [[ "$rest" == '-'* ]]; then dash=1; rest="${rest#-}"; fi
            while [[ "$rest" == ' '* || "$rest" == "	"* ]]; do rest="${rest#?}"; done
            delim=""
            case "$rest" in
                '"'*) rest="${rest#\"}"; delim="${rest%%\"*}"; rest="${rest#*\"}"; qd=$(( qd + 2 )) ;;
                "'"*) rest="${rest#\'}"; delim="${rest%%\'*}"; rest="${rest#*\'}"; qs=$(( qs + 2 )) ;;
                *)    [[ "$rest" == '\'* ]] && rest="${rest#\\}"
                      if [[ "$rest" =~ ^[A-Za-z0-9_]+ ]]; then
                          delim="${BASH_REMATCH[0]}"; rest="${rest#"$delim"}"
                      fi ;;
            esac
            # A delimiter that is not an identifier is a mis-parse (this is
            # what rejects the numeric delimiter a left shift manufactures).
            [[ "$delim" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            cmdword="${seg#"${seg%%[![:space:]]*}"}"
            cmdword="${cmdword%%[[:space:]]*}"
            # The pipe test reads only what follows THIS delimiter (#1868 item 2),
            # and runs only for an opener the mask could otherwise apply to.
            # BOUNDED: a view per opener costs (removals x text length), so past
            # 8 views on one line, or on more than 8 KB of text, the raw text is
            # the view — its pipes all count, which refuses the mask (the
            # false-positive side). Measured on a 20 KB line of 64 openers x 60
            # substitutions: 4.3 s unbounded, against 0.75 s for the base hook.
            lpipe='|'
            if (( segsub == 0 )) && [[ "$_HD_DATA_CMDS" == *" $cmdword "* ]]; then
                nview=$(( nview + 1 ))
                if (( nview <= 8 )) && (( ${#rest} <= 8192 )); then
                    _hd_pipe_view "$rest"; lpipe="$_hd_pv"
                else
                    lpipe="$rest"
                fi
            fi
            # A `$(cat <<EOF` (#1870 item 5). Its OUTPUT is the substitution's
            # value, so what may run the body is the command AROUND the `$(`,
            # and the `)` that closes it is on a LATER line. Two arms:
            #   * the `$(` must be an assignment's value (`body=$(cat <<'EOF'`,
            #     this workspace's commonest heredoc) or an argument of a named
            #     data consumer (`gh … --body $(cat <<EOF`). Anything else is
            #     not masked: at command position the value IS a command
            #     (`$(cat <<EOF` … `)` runs `sbatch job.sh`), and `eval`,
            #     `bash -c` or an unknown wrapper may run it;
            #   * when the opener line does not close the `$(`, the body is
            #     HELD and the closing `)` line decides (above). This also
            #     needs it to be the line's LAST opener, so the held body is
            #     the last one before that line; a later opener unmasks it.
            # Default DO NOT MASK, like every other arm here. (`rp` holds the
            # `)` so no tested line carries a lone paren: mutation-gate.sh
            # refuses to mutate a line it reads as unbalanced.)
            local hold=0 odata=0 rp=')'
            if (( subst )); then
                [[ "$outer" =~ ^((local|export|declare|readonly|typeset)([[:space:]]+-[A-Za-z]+)*[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=$ ]] && odata=1
                [[ -n "$outer" && "$_HD_DATA_CMDS" == *" ${outer%%[[:space:]]*} "* ]] && odata=1
            fi
            if [[ "$lpipe" != *'|'* ]] && (( segsub == 0 )) && [[ "$_HD_DATA_CMDS" == *" $cmdword "* ]]; then
                if (( subst )); then
                    if (( odata )); then
                        d_mask+=(1)
                        [[ "$rest" == *"$rp"* ]] || hold=1
                    else
                        d_mask+=(0)
                    fi
                else
                    d_mask+=(1)
                fi
            else
                d_mask+=(0)
            fi
            if (( hidx >= 0 )); then d_mask[hidx]=0; d_hold[hidx]=0; hidx=-1; fi
            (( hold )) && hidx=${#d_hold[@]}
            d_hold+=("$hold")
            d_delim+=("$delim"); d_dash+=("$dash")
        done
    done <<< "$src"
    # Unterminated at the end ⇒ the parse was wrong ⇒ mask nothing.
    # Same for the pathological-line abort. Both fall back to TODAY's
    # behaviour, never to a miss.
    # A held body whose closing line never came is released VERBATIM.
    (( pend )) && out+="$hold_o"
    if (( abort )) || (( ${#d_delim[@]} > hp )); then printf '%s' "$src"; else printf '%s' "$out"; fi
}

# The SCAN VIEW. `command_str` itself is untouched: the synthetic id is
# `sha1(command_str)`, so masking it would change every `syn-` id.
command_scan="$command_str"
case "$command_str" in
    *'<<'*) command_scan=$(_mask_heredoc_bodies "$command_str") || command_scan="$command_str" ;;
esac
[[ -n "$command_scan" ]] || command_scan="$command_str"

# ---- QUOTED TEXT AND COMMENTS ARE NOT COMMANDS (your-org/nexus-code#1832) --
#
# THE DEFECT. Every row below is a regex over command TEXT, and text inside a
# string is still text. A worker that ran no Slurm job at all got a
# `slurm:syn-…` wait from `git commit -m "…\n\nsbatch job names in code…"`:
# per-line matching (#948) made line 3 of the MESSAGE a line start. The same
# shape fires on `ng send --message '…; sbatch …'`, `echo "x && sbatch y"`,
# `echo 'call it (sbatch)'` and a `# …; sbatch` comment — anything where the
# word sits after a separator or a newline INSIDE a quote.
#
# THE RULE. Before any row is tried, the scan view has the BODY of every
# single-quoted, double-quoted and `$'…'` string, and every `#` comment,
# replaced by `_` (newlines included, so a multi-line message is one line).
# The quote characters themselves stay, so positions are unchanged in kind.
# What a shell would EXECUTE inside a double-quoted string is kept verbatim:
# `jid="$(sbatch --parsable j.sh)"` still reads `$(sbatch …`, and so do
# backticks, so the `$(…)` handling (#1727) sees exactly what it saw before.
#
# THE MISS DIRECTION IS THE EXPENSIVE ONE, so two arms fall back to TODAY:
#   * a string whose simple command contains a SHELL RUNNER word before it
#     (`bash -c '…'`, `ssh node01 'cd d && sbatch j.sh'`, `eval "…"`,
#     `tmux send-keys … '…'`, `find … -exec sh -c '…'`) is left unmasked — its
#     body is a command, not text;
#   * any parse doubt — an unterminated quote, `$(`, backtick or heredoc —
#     discards the whole mask and scans the unmasked view, i.e. today.
# Heredoc BODIES are copied through untouched: the data-consumer mask above
# already decided them, and a body is not shell-quoted text.
#
# RESIDUAL FALSE NEGATIVE, declared: a non-runner command that executes a
# quoted argument as shell (`nix-shell --run '…'`, `git rebase --exec '…'`,
# `make CMD='…'`) is masked and missed. Adding its name to _Q_RUNNERS is the
# fix, and a data edit.
#
# HOT PATH: skipped unless the command names a launcher AND contains a quote
# or `#`; then ONE awk exec, linear in the command (it streams its output, so
# no quadratic string growth).
_Q_RUNNERS='bash sh zsh dash ksh mksh fish eval ssh su sudo doas srun salloc tmux screen watch xargs parallel flock nohup setsid script'
_mask_quotes_awk='
function flushw() { if (cur != "") { w = cur; sub(/.*\//, "", w); words = words w " "; cur = "" } }
function runner(   n, i, a) {
    flushw()
    n = split(words, a, " ")
    for (i = 1; i <= n; i++) if (a[i] in R) return 1
    return 0
}
function newcmd() { cur = ""; words = " " }
BEGIN { SQ = "\047"; n = split(runners, a, " "); for (i = 1; i <= n; i++) R[a[i]] = 1 }
{ src = (NR > 1) ? src "\n" $0 : $0 }
END {
    L = length(src); sp = 0; ctx[0] = "T"; dep[0] = 0; newcmd()
    hn = 0; hq = 1; inbody = 0; prevc = "\n"
    i = 1
    while (i <= L) {
        if (inbody) {
            rest = substr(src, i); j = index(rest, "\n")
            if (j == 0) { line = rest; adv = length(rest) } else { line = substr(rest, 1, j - 1); adv = j }
            t = line; if (hdash[hq]) sub(/^\t+/, "", t)
            printf "%s", substr(src, i, adv); i += adv
            if (t == hdel[hq]) { hq++; if (hq > hn) { inbody = 0; hn = 0; hq = 1 } }
            prevc = "\n"; continue
        }
        c = substr(src, i, 1); c2 = substr(src, i + 1, 1); top = ctx[sp]
        if (top == "S" || top == "A") {
            if (top == "A" && c == "\\") { printf "%s", raw[sp] ? c c2 : "__"; i += 2; continue }
            if (c == SQ) { printf "%s", c; sp--; i++; prevc = c; continue }
            printf "%s", raw[sp] ? c : "_"; i++; continue
        }
        if (top == "D") {
            if (c == "\\") { printf "%s", raw[sp] ? c c2 : "__"; i += 2; continue }
            if (c == "\"") { printf "%s", c; sp--; i++; prevc = c; continue }
            if (c == "$" && c2 == "(") { ctx[++sp] = "C"; dep[sp] = 0; raw[sp] = 0; newcmd(); printf "$("; i += 2; continue }
            if (c == "`") { ctx[++sp] = "B"; raw[sp] = 0; newcmd(); printf "`"; i++; continue }
            printf "%s", raw[sp] ? c : "_"; i++; continue
        }
        # Unquoted: top level, inside $( ), inside backticks.
        if (c == "\\") { printf "%s", c c2; cur = cur c c2; i += 2; prevc = c2; continue }
        if (c == SQ) { r = runner(); ctx[++sp] = "S"; raw[sp] = r; printf "%s", c; i++; continue }
        if (c == "$" && c2 == SQ) { r = runner(); ctx[++sp] = "A"; raw[sp] = r; printf "$%s", SQ; i += 2; continue }
        if (c == "\"") { r = runner(); ctx[++sp] = "D"; raw[sp] = r; printf "%s", c; i++; continue }
        if (c == "$" && c2 == "(") { ctx[++sp] = "C"; dep[sp] = 0; raw[sp] = 0; newcmd(); printf "$("; i += 2; prevc = "("; continue }
        if (c == "`") {
            if (top == "B") sp--; else { ctx[++sp] = "B"; raw[sp] = 0 }
            newcmd(); printf "`"; i++; prevc = c; continue
        }
        if (c == "(") { if (top == "C") dep[sp]++; newcmd(); printf "("; i++; prevc = c; continue }
        if (c == ")") {
            if (top == "C") { if (dep[sp] == 0) sp--; else dep[sp]-- }
            newcmd(); printf ")"; i++; prevc = c; continue
        }
        if (c == "#" && prevc ~ /^[ \t\n;&|()]$/) {
            printf "#"; i++
            while (i <= L && substr(src, i, 1) != "\n") { printf "_"; i++ }
            continue
        }
        if (c == "<" && c2 == "<") {
            if (substr(src, i + 2, 1) == "<") { printf "<<<"; i += 3; prevc = "<"; continue }
            k = i + 2; d = 0; dl = ""
            if (substr(src, k, 1) == "-") { d = 1; k++ }
            while (substr(src, k, 1) ~ /^[ \t]$/) k++
            q = substr(src, k, 1)
            if (q == SQ || q == "\"") {
                e = index(substr(src, k + 1), q)
                if (e > 0) { dl = substr(src, k + 1, e - 1); k = k + e + 1 }
            } else {
                if (q == "\\") k++
                if (match(substr(src, k), /^[A-Za-z0-9_]+/)) { dl = substr(src, k, RLENGTH); k += RLENGTH }
            }
            if (dl ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { hn++; hdel[hn] = dl; hdash[hn] = d }
            printf "%s", substr(src, i, k - i); i = k; prevc = "<"; continue
        }
        if (c == "\n") { newcmd(); printf "\n"; i++; prevc = c; if (hn > 0) inbody = 1; continue }
        if (c == ";" || c == "&" || c == "|") { newcmd(); printf "%s", c; i++; prevc = c; continue }
        if (c == " " || c == "\t") { flushw(); printf "%s", c; i++; prevc = c; continue }
        cur = cur c; printf "%s", c; i++; prevc = c
    }
    if (sp != 0 || inbody || hn > 0) exit 3
}'
case "$command_scan" in
    *sbatch*|*srun*|*nohup*)
        case "$command_scan" in
            *[\'\"#]*)
                _q_scan=$(printf '%s' "$command_scan" | awk -v runners="$_Q_RUNNERS" "$_mask_quotes_awk" 2>/dev/null) \
                    && [[ -n "$_q_scan" ]] && command_scan="$_q_scan" ;;
        esac ;;
esac

hb_dir="$state_dir/heartbeat"
mkdir -p "$hb_dir" 2>/dev/null || exit 0
hb_file="$hb_dir/$window.json"

# Read prior heartbeat for dismissed-waits filtering AND for
# preserving the rest of the fields across our atomic rewrite. A
# missing / corrupt file falls back to an empty skeleton — the
# next worker-heartbeat.sh tick will fill in the missing tick
# fields.
read_existing() {
    if [[ -f "$hb_file" ]] && [[ -r "$hb_file" ]]; then
        local content
        content=$(<"$hb_file") || content=""
        [[ -n "$content" ]] || content='{}'
        if printf '%s' "$content" | jq empty >/dev/null 2>&1; then
            printf '%s' "$content"
        else
            printf '{}'
        fi
    else
        printf '{}'
    fi
}

# Iterate pattern rows. First command_regex that matches the
# worker's command wins (a typical worker command matches at most
# one launch class anyway; deterministic ordering avoids
# surprises). We emit zero or one new external_waits entry per
# hook fire.
matched_kind=""
matched_desc=""
# ONE WAIT PER JOB, NOT ONE PER CALL (your-org/nexus-code#1071).
# A submission LOOP — `for i in 1..15; do sbatch …; done` — is a single Bash
# tool call whose stdout carries fifteen `Submitted batch job <id>` lines. The
# first version of this hook took `BASH_REMATCH[1]` from a whole-string match,
# i.e. the FIRST id, and synthesised `syn-…` for a call it could not id at all.
# Either way the fourteen remaining jobs were invisible, and a `slurm:syn-…`
# token has no job behind it, so nothing can look it up: it is unresolvable by
# construction and the operator's only escape is `declare-no-wait.sh`, which is
# the dangerous direction. A grid is the COMMON shape for this kind of work, so
# per-call tokenisation kept manufacturing exactly the wait the watcher's new
# wake loop (`monitor/watcher/_orphan_async.sh`) cannot resolve.
# Collect EVERY id instead; the ids are what make the waits resolvable.
matched_ids=()
# Ids a Slurm row parsed but the job-id predicate REFUSED (`0`, `007`), and
# whether a bare-number row was distrusted for sitting in `$(…)`. Neither is a
# watch, so both are named in the NOT-ARMED notice (your-org/nexus-code#1727).
_rejected_ids=()
_id_distrust=0
_id_first_only=0   # 1 = only stdout's first non-empty line may carry the id (#1832)
# An `sbatch` inside `$(…)` or backticks. Matched against the WHOLE scan view,
# not per line, so `jid=$(\n  sbatch --parsable …\n)` is caught too: `[^)…]`
# spans a newline in bash's ERE. Over-matching (`$(cat f) sbatch` cannot match:
# the class stops at the first `)`) errs toward distrusting a bare number,
# which costs a NOT-ARMED notice, never a wrong job.
_CMDSUBST_SBATCH_ERE='(\$\(|`)[^)`]*\bsbatch\b'
# ONLY THE ID SBATCH ITSELF PRINTS MAY ARM (your-org/nexus-code#1727 core). A
# `--parsable` row's id field accepts ANY bare-integer stdout line, and the hook
# sees the whole tool call's stdout, not sbatch's. `sbatch --parsable j.sh;
# grep -c x f` prints the id AND a count; proj-w3 armed `slurm:1` from two
# `grep -c` lines exactly so. So a bare number is trusted only when EVERY
# command segment of the call (split on ; && || | & and newlines) is an sbatch
# or a command that prints nothing to stdout here: cd, export, module/ml,
# source/., set, umask, true/:, a pure VAR=value assignment, a comment line,
# loop/branch syntax, and `tee` (it re-prints sbatch's own output).
# RESIDUAL, stated: `source`/`.` and `module` are allowed although a sourced
# file CAN print; `source env.sh; sbatch --parsable …` printing `7` would still
# be read as an id. They are allowed because they are how a submission is set
# up, and distrusting them would un-watch most real submissions.
# Any other segment may have printed the integer, so the call is DISTRUSTED:
# a `syn-` wait plus the NOT-ARMED notice, never a guessed id — UNLESS sbatch
# provably printed first (`_parsable_sbatch_spoke_first`, #1832). Segments are
# split on the QUOTE-MASKED scan view (#1832); where the mask fell back, a
# separator inside quotes only ADDS segments, which errs toward distrust (a
# loud notice), never toward a wrong watch.
# _seg_word <segment> — strip leading VAR=value assignments, shell CONTROL
# words and the WRAPPERS the slurm rows already accept (timeout/nice/env/
# stdbuf/time/nohup, with their own option/duration tokens), then set `_sw` to
# the command word that actually runs ('' for a pure assignment or a comment).
# So `if grep -q …; then sbatch …` judges `grep`, and `env A=1 sbatch` judges
# `sbatch`.
_seg_word() {
    local seg="$1" w
    _sw=""; _sseg=""; _swrap=0; _sctl=0
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [[ -n "$seg" ]] || return 0
    [[ "$seg" == \#* ]] && return 0
    while [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; do
        seg="${BASH_REMATCH[1]}"
    done
    [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*$ ]] && return 0
    w="${seg%%[[:space:]]*}"
    while :; do
        case "$w" in
            do|then|else|if|while|until) _sctl=1 ;;
            '{'|'!') ;;
            time|nohup|env|nice|stdbuf|timeout) _swrap=1 ;;
            *) break ;;
        esac
        seg="${seg#"$w"}"; seg="${seg#"${seg%%[![:space:]]*}"}"
        while [[ "$seg" =~ ^(-[^[:space:]]*|[0-9]+[smhd]?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)([[:space:]]+(.*))?$ ]]; do
            seg="${BASH_REMATCH[3]}"
        done
        w="${seg%%[[:space:]]*}"
    done
    _sw="$w"; _sseg="$seg"
}
# The command words that print nothing to stdout here: cd, export, module/ml,
# source/., set, umask, true/:, loop/branch closers, and `tee` (it re-prints
# sbatch's own output). `for` — the loop HEADER `for x in …` prints nothing;
# its body is judged per segment.
_seg_is_silent() {
    case "$1" in
        ''|cd|export|module|ml|source|.|set|umask|true|:|tee|done|fi|'}'|esac|for) return 0 ;;
    esac
    return 1
}
# FD REDIRECTIONS FIRST (ncbundle17-sk on PR 1745): `2>&1`, `>&2` and
# `&>`/`&>>` carry an `&` that is not a separator; split on it and
# `sbatch --parsable j.sh 2>&1`, the commonest idiom there is, left a
# segment `1` and was distrusted.
_norm_redirs() { printf '%s\n' "$1" | sed -E 's/[0-9]*[<>]&[0-9-]+//g; s/&>>?/>/g'; }
_split_segs() { _norm_redirs "$1" | sed -E 's/(&&|\|\||[;|&])/\n/g'; }
_parsable_call_is_sbatch_only() {   # <command text> → 0 when only sbatch can have printed
    local seg
    while IFS= read -r seg || [[ -n "$seg" ]]; do
        _seg_word "$seg"
        [[ "$_sw" == sbatch ]] && continue
        _seg_is_silent "$_sw" || return 1
    done < <(_split_segs "$1")
    return 0
}
# SBATCH SPOKE FIRST (your-org/nexus-code#1832, the opposite direction to
# #1727). `sbatch --parsable a.sh; echo done` prints `1234567\ndone`, and the
# rule above distrusts it because `echo` could have printed an integer — so a
# real submission fell to a `syn-` wait (observed 3x). ORDER attributes it,
# but only together with a POSITIVE fact about what runs next.
#
# THE INVARIANT. A sbatch that FAILS may print nothing to stdout at all, and
# its failure text is open-ended: `sbatch: error: …`, a sandbox stub's
# `error: chaperon is not responding`, a `timeout` that kills it silently, a
# harness that drops stderr. So "no diagnostic was seen" can never prove that
# sbatch spoke (ncbundle27-sk F1: `timeout 60 sbatch …; echo $?` armed 124,
# `…; wc -l < ids.txt` armed 42, `…; grep -c x f` armed 1). When sbatch is
# silent, stdout's first line belongs to the first command AFTER it that
# prints. So that command must be one whose first line can NEVER be a bare
# integer: `echo` whose first argument is an unquoted word starting with a
# letter (`echo done`, `&& echo submitted`). Then, whichever way sbatch went,
# a bare-integer first line can only be sbatch's own, and a silent failure
# yields `done`, which is no id. Anything that runs later cannot get ahead of
# that echo.
#
# All of these must hold:
#   * exactly one sbatch in the call, it is `--parsable`, and NO WRAPPER runs
#     it (`timeout`/`nice`/`env`/`stdbuf`/`time`/`nohup`: a wrapper can kill
#     it or fail in its place, silently on stdout);
#   * every segment before it is a silent one (the list above);
#   * after it, only the never-an-integer words below, then the literal echo;
#   * no lone `&` (a backgrounded command can print first or interleave) and
#     no `|` other than `| tee` (a pipeline's members run concurrently);
#   * no loop keyword (`for`/`while`/`until`/`select`): a loop repeats, so
#     "one sbatch in the text" is not one sbatch run;
#   * no output redirection to a FILE anywhere in the call (`> f`, `2>…`,
#     `&>…`; the fd duplications `2>&1`/`>&2` are fine).
#   * the vouching echo is UNCONDITIONAL — reached from sbatch through `;`,
#     newlines and `| tee` only, and not opened by `then`/`else`/`do`/`if`/
#     `while`/`until` — OR nothing after it can print. `sbatch … && echo ok;
#     grep -c x f` skips the echo exactly when sbatch FAILS, and grep's `1`
#     takes the slot (ncbundle27-sk R1).
# The caller adds two refusals: a non-empty SEPARATED stderr, and any
# `sbatch:`/`found: sbatch` text in the output.
# DECLARED COST: every other follow-on (`; grep -c x f`, `; squeue …`, a
# QUOTED `echo "done"`, which the quote mask blanks) is a `syn-` wait plus the
# NOT-ARMED notice, as on dev. A loud miss, never a wrong id.
# RESIDUAL, stated: `source`/`module` BEFORE sbatch can print (see above).
_PIPE_NOT_TEE_ERE='[|][[:space:]]*([^t[:space:]]|t[^e]|te[^e]|tee[^[:space:]]|$)'
_LOOP_KW_ERE='(^|[[:space:];&|({])(for|while|until|select)([[:space:]]|$)'
_PARSABLE_FLAG_ERE='(^|[[:space:]])--parsable([[:space:]=]|$)'
_LITERAL_ECHO_ERE='^echo[[:space:]]+[A-Za-z][A-Za-z0-9_.,:!-]*([[:space:]]|$)'
# After sbatch and before the echo: words that print nothing, or never a bare
# integer (`cd -` prints a path). `tee` re-prints sbatch's own line. NOT here:
# `source`/`module`/`ml` (anything). `umask` (prints `0022`) is excluded too,
# although the job-id predicate already rejects that shape.
_seg_is_quiet_after() {
    case "$1" in
        ''|true|:|tee|cd|export|done|fi|'}'|esac) return 0 ;;
    esac
    return 1
}
# Like _split_segs, but each segment after the first keeps the separator that
# PRECEDED it as a leading `&&`/`||`/`;`/`|` token, so a conditional join is
# visible (newline separators carry none: they are unconditional).
_split_segs_sep() { _norm_redirs "$1" | sed -E 's/(&&|\|\||[;|&])/\n\1 /g'; }
_parsable_sbatch_spoke_first() {   # <command text> → 0 when sbatch's line is stdout's first
    local norm seg sep nsb=0 first=0 before=1 vouched=0 cond=0
    norm=$(_norm_redirs "$1")
    norm="${norm//&&/ }"; norm="${norm//||/ }"
    [[ "$norm" == *'&'* ]] && return 1
    [[ "$norm" == *'>'* ]] && return 1
    [[ "$norm" =~ $_PIPE_NOT_TEE_ERE ]] && return 1
    [[ "$norm" =~ $_LOOP_KW_ERE ]] && return 1
    while IFS= read -r seg || [[ -n "$seg" ]]; do
        sep=""
        case "$seg" in
            '&& '*|'|| '*) sep="${seg%% *}"; seg="${seg#* }" ;;
            '; '*|'| '*)   seg="${seg#* }" ;;
        esac
        _seg_word "$seg"
        if [[ "$_sw" == sbatch ]]; then
            nsb=$(( nsb + 1 ))
            (( _swrap )) && return 1
            if (( before )) && [[ "$_sseg" =~ $_PARSABLE_FLAG_ERE ]]; then first=1; fi
            before=0
            continue
        fi
        if (( before )); then
            _seg_is_silent "$_sw" || return 1
            continue
        fi
        if (( vouched )); then
            # A CONDITIONAL vouch holds only if nothing after it can print.
            (( cond )) && ! _seg_is_quiet_after "$_sw" && return 1
            continue
        fi
        [[ -n "$sep" ]] && cond=1
        (( _sctl )) && cond=1
        _seg_is_quiet_after "$_sw" && continue
        [[ "$_sseg" =~ $_LITERAL_ECHO_ERE ]] || return 1
        vouched=1
    done < <(_split_segs_sep "$1")
    (( nsb == 1 && first == 1 && vouched == 1 ))
}
# ---- A DRY RUN CREATES NO JOB (your-org/nexus-code#1854 a) ------------------
# `sbatch --test-only` asks the controller WHEN a job would start and prints a
# would-be id on stderr (`sbatch: Job 1234567 to start at …`), and `--help`,
# `--usage` and `--version` print text. None creates a job, so a wait armed for
# one can never resolve: measured 2026-10-16, a `--test-only` probe became an
# untracked `slurm:syn-…` wait and an `idle-orphan-async` flag. The call arms
# NOTHING when EVERY sbatch in it is such a call.
#
# WHERE THE FLAG MAY SIT. Anything after the job SCRIPT is the script's own
# argument (`sbatch job.sh --help` SUBMITS job.sh). The script is the first
# word that is neither an option nor an option's VALUE, so the scan walks
# sbatch's option table (your-org/nexus-code#1859 b): `-p part-x --test-only
# job.sh` is a dry run, and `-p part-x job.sh --test-only` submits job.sh. A
# value attached in the same word (`-ppart-x`, `--partition=part-x`) is one
# word; a short-option CLUSTER (`-Hp part-x`) takes its value from the rest of
# the word or, when the value option is last, from the next word; `--` ends the
# options. A flag after the script is not recognised, and the call is treated
# as a real submission — the miss direction this hook prefers (a loud `syn-`
# wait, never a dropped job).
#
# THE OPTION TABLE, from sbatch(1) on this host: every option whose argument is
# REQUIRED. An option with an OPTIONAL argument (`--exclusive[=…]`, `--nice`,
# `-k/--no-kill`, `--requeue`, `--propagate`, `--resv-ports`, `--oom-kill-step`,
# `--get-user-env`, `-I`) takes it only after `=`, so it is flag-only here.
# AN OPTION NOT IN THIS TABLE IS TREATED AS FLAG-ONLY. If it really takes a
# value, that value is read as the script, the scan stops, and a later
# `--test-only` is not seen: the call ARMS a `syn-` wait. That is the loud
# direction. The opposite error, a flag listed here as taking a value, would
# swallow the script and could read a job argument as a dry flag — a dropped
# job — which is why only man-page-required arguments are listed.
_SBATCH_DRY_ERE='^(--test-only|--help|--usage|--version|-h|-V)$'
_SBATCH_VALUE_SHORT='AabBCcDdeFGiJLMmNnopqStwx'
_SBATCH_VALUE_LONG=' account acctg-freq array batch bb bbf begin chdir cluster-constraint clusters comment constraint container container-id core-spec cores-per-socket cpu-freq cpus-per-gpu cpus-per-task deadline delay-boot dependency distribution error exclude export export-file extra extra-node-info gid gpu-bind gpu-freq gpus gpus-per-node gpus-per-socket gpus-per-task gres gres-flags hint input job-name kill-on-invalid-dep licenses mail-type mail-user mcs-label mem mem-bind mem-per-cpu mem-per-gpu mincpus network nodefile nodelist nodes ntasks ntasks-per-core ntasks-per-gpu ntasks-per-node ntasks-per-socket open-mode output partition prefer priority profile qos reservation resources segment signal sockets-per-node switches thread-spec threads-per-core time time-min tmp tres-bind tres-per-task uid wait-all-nodes wckey wrap '
# _sbatch_args_dry <args after the word sbatch> → 0 when a dry flag precedes
# the script. `read -ra`, not an unquoted `for w in $x`: the words come from
# command text, and an unquoted expansion would GLOB them.
_sbatch_args_dry() {
    local -a ws=(); local i=0 n w j c skip=0
    read -ra ws <<< "$1"
    n=${#ws[@]}
    while (( i < n )); do
        w="${ws[i]}"; i=$(( i + 1 ))
        if (( skip )); then skip=0; continue; fi
        [[ "$w" =~ $_SBATCH_DRY_ERE ]] && return 0
        case "$w" in
            --) return 1 ;;
            --*=*) ;;
            --?*) [[ "$_SBATCH_VALUE_LONG" == *" ${w#--} "* ]] && skip=1 ;;
            -?*)
                for (( j = 1; j < ${#w}; j++ )); do
                    c="${w:j:1}"
                    [[ "$c" == h || "$c" == V ]] && return 0
                    if [[ "$_SBATCH_VALUE_SHORT" == *"$c"* ]]; then
                        (( j == ${#w} - 1 )) && skip=1
                        break
                    fi
                done ;;
            *) return 1 ;;
        esac
    done
    return 1
}
# PER INVOCATION, NOT PER SEGMENT HEAD (your-org/nexus-code#1864). The first
# form judged only segments whose COMMAND WORD was sbatch, via `_seg_word`. That
# word-finder strips a leading `VAR=value` as an assignment, so `jid=$(sbatch
# --parsable b.sh)` read as the command `--parsable`, and `\sbatch b.sh` read as
# `\sbatch`. Neither counted as an sbatch, so `sbatch --test-only a.sh;
# jid=$(sbatch --parsable b.sh)` looked like "one sbatch, and it is dry" and the
# REAL job b.sh armed nothing: the dropped-job direction this hook exists to
# avoid.
#
# So every OCCURRENCE of the word `sbatch` in the scan view is an invocation, in
# whatever position it sits: a segment head, inside `$(…)` or backticks, after
# `\`, after a path (`/usr/bin/sbatch`), after a wrapper (`xargs sbatch`). Its
# arguments run to the next separator (`; & | )`, a backtick, a newline). The
# call is dry-only when there is at least one occurrence and EVERY one is dry.
# An occurrence that is not really an invocation (`which sbatch`, `ls
# jobs/sbatch`) has no dry flag before a script word, so it reads as a REAL
# submit and the call arms: a `syn-` wait, the loud direction. Quoted text and
# masked heredoc bodies are already blanked in the scan view, so prose does not
# count. Past 64 occurrences the call is treated as real, for the same reason.
# A redirection GLUED to the word (`sbatch<b.sh`, `sbatch>o.txt b.sh`) ends it
# too: without `<>` in the suffix class such a real submit was not counted, and
# a dry probe beside it made the whole call read dry-only (ncbundle33-sk F1).
_SBATCH_OCC_ERE='(^|[^A-Za-z0-9_.-])sbatch([[:space:];&|)`<>]|$)'
_sbatch_call_is_dry_only() {   # <command text> → 0 when ≥1 sbatch ran and all are dry
    local rest m pre args nsb=0
    rest=$(_norm_redirs "$1")
    rest="${rest//$'\n'/;}"
    while [[ "$rest" =~ $_SBATCH_OCC_ERE ]]; do
        m="${BASH_REMATCH[0]}"
        nsb=$(( nsb + 1 ))
        (( nsb > 64 )) && return 1
        # The regex's leftmost match is the first literal occurrence of `m`:
        # any literal copy of `m` is itself a match.
        pre="${rest%%"$m"*}${m%%sbatch*}"; pre="${pre##*[;&|(\`]}"
        rest="${rest#*"$m"}"
        # A LOOKUP names sbatch without running it (`command -v sbatch &&
        # sbatch --test-only …`). Exact final words only, so this arm cannot
        # swallow an invocation: none of these runs its argument.
        if [[ "$pre" =~ (^|[[:space:]])(which|type|whence|whereis|hash|man|command[[:space:]]+-[vV])[[:space:]]+$ ]]; then
            nsb=$(( nsb - 1 )); continue
        fi
        # A separator the match consumed ends this invocation's arguments.
        case "$m" in
            *sbatch) args="$rest" ;;
            *[[:space:]]) args="$rest" ;;
            *) args="" ;;
        esac
        args="${args%%[;&|)\`]*}"
        _sbatch_args_dry "$args" || return 1
    done
    (( nsb > 0 ))
}

# ---- THE ID SBATCH WROTE TO A FILE, READ BACK BY `cat` (#1854 b) -------------
# The measured submission shape, three of four synthetic waits on 2026-10-16:
#
#     … && sbatch --parsable … > $P/JOBID.txt; echo "sbatch rc=$?"; cat $P/JOBID.txt
#
# Every rule above distrusts it, correctly: `echo` and `cat` both print, and a
# bare integer could be either one's. What makes it ATTRIBUTABLE is a POSITIVE
# fact the call prints about itself. `$?` in that echo is the status of the
# and-or list that ENDS in sbatch. With no `||` and no `if`/`while`/`case`
# anywhere, that list is 0 only when every `&&` element ran and succeeded,
# sbatch last. So when the echo line reads `rc=0`, sbatch RAN and EXITED 0, and
# its stdout went into the file its own redirection had just truncated. `cat`
# is the last command, so stdout's last line is sbatch's own line.
#
# A skipped sbatch is the case this closes rather than opens. When an earlier
# `&&` element fails, the redirection never happens and the file keeps a
# PREVIOUS job's id; `$?` is then that element's non-zero status, the echo line
# is not `rc=0`, and nothing is read.
#
# All of these must hold, or this path reads nothing:
#   * exactly ONE sbatch, `--parsable`, no wrapper, stdout redirected `> F`
#     (or `1> F`) to an UNQUOTED word F; never `>>` (an append keeps old ids);
#   * no `||`, no lone `&`, no loop or branch keyword, no backtick, and no
#     `(`/`)` once every `$( … )` is blanked (they cannot hold sbatch: the
#     `$(…)` rule above already distrusts that);
#   * the call ENDS with exactly these two commands after sbatch, each joined
#     by `;` or a newline: an `echo "<text>"` whose text expands nothing but
#     `$?` and holds no backslash, then `cat F`, with the same word F;
#   * stdout's last two non-empty lines are that echo's text with `$?` read as
#     `0`, then the id. Prints the id, rc 0; rc 1 otherwise.
# The echo's text is read from the ORIGINAL command, located through the
# quote-masked scan view by POSITION. That only works if the two align, so
# every character the mask did not blank must match the original. If not, the
# mask moved something and nothing is read.
_parsable_sbatch_via_file() {   # <scan view> <original command> <stdout>
    local scan="$1" orig="$2" out="$3" v n=0 seg sep
    v="$scan"
    while [[ "$v" =~ \$\([^()]*\) ]] && (( n < 64 )); do
        v="${v/"${BASH_REMATCH[0]}"/_}"; n=$(( n + 1 ))
    done
    [[ "$v" == *'`'* || "$v" == *'('* || "$v" == *')'* || "$v" == *'||'* ]] && return 1
    local norm; norm=$(_norm_redirs "$v"); norm="${norm//&&/ }"
    [[ "$norm" == *'&'* ]] && return 1
    [[ "$norm" =~ $_LOOP_KW_ERE ]] && return 1
    local -a segs=() seps=()
    while IFS= read -r seg || [[ -n "$seg" ]]; do
        sep=""
        case "$seg" in
            '&& '*|'|| '*|'; '*|'| '*) sep="${seg%% *}"; seg="${seg#* }" ;;
        esac
        _seg_word "$seg"
        (( _sctl )) && return 1
        case "$_sw" in case|esac|if|fi|elif|else|then|while|until|do|done) return 1 ;; esac
        [[ -n "$_sw" ]] || continue
        segs+=("$_sseg"); seps+=("$sep")
    done < <(_split_segs_sep "$v")
    local k=${#segs[@]} i sb=-1 nsb=0
    (( k >= 3 )) || return 1
    for (( i = 0; i < k; i++ )); do
        [[ "${segs[i]%%[[:space:]]*}" == sbatch ]] && { sb=$i; nsb=$(( nsb + 1 )); }
    done
    (( nsb == 1 && sb == k - 3 )) || return 1
    # the sbatch segment: --parsable, one `> F` (or `1> F` / `>F`)
    local sbs="${segs[sb]}" w prev="" f="" nred=0
    [[ "$sbs" =~ $_PARSABLE_FLAG_ERE ]] || return 1
    for w in $sbs; do
        if [[ "$prev" == '>' || "$prev" == '1>' ]]; then f="$w"; nred=$(( nred + 1 )); prev=""; continue; fi
        case "$w" in
            '>>'*|'1>>'*) return 1 ;;
            '>'|'1>') prev="$w" ;;
            '>'?*) f="${w#>}"; nred=$(( nred + 1 )) ;;
            '1>'?*) f="${w#1>}"; nred=$(( nred + 1 )) ;;
        esac
    done
    (( nred == 1 )) && [[ -n "$f" && "$f" != *[\"\']* ]] || return 1
    # the two trailing segments: echo "<text>" then `cat F`, unconditional joins
    [[ "${seps[sb+1]}" == '' || "${seps[sb+1]}" == ';' ]] || return 1
    [[ "${seps[sb+2]}" == '' || "${seps[sb+2]}" == ';' ]] || return 1
    [[ "${segs[sb+2]}" =~ ^cat[[:space:]]+([^[:space:]]+)[[:space:]]*$ && "${BASH_REMATCH[1]}" == "$f" ]] || return 1
    [[ "${segs[sb+1]}" =~ ^echo[[:space:]]+\" ]] || return 1
    # recover the echo from the ORIGINAL by position: the call ends `<echo…>; cat F`
    local ms="$scan" os="$orig"
    ms="${ms%"${ms##*[![:space:]]}"}"; os="${os%"${os##*[![:space:]]}"}"
    (( ${#ms} == ${#os} )) || return 1
    local tail_m="${ms##*echo }" ; local L=$(( ${#tail_m} + 5 ))
    (( L <= ${#ms} )) || return 1
    local em="${ms: -L}" eo="${os: -L}" c
    for (( i = 0; i < L; i++ )); do
        c="${em:i:1}"
        [[ "$c" == _ || "$c" == "${eo:i:1}" ]] || return 1
    done
    # eo is now `echo "<text>"<sep>cat F` in the original's own bytes
    [[ "$eo" =~ ^echo[[:space:]]+\"([^\"]*)\"[[:space:]]*[\;$'\n'][[:space:]]*cat[[:space:]]+([^[:space:]]+)$ ]] || return 1
    local text="${BASH_REMATCH[1]}"
    [[ "${BASH_REMATCH[2]}" == "$f" ]] || return 1
    [[ "$text" == *'$?'* ]] || return 1
    [[ "$text" == *'\'* || "$text" == *'`'* ]] && return 1
    local t2="${text//'$?'/}"; [[ "$t2" == *'$'* ]] && return 1
    local want="${text//'$?'/0}"
    # stdout's last two non-empty lines
    local line l1="" l2=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        l1="$l2"; l2="$line"
    done <<< "$out"
    [[ "$l1" == "$want" ]] || return 1
    [[ "$l2" =~ ^[[:space:]]*([0-9]+)(\;[^[:space:]]+)?[[:space:]]*$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# ---- THE ID A SUBSTITUTION CAPTURED, ECHOED BACK (your-org/nexus-code#1859 a) --
# `jid=$(sbatch --parsable job.sh)` sends sbatch's id into the VARIABLE, so
# stdout carries none, and the `$(…)` rule above rightly reads no bare number
# from such a call. When the call then PRINTS that variable as its last command
# (`; echo "$jid"`, `; printf '%s\n' "$jid"`), the id is on stdout again, and
# this function attributes it.
#
# WHY READ THE ECHO, NOT ASK SLURM AFTERWARDS. The alternative (resolving the
# `syn-` wait through `squeue -u`/`sacct --name`) puts a Slurm call on claude's
# PostToolUse hot path. In this sandbox every Slurm command goes through a
# shared chaperon that has jammed for 22 minutes on one held call, and
# `squeue -j` answers EMPTY for a queued job on ~25% of calls — so a resolver
# would wedge turns or confidently report "no such job". Reading what the call
# printed is hermetic: no process, no network, the same input every time.
#
# THE INVARIANT. No command in the call but the final echo can put a line on
# stdout. Then the only non-empty stdout line is that echo's, and it carries
# exactly the substitution's value. If sbatch failed, the value is empty (or
# its error text, which names `sbatch:` and is refused), and the expanded line
# holds no integer where the id goes. So:
#   * exactly ONE `sbatch` word and exactly ONE command substitution in the
#     call, no backtick, no `(`/`)` outside it, no `|`, no `||`, no lone `&`,
#     no loop or branch keyword;
#   * the substitution is a whole segment `VAR=$(sbatch …)` or
#     `VAR="$(sbatch …)"`, its body is ONE sbatch with `--parsable`, no wrapper,
#     and no separator, redirection or newline (`2>&1` would put its error text
#     in VAR; `| tail -1` would make it another command's output);
#   * VAR is assigned nowhere else and never expanded with a default
#     (`${VAR:=…}`) before the echo;
#   * every other segment, before or after the assignment, is one that prints
#     nothing, or never a bare integer (`_seg_is_quiet_after`: NOT `source`
#     or `module`, which can print anything);
#   * the echo is the LAST segment, joined by `;`, a newline or `&&` (`&&`
#     skips it when sbatch fails, which prints nothing at all), and is one of
#       echo "<lit>$VAR<lit>"   echo $VAR   printf '<lit>%s<lit>\n' "$VAR"
#     with `${VAR}` accepted for `$VAR`, and literal text holding no `$`, `%`,
#     backslash, backtick or quote, and not starting with `-`;
#   * stdout holds exactly ONE non-empty line, it is the echo's literal text
#     around a value, and that value is `<digits>` or `<digits>;<cluster>`.
# The echo's text is read from the ORIGINAL command by POSITION through the
# quote-masked scan view, exactly as `_parsable_sbatch_via_file` does, and is
# refused unless the two align. The caller adds the separated-stderr and
# `sbatch:`-text refusals. Prints the id, rc 0; rc 1 otherwise.
# DECLARED COST: `jid=$(sbatch …)` with NO echo, an `EX=$(…)` beside it, or
# `$(sbatch … 2>/dev/null)` still falls to the `syn-` wait and the NOT-ARMED
# notice — a loud miss, never a guessed id.
_ECHO_ASSIGN_ERE='(^|[[:space:];&])([A-Za-z_][A-Za-z0-9_]*)=("?)\$\(([^()]*)\)("?)'
_parsable_sbatch_via_echo() {   # <scan view> <original command> <stdout>
    local scan="$1" orig="$2" out="$3" ms os t
    ms="${scan%"${scan##*[![:space:]]}"}"; os="${orig%"${orig##*[![:space:]]}"}"
    (( ${#ms} == ${#os} )) || return 1
    [[ "$ms" == *'`'* ]] && return 1
    t="${ms//'$('/}"; (( ${#ms} - ${#t} == 2 )) || return 1
    local nsb=0 w
    for w in ${ms//[^A-Za-z0-9_]/ }; do [[ "$w" == sbatch ]] && nsb=$(( nsb + 1 )); done
    (( nsb == 1 )) || return 1
    [[ "$ms" =~ $_ECHO_ASSIGN_ERE ]] || return 1
    local whole="${BASH_REMATCH[0]}" lead="${BASH_REMATCH[1]}" var="${BASH_REMATCH[2]}" \
          q1="${BASH_REMATCH[3]}" body="${BASH_REMATCH[4]}" q2="${BASH_REMATCH[5]}"
    [[ "$q1" == "$q2" ]] || return 1
    [[ "$body" == *[\;\&\|\<\>]* || "$body" == *$'\n'* ]] && return 1
    _seg_word "$body"
    [[ "$_sw" == sbatch ]] && (( ! _swrap && ! _sctl )) || return 1
    [[ "$_sseg" =~ $_PARSABLE_FLAG_ERE ]] || return 1
    # the call with the substitution reduced to `VAR=_`
    local v="${ms/"$whole"/"${lead}${var}=_"}"
    [[ "$v" == *'('* || "$v" == *')'* || "$v" == *'||'* || "$v" == *'|'* ]] && return 1
    local norm; norm=$(_norm_redirs "$v"); norm="${norm//&&/ }"
    [[ "$norm" == *'&'* ]] && return 1
    [[ "$norm" =~ $_LOOP_KW_ERE ]] && return 1
    local seg sep a=-1 k=0 last="" lastsep=""
    while IFS= read -r seg || [[ -n "$seg" ]]; do
        sep=""
        case "$seg" in
            '&& '*|'|| '*|'; '*|'| '*) sep="${seg%% *}"; seg="${seg#* }" ;;
        esac
        [[ "$seg" =~ ^[[:space:]]*$ ]] && continue
        if [[ -n "$last" ]]; then
            # the PREVIOUS segment was not the last one: it must be quiet
            _seg_word "$last"
            (( _sctl )) && return 1
            if [[ "${last//[[:space:]]/}" == "${var}=_" ]]; then
                (( a < 0 )) || return 1; a=$k
            else
                _seg_is_quiet_after "$_sw" || return 1
            fi
            k=$(( k + 1 ))
        fi
        last="$seg"; lastsep="$sep"
    done < <(_split_segs_sep "$v")
    (( a >= 0 )) && [[ -n "$last" ]] || return 1
    [[ "$lastsep" == '' || "$lastsep" == ';' || "$lastsep" == '&&' ]] || return 1
    # recover the last segment from the ORIGINAL by position
    local pre="${ms%[;&$'\n']*}"
    [[ "$pre" != "$ms" ]] || return 1
    local p=$(( ${#pre} + 1 )) i c
    local em="${ms:p}" eo="${os:p}"
    for (( i = 0; i < ${#em}; i++ )); do
        c="${em:i:1}"
        [[ "$c" == _ || "$c" == "${eo:i:1}" ]] || return 1
    done
    eo="${eo#"${eo%%[![:space:]]*}"}"
    # VAR is assigned ONCE and never default-expanded (`${VAR:=7}`) before the
    # echo. Read from the ORIGINAL, where quoted text is not blanked. EVERY
    # assignment spelling counts, not only `VAR=` (ncbundle32-sk R2):
    # `export jid+=0` rode the quiet list and the read-back attributed the
    # appended `12345670`, a WRONG id where base armed `syn-`. So `VAR+=`,
    # `VAR[i]=` and `VAR[i]+=` are reassignments too. Other writers (`read`,
    # `printf -v`, `let`, `unset`, `declare`) are not on the quiet list, so their
    # segment already refuses the read-back.
    local head=" ${os:0:p}" cnt=0
    while [[ "$head" =~ [^A-Za-z0-9_]${var}(\[[^]]*\])?\+?=(.*)$ ]]; do
        cnt=$(( cnt + 1 )); head="${BASH_REMATCH[2]}"
    done
    (( cnt == 1 )) || return 1
    [[ "${os:0:p}" =~ \$\{${var}[^}] ]] && return 1
    local lit='[^"$%\\`'"'"']*' ref="(\\\$${var}|\\\$\\{${var}\\})" l1="" l2=""
    if [[ "$eo" =~ ^echo[[:space:]]+\"(${lit})${ref}(${lit})\"$ ]]; then
        l1="${BASH_REMATCH[1]}"; l2="${BASH_REMATCH[3]}"
        [[ "${BASH_REMATCH[2]}" == '${'* || "$l2" != [A-Za-z0-9_]* ]] || return 1
    elif [[ "$eo" =~ ^echo[[:space:]]+${ref}$ ]]; then
        :
    elif [[ "$eo" =~ ^printf[[:space:]]+([\'\"])(${lit})%s(${lit})\\n([\'\"])[[:space:]]+(\"?)${ref}(\"?)$ ]]; then
        [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[4]}" && "${BASH_REMATCH[5]}" == "${BASH_REMATCH[7]}" ]] || return 1
        l1="${BASH_REMATCH[2]}"; l2="${BASH_REMATCH[3]}"
    else
        return 1
    fi
    [[ "$l1" == -* ]] && return 1
    # stdout: exactly one non-empty line, `<l1><id><l2>`
    local line got="" n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        n=$(( n + 1 )); got="$line"
    done <<< "$out"
    (( n == 1 )) || return 1
    got="${got%"${got##*[![:space:]]}"}"; l2="${l2%"${l2##*[![:space:]]}"}"
    [[ "$got" == "$l1"* ]] || return 1
    got="${got#"$l1"}"
    if [[ -n "$l2" ]]; then
        [[ "$got" == *"$l2" ]] || return 1
        got="${got%"$l2"}"
    fi
    [[ "$got" =~ ^([0-9]+)(\;[^[:space:]]+)?$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# _slurm_id_ok <id> — the job-id predicate from the PROBE file, loaded lazily
# (only a Slurm row ever asks) from this hook's own tree, so it holds without
# NEXUS_ROOT. If the file cannot be loaded every id is REFUSED: the failure
# direction is a `syn-` wait plus a loud notice, never an unvalidated watch.
_slurm_pred=""   # "" = not loaded yet, 1 = loaded, 0 = unavailable
_slurm_id_ok() {
    if [[ -z "$_slurm_pred" ]]; then
        _slurm_pred=0
        local _hd
        _hd=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _hd=""
        # shellcheck disable=SC1090,SC1091
        if [[ -n "$_hd" ]] && . "$_hd/../longjob-probes.d/slurm.sh" >/dev/null 2>&1 \
            && declare -F lj_slurm_jobid_valid >/dev/null 2>&1; then
            _slurm_pred=1
        fi
    fi
    [[ "$_slurm_pred" == 1 ]] && lj_slurm_jobid_valid "$1"
}

# THE FIELD SEPARATOR IS NOT A LIMIT ON THE REGEX LANGUAGE
# (your-org/nexus-code#1269). `|` is this file format's field separator, so a
# row carrying a literal `|` is SHREDDED by the split below: `cmd_re` becomes a
# fragment, the row matches nothing, and a detector row is silently disabled.
# That is a real hazard and the conf's parse assertion still forbids a literal
# `|` — but it was also being read as "this detector cannot express `|`", which
# is a different and false claim. It cost the `after ||` and `after a pipe`
# launch positions, and it forced one row per alternation branch everywhere
# else, which is what kept the row count near the hot-path budget.
#
# `\x7c` is decoded to a literal `|` AFTER the split. POSIX ERE has no `\x`
# escape, so the token cannot collide with anything a row could legitimately
# mean, and the row still carries no literal `|` — the parse assertion is
# unaffected. Both a `|` MATCHED AS A CHARACTER (a pipeline separator) and a
# `|` MEANING ALTERNATION are now expressible.
_ESC_PIPE='\x7c'
while IFS='|' read -r kind cmd_re id_re desc; do
    # Skip blank and comment lines.
    [[ -z "${kind// /}" ]] && continue
    case "$kind" in
        '#'*) continue ;;
    esac
    cmd_re=${cmd_re//"$_ESC_PIPE"/|}
    id_re=${id_re//"$_ESC_PIPE"/|}
    desc=${desc//"$_ESC_PIPE"/|}
    [[ -n "$cmd_re" ]] || continue
    # Match command. Bash =~ uses POSIX ERE.
    #
    # PER LINE, not per string (your-org/nexus-code#948). Bash's `=~`
    # anchors `^` to the whole subject, so a position-anchored row is
    # BLIND to a launch on line 2 of a multi-line command:
    #
    #     cd /tmp\nsrun --no-block ./j.sh   →  [[ =~ ]] no match
    #                                          grep -E   MATCH on line 2
    #
    # Multi-line `Bash` tool calls are a routine agent shape, so that
    # blind spot covers a large share of real launches. Testing each
    # LINE recovers them with no change to any pattern — the defect was
    # never in the regexes. Found because a third matcher (`grep -E`,
    # a different engine with line semantics) DISAGREED with the two
    # that shared bash's; agreement between two matchers that share an
    # engine cannot surface this.
    _line_hit=0
    while IFS= read -r _cmd_line || [[ -n "$_cmd_line" ]]; do
        if [[ "$_cmd_line" =~ $cmd_re ]]; then _line_hit=1; break; fi
    done <<< "$command_scan"
    if (( _line_hit )); then
        # A dry run (`--test-only`, `--help`, `--usage`, `--version`) creates
        # no job, so it arms NOTHING: no wait, no watch, no notice (#1854 a).
        if [[ "$kind" == slurm ]] && _sbatch_call_is_dry_only "$command_scan"; then
            exit 0
        fi
        matched_kind="$kind"
        matched_desc="$desc"
        # Extract id from stdout if id_regex was provided. The
        # first capture group is the id. Otherwise synthesize a
        # short stable id from sha1(command_str)[0:12] so dismissal
        # by (kind, id) remains feasible.
        # PER LINE here too, and for a second reason beyond the one above:
        # bash's `=~` yields only the FIRST match of a whole-string subject, so
        # even an explicit loop over `BASH_REMATCH` cannot reach ids 2..N. Each
        # `Submitted batch job <id>` is on its own line, so testing lines is
        # what makes them all reachable.
        #
        # A BARE-NUMBER ID ROW INSIDE `$(…)` READS NOTHING
        # (your-org/nexus-code#1727). The `--parsable` rows' id field accepts
        # ANY stdout line that is just an integer. When the matched `sbatch`
        # sits inside a command substitution, its stdout went into the
        # VARIABLE, so every bare integer the tool call printed came from
        # something else — `jid=$(sbatch --parsable j.sh); echo $?` prints `0`,
        # and that `0` became a job id. "Is this row's id field a bare-number
        # shape?" is asked of the row itself (does it match `12345`?), so no
        # row is named here. `jid=$(sbatch --parsable …); echo "$jid"` prints
        # the REAL id, and since #1859 it is read back by POSITION
        # (`_parsable_sbatch_via_echo`); every other substituted shape falls to
        # the `syn-` wait and the NOT-ARMED notice below, which names the one
        # command that arms it. A wrong id is strictly worse: `sacct` answers
        # about ANOTHER job.
        _id_distrust=0; _id_via_file=""
        if [[ -n "$id_re" ]] && [[ "12345" =~ $id_re ]]; then
            if [[ "$command_scan" =~ $_CMDSUBST_SBATCH_ERE ]]; then
                _id_distrust=1
                # …unless the call echoes the captured variable as its last
                # and only printing command (#1859 a). `_id_via_file` holds
                # the ONE line chosen, whichever path chose it.
                if [[ -z "$stderr_str" ]] \
                    && [[ "$stdout_str" != *'sbatch:'* && "$stdout_str" != *'found: sbatch'* ]] \
                    && _id_via_file=$(_parsable_sbatch_via_echo "$command_scan" "$command_str" "$stdout_str") \
                    && [[ -n "$_id_via_file" ]]; then
                    _id_distrust=0
                fi
            elif ! _parsable_call_is_sbatch_only "$command_scan"; then
                _id_distrust=2
                # Other commands ran too — but if sbatch provably printed
                # FIRST, its line is stdout's first non-empty one (#1832).
                if [[ -z "$stderr_str" ]] \
                    && [[ "$stdout_str" != *'sbatch:'* && "$stdout_str" != *'found: sbatch'* ]] \
                    && _parsable_sbatch_spoke_first "$command_scan"; then
                    _id_distrust=0; _id_first_only=1
                # …or sbatch wrote its id to a file the call then `cat`s, with
                # an `rc=0` echo in between proving it ran (#1854 b).
                elif _id_via_file=$(_parsable_sbatch_via_file "$command_scan" "$command_str" "$stdout_str") \
                    && [[ -n "$_id_via_file" ]]; then
                    _id_distrust=0
                fi
            fi
        fi
        if [[ -n "$id_re" ]] && [[ -n "$stdout_str" ]] && (( _id_distrust == 0 )); then
            _seen_line=0
            # The via-file path has already chosen the ONE line that is
            # sbatch's; read only that, so no other integer can join it.
            _id_src="$stdout_str"
            [[ -n "$_id_via_file" ]] && _id_src="$_id_via_file"
            while IFS= read -r _out_line || [[ -n "$_out_line" ]]; do
                if (( _id_first_only )); then
                    [[ "$_out_line" =~ ^[[:space:]]*$ ]] && continue
                    (( _seen_line )) && break
                    _seen_line=1
                fi
                if [[ "$_out_line" =~ $id_re ]]; then
                    _cand="${BASH_REMATCH[1]}"
                    # A Slurm row's id must be a Slurm job id — the ONE shape,
                    # shared with the probe and `longjob-watch.sh add`
                    # (your-org/nexus-code#1727). A rejected id is not recorded
                    # as a wait either: the orphan-async resolver would ask
                    # `sacct` about it just as the watch did.
                    case "$kind" in
                        slurm|slurm-srun-async)
                            if ! _slurm_id_ok "$_cand"; then
                                _rejected_ids+=("$_cand"); continue
                            fi ;;
                    esac
                    matched_ids+=("$_cand")
                fi
            done <<< "$_id_src"
        fi
        if (( ${#matched_ids[@]} == 0 )); then
            # No id in stdout — a `nohup … &`, or a launcher whose success line
            # this row cannot parse. Synthesize a stable id from the command so
            # `declare-no-wait.sh <kind> <id>` still has something to key on.
            # It is deliberately PREFIXED `syn-`, and that prefix is now load
            # bearing rather than cosmetic: the wake loop's resolver checks it
            # FIRST and reports `unresolvable` — "the launcher retained no
            # handle" — instead of rounding an unlookuppable id to "finished".
            local_syn=""
            if command -v sha1sum >/dev/null 2>&1; then
                local_syn=$(printf '%s' "$command_str" \
                    | sha1sum 2>/dev/null | cut -c1-12)
            fi
            [[ -n "$local_syn" ]] || local_syn="$(date +%s)"
            matched_ids=("syn-${local_syn}")
        fi
        break
    fi
done < "$pattern_file"

# No match → no work. Fast path for the common case of a
# non-launching Bash call (cd, ls, grep, …).
[[ -n "$matched_kind" ]] || exit 0
(( ${#matched_ids[@]} > 0 )) || exit 0

# Read existing heartbeat once, then check dismissed_waits BEFORE
# mutating. Saves a write when (kind, id) was already dismissed.
existing=$(read_existing)

if [[ "$existing" == '{}' ]]; then
    now=$(date +%s)
    existing=$(jq -nc \
        --arg window "$window" \
        --argjson now "$now" \
        '{window: $window, last_activity: $now, external_waits: [], dismissed_waits: []}')
fi

# Idempotent insert, one entry PER ID: drop any prior row with the same
# (kind, id), then append. Workers often re-submit the same job during a
# retry; we want the latest desc and a single entry, not a stack of
# duplicates. A (kind, id) already in `dismissed_waits` is skipped — the
# worker declared it fire-and-forget — and skipping is PER ID, so dismissing
# one job of a grid does not dismiss the other fourteen.
ids_json=$(printf '%s\n' "${matched_ids[@]}" | jq -Rc '[., inputs]' 2>/dev/null) \
    || ids_json=$(printf '%s\n' "${matched_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))') \
    || exit 0
[[ -n "$ids_json" ]] || exit 0

updated=$(printf '%s' "$existing" | jq -c \
    --arg k "$matched_kind" \
    --arg d "$matched_desc" \
    --arg l "$launcher" \
    --argjson ids "$ids_json" \
    '. as $hb
     | ($ids | map(select(. as $i | ($hb.dismissed_waits // [])
                                    | map(select(.kind == $k and .id == $i)) | length == 0)))
       as $fresh
     | .external_waits = (
        ((.external_waits // []) | map(select(.kind != $k or (.id as $x | $fresh | index($x) | not))))
        + ($fresh | map({kind: $k, id: ., desc: $d} + (if $l == "" then {} else {launcher: $l} end)))
    )') || exit 0

tmp="$hb_file.$$.tmp"
printf '%s\n' "$updated" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
mv -f "$tmp" "$hb_file" 2>/dev/null || rm -f "$tmp"

# ---- auto-arm a longjob-watch for every detected Slurm launch (#1535) -------
# The wake nobody remembers to arm is no wake, so a detected `sbatch` /
# `srun --no-block` gets a watch WITHOUT a second command: the dispatcher
# (monitor/longjob-watch.sh) then delivers ONE task notification when the job
# reaches any terminal state. Gated by monitor.longjob.auto_watch_launches
# (env MONITOR_LONGJOB_AUTO_WATCH, default true) — its own knob. A job the
# worker dismissed via declare-no-wait.sh is not in $fresh and gets no watch.
# `--no-declare`: this hook already declared the `slurm <id>` wait above, and
# the dispatcher removes that entry when the watch retires. `--no-first-probe`:
# this is claude's PostToolUse hot path; no synchronous `sacct` here.
#
# NEVER SILENT WHEN NOTHING WAS ARMED (your-org/nexus-code#1727). This section
# used to discard every failure (`>/dev/null 2>&1 || true`) and say nothing
# when no id was parsed at all, so `jid=$(sbatch --parsable …)` — the most
# common submission idiom there is — left the worker believing the job was
# watched while nothing was. Whenever a Slurm launch matched and a REAL watch
# was not armed for it (no id in the output, an id the predicate refused, a
# bare-number id distrusted inside `$(…)`, or `add` returning non-zero —
# which includes add's own `dispatcher: NOT ARMED` rc 3), the hook prints ONE
# PostToolUse `additionalContext` naming why and the command that arms it — the
# same JSON form bash-footgun-guard.sh uses. It never blocks the call: rc is
# always 0, and the ARMED case prints nothing. A DISMISSED id stays silent: the
# worker said so on purpose.
_lj_auto="${MONITOR_LONGJOB_AUTO_WATCH:-}"
if [[ -z "$_lj_auto" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
    _lj_auto=$("$NEXUS_ROOT/config/load.sh" monitor.longjob.auto_watch_launches true 2>/dev/null) || _lj_auto=true
fi
case "${_lj_auto:-true}" in 1|true|yes|on) ;; *) exit 0 ;; esac
case "$matched_kind" in
    slurm|slurm-srun-async) ;;
    *) exit 0 ;;
esac
_na=()   # one reason per launch that got NO real watch
_grp_why=(); _grp_ids=()
_na_group() {   # <reason> <id> — file <id> under <reason>, one entry per distinct reason
    local i
    for i in "${!_grp_why[@]}"; do
        if [[ "${_grp_why[i]}" == "$1" ]]; then _grp_ids[i]+="$2 "; return 0; fi
    done
    _grp_why+=("$1"); _grp_ids+=("$2 ")
}
_fresh_ids=$(printf '%s' "$updated" | jq -r --arg k "$matched_kind" '.external_waits[] | select(.kind == $k) | .id' 2>/dev/null) || _fresh_ids=""
_lj="${NEXUS_ROOT:-}/monitor/longjob-watch.sh"
_lj_ok=1
[[ -n "${NEXUS_ROOT:-}" && -x "$_lj" ]] || _lj_ok=0
# The SESSION KEY comes from the PAYLOAD's `session_id` — the field claude
# itself supplies to every hook — not from this process's env. A suite that
# exported CLAUDE_CODE_SESSION_ID itself could only prove the key it supplied
# (skeptic, refuting its own attack: the hook env carries it too, via the
# host's child-env builder, but the payload is the documented one).
_lj_sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || _lj_sid=""
if (( ${#_rejected_ids[@]} > 0 )); then
    _na+=("refused job id(s) $(printf '%s ' "${_rejected_ids[@]}")— not a Slurm job id (job id 0 does not exist; 'sacct -j 0' answers about OTHER jobs)")
fi
for _jid in "${matched_ids[@]}"; do
    # Only THIS launch's ids that are still waits: a dismissed one is skipped,
    # silently and on purpose.
    grep -qxF -- "$_jid" <<<"$_fresh_ids" || continue
    if [[ "$_jid" == syn-* ]]; then
        if (( _id_distrust == 1 )); then
            _na+=("the sbatch ran inside \$(…) or backticks, so its stdout went into the variable and no bare number in this output can be trusted as its job id (end the call with: echo \"\$VAR\" — e.g. jid=\$(sbatch --parsable job.sh); echo \"\$jid\" — and this hook reads the id back)")
        elif (( _id_distrust == 2 )); then
            _na+=("this call ran other commands beside sbatch --parsable, so a bare number in its output may not be the job id (e.g. a grep -c count)")
        elif (( ${#_rejected_ids[@]} > 0 )); then
            :   # the refused id(s) above are the reason; saying "none read" too would contradict it
        else
            _na+=("no job id could be read from this call's output")
        fi
        continue
    fi
    if ! _slurm_id_ok "$_jid"; then
        _na+=("'$_jid' is not a Slurm job id (or the job-id predicate could not be loaded)")
        continue
    fi
    if (( _lj_ok == 0 )); then
        _na_group "monitor/longjob-watch.sh not found (NEXUS_ROOT unset or not executable), so nothing can watch it" "$_jid"
        continue
    fi
    _add_out=$(NEXUS_STATE_DIR="$state_dir" NEXUS_WORKER_WINDOW="$window" NEXUS_LONGJOB_SESSION_ID="$_lj_sid" \
        "$_lj" add "slurm:$_jid" --id "auto-slurm-$_jid" --desc "${matched_desc:-sbatch} (auto-watched by async-launch-detect)" \
        --no-declare --no-first-probe 2>&1 </dev/null)
    _add_rc=$?
    if (( _add_rc != 0 )); then
        # A re-submission of the SAME id (a retry) finds its watch already
        # recorded: that watch exists, so this call armed nothing NEW and
        # lost nothing either. Every other refusal is reported.
        [[ "$_add_out" == *"watch auto-slurm-$_jid already exists"* ]] && continue
        # add's own verdict line, else its last line (a `die` message).
        _why=$(printf '%s\n' "$_add_out" | grep -m1 -E '^dispatcher:|^longjob-watch:' 2>/dev/null) || _why=""
        [[ -n "$_why" ]] || _why=$(printf '%s\n' "$_add_out" | tail -n 1)
        _na_group "'longjob-watch.sh add' rc=$_add_rc: ${_why:0:300}" "$_jid"
    fi
done
# Ids sharing one reason are named ONCE with that reason — a 15-job grid under
# an unarmed dispatcher is one sentence, not fifteen copies of it.
for _gi in "${!_grp_why[@]}"; do
    _na+=("job(s) ${_grp_ids[_gi]% }: ${_grp_why[_gi]}")
done
if (( ${#_na[@]} > 0 )); then
    _msg="longjob NOT ARMED for this Slurm submission (your-org/nexus-code#1727) — no watch will wake you when it ends: $(printf '%s; ' "${_na[@]}")"
    _msg+="for each job, run: ng longjob add slurm:<id> (the REAL id — sbatch's output or squeue --me), and check it says ARMED; if add itself says NOT ARMED, use the fallback it prints."
    jq -nc --arg m "${_msg:0:4000}" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$m}}' \
        2>/dev/null || true
fi
exit 0
