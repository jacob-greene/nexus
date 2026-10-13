#!/usr/bin/env bash
# Operator-local settings overlay (your-org/nexus-code#614, second defect).
#
# THE PROBLEM. `monitor/worker-settings.json` and
# `monitor/orchestrator-settings.json` are TRACKED files that every
# operator must edit to carry operator-LOCAL configuration — the case
# that motivated this overlay was a nexus carrying `"model":
# "claude-opus-5"` and `"tui": "fullscreen"` in those tracked files,
# neither of which exists upstream. (Both have since left the tracked
# files: `tui` was reverted in b37bb68 / your-org/nexus-code#570, and a
# model pin belongs in the `.local.json` described below. They are named
# here as the worked example, not as keys the tracked files carry
# today.) Two consequences follow, and the second is the dangerous one:
#
#   1. Every `git pull` conflicts on both files, forever.
#   2. The obvious conflict resolution — discard local, take upstream —
#      SILENTLY DOWNGRADES every worker and skeptic off the operator's
#      chosen model. No error, no warning; the next worker simply runs
#      on a weaker model and nobody can tell from the outside.
#
# (2) is a live footgun in a repo whose whole update story is "pull and
# the watcher restarts itself". Documentation cannot fix a file layout
# that puts local and shared configuration in the same bytes.
#
# THE FIX. Keep the tracked file as the DEFAULTS, and let an UNTRACKED
# sibling `<name>.local.json` override keys on top of it. The merged
# result is materialised under `monitor/.state/settings/` (gitignored)
# and that path is what gets passed to `claude --settings`. A pull can
# now never touch the operator's model pin, because the pin does not
# live in a tracked file any more.
#
#   monitor/worker-settings.json          tracked   — hooks, defaults
#   monitor/worker-settings.local.json    UNTRACKED — operator's keys
#   monitor/.state/settings/worker-settings.effective.json   generated
#
# MERGE SEMANTICS: recursive object merge, local wins on conflicts
# (jq's `*`). Objects merge key-by-key so a local file setting only
# `model` inherits the entire tracked `hooks` block; ARRAYS REPLACE
# wholesale, which is what you want for a hook list — a local file that
# defines `hooks.Stop` replaces that event's hooks rather than appending
# to them.
#
# FAILURE POSTURE — FAIL LOUD, NEVER SILENTLY DEGRADE. The bug being
# fixed is a silent downgrade, so every failure path here must be
# noisier than the bug. Malformed local JSON, a jq that is missing, an
# unwritable state dir: each returns non-zero with a message on stderr.
# Callers treat that as a spawn-blocker. Falling back to the tracked
# defaults would reintroduce the exact silent-downgrade this exists to
# prevent — the operator asked for opus and would get sonnet because a
# comma was missing.
#
# Usage:
#   eff=$(monitor/resolve-settings.sh <path-to-tracked-settings.json>) || exit
#   claude --settings "$eff" ...
#
# With no `.local.json` present the tracked path is echoed unchanged —
# zero new files, zero behaviour change, so this is a no-op for every
# operator who has not opted in.
#
# FOREIGN INSTRUCTION FILES (your-org/nexus-code#1671, #1779):
#   eff=$(monitor/resolve-settings.sh --nexus-root <root> <settings.json>)
# additionally writes `claudeMdExcludes` for every CLAUDE.md-family,
# AGENTS.md and `.claude/rules/` file under <root>/work/, and defaults the
# AGENTS.md fallback off. A repo cloned under work/ is foreign content, and Claude Code loads
# its instruction files as PROJECT INSTRUCTIONS: at launch for the workdir
# and its ancestors, on a Read of any file below one (2.1.x), and, since
# 2.1.293, on a single-file `cat`/`head`/`tail`/`sed -n`/`grep` in Bash.
# MEASURED on 2.1.293 against the cc-harness mock (canary files, request
# bodies; evidence on #1779): a `--settings` `claudeMdExcludes` of
# `<root>/*/**/CLAUDE.md` suppresses the nested load on the Bash route, the
# Read route and through an intermediate ancestor, the root's own CLAUDE.md
# still loads, and the same key suppresses AGENTS.md at launch and on Read,
# and a nested `.claude/rules/` file (plain or path-scoped), which the same
# Bash and Read routes load too.
# The key is stripped from launch-folder (project) settings by the binary,
# so a cloned repo cannot undo it. COVERAGE BOUNDARY: only a session started
# with the resolved `--settings` file gets the excludes — spawn-worker.sh's
# launchers and the orchestrator respawn launcher. A session the operator
# launches by hand gets none (skeptic note on PR #1781). Globs are matched against ABSOLUTE paths
# (picomatch), hence a per-root generated value and not a tracked one.
# Existing excludes are kept (union); an `instructionFiles` mode the
# operator set is kept. This mode never REFUSES for the excludes' sake: if
# they cannot be applied the path is still printed (the overlay, when
# present, is honoured as above) with exit 11 and the reason on stderr —
# a spawn that cannot start is worse than one that starts unprotected and
# says so.

