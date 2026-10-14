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
    # Every launch modelled here is one that takes the lead's claim, as every
    # launch this cs makes does; a test of a launch without it unsets this.
    export CS_LEAD_CLAIM=1
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
# lead (its pid is not the launch and no claim names it) and must not be
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
    _lead_starts "$lead"
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

# The lead's own SessionStart, which comes before anything the lead starts:
# it claims the launch, so a claude started under it afterwards finds the
# claim. The lead here carries the launch pid, as after an exec launch.
_lead_starts() {  # lead_pid
    _start_hook "$1" "$1" startup 11111111-1111-4111-8111-111111111111 > /dev/null
}

# The lead wrote a handoff and armed the marker; its /clear has not come yet.
# A child started in that window fires SessionStart with source startup. The
# rotation is the lead's: the child must not be handed it, flip the handoff to
# consumed under its own id, or drop the marker. The lead's /clear afterwards
# is the positive control: the rotation is still there to load.
test_a_nested_child_leaves_the_armed_rotation_to_the_lead() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" handoff out
    sleep 300 &
    local lead=$!
    _lead_starts "$lead"
    handoff=$(_arm_rotation)
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

# A rotation marker git tracks came with a pull, a merge or a checkout, not
# from this session's rotate: the lead's /clear loads nothing from it and
# leaves the marker and the handoff as they are.
test_a_rotation_marker_git_tracks_is_not_loaded() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" handoff out
    handoff=$(_arm_rotation)
    git -C "$CLAUDE_SESSION_DIR" init -q
    git -C "$CLAUDE_SESSION_DIR" add -f .cs/local/pending-handoff .cs/handoffs
    git -C "$CLAUDE_SESSION_DIR" -c user.email=jane.roe@example.com -c user.name="Jane Roe" \
        commit -q -m "ship a rotation"

    out=$(_start_hook "$$" "$$" clear 33333333-3333-4333-8333-333333333333)

    assert_eq "0" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "the lead is not told to continue a rotation git delivered" || return 1
    assert_eq "2026-01-01-topic.md" "$(cat "$meta/local/pending-handoff" 2>/dev/null)" \
        "the tracked marker is left in place" || return 1
    assert_eq "status: unconsumed" "$(sed -n 2p "$handoff")" "the handoff is left unconsumed" || return 1
}

# The queue's digest is shown once, to whoever reads it first. A child that
# starts before the lead must neither be shown it nor move the cursor.
test_a_nested_child_leaves_the_queue_digest_to_the_lead() {
    _nested_setup
    local local_dir="$CLAUDE_SESSION_META_DIR/local" out
    sleep 300 &
    local lead=$!
    _lead_starts "$lead"
    printf '{"ts":1,"event":"task_done","task":"t"}\n{"ts":2,"event":"drain_finished"}\n' \
        > "$local_dir/notifications.jsonl"
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

# A teammate's Stop ends a turn of its own, not the lead's, so it neither
# raises the attention flag nor bounces the dock. A front end that walked in
# has no launch pid and none of the teammate flags: its Stop raises both,
# which is the positive control.
test_a_teammate_does_not_raise_the_attention_flag() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" mate i=0
    local it2_dir="$TEST_TMPDIR/it2" it2_log="$TEST_TMPDIR/it2.log"
    mkdir -p "$it2_dir"
    printf '#!/bin/sh\necho "$@" >> "%s"\n' "$it2_log" > "$it2_dir/it2attention"
    chmod +x "$it2_dir/it2attention"
    _fake_claude_script
    "$TEST_TMPDIR/fake-claude.sh" --agent-id a1 --agent-name mate --team-name t >/dev/null 2>&1 &
    mate=$!
    while [ "$i" -lt 50 ]; do
        ps -o args= -p "$mate" 2>/dev/null | grep -q fake-claude && break
        i=$((i + 1)); sleep 0.1
    done
    CS_NO_ITERM2='' TERM_PROGRAM=iTerm.app CS_IT2_DIR="$it2_dir" CS_IT2_TTY="$TEST_TMPDIR/tty" _stop_hook "" "$mate" > /dev/null
    kill "$mate" 2>/dev/null
    assert_not_exists "$meta/local/attention" \
        "a teammate's Stop leaves the attention flag down" || return 1
    assert_not_exists "$it2_log" "a teammate's Stop does not bounce the dock" || return 1

    CS_NO_ITERM2='' TERM_PROGRAM=iTerm.app CS_IT2_DIR="$it2_dir" CS_IT2_TTY="$TEST_TMPDIR/tty" _stop_hook "" "$$" > /dev/null
    assert_file_exists "$meta/local/attention" \
        "a front end's Stop raises the attention flag" || return 1
    assert_eq "start" "$(cat "$it2_log" 2>/dev/null)" "a front end's Stop bounces the dock" || return 1
}

