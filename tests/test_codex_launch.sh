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
    export CS_CODEX_HELP='--approve-for-me' CS_CODEX_HELP_EXIT=0
    unset CS_LAUNCH_APPROVAL CS_LAUNCH_MODEL CS_LAUNCH_EFFORT
    export CS_CODEX_START=0 CS_CODEX_NEW_HANDOFF=""
    export CS_CODEX_TURN=0 CS_CODEX_TURNS="$TEST_TMPDIR/codex-turns"
    export CS_HELPER_TURN_CALLS="$TEST_TMPDIR/helper-turn-calls" CS_HELPER_TURN_FAIL_FROM=0
    export CS_HELPER_PROJECT_CONFIG='{}' CS_HELPER_PROJECT_EXIT=0
    export CODEX_BIN="$TEST_TMPDIR/codex with spaces"
    export CS_CODEX_THREAD_BIN="$TEST_TMPDIR/cs-codex-thread"
    export CS_BIN="$SCRIPT_DIR/../bin/cs"
    cat > "$CODEX_BIN" <<'CODEX'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
    printf '      %s\n' "$CS_CODEX_HELP"
    exit "$CS_CODEX_HELP_EXIT"
fi
printf '%s\n' "$@" > "$CS_CODEX_LOG"
env | grep -E '^(CS_SESSION_|CS_RUN_APPROVAL=|CS_CODEX_ROTATION_FIXED=|CS_ACTOR=|CLAUDE_SESSION_|CLAUDE_CODE_SESSION_ID=|CS_CLAUDE_SESSION_ID=|CS_LEAD_PID=|CLAUDE_PID=)' > "$CS_CODEX_ENV" || true
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
    *' --project-config '*)
        [ "$CS_HELPER_PROJECT_EXIT" -eq 0 ] || exit "$CS_HELPER_PROJECT_EXIT"
        printf '%s\n' "$CS_HELPER_PROJECT_CONFIG"
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
    unset CS_HELPER_EXIT CS_CODEX_EXIT CS_CODEX_HELP CS_CODEX_HELP_EXIT
    unset CS_LAUNCH_APPROVAL CS_LAUNCH_MODEL CS_LAUNCH_EFFORT
    unset CS_CODEX_START CS_CODEX_NEW_HANDOFF
    unset CS_CODEX_TURN CS_CODEX_TURNS CS_HELPER_TURN_CALLS CS_HELPER_TURN_FAIL_FROM CODEX_HOME
    unset CS_HELPER_PROJECT_CONFIG CS_HELPER_PROJECT_EXIT
    unset CS_TEST_PROBE
}

# Unsupported builds must be rejected before native preparation changes the
# session, even when a saved conversation or an armed handoff already exists.
test_unsupported_codex_first_open_does_not_prepare_a_thread() {
    export CS_CODEX_HELP='--sandbox'
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 1 "$status" "unsupported Codex must refuse" || return 1
    assert_output_contains "$output" 'Upgrade Codex' "says how to repair the installation" || return 1
    assert_output_contains "$output" 'CODEX_BIN' "names the executable override" || return 1
    assert_output_contains "$output" '--approve-for-me' "names the required capability" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no native preparation" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no interactive launch" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" "no binding" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" "no context" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-binding-codex.json" "no staged binding" || return 1
}

