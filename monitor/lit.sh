#!/usr/bin/env bash
# monitor/lit.sh — nexus literature-research tool (backs `ng lit`).
#
# Native, on-demand literature discovery for Claude workers. Finds papers
# by CONTENT relevance across PubMed (NCBI E-utilities, keyless), Semantic
# Scholar (S2) and ASTA (Allen AI), deduplicated against the nexus reference
# library, and can pull a paper's metadata into that library.
# Reimplements the subset of `bipartite` (bip)
# utilities the nexus needs as plain curl+jq — ZERO dependency on the
# operator-local `bip` binary, so it ships in nexus-code and works in any
# operator's clone.
#
# Subcommands:
#   ng lit status                      keys, library, index — and what to fix
#   ng lit search "<query>" [flags]    discovery (PubMed / S2 / ASTA)
#   ng lit add <DOI|PMID|S2-id> [flags] fetch metadata + append to the library
#   ng lit setup                       print the exact setup / key-acquisition refs
#
# search flags:
#   --source pubmed|s2|asta|both|all          pick discovery backend(s)
#                           both = s2+asta; all = pubmed+s2+asta.
#                           Default: the keyed backends (s2/asta) that are
#                           configured, else pubmed — so a keyless nexus
#                           searches PubMed out of the box.
#   --limit N               (default 10)      max results per source
#   --year A:B                                publication-year filter (S2, PubMed)
#   --human                                   human-readable (default: JSON)
#
# add flags:
#   --human                                   human-readable confirmation
#
# Keys are resolved per-source from (first hit wins):
#   1. env            S2_API_KEY            / ASTA_API_KEY
#   2. nexus config   lit.s2_api_key        / lit.asta_api_key   (config/nexus.yml)
#   3. legacy bip     s2_api_key            / asta_api_key       (.config/bip/config.yml)
# An unconfigured source is SKIPPED WITH A NOTE — never a silent hang and
# never a hard failure of the whole command.
#
# PubMed needs no key. Optional settings (env first, then config/nexus.yml):
#   NCBI_API_KEY / lit.ncbi_api_key   raises the NCBI limit from 3 to 10 req/s
#   NCBI_EMAIL   / lit.ncbi_email     sent as `email=` (NCBI asks for a contact)
#   NCBI_TOOL    / lit.ncbi_tool      sent as `tool=`  (default: nexus-lit)
# Requests are paced to the applicable limit and retried on HTTP 429.
#
# Secrets: keys are read, never printed. Errors are scrubbed of the key.
# Docs: reference/literature.md (acquisition + setup). Skill: nexus.lit.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_cfg="$_script_dir/../config/load.sh"

DOCS_REF="docs/reference/literature.md"
SKILL_REF="skills/nexus.lit/SKILL.md"
S2_API="https://api.semanticscholar.org/graph/v1"
ASTA_API="https://asta-tools.allen.ai/mcp/v1"
NCBI_EUTILS="https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

die() { printf 'lit: %s\n' "$*" >&2; exit 1; }
note() { printf 'lit: %s\n' "$*" >&2; }

command -v jq  >/dev/null 2>&1 || die "jq not found (required)"
command -v curl >/dev/null 2>&1 || die "curl not found (required)"

# --- nexus root -------------------------------------------------------------
_nexus_root() {
    if [[ -n "${NEXUS_ROOT:-}" ]]; then printf '%s' "$NEXUS_ROOT"; return; fi
    local r; r=$("$_cfg" nexus.root 2>/dev/null) || r=""
    if [[ -n "$r" ]]; then printf '%s' "${r/#\~/$HOME}"; return; fi
    # script lives at <root>/monitor/lit.sh
    printf '%s' "$(cd "$_script_dir/.." && pwd)"
}
ROOT="$(_nexus_root)"

# --- key resolution ---------------------------------------------------------
# $1 = s2|asta  -> prints key (empty if none configured). Never logs it.
_lit_key() {
    local svc="$1" envv cfgk bipk val
    case "$svc" in
        s2)   envv=S2_API_KEY;   cfgk=lit.s2_api_key;   bipk=s2_api_key   ;;
        asta) envv=ASTA_API_KEY; cfgk=lit.asta_api_key; bipk=asta_api_key ;;
        *) return 1 ;;
    esac
    val="${!envv:-}"; [[ -n "$val" ]] && { printf '%s' "$val"; return; }
    val=$("$_cfg" "$cfgk" 2>/dev/null) || val=""
    [[ -n "$val" ]] && { printf '%s' "$val"; return; }
    local bipcfg="$ROOT/.config/bip/config.yml"
    if [[ -f "$bipcfg" ]]; then
        val=$(sed -nE "s/^[[:space:]]*${bipk}:[[:space:]]*(.+)$/\1/p" "$bipcfg" | head -1)
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    fi
    printf '%s' "$val"
}

