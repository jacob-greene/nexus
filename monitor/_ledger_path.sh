#!/usr/bin/env bash
# _ledger_path.sh — where the delivery ledger (`machine-input.tsv`) lives: the
# ONE resolver every reader and writer calls (your-org/nexus-code#1724,
# piece A). Sourced; defines one function.
#
# WHY. The ledger was `$STATE_DIR/machine-input.tsv`, composed independently
# by every writer (send.sh, paste-followup.sh, skeptic-channel.sh, the
# watcher's _machine_input_stamp) and every reader (the idle probe's delivery
# guard and attribution rule, retire-preflight, bootstrap-recover, the
# retirement bookkeeping). During a read-only incident every stamp fails, so
# `ng send` cannot deliver at all. `ng degraded enter` relocates the ledger
# into the degraded run dir, and that only works if writers AND readers move
# together: a writer stamping the relocated file while the guard still reads
# the tree's copy reads every delivery as lost, and the reverse reads every
# submit as the operator's. So nothing composes the path but this function,
# and test-degraded-enter-exit.sh's population lint holds every tracked
# monitor/ shell file to that.
#
#   nexus_ledger_path <state_dir>
#       -> the ledger path. With no relocation pointer it is EXACTLY
#          "<state_dir>/machine-input.tsv", the state dir spelled as given
#          (byte-identical to the old composition).
#          rc 2, nothing printed: a pointer exists but is unusable
#          (stderr says why). Writers must refuse rather than stamp the tree.
#
# Resolved PER CALL through monitor/_degraded-pointer.sh, so a long-running
# watcher sees `enter`/`exit` on its next resolution without a restart.

[[ -n "${_NEXUS_LEDGER_PATH_LIB:-}" ]] && return 0
_NEXUS_LEDGER_PATH_LIB=1

if ! declare -F nexus_degraded_relocated >/dev/null 2>&1; then
    # shellcheck source=monitor/_degraded-pointer.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_degraded-pointer.sh"
fi

#   nexus_ledger_tree_path <state_dir>
#       -> "<state_dir>/machine-input.tsv" whatever the pointer says: the
#          ledger's HOME in the tree. For `ng degraded enter|exit` (what to
#          copy out, where to merge back) and for a reader's documented
#          fallback; never for a writer.
nexus_ledger_tree_path() { printf '%s/machine-input.tsv\n' "${1:?state_dir required}"; }

nexus_ledger_path() {
    local sd="${1:?state_dir required}" r rc
    r=$(nexus_degraded_relocated "$sd" ledger); rc=$?
    case "$rc" in
        0) printf '%s\n' "$r" ;;
        1) nexus_ledger_tree_path "$sd" ;;
        *) return 2 ;;
    esac
}
