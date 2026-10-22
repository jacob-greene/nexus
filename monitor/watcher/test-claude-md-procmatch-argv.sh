#!/usr/bin/env bash
# Executes the `proc-exists-authorized` block CLAUDE.md documents
# (your-org/nexus-code#1073), against real planted processes.
#
# Run: bash monitor/watcher/test-claude-md-procmatch-argv.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. The bullet it checks tells a reader that a
# process-existence predicate keyed on a command line matches SIBLING AGENTS'
# argv, that bracketing stops the observer and not the siblings, and that the
# documented four forms behave a particular way — including one that is a
# REFUSAL. Prose cannot be made to fail. A documented form that stops behaving
# as documented must turn this suite red rather than quietly misinform the next
# reader, which is the same contract as the #618-remedies and #770-pathspec
# blocks.
#
# NON-VACUITY, because "the forms ran" proves nothing on its own:
#   Control A — the extracted form count is PINNED at 4. A botched extraction
#               yielding zero commands would otherwise pass every assertion by
#               having none to make (#618's own shape, reproduced inside its
#               remedy).
#   Control B — POTENCY. Before asserting that the prescribed form EXCLUDES a
#               foreign-session process, the naive `ps | grep` is shown MATCHING
#               that same plant. An exclusion test whose plant is invisible to
#               the predicate being replaced would pass against a helper that
#               always answers absent.
#   Control C — the observer-self-match half is measured in BOTH polarities on
#               a live plant: bracketing must take the naive count DOWN, and
#               must NOT take it to zero when a foreign-session holder exists.
#               The bullet's whole claim is that these two differ.
#
# COVERAGE BOUNDARY. This pins the documented FORMS and the ownership
# semantics. It does NOT spawn a second agent: a `setsid` process stands in for
# a sibling because the property that matters is identical — a process can
# LEAVE your session, never JOIN it — and spawning a real agent is not
# something a unit test may do.

# THIS FILE CONTAINS ARGV-KEYED PROCESS LOOKUPS, DELIBERATELY, AND THEY ARE
# NOT INSTANCES OF THE CLASS IT CLOSES. `setsid` forks, so `$!` is the
# intermediate shell rather than the decoy, and the decoy's pid can only be
# recovered by looking. What makes that safe here is the axis the defect varies
# on: the pattern is a RUNTIME nonce (`$$` plus nanoseconds), so it appears in
# no file, no prompt and no sibling's argv, and the population it can match is
# exactly one process this suite created. Everything is then SIGNALLED by the
# recorded pid, never by the pattern. The hazard is a predicate whose string
# also describes the thing; a nonce minted after every agent on the host
# started cannot.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite EXECUTES, so
# an edit to the fenced block it pins is exactly the edit that can change its
# verdict — and until #1219 no such edit could SELECT it: a suite that declares
# no population is INVISIBLE to `guards-for-diff` rather than excluded by it
# (#1078), appearing in neither SELECTED nor CONSIDERED AND EXCLUDED, so its
# absence reads as a considered exclusion. `gp_handle` adds this suite's own
# path and `monitor/_guard_population.sh` for free; everything else is declared
# because this suite READS ITS BYTES to reach a verdict.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/proc-exists-authorized \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
bash "$(dirname "${BASH_SOURCE[0]}")/claude-md-block-coverage.sh" PROC-EXISTS-AUTHORIZED   # the entry's UNCHECKED share, in this suite's own output (#1239)
HELPER="$REPO_ROOT/monitor/proc-exists-authorized"

# The SHARED assertion ledger (your-org/nexus-code#805): the in-memory counters
# die in a subshell, the ledger is a file and survives, so a FAILING assertion
# counted inside `( … )` or `$( … )` still reddens the suite. Adopting it here
# (rather than the hand-rolled counters its sibling `test-claude-md-*` suites
# use) is what makes this file ledger=yes AND count=exact — the one combination
# `summary-honesty.manifest` omits, because its green certifies both that
# something was asserted and that nothing silently stopped being asserted.
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; _th_fail; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

_kids=""
# ONLY recorded pids. A teardown that matched by name inside the suite about
# the hazard of matching by name would be absurd (your-org/nexus-code#851).
WORK=$(mktemp -d "${TMPDIR:-/tmp}/procmatch-XXXXXX") || { echo "FATAL: mktemp failed" >&2; exit 1; }
cleanup() { local k; for k in $_kids; do kill "$k" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

[[ -r "$CLAUDE_MD" ]] || { echo "FATAL: CLAUDE.md not readable at $CLAUDE_MD" >&2; exit 1; }
[[ -x "$HELPER" ]]    || { echo "FATAL: helper not executable at $HELPER" >&2; exit 1; }

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
BEGIN_MARK='<!-- BEGIN PROC-EXISTS-AUTHORIZED -->'
END_MARK='<!-- END PROC-EXISTS-AUTHORIZED -->'

FORMS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | grep -E 'proc-exists-authorized')

n_forms=$(printf '%s\n' "$FORMS" | grep -c 'proc-exists-authorized' || true)
# Control A.
assert_eq "Control A: exactly 4 documented forms extracted" "$n_forms" "4"

