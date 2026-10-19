#!/usr/bin/env bash
# A cc-update block caused by a STALE CHECKOUT is not filed on the
# implementation repo; the operator is told to pull instead
# (your-org/nexus-code#1855).
#
# THE DEFECT. Seven open "cc-update blocked" issues on the shared
# implementation repo came from other operators' installs whose clones were
# 378-496 commits behind their integration branch, all on one red scenario
# fixed weeks earlier. The fix was one pull away; the shared repo was told
# instead of the operator.
#
# WHAT IS CHECKED, on planted fixture repos (a bare "upstream" plus a clone
# that has not pulled), driving the REAL `cc-auto-update-apply.sh`:
#   S1  stale clone + the red scenario changed upstream → `stale-check` exits
#       20; `block` (no --issue) holds with contract=stale-checkout, files NO
#       issue (the defect-filer seam is never called, no `ng` is invoked) and
#       sends ONE operator notice carrying the pull command.
#   S2  a second identical `block` → NO second notice (dedupe).
#   S3  a helper the scenario SOURCES changed upstream (scenario blob equal)
#       → still stale (the depth-one dependency arm).
#   S4  channel: a tracking issue on the operator's OWN repo is used; one on
#       the implementation repo is NOT (notify.sh instead).
#   N1  the red persists upstream (only an unrelated file changed) →
#       `stale-check` 0 (unchanged-upstream), and `block` takes today's path:
#       the full COMPAT contract holds (class=compat, no stale contract), and
#       an evidence-less block files its defect as before. No notice.
#   N2  no upstream commit available (fetch fails, tracking ref absent) →
#       not stale (no-upstream-ref), today's behaviour.
#   N3  a changelog/probe block (no gate scenario) is never stale.
#
# Run: bash monitor/watcher/test-cc-auto-update-stale-checkout.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
APPLY="$_repo_root/monitor/cc-auto-update-apply.sh"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
export NEXUS_NOTIFY_QUIET=1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-stale.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

SCEN="test-realmodel-fixture-red"
SCEN_PATH="monitor/watcher/test-integration/$SCEN.sh"
HELPER_PATH="monitor/watcher/_fixture_helper.sh"

_g() { git -c user.name=fixture -c user.email=fixture@invalid -c init.defaultBranch=dev "$@"; }

# mk_case <name> <what-upstream-changes: scenario|helper|unrelated|none>
#   → prints the clone root (NEXUS_ROOT). Upstream gets one more commit than
#   the clone; the clone has NOT fetched it.
mk_case() {
    local name="$1" what="$2" base="$WORK/$1"
    mkdir -p "$base"
    _g init -q --bare "$base/up.git"
    _g init -q "$base/seed"
    th_require_fixture_repo "$base/seed" "seed repo"
    mkdir -p "$base/seed/monitor/watcher/test-integration"
    cat > "$base/seed/$SCEN_PATH" <<'EOF'
#!/usr/bin/env bash
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_fixture_helper.sh"
exit 1
EOF
    printf 'helper() { :; }\n' > "$base/seed/$HELPER_PATH"
    printf 'unrelated v1\n' > "$base/seed/unrelated.txt"
    _g -C "$base/seed" checkout -q -b dev 2>/dev/null
    _g -C "$base/seed" add -A
    _g -C "$base/seed" commit -q -m base
    _g -C "$base/seed" push -q "$base/up.git" dev 2>/dev/null
    _g clone -q -b dev "$base/up.git" "$base/root" 2>/dev/null
    th_require_fixture_repo "$base/root" "clone root"
    case "$what" in
        scenario)  printf '# fixed upstream\nexit 0\n' >> "$base/seed/$SCEN_PATH" ;;
        helper)    printf 'helper() { true; }\n' > "$base/seed/$HELPER_PATH" ;;
        unrelated) printf 'unrelated v2\n' > "$base/seed/unrelated.txt" ;;
        none)      : ;;
    esac
    if [[ "$what" != none ]]; then
        _g -C "$base/seed" commit -q -am "upstream change: $what"
        _g -C "$base/seed" push -q "$base/up.git" dev 2>/dev/null
    fi
    # The live tree the #1002 assertion reads: effective pin = floor.
    local root="$base/root"
    mkdir -p "$root/monitor/.state" "$root/node_modules/.bin" "$root/monitor"
    printf '{ "dependencies": { "@anthropic-ai/claude-code": "2.1.150" } }\n' > "$root/package.json"
    printf '#!/usr/bin/env bash\necho "2.1.150 (Claude Code)"\n' > "$root/node_modules/.bin/claude"
    chmod +x "$root/node_modules/.bin/claude"
    # Recorders: an `ng` that must never run, the defect filer's issue seam,
    # and the operator-notice seam. One log line per call.
    printf '#!/usr/bin/env bash\necho "ng $*" >> "%s/calls.log"\nexit 0\n' "$base" > "$root/monitor/ng"
    printf '#!/usr/bin/env bash\necho "gate-issue $1" >> "%s/calls.log"\necho 1\n' "$base" > "$base/gate-issue"
    printf '#!/usr/bin/env bash\necho "operator-notice $1 $2" >> "%s/calls.log"\ncat "$3" >> "%s/notices.txt"\nexit 0\n' "$base" "$base" > "$base/notice"
    chmod +x "$root/monitor/ng" "$base/gate-issue" "$base/notice"
    : > "$base/calls.log"
    printf '%s' "$root"
}

