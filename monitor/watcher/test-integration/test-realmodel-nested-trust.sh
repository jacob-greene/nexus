#!/usr/bin/env bash
# Real-binary scenario: the nested-git-repo folder-trust dialog
# (cc 2.1.232 compat).
#
# Claude Code 2.1.232 ended trust INHERITANCE for nested git repos —
# "each repository now requires its own trust confirmation". Every nexus
# worker is spawned into a nested git repo (`work/<project>/`, a fresh
# clone or worktree beneath the nexus root, itself a repo), so from
# 2.1.232 on such a spawn parks PRE-REPL on:
#
#     ❯ 1. Yes, I trust this folder
#       2. No, exit
#
# `--dangerously-skip-permissions` does NOT bypass it. Before the compat
# fix, pane-state classified the frame `empty` (the state
# retire-preflight reads as safe-to-kill) and none of `_unstick.sh`'s
# cases matched its text — a stranded worker with no recovery path.
#
# WHY THE REST OF THE HARNESS CANNOT CATCH THIS: `_lib.sh::cch_setup`
# seeds `projects.<CCH_WORKDIR>.hasTrustDialogAccepted = true` for the
# exact cwd it then boots in, so the inheritance path is never
# exercised. This scenario deliberately builds the production topology
# instead — a TRUSTED parent repo with an UNTRUSTED nested repo beneath
# it — and boots in the nested one.
#
# It asserts, against the real candidate binary:
#   A. the dialog (if this release renders one) classifies `blocked`,
#      not `empty` — pane-state's `_has_trust_overlay`;
#   B. `_unstick.sh` recognises it as case `trust` and its Enter clears
#      it to a usable REPL — the recovery layer;
#   C. `spawn-worker.sh::_pre_accept_workspace_trust` prevents the
#      dialog outright — the prevention layer.
#
# On a release that still inherits trust (≤ 2.1.231) A and B are
# vacuous: the pane boots straight to idle. That is asserted explicitly
# rather than skipped, so this scenario is meaningful on both sides of
# the behaviour change and never green-via-skip.
set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../../.." && pwd)
# shellcheck source=/dev/null
. "$_self_dir/../../cc-harness/_lib.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

cch_skip_if_disabled

echo "=== real-binary harness: nested-repo folder trust ==="
printf '    claude:  %s\n' "$(cch_resolve_claude)"

cch_setup || exit 1

# --- production topology: trusted parent repo, untrusted nested repo ---
PARENT="$CCH_DIR/parent"
CHILD="$PARENT/work/child"
mkdir -p "$CHILD"
git -C "$PARENT" init -q 2>/dev/null
git -C "$CHILD"  init -q 2>/dev/null
printf 'root\n'  > "$PARENT/README.md"
printf 'child\n' > "$CHILD/README.md"

# Trust ONLY the parent. The nested repo is absent from projects{}
# entirely — the state a freshly-created work/<project> is in.
seed_parent_only() {
    cat > "$CCH_CFG/.claude.json" <<EOF
{
  "theme": "dark",
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "projects": {
    "$PARENT": {
      "hasTrustDialogAccepted": true,
      "hasCompletedProjectOnboarding": true,
      "allowedTools": []
    }
  }
}
EOF
}

