#!/usr/bin/env bash
# ABOUTME: Shared-config setup, migration and launcher regressions in fake homes.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
REPO="$SCRIPT_DIR/.."

stage_checkout() {
    local payload
    use_fake_keychain
    CHECKOUT="$TEST_TMPDIR/checkout with spaces"
    LEGACY="$HOME/.local/share/code-sessions/home"
    mkdir -p "$CHECKOUT/bin" "$CHECKOUT/tui" "$TEST_TMPDIR/tools"
    cp "$REPO/setup.sh" "$REPO/build.sh" "$REPO/install.sh.in" "$CHECKOUT/"
    for payload in lib hooks skills mods completions scripts; do
        cp -R "$REPO/$payload" "$CHECKOUT/"
    done
    for payload in cs-secrets cs-codex-thread cs-statusline cs-subagent-statusline; do
        cp "$REPO/bin/$payload" "$CHECKOUT/bin/"
    done
    cp "$REPO/tui/Cargo.toml" "$REPO/tui/Cargo.lock" "$CHECKOUT/tui/"
    cat > "$TEST_TMPDIR/tools/cargo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CS_SETUP_CARGO_LOG"
[ "${CS_SETUP_CARGO_FAIL:-0}" -eq 0 ] || exit 7
mkdir -p tui/target/release
printf '#!/bin/sh\nprintf "picker fixture\\n"\n' > tui/target/release/cs-tui
chmod +x tui/target/release/cs-tui
EOF
    chmod +x "$TEST_TMPDIR/tools/cargo"
}
run_setup() {
    (
        cd "$TEST_TMPDIR"
        PATH="$TEST_TMPDIR/tools:$PATH" SHELL="${TEST_SHELL:-/bin/zsh}" \
            CS_SETUP_CARGO_LOG="$TEST_TMPDIR/cargo.log" sh "$CHECKOUT/setup.sh" "$@" </dev/null
    ) > "$TEST_TMPDIR/setup.log" 2>&1 || { cat "$TEST_TMPDIR/setup.log"; return 1; }
}

test_shared_setup_installs_normal_engines_and_replaces_cs_with_backup() {
    stage_checkout
    mkdir -p "$HOME/.local/bin" "$HOME/.claude"
    printf '#!/bin/sh\necho original\n' > "$HOME/.local/bin/cs"
    printf '{"env":{"MY_SETTING":"keep"}}\n' > "$HOME/.claude/settings.json"
    run_setup || return 1
    assert_output_contains "$("$HOME/.local/bin/cs" -version)" '(code-sessions, a fork of cs)' || return 1
    assert_eq 'claude,codex' "$(cat "$HOME/.local/bin/.cs-install-engines")" || return 1
    assert_eq 'picker fixture' "$("$HOME/.local/bin/cs-tui")" || return 1
    assert_eq keep "$(jq -r .env.MY_SETTING "$HOME/.claude/settings.json")" || return 1
    assert_file_exists "$HOME/.claude/skills/finish/SKILL.md" || return 1
    assert_file_exists "$HOME/.codex/skills/finish/SKILL.md" || return 1
    jq -e '.hooks.SessionStart | length > 0' "$HOME/.claude/settings.json" >/dev/null || return 1
    jq -e '.hooks.SessionStart | length > 0' "$HOME/.codex/hooks.json" >/dev/null || return 1
    local saved
    saved=$(find "$HOME/.local/share/code-sessions/backups" -path '*/.local/bin/cs' -type f | head -1)
    assert_file_contains "$saved" 'echo original' || return 1
    assert_not_exists "$LEGACY/.claude" || return 1
    assert_not_exists "$LEGACY/.codex" || return 1
    assert_eq "$("$HOME/.local/bin/ccs" -version)" "$("$HOME/.local/bin/cs" -version)"
}

test_shared_setup_imports_history_without_moving_projects_or_credentials() {
    stage_checkout
    mkdir -p "$LEGACY/.claude/projects/project" "$LEGACY/.codex/sessions/2026" "$LEGACY/sessions/ask/.cs" "$HOME/.codex"
    printf '{"conversation":1}\n' > "$LEGACY/.claude/projects/project/thread.jsonl"
    printf '{"rollout":1}\n' > "$LEGACY/.codex/sessions/2026/rollout.jsonl"
    printf 'normal login\n' > "$HOME/.codex/auth.json"
    printf 'old login\n' > "$LEGACY/.codex/auth.json"
    run_setup --skip-tui-build || return 1
    assert_file_exists "$HOME/.claude/projects/project/thread.jsonl" || return 1
    assert_file_exists "$HOME/.codex/sessions/2026/rollout.jsonl" || return 1
    assert_file_exists "$LEGACY/.codex/sessions/2026/rollout.jsonl" || return 1
    assert_file_contains "$HOME/.codex/auth.json" 'normal login' || return 1
    assert_file_contains "$LEGACY/.codex/auth.json" 'old login' || return 1
    assert_exists "$LEGACY/sessions/ask/.cs"
}