# Stand-ins for the processes of one launch, in $TEST_TMPDIR/tree as
# "launch direct wrapper grandchild": the launch pid cs hands on, a direct
# child of it, and a wrapper with a child of its own (claude run by a wrapper
# that forks it, as `op run --` or a script without exec does). Every one of
# them is alive until _kill_launch_tree.
_launch_tree() {
    local i=0
    printf '%s\n' '#!/usr/bin/env bash' \
        'sleep 300 & direct=$!' \
        'bash -c '"'"'sleep 300 & echo "$!" > "$1.g"; wait'"'"' _ "$1" & wrapper=$!' \
        'while [ ! -s "$1.g" ]; do sleep 0.05; done' \
        'echo "$$ $direct $wrapper $(cat "$1.g")" > "$1.tmp" && mv "$1.tmp" "$1"' \
        'wait' > "$TEST_TMPDIR/tree.sh"
    bash "$TEST_TMPDIR/tree.sh" "$TEST_TMPDIR/tree" >/dev/null 2>&1 &
    while [ "$i" -lt 100 ] && [ ! -s "$TEST_TMPDIR/tree" ]; do
        i=$((i + 1)); sleep 0.1
    done
    [ -s "$TEST_TMPDIR/tree" ] || { echo "  FAIL: the stand-in launch did not start"; return 1; }
}

_kill_launch_tree() {
    local launch direct wrapper grand
    read -r launch direct wrapper grand < "$TEST_TMPDIR/tree"
    kill "$grand" "$direct" "$wrapper" "$launch" 2>/dev/null
}

_recorded_conversation() {
    awk '/^claude_session_id:/ { print $2; exit }' "$CLAUDE_SESSION_META_DIR/local/state" 2>/dev/null
}

# The launched claude is not always the launch pid: the resume arm runs claude
# as cs's child, and a CLAUDE_CODE_BIN that forks puts one more process in
# between. That claude claims the launch at its SessionStart and is the lead
# from then on: it rebinds the recorded conversation, loads the armed rotation
# and raises the attention flag. Another claude under the same launch that
# starts after it, while it lives, is a guest.
test_a_claude_the_launch_forked_is_the_lead_once_it_claims() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" handoff out launch direct wrapper grand
    handoff=$(_arm_rotation)
    _launch_tree || return 1
    read -r launch direct wrapper grand < "$TEST_TMPDIR/tree"

    out=$(_start_hook "$launch" "$grand" startup 66666666-6666-4666-8666-666666666666)
    local rotations recorded
    rotations=$(grep -c 'Conversation Rotation' <<< "$out")
    recorded=$(_recorded_conversation)
    _stop_hook "$launch" "$grand" > /dev/null
    local lead_flag=absent
    [ -e "$meta/local/attention" ] && lead_flag=raised
    rm -f "$meta/local/attention"

    _arm_rotation > /dev/null
    out=$(_start_hook "$launch" "$direct" startup 77777777-7777-4777-8777-777777777777)
    local guest_rotations guest_recorded
    guest_rotations=$(grep -c 'Conversation Rotation' <<< "$out")
    guest_recorded=$(_recorded_conversation)
    _stop_hook "$launch" "$direct" > /dev/null
    local guest_flag=absent
    [ -e "$meta/local/attention" ] && guest_flag=raised
    _kill_launch_tree

    assert_eq "1" "$rotations" "the forked lead loads the armed rotation" || return 1
    assert_eq "66666666-6666-4666-8666-666666666666" "$recorded" \
        "the forked lead rebinds the recorded conversation" || return 1
    assert_eq "raised" "$lead_flag" "the forked lead's Stop raises the attention flag" || return 1
    assert_eq "0" "$guest_rotations" "a later claude under the launch is not handed the rotation" || return 1
    assert_eq "66666666-6666-4666-8666-666666666666" "$guest_recorded" \
        "a later claude under the launch leaves the recorded conversation" || return 1
    assert_eq "absent" "$guest_flag" "a later claude's Stop leaves the attention flag down" || return 1
}

# A wrapper that forks claude on an exec launch leaves claude a direct child
# of the launch pid. CS_LEAD_IS_PARENT=0 in its environment, the value a
# launch carried before the claim, changes nothing: the claim decides.
test_a_claude_an_exec_launch_forked_is_the_lead_once_it_claims() {
    _nested_setup
    local launch direct wrapper grand out
    _arm_rotation > /dev/null
    _launch_tree || return 1
    read -r launch direct wrapper grand < "$TEST_TMPDIR/tree"
    out=$(CS_LEAD_IS_PARENT=0 _start_hook "$launch" "$direct" startup 66666666-6666-4666-8666-666666666666)
    local recorded
    recorded=$(_recorded_conversation)
    _kill_launch_tree
    assert_eq "1" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "the forked lead loads the armed rotation" || return 1
    assert_eq "66666666-6666-4666-8666-666666666666" "$recorded" \
        "the forked lead rebinds the recorded conversation" || return 1
}

