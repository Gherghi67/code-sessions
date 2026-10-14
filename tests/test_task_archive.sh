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

# ============================================================================
# Fail closed: a store cs does not recognise is left exactly as it is
# ============================================================================

# A run that refuses must move nothing and write nothing: the store keeps every
# row and no archive directory appears.
_assert_refused() {  # expected error line, output, live ids before
    assert_eq "$1" "$2" "the refusal names its reason" || return 1
    assert_eq "$3" "$(_live_ids)" "every row stays in the store" || return 1
    assert_not_exists "$SESSION_DIR/.cs/task-archive" "nothing is written to the archive" || return 1
}

test_an_unknown_file_in_the_store_refuses_the_run() {
    _row 1 completed "One"
    _row 2 pending "Two"
    printf 'scratch\n' > "$STORE/notes.txt"
    _agree || return 1
    local out rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "the run fails" || return 1
    _assert_refused "Error: refusing to archive: $STORE holds notes.txt, which is not part of the task store layout cs knows (<id>.json rows, .lock, .highwatermark); nothing archived" \
        "$out" "1 2" || return 1
}

test_a_directory_in_the_store_refuses_the_run() {
    _row 1 completed "One"
    _row 2 pending "Two"
    mkdir "$STORE/3.json"
    _agree || return 1
    local out rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "the run fails" || return 1
    _assert_refused "Error: refusing to archive: $STORE holds 3.json, which is not part of the task store layout cs knows (<id>.json rows, .lock, .highwatermark); nothing archived" \
        "$out" "1 2" || return 1
}

test_a_linked_row_refuses_the_run() {
    _row 1 completed "One"
    _row 2 pending "Two"
    printf '{}' > "$TEST_TMPDIR/elsewhere.json"
    ln -s "$TEST_TMPDIR/elsewhere.json" "$STORE/3.json"
    _agree || return 1
    local out rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "the run fails" || return 1
    _assert_refused "Error: refusing to archive: $STORE holds 3.json, which is not part of the task store layout cs knows (<id>.json rows, .lock, .highwatermark); nothing archived" \
        "$out" "1 2 3" || return 1
    assert_eq "{}" "$(cat "$TEST_TMPDIR/elsewhere.json")" "the link's target is untouched" || return 1
}

# Every row is checked against the schema Claude Code's own reader enforces:
# id (matching the file name), subject, description, a known status, and the
# two dependency arrays. A row that fails any of them means a format cs was not
# written for.
test_a_row_outside_the_task_schema_refuses_the_run() {
    local bad
    for bad in 'not json' \
        '{"id":"3","subject":"s","description":"d","status":"done","blocks":[],"blockedBy":[]}' \
        '{"id":"4","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[]}' \
        '{"id":"3","subject":"s","status":"completed","blocks":[],"blockedBy":[]}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":{},"blockedBy":[]}' \
        '["3"]'; do
        rm -rf "$STORE"
        mkdir -p "$STORE"
        _row 1 completed "One"
        _row 2 pending "Two"
        printf '%s' "$bad" > "$STORE/3.json"
        _agree || return 1
        local out rc=0
        out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
        assert_eq "1" "$rc" "the run fails on: $bad" || return 1
        _assert_refused "Error: refusing to archive: $STORE/3.json is not a task row in the format cs knows; nothing archived" \
            "$out" "1 2 3" || return 1
    done
}

# Claude Code holds a list lock (.lock.lock) or a row lock (<id>.json.lock)
# while it writes; a run then could race the write it is making.
test_a_held_lock_refuses_the_run() {
    local lock
    for lock in .lock.lock 2.json.lock; do
        rm -rf "$STORE"
        mkdir -p "$STORE/$lock"
        _row 1 completed "One"
        _row 2 pending "Two"
        _agree || return 1
        local out rc=0
        out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
        assert_eq "1" "$rc" "the run fails while $lock is held" || return 1
        _assert_refused "Error: Claude Code is writing the task list ($STORE/$lock exists); nothing archived. Run it again once the write is done" \
            "$out" "1 2" || return 1
    done
}

