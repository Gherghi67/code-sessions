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
source "$SCRIPT_DIR/../lib/76-codex-vault.sh"
source "$SCRIPT_DIR/../lib/77-codex-hooks.sh"
source "$SCRIPT_DIR/../lib/77-codex-queue.sh"
source "$SCRIPT_DIR/../lib/78-switch.sh"

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
    # $TMPDIR and /tmp are left out only because the fixture lives under them.
    _codex_run_dir_in_sandbox_root() { _codex_dir_under "$1" "$2"; }
    _codex_run_dir_prepare "$CS_SESSION_DIR" >/dev/null
    # What a launch records for a Codex that writes the hook provenance.
    : > "$CS_CACHE_DIR/codex-runs/$RUN/queue-version-ok"
    # And the session it serves, by its physical path.
    (cd -P "$CS_SESSION_DIR" && pwd -P) > "$CS_CACHE_DIR/codex-runs/$RUN/session"
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
    printf 'boss\n' > "$QDIR/spawned-by"
    first=$(_stop)
    _deliver "$first"
    parked=$(_stop true $'summary\ncs-task-failed')
    assert_output_contains "$parked" 'reported the task as not completed' || return 1
    assert_output_not_contains "$parked" 'threshold' || return 1
    assert_file_contains "$CS_CACHE_DIR/notify.log" 'task reported failed, 2 task(s) remaining' || return 1
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

# More than 8 MiB of output after the receipt. Written by jq directly: as an
# argument it would be too long.
_large_output() {
    jq -nc --arg id big '{timestamp:(now|todate),type:"response_item",
        payload:{type:"function_call_output",call_id:$id,output:("x" * 9437184)}}' >> "$ROLLOUT"
}

test_large_task_output_keeps_the_receipt() {
    local first parked
    CS_QUEUE_MAX_FAILURES=1
    first=$(_stop)
    _deliver "$first"
    _record response_item '{"type":"function_call","name":"exec_command","call_id":"a"}'
    _record response_item '{"type":"function_call_output","call_id":"a","output":"Chunk ID: 42\nWall time: 0.001 seconds\nProcess exited with code 7\nOutput:\n"}'
    _large_output
    parked=$(_stop true)
    assert_output_contains "$parked" 'failures at 1' || return 1
    assert_file_exists "$QDIR/queue/001"
}

test_large_task_output_still_delivers_the_next_task() {
    local first second
    first=$(_stop)
    _deliver "$first"
    _large_output
    second=$(_stop true)
    assert_output_contains "$second" 'second task' || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")"
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

# A later reading for another limit carries no five-hour quota of Codex's.
test_a_later_reading_of_another_limit_keeps_the_quota() {
    local first parked reset
    reset=$(( $(date +%s) + 3600 ))
    first=$(_stop)
    _deliver "$first"
    _usage 12480 90 "$reset"
    _record event_msg "$(jq -nc --argjson reset "$reset" \
        '{type:"token_count",info:{last_token_usage:{total_tokens:12480},model_context_window:95000},
          rate_limits:{limit_id:"codex_other",primary:{window_minutes:300,used_percent:10,resets_at:$reset}}}')"
    parked=$(_stop true)
    assert_output_contains "$parked" 'five_hour at 90' || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")"
}

