#!/usr/bin/env bash
# Tests for monitor/evidence-freeze.sh — the durable-evidence freeze guard.
#
# Run: bash monitor/test-evidence-freeze.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE CONTRACT UNDER TEST. A freeze exists to prove afterwards that
# nothing was lost. The hand-rolled form it replaces —
#
#     cp -p <artefact> "$EV/<name>"
#     cd "$EV" && md5sum *.ipynb > MANIFEST.md5 && md5sum -c MANIFEST.md5
#
# — destroys the baseline and regenerates the checksum that would have
# caught it, in one command, so `md5sum -c` reports OK on the wrong
# bytes. Section "the incident, replayed" below runs exactly that
# sequence against the guard and asserts the baseline survives.
#
# Every assertion here was watched fail against a mutated script before
# it was trusted (see the mutation table in the PR body): dropping the
# `chmod 0440`, dropping the clobber refusal, and swapping `>>` for `>`
# each turn at least one case RED.
#
# Hermetic: everything happens under a fresh mktemp -d. No tmux, no
# network, no state outside the temp dir.
#
# Root note: three cases assert that the KERNEL refuses a write to a
# mode-0440 file. Root bypasses that check, so those cases self-skip
# under EUID 0 rather than reporting a false PASS.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FREEZE_BIN="${FREEZE_BIN:-$_test_dir/evidence-freeze.sh}"

PASS=0
FAIL=0
SKIP=0

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
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — %q not found in %q\n' "$label" "$needle" "$haystack" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

skip() {
    printf '  SKIP: %s\n' "$1"; SKIP=$(( SKIP + 1 ))
}

TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

md5of() { md5sum < "$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
echo "=== 1. a first freeze writes a read-only copy and an append-only manifest"
# ---------------------------------------------------------------------------
W="$TMP/w1"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")

out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1); rc=$?
assert_eq "first freeze exits 0" "$rc" "0"
assert_eq "frozen bytes match the source" "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
assert_eq "frozen copy is mode 0440" "$(stat -c '%a' "$W/ev/nb.PRE.txt")" "440"
assert_eq "manifest is mode 0440" "$(stat -c '%a' "$W/ev/MANIFEST.md5")" "440"
assert_eq "manifest has exactly one row" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"
assert_contains "manifest records the source hash" \
    "$(cat "$W/ev/MANIFEST.md5")" "$BASE_MD5  nb.PRE.txt"
assert_contains "stdout names the mode" "$out" "0440"

# ---------------------------------------------------------------------------
echo "=== 2. the copy is NOT cp -p: the frozen mtime is the freeze time"
# ---------------------------------------------------------------------------
# `cp -p` carried the SOURCE mtime, so a substituted freeze did not even
# look freshly written. The freeze time must be readable off the file.
W="$TMP/w2"; mkdir -p "$W/code"
printf 'OLD\n' > "$W/code/nb.txt"
touch -d '2001-02-03 04:05:06' "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
src_mtime=$(stat -c '%Y' "$W/code/nb.txt")
frz_mtime=$(stat -c '%Y' "$W/ev/nb.PRE.txt")
if (( frz_mtime > src_mtime )); then
    assert_eq "frozen mtime is later than the source mtime" "later" "later"
else
    assert_eq "frozen mtime is later than the source mtime" "src=$src_mtime frz=$frz_mtime" "later"
fi

# ---------------------------------------------------------------------------
echo "=== 3. a second freeze under the same name is REFUSED, not an overwrite"
# ---------------------------------------------------------------------------
W="$TMP/w3"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'REPLACEMENT\n' > "$W/code/nb.txt"

out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1); rc=$?
assert_eq "clobbering freeze exits 3" "$rc" "3"
assert_contains "refusal names the file" "$out" "nb.PRE.txt already exists"
assert_contains "refusal prints the existing hash" "$out" "$BASE_MD5"
assert_eq "baseline bytes are untouched" "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
assert_eq "manifest still has one row" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"

# ---------------------------------------------------------------------------
echo "=== 4. the incident, replayed: cp -p + manifest regeneration"
# ---------------------------------------------------------------------------
# The exact two-line sequence that destroyed fb2c326b on 2026-09-09,
# run against a freeze this script wrote. Both halves must fail.
W="$TMP/w4"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'REPLACEMENT\n' > "$W/code/nb.txt"

if (( EUID == 0 )); then
    skip "raw cp over a freeze fails (root bypasses mode 0440)"
    skip "manifest regeneration fails (root bypasses mode 0440)"
    skip "md5sum -c still reports the baseline (root)"
