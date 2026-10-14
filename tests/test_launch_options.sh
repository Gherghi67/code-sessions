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
run_test test_login_refresh_preserves_session_projects_and_preferences
run_test test_native_writer_lock_is_never_reclaimed
run_test test_corrupt_login_json_preserves_existing_config
run_test test_picker_preserves_each_argument_line
run_test test_login_refresh_keeps_a_config_symlink
run_test test_native_legacy_config_wins_for_source_and_destination
run_test test_symlink_target_lock_blocks_login_refresh
run_test test_abandoned_stale_native_lock_can_be_reclaimed
run_test test_signal_releases_only_our_config_lock_and_preserves_outer_trap
run_test test_slow_login_refresh_keeps_native_lock_fresh
run_test test_lost_login_lock_aborts_write_and_keeps_successor_lock
report_results
