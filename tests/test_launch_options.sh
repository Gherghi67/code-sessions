#!/usr/bin/env bash
# ABOUTME: Checks launch argument transport and per-session login synchronization.
# ABOUTME: Uses temporary JSON and picker stubs without real credentials or engines.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/75-launch.sh"
error() { printf 'Error: %s\n' "$*" >&2; exit 1; }

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    mkdir -p "$TEST_TMPDIR/config"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

test_vault_reopen_retargets_managed_profile_links_to_normal_config() (
    export HOME="$TEST_TMPDIR/home"
    unset CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR CODE_SESSIONS_HOME
    local session="$TEST_TMPDIR/session" vault="$TEST_TMPDIR/vault/claude-config"
    local normal="$HOME/.claude" legacy="$HOME/.local/share/code-sessions/home/.claude" name
    mkdir -p "$session/.cs" "$vault/projects/own" "$normal" "$legacy"
    ln -s "$vault" "$session/.cs/claude-config"
    printf '%s\n' '{"theme":"normal"}' > "$normal/settings.json"
    printf '%s\n' '{"theme":"old-profile"}' > "$legacy/settings.json"
    ln -s "$legacy/settings.json" "$vault/settings.json"
    for name in hooks skills plugins; do
        mkdir -p "$normal/$name" "$legacy/$name"
        printf '%s\n' normal > "$normal/$name/marker"
        printf '%s\n' old-profile > "$legacy/$name/marker"
        ln -s "$legacy/$name" "$vault/$name"
    done
    printf '%s\n' '{"private-thread":1}' > "$vault/projects/own/thread.jsonl"
    printf '%s\n' '{"private-history":1}' > "$vault/history.jsonl"
    _export_session_claude_config "$session" || return 1
    assert_eq "$normal/settings.json" "$(readlink "$vault/settings.json")" || return 1
    assert_eq normal "$(jq -r .theme "$vault/settings.json")" || return 1
    for name in hooks skills plugins; do
        assert_eq "$normal/$name" "$(readlink "$vault/$name")" || return 1
        assert_eq normal "$(cat "$vault/$name/marker")" || return 1
        assert_eq old-profile "$(cat "$legacy/$name/marker")" || return 1
    done
    assert_eq "$session/.cs/claude-config" "$CLAUDE_CONFIG_DIR" || return 1
    assert_eq "$vault" "$(readlink "$session/.cs/claude-config")" || return 1
    assert_eq '{"private-thread":1}' "$(cat "$vault/projects/own/thread.jsonl")" || return 1
    assert_eq '{"private-history":1}' "$(cat "$vault/history.jsonl")" || return 1
    assert_not_exists "$normal/projects" || return 1
    assert_not_exists "$normal/history.jsonl"
)

test_vault_retargets_broken_managed_links_even_without_normal_targets() (
    export HOME="$TEST_TMPDIR/home"
    local normal="$TEST_TMPDIR/custom ' config" legacy="$HOME/.local/share/code-sessions/home/.claude"
    mkdir -p "$normal" "$legacy"
    printf '%s\n' old-profile > "$legacy/settings.json"
    ln -s "$legacy/settings.json" "$TEST_TMPDIR/config/settings.json"
    ln -s "$legacy/plugins" "$TEST_TMPDIR/config/plugins"
    _link_shared_claude_config "$TEST_TMPDIR/config" "$normal" || return 1
    assert_eq "$normal/settings.json" "$(readlink "$TEST_TMPDIR/config/settings.json")" || return 1
    assert_eq "$normal/plugins" "$(readlink "$TEST_TMPDIR/config/plugins")" || return 1
    assert_not_exists "$TEST_TMPDIR/config/settings.json" || return 1
    assert_not_exists "$TEST_TMPDIR/config/plugins" || return 1
    assert_eq old-profile "$(cat "$legacy/settings.json")"
)

