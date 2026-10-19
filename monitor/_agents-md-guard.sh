#!/usr/bin/env bash
# monitor/_agents-md-guard.sh — spawn-time scan for AGENTS.md files a worker's
# harness would load as PROJECT INSTRUCTIONS (your-org/nexus-code#1671).
#
# WHY. A repo cloned under work/ that ships an AGENTS.md hands its text to the
# agent started there as instructions, not data — a prompt-injection surface in
# exactly the directories where workers run. This file answers, at spawn time,
# "which AGENTS.md files between the workdir and the nexus root would this
# harness load?", so spawn-worker.sh can say so loudly and tell the worker the
# content is untrusted DATA.
#
# MEASURED SEMANTICS, Claude Code 2.1.284 (the pinned build), against the
# cc-harness mock backend with unique-token AGENTS.md files; the evidence is on
# your-org/nexus-code#1671. The loader is the built-in plugin `agents-md@builtin`
# (GrowthBook gate `tengu_agents_md_mod`, client default ON):
#   - default mode `claude-md-or-agents-md`: `AGENTS.md` and `.claude/AGENTS.md`
#     in the cwd and EVERY ancestor (past the git root, up to /) are loaded —
#     unless ANY `CLAUDE.md` / `.claude/CLAUDE.md` / `CLAUDE.local.md` sits in
#     the cwd or an ancestor, which suppresses the whole fallback. A CLAUDE.md
#     BELOW the cwd does NOT suppress. With the fallback active, an AGENTS.md
#     BELOW the cwd is loaded when a file beside it is Read.
#   - IN THE DEFAULT NEXUS LAYOUT NOTHING IS LOADED: the nexus root's own
#     CLAUDE.md is an ancestor of every work/<proj>, so the fallback is
#     suppressed (measured: a git repo and a plain dir under work/, and the
#     nested on-Read path, all load no token). The exposure is a workdir
#     OUTSIDE the nexus root, or a mode switched away from the default.
#   - the mode is `pluginConfigs["agents-md@builtin"].options.instructionFiles`
#     (claude-md | claude-md-or-agents-md | claude-md-and-agents-md |
#     managed-only), read from user, --settings and managed settings — NOT from
#     project settings. `enabledPlugins["agents-md@builtin"]: false` turns the
#     plugin off. Both measured; an unknown value reads as the default, as the
#     binary does.
# Codex (NOT measured here — no codex binary on the measuring host; this is
# its documented behaviour): `AGENTS.override.md` / `AGENTS.md` in every
# directory from the project root (nearest ancestor holding `.git`) down to the
# cwd. A CLAUDE.md does not suppress it, so for a Codex worker the exposure is
# real in the default layout.
#
# SCOPE. The directories scanned are the workdir and its ancestors up to, NOT
# including, the nexus root (all the way to / when the workdir is outside it).
# The nexus root and above are the operator's own tree, not a foreign clone,
# and for Claude the root CLAUDE.md suppresses them anyway.
#
# BOUNDARY, stated so a zero is not over-read: managed (policy) settings are
# not consulted for the mode; files BELOW the workdir are not enumerated (a
# subtree walk at spawn time is unbounded) — the warning text says they load on
# Read when the fallback is active.
#
# API
#   amg_scan <workdir> <nexus_root> <harness> [settings_file]
#     harness: claude-code | codex. settings_file: the --settings file the
#     worker is launched with (flag settings; they override user settings).
#     stdout, one TAB-separated record per file found:
#         loaded<TAB><path><TAB><reason>
#         suppressed<TAB><path><TAB><reason>
#     rc 0 = scanned (zero records means none found); rc 2 = could not scan
#     (workdir not a directory, unknown harness) — NOT "none found".
#   amg_claude_mode [settings_file]   → the effective instructionFiles mode,
#     or `plugin-disabled`.

_AMG_CLAUDE_NAMES=(AGENTS.md .claude/AGENTS.md)
_AMG_CODEX_NAMES=(AGENTS.override.md AGENTS.md)
_AMG_CLAUDE_MD_NAMES=(CLAUDE.md .claude/CLAUDE.md CLAUDE.local.md)
_AMG_DEFAULT_MODE=claude-md-or-agents-md

_amg_real() { ( CDPATH= cd -- "$1" 2>/dev/null && pwd -P ); }

