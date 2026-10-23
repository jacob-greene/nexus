#!/usr/bin/env bash
# Regression test for the labsh "phantom-adopt" outage (jupyterlab service
# went DOWN 2026-07-01 ~18:59 and did NOT auto-recover through three watcher
# restarts). Exercises monitor/labsh-supervised.sh's phantom-adopt self-heal.
#
# The outage mechanism: labsh's start-guard scans
#   $JUPYTER_DATA_DIR/runtime/jpserver-*.json
# and, finding a STALE record for a since-dead server, declared "server is
# already running (pid …)" and returned rc=1. The supervisor adopted the
# phantom and logged "serving" — but nothing was listening, so the healthcheck
# failed forever and every restart re-adopted the same phantom. (labsh's guard
# only `kill -0`s the recorded pid, which cannot tell a live JupyterLab from a
# dead server's record whose pid was recycled to another process or is a
# zombie — exactly the incident's pid 6105.)
#
# The fix under test, in labsh-supervised.sh:
#   1. prune_dead_runtime_records — before every start, drop records whose pid
#      is VERIFIABLY DEAD (kill -0). Conservative: a live pid is never touched.
#   2. phantom-adopt detection — if `labsh start` returns rc=1 (adopted a
#      record) but no healthy server appears within START_GRACE, prune the
#      NON-SERVING record(s) (a record that answers /api/status is a real live
#      server and is kept) and retry the start ONCE (guarded, cannot spin).
#
# Hermetic: labsh is a PATH-shadow stub whose `start` refuses (rc=1, "already
# running") whenever a jpserver-*.json record is present — faithfully modelling
# incident-time labsh — and otherwise launches a real token-checking HTTP
# server (python3) and writes a fresh jpserver record. No uv, venv, or
# JupyterLab. Every server/supervisor is killed by recorded pid on exit.
#
# Run: bash monitor/watcher/test-labsh-phantom-adopt.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Falsifiability (verified by the author, documented in the PR): checking out
# monitor/labsh-supervised.sh at pre-fix dev and re-running REDs both the
# dead-pid and pid-reuse subtests (no healthy server ever comes up), and the
# fix GREENs them.
#
# Flake hardening (your-org/nexus-code#478): this test lost a CI run by
# asserting states it never established — elapsed wall-clock taken as proof
# an event had occurred. Every assertion now either polls the condition
# itself to a generous deadline (wait_for / wait_for_log; LABSH_TEST_DEADLINE
# overrides) or is causally ordered after one that did. The fixture pids are
# unforgeable under PID-space wrap: the "alive non-server" pid is this test
# shell's own $$ (a sibling test's stale-pid cleanup can never reap it
# mid-test, unlike the previous `sleep 300`), and the "verifiably dead" pid
# is /proc/sys/kernel/pid_max (a value the kernel never allocates), not a
# spawned-then-reaped pid that a wrap can resurrect. Seed ports are probed
# free at runtime, never hardcoded. LABSH_TEST_START_GRACE widens the
# supervisor's grace window to reproduce the slow-runner path deterministically.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

MON_DIR=$(cd "$_test_dir/.." && pwd)
HEALTH="$MON_DIR/jupyter-health.sh"
SUP="$MON_DIR/labsh-supervised.sh"

WORK=$(mktemp -d -t nexus-phantom-XXXXXX)