test_vault_preserves_session_overrides_and_unrelated_links() (
    export HOME="$TEST_TMPDIR/home"
    local normal="$HOME/.claude"
    mkdir -p "$normal/hooks" "$normal/plugins" "$TEST_TMPDIR/config/plugins" "$TEST_TMPDIR/override-hooks"
    printf '%s\n' normal > "$normal/settings.json"
    printf '%s\n' session > "$TEST_TMPDIR/config/settings.json"
    printf '%s\n' custom > "$TEST_TMPDIR/override-hooks/marker"
    printf '%s\n' session-plugin > "$TEST_TMPDIR/config/plugins/marker"
    ln -s ../override-hooks "$TEST_TMPDIR/config/hooks"
    _link_shared_claude_config "$TEST_TMPDIR/config" "$normal" || return 1
    assert_eq session "$(cat "$TEST_TMPDIR/config/settings.json")" || return 1
    [ ! -L "$TEST_TMPDIR/config/settings.json" ] || return 1
    assert_eq ../override-hooks "$(readlink "$TEST_TMPDIR/config/hooks")" || return 1
    assert_eq custom "$(cat "$TEST_TMPDIR/config/hooks/marker")" || return 1
    assert_eq session-plugin "$(cat "$TEST_TMPDIR/config/plugins/marker")" || return 1
    [ ! -L "$TEST_TMPDIR/config/plugins" ]
)

test_login_refresh_preserves_session_projects_and_preferences() {
    local source="$TEST_TMPDIR/shell.json" dest="$TEST_TMPDIR/config/.claude.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"new"},"theme":"shell","projects":{"secret":1}}' > "$source"
    _seed_session_claude_json "$TEST_TMPDIR/config" "$source" || return 1
    assert_eq '{}' "$(jq -c .projects "$dest")" "initial seed drops shell project data" || return 1
    printf '%s\n' '{"oauthAccount":{"accountUuid":"old"},"theme":"session","projects":{"own":2}}' > "$dest"
    _seed_session_claude_json "$TEST_TMPDIR/config" "$source" || return 1
    assert_eq new "$(jq -r .oauthAccount.accountUuid "$dest")" || return 1
    assert_eq session "$(jq -r .theme "$dest")" || return 1
    assert_eq '{"own":2}' "$(jq -c .projects "$dest")" || return 1
    printf '%s\n' '{}' > "$source"
    _seed_session_claude_json "$TEST_TMPDIR/config" "$source" || return 1
    assert_eq false "$(jq 'has("oauthAccount")' "$dest")" "logout drops stale identity" || return 1
}

test_native_writer_lock_is_never_reclaimed() {
    local output status=0
    printf '%s\n' '{}' > "$TEST_TMPDIR/shell.json"
    mkdir "$TEST_TMPDIR/config/.claude.json.lock"
    output=$( _seed_session_claude_json "$TEST_TMPDIR/config" "$TEST_TMPDIR/shell.json" 2>&1 ) || status=$?
    [ "$status" -ne 0 ] || return 1
    assert_dir "$TEST_TMPDIR/config/.claude.json.lock" "native writer retains lock" || return 1
    assert_not_exists "$TEST_TMPDIR/config/.claude.json" "busy writer's config untouched" || return 1
}

test_corrupt_login_json_preserves_existing_config() {
    local output status=0
    printf '%s\n' '[]' > "$TEST_TMPDIR/shell.json"
    printf '%s\n' '{"projects":{"own":2}}' > "$TEST_TMPDIR/config/.claude.json"
    output=$( _seed_session_claude_json "$TEST_TMPDIR/config" "$TEST_TMPDIR/shell.json" 2>&1 ) || status=$?
    [ "$status" -ne 0 ] || return 1
    assert_eq '{"projects":{"own":2}}' "$(cat "$TEST_TMPDIR/config/.claude.json")" || return 1
    assert_not_exists "$TEST_TMPDIR/config/.claude.json.lock" "failed refresh releases lock" || return 1
}