else
    cp_err=$(cp -p "$W/code/nb.txt" "$W/ev/nb.PRE.txt" 2>&1); cp_rc=$?
    assert_eq "raw cp -p over a freeze fails" "$cp_rc" "1"
    assert_contains "cp failure names permission" "$cp_err" "Permission denied"

    regen_rc=0
    ( cd "$W/ev" && md5sum ./*.txt > MANIFEST.md5 ) 2>/dev/null || regen_rc=$?
    if (( regen_rc != 0 )); then
        assert_eq "manifest regeneration fails" "failed" "failed"
    else
        assert_eq "manifest regeneration fails" "succeeded" "failed"
    fi

    assert_eq "baseline survives the replayed incident" \
        "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
    ( cd "$W/ev" && md5sum -c MANIFEST.md5 >/dev/null 2>&1 ); chk_rc=$?
    assert_eq "md5sum -c still passes on the true baseline" "$chk_rc" "0"
fi

# ---------------------------------------------------------------------------
echo "=== 5. a second, differently-named freeze APPENDS; the first row survives"
# ---------------------------------------------------------------------------
W="$TMP/w5"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
first_row=$(head -1 "$W/ev/MANIFEST.md5")
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.POST.txt 2>&1); rc=$?
assert_eq "second freeze under a new name exits 0" "$rc" "0"
assert_eq "manifest now has two rows" "$(wc -l < "$W/ev/MANIFEST.md5")" "2"
assert_eq "the first row is byte-identical" "$(head -1 "$W/ev/MANIFEST.md5")" "$first_row"
assert_eq "manifest is read-only again after the append" \
    "$(stat -c '%a' "$W/ev/MANIFEST.md5")" "440"

# ---------------------------------------------------------------------------
echo "=== 6. a manifest entry whose file was removed still blocks the name"
# ---------------------------------------------------------------------------
W="$TMP/w6"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
chmod u+w "$W/ev/nb.PRE.txt"; rm -f "$W/ev/nb.PRE.txt"
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1); rc=$?
assert_eq "re-using a recorded name exits 4" "$rc" "4"
assert_contains "refusal names the manifest" "$out" "MANIFEST.md5 already records"
assert_eq "manifest still has one row" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"

# A name that merely CONTAINS a recorded name must still be freezable.
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt.bak 2>&1); rc=$?
assert_eq "a superstring name is not blocked" "$rc" "0"

# ---------------------------------------------------------------------------
echo "=== 7. --verify reports the three invariants"
# ---------------------------------------------------------------------------
W="$TMP/w7"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of a clean dir exits 0" "$rc" "0"
assert_contains "verify says clean" "$out" "verified clean"

# (a) content substituted behind the guard's back → checksum mismatch
chmod u+w "$W/ev/nb.PRE.txt"
printf 'SUBSTITUTED\n' > "$W/ev/nb.PRE.txt"
chmod 0440 "$W/ev/nb.PRE.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of substituted content exits 5" "$rc" "5"
assert_contains "verify names the mismatch" "$out" "CHECKSUM MISMATCH"

# (b) a writable freeze is reported even when its checksum matches
W="$TMP/w7b"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
chmod u+w "$W/ev/nb.PRE.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of a writable freeze exits 5" "$rc" "5"
assert_contains "verify names the writable file" "$out" "WRITABLE freeze: nb.PRE.txt"

# (c) a writable manifest is reported on its own
W="$TMP/w7c"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
chmod u+w "$W/ev/MANIFEST.md5"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of a writable manifest exits 5" "$rc" "5"
assert_contains "verify names the writable manifest" "$out" "WRITABLE MANIFEST.md5"

# ---------------------------------------------------------------------------
echo "=== 8. --task resolves under the state dir"
# ---------------------------------------------------------------------------
W="$TMP/w8"; mkdir -p "$W/code" "$W/state"
printf 'BASELINE\n' > "$W/code/nb.txt"
out=$(NEXUS_STATE_DIR="$W/state" "$FREEZE_BIN" "$W/code/nb.txt" --task issue70 --as nb.PRE.txt 2>&1); rc=$?
assert_eq "--task freeze exits 0" "$rc" "0"
assert_eq "--task wrote under \$NEXUS_STATE_DIR/evidence/<slug>" \
    "$(stat -c '%a' "$W/state/evidence/issue70/nb.PRE.txt" 2>/dev/null)" "440"

# ---------------------------------------------------------------------------
echo "=== 9. usage errors are loud and write nothing"
# ---------------------------------------------------------------------------
W="$TMP/w9"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"

"$FREEZE_BIN" --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "no source exits 2" "$rc" "2"

"$FREEZE_BIN" "$W/code/missing.txt" --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "unreadable source exits 2" "$rc" "2"

"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as sub/dir.txt >/dev/null 2>&1; rc=$?
assert_eq "--as with a path separator exits 2" "$rc" "2"

"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as MANIFEST.md5 >/dev/null 2>&1; rc=$?
assert_eq "--as MANIFEST.md5 exits 2" "$rc" "2"

"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --task t >/dev/null 2>&1; rc=$?
assert_eq "--task with --dir exits 2" "$rc" "2"

"$FREEZE_BIN" --verify --dir "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
assert_eq "verify of a missing dir exits 2" "$rc" "2"

mkdir -p "$W/empty"
"$FREEZE_BIN" --verify --dir "$W/empty" >/dev/null 2>&1; rc=$?
assert_eq "verify of a dir with no manifest exits 5" "$rc" "5"

echo
printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "TESTS FAILED" >&2
exit 1
