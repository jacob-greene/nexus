#!/usr/bin/env bash
# A FIXTURE TMUX SERVER IS STARTED WITH `-f`, NEVER WITH THE OPERATOR'S DOTFILE.
#
# WHY THIS FILE EXISTS. A tmux server started without `-f` loads the invoking
# user's ~/.tmux.conf. If that file has ANY error, tmux 2.6 reports the errors
# by putting the new session's pane into COPY MODE, and with no client attached
# a copy-mode key binding (`e`, `h`, `b`, space, Enter, C-m) CRASHES THE
# SERVER: the next `send-keys` returns "lost server". Measured on tmux 2.6 with
# a planted one-line error (`set-option -g mouse om`), `send-keys 'env -i true'
# C-m` into a fresh detached server: 4/4 servers lost without a fixture config,
# 0/4 with `th_tmux_fixture_conf`. The suite then fails for a reason that lives
# in a DOTFILE, and the failure reads as a defect in the code under test
# (test-bootstrap-stub-claude.sh Case E was the reported instance).
#
# Even short of a crash the dotfile changes what a fixture measures
# (base-index, default-shell, status jobs: see `th_tmux_fixture_conf` and
# your-org/nexus-code#555), so the rule is the same whether or not the pane
# ever receives a key.
#
# ── THE PREDICATE, AND WHICH WAY IT ERRS ───────────────────────────────────
#
# For every LOGICAL command line (backslash continuations joined), read from
# the heredoc-stripped view with quoted spans and comments masked out through
# the shared quote machine, the lint looks for a server-starting subcommand —
# `new-session` or `start-server` anywhere, `new` / `start` only when the line
# also names tmux — and requires an unquoted `-f` token BEFORE it.
#
#   FALSE NEGATIVES (the dangerous direction; a site it cannot see):
#     * a subcommand that never appears as a literal word: `"$sub"`, an
#       abbreviation other than `new`/`start`, or a helper that forwards "$@"
#       and is called with the subcommand from another line;
#     * a `-f` that belongs to a DIFFERENT command earlier on the same logical
#       line (`rm -f x; tmux new-session …`) satisfies it;
#     * a `-f` that points at the operator's dotfile, or at a config that
#       itself has an error, satisfies it — the lint checks presence, not the
#       file;
#     * tmux started from heredoc bodies (scripts a suite WRITES), `$'…'`
#       strings, non-shell code, and files outside the population below.
#   FALSE POSITIVES (loud, and resolved by a reasoned marker, never by
#   filename):
#     * a wrapper, array or PATH shim that already pins `-f`
#       (`"${FTMUX[@]}"`, an `nx_write_tmux_shim … -f` shim);
#     * a `new-session` against a server that is ALREADY RUNNING, where `-f`
#       has no effect because the config is read only at server start.
#
# ── THE POPULATION ─────────────────────────────────────────────────────────
#
# Every tracked `monitor/watcher/**/test-*.sh`, plus the helpers suites source
# to start servers (`_test_helpers.sh`, `_tmux-fixture.sh`,
# `test-integration/_*.sh`). Deliberately EXCLUDED: stub/fake executables
# (`fixtures/stubs/*`, `test-integration/stub-claude.sh`), which impersonate
# tools rather than start tmux, and production scripts (`main.sh`,
# `launcher.sh`, …), which start the operator's real board on purpose.
#
# ── THE MARKER ─────────────────────────────────────────────────────────────
#
#     # tmux-fixture-conf-lint: <token>  <reason>
#
# on the command's first line or in the comment block directly above it.
#   allow-wrapper-pins-f   the invoking wrapper/array/shim already passes -f
#   allow-live-server      the server is already running; -f would be inert
# A marker that no longer guards a server-starting line is reported STALE.
#
# Run: bash monitor/watcher/test-tmux-fixture-conf-lint.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
QUOTES_AWK="$_test_dir/_shell_quotes.awk"

