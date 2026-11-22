#!/usr/bin/env bash
# ABOUTME: Tests the Antigravity queue with native-shaped Stop events and history.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../lib/41-bindings.sh"
source "$SCRIPT_DIR/../lib/55-queue.sh"
source "$SCRIPT_DIR/../lib/75-launch.sh"
source "$SCRIPT_DIR/../lib/76-codex.sh"
source "$SCRIPT_DIR/../lib/77-codex-hooks.sh"
source "$SCRIPT_DIR/../lib/77-codex-queue.sh"
source "$SCRIPT_DIR/../lib/78-switch.sh"
source "$SCRIPT_DIR/../lib/79-antigravity-queue.sh"
source "$SCRIPT_DIR/../lib/79-antigravity.sh"

THREAD=11111111-1111-4111-8111-111111111111
RUN=33333333-3333-4333-8333-333333333333

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export HOME="$TEST_TMPDIR/home" CS_CACHE_DIR="$TEST_TMPDIR/cache"
    export CS_SESSION_DIR="$TEST_TMPDIR/session" CS_RUN_ID="$RUN" CS_RUN_ENGINE=antigravity
    export CS_RUN_OWNER_PID=$$ CS_SESSION_META_DIR="$TEST_TMPDIR/session/.cs"
    export CS_CODEX_THREAD_BIN="$SCRIPT_DIR/../bin/cs-codex-thread"
    QDIR="$CS_SESSION_META_DIR/local"
    TRANSCRIPT="$HOME/.gemini/antigravity-cli/brain/$THREAD/.system_generated/logs/transcript_full.jsonl"
    mkdir -p "$QDIR/queue" "${TRANSCRIPT%/*}"
    git -C "$CS_SESSION_DIR" init -q
    printf '%s\n' "$$" > "$CS_SESSION_META_DIR/session.lock"
    jq -n --arg id "$RUN" --argjson owner "$$" '{engine:"antigravity",run_id:$id,owner_pid:$owner}' > "$QDIR/run-lease.json"
    cs_binding_write "$CS_SESSION_DIR" antigravity "$THREAD"
    RUN_DIR=$(_antigravity_run_dir_prepare)
    printf '%s\n' "$HOME" > "$RUN_DIR/queue-home"
    printf '%s\n' "$PPID" > "$RUN_DIR/native.pid"
    : > "$RUN_DIR/held-$THREAD"
    # Test files all live in the sandbox's temporary folder.
    _codex_run_dir_in_sandbox_root() { _codex_dir_under "$1" "$2"; }
    _antigravity_queue_arm "$CS_SESSION_DIR"
    printf 'armed\n' > "$QDIR/queue.state"
    printf 'first task\n' > "$QDIR/queue/001"
    printf 'second task\n' > "$QDIR/queue/002"
    record 0 USER_EXPLICIT USER_INPUT "go"
    record 1 MODEL PLANNER_RESPONSE "ready"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

record() {
    jq -nc --argjson step "$1" --arg source "$2" --arg type "$3" --arg content "$4" \
        '{step_index:$step,$source,$type,status:"DONE",$content}' >> "$TRANSCRIPT"
}

stop() {
    jq -nc --arg cid "${3:-$THREAD}" --arg path "$TRANSCRIPT" --argjson n "$1" --argjson idle "${2:-true}" \
        '{conversationId:$cid,transcriptPath:$path,executionNum:$n,fullyIdle:$idle,terminationReason:"NO_TOOL_CALL",lastUserInput:"go"}' |
        cmd_antigravity_hook stop
}

receipt() {
    record "$2" SYSTEM SYSTEM_MESSAGE $'system wrapper\nStop hook blocked termination: '"$(printf '%s\n' "$1" | jq -r .reason)"
}

test_drains_two_tasks_with_provenance() {
    local first next
    first=$(stop 0)
    assert_eq continue "$(printf '%s\n' "$first" | jq -r .decision)" "first task delivered" || return 1
    assert_file_contains "$QDIR/queue.current" '^001$' || return 1
    assert_eq '{}' "$(stop 0)" "duplicate Stop is ignored" || return 1
    receipt "$first" 2
    record 3 MODEL PLANNER_RESPONSE "first complete"
    next=$(stop 1)
    assert_output_contains "$next" 'second task' || return 1
    assert_file_contains "$QDIR/queue.done" '^first task$' || return 1
    receipt "$next" 4
    record 5 MODEL PLANNER_RESPONSE "second complete"
    assert_eq '{}' "$(stop 2)" "no further continuation" || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_file_contains "$QDIR/notifications.jsonl" '"event":"drain_finished","done":2' || return 1
    assert_not_exists "$QDIR/queue/002"
}

