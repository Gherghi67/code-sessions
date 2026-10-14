#!/usr/bin/env bash
# ABOUTME: Tests for cs <name> --remote: serving a session through claude remote-control,
# ABOUTME: with a fake claude that records argv, env names and signals (no real server).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_BIN="$SCRIPT_DIR/../bin/cs"

# setup and teardown run under the suite's errexit and outside run_test's
# count, so a command failing in either would end the suite with no FAIL line
# and no Results line. SUITE_PHASE names the one running; an exit inside it
# says which command stopped the suite, counts it as a failure and still
# reports the results.
SUITE_PHASE=""
on_suite_exit() {
    local rc=$? cmd="$BASH_COMMAND"
    [ -n "$SUITE_PHASE" ] || return 0
    echo "  FAIL: $SUITE_PHASE stopped the suite at \`$cmd\` (status $rc)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$SUITE_PHASE")
    SUITE_PHASE=""
    report_results
    exit 1
}
trap on_suite_exit EXIT

# A teardown step that failed without stopping the suite: said, and counted.
teardown_failed() {  # what
    echo "  FAIL: $SUITE_PHASE: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$SUITE_PHASE")
}

# The fake claude. --version prints FAKE_CLAUDE_VERSION and exits
# FAKE_CLAUDE_VERSION_EXIT (0 by default). Any other call appends
# what it was given to $FAKE_CLAUDE_LOG: argv, which cs variables are set (the
# names only, never a value), its cwd, its pid and parent, and what the session
# lock and .cs/local/remote.pid held when it started. FAKE_CLAUDE_MODE then
# picks how it ends:
#   exit:<n>  print an error line to stderr when n is not 0, exit n at once
#   serve     say "ready" on $FAKE_READY_FIFO, then wait for a signal; HUP,
#             INT and TERM are logged and end it with 0, as the real server
#             does; with no signal in 120 s it exits 9, so a run that
#             loses its server never hangs the suite.
write_fake_claude() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/claude" << 'FAKE'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then
    printf '%s (Claude Code)\n' "${FAKE_CLAUDE_VERSION:-2.1.299}"
    exit "${FAKE_CLAUDE_VERSION_EXIT:-0}"
fi
log="$FAKE_CLAUDE_LOG"
meta="${CLAUDE_SESSION_META_DIR:-}"
{
    printf 'bin=%s\n' "$0"
    printf 'argv='; printf '[%s]' "$@"; printf '\n'
    printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY+present}"
    printf 'CLAUDE_SESSION_NAME=%s\n' "${CLAUDE_SESSION_NAME:+set}"
    printf 'CLAUDE_SESSION_DIR=%s\n' "${CLAUDE_SESSION_DIR:+set}"
    printf 'CLAUDE_SESSION_META_DIR=%s\n' "${CLAUDE_SESSION_META_DIR:+set}"
    printf 'CLAUDE_CODE_TASK_LIST_ID=%s\n' "${CLAUDE_CODE_TASK_LIST_ID:+set}"
    printf 'CLAUDE_COWORK_MEMORY_PATH_OVERRIDE=%s\n' "${CLAUDE_COWORK_MEMORY_PATH_OVERRIDE:+set}"
    printf 'CS_LEAD_PID=%s\n' "${CS_LEAD_PID:+set}"
    printf 'CS_REMOTE_WINDOW=%s\n' "${CS_REMOTE_WINDOW+present}"
    printf 'pwd=%s\n' "$(pwd -P)"
    printf 'pid=%s\n' "$$"
    printf 'ppid=%s\n' "$(ps -o ppid= -p $$ | tr -d ' ')"
    printf 'lock=%s\n' "$(cat "$meta/session.lock" 2>/dev/null)"
    printf 'remote_pid=%s\n' "$(cat "$meta/local/remote.pid" 2>/dev/null)"
} >> "$log"
mode="${FAKE_CLAUDE_MODE:-exit:0}"
case "$mode" in
    exit:*)
        n="${mode#exit:}"
        [ "$n" = 0 ] || echo "Error: You must be logged in to use Remote Control." >&2
        exit "$n"
        ;;
    serve)
        # Waits in the read builtin on a fifo nobody writes, not on a child:
        # a child in the same process group takes the signal too, and its
        # death could end the wait before the trap ran.
        on_signal() { echo "signal $1" >> "$log"; exit 0; }
        trap 'on_signal HUP' HUP
        trap 'on_signal INT' INT
        trap 'on_signal TERM' TERM
        mkfifo "$FAKE_READY_FIFO.hold"
        exec 4<>"$FAKE_READY_FIFO.hold"
        printf 'ready\n' > "$FAKE_READY_FIFO"
        read -t 120 -u 4 _ || true
        echo "no signal" >> "$log"
        exit 9
        ;;