# The user-settings file Claude Code reads: $CLAUDE_CONFIG_DIR/settings.json,
# else ~/.claude/settings.json.
_amg_user_settings() {
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        printf '%s/settings.json\n' "$CLAUDE_CONFIG_DIR"
    else
        printf '%s/.claude/settings.json\n' "${HOME:-/nonexistent}"
    fi
}

amg_claude_mode() {
    local flag_settings="${1:-}" mode="$_AMG_DEFAULT_MODE" f v disabled=0 havejq=1
    command -v jq >/dev/null 2>&1 || havejq=0
    # Precedence as the binary merges it: user, then --settings (later wins).
    # A settings file that EXISTS but cannot be read here (no jq, or JSON jq
    # rejects) could say anything, including `claude-md-and-agents-md`, so it
    # yields `unreadable`, which amg_scan treats as LOADED. That is the warn
    # direction. Deferring to the default would silently report `suppressed`
    # for a file the binary loads.
    for f in "$(_amg_user_settings)" "$flag_settings"; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        if [ "$havejq" -eq 0 ] || [ ! -r "$f" ] || ! jq -e . "$f" >/dev/null 2>&1; then
            printf 'unreadable\n'; return 0
        fi
        v=$(jq -r '.pluginConfigs["agents-md@builtin"].options.instructionFiles // empty' "$f" 2>/dev/null) || v=""
        [ -n "$v" ] && mode="$v"
        # NOT `// empty`: jq's `//` treats `false` as absent, which would
        # erase exactly the value this line exists to read.
        v=$(jq -r '.enabledPlugins["agents-md@builtin"] | if . == null then empty else tostring end' "$f" 2>/dev/null) || v=""
        case "$v" in false) disabled=1 ;; true) disabled=0 ;; esac
    done
    if [ "$disabled" -eq 1 ]; then printf 'plugin-disabled\n'; return 0; fi
    case "$mode" in
        claude-md|claude-md-or-agents-md|claude-md-and-agents-md|managed-only) ;;
        *) mode="$_AMG_DEFAULT_MODE" ;;   # the binary's own fallback for an unknown value
    esac
    printf '%s\n' "$mode"
}

# First CLAUDE.md-family file in <dir> or any ancestor up to /, or nothing.
_amg_claude_md_on_walk() {
    local d="$1" n
    while :; do
        for n in "${_AMG_CLAUDE_MD_NAMES[@]}"; do
            [ -f "$d/$n" ] && { printf '%s\n' "$d/$n"; return 0; }
        done
        [ "$d" = / ] && return 1
        d=$(dirname -- "$d")
    done
}

# Nearest ancestor-or-self holding `.git` (dir or file), or nothing.
_amg_git_root() {
    local d="$1"
    while :; do
        [ -e "$d/.git" ] && { printf '%s\n' "$d"; return 0; }
        [ "$d" = / ] && return 1
        d=$(dirname -- "$d")
    done
}

