#!/usr/bin/env bash
# ABOUTME: Tests the session-commits rule in the session protocol: a new session carries it,
# ABOUTME: an existing session gains it once on migration, and a tombstone keeps it out.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

SENTINEL='<!-- cs:session-commits -->'
RULE='Apart from the one commit that creates a new session, cs, its skills and its commands never commit files under `.cs/` (narratives, handoffs, `.cs/README.md`, `.cs/summary.md`, memory entries, the task archive), and neither do you on your own: commit them only when the user asks. Uncommitted, they are safe: autosave snapshots every Write and Edit to a shadow ref.'

# Open a session, answering the resume prompt. Prints cs's output.
_open() {  # name
    CS_ACTOR=alice "$CS_BIN" "$1" <<< "" 2>&1
}

# Lines of a file equal to the given text.
_count_lines() {  # file, text
    grep -cxF -- "$2" "$1" || true
}

test_new_session_carries_the_session_commit_rule() {
    local file="$CS_SESSIONS_ROOT/fresh/CLAUDE.local.md"
    _open fresh > /dev/null || { echo "  FAIL: creating the session failed"; return 1; }
    assert_eq "1" "$(_count_lines "$file" "$SENTINEL")" "the sentinel appears once" || return 1
    assert_eq "1" "$(_count_lines "$file" "## Committing session files")" "under its heading" || return 1
    assert_eq "1" "$(_count_lines "$file" "$RULE")" "the rule is in the protocol" || return 1
}

# A session created before the rule existed: its protocol carries the other
# managed sections and not this one. The migration runs its one-time phases
# only without a fresh stamp, as after an upgrade.
test_existing_session_gains_the_rule_once() {
    local dir="$CS_SESSIONS_ROOT/older" file before size
    file="$dir/CLAUDE.local.md"
    _open older > /dev/null || { echo "  FAIL: creating the session failed"; return 1; }
    printf '%s\n' '<!-- cs:session-protocol -->' '# Session Documentation Protocol' '' 'protocol body' \
        '' '<!-- cs:memory-note -->' '## Where memory lives' '' 'note body' \
        '' '<!-- cs:wrap-cues -->' '## Session wrap-up cues' '' 'cues body' > "$file"
    before=$(cat "$file")
    rm -f "$dir/.cs/local/migrated"
    _open older > /dev/null || { echo "  FAIL: the reopen failed"; return 1; }
    assert_eq "1" "$(_count_lines "$file" "$SENTINEL")" "the migration adds the sentinel" || return 1
    assert_eq "1" "$(_count_lines "$file" "$RULE")" "and the rule" || return 1
    assert_eq "$before" "$(head -n 14 "$file")" "the existing protocol stays as it was, above the rule" || return 1
    size=$(wc -c < "$file" | tr -d ' ')
    rm -f "$dir/.cs/local/migrated"
    _open older > /dev/null || { echo "  FAIL: the second reopen failed"; return 1; }
    assert_eq "$size" "$(wc -c < "$file" | tr -d ' ')" "a second migration adds nothing" || return 1
}

test_tombstone_keeps_the_rule_out() {
    local dir="$CS_SESSIONS_ROOT/opted" file
    file="$dir/CLAUDE.local.md"
    _open opted > /dev/null || { echo "  FAIL: creating the session failed"; return 1; }
    printf '%s\n' '<!-- cs:session-protocol -->' '# Session Documentation Protocol' '' 'protocol body' \
        '' '<!-- cs:memory-note -->' '' '<!-- cs:wrap-cues -->' '' "$SENTINEL" > "$file"
    rm -f "$dir/.cs/local/migrated"
    _open opted > /dev/null || { echo "  FAIL: the reopen failed"; return 1; }
    assert_eq "1" "$(_count_lines "$file" "$SENTINEL")" "the tombstone is not duplicated" || return 1
    assert_eq "0" "$(_count_lines "$file" "$RULE")" "and the rule is not re-added" || return 1
}

run_test test_new_session_carries_the_session_commit_rule
run_test test_existing_session_gains_the_rule_once
run_test test_tombstone_keeps_the_rule_out
report_results
