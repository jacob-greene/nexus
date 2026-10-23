# shellcheck shell=bash
# _renderer_scrape_check.sh — the DISCRIMINATING sub-check of
# test-realmodel-overlimit.sh, as a function with three outcomes instead of two.
# (your-org/nexus-code#1530)
#
# SOURCED, never executed. The caller supplies `cch_capture <idx>` and
# `cch_pane_state <idx> [args…]` (from monitor/cc-harness/_lib.sh in the real
# scenario, from stubs in test-realmodel-overlimit-unmeasured.sh).
#
# WHAT THIS CHECKS. Production reads an over-limit pane WITHOUT a stamp — the
# renderer scrape, `_detect_over_limit` — so the scenario asks the production
# classifier about the REAL painted notice with the stamp path pointed at a
# file that does not exist. That is the surface the 2026-07-14 incident lost,
# and it is the one sub-check in the scenario that a renderer repaint breaks.
#
# THE DEFECT. The sub-check ran only when the captured pane contained the
# notice. On a blank frame the `else` arm printed a `note:` and moved on, so the
# scenario finished GREEN with its discriminating sub-check never run: a branch
# that converts "could not measure" into "measured and fine". The `if` arm had
# both a PASS and a FAIL; the `else` had neither, and nothing downstream could
# tell a run that exercised the scrape from one that skipped it. Never taken in
# 88 recorded runs — latent, which is exactly why no green was ever doubted.
#
# THE FIX HAS TWO PARTS, and the order matters:
#   1. RETRY, BOUNDED. The frame paints asynchronously; one capture taken the
#      instant phase B ends is a race the scenario usually wins. Poll for the
#      notice for a bounded time before concluding anything.
#   2. IF IT NEVER PAINTS, SAY `unmeasured` — a third outcome that is neither a
#      pass nor a failure of the code under test. The scenario then exits 69
#      (ENVSKIP: "I ran, I asserted, and then measured this MACHINE unable to
#      supply what I needed", your-org/nexus-code#1283) unless something else
#      already FAILED. THE TWO READERS OF 69 DISAGREE, and the claim must be
#      scoped to the reader (skeptic F3 on #1558): `cc-harness/gate.sh`, the
#      pin-promotion gate, counts 69 toward RED and names it UNMEASURED;
#      `run-tests.sh` tallies 69 as ENVSKIP — reported, NOT a pass, and NOT
#      red either (#1283), so the cc-harness CI job, which runs these
#      scenarios through run-tests.sh, still ends its band green with the
#      scrape unmeasured. Making that job fail on an ENV-DECLINED realmodel
#      scenario is your-org/nexus-code#1563; before this file the same job ended green
#      with a `note:` and no ENVSKIP row at all.
#
# WE CHOSE the bound: RSC_ATTEMPTS=20 polls, RSC_INTERVAL=0.5 s, i.e. 10 s.
# It is a CHOICE, not an upstream convention and not derived from a measured
# paint latency — none has been recorded. The reasoning: the blank branch was
# never taken in 88 recorded runs, so the wait is almost never paid; and 10 s is
# small beside the scenario's own `drive_until` waits (60 x 0.5 s each). Both
# are overridable, for the unit suite, which must not sleep.
#
# Sets:  RSC_VERDICT   pass | fail | unmeasured
#        RSC_ATTEMPTS_USED   how many captures were taken
#        RSC_PANE_TEXT       the last capture (the caller prints diagnostics from it)
#        RSC_STATE           what the classifier said, when it was asked

RSC_VERDICT=""; RSC_ATTEMPTS_USED=0; RSC_PANE_TEXT=""; RSC_STATE=""

rsc_check() {   # <window-idx> <pane-state-dir> <missing-stamp-path>
    local idx="$1" state_dir="$2" no_stamp="$3"
    local attempts="${RSC_ATTEMPTS:-20}" interval="${RSC_INTERVAL:-0.5}" i out
    RSC_VERDICT=""; RSC_ATTEMPTS_USED=0; RSC_PANE_TEXT=""; RSC_STATE=""
    [[ "$attempts" =~ ^[0-9]+$ ]] && (( attempts >= 1 )) || attempts=20
    for (( i = 1; i <= attempts; i++ )); do
        RSC_PANE_TEXT=$(cch_capture "$idx")
        RSC_ATTEMPTS_USED=$i
        if grep -q "hit your" <<<"$RSC_PANE_TEXT"; then
            out=$(CCH_PANE_STATE_DIR="$state_dir" cch_pane_state "$idx" --over-limit-file "$no_stamp" 2>&1)
            RSC_STATE=$(sed -n 's/.*state=\([^ ]*\).*/\1/p' <<<"$out")
            if [[ "$RSC_STATE" == "over-limit" ]]; then RSC_VERDICT=pass; else RSC_VERDICT=fail; fi
            return 0
        fi
        (( i < attempts )) && sleep "$interval"
    done
    RSC_VERDICT=unmeasured
    return 0
}

# rsc_exit_code <fail-count> <unmeasured 0|1> -> the scenario's exit code.
# A FAIL outranks an UNMEASURED: a red the scenario DID measure must not be
# softened into "could not tell". THE ORDER OF THE TWO TESTS IS THE RULE — a run
# can be both, and whichever is asked first wins.
rsc_exit_code() {
    local fails="$1" unmeasured="$2"
    if (( fails > 0 )); then printf '1'
    elif (( unmeasured > 0 )); then printf '69'
    else printf '0'; fi
}
