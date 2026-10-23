#!/usr/bin/env bash
# test-argv-credential-lint.sh — no tracked file may put a RUNTIME credential in
# a command's argv (your-org/nexus-code#1840). argv sits in /proc/<pid>/cmdline,
# mode 0444, for the whole life of the process, so every same-uid agent on the
# board can read it with a routine `ps` — which is how #1840 was found: a live
# GitHub App JWT in another session's curl argv. The operator's long-lived PAT
# (monitor/user-pat.sh, `ng fetch-asset`) and the Anthropic API key
# (_unstick.sh) went the same way.
#
# The safe forms, which this lint does NOT flag:
#   curl -H @<(printf 'Authorization: Bearer %s\n' "$tok")   # header file, argv says /dev/fd/N
#   curl -K <(printf 'form = "token=%s"\n' "$tok")           # curl config, same
#   git -c "credential.helper=!f() { … \"$VAR\" …; }; f"      # helper names the VARIABLE
#   GIT_ASKPASS=<script> … https://x-access-token@github.com/…  # username only in the URL
# printf is a shell builtin, so the value never reaches an execve.
#
# THE FORMS FLAGGED (one regex each, case-insensitive, over source TEXT):
#   F1 header   -H/--header carrying Authorization, Proxy-Authorization,
#               X-Api-Key, Private-Token, X-Auth-Token or Cookie whose value
#               contains `$`, a backtick or a Python `{` — shell AND a Python
#               argv list ("-H", f"Authorization: …").
#   F2 url      a credential inside a URL: `://user:$X@` / `://user:$(cmd)@`.
#   F3 form     -F/-d/--data*/--form carrying token|secret|password|api_key
#               =<runtime value>.
#   F4 basic    curl -u / --user user:<runtime value>.
#   F5 query    a credential in a URL QUERY STRING: ?/&access_token, private
#               token, api_key or token =<runtime value>.
#   F6 githeader  git's http.extraHeader (any case) set in argv (`git -c`,
#               `git config`) to an Authorization header with a runtime value.
#   F7 oauth2   curl --oauth2-bearer <runtime value>.
# F5..F7 were added after the #1846 skeptic (N1) found all three missing.
# A literal value (`-H 'Authorization: token WRONG'` in a fixture) is NOT a
# runtime credential and is not flagged: a secret committed as a literal is a
# different defect with a different remedy. A line carrying
# `argv-credential-ok: <reason>` is exempt; the set of such files is pinned
# below so an exemption cannot be added without changing this suite.
#
# COVERAGE BOUNDARY, and the direction it errs in. Population: every tracked
# file except `*.ansi` captures and this suite; Markdown is scanned only inside
# ``` fences (prose that QUOTES the bad form to forbid it is not code).
# Line-oriented: a header assembled across lines (`h="Authorization: Bearer";
# curl -H "$h $tok"`) or by a helper whose name hides the value is NOT seen, so
# a zero here means "none in the seven forms F1..F7", never "none". It UNDER-counts.
# Environment variables are out of scope on purpose: /proc/<pid>/environ is
# 0400 (same uid only, not world-readable like cmdline), which is the boundary
# the fix moves credentials TO, not a leak this lint hunts.
#
# Run: bash monitor/watcher/test-argv-credential-lint.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SELF=monitor/watcher/test-argv-credential-lint.sh

_ac_population() {
    ( cd "$REPO_ROOT" && git ls-files ) | grep -vE '\.ansi$' | grep -vxF "$SELF"
}
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { _ac_population; }
gp_handle "$@"

WORK=$(mktemp -d -t nxargvcred-XXXXXX); trap 'rm -rf "$WORK"' EXIT

