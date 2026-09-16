#!/usr/bin/env bash
# Tests for monitor/uv-cache-guard.sh — the dangling-uv-cache guard
# (jacob-greene/nexus#98, incident 2026-08-25).
#
# The fault: `locals/uv/cache` is a symlink into purgeable scratch. A purge
# removes the TARGET; the symlink survives dangling; every `uv` call then fails
# with `File exists (os error 17)`, which names neither the symlink nor the
# missing target. It took `jupyter-mouse_BM` down twice, 20 min 18 s combined.
#
# These tests CONSTRUCT the broken state — they do not reason about the code.
# Test (13) is the decisive one: it runs the real `uv` against a real dangling
# symlink, asserts the incident's exact error, runs the guard, and asserts the
# same `uv` command then succeeds. Tests (3)-(5) are the controls: the guard
# must be a no-op on a healthy link, on a real directory, and on an absent path.
#
# Everything is hermetic under a mktemp -d sandbox. Nothing touches the live
# `locals/` tree.
#
# Run: bash monitor/watcher/test-uv-cache-guard.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD="$_test_dir/../uv-cache-guard.sh"
RECOVER="$_test_dir/../bootstrap-recover.sh"
LABSH="$_test_dir/../labsh-supervised.sh"

[[ -r "$GUARD" ]] || { echo "FAIL: $GUARD missing" >&2; echo FAILED; exit 1; }

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() {
    local label="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] && ok "$label" || bad "$label" "got $(printf %q "$got") want $(printf %q "$want")"
}