# Track every pid we spawn (supervisors, stub servers, sleepers) so cleanup
# never has to pattern-match (self-kill hazard). Identity-verified kills only.
SPAWNED_PIDS=()
SPAWNED_GROUPS=()   # self-grouped plants (T5's `timeout`): killed as a GROUP, so no child is orphaned
cleanup() {
    local pid pf
    for pid in "${SPAWNED_GROUPS[@]:-}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL -- "-$pid" 2>/dev/null || true
    done
    for pid in "${SPAWNED_PIDS[@]:-}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done
    # Stub servers record their own pid under each project's .jupyter/stub.pid.
    for pf in "$WORK"/t*/.jupyter/stub.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Fast health timeout so record_is_serving probes against a dead port fail
# quickly (default 3s each would make the phantom subtest crawl).
export LABSH_HEALTH_TIMEOUT=1

# --- stubs ------------------------------------------------------------------
STUBS="$WORK/stub-bin"
mkdir -p "$STUBS"

# Token-checking HTTP server: 200 on /api/status with the token given at start,
# 403 otherwise. Mirrors real jupyter holding JUPYTER_TOKEN from launch.
cat > "$STUBS/stub-server.py" <<'PY'
import http.server, sys
PORT, TOKEN = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == '/api/status' and \
             self.headers.get('Authorization') == 'token ' + TOKEN
        self.send_response(200 if ok else 403)
        self.end_headers()
        self.wfile.write(b'{}' if ok else b'forbidden')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY

# Per-test-process port band (your-org/nexus-code#558) — this file uses the
# 40000-band, DISJOINT from test-jupyter-service.sh's 20000-band, so the two
# jupyter-family stubs can never contend for the same port window when the
# runner schedules them concurrently. See the fuller note in that file.
# fixture-port-lint: allow-scan-base  as in test-jupyter-service.sh, the stub
# bind-probes [base, base+40); this is a scan START (your-org/nexus-code#800).
# NOTE: this band (40000-47999) sits INSIDE the kernel ephemeral range
# (32768-60999), unlike the 20000-band. The scan tolerates that — it retries
# on EADDRINUSE — but it is why the scan, not the arithmetic, is load bearing.
LABSH_STUB_BASE_PORT=$(( 40000 + ($$ % 8000) ))

# Stub labsh. Contract for the surface the supervisor touches, PLUS the
# jpserver-*.json runtime-record scan that drove the incident.
cat > "$STUBS/labsh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
J="\${JUPYTER_CONFIG_DIR:-\$PWD/.jupyter}"
RT="\$PWD/.jupyter/share/jupyter/runtime"     # == labsh's default JUPYTER_DATA_DIR/runtime
SERVER_PY="$STUBS/stub-server.py"
alive() { [[ -f "\$J/stub.pid" ]] && kill -0 "\$(cat "\$J/stub.pid" 2>/dev/null)" 2>/dev/null; }
first_record() { local f; for f in "\$RT"/jpserver-*.json; do [[ -e "\$f" ]] && { printf '%s' "\$f"; return 0; }; done; return 1; }
case "\${1:-}" in
  start)
    shift
    # Incident-time start-guard: refuse if ANY jpserver record is present. The
    # real labsh only kill-0s the recorded pid, but a recycled/zombie pid makes
    # that guard fire on a stale record all the same — which is exactly what
    # the supervisor must survive. So the stub refuses on record-present.
    if rec=\$(first_record); then
        pid=\$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('pid',''))" "\$rec" 2>/dev/null)
        url=\$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('url',''))" "\$rec" 2>/dev/null)
        echo "labsh: server is already running (pid \${pid:-?}, \${url:-?})" >&2
        exit 1
    fi
    port=${LABSH_STUB_BASE_PORT}
    while (( \$# > 0 )); do case "\$1" in --port) port="\$2"; shift 2 ;; *) shift ;; esac; done
    mkdir -p "\$J" "\$RT"
    [[ -f "\$J/token" ]] || printf 'stubtok-%s' "\$RANDOM" > "\$J/token"
    tok=\$(cat "\$J/token")
    # labsh auto-increment: first free port in [port, port+39] (widened for #558).
    port=\$(python3 - "\$port" <<'EOF'
import socket, sys
p = int(sys.argv[1])
for q in range(p, p + 40):
    s = socket.socket()
    try: s.bind(('127.0.0.1', q)); s.close(); print(q); break
    except OSError: s.close()
EOF
)
    [[ -n "\$port" ]] || { echo "labsh-stub: no free port" >&2; exit 1; }
    python3 "\$SERVER_PY" "\$port" "\$tok" >/dev/null 2>&1 &
    spid=\$!
    echo "\$spid" > "\$J/stub.pid"; echo "\$port" > "\$J/stub.port"
    echo \$(( \$(cat "\$J/stub-start-count" 2>/dev/null || echo 0) + 1 )) > "\$J/stub-start-count"
    printf '{"pid": %s, "url": "http://127.0.0.1:%s/", "port": %s, "token": "%s", "secure": false}\n' \
        "\$spid" "\$port" "\$port" "\$tok" > "\$RT/jpserver-\$spid.json"
    for i in \$(seq 1 20); do curl -fs -o /dev/null "http://127.0.0.1:\$port/x" 2>/dev/null && break; sleep 0.1; done
    echo "labsh-stub: running at http://127.0.0.1:\$port/" >&2
    ;;
  url)
    if alive; then
        echo "http://127.0.0.1:\$(cat "\$J/stub.port")/lab?token=\$(cat "\$J/token")"; exit 0
    fi
    # Phantom: no live stub, but a record resolves a (stale) URL — mirrors labsh
    # reading jpserver-*.json, which is how a phantom exposes a URL at all.
    if rec=\$(first_record); then
        python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('url','')+'lab?token='+d.get('token',''))" "\$rec" 2>/dev/null
        exit 0
    fi
    echo "labsh-stub: no running server" >&2; exit 1
    ;;
  stop)
    # Faithful to real labsh: stop signals the LIVE server it started and that
    # server removes its OWN record on shutdown. A phantom record (a dead
    # server's, not ours) is left untouched — which is exactly why the
    # incident's bounce loop (stop+start) never cleared the stale record.
    if [[ -f "\$J/stub.pid" ]]; then
        spid=\$(cat "\$J/stub.pid")
        kill "\$spid" 2>/dev/null
        rm -f "\$RT/jpserver-\$spid.json" "\$J/stub.pid"
    fi
    ;;
  status) alive && echo "server up" || echo "no server" ;;
  token)  cat "\$J/token" 2>/dev/null ;;
  kernel) shift; mkdir -p "\$J"; echo "\$*" >> "\$J/stub-kernel-calls" ;;
  *) echo "labsh-stub: unhandled verb: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$STUBS/labsh"
