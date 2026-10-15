#!/usr/bin/env bash
# ABOUTME: Tests the watcher behind Codex's automatic /clear after a rotation (lib/77-codex-hooks.sh).
# ABOUTME: The keys it would type are recorded by a stand-in; no terminal or Codex process is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../lib/41-bindings.sh"
source "$SCRIPT_DIR/../lib/75-launch.sh"
source "$SCRIPT_DIR/../lib/76-codex.sh"
source "$SCRIPT_DIR/../lib/77-codex-hooks.sh"
source "$SCRIPT_DIR/../lib/78-switch.sh"

HANDOFF=2026-10-15-continue.md
RUN=33333333-3333-4333-8333-333333333333
OTHER_RUN=44444444-4444-4444-8444-444444444444

# What the watcher types, one line per call, instead of the terminal, which a
# test run has none of: the stand-in terminal stays until a test closes it.
# Each look at it marks a poll, so a test can wait for polls, not seconds.
_codex_type_keys() { printf '%s\n' "$1" >> "$KEYS"; }
_codex_autoclear_terminal() { printf 'poll\n' >> "$TEST_TMPDIR/polls"; [ ! -e "$TEST_TMPDIR/tty-closed" ]; }

# The real check, kept for the tests that exercise it: every other test runs
# under TMPDIR, which the check rightly refuses, so setup stands it down.
eval "_real_run_dir_in_sandbox_root() $(declare -f _codex_run_dir_in_sandbox_root | tail -n +2)"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    SESSION="$TEST_TMPDIR/session"
    KEYS="$TEST_TMPDIR/keys"
    mkdir -p "$SESSION/.cs/local" "$SESSION/.cs/handoffs"
    printf -- '---\nparent: x\ncreated: 2026-10-15T07:00:00Z\npurpose: p\nstatus: unconsumed\n---\n' \
        > "$SESSION/.cs/handoffs/$HANDOFF"
    printf '%s\n' "$HANDOFF" > "$SESSION/.cs/local/pending-handoff"
    export CS_CACHE_DIR="$TEST_TMPDIR/cache" CS_RUN_ID=$RUN CS_RUN_OWNER_PID=$$
    _codex_run_dir_in_sandbox_root() { return 1; }
    RUN_DIR=$(_codex_run_dir_prepare "$SESSION") || { echo "  FAIL: setup could not make the run directory"; return 1; }
    STAMP="$RUN_DIR/autoclear"
    WATCHER=""
}

teardown() {
    [ -z "$WATCHER" ] || { kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null || true; }
    rm -rf "$TEST_TMPDIR"
    unset CS_CACHE_DIR CS_RUN_ID CS_RUN_OWNER_PID CS_ROTATE_FORCE_CTX CS_CODEX_CLEAR_GRACE
}

# A deadline as the Stop hook writes it, into the run directory unless a test
# names another file.
_stamp() {  # deadline, [action], [run], [handoff], [file]
    local file="${5:-$STAMP}"
    printf 'deadline=%s\nhandoff=%s\naction=%s\nrun=%s\n' \
        "$1" "${4:-$HANDOFF}" "${2:-clear}" "${3:-$RUN}" > "$file"
    chmod 600 "$file"
}

_watch() { _codex_autoclear_watch "$SESSION" "$RUN_DIR" & WATCHER=$!; }

# Waits until the watcher has looked more than n times, so n polls are done.
_polls() {  # n
    local i=0 n
    while :; do
        n=0
        [ ! -f "$TEST_TMPDIR/polls" ] || n=$(wc -l < "$TEST_TMPDIR/polls" | tr -d ' ')
        [ "$n" -le "$1" ] || return 0
        i=$((i + 1)); [ "$i" -lt 100 ] || { echo "  FAIL: the watcher never polled $1 times"; return 1; }
        sleep 0.1
    done
}

# Waits for the watcher to end on its own.
_watcher_ends() {  # reason
    local i=0
    while kill -0 "$WATCHER" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -lt 40 ] || { echo "  FAIL: $1"; return 1; }
        sleep 0.1
    done
    WATCHER=""
}

# Waits up to the given seconds for the keys file to hold n lines.
_keys_after() {  # seconds, lines
    local i=0
    while [ "$i" -lt $(( $1 * 10 )) ]; do
        [ -f "$KEYS" ] && [ "$(wc -l < "$KEYS" | tr -d ' ')" = "$2" ] && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}

