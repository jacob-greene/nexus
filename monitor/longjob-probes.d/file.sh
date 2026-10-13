# shellcheck shell=bash
# monitor/longjob-probes.d/file.sh — longjob-watch subject probe: a file
# predicate. Contract: see slurm.sh.
#
# Target: a path. The predicate lives in the spec (`add file:<path> --when …`):
#
#   exists          done once the path exists (default)
#   grew            done once the file's size exceeds `.size0`, the size
#                   recorded at add time (0 when it did not exist yet)
#   match           done once `grep -E -- <pattern>` matches a line written
#                   AFTER the add (`.lines0`; see the failure arm below); the
#                   pattern is `.pattern` in the spec. A pattern that is a
#                   valid regex but matches nothing is `running`, forever,
#                   bounded only by the watch TTL — say what you mean.
#
# A SUCCESS-ONLY WAIT NEVER WAKES ON AN ABORT (your-org/nexus-code bundle 21).
# Measured 2026-10-08: an agent waited for a deploy's version-stamp line; the
# deploy ABORTed on its lock instead, twice, and the agent slept ~2 h until the
# orchestrator noticed. So `match` carries a FAILURE ARM, `.fail_pattern`:
# a line matching it is `failed`, if it comes BEFORE the first success line.
# `add --when match` writes LJ_FILE_FAIL_DEFAULT below unless told otherwise
# (`--fail-pattern <ERE>` replaces it, `--fail-pattern none` drops it). The
# default is deliberately broad: a spurious failure costs ONE wake and a
# re-arm, a missed one costs the whole wait — the same direction as the slurm
# probe's default arm. Only lines written AFTER `add` count toward failure
# (`.lines0`, the line count at add time), so an old ABORT in an append-only
# log cannot fire on the first probe; a file that SHRANK (rotated, truncated)
# is read from line 1. A spec with no `.fail_pattern` key (written before this
# arm existed) has no failure arm — it is never given one retroactively.
#
# A file predicate has no failure state of its own: the thing that fails is
# the producer, which is a different subject. So `failed` is reserved for a
# predicate that cannot be evaluated (unreadable directory, bad regex), and
# an absent file under `grew`/`match` is `pending`, not `unknown` — absence
# IS the answer for a file, unlike for a job.

# The default failure arm (ERE, case-SENSITIVE), chosen here, not an upstream
# convention — replace it per watch with --fail-pattern:
#   * a word starting `ABORT` (ABORT, ABORTED, ABORTing — the measured deploy
#     wrote "ABORT"), and bash's `Aborted` / `Segmentation fault`;
#   * FATAL, ERROR, FAILED or Python's `Traceback` as WHOLE upper-case words
#     (so `ERRORS: 0` and `0 failed` do not fire);
#   * Slurm's own abort shapes: CANCELLED (`*** JOB … CANCELLED AT … DUE TO
#     TIME LIMIT ***`), OUT_OF_MEMORY and `oom-kill`/`oom_kill` (current Slurm
#     writes the underscore; skeptic N1 on PR #1786), and bash's `Killed` for a
#     SIGKILLed child (`line 3:  4242 Killed  python x.py`, the OOM shape) —
#     skeptic F3 on PR #1784 measured all of these staying `running`;
#   * a lower-case `error:` / `fatal:` diagnostic prefix (git, Slurm, most CLIs).
# A `set -x` TRACE line (`+ grep -q ERROR log`, `++ …` when nested) never
# counts toward ANY failure arm: it prints the command, not its outcome, and
# the skeptic measured the default firing on one. Chosen: a line starting with
# one or more `+` and a space, bash's default PS4.
LJ_FILE_FAIL_DEFAULT='(^|[^[:alnum:]_])(ABORT[[:alpha:]]*|Aborted|Segmentation fault|FATAL|ERROR|FAILED|Traceback|CANCELLED|OUT_OF_MEMORY|oom[-_]kill|Killed)([^[:alnum:]_]|$)|(^|[[:space:]])(error|fatal):'

