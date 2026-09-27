#!/usr/bin/env bash
# ci-band-verdict.sh — CI's reader of a unit band's END marker: a band that did
# not finish renders as NO VERDICT, never as an ordinary `fail`
# (your-org/nexus-code#1474, the CI half; band-verdict.sh is the local half).
#
# THE HARM. A band killed at `timeout-minutes` is CANCELLED by GitHub, and a
# truncated band that fails its step renders `fail` beside a band whose suites
# failed assertions — two different facts, one colour, and only the second is
# about the tree. band-verdict.sh already classifies the LOG correctly (exit 4
# NOT A VERDICT); nothing in CI read it. This script is that reader: tests.yml
# bounds each band's run step below the job ceiling (`ci-diag-budget.sh
# --run-bound`), so a slow band is stopped INSIDE the job, and an `if: always()`
# step then runs this over the band log and says which fact it is.
#
# Usage:
#   ci-band-verdict.sh [--band NAME] [--run-rc N] <band-log>
#     --band    the job's display name, quoted in the annotation and summary
#     --run-rc  the run step's exit status. 124/137 mean the step's `timeout`
#               bound FIRED; an empty value means unknown (the step was killed
#               before it could record one) and changes nothing.
#
# Output: GitHub workflow commands on stdout (`::error title=…::`), band-verdict's
# own lines as a log group, and ONE line appended to $GITHUB_STEP_SUMMARY when
# that is set. Titles, so a rollup reader can tell them apart at a glance:
#   RED            complete band, assertion/timeout reds (band-verdict exit 1)
#   NO VERDICT     truncated, cancelled, signalled, bound-fired, or no log
#   VERDICT REFUSED  the log contradicts itself (band-verdict exit 2)
#
# Exit codes — the JOB CONCLUSION is `failure` for everything but green:
#   0  GREEN
#   1  RED
#   4  NO VERDICT — deliberately NOT 0. A truncated band is not a pass, and a
#      step cannot conclude `neutral` or `cancelled` on its own (only the
#      checks API can, and cancelling via the API would take every other job
#      in the run with it). So the conclusion stays `failure`; what separates
#      it from a red is the annotation TITLE and the summary line.
#   2  REFUSED, or band-verdict answered outside its vocabulary
#
# THE BOUND OVERRIDES A MARKER, NOT THE OTHER WAY ROUND. When the run step's
# `timeout` fired (rc 124 TERM, 137 KILL — outside run-tests.sh's own
# vocabulary 0-5/97, so for THIS callee they identify the wrapper), a TERM
# reached the whole band. At `--jobs >1` the runner traps it and prints
# `END rc=4`, which band-verdict already reads as NO VERDICT. At `--jobs 1`
# measured otherwise: the TERM kills the running suite, the runner records it
# as `FAIL … rc=143` and can print a COMPLETE RED marker. So a bound that fired
# makes the band NO VERDICT whatever its marker says — the safe direction: a
# band that finished its last suite just as the bound fired is reported as
# "re-run", never as a verdict it may not have reached. FAIL rows recorded
# before the stop are still listed; rc=143/137 among them are the bound's kill.
set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
READER="$_self_dir/band-verdict.sh"

_usage() { sed -n '2,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
band="band"; run_rc=""; log=""
while (( $# > 0 )); do
    case "$1" in
        --band)   (( $# >= 2 )) || _usage; band="$2"; shift 2 ;;
        --run-rc) (( $# >= 2 )) || _usage; run_rc="$2"; shift 2 ;;
        -h|--help) _usage ;;
        -*)       _usage ;;
        *)        [[ -z "$log" ]] || _usage; log="$1"; shift ;;
    esac
done
[[ -n "$log" ]] || _usage
[[ -z "$run_rc" || "$run_rc" =~ ^[0-9]+$ ]] || _usage

# Workflow-command data escaping: `%`, CR and LF are the three the runner decodes.
_esc() { local s="$1"; s="${s//'%'/%25}"; s="${s//$'\r'/%0D}"; s="${s//$'\n'/%0A}"; printf '%s' "$s"; }
_summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; return 0; }
_field() { sed -n "s/.*[[:space:]]$1=\([^[:space:]]*\).*/\1/p" <<<" $2"; }

bound_fired=0
case "$run_rc" in 124|137) bound_fired=1 ;; esac

if [[ ! -s "$log" ]]; then
    msg="$band: no band log at $log — the band step never started or wrote nothing (run rc ${run_rc:-unknown}). No suite has a verdict."
    printf '::error title=NO VERDICT::%s\n' "$(_esc "$msg")"
    _summary "**$band — no verdict** (no band log; the band never ran), not a test failure."
    exit 4
fi

out=$(bash "$READER" "$log" 2>&1)
bv_rc=$?
line=$(sed -n 1p <<<"$out")
selected=$(_field selected "$line"); reported=$(_field reported "$line")
class=$(_field class "$line"); n_fail=$(_field fail "$line"); n_timeout=$(_field timeout "$line")
counts="${reported:-?} of ${selected:-?} selected suites reported"

echo "::group::band-verdict.sh on $log"
printf '%s\n' "$out"
echo "::endgroup::"

# A bound that fired outranks a verdict marker (header).
if (( bound_fired )) && [[ "$bv_rc" == 0 || "$bv_rc" == 1 ]]; then
    bv_rc=4; class="bound-fired (marker said ${class:-?})"
fi

case "$bv_rc" in
    0)
        _summary "**$band — GREEN**: $counts."
        exit 0 ;;
    1)
        msg="$band: ${n_fail:-?} suite(s) failed an assertion, ${n_timeout:-?} timed out; $counts. The band COMPLETED — this is a verdict about the tree."
        printf '::error title=RED::%s\n' "$(_esc "$msg")"
        _summary "**$band — RED**: ${n_fail:-?} failed, ${n_timeout:-?} timed out; $counts."
        exit 1 ;;
    4)
        why="class ${class:-?}"
        (( bound_fired )) && why="$why; the run step's ${run_rc}-exit bound fired below the job ceiling"
        fails=$(grep -aE '^  FAIL  ' -- "$log" | awk '{ printf "%s%s %s", sep, $2, $NF; sep=", " }')
        msg="$band: NO VERDICT (truncated/cancelled band), not a test failure — $counts ($why). Re-run; the rows present are a SUBSET."
        [[ -n "$fails" ]] && msg="$msg FAIL rows recorded before the stop: $fails (rc=143/137 are the stop's own kill)."
        printf '::error title=NO VERDICT::%s\n' "$(_esc "$msg")"
        _summary "**$band — no verdict** (truncated/cancelled band), not a test failure: $counts ($why)."
        exit 4 ;;
    2)
        why=$(grep -a -m1 'REFUSED' <<<"$out")
        msg="$band: band-verdict.sh REFUSED to read the band log (${why:-no reason printed}). Treat it as no verdict and read the log."
        printf '::error title=VERDICT REFUSED::%s\n' "$(_esc "$msg")"
        _summary "**$band — verdict REFUSED** (the band log contradicts itself), not a test failure: $counts."
        exit 2 ;;
    *)
        printf '::error title=VERDICT REFUSED::%s\n' "$(_esc "$band: band-verdict.sh exited $bv_rc, outside its vocabulary")"
        _summary "**$band — verdict REFUSED** (band-verdict.sh exit $bv_rc)."
        exit 2 ;;
esac