export PATH="$STUBS:$PATH"

# --- helpers ----------------------------------------------------------------
# Generous shared deadline for every poll. Costs wall-clock only on real
# failure; a load-delayed supervisor is waited out, not sampled early (#478).
# Scaled with the grace seam: the supervisor's START_GRACE poll loop runs
# 2×grace iterations, each paying python3 startups in the stub (~1.5 s
# loaded), so the phantom branch fires at roughly 3×grace — a fixed
# deadline that ignores the seam would undershoot exactly when the seam is
# used to simulate a slow runner. (LABSH_SVC_START_GRACE is exported a few
# lines below; default 4 → deadline 62 s.)
DL="${LABSH_TEST_DEADLINE:-$(( ${LABSH_TEST_START_GRACE:-4} * 8 + 30 ))}"

wait_for() {  # wait_for <label> <deadline-s> -- cmd...
    # Deadline is in UNLOADED seconds; th_deadline scales it for the
    # parallelism this run competes with (your-org/nexus-code#558).
    local label="$1" deadline; deadline=$(th_deadline "$2"); shift 3
    local t=0
    while (( t < deadline * 4 )); do
        "$@" >/dev/null 2>&1 && { printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); return 0; }
        sleep 0.25; t=$(( t + 1 ))
    done
    printf '  FAIL: %s (deadline %ss)\n' "$label" "$deadline" >&2; FAIL=$(( FAIL + 1 )); return 1
}

wait_for_log() {  # wait_for_log <label> <deadline-s> <file> <needle>
    local label="$1" deadline="$2" file="$3" needle="$4"
    local t=0
    while (( t < deadline * 4 )); do
        grep -qF -- "$needle" "$file" 2>/dev/null \
            && { printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); return 0; }
        sleep 0.25; t=$(( t + 1 ))
    done
    printf '  FAIL: %s — %q absent from %s after %ss\n' "$label" "$needle" "$file" "$deadline" >&2
    FAIL=$(( FAIL + 1 )); return 1
}

free_port() {  # print a currently-free localhost port (probed, not hardcoded)
    python3 - <<'EOF'
import socket
s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()
EOF
}

seed_record() {  # seed_record <project> <pid> <port> [<token>]
    local p="$1" pid="$2" port="$3" tok="${4:-seedtok}"
    local rt="$p/.jupyter/share/jupyter/runtime"
    mkdir -p "$rt"
    printf '{"pid": %s, "url": "http://127.0.0.1:%s/", "port": %s, "token": "%s", "secure": false}\n' \
        "$pid" "$port" "$port" "$tok" > "$rt/jpserver-$pid.json"
    printf '%s' "$tok" > "$p/.jupyter/token"          # so a phantom's health probe uses a real token
}