# The scanner: file paths on argv, offenders `path:line:form: text` on stdout.
cat > "$WORK/scan.py" <<'PY'
import re, sys
HDR = r'(authorization|proxy-authorization|x-api-key|private-token|x-auth-token|cookie)'
RV = r'''(\$\([^)]*\)|\$\{?\w+\}?|`[^`]*`)'''   # $(cmd), ${x}, $x, `cmd`
OK = "argv-credential-ok:"
FORMS = [
    # A runtime value INSIDE the header's own quotes: a double-quoted shell
    # string carrying $ or a backtick, or a Python f-string carrying {. A
    # single-quoted shell string is literal, so it is not a runtime credential.
    ("F1", re.compile(r'''(-H|--header)['"]?\s*[,=]?\s*'''
                      r'''("\s*''' + HDR + r'''\s*:[^"\n]*(\$|`)'''
                      r'''|f["']\s*''' + HDR + r'''\s*:[^"'\n]*\{)''', re.I)),
    ("F2", re.compile(r'''://[^\s/@'"]*:''' + RV + r'''[^\s@'"]*@''', re.I)),
    ("F3", re.compile(r'''(-F|-d|--data[a-z-]*|--form)['"]?\s*[,=]?\s*['"]?[a-z_]*(token|secret|password|api_?key)=(\$|`|\{)''', re.I)),
    ("F4", re.compile(r'''curl\b[^\n|;]*\s(-u|--user)\s*['"]?[^\s'"]*:(\$|`)''', re.I)),
    # F5..F7: your-org/nexus-code#1846 skeptic N1, three argv forms F1..F4 did
    # not see. F5 a credential in a URL QUERY STRING (`?access_token=$tok`,
    # `&private_token=…`), which F2's `user:pass@` shape never matches. The
    # query must sit in the SAME token as a `://`: a URL assembled in a string
    # (svc.sh's `url+="?token=$token"`, then printf'd, never exec'd) and prose
    # quoting the parameter name are not argv, and the corpus run showed both.
    # Round 2 (skeptic ncbundle29-sk F3, your-org/nexus-code#1847): a base URL
    # held in a VARIABLE (`"$API/user?access_token=$tok"`) counts as a URL too,
    # and a value spliced in after the quote closes (`'…?access_token='"$tok"`)
    # is still a runtime value. svc.sh's `url+="?token=$token"` stays clean: no
    # `://` and no `$VAR/` precedes its query.
    ("F5", re.compile(r'''(://|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)[^\s'"]*[?&](access_?token|private_?token|api_?key|token)=(\'")?(\$|`|\{)''', re.I)),
    # F6 git's http.extraHeader set on the command line (`git -c`, or `git
    # config`, which ALSO persists it): the value must FOLLOW the key, so the
    # environment form GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0=…
    # does not match. Quote type is not inspected, so it may over-count.
    # Round 2 (ncbundle29-sk F3): the URL-SCOPED key `http.<url>.extraheader`,
    # the form actions/checkout writes, is the same header with a URL between.
    ("F6", re.compile(r'''http\.([^\s'"=]*\.)?extraheader['"]?\s*[=\s]\s*['"]?\s*(f['"])?\s*authorization\s*:[^'"\n]*(\$|`|\{)''', re.I)),
    # F7 curl --oauth2-bearer <runtime value>: double-quoted with $ or a
    # backtick, a bare $x/backtick, or a Python f-string with {.
    ("F7", re.compile(r'''--oauth2-bearer['"]?\s*[,=\s]\s*("[^"\n]*(\$|`)|\$|`|f['"][^'"\n]*\{)''', re.I)),
]
for path in sys.argv[1:]:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except (IsADirectoryError, FileNotFoundError):
        continue
    md = path.endswith(".md")
    fence = False
    for i, line in enumerate(lines, 1):
        if md:
            if line.lstrip().startswith("```"):
                fence = not fence
                continue
            if not fence:
                continue
        if OK in line:
            continue
        for name, rx in FORMS:
            if rx.search(line):
                print("%s:%d:%s: %s" % (path, i, name, line.strip()[:160]))
                break
PY
_scan() { python3 "$WORK/scan.py" "$@"; }

echo '=== positive control: every form is SEEN when planted ==='
# Synthetic values only; none of these is, or resembles, a real credential.
cat > "$WORK/planted.sh" <<'FIX'
curl -sS -H "Authorization: Bearer $app_jwt" https://example.invalid/
    -H "Authorization: Bearer ${PAT}" \
curl -H "x-api-key: $(cat keyfile)" https://example.invalid/
git clone "https://x-access-token:${TOKEN}@github.com/o/r.git"
uv pip install "git+https://x-access-token:$(gh auth token)@github.com/o/r@abc"
curl -F "token=$app" -F "user=$user" https://example.invalid/
curl -sS -u "bot:$pw" https://example.invalid/
FIX
cat > "$WORK/planted.py" <<'FIX'
subprocess.run(["curl", "-H", f"Authorization: Bearer {tok}", url])
FIX
cat > "$WORK/planted.md" <<'FIX'
Prose quoting `-H "Authorization: Bearer $JWT"` to forbid it is not code.
```bash
curl -H "Authorization: Bearer $JWT" https://example.invalid/
```
FIX
hits=$(_scan "$WORK/planted.sh" "$WORK/planted.py" "$WORK/planted.md")
assert_eq "planted: all 7 shell lines are flagged" "$(printf '%s\n' "$hits" | grep -c 'planted.sh:')" "7"
assert_contains "planted: F1 Bearer header"              "$hits" 'planted.sh:1:F1:'
assert_contains "planted: F1 continuation-line header"   "$hits" 'planted.sh:2:F1:'
assert_contains "planted: F1 x-api-key via substitution" "$hits" 'planted.sh:3:F1:'
assert_contains "planted: F2 token in a git URL"         "$hits" 'planted.sh:4:F2:'
assert_contains "planted: F2 PAT in a uv URL"            "$hits" 'planted.sh:5:F2:'
assert_contains "planted: F3 form token"                 "$hits" 'planted.sh:6:F3:'
assert_contains "planted: F4 basic auth"                 "$hits" 'planted.sh:7:F4:'
assert_contains "planted: F1 Python argv list"           "$hits" 'planted.py:1:F1:'
assert_contains "planted: Markdown inside a fence"       "$hits" 'planted.md:3:F1:'
assert_not_contains "planted: Markdown prose is NOT flagged" "$hits" 'planted.md:1:'

