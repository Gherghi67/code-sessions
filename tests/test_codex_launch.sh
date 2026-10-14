#!/usr/bin/env bash
# ABOUTME: Exercises Codex thread binding, refresh, launch, and shared lock cleanup.
# ABOUTME: Uses isolated fake executables so no real Codex thread is created.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/01-manifests.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/15-lock.sh"
source "$SCRIPT_DIR/../lib/16-lifecycle.sh"
source "$SCRIPT_DIR/../lib/24-engine-adapters.sh"
source "$SCRIPT_DIR/../lib/36-context.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../lib/41-bindings.sh"
source "$SCRIPT_DIR/../lib/75-launch.sh"
source "$SCRIPT_DIR/../lib/76-codex.sh"
source "$SCRIPT_DIR/../lib/77-codex-hooks.sh"
source "$SCRIPT_DIR/../lib/78-switch.sh"

_set_local_state() {  # state key value
    printf '%s: %s\n' "$2" "$3" >> "$1"
}
cs_interactive() { return 1; }
# The launch prompt's palette; empty keeps escape codes out of asserted output.
DIM='' NC='' BOLD='' WHITE='' GREEN='' GOLD='' COMMENT='' ORANGE=''
warn() { printf 'Warning: %s\n' "$1" >&2; }
cs_actor_slug() { printf '%s\n' "${CS_ACTOR:-test-actor}"; }

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export CS_TEST_SESSION_DIR="$TEST_TMPDIR/session with spaces"
    mkdir -p "$CS_TEST_SESSION_DIR/.cs/local"
    export CS_CODEX_LOG="$TEST_TMPDIR/codex-args"
    export CS_CODEX_ENV="$TEST_TMPDIR/codex-env"
    export CS_HELPER_ARGS="$TEST_TMPDIR/helper-args"
    export CS_HELPER_COUNT="$TEST_TMPDIR/helper-count"
    export CS_THREAD_ID=12345678-1234-1234-1234-123456789abc
    export CS_HELPER_EXIT=0 CS_CODEX_EXIT=0
    export CS_CODEX_START=0 CS_CODEX_NEW_HANDOFF=""
    export CS_CODEX_TURN=0 CS_CODEX_TURNS="$TEST_TMPDIR/codex-turns"
    export CS_HELPER_TURN_CALLS="$TEST_TMPDIR/helper-turn-calls" CS_HELPER_TURN_FAIL_FROM=0
    export CODEX_BIN="$TEST_TMPDIR/codex with spaces"
    export CS_CODEX_THREAD_BIN="$TEST_TMPDIR/cs-codex-thread"
    export CS_BIN="$SCRIPT_DIR/../bin/cs"
    cat > "$CODEX_BIN" <<'CODEX'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CS_CODEX_LOG"
env | grep -E '^(CS_SESSION_|CS_ACTOR=|CLAUDE_SESSION_|CLAUDE_CODE_SESSION_ID=|CS_CLAUDE_SESSION_ID=|CS_LEAD_PID=|CLAUDE_PID=)' > "$CS_CODEX_ENV" || true
if [ "$CS_CODEX_START" = 1 ]; then
    printf '{"session_id":"%s","source":"resume"}' "$CS_THREAD_ID" | "$CS_BIN" -codex-hook session-start