# A pid that is guaranteed dead AND unforgeable: /proc/sys/kernel/pid_max
# itself is never allocated by the kernel, so unlike a spawned-then-reaped
# pid it can never be resurrected by a PID-space wrap under parallel suite
# load (#478 — the wrap turned "dead" seeds live and flipped T1's premise).
impossible_pid() {
    local m
    m=$(cat /proc/sys/kernel/pid_max 2>/dev/null)
    [[ "$m" =~ ^[0-9]+$ ]] || m=4194304
    printf '%s' "$m"
}

# Fast start grace so the phantom-adopt window closes in a few seconds.
# LABSH_TEST_START_GRACE is a test seam: widening it reproduces the
# loaded-runner slow path deterministically (the #478 falsifiability runs).
export LABSH_SVC_INTERVAL=1 LABSH_SVC_FAILS=2 \
       LABSH_SVC_START_GRACE="${LABSH_TEST_START_GRACE:-4}"

# ============================================================================
echo '=== T1: stale DEAD-pid record is pruned before start → real healthy server ==='
# The steady-state case: a crashed server left a record whose pid is now dead.
# prune_dead_runtime_records (kill -0) removes it before start; labsh then
# launches a fresh server. Pre-fix (no prune) the stub refuses on the record
# and the phantom is adopted — nothing healthy ever comes up.
T1="$WORK/t1"; mkdir -p "$T1/.jupyter"
DPID=$(impossible_pid)
seed_record "$T1" "$DPID" "$(free_port)"
assert_eq "seeded pid is verifiably dead" "$(kill -0 "$DPID" 2>/dev/null; echo $?)" "1"
"$SUP" "$T1" >"$T1/sup.log" 2>&1 &
T1SUP=$!; SPAWNED_PIDS+=("$T1SUP")
# Poll the log line FIRST: the prune strictly precedes the start that makes
# health pass, so a one-shot sample after health is only safe when health
# arrived via that path — poll each condition on its own instead (#478).
wait_for_log "T1 log records the prune" "$DL" "$T1/sup.log" \
    "pruned stale runtime record for dead pid $DPID"
wait_for "T1 server becomes healthy" "$DL" -- "$HEALTH" "$T1"
assert_no_file "T1 dead-pid record pruned" "$T1/.jupyter/share/jupyter/runtime/jpserver-$DPID.json"
assert_eq "T1 exactly one real start" "$(cat "$T1/.jupyter/stub-start-count" 2>/dev/null)" "1"
kill -KILL "$T1SUP" 2>/dev/null

# ============================================================================
echo '=== T2: pid-reuse phantom (alive non-server pid) → detect, prune, retry, heal ==='
# The actual incident: the recorded pid is ALIVE (recycled to an unrelated
# process / zombie) so kill -0 passes and the conservative pre-start prune
# correctly leaves it. labsh adopts it (rc=1) but nothing serves. The
# phantom-adopt detector must, after START_GRACE of unhealth, prune the
# non-serving record and retry the start once.
T2="$WORK/t2"; mkdir -p "$T2/.jupyter"
# The alive-but-not-a-server pid is THIS TEST SHELL ($$): alive for exactly
# the test's lifetime, never a server, and — unlike the previous
# `sleep 300 &` — impossible for a sibling test's stale-pid cleanup to reap
# after a PID-space wrap (#478: the reaped sleeper let the pre-start
# dead-prune fire, the phantom path never ran, and the log assertions
# sampled `got 0 want 1`). If a supervisor regression ever kills the
# recorded pid, the test dies loudly — still a red, and a truthful one.
ALIVEPID=$$
# Point the record at a probed-free (hence dead) port so record_is_serving
# fails fast; hardcoded ports collide with real services under load.
seed_record "$T2" "$ALIVEPID" "$(free_port)"
assert_eq "T2 seeded pid is alive (kill -0 passes)" "$(kill -0 "$ALIVEPID" 2>/dev/null; echo $?)" "0"
"$SUP" "$T2" >"$T2/sup.log" 2>&1 &
T2SUP=$!; SPAWNED_PIDS+=("$T2SUP")
# Poll each log condition in causal order (phantom-adopt detection → the
# single retry → a healthy server), each to the shared generous deadline —
# never a one-shot sample at a load-dependent instant (#478).
wait_for_log "T2 log shows phantom-adopt heal" "$DL" "$T2/sup.log" "phantom-adopt:"
wait_for_log "T2 log shows the retry" "$DL" "$T2/sup.log" "retrying start once"
wait_for "T2 server becomes healthy after phantom self-heal" "$DL" -- "$HEALTH" "$T2"
assert_no_file "T2 phantom record pruned" "$T2/.jupyter/share/jupyter/runtime/jpserver-$ALIVEPID.json"
assert_eq "T2 alive non-server process was NOT killed (only its record removed)" \
    "$(kill -0 "$ALIVEPID" 2>/dev/null; echo $?)" "0"
