#!/usr/bin/env bash
# ABOUTME: Tests `cs -codex-hook session-start`, the SessionStart hook cs registers for Codex.
# ABOUTME: Feeds Codex-shaped stdin JSON under a faked run lease; no Codex process runs.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

OLD_THREAD=11111111-1111-4111-8111-111111111111
NEW_THREAD=22222222-2222-4222-8222-222222222222
HANDOFF=2026-10-05-continue-the-plan.md
RUN=33333333-3333-4333-8333-333333333333
OTHER_RUN=44444444-4444-4444-8444-444444444444

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    SESSION="$TEST_TMPDIR/session"
    mkdir -p "$SESSION/.cs/local" "$SESSION/.cs/handoffs"
    printf 'engine: codex\n' > "$SESSION/.cs/local/state"
    printf '%s\n' "$OLD_THREAD" > "$SESSION/.cs/local/codex-thread-id"
    # The run lease a supervised cs launch holds: the hook may rebind only
    # for the run that owns the session.
    printf '%s\n' "$$" > "$SESSION/.cs/session.lock"
    jq -n --arg owner "$$" --arg run "$RUN" '{run_id: $run, engine: "codex", owner_pid: ($owner | tonumber)}' \
        > "$SESSION/.cs/local/run-lease.json"
    # The private directory the launch makes for the automatic /clear.
    export CS_CACHE_DIR="$TEST_TMPDIR/cache"
    RUN_DIR="$CS_CACHE_DIR/codex-runs/$RUN"
    mkdir -p "$CS_CACHE_DIR/codex-runs"
    mkdir -m 700 "$RUN_DIR"
    STAMP="$RUN_DIR/autoclear"
    export CS_ACTOR=tester
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CS_ACTOR CS_CACHE_DIR
}

_handoff() {  # status
    printf -- '---\nparent: %s\ncreated: 2026-10-05T10:00:00Z\npurpose: continue the plan\nstatus: %s\n---\n\n## 1. Next Step\nstatus: unconsumed is quoted here on purpose.\n' \
        "$OLD_THREAD" "$1" > "$SESSION/.cs/handoffs/$HANDOFF"
}

_arm() { printf '%s\n' "$HANDOFF" > "$SESSION/.cs/local/pending-handoff"; }

# Runs the hook the way Codex does: JSON on stdin, inside the launch's env.
_hook() {  # source, [run_id]
    printf '{"session_id":"%s","source":"%s","cwd":"%s","hook_event_name":"SessionStart"}' \
        "$NEW_THREAD" "$1" "$SESSION" \
        | env CS_RUN_ENGINE=codex CS_RUN_ID="${2:-$RUN}" CS_RUN_OWNER_PID="$$" \
            CS_SESSION_DIR="$SESSION" CS_SESSION_NAME=demo "$CS_BIN" -codex-hook session-start
}

test_clear_with_an_armed_handoff_rebinds_and_loads_it() {
    _handoff unconsumed
    _arm
    local out
    out=$(_hook clear) || { echo "  FAIL: hook exited non-zero"; return 1; }
    assert_eq "$NEW_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" \
        "the next cs launch must resume the conversation /clear opened" || return 1
    printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null \
        || { echo "  FAIL: not a SessionStart hook output: $out"; return 1; }
    assert_output_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" \
        "Read .cs/handoffs/$HANDOFF FIRST" "the new conversation is pointed at the handoff" || return 1
    assert_output_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" \
        "narrative.tester.md" "and at its actor's narrative" || return 1
    assert_output_contains "$(printf '%s' "$out" | jq -r '.systemMessage')" "Rotation loaded from $HANDOFF" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^status: consumed$" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^consumed_by: $NEW_THREAD$" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^status: unconsumed is quoted here" \
        "only the frontmatter's status line flips" || return 1
    assert_not_exists "$SESSION/.cs/local/pending-handoff" "the marker is spent" || return 1
    jq -e --arg from "$OLD_THREAD" --arg to "$NEW_THREAD" --arg h "$HANDOFF" --arg run "$RUN" \
        'select(.event == "rotated") | .engine == "codex" and .from == $from and .to == $to
         and .reason == "handoff" and .handoff == $h and .run_id == $run' \
        "$SESSION/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: no rotated event with the lineage"; return 1; }
    jq -e --arg id "$NEW_THREAD" 'select(.event == "started") | .engine == "codex" and .session_id == $id and .source == "clear"' \
        "$SESSION/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: no started event"; return 1; }
    assert_file_contains "$SESSION/.cs/local/session.log" "Session started (source: clear, ID: $NEW_THREAD)" \
        "the rotate skill finds this conversation's handoffs by this line" || return 1
}

