#!/usr/bin/env bash
# monitor/watcher/test-longjob-plugin-arming.sh — the launch-path arming of the
# longjob-watch dispatcher is FAIL-OPEN BY CONSTRUCTION (your-org/nexus-code#1535).
#
# `monitor/_longjob-plugin.sh:longjob_plugin_flag` decides, for every launch
# surface, whether `--plugin-dir <dir>` is spliced into the `claude` command
# line. This suite drives it against a STUB claude whose `--help` and
# `plugin validate` answers are set per case, and asserts that every reason
# not to arm yields (a) an EMPTY flag, never a partial one, (b) rc 1 with a
# stderr line that names the reason, and (c) a row in arming.log — while the
# one good case yields the flag, rc 0, and an `armed` row. It then asserts the
# shipped manifest validates under the REAL binary when one is resolvable.
#
# POTENCY CONTROL: the good case is the control that proves the stub, the
# helper and the assertion are wired — every negative case below reuses the
# same stub with one axis varied (help text, validate rc, validate hang,
# manifest presence, the kill switch), so a "no flag" that came from a broken
# rig rather than from the gate under test would fail the control first.
#
# Also pinned here: the three launcher composers splice the flag (spawn-worker
# fresh + resume + loop-wrapper, claude-loop.sh's own args, _respawn's
# launcher) — by grepping each for the `PLUGIN_ARG`/`plugin_flag`/`PLUGIN_DIR`
# token at the `claude` invocation, so the wiring cannot silently drop out of
# one surface while the other four keep it.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
WORK=$(mktemp -d -t lj-arm-XXXXXX); trap 'rm -rf "$WORK"' EXIT

# A code root with the helper, a manifest, and a stub claude.
ROOT="$WORK/root"; mkdir -p "$ROOT/monitor/longjob-plugin/.claude-plugin" "$ROOT/config" "$ROOT/monitor/.state"
cp "$REPO_ROOT/monitor/_longjob-plugin.sh" "$ROOT/monitor/"
cp "$REPO_ROOT/monitor/_claude-bin.sh" "$ROOT/monitor/"
cp "$REPO_ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json" "$ROOT/monitor/longjob-plugin/.claude-plugin/"
STUB="$WORK/claude-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
# LJ_HELP: "full" (advertises --plugin-dir <path>), "old" (no such flag), "hang", "empty",
#          "partial134" (a partial usage line, then exit 134: an INCOMPLETE answer)
# LJ_VALIDATE_RC: exit code for `plugin validate`; "hang" sleeps
case "${1:-}" in
  --help)
    [[ -n "${LJ_HELP_LOG:-}" ]] && echo help >> "$LJ_HELP_LOG"
    case "${LJ_HELP:-full}" in
      full) printf 'Usage: claude [options]\n  --name <name>   Set a display name\n  --plugin-dir <path>   Load a plugin from a directory\n' ;;
      old)  printf 'Usage: claude [options]\n  --name <name>   Set a display name\n' ;;
      hang) sleep 60 ;;
      empty) : ;;
      partial134) printf 'Usage: claude [options]\n'; exit 134 ;;
    esac; exit 0 ;;
  plugin)
    [[ "${2:-}" == validate ]] || exit 2
    [[ -n "${LJ_VALIDATE_LOG:-}" ]] && echo validate >> "$LJ_VALIDATE_LOG"
    [[ "${LJ_VALIDATE_RC:-0}" == hang ]] && sleep 60
    exit "${LJ_VALIDATE_RC:-0}" ;;
  --version) echo "0.0.0-stub"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUB"
# This stub's --help varies by ENVIRONMENT at one fixed path, which is exactly
# the bet the #1721 disk cache does not make. The cases above the #1721 section
# vary LJ_HELP per case, so the disk cache is OFF for them (the EMPTY string
# disables it; `${VAR+set}`); that section names its own directories.
export NEXUS_CLAUDE_HELP_CACHE_DIR=""
# Same for the validate-pass cache (#1704): its own section names directories.
export NEXUS_LONGJOB_VALIDATE_CACHE_DIR=""

