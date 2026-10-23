#!/usr/bin/env bash
# _api_hold.sh — the API-UNREACHABLE hold: a whole-workspace STATE, not a
# per-window alert, with a WATCHER-driven resume that needs no model turn.
# your-org/nexus-code#1845.
#
# ============================================================================
# THE DEFECT THIS CLOSES
# ============================================================================
#
# 2026-10-15, 08:00-12:46 PDT: the agents' resolver could not resolve the
# Claude API host. Every turn on the board, the orchestrator's included, ended
#
#     API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)
#
# and nothing resumed them for ~5 h. The watcher stayed up and classified the
# crashed workers correctly (`interrupted … recovery=paste`, "PASTE a resume
# nudge"), but the only actor that pastes on that verdict is the ORCHESTRATOR,
# which was down for the same reason. The outage disabled its own remedy — the
# self-latching shape of #1567 G2. Each worker idled until a human noticed.
#
# The nexus already treats two whole-workspace conditions as states: the usage
# limit (`_over_limit.sh`) and a logged-out orchestrator (`_auth_hold.sh`).
# This is the third, and it is modelled on those two.
#
# ============================================================================
# THE SENSOR — the TYPED StopFailure marker, not a transcript walk
# ============================================================================
#
# The issue proposed counting `isApiErrorMessage` transcript records. This
# module reads the typed marker instead, and the reasons are measured:
#
#   * The harness fires `StopFailure` for this failure. Over the 2026-10-15
#     outage `monitor/.state/stopfailure-raw-captures.jsonl` holds 35
#     EAI_AGAIN payloads (the issue counted 37 transcript records), each
#     `"error":"server_error"` with the copy above in `last_assistant_message`,
#     from the orchestrator's session and the workers' alike.
#   * `hooks/turn-failure-emit.sh` already turns that payload into
#     `$STATE_DIR/turn-failure/<window>.json`, KEYED BY WINDOW — which is what
#     the resume needs, and which a transcript record is not (a session id has
#     to be mapped back to a window, and that map is the fragile part).
#   * Reading N small files on the 10 s task is cheap; walking the transcript
#     tree on the filer every cycle is the load the 2026-10 RO incidents
#     correlate with.
#
# COVERAGE BOUNDARY, stated: a session launched BY HAND, with no nexus hooks,
# writes no marker and is invisible to this sensor. Every spawned worker and
# the respawned orchestrator carry the hook (`worker-settings.json`,
# `orchestrator-settings.json`).
#
# THE CLASS, NOT ONE STRING. The marker's `category` is `transient` for both a
# DNS failure and an Anthropic 5xx (the token is `server_error` for both), and
# `category` is a field other modules SELECT on (`_idle_probe.sh`, liveness),
# so re-labelling it would be a behaviour change in every reader (#1050). The
# transport class is therefore computed HERE, from the marker's `error` and
# `last_msg`, by the pure `cause_classify_class` in `hooks/_cause_classify.sh`:
# `transport` | `server` | `other`. Only `transport` enters this hold; an
# Anthropic-side outage classifies `server` and keeps its existing owner.
#
# ENTRY: transport-class markers newer than the last hold's exit, written
# within `signal_window_seconds`, from >= `min_sessions` distinct sessions — OR
# from the orchestrator's own window alone (it is the one session whose crash
# removes the remedy).
#
# ============================================================================
# EXIT — a watcher-side PROBE that needs no model turn
# ============================================================================
#
# TWO PROBES, either answering is reachable (`_api_hold_probe_both`): curl uses
# the SYSTEM resolver; a `node` connect inherits `NODE_OPTIONS` (or
# `monitor.watcher.api_hold.probe_node_options`) and tries BOTH of Node's
# resolution paths, `dns.lookup` (libc getaddrinfo, which IGNORES
# `dns.setServers`) and `dns.resolve4/6` (c-ares, which honours it). On
# 2026-10-15 the operator's working fix was a `dns.setServers` override, which
# curl could never have seen (skeptic ncbundle29-sk F2) and which a plain
# `https.get` — it resolves through `dns.lookup` — could not see either
# (skeptic delta F2b: under a blackhole `setServers`, `dns.lookup` and the
# round-2 probe still answered while `dns.resolve4` timed out). Whether
# Claude Code itself resolves through `lookup` or `resolve*` is NOT measured
# here; trying both errs toward an EARLY release, the side this module
# chooses (one round of nudges, never a stranded window). REMAINING LIMIT: the node probe sees the override only if
# it reaches the WATCHER's environment, or the knob names it. An override set
# only in the agents' shells is still invisible to both probes. Then the hold
# ends by the board (a crashed window completes a turn, or the orchestrator
# does, EXIT 2 and 3 in `_api_hold_step`), or at the ceiling.
#
# `_api_hold_probe_curl` resolves and connects to the configured API endpoint
# (`ANTHROPIC_BASE_URL`, else https://api.anthropic.com) with `curl`, bounded
# by `--max-time` AND an outer `timeout`. ANY HTTP status is "reachable" — an
# unauthenticated GET answers 404 and that proves resolution, TCP and TLS,
# which is exactly the path the turns lost. Classified by curl's rc as a SET:
# 5/6 dns, 7 connect, 28 timeout, 35/52/56/60 tls-or-reset → unreachable;
# 0 → reachable; anything else, and the outer timeout's own vocabulary
# (124/125/126/127/137/143), → `probe-error`, which is NOT a verdict and
# neither enters nor exits anything. Without curl it falls back to
# `getent hosts` (DNS only) plus a bash `/dev/tcp` connect.
#
# The probe runs in an ASYNC task (`api_hold_probe`), so a resolver timeout
# never stalls the watcher's sync loop; the cheap sync step reads its last
# result. It runs only while a hold is open.
#
# A SECOND EXIT, from the board itself: a recorded window whose marker has
# been CLEARED. The `Stop` hook removes the marker only on a successful turn,
# so its absence is a session that reached the API. That covers a probe whose
# route differs from the agents' (a resolver override in one of them, say).
#
# ============================================================================
# WHILE HELD
# ============================================================================
#
#   * EMITS ARE HELD on main.sh's existing ladder, as a FOURTH arm beside
#     over-limit and the login hold — and that placement is the design, for
#     the five reasons `_auth_hold.sh`'s header gives: the archive is already
#     on disk, the dedup anchor does not move (so the body re-composes), and
#     request ids and one-shots stay due. A paste into a session that cannot
#     reach the API starts a turn that fails again and CONSUMES the emit.
#   * orchestrator-liveness files NO resubmit and NO respawn. A silent
#     orchestrator during the outage is not a dead one, and a respawned one
#     cannot reach the API either (the `_auth_hold` reasoning, #1517).
#   * `_idle_probe.sh` does not promote a crashed worker to `idle-too-long`
#     (a CLOSE candidate) while it is in the hold's crashed set awaiting its
#     nudge, and the `interrupted` row says the watcher owns the resume, so
#     the orchestrator does not paste a second one.
#   * THE CRASHED SET is recorded: window, marker ts, prompt id (when the hook
#     carried one), class.
#   * THE OPERATOR is told by the turn-independent legs (`_operator_alert`,
#     key `api-unreachable`): raised on entry and on its own reminder cadence;
#     its network legs need DNS too, so their failure is recorded by that
#     module as failed. A SUMMARY alert is QUEUED in this module's own ledger
#     as `UNSENT` and handed to `_operator_alert notify` on the first positive
#     probe — and recorded `handed-off`, never `sent`, because delivery is
#     that module's record to make (#1548, #1551).
#
# ============================================================================
# THE RESUME — pasted by the WATCHER, orchestrator FIRST
# ============================================================================
#
# On exit, one nudge per recorded window per hold, through the same
# `paste_with_retry` every emit uses, after these gates (each re-probed at
# delivery, as `_orphan_async.sh` does):
#
#   * the window is still live (pane-state rc 3 → `gone`);
#   * its marker still stands (absent → `recovered`: a successful turn ran);
#   * `queued=1` → skip (input is already waiting; #1065's double delivery);
#   * `input=typed` → skip (an operator draft; a paste merges into it and the
#     Enter submits it, #1674) — and `input=?` likewise, the undecidable case
#     CLAUDE.md says to treat as a draft;
#   * `state=` must be one in which the turn is over and the box empty
#     (`idle`, `autosuggest-only`); anything else is recorded and skipped;
#   * at most one nudge per window per hold, and never two to one window
#     inside `nudge_min_interval_seconds` across holds, so a flapping API
#     cannot turn this into a paste storm.
#
# The ORCHESTRATOR's nudge carries the summary: the outage window, the workers
# about to be nudged and the ones skipped with the reason. A non-crashed
# orchestrator gets the summary without the "your last turn did not complete"
# sentence, which would be false for it.
#
# A bare Enter is NOT a resume: measured in `_unstick.sh`'s Case C tombstone
# (2.1.284), an Enter on the empty prompt after an API error sends no request;
# typed text + Enter does. So the nudge is text.
#
# ============================================================================
# POLARITY
# ============================================================================
#
# Here the costly act is HOLDING (an unread board), so every form of
# not-knowing RELEASES `_api_hold_active`: knob off, no row, unparseable row,
# a row the step has not refreshed within `staleness_seconds`, past
# `max_hold_seconds`. Past the ceiling the gates fail open but the crashed set
# is kept, so the nudges still go out on recovery.
#
# ============================================================================
# INJECTION CONTRACTS (tests replace these)
# ============================================================================
#
#   _API_HOLD_LOG_FN             <message>                     (default no-op)
#   _API_HOLD_ALERT_FN           <message> — the attention bell (default no-op)
#   _API_HOLD_OPERATOR_ALERT_FN  `_operator_alert`'s verbs      (default no-op)
#   _API_HOLD_PROBE_FN           → `<verdict>\t<detail>`        (default: curl AND
#                                node, either reachable → reachable)
#   _API_HOLD_PANE_FN            <window> → pane-state line; rc is pane-state's
#                                (3 = not a live window)        (default real)
#   _API_HOLD_PASTE_FN           <window> <body-file> → rc      (default no-op
#                                rc 1: a module sourced without a paster must
#                                never claim a delivery)