test_clear_without_a_handoff_rebinds_as_a_clean_break() {
    local out
    out=$(_hook clear) || return 1
    assert_eq "$NEW_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" || return 1
    assert_output_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" \
        "--- Fresh Conversation ---" || return 1
    printf '%s' "$out" | jq -e 'has("systemMessage") | not' >/dev/null \
        || { echo "  FAIL: nothing to announce without a rotation"; return 1; }
    jq -e 'select(.event == "rotated") | .reason == "rebind" and (has("handoff") | not)' \
        "$SESSION/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: rebind lineage missing"; return 1; }
}

# A marker naming a spent handoff is stale: the clear is a clean break and the
# marker goes, so no later /clear trips over it.
test_a_stale_marker_is_dropped() {
    _handoff consumed
    _arm
    local out
    out=$(_hook clear) || return 1
    assert_output_contains "$out" "Fresh Conversation" || return 1
    assert_not_exists "$SESSION/.cs/local/pending-handoff" || return 1
}

# Every cs launch reaches Codex as a resume (cs creates the thread first),
# and the launch owns that binding and any rotation it starts. The hook only
# records that the conversation ran here.
test_resume_changes_nothing_but_the_log() {
    _handoff unconsumed
    _arm
    local out
    out=$(_hook resume) || return 1
    assert_eq "" "$out" "nothing to inject on a launch" || return 1
    assert_eq "$OLD_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" || return 1
    assert_file_exists "$SESSION/.cs/local/pending-handoff" "an armed rotation waits for /clear" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^status: unconsumed$" || return 1
    assert_file_contains "$SESSION/.cs/local/session.log" "Session started (source: resume, ID: $NEW_THREAD)" || return 1
}

# Only the run that owns the session may move its binding or spend its
# rotation: another Codex process in the same directory is not the launch.
test_a_run_without_the_lease_rebinds_nothing() {
    _handoff unconsumed
    _arm
    local out
    out=$(_hook clear run-other) || return 1
    assert_eq "" "$out" || return 1
    assert_eq "$OLD_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" || return 1
    assert_file_exists "$SESSION/.cs/local/pending-handoff" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^status: unconsumed$" || return 1
}

# Not even a stale marker is the outsider's to clear.
test_a_run_without_the_lease_leaves_a_stale_marker() {
    _handoff consumed
    _arm
    _hook clear run-other >/dev/null || return 1
    assert_file_exists "$SESSION/.cs/local/pending-handoff" "only the owning run tidies the session" || return 1
}

# A plain codex run, or a Claude conversation's environment, is not a cs
# Codex launch: the hook stays silent and touches nothing.
test_outside_a_cs_codex_run_the_hook_is_inert() {
    local out status=0
    out=$(printf '{"session_id":"%s","source":"clear"}' "$NEW_THREAD" \
        | env -u CS_RUN_ENGINE -u CS_SESSION_DIR "$CS_BIN" -codex-hook session-start) || status=$?
    assert_eq 0 "$status" || return 1
    assert_eq "" "$out" || return 1
    out=$(printf 'not json' | env CS_RUN_ENGINE=codex CS_SESSION_DIR="$SESSION" "$CS_BIN" -codex-hook session-start) || status=$?
    assert_eq 0 "$status" "a hook must never fail a turn" || return 1
    assert_eq "" "$out" || return 1
    assert_eq "$OLD_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" || return 1
    assert_not_exists "$SESSION/.cs/local/session.log" || return 1
}

# An encrypted session keeps its command log behind .cs/private; a plaintext
# .cs/local/session.log beside the vault is what the next open refuses.
test_an_encrypted_session_logs_the_start_behind_private() {
    mkdir -p "$SESSION/.cs/private"
    _hook resume >/dev/null || return 1
    assert_file_contains "$SESSION/.cs/private/session.log" "Session started (source: resume, ID: $NEW_THREAD)" || return 1
    assert_not_exists "$SESSION/.cs/local/session.log" "no plaintext log beside the vault" || return 1
}

