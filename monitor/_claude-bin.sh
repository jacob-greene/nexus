#!/bin/bash
# monitor/_claude-bin.sh — shared $CLAUDE_BIN resolver for spawn surfaces.
#
# Sourced by every script that spawns a `claude` process. Resolves the
# binary path in this order:
#   1. CLAUDE_BIN env var (operator override).
#   2. $NEXUS_ROOT/node_modules/.bin/claude — project-local install,
#      managed by monitor/install-claude-local.sh.
#   3. `claude` on PATH (legacy system install).
# Fails loud with exit 1 if none are found.
#
# Why a shared helper: keeping the resolver in one file means future
# changes (e.g. a third lookup path, version-floor check) land in one
# place instead of drifting across spawn-worker.sh, entry.sh, main.sh,
# spawn-fresh-orchestrator.sh, bootstrap-install.sh, and claude-loop.sh.
#
# Why baked into heredocs at write time: every spawn surface writes a
# /tmp launcher script and tmux-spawns it. The launcher's heredoc is
# unquoted, so $CLAUDE_BIN interpolates at write time and the launcher
# contains the absolute path verbatim. This avoids re-resolving inside
# the launcher's shell (which may not have NEXUS_ROOT set yet).
#
# Caller contract: $NEXUS_ROOT must be set before sourcing. The helper
# is destructive on failure (calls `exit 1`) — that's intentional, a
# spawn surface that can't find claude has no recovery path.

if [[ -z "${NEXUS_ROOT:-}" ]]; then
    echo "_claude-bin.sh: NEXUS_ROOT must be set before sourcing" >&2
    exit 1
fi

if [[ -z "${CLAUDE_BIN:-}" ]]; then
    if [[ -x "$NEXUS_ROOT/node_modules/.bin/claude" ]]; then
        CLAUDE_BIN="$NEXUS_ROOT/node_modules/.bin/claude"
    elif command -v claude >/dev/null 2>&1; then
        CLAUDE_BIN="$(command -v claude)"
    else
        echo "_claude-bin.sh: no claude binary found" >&2
        echo "  Looked for: $NEXUS_ROOT/node_modules/.bin/claude" >&2
        echo "              claude on PATH" >&2
        echo "  Run: $NEXUS_ROOT/monitor/install-claude-local.sh" >&2
        exit 1
    fi
fi
export CLAUDE_BIN

# ---------------------------------------------------------------------------
# THE CAPABILITY PROBE'S BOUND (your-org/nexus-code#1289)
# ---------------------------------------------------------------------------
# `claude_supports_name_flag` runs `"$CLAUDE_BIN" --help`. That call sits on
# the watcher's ORCHESTRATOR-RESPAWN path — `_respawn.sh:716-717`, inside
# `_respawn_compose_launcher`, called at `:1173` immediately before
# `_respawn_spawn_window` at `:1176` — and the whole compose+spawn dance runs
# under the async in-flight guard (`_target_absent.sh:159-162`). So for as
# long as `--help` takes, the guard holds, the orchestrator does not exist,
# and every watcher poll logs the benign-sounding `respawn-agent (async):
# launch deferred (in flight)`. The failure mode is not a crash; it is a
# live-looking watcher repeating a reassuring line while the board has no
# control surface.
#
# THE VALUE IS FITTED, NOT GUESSED. Measured on this host, project-local
# install, 6 warm runs: 331/381/401/331/356/386 ms (mean 370 ms), 16890 bytes,
# rc 0. 10 s is ~27x the warm mean. COVERAGE BOUNDARY, stated because it is
# the case the bound exists for: a COLD read of the binary off shared storage
# was NOT measured and could be materially slower — 10 s is a generous ceiling
# rather than a fitted p99. Override with $NEXUS_CLAUDE_HELP_TIMEOUT;
# $NEXUS_CLAUDE_HELP_TIMEOUT_BIN is a test seam for the `timeout`-ABSENT path
# (never set in production).
#
# WHAT A BOUND CANNOT DO. `timeout` bounds a SLOW probe, not an
# UNINTERRUPTIBLE one: a process wedged in uninterruptible sleep on a stalled
# NFS mount ignores TERM and KILL alike, so `timeout` itself would wait. `-k`
# narrows this (a TERM-ignoring child is KILLed) but cannot close it. This
# change converts the unbounded-hang class into a bounded one; it does not
# claim to make the probe non-blocking.
: "${NEXUS_CLAUDE_HELP_TIMEOUT:=10}"
# DO NOT ADD `--foreground`. Measured on this host, against a stub whose
# `--help` spawns a child `sleep 30`:
#
#   timeout -k 2 1 stub --help              -> rc 124 in  1005 ms
#   timeout --foreground -k 2 1 stub --help -> rc 124 in 30014 ms
#
# `timeout` signals the whole process GROUP by default; `--foreground` signals
# only the direct child, and the orphaned grandchild keeps the command
# substitution's pipe open — so `$( … )` blocks for the child's full lifetime
# and the bound becomes decorative WHILE STILL REPORTING rc 124. A remedy that
# reinstates the defect it was added to fix, and reports success at doing so,
# is worse than no remedy.
#
# Resolved ONCE, here, rather than per call: an absent `timeout` must be
# reported as a real degradation (the wedge is back), not silently tolerated.
# $NEXUS_CLAUDE_HELP_TIMEOUT_BIN is a TEST SEAM (never set in production) and
# is honoured even when set to the EMPTY string — that is how the unbounded
# path is exercised at all. `${VAR+set}` distinguishes "unset" from
# "deliberately empty"; `${VAR:-}` cannot.
if [[ -n "${NEXUS_CLAUDE_HELP_TIMEOUT_BIN+set}" ]]; then
    _CLAUDE_TIMEOUT_BIN="$NEXUS_CLAUDE_HELP_TIMEOUT_BIN"
