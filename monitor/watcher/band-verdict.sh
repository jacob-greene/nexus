#!/usr/bin/env bash
# band-verdict.sh — is this run-tests.sh LOG a verdict, and if so which?
# (your-org/nexus-code#1474, the local form.)
#
# THE END MARKER HAD A PRODUCER AND NO READER. Since #1558 a run that reaches its
# own verdict prints `=== run-tests: END rc=N (…) ===` as its LAST line, and the
# header says a log without it "was KILLED or is still going, and the PASS lines
# are a SUBSET". Measured at d58bc49a: nothing outside the runner's own suites
# consumed that marker — the protocol was enforced by the reader's discipline,
# and the reader of a band log is an agent who greps PASS and FAIL rows. #1474's
# measured local instance is exactly what that reads wrongly: a runner TERMed at
# `--jobs 4` whose orphaned children kept appending PASS rows to the dead
# runner's log — 6 of 6 PASS, 0 FAIL, no summary. CI's form of it (a CANCELLED
# band rendering as `fail`) has `monitor/ci-band-coverage.sh`; that tool keys on
# GitHub's `Post job cleanup.` line and a job conclusion, and GitHub Actions
# starts no job on this repo. This is the local equivalent.
#
# Usage:
#   monitor/watcher/band-verdict.sh <log-file>
#
# Output: ONE machine-readable line on stdout, detail after it:
#   verdict=<green|red|none> class=<…> end_rc=<N|none> selected=<N> reported=<R> \
#       pass=<n> fail=<n> timeout=<n> skip=<n> envskip=<n>
#     class  complete          the END marker is the last runner line, rc 0 or 1
#            no-end-marker     no END marker: KILLED (SIGKILL, a wall-clock kill,
#                              a lost node) or STILL RUNNING. Rows are a SUBSET.
#            rows-after-end    a verdict row FOLLOWS the END marker: dispatch
#                              children outlived the runner (#1474's orphans)
#            incomplete        END rc=3, a budget stop — resume, do not read
#            signalled         END rc=4
#            tree-changed      END rc=5 — the result describes no single tree
#            aborted           any other END rc, or the runner's own
#                              `STOPPED WITHOUT REACHING A VERDICT` line
#            rows-mismatch     the marker says COMPLETE and the row count is
#                              not the selected count — REFUSED (exit 2)
#            marker-rows-contradiction
#                              the marker says rc=0 (green) while a FAIL or
#                              TIMEOUT row is present — REFUSED (exit 2). No
#                              runner in this tree can emit that pair.
#
# Exit codes — 4 and 2 are NOT answers about the tree:
#   0  VERDICT green    1  VERDICT red
#   4  NOT A VERDICT (every class but `complete`)
#   2  REFUSED — could not look: unreadable or empty file, no `=== running N
#      tests` header (not a run-tests log), more than one run in the file, or
#      the row count disagrees with the header under a `complete` marker
#   3  usage
#
# A RED BY TIME IS NAMED APART FROM A RED BY ASSERTION. A TIMEOUT row is "no
# verdict about that suite"; both are rc 1 to every caller, and only the second
# sends anyone into the code. The two lists are printed separately.
#
# ERROR DIRECTION, because this is a predicate over TEXT. It reads rows shaped
# `^  (PASS|FAIL|SKIP|ENVSKIP|TIMEOUT)  <name>`; a suite that ECHOES such a line
# at column 2 into the band log would be over-counted — the runner prints suite
# output only inside a red block, indented four columns, so that is not the
# shape — and an over-count under a `complete` marker is a REFUSAL (rows !=
# selected), never a silent pass. `--state`/`--resume` sweeps report rows for
# one invocation against a header for the same invocation, so they reconcile;
# a log holding several invocations is refused rather than summed.
#
# AND THE ROWS ARE READ AGAINST THE MARKER, NOT MERELY COUNTED. The paragraph
# above reasons about a row SHAPE being over-counted; the other direction is a
# row that IS counted and that the verdict arm then ignores. A green marker
# beside a FAIL or TIMEOUT row is refused for that reason (`marker-rows-
# contradiction`), because the failure mode of a reader is not only miscounting
# — it is counting correctly and then not consulting the count.
#
# Reads only. Every extraction is a full pass over the file (no `head`).