# Where the key came from, for `status` (no value printed).
_lit_key_origin() {
    local svc="$1" envv cfgk bipk
    case "$svc" in
        s2)   envv=S2_API_KEY;   cfgk=lit.s2_api_key;   bipk=s2_api_key   ;;
        asta) envv=ASTA_API_KEY; cfgk=lit.asta_api_key; bipk=asta_api_key ;;
    esac
    [[ -n "${!envv:-}" ]] && { printf 'env:%s' "$envv"; return; }
    local v; v=$("$_cfg" "$cfgk" 2>/dev/null) || v=""
    [[ -n "$v" ]] && { printf 'config:%s' "$cfgk"; return; }
    local bipcfg="$ROOT/.config/bip/config.yml"
    if [[ -f "$bipcfg" ]] && grep -qE "^[[:space:]]*${bipk}:[[:space:]]*\S" "$bipcfg"; then
        printf 'legacy-bip:%s' "$bipk"; return
    fi
    printf 'none'
}

# --- NCBI (PubMed) settings -------------------------------------------------
# Optional API key: env NCBI_API_KEY, then lit.ncbi_api_key. Never logged.
_ncbi_key() {
    local v="${NCBI_API_KEY:-}"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }
    v=$("$_cfg" lit.ncbi_api_key 2>/dev/null) || v=""
    printf '%s' "$v"
}
_ncbi_key_origin() {
    [[ -n "${NCBI_API_KEY:-}" ]] && { printf 'env:NCBI_API_KEY'; return; }
    local v; v=$("$_cfg" lit.ncbi_api_key 2>/dev/null) || v=""
    [[ -n "$v" ]] && { printf 'config:lit.ncbi_api_key'; return; }
    printf 'none'
}
# `email=` / `tool=` identify the caller to NCBI. Configured, never hard-coded.
_ncbi_email() {
    local v="${NCBI_EMAIL:-}"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }
    v=$("$_cfg" lit.ncbi_email 2>/dev/null) || v=""
    printf '%s' "$v"
}
_ncbi_tool() {
    local v="${NCBI_TOOL:-}"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }
    v=$("$_cfg" lit.ncbi_tool 2>/dev/null) || v=""
    printf '%s' "${v:-nexus-lit}"
}

