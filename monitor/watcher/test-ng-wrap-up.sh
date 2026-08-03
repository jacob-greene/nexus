#!/usr/bin/env bash
# Unit tests for `ng wrap-up` (cmd_wrap_up in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-wrap-up.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy mirrors test-ng-reply-repo.sh:
#   - Build a minimal nexus tree under a temp dir (ng + stubbed
#     config/load.sh + stubbed mint-token.sh + a stubbed
#     upload-asset.sh that records its argv and prints a canned URL
#     unless $MOCK_UPLOAD_FAIL is set).
#   - PATH-shadow `gh` to record the POST/reaction endpoints and
#     return canned JSON, with toggles to simulate per-step failure.
#
# Each test resets the mocks and capture file, runs `ng wrap-up`,
# and asserts both the stdout step-status lines and the captured
# side-effects against the four-step contract:
#   1. upload report
#   2. post templated comment (skipped if upload failed)
#   3. rocket trigger comment (skipped if --trigger-comment absent)
#   4. log-action wrap-up

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_file() { assert_file_exists "$@"; }
assert_not_file() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — unexpected file: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config" "$FAKE_NEXUS/reports"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"
STATE_DIR="$FAKE_NEXUS/monitor/.state"

# The spawn-skeptic request-filing step (your-org/nexus-code#545) shells out
# to $_script_dir/request-channel.sh (+ its libs). Provide the REAL scripts
# in the fake monitor dir so cmd_wrap_up can file a request into $STATE_DIR.
for _dep in request-channel.sh _channel_lib.sh _fm_lib.sh; do
    cp "$_test_dir/../$_dep" "$FAKE_NEXUS/monitor/$_dep"
done
chmod +x "$FAKE_NEXUS/monitor/request-channel.sh"

# The shared retire-gate predicate (jacob-greene/nexus#16) + the idle-probe
# liveness primitives it combines. ng's re-wrap guard asks
# skeptic_gate_state whether the window is still gated; without these two
# files it degrades to `unclassified` (marker-presence only), which is a
# real mode and is asserted separately at the end of the SK1-d block.
cp "$_test_dir/../_skeptic_gate.sh" "$FAKE_NEXUS/monitor/_skeptic_gate.sh"
mkdir -p "$FAKE_NEXUS/monitor/watcher"
cp "$_test_dir/_idle_probe.sh" "$FAKE_NEXUS/monitor/watcher/_idle_probe.sh"

# Stubbed config — same shape as test-ng-reply-repo.sh.
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf '%s' "${TEST_DEFAULT_REPO:-default-org/default-repo}" ;;
    github.user_login)  printf '%s' "${TEST_DEFAULT_USER:-test-user}" ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-installation-token'
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# Stubbed upload-asset.sh. Records argv to $UPLOAD_CAPTURE and prints
# a canned SHA-pinned URL on stdout (the real script's contract).
# MOCK_UPLOAD_FAIL=1 → exit non-zero with an error on stderr.
UPLOAD_CAPTURE="$WORK/upload-calls.txt"
cat > "$FAKE_NEXUS/monitor/upload-asset.sh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$UPLOAD_CAPTURE"
if [[ "\${MOCK_UPLOAD_FAIL:-0}" == "1" ]]; then
    echo "upload-asset.sh: mock failure (auth or push refused)" >&2
    exit 3
fi
# Strip optional leading args; the local path is the first positional.
LOCAL=""
ISSUE=""
while (( \$# > 0 )); do
    case "\$1" in
        --issue)     ISSUE="\$2"; shift 2 ;;
        --*)         shift 2 ;;
        *)           [[ -z "\$LOCAL" ]] && LOCAL="\$1"; shift ;;
    esac
done
BASENAME="\$(basename "\$LOCAL")"
SHA="\${MOCK_UPLOAD_SHA:-deadbeefcafe1234}"
printf 'https://github.com/asset-org/assets/raw/%s/assets/%s/%s\\n' \
    "\$SHA" "\${ISSUE:-general}" "\$BASENAME"
STUB
chmod +x "$FAKE_NEXUS/monitor/upload-asset.sh"

# PATH-shadow gh. Records every invocation to $GH_CAPTURE. For
# `gh api`, returns canned JSON unless the per-step failure toggle
# matches the endpoint:
#   MOCK_COMMENT_FAIL=1 → /issues/<n>/comments POST returns 1 + error JSON
#   MOCK_ROCKET_FAIL=1  → /issues/comments/<id>/reactions POST returns 1
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
GH_CAPTURE="$WORK/gh-calls.txt"
# Stateful fake comment store for the post-once / re-point tests
# (#524 defect 2): POST to the issue-comments endpoint persists the
# body; GET/PATCH on /issues/comments/1234 read/mutate it.
COMMENT_STORE="$WORK/comment-store.json"
COMMENT_SEQ="$WORK/comment-updated-seq"

# Stubbed tmux. wrap-up calls
#   tmux display-message -p -t "$TMUX_PANE" '#{window_name}'
# when running inside a tmux session (TMUX is non-empty). Without
# `-t`, display-message returns the active window of the session
# — wrong when wrap-up runs in a non-active worker pane. The stub
# enforces this by RECORDING the -t value to $TMUX_CAPTURE and
# REQUIRING `-t %<pane>` for display-message calls; without it the
# stub prints an error to stderr and the assertion in test 16-target
# fails. MOCK_TMUX_WINDOW is the canned return value for the happy
# path.
TMUX_CAPTURE="$WORK/tmux-calls.txt"
cat > "$STUB_DIR/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$TMUX_CAPTURE"
# list-windows drives _idle_skeptic_live_window, i.e. whether the shared
# retire-gate predicate sees a LIVE reviewer. MOCK_LIVE_WINDOWS is the
# newline-separated window set; unset/empty means "no windows alive",
# which is what makes a re-armed marker ORPHANED rather than live.
if [[ "\${1:-}" == "list-windows" ]]; then
    [[ -n "\${MOCK_LIVE_WINDOWS:-}" ]] && printf '%s\\n' "\$MOCK_LIVE_WINDOWS"
    exit 0
fi
if [[ "\${1:-}" == "display-message" ]]; then
    # Require -t to be present and to look like a pane id (\$TMUX_PANE
    # is set by tmux to %<digits>). Refuse the default (active-window)
    # targeting so the regression test catches a re-introduction of
    # the pre-fix behaviour.
    saw_target=0
    target_val=""
    shift
    while (( \$# > 0 )); do
        case "\$1" in
            -t) saw_target=1; target_val="\$2"; shift 2 ;;
            -p) shift ;;
            *) shift ;;
        esac
    done
    if (( saw_target == 0 )); then
        echo "stub-tmux: display-message MISSING -t (would return active-window name; bug)" >&2
        exit 1
    fi
    if [[ ! "\$target_val" =~ ^%[0-9]+\$ ]]; then
        echo "stub-tmux: display-message -t '\$target_val' not a pane id" >&2
        exit 1
    fi
    printf '%s' "\${MOCK_TMUX_WINDOW:-}"
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"

if [[ "\${1:-}" != "api" ]]; then
    exit 0
