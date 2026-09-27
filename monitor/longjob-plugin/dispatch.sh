#!/usr/bin/env bash
# monitor/longjob-plugin/dispatch.sh — the ONE command Claude Code arms at
# session start from this plugin's manifest. It never returns on purpose: a
# plugin-monitor command that exits is NOT relaunched for the rest of the
# session (measured, your-org/your-nexus#375 §S1), and its exit is delivered
# to the model as a "script failed" notice that costs a turn (measured
# 2026-09-15: ~16–21 s and ~$0.11 per session for a probe that exited at
# once). So even "nothing to do" is a loop, and a crash inside the dispatcher
# is caught by the supervisor loop in longjob-watch.sh rather than reaching
# the host.
#
# The dispatcher itself lives one directory up so it can be TESTED without a
# plugin — against a HERMETIC state dir (a private NEXUS_STATE_DIR), as
# monitor/watcher/test-longjob-watch.sh does.
#
# NEVER RUN `dispatch` BY HAND INSIDE A LIVE SESSION (bundle-2609sk3 F1,
# your-org/nexus-code#1541, #1544). The session ledger has ONE writer. That
# used to be an assumption nothing enforced: a second `longjob-watch.sh
# dispatch` started from a tool shell rewrote `sid-<session>/dispatcher.json`
# to name ITSELF, and pane-state.sh then excluded THAT process's root from the
# background-shell census — together with whatever real work shared the root.
# Measured: `idle` (kill-authorised) over a `sleep 600` started in the same
# Bash call.
#
# Both halves are now closed (#1544): `dispatch` REFUSES TO ARM while the
# ledger names a different live dispatcher with fresh polls (it stays alive,
# polls nothing, writes nothing, and arms only if that owner stops), and
# pane-state.sh excludes a root only when nothing but the dispatcher's own
# chain lives in it. The instruction stands regardless: a hand-run dispatcher
# that DOES arm — because the host's is dead — reports `armed` while its wake
# lines go to a tool shell that nobody reads. If a session is NOT ARMED, the
# fallback is `longjob-watch.sh await`, which writes no ledger.
exec bash "$(cd "$(dirname "$0")/.." && pwd)/longjob-watch.sh" dispatch
