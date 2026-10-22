#!/usr/bin/env bash
# test-recover-service-gh-env.sh — a service relaunched by recovery starts in
# the SAME gh environment as one started from an agent shell
# (your-org/nexus-code#1764).
#
# THE DEFECT. `svc.sh up` IS bootstrap-recover.sh and `svc.sh start` calls
# `_recover_launch_service`, so the launch code was already shared — but the
# supervisor inherited its CALLER's environment. From an agent shell that is
# locals-env.sh's full env; from a cold-boot trigger it is whatever that process
# had. A deploy watch relaunched after a sandbox restart failed every
# `git fetch` (gh credential helper: no config) for ~4 h, health GREEN.
#
# WHAT THIS PINS, against the REAL `_recover_launch_service` with a stub service
# that records its own environment (a short-lived script, never a real service,
# never the live registry, never the primary's .state):
#
#   S  svc.sh-shaped caller: locals-env.sh already sourced. The REFERENCE, and a
#      control that must hold on every tree.
#   B  the INCIDENT shape: GH_CONFIG_DIR already scoped to the credential-free
#      dir and NEXUS_GH_CONFIG_SCOPED inherited, but the gh wrapper NOT on PATH,
#      so a bare `gh` (what the credential helper runs) is the real binary
#      reading a config dir with no credentials in it.
#   A  a STRIPPED boot env: `env -i` with only PATH, HOME and XDG_CONFIG_HOME.
#
# For B and A the service must see what S sees: GH_CONFIG_DIR scoped, `gh`
# resolving to the wrapper, and the shim's own operator-config resolver
# (`_ghs_opdir`, what `gh auth …` uses) naming the operator's config dir.
#
# Run: bash monitor/watcher/test-recover-service-gh-env.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SRC="$REPO_ROOT/monitor/bootstrap-recover.sh"
. "$_test_dir/_test_helpers.sh"
[[ -r "$SRC" ]] || th_abort "missing $SRC"
[[ -r "$REPO_ROOT/monitor/locals-env.sh" ]] || th_abort "missing monitor/locals-env.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' 'monitor/bootstrap-recover.sh' 'monitor/locals-env.sh' 'monitor/gh-shim.sh' 'monitor/svc.sh'
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-recover-ghenv-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/wd" "$WORK/realbin" "$WORK/xdg/gh" "$WORK/home"

# A stand-in for the real gh binary, so `command -v gh` has something to find
# behind the wrapper. Never executed by this suite.
printf '#!/bin/sh\necho "fake real gh: $*"\n' > "$WORK/realbin/gh"
chmod +x "$WORK/realbin/gh"

# The stub service: record the env a git credential helper would run under —
# `sh -c` resolves `gh` by PATH exactly as `!f(){ … gh auth token; }` does —
# and the operator-config dir gh-shim.sh would restore for `gh auth …`. Then a
# short sleep and exit: nothing outlives the suite.
cat > "$WORK/wd/record.sh" <<'S'
#!/usr/bin/env bash
out="$1"
{
    printf 'GH_CONFIG_DIR=%s\n' "${GH_CONFIG_DIR:-}"
    printf 'SCOPED=%s\n' "${NEXUS_GH_CONFIG_SCOPED:-}"
    printf 'GH=%s\n' "$(sh -c 'command -v gh' 2>/dev/null)"
    printf 'OPDIR=%s\n' "$(sh -c '. "$1"; _ghs_opdir' _ "$2" 2>/dev/null)"
} > "$out.tmp" && mv -f "$out.tmp" "$out"
sleep 1
S
chmod +x "$WORK/wd/record.sh"

