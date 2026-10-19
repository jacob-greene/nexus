#!/usr/bin/env bash
# test-svc-boot-starting.sh — a service that recovery has JUST relaunched, and
# whose healthcheck has not passed yet, reads `STARTING` in `svc.sh status`,
# never `DOWN`.
#
# THE INCIDENT (2026-10-12, four sandbox restarts). myviewer, jupyterlab,
# svc-a and nexus-remote-ssh "came back DOWN" after every restart
# and were restarted by hand each time. Recovery had NOT missed them:
# bootstrap-recover.sh relaunched every one (fresh pid records, live
# supervisors, their logs show them binding). But it brings the ORCHESTRATOR up
# first and the services after, so the resumed orchestrator's first
# `svc.sh status` sampled them seconds after launch, before their healthchecks
# could pass, and the table printed the red `DOWN` it prints for a dead
# service. The hand restart then killed a warm-up that was about to succeed.
#
# THIS SUITE REPRODUCES THAT SEQUENCE, END TO END, IN A FIXTURE. The real
# bootstrap-recover.sh (`--services-only --no-workers`) launches a stub
# supervisor from a fixture registry; the stub becomes healthy only after a
# few seconds (it creates `ready`), like a real slow starter. `svc.sh status`
# is run immediately after the launch returns, exactly when the orchestrator
# ran it.
#
# Cases and why:
#   B1  just launched, live supervisor, healthcheck not yet passing → STARTING
#       (the defect: base prints DOWN), with the "do not restart" detail
#   B2  the same row once the grace has elapsed (SVC_STARTUP_GRACE_SECONDS=0)
#       → DOWN: a supervisor that never brings its service up is still flagged
#   B3  the same row once the stub is serving → UP (the warm-up completes on
#       its own; no restart was needed). Sampled only after the stub is SEEN
#       serving, and while it is held serving (#1822: it used to linger ~3 s
#       and exit on its own, and a loaded `svc.sh status` sampled after that)
#   N1  failing healthcheck with NO supervisor record → DOWN (STARTING requires
#       a LIVE supervisor; an unmanaged dead service is not "starting")
#   N2  failing healthcheck with a DEAD supervisor record → DOWN, `stale`
#
# The stub exits when the test drops `stop`, when its workdir disappears (the
# EXIT trap removes it), or at a ~60 s ceiling, whichever is first, so this
# suite never leaves a setsid child behind (proc-kill-authorized refuses setsid
# session leaders by design, so a harness should not create long-lived ones).
# Synthetic names only.
#
# Run: bash monitor/watcher/test-svc-boot-starting.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SVC="$_dir/../svc.sh"
RECOVER="$_dir/../bootstrap-recover.sh"

W=$(mktemp -d)
trap ': > "$W/slow/stop" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/root/monitor/.state" "$W/tmx" "$W/slow" "$W/nosup" "$W/dead"

# A slow starter under the TEST's control, in both directions: it stays
# not-ready until the test drops `go`, then is healthy (`ready`) until the test
# drops `stop`. No phase ends on a timer the host's speed decides (#1822: a
# ~3 s serving window ran out inside a loaded `svc.sh status`, which then read
# the dead supervisor as DOWN). Both waits share one ~60 s ceiling and end
# early if the workdir is gone, so it can never outlive the suite by much.
# Must NOT exec away: the supervisor probe matches the launch token against
# the live cmdline.
cat > "$W/slow/stub-supervised.sh" <<'S'
#!/usr/bin/env bash
rm -f ready
end=$(( SECONDS + 60 ))
while [[ ! -f go && -e "$PWD" ]] && (( SECONDS < end )); do sleep 0.1; done
: > ready
while [[ ! -f stop && -e "$PWD" ]] && (( SECONDS < end )); do sleep 0.1; done
rm -f ready
S
chmod +x "$W/slow/stub-supervised.sh"
cp "$W/slow/stub-supervised.sh" "$W/nosup/stub-supervised.sh"
cp "$W/slow/stub-supervised.sh" "$W/dead/stub-supervised.sh"

REG="$W/registry"
printf '%s\t%s\t%s\t%s\n' \
    slowsvc  "$W/slow"  ./stub-supervised.sh 'test -f ready' \
    nosupsvc "$W/nosup" ./stub-supervised.sh 'test -f ready' \
    deadsvc  "$W/dead"  ./stub-supervised.sh 'test -f ready' \
    > "$REG"