test_a_passed_deadline_types_clear_then_go() {
    _stamp "$(date +%s)"
    _watch
    _keys_after 6 2 || { echo "  FAIL: expected two prompts, got: $(cat "$KEYS" 2>/dev/null)"; return 1; }
    assert_eq $'/clear\ngo' "$(cat "$KEYS")" || return 1
    assert_not_exists "$STAMP" "the deadline is consumed once" || return 1
}

# The agent's sandbox writes anywhere in the session, so a deadline there,
# however well formed and with this run's id, is never the watcher's licence.
test_a_stamp_in_the_workspace_types_nothing() {
    _stamp "$(date +%s)" clear "$RUN" "$HANDOFF" "$SESSION/.cs/local/codex-autoclear"
    _watch
    _polls 2 || return 1
    assert_not_exists "$KEYS" "keys typed: $(tr '\n' ' ' < "$KEYS" 2>/dev/null)" || return 1
}

test_a_symlinked_stamp_types_nothing() {
    _stamp "$(date +%s)" clear "$RUN" "$HANDOFF" "$SESSION/.cs/local/forged"
    ln -s "$SESSION/.cs/local/forged" "$STAMP"
    _watch
    _polls 2 || return 1
    assert_not_exists "$KEYS" "a link is not the hook's file" || return 1
    [ ! -L "$STAMP" ] || { echo "  FAIL: the link was left in place"; return 1; }
    assert_file_exists "$SESSION/.cs/local/forged" "only the link goes, not what it names" || return 1
}

test_a_stamp_others_can_write_types_nothing() {
    local mode
    for mode in 644 666; do
        _stamp "$(date +%s)"
        chmod "$mode" "$STAMP"
        _watch
        _polls 2 || return 1
        assert_not_exists "$KEYS" "a stamp with mode $mode is not the hook's" || return 1
        assert_not_exists "$STAMP" "a stamp with mode $mode is dropped" || return 1
        kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null || true
        WATCHER=""; rm -f "$TEST_TMPDIR/polls"
    done
}

test_a_run_dir_others_can_open_ends_the_watch() {
    _stamp "$(date +%s)"
    chmod 755 "$RUN_DIR"
    _watch
    _watcher_ends "the watcher kept a directory that is no longer private" || return 1
    assert_not_exists "$KEYS" || return 1
    grep -q "Automatic /clear: this run's directory is gone or no longer private" "$SESSION/.cs/local/session.log" \
        || { echo "  FAIL: no session.log line"; return 1; }
}

# The link's target passes every other check, so only the link refuses it.
test_a_symlinked_run_dir_ends_the_watch() {
    _stamp "$(date +%s)" clear "$RUN" "$HANDOFF" "$SESSION/.cs/local/autoclear"
    chmod 700 "$SESSION/.cs/local"
    rmdir "$RUN_DIR"
    ln -s "$SESSION/.cs/local" "$RUN_DIR"
    _watch
    _watcher_ends "the watcher followed a linked run directory" || return 1
    assert_not_exists "$KEYS" || return 1
}

test_a_removed_run_dir_ends_the_watch() {
    _watch
    _polls 1 || return 1
    rm -rf "$RUN_DIR"
    _watcher_ends "the watcher outlived its run directory" || return 1
}

# With the real check: a cache inside the session or under TMPDIR is a place
# the sandbox can write, so the launch makes no run directory there, and the
# watcher of one already made stops at its first poll.
test_a_run_dir_the_sandbox_can_write_is_refused() {
    eval "_codex_run_dir_in_sandbox_root() $(declare -f _real_run_dir_in_sandbox_root | tail -n +2)"
    if CS_CACHE_DIR="$SESSION/.cache" CS_RUN_ID=$OTHER_RUN _codex_run_dir_prepare "$SESSION" >/dev/null; then
        echo "  FAIL: a run directory inside the session was accepted"; return 1
    fi
    assert_not_exists "$SESSION/.cache/codex-runs/$OTHER_RUN" "a refused directory is taken back" || return 1
    mkdir -p "$TEST_TMPDIR/tmp"
    if TMPDIR="$TEST_TMPDIR/tmp" CS_CACHE_DIR="$TEST_TMPDIR/tmp/cache" CS_RUN_ID=$OTHER_RUN \
        _codex_run_dir_prepare "$SESSION" >/dev/null; then
        echo "  FAIL: a run directory under TMPDIR was accepted"; return 1
    fi
    if _codex_run_dir_in_sandbox_root /usr "$SESSION"; then
        echo "  FAIL: /usr is not a sandbox root"; return 1
    fi
    _stamp "$(date +%s)"
    _watch
    _watcher_ends "the watcher kept a run directory under a sandbox root" || return 1
    assert_not_exists "$KEYS" || return 1
}