test_a_clear_in_an_encrypted_session_logs_the_rebind_behind_private() {
    mkdir -p "$SESSION/.cs/private"
    _hook clear >/dev/null || return 1
    assert_file_contains "$SESSION/.cs/private/session.log" "Session started (source: clear, ID: $NEW_THREAD)" || return 1
    assert_file_contains "$SESSION/.cs/private/session.log" "Rebound codex thread: $OLD_THREAD -> $NEW_THREAD" || return 1
    assert_not_exists "$SESSION/.cs/local/session.log" || return 1
}

# A locked vault drops the line, as the Claude hooks do.
test_a_locked_vault_drops_the_log_line() {
    ln -s "$TEST_TMPDIR/not-mounted" "$SESSION/.cs/private"
    _hook clear >/dev/null || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_not_exists "$SESSION/.cs/local/session.log" || return 1
    assert_not_exists "$TEST_TMPDIR/not-mounted" "nothing is created behind the dangling link" || return 1
}

test_unknown_hook_event_is_a_usage_error() {
    local status=0 out
    out=$("$CS_BIN" -codex-hook no-such-event </dev/null 2>&1) || status=$?
    assert_eq 2 "$status" || return 1
    assert_output_contains "$out" "Usage: cs -codex-hook session-start|files-changed|stop|user-prompt-submit" || return 1
}

# --- the automatic /clear after a rotation: Stop and UserPromptSubmit ---

# Runs a turn-end or prompt hook the way Codex does, for a thread. The test's
# cache lies under TMPDIR, which the hooks rightly refuse for the run
# directory, so this runs cs with that one check stood down: bin/cs without
# its closing `main "$@"`, the stub, then main. tests/test_codex_autoclear.sh
# exercises the real check.
_turn_hook() {  # verb, thread, [run_id]
    printf '{"session_id":"%s","turn_id":"turn-1","cwd":"%s","hook_event_name":"x"}' "$2" "$SESSION" \
        | env CS_RUN_ENGINE=codex CS_RUN_ID="${3:-$RUN}" CS_RUN_OWNER_PID="$$" \
            CS_SESSION_DIR="$SESSION" CS_SESSION_NAME=demo bash -c '
                eval "$(sed "\$d" "$1")"
                _codex_run_dir_in_sandbox_root() { return 1; }
                shift
                main "$@"' cs "$CS_BIN" -codex-hook "$1"
}

_stamp_field() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$STAMP"; }

_stale_stamp() { printf 'deadline=1\nhandoff=x.md\naction=clear\nrun=%s\n' "$RUN" > "$STAMP"; }

test_a_turn_ending_with_a_handoff_armed_starts_the_count() {
    _handoff unconsumed; _arm
    local out now deadline
    now=$(date +%s)
    out=$(CS_CODEX_CLEAR_GRACE=20 _turn_hook stop "$OLD_THREAD") || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_file_exists "$STAMP" || return 1
    assert_eq "$HANDOFF" "$(_stamp_field handoff)" || return 1
    assert_eq "" "$(_stamp_field action)" "the watcher decides at the deadline, not the turn's end" || return 1
    assert_eq "$RUN" "$(_stamp_field run)" || return 1
    deadline=$(_stamp_field deadline)
    [ "$deadline" -ge $((now + 20)) ] && [ "$deadline" -le $((now + 22)) ] \
        || { echo "  FAIL: deadline $deadline is not about 20 s after $now"; return 1; }
    assert_eq "cs: /clear and go in 20 s, to continue from $HANDOFF. Send a message first to keep this conversation; unsent text in the composer would be sent." \
        "$(printf '%s' "$out" | jq -r .systemMessage)" "the TUI says what will happen" || return 1
}

# A grace with a leading zero is decimal: 08 is eight seconds, not an
# arithmetic error that fails the turn and strands the temp file.
test_a_grace_with_a_leading_zero_is_decimal() {
    _handoff unconsumed; _arm
    local out now deadline
    now=$(date +%s)
    out=$(CS_CODEX_CLEAR_GRACE=08 _turn_hook stop "$OLD_THREAD") || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    deadline=$(_stamp_field deadline)
    [ -n "$deadline" ] && [ "$deadline" -ge $((now + 8)) ] && [ "$deadline" -le $((now + 10)) ] \
        || { echo "  FAIL: deadline '$deadline' is not about 8 s after $now"; return 1; }
    assert_output_contains "$(printf '%s' "$out" | jq -r .systemMessage)" "in 8 s" || return 1
    local temp
    for temp in "$RUN_DIR"/autoclear.*; do
        assert_not_exists "$temp" "no temp file left behind" || return 1
    done
}