test_a_later_empty_reading_keeps_the_context() {
    local first parked
    first=$(_stop)
    _deliver "$first"
    _usage 90000
    _record event_msg '{"type":"token_count","info":null,"rate_limits":null}'
    parked=$(_stop true)
    assert_output_contains "$parked" 'context at 94'
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

_permission() {  # [session_id, agent_id]
    jq -nc --arg s "${1:-$THREAD}" --arg t "$TURN" --arg a "${2:-}" \
        '{session_id:$s,turn_id:$t} + (if $a == "" then {} else {agent_id:$a} end)' \
        | cmd_codex_hook permission-request
}

# A native subagent asks from its own thread, and its request is the drain's
# first.
test_subagent_approval_notifies_once() {
    local first out
    printf 'subagents\n' > "$QDIR/queue.mode"
    printf 'boss\n' > "$QDIR/spawned-by"
    first=$(_stop)
    _deliver "$first"
    out=$(_permission "$OTHER" worker)
    assert_eq '{}' "$out" || return 1
    assert_eq 1 "$(grep -c -F 'waiting for native approval' "$CS_CACHE_DIR/notify.log" 2>/dev/null)" \
        "the subagent's request notifies the spawner" || return 1
    _permission >/dev/null
    assert_eq 1 "$(grep -c -F 'waiting for native approval' "$CS_CACHE_DIR/notify.log")" "one notice a drain"
}

# cs -queue as the user runs it in this session.
_cs_queue() {
    CS_SESSION_META_DIR="$CS_SESSION_DIR/.cs" run_queue "$@"
}

# A batch armed after cs -queue clear is a new drain: it starts, counts and
# sends its approval notice afresh.
_assert_fresh_drain() {
    local out
    mkdir -p "$QDIR/queue"
    printf 'new task\n' > "$QDIR/queue/010"
    CS_SESSION_META_DIR="$CS_SESSION_DIR/.cs" _queue_start "$QDIR" || return 1
    out=$(_stop)
    assert_output_contains "$out" 'starting a walk-away run' || return 1
    assert_eq 2 "$(jq -s '[.[] | select(.event=="drain_started")]|length' "$QDIR/notifications.jsonl")" || return 1
    _permission >/dev/null
    assert_eq 2 "$(grep -c -F 'waiting for native approval' "$CS_CACHE_DIR/notify.log")" "one notice each drain" || return 1
    _deliver "$out"
    _stop true >/dev/null
    assert_eq '-msg boss -k notify queue drained: 1 task(s) done' "$(tail -n 1 "$CS_CACHE_DIR/notify.log")"
}

# Cleared at a rotation boundary, the first task done and none delivered, then
# a Stop that finds no queue.
test_clear_mid_drain_starts_a_fresh_drain() (
    local first
    printf 'boss\n' > "$QDIR/spawned-by"
    first=$(_stop)
    _deliver "$first"
    _permission >/dev/null
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=0
    _stop true >/dev/null
    rm "$QDIR/pending-handoff"
    _cs_queue clear
    assert_eq '' "$(_stop true)" "a Stop after the clear does nothing" || return 1
    _assert_fresh_drain
)

# Cleared and re-armed with the second task's delivery outstanding, and no
# Stop in between.
test_clear_and_restart_inside_one_turn() (
    local first second
    printf 'boss\n' > "$QDIR/spawned-by"
    first=$(_stop)
    _deliver "$first"
    second=$(_stop true)
    _deliver "$second"
    _permission >/dev/null
    _cs_queue clear
    _assert_fresh_drain
)

# Cleared and re-armed at a rotation boundary, with no Stop in between: the
# next bound conversation opens a new drain.
test_clear_at_a_rotation_boundary_starts_a_fresh_drain() (
    local first out
    printf 'boss\n' > "$QDIR/spawned-by"
    first=$(_stop)
    _deliver "$first"
    _permission >/dev/null
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=0
    _stop true >/dev/null
    _cs_queue clear
    mkdir -p "$QDIR/queue"
    printf 'new task\n' > "$QDIR/queue/010"
    _session_engine() { printf 'codex\n'; }     # lib/25-deps.sh is not sourced
    _cs_queue start || return 1
    rm "$QDIR/pending-handoff"
    THREAD=$OTHER TURN=$OTHER
    _rollout_under "$CODEX_HOME"
    cs_binding_write "$CS_SESSION_DIR" codex "$OTHER"
    out=$(_stop)
    assert_output_contains "$out" 'starting a walk-away run' || return 1
    assert_eq 2 "$(jq -s '[.[] | select(.event=="drain_started")]|length' "$QDIR/notifications.jsonl")" || return 1
    _permission >/dev/null
    assert_eq 2 "$(grep -c -F 'waiting for native approval' "$CS_CACHE_DIR/notify.log")" "one notice each drain" || return 1
    _deliver "$out"
    _stop true >/dev/null
    assert_eq '-msg boss -k notify queue drained: 1 task(s) done' "$(tail -n 1 "$CS_CACHE_DIR/notify.log")"
)

# queue.state is the agent's to write: re-armed mid-task, the drain still
# finishes and counts the task outstanding.
test_an_agent_written_armed_state_keeps_the_count() {
    local out n=0
    CS_CODEX_QUEUE_MAX_TASKS=2
    printf 'third task\n' > "$QDIR/queue/003"
    printf 'fourth task\n' > "$QDIR/queue/004"
    out=$(_stop)
    _deliver "$out"
    out=$(_stop true)
    assert_output_contains "$out" 'second task' || return 1
    _deliver "$out"
    printf 'armed\n' > "$QDIR/queue.state"
    out=$(_stop true)
    while [ "$n" -lt 4 ] && printf '%s\n' "$out" | jq -e '.reason | startswith("cs task queue [")' >/dev/null 2>&1; do
        _deliver "$out"
        out=$(_stop true)
        n=$((n + 1))
    done
    assert_output_contains "$out" 'task_cap at 2' || return 1
    assert_eq $'first task\nsecond task' "$(cat "$QDIR/queue.done")" "two tasks done"
}

# Written idle mid-task, the Stop finds no drain; written armed again, the
# drain finishes the task outstanding and still counts the first.
test_an_agent_idle_write_keeps_the_count() {
    local out n=0
    CS_CODEX_QUEUE_MAX_TASKS=2
    printf 'third task\n' > "$QDIR/queue/003"
    printf 'fourth task\n' > "$QDIR/queue/004"
    out=$(_stop)
    _deliver "$out"
    out=$(_stop true)
    assert_output_contains "$out" 'second task' || return 1
    _deliver "$out"
    printf 'idle\n' > "$QDIR/queue.state"
    assert_eq '' "$(_stop true)" "a Stop with no drain does nothing" || return 1
    printf 'armed\n' > "$QDIR/queue.state"
    out=$(_stop true)
    while [ "$n" -lt 4 ] && printf '%s\n' "$out" | jq -e '.reason | startswith("cs task queue [")' >/dev/null 2>&1; do
        _deliver "$out"
        out=$(_stop true)
        n=$((n + 1))
    done
    assert_output_contains "$out" 'task_cap at 2' || return 1
    assert_eq $'first task\nsecond task' "$(cat "$QDIR/queue.done")" "two tasks done"
}

# A cap park leaves the turn to the agent, which can write armed again each
# time: the run stays capped, and each re-armed Stop parks with no task more.
test_a_rearm_after_a_cap_park_stays_capped() {
    local out first="" n=0
    CS_CODEX_QUEUE_MAX_TASKS=2
    printf 'third task\n' > "$QDIR/queue/003"
    printf 'fourth task\n' > "$QDIR/queue/004"
    printf 'fifth task\n' > "$QDIR/queue/005"
    out=$(_stop)
    _deliver "$out"
    out=$(_stop true)
    _deliver "$out"
    out=$(_stop true)
    assert_output_contains "$out" 'task_cap at 2' || return 1
    printf 'armed\n' > "$QDIR/queue.state"
    while [ "$n" -lt 6 ]; do
        out=$(_stop true)
        n=$((n + 1))
        [ "$n" -gt 1 ] || first=$out
        if printf '%s\n' "$out" | jq -e '.reason | startswith("cs task queue [")' >/dev/null 2>&1; then
            _deliver "$out"
        elif printf '%s\n' "$out" | grep -qF 'task_cap at 2'; then
            printf 'armed\n' > "$QDIR/queue.state"
        fi
    done
    assert_eq 2 "$(wc -l < "$QDIR/queue.done" | tr -d ' ')" "tasks done under a cap of 2" || return 1
    assert_output_contains "$first" 'task_cap at 2' "the re-armed drain parks at its next Stop"
}

# The user's own cs -queue start, run outside the sandbox, forgets the run's
# record: the next batch starts a walk-away run and counts afresh.
test_a_user_start_resets_the_count() (
    local out
    CS_CODEX_QUEUE_MAX_TASKS=2
    printf 'third task\n' > "$QDIR/queue/003"
    printf 'fourth task\n' > "$QDIR/queue/004"
    out=$(_stop)
    _deliver "$out"
    out=$(_stop true)
    _deliver "$out"
    out=$(_stop true)
    assert_output_contains "$out" 'task_cap at 2' || return 1
    _session_engine() { printf 'codex\n'; }     # lib/25-deps.sh is not sourced
    _cs_queue start || return 1
    out=$(_stop true)
    assert_output_contains "$out" 'starting a walk-away run' || return 1
    assert_output_contains "$out" 'third task' || return 1
    _deliver "$out"
    out=$(_stop true)
    assert_output_contains "$out" 'fourth task' "the count restarted" || return 1
    _deliver "$out"
    out=$(_stop true)
    assert_output_contains "$out" 'all tasks complete' || return 1
    assert_eq 2 "$(jq -s '[.[] | select(.event=="drain_finished")][0].done' "$QDIR/notifications.jsonl")" \
        "the new drain counts only its own tasks"
)

# The lease is the agent's to rewrite: one naming the run of another session
# leaves that run's record alone.
test_clear_ignores_a_run_of_another_session() {
    local other_run=44444444-4444-4444-8444-444444444444 other_dir
    other_dir=$(CS_RUN_ID=$other_run _codex_run_dir_prepare "$CS_SESSION_DIR") || return 77
    mkdir -p "$TEST_TMPDIR/other"
    (cd -P "$TEST_TMPDIR/other" && pwd -P) > "$other_dir/session"
    printf '2\n' > "$other_dir/queue-count"
    jq -n --arg run "$other_run" --argjson owner "$$" '{run_id:$run,engine:"codex",owner_pid:$owner}' > "$QDIR/run-lease.json"
    _cs_queue clear
    assert_eq 2 "$(cat "$other_dir/queue-count" 2>/dev/null)" "the other session's count stays"
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

# The helper runs after the Stop's entry check on queue/ and before the pop.
# This one first swaps queue/ for a link to <dir>, outside the session, as a
# process the agent left running could.
_helper_swapping_queue_for() {  # dir
    cat > "$TEST_TMPDIR/helper" <<HELPER
#!/bin/bash
mv "$QDIR/queue" "$QDIR/queue.real" && ln -s "$1" "$QDIR/queue"
exec "$CS_CODEX_THREAD_BIN" "\$@"
HELPER
    chmod +x "$TEST_TMPDIR/helper"
}

test_a_queue_swapped_for_a_link_before_the_pop() {
    local first out outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    printf 'outside line\nmore\n' > "$outside/001"
    first=$(_stop)
    _deliver "$first"
    _helper_swapping_queue_for "$outside"
    out=$(CS_CODEX_THREAD_BIN="$TEST_TMPDIR/helper" _stop true)
    assert_eq $'outside line\nmore' "$(cat "$outside/001" 2>/dev/null)" "the outside file is left alone" || return 1
    assert_file_not_contains "$QDIR/queue.done" 'outside line' || return 1
    assert_output_not_contains "$out" 'all tasks complete' || return 1
    assert_output_not_contains "$out" 'second task' || return 1
    assert_output_contains "$out" 'could not update queue state'
}

# Run as a DEBUG trap: as the pop reads the task, swap queue/ for a link to
# $SWAP_OUTSIDE, as a process racing the Stop could.
_swap_queue_mid_pop() {
    case $BASH_COMMAND in *'first-line'*) ;; *) return 0 ;; esac
    [ ! -L "$QDIR/queue" ] || return 0
    mv "$QDIR/queue" "$QDIR/queue.real" && ln -s "$SWAP_OUTSIDE" "$QDIR/queue"
}