test_picker_preserves_each_argument_line() {
    export CS_PICKER_ARGS="$TEST_TMPDIR/args" CS_PICKER_STUB="$TEST_TMPDIR/picker"
    local wrapper="$TEST_TMPDIR/entry"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' picked --model 'provider/model with spaces' --effort high" > "$CS_PICKER_STUB"
    cat > "$wrapper" <<'WRAPPER'
#!/usr/bin/env bash
if [ "${1:-}" = picked ]; then printf '%s\n' "$@" > "$CS_PICKER_ARGS"; exit 0; fi
source "$CS_PICKER_LIB"
_tui_bin() { printf '%s\n' "$CS_PICKER_STUB"; }
_export_term_theme() { :; }
run_tui
WRAPPER
    chmod +x "$wrapper" "$CS_PICKER_STUB"
    CS_PICKER_LIB="$SCRIPT_DIR/../lib/65-sessions.sh" "$wrapper" || return 1
    assert_eq 'provider/model with spaces' "$(sed -n '3p' "$CS_PICKER_ARGS")" || return 1
    assert_eq 5 "$(wc -l < "$CS_PICKER_ARGS" | tr -d ' ')" || return 1
}

test_login_refresh_keeps_a_config_symlink() {
    local dest="$TEST_TMPDIR/config/.claude.json" target="$TEST_TMPDIR/account.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"old"},"projects":{"own":2}}' > "$target"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"new"}}' > "$TEST_TMPDIR/shell.json"
    ln -s "$target" "$dest"
    _seed_session_claude_json "$TEST_TMPDIR/config" "$TEST_TMPDIR/shell.json" || return 1
    [ -L "$dest" ] || return 1
    assert_eq new "$(jq -r .oauthAccount.accountUuid "$target")" || return 1
    assert_eq '{"own":2}' "$(jq -c .projects "$target")" || return 1
}

test_native_legacy_config_wins_for_source_and_destination() {
    local shell="$TEST_TMPDIR/shell" config="$TEST_TMPDIR/config" source
    mkdir -p "$shell/.claude"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"selected"}}' > "$shell/.claude/.config.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"stale"}}' > "$shell/.claude.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"old"},"projects":{"own":2},"theme":"local"}' > "$config/.config.json"
    printf '%s\n' '{"sentinel":true}' > "$config/.claude.json"
    source=$(_cs_claude_json_path "$shell/.claude" "$shell/.claude.json")
    _seed_session_claude_json "$config" "$source" || return 1
    assert_eq selected "$(jq -r .oauthAccount.accountUuid "$config/.config.json")" || return 1
    assert_eq local "$(jq -r .theme "$config/.config.json")" || return 1
    assert_eq '{"own":2}' "$(jq -c .projects "$config/.config.json")" || return 1
    assert_eq '{"sentinel":true}' "$(cat "$config/.claude.json")" || return 1
}

test_empty_legacy_configs_keep_valid_modern_login_and_preferences() {
    local shell="$TEST_TMPDIR/shell" config="$TEST_TMPDIR/config" source
    mkdir -p "$shell/.claude"
    : > "$shell/.claude/.config.json"
    : > "$config/.config.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"selected"}}' > "$shell/.claude.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"old"},"projects":{"own":2},"theme":"session"}' > "$config/.claude.json"
    source=$(_cs_claude_json_path "$shell/.claude" "$shell/.claude.json")
    assert_eq "$shell/.claude.json" "$source" || return 1
    _seed_session_claude_json "$config" "$source" || return 1
    assert_eq selected "$(jq -r .oauthAccount.accountUuid "$config/.claude.json")" || return 1
    assert_eq session "$(jq -r .theme "$config/.claude.json")" || return 1
    assert_eq '{"own":2}' "$(jq -c .projects "$config/.claude.json")" || return 1
    [ ! -s "$config/.config.json" ] || return 1
}

test_non_file_legacy_paths_keep_modern_config_selected() {
    local shell="$TEST_TMPDIR/shell" config="$TEST_TMPDIR/config" source
    mkdir -p "$shell/.claude/.config.json" "$config/.config.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"selected"}}' > "$shell/.claude.json"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"old"},"theme":"session"}' > "$config/.claude.json"
    source=$(_cs_claude_json_path "$shell/.claude" "$shell/.claude.json")
    assert_eq "$shell/.claude.json" "$source" || return 1
    _seed_session_claude_json "$config" "$source" || return 1
    assert_eq selected "$(jq -r .oauthAccount.accountUuid "$config/.claude.json")" || return 1
    assert_eq session "$(jq -r .theme "$config/.claude.json")" || return 1
    assert_dir "$config/.config.json" || return 1
}

