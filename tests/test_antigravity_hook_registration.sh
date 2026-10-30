#!/usr/bin/env bash
# ABOUTME: cs's Antigravity plugin is written whole, only into a folder that is cs's, and removed file by file.
# ABOUTME: Exercises lib/01-manifests.sh in a temporary HOME; no real ~/.gemini is read or written.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/01-manifests.sh"
# bin/cs and install.sh both define warn; the manifests alone do not.
warn() { printf 'Warning: %s\n' "$*" >&2; }

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    PLUGIN="$HOME/.gemini/config/plugins/cs"
    mkdir -p "$HOME"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

test_register_writes_one_named_hook_for_the_installed_cs() {
    _antigravity_plugin_register /opt/cs/bin/cs || return 1
    assert_eq cs "$(jq -r .name "$PLUGIN/plugin.json")" "agy names the plugin by its folder" || return 1
    assert_eq '["cs-session"]' "$(jq -c keys "$PLUGIN/hooks.json")" "one named hook, cs's" || return 1
    assert_eq '/opt/cs/bin/cs -antigravity-hook pre-invocation' \
        "$(jq -r '."cs-session".PreInvocation[0].command' "$PLUGIN/hooks.json")" || return 1
    assert_eq '*' "$(jq -r '."cs-session".PostToolUse[0].matcher' "$PLUGIN/hooks.json")" "every tool reaches the hook" || return 1
    assert_eq '/opt/cs/bin/cs -antigravity-hook post-tool-use' \
        "$(jq -r '."cs-session".PostToolUse[0].hooks[0].command' "$PLUGIN/hooks.json")" || return 1
    assert_eq '["PostToolUse","PreInvocation"]' "$(jq -c '."cs-session" | keys' "$PLUGIN/hooks.json")" \
        "only the two events cs uses" || return 1
    _antigravity_plugin_is_cs "$PLUGIN" || { echo "  FAIL: cs must know its own plugin"; return 1; }
}

test_register_quotes_a_path_the_shell_would_split() {
    _antigravity_plugin_register "/Users/a b/it's/cs" || return 1
    assert_eq "'/Users/a b/it'\\''s/cs' -antigravity-hook pre-invocation" \
        "$(jq -r '."cs-session".PreInvocation[0].command' "$PLUGIN/hooks.json")" || return 1
    _antigravity_plugin_is_cs "$PLUGIN" || { echo "  FAIL: a quoted command is still cs's"; return 1; }
}

test_reregister_replaces_cs_files_in_place_and_is_idempotent() {
    local before
    _antigravity_plugin_register /old/cs || return 1
    _antigravity_plugin_register /new/cs || return 1
    assert_eq '/new/cs -antigravity-hook pre-invocation' \
        "$(jq -r '."cs-session".PreInvocation[0].command' "$PLUGIN/hooks.json")" "an update names the new cs" || return 1
    before=$(cat "$PLUGIN/hooks.json" "$PLUGIN/plugin.json")
    _antigravity_plugin_register /new/cs || return 1
    assert_eq "$before" "$(cat "$PLUGIN/hooks.json" "$PLUGIN/plugin.json")" "a reinstall changes nothing" || return 1
    assert_eq "hooks.json plugin.json" "$(ls -A "$PLUGIN" | tr '\n' ' ' | sed 's/ $//')" "no temporary file is left"
}

test_a_folder_of_the_users_is_never_written_or_removed() {
    local status=0 before
    mkdir -p "$PLUGIN"
    printf '{"name": "cs"}\n' > "$PLUGIN/plugin.json"
    printf '{"lint": {"PostToolUse": [{"matcher": "*", "hooks": [{"command": "./lint.sh"}]}]}}\n' > "$PLUGIN/hooks.json"
    before=$(cat "$PLUGIN/plugin.json" "$PLUGIN/hooks.json")
    _antigravity_plugin_register /opt/cs || status=$?
    assert_eq 3 "$status" "register refuses a folder that is not cs's" || return 1
    assert_eq "$before" "$(cat "$PLUGIN/plugin.json" "$PLUGIN/hooks.json")" "and writes nothing" || return 1
    status=0
    _antigravity_plugin_unregister || status=$?
    assert_eq 3 "$status" "unregister refuses it too" || return 1
    assert_eq "$before" "$(cat "$PLUGIN/plugin.json" "$PLUGIN/hooks.json")" "and removes nothing" || return 1
    printf '{"cs-session": {"PreInvocation": [{"command": "/opt/cs -antigravity-hook pre-invocation"}]}, "mine": {}}\n' \
        > "$PLUGIN/hooks.json"
    _antigravity_plugin_is_cs "$PLUGIN" && { echo "  FAIL: a hook the user added makes the file theirs"; return 1; }
    printf '{"cs-session": {"PreInvocation": [{"command": "rm -rf ~"}]}}\n' > "$PLUGIN/hooks.json"
    _antigravity_plugin_is_cs "$PLUGIN" && { echo "  FAIL: a command that is not cs's is not cs's"; return 1; }
    return 0
}

test_a_linked_folder_or_hooks_file_is_never_written_through() {
    local status=0 target="$TEST_TMPDIR/elsewhere"
    mkdir -p "$target" "${PLUGIN%/*}"
    ln -s "$target" "$PLUGIN"
    _antigravity_plugin_register /opt/cs || status=$?
    assert_eq 3 "$status" "a linked plugin folder is refused" || return 1
    assert_eq "" "$(ls -A "$target")" "nothing lands behind the link" || return 1
    rm "$PLUGIN"
    _antigravity_plugin_register /opt/cs || return 1
    cp "$PLUGIN/hooks.json" "$target/hooks.json"
    rm "$PLUGIN/hooks.json"
    ln -s "$target/hooks.json" "$PLUGIN/hooks.json"
    status=0
    _antigravity_plugin_register /new/cs || status=$?
    assert_eq 3 "$status" "a linked hooks.json is refused" || return 1
    assert_file_contains "$target/hooks.json" '/opt/cs' "the link's target is left as it was"
}