fi
# Walk argv to find the endpoint (the first positional that begins with "/").
endpoint=""
shift  # drop "api"
while (( \$# > 0 )); do
    case "\$1" in
        --input)  shift 2 ;;       # drain stdin too
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
# Drain stdin defensively (some calls --input -)
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi

case "\$endpoint" in
    */issues/*/comments)
        if [[ "\${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2
            exit 1
        fi
        printf '{"html_url":"https://mock.example/issuecomment-1234"}'
        ;;
    */issues/comments/*/reactions)
        if [[ "\${MOCK_ROCKET_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock reactions POST 422"}' >&2
            exit 1
        fi
        printf '{"id":99999,"content":"rocket"}'
        ;;
    *)
        printf '{}'
        ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# Run ng with stubs in front of PATH. Captures stdout/stderr/exit.
# By default unsets TMUX so wrap-up sees no tmux context (the
# expected shape for the bulk of these tests, which assert non-tmux
# behaviour). Set MOCK_TMUX=1 + MOCK_TMUX_WINDOW=<name> to opt in
# to a tmux context for issue-#109 tests.
#
# Hermetic STATE_DIR: ng's _resolve_state_dir consults
# NEXUS_STATE_DIR / NEXUS_ROOT / config nexus.root before the
# $_script_dir/.state fallback. Pin NEXUS_STATE_DIR to the
# fixture's state dir and unset NEXUS_ROOT/NEXUS_CONFIG so the
# operator's exported env doesn't redirect the action-log out of
# $FAKE_NEXUS (mirrors the fix applied to test-ng-fetch-asset.sh
# in ce1cffb6).
#
# Skeptic isolation: this suite exercises the GitHub HAND-OFF mechanics
# (upload / comment / rocket / log / retain), not the skeptic step. The
# fixture window has no spawn provenance, so it resolves to `auto` mode;
# with monitor.skeptic.enforce_auto_decision now defaulting TRUE, a bare
# wrap-up (no --skeptic-decision) would fail step 6 and flip the exit
# code, masking the hand-off assertions. The skeptic step has its own
# dedicated suite (test-skeptic-channel.sh, including the enforce-on/off
# + consequence assertions), so pin the env override OFF here to isolate
# the unit under test. (The override-wins contract is itself asserted in
# test-skeptic-channel.sh.)
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$GH_CAPTURE"
    : > "$UPLOAD_CAPTURE"
    if [[ "${MOCK_TMUX:-0}" == "1" ]]; then
        # MOCK_TMUX branch deliberately sets TMUX/TMUX_PANE — we are
        # testing the tmux-context code path, so they must be present.
        env -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
            NEXUS_STATE_DIR="$STATE_DIR" \
            MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 \
            TMUX="${MOCK_TMUX_SOCKET:-/tmp/fake-tmux-sock}" \
            TMUX_PANE="${MOCK_TMUX_PANE:-%42}" \
            PATH="$STUB_DIR:$PATH" \
            "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    else
        env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
            NEXUS_STATE_DIR="$STATE_DIR" \
            MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 \
            PATH="$STUB_DIR:$PATH" \
            "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    fi
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

reset_mocks() {
    unset MOCK_UPLOAD_FAIL MOCK_UPLOAD_SHA MOCK_COMMENT_FAIL MOCK_ROCKET_FAIL
    unset MOCK_COMMENT_MOVING
    rm -rf "$STATE_DIR"
    rm -f "$COMMENT_STORE" "$COMMENT_SEQ"
}

# Standard well-formed report used across the happy-path tests.
# The body is intentionally well above the 500-char default minimum
# so the new pre-flight `report-check` (PR #4 round 4) accepts it
# without `--allow-stub`. Frontmatter carries every required field.
write_report() {
    local path="$1"
    cat > "$path" <<'EOF'
---
project: nexus
date: 2026-05-10
session-id: 4e8f1c2b-3a91-4d77-b9e0-5f2d0a1c7e8a
window: wrap-up-test
trigger: #42 (comment 7777)
status: completed
---

# Wrap-up dogfood: first iteration

## Summary

Implemented ng wrap-up so workers can hand off in one verb. The verb
folds upload + comment + rocket + log into a single call.

## What Was Done

- Added cmd_wrap_up to monitor/ng.
- Added tests under monitor/watcher/.
- Wired upload-asset.sh as the step-1 plumbing.
- Wired ng reply --repo as the step-2 backend.
- Added structured per-step status to stdout and per-step
  failure detail to stderr.

## Current State

- Branch operator/ng-wrap-up-and-friction-fixes, commits 91e1940
  through 80d4715. Tests green across the watcher suite.

## What Remains

- Address review on PR your-org/nexus-code#4.
- Land round-4 expansion once the PR is merged.

## How to Resume

- git checkout operator/ng-wrap-up-and-friction-fixes
- bash monitor/watcher/test-ng-wrap-up.sh
- Read this report for context.
EOF
}

REPORT="$FAKE_NEXUS/reports/nexus_2026-05-10_120000_wrap-up-test.md"
write_report "$REPORT"

# ---- Test 1: happy path with all four steps ----------------------------

echo '=== happy path: all four steps succeed, exit 0 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq        "exit 0 on full happy path"          "$rc" "0"
assert_contains  "stdout reports uploaded URL"        "$stdout" \
                 "uploaded: https://github.com/asset-org/assets/raw/deadbeefcafe1234"
assert_contains  "stdout reports comment URL"        "$stdout" \
                 "posted comment: https://mock.example/issuecomment-1234"
assert_contains  "stdout reports rocketed trigger"   "$stdout" \
                 "rocketed comment 7777"
assert_contains  "stdout reports logged action"      "$stdout" \
                 "logged action: wrap-up issue=42"

# Side-effect: upload-asset.sh called with --issue 42 and the report path.
upload_args=$(<"$UPLOAD_CAPTURE")
assert_contains "upload-asset.sh called with --issue 42" "$upload_args" \
                "--issue 42"
assert_contains "upload-asset.sh called with the report" "$upload_args" \
                "$(basename "$REPORT")"

# Side-effect: gh POSTed the comment to the right repo.
gh_calls=$(<"$GH_CAPTURE")
assert_contains "comment POST hits override-org/override-repo" "$gh_calls" \
                "/repos/override-org/override-repo/issues/42/comments"
assert_contains "rocket POST hits the trigger comment"        "$gh_calls" \
                "/repos/override-org/override-repo/issues/comments/7777/reactions"

# Side-effect: action-log.jsonl has a wrap-up entry.
LOG_FILE="$STATE_DIR/action-log.jsonl"
assert_file_exists "action-log.jsonl created" "$LOG_FILE"
log_line=$(<"$LOG_FILE")
assert_contains "log entry names event=wrap-up"     "$log_line" '"event":"wrap-up"'
assert_contains "log entry names issue=42"          "$log_line" '"issue":"42"'
assert_contains "log entry names upload=ok"         "$log_line" '"upload":"ok"'
assert_contains "log entry names comment=ok"        "$log_line" '"comment":"ok"'
assert_contains "log entry names rocket=ok"         "$log_line" '"rocket":"ok"'

# ---- Test 2: missing arg → exit 1 + usage --------------------------------

echo '=== missing args → exit 1 + usage line ==='
reset_mocks
run_ng stdout stderr rc wrap-up
assert_eq       "exit 1 with no args"                "$rc" "1"
assert_contains "stderr prints usage"                "$stderr" \
                "usage: ng wrap-up"

# ---- Test 3: report path doesn't exist → exit 1 -------------------------

echo '=== missing report file → exit 1 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$WORK/nope.md" --repo a/b
assert_eq       "exit 1 on missing report"           "$rc" "1"
assert_contains "stderr names the missing report"    "$stderr" \
                "report not found"

# ---- Test 4: upload fails → comment skipped, exit 1, structured stderr -

echo '=== upload fails → comment skipped, exit 1, structured stderr ==='
reset_mocks
export MOCK_UPLOAD_FAIL=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "exit 1 on upload failure"           "$rc" "1"
assert_contains "stdout reports upload FAILED"       "$stdout" \
                "uploaded: FAILED"
assert_contains "stdout reports comment SKIPPED"     "$stdout" \
                "posted comment: SKIPPED"
assert_contains "stderr names upload as the failed step" "$stderr" \
                "upload: upload-asset.sh failed"
# Comment was NOT attempted (no POST to /issues/.../comments).
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no comment POST attempted when upload failed" "$gh_calls" \
                    "/issues/42/comments"
# Rocket IS still attempted — it's independent of upload.
assert_contains "rocket still POSTed on upload failure" "$gh_calls" \
                "/issues/comments/7777/reactions"
# Log-action still recorded with upload=failed.
LOG_FILE="$STATE_DIR/action-log.jsonl"
assert_file_exists "log file still written on partial failure" "$LOG_FILE"
log_line=$(<"$LOG_FILE")
assert_contains "log entry names upload=failed"      "$log_line" \
                '"upload":"failed"'
assert_contains "log entry names comment=skipped on upload-fail" "$log_line" \
                '"comment":"skipped"'

# ---- Test 5: comment POST fails → exit 1, rocket + log still attempt ---

echo '=== comment fails → exit 1, rocket + log still attempt ==='
reset_mocks
export MOCK_COMMENT_FAIL=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "exit 1 on comment failure"          "$rc" "1"
assert_contains "stdout reports uploaded URL"        "$stdout" "uploaded: "
assert_contains "stdout reports comment FAILED"      "$stdout" \
                "posted comment: FAILED"
assert_contains "stdout reports rocketed"            "$stdout" \
                "rocketed comment 7777"
assert_contains "stderr names comment as the failed step" "$stderr" \
                "comment: POST"
# Log entry records comment=failed but upload=ok.
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_contains "log entry names upload=ok"          "$log_line" '"upload":"ok"'
assert_contains "log entry names comment=failed"     "$log_line" '"comment":"failed"'

# ---- Test 6: rocket POST fails → exit 1, upload/comment still ok ------

echo '=== rocket fails → exit 1, upload+comment still ok ==='
reset_mocks
export MOCK_ROCKET_FAIL=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "exit 1 on rocket failure"           "$rc" "1"
assert_contains "stdout reports uploaded URL"        "$stdout" "uploaded: "
assert_contains "stdout reports comment ok"          "$stdout" "posted comment: https://"
assert_contains "stdout reports rocketed FAILED"     "$stdout" \
                "rocketed comment 7777: FAILED"
assert_contains "stderr names rocket as the failed step" "$stderr" \
                "rocket: POST"

# ---- Test 7: --trigger-comment omitted → rocket step skipped ----------

echo '=== no --trigger-comment → rocket skipped, exit 0 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "exit 0 without --trigger-comment"   "$rc" "0"
assert_not_contains "no rocket line printed" "$stdout" "rocketed comment"
# And no reactions POST.
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no reactions POST issued" "$gh_calls" "/reactions"

# ---- Test 8: --trigger-comment 0 treated as skip ----------------------

echo '=== --trigger-comment 0 → rocket skipped ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 0 --repo override-org/override-repo
assert_eq       "exit 0 with --trigger-comment 0"    "$rc" "0"
assert_not_contains "no rocket line printed for 0"   "$stdout" \
                    "rocketed comment"

# ---- Test 9: comment body templates pull title + summary -------------

echo '=== comment body template pulls H1 + Summary section first sentence ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "exit 0 on template happy path"      "$rc" "0"

# To verify the body template, peek at the captured gh argv. The body
# JSON arrived via stdin (`--input -`) which our stub drains; we can't
# round-trip it from $GH_CAPTURE alone. Instead, intercept the JSON
# payload via a body-aware stub override for this single test.
BODY_CAPTURE="$WORK/comment-body.txt"
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  cat > "$BODY_CAPTURE"; shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
case "\$endpoint" in
    */issues/*/comments) printf '{"html_url":"https://mock.example/cmt"}' ;;
    *)                    printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
body=$(jq -r '.body // ""' < "$BODY_CAPTURE" 2>/dev/null)
assert_contains "comment body embeds the report's H1 title" "$body" \
                "Wrap-up dogfood: first iteration"
assert_contains "comment body embeds the Summary first sentence" "$body" \
                "Implemented ng wrap-up"
assert_contains "comment body links to the uploaded asset"  "$body" \
                "Full report: https://github.com/asset-org"

# Restore the canonical stub for any later tests below.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
case "\$endpoint" in
    */issues/*/comments)
        if [[ "\${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2; exit 1
        fi
        printf '{"html_url":"https://mock.example/issuecomment-1234"}' ;;
    */issues/comments/*/reactions)
        if [[ "\${MOCK_ROCKET_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock reactions POST 422"}' >&2; exit 1
        fi
        printf '{"id":99999,"content":"rocket"}' ;;
    *) printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# ---- Test 10: bare report (no frontmatter, no H1) → pre-flight rejects -

echo '=== bare report (no frontmatter) → pre-flight report-check rejects ==='
BARE_REPORT="$FAKE_NEXUS/reports/bare-report.md"
cat > "$BARE_REPORT" <<'EOF'
This file intentionally has no markdown H1 heading.

Just a single paragraph of body text describing the run.
EOF
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$BARE_REPORT" --repo override-org/override-repo
assert_eq        "exit 1 on bare-report pre-flight fail"   "$rc" "1"
assert_contains  "stderr explains the pre-flight"          "$stderr" \
                 "report-check failed"
assert_contains  "stderr names --allow-stub override"      "$stderr" \
                 "--allow-stub"
assert_contains  "stderr names frontmatter as missing"     "$stderr" \
                 "frontmatter"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no upload attempted on pre-flight fail" "$gh_calls" \
                    "/issues/42/comments"

# Test 10b: same bare report with a fully-fleshed body but no frontmatter
# still fails the pre-flight (body+sections alone aren't enough).
FAT_NOFRONT="$FAKE_NEXUS/reports/fat-no-front.md"
cat > "$FAT_NOFRONT" <<'EOF'
# Worker delivered substantive content but forgot frontmatter

## Summary
We delivered a meaningful change set but didn't run ng report-init.
The body has all the canonical sections and is well over the
500-character minimum. The pre-flight should still refuse because
the frontmatter is missing entirely, and the worker should be
nudged to re-do the report via ng report-init.

## What Was Done
- Things and things and things and things and things.

## Current State
- All sections present; no frontmatter.

## What Remains
- Re-do the report via ng report-init.

## How to Resume
- Run ng report-init.
EOF
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$FAT_NOFRONT" --repo override-org/override-repo
assert_eq        "exit 1 even with full body + no frontmatter" "$rc" "1"
assert_contains  "stderr names frontmatter"                "$stderr" \
                 "frontmatter"

# ---- Test 11: --comment-body-file with {{REPORT_URL}} → substitution ---

echo '=== --comment-body-file with {{REPORT_URL}} token → substituted ==='
# Reuse the body-capturing stub.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  cat > "$BODY_CAPTURE"; shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
case "\$endpoint" in
    */issues/*/comments)              printf '{"html_url":"https://mock.example/cmt"}' ;;
    */issues/comments/*/reactions)    printf '{"id":111,"content":"rocket"}' ;;
    *)                                printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

CUSTOM_BODY="$WORK/custom-body.md"
cat > "$CUSTOM_BODY" <<'EOF'
This is bespoke synthesis prose with **bold** and inline `code`.

Findings landed in fig5. See {{REPORT_URL}} for the breakdown.

- Bullet one
- Bullet two
EOF
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --comment-body-file "$CUSTOM_BODY" --repo override-org/override-repo
assert_eq        "exit 0 on custom-body happy path"    "$rc" "0"
body=$(jq -r '.body // ""' < "$BODY_CAPTURE" 2>/dev/null)
assert_contains  "custom body preserved verbatim (bold)"  "$body" "**bold**"
assert_contains  "{{REPORT_URL}} substituted with asset URL" "$body" \
                 "https://github.com/asset-org/assets/raw/deadbeefcafe1234"
assert_not_contains "{{REPORT_URL}} token gone from body" "$body" \
                    "{{REPORT_URL}}"

# ---- Test 12: --comment-body-file without token → footer appended -------

echo '=== --comment-body-file with no token → "Full report: <URL>" footer ==='
NO_TOKEN_BODY="$WORK/no-token-body.md"
cat > "$NO_TOKEN_BODY" <<'EOF'
Custom prose that does not reference the report inline.
EOF
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --comment-body-file "$NO_TOKEN_BODY" --repo override-org/override-repo
assert_eq        "exit 0 with no-token body"           "$rc" "0"
body=$(jq -r '.body // ""' < "$BODY_CAPTURE" 2>/dev/null)
assert_contains  "custom prose preserved"              "$body" \
                 "Custom prose that does not reference"
assert_contains  "footer appended with asset URL"      "$body" \
                 "Full report: https://github.com/asset-org"

# ---- Test 13: --no-comment skips step 2 entirely ------------------------

echo '=== --no-comment → step 2 skipped, upload + rocket + log still run ==='
# Restore the canonical stub (no body capture, since no POST expected).
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
case "\$endpoint" in
    */issues/*/comments)              printf '{"html_url":"https://mock.example/cmt"}' ;;
    */issues/comments/*/reactions)    printf '{"id":111,"content":"rocket"}' ;;
    *)                                printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo --no-comment
assert_eq        "exit 0 with --no-comment"            "$rc" "0"
assert_contains  "stdout reports uploaded URL"         "$stdout" "uploaded: "
assert_contains  "stdout reports comment SKIPPED"      "$stdout" \
                 "posted comment: SKIPPED"
assert_contains  "stdout reports rocketed"             "$stdout" "rocketed comment 7777"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no comment POST attempted"        "$gh_calls" \
                    "/issues/42/comments"
assert_contains  "rocket POST attempted"               "$gh_calls" \
                 "/issues/comments/7777/reactions"
# Log records comment=skipped so the orchestrator can tell apart
# "worker chose --no-comment" from "comment failed".
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_contains  "log entry names comment=skipped"     "$log_line" \
                 '"comment":"skipped"'

# ---- Test 14: --no-comment + --comment-body-file → exit 1 (conflict) ---

echo '=== --no-comment + --comment-body-file → exit 1 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --no-comment --comment-body-file "$CUSTOM_BODY" --repo a/b
assert_eq        "exit 1 on conflicting flags"         "$rc" "1"
assert_contains  "stderr names the conflict"           "$stderr" \
                 "mutually exclusive"

# ---- Test 15: --comment-body-file path missing → exit 1 ----------------

echo '=== --comment-body-file path missing → exit 1 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --comment-body-file "$WORK/nope-body.md" --repo a/b
assert_eq        "exit 1 on missing body file"         "$rc" "1"
assert_contains  "stderr names the missing body file"  "$stderr" \
                 "comment-body-file not found"

# ---- Test 16: under tmux → log entry records window field (#109) -------

echo '=== under tmux → log entry includes "window":"<name>" ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="my-worker-window"
: > "$TMUX_CAPTURE"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 with tmux context"            "$rc" "0"
LOG_FILE="$STATE_DIR/action-log.jsonl"
assert_file_exists "log file written"                  "$LOG_FILE"
log_line=$(<"$LOG_FILE")
assert_contains  "log entry records source window"     "$log_line" \
                 '"window":"my-worker-window"'

# Regression for the post-#10 bug: without `-t`, display-message
# returns the ACTIVE window of the session, not the calling pane's
# window. The stub-tmux refuses any display-message without `-t`,
# so the assertion above on `"window":"my-worker-window"` ONLY
# passes when ng targets by pane explicitly. Belt-and-suspenders:
# also assert the captured argv literally contains `-t %42`.
tmux_calls=$(<"$TMUX_CAPTURE")
assert_contains "tmux display-message targets pane via -t \$TMUX_PANE" \
                "$tmux_calls" "display-message -p -t %42"

# ---- Test 17: outside tmux → log entry omits window field --------------

echo '=== outside tmux → log entry has no window field ==='
reset_mocks
# Default run_ng path unsets TMUX.
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq        "exit 0 without tmux context"         "$rc" "0"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_not_contains "log entry omits window field outside tmux" "$log_line" \
                    '"window":'

# ---- Test 18: --trigger-repo routes rocket to a different repo (#108) --

echo '=== --trigger-repo routes rocket-react to a different repo than --repo ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 \
    --repo issue-org/issue-repo \
    --trigger-repo trigger-org/trigger-repo
assert_eq        "exit 0 with --trigger-repo"          "$rc" "0"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "comment POST hits --repo target (issue thread)" "$gh_calls" \
                "/repos/issue-org/issue-repo/issues/42/comments"
assert_contains "rocket POST hits --trigger-repo target"         "$gh_calls" \
                "/repos/trigger-org/trigger-repo/issues/comments/7777/reactions"
assert_not_contains "rocket does NOT post on --repo target"      "$gh_calls" \
                    "/repos/issue-org/issue-repo/issues/comments/7777/reactions"
# Log entry records the trigger-repo when it differs.
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_contains "log entry records issue-thread repo"  "$log_line" \
                '"repo":"issue-org/issue-repo"'
assert_contains "log entry records cross-repo trigger" "$log_line" \
                '"trigger-repo":"trigger-org/trigger-repo"'

# ---- Test 19: --trigger-repo omitted → defaults to --repo (back-compat)

echo '=== --trigger-repo omitted → rocket falls back to --repo target ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo same-org/same-repo
assert_eq        "exit 0 with --trigger-repo absent"   "$rc" "0"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "rocket POST hits --repo target (default)"  "$gh_calls" \
                "/repos/same-org/same-repo/issues/comments/7777/reactions"
# When trigger-repo == --repo, the log entry omits the trigger-repo
# extra (compact legacy shape).
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_not_contains "log entry omits trigger-repo when same as --repo" "$log_line" \
                    '"trigger-repo":'

# ---- Test 20: under tmux → wrap-up auto-retains the source window ------

echo '=== under tmux → wrap-up auto-logs window-retain with default tag ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="retainme-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on retain happy path"           "$rc" "0"
assert_contains  "stdout reports retained window"        "$stdout" \
                 "retained window: retainme-worker"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
# Two log entries: wrap-up first, then window-retain.
assert_contains  "log has the wrap-up entry"             "$log_lines" \
                 '"event":"wrap-up"'
assert_contains  "log has the window-retain entry"       "$log_lines" \
                 '"event":"window-retain"'
assert_contains  "retain entry names the source window"  "$log_lines" \
                 '"window":"retainme-worker"'
# Default reason is wrap-up-<YYYY-MM-DD>.
today=$(date -u +%Y-%m-%d)
assert_contains  "retain entry uses wrap-up-<date> auto-tag" "$log_lines" \
                 "\"reason\":\"wrap-up-${today}\""
assert_contains  "retain entry records the issue"        "$log_lines" \
                 '"issue":"42"'

# ---- Test 21: --retain <reason> overrides the auto-tag ----------------

echo '=== --retain <reason> overrides the wrap-up-<date> auto-tag ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="customtag-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo \
    --retain "loaded-kompot-figures-kernel"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on --retain happy path"         "$rc" "0"
assert_contains  "stdout reports retained window"        "$stdout" \
                 "retained window: customtag-worker"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_contains  "retain entry uses the custom reason"   "$log_lines" \
                 '"reason":"loaded-kompot-figures-kernel"'
assert_not_contains "retain entry omits the wrap-up-<date> auto-tag" "$log_lines" \
                    "wrap-up-${today}"

# ---- Test 22: --no-retain opts out of auto-retain ----------------------

echo '=== --no-retain opts out → no window-retain event ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="closeme-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo --no-retain
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on --no-retain"                 "$rc" "0"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_contains  "log has the wrap-up entry"             "$log_lines" \
                 '"event":"wrap-up"'
assert_not_contains "log has NO window-retain entry"     "$log_lines" \
                    '"event":"window-retain"'
assert_not_contains "stdout omits retained-window line"  "$stdout" \
                    "retained window:"

# ---- Test 23: outside tmux → no retain logged (no source_window) -------

echo '=== outside tmux → no source_window → no retain logged ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo
assert_eq        "exit 0 outside tmux"                   "$rc" "0"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_not_contains "no window-retain logged off-tmux"   "$log_lines" \
                    '"event":"window-retain"'

# ---- Test 24: --no-retain + --retain → exit 1 (conflict) ---------------

echo '=== --no-retain + --retain → exit 1 (mutually exclusive) ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo a/b --no-retain --retain "irrelevant"
assert_eq        "exit 1 on conflicting retain flags"    "$rc" "1"
assert_contains  "stderr names the conflict"             "$stderr" \
                 "mutually exclusive"

# ---- Tests 25+: interactive-wrap clarification + engaged-done (the
#      #205 state-machine follow-up) ---------------------------------------
#
# A wrap-up from an operator-engaged (interactive) window must emit
# the clarification block telling the agent that staying engaged is
# the default and that `ng engaged-done` is the explicit
# finished-signal. A machine-driven wrap-up (no live mark) keeps
# today's output exactly. The engagement predicate mirrors the
# watcher's `_openg_marked` core: row seeded + pane-change within the
# change TTL + no newer engaged-done.

echo '=== interactive wrap-up → clarification block emitted ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="engaged-worker"
_iw_now=$(date +%s)
mkdir -p "$STATE_DIR/pane-change"
printf 'engaged-worker\t%s\t%s\t%s\tsubmit\t0\n' \
    "$(( _iw_now - 300 ))" "$(( _iw_now - 10 ))" "$(( _iw_now - 200 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
printf 'h\t%s\n' "$_iw_now" > "$STATE_DIR/pane-change/engaged-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on interactive wrap"            "$rc" "0"
assert_contains  "clarification block present"           "$stdout" \
                 "operator-engaged (interactive) session detected"
assert_contains  "default is stay-engaged"               "$stdout" \
                 "expecting follow-up user inquiries (the DEFAULT)"
assert_contains  "finished-signal verb named"            "$stdout" \
                 "ng engaged-done"

echo '=== machine wrap-up (no mark) → no clarification, output unchanged ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="machine-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq           "exit 0 on machine wrap"             "$rc" "0"
assert_not_contains "no clarification without a mark"    "$stdout" \
                    "operator-engaged (interactive)"
assert_contains     "normal retain line still present"   "$stdout" \
                    "retained window: machine-worker"

echo '=== expired mark (pane static past change TTL) → no clarification ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="expired-worker"
_iw_now=$(date +%s)
mkdir -p "$STATE_DIR/pane-change"
printf 'expired-worker\t%s\t%s\t%s\tsubmit\t0\n' \
    "$(( _iw_now - 5000 ))" "$(( _iw_now - 4000 ))" "$(( _iw_now - 4500 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
# Change clock frozen 2000 s ago — far past the default 600 s TTL.
printf 'h\t%s\n' "$(( _iw_now - 2000 ))" > "$STATE_DIR/pane-change/expired-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq           "exit 0 on expired-mark wrap"        "$rc" "0"
assert_not_contains "lapsed mark → no clarification"     "$stdout" \
                    "operator-engaged (interactive)"

echo '=== engaged-done: in-tmux → logs the finished-signal event ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="done-worker"
run_ng stdout stderr rc engaged-done
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on engaged-done"                "$rc" "0"
assert_contains  "confirmation names the window"         "$stdout" \
                 "engaged-done: done-worker released"
log_lines=$(<"$STATE_DIR/action-log.jsonl")
assert_contains  "log has the engaged-done event"        "$log_lines" \
                 '"event":"engaged-done"'
assert_contains  "event names the window"                "$log_lines" \
                 '"window":"done-worker"'

echo '=== engaged-done: --window override works off-tmux ==='
reset_mocks
run_ng stdout stderr rc engaged-done --window override-worker
assert_eq        "exit 0 with --window"                  "$rc" "0"
log_lines=$(<"$STATE_DIR/action-log.jsonl")
assert_contains  "event names the overridden window"     "$log_lines" \
                 '"window":"override-worker"'

echo '=== engaged-done: off-tmux without --window → loud failure ==='
reset_mocks
run_ng stdout stderr rc engaged-done
assert_eq        "exit 1 with no resolvable window"      "$rc" "1"
assert_contains  "stderr names the fix"                  "$stderr" \
                 "--window"

# ---- Test 30: skeptic gate runs BEFORE the GitHub hand-off (Change 3) ---
# An undecided `auto` worker under enforce_auto_decision must FAIL wrap-up
# WITHOUT uploading the report or posting any comment/rocket — so a
# blocked task never announces "done" and a retry can't double-post. The
# fixture window has no provenance → resolves to `auto`; we flip enforce
# ON for this one run (the rest of the suite pins it off to isolate the
# hand-off). report-check (step 0) still passes on the well-formed REPORT,
# so the skeptic step (step 0b) is genuinely what blocks.
echo '=== skeptic gate precedes hand-off: enforce-on undecided → no GitHub writes ==='
reset_mocks
: > "$GH_CAPTURE"; : > "$UPLOAD_CAPTURE"
_g_out=$(mktemp); _g_err=$(mktemp)
env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
    NEXUS_STATE_DIR="$STATE_DIR" \
    MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=1 \
    PATH="$STUB_DIR:$PATH" \
    "$NG" wrap-up 42 "$REPORT" --trigger-comment 7777 --repo override-org/override-repo \
    >"$_g_out" 2>"$_g_err"
rc=$?
stdout=$(<"$_g_out"); stderr=$(<"$_g_err"); rm -f "$_g_out" "$_g_err"
assert_eq        "enforce-on undecided → exit 1"             "$rc" "1"
assert_contains  "stdout names the decision-required block"  "$stdout" \
                 "SKEPTIC DECISION REQUIRED"
upload_args=$(<"$UPLOAD_CAPTURE")
assert_eq        "NO upload attempted before the gate"       "$upload_args" ""
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "NO comment POST before the gate"        "$gh_calls" \
                    "/issues/42/comments"
assert_not_contains "NO rocket reaction before the gate"     "$gh_calls" \
                    "/reactions"
# And the auto-require decision path DOES proceed to the hand-off (gate
# satisfied) → report uploaded + comment posted, exit 0.
echo '=== skeptic gate satisfied (auto→require) → hand-off proceeds ==='
reset_mocks
: > "$GH_CAPTURE"; : > "$UPLOAD_CAPTURE"
_g_out=$(mktemp); _g_err=$(mktemp)
env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
    NEXUS_STATE_DIR="$STATE_DIR" \
    MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=1 \
    PATH="$STUB_DIR:$PATH" \
    "$NG" wrap-up 42 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra" \
    >"$_g_out" 2>"$_g_err"
rc=$?
stdout=$(<"$_g_out"); rm -f "$_g_out" "$_g_err"
assert_eq        "auto→require decision → exit 0"            "$rc" "0"
assert_contains  "hand-off ran: report uploaded"            "$stdout" "uploaded: https://"
gh_calls=$(<"$GH_CAPTURE")
assert_contains  "hand-off ran: comment POSTed"             "$gh_calls" \
                 "/issues/42/comments"

# Re-establish the FULL canonical gh stub — now STATEFUL (#524 defect
# 2): tests 11/13 above left a simplified stub in place (returns
# .../cmt, ignores MOCK_*_FAIL). The post-once tests below need the
# issuecomment-1234 URL, the MOCK_ROCKET_FAIL toggle, AND a real
# comment record: POST persists the body to $COMMENT_STORE; GET/PATCH
# on /issues/comments/1234 read/mutate it (PATCH bumps updated_at).
# MOCK_COMMENT_MOVING=1 bumps updated_at on every GET, simulating a
# comment under sustained concurrent edits (the CAS must fail loud).
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
method="GET"
body_json=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  body_json=\$(cat); shift 2 ;;
        -X)       method="\$2"; shift 2 ;;
        -H|-f)    shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
_bump() {
    n=\$(( \$( cat "$COMMENT_SEQ" 2>/dev/null || echo 0 ) + 1 ))
    printf '%s' "\$n" > "$COMMENT_SEQ"
    printf '2026-07-15T12:00:%02dZ' "\$n"
}
case "\$endpoint" in
    */issues/comments/*/reactions)
        if [[ "\${MOCK_ROCKET_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock reactions POST 422"}' >&2; exit 1
        fi
        printf '{"id":99999,"content":"rocket"}' ;;
    */issues/comments/*)
        if [[ ! -f "$COMMENT_STORE" ]]; then
            echo '{"message":"Not Found"}' >&2; exit 1
        fi
        if [[ "\$method" == "PATCH" ]]; then
            new_body=\$(jq -r '.body' <<<"\$body_json")
            ts=\$(_bump)
            jq --arg b "\$new_body" --arg t "\$ts" \\
               '.body=\$b | .updated_at=\$t' "$COMMENT_STORE" > "$COMMENT_STORE.tmp" \\
               && mv "$COMMENT_STORE.tmp" "$COMMENT_STORE"
        elif [[ "\${MOCK_COMMENT_MOVING:-0}" == "1" ]]; then
            ts=\$(_bump)
            jq --arg t "\$ts" '.updated_at=\$t' "$COMMENT_STORE" > "$COMMENT_STORE.tmp" \\
                && mv "$COMMENT_STORE.tmp" "$COMMENT_STORE"
        fi
        jq '. + {html_url:"https://mock.example/issuecomment-1234"}' "$COMMENT_STORE" ;;
    */issues/*/comments)
        if [[ "\${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2; exit 1
        fi
        posted=\$(jq -r '.body' <<<"\$body_json")
        jq -n --arg b "\$posted" --arg t "2026-07-15T12:00:00Z" \\
            '{body:\$b, updated_at:\$t}' > "$COMMENT_STORE"
        printf '{"html_url":"https://mock.example/issuecomment-1234"}' ;;
    *) printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

comment_store_body() { jq -r '.body' "$COMMENT_STORE" 2>/dev/null; }

# ---- Test 31: post-once idempotency — a clean re-run does not duplicate
#      the link comment (B15 / your-nexus#236) and, post-#524, re-points
#      it at the fresh upload instead of silently REUSING the stale link.
#      State (the action-log) persists across run_ng; only reset_mocks
#      wipes it, so the two runs below share the log the guard reads. ----
echo '=== post-once: re-running wrap-up updates the prior comment, no duplicate POST ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "first wrap-up exits 0"               "$rc" "0"
assert_contains "first run posts the comment"         "$stdout" \
                "posted comment: https://mock.example/issuecomment-1234"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "first run POSTs to the comments endpoint" "$gh_calls" \
                "/repos/override-org/override-repo/issues/42/comments"
# Second wrap-up for the SAME issue+report+repo. Must NOT re-POST.
# (Same MOCK_UPLOAD_SHA → the link already points at this blob → the
# re-point is a no-op UPDATE, still reported as such.)
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "re-run exits 0"                      "$rc" "0"
assert_contains "re-run updates (not blind-reuses) the prior comment" "$stdout" \
                "posted comment: UPDATED https://mock.example/issuecomment-1234"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "re-run does NOT POST a duplicate comment" "$gh_calls" \
                    "/repos/override-org/override-repo/issues/42/comments"

# ---- Test 32: the other-nexus scenario — a partial failure (rocket) makes the
#      worker re-run the WHOLE verb (the only retry surface); the comment
#      must not double-post while the rocket DOES get re-attempted. -------
echo '=== post-once: retry after a rocket failure does not duplicate the comment ==='
reset_mocks
export MOCK_ROCKET_FAIL=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "partial-failure run exits 1"         "$rc" "1"
assert_contains "first run posted the comment"        "$stdout" \
                "posted comment: https://mock.example/issuecomment-1234"
assert_contains "first run's rocket FAILED"           "$stdout" \
                "rocketed comment 7777: FAILED"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "first run POSTs the comment"         "$gh_calls" \
                "/issues/42/comments"
unset MOCK_ROCKET_FAIL
# Worker retries the whole verb. Rocket now succeeds. The re-uploaded
# blob keeps the same mock SHA, so the link comment needs no PATCH —
# but the retry must still go through the post-once UPDATE path, not
# a blind reuse.
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "retry exits 0"                       "$rc" "0"
assert_contains "retry updates the prior comment"     "$stdout" \
                "posted comment: UPDATED"
assert_contains "retry rockets successfully"          "$stdout" \
                "rocketed comment 7777"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "retry does NOT duplicate the comment" "$gh_calls" \
                    "/issues/42/comments"
assert_contains "retry DID re-attempt the rocket"     "$gh_calls" \
                "/issues/comments/7777/reactions"

# ---- Test 33: the guard is scoped to (issue, report, repo) — a DIFFERENT
#      report under the same issue still posts a fresh comment. Guards
#      against an over-broad dedup that would swallow legitimate posts. --
echo '=== post-once is per-report: a different report still posts fresh ==='
REPORT2="$FAKE_NEXUS/reports/nexus_2026-05-11_090000_second-task.md"
write_report "$REPORT2"
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "first report wrap-up exits 0"        "$rc" "0"
run_ng stdout stderr rc wrap-up 42 "$REPORT2" --repo override-org/override-repo
assert_eq       "second report wrap-up exits 0"       "$rc" "0"
assert_contains "second report posts a fresh comment" "$stdout" \
                "posted comment: https://mock.example/issuecomment-1234"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "second report DID POST (not deduped)" "$gh_calls" \
                "/issues/42/comments"

# ---- Test 34 (LOAD-BEARING, #524 defect 2): a re-wrap after correcting
#      the report re-uploads to a NEW blob; the post-once path must
#      re-point the existing link comment's asset URL at that new blob.
#      Pre-#524 behaviour: print "REUSED", never touch the comment —
#      the thread keeps linking the PRE-correction report while the
#      verb reports success (the #523 incident). RED on old code:
#      the UPDATED line is absent and the stored comment still carries
#      the stale SHA. -----------------------------------------------------
echo '=== re-wrap after correction → link comment PATCHed to the NEW blob ==='
reset_mocks
export MOCK_UPLOAD_SHA="aaaa1111beforefix"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "first wrap-up exits 0"                "$rc" "0"
assert_contains "link comment stores the v1 blob URL"  "$(comment_store_body)" \
                "https://github.com/asset-org/assets/raw/aaaa1111beforefix/assets/42/$(basename "$REPORT")"
# The report gets materially corrected; the worker re-wraps. The upload
# step mints a NEW sha for the corrected content.
export MOCK_UPLOAD_SHA="bbbb2222corrected"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
unset MOCK_UPLOAD_SHA
assert_eq       "re-wrap exits 0"                      "$rc" "0"
assert_contains "stdout reports the UPDATED link comment" "$stdout" \
                "posted comment: UPDATED https://mock.example/issuecomment-1234"
store_body=$(comment_store_body)
assert_contains "link comment NOW points at the corrected blob" "$store_body" \
                "https://github.com/asset-org/assets/raw/bbbb2222corrected/assets/42/$(basename "$REPORT")"
assert_not_contains "STALE blob URL is gone from the link comment" "$store_body" \
                    "aaaa1111beforefix"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "re-point went through PATCH on the comment" "$gh_calls" \
                "-X PATCH /repos/override-org/override-repo/issues/comments/1234"
assert_not_contains "no duplicate link comment POSTed"  "$gh_calls" \
                    "/issues/42/comments"
# The action log records the update so a THIRD wrap-up keys off it.
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_contains "log records comment=updated on the re-wrap" "$log_lines" \
                '"comment":"updated"'

# ---- Test 35: re-point under sustained concurrent edits → the CAS
#      refuses and the wrap-up FAILS LOUDLY instead of clobbering
#      (defect 1's fail-loud contract, exercised through the defect-2
#      path that now depends on it). --------------------------------------
echo '=== re-wrap while the comment keeps moving → loud failure, no clobber ==='
reset_mocks
export MOCK_UPLOAD_SHA="cccc3333firstpass"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "first wrap-up exits 0"                "$rc" "0"
export MOCK_UPLOAD_SHA="dddd4444secondpass"
export MOCK_COMMENT_MOVING=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
unset MOCK_COMMENT_MOVING MOCK_UPLOAD_SHA
assert_eq       "re-wrap exits 1 when the comment keeps moving" "$rc" "1"
assert_contains "stdout reports the comment step FAILED" "$stdout" \
                "posted comment: FAILED"
assert_contains "stderr names the re-point failure"     "$stderr" \
                "re-point of prior link comment"
store_body=$(comment_store_body)
assert_contains "contended comment NOT clobbered (v1 link intact)" "$store_body" \
                "cccc3333firstpass"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no PATCH landed on the moving comment" "$gh_calls" \
                    "-X PATCH /repos/override-org/override-repo/issues/comments/1234"

# ---- Test 40+: spawn-skeptic request filing (your-org/nexus-code#545) ----
# A require resolution files a `kind=spawn-skeptic` request into the
# watcher-mediated inbox (Step 2b), carrying pointers; a clean first-pass
# require is auto-spawnable (deliberate=false); --skeptic-contradicted flips
# it to deliberate=true; a deny/undecided resolution files NOTHING; and a
# retry is idempotent (no duplicate request).
REQ_DIR="$STATE_DIR/requests"
count_spawn_reqs() {  # non-terminal spawn-skeptic requests currently in the inbox
    shopt -s nullglob
    local -a f=("$REQ_DIR"/*spawn*skeptic*.new.md "$REQ_DIR"/*-skeptic-d*.new.md \
                "$REQ_DIR"/*-skeptic-d*.claimed.md)
    shopt -u nullglob
    printf '%s' "${#f[@]}"
}
spawn_req_body() {  # concatenated body of every filed spawn-skeptic request
    shopt -s nullglob
    local -a f=("$REQ_DIR"/*-skeptic-d*.md)
    shopt -u nullglob
    (( ${#f[@]} > 0 )) && cat "${f[@]}" 2>/dev/null
}

echo '=== spawn-skeptic: a first-pass require FILES the request with pointers ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-req-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --trigger-comment 4242 \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "require wrap-up exits 0"                  "$rc" "0"
assert_contains "stdout reports the filed spawn-skeptic request" "$stdout" \
                "spawn-skeptic request: filed "
assert_eq       "exactly one spawn-skeptic request filed"  "$(count_spawn_reqs)" "1"
body=$(spawn_req_body)
assert_contains "request frontmatter carries kind=spawn-skeptic" "$body" \
                "kind: spawn-skeptic"
assert_contains "request origin is the worker window"      "$body" \
                "origin: sk-req-worker"
assert_contains "body carries the issue pointer"           "$body" \
                "issue: override-org/override-repo#77"
assert_contains "body carries the trigger-comment pointer" "$body" \
                "trigger-comment: 4242"
assert_contains "body carries the report asset URL"        "$body" \
                "report-asset-url: https://github.com/asset-org/"
assert_contains "body carries the target window"           "$body" \
                "target-window: sk-req-worker"
assert_contains "body carries depth 1"                     "$body" \
                "depth: 1"
assert_contains "clean first pass is NOT deliberate"       "$body" \
                "deliberate: false"

echo '=== spawn-skeptic: --skeptic-contradicted → deliberate=true ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-contra-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra" \
    --skeptic-contradicted "overrode the skeptic's retry-loop suggestion"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "contradicted require exits 0"             "$rc" "0"
body=$(spawn_req_body)
assert_contains "contradiction flags deliberate=true"      "$body" \
                "deliberate: true"
assert_contains "reasons name the contradiction"           "$body" \
                "worker-contradiction"
assert_contains "the contradiction text rides the body"    "$body" \
                "overrode the skeptic's retry-loop suggestion"

echo '=== spawn-skeptic: an auto-deny resolution files NOTHING ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-deny-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision deny --skeptic-rationale "one-line doc typo, trivial"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "auto-deny wrap-up exits 0"                "$rc" "0"
assert_eq       "NO spawn-skeptic request filed on deny"   "$(count_spawn_reqs)" "0"
assert_not_contains "stdout says nothing about a spawn-skeptic request" "$stdout" \
                    "spawn-skeptic request:"

echo '=== spawn-skeptic: a retry is idempotent (no duplicate request) ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-retry-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
assert_eq       "first require wrap-up exits 0"            "$rc" "0"
assert_eq       "one request after first wrap-up"          "$(count_spawn_reqs)" "1"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "retry require wrap-up exits 0"            "$rc" "0"
# Issue 16: the retry is now caught EARLIER, by the round-identity guard,
# so it never reaches the request-filing step's own "already filed" glob.
# The status slot still reports, with the more specific reason.
assert_contains "retry reports the round already open"     "$stdout" \
                "spawn-skeptic request: skipped (a round is already open for this report)"
assert_eq       "still exactly one request after retry"    "$(count_spawn_reqs)" "1"
# The pending marker is still on this channel, so the retire gate is still
# up: this is the GATE-ARMED branch of the guard, the only one that may
# exit 0, and it must still complete the hand-off. Round 2 (SK1) re-keyed
# the guard from the DONE sentinel to the marker, so the message now
# reports the gate it actually tested rather than inferring it.
assert_file     "retry leaves the retire gate ARMED"       "$STATE_DIR/skeptic/pending/sk-retry-worker"
assert_contains "retry reports the gate is still armed"    "$stdout" \
                "RETIRE GATE STILL ARMED"
assert_contains "retry cites the marker it actually tested" "$stdout" \
                "skeptic-pending marker is STILL IN PLACE"
assert_contains "retry still uploads the report"           "$stdout" "uploaded: https://github.com/asset-org"
assert_contains "retry still handles the link comment"     "$stdout" "posted comment"

echo '=== issue 16: repeat wrap-up after the request was ACKED + the skeptic CLOSED ==='
# The production failure (three duplicate requests in one round) slipped
# past the pre-existing "already filed" guard because that guard only
# globs *.new.md / *.claimed.md — an ACKED request is *.done.md, so a
# repeat filed a FRESH duplicate stamped `deliberate: false`, i.e. a
# rubber-stamp auto-spawnable first pass. End-to-end, through the real
# verb: file → ack → close → repeat.
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-acked-worker"
CHAN_SH="$FAKE_NEXUS/monitor/skeptic-channel.sh"
cp "$_test_dir/../skeptic-channel.sh" "$CHAN_SH"; chmod +x "$CHAN_SH"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
assert_eq       "round 1 wrap-up exits 0"                  "$rc" "0"
assert_eq       "round 1 files exactly one request"        "$(count_spawn_reqs)" "1"
assert_file     "round 1 arms the retire gate"             "$STATE_DIR/skeptic/pending/sk-acked-worker"
# The orchestrator acks it: .new.md -> .done.md (what request-channel ack does).
for _f in "$STATE_DIR"/requests/*spawn-skeptic*.new.md "$STATE_DIR"/requests/*skeptic-d1.new.md; do
    [[ -e "$_f" ]] && mv "$_f" "${_f%.new.md}.done.md"
done
# The skeptic runs, answers land, and it closes the channel.
NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" ask sk-acked-worker why --message "why?" >/dev/null
NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" await sk-acked-worker --once >/dev/null 2>&1
NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" answer sk-acked-worker 1 --message "because" >/dev/null
NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" close sk-acked-worker >/dev/null
sk_before=$(NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" status sk-acked-worker)
assert_eq       "verdict landed and the channel closed"    "$sk_before" \
                "open=0 ack=0 answered=1 total=1 done=1"
# THE REPEAT. Same issue, same unchanged report path — but a verdict has
# now LANDED, which cleared the pending marker. The retire gate is DOWN,
# so a silent rc 0 here would let `verdict -> remediate -> append ->
# re-wrap` (the ordinary remediation loop, and the common exit shape once
# `#20` is accounted for) proceed UNGATED. It must refuse and fail closed.
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
assert_eq       "post-verdict repeat REFUSES (rc 1, fails closed)" "$rc" "1"
assert_contains "post-verdict repeat says the retire gate is down" "$stdout" \
                "RETIRE GATE IS DOWN"
# ...and diagnoses HOW it went down. On THIS path a `close` landed, so the
# DONE sentinel is present and the message must say so — the other branch
# (verdict without close) is asserted in the SK1 block below.
assert_contains "post-verdict repeat diagnoses the close" "$stdout" \
                "\`close\` is"
assert_contains "post-verdict repeat cites the DONE sentinel as the evidence" "$stdout" \
                "The DONE sentinel is present"
assert_contains "post-verdict repeat names --skeptic-reopen" "$stdout" "--skeptic-reopen"
assert_contains "post-verdict repeat says an UNCHANGED deliverable is done" \
                "$stdout" "You are DONE"
# SK1-c: "you are done, retire" is safe HERE and only here — a verdict
# provably landed (DONE present, and `close` is its only writer). The
# message must say that is what corroborates it, so the same paragraph
# cannot be read as a retire licence in the states where nothing does.
assert_contains "post-verdict repeat states a verdict DID land" "$stdout" \
                "A VERDICT DID LAND"
assert_contains "post-verdict repeat corroborates (b) from the DONE sentinel" "$stdout" \
                "The DONE sentinel above corroborates (b)"
assert_not_contains "post-verdict repeat does NOT hedge (b) when DONE is present" \
                    "$stdout" "NOTHING HERE CORROBORATES (b)"
assert_eq       "repeat files NO duplicate request (was 3 in production)" \
                "$(count_spawn_reqs)" "0"
assert_eq       "repeat leaves the round-1 verdict + DONE intact" \
                "$(NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" status sk-acked-worker)" "$sk_before"
assert_not_file "repeat does NOT re-arm the retire gate" \
                "$STATE_DIR/skeptic/pending/sk-acked-worker"
# ...and NOTHING downstream of the skeptic step runs either. The refusal
# is the whole verb refusing, not just the gate opting out — round 1
# already uploaded this exact report and posted its link comment.
assert_not_contains "post-verdict repeat does NOT upload"  "$stdout" "uploaded: https://github.com/asset-org"
assert_not_contains "post-verdict repeat does NOT comment" "$stdout" "posted comment"
# The worker floor sends agents to STDERR on a non-zero wrap-up ("retry
# only the failed step(s) named on stderr"). A blind retry here just
# refuses again, so stderr must name the step AND say not to repeat it.
assert_contains "post-verdict repeat names the failed step on stderr" "$stderr" \
                "REFUSED at the skeptic step"
assert_contains "post-verdict repeat tells stderr readers not to blind-retry" "$stderr" \
                "do NOT retry this command as-is"

echo '=== issue 16: --skeptic-reopen forces a genuine new round ==='
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra" --skeptic-reopen
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "reopen wrap-up exits 0"                   "$rc" "0"
assert_contains "reopen announces a real require"          "$stdout" "SKEPTIC REQUIRED"
assert_eq       "reopen files a fresh request"             "$(count_spawn_reqs)" "1"
assert_file     "reopen re-arms the retire gate"           "$STATE_DIR/skeptic/pending/sk-acked-worker"
assert_eq       "reopen archives the stale DONE (#469 path intact)" \
                "$(NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" status sk-acked-worker)" \
                "open=0 ack=0 answered=0 total=0 done=0"
# F3 (issue 16 skeptic pass): a reopen files a fresh request only when
# round 1's request was ACKED (*.done.md — terminal, so the filing guard's
# *.new.md / *.claimed.md globs cannot see it), which is the case above.
# With an UNACKED request still in the inbox the guard DOES suppress it,
# and that is deliberate: two non-terminal requests for the same
# window+depth are two spawn instructions. The gate does not depend on the
# request, and the surviving one names the same window/depth/report-path.
# The status line must say which request it deferred to.
NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" close sk-acked-worker >/dev/null
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-acked-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra" --skeptic-reopen
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "reopen with an UNACKED request exits 0"   "$rc" "0"
assert_contains "reopen with an UNACKED request defers to it, by name" "$stdout" \
                "is still pending for this window+depth"
assert_eq       "reopen with an UNACKED request files no duplicate" \
                "$(count_spawn_reqs)" "1"
assert_file     "reopen with an UNACKED request still re-arms the gate" \
                "$STATE_DIR/skeptic/pending/sk-acked-worker"

echo '=== issue 16 SK1: a verdict landed WITHOUT a close still refuses a re-wrap ==='
# THE ROUND-2 REGRESSION TEST. Every other F1 assertion in this file and in
# test-skeptic-channel.sh drives the verdict through `skeptic-channel.sh
# close`, and that is exactly why a fully green suite missed SK1: `close` is
# the ONLY writer of the DONE sentinel, so a DONE-keyed guard looked correct
# everywhere it was tested.
#
# The PRODUCTION verdict path is `ng wrap-up --skeptic-role`, which clears
# the pending marker for the reviewed window AND the chain-root worker but
# NEVER writes DONE. That reaches `marker absent + DONE absent`, where the
# DONE-keyed guard computed done=0, took the honest-retry branch, returned
# 0, ran the whole hand-off and printed "the retire gate is STILL ARMED"
# while the gate was DOWN — the F1 fail-open through the other door.
#
# It is not an ordering slip: skills/nexus.skeptic's "Channel-close
# discipline across the chain" REQUIRES that only the final skeptic in a
# chain closes the original worker's channel, so a mid-chain skeptic
# returning a substantive verdict must land it exactly this way.
reset_mocks
SK1_REPORT="$FAKE_NEXUS/reports/sk1_2026-08-03_000000_x.md"
cp "$REPORT" "$SK1_REPORT"

export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk1-worker"
run_ng stdout stderr rc wrap-up 77 "$SK1_REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
assert_eq       "SK1 round 1 wrap-up exits 0"              "$rc" "0"
assert_file     "SK1 round 1 arms the retire gate"         "$STATE_DIR/skeptic/pending/sk1-worker"

# The skeptic reports its verdict through the real verb, and does NOT close.
export MOCK_TMUX_WINDOW="sk1-skeptic"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-role --skeptic-verdict check --skeptic-target sk1-worker \
    --skeptic-depth 1 --skeptic-findings 1
assert_eq       "SK1 skeptic verdict wrap-up exits 0"      "$rc" "0"
# The two halves of the defect's precondition, asserted separately so a
# future change to either writer fails HERE with a readable message.
assert_not_file "SK1 verdict CLEARED the worker's retire gate" \
                "$STATE_DIR/skeptic/pending/sk1-worker"
assert_not_file "SK1 verdict wrote NO DONE sentinel" \
                "$STATE_DIR/skeptic/sk1-worker/DONE"
# Baseline for the duplicate-request check is taken HERE, after the verdict.
# A substantive verdict (findings=1) legitimately files its own second-pass
# spawn-skeptic request, so measuring from before it would charge that
# request to the re-wrap and make the assertion lie about what it tests.
sk1_reqs_before=$(count_spawn_reqs)

# THE RE-WRAP. Worker remediated, appended to the same append-only report,
# and wraps up again. The gate is down, so this must fail CLOSED exactly as
# the close-driven path does.
export MOCK_TMUX_WINDOW="sk1-worker"
printf '\n<!-- remediation appended after the verdict -->\n' >> "$SK1_REPORT"
run_ng stdout stderr rc wrap-up 77 "$SK1_REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "SK1 re-wrap REFUSES (rc 1, fails closed)" "$rc" "1"
assert_contains "SK1 re-wrap says the retire gate is down" "$stdout" \
                "RETIRE GATE IS DOWN"
# The message must NOT make the false claim the DONE-keyed guard made.
assert_not_contains "SK1 re-wrap does not claim the gate is still armed" \
                    "$stdout" "RETIRE GATE STILL ARMED"
# ...and must diagnose THIS cause (no close) rather than the close cause.
assert_contains "SK1 re-wrap names the verdict-without-close history" "$stdout" \
                "a verdict WAS returned without closing the channel"
assert_not_contains "SK1 re-wrap does not claim a close happened" "$stdout" \
                    "A VERDICT DID LAND"
# SK1-c. `marker gone + no DONE` is reachable from TWO histories — a
# mid-chain verdict that (correctly) did not close, and no validation at
# all — and nothing on disk separates them. Round 2 asserted the first one
# outright ("a verdict was returned WITHOUT closing the channel", "the
# validation is over") and then offered "You are DONE ... retire", which is
# a fail-open instruction inside a fail-closed exit code for a
# require-mandated worker that was never validated. The message must state
# the ambiguity and must not resolve it in the unsafe direction.
assert_contains "SK1 re-wrap says validation is NOT established" "$stdout" \
                "WHETHER YOU WERE VALIDATED AT ALL IS NOT ESTABLISHED"
assert_contains "SK1 re-wrap names the never-validated history too" "$stdout" \
                "NO validation ever happened"
assert_not_contains "SK1 re-wrap does NOT declare the validation over" "$stdout" \
                    "the validation is over"
assert_contains "SK1 re-wrap flags that nothing corroborates the retire case" "$stdout" \
                "NOTHING HERE CORROBORATES (b)"
assert_contains "SK1 re-wrap offers the never-validated recovery (case c)" "$stdout" \
                "NO verdict was ever returned to"
assert_contains "SK1 re-wrap conditions retiring on a verdict the agent saw" "$stdout" \
                "a verdict WAS returned on"
# ...and stderr, which is where the worker floor sends agents on a
# non-zero wrap-up, must not carry the unconditional retire licence either.
assert_not_contains "stderr does NOT tell an unvalidated worker it is done" "$stderr" \
                    "otherwise you are done — retire"
assert_contains "stderr conditions retiring on a received verdict" "$stderr" \
                "you received a verdict on it"
# Nothing downstream ran, and nothing was re-armed or re-filed.
assert_not_contains "SK1 re-wrap does NOT upload"          "$stdout" "uploaded: https://github.com/asset-org"
assert_not_contains "SK1 re-wrap does NOT comment"         "$stdout" "posted comment"
assert_not_file "SK1 re-wrap does NOT re-arm the retire gate" \
                "$STATE_DIR/skeptic/pending/sk1-worker"
assert_eq       "SK1 re-wrap files no duplicate request"   "$(count_spawn_reqs)" "$sk1_reqs_before"
assert_contains "SK1 re-wrap names the failed step on stderr" "$stderr" \
                "REFUSED at the skeptic step"

echo '=== issue 16 SK1-d: all four gate quadrants, live vs orphaned reviewer ==='
# THE COVERAGE THE ROUND-2 COMMIT SHIPPED WITHOUT. Its own Infrastructure
# Issues note said "a green suite is not evidence when every assertion
# drives the same writer" — and then the one quadrant where behaviour moved
# toward PROCEEDING (marker present + DONE present) shipped with no
# assertion at all, so the branch that prints "a live reviewer holds this
# window right now" was dead code as far as the suite was concerned.
#
# The grid, keyed on the shared predicate (monitor/_skeptic_gate.sh):
#
#   marker    DONE     reviewer     gate-state     rc
#   ------------------------------------------------------
#   present   absent   live         live           0
#   present   absent   dead         orphaned       1   <- was 0 (pre-existing hole)
#   present   present  live         live           0
#   present   present  dead         orphaned       1   <- was 0 (SK1-b, opened by round 2)
#   absent    present  --           absent         1
#   absent    absent   --           absent         1
#
# The reviewer's liveness is driven ONLY through the tmux window set and
# the action-log `skeptic-spawn` event — i.e. through writers that never
# touch the marker file the guard keys on, which is the property round 2's
# note asks for and round 2's tests did not have.
CHAN_SH="$FAKE_NEXUS/monitor/skeptic-channel.sh"
cp "$_test_dir/../skeptic-channel.sh" "$CHAN_SH"; chmod +x "$CHAN_SH"

# Re-arm a marker exactly as spawn-worker.sh does at a real further-pass
# spawn (a plain depth write to pending/<window>) — never via ng, so the
# quadrant is reached by the production writer.
q_rearm() { printf '%s' "${2:-2}" > "$STATE_DIR/skeptic/pending/$1"; }
# Record a `skeptic-spawn` action-log event naming <reviewed> — the
# authoritative live-reviewer signal spawn-worker.sh emits. Liveness then
# depends on whether MOCK_LIVE_WINDOWS lists the skeptic window.
q_log_spawn() {
    printf '{"ts":"%s","event":"skeptic-spawn","window":"%s","target-window":"%s","orig-window":"%s"}\n' \
        "$(date -Iseconds)" "$2" "$1" "$1" >> "$STATE_DIR/action-log.jsonl"
}
# Age the gate for <window> by <seconds>: backdate the marker mtime and
# append a skeptic-request event with an older ts (the request epoch is the
# LAST matching event, so appending wins). Deterministic — driving the
# orphan state off a zero grace and real elapsed time would flake whenever
# two wrap-ups land inside the same second.
q_age_gate() {
    local win="$1" secs="${2:-300}" then
    then=$(( $(date +%s) - secs ))
    printf '{"ts":"%s","event":"skeptic-request","target-window":"%s","depth":"1"}\n' \
        "$(date -Iseconds -d "@$then")" "$win" >> "$STATE_DIR/action-log.jsonl"
    touch -d "@$then" "$STATE_DIR/skeptic/pending/$win"
}
# Last skeptic-decision reason recorded for this window.
q_last_reason() {
    grep -F '"event":"skeptic-decision"' "$STATE_DIR/action-log.jsonl" 2>/dev/null \
        | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | tail -1
}
q_last_gate_state() {
    grep -F '"event":"skeptic-decision"' "$STATE_DIR/action-log.jsonl" 2>/dev/null \
        | sed -n 's/.*"gate-state":"\([^"]*\)".*/\1/p' | tail -1
}
# Open a require round for <window> on its own copy of the report.
q_open_round() {
    export MOCK_TMUX=1 MOCK_TMUX_WINDOW="$1"
    run_ng stdout stderr rc wrap-up 77 "$2" --repo override-org/override-repo \
        --skeptic-decision require --skeptic-rationale "shared infra"
}
q_rewrap() {
    export MOCK_TMUX=1 MOCK_TMUX_WINDOW="$1"
    run_ng stdout stderr rc wrap-up 77 "$2" --repo override-org/override-repo \
        --skeptic-decision require --skeptic-rationale "shared infra"
}

