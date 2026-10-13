#!/usr/bin/env bash
# test-host-pin-lint.sh — both directions of monitor/host-pin-lint.sh: no
# service declaration (services.registry row, Caddyfile, .deploy/endpoint) may
# pin a literal cluster node or a literal IPv4.
#
#   POSITIVE — one plant per pin shape, in every declaration file shape, in
#              BOTH modes (tracked, and --live over an untracked operator
#              tree). Each MUST be flagged.
#   NEGATIVE — the allowlisted addresses (127.0.0.1, 0.0.0.0, RFC 5737) and the
#              ordinary words that share the silhouette (python3, run2.sh,
#              release-2026-01-01, a version string). Each MUST NOT be flagged,
#              or the lint gets muted within a week.
#
# All hosts and addresses are SYNTHETIC (node01, example.org, 192.0.2.x for the
# negative, 10.x for the positive).
#
# Run: bash monitor/watcher/test-host-pin-lint.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LINT="$REPO_ROOT/monitor/host-pin-lint.sh"

# The population: what the lint reads in this repository, plus the lint itself.
_hpl_population() {
    bash "$LINT" --files "$REPO_ROOT"
    printf '%s\n' monitor/host-pin-lint.sh
}
. "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() { _hpl_population; }
gp_handle "$@"

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
T="$WORK/tree"

_mktree() {   # a fresh fixture repository with a clean registry row
    rm -rf "$T"
    mkdir -p "$T/monitor" "$T/work/proj/.deploy"
    git -C "$WORK" init -q tree
    th_require_fixture_repo "$T"
    printf 'svc\t$NEXUS_ROOT/work/proj\t./serve.sh\tcurl -fsS http://localhost:8765/\n' > "$T/monitor/services.registry.example"
    git -C "$T" add -A
    git -C "$T" -c user.email=t@t -c user.name=t commit -qm base
}
_plant() {   # <relpath> <line> — tracked
    _mktree
    mkdir -p "$(dirname "$T/$1")"
    printf '%s\n' "$2" > "$T/$1"
    git -C "$T" add -- "$1"
}
_scan() { OUT=$(bash "$LINT" "$@" 2>"$WORK/err"); RC=$?; }

# ---- POSITIVE: every pin shape, in every declaration file shape ----------
POS=(
    "registry row binds a literal node FQDN|monitor/services.registry.example|svc	/w	./serve.sh --host node87.example.org	curl -fsS http://localhost:1/"
    "registry healthcheck probes a literal IPv4|monitor/services.registry.example|svc	/w	./serve.sh	curl -fsS http://10.6.7.8:8765/"
    "Caddyfile site address is a node:port|Caddyfile|node87:27701 {"
    "Caddyfile bind is a literal IPv4|work/proj/Caddyfile|	bind 10.20.30.40"
    "Caddyfile proxies to a node FQDN|deploy/site.caddy|	reverse_proxy node12.cluster.example.org:8080"
    "endpoint URL names a bare node|work/proj/.deploy/endpoint|https://node87:27701/"
    "endpoint URL names a node FQDN|work/proj/.deploy/endpoint|https://node87.example.org/"
    "host variable assigned a node|monitor/services.registry.example|svc	/w	SVC_HOST=node87 ./serve.sh	true"
    "ssh to a node|monitor/services.registry.example|svc	/w	ssh hostb3 ./serve.sh	true"
)
for row in "${POS[@]}"; do
    IFS='|' read -r label rel line <<<"$row"
    _plant "$rel" "$line"
    _scan "$T"
    assert_rc "POSITIVE $label: rc 1" "$RC" 1
    assert_contains "POSITIVE $label: the site is named" "$OUT" "$rel:1:"
done

_plant work/proj/.deploy/endpoint "https://node87:27701/"
_scan "$T"
assert_contains "a finding names the start-time derivation remedy" "$OUT" "hostname -f"
assert_contains "a finding names the cockpit's resolver" "$OUT" "svc_fqdn"

_mktree
printf 'http://10.1.1.1:9/\n' > "$T/work/proj/.deploy/endpoint"     # never git-added
_scan "$T"
assert_contains "an UNTRACKED (not ignored) endpoint is in the tracked population" "$OUT" "work/proj/.deploy/endpoint:1:"

