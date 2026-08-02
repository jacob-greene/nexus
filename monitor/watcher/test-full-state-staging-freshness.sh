#!/usr/bin/env bash
# Regression tests for the `--- workspace snapshot ---` staging freshness
# gate (jacob-greene/nexus#14).
#
# THE BUG: compose_emit renders the `workspace:` counts line INLINE (always
# fresh) but read the snapshot BODY verbatim from the async
# `scheduler-staging/full_state_snap.out` at any age. A window closing
# between the async render and the emit put two contradictory views in one
# message — `0 busy` in the preamble and a `state=busy` window in the
# snapshot body, naming a window that no longer existed.
#
# Strategy — same shape as test-full-state-suppression.sh: shadow `tmux` and
# `pane-state.sh` on PATH so per-window state is scriptable without a real
# tmux server, and use `touch -d` for synthetic staging mtimes. The emit
# composition is the PRODUCTION code: `_full_state_stage_age_seconds`,
# `_run_bounded`, `compose_report`, `_compose_report_body` and
# `_cap_emit_sections` are extracted verbatim from main.sh, and the
# full-state consume block is lifted verbatim out of `_v2_task_compose_emit`
# (only `local ` stripped, since it runs here at top level). Nothing about
# the gate is reimplemented in this file — a test that reimplemented it
# could not prove main.sh carries it.
#
# Run: bash monitor/watcher/test-full-state-staging-freshness.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"
CONFIG_SH="$_test_dir/_config.sh"
DEDUP_SH="$_test_dir/_emit_dedup.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$label"
    else
        fail "$label"
        printf '         got:  %q\n' "$got" >&2
        printf '         want: %q\n' "$want" >&2
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then pass "$label"
    else
        fail "$label"
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then pass "$label"
    else
        fail "$label"
        printf '         should NOT contain: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
    fi
}

_extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }

# ---- harness -------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
STAGE_DIR="$STATE_DIR/scheduler-staging"
STAGE_FILE="$STAGE_DIR/full_state_snap.out"
mkdir -p "$STAGE_DIR" "$WORK/tmp" "$WORK/monitor"
NEXUS_ROOT="$WORK"
export STATE_DIR NEXUS_ROOT

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# tmux stub: `list-windows` echoes MOCK_TMUX_WINDOWS regardless of -F, which
# is enough for both consumers (_idle_list_worker_windows parses
# name|activity|index; render_full_state_snapshot only membership-tests).
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    *)            : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# pane-state.sh stub. MOCK_PANE_SLEEP > 0 makes every probe hang, which is
# how the bounded-render-timeout (PARTIAL) case is exercised.
cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
win="${1:-}"
while [[ "$win" == --* ]]; do shift 2 2>/dev/null || break; win="${1:-}"; done
if [[ -n "${MOCK_PANE_SLEEP:-}" ]] && (( MOCK_PANE_SLEEP > 0 )); then
    sleep "$MOCK_PANE_SLEEP"
fi
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
printf 'state=%s\n' "${!key:-busy}"
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"

# Run one full-state compose cycle through the PRODUCTION composition path.
#   $1 windows        MOCK_TMUX_WINDOWS value (tmux ground truth)
#   $2 stage_age      seconds to backdate the staging file (empty ⇒ no file)
#   $3 stage_body     staging file content (empty ⇒ empty staging file)
#   $4 render_budget  _run_bounded budget for the inline re-render
#   $5 pane_sleep     per-pane probe delay (drives the timeout case)
# stdout: the emit body. stderr: the watcher log lines, prefixed `LOG `.
compose_cycle() {
    local windows="$1" stage_age="${2:-}" stage_body="${3:-}"
    local budget="${4:-20}" pane_sleep="${5:-0}"

    rm -f "$STAGE_FILE"
    if [[ -n "$stage_age" ]]; then
        printf '%s' "$stage_body" > "$STAGE_FILE"
        touch -d "@$(( $(date +%s) - stage_age ))" "$STAGE_FILE"
    fi

    PATH="$STUB_DIR:$PATH" MOCK_TMUX_WINDOWS="$windows" MOCK_PANE_SLEEP="$pane_sleep" \
    bash <<EOSH
set -uo pipefail
export STATE_DIR='$STATE_DIR' NEXUS_ROOT='$NEXUS_ROOT'
source '$DEDUP_SH'
source '$_test_dir/_idle_probe.sh'

$(_extract_fn "$MAIN_SH" _full_state_stage_age_seconds)
$(_extract_fn "$MAIN_SH" _run_bounded)
$(_extract_fn "$MAIN_SH" _cap_emit_sections)
$(_extract_fn "$MAIN_SH" compose_report)
$(_extract_fn "$MAIN_SH" _compose_report_body)
_close_inherited_locks() { :; }
_ensure_watcher_tmp_dir() { :; }
log() { printf 'LOG %s\n' "\$*" >&2; }

stage_dir='$STAGE_DIR'
tmp_dir='$WORK/tmp'
now_ts=\$(date +%s)
full_state_lines=""
TARGET=orchestrator
EMIT_SIG_NONCE=test
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=$budget
MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS=300

# --- verbatim from _v2_task_compose_emit ----------------------------------
# Only \`local\` → \`declare\` (we run at top level, not inside a function;
# \`declare\` keeps multi-variable declarations working). Nothing else altered.
$(awk '/full_state_snap\.out"/ {on=1} /if MONITOR_PRELUDE_DRY_RUN=1 _run_bounded/ {on=0} on' "$MAIN_SH" \
    | sed 's/^\( *\)local /\1declare /')
# --- end verbatim ---------------------------------------------------------

compose_report "poll-full-state" "" "" "" "" "\$full_state_lines" "" "" "" "" "" "" "" "" "" ""
EOSH
}

