# shellcheck shell=bash
# monitor/watcher/_over_limit.sh — watcher-side wake scheduler for
# panes (orchestrator + workers) that hit the weekly Opus limit.
#
# Issue #87. Architectural premise: when a claude pane renders the
# canonical "You've hit your limit · resets <time>" notice, the
# session is functionally suspended. The orchestrator pane shares
# the same account/budget as workers, so an orchestrator-side
# scheduler can't be assumed alive at the moment it's needed.
# The watcher (pure shell, no claude budget) is the right responsible
# party: it's already polling pane state every cycle, and `tmux
# paste-buffer` requires no LLM mediation.
#
# State substrate: `monitor/.state/over-limit-state.tsv`. One row per
# suspended pane. Atomic-by-rename rewrites; reads are line-grep.
# Survives watcher restart by design — the wake-loop is the load-
# bearing recovery path; losing state would leave a worker stranded.
#
# Row schema (tab-separated):
#
#   <key> <window> <role> <reset_at_token> <reset_epoch>
#       <first_seen_epoch> <next_attempt_epoch> <attempts>
#       <session_id>
#
# NINE fields: the eight above plus `<session_id>` (issue #161, see
# SESSION IDENTITY below). Every OTHER per-key datum — the observation
# epoch the emit gate depends on (your-org/nexus-code#592), the limit
# flavour, the liveness note — lives in a SIDECAR file, not in a further
# column; see `_over_limit_observation_get`. Rollback caveat, stated: a
# watcher that predates the ninth field reads `attempts` as
# `<attempts><TAB><session_id>` (bash's `read` folds the remainder into
# the last variable). Within this module every row-parsing `read` names
# the ninth field.
#
# `<key>` is `_orchestrator` when the pane is the watcher's TARGET,
# otherwise the window name. `<role>` is `orchestrator` or `worker`.
# All epoch fields are unix seconds.
#
# SESSION IDENTITY (issue #161). `<session_id>` names the claude
# session that owned the pane when the hold was stamped. It is the
# ninth and last field, so a row written by an older revision (eight
# fields) still parses — it simply reads as "session unknown" and the
# identity test below is skipped. Every row-parsing `read` in this
# module MUST name the ninth field: bash's `read` collapses all
# remaining fields into the last variable, so an eight-name read of a
# nine-field row silently corrupts `attempts`.
#
# A tmux window name is NOT a session. A context rotation retires the
# orchestrator session and cold-spawns a replacement into a window of
# the SAME name, so every name-based test in this module still
# resolves and the row outlives the session it describes. The fresh
# session then receives its predecessor's usage-limit recovery brief,
# and — when the rotation lands inside a live hold — inherits the emit
# suppression as well. Recording the session and dropping the row when
# it no longer matches the live one fixes that class, including any
# path that replaces the session without going through
# spawn-fresh-orchestrator.sh. Both the wake loop and the pause
# predicate apply the test, for the same reason the staleness rule is
# applied in both: neither may depend on the other having run.
#
# Public functions:
#
#   _over_limit_reset_at_to_epoch <token> [<now>]
#     Pure parser — a function of (token, now) ONLY; it never consults the
#     wall clock, so it can be pinned to any instant under test. Returns
#     the next occurrence of the stated wall-clock time in the stated
#     timezone, STRICTLY after <now>, and always within 25h of it.
#     Token shapes accepted:
#       "3am_America/Los_Angeles"  → next 3am in LA tz
#       "11pm"                      → next 11pm in caller's tz
#       "midnight_UTC"              → next midnight UTC
#       "unknown" / "" / unparseable / invalid tz / out-of-band result
#                                   → now + safety fallback (6h)
#     Always prints an integer epoch on stdout (return 0).
#
#   _over_limit_record <key> <window> <role> <reset_at_token>
#     Insert-or-refresh a stamp. Preserves first_seen_epoch and
#     attempts across refreshes (so repeated observations of an
#     unchanged suspension don't reset progress through backoff).
#     ALSO preserves reset_epoch + next_attempt_epoch whenever the token
#     is unchanged (your-org/nexus-code#581): the reset instant of an
#     ongoing hold is fixed at first observation. Only a CHANGED token
#     recomputes them — that is the mid-suspension renderer update the
#     recompute was there to serve. Recomputing unconditionally rolled the
#     horizon a day forward at the exact moment the reset landed; see the
#     comment in the function body. Whatever horizon results is clamped
#     to first_seen + MAX_HOLD (see "DEADLINE FREEZE" in the body).
#
#   _over_limit_drop <key> [<window>]
#     Remove the row, atomically, AND retire the hook-written
#     per-window JSON stamp the row was latched off. <window> defaults
#     to the row's own window field. Silent no-op when row absent.
#     Retiring the JSON is load-bearing: `pane-state.sh` reports
#     `state=over-limit` straight from that file, so a row dropped
#     without it leaves a live detector behind and the very next scan
#     re-stamps the row. A window of the same name that appears later
#     (a rotation, a re-used worker name) then re-latches off a stamp
#     written for a pane that no longer exists.
#
#   _over_limit_load <key>
#     Tab-separated row for <key>, or empty on miss. Use IFS=$'\t' read.
#
#   _over_limit_orchestrator_paused
#     Exit 0 when an `_orchestrator` row exists, is not expired, belongs
#     to the session that still owns the pane, AND — when an observation
#     is on record — its suspension was OBSERVED within
#     MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS; 1 otherwise. Used
#     by main.sh's paste-gate to suppress routine emits to a suspended
#     orchestrator (would pile up unread). Archive still runs.
#     Row-existence alone is NOT sufficient (your-org/nexus-code#592) — a
#     row is a prediction, and a stale one silently severs the operator's
#     channel. "Expired" is _over_limit_hold_expired: past the absolute
#     ceiling, or past the row's own stored deadline plus the stale
#     grace. The predicate deliberately does NOT depend on the wake loop
#     having run — that dependency is what latched on 2026-09-02.
#
#   _over_limit_hold_expired <first_seen> <reset_epoch> <now>
#     Shared staleness rule. Exit 0 when the hold must stop suppressing.
#
#   _over_limit_session_rotated <window> <role> <row_session_id>
#     Shared identity rule. Exit 0 ONLY on a positive mismatch: the row
#     names a session, the pane names a session, and the two differ.
#     An unknown id on either side exits 1 (no evidence of a rotation),
#     so the module never drops a hold on a guess.
#
#   _over_limit_state_dir
#     Resolve the state directory, or fail LOUDLY. Never returns a
#     relative path.
#
#   _over_limit_keys
#     One key per line. Caller iterates to dispatch wake checks.
#
#   _over_limit_scan_panes <target_window>
#     Probe the orchestrator pane + every worker pane via pane-state.sh.
#     For each pane returning state=over-limit, _over_limit_record it.
#     Idempotent — re-running on a stable suspension leaves the row's
#     horizon, wake time, first_seen and attempts all untouched. It runs
#     every 60s for the whole of a multi-hour hold, so anything it mutates
#     is mutated hundreds of times; see _over_limit_record.
#
#   _over_limit_process_wakes <target_window>
#     The wake loop. For each stamped row whose next_attempt_epoch ≤
#     now, re-probe. If still over-limit: bump backoff (60s → 120s →
#     240s → cap 300s), increment attempts; at MAX_ATTEMPTS (default
#     4) FAIL OPEN — paste the resume brief anyway and drop the row.
#     The paste is deliberate, not optimistic: a suspended pane never
#     repaints on its own and the hook stamp only clears on a
#     successful turn, so "still reads over-limit" is EXPECTED after
#     a genuine reset; the paste triggers the turn that either
#     confirms recovery (Stop hook clears the stamp) or re-stamps
#     with the current reset time (StopFailure hook). This is the
#     anti-latch guarantee: the hold is bounded by
#     reset_epoch + margin + Σbackoff (≈12 min past reset at
#     defaults), never indefinite. If transitioned out — ANY alive
#     state (idle/busy/empty/user-typing/autosuggest-only AND the
#     refined-idle states working-background/working-self-paced/
#     idle-orphan-async): paste the resume brief and drop the row.
#     An UNRECOGNISED state routes through the same MAX_ATTEMPTS
#     fail-open as over-limit, so NO state can hold the gate forever
#     (skeptic finding, PR #526 round 1). If pane-absent or window
#     missing: log + drop. Returns 0 always (logs are advisory).
#
# Env knobs (override config or default):
#   MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS    (default 300 = 5 min)
#       Safety margin added to reset_epoch before the first wake
#       attempt. Allows for clock-skew + the rate-limit-bucket-refill
#       not landing on the dot.
#   MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS (default 60)
#       Delay before the first retry when a wake attempt finds the
#       pane still suspended.
#   MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS    (default 300)
#       Cap on the exponential backoff between retries.
#   MONITOR_OVER_LIMIT_MAX_ATTEMPTS           (default 4)
#       Fail OPEN (paste the resume brief + drop the row) after this
#       many still-over-limit wake attempts. Default 4 ≈ 7 min of
#       grace past the reset margin (60+120+240s) before the paste.
#   MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS (default 600 = 10 min)
#       How long an OBSERVED over-limit sighting (the observation sidecar) keeps the
#       orchestrator emit gate suppressed. The scan refreshes it every 60s
#       during a genuine hold, so 10 min tolerates ten consecutive missed
#       cycles before the gate opens. This is the liveness cross-check the
#       gate previously lacked entirely (your-org/nexus-code#592): a wrong
#       reset epoch, clock skew, wedged scan or broken probe used to sever
#       the operator↔orchestrator channel indefinitely and in silence. The
#       polarity is deliberate — a STALE observation opens the gate.
#       Emitting into a live pane is cheap; withholding is not. A row with
#       NO observation on record is bounded by the expiry rules instead
#       (see _over_limit_orchestrator_paused).
#   MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS     (default 900 = 15 min)
#       How long a hold must last before the FIRST out-of-band announcement
#       that the orchestrator's emit channel is being withheld.
#   MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS  (default 3600 = 1h)
#       Cadence of the reminders after that first announcement. Separate from
#       the announcement delay on purpose: a legitimate 5h hold fired 20
#       critical-class bells when both used the same 15-min interval, which
#       trains the operator to ignore exactly the signal this exists to send.
#   MONITOR_OVER_LIMIT_MAX_HOLD_SECONDS       (default 90000 = 25h)
#       Absolute per-row hold ceiling. A row older than this
#       (now - first_seen) fails OPEN regardless of pane state or
#       probe outcome — the belt-and-suspenders that bounds EVERY
#       wake path, including a persistently-failing pane-state probe.
#       Must exceed the longest legitimate reset horizon (24h).
#       Evaluated BEFORE the due-gate, so it does not depend on the
#       wake schedule it protects. Also clamps a recomputed deadline.
#   MONITOR_OVER_LIMIT_STALE_GRACE_SECONDS    (default: see below)
#       How far past a row's own stored reset_epoch the hold may keep
#       suppressing. Past it the pause predicate reports NOT paused
#       even while the row lives.
#
#       It must exceed the whole wake sequence, or the predicate would
#       cut short a wake that is still legitimately retrying. The
#       sequence is the wake margin plus every backoff interval that
#       actually elapses. Only MAX_ATTEMPTS-1 intervals elapse, because
#       _over_limit_bump_or_failopen fails open when the NEXT attempt
#       count reaches the cap. At defaults that is 3 intervals, not 4,
#       and the cap is never reached:
#
#           margin 300 + (60 + 120 + 240) = 720s
#
#       An earlier revision of this comment claimed 300 + 4x300 = 1500s.
#       That was wrong on both the interval count and their values
#       (skeptic finding, PR #116). The conclusion survived but the
#       derivation did not, and the relationship was not config-robust:
#       at max_attempts=8 the sequence is 300 + 1620 = 1920s, which
#       exceeds a fixed 1800s grace. So the default is now DERIVED —
#       _over_limit_grace_default returns the larger of 1800 and the
#       measured sequence, and any explicit value still wins.
#
# Logger contract: callers may set `_OVER_LIMIT_LOG_FN` to the name of
# a function that takes one string arg. Default is a noop. Tests pin a
# capturing impl; main.sh wires it to the watcher's `log` helper.
#
# Paster contract: callers may set `_OVER_LIMIT_PASTE_FN` to a function
# accepting `<window> <body_file>`. Default is noop. Tests pin a
# capturing impl; main.sh wires it to `paste_with_retry`.
#
# Alert contract: callers may set `_OVER_LIMIT_ALERT_FN` to a function taking
# one string. Default is a noop. main.sh wires it to `_watcher_alert`, whose
# whole premise matches this case exactly — "the orchestrator-paste channel may
# itself be the thing that is broken", so it reports out-of-band (alerts log +
# sandbox-notify), not through the channel being suppressed.