# Boot the real binary in $1 with the production spawn flags.
boot_in() {
    local name="$1" workdir="$2" launch idx
    printf -v launch 'env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q \
ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 \
TERM=%q %q --dangerously-skip-permissions' \
        "$CCH_CFG" "$PATH" "$CCH_CFG" \
        "http://127.0.0.1:$CCH_MOCK_PORT" "${TERM:-xterm-256color}" "$CLAUDE_BIN"
    cch_tmux new-window -d -t "$CCH_SESSION": -n "$name" -c "$workdir" "$launch"
    idx=$(cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' \
        | awk -v n="$name" '$1==n {print $2; exit}')
    [[ -n "$idx" ]] && cch_tmux set-option -t "$CCH_SESSION:$idx" -w remain-on-exit on 2>/dev/null
    printf '%s' "$idx"
}

# Poll until the pane settles (idle or blocked), up to ~30s.
settle() {
    local win="$1" i st=""
    for i in $(seq 1 15); do
        sleep 2
        st=$(cch_state "$win")
        [[ "$st" == "idle" || "$st" == "blocked" ]] && break
    done
    printf '%s' "$st"
}

# ---------------------------------------------------------------------
# Phase 1 — untrusted nested repo, NO pre-seed.
# ---------------------------------------------------------------------
echo
echo "--- phase 1: nested repo, trust NOT pre-seeded ---"
seed_parent_only
WIN1=$(boot_in nested "$CHILD")
[[ -n "$WIN1" ]] || { bad "phase 1: window did not open"; echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1; }
ST1=$(settle "$WIN1")
CAP1=$(cch_capture "$WIN1")
printf '    pane state=%s\n' "$ST1"

DIALOG=0
grep -qF 'Yes, I trust this folder' <<<"$CAP1" && DIALOG=1

if (( DIALOG )); then
    echo "    (this release requires per-repo trust — asserting the compat surfaces)"
    # A. classification: blocked, never empty.
    if [[ "$ST1" == "blocked" ]]; then
        ok "trust dialog classifies blocked (not the retire-safe 'empty')"
    else
        bad "trust dialog classified '$ST1' — expected blocked"
    fi
    # B. unstick recognises it as case `trust` and clears it.
    #
    # _handle_unstick_window takes the WINDOW only and captures the pane
    # itself via `tmux` — so it must run with the harness's tmux shim
    # ($CCH_DIR/.bin/tmux, which injects -L $CCH_SOCKET) at the front of
    # PATH, exactly as cch_pane_state does. Without it the real tmux
    # server is queried, the capture is empty, and every case falls
    # through silently.
    UNSTICK_DIR="$CCH_DIR/unstick"; mkdir -p "$UNSTICK_DIR"
    verdict=$(
        set +u
        export PATH="$CCH_DIR/.bin:$PATH"
        export UNSTICK_DIR TARGET=orchestrator WATCHER_WINDOW=__none__
        # shellcheck source=/dev/null
        source "$REPO_ROOT/monitor/watcher/_unstick.sh" >/dev/null 2>&1
        _handle_unstick_window "$CCH_SESSION:$WIN1" 2>/dev/null
    )
    if [[ "$verdict" == "trust" ]]; then
        ok "_unstick classifies the frame as case 'trust'"
    else
        bad "_unstick classified '$verdict' — expected 'trust'"
    fi
    ST1B=$(settle "$WIN1")
    if [[ "$ST1B" == "idle" ]]; then
        ok "case T's Enter cleared the dialog to a usable REPL"
    else
        bad "after case T the pane is '$ST1B' — expected idle"
    fi
else
    echo "    (this release still inherits trust from the parent repo)"
    if [[ "$ST1" == "idle" ]]; then
        ok "nested repo boots to idle (trust inherited — pre-2.1.232 behaviour)"
    else
        bad "nested repo with inherited trust classified '$ST1' — expected idle"
    fi
    ok "no trust dialog to unstick on this release (case T vacuous)"
    ok "no trust dialog to clear on this release (case T vacuous)"
fi

# ---------------------------------------------------------------------
# Phase 2 — the prevention layer: spawn-worker's pre-seed.
# ---------------------------------------------------------------------
echo
echo "--- phase 2: nested repo, trust pre-seeded by spawn-worker ---"
seed_parent_only

# Call the REAL function from spawn-worker.sh rather than reimplementing
# it, so this asserts the shipped prevention logic. spawn-worker.sh is a
# script, not a library: extract just the helper pair by name.
TRUSTSEED="$CCH_DIR/trustseed.sh"
awk '/^_cc_home\(\) \{/,/^\}/' "$REPO_ROOT/monitor/spawn-worker.sh"  > "$TRUSTSEED"
awk '/^_pre_accept_workspace_trust\(\) \{/,/^\}/' "$REPO_ROOT/monitor/spawn-worker.sh" >> "$TRUSTSEED"
if [[ -s "$TRUSTSEED" ]] && grep -q '_pre_accept_workspace_trust' "$TRUSTSEED"; then
    ok "extracted _pre_accept_workspace_trust from spawn-worker.sh"
else
    bad "could not extract _pre_accept_workspace_trust from spawn-worker.sh"
fi

(
    # shellcheck source=/dev/null
    NEXUS_CC_HOME="$CCH_CFG" source "$TRUSTSEED"
    NEXUS_CC_HOME="$CCH_CFG" _pre_accept_workspace_trust "$CHILD"
)

if command -v jq >/dev/null 2>&1 \
   && [[ "$(jq -r --arg wd "$CHILD" '.projects[$wd].hasTrustDialogAccepted' "$CCH_CFG/.claude.json" 2>/dev/null)" == "true" ]]; then
    ok "pre-seed marked the nested repo trusted in .claude.json"
else
    bad "pre-seed did not mark the nested repo trusted"
fi

WIN2=$(boot_in nested2 "$CHILD")
ST2=$(settle "$WIN2")
CAP2=$(cch_capture "$WIN2")
printf '    pane state=%s\n' "$ST2"
if grep -qF 'Yes, I trust this folder' <<<"$CAP2"; then
    bad "pre-seeded nested repo STILL parked on the trust dialog"
else
    ok "pre-seeded nested repo booted with no trust dialog"
fi
if [[ "$ST2" == "idle" ]]; then
    ok "pre-seeded nested repo classifies idle (usable REPL)"
else
    bad "pre-seeded nested repo classified '$ST2' — expected idle"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