RESERVED_ONLY='services|0|1
orchestrator|0|2'
ONE_WORKER='services|0|1
orchestrator|0|2
nuc-arm-scatter|0|3'
OTHER_WORKER='services|0|1
orchestrator|0|2
kompot-bench|0|4'

STALE_BODY='  - nuc-arm-scatter (active, state=busy)'

# ===========================================================================
echo '=== _full_state_stage_age_seconds (unit) ==='

eval "$(_extract_fn "$MAIN_SH" _full_state_stage_age_seconds)"

assert_eq "missing file → -1" \
    "$(_full_state_stage_age_seconds "$WORK/nope.out")" "-1"

probe="$WORK/age-probe"
: > "$probe"
now=$(date +%s)
touch -d "@$(( now - 320 ))" "$probe"
assert_eq "backdated 320s → 320" \
    "$(_full_state_stage_age_seconds "$probe" "$now")" "320"
touch -d "@$now" "$probe"
assert_eq "just written → 0" \
    "$(_full_state_stage_age_seconds "$probe" "$now")" "0"
# NFS clock skew: a future mtime must clamp to 0 (fresh), never go negative.
# Reporting a negative age would make the gate's `age > max` comparison
# nonsense; reporting it as stale would fire the inline re-render on EVERY
# emit under sustained skew — the nexus-code#236 regression.
touch -d "@$(( now + 120 ))" "$probe"
assert_eq "future mtime (clock skew) → clamped to 0, not negative" \
    "$(_full_state_stage_age_seconds "$probe" "$now")" "0"

# ===========================================================================
echo '=== #14 repro: stale staging must not contradict the counts line ==='

# The exact production scenario from #14: the async render captured a worker
# window; the window closed 1.8s later; the emit fired 320s after that.
out=$(compose_cycle "$RESERVED_ONLY" 320 "$STALE_BODY" 2>"$WORK/err.1")
counts=$(printf '%s\n' "$out" | grep '^workspace:')
assert_contains "counts line reports zero workers (ground truth)" "$counts" "0 busy"
assert_not_contains "stale window is NOT served in the snapshot body" \
    "$out" "nuc-arm-scatter"
# Zero live workers ⇒ render_full_state_snapshot yields nothing ⇒ the section
# is correctly absent. Agreeing with `0 busy` is the whole point.
assert_not_contains "snapshot section absent when there are no workers" \
    "$out" "--- workspace snapshot ---"
# Age is compared loosely: the child re-reads the clock, so a `touch -d`
# 320s in the past can read back as 321s across a second boundary.
assert_contains "re-render is logged with its reason" \
    "$(cat "$WORK/err.1")" "re-rendered inline (staging 32"
assert_contains "re-render reason names the threshold it crossed" \
    "$(cat "$WORK/err.1")" "> 300s max"

# Stale staging + a DIFFERENT live worker: the served body must be the LIVE
# one, not merely "not the stale one".
out=$(compose_cycle "$OTHER_WORKER" 320 "$STALE_BODY" 2>/dev/null)
assert_contains "stale body replaced by the live worker" "$out" "kompot-bench"
assert_not_contains "stale worker gone from the replacement" "$out" "nuc-arm-scatter"

# ===========================================================================
echo '=== heartbeat guard: FRESH staging is served as-is, no inline render ==='

# This is the constraint that keeps the async path the fast path. A gate that
# re-rendered on every emit would reintroduce exactly the O(workers) inline
# stall nexus-code#236 fixed.
#
# The discriminator is a SENTINEL in the staged bytes that a live render
# could never produce. Wall-clock timing cannot be used here:
# `_compose_report_body` renders the `workspace:` prelude inline on every
# emit (by design — that is the always-fresh half), so the cycle pays a
# pane-probe pass either way.
SENTINEL='  - nuc-arm-scatter (active, state=busy) [staged-sentinel]'
out=$(compose_cycle "$ONE_WORKER" 10 "$SENTINEL" 2>"$WORK/err.2")
assert_contains "fresh staged body served byte-for-byte" "$out" "[staged-sentinel]"
assert_not_contains "no inline re-render on the fresh path" \
    "$(cat "$WORK/err.2")" "re-rendered inline"