# On an exec launch the pid cs hands on is the lead claude's own, so a claude
# started as its direct child (a mod's process run) is a descendant of the
# launch like the lead. The lead claimed the launch at its own start, before
# it could start anything, so the child finds a live claim that is not its
# own and is a guest: it is not handed the rotation, and its end leaves the
# lead's lock and claim.
test_a_direct_child_of_the_lead_claude_is_not_the_lead() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" handoff out lead child i=0
    printf '#!/usr/bin/env bash\nsleep 300 &\necho "$$ $!" > "$1"\ntrap "kill $!" TERM\nwait\n' > "$TEST_TMPDIR/lead.sh"
    bash "$TEST_TMPDIR/lead.sh" "$TEST_TMPDIR/pids" &
    while [ "$i" -lt 50 ] && [ ! -s "$TEST_TMPDIR/pids" ]; do
        i=$((i + 1)); sleep 0.1
    done
    read -r lead child < "$TEST_TMPDIR/pids"
    assert_eq "$lead" "$(ps -o ppid= -p "$child" | tr -d '[:space:]')" \
        "the stand-in child's parent is the stand-in lead" || { kill "$lead" 2>/dev/null; return 1; }
    echo "$lead" > "$meta/session.lock"

    _start_hook "$lead" "$lead" startup 33333333-3333-4333-8333-333333333333 > /dev/null
    handoff=$(_arm_rotation)
    out=$(_start_hook "$lead" "$child" startup 44444444-4444-4444-8444-444444444444)
    printf '{"session_id":"44444444-4444-4444-8444-444444444444","reason":"other"}\n' \
        | CS_RESOLVED_FROM=env CS_LEAD_PID="$lead" CLAUDE_PID="$child" bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1
    local marker status lock claim
    marker=$(cat "$meta/local/pending-handoff" 2>/dev/null)
    status=$(sed -n 2p "$handoff")
    lock=$(cat "$meta/session.lock" 2>/dev/null)
    claim=$(cat "$meta/local/lead-pid" 2>/dev/null)
    kill "$lead" 2>/dev/null

    assert_eq "0" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "the lead's child is not told to continue the rotation" || return 1
    assert_eq "2026-01-01-topic.md" "$marker" "the marker stays armed" || return 1
    assert_eq "status: unconsumed" "$status" "the handoff stays unconsumed" || return 1
    assert_eq "$lead" "$lock" "the child's end leaves the live lead's lock" || return 1
    assert_eq "$lead $lead 33333333-3333-4333-8333-333333333333" "$claim" \
        "the child's end leaves the lead's claim" || return 1
}

# A claude the lead started before the lead's own SessionStart ran (another
# plugin's SessionStart hook running `claude -p`) finds no claim and takes
# it. The lead, starting next, is that claude's ancestor, so it takes the
# claim back; the other claude is a guest from then on.
test_the_lead_takes_the_claim_from_a_claude_it_started() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" launch direct wrapper grand
    _launch_tree || return 1
    read -r launch direct wrapper grand < "$TEST_TMPDIR/tree"
    _start_hook "$launch" "$grand" startup 77777777-7777-4777-8777-777777777777 > /dev/null
    _start_hook "$launch" "$wrapper" startup 66666666-6666-4666-8666-666666666666 > /dev/null
    local claim recorded
    claim=$(cat "$meta/local/lead-pid" 2>/dev/null)
    recorded=$(_recorded_conversation)
    _stop_hook "$launch" "$grand" > /dev/null
    local guest_flag=absent
    [ -e "$meta/local/attention" ] && guest_flag=raised
    _kill_launch_tree

    assert_eq "$launch $wrapper 66666666-6666-4666-8666-666666666666" "$claim" \
        "the lead holds the claim" || return 1
    assert_eq "66666666-6666-4666-8666-666666666666" "$recorded" \
        "the recorded conversation is the lead's" || return 1
    assert_eq "absent" "$guest_flag" "the other claude's Stop leaves the attention flag down" || return 1
}