elif command -v timeout >/dev/null 2>&1; then
    _CLAUDE_TIMEOUT_BIN=$(command -v timeout)
elif [[ -x /usr/bin/timeout ]]; then
    _CLAUDE_TIMEOUT_BIN=/usr/bin/timeout
else
    _CLAUDE_TIMEOUT_BIN=""
fi

# ---------------------------------------------------------------------------
# ONE `--help` PER PROCESS, AND A DISK CACHE OF COMPLETED ANSWERS
# (your-org/nexus-code#1721)
# ---------------------------------------------------------------------------
# Both probes below read the SAME help text, and on a spawn they are asked in
# the same process (`--name`, then `--plugin-dir`). Each used to run its own
# `--help`, so a loaded login node paid the bound twice per launch, and every
# launcher paid it again because nothing outlived the process. Measured on
# another operator's board (your-org/your-nexus#395): 4 of 5 orchestrator
# boots at load ~130-144 logged `armed-unprobed` behind two TIMED OUT --help
# probes — correct outcomes, read by the operator as failures.
#
# _claude_help_answers resolves BOTH answers from ONE source, in order:
#   1. this process's memo, keyed on $CLAUDE_BIN — set only by 2 or 3;
#   2. the disk cache, keyed on realpath($CLAUDE_BIN) + size + mtime + inode;
#   3. ONE bounded `--help`, whose COMPLETED answers are memoised and written
#      to the disk cache.
# A probe that did NOT complete (timeout, or no bytes) is memoised NOWHERE —
# not in this process, not on disk. That is #1611's rule ("UNKNOWN IS NEVER
# CACHED … the next ask may find an idle node"), kept whole: a second ask in
# the same process after an UNKNOWN re-probes, so on a loaded node the two
# timeouts of one launch remain two. What this buys is that the slow case
# becomes RARE: after the first COMPLETED probe of a binary, no launch of that
# binary runs `--help` at all, on any load.
#
# WHY THE KEY IS SOUND. A binary only changes at a cc-update, which replaces
# the file the symlink resolves to (new realpath, size or mtime) — so the key
# cannot outlive the bytes that produced the answer. The bet it makes is that
# `--help` is a function of the binary alone; a stub whose help text varies by
# ENVIRONMENT at one fixed path breaks that bet, which is why the cache is OFF
# under a test fence (below).
#
# WHERE: $NEXUS_CLAUDE_HELP_CACHE_DIR when SET (the EMPTY string disables the
# disk cache — `${VAR+set}`, as for the timeout seam above); otherwise
# ${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}/claude-help-cache, and NOT AT
# ALL when $NEXUS_TEST_FENCE is set (a suite never writes a real .state, and a
# fixture stub must not inherit another case's answer; a suite that tests the
# cache names its directory explicitly). The leaf directory is created only
# when its parent exists, so a fixture NEXUS_ROOT with no .state stays clean.
# Writes are tmp + mv in the same directory (atomic rename). A read that
# fails, or a file that is not exactly `<key>\n<yes|no> <yes|no>\n` for THIS
# key, is ignored and the probe runs — a cache can only ever save a probe,
# never supply an answer it cannot vouch for.
_claude_help_cache_dir() {   # -> the directory; rc 1 = disk cache disabled
    if [[ -n "${NEXUS_CLAUDE_HELP_CACHE_DIR+set}" ]]; then
        [[ -n "$NEXUS_CLAUDE_HELP_CACHE_DIR" ]] || return 1
        printf '%s' "$NEXUS_CLAUDE_HELP_CACHE_DIR"
        return 0
    fi
    [[ -z "${NEXUS_TEST_FENCE:-}" ]] || return 1
    # FENCED AT THE SOURCE, not per suite: the default location serves ONLY
    # this nexus's own pinned binary. A stub or fixture binary (every suite
    # that drives _claude-bin.sh) is never cached by default, whether or not
    # the suite sourced _test_helpers.sh and so got NEXUS_TEST_FENCE. Measured:
    # test-respawn.sh, which does not, wrote the cache into the decoy root in
    # CI's fixture-band decoy gate, and would write the LIVE primary's .state
    # from an agent shell (your-org/nexus-code#1721, skeptic on #1781).
    local pinned='' rp=''
    pinned=$(readlink -f -- "$NEXUS_ROOT/node_modules/.bin/claude" 2>/dev/null) || return 1
    rp=$(readlink -f -- "${CLAUDE_BIN:-}" 2>/dev/null) || return 1
    [[ -n "$pinned" && -f "$pinned" && "$rp" == "$pinned" ]] || return 1
    printf '%s' "${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}/claude-help-cache"
}