# Loop guard: asserted only after the retry line appeared AND the server is
# healthy (the retry cycle completed), so it can no longer flake low; a
# pathological spin before health would still be caught as count > 1.
assert_eq "T2 phantom retry happened AT MOST once (loop guard)" \
    "$(grep -c 'retrying start once' "$T2/sup.log")" "1"
kill -KILL "$T2SUP" 2>/dev/null

# ============================================================================
echo '=== T3: non-degrading — a genuinely healthy already-running server is adopted, record kept ==='
# A real server is serving with a valid env file + record. The supervisor must
# adopt it on the first probe (start_server never runs), so nothing is started
# and the live server's record is NEVER pruned.
T3="$WORK/t3"; mkdir -p "$T3/.jupyter" "$T3/.jupyter/share/jupyter/runtime"
T3TOK="livetok-$RANDOM"
T3PORT=$(python3 - <<'EOF'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
EOF
)
printf '%s' "$T3TOK" > "$T3/.jupyter/token"
printf 'PORT=%s\nSCHEME=http\n' "$T3PORT" > "$T3/.jupyter/labsh-service.env"
python3 "$STUBS/stub-server.py" "$T3PORT" "$T3TOK" >/dev/null 2>&1 &
T3SRV=$!; SPAWNED_PIDS+=("$T3SRV")
printf '{"pid": %s, "url": "http://127.0.0.1:%s/", "port": %s, "token": "%s", "secure": false}\n' \
    "$T3SRV" "$T3PORT" "$T3PORT" "$T3TOK" > "$T3/.jupyter/share/jupyter/runtime/jpserver-$T3SRV.json"
wait_for "T3 pre-existing server is healthy" 10 -- "$HEALTH" "$T3"
"$SUP" "$T3" >"$T3/sup.log" 2>&1 &
T3SUP=$!; SPAWNED_PIDS+=("$T3SUP")
# Absence assertions need a window; polling cannot prove a negative. Anchor
# the window AFTER the supervisor demonstrably started (its first log line),
# so a load-delayed startup can no longer eat the observation time (#478).
wait_for_log "T3 supervisor came up" "$DL" "$T3/sup.log" "supervisor up:"
sleep 3   # observation window: time for the bring-up probe to (not) start anything
assert_no_file "T3 no labsh start was issued (healthy server adopted)" "$T3/.jupyter/stub-start-count"
assert_file_exists "T3 live server's record left untouched" \
    "$T3/.jupyter/share/jupyter/runtime/jpserver-$T3SRV.json"
assert_not_contains "T3 nothing was pruned" "$(cat "$T3/sup.log")" "pruned"
assert_eq "T3 server still healthy alongside supervisor" "$("$HEALTH" "$T3" >/dev/null 2>&1; echo $?)" "0"
kill -KILL "$T3SUP" 2>/dev/null
kill -KILL "$T3SRV" 2>/dev/null

