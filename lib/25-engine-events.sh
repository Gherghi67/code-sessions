# ABOUTME: Native successful file edits translated into one files_changed event.
# ABOUTME: Recovery consumers receive paths and identity, never native tool payloads.

# Each adapter reads native PostToolUse JSON on stdin. No applicable successful
# edit emits nothing and returns success; malformed input also fails open. Paths
# remain native paths, resolved against cwd by the shared recovery consumer.
_cs_claude_adapter_files_changed() {
    jq -c '
        select(type == "object")
        | select((.hook_event_name // "PostToolUse") == "PostToolUse")
        | select(.tool_name == "Write" or .tool_name == "Edit")
        | select(.error == null and .is_error != true)
        | select((.tool_response | type) != "object" or
            (.tool_response.is_error != true and .tool_response.success != false))
        | select(.tool_input.file_path | type == "string" and length > 0)
        | {type: "files_changed", engine: "claude", session_id: .session_id,
           cwd: (.cwd // ""), files: [.tool_input.file_path]}
    ' 2>/dev/null || true
}

_cs_codex_adapter_files_changed() {
    # Codex uses a command-shaped raw patch and a successful string response.
    # PostToolUse is only emitted after completion. Verify its success response
    # too: input alone also appears in pre-tool/permission hooks and failed calls.
    jq -c '
        select(type == "object")
        | select(.hook_event_name == "PostToolUse" and .tool_name == "apply_patch")
        | select(.error == null and .is_error != true)
        | select(.tool_response | type == "string" and startswith("Success. Updated the following files:\n"))
        | select(.tool_input.command | type == "string")
        | . as $input
        | (.tool_input.command | split("\n")) as $lines
        | select($lines[0] == "*** Begin Patch" and $lines[-1] == "*** End Patch" or
            $lines[0] == "*** Begin Patch" and $lines[-2] == "*** End Patch" and $lines[-1] == "")
        | [$lines[] | select(test("^\\*\\*\\* (Add File|Delete File|Update File|Move to): .+"))
            | sub("^\\*\\*\\* (Add File|Delete File|Update File|Move to): "; "")]
          | unique as $files
        | select($files | length > 0)
        | {type: "files_changed", engine: "codex", session_id: $input.session_id,
           cwd: ($input.cwd // ""), files: $files}
    ' 2>/dev/null || true
}