for _want in -- '--until-present --token' '--until-gone --pid' "--match 'myjob'" "--until-gone --match"; do
    [[ "$_want" == "--" ]] && continue
    # HERESTRING, not `printf … | grep -qF`. Under this file's `pipefail`,
    # `grep -q` exits the instant it matches, `printf` takes SIGPIPE, and the
    # PIPELINE's status becomes 141 — so the `if` reads FALSE on a string that
    # DOES match (your-org/nexus-code#622). Caught here by
    # test-sigpipe-assertion-lint.sh, in a diff whose subject is predicates
    # that quietly answer the wrong question.
    if grep -qF -- "$_want" <<<"$FORMS"; then
        ok "the documented form carrying \`$_want\` was extracted"
    else
        bad "the documented form carrying \`$_want\` was extracted" "block shape changed"
    fi
done

echo '=== The REFUSAL the block documents: --until-gone --match is rc 2 ==='
# Run the extracted line verbatim, with NEXUS_ROOT bound to this repo, so a
# drift between the doc and the tool reds here.
_gone_match=$(printf '%s\n' "$FORMS" | grep -F -- "--until-gone --match")
_out=$(NEXUS_ROOT="$REPO_ROOT" bash -c "$_gone_match" 2>&1); _rc=$?
assert_eq "the documented --until-gone --match line exits 2" "$_rc" "2"
if [[ "$_out" == *"MANUFACTURED-SUCCESS"* ]]; then
    ok "…and names the direction that makes it unsound"
else
    bad "…and names the direction that makes it unsound" "out: $_out"
fi

echo '=== The plant: a FOREIGN-session process holding the pattern in argv ==='
NONCE="cmp$$x$(date +%N | tail -c 6)"
if ! command -v setsid >/dev/null 2>&1; then
    bad "plant a foreign-session decoy" "setsid unavailable on this host"