test_unsupported_codex_preserves_bound_launches_and_handoffs() {
    export CS_CODEX_HELP='--sandbox'
    _rotation_fixture unconsumed
    local local_dir="$CS_TEST_SESSION_DIR/.cs/local" intent output status
    printf 'existing context\n' > "$local_dir/codex-instructions.md"
    printf '{"marker":"untouched"}\n' > "$local_dir/pending-binding-codex.json"
    printf 'engine: claude\n' > "$local_dir/state"
    cp "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "$TEST_TMPDIR/handoff-before"
    for intent in resume fresh handoff; do
        status=0
        output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" "$intent" 2>&1) || status=$?
        assert_eq 1 "$status" "$intent must refuse unsupported Codex" || return 1
        assert_output_contains "$output" 'Upgrade Codex' "$intent compatibility diagnostic" || return 1
        assert_not_exists "$CS_HELPER_COUNT" "$intent must not call the helper" || return 1
        assert_not_exists "$CS_CODEX_LOG" "$intent must not launch interactively" || return 1
        assert_eq "$ROTATION_OLD_THREAD" "$(cat "$local_dir/codex-thread-id")" "$intent keeps its binding" || return 1
        assert_eq 'existing context' "$(cat "$local_dir/codex-instructions.md")" "$intent keeps its context" || return 1
        assert_eq '{"marker":"untouched"}' "$(cat "$local_dir/pending-binding-codex.json")" "$intent keeps its pending binding" || return 1
        assert_eq 'engine: claude' "$(cat "$local_dir/state")" "$intent keeps its engine preference" || return 1
        assert_eq "$ROTATION_HANDOFF" "$(cat "$local_dir/pending-handoff")" "$intent keeps its armed handoff" || return 1
        cmp -s "$TEST_TMPDIR/handoff-before" "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" \
            || { echo "  FAIL: $intent changed the handoff"; return 1; }
    done
}

test_failed_codex_help_cannot_advertise_compatibility() {
    export CS_CODEX_HELP_EXIT=23
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 1 "$status" "a failed help probe must refuse even when it prints the option" || return 1
    assert_output_contains "$output" 'Upgrade Codex' "actionable refusal" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no native preparation" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no interactive launch" || return 1
}

test_codex_help_prose_is_not_an_approval_option() {
    export CS_CODEX_HELP='Upgrade for --approve-for-me support'
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 1 "$status" "mentioning a flag in prose does not declare support" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no native preparation" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no interactive launch" || return 1
}

test_native_approval_launches_without_automatic_approval_support() {
    export CS_CODEX_HELP='--sandbox' CS_LAUNCH_APPROVAL=native
    export CS_LAUNCH_MODEL='native-model' CS_LAUNCH_EFFORT='high'
    local output status=0 binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "native approval launch failed: $output" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$binding")" "native approval creates its thread" || return 1
    assert_exists "$CS_HELPER_COUNT" "native approval prepares the thread" || return 1
    assert_eq '--model' "$(sed -n '6p' "$CS_CODEX_LOG")" "model option retained" || return 1
    assert_eq 'native-model' "$(sed -n '7p' "$CS_CODEX_LOG")" "model value retained" || return 1
    assert_eq '-c' "$(sed -n '8p' "$CS_CODEX_LOG")" "effort config option retained" || return 1
    assert_eq 'model_reasoning_effort="high"' "$(sed -n '9p' "$CS_CODEX_LOG")" "effort value retained" || return 1
    if grep -Fx -- '--approve-for-me' "$CS_CODEX_LOG" >/dev/null; then
        echo '  FAIL: native approval passed the automatic approval option'
        return 1
    fi
    grep -Fqx CS_RUN_APPROVAL=native "$CS_CODEX_ENV" \
        || { echo "  FAIL: the run's hooks are not told its approval is native"; return 1; }
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" "native launch releases its lock" || return 1
}

test_rotation_profile_seeds_launch_choices_without_pinning_them() {
    export CS_CODEX_HELP=$'--approve-for-me\n-p, --profile <CONFIG_PROFILE_V2>'
    export CS_LAUNCH_MODEL='gpt-6-astra' CS_LAUNCH_EFFORT=xhigh
    local output status=0 profile
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "$output" || return 1
    grep -Fx -- '--profile' "$CS_CODEX_LOG" >/dev/null \
        || { echo '  FAIL: no scoped profile to reload after /clear'; return 1; }
    profile=$(tail -n 1 "$CS_CODEX_LOG")
    assert_file_contains "$HOME/.codex/$profile.config.toml" '^model = "gpt-6-astra"$' || return 1
    assert_file_contains "$HOME/.codex/$profile.config.toml" '^model_reasoning_effort = "xhigh"$' || return 1
    if grep -Eq -- '^--model$|^model_reasoning_effort=' "$CS_CODEX_LOG"; then
        echo '  FAIL: fixed CLI overrides would shadow later /model choices on /clear'
        return 1
    fi
    # A later launch starts from its own choices, rather than a stale rotation.
    unset CS_LAUNCH_MODEL CS_LAUNCH_EFFORT
    launch_codex demo "$CS_TEST_SESSION_DIR" true false >/dev/null 2>&1 || return 1
    assert_eq "" "$(cat "$HOME/.codex/$profile.config.toml")" 'new launch clears the old rotation defaults' || return 1
    assert_eq '{}' "$(sed -n 's/^CS_CODEX_ROTATION_FIXED=//p' "$CS_CODEX_ENV")" 'nothing fixed for the run' || return 1
}

