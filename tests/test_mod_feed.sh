#!/usr/bin/env bash
# ABOUTME: Tests for the cs-feed mod under mods/cs-feed (a Claude Code function-hooks plugin that restyles the chat per session).
# ABOUTME: Pins the manifest and the installer listing, lints the hook source, and runs plugin validate, tsc and the engine test kit when claude is present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-feed"

setup() { :; }
teardown() { :; }

# The one shape every session registers (rationale decision 1): its exact
# inventory, as `claude plugin validate` prints it.
HOOKS_LINE='./register.tsx hooks: session.start, command.run{command=feed}, command.run{command=helpers}, ui.press{plugin=cs, element=cs-feed}, ui.render{component=Pane, requestId=cs-feed}, ui.render{component=Pane, requestId=cs-feed-helpers}, session.append{door=prompt}, session.append{door=command}, session.append{door=response}, session.append{door=tool-result}, session.append{door=delivery}, turn.start, turn.complete, agent.spawn, ui.render{component=UserMessage}, ui.render{component=AssistantMessage}, ui.render{component=ToolUse}, ui.render{component=ToolGroup}, ui.render{component=ToolResult}, ui.render{component=ToolProgress}, ui.render{component=TurnDuration}, ui.render{component=CommandOutput}, ui.render{component=Spinner}, ui.render{component=SessionMode}, ui.render{component=AbovePrompt}'

test_mod_manifest_names_the_plugin_its_module_and_its_state_types() {
    local manifest="$MOD/.claude-plugin/plugin.json"
    assert_eq "cs-feed" "$(jq -r .name "$manifest")" "plugin name" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_eq "1" "$(jq '.modules | length' "$MOD/hooks/hooks.json")" "one hooks module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
    local types
    types="$(jq -r .types "$manifest")"
    assert_eq "./hooks/state.d.ts" "$types" "types names the state declarations" || return 1
    assert_file_exists "$MOD/${types#./}" "the types file exists" || return 1
    # No install switch (ruling 1): the on/off is the session's .cs/local/feed, never a /config row.
    assert_eq "false" "$(jq 'has("userConfig")' "$manifest")" "no userConfig" || return 1
}

test_mod_is_deployed_by_the_installer() {
    local file
    for file in .claude-plugin/plugin.json hooks/hooks.json hooks/draw.tsx hooks/register.tsx hooks/session.ts hooks/settings.ts hooks/state.d.ts hooks/transcript.ts hooks/verdict.ts hooks/words.ts; do
        assert_file_exists "$MOD/$file" "the mod has $file" || return 1
        grep -qF "cs-feed/$file" "$SCRIPT_DIR/../install.sh" \
            || { echo "  FAIL: install.sh does not deploy cs-feed/$file"; return 1; }
    done
    # Every module file under hooks/ is deployed, so a new one cannot be left out.
    for file in "$MOD"/hooks/*; do
        grep -qF "cs-feed/hooks/$(basename "$file")" "$SCRIPT_DIR/../install.sh" \
            || { echo "  FAIL: install.sh does not deploy cs-feed/hooks/$(basename "$file")"; return 1; }
    done
}

# Nothing the feed registers awaits across a tool call or a stream, it never
# reads a classic hook or rewrites the prompt, it has no install switch, and
# it runs no command (rationale decision 4, ruling 1, (b) "No $.command.run").
test_mod_source_never_spells_the_refused_events_or_command_run() {
    local event hits
    for event in tool.call turn.step prompt.compose config.set; do
        hits="$(grep -rnF -e "'$event'" -e "\"$event\"" "$MOD/hooks")"
        [ -z "$hits" ] || { echo "  FAIL: the hooks name $event:"; echo "$hits"; return 1; }
    done
    hits="$(grep -rnF -e "'classic." -e '"classic.' -e '$.command.run' "$MOD/hooks")"
    [ -z "$hits" ] || { echo "  FAIL: the hooks name a classic event or \$.command.run:"; echo "$hits"; return 1; }
}

test_mod_validate_inventories_the_one_shape() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-feed-validate.$$"
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
    if ! grep -q 'hooks:' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) does not inventory function hooks"
        return 77
    fi
    local line
    line="$(grep -F './register.tsx hooks:' <<< "$out" | sed 's/^[^.]*//')"
    assert_eq "$HOOKS_LINE" "$line" "the exact hooks inventory" || return 1
}

# The engine writes its types under .claude-plugin/types on first use, and
# gitignores them; a checkout without them borrows the cs mod's copy for the
# check and removes it after. A copy already present is used as it is.
test_mod_typechecks_against_the_engine_contract() {
    require_tool npx || return $?
    local target="$MOD/.claude-plugin/types" source="$SCRIPT_DIR/../mods/cs/.claude-plugin/types" copied=0
    if [ ! -d "$target" ]; then
        if [ ! -d "$source" ]; then
            echo "    SKIP: no engine-written types here or in mods/cs (the engine writes them on first use)"
            return 77
        fi
        cp -R "$source" "$target" || { echo "  FAIL: could not copy the engine types"; return 1; }
        copied=1
    fi
    local out status
    out="$(cd "$MOD" && npx tsc -p tsconfig.json 2>&1)"
    status=$?
    [ "$copied" -eq 1 ] && rm -rf "$target"
    assert_eq "0" "$status" "tsc exits 0, painters.typecheck.ts included" || { echo "$out"; return 1; }
}

# The tests import claude-code/testing, the engine's own kit, so they run under
# `claude plugin test`, not bare bun; the kit runs only with function hooks on.
test_mod_unit_tests_pass_under_the_engine_test_kit() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-feed-test.$$"
    env -u ANTHROPIC_API_KEY CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    if grep -q 'unknown command' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) has no plugin test"
        return 77
    fi
    assert_eq "0" "$status" "plugin test exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" " 0 fail" "no unit test fails" || return 1
    assert_output_not_contains "$out" " 0 pass" "the suite ran something" || return 1
}

run_test test_mod_manifest_names_the_plugin_its_module_and_its_state_types
run_test test_mod_is_deployed_by_the_installer
run_test test_mod_source_never_spells_the_refused_events_or_command_run
run_test test_mod_validate_inventories_the_one_shape
run_test test_mod_typechecks_against_the_engine_contract
run_test test_mod_unit_tests_pass_under_the_engine_test_kit

report_results
