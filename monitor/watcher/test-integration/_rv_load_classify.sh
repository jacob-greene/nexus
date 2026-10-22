# _rv_load_classify.sh — the `load` arm's verdict over its trace, as a UNIT
# (your-org/nexus-code#1795). Sourced by test-realmodel-respawn-verify.sh and
# driven on synthetic traces by monitor/watcher/test-rv-load-classify.sh, so
# the classification is testable without a real binary.
#
# WHY A THIRD OUTCOME. The `load` arm asserts that the verify stage WAITED on an
# INDETERMINATE reading (`waiting for the box to read as the brief`), and its own
# precondition is that the resume's load outlasts the paste, its Enter AND the
# one INDETERMINATE retry Enter, so that an INDETERMINATE reading reaches the
# STRICT check. Under host load that precondition fails on any build: the box
# has rendered by the time the strict check first looks, so there is nothing to
# wait on and the waiting line can never appear. #1795's red runs (2.1.295 and
# 2.1.296, 2026-10-10) are exactly that shape:
#
#     post-paste verify: … state='empty' is INDETERMINATE (not 'the box is clear') — pressing ONE Enter, …; retrying Enter once
#     post-paste verify: state=user-typing input=typed — the brief is IN the input box, unsubmitted; re-sending Enter (typed-retry 1, budget 120s)
#     post-paste verify (after 1 typed-retry): state=busy — turn submitted
#
# A FAIL there blames the build for the host. So the arm is UNMEASURED in that
# shape (the scenario exits 69), and stays a FAIL in every other shape. A
# lighter load fails the precondition earlier still, and that is UNMEASURED
# too — measured here on 2.1.296 with RV_LOAD_MB=200 (2026-10-12): the first
# check found the brief already rendered, its Enter submitted, and no
# INDETERMINATE reading reached any check:
#
#     post-paste verify: no submit-evidence after 1s (last state='empty'); the brief is IN the input box (pd_box_is_ours), unsubmitted; box: '…'; retrying Enter once
#     post-paste verify (after retry): state=busy — turn submitted
#
# rv_load_classify <trace>   prints ONE line on stdout:
#   waited                  the strict check waited (the measured, passing shape)
#   unmeasured <why>        the precondition was not met: no INDETERMINATE reading
#                           ever reached the strict check
#   fail <why>              anything else, INCLUDING every shape it does not
#                           recognise (default-deny: an unmodelled shape is a
#                           FAIL, never unmeasured)
#
# The trace is the arm's `trace-load`: `LOG <subject log line>` and
# `PS <pane-state reading>` lines in the order they happened.
#
# WHY THE "NOT WAITED" SIDE IS SAFE TO SPLIT. With the subject as written
# (`_respawn.sh`: `_respawn_box_is_brief … strict` returns 2 on an INDETERMINATE
# reading, and the typed-retry loop logs the waiting line on the FIRST rc 2), an
# INDETERMINATE reading at the strict check ALWAYS produces the waiting line. So
# with no waiting line, the only question is whether the strict check SAW one:
#   * a later LOG line that names INDETERMINATE (the pre-#1674 subject logged
#     `typed-retry stopped — state='empty' is INDETERMINATE …` and gave up)
#     means it did, and did not wait            -> fail
#   * the first check's Enter was on an INDETERMINATE reading, or on the brief
#     positively rendered (`state=user-typing … input=typed` before it), and:
#   * the first verdict after that Enter is the turn submitting                -> unmeasured
#   * it is `typed-retry 1` AND the reading that earned that Enter is
#     `state=user-typing … input=typed` (the box had rendered)                -> unmeasured
#   * `typed-retry 1` earned by any OTHER reading — an Enter pressed on an
#     INDETERMINATE box, which the typed-retry LOG line hides because its text
#     is fixed                                                                -> fail
# Error direction: a subject that waits WITHOUT logging the line, or logs
# INDETERMINATE wording on a line that is not a check's verdict, is classified
# fail (loud). A subject defect that leaves no trace in either the log or the
# reading before `typed-retry 1` would be classified unmeasured — that is the
# residue this unit cannot see.
rv_load_classify() {
    local trace="$1"
    [[ -r "$trace" ]] || { printf 'fail trace %s is unreadable\n' "$trace"; return 0; }
    awk '
        # The reading that earned an Enter is the box check the subject made
        # just before logging it. Two guards, one line each, so dropping
        # EITHER is a mutant the unit suite can see (it plants a reading
        # that fails only one of them).
        function rendered(ps,   ok) {
            ok = 1
            if (ps !~ /(^|[ \t])state=user-typing([ \t]|$)/) ok = 0
            if (ps !~ /(^|[ \t])input=typed([ \t]|$)/) ok = 0
            return ok
        }
        function shown(ps) { return (ps == "" ? "<no reading>" : ps) }
        /^PS /  { lastps = substr($0, 4); next }
        /^LOG / { n++; L[n] = substr($0, 5); P[n] = lastps; next }
        END {
            for (i = 1; i <= n; i++)
                if (index(L[i], "waiting for the box to read as the brief")) { print "waited"; exit }
            # The FIRST check'"'"'s Enter: on an INDETERMINATE reading (e), or
            # on the brief positively in the box (p).
            e = 0; p = 0
            for (i = 1; i <= n; i++) {
                if (index(L[i], "is INDETERMINATE (not '"'"'the box is clear'"'"')") && index(L[i], "pressing ONE Enter")) { e = i; break }
                if (index(L[i], "the brief is IN the input box (pd_box_is_ours), unsubmitted") && index(L[i], "retrying Enter once")) { p = i; break }
            }
            if (!e && !p) { print "fail no waiting line, and no first-check Enter the split models (unrecognised shape)"; exit }
            k = (e ? e : p)
            if (p && !rendered(P[p])) { print "fail first-check Enter earned by a reading that is not user-typing/typed: " shown(P[p]); exit }
            for (j = k + 1; j <= n; j++)
                if (index(L[j], "INDETERMINATE")) { print "fail a check after the first Enter read INDETERMINATE and did not wait: " L[j]; exit }
            if (k == n) { print "fail no verdict logged after the first-check Enter"; exit }
            why = (e ? "the INDETERMINATE Enter" : "the first check'"'"'s Enter (on the rendered brief; no INDETERMINATE reading reached any check)")
            v = L[k + 1]
            if (index(v, "(after retry): state=busy") && index(v, "turn submitted")) {
                print "unmeasured " why " submitted the brief; the strict check never ran"; exit
            }
            if (index(v, "the brief is IN the input box, unsubmitted; re-sending Enter (typed-retry 1,")) {
                if (rendered(P[k + 1])) { print "unmeasured the box had rendered before the strict check first looked (its first reading: " P[k + 1] ")"; exit }
                print "fail typed-retry Enter earned by a reading that is not user-typing/typed: " shown(P[k + 1]); exit
            }
            print "fail unrecognised verdict after the first-check Enter: " v
        }' "$trace"
}