_OVER_LIMIT_LOG_FN="${_OVER_LIMIT_LOG_FN:-_over_limit_log_noop}"
_OVER_LIMIT_PASTE_FN="${_OVER_LIMIT_PASTE_FN:-_over_limit_paste_noop}"
_OVER_LIMIT_ALERT_FN="${_OVER_LIMIT_ALERT_FN:-_over_limit_alert_noop}"

_over_limit_log_noop() { :; }
_over_limit_paste_noop() { return 0; }
_over_limit_alert_noop() { :; }

# Resolve the state directory. NEVER falls back to a relative path.
#
# A `${STATE_DIR:-.}` fallback silently redirected every read and write
# into the CALLER's working directory: `_over_limit_drop` then reported
# success having removed a file that was not the real state file, and
# `_over_limit_orchestrator_paused` read a stranger's row (issue #500).
# Resolution order mirrors bootstrap.sh:
#   STATE_DIR → NEXUS_STATE_DIR → NEXUS_ROOT/monitor/.state → repo layout
# The repo-layout rung only accepts a directory that really is
# `monitor/watcher/` (its sibling `main.sh` must exist), so a stray copy
# of this helper cannot invent a plausible-looking absolute path. When
# nothing resolves the function fails LOUDLY on stderr and returns 1;
# every caller propagates that rather than touching the cwd. The
# sidecar paths below use the same resolver.
_over_limit_state_dir() {
    if [[ -n "${STATE_DIR:-}" ]]; then
        printf '%s' "$STATE_DIR"; return 0
    fi
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
        printf '%s' "$NEXUS_STATE_DIR"; return 0
    fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then
        printf '%s/monitor/.state' "$NEXUS_ROOT"; return 0
    fi
    local helper_dir
    helper_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || helper_dir=""
    if [[ -n "$helper_dir" && -f "$helper_dir/main.sh" ]]; then
        printf '%s/.state' "$(cd "$helper_dir/.." && pwd)"
        return 0
    fi
    printf 'over-limit: cannot resolve a state directory (STATE_DIR, NEXUS_STATE_DIR and NEXUS_ROOT are unset, and %s is not a monitor/watcher checkout); refusing to use a relative path\n' \
        "${helper_dir:-<unknown>}" >&2
    return 1
}

_over_limit_state_path() {
    local dir
    dir=$(_over_limit_state_dir) || return 1
    printf '%s/over-limit-state.tsv' "$dir"
}

# ---- observation sidecar (your-org/nexus-code#592) ------------------------
#
# `<key>\t<epoch>` — when a scan last OBSERVED that pane rendering the
# over-limit notice. Distinct in kind from every epoch in the row file, which
# are predictions or bookkeeping; this one is evidence, and it is what the
# emit-suppression gate trusts.
#
# WHY A SIDECAR RATHER THAN A 9TH COLUMN. The row file survives restarts and
# version skew — `_version_restart.sh` exists precisely because the watcher can
# be mid-transition — so the format has to tolerate being read by code that
# predates it. It does not: an older watcher reads a row with
# `IFS=$'\t' read -r ... attempts`, and the trailing variable absorbs the
# remainder, so `attempts` becomes `0<TAB><epoch>` and the wake loop's
# `$(( attempts + 1 ))` dies with `bad math expression`. That converts a
# routine rollback into an outage of the very wake path this module is.
# Verified, not assumed. A sidecar is invisible to old code by construction.
#
# The reverse direction: new code finding no sidecar (rolled forward onto an
# old state dir) sees no observation and judges the row by the expiry and
# session rules alone (see _over_limit_orchestrator_paused, which states why);
# the next scan of a still-suspended pane stamps the sidecar.
#
# It is also why the write asymmetry is structural rather than a discipline:
# `_over_limit_record` is the only writer of this file, and every other mutator
# touches the row file instead, so no future call site can accidentally forge
# or clobber an observation.
_over_limit_observation_path() {
    local dir
    dir=$(_over_limit_state_dir) || return 1
    printf '%s/over-limit-observed.tsv' "$dir"
}

# Epoch, or empty when never observed / file absent.
_over_limit_observation_get() {
    local key="$1" path
    path=$(_over_limit_observation_path) || return 0
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v k="$key" '$1 == k && $2 ~ /^[0-9]+$/ { print $2; exit }' "$path"
}

_over_limit_observation_set() {
    local key="$1" epoch="$2" path tmp
    [[ -n "$key" && "$epoch" =~ ^[0-9]+$ ]] || return 0
    path=$(_over_limit_observation_path) || return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    tmp=$(mktemp "${path}.XXXXXX") || return 0
    [[ -f "$path" ]] && awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    printf '%s\t%s\n' "$key" "$epoch" >> "$tmp"
    mv "$tmp" "$path"
}

_over_limit_observation_drop() {
    local key="$1" path tmp
    [[ -n "$key" ]] || return 0
    path=$(_over_limit_observation_path) || return 0
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX") || return 0
    awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    if [[ -s "$tmp" ]]; then mv "$tmp" "$path"; else rm -f "$path" "$tmp"; fi
}

# WHICH LIMIT was hit, per key (your-org/nexus-code#1488). A SIDECAR, for the
# same reason the observation epoch is one: the state row is EIGHT fields and
# must stay eight. `unknown` is never stored — an absent row and a stored
# "unknown" would be two spellings of one fact.
_over_limit_flavour_path() {
    local dir
    dir=$(_over_limit_state_dir) || return 1
    printf '%s/over-limit-limit.tsv' "$dir"
}
_over_limit_flavour_get() {
    local key="$1" path
    path=$(_over_limit_flavour_path) || return 0
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v k="$key" '$1 == k && $2 != "" { print $2; exit }' "$path"
}
_over_limit_flavour_set() {
    local key="$1" flavour="$2" path tmp
    [[ -n "$key" && -n "$flavour" && "$flavour" != unknown ]] || return 0
    path=$(_over_limit_flavour_path) || return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    tmp=$(mktemp "${path}.XXXXXX") || return 0
    [[ -f "$path" ]] && awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    printf '%s\t%s\n' "$key" "$flavour" >> "$tmp"
    mv "$tmp" "$path"
}
_over_limit_flavour_drop() {
    local key="$1" path tmp
    [[ -n "$key" ]] || return 0
    path=$(_over_limit_flavour_path) || return 0
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX") || return 0
    awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    if [[ -s "$tmp" ]]; then mv "$tmp" "$path"; else rm -f "$path" "$tmp"; fi
}
# How a limit is NAMED in prose. `unknown` becomes "usage", never a model name
# nobody measured: the whole defect was asserting a tier the evidence did not
# support.
_over_limit_flavour_label() {
    local f="${1:-}"
    if [[ -z "$f" || "$f" == unknown ]]; then printf 'usage'
    else printf '%s' "${f//_/ }"; fi
}

# Off-time log (operator ask, your-nexus#275): a human-readable,
# consolidated record of what the watcher HELD while the orchestrator was
# over-limit. main.sh appends one line per suppressed emit; the resume
# brief (the special first flushed emit) points the operator here so they
# can see exactly what they missed during the off-time. Freshly started at
# the top of each orchestrator hold (`_over_limit_held_log_start`), so it
# always describes the most-recent incident; the per-emit full bodies stay
# archived under monitor/.state/diffs/ as the permanent record.
_over_limit_held_log_path() {
    local dir
    dir=$(_over_limit_state_dir) || return 1
    printf '%s/over-limit-held.log' "$dir"
}

# Start (truncate + header) the off-time log for a new orchestrator hold.
# Called from _over_limit_record when a fresh `_orchestrator` row appears.
_over_limit_held_log_start() {
    local t0="$1" path pretty
    path=$(_over_limit_held_log_path) || return 1
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    pretty=$(date -d "@$t0" -Is 2>/dev/null || printf '%s' "$t0")
    printf '# over-limit off-time log — orchestrator hold began %s (epoch %s)\n# one line per emit the watcher held while the pane was over-limit; full bodies under monitor/.state/diffs/\n' \
        "$pretty" "$t0" > "$path" 2>/dev/null || true
    # New hold ⇒ new alert clock, so the first escalation is measured from
    # THIS hold's start rather than inheriting the previous incident's stamp.
    rm -f "$(_over_limit_alert_stamp_path)" 2>/dev/null || true
}

# Where the last suppression ALERT was fired (epoch). Reset at hold start.
_over_limit_alert_stamp_path() {
    local dir
    dir=$(_over_limit_state_dir) || return 1
    printf '%s/over-limit-alert.stamp' "$dir"
}

# Append a held-emit record to the off-time log. Called by main.sh's
# over-limit-suppressed emit branch. Best-effort; never fails the caller.
#
# ALSO makes the suppression VISIBLE (your-org/nexus-code#592). Withholding the
# operator's channel was previously recorded only in watcher.log, which is
# exactly why a 15-hour blackout passed unnoticed: the watcher dutifully logged
# "emit paste suppressed" once per ~50s cycle into a file no human reads, while
# an operator comment and four spawn requests went undelivered. A condition
# that mutes operator communication must announce itself out-of-band. So once
# a hold outlives MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS, escalate
# through the injected alert channel (main.sh wires `_watcher_alert`: alerts
# log + watcher log + sandbox-notify), then remind on the SLOWER
# MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS cadence for as long as it
# continues. Rate-limited via a stamp file so the ~50s emit cadence cannot
# turn this into a notification storm.
#
# This sentence used to say "keep re-announcing at that interval", the
# pre-19c1e12 single-interval model, while the function immediately below
# had already been rewritten to one announcement plus slower reminders —
# the two cadences are the whole point of the split (a 5h hold fired 20
# critical-class bells when they were one). Corrected by
# your-org/nexus-code#976; same class as `#582` finding C.
_over_limit_record_held() {
    local archive="$1" reason="$2" path ts
    path=$(_over_limit_held_log_path) || return 1
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    ts=$(date -Is 2>/dev/null || date 2>/dev/null || printf '?')
    printf '%s\theld\tarchive=%s\treason=%s\n' "$ts" "$archive" "$reason" \
        >> "$path" 2>/dev/null || true
    _over_limit_maybe_alert_suppression
}