_claude_help_key() {   # -> "<size> <mtime.ns> <inode> <realpath>"; rc 1 = unkeyable
    local rp='' st=''
    rp=$(readlink -f -- "$CLAUDE_BIN" 2>/dev/null) || return 1
    [[ -n "$rp" && -f "$rp" ]] || return 1
    st=$(stat -L -c '%s %.9Y %i' -- "$rp" 2>/dev/null) || return 1
    # Validate the SHAPE: a `stat` without %.9Y prints something else at rc 0,
    # and an unvalidated key would still "match" itself on the next read.
    [[ "$st" =~ ^[0-9]+\ [0-9]+(\.[0-9]+)?\ [0-9]+$ ]] || return 1
    printf '%s %s' "$st" "$rp"
}

# _claude_help_answers
#   rc 0  COMPLETED: $_CLAUDE_HELP_ANS_NAME and $_CLAUDE_HELP_ANS_PLUGIN_DIR
#         are `yes`/`no` (from the memo, the disk cache, or one --help).
#   rc 1  NOT completed: $_CLAUDE_HELP_FAIL is `timeout` or `empty`, and
#         $_CLAUDE_HELP_RC is the status. Nothing was memoised or written.
# The warnings stay in the two callers, which decide per FLAG what an answer
# or an UNKNOWN means; this function only establishes what the binary said.
_claude_help_answers() {
    _CLAUDE_HELP_FAIL=''
    _CLAUDE_HELP_RC=0
    if [[ -n "${_CLAUDE_HELP_MEMO_BIN:-}" && "$_CLAUDE_HELP_MEMO_BIN" == "$CLAUDE_BIN" ]]; then
        return 0
    fi
    local dir='' key='' f='' k='' a='' extra='' help_out='' _rc=0 _bounded=0 tmp=''
    if dir=$(_claude_help_cache_dir) && key=$(_claude_help_key); then
        f="$dir/claude-help-$(printf '%s' "$key" | cksum | tr ' ' '-').v1"
        if [[ -f "$f" ]] \
           && { IFS= read -r k && IFS= read -r a && ! IFS= read -r extra; } < "$f" 2>/dev/null \
           && [[ "$k" == "$key" && "$a" =~ ^(yes|no)\ (yes|no)$ ]]; then
            _CLAUDE_HELP_ANS_NAME="${BASH_REMATCH[1]}"
            _CLAUDE_HELP_ANS_PLUGIN_DIR="${BASH_REMATCH[2]}"
            _CLAUDE_HELP_MEMO_BIN="$CLAUDE_BIN"
            return 0
        fi
    else
        f=''
    fi

    # Capture BEFORE testing: `cmd | grep` would report grep's status, not
    # claude's, and a claude that failed to run would read as "no such flag"
    # (CLAUDE.md, pipeline-status entry). $_rc is read on the very next line
    # because anything executing in between is a write to $?.
    if [[ -n "$_CLAUDE_TIMEOUT_BIN" ]]; then
        _bounded=1
        help_out=$("$_CLAUDE_TIMEOUT_BIN" -k 2 "$NEXUS_CLAUDE_HELP_TIMEOUT" "${CLAUDE_BIN}" --help 2>/dev/null)
        _rc=$?
    else
        # No `timeout` on this host: the #1289 wedge is UNBOUNDED again. Say so
        # rather than degrade in silence — a missing bound is exactly the
        # condition whose whole symptom is that nothing appears to be wrong.
        echo "_claude-bin: no 'timeout' binary found — probing '${CLAUDE_BIN} --help' UNBOUNDED. On the watcher respawn path a hang here holds the in-flight guard and the orchestrator stays dead (your-org/nexus-code#1289)." >&2
        help_out=$("${CLAUDE_BIN}" --help 2>/dev/null)
        _rc=$?
    fi

    # A TIMEOUT IS NOT "THE BINARY SAID NO" — and it is not even in the
    # callee's vocabulary (your-org/nexus-code#1248). `timeout` INJECTS 124
    # (TERM fired), 137 (KILL after the `-k` grace) or 125 (`timeout` itself
    # failed). Measured on this host, GNU coreutils 8.28. Tested as a SET and
    # FIRST, before any look at content: a probe that had to be killed already
    # cost the respawn lock, and whatever partial bytes it flushed are not an
    # answer. The `_bounded` gate matters — without it, an UNBOUNDED claude
    # that happened to exit 124 would be mislabelled a timeout.
    if (( _bounded )) && { (( _rc == 124 )) || (( _rc == 125 )) || (( _rc == 137 )); }; then
        _CLAUDE_HELP_FAIL=timeout
        _CLAUDE_HELP_RC=$_rc
        return 1
    fi
    if [[ -z "$help_out" ]]; then
        _CLAUDE_HELP_FAIL=empty
        _CLAUDE_HELP_RC=$_rc
        return 1
    fi
    # ONLY A COMPLETE, rc-0 ANSWER IS AN ANSWER (#1611's rule, skeptic on
    # #1781). A --help that printed a partial usage and then failed would read
    # as "no" for both flags, and with the disk cache that "no" would outlive
    # the process: every later launch drops --name and --plugin-dir until the
    # binary changes. The real binary's --help exits 0 (2.1.293, measured), so
    # this costs nothing on the path that matters.
    if (( _rc != 0 )); then
        _CLAUDE_HELP_FAIL=incomplete
        _CLAUDE_HELP_RC=$_rc
        return 1
    fi

    _CLAUDE_HELP_ANS_NAME=no
    _CLAUDE_HELP_ANS_PLUGIN_DIR=no
    case "$help_out" in *"--name <name>"*)       _CLAUDE_HELP_ANS_NAME=yes ;; esac
    case "$help_out" in *"--plugin-dir <path>"*) _CLAUDE_HELP_ANS_PLUGIN_DIR=yes ;; esac
    _CLAUDE_HELP_MEMO_BIN="$CLAUDE_BIN"

    # Best-effort write: a cache that cannot be written costs the next launch
    # one probe, nothing more, so a failure here is silent by design.
    if [[ -n "$f" ]]; then
        [[ -d "$dir" ]] || { [[ -d "$(dirname -- "$dir")" ]] && mkdir -- "$dir" 2>/dev/null; }
        if [[ -d "$dir" ]]; then
            tmp="$f.tmp.$$"
            if printf '%s\n%s %s\n' "$key" "$_CLAUDE_HELP_ANS_NAME" "$_CLAUDE_HELP_ANS_PLUGIN_DIR" > "$tmp" 2>/dev/null \
               && mv -f -- "$tmp" "$f" 2>/dev/null; then
                :
            else
                rm -f -- "$tmp" 2>/dev/null
            fi
        fi
    fi
    return 0
}

