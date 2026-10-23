#!/usr/bin/env bash
# probe-instruction-files.sh — which tool reads make a real `claude` load a
# NESTED instruction file (CLAUDE.md, AGENTS.md, .claude/rules) as PROJECT
# INSTRUCTIONS, and does the `claudeMdExcludes` the nexus writes suppress it
# (your-org/nexus-code#1779, #1671).
#
# WHY. A repo cloned under work/ is foreign content. Claude Code 2.1.293 loads
# its CLAUDE.md when an agent reads a file below it with a single-file
# cat/head/tail/sed -n/grep in Bash, not only with Read, and the nexus guards
# that with `claudeMdExcludes` (monitor/resolve-settings.sh --nexus-root). Both
# halves are the HARNESS's behaviour, so a release can move either. This probe
# is the re-measurement `skills/nexus.cc-update/GUIDE.md` 2d asks for.
#
# HOW. Each arm boots a FRESH worker (an instruction file, once loaded, stays
# loaded) against the mock with MOCK_DUMP_BODIES=1, drives ONE tool call whose
# PreToolUse hook flips the mock back to text, and counts unique canary
# strings in the request bodies sent after the arm started. The canaries live
# only in the instruction files, never in the file that is read, the command
# or the prompt. Every arm checks the root canary too: a root CLAUDE.md that
# stopped loading would make every "no" meaningless.
#
# Usage: CLAUDE_BIN=<claude> bash monitor/cc-harness/probe-instruction-files.sh
#        (defaults to the repo's pinned node_modules/.bin/claude)
# Exit:  0 every arm matched its expectation; 1 a mismatch (the table names
#        it); 2 setup failed. ~40 s per arm, 17 arms.
#
# Measured 2026-10-08 on 2.1.293: every arm matched (#1779). On a mismatch,
# re-read the arm before the guard: `tool_ran=0` means the arm never reached
# its tool call, which is a rig failure, not a "no".

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/_lib.sh"
export MOCK_DUMP_BODIES=1
cch_setup || exit 2
trap cch_teardown EXIT
P="$CCH_WORKDIR"
BODIES="$CCH_DIR/bodies.log"; : > "$BODIES"
MARK="$CCH_DIR/marks"; mkdir -p "$MARK"
echo "claude: $("$CLAUDE_BIN" --version 2>/dev/null || echo '?')"

# <rootkind> = claude | agents: the launch-time root file of the fixture.
plant() {
    rm -rf "${P:?}"/* "$P"/.claude 2>/dev/null
    mkdir -p "$P/sub" "$P/deep/a/b" "$P/agt" "$P/rul/.claude/rules"
    if [ "$1" = claude ]; then
        echo "root instructions CANARY_ROOTC_7731" > "$P/CLAUDE.md"
    else
        echo "root agents CANARY_ROOTA_7732" > "$P/AGENTS.md"
    fi
    echo "nested claude CANARY_NESTC_4410" > "$P/sub/CLAUDE.md"
    echo "deep claude CANARY_DEEPC_8820"   > "$P/deep/CLAUDE.md"
    echo "nested agents CANARY_NESTA_5521" > "$P/agt/AGENTS.md"
    printf 'plain rule CANARY_RULEU_9901\n' > "$P/rul/.claude/rules/r1.md"
    printf -- '---\npaths:\n  - "**/*.txt"\n---\nscoped rule CANARY_RULEP_9902\n' > "$P/rul/.claude/rules/r2.md"
    local d; for d in sub deep/a/b agt rul; do printf 'filebody one\nfilebody x two\n' > "$P/$d/f.txt"; done
    # A nexus-code-like clone under work/: its own repo, its own CLAUDE.md.
    # The repo is built by hand, not with a git verb: this directory is a
    # cc-update surface, where test-cc-update-no-remote-code denies every
    # non-read-only `git <verb>`. HEAD + objects/ + refs/ is what git itself
    # accepts as a repository.
    mkdir -p "$P/work/clone/.git/objects" "$P/work/clone/.git/refs/heads"
    printf 'ref: refs/heads/main\n' > "$P/work/clone/.git/HEAD"
    echo "clone contract CANARY_CLONEC_3301" > "$P/work/clone/CLAUDE.md"
    # User memory (~/.claude/CLAUDE.md): must load whatever the excludes say.
    echo "user memory CANARY_USERC_1201" > "$CCH_CFG/CLAUDE.md"
}
# Launch a worker in <dir> instead of the fixture root: seed folder trust for
# it (a nested git repo does not inherit trust, cc 2.1.232).
trust() {
    local t; t=$(mktemp "$CCH_DIR/cfg.XXXX")
    jq --arg wd "$1" '.projects[$wd] = {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true, allowedTools: []}' \
        "$CCH_CFG/.claude.json" > "$t" && mv "$t" "$CCH_CFG/.claude.json"
}