# ONE announcement per hold, then periodic reminders — not an alert every
# interval. A legitimate 5h hold used to fire 20 critical-class bells, which is
# precisely how an operator learns to ignore the announcement, defeating the
# visibility this exists to provide. At the defaults a 5h hold now fires one
# announcement plus four hourly reminders.
#
# The text describes what OBTAINS; it does not assert a cause. The earlier
# wording told the operator to suspect a stale stamp — which, since #592, is
# false BY CONSTRUCTION at the moment this fires: the gate only suppresses on a
# fresh observation, so anything alerting here is a live hold with the pane
# genuinely rendering the notice. Sending them hunting for a stale stamp that
# cannot be there is worse than saying nothing, because it trains the wrong
# reflex for the first occurrence that is real.
_over_limit_maybe_alert_suppression() {
    local first_delay reminder stamp_path last now row first_seen held_n
    local token observed kind since_obs
    first_delay="${MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS:-900}"
    reminder="${MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS:-3600}"
    [[ "$first_delay" =~ ^[0-9]+$ ]] || first_delay=900
    [[ "$reminder"    =~ ^[0-9]+$ ]] || reminder=3600
    (( first_delay > 0 )) || return 0
    now=$(date +%s)
    row=$(_over_limit_load "_orchestrator") || return 0
    IFS=$'\t' read -r _ _ _ token _ first_seen _ _ _ <<<"$row"
    [[ "$first_seen" =~ ^[0-9]+$ ]] || return 0
    (( now - first_seen >= first_delay )) || return 0
    stamp_path=$(_over_limit_alert_stamp_path) || return 0
    last=$(cat "$stamp_path" 2>/dev/null)
    if [[ "$last" =~ ^[0-9]+$ ]]; then
        # Already announced — only a reminder is due, and only on the slower
        # cadence.
        (( now - last >= reminder )) || return 0
        kind="continues"
    else
        kind="began"
    fi
    printf '%s' "$now" > "$stamp_path" 2>/dev/null || true
    # `grep -c` prints `0` on no match AND exits 1; `|| printf '0'` appended a
    # second one, rendering "(0\n0 emits held)" in the operator emit (#725).
    held_n=$(grep -c $'\theld\t' "$(_over_limit_held_log_path)" 2>/dev/null) || held_n=0
    [[ "$held_n" =~ ^[0-9]+$ ]] || held_n=0
    observed=$(_over_limit_observation_get "_orchestrator")
    if [[ "$observed" =~ ^[0-9]+$ ]]; then
        since_obs="$(( now - observed ))s ago"
    else
        since_obs="not recorded"
    fi
    "$_OVER_LIMIT_ALERT_FN" \
        "over-limit hold ${kind}: the orchestrator's emit channel has been suppressed for $(( (now - first_seen) / 60 )) min (${held_n} emits held). The pane is still rendering the over-limit notice — last observed ${since_obs} — so this is a live hold, not a stale stamp; the reset it states is '${token}'. Held emits are archived and summarised on resume: $(_over_limit_held_log_path)."
}

# ---- liveness sidecar: DEFENCE IN DEPTH against a stale over-limit read ----
#
# OWNERSHIP NOTE, so nobody mistakes this for the fix. The classification bug
# is `pane-state.sh` 1b: it short-circuits to `over-limit` on the hook-written
# stamp before inspecting the pane at all, and that stamp's only clear is the
# Stop hook on the next SUCCESSFUL turn — which for a worker mid-turn was
# measured 20+ minutes away (your-org/nexus-code#1141). That is fixed there,
# where every consumer reads it. THIS is the belt: pane-state is not the only
# thing that can hand the watcher a wrong answer, and the wake loop's cost for
# believing one is measured — 63 held emits in an hour, five windows
# re-stamped and re-briefed, one resume brief pasted 62 s after the last.
#
# The asymmetry this closes: the WAKE path already knows that a pane servicing
# turns is not suspended — its resumption arm lists busy / working-background /
# working-self-paced / idle-orphan-async and says so. The DETECTOR never
# applied the same knowledge, so a pane the wake loop had just retired as alive
# was re-stamped by the very next scan on the same stale signal.
#
# `<key>\t<epoch>\t<reason>` — when this pane was last ACTIONED as resumed.
# It is the mirror of the observation sidecar above: that one records evidence
# of SUSPENSION and keeps the emit gate shut; this one records that a
# contradiction was already resolved, and keeps a row from being re-created on
# the same evidence that produced the resolution. Same substrate discipline — a separate file, so it
# is invisible to an older watcher reading the eight-column row format.
_over_limit_liveness_path() {
    local dir
    dir=$(_over_limit_state_dir) || return 1
    printf '%s/over-limit-liveness.tsv' "$dir"
}

# `<epoch> <reason>` on stdout, or empty when never noted / file absent.
_over_limit_liveness_get() {
    local key="$1" path
    path=$(_over_limit_liveness_path) || return 0
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v k="$key" '$1 == k && $2 ~ /^[0-9]+$/ { print $2, $3; exit }' "$path"
}

_over_limit_liveness_set() {
    local key_raw="$1" epoch="$2" reason="$3" key path tmp
    [[ -n "$key_raw" && "$epoch" =~ ^[0-9]+$ ]] || return 0
    key=$(_over_limit_sanitize_key "$key_raw")
    path=$(_over_limit_liveness_path) || return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    tmp=$(mktemp "${path}.XXXXXX") || return 0
    [[ -f "$path" ]] && awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    printf '%s\t%s\t%s\n' "$key" "$epoch" "${reason:-alive}" >> "$tmp"
    mv "$tmp" "$path"
}

# Is this key inside the post-resume suppression window? Echoes a
# human-readable reason on stdout when it is.
#
# WHY THIS ARM AND NOT A BROADER ONE — the narrowing matters more than the
# mechanism, and the repo's own suite is what forced it. The first version of
# this gate also armed on ANY pane observed alive by the scan. That reads as
# strictly safer and is not: the scan probes every pane every 60 s and panes
# are alive nearly all the time, so a note would be sitting there at the moment
# of essentially EVERY genuine suspension, and every hold would start a full
# grace period late. That is not a narrow cost paid in an edge case — it is the
# normal path, and it weakens the hold exactly as much as the spam it was
# meant to stop. `test-over-limit.sh` caught it by failing on a legitimate
# fresh orchestrator hold.
#
# So the arm is only ever set where the watcher has ALREADY ACTED on a
# contradiction: it pasted a resume brief and retired the row. The turn that
# brief starts is what clears the underlying stamp, and until that turn ends
# the same stale signal is still there to be re-read. That is the "one banner
# instance, one resume" rule — fresh evidence has to mean a NEW suspension, not
# the scrollback that produced the last one.
#
# The residual, stated rather than hidden: a stale read arriving with NO prior
# resume still stamps once, and the wake loop then pastes one brief before this
# arm engages. The bound is therefore ONE spurious brief per episode, not zero
# and not a loop. Closing that last one would need the broad arm, and the
# paragraph above is why it costs more than it buys.
_over_limit_liveness_suppressed() {
    local key="$1" now="$2" note epoch reason window
    note=$(_over_limit_liveness_get "$key")
    [[ -n "$note" ]] || return 1
    read -r epoch reason <<<"$note"
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    [[ "$reason" == "resumed" ]] || return 1
    window="${MONITOR_OVER_LIMIT_RESUME_SUPPRESSION_SECONDS:-300}"
    [[ "$window" =~ ^[0-9]+$ ]] || window=300
    (( window > 0 )) || return 1
    (( now - epoch <= window )) || return 1
    printf '%s %ss ago' "$reason" "$(( now - epoch ))"
}

_over_limit_sanitize_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

# --- session identity (issue #161) ----------------------------------
#
# Two questions, two sources:
#
#   Which session was suspended?  The hook-written per-window stamp
#     `<state>/over-limit/<window>.json` carries `session_id` — the
#     session whose turn failed with `rate_limit`. That is the most
#     precise answer, so it is preferred. It is absent when the
#     suspension was detected by the renderer scrape instead of the
#     StopFailure hook, and the live source below is the fallback.
#
#   Which session owns the pane now?  For the orchestrator, the pin at
#     `<state>/orchestrator-session-id`, rewritten by the
#     UserPromptSubmit hook on every turn. For a worker, `session_id`
#     in its heartbeat `<state>/heartbeat/<window>.json`.
#
# Both readers fail SOFT: an unresolvable path, an absent file or an
# unparseable body yields the empty string, which the identity test
# reads as "no evidence" and skips. Dropping a live hold on a failed
# read would resume emits into a genuinely frozen pane.

# Directory holding the hook-written per-window over-limit stamps.
_over_limit_stamp_dir() {
    local dir
    dir=$(_over_limit_state_dir) || return 1
    printf '%s/over-limit' "$dir"
}

# Path of one window's JSON stamp. A window name that could escape the
# stamp directory is refused outright — the caller `rm -f`s this path.
_over_limit_stamp_path() {
    local window="$1" dir
    [[ -n "$window" && "$window" != *"/"* && "$window" != .* ]] || return 1
    dir=$(_over_limit_stamp_dir) || return 1
    printf '%s/%s.json' "$dir" "$window"
}

# Read one string field out of a JSON file. Uses jq when present; the
# sed fallback keeps the module working on a host without it, since
# nothing else here depends on jq. Prints the empty string on any
# miss, including a JSON `null`.
_over_limit_json_field() {
    local file="$1" field="$2" v=""
    [[ -n "$file" && -f "$file" ]] || { printf ''; return 0; }
    if command -v jq >/dev/null 2>&1; then
        v=$(jq -r --arg f "$field" '.[$f] // ""' "$file" 2>/dev/null) || v=""
    else
        # First match taken by parameter expansion, not `| head -n1`: an
        # early-exit reader under pipefail can SIGPIPE sed and blank a
        # real value through the `|| v=""` (early-exit-readers.manifest).
        v=$(sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
            "$file" 2>/dev/null) || v=""
        v=${v%%$'\n'*}
    fi
    [[ "$v" != "null" ]] || v=""
    printf '%s' "$v"
}

# Normalise a session id for storage and for comparison. EVERY read of
# an id goes through this, so the two sides of the comparison can never
# be normalised differently.
#
# An asymmetry here is not cosmetic: it makes two spellings of the SAME
# session compare unequal, which reports a rotation that did not happen
# and drops a LIVE hold — the one direction this module must never fail
# in, because it resumes emits into a frozen pane. An earlier revision
# stripped whitespace on the pin (which is written with a trailing
# newline) but returned the JSON stamp's value verbatim, so a padded
# `session_id` in a hook payload was enough to trip it. Reachability was
# low — the pin writer applies a canonical UUID shape guard
# (`monitor/hooks/orchestrator-session-pin.sh:48`) while the stamp
# writer applies none (`monitor/hooks/over-limit-emit.sh:125`) — but the
# failure direction is the bad one. Skeptic finding, request 002.
#
# The strip lives here rather than inside `_over_limit_json_field`
# because that helper is a general JSON reader; whitespace is not noise
# in every field it might ever read.
_over_limit_normalize_session() {
    local v="$1"
    printf '%s' "${v//[[:space:]]/}"
}

# The session that owned the pane NOW (see the block comment above).
_over_limit_live_session() {
    local window="$1" role="$2" dir pin v
    dir=$(_over_limit_state_dir) || { printf ''; return 0; }
    if [[ "$role" == "orchestrator" ]]; then
        pin="$dir/orchestrator-session-id"
        [[ -f "$pin" ]] || { printf ''; return 0; }
        v=$(head -n1 "$pin" 2>/dev/null) || v=""
        _over_limit_normalize_session "$v"
        return 0
    fi
    [[ -n "$window" && "$window" != *"/"* && "$window" != .* ]] \
        || { printf ''; return 0; }
    v=$(_over_limit_json_field "$dir/heartbeat/$window.json" "session_id")
    _over_limit_normalize_session "$v"
}

# The session to STAMP into a new row: the suspended one when the hook
# recorded it, else whoever owns the pane now.
_over_limit_resolve_session() {
    local window="$1" role="$2" sid="" path
    if path=$(_over_limit_stamp_path "$window" 2>/dev/null); then
        sid=$(_over_limit_normalize_session \
            "$(_over_limit_json_field "$path" "session_id")")
    fi
    [[ -n "$sid" ]] || sid=$(_over_limit_live_session "$window" "$role")
    printf '%s' "$sid"
}

# Exit 0 only on a POSITIVE mismatch — both sides known, and different.
# An unknown id on either side is not evidence of a rotation.
_over_limit_session_rotated() {
    local window="$1" role="$2" row_session="$3" live
    # Normalise the ROW's copy too, so the invariant holds at the point
    # of comparison and not only at the point of writing. A row written
    # by any other revision of this module still compares correctly.
    row_session=$(_over_limit_normalize_session "$row_session")
    [[ -n "$row_session" ]] || return 1
    live=$(_over_limit_live_session "$window" "$role")
    [[ -n "$live" ]] || return 1
    [[ "$live" != "$row_session" ]]
}

# Retire the hook-written per-window stamp. Called from
# _over_limit_drop so the JSON never outlives the TSV row: see the
# _over_limit_drop contract in the header for why a row-only drop
# re-latches. Best-effort — a stamp we cannot remove must not keep the
# row alive.
_over_limit_retire_stamp() {
    local window="$1" path
    [[ -n "$window" ]] || return 0
    path=$(_over_limit_stamp_path "$window" 2>/dev/null) || return 0
    [[ -f "$path" ]] || return 0
    rm -f "$path" 2>/dev/null || true
    "$_OVER_LIMIT_LOG_FN" \
        "over-limit: retired the per-window stamp for '${window}' (${path})"
}

