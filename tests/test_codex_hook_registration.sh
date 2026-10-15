#!/usr/bin/env bash
# ABOUTME: Codex hook registration and removal preserve neighboring handlers and their trust.
# ABOUTME: Exercises lib/01-manifests.sh with isolated hooks.json and config.toml fixtures.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/01-manifests.sh"

_mixed_group() {  # CS handler position
    CODEX_DIR="$TEST_TMPDIR/codex-$1"
    mkdir -p "$CODEX_DIR"
    jq -n --argjson i "$1" '
        [{type: "command", command: "/user/trusted", timeout: 12, async: true},
         {type: "command", command: "/user/untrusted", statusMessage: "User hook"}] as $user
        | {hooks: {SessionStart: [
            {hooks: [{type: "command", command: "/user/earlier"}]},
            {matcher: "clear", hooks: ($user[:$i] + [{type: "command", command: "/old/cs -codex-hook session-start"}] + $user[$i:])},
            {hooks: [{type: "command", command: "/user/later"}]}]}}' > "$CODEX_DIR/hooks.json"
    local trusted=0
    [ "$1" != 0 ] || trusted=1
    printf 'model = "mine"\n\n[hooks.state."%s:session_start:0:0"]\ntrusted_hash = "earlier"\n\n[hooks.state."%s:session_start:1:%s"]\ntrusted_hash = "trusted-user"\n\n[hooks.state."%s:session_start:1:%s"]\ntrusted_hash = "old-cs"\n\n[hooks.state."%s:session_start:2:0"]\ntrusted_hash = "later"\n' \
        "$CODEX_DIR/hooks.json" "$CODEX_DIR/hooks.json" "$trusted" \
        "$CODEX_DIR/hooks.json" "$1" "$CODEX_DIR/hooks.json" > "$CODEX_DIR/config.toml"
}

_trust_at() {  # group, handler
    awk -v head="[hooks.state.\"$CODEX_DIR/hooks.json:${3:-session_start}:$1:$2\"]" '
        $0 == head { getline; print; exit }
    ' "$CODEX_DIR/config.toml"
}