# The helper's walk refuses the swapped queue/, so the read fails and the pop
# leaves the task.
test_a_failed_read_mid_pop_never_lands_outside() {
    local first SWAP_OUTSIDE="$TEST_TMPDIR/outside"
    mkdir -p "$SWAP_OUTSIDE"
    first=$(_stop)
    _deliver "$first"
    (set -T; trap _swap_queue_mid_pop DEBUG; _stop true) >/dev/null
    assert_symlink "$QDIR/queue" "queue/ was swapped mid-pop" || return 1
    assert_eq '' "$(ls -A "$SWAP_OUTSIDE")" "nothing lands outside the session" || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.real/001" 2>/dev/null)" "the task stays in queue/"
}

# An external mv follows a destination that is a link to a directory. This mv
# first plants one where a pop renaming the task aside would land, as an agent
# racing the Stop could.
test_a_link_planted_at_pop_time_gets_nothing() (
    local first outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    first=$(_stop)
    _deliver "$first"
    mv() {
        [ -L "$QDIR/queue.popping.codex.001" ] || ln -s "$outside" "$QDIR/queue.popping.codex.001"
        command mv "$@"
    }
    _stop true >/dev/null
    assert_eq '' "$(ls -A "$outside")" "nothing lands outside the session" || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done" 2>/dev/null)" "queue.done holds the first task once"
)

