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

run_test test_the_lead_gets_the_narrative_reminder
run_test test_a_nested_child_is_not_reminded

report_results