set -uo pipefail

_usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 3; }
(( $# == 1 )) || _usage
case "$1" in -h|--help) _usage ;; esac
log="$1"

[[ -f "$log" && -r "$log" ]] || { printf 'band-verdict.sh: REFUSED — cannot read %s\n' "$log" >&2; exit 2; }
[[ -s "$log" ]] || { printf 'band-verdict.sh: REFUSED — %s is EMPTY (a log still buffered, or a run that never started — neither is a verdict)\n' "$log" >&2; exit 2; }

n_headers=$(grep -acE '^=== running [0-9]+ tests? \(' -- "$log" || true)
if [[ "$n_headers" != 1 ]]; then
    printf 'band-verdict.sh: REFUSED — %s holds %s `=== running N tests` header(s); want exactly 1 (not a run-tests log, or several runs in one file)\n' \
        "$log" "$n_headers" >&2
    exit 2
fi
selected=$(sed -n 's/^=== running \([0-9][0-9]*\) tests\{0,1\} (.*/\1/p' -- "$log" | sed -n 1p)
[[ "$selected" =~ ^[0-9]+$ ]] || { printf 'band-verdict.sh: REFUSED — could not read the selected count from the header\n' >&2; exit 2; }

# One pass: row tallies, the LAST END marker's line number and rc, the last
# row's line number, and whether the runner said it stopped without a verdict.
read -r n_pass n_fail n_timeout n_skip n_envskip end_line end_rc last_row stopped < <(
    awk '
        /^  PASS  /    { p++;  lr = NR }
        /^  FAIL  /    { f++;  lr = NR }
        /^  TIMEOUT  / { t++;  lr = NR }
        /^  SKIP  /    { s++;  lr = NR }
        /^  ENVSKIP  / { e++;  lr = NR }
        /^=== run-tests: END rc=[0-9]+ \(/ {
            el = NR; rc = $0; sub(/^=== run-tests: END rc=/, "", rc); sub(/ .*/, "", rc)
        }
        /^=== run-tests: STOPPED WITHOUT REACHING A VERDICT/ { st = 1 }
        END { printf "%d %d %d %d %d %d %s %d %d\n", p, f, t, s, e, el, (rc == "" ? "none" : rc), lr, st }
    ' "$log"
)
# THE PRODUCER'S STATUS IS NOT ON THIS PATH: `< <(awk …)` discards it, so a
# failed awk would leave these EMPTY and every number below would be arithmetic
# on nothing. Validate the SHAPE of what arrived, and refuse rather than guess.
for _v in "$n_pass" "$n_fail" "$n_timeout" "$n_skip" "$n_envskip" "$end_line" "$last_row" "$stopped"; do
    [[ "$_v" =~ ^[0-9]+$ ]] || { printf 'band-verdict.sh: REFUSED — could not parse %s (the row scan returned a non-number)\n' "$log" >&2; exit 2; }
done
[[ "$end_rc" == none || "$end_rc" =~ ^[0-9]+$ ]] || { printf 'band-verdict.sh: REFUSED — unreadable END rc in %s\n' "$log" >&2; exit 2; }
reported=$(( n_pass + n_fail + n_timeout + n_skip + n_envskip ))

# Literal equality over disjoint values; the default arm is NOT-A-VERDICT, so an
# END rc nobody taught this tool can never be read as a pass.
verdict=none
if (( stopped == 1 )); then
    class=aborted
elif [[ "$end_rc" == none ]]; then
    class=no-end-marker
elif (( last_row > end_line )); then
    class=rows-after-end
else
    case "$end_rc" in
        0) class=complete; verdict=green ;;
        1) class=complete; verdict=red ;;
        3) class=incomplete ;;
        4) class=signalled ;;
        5) class=tree-changed ;;
        *) class=aborted ;;
    esac