# <name> in .cs/local made a hard link to <outside>/target, on the same
# filesystem: every check by path sees a regular file inside the session.
_hard_link_at() {  # name, outside
    printf 'outside\n' > "$2/target"
    rm -f "$QDIR/$1"
    ln "$2/target" "$QDIR/$1"
}

# <name> in .cs/local swapped for a link to <outside>/target once a writer has
# checked it and before it writes, as an agent racing the Stop could: from
# _cs_refuses_write, the check the shared writers make just before they write
# by path, and from the helper, just before it opens the name.
_link_flipped_after_the_check() {  # name, outside
    FLIP_NAME=$1 FLIP_TARGET="$2/target"
    printf 'outside\n' > "$FLIP_TARGET"
    _cs_refuses_write() {
        [ "$2" != "$QDIR/$FLIP_NAME" ] || [ -L "$2" ] || { rm -f "$2"; ln -s "$FLIP_TARGET" "$2"; }
        return 1
    }
    cat > "$TEST_TMPDIR/helper" <<HELPER
#!/bin/bash
case " \$* " in
    *" --queue-file append $1 "*)
        [ -L "$QDIR/$1" ] || { rm -f "$QDIR/$1"; ln -s "$FLIP_TARGET" "$QDIR/$1"; } ;;
esac
exec "$CS_CODEX_THREAD_BIN" "\$@"
HELPER
    chmod +x "$TEST_TMPDIR/helper"
    CS_CODEX_THREAD_BIN="$TEST_TMPDIR/helper"
}