# ---- quadrant: marker present + DONE absent + LIVE reviewer -> exit 0 ----
reset_mocks
Q_REPORT="$FAKE_NEXUS/reports/q1_2026-08-03_000000_x.md"; cp "$REPORT" "$Q_REPORT"
q_open_round q1-worker "$Q_REPORT"
assert_eq "q1: round 1 exits 0" "$rc" "0"
q_log_spawn q1-worker q1-worker-skeptic
export MOCK_LIVE_WINDOWS="q1-worker-skeptic"
q_rewrap q1-worker "$Q_REPORT"
assert_eq       "q1 (marker+no DONE+live): exits 0"        "$rc" "0"
assert_eq       "q1: gate-state is live"                   "$(q_last_gate_state)" "live"
assert_eq       "q1: reason names the armed gate"          "$(q_last_reason)" \
                "round-already-open-gate-armed"
assert_contains "q1: claims a LIVE reviewer (it checked one)" "$stdout" \
                "A reviewer is LIVE on this window right now"
assert_contains "q1: completes the hand-off"               "$stdout" \
                "uploaded: https://github.com/asset-org"

# ---- quadrant: marker present + DONE absent + reviewer DEAD -> refuse ----
# The PRE-EXISTING orphan hole (open in 45e11ae, round 1 and round 2
# alike): a first-pass skeptic that was required, spawned, and then died
# without a verdict leaves a marker nothing ever clears. Same state as q1
# except the reviewer's window is gone.
reset_mocks
unset MOCK_LIVE_WINDOWS
Q_REPORT="$FAKE_NEXUS/reports/q2_2026-08-03_000000_x.md"; cp "$REPORT" "$Q_REPORT"
q_open_round q2-worker "$Q_REPORT"
q_log_spawn q2-worker q2-worker-skeptic
# Past the spawn grace: the orchestrator has had its window to dispatch,
# and no reviewer is alive. (Inside the grace this is state `grace` and
# the gate legitimately still holds — asserted below.)
export MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS=60
q_age_gate q2-worker 300
q_rewrap q2-worker "$Q_REPORT"
assert_eq       "q2 (marker+no DONE+DEAD reviewer): REFUSES" "$rc" "1"
assert_eq       "q2: gate-state is orphaned"               "$(q_last_gate_state)" "orphaned"
assert_eq       "q2: reason names a gate that is down"     "$(q_last_reason)" \
                "round-gate-down-no-close"