k=0; MISMATCH=0
# arm <label> <excludes-json|null> <tool> <input-json> <root-canary> <canary> <want 0|1>
arm() {
    local label="$1" excl="$2" tool="$3" input="$4" rootc="$5" can="$6" want="$7"
    k=$((k+1))
    local hook="$CCH_DIR/hook$k.sh" set="$CCH_DIR/set$k.json" m="$MARK/m$k"
    printf '#!/bin/bash\ncat > %q\nprintf %q > %q\n' "$m" '{"mode":"text","text":"arm done"}\n' "$CCH_CONTROL" > "$hook"
    chmod +x "$hook"
    jq -n --arg h "$hook" --argjson ex "$excl" \
        '{hooks:{PreToolUse:[{matcher:"*",hooks:[{type:"command",command:$h}]}]}}
         + (if $ex == null then {} else {claudeMdExcludes:$ex} end)' > "$set"
    cch_control '{"mode":"text","text":"ready"}'
    local off; off=$(stat -c %s "$BODIES" 2>/dev/null || echo 0)
    local idx; idx=$(CCH_WORKDIR="${ARM_CWD:-$CCH_WORKDIR}" CCH_SETTINGS="$set" cch_boot_worker "arm$k")
    sleep 8
    cch_control "$(jq -nc --arg t "$tool" --argjson i "$input" '{mode:"tool_use",tool:{name:$t,input:$i}}')"
    local ok=0 attempt i
    for attempt in 1 2; do
        cch_send "$idx" "please run arm $k"
        for i in $(seq 1 90); do
            if [ -s "$m" ] && grep -qF 'tool_result' <<<"$(tail -c +$((off+1)) "$BODIES")"; then ok=1; break 2; fi
            sleep 1
        done
    done
    sleep 4
    local seg rn n got verdict
    seg=$(tail -c +$((off+1)) "$BODIES")
    # rootc "-" = this arm excludes the root file itself: no root control.
    if [ "$rootc" = - ]; then rn=-; else rn=$(grep -o "CANARY_${rootc}_[0-9]*" <<<"$seg" | wc -l); fi
    n=$(grep -o "CANARY_${can}_[0-9]*" <<<"$seg" | wc -l)
    got=0; [ "$n" -gt 0 ] && got=1
    verdict=ok
    if [ "$ok" -ne 1 ] || [ "$rn" = 0 ] || [ "$got" != "$want" ]; then verdict=MISMATCH; MISMATCH=$((MISMATCH+1)); fi
    printf '%-9s %-2s %-46s tool_ran=%s root=%s %s loaded=%s want=%s\n' "$verdict" "$k" "$label" "$ok" "$rn" "$can" "$got" "$want"
    cch_kill_claude "$idx" >/dev/null 2>&1 || true
}
rd() { jq -nc --arg p "$P/$1" '{file_path:$p}'; }