test_a_hard_linked_queue_done_gets_nothing() {
    local first out outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    first=$(_stop)
    _deliver "$first"
    _hard_link_at queue.done "$outside"
    out=$(_stop true)
    assert_eq outside "$(cat "$outside/target")" "the outside file is left alone" || return 1
    assert_file_exists "$QDIR/queue/001" "the task stays queued" || return 1
    assert_output_contains "$out" 'could not update queue state'
}

test_a_link_flipped_after_the_check_gets_nothing() (
    local first out outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    first=$(_stop)
    _deliver "$first"
    _link_flipped_after_the_check queue.done "$outside"
    out=$(_stop true)
    assert_symlink "$QDIR/queue.done" "queue.done was swapped for a link" || return 1
    assert_eq outside "$(cat "$outside/target")" "the outside file is left alone" || return 1
    assert_file_exists "$QDIR/queue/001" "the task stays queued" || return 1
    assert_output_contains "$out" 'could not update queue state'
)

# The journal is best effort: a refused task_done line leaves the drain going.
test_a_hard_linked_notifications_file_gets_nothing() {
    local first out outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    first=$(_stop)
    _deliver "$first"
    _hard_link_at notifications.jsonl "$outside"
    out=$(_stop true)
    assert_eq outside "$(cat "$outside/target")" "the outside file is left alone" || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")" || return 1
    assert_output_contains "$out" 'second task'
}

test_a_notifications_link_flipped_after_the_check_gets_nothing() (
    local first out outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    first=$(_stop)
    _deliver "$first"
    _link_flipped_after_the_check notifications.jsonl "$outside"
    out=$(_stop true)
    assert_symlink "$QDIR/notifications.jsonl" "notifications.jsonl was swapped for a link" || return 1
    assert_eq outside "$(cat "$outside/target")" "the outside file is left alone" || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")" || return 1
    assert_output_contains "$out" 'second task'
)

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
    assert_eq "cs task queue: the walk-away run is waiting for this rotation. Run /clear, then send go, to continue from continue.md; the queue resumes when that turn ends." \
        "$(printf '%s\n' "$during" | jq -r .systemMessage)" "the run waits for /clear and go by hand" || return 1
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
# switch.
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
    assert_output_contains "$(cat "$CS_CACHE_DIR/notify.log")" '/clear and go' || return 1
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

# A switch held under native approval is taken by /quit or cancelled, never
# by /clear: the wait says so, and so does the spawner's notice.
test_a_held_switch_wait_does_not_say_clear() (
    local first out message
    first=$(_stop)
    _deliver "$first"
    printf 'boss\n' > "$QDIR/spawned-by"
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=20
    _live_watcher
    _codex_autoclear_action() { printf 'hold Claude\n'; }
    out=$(_stop true)
    assert_eq armed "$(cat "$QDIR/queue.state")" || return 1
    assert_not_exists "$CS_CACHE_DIR/codex-runs/$RUN/autoclear" "a held switch counts nothing down" || return 1
    message=$(printf '%s\n' "$out" | jq -r .systemMessage)
    assert_output_contains "$message" 'pending switch' || return 1
    assert_output_not_contains "$message" 'Run /clear' || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "the spawner hears of the wait" || return 1
    assert_file_contains "$CS_CACHE_DIR/notify.log" 'pending engine switch'
)