test_launcher_clears_inherited_profile_config_and_preserves_manager_data() {
    stage_checkout
    mkdir -p "$HOME/.local/bin" "$LEGACY/sessions"
    cp "$REPO/scripts/code-sessions-profile.sh" "$HOME/.local/bin/ccs"
    chmod +x "$HOME/.local/bin/ccs"
    cat > "$HOME/.local/bin/cs" <<'EOF'
#!/bin/sh
printf 'claude=%s codex=%s hooks=%s profile=%s\n' "${CLAUDE_CONFIG_DIR-unset}" "${CODEX_HOME-unset}" "${CS_HOOKS_DIR-unset}" "${CODE_SESSIONS_HOME-unset}"
printf 'sessions=%s secrets=%s\n' "$CS_SESSIONS_ROOT" "$CS_SECRETS_KEYCHAIN_PREFIX"
EOF
    chmod +x "$HOME/.local/bin/cs"
    local output
    output=$(CLAUDE_CONFIG_DIR="$LEGACY/.claude" CODEX_HOME="$LEGACY/.codex" CS_HOOKS_DIR="$LEGACY/.claude/hooks/cs" \
        CODE_SESSIONS_HOME="$LEGACY" "$HOME/.local/bin/ccs" .) || return 1
    assert_output_contains "$output" 'claude=unset codex=unset hooks=unset profile=unset' || return 1
    assert_output_contains "$output" "sessions=$LEGACY/sessions secrets=code-sessions" || return 1
    output=$(CLAUDE_CONFIG_DIR="$HOME/custom-claude" CODEX_HOME="$HOME/custom-codex" "$HOME/.local/bin/ccs") || return 1
    assert_output_contains "$output" "claude=$HOME/custom-claude codex=$HOME/custom-codex"
}

test_setup_from_old_session_still_installs_only_normal_integrations() {
    stage_checkout
    CLAUDE_CONFIG_DIR="$LEGACY/.claude" CODEX_HOME="$LEGACY/.codex" CODE_SESSIONS_HOME="$LEGACY" \
        CS_INSTALL_DIR="$LEGACY/.local/bin" CS_HOOKS_DIR="$LEGACY/.claude/hooks/cs" run_setup --skip-tui-build || return 1
    assert_file_exists "$HOME/.claude/settings.json" || return 1
    assert_file_exists "$HOME/.codex/hooks.json" || return 1
    assert_not_exists "$LEGACY/.claude/settings.json" || return 1
    assert_not_exists "$LEGACY/.codex/hooks.json"
}

test_setup_reinstall_preserves_preferences_and_unique_path() {
    stage_checkout
    printf '# my shell settings\n' > "$HOME/.zshrc"
    run_setup --skip-tui-build || return 1
    run_setup --skip-tui-build || return 1
    assert_file_contains "$HOME/.zshrc" '# my shell settings' || return 1
    assert_eq 1 "$(grep -c '^# >>> code-sessions PATH >>>$' "$HOME/.zshrc")"
}

test_build_failure_does_not_replace_original_or_import_history() {
    stage_checkout
    mkdir -p "$HOME/.local/bin"
    printf 'original\n' > "$HOME/.local/bin/cs"
    if CS_SETUP_CARGO_FAIL=1 run_setup; then return 1; fi
    assert_eq original "$(cat "$HOME/.local/bin/cs")" || return 1
    assert_not_exists "$HOME/.claude"
}

test_direct_install_requires_explicit_replacement() {
    stage_checkout
    (cd "$CHECKOUT" && bash build.sh) >/dev/null
    mkdir -p "$HOME/.local/bin"
    printf 'original\n' > "$HOME/.local/bin/cs"
    if SHELL=/bin/sh bash "$CHECKOUT/install.sh" </dev/null > "$TEST_TMPDIR/refusal" 2>&1; then return 1; fi
    assert_file_contains "$TEST_TMPDIR/refusal" 'Run sh setup.sh' || return 1
    assert_eq original "$(cat "$HOME/.local/bin/cs")"
}

test_shared_config_history_regressions() {
    python3 -B "$REPO/tests/test_shared_config.py"
}

run_test test_shared_setup_installs_normal_engines_and_replaces_cs_with_backup
run_test test_shared_setup_imports_history_without_moving_projects_or_credentials
run_test test_launcher_clears_inherited_profile_config_and_preserves_manager_data
run_test test_setup_from_old_session_still_installs_only_normal_integrations
run_test test_setup_reinstall_preserves_preferences_and_unique_path
run_test test_build_failure_does_not_replace_original_or_import_history
run_test test_direct_install_requires_explicit_replacement
run_test test_shared_config_history_regressions
report_results
