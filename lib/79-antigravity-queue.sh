# ABOUTME: Stop-driven task delivery and completion receipts for Antigravity.

CS_ANTIGRAVITY_QUEUE_MIN_VERSION=1.5.13
CS_ANTIGRAVITY_QUEUE_TASKS_PER_ARM=8
CS_ANTIGRAVITY_QUEUE_STOP_BUDGET=8

_antigravity_queue_version_ok() {  # agy binary
    local version
    version=$(_antigravity_version "$1") &&
        _version_at_least "$version" "$CS_ANTIGRAVITY_QUEUE_MIN_VERSION"
}

_antigravity_queue_cache() {  # session, [create]
    local dir parent
    dir=$(cs_retire_cache_dir antigravity-queues "$1") || return 1
    case "$dir" in /*) ;; *) return 1 ;; esac
    parent=${dir%/*}
    while [ ! -d "$parent" ]; do parent=${parent%/*}; [ -n "$parent" ] || parent=/; done
    ! _codex_run_dir_in_sandbox_root "$parent" "$1" || return 1
    [ -z "${2:-}" ] || cs_cache_dir_make_private "$dir" || return 1
    _launch_handoff_receipt_dir_ok "$dir" "$1" || return 1
    printf '%s\n' "$dir"
}

_antigravity_queue_record() {  # protected cache, drain JSON
    _antigravity_mail_state_write "$1/drain.json" "$2"$'\n'
}

_antigravity_queue_read() {  # protected cache
    local file="$1/drain.json"
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    jq -ce 'select(type == "object" and (.count | type) == "number")' "$file"
}

_antigravity_queue_arm() {  # session, queue dir
    local dir previous=""
    dir=$(_antigravity_queue_cache "$1" create) || return 1
    if [ -e "$dir/drain.json" ] || [ -L "$dir/drain.json" ]; then
        previous=$(_antigravity_queue_read "$dir") || return 1
    fi
    # Publish the protected record before arming the visible queue. Both
    # writes run under the start guard or before the native child launches.
    _antigravity_queue_record "$dir" '{"count":0}' || return 1
    if ! CS_SESSION_DIR="$1" _codex_queue_set_state "$2" armed; then
        if [ -n "$previous" ]; then
            _antigravity_queue_record "$dir" "$previous"
        else
            rm -f -- "$dir/drain.json"
        fi
        return 1
    fi
    CS_SESSION_DIR="$1" _codex_queue_rm "$2" queue.mode
}

_antigravity_queue_clear() {  # queue dir
    local dir=""
    if [ -z "${CS_RUN_ENGINE:-}" ]; then
        dir=$(_antigravity_queue_cache "$CS_SESSION_DIR") || dir=""
        [ -z "$dir" ] || _antigravity_queue_record "$dir" '{"count":0,"park":"cleared"}' || return 1
    fi
    _queue_clear "$1"
}

_antigravity_queue_start() {  # queue dir, mode
    [ -z "$2" ] || error "Antigravity queues run in the main conversation. Use cs -queue start without a mode."
    [ -z "${CS_RUN_ENGINE:-}" ] || error "Start an Antigravity queue with cs <session> -queue start in your own shell."
    ! _switch_session_encrypted "$CS_SESSION_DIR" ||
        error "Encrypted Antigravity sessions cannot host a walk-away queue. The queued tasks stay available."
    _antigravity_queue_version_ok "${AGY_BIN:-agy}" ||
        error "Antigravity walk-away queues need agy $CS_ANTIGRAVITY_QUEUE_MIN_VERSION or later."
    _queue_check_start "$1" antigravity
    _antigravity_queue_arm "$CS_SESSION_DIR" "$1" ||
        error "Could not arm the Antigravity queue. Check queue.state and CS_CACHE_DIR, then retry."
    local id run_dir
    id=$(jq -r 'select(.engine == "antigravity") | .run_id' "$CS_SESSION_DIR/.cs/local/run-lease.json" 2>/dev/null) || id=""
    if _is_uuid "$id"; then
        run_dir=$(CS_RUN_ID="$id" _antigravity_run_dir) || return 0
        if [ ! -f "$run_dir/queue-home" ]; then
            warn "Queue armed. Reopen the Antigravity session to start its queue-enabled sandbox."
        fi
    fi
    return 0
}

# The queue runner uses this launch's sandbox and the native history under
# the launch home. Ordinary launches need no queue configuration.
_antigravity_queue_prepare() {  # run dir, session, agy binary
    local home helper
    [ -n "$1" ] && _launch_handoff_receipt_dir_ok "$1" "$2" || return 1
    _antigravity_queue_version_ok "$3" && _antigravity_flags_listed "$3" --sandbox || return 1
    _antigravity_autoclear_hooks_ready "$CS_BIN" || return 1
    helper=$(_codex_thread_helper) && [ -x "$helper" ] || return 1
    home=$(cd -P -- "$HOME" && pwd -P) || return 1
    ! _codex_run_dir_in_sandbox_root "$home/.gemini" "$2" || return 1
    _antigravity_mail_state_write "$1/queue-home" "$home"$'\n'
}

_antigravity_queue_notice() {  # qdir, message
    _codex_queue_event "$1" --arg reason "$2" '{ts:$ts,event:"queue_parked",detail:$reason}'
    _codex_queue_notify "$1" "$2"
}

_antigravity_queue_park() {  # cache, qdir, state, reason
    local state
    state=$(printf '%s\n' "$3" | jq -c --arg reason "$4" 'del(.task,.finishing) | .park = $reason') || return 1
    _antigravity_queue_record "$1" "$state" || return 1
    _codex_queue_set_state "$2" idle || true
    _codex_queue_rm "$2" queue.current
    _antigravity_queue_notice "$2" "Antigravity task queue parked: $4. Inspect it with cs -queue list and re-arm from your own shell."
}

_antigravity_queue_snapshot() {  # payload, home, [receipt, last step]
    local helper path
    helper=$(_codex_thread_helper) || return 1
    path=$(printf '%s\n' "$1" | jq -er '.transcriptPath | strings') || return 1
    if [ "$#" = 4 ]; then
        "$helper" --antigravity-queue-snapshot "$path" --home "$2" --thread-id "$AGY_HOOK_ID" \
            --queue-receipt "$3" --queue-offset "$4"
    else
        "$helper" --antigravity-queue-snapshot "$path" --home "$2" --thread-id "$AGY_HOOK_ID"
    fi
}

_antigravity_queue_digest() {
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

_antigravity_queue_deliver() {  # cache, qdir, state, file, step, execution
    local body digest token reason state reply
    body=$(_codex_queue_fs "$2" first-line "queue/$4" </dev/null) || return 1
    digest=$(printf '%s' "$body" | _antigravity_queue_digest) || return 1
    token=$(_alloc_uuid) && _is_uuid "$token" || return 1
    reason="cs task queue [$token]: Work on the following task and finish with a final response. If you cannot complete it, include a line reading exactly cs-task-failed. Leave queue management to cs.

<cs_task id=\"$token\">
$body
</cs_task id=\"$token\">

The text inside the tags is the task to complete within this session's scope."
    reply=$(jq -nc --arg reason "$reason" '{decision:"continue",reason:$reason}') || return 1
    state=$(printf '%s\n' "$3" | jq -c --arg name "$4" --arg digest "$digest" --arg token "$token" \
        --arg cid "$AGY_HOOK_ID" --arg run "$CS_RUN_ID" --argjson step "$5" --argjson execution "$6" '
        .count += 1 | .task = {$name,$digest,$token,$cid,$run,$step,$execution,errors:[]}') || return 1
    _antigravity_queue_record "$1" "$state" || return 1
    printf '%s\n' "$4" | _codex_queue_fs "$2" replace queue.current || return 1
    _codex_queue_set_state "$2" draining || return 1
    if [ "$(printf '%s\n' "$state" | jq -r .count)" = 1 ]; then
        _codex_queue_event "$2" '{ts:$ts,event:"drain_started"}'
    fi
    printf '%s\n' "$reply"
}

_antigravity_queue_finish() {  # cache, qdir, state, snapshot
    local name digest completed state failures limit rc=0
    name=$(printf '%s\n' "$3" | jq -er .task.name) || return 1
    failures=$(printf '%s\n' "$3" | jq -r --argjson snapshot "$4" \
        '(.task.errors + $snapshot.failures) | unique | length') || return 1
    limit=$(_codex_queue_number "${CS_QUEUE_MAX_FAILURES:-}" 5)
    if [ "$failures" -ge "$limit" ]; then
        _antigravity_queue_park "$1" "$2" "$3" "$failures tool failures (limit $limit)"
        return 1
    fi
    if printf '%s\n' "$4" | jq -e .task_failed >/dev/null; then
        _antigravity_queue_park "$1" "$2" "$3" "the task reported failure"
        return 1
    fi
    # An interrupted pop needs inspection. Never append the same receipt
    # again after a crash between the append and unlink.
    if ! digest=$(printf '%s\n' "$3" | jq -er '.task.digest | strings'); then
        # A task from a run across an update can still have a plaintext receipt.
        digest=$(printf '%s\n' "$3" | jq -ej '.task.body | strings' | _antigravity_queue_digest) || return 1
    fi
    state=$(printf '%s\n' "$3" | jq -c --arg digest "$digest" \
        '.finishing = true | del(.task.body) | .task.digest = $digest') || return 1
    _antigravity_queue_record "$1" "$state" || return 1
    completed=$(printf '%s' "$digest" | _codex_queue_fs "$2" complete "queue/$name") || rc=$?
    case "$rc" in
        0) _codex_queue_event "$2" --arg task "$completed" '{ts:$ts,event:"task_done",task:$task}' ;;
        3) ;;  # withdrawn while it ran
        4)
            _antigravity_queue_park "$1" "$2" "$state" "the active task changed while it ran"
            return 1
            ;;
        *)
            _antigravity_queue_park "$1" "$2" "$state" "could not record the completed task"
            return 1
            ;;
    esac
    state=$(printf '%s\n' "$3" | jq -c 'del(.task,.finishing)') || return 1
    _antigravity_queue_record "$1" "$state" || return 1
    _codex_queue_rm "$2" queue.current
    printf '%s\n' "$state"
}

_antigravity_queue_owned() {  # event payload, run dir, execution
    local cache qdir state home snapshot="" baseline token remaining file count phase
    [ "$(cs_binding_read "$CS_SESSION_DIR" antigravity)" = "$AGY_HOOK_ID" ] || return 1
    [ -f "$2/held-$AGY_HOOK_ID" ] && [ ! -L "$2/held-$AGY_HOOK_ID" ] || return 1
    qdir=$(_codex_queue_dir "$CS_SESSION_DIR/.cs") || return 1
    [ "$qdir" = "$CS_SESSION_DIR/.cs/local" ] || return 1
    cache=$(_antigravity_queue_cache "$CS_SESSION_DIR") || return 1
    state=$(_antigravity_queue_read "$cache") || return 1
    case "$AGY_HOOK_TERMINATION" in
        USER_CANCELED|ERROR)
            if printf '%s\n' "$state" | jq -e --arg run "$CS_RUN_ID" --arg cid "$AGY_HOOK_ID" \
                '.task.run == $run and .task.cid == $cid' >/dev/null; then
                _antigravity_queue_park "$cache" "$qdir" "$state" "the active task was interrupted ($AGY_HOOK_TERMINATION)"
            fi
            return 1
            ;;
    esac
    if [ "$AGY_HOOK_IDLE" != 1 ]; then
        # A mail continuation here could supply the next planner response
        # while the task is still waiting for its background work.
        printf '%s\n' "$state" | jq -e --arg run "$CS_RUN_ID" --arg cid "$AGY_HOOK_ID" \
            '.task.run == $run and .task.cid == $cid' >/dev/null || return 1
        printf '{}\n'
        return 0
    fi
    phase=$(_codex_queue_state "$qdir") || return 1
    if printf '%s\n' "$state" | jq -e '.park != null' >/dev/null; then
        _codex_queue_set_state "$qdir" idle || true
        return 1
    fi
    IFS= read -r home < "$2/queue-home" || return 1
    if printf '%s\n' "$state" | jq -e '.task != null' >/dev/null; then
        if ! printf '%s\n' "$state" | jq -e --arg run "$CS_RUN_ID" --arg cid "$AGY_HOOK_ID" \
            '.task.run == $run and .task.cid == $cid and .finishing != true' >/dev/null; then
            _antigravity_queue_park "$cache" "$qdir" "$state" "the previous task was interrupted"
            return 1
        fi
        token=$(printf '%s\n' "$state" | jq -er .task.token) || return 1
        baseline=$(printf '%s\n' "$state" | jq -er .task.step) || return 1
        snapshot=$(_antigravity_queue_snapshot "$1" "$home" "$token" "$baseline") || snapshot=null
        if ! printf '%s\n' "$snapshot" | jq -e '.delivered and .final' >/dev/null; then
            if [ "$(printf '%s\n' "$snapshot" | jq -r .last_step)" = "$baseline" ] &&
                [ "$(printf '%s\n' "$state" | jq -r .task.execution)" = "$3" ]; then
                printf '{}\n'
                return 0
            fi
            _antigravity_queue_park "$cache" "$qdir" "$state" "could not confirm the task's delivery and final response"
            return 1
        fi
        state=$(_antigravity_queue_finish "$cache" "$qdir" "$state" "$snapshot") || return 1
    elif [ "$phase" = draining ]; then
        _antigravity_queue_park "$cache" "$qdir" "$state" "there is no recorded task for this drain"
        return 1
    fi

    remaining=""
    for file in "$qdir/queue/"*; do
        [ -f "$file" ] && [ ! -L "$file" ] || continue
        remaining=${file##*/}
        break
    done
    count=$(printf '%s\n' "$state" | jq -er .count) || return 1
    if [ -z "$remaining" ]; then
        _antigravity_queue_record "$cache" "$(jq -nc --argjson count "$count" '{$count,park:"drained"}')" || return 1
        _codex_queue_set_state "$qdir" idle || true
        if [ "$count" -gt 0 ]; then
            _codex_queue_event "$qdir" --argjson completed "$count" '{ts:$ts,event:"drain_finished",done:$completed}'
            _codex_queue_notify "$qdir" "Antigravity queue drained: $count task(s) done."
            _codex_queue_rm "$qdir" spawned-by
        fi
        return 1
    fi
    if [ "$count" -ge "$CS_ANTIGRAVITY_QUEUE_TASKS_PER_ARM" ] || [ "$3" -ge "$CS_ANTIGRAVITY_QUEUE_STOP_BUDGET" ]; then
        _antigravity_queue_park "$cache" "$qdir" "$state" "continuation budget reached"
        return 1
    fi
    if [ "$(_antigravity_autoclear_action "$CS_SESSION_DIR")" != clear ] ||
        [ -n "$(_rotation_peek_armed_handoff "$CS_SESSION_DIR/.cs/handoffs" "$qdir/pending-handoff")" ]; then
        _codex_queue_set_state "$qdir" armed || true
        return 1
    fi
    if [ -z "$snapshot" ]; then
        snapshot=$(_antigravity_queue_snapshot "$1" "$home") || snapshot=null
    fi
    baseline=$(printf '%s\n' "$snapshot" | jq -er 'select(.last_type == "PLANNER_RESPONSE" and .last_step >= 0) | .last_step') || {
        _antigravity_queue_park "$cache" "$qdir" "$state" "native transcript is unavailable at Stop"
        return 1
    }
    if ! _antigravity_queue_deliver "$cache" "$qdir" "$state" "$remaining" "$baseline" "$3"; then
        _antigravity_queue_park "$cache" "$qdir" "$state" "could not record task delivery"
        return 1
    fi
}