# ---- NEGATIVE: allowlisted addresses and look-alike words ----------------
NEG=(
    "svc	/w	./serve.sh --bind 127.0.0.1	curl -fsS http://localhost:8765/"
    "svc	/w	./serve.sh --bind 0.0.0.0	curl -fsS http://127.0.0.1:8765/"
    "svc	/w	./serve.sh --host 192.0.2.10	curl -fsS http://198.51.100.7:1/ http://203.0.113.9:2/"
    "svc	/w	python3 ./run2.sh --max-time 3	sha256sum x"
    "svc	\$NEXUS_ROOT/work/release-2026-01-01/abc2-site	./serve.sh	true"
    "svc	/w	uv pip install pkg==1.2.3.4.5	true"
    "svc	/w	./serve.sh	OLAY_HOST=127.0.0.1 tools/healthcheck.sh"
    "# a COMMENT naming node87.example.org and 10.1.2.3 is not a pin"
    "svc	/w	./serve.sh --bind 10.9.9.9	true  # host-pin-lint: allow (reviewed)"
)
for line in "${NEG[@]}"; do
    _plant monitor/services.registry.example "$line"
    _scan "$T"
    assert_rc "NEGATIVE not flagged: $line" "$RC" 0
done

_plant Caddyfile '{$SVC_HOST}:27701 {'
printf '\tbind {$SVC_BIND}\n\treverse_proxy 127.0.0.1:27711\n}\n' >> "$T/Caddyfile"
_scan "$T"
assert_rc "NEGATIVE a host-independent Caddyfile (env placeholders, loopback upstream) is clean" "$RC" 0

_mktree
printf 'Caddyfile\n' > "$T/.gitignore"
printf 'node87:1 {\n' > "$T/Caddyfile"
_scan "$T"
assert_rc "an IGNORED Caddyfile is outside the TRACKED population (that is what --live is for)" "$RC" 0

# ---- LIVE mode: the operator's untracked registry and workdirs -----------
# A primary's services.registry is gitignored and each service's .deploy/
# endpoint lives in its own project checkout, so --live reads the disk.
L="$WORK/live"
_mklive() {
    rm -rf "$L"
    mkdir -p "$L/monitor" "$L/work/proj/.deploy" "$L/work/grp/svc/.deploy"
    # A depth-2 workdir, named only by the registry: a work/* walk misses it.
    printf 'svc\t$NEXUS_ROOT/work/grp/svc\t./serve.sh\tcurl -fsS http://localhost:8765/\n' > "$L/monitor/services.registry"
    printf 'http://localhost:8765/\n' > "$L/work/grp/svc/.deploy/endpoint"
    printf 'http://localhost:8766/\n' > "$L/work/proj/.deploy/endpoint"
}
_mklive
_scan --live "$L"
assert_rc "LIVE a clean untracked tree is clean (rc 0)" "$RC" 0
_scan --live --files "$L"
assert_contains "LIVE population includes the untracked registry" "$OUT" "monitor/services.registry"
assert_contains "LIVE population reaches a depth-2 workdir through the registry" "$OUT" "work/grp/svc/.deploy/endpoint"
assert_contains "LIVE population includes work/*/.deploy/endpoint" "$OUT" "work/proj/.deploy/endpoint"

_mklive
printf 'https://node87.example.org:27701/\n' > "$L/work/grp/svc/.deploy/endpoint"
_scan --live "$L"
assert_rc "LIVE POSITIVE a pinned endpoint in a registry-named depth-2 workdir: rc 1" "$RC" 1
assert_contains "LIVE POSITIVE the site is named" "$OUT" "work/grp/svc/.deploy/endpoint:1:"

_mklive
printf 'svc2\t/w\t./serve.sh --bind 10.4.4.4\ttrue\n' >> "$L/monitor/services.registry"
_scan --live "$L"
assert_rc "LIVE POSITIVE a pinned row in the untracked registry: rc 1" "$RC" 1

_mklive
printf 'node87:1 {\n' > "$L/work/proj/Caddyfile"
_scan --live "$L"
assert_rc "LIVE POSITIVE a pinned work/*/Caddyfile: rc 1" "$RC" 1

_mklive
chmod 000 "$L/work/proj/.deploy/endpoint"
if [[ -r "$L/work/proj/.deploy/endpoint" ]]; then
    th_skip "LIVE an unreadable declaration" "a mode-000 file is still readable here (root or an ACL), so no unreadable input can be planted"
else
    _scan --live "$L"
    assert_rc "LIVE an UNREADABLE declaration is UNCHECKED and refuses a green (rc 3)" "$RC" 3
fi
chmod 600 "$L/work/proj/.deploy/endpoint"

# ---- refusals ------------------------------------------------------------
_mktree
_scan "$T/monitor"
assert_rc "TRACKED mode on a dir that is NOT its repository's top is refused (rc 3)" "$RC" 3

# ---- the real tree -------------------------------------------------------
OUT=$(bash "$LINT" "$REPO_ROOT" 2>&1); RC=$?
assert_rc "the real tree is clean (rc 0)" "$RC" 0
[[ $RC == 0 ]] || printf '%s\n' "$OUT" >&2
_n_pop=$(bash "$LINT" --files "$REPO_ROOT" | grep -c .)
assert_eq "the real-tree population is non-empty (the registry template at least; got $_n_pop)" \
    "$(( _n_pop >= 1 ? 1 : 0 ))" "1"

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact).
EXPECTED=44
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