assert_contains "q2: says the marker is ORPHANED, not gone" "$stdout" \
                "skeptic-pending marker is ORPHANED"
assert_not_contains "q2: does NOT claim a live reviewer"   "$stdout" \
                    "A reviewer is LIVE on this window right now"
assert_not_contains "q2: does NOT complete the hand-off"   "$stdout" \
                    "uploaded: https://github.com/asset-org"
assert_file     "q2: the marker itself is left alone"      "$STATE_DIR/skeptic/pending/q2-worker"

# ---- same state, INSIDE the spawn grace -> still gated, exit 0 ----------
# The grace is why an orphan refusal cannot fire on a worker whose skeptic
# is merely still being dispatched. Identical to q2 but with the grace
# restored, so the ONLY difference is elapsed time.
unset MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS
q_rewrap q2-worker "$Q_REPORT"
assert_eq       "q2-grace (same state, inside grace): exits 0" "$rc" "0"
assert_eq       "q2-grace: gate-state is grace"            "$(q_last_gate_state)" "grace"
assert_contains "q2-grace: says a reviewer is not visible YET" "$stdout" \
                "No live skeptic window is visible yet"
assert_not_contains "q2-grace: does NOT claim a live reviewer" "$stdout" \
                    "A reviewer is LIVE on this window right now"