_launched_with() {  # option, value
    grep -A1 -Fx -- "$1" "$CS_CODEX_LOG" | tail -n 1 | grep -Fx -- "$2" >/dev/null
}

# A trusted project's .codex/config.toml outranks a --profile, so an explicit
# choice the project also sets stays on the command line, and the run names
# what /clear will reload for the Stop hook. The rest still seeds the profile.
test_an_explicit_choice_a_trusted_project_sets_stays_on_the_command_line() {
    export CS_CODEX_HELP=$'--approve-for-me\n-p, --profile <CONFIG_PROFILE_V2>'
    export CS_HELPER_PROJECT_CONFIG='{"model":{"value":"gpt-project","file":"/p/.codex/config.toml"}}'
    export CS_LAUNCH_MODEL='gpt-6-astra' CS_LAUNCH_EFFORT=xhigh
    local output status=0 profile
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "$output" || return 1
    _launched_with --model gpt-6-astra \
        || { echo '  FAIL: the explicit model must outrank the project config'; return 1; }
    if grep -Eq -- '^model_reasoning_effort=' "$CS_CODEX_LOG"; then
        echo '  FAIL: an effort the project leaves alone belongs in the profile'
        return 1
    fi
    profile=$(tail -n 1 "$CS_CODEX_LOG")
    assert_eq 'model_reasoning_effort = "xhigh"' "$(cat "$HOME/.codex/$profile.config.toml")" || return 1
    assert_eq '{"model":{"value":"gpt-6-astra","source":"the command line"}}' \
        "$(sed -n 's/^CS_CODEX_ROTATION_FIXED=//p' "$CS_CODEX_ENV")" || return 1
    # Without an explicit model the project's applies, and /clear reloads it.
    unset CS_LAUNCH_MODEL
    launch_codex demo "$CS_TEST_SESSION_DIR" true false >/dev/null 2>&1 || return 1
    if grep -Fxq -- '--model' "$CS_CODEX_LOG"; then
        echo '  FAIL: no model was asked for'
        return 1
    fi
    assert_eq '{"model":{"value":"gpt-project","source":"/p/.codex/config.toml"}}' \
        "$(sed -n 's/^CS_CODEX_ROTATION_FIXED=//p' "$CS_CODEX_ENV")" || return 1
}