esac
FAKE
    chmod +x "$TEST_TMPDIR/bin/claude"
}

# Recording tmux: one line of argv per call; new-session prints a window id.
write_fake_tmux() {
    export CS_TMUX_BIN="$TEST_TMPDIR/fake-tmux"
    cat > "$CS_TMUX_BIN" << 'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
case "$1" in
    has-session) exit 1 ;;
    new-session) case "$*" in *" -P "*) echo '@0' ;; esac ;;
esac
exit 0
FAKE
    chmod +x "$CS_TMUX_BIN"
}

setup() {
    # test_name is run_test's local, visible here because bash scopes
    # dynamically.
    SUITE_PHASE="setup of ${test_name:-a test}"
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CS_TRANSCRIPTS_DIR="$TEST_TMPDIR/claude-projects"
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    mkdir -p "$CS_SESSIONS_ROOT" "$CS_TRANSCRIPTS_DIR" "$CS_CLAUDE_DIR"
    export CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1
    export FAKE_CLAUDE_LOG="$TEST_TMPDIR/claude.log"
    export FAKE_TMUX_LOG="$TEST_TMPDIR/tmux.log"
    export FAKE_READY_FIFO="$TEST_TMPDIR/ready"
    write_fake_claude
    write_fake_tmux
    export PATH="$TEST_TMPDIR/bin:$PATH"
    export CLAUDE_CODE_BIN="claude"
    unset FAKE_CLAUDE_MODE FAKE_CLAUDE_VERSION ANTHROPIC_API_KEY CS_REMOTE_WINDOW TMUX 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_TERM_THEME CS_TERM_BG_RGB 2>/dev/null || true
    SERVE_PID=""
    STARTED_PIDS=""
    SUITE_PHASE=""
}

# Stops only what the test started: the serving process group, and the
# processes it recorded in STARTED_PIDS. The serving group holds the release
# cs leaves beside the server, so the session is removed only once that group
# is empty.
teardown() {
    SUITE_PHASE="teardown of ${test_name:-a test}"
    if [ -n "${SERVE_PID:-}" ]; then
        kill -TERM -- -"$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
        group_gone_within_10s "$SERVE_PID" \
            || { kill -KILL -- -"$SERVE_PID" 2>/dev/null || true; teardown_failed "process group $SERVE_PID still ran 10 s after its server was stopped"; }
        SERVE_PID=""
    fi
    local pid
    for pid in $STARTED_PIDS; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    { exec 3<&-; } 2>/dev/null || true
    rm -rf "$TEST_TMPDIR" || teardown_failed "could not remove $TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TMUX_BIN CS_TRANSCRIPTS_DIR CS_CLAUDE_DIR 2>/dev/null || true
    SUITE_PHASE=""
}

# True once no process is left in process group <pgid>, waiting up to 10 s.
group_gone_within_10s() {  # pgid
    local i=0
    while kill -0 -- -"$1" 2>/dev/null && [ "$i" -lt 50 ]; do
        sleep 0.2
        i=$((i + 1))
    done
    ! kill -0 -- -"$1" 2>/dev/null
}

# Run a command to its end in a process group of its own, as a terminal runs
# it, with its input from RUN_CS_STDIN (/dev/null when unset), its output in
# $TEST_TMPDIR/out and its status in CS_RC. The release cs leaves beside the
# server runs in that group too, so the run is over only once the group is
# empty; the wait keeps the next step from racing it.
run_in_its_own_group() {  # command...
    CS_RC=0
    perl -e 'setpgrp(0,0); exec @ARGV' "$@" > "$TEST_TMPDIR/out" 2>&1 < "${RUN_CS_STDIN:-/dev/null}" &
    local leader=$!
    wait "$leader" || CS_RC=$?
    group_gone_within_10s "$leader" \
        || { echo "  FAIL: $* left process group $leader running 10 s after it ended"; return 1; }
}

run_cs() {  # cs args...
    run_in_its_own_group "$CS_BIN" "$@"
}

# run_cs, failing unless cs exits 0; cs's output is shown when it does not.
run_cs_ok() {  # cs args...
    run_cs "$@" || return 1
    assert_eq "0" "$CS_RC" "cs $* exits 0" || { cat "$TEST_TMPDIR/out"; return 1; }
}

