#!/usr/bin/env bash
# ABOUTME: Tests for cs -archive-tasks: moving completed native task rows out of
# ABOUTME: Claude Code's task store into the session's .cs/task-archive/<date>/.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# One session, one task list under a scoped HOME. The store is laid out the
# way Claude Code's file store writes it: one <id>.json per row, a .lock anchor
# and (once a row has been deleted or the list reset) a .highwatermark.
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
    # The archive is kept per actor; pinned so the fixture never reads the
    # machine's git identity.
    export CS_ACTOR="alice"
    STORE="$HOME/.claude/tasks/demo"
    mkdir -p "$STORE"
    : > "$STORE/.lock"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_NO_UPDATE_CHECK CS_NO_ITERM2 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_CODE_TASK_LIST_ID CS_ACTOR 2>/dev/null || true
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

# The ids in the actor's json/ directories, ascending, space-separated.
_archived_ids() {
    local f ids=""
    for f in "$SESSION_DIR"/.cs/task-archive/*/"${1:-alice}"/json/*.json; do
        [ -f "$f" ] || continue
        ids="$ids $(basename "$f" .json)"
    done
    printf '%s\n' $ids | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# A stand-in cp first on PATH: it logs each source it is given, fails without
# copying when the source is $FAKE_CP_FAIL, and after copying
# $FAKE_CP_TOUCH appends a space to it (still the same JSON value), as a
# write Claude Code makes in that moment would change it.
_stand_in_cp() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/cp" <<'SH'
#!/bin/sh
src=""
for a in "$@"; do
    case "$a" in -*) ;; *) [ -n "$src" ] || src="$a" ;; esac
done
printf '%s\n' "$src" >> "${FAKE_CP_LOG:-/dev/null}"
if [ -n "${FAKE_CP_FAIL:-}" ] && [ "$src" = "$FAKE_CP_FAIL" ]; then
    exit 1
fi
/bin/cp "$@" || exit $?
if [ -n "${FAKE_CP_TOUCH:-}" ] && [ "$src" = "$FAKE_CP_TOUCH" ]; then
    printf ' ' >> "$src"
fi
SH
    chmod +x "$TEST_TMPDIR/bin/cp"
}

_agree() {
    "$CS_BIN" -archive-tasks answer yes > /dev/null 2>&1 || { echo "  FAIL: answer yes failed"; return 1; }
}

# ============================================================================
# Which rows move
# ============================================================================

# Claude Code numbers a new task max(live ids, .highwatermark) + 1, and raises
# .highwatermark only through its own deletes, resets and id writes, never when
# a row file leaves the store any other way, so archiving the highest row would
# hand its number to the next task. The highest row stays live even when it is done;
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
    day=$(ls "$SESSION_DIR/.cs/task-archive")
    cmp -s "$TEST_TMPDIR/3.orig" "$SESSION_DIR/.cs/task-archive/$day/alice/json/3.json" \
        || { echo "  FAIL: the archived row is not byte-identical to the store's"; return 1; }
    assert_eq "Archived 2 completed task rows to .cs/task-archive/$day/alice (#12 stays live: it is the highest id, and Claude Code numbers new tasks after it)" \
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
    assert_eq "Archived 2 completed task rows to .cs/task-archive/$day/alice" "$out" "no row is kept back" || return 1
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

# Claude Code makes the store as a directory. One that is a link (live or
# dangling) is a layout cs was not written for, and its rows are left where
# they are.
test_a_linked_store_refuses_the_run() {
    _row 1 completed "One"
    _row 2 pending "Two"
    mv "$STORE" "$TEST_TMPDIR/elsewhere"
    ln -s "$TEST_TMPDIR/elsewhere" "$STORE"
    _agree || return 1
    local out rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "the run fails" || return 1
    assert_eq "Error: refusing to archive: $STORE is a link, not the task store directory Claude Code makes; nothing archived" \
        "$out" "the link is named" || return 1
    assert_eq "1.json 2.json" "$(ls "$TEST_TMPDIR/elsewhere" | tr '\n' ' ' | sed 's/ $//')" "every row stays where it is" || return 1
    assert_not_exists "$SESSION_DIR/.cs/task-archive" "nothing is written to the archive" || return 1
    rm -rf "$TEST_TMPDIR/elsewhere"
    rc=0
    out=$("$CS_BIN" -archive-tasks plan 2>&1) || rc=$?
    assert_eq "1" "$rc" "a dangling link refuses too" || return 1
    assert_eq "Error: refusing to archive: $STORE is a link, not the task store directory Claude Code makes; nothing archived" \
        "$out" "the dangling link is named" || return 1
}

# Every row is checked against the schema Claude Code's own reader enforces
# (2.1.299): id (matching the file name), subject and description strings, a
# known status, blocks and blockedBy arrays of ids, and, when present, an
# activeForm and owner string and a metadata object. A row that fails any of
# them is one Claude Code itself would not load, so a format cs was not
# written for. An optional field that is absent is fine; null is not.
test_a_row_outside_the_task_schema_refuses_the_run() {
    local bad
    for bad in 'not json' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":[1],"blockedBy":[]}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[null]}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[],"owner":7}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[],"owner":null}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[],"activeForm":["a"]}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[],"metadata":[]}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[],"metadata":"m"}' \
        '{"id":"3","subject":"s","description":"d","status":"done","blocks":[],"blockedBy":[]}' \
        '{"id":"4","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[]}' \
        '{"id":"3","subject":"s","status":"completed","blocks":[],"blockedBy":[]}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":{},"blockedBy":[]}' \
        '{"id":"3","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[]}{"id":"3","subject":"s","description":"d","status":"completed","blocks":[],"blockedBy":[]}' \
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

# The positive side of the schema: every optional field Claude Code writes,
# well formed, and a key it does not know, which its reader drops, archive.
test_a_row_with_every_optional_field_archives() {
    printf '%s' '{"id":"1","subject":"s","description":"d","activeForm":"Doing s","owner":"agent-1","status":"completed","blocks":["2"],"blockedBy":[],"metadata":{"k":1},"extra":true}' > "$STORE/1.json"
    _row 2 pending "Two"
    _agree || return 1
    local out day
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: run failed: $out"; return 1; }
    day=$(ls "$SESSION_DIR/.cs/task-archive")
    assert_eq "Archived 1 completed task row to .cs/task-archive/$day/alice" "$out" "the full row archives" || return 1
    assert_eq "1" "$(_archived_ids)" "row #1 is in the archive" || return 1
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
    assert_eq "Archived 1 completed task row to .cs/private/task-archive/$day/alice" "$out" "the vault path is reported" || return 1
    assert_exists "$SESSION_DIR/.cs/vault-mnt/private/task-archive/$day/alice/json/1.json" "the row is in the vault" || return 1
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

# ============================================================================
# The answer, the plan, and a second run
# ============================================================================

# The session's answer is asked once and kept; run moves nothing without a yes,
# so a skill that skipped the question cannot archive behind the user's back.
test_run_refuses_until_the_session_has_agreed() {
    _row 1 completed "One"
    _row 2 pending "Two"
    local out rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "an unasked session refuses" || return 1
    _assert_refused "Error: this session has not agreed to task archiving (answer: unasked); ask first, then record it with cs -archive-tasks answer yes" \
        "$out" "1 2" || return 1
    "$CS_BIN" -archive-tasks answer no > /dev/null 2>&1 || { echo "  FAIL: answer no failed"; return 1; }
    assert_eq "no" "$(cat "$SESSION_DIR/.cs/local/task-archive")" "the answer is kept in .cs/local" || return 1
    rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "a session that said no refuses" || return 1
    _assert_refused "Error: this session has not agreed to task archiving (answer: no); ask first, then record it with cs -archive-tasks answer yes" \
        "$out" "1 2" || return 1
}

test_answer_takes_only_yes_or_no() {
    local out rc=0
    out=$("$CS_BIN" -archive-tasks answer maybe 2>&1) || rc=$?
    assert_eq "1" "$rc" "another word is refused" || return 1
    assert_eq "Error: Usage: cs -archive-tasks answer yes|no" "$out" "the usage is named" || return 1
    assert_not_exists "$SESSION_DIR/.cs/local/task-archive" "nothing is recorded" || return 1
}

# plan is what the skill reads before it asks: the standing answer, the store,
# the rows a run would move and the row it would keep. It moves nothing.
test_plan_names_the_answer_and_the_rows_and_moves_nothing() {
    _row 3 completed "Write the parser"
    _row 4 pending "Review the parser"
    _row 7 completed "Ship the parser"
    _row 12 completed "Tag the release"
    local out
    out=$("$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "answer: unasked
forced: no
store: $STORE
archive: 2 completed rows: #3 #7
keep: #12, the highest id, stays live
target: .cs/task-archive" "$out" "plan describes the run" || return 1
    assert_eq "3 4 7 12" "$(_live_ids)" "plan moves nothing" || return 1
    assert_not_exists "$SESSION_DIR/.cs/task-archive" "plan writes nothing" || return 1
    _agree || return 1
    rm "$STORE/3.json" "$STORE/7.json"
    out=$("$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "answer: yes
forced: no
store: $STORE
archive: nothing: no completed task row below #12, the highest id" "$out" "plan says when there is nothing to move" || return 1
}

# plan's forced: line tells the rotate skill whether the cs mod ran this
# /rotate on its own: the mod writes the conversation's id to
# .cs/local/cs.forced before it runs a forced rotation, so the line is yes
# only when that file names the conversation .cs/local/state names. A marker
# from an earlier conversation is no, and CS_ROTATE_FORCE_CTX, a threshold the
# person sets whether or not anything was forced, has no say either way.
test_plan_says_whether_the_cs_mod_forced_this_rotation() {
    _row 1 completed "One"
    _row 2 pending "Two"
    printf 'claude_session_id: "uuid-now"\n' > "$SESSION_DIR/.cs/local/state"
    local out
    out=$("$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "forced: no" "$(printf '%s\n' "$out" | sed -n 2p)" "no marker: not forced" || return 1
    printf 'uuid-earlier\n' > "$SESSION_DIR/.cs/local/cs.forced"
    out=$("$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "forced: no" "$(printf '%s\n' "$out" | sed -n 2p)" "an earlier conversation's marker: not forced" || return 1
    out=$(CS_ROTATE_FORCE_CTX=70 "$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "forced: no" "$(printf '%s\n' "$out" | sed -n 2p)" "a threshold set: still not forced" || return 1
    printf 'uuid-now\n' > "$SESSION_DIR/.cs/local/cs.forced"
    out=$(env -u CS_ROTATE_FORCE_CTX "$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "forced: yes" "$(printf '%s\n' "$out" | sed -n 2p)" "this conversation's marker, no threshold set: forced" || return 1
    out=$(CS_ROTATE_FORCE_CTX=off "$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "forced: yes" "$(printf '%s\n' "$out" | sed -n 2p)" "this conversation's marker: forced whatever the threshold" || return 1
    rm "$SESSION_DIR/.cs/local/state"
    out=$("$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "forced: no" "$(printf '%s\n' "$out" | sed -n 2p)" "no conversation id to match: not forced" || return 1
    : > "$SESSION_DIR/.cs/local/cs.forced"
    out=$("$CS_BIN" -archive-tasks plan 2>&1) || { echo "  FAIL: plan failed: $out"; return 1; }
    assert_eq "forced: no" "$(printf '%s\n' "$out" | sed -n 2p)" "an empty marker and no id do not match" || return 1
}

test_plan_refuses_a_store_it_does_not_recognise() {
    _row 1 completed "One"
    printf 'scratch\n' > "$STORE/notes.txt"
    local out rc=0
    out=$("$CS_BIN" -archive-tasks plan 2>&1) || rc=$?
    assert_eq "1" "$rc" "plan fails" || return 1
    assert_eq "Error: refusing to archive: $STORE holds notes.txt, which is not part of the task store layout cs knows (<id>.json rows, .lock, .highwatermark); nothing archived" \
        "$out" "the same refusal run gives" || return 1
}

# tasks.md is a readable snapshot of the whole list as it stood before the
# run, open rows included, in id order: the shape of the archive cs replaces.
test_tasks_md_is_a_readable_snapshot_of_the_whole_list() {
    _row 10 completed "Ship it" "Tagged and pushed."
    _row 2 pending "Review it" "Two passes.

Second paragraph."
    _row 3 completed "Write it" "First draft."
    _agree || return 1
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || { echo "  FAIL: run failed"; return 1; }
    local md
    md=$(ls "$SESSION_DIR"/.cs/task-archive/*/alice/tasks.md)
    case "$(head -n 1 "$md")" in
        "# Task list as of "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" "[0-9][0-9]:[0-9][0-9]" (before archiving completed rows)") ;;
        *) echo "  FAIL: unexpected header: $(head -n 1 "$md")"; return 1 ;;
    esac
    assert_eq "