fi
if [ "$CS_CODEX_TURN" = 1 ]; then
    # A turn begins as Codex runs one: into the thread's history, then the
    # SessionStart handlers of each group whose matcher takes the source.
    printf 'turn-%s-%s\n' "$$" "$RANDOM" >> "$CS_CODEX_TURNS"
    jq -r '.hooks.SessionStart[]?
        | select((.matcher // "") as $m | $m == "" or $m == "*" or ("resume" | test("^(?:" + $m + ")$")))
        | .hooks[].command' "$CODEX_HOME/hooks.json" 2>/dev/null \
        | while IFS= read -r command; do
            printf '{"session_id":"%s","source":"resume"}' "$CS_THREAD_ID" | bash -c "$command" >/dev/null 2>&1
        done
fi
if [ -n "$CS_CODEX_NEW_HANDOFF" ]; then
    printf -- '---\nstatus: unconsumed\n---\n' > "$CS_SESSION_DIR/.cs/handoffs/$CS_CODEX_NEW_HANDOFF"
    printf '%s\n' "$CS_CODEX_NEW_HANDOFF" > "$CS_SESSION_DIR/.cs/local/pending-handoff"
fi
exit "$CS_CODEX_EXIT"
CODEX
    cat > "$CS_CODEX_THREAD_BIN" <<'HELPER'
#!/usr/bin/env bash
case " $* " in
    *' --latest-turn '*)
        printf '%s\n' "$*" >> "$CS_HELPER_TURN_CALLS"
        # From the CS_HELPER_TURN_FAIL_FROM-th read on, the history cannot be read.
        [ "$CS_HELPER_TURN_FAIL_FROM" -eq 0 ] \
            || [ "$(wc -l < "$CS_HELPER_TURN_CALLS")" -lt "$CS_HELPER_TURN_FAIL_FROM" ] || exit 1
        tail -n 1 "$CS_CODEX_TURNS" 2>/dev/null
        exit 0
        ;;
esac
printf '%s\n' "$@" > "$CS_HELPER_ARGS"
printf 'called\n' >> "$CS_HELPER_COUNT"
[ "$CS_HELPER_EXIT" -eq 0 ] || { echo 'simulated app-server failure' >&2; exit "$CS_HELPER_EXIT"; }
printf '%s\n' "$CS_THREAD_ID"
HELPER
    chmod +x "$CODEX_BIN" "$CS_CODEX_THREAD_BIN"
    unset CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CS_LEAD_PID CLAUDE_PID CODEX_HOME
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CODEX_BIN CS_CODEX_THREAD_BIN CS_TEST_SESSION_DIR CS_CODEX_LOG
    unset CS_CODEX_ENV CS_HELPER_ARGS CS_HELPER_COUNT CS_THREAD_ID
    unset CS_HELPER_EXIT CS_CODEX_EXIT
    unset CS_CODEX_START CS_CODEX_NEW_HANDOFF
    unset CS_CODEX_TURN CS_CODEX_TURNS CS_HELPER_TURN_CALLS CS_HELPER_TURN_FAIL_FROM CODEX_HOME
}

test_new_thread_binding_and_context() {
    local output status=0 binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "first launch failed: $output" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$binding")" "new thread binding" || return 1
    assert_eq "--no-daemon" "$(sed -n '1p' "$CS_CODEX_LOG")" "CLI owns thread writer lifetime" || return 1
    assert_eq "resume" "$(sed -n '2p' "$CS_CODEX_LOG")" "CLI resumes exact thread" || return 1
    assert_eq "$CS_THREAD_ID" "$(sed -n '3p' "$CS_CODEX_LOG")" "CLI thread ID" || return 1
    assert_eq "-C" "$(sed -n '4p' "$CS_CODEX_LOG")" "CLI cwd switch" || return 1
    assert_eq "$CS_TEST_SESSION_DIR" "$(sed -n '5p' "$CS_CODEX_LOG")" "CLI cwd with spaces" || return 1
    assert_eq 6 "$(wc -l < "$CS_HELPER_ARGS" | tr -d ' ')" "helper takes three named arguments" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'This context does not request work' || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'narrative.test-actor.md' || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'Agent-sessions executable:' || return 1
    assert_output_contains "$output" 'autosave, and task queue integration are unavailable' "feature scope notice" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/state" 'engine: codex' || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" "lock released after CLI exit" || return 1
    assert_output_contains "$(cat "$CS_CODEX_ENV")" 'CS_SESSION_NAME=demo' "neutral identity exported" || return 1
    assert_output_contains "$(cat "$CS_CODEX_ENV")" 'CLAUDE_SESSION_NAME=demo' "legacy resolver alias exported" || return 1
}