test_an_unset_task_list_id_refuses_the_run() {
    _row 1 completed "One"
    _row 2 pending "Two"
    _agree || return 1
    local out rc=0
    out=$(env -u CLAUDE_CODE_TASK_LIST_ID "$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "the run fails" || return 1
    _assert_refused "Error: CLAUDE_CODE_TASK_LIST_ID is not set, so the session's task list is unknown; nothing archived" \
        "$out" "1 2" || return 1
}

test_a_missing_store_is_nothing_to_archive() {
    rm -rf "$STORE"
    _agree || return 1
    local out
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: run failed: $out"; return 1; }
    assert_eq "Nothing to archive: no task list at $STORE" "$out" "the missing store is named" || return 1
    assert_not_exists "$SESSION_DIR/.cs/task-archive" "nothing is written" || return 1
}

# ============================================================================
# Where the store and the archive are
# ============================================================================

# Claude Code turns every character of the list id outside [a-zA-Z0-9_-] into
# '-': a feature worktree's base@task list lives in tasks/base-task.
test_the_list_id_is_read_the_way_claude_code_names_its_directory() {
    rm -rf "$STORE"
    export CLAUDE_CODE_TASK_LIST_ID="demo@fix.it"
    STORE="$HOME/.claude/tasks/demo-fix-it"
    mkdir -p "$STORE"
    _row 1 completed "One"
    _row 2 pending "Two"
    _agree || return 1
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || { echo "  FAIL: run failed"; return 1; }
    assert_eq "2" "$(_live_ids)" "the row moved out of tasks/demo-fix-it" || return 1
    assert_eq "1" "$(_archived_ids)" "and into the archive" || return 1
}

test_claude_config_dir_moves_the_store() {
    rm -rf "$STORE"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/config"
    STORE="$CLAUDE_CONFIG_DIR/tasks/demo"
    mkdir -p "$STORE"
    _row 1 completed "One"
    _row 2 pending "Two"
    _agree || return 1
    local rc=0
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || rc=$?
    unset CLAUDE_CONFIG_DIR
    assert_eq "0" "$rc" "the run succeeds" || return 1
    assert_eq "2" "$(_live_ids)" "the row moved out of the config dir's store" || return 1
}

# An encrypted session keeps its content in the vault behind .cs/private (cs
# -encrypt links it to vault-mnt/private, the mounted volume); task text is
# session content, so its archive goes there too, and a locked vault (the
# volume detached, the link dangling) refuses rather than write plaintext.
test_an_encrypted_session_archives_into_its_vault() {
    mkdir -p "$SESSION_DIR/.cs/vault-mnt/private"
    ln -s vault-mnt/private "$SESSION_DIR/.cs/private"
    _row 1 completed "One"
    _row 2 pending "Two"
    _agree || return 1
    local out day
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: run failed: $out"; return 1; }
    day=$(ls "$SESSION_DIR/.cs/vault-mnt/private/task-archive")
    assert_eq "Archived 1 completed task row to .cs/private/task-archive/$day" "$out" "the vault path is reported" || return 1
    assert_exists "$SESSION_DIR/.cs/vault-mnt/private/task-archive/$day/json/1.json" "the row is in the vault" || return 1
    assert_not_exists "$SESSION_DIR/.cs/task-archive" "nothing is written in plaintext" || return 1
}

test_a_locked_vault_refuses_the_run() {
    ln -s vault-mnt/private "$SESSION_DIR/.cs/private"
    _row 1 completed "One"
    _row 2 pending "Two"
    _agree || return 1
    local out rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "the run fails" || return 1
    _assert_refused "Error: the session's vault is locked (.cs/private leads to a missing directory); mount it, then archive again. Nothing archived" \
        "$out" "1 2" || return 1
}

echo "Running test_task_archive.sh"
echo ""

run_test test_completed_rows_move_and_the_highest_stays_live
run_test test_every_completed_row_moves_when_the_highest_is_open
run_test test_the_store_keeps_its_highest_id_so_numbers_are_never_reused
run_test test_nothing_to_archive_says_so_and_writes_nothing
run_test test_an_unknown_file_in_the_store_refuses_the_run
run_test test_a_directory_in_the_store_refuses_the_run
run_test test_a_linked_row_refuses_the_run
run_test test_a_row_outside_the_task_schema_refuses_the_run
run_test test_a_held_lock_refuses_the_run
run_test test_an_unset_task_list_id_refuses_the_run
run_test test_a_missing_store_is_nothing_to_archive
run_test test_the_list_id_is_read_the_way_claude_code_names_its_directory
run_test test_claude_config_dir_moves_the_store
run_test test_an_encrypted_session_archives_into_its_vault
run_test test_a_locked_vault_refuses_the_run

report_results
