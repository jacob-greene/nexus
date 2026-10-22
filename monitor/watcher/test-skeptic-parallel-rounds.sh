#!/usr/bin/env bash
# SEVERAL SKEPTIC ROUNDS OPEN ON ONE TARGET: each verdict discharges ONLY its own
# round, and the target cannot retire while ANY round is open
# (your-org/your-nexus#414).
#
# Run: bash monitor/watcher/test-skeptic-parallel-rounds.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ── THE DEFECT ──────────────────────────────────────────────────────────────
#
# `mysite-review` had five batch skeptics, each armed (`ng skeptic-arm`)
# against its own fix log. The LEDGER (`skeptic/pending/.<key>.ledger`) already
# keeps one `armed` row per deliverable, so the rounds were distinct there. Every
# other writer treated the target as having ONE round:
#
#   · a verdict wrap-up `rm`ed the single pending marker whatever the ledger
#     still held, so the first verdict ended every sibling's await;
#   · its report-predates-round check measured against the NEWEST arm — a
#     sibling's — so a batch skeptic whose report was started before the next
#     batch was armed was refused for "predating" a round it never claimed;
#   · `skeptic-channel close` appended a `resolved` row, which closes EVERY
#     open arm, so one reviewer's close released its siblings' unreviewed
#     rounds and opened retire-preflight's ledger check 1be;
#   · `ng skeptic-arm` archived the channel's `*.answered.md` as "the prior
#     round", although they were a LIVE sibling's correspondence.
#
# The rounds are the ledger's open arms (keyed by the subject sha / deliverable);
# the marker is now their aggregate. Legacy (marker, no ledger) is one round.
#
# HERMETIC: `NEXUS_STATE_DIR` is a scratch dir, pinned and checked.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
NG="$REPO_ROOT/monitor/ng"
SC="$REPO_ROOT/monitor/skeptic-channel.sh"
PF="$REPO_ROOT/monitor/retire-preflight.sh"

[[ -x "$NG" ]] || th_abort "monitor/ng not executable at $NG"
[[ -x "$SC" ]] || th_abort "monitor/skeptic-channel.sh not executable at $SC"
[[ -r "$PF" ]] || th_abort "monitor/retire-preflight.sh not readable at $PF"

# DECLARED to the guards-for-diff index: the files this suite EXECUTES.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$NG" "$SC" "$PF"
}
gp_handle "$@"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nexus-skpar-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/.state"
PEND="$STATE/skeptic/pending"
mkdir -p "$PEND" "$WORK/reports" "$WORK/pfreports"
export NEXUS_STATE_DIR="$STATE" NEXUS_ROOT="$WORK"
unset NEXUS_WORKER_WINDOW NEXUS_LOCALS
th_pin_ng_state "$NG" "$STATE"
case "$("$SC" dir pin-probe 2>/dev/null)" in
    "$STATE"/*) : ;;
    *) th_abort "skeptic-channel.sh did not resolve its state dir under the fixture ($STATE)" ;;
esac

_sha() { sha256sum < "$1" | awk '{print $1}'; }
# _arm <target> <label> → arms reports/<target>-<label>.md on issue 414
_arm() {
    printf 'round %s of %s\n' "$2" "$1" > "$WORK/reports/$1-$2.md"
    "$NG" skeptic-arm "$1" --report "$WORK/reports/$1-$2.md" --issue 414 \
        --state-dir "$STATE" >"$WORK/arm.out" 2>&1
}
# _skrep <name> → a skeptic report that states its disposition
_skrep() {
    printf -- '---\nproject: p\ndisposition: no-further-pass\n---\n\n## Summary\nverdict.\n' \
        > "$WORK/reports/$1.md"
    printf '%s' "$WORK/reports/$1.md"
}
# _verdict <target> <skeptic-window> <subject|""> <skeptic-report> → rc; output in $WORK/vd.out
_verdict() {
    local rc=0
    (
        source "$NG" >/dev/null 2>&1
        STATE_DIR="$STATE"
        _SK_REPORT_PATH="$4"
        _SK_SUBJECT_ARG="$3"
        _wrapup_skeptic_step 414 "$2" owner/repo 1 "" "" "" credible "$1" 1 0
    ) >"$WORK/vd.out" 2>&1 || rc=$?
    printf '%s' "$rc"
}
# _open <target> → the ledger's outstanding count
_open() {
    "$NG" skeptic-obligations "$1" --state-dir "$STATE" 2>/dev/null \
        | sed -n '1s/.*outstanding=\([0-9?]*\).*/\1/p'
}
# _pf <target> → retire-preflight rc (stdout in $WORK/pf.out)
_pf() {
    local rc=0
    bash "$PF" "$1" --pane-state idle --state-dir "$STATE" --now "$(date +%s)" \
        --reports-dir "$WORK/pfreports" >"$WORK/pf.out" 2>/dev/null || rc=$?
    printf '%s' "$rc"
}
_rows() { grep -c "^$1" "$PEND/.$2.ledger" 2>/dev/null || true; }

