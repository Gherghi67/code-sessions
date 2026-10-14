#!/usr/bin/env bash
# ABOUTME: Tests for cs <name> --remote: serving a session through claude remote-control,
# ABOUTME: with a fake claude that records argv, env names and signals (no real server).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_BIN="$SCRIPT_DIR/../bin/cs"

# The fake claude. --version prints FAKE_CLAUDE_VERSION. Any other call appends
# what it was given to $FAKE_CLAUDE_LOG: argv, which cs variables are set (the
# names only, never a value), its cwd, its pid and parent, and what the session
# lock and .cs/local/remote.pid held when it started. FAKE_CLAUDE_MODE then
# picks how it ends:
#   exit:<n>  print an error line to stderr when n is not 0, exit n at once
#   serve     say "ready" on $FAKE_READY_FIFO, then wait for a signal; HUP,
#             INT and TERM are logged and end it with 0, as the real server
#             does; with no signal in 20 s it exits 9.
write_fake_claude() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/claude" << 'FAKE'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then
    printf '%s (Claude Code)\n' "${FAKE_CLAUDE_VERSION:-2.1.299}"
    exit 0
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
case "${FAKE_CLAUDE_MODE:-exit:0}" in
    exit:*)
        n="${FAKE_CLAUDE_MODE#exit:}"
        [ "$n" = 0 ] || echo "Error: You must be logged in to use Remote Control." >&2
        exit "$n"
        ;;
    serve)
        sleeper=""
        on_signal() { echo "signal $1" >> "$log"; [ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null; exit 0; }
        trap 'on_signal HUP' HUP
        trap 'on_signal INT' INT
        trap 'on_signal TERM' TERM
        printf 'ready\n' > "$FAKE_READY_FIFO"
        sleep 20 > /dev/null 2>&1 &
        sleeper=$!
        wait "$sleeper"
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
}

teardown() {
    if [ -n "${SERVE_PID:-}" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
        kill -TERM -- -"$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
    fi
    exec 3<&- 2>/dev/null || true
    local lf pid
    for lf in "$CS_SESSIONS_ROOT"/*/.cs/session.lock "$CS_SESSIONS_ROOT"/*/.cs/local/remote.pid; do
        [ -f "$lf" ] || continue
        pid="$(cat "$lf" 2>/dev/null || true)"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        [ "$pid" = "$$" ] || kill "$pid" 2>/dev/null || true
    done
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TMUX_BIN CS_TRANSCRIPTS_DIR CS_CLAUDE_DIR 2>/dev/null || true
}

# One line of the fake's log, by key (the first such line).
log_value() {  # key
    sed -n "s/^$1=//p" "$FAKE_CLAUDE_LOG" | head -1
}

# Start `cs <args>` serving in its own process group, as a tmux window or a
# terminal runs it, and wait (on a fifo, no polling) until the fake server
# says it is up. SIGINT is reset to its default: a background job of a
# non-interactive shell starts with it ignored, which a terminal's Ctrl-C
# never sees.
start_serving() {  # cs args...
    mkfifo "$FAKE_READY_FIFO"
    exec 3<>"$FAKE_READY_FIFO"
    FAKE_CLAUDE_MODE=serve perl -e '$SIG{INT}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
        "$CS_BIN" "$@" > "$TEST_TMPDIR/serve.out" 2>&1 &
    SERVE_PID=$!
    local line=""
    read -t 15 -u 3 line || true
    [ "$line" = "ready" ] || { echo "  FAIL: the fake server never said ready"; cat "$TEST_TMPDIR/serve.out"; return 1; }
}

# Signal the serving process group, as closing a terminal or a tmux window
# does, and collect cs's exit status into SERVE_RC.
stop_serving() {  # signal
    kill -"$1" -- -"$SERVE_PID"
    SERVE_RC=0
    wait "$SERVE_PID" || SERVE_RC=$?
    SERVE_PID=""
}

# A session directory with a lock held by a running process, as an open
# `cs <name>` leaves it. Called directly, never through $(...): the sleeper
# would hold the substitution's pipe open.
make_open_session() {  # name
    local sdir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$sdir/.cs/local"
    sleep 60 > /dev/null 2>&1 &
    printf '%s\n' "$!" > "$sdir/.cs/session.lock"
}

strip_ansi() {
    sed $'s/\033\\[[0-9;]*m//g'
}

# ---------------------------------------------------------------------------

test_remote_runs_remote_control_by_absolute_path_with_the_default_mode() {
    local rc=0
    "$CS_BIN" demo --remote > "$TEST_TMPDIR/out" 2>&1 || rc=$?
    assert_eq "0" "$rc" "cs exits with the server's status" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "$TEST_TMPDIR/bin/claude" "$(log_value bin)" "claude runs by its absolute path" || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default]" "$(log_value argv)" \
        "remote-control gets the session name and the default permission mode, after the verb" || return 1
    assert_eq "$(cd "$CS_SESSIONS_ROOT/demo" && pwd -P)" "$(log_value pwd)" "the server runs in the session dir" || return 1
}

