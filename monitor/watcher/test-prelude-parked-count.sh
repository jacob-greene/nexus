#!/usr/bin/env bash
# Regression contract for issue #7 proposal item 2: `parked-skeptic` must
# be counted "consistently across state=empty and state=busy".
#
# Item 1 of #7 (suppress the parked worker's `idle_prompt` decision) shipped
# and is pinned by test-emit-gate-recover.sh case (d). Item 2 did not. The
# result is two subsystems disagreeing INSIDE ONE EMIT BODY:
#
#   workspace: 1 busy | ... | 0 parked-skeptic | ...      <- render_idle_prelude
#   --- workspace snapshot ---
#     - W parked-awaiting-skeptic (state=busy; ...)       <- render_full_state_snapshot
#
# This is NOT the staleness of #14: both renderers run back-to-back in one
# process against one fixture here, so the skew is exactly zero.
#
# Root cause: render_idle_prelude derives `n_parked` from the idle set that
# list_really_idle_workers returns, but that classifier `continue`s on a
# `busy` pane (the `*)` arm) and on an `empty` pane (the `empty)` arm)
# BEFORE reaching its own parked-awaiting-skeptic short-circuit. A parked
# worker is `busy` by construction — monitor/README.md: "A worker parked in
# `await` reads `busy` (the await tool's spinner)" — so it never enters the
# idle set, `n_parked` stays 0, and the worker lands in the `busy` residue:
# precisely the inflation PR #285 set out to remove, still present in the
# two pane states a parked worker actually occupies.
#
# render_full_state_snapshot has it right: it calls `_idle_skeptic_parked`
# directly on every worker window, with no idle-candidate precondition.
#
# Run: bash monitor/watcher/test-prelude-parked-count.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR/skeptic/pending"
export STATE_DIR
LOGFILE="$WORK/watcher.log"
export LOGFILE
log() { :; }
export -f log

W=parked-worker
SK="$W-skeptic"
NOW=$(date +%s)

# Fixture: a worker parked on a FRESH skeptic-pending marker whose named
# skeptic window is LIVE — the healthy park, the case #7 calls "nothing was
# wrong". Idle age is well past the 60s threshold so nothing is grace-skipped.
touch "$STATE_DIR/skeptic/pending/$W"
printf '%s\t%s\n' "$W" "$(( NOW - 3000 ))" > "$STATE_DIR/engagement-log.tsv"
printf '{"ts":"%s","agent":"monitor","event":"skeptic-spawn","window":"%s","target-window":"%s","orig-window":"%s","depth":"1"}\n' \
    "$(date -Is)" "$SK" "$W" "$W" > "$STATE_DIR/action-log.jsonl"

# tmux stub: both windows alive, rc 0 (an answer, not a misread — #31).
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n%%s\\n" "%s" "%s"\n' "$W" "$SK" > "$WORK/bin/tmux"
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"

# shellcheck source=_idle_probe.sh
. "$_test_dir/_idle_probe.sh"

PANE_STATE=busy
_idle_list_worker_windows() { printf '%s\t%s\t%s\n' "$W" "$(( NOW - 3000 ))" "3"; }
_idle_pane_state_line()     { printf 'state=%s active=0\n' "$PANE_STATE"; }

# The predicate itself is the shared ground truth both renderers claim to
# report. Assert it first so a later failure cannot be blamed on the fixture.
if _idle_skeptic_parked "$W" "$NOW" "$(tmux list-windows -F '#{window_name}')"; then
    ok "fixture: _idle_skeptic_parked says PARKED (fresh marker + live skeptic)"
else
    bad "fixture is wrong: _idle_skeptic_parked says NOT parked — the rest of this file proves nothing"
fi

# `idle` is the one pane state that reaches the idle-set short-circuit, so
# it is the control: the counter has always worked here.
for PANE_STATE in idle busy empty; do
    echo "=== pane state=$PANE_STATE ==="
    prelude=$(render_idle_prelude)
    snapshot=$(render_full_state_snapshot)

    n_parked=$(printf '%s' "$prelude" | sed -n 's/.*| \([0-9]*\) parked-skeptic |.*/\1/p')
    n_busy=$(printf '%s' "$prelude" | sed -n 's/^\([0-9]*\) busy |.*/\1/p')

    if [[ "$snapshot" == *parked-awaiting-skeptic* ]]; then
        ok "snapshot labels the worker parked-awaiting-skeptic"
    else
        bad "snapshot did not label the worker parked (got: $snapshot)"
    fi

    if [[ "$n_parked" == "1" ]]; then
        ok "counts line reports 1 parked-skeptic"
    else
        bad "counts line and snapshot contradict each other in ONE emit body"
        printf '         want: 0 busy | ... | 1 parked-skeptic | ...\n' >&2
        printf '         got : %s\n' "$prelude" >&2
        printf '         snapshot (same body): %s\n' "$snapshot" >&2
    fi

    # The whole point of giving `parked` its own axis (PR #285) is that a
    # parked worker is NOT working, so it must not inflate `busy`.
    if [[ "$n_busy" == "0" ]]; then
        ok "parked worker excluded from the busy residue"
    else
        bad "parked worker inflates busy: got '$n_busy busy', want '0 busy'"
    fi
done

# A marker with NO live skeptic past grace is `orphaned`, not parked — it
# must NOT be swept into parked-skeptic by the fix.
echo '=== orphaned marker is not counted as parked ==='
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$W" > "$WORK/bin/tmux"   # skeptic window gone
printf '{"ts":"%s","agent":"monitor","event":"skeptic-request","target-window":"%s","depth":"1"}\n' \
    "$(date -Is -d "@$(( NOW - 3000 ))")" "$W" >> "$STATE_DIR/action-log.jsonl"
PANE_STATE=busy
prelude=$(render_idle_prelude)
n_parked=$(printf '%s' "$prelude" | sed -n 's/.*| \([0-9]*\) parked-skeptic |.*/\1/p')
if [[ "$n_parked" == "0" ]]; then
    ok "orphaned marker (no live skeptic past grace) is not counted parked"
else
    bad "orphaned marker counted as parked — the exemption was widened, not fixed: $prelude"
fi

echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d/%d)\n' "$PASS" "$(( PASS + FAIL ))"
    exit 0
else
    printf 'TESTS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
    exit 1
fi
