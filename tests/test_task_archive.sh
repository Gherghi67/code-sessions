#!/usr/bin/env bash
# ABOUTME: Tests for cs -archive-tasks: moving completed native task rows out of
# ABOUTME: Claude Code's task store into the session's .cs/task-archive/<date>/.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# One session, one task list under a scoped HOME. The store is laid out the
# way Claude Code's file store writes it: one <id>.json per row, a .lock anchor
# and (once a list has been reset) a .highwatermark.
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo" CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1
    SESSION_DIR="$CS_SESSIONS_ROOT/demo"
    mkdir -p "$SESSION_DIR/.cs/local"
    printf '# Session: demo\n' > "$SESSION_DIR/.cs/README.md"
    export CLAUDE_SESSION_NAME="demo"
    export CLAUDE_SESSION_DIR="$SESSION_DIR"
    export CLAUDE_SESSION_META_DIR="$SESSION_DIR/.cs"
    export CLAUDE_CODE_TASK_LIST_ID="demo"
    STORE="$HOME/.claude/tasks/demo"
    mkdir -p "$STORE"
    : > "$STORE/.lock"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_NO_UPDATE_CHECK CS_NO_ITERM2 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_CODE_TASK_LIST_ID 2>/dev/null || true
}

# A task row as Claude Code writes it: JSON.stringify(task, null, 2), no
# trailing newline.
_row() {  # id status subject [description]
    jq -n --arg id "$1" --arg status "$2" --arg subject "$3" --arg description "${4:-details for $3}" \
        '{id: $id, subject: $subject, description: $description, activeForm: ("Working on " + $subject), status: $status, blocks: [], blockedBy: []}' \
        | perl -pe 'chomp if eof' > "$STORE/$1.json"
}

# The ids still in the store, ascending, space-separated.
_live_ids() {
    local f ids=""
    for f in "$STORE"/*.json; do
        [ -f "$f" ] || continue
        f=$(basename "$f" .json)
        ids="$ids $f"
    done
    printf '%s\n' $ids | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# The ids in the archive's json/ directory, ascending, space-separated.
_archived_ids() {
    local f ids=""
    for f in "$SESSION_DIR"/.cs/task-archive/*/json/*.json; do
        [ -f "$f" ] || continue
        ids="$ids $(basename "$f" .json)"
    done
    printf '%s\n' $ids | sort -n | tr '\n' ' ' | sed 's/ $//'
}

_agree() {
    "$CS_BIN" -archive-tasks answer yes > /dev/null 2>&1 || { echo "  FAIL: answer yes failed"; return 1; }
}

# ============================================================================
# Which rows move
# ============================================================================

# Claude Code numbers a new task max(live ids, .highwatermark) + 1, and only
# writes .highwatermark on a reset, so archiving the highest row would hand its
# number to the next task. The highest row stays live even when it is done;
# every other completed row moves, byte for byte.
test_completed_rows_move_and_the_highest_stays_live() {
    _row 3 completed "Write the parser"
    _row 4 pending "Review the parser"
    _row 7 completed "Ship the parser"
    _row 9 in_progress "Measure the parser"
    _row 12 completed "Tag the release"
    cp "$STORE/3.json" "$TEST_TMPDIR/3.orig"
    _agree || return 1
    local out
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: run failed: $out"; return 1; }
    assert_eq "4 9 12" "$(_live_ids)" "open rows and the highest row stay in the store" || return 1
    assert_eq "3 7" "$(_archived_ids)" "the other completed rows are archived" || return 1
    local day
    day=$(basename "$(dirname "$(dirname "$(ls "$SESSION_DIR"/.cs/task-archive/*/json/3.json)")")")
    cmp -s "$TEST_TMPDIR/3.orig" "$SESSION_DIR/.cs/task-archive/$day/json/3.json" \
        || { echo "  FAIL: the archived row is not byte-identical to the store's"; return 1; }
    assert_eq "Archived 2 completed task rows to .cs/task-archive/$day (#12 stays live: it is the highest id, and Claude Code numbers new tasks after it)" \
        "$out" "run reports what it moved and what it kept" || return 1
}

# When the highest row is still open it already holds the top number, so every
# completed row can go.
test_every_completed_row_moves_when_the_highest_is_open() {
    _row 1 completed "First"
    _row 2 completed "Second"
    _row 5 pending "Third"
    _agree || return 1
    local out
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: run failed: $out"; return 1; }
    assert_eq "5" "$(_live_ids)" "only the open row stays" || return 1
    assert_eq "1 2" "$(_archived_ids)" "both completed rows are archived" || return 1
    local day
    day=$(ls "$SESSION_DIR/.cs/task-archive")
    assert_eq "Archived 2 completed task rows to .cs/task-archive/$day" "$out" "no row is kept back" || return 1
}

# The property the rule exists for: after a run, the highest id in the store is
# the highest id the list ever had, so the next TaskCreate (max + 1) cannot
# reuse an archived number. Ids compare as numbers: 10 outranks 9.
test_the_store_keeps_its_highest_id_so_numbers_are_never_reused() {
    _row 8 completed "Eight"
    _row 9 completed "Nine"
    _row 10 completed "Ten"
    _agree || return 1
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || { echo "  FAIL: run failed"; return 1; }
    assert_eq "10" "$(_live_ids)" "the numerically highest row stays" || return 1
    assert_eq "8 9" "$(_archived_ids)" "the rest move" || return 1
}

test_nothing_to_archive_says_so_and_writes_nothing() {
    _row 1 pending "Open"
    _row 2 completed "Done but highest"
    _agree || return 1
    local out
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: run failed: $out"; return 1; }
    assert_eq "Nothing to archive: no completed task row below #2, the highest id" "$out" "the reason is named" || return 1
    assert_not_exists "$SESSION_DIR/.cs/task-archive" "no archive directory for an empty run" || return 1
    assert_eq "1 2" "$(_live_ids)" "the store is untouched" || return 1
}

echo "Running test_task_archive.sh"
echo ""

run_test test_completed_rows_move_and_the_highest_stays_live
run_test test_every_completed_row_moves_when_the_highest_is_open
run_test test_the_store_keeps_its_highest_id_so_numbers_are_never_reused
run_test test_nothing_to_archive_says_so_and_writes_nothing

report_results