## #2 [pending] Review it

Two passes.

Second paragraph.

## #3 [completed] Write it

First draft.

## #10 [completed] Ship it

Tagged and pushed.

x" "$(tail -n +2 "$md"; printf x)" "every row, in id order, heading then description" || return 1
}

# A second run the same day adds to the day's archive: its snapshot is
# appended, never written over, and the rows already there stay.
test_a_second_run_the_same_day_adds_to_the_archive() {
    _row 1 completed "One"
    _row 2 completed "Two"
    _row 3 pending "Three"
    _agree || return 1
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || { echo "  FAIL: first run failed"; return 1; }
    _row 4 completed "Four"
    _row 5 pending "Five"
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || { echo "  FAIL: second run failed"; return 1; }
    assert_eq "1 2 4" "$(_archived_ids)" "both runs' rows are archived" || return 1
    assert_eq "3 5" "$(_live_ids)" "the open rows stay" || return 1
    assert_eq "2" "$(grep -c '^# Task list as of ' "$SESSION_DIR"/.cs/task-archive/*/alice/tasks.md)" \
        "tasks.md holds both snapshots" || return 1
}

# An archived row is never overwritten. A live row whose number the day's
# archive already holds with other content (an earlier run stopped before it
# removed the row, and the row changed since) refuses the run, naming both
# files and what to do; the same bytes mean an earlier run stopped after the
# copy, and the row finishes moving without a second snapshot.
test_an_archived_row_is_never_overwritten() {
    _row 1 completed "One"
    _row 2 pending "Two"
    _agree || return 1
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || { echo "  FAIL: first run failed"; return 1; }
    local day archived
    day=$(ls "$SESSION_DIR/.cs/task-archive")
    archived="$SESSION_DIR/.cs/task-archive/$day/alice/json/1.json"
    cp "$archived" "$TEST_TMPDIR/1.archived"
    _row 1 completed "Another one"
    local out rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "a different row under an archived number refuses" || return 1
    assert_eq "Error: refusing to archive: .cs/task-archive/$day/alice/json/1.json holds a different row #1 than $STORE/1.json, which is still live. Delete the archived copy to keep the live row (or the live row to keep the copy), then run again; nothing archived" \
        "$out" "the clash is named with what to do" || return 1
    cmp -s "$TEST_TMPDIR/1.archived" "$archived" || { echo "  FAIL: the archived row was overwritten"; return 1; }
    assert_eq "1 2" "$(_live_ids)" "the live row stays" || return 1
    assert_eq "1" "$(grep -c '^# Task list as of ' "$SESSION_DIR/.cs/task-archive/$day/alice/tasks.md")" \
        "a refused run adds no snapshot" || return 1
    cp "$archived" "$STORE/1.json"
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: run over an identical copy failed: $out"; return 1; }
    assert_eq "2" "$(_live_ids)" "an identical row finishes moving" || return 1
    cmp -s "$TEST_TMPDIR/1.archived" "$archived" || { echo "  FAIL: the archived row changed"; return 1; }
    assert_eq "1" "$(grep -c '^# Task list as of ' "$SESSION_DIR/.cs/task-archive/$day/alice/tasks.md")" \
        "finishing the move adds no second snapshot" || return 1
}

