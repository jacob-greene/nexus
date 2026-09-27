#!/usr/bin/env bash
# realmodel-scenarios.sh — which realmodel scenarios may a caller declare
# MEASURABLE on a given backend? (your-org/nexus-code#1574 G1.)
#
# THE DEFECT THIS CLOSES. `cc-harness.yml` discovered its scenarios with a bare
# `find … -name 'test-realmodel-*.sh'` and handed the whole set to
# `run-tests.sh --require-run`, which DECLARES every selected test applicable
# and reddens a SKIP (77) and an ENVSKIP (69). One scenario cannot be measured
# on the mock backend at all — test-realmodel-longjob-wake.sh: the dispatcher
# is a plugin monitor the host arms only when GrowthBook serves a flag, and
# under the mock GrowthBook is off. It stayed green by leaving at `exit 0`,
# which `--require-run` cannot see (rc 0 is in neither of the two counts):
# measured by the #1569 delta skeptic, `PASS … 144.14s assertions: ?` and
# `END rc=0 (COMPLETE and green)` with the whole wake contract unexercised. So
# the comment in that workflow — "a SKIP here is never 'the gate did not take'"
# — was true only because the one legitimate exception did not use a skip code.
# Making the scenario honest (it now exits 69) would turn the job PERMANENTLY
# red; the caller's DECLARATION was what was false, so the caller is what is
# fixed: it asks here, and an unmeasurable scenario is excluded AND REPORTED.
#
# WHY NOT gate-coverage.tsv's `exempt` ROWS. They look like this channel and
# are not. `exempt` means "exists and is not in gate.sh's list"; at d58bc49a it
# has three rows, and two of them (apispoof, long-exchange) RUN AND MEASURE on
# the mock backend in the workflow. Selecting on `exempt` would have deleted
# their coverage in silence — a field that SELECTS is not a label (#1050). So
# the property is declared where it is true, in the scenario's own header:
#
#     # cch:mock-backend=unmeasurable  <reason, required>
#
# IN THE HEAD OF THE FILE (first 10 lines), anchored at column 0. A predicate
# over text cannot tell the thing from a description of it: this header you are
# reading names the marker, and so will any suite that plants a fixture
# carrying one. ERROR DIRECTION, stated: a marker placed below line 10 is NOT
# honoured, so the scenario is SELECTED, runs, exits 69 and the job goes RED —
# the loud direction. Nothing here can exclude a scenario that did not ask.
#
# Usage:
#   monitor/cc-harness/realmodel-scenarios.sh --backend mock|real [--dir DIR]
#
#   stdout  the APPLICABLE scenario paths, one per line, sorted (C locale).
#   stderr  one `EXCLUDED <path> — <reason>` line per excluded scenario, then a
#           tally. Excluded is never silent: an absence must not read as cover.
#
# Exit codes:
#   0  at least one applicable scenario, and applicable + excluded = discovered
#   1  nothing discovered; nothing applicable; or a marker with NO reason (an
#      exclusion nobody can review is refused — the scenario is not dropped,
#      the whole selection fails)
#   2  usage
#
# READ THE EXIT CODE, NOT JUST THE LIST: `mapfile < <(this …)` discards it, and
# an empty list from a failed selection then reads as "no scenarios". Write to
# a file, test the status, then read the file.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
backend=''
dir=$(cd "$_self_dir/../watcher/test-integration" 2>/dev/null && pwd) || dir="$_self_dir/../watcher/test-integration"

_usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while (( $# > 0 )); do
    case "$1" in
        --backend) backend="${2:-}"; shift 2 || _usage ;;
        --dir)     dir="${2:-}";     shift 2 || _usage ;;
        -h|--help) _usage ;;
        *)         printf 'realmodel-scenarios.sh: unknown argument: %s\n' "$1" >&2; _usage ;;
    esac
done
# Literal equality over disjoint values, default DENY: an unknown backend is a
# usage error, never "exclude nothing".
case "$backend" in
    mock|real) ;;
    *) printf 'realmodel-scenarios.sh: --backend must be mock or real (got: %s)\n' "${backend:-<none>}" >&2; exit 2 ;;
esac
[[ -d "$dir" ]] || { printf 'realmodel-scenarios.sh: no such directory: %s\n' "$dir" >&2; exit 2; }

discovered=()
while IFS= read -r f; do
    [[ -n "$f" ]] && discovered+=("$f")
done < <(find "$dir" -maxdepth 1 -name 'test-realmodel-*.sh' -type f | LC_ALL=C sort)

if (( ${#discovered[@]} == 0 )); then
    printf 'realmodel-scenarios.sh: NO test-realmodel-*.sh under %s — refusing to hand back an empty selection.\n' "$dir" >&2
    exit 1
fi

applicable=(); n_excluded=0; bad=0
for f in "${discovered[@]}"; do
    # The marker, from the HEAD of the file only. Every stage reads its whole
    # input (`sed -n`, never `head`; no `exit` in the awk): an early-exiting
    # reader SIGPIPEs its producer. The first marker line wins.
    marker=$(sed -n '1,10p' -- "$f" 2>/dev/null \
        | awk '/^# cch:mock-backend=unmeasurable([[:space:]]|$)/' \
        | sed -n 1p)
    if [[ -z "$marker" || "$backend" != mock ]]; then
        applicable+=("$f")
        continue
    fi
    reason=${marker#'# cch:mock-backend=unmeasurable'}
    reason=$(printf '%s' "$reason" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ -z "$reason" ]]; then
        printf 'realmodel-scenarios.sh: %s declares cch:mock-backend=unmeasurable with NO REASON — refusing.\n' "$f" >&2
        bad=1
        continue
    fi
    printf 'EXCLUDED %s — %s\n' "$f" "$reason" >&2
    n_excluded=$(( n_excluded + 1 ))
done
(( bad == 0 )) || exit 1

# The identity that makes a silent drop impossible. True by construction today;
# asserted so it stays true when someone adds a third arm to the loop above.
if (( ${#applicable[@]} + n_excluded != ${#discovered[@]} )); then
    printf 'realmodel-scenarios.sh: INTERNAL: %d applicable + %d excluded != %d discovered — refusing.\n' \
        "${#applicable[@]}" "$n_excluded" "${#discovered[@]}" >&2
    exit 1
fi
printf 'realmodel-scenarios.sh: backend=%s discovered=%d applicable=%d excluded=%d (excluded scenarios are NOT covered by this run)\n' \
    "$backend" "${#discovered[@]}" "${#applicable[@]}" "$n_excluded" >&2
if (( ${#applicable[@]} == 0 )); then
    printf 'realmodel-scenarios.sh: every discovered scenario is excluded on backend=%s — refusing an empty selection.\n' "$backend" >&2
    exit 1
fi
printf '%s\n' "${applicable[@]}"
