#!/usr/bin/env bash
# test-degraded-enter-exit.sh — `ng degraded enter|exit` and the ONE pointer
# reader behind the ledger and inbox resolvers (your-org/nexus-code#1724,
# pieces A and B).
#
#   A. no pointer: every resolver answers EXACTLY today's path, spelled as given
#      (byte-identical), and another nexus's pointer does not leak in (#833).
#   B. a refused enter: no resolvable run dir (rc 3), and every surface
#      writable (rc 1, no --force); neither leaves a pointer.
#   C. enter through the RO SEAM (the probe's writer): the pointer lands in the
#      run dir, OUTSIDE the tree, and both resolvers follow it; the guard's
#      history (the ledger's rows) and the inbox come along.
#   D. writers AND readers use the relocated path, driven through the real
#      code with the tree's state dir made unwritable: a watcher stamp, the
#      watcher's guard reader, the retirement bookkeeping, and the request
#      channel's file/list.
#   E. exit: refused while a probe is not OK (pointer kept); then a merge home
#      — ledger rows appended once, an inbox rename propagated, a new request
#      copied — and every resolver back on the tree, byte-identical.
#   F. a CONFLICT refuses exit and changes nothing; --force exits rc 4 and
#      lists it STILL STAGED.
#   G. THE REAL REGISTERED SURFACES, no seam (a seam cannot test selection):
#      a real unwritable state dir, the real probe, the real surface list; the
#      pointer names exactly the surfaces degraded-relocate.sh registers and
#      each one's resolver follows it.
#   H. a population lint: no tracked monitor/ shell file outside the resolver
#      composes `<…>/machine-input.tsv` on a code line, except the marked
#      resolver-absent fallback, so a new reader or writer cannot split the
#      ledger from the guard.
#   I. `ng degraded` routes enter/exit.
#
# Run: bash monitor/watcher/test-degraded-enter-exit.sh

set -uo pipefail
if [[ -z "${_DEGEE_TEST_REEXEC:-}" ]]; then
    export _DEGEE_TEST_REEXEC=1
    # Never read the operator's live config, state or run dir (#833).
    exec env -u NEXUS_ROOT -u NEXUS_STATE_DIR -u NEXUS_REQUESTS_DIR -u NEXUS_DEGRADED_RUNDIR \
        -u NEXUS_DEGRADED_PROBE_WRITER -u MACHINE_INPUT_TSV -u ACTION_LOG \
        bash "${BASH_SOURCE[0]}" "$@"
fi

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_dir/.." && pwd)
REPO=$(cd "$MON/.." && pwd)
REL="$MON/degraded-relocate.sh"

# The lint's corpus (section H): every tracked monitor/ file the repo's SHARED
# shell predicate (monitor/shell-files.sh:shf_is_shell) calls shell — which,
# unlike a first-line shebang test, includes the sourced watcher libraries
# (`_idle_probe.sh` opens with `# shellcheck shell=bash`, and it holds the
# guard's reader) — minus the suites, the helper library and the resolver.
. "$MON/shell-files.sh"
_mi_corpus() {   # -> repo-relative paths
    local f
    (cd "$REPO" && git ls-files -- ':(glob)monitor/**') | while IFS= read -r f; do
        case "$f" in */test-*|*/_test_helpers.sh|monitor/_ledger_path.sh) continue ;; esac
        [[ -f "$REPO/$f" ]] || continue
        shf_is_shell "$REPO/$f" && printf '%s\n' "$f"
    done
}
# --- the guard's population (#1747): section H reads every tracked monitor/
# shell file, so it must be selectable by guards-for-diff. The corpus
# enumerator (called, not copied), plus the resolvers, the relocator and the
# helper library. Placed before anything prints: gp_handle exits on the flag.
. "$MON/_guard_population.sh"
gp_population() {
    _mi_corpus | sed "s|^|$REPO/|"
    printf '%s\n' "$MON/_ledger_path.sh" "$MON/_degraded-pointer.sh" "$MON/_degraded-rundir.sh" \
        "$MON/degraded-relocate.sh" "$MON/_requests_dir.sh" "$MON/shell-files.sh" "$_dir/_test_helpers.sh"
}
gp_handle "$@"

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