# A session opened by a cs that predates the claim carries no CS_LEAD_CLAIM,
# and stays open while the hooks are updated. Nothing under that launch
# claims it, so the claude carrying the launch pid is its only lead. A
# `claude -p` the lead's Bash tool runs (below a shell, so the launch's
# grandchild) neither rebinds the recorded conversation nor writes a claim,
# and its end leaves the lead's lock. The lead's own /clear still rebinds.
test_a_launch_that_takes_no_claim_has_only_the_launch_pid_for_its_lead() {
    _nested_setup
    unset CS_LEAD_CLAIM
    local meta="$CLAUDE_SESSION_META_DIR" launch direct wrapper grand
    _launch_tree || return 1
    read -r launch direct wrapper grand < "$TEST_TMPDIR/tree"
    echo "$launch" > "$meta/session.lock"
    printf 'claude_session_id: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n' > "$meta/local/state"

    _start_hook "$launch" "$grand" startup bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb > /dev/null
    local child_recorded child_claim lock
    child_recorded=$(_recorded_conversation)
    child_claim=$(cat "$meta/local/lead-pid" 2>/dev/null || echo none)
    printf '{"session_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","reason":"other"}\n' \
        | CS_RESOLVED_FROM=env CS_LEAD_PID="$launch" CLAUDE_PID="$grand" bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1
    lock=$(cat "$meta/session.lock" 2>/dev/null || echo none)
    _start_hook "$launch" "$launch" clear cccccccc-cccc-4ccc-8ccc-cccccccccccc > /dev/null
    local lead_recorded lead_claim
    lead_recorded=$(_recorded_conversation)
    lead_claim=$(cat "$meta/local/lead-pid" 2>/dev/null || echo none)
    _kill_launch_tree

    assert_eq "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" "$child_recorded" \
        "the claude -p leaves the recorded conversation" || return 1
    assert_eq "none" "$child_claim" "the claude -p writes no claim" || return 1
    assert_eq "$launch" "$lock" "the claude -p's end leaves the lead's lock" || return 1
    assert_eq "cccccccc-cccc-4ccc-8ccc-cccccccccccc" "$lead_recorded" \
        "the claude carrying the launch pid rebinds the recorded conversation" || return 1
    assert_eq "none" "$lead_claim" "nothing under the launch writes a claim" || return 1
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

# The resume arm runs claude as cs's child, so the lead claims the launch only
# once ps shows the launch pid among its ancestors. A ps that cannot answer
# leaves no claim, and with no claim no claude is shown to be a guest: this one
# keeps what is the lead's. The stand-in leaves a file behind, so the test
# knows it was the ps that answered.
test_a_claude_whose_ancestry_cannot_be_read_is_not_taken_for_a_guest() {
    _nested_setup
    local meta="$CLAUDE_SESSION_META_DIR" out shim="$TEST_TMPDIR/shim"
    _arm_rotation > /dev/null
    mkdir -p "$shim"
    printf '#!/bin/sh\n: > "%s/ps-asked"\nexit 126\n' "$TEST_TMPDIR" > "$shim/ps"
    chmod +x "$shim/ps"
    out=$(PATH="$shim:$PATH" _start_hook "$PPID" "$$" clear 33333333-3333-4333-8333-333333333333)
    assert_file_exists "$TEST_TMPDIR/ps-asked" "the stand-in ps was the one asked" || return 1
    assert_eq "1" "$(grep -c 'Conversation Rotation' <<< "$out")" \
        "the rotation is loaded when the ancestry cannot be read" || return 1
    PATH="$shim:$PATH" _stop_hook "$PPID" "$$" > /dev/null
    assert_file_exists "$meta/local/attention" \
        "the attention flag is raised when the ancestry cannot be read" || return 1
}

run_test test_the_lead_gets_the_narrative_reminder
run_test test_a_nested_child_is_not_reminded
run_test test_a_nested_child_does_not_raise_the_attention_flag
run_test test_a_nested_child_leaves_the_armed_rotation_to_the_lead
run_test test_a_rotation_marker_git_tracks_is_not_loaded
run_test test_a_nested_child_leaves_the_queue_digest_to_the_lead
run_test test_a_teammate_leaves_the_armed_rotation_and_the_digest_to_the_lead
run_test test_a_teammate_does_not_raise_the_attention_flag
run_test test_a_claude_the_launch_forked_is_the_lead_once_it_claims
run_test test_a_claude_an_exec_launch_forked_is_the_lead_once_it_claims
run_test test_a_direct_child_of_the_lead_claude_is_not_the_lead
run_test test_the_lead_takes_the_claim_from_a_claude_it_started
run_test test_a_launch_that_takes_no_claim_has_only_the_launch_pid_for_its_lead
run_test test_the_lead_keeps_its_rotation_when_its_prompt_names_the_teammate_flags
run_test test_a_claude_whose_ancestry_cannot_be_read_is_not_taken_for_a_guest

report_results
