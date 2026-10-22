#!/usr/bin/env bash
# host-pin-lint.sh — no service declaration may PIN a cluster node.
#
# A learning service was pinned to one literal node and broke the day the
# nexus moved to another one. Operator directive: remove every such pin. This
# lint flags a literal NODE-SHAPED hostname or a literal IPv4 in the files that
# declare where a service lives and how it is reached:
#
#     monitor/services.registry (and the tracked .example)   every row
#     any Caddyfile (Caddyfile, Caddyfile.*, *.caddy, *.caddyfile)
#     any .deploy/endpoint
#
# THE CORRECT MECHANISM, named in every finding: a service derives its host at
# START time — `hostname -f` (and `getent` for the address) in its launcher,
# passed to Caddy as an environment placeholder ({$X_HOST}, {$X_BIND}) — and
# DECLARES itself as http(s)://localhost:PORT. `monitor/svc.sh` renders that
# URL with the live FQDN (svc_display_url → svc_fqdn = `hostname -f`) when the
# port is bound beyond loopback. Bind 127.0.0.1, or 0.0.0.0 when the service is
# meant to be reached from other machines (skills/nexus.services/SKILL.md §6).
#
# Usage:  monitor/host-pin-lint.sh [--files] [--live] [<root>]
#   default   TRACKED mode. <root> must be the top of its own git repository;
#             the population is every git-visible file (tracked plus
#             untracked-not-ignored, `ls-files -co --exclude-standard`) whose
#             name is one of the shapes above. This is what the suite gates.
#   --live    LIVE mode, for an operator's primary. services.registry and the
#             service workdirs are NOT in the tracked tree (monitor/.gitignore
#             ignores the registry; .deploy/endpoint lives in each project's
#             own checkout under work/), so the tracked mode cannot see them.
#             Population: <root>/monitor/services.registry, then for EVERY row's
#             workdir (`~` and $NEXUS_ROOT expanded as svc.sh does) its
#             .deploy/endpoint and Caddyfile, then <root>/work/*/.deploy/endpoint
#             and <root>/work/*/Caddyfile (one level, never a recursive walk).
#             Read-only. Every file access is bounded (HPL_TIMEOUT, default 5 s):
#             an access that does not return is UNCHECKED, listed, and makes
#             the verdict rc 3 — never a green.
#   --files   print the population, one path per line, and exit 0.
#
# A finding:  <path>:<line>: <kind> '<token>' — <remedy>
# Exit: 0 clean · 1 a pin was found · 3 REFUSED / incomplete (not a repo top,
#       an unreadable or hung file) — never a green · 2 usage.
#
# WHAT IS A PIN.
#   IPv4    any dotted quad with octets <= 255, EXCEPT 127.0.0.0/8 (loopback),
#           0.0.0.0 (all interfaces) and the RFC 5737 documentation ranges
#           192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24. IPv6 is not scanned
#           (`::1` is the only one these files carry).
#   NODE    a label of letters then digits (`node01`, `hostb3`, `ab-cd12`) used
#           as a HOST: (a) a dotted name of 3+ labels starting with it
#           (`node01.example.org`); (b) after `://` or `@`; (c) before
#           `:<port>`; (d) after a host-ish flag, keyword or variable
#           (--host --bind --ip --listen --addr --server, ssh, bind, *HOST*=,
#           *BIND*=, *ADDR*=, *LISTEN*=, *SERVER*=).
#   Comments (`#` at line start or after whitespace) are not scanned.
#   A line carrying `host-pin-lint: allow` is skipped: a REVIEWED exemption,
#   visible in the file it exempts.
#
# BOUNDARY, stated: a source-text lint over three file shapes. It does not see
# a pin in a launcher SCRIPT, a config file of another name, a host assembled
# at runtime, a single-dot name used outside a host position (`node01.local`
# as a bare word), or `localhost`-shaped names. A bare node-shaped WORD outside
# a host position (`python3`, `sha256`) is deliberately not a finding.
set -uo pipefail

MODE=scan
LIVE=0
ROOT=""
for a in "$@"; do
    case "$a" in
        --files) MODE=files ;;
        --live)  LIVE=1 ;;
        -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*) printf 'host-pin-lint: unknown flag %s\n' "$a" >&2; exit 2 ;;
        *)  [[ -z "$ROOT" ]] || { printf 'host-pin-lint: one <root> only (got %s and %s)\n' "$ROOT" "$a" >&2; exit 2; }
            ROOT="$a" ;;
    esac
done
_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT="${ROOT:-$(cd "$_dir/.." && pwd)}"
[[ -d "$ROOT" ]] || { printf 'host-pin-lint: REFUSED — %s is not a directory.\n' "$ROOT" >&2; exit 3; }
ROOT=$(cd "$ROOT" && pwd -P) || exit 3
HPL_TIMEOUT="${HPL_TIMEOUT:-5}"

