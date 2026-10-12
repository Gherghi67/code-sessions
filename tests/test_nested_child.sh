#!/usr/bin/env bash
# ABOUTME: Tests for a claude started from inside a cs session that is not the lead
# ABOUTME: Such a child inherits the launch contract; its hooks must act as a guest, not the owner

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

_nested_setup() {
    setup
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/nested"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_SESSION_NAME="nested"
    mkdir -p "$CLAUDE_SESSION_META_DIR/memory" "$CLAUDE_SESSION_META_DIR/local"
    # A narrative older than the reminder's cooldown, so the lead WOULD be
    # reminded: that is what makes the child's silence a measurement.
    printf '# narrative\n' > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    touch -t 202601010000 "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    unset CS_RESOLVED_FROM 2>/dev/null || true
}

_stop_hook() {  # CS_LEAD_PID CLAUDE_PID
    printf '{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}' \
        | CS_RESOLVED_FROM=env CS_LEAD_PID="$1" CLAUDE_PID="$2" bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null
}

# Positive control: the lead is reminded, so the fixture reaches the block.
test_the_lead_gets_the_narrative_reminder() {
    _nested_setup
    local out
    out=$(_stop_hook "$$" "$$")
    assert_output_contains "$out" '"decision":"block"' "the lead is reminded on a stale narrative" || return 1
}

# A `claude -p` the lead's Bash tool ran inherits the contract; it is not the
# lead (its pid is neither the launch nor the launch's child) and must not be
# told to write the lead's narrative, nor spend the lead's cooldown.
test_a_nested_child_is_not_reminded() {
    _nested_setup
    sleep 300 &
    local lead=$!
    local out
    out=$(_stop_hook "$lead" "$$")
    kill "$lead" 2>/dev/null
    assert_eq '{"decision": "approve"}' "$out" "a nested child's Stop passes silently" || return 1
    assert_not_exists "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
        "the child must not spend the lead's reminder cooldown" || return 1
}

# The attention flag tells the status line the lead's turn has ended and the
# user is awaited. A child finishing in the middle of the lead's turn ends no
# turn of the lead's. The lead's own Stop is the positive control.
test_a_nested_child_does_not_raise_the_attention_flag() {
    _nested_setup
    sleep 300 &
    local lead=$!
    _stop_hook "$lead" "$$" > /dev/null
    kill "$lead" 2>/dev/null
    assert_not_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "a nested child's Stop leaves the attention flag down" || return 1
    _stop_hook "$$" "$$" > /dev/null
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "the lead's Stop raises the attention flag" || return 1
}

_start_hook() {  # CS_LEAD_PID CLAUDE_PID source session_id; prints the context Claude is given
    printf '{"session_id":"%s","source":"%s","cwd":"%s","hook_event_name":"SessionStart"}\n' \
        "$4" "$3" "$CLAUDE_SESSION_DIR" \
        | CS_RESOLVED_FROM=env CS_LEAD_PID="$1" CLAUDE_PID="$2" CS_NO_ROTATION_WAKE=1 CS_NO_ITERM2=1 \
            bash "$HOOKS_DIR/session-start.sh" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext'
}

# The lead wrote a handoff and armed the marker; its /clear has not come yet.
# A child started in that window fires SessionStart with source startup. The
# rotation is the lead's: the child must not be handed it, flip the handoff to
# consumed under its own id, or drop the marker. The lead's /clear afterwards
# is the positive control: the rotation is still there to load.
test_a_nested_child_leaves_the_armed_rotation_to_the_lead() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" handoff out
    handoff="$meta/handoffs/2026-01-01-topic.md"
    mkdir -p "$meta/handoffs"
    printf -- '---\nstatus: unconsumed\n---\nnext step: do the thing\n' > "$handoff"
    printf '2026-01-01-topic.md\n' > "$meta/local/pending-handoff"
    sleep 300 &
    local lead=$!
    out=$(_start_hook "$lead" "$$" startup 22222222-2222-4222-8222-222222222222)
    kill "$lead" 2>/dev/null
    assert_eq "0" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "a nested child is not told to continue the rotation" || return 1
    assert_eq "2026-01-01-topic.md" "$(cat "$meta/local/pending-handoff" 2>/dev/null)" \
        "the marker stays armed after a nested child starts" || return 1
    assert_eq "status: unconsumed" "$(sed -n 2p "$handoff")" \
        "the handoff stays unconsumed after a nested child starts" || return 1

    out=$(_start_hook "$$" "$$" clear 33333333-3333-4333-8333-333333333333)
    assert_eq "1" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "the lead's /clear loads the rotation" || return 1
    assert_eq "consumed_by: 33333333-3333-4333-8333-333333333333" "$(sed -n 3p "$handoff")" \
        "the lead's conversation is the one recorded as the consumer" || return 1
}

# The queue's digest is shown once, to whoever reads it first. A child that
# starts before the lead must neither be shown it nor move the cursor.
test_a_nested_child_leaves_the_queue_digest_to_the_lead() {
    _nested_setup
    local local_dir="$CLAUDE_SESSION_META_DIR/local" out
    printf '{"ts":1,"event":"task_done","task":"t"}\n{"ts":2,"event":"drain_finished"}\n' \
        > "$local_dir/notifications.jsonl"
    sleep 300 &
    local lead=$!
    out=$(_start_hook "$lead" "$$" startup 22222222-2222-4222-8222-222222222222)
    kill "$lead" 2>/dev/null
    assert_eq "0" "$(grep -c 'cs queue while you were away' <<< "$out")" \
        "a nested child is not shown the queue digest" || return 1
    assert_not_exists "$local_dir/notifications.seen" \
        "a nested child does not move the digest cursor" || return 1

    out=$(_start_hook "$$" "$$" resume 33333333-3333-4333-8333-333333333333)
    assert_eq "1" "$(grep -c 'cs queue while you were away' <<< "$out")" \
        "the lead is shown the digest afterwards" || return 1
    assert_eq "2" "$(tr -d '[:space:]' < "$local_dir/notifications.seen")" \
        "the lead's start moves the cursor past both entries" || return 1
}

run_test test_the_lead_gets_the_narrative_reminder
run_test test_a_nested_child_is_not_reminded
run_test test_a_nested_child_does_not_raise_the_attention_flag
run_test test_a_nested_child_leaves_the_armed_rotation_to_the_lead
run_test test_a_nested_child_leaves_the_queue_digest_to_the_lead

report_results
