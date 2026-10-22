#!/usr/bin/env bash
# test-claude-md-nullcmd-redirect.sh — execute CLAUDE.md's NULLCMD-REDIRECT
# block (your-org/nexus-code#1393).
#
# WHY THIS SUITE EXISTS. In zsh a command-less redirection `> file` is not a
# truncate: zsh runs `$NULLCMD` (cat) under the redirection, and on an agent's
# Bash tool call that cat reads INHERITED stdin, which never closes. The call
# blocks forever at 0% CPU with no error. A base-comparison job sat 7h30m on
# exactly this; `< /dev/null` masks it completely, so the idiom is correct in
# every script and every `bash -c` test of it, and wrong in the one place an
# agent types it. The corpus is dormant (every site is bash-shebang); the
# exposure is the zsh-invoked agent path.
#
# WHAT IS ACTUALLY PINNED:
#   the MECHANISM   — zsh's $NULLCMD is `cat`.
#   the ASYMMETRY   — bash returns; zsh with stdin at /dev/null returns (the
#                     MASK); zsh with stdin HELD OPEN blocks.
#   the REMEDY      — `: > f` returns in zsh even with stdin held open.
#   the CONF ROW    — the `nullcmd-redirect` hook row fires on a command-less
#                     `> target` in a tool call and not on `echo x > f`,
#                     `cmd 2> err`, `cmd &> all`, or a heredoc blockquote line.
#
# CONTAINMENT, stated first: THE BLOCKING FORM IS RUN UNDER `timeout` AGAINST
# A FIFO THIS SUITE HOLDS OPEN, never against the runner's own stdin. So a
# regression in the guard, or a host where the block is somehow reachable
# from here, costs this suite 3 seconds and a red — never a hang. The fifo's
# writer is a `sleep` this suite owns and kills by recorded pid.
#
# CONTROLS:
#   A — extracted form count PINNED at 4 (#618's shape).
#   B — POSITIVE control for the fifo: the REMEDY form, given the SAME
#       held-open fifo as stdin, returns — so the block is the NULLCMD cat
#       reading stdin, not the fifo itself blocking every reader.
#   C — the masked form and the bash form EXIT 0 with the file truncated: the
#       defect is that they succeed, which is how it survives testing.
#   D — the hook's NEGATIVE samples: forms that carry a `>` and must NOT fire.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
HOOK="$REPO_ROOT/monitor/hooks/bash-footgun-guard.sh"
CONF="$REPO_ROOT/monitor/bash-footgun-patterns.conf"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite EXECUTES, and
# the conf row it drives through the hook is the other set of bytes an edit to
# which changes its verdict. NOTE: a declaring suite needs a
# guard-populations.manifest row (test-guards-for-diff.sh §1).
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/bash-footgun-patterns.conf \
        monitor/hooks/bash-footgun-guard.sh \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage NULLCMD-REDIRECT   # the entry's UNCHECKED share, in this suite's own output (#1239)

HAVE_ZSH=no
if command -v zsh >/dev/null 2>&1; then HAVE_ZSH=yes
else th_skip "every zsh-dependent arm" "zsh is not on PATH — the mechanism, the mask, the block and the remedy could NOT be exercised here; only extraction, the bash arm and the hook ran"
fi
HAVE_JQ=no
if command -v jq >/dev/null 2>&1; then HAVE_JQ=yes
else th_skip "the hook arm" "jq is not on PATH — the conf row could not be driven through the hook"
fi