# A live row the day's archive holds a copy of, that this run would not move
# (an earlier run stopped before it removed the row, and the row reopened or
# is now the highest id), is a copy the archive must not keep: the run
# refuses, naming the row and what to do, and moves nothing.
test_an_archived_copy_of_a_row_that_stays_live_refuses_the_run() {
    _row 1 completed "One"
    _row 2 completed "Two"
    _row 3 pending "Three"
    _agree || return 1
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || { echo "  FAIL: first run failed"; return 1; }
    local day out rc
    day=$(ls "$SESSION_DIR/.cs/task-archive")
    cp "$SESSION_DIR/.cs/task-archive/$day/alice/json/2.json" "$STORE/2.json"
    rm "$STORE/3.json"
    rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "a copy of the highest row refuses" || return 1
    assert_eq "Error: refusing to archive: .cs/task-archive/$day/alice/json/2.json holds a copy of row #2, which stays in the live list as the highest id. Delete the archived copy, then run again; nothing archived" \
        "$out" "the copy is named with what to do" || return 1
    _row 2 in_progress "Two"
    _row 3 pending "Three"
    rc=0
    out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
    assert_eq "1" "$rc" "a copy of a reopened row refuses" || return 1
    assert_eq "Error: refusing to archive: .cs/task-archive/$day/alice/json/2.json holds a different row #2 than $STORE/2.json, which is still live. Delete the archived copy to keep the live row (or the live row to keep the copy), then run again; nothing archived" \
        "$out" "the reopened row is named with what to do" || return 1
    assert_eq "2 3" "$(_live_ids)" "every row stays live" || return 1
    assert_eq "1" "$(grep -c '^# Task list as of ' "$SESSION_DIR/.cs/task-archive/$day/alice/tasks.md")" \
        "a refused run adds no snapshot" || return 1
    rm "$SESSION_DIR/.cs/task-archive/$day/alice/json/2.json"
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: the run after the advice failed: $out"; return 1; }
    assert_eq "Nothing to archive: no completed task rows" "$out" "following the advice clears the refusal" || return 1
}