test_a_run_dir_already_there_is_not_this_runs() {
    if _codex_run_dir_prepare "$SESSION" >/dev/null; then
        echo "  FAIL: a second prepare took over an existing directory"; return 1
    fi
    if CS_RUN_ID=run-1 _codex_run_dir_prepare "$SESSION" >/dev/null; then
        echo "  FAIL: a run id that is not a uuid named a directory"; return 1
    fi
}

test_a_pending_switch_types_quit() {
    _stamp "$(date +%s)" quit
    _watch
    _keys_after 4 1 || { echo "  FAIL: nothing typed"; return 1; }
    sleep 1.5
    assert_eq /quit "$(cat "$KEYS")" || return 1
}

test_a_deadline_still_ahead_types_nothing() {
    _stamp $(( $(date +%s) + 60 ))
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" || return 1
    assert_file_exists "$STAMP" "the count is still running" || return 1
}

test_a_handoff_no_longer_armed_types_nothing() {
    _stamp "$(date +%s)"
    rm -f "$SESSION/.cs/local/pending-handoff"
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" "a /clear already taken by hand is not repeated" || return 1
    assert_not_exists "$STAMP" || return 1
}

test_another_handoff_armed_types_nothing() {
    _stamp "$(date +%s)" clear "$RUN" 2026-10-14-older.md
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" "a deadline for a different handoff is stale" || return 1
}

test_another_runs_deadline_types_nothing() {
    _stamp "$(date +%s)" clear "$OTHER_RUN"
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" || return 1
    assert_not_exists "$STAMP" "a stale deadline is dropped" || return 1
}

test_an_unreadable_deadline_is_dropped() {
    _stamp soon
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" || return 1
    assert_not_exists "$STAMP" || return 1
}

test_keys_the_terminal_refuses_are_logged() {
    _codex_type_keys() { return 1; }
    _stamp "$(date +%s)"
    _watch
    local i=0
    until grep -q "Automatic /clear: the terminal refused simulated input" "$SESSION/.cs/local/session.log" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -lt 40 ] || { echo "  FAIL: no session.log line"; return 1; }
        sleep 0.1
    done
}

test_the_watcher_ends_with_the_runs_owner() {
    local dead
    ( exit 0 ) & dead=$!; wait "$dead"
    CS_RUN_OWNER_PID=$dead _codex_autoclear_watch "$SESSION" "$RUN_DIR" & WATCHER=$!
    local i=0
    while kill -0 "$WATCHER" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -lt 30 ] || { echo "  FAIL: the watcher outlived its owner"; return 1; }
        sleep 0.1
    done
    WATCHER=""
}

# A closed tab hangs the terminal up: the watcher ends even while its owner
# lives, so nothing waits on it.
test_the_watcher_ends_with_its_terminal() {
    _watch
    sleep 1.5
    kill -0 "$WATCHER" 2>/dev/null || { echo "  FAIL: the watcher ended with its terminal still there"; return 1; }
    touch "$TEST_TMPDIR/tty-closed"
    local i=0
    while kill -0 "$WATCHER" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -lt 30 ] || { echo "  FAIL: the watcher outlived its terminal"; return 1; }
        sleep 0.1
    done
    WATCHER=""
}

# The launcher's cleanup ends the helper before it reaps the CLI, and a
# helper's own children go first.
test_cleanup_stops_the_helper_and_its_children() {
    source "$SCRIPT_DIR/../lib/16-lifecycle.sh"
    local _cs_run_helper_pid child
    ( sleep 30 & wait ) & _cs_run_helper_pid=$!
    sleep 0.3
    child=$(pgrep -P "$_cs_run_helper_pid" | head -1)
    [ -n "$child" ] || { echo "  FAIL: the stand-in helper has no child"; return 1; }
    _cs_run_stop_helper
    assert_eq "" "$_cs_run_helper_pid" || return 1
    if kill -0 "$child" 2>/dev/null; then echo "  FAIL: the helper's child survived"; return 1; fi
}