fi

# RECONCILE BEFORE THE LINE IS PRINTED. The first cut printed `verdict=green
# class=complete` and refused on the NEXT line, so a consumer parsing the
# machine-readable line read green from a log this tool had declined to vouch
# for — this bundle's own defect class, written into its own remedy, and caught
# only because the test table printed that line beside the exit code.
_mismatch=0
if [[ "$class" == complete ]] && (( reported != selected )); then
    _mismatch=1; verdict=none; class=rows-mismatch
fi
# A GREEN MARKER OVER A RED ROW IS A CONTRADICTION, NOT A GREEN (skeptic round 1,
# your-org/nexus-code#1474). The green arm below used to consult neither `n_fail`
# nor `n_timeout`: it printed "none red" from the MARKER alone and disclosed only
# SKIP/ENVSKIP, so a log carrying `END rc=0` beside a TIMEOUT row would have had
# its one NO-VERDICT suite go unmentioned in the prose a human reads — the exact
# sentence this file's header is about. `timeout=N` was on the machine line, so a
# machine consumer could see it and a person could not.
#
# NOT REACHABLE FROM TODAY'S RUNNER, and that is why it is a REFUSAL rather than a
# verdict: both accounting arms force rc 1 on a timeout (the ledger arm requires
# `n_timeout == 0` for `_rt_exit 0`; the non-ledger arm passes
# `(( ${#failed_paths[@]} > 0 ))` first, and the TIMEOUT arm writes `.failed`), and
# test-band-verdict.sh pins `END rc=1` on a REAL generated timeout log. So if this
# ever fires, the producer's marker and its rows disagree and THIS TOOL CANNOT SAY
# WHICH IS RIGHT — the same stance as `rows-mismatch`. Added because "unreachable
# today" is a claim about a producer whose marker vocabulary has changed twice in
# recent memory (#1558, and this bundle's own TIMEOUT annotation), and a reader
# whose job is to distrust that producer should not carry an unstated assumption
# about it.
if [[ "$class" == complete ]] && [[ "$verdict" == green ]] && (( n_fail > 0 || n_timeout > 0 )); then
    _mismatch=2; verdict=none; class=marker-rows-contradiction
fi
printf 'verdict=%s class=%s end_rc=%s selected=%s reported=%s pass=%s fail=%s timeout=%s skip=%s envskip=%s\n' \
    "$verdict" "$class" "$end_rc" "$selected" "$reported" "$n_pass" "$n_fail" "$n_timeout" "$n_skip" "$n_envskip"

if (( _mismatch == 1 )); then
    printf 'band-verdict.sh: REFUSED — the END marker says COMPLETE, but %d verdict row(s) were found for %d selected test(s).\n' "$reported" "$selected" >&2
    printf '  The log and its own marker disagree; this tool will not pick one. (A log captured through a filter? several runs appended?)\n' >&2
    exit 2
fi
if (( _mismatch == 2 )); then
    printf 'band-verdict.sh: REFUSED — the END marker says rc=0 (green) while the rows carry %d FAIL and %d TIMEOUT.\n' "$n_fail" "$n_timeout" >&2
    printf '  No runner in this tree can produce that: a timeout or a failure forces rc 1 in BOTH accounting arms.\n' >&2
    printf '  So the marker and the rows disagree and this tool will not pick one — least of all the green one.\n' >&2
    exit 2
fi