# ---- quadrant: marker present + DONE present + LIVE reviewer -> exit 0 --
# The legitimate case the round-2 change was FOR: a verdict landed, the
# channel closed, a further pass was really spawned (re-arming the marker),
# and that reviewer must see the remediated hand-off.
reset_mocks
unset MOCK_LIVE_WINDOWS MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS
Q_REPORT="$FAKE_NEXUS/reports/q3_2026-08-03_000000_x.md"; cp "$REPORT" "$Q_REPORT"
q_open_round q3-worker "$Q_REPORT"
NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" close q3-worker >/dev/null
assert_file     "q3: close wrote the DONE sentinel"        "$STATE_DIR/skeptic/q3-worker/DONE"
assert_not_file "q3: close cleared the marker"             "$STATE_DIR/skeptic/pending/q3-worker"
q_rearm q3-worker 2                       # the further-pass spawn re-arms it
q_log_spawn q3-worker q3-worker-skeptic2
export MOCK_LIVE_WINDOWS="q3-worker-skeptic2"
printf '\n<!-- remediation appended -->\n' >> "$Q_REPORT"
q_rewrap q3-worker "$Q_REPORT"
assert_eq       "q3 (marker+DONE+live): exits 0"           "$rc" "0"
assert_eq       "q3: gate-state is live"                   "$(q_last_gate_state)" "live"
assert_eq       "q3: reason names the armed gate"          "$(q_last_reason)" \
                "round-already-open-gate-armed"