# Resolved once per run by _ncbi_init (config reads fork python). Callers
# run it in the PARENT shell: _ncbi_get runs inside $(...) subshells, whose
# variable writes are lost.
_NCBI_READY=0 _NCBI_KEY="" _NCBI_EMAIL="" _NCBI_TOOL="" _NCBI_GAP=""
_ncbi_init() {
    [[ $_NCBI_READY -eq 1 ]] && return
    _NCBI_KEY="$(_ncbi_key)"; _NCBI_EMAIL="$(_ncbi_email)"; _NCBI_TOOL="$(_ncbi_tool)"
    # NCBI limits: 3 requests/s without a key, 10/s with one. Pace a little
    # under each so a burst never trips the limit.
    if [[ -n "$_NCBI_KEY" ]]; then _NCBI_GAP=110; else _NCBI_GAP=350; fi
    _NCBI_READY=1
}
_now_ms() {
    local t; t=$(date +%s%N 2>/dev/null)
    if [[ "$t" =~ ^[0-9]+$ ]]; then printf '%s' $((t / 1000000)); else printf '%s000' "$(date +%s)"; fi
}
# Sleep until $_NCBI_GAP ms have passed since the previous NCBI request.
# The last-request time lives in a file, not a variable, so pacing holds
# across subshells — and, under flock, across concurrent `ng lit` runs of
# the same user (the NCBI limit is per IP, not per process).
_ncbi_pace() {
    local f="${LIT_NCBI_PACE_FILE:-${TMPDIR:-/tmp}/nexus-lit-ncbi-$(id -u).last}"
    {
        command -v flock >/dev/null 2>&1 && flock -w 30 9
        local last now wait
        last=$(cat "$f" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || last=0
        now=$(_now_ms); wait=$(( last + _NCBI_GAP - now ))
        (( wait > _NCBI_GAP )) && wait=$_NCBI_GAP     # clock skew guard
        (( wait > 0 )) && sleep "$(printf '0.%03d' "$wait")"
        _now_ms >"$f" 2>/dev/null
    } 9>>"$f.lock"
}

# GET one E-utility. $1 = esearch|esummary|efetch, rest = key=value params.
# Prints the body on success. On failure prints a note (the key is scrubbed;
# NCBI echoes a rejected key in its error body) and returns 1.
_ncbi_get() {
    _ncbi_init
    local util="$1"; shift
    local args=(-sS --max-time 40 -G "$NCBI_EUTILS/$util.fcgi" -w '\n%{http_code}')
    local kv; for kv in "$@"; do args+=(--data-urlencode "$kv"); done
    args+=(--data-urlencode "tool=$_NCBI_TOOL")
    [[ -n "$_NCBI_EMAIL" ]] && args+=(--data-urlencode "email=$_NCBI_EMAIL")
    [[ -n "$_NCBI_KEY" ]]   && args+=(--data-urlencode "api_key=$_NCBI_KEY")
    local attempt out code body
    for attempt in 1 2 3; do
        _ncbi_pace
        out=$(curl "${args[@]}" 2>/dev/null) || { note "PubMed: $util request failed (network?)"; return 1; }
        code="${out##*$'\n'}"; body="${out%$'\n'*}"
        [[ "$code" == 429 ]] || break
        sleep "$attempt"
    done
    if [[ "$code" != 200 ]]; then
        local msg; msg=$(printf '%s' "$body" | jq -r '.error // empty' 2>/dev/null)
        msg="${msg:-HTTP $code}"
        [[ -n "$_NCBI_KEY" ]] && msg="${msg//"$_NCBI_KEY"/<redacted>}"
        note "PubMed: $util: $msg"; return 1
    fi
    printf '%s' "$body"
}

# PMIDs (comma-separated) -> esummary JSON normalized to the search shape,
# in the order given (esearch's relevance order).
_pubmed_summaries() {
    local ids="$1" resp
    resp=$(_ncbi_get esummary db=pubmed "id=$ids" retmode=json) || return 1
    if ! printf '%s' "$resp" | jq -e '.result.uids' >/dev/null 2>&1; then
        note "PubMed: esummary: $(printf '%s' "$resp" | jq -r '.error // .esummaryresult[0]? // "unexpected response"' 2>/dev/null)"
        return 1
    fi
    printf '%s' "$resp" | jq '.result as $r | [ $r.uids[] | $r[.] | select(.error == null) | {
        source: "pubmed",
        id: .uid,
        pmid: .uid,
        title: (.title // ""),
        year: ((.pubdate // "")[0:4] | tonumber? // null),
        venue: (.fulljournalname // .source // ""),
        doi: ([.articleids[]? | select(.idtype == "doi") | .value][0] // null),
        pmcid: ([.articleids[]? | select(.idtype == "pmc") | .value][0] // null),
        citations: null,
        url: ("https://pubmed.ncbi.nlm.nih.gov/" + .uid + "/"),
        authors: ([.authors[]?.name] | join(", ")),
        author_list: [.authors[]? | {name, authtype}]
    } ]'
}

# --- library ----------------------------------------------------------------
_lit_library() {
    local p; p=$("$_cfg" lit.library_path 2>/dev/null) || p=""
    if [[ -n "$p" ]]; then printf '%s' "${p/#\~/$HOME}"; return; fi
    printf '%s/.bipartite/refs.jsonl' "$ROOT"
}

# DOIs already in the library (lowercased), one per line.
_lib_dois() {
    local lib; lib="$(_lit_library)"
    [[ -f "$lib" ]] || return 0
    jq -r 'select(.doi != null and .doi != "") | .doi | ascii_downcase' "$lib" 2>/dev/null
}

# PMIDs already in the library, one per line.
_lib_pmids() {
    local lib; lib="$(_lit_library)"
    [[ -f "$lib" ]] || return 0
    jq -r 'select(.pmid != null and .pmid != "") | .pmid | tostring' "$lib" 2>/dev/null
}

# --- setup / not-configured guidance ---------------------------------------
_setup_refs() {
    cat >&2 <<EOF
lit: literature-search setup.

  PubMed (NCBI E-utilities) — works with NO key; the default backend when
  no S2/ASTA key is configured. Optional settings:
      NCBI_API_KEY / lit.ncbi_api_key   raises the limit from 3 to 10 req/s;
                                        free, from your NCBI account settings
                                        https://account.ncbi.nlm.nih.gov/settings/
      NCBI_EMAIL   / lit.ncbi_email     contact address NCBI asks callers to send
  Semantic Scholar (S2)  — free key, instant:
      request at  https://www.semanticscholar.org/product/api#api-key-form
  ASTA (Allen AI)        — request via the ASTA program (see the docs page).
  An unconfigured keyed backend is simply skipped.

Install a key one of three ways (first found wins):
  1. export S2_API_KEY=...   (or ASTA_API_KEY / NCBI_API_KEY)  in the environment
  2. add to config/nexus.yml:
         lit:
           s2_api_key: "..."     # config/nexus.yml is gitignored — safe
           asta_api_key: "..."
           ncbi_api_key: "..."
           ncbi_email: "you@example.org"
  3. legacy: .config/bip/config.yml  s2_api_key: / asta_api_key:

Full instructions, key-acquisition links, and library setup:
  $DOCS_REF
  $SKILL_REF   (when to use the tool; cite findings in scientific reports)
EOF
}

# ===========================================================================
# status
# ===========================================================================
cmd_status() {
    local human=0; [[ "${1:-}" == "--human" ]] && human=1
    local lib; lib="$(_lit_library)"
    local libn=0; [[ -f "$lib" ]] && libn=$(grep -c '' "$lib" 2>/dev/null || echo 0)
    local s2o asta_o ncbio
    s2o=$(_lit_key_origin s2); asta_o=$(_lit_key_origin asta); ncbio=$(_ncbi_key_origin)
    local s2_ok=no asta_ok=no
    [[ "$s2o" != none ]] && s2_ok=yes
    [[ "$asta_o" != none ]] && asta_ok=yes
    local rate="3/s"; [[ "$ncbio" != none ]] && rate="10/s"
    local email_set=no; [[ -n "$(_ncbi_email)" ]] && email_set=yes
    local tool; tool="$(_ncbi_tool)"
    local default=pubmed
    if [[ $s2_ok == yes && $asta_ok == yes ]]; then default=both
    elif [[ $s2_ok == yes ]]; then default=s2
    elif [[ $asta_ok == yes ]]; then default=asta
    fi
    if [[ $human -eq 1 ]]; then
        printf 'Nexus literature tool\n'
        printf '  library:     %s\n' "$lib"
        printf '  references:  %s\n' "$libn"
        printf '  PubMed:      yes (keyless; api key: %s; limit %s; email: %s; tool: %s)\n' \
            "$ncbio" "$rate" "$email_set" "$tool"
        printf '  S2 key:      %s (%s)\n'   "$s2_ok"   "$s2o"
        printf '  ASTA key:    %s (%s)\n'   "$asta_ok" "$asta_o"
        printf '  default:     --source %s\n' "$default"
        printf '  status:      ready\n'
    else
        jq -n --arg lib "$lib" --argjson n "$libn" \
              --arg s2 "$s2_ok" --arg s2o "$s2o" \
              --arg asta "$asta_ok" --arg astao "$asta_o" \
              --arg ncbio "$ncbio" --arg rate "$rate" --arg email "$email_set" \
              --arg tool "$tool" --arg dflt "$default" \
              '{library:$lib, references:$n,
                pubmed:{configured:true, api_key:($ncbio != "none"), origin:$ncbio,
                        rate_limit:$rate, email_set:($email=="yes"), tool:$tool},
                s2:{configured:($s2=="yes"), origin:$s2o},
                asta:{configured:($asta=="yes"), origin:$astao},
                default_source:$dflt,
                configured: true}'
    fi
    [[ $email_set == no ]] && note "tip: set lit.ncbi_email (or NCBI_EMAIL) — NCBI asks E-utilities callers for a contact address"
    return 0
}

# ===========================================================================
# search
# ===========================================================================
# S2 relevance search -> normalized JSON array on stdout.
_s2_search() {
    local q="$1" limit="$2" year="$3" key="$4"
    local url="$S2_API/paper/search"
    local fields="title,year,venue,authors,externalIds,abstract,citationCount,url"
    local args=(-sS --max-time 40 -G "$url"
        --data-urlencode "query=$q"
        --data-urlencode "limit=$limit"
        --data-urlencode "fields=$fields"
        -H "x-api-key: $key")
    [[ -n "$year" ]] && args+=(--data-urlencode "year=${year/:/-}")
    local resp; resp=$(curl "${args[@]}" 2>/dev/null) || { note "S2: request failed"; return 1; }
    if ! printf '%s' "$resp" | jq -e '.data' >/dev/null 2>&1; then
        local msg; msg=$(printf '%s' "$resp" | jq -r '.error // .message // "unexpected response"' 2>/dev/null || echo "unexpected response")
        note "S2: $msg"; return 1
    fi
    printf '%s' "$resp" | jq '[.data[] | {
        source: "s2",
        id: .paperId,
        title: .title,
        year: .year,
        venue: .venue,
        doi: (.externalIds.DOI // null),
        pmid: (.externalIds.PubMed // null),
        citations: .citationCount,
        url: .url,
        authors: ([.authors[]?.name] | join(", "))
    }]'
}

# ASTA relevance search -> normalized JSON array on stdout.
# MCP JSON-RPC (tools/call search_papers_by_relevance) over an SSE response.
# The result is `.result.content[]`, ONE {type,text} item per paper, each
# `.text` a JSON paper object. A `fields` argument is required to get more
# than {paperId,title}; field names mirror Semantic Scholar's graph API.
_asta_search() {
    local q="$1" limit="$2" key="$3"
    local body
    body=$(jq -n --arg k "$q" --argjson l "$limit" \
        '{jsonrpc:"2.0", id:1, method:"tools/call",
          params:{name:"search_papers_by_relevance",
                  arguments:{keyword:$k, limit:$l,
                             fields:"title,year,venue,authors,externalIds,citationCount,url"}}}')
    local resp
    resp=$(curl -sS --max-time 60 -X POST "$ASTA_API" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "x-api-key: $key" \
        -d "$body" 2>/dev/null) || { note "ASTA: request failed"; return 1; }
    # SSE: take the JSON payload of the last `data:` event.
    local data
    data=$(printf '%s\n' "$resp" | sed -nE 's/^data:[[:space:]]*(.+)$/\1/p' | tail -1)
    [[ -z "$data" ]] && { note "ASTA: no result event (heartbeat-only stream — key rejected or empty?)"; return 1; }
    if printf '%s' "$data" | jq -e '.error' >/dev/null 2>&1; then
        note "ASTA: $(printf '%s' "$data" | jq -r '.error.message // "error"')"; return 1
    fi
    printf '%s' "$data" | jq '[ .result.content[]?.text | fromjson ] | [.[] | {
        source: "asta",
        id: .paperId,
        title: .title,
        year: .year,
        venue: .venue,
        doi: (.externalIds.DOI // null),
        pmid: (.externalIds.PubMed // null),
        citations: .citationCount,
        url: (.url // null),
        authors: ([.authors[]?.name] | join(", "))
    }]' 2>/dev/null || { note "ASTA: could not parse result"; return 1; }
}

# PubMed relevance search -> normalized JSON array on stdout.
# esearch (sort=relevance) for PMIDs, then one esummary call for metadata.
# A query with no hits is a SUCCESS with []; an API error is a note + rc 1.
_pubmed_search() {
    local q="$1" limit="$2" year="$3"
    local args=(db=pubmed "term=$q" retmode=json "retmax=$limit" sort=relevance)
    if [[ -n "$year" ]]; then
        local a="${year%%:*}" b="${year##*:}"
        args+=(datetype=pdat "mindate=${a:-1800}" "maxdate=${b:-3000}")
    fi
    local resp; resp=$(_ncbi_get esearch "${args[@]}") || return 1
    if ! printf '%s' "$resp" | jq -e '.esearchresult.idlist' >/dev/null 2>&1; then
        note "PubMed: esearch: $(printf '%s' "$resp" | jq -r '.esearchresult.ERROR // .error // "unexpected response"' 2>/dev/null)"
        return 1
    fi
    local ids; ids=$(printf '%s' "$resp" | jq -r '.esearchresult.idlist | join(",")')
    [[ -z "$ids" ]] && { printf '[]'; return 0; }
    _pubmed_summaries "$ids"
}

cmd_search() {
    local q="" source="" limit=10 year="" human=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source="$2"; shift 2 ;;
            --limit)  limit="$2";  shift 2 ;;
            --year)   year="$2";   shift 2 ;;
            --human)  human=1; shift ;;
            --*) die "unknown flag: $1" ;;
            *) [[ -z "$q" ]] && q="$1" || q="$q $1"; shift ;;
        esac
    done
    [[ -n "$q" ]] || die "usage: ng lit search \"<query>\" [--source pubmed|s2|asta|both|all] [--limit N] [--year A:B] [--human]"
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]] || die "--limit must be a positive integer"

    local s2key astakey; s2key="$(_lit_key s2)"; astakey="$(_lit_key asta)"
    # Default: the keyed backends that are configured; PubMed when none is.
    if [[ -z "$source" ]]; then
        if [[ -n "$s2key" && -n "$astakey" ]]; then source=both
        elif [[ -n "$s2key" ]]; then source=s2
        elif [[ -n "$astakey" ]]; then source=asta
        else source=pubmed
        fi
    fi
    local want_pm=0 want_s2=0 want_asta=0
    case "$source" in
        pubmed) want_pm=1 ;;
        s2)     want_s2=1 ;;
        asta)   want_asta=1 ;;
        both)   want_s2=1; want_asta=1 ;;
        all)    want_pm=1; want_s2=1; want_asta=1 ;;
        *) die "--source must be pubmed|s2|asta|both|all" ;;
    esac
    if [[ $want_pm -eq 0 && ( $want_s2 -eq 0 || -z "$s2key" ) && ( $want_asta -eq 0 || -z "$astakey" ) ]]; then
        note "no requested backend is configured ($source); PubMed needs no key: --source pubmed"
        _setup_refs; return 3
    fi

    local results="[]" used=() skipped=() r
    if [[ $want_pm -eq 1 ]]; then
        _ncbi_init
        if r=$(_pubmed_search "$q" "$limit" "$year"); then
            results=$(jq -n --argjson a "$results" --argjson b "$r" '$a + $b'); used+=(pubmed)
        fi
    fi
    if [[ $want_s2 -eq 1 ]]; then
        if [[ -n "$s2key" ]]; then
            if r=$(_s2_search "$q" "$limit" "$year" "$s2key"); then
                results=$(jq -n --argjson a "$results" --argjson b "$r" '$a + $b'); used+=(s2)
            fi
        else
            skipped+=("s2 (no key — set S2_API_KEY or lit.s2_api_key)")
        fi
    fi
    if [[ $want_asta -eq 1 ]]; then
        if [[ -n "$astakey" ]]; then
            if r=$(_asta_search "$q" "$limit" "$astakey"); then
                results=$(jq -n --argjson a "$results" --argjson b "$r" '$a + $b'); used+=(asta)
            fi
        else
            skipped+=("asta (no key — set ASTA_API_KEY or lit.asta_api_key)")
        fi
    fi

    # Annotate in_library by DOI or PMID (jq --arg is portable; --rawfile is
    # 1.6+). Then drop cross-source duplicates — same DOI or same PMID —
    # keeping the FIRST hit, so each backend's relevance order survives.
    local doidata pmiddata; doidata=$(_lib_dois); pmiddata=$(_lib_pmids)
    results=$(jq --arg dois "$doidata" --arg pmids "$pmiddata" '
        def lines: split("\n") | map(select(length>0));
        ($dois | lines) as $have_d | ($pmids | lines) as $have_p
        | map(. + {in_library: (
                ((.doi // "" | ascii_downcase) as $d | ($d != "" and ($have_d | index($d) != null)))
             or ((.pmid // "" | tostring) as $p | ($p != "" and ($have_p | index($p) != null))))})
        | reduce .[] as $x ({seen: {}, out: []}; . as $st
            | ([ ($x.doi // "" | ascii_downcase | select(. != "") | "doi:" + .),
               ($x.pmid // "" | tostring | select(. != "") | "pmid:" + .) ]
             | if length == 0 then ["id:" + ($x.source // "") + ":" + (($x.id // $x.title // "") | tostring)] else . end) as $keys
            | if any($keys[]; $st.seen[.] == true) then .
              else .out += [$x] | reduce $keys[] as $k (.; .seen[$k] = true) end)
        | .out' <<<"$results") || die "internal: could not merge results"

    for s in "${skipped[@]:-}"; do [[ -n "$s" ]] && note "skipped: $s"; done

    if [[ $human -eq 1 ]]; then
        local n; n=$(jq 'length' <<<"$results")
        printf 'Found %s papers (sources: %s)\n\n' "$n" "${used[*]:-none}"
        jq -r 'def short: (. // "" | split(", ")) as $a
                   | if ($a | length) > 6 then ($a[:6] | join(", ")) + ", et al." else ($a | join(", ")) end;
               .[] | "  [\(if .in_library then "IN-LIB" else "new" end)] \(.title)\n      \(.authors | short)\n      \(.venue // "") (\(.year // "n/a"))  cites:\(.citations // "?")  doi:\(.doi // "n/a")\(if .pmid then "  pmid:\(.pmid)" else "" end)  [\(.source)]\n"' <<<"$results"
    else
        jq -n --argjson r "$results" --arg sources "${used[*]:-}" \
              '{query_sources: ($sources | split(" ") | map(select(length>0))), count: ($r|length), results: $r}' <<<""
    fi
    [[ ${#used[@]} -eq 0 ]] && { note "no backend returned results"; return 1; }
    return 0
}

# ===========================================================================
# add
# ===========================================================================
# Build a refs.jsonl record from an S2 paper object (stdin) -> stdout (one line).
_s2_to_ref() {
    jq -c '
        def slug: (.authors[0].name // "anon" | split(" ") | last) + ((.year|tostring) // "");
        {
          id: ((.authors[0].name // "Anon" | split(" ") | last) + ((.year // "") | tostring) + "-s2"),
          doi: (.externalIds.DOI // ""),
          title: (.title // ""),
          authors: [ .authors[]? | (.name // "") | (split(" ")) as $p
                     | {first: ($p[:-1] | join(" ")), last: ($p[-1] // "")} ],
          abstract: (.abstract // ""),
          venue: (.venue // ""),
          published: { year: (.year // null) },
          pdf_path: "",
          source: { type: "s2", id: (.paperId // "") },
          pmid: (.externalIds.PubMed // ""),
          pmcid: (.externalIds.PubMedCentral // "")
        }'
}

# Build a refs.jsonl record from a normalized PubMed summary (stdin, one
# object as produced by _pubmed_summaries) + an abstract ($1) -> one line.
# esummary names read "Lastname Initials"; a CollectiveName is kept whole.
_pubmed_to_ref() {
    jq -c --arg abs "$1" '
        def split_name: if .authtype == "CollectiveName" then {first: "", last: .name}
                        else (.name | split(" ")) as $p
                             | if ($p | length) > 1 then {first: $p[-1], last: ($p[:-1] | join(" "))}
                               else {first: "", last: ($p[0] // "")} end end;
        ([.author_list[]? | split_name]) as $au
        | {
          id: (($au[0].last // "Anon" | if . == "" then "Anon" else . end | split(" ") | last)
               + ((.year // "") | tostring) + "-pubmed"),
          doi: (.doi // ""),
          title: (.title // ""),
          authors: $au,
          abstract: $abs,
          venue: (.venue // ""),
          published: { year: (.year // null) },
          pdf_path: "",
          source: { type: "pubmed", id: .pmid },
          pmid: .pmid,
          pmcid: (.pmcid // "")
        }'
}

# Abstract text for one PMID from efetch XML (plain text; labelled sections
# become "LABEL: text"). Empty on any failure — an abstract is a nicety.
_pubmed_abstract() {
    local xml; xml=$(_ncbi_get efetch db=pubmed "id=$1" retmode=xml) || return 0
    printf '%s' "$xml" | tr '\n' ' ' \
        | sed -n 's:.*<Abstract>\(.*\)</Abstract>.*:\1:p' \
        | sed -e 's:<AbstractText[^>]*Label="\([^"]*\)"[^>]*>:\1\: :g' \
              -e 's:</AbstractText>: :g' -e 's:<[^>]*>::g' \
              -e 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'"'"'/g; s/&amp;/\&/g' \
              -e 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'
}

# Refuse a record already in the library by DOI or PMID. $1=doi $2=pmid.
_lib_has() {
    local doi="${1,,}" pmid="$2"
    [[ -n "$doi"  ]] && _lib_dois  | grep -qxF -- "$doi"  && { printf 'doi:%s' "$doi"; return 0; }
    [[ -n "$pmid" ]] && _lib_pmids | grep -qxF -- "$pmid" && { printf 'pmid:%s' "$pmid"; return 0; }
    return 1
}

_append_ref() {  # $1 = record line, $2 = human flag
    local rec="$1" human="$2" lib; lib="$(_lit_library)"
    mkdir -p "$(dirname "$lib")"
    printf '%s\n' "$rec" >>"$lib"
    if [[ $human -eq 1 ]]; then
        printf 'added to %s\n' "$lib"
        printf '%s\n' "$rec" | jq -r '"  \(.title) (\(.published.year // "n/a"))  doi:\(.doi)\(if .pmid != "" then "  pmid:\(.pmid)" else "" end)"'
    else
        printf '%s\n' "$rec" | jq --arg lib "$lib" '{added:true, library:$lib, ref:.}'
    fi
}

_already() {  # $1 = match ("doi:..."/"pmid:..."), $2 = human flag
    note "already in library ($1) — not added"
    [[ $2 -eq 1 ]] && printf 'already present: %s\n' "$1"
    return 0
}

# PubMed path of `add`: $1 = PMID.
_add_pubmed() {
    local pmid="$1" human="$2" sum
    sum=$(_pubmed_summaries "$pmid") || die "PubMed lookup failed for PMID $pmid"
    sum=$(jq -c --arg p "$pmid" 'map(select(.pmid == $p)) | .[0] // empty' <<<"$sum")
    [[ -n "$sum" ]] || die "PubMed: PMID $pmid not found"
    local doi hit; doi=$(jq -r '.doi // ""' <<<"$sum")
    if hit=$(_lib_has "$doi" "$pmid"); then _already "$hit" "$human"; return 0; fi
    local abs; abs=$(_pubmed_abstract "$pmid")
    _append_ref "$(printf '%s' "$sum" | _pubmed_to_ref "$abs")" "$human"
}

cmd_add() {
    local human=0 pid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --human) human=1; shift ;;
            --*) die "unknown flag: $1" ;;
            *) pid="$1"; shift ;;
        esac
    done
    [[ -n "$pid" ]] || die "usage: ng lit add <DOI|PMID|S2-id> [--human]   (e.g. ng lit add 10.1093/nar/gkac1071, ng lit add 36420896)"
    local s2key; s2key="$(_lit_key s2)"

    # PMID: bare digits or PMID:<digits>. Always PubMed (keyless).
    if [[ "$pid" =~ ^([Pp][Mm][Ii][Dd]:?)?([0-9]+)$ ]]; then
        _ncbi_init; _add_pubmed "${BASH_REMATCH[2]}" "$human"; return
    fi
    local doi=""
    [[ "$pid" =~ ^([Dd][Oo][Ii]:)?(10\..+)$ ]] && doi="${BASH_REMATCH[2]}"

    # DOI without an S2 key: resolve it to a PMID through PubMed.
    if [[ -z "$s2key" ]]; then
        if [[ -z "$doi" ]]; then
            note "an S2 paper id needs an S2 key; pass a DOI or PMID to use PubMed (keyless)"
            _setup_refs; return 3
        fi
        _ncbi_init
        local resp ids
        resp=$(_ncbi_get esearch db=pubmed "term=\"$doi\"[doi]" retmode=json retmax=2) \
            || die "PubMed DOI lookup failed"
        ids=$(printf '%s' "$resp" | jq -r '.esearchresult.idlist // [] | join(" ")' 2>/dev/null)
        case "$ids" in
            "") die "DOI $doi not found in PubMed (non-biomedical papers need an S2 key: ng lit setup)" ;;
            *" "*) die "DOI $doi matches several PubMed records ($ids); add by PMID" ;;
        esac
        _add_pubmed "$ids" "$human"; return
    fi

    # S2 path. Normalize: bare DOI -> DOI:..., else pass through (S2 id, CorpusId:, etc.)
    local lookup="$pid"
    [[ -n "$doi" ]] && lookup="DOI:$doi"
    local fields="title,year,venue,authors,externalIds,abstract,paperId"
    local resp
    resp=$(curl -sS --max-time 40 -G "$S2_API/paper/$lookup" \
        --data-urlencode "fields=$fields" -H "x-api-key: $s2key" 2>/dev/null) \
        || die "S2 lookup failed"
    if ! printf '%s' "$resp" | jq -e '.paperId' >/dev/null 2>&1; then
        die "S2: $(printf '%s' "$resp" | jq -r '.error // .message // "not found"' 2>/dev/null)"
    fi

    local sdoi spmid hit
    sdoi=$(printf '%s' "$resp" | jq -r '.externalIds.DOI // "" | ascii_downcase')
    spmid=$(printf '%s' "$resp" | jq -r '.externalIds.PubMed // "" | tostring')
    if hit=$(_lib_has "$sdoi" "$spmid"); then _already "$hit" "$human"; return 0; fi
    _append_ref "$(printf '%s' "$resp" | _s2_to_ref)" "$human"
}

# ===========================================================================
# dispatch
# ===========================================================================
main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        status)        cmd_status "$@" ;;
        search)        cmd_search "$@" ;;
        add)           cmd_add    "$@" ;;
        setup)         _setup_refs; exit 0 ;;
        ""|-h|--help)
            sed -n '3,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' ; exit 0 ;;
        *) die "unknown lit subcommand: $sub (status|search|add|setup)" ;;
    esac
}
main "$@"