# A run that stops part way (here a copy fails) leaves every row live and what
# it wrote in place. The next run finishes the move with one snapshot in
# tasks.md, whether the stop came before the first copy or after one.
test_a_rerun_after_an_interrupted_run_finishes_with_one_snapshot() {
    _stand_in_cp
    local stop out rc day
    for stop in 1 2; do
        rm -rf "$SESSION_DIR/.cs/task-archive" "$STORE"
        mkdir -p "$STORE"
        _row 1 completed "One"
        _row 2 completed "Two"
        _row 3 pending "Three"
        _agree || return 1
        rc=0
        out=$(PATH="$TEST_TMPDIR/bin:$PATH" FAKE_CP_FAIL="$STORE/$stop.json" "$CS_BIN" -archive-tasks run 2>&1) || rc=$?
        assert_eq "1" "$rc" "the run stops at row #$stop's copy" || return 1
        day=$(ls "$SESSION_DIR/.cs/task-archive")
        assert_eq "Error: could not copy task row #$stop to .cs/task-archive/$day/alice/json/$stop.json; every row is still in the live list" \
            "$out" "the stop is named" || return 1
        assert_eq "1 2 3" "$(_live_ids)" "every row stays live" || return 1
        out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: the rerun after a stop at #$stop failed: $out"; return 1; }
        assert_eq "Archived 2 completed task rows to .cs/task-archive/$day/alice" "$out" "the rerun finishes the move" || return 1
        assert_eq "3" "$(_live_ids)" "only the open row stays" || return 1
        assert_eq "1 2" "$(_archived_ids)" "both rows are archived" || return 1
        assert_eq "1" "$(grep -c '^# Task list as of ' "$SESSION_DIR/.cs/task-archive/$day/alice/tasks.md")" \
            "one snapshot after a stop at #$stop" || return 1
    done
    # A stop after the copies, once row #1 had left the store and before #2
    # did: the store no longer matches the snapshot, and the copy of #2 is
    # what tells the rerun that snapshot is already there.
    cp "$SESSION_DIR/.cs/task-archive/$day/alice/json/2.json" "$STORE/2.json"
    out=$("$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: the rerun after a stop between removals failed: $out"; return 1; }
    assert_eq "Archived 1 completed task row to .cs/task-archive/$day/alice" "$out" "the rerun finishes row #2" || return 1
    assert_eq "3" "$(_live_ids)" "only the open row stays" || return 1
    assert_eq "1" "$(grep -c '^# Task list as of ' "$SESSION_DIR/.cs/task-archive/$day/alice/tasks.md")" \
        "one snapshot after a stop between removals" || return 1
}

