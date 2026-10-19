#!/usr/bin/env bash
# Regression test for your-org/nexus-code#1693: a labsh supervisor that is
# REPLACED (the version-aware restart's `svc.sh restart` with
# SVC_RESTART_MODE=replace) leaves a healthy server it owns running for its
# successor, which adopts it; every other stop still stops the server.
#
# The subjects, driven end to end through the real cockpit:
#   monitor/svc.sh               the replace mark, the TERM to the supervisor
#                                ALONE, the ACK, the successor launch
#   monitor/labsh-supervised.sh  on_term's four-fact hand-off, the owner
#                                record, the successor's adopt-or-restart
#
# Hermetic: labsh is a PATH-shadow stub whose `start` backgrounds a real
# token-checking HTTP server WITHOUT job control — so, exactly like labsh's
# `uvx … &`, the server lands in the SUPERVISOR's process group. That is the
# fact the svc.sh half exists for: a group TERM kills such a server whatever
# `on_term` decides. Registry and state are fixture-local
# (NEXUS_SERVICES_REGISTRY / NEXUS_STATE_DIR); the live registry is never read.
#
# Arms (the hand-off needs all of mark + pid + age + health + ownership):
#   R1  replace-marked, healthy, owned      → server ALIVE, same pid, adopted
#   R2  operator `svc.sh restart` (no mode) → server stopped, a new one started
#   R3  replace-marked but UNHEALTHY        → stopped
#   R4  a mark naming a DIFFERENT pid       → stopped
#   R5  a STALE mark naming this pid        → stopped
#   R6  replace-marked, no owner record     → stopped (ownership unknown)
#   R7  replace + launch config changed     → handed off, then the successor
#                                             restarts it (the middle path)
#   R8  plain `svc.sh stop`                 → stopped
#
# Run: bash monitor/watcher/test-labsh-replace-adopt.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

MON_DIR=$(cd "$_test_dir/.." && pwd)
HEALTH="$MON_DIR/jupyter-health.sh"
SUP="$MON_DIR/labsh-supervised.sh"
SVC="$MON_DIR/svc.sh"

WORK=$(mktemp -d -t nexus-labsh-replace-XXXXXX)
cleanup() {
    local pf pid
    for pf in "$WORK"/state/services/*.pid "$WORK"/p*/.jupyter/stub.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; }
    done
    for pid in "${SPAWNED_PIDS[@]:-}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
SPAWNED_PIDS=()
th_trap_exit cleanup

export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
mkdir -p "$NEXUS_STATE_DIR"
: > "$NEXUS_SERVICES_REGISTRY"
unset JUPYTER_DATA_DIR JUPYTER_CONFIG_DIR SVC_RESTART_MODE SVC_RESTART_ACTOR
# A long watchdog interval: the bring-up probe is immediate regardless, and no
# arm may be decided by the watchdog bouncing a server mid-assertion.
export LABSH_SVC_INTERVAL=30 LABSH_SVC_FAILS=2 LABSH_SVC_START_GRACE=10
export LABSH_HEALTH_TIMEOUT=1 LABSH_SVC_REPIN_DAYS=0

# --- stubs --------------------------------------------------------------------
STUBS="$WORK/stub-bin"
mkdir -p "$STUBS"
cat > "$STUBS/stub-server.py" <<'PY'
import http.server, sys
PORT, TOKEN = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == '/api/status' and \
             self.headers.get('Authorization') == 'token ' + TOKEN
        self.send_response(200 if ok else 403)
        self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY
cat > "$STUBS/labsh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
J="\$PWD/.jupyter"
RT="\$J/share/jupyter/runtime"
alive() { [[ -f "\$J/stub.pid" ]] && kill -0 "\$(cat "\$J/stub.pid" 2>/dev/null)" 2>/dev/null; }
case "\${1:-}" in
  start)
    shift
    if alive; then echo "labsh: server is already running (pid \$(cat "\$J/stub.pid"))" >&2; exit 1; fi
    port=0
    while (( \$# > 0 )); do case "\$1" in --port) port="\$2"; shift 2 ;; *) shift ;; esac; done
    mkdir -p "\$J" "\$RT"
    [[ -s "\$J/token" ]] || printf 'tok-%s' "\$RANDOM" > "\$J/token"
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
    # No setsid, no job control: the server joins the CALLER's process group,
    # as labsh's own \`uvx … &\` does.
    python3 "$STUBS/stub-server.py" "\$port" "\$(cat "\$J/token")" >/dev/null 2>&1 &
    spid=\$!
    echo "\$spid" > "\$J/stub.pid"; echo "\$port" > "\$J/stub.port"
    echo \$(( \$(cat "\$J/stub-start-count" 2>/dev/null || echo 0) + 1 )) > "\$J/stub-start-count"
    printf '{"pid": %s, "url": "http://127.0.0.1:%s/", "port": %s, "token": "%s", "secure": false}\n' \
        "\$spid" "\$port" "\$port" "\$(cat "\$J/token")" > "\$RT/jpserver-\$spid.json"
    for i in \$(seq 1 40); do curl -fs -o /dev/null "http://127.0.0.1:\$port/x" 2>/dev/null; [[ \$? == 22 ]] && break; sleep 0.1; done
    ;;
  url)
    alive || { echo "labsh-stub: no running server" >&2; exit 1; }
    echo "http://127.0.0.1:\$(cat "\$J/stub.port")/lab?token=\$(cat "\$J/token")"
    ;;
  stop)
    if [[ -f "\$J/stub.pid" ]]; then
        spid=\$(cat "\$J/stub.pid")
        kill "\$spid" 2>/dev/null
        rm -f "\$RT/jpserver-\$spid.json" "\$J/stub.pid"
    fi
    ;;
  *) echo "labsh-stub: unhandled verb: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$STUBS/labsh"