test_empty_legacy_selection_uses_native_write_permission_bits() {
    local config="$TEST_TMPDIR/config"
    : > "$config/.config.json"
    chmod 600 "$config/.config.json"
    assert_eq "$config/.config.json" "$(_cs_claude_json_path "$config" "$config/.claude.json")" || return 1
    chmod 400 "$config/.config.json"
    assert_eq "$config/.claude.json" "$(_cs_claude_json_path "$config" "$config/.claude.json")" || return 1
    chmod 600 "$config/.config.json"
    printf '%s\n' '{}' > "$config/.config.json"
    chmod 400 "$config/.config.json"
    assert_eq "$config/.config.json" "$(_cs_claude_json_path "$config" "$config/.claude.json")" || return 1
}

test_legacy_symlink_selection_uses_its_target_type_and_size() {
    local config="$TEST_TMPDIR/config" target="$TEST_TMPDIR/account.json"
    printf '%s\n' '{}' > "$target"
    printf '%s\n' '{}' > "$config/.claude.json"
    ln -s "$target" "$config/.config.json"
    assert_eq "$config/.config.json" "$(_cs_claude_json_path "$config" "$config/.claude.json")" || return 1
    : > "$target"
    assert_eq "$config/.claude.json" "$(_cs_claude_json_path "$config" "$config/.claude.json")" || return 1
}

test_symlink_target_lock_blocks_login_refresh() {
    local target="$TEST_TMPDIR/account.json" output status=0
    printf '%s\n' '{"oauthAccount":{"accountUuid":"old"}}' > "$target"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"new"}}' > "$TEST_TMPDIR/shell.json"
    ln -s "$target" "$TEST_TMPDIR/config/.claude.json"
    mkdir "$target.lock"
    output=$( _seed_session_claude_json "$TEST_TMPDIR/config" "$TEST_TMPDIR/shell.json" 2>&1 ) || status=$?
    [ "$status" -ne 0 ] || return 1
    assert_dir "$target.lock" || return 1
    assert_eq old "$(jq -r .oauthAccount.accountUuid "$target")" || return 1
    assert_not_exists "$TEST_TMPDIR/config/.claude.json.lock" || return 1
}

test_abandoned_stale_native_lock_can_be_reclaimed() {
    printf '%s\n' '{}' > "$TEST_TMPDIR/shell.json"
    mkdir "$TEST_TMPDIR/config/.claude.json.lock"
    touch -t 200001010000 "$TEST_TMPDIR/config/.claude.json.lock"
    _seed_session_claude_json "$TEST_TMPDIR/config" "$TEST_TMPDIR/shell.json" || return 1
    assert_file_exists "$TEST_TMPDIR/config/.claude.json" || return 1
    assert_not_exists "$TEST_TMPDIR/config/.claude.json.lock" || return 1
}

test_signal_releases_only_our_config_lock_and_preserves_outer_trap() {
    local marker="$TEST_TMPDIR/seed-ready" signaller status=0
    printf '%s\n' '{}' > "$TEST_TMPDIR/shell.json"
    trap 'printf outer > "$TEST_TMPDIR/outer-trap"' TERM
    signaller=$(command -v python3)
    (
        jq() {
            printf '%s\n' ready > "$marker"
            "$signaller" -c 'import os,signal; os.kill(os.getppid(), signal.SIGTERM)'
        }
        _seed_session_claude_json "$TEST_TMPDIR/config" "$TEST_TMPDIR/shell.json"
    ) || status=$?
    trap - TERM
    assert_eq 143 "$status" || return 1
    assert_not_exists "$TEST_TMPDIR/config/.claude.json.lock" || return 1
    assert_not_exists "$TEST_TMPDIR/outer-trap" "subshell trap must not replace outer trap" || return 1
    [ -z "$(find "$TEST_TMPDIR/config" -name '.claude.json.*' -type f)" ] || return 1
}

test_slow_login_refresh_keeps_native_lock_fresh() {
    local source="$TEST_TMPDIR/shell.json" dest="$TEST_TMPDIR/config/.claude.json"
    local ready="$TEST_TMPDIR/ready" contender status=0
    printf '%s\n' '{"oauthAccount":{"accountUuid":"seed"}}' > "$source"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"old"},"theme":"session"}' > "$dest"
    python3 - "$dest" "$ready" <<'PY' &