REMEDY="derive the host at START time (hostname -f / getent in the launcher, handed to Caddy as {\$X_HOST}/{\$X_BIND}) and declare http(s)://localhost:PORT — monitor/svc.sh renders it with the live FQDN (svc_display_url/svc_fqdn); bind 127.0.0.1 or 0.0.0.0 (skills/nexus.services/SKILL.md §6)"

_scratch=$(mktemp -d "${TMPDIR:-/tmp}/host-pin-lint.XXXXXX") || { printf 'host-pin-lint: REFUSED — no scratch dir.\n' >&2; exit 3; }
trap 'rm -rf "$_scratch"' EXIT
: > "$_scratch/pop"          # <display-path> TAB <absolute-path>
: > "$_scratch/unchecked"

_is_target_name() {   # <relpath> — one of the declaration shapes?
    local p="$1" b="${1##*/}"
    case "$b" in
        services.registry|services.registry.*) return 0 ;;
        Caddyfile|Caddyfile.*|*.caddy|*.caddyfile|*.Caddyfile) return 0 ;;
    esac
    case "$p" in
        .deploy/endpoint|*/.deploy/endpoint) return 0 ;;
    esac
    return 1
}

# _probe <abs> — rc 0 a readable regular file, 1 absent, 2 HUNG or unreadable.
_probe() {
    local rc=0
    timeout -k 1 "$HPL_TIMEOUT" test -e "$1" || rc=$?
    case "$rc" in
        0) ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
    timeout -k 1 "$HPL_TIMEOUT" test -f "$1" -a -r "$1" || return 2
    return 0
}
_add_live() {   # <abs> — add to the population if present; record a hang
    local f="$1" rc=0
    grep -qxF -e "$f" <(cut -f2 "$_scratch/pop") 2>/dev/null && return 0
    _probe "$f" || rc=$?
    case "$rc" in
        0) printf '%s\t%s\n' "${f#"$ROOT"/}" "$f" >> "$_scratch/pop" ;;
        2) printf '%s\n' "$f" >> "$_scratch/unchecked" ;;
    esac
}