# The session id stored on a row, or empty. Lets a rewrite carry the
# field forward without threading it through every caller's arg list —
# an arity change on the shared helpers is the failure mode that
# silently breaks a running watcher mid-source-set.
_over_limit_row_session() {
    local row
    row=$(_over_limit_load "$1" 2>/dev/null) || { printf ''; return 0; }
    awk -F'\t' 'NR==1 {print $9}' <<<"$row"
}

# Exit 0 when `$1` names a timezone the C library can actually resolve.
#
# WHY THIS EXISTS. An invalid TZ string does NOT make `date` fail. glibc
# resolves the time in UTC and exits 0, so the parser's only guard — the
# epoch being numeric — passes, and a confidently wrong deadline is
# stored with no error and no fallback. Two independent measurements:
#
#   | Source                         | Token fed to the parser            | Skew    |
#   |--------------------------------|------------------------------------|---------|
#   | jacob-greene/nexus#79          | `3am_America/Los_Angeles"`         | 17 h    |
#   | your-org/nexus-code#574        | `3am_America/Los_Angeles<ESC>[0m`  | 17 h    |
#
# In the first, a scan-window row carried the closing quote of the source
# line it came from: a 3.75 h hold became a 20.75 h one. Neither the 25 h
# MAX_HOLD ceiling nor the 27 h stamp TTL clamps 20.75 h, so nothing
# downstream caught it. The guard has to be here.
#
# Two checks, in order. The charset check rejects the stray punctuation,
# quotes, spaces and ANSI escapes that caused both incidents. The tzdata
# lookup rejects a syntactically clean name that does not exist — glibc
# treats `PDT` or `America/Nowhere` the same way it treated the quoted
# token, as UTC. The UTC aliases are accepted without a lookup. When the
# host has no tzdata at all (minimal containers), the charset check is
# all we can offer, so we accept and let the caller proceed.
_over_limit_tz_resolves() {
    local tz="$1" dir
    [[ -n "$tz" ]] || return 1
    [[ "$tz" =~ ^[A-Za-z0-9_+/.-]+$ ]] || return 1
    [[ "$tz" != *..* ]] || return 1
    case "$tz" in UTC|GMT|Z|UCT|Universal|Zulu) return 0 ;; esac
    dir="${TZDIR:-/usr/share/zoneinfo}"
    [[ -d "$dir" ]] || return 0
    [[ -f "$dir/$tz" ]]
}

# Run `date` in an optional zone without bleeding TZ into the caller.
# Empty zone → the caller's own zone (the terse `11pm` token shape).
_over_limit_date_in_zone() {   # <zone|""> <date-args...>
    local zone="$1"; shift
    if [[ -n "$zone" ]]; then
        TZ="$zone" date "$@"
    else
        date "$@"
    fi
}

# Convert a reset_at token to a unix epoch. See header for shape rules.
# Always prints an integer epoch; never fails the pipeline.
#
# PURE in (token, now): the calendar date is anchored EXPLICITLY to `now`
# in the target zone, never to `date`'s idea of "today"
# (your-org/nexus-code#581). The old `date -d "<time> today"` form read the
# real wall clock regardless of the `now` argument, which had two costs.
# It made the function impossible to pin at a boundary instant — so every
# test asserted only "some epoch within 26h" and the ratchet below sailed
# through review. And it is the primitive the ratchet was built on: "today,
# else tomorrow" is memoryless, so evaluating it one second before vs. one
# second after the stated time yields answers a full day apart.
_over_limit_reset_at_to_epoch() {
    local token="$1" now="${2:-$(date +%s)}"
    local fallback=$(( now + 21600 ))  # 6h safety net
    [[ -n "$token" && "$token" != "unknown" ]] || { printf '%d' "$fallback"; return 0; }
    local time_part tz_part epoch=""
    if [[ "$token" == *_* ]]; then
        time_part="${token%%_*}"
        tz_part="${token#*_}"
    else
        time_part="$token"
        tz_part=""
    fi
    # Sanitise the TIME half at the CONSUMER (your-org/nexus-code#574).
    # Every producer channel converges here, so this is the one place a fix
    # covers all of them. Control characters and quotes are exactly what
    # rode in on the live token.
    #
    # The ZONE half is deliberately NOT stripped (jacob-greene/nexus#79): a
    # tainted zone is evidence the token was mis-extracted, so it takes the
    # blind 6h net instead of being repaired into a guess. A blind 6h hold
    # is recoverable; a confident wrong one is not.
    time_part=$(printf '%s' "$time_part" | tr -d '\000-\037\177"'"'")
    # An unusable zone must engage the safety net, NOT silently resolve in the
    # wrong zone. This is the branch that never fired before.
    if [[ -n "$tz_part" ]] && ! _over_limit_tz_resolves "$tz_part"; then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: reset_at token '${token}' names an unresolvable timezone '${tz_part}'; falling back to the blind 6h deadline"
        printf '%d' "$fallback"; return 0
    fi
    # GNU date accepts "3am" / "11pm" / "3:30am" but NOT the bare words
    # `midnight` / `noon` (coreutils 8.28 rejects both "midnight today" and
    # "midnight 2026-07-29"). The header has advertised `midnight_UTC` since
    # #87 while that shape silently took the 6h fallback; normalising here
    # makes the documented token actually resolve.
    case "$time_part" in
        [Mm]idnight) time_part="00:00" ;;
        [Nn]oon)     time_part="12:00" ;;
    esac
    # Anchor to the calendar date at `now` IN THE TARGET ZONE.
    local anchor
    anchor=$(_over_limit_date_in_zone "$tz_part" -d "@$now" +%F 2>/dev/null)
    [[ -n "$anchor" ]] || { printf '%d' "$fallback"; return 0; }
    epoch=$(_over_limit_date_in_zone "$tz_part" -d "$time_part $anchor" +%s 2>/dev/null)
    [[ "$epoch" =~ ^[0-9]+$ ]] || { printf '%d' "$fallback"; return 0; }
    # Strictly after `now`: if the stated time has already passed today,
    # the next occurrence is tomorrow. Re-resolve against the next calendar
    # DAY rather than adding 86400 — across a DST transition the flat
    # addition lands an hour off the stated wall clock (verified: 3am PST
    # + 86400s = 4am PDT).
    if (( epoch <= now )); then
        local anchor_next
        anchor_next=$(_over_limit_date_in_zone "$tz_part" -d "$anchor + 1 day" +%F 2>/dev/null)
        [[ -n "$anchor_next" ]] || { printf '%d' "$fallback"; return 0; }
        epoch=$(_over_limit_date_in_zone "$tz_part" -d "$time_part $anchor_next" +%s 2>/dev/null)
        [[ "$epoch" =~ ^[0-9]+$ ]] || { printf '%d' "$fallback"; return 0; }
    fi
    # Invariant: the next occurrence of a DATE-LESS wall-clock time is always
    # within 24h of now (25h allows the DST-long day). A result outside that
    # band is an arithmetic error, not a real reset horizon — take the safety
    # net rather than park a hold a day out. This is the standing assertion
    # that would have caught #581 at the source.
    if (( epoch <= now || epoch > now + 90000 )); then
        printf '%d' "$fallback"; return 0
    fi
    printf '%d' "$epoch"
}

# Read a row by key. Empty stdout when row absent. Returns 0 on hit
# (truthy use: `row=$(_over_limit_load k); [[ -n $row ]]`).
_over_limit_load() {
    local key="$1" path
    path=$(_over_limit_state_path) || return 1
    [[ -f "$path" ]] || return 1
    awk -F'\t' -v k="$key" '$1 == k { print; found=1; exit } END { exit !found }' "$path"
}

_over_limit_keys() {
    local path
    path=$(_over_limit_state_path) || return 1
    [[ -f "$path" ]] || return 0
    awk -F'\t' 'NF>=1 && $1 != "" { print $1 }' "$path"
}

