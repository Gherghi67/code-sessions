#!/usr/bin/env bash
# ABOUTME: Exercises runtime selection, precedence, and dependency isolation through cs.
# ABOUTME: Uses temporary fake engines and Codex helper to avoid real launches.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CS_TRANSCRIPTS_DIR="$TEST_TMPDIR/claude-projects"
    export CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1
    export CS_NO_FUNCTION_HOOKS=1
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/claude"
    export CODEX_BIN="$TEST_TMPDIR/bin/codex"
    export CS_CODEX_THREAD_BIN="$TEST_TMPDIR/bin/cs-codex-thread"
    export CS_CLAUDE_ARGV="$TEST_TMPDIR/claude-argv" CS_CODEX_ARGV="$TEST_TMPDIR/codex-argv"
    export CS_CLAUDE_LOG="$TEST_TMPDIR/claude.log"
    export CS_CLAUDE_ENV="$TEST_TMPDIR/claude.env"
    export CS_CODEX_LOG="$TEST_TMPDIR/codex.log"
    export CS_HELPER_LOG="$TEST_TMPDIR/helper.log"
    export CS_TEST_START_HOOK="$SCRIPT_DIR/../hooks/session-start.sh"
    mkdir -p "$HOME" "$CS_SESSIONS_ROOT" "$CS_TRANSCRIPTS_DIR" "$TEST_TMPDIR/bin"

    cat > "$CLAUDE_CODE_BIN" <<'CLAUDE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CS_CLAUDE_LOG"
printf '%s\n' "$@" > "$CS_CLAUDE_ARGV"
env | grep -E '^(CS_SESSION_|CLAUDE_SESSION_|CLAUDE_SECURESTORAGE_CONFIG_DIR=)' > "$CS_CLAUDE_ENV"
uuid=""
while [ "$#" -gt 0 ]; do
    case "$1" in --session-id|--resume) uuid="$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "$uuid" ]; then
    jq -nc --arg session_id "$uuid" --arg cwd "$CS_SESSION_DIR" \
        '{session_id:$session_id,cwd:$cwd,source:"startup"}' \
        | CLAUDE_PID=$$ bash "$CS_TEST_START_HOOK" >/dev/null
fi
exit 0
CLAUDE
    cat > "$CODEX_BIN" <<'CODEX'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
    printf '      --approve-for-me\n'
    exit 0
fi
printf '%s\n' "$*" >> "$CS_CODEX_LOG"
printf '%s\n' "$@" > "$CS_CODEX_ARGV"
exit 0
CODEX
    # The carry-over's conversions run the real helper (no app-server in them);
    # a thread start stays stubbed, and one that carries a Claude conversation
    # gets its own ID, or fails when CS_HELPER_FAIL_CARRY is set.
    export CS_REAL_THREAD_HELPER="$SCRIPT_DIR/../bin/cs-codex-thread"
    cat > "$CS_CODEX_THREAD_BIN" <<'HELPER'
#!/usr/bin/env bash
case " $* " in
    *" --export-claude "*|*" --read-claude "*)
        printf '%s\n' "$*" >> "$CS_HELPER_LOG.real"
        [ -n "${CS_HELPER_SWAP_STAGED:-}" ] || exec python3 "$CS_REAL_THREAD_HELPER" "$@"
        # The converted transcript swapped for a link while the question waits.
        python3 "$CS_REAL_THREAD_HELPER" "$@" || exit
        while [ "$#" -gt 1 ] && [ "$1" != --out ]; do shift; done
        [ "$1" != --out ] || ln -sf "$CS_HELPER_SWAP_STAGED" "$2"
        exit 0
        ;;
esac
printf '%s\n' "$*" >> "$CS_HELPER_LOG"
thread_id=${CS_HELPER_FRESH_ID:-12345678-1234-1234-1234-123456789abc}
while [ "$#" -gt 0 ]; do
    if [ "$1" = --thread-id ]; then
        thread_id="$2"
        shift 2
    elif [ "$1" = --history-from-claude ]; then
        if [ -n "${CS_HELPER_FAIL_CARRY:-}" ]; then
            printf 'cs-codex-thread: codex app-server rejected thread/inject_items\n' >&2
            exit 1
        fi
        thread_id=87654321-4321-4321-4321-cba987654321
        shift 2
    else
        shift
    fi
done
printf '%s\n' "$thread_id"
HELPER
    chmod +x "$CLAUDE_CODE_BIN" "$CODEX_BIN" "$CS_CODEX_THREAD_BIN"
    unset XDG_CONFIG_HOME
    unset CS_DEFAULT_ENGINE CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CS_LEAD_PID CLAUDE_PID
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CS_TRANSCRIPTS_DIR CS_NO_UPDATE_CHECK CS_NO_ITERM2
    unset CS_NO_FUNCTION_HOOKS CLAUDE_CODE_BIN CODEX_BIN CS_CODEX_THREAD_BIN
    unset CS_CLAUDE_LOG CS_CLAUDE_ENV CS_CODEX_LOG CS_HELPER_LOG CS_DEFAULT_ENGINE
    unset CS_REAL_THREAD_HELPER CS_HELPER_FAIL_CARRY CS_HELPER_FRESH_ID CS_HELPER_SWAP_STAGED CS_ASSUME_TTY
}

_engine_session_dir() {
    printf '%s/%s\n' "$CS_SESSIONS_ROOT" "$1"
}