R="$WORK/nexus"; SD="$R/monitor/.state"; RD="$WORK/rundir"
mkdir -p "$SD/requests" "$R/reports" "$R/work"
printf 'w1\t1700000000000000\tpaste-followup\t\n' > "$SD/machine-input.tsv"
printf 'state: new\nbody one\n' > "$SD/requests/a1.new.md"
export NEXUS_ROOT="$R" NEXUS_STATE_DIR="$SD" NEXUS_DEGRADED_RUNDIR="$RD"

mkw() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$WORK/w-$1"; chmod +x "$WORK/w-$1"; printf '%s' "$WORK/w-$1"; }
EROFS=$(mkw erofs 'echo "bash: $1: Read-only file system" >&2; exit 1')

ledger()  { ( . "$MON/_ledger_path.sh"; nexus_ledger_path "$1" ); }
inbox()   { ( . "$MON/_requests_dir.sh"; nexus_requests_dir "$1" ); }
inboxsrc(){ ( . "$MON/_requests_dir.sh"; nexus_requests_dir_source "$1" ); }
ptrfile() { ( . "$MON/_degraded-pointer.sh"; nexus_degraded_pointer_path "$1" ); }
marker()  { ( . "$MON/_degraded-pointer.sh"; nexus_degraded_marker_path "$1" ); }
# The append-only record of earlier, unacknowledged losses beside the marker.
lostfile(){ local m; m=$(marker "$1") && printf '%s' "${m%.entered}.lost"; }
# The loss marker lives in $CLAUDE_CONFIG_DIR, the HARNESS's real state dir in
# an agent shell: point it at this suite's scratch, or `enter` below would
# write into the operator's own config tree.
export CLAUDE_CONFIG_DIR="$WORK/ccd"

echo '=== A. no pointer: today'"'"'s paths, byte-identical ==='
assert_eq "A1 ledger: <state>/machine-input.tsv"                    "$(ledger "$SD")" "$SD/machine-input.tsv"
assert_eq "A2 …spelled as given (a trailing slash is kept, as the old composition kept it)" "$(ledger "$SD/")" "$SD//machine-input.tsv"
assert_eq "A3 inbox: <state>/requests, source default"              "$(inbox "$SD") $(inboxsrc "$SD")" "$SD/requests default"
# Another nexus's pointer (a different state dir) is in force: it must not leak.
O="$WORK/other/monitor/.state"; mkdir -p "$O" "$RD"
op=$(ptrfile "$O"); printf 'state_dir=%s\nledger=%s/x.d/machine-input.tsv\nrequests=%s/x.d/requests\n' "$O" "$RD" "$RD" > "$op"
assert_eq "A4 another state dir's pointer does not move THIS nexus's ledger" "$(ledger "$SD")" "$SD/machine-input.tsv"
assert_eq "A5 …nor its inbox"                                       "$(inbox "$SD")" "$SD/requests"
assert_eq "A6 …while it DOES move its own (the pointer reader works)" "$(ledger "$O")" "$RD/x.d/machine-input.tsv"
rm -f "$op"
# A7-A8: an UNUSABLE pointer for THIS state dir (its ledger outside the run
# dir). The retirement check cannot know whether a row is left, so it must
# report the ledger still referenced, never read the tree's copy as the answer.
bkrefs() { ( . "$MON/_bookkeeping.sh" >/dev/null 2>&1; bk_state_refs_window "$SD" "$1" 2>/dev/null ); }
assert_not_contains "A7 control: no pointer, no row for the window → ledger not referenced" "$(bkrefs w-none)" "machine-input.tsv"
sp=$(ptrfile "$SD"); printf 'state_dir=%s\nledger=/elsewhere/machine-input.tsv\n' "$(cd "$SD" && pwd -P)" > "$sp"
assert_contains "A8 unusable pointer → bookkeeping fails CLOSED (still referenced)" "$(bkrefs w-none)" "machine-input.tsv"
rm -f "$sp"