# ═══ 1. THREE ROUNDS ON ONE TARGET ═══════════════════════════════════════════
# Round A is armed, its skeptic writes its report, THEN rounds B and C are armed
# (the second at a later second, so "predates the newest arm" is a real fact).
_arm tgt A
SKA=$(_skrep skA-report)
# Round A's Q&A on the target's channel: one question asked and answered.
"$SC" ask tgt q1 --message "round A question" >/dev/null
"$SC" await tgt --once >/dev/null 2>&1
"$SC" answer tgt 1 --message "round A answer" >/dev/null
assert_eq "FIXTURE: round A's answered correspondence is in the channel" \
    "$(ls "$STATE/skeptic/tgt/"*.answered.md 2>/dev/null | wc -l | tr -d ' ')" "1"
sleep 1
_arm tgt B
sleep 1
_arm tgt C
assert_eq "three rounds armed on one target: outstanding=3" "$(_open tgt)" "3"
assert_file_exists "the pending marker exists" "$PEND/tgt"
assert_eq "arming B and C kept round A's LIVE answered correspondence in the channel" \
    "$(ls "$STATE/skeptic/tgt/"*.answered.md 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_contains "…and said why" "$(cat "$WORK/arm.out")" "other round(s) are still open"
assert_eq "retire refused with 3 rounds open" "$(_pf tgt)" "1"

# ═══ 2. DISCHARGE ROUND 2 ONLY ═══════════════════════════════════════════════
SKB=$(_skrep skB-report)
assert_eq "verdict on round B (subject = B's report) is recorded" \
    "$(_verdict tgt skB "$WORK/reports/tgt-B.md" "$SKB")" "0"
assert_eq "…as an ASSERTED discharge of exactly B's sha" \
    "$(awk -F'\t' '$1 == "discharged" { print $2 " " $7 }' "$PEND/.tgt.ledger")" \
    "$(_sha "$WORK/reports/tgt-B.md") asserted"
assert_eq "rounds A and C are still open: outstanding=2" "$(_open tgt)" "2"
assert_contains "…and they are A and C" \
    "$("$NG" skeptic-obligations tgt --state-dir "$STATE" 2>/dev/null | tr '\n' ' ')" \
    "$(_sha "$WORK/reports/tgt-A.md")"
assert_contains "…C too" \
    "$("$NG" skeptic-obligations tgt --state-dir "$STATE" 2>/dev/null | tr '\n' ' ')" \
    "$(_sha "$WORK/reports/tgt-C.md")"
assert_file_exists "the pending MARKER is KEPT while A and C are open" "$PEND/tgt"
assert_contains "the verdict banner says the marker was kept" "$(cat "$WORK/vd.out")" "other round(s) still open"
assert_eq "retire refused: rounds 1 and 3 still open" "$(_pf tgt)" "1"

# B's reviewer closes its pairing: two rounds are open, so nothing is released.
_crc=0; NEXUS_WORKER_WINDOW=skB "$SC" close tgt >/dev/null 2>"$WORK/close.err" || _crc=$?
assert_eq "a close that leaves the channel open exits 16, not 0 (#1810 skeptic F1)" "$_crc" "16"
assert_contains "close with 2 rounds open leaves the channel OPEN" "$(cat "$WORK/close.err")" "LEFT OPEN"
assert_no_file "…writes no DONE" "$STATE/skeptic/tgt/DONE"
assert_eq "…appends no resolved row (which would release A and C)" "$(_rows resolved tgt)" "0"
assert_file_exists "…keeps the marker" "$PEND/tgt"
assert_eq "…and A and C are still open" "$(_open tgt)" "2"

# ═══ 3. ROUND A: its report predates C's arm, NOT its own ════════════════════
touch -d "$(awk -F'\t' '$1 == "armed" { print $3; exit }' "$PEND/.tgt.ledger")" "$SKA"
assert_eq "verdict on round A from a report written BEFORE round C was armed is recorded" \
    "$(_verdict tgt skA "$WORK/reports/tgt-A.md" "$SKA")" "0"
assert_not_contains "…not refused as predating a sibling's round" "$(cat "$WORK/vd.out")" "predates the round"
assert_eq "only round C is open now" "$(_open tgt)" "1"
assert_file_exists "the marker is still KEPT (C open)" "$PEND/tgt"
_crc=0; NEXUS_WORKER_WINDOW=skA "$SC" close tgt >/dev/null 2>"$WORK/close.err" || _crc=$?
assert_eq "A's kept-open close exits 16" "$_crc" "16"
assert_contains "A's close with only C (a SIBLING's round) open leaves the channel OPEN" \
    "$(cat "$WORK/close.err")" "sibling's round"