# Every machine numbers its own copy of a list from 1, so two actors archiving
# the same day write different rows under the same numbers. Each actor's rows
# and snapshot go under .cs/task-archive/<date>/<actor>/ (the actor slug
# narratives use), so neither run touches the other's paths and a pull of the
# other's archive adds files instead of meeting them.
test_each_actor_archives_into_its_own_directory() {
    _row 1 completed "Alice's first"
    _row 2 pending "Alice's second"
    _agree || return 1
    "$CS_BIN" -archive-tasks run > /dev/null 2>&1 || { echo "  FAIL: alice's run failed"; return 1; }
    cp "$SESSION_DIR"/.cs/task-archive/*/alice/json/1.json "$TEST_TMPDIR/1.alice"
    rm -rf "$STORE"
    mkdir -p "$STORE"
    _row 1 completed "Bob's first"
    _row 2 pending "Bob's second"
    cp "$STORE/1.json" "$TEST_TMPDIR/1.bob"
    local out day
    out=$(CS_ACTOR="Bob Example" "$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: bob's run failed: $out"; return 1; }
    day=$(ls "$SESSION_DIR/.cs/task-archive")
    assert_eq "Archived 1 completed task row to .cs/task-archive/$day/bob-example" "$out" "bob's run names his directory" || return 1
    assert_eq "alice bob-example" "$(ls "$SESSION_DIR/.cs/task-archive/$day" | tr '\n' ' ' | sed 's/ $//')" \
        "one directory per actor under the day" || return 1
    cmp -s "$TEST_TMPDIR/1.alice" "$SESSION_DIR/.cs/task-archive/$day/alice/json/1.json" \
        || { echo "  FAIL: alice's row #1 changed"; return 1; }
    cmp -s "$TEST_TMPDIR/1.bob" "$SESSION_DIR/.cs/task-archive/$day/bob-example/json/1.json" \
        || { echo "  FAIL: bob's row #1 is not his store's bytes"; return 1; }
    assert_eq "1" "$(grep -c '^# Task list as of ' "$SESSION_DIR/.cs/task-archive/$day/alice/tasks.md")" \
        "alice's snapshot is hers alone" || return 1
    assert_eq "1" "$(grep -c '^## #1 \[completed\] Bob' "$SESSION_DIR/.cs/task-archive/$day/bob-example/tasks.md")" \
        "bob's snapshot holds his rows" || return 1
}

# The archive is written only inside the session. A link anywhere under
# .cs/task-archive that leads out of it (a clone can commit one, and a pull can
# bring one in while the session is open) refuses plan and run before anything
# is written or moved: the archive itself, a day, the actor's directory, its
# json/, its tasks.md, or a day this run does not write to.
test_a_link_out_of_the_session_under_the_archive_refuses_the_run() {
    local day out_dir out_p shape link target expect out rc
    day=$(date +%Y-%m-%d)
    out_dir="$TEST_TMPDIR/outside"
    for shape in "task-archive" "task-archive/$day" "task-archive/$day/alice" \
        "task-archive/$day/alice/json" "task-archive/$day/alice/tasks.md" "task-archive/2026-01-01"; do
        rm -rf "$SESSION_DIR/.cs/task-archive" "$out_dir" "$STORE"
        mkdir -p "$out_dir" "$STORE"
        printf 'ORIGINAL\n' > "$out_dir/victim.rc"
        _row 1 completed "One"
        _row 2 pending "Two"
        link="$SESSION_DIR/.cs/$shape"
        mkdir -p "$(dirname "$link")"
        out_p=$(cd -P "$out_dir" && pwd -P)
        target="$out_dir" expect="$out_p"
        case "$shape" in
            *tasks.md) target="$out_dir/victim.rc" expect="$out_p/victim.rc" ;;
        esac
        ln -s "$target" "$link"
        _agree || return 1
        rc=0
        out=$("$CS_BIN" -archive-tasks plan 2>&1) || rc=$?
        assert_eq "1" "$rc" "plan fails with .cs/$shape linked out" || return 1
        assert_eq "Error: .cs/$shape leads to $expect, outside the session; nothing archived" "$out" \
            "plan names the link" || return 1
        rc=0
        out=$("$CS_BIN" -archive-tasks run 2>&1) || rc=$?
        assert_eq "1" "$rc" "run fails with .cs/$shape linked out" || return 1
        assert_eq "Error: .cs/$shape leads to $expect, outside the session; nothing archived" "$out" \
            "run names the link" || return 1
        assert_eq "1 2" "$(_live_ids)" "every row stays in the store" || return 1
        assert_eq "victim.rc" "$(ls -A "$out_dir")" "nothing is written outside the session" || return 1
        assert_eq "ORIGINAL" "$(cat "$out_dir/victim.rc")" "the link's target is untouched" || return 1
    done
}

# A link that appears after that check (a pull landing mid-run) meets the
# writes themselves: the archive's directories and the snapshot go through
# cs's in-session writers. A stand-in date makes the link at the moment the
# run reads the date, after the check; with nothing to make, the same
# stand-in lets the run through.
test_a_link_that_appears_mid_run_is_refused_at_the_write() {
    local day out_dir out_p root_md link target out rc
    day=$(date +%Y-%m-%d)
    out_dir="$TEST_TMPDIR/outside"
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/date" <<'SH'
#!/bin/sh
if [ -n "${FAKE_DATE_LINK:-}" ] && [ ! -e "$FAKE_DATE_SENTINEL" ]; then
    : > "$FAKE_DATE_SENTINEL"
    mkdir -p "$(dirname "$FAKE_DATE_LINK")"
    ln -s "$FAKE_DATE_TARGET" "$FAKE_DATE_LINK"
fi
exec /bin/date "$@"
SH
    chmod +x "$TEST_TMPDIR/bin/date"
    for link in "$SESSION_DIR/.cs/task-archive/$day" "$SESSION_DIR/.cs/task-archive/$day/alice/tasks.md"; do
        rm -rf "$SESSION_DIR/.cs/task-archive" "$out_dir" "$STORE" "$TEST_TMPDIR/date.done"
        mkdir -p "$out_dir" "$STORE" "$SESSION_DIR/.cs/task-archive"
        printf 'ORIGINAL\n' > "$out_dir/victim.rc"
        out_p=$(cd -P "$out_dir" && pwd -P)
        _row 1 completed "One"
        _row 2 pending "Two"
        _agree || return 1
        target="$out_dir"
        case "$link" in *tasks.md) target="$out_dir/victim.rc" ;; esac
        rc=0
        out=$(PATH="$TEST_TMPDIR/bin:$PATH" FAKE_DATE_LINK="$link" FAKE_DATE_TARGET="$target" \
            FAKE_DATE_SENTINEL="$TEST_TMPDIR/date.done" "$CS_BIN" -archive-tasks run 2>&1) || rc=$?
        assert_exists "$TEST_TMPDIR/date.done" "the stand-in date made the link" || return 1
        assert_eq "1" "$rc" "the run fails" || return 1
        case "$link" in
            *tasks.md)
                assert_eq "cs_append_inside: $link leads to $out_p/victim.rc, outside the session $SESSION_DIR
Error: could not add the snapshot to .cs/task-archive/$day/alice/tasks.md; nothing archived" "$out" \
                    "the snapshot's append refuses" || return 1 ;;
            *)
                assert_eq "cs_mkdir_inside: $link/alice/json leads to $out_p/alice/json, outside the session $SESSION_DIR
Error: could not make .cs/task-archive/$day/alice/json; nothing archived" "$out" \
                    "the directory's mkdir refuses" || return 1 ;;
        esac
        assert_eq "1 2" "$(_live_ids)" "every row stays in the store" || return 1
        assert_eq "victim.rc" "$(ls -A "$out_dir")" "nothing is written outside the session" || return 1
        assert_eq "ORIGINAL" "$(cat "$out_dir/victim.rc")" "the link's target is untouched" || return 1
    done
    rm -rf "$SESSION_DIR/.cs/task-archive" "$TEST_TMPDIR/date.done"
    out=$(PATH="$TEST_TMPDIR/bin:$PATH" FAKE_DATE_SENTINEL="$TEST_TMPDIR/date.done" "$CS_BIN" -archive-tasks run 2>&1) \
        || { echo "  FAIL: the stand-in date alone breaks the run: $out"; return 1; }
    assert_eq "Archived 1 completed task row to .cs/task-archive/$day/alice" "$out" "with no link made, the run archives" || return 1
}

# A row that changes between its copy and its removal (Claude Code updating it
# in that moment) stays live with its new bytes, and its copy leaves the
# archive; the other rows move. With nothing changed, the same stand-in cp
# lets every row through.
test_a_row_that_changes_while_it_is_archived_stays_live() {
    _stand_in_cp
    _row 1 completed "One"
    _row 2 completed "Two"
    _row 3 pending "Three"
    _agree || return 1
    local out day
    out=$(PATH="$TEST_TMPDIR/bin:$PATH" FAKE_CP_TOUCH="$STORE/1.json" FAKE_CP_LOG="$TEST_TMPDIR/cp.log" \
        "$CS_BIN" -archive-tasks run 2>&1) || { echo "  FAIL: run failed: $out"; return 1; }
    day=$(ls "$SESSION_DIR/.cs/task-archive")
    assert_eq "Task row #1 changed while it was archived; it stays in the live list
Archived 1 completed task row to .cs/task-archive/$day/alice" "$out" "the changed row is named and stays" || return 1
    assert_eq "1" "$(grep -cx "$STORE/1.json" "$TEST_TMPDIR/cp.log")" "the stand-in cp copied row #1" || return 1
    assert_eq "1 3" "$(_live_ids)" "the changed row and the open row stay live" || return 1
    assert_eq "2" "$(_archived_ids)" "only the unchanged row is archived" || return 1
    assert_eq " " "$(tail -c 1 "$STORE/1.json")" "the live row keeps its change" || return 1
    rm -rf "$SESSION_DIR/.cs/task-archive" "$STORE"
    mkdir -p "$STORE"
    _row 1 completed "One"
    _row 2 completed "Two"
    _row 3 pending "Three"
    out=$(PATH="$TEST_TMPDIR/bin:$PATH" FAKE_CP_LOG="$TEST_TMPDIR/cp.log" "$CS_BIN" -archive-tasks run 2>&1) \
        || { echo "  FAIL: the stand-in cp alone breaks the run: $out"; return 1; }
    assert_eq "Archived 2 completed task rows to .cs/task-archive/$day/alice" "$out" "unchanged rows all move" || return 1
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
run_test test_a_linked_store_refuses_the_run
run_test test_a_row_outside_the_task_schema_refuses_the_run
run_test test_a_row_with_every_optional_field_archives
run_test test_a_held_lock_refuses_the_run
run_test test_an_unset_task_list_id_refuses_the_run
run_test test_a_missing_store_is_nothing_to_archive
run_test test_the_list_id_is_read_the_way_claude_code_names_its_directory
run_test test_claude_config_dir_moves_the_store
run_test test_an_encrypted_session_archives_into_its_vault
run_test test_a_locked_vault_refuses_the_run
run_test test_run_refuses_until_the_session_has_agreed
run_test test_answer_takes_only_yes_or_no
run_test test_plan_names_the_answer_and_the_rows_and_moves_nothing
run_test test_plan_refuses_a_store_it_does_not_recognise
run_test test_plan_says_whether_the_cs_mod_forced_this_rotation
run_test test_tasks_md_is_a_readable_snapshot_of_the_whole_list
run_test test_a_second_run_the_same_day_adds_to_the_archive
run_test test_an_archived_row_is_never_overwritten
run_test test_an_archived_copy_of_a_row_that_stays_live_refuses_the_run
run_test test_a_rerun_after_an_interrupted_run_finishes_with_one_snapshot
run_test test_each_actor_archives_into_its_own_directory
run_test test_a_link_out_of_the_session_under_the_archive_refuses_the_run
run_test test_a_link_that_appears_mid_run_is_refused_at_the_write
run_test test_a_row_that_changes_while_it_is_archived_stays_live

report_results