# One line of the fake's log, by key (the first such line).
log_value() {  # key
    sed -n "s/^$1=//p" "$FAKE_CLAUDE_LOG" | head -1
}

# Start `cs <args>` serving in its own process group, as a tmux window or a
# terminal runs it, and wait (on a fifo, no polling) until the fake server
# says it is up. SIGINT and SIGHUP are reset to their defaults: a background
# job of a non-interactive shell starts with SIGINT ignored, a suite run
# under nohup starts with SIGHUP ignored, and a shell cannot trap a signal it
# started with ignored, so the fake would never see either.
start_serving() {  # cs args...
    mkfifo "$FAKE_READY_FIFO"
    exec 3<>"$FAKE_READY_FIFO"
    FAKE_CLAUDE_MODE=serve perl -e '$SIG{INT}="DEFAULT"; $SIG{HUP}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
        "$CS_BIN" "$@" > "$TEST_TMPDIR/serve.out" 2>&1 &
    SERVE_PID=$!
    local line=""
    read -t 60 -u 3 line || true
    [ "$line" = "ready" ] || { echo "  FAIL: the fake server never said ready"; cat "$TEST_TMPDIR/serve.out"; return 1; }
}

# Signal the serving process group, as closing a terminal or a tmux window
# does, collect cs's exit status into SERVE_RC, and wait for the release cs
# left in the group to finish.
stop_serving() {  # signal
    kill -"$1" -- -"$SERVE_PID"
    SERVE_RC=0
    wait "$SERVE_PID" || SERVE_RC=$?
    group_gone_within_10s "$SERVE_PID" \
        || { echo "  FAIL: process group $SERVE_PID still runs 10 s after its server stopped"; return 1; }
    SERVE_PID=""
}

# Run a command on a pseudo-terminal of its own, as a tmux window or a
# terminal tab runs it: the command is the session leader there. Once the
# fake server says ready, either type Ctrl-C (ctrlc) or close the terminal
# (hangup), then print how the command ended, once its process group (the
# release cs leaves beside the server included) is empty. Only the kernel
# signals anything here.
drive_on_a_terminal() {  # ctrlc|hangup, command...
    local mode="$1"
    shift
    mkfifo "$FAKE_READY_FIFO"
    FAKE_CLAUDE_MODE=serve python3 - "$mode" "$FAKE_READY_FIFO" "$@" << 'PY'
import os, pty, select, signal, sys, time
mode, fifo, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
rfd = os.open(fifo, os.O_RDWR)
pid, fd = pty.fork()
if pid == 0:
    # Defaults, as on a fresh terminal: a suite under nohup ignores SIGHUP.
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.execvp(cmd[0], cmd)
def group_gone_within_10s():
    end = time.time() + 10
    while time.time() < end:
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.2)
    return False
out, ready, start = b"", False, time.time()
while time.time() - start < 60 and not ready:
    r, _, _ = select.select([fd, rfd], [], [], 0.5)
    if rfd in r:
        os.read(rfd, 64)
        ready = True
    if fd in r:
        try:
            out += os.read(fd, 65536)
        except OSError:
            break
if not ready:
    print("never ready: " + out.decode("utf-8", "replace")[-1000:])
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    group_gone_within_10s()
    sys.exit(0)
if mode == "ctrlc":
    os.write(fd, b"\x03")
    while True:
        try:
            if not os.read(fd, 65536):
                break
        except OSError:
            break
else:
    os.close(fd)
_, status = os.waitpid(pid, 0)
ended = "exit %d" % os.WEXITSTATUS(status) if os.WIFEXITED(status) else "signal %d" % os.WTERMSIG(status)
print(ended if group_gone_within_10s() else ended + ", and its process group still ran 10 s later")
PY
}

# True once <file> is gone, waiting up to 10 s: what cs leaves behind is
# removed just after the server exits, not by it.
gone_within_10s() {  # file
    local i=0
    while [ -e "$1" ] && [ "$i" -lt 50 ]; do
        sleep 0.2
        i=$((i + 1))
    done
    [ ! -e "$1" ]
}

# A session directory with a lock held by a running process, as an open
# `cs <name>` leaves it. Called directly, never through $(...): the sleeper
# would hold the substitution's pipe open, and its pid would not reach
# STARTED_PIDS.
make_open_session() {  # name
    local sdir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$sdir/.cs/local"
    sleep 60 > /dev/null 2>&1 &
    STARTED_PIDS="$STARTED_PIDS $!"
    printf '%s\n' "$!" > "$sdir/.cs/session.lock"
}