import json, os, sys, time
dest, ready = sys.argv[1:]
deadline = time.monotonic() + 10
while not os.path.exists(ready):
    if time.monotonic() >= deadline:
        sys.exit("refresh did not reach JSON processing")
    time.sleep(0.05)
time.sleep(10.5)
lock = dest + ".lock"
if time.time() - os.stat(lock).st_mtime > 10:
    os.rename(lock, lock + ".displaced")
    os.mkdir(lock)
    with open(dest, "w") as stream:
        json.dump({"oauthAccount": {"accountUuid": "successor"}, "theme": "successor"}, stream)
    with open(ready + ".stolen", "w") as stream:
        stream.write("stale lock was reclaimed")
PY
    contender=$!
    (
        jq() {
            command jq "$@" || return 1
            : > "$ready"
            sleep 12
        }
        _seed_session_claude_json "$TEST_TMPDIR/config" "$source"
    ) || status=$?
    wait "$contender" || return 1
    assert_not_exists "$ready.stolen" "a live refresh must not look stale after ten seconds" || return 1
    assert_eq 0 "$status" || return 1
    assert_eq seed "$(jq -r .oauthAccount.accountUuid "$dest")" || return 1
    assert_eq session "$(jq -r .theme "$dest")" || return 1
    assert_not_exists "$dest.lock" || return 1
}

test_lost_login_lock_aborts_write_and_keeps_successor_lock() {
    local source="$TEST_TMPDIR/shell.json" dest="$TEST_TMPDIR/config/.claude.json"
    local output status=0
    printf '%s\n' '{"oauthAccount":{"accountUuid":"seed"}}' > "$source"
    printf '%s\n' '{"oauthAccount":{"accountUuid":"old"}}' > "$dest"
    output=$(
        jq() {
            command jq "$@" || return 1
            mv "$dest.lock" "$TEST_TMPDIR/displaced-lock"
            mkdir "$dest.lock"
            printf '%s\n' '{"oauthAccount":{"accountUuid":"successor"},"theme":"successor"}' > "$dest"
        }
        _seed_session_claude_json "$TEST_TMPDIR/config" "$source" 2>&1
    ) || status=$?
    [ "$status" -ne 0 ] || { echo "a refresh that lost its lock still succeeded"; return 1; }
    assert_eq successor "$(jq -r .oauthAccount.accountUuid "$dest")" || return 1
    assert_eq successor "$(jq -r .theme "$dest")" || return 1
    assert_dir "$dest.lock" "cleanup must leave the successor's lock alone" || return 1
    [ -z "$(find "$TEST_TMPDIR/config" -name '.claude.json.*' -type f)" ] || return 1
}

echo 'Launch options and login synchronization tests'
run_test test_vault_reopen_retargets_managed_profile_links_to_normal_config
run_test test_vault_retargets_broken_managed_links_even_without_normal_targets
run_test test_vault_preserves_session_overrides_and_unrelated_links
run_test test_login_refresh_preserves_session_projects_and_preferences
run_test test_native_writer_lock_is_never_reclaimed
run_test test_corrupt_login_json_preserves_existing_config
run_test test_picker_preserves_each_argument_line
run_test test_login_refresh_keeps_a_config_symlink
run_test test_native_legacy_config_wins_for_source_and_destination
run_test test_empty_legacy_configs_keep_valid_modern_login_and_preferences
run_test test_non_file_legacy_paths_keep_modern_config_selected
run_test test_empty_legacy_selection_uses_native_write_permission_bits
run_test test_legacy_symlink_selection_uses_its_target_type_and_size
run_test test_symlink_target_lock_blocks_login_refresh
run_test test_abandoned_stale_native_lock_can_be_reclaimed
run_test test_signal_releases_only_our_config_lock_and_preserves_outer_trap
run_test test_slow_login_refresh_keeps_native_lock_fresh
run_test test_lost_login_lock_aborts_write_and_keeps_successor_lock
report_results