# The agent's sandbox writes anywhere in the session, so the deadline never
# goes there: only into the run's private directory, as a 0600 file.
test_a_turn_end_never_writes_into_the_workspace() {
    _handoff unconsumed; _arm
    _turn_hook stop "$OLD_THREAD" >/dev/null || return 1
    assert_not_exists "$SESSION/.cs/local/codex-autoclear" "the agent's sandbox can write the workspace" || return 1
    assert_file_exists "$STAMP" || return 1
    assert_eq 600 "$(_file_mode "$STAMP")" "the deadline is the user's alone" || return 1
}

# No run directory means the launch runs no watcher: no count, and no line
# promising one.
test_no_run_dir_means_no_count_and_no_message() {
    _handoff unconsumed; _arm
    rmdir "$RUN_DIR"
    local out
    out=$(_turn_hook stop "$OLD_THREAD") || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_eq "" "$out" "no message without a watcher" || return 1
    assert_not_exists "$RUN_DIR" || return 1
    assert_not_exists "$SESSION/.cs/local/codex-autoclear" || return 1
}

# The real cs, with no check stood down: the test's cache lies under TMPDIR
# (or /tmp), where the sandbox writes, so the hook starts no count there.
test_a_run_dir_the_sandbox_can_write_gets_no_count() {
    _handoff unconsumed; _arm
    local out
    out=$(printf '{"session_id":"%s"}' "$OLD_THREAD" \
        | env CS_RUN_ENGINE=codex CS_RUN_ID="$RUN" CS_RUN_OWNER_PID="$$" \
            CS_SESSION_DIR="$SESSION" CS_SESSION_NAME=demo "$CS_BIN" -codex-hook stop) \
        || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_eq "" "$out" || return 1
    assert_not_exists "$STAMP" "a run directory the sandbox can write holds no deadline" || return 1
}

test_a_turn_ending_with_nothing_armed_drops_a_count() {
    _stale_stamp
    local out
    out=$(_turn_hook stop "$OLD_THREAD") || return 1
    assert_not_exists "$STAMP" || return 1
    assert_eq "" "$out" "no message when nothing is armed" || return 1
}

test_a_turn_in_another_thread_starts_no_count() {
    _handoff unconsumed; _arm
    _turn_hook stop "$NEW_THREAD" >/dev/null || return 1
    assert_not_exists "$STAMP" "only the bound conversation counts down" || return 1
}

test_a_turn_of_another_run_starts_no_count() {
    _handoff unconsumed; _arm
    _turn_hook stop "$OLD_THREAD" "$OTHER_RUN" >/dev/null || return 1
    assert_not_exists "$STAMP" "a run without the lease never counts down" || return 1
}

test_force_off_leaves_the_clear_to_the_user() {
    _handoff unconsumed; _arm
    local value
    for value in off OFF " off " 0 00; do
        _stale_stamp
        CS_ROTATE_FORCE_CTX="$value" _turn_hook stop "$OLD_THREAD" >/dev/null || return 1
        assert_not_exists "$STAMP" "CS_ROTATE_FORCE_CTX=$value turns the count off" || return 1
    done
    for value in 80 bogus ""; do
        CS_ROTATE_FORCE_CTX="$value" _turn_hook stop "$OLD_THREAD" >/dev/null || return 1
        assert_file_exists "$STAMP" "CS_ROTATE_FORCE_CTX=$value leaves it on" || return 1
        rm -f "$STAMP"
    done
}

test_a_pending_switch_counts_down_to_quit() {
    _handoff unconsumed; _arm
    local out
    printf 'engine=claude\nmode=fresh\nhandoff=%s\nrun=%s\n' "$HANDOFF" "$RUN" > "$SESSION/.cs/local/pending-switch"
    out=$(CS_CODEX_CLEAR_GRACE=20 _turn_hook stop "$OLD_THREAD") || return 1
    assert_file_exists "$STAMP" || return 1
    assert_eq "cs: /quit in 20 s, and cs reopens this session under claude (its default model, native approval) from $HANDOFF. Send a message first to stay; unsent text in the composer would be sent." \
        "$(printf '%s' "$out" | jq -r .systemMessage)" || return 1
    # Another run's switch is not this run's to take.
    printf 'engine=claude\nmode=fresh\nhandoff=%s\nrun=%s\n' "$HANDOFF" "$OTHER_RUN" > "$SESSION/.cs/local/pending-switch"
    out=$(CS_CODEX_CLEAR_GRACE=20 _turn_hook stop "$OLD_THREAD") || return 1
    assert_eq "cs: /clear and go in 20 s, to continue from $HANDOFF. Send a message first to keep this conversation; unsent text in the composer would be sent." \
        "$(printf '%s' "$out" | jq -r .systemMessage)" || return 1
}

