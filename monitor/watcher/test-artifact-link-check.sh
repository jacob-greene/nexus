#!/usr/bin/env bash
# Unit tests for the Artifact-only-body WARNING (your-org/nexus-code#1856):
# monitor/artifact-link-check.sh (the rule), its call in monitor/gh-shim.sh's
# gh() (every `gh` write carrying a body, including the explicit-GH_TOKEN form),
# and its calls in `ng reply` / `ng issue create`. The wrap-up arms are in
# test-ng-wrap-up.sh (Tests 12b/12c), beside the stub they need.
#
# Run: bash monitor/watcher/test-artifact-link-check.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Every POSITIVE (warns) is paired with a NEGATIVE that differs in one thing,
# so a check that warned on everything could not pass, and every warning case
# also asserts the write still HAPPENED with its argv/stdin untouched — the
# guard is a warning and must never become a block or a mutation.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
PASS=0
FAIL=0

LIB="$_test_dir/../artifact-link-check.sh"
SHIM="$_test_dir/../gh-shim.sh"
[[ -r "$LIB"  ]] || th_abort "artifact-link-check.sh missing at $LIB"
[[ -r "$SHIM" ]] || th_abort "gh-shim.sh missing at $SHIM"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ART='https://claude.ai/artifact/5d1e-plan'
ART_CODE='https://claude.ai/code/artifact/9f00-schematic'
ASSET='https://github.com/asset-org/assets/blob/abc1234/assets/42/plan.md'
ASSET_RAW='https://github.com/asset-org/assets/raw/abc1234/assets/42/fig.png'

# ---- L: the rule ----------------------------------------------------------
echo '=== L: alc_flags — the rule itself ==='
# shellcheck source=monitor/artifact-link-check.sh
. "$LIB"
alc_flags "plan: $ART";                        assert_eq "L1 artifact only → flagged"                 "$?" "0"
alc_flags "schematic: $ART_CODE";              assert_eq "L2 code/artifact only → flagged"            "$?" "0"
alc_flags "plan: $ART and $ASSET";             assert_eq "L3 artifact + blob asset → clean"           "$?" "1"
alc_flags "fig: $ART_CODE ![f]($ASSET_RAW)";   assert_eq "L4 artifact + raw asset → clean"            "$?" "1"
alc_flags "no links at all, just prose";       assert_eq "L5 no artifact → clean"                     "$?" "1"
alc_flags "see https://claude.ai/chat/xyz";    assert_eq "L6 a claude.ai CHAT link is not an Artifact" "$?" "1"
alc_flags "$ART https://github.com/o/r/blob/main/docs/x.md"
assert_eq "L7 a non-assets github blob does not count as a nexus asset" "$?" "0"
err=$(alc_warn "plan: $ART" "ng test" 2>&1 >/dev/null); rc=$?
assert_eq       "L8 alc_warn rc is 0 even when it warns" "$rc" "0"
assert_contains "L8 …names the issue"                     "$err" "your-org/nexus-code#1856"
assert_contains "L8 …names ng upload"                     "$err" "monitor/ng upload"
assert_contains "L8 …names where"                         "$err" "ng test"
err=$(alc_warn "plan: $ART $ASSET" "ng test" 2>&1 >/dev/null)
assert_eq "L9 alc_warn is silent on a clean body" "$err" ""

# ---- C: the CLI -------------------------------------------------------------
echo '=== C: CLI exit codes ==='
printf 'plan: %s\n' "$ART" > "$WORK/pos.md"
printf 'plan: %s\n%s\n' "$ART" "$ASSET" > "$WORK/neg.md"
bash "$LIB" "$WORK/pos.md" 2>/dev/null;          assert_eq "C1 flagged file → rc 3" "$?" "3"
bash "$LIB" "$WORK/neg.md" 2>/dev/null;          assert_eq "C2 clean file → rc 0"   "$?" "0"
bash "$LIB" - < "$WORK/pos.md" 2>/dev/null;      assert_eq "C3 flagged stdin → rc 3" "$?" "3"
bash "$LIB" "$WORK/missing.md" 2>/dev/null;      assert_eq "C4 unreadable → rc 2, never a silent clean" "$?" "2"