echo '=== B. refused enter ==='
out=$(env -u NEXUS_DEGRADED_RUNDIR -u TMPDIR NEXUS_TMPDIR_BASE=rel NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter 2>&1); rc=$?
assert_eq       "B1 no resolvable run dir: rc 3"                    "$rc" "3"
assert_contains "B2 …names why, and that nothing was relocated"     "$out" "Nothing was relocated"
assert_eq       "B3 …and no pointer exists anywhere in the run dir" "$(ls -A "$RD")" ""
out=$(bash "$REL" enter 2>&1); rc=$?
assert_eq       "B4 every surface writable (real probe), no --force: rc 1" "$rc" "1"
assert_contains "B5 …says nothing is degraded"                      "$out" "nothing to relocate"
assert_eq       "B6 …and leaves no pointer"                         "$(ls -A "$RD")" ""

echo '=== C. enter through the RO seam ==='
out=$(NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter 2>&1); rc=$?
assert_eq       "C1 enter: rc 0"                                    "$rc" "0"
PTR=$(ptrfile "$SD")
assert_file_exists "C2 the pointer is a file in the run dir, outside the tree" "$PTR"
case "$PTR" in "$R"/*) inside=yes ;; *) inside=no ;; esac
assert_eq       "C3 …and NOT under the nexus tree"                  "$inside" "no"
LREL=$(ledger "$SD"); QREL=$(inbox "$SD")
case "$LREL" in "$RD"/*) l_ok=yes ;; *) l_ok="no ($LREL)" ;; esac
case "$QREL" in "$RD"/*) q_ok=yes ;; *) q_ok="no ($QREL)" ;; esac
assert_eq       "C4 the ledger resolver follows the pointer into the run dir" "$l_ok" "yes"
assert_eq       "C5 the inbox resolver follows it too, source=degraded" "$q_ok $(inboxsrc "$SD")" "yes degraded"
assert_eq       "C6 the guard's history came along (pre-enter row present)" "$(cat "$LREL")" "$(printf 'w1\t1700000000000000\tpaste-followup\t')"
assert_file_exists "C7 the inbox came along"                        "$QREL/a1.new.md"
out=$(NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter 2>&1); rc=$?
assert_eq       "C8 a second enter is idempotent: rc 0, already in force" "$rc:$(grep -c 'already in degraded mode' <<<"$out")" "0:1"

echo '=== D. writers and readers use the relocated path (real code, tree unwritable) ==='
chmod 0555 "$SD/requests" "$SD"
if [[ "$(id -u)" != 0 ]] && ! ( : > "$SD/.x" ) 2>/dev/null; then
    # D1 a watcher-side writer: _lib.sh's stamp chokepoint, as the watcher calls it.
    ( STATE_DIR="$SD"; ACTION_LOG="$SD/action-log.jsonl"; . "$_dir/_lib.sh" >/dev/null 2>&1; _machine_input_stamp w2 unstick-test ) 2>/dev/null
    assert_contains "D1 the watcher's stamp lands in the RELOCATED ledger" "$(cat "$LREL")" "$(printf 'w2\t')"
    assert_eq       "D2 …and the tree's ledger is untouched (one row)"  "$(wc -l < "$SD/machine-input.tsv" | tr -d ' ')" "1"
    # D3 the watcher's guard/attribution reader, which decides delivery.
    printf 'w3\t1700000100000000\tpaste-followup\t\n' >> "$LREL"
    got=$( STATE_DIR="$SD"; . "$_dir/_lib.sh" >/dev/null 2>&1; . "$_dir/_idle_probe.sh" >/dev/null 2>&1; _machine_input_path; echo; _openg_machine_input_epoch w3 ) 2>/dev/null
    assert_eq       "D3 the idle probe's ledger path is the relocated one" "${got%%$'\n'*}" "$LREL"
    assert_eq       "D4 …and its attribution reader sees a row only the relocated ledger holds" "${got##*$'\n'}" "1700000100"
    # D5 the retirement bookkeeping reports a window whose only row is relocated.
    got=$( . "$MON/_bookkeeping.sh" >/dev/null 2>&1; bk_state_refs_window "$SD" w3 )
    assert_contains "D5 bk_state_refs_window sees the relocated ledger's row" "$got" "machine-input.tsv"
    # D6 the request channel files into, and lists from, the relocated inbox.
    id=$( bash "$MON/request-channel.sh" file --origin w1 --no-publish --slug degtest --message 'hello' 2>/dev/null ); frc=$?
    assert_eq       "D6 request-channel file succeeds with the tree unwritable" "$frc" "0"
    n=$(find "$QREL" -maxdepth 1 -name '*degtest*.new.md' | wc -l | tr -d ' ')
    assert_eq       "D7 …and the request landed in the RELOCATED inbox" "$n" "1"
    assert_contains "D8 list reads the relocated inbox" "$(bash "$MON/request-channel.sh" list --state new 2>/dev/null)" "degtest"
    # D9-D11 the primary writer, `ng send` (send.sh). No tmux server is
    # reachable (TMUX unset, a private TMUX_TMPDIR) and the window name exists
    # nowhere, so nothing can be pasted anywhere; what is measured is the
    # ledger decision, which comes first.
    snd() { env -u TMUX TMUX_TMPDIR="$WORK/notmux" bash "$MON/send.sh" w9-degtest-nowin "$@" 2>&1; }
    mkdir -p "$WORK/notmux"
    mv "$PTR" "$PTR.off"
    assert_contains "D9 control: with the pointer moved away, send refuses DEGRADED (the tree IS unwritable)" "$(snd --message hi)" "DEGRADED — the delivery ledger cannot be written"
    mv "$PTR.off" "$PTR"
    assert_not_contains "D10 with the pointer in force, send gets past the ledger check" "$(snd --message hi)" "DEGRADED"
    assert_contains "D11 …and the ledger it names is the relocated one" "$(snd --ledger-coverage)" "ledger=$LREL"
    _D_RAN=11
else
    th_skip "D: the mode bits do not bind for this uid; writers/readers not driven"
    _D_RAN=0
fi
chmod 0755 "$SD" "$SD/requests"

echo '=== E. exit ==='
out=$(NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" exit --probes 2 --interval 0 2>&1); rc=$?
assert_eq       "E1 a probe not OK refuses exit: rc 1"              "$rc" "1"
assert_file_exists "E2 …and the pointer stays in force"             "$PTR"
# E2b-E2c: a FLAPPING tree (the incidents flapped 4x in 4 h). Round 1 probes
# both relocated surfaces OK (writer calls 1-2), round 2 fails (call 3 on). A
# single probe would have exited here; N consecutive OK probes must not.
FLAP=$(mkw flap 'c="$(dirname "$0")/flap.count"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
if (( n <= 2 )); then : > "$1" && rm -f -- "$1"; else echo "bash: $1: Read-only file system" >&2; exit 1; fi')
rm -f "$WORK/flap.count"
out=$(NEXUS_DEGRADED_PROBE_WRITER="$FLAP" bash "$REL" exit --probes 2 --interval 0 2>&1); rc=$?
assert_eq       "E2b healthy once, then not: exit refused, rc 1, pointer kept" "$rc:$([[ -f "$PTR" ]] && echo kept)" "1:kept"
assert_contains "E2c …refused at the SECOND probe, after the first passed" "$out" "probe 2/2 is not OK"
# Simulate the incident's own writes: a stamp, a claim (rename), a new request.
printf 'w1\t1700000200000000\tpaste-followup\tadmin\n' >> "$LREL"
# Two more, written OUT of epoch order, so the merge's epoch sort is observable.
printf 'w1\t1700000400000000\tpaste-followup\tlate\n' >> "$LREL"
printf 'w1\t1700000300000000\tpaste-followup\tearly\n' >> "$LREL"
mv "$QREL/a1.new.md" "$QREL/a1.claimed.md"
printf 'state: new\nbody two\n' > "$QREL/b2.new.md"
out=$(bash "$REL" exit --probes 2 --interval 0 2>&1); rc=$?
assert_eq       "E3 exit after sustained health: rc 0"              "$rc" "0"
assert_contains "E4 …it required both probes"                       "$out" "probe 2/2"
assert_no_file  "E5 the pointer is gone"                            "$PTR"
assert_no_file  "E5b a clean exit clears the loss marker too"        "$(marker "$SD")"
assert_eq       "E6 the ledger resolver is back on the tree, byte-identical" "$(ledger "$SD")" "$SD/machine-input.tsv"
assert_eq       "E7 the inbox resolver too, source default"         "$(inbox "$SD") $(inboxsrc "$SD")" "$SD/requests default"
assert_eq       "E8 the pre-enter row is in the tree ledger ONCE (no duplicate)" "$(grep -c '1700000000000000' "$SD/machine-input.tsv")" "1"
assert_contains "E9 the row stamped while relocated is home"        "$(cat "$SD/machine-input.tsv")" "$(printf '1700000200000000\tpaste-followup\tadmin')"
assert_eq       "E9b rows appended home in EPOCH order, not file order" \
    "$(awk -F'\t' '$4 == "early" || $4 == "late" { printf "%s ", $4 }' "$SD/machine-input.tsv")" "early late "
assert_eq       "E10 the inbox rename propagated: claimed home, new gone" \
    "$([[ -f "$SD/requests/a1.claimed.md" ]] && echo C)$([[ -f "$SD/requests/a1.new.md" ]] && echo N)" "C"
assert_file_exists "E11 the request filed while relocated is home"  "$SD/requests/b2.new.md"
n=$(find "$RD" -maxdepth 1 -name '*.exited-*' -type d | wc -l | tr -d ' ')
assert_eq       "E12 the relocated copy is kept for audit, not deleted" "$n" "1"
out=$(bash "$REL" exit 2>&1); rc=$?
assert_eq       "E13 exit with nothing in force: rc 0, says so"     "$rc:$(grep -c 'not in degraded mode' <<<"$out")" "0:1"

echo '=== F. a conflict ==='
NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter >/dev/null 2>&1
QREL=$(inbox "$SD")
printf 'state: new\nedited in the TREE\n' > "$SD/requests/b2.new.md"
printf 'state: new\nedited while RELOCATED\n' > "$QREL/b2.new.md"
out=$(bash "$REL" exit --probes 1 --interval 0 2>&1); rc=$?
assert_eq       "F1 both sides changed one file: exit refused, rc 1" "$rc" "1"
assert_contains "F2 …with the conflict itemised"                    "$out" "CONFLICT b2.new.md"
assert_file_exists "F3 …the pointer is still in force"              "$PTR"
assert_contains "F4 …and the tree's file is untouched"              "$(cat "$SD/requests/b2.new.md")" "edited in the TREE"
out=$(bash "$REL" exit --probes 1 --interval 0 --force 2>&1); rc=$?
assert_eq       "F5 --force exits but reports STILL STAGED: rc 4"   "$rc" "4"
assert_contains "F6 …listing the conflict"                          "$out" "STILL STAGED"
assert_no_file  "F7 …and the pointer is removed"                    "$PTR"

echo '=== L. a restart wipes the run dir: exit says LOST, never "nothing to do" (#1830 skeptic F1) ==='
# Every recorded RO incident ended in a sandbox restart, which wipes the run dir
# (pointer AND staged copies). The marker outside it is what lets `exit` tell
# "nothing was in force" from "it was in force and is gone".
for _p in "$RD"/*.relocate; do [[ -f "$_p" ]] && bash "$REL" exit --probes 1 --interval 0 --force >/dev/null 2>&1; done
rm -f "$(marker "$SD")"
NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter >/dev/null 2>&1
MK=$(marker "$SD")
case "$MK" in "$RD"/*) mk_out=no ;; "$WORK/ccd"/*) mk_out=yes ;; *) mk_out="no ($MK)" ;; esac
assert_eq       "L1 enter leaves a loss marker OUTSIDE the run dir" "$([[ -f "$MK" ]] && echo present) $mk_out" "present yes"
printf 'w1\t1700000500000000\tpaste-followup\tdoomed\n' >> "$(ledger "$SD")"
rm -rf "${RD:?}"/* "$RD"/.[!.]* 2>/dev/null    # the restart
out=$(bash "$REL" exit --probes 1 --interval 0 2>&1); rc=$?
assert_eq       "L2 exit after the wipe: rc 5, not a clean 0" "$rc" "5"
assert_contains "L3 …and it says LOST, naming what is gone"   "$out" "is GONE: it never reached"
out=$(bash "$REL" exit --ack-loss 2>&1); rc=$?
assert_eq       "L4 --ack-loss records it and clears the marker" "$rc:$([[ -f "$MK" ]] || echo cleared)" "0:cleared"
out=$(bash "$REL" exit 2>&1); rc=$?
assert_eq       "L5 control: after the ack, exit is the plain nothing-to-do, rc 0" "$rc:$(grep -c 'nothing to do' <<<"$out")" "0:1"

echo '=== M. a second enter before --ack-loss preserves the earlier loss (#1724 residual) ==='
# The skeptic's residual on #1830: `enter` used to OVERWRITE the loss marker, so
# a relocation entered while an earlier loss was unacknowledged erased that
# loss — and its clean exit then removed the only trace. Evidence is appended,
# never overwritten, and `enter` is NOT refused: during an outage it is the
# relocation that keeps ng send and the inbox working.
LOSTF=$(lostfile "$SD")
_when() { date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "epoch $1"; }
# The watcher's once-per-process reader, driven through the real _fs_guard.sh.
wlost() {
    ( . "$MON/_degraded-pointer.sh"; . "$_dir/_fs_guard.sh" >/dev/null 2>&1
      log() { printf 'LOG %s\n' "$*"; }; _fs_note_deliver() { printf 'NOTE %s\n' "$1"; }
      STATE_DIR="$SD"; FS_LOSS_CHECKED=0; _fs_relocation_lost_check ) 2>&1
}
NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter >/dev/null 2>&1
sed -i 's/^entered=.*/entered=1700000000/' "$MK"           # loss 1, dated distinctly
rm -rf "${RD:?}"/* "$RD"/.[!.]* 2>/dev/null                   # restart 1 wipes it
out=$(NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter 2>&1); rc=$?
assert_eq       "M1 enter with an unacknowledged loss is NOT refused: rc 0, relocated" "$rc:$([[ -f "$PTR" ]] && echo inforce)" "0:inforce"
assert_contains "M2 …and it says the earlier loss is preserved, unacknowledged" "$out" "UNACKNOWLEDGED"
assert_contains "M3 status lists the earlier loss while the new relocation is in force" \
    "$(bash "$MON/degraded-status.sh" --timeout 5 2>&1)" "LOST (unacknowledged): relocation entered $(_when 1700000000)"
assert_contains "M4 the watcher reports it although a pointer is in force" "$(wlost)" "NOTE [nexus watcher] LOST"
out=$(bash "$REL" exit --probes 1 --interval 0 2>&1); rc=$?
assert_eq       "M5 the second relocation exits cleanly: rc 0" "$rc" "0"
assert_contains "M6 …and its exit says an earlier loss is still unacknowledged" "$out" "still UNACKNOWLEDGED"
out=$(bash "$REL" exit 2>&1); rc=$?
assert_eq       "M7 the earlier loss survives that clean exit: rc 5, not nothing-to-do" "$rc" "5"
assert_contains "M8 …naming WHEN it was entered" "$out" "$(_when 1700000000)"
NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter >/dev/null 2>&1
rm -rf "${RD:?}"/* "$RD"/.[!.]* 2>/dev/null                   # restart 2: a second loss
out=$(bash "$REL" exit 2>&1); rc=$?
assert_eq       "M9 two losses: rc 5, both counted" "$rc:$(grep -c 'LOST — relocation entered' <<<"$out")" "5:2"
assert_contains "M10 …the first still named" "$out" "$(_when 1700000000)"
out=$(bash "$REL" exit --ack-loss 2>&1); rc=$?
assert_eq       "M11 one --ack-loss clears every recorded loss" "$rc:$([[ -e "$MK" || -e "$LOSTF" ]] || echo cleared)" "0:cleared"
assert_contains "M12 …and says how many it acknowledged" "$out" "2 relocation(s)"
out=$(bash "$REL" exit 2>&1); rc=$?
assert_eq       "M13 control: after the ack, the plain nothing-to-do, rc 0" "$rc:$(grep -c 'nothing to do' <<<"$out")" "0:1"
assert_not_contains "M14 control: and the watcher is silent" "$(wlost)" "LOST"
# M15-M18: the lost record cannot be appended to (here: a directory in its
# place). enter must still relocate, and must KEEP the old marker rather than
# overwrite it; the new relocation's clean exit must not remove it (its id is
# not the pointer's), so the earlier loss is still reported.
NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter >/dev/null 2>&1
sed -i 's/^entered=.*/entered=1700000000/' "$MK"
rm -rf "${RD:?}"/* "$RD"/.[!.]* 2>/dev/null
mkdir "$LOSTF"
out=$(NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter 2>&1); rc=$?
assert_eq       "M15 lost record unwritable: enter still relocates, rc 0" "$rc:$([[ -f "$PTR" ]] && echo inforce)" "0:inforce"
assert_contains "M16 …and says the old marker is KEPT"  "$out" "is KEPT"
bash "$REL" exit --probes 1 --interval 0 >/dev/null 2>&1
out=$(bash "$REL" exit 2>&1); rc=$?
assert_eq       "M17 after the new relocation's clean exit the kept loss still reports: rc 5, dated" \
    "$rc:$(grep -c "$(_when 1700000000)" <<<"$out")" "5:1"
rmdir "$LOSTF"; bash "$REL" exit --ack-loss >/dev/null 2>&1
assert_eq       "M18 …and --ack-loss clears it" "$(bash "$REL" exit >/dev/null 2>&1; echo $?)" "0"
# M19-M22 (ncbundle27-sk F2): the kept marker was written by the PRE-id code
# (#1830: no `id=` line) and the append fails. An id-less marker used to read as
# "this relocation's", so the loss vanished from status and the clean exit
# deleted it. Ids must MATCH, both empty included.
NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter >/dev/null 2>&1
sed -i 's/^entered=.*/entered=1700000000/; /^id=/d' "$MK"   # an id-less (#1830) marker
rm -rf "${RD:?}"/* "$RD"/.[!.]* 2>/dev/null
mkdir "$LOSTF"
NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter >/dev/null 2>&1
assert_eq       "M19 rig: the new pointer carries an id, the kept marker none" \
    "$(grep -c '^id=' "$PTR"):$(grep -c '^id=' "$MK")" "1:0"
assert_contains "M20 status lists the id-less earlier loss while the new relocation is in force" \
    "$(bash "$MON/degraded-status.sh" --timeout 5 2>&1)" "LOST (unacknowledged): relocation entered $(_when 1700000000)"
bash "$REL" exit --probes 1 --interval 0 >/dev/null 2>&1
assert_eq       "M21 the new relocation's clean exit does NOT delete the id-less marker" "$([[ -f "$MK" ]] && echo kept)" "kept"
out=$(bash "$REL" exit 2>&1); rc=$?
assert_eq       "M22 …so the loss still reports: rc 5, dated" "$rc:$(grep -c "$(_when 1700000000)" <<<"$out")" "5:1"
rmdir "$LOSTF"; bash "$REL" exit --ack-loss >/dev/null 2>&1
# M23-M24 CONTROL: pointer AND marker both id-less (a relocation entered wholly
# by the #1830 code) is still that relocation's own marker: no loss, and its
# clean exit removes it.
NEXUS_DEGRADED_PROBE_WRITER="$EROFS" bash "$REL" enter >/dev/null 2>&1
sed -i '/^id=/d' "$MK" "$PTR"
assert_not_contains "M23 control: an id-less pointer + id-less marker is NOT a loss" \
    "$(bash "$MON/degraded-status.sh" --timeout 5 2>&1)" "LOST (unacknowledged)"
bash "$REL" exit --probes 1 --interval 0 >/dev/null 2>&1
out=$(bash "$REL" exit 2>&1); rc=$?
assert_eq       "M24 control: …and its clean exit removes it: then nothing-to-do, rc 0" "$rc:$([[ -f "$MK" ]] || echo gone)" "0:gone"

echo '=== G. the REAL registered surfaces, no seam ==='
surfaces=$(awk '/^_surfaces\(\)/ { sub(/.*printf .%s\\n. /, ""); sub(/; *}.*/, ""); print }' "$REL")
assert_eq       "G1 degraded-relocate.sh registers exactly: ledger requests" "$surfaces" "ledger requests"
chmod 0555 "$SD/requests" "$SD"
if [[ "$(id -u)" != 0 ]] && ! ( : > "$SD/.x" ) 2>/dev/null; then
    out=$(bash "$REL" enter 2>&1); rc=$?
    assert_eq   "G2 a REALLY unwritable state dir: enter (real probe, no --force) rc 0" "$rc" "0"
    keys=$(grep -v '^#' "$PTR" | cut -d= -f1 | grep -vE '^(state_dir|entered|id)$|\.home$' | LC_ALL=C sort | tr '\n' ' ')
    assert_eq   "G3 the pointer relocates exactly the registered surfaces" "${keys% }" "$(tr ' ' '\n' <<<"$surfaces" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    for s in $surfaces; do
        case $s in
            ledger)   got=$(ledger "$SD") ;;
            requests) got=$(inbox "$SD") ;;
            *)        got="(no resolver known to this suite)" ;;
        esac
        want=$(awk -F= -v k="$s" '$1 == k { print substr($0, length(k) + 2) }' "$PTR")
        assert_eq "G4 surface '$s': its resolver follows the pointer" "$got" "$want"
    done
    chmod 0755 "$SD" "$SD/requests"
    bash "$REL" exit --probes 1 --interval 0 >/dev/null 2>&1
    _G_RAN=$(( 2 + $(wc -w <<<"$surfaces") ))