set -uo pipefail

nexus_root=""
if [[ "${1:-}" == --nexus-root ]]; then
    nexus_root="${2:-}"
    if [[ -z "$nexus_root" ]]; then
        printf 'resolve-settings: --nexus-root needs a directory\n' >&2
        exit 2
    fi
    shift 2
fi

base="${1:-}"
if [[ -z "$base" ]]; then
    printf 'resolve-settings: usage: resolve-settings.sh [--nexus-root <root>] <settings.json>\n' >&2
    exit 2
fi
if [[ ! -f "$base" ]]; then
    printf 'resolve-settings: base settings file missing: %s\n' "$base" >&2
    exit 3
fi

dir="${base%/*}"
file="${base##*/}"
stem="${file%.json}"
local_file="$dir/${stem}.local.json"

# With --nexus-root and no overlay, any failure below still prints the
# tracked path: exit 11, "resolved, foreign instruction files NOT excluded".
_excl_unapplied() {
    printf 'resolve-settings: foreign instruction files under %s/work are NOT excluded (%s) — the agent will load any CLAUDE.md/AGENTS.md it reads there (your-org/nexus-code#1779)\n' \
        "${nexus_root%/}" "$1" >&2
}

# The instruction-file exclusion filter for --nexus-root, as a jq program
# argument, or empty with the reason in $excl_why. Both the logical and the
# physical spelling of the root are listed, because the binary may report
# either. A root holding a glob metacharacter cannot be matched literally,
# so it gets no excludes rather than wrong ones.
excl_json=""
excl_why=""
if [[ -n "$nexus_root" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
        # No overlay: the excludes are the only jq work, so stop here (11).
        # With an overlay, the overlay gate below refuses outright (exit 4).
        [[ -f "$local_file" ]] || { _excl_unapplied "jq is unavailable"; printf '%s' "$base"; exit 11; }
        excl_why="jq is unavailable"
    elif [[ ! -d "$nexus_root" ]]; then
        excl_why="nexus root $nexus_root is not a directory"
    else
        roots=( "${nexus_root%/}" )
        phys=$(cd -- "$nexus_root" 2>/dev/null && pwd -P) || phys=""
        [[ -n "$phys" && "$phys" != "${roots[0]}" ]] && roots+=( "$phys" )
        pats=()
        for r in "${roots[@]}"; do
            case "$r" in
                *[][*?{}\(\)\!+@]*) excl_why="nexus root $r contains a glob metacharacter"; pats=(); break ;;
            esac
            for n in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md AGENTS.md .claude/AGENTS.md '.claude/rules/**'; do
                pats+=( "$r/work/**/$n" )
            done
        done
        if [[ -z "$excl_why" ]]; then
            excl_json=$(printf '%s\n' "${pats[@]}" | jq -R . | jq -s -c .) || { excl_json=""; excl_why="jq could not encode the patterns"; }
        fi
    fi
fi
# shellcheck disable=SC2016
excl_filter='((.claudeMdExcludes // []) + $pats | unique) as $e | .claudeMdExcludes = $e
  | if (.pluginConfigs["agents-md@builtin"].options.instructionFiles // null) == null
    then .pluginConfigs["agents-md@builtin"].options.instructionFiles = "claude-md" else . end'


# No overlay — the common case, and a pure pass-through.
if [[ ! -f "$local_file" && -z "$nexus_root" ]]; then
    printf '%s' "$base"
    exit 0
fi
if [[ ! -f "$local_file" && -z "$excl_json" ]]; then
    _excl_unapplied "$excl_why"
    printf '%s' "$base"
    exit 11
fi

if [[ -f "$local_file" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
        printf 'resolve-settings: %s exists but jq is unavailable — refusing to spawn with the operator overlay SILENTLY DROPPED (that is the #614 downgrade). Install jq or remove the overlay.\n' \
            "$local_file" >&2
        exit 4
    fi
    # Validate by asking for the PROPERTY (this parses to a JSON object),
    # not the proxy (jq exited 0). jq 1.5 — which ships on the sandbox
    # hosts — exits 0 on a TRUNCATED document while emitting nothing at
    # all, so `jq -e . file >/dev/null` waves through exactly the malformed
    # overlay this guard exists to catch. Require the type name on stdout.
    _json_type() {
        local t
        t=$(jq -r 'type' "$1" 2>/dev/null) || return 1
        [[ -n "$t" ]] || return 1
        printf '%s' "$t"
    }
    lt=$(_json_type "$local_file") || lt=""
    if [[ "$lt" != "object" ]]; then
        printf 'resolve-settings: %s is not a valid JSON object (parsed as %s) — refusing to spawn rather than silently ignoring the operator overlay.\n' \
            "$local_file" "${lt:-unparseable}" >&2
        exit 5
    fi
    bt=$(_json_type "$base") || bt=""
    if [[ "$bt" != "object" ]]; then
        printf 'resolve-settings: %s is not a valid JSON object (parsed as %s).\n' \
            "$base" "${bt:-unparseable}" >&2
        exit 6
    fi
fi

state_dir="${NEXUS_STATE_DIR:-$dir/.state}/settings"
if ! mkdir -p "$state_dir" 2>/dev/null; then
    if [[ ! -f "$local_file" ]]; then
        _excl_unapplied "cannot create $state_dir"
        printf '%s' "$base"; exit 11
    fi
    printf 'resolve-settings: cannot create %s — refusing to spawn without the operator overlay.\n' \
        "$state_dir" >&2
    exit 7
fi

out="$state_dir/${stem}.effective.json"
tmp="$out.$$.tmp"
if [[ -f "$local_file" ]]; then
    merge='.[0] * .[1]'; inputs=( "$base" "$local_file" )
else
    merge='.[0]'; inputs=( "$base" )
fi
excl_rc=0
if [[ -n "$excl_json" ]]; then
    jq -s --argjson pats "$excl_json" "$merge | $excl_filter" "${inputs[@]}" > "$tmp" 2>/dev/null || excl_rc=$?
    if (( excl_rc != 0 )); then
        if [[ ! -f "$local_file" ]]; then
            rm -f "$tmp"; _excl_unapplied "merge failed"
            printf '%s' "$base"; exit 11
        fi
        excl_why="merge failed"
    fi
fi
if [[ -z "$excl_json" || $excl_rc -ne 0 ]]; then
    if ! jq -s "$merge" "${inputs[@]}" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        printf 'resolve-settings: merge of %s over %s failed — refusing to spawn.\n' \
            "$local_file" "$base" >&2
        exit 8
    fi
fi
# Verify the PROPERTY (the merged file is usable settings), not the
# proxy (jq exited 0). A merge can succeed into something that is not
# an object — e.g. if either input is a top-level array.
if ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    if [[ ! -f "$local_file" ]]; then
        _excl_unapplied "the result is not a JSON object"
        printf '%s' "$base"; exit 11
    fi
    printf 'resolve-settings: merged settings are not a JSON object — refusing to spawn.\n' >&2
    exit 9
fi
if ! mv "$tmp" "$out" 2>/dev/null; then
    rm -f "$tmp"
    if [[ ! -f "$local_file" ]]; then
        _excl_unapplied "cannot write $out"
        printf '%s' "$base"; exit 11
    fi
    printf 'resolve-settings: cannot write %s — refusing to spawn.\n' "$out" >&2
    exit 10
fi
chmod 600 "$out" 2>/dev/null || true
printf '%s' "$out"
if [[ -n "$nexus_root" && ( -z "$excl_json" || $excl_rc -ne 0 ) ]]; then
    _excl_unapplied "$excl_why"
    exit 11
fi
exit 0