# ---- S: the gh shim, through the explicit-GH_TOKEN arm ----------------------
#
# A stub _ghs_realgh (the shim keeps a pre-existing definition) records argv
# and whatever arrives on stdin, so each case shows the call still went through
# UNCHANGED. GH_TOKEN is set: that is the form every write is told to use, and
# the arm that returns before any classification, so the scan must sit above it.
echo '=== S: gh-shim warns on Artifact-only bodies, passes every call through ==='
run_shim() {   # <stdin-file> <args...> ; sets SH_ERR SH_RC, writes $WORK/argv $WORK/stdin
    local in="$1"; shift
    SH_ERR=$(cd "$WORK" && env -u WATCHER_WINDOW GH_TOKEN=test-token NEXUS_ROOT="$(cd "$_test_dir/../.." && pwd)" \
        bash -c '
            _ghs_realgh() { printf "%s\n" "$*" > "$0/argv"; cat > "$0/stdin"; return 7; }
            . "$1"; shift; gh "$@"' "$WORK" "$SHIM" "$@" < "$in" 2>&1 >/dev/null)
    SH_RC=$?
}
: > "$WORK/empty"
run_shim "$WORK/empty" issue comment 5 --body "plan: $ART"
assert_contains "S1 --body artifact-only → WARNING"           "$SH_ERR" "your-org/nexus-code#1856"
assert_eq       "S1 the real gh's rc passes through (7)"       "$SH_RC" "7"
assert_eq       "S1 argv reached the real gh unchanged"        "$(cat "$WORK/argv")" "issue comment 5 --body plan: $ART"
run_shim "$WORK/empty" issue comment 5 --body "plan: $ART $ASSET"
assert_not_contains "S2 --body with an asset → no WARNING"     "$SH_ERR" "#1856"
run_shim "$WORK/empty" pr create --title t --body-file "$WORK/pos.md"
assert_contains "S3 --body-file artifact-only → WARNING"      "$SH_ERR" "#1856"
run_shim "$WORK/empty" pr create --title t --body-file "$WORK/neg.md"
assert_not_contains "S4 --body-file clean → no WARNING"        "$SH_ERR" "#1856"
run_shim "$WORK/empty" issue create --title t -F "$WORK/pos.md"
assert_contains "S5 -F <file> on issue create → WARNING"       "$SH_ERR" "#1856"
run_shim "$WORK/empty" api -X POST /repos/o/r/issues/5/comments -f "body=plan: $ART_CODE"
assert_contains "S6 gh api -f body= artifact-only → WARNING"  "$SH_ERR" "#1856"
run_shim "$WORK/empty" api -X POST /repos/o/r/issues/5/comments -f "title=plan: $ART_CODE"
assert_not_contains "S7 gh api -f on a NON-body field → no WARNING" "$SH_ERR" "#1856"
run_shim "$WORK/empty" api -X POST /repos/o/r/issues/5/comments -F "body=@$WORK/pos.md"
assert_contains "S8 gh api -F body=@file → WARNING"            "$SH_ERR" "#1856"
# The STDIN blind spot, stated and pinned: a body on stdin is NOT read, because
# reading it would consume what gh is about to send.
run_shim "$WORK/pos.md" issue comment 5 --body-file -
assert_not_contains "S9 --body-file - is NOT read (stated blind spot)" "$SH_ERR" "#1856"
assert_eq "S9 …and stdin reached the real gh intact" "$(cat "$WORK/stdin")" "$(cat "$WORK/pos.md")"
run_shim "$WORK/empty" issue view 5
assert_eq "S10 a read with no body says nothing" "$SH_ERR" ""

# ---- N: ng verbs (they post via `gh api --input -`, which the shim cannot read)
echo '=== N: ng reply / ng issue create warn before posting, and still post ==='
FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor/.state" "$FAKE_NEXUS/config" "$WORK/bin"
for f in ng _bookkeeping.sh _nexus-root.sh artifact-link-check.sh; do
    cp "$_test_dir/../$f" "$FAKE_NEXUS/monitor/$f"
done
printf '#!/usr/bin/env bash\ncase "${1:-}" in github.repo) printf default-org/default-repo ;; github.user_login) printf test-user ;; *) exit 2 ;; esac\n' \
    > "$FAKE_NEXUS/config/load.sh"
printf '#!/usr/bin/env bash\nprintf fake-installation-token\n' > "$FAKE_NEXUS/monitor/mint-token.sh"
chmod +x "$FAKE_NEXUS/config/load.sh" "$FAKE_NEXUS/monitor/mint-token.sh" "$FAKE_NEXUS/monitor/ng"
cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh-calls"
[ -t 0 ] || cat >> "$WORK/gh-stdin"
printf '%s' '{"html_url":"https://mock.example/posted","number":9}'
STUB
chmod +x "$WORK/bin/gh"
run_ng() {   # <args...> ; sets NG_ERR NG_RC
    : > "$WORK/gh-calls"; : > "$WORK/gh-stdin"
    NG_ERR=$(env -u NEXUS_ROOT -u NEXUS_WORKER_WINDOW -u GH_TOKEN \
        NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state" PATH="$WORK/bin:$PATH" \
        "$FAKE_NEXUS/monitor/ng" "$@" 2>&1 >/dev/null)
    NG_RC=$?
}
run_ng reply 5 --repo o/r --body-file "$WORK/pos.md"
assert_eq       "N1 ng reply exits 0 on an Artifact-only body" "$NG_RC" "0"
assert_contains "N1 …warns"                                    "$NG_ERR" "your-org/nexus-code#1856"
assert_contains "N1 …names the verb"                           "$NG_ERR" "ng reply #5"
assert_contains "N1 …and still POSTED the body"                "$(cat "$WORK/gh-stdin")" "5d1e-plan"
run_ng reply 5 --repo o/r --body-file "$WORK/neg.md"
assert_eq           "N2 ng reply with an asset exits 0"        "$NG_RC" "0"
assert_not_contains "N2 …and does not warn"                    "$NG_ERR" "#1856"
run_ng issue create --repo o/r --title t --body-file "$WORK/pos.md"
assert_contains "N3 ng issue create warns"                     "$NG_ERR" "ng issue create"
run_ng issue create --repo o/r --title t --body-file "$WORK/neg.md"
assert_not_contains "N4 ng issue create with an asset does not" "$NG_ERR" "#1856"

# ---- M: potency — the ng arm is the call, not a coincidence -------------------
echo '=== M: with _alc_warn neutered, N1 stops warning ==='
python3 - "$FAKE_NEXUS/monitor/ng" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '    _alc_warn "$_body" "ng reply #$issue"\n'
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, "    :\n"))
PY
run_ng reply 5 --repo o/r --body-file "$WORK/pos.md"
assert_not_contains "M1 killed: no call, no warning" "$NG_ERR" "#1856"

EXPECTED_ASSERTIONS=38
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
