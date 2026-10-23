#!/usr/bin/env bash
# Regression test for `monitor/upload-asset.sh --repo-path` naming a
# directory (issue #211). Before the fix, `cp "$blob" "$dest"` with an
# existing directory as $dest dropped the internal staging blob
# (req.XXXXXXXXXX.blob) into it, committed that, and exited 0 with a URL
# that named the directory.
#
# Run: bash monitor/watcher/test-upload-asset-repo-path.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Hermetic: the harness is the one in test-upload-asset-gitignore.sh (a
# local bare repo as the asset remote, PATH-stubbed git that no-ops
# `set-url`, stub mint-token.sh and config/load.sh). No network.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_real_script="$_test_dir/../upload-asset.sh"

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
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
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
    if ! grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — unexpected substring %q in output\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d -t nexus-test-upload-asset-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REAL_GIT=$(command -v git)
[[ -x "$REAL_GIT" ]] || { echo "git not on PATH; cannot run test" >&2; exit 2; }

# ---- build a fake nexus root and a local bare "asset remote" ------------

setup_fake_nexus() {
    # Args: $1 = gitignore body (multi-line OK; empty to skip seed).
    local gitignore_body="${1-}"

    FAKE_NEXUS="$WORK/nexus"
    BARE="$WORK/asset-repo.git"

    rm -rf "$FAKE_NEXUS" "$BARE"
    mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"

    # Local bare repo as the "remote". Force HEAD to `main` so the
    # script's `git fetch origin main` / `git push origin main` line up.
    "$REAL_GIT" init --quiet --bare "$BARE"
    "$REAL_GIT" --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

    # Seed the bare with an initial commit carrying the test .gitignore.
    local seed="$WORK/seed"
    rm -rf "$seed"
    "$REAL_GIT" clone --quiet "$BARE" "$seed" 2>/dev/null
    if [[ -n "$gitignore_body" ]]; then
        printf '%s\n' "$gitignore_body" > "$seed/.gitignore"
        "$REAL_GIT" -C "$seed" \
            -c user.name=test -c user.email=test@example.com \
            add .gitignore
    fi
    # Always create at least one commit so `main` exists on the bare.
    "$REAL_GIT" -C "$seed" \
        -c user.name=test -c user.email=test@example.com \
        commit --quiet --allow-empty -m "seed: ${gitignore_body:-empty}"
    "$REAL_GIT" -C "$seed" branch -M main 2>/dev/null || true
    "$REAL_GIT" -C "$seed" push --quiet origin HEAD:main
    rm -rf "$seed"

    # Copy upload-asset.sh into the fake nexus so its $_nexus_root
    # resolves to $FAKE_NEXUS rather than the real repo root.
    cp "$_real_script" "$FAKE_NEXUS/monitor/upload-asset.sh"
    chmod +x "$FAKE_NEXUS/monitor/upload-asset.sh"
    # upload-asset.sh sources the shared primary-root resolver and REFUSES
    # (exit 4) without it (your-org/nexus-code#1077), so the fake nexus ships it.
    cp "$_test_dir/../_nexus-root.sh" "$FAKE_NEXUS/monitor/_nexus-root.sh"

    # Stub mint-token.sh: prints a deterministic fake token.
    cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "fake-token-for-tests"
STUB
    chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

    # Stub config/load.sh: matches signature `<key> [default]`.
    cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.asset_repo)    printf 'fake-owner/fake-repo' ;;
    github.repo)          printf 'fake-owner/fake-repo' ;;
    github.bot_git_name)  printf 'test-bot[bot]' ;;
    github.bot_git_email) printf 'test-bot[bot]@users.noreply.github.com' ;;
    *)                    printf '%s' "${2-}" ;;
esac
STUB
    chmod +x "$FAKE_NEXUS/config/load.sh"

    # Pre-clone the bare into $FAKE_NEXUS/assets so upload-asset.sh's
    # `if [[ ! -d "$ASSETS_DIR/.git" ]]` branch skips the github.com
    # clone path. The script will still `remote set-url origin` to a
    # github.com URL — we intercept that via the PATH stub below.
    "$REAL_GIT" clone --quiet "$BARE" "$FAKE_NEXUS/assets"
}