# claude_supports_name_flag
#
# Capability probe for `-n/--name <name>` ("Set a display name for this
# session"), the flag that pins a session's MESSAGING name — the string
# cross-session SendMessage uses as the address (your-org/nexus-code#1047).
#
# By CAPABILITY, never by version string — the same rule monitor/gh-capable.sh
# applies to `gh`. Operators pin and bump Claude Code deliberately
# (skills/nexus.cc-update), so a spawn surface must not assume the flag exists.
#
# Why this is a REFUSAL to add the flag rather than a refusal to spawn: an
# unsupported flag is FATAL, not ignored — measured on this host,
# `claude --nosuchflag-xyz` exits 1 with "error: unknown option". Baking the
# flag in unconditionally would therefore kill every worker spawn AND every
# orchestrator respawn on an older pin, taking out the watcher's own recovery
# path to fix a naming nicety. Degrading to the derived name is strictly better
# than a dead orchestrator.
#
# It warns on stderr when it degrades, because a silently-omitted flag is this
# workspace's dominant defect class: the address quietly reverts to the derived
# name and escalation fails later, far from the cause.
#
# Returns 0 = PASS the flag, 1 = do not. NEVER blocks without a bound when a
# `timeout` binary exists: see $NEXUS_CLAUDE_HELP_TIMEOUT above
# (your-org/nexus-code#1289). A timeout is reported as a TIMEOUT, distinctly
# from "the binary answered and said no" and from "the binary failed to run" —
# the three have different remedies and #1248 is the reason the injected 124
# must not pass for the callee's own status.
#
# rc 0 covers TWO answers, and only the second is new (skeptic pass on #1626,
# the #1611 defect in this probe):
#   YES      the probe COMPLETED and --help lists `--name <name>` (cached)
#   UNKNOWN  the probe did NOT complete — `timeout` killed it (124/125/137).
#            NEVER cached; the reason is left in
#            $_CLAUDE_NAME_FLAG_UNKNOWN_REASON and said on stderr.
# rc 1 is a COMPLETED probe that read the help text and found no flag (cached),
# or an EMPTY --help that was not a timeout — omitted, fail-closed as before,
# but no longer cached either (reason in the same variable).
#
# WHY UNKNOWN PASSES THE FLAG rather than omitting it. Before, an unknown was
# CACHED as `no`: one --help slowed by a loaded node made every later ask in
# that shell omit --name — every `--continue` respawn of a claude-loop.sh
# worker, for its life — and an omitted --name is the SILENT failure: the
# session self-names from its cwd, and cross-session addressing fails later,
# far from the cause. Every caller gates on `claude_supports_name_flag || …`
# with no note of its own (spawn-worker.sh `_spawn_name_arg`), so an unknown
# that returned non-zero would be swallowed exactly as silently. Passing the
# flag bets on the pinned binary, which lists it (skills/nexus.cc-update
# GUIDE); if the bet is wrong the launch dies AT ONCE with `error: unknown
# option` — LOUD, at the cause, and the next ask re-probes because nothing was
# cached. That is the same bet #1611 made for `--plugin-dir` on the same
# spawn and respawn paths. Boundary, stated: an OLDER pin (no --name) probed
# under load fails its launch instead of degrading; the "degrade rather than a
# dead orchestrator" rule above still holds for every COMPLETED probe.
#
# CACHE LIFETIME: the answer is memoised in $_CLAUDE_NAME_FLAG_CACHED for the
# life of THIS shell process only, and it is keyed on nothing — not on
# $CLAUDE_BIN. That is correct for every caller here, because each spawn
# surface resolves $CLAUDE_BIN once and then invokes the probe one or more
# times for that same binary, and the warning is emitted once rather than per
# call site. It is NOT safe for a caller that changes $CLAUDE_BIN and re-asks
# in the same shell: it would get the previous binary's answer. Nothing does
# that in production; test-session-name-from-window.sh probes several different
# binaries, and gets a fresh answer each time because every probe runs in its
# own `( … )` subshell rather than by clearing the cache. A caller that must
# re-ask in ONE shell has to unset $_CLAUDE_NAME_FLAG_CACHED itself — and,
# to re-PROBE the same $CLAUDE_BIN rather than reuse its completed --help,
# $_CLAUDE_HELP_MEMO_BIN as well (that memo IS keyed on $CLAUDE_BIN).
# The flag cache is not exported. Underneath it, the `--help` itself is shared
# with claude_supports_plugin_dir_flag and cached ON DISK per binary
# (_claude_help_answers above, your-org/nexus-code#1721), so a child process
# re-ASKS but does not re-PROBE once any process has completed a probe of
# that binary; the warnings below still fire once per process.
claude_supports_name_flag() {
    _CLAUDE_NAME_FLAG_UNKNOWN_REASON=''
    if [[ -n "${_CLAUDE_NAME_FLAG_CACHED:-}" ]]; then
        [[ "$_CLAUDE_NAME_FLAG_CACHED" == "yes" ]] && return 0
        return 1
    fi
    if ! _claude_help_answers; then
        if [[ "$_CLAUDE_HELP_FAIL" == timeout ]]; then
            # A degraded probe, NOT an error (your-org/nexus-code#1721): the
            # binary was not slow to say no, it was not heard at all, and the
            # launch proceeds on the pinned binary's word. Worded so that the
            # operator reading it on a loaded node does not file it as a fault.
            _CLAUDE_NAME_FLAG_UNKNOWN_REASON="--help probe TIMED OUT (rc ${_CLAUDE_HELP_RC}, bound ${NEXUS_CLAUDE_HELP_TIMEOUT}s) — capability not established"
            echo "_claude-bin: degraded probe, not an error — '${CLAUDE_BIN} --help' did not answer within ${NEXUS_CLAUDE_HELP_TIMEOUT}s (TIMED OUT, killed, rc ${_CLAUDE_HELP_RC}; a loaded node?). --name support is UNKNOWN, not 'unsupported'; not cached; passing --name on the pinned binary's word. Only if this binary lacks it does the launch fail, at once, with 'error: unknown option' (your-org/nexus-code#1047, #1611's rule; bound per #1289)." >&2
            return 0
        fi
        # Could not ask, and NOT for want of time: the binary ran (or could not
        # be run) and printed nothing. Fail CLOSED on the FLAG (omit it),
        # loudly, as before — this is not the load case the TIMEOUT arm above
        # bets on, and test-session-name-from-window.sh section 4 pins it. But
        # NOT cached: it is no answer about the flag either, so the next ask
        # re-probes rather than inheriting it (skeptic pass on #1626).
        _CLAUDE_NAME_FLAG_UNKNOWN_REASON="--help did not complete (${_CLAUDE_HELP_FAIL}, rc ${_CLAUDE_HELP_RC}) — capability not established"
        echo "_claude-bin: could not read '${CLAUDE_BIN} --help' (rc ${_CLAUDE_HELP_RC}) — NOT passing --name (not cached); this session will self-name from its cwd basename and will not be addressable by its tmux window name (your-org/nexus-code#1047)." >&2
        return 1
    fi
    if [[ "$_CLAUDE_HELP_ANS_NAME" == yes ]]; then
        _CLAUDE_NAME_FLAG_CACHED=yes
        return 0
    fi
    _CLAUDE_NAME_FLAG_CACHED=no
    echo "_claude-bin: this claude does not support '--name' — NOT passing it; this session will self-name from its cwd basename and will not be addressable by its tmux window name (your-org/nexus-code#1047)." >&2
    return 1
}