_lj_file_cut() { local t="$1"; printf '%s' "${t:0:120}"; }

lj_probe_main() {
    local target="$1" spec="$2" when pattern size0 size
    when=$(printf '%s' "$spec" | jq -r '.when // "exists"' 2>/dev/null) || when=exists
    case "$when" in
        exists)
            if [[ -e "$target" ]]; then printf 'done|%s exists' "$target"
            else printf 'pending|%s absent' "$target"; fi ;;
        grew)
            size0=$(printf '%s' "$spec" | jq -r '.size0 // 0' 2>/dev/null) || size0=0
            [[ "$size0" =~ ^[0-9]+$ ]] || size0=0
            if [[ ! -e "$target" ]]; then printf 'pending|%s absent (size0=%s)' "$target" "$size0"; return 0; fi
            size=$(stat -c %s -- "$target" 2>/dev/null) || { printf 'failed|cannot stat %s' "$target"; return 0; }
            if (( size > size0 )); then printf 'done|%s grew %s → %s bytes' "$target" "$size0" "$size"
            else printf 'running|%s at %s bytes (waiting for > %s)' "$target" "$size" "$size0"; fi ;;
        match)
            pattern=$(printf '%s' "$spec" | jq -r '.pattern // empty' 2>/dev/null) || pattern=""
            [[ -n "$pattern" ]] || { printf 'failed|no pattern in spec for --when match'; return 0; }
            if [[ ! -e "$target" ]]; then printf 'pending|%s absent' "$target"; return 0; fi
            local hit rc fail lines0 fhit frc fline sline
            # BOTH arms count only lines written AFTER the add (`.lines0`, the
            # line count `add` recorded). The failure arm got this in bundle
            # 21; the SUCCESS arm did not (your-org/nexus-code bundle 23), so
            # an OLD success line already in an append-only log read `done` on
            # the FIRST probe — a false wake, at rc 0, that looks exactly like
            # the real one. A file with FEWER lines than at add time was
            # rotated or truncated: everything in it is new. A spec with no
            # `.lines0` (a one-shot `probe`, whose --lines0 defaults to 0, or a
            # spec written before add recorded it for every match) reads the
            # whole file, as before.
            lines0=$(printf '%s' "$spec" | jq -r '.lines0 // 0' 2>/dev/null) || lines0=0
            [[ "$lines0" =~ ^[0-9]+$ ]] || lines0=0
            (( lines0 > 0 )) && (( $(wc -l < "$target" 2>/dev/null || echo 0) < lines0 )) && lines0=0
            # The SUCCESS arm skips `set -x` trace lines too (skeptic N2 on PR
            # #1786): `+ [[ $st == COMPLETED ]]` prints the test, not its
            # outcome, and used to read `done` early. Same carry-through as the
            # failure arm below: a bad pattern (the second stage's rc 2) stays
            # rc 2, and pipefail is OFF for the same SIGPIPE reason.
            hit=$(set +o pipefail; tail -n "+$(( lines0 + 1 ))" -- "$target" 2>/dev/null \
                  | grep -n -E -- "$pattern" 2>/dev/null | grep -v -E -m1 -- '^[0-9]+:[+]+ ' 2>/dev/null
                  _ps=("${PIPESTATUS[@]}"); (( _ps[1] == 2 )) && exit 2; exit "${_ps[2]}"); rc=$?
            case "$rc" in 0|1) ;; *) printf 'failed|grep rc=%s on %s (bad pattern or unreadable file)' "$rc" "$target"; return 0 ;; esac
            # `hit` is N:text with N relative to line lines0+1; make it absolute.
            (( rc == 0 )) && hit="$(( ${hit%%:*} + lines0 )):${hit#*:}"
            fail=$(printf '%s' "$spec" | jq -r '.fail_pattern // empty' 2>/dev/null) || fail=""
            if [[ -n "$fail" ]]; then
                # pipefail OFF in the substitution: `grep -m1` exits at its
                # first hit and `tail` then dies of SIGPIPE, which under the
                # dispatcher's pipefail would replace grep's 0 with 141.
                # The second grep drops xtrace lines (`N:+ …`) and keeps the
                # first survivor. Its rc is the answer, EXCEPT that a bad
                # pattern (the first grep's rc 2) must stay rc 2 rather than
                # read as "no match"; the first grep's SIGPIPE (141) is normal.
                fhit=$(set +o pipefail; tail -n "+$(( lines0 + 1 ))" -- "$target" 2>/dev/null \
                       | grep -n -E -- "$fail" 2>/dev/null | grep -v -E -m1 -- '^[0-9]+:[+]+ ' 2>/dev/null
                       _ps=("${PIPESTATUS[@]}"); (( _ps[1] == 2 )) && exit 2; exit "${_ps[2]}"); frc=$?
                case "$frc" in
                    0) fline=$(( ${fhit%%:*} + lines0 ))
                       sline=${hit%%:*}
                       if (( rc != 0 )) || (( fline < sline )); then
                           printf 'failed|%s matched the FAILURE arm /%s/ at line %s, before any success line /%s/: %s' \
                               "$target" "$fail" "$fline" "$pattern" "$(_lj_file_cut "${fhit#*:}")"
                           # First in file order decides, but a LATER success
                           # line is SAID, never hidden (skeptic F2 on PR #1784).
                           (( rc == 0 )) && printf ' (a success line ALSO appears later, at line %s: %s — read the file before treating this as a failure)' \
                               "$sline" "$(_lj_file_cut "${hit#*:}")"
                           printf ' (benign? re-add with --fail-pattern <narrower ERE>, or --fail-pattern none)'
                           return 0
                       fi ;;
                    1) ;;
                    *) printf 'failed|grep rc=%s evaluating the failure arm /%s/ on %s (bad pattern or unreadable file)' "$frc" "$fail" "$target"; return 0 ;;
                esac
            fi
            case "$rc" in
                0) printf 'done|%s matched /%s/: %s' "$target" "$pattern" "$(_lj_file_cut "${hit#*:}")" ;;
                *) # A success line written BEFORE the add is not counted (above),
                   # but it must never be SILENT (skeptic F1 on your-org/nexus-code
                   # #1799): a job that finished before the agent added the watch
                   # would otherwise wait out the TTL with a detail saying "no line
                   # matching". So name the newest pre-add match, with the remedy.
                   local pre=""
                   if (( lines0 > 0 )); then
                       pre=$(set +o pipefail; head -n "$lines0" -- "$target" 2>/dev/null \
                             | grep -n -E -- "$pattern" 2>/dev/null | grep -v -E -- '^[0-9]+:[+]+ ' 2>/dev/null | tail -n 1)
                   fi
                   if [[ -n "$pre" ]]; then
                       # The marker LEADS: _probe cuts a detail at 400 chars, and
                       # `add` keys its WARNING on it, so a long path must not push
                       # it past the cut.
                       printf 'running|PRE-ADD MATCH at line %s (written BEFORE the add, NOT counted): %s — %s has no line matching /%s/ written since add. If that is THIS job finishing, it is already DONE: act on it, then remove the watch (ng longjob rm <id>)%s' \
                           "${pre%%:*}" "$(_lj_file_cut "${pre#*:}")" "$target" "$pattern" "${fail:+ (no failure-arm line since add either)}"
                   else
                       printf 'running|%s has no line matching /%s/ yet%s' "$target" "$pattern" "${fail:+ (and none matching the failure arm since add)}"
                   fi ;;
            esac ;;
        *)  printf 'failed|unknown file predicate %s' "$when" ;;
    esac
    return 0
}