test_leaves_an_interrupted_delivery_queued() {
    local first
    first=$(stop 0)
    receipt "$first" 2
    record 3 USER_EXPLICIT USER_INPUT "new turn"
    record 4 MODEL PLANNER_RESPONSE "reply to the new turn"
    assert_eq '{}' "$(stop 0)" || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_not_exists "$QDIR/queue.done" || return 1
    assert_file_contains "$QDIR/notifications.jsonl" "could not confirm" || return 1
    printf 'armed\n' > "$QDIR/queue.state"
    assert_eq '{}' "$(stop 0)" "workspace state cannot lift the park"
}

test_ignores_busy_and_unrelated_stops() {
    assert_eq '{}' "$(stop 0 false)" || return 1
    assert_eq '{}' "$(stop 0 true "$RUN")" || return 1
    assert_eq armed "$(cat "$QDIR/queue.state")"
}

test_finishes_the_active_task_before_yielding_to_rotation() {
    local first
    first=$(stop 0)
    receipt "$first" 2
    record 3 MODEL PLANNER_RESPONSE "finished"
    mkdir -p "$CS_SESSION_META_DIR/handoffs"
    printf -- '---\nstatus: unconsumed\n---\n' > "$CS_SESSION_META_DIR/handoffs/2026-11-22-next.md"
    printf '%s\n' 2026-11-22-next.md > "$QDIR/pending-handoff"
    assert_eq '{}' "$(stop 1)" || return 1
    assert_eq armed "$(cat "$QDIR/queue.state")" || return 1
    assert_file_contains "$QDIR/queue.done" '^first task$' || return 1
    assert_file_exists "$QDIR/queue/002"
}

test_keeps_a_task_that_reports_failure() {
    local first
    first=$(stop 0)
    receipt "$first" 2
    record 3 MODEL PLANNER_RESPONSE $'could not complete\ncs-task-failed'
    assert_eq '{}' "$(stop 1)" || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_not_exists "$QDIR/queue.done" || return 1
    assert_file_contains "$QDIR/notifications.jsonl" 'the task reported failure'
}

test_finishes_on_a_background_wake() {
    local first
    first=$(stop 0)
    receipt "$first" 2
    record 3 MODEL PLANNER_RESPONSE "waiting for background work"
    assert_eq '{}' "$(stop 1 false)" || return 1
    assert_not_exists "$QDIR/queue.done" || return 1
    record 4 SYSTEM SYSTEM_MESSAGE "background tool has completed"
    record 5 MODEL PLANNER_RESPONSE "task complete"
    assert_output_contains "$(stop 0)" 'second task'
}

test_counts_nonzero_shell_exit_before_final_response() {
    local first
    export CS_QUEUE_MAX_FAILURES=1
    first=$(stop 0)
    receipt "$first" 2
    record 3 MODEL GENERIC $'Created At: time\nCommand exited with code 7.\n\nCommand output:\nfailed'
    record 4 MODEL PLANNER_RESPONSE "finished"
    assert_eq '{}' "$(stop 1)" || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_file_contains "$QDIR/notifications.jsonl" '1 tool failures'
    unset CS_QUEUE_MAX_FAILURES
}

test_keeps_remainder_after_eight_deliveries() {
    local first cache
    cache=$(_antigravity_queue_cache "$CS_SESSION_DIR")
    _antigravity_queue_record "$cache" '{"count":7}'
    first=$(stop 0)
    receipt "$first" 2
    record 3 MODEL PLANNER_RESPONSE "finished"
    assert_eq '{}' "$(stop 1)" || return 1
    assert_not_exists "$QDIR/queue/001" || return 1
    assert_file_exists "$QDIR/queue/002" || return 1
    assert_file_contains "$QDIR/notifications.jsonl" 'continuation budget reached' || return 1
    _antigravity_queue_arm "$CS_SESSION_DIR"
    printf 'armed\n' > "$QDIR/queue.state"
    assert_output_contains "$(stop 0)" 'second task'
}

test_reserves_native_continuations_already_used() {
    assert_eq '{}' "$(stop 8)" || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_file_contains "$QDIR/notifications.jsonl" 'continuation budget reached'
}

test_rejects_a_link_in_native_history() {
    mv "$TRANSCRIPT" "$TEST_TMPDIR/transcript"
    ln -s "$TEST_TMPDIR/transcript" "$TRANSCRIPT"
    assert_eq '{}' "$(stop 0)" || return 1
    assert_file_contains "$QDIR/notifications.jsonl" 'native transcript is unavailable'
}

run_test test_drains_two_tasks_with_provenance
run_test test_leaves_an_interrupted_delivery_queued
run_test test_ignores_busy_and_unrelated_stops
run_test test_finishes_the_active_task_before_yielding_to_rotation
run_test test_keeps_a_task_that_reports_failure
run_test test_finishes_on_a_background_wake
run_test test_counts_nonzero_shell_exit_before_final_response
run_test test_keeps_remainder_after_eight_deliveries
run_test test_reserves_native_continuations_already_used
run_test test_rejects_a_link_in_native_history
report_results