WORK=$(mktemp -d -t nexus-uv-cache-guard-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Run the guard as a SUBPROCESS so a `return` cannot leak into this shell and
# so each case gets a clean environment. Prints the exit code on stdout;
# stderr is captured to $2 when a caller wants to inspect the warnings.
run_guard() {
    local path="$1" errfile="${2:-/dev/null}" rc=0
    env -u UV_CACHE_DIR -u NEXUS_LOCALS \
        NEXUS_STATE_DIR="$WORK/state" \
        PATH="/usr/bin:/bin" \
        bash "$GUARD" "$path" 2>"$errfile" || rc=$?
    printf '%s' "$rc"
}

echo "=== uv-cache-guard ==="

# ---- (1) the fault: a dangling symlink is repaired -------------------------
c1="$WORK/c1"; mkdir -p "$c1/locals/uv" "$c1/scratch"
ln -s "$c1/scratch/nexus-uv-cache" "$c1/locals/uv/cache"
rc=$(run_guard "$c1/locals/uv/cache" "$WORK/c1.err")
assert_eq "(1) dangling symlink -> exit 10 (repaired)" "$rc" "10"
[[ -d "$c1/scratch/nexus-uv-cache" ]] \
    && ok "(1) target directory created" \
    || bad "(1) target directory created" "$c1/scratch/nexus-uv-cache is not a directory"
[[ -L "$c1/locals/uv/cache" && -e "$c1/locals/uv/cache" ]] \
    && ok "(1) symlink now resolves" \
    || bad "(1) symlink now resolves" "still dangling"

# ---- (2) idempotent: a second run is a silent no-op ------------------------
rc=$(run_guard "$c1/locals/uv/cache" "$WORK/c2.err")
assert_eq "(2) second run -> exit 0 (nothing to do)" "$rc" "0"
[[ ! -s "$WORK/c2.err" ]] \
    && ok "(2) second run warns nothing (fires once per purge)" \
    || bad "(2) second run warns nothing" "stderr: $(cat "$WORK/c2.err")"

# ---- (3) CONTROL: healthy symlink is untouched -----------------------------
c3="$WORK/c3"; mkdir -p "$c3/locals/uv" "$c3/scratch/nexus-uv-cache"
ln -s "$c3/scratch/nexus-uv-cache" "$c3/locals/uv/cache"
touch "$c3/scratch/nexus-uv-cache/sentinel"
rc=$(run_guard "$c3/locals/uv/cache" "$WORK/c3.err")
assert_eq "(3) healthy symlink -> exit 0" "$rc" "0"
[[ -f "$c3/scratch/nexus-uv-cache/sentinel" && ! -s "$WORK/c3.err" ]] \
    && ok "(3) healthy symlink: contents intact, no output" \
    || bad "(3) healthy symlink no-op" "sentinel or stderr changed"

# ---- (4) CONTROL: a real directory does not fire ---------------------------
c4="$WORK/c4"; mkdir -p "$c4/locals/uv/cache"
touch "$c4/locals/uv/cache/sentinel"
rc=$(run_guard "$c4/locals/uv/cache" "$WORK/c4.err")
assert_eq "(4) real directory -> exit 0" "$rc" "0"
[[ -d "$c4/locals/uv/cache" && ! -L "$c4/locals/uv/cache" && -f "$c4/locals/uv/cache/sentinel" ]] \
    && ok "(4) real directory: still a plain directory, contents intact" \
    || bad "(4) real directory no-op" "the path was modified"

# ---- (5) CONTROL: an absent path is NOT provisioned ------------------------
# Provisioning `locals/` is bootstrap-venv's job. A guard that also created a
# missing cache would silently take that over and mask an unprovisioned tree.
c5="$WORK/c5"; mkdir -p "$c5/locals/uv"
rc=$(run_guard "$c5/locals/uv/cache" "$WORK/c5.err")
assert_eq "(5) absent path -> exit 0" "$rc" "0"
[[ ! -e "$c5/locals/uv/cache" ]] \
    && ok "(5) absent path is not created (provisioning stays bootstrap-venv's job)" \
    || bad "(5) absent path" "the guard created $c5/locals/uv/cache"

# ---- (6) a RELATIVE link body resolves against the LINK, not the cwd -------
# The footgun the sketch in #98 had: `mkdir -p "$(readlink …)"` from the wrong
# cwd creates the wrong directory and leaves the real fault unrepaired.
c6="$WORK/c6"; mkdir -p "$c6/locals/uv" "$c6/scratch" "$c6/elsewhere"
ln -s "../../scratch/nexus-uv-cache" "$c6/locals/uv/cache"
rc=$(cd "$c6/elsewhere" && run_guard "$c6/locals/uv/cache" "$WORK/c6.err")
assert_eq "(6) relative body, foreign cwd -> exit 10" "$rc" "10"
[[ -d "$c6/scratch/nexus-uv-cache" ]] \
    && ok "(6) relative body resolved against the symlink's own directory" \
    || bad "(6) relative body" "$c6/scratch/nexus-uv-cache was not created"
[[ ! -e "$c6/elsewhere/scratch" && ! -e "$c6/elsewhere/nexus-uv-cache" ]] \
    && ok "(6) nothing created under the caller's cwd" \
    || bad "(6) relative body" "the guard created a directory under the cwd"

# ---- (7) REFUSE: a single top-level component is not a plausible cache -----
c7="$WORK/c7"; mkdir -p "$c7/locals/uv"
ln -s "/nexus-uv-cache-should-not-exist" "$c7/locals/uv/cache"
rc=$(run_guard "$c7/locals/uv/cache" "$WORK/c7.err")
assert_eq "(7) single top-level target -> exit 2 (refused)" "$rc" "2"
[[ ! -e "/nexus-uv-cache-should-not-exist" ]] \
    && ok "(7) refused without creating anything at /" \
    || bad "(7) refusal" "the guard created a top-level directory"
grep -q "REFUSING" "$WORK/c7.err" \
    && ok "(7) refusal says why on stderr" \
    || bad "(7) refusal message" "stderr: $(cat "$WORK/c7.err")"

# ---- (8) REFUSE: no existing ancestor below / ------------------------------
# Models an unmounted scratch filesystem. Creating the tree would shadow the
# mountpoint with a directory on the root filesystem and hide the real fault.
c8="$WORK/c8"; mkdir -p "$c8/locals/uv"
ln -s "/nexus-no-such-mount-98/setty_m/jgreene/nexus-uv-cache" "$c8/locals/uv/cache"
rc=$(run_guard "$c8/locals/uv/cache" "$WORK/c8.err")
assert_eq "(8) unmounted-looking target -> exit 2 (refused)" "$rc" "2"
[[ ! -e "/nexus-no-such-mount-98" ]] \
    && ok "(8) refused without creating a shadow mountpoint" \
    || bad "(8) refusal" "the guard created /nexus-no-such-mount-98"

# ---- (9) REFUSE: a symlink cycle terminates ---------------------------------
c9="$WORK/c9"; mkdir -p "$c9"
ln -s "$c9/b" "$c9/a"
ln -s "$c9/a" "$c9/b"
rc=$(run_guard "$c9/a" "$WORK/c9.err")
assert_eq "(9) symlink cycle -> exit 2 (refused, bounded)" "$rc" "2"

# ---- (10) the purge is RECORDED durably (review question 2) ----------------
rec="$WORK/state/uv-cache-purged.log"
if [[ -f "$rec" ]]; then
    ok "(10) purge record written to \$NEXUS_STATE_DIR/uv-cache-purged.log"
    grep -qF "$c1/scratch/nexus-uv-cache" "$rec" \
        && ok "(10) record names the scratch target (so other losses can be checked)" \
        || bad "(10) record content" "target missing from $rec"
    # one line per repair: cases (1) and (6) repaired, (2)-(9) did not.
    assert_eq "(10) exactly one record per repair" "$(grep -c . "$rec")" "2"
else
    bad "(10) purge record" "$rec was not written"
fi
grep -q "WARNING" "$WORK/c1.err" \
    && ok "(10) repair warns loudly on stderr" \
    || bad "(10) warning" "no WARNING in stderr: $(cat "$WORK/c1.err")"

# ---- (11) bootstrap-recover wiring: --dry-run writes NOTHING ---------------
# boot-recover.sh runs `--dry-run` as a health probe, so it must stay
# side-effect-free.
c11="$WORK/c11"; mkdir -p "$c11/locals/uv" "$c11/scratch"
ln -s "$c11/scratch/nexus-uv-cache" "$c11/locals/uv/cache"
dry_out=$(
    env -u UV_CACHE_DIR NEXUS_LOCALS="$c11/locals" NEXUS_STATE_DIR="$WORK/state11" \
        bash -c '
            set -uo pipefail
            source "$1" >/dev/null 2>&1
            DRY_RUN=1
            _recover_uv_cache_guard
        ' _ "$RECOVER" 2>&1
)
if [[ ! -e "$c11/scratch/nexus-uv-cache" ]]; then
    ok "(11) bootstrap-recover --dry-run creates nothing"
else
    bad "(11) dry-run purity" "the target was created under --dry-run"
fi
grep -q "would repair" <<<"$dry_out" \
    && ok "(11) dry-run reports 'would repair'" \
    || bad "(11) dry-run marker" "output: $dry_out"
# The marker must NOT match boot-recover's launch gate — a dangling cache
# alone should not trigger a full recovery sweep.
grep -qE 'would (relaunch|run|resume)' <<<"$dry_out" \
    && bad "(11) dry-run gate" "the marker matches boot-recover's launch gate" \
    || ok "(11) marker does not trip boot-recover's 'would (relaunch|run|resume)' gate"

# ---- (12) bootstrap-recover wiring: a real run repairs ---------------------
real_out=$(
    env -u UV_CACHE_DIR NEXUS_LOCALS="$c11/locals" NEXUS_STATE_DIR="$WORK/state11" \
        bash -c '
            set -uo pipefail
            source "$1" >/dev/null 2>&1
            DRY_RUN=0
            _recover_uv_cache_guard
        ' _ "$RECOVER" 2>&1
)
[[ -d "$c11/scratch/nexus-uv-cache" ]] \
    && ok "(12) bootstrap-recover repairs the cache on a real run" \
    || bad "(12) recover wiring" "target not created; output: $real_out"
grep -q "uv cache: repaired" <<<"$real_out" \
    && ok "(12) recovery logs the repair under its [recover] prefix" \
    || bad "(12) recover log" "output: $real_out"

# ---- (13) THE PROOF: real uv fails, then recovers --------------------------
if command -v uv >/dev/null 2>&1; then
    c13="$WORK/c13"; mkdir -p "$c13/locals/uv" "$c13/scratch"
    ln -s "$c13/scratch/nexus-uv-cache" "$c13/locals/uv/cache"

    before=$(UV_CACHE_DIR="$c13/locals/uv/cache" uv venv "$c13/venv-before" 2>&1)
    before_rc=$?
    if (( before_rc != 0 )); then
        ok "(13) real uv FAILS against the dangling symlink (rc=$before_rc)"
    else
        bad "(13) reproduction" "uv unexpectedly succeeded; the fault was not reproduced"
    fi
    grep -qF "File exists (os error 17)" <<<"$before" \
        && ok "(13) uv reports the incident's exact error: File exists (os error 17)" \
        || bad "(13) error text" "got: $before"

    rc=$(run_guard "$c13/locals/uv/cache" "$WORK/c13.err")
    assert_eq "(13) guard repairs it -> exit 10" "$rc" "10"

    after=$(UV_CACHE_DIR="$c13/locals/uv/cache" uv venv "$c13/venv-after" 2>&1)
    after_rc=$?
    if (( after_rc == 0 )); then
        ok "(13) the SAME uv command now SUCCEEDS (rc=0)"
    else
        bad "(13) recovery" "uv still fails after the guard: $after"
    fi
    [[ -f "$c13/locals/uv/cache/CACHEDIR.TAG" ]] \
        && ok "(13) uv populated the cache through the repaired symlink" \
        || bad "(13) cache population" "no CACHEDIR.TAG under the cache path"
else
    echo "  SKIP: (13) uv end-to-end — no uv on PATH"
fi

# ---- (14) labsh-supervised wiring ------------------------------------------
# The warm-restart path. bootstrap-recover only covers COLD BOOT; this
# supervisor restarts on its own long after any recovery sweep, and a purge can
# land in between.
if [[ -r "$LABSH" ]]; then
    grep -q 'uv-cache-guard.sh' "$LABSH" \
        && ok "(14) labsh-supervised sources the guard" \
        || bad "(14) labsh wiring" "uv-cache-guard.sh is not sourced"
    grep -q '^repair_uv_cache()' "$LABSH" \
        && ok "(14) labsh-supervised defines repair_uv_cache" \
        || bad "(14) labsh wiring" "repair_uv_cache is not defined"
    # The call must precede `labsh start` inside _start_cycle.
    call_line=$(grep -n '^ *repair_uv_cache  *#' "$LABSH" | head -1 | cut -d: -f1)
    start_line=$(grep -n '^ *labsh start --port' "$LABSH" | head -1 | cut -d: -f1)
    if [[ -n "$call_line" && -n "$start_line" ]] && (( call_line < start_line )); then
        ok "(14) repair_uv_cache is called before 'labsh start' (line $call_line < $start_line)"
    else
        bad "(14) labsh call site" "call=$call_line start=$start_line"
    fi
fi

# ---- (15) locals-env.sh stays PURE -----------------------------------------
# Review question 1 (#98): the guard deliberately does NOT live in
# locals-env.sh, whose header promises "no mkdir, no network, no writes" and
# whose own suite asserts it. This test pins the decision so a later change
# cannot quietly move the guard there.
grep -q 'uv-cache-guard' "$_test_dir/../locals-env.sh" \
    && bad "(15) locals-env purity" "locals-env.sh references the guard; it must stay side-effect-free" \
    || ok "(15) locals-env.sh does not call the guard (its no-side-effects contract holds)"

# ---- summary ---------------------------------------------------------------

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