# The recovery scripts as an install deploys them: the shipped files, each in
# the install record that tells cs's files from the user's.
_deploy_scripts() {
    local script record
    record=$(_cs_install_record)
    mkdir -p "$PLUGIN/scripts" "${record%/*}"
    for script in "${CS_RECOVERY_SCRIPTS[@]}"; do
        cp "$SCRIPT_DIR/../hooks/$script" "$PLUGIN/scripts/$script" || return 1
        printf '%s  %s\n' "$(_cs_sha256_file "$PLUGIN/scripts/$script")" \
            ".gemini/config/plugins/cs/scripts/$script" >> "$record"
    done
}

test_unregister_removes_only_what_cs_wrote() {
    local output
    _antigravity_plugin_register /opt/cs || return 1
    _deploy_scripts || return 1
    _antigravity_plugin_unregister || return 1
    assert_not_exists "$PLUGIN" "an untouched plugin goes whole" || return 1
    _antigravity_plugin_register /opt/cs || return 1
    _deploy_scripts || return 1
    printf 'mine\n' > "$PLUGIN/scripts/notes.txt"
    printf '# my change\n' >> "$PLUGIN/scripts/cs-resolve.sh"
    printf '{"name": "cs", "description": "mine"}\n' > "$PLUGIN/plugin.json"
    output=$(_antigravity_plugin_unregister 2>&1) || { echo "  FAIL: $output"; return 1; }
    assert_not_exists "$PLUGIN/hooks.json" "the hook is gone, so agy runs nothing of cs's" || return 1
    assert_not_exists "$PLUGIN/scripts/autosave-commits.sh" "a script cs wrote goes" || return 1
    assert_eq mine "$(cat "$PLUGIN/scripts/notes.txt")" "a file the user put there stays" || return 1
    assert_file_contains "$PLUGIN/scripts/cs-resolve.sh" '# my change' "a script the user changed stays" || return 1
    assert_output_contains "$output" "Kept $PLUGIN/scripts/cs-resolve.sh" "and is named" || return 1
    assert_file_contains "$PLUGIN/plugin.json" mine "a plugin.json the user changed stays" || return 1
    _antigravity_plugin_unregister || true
    assert_eq mine "$(cat "$PLUGIN/scripts/notes.txt")" "a second removal leaves the user's file too"
}

# hooks.json marks the folder cs's, so it is written first: an install cut
# short at either write leaves a folder the next install still takes.
test_an_install_cut_short_is_repaired_by_the_next() {
    local target status
    for target in hooks plugin; do
        rm -rf "$PLUGIN"
        # chmod stands for the write that fails: the disk filled, the run was cut.
        eval "chmod() { case \"\$2\" in *.$target.json.*) return 1 ;; esac; command chmod \"\$@\"; }"
        status=0
        _antigravity_plugin_register /opt/cs || status=$?
        unset -f chmod
        [ "$status" -ne 0 ] && [ "$status" -ne 3 ] || { echo "  FAIL: a failed $target.json write must fail ($status)"; return 1; }
        _antigravity_plugin_register /opt/cs \
            || { echo "  FAIL: after a failed $target.json write the next install must take the folder"; return 1; }
        assert_eq cs "$(jq -r .name "$PLUGIN/plugin.json")" "plugin.json is in place after $target" || return 1
        _antigravity_plugin_is_cs "$PLUGIN" || { echo "  FAIL: the folder is cs's after $target"; return 1; }
    done
}

test_a_linked_scripts_folder_is_never_written_or_emptied_through() {
    local status=0 target="$TEST_TMPDIR/elsewhere" script
    mkdir -p "$target"
    for script in "${CS_RECOVERY_SCRIPTS[@]}"; do printf 'theirs\n' > "$target/$script"; done
    _antigravity_plugin_register /opt/cs || return 1
    ln -s "$target" "$PLUGIN/scripts"
    _antigravity_plugin_register /new/cs || status=$?
    assert_eq 3 "$status" "a plugin whose scripts/ is a link is not cs's to write" || return 1
    status=0
    _antigravity_plugin_unregister || status=$?
    assert_eq 3 "$status" "nor to remove" || return 1
    for script in "${CS_RECOVERY_SCRIPTS[@]}"; do
        assert_eq theirs "$(cat "$target/$script")" "$script behind the link stays" || return 1
    done
}

test_unregister_without_a_plugin_is_a_no_op() {
    _antigravity_plugin_unregister || return 1
    assert_not_exists "$HOME/.gemini" "nothing is created"
}

run_test test_register_writes_one_named_hook_for_the_installed_cs
run_test test_register_quotes_a_path_the_shell_would_split
run_test test_reregister_replaces_cs_files_in_place_and_is_idempotent
run_test test_a_folder_of_the_users_is_never_written_or_removed
run_test test_a_linked_folder_or_hooks_file_is_never_written_through
run_test test_unregister_removes_only_what_cs_wrote
run_test test_unregister_without_a_plugin_is_a_no_op
run_test test_an_install_cut_short_is_repaired_by_the_next
run_test test_a_linked_scripts_folder_is_never_written_or_emptied_through
report_results
