#!/usr/bin/env bash
# ABOUTME: Tests the diagram instruction in a session's CLAUDE.local.md.
# ABOUTME: Covers new-session creation and the sentinel-only opt-out.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

test_new_session_has_the_diagram_instruction() {
    local file="$CS_SESSIONS_ROOT/fresh/CLAUDE.local.md"
    "$CS_BIN" fresh <<< "" > /dev/null 2>&1 \
        || { echo "  FAIL: creating the session failed"; return 1; }
    assert_file_contains "$file" '^<!-- cs:mermaid-diagrams -->$' \
        "new sessions carry the diagram sentinel" || return 1
    assert_file_contains "$file" '^## Diagrams$' "the instruction has its heading" || return 1
    assert_file_contains "$file" '^Mermaid flowchart fences' \
        "the session tells the model that flowchart fences draw" || return 1
    assert_eq '<!-- cs:mermaid-diagrams -->' "$(grep '^<!-- cs:' "$file" | tail -1)" \
        "the diagram section is the last managed block" || return 1
    assert_eq '## Diagrams' "$(grep '^## ' "$file" | tail -1)" \
        "the diagram section follows every other heading" || return 1
    assert_eq 'Mermaid flowchart fences (```mermaid with graph TD or graph LR) are drawn as diagrams in this terminal. Add one beside the prose only when an answer describes a flow that branches, loops or has four or more stages; never for a task list or numbered steps. One fence, short labels, no subgraphs; `{ }` for a decision, `(( ))` for a start or end, `[ ]` for a step; other diagram types show as source.' \
        "$(grep '^Mermaid flowchart fences' "$file")" "the diagram instruction is verbatim" || return 1
}

test_a_diagram_tombstone_keeps_the_local_file_unchanged() {
    local dir="$CS_SESSIONS_ROOT/opted"
    mkdir -p "$dir"
    printf '%s\n' '<!-- cs:mermaid-diagrams -->' > "$dir/CLAUDE.local.md"
    cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/before"
    # shellcheck source=lib/35-claudemd.sh
    source "$SCRIPT_DIR/../lib/35-claudemd.sh"
    ensure_session_claude_md "$dir"
    cmp -s "$TEST_TMPDIR/before" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: the diagram tombstone file changed"; return 1; }
}

run_test test_new_session_has_the_diagram_instruction
run_test test_a_diagram_tombstone_keeps_the_local_file_unchanged
report_results
