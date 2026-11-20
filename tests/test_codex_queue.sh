#!/usr/bin/env bash
# ABOUTME: Exercises the Codex queue through Stop using native rollout records.

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

THREAD=01a1f60d-c642-7f33-be26-0950816bebc6
TURN=01a1f60d-c65b-7580-ad01-c808f64794b6
OTHER=01a1f60d-c65b-7580-ad01-c808f64794b7
RUN=33333333-3333-4333-8333-333333333333

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CODEX_HOME="$TEST_TMPDIR/codex" CS_CACHE_DIR="$TEST_TMPDIR/cache"
    export CS_SESSION_DIR="$TEST_TMPDIR/session" CS_RUN_ID="$RUN" CS_RUN_ENGINE=codex
    export CS_RUN_OWNER_PID=$$ CS_RUN_APPROVAL=native
    export CS_CODEX_THREAD_BIN="${CS_QUEUE_TEST_HELPER:-$SCRIPT_DIR/../bin/cs-codex-thread}"
    QDIR="$CS_SESSION_DIR/.cs/local"
    ROLLOUT="$CODEX_HOME/sessions/2026/11/20/rollout-2026-11-20T00-00-00-$THREAD.jsonl"
    mkdir -p "$QDIR/queue" "${ROLLOUT%/*}"
    printf '%s\n' "$$" > "$CS_SESSION_DIR/.cs/session.lock"
    jq -n --arg run "$RUN" --argjson owner "$$" '{run_id:$run,engine:"codex",owner_pid:$owner}' > "$QDIR/run-lease.json"
    cs_binding_write "$CS_SESSION_DIR" codex "$THREAD"
    jq -nc --arg id "$THREAD" '{type:"session_meta",payload:{id:$id}}' > "$ROLLOUT"
    _record event_msg "$(jq -nc --arg t "$TURN" '{type:"task_started",turn_id:$t}')"
    _codex_run_dir_in_sandbox_root() { return 1; }
    _codex_run_dir_prepare "$CS_SESSION_DIR" >/dev/null
    CS_BIN="$TEST_TMPDIR/spawner"
    cat > "$CS_BIN" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CS_CACHE_DIR/notify.log"
EOF
    chmod +x "$CS_BIN"
    printf 'armed\n' > "$QDIR/queue.state"
    printf 'first task\n' > "$QDIR/queue/001"
    printf 'second task\n' > "$QDIR/queue/002"
    export CS_QUEUE_MAX_FAILURES=5 CS_QUEUE_MAX_CTX=85 CS_QUEUE_MAX_5H=85 CS_CODEX_QUEUE_MAX_TASKS=10
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

_record() {
    jq -nc --arg type "$1" --argjson payload "$2" \
        '{timestamp:(now|todate), type:$type, payload:$payload}' >> "$ROLLOUT"
}

_stop() {
    if [ "${1:-false}" = true ] && [ "${5:-record}" = record ]; then
        _record response_item "$(jq -nc --arg m "${2:-finished}" \
            '{type:"message",role:"assistant",phase:"final_answer",content:[{type:"output_text",text:$m}]}')"
    fi
    jq -nc --arg s "${3:-$THREAD}" --arg t "${4:-$TURN}" --arg p "$ROLLOUT" \
        --arg m "${2:-finished}" --argjson a "${1:-false}" \
        '{hook_event_name:"Stop",session_id:$s,turn_id:$t,transcript_path:$p,
          last_assistant_message:$m,stop_hook_active:$a}' | cmd_codex_hook stop
}

_deliver() {
    local escaped
    escaped=$(printf '%s\n' "$1" | jq -r '.reason | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")')
    _record response_item "$(jq -nc --arg t "$TURN" --argjson hook "${2:-true}" \
        --arg text "<hook_prompt hook_run_id=\"stop:4:hooks.json\">$escaped</hook_prompt>" \
        '{type:"message",role:"user",content:[{type:"input_text",text:$text}],
          internal_chat_message_metadata_passthrough:{turn_id:$t,content_item_metadata:[{provenance:{type:"harness",hook:$hook}}]}}')"
}

_usage() {
    _record event_msg "$(jq -nc --argjson tokens "$1" --argjson limit "${2:-null}" --argjson reset "${3:-0}" \
        '{type:"token_count",info:{last_token_usage:{total_tokens:$tokens},model_context_window:95000},
          rate_limits:{limit_id:"codex",primary:(if $limit==null then null else
            {window_minutes:300,used_percent:$limit,resets_at:$reset} end)}}')"
}