# A process standing in for the server of session <name>: its argv carries
# `remote-control --name <name>`, as the server's does. Its pid is left in
# FAKE_SERVER_PID. Called directly, for the reason make_open_session is.
start_fake_server_process() {  # name
    perl -e 'sleep 60' remote-control --name "$1" --permission-mode default > /dev/null 2>&1 &
    FAKE_SERVER_PID=$!
    STARTED_PIDS="$STARTED_PIDS $!"
}

# A running process the test started, as a stand-in for some other program.
# Its pid is left in OTHER_PID. Called directly, for the reason
# make_open_session is.
start_unrelated_process() {
    sleep 60 > /dev/null 2>&1 &
    OTHER_PID=$!
    STARTED_PIDS="$STARTED_PIDS $!"
}

# The command the server's tmux window runs for demo in plan mode, from a
# caller whose sessions root is CS_SESSIONS_ROOT and whose claude is the fake.
window_command() {
    local self
    self="$(cd "$SCRIPT_DIR/../bin" && pwd)/cs"
    printf '%s' "sh -c '\"\$@\" || { s=\$?; printf \"\\nclaude remote-control exited with status %s. Press Enter to close this window.\\n\" \"\$s\"; read -r _; exit \"\$s\"; }' cs-remote env CS_REMOTE_WINDOW=1 'CS_SESSIONS_ROOT=$CS_SESSIONS_ROOT' 'CLAUDE_CODE_BIN=$TEST_TMPDIR/bin/claude' '$self' 'demo' --remote --permission-mode 'plan'"
}

strip_ansi() {
    sed $'s/\033\\[[0-9;]*m//g'
}

# ---------------------------------------------------------------------------

test_remote_runs_remote_control_by_absolute_path_with_the_default_mode() {
    run_cs_ok demo --remote || return 1
    assert_eq "$TEST_TMPDIR/bin/claude" "$(log_value bin)" "claude runs by its absolute path" || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default]" "$(log_value argv)" \
        "remote-control gets the session name and the default permission mode, after the verb" || return 1
    assert_eq "$(cd "$CS_SESSIONS_ROOT/demo" && pwd -P)" "$(log_value pwd)" "the server runs in the session dir" || return 1
}

test_remote_passes_the_permission_mode_it_was_given() {
    run_cs_ok demo --remote --permission-mode plan || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][plan]" "$(log_value argv)" \
        "the mode given to --permission-mode reaches remote-control" || return 1
}

test_remote_strips_the_api_key_and_keeps_the_cs_exports() {
    ANTHROPIC_API_KEY=sk-ant-example-not-a-key run_cs_ok demo --remote || return 1
    assert_eq "" "$(log_value ANTHROPIC_API_KEY)" "ANTHROPIC_API_KEY is absent from the server's env" || return 1
    local v
    for v in CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_CODE_TASK_LIST_ID \
        CLAUDE_COWORK_MEMORY_PATH_OVERRIDE CS_LEAD_PID; do
        assert_eq "set" "$(log_value "$v")" "$v is exported to the server" || return 1
    done
}

test_remote_holds_the_lock_and_records_the_server_pid_while_it_runs() {
    run_cs_ok demo --remote || return 1
    assert_eq "$(log_value pid)" "$(log_value lock)" "the lock names the server while it serves" || return 1
    assert_eq "$(log_value pid)" "$(log_value remote_pid)" ".cs/local/remote.pid names the server" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/session.lock" "the lock is gone once the release is done" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is gone once the release is done" || return 1
}

# remote-control takes no prompt, so a seed cs -spawn staged for the session
# is not run; one line says it waits for the next interactive open.
test_remote_says_a_staged_spawn_seed_stays_staged() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'token-0\nspawner\nfirst task\n' > "$CS_SESSIONS_ROOT/.spawn/demo.seed"
    run_cs_ok demo --remote || return 1
    assert_eq "A spawn seed is staged for demo; it stays staged for the next cs demo, since claude remote-control takes no prompt to start it with." \
        "$(strip_ansi < "$TEST_TMPDIR/out" | grep -F 'spawn seed')" "one line says the seed stays staged" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "token-0
spawner
first task" "$(cat "$CS_SESSIONS_ROOT/.spawn/demo.seed")" "the seed is left as it was" || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default]" "$(log_value argv)" "the server ran" || return 1
}