assert_contains "q3: claims a LIVE reviewer (it checked one)" "$stdout" \
                "A reviewer is LIVE on this window right now"
assert_contains "q3: explains the re-armed gate"           "$stdout" "RE-ARMED"
assert_contains "q3: completes the hand-off"               "$stdout" \
                "uploaded: https://github.com/asset-org"

# ---- quadrant: marker present + DONE present + reviewer DEAD -> refuse --
# SK1-b. Byte-identical on-disk state to q3; the ONLY difference is that
# the further-pass reviewer is no longer alive. Round 2 exited 0 here and
# printed q3's live-reviewer claim verbatim, so the remediation shipped
# with no reviewer, no replacement request, and retirement permitted.
reset_mocks
unset MOCK_LIVE_WINDOWS
Q_REPORT="$FAKE_NEXUS/reports/q4_2026-08-03_000000_x.md"; cp "$REPORT" "$Q_REPORT"
q_open_round q4-worker "$Q_REPORT"
NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" close q4-worker >/dev/null
q_rearm q4-worker 2
q_log_spawn q4-worker q4-worker-skeptic2
export MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS=60    # reviewer dead, past grace
q_age_gate q4-worker 300
printf '\n<!-- remediation appended -->\n' >> "$Q_REPORT"
q4_reqs_before=$(count_spawn_reqs)
q_rewrap q4-worker "$Q_REPORT"
assert_eq       "q4 (marker+DONE+DEAD reviewer): REFUSES"  "$rc" "1"
assert_eq       "q4: gate-state is orphaned"               "$(q_last_gate_state)" "orphaned"
assert_eq       "q4: reason names a gate that is down, verdict closed" \
                "$(q_last_reason)" "round-gate-down-verdict-closed"