# A switch waits for /quit or cs -switch cancel whether or not a count runs:
# the wait and the spawner's notice name the switch, and nothing counts down.
_assert_switch_wait() {  # Stop output
    local message
    assert_eq armed "$(cat "$QDIR/queue.state")" || return 1
    assert_not_exists "$CS_CACHE_DIR/codex-runs/$RUN/autoclear" "nothing counts down" || return 1
    message=$(printf '%s\n' "$1" | jq -r .systemMessage)
    assert_output_contains "$message" 'pending switch' || return 1
    assert_output_not_contains "$message" 'Run /clear' || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "the spawner hears of the wait" || return 1
    assert_file_contains "$CS_CACHE_DIR/notify.log" 'pending engine switch'
}

# The automatic /clear is off, so the count never reaches the switch.
test_a_held_switch_wait_with_the_count_off_does_not_say_clear() (
    local first out
    first=$(_stop)
    _deliver "$first"
    printf 'boss\n' > "$QDIR/spawned-by"
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=0
    _live_watcher
    _codex_autoclear_action() { printf 'hold Claude\n'; }
    out=$(_stop true)
    _assert_switch_wait "$out"
)

# No watcher runs, so nothing would type the /quit the switch counts toward.
test_a_switch_wait_without_a_watcher_does_not_say_clear() (
    local first out
    first=$(_stop)
    _deliver "$first"
    printf 'boss\n' > "$QDIR/spawned-by"
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=20
    _codex_autoclear_action() { printf 'quit Claude\n'; }
    out=$(_stop true)
    _assert_switch_wait "$out"
)

# A Stop from a turn the queue never handed a task: the park is a message,
# and the armed rotation still counts down.
test_unconfirmed_park_still_counts_down_an_armed_rotation() (
    local first out message
    first=$(_stop)
    _deliver "$first"
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=20
    _live_watcher
    out=$(_stop false hi "$THREAD" "$(_alloc_uuid)")
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_file_exists "$CS_CACHE_DIR/codex-runs/$RUN/autoclear" "the armed rotation still counts down" || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | jq -s length)" "one message for the Stop" || return 1
    message=$(printf '%s\n' "$out" | jq -r .systemMessage)
    assert_output_contains "$message" 'could not confirm' || return 1
    assert_output_contains "$message" '/clear and go'
)

# A launch under a Codex older than CS_CODEX_QUEUE_MIN_VERSION leaves no
# record: that build writes no hook provenance to confirm a task by, so the
# queue parks before it hands one over.
test_an_old_codex_parks_the_queue() {
    local out
    printf 'boss\n' > "$QDIR/spawned-by"
    rm -f "$CS_CACHE_DIR/codex-runs/$RUN/queue-version-ok"
    out=$(_stop)
    assert_eq 1 "$(printf '%s\n' "$out" | jq -s length)" "one message for the Stop" || return 1
    assert_eq "cs task queue: walk-away tasks need Codex ${CS_CODEX_QUEUE_MIN_VERSION:-<unset>} or later, which records the hook provenance cs confirms each task by. Parked with 2 task(s) remaining. Re-arm with cs -queue start." \
        "$(printf '%s\n' "$out" | jq -r .systemMessage)" || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "the spawner hears of the park"
}

# An older Codex may send its Stop without a turn_id: the queue parks before
# it reads one.
test_an_old_codex_parks_without_a_turn_id() {
    local out
    printf 'boss\n' > "$QDIR/spawned-by"
    rm -f "$CS_CACHE_DIR/codex-runs/$RUN/queue-version-ok"
    out=$(jq -nc --arg s "$THREAD" --arg t "$TURN" --arg p "$ROLLOUT" \
        '{hook_event_name:"Stop",session_id:$s,turn_id:$t,transcript_path:$p,
          last_assistant_message:"finished",stop_hook_active:false} | del(.turn_id)' | cmd_codex_hook stop)
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" \
        "walk-away tasks need Codex ${CS_CODEX_QUEUE_MIN_VERSION:-<unset>} or later" || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "the spawner hears of the park"
}

test_missing_run_dir_still_saves_the_rotation_model() (
    local out
    _arm_handoff
    rm -rf "$CS_CACHE_DIR/codex-runs/$RUN"
    export CS_CODEX_ROTATION_PROFILE="$CODEX_HOME/cs-rotation-test.config.toml"
    _codex_rotation_model_save() { printf 'saved %s\n' "$2" >> "$TEST_TMPDIR/model-saves"; }
    out=$(_stop true)
    assert_eq 1 "$(wc -l < "$TEST_TMPDIR/model-saves" | tr -d ' ')" "the rotation model is saved" || return 1
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" 'private run directory is required'
)