# A signal ends the launch through _cs_run_cleanup, which must end the helper:
# the helper waits for the launcher, so a cleanup that left it would hang on it.
test_run_cleanup_stops_the_helper() {
    source "$SCRIPT_DIR/../lib/16-lifecycle.sh"
    release_session_lock() { :; }
    local _cs_run_active=1 _cs_run_child_pid="" _cs_run_gate="" _cs_run_meta="$SESSION/.cs" _cs_run_helper_pid helper
    ( while :; do sleep 0.2; done ) & _cs_run_helper_pid=$!
    helper=$_cs_run_helper_pid
    _cs_run_cleanup
    if kill -0 "$helper" 2>/dev/null; then
        kill "$helper" 2>/dev/null; echo "  FAIL: the run's cleanup left its helper running"; return 1
    fi
}

# The run directory goes with the helper, after the CLI and on a signal alike.
test_stopping_the_helper_removes_its_run_dir() {
    source "$SCRIPT_DIR/../lib/16-lifecycle.sh"
    release_session_lock() { :; }
    local _cs_run_helper_pid="" _cs_run_helper_dir="$RUN_DIR"
    _stamp "$(date +%s)"
    _cs_run_stop_helper
    assert_not_exists "$RUN_DIR" "the helper's directory outlived it" || return 1
    assert_eq "" "$_cs_run_helper_dir" || return 1
    local _cs_run_active=1 _cs_run_child_pid="" _cs_run_gate="" _cs_run_meta="$SESSION/.cs"
    RUN_DIR=$(CS_RUN_ID=$OTHER_RUN _codex_run_dir_prepare "$SESSION") || return 1
    _cs_run_helper_dir=$RUN_DIR
    _cs_run_cleanup
    assert_not_exists "$RUN_DIR" "a signal's cleanup left the run directory" || return 1
}

test_the_grace_follows_the_force_setting() {
    assert_eq 20 "$(CS_ROTATE_FORCE_CTX='' _codex_autoclear_grace)" || return 1
    assert_eq 20 "$(CS_ROTATE_FORCE_CTX=80 _codex_autoclear_grace)" || return 1
    assert_eq 7 "$(CS_CODEX_CLEAR_GRACE=7 _codex_autoclear_grace)" || return 1
    assert_eq 20 "$(CS_CODEX_CLEAR_GRACE=soon _codex_autoclear_grace)" "an unreadable grace is the default" || return 1
    assert_eq 8 "$(CS_CODEX_CLEAR_GRACE=08 _codex_autoclear_grace)" "a leading zero is decimal, not octal" || return 1
    assert_eq 10 "$(CS_CODEX_CLEAR_GRACE=010 _codex_autoclear_grace)" "a leading zero is decimal, not octal" || return 1
    local value
    for value in off Off ' off ' 0 000; do
        if CS_ROTATE_FORCE_CTX="$value" _codex_autoclear_grace >/dev/null; then
            echo "  FAIL: CS_ROTATE_FORCE_CTX='$value' should turn the automatic /clear off"; return 1
        fi
    done
    for value in 0 00; do
        if CS_CODEX_CLEAR_GRACE="$value" _codex_autoclear_grace >/dev/null; then
            echo "  FAIL: CS_CODEX_CLEAR_GRACE='$value' should turn the automatic /clear off"; return 1
        fi
    done
}

run_test test_a_passed_deadline_types_clear_then_go
run_test test_a_stamp_in_the_workspace_types_nothing
run_test test_a_symlinked_stamp_types_nothing
run_test test_a_stamp_others_can_write_types_nothing
run_test test_a_run_dir_others_can_open_ends_the_watch
run_test test_a_symlinked_run_dir_ends_the_watch
run_test test_a_removed_run_dir_ends_the_watch
run_test test_a_run_dir_the_sandbox_can_write_is_refused
run_test test_a_run_dir_already_there_is_not_this_runs
run_test test_a_pending_switch_types_quit
run_test test_a_deadline_still_ahead_types_nothing
run_test test_a_handoff_no_longer_armed_types_nothing
run_test test_another_handoff_armed_types_nothing
run_test test_another_runs_deadline_types_nothing
run_test test_an_unreadable_deadline_is_dropped
run_test test_keys_the_terminal_refuses_are_logged
run_test test_the_watcher_ends_with_the_runs_owner
run_test test_the_watcher_ends_with_its_terminal
run_test test_cleanup_stops_the_helper_and_its_children
run_test test_run_cleanup_stops_the_helper
run_test test_stopping_the_helper_removes_its_run_dir
run_test test_the_grace_follows_the_force_setting

report_results
