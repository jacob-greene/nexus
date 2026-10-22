#!/usr/bin/env bash
# The private vulnerability-report route must point at a real repository.
#
# SECURITY.md forbids a public issue and sends the reporter to GitHub's
# private-reporting form. A template placeholder such as `<your-org>` in
# that link resolves to a 404, so the reporter is left with no route
# (jacob-greene/nexus#151). This test fails while either copy of the
# link (SECURITY.md, docs/admin/security.md) holds a placeholder, and
# while either copy lacks the fallback for a repository where private
# reporting is switched off.
#
# Run: bash monitor/watcher/test-security-report-route.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$_test_dir/../.." && pwd)

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

for rel in SECURITY.md docs/admin/security.md; do
    f="$ROOT/$rel"
    if [[ ! -f "$f" ]]; then
        bad "$rel exists"
        continue
    fi
    links=$(grep -oE 'https://github\.com/[^)[:space:]]*/security/advisories/new' "$f" || true)
    if [[ -z "$links" ]]; then
        bad "$rel: names a private-reporting link"
        continue
    fi
    ok "$rel: names a private-reporting link"
    while IFS= read -r link; do
        # owner/repo must be two plain path segments, no template markup.
        if [[ "$link" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/security/advisories/new$ ]] \
            && [[ "$link" != *your-org* ]]; then
            ok "$rel: link has a concrete owner/repo ($link)"
        else
            bad "$rel: link holds a template placeholder ($link)"
        fi
    done <<< "$links"
    if tr '\n' ' ' < "$f" | grep -q 'asks for a private contact'; then
        ok "$rel: states the fallback when private reporting is off"
    else
        bad "$rel: states the fallback when private reporting is off"
    fi
done

printf '\n=== summary: %d passed, %d failed ===\n' "$pass" "$fail"
if (( fail > 0 )); then
    echo "FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