echo '=== negative control: the safe forms and literal fixtures are NOT flagged ==='
cat > "$WORK/safe.sh" <<'FIX'
curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$app_jwt") https://example.invalid/
curl -K <(printf 'form = "token=%s"\n' "$app") -F "title=$TITLE" https://example.invalid/
curl -fs -H 'Authorization: token WRONG' http://127.0.0.1:1/
git -c "credential.helper=!f() { printf 'password=%s\n' \"$NEXUS_ASSET_TOKEN\"; }; f" fetch
ASSET_URL_NOAUTH="https://github.com/${REPO}.git"
GIT_ASKPASS="$ap" uv pip install "git+https://x-access-token@github.com/o/r@abc"
echo "async-run: launched token=$token"
FIX
safe_hits=$(_scan "$WORK/safe.sh")
assert_eq "safe forms: zero hits${safe_hits:+ — got:
$safe_hits}" "$(printf '%s' "$safe_hits" | grep -c . || true)" "0"

echo '=== F5..F7 (your-org/nexus-code#1846 skeptic N1): each SEEN, and each NOT over-matching ==='
# A form added without its own planted positive is a regex nobody has seen
# fire, and one added without a planted negative may flag the very forms the
# fix moves credentials TO. So each new form gets both, in its own file, and
# the assertions name the FORM, not only the line, so a hit by the wrong arm
# (an F1 match on an F6 line) does not pass as coverage.
cat > "$WORK/planted-n1.sh" <<'FIX'
curl -sS "https://example.invalid/api?access_token=$tok"
curl -sS "https://example.invalid/api?per_page=1&access_token=${GH_TOKEN}"
git -c http.extraHeader="Authorization: Bearer $tok" fetch origin
git -c "http.extraheader=AUTHORIZATION: basic $(printf x:%s "$pat" | base64)" push
curl -sS --oauth2-bearer "$tok" https://example.invalid/
git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $b64" fetch
curl -sS "$API/user?access_token=$tok"
curl -sS 'https://example.invalid/a?access_token='"$tok"
FIX
cat > "$WORK/planted-n1.py" <<'FIX'
subprocess.run(["git", "-c", f"http.extraHeader=Authorization: Bearer {tok}", "fetch"])
subprocess.run(["curl", "--oauth2-bearer", f"{tok}", url])
FIX
n1_hits=$(_scan "$WORK/planted-n1.sh" "$WORK/planted-n1.py")
assert_eq "N1 planted: all 8 shell lines are flagged" "$(printf '%s\n' "$n1_hits" | grep -c 'planted-n1.sh:')" "8"
assert_contains "N1 planted: F5 ?access_token= in a URL"         "$n1_hits" 'planted-n1.sh:1:F5:'
assert_contains "N1 planted: F5 &access_token= in a URL"         "$n1_hits" 'planted-n1.sh:2:F5:'
assert_contains "N1 planted: F6 git -c http.extraHeader"         "$n1_hits" 'planted-n1.sh:3:F6:'
assert_contains "N1 planted: F6 lowercase extraheader, upper value" "$n1_hits" 'planted-n1.sh:4:F6:'
assert_contains "N1 planted: F7 curl --oauth2-bearer"            "$n1_hits" 'planted-n1.sh:5:F7:'
assert_contains "N1 planted: F6 URL-scoped http.<url>.extraheader (ncbundle29-sk F3)" "$n1_hits" 'planted-n1.sh:6:F6:'
assert_contains "N1 planted: F5 \$VAR/…?access_token= base URL in a variable (ncbundle29-sk F3)" "$n1_hits" 'planted-n1.sh:7:F5:'
assert_contains "N1 planted: F5 quote-spliced ?access_token='\"\$tok\" (ncbundle29-sk F3)" "$n1_hits" 'planted-n1.sh:8:F5:'
assert_contains "N1 planted: F6 Python argv f-string"            "$n1_hits" 'planted-n1.py:1:F6:'
assert_contains "N1 planted: F7 Python argv f-string"            "$n1_hits" 'planted-n1.py:2:F7:'
# The negatives: a LITERAL value (a fixture), and the environment / config-file
# forms that keep the value out of argv. One or more per form.
cat > "$WORK/safe-n1.sh" <<'FIX'
curl -fs "http://127.0.0.1:1/api?access_token=FIXTURE-NOT-A-TOKEN"
access_token=$(jq -r .access_token "$f"); export access_token
curl -sS "https://example.invalid/api?page=$page&per_page=100"
[[ -n "$token" ]] && url+="?token=$token"
git -c 'http.extraHeader=Authorization: Bearer FIXTURE' fetch origin
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: Bearer $tok" git fetch
curl -sS --oauth2-bearer FIXTURE-NOT-A-TOKEN https://example.invalid/
curl -sS -K <(printf 'oauth2-bearer = "%s"\n' "$tok") https://example.invalid/
git -c 'http.https://github.com/.extraheader=AUTHORIZATION: basic FIXTURE' fetch
curl -sS "$API/user?access_token=FIXTURE-NOT-A-TOKEN"
curl -sS 'https://example.invalid/a?access_token=FIXTURE'"$page"
FIX
n1_safe=$(_scan "$WORK/safe-n1.sh")
assert_eq "N1 safe forms: zero hits${n1_safe:+ — got:
$n1_safe}" "$(printf '%s' "$n1_safe" | grep -c . || true)" "0"