# ...and the same sentinel IS discarded once the body goes stale.
out=$(compose_cycle "$ONE_WORKER" 320 "$SENTINEL" 2>/dev/null)
assert_not_contains "stale staged bytes are discarded, not served" \
    "$out" "[staged-sentinel]"
assert_contains "replaced by a live render of the same window" "$out" "nuc-arm-scatter"

# Boundary. The end-to-end checks carry a few seconds of slack on purpose:
# compose_cycle backdates with `touch -d` and the child then re-reads the
# clock, so an age staged as exactly 300 can read back as 301 across a second
# tick. Exactness is pinned separately, deterministically, below.
out=$(compose_cycle "$ONE_WORKER" 295 "$STALE_BODY" 2>"$WORK/err.3")
assert_not_contains "comfortably under max → fresh (no re-render)" \
    "$(cat "$WORK/err.3")" "re-rendered inline"
out=$(compose_cycle "$ONE_WORKER" 310 "$STALE_BODY" 2>"$WORK/err.4")
assert_contains "comfortably over max → stale (re-renders)" \
    "$(cat "$WORK/err.4")" "re-rendered inline"

# Exact boundary, no clock race: pin `now` and assert (a) the age function is
# exact at the threshold and (b) the gate compares with strict `>`, i.e. an
# age of exactly max is fresh. Together these fix the boundary without a
# timing-dependent assertion.
now=$(date +%s)
touch -d "@$(( now - 300 ))" "$probe"
assert_eq "age at exactly the threshold is 300 (pinned clock)" \
    "$(_full_state_stage_age_seconds "$probe" "$now")" "300"
if grep -qE '\(\( *_fs_age > MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS *\)\)' "$MAIN_SH"; then
    pass "gate uses strict > (age == max is fresh, not stale)"
else
    fail "gate must compare _fs_age with strict > against MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS"
fi

# Empty staging still re-renders (the pre-#14 behaviour must survive).
out=$(compose_cycle "$ONE_WORKER" 0 "" 2>"$WORK/err.5")
assert_contains "empty staging still re-renders" \
    "$(cat "$WORK/err.5")" "re-rendered inline (staging empty)"
# Absent staging file: mtime unreadable ⇒ fail toward freshness.
out=$(compose_cycle "$ONE_WORKER" "" "" 2>"$WORK/err.6")
assert_contains "absent staging file re-renders" \
    "$(cat "$WORK/err.6")" "re-rendered inline"

# ===========================================================================
echo '=== provenance footer ==='

# Age slack again (staged 120s can read back as 121s); the shape is what is
# asserted exactly, the digits loosely.
out=$(compose_cycle "$ONE_WORKER" 120 "$STALE_BODY" 2>/dev/null)
footer=$(printf '%s\n' "$out" | grep '^(full snapshot')
if [[ "$footer" =~ ^\(full\ snapshot,\ rendered\ 12[0-9]s\ ago\;\ transitions\ only\ between\ snapshots\)$ ]]; then
    pass "staged body carries its render age"
else
    fail "staged body footer wrong: got '$footer'"
fi

out=$(compose_cycle "$OTHER_WORKER" 320 "$STALE_BODY" 2>/dev/null)
assert_contains "freshly re-rendered body reports 0s" \
    "$out" "(full snapshot, rendered 0s ago; transitions only between snapshots)"

# Bounded re-render times out before emitting a single row. Taking its empty
# output would DELETE the section — and an absent section legitimately means
# "no workers", so that would swap one silent falsehood for another. The
# staged body is kept, labelled STALE with its true age. "Fail toward
# freshness, not toward silence."
out=$(compose_cycle "$ONE_WORKER" 320 "$STALE_BODY" 1 30 2>"$WORK/err.7")
assert_contains "timed-out empty re-render keeps the section" \
    "$out" "--- workspace snapshot ---"
assert_contains "...serving the staged body" "$out" "nuc-arm-scatter"
assert_contains "...labelled STALE" "$out" "STALE"
assert_contains "...with its true age, not 0s" "$out" "rendered 32"
assert_contains "...and a verify-with-tmux instruction" "$out" "verify with tmux before acting"
assert_contains "timeout logs the empty-render fallback" \
    "$(cat "$WORK/err.7")" "produced nothing; serving the"