# run_apply <root> <verb> [args…] — the real script, every external seam
# pointed into the fixture; rc in $RC, combined output in $OUT.
run_apply() {
    local root="$1"; shift
    local base; base=$(dirname "$root")
    OUT=$(env -u MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE -u MONITOR_REPO \
        NEXUS_ROOT="$root" NEXUS_STATE_DIR="$root/monitor/.state" \
        MONITOR_INTEGRATION_BRANCH=dev \
        CC_AUTO_CLAUDE_BIN="$root/node_modules/.bin/claude" \
        CC_AUTO_GATE_ISSUE_CMD="$base/gate-issue" \
        CC_AUTO_OPERATOR_NOTIFY_CMD="$base/notice" \
        _CLONE_DRIFT_RETRY_PAUSE_SECONDS=0 \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        bash "$APPLY" "$@" 2>&1)
    RC=$?
}
EXTRA_ENV=()
ncalls() { awk -v p="$2" 'index($0,p)==1{n++} END{print n+0}' "$1/calls.log"; }
lastrow() { grep $'\tblock' "$1/monitor/.state/cc-auto-update/decisions.tsv" 2>/dev/null | tail -n1; }
contains() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

STALE_ARGS=(--candidate 2.1.160 --evidence "gate:$SCEN" --control "2.1.150: passed" --reason "gate RED on $SCEN")

echo "=== S1: stale clone, red scenario changed upstream ==="
R=$(mk_case s1 scenario) || exit $?; B=$(dirname "$R")
run_apply "$R" stale-check --candidate 2.1.160 --evidence "gate:$SCEN"
assert_rc "S1 stale-check exits 20 (STALE-CHECKOUT)" "$RC" 20
assert_eq "S1 stale-check names the changed scenario" "$(contains "$OUT" "changed=$SCEN_PATH")" yes
assert_eq "S1 stale-check records nothing and notifies nobody" "$(wc -l < "$B/calls.log" | tr -d ' ')" 0
run_apply "$R" block "${STALE_ARGS[@]}"
assert_rc "S1 block (no --issue) exits 0 — a recorded hold" "$RC" 0
row=$(lastrow "$R")
assert_eq "S1 row is a stale-checkout hold" "$(contains "$row" $'\tblock\tclass=compat contract=stale-checkout')" yes
assert_eq "S1 row carries stale_checkout=stale-checkout" "$(contains "$row" "stale_checkout=stale-checkout")" yes
assert_eq "S1 NO issue filed by the defect filer" "$(ncalls "$B" gate-issue)" 0
assert_eq "S1 NO ng invoked (nothing posted anywhere by ng)" "$(ncalls "$B" 'ng ')" 0
assert_eq "S1 exactly ONE operator notice" "$(ncalls "$B" operator-notice)" 1
assert_eq "S1 notice went to notify (no own tracking issue configured)" "$(ncalls "$B" 'operator-notice notify')" 1
assert_eq "S1 notice carries the one pull command" \
    "$(contains "$(cat "$B/notices.txt")" "git -C $R pull --ff-only origin dev")" yes
assert_eq "S1 notice is one sentence plus the command (3 lines)" "$(wc -l < "$B/notices.txt" | tr -d ' ')" 3

echo "=== S2: dedupe — same HEAD, same verdict ==="
run_apply "$R" block "${STALE_ARGS[@]}"
assert_rc "S2 second block exits 0" "$RC" 0
assert_eq "S2 NO second operator notice" "$(ncalls "$B" operator-notice)" 1
assert_eq "S2 says it was deduped" "$(contains "$OUT" "already told about this verdict")" yes
# Catch-up-then-fall-behind: a pull moves HEAD, so the key changes. Simulated
# by a local commit (HEAD moves; still behind upstream).
_g -C "$R" commit -q --allow-empty -m "local"
run_apply "$R" block "${STALE_ARGS[@]}"
assert_eq "S2 a moved HEAD re-notifies" "$(ncalls "$B" operator-notice)" 2

echo "=== S3: only a sourced helper changed upstream ==="
R=$(mk_case s3 helper) || exit $?; B=$(dirname "$R")
run_apply "$R" stale-check --candidate 2.1.160 --evidence "gate:$SCEN"
assert_rc "S3 stale-check exits 20 on a changed helper" "$RC" 20
assert_eq "S3 the changed file named is the helper" "$(contains "$OUT" "changed=$HELPER_PATH")" yes