# Directories scanned, workdir first: up to NOT including nexus_root when the
# workdir is below it; to / inclusive otherwise; none when workdir IS the root.
_amg_scan_dirs() {
    local wd="$1" root="$2" d="$1"
    [ "$wd" = "$root" ] && return 0
    case "$wd/" in
        "$root"/*)
            while [ "$d" != "$root" ]; do printf '%s\n' "$d"; d=$(dirname -- "$d"); done ;;
        *)
            while :; do printf '%s\n' "$d"; [ "$d" = / ] && break; d=$(dirname -- "$d"); done ;;
    esac
}

amg_scan() {
    local wd root harness="${3:-}" settings="${4:-}" d n f
    wd=$(_amg_real "${1:-}") || { echo "amg_scan: workdir ${1:-<empty>} is not a directory" >&2; return 2; }
    [ -n "$wd" ] || { echo "amg_scan: workdir ${1:-<empty>} is not a directory" >&2; return 2; }
    root=$(_amg_real "${2:-}") || root="${2:-}"
    [ -n "$root" ] || { echo "amg_scan: nexus root is empty" >&2; return 2; }
    local -a names=()
    case "$harness" in
        claude-code|claude|'') harness=claude-code; names=("${_AMG_CLAUDE_NAMES[@]}") ;;
        codex)                 names=("${_AMG_CODEX_NAMES[@]}") ;;
        *) echo "amg_scan: unknown harness '$harness'" >&2; return 2 ;;
    esac

    local -a found=()
    while IFS= read -r d; do
        for n in "${names[@]}"; do
            [ -f "$d/$n" ] && found+=("$d/$n")
        done
    done < <(_amg_scan_dirs "$wd" "$root")
    [ "${#found[@]}" -gt 0 ] || return 0

    local verdict reason
    if [ "$harness" = codex ]; then
        local groot
        groot=$(_amg_git_root "$wd") || groot="$wd"
        for f in "${found[@]}"; do
            case "$(dirname -- "$f")/" in
                "$groot"/*) verdict=loaded; reason="codex reads AGENTS files from the project root $groot down to the workdir" ;;
                *)          verdict=suppressed; reason="above the codex project root $groot" ;;
            esac
            printf '%s\t%s\t%s\n' "$verdict" "$f" "$reason"
        done
        return 0
    fi

    local mode cm
    mode=$(amg_claude_mode "$settings")
    case "$mode" in
        claude-md|managed-only|plugin-disabled)
            verdict=suppressed; reason="agents-md mode $mode" ;;
        claude-md-and-agents-md)
            verdict=loaded; reason="agents-md mode $mode loads AGENTS.md beside CLAUDE.md" ;;
        unreadable)
            verdict=loaded; reason="a settings file could not be read (jq absent or invalid JSON), so the agents-md mode is unknown; assuming LOADED" ;;
        *)
            if cm=$(_amg_claude_md_on_walk "$wd"); then
                verdict=suppressed; reason="fallback suppressed by $cm"
            else
                verdict=loaded; reason="no CLAUDE.md in the workdir or any ancestor, so AGENTS.md is the fallback; AGENTS.md below the workdir also loads when a file beside it is Read"
            fi ;;
    esac
    for f in "${found[@]}"; do
        printf '%s\t%s\t%s\n' "$verdict" "$f" "$reason"
    done
    return 0
}

# ---- the workdir's OWN AGENTS.md: conventions, by trust tier ----------------
# (your-org/nexus-code#1671, the operator-agreed proposal on that issue.) A
# project that ships an AGENTS.md expects agents that WORK IN it to read it, so
# the warning above is wrong for that one file. When the workdir IS a repository
# root, or a linked worktree of one, and `<workdir>/AGENTS.md` exists, the spawn
# prompt tells the worker to read it FIRST as the project's conventions. The
# mechanism is an explicit read instruction, never harness auto-load, so the
# precedence stays ours: the worker floor and the nexus contract win on any
# conflict. A repo the worker only USES (an AGENTS.md above the workdir, or a
# workdir below a repo's root) keeps the untrusted-DATA warning.
#
# The tier decides how much authority the file gets, after CLAUDE.md's
# "WHETHER — by repo tier": INTERNAL is the lab org (`github.repo`'s owner) and
# the operator's (`github.user_login`) PRIVATE repos; everything else is
# EXTERNAL, and so is everything UNCERTAIN — no remote, an unparsable or
# non-github.com remote, a placeholder or unreadable config, a visibility probe
# that failed or timed out. External still reads the conventions, with the
# stricter framing, so the fail direction costs only authority, never the read.
#
# API
#   amg_workin_agents_md <workdir> <nexus_root>
#     stdout: the path of the workdir repository's AGENTS.md, when the workdir
#     is a repository root (repo-root.sh kind `root` or `linked-worktree`) and
#     the file exists; nothing otherwise. rc 0 = decided; rc 2 = could not
#     decide (repo-root.sh unreadable, or its verdict was `undetermined`).
#   amg_repo_tier <repo_root> <nexus_root>
#     stdout: `internal<TAB><owner/name><TAB><reason>` or
#             `external<TAB><owner/name or -><TAB><reason>`. Always rc 0.
#     Test seam: AMG_VISIBILITY_OVERRIDE=private|public|<anything> replaces the
#     `gh api repos/O/R --jq .private` probe (bounded by AMG_GH_TIMEOUT
#     seconds, default 10); any value but `private` reads as not-private.

amg_workin_agents_md() {
    local wd root="${2:-}" kind
    wd=$(_amg_real "${1:-}") || return 2
    [ -n "$wd" ] || return 2
    root=$(_amg_real "$root") || root="${2:-}"
    [ "$wd" = "$root" ] && return 0          # the nexus itself is not a clone
    [ -f "$wd/AGENTS.md" ] || return 0
    [ -r "$root/monitor/repo-root.sh" ] || return 2
    kind=$(bash "$root/monitor/repo-root.sh" --kind "$wd" 2>/dev/null)
    case "$kind" in
        root|linked-worktree) printf '%s\n' "$wd/AGENTS.md" ;;
        unreadable|git-unavailable|error|'') return 2 ;;
        *) : ;;                                # subdir, none, …: a USE, not work-in
    esac
    return 0
}

# owner/name from a GitHub remote URL (https, ssh scp-form, ssh://), or nothing.
# Only github.com: the tier rule is about GitHub ownership, and another host's
# `labx/` is not the lab's.
_amg_slug_from_url() {
    printf '%s\n' "$1" | sed -nE \
        -e 's#^https?://([^@/]+@)?github\.com/([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+)/?$#\2#Ip' \
        -e 's#^ssh://([^@/]+@)?github\.com(:[0-9]+)?/([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+)/?$#\3#Ip' \
        -e 's#^([^@/:]+@)?github\.com:([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+)/?$#\2#Ip' \
        | sed -E 's/\.git$//' | sed -n 1p
}

# A config value, or nothing when absent, unreadable, or still the
# nexus.example.yml placeholder (load.sh falls through to the template when
# config/nexus.yml is missing, and its values look real enough to match).
_amg_cfg() {
    local root="$1" key="$2" v ex
    [ -x "$root/config/load.sh" ] || return 0
    # NEXUS_ROOT pinned: load.sh prefers an inherited one over its own location.
    v=$(NEXUS_ROOT="$root" "$root/config/load.sh" "$key" '' 2>/dev/null) || return 0
    if [ -f "$root/config/nexus.example.yml" ]; then
        ex=$(NEXUS_ROOT="$root" NEXUS_CONFIG="$root/config/nexus.example.yml" "$root/config/load.sh" "$key" '' 2>/dev/null) || ex=""
        [ -n "$ex" ] && [ "$v" = "$ex" ] && return 0
    fi
    printf '%s\n' "$v"
}

amg_repo_tier() {
    local repo="${1:-}" root="${2:-}" url slug owner lab op lc_owner vis
    url=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$repo" remote get-url origin 2>/dev/null) || url=""
    if [ -z "$url" ]; then
        printf 'external\t-\tno origin remote\n'; return 0
    fi
    slug=$(_amg_slug_from_url "$url")
    if [ -z "$slug" ]; then
        printf 'external\t-\torigin is not a parsable github.com URL\n'; return 0
    fi
    owner=${slug%%/*}
    lab=$(_amg_cfg "$root" github.repo); lab=${lab%%/*}
    op=$(_amg_cfg "$root" github.user_login)
    case "$lab" in *[!A-Za-z0-9-]*) lab="" ;; esac
    case "$op" in *[!A-Za-z0-9-]*) op="" ;; esac
    if [ -z "$lab" ] && [ -z "$op" ]; then
        printf 'external\t%s\tno lab org or operator resolvable from config\n' "$slug"; return 0
    fi
    # GitHub logins are case-insensitive.
    lc_owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
    lab=$(printf '%s' "$lab" | tr '[:upper:]' '[:lower:]')
    op=$(printf '%s' "$op" | tr '[:upper:]' '[:lower:]')
    # A github.repo under the operator's OWN account names no lab org: that
    # owner is then judged by the operator rule, which demands privacy.
    if [ -n "$lab" ] && [ "$lab" != "$op" ] && [ "$lc_owner" = "$lab" ]; then
        printf 'internal\t%s\tlab org %s\n' "$slug" "$owner"; return 0
    fi
    if [ -n "$op" ] && [ "$lc_owner" = "$op" ]; then
        if [ -n "${AMG_VISIBILITY_OVERRIDE+x}" ]; then
            vis="$AMG_VISIBILITY_OVERRIDE"
        else
            vis=$(timeout "${AMG_GH_TIMEOUT:-10}" gh api "repos/$slug" --jq .private 2>/dev/null) || vis=""
            case "$vis" in true) vis=private ;; false) vis=public ;; *) vis=unknown ;; esac
        fi
        if [ "$vis" = private ]; then
            printf 'internal\t%s\toperator-owned private repo\n' "$slug"
        else
            printf 'external\t%s\toperator-owned but not positively private (visibility %s)\n' "$slug" "$vis"
        fi
        return 0
    fi
    printf 'external\t%s\towner %s is neither the lab org nor the operator\n' "$slug" "$owner"
    return 0
}