test_drains_and_notifies_once() {
    local first second final
    printf 'boss\n' > "$QDIR/spawned-by"
    first=$(_stop)
    assert_output_contains "$first" 'first task' || return 1
    _deliver "$first"
    second=$(_stop true)
    assert_output_contains "$second" 'second task' || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")" || return 1
    _deliver "$second"
    final=$(_stop true)
    assert_output_contains "$final" 'all tasks complete' || return 1
    _stop true >/dev/null
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_eq $'first task\nsecond task' "$(cat "$QDIR/queue.done")" || return 1
    assert_eq '-msg boss -k notify queue drained: 2 task(s) done' "$(cat "$CS_CACHE_DIR/notify.log")"
}

test_unbound_and_undelivered_tasks_cannot_complete() {
    local first parked
    _stop false ignored "$OTHER" >/dev/null
    assert_eq armed "$(cat "$QDIR/queue.state")" || return 1
    first=$(_stop)
    assert_output_contains "$first" 'first task' || return 1
    _deliver "$first" false
    parked=$(_stop true)
    assert_output_contains "$parked" 'could not confirm' || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_not_exists "$QDIR/queue.done" || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")"
}

test_reported_failure_keeps_the_task() {
    local first parked
    first=$(_stop)
    _deliver "$first"
    parked=$(_stop true $'summary\ncs-task-failed')
    assert_output_contains "$parked" 'task_failed' || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_not_exists "$QDIR/queue.done"
}

test_shell_and_patch_failures_count_from_this_task_only() {
    local first parked
    CS_QUEUE_MAX_FAILURES=2
    first=$(_stop)
    _record response_item '{"type":"function_call","name":"exec_command","call_id":"prelude"}'
    _record response_item '{"type":"function_call_output","call_id":"prelude","output":"Chunk ID: 42\nWall time: 0.001 seconds\nProcess exited with code 7\nOutput:\n"}'
    _deliver "$first"
    _record response_item '{"type":"function_call","name":"exec_command","call_id":"success"}'
    _record response_item '{"type":"function_call_output","call_id":"success","output":"Chunk ID: 42\nWall time: 0.001 seconds\nProcess exited with code 0\nOutput:\nProcess exited with code 9\n"}'
    _record response_item '{"type":"function_call","name":"exec_command","call_id":"a"}'
    _record response_item '{"type":"function_call_output","call_id":"a","output":"Chunk ID: 42\nWall time: 0.001 seconds\nProcess exited with code 7\nOutput:\n"}'
    _record response_item '{"type":"custom_tool_call","name":"apply_patch","call_id":"b"}'
    _record response_item '{"type":"custom_tool_call_output","call_id":"b","output":"apply_patch verification failed: file missing"}'
    parked=$(_stop true)
    assert_output_contains "$parked" 'failures at 2' || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_not_exists "$QDIR/queue.done"
}

test_missing_or_expired_usage_uses_the_cap() {
    local first parked
    CS_CODEX_QUEUE_MAX_TASKS=1
    first=$(_stop)
    _deliver "$first"
    _usage 12480 99 "$(( $(date +%s) - 1 ))"
    parked=$(_stop true)
    assert_output_contains "$parked" 'task_cap at 1' || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")" || return 1
    assert_file_exists "$QDIR/queue/002"
}

test_fresh_quota_trips_and_context_uses_the_latest_reading() {
    local first parked
    first=$(_stop)
    _deliver "$first"
    _usage 12480 87 "$(( $(date +%s) + 3600 ))"
    parked=$(_stop true)
    assert_output_contains "$parked" 'five_hour at 87' || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")" || return 1
    assert_file_exists "$QDIR/queue/002"
}

test_native_approval_notifies_once_without_deciding() {
    local first input out
    first=$(_stop)
    _deliver "$first"
    printf 'boss\n' > "$QDIR/spawned-by"
    input=$(jq -nc --arg s "$THREAD" --arg t "$TURN" '{session_id:$s,turn_id:$t}')
    out=$(printf '%s\n' "$input" | cmd_codex_hook permission-request)
    assert_eq '{}' "$out" || return 1
    printf '%s\n' "$input" | cmd_codex_hook permission-request >/dev/null
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" || return 1
    assert_output_contains "$(cat "$CS_CACHE_DIR/notify.log")" 'waiting for native approval'
}

test_receipt_without_a_new_final_answer_parks() {
    local first parked
    first=$(_stop)
    _deliver "$first"
    parked=$(_stop true earlier "$THREAD" "$TURN" skip)
    assert_output_contains "$parked" 'could not confirm' || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_not_exists "$QDIR/queue.done"
}