# PATH stub for `git`: no-ops any invocation that mentions `set-url`
# (so the script can't repoint origin at github.com), otherwise passes
# through to the real git binary captured at setup time.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
    [[ "\$arg" == "set-url" ]] && exit 0
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$STUB_DIR/git"

run_upload() {
    # Args: <local_file> [extra upload-asset.sh args...]
    # Sets stdout, stderr, rc as caller-visible vars.
    local _local="$1"; shift
    local _out _err _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG -u NEXUS_ROOT \
        PATH="$STUB_DIR:$PATH" \
        "$FAKE_NEXUS/monitor/upload-asset.sh" "$_local" "$@" \
        >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _out=$(<"$_out_tmp"); _err=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    stdout="$_out"; stderr="$_err"; rc="$_rc"
}

tree() { "$REAL_GIT" --git-dir="$BARE" ls-tree -r --name-only main; }

setup_fake_nexus ""
PAYLOAD="$WORK/report.md"
printf 'line one\n' > "$PAYLOAD"

echo '=== seed: a normal upload creates assets/88/ ==='
run_upload "$PAYLOAD" --issue 88
assert_eq "seed upload exit 0" "$rc" "0"
head_before=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)

echo '=== --repo-path naming an existing directory is refused up front ==='
printf 'line one\nline two\n' > "$PAYLOAD"
run_upload "$PAYLOAD" --repo-path 88
assert_eq "exit 1" "$rc" "1"
assert_eq "no URL on stdout" "$stdout" ""
assert_contains "error names the directory" "$stderr" "assets/88 names a directory"
assert_contains "error suggests <dir>/<basename>" "$stderr" "--repo-path assets/88/report.md"
assert_eq "remote main unchanged" "$("$REAL_GIT" --git-dir="$BARE" rev-parse main)" "$head_before"
assert_not_contains "no staging blob on the remote" "$(tree)" ".blob"

echo '=== a trailing slash is refused up front ==='
run_upload "$PAYLOAD" --repo-path assets/99/
assert_eq "exit 1" "$rc" "1"
assert_contains "error suggests <dir>/<basename>" "$stderr" "--repo-path assets/99/report.md"
assert_eq "remote main unchanged" "$("$REAL_GIT" --git-dir="$BARE" rev-parse main)" "$head_before"

echo '=== drain backstop: the directory exists on the remote only ==='
# Another clone creates assets/77/ on the remote; the local checkout does
# not have it yet, so the up-front check passes and the drain must refuse.
other="$WORK/other"
"$REAL_GIT" clone --quiet "$BARE" "$other"
mkdir -p "$other/assets/77"; printf 'x\n' > "$other/assets/77/x.md"
"$REAL_GIT" -C "$other" add assets/77/x.md
"$REAL_GIT" -C "$other" -c user.name=t -c user.email=t@example.com commit --quiet -m other
"$REAL_GIT" -C "$other" push --quiet origin HEAD:main
head_other=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
[[ -d "$FAKE_NEXUS/assets/assets/77" ]] && echo "  (fixture premise broken: local checkout already has assets/77)" >&2
run_upload "$PAYLOAD" --repo-path 77
assert_eq "exit 1" "$rc" "1"
assert_eq "no URL on stdout" "$stdout" ""
assert_contains "drain logs the skip" "$stderr" "assets/77 is a directory in the asset repo"
assert_eq "remote main unchanged" "$("$REAL_GIT" --git-dir="$BARE" rev-parse main)" "$head_other"
assert_not_contains "no staging blob on the remote" "$(tree)" ".blob"
left=$(find "$FAKE_NEXUS/assets.staging" -maxdepth 1 -name 'req.*' 2>/dev/null)
assert_eq "no request files left in staging" "$left" ""

echo '=== a file path in the same directory still uploads ==='
# A NEW file name: assets/88/report.md already holds the seed's bytes, and a
# differing upload onto it is now refused as a clobber (exit 5,
# your-org/nexus-code#1639) — a different guard from the one tested here.
run_upload "$PAYLOAD" --repo-path 88/notes.md
assert_eq "exit 0" "$rc" "0"
assert_contains "URL names the file" "$stdout" "assets/88/notes.md"
assert_contains "the file landed in the directory" "$(tree)" "assets/88/notes.md"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