_api_hold_log_noop() { :; }
_api_hold_alert_noop() { :; }
_api_hold_operator_alert_noop() { [[ "${1:-}" == standing ]] && return 1; return 0; }
_api_hold_paste_noop() { return 1; }
_API_HOLD_LOG_FN="${_API_HOLD_LOG_FN:-_api_hold_log_noop}"
_API_HOLD_ALERT_FN="${_API_HOLD_ALERT_FN:-_api_hold_alert_noop}"
_API_HOLD_OPERATOR_ALERT_FN="${_API_HOLD_OPERATOR_ALERT_FN:-_api_hold_operator_alert_noop}"
_API_HOLD_PROBE_FN="${_API_HOLD_PROBE_FN:-_api_hold_probe_both}"
_API_HOLD_PANE_FN="${_API_HOLD_PANE_FN:-_api_hold_pane}"
_API_HOLD_PASTE_FN="${_API_HOLD_PASTE_FN:-_api_hold_paste_noop}"

_API_HOLD_ALERT_KEY="api-unreachable"

# The pure classifier lives with its sibling in hooks/ so the hook and this
# module cannot disagree on what "transport" means.
if ! declare -F cause_classify_class >/dev/null 2>&1; then
    # shellcheck source=../hooks/_cause_classify.sh
    . "$(dirname "${BASH_SOURCE[0]}")/../hooks/_cause_classify.sh" 2>/dev/null || true
fi

# ---- state substrate ------------------------------------------------------
#
#   api-hold.tsv           ONE row while held:
#                          <hold_id>\t<entered>\t<t0_first_failure>\t<last_step>\t<orch_crashed 0|1>
#   api-hold-crashed.tsv   <window>\t<marker_ts>\t<prompt_id|->\t<class>\t<session|->
#                          for the CURRENT hold; rewritten, never appended blind
#   api-hold-probe.tsv     <epoch>\t<verdict>\t<detail> — the async probe's last answer
#   api-hold-nudged.tsv    <window>\t<hold_id>\t<epoch>\t<outcome> — append-only ledger
#   api-hold-last-exit     <epoch> of the last exit: older markers cannot re-enter
#   api-hold-alerts.tsv    <hold_id>\t<kind>\t<state UNSENT|handed-off>\t<epoch>
#   api-hold.log           human-readable event ledger (entry, exit, each nudge)
#
# Separate files rather than columns on any existing state file: a value
# written into a field something else MATCHES on is a behavioural change
# (#1050), and nothing should have to learn to skip an api-hold row.

_api_hold_path()          { printf '%s/api-hold.tsv' "${STATE_DIR:-.}"; }
_api_hold_crashed_path()  { printf '%s/api-hold-crashed.tsv' "${STATE_DIR:-.}"; }
_api_hold_probe_path()    { printf '%s/api-hold-probe.tsv' "${STATE_DIR:-.}"; }
_api_hold_nudged_path()   { printf '%s/api-hold-nudged.tsv' "${STATE_DIR:-.}"; }
_api_hold_exit_path()     { printf '%s/api-hold-last-exit' "${STATE_DIR:-.}"; }
_api_hold_alerts_path()   { printf '%s/api-hold-alerts.tsv' "${STATE_DIR:-.}"; }
_api_hold_ledger_path()   { printf '%s/api-hold.log' "${STATE_DIR:-.}"; }
_api_hold_ceiling_stamp() { printf '%s/api-hold-ceiling.stamp' "${STATE_DIR:-.}"; }
_api_hold_tf_dir()        { printf '%s/turn-failure' "${STATE_DIR:-.}"; }