# ── POPULATION (your-org/nexus-code#1301 convention) ───────────────────────
# `_tfcl_corpus` is the ONE enumerator: the sweep and `gp_population` both
# call it. `:(glob)` because git's pathspec `*` crosses `/` (CLAUDE.md).
_tfcl_corpus() {
    git -C "$REPO_ROOT" ls-files -- \
        ':(glob)monitor/watcher/**/test-*.sh' \
        ':(glob)monitor/watcher/_test_helpers.sh' \
        ':(glob)monitor/watcher/_tmux-fixture.sh' \
        ':(glob)monitor/watcher/test-integration/_*.sh'
}
. "$_test_dir/../_guard_population.sh"
gp_population() {
    _tfcl_corpus | sed "s|^|$REPO_ROOT/|"
    printf '%s\n' "$REPO_ROOT/monitor/shell-files.sh" "$QUOTES_AWK" "$_test_dir/_test_helpers.sh"
}
gp_handle "$@"

[[ -r "$QUOTES_AWK" ]] || { echo "FAIL: missing $QUOTES_AWK" >&2; exit 1; }

MARKER_RE='tmux-fixture-conf-lint:[[:space:]]*(allow-wrapper-pins-f|allow-live-server)[[:space:]]+[^[:space:]]'

# scan_conf <file> -> `HIT:<file>:<line>`, `OK:<file>:<line>`,
# `MARKED:<file>:<line>` per server-starting command, `STALE:<file>:<line>`
# per marker that guards none.
scan_conf() {
    local f="$1" src
    # FILE-LEVEL FAST PATH, also exact: every report below needs a raw line
    # naming tmux, new-session or start-server (a marker names tmux), so a
    # file with none of them cannot produce one and is not stripped/masked.
    # FAIL CLOSED: grep rc 2 or a stripper failure is an `ERR:` row, never a
    # silent skip, because a file this scan could not read is not a clean file.
    local rc=0
    command grep -qiE 'tmux|new-session|start-server' -- "$f" 2>/dev/null || rc=$?
    (( rc == 1 )) && return 0
    (( rc == 0 )) || { printf 'ERR:%s: grep rc %s\n' "${f#"$REPO_ROOT"/}" "$rc"; return 0; }
    src=$(th_strip_heredocs "$f" 2>/dev/null) \
        || { printf 'ERR:%s: th_strip_heredocs failed\n' "${f#"$REPO_ROOT"/}"; return 0; }
    printf '%s\n' "$src" | awk -v file="${f#"$REPO_ROOT"/}" -v mre="$MARKER_RE" "$(cat "$QUOTES_AWK")"'
        function code_no_comment(s,   m, i, L, out, c, p) {
            m = quote_mask(s); L = length(s); out = ""
            for (i = 1; i <= L; i++) {
                c = substr(s, i, 1)
                if (substr(m, i, 1) == "1") continue
                p = (i > 1) ? substr(s, i-1, 1) : " "
                if (c == "#" && (p == " " || p == "\t" || i == 1)) break
                out = out c
            }
            return out
        }
        # The TRAILING COMMENT of a code line: a marker inside a quoted
        # string (a diagnostic that QUOTES the marker) is not a marker.
        function comment_part(s,   m, i, L, c, p) {
            m = quote_mask(s); L = length(s)
            for (i = 1; i <= L; i++) {
                if (substr(m, i, 1) == "1") continue
                c = substr(s, i, 1); p = (i > 1) ? substr(s, i-1, 1) : " "
                if (c == "#" && (p == " " || p == "\t" || i == 1)) return substr(s, i)
            }
            return ""
        }
        function is_comment(l) { sub(/^[ \t]+/, "", l); return substr(l, 1, 1) == "#" }
        function is_blank(l)   { return l ~ /^[ \t]*$/ }
        # A subcommand followed by `)` or `|` is a CASE PATTERN in a fake
        # tmux, not an invocation, so those followers are not accepted.
        function starts_server(code, raw) {
            if (match(code, /(^|[ \t;&|(])(new[-]session|start-server)([ \t;]|$)/)) return 1
            if (match(code, /(^|[ \t;&|(])(new|start)([ \t;]|$)/) && tolower(raw) ~ /tmux/) return 1
            return 0
        }
        {
            raw = $0
            if (acc == "") {
                # Between logical commands: track the comment block above.
                if (is_blank(raw)) { marked = 0; mline = 0; next }
                if (is_comment(raw)) {
                    if (raw ~ mre) { marked = 1; mline = NR }
                    next
                }
                # FAST PATH, exact rather than heuristic: a line naming no
                # subcommand word, carrying no marker and not continued
                # cannot start a server or mark one, so the per-character
                # quote mask is skipped. It can still be a STALE target.
                if (raw !~ /new|start|tmux-fixture-conf-lint/ && raw !~ /\\[ \t]*$/) {
                    if (marked) printf("STALE:%s:%d\n", file, mline)
                    marked = 0; mline = 0
                    next
                }
                start = NR; accraw = ""
                if (comment_part(raw) ~ mre) { marked = 1; if (!mline) mline = NR }
            }
            code = code_no_comment(raw)
            acc = acc " " code; accraw = accraw " " raw
            if (code ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", acc); next }
            L = acc; R = accraw; acc = ""
            if (starts_server(L, R)) {
                pre = substr(L, 1, RSTART)
                if (pre ~ /(^|[ \t])-f([ \t]|$)/) printf("OK:%s:%d\n", file, start)
                else if (marked)                  printf("MARKED:%s:%d\n", file, start)
                else                              printf("HIT:%s:%d\n", file, start)
            } else if (marked) {
                printf("STALE:%s:%d\n", file, mline)
            }
            marked = 0; mline = 0
        }
        END { if (marked) printf("STALE:%s:%d\n", file, mline) }
    '
}

count_kind() {   # count_kind <KIND> <file>
    scan_conf "$2" | grep -c "^$1:" || true
}

# ── POSITIVE CONTROL, FIRST ────────────────────────────────────────────────
# A scan that finds nothing is indistinguishable from one that cannot find
# anything; prove the detector fires before trusting its zero.
PLANT=$(mktemp -d) || { echo "FAIL: mktemp for the plant"; exit 1; }
trap 'rm -rf "$PLANT"; _th_reap_own_tmp' EXIT

# The plants spell the subcommand @NS@ and _plant restores it, so THIS
# file's source never carries the literal subcommand in command position:
# test-tmux-socket-ceiling.sh §8 enumerates real-tmux suites by that
# literal and cannot see a heredoc boundary.
_plant() { sed 's/@NS@/new-session/g' >"$1"; }

_plant "$PLANT/test-plant-bare.sh" <<'PLANTED'
#!/usr/bin/env bash
env -u TMUX tmux -S "$SOCK" @NS@ -d -s s -x 80 -y 24 'sleep 30'
PLANTED
assert_eq "POSITIVE CONTROL: new-session without -f is flagged" \
    "$(count_kind HIT "$PLANT/test-plant-bare.sh")" "1"

_plant "$PLANT/test-plant-cont.sh" <<'PLANTED'
#!/usr/bin/env bash
env -u TMUX tmux -S "$SOCK" \
    @NS@ -d -s s 'sleep 30' 2>/dev/null \
    || exit 1
"$T" -L x start-server
PLANTED
assert_eq "POSITIVE CONTROL: a continued line and start-server via a quoted binary are both flagged" \
    "$(count_kind HIT "$PLANT/test-plant-cont.sh")" "2"

_plant "$PLANT/test-plant-after.sh" <<'PLANTED'
#!/usr/bin/env bash
tmux -L x @NS@ -d -f "$CONF" 'sleep 30'
PLANTED
assert_eq "POSITIVE CONTROL: a -f AFTER the subcommand (a new-session flag, not the config) is flagged" \
    "$(count_kind HIT "$PLANT/test-plant-after.sh")" "1"

_plant "$PLANT/test-plant-ok.sh" <<'PLANTED'
#!/usr/bin/env bash
env -u TMUX tmux -S "$SOCK" -f "$CONF" @NS@ -d -s s 'sleep 30'
env -u TMUX tmux -S "$SOCK" \
    -f /dev/null \
    @NS@ -d -s s2
echo "run: agent-sandbox tmux @NS@ ./watcher"
# tmux @NS@ in a comment
fake_tmux() { case "$1" in @NS@) echo ok ;; esac; }
cat >"$D/notes.txt" <<'EOF'
tmux @NS@ -d
EOF
PLANTED
assert_eq "NEGATIVE CONTROL: -f before the subcommand passes; strings, comments, case arms and heredoc bodies are not invocations" \
    "$(scan_conf "$PLANT/test-plant-ok.sh" | grep -c '^HIT:' || true):$(count_kind OK "$PLANT/test-plant-ok.sh")" "0:2"

_plant "$PLANT/test-plant-marked.sh" <<'PLANTED'
#!/usr/bin/env bash
# tmux-fixture-conf-lint: allow-wrapper-pins-f  FT carries -f
"${FT[@]}" @NS@ -d -s a
semi @NS@ -d -s b   # tmux-fixture-conf-lint: allow-live-server  started above

# tmux-fixture-conf-lint: allow-live-server  no longer guarding anything
echo unrelated
# tmux-fixture-conf-lint: allow-live-server
semi @NS@ -d -s c
PLANTED
assert_eq "MARKERS: two reasoned markers accepted, a reasonless one rejected, a stale one reported" \
    "$(count_kind MARKED "$PLANT/test-plant-marked.sh"):$(count_kind HIT "$PLANT/test-plant-marked.sh"):$(count_kind STALE "$PLANT/test-plant-marked.sh")" "2:1:1"

# The lint names its own forbidden idiom in heredoc plants above; scanning
# THIS file must return nothing.
assert_eq "the lint does not flag its own planted fixtures (heredoc-aware)" \
    "$(scan_conf "$_test_dir/$(basename "${BASH_SOURCE[0]}")" | grep -cE '^(HIT|STALE):' || true)" "0"

# ── THE CORPUS ─────────────────────────────────────────────────────────────
cd "$REPO_ROOT" || { echo "FAIL: cd repo root"; exit 1; }
n_files=0; hits=""; stales=""; n_ok=0; n_marked=0
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    n_files=$(( n_files + 1 ))
    while IFS= read -r r; do
        case "$r" in
            HIT:*)    hits+="${r#HIT:}"$'\n' ;;
            STALE:*)  stales+="${r#STALE:}"$'\n' ;;
            ERR:*)    stales+="${r#ERR:} (UNSCANNED)"$'\n' ;;
            OK:*)     n_ok=$(( n_ok + 1 )) ;;
            MARKED:*) n_marked=$(( n_marked + 1 )) ;;
        esac
    done < <(scan_conf "$f")