fixture_env=(env -u TMUX TMUX_TMPDIR="$W/tmx" NEXUS_ROOT="$W/root"
             NEXUS_STATE_DIR="$W/root/monitor/.state" NEXUS_SERVICES_REGISTRY="$REG")

run_status() {   # [VAR=value ...] → sets OUT RC
    "${fixture_env[@]}" "$@" timeout 120 bash "$SVC" status > "$W/out" 2> "$W/err"
    RC=$?
    OUT=$(<"$W/out")
}
row() { grep -E "^ *[0-9-]+ +$1 " <<<"$OUT"; }
word() { row "$1" | awk '{print $3}'; }   # the STATUS column only

# A dead supervisor record for deadsvc: a pid that is certainly not running
# (a finished child of this shell), in the production record format.
mkdir -p "$W/root/monitor/.state/services"
true & dead_pid=$!; wait "$dead_pid" 2>/dev/null
printf '%s\nns=%s\nstart=%s\n' "$dead_pid" "$(readlink /proc/$$/ns/pid)" 1 \
    > "$W/root/monitor/.state/services/deadsvc.pid"

echo '=== the boot sequence: recovery relaunches, status samples at once ==='
# Only slowsvc is in the registry recovery sees — nosupsvc must stay
# unsupervised and deadsvc must keep its dead record.
printf '%s\t%s\t%s\t%s\n' slowsvc "$W/slow" ./stub-supervised.sh 'test -f ready' > "$W/registry-boot"
"${fixture_env[@]}" NEXUS_SERVICES_REGISTRY="$W/registry-boot" \
    timeout 60 bash "$RECOVER" --services-only --no-workers > "$W/recover.log" 2>&1
rec_rc=$?
assert_rc       "recovery ran (rc 0)"                              "$rec_rc" 0
assert_contains "recovery RELAUNCHED the service (it was not missed)" "$(<"$W/recover.log")" "service 'slowsvc': relaunched headless"
run_status
assert_contains "B1 just-relaunched, not yet healthy → STARTING"   "$(row slowsvc)" "STARTING"
assert_eq       "B1 …the STATUS word is STARTING, not the DOWN that invited a restart" "$(word slowsvc)" "STARTING"
assert_contains "B1 …the detail says not to restart it"           "$(row slowsvc)" "do not restart"
assert_contains "B1 …and its supervisor is named live"            "$(row slowsvc)" "pid:"
assert_eq       "N1 failing check, NO supervisor record → DOWN"   "$(word nosupsvc)" "DOWN"
assert_eq       "N2 failing check, DEAD supervisor record → DOWN" "$(word deadsvc)" "DOWN"
assert_contains "N2 …with a stale supervisor cell"                "$(row deadsvc)" "stale"

echo '=== past the startup grace the same row is DOWN again ==='
run_status SVC_STARTUP_GRACE_SECONDS=0
assert_eq       "B2 grace elapsed → DOWN (a never-healthy service is still flagged)" "$(word slowsvc)" "DOWN"
assert_not_contains "B2 …and no STARTING detail"                  "$(row slowsvc)" "STARTING"

echo '=== left alone, the warm-up completes ==='
# Wait on the stub's OWN serving state (`ready`, which is its healthcheck), with
# a ceiling, and say so when it never came: then B3 has not been tested, which
# is not the same as B3 failing. The stub keeps serving until `stop`, so the
# status below samples a serving service however long it takes to run.
: > "$W/slow/go"
for _ in $(seq 1 100); do [[ -f "$W/slow/ready" ]] && break; sleep 0.1; done
assert_eq       "fixture precondition: the stub is serving before status samples it" "$([[ -f "$W/slow/ready" ]] && echo yes)" "yes"
run_status
assert_eq       "B3 the stub finished starting → UP, no restart needed" "$(word slowsvc)" "UP"

# Release the stub and let it exit before the trap removes its workdir.
: > "$W/slow/stop"
for _ in $(seq 1 120); do [[ -f "$W/slow/ready" ]] || break; sleep 0.1; done

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact).
EXPECTED=13
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