# ---- knobs ----------------------------------------------------------------
#
# Every number below is one WE CHOSE (bridged from config in `_config.sh`,
# where each is labelled), not a vendor default.

_api_hold_enabled() {
    case "${MONITOR_API_HOLD_ENABLED:-true}" in
        false|0|no|off|FALSE|NO|OFF) return 1 ;;
    esac
    return 0
}
_api_hold_int() { local v="$1" d="$2"; [[ "$v" =~ ^[0-9]+$ ]] || v="$d"; printf '%s' "$v"; }
_api_hold_signal_window()   { _api_hold_int "${MONITOR_API_HOLD_SIGNAL_WINDOW_SECONDS:-600}" 600; }
_api_hold_min_sessions()    { _api_hold_int "${MONITOR_API_HOLD_MIN_SESSIONS:-2}" 2; }
_api_hold_probe_interval()  { _api_hold_int "${MONITOR_API_HOLD_PROBE_INTERVAL_SECONDS:-60}" 60; }
_api_hold_probe_timeout()   { _api_hold_int "${MONITOR_API_HOLD_PROBE_TIMEOUT_SECONDS:-10}" 10; }
_api_hold_max_hold()        { _api_hold_int "${MONITOR_API_HOLD_MAX_HOLD_SECONDS:-43200}" 43200; }
_api_hold_staleness()       { _api_hold_int "${MONITOR_API_HOLD_STALENESS_SECONDS:-600}" 600; }
_api_hold_nudge_interval()  { _api_hold_int "${MONITOR_API_HOLD_NUDGE_MIN_INTERVAL_SECONDS:-900}" 900; }
_api_hold_probe_url() {
    local u="${MONITOR_API_HOLD_PROBE_URL:-}"
    [[ -n "$u" ]] || u="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
    printf '%s' "$u"
}

_api_hold_ts() { date -Is -d "@$1" 2>/dev/null || printf '%s' "$1"; }

_api_hold_ledger() {   # <message>
    local p; p=$(_api_hold_ledger_path)
    printf '%s\t%s\n' "$(date -Is 2>/dev/null || date)" "$1" >> "$p" 2>/dev/null || true
}

# ---- marker reading -------------------------------------------------------
#
# Prints one row per TRANSPORT-class marker:
#   <window>\t<ts>\t<prompt_id|->\t<class>\t<session|->
# for every marker whose ts is within [now - window, now] and strictly newer
# than <after>. jq is REQUIRED; without it the sensor reports nothing, which is
# the pre-#1845 behaviour (fail toward not holding), and says so once per run.
_API_HOLD_NOJQ_SAID=0
_api_hold_scan_markers() {   # <now> <after_epoch>
    local now="$1" after="${2:-0}" dir win lo f row ts err msg pid sid cls name
    dir=$(_api_hold_tf_dir)
    [[ -d "$dir" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        if (( _API_HOLD_NOJQ_SAID == 0 )); then
            _API_HOLD_NOJQ_SAID=1
            "$_API_HOLD_LOG_FN" "api-hold: jq is unavailable, so the turn-failure markers cannot be read — the API-unreachable sensor is OFF for this run (fails toward NOT holding, the pre-#1845 behaviour)"
        fi
        return 0
    fi
    declare -F cause_classify_class >/dev/null 2>&1 || return 0
    win=$(_api_hold_signal_window)
    lo=$(( now - win ))
    # `find -maxdepth 1`, not a glob: no nullglob dependence, and a dir of
    # dotfile temporaries (the hook's `.<window>.<pid>.tmp`) is excluded by name.
    while IFS= read -r -d '' f; do
        name=${f##*/}; name=${name%.json}
        row=$(jq -r '[(.ts // "" | tostring), (.error // ""), (.last_msg // ""), (.prompt_id // ""), (.session_id // "")] | @tsv' "$f" 2>/dev/null) || continue
        IFS=$'\t' read -r ts err msg pid sid <<<"$row"
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        (( ts >= lo && ts <= now + 60 )) || continue
        (( ts > after )) || continue
        cls=$(cause_classify_class "$err" "$msg")
        [[ "$cls" == transport ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$ts" "${pid:--}" "$cls" "${sid:--}"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.json' ! -name '.*' -print0 2>/dev/null)
    return 0
}

# rc 0 iff <window>'s marker still stands AND is transport-class. A cleared
# marker is a session whose last turn SUCCEEDED (the Stop hook removes it).
_api_hold_marker_stands() {   # <window>
    local f row err msg
    f="$(_api_hold_tf_dir)/$1.json"
    [[ -f "$f" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 0
    row=$(jq -r '[(.error // ""), (.last_msg // "")] | @tsv' "$f" 2>/dev/null) || return 0
    IFS=$'\t' read -r err msg <<<"$row"
    [[ "$(cause_classify_class "$err" "$msg")" == transport ]]
}

# The signal: rc 0 iff the scanned rows satisfy the entry predicate. Reads the
# rows on stdin (so the step scans ONCE and decides from one snapshot).
_api_hold_signal_fires() {   # <target> < rows
    local target="${1:-}" min sessions=0 orch=0 w ts pid cls sid
    local -A seen=()
    min=$(_api_hold_min_sessions)
    while IFS=$'\t' read -r w ts pid cls sid; do
        [[ -n "$w" ]] || continue
        [[ -n "$target" && "$w" == "$target" ]] && orch=1
        local k="${sid:--}"; [[ "$k" == - ]] && k="w:$w"
        [[ -n "${seen[$k]:-}" ]] && continue
        seen[$k]=1; sessions=$(( sessions + 1 ))
    done
    (( orch == 1 )) && return 0
    (( sessions >= min ))
}

# ---- the probe ------------------------------------------------------------
#
# Prints `<verdict>\t<detail>`: reachable | unreachable | probe-error. The rc of
# the tool is classified as a SET (CLAUDE.md, timeout-status injection): the
# outer `timeout`'s own codes are a WRAPPER status and never a verdict.
_api_hold_probe_curl() {
    local url host port to rc out
    url=$(_api_hold_probe_url)
    to=$(_api_hold_probe_timeout)
    if command -v curl >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        out=$(timeout -k 2 $(( to + 5 )) curl -sS -o /dev/null -w '%{http_code}' \
                --connect-timeout "$to" --max-time "$to" "$url" 2>/dev/null); rc=$?
        case "$rc" in
            0)              printf 'reachable\thttp=%s url=%s' "${out:-?}" "$url" ;;
            5|6)            printf 'unreachable\tdns curl_rc=%s url=%s' "$rc" "$url" ;;
            7)              printf 'unreachable\tconnect curl_rc=%s url=%s' "$rc" "$url" ;;
            28)             printf 'unreachable\ttimeout curl_rc=%s url=%s' "$rc" "$url" ;;
            35|52|56|60)    printf 'unreachable\ttls-or-reset curl_rc=%s url=%s' "$rc" "$url" ;;
            124|125|126|127|137|143)
                            printf 'probe-error\twrapper rc=%s (the outer timeout, not curl) url=%s' "$rc" "$url" ;;
            *)              printf 'probe-error\tcurl_rc=%s url=%s' "$rc" "$url" ;;
        esac
        return 0
    fi
    # Fallback: resolution, then a bare TCP connect. No TLS, so a reachable
    # verdict here is weaker; it says so in the detail.
    host=${url#*://}; host=${host%%/*}; port=443
    [[ "$host" == *:* ]] && { port=${host##*:}; host=${host%%:*}; }
    [[ "$url" == http://* && "$port" == 443 ]] && port=80
    command -v getent >/dev/null 2>&1 || { printf 'probe-error\tneither curl+timeout nor getent available'; return 0; }
    command -v timeout >/dev/null 2>&1 || { printf 'probe-error\ttimeout unavailable; an unbounded probe is refused'; return 0; }
    timeout -k 2 "$to" getent hosts "$host" >/dev/null 2>&1; rc=$?
    case "$rc" in
        0) ;;
        2) printf 'unreachable\tdns getent_rc=2 host=%s' "$host"; return 0 ;;
        124|125|126|127|137|143) printf 'unreachable\tdns-timeout wrapper_rc=%s host=%s' "$rc" "$host"; return 0 ;;
        *) printf 'probe-error\tgetent_rc=%s host=%s' "$rc" "$host"; return 0 ;;
    esac
    timeout -k 2 "$to" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" >/dev/null 2>&1; rc=$?
    case "$rc" in
        0) printf 'reachable\ttcp-only host=%s port=%s (no curl: TLS not exercised)' "$host" "$port" ;;
        124|137|143) printf 'unreachable\tconnect-timeout host=%s port=%s' "$host" "$port" ;;
        *) printf 'unreachable\tconnect rc=%s host=%s port=%s' "$rc" "$host" "$port" ;;
    esac
    return 0
}