else
    setsid bash -c "exec -a sibling_${NONCE}_decoy sleep 60" >/dev/null 2>&1 &
    disown %% 2>/dev/null || true
    sleep 1
    # NO `exit` in the awk and no `| head`: both are EARLY-EXIT READERS, which
    # under this file's `pipefail` turn the upstream SIGPIPE into the
    # pipeline's status (your-org/nexus-code#622). Drain, then take the first
    # line in the shell.
    _foreign=$(ps -eo pid=,args= | awk -v n="sibling_${NONCE}_decoy" 'index($0,n){print $1}')
    _foreign=${_foreign%%$'\n'*}
    if [[ -z "$_foreign" ]]; then
        bad "plant a foreign-session decoy" "no matching pid appeared"
    else
        _kids="$_kids $_foreign"
        ok "planted a foreign-session decoy at pid $_foreign"

        # Control B — POTENCY. The predicate being replaced MUST see the plant,
        # or the exclusion below is vacuous.
        _naive=$(ps -eo pid=,args= | grep -c "sibling_${NONCE}_decoy" || true)
        if (( _naive >= 1 )); then
            ok "Control B: the naive ps|grep DOES match the plant ($_naive hit(s))"
        else
            bad "Control B: the naive ps|grep DOES match the plant" \
                "0 hits — the exclusion assertion below would be vacuous"
        fi

        # Control C — BOTH POLARITIES of the bracketing claim, on a live plant.
        # Bracketing removes the OBSERVER's hit and leaves the foreign one, so
        # the bracketed count must be strictly smaller AND still non-zero.
        #
        # THE OBSERVER IS NOT GUARANTEED TO BE IN `ps`'s SNAPSHOT
        # (your-org/nexus-code#1853). `ps | grep` starts both at once, and `ps`
        # can read /proc before the grep has exec'd, so the grep's own argv is
        # sometimes absent: measured once on a node, `naive=1 bracketed=1`, and
        # Control C went red for a reason that is not the bullet's. So each
        # attempt `tee`s the EXACT snapshot its grep consumed, and the suite
        # LOOKS for the observer's line in it rather than inferring it from a
        # count. An attempt that did not capture its observer measured nothing
        # about self-matching and is retried; if none captures it, the control
        # SKIPS, naming the measurement, and never reports a failure the
        # mechanism under test did not produce. What is ASSERTED is unchanged:
        # bracketed >= 1 on EVERY run, and bracketed < naive on a captured attempt.
        _pat_n="sibling_${NONCE}_decoy"; _pat_b="sibling_[${NONCE:0:1}]${NONCE:1}_decoy"
        _cc_seen=0 _cc_try=0 _cc_raced=0
        while (( _cc_try < 8 )); do
            _cc_try=$(( _cc_try + 1 ))
            _naive_c=$(ps -eo pid=,args= | tee "$WORK/snap-n" | grep -c "$_pat_n" || true)
            _bracketed=$(ps -eo pid=,args= | tee "$WORK/snap-b" | grep -c "$_pat_b" || true)
            # The observer's own line: a process whose argv carries the pattern
            # VERBATIM and is not the decoy. Keyed on the PATTERN, not on the
            # word `grep`: a wrapped grep has a different argv[0], and a match
            # on the literal would read as "raced" forever — a permanent SKIP,
            # i.e. the control silently switched off. `index`, not a regex:
            # the bracketed pattern IS a regex.
            _on=$(awk -v p="$_pat_n" -v d="$_foreign" '$1 != d && index($0,p){n++} END{print n+0}' "$WORK/snap-n")
            _ob=$(awk -v p="$_pat_b" -v d="$_foreign" '$1 != d && index($0,p){n++} END{print n+0}' "$WORK/snap-b")
            if (( _on >= 1 && _ob >= 1 )); then _cc_seen=1; break; fi
            _cc_raced=$(( _cc_raced + 1 ))
        done
        if (( _cc_seen == 1 )); then
            # POTENCY: the naive count's extra hit IS the observer, so the
            # comparison below measures the self-match and nothing else.
            assert_eq "Control C potency: on a captured attempt the naive count is the decoy PLUS its own grep ($_cc_raced raced attempt(s) retried)" \
                "$_naive_c" "$(( _bracketed + 1 ))"
            if (( _bracketed < _naive_c )); then
                ok "Control C: bracketing removes the observer's own hit ($_naive_c -> $_bracketed)"
            else
                bad "Control C: bracketing removes the observer's own hit" \
                    "naive=$_naive_c bracketed=$_bracketed — the self-match half no longer reproduces"
            fi
        else
            for _l in "Control C potency" "Control C: bracketing removes the observer's own hit"; do
                th_skip "$_l" "COULD NOT OBSERVE: in $_cc_try attempts no ps snapshot contained the observer's own grep (it raced the grep's exec every time), so self-matching was not measured — not a failure of the bullet (your-org/nexus-code#1853)"
            done
        fi
        # OUTSIDE the capture gate (ncbundle31-sk F3): the foreign-session hit
        # is the decoy's line, present in every snapshot whether or not the
        # observer's grep raced, so the bullet's core claim is asserted on
        # EVERY run, as it was before the race fix.
        if (( _bracketed >= 1 )); then
            ok "…and does NOT remove the foreign-session hit — the bullet's core claim"
        else
            bad "…and does NOT remove the foreign-session hit" \
                "bracketed=0; the sibling half of the bullet no longer reproduces here"
        fi

        # THE PRESCRIBED FORM: session-scoped, so the plant is excluded.
        # `grep -F -- "--match 'myjob'"` ALSO matches the `--until-gone --match`
        # line — both contain that substring — and `bash -c` would then run the
        # refusal last and report ITS rc 2. Exclude the wait spelling
        # explicitly; measured, not guessed (it produced exactly that rc here).
        _match_form=$(printf '%s\n' "$FORMS" | grep -F -- "--match '" \
                      | grep -vF -- '--until-gone' | sed "s/'myjob'/'$NONCE'/")
        _out=$(NEXUS_ROOT="$REPO_ROOT" bash -c "$_match_form" 2>&1); _rc=$?
        assert_eq "the documented --match form answers ABSENT (rc 1) for a foreign plant" "$_rc" "1"
        if [[ "$_out" == *"unowned=1"* ]]; then
            ok "…counting the unowned hit rather than hiding it behind a bare zero"
        else
            bad "…counting the unowned hit rather than hiding it" "out: $_out"
        fi
        if [[ "$_out" == *"NOTHING OWNED matched"* ]]; then
            ok "…and saying out loud that this is a refusal to guess"
        else
            bad "…and saying out loud that this is a refusal to guess" "out: $_out"
        fi
        kill "$_foreign" 2>/dev/null
    fi
fi

echo '=== The OWNED direction: the same form must still FIND your own job ==='
# The exclusion above is only useful if the tool is not simply blind. Same
# pattern, same command, process moved into OUR session.
ONONCE="cmo$$x$(date +%N | tail -c 6)"
( exec -a "mine_${ONONCE}_decoy" sleep 60 ) & _mine=$!; _kids="$_kids $_mine"
disown %% 2>/dev/null || true
sleep 1
_match_form=$(printf '%s\n' "$FORMS" | grep -F -- "--match '" \
              | grep -vF -- '--until-gone' | sed "s/'myjob'/'$ONONCE'/")
_out=$(NEXUS_ROOT="$REPO_ROOT" bash -c "$_match_form" 2>&1); _rc=$?
assert_eq "an OWNED process is found by the same documented form (rc 0)" "$_rc" "0"
if [[ "$_out" == *"owned_pids=$_mine"* ]]; then
    ok "…and its pid is named, so the answer is checkable"
else
    bad "…and its pid is named" "out: $_out"
fi
kill "$_mine" 2>/dev/null

echo
# COUNT GUARD. Two branches are conditional on a plant succeeding, so a case
# that stops running would show as a smaller green rather than a red.
_EXPECTED_ASSERTIONS=17   # +1: #1853 Control C potency
_ran=$(( PASS + FAIL + ${SKIP:-0} ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    ok "every declared assertion executed ($_EXPECTED_ASSERTIONS)"
else
    bad "assertion count drifted" "ran $_ran, expected $_EXPECTED_ASSERTIONS"
fi

th_summary_and_exit