test_remote_passes_the_permission_mode_it_was_given() {
    "$CS_BIN" demo --remote --permission-mode plan > /dev/null 2>&1 || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][plan]" "$(log_value argv)" \
        "the mode given to --permission-mode reaches remote-control" || return 1
}

test_remote_strips_the_api_key_and_keeps_the_cs_exports() {
    ANTHROPIC_API_KEY=sk-ant-example-not-a-key "$CS_BIN" demo --remote > /dev/null 2>&1 || return 1
    assert_eq "" "$(log_value ANTHROPIC_API_KEY)" "ANTHROPIC_API_KEY is absent from the server's env" || return 1
    local v
    for v in CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_CODE_TASK_LIST_ID \
        CLAUDE_COWORK_MEMORY_PATH_OVERRIDE CS_LEAD_PID; do
        assert_eq "set" "$(log_value "$v")" "$v is exported to the server" || return 1
    done
}

test_remote_holds_the_lock_and_records_the_server_pid_while_it_runs() {
    "$CS_BIN" demo --remote > /dev/null 2>&1 || return 1
    assert_eq "$(log_value ppid)" "$(log_value lock)" "the lock names cs, the server's parent, while it serves" || return 1
    assert_eq "$(log_value pid)" "$(log_value remote_pid)" ".cs/local/remote.pid names the server" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/session.lock" "the lock is released when the server exits" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is removed when the server exits" || return 1
}