# When Codex cannot say which settings the project fixes, explicit choices
# stay on the command line, where nothing outranks them.
test_unknown_project_settings_keep_explicit_choices_on_the_command_line() {
    export CS_CODEX_HELP=$'--approve-for-me\n-p, --profile <CONFIG_PROFILE_V2>'
    export CS_HELPER_PROJECT_EXIT=1 CS_LAUNCH_MODEL='gpt-6-astra' CS_LAUNCH_EFFORT=xhigh
    local output status=0 profile
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "$output" || return 1
    _launched_with --model gpt-6-astra || { echo '  FAIL: explicit model dropped'; return 1; }
    _launched_with -c 'model_reasoning_effort="xhigh"' || { echo '  FAIL: explicit effort dropped'; return 1; }
    profile=$(tail -n 1 "$CS_CODEX_LOG")
    assert_eq "" "$(cat "$HOME/.codex/$profile.config.toml")" || return 1
    assert_eq '{"model":{"value":"gpt-6-astra","source":"the command line"},"model_reasoning_effort":{"value":"xhigh","source":"the command line"}}' \
        "$(sed -n 's/^CS_CODEX_ROTATION_FIXED=//p' "$CS_CODEX_ENV")" || return 1
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
    assert_eq "--approve-for-me" "$(sed -n '6p' "$CS_CODEX_LOG")" "new thread uses automatic approval review" || return 1
    grep -Fqx CS_RUN_APPROVAL=auto "$CS_CODEX_ENV" \
        || { echo "  FAIL: the run's hooks are not told its approval is automatic"; return 1; }
    assert_eq 6 "$(wc -l < "$CS_HELPER_ARGS" | tr -d ' ')" "helper takes three named arguments" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'This context does not request work' || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'narrative.test-actor.md' || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'Agent-sessions executable:' || return 1
    assert_output_contains "$output" 'automatic recovery is enabled' "feature scope notice" || return 1
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
    assert_eq "--approve-for-me" "$(sed -n '6p' "$CS_CODEX_LOG")" "resumed thread uses automatic approval review" || return 1
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
    assert_eq '$finish feature' "$(sed -n '7p' "$CS_CODEX_LOG")" "the first prompt names the skill" || return 1
    assert_eq 7 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "nothing after the prompt" || return 1
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
if [ "${1:-}" = --help ]; then
    printf '      --approve-for-me\n'
    exit 0
fi
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
source "$CS_TEST_LIB_DIR/../lib/75-launch.sh"
source "$CS_TEST_LIB_DIR/../lib/76-codex.sh"
source "$CS_TEST_LIB_DIR/../lib/77-codex-hooks.sh"
source "$CS_TEST_LIB_DIR/../lib/78-switch.sh"
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

# A launch whose automatic /clear watcher is a stand-in. The stand-in records
# its pid and run directory and, when stopped, whether the run had already
# settled (the first thing the run does after the engine call). The fake Codex
# records whether a deadline an earlier build left in the session was still
# there, writes this run's own deadline into the run directory, copies the CLI
# pid the launch wrote there beside its own, and exits a second later.
# Everything lands in $CS_TEST_PROBE; the launcher is $TEST_TMPDIR/launch.sh.
_autoclear_launch_fixture() {
    local launcher_script="$TEST_TMPDIR/launch.sh"
    export CS_TEST_LIB_DIR="$SCRIPT_DIR" CS_TEST_PROBE="$TEST_TMPDIR/probe"
    mkdir -p "$CS_TEST_PROBE"
    printf 'deadline=1\nrun=earlier\n' > "$CS_TEST_SESSION_DIR/.cs/local/codex-autoclear"
    cat > "$CODEX_BIN" <<'FAKE_CODEX'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
    printf '      --approve-for-me\n'
    exit 0
fi
source "$CS_TEST_LIB_DIR/../lib/02-shared.sh"
source "$CS_TEST_LIB_DIR/../lib/40-state.sh"
source "$CS_TEST_LIB_DIR/../lib/77-codex-hooks.sh"
touch "$CS_TEST_PROBE/codex-ran"
[ ! -e "$CS_TEST_SESSION_DIR/.cs/local/codex-autoclear" ] || touch "$CS_TEST_PROBE/saw-legacy-deadline"
run_dir=$(_codex_run_dir) || exit 0
printf '%s\n' "$run_dir" > "$CS_TEST_PROBE/run-dir"
if [ -d "$run_dir" ]; then
    printf 'deadline=1\nrun=%s\n' "$CS_RUN_ID" > "$(_codex_autoclear_file "$run_dir")"
    touch "$CS_TEST_PROBE/wrote-deadline"
    cp "$run_dir/native.pid" "$CS_TEST_PROBE/native-pid" 2>/dev/null
    echo $$ > "$CS_TEST_PROBE/codex-pid"
fi
sleep 1
FAKE_CODEX
    chmod +x "$CODEX_BIN"
    cat > "$launcher_script" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
for lib in 02-shared 15-lock 16-lifecycle 24-engine-adapters 36-context 40-state 41-bindings 75-launch 76-codex 77-codex-hooks 78-switch; do
    source "$CS_TEST_LIB_DIR/../lib/$lib.sh"
done
_set_local_state() { printf '%s: %s\n' "$2" "$3" >> "$1"; }
cs_actor_slug() { printf 'test-actor\n'; }
cs_interactive() { return 1; }
warn() { printf 'Warning: %s\n' "$1" >&2; }
# The fixture's cache lies under TMPDIR, which the real check rightly refuses.
export CS_CACHE_DIR="$CS_TEST_PROBE/cache"
_codex_run_dir_in_sandbox_root() { return 1; }
_codex_flush_input() { touch "$CS_TEST_PROBE/flushed"; }
# The terminal the pty gives the launch takes simulated input unless a test
# says it refuses.
_codex_autoclear_probe() {
    [ -n "${CS_TEST_PROBE_REFUSES:-}" ] || return 0
    printf '%s\n' "$CS_TEST_PROBE_REFUSES"
    return 1
}
eval "_real_switch_settle() $(declare -f _switch_settle | tail -n +2)"
_switch_settle() { touch "$CS_TEST_PROBE/settled"; _real_switch_settle "$@"; }
_codex_autoclear_watch() {  # session_dir, run_dir
    trap 'if [ -e "$CS_TEST_PROBE/settled" ]; then echo after; else echo before; fi > "$CS_TEST_PROBE/stopped"; exit 0' TERM
    printf '%s\n' "$2" > "$CS_TEST_PROBE/watch-dir"
    [ -z "${CS_TEST_KEYS_SENT:-}" ] || : > "$2/keys-sent"
    # bash 3.2 has no BASHPID: a child's parent is this subshell.
    sh -c 'echo $PPID' > "$CS_TEST_PROBE/watch-pid"
    while :; do sleep 0.1; done
}
launch_codex demo "$CS_TEST_SESSION_DIR" true false
if [ -s "$CS_TEST_PROBE/watch-pid" ] && kill -0 "$(cat "$CS_TEST_PROBE/watch-pid")" 2>/dev/null; then
    touch "$CS_TEST_PROBE/watcher-outlived-launch"
fi
LAUNCHER
}

# Under a terminal the watcher runs for exactly as long as Codex: started
# before it, stopped as soon as it exits and before anything else the run does
# (a switch's relaunch would otherwise get its keys), and the run directory
# with this run's deadline goes with it.
test_autoclear_watcher_lives_exactly_as_long_as_codex() {
    local launcher_script="$TEST_TMPDIR/launch.sh" watcher run_dir
    _autoclear_launch_fixture
    _pty_run /bin/bash "$launcher_script" > "$TEST_TMPDIR/launcher-output" 2>&1
    assert_file_exists "$CS_TEST_PROBE/codex-ran" "Codex ran: $(cat "$TEST_TMPDIR/launcher-output")" || return 1
    [ -s "$CS_TEST_PROBE/watch-pid" ] || { echo "  FAIL: no watcher under a terminal: $(cat "$TEST_TMPDIR/launcher-output")"; return 1; }
    watcher=$(cat "$CS_TEST_PROBE/watch-pid")
    if kill -0 "$watcher" 2>/dev/null; then
        kill "$watcher" 2>/dev/null; echo "  FAIL: the watcher outlived Codex"; return 1
    fi
    assert_not_exists "$CS_TEST_PROBE/watcher-outlived-launch" "the watcher is stopped before launch_codex returns" || return 1
    assert_eq before "$(cat "$CS_TEST_PROBE/stopped" 2>/dev/null)" \
        "the watcher is stopped as soon as Codex exits, before the run settles" || return 1
    assert_not_exists "$CS_TEST_PROBE/saw-legacy-deadline" \
        "a deadline an earlier build left in the session is gone before Codex starts" || return 1
    assert_file_exists "$CS_TEST_PROBE/wrote-deadline" "Codex found this run's directory to write its deadline in" || return 1
    run_dir=$(cat "$CS_TEST_PROBE/run-dir")
    assert_eq "$run_dir" "$(cat "$CS_TEST_PROBE/watch-dir")" "the watcher reads this run's directory" || return 1
    assert_eq "$(cat "$CS_TEST_PROBE/codex-pid")" "$(cat "$CS_TEST_PROBE/native-pid" 2>/dev/null)" \
        "the run directory names the CLI the typist must check" || return 1
    assert_not_exists "$run_dir" "this run's directory and deadline are gone once launch_codex returns" || return 1
}

# Keys the watcher typed can still be queued when Codex exits, and would run in
# the shell: the launch flushes the terminal's input then, and only then, so
# ordinary type-ahead survives every other exit.
test_the_launch_flushes_input_only_after_typing() {
    local launcher_script="$TEST_TMPDIR/launch.sh"
    _autoclear_launch_fixture
    _pty_run /bin/bash "$launcher_script" > "$TEST_TMPDIR/launcher-output" 2>&1
    assert_file_exists "$CS_TEST_PROBE/codex-ran" "Codex ran: $(cat "$TEST_TMPDIR/launcher-output")" || return 1
    assert_not_exists "$CS_TEST_PROBE/flushed" "input flushed with no keys of cs's sent" || return 1
    rm -rf "$CS_TEST_PROBE"
    _autoclear_launch_fixture
    CS_TEST_KEYS_SENT=1 _pty_run /bin/bash "$launcher_script" > "$TEST_TMPDIR/launcher-output" 2>&1
    assert_file_exists "$CS_TEST_PROBE/codex-ran" "Codex ran: $(cat "$TEST_TMPDIR/launcher-output")" || return 1
    assert_file_exists "$CS_TEST_PROBE/flushed" "keys cs sent were left in the terminal's input" || return 1
}

# A terminal that will not take simulated input gets no watcher, and the
# launch says why before Codex starts, rather than the turn promising a count.
test_a_refused_probe_starts_no_watcher_and_says_why() {
    local launcher_script="$TEST_TMPDIR/launch.sh"
    _autoclear_launch_fixture
    CS_TEST_PROBE_REFUSES="legacy_tiocsti is 0" _pty_run /bin/bash "$launcher_script" > "$TEST_TMPDIR/launcher-output" 2>&1
    assert_file_exists "$CS_TEST_PROBE/codex-ran" "Codex ran: $(cat "$TEST_TMPDIR/launcher-output")" || return 1
    assert_not_exists "$CS_TEST_PROBE/watch-pid" "a watcher started where it cannot type" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/launcher-output")" \
        "cs: no automatic /clear after a rotation: legacy_tiocsti is 0" || return 1
}

# The refusal is kept in session.log too, where the rest of the automatic
# /clear's story is.
test_a_failed_probe_is_logged() {
    local launcher_script="$TEST_TMPDIR/launch.sh"
    _autoclear_launch_fixture
    CS_TEST_PROBE_REFUSES="legacy_tiocsti is 0" _pty_run /bin/bash "$launcher_script" > "$TEST_TMPDIR/launcher-output" 2>&1
    assert_file_exists "$CS_TEST_PROBE/codex-ran" "Codex ran: $(cat "$TEST_TMPDIR/launcher-output")" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/session.log" \
        "Automatic /clear is off for this run: legacy_tiocsti is 0" || return 1
}

# Without a terminal there is nothing to type into, so no watcher starts.
test_no_autoclear_watcher_without_a_terminal() {
    local launcher_script="$TEST_TMPDIR/launch.sh"
    _autoclear_launch_fixture
    /bin/bash "$launcher_script" > "$TEST_TMPDIR/launcher-output" 2>&1 < /dev/null
    assert_file_exists "$CS_TEST_PROBE/codex-ran" "Codex ran: $(cat "$TEST_TMPDIR/launcher-output")" || return 1
    assert_not_exists "$CS_TEST_PROBE/watch-pid" "no terminal, no watcher" || return 1
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

test_fresh_acknowledgment_keeps_rotated_and_started_after_a_torn_tail() {
    local old_id=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa output status=0 events
    local timeline="$CS_TEST_SESSION_DIR/.cs/timeline.jsonl"
    printf '%s\n' "$old_id" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    printf '{"event":"torn"' > "$timeline"

    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?

    assert_eq 0 "$status" "fresh acknowledgment failed: $output" || return 1
    events=$(jq -cRs '[split("\n")[] | fromjson? | select(.engine == "codex")]' "$timeline")
    assert_eq 'rotated,started' "$(jq -r 'map(.event) | join(",")' <<< "$events")" \
        "both acknowledged events remain readable after the torn record" || return 1
    assert_eq "$old_id" "$(jq -r '.[0].from' <<< "$events")" "rotation keeps the prior binding" || return 1
    assert_eq "$CS_THREAD_ID" "$(jq -r '.[0].to' <<< "$events")" "rotation records the acknowledged candidate" || return 1
    assert_eq "$CS_THREAD_ID" "$(jq -r '.[1].session_id' <<< "$events")" "the new conversation has a readable start" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-binding-codex.json" \
        "durable lineage clears the transition's recovery record" || return 1
}

test_first_acknowledgment_keeps_started_after_a_torn_tail() {
    local output status=0 events timeline="$CS_TEST_SESSION_DIR/.cs/timeline.jsonl"
    printf '{"event":"torn"' > "$timeline"

    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?

    assert_eq 0 "$status" "first acknowledgment failed: $output" || return 1
    events=$(jq -cRs '[split("\n")[] | fromjson? | select(.engine == "codex")]' "$timeline")
    assert_eq started "$(jq -r 'map(.event) | join(",")' <<< "$events")" \
        "a first start remains readable without a rotation to terminate the torn record" || return 1
    assert_eq "$CS_THREAD_ID" "$(jq -r '.[0].session_id' <<< "$events")" "the acknowledged thread is recorded" || return 1
    assert_eq fresh "$(jq -r '.[0].source' <<< "$events")" "the event identifies a fresh conversation" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-binding-codex.json" \
        "the durable start clears the transition's recovery record" || return 1
}

test_resume_acknowledgment_keeps_started_after_a_torn_tail() {
    local output status=0 events timeline="$CS_TEST_SESSION_DIR/.cs/timeline.jsonl"
    printf '%s\n' "$CS_THREAD_ID" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    printf '{"event":"torn"' > "$timeline"

    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?

    assert_eq 0 "$status" "resume acknowledgment failed: $output" || return 1
    events=$(jq -cRs '[split("\n")[] | fromjson? | select(.engine == "codex")]' "$timeline")
    assert_eq started "$(jq -r 'map(.event) | join(",")' <<< "$events")" \
        "a resumed start remains readable after the torn record" || return 1
    assert_eq "$CS_THREAD_ID" "$(jq -r '.[0].session_id' <<< "$events")" "the resumed thread is recorded" || return 1
    assert_eq resume "$(jq -r '.[0].source' <<< "$events")" "the event identifies a resumed conversation" || return 1
}

_assert_timeline_failure_keeps_pending_binding() {  # previous native id, or empty for first open
    local previous="$1" output status=0 outside="$TEST_TMPDIR/outside-timeline.jsonl"
    local pending="$CS_TEST_SESSION_DIR/.cs/local/pending-binding-codex.json"
    if [ -n "$previous" ]; then
        printf '%s\n' "$previous" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    fi
    printf '{"event":"outside"' > "$outside"
    ln -s "$outside" "$CS_TEST_SESSION_DIR/.cs/timeline.jsonl"

    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?

    assert_eq 1 "$status" "refused lineage append must fail acknowledgment: $output" || return 1
    assert_output_contains "$output" 'prior transition remains recoverable' "the failure explains recovery" || return 1
    assert_file_exists "$pending" "the transition remains available for recovery" || return 1
    assert_eq "$previous" "$(jq -r '.previous_id' "$pending")" "recovery preserves the previous binding" || return 1
    assert_eq "$CS_THREAD_ID" "$(jq -r '.candidate_id' "$pending")" "recovery records the acknowledged candidate" || return 1
    assert_eq '{"event":"outside"' "$(cat "$outside")" "neither repair nor append writes through the link" || return 1
    assert_not_exists "$CS_CODEX_LOG" "the interactive CLI waits for durable acknowledgment" || return 1
}

test_refused_rotated_append_keeps_the_pending_binding() {
    _assert_timeline_failure_keeps_pending_binding aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
}

test_refused_started_append_keeps_the_pending_binding() {
    _assert_timeline_failure_keeps_pending_binding ""
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
        "$(sed -n '7p' "$CS_CODEX_LOG")" "codex resume gets the kick as its starting prompt" || return 1
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
    assert_eq 6 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
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
    assert_eq 6 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
}

# Claude's fresh launch consumes an armed marker at SessionStart; an explicit
# Codex --fresh does the same through the launch.
test_explicit_fresh_continues_an_armed_rotation() {
    _rotation_fixture unconsumed
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?
    assert_eq 0 "$status" "fresh launch failed: $output" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^consumed_by: $CS_THREAD_ID$" || return 1
    assert_output_contains "$(sed -n '7p' "$CS_CODEX_LOG")" "$ROTATION_HANDOFF" "kicked from the handoff" || return 1
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

# The scoped profile is written before a thread is bound or a handoff spent,
# so a Codex home that refuses it leaves both for the retry.
_refused_profile_spends_nothing() {
    local intent output status
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    local h="$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF"
    for intent in handoff fresh; do
        _rotation_fixture unconsumed
        status=0
        output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" "$intent" 2>&1) || status=$?
        assert_eq 1 "$status" "$intent: $output" || return 1
        assert_output_contains "$output" 'Could not prepare the scoped Codex model profile' || return 1
        assert_file_contains "$h" '^status: unconsumed$' "$intent keeps the handoff" || return 1
        assert_file_not_contains "$h" '^consumed_by:' || return 1
        assert_eq "$ROTATION_HANDOFF" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" 2>/dev/null)" "$intent keeps the marker" || return 1
        assert_eq "$ROTATION_OLD_THREAD" "$(cat "$binding")" "$intent keeps the binding" || return 1
        assert_not_exists "$CS_HELPER_COUNT" "$intent prepares no thread" || return 1
        assert_not_exists "$CS_CODEX_LOG" "$intent starts no CLI" || return 1
        assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
    done
    # A fresh start with nothing armed binds nothing either.
    rm -f "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" "$h"
    status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?
    assert_eq 1 "$status" "fresh: $output" || return 1
    assert_eq "$ROTATION_OLD_THREAD" "$(cat "$binding")" "fresh keeps the binding" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "fresh prepares no thread" || return 1
    assert_not_exists "$CS_CODEX_LOG" "fresh starts no CLI" || return 1
}

test_a_refused_rotation_profile_spends_nothing() {
    export CS_CODEX_HELP=$'--approve-for-me\n-p, --profile <CONFIG_PROFILE_V2>'
    local status=0
    mkdir -p "$HOME/.codex" && chmod 500 "$HOME/.codex"
    _refused_profile_spends_nothing || status=$?
    chmod 700 "$HOME/.codex"
    return "$status"
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
    assert_eq 6 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
}

echo 'Codex launch tests'
run_test test_unsupported_codex_first_open_does_not_prepare_a_thread
run_test test_unsupported_codex_preserves_bound_launches_and_handoffs
run_test test_failed_codex_help_cannot_advertise_compatibility
run_test test_codex_help_prose_is_not_an_approval_option
run_test test_rotation_profile_seeds_launch_choices_without_pinning_them
run_test test_an_explicit_choice_a_trusted_project_sets_stays_on_the_command_line
run_test test_unknown_project_settings_keep_explicit_choices_on_the_command_line
run_test test_native_approval_launches_without_automatic_approval_support
run_test test_fresh_acknowledgment_keeps_rotated_and_started_after_a_torn_tail
run_test test_first_acknowledgment_keeps_started_after_a_torn_tail
run_test test_resume_acknowledgment_keeps_started_after_a_torn_tail
run_test test_refused_rotated_append_keeps_the_pending_binding
run_test test_refused_started_append_keeps_the_pending_binding
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
run_test test_a_refused_rotation_profile_spends_nothing
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
run_test test_autoclear_watcher_lives_exactly_as_long_as_codex
run_test test_no_autoclear_watcher_without_a_terminal
run_test test_the_launch_flushes_input_only_after_typing
run_test test_a_refused_probe_starts_no_watcher_and_says_why
run_test test_a_failed_probe_is_logged
report_results