case "$class" in
    complete)
        if [[ "$verdict" == green ]]; then
            printf 'VERDICT: GREEN — %d of %d selected reported, none red' "$reported" "$selected"
            (( n_skip + n_envskip > 0 )) && printf ' (%d SKIP, %d ENVSKIP: NOT covered by this run)' "$n_skip" "$n_envskip"
            printf '.\n'
            exit 0
        fi
        printf 'VERDICT: RED — %d failed an assertion, %d TIMED OUT.\n' "$n_fail" "$n_timeout"
        if (( n_fail > 0 )); then
            printf '  red by ASSERTION (these are about the tree):\n'
            grep -aE '^  FAIL  ' -- "$log" | awk '{ print "    " $2 }'
        fi
        if (( n_timeout > 0 )); then
            printf '  NO VERDICT about these — they ran out of their ceiling (a TIMEOUT is not a failed assertion):\n'
            grep -aE '^  TIMEOUT  ' -- "$log" | awk '{ print "    " $2 }'
        fi
        if (( n_fail == 0 && n_timeout == 0 )); then
            # A third producer of a row-less red since your-org/nexus-code#1620: the
            # runner's suite census. Named here so the one sentence a reader gets does
            # not send them looking only at accounting; the verdict itself is
            # unchanged (rc 1, class complete), and so is the machine line.
            #
            # The census reddens for TWO different reasons, and they are fixed in
            # different places, so the sentence names WHICH one the log carries
            # (skeptic pass on #1626): a tracked suite no root walks (`UNREACHABLE:`
            # rows; fix a root or the file's location) and a defective row in
            # census-exclusions.manifest (`RED: N defect(s) in the census
            # exclusions`, REFUSED / STALE rows; fix the manifest). Calling the
            # second "UNREACHABLE-SUITE" sent a reader hunting for a lost suite
            # when nothing was lost. Keyed on the runner's own headings.
            _bv_n_unreach=$(grep -caE '^    UNREACHABLE: ' -- "$log" || true)
            _bv_n_excl=$(sed -nE 's/^RED: ([0-9]+) defect\(s\) in the census exclusions.*/\1/p' -- "$log" | sed -n 1p)
            _bv_census=""
            if [[ "$_bv_n_excl" =~ ^[1-9][0-9]*$ ]]; then _bv_census="CENSUS-EXCLUSION-DEFECT (${_bv_n_excl} manifest row(s) REFUSED or STALE)"; fi
            if [[ "$_bv_n_unreach" =~ ^[1-9][0-9]*$ ]]; then _bv_census="${_bv_census:+$_bv_census and }UNREACHABLE-SUITE (${_bv_n_unreach} tracked suite(s) no root walks)"; fi
            if [[ -n "$_bv_census" ]]; then
                printf '  no FAIL or TIMEOUT row: the suite census (#1620) is red — %s — read the census lines above the END marker.\n' "$_bv_census"
            else
                printf '  no FAIL or TIMEOUT row: the red is an ACCOUNTING or --require-* verdict — read the lines above the END marker.\n'
            fi
        fi
        exit 1 ;;
    no-end-marker)
        printf 'NOT A VERDICT: no END marker. The run was KILLED or is STILL RUNNING; %d of %d selected have a row, and those rows are a SUBSET (%d PASS among them proves nothing about the rest).\n' \
            "$reported" "$selected" "$n_pass" ;;
    rows-after-end)
        printf 'NOT A VERDICT: a verdict row (line %d) FOLLOWS the END marker (line %d) — dispatch children outlived the runner and kept writing (your-org/nexus-code#1474).\n' \
            "$last_row" "$end_line" ;;
    incomplete)   printf 'NOT A VERDICT: END rc=3, a budget stop with tests unaccounted. Resume with the same command.\n' ;;
    signalled)    printf 'NOT A VERDICT: END rc=4, the sweep was interrupted by a signal; %d of %d selected have a row. Re-run.\n' "$reported" "$selected" ;;
    tree-changed) printf 'NOT A VERDICT: END rc=5, the tree CHANGED during the run; the result describes no single tree. Run from a detached worktree you never edit.\n' ;;
    aborted)      printf 'NOT A VERDICT: the runner stopped without a verdict (END rc=%s).\n' "$end_rc" ;;
esac
exit 4