if (( LIVE )); then
    REG="$ROOT/monitor/services.registry"
    _add_live "$REG"
    if grep -qxF -e "$REG" <(cut -f2 "$_scratch/pop"); then
        # Each row's workdir: the service's OWN declarations live there, at any
        # depth under work/ (or outside it), so a work/* walk alone would miss
        # a depth-2 workdir. Expansion mirrors svc.sh (`~`, $NEXUS_ROOT).
        while IFS=$'\t' read -r _name wd _rest; do
            [[ -z "$_name" || "$_name" == \#* ]] && continue
            [[ -n "$wd" ]] || continue
            wd="${wd/#\~/$HOME}"; wd="${wd//\$\{NEXUS_ROOT\}/$ROOT}"; wd="${wd//\$NEXUS_ROOT/$ROOT}"
            _add_live "$wd/.deploy/endpoint"
            _add_live "$wd/Caddyfile"
        done < "$REG"
    fi
    _add_live "$ROOT/Caddyfile"
    if [[ -d "$ROOT/work" ]]; then
        if ! timeout -k 1 30 ls -f -- "$ROOT/work" > "$_scratch/work" 2>/dev/null; then
            printf '%s\n' "$ROOT/work (directory listing)" >> "$_scratch/unchecked"
        fi
        while IFS= read -r d; do
            [[ "$d" == . || "$d" == .. || "$d" == */* ]] && continue
            _add_live "$ROOT/work/$d/.deploy/endpoint"
            _add_live "$ROOT/work/$d/Caddyfile"
        done < "$_scratch/work"
    fi
else
    # TRACKED mode: the population must be about ROOT itself, never an
    # enclosing repository (git -C walks up — CLAUDE.md REPO-WALKUP).
    _top=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || _top=""
    if [[ -z "$_top" || "$(cd "$_top" && pwd -P)" != "$ROOT" ]]; then
        printf 'host-pin-lint: REFUSED — %s is not the root of its own git repository; I cannot build the population (use --live for an untracked operator tree).\n' "$ROOT" >&2
        exit 3
    fi
    if ! git -C "$ROOT" ls-files -co --exclude-standard -z > "$_scratch/all0"; then
        printf 'host-pin-lint: REFUSED — git ls-files failed; a population I could not build certifies nothing.\n' >&2
        exit 3
    fi
    while IFS= read -r -d '' f; do
        _is_target_name "$f" || continue
        [[ -f "$ROOT/$f" && ! -L "$ROOT/$f" ]] || continue
        printf '%s\t%s\n' "$f" "$ROOT/$f" >> "$_scratch/pop"
    done < "$_scratch/all0"
fi

if [[ "$MODE" == files ]]; then
    cut -f1 "$_scratch/pop"
    exit 0
fi

: > "$_scratch/hits"
while IFS=$'\t' read -r disp abs; do
    if ! timeout -k 1 "$HPL_TIMEOUT" cat -- "$abs" > "$_scratch/body" 2>/dev/null; then
        printf '%s\n' "$abs" >> "$_scratch/unchecked"; continue
    fi
    # POSIX ERE only (no {n} intervals): CI's awk need not be gawk.
    awk -v disp="$disp" -v remedy="$REMEDY" '
        function report(kind, tok) { printf "%s:%d: %s %c%s%c — %s\n", disp, NR, kind, 39, tok, 39, remedy; found = 1 }
        function ip_ok(q,   o, n, i) {
            n = split(q, o, ".")
            for (i = 1; i <= 4; i++) if (o[i] + 0 > 255 || length(o[i]) > 3) return 2   # not an address
            if (o[1] == 127) return 1
            if (q == "0.0.0.0") return 1
            if (o[1] == 192 && o[2] == 0 && o[3] == 2) return 1
            if (o[1] == 198 && o[2] == 51 && o[3] == 100) return 1
            if (o[1] == 203 && o[2] == 0 && o[3] == 113) return 1
            return 0
        }
        index($0, "host-pin-lint: allow") { next }
        {
            s = $0
            sub(/^[ \t]*#.*/, "", s); sub(/[ \t]#.*/, "", s)
            # ---- IPv4 ----
            t = s; off = 0
            while (match(t, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
                q = substr(t, RSTART, RLENGTH)
                pre = (RSTART > 1) ? substr(t, RSTART - 1, 1) : ""
                post = substr(t, RSTART + RLENGTH, 1)
                if (pre !~ /[0-9.]/ && post !~ /[0-9]/ && !(post == "." && substr(t, RSTART + RLENGTH + 1, 1) ~ /[0-9]/)) {
                    if (ip_ok(q) == 0) report("IPv4", q)
                }
                t = substr(t, RSTART + RLENGTH)
            }
            # ---- node-shaped host ----
            l = tolower(s); t = l; consumed = 0
            while (match(t, /[a-z][a-z-]*[0-9]+(\.[a-z0-9-]+)*/)) {
                tok = substr(t, RSTART, RLENGTH)
                abs_start = consumed + RSTART
                before = substr(l, 1, abs_start - 1)
                pre = (abs_start > 1) ? substr(l, abs_start - 1, 1) : ""
                post = substr(l, abs_start + RLENGTH, 1)
                after = substr(l, abs_start + RLENGTH)
                consumed += RSTART + RLENGTH - 1
                t = substr(t, RSTART + RLENGTH)
                if (pre ~ /[a-z0-9_.-]/ || post ~ /[a-z0-9_-]/) continue        # part of a longer word
                sub(/\.$/, "", tok)
                ndots = gsub(/\./, ".", tok)
                if (ndots >= 2 && tok ~ /\.[a-z][a-z0-9-]*$/) { report("NODE", tok); continue }   # (a) FQDN
                if (before ~ /(:\/\/|@)$/) { report("NODE", tok); continue }                       # (b)
                if (after ~ /^:[0-9]/) { report("NODE", tok); continue }                            # (c)
                if (before ~ /(--?[a-z-]*(host|bind|ip|listen|addr|address|server)[a-z-]*|ssh|bind|[a-z_]*(host|bind|addr|address|listen|server)[a-z_]*)[ \t]*[= \t][ \t]*["'"'"']?$/ \
                    || before ~ /[a-z_]*(host|bind|addr|address|listen|server)[a-z_]*=["'"'"']?$/) { report("NODE", tok); continue }   # (d)
            }
        }
        END { exit found ? 1 : 0 }
    ' "$_scratch/body" >> "$_scratch/hits"
    _arc=$?
    (( _arc <= 1 )) || { printf 'host-pin-lint: REFUSED — the scan of %s errored (awk rc %s).\n' "$disp" "$_arc" >&2; exit 3; }
done < "$_scratch/pop"

_npop=$(grep -c . "$_scratch/pop")
_nhit=$(grep -c . "$_scratch/hits")
_nun=$(grep -c . "$_scratch/unchecked")
cat "$_scratch/hits"
if (( _nun > 0 )); then
    printf 'host-pin-lint: UNCHECKED (%s) — could not read within %ss; these are NOT certified:\n' "$_nun" "$HPL_TIMEOUT" >&2
    sed 's/^/  /' "$_scratch/unchecked" >&2
fi
printf 'host-pin-lint: %s mode, %s file(s) scanned, %s pin(s), %s unchecked.\n' \
    "$([ "$LIVE" -eq 1 ] && echo live || echo tracked)" "$_npop" "$_nhit" "$_nun" >&2
(( _nhit > 0 )) && exit 1
(( _nun > 0 )) && exit 3
exit 0