test_resume_refreshes_exact_thread() {
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" output status=0
    printf '%s\n' "$CS_THREAD_ID" > "$binding"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 0 "$status" "resume failed: $output" || return 1
    assert_eq "--thread-id" "$(sed -n '7p' "$CS_HELPER_ARGS")" "refresh parameter" || return 1
    assert_eq "$CS_THREAD_ID" "$(sed -n '8p' "$CS_HELPER_ARGS")" "refresh exact ID" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$binding")" "binding retained" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

test_failed_refresh_never_starts_fresh() {
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" output status=0
    printf '%s\n' "$CS_THREAD_ID" > "$binding"
    export CS_HELPER_EXIT=12
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 12 "$status" "failed refresh preserves helper failure status" || return 1
    assert_output_contains "$output" 'Could not refresh Codex thread' "actionable error" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$binding")" "binding unchanged" || return 1
    assert_not_exists "$CS_CODEX_LOG" "CLI must not launch on refresh failure" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

test_malformed_binding_rejected_without_helper() {
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" output status=0
    printf 'not-a-thread\n' > "$binding"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 1 "$status" "malformed binding must reject" || return 1
    assert_output_contains "$output" 'Invalid Codex thread binding' "diagnostic" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no helper call" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no CLI call" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

# Codex refuses a CODEX_HOME that does not exist, and its app-server then dies
# before the helper can say why. The launch names the directory instead.
test_missing_codex_home_is_named_before_the_helper() {
    local output status=0
    export CODEX_HOME="$TEST_TMPDIR/no such codex home"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    unset CODEX_HOME
    assert_eq 1 "$status" "a missing CODEX_HOME must stop the launch" || return 1
    assert_output_contains "$output" "CODEX_HOME points to $TEST_TMPDIR/no such codex home" "names the directory" || return 1
    assert_output_contains "$output" "codex login" "says what to do next" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no helper call" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no CLI call" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

# Codex keeps its conversations in its own home, outside the vault, so no
# intent opens an encrypted session; a locked vault (a dangling link) counts.
test_encrypted_session_refuses_codex() {
    local output status intent
    mkdir -p "$TEST_TMPDIR/vault/private"
    ln -s "$TEST_TMPDIR/vault/private" "$CS_TEST_SESSION_DIR/.cs/private"
    printf '%s\n' "$CS_THREAD_ID" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    for intent in auto fresh resume handoff; do
        status=0
        output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" "$intent" 2>&1) || status=$?
        assert_eq 1 "$status" "$intent must refuse an encrypted session" || return 1
        assert_output_contains "$output" "demo is encrypted" "$intent names why" || return 1
        assert_output_contains "$output" "cs demo --engine claude" "$intent names the Claude way" || return 1
    done
    rm -rf "$TEST_TMPDIR/vault"
    status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 1 "$status" "a locked vault must refuse too" || return 1
    assert_output_contains "$output" "demo is encrypted" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no helper call" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no CLI call" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

test_mismatched_refresh_rejected() {
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" output status=0
    printf 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n' > "$binding"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 1 "$status" "mismatched helper result must reject" || return 1
    assert_output_contains "$output" 'for bound thread' "diagnostic" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no CLI call" || return 1
    assert_eq aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa "$(cat "$binding")" "binding unchanged" || return 1
}

test_cli_status_and_lock_cleanup() {
    local status=0
    export CS_CODEX_EXIT=27
    launch_codex demo "$CS_TEST_SESSION_DIR" true false > /dev/null 2>&1 || status=$?
    assert_eq 27 "$status" "preserve Codex exit status" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" "cleanup after CLI failure" || return 1
}

test_claude_runtime_binding_isolation() {
    local output status=0
    export CLAUDE_CODE_SESSION_ID=claude-uuid CS_CLAUDE_SESSION_ID=claude-uuid
    export CS_LEAD_PID=999 CLAUDE_PID=999
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "launch failed: $output" || return 1
    assert_output_not_contains "$(cat "$CS_CODEX_ENV")" 'CLAUDE_CODE_SESSION_ID=' "no Claude runtime ID" || return 1
    assert_output_not_contains "$(cat "$CS_CODEX_ENV")" 'CS_CLAUDE_SESSION_ID=' "no CS Claude binding" || return 1
    assert_output_not_contains "$(cat "$CS_CODEX_ENV")" 'CS_LEAD_PID=999' "inherited lead marker replaced by run controller" || return 1
    assert_output_not_contains "$(cat "$CS_CODEX_ENV")" 'CLAUDE_PID=' "no Claude PID" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/claude_session_id" || return 1
}

# -finish starts the thread on the finish skill, named the way Codex takes a
# skill from the user: one argument, after the exact resume and its cwd.
test_finish_starts_the_thread_on_the_finish_skill() {
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false feature 2>&1) || status=$?
    assert_eq 0 "$status" "launch failed: $output" || return 1
    assert_eq "resume" "$(sed -n '2p' "$CS_CODEX_LOG")" "CLI resumes exact thread" || return 1
    assert_eq "$CS_TEST_SESSION_DIR" "$(sed -n '5p' "$CS_CODEX_LOG")" "CLI cwd" || return 1
    assert_eq '$finish feature' "$(sed -n '6p' "$CS_CODEX_LOG")" "the first prompt names the skill" || return 1
    assert_eq 6 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "nothing after the prompt" || return 1
}

test_live_lock_blocks_launch() {
    local output status=0 lock="$CS_TEST_SESSION_DIR/.cs/session.lock"
    sleep 20 &
    local holder=$!
    printf '%s\n' "$holder" > "$lock"
    RED='' NC='' DIM=''
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    assert_eq 1 "$status" "live lock must reject" || return 1
    assert_output_contains "$output" 'already open' "shared lock diagnostic" || return 1
    assert_eq "$holder" "$(cat "$lock")" "rejected launch keeps owner lock" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "helper not called when locked" || return 1
}

test_helper_resolved_beside_cs() {
    local output status=0
    mkdir -p "$TEST_TMPDIR/installed bin"
    cp "$CS_CODEX_THREAD_BIN" "$TEST_TMPDIR/installed bin/cs-codex-thread"
    export CS_BIN="$TEST_TMPDIR/installed bin/cs"
    unset CS_CODEX_THREAD_BIN
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "sibling helper lookup failed: $output" || return 1
    assert_eq 1 "$(wc -l < "$CS_HELPER_COUNT" | tr -d ' ')" "helper called once" || return 1
}

test_unarchive_and_actor_override() {
    local output status=0
    printf 'archived\n' > "$CS_TEST_SESSION_DIR/.cs/archived"
    export CS_ACTOR=custom-actor
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 0 "$status" "archived launch failed: $output" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/archived" "opening unarchives session" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'narrative.custom-actor.md' || return 1
    assert_file_contains "$CS_CODEX_ENV" 'CS_ACTOR=custom-actor' "explicit actor preserved" || return 1
    unset CS_ACTOR
}

test_termination_releases_lock_and_stops_codex() {
    local launcher_script="$TEST_TMPDIR/launch.sh" child_file="$TEST_TMPDIR/codex-child"
    local lock="$CS_TEST_SESSION_DIR/.cs/session.lock" launcher child='' status=0 n
    export CS_TEST_LIB_DIR="$SCRIPT_DIR" CS_CODEX_CHILD_PID="$child_file"
    cat > "$CODEX_BIN" <<'SLEEP_CODEX'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$CS_CODEX_CHILD_PID"
exec sleep 30
SLEEP_CODEX
    chmod +x "$CODEX_BIN"
    cat > "$launcher_script" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
source "$CS_TEST_LIB_DIR/../lib/02-shared.sh"
source "$CS_TEST_LIB_DIR/../lib/15-lock.sh"
source "$CS_TEST_LIB_DIR/../lib/16-lifecycle.sh"
source "$CS_TEST_LIB_DIR/../lib/24-engine-adapters.sh"
source "$CS_TEST_LIB_DIR/../lib/36-context.sh"
source "$CS_TEST_LIB_DIR/../lib/40-state.sh"
source "$CS_TEST_LIB_DIR/../lib/41-bindings.sh"
source "$CS_TEST_LIB_DIR/../lib/76-codex.sh"
_set_local_state() { printf '%s: %s\n' "$2" "$3" >> "$1"; }
cs_actor_slug() { printf 'test-actor\n'; }
cs_interactive() { return 1; }
warn() { printf 'Warning: %s\n' "$1" >&2; }
launch_codex demo "$CS_TEST_SESSION_DIR" true false
LAUNCHER
    /bin/bash "$launcher_script" > "$TEST_TMPDIR/launcher-output" 2>&1 &
    launcher=$!
    for ((n = 0; n < 100; n++)); do
        [ -f "$lock" ] && [ -f "$child_file" ] && break
        sleep 0.1
    done
    if [ ! -f "$lock" ] || [ ! -f "$child_file" ]; then
        kill "$launcher" 2>/dev/null || true
        wait "$launcher" 2>/dev/null || true
        echo "  FAIL: Codex child did not start: $(cat "$TEST_TMPDIR/launcher-output")"
        return 1
    fi
    child=$(cat "$child_file")
    assert_eq "$launcher" "$(cat "$lock")" "lock belongs to launch shell" || return 1
    kill -TERM "$launcher"
    wait "$launcher" 2>/dev/null || status=$?
    if [ "$status" -ne 143 ]; then
        kill "$child" 2>/dev/null || true
        assert_eq 143 "$status" "TERM exit status" || return 1
    fi
    assert_not_exists "$lock" "TERM releases lock" || return 1
    if kill -0 "$child" 2>/dev/null; then
        kill "$child" 2>/dev/null || true
        echo '  FAIL: Codex child survived launcher termination'
        return 1
    fi
}

test_explicit_fresh_replaces_only_codex_binding() {
    local old_id=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa output status=0
    printf '%s\n' "$old_id" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    printf 'claude_session_id: claude-old\n' > "$CS_TEST_SESSION_DIR/.cs/local/state"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?
    assert_eq 0 "$status" "fresh failed: $output" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id")" || return 1
    assert_output_not_contains "$(cat "$CS_HELPER_ARGS")" '--thread-id' "fresh creates a native conversation" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/state" 'claude_session_id: claude-old' || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-binding-codex.json" "acknowledged transition cleared" || return 1
    local event
    event=$(jq -c 'select(.event == "rotated")' "$CS_TEST_SESSION_DIR/.cs/timeline.jsonl")
    assert_output_contains "$event" '"engine":"codex"' "qualified lineage" || return 1
    assert_output_contains "$event" "\"from\":\"$old_id\"" "prior binding recorded" || return 1
}

test_failed_fresh_preserves_codex_binding() {
    local old_id=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa output status=0
    printf '%s\n' "$old_id" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    export CS_HELPER_EXIT=12
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?
    assert_eq 12 "$status" "failed create preserves helper failure status" || return 1
    assert_eq "$old_id" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id")" "prior conversation recoverable" || return 1
    assert_not_exists "$CS_CODEX_LOG" "invalid preparation prevents native launch" || return 1
}

test_resume_without_binding_does_not_create() {
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" resume 2>&1) || status=$?
    assert_eq 1 "$status" "missing resume must reject" || return 1
    assert_output_contains "$output" 'no recorded Codex conversation' || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no native create on resume" || return 1
}

# A bound Codex thread and a handoff the rotate skill wrote and armed.
ROTATION_OLD_THREAD=99999999-9999-4999-8999-999999999999
ROTATION_HANDOFF=2026-10-05-next-step.md
_rotation_fixture() {  # handoff status
    printf '%s\n' "$ROTATION_OLD_THREAD" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    mkdir -p "$CS_TEST_SESSION_DIR/.cs/handoffs"
    printf -- '---\nparent: %s\ncreated: 2026-10-05T10:00:00Z\npurpose: next step\nstatus: %s\n---\n\n## 1. Next Step\n' \
        "$ROTATION_OLD_THREAD" "$1" > "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF"
    printf '%s\n' "$ROTATION_HANDOFF" > "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff"
}

# Launch interactively, answering the prompt with one key.
_launch_answering() {  # key, [intent]
    cs_interactive() { return 0; }
    launch_codex demo "$CS_TEST_SESSION_DIR" false false "" "${2:-auto}" <<< "$1"
}

# r at launch is Codex's other way into a rotation (the first is /clear): a
# fresh thread whose launch context carries the handoff, started with a kick
# so it acts without waiting for a message.
test_r_starts_a_thread_from_the_rotation_handoff() {
    _rotation_fixture unconsumed
    local output status=0 h="$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF"
    output=$(_launch_answering r 2>&1) || status=$?
    assert_eq 0 "$status" "r launch failed: $output" || return 1
    assert_output_contains "$output" "Rotation handoff pending:" || return 1
    assert_output_contains "$output" "from handoff" "the prompt offers r" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id")" "bound to the new thread" || return 1
    assert_output_not_contains "$(cat "$CS_HELPER_ARGS")" '--thread-id' "r creates a thread" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" "Read .cs/handoffs/$ROTATION_HANDOFF FIRST" \
        "the new thread's context names the handoff" || return 1
    assert_eq "Continue from the pending rotation handoff: read .cs/handoffs/$ROTATION_HANDOFF first." \
        "$(sed -n '6p' "$CS_CODEX_LOG")" "codex resume gets the kick as its starting prompt" || return 1
    assert_file_contains "$h" "^status: consumed$" || return 1
    assert_file_contains "$h" "^consumed_by: $CS_THREAD_ID$" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    jq -e --arg from "$ROTATION_OLD_THREAD" --arg to "$CS_THREAD_ID" --arg h "$ROTATION_HANDOFF" \
        'select(.event == "rotated") | .engine == "codex" and .from == $from and .to == $to
         and .reason == "handoff" and .handoff == $h' \
        "$CS_TEST_SESSION_DIR/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: rotated lineage missing"; return 1; }
}

# n starts fresh without the handoff, and must disarm the marker, or an
# unrelated /clear later would load a handoff the user just passed on.
test_n_starts_fresh_and_leaves_the_handoff_pending() {
    _rotation_fixture unconsumed
    local output status=0
    output=$(_launch_answering n 2>&1) || status=$?
    assert_eq 0 "$status" "n launch failed: $output" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id")" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" "n disarms" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^status: unconsumed$" || return 1
    assert_file_not_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" "Conversation Rotation" || return 1
    assert_eq 5 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
}

test_d_discards_the_handoff_then_resumes() {
    _rotation_fixture unconsumed
    export CS_THREAD_ID="$ROTATION_OLD_THREAD"
    local output status=0
    output=$(_launch_answering d 2>&1) || status=$?
    assert_eq 0 "$status" "d launch failed: $output" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^status: discarded$" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    assert_eq "$ROTATION_OLD_THREAD" "$(sed -n '3p' "$CS_CODEX_LOG")" "resumes the bound thread" || return 1
    assert_eq 5 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
}

# Claude's fresh launch consumes an armed marker at SessionStart; an explicit
# Codex --fresh does the same through the launch.
test_explicit_fresh_continues_an_armed_rotation() {
    _rotation_fixture unconsumed
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?
    assert_eq 0 "$status" "fresh launch failed: $output" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^consumed_by: $CS_THREAD_ID$" || return 1
    assert_output_contains "$(sed -n '6p' "$CS_CODEX_LOG")" "$ROTATION_HANDOFF" "kicked from the handoff" || return 1
}

test_failed_direct_rotation_launches_restore_the_handoff_for_retry() {
    local intent output status h="$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF"
    # An older conversation's log entry must not count as this one starting.
    printf 'Earlier - Session started (source: resume, ID: old)\n' > "$CS_TEST_SESSION_DIR/.cs/local/session.log"
    for intent in handoff fresh auto; do
        _rotation_fixture unconsumed
        export CS_THREAD_ID=12345678-1234-1234-1234-123456789abc CS_CODEX_EXIT=27
        status=0
        output=$(_launch_answering r "$intent" 2>&1) || status=$?
        assert_eq 27 "$status" "$intent preserves CLI failure: $output" || return 1
        assert_file_contains "$h" '^status: unconsumed$' "$intent restores the handoff" || return 1
        assert_file_not_contains "$h" '^consumed_by:' || return 1
        assert_eq "$ROTATION_HANDOFF" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff")" || return 1
        assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1

        export CS_THREAD_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa CS_CODEX_EXIT=0
        status=0
        output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" handoff 2>&1) || status=$?
        assert_eq 0 "$status" "$intent can retry --from-handoff: $output" || return 1
        assert_file_contains "$h" "^consumed_by: $CS_THREAD_ID$" || return 1
        assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    done
}

test_direct_rotation_that_started_then_failed_keeps_the_handoff_consumed() {
    _rotation_fixture unconsumed
    export CS_CODEX_START=1 CS_CODEX_EXIT=27
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" handoff 2>&1) || status=$?
    assert_eq 27 "$status" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/session.log" "Session started.*$CS_THREAD_ID" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^consumed_by: $CS_THREAD_ID$" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    assert_output_not_contains "$output" 'restored for retry' || return 1
}

# A reinstall keeps the user's matcher on the group cs's hook sits in. With
# `clear` there, the hook never sees a launch's `resume` start, so the log
# says nothing; the thread's own history shows the turn that ran.
test_direct_rotation_that_ran_behind_a_clear_only_hook_keeps_the_handoff_consumed() {
    _rotation_fixture unconsumed
    export CODEX_HOME="$TEST_TMPDIR/codex-home"
    mkdir -p "$CODEX_HOME"
    jq -n '{hooks: {SessionStart: [{matcher: "clear", hooks: [
        {type: "command", command: "/user/on-clear"},
        {type: "command", command: "/old/cs -codex-hook session-start"}]}]}}' > "$CODEX_HOME/hooks.json"
    _codex_hooks_register "$CODEX_HOME" "$(_codex_hook_command "$CS_BIN")" || return 1
    assert_eq clear "$(jq -r '.hooks.SessionStart[0].matcher' "$CODEX_HOME/hooks.json")" "(fixture) the matcher stays" || return 1
    export CS_CODEX_TURN=1 CS_CODEX_EXIT=27
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" handoff 2>&1) || status=$?
    assert_eq 27 "$status" || return 1
    assert_file_not_contains "$CS_TEST_SESSION_DIR/.cs/local/session.log" "$CS_THREAD_ID" \
        "(fixture) the matcher keeps the start out of the log" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^consumed_by: $CS_THREAD_ID$" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    assert_output_not_contains "$output" 'restored for retry' || return 1
}