echo '=== the pre-#1840 call sites, verbatim, are flagged ==='
# The exact lines this fix removed, so the lint is shown to see the real
# instances and not only the planted shapes above.
cat > "$WORK/prefix.sh" <<'FIX'
    -H "Authorization: Bearer $app_jwt" \
        -H "Authorization: Bearer ${PAT}" \
            -H "Authorization: Bearer $jwt" \
        -H "Authorization: Bearer $token" \
        -H "Authorization: Bearer $user_pat" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        --data-urlencode "fields=$fields" -H "x-api-key: $s2key" 2>/dev/null) \
    -H "Authorization: token $token" \
ASSET_URL_AUTH="https://x-access-token:${TOKEN}@github.com/${REPO}.git"
    local form=(-F "token=$app" -F "user=$user" -F "title=$TITLE"
FIX
pre_hits=$(_scan "$WORK/prefix.sh")
assert_eq "pre-fix sites: all 10 flagged" "$(printf '%s\n' "$pre_hits" | grep -c 'prefix.sh:')" "10"

echo '=== behaviour: the safe header form keeps the value OUT of /proc cmdline ==='
# A local server that holds the request open, so curl is alive while we read
# its argv. Positive control first: the OLD form puts the value in cmdline, so
# the probe can see a leak when there is one.
SECRET="fake-cred-$$-$RANDOM"
cat > "$WORK/slow.py" <<'PY'
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        time.sleep(3)
        b = ("AUTH=%s" % s.headers.get("Authorization")).encode()
        s.send_response(200); s.end_headers(); s.wfile.write(b)
    def log_message(*a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
coproc SRV { exec timeout -k 5 60 python3 "$WORK/slow.py"; }
read -r -t 10 port <&"${SRV[0]}" || port=""
if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    # Four assertions either way, so the count check below still holds.
    for _l in "local server did not start (port='$port')" skipped skipped skipped; do
        assert_eq "behaviour: $_l" "no-server" "server"
    done
else
    _cmdline_of_curl() {   # <outfile> <curl args…>: start curl, return its cmdline
        local out="$1"; shift
        curl -sS --max-time 15 "$@" "http://127.0.0.1:$port/" > "$out" &
        local cp=$! i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            [[ -r /proc/$cp/cmdline ]] && break; sleep 0.1
        done
        sleep 0.5
        { tr '\0' ' ' < "/proc/$cp/cmdline"; } 2>/dev/null
        wait "$cp"
    }
    old=$(_cmdline_of_curl "$WORK/old.out" -H "Authorization: Bearer $SECRET")
    assert_contains "control: the OLD form's cmdline DOES carry the value" "$old" "$SECRET"
    new=$(_cmdline_of_curl "$WORK/new.out" -H @<(printf 'Authorization: Bearer %s\n' "$SECRET"))
    assert_not_contains "fix: the header-file form's cmdline does NOT carry the value" "$new" "$SECRET"
    assert_contains "fix: …and curl still sent the header" "$(cat "$WORK/new.out")" "AUTH=Bearer $SECRET"
    assert_contains "control: the OLD form sent it too (same server, same check)" "$(cat "$WORK/old.out")" "AUTH=Bearer $SECRET"
fi
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null

echo '=== behaviour: upload-asset.sh credential helper answers git, from the environment ==='
helper=$(sed -n "s/^    local helper='\(.*\)'\$/\1/p" "$REPO_ROOT/monitor/upload-asset.sh")
assert_contains "the helper is defined in upload-asset.sh" "$helper" 'NEXUS_ASSET_TOKEN'
assert_not_contains "the helper text carries no value, only the variable name" "$helper" "$SECRET"
# rc and stderr are kept apart and named in the labels: one node run (job
# 1234567, f61e3447) returned an EMPTY answer here, stdout AND stderr, which
# git never does on a real failure and which no local run reproduced (plain,
# env -i with an empty HOME, under run-tests). So the git path is GATED on a
# CONTROL: a literal helper through the same `git credential fill`. Control
# works -> the real helper is judged through git, the production path. Control
# fails -> git's credential machinery is not working in THIS environment, which
# says nothing about the helper; the git-path check is recorded as a counted
# SKIP (th_skip) and the helper is then executed directly by sh,
# exactly as git would (`sh -c '<helper minus !> "$@"' <helper> get`). Either way two assertions, and no operator credential is
# ever read: the token is a synthetic value in the environment.
_cf() {   # <helper> -> CF_OUT, CF_RC, CF_ERR (globals; no subshell, so they survive)
    local e o; e=$(mktemp "$WORK/cf.XXXXXX"); o=$(mktemp "$WORK/cf.XXXXXX")
    printf 'protocol=https\nhost=github.com\n\n' \
        | GIT_TERMINAL_PROMPT=0 NEXUS_ASSET_TOKEN="$SECRET" \
          git -c credential.helper= -c "credential.helper=$1" credential fill >"$o" 2>"$e"
    CF_RC=${PIPESTATUS[1]}; CF_OUT=$(cat "$o"); CF_ERR=$(tr '\n' ' ' < "$e"); rm -f "$e" "$o"
}
_cf '!f() { echo username=u; echo password=CONTROL; }; f'
ctrl_why="rc=$CF_RC stderr=[$CF_ERR] out=[${CF_OUT//$'\n'/ }]"
if [[ "$CF_OUT" == *password=CONTROL* ]]; then
    _cf "$helper"; filled=$CF_OUT; via="git credential fill, rc=$CF_RC stderr=[$CF_ERR]"
else
    # COUNTED, not only printed: the summary then reads "1 SKIPPED — NOT
    # covered", so a green run on this branch cannot be read as "the helper was
    # verified through git".
    th_skip "the helper verified THROUGH git credential fill" \
        "git's credential machinery is not working here (control: $ctrl_why); the helper is judged by direct sh execution only"
    # git runs a `!` helper as `sh -c '<helper> "$@"' <helper> get`: same here.
    filled=$(NEXUS_ASSET_TOKEN="$SECRET" sh -c "${helper#!} \"\$@\"" "${helper#!}" get 2>&1); via="direct sh, rc=$?"
fi
assert_contains "the helper answers get with the token as the password ($via)" "$filled" "password=$SECRET"
assert_contains "…with the x-access-token username"                       "$filled" "username=x-access-token"

echo '=== the corpus ==='
n=0
while IFS= read -r f; do [[ -f "$REPO_ROOT/$f" ]] && n=$((n+1)); done < <(_ac_population)
assert_eq "population is non-vacuous (>= 900 files)" "$(( n >= 900 ))" "1"
all=$(cd "$REPO_ROOT" && _ac_population | tr '\n' '\0' | xargs -0 python3 "$WORK/scan.py")
assert_eq "#1840 no tracked file puts a runtime credential in argv${all:+ — offenders:
$all}" "$(printf '%s' "$all" | grep -c . || true)" "0"
# The exemption marker is a hole by construction, so its population is pinned:
# a new `argv-credential-ok:` must change this number in review, not slip in.
exempt=$(cd "$REPO_ROOT" && _ac_population | tr '\n' '\0' | xargs -0 grep -lF 'argv-credential-ok:' 2>/dev/null | sort | tr '\n' ' ')
assert_eq "exemptions are exactly the one synthetic redaction fixture" "$exempt" "monitor/watcher/test-force-push-check-credential-redaction.sh "
echo
EXPECTED=36
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