WORK=$(mktemp -d -t nexus-nullcmd-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# A RETURNING form's bound. WE CHOSE 60 s (it was 10): the form returns the
# instant it is done, so this is a polled ceiling and a larger one costs nothing
# on a green run — and 10 s was BELOW the 10.2 s zsh startup `#1589` measured on
# this host at load ~40, so the three returning legs were one loaded band away
# from the same false red as the BLOCK leg. 60 is ~6x that worst measurement.
# `th_deadline` adds the `--jobs` scaling on top; note it scales by jobs/cpus
# and is therefore x1 on this 36-core host — it does NOT see other agents' load,
# which is why the base itself had to move.
RETURN_CEILING=$(th_deadline 60)
STARTUP_CEILING=$(th_deadline 60)   # same reasoning: how long zsh may take to REACH its redirection
BLOCK_WINDOW=3                      # unchanged: how long a form must stay blocked to be called blocked

# _held_verdict <form> -> blocked | returned | never-started   (stdout)
#
# Runs <form> in $PWD with stdin HELD OPEN, against a fresh 4-byte `f`.
#   returned       the form exited by itself
#   blocked        `f` was OBSERVED emptied — zsh reached the redirection — and
#                  the form was still alive BLOCK_WINDOW seconds AFTER that
#   never-started  `f` was never emptied within STARTUP_CEILING: a statement
#                  about the HOST, deliberately not folded into either verdict
# Side files: $WORK/held.out (the form's output), $WORK/held.sig (the argv of
# the blocked form's grandchild, read WHILE it is blocked).
#
# `exec timeout …` so `$!` IS the `timeout` process: GNU timeout makes itself a
# process-group leader and forwards a TERM it receives to that whole group, so
# one signal to a pid this suite owns reaps zsh AND the `cat` under it. That
# `cat` holds BOTH ends of the fifo through the inherited `<>` descriptor and
# would otherwise never see EOF — an orphan that outlives the suite.
_held_verdict() {
    local form="$1" pid t0 verdict zpid cpid=""
    printf 'old\n' > f
    : > "$WORK/held.out"; : > "$WORK/held.sig"; : > "$WORK/held.reaped"
    eval "exec timeout -k 5 $(( STARTUP_CEILING + BLOCK_WINDOW + 60 )) $form" \
        <&"$_HELD_FD" > "$WORK/held.out" 2>&1 &
    pid=$!
    t0=$SECONDS
    while kill -0 "$pid" 2>/dev/null && [[ -s f ]] && (( SECONDS - t0 < STARTUP_CEILING )); do
        sleep 0.1
    done
    if ! kill -0 "$pid" 2>/dev/null; then
        verdict=returned
    elif [[ -s f ]]; then
        verdict=never-started
    else
        t0=$SECONDS
        while kill -0 "$pid" 2>/dev/null && (( SECONDS - t0 < BLOCK_WINDOW )); do sleep 0.1; done
        if kill -0 "$pid" 2>/dev/null; then
            verdict=blocked
            zpid=$(ps -o pid= --ppid "$pid" 2>/dev/null | tr -d ' ' | sed -n 1p)
            if [[ "$zpid" =~ ^[0-9]+$ ]]; then
                ps -o args= --ppid "$zpid" 2>/dev/null | sed -n 1p | sed 's/[[:space:]]*$//' > "$WORK/held.sig"
                cpid=$(ps -o pid= --ppid "$zpid" 2>/dev/null | tr -d ' ' | sed -n 1p)
            fi
        else
            verdict=returned
        fi
    fi
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    # REAPED, ASKED BY HANDLE. The blocked `cat` is the process that would
    # outlive this suite, and "did it" is answered from the PID recorded while
    # it was blocked — never from a `ps | grep cat`, which cannot tell this
    # `cat` from anybody else's (your-org/nexus-code#1073). `timeout` forwards
    # the TERM asynchronously, so poll briefly rather than sample once.
    if [[ "$cpid" =~ ^[0-9]+$ ]]; then
        t0=$SECONDS
        while [[ -d "/proc/$cpid" ]] && (( SECONDS - t0 < 10 )); do sleep 0.1; done
        [[ -d "/proc/$cpid" ]] && printf 'no' > "$WORK/held.reaped" || printf 'yes' > "$WORK/held.reaped"
    fi
    printf '%s' "$verdict"
}

# ---- assertion-count guard --------------------------------------------------
_th_count_guard() {
    local EXPECTED_ASSERTIONS=9          # extraction (6) + bash arm (3)
    # zsh arm: NULLCMD (1) + mask (3) + block (5) + slow-startup block (2)
    #          + verdict discrimination (1) + remedy (3)
    [[ "$HAVE_ZSH" == yes ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 15 ))
    [[ "$HAVE_JQ"  == yes ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 10 ))
    assert_eq "assertion TOTAL matches the EXPECTED total (zsh=$HAVE_ZSH jq=$HAVE_JQ)" \
              "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN NULLCMD-REDIRECT -->' -v e='<!-- END NULLCMD-REDIRECT -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^(zsh|bash) ')

FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '^(zsh|bash) ')
assert_eq "extracted exactly 4 documented forms (control A)" "$FORM_COUNT" "4"
if [[ "$FORM_COUNT" != "4" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi
FORM_BASH=$(printf '%s\n' "$FORMS" | sed -n '1p')
FORM_MASK=$(printf '%s\n' "$FORMS" | sed -n '2p')
FORM_BLOCK=$(printf '%s\n' "$FORMS" | sed -n '3p')
FORM_FIX=$(printf '%s\n' "$FORMS" | sed -n '4p')
assert_contains     "form 1 is the bash contrast"                 "$FORM_BASH"  'bash -c'
assert_contains     "form 2 is the zsh MASK (stdin at /dev/null)" "$FORM_MASK"  '/dev/null'
assert_not_contains "form 3 is the zsh BLOCK (stdin inherited)"   "$FORM_BLOCK" '/dev/null'
assert_contains     "form 4 is the remedy (colon as the command)"   "$FORM_FIX"   ': > f'

echo
echo '=== THE ASYMMETRY, bash half: a command-less redirection only truncates ==='
cd "$WORK" || th_abort "cannot cd to $WORK"
printf 'old\n' > f
out=$(eval "timeout $RETURN_CEILING $FORM_BASH" 2>&1); rc=$?
assert_eq       "the bash form exits 0 (control C)" "$rc" "0"
assert_contains "…and returns"                      "$out" "returned"
assert_eq       "…having truncated the file"        "$(wc -c < f)" "0"

if [[ "$HAVE_ZSH" == yes ]]; then
    echo
    echo '=== THE MECHANISM: zsh runs $NULLCMD, and it is cat ==='
    assert_eq "zsh's NULLCMD is cat" "$(zsh -c 'print -r -- $NULLCMD' 2>/dev/null)" "cat"

    echo
    echo '=== THE MASK: zsh with stdin at /dev/null RETURNS (why nobody finds it) ==='
    printf 'old\n' > f
    out=$(eval "timeout $RETURN_CEILING $FORM_MASK" 2>&1); rc=$?
    assert_eq       "the masked zsh form exits 0 (control C)" "$rc" "0"
    assert_contains "…and returns"                            "$out" "returned"
    assert_eq       "…having truncated the file"              "$(wc -c < f)" "0"

    echo
    echo '=== THE BLOCK: zsh with stdin HELD OPEN never returns — bounded by timeout ==='
    # A fifo this suite holds open on BOTH ends (`<>`): the open never blocks
    # waiting for a rendezvous, no data ever arrives and no EOF ever comes, so a
    # `cat` reading it blocks for as long as it lives — which is exactly what an
    # inherited tool-call stdin looks like to cat. (An earlier form paired a
    # `sleep 300 > fifo &` writer with a blocking reader-open; under
    # `ng guards-for-diff --run` the writer was not there, the reader-open
    # blocked instead of cat, zsh never ran, and the assertion below read the
    # UN-truncated file as a failure of the wrong mechanism. Holding both ends
    # removes the rendezvous entirely.)
    mkfifo "$WORK/held"
    exec {_HELD_FD}<>"$WORK/held"
    # THE CLOCK STARTS WHEN ZSH REACHES THE REDIRECTION, NOT WHEN IT IS SPAWNED
    # (your-org/nexus-code#1589). This leg used to be `timeout 3 <form>` and then
    # asserted the file was truncated — which silently assumed zsh STARTED and
    # reached `> f` inside those 3 s. Measured on this host at load ~40:
    # `time zsh -c true` = 10.2 s. `timeout` then killed zsh before the
    # redirection ran, the file kept its 4 bytes, and the row read a HOST
    # condition as a failure of the mechanism under test: red in two full bands,
    # green in isolation, reproduced exactly by a `.zshenv` that sleeps 4 s.
    #
    # Raising the bound is the wrong fix: a BLOCKING form always runs to its
    # bound, so 30 s would cost 30 s on every GREEN run. `_held_verdict` instead
    # waits for the OBSERVABLE the old row assumed — `f` emptied — and only then
    # opens the block window. Startup gets a generous polled ceiling (free on
    # green); the window stays at the 3 s it always was.
    _v=$(_held_verdict "$FORM_BLOCK")
    assert_eq           "the blocking form reaches its redirection and is STILL BLOCKED when the window closes" "$_v" "blocked"
    assert_not_contains "…and never printed its trailing echo"              "$(cat "$WORK/held.out")" "returned"
    # THE SIGNATURE CLAUDE.md tells a reader to look for in /proc: a child `cat`
    # with NO ARGUMENTS. Every `cat` an author writes has a file argument; this
    # one has none because zsh supplied it. Read while the form is still blocked.
    assert_eq           "…blocked in an ARGUMENT-LESS \`cat\` that zsh, not the author, supplied" "$(cat "$WORK/held.sig")" "cat"
    # The `cat` ran and consumed nothing: the file was truncated by the open
    # and stays empty, so the artefact looks exactly like a successful truncate.
    assert_eq           "…yet the file IS truncated — the artefact reads as success" "$(wc -c < f)" "0"
    assert_eq           "…and reaping the form left NO \`cat\` behind holding the fifo (asked by recorded pid)" "$(cat "$WORK/held.reaped")" "yes"

    echo
    echo '=== #1589: the same verdict when zsh takes LONGER TO START than the old 3 s bound ==='
    # The regression pin, in-suite so it cannot rot: a ZDOTDIR whose `.zshenv`
    # sleeps past the OLD budget. Before the fix this is the exact red the bands
    # saw. 4 s is `#1589`'s own reproduction value: above 3, and small enough
    # to cost this suite ~4 s.
    mkdir -p "$WORK/slowzsh"; printf 'sleep 4\n' > "$WORK/slowzsh/.zshenv"
    _v=$(ZDOTDIR="$WORK/slowzsh" _held_verdict "$FORM_BLOCK")
    assert_eq "a 4 s zsh startup still yields \`blocked\` — startup is no longer inside the block budget" "$_v" "blocked"
    assert_eq "…and the file is truncated, which is what the old row mis-read"   "$(wc -c < f)" "0"

    echo
    echo '=== the verdict DISCRIMINATES: the remedy form through the same instrument is `returned` ==='
    # Without this, `blocked` could be what `_held_verdict` says about everything.
    assert_eq "the remedy form is \`returned\`, not \`blocked\`, against the SAME held-open stdin" \
        "$(_held_verdict "$FORM_FIX")" "returned"

    echo
    echo '=== CONTROL B + THE REMEDY: ": > f" returns even with stdin held open ==='
    printf 'old\n' > f
    out=$(eval "timeout $RETURN_CEILING $FORM_FIX" < "$WORK/held" 2>&1); rc=$?
    assert_eq       "the remedy form exits 0 against the SAME held-open stdin" "$rc" "0"
    assert_contains "…and returns — so the fifo is not what blocked above"    "$out" "returned"
    assert_eq       "…and truncates the file"                                 "$(wc -c < f)" "0"
fi
cd "$REPO_ROOT" || th_abort "cannot cd back to $REPO_ROOT"

if [[ "$HAVE_JQ" == yes ]]; then
    echo
    echo '=== THE CONF ROW: the hook fires on a command-less redirection, and only on one ==='
    _deliver() {   # <command> -> the additionalContext string
        printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
        | NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$WORK/state-$RANDOM$RANDOM" \
          NEXUS_FOOTGUN_PATTERNS="$CONF" NEXUS_WORKER_WINDOW="nullcmd-test" \
          bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""'
    }
    _fires() { [[ "$(_deliver "$1")" == *'bash-footgun-guard [nullcmd-redirect]'* ]] && echo yes || echo no; }
    assert_contains "the row exists in the conf" "$(grep -c '^nullcmd-redirect|' "$CONF")" "1"
    # POSITIVES — the incident's own line first.
    assert_eq "fires: the incident line, bare at the start of a call"  "$(_fires '> /tmp/w218/fail_base.txt')" "yes"
    assert_eq "fires: after a semicolon mid-line"                            "$(_fires 'cd /x; > out.txt; ls')" "yes"
    assert_eq "fires: on its own line inside a multi-line call"        "$(_fires $'set -e\n> /tmp/x\necho hi')" "yes"
    assert_eq "fires: an append with no command"                       "$(_fires '>> log.txt')" "yes"
    assert_contains "…and the text names the remedy"                   "$(_deliver '> /tmp/x')" ': > file'
    # NEGATIVES (control D) — every one carries a `>` and must stay silent.
    assert_eq "silent: a redirect WITH a command"                      "$(_fires 'echo hi > /tmp/x')" "no"
    assert_eq "silent: a stderr redirect (2>)"                           "$(_fires 'cmd 2> err.log')" "no"
    assert_eq "silent: &> is an operator, not a background plus redirect" "$(_fires 'cmd &> all.log')" "no"
    assert_eq "silent: a markdown blockquote inside a heredoc body"    "$(_fires $'cat <<EOF > body.md\n> a quoted line of text\nEOF')" "no"
fi

_th_count_guard