# A timed-out render that DID emit rows is served as a labelled PARTIAL.
# MOCK_PANE_SLEEP=2 with a 3s budget lets the first window through before the
# kill; the second window is lost.
out=$(compose_cycle "$ONE_WORKER
kompot-bench|0|5" 320 "$STALE_BODY" 3 2 2>"$WORK/err.8")
if [[ "$out" == *"PARTIAL"* ]]; then
    pass "partial (non-empty) timed-out render is labelled PARTIAL"
    assert_contains "PARTIAL names the budget it blew" "$out" "3s budget"
    assert_not_contains "a PARTIAL is not also labelled STALE" "$out" "STALE"
else
    # Machine was fast enough that the render completed inside the budget —
    # a timing-dependent case we do not force. Say so rather than pass blind.
    printf '  SKIP: partial-render labelling (render completed within budget on this host)\n'
fi

# ===========================================================================
echo '=== section-cap allowlist invariant ==='

# The provenance annotation MUST stay in the footer. `_cap_emit_sections`
# matches `--- workspace snapshot ---` as an exact string in its exempt
# allowlist; annotating the HEADER (as #14 suggested) would silently drop the
# section off that allowlist and make it truncatable at 50 lines.
grep -q "exempt\[\"--- workspace snapshot ---\"\]" "$MAIN_SH" \
    && pass "allowlist still keys on the bare header string" \
    || fail "exempt allowlist no longer contains '--- workspace snapshot ---'"

eval "$(_extract_fn "$MAIN_SH" _cap_emit_sections)"
big=$( { printf -- '--- workspace snapshot ---\n'
         for i in $(seq 1 80); do printf '  - w%02d (active, state=busy)\n' "$i"; done
         printf '(full snapshot, rendered 12s ago; transitions only between snapshots)\n'
       } | MONITOR_EMIT_SECTION_MAX_LINES=50 _cap_emit_sections )
assert_not_contains "annotated snapshot section is still never truncated" \
    "$big" "more lines omitted"
assert_eq "all 80 rows survive the cap" \
    "$(printf '%s\n' "$big" | grep -c '^  - w')" "80"

# ===========================================================================
echo '=== volatile strip normalises the age token ==='

# The footer now varies emit-to-emit. `_emit_volatile_strip` feeds the
# emit-dedup hash and the full-state canonical comparison, so an un-normalised
# age would make two byte-identical workspaces hash differently.
source "$DEDUP_SH"
a=$(printf '(full snapshot, rendered 12s ago; transitions only between snapshots)\n' | _emit_volatile_strip)
b=$(printf '(full snapshot, rendered 287s ago; transitions only between snapshots)\n' | _emit_volatile_strip)
assert_eq "differing ages normalise identically" "$a" "$b"
assert_eq "normalised form is the legacy footer" \
    "$a" "(full snapshot; transitions only between snapshots)"
# PARTIAL is genuinely different content and must NOT normalise away.
c=$(printf '(full snapshot, rendered 0s ago, PARTIAL (render hit its 20s budget; windows may be missing); transitions only between snapshots)\n' | _emit_volatile_strip)
assert_not_contains "PARTIAL survives normalisation" "$c" "$a"

# ===========================================================================
echo '=== config derivation ==='

# Derived defaults must satisfy stage_max_age >= 2 * snap_interval, so the
# gate fires only after the async producer has missed two beats — that
# margin is what keeps the inline re-render the exception, not the rule.
# `_cfg` stub: the real one reads config.yaml; here every lookup misses, so
# it echoes the caller-supplied default (its 2nd arg) — which is what forces
# the derived-default branch we want to test.
cat > "$WORK/cfgstub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${2:-}"
STUB
chmod +x "$WORK/cfgstub"

read -r snap_i stage_a < <(
    env -u MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS \
        -u MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS \
        bash -c "
            _cfg='$WORK/cfgstub'
            MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS=600
            $(awk '/^MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS=/ {on=1}
                   on {print}
                   on && /^fi$/ {n++; if (n==2) exit}' "$CONFIG_SH")
            printf '%s %s\n' \"\$MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS\" \"\$MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS\"
        ")
assert_eq "snap interval defaults to emit_interval/4" "$snap_i" "150"
assert_eq "stage max age defaults to emit_interval/2" "$stage_a" "300"
if (( stage_a >= 2 * snap_i )); then
    pass "stage_max_age >= 2 x snap_interval (gate stays cold in normal operation)"
else
    fail "stage_max_age ($stage_a) < 2 x snap_interval ($snap_i) — inline render would be the rule"
fi

# The producer cadence must be wired to the knob, not hard-coded back to 600.
grep -q '_schedule_task full_state_snap *"\$MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS"' "$MAIN_SH" \
    && pass "full_state_snap cadence reads the config knob" \
    || fail "full_state_snap cadence is not wired to MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS"

# ===========================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo 'ALL TESTS PASSED'
    exit 0
fi
exit 1