export PATH="$STUBS:$PATH"

# --- helpers --------------------------------------------------------------------
wait_for() {  # wait_for <label> <deadline-s> -- cmd...
    local label="$1" deadline; deadline=$(th_deadline "$2"); shift 3
    local t=0
    while (( t < deadline * 4 )); do
        "$@" >/dev/null 2>&1 && { printf '  PASS: %s\n' "$label"; _th_pass; return 0; }
        sleep 0.25; t=$(( t + 1 ))
    done
    printf '  FAIL: %s (deadline %ss)\n' "$label" "$deadline" >&2; _th_fail; return 1
}
sup_pid() { local p="" f="$NEXUS_STATE_DIR/services/$1.pid"; [[ -r "$f" ]] && read -r p < "$f"; printf '%s' "$p"; }
srv_pid() { cat "$1/.jupyter/stub.pid" 2>/dev/null; }
starts()  { cat "$1/.jupyter/stub-start-count" 2>/dev/null || echo 0; }
# A COMMAND for wait_for, so the count is re-read on every poll (an inline
# `test "$(starts …)" = 2` is expanded ONCE, when wait_for is called).
starts_is() { [[ "$(starts "$1")" == "$2" ]]; }
live()    { [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
gone()    { ! kill -0 "$1" 2>/dev/null; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

# up <name> — register a fresh project and bring it up through `svc.sh start`.
up() {
    local n="$1" d="$WORK/$1"
    mkdir -p "$d/.jupyter"
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$d" "$SUP" "$HEALTH" "$d/.jupyter/labsh-service.log" >> "$NEXUS_SERVICES_REGISTRY"
    "$SVC" start "$n" >/dev/null 2>&1
    wait_for "$n: brought up healthy under svc.sh" 30 -- "$HEALTH" "$d"
    wait_for "$n: the owner record names the server it started" 15 -- \
        grep -qx "server_pid=$(srv_pid "$d")" "$d/.jupyter/labsh-server.owner"
}
replace() { SVC_RESTART_ACTOR=version-restart SVC_RESTART_MODE=replace "$SVC" restart "$1" 2>&1; }

# ==============================================================================
echo '=== R1: replace-marked TERM, healthy, owned → the server is left alive and ADOPTED ==='
up p1; P1="$WORK/p1"
S=$(srv_pid "$P1"); OLD=$(sup_pid p1)
assert_eq "R1 PRECONDITION: the server is in the supervisor's process group (else a group TERM could not kill it)" \
    "$(pgid_of "$S")" "$OLD"
out=$(replace p1); rc=$?
assert_eq "R1 svc.sh restart exits 0" "$rc" "0"
assert_contains "R1 svc.sh replaced rather than stopped" "$out" "REPLACING supervisor pid $OLD"
assert_contains "R1 svc.sh launched the successor itself" "$out" "the new supervisor adopts the running server"
NEW=$(sup_pid p1)
assert_eq "R1 the old supervisor is gone" "$(live "$OLD")" "gone"
assert_eq "R1 a NEW supervisor is running" "$( [[ -n "$NEW" && "$NEW" != "$OLD" ]] && live "$NEW")" "alive"
assert_eq "R1 the SAME server process is still alive" "$(live "$S")" "alive"
assert_eq "R1 and is still the project's server" "$(srv_pid "$P1")" "$S"
wait_for "R1 the successor logged the adoption" 15 -- \
    grep -qF "a healthy server (pid $S) is already running with this supervisor's launch configuration — adopted" "$P1/.jupyter/labsh-service.log"
assert_eq "R1 no second labsh start was issued" "$(starts "$P1")" "1"
assert_eq "R1 still healthy" "$("$HEALTH" "$P1" >/dev/null 2>&1; echo $?)" "0"
assert_no_file "R1 the replace mark was consumed" "$P1/.jupyter/labsh-supervisor.replace"
assert_no_file "R1 the hand-off ack was cleared" "$P1/.jupyter/labsh-supervisor.handoff"

echo '=== R2: an operator `svc.sh restart` (no replace mode) still BOUNCES the server ==='
out=$("$SVC" restart p1 2>&1)
assert_not_contains "R2 svc.sh did not replace" "$out" "REPLACING"
wait_for "R2 the adopted server was STOPPED" 15 -- gone "$S"
wait_for "R2 a fresh server was started" 20 -- starts_is "$P1" 2
wait_for "R2 healthy again" 20 -- "$HEALTH" "$P1"

echo '=== R3: replace-marked but the server is UNHEALTHY → stopped ==='
up p3; P3="$WORK/p3"; S=$(srv_pid "$P3")
printf 'rotated-%s' "$RANDOM" > "$P3/.jupyter/token"     # alive, but answers 403
# jupyter-health.sh exits 22 for "answered and REJECTED our token".
assert_eq "R3 PRECONDITION: the server is alive but unhealthy (health rc 22, token rejected)" \
    "$(live "$S") $("$HEALTH" "$P3" >/dev/null 2>&1; echo $?)" "alive 22"
out=$(replace p3)
assert_contains "R3 svc.sh did ask for a replacement" "$out" "REPLACING supervisor pid"
wait_for "R3 the unhealthy server was STOPPED" 15 -- gone "$S"
assert_contains "R3 the refusal says why" "$(cat "$P3/.jupyter/labsh-service.log")" "the server is NOT healthy — stopping it"
wait_for "R3 the successor started a fresh healthy server" 20 -- "$HEALTH" "$P3"

echo '=== R4: a replace mark naming a DIFFERENT pid → stopped ==='
up p4; P4="$WORK/p4"; S=$(srv_pid "$P4"); SP=$(sup_pid p4)
printf 'pid=%s\nat=%s\n' "$$" "$(date +%s)" > "$P4/.jupyter/labsh-supervisor.replace"
kill -TERM "$SP"          # the replace-mode signal: the supervisor alone
wait_for "R4 the server was STOPPED" 15 -- gone "$S"
assert_contains "R4 the refusal names the other pid" "$(cat "$P4/.jupyter/labsh-service.log")" "names pid $$, not this supervisor"
assert_no_file "R4 no hand-off ack was written" "$P4/.jupyter/labsh-supervisor.handoff"

echo '=== R5: a STALE mark naming this pid → stopped ==='
up p5; P5="$WORK/p5"; S=$(srv_pid "$P5"); SP=$(sup_pid p5)
printf 'pid=%s\nat=%s\n' "$SP" "$(( $(date +%s) - 3600 ))" > "$P5/.jupyter/labsh-supervisor.replace"
kill -TERM "$SP"
wait_for "R5 the server was STOPPED" 15 -- gone "$S"
assert_contains "R5 the refusal says stale" "$(cat "$P5/.jupyter/labsh-service.log")" "the replace mark is stale or undated"
# CONTROL for R4/R5: the SAME direct signal with a FRESH mark naming this pid
# hands off — so the two rows above are refused by the mark, not by the path.
up p5c; P5C="$WORK/p5c"; S=$(srv_pid "$P5C"); SP=$(sup_pid p5c)
printf 'pid=%s\nat=%s\n' "$SP" "$(date +%s)" > "$P5C/.jupyter/labsh-supervisor.replace"
kill -TERM "$SP"
wait_for "R5 CONTROL: the supervisor exits" 15 -- gone "$SP"
assert_eq "R5 CONTROL: a fresh mark naming this pid leaves the server alive" "$(live "$S")" "alive"
assert_contains "R5 CONTROL: …and acks the hand-off" "$(cat "$P5C/.jupyter/labsh-supervisor.handoff" 2>/dev/null)" "pid=$SP"

echo '=== R6: replace-marked, healthy, but no owner record (ownership unknown) → stopped ==='
up p6; P6="$WORK/p6"; S=$(srv_pid "$P6")
rm -f "$P6/.jupyter/labsh-server.owner"
out=$(replace p6)
wait_for "R6 the server was STOPPED" 15 -- gone "$S"
assert_contains "R6 the refusal says ownership" "$(cat "$P6/.jupyter/labsh-service.log")" "is not the one .jupyter/labsh-server.owner names"
wait_for "R6 the successor started a fresh healthy server" 20 -- "$HEALTH" "$P6"

echo '=== R7: replace with a changed launch configuration → handed off, then RESTARTED by the successor ==='
up p7; P7="$WORK/p7"; S=$(srv_pid "$P7")
out=$(LABSH_WITH="jupyterlab-code-formatter black isort extra-pkg" replace p7)
assert_contains "R7 the old supervisor handed off" "$out" "the new supervisor adopts the running server"
wait_for "R7 the successor detected the configuration change" 15 -- \
    grep -qF "the running server (pid $S) was launched with a DIFFERENT configuration" "$P7/.jupyter/labsh-service.log"
wait_for "R7 the old server was stopped" 15 -- gone "$S"
wait_for "R7 a fresh server was started under the new configuration" 20 -- starts_is "$P7" 2
wait_for "R7 healthy again" 20 -- "$HEALTH" "$P7"

echo '=== R8: a plain `svc.sh stop` → stopped (unchanged) ==='
up p8; P8="$WORK/p8"; S=$(srv_pid "$P8")
out=$("$SVC" stop p8 2>&1)
assert_not_contains "R8 no replacement on stop" "$out" "REPLACING"
wait_for "R8 the server was STOPPED" 15 -- gone "$S"

th_summary_and_exit