# A switch that would move a native-approval run to automatic review gets no
# count: the line names what the switch would start and leaves the exit to the
# user.
test_a_switch_that_loosens_approval_starts_no_count() {
    _handoff unconsumed; _arm
    _stale_stamp
    local out
    printf 'engine=claude\nmode=fresh\nhandoff=%s\nrun=%s\nmodel=opus\neffort=\napproval=auto\n' \
        "$HANDOFF" "$RUN" > "$SESSION/.cs/local/pending-switch"
    out=$(CS_RUN_APPROVAL=native _turn_hook stop "$OLD_THREAD") || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_not_exists "$STAMP" "no count toward an exit cs will not make" || return 1
    assert_eq "cs: a switch to claude (model opus, automatic approval) is pending. It would move this run from native to automatic approval, so cs does not quit for you: /quit to take it, or cs -switch cancel to stay." \
        "$(printf '%s' "$out" | jq -r .systemMessage)" || return 1
    out=$(CS_RUN_APPROVAL=auto CS_CODEX_CLEAR_GRACE=20 _turn_hook stop "$OLD_THREAD") || return 1
    assert_file_exists "$STAMP" "automatic approval kept is not loosened" || return 1
    assert_output_contains "$(printf '%s' "$out" | jq -r .systemMessage)" "/quit in 20 s" || return 1
}

test_a_message_sent_during_the_count_stops_it() {
    _stale_stamp
    : > "$RUN_DIR/typing"
    local out
    out=$(_turn_hook user-prompt-submit "$NEW_THREAD") || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_not_exists "$STAMP" || return 1
    assert_not_exists "$RUN_DIR/typing" "a prompt sent while cs types stops the rest of its keys" || return 1
    assert_eq "" "$out" || return 1
}

test_outside_a_cs_codex_run_the_turn_hooks_are_inert() {
    _handoff unconsumed; _arm
    _stale_stamp
    local verb
    for verb in stop user-prompt-submit; do
        printf '{"session_id":"%s"}' "$OLD_THREAD" | "$CS_BIN" -codex-hook "$verb" >/dev/null \
            || { echo "  FAIL: $verb failed outside a run"; return 1; }
    done
    assert_file_exists "$STAMP" "nothing outside a cs Codex run touches the count" || return 1
}

run_test test_clear_with_an_armed_handoff_rebinds_and_loads_it
run_test test_clear_without_a_handoff_rebinds_as_a_clean_break
run_test test_a_stale_marker_is_dropped
run_test test_resume_changes_nothing_but_the_log
run_test test_a_run_without_the_lease_rebinds_nothing
run_test test_a_run_without_the_lease_leaves_a_stale_marker
run_test test_outside_a_cs_codex_run_the_hook_is_inert
run_test test_an_encrypted_session_logs_the_start_behind_private
run_test test_a_clear_in_an_encrypted_session_logs_the_rebind_behind_private
run_test test_a_locked_vault_drops_the_log_line
run_test test_unknown_hook_event_is_a_usage_error
run_test test_a_turn_ending_with_a_handoff_armed_starts_the_count
run_test test_a_grace_with_a_leading_zero_is_decimal
run_test test_a_turn_end_never_writes_into_the_workspace
run_test test_no_run_dir_means_no_count_and_no_message
run_test test_a_run_dir_the_sandbox_can_write_gets_no_count
run_test test_a_turn_ending_with_nothing_armed_drops_a_count
run_test test_a_turn_in_another_thread_starts_no_count
run_test test_a_turn_of_another_run_starts_no_count
run_test test_force_off_leaves_the_clear_to_the_user
run_test test_a_pending_switch_counts_down_to_quit
run_test test_a_switch_that_loosens_approval_starts_no_count
run_test test_a_message_sent_during_the_count_stops_it
run_test test_outside_a_cs_codex_run_the_turn_hooks_are_inert

report_results