test_remote_shows_the_servers_error_and_exits_with_its_status() {
    FAKE_CLAUDE_MODE=exit:1 run_cs demo --remote || return 1
    assert_eq "1" "$CS_RC" "cs exits with the server's status" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/out")" "Error: You must be logged in to use Remote Control." "the server's own error is shown as is" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/session.lock" "the lock is gone after a failed start" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is gone after a failed start" || return 1
}

test_remote_refuses_a_claude_older_than_the_measured_version() {
    local rc=0 out
    out=$(FAKE_CLAUDE_VERSION=2.1.298 "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "an older claude is refused" || return 1
    assert_eq "Error: cs --remote needs Claude Code 2.1.299 or later for claude remote-control; $TEST_TMPDIR/bin/claude is 2.1.298. Update Claude Code, then retry." \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal names both versions" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
}

test_remote_accepts_a_newer_claude_by_number_not_by_text() {
    FAKE_CLAUDE_VERSION=2.1.1000 run_cs_ok demo --remote || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default]" "$(log_value argv)" \
        "2.1.1000 is newer than 2.1.299" || return 1
}

test_remote_refuses_a_claude_that_names_no_version() {
    local rc=0 out
    out=$(FAKE_CLAUDE_VERSION=unknown "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a version cs cannot read is refused" || return 1
    assert_eq "Error: cs --remote needs Claude Code 2.1.299 or later for claude remote-control; $TEST_TMPDIR/bin/claude --version printed no version number." \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal says what was read" || return 1
}

test_remote_refuses_a_claude_whose_version_check_fails() {
    local rc=0 out
    out=$(FAKE_CLAUDE_VERSION_EXIT=1 "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a failed version check is refused" || return 1
    assert_eq "Error: cs --remote needs Claude Code 2.1.299 or later for claude remote-control; $TEST_TMPDIR/bin/claude --version exited with status 1." \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal says the version check failed" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
}

test_remote_refuses_options_carried_in_claude_code_bin() {
    local rc=0 out
    out=$(CLAUDE_CODE_BIN="claude --permission-mode bypassPermissions" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "options before the verb are refused" || return 1
    assert_eq 'Error: cs --remote runs claude remote-control, which refuses options before its verb; CLAUDE_CODE_BIN carries "--permission-mode bypassPermissions" after the command. Set CLAUDE_CODE_BIN to the command alone for --remote.' \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal names the options" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
}

test_remote_refuses_a_session_open_locally() {
    "$CS_BIN" demo > /dev/null 2>&1 <<< "" || return 1
    rm -f "$FAKE_CLAUDE_LOG"
    make_open_session demo
    local pid rc=0 out
    pid="$(cat "$CS_SESSIONS_ROOT/demo/.cs/session.lock")"
    out=$("$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a session open locally is not served" || return 1
    assert_eq "Error: Session demo is already open (PID $pid); cs demo --remote serves only a session that is not open. Close it first." \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the refusal names the open session's pid" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
}

test_local_open_is_refused_while_the_session_is_served() {
    start_serving demo --remote || return 1
    local spid rc out
    spid="$(log_value pid)"
    for flag in "" --force; do
        rc=0
        out=$(CS_ASSUME_TTY=1 "$CS_BIN" demo $flag 2>&1 <<< "1") || rc=$?
        assert_eq "1" "$rc" "cs demo $flag is refused while demo is served" \
            || { printf '%s\n' "$out"; cat "$FAKE_CLAUDE_LOG"; return 1; }
        assert_eq "Error: Session demo is served by cs demo --remote (remote-control PID $spid); stop it first with Ctrl-C in its window, or close the window." \
            "$(printf '%s' "$out" | strip_ansi | tail -1)" "the refusal names the server" || return 1
    done
    assert_eq "1" "$(grep -c '^argv=' "$FAKE_CLAUDE_LOG")" "no second claude started in the served dir" || return 1
    stop_serving TERM || return 1
    assert_eq "0" "$SERVE_RC" "the server stopped cleanly" || return 1
}

test_remote_stops_cleanly_when_its_window_hangs_up() {
    start_serving demo --remote || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is written while serving" || return 1
    stop_serving HUP || return 1
    assert_eq "0" "$SERVE_RC" "cs exits 0 when the server stops cleanly on SIGHUP" || { cat "$TEST_TMPDIR/serve.out"; return 1; }
    assert_eq "1" "$(grep -cx 'signal HUP' "$FAKE_CLAUDE_LOG")" "the server got the hangup" || return 1
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" || { echo "  FAIL: remote.pid is left after the server exits"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_remote_stops_cleanly_on_ctrl_c() {
    start_serving demo --remote || return 1
    stop_serving INT || return 1
    assert_eq "0" "$SERVE_RC" "cs exits with the server's 0, not 130" || { cat "$TEST_TMPDIR/serve.out"; return 1; }
    assert_eq "1" "$(grep -cx 'signal INT' "$FAKE_CLAUDE_LOG")" "the server got the interrupt" || return 1
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_remote_stops_cleanly_when_its_terminal_closes() {
    local result
    result=$(drive_on_a_terminal hangup "$CS_BIN" demo --remote)
    assert_eq "exit 0" "$result" "the server stops cleanly when its terminal goes away" || { cat "$FAKE_CLAUDE_LOG"; return 1; }
    assert_eq "1" "$(grep -cx 'signal HUP' "$FAKE_CLAUDE_LOG")" "the server got the hangup itself" || { cat "$FAKE_CLAUDE_LOG"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" || { echo "  FAIL: remote.pid is left after the server exits"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_remote_stops_cleanly_on_ctrl_c_typed_at_its_terminal() {
    local result
    result=$(drive_on_a_terminal ctrlc "$CS_BIN" demo --remote)
    assert_eq "exit 0" "$result" "the server stops cleanly on Ctrl-C" || { cat "$FAKE_CLAUDE_LOG"; return 1; }
    assert_eq "1" "$(grep -cx 'signal INT' "$FAKE_CLAUDE_LOG")" "the server got the interrupt itself" || return 1
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" || { echo "  FAIL: remote.pid is left after the server exits"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_remote_refuses_force_finish_and_a_mode_without_remote() {
    local rc out
    rc=0; out=$("$CS_BIN" demo --remote --force 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force with --remote is refused" || return 1
    assert_eq "Error: --force cannot be used with --remote: a served session never shares its directory with another claude." \
        "$(printf '%s' "$out" | strip_ansi)" "--force refusal" || return 1
    rc=0; out=$("$CS_BIN" demo --remote -finish feat 2>&1) || rc=$?
    assert_eq "1" "$rc" "-finish with --remote is refused" || return 1
    assert_eq "Error: -finish cannot be used with --remote: remote-control takes no prompt to run /finish with." \
        "$(printf '%s' "$out" | strip_ansi)" "-finish refusal" || return 1
    rc=0; out=$("$CS_BIN" demo --permission-mode plan 2>&1) || rc=$?
    assert_eq "1" "$rc" "--permission-mode without --remote is refused" || return 1
    assert_eq "Error: --permission-mode is an option of --remote: cs demo --remote --permission-mode plan" \
        "$(printf '%s' "$out" | strip_ansi)" "--permission-mode refusal" || return 1
    rc=0; out=$("$CS_BIN" demo --remote --permission-mode 2>&1) || rc=$?
    assert_eq "1" "$rc" "--permission-mode with no mode is refused" || return 1
    assert_eq "Error: --permission-mode needs a mode: cs demo --remote --permission-mode <mode>" \
        "$(printf '%s' "$out" | strip_ansi)" "missing mode refusal" || return 1
    rc=0; out=$("$CS_BIN" demo --permission-mode --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "an option in the mode's place is refused" || return 1
    assert_eq "Error: --permission-mode needs a mode: cs demo --remote --permission-mode <mode>" \
        "$(printf '%s' "$out" | strip_ansi)" "an option is not taken as the mode" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/demo" ] || { echo "  FAIL: a refused --remote created the session"; return 1; }
}

test_remote_inside_tmux_opens_its_own_window_in_the_cs_session() {
    local rc=0 out self
    out=$(TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote --permission-mode plan 2>&1) || rc=$?
    assert_eq "0" "$rc" "the window opens" || { printf '%s\n' "$out"; return 1; }
    assert_eq "new-session -d -s cs -n remote:demo -P -F #{window_id} $(window_command)" \
        "$(grep '^new-session' "$FAKE_TMUX_LOG")" "the window runs cs --remote by absolute path, marked as the window" || return 1
    assert_eq "remote:demo runs in tmux session cs (window @0). Attach: tmux switch-client -t cs" \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the caller is told where it runs" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "the caller's own terminal starts no server" || return 1
}

# tmux starts a window with the tmux server's environment, not the caller's.
# The window still serves the caller's sessions root with the claude the
# caller checked, here against a server whose root and PATH lead elsewhere.
test_remote_window_serves_the_callers_root_with_the_callers_claude() {
    local other_root="$TEST_TMPDIR/server-sessions" other_bin="$TEST_TMPDIR/server-bin" cmd
    mkdir -p "$other_root" "$other_bin"
    cp "$TEST_TMPDIR/bin/claude" "$other_bin/claude"
    TMUX="/tmp/fake,1,0" run_cs_ok demo --remote || return 1
    cmd=$(sed -n 's/^new-session -d -s cs -n remote:demo -P -F #{window_id} //p' "$FAKE_TMUX_LOG")
    [ -n "$cmd" ] || { echo "  FAIL: no window was opened"; cat "$FAKE_TMUX_LOG"; return 1; }
    CS_SESSIONS_ROOT="$other_root" PATH="$other_bin:$PATH" CLAUDE_CODE_BIN=claude TMUX="/tmp/fake,1,0" \
        run_in_its_own_group sh -c "$cmd" || return 1
    assert_eq "0" "$CS_RC" "the window's server ran" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "$(cd "$CS_SESSIONS_ROOT" && pwd -P)/demo" "$(log_value pwd)" "the window serves the caller's sessions root" || return 1
    assert_eq "$TEST_TMPDIR/bin/claude" "$(log_value bin)" "the window runs the claude the caller checked" || return 1
    [ ! -e "$other_root/demo" ] || { echo "  FAIL: the window created demo under the tmux server's root"; return 1; }
}

test_remote_inside_tmux_without_tmux_names_remote() {
    local rc=0 out
    out=$(CS_TMUX_BIN="$TEST_TMPDIR/no-such-tmux" TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "no window opens without tmux" || return 1
    assert_eq "Error: cs --remote needs tmux" "$(printf '%s' "$out" | strip_ansi)" "the error names --remote" || return 1
}

test_remote_in_its_window_serves_there_instead_of_opening_another() {
    CS_REMOTE_WINDOW=1 TMUX="/tmp/fake,1,0" run_cs_ok demo --remote || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default]" "$(log_value argv)" "the server runs in the window" || return 1
    assert_eq "" "$(grep -E '^new-(session|window)' "$FAKE_TMUX_LOG" 2>/dev/null || true)" "no further window opens" || return 1
    assert_eq "" "$(log_value CS_REMOTE_WINDOW)" "the window marker never reaches the server" || return 1
}

test_remote_failure_in_its_window_waits_for_enter() {
    local rc=0 out
    out=$(FAKE_CLAUDE_MODE=exit:1 TMUX="/tmp/fake,1,0" sh -c "$(window_command)" 2>&1 <<< "") || rc=$?
    assert_eq "1" "$rc" "the window ends with the server's status" || return 1
    assert_eq "claude remote-control exited with status 1. Press Enter to close this window." \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the window stays until the error is read" || return 1
}

test_remote_window_close_reaches_the_server() {
    local result
    result=$(TMUX="/tmp/fake,1,0" drive_on_a_terminal hangup sh -c "$(window_command)")
    assert_eq "1" "$(grep -cx 'signal HUP' "$FAKE_CLAUDE_LOG")" "the server got the hangup through the window's sh: $result" \
        || { cat "$FAKE_CLAUDE_LOG"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" || { echo "  FAIL: remote.pid is left after the server exits"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_live_shows_a_served_session_as_remote_with_the_server_pid() {
    make_open_session demo
    start_fake_server_process demo
    local spid="$FAKE_SERVER_PID"
    printf '%s\n' "$spid" > "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    local out
    out=$("$CS_BIN" -live 2>&1 | strip_ansi | grep ' demo ') || { echo "  FAIL: demo is not listed live"; return 1; }
    assert_output_contains "$out" "remote  remote-control PID $spid" "the agent column says remote and the status names the server" || return 1
}

test_doctor_reports_a_live_server_and_removes_a_stale_pid_file() {
    make_open_session live
    start_fake_server_process live
    local spid="$FAKE_SERVER_PID" dpid out
    printf '%s\n' "$spid" > "$CS_SESSIONS_ROOT/live/.cs/local/remote.pid"
    mkdir -p "$CS_SESSIONS_ROOT/gone/.cs/local"
    sleep 60 > /dev/null 2>&1 &
    dpid=$!
    kill "$dpid"; wait "$dpid" 2>/dev/null || true
    printf '%s\n' "$dpid" > "$CS_SESSIONS_ROOT/gone/.cs/local/remote.pid"
    out=$("$CS_BIN" -doctor 2>&1 | strip_ansi) || true
    assert_eq "  [ OK ] Remote: live is served by claude remote-control (PID $spid)" \
        "$(grep -F 'Remote: live' <<< "$out")" "a live server is reported" || return 1
    assert_eq "  [WARN] Remote: gone's .cs/local/remote.pid named PID $dpid, which is no longer gone's claude remote-control server, and nothing removed it when that server ended; removed it now." \
        "$(grep -F 'Remote: gone' <<< "$out")" "a stale pid file is reported" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/gone/.cs/local/remote.pid" "the stale pid file is removed" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/live/.cs/local/remote.pid" "a live server's pid file is kept" || return 1
}

# A server whose release never ran (its process group killed with SIGKILL, a
# crash, a restart) leaves session.lock and remote.pid naming its pid. Once
# that pid belongs to another program, the session is not served: -live does
# not show it as remote, --force opens it as it opens any session whose lock
# names a live process, and -doctor removes the file.
test_a_remote_pid_another_process_took_over_serves_nothing() {
    run_cs_ok demo || return 1
    rm -f "$FAKE_CLAUDE_LOG"
    start_unrelated_process
    printf '%s\n' "$OTHER_PID" > "$CS_SESSIONS_ROOT/demo/.cs/session.lock"
    printf '%s\n' "$OTHER_PID" > "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    local out
    out=$("$CS_BIN" -live 2>&1 | strip_ansi | grep ' demo ') || { echo "  FAIL: demo is not listed live"; return 1; }
    assert_output_not_contains "$out" "remote" "-live does not show the other process as demo's server: $out" || return 1
    printf '\n' > "$TEST_TMPDIR/enter"
    RUN_CS_STDIN="$TEST_TMPDIR/enter" run_cs_ok demo --force || return 1
    assert_eq "Overriding active session lock (PID $OTHER_PID)" \
        "$(strip_ansi < "$TEST_TMPDIR/out" | grep -F 'Overriding active session lock')" "--force overrides the lock" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "1" "$(grep -c '^argv=' "$FAKE_CLAUDE_LOG")" "claude opened the session" || return 1
    out=$("$CS_BIN" -doctor 2>&1 | strip_ansi) || true
    assert_eq "  [WARN] Remote: demo's .cs/local/remote.pid named PID $OTHER_PID, which is no longer demo's claude remote-control server, and nothing removed it when that server ended; removed it now." \
        "$(grep -F 'Remote: demo' <<< "$out")" "the doctor reports the file" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "the doctor removes the file" || return 1
    kill -0 "$OTHER_PID" 2>/dev/null || { echo "  FAIL: the other process was stopped"; return 1; }
}

run_test test_remote_runs_remote_control_by_absolute_path_with_the_default_mode
run_test test_remote_passes_the_permission_mode_it_was_given
run_test test_remote_strips_the_api_key_and_keeps_the_cs_exports
run_test test_remote_holds_the_lock_and_records_the_server_pid_while_it_runs
run_test test_remote_says_a_staged_spawn_seed_stays_staged
run_test test_remote_shows_the_servers_error_and_exits_with_its_status
run_test test_remote_refuses_a_claude_older_than_the_measured_version
run_test test_remote_accepts_a_newer_claude_by_number_not_by_text
run_test test_remote_refuses_a_claude_that_names_no_version
run_test test_remote_refuses_a_claude_whose_version_check_fails
run_test test_remote_refuses_options_carried_in_claude_code_bin
run_test test_remote_refuses_a_session_open_locally
run_test test_local_open_is_refused_while_the_session_is_served
run_test test_remote_stops_cleanly_when_its_window_hangs_up
run_test test_remote_stops_cleanly_on_ctrl_c
run_test test_remote_stops_cleanly_when_its_terminal_closes
run_test test_remote_stops_cleanly_on_ctrl_c_typed_at_its_terminal
run_test test_remote_refuses_force_finish_and_a_mode_without_remote
run_test test_remote_inside_tmux_opens_its_own_window_in_the_cs_session
run_test test_remote_inside_tmux_without_tmux_names_remote
run_test test_remote_in_its_window_serves_there_instead_of_opening_another
run_test test_remote_window_serves_the_callers_root_with_the_callers_claude
run_test test_remote_failure_in_its_window_waits_for_enter
run_test test_remote_window_close_reaches_the_server
run_test test_live_shows_a_served_session_as_remote_with_the_server_pid
run_test test_doctor_reports_a_live_server_and_removes_a_stale_pid_file
run_test test_a_remote_pid_another_process_took_over_serves_nothing

report_results