# The HARNESS's resolution path (skeptic ncbundle29-sk F2). Claude Code is a
# Node program, and on 2026-10-15 the operator's working fix was
# `NODE_OPTIONS="-r ~/force-dns.js"` (`dns.setServers(['8.8.8.8'])`), a
# Node-only resolver override that leaves the system resolver, and so curl,
# failing. This probe connects with `node`, inherits `NODE_OPTIONS` or takes
# `MONITOR_API_HOLD_PROBE_NODE_OPTIONS`, and runs one request through each of
# Node's resolution paths: `dns.lookup` ignores `setServers`, so a
# `setServers` override reaches only the `dns.resolve*` request (F2b).
# Either answering is reachable. Same verdict vocabulary.
_api_hold_probe_node() {
    local url to rc out nopts
    url=$(_api_hold_probe_url); to=$(_api_hold_probe_timeout)
    command -v node >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 \
        || { printf 'probe-error\tnode or timeout unavailable'; return 0; }
    nopts="${MONITOR_API_HOLD_PROBE_NODE_OPTIONS:-${NODE_OPTIONS:-}}"
    out=$(NODE_OPTIONS="$nopts" timeout -k 2 $(( to + 5 )) node -e '
        const u = new URL(process.argv[1]), t = Number(process.argv[2]) * 1000;
        const m = u.protocol === "http:" ? require("http") : require("https");
        const dns = require("dns");
        // BOTH resolution paths (skeptic delta F2b, your-org/nexus-code#1847):
        // the default `dns.lookup` is libc getaddrinfo and IGNORES
        // dns.setServers, while `dns.resolve4/6` is c-ares and HONOURS it.
        // An override like force-dns.js reaches only the second. Either
        // answering is reachable.
        const viaResolve = (host, opts, cb) => {
            const done = (a, fam) => opts && opts.all ? cb(null, [{ address: a, family: fam }]) : cb(null, a, fam);
            dns.resolve4(host, (e4, a4) => {
                if (!e4 && a4 && a4.length) return done(a4[0], 4);
                dns.resolve6(host, (e6, a6) => (!e6 && a6 && a6.length) ? done(a6[0], 6) : cb(e4 || e6));
            });
        };
        const errs = [];
        const fail = (path, c) => { errs.push(path + ":" + c); if (errs.length < 2) return;
            console.log("err=" + errs.join(","));
            process.exit(errs.some((x) => /EAI_AGAIN|ENOTFOUND|ESERVFAIL|ENODATA|ETIMEOUT|ECONNREFUSED$/.test(x) && /resolve:|lookup:/.test(x)) ? 6 : 7); };
        for (const [path, opts] of [["lookup", { timeout: t }], ["resolve", { timeout: t, lookup: viaResolve }]]) {
            const r = m.get(u, opts, (res) => { console.log("http=" + res.statusCode + " via=" + path); process.exit(0); });
            r.on("timeout", () => { r.destroy(); fail(path, "TIMEOUT"); });
            r.on("error", (e) => fail(path, e.code || "ERR"));
        }
        setTimeout(() => { console.log("timeout err=" + errs.join(",")); process.exit(28); }, t).unref();
    ' "$url" "$to" 2>/dev/null); rc=$?
    case "$rc" in
        0)     printf 'reachable\tnode %s url=%s' "${out:-?}" "$url" ;;
        6)     printf 'unreachable\tnode-dns %s url=%s' "${out:-?}" "$url" ;;
        7|28)  printf 'unreachable\tnode-connect %s url=%s' "${out:-?}" "$url" ;;
        *)     printf 'probe-error\tnode rc=%s %s url=%s' "$rc" "${out:-}" "$url" ;;
    esac
}

# BOTH routes, and EITHER answering is reachable: the hold exists because the
# agents cannot reach the API, so the question is whether ANY route they could
# be using works. unreachable needs a route to say so with no route answering;
# two probe-errors stay probe-error, which is not a verdict.
_api_hold_probe_both() {
    local a b va vb
    a=$(_api_hold_probe_curl); b=$(_api_hold_probe_node)
    va=${a%%$'\t'*}; vb=${b%%$'\t'*}
    if [[ "$va" == reachable || "$vb" == reachable ]]; then
        printf 'reachable\tcurl[%s] node[%s]' "${a#*$'\t'}" "${b#*$'\t'}"
    elif [[ "$va" == unreachable || "$vb" == unreachable ]]; then
        printf 'unreachable\tcurl[%s] node[%s]' "${a#*$'\t'}" "${b#*$'\t'}"
    else
        printf 'probe-error\tcurl[%s] node[%s]' "${a#*$'\t'}" "${b#*$'\t'}"
    fi
}