# No private run directory, no task can be confirmed: the queue parks once,
# the spawner hears once, and later Stops find it idle.
test_a_missing_run_dir_parks_once() {
    local out
    printf 'boss\n' > "$QDIR/spawned-by"
    rm -rf "$CS_CACHE_DIR/codex-runs/$RUN"
    out=$(_stop)
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" 'private run directory is required' || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "the spawner hears of the park" || return 1
    assert_eq '' "$(_stop)" "the next Stop prints nothing" || return 1
    assert_eq '' "$(_stop)" "nor does the one after it" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "one notice a drain"
}

# A task the Stop cannot read is never handed out: the queue parks, and the
# spawner hears once.
test_an_unreadable_next_task_parks() {
    local out
    printf 'boss\n' > "$QDIR/spawned-by"
    : > "$QDIR/queue/000"
    out=$(_stop)
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" 'could not update queue state' || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "one notice" || return 1
    assert_file_contains "$CS_CACHE_DIR/notify.log" 'could not hand out'
}

# A finished task the pop refuses, here one emptied while it ran: the queue
# parks, and the spawner hears once.
test_an_unpoppable_finished_task_parks() {
    local first out
    printf 'boss\n' > "$QDIR/spawned-by"
    first=$(_stop)
    _deliver "$first"
    : > "$QDIR/queue/001"
    out=$(_stop true)
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" 'could not update queue state' || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "one notice" || return 1
    assert_file_contains "$CS_CACHE_DIR/notify.log" 'could not record its finished task'
}

# A count the Stop cannot write parks the queue the same way.
test_an_unrecorded_task_count_parks() {
    local first out
    printf 'boss\n' > "$QDIR/spawned-by"
    first=$(_stop)
    _deliver "$first"
    mkdir "$CS_CACHE_DIR/codex-runs/$RUN/queue-count"
    out=$(_stop true 2>/dev/null)
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" 'could not update queue state' || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "one notice" || return 1
    assert_file_contains "$CS_CACHE_DIR/notify.log" 'could not record its finished task'
}

# A Stop that cannot update the queue says so, and the armed rotation still
# counts down.
test_a_write_error_still_counts_down_an_armed_rotation() (
    local first out outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    first=$(_stop)
    _deliver "$first"
    _arm_handoff
    export CS_CODEX_CLEAR_GRACE=20
    _live_watcher
    _helper_swapping_queue_for "$outside"
    out=$(CS_CODEX_THREAD_BIN="$TEST_TMPDIR/helper" _stop true)
    assert_file_exists "$CS_CACHE_DIR/codex-runs/$RUN/autoclear" "the armed rotation still counts down" || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | jq -s length)" "one message for the Stop" || return 1
    assert_output_contains "$(printf '%s\n' "$out" | jq -r .systemMessage)" 'could not update queue state'
)

# Codex's history in another home: the rollout is rebuilt there as setup
# writes it.
_rollout_under() {  # codex_home
    export CODEX_HOME="$1"
    ROLLOUT="$CODEX_HOME/sessions/2026/11/20/rollout-2026-11-20T00-00-00-$THREAD.jsonl"
    mkdir -p "${ROLLOUT%/*}"
    jq -nc --arg id "$THREAD" '{type:"session_meta",payload:{id:$id}}' > "$ROLLOUT"
    _record event_msg "$(jq -nc --arg t "$TURN" '{type:"task_started",turn_id:$t}')"
}

# A refusal parks the queue, and the spawner hears once.
_assert_history_park() {  # Stop output
    assert_output_contains "$1" 'active history must be outside its writable workspace' || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_not_exists "$QDIR/queue.done" || return 1
    assert_eq idle "$(cat "$QDIR/queue.state")" || return 1
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "the spawner hears of the park"
}

test_codex_history_inside_the_session_is_refused() (
    local out
    printf 'boss\n' > "$QDIR/spawned-by"
    _rollout_under "$CS_SESSION_DIR/codex"
    out=$(_stop)
    _assert_history_park "$out"
)

test_codex_history_under_a_writable_root_is_refused() (
    local out
    printf 'boss\n' > "$QDIR/spawned-by"
    printf '[sandbox_workspace_write]\nwritable_roots = ["%s/sessions"]\n' \
        "$(cd -P "$CODEX_HOME" && pwd -P)" > "$CODEX_HOME/config.toml"
    out=$(_stop)
    _assert_history_park "$out"
)