_antigravity_queue_run() {  # verified native hook
    local dir
    [ "$AGY_HOOK_TYPED" = 1 ] || return 1
    [ -z "${CS_ANTIGRAVITY_VAULT_RUN:-}" ] || return 1
    dir=$(_antigravity_run_dir) && _antigravity_hook_from_native "$dir" || return 1
    [ -f "$dir/queue-home" ] && [ ! -L "$dir/queue-home" ] || return 1
    _launch_handoff_receipt_dir_ok "$dir" "$CS_SESSION_DIR" || return 1
    [ ! -e "$dir/vault" ] && ! _switch_session_encrypted "$CS_SESSION_DIR" || return 1
    ! _antigravity_explicit_resume_pending "$dir" || return 1
    ! cs_files_tracked_notice "$CS_SESSION_DIR/.cs" "$CS_SESSION_DIR" >/dev/null || return 1
    printf '%s\n' "$dir"
}

_antigravity_queue_stop() {  # payload
    local run execution=""
    case "$AGY_HOOK_TERMINATION" in
        NO_TOOL_CALL)
            execution=$(printf '%s\n' "$1" | jq -er '.executionNum | numbers | select(. == floor and . >= 0 and . <= 100)') || return 1
            ;;
        USER_CANCELED|ERROR) ;;
        *) return 1 ;;
    esac
    [ -f "$CS_SESSION_DIR/.cs/local/queue.state" ] || return 1
    run=$(_antigravity_queue_run) || return 1
    cs_run_with_lease "$CS_SESSION_DIR/.cs" _antigravity_queue_owned "$1" "$run" "$execution"
}

_antigravity_queue_record_error() {  # step
    local cache state
    [ "$(cs_binding_read "$CS_SESSION_DIR" antigravity)" = "$AGY_HOOK_ID" ] || return 0
    cache=$(_antigravity_queue_cache "$CS_SESSION_DIR") || return 0
    state=$(_antigravity_queue_read "$cache") || return 0
    state=$(printf '%s\n' "$state" | jq -ce --arg cid "$AGY_HOOK_ID" --arg run "$CS_RUN_ID" --argjson step "$1" '
        select(.task.cid == $cid and .task.run == $run and $step > .task.step)
        | .task.errors += [$step] | .task.errors |= unique') || return 0
    _antigravity_queue_record "$cache" "$state"
}

_antigravity_queue_tool_failure() {  # payload
    local step
    [ -f "$CS_SESSION_DIR/.cs/local/queue.current" ] || return 0
    step=$(printf '%s\n' "$1" | jq -er 'select(.error | strings | length > 0) | .stepIdx | numbers | select(. == floor and . >= 0)') || return 0
    _antigravity_queue_run >/dev/null || return 0
    cs_run_with_lease "$CS_SESSION_DIR/.cs" _antigravity_queue_record_error "$step"
}