# The ASYNC task body. Runs the probe only while a hold is open (a signal
# ENTERS the hold at once, so "a signal stands" is "a hold is open"), and not
# more often than `probe_interval`. Writes atomically.
_api_hold_probe_step() {
    _api_hold_enabled || return 0
    [[ -f "$(_api_hold_path)" ]] || return 0
    local p now last res tmp
    p=$(_api_hold_probe_path)
    now=$(date +%s)
    if [[ -f "$p" ]]; then
        last=$(cut -f1 "$p" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || last=0
        (( now - last >= $(_api_hold_probe_interval) )) || return 0
    fi
    res=$("$_API_HOLD_PROBE_FN")
    [[ -n "$res" ]] || res=$'probe-error\tthe probe printed nothing'
    tmp="${p}.$$.tmp"
    printf '%s\t%s\n' "$(date +%s)" "$res" > "$tmp" 2>/dev/null && mv -f "$tmp" "$p" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
    return 0
}

# Last probe: prints `<epoch>\t<verdict>\t<detail>`, rc 1 when there is none.
_api_hold_probe_last() {
    local p row; p=$(_api_hold_probe_path)
    [[ -f "$p" ]] || return 1
    row=$(head -n 1 "$p" 2>/dev/null)
    [[ "${row%%$'\t'*}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$row"
}

# ---- the gate -------------------------------------------------------------
#
# rc 0 → HOLD (emits, liveness remedies, idle-too-long promotion). rc 1 → do
# not, for ANY reason including every form of not-knowing.
_api_hold_active() {
    local p id entered t0 last_step orch now
    _api_hold_enabled || return 1
    p=$(_api_hold_path)
    [[ -f "$p" ]] || return 1
    IFS=$'\t' read -r id entered t0 last_step orch < "$p" 2>/dev/null || return 1
    [[ "$entered" =~ ^[0-9]+$ && "$last_step" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    (( now - last_step <= $(_api_hold_staleness) )) || return 1
    (( now - entered < $(_api_hold_max_hold) )) || return 1
    return 0
}

# rc 0 iff <window> is in the open hold's crashed set and not yet nudged —
# for `_idle_probe.sh`, which must not promote it to a close candidate. Not
# bounded by the ceiling: past it the gates fail open, but the window is
# still owed its nudge, and closing it would lose the very work held.
# Bounded instead by the row's staleness (a hold nobody steps is no hold).
_api_hold_window_awaiting_nudge() {   # <window>
    local p id entered t0 last_step orch now
    _api_hold_enabled || return 1
    p=$(_api_hold_path)
    [[ -f "$p" ]] || return 1
    IFS=$'\t' read -r id entered t0 last_step orch < "$p" 2>/dev/null || return 1
    [[ "$last_step" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    (( now - last_step <= $(_api_hold_staleness) )) || return 1
    awk -F'\t' -v w="$1" '$1 == w {f=1} END {exit !f}' "$(_api_hold_crashed_path)" 2>/dev/null
}

# One line per window the CURRENT or LAST hold concerns, for the idle render:
#   <window>\t<note>
# Held: "the watcher will paste a resume when the API is back".
# After exit: "the watcher pasted a resume at T" for windows nudged in the
# last hour, so the orchestrator does not paste a second one.
_api_hold_render_notes() {
    _api_hold_enabled || return 0
    local now since p
    now=$(date +%s)
    if _api_hold_active; then
        IFS=$'\t' read -r _ _ since _ _ < "$(_api_hold_path)" 2>/dev/null
        awk -F'\t' -v s="$(_api_hold_ts "${since:-$now}")" \
            '{ printf "%s\tAPI UNREACHABLE since %s (watcher api-hold): the WATCHER pastes the resume when its probe recovers; do NOT paste one now (your-org/nexus-code#1845)\n", $1, s }' \
            "$(_api_hold_crashed_path)" 2>/dev/null
        return 0
    fi
    p=$(_api_hold_nudged_path)
    [[ -f "$p" ]] || return 0
    # A window whose marker is NEWER than its last nudge crashed AGAIN after
    # the resume, so the note must not tell the orchestrator to leave it alone
    # (skeptic ncbundle29-sk F1): it falls back to today's "PASTE a resume" row.
    local w e
    while IFS=$'\t' read -r w e; do
        [[ -n "$w" && "$e" =~ ^[0-9]+$ ]] || continue
        (( $(_api_hold_marker_ts "$w") > e )) && continue
        printf '%s\twatcher api-hold PASTED a resume at epoch %s; do NOT paste another (your-org/nexus-code#1845)\n' "$w" "$e"
    done < <(awk -F'\t' -v now="$now" '
        $4 == "nudged" && now - $3 <= 3600 { last[$1] = $3 }
        END { for (w in last) printf "%s\t%s\n", w, last[w] }' "$p" 2>/dev/null)
}

# The held-emit ledger, mirroring `_auth_hold_record_held`: a hold that mutes
# the operator's channel leaves a record a human can read (#592).
_api_hold_record_held() {   # <archive-basename> <reason>
    printf '%s\theld\tarchive=%s\treason=%s\n' "$(date -Is 2>/dev/null || date)" "$1" "$2" \
        >> "${STATE_DIR:-.}/api-hold-held.log" 2>/dev/null || true
}

# ---- enter / exit -----------------------------------------------------------

_api_hold_write_row() {   # <id> <entered> <t0> <last_step> <orch>
    local p tmp; p=$(_api_hold_path); tmp="${p}.$$.tmp"
    printf '%s\t%s\t%s\t%s\t%s\n' "$@" > "$tmp" 2>/dev/null && mv -f "$tmp" "$p" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
}

# Merge <rows> into the crashed set: one row per window, keeping the NEWEST
# marker ts (a window that crashes again mid-hold is still one window).
_api_hold_merge_crashed() {   # <rows>
    local p tmp; p=$(_api_hold_crashed_path); tmp="${p}.$$.tmp"
    { [[ -f "$p" ]] && cat "$p"; printf '%s\n' "$1"; } 2>/dev/null \
        | awk -F'\t' 'NF >= 2 && $1 != "" { if (!($1 in ts) || $2 > ts[$1]) { ts[$1] = $2; row[$1] = $0 } }
                      END { for (w in row) print row[w] }' \
        | sort > "$tmp" 2>/dev/null && mv -f "$tmp" "$p" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
}

_api_hold_alert_text() {   # <t0> <orch 0|1> <n_windows>
    local who="${3:-?} session(s)"
    (( ${2:-0} == 1 )) && who="the ORCHESTRATOR and ${3:-?} session(s) in all"
    printf 'The Claude API is UNREACHABLE from this nexus (transport-class errors such as EAI_AGAIN since %s; %s crashed). No agent can take a turn. The watcher is HOLDING emits and the orchestrator-liveness remedies, and will paste ONE resume nudge into each crashed window itself when its probe of %s succeeds — no orchestrator turn needed. If this is a site DNS/network problem it is outside the nexus. Ledger: %s (your-org/nexus-code#1845).' \
        "$(_api_hold_ts "$1")" "$who" "$(_api_hold_probe_url)" "$(_api_hold_ledger_path)"
}

_api_hold_enter() {   # <target> <rows> <now>
    local target="$1" rows="$2" now="$3" t0 orch=0 n
    t0=$(printf '%s\n' "$rows" | awk -F'\t' 'NF>=2 {if (m=="" || $2<m) m=$2} END {print m}')
    [[ "$t0" =~ ^[0-9]+$ ]] || t0="$now"
    printf '%s\n' "$rows" | awk -F'\t' -v t="$target" '$1 == t {f=1} END {exit !f}' && orch=1
    : > "$(_api_hold_crashed_path)" 2>/dev/null || true
    _api_hold_merge_crashed "$rows"
    n=$(grep -c . "$(_api_hold_crashed_path)" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
    _api_hold_write_row "$now" "$now" "$t0" "$now" "$orch"
    rm -f "$(_api_hold_ceiling_stamp)" 2>/dev/null || true
    printf '%s\tsummary\tUNSENT\t%s\n' "$now" "$now" >> "$(_api_hold_alerts_path)" 2>/dev/null || true
    local msg="api-hold: ENGAGED — transport-class API errors (first at $(_api_hold_ts "$t0")) in ${n} window(s)$( (( orch )) && printf ', the orchestrator among them'): $(cut -f1 "$(_api_hold_crashed_path)" 2>/dev/null | paste -sd, -). Emits are archived and HELD, orchestrator-liveness files no resubmit/respawn, crashed workers are not promoted to idle-too-long; the watcher will paste one resume per crashed window on the first positive probe of $(_api_hold_probe_url) (your-org/nexus-code#1845). Ceiling $(_api_hold_max_hold)s."
    "$_API_HOLD_LOG_FN" "$msg"
    _api_hold_ledger "$msg"
    "$_API_HOLD_ALERT_FN" "API UNREACHABLE: ${n} agent session(s) crashed on transport errors; the watcher holds emits and will resume them itself on recovery (your-org/nexus-code#1845)"
    "$_API_HOLD_OPERATOR_ALERT_FN" raise "$_API_HOLD_ALERT_KEY" "$( (( orch )) && printf critical || printf warning)" \
        "$(_api_hold_alert_text "$t0" "$orch" "$n")"
}

# ---- delivery ---------------------------------------------------------------

_api_hold_pane() {   # <window> → pane-state line; rc = pane-state's
    local key="$1" idx="" line="" script rc
    if declare -F resolve_window_index >/dev/null 2>&1; then
        idx=$(resolve_window_index "$key" 2>/dev/null) || idx=""
        [[ "$idx" =~ ^[0-9]+$ ]] || idx=""
    fi
    if [[ -n "$idx" ]] && declare -F _pane_cache_read >/dev/null 2>&1; then
        line=$(_pane_cache_read "$idx" "$key") || line=""
    fi
    if [[ -z "$line" ]]; then
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
            script="$NEXUS_ROOT/monitor/pane-state.sh"
        else
            script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/pane-state.sh"
        fi
        [[ -x "$script" ]] || return 127
        line=$("$script" "$key" 2>/dev/null); rc=$?
        (( rc == 0 )) || return "$rc"
    fi
    printf '%s' "$line"
}

# Exact-key field read, on a real whitespace boundary (the `_orphan_async_field`
# lesson: a later token merely ENDING in the name must not shadow the real one).
_api_hold_field() {   # <line> <name>
    awk -v k="$2" '{ for (i = 1; i <= NF; i++) { n = index($i, "=");
        if (n > 0 && substr($i, 1, n - 1) == k) { print substr($i, n + 1); break } } }' <<<"$1"
}

# The pre-delivery gate. Prints `ok` or `skip:<reason>`. Re-run immediately
# before each paste, never trusted from the plan.
_api_hold_delivery_gate() {   # <window> <is_target 0|1>
    local w="$1" is_target="${2:-0}" line rc state input queued
    line=$("$_API_HOLD_PANE_FN" "$w"); rc=$?
    if (( rc == 3 )); then printf 'skip:gone (pane-state: not a live window)'; return 0; fi
    if (( rc != 0 )) || [[ -z "$line" ]]; then printf 'skip:could-not-look (pane-state rc=%s)' "$rc"; return 0; fi
    state=$(_api_hold_field "$line" state)
    input=$(_api_hold_field "$line" input)
    queued=$(_api_hold_field "$line" queued)
    [[ "$queued" == 1 ]] && { printf 'skip:queued=1 (input already waiting behind a turn)'; return 0; }
    case "$input" in
        typed) printf 'skip:input=typed (an operator draft is in the box)'; return 0 ;;
        '?')   printf 'skip:input=? (undecidable box, treated as a draft)'; return 0 ;;
    esac
    case "$state" in
        idle|autosuggest-only) ;;
        *) printf 'skip:state=%s (not an idle, empty prompt)' "${state:-?}"; return 0 ;;
    esac
    printf 'ok'
}

# rc 0 iff <window> is already SATISFIED: nudged for <hold_id>, or nudged inside
# the cross-hold minimum interval AND not crashed again since that nudge.
#
# THE SECOND CLAUSE IS KEYED ON THE WINDOW'S CURRENT CRASH, not on the clock
# alone (skeptic ncbundle29-sk F1, your-org/nexus-code#1847). The first cut
# let any nudge inside the interval satisfy, so a FLAPPING outage stranded the
# board: hold N exits, every window is nudged, every resumed turn fails again,
# hold N+1 opens, the real recovery lands inside 900 s and NO nudge goes out.
# Every marker then predates the exit stamp, nothing re-enters, and the render
# note told the orchestrator "do NOT paste another". A nudge answers the crash
# it was sent for. A marker NEWER than the nudge is a new crash, which the new
# hold owes a nudge whatever the interval says. The interval still bounds the
# case it exists for: a window whose nudged turn has not failed again (its
# marker is no newer than the nudge) is not nudged twice. A storm is bounded by
# the harness itself, because a re-crash takes a whole retry cycle (minutes).
_api_hold_already_nudged() {   # <window> <hold_id> <now> [<current_marker_ts>]
    local p mts="${4:-0}"; p=$(_api_hold_nudged_path)
    [[ -f "$p" ]] || return 1
    [[ "$mts" =~ ^[0-9]+$ ]] || mts=0
    awk -F'\t' -v w="$1" -v id="$2" -v now="$3" -v iv="$(_api_hold_nudge_interval)" -v mts="$mts" '
        $1 == w && $4 == "nudged" && ($2 == id || (now - $3 < iv && mts <= $3)) { f = 1 }
        END { exit !f }' "$p" 2>/dev/null
}

# The ts of <window>'s standing marker, or 0 when it has none.
_api_hold_marker_ts() {   # <window>
    local f ts
    f="$(_api_hold_tf_dir)/$1.json"
    [[ -f "$f" ]] && command -v jq >/dev/null 2>&1 && ts=$(jq -r '.ts // empty' "$f" 2>/dev/null)
    [[ "${ts:-}" =~ ^[0-9]+$ ]] && printf '%s' "$ts" || printf '0'
}

_api_hold_record_nudge() {   # <window> <hold_id> <outcome>
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" "$3" >> "$(_api_hold_nudged_path)" 2>/dev/null || true
    _api_hold_ledger "nudge window=$1 hold=$2 outcome=$3"
}

_api_hold_compose_nudge() {   # <t0> <t1> <crashed 0|1> [summary]
    local t0 t1
    t0=$(_api_hold_ts "$1"); t1=$(_api_hold_ts "$2")
    if (( ${3:-1} == 1 )); then
        printf 'The Claude API was unreachable from %s to %s (transport errors such as EAI_AGAIN), and your last turn did not complete. Re-read your last message and continue where you left off. (Pasted by the nexus watcher, not the operator: your-org/nexus-code#1845.)\n' "$t0" "$t1"
    else
        printf 'The Claude API was unreachable from %s to %s (transport errors such as EAI_AGAIN). Your own last turn completed; this is a status note from the nexus watcher (your-org/nexus-code#1845).\n' "$t0" "$t1"
    fi
    [[ -n "${4:-}" ]] && printf '\n%s\n' "$4"
    return 0
}

# Deliver one nudge. Returns 0 and records the outcome either way.
_api_hold_deliver() {   # <window> <hold_id> <body> <is_target 0|1>
    local w="$1" id="$2" body="$3" is_target="$4" gate f
    gate=$(_api_hold_delivery_gate "$w" "$is_target")
    if [[ "$gate" != ok ]]; then
        _api_hold_record_nudge "$w" "$id" "skipped ${gate#skip:}"
        "$_API_HOLD_LOG_FN" "api-hold: NOT nudging '${w}' — ${gate#skip:}"
        return 0
    fi
    f=$(mktemp "${TMPDIR:-/tmp}/api-hold-nudge.XXXXXX") || { _api_hold_record_nudge "$w" "$id" "failed mktemp"; return 0; }
    printf '%s' "$body" > "$f"
    # Stamp-before-paste (#293): a watcher-initiated input into a WORKER pane
    # must be attributed to the machine, or the window reads operator-engaged.
    (( is_target == 0 )) && declare -F _machine_input_stamp >/dev/null 2>&1 \
        && _machine_input_stamp "$w" "api-hold-resume"
    local rc
    "$_API_HOLD_PASTE_FN" "$w" "$f"; rc=$?
    rm -f "$f" 2>/dev/null || true
    if (( rc == 0 )); then
        _api_hold_record_nudge "$w" "$id" nudged
        "$_API_HOLD_LOG_FN" "api-hold: resume nudge PASTED into '${w}' (hold ${id}; your-org/nexus-code#1845)"
    else
        _api_hold_record_nudge "$w" "$id" "failed paste rc=${rc}"
        "$_API_HOLD_LOG_FN" "api-hold: resume nudge to '${w}' FAILED (paste rc=${rc}); not retried — the orchestrator's next emit carries the window as interrupted"
    fi
    return 0
}

# The resume: orchestrator FIRST, carrying the plan; then each worker, each
# re-gated at delivery. Needs NO orchestrator turn: everything here is the
# watcher's own process writing to tmux.
_api_hold_resume() {   # <target> <hold_id> <t0> <t1> <orch_crashed>
    local target="$1" id="$2" t0="$3" t1="$4" orch="$5" now w g
    local plan_ok="" plan_skip="" summary body
    local -a workers=()
    now=$(date +%s)
    while IFS=$'\t' read -r w _; do
        [[ -n "$w" && "$w" != "$target" ]] || continue
        if _api_hold_already_nudged "$w" "$id" "$now" "$(_api_hold_marker_ts "$w")"; then
            plan_skip+="${plan_skip:+; }${w} (already nudged within $(_api_hold_nudge_interval)s)"
            continue
        fi
        if ! _api_hold_marker_stands "$w"; then
            plan_skip+="${plan_skip:+; }${w} (recovered: its failure marker was cleared by a successful turn)"
            _api_hold_record_nudge "$w" "$id" "skipped recovered"
            continue
        fi
        g=$(_api_hold_delivery_gate "$w" 0)
        if [[ "$g" == ok ]]; then
            plan_ok+="${plan_ok:+, }${w}"; workers+=("$w")
        else
            plan_skip+="${plan_skip:+; }${w} (${g#skip:})"
            _api_hold_record_nudge "$w" "$id" "skipped ${g#skip:}"
        fi
    done < "$(_api_hold_crashed_path)"
    summary="api-hold summary: hold lasted $(( t1 - t0 ))s. The watcher is pasting a resume into: ${plan_ok:-none}. Skipped: ${plan_skip:-none}. Outcomes per window: $(_api_hold_nudged_path)."
    # Orchestrator first. Its own gate is the same, but a non-crashed
    # orchestrator still gets the summary (without the false sentence).
    if [[ -n "$target" ]]; then
        if _api_hold_already_nudged "$target" "$id" "$now" "$(_api_hold_marker_ts "$target")"; then
            "$_API_HOLD_LOG_FN" "api-hold: orchestrator '${target}' already nudged within $(_api_hold_nudge_interval)s; summary goes to the ledger only"
            _api_hold_ledger "$summary"
        else
            body=$(_api_hold_compose_nudge "$t0" "$t1" "$orch" "$summary")
            _api_hold_deliver "$target" "$id" "$body" 1
        fi
    fi
    body=$(_api_hold_compose_nudge "$t0" "$t1" 1)
    for w in "${workers[@]}"; do
        _api_hold_deliver "$w" "$id" "$body" 0
    done
    _api_hold_ledger "$summary"
    return 0
}

_api_hold_exit() {   # <target> <why> <now>
    local target="$1" why="$2" now="$3" p id entered t0 last_step orch n
    p=$(_api_hold_path)
    IFS=$'\t' read -r id entered t0 last_step orch < "$p" 2>/dev/null
    [[ "$id" =~ ^[0-9]+$ ]] || id="$now"
    [[ "$t0" =~ ^[0-9]+$ ]] || t0="$now"
    [[ "$orch" =~ ^[01]$ ]] || orch=0
    n=$(grep -c . "$(_api_hold_crashed_path)" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
    local msg="api-hold: RELEASED (${why}) — API unreachable from $(_api_hold_ts "$t0") to $(_api_hold_ts "$now") ($(( now - t0 ))s), ${n} crashed window(s); pasting the resume nudges now, orchestrator first"
    "$_API_HOLD_LOG_FN" "$msg"
    _api_hold_ledger "$msg"
    # Release the gates BEFORE pasting, so a nudge is not itself held, and stamp
    # the exit so the markers this hold already counted cannot re-enter it.
    printf '%s\n' "$now" > "$(_api_hold_exit_path)" 2>/dev/null || true
    rm -f "$p" "$(_api_hold_ceiling_stamp)" 2>/dev/null || true
    _api_hold_resume "$target" "$id" "$t0" "$now" "$orch"
    rm -f "$(_api_hold_crashed_path)" 2>/dev/null || true
    # The queued summary alert: handed to the operator-alert module NOW, when
    # the probe has just shown the network works. Recorded `handed-off`, never
    # `sent`: whether a leg delivered is `_operator_alert`'s record.
    local nudged skipped
    nudged=$(awk -F'\t' -v id="$id" '$2 == id && $4 == "nudged" {print $1}' "$(_api_hold_nudged_path)" 2>/dev/null | paste -sd, -)
    skipped=$(awk -F'\t' -v id="$id" '$2 == id && $4 ~ /^(skipped|failed)/ {print $1 " (" $4 ")"}' "$(_api_hold_nudged_path)" 2>/dev/null | paste -sd';' -)
    "$_API_HOLD_OPERATOR_ALERT_FN" clear "$_API_HOLD_ALERT_KEY" "the API answers again (${why})"
    "$_API_HOLD_OPERATOR_ALERT_FN" notify api-unreachable-resolved warning \
        "The Claude API was unreachable from $(_api_hold_ts "$t0") to $(_api_hold_ts "$now") ($(( now - t0 ))s). The watcher pasted a resume nudge into: ${nudged:-none}. Not nudged: ${skipped:-none}. Ledger: $(_api_hold_ledger_path) (your-org/nexus-code#1845)."
    awk -F'\t' -v OFS='\t' -v id="$id" -v now="$now" \
        '$1 == id && $2 == "summary" && $3 == "UNSENT" { $3 = "handed-off"; $4 = now } { print }' \
        "$(_api_hold_alerts_path)" > "$(_api_hold_alerts_path).tmp" 2>/dev/null \
        && mv -f "$(_api_hold_alerts_path).tmp" "$(_api_hold_alerts_path)" 2>/dev/null
    rm -f "$(_api_hold_alerts_path).tmp" 2>/dev/null || true
    return 0
}

# ---- the step ---------------------------------------------------------------
#
# One call per watcher cycle (sync, cheap: a marker-dir read and a file read).
# Returns 0 always.
_api_hold_step() {
    local target="${1:-}" now after rows p id entered t0 last_step orch probe pts verdict detail
    if ! _api_hold_enabled; then
        rm -f "$(_api_hold_path)" "$(_api_hold_crashed_path)" 2>/dev/null || true
        return 0
    fi
    now=$(date +%s)
    after=$(head -n 1 "$(_api_hold_exit_path)" 2>/dev/null); [[ "$after" =~ ^[0-9]+$ ]] || after=0
    rows=$(_api_hold_scan_markers "$now" "$after")
    p=$(_api_hold_path)

    if [[ ! -f "$p" ]]; then
        if [[ -n "$rows" ]] && _api_hold_signal_fires "$target" <<<"$rows"; then
            _api_hold_enter "$target" "$rows" "$now"
        fi
        return 0
    fi

    IFS=$'\t' read -r id entered t0 last_step orch < "$p" 2>/dev/null
    [[ "$id" =~ ^[0-9]+$ && "$entered" =~ ^[0-9]+$ ]] || { rm -f "$p"; return 0; }
    [[ "$orch" =~ ^[01]$ ]] || orch=0
    [[ -n "$rows" ]] && _api_hold_merge_crashed "$rows"
    if [[ -n "$target" ]] && printf '%s\n' "$rows" | awk -F'\t' -v t="$target" '$1 == t {f=1} END {exit !f}'; then
        orch=1
    fi
    _api_hold_write_row "$id" "$entered" "$t0" "$now" "$orch"

    # EXIT 1: a positive probe taken AFTER the hold was entered.
    if probe=$(_api_hold_probe_last); then
        IFS=$'\t' read -r pts verdict detail <<<"$probe"
        if [[ "$verdict" == reachable ]] && (( pts >= entered )); then
            _api_hold_exit "$target" "probe: ${detail}" "$now"
            return 0
        fi
    fi
    # EXIT 2: a recorded session completed a turn (its marker was cleared).
    local w
    while IFS=$'\t' read -r w _; do
        [[ -n "$w" ]] || continue
        if [[ ! -f "$(_api_hold_tf_dir)/${w}.json" ]]; then
            _api_hold_exit "$target" "board: '${w}' completed a turn (its failure marker was cleared)" "$now"
            return 0
        fi
    done < "$(_api_hold_crashed_path)"

    # EXIT 3, the FAIL-SAFE (skeptic ncbundle29-sk F2): the orchestrator made
    # progress after entry. `orchestrator-heartbeat` is touched by two of its
    # hooks (orchestrator-settings.json): `Stop`, which fires only on a
    # SUCCESSFUL turn (a failed one fires StopFailure), and `PostToolUse`. Its
    # mtime past `entered` is therefore the API answering the orchestrator,
    # whatever route made that work and whether or not it was in the crashed
    # set — and that counts as recovery for everyone.
    #
    # ERROR DIRECTION, stated: a tool that STARTED before entry and FINISHES
    # during the outage also touches the file, so this can exit EARLY. The cost
    # is one round of nudges into sessions that still fail. Those re-crash with
    # markers newer than this exit, re-enter a new hold, and are nudged again
    # on the next recovery (the F1 re-arm above) — so an early exit costs
    # pastes, never a stranded window. The opposite error, exiting late, is the
    # 2026-10-15 incident itself, so this is the cheaper side to err on.
    local hbf hbm
    hbf="${ORCH_HEARTBEAT_FILE:-${STATE_DIR:-.}/orchestrator-heartbeat}"
    hbm=$(stat -c %Y "$hbf" 2>/dev/null) || hbm=0
    if [[ "$hbm" =~ ^[0-9]+$ ]] && (( hbm > entered )); then
        _api_hold_exit "$target" "board: the orchestrator completed a turn ($(basename "$hbf") touched at $(_api_hold_ts "$hbm"))" "$now"
        return 0
    fi

    # Still held. The ceiling fails the gates open (see `_api_hold_active`);
    # say so once, then at a backoff.
    if (( now - entered >= $(_api_hold_max_hold) )) && [[ ! -f "$(_api_hold_ceiling_stamp)" ]]; then
        printf '%s\n' "$now" > "$(_api_hold_ceiling_stamp)" 2>/dev/null || true
        "$_API_HOLD_LOG_FN" "api-hold: ceiling CROSSED ($(_api_hold_max_hold)s) — emits and orchestrator-liveness FAIL OPEN; the crashed set is kept and is still nudged when the probe recovers"
    fi
    if "$_API_HOLD_OPERATOR_ALERT_FN" due "$_API_HOLD_ALERT_KEY"; then
        "$_API_HOLD_OPERATOR_ALERT_FN" raise "$_API_HOLD_ALERT_KEY" "$( (( orch )) && printf critical || printf warning)" \
            "$(_api_hold_alert_text "$t0" "$orch" "$(grep -c . "$(_api_hold_crashed_path)" 2>/dev/null)")"
    fi
    return 0
}