# Shared staleness rule for a stamped hold. Exit 0 when the hold is
# EXPIRED and must no longer suppress anything. Two independent bounds:
#
#   (a) absolute ceiling  — now - first_seen  > MAX_HOLD  (default 25h)
#   (b) deadline + grace  — now > reset_epoch + STALE_GRACE (default 30m)
#
# (b) is the bound the pause predicate was missing (issue #500): the
# predicate tested only that a row EXISTED, so a row whose own stored
# deadline had passed hours earlier still suppressed every emit. A
# malformed or non-numeric field is treated as "not expired by that
# bound" — the other bound still applies, and the wake loop's fail-open
# remains the terminal backstop.
# Total seconds a wake sequence can legitimately occupy past the stored
# deadline: the wake margin plus every backoff interval that actually
# elapses. _over_limit_bump_or_failopen fails open when the NEXT attempt
# count reaches max_attempts, so only max_attempts-1 intervals run. The
# n-th elapsed interval is `initial << (n-1)`, capped at `cap`.
_over_limit_wake_sequence_seconds() {
    local margin="${MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS:-300}"
    local initial="${MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS:-60}"
    local cap="${MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS:-300}"
    local max_attempts="${MONITOR_OVER_LIMIT_MAX_ATTEMPTS:-4}"
    [[ "$margin"       =~ ^[0-9]+$ ]] || margin=300
    [[ "$initial"      =~ ^[0-9]+$ ]] || initial=60
    [[ "$cap"          =~ ^[0-9]+$ ]] || cap=300
    [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=4
    local total="$margin" n shift_n delay
    for (( n = 1; n < max_attempts; n++ )); do
        shift_n=$(( n - 1 ))
        (( shift_n > 16 )) && shift_n=16
        delay=$(( initial << shift_n ))
        (( delay > cap )) && delay=$cap
        total=$(( total + delay ))
    done
    printf '%d' "$total"
}

# Default stale grace: never shorter than the wake sequence it must not
# cut short, and never below the 1800s floor the module shipped with.
_over_limit_grace_default() {
    local seq floor=1800
    seq=$(_over_limit_wake_sequence_seconds)
    (( seq > floor )) && floor="$seq"
    printf '%d' "$floor"
}

_over_limit_hold_expired() {
    local first_seen="$1" reset_epoch="$2" now="$3"
    local max_hold="${MONITOR_OVER_LIMIT_MAX_HOLD_SECONDS:-90000}"
    [[ "$max_hold" =~ ^[0-9]+$ ]] || max_hold=90000
    local grace="${MONITOR_OVER_LIMIT_STALE_GRACE_SECONDS:-}"
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=$(_over_limit_grace_default)
    if [[ "$first_seen" =~ ^[0-9]+$ ]] && (( now - first_seen > max_hold )); then
        return 0
    fi
    if [[ "$reset_epoch" =~ ^[0-9]+$ ]] && (( now > reset_epoch + grace )); then
        return 0
    fi
    return 1
}

# Is the orchestrator's emit channel suppressed?
#
# The gate is NOT "a row exists" (your-org/nexus-code#592). A row is a
# PREDICTION — it says a pane was suspended and names a computed instant. The
# suppression it drives is total: main.sh composes each emit, archives it, then
# refuses to paste. So a stale row severs operator→orchestrator communication
# entirely, in silence, with the orchestrator visibly alive and heartbeating.
# Measured 2026-07-29: "emit paste suppressed: orchestrator over-limit" logged
# once per ~50s cycle for over FIFTEEN HOURS after the quota had actually
# reset, withholding an operator comment and four spawn-skeptic requests. That
# is a strictly worse outage than the late wake that triggered it. The same
# class latched on 2026-09-02 (889 emits over 6h36m while the pane itself
# probed `state=busy active=1`).
#
# Four independent bounds, each sufficient to OPEN the gate:
#
#   (1) No `_orchestrator` row.
#   (2) EXPIRED by _over_limit_hold_expired (absolute ceiling, or the row's
#       own stored deadline plus the stale grace). The wake loop is the
#       mechanism that clears such a row, and this predicate must not
#       depend on the wake loop having run.
#   (3) SESSION ROTATED (issue #161): the row belongs to a session that no
#       longer occupies the pane. The wake loop DROPS such a row, but the
#       wake is not due until reset_epoch + margin, while a rotation inside
#       a live hold closes this gate immediately. Same independence
#       argument as (2).
#   (4) STALE OBSERVATION (#592): the suspension was last OBSERVED longer
#       ago than MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS. The
#       observation epoch lives in the sidecar and is stamped only by
#       `_over_limit_record`, i.e. only when a scan actually saw the pane
#       render the over-limit notice. During a genuine hold the 60s scan
#       refreshes it continuously and the gate stays closed. The moment
#       observation stops — pane recovered, scan wedged, probe broken,
#       epoch miscomputed — it goes stale and the gate OPENS.
#
# A row with NO observation on record at all (a state dir written before
# the sidecar existed, or a hand-written row) is judged by (1)-(3) alone.
# Merge note: the two parent lines disagreed here — one opened the gate on
# a missing sidecar, the other kept a legacy row suppressing until its own
# deadline. (2) still bounds such a row, so it cannot latch.
_over_limit_orchestrator_paused() {
    local path row now window role reset_epoch first_seen session
    local staleness observed
    path=$(_over_limit_state_path) || return 1
    [[ -f "$path" ]] || return 1
    row=$(awk -F'\t' '$1 == "_orchestrator" { print; found=1; exit } END { exit !found }' "$path") \
        || return 1
    IFS=$'\t' read -r _ window role _ reset_epoch first_seen _ _ session <<<"$row"
    now=$(date +%s)
    _over_limit_hold_expired "$first_seen" "$reset_epoch" "$now" && return 1
    _over_limit_session_rotated "$window" "$role" "$session" && return 1
    observed=$(_over_limit_observation_get "_orchestrator")
    if [[ "$observed" =~ ^[0-9]+$ ]]; then
        staleness="${MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS:-600}"
        [[ "$staleness" =~ ^[0-9]+$ ]] || staleness=600
        (( now - observed <= staleness )) || return 1
    fi
    return 0
}

# Atomic rewrite: read all rows, replace any with matching key, append
# the new row, rename into place. NINE fields; every other per-key datum
# goes to a sidecar (see the observation sidecar above).
# `session` ($9) is optional: an omitted value writes an empty ninth
# field, which reads back as "session unknown" and skips the identity
# test. Optional rather than required so an in-memory caller from an
# older source set still writes a well-formed row.
_over_limit_write_row() {
    local key="$1" window="$2" role="$3" token="$4"
    local reset_epoch="$5" first_seen="$6" next_attempt="$7" attempts="$8"
    local session="${9:-}"
    local path tmp dir
    path=$(_over_limit_state_path) || return 1
    dir=$(dirname "$path")
    mkdir -p "$dir" 2>/dev/null || true
    tmp=$(mktemp "${path}.XXXXXX")
    if [[ -f "$path" ]]; then
        awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$next_attempt" "$attempts" \
        "$session" \
        >> "$tmp"
    mv "$tmp" "$path"
}

_over_limit_record() {
    local key_raw="$1" window="$2" role="$3" token="$4"
    [[ -n "$key_raw" && -n "$window" && -n "$role" ]] || return 1
    local key
    key=$(_over_limit_sanitize_key "$key_raw")
    local now wake_margin first_seen attempts session
    now=$(date +%s)
    wake_margin="${MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS:-300}"
    [[ "$wake_margin" =~ ^[0-9]+$ ]] || wake_margin=300
    first_seen=$now
    attempts=0
    # The session that owns this suspension (issue #161). Resolved on
    # every refresh, not just on insert: a refresh re-reads a pane that
    # STILL renders over-limit, so the freshest answer is the right one.
    # An unresolvable id falls back to whatever the row already carried,
    # so a transient read failure never erases a known identity.
    session=$(_over_limit_resolve_session "$window" "$role")
    # Empty ⇒ "compute fresh below". A refresh of an UNCHANGED hold carries
    # both forward from the existing row instead.
    local reset_epoch="" next_attempt=""
    # Anchor for a fresh computation. `now` for a new row or a token the
    # renderer has just changed; first_seen when HEALING a row (below), since
    # that is when the banner we are re-deriving from was actually observed.
    local anchor_now="$now"
    local existing _
    existing=$(_over_limit_load "$key") || existing=""
    # LIVENESS PRECEDENCE, and note the scope: this gates CREATION of a row,
    # never the refresh of one that already exists.
    #
    # That boundary is the whole reason this cannot weaken the hold. A refresh
    # is what keeps the observation sidecar fresh through a genuine multi-hour
    # suspension; blocking it would let the emit gate open mid-hold on
    # staleness, which is the failure the hold exists to prevent. Re-CREATION
    # is a different event — it happens only after the row was dropped, i.e.
    # after this module already concluded the pane had resumed — and it is the
    # one the measured loop consisted of.
    #
    # Suppressing the record deliberately also suppresses the observation
    # write below, so the emit gate opens rather than staying shut on evidence
    # we have positive reason to disbelieve. That is this module's stated
    # polarity: absent evidence of suspension opens the gate, because emitting
    # into a live pane is cheap and withholding is not.
    if [[ -z "$existing" ]]; then
        local _live_reason
        if _live_reason=$(_over_limit_liveness_suppressed "$key" "$now") \
            && [[ -n "$_live_reason" ]]; then
            "$_OVER_LIMIT_LOG_FN" \
                "over-limit: '${window}' (key=${key}) reads over-limit but was already ${_live_reason}; NOT stamping — one banner instance gets one resume, and the turn that brief started has not ended yet"
            return 0
        fi
    fi
    if [[ -n "$existing" ]]; then
        local e_token e_reset e_first e_next e_attempts e_session
        IFS=$'\t' read -r _ _ _ e_token e_reset e_first e_next e_attempts e_session \
            <<<"$existing"
        [[ "$e_first" =~ ^[0-9]+$ ]] && first_seen="$e_first"
        [[ "$e_attempts" =~ ^[0-9]+$ ]] && attempts="$e_attempts"
        [[ -n "$session" ]] || session="$e_session"
        # THE RATCHET FIX (your-org/nexus-code#581; the same defect was
        # measured independently as the DEADLINE FREEZE, issue #500 — a
        # reset_epoch 19.0h in the future on a row whose first_seen was
        # 6.6h old, 2026-09-02). An ongoing hold KEEPS the
        # reset instant it was first given. Recomputing it on every refresh is
        # what broke the wake loop: the token states a wall-clock time with NO
        # DATE, so the parser can only answer "today's occurrence, else
        # tomorrow's" — memoryless. `_over_limit_scan_panes` refreshes every
        # 60s and a suspended pane keeps reading over-limit (the banner never
        # repaints on its own), so at the instant the reset arrives the very
        # next scan re-resolves the same token to TOMORROW and rewrites
        # next_attempt with it. The wake was due at reset+5min; the refresh
        # moved it a full day out ~4 minutes before it could fire, every time.
        # Observed 2026-07-28: four panes (orchestrator + three workers)
        # parked at 2026-07-30 03:00 with attempts=0 — not one wake attempt
        # was ever due. Carrying next_attempt forward also stops the refresh
        # from wiping the wake loop's exponential-backoff progress.
        # Only a CHANGED token — the renderer now states a different reset
        # time — may move the horizon, which is the mid-suspension update the
        # original recompute existed to serve.
        if [[ "$e_token" == "$token" ]] \
            && [[ "$e_reset" =~ ^[0-9]+$ ]] && [[ "$e_next" =~ ^[0-9]+$ ]]; then
            # SELF-HEAL, by EXACT re-derivation (skeptic finding B on #582).
            #
            # Post-fix the horizon is computed exactly once, at first
            # observation, so a healthy row satisfies the invariant
            #     reset_epoch == parse(token, first_seen)
            # and a row the pre-fix code ratcheted does not. Comparing against
            # that re-derivation is therefore an exact test.
            #
            # It replaces a `> first_seen + 90000` threshold, which could not
            # discriminate: legitimate horizons occupy (first, first+90000] and
            # ratcheted ones (first+86400, first+176400], so a row stamped less
            # than an hour before its reset ratcheted into the overlap and was
            # preserved verbatim — stalling a further ~24h past the upgrade.
            #
            # Anchor at FIRST_SEEN, not `now`: the banner was observed at
            # first_seen, so that reproduces the horizon the row should have
            # had. Re-deriving at `now` would just reproduce the ratchet, since
            # the reset has by then passed and `now` answers "tomorrow" again.
            #
            # Residual (accepted, narrow): if the renderer CHANGED the token
            # mid-hold to a time that had already passed between first_seen and
            # the change, the re-derivation disagrees and this heals
            # spuriously. Consequence is an early wake, not a stall — the
            # fail-open direction — and it self-terminates at MAX_ATTEMPTS.
            # Discriminating it exactly would need the anchor stored as its own
            # column; not worth a second schema change for a documented edge.
            local expected_reset
            expected_reset=$(_over_limit_reset_at_to_epoch "$token" "$e_first")
            if [[ "$e_reset" != "$expected_reset" ]]; then
                anchor_now="$e_first"
                "$_OVER_LIMIT_LOG_FN" \
                    "over-limit: '${window}' (key=${key}) horizon ${e_reset} disagrees with the re-derivation from first_seen (${expected_reset}); healing"
            else
                reset_epoch="$e_reset"
                next_attempt="$e_next"
            fi
        fi
    elif [[ "$key" == "_orchestrator" ]]; then
        # Fresh orchestrator hold (no prior row) → start the off-time log
        # so it describes THIS incident from the moment emits begin to be
        # held. Refreshes of an existing hold leave it untouched.
        _over_limit_held_log_start "$now"
    fi
    if [[ -z "$reset_epoch" ]]; then
        reset_epoch=$(_over_limit_reset_at_to_epoch "$token" "$anchor_now")
    fi
    # Hard upper bound on the deadline. A token change (or a heal) is the
    # path that still recomputes reset_epoch, so clamp the result to the
    # absolute ceiling: no stored deadline may sit beyond
    # first_seen + MAX_HOLD, which guarantees the wake comes due inside
    # the ceiling instead of being pushed past it.
    local max_hold="${MONITOR_OVER_LIMIT_MAX_HOLD_SECONDS:-90000}"
    [[ "$max_hold" =~ ^[0-9]+$ ]] || max_hold=90000
    if (( reset_epoch > first_seen + max_hold )); then
        reset_epoch=$(( first_seen + max_hold ))
        next_attempt=""
    fi
    if [[ -z "$next_attempt" ]]; then
        next_attempt=$(( reset_epoch + wake_margin ))
        # Don't push next_attempt into the past if we've been sitting on a
        # stamp longer than the reset window suggested. Lower bound is now.
        #
        # NOTE (skeptic finding C on #582): this clamp means a HEALED row does
        # not fire immediately — its re-derived horizon is already past, so it
        # lands here and fires at now + wake_margin (300s). That is the
        # intended behaviour, not an oversight: it keeps the margin's
        # clock-skew allowance and avoids a thundering wake the instant the
        # watcher restarts. After a stall measured in hours, 300s is noise.
        (( next_attempt > now )) || next_attempt=$(( now + wake_margin ))
    fi
    _over_limit_write_row "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$next_attempt" "$attempts" "$session"
    # `now` IS the observation: _over_limit_record is only ever reached from a
    # scan that just saw this pane render the over-limit notice. This is the
    # ONLY writer of the sidecar. Because every other mutator touches the row
    # file and not this one, "backing off is not an observation" and "reconcile
    # must not forge an observation" are STRUCTURAL rather than a discipline
    # each call site has to remember.
    _over_limit_observation_set "$key" "$now"
}

_over_limit_drop() {
    local key_raw="$1" window="${2:-}"
    [[ -n "$key_raw" ]] || return 1
    local key path tmp row
    key=$(_over_limit_sanitize_key "$key_raw")
    path=$(_over_limit_state_path) || return 1
    # Retire the JSON stamp alongside the row. The window comes from the
    # row itself unless the caller named one, because the key is NOT the
    # window for an orchestrator row (`_orchestrator` is a role constant).
    # This runs BEFORE the row rewrite — the row is where the window name
    # lives, so reading it afterwards would read nothing.
    if [[ -z "$window" ]]; then
        row=$(_over_limit_load "$key" 2>/dev/null) || row=""
        [[ -n "$row" ]] && window=$(awk -F'\t' 'NR==1 {print $2}' <<<"$row")
    fi
    _over_limit_retire_stamp "$window"
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX")
    awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$path"
    else
        # Empty result — drop the file entirely so callers can use
        # `[[ -f path ]]` as a "any rows?" probe.
        rm -f "$path"
        rm -f "$tmp"
    fi
    # Keep the sidecar in step so it cannot accumulate entries for keys that
    # no longer exist, and so a re-stamped key starts from a fresh observation.
    _over_limit_observation_drop "$key"
    _over_limit_flavour_drop "$key"
}

# Probe one pane via pane-state.sh; emit `state reset_at` on stdout
# (space-separated). Empty stdout on resolver failure.
#
# Shared-recording consumer (your-org/nexus-code#562): serves the
# current sweep loop's recording of this window when `_pane_cache.sh`
# is loaded and the entry is fresh, instead of re-forking
# pane-state.sh; a direct fork's result is recorded for reuse.
# Optional $2 = expected window name (reused-index guard). Worst-case
# recording staleness (cache TTL, default 90s) is far inside the
# over-limit signal's own time constants (a limit episode lasts
# hours; the scan cadence is 60s). Fail-open on every cache condition.
_over_limit_probe_pane() {
    local window_arg="$1" expected_name="${2:-}"
    local line state reset_at flavour
    if declare -F _pane_cache_read >/dev/null 2>&1; then
        line=$(_pane_cache_read "$window_arg" "$expected_name") || line=""
    else
        line=""
    fi
    if [[ -z "$line" ]]; then
        local pane_state_script
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
            pane_state_script="$NEXUS_ROOT/monitor/pane-state.sh"
        elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../pane-state.sh" ]]; then
            pane_state_script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pane-state.sh
        else
            return 0
        fi
        local hb_args=()
        if [[ -n "${MONITOR_HEARTBEAT_STALENESS_SECONDS:-}" ]] \
            && [[ "$MONITOR_HEARTBEAT_STALENESS_SECONDS" =~ ^[0-9]+$ ]]; then
            hb_args+=(--heartbeat-staleness "$MONITOR_HEARTBEAT_STALENESS_SECONDS")
        fi
        line=$("$pane_state_script" "${hb_args[@]}" "$window_arg" 2>/dev/null) || return 0
        if [[ -n "$line" ]] && declare -F _pane_cache_write >/dev/null 2>&1; then
            _pane_cache_write "$window_arg" "$line"
        fi
    fi
    state=$(printf '%s' "$line" | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
    reset_at=$(printf '%s' "$line" | sed -n 's/.*reset_at=\([^ ]*\).*/\1/p')
    # WHICH limit, carried alongside (your-org/nexus-code#1488). Absent on a
    # pane-state that predates the field, which resolves to `unknown` and
    # renders as "usage" — never as a model tier nobody measured.
    flavour=$(printf '%s' "$line" | sed -n 's/.*[ ]limit=\([^ ]*\).*/\1/p')
    [[ -n "$state" ]] || return 0
    printf '%s %s %s' "$state" "${reset_at:-unknown}" "${flavour:-unknown}"
}

# Scan the orchestrator pane + every worker pane. Stamp any returning
# state=over-limit. Reuses _idle_list_worker_windows from
# _idle_probe.sh for the worker enumeration so the reserved-name
# filter (target / cockpit `services` / `watcher` / `claude` /
# `orchestrator` / `monitor` + registry services) stays in one place.
_over_limit_scan_panes() {
    local target="${1:?target window required}"
    local probe state reset_at flavour
    # Orchestrator pane: name-targeted lookup. tmux's send-keys et al.
    # accept the window NAME, so pane-state.sh — which expects an
    # index or `session:window` — needs the index resolved first.
    # The resolver's rc is deliberately NOT split here (contrast the wake
    # path below, your-org/nexus-code#699): this arm's failure action is to
    # do NOTHING — no stamp recorded, no state dropped — which is already
    # the safe verdict for both "absent" and "could not look". Empty stdout
    # covers both. Do not "fix" this into a drop.
    local orch_index
    orch_index=$(_over_limit_resolve_window_index "$target" || true)
    if [[ -n "$orch_index" ]]; then
        probe=$(_over_limit_probe_pane "$orch_index" "$target")
        if [[ -n "$probe" ]]; then
            read -r state reset_at flavour <<<"$probe"
            if [[ "$state" == "over-limit" ]]; then
                _over_limit_record "_orchestrator" "$target" \
                    "orchestrator" "$reset_at"
                _over_limit_flavour_set "_orchestrator" "${flavour:-}"
            else
                _over_limit_reconcile_alive "_orchestrator" "$state"
            fi
        fi
    fi
    # Workers: only when _idle_probe.sh is sourced (it provides the
    # reserved-name filter). If the lister isn't available, we
    # silently skip worker stamps — orchestrator stamps still work.
    if declare -F _idle_list_worker_windows >/dev/null 2>&1; then
        local name activity_epoch window_index
        while IFS=$'\t' read -r name activity_epoch window_index; do
            [[ -n "$name" ]] || continue
            local probe_target="${window_index:-$name}"
            probe=$(_over_limit_probe_pane "$probe_target" "$name")
            [[ -n "$probe" ]] || continue
            read -r state reset_at flavour <<<"$probe"
            if [[ "$state" == "over-limit" ]]; then
                _over_limit_record "$name" "$name" "worker" "$reset_at"
                _over_limit_flavour_set "$(_over_limit_sanitize_key "$name")" "${flavour:-}"
            else
                _over_limit_reconcile_alive "$name" "$state"
            fi
        done < <(_idle_list_worker_windows)
    fi
}

# RECONCILE ON OBSERVED LIVENESS (your-org/nexus-code#592).
#
# The scan probes every pane every 60s and, until now, threw the answer away
# unless it read `over-limit`. That is the whole bug behind the 15-hour emit
# blackout: resumption was detected ONLY by the wake loop, which is gated on
# `now >= next_attempt`, so a row parked at a miscomputed instant kept the
# suppression gate shut while the scan watched a demonstrably live pane every
# minute and said nothing.
#
# Correct division of labour: the epoch decides when to start NUDGING a pane
# that still looks suspended; only OBSERVATION decides when to stop
# SUPPRESSING. So when a stamped pane probes as anything other than
# `over-limit`, expedite its row — set next_attempt to now — and let the wake
# loop (5s cadence) run its existing, tested resumption path on the next tick:
# re-probe, paste the right brief, stamp the machine-input ledger for a worker,
# drop the row. Expediting rather than duplicating that logic keeps one
# resumption implementation.
#
# `absent`/`blocked` are deliberately included: those mean the pane is gone,
# and the wake loop's handler for them is to drop the row — which is exactly
# the reconciliation wanted. An empty probe never reaches here (the caller
# skips it), so a broken pane-state.sh cannot expedite anything.
_over_limit_reconcile_alive() {
    local key_raw="$1" state="$2"
    [[ -n "$key_raw" && -n "$state" ]] || return 0
    local key row
    key=$(_over_limit_sanitize_key "$key_raw")
    row=$(_over_limit_load "$key") || return 0
    [[ -n "$row" ]] || return 0
    local r_key window role token reset_epoch first_seen next_attempt attempts session
    IFS=$'\t' read -r r_key window role token reset_epoch first_seen next_attempt \
        attempts session <<<"$row"
    local now
    now=$(date +%s)
    # A malformed next_attempt is already treated as due by the wake loop.
    [[ "$next_attempt" =~ ^[0-9]+$ ]] || return 0
    # Already due — the wake loop will handle it this tick; don't churn the file.
    (( next_attempt > now )) || return 0
    "$_OVER_LIMIT_LOG_FN" \
        "over-limit: '${window}' (key=${key}) observed alive (state=${state}) while stamped with a wake $(( next_attempt - now ))s out; expediting to now"
    _over_limit_write_row "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$now" "$attempts" "$session"
}

# RELEASE EVERY ROW on a CREDENTIAL CHANGE (your-org/nexus-code#1739; skeptic S2
# on #1741). A re-login / account switch lifts the OLD account's limit before any
# row's reset epoch, and a wake stamped hours out would otherwise sit there.
#
# MOVING THE CLOCK ALONE RESUMES NOTHING — the first cut claimed it "let the wake
# loop's existing, tested resumption path run", and that was false: pane-state.sh
# answers `over-limit` from the hook's unexpired StopFailure stamp
# (`over-limit/<window>.json`) BEFORE it reads the pane, so the expedited row read
# `over-limit`, consumed an attempt per wake (60/120/240 s) and failed open ~7 min
# later — hours before reset_at whenever the event was not a real reset.
#
# THE CHOICE, stated: option (a), fail open IMMEDIATELY, and ONLY on
# `credential-change`. A new identity is positive evidence that the stamp
# describes the old account's limit, so each row's stamp is moved aside (kept as
# `*.released-credential-change.<epoch>` for audit — pane-state reads only
# `<window>.json`) and `attempts` is set one short of the cap. On the next wake a
# live pane takes the resume path; a pane still rendering the banner takes the
# fail-open probe AT ONCE (the wake brief; a still-limited turn re-stamps via
# StopFailure). Every OTHER source (`over-limit-resumed:*`) touches NO row: one
# busy pane is evidence of quota, not that another pane's stamp is stale, and
# expediting such a row would only burn its attempts toward an early fail-open
# (option (b), restoring next_attempt afterwards, was rejected as two writes to
# undo one). Those rows keep their own clocks; `_over_limit_reconcile_alive`
# already expedites any of them the scan sees alive. Prints the count changed.
# The stamp directory is `_over_limit_stamp_dir` (session-identity block
# above), which resolves through `_over_limit_state_dir`.

_over_limit_expedite_all() {
    local source="${1:-reset-event}" path now n=0 snapshot row
    if [[ "$source" != credential-change ]]; then
        printf '0'; return 0
    fi
    path=$(_over_limit_state_path) || { printf '0'; return 0; }
    [[ -f "$path" ]] || { printf '0'; return 0; }
    now=$(date +%s)
    snapshot=$(cat "$path" 2>/dev/null)
    local max_attempts="${MONITOR_OVER_LIMIT_MAX_ATTEMPTS:-4}"
    [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=4
    local key window role token reset_epoch first_seen next_attempt attempts session
    local sdir stamp new_attempts new_next
    sdir=$(_over_limit_stamp_dir) || { printf '0'; return 0; }
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        # Ninth field named (issue #161) so `attempts` parses intact and the
        # session id is carried through the rewrite below.
        IFS=$'\t' read -r key window role token reset_epoch first_seen next_attempt \
            attempts session <<<"$row"
        [[ "$next_attempt" =~ ^[0-9]+$ ]] || continue
        [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
        new_next="$next_attempt"; new_attempts="$attempts"
        (( next_attempt > now )) && new_next="$now"
        stamp="$sdir/${window}.json"
        if [[ -f "$stamp" ]]; then
            mv -f "$stamp" "$stamp.released-${source}.${now}" 2>/dev/null \
                && "$_OVER_LIMIT_LOG_FN" \
                    "over-limit: '${window}' (key=${key}) hook stamp released by reset event (${source}) — kept as $(basename "$stamp").released-${source}.${now}"
        fi
        (( max_attempts > 0 && attempts < max_attempts - 1 )) && new_attempts=$(( max_attempts - 1 ))
        [[ "$new_next" == "$next_attempt" && "$new_attempts" == "$attempts" ]] && continue
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: '${window}' (key=${key}) wake expedited by reset event (${source}) from $(( next_attempt - now ))s out to now (attempts ${attempts} -> ${new_attempts})"
        _over_limit_write_row "$key" "$window" "$role" "$token" \
            "$reset_epoch" "$first_seen" "$new_next" "$new_attempts" "$session"
        n=$(( n + 1 ))
    done <<<"$snapshot"
    printf '%s' "$n"
}

# Resolve a tmux window name to its index (for pane-state.sh).
#
# THREE-STATE, same contract as monitor/_tmux-window.sh's resolvers
# (your-org/nexus-code#699):
#
#   rc 0  index on stdout — present
#   rc 1  tmux answered, no window by that name — genuinely absent
#   rc 3  could NOT look: no tmux binary, `list-windows` failed, or a row
#         came back in a shape we cannot parse
#
# It used to `return 0` with EMPTY stdout for all three, and the wake
# path below read empty as absence and DROPPED the over-limit stamp,
# logging the word "absent" about a window it had never observed. A
# stamp dropped for a window that is actually still frozen means the
# watcher stops holding emits and starts piling them into a dead pane —
# the state is gone and nothing re-derives it.
#
# Deliberately NOT delegating to `resolve_window_index`: _over_limit.sh
# is sourced standalone by four test suites that do not source
# _tmux-window.sh, so a cross-file dependency here would make the helper
# undefined in exactly the hermetic paths that cover it. The contract is
# shared; the implementation is local on purpose — and the manifest arm of
# test-tmux-window-resolver.sh is what keeps the two from drifting.
#
# THE ROW-SHAPE BELT (your-org/nexus-code#701 item C). `#699` gave
# `_tmux_window_check_row` to resolve_window_id/_index and NOT to this
# function, which the same commit rewrote and declared to carry "the same
# contract". With the delimiter defeated the twin answered rc 3 and this one
# answered rc 1 — laundered to ABSENT, missing the `probe_rc >= 2` hold arm
# below, dropping the stamp for a window never observed. That is the `#699`
# defect verbatim, left inside `#699`'s own fix. A row we cannot parse is not
# an answer; it is the absence of one.
_over_limit_resolve_window_index() {
    local name="$1" out rc=0 row rname ridx
    [[ -n "$name" ]] || return 1
    command -v tmux >/dev/null 2>&1 || return 3
    out=$(tmux list-windows -F '#{window_name}|#{window_index}' 2>/dev/null) || rc=$?
    (( rc == 0 )) || return 3
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        rname="${row%|*}"; ridx="${row##*|}"
        if [[ "$row" != *'|'* || -z "$rname" || ! "$ridx" =~ ^[0-9]+$ ]]; then
            return 3
        fi
        [[ "$rname" == "$name" ]] || continue
        printf '%s' "$ridx"
        return 0
    done <<<"$out"
    return 1
}

# Build the SPECIAL first flushed emit that lands in the orchestrator's
# input box when the watcher detects resumption. Per the operator ask
# (your-nexus#275) it explains, in order: (a) what happened — the pane
# was over-limit and the watcher HELD its emits rather than piling them
# into a frozen pane; (b) the state now — limit reset, back online, this
# is the first emit since; (c) where to find a log of the off-time (the
# consolidated held-emit log + the per-emit diff archives). Normal
# state-change emits resume after this one. Arguments:
#   $1  reset_at token (display only)
#   $2  duration seconds (display only — formatted to Hh:MMm:SSs)
#   $3  optional: comma-separated list of currently-stamped worker windows
#   $4  optional: first_seen epoch (the hold start T0); when present the
#       brief prints the explicit T0→reset window
_over_limit_compose_resume_brief() {
    local token="$1" duration="$2" workers="$3" first_seen="${4:-}"
    # Pretty-print the token. The first `_` separates the time from
    # the tz; subsequent `_` chars inside the tz (e.g.
    # `America/Los_Angeles`) MUST be preserved. So we split on
    # first `_` only.
    local pretty
    if [[ "$token" == *_* ]]; then
        pretty="${token%%_*} (${token#*_})"
    else
        pretty="$token"
    fi
    local d_h=$(( duration / 3600 ))
    local d_m=$(( (duration % 3600) / 60 ))
    local d_s=$(( duration % 60 ))
    local pretty_dur
    pretty_dur=$(printf '%dh %02dm %02ds' "$d_h" "$d_m" "$d_s")
    local t0_pretty=""
    if [[ "$first_seen" =~ ^[0-9]+$ ]]; then
        t0_pretty=$(date -d "@$first_seen" -Is 2>/dev/null || printf '%s' "$first_seen")
    fi
    local held_log
    held_log=$(_over_limit_held_log_path)
    {
        printf '=== WATCHER: USAGE-LIMIT RECOVERY (read first) ===\n'
        printf '\n'
        printf 'WHAT HAPPENED: this session hit its usage limit and could not\n'
        printf 'complete turns. The watcher detected the over-limit status and HELD\n'
        printf 'its emits (state-change and eligible-comment pastes) instead of\n'
        printf 'piling them into a frozen pane.\n'
        if [[ -n "$t0_pretty" ]]; then
            printf 'The hold ran from %s until the limit reset (%s) — %s.\n' \
                "$t0_pretty" "$pretty" "$pretty_dur"
        else
            printf 'The hold lasted %s (limit reset: %s).\n' "$pretty_dur" "$pretty"
        fi
        printf '\n'
        printf 'STATE NOW: the limit has reset and you are back online. This is the\n'
        printf 'FIRST emit since recovery; normal state-change emits resume after it.\n'
        if [[ -n "$workers" ]]; then
            printf 'Workers still queued for wake: %s (the watcher pastes a resume\n' "$workers"
            printf 'directive into each as it transitions out).\n'
        else
            printf 'No workers were suspended in this window.\n'
        fi
        printf '\n'
        printf 'LOG OF THE OFF-TIME: the emits held while you were inert are recorded\n'
        printf 'at %s\n' "$held_log"
        printf '(one line per held emit); each full body is archived under\n'
        printf 'monitor/.state/diffs/, and current canonical state is in\n'
        printf 'monitor/.state/last-snapshot.txt. Review the held log to see what you\n'
        printf 'missed, then proceed with bootstrap.sh as on any resumption.\n'
    }
}

# Build the worker-side wake brief. Workers carry their own
# conversation context; a terse "resume" suffices.
_over_limit_compose_worker_brief() {
    local token="$1" flavour="${2:-}" pretty label
    # Same first-underscore-only split as the orchestrator brief.
    if [[ "$token" == *_* ]]; then
        pretty="${token%%_*} (${token#*_})"
    else
        pretty="$token"
    fi
    label=$(_over_limit_flavour_label "$flavour")
    {
        # AN UNKNOWN RESET IS A PROBE, NOT A RESET (your-org/nexus-code#1488).
        # This line used to read "weekly Opus limit reset (unknown)" — it
        # asserted a reset in the same sentence that admitted the time was
        # unknown, and it named a model tier nobody had measured. Both halves
        # were wrong for the worker it was pasted into: the limit was FABLE and
        # the reset time was never established, so the worker was refused again
        # on arrival (2 pastes, 3 rejections).
        #
        # The wake paste is legitimately a PROBE — the fail-open design says so
        # in _over_limit_bump_or_failopen: "if the limit genuinely reset the
        # pasted brief lands; if it is truly still limited, the turn fails".
        # The wording now says what the mechanism does, so a recipient who is
        # STILL limited is not told they are not.
        if [[ -z "$token" || "$token" == unknown ]]; then
            printf 'Watcher probe: your %s limit MAY have reset — the watcher could not establish a reset time from your pane, so this is a PROBE, not a statement that you are back. If you can act, continue the work you had in flight. If you are still limited, ignore this; the refusal re-stamps the hold with the current reset time.\n' "$label"
        else
            printf 'Watcher resume: your %s limit was reported to reset at %s. If you can act, continue the work you had in flight before suspension. If you are still refused, ignore this — the refusal re-stamps the hold.\n' "$label" "$pretty"
        fi
    }
}

# Format human-readable list of currently-stamped worker windows for
# the orchestrator brief. Empty stdout when no worker rows exist.
_over_limit_worker_summary() {
    local path
    path=$(_over_limit_state_path) || return 1
    [[ -f "$path" ]] || return 0
    awk -F'\t' '$3 == "worker" { print $2 }' "$path" \
        | sort -u \
        | paste -sd, -
}

# Fail-open terminal: compose the appropriate brief, paste it (best
# effort — the point is to break the hold, so a paste failure must not
# keep the row alive), and DROP the row so the emit gate reopens. Used
# both when a genuinely-over-limit pane exhausts its wake attempts and
# when an unrecognised pane state must not be allowed to hold the gate
# forever. Orchestrator gets the special resume brief (with T0); workers
# get the terse brief + a machine-input ledger stamp (stamp-before-paste,
# #293).
_over_limit_failopen() {
    local key="$1" window="$2" role="$3" token="$4" first_seen="$5" now="$6"
    local duration=$(( now - first_seen ))
    (( duration >= 0 )) || duration=0
    local body
    body=$(mktemp)
    if [[ "$role" == "orchestrator" ]]; then
        _over_limit_compose_resume_brief \
            "$token" "$duration" "$(_over_limit_worker_summary)" "$first_seen" > "$body"
    else
        _over_limit_compose_worker_brief "$token" "$(_over_limit_flavour_get "$key")" > "$body"
        _machine_input_stamp "$window" "over-limit-wake"
    fi
    "$_OVER_LIMIT_PASTE_FN" "$window" "$body" || true
    rm -f "$body"
    _over_limit_drop "$key" "$window"
}

# "Still suspended" step: increment attempts, and at MAX_ATTEMPTS FAIL
# OPEN (paste + drop) instead of backing off forever. This is the
# anti-latch guarantee — EVERY non-resumption branch routes through here
# so no pane state can suppress emits indefinitely. `state_label` is for
# the log line only. Returns 0.
_over_limit_bump_or_failopen() {
    local key="$1" window="$2" role="$3" token="$4" reset_epoch="$5" \
          first_seen="$6" attempts="$7" now="$8" state_label="$9"
    local new_attempts=$(( attempts + 1 ))
    local max_attempts="${MONITOR_OVER_LIMIT_MAX_ATTEMPTS:-4}"
    [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=4
    if (( new_attempts >= max_attempts )); then
        # A bare drop here would be a latch: the next _over_limit_scan_panes
        # re-stamps the still-suspended-reading pane with a FRESH reset
        # horizon, so "drop and wait" silently re-arms the suppression
        # forever (the pane never changes precisely BECAUSE we stopped
        # pasting). The wake paste is the probe that breaks the cycle — if
        # the limit genuinely reset the pasted brief lands and the pane
        # recovers; if it is truly still limited, the turn fails, the
        # StopFailure hook re-stamps with the CURRENT reset time, and the
        # next hold starts from accurate data. Cost is one paste; a
        # wrongly-held channel hangs the whole nexus (2026-07-14, 63 emits
        # into a frozen orchestrator).
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: max wake attempts (${max_attempts}) reached for '${window}' (key=${key}, state=${state_label}); failing OPEN — pasting wake brief and dropping stamp"
        _over_limit_failopen "$key" "$window" "$role" "$token" "$first_seen" "$now"
        return 0
    fi
    _over_limit_apply_backoff "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$new_attempts" "$now"
    "$_OVER_LIMIT_LOG_FN" \
        "over-limit: '${window}' still suspended (state=${state_label}, attempt ${new_attempts}/${max_attempts}); next probe at $(date -d "@$(_over_limit_load_next_attempt "$key")" -Is 2>/dev/null || echo '?')"
    return 0
}

# Per-row wake decision. Args: tab-row from the state file. Mutates
# state (drops row, updates attempts/next_attempt) and pastes via the
# injected _OVER_LIMIT_PASTE_FN.
_over_limit_evaluate_row() {
    local row="$1" now="$2"
    local key window role token reset_epoch first_seen next_attempt attempts session
    IFS=$'\t' read -r key window role token reset_epoch first_seen next_attempt attempts session \
        <<<"$row"
    [[ -n "$key" ]] || return 0

    # ABSOLUTE anti-latch ceiling — the belt over every per-state
    # suspenders. No hold may outlive first_seen + MAX_HOLD regardless of
    # which branch it takes. This closes the ONE path the per-state
    # fail-opens don't: a persistently-FAILING pane-state probe (empty
    # output — not any pane state) backs off without consuming an attempt,
    # so on a broken pane-state.sh it would retry every 60s forever with
    # the gate closed (skeptic round-2 residual, PR #526). It also
    # backstops any future branch that forgets to bound itself. The
    # longest legitimate reset horizon is 24h ("resets <clock-time>"); the
    # default ceiling adds an hour of margin. A negative delta (bogus
    # future first_seen) never trips it.
    #
    # It is checked BEFORE the not-due guard (your-org/nexus-code#581). Behind
    # that guard the "absolute" ceiling was not absolute at all: it could only
    # fire on a row that was already due, so any defect that parked
    # next_attempt in the far future — exactly what the reset-horizon ratchet
    # did — silently disabled the one backstop meant to bound EVERY path. The
    # 2026-07-28 hold ran >12h with a 25h ceiling nominally in force and was
    # ended by a human, not by this check. The same defect was measured
    # independently (issue #500): no ceiling line was logged between
    # 2026-08-26 and the 2026-09-02 incident. A backstop gated on the value
    # it backstops is not a backstop. The cost of running it first is one
    # integer compare per row per tick.
    local max_hold="${MONITOR_OVER_LIMIT_MAX_HOLD_SECONDS:-90000}"  # 25h
    [[ "$max_hold" =~ ^[0-9]+$ ]] || max_hold=90000
    if [[ "$first_seen" =~ ^[0-9]+$ ]] && (( now - first_seen > max_hold )); then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: '${window}' (key=${key}) hold exceeded absolute ceiling (${max_hold}s since first_seen); failing OPEN"
        _over_limit_failopen "$key" "$window" "$role" "$token" "$first_seen" "$now"
        return 0
    fi

    # SESSION IDENTITY — the pane may keep its name across a change of
    # occupant (issue #161). A context rotation cold-spawns a new
    # orchestrator session into a window of the SAME name, so the name
    # lookup below still resolves, the healthy new session probes
    # `idle`, and the resumption branch pastes IT the predecessor's
    # recovery brief. Drop the row instead, with NO paste: the brief
    # describes an outage this session never had, and the hold it
    # represents belongs to a session that is gone.
    #
    # LIKE THE CEILING ABOVE, THIS RUNS BEFORE THE DUE-GATE. A rotation
    # inside a live hold is the damaging case: the pause predicate reads
    # the row on every cycle while the wake is not due until
    # reset_epoch + margin, so a check behind the due-gate would leave a
    # healthy session suppressed for up to the whole remaining hold.
    if _over_limit_session_rotated "$window" "$role" "$session"; then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: '${window}' (key=${key}) was stamped for session ${session}, which no longer occupies the pane; the session was replaced — dropping stamp without a paste"
        _over_limit_drop "$key" "$window"
        return 0
    fi

    # Not due yet — leave the row alone. `next_attempt` is guarded the
    # same way `first_seen` is above: bash arithmetic evaluates array
    # subscripts, so a non-numeric field is a code path, not a syntax
    # error (skeptic finding, PR #116). A malformed field reads as DUE,
    # which routes the row through the probe and the bounded state
    # machine rather than parking it forever on an unusable schedule.
    if [[ ! "$next_attempt" =~ ^[0-9]+$ ]]; then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: '${window}' (key=${key}) has a malformed next_attempt; treating the row as due"
    elif (( now < next_attempt )); then
        return 0
    fi

    # Orchestrator and worker rows resolve identically: the wake loop
    # iterates EVERY row in the state file, and the only role-dependent
    # steps are which brief gets composed and the worker-only
    # machine-input stamp (both below).
    local probe_target probe_rc=0
    probe_target=$(_over_limit_resolve_window_index "$window") || probe_rc=$?
    if (( probe_rc >= 2 )); then
        # COULD NOT LOOK (your-org/nexus-code#699) — no tmux, or
        # `list-windows` failed. Dropping the stamp here would retire the
        # hold for a window we never observed; if it is in fact still
        # over-limit, every subsequent emit piles into a frozen pane and
        # the state that would have told us is gone. HOLD instead: the
        # stamp costs nothing to keep and the next wake re-evaluates.
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: could NOT determine whether window '${window}' (key=${key}) exists (rc ${probe_rc}) — holding the stamp; an unobserved window is not an absent one"
        return 0
    fi
    if (( probe_rc != 0 )) || [[ -z "$probe_target" ]]; then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: window '${window}' (key=${key}) absent at wake; dropping stamp"
        # Pass the window explicitly. This is the path a RETIRED worker
        # window takes, and its JSON stamp is exactly the one a later
        # window of the same name would re-latch off (issue #161).
        _over_limit_drop "$key" "$window"
        return 0
    fi

    local probe state reset_at flavour
    probe=$(_over_limit_probe_pane "$probe_target")
    if [[ -z "$probe" ]]; then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: pane-state probe failed for '${window}' (key=${key}); will retry"
        # Apply backoff so we don't busy-loop on a flaky probe.
        _over_limit_apply_backoff "$key" "$window" "$role" "$token" \
            "$reset_epoch" "$first_seen" "$attempts" "$now"
        return 0
    fi
    read -r state reset_at flavour <<<"$probe"

    case "$state" in
        over-limit)
            # Genuinely still suspended — back off, and fail OPEN at the
            # attempt cap rather than latch.
            _over_limit_bump_or_failopen "$key" "$window" "$role" "$token" \
                "$reset_epoch" "$first_seen" "$attempts" "$now" "over-limit"
            ;;
        absent|blocked)
            "$_OVER_LIMIT_LOG_FN" \
                "over-limit: '${window}' (key=${key}) reads ${state}; pane lost during suspension — dropping stamp"
            _over_limit_drop "$key" "$window"
            ;;
        idle|autosuggest-only|empty|busy|user-typing|working-background|working-self-paced|idle-orphan-async)
            # Resumption. ALL of these mean the pane is alive and
            # servicing turns again — the limit has lifted. The three
            # refined-idle states (working-background, working-self-paced,
            # idle-orphan-async; issue #183) are refinements of `idle`,
            # NOT a distinct suspension: an over-limit orchestrator that
            # recovers on its own (a standing Monitor-handle self-wake or
            # an operator prompt, both routine) and then idles under a
            # `· N monitor ·` footer probes as working-background every
            # cycle. Omitting them here left the row in the `*)` branch,
            # which backed off forever with no cap and latched the emit
            # gate closed indefinitely (skeptic finding, PR #526 round 1).
            # Paste the appropriate brief and drop the stamp. We compute
            # duration from first_seen so it reflects total inertness, not
            # just the last retry leg.
            local duration=$(( now - first_seen ))
            (( duration >= 0 )) || duration=0
            local body
            body=$(mktemp)
            if [[ "$role" == "orchestrator" ]]; then
                local workers
                workers=$(_over_limit_worker_summary)
                _over_limit_compose_resume_brief \
                    "$token" "$duration" "$workers" "$first_seen" > "$body"
            else
                _over_limit_compose_worker_brief "$token" > "$body"
                # Stamp the machine-input ledger BEFORE the worker wake
                # paste (stamp-before-paste ordering). This is a
                # watcher-initiated wake into a *worker* pane, so the
                # resulting UserPromptSubmit must be attributed to the
                # machine, not the operator — an unstamped wake leaves
                # machine_epoch stale and falsely marks the window
                # operator-engaged, holding retire-preflight at safe=0
                # until staleness (#293, gap row 6). Orchestrator wakes
                # are NOT stamped: the orchestrator window is not
                # retire-gated (matches the unstamped orchestrator-pane
                # paths, inventory rows 8/9).
                _machine_input_stamp "$window" "over-limit-wake"
            fi
            if "$_OVER_LIMIT_PASTE_FN" "$window" "$body"; then
                "$_OVER_LIMIT_LOG_FN" \
                    "over-limit: '${window}' resumed (suspended ${duration}s); resume brief pasted"
                # ONE BANNER INSTANCE, ONE RESUME. Armed here and NOT in
                # _over_limit_failopen: the fail-open paste happens while the
                # pane still reads over-limit, so no liveness was observed and
                # nothing has earned a suppression — re-stamping immediately is
                # correct there, and is how the gate re-closes after a paste
                # into a pane that never actually came back.
                _over_limit_liveness_set "$key" "$now" "resumed"
                _over_limit_drop "$key" "$window"
                # A pane observed BUSY again is running a fresh turn: this
                # account has quota, so every worker parked at the rate-limit
                # MENU is owed its nudge now (your-org/nexus-code#1739). `idle`
                # is not evidence — a pane can stop reading over-limit by
                # scrolling — so only `busy` raises the event.
                if [[ "$state" == busy ]] && declare -F _unstick_reset_event_signal >/dev/null 2>&1; then
                    _unstick_reset_event_signal "over-limit-resumed:${window}"
                fi
            else
                "$_OVER_LIMIT_LOG_FN" \
                    "over-limit: '${window}' transitioned out but paste failed; will retry next cycle"
                # Paste failed — re-attempt next cycle without
                # consuming an attempt slot (the suspension is gone;
                # the failure is in the paste path).
                _over_limit_apply_backoff "$key" "$window" "$role" "$token" \
                    "$reset_epoch" "$first_seen" "$attempts" "$now"
            fi
            rm -f "$body"
            ;;
        *)
            # Unrecognised pane state — a future pane-state.sh could add
            # one. Treat conservatively as still-suspended, BUT route
            # through the bounded step so even an unknown state cannot
            # back off forever: it hits the same MAX_ATTEMPTS fail-open as
            # `over-limit`. This is the belt-and-suspenders half of the
            # anti-latch guarantee (the known refined-idle states are
            # handled as resumption above; this catches anything new).
            _over_limit_bump_or_failopen "$key" "$window" "$role" "$token" \
                "$reset_epoch" "$first_seen" "$attempts" "$now" "unexpected:${state}"
            ;;
    esac
}

# Compute the next backoff and rewrite the row. Exponential: 60s →
# 120s → 240s → cap at 300s. Initial backoff and cap are configurable
# via env knobs.
#
# It does NOT touch the observation sidecar, and cannot: backing off is not an
# observation of the pane being over-limit. Advancing it here would let a retry
# loop hold the emit gate closed forever with no fresh evidence; clearing it
# would flap the gate open mid-retry during a genuine hold. Both are structural
# now — this function only writes the row file.
_over_limit_apply_backoff() {
    local key="$1" window="$2" role="$3" token="$4"
    local reset_epoch="$5" first_seen="$6" attempts="$7" now="$8"
    local initial="${MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS:-60}"
    local cap="${MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS:-300}"
    [[ "$initial" =~ ^[0-9]+$ ]] || initial=60
    [[ "$cap"     =~ ^[0-9]+$ ]] || cap=300
    # attempts here is the *resulting* attempt count for the row; the
    # first retry uses `initial`, the second uses `2*initial`, etc.
    local shift_n=$(( attempts > 0 ? attempts - 1 : 0 ))
    (( shift_n > 16 )) && shift_n=16  # guard against pathological << overflow
    local delay=$(( initial << shift_n ))
    (( delay > cap )) && delay=$cap
    (( delay < initial )) && delay=$initial
    local next_attempt=$(( now + delay ))
    # Carry the row's session id (issue #161) through the rewrite. Read
    # from the row rather than taken as a ninth argument: every caller
    # of this helper would otherwise need a new argument, and an arity
    # change on a shared helper is what silently breaks a watcher whose
    # in-memory functions call an updated copy on disk.
    local session
    session=$(_over_limit_row_session "$key")
    _over_limit_write_row "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$next_attempt" "$attempts" "$session"
}

_over_limit_load_next_attempt() {
    local row
    row=$(_over_limit_load "$1") || { printf '0'; return 0; }
    awk -F'\t' '{print $7}' <<<"$row"
}

_over_limit_process_wakes() {
    local target="${1:?target window required}"
    local path now
    path=$(_over_limit_state_path) || return 1
    [[ -f "$path" ]] || return 0
    now=$(date +%s)
    # Snapshot the rows up front so a mid-loop _over_limit_drop /
    # _over_limit_write_row doesn't disturb the iteration.
    local snapshot
    snapshot=$(cat "$path" 2>/dev/null)
    [[ -n "$snapshot" ]] || return 0
    local row
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        _over_limit_evaluate_row "$row" "$now"
    done <<<"$snapshot"
}
