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

_permission() {
    jq -nc --arg s "$THREAD" --arg t "$TURN" '{session_id:$s,turn_id:$t}' | cmd_codex_hook permission-request
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

# Cleared at a rotation boundary, the first task done and none delivered: the
# Stop that finds no queue ends the drain.
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
    _queue_clear "$QDIR"
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
    _queue_clear "$QDIR"
    _assert_fresh_drain
)

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

# Run as a DEBUG trap: once the pop has moved the task out of queue/, swap
# queue/ for a link to $SWAP_OUTSIDE, as a process racing the Stop could.
_swap_queue_mid_pop() {
    [ -e "$QDIR/queue.popping.codex.001" ] && [ ! -L "$QDIR/queue" ] || return 0
    mv "$QDIR/queue" "$QDIR/queue.real" && ln -s "$SWAP_OUTSIDE" "$QDIR/queue"
}

# A task with no trailing newline fails the read, so the pop puts it back.
test_the_take_back_never_lands_outside() {
    local first SWAP_OUTSIDE="$TEST_TMPDIR/outside"
    mkdir -p "$SWAP_OUTSIDE"
    first=$(_stop)
    _deliver "$first"
    printf 'first task' > "$QDIR/queue/001"
    (set -T; trap _swap_queue_mid_pop DEBUG; _stop true) >/dev/null
    assert_symlink "$QDIR/queue" "queue/ was swapped mid-pop" || return 1
    assert_eq '' "$(ls -A "$SWAP_OUTSIDE")" "nothing lands outside the session" || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.real/001" 2>/dev/null)" "the task is put back"
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
# queue and, unless another is named, Codex's home.
_vault_layout() {  # [codex_home]
    local vault="$CS_SESSION_DIR/.cs/vault-mnt/private"
    mkdir -p "$vault"
    mv "$QDIR/queue" "$QDIR/queue.state" "$vault/"
    ln -s vault-mnt/private "$CS_SESSION_DIR/.cs/private"
    QDIR="$CS_SESSION_DIR/.cs/private"
    _rollout_under "${1:-$vault/codex-home}"
}

# The record a launch leaves in the run directory when cs's permissions
# profile keeps the vault home read-only to the agent.
_vault_record() {  # home
    local home
    home=$(cd -P "$1" && pwd -P)
    printf '%s\n' "$home" "$(cs_dir_identity "${home%/*}")" > "$CS_CACHE_DIR/codex-runs/$RUN/vault-home"
}

test_an_encrypted_vault_home_drains() (
    local first second
    _vault_layout
    _vault_record "$CODEX_HOME"
    first=$(_stop)
    assert_output_contains "$first" 'first task' || return 1
    _deliver "$first"
    second=$(_stop true)
    assert_output_contains "$second" 'second task' || return 1
    assert_eq 'first task' "$(cat "$QDIR/queue.done")"
)

test_an_unrecorded_vault_home_parks_once() (
    local out
    printf 'boss\n' > "$CS_SESSION_DIR/.cs/local/spawned-by"
    _vault_layout
    out=$(_stop)
    _assert_history_park "$out" || return 1
    _stop >/dev/null
    assert_eq 1 "$(wc -l < "$CS_CACHE_DIR/notify.log" | tr -d ' ')" "one notice a drain"
)

test_a_vault_record_for_another_home_is_refused() (
    local out
    printf 'boss\n' > "$CS_SESSION_DIR/.cs/local/spawned-by"
    mkdir -p "$CS_SESSION_DIR/fake-home"
    _vault_layout "$CS_SESSION_DIR/fake-home"
    _vault_record "$CODEX_HOME"
    out=$(_stop)
    _assert_history_park "$out"
)

run_test test_drains_and_notifies_once
run_test test_unbound_and_undelivered_tasks_cannot_complete
run_test test_reported_failure_keeps_the_task
run_test test_shell_and_patch_failures_count_from_this_task_only
run_test test_missing_or_expired_usage_uses_the_cap
run_test test_fresh_quota_trips_and_context_uses_the_latest_reading
run_test test_native_approval_notifies_once_without_deciding
run_test test_clear_mid_drain_starts_a_fresh_drain
run_test test_clear_and_restart_inside_one_turn
run_test test_receipt_without_a_new_final_answer_parks
run_test test_torn_rollout_tail_leaves_the_last_complete_context_reading
run_test test_a_queue_swapped_for_a_link_before_the_pop
run_test test_the_take_back_never_lands_outside
run_test test_rotation_commits_the_boundary_then_resumes_the_next_task
run_test test_rotation_without_a_countdown_notifies_the_spawner
run_test test_rotation_with_a_live_watcher_does_not_notify
run_test test_unconfirmed_park_still_counts_down_an_armed_rotation
run_test test_missing_run_dir_still_saves_the_rotation_model
run_test test_codex_history_inside_the_session_is_refused
run_test test_codex_history_under_a_writable_root_is_refused
run_test test_an_encrypted_vault_home_drains
run_test test_an_unrecorded_vault_home_parks_once
run_test test_a_vault_record_for_another_home_is_refused
report_results