assert_eq "…and releases nothing" "$(_rows resolved tgt)" "0"
assert_eq "retire refused: round 3 still open" "$(_pf tgt)" "1"

# NEGATIVE CONTROL (skprotosk F5 still holds): a report older than ITS OWN round.
_arm tgt D
SKD=$(_skrep skD-report)
touch -d '2001-01-01' "$SKD"
assert_eq "CONTROL: a verdict whose report predates ITS OWN round is still refused" \
    "$(_verdict tgt skD "$WORK/reports/tgt-D.md" "$SKD")" "1"
assert_contains "…for predating the round" "$(cat "$WORK/vd.out")" "predates the round"
touch "$SKD"
assert_eq "round D discharged with a fresh report" \
    "$(_verdict tgt skD "$WORK/reports/tgt-D.md" "$SKD")" "0"

# ═══ 4. DISCHARGE ALL → RETIRE ALLOWED ═══════════════════════════════════════
SKC=$(_skrep skC-report)
assert_eq "verdict on round C is recorded" "$(_verdict tgt skC "$WORK/reports/tgt-C.md" "$SKC")" "0"
assert_eq "no round is open" "$(_open tgt)" "0"
assert_no_file "the last verdict releases the marker" "$PEND/tgt"
assert_eq "retire allowed once every round is discharged" "$(_pf tgt)" "0"
NEXUS_WORKER_WINDOW=skC "$SC" close tgt >/dev/null 2>&1
assert_file_exists "the last close writes DONE (nothing open)" "$STATE/skeptic/tgt/DONE"

# ═══ 5. LEGACY: a marker with NO ledger is one round ═════════════════════════
printf '1' > "$PEND/legacy"
assert_eq "legacy marker (no ledger) blocks retire" "$(_pf legacy)" "1"
SKL=$(_skrep skL-report)
assert_eq "a verdict on the legacy round is recorded" "$(_verdict legacy skL "" "$SKL")" "0"
assert_no_file "…and releases the legacy marker" "$PEND/legacy"
assert_eq "legacy round discharged → retire allowed" "$(_pf legacy)" "0"

# ═══ 6. MUST-NOT-FLIP: single-round shapes keep their old behaviour ══════════
# A lone round closed WITHOUT a verdict is still released by close (#961's
# anti-brick path).
_arm solo A
NEXUS_WORKER_WINDOW=skS "$SC" close solo >/dev/null 2>&1
assert_eq "CONTROL single round, close without verdict: the round is released" "$(_rows resolved solo)" "1"
assert_no_file "CONTROL …the marker is cleared" "$PEND/solo"
assert_file_exists "CONTROL …DONE is written" "$STATE/skeptic/solo/DONE"

# A retained skeptic's round 2 after round 1 was discharged: still THIS closer's
# own round (armed after its verdict), so close releases it as before.
_arm ret A
SKR=$(_skrep skR-report)
_verdict ret skR "$WORK/reports/ret-A.md" "$SKR" >/dev/null
sleep 1
_arm ret B
NEXUS_WORKER_WINDOW=skR "$SC" close ret >/dev/null 2>&1
assert_eq "CONTROL retained reviewer's next round (armed after its verdict) is released by its close" \
    "$(_rows resolved ret)" "1"

# A new round after the previous one CLOSED archives the prior correspondence.
_arm seq A
"$SC" ask seq q1 --message "q" >/dev/null
"$SC" await seq --once >/dev/null 2>&1
"$SC" answer seq 1 --message "a" >/dev/null
SKQ=$(_skrep skQ-report)
_verdict seq skQ "$WORK/reports/seq-A.md" "$SKQ" >/dev/null
assert_no_file "CONTROL single round: the verdict releases the marker" "$PEND/seq"
_arm seq B
assert_eq "CONTROL a new round with no sibling open archives the prior answered correspondence" \
    "$(ls "$STATE/skeptic/seq/"*.answered.md 2>/dev/null | wc -l | tr -d ' ')" "0"