# An encrypted session: .cs/private links into the vault, which holds the
# queue and Codex's home, spelled as cs exports it.
_vault_layout() {
    local vault="$CS_SESSION_DIR/.cs/vault-mnt/private"
    mkdir -p "$vault"
    mv "$QDIR/queue" "$QDIR/queue.state" "$vault/"
    ln -s vault-mnt/private "$CS_SESSION_DIR/.cs/private"
    QDIR="$CS_SESSION_DIR/.cs/private"
    _rollout_under "$(_codex_vault_home_path "$CS_SESSION_DIR")"
}

# On macOS the agent can move the vault's Codex home out from under cs's
# read-only rule and rewrite the history a task is confirmed by: an armed
# queue in an encrypted session hands out nothing and writes no queue state,
# and the spawner hears once a run.
test_an_encrypted_session_hands_out_no_task() (
    local out reason
    reason="cs task queue: an encrypted session cannot host a Codex walk-away queue, so cs hands out no tasks here. The queued tasks are still available; run them under Claude, or move them to an unencrypted session."
    printf 'boss\n' > "$CS_SESSION_DIR/.cs/local/spawned-by"
    _vault_layout
    out=$(_stop)
    assert_eq "$reason" "$(printf '%s\n' "$out" | jq -r .systemMessage)" || return 1
    assert_file_exists "$QDIR/queue/001" || return 1
    assert_eq armed "$(cat "$QDIR/queue.state")" "no queue state is written" || return 1
    assert_not_exists "$QDIR/queue.current" || return 1
    out=$(_stop)
    assert_eq "$reason" "$(printf '%s\n' "$out" | jq -r .systemMessage)" "every Stop says so" || return 1
    assert_eq "-msg boss -k notify $reason" "$(cat "$CS_CACHE_DIR/notify.log")" "the spawner hears once a run"
)

run_test test_drains_and_notifies_once
run_test test_unbound_and_undelivered_tasks_cannot_complete
run_test test_reported_failure_keeps_the_task
run_test test_shell_and_patch_failures_count_from_this_task_only
run_test test_large_task_output_keeps_the_receipt
run_test test_large_task_output_still_delivers_the_next_task
run_test test_missing_or_expired_usage_uses_the_cap
run_test test_fresh_quota_trips_and_context_uses_the_latest_reading
run_test test_a_later_reading_of_another_limit_keeps_the_quota
run_test test_a_later_empty_reading_keeps_the_context
run_test test_native_approval_notifies_once_without_deciding
run_test test_subagent_approval_notifies_once
run_test test_clear_mid_drain_starts_a_fresh_drain
run_test test_clear_and_restart_inside_one_turn
run_test test_clear_at_a_rotation_boundary_starts_a_fresh_drain
run_test test_an_agent_written_armed_state_keeps_the_count
run_test test_an_agent_idle_write_keeps_the_count
run_test test_a_rearm_after_a_cap_park_stays_capped
run_test test_a_user_start_resets_the_count
run_test test_clear_ignores_a_run_of_another_session
run_test test_receipt_without_a_new_final_answer_parks
run_test test_torn_rollout_tail_leaves_the_last_complete_context_reading
run_test test_a_queue_swapped_for_a_link_before_the_pop
run_test test_a_failed_read_mid_pop_never_lands_outside
run_test test_a_link_planted_at_pop_time_gets_nothing
run_test test_a_hard_linked_queue_done_gets_nothing
run_test test_a_link_flipped_after_the_check_gets_nothing
run_test test_a_hard_linked_notifications_file_gets_nothing
run_test test_a_notifications_link_flipped_after_the_check_gets_nothing
run_test test_rotation_commits_the_boundary_then_resumes_the_next_task
run_test test_rotation_without_a_countdown_notifies_the_spawner
run_test test_rotation_with_a_live_watcher_does_not_notify
run_test test_a_held_switch_wait_does_not_say_clear
run_test test_a_held_switch_wait_with_the_count_off_does_not_say_clear
run_test test_a_switch_wait_without_a_watcher_does_not_say_clear
run_test test_unconfirmed_park_still_counts_down_an_armed_rotation
run_test test_an_old_codex_parks_the_queue
run_test test_an_old_codex_parks_without_a_turn_id
run_test test_missing_run_dir_still_saves_the_rotation_model
run_test test_a_missing_run_dir_parks_once
run_test test_an_unreadable_next_task_parks
run_test test_an_unpoppable_finished_task_parks
run_test test_an_unrecorded_task_count_parks
run_test test_a_write_error_still_counts_down_an_armed_rotation
run_test test_codex_history_inside_the_session_is_refused
run_test test_codex_history_under_a_writable_root_is_refused
run_test test_an_encrypted_session_hands_out_no_task
report_results
