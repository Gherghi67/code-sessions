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

# A stand-in for a claude process: its command line carries whatever the test
# passes, and a kill takes its sleep down with it, so nothing outlives a test.
_fake_claude_script() {
    printf '#!/usr/bin/env bash\nsleep 300 &\ntrap "kill $!" TERM\nwait\n' > "$TEST_TMPDIR/fake-claude.sh"
    chmod +x "$TEST_TMPDIR/fake-claude.sh"
}

# A rotation the lead armed and has not cleared into yet: an unconsumed
# handoff and the marker that names it. Prints the handoff's path.
_arm_rotation() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/handoffs"
    printf -- '---\nstatus: unconsumed\n---\nnext step: do the thing\n' > "$meta/handoffs/2026-01-01-topic.md"
    printf '2026-01-01-topic.md\n' > "$meta/local/pending-handoff"
    printf '%s\n' "$meta/handoffs/2026-01-01-topic.md"
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
    handoff=$(_arm_rotation)
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

# A tmux teammate is a full claude with its own SessionStart and no launch pid
# in its environment, so it is neither the lead nor a nested child; Claude
# Code's three teammate flags are what name it. A front end that walked in
# has no launch pid either and none of the flags: its /clear still loads the
# rotation, which is the positive control.
test_a_teammate_leaves_the_armed_rotation_and_the_digest_to_the_lead() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" handoff out mate i=0
    handoff=$(_arm_rotation)
    printf '{"ts":1,"event":"task_done","task":"t"}\n' > "$meta/local/notifications.jsonl"
    _fake_claude_script
    "$TEST_TMPDIR/fake-claude.sh" --agent-id a1 --agent-name mate --team-name t >/dev/null 2>&1 &
    mate=$!
    while [ "$i" -lt 50 ]; do
        ps -o args= -p "$mate" 2>/dev/null | grep -q fake-claude && break
        i=$((i + 1)); sleep 0.1
    done
    out=$(_start_hook "" "$mate" startup 22222222-2222-4222-8222-222222222222)
    kill "$mate" 2>/dev/null
    assert_eq "0" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "a teammate is not told to continue the rotation" || return 1
    assert_eq "status: unconsumed" "$(sed -n 2p "$handoff")" \
        "the handoff stays unconsumed after a teammate starts" || return 1
    assert_eq "2026-01-01-topic.md" "$(cat "$meta/local/pending-handoff" 2>/dev/null)" \
        "the marker stays armed after a teammate starts" || return 1
    assert_eq "0" "$(grep -c 'cs queue while you were away' <<< "$out")" \
        "a teammate is not shown the queue digest" || return 1
    assert_not_exists "$meta/local/notifications.seen" \
        "a teammate does not move the digest cursor" || return 1

    out=$(_start_hook "" "$$" clear 33333333-3333-4333-8333-333333333333)
    assert_eq "1" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "a front end with no launch pid still loads the rotation on /clear" || return 1
}

# cs passes a launch prompt to claude as an argument, so the lead's own
# command line can hold the three teammate flags as words of a prompt. A
# claude shown to be the lead is the lead whatever its arguments say.
test_the_lead_keeps_its_rotation_when_its_prompt_names_the_teammate_flags() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" handoff out lead i=0
    handoff=$(_arm_rotation)
    _fake_claude_script
    "$TEST_TMPDIR/fake-claude.sh" explain --agent-id --agent-name --team-name options >/dev/null 2>&1 &
    lead=$!
    while [ "$i" -lt 50 ]; do
        ps -o args= -p "$lead" 2>/dev/null | grep -q fake-claude && break
        i=$((i + 1)); sleep 0.1
    done
    out=$(_start_hook "$lead" "$lead" clear 33333333-3333-4333-8333-333333333333)
    kill "$lead" 2>/dev/null
    assert_eq "1" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "the lead's /clear loads the rotation" || return 1
    assert_eq "consumed_by: 33333333-3333-4333-8333-333333333333" "$(sed -n 3p "$handoff")" \
        "the lead's conversation is recorded as the consumer" || return 1
}

# The resume arm runs claude as cs's child, so the lead is known there only by
# asking ps for the parent. A ps that cannot answer proves nothing: the claude
# is then not shown to be a guest, and keeps what is the lead's. The stand-in
# leaves a file behind, so the test knows it was the ps that answered.
test_a_claude_whose_parent_cannot_be_read_is_not_taken_for_a_guest() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" out shim="$TEST_TMPDIR/shim"
    _arm_rotation > /dev/null
    mkdir -p "$shim"
    printf '#!/bin/sh\n: > "%s/ps-asked"\nexit 126\n' "$TEST_TMPDIR" > "$shim/ps"
    chmod +x "$shim/ps"
    out=$(PATH="$shim:$PATH" _start_hook "$PPID" "$$" clear 33333333-3333-4333-8333-333333333333)
    assert_file_exists "$TEST_TMPDIR/ps-asked" "the stand-in ps was the one asked" || return 1
    assert_eq "1" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "the rotation is loaded when the parent cannot be read" || return 1
    PATH="$shim:$PATH" _stop_hook "$PPID" "$$" > /dev/null
    assert_file_exists "$meta/local/attention" \
        "the attention flag is raised when the parent cannot be read" || return 1
}

run_test test_the_lead_gets_the_narrative_reminder
run_test test_a_nested_child_is_not_reminded
run_test test_a_nested_child_does_not_raise_the_attention_flag
run_test test_a_nested_child_leaves_the_armed_rotation_to_the_lead
run_test test_a_nested_child_leaves_the_queue_digest_to_the_lead
run_test test_a_teammate_leaves_the_armed_rotation_and_the_digest_to_the_lead
run_test test_the_lead_keeps_its_rotation_when_its_prompt_names_the_teammate_flags
run_test test_a_claude_whose_parent_cannot_be_read_is_not_taken_for_a_guest

report_results