# ═══ 7. A REQUIRE WRAP-UP OPENING A SIBLING ROUND ════════════════════════════
# The worker's own `wrap-up --skeptic-decision require` is the other round
# opener; with round A still open it must not archive A's correspondence.
_arm wk A
"$SC" ask wk q1 --message "q" >/dev/null
"$SC" await wk --once >/dev/null 2>&1
"$SC" answer wk 1 --message "a" >/dev/null
printf -- '---\nproject: p\ndisposition: no-further-pass\n---\nsecond deliverable\n' > "$WORK/reports/wk-B.md"
(
    source "$NG" >/dev/null 2>&1
    STATE_DIR="$STATE"
    _SK_REPORT_PATH="$WORK/reports/wk-B.md"
    _SK_SPAWN_REQ=0
    _wrapup_skeptic_step 414 wk owner/repo 0 require "why" "" "" "" "" "" "" "" ""
) >"$WORK/wu.out" 2>&1
assert_eq "a require wrap-up on a second deliverable opens a second round: outstanding=2" "$(_open wk)" "2"
assert_eq "…and keeps round A's LIVE answered correspondence in the channel" \
    "$(ls "$STATE/skeptic/wk/"*.answered.md 2>/dev/null | wc -l | tr -d ' ')" "1"

# ═══ 8. AN ABANDONED EARLIER ROUND IS NOT A SIBLING (#1810 skeptic F1) ═══════
# The sequential revise-and-re-wrap flow: round X is armed, the worker revises
# and re-arms under a NEW report path (Y) before X's verdict lands, and the
# reviewer's verdict attributes to Y. X stays open on the ledger. It was armed
# BEFORE the closer's own round, so close must release it as the base did —
# DONE, a `resolved` row, the marker gone — not keep the channel open for a
# round nobody will ever review. The live `.overlay.ledger` holds this shape.
_arm ab round1
sleep 1
_arm ab round1b
SKAB=$(_skrep skAB-report)
_verdict ab ab-sk "$WORK/reports/ab-round1b.md" "$SKAB" >/dev/null
assert_eq "FIXTURE: the abandoned round1 is still open after round1b's verdict" "$(_open ab)" "1"
assert_file_exists "FIXTURE: …and its marker is kept" "$PEND/ab"
_crc=0; NEXUS_WORKER_WINDOW=ab-sk "$SC" close ab >/dev/null 2>"$WORK/close.err" || _crc=$?
assert_eq "F1: close releases an abandoned EARLIER round: rc 0" "$_crc" "0"
assert_not_contains "F1: …not LEFT OPEN" "$(cat "$WORK/close.err")" "LEFT OPEN"
assert_file_exists "F1: …DONE is written, so the target's await ends" "$STATE/skeptic/ab/DONE"
assert_eq "F1: …a resolved row releases it on the ledger" "$(_rows resolved ab)" "1"
assert_no_file "F1: …the marker is removed" "$PEND/ab"
assert_eq "F1: …nothing is outstanding" "$(_open ab)" "0"

# A LIVE REVIEWER other than the closer is the other positive evidence of a
# sibling. `tmux` is an exported FUNCTION scoped to one subshell, never a shim
# file on PATH (test-tmux-shim-gate3-safety.sh): it only prints a fixture list.
_close_tm() {   # <target> <closer> <tmux-names...> → rc; stderr in $WORK/close.err
    local t="$1" by="$2" rc=0; shift 2
    printf '%s\n' "$@" > "$WORK/tmux-names"
    (   tmux() { [[ "${1:-}" == list-windows ]] && cat "$WORK/tmux-names"; }
        export -f tmux; export WORK
        NEXUS_WORKER_WINDOW="$by" "$SC" close "$t" >/dev/null 2>"$WORK/close.err"
    ) || rc=$?
    printf '%s' "$rc"
}
mkdir -p "$STATE/windows"
printf '{"window":"lv-sk1","spawned_at":"2026-10-12T10:00:00-07:00","skeptic_role":true,"skeptic_target":"lv","skeptic_orig":"lv"}\n' > "$STATE/windows/lv-sk1.json"
printf '{"window":"lv-sk2","spawned_at":"2026-10-12T10:01:00-07:00","skeptic_role":true,"skeptic_target":"lv","skeptic_orig":"lv"}\n' > "$STATE/windows/lv-sk2.json"
_arm lv A
assert_eq "LIVE: a second recorded reviewer still in tmux keeps the channel open: rc 16" \
    "$(_close_tm lv lv-sk1 lv lv-sk1 lv-sk2)" "16"
assert_contains "LIVE: …naming that reviewer" "$(cat "$WORK/close.err")" "lv-sk2"
assert_no_file "LIVE: …and writing no DONE" "$STATE/skeptic/lv/DONE"
assert_eq "LIVE CONTROL: the closer itself being live is not a sibling: released, rc 0" \
    "$(_close_tm lv lv-sk1 lv lv-sk1 lv-sk2-old)" "0"
assert_file_exists "LIVE CONTROL: …DONE is written" "$STATE/skeptic/lv/DONE"

# ── ASSERTION-COUNT PIN ────────────────────────────────────────────────────
EXPECTED=61
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