assert_not_contains "q4: does NOT claim a live reviewer"   "$stdout" \
                    "A reviewer is LIVE on this window right now"
assert_contains "q4: says the marker is ORPHANED, not gone" "$stdout" \
                "skeptic-pending marker is ORPHANED"
# A verdict DID land here (DONE present), so unlike q2 the message may say
# so — and must, since that is what makes case (b) available.
assert_contains "q4: still credits the verdict that landed" "$stdout" \
                "A VERDICT DID LAND"
assert_contains "q4: names the dead further-pass reviewer" "$stdout" \
                "whose reviewer is no longer alive"
assert_not_contains "q4: does NOT complete the hand-off"   "$stdout" \
                    "uploaded: https://github.com/asset-org"
assert_eq       "q4: files no duplicate request"           "$(count_spawn_reqs)" "$q4_reqs_before"
assert_contains "q4: names the failed step on stderr"      "$stderr" \
                "REFUSED at the skeptic step"
assert_contains "q4: stderr carries the gate state"        "$stderr" "gate-state=orphaned"

# ---- quadrant: marker absent + DONE present -> refuse (regression) -----
# Covered end-to-end by the close-driven block above; asserted here on the
# action-log reason, which had no assertion anywhere before this block.
reset_mocks
unset MOCK_LIVE_WINDOWS MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS
Q_REPORT="$FAKE_NEXUS/reports/q5_2026-08-03_000000_x.md"; cp "$REPORT" "$Q_REPORT"
q_open_round q5-worker "$Q_REPORT"
NEXUS_STATE_DIR="$STATE_DIR" "$CHAN_SH" close q5-worker >/dev/null
q_rewrap q5-worker "$Q_REPORT"
assert_eq       "q5 (no marker + DONE): REFUSES"           "$rc" "1"
assert_eq       "q5: gate-state is absent"                 "$(q_last_gate_state)" "absent"
assert_eq       "q5: reason names verdict-closed"          "$(q_last_reason)" \
                "round-gate-down-verdict-closed"