# run_case <name> → prints "rc|flag|stderr|logrow"
run_case() {
    local name="$1" out err rc row
    mkdir -p "$ROOT/monitor/.state/longjob"; : > "$ROOT/monitor/.state/longjob/arming.log"
    out=$(bash -c '
        set -uo pipefail
        export NEXUS_ROOT="$1" NEXUS_STATE_DIR="$1/monitor/.state" CLAUDE_BIN="$2" NEXUS_CLAUDE_HELP_TIMEOUT=2 NEXUS_LONGJOB_VALIDATE_TIMEOUT=2
        . "$1/monitor/_claude-bin.sh" >/dev/null 2>&1
        . "$1/monitor/_longjob-plugin.sh"
        longjob_plugin_flag "'"$name"'"; rc=$?
        printf "\n__RC__=%s\n" "$rc"' _ "$ROOT" "$STUB" 2>"$WORK/err.$name")
    rc=$(sed -n 's/^__RC__=//p' <<<"$out"); out=$(sed '/^__RC__=/d' <<<"$out" | tr -d '\n')
    err=$(tr '\n' ' ' < "$WORK/err.$name")
    row=$(tail -n1 "$ROOT/monitor/.state/longjob/arming.log" 2>/dev/null | cut -f3-)
    printf '%s|%s|%s|%s' "$rc" "$out" "$err" "$row"
}

echo "=== control: everything in order → the flag, rc 0, an armed row ==="
r=$(LJ_HELP=full LJ_VALIDATE_RC=0 run_case good)
rc="${r%%|*}"; rest="${r#*|}"; flag="${rest%%|*}"; rest="${rest#*|}"; err="${rest%%|*}"; row="${rest#*|}"
(( rc == 0 )) && [[ "$flag" == "--plugin-dir $ROOT/monitor/longjob-plugin" ]] && ok "control: rc 0 and the exact flag ($flag)" || bad "control: rc=$rc flag='$flag' err='$err'"
# EXACT token, not `armed*`: `armed-unprobed` (#1611) shares the prefix, so a
# prefix match here would pass a control that had silently become unprobed.
[[ "${row%%$'\t'*}" == armed ]] && ok "control: arming.log row 'armed' (exact token)" || bad "control row: '$row'"
[[ -z "$err" ]] && ok "control: nothing on stderr" || bad "control stderr: $err"

neg() {   # <name> <expect-reason-substr> <expect-stderr-substr>
    local r rc flag err row
    r=$(run_case "$1"); rc="${r%%|*}"; rest="${r#*|}"; flag="${rest%%|*}"; rest="${rest#*|}"; err="${rest%%|*}"; row="${rest#*|}"
    (( rc == 1 )) && [[ -z "$flag" ]] && ok "$1: rc 1 and an EMPTY flag (never partial)" || bad "$1: rc=$rc flag='$flag'"
    [[ "$row" == skipped*"$2"* ]] && ok "$1: arming.log row 'skipped … $2'" || bad "$1 row: '$row'"
    [[ "$err" == *"$3"* ]] && ok "$1: stderr names the reason" || bad "$1 stderr: '$err'"
}
echo "=== kill switch ==="
MONITOR_LONGJOB_ENABLED=false neg killswitch "disabled" "DISABLED"
# unprobed <name> <expect-reason-substr> <expect-stderr-substr> — a probe that
# could NOT answer ARMS, logged `armed-unprobed` (your-org/nexus-code#1611).
# Before #1611 each of these cases was a `skipped` row and an EMPTY flag: the
# mass-resurrection failure, where every slow --help became a session with no
# longjob-watch dispatcher for its whole life.
unprobed() {
    local r rc flag err row tok
    r=$(run_case "$1"); rc="${r%%|*}"; rest="${r#*|}"; flag="${rest%%|*}"; rest="${rest#*|}"; err="${rest%%|*}"; row="${rest#*|}"
    tok="${row%%$'\t'*}"
    (( rc == 0 )) && [[ "$flag" == "--plugin-dir $ROOT/monitor/longjob-plugin" ]] && ok "$1: could-not-determine ARMS — rc 0 and the exact flag" || bad "$1: rc=$rc flag='$flag' err='$err'"
    [[ "$tok" == armed-unprobed && "$row" == *"$2"* ]] && ok "$1: arming.log row 'armed-unprobed … $2'" || bad "$1 row: '$row'"
    [[ "$err" == *"$3"* ]] && ok "$1: stderr names the reason" || bad "$1 stderr: '$err'"
}
echo "=== binary without --plugin-dir (a COMPLETED probe that said no) ==="
LJ_HELP=old neg oldbinary "was read and does not list --plugin-dir" "does not support '--plugin-dir'"
echo "=== --help hangs (bounded probe) → UNKNOWN, arms unprobed (#1611) ==="
LJ_HELP=hang unprobed helphang "--help probe TIMED OUT (rc 124" "UNKNOWN, not 'unsupported'"
echo "=== --help prints nothing → UNKNOWN, arms unprobed (#1611) ==="
LJ_HELP=empty unprobed helpempty "--help did not complete (empty" "UNKNOWN, not 'unsupported'"
echo "=== validate fails ==="
LJ_HELP=full LJ_VALIDATE_RC=1 neg badmanifest "validate failed rc=1" "FAILED (rc 1)"
echo "=== --help hangs BUT validate RAN and FAILED → skipped: a completed negative outranks an unknown ==="
LJ_HELP=hang LJ_VALIDATE_RC=1 neg hang-then-badmanifest "validate failed rc=1" "FAILED (rc 1)"
echo "=== validate hangs (bounded; a timeout is not a pass, and not a fail) → arms unprobed (#1611) ==="
LJ_HELP=full LJ_VALIDATE_RC=hang unprobed validatehang "plugin validate TIMED OUT (rc 124)" "TIMED OUT"
echo "=== the probe itself: three-valued, and UNKNOWN is never cached (#1611) ==="
# One shell, two asks: the first while --help hangs, the second after it
# recovers. Pre-#1611 the first CACHED `no`, so the second returned 1 without
# re-probing — the transient timeout made permanent for that launcher.
r=$(bash -c '
    export NEXUS_ROOT="$1" CLAUDE_BIN="$2" NEXUS_CLAUDE_HELP_TIMEOUT=1
    . "$1/monitor/_claude-bin.sh" >/dev/null 2>&1
    export LJ_HELP=hang; claude_supports_plugin_dir_flag 2>/dev/null; a=$?
    export LJ_HELP=full; claude_supports_plugin_dir_flag 2>/dev/null; b=$?
    export LJ_HELP=old;  claude_supports_plugin_dir_flag 2>/dev/null; c=$?
    printf "%s,%s,%s" "$a" "$b" "$c"' _ "$ROOT" "$STUB")
[[ "$r" == "2,0,0" ]] && ok "probe: hang→2 (unknown, uncached), recovered→0 (re-probed), then 0 (a COMPLETED yes IS cached)" || bad "probe sequence: got '$r' (want 2,0,0)"
r=$(bash -c '
    export NEXUS_ROOT="$1" CLAUDE_BIN="$2" NEXUS_CLAUDE_HELP_TIMEOUT=1
    . "$1/monitor/_claude-bin.sh" >/dev/null 2>&1
    export LJ_HELP=old;  claude_supports_plugin_dir_flag 2>/dev/null; a=$?
    export LJ_HELP=full; claude_supports_plugin_dir_flag 2>/dev/null; b=$?
    printf "%s,%s" "$a" "$b"' _ "$ROOT" "$STUB")
[[ "$r" == "1,1" ]] && ok "probe: a COMPLETED no → 1 and IS cached (1,1) — only the unknown escapes the cache" || bad "probe completed-no: got '$r' (want 1,1)"
echo "=== ONE --help per process for both flags; a disk cache of COMPLETED answers (#1721) ==="
# A separate stub path, so the binary-change cases below cannot touch $STUB.
# LJ_HELP is the lever that makes a cache hit OBSERVABLE: a stub that would now
# answer `old` (--name, no --plugin-dir) still yields the cached `full` answers, with
# ZERO --help invocations counted in LJ_HELP_LOG.
HSTUB="$WORK/claude-hc-stub"; cp "$STUB" "$HSTUB"; chmod +x "$HSTUB"
HLOG="$WORK/hc-help.log"
# hc_run <cache-dir|-unset-> <LJ_HELP> [fence|-] -> "name_rc,plugin_rc,help_invocations"
hc_run() {
    : > "$HLOG"
    local r
    r=$(LJ_HELP="$2" LJ_HELP_LOG="$HLOG" bash -c '
        export NEXUS_ROOT="$1" NEXUS_STATE_DIR="$1/monitor/.state" CLAUDE_BIN="$2" NEXUS_CLAUDE_HELP_TIMEOUT=1
        if [[ "$3" == -unset- ]]; then unset NEXUS_CLAUDE_HELP_CACHE_DIR; else export NEXUS_CLAUDE_HELP_CACHE_DIR="$3"; fi
        if [[ "$4" == - ]]; then unset NEXUS_TEST_FENCE; else export NEXUS_TEST_FENCE="$4"; fi
        . "$1/monitor/_claude-bin.sh" >/dev/null 2>&1
        claude_supports_name_flag 2>/dev/null; a=$?
        claude_supports_plugin_dir_flag 2>/dev/null; b=$?
        printf "%s,%s" "$a" "$b"' _ "$ROOT" "$HSTUB" "$1" "${3:--}")
    printf '%s,%s' "$r" "$(( $(wc -l < "$HLOG") ))"
}
hc_entries() { find "$1" -maxdepth 1 -type f -name 'claude-help-*.v1' 2>/dev/null | wc -l | tr -d ' '; }
hc_strays()  { find "$1" -maxdepth 1 -type f -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' '; }

r=$(hc_run "" full)
[[ "$r" == "0,0,1" ]] && ok "C1 one process asks both flags → ONE --help (0,0,1)" || bad "C1 one --help per process: got '$r' (want 0,0,1 — base runs --help once per flag)"

HC="$WORK/hc"; mkdir -p "$HC"
r=$(hc_run "$HC" full)
[[ "$r" == "0,0,1" && "$(hc_entries "$HC")" == 1 && "$(hc_strays "$HC")" == 0 ]] \
    && ok "C2a cold cache: one --help, ONE entry written, no tmp left behind" \
    || bad "C2a cold cache: got '$r', entries=$(hc_entries "$HC"), strays=$(hc_strays "$HC")"
r=$(hc_run "$HC" old)
[[ "$r" == "0,0,0" ]] && ok "C2b warm cache, a SECOND process: ZERO --help, the cached answers (0,0,0)" || bad "C2b warm cache: got '$r' (want 0,0,0)"

printf '# changed binary (#1721 fixture)\n' >> "$HSTUB"
r=$(hc_run "$HC" old)
[[ "$r" == "0,1,1" ]] && ok "C3a size+mtime change invalidates: re-probed, the NEW binary's --plugin-dir no (0,1,1)" || bad "C3a changed binary: got '$r' (want 0,1,1)"
r=$(hc_run "$HC" full)
[[ "$r" == "0,1,0" ]] && ok "C3b …and the new binary's answer is itself cached (0,1,0)" || bad "C3b re-cached: got '$r' (want 0,1,0)"
touch -d '2001-02-03 04:05:06' "$HSTUB"
r=$(hc_run "$HC" full)
[[ "$r" == "0,0,1" ]] && ok "C3c an mtime-ONLY change (same size) invalidates too (0,0,1)" || bad "C3c mtime-only change: got '$r' (want 0,0,1)"

HC2="$WORK/hc2"; mkdir -p "$HC2"
r=$(hc_run "$HC2" hang)
[[ "$r" == "0,2,2" && "$(hc_entries "$HC2")" == 0 && "$(hc_strays "$HC2")" == 0 ]] \
    && ok "C4a a TIMED-OUT probe writes NO entry, and the UNKNOWN is not shared within the process either (#1611: 0,2,2)" \
    || bad "C4a timeout: got '$r', entries=$(hc_entries "$HC2") (want 0,2,2 and no entry)"
r=$(hc_run "$HC2" full)
[[ "$r" == "0,0,1" && "$(hc_entries "$HC2")" == 1 ]] && ok "C4b …so the next process re-probes and caches the COMPLETED answer (0,0,1)" || bad "C4b after timeout: got '$r'"
r=$(hc_run "$HC2" empty)
[[ "$r" == "0,0,0" ]] && ok "C4c (control) the cache is what answered C4b's successor: an EMPTY --help is never even run (0,0,0)" || bad "C4c: got '$r'"

f=$(find "$HC2" -maxdepth 1 -type f -name 'claude-help-*.v1' -print -quit)
for bad_body in 'garbage' "$(head -n1 "$f")"$'\n''maybe yes' "$(head -n1 "$f")"$'\n''yes yes'$'\n''extra' 'some other key'$'\n''yes yes'; do
    printf '%s\n' "$bad_body" > "$f"
    r=$(hc_run "$HC2" old)
    [[ "$r" == "0,1,1" ]] && ok "C5 malformed/foreign entry ($(head -c 18 <<<"$bad_body" | tr '\n' '|')…) → ignored, re-probed (0,1,1)" || bad "C5 malformed entry: got '$r' (want 0,1,1)"
done
[[ "$(wc -l < "$f")" -eq 2 && "$(sed -n 2p "$f")" == "yes no" ]] && ok "C5 …and the re-probe rewrote it as a valid two-line entry" || bad "C5 rewrite: [$(cat "$f")]"

rm -rf "$ROOT/monitor/.state/claude-help-cache"
r=$(hc_run -unset- full "$WORK")
[[ "$r" == "0,0,1" && ! -e "$ROOT/monitor/.state/claude-help-cache" ]] && ok "C6a under a TEST FENCE the default location is never written" || bad "C6a fenced default: got '$r', dir exists=$([[ -e "$ROOT/monitor/.state/claude-help-cache" ]] && echo yes || echo no)"
# The default location serves ONLY this nexus's pinned binary (fenced at the
# SOURCE, skeptic on #1781): C6b makes the stub the pinned binary, C6c is the
# decoy-gate shape — an unfenced suite whose CLAUDE_BIN is NOT the pinned one.
mkdir -p "$ROOT/node_modules/.bin"; ln -sfn "$HSTUB" "$ROOT/node_modules/.bin/claude"
r=$(hc_run -unset- full -)
[[ "$r" == "0,0,1" && "$(hc_entries "$ROOT/monitor/.state/claude-help-cache")" == 1 ]] && ok "C6b unfenced, CLAUDE_BIN IS the pinned binary: the default is \$NEXUS_STATE_DIR/claude-help-cache" || bad "C6b default location: got '$r', entries=$(hc_entries "$ROOT/monitor/.state/claude-help-cache")"
rm -rf "$ROOT/monitor/.state/claude-help-cache" "$ROOT/node_modules"
r=$(hc_run -unset- full -)
[[ "$r" == "0,0,1" && ! -e "$ROOT/monitor/.state/claude-help-cache" ]] && ok "C6c unfenced, CLAUDE_BIN is NOT the pinned binary: the default location is never written" || bad "C6c stub binary wrote the default cache: got '$r', dir exists=$([[ -e "$ROOT/monitor/.state/claude-help-cache" ]] && echo yes || echo no)"
rm -rf "$ROOT/monitor/.state/claude-help-cache"

# ONLY A COMPLETE, rc-0 --help IS AN ANSWER (#1611; skeptic on #1781): a
# partial usage line followed by exit 134 must not be cached as "no no".
HC7="$WORK/hc7"; mkdir -p "$HC7"
r=$(hc_run "$HC7" partial134)
[[ "$r" == "1,2,2" && "$(hc_entries "$HC7")" == 0 ]] && ok "C7a partial stdout + rc 134: UNKNOWN (name omitted, plugin-dir on the binary's word), not even memoised (2 probes, as C4a), NOTHING cached" || bad "C7a incomplete --help: got '$r', entries=$(hc_entries "$HC7") (want 1,2,2 and 0)"
r=$(hc_run "$HC7" full)
[[ "$r" == "0,0,1" ]] && ok "C7b the next process RE-PROBES and gets the real answer (no inherited 'no')" || bad "C7b after an incomplete probe: got '$r' (want 0,0,1)"

echo "=== a disk cache of PASSED validations: binary + plugin bytes (#1704) ==="
# LJ_VALIDATE_LOG counts real `plugin validate` runs. A cache hit is made
# OBSERVABLE by asking with LJ_VALIDATE_RC=1: a stub that would now FAIL still
# arms, with ZERO validate runs. A separate stub path so binary edits stay local.
VSTUB="$WORK/claude-v-stub"; cp "$STUB" "$VSTUB"; chmod +x "$VSTUB"
VLOG="$WORK/v-validate.log"
# vc_run <cache-dir|-unset-> <LJ_VALIDATE_RC> [fence|-] -> "rc,verdict,validate_runs"
vc_run() {
    : > "$VLOG"; mkdir -p "$ROOT/monitor/.state/longjob"; : > "$ROOT/monitor/.state/longjob/arming.log"
    local rc verdict vto=30
    # Generous bounds so a loaded host cannot turn a real validate into a
    # timeout (a false armed-unprobed); only the `hang` case needs the short one.
    [[ "$2" == hang ]] && vto=1
    LJ_HELP=full LJ_VALIDATE_RC="$2" LJ_VALIDATE_LOG="$VLOG" bash -c '
        export NEXUS_ROOT="$1" NEXUS_STATE_DIR="$1/monitor/.state" CLAUDE_BIN="$2" NEXUS_CLAUDE_HELP_TIMEOUT=30 NEXUS_LONGJOB_VALIDATE_TIMEOUT="$5"
        if [[ "$3" == -unset- ]]; then unset NEXUS_LONGJOB_VALIDATE_CACHE_DIR; else export NEXUS_LONGJOB_VALIDATE_CACHE_DIR="$3"; fi
        if [[ "$4" == - ]]; then unset NEXUS_TEST_FENCE; else export NEXUS_TEST_FENCE="$4"; fi
        . "$1/monitor/_claude-bin.sh" >/dev/null 2>&1
        . "$1/monitor/_longjob-plugin.sh"
        longjob_plugin_flag vc >/dev/null 2>&1' _ "$ROOT" "$VSTUB" "$1" "${3:--}" "$vto"
    rc=$?
    verdict=$(tail -n1 "$ROOT/monitor/.state/longjob/arming.log" | cut -f3)
    printf '%s,%s,%s' "$rc" "$verdict" "$(( $(wc -l < "$VLOG") ))"
}
vc_entries() { find "$1" -maxdepth 1 -type f -name 'longjob-validate-*.v1' 2>/dev/null | wc -l | tr -d ' '; }
vc_strays()  { find "$1" -maxdepth 1 -type f -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' '; }
VC="$WORK/vc"; mkdir -p "$VC"
r=$(vc_run "$VC" 0)
[[ "$r" == "0,armed,1" && "$(vc_entries "$VC")" == 1 && "$(vc_strays "$VC")" == 0 ]] \
    && ok "V1 cold cache: ONE validate, armed, ONE entry written, no tmp left" \
    || bad "V1 cold: got '$r', entries=$(vc_entries "$VC"), strays=$(vc_strays "$VC")"
r=$(vc_run "$VC" 1)
[[ "$r" == "0,armed,0" ]] && ok "V2 warm cache: ZERO validate runs — the cached pass answered (a stub that would FAIL still arms)" || bad "V2 warm cache: got '$r' (want 0,armed,0)"
r=$(vc_run "" 1)
[[ "$r" == "1,skipped,1" ]] && ok "V2c (control) the same stub with the cache DISABLED validates and fails — V2's arm came from the cache" || bad "V2c control: got '$r' (want 1,skipped,1)"
MAN="$ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json"; cp "$MAN" "$WORK/man.orig"
printf ' \n' >> "$MAN"
r=$(vc_run "$VC" 1)
[[ "$r" == "1,skipped,1" ]] && ok "V3a a manifest edit invalidates: re-validated (and the new FAIL is honoured)" || bad "V3a manifest change: got '$r' (want 1,skipped,1)"
r=$(vc_run "$VC" 0); r2=$(vc_run "$VC" 1)
[[ "$r" == "0,armed,1" && "$r2" == "0,armed,0" ]] && ok "V3b …the edited manifest's pass is itself cached" || bad "V3b: got '$r' then '$r2'"
cp "$WORK/man.orig" "$MAN"
printf '#!/usr/bin/env bash\n' > "$ROOT/monitor/longjob-plugin/dispatch.sh"
r=$(vc_run "$VC" 1)
[[ "$r" == "1,skipped,1" ]] && ok "V3c a NEW/changed file elsewhere in the plugin dir invalidates too" || bad "V3c plugin-dir change: got '$r' (want 1,skipped,1)"
rm -f "$ROOT/monitor/longjob-plugin/dispatch.sh"
r=$(vc_run "$VC" 1)
[[ "$r" == "0,armed,0" ]] && ok "V3d restoring the original bytes hits the original entry again (the key IS the content)" || bad "V3d: got '$r' (want 0,armed,0)"
printf '# changed binary (#1704 fixture)\n' >> "$VSTUB"
r=$(vc_run "$VC" 1)
[[ "$r" == "1,skipped,1" ]] && ok "V4 a binary change (size+mtime) invalidates: re-validated" || bad "V4 binary change: got '$r' (want 1,skipped,1)"
VC2="$WORK/vc2"; mkdir -p "$VC2"
r=$(vc_run "$VC2" hang)
[[ "$r" == "0,armed-unprobed,1" && "$(vc_entries "$VC2")" == 0 && "$(vc_strays "$VC2")" == 0 ]] \
    && ok "V5a a TIMED-OUT validate arms unprobed and writes NO entry (#1611)" \
    || bad "V5a timeout: got '$r', entries=$(vc_entries "$VC2")"
r=$(vc_run "$VC2" 0)
[[ "$r" == "0,armed,1" && "$(vc_entries "$VC2")" == 1 ]] && ok "V5b …so the next launch RE-validates (1 run) and only then caches" || bad "V5b after timeout: got '$r'"
VC3="$WORK/vc3"; mkdir -p "$VC3"
r=$(vc_run "$VC3" 1); r2=$(vc_run "$VC3" 1)
[[ "$r" == "1,skipped,1" && "$r2" == "1,skipped,1" && "$(vc_entries "$VC3")" == 0 ]] && ok "V6 a FAILED validate is never cached: two launches, two validates, two skips, no entry" || bad "V6 failure cached? got '$r' then '$r2', entries=$(vc_entries "$VC3")"
VC4="$WORK/vc4"; mkdir -p "$VC4"
r=$(vc_run "$VC4" 0)
vf=$(find "$VC4" -maxdepth 1 -type f -name 'longjob-validate-*.v1' -print -quit)
vkey=$(head -n1 "$vf")
[[ "$r" == "0,armed,1" && -n "$vkey" ]] || bad "V7 setup: got '$r', entry='$vf'"
for vbad in 'garbage' "$vkey"$'\n''maybe' "$vkey"$'\n''ok'$'\n''extra' 'some other key'$'\n''ok'; do
    printf '%s\n' "$vbad" > "$vf"
    r=$(vc_run "$VC4" 1)
    [[ "$r" == "1,skipped,1" ]] && ok "V7 malformed/foreign entry for the CURRENT key ($(head -c 12 <<<"$vbad" | tr '\n' '|')…) → ignored, re-validated" || bad "V7 malformed entry: got '$r' (want 1,skipped,1)"
done
rm -rf "$ROOT/monitor/.state/longjob-validate-cache"
r=$(vc_run -unset- 0 "$WORK")
[[ "$r" == "0,armed,1" && ! -e "$ROOT/monitor/.state/longjob-validate-cache" ]] && ok "V8a under a TEST FENCE the default location is never written" || bad "V8a fenced default: got '$r'"
mkdir -p "$ROOT/node_modules/.bin"; ln -sfn "$VSTUB" "$ROOT/node_modules/.bin/claude"
r=$(vc_run -unset- 0 -); r2=$(vc_run -unset- 1 -)
[[ "$r" == "0,armed,1" && "$r2" == "0,armed,0" && "$(vc_entries "$ROOT/monitor/.state/longjob-validate-cache")" == 1 ]] && ok "V8b unfenced, CLAUDE_BIN IS the pinned binary: cached at \$NEXUS_STATE_DIR/longjob-validate-cache (the #1721 location scheme)" || bad "V8b default location: got '$r' then '$r2'"
rm -rf "$ROOT/monitor/.state/longjob-validate-cache" "$ROOT/node_modules"
r=$(vc_run -unset- 0 -)
[[ "$r" == "0,armed,1" && ! -e "$ROOT/monitor/.state/longjob-validate-cache" ]] && ok "V8c unfenced, a NON-pinned stub: the default location is never written" || bad "V8c: got '$r'"

echo "=== manifest missing ==="
mv "$ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json" "$WORK/plugin.json.bak"
LJ_HELP=full neg nomanifest "manifest unreadable" "manifest missing"
mv "$WORK/plugin.json.bak" "$ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json"
echo "=== CLAUDE_BIN unset ==="
r=$(bash -c 'export NEXUS_ROOT="$1" NEXUS_STATE_DIR="$1/monitor/.state"; unset CLAUDE_BIN; . "$1/monitor/_longjob-plugin.sh"; longjob_plugin_flag w; echo "|rc=$?"' _ "$ROOT" 2>&1)
[[ "$r" == *"CLAUDE_BIN unset"*"|rc=1" ]] && ok "no CLAUDE_BIN: rc 1, says so, no flag" || bad "no CLAUDE_BIN: $r"

echo "=== the row lands in the CALLER's state dir, never the inherited NEXUS_ROOT (bundle-2609 soak) ==="
# Measured on the operator's live primary, 2026-09-16: 17 `skipped … does not
# advertise` rows for `orchestrator` and `mission-control` that no launch
# wrote — suites respawning against a FIXTURE root while the helper resolved
# its log from the agent shell's inherited NEXUS_ROOT. Pre-fix every case
# below lands its row in the DECOY (measured before the second argument
# existed); the bare-call case is the documented fallback and stays so.
DECOY="$WORK/decoy"; mkdir -p "$DECOY/monitor/.state"
_decoy_case() {   # <window> <state-dir-arg or ''> <NEXUS_TEST_SUITE or ''> → "rc|verdict-in-ROOT|decoy-rows|src"
    mkdir -p "$ROOT/monitor/.state/longjob"; : > "$ROOT/monitor/.state/longjob/arming.log"
    rm -rf "$DECOY/monitor/.state/longjob"
    LJ_HELP=old bash -c '
        set -uo pipefail
        export NEXUS_ROOT="$3" CLAUDE_BIN="$2" NEXUS_CLAUDE_HELP_TIMEOUT=2; unset NEXUS_STATE_DIR
        if [[ -n "$6" ]]; then export NEXUS_TEST_SUITE="$6"; else unset NEXUS_TEST_SUITE; fi
        . "$1/monitor/_claude-bin.sh" >/dev/null 2>&1
        . "$1/monitor/_longjob-plugin.sh"
        if [[ -n "$5" ]]; then longjob_plugin_flag "$4" "$5"; else longjob_plugin_flag "$4"; fi' \
        _ "$ROOT" "$STUB" "$DECOY" "$1" "$2" "$3" >/dev/null 2>&1
    local rc=$? verdict='' drows=0 src='-'
    verdict=$(tail -n1 "$ROOT/monitor/.state/longjob/arming.log" 2>/dev/null | cut -f3)
    [[ -f "$DECOY/monitor/.state/longjob/arming.log" ]] && drows=$(wc -l < "$DECOY/monitor/.state/longjob/arming.log")
    [[ -n "$verdict" ]] && src=$(tail -n1 "$ROOT/monitor/.state/longjob/arming.log" | cut -f5)
    printf '%s|%s|%s|%s' "$rc" "$verdict" "$((drows))" "$src"
}
r=$(_decoy_case w "$ROOT/monitor/.state" watcher/test-zz-fixture.sh)
[[ "$r" == "1|skipped|0|watcher/test-zz-fixture.sh" ]] && ok "caller's state dir wins over an inherited NEXUS_ROOT: row in the fixture, NOTHING in the decoy, src = the suite" || bad "caller state dir: got '$r' (want 1|skipped|0|watcher/test-zz-fixture.sh)"
r=$(_decoy_case w "$ROOT/monitor/.state" '')
[[ "$r" == "1|skipped|0|" ]] && ok "outside run-tests.sh the src column is EMPTY (a real launch's row)" || bad "empty src: got '$r'"
r=$(_decoy_case w '' '')
[[ "$r" == "1||1|-" ]] && ok "bare call (no state dir, no NEXUS_STATE_DIR) falls back to the inherited NEXUS_ROOT — the documented production chain, unchanged" || bad "bare call: got '$r' (want 1||1|-)"
grep -qF 'longjob_plugin_flag "$target_window" "${NEXUS_STATE_DIR:-$nexus_root/monitor/.state}"' "$REPO_ROOT/monitor/watcher/_respawn.sh" && ok "_respawn.sh passes the state dir it resolved" || bad "_respawn.sh: the plugin call does not pass its state dir"
grep -qF 'longjob_plugin_flag "$w" "$STATE_DIR"' "$REPO_ROOT/monitor/spawn-worker.sh" && ok "spawn-worker.sh passes its resolved STATE_DIR" || bad "spawn-worker.sh: the plugin call does not pass STATE_DIR"

echo "=== the shipped manifest validates under the real binary (when resolvable) ==="
REAL=$(bash -c "cd '$REPO_ROOT' && . monitor/_claude-bin.sh >/dev/null 2>&1; echo \"\$CLAUDE_BIN\"" 2>/dev/null)
if [[ -n "$REAL" && -x "$REAL" ]]; then
    timeout 60 "$REAL" plugin validate "$REPO_ROOT/monitor/longjob-plugin" >"$WORK/v.out" 2>&1; rc=$?
    (( rc == 0 )) && ok "real 'claude plugin validate monitor/longjob-plugin' → rc 0" || bad "real validate rc=$rc: $(cat "$WORK/v.out")"
    grep -q 'experimental' "$REPO_ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json" && ok "manifest declares experimental.monitors (the supported form; top-level is announced for removal)" || bad "manifest not under experimental"
else
    printf '  SKIP: no real claude resolvable; the shipped-manifest check is unmeasured here\n'
fi
jq -e '.experimental.monitors | length == 1 and .[0].command != "" and .[0].when == "always"' "$REPO_ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json" >/dev/null && ok "manifest: exactly one monitor, a command, when=always" || bad "manifest shape"
[[ -x "$REPO_ROOT/monitor/longjob-plugin/dispatch.sh" ]] && grep -q 'longjob-watch.sh" dispatch' "$REPO_ROOT/monitor/longjob-plugin/dispatch.sh" && ok "dispatch.sh execs longjob-watch.sh dispatch" || bad "dispatch.sh"

echo "=== every launch surface splices the flag ==="
sw="$REPO_ROOT/monitor/spawn-worker.sh"
n=$(grep -o 'PLUGIN_ARG:+ \$PLUGIN_ARG' "$sw" | wc -l); (( n == 3 )) && ok "spawn-worker.sh: 3 launcher lines carry \${PLUGIN_ARG:+ …} (fresh, resume, loop)" || bad "spawn-worker.sh PLUGIN_ARG splice count $n (want 3)"
# Since the Codex harness (#1640/#1642) the FRESH-path computation sits in the
# claude arm of an `if [ "$HARNESS" = codex ]` whose codex arm sets PLUGIN_ARG
# EMPTY on purpose (the dispatcher is a Claude Code plugin monitor; Codex has no
# equivalent wake). Reviewed for #1643: assert both computations AND the explicit
# empty codex arm, rather than loosening the anchor to any indentation.
n=$(grep -c '^ *PLUGIN_ARG=\$(_spawn_plugin_arg "\$WINDOW_NAME")$' "$sw")
(( n == 2 )) && ok "spawn-worker.sh: PLUGIN_ARG computed on both the fresh and the resume path (2 sites)" || bad "spawn-worker.sh PLUGIN_ARG assignment count $n (want 2)"
grep -q '^    PLUGIN_ARG=""$' <<<"$(grep -A4 '^if \[ "\$HARNESS" = codex \]; then$' "$sw")" \
    && ok "spawn-worker.sh: the codex fresh arm sets PLUGIN_ARG EMPTY explicitly (no plugin monitor for Codex)" \
    || bad "spawn-worker.sh: codex fresh arm does not set PLUGIN_ARG=\"\" explicitly"
grep -q -- '--plugin-dir)          PLUGIN_DIR=' "$REPO_ROOT/monitor/claude-loop.sh" && grep -q 'args+=( --plugin-dir "\$PLUGIN_DIR" )' "$REPO_ROOT/monitor/claude-loop.sh" && ok "claude-loop.sh parses --plugin-dir and re-passes it on every (re)invocation" || bad "claude-loop.sh plugin-dir"
grep -q '\${name_flag}\${plugin_flag}\$continue_flag' "$REPO_ROOT/monitor/watcher/_respawn.sh" && ok "_respawn.sh: the orchestrator launcher carries \${plugin_flag}" || bad "_respawn.sh splice"
# The loop wrapper must ACCEPT the flag the spawner passes: an unknown arg is fatal there.
out=$(bash "$REPO_ROOT/monitor/claude-loop.sh" --window w --prompt-file /dev/null --plugin-dir /x --no-such-flag 2>&1); rc=$?
[[ "$out" == *"unknown arg: --no-such-flag"* ]] && ok "claude-loop.sh: --plugin-dir accepted (the NEXT unknown flag is what it rejects)" || bad "claude-loop.sh arg parse: $out"

echo; echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }; exit 1