else
    th_skip "G2-G4: the mode bits do not bind for this uid"
    chmod 0755 "$SD" "$SD/requests"
    _G_RAN=0
fi

echo '=== H. population lint: one composer of the ledger path ==='
lint() {   # <file>... -> offending "<file>:<line>: <text>" rows
    local f
    for f in "$@"; do
        awk -v f="$f" '
            /^[[:space:]]*#/ { next }
            /ledger-resolver-absent/ { next }
            index($0, "/machine-input.tsv") { printf "%s:%d: %s\n", f, NR, $0 }' "$f"
    done
}
corpus=()
while IFS= read -r f; do corpus+=("$f"); done < <(_mi_corpus)
(( ${#corpus[@]} > 100 )) && corpus_ok=yes || corpus_ok="no (${#corpus[@]})"
assert_eq       "H1 the corpus is the real shell tree (>100 files), not a silent zero" "$corpus_ok" "yes"
hits=$(cd "$REPO" && lint "${corpus[@]}")
assert_empty    "H2 no tracked monitor/ shell file composes <…>/machine-input.tsv outside the resolver" "$hits"
printf '#!/usr/bin/env bash\nmi="$STATE_DIR/machine-input.tsv"\n# mi="$STATE_DIR/machine-input.tsv"\n' > "$WORK/plant.sh"
assert_contains "H3 positive control: a planted composition IS flagged" "$(lint "$WORK/plant.sh")" 'plant.sh:2:'
assert_not_contains "H4 …and its commented twin is not"            "$(lint "$WORK/plant.sh")" 'plant.sh:3:'
fb=$(cd "$REPO" && grep -l 'ledger-resolver-absent' "${corpus[@]}" | LC_ALL=C sort | tr '\n' ' ')
assert_eq       "H5 the marked resolver-absent fallbacks are exactly the known set" "${fb% }" \
    "monitor/bootstrap-recover.sh monitor/paste-followup.sh monitor/retire-preflight.sh monitor/send.sh monitor/skeptic-channel.sh monitor/watcher/_idle_probe.sh monitor/watcher/_lib.sh"

echo '=== I. ng routing ==='
out=$("$MON/ng" degraded exit 2>&1); rc=$?
assert_eq       "I1 ng degraded exit reaches the script (nothing in force: rc 0)" "$rc:$(grep -c 'not in degraded mode' <<<"$out")" "0:1"
out=$("$MON/ng" degraded bogus 2>&1); rc=$?
assert_eq       "I2 an unknown sub-verb is refused with the usage"  "$(( rc != 0 )):$(grep -c 'enter \[--force\]' <<<"$out")" "1:1"

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact): a
# dropped or added assertion is a FAIL, never a quieter green.
#   A 8 | B 6 | C 8 | D 11 (or 1 skip) | E 17 | L 5 | F 7 | M 24 | G 1 + (2 + one per surface) | H 5 | I 2
EXPECTED=$(( 8 + 6 + 8 + _D_RAN + 17 + 5 + 7 + 24 + 1 + _G_RAN + 5 + 2 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
