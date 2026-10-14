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
    awk -v head="[hooks.state.\"$CODEX_DIR/hooks.json:session_start:$1:$2\"]" '
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
        '.hooks.SessionStart[1].hooks[1].command = $cmd' "$CODEX_DIR/hooks.json")
    after_remove=$(jq -S 'del(.hooks.SessionStart[1].hooks[1])' "$CODEX_DIR/hooks.json")
    for pass in 1 2; do
        HOME="$fake_home" CODEX_HOME="$CODEX_DIR" CS_INSTALL_ENGINES=codex \
            bash "$SCRIPT_DIR/../install.sh" </dev/null > "$TEST_TMPDIR/install.log" 2>&1 \
            || { cat "$TEST_TMPDIR/install.log"; return 1; }
        assert_eq "$expected" "$(jq -S . "$CODEX_DIR/hooks.json")" "install pass $pass preserves neighbors" || return 1
        assert_eq 'trusted_hash = "trusted-user"' "$(_trust_at 1 0)" || return 1
        assert_eq '' "$(_trust_at 1 2)" || return 1
    done
    printf 'y\nn\nn\n' | HOME="$fake_home" CODEX_HOME="$CODEX_DIR" "$fake_home/.local/bin/cs" -uninstall \
        > "$TEST_TMPDIR/uninstall.log" 2>&1 || { cat "$TEST_TMPDIR/uninstall.log"; return 1; }
    assert_eq "$after_remove" "$(jq -S . "$CODEX_DIR/hooks.json")" || return 1
    assert_eq 'trusted_hash = "trusted-user"' "$(_trust_at 1 0)" || return 1
    assert_eq '' "$(_trust_at 1 1)" || return 1
}

run_test test_reinstall_preserves_mixed_group_and_trust
run_test test_uninstall_preserves_mixed_group_and_moves_only_its_handler_trust
run_test test_installer_and_uninstaller_preserve_a_mixed_group
report_results