EX='["'"$P"'/*/**/CLAUDE.md","'"$P"'/*/**/AGENTS.md","'"$P"'/*/**/.claude/rules/**"]'
EXA='["'"$P"'/AGENTS.md","'"$P"'/*/**/AGENTS.md"]'

plant claude
arm "echo (negative control)"           null Bash '{"command":"echo hi"}'           ROOTC NESTC 0
arm "Read sub/f.txt (positive control)" null Read "$(rd sub/f.txt)"                  ROOTC NESTC 1
arm "cat sub/f.txt (2.1.293 route)"     null Bash '{"command":"cat sub/f.txt"}'     ROOTC NESTC 1
arm "sed -n 1p sub/f.txt"               null Bash '{"command":"sed -n 1p sub/f.txt"}' ROOTC NESTC 1
arm "cat deep/a/b/f.txt (ancestor)"     null Bash '{"command":"cat deep/a/b/f.txt"}' ROOTC DEEPC 1
arm "cat sub/f.txt | wc -l (pipeline)"  null Bash '{"command":"cat sub/f.txt | wc -l"}' ROOTC NESTC 0
arm "cat rul/f.txt (.claude/rules)"     null Bash '{"command":"cat rul/f.txt"}'     ROOTC RULEU 1
arm "Read agt/f.txt (AGENTS, root CLAUDE)" null Read "$(rd agt/f.txt)"              ROOTC NESTA 0
arm "EXCLUDED cat sub/f.txt"            "$EX" Bash '{"command":"cat sub/f.txt"}'    ROOTC NESTC 0
arm "EXCLUDED Read sub/f.txt"           "$EX" Read "$(rd sub/f.txt)"                 ROOTC NESTC 0
arm "EXCLUDED cat deep/a/b/f.txt"       "$EX" Bash '{"command":"cat deep/a/b/f.txt"}' ROOTC DEEPC 0
arm "EXCLUDED cat rul/f.txt"            "$EX" Bash '{"command":"cat rul/f.txt"}'    ROOTC RULEP 0
# THE PRODUCTION PATTERNS: generated by the resolver the nexus spawns with,
# for this fixture as the nexus root. A worker whose cwd is a clone under
# work/ (every bundle worker in a nexus-code worktree) must still get the
# ROOT CLAUDE.md, must NOT get the clone's own, and keeps user memory.
printf '{}\n' > "$CCH_DIR/base-settings.json"
PROD=$(NEXUS_STATE_DIR="$CCH_DIR/rs-state" bash "$_self_dir/../resolve-settings.sh" --nexus-root "$P" "$CCH_DIR/base-settings.json" 2>/dev/null) \
    && PROD=$(jq -c '.claudeMdExcludes' "$PROD" 2>/dev/null)
[[ "$PROD" == \[* ]] || { echo "setup: resolve-settings.sh --nexus-root produced no claudeMdExcludes" >&2; exit 2; }
trust "$P/work/clone"
ARM_CWD="$P/work/clone" arm "cwd=work/clone: clone CLAUDE.md (no excludes)" null   Bash '{"command":"echo hi"}' ROOTC CLONEC 1
ARM_CWD="$P/work/clone" arm "cwd=work/clone: clone CLAUDE.md PRODUCTION excl" "$PROD" Bash '{"command":"echo hi"}' ROOTC CLONEC 0
ARM_CWD="$P/work/clone" arm "cwd=work/clone: user memory PRODUCTION excl" "$PROD" Bash '{"command":"echo hi"}' ROOTC USERC 1
plant agents
arm "no root CLAUDE: Read agt/f.txt"    null Read "$(rd agt/f.txt)"                  ROOTA NESTA 1
arm "no root CLAUDE: EXCLUDED Read agt" "$EXA" Read "$(rd agt/f.txt)"                -     NESTA 0

echo "arms=$k mismatches=$MISMATCH"
[ "$MISMATCH" -eq 0 ] || exit 1
exit 0
