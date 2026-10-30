#!/usr/bin/env bash
# ABOUTME: Native engine edit events feed the same recovery snapshot consumer.
# ABOUTME: Exercises completed patch batches, failures, index isolation and installation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/24-engine-adapters.sh"
source "$SCRIPT_DIR/../lib/25-engine-events.sh"
UUID=33333333-3333-4333-8333-333333333333
REF="refs/worktree/cs/session/$UUID"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export CS_SESSION_DIR="$TEST_TMPDIR/session" CS_SESSION_NAME=test
    export CS_SESSION_META_DIR="$CS_SESSION_DIR/.cs" CS_TEST_SYNC=1
    export CODEX_HOME="$TEST_TMPDIR/codex" CS_RUN_ENGINE=codex
    mkdir -p "$CS_SESSION_DIR/.cs/local" "$CODEX_HOME/hooks/cs"
    for f in autosave-commits.sh cs-resolve.sh cs-shared.sh cs-engine-events.sh; do
        cp "$SCRIPT_DIR/../hooks/$f" "$CODEX_HOME/hooks/cs/$f"
    done
    git -C "$CS_SESSION_DIR" init -q
    git -C "$CS_SESSION_DIR" config user.email test@example.com
    git -C "$CS_SESSION_DIR" config user.name Test
    printf 'initial\n' > "$CS_SESSION_DIR/login.ts"
    printf 'initial\n' > "$CS_SESSION_DIR/users.ts"
    git -C "$CS_SESSION_DIR" add -A
    git -C "$CS_SESSION_DIR" commit -qm initial
}

teardown() {
    rm -rf "$TEST_TMPDIR" "$HOME/.gemini"
    unset CS_SESSION_DIR CS_SESSION_NAME CS_SESSION_META_DIR CS_TEST_SYNC CODEX_HOME CS_RUN_ENGINE
    unset CS_RUN_ID CS_RUN_OWNER_PID
}

_codex_payload() {  # raw patch, [response]
    jq -nc --arg id "$UUID" --arg cwd "$CS_SESSION_DIR" --arg patch "$1" \
        --arg response "${2-Success. Updated the following files:
M login.ts}" \
        '{hook_event_name: "PostToolUse", session_id: $id, cwd: $cwd,
          tool_name: "apply_patch", tool_input: {command: $patch}, tool_response: $response}'
}

_claude_payload() {  # path
    jq -nc --arg id "$UUID" --arg cwd "$CS_SESSION_DIR" --arg path "$1" \
        '{hook_event_name: "PostToolUse", session_id: $id, cwd: $cwd,
          tool_name: "Edit", tool_input: {file_path: $path}, tool_response: {success: true}}'
}

_ref() { git -C "$CS_SESSION_DIR" rev-parse -q --verify "$REF" 2>/dev/null || true; }

_patch='*** Begin Patch
*** Update File: login.ts
@@
-initial
+changed
*** Update File: users.ts
@@
-initial
+changed
*** End Patch'

