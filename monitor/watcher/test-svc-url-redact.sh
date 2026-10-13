#!/usr/bin/env bash
# test-svc-url-redact.sh — `svc.sh status` never prints a secret-named URL
# query parameter, and keeps the full URL in a mode-0600 file it names.
#
# THE INCIDENT (2026-10-12). The jupyterlab row rendered
# `http://<host>:<port>/lab?token=<the live JupyterLab token>`, so every agent
# that ran `svc.sh status` copied the credential into its transcript (and from
# there into reports and issue comments). The redaction covers every URL source
# the DETAIL cell has — a labsh JupyterLab row (`.jupyter/token`), a service's
# `.deploy/endpoint`, a healthcheck URL — and every parameter NAME ending in
# token / key / secret / password / passwd, case-insensitively.
#
# Cases and why:
#   R1  .deploy/endpoint with ?token=SECRETX → SECRETX absent from stdout AND
#       stderr; the cell names the 0600 file; other params survive verbatim
#   R2  the 0600 file holds the full URL, mode 600 exactly
#   R3  a labsh JupyterLab row (token from .jupyter/token) → token absent, file 600
#   R4  key / api_key / Client_Secret / password / Access_Token → all absent
#   N1  no secret-named param → URL byte-identical, NO file written
#   R5  a pre-existing file at mode 644 is rewritten at 600
#   R6  state dir unwritable → still redacted, cell says "not saved" (the
#       failure direction is "less convenient", never "leaked")
#
# Synthetic secrets only (SECRETX…); every healthcheck is `exit 0`, so no
# port is touched. Private TMUX_TMPDIR: no live board is read.
#
# Run: bash monitor/watcher/test-svc-url-redact.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SVC="$_dir/../svc.sh"

W=$(mktemp -d)
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
STATE="$W/root/monitor/.state"
mkdir -p "$STATE" "$W/tmx"

endpoint() {   # <svcdir> <url>
    mkdir -p "$W/$1/.deploy"; printf '%s\n' "$2" > "$W/$1/.deploy/endpoint"
}
endpoint r1 'http://localhost:1/app?token=SECRETX1&view=a#frag'
endpoint r4 'http://localhost:1/x?key=SECRETK4&api_key=SECRETA4&Client_Secret=SECRETC4&password=SECRETP4&Access_Token=SECRETT4&page=2'
endpoint n1 'http://localhost:1/plain?view=a&tokenized=no'
endpoint r5 'http://localhost:1/r5?token=SECRETX5'
mkdir -p "$W/r3/.jupyter"
printf 'PORT=1\nSCHEME=http\n' > "$W/r3/.jupyter/labsh-service.env"
printf 'SECRETJ3\n' > "$W/r3/.jupyter/token"

REG="$W/registry"
printf '%s\t%s\t%s\t%s\n' \
    r1svc "$W/r1" 'echo run' 'exit 0' \
    r3svc "$W/r3" "$W/r3/labsh-supervised.sh" 'exit 0' \
    r4svc "$W/r4" 'echo run' 'exit 0' \
    n1svc "$W/n1" 'echo run' 'exit 0' \
    r5svc "$W/r5" 'echo run' 'exit 0' \
    > "$REG"

run_status() {   # → sets OUT ERR RC
    env -u TMUX TMUX_TMPDIR="$W/tmx" NEXUS_ROOT="$W/root" NEXUS_STATE_DIR="$STATE" \
        NEXUS_SERVICES_REGISTRY="$REG" timeout 120 bash "$SVC" status > "$W/out" 2> "$W/err"
    RC=$?
    OUT=$(<"$W/out"); ERR=$(<"$W/err")
}
row() { grep -E "^ *[0-9-]+ +$1 " <<<"$OUT"; }
mode() { stat -c '%a' "$1" 2>/dev/null || echo none; }

# R5's file pre-exists, too permissive, holding a stale URL.
mkdir -p "$STATE/services"
printf 'http://localhost:1/r5?token=OLD\n' > "$STATE/services/r5svc.url"
chmod 644 "$STATE/services/r5svc.url"

echo '=== secrets never reach the status output ==='
run_status
ALL="$OUT$ERR"
assert_not_contains "R1 the endpoint token is absent from stdout+stderr" "$ALL" "SECRETX1"
assert_contains     "R1 the cell names the 0600 file"     "$(row r1svc)" "?token=<redacted: see $STATE/services/r1svc.url>"
assert_contains     "R1 other params and the fragment survive" "$(row r1svc)" ">&view=a#frag"
assert_eq           "R2 the full URL is kept in the file" "$(cat "$STATE/services/r1svc.url" 2>/dev/null)" 'http://localhost:1/app?token=SECRETX1&view=a#frag'
assert_eq           "R2 …at mode 600"                     "$(mode "$STATE/services/r1svc.url")" "600"
assert_not_contains "R3 the JupyterLab token is absent"   "$ALL" "SECRETJ3"
assert_contains     "R3 the labsh row is redacted"        "$(row r3svc)" "/lab?token=<redacted: see $STATE/services/r3svc.url>"
assert_contains     "R3 the file holds the tokened URL"   "$(cat "$STATE/services/r3svc.url" 2>/dev/null)" "?token=SECRETJ3"
assert_eq           "R3 …at mode 600"                     "$(mode "$STATE/services/r3svc.url")" "600"
for s in SECRETK4 SECRETA4 SECRETC4 SECRETP4 SECRETT4; do
    assert_not_contains "R4 $s (a secret-named param) is absent" "$ALL" "$s"
done
assert_contains     "R4 a non-secret param survives"      "$(row r4svc)" "&page=2"
assert_contains     "N1 a URL with no secret-named param is untouched" "$(row n1svc)" "http://localhost:1/plain?view=a&tokenized=no"
assert_eq           "N1 …and no file is written for it"   "$(mode "$STATE/services/n1svc.url")" "none"
assert_eq           "R5 a 644 file is rewritten at 600"   "$(mode "$STATE/services/r5svc.url")" "600"
assert_eq           "R5 …with the current URL"            "$(cat "$STATE/services/r5svc.url" 2>/dev/null)" 'http://localhost:1/r5?token=SECRETX5'

echo '=== an unwritable state dir still redacts ==='
rm -f "$STATE/services/r1svc.url"
chmod 500 "$STATE/services"
run_status
chmod 700 "$STATE/services"
assert_not_contains "R6 unwritable: the token is still absent" "$OUT$ERR" "SECRETX1"
assert_contains     "R6 …and the cell says the URL was not saved" "$(row r1svc)" "?token=<redacted: full URL not saved>"

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact).
EXPECTED=21
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