# _launch <arm> <env-prefix…> — run the REAL launch helper under the given env,
# then wait (bounded) for the stub's record.
_launch() {
    local arm="$1"; shift
    local rec="$WORK/rec-$arm" i
    "$@" bash -c '
        source "$1" >/dev/null 2>&1 || exit 97
        _recover_launch_service "svc-$2" "$3/wd" "$3/wd/record.sh $3/rec-$2 $4/monitor/gh-shim.sh" "$3/svc-$2.log" >/dev/null 2>&1
    ' _ "$SRC" "$arm" "$WORK" "$REPO_ROOT"
    for ((i = 0; i < 100; i++)); do [[ -s "$rec" ]] && break; sleep 0.1; done
}
_val() { sed -n "s/^$2=//p" "$WORK/rec-$1" 2>/dev/null; }

STATE="$WORK/state"; mkdir -p "$STATE/services"
BASEPATH="$WORK/realbin:/usr/bin:/bin"
COMMON=(NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$STATE" HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/xdg")
SCOPED_DIR="$REPO_ROOT/monitor/.state/gh-config"
WRAP="$REPO_ROOT/monitor/ghwrap/gh"

# ── S: the svc.sh-from-an-agent-shell reference ─────────────────────────────
# locals-env.sh is sourced in the CALLER, as an agent shell has it.
env -i "${COMMON[@]}" PATH="$BASEPATH" bash -c '
    . "$1/monitor/locals-env.sh"
    source "$2" >/dev/null 2>&1 || exit 97
    _recover_launch_service svc-S "$3/wd" "$3/wd/record.sh $3/rec-S $1/monitor/gh-shim.sh" "$3/svc-S.log" >/dev/null 2>&1
' _ "$REPO_ROOT" "$SRC" "$WORK"
for ((i = 0; i < 100; i++)); do [[ -s "$WORK/rec-S" ]] && break; sleep 0.1; done
assert_file_exists "S: the stub service ran and recorded its env" "$WORK/rec-S"
assert_eq "S (reference): GH_CONFIG_DIR is the scoped credential-free dir" "$(_val S GH_CONFIG_DIR)" "$SCOPED_DIR"
assert_eq "S (reference): a bare gh resolves to the nexus wrapper" "$(_val S GH)" "$WRAP"
assert_eq "S (reference): the shim restores the operator's config for gh auth" "$(_val S OPDIR)" "$WORK/xdg/gh"

# ── B: the incident shape — scoped config, no wrapper on PATH ────────────────
_launch B env -i "${COMMON[@]}" PATH="$BASEPATH" \
    GH_CONFIG_DIR="$SCOPED_DIR" NEXUS_GH_CONFIG_SCOPED=1
assert_file_exists "B: the stub service ran and recorded its env" "$WORK/rec-B"
assert_eq "B (scoped, unwrapped caller): a bare gh resolves to the wrapper, not the real binary" "$(_val B GH)" "$WRAP"
assert_eq "B: the shim restores the operator's config for gh auth" "$(_val B OPDIR)" "$WORK/xdg/gh"
assert_eq "B: GH_CONFIG_DIR matches the reference" "$(_val B GH_CONFIG_DIR)" "$(_val S GH_CONFIG_DIR)"

# ── A: a stripped boot env ───────────────────────────────────────────────────
_launch A env -i "${COMMON[@]}" PATH="$BASEPATH"
assert_file_exists "A: the stub service ran and recorded its env" "$WORK/rec-A"
assert_eq "A (stripped boot env): GH_CONFIG_DIR matches the reference" "$(_val A GH_CONFIG_DIR)" "$(_val S GH_CONFIG_DIR)"
assert_eq "A: NEXUS_GH_CONFIG_SCOPED is set, as in the reference" "$(_val A SCOPED)" "$(_val S SCOPED)"
assert_eq "A: a bare gh resolves to the wrapper" "$(_val A GH)" "$WRAP"
assert_eq "A: the shim restores the operator's config for gh auth" "$(_val A OPDIR)" "$WORK/xdg/gh"

# THE ASSERTION TOTAL IS EXACT: an assertion that silently stops running (a
# section that aborted, a loop over an empty set) is a red, not a smaller green.
EXPECTED=13
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: assertion census %d != EXPECTED %d — an assertion did not run, or one was added without updating EXPECTED\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