test_torn_rollout_tail_leaves_the_last_complete_context_reading() {
    local first parked
    first=$(_stop)
    _deliver "$first"
    _usage 90000
    _record response_item '{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"finished"}]}'
    printf '{"type":' >> "$ROLLOUT"
    parked=$(_stop true finished "$THREAD" "$TURN" skip)
    assert_output_contains "$parked" 'context at 94' || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")"
}

test_rotation_commits_the_boundary_then_resumes_the_next_task() (
    local first during after
    first=$(_stop)
    _deliver "$first"
    mkdir -p "$CS_SESSION_DIR/.cs/handoffs"
    printf -- '---\nstatus: unconsumed\n---\n' > "$CS_SESSION_DIR/.cs/handoffs/continue.md"
    printf 'continue.md\n' > "$QDIR/pending-handoff"
    export CS_CODEX_CLEAR_GRACE=0
    during=$(_stop true)
    assert_eq 1 "$(printf '%s\n' "$during" | jq -s length)" "one message for the Stop" || return 1
    assert_eq "cs task queue: the walk-away run is waiting for this rotation. Run /clear to continue from continue.md; the queue resumes in the new conversation." \
        "$(printf '%s\n' "$during" | jq -r .systemMessage)" "the run waits for /clear by hand" || return 1
    assert_eq armed "$(cat "$QDIR/queue.state")" || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")" || return 1
    assert_not_exists "$QDIR/queue.current" || return 1
    rm "$QDIR/pending-handoff"
    cs_binding_write "$CS_SESSION_DIR" codex "$OTHER"
    after=$(_stop false go "$OTHER" "$OTHER")
    assert_output_contains "$after" 'second task' || return 1
    assert_eq 1 "$(jq -s '[.[] | select(.event=="drain_started")]|length' "$QDIR/notifications.jsonl")"
)

_arm_handoff() {
    mkdir -p "$CS_SESSION_DIR/.cs/handoffs"
    printf -- '---\nstatus: unconsumed\n---\n' > "$CS_SESSION_DIR/.cs/handoffs/continue.md"
    printf 'continue.md\n' > "$QDIR/pending-handoff"
}

# A watcher of this run's, which this shell stands in for, and no pending
# switch (lib/78-switch.sh is not sourced here).
_live_watcher() {
    printf '%s %s\n' "$$" "$RUN" > "$CS_CACHE_DIR/codex-runs/$RUN/watcher.pid"
    _switch_file() { return 1; }
}

# The count is off, so nothing types /clear: the run waits for it by hand,
# and the spawner hears once.
test_rotation_without_a_countdown_notifies_the_spawner() (
    local first out
    first=$(_stop)
    _deliver "$first"
    printf 'boss\n' > "$QDIR/spawned-by"
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=0
    out=$(_stop true)
    assert_eq armed "$(cat "$QDIR/queue.state")" || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "the spawner hears of the wait" || return 1
    assert_output_contains "$(cat "$CS_CACHE_DIR/notify.log")" '/clear' || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | jq -s length)" "one message for the Stop" || return 1
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" 'waiting for this rotation' || return 1
    _stop true >/dev/null
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "one notice a drain"
)

test_rotation_with_a_live_watcher_does_not_notify() (
    local first out
    first=$(_stop)
    _deliver "$first"
    printf 'boss\n' > "$QDIR/spawned-by"
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=20
    _live_watcher
    out=$(_stop true)
    [ ! -s "$CS_CACHE_DIR/notify.log" ] || { echo "  FAIL: the spawner heard of a /clear the watcher types"; return 1; }
    assert_file_exists "$CS_CACHE_DIR/codex-runs/$RUN/autoclear" || return 1
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" '/clear and go in 20 s'
)

run_test test_drains_and_notifies_once
run_test test_unbound_and_undelivered_tasks_cannot_complete
run_test test_reported_failure_keeps_the_task
run_test test_shell_and_patch_failures_count_from_this_task_only
run_test test_missing_or_expired_usage_uses_the_cap
run_test test_fresh_quota_trips_and_context_uses_the_latest_reading
run_test test_native_approval_notifies_once_without_deciding
run_test test_receipt_without_a_new_final_answer_parks
run_test test_torn_rollout_tail_leaves_the_last_complete_context_reading
run_test test_rotation_commits_the_boundary_then_resumes_the_next_task
run_test test_rotation_without_a_countdown_notifies_the_spawner
run_test test_rotation_with_a_live_watcher_does_not_notify
report_results