test_adapters_translate_native_edits_to_common_events() {
    local event
    event=$(_claude_payload login.ts | cs_engine_call claude files_changed)
    assert_eq '["login.ts"]' "$(printf '%s' "$event" | jq -c .files)" || return 1
    assert_eq files_changed "$(printf '%s' "$event" | jq -r .type)" || return 1
    event=$(_codex_payload '*** Begin Patch
*** Delete File: gone.ts
*** Update File: old name.ts
*** Move to: new name.ts
*** Add File: users.ts
*** End Patch' | cs_engine_call codex files_changed)
    assert_eq '["gone.ts","new name.ts","old name.ts","users.ts"]' "$(printf '%s' "$event" | jq -c .files)" || return 1
    assert_eq "$UUID" "$(printf '%s' "$event" | jq -r .session_id)" || return 1
    assert_eq "$CS_SESSION_DIR" "$(printf '%s' "$event" | jq -r .cwd)"
}

_assert_native_patch_snapshot() {  # original successful patch input
    local event response='Success. Updated the following files:
M login.ts
M users.ts'
    printf 'changed\n' > "$CS_SESSION_DIR/login.ts"
    printf 'changed\n' > "$CS_SESSION_DIR/users.ts"
    event=$(_codex_payload "$1" "$response" | cs_engine_call codex files_changed)
    assert_eq '["login.ts","users.ts"]' "$(printf '%s' "$event" | jq -c .files)" || return 1
    _codex_payload "$1" "$response" | "$CS_BIN" -codex-hook files-changed || return 1
    assert_eq changed "$(git -C "$CS_SESSION_DIR" show "$REF:login.ts")" || return 1
    assert_eq changed "$(git -C "$CS_SESSION_DIR" show "$REF:users.ts")" || return 1
}

test_native_patch_with_leading_whitespace_is_saved() {
    _assert_native_patch_snapshot $' \t\n'"$_patch"
}

test_native_patch_with_extra_trailing_newlines_is_saved() {
    _assert_native_patch_snapshot "$_patch"$'\n\n'
}

test_native_crlf_patch_is_saved_without_carriage_returns_in_paths() {
    _assert_native_patch_snapshot "${_patch//$'\n'/$'\r\n'}"
}

test_native_patch_heredoc_wrappers_are_saved() {
    local opener
    for opener in '<<EOF' "<<'EOF'" '<<"EOF"'; do
        _assert_native_patch_snapshot "$opener"$'\n'"$_patch"$'\nEOF\n' || return 1
    done
}

test_failed_unrelated_and_pre_tool_events_emit_nothing() {
    local payload event
    payload=$(_codex_payload "$_patch")
    for event in '.hook_event_name = "PreToolUse"' '.tool_name = "exec_command"' \
        '.tool_response = "Failed to apply patch"' '.error = "denied"' \
        '.tool_input.command = "*** Begin Patch\n*** End Patch"' \
        '.tool_input.command += "\nunexpected"' \
        '.tool_input.command = "unexpected\n" + .tool_input.command'; do
        assert_eq '' "$(printf '%s' "$payload" | jq "$event" | cs_engine_call codex files_changed)" || return 1
    done
    payload=$(_claude_payload login.ts)
    assert_eq '' "$(printf '%s' "$payload" | jq '.tool_response.success = false' | cs_engine_call claude files_changed)" || return 1
    assert_eq '' "$(printf '%s' "$payload" | jq '.hook_event_name = "PostToolUseFailure"' | cs_engine_call claude files_changed)" || return 1
    assert_eq '' "$(printf '%s' invalid | cs_engine_call codex files_changed)"
}

test_codex_batch_snapshots_both_files_and_preserves_index_and_head() {
    local head index event
    head=$(git -C "$CS_SESSION_DIR" rev-parse HEAD)
    printf 'staged\n' > "$CS_SESSION_DIR/login.ts"
    git -C "$CS_SESSION_DIR" add login.ts
    index=$(git -C "$CS_SESSION_DIR" write-tree)
    printf 'changed\n' > "$CS_SESSION_DIR/login.ts"
    printf 'changed\n' > "$CS_SESSION_DIR/users.ts"
    _codex_payload "$_patch" | "$CS_BIN" -codex-hook files-changed || return 1
    assert_eq changed "$(git -C "$CS_SESSION_DIR" show "$REF:login.ts")" || return 1
    assert_eq changed "$(git -C "$CS_SESSION_DIR" show "$REF:users.ts")" || return 1
    assert_eq "$head" "$(git -C "$CS_SESSION_DIR" rev-parse HEAD)" || return 1
    assert_eq "$index" "$(git -C "$CS_SESSION_DIR" write-tree)" || return 1
    assert_output_contains "$(git -C "$CS_SESSION_DIR" show -s --format=%B "$REF")" "cs-base: $head"
}

test_claude_separate_edits_snapshot_the_same_final_tree() {
    printf 'changed\n' > "$CS_SESSION_DIR/login.ts"
    _claude_payload login.ts | bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" || return 1
    local first
    first=$(_ref)
    [ -n "$first" ] || return 1
    printf 'changed\n' > "$CS_SESSION_DIR/users.ts"
    _claude_payload users.ts | bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" || return 1
    assert_eq "$first" "$(git -C "$CS_SESSION_DIR" rev-parse "$REF^")" || return 1
    assert_eq changed "$(git -C "$CS_SESSION_DIR" show "$REF:login.ts")" || return 1
    assert_eq changed "$(git -C "$CS_SESSION_DIR" show "$REF:users.ts")"
}

test_codex_deletion_and_rename_are_saved() {
    mv "$CS_SESSION_DIR/login.ts" "$CS_SESSION_DIR/new name.ts"
    rm "$CS_SESSION_DIR/users.ts"
    _codex_payload '*** Begin Patch
*** Update File: login.ts
*** Move to: new name.ts
@@
-initial
+initial
*** Delete File: users.ts
*** End Patch' | "$CS_BIN" -codex-hook files-changed || return 1
    assert_eq initial "$(git -C "$CS_SESSION_DIR" show "$REF:new name.ts")" || return 1
    assert_eq '' "$(git -C "$CS_SESSION_DIR" ls-tree --name-only "$REF" -- login.ts users.ts)"
}

test_failed_and_duplicate_events_do_not_advance_snapshot() {
    printf 'changed\n' > "$CS_SESSION_DIR/login.ts"
    _codex_payload "$_patch" | "$CS_BIN" -codex-hook files-changed || return 1
    local first
    first=$(_ref)
    [ -n "$first" ] || return 1
    _codex_payload "$_patch" | "$CS_BIN" -codex-hook files-changed || return 1
    assert_eq "$first" "$(_ref)" || return 1
    printf 'unsaved\n' > "$CS_SESSION_DIR/login.ts"
    _codex_payload "$_patch" 'Error: denied' | "$CS_BIN" -codex-hook files-changed || return 1
    assert_eq "$first" "$(_ref)"
}

test_outside_traversal_and_malformed_events_do_not_snapshot() {
    local event
    mkdir -p "$TEST_TMPDIR/outside"
    for path in '../outside/file.ts' '../outside/nonexistent/file.ts'; do
        event=$(_claude_payload "$path" | cs_engine_call claude files_changed)
        printf '%s' "$event" | bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" --event || return 1
        assert_eq '' "$(_ref)" || return 1
    done
    event=$(_claude_payload login.ts | cs_engine_call claude files_changed)
    for invalid in '.session_id = "bad"' '.cwd = {}' '.files = []' '.engine = "other"'; do
        printf '%s' "$event" | jq "$invalid" | bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" --event || return 1
        assert_eq '' "$(_ref)" || return 1
    done
}

test_recovery_copy_supports_a_repository_without_an_index() {
    export CS_SESSION_DIR="$TEST_TMPDIR/unborn" CS_SESSION_META_DIR="$TEST_TMPDIR/unborn/.cs"
    mkdir -p "$CS_SESSION_META_DIR/local"
    git -C "$CS_SESSION_DIR" init -q
    git -C "$CS_SESSION_DIR" config user.email test@example.com
    git -C "$CS_SESSION_DIR" config user.name Test
    printf 'first file\n' > "$CS_SESSION_DIR/login.ts"
    _codex_payload '*** Begin Patch
*** Add File: login.ts
+first file
*** End Patch' | "$CS_BIN" -codex-hook files-changed || return 1
    assert_eq 'first file' "$(git -C "$CS_SESSION_DIR" show "$REF:login.ts")" || return 1
    assert_file_not_exists "$CS_SESSION_DIR/.git/index" || return 1
    assert_eq '' "$(git -C "$CS_SESSION_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)"
}