# The same group without the matcher runs cs's hook on the launch's start, so
# the fake's dispatch is what keeps it out above.
test_direct_rotation_that_ran_behind_an_unfiltered_hook_logs_its_start() {
    _rotation_fixture unconsumed
    export CODEX_HOME="$TEST_TMPDIR/codex-home"
    mkdir -p "$CODEX_HOME"
    _codex_hooks_register "$CODEX_HOME" "$(_codex_hook_command "$CS_BIN")" || return 1
    export CS_CODEX_TURN=1 CS_CODEX_EXIT=27
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" handoff 2>&1) || status=$?
    assert_eq 27 "$status" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/session.log" "Session started (source: resume, ID: $CS_THREAD_ID)" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^consumed_by: $CS_THREAD_ID$" || return 1
}

# A thread whose history cannot be read, before the CLI or after it, proves
# nothing either way, so the handoff stays with the thread that took it.
test_failed_rotation_with_unreadable_thread_history_keeps_the_handoff_consumed() {
    local from output status
    for from in 1 2; do
        _rotation_fixture unconsumed
        rm -f "$CS_HELPER_TURN_CALLS"
        export CS_HELPER_TURN_FAIL_FROM="$from" CS_CODEX_EXIT=27
        status=0
        output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" handoff 2>&1) || status=$?
        assert_eq 27 "$status" || return 1
        # With no mark from before, the history after is not asked.
        assert_eq "$from" "$(wc -l < "$CS_HELPER_TURN_CALLS" | tr -d ' ')" "reads up to the one that fails" || return 1
        assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^consumed_by: $CS_THREAD_ID$" \
            "read $from fails: the handoff stays consumed" || return 1
        assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
        assert_output_not_contains "$output" 'restored for retry' || return 1
    done
}