test_remote_shows_the_servers_error_and_exits_with_its_status() {
    local rc=0 out
    out=$(FAKE_CLAUDE_MODE=exit:1 "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "cs exits with the server's status" || return 1
    assert_output_contains "$out" "Error: You must be logged in to use Remote Control." "the server's own error is shown as is" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/session.lock" "the lock is released after a failed start" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is removed after a failed start" || return 1
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
    FAKE_CLAUDE_VERSION=2.1.1000 "$CS_BIN" demo --remote > /dev/null 2>&1 || return 1
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
        assert_eq "1" "$rc" "cs demo $flag is refused while demo is served" || return 1
        assert_eq "Error: Session demo is served by cs demo --remote (remote-control PID $spid); stop it first with Ctrl-C in its window, or close the window." \
            "$(printf '%s' "$out" | strip_ansi | tail -1)" "the refusal names the server" || return 1
    done
    assert_eq "1" "$(grep -c '^argv=' "$FAKE_CLAUDE_LOG")" "no second claude started in the served dir" || return 1
    stop_serving TERM
    assert_eq "0" "$SERVE_RC" "the server stopped cleanly" || return 1
}

test_remote_stops_cleanly_when_its_window_hangs_up() {
    start_serving demo --remote || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is written while serving" || return 1
    stop_serving HUP
    assert_eq "0" "$SERVE_RC" "cs exits 0 when the server stops cleanly on SIGHUP" || { cat "$TEST_TMPDIR/serve.out"; return 1; }
    assert_eq "1" "$(grep -cx 'signal HUP' "$FAKE_CLAUDE_LOG")" "the server got the hangup" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is removed after the server exits" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/session.lock" "the lock is released after the server exits" || return 1
}

test_remote_stops_cleanly_on_ctrl_c() {
    start_serving demo --remote || return 1
    stop_serving INT
    assert_eq "0" "$SERVE_RC" "cs exits with the server's 0, not 130" || { cat "$TEST_TMPDIR/serve.out"; return 1; }
    assert_eq "1" "$(grep -cx 'signal INT' "$FAKE_CLAUDE_LOG")" "the server got the interrupt" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/session.lock" "the lock is released after the server exits" || return 1
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
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/demo" ] || { echo "  FAIL: a refused --remote created the session"; return 1; }
}

test_remote_inside_tmux_opens_its_own_window_in_the_cs_session() {
    local rc=0 out self
    out=$(TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote --permission-mode plan 2>&1) || rc=$?
    assert_eq "0" "$rc" "the window opens" || { printf '%s\n' "$out"; return 1; }
    self="$(cd "$SCRIPT_DIR/../bin" && pwd)/cs"
    assert_eq "new-session -d -s cs -n remote:demo -P -F #{window_id} env CS_REMOTE_WINDOW=1 '$self' 'demo' --remote --permission-mode 'plan'" \
        "$(grep '^new-session' "$FAKE_TMUX_LOG")" "the window runs cs --remote by absolute path, marked as the window" || return 1
    assert_eq "remote:demo runs in tmux session cs (window @0). Attach: tmux switch-client -t cs" \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the caller is told where it runs" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "the caller's own terminal starts no server" || return 1
}

test_remote_in_its_window_serves_there_instead_of_opening_another() {
    local rc=0
    CS_REMOTE_WINDOW=1 TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote > "$TEST_TMPDIR/out" 2>&1 || rc=$?
    assert_eq "0" "$rc" "the window's cs serves" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "[remote-control][--name][demo][--permission-mode][default]" "$(log_value argv)" "the server runs in the window" || return 1
    assert_eq "" "$(grep -E '^new-(session|window)' "$FAKE_TMUX_LOG" 2>/dev/null || true)" "no further window opens" || return 1
    assert_eq "" "$(log_value CS_REMOTE_WINDOW)" "the window marker never reaches the server" || return 1
}

test_remote_failure_in_its_window_waits_for_a_key() {
    local rc=0 out
    out=$(FAKE_CLAUDE_MODE=exit:1 CS_REMOTE_WINDOW=1 TMUX="/tmp/fake,1,0" CS_ASSUME_TTY=1 "$CS_BIN" demo --remote 2>&1 <<< "x") || rc=$?
    assert_eq "1" "$rc" "cs exits with the server's status" || return 1
    assert_eq "claude remote-control exited with status 1. Press a key to close this window." \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the window stays until the error is read" || return 1
}

test_live_shows_a_served_session_as_remote_with_the_server_pid() {
    make_open_session demo
    sleep 60 > /dev/null 2>&1 &
    local spid=$!
    printf '%s\n' "$spid" > "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    local out
    out=$("$CS_BIN" -live 2>&1 | strip_ansi | grep ' demo ') || { echo "  FAIL: demo is not listed live"; return 1; }
    assert_output_contains "$out" "remote  remote-control PID $spid" "the agent column says remote and the status names the server" || return 1
    kill "$spid" 2>/dev/null || true
}

test_doctor_reports_a_live_server_and_removes_a_stale_pid_file() {
    make_open_session live
    sleep 60 > /dev/null 2>&1 &
    local spid=$! dpid out
    printf '%s\n' "$spid" > "$CS_SESSIONS_ROOT/live/.cs/local/remote.pid"
    mkdir -p "$CS_SESSIONS_ROOT/gone/.cs/local"
    sleep 60 > /dev/null 2>&1 &
    dpid=$!
    kill "$dpid"; wait "$dpid" 2>/dev/null || true
    printf '%s\n' "$dpid" > "$CS_SESSIONS_ROOT/gone/.cs/local/remote.pid"
    out=$("$CS_BIN" -doctor 2>&1 | strip_ansi) || true
    assert_output_contains "$out" "[ OK ] Remote: live is served by claude remote-control (PID $spid)" "a live server is reported" || return 1
    assert_output_contains "$out" "[WARN] Remote: gone's .cs/local/remote.pid named PID $dpid, which is not running; removed it. A server killed with SIGKILL leaves its spawned session running: look for it with ps." \
        "a stale pid file is reported" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/gone/.cs/local/remote.pid" "the stale pid file is removed" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/live/.cs/local/remote.pid" "a live server's pid file is kept" || return 1
    kill "$spid" 2>/dev/null || true
}

run_test test_remote_runs_remote_control_by_absolute_path_with_the_default_mode
run_test test_remote_passes_the_permission_mode_it_was_given
run_test test_remote_strips_the_api_key_and_keeps_the_cs_exports
run_test test_remote_holds_the_lock_and_records_the_server_pid_while_it_runs
run_test test_remote_shows_the_servers_error_and_exits_with_its_status
run_test test_remote_refuses_a_claude_older_than_the_measured_version
run_test test_remote_accepts_a_newer_claude_by_number_not_by_text
run_test test_remote_refuses_a_claude_that_names_no_version
run_test test_remote_refuses_options_carried_in_claude_code_bin
run_test test_remote_refuses_a_session_open_locally
run_test test_local_open_is_refused_while_the_session_is_served
run_test test_remote_stops_cleanly_when_its_window_hangs_up
run_test test_remote_stops_cleanly_on_ctrl_c
run_test test_remote_refuses_force_finish_and_a_mode_without_remote
run_test test_remote_inside_tmux_opens_its_own_window_in_the_cs_session
run_test test_remote_in_its_window_serves_there_instead_of_opening_another
run_test test_remote_failure_in_its_window_waits_for_a_key
run_test test_live_shows_a_served_session_as_remote_with_the_server_pid
run_test test_doctor_reports_a_live_server_and_removes_a_stale_pid_file

report_results