echo "=== S4: channel selection ==="
R=$(mk_case s4a scenario) || exit $?; B=$(dirname "$R")
EXTRA_ENV=(MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE="op-org/op-nexus#5" MONITOR_REPO="op-org/op-nexus")
run_apply "$R" block "${STALE_ARGS[@]}"
assert_eq "S4 own-repo tracking issue is the channel" "$(ncalls "$B" 'operator-notice issue op-org/op-nexus#5')" 1
R=$(mk_case s4b scenario) || exit $?; B=$(dirname "$R")
EXTRA_ENV=(MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE="your-org/nexus-code#229" MONITOR_REPO="your-org/nexus-code")
run_apply "$R" block "${STALE_ARGS[@]}"
assert_eq "S4 a tracking issue on the implementation repo is NOT used" "$(ncalls "$B" 'operator-notice issue')" 0
assert_eq "S4 …notify.sh is used instead" "$(ncalls "$B" 'operator-notice notify')" 1
EXTRA_ENV=()

echo "=== N1: red persists upstream (only an unrelated file changed) ==="
R=$(mk_case n1 unrelated) || exit $?; B=$(dirname "$R")
run_apply "$R" stale-check --candidate 2.1.160 --evidence "gate:$SCEN"
assert_rc "N1 stale-check exits 0 (not stale)" "$RC" 0
assert_eq "N1 reason is unchanged-upstream" "$(contains "$OUT" "stale_reason=unchanged-upstream:$SCEN")" yes
run_apply "$R" block "${STALE_ARGS[@]}" --issue your-org/nexus-code#1
assert_rc "N1 full-contract block holds as today (rc 0)" "$RC" 0
row=$(lastrow "$R")
assert_eq "N1 row is today's COMPAT hold, not a stale one" "$(contains "$row" $'\tblock\tclass=compat evidence=')" yes
assert_eq "N1 no operator notice" "$(ncalls "$B" operator-notice)" 0
run_apply "$R" block --candidate 2.1.160 --reason "gate could not run"
assert_rc "N1 evidence-less block exits 12 as today" "$RC" 12
assert_eq "N1 …and files its defect as today" "$(ncalls "$B" gate-issue)" 1

echo "=== N2: no upstream commit available ==="
R=$(mk_case n2 scenario) || exit $?; B=$(dirname "$R")
# The refs-only fetch fails (network), the clone has no tracking ref for dev,
# and the live tip is therefore NOT a local object: the probe measures the
# margin through the compare API instead (stubbed: the origin URL is read as a
# GitHub slug, the API answers "1 ahead"). The clone is measured BEHIND, and
# the classifier has no upstream commit to compare against.
mkdir -p "$B/bin"
cat > "$B/bin/timeout" <<'EOF2'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == fetch ]] && exit 1; done
exec /usr/bin/timeout "$@"
EOF2
cat > "$B/bin/drift-git" <<'EOF2'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == get-url ]] && { echo https://github.com/fixture-org/fixture-repo.git; exit 0; }; done
exec git "$@"
EOF2
cat > "$B/bin/drift-gh" <<'EOF2'
#!/usr/bin/env bash
echo '{"ahead_by":1,"behind_by":0,"status":"ahead","commits":[]}'
EOF2
chmod +x "$B/bin/timeout" "$B/bin/drift-git" "$B/bin/drift-gh"
git -C "$R" update-ref -d refs/remotes/origin/dev
EXTRA_ENV=(PATH="$B/bin:$PATH" _CLONE_DRIFT_GIT_BIN="$B/bin/drift-git" _CLONE_DRIFT_GH_BIN="$B/bin/drift-gh")
run_apply "$R" stale-check --candidate 2.1.160 --evidence "gate:$SCEN"
EXTRA_ENV=()
assert_rc "N2 stale-check exits 0 (cannot look ⇒ not stale)" "$RC" 0
assert_eq "N2 reason is no-upstream-ref" "$(contains "$OUT" "stale_reason=no-upstream-ref")" yes
assert_eq "N2 the clone WAS measured behind (the arm under test ran)" "$(contains "$OUT" "drift=behind")" yes

echo "=== N3: a probe block names no scenario ==="
R=$(mk_case n3 scenario) || exit $?; B=$(dirname "$R")
run_apply "$R" stale-check --candidate 2.1.160 --evidence "probe:/nonexistent"
assert_rc "N3 stale-check exits 0" "$RC" 0
assert_eq "N3 reason is no-failing-scenario" "$(contains "$OUT" "stale_reason=no-failing-scenario")" yes

_EXPECTED_ASSERTIONS=33   # count=exact (summary-honesty): every assertion above, once
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