test_failed_direct_rotation_preserves_a_newer_pending_handoff() {
    _rotation_fixture unconsumed
    export CS_CODEX_NEW_HANDOFF=2026-10-13-newer.md CS_CODEX_EXIT=27
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" handoff 2>&1) || status=$?
    assert_eq 27 "$status" || return 1
    assert_eq "$CS_CODEX_NEW_HANDOFF" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff")" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^consumed_by: $CS_THREAD_ID$" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$CS_CODEX_NEW_HANDOFF" '^status: unconsumed$' || return 1
}

# Unattended or explicit resume never takes the rotation, so the marker goes.
test_resume_disarms_an_armed_rotation() {
    _rotation_fixture unconsumed
    export CS_THREAD_ID="$ROTATION_OLD_THREAD"
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 0 "$status" "resume failed: $output" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^status: unconsumed$" || return 1
    assert_eq 5 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
}

echo 'Codex launch tests'
run_test test_explicit_fresh_replaces_only_codex_binding
run_test test_failed_fresh_preserves_codex_binding
run_test test_resume_without_binding_does_not_create
run_test test_r_starts_a_thread_from_the_rotation_handoff
run_test test_n_starts_fresh_and_leaves_the_handoff_pending
run_test test_d_discards_the_handoff_then_resumes
run_test test_explicit_fresh_continues_an_armed_rotation
run_test test_failed_direct_rotation_launches_restore_the_handoff_for_retry
run_test test_direct_rotation_that_started_then_failed_keeps_the_handoff_consumed
run_test test_direct_rotation_that_ran_behind_a_clear_only_hook_keeps_the_handoff_consumed
run_test test_direct_rotation_that_ran_behind_an_unfiltered_hook_logs_its_start
run_test test_failed_rotation_with_unreadable_thread_history_keeps_the_handoff_consumed
run_test test_failed_direct_rotation_preserves_a_newer_pending_handoff
run_test test_resume_disarms_an_armed_rotation
run_test test_new_thread_binding_and_context
run_test test_resume_refreshes_exact_thread
run_test test_failed_refresh_never_starts_fresh
run_test test_malformed_binding_rejected_without_helper
run_test test_missing_codex_home_is_named_before_the_helper
run_test test_encrypted_session_refuses_codex
run_test test_mismatched_refresh_rejected
run_test test_cli_status_and_lock_cleanup
run_test test_claude_runtime_binding_isolation
run_test test_finish_starts_the_thread_on_the_finish_skill
run_test test_live_lock_blocks_launch
run_test test_helper_resolved_beside_cs
run_test test_unarchive_and_actor_override
run_test test_termination_releases_lock_and_stops_codex
report_results