assert_contains "q5: says the marker is GONE"              "$stdout" \
                "skeptic-pending marker is GONE"

# ---- DEGRADED MODE: the gate lib is unreachable ------------------------
# The predicate must not silently disagree with retire-preflight when the
# shared lib cannot be loaded. Both fall back to "marker present -> gated",
# so they stay in step; the message must then NOT claim a live reviewer.
reset_mocks
unset MOCK_LIVE_WINDOWS
Q_REPORT="$FAKE_NEXUS/reports/q6_2026-08-03_000000_x.md"; cp "$REPORT" "$Q_REPORT"
mv "$FAKE_NEXUS/monitor/_skeptic_gate.sh" "$WORK/_skeptic_gate.sh.hidden"
mv "$FAKE_NEXUS/monitor/watcher/_idle_probe.sh" "$WORK/_idle_probe.sh.hidden"
q_open_round q6-worker "$Q_REPORT"
assert_eq "q6: round 1 exits 0 without the gate lib" "$rc" "0"
q_rewrap q6-worker "$Q_REPORT"
assert_eq       "q6 (degraded, marker present): exits 0"   "$rc" "0"
assert_eq       "q6: gate-state is unclassified"           "$(q_last_gate_state)" "unclassified"
assert_contains "q6: says liveness could not be determined" "$stdout" \
                "could not be determined here"
assert_not_contains "q6: does NOT claim a live reviewer"   "$stdout" \
                    "A reviewer is LIVE on this window right now"
rm -f "$STATE_DIR/skeptic/pending/q6-worker"
q_rewrap q6-worker "$Q_REPORT"
assert_eq       "q6 (degraded, marker gone): REFUSES"      "$rc" "1"
assert_eq       "q6: gate-state is absent"                 "$(q_last_gate_state)" "absent"
mv "$WORK/_skeptic_gate.sh.hidden" "$FAKE_NEXUS/monitor/_skeptic_gate.sh"
mv "$WORK/_idle_probe.sh.hidden" "$FAKE_NEXUS/monitor/watcher/_idle_probe.sh"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_LIVE_WINDOWS MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS

echo '=== spawn-skeptic: off-tmux wrap-up (no window) files NOTHING ==='
reset_mocks
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
assert_eq       "off-tmux require wrap-up exits 0"         "$rc" "0"
assert_eq       "NO request filed without a source window" "$(count_spawn_reqs)" "0"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
