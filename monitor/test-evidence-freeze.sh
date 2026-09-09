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
# it was trusted (see the mutation table in the PR body). Thirteen
# mutations are on record and every one turns at least one case RED:
# dropping the `chmod 0440`, dropping the clobber refusal, swapping
# `>>` for `>`, widening the evidence directory to 0777, dropping the
# rollback after a failed copy, dropping either mode read-back, and
# dropping the `./` normalisation in `_manifest_records`.
#
# A suite with no surviving mutant is a claim, not a fact. The first
# version of this file claimed it and a skeptic found three survivors:
# the evidence directory's mode, the failed-copy path, and the
# append-failure path. Cases 12, 13 and 14 exist because of that.
#
# Hermetic: everything happens under a fresh mktemp -d. No tmux, no
# network, no state outside the temp dir.
#
# Root note: three cases assert that the KERNEL refuses a write to a
# mode-0440 file. Root bypasses that check, so those cases self-skip
# under EUID 0 rather than reporting a false PASS. Cases 15 and 16 skip
# under root for the same reason.
#
# Two cases need a write to fail. `ulimit -f 0` lets a file be created
# and then fails the first byte written, which is how cases 13 and 14
# reach the failure paths. RLIMIT_FSIZE is not enforced on every
# filesystem, so those cases self-skip rather than pass when the limit
# does not bite.

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

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — %q was present in %q\n' "$label" "$needle" "$haystack" >&2
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

# ---------------------------------------------------------------------------
echo "=== 10. KNOWN LIMIT: remove-and-recreate is not prevented"
# ---------------------------------------------------------------------------
# Mode 0440 stops a WRITE, not an UNLINK. The evidence directory is
# writable, so the owning uid can remove a freeze and its manifest and
# put new bytes under the old name. This case pins the current truth so
# the suite is never read as proof of impossibility. If the guard is
# later hardened — by holding the DIRECTORY read-only between freezes —
# this case turns RED, and that is the correct signal to update it.
W="$TMP/w10"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
REPL_MD5=$(md5of "$W/code/nb.txt")