test_reinstall_preserves_mixed_group_and_trust() {
    local pos expected trusted untrusted hash before_hooks before_config
    for pos in 0 1 2; do
        _mixed_group "$pos"
        expected=$(jq -S --argjson i "$pos" \
            '.hooks.SessionStart[1].hooks[$i] = {type: "command", command: "/new/cs -codex-hook session-start"}' \
            "$CODEX_DIR/hooks.json")
        _codex_hooks_register "$CODEX_DIR" '/new/cs -codex-hook session-start' || return 1
        assert_eq "$expected" "$(jq -S . "$CODEX_DIR/hooks.json")" "replace only CS at position $pos" || return 1
        trusted=0; untrusted=2
        [ "$pos" != 0 ] || trusted=1
        [ "$pos" != 2 ] || untrusted=1
        assert_eq 'trusted_hash = "trusted-user"' "$(_trust_at 1 "$trusted")" || return 1
        assert_eq '' "$(_trust_at 1 "$untrusted")" "never approve a neighboring user hook" || return 1
        assert_eq 'trusted_hash = "earlier"' "$(_trust_at 0 0)" || return 1
        assert_eq 'trusted_hash = "later"' "$(_trust_at 2 0)" || return 1
        hash=$(python3 - <<'PY'
import hashlib, json
definition = {"event_name": "session_start", "matcher": "clear", "hooks": [
    {"async": False, "command": "/new/cs -codex-hook session-start", "timeout": 600, "type": "command"}]}
print(hashlib.sha256(json.dumps(definition, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
PY
        ) || return 1
        assert_eq "trusted_hash = \"sha256:$hash\"" "$(_trust_at 1 "$pos")" "CS trust includes the retained matcher" || return 1
        before_hooks=$(cat "$CODEX_DIR/hooks.json"); before_config=$(cat "$CODEX_DIR/config.toml")
        _codex_hooks_register "$CODEX_DIR" '/new/cs -codex-hook session-start' || return 1
        assert_eq "$before_hooks" "$(cat "$CODEX_DIR/hooks.json")" || return 1
        assert_eq "$before_config" "$(cat "$CODEX_DIR/config.toml")" "reinstall is idempotent" || return 1
    done
}

test_uninstall_preserves_mixed_group_and_moves_only_its_handler_trust() {
    local pos expected before_hooks before_config
    for pos in 0 1 2; do
        _mixed_group "$pos"
        expected=$(jq -S --argjson i "$pos" 'del(.hooks.SessionStart[1].hooks[$i])' "$CODEX_DIR/hooks.json")
        _codex_hooks_unregister "$CODEX_DIR" || return 1
        assert_eq "$expected" "$(jq -S . "$CODEX_DIR/hooks.json")" "remove only CS at position $pos" || return 1
        assert_eq 'trusted_hash = "trusted-user"' "$(_trust_at 1 0)" || return 1
        assert_eq '' "$(_trust_at 1 1)" "the untrusted handler stays untrusted" || return 1
        assert_eq '' "$(_trust_at 1 2)" "no stale handler trust remains" || return 1
        assert_eq 'trusted_hash = "earlier"' "$(_trust_at 0 0)" || return 1
        assert_eq 'trusted_hash = "later"' "$(_trust_at 2 0)" "the later group does not move" || return 1
        assert_file_not_contains "$CODEX_DIR/config.toml" 'old-cs' || return 1
        before_hooks=$(cat "$CODEX_DIR/hooks.json"); before_config=$(cat "$CODEX_DIR/config.toml")
        _codex_hooks_unregister "$CODEX_DIR" || return 1
        assert_eq "$before_hooks" "$(cat "$CODEX_DIR/hooks.json")" || return 1
        assert_eq "$before_config" "$(cat "$CODEX_DIR/config.toml")" || return 1
    done
}

test_installer_and_uninstaller_preserve_a_mixed_group() {
    _mixed_group 1
    local fake_home="$TEST_TMPDIR/installed-home" expected after_remove pass
    mkdir -p "$fake_home"
    expected=$(jq -S --arg cmd "$fake_home/.local/bin/cs -codex-hook session-start" \
        --arg recovery "$fake_home/.local/bin/cs -codex-hook files-changed" \
        --arg stop "$fake_home/.local/bin/cs -codex-hook stop" \
        --arg prompt "$fake_home/.local/bin/cs -codex-hook user-prompt-submit" \
        --arg approval "$fake_home/.local/bin/cs -codex-hook permission-request" \
        '.hooks.SessionStart[1].hooks[1].command = $cmd
         | .hooks.PostToolUse = [{hooks: [{type: "command", command: $recovery}]}]
         | .hooks.Stop = [{hooks: [{type: "command", command: $stop}]}]
         | .hooks.UserPromptSubmit = [{hooks: [{type: "command", command: $prompt}]}]
         | .hooks.PermissionRequest = [{hooks: [{type: "command", command: $approval}]}]' "$CODEX_DIR/hooks.json")
    after_remove=$(jq -S 'del(.hooks.SessionStart[1].hooks[1])' "$CODEX_DIR/hooks.json")
    for pass in 1 2; do
        HOME="$fake_home" CODEX_HOME="$CODEX_DIR" CS_INSTALL_ENGINES=codex \
            bash "$SCRIPT_DIR/../install.sh" </dev/null > "$TEST_TMPDIR/install.log" 2>&1 \
            || { cat "$TEST_TMPDIR/install.log"; return 1; }
        assert_eq "$expected" "$(jq -S . "$CODEX_DIR/hooks.json")" "install pass $pass preserves neighbors" || return 1
        assert_eq 'trusted_hash = "trusted-user"' "$(_trust_at 1 0)" || return 1
        assert_eq '' "$(_trust_at 1 2)" || return 1
        assert_file_exists "$CODEX_DIR/hooks/cs/autosave-commits.sh" || return 1
        assert_file_exists "$CODEX_DIR/hooks/cs/cs-engine-events.sh" || return 1
        local hash
        hash=$(_codex_hook_trust_hash "$fake_home/.local/bin/cs -codex-hook files-changed" null post_tool_use)
        assert_eq "trusted_hash = \"sha256:$hash\"" "$(_trust_at 0 0 post_tool_use)" || return 1
        # The automatic /clear after a rotation: its three hooks, trusted.
        hash=$(_codex_hook_trust_hash "$fake_home/.local/bin/cs -codex-hook stop" null stop)
        assert_eq "trusted_hash = \"sha256:$hash\"" "$(_trust_at 0 0 stop)" || return 1
        hash=$(_codex_hook_trust_hash "$fake_home/.local/bin/cs -codex-hook user-prompt-submit" null user_prompt_submit)
        assert_eq "trusted_hash = \"sha256:$hash\"" "$(_trust_at 0 0 user_prompt_submit)" || return 1
        hash=$(_codex_hook_trust_hash "$fake_home/.local/bin/cs -codex-hook permission-request" null permission_request)
        assert_eq "trusted_hash = \"sha256:$hash\"" "$(_trust_at 0 0 permission_request)" || return 1
    done
    printf 'y\nn\nn\n' | HOME="$fake_home" CODEX_HOME="$CODEX_DIR" \
        env -u CODE_SESSIONS_HOME -u CS_INSTALL_DIR -u CS_CONFIG_DIR -u CS_CACHE_DIR \
        -u CS_HOOKS_DIR -u CS_CLAUDE_DIR -u CS_SKILLS_DIR -u CS_COMMANDS_DIR \
        "$fake_home/.local/bin/cs" -uninstall \
        > "$TEST_TMPDIR/uninstall.log" 2>&1 || { cat "$TEST_TMPDIR/uninstall.log"; return 1; }
    assert_eq "$after_remove" "$(jq -S . "$CODEX_DIR/hooks.json")" || return 1
    assert_eq 'trusted_hash = "trusted-user"' "$(_trust_at 1 0)" || return 1
    assert_eq '' "$(_trust_at 1 1)" || return 1
    assert_eq '' "$(_trust_at 0 0 post_tool_use)" || return 1
    assert_eq '' "$(_trust_at 0 0 stop)" || return 1
    assert_eq '' "$(_trust_at 0 0 user_prompt_submit)" || return 1
    assert_eq '' "$(_trust_at 0 0 permission_request)" || return 1
    assert_file_not_exists "$CODEX_DIR/hooks/cs/autosave-commits.sh" || return 1
}

# One hook the uninstaller cannot remove leaves the others to go on their own,
# and the warning names the event that stayed, not one that was removed.
test_uninstall_removes_the_other_hooks_when_one_fails() {
    CODEX_DIR="$TEST_TMPDIR/codex-one-fails"
    mkdir -p "$CODEX_DIR"
    local fake_home="$TEST_TMPDIR/one-fails-home" event verb tmp
    mkdir -p "$fake_home"
    HOME="$fake_home" CODEX_HOME="$CODEX_DIR" CS_INSTALL_ENGINES=codex \
        bash "$SCRIPT_DIR/../install.sh" </dev/null > "$TEST_TMPDIR/install.log" 2>&1 \
        || { cat "$TEST_TMPDIR/install.log"; return 1; }
    # A Stop entry edited into an object, not a list of groups: removing cs's
    # handler from it fails, as it would for any hooks.json cs cannot read.
    tmp="$CODEX_DIR/hooks.json.edit"
    jq --arg stop "$fake_home/.local/bin/cs -codex-hook stop" \
        '.hooks.Stop = {x: {hooks: [{type: "command", command: $stop}]}}' \
        "$CODEX_DIR/hooks.json" > "$tmp" && mv "$tmp" "$CODEX_DIR/hooks.json" || return 1
    printf 'y\nn\nn\n' | HOME="$fake_home" CODEX_HOME="$CODEX_DIR" \
        env -u CODE_SESSIONS_HOME -u CS_INSTALL_DIR -u CS_CONFIG_DIR -u CS_CACHE_DIR \
        -u CS_HOOKS_DIR -u CS_CLAUDE_DIR -u CS_SKILLS_DIR -u CS_COMMANDS_DIR \
        "$fake_home/.local/bin/cs" -uninstall \
        > "$TEST_TMPDIR/uninstall.log" 2>&1 || { cat "$TEST_TMPDIR/uninstall.log"; return 1; }
    for event in SessionStart:session-start PostToolUse:files-changed UserPromptSubmit:user-prompt-submit \
        PermissionRequest:permission-request; do
        verb=${event#*:}; event=${event%%:*}
        assert_eq 0 "$(jq --arg e "$event" --arg v " -codex-hook $verb" \
            '[.hooks[$e][]?.hooks[]? | select(.command | endswith($v))] | length' "$CODEX_DIR/hooks.json")" \
            "cs's $event hook outlived a failed Stop removal" || return 1
    done
    assert_file_contains "$TEST_TMPDIR/uninstall.log" "Could not remove the cs hooks for Stop from" || return 1
    assert_file_not_contains "$TEST_TMPDIR/uninstall.log" "SessionStart entry" || return 1
}

test_recovery_registration_preserves_mixed_handlers_and_trust() {
    _mixed_group 1
    jq '.hooks.PostToolUse = .hooks.SessionStart | del(.hooks.SessionStart)
        | .hooks.PostToolUse[1].hooks[1].command = "/old/cs -codex-hook files-changed"' \
        "$CODEX_DIR/hooks.json" > "$TEST_TMPDIR/new.json"
    mv "$TEST_TMPDIR/new.json" "$CODEX_DIR/hooks.json"
    sed 's/session_start/post_tool_use/g' "$CODEX_DIR/config.toml" > "$TEST_TMPDIR/new.toml"
    mv "$TEST_TMPDIR/new.toml" "$CODEX_DIR/config.toml"
    local original expected
    original=$(jq -S . "$CODEX_DIR/hooks.json")
    expected=$(jq -S '.hooks.PostToolUse[1].hooks[1].command = "/new/cs -codex-hook files-changed"' "$CODEX_DIR/hooks.json")
    _codex_hooks_register "$CODEX_DIR" '/new/cs -codex-hook files-changed' PostToolUse post_tool_use files-changed || return 1
    assert_eq "$expected" "$(jq -S . "$CODEX_DIR/hooks.json")" || return 1
    assert_eq 'trusted_hash = "trusted-user"' "$(_trust_at 1 0 post_tool_use)" || return 1
    assert_eq '' "$(_trust_at 1 2 post_tool_use)" || return 1
    _codex_hooks_unregister "$CODEX_DIR" PostToolUse post_tool_use files-changed || return 1
    assert_eq "$(printf '%s' "$original" | jq -S 'del(.hooks.PostToolUse[1].hooks[1])')" "$(jq -S . "$CODEX_DIR/hooks.json")" || return 1
    assert_eq 'trusted_hash = "trusted-user"' "$(_trust_at 1 0 post_tool_use)" || return 1
    assert_eq '' "$(_trust_at 1 1 post_tool_use)"
}

run_test test_reinstall_preserves_mixed_group_and_trust
run_test test_uninstall_preserves_mixed_group_and_moves_only_its_handler_trust
run_test test_installer_and_uninstaller_preserve_a_mixed_group
run_test test_uninstall_removes_the_other_hooks_when_one_fails
run_test test_recovery_registration_preserves_mixed_handlers_and_trust
report_results