# claude_supports_plugin_dir_flag
#
# Capability probe for `--plugin-dir <path>` ("Load a plugin from a directory
# or .zip for this session only"), the flag that arms the longjob-watch
# dispatcher's plugin monitor at session start (your-org/nexus-code#1535).
# By capability, never by version, bounded exactly as claude_supports_name_flag
# above — but THREE-VALUED where that one is two-valued, and deliberately so
# (your-org/nexus-code#1611):
#
#   rc 0  YES      the probe COMPLETED and the help text carries the flag
#   rc 1  NO       the probe COMPLETED, the help text was read, no flag
#   rc 2  UNKNOWN  the probe did NOT complete: `timeout` killed it (124/137, or
#                  125 — `timeout` itself failed), or `--help` produced no
#                  bytes at all. Nothing was learned about the BINARY.
#
# WHY UNKNOWN HAS TO BE ITS OWN VALUE. Before #1611 all three paths returned 1
# and CACHED `no`, so a --help that was merely SLOW — every session in a mass
# resurrection, when the node is loaded — became a permanent "unsupported" for
# that launcher and the session came back with no longjob-watch dispatcher for
# its whole life, silently. Measured on the operator's live arming.log: `rtevsk`
# `armed` at 14:53:39 and `skipped` at 14:53:47, same binary, 8 s apart — a
# capability cannot change in 8 s. The branch below already KNEW the status was
# the wrapper's (`_bounded` is tested first; #1248: 124 is in no callee's
# vocabulary) and converted it into an answer about the callee anyway. Same
# class as monitor/repo-root.sh's `undetermined`, which exists because "'I could
# not tell' collapses into 'no'".
#
# UNKNOWN IS NEVER CACHED — only a COMPLETED probe is memoised in
# $_CLAUDE_PLUGIN_DIR_FLAG_CACHED (cache lifetime as documented above), and
# only a COMPLETED `--help` reaches the shared memo or the disk cache
# (_claude_help_answers, your-org/nexus-code#1721). A caller that asks again
# in the same shell re-probes, which is the point: the next ask may find an
# idle node. The reason is left in $_CLAUDE_PLUGIN_DIR_FLAG_UNKNOWN_REASON for
# the caller to log.
#
# WHAT THE CALLER DOES WITH UNKNOWN is policy and lives in
# monitor/_longjob-plugin.sh (it arms, logged `armed-unprobed`). This function
# says only what was established. Note the boundary it must respect: an
# unsupported flag is FATAL to `claude` (`error: unknown option`, exit 1 —
# measured, see claude_supports_name_flag's header), so UNKNOWN is not "safe to
# pass" in general; it is safe only where the binary is known to be the pinned
# one, and that argument is made at the call site, not here. The stderr line
# names that policy all the same, worded as a DEGRADED PROBE rather than an
# error (#1721): it is what the operator reads, and it read as a fault.
claude_supports_plugin_dir_flag() {
    _CLAUDE_PLUGIN_DIR_FLAG_UNKNOWN_REASON=''
    if [[ -n "${_CLAUDE_PLUGIN_DIR_FLAG_CACHED:-}" ]]; then
        [[ "$_CLAUDE_PLUGIN_DIR_FLAG_CACHED" == "yes" ]] && return 0
        return 1
    fi
    if ! _claude_help_answers; then
        if [[ "$_CLAUDE_HELP_FAIL" == timeout ]]; then
            _CLAUDE_PLUGIN_DIR_FLAG_UNKNOWN_REASON="--help probe TIMED OUT (rc ${_CLAUDE_HELP_RC}, bound ${NEXUS_CLAUDE_HELP_TIMEOUT}s) — capability not established"
            echo "_claude-bin: degraded probe, not an error — '${CLAUDE_BIN} --help' did not answer within ${NEXUS_CLAUDE_HELP_TIMEOUT}s (TIMED OUT, killed, rc ${_CLAUDE_HELP_RC}; a loaded node?). --plugin-dir support is UNKNOWN, not 'unsupported'; not cached; a launch path that arms on it passes --plugin-dir on the pinned binary's word (armed-unprobed; your-org/nexus-code#1611, #1721)." >&2
            return 2
        fi
        _CLAUDE_PLUGIN_DIR_FLAG_UNKNOWN_REASON="--help did not complete (${_CLAUDE_HELP_FAIL}, rc ${_CLAUDE_HELP_RC}) — capability not established"
        echo "_claude-bin: degraded probe — could not read '${CLAUDE_BIN} --help' (rc ${_CLAUDE_HELP_RC}). --plugin-dir support is UNKNOWN, not 'unsupported'; not cached; a launch path that arms on it passes --plugin-dir on the pinned binary's word (armed-unprobed; your-org/nexus-code#1611, #1721)." >&2
        return 2
    fi
    if [[ "$_CLAUDE_HELP_ANS_PLUGIN_DIR" == yes ]]; then
        _CLAUDE_PLUGIN_DIR_FLAG_CACHED=yes
        return 0
    fi
    _CLAUDE_PLUGIN_DIR_FLAG_CACHED=no
    echo "_claude-bin: this claude does not support '--plugin-dir' (its --help was read and does not list it) — NOT passing it; this session will have NO longjob-watch dispatcher and cannot be woken by a long job (your-org/nexus-code#1535)." >&2
    return 1
}