# ============================================================================
echo '=== T4 (F5, #1594): the token-mismatch proof consults only the record on OUR port ==='
# `_token_mismatch_proven` read EVERY jpserver record, so a FOREIGN serving
# record (its own token, not the file's) proved a "mismatch" while our own
# server was merely warming — and the fast bail fired on a warming server.
# Driven on the functions EXTRACTED VERBATIM from the supervisor, so this
# cannot drift from the code it judges; real stub servers answer the probes.
_tmp_src=$(awk '/^(runtime_dir|record_field|record_is_serving|_token_mismatch_proven)\(\) \{/,/^}/' "$SUP")
assert_eq "T4 CONTROL: all four functions were really extracted" \
    "$(grep -cE '^(runtime_dir|record_field|record_is_serving|_token_mismatch_proven)\(\) \{' <<<"$_tmp_src")" "4"
T4="$WORK/t4"; T4RT="$T4/.jupyter/share/jupyter/runtime"; mkdir -p "$T4RT"
T4FPORT=$(free_port); T4OPORT=$(free_port)
python3 "$STUBS/stub-server.py" "$T4FPORT" foreigntok >/dev/null 2>&1 &
SPAWNED_PIDS+=("$!")
# OUR server is WARMING: it holds a token nobody is told, so it answers 403 to
# the one in its record — exactly what a warming jupyter shows.
python3 "$STUBS/stub-server.py" "$T4OPORT" not-yet-ready >/dev/null 2>&1 &
SPAWNED_PIDS+=("$!")
printf '{"pid": 1, "port": %s, "token": "foreigntok", "secure": false}\n' "$T4FPORT" > "$T4RT/jpserver-foreign.json"
printf '{"pid": 2, "port": %s, "token": "filetok", "secure": false}\n' "$T4OPORT" > "$T4RT/jpserver-ours.json"
printf 'PORT=%s\nSCHEME=http\n' "$T4OPORT" > "$T4/.jupyter/labsh-service.env"
t4_run() {  # t4_run <fn-call…> — run in the project, as the supervisor does
    ( cd "$T4" && PROJECT_DIR="$T4" ENV_FILE=".jupyter/labsh-service.env" \
        bash -c "$_tmp_src"'
"$@" && echo 0 || echo 1' _ "$@" ) 2>/dev/null
}
wait_for "T4 PRECONDITION: the foreign server is up" 10 -- \
    curl -fs -o /dev/null -H 'Authorization: token foreigntok' "http://127.0.0.1:$T4FPORT/api/status"
assert_eq "T4 PRECONDITION: the FOREIGN record really is serving (else the row below proves nothing)" \
    "$(t4_run record_is_serving "$T4RT/jpserver-foreign.json")" "0"
assert_eq "T4 PRECONDITION: OUR record is NOT serving (warming, 403)" \
    "$(t4_run record_is_serving "$T4RT/jpserver-ours.json")" "1"
assert_eq "T4 a foreign serving record on ANOTHER port does not prove a mismatch while ours warms" \
    "$(t4_run _token_mismatch_proven filetok)" "1"
# CONTROL: OUR port's record serving with a token that is not the file's — a
# real rotation — must still be proven, or the guard above is merely a mute.
T4RPORT=$(free_port)
python3 "$STUBS/stub-server.py" "$T4RPORT" oldtok >/dev/null 2>&1 &
SPAWNED_PIDS+=("$!")
printf '{"pid": 3, "port": %s, "token": "oldtok", "secure": false}\n' "$T4RPORT" > "$T4RT/jpserver-rotated.json"
printf 'PORT=%s\nSCHEME=http\n' "$T4RPORT" > "$T4/.jupyter/labsh-service.env"
wait_for "T4 CONTROL: our rotated server is up" 10 -- \
    curl -fs -o /dev/null -H 'Authorization: token oldtok' "http://127.0.0.1:$T4RPORT/api/status"
assert_eq "T4 CONTROL: OUR port's record serving a token that is not the file's IS a proven mismatch" \
    "$(t4_run _token_mismatch_proven filetok)" "0"
rm -f "$T4/.jupyter/labsh-service.env"
assert_eq "T4 no env file (our port unknown) = cannot tell, never a proof" \
    "$(t4_run _token_mismatch_proven filetok)" "1"

# ============================================================================
# F6 (#1594): a predecessor's orphaned periodic hook is reaped at startup. The
# plants are ORPHANS on purpose — launched from a subshell that exits, so init
# reaps them and "gone" is never a zombie of ours — which is also exactly the
# shape a KILLed supervisor leaves behind.
proc_live() {  # proc_live <pid> — present and not a zombie
    local st; st=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    st=${st##*) }; [[ "${st%% *}" != Z ]]
}
plant_orphan() {  # plant_orphan <dir> <cmd…> — prints the orphan's pid
    local d="$1"; shift
    ( cd "$d" && { "$@" >/dev/null 2>&1 </dev/null & echo $!; } )
}
echo '=== T5 (F6, #1594): a still-VALID pgid file left by a killed supervisor is reaped before the first round ==='
T5="$WORK/t5"; mkdir -p "$T5/.jupyter"
T5T=$(plant_orphan "$T5" timeout 600 sleep 600)
SPAWNED_GROUPS+=("$T5T")
wait_for "T5 PRECONDITION: the plant is a self-grouped \`timeout\` (the identity the reaper accepts)" 10 -- \
    bash -c '[[ "$(cat /proc/$1/comm)" == timeout && "$(ps -o pgid= -p "$1" | tr -d " ")" == "$1" ]]' _ "$T5T"
T5C=""; for _i in $(seq 1 40); do T5C=$(ps -o pid= --ppid "$T5T" 2>/dev/null | tr -d ' '); [[ -n "$T5C" ]] && break; sleep 0.25; done
printf '%s\n' "$T5T" > "$T5/.jupyter/labsh-periodic.pgid"
"$SUP" "$T5" >"$T5/sup.log" 2>&1 &
T5SUP=$!; SPAWNED_PIDS+=("$T5SUP")
wait_for_log "T5 the startup reap is LOGGED" "$DL" "$T5/sup.log" "an orphaned periodic hook left by a previous supervisor (process group $T5T)"
wait_for "T5 the orphaned \`timeout\` is GONE" "$DL" -- bash -c '! { st=$(cat /proc/$1/stat 2>/dev/null) && st=${st##*) } && [[ ${st%% *} != Z ]]; }' _ "$T5T"
wait_for "T5 …and so is the hook under it (the whole group)" "$DL" -- bash -c '[[ -n "$1" ]] && ! { st=$(cat /proc/$1/stat 2>/dev/null) && st=${st##*) } && [[ ${st%% *} != Z ]]; }' _ "$T5C"
kill -KILL "$T5SUP" 2>/dev/null
kill -KILL -- "-$T5T" 2>/dev/null   # a regression leaves a 600 s group behind

echo '=== T6 (F6 control): a RECYCLED pgid (a live non-`timeout` in the same dir) is left alone ==='
T6="$WORK/t6"; mkdir -p "$T6/.jupyter"
# SELF-GROUPED (`setsid`), in the SAME directory: only the `comm` check can
# refuse it. A plain background `sleep` would also fail the group-leader check,
# and a control two guards defend cannot show that either one works.
T6S=$(plant_orphan "$T6" setsid sleep 600)
SPAWNED_PIDS+=("$T6S")
wait_for "T6 PRECONDITION: the plant is self-grouped, in this dir, and NOT a \`timeout\`" 10 -- \
    bash -c '[[ "$(cat /proc/$1/comm)" == sleep && "$(ps -o pgid= -p "$1" | tr -d " ")" == "$1" && "$(readlink /proc/$1/cwd)" == "$2" ]]' _ "$T6S" "$(cd "$T6" && pwd -P)"
printf '%s\n' "$T6S" > "$T6/.jupyter/labsh-periodic.pgid"
"$SUP" "$T6" >"$T6/sup.log" 2>&1 &
T6SUP=$!; SPAWNED_PIDS+=("$T6SUP")
# Anchor AFTER the reap point: the start line is logged only once startup has
# passed it, so the absence below is observed, not sampled early.
wait_for_log "T6 supervisor passed the startup reap point" "$DL" "$T6/sup.log" "starting labsh server"
assert_eq "T6 the recycled pid's process is still alive" "$(proc_live "$T6S" && echo alive || echo dead)" "alive"
assert_not_contains "T6 no reap was logged" "$(cat "$T6/sup.log")" "(process group $T6S)"
kill -KILL "$T6SUP" 2>/dev/null
kill -KILL "$T6S" 2>/dev/null

th_summary_and_exit
