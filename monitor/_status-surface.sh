#!/usr/bin/env bash
# Status-surface resolution (your-org/nexus-code#1839). Which surface carries
# the operator's "state of everything" view, from `status_surface.kind` in
# config/nexus.yml:
#
#   overview-dashboard  the default, and what an ABSENT key means: the
#                       overview issue, maintained with `ng dashboard put`.
#   external            an operator-run page the nexus does not maintain, so
#                       nothing may nudge toward a dashboard put.
#
# Functions only; sourced by monitor/ng (cmd_dashboard_put) and
# monitor/watcher/main.sh (the emit's dashboard section). An unknown kind is
# refused at start-up by `config/load.sh --validate`; these helpers refuse it
# again at the point of use rather than falling back to the default, because
# a config edited after the watcher started never meets the start-up check.
#
# Every function takes the config reader as $1 (`"$_cfg"` in the watcher,
# `_ng_cfg` in ng), so each caller keeps its own config-root resolution.

# status_surface_kind <cfg-reader>
#   rc 0  a known kind on stdout
#   rc 3  an UNKNOWN kind: the raw value on stdout, the refusal on stderr
#   rc 2  the config could not be read at all: `overview-dashboard` on stdout,
#         because nothing read this key before #1839, so that is the
#         behaviour the caller had — every other config read fails too
status_surface_kind() {
    local cfg="$1" kind rc
    kind=$("$cfg" status_surface.kind overview-dashboard 2>/dev/null); rc=$?
    if (( rc != 0 )); then
        printf 'overview-dashboard\n'
        return 2
    fi
    case "$kind" in
        overview-dashboard|external) printf '%s\n' "$kind"; return 0 ;;
    esac
    printf '%s\n' "$kind"
    printf "status_surface.kind '%s' in config/nexus.yml is not a known kind (overview-dashboard | external)\n" \
        "$kind" >&2
    return 3
}

# status_surface_key <cfg-reader> <url_file|feed> <nexus-root>
#   The configured path for that key, made absolute against <nexus-root> when
#   relative; empty (rc 0) when unset.
status_surface_key() {
    local cfg="$1" key="$2" root="$3" p
    p=$("$cfg" "status_surface.$key" "" 2>/dev/null) || p=""
    [[ -n "$p" && "$p" != /* ]] && p="$root/$p"
    printf '%s\n' "$p"
}