test_invalid_engine_values_fail_before_session_creation() {
    local output status=0
    output=$("$CS_BIN" invalid-engine --engine 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: missing engine value should fail'; return 1; }
    assert_output_contains "$output" '--engine needs claude, codex or antigravity' "missing-value diagnostic" || return 1
    assert_not_exists "$(_engine_session_dir invalid-engine)" "missing value must not create a session" || return 1

    status=0
    output=$("$CS_BIN" invalid-engine --engine=wat 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: unknown engine should fail'; return 1; }
    assert_output_contains "$output" '--engine needs claude, codex or antigravity' "unknown-value diagnostic" || return 1
    assert_not_exists "$(_engine_session_dir invalid-engine)" "invalid value must not create a session" || return 1
}

test_default_launch_remains_claude() {
    local output status=0 session_dir
    output=$("$CS_BIN" old-session 2>&1) || status=$?
    session_dir=$(_engine_session_dir old-session)
    assert_eq 0 "$status" "default launch failed: $output" || return 1
    assert_file_contains "$CS_CLAUDE_LOG" 'session-id' "legacy default launches Claude" || return 1
    assert_file_not_exists "$CS_CODEX_LOG" "default launch must not start Codex" || return 1
    assert_file_contains "$session_dir/.cs/local/state" 'engine: claude' "Claude preference recorded" || return 1
    assert_file_contains "$CS_CLAUDE_ENV" '^CS_SESSION_NAME=old-session$' "Claude receives neutral session identity" || return 1
    assert_file_contains "$CS_CLAUDE_ENV" "^CS_SESSION_DIR=$session_dir$" "Claude receives neutral workspace" || return 1
    assert_file_contains "$CS_CLAUDE_ENV" "^CS_SESSION_META_DIR=$session_dir/.cs$" "Claude receives neutral metadata" || return 1
    assert_file_contains "$CS_CLAUDE_ENV" '^CLAUDE_SESSION_NAME=old-session$' "Claude retains legacy identity alias" || return 1
}

test_environment_default_selects_codex() {
    local output status=0 session_dir
    export CS_DEFAULT_ENGINE=codex
    # Codex selection must not require the Claude executable to exist.
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/no-claude"
    output=$("$CS_BIN" codex-default 2>&1) || status=$?
    session_dir=$(_engine_session_dir codex-default)
    assert_eq 0 "$status" "Codex default launch failed: $output" || return 1
    assert_file_contains "$CS_CODEX_LOG" 'resume 12345678-1234-1234-1234-123456789abc' "environment default launches Codex" || return 1
    assert_file_contains "$session_dir/.cs/local/state" 'engine: codex' "Codex preference recorded" || return 1
    assert_file_not_exists "$CS_CLAUDE_LOG" "Codex launch must not invoke Claude" || return 1
}

test_stored_engine_wins_and_explicit_claude_keeps_codex_binding() {
    local output status=0 session_dir binding thread_id
    export CS_DEFAULT_ENGINE=codex
    output=$("$CS_BIN" remembered 2>&1) || status=$?
    session_dir=$(_engine_session_dir remembered)
    binding="$session_dir/.cs/local/codex-thread-id"
    assert_eq 0 "$status" "initial Codex launch failed: $output" || return 1
    thread_id=$(cat "$binding")

    # A saved Codex preference overrides the environment default. Then an
    # explicit Claude launch overrides that choice without deleting Codex's
    # independent native conversation binding.
    export CS_DEFAULT_ENGINE=claude
    output=$("$CS_BIN" remembered 2>&1) || status=$?
    assert_eq 0 "$status" "saved preference launch failed: $output" || return 1
    assert_eq 2 "$(wc -l < "$CS_HELPER_LOG" | tr -d ' ')" "stored Codex preference selected" || return 1

    status=0
    output=$(printf 'n\n' | "$CS_BIN" remembered --engine=claude 2>&1) || status=$?
    assert_eq 0 "$status" "explicit Claude override failed: $output" || return 1
    assert_file_contains "$CS_CLAUDE_LOG" 'session-id' "explicit option launches Claude" || return 1
    assert_eq "$thread_id" "$(cat "$binding")" "Claude override preserves Codex binding" || return 1
    assert_file_contains "$session_dir/.cs/local/state" 'engine: claude' "successful explicit choice becomes preference" || return 1
}

test_explicit_codex_works_without_claude_and_claude_without_codex() {
    local output status=0
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/no-claude"
    output=$("$CS_BIN" only-codex --engine codex 2>&1) || status=$?
    assert_eq 0 "$status" "Codex should not require Claude: $output" || return 1
    assert_file_contains "$CS_CODEX_LOG" 'resume 12345678-1234-1234-1234-123456789abc' "Codex launch succeeded" || return 1

    export CODEX_BIN="$TEST_TMPDIR/bin/no-codex"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/claude"
    status=0
    output=$("$CS_BIN" only-claude --engine claude 2>&1) || status=$?
    assert_eq 0 "$status" "Claude should not require Codex: $output" || return 1
    assert_file_contains "$CS_CLAUDE_LOG" 'session-id' "Claude launch succeeded" || return 1
    assert_not_exists "$(_engine_session_dir only-claude)/.cs/local/codex-thread-id" "Claude launch must not bind Codex" || return 1
}

# -finish opens the base under Codex on the finish skill, named the way Codex
# takes a skill from the user, as Claude's opens on /finish <task>.
test_codex_finish_starts_the_thread_on_the_finish_skill() {
    local output status=0
    create_test_session_with_git base >/dev/null
    "$CS_BIN" base@feature --engine claude < /dev/null > /dev/null 2>&1 || true
    [ -d "$(_engine_session_dir base@feature)" ] || { echo '  FAIL: feature fixture'; return 1; }
    output=$("$CS_BIN" base --engine codex -finish feature < /dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "Codex -finish launches: $output" || return 1
    assert_file_contains "$CS_CODEX_LOG" 'resume 12345678-1234-1234-1234-123456789abc -C .* --approve-for-me \$finish feature$' \
        "the thread starts on \$finish feature" || return 1
}

# The feature check runs before anything starts, under Codex as under Claude.
test_codex_finish_of_an_unknown_feature_starts_nothing() {
    local output status=0
    create_test_session_with_git base >/dev/null
    output=$("$CS_BIN" base --engine codex -finish nope < /dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: an unknown feature was accepted'; return 1; }
    assert_output_contains "$output" "No feature worktree 'nope' of 'base'" || return 1
    assert_file_not_exists "$CS_HELPER_LOG" "no Codex thread for an unknown feature" || return 1
    assert_file_not_exists "$CS_CODEX_LOG" "Codex never started" || return 1
}

_assert_codex_only_workspace() {
    assert_not_exists "$1/CLAUDE.local.md" "Codex must not write Claude instructions" || return 1
    assert_not_exists "$1/.claude" "Codex must not configure Claude" || return 1
    assert_file_not_contains "$1/.cs/local/state" 'claude_session_' "Codex must not allocate Claude identity" || return 1
    [ -d "$1/.cs/memory" ] && [ -d "$1/.cs/plans" ] \
        || { echo "  FAIL: portable memory and plans storage is missing"; return 1; }
}

test_codex_create_and_resume_do_not_prepare_claude() {
    local output session_dir
    output=$("$CS_BIN" neutral --engine codex 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir neutral)
    _assert_codex_only_workspace "$session_dir" || return 1
    output=$("$CS_BIN" neutral 2>&1) || { echo "$output"; return 1; }
    _assert_codex_only_workspace "$session_dir" || return 1
    assert_not_exists "$HOME/.claude" "Codex must not touch native Claude memory"
}

test_codex_adopt_preserves_user_instructions_and_configuration() {
    local project="$TEST_TMPDIR/project" output
    mkdir -p "$project/.claude"
    printf 'User agents\n' > "$project/AGENTS.md"
    printf 'User Claude\n' > "$project/CLAUDE.md"
    printf 'User local Claude\n' > "$project/CLAUDE.local.md"
    printf '{"custom":true}\n' > "$project/.claude/settings.local.json"
    output=$(cd "$project" && "$CS_BIN" -adopt adopted --engine codex 2>&1) || { echo "$output"; return 1; }
    assert_eq 'User agents' "$(cat "$project/AGENTS.md")" || return 1
    assert_eq 'User Claude' "$(cat "$project/CLAUDE.md")" || return 1
    assert_eq 'User local Claude' "$(cat "$project/CLAUDE.local.md")" || return 1
    assert_eq '{"custom":true}' "$(cat "$project/.claude/settings.local.json")" || return 1
    assert_file_not_contains "$project/.cs/local/state" 'claude_session_' || return 1
    output=$("$CS_BIN" adopted 2>&1) || { echo "$output"; return 1; }
    assert_eq 'User local Claude' "$(cat "$project/CLAUDE.local.md")" || return 1
    assert_eq '{"custom":true}' "$(cat "$project/.claude/settings.local.json")"
}

test_codex_worktree_then_claude_prepares_only_on_switch() {
    local output base feature
    output=$("$CS_BIN" tree-base --engine codex 2>&1) || { echo "$output"; return 1; }
    base=$(_engine_session_dir tree-base)
    output=$("$CS_BIN" tree-base@worker --engine codex 2>&1) || { echo "$output"; return 1; }
    feature=$(_engine_session_dir tree-base@worker)
    _assert_codex_only_workspace "$feature" || return 1
    output=$(printf 'n\n' | "$CS_BIN" tree-base@worker --engine claude 2>&1) || { echo "$output"; return 1; }
    assert_file_exists "$feature/CLAUDE.local.md" || return 1
    assert_file_exists "$feature/.claude/settings.local.json" || return 1
    assert_file_contains "$feature/.cs/local/state" 'claude_session_id:' || return 1
    assert_file_exists "$feature/.cs/local/codex-thread-id" || return 1
    _assert_codex_only_workspace "$base"
}

test_neutral_session_environment_drives_shared_commands() {
    local output session_dir
    output=$("$CS_BIN" ambient --engine codex 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir ambient)
    output=$(env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR \
        CS_SESSION_NAME=ambient CS_SESSION_DIR="$session_dir" CS_SESSION_META_DIR="$session_dir/.cs" \
        "$CS_BIN" -status 'Working with Codex' 2>&1) || { echo "$output"; return 1; }
    assert_eq 'Working with Codex' "$(cat "$session_dir/.cs/local/presence")" || return 1
    printf 'neutral-actor\n' > "$session_dir/.cs/local/identity"
    output=$(env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR \
        CS_SESSION_NAME=ambient CS_SESSION_DIR="$session_dir" CS_SESSION_META_DIR="$session_dir/.cs" \
        "$CS_BIN" -whoami 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" 'actor: neutral-actor' 
}

test_sole_installed_codex_adapter_is_default() {
    local output
    export XDG_CONFIG_HOME="$TEST_TMPDIR/config"
    mkdir -p "$HOME/.local/bin"
    printf 'codex\n' > "$HOME/.local/bin/.cs-install-engines"
    output=$("$CS_BIN" installed-default 2>&1) || { echo "$output"; return 1; }
    _assert_codex_only_workspace "$(_engine_session_dir installed-default)" || return 1
    unset XDG_CONFIG_HOME
}

test_sole_installed_codex_adapter_is_read_from_the_install_dir() {
    local output
    export XDG_CONFIG_HOME="$TEST_TMPDIR/config"
    # The profile launcher names its own install dir while HOME stays the
    # user's: the stable install's record (claude) must not decide the engine.
    mkdir -p "$HOME/.local/bin" "$TEST_TMPDIR/profile-bin"
    printf 'claude\n' > "$HOME/.local/bin/.cs-install-engines"
    printf 'codex\n' > "$TEST_TMPDIR/profile-bin/.cs-install-engines"
    output=$(CS_INSTALL_DIR="$TEST_TMPDIR/profile-bin" "$CS_BIN" profile-default 2>&1) || { echo "$output"; return 1; }
    _assert_codex_only_workspace "$(_engine_session_dir profile-default)" || return 1
    unset XDG_CONFIG_HOME
}

test_codex_doctor_reports_capability_gaps_without_claude_checks() {
    local output session_dir
    output=$("$CS_BIN" diagnostics --engine codex 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir diagnostics)
    output=$(CS_SESSION_DIR="$session_dir" CS_SESSION_META_DIR="$session_dir/.cs" "$CS_BIN" -doctor 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" 'Codex integration capabilities' || return 1
    assert_output_contains "$output" 'usage observations are unavailable' || return 1
    if [[ "$output" == *'settings.json'* || "$output" == *'hooks not registered'* ]]; then
        echo '  FAIL: Codex diagnostics requested Claude configuration'; return 1
    fi
}

test_claude_adoption_preserves_user_local_instructions() {
    local project="$TEST_TMPDIR/claude-project" output
    mkdir -p "$project"
    printf 'User local instructions\n' > "$project/CLAUDE.local.md"
    printf 'User agents\n' > "$project/AGENTS.md"
    output=$(cd "$project" && "$CS_BIN" -adopt claude-adopted --engine claude 2>&1) || { echo "$output"; return 1; }
    assert_file_contains "$project/CLAUDE.local.md" '^User local instructions$' || return 1
    assert_file_contains "$project/CLAUDE.local.md" 'cs:session-protocol' || return 1
    assert_eq 'User agents' "$(cat "$project/AGENTS.md")"
}

test_engine_roundtrip_resumes_each_acknowledged_binding() {
    local output session_dir claude_id codex_id
    output=$("$CS_BIN" roundtrip --engine claude 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir roundtrip)
    claude_id=$(awk '/^claude_session_id:/ {print $2; exit}' "$session_dir/.cs/local/state")
    output=$("$CS_BIN" roundtrip --engine codex 2>&1) || { echo "$output"; return 1; }
    codex_id=$(cat "$session_dir/.cs/local/codex-thread-id")
    output=$("$CS_BIN" roundtrip --engine claude --resume </dev/null 2>&1) || { echo "$output"; return 1; }
    assert_eq "--name roundtrip --resume $claude_id" "$(tail -1 "$CS_CLAUDE_LOG" | sed 's@ /color.*@@')" "returning Claude resumes its exact ID" || return 1
    output=$("$CS_BIN" roundtrip --engine codex --resume </dev/null 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$(tail -1 "$CS_HELPER_LOG")" "--thread-id $codex_id" "returning Codex refreshes its exact ID" || return 1
    assert_eq "$claude_id" "$(awk '/^claude_session_id:/ {print $2; exit}' "$session_dir/.cs/local/state")" "engine switches preserve Claude identity" || return 1
    assert_eq "$codex_id" "$(cat "$session_dir/.cs/local/codex-thread-id")" "engine switches preserve Codex identity" || return 1
}

test_launch_intent_flags_validate_before_creation() {
    local output status=0
    output=$("$CS_BIN" missing --fresh --resume 2>&1) || status=$?
    assert_eq 1 "$status" "conflicting intent rejected" || return 1
    assert_output_contains "$output" '--fresh and --resume cannot be combined' || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/missing" "conflicting flags do not create session" || return 1
    status=0
    output=$("$CS_BIN" missing --engine codex --resume 2>&1) || status=$?
    assert_eq 1 "$status" "missing session resume rejected" || return 1
    assert_output_contains "$output" 'does not exist' || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/missing" "resume does not create workspace" || return 1
}

test_resume_missing_binding_does_not_migrate_or_allocate() {
    local output status=0 session_dir="$CS_SESSIONS_ROOT/unbound"
    mkdir -p "$session_dir/.cs/local"
    printf 'engine: codex\n' > "$session_dir/.cs/local/state"
    output=$("$CS_BIN" unbound --engine claude --resume 2>&1) || status=$?
    assert_eq 1 "$status" "missing binding resume rejected" || return 1
    assert_output_contains "$output" 'no recorded claude conversation' || return 1
    assert_file_not_contains "$session_dir/.cs/local/state" 'claude_session_id:' "no migration allocation" || return 1
    assert_not_exists "$session_dir/CLAUDE.local.md" "no native preparation" || return 1
}

test_launch_options_survive_fresh_and_resumed_engines() {
    local model='provider/model with spaces $(literal)' output dir
    output=$("$CS_BIN" choices --engine claude --model "$model" --effort high --approve-for-me 2>&1) || {
        echo "  FAIL: Claude options launch: $output"; return 1;
    }
    assert_eq "$model" "$(sed -n '2p' "$CS_CLAUDE_ARGV")" "model is one literal argument" || return 1
    assert_file_contains "$CS_CLAUDE_ARGV" '^--effort$' || return 1
    assert_file_contains "$CS_CLAUDE_ARGV" '^auto$' || return 1
    output=$("$CS_BIN" choices --resume --model "$model" --effort medium 2>&1) || return 1
    assert_file_contains "$CS_CLAUDE_ARGV" '^--resume$' || return 1
    assert_file_contains "$CS_CLAUDE_ARGV" '^medium$' || return 1
    assert_file_not_contains "$CS_CLAUDE_ARGV" '^--permission-mode$' || return 1
    output=$("$CS_BIN" choices --fresh --model "$model" --effort low 2>&1) || return 1
    assert_eq "$model" "$(sed -n '2p' "$CS_CLAUDE_ARGV")" "fresh rebind takes selected model" || return 1
    output=$("$CS_BIN" choices --engine codex --model "$model" --effort xhigh 2>&1) || return 1
    assert_file_contains "$CS_CODEX_ARGV" '^--approve-for-me$' || return 1
    assert_file_contains "$CS_CODEX_ARGV" '^model_reasoning_effort="xhigh"$' || return 1
    assert_eq "$model" "$(sed -n '7p' "$CS_CODEX_ARGV")" "Codex model is one literal argument" || return 1
    output=$("$CS_BIN" choices --engine codex --resume --native-approval 2>&1) || return 1
    assert_file_not_contains "$CS_CODEX_ARGV" '^--approve-for-me$' || return 1
}

test_invalid_launch_options_do_not_create_workspace() {
    local output status=0
    output=$("$CS_BIN" invalid-model --model '' 2>&1) || status=$?
    [ "$status" -ne 0 ] || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/invalid-model" || return 1
    status=0
    output=$("$CS_BIN" invalid-model --model $'some\nmodel' 2>&1) || status=$?
    [ "$status" -ne 0 ] || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/invalid-model" || return 1
}

test_profile_reopen_refreshes_login_without_overwriting_preferences() {
    local profile="$TEST_TMPDIR/profile" output
    mkdir -p "$profile/.claude"
    mkdir -p "$HOME/.claude"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"selected"},"projects":{"default":1}}' > "$HOME/.claude/.config.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"stale-default"}}' > "$HOME/.claude.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"stale"},"theme":"profile","projects":{"own":2}}' > "$profile/.claude/.claude.json"
    output=$(CODE_SESSIONS_HOME="$profile" CLAUDE_CONFIG_DIR="$profile/.claude" CLAUDE_SECURESTORAGE_CONFIG_DIR='' \
        "$CS_BIN" profile-login --engine claude 2>&1) || { echo "$output"; return 1; }
    assert_eq selected "$(jq -r .oauthAccount.accountUuid "$profile/.claude/.claude.json")" || return 1
    assert_eq profile "$(jq -r .theme "$profile/.claude/.claude.json")" || return 1
    assert_eq '{"own":2}' "$(jq -c .projects "$profile/.claude/.claude.json")" || return 1
}

# A code-sessions launch that did not come through the current launcher (a
# feature or tmux window opened from a session an older launcher started)
# arrives without CLAUDE_SECURESTORAGE_CONFIG_DIR. Claude would then file its
# login under the profile's own keychain entry, which the Agents sidebar's
# switch never writes, so the session would stay on the old account.
test_profile_launch_without_the_variable_shares_the_default_login() {
    local profile="$TEST_TMPDIR/profile" output
    mkdir -p "$profile/.claude"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"switched"}}' > "$HOME/.claude.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"stale"},"theme":"profile"}' > "$profile/.claude/.claude.json"
    output=$(env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CODE_SESSIONS_HOME="$profile" CLAUDE_CONFIG_DIR="$profile/.claude" \
        "$CS_BIN" profile-unset --engine claude 2>&1) || { echo "$output"; return 1; }
    assert_file_contains "$CS_CLAUDE_ENV" '^CLAUDE_SECURESTORAGE_CONFIG_DIR=$' \
        "Claude gets the default credential entry" || return 1
    assert_eq switched "$(jq -r .oauthAccount.accountUuid "$profile/.claude/.claude.json")" || return 1
    assert_eq profile "$(jq -r .theme "$profile/.claude/.claude.json")" || return 1
}

test_profile_launch_keeps_a_chosen_credential_dir() {
    local profile="$TEST_TMPDIR/profile" output
    mkdir -p "$profile/.claude"
    output=$(CODE_SESSIONS_HOME="$profile" CLAUDE_CONFIG_DIR="$profile/.claude" \
        CLAUDE_SECURESTORAGE_CONFIG_DIR="$TEST_TMPDIR/own-login" \
        "$CS_BIN" profile-chosen --engine claude 2>&1) || { echo "$output"; return 1; }
    assert_file_contains "$CS_CLAUDE_ENV" "^CLAUDE_SECURESTORAGE_CONFIG_DIR=$TEST_TMPDIR/own-login\$" || return 1
}

test_original_launch_leaves_the_credential_dir_alone() {
    local output
    output=$(env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CODE_SESSIONS_HOME -u CLAUDE_CONFIG_DIR \
        "$CS_BIN" original-unset --engine claude 2>&1) || { echo "$output"; return 1; }
    assert_file_not_contains "$CS_CLAUDE_ENV" '^CLAUDE_SECURESTORAGE_CONFIG_DIR=' || return 1
}

# Both native bindings exist, but the feature was last used with Claude and
# the base with Codex. A collision redirect must carry only an explicit engine
# override; otherwise the feature's own preference decides what opens.
_collision_engine_fixture() {
    local output base feature
    output=$("$CS_BIN" collision-base --engine codex 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" collision-base@feature --engine codex 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" collision-base@feature --engine claude --fresh 2>&1) || { echo "$output"; return 1; }
    base=$(_engine_session_dir collision-base)
    feature=$(_engine_session_dir collision-base@feature)
    assert_file_contains "$feature/.cs/local/state" '^engine: claude$' || return 1
    assert_file_exists "$feature/.cs/local/codex-thread-id" || return 1
    assert_file_contains "$feature/.cs/local/state" '^claude_session_id:' || return 1
    printf '%s\n' "$$" > "$base/.cs/session.lock"
    rm -f "$CS_CLAUDE_LOG" "$CS_CODEX_LOG" "$CS_HELPER_LOG"
}

test_collision_resume_preserves_explicit_engine() {
    _collision_engine_fixture || return 1
    local output status=0 feature thread_id
    feature=$(_engine_session_dir collision-base@feature)
    thread_id=$(cat "$feature/.cs/local/codex-thread-id")
    output=$(printf '1' | CS_ASSUME_TTY=1 "$CS_BIN" collision-base --engine codex --resume 2>&1) || status=$?
    assert_eq 0 "$status" "explicit Codex resume redirect failed: $output" || return 1
    assert_file_contains "$CS_CODEX_LOG" "resume $thread_id -C $feature" \
        "the redirect resumes the feature's Codex binding" || return 1
    assert_file_not_exists "$CS_CLAUDE_LOG" "explicit Codex redirect must not launch Claude" || return 1
    assert_output_not_contains "$output" 'Continue previous' "--resume stays unattended after redirect" || return 1
}

test_collision_attended_open_preserves_explicit_engine() {
    _collision_engine_fixture || return 1
    local output status=0 feature thread_id
    feature=$(_engine_session_dir collision-base@feature)
    thread_id=$(cat "$feature/.cs/local/codex-thread-id")
    output=$(printf '1y' | CS_ASSUME_TTY=1 "$CS_BIN" collision-base --engine codex 2>&1) || status=$?
    assert_eq 0 "$status" "attended explicit Codex redirect failed: $output" || return 1
    assert_file_contains "$CS_CODEX_LOG" "resume $thread_id -C $feature" \
        "the attended redirect also selects Codex" || return 1
    assert_file_not_exists "$CS_CLAUDE_LOG" "the attended override must not launch Claude" || return 1
}

test_collision_without_explicit_engine_uses_feature_preference() {
    _collision_engine_fixture || return 1
    local output status=0 feature claude_id
    feature=$(_engine_session_dir collision-base@feature)
    claude_id=$(awk '/^claude_session_id:/ {print $2; exit}' "$feature/.cs/local/state")
    output=$(printf '1' | CS_ASSUME_TTY=1 "$CS_BIN" collision-base --resume 2>&1) || status=$?
    assert_eq 0 "$status" "feature preference redirect failed: $output" || return 1
    assert_file_contains "$CS_CLAUDE_LOG" " --resume $claude_id" \
        "without an override the feature's stored Claude engine wins" || return 1
    assert_file_not_exists "$CS_CODEX_LOG" "the base's resolved Codex preference must not be forwarded" || return 1
}

test_collision_new_feature_preserves_explicit_engine() {
    local output status=0 base feature
    output=$("$CS_BIN" collision-base --engine claude 2>&1) || { echo "$output"; return 1; }
    base=$(_engine_session_dir collision-base)
    printf '%s\n' "$$" > "$base/.cs/session.lock"
    rm -f "$CS_CLAUDE_LOG" "$CS_CODEX_LOG"
    feature=$(_engine_session_dir collision-base@new-feature)
    output=$(printf '2new-feature\n' | CS_ASSUME_TTY=1 "$CS_BIN" collision-base --engine codex 2>&1) || status=$?
    assert_eq 0 "$status" "new feature redirect failed: $output" || return 1
    assert_file_contains "$CS_CODEX_LOG" "resume .* -C $feature" \
        "a new feature keeps the explicit engine" || return 1
    assert_file_not_exists "$CS_CLAUDE_LOG" "new feature must not fall back to Claude" || return 1
}

echo 'Engine selection tests'
# --- Carrying the other engine's newer conversation over (lib/47-transplant.sh) ---

_tp_codex_thread=12345678-1234-1234-1234-123456789abc
_tp_carried_thread=87654321-4321-4321-4321-cba987654321

# A saved Codex history for the stub helper's thread, where the real helper
# finds it (CODEX_HOME defaults to ~/.codex).
_tp_write_rollout() {  # thread_id
    local folder="$HOME/.codex/sessions/2026/11/07"
    mkdir -p "$folder"
    {
        jq -nc '{timestamp:"2026-11-07T10:00:00.000Z",type:"response_item",
                 payload:{type:"message",role:"user",content:[{type:"input_text",text:"what is the codename?"}]}}'
        jq -nc '{timestamp:"2026-11-07T10:00:01.000Z",type:"response_item",
                 payload:{type:"custom_tool_call",name:"exec",call_id:"c1",input:"cat notes.txt"}}'
        jq -nc '{timestamp:"2026-11-07T10:00:02.000Z",type:"response_item",
                 payload:{type:"custom_tool_call_output",call_id:"c1",output:"AMBER-FALCON"}}'
        jq -nc '{timestamp:"2026-11-07T10:00:03.000Z",type:"response_item",
                 payload:{type:"message",role:"assistant",content:[{type:"output_text",text:"The codename is AMBER-FALCON."}]}}'
    } > "$folder/rollout-2026-11-07T10-00-00-$1.jsonl"
}