done < <(_tfcl_corpus)

# A blind enumeration or a blind detector would both report zero hits. The
# floors are well under the measured values (500+ files, 20+ conforming
# sites) so they catch a COLLAPSE, not drift.
if (( n_files >= 400 && n_ok >= 15 )); then
    printf '  PASS: corpus enumerated (%d files; %d server starts with -f, %d marked)\n' \
        "$n_files" "$n_ok" "$n_marked"; _th_pass
else
    printf '  FAIL: corpus collapsed — %d files, %d conforming sites (floors 400 / 15): the scan is blind\n' \
        "$n_files" "$n_ok" >&2; _th_fail
fi

hits=$(printf '%s' "$hits" | grep -v '^$' || true)
if [[ -z "$hits" ]]; then
    printf '  PASS: every fixture tmux server start passes -f\n'; _th_pass
else
    printf '  FAIL: tmux server start(s) with no -f (the operator'"'"'s ~/.tmux.conf is loaded):\n' >&2
    printf '%s\n' "$hits" | sed 's/^/         /' >&2
    printf '        Start the server with `th_tmux_fixture_conf "$WORK/tmux.conf"` and\n' >&2
    printf '        `tmux -L <sock> -f "$WORK/tmux.conf" new-session …` (or `-f /dev/null`).\n' >&2
    printf '        If a wrapper already pins -f, or the server is already running, say so:\n' >&2
    printf '          # tmux-fixture-conf-lint: allow-wrapper-pins-f  <why>\n' >&2
    printf '          # tmux-fixture-conf-lint: allow-live-server  <why>\n' >&2
    _th_fail
fi

stales=$(printf '%s' "$stales" | grep -v '^$' || true)
if [[ -z "$stales" ]]; then
    printf '  PASS: no stale tmux-fixture-conf-lint markers, no unscanned files\n'; _th_pass
else
    printf '  FAIL: stale tmux-fixture-conf-lint marker(s), or file(s) the scan could not read (UNSCANNED):\n' >&2
    printf '%s\n' "$stales" | sed 's/^/         /' >&2
    _th_fail
fi

# EXPECTED-COUNT GUARD (your-org/nexus-code#807): every assertion above is
# unconditional, so the total is pinned.
EXPECTED=9
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