# agy's PostToolUse payload, as measured on agy 1.4.11: the call it ran, an
# empty error on success, no event name.
_agy_payload() {  # path, [tool], [error]
    jq -nc --arg id "$UUID" --arg ws "$CS_SESSION_DIR" --arg path "$1" \
        --arg tool "${2:-edit_file}" --arg error "${3-}" \
        '{conversationId: $id, workspacePaths: [$ws], modelName: "fake", stepIdx: 4, error: $error,
          toolCall: {name: $tool, args: {Path: $path, Target: "initial", Replacement: "changed"}}}'
}

# The hook's own run: cs's plugin with its recovery scripts in test_lib's
# temporary HOME; teardown removes it.
_agy_hook_home() {
    local script
    mkdir -p "$HOME/.gemini/config/plugins/cs/scripts"
    for script in autosave-commits.sh cs-resolve.sh cs-shared.sh cs-engine-events.sh; do
        cp "$SCRIPT_DIR/../hooks/$script" "$HOME/.gemini/config/plugins/cs/scripts/$script"
    done
}

# The session's run lease as a live Antigravity launch holds it, owned by
# this test's own shell.
_agy_lease() {
    export CS_RUN_ID=77777777-7777-4777-8777-777777777777 CS_RUN_OWNER_PID=$$
    printf '%s\n' "$$" > "$CS_SESSION_DIR/.cs/session.lock"
    jq -nc --arg id "$CS_RUN_ID" --argjson pid "$$" '{run_id: $id, engine: "antigravity", owner_pid: $pid}' \
        > "$CS_SESSION_DIR/.cs/local/run-lease.json"
}