rm -f "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"; rm_rc=$?
assert_eq "rm of a mode-0440 freeze succeeds (dir is writable)" "$rm_rc" "0"
cp -p "$W/code/nb.txt" "$W/ev/nb.PRE.txt"
( cd "$W/ev" && md5sum ./*.txt > MANIFEST.md5 )
chmod 0440 "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "verify still reports clean after remove-and-recreate" "$rc" "0"
assert_eq "the substituted bytes are what is stored" \
    "$(md5of "$W/ev/nb.PRE.txt")" "$REPL_MD5"

# ---------------------------------------------------------------------------
echo "=== 11. --verify refuses a file the manifest does not record"
# ---------------------------------------------------------------------------
# `md5sum -c` walks the manifest, so it is blind in the other direction:
# bytes present under an unrecorded name passed every check. Top-level
# regular files only, and no name is exempt.
W="$TMP/w11"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1

printf 'NOBODY RECORDED ME\n' > "$W/ev/rogue.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify with an unrecorded file exits 6" "$rc" "6"
assert_contains "verify names the unrecorded file" "$out" "UNRECORDED file: rogue.txt"
assert_contains "verify does not call the dir clean" "$out" "unrecorded file(s)"

# Freezing it records it, and the directory is clean again.
"$FREEZE_BIN" "$W/ev/rogue.txt" --dir "$W/ev" --as rogue.FROZEN.txt >/dev/null 2>&1
rm -f "$W/ev/rogue.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify is clean once every file is recorded" "$rc" "0"

# A sub-directory is NOT walked: a bare name in a manifest cannot
# address one, so it could not be recorded even in principle.
mkdir -p "$W/ev/notes" && printf 'a note\n' > "$W/ev/notes/README.md"
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "a file inside a sub-directory does not trip exit 6" "$rc" "0"

# Exit 5 wins over exit 6: a broken invariant is the graver finding.
chmod u+w "$W/ev/MANIFEST.md5"
printf 'ROGUE AGAIN\n' > "$W/ev/rogue2.txt"
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "a broken invariant outranks an unrecorded file" "$rc" "5"

# A manifest written by hand as `md5sum ./*.txt` records `./nb.txt`.
# That is the same file, so it must not read as unrecorded.
W="$TMP/w11b"; mkdir -p "$W/ev"
printf 'BASELINE\n' > "$W/ev/nb.txt"
( cd "$W/ev" && md5sum ./*.txt > MANIFEST.md5 )
chmod 0440 "$W/ev/nb.txt" "$W/ev/MANIFEST.md5"
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "a ./-prefixed manifest name counts as recorded" "$rc" "0"

# ---------------------------------------------------------------------------
echo "=== 12. the evidence directory is created mode 0770, whatever the umask"
# ---------------------------------------------------------------------------
# The bypass in case 10 walks through the DIRECTORY's mode, and nothing
# asserted it. `mkdir -m` also makes the mode independent of the
# caller's umask, so this is a fact about the script, not the caller.
W="$TMP/w12"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
( umask 000; "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1 )
assert_eq "a created evidence dir is mode 0770 under umask 000" \
    "$(stat -c '%a' "$W/ev")" "770"

W="$TMP/w12b"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
( umask 022; "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1 )
assert_eq "a created evidence dir is mode 0770 under umask 022" \
    "$(stat -c '%a' "$W/ev")" "770"

# An EXISTING directory keeps its own mode: `mkdir -m` applies only to
# directories it creates. Freezing must not re-permission a live dir.
W="$TMP/w12c"; mkdir -p "$W/code"; mkdir -m 0700 "$W/ev"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
assert_eq "an existing evidence dir keeps its mode" "$(stat -c '%a' "$W/ev")" "700"

# ---------------------------------------------------------------------------
echo "=== 13. a failed copy leaves nothing behind"
# ---------------------------------------------------------------------------
# `ulimit -f 0` lets cp CREATE the target and then fail on the first
# byte written. Without the rollback, that empty file survives,
# unrecorded, and then blocks its own name with exit 3 forever.
W="$TMP/w13"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
out=$( ( ulimit -f 0; "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt ) 2>&1 ); rc=$?
if (( rc == 2 )); then
    assert_eq "a failed copy exits 2" "$rc" "2"
    assert_contains "the failure names the copy" "$out" "copy failed"
    if [[ -e "$W/ev/nb.PRE.txt" ]]; then
        assert_eq "a failed copy leaves no partial target" "left behind" "removed"
    else
        assert_eq "a failed copy leaves no partial target" "removed" "removed"
    fi
    # The name is free afterwards, because nothing was written.
    "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1; rc=$?
    assert_eq "the name is still freezable after a failed copy" "$rc" "0"
else
    # RLIMIT_FSIZE is not enforced everywhere. Skip rather than pass.
    skip "a failed copy leaves no partial target (RLIMIT_FSIZE not enforced here)"
    skip "the name is still freezable after a failed copy (same)"
    skip "a failed copy exits 2 (same)"
fi

# ---------------------------------------------------------------------------
echo "=== 14. a failed manifest append leaves the manifest read-only"
# ---------------------------------------------------------------------------
# An EMPTY source copies fine under `ulimit -f 0` — cp writes no bytes —
# so the first write to fail is the manifest append. That path must
# still restore mode 0440, or the manifest stays writable for good.
W="$TMP/w14"; mkdir -p "$W/code"
: > "$W/code/empty.txt"
out=$( ( ulimit -f 0; "$FREEZE_BIN" "$W/code/empty.txt" --dir "$W/ev" --as nb.PRE.txt ) 2>&1 ); rc=$?
if (( rc == 4 )); then
    assert_eq "a failed append exits 4" "$rc" "4"
    assert_contains "the failure says the freeze is NOT recorded" "$out" "NOT recorded"
    assert_eq "the manifest is left mode 0440 after a failed append" \
        "$(stat -c '%a' "$W/ev/MANIFEST.md5")" "440"
    assert_eq "the frozen copy is still mode 0440" \
        "$(stat -c '%a' "$W/ev/nb.PRE.txt")" "440"
else
    skip "a failed append exits 4 (RLIMIT_FSIZE not enforced here)"
    skip "the manifest is left mode 0440 after a failed append (same)"
    skip "the frozen copy is still mode 0440 (same)"
fi

# ---------------------------------------------------------------------------
echo "=== 15. a chmod that fails silently is caught, not printed over"
# ---------------------------------------------------------------------------
# The script used to run `chmod 0440 … || true` and then print
# `mode 0440 (read-only)` unconditionally. On a filesystem that ignores
# chmod, that is a success message standing in for an unrun check — the
# exact shape of the incident the guard exists to prevent.
#
# A PATH-front `chmod` stub that exits 0 and changes nothing simulates
# that filesystem. It is the only portable way to reach the branch;
# every real filesystem here honours chmod.
W="$TMP/w15"; mkdir -p "$W/code" "$W/stub"
printf 'BASELINE\n' > "$W/code/nb.txt"
printf '#!/bin/sh\nexit 0\n' > "$W/stub/chmod"
chmod +x "$W/stub/chmod"

if (( EUID == 0 )); then
    skip "a silently-failing chmod exits 7 (root: mode 0440 is not enforced anyway)"
    skip "a silently-failing chmod removes the copy (root)"
    skip "a silently-failing chmod records nothing (root)"
else
    out=$( PATH="$W/stub:$PATH" "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1 ); rc=$?
    assert_eq "a silently-failing chmod exits 7" "$rc" "7"
    assert_contains "the failure names the mode it could not set" "$out" "FAILED to set mode 0440"
    if [[ -e "$W/ev/nb.PRE.txt" ]]; then
        assert_eq "a silently-failing chmod removes the copy" "left behind" "removed"
    else
        assert_eq "a silently-failing chmod removes the copy" "removed" "removed"
    fi
    if [[ -e "$W/ev/MANIFEST.md5" ]]; then
        assert_eq "a silently-failing chmod records nothing" "recorded" "not recorded"
    else
        assert_eq "a silently-failing chmod records nothing" "not recorded" "not recorded"
    fi
    assert_not_contains "output never claims the mode it did not set" \
        "$out" "mode   0440 (read-only)"
fi

# ---------------------------------------------------------------------------
echo "=== 16. an unprotected manifest is reported, and the freeze is kept"
# ---------------------------------------------------------------------------
# The manifest chmod runs AFTER the append, so the freeze is already
# recorded. Undoing it would be wrong. The script must keep it, say
# plainly that the manifest is unprotected, and still exit non-zero.
#
# The stub passes every chmod through EXCEPT the one on the manifest,
# so the frozen copy really is 0440 and only the manifest branch fires.
W="$TMP/w16"; mkdir -p "$W/code" "$W/stub"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
real_chmod=$(command -v chmod)
{
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do case "$a" in *MANIFEST.md5) exit 0 ;; esac; done\n'
    printf 'exec %s "$@"\n' "$real_chmod"
} > "$W/stub/chmod"
"$real_chmod" +x "$W/stub/chmod"

if (( EUID == 0 )); then
    skip "an unprotected manifest exits 7 (root: mode 0440 is not enforced anyway)"
    skip "an unprotected manifest is named (root)"
    skip "the freeze is kept when only the manifest chmod fails (root)"
    skip "the manifest still records the freeze (root)"
else
    out=$( PATH="$W/stub:$PATH" "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1 ); rc=$?
    assert_eq "an unprotected manifest exits 7" "$rc" "7"
    assert_contains "the failure names the manifest" "$out" "FAILED to set mode 0440"
    assert_eq "the freeze is kept when only the manifest chmod fails" \
        "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
    assert_eq "the manifest still records the freeze" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"
    assert_not_contains "output never claims the manifest is append-only" \
        "$out" "is append-only"
fi

echo
printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "TESTS FAILED" >&2
exit 1