_tp_project_dir() {  # session_dir
    local resolved
    resolved=$(cd -- "$1" && pwd -P)
    printf '%s/%s\n' "$CS_TRANSCRIPTS_DIR" "${resolved//[^A-Za-z0-9]/-}"
}

# A Claude transcript for the session's bound conversation.
_tp_write_transcript() {  # session_dir, conversation id
    local proj
    proj=$(_tp_project_dir "$1")
    mkdir -p "$proj"
    {
        jq -nc --arg s "$2" '{type:"user",uuid:"u1",parentUuid:null,sessionId:$s,
                 message:{role:"user",content:"find the budget"}}'
        jq -nc --arg s "$2" '{type:"assistant",uuid:"a1",parentUuid:"u1",sessionId:$s,
                 message:{role:"assistant",content:[{type:"text",text:"The budget is 42."}]}}'
    } > "$proj/$2.jsonl"
}

_tp_claude_id() {  # session_dir
    awk '/^claude_session_id:/ {print $2; exit}' "$1/.cs/local/state"
}

# Claude first, then Codex: the Codex thread is the newer conversation.
_tp_claude_then_codex() {  # name
    local output
    output=$("$CS_BIN" "$1" --engine claude </dev/null 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" "$1" --engine codex </dev/null 2>&1) || { echo "$output"; return 1; }
    _tp_write_rollout "$_tp_codex_thread"
}

test_claude_reopen_carries_the_newer_codex_conversation() {
    local output session_dir old_id new_id proj
    _tp_claude_then_codex carry || return 1
    session_dir=$(_engine_session_dir carry)
    old_id=$(_tp_claude_id "$session_dir")
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" carry --engine claude <<< "y" 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "The newest conversation here is Codex's" "the offer names the newer conversation" || return 1
    assert_output_contains "$output" "2 messages" "the offer says how much it carries" || return 1
    assert_output_contains "$output" "resume the earlier Claude conversation instead" "e is offered beside an earlier conversation" || return 1
    assert_output_contains "$output" "Carrying over the Codex conversation" "y says what it carries" || return 1
    new_id=$(_tp_claude_id "$session_dir")
    _is_uuid_shape "$new_id" || { echo "  FAIL: no new Claude binding: $new_id"; return 1; }
    [ "$new_id" != "$old_id" ] || { echo "  FAIL: y kept the earlier Claude conversation"; return 1; }
    assert_eq "--name carry --resume $new_id" "$(tail -1 "$CS_CLAUDE_LOG" | sed 's@ /color.*@@')" "Claude resumes the carried conversation" || return 1
    proj=$(_tp_project_dir "$session_dir")
    assert_file_contains "$proj/$new_id.jsonl" 'The codename is AMBER-FALCON' "the transcript holds the Codex conversation" || return 1
    assert_file_contains "$proj/$new_id.jsonl" "\"sessionId\":\"$new_id\"" "the transcript is the new conversation's" || return 1
    assert_eq 0 "$(find "$proj" -name '*cs-transplant*' | wc -l | tr -d ' ')" "no converted copy is left behind" || return 1
    assert_file_not_exists "$session_dir/.cs/local/pending-binding-claude.json" "SessionStart committed the staged binding" || return 1
    assert_eq "$_tp_codex_thread" "$(cat "$session_dir/.cs/local/codex-thread-id")" "the Codex binding is untouched" || return 1
    jq -e --arg from "$old_id" --arg to "$new_id" --arg src "codex:$_tp_codex_thread" \
        'select(.event == "rotated" and .engine == "claude" and .from == $from and .to == $to
                and .reason == "transplant" and .carried_from == $src)' \
        "$session_dir/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: no transplant rotation in the timeline"; return 1; }
    output=$("$CS_BIN" carry -conversations 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "rotated (transplant from codex:${_tp_codex_thread:0:8})" "cs -conversations names the source" || return 1

    # The run ended under Claude, so the next Claude open asks as before.
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" carry --engine claude <<< "y" 2>&1) || { echo "$output"; return 1; }
    assert_output_not_contains "$output" "The newest conversation" "a same-engine reopen offers nothing" || return 1
    assert_output_not_contains "$output" "carried over" "a same-engine reopen tries no conversion" || return 1
    assert_eq "--name carry --resume $new_id" "$(tail -1 "$CS_CLAUDE_LOG" | sed 's@ /color.*@@')" "the carried conversation is now the one resumed" || return 1
}

_is_uuid_shape() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

test_claude_reopen_e_resumes_the_earlier_conversation() {
    local output session_dir old_id
    _tp_claude_then_codex earlier || return 1
    session_dir=$(_engine_session_dir earlier)
    old_id=$(_tp_claude_id "$session_dir")
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" earlier --engine claude <<< "e" 2>&1) || { echo "$output"; return 1; }
    assert_eq "--name earlier --resume $old_id" "$(tail -1 "$CS_CLAUDE_LOG" | sed 's@ /color.*@@')" "e resumes Claude's own conversation" || return 1
    assert_eq "$old_id" "$(_tp_claude_id "$session_dir")" "e keeps the binding" || return 1
    assert_eq 0 "$(find "$(_tp_project_dir "$session_dir")" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')" \
        "e places no carried transcript" || return 1
    assert_eq 0 "$(find "$(_tp_project_dir "$session_dir")" -name '*cs-transplant*' | wc -l | tr -d ' ')" "e leaves no converted copy" || return 1
}

# The conversion waits for the answer where Claude keeps the session's
# conversations, outside the session an agent can write, under a name neither
# Claude nor discovery lists; y renames it in.
test_claude_carry_over_is_never_staged_in_the_session() {
    local output session_dir real_dir out proj new_id
    _tp_claude_then_codex staged || return 1
    session_dir=$(_engine_session_dir staged)
    real_dir=$(cd -- "$session_dir" && pwd -P)
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" staged --engine claude <<< "y" 2>&1) || { echo "$output"; return 1; }
    out=$(sed -n 's/.* --out \([^ ]*\) .*/\1/p' "$CS_HELPER_LOG.real" | tail -1)
    [ -n "$out" ] || { echo "  FAIL: the helper wrote no transcript"; return 1; }
    case "$out" in
        "$session_dir"/*|"$real_dir"/*) echo "  FAIL: staged in the session: $out"; return 1 ;;
        *.jsonl) echo "  FAIL: staged under a name Claude lists: $out"; return 1 ;;
    esac
    new_id=$(_tp_claude_id "$session_dir")
    proj=$(_tp_project_dir "$session_dir")
    assert_file_contains "$proj/$new_id.jsonl" 'AMBER-FALCON' "y places the converted conversation" || return 1
    assert_eq 0 "$(find "$proj" -name '*cs-transplant*' | wc -l | tr -d ' ')" "no staged copy is left behind" || return 1
}

test_claude_never_places_a_swapped_staged_transcript() {
    local output session_dir old_id proj
    _tp_claude_then_codex swapped || return 1
    session_dir=$(_engine_session_dir swapped)
    old_id=$(_tp_claude_id "$session_dir")
    jq -nc '{type:"user",message:{role:"user",content:"SWAPPED-IN"}}' > "$TEST_TMPDIR/swapped.jsonl"
    output=$(CS_HELPER_SWAP_STAGED="$TEST_TMPDIR/swapped.jsonl" CS_ASSUME_TTY=1 \
        "$CS_BIN" swapped --engine claude <<< "y" 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "could not carry the Codex conversation over; resuming the earlier Claude conversation" \
        "a staged copy that is no longer a plain file is refused" || return 1
    assert_eq "$old_id" "$(_tp_claude_id "$session_dir")" "the binding is unchanged" || return 1
    proj=$(_tp_project_dir "$session_dir")
    if cat "$proj"/*.jsonl 2>/dev/null | grep -qF SWAPPED-IN; then
        echo "  FAIL: the link's target was placed as a conversation"; return 1
    fi
    assert_eq 0 "$(find "$proj" -name '*cs-transplant*' | wc -l | tr -d ' ')" "the refused copy is removed" || return 1
}

test_claude_reopen_n_starts_fresh_without_carrying() {
    local output session_dir old_id new_id
    _tp_claude_then_codex fresh-tp || return 1
    session_dir=$(_engine_session_dir fresh-tp)
    old_id=$(_tp_claude_id "$session_dir")
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" fresh-tp --engine claude <<< "n" 2>&1) || { echo "$output"; return 1; }
    new_id=$(_tp_claude_id "$session_dir")
    [ "$new_id" != "$old_id" ] || { echo "  FAIL: n resumed"; return 1; }
    assert_output_contains "$(tail -1 "$CS_CLAUDE_LOG")" "--session-id $new_id" "n starts a fresh conversation" || return 1
    [ ! -e "$(_tp_project_dir "$session_dir")/$new_id.jsonl" ] || { echo "  FAIL: n placed a carried transcript"; return 1; }
    if grep -q '"reason":"transplant"' "$session_dir/.cs/timeline.jsonl"; then
        echo "  FAIL: n recorded a transplant"; return 1
    fi
}

test_claude_first_open_after_codex_offers_the_carry_over() {
    local output session_dir new_id
    output=$("$CS_BIN" codex-first --engine codex </dev/null 2>&1) || { echo "$output"; return 1; }
    _tp_write_rollout "$_tp_codex_thread"
    session_dir=$(_engine_session_dir codex-first)
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" codex-first --engine claude <<< "y" 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "The newest conversation here is Codex's" "an engine's first open still offers" || return 1
    assert_output_not_contains "$output" "earlier" "no e without an earlier conversation" || return 1
    new_id=$(_tp_claude_id "$session_dir")
    _is_uuid_shape "$new_id" || { echo "  FAIL: no binding: $new_id"; return 1; }
    assert_eq "--name codex-first --resume $new_id" "$(tail -1 "$CS_CLAUDE_LOG" | sed 's@ /color.*@@')" "y resumes the carried conversation" || return 1
    jq -e --arg to "$new_id" 'select(.event == "rotated" and .reason == "transplant" and .from == "" and .to == $to)' \
        "$session_dir/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: a first carry-over records its lineage"; return 1; }
}

test_unreadable_codex_history_falls_back_to_the_usual_question() {
    local output session_dir old_id
    output=$("$CS_BIN" no-history --engine claude </dev/null 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" no-history --engine codex </dev/null 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir no-history)
    old_id=$(_tp_claude_id "$session_dir")
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" no-history --engine claude <<< "y" 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "the Codex conversation cannot be carried over: Codex keeps no saved history" "the reason is one line" || return 1
    assert_output_contains "$output" "Continue previous conversation?" "the usual question follows" || return 1
    assert_eq "--name no-history --resume $old_id" "$(tail -1 "$CS_CLAUDE_LOG" | sed 's@ /color.*@@')" "y resumes as before" || return 1
}

test_unattended_and_explicit_resume_never_carry_over() {
    local output session_dir old_id
    _tp_claude_then_codex quiet || return 1
    session_dir=$(_engine_session_dir quiet)
    old_id=$(_tp_claude_id "$session_dir")
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" quiet --engine claude --resume 2>&1) || { echo "$output"; return 1; }
    assert_output_not_contains "$output" "The newest conversation" "--resume asks nothing" || return 1
    assert_eq "--name quiet --resume $old_id" "$(tail -1 "$CS_CLAUDE_LOG" | sed 's@ /color.*@@')" "--resume keeps its binding" || return 1
    output=$("$CS_BIN" quiet --engine codex </dev/null 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" quiet --engine claude </dev/null 2>&1) || { echo "$output"; return 1; }
    assert_output_not_contains "$output" "The newest conversation" "an unattended open asks nothing" || return 1
    assert_eq "$old_id" "$(_tp_claude_id "$session_dir")" "no carry-over without an answer" || return 1
}

# Codex first, then Claude with a transcript: the Claude conversation is newer.
_tp_codex_then_claude() {  # name
    local output session_dir
    output=$("$CS_BIN" "$1" --engine codex </dev/null 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" "$1" --engine claude </dev/null 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir "$1")
    _tp_write_transcript "$session_dir" "$(_tp_claude_id "$session_dir")"
}

test_codex_reopen_carries_the_newer_claude_conversation() {
    local output session_dir claude_id transcript
    _tp_codex_then_claude to-codex || return 1
    session_dir=$(_engine_session_dir to-codex)
    claude_id=$(_tp_claude_id "$session_dir")
    transcript="$(_tp_project_dir "$session_dir")/$claude_id.jsonl"
    : > "$CS_HELPER_LOG"
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" to-codex --engine codex <<< "y" 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "The newest conversation here is Claude's" "the offer names the newer conversation" || return 1
    assert_output_contains "$output" "resume the earlier Codex conversation instead" "e is offered beside the earlier thread" || return 1
    assert_output_contains "$output" "Carried over the Claude conversation" "y says what it carried" || return 1
    assert_file_contains "$CS_HELPER_LOG" "history-from-claude $transcript --history-source $claude_id" "the new thread carries the transcript" || return 1
    assert_file_not_contains "$CS_HELPER_LOG" "thread-id" "a carry-over starts a new thread" || return 1
    assert_eq "$_tp_carried_thread" "$(cat "$session_dir/.cs/local/codex-thread-id")" "the carried thread is bound" || return 1
    assert_file_contains "$CS_CODEX_LOG" "resume $_tp_carried_thread" "Codex opens the carried thread" || return 1
    jq -e --arg from "$_tp_codex_thread" --arg to "$_tp_carried_thread" --arg src "claude:$claude_id" \
        'select(.event == "rotated" and .engine == "codex" and .from == $from and .to == $to
                and .reason == "transplant" and .carried_from == $src)' \
        "$session_dir/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: no transplant rotation in the timeline"; return 1; }
    jq -e --arg id "$_tp_carried_thread" 'select(.event == "started" and .engine == "codex" and .session_id == $id
        and .source == "transplant")' "$session_dir/.cs/timeline.jsonl" >/dev/null \
        || { echo "  FAIL: the carried thread's start is not recorded"; return 1; }
    assert_eq "$claude_id" "$(_tp_claude_id "$session_dir")" "the Claude binding is untouched" || return 1
}

test_codex_reopen_e_and_n_do_not_carry() {
    local output session_dir
    _tp_codex_then_claude codex-keys || return 1
    session_dir=$(_engine_session_dir codex-keys)
    : > "$CS_HELPER_LOG"
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" codex-keys --engine codex <<< "e" 2>&1) || { echo "$output"; return 1; }
    assert_file_contains "$CS_HELPER_LOG" "thread-id $_tp_codex_thread" "e refreshes the earlier thread" || return 1
    assert_file_not_contains "$CS_HELPER_LOG" "history-from-claude" "e carries nothing" || return 1
    # Back under Claude, then n under Codex: a fresh thread without the history.
    output=$("$CS_BIN" codex-keys --engine claude </dev/null 2>&1) || { echo "$output"; return 1; }
    : > "$CS_HELPER_LOG"
    output=$(CS_HELPER_FRESH_ID=11111111-1111-4111-8111-111111111111 CS_ASSUME_TTY=1 \
        "$CS_BIN" codex-keys --engine codex <<< "n" 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "The newest conversation here is Claude's" "the offer is made again" || return 1
    assert_file_not_contains "$CS_HELPER_LOG" "history-from-claude" "n carries nothing" || return 1
    assert_eq 11111111-1111-4111-8111-111111111111 "$(cat "$session_dir/.cs/local/codex-thread-id")" "n binds a fresh thread" || return 1
}

test_codex_carry_failure_resumes_the_earlier_thread() {
    local output session_dir
    _tp_codex_then_claude carry-fails || return 1
    session_dir=$(_engine_session_dir carry-fails)
    : > "$CS_HELPER_LOG"
    output=$(CS_HELPER_FAIL_CARRY=1 CS_ASSUME_TTY=1 "$CS_BIN" carry-fails --engine codex <<< "y" 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "rejected thread/inject_items" "the helper's reason is shown" || return 1
    assert_output_contains "$output" "could not carry the Claude conversation over; resuming the earlier Codex conversation" "one line says what happens instead" || return 1
    assert_file_contains "$CS_HELPER_LOG" "thread-id $_tp_codex_thread" "the earlier thread is refreshed" || return 1
    assert_eq "$_tp_codex_thread" "$(cat "$session_dir/.cs/local/codex-thread-id")" "the binding is unchanged" || return 1
    if grep -q '"reason":"transplant"' "$session_dir/.cs/timeline.jsonl"; then
        echo "  FAIL: a failed carry-over recorded a transplant"; return 1
    fi
}

run_test test_collision_resume_preserves_explicit_engine
run_test test_collision_attended_open_preserves_explicit_engine
run_test test_collision_without_explicit_engine_uses_feature_preference
run_test test_collision_new_feature_preserves_explicit_engine
run_test test_engine_roundtrip_resumes_each_acknowledged_binding
run_test test_launch_intent_flags_validate_before_creation
run_test test_resume_missing_binding_does_not_migrate_or_allocate
run_test test_invalid_engine_values_fail_before_session_creation
run_test test_default_launch_remains_claude
run_test test_environment_default_selects_codex
run_test test_stored_engine_wins_and_explicit_claude_keeps_codex_binding
run_test test_explicit_codex_works_without_claude_and_claude_without_codex
run_test test_codex_finish_starts_the_thread_on_the_finish_skill
run_test test_codex_finish_of_an_unknown_feature_starts_nothing
run_test test_codex_create_and_resume_do_not_prepare_claude
run_test test_codex_adopt_preserves_user_instructions_and_configuration
run_test test_codex_worktree_then_claude_prepares_only_on_switch
run_test test_neutral_session_environment_drives_shared_commands
run_test test_sole_installed_codex_adapter_is_default
run_test test_sole_installed_codex_adapter_is_read_from_the_install_dir
run_test test_codex_doctor_reports_capability_gaps_without_claude_checks
run_test test_claude_adoption_preserves_user_local_instructions
run_test test_launch_options_survive_fresh_and_resumed_engines
run_test test_invalid_launch_options_do_not_create_workspace
run_test test_profile_reopen_refreshes_login_without_overwriting_preferences
run_test test_profile_launch_without_the_variable_shares_the_default_login
run_test test_profile_launch_keeps_a_chosen_credential_dir
run_test test_original_launch_leaves_the_credential_dir_alone
run_test test_claude_reopen_carries_the_newer_codex_conversation
run_test test_claude_reopen_e_resumes_the_earlier_conversation
run_test test_claude_carry_over_is_never_staged_in_the_session
run_test test_claude_never_places_a_swapped_staged_transcript
run_test test_claude_reopen_n_starts_fresh_without_carrying
run_test test_claude_first_open_after_codex_offers_the_carry_over
run_test test_unreadable_codex_history_falls_back_to_the_usual_question
run_test test_unattended_and_explicit_resume_never_carry_over
run_test test_codex_reopen_carries_the_newer_claude_conversation
run_test test_codex_reopen_e_and_n_do_not_carry
run_test test_codex_carry_failure_resumes_the_earlier_thread
report_results