test_antigravity_write_and_edit_become_common_events() {
    local event tool
    for tool in write_file edit_file; do
        event=$(_agy_payload "$CS_SESSION_DIR/login.ts" "$tool" | cs_engine_call antigravity files_changed)
        assert_eq "[\"$CS_SESSION_DIR/login.ts\"]" "$(printf '%s' "$event" | jq -c .files)" "$tool names its file" || return 1
        assert_eq antigravity "$(printf '%s' "$event" | jq -r .engine)" || return 1
        assert_eq "$UUID" "$(printf '%s' "$event" | jq -r .session_id)" "keyed by the conversation" || return 1
        assert_eq "$CS_SESSION_DIR" "$(printf '%s' "$event" | jq -r .cwd)" "the workspace is the cwd" || return 1
    done
    event=$(_agy_payload login.ts | jq 'del(.workspacePaths)' | cs_engine_call antigravity files_changed)
    assert_eq '' "$(printf '%s' "$event" | jq -r .cwd)" "no workspace leaves the session's to the consumer"
}

test_antigravity_failed_and_other_calls_emit_nothing() {
    local payload change
    payload=$(_agy_payload "$CS_SESSION_DIR/login.ts")
    assert_eq '' "$(_agy_payload "$CS_SESSION_DIR/login.ts" edit_file 'target not found' \
        | cs_engine_call antigravity files_changed)" "a failed edit" || return 1
    for change in '.toolCall.name = "run_command"' '.toolCall.name = "view_file"' \
        'del(.toolCall.args.Path)' '.toolCall.args.Path = ""' '.toolCall.args.Path = ["x"]' \
        'del(.toolCall)' '[.]'; do
        assert_eq '' "$(printf '%s' "$payload" | jq "$change" | cs_engine_call antigravity files_changed)" "$change" || return 1
    done
    assert_eq '' "$(printf '%s' invalid | cs_engine_call antigravity files_changed)" "malformed input"
}

test_antigravity_hook_snapshots_an_edit_only_in_its_run() {
    local output
    _agy_hook_home
    printf 'changed\n' > "$CS_SESSION_DIR/login.ts"
    output=$(_agy_payload "$CS_SESSION_DIR/login.ts" | CS_RUN_ENGINE=codex "$CS_BIN" -antigravity-hook post-tool-use) || return 1
    assert_eq '{}' "$output" "a hook outside an Antigravity run answers {}" || return 1
    assert_eq '' "$(_ref)" "and saves nothing" || return 1
    output=$(_agy_payload "$CS_SESSION_DIR/login.ts" | CS_RUN_ENGINE=antigravity "$CS_BIN" -antigravity-hook post-tool-use) || return 1
    assert_eq '{}' "$output" || return 1
    assert_eq '' "$(_ref)" "a run that does not hold the session's lease saves nothing" || return 1
    _agy_lease
    output=$(_agy_payload "$CS_SESSION_DIR/login.ts" | CS_RUN_ENGINE=antigravity "$CS_BIN" -antigravity-hook post-tool-use) || return 1
    assert_eq '{}' "$output" "the hook's stdout is {} alone" || return 1
    assert_eq changed "$(git -C "$CS_SESSION_DIR" show "$REF:login.ts")" "the edit is snapshotted" || return 1
    output=$(_agy_payload "$CS_SESSION_DIR/users.ts" edit_file denied \
        | CS_RUN_ENGINE=antigravity "$CS_BIN" -antigravity-hook post-tool-use) || return 1
    assert_eq '{}' "$output" || return 1
    assert_eq initial "$(git -C "$CS_SESSION_DIR" show "$REF:users.ts")" "a failed edit adds nothing"
}

run_test test_adapters_translate_native_edits_to_common_events
run_test test_native_patch_with_leading_whitespace_is_saved
run_test test_native_patch_with_extra_trailing_newlines_is_saved
run_test test_native_crlf_patch_is_saved_without_carriage_returns_in_paths
run_test test_native_patch_heredoc_wrappers_are_saved
run_test test_failed_unrelated_and_pre_tool_events_emit_nothing
run_test test_codex_batch_snapshots_both_files_and_preserves_index_and_head
run_test test_claude_separate_edits_snapshot_the_same_final_tree
run_test test_codex_deletion_and_rename_are_saved
run_test test_failed_and_duplicate_events_do_not_advance_snapshot
run_test test_outside_traversal_and_malformed_events_do_not_snapshot
run_test test_recovery_copy_supports_a_repository_without_an_index
run_test test_antigravity_write_and_edit_become_common_events
run_test test_antigravity_failed_and_other_calls_emit_nothing
run_test test_antigravity_hook_snapshots_an_edit_only_in_its_run
report_results
