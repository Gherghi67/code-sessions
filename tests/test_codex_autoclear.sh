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

# What the watcher types, one line per call, instead of the terminal, which a
# test run has none of: the stand-in terminal stays until a test closes it.
_codex_type_keys() { printf '%s\n' "$1" >> "$KEYS"; }
_codex_autoclear_terminal() { [ ! -e "$TEST_TMPDIR/tty-closed" ]; }

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    SESSION="$TEST_TMPDIR/session"
    KEYS="$TEST_TMPDIR/keys"
    mkdir -p "$SESSION/.cs/local" "$SESSION/.cs/handoffs"
    printf -- '---\nparent: x\ncreated: 2026-10-15T07:00:00Z\npurpose: p\nstatus: unconsumed\n---\n' \
        > "$SESSION/.cs/handoffs/$HANDOFF"
    printf '%s\n' "$HANDOFF" > "$SESSION/.cs/local/pending-handoff"
    export CS_RUN_ID=run-1 CS_RUN_OWNER_PID=$$
    WATCHER=""
}

teardown() {
    [ -z "$WATCHER" ] || { kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null || true; }
    rm -rf "$TEST_TMPDIR"
    unset CS_RUN_ID CS_RUN_OWNER_PID CS_ROTATE_FORCE_CTX CS_CODEX_CLEAR_GRACE
}

_stamp() {  # deadline, [action], [run], [handoff]
    printf 'deadline=%s\nhandoff=%s\nthread=t\naction=%s\nrun=%s\n' \
        "$1" "${4:-$HANDOFF}" "${2:-clear}" "${3:-run-1}" > "$SESSION/.cs/local/codex-autoclear"
}

_watch() { _codex_autoclear_watch "$SESSION" & WATCHER=$!; }

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
    assert_not_exists "$SESSION/.cs/local/codex-autoclear" "the deadline is consumed once" || return 1
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
    assert_file_exists "$SESSION/.cs/local/codex-autoclear" "the count is still running" || return 1
}

test_a_handoff_no_longer_armed_types_nothing() {
    _stamp "$(date +%s)"
    rm -f "$SESSION/.cs/local/pending-handoff"
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" "a /clear already taken by hand is not repeated" || return 1
    assert_not_exists "$SESSION/.cs/local/codex-autoclear" || return 1
}

test_another_handoff_armed_types_nothing() {
    _stamp "$(date +%s)" clear run-1 2026-10-14-older.md
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" "a deadline for a different handoff is stale" || return 1
}

test_another_runs_deadline_types_nothing() {
    _stamp "$(date +%s)" clear run-0
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" || return 1
    assert_not_exists "$SESSION/.cs/local/codex-autoclear" "a stale deadline is dropped" || return 1
}

test_an_unreadable_deadline_is_dropped() {
    printf 'deadline=soon\n' > "$SESSION/.cs/local/codex-autoclear"
    _watch
    sleep 2.5
    assert_not_exists "$KEYS" || return 1
    assert_not_exists "$SESSION/.cs/local/codex-autoclear" || return 1
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
    CS_RUN_OWNER_PID=$dead _codex_autoclear_watch "$SESSION" & WATCHER=$!
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

test_the_grace_follows_the_force_setting() {
    assert_eq 20 "$(CS_ROTATE_FORCE_CTX='' _codex_autoclear_grace)" || return 1
    assert_eq 20 "$(CS_ROTATE_FORCE_CTX=80 _codex_autoclear_grace)" || return 1
    assert_eq 7 "$(CS_CODEX_CLEAR_GRACE=7 _codex_autoclear_grace)" || return 1
    assert_eq 20 "$(CS_CODEX_CLEAR_GRACE=soon _codex_autoclear_grace)" "an unreadable grace is the default" || return 1
    local value
    for value in off Off ' off ' 0 000; do
        if CS_ROTATE_FORCE_CTX="$value" _codex_autoclear_grace >/dev/null; then
            echo "  FAIL: CS_ROTATE_FORCE_CTX='$value' should turn the automatic /clear off"; return 1
        fi
    done
}

run_test test_a_passed_deadline_types_clear_then_go
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
run_test test_the_grace_follows_the_force_setting

report_results
