# ABOUTME: cs -archive-tasks: moves completed native task rows out of Claude Code's task
# ABOUTME: store into the session's .cs/task-archive/<date>/<actor>/<list>/; plumbing /rotate and /wrap drive.

# The session's answer to "archive completed task rows?", recorded once in
# .cs/local and read by every later /rotate and /wrap: yes, no or unasked.
_task_archive_answer() {  # meta_dir
    local file="$1/local/task-archive" answer
    [ -f "$file" ] || { echo "unasked"; return 0; }
    answer=$(head -n 1 "$file")
    case "$answer" in
        yes|no) echo "$answer" ;;
        *) error "$file holds \"$answer\", not yes or no; record the answer again with cs -archive-tasks answer yes|no" ;;
    esac
}

# Whether the cs mod ran this /rotate for the person, on its own or from its
# one-key rotate button: yes when .cs/local/cs.forced or .cs/local/cs.pressed
# names the conversation .cs/local/state names; no otherwise. The mod writes
# the conversation's id to cs.forced before it runs a forced rotation, and to
# cs.pressed before it runs a press's /rotate, emptying cs.pressed once that
# turn is over. CS_ROTATE_FORCE_CTX is only the threshold the mod forces at
# (forcing is on when it is unset), so it says nothing about this rotation.
_task_archive_forced() {  # meta_dir
    local now marker named
    now=$(_read_local_state "$1/local/state" claude_session_id)
    if [ -n "$now" ]; then
        # Nothing empties cs.forced: it is the mod's retry guard (forceRotation
        # forces no conversation it already names), so a forced rotation that
        # fails is not run again at every turn's end. The cost: once the mod
        # has forced a rotation here, a /rotate typed later in the same
        # conversation, as after a forced rotation that never armed, reads as
        # forced too and skips the archive question.
        for marker in cs.forced cs.pressed; do
            [ -f "$1/local/$marker" ] || continue
            named=""
            # A last line with no newline still sets named; read's status is
            # only that missing newline.
            IFS= read -r named < "$1/local/$marker" || true
            if [ "$named" = "$now" ]; then echo yes; return 0; fi
        done
    fi
    echo no
}

# Claude Code's file store for the session's task list:
# <config dir>/tasks/<list id>, where every character of the list id outside
# [a-zA-Z0-9_-] reads as '-' (a feature's base@task list is base-task).
_task_store_dir() {
    local id="${CLAUDE_CODE_TASK_LIST_ID:-}"
    [ -n "$id" ] || error "CLAUDE_CODE_TASK_LIST_ID is not set, so the session's task list is unknown; nothing archived"
    id=$(printf '%s' "$id" | LC_ALL=C tr -c 'a-zA-Z0-9_-' '-')
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/$id"
}

# Checks that the store holds only what Claude Code's file store writes: one
# regular <id>.json per row, a regular .lock anchor and .highwatermark. A held
# lock (.lock.lock for the list, <id>.json.lock for a row) means Claude Code is
# writing. Anything else is a layout cs was not written for. Errors on either,
# before anything is moved.
_task_store_check() {  # store
    local f name
    for f in "$1"/* "$1"/.*; do
        name=$(basename "$f")
        case "$name" in
            .|..) continue ;;
            '*'|'.*') [ -e "$f" ] || [ -L "$f" ] || continue ;;
        esac
        case "$name" in
            .lock.lock|*.json.lock)
                error "Claude Code is writing the task list ($f exists); nothing archived. Run it again once the write is done" ;;
        esac
        if [ ! -L "$f" ] && [ -f "$f" ]; then
            case "$name" in
                .lock|.highwatermark) continue ;;
                *.json)
                    case "${name%.json}" in
                        ''|*[!0-9]*) ;;
                        *) continue ;;
                    esac
                    ;;
            esac
        fi
        error "refusing to archive: $1 holds $name, which is not part of the task store layout cs knows (<id>.json rows, .lock, .highwatermark); nothing archived"
    done
}

# The ids of the rows in the store, one per line, ascending by number.
_task_store_ids() {  # store
    local f
    for f in "$1"/*.json; do
        [ -f "$f" ] || continue
        f=$(basename "$f")
        printf '%s\n' "${f%.json}"
    done | sort -n
}

# A row's status when the row matches the schema Claude Code reads a task
# with; errors naming the file otherwise. The schema is the zod object its
# task reader parses every row with (Claude Code 2.1.299, `Oe`): id, subject
# and description strings; activeForm and owner optional strings; status one
# of pending, in_progress, completed; blocks and blockedBy arrays of strings;
# metadata an optional record of string keys. Optional means absent, never
# null. Keys it does not name are dropped, not refused. cs adds one rule: the
# id is the file's number.
_task_row_status() {  # store, id
    local status
    status=$(jq -r --arg id "$2" '
        def optional_string(k): (has(k) | not) or (.[k] | type) == "string";
        def ids(k): (.[k] | type) == "array" and all(.[k][]; type == "string");
        if type == "object" and .id == $id
            and (.subject | type) == "string" and (.description | type) == "string"
            and optional_string("activeForm") and optional_string("owner")
            and (.status == "pending" or .status == "in_progress" or .status == "completed")
            and ids("blocks") and ids("blockedBy")
            and ((has("metadata") | not) or (.metadata | type) == "object")
        then .status else "unrecognised" end' "$1/$2.json" 2>/dev/null) || status="unrecognised"
    # One known word or nothing: a file holding two JSON values prints two.
    case "$status" in
        pending|in_progress|completed) printf '%s\n' "$status" ;;
        *) error "refusing to archive: $1/$2.json is not a task row in the format cs knows; nothing archived" ;;
    esac
}

# Where the session keeps its task archive: in the vault behind .cs/private
# for an encrypted session, else .cs/task-archive. Errors when the vault is
# locked, or when the archive or any link anywhere under it leads out of the
# session (a clone can commit such a link, and a pull can bring one in while
# the session is open). The writes check their own paths again as they write.
_task_archive_root() {  # session_dir, meta_dir
    local root="$2/task-archive" out link
    if [ -L "$2/private" ] || [ -e "$2/private" ]; then
        [ -d "$2/private" ] \
            || error "the session's vault is locked (.cs/private leads to a missing directory); mount it, then archive again. Nothing archived"
        root="$2/private/task-archive"
    fi
    if out=$(_cs_write_leaves_session "$1" "$root"); then
        error ".cs/${root#"$2"/} leads to $out, outside the session; nothing archived"
    fi
    if [ -d "$root" ]; then
        while IFS= read -r -d '' link; do
            if out=$(_cs_write_leaves_session "$1" "$link"); then
                error ".cs/$(_cs_plain_name "${link#"$2"/}" 160) leads to $out, outside the session; nothing archived"
            fi
        done < <(find -H "$root" -type l -print0)
    fi
    printf '%s\n' "$root"
}

# One row of the readable copy: its heading, then its description.
_task_row_markdown() {  # row file
    jq -r '"## #\(.id) [\(.status)] \(.subject)\n\n\(.description)\n"' "$1"
}

# Every row of the list in id order (TASK_ARCHIVE_IDS), as the snapshot
# shows them.
_task_archive_rows() {  # store
    local id
    while read -r id; do
        _task_row_markdown "$1/$id.json"
    done <<IDS
$TASK_ARCHIVE_IDS
IDS
}

# The readable snapshot of the whole list a run appends to tasks.md: a dated
# header, then every row.
_task_archive_snapshot() {  # store
    printf '# Task list as of %s (before archiving completed rows)\n\n' "$(date '+%Y-%m-%d %H:%M')"
    _task_archive_rows "$1"
}

# The rows of the last snapshot in a tasks.md, without its header.
_task_archive_last_rows() {  # tasks.md
    awk '/^# Task list as of .* \(before archiving completed rows\)$/ { rows = ""; head = 1; next }
         head && $0 == "" { head = 0; next }
         { head = 0; rows = rows $0 "\n" }
         END { printf "%s", rows }' "$1"
}

# Reads the session's task list and decides what a run moves. Sets
# TASK_ARCHIVE_STORE, TASK_ARCHIVE_IDS (every row, ascending by number),
# TASK_ARCHIVE_TOP (the highest id), TASK_ARCHIVE_TOP_DONE (1 when that row is
# completed), TASK_ARCHIVE_MOVING (the completed rows below it, space
# separated) and TASK_ARCHIVE_NOTHING (why nothing moves; empty when rows do).
# The highest row stays in the store whatever its status: Claude Code numbers
# a new task one past the larger of the highest row id in the store and
# .highwatermark, and it raises .highwatermark only when it deletes a row,
# resets the list, writes a row under a given id or skips an id (2.1.299),
# never when a row file leaves the store any other way. Moving the highest
# row would hand its number to the next task. Errors on a store it does not
# recognise.
_task_archive_select() {
    TASK_ARCHIVE_STORE=$(_task_store_dir)
    TASK_ARCHIVE_IDS="" TASK_ARCHIVE_TOP="" TASK_ARCHIVE_TOP_DONE=0
    TASK_ARCHIVE_MOVING="" TASK_ARCHIVE_NOTHING=""
    local store="$TASK_ARCHIVE_STORE" id status
    if [ -L "$store" ]; then
        error "refusing to archive: $store is a link, not the task store directory Claude Code makes; nothing archived"
    fi
    if [ ! -d "$store" ]; then
        TASK_ARCHIVE_NOTHING="no task list at $store"
        return 0
    fi
    _task_store_check "$store"
    TASK_ARCHIVE_IDS=$(_task_store_ids "$store")
    if [ -z "$TASK_ARCHIVE_IDS" ]; then
        TASK_ARCHIVE_NOTHING="no task rows in $store"
        return 0
    fi
    TASK_ARCHIVE_TOP=$(printf '%s\n' "$TASK_ARCHIVE_IDS" | tail -n 1)
    while read -r id; do
        status=$(_task_row_status "$store" "$id")
        [ "$status" = "completed" ] || continue
        if [ "$id" = "$TASK_ARCHIVE_TOP" ]; then
            TASK_ARCHIVE_TOP_DONE=1
        else
            TASK_ARCHIVE_MOVING="$TASK_ARCHIVE_MOVING${TASK_ARCHIVE_MOVING:+ }$id"
        fi
    done <<IDS
$TASK_ARCHIVE_IDS
IDS
    if [ -z "$TASK_ARCHIVE_MOVING" ]; then
        if [ "$TASK_ARCHIVE_TOP_DONE" -eq 1 ]; then
            TASK_ARCHIVE_NOTHING="no completed task row below #$TASK_ARCHIVE_TOP, the highest id"
        else
            TASK_ARCHIVE_NOTHING="no completed task rows"
        fi
    fi
}

# Where a run writes, and what the day's archive already holds of the live
# list. Sets TASK_ARCHIVE_ROOT (_task_archive_root), TASK_ARCHIVE_DAY (this
# actor's directory for this list today) and TASK_ARCHIVE_COPIED (the rows this run
# moves that the day's archive already holds with the same bytes: an earlier
# run copied them and stopped before it removed them). Any other archived
# copy of a live row errors, naming the row and what to do: one with other
# bytes would be overwritten, and one of a row that stays live would leave
# the archive holding a row the list still has.
_task_archive_place() {  # session_dir, meta_dir
    local store="$TASK_ARCHIVE_STORE" id dst why
    TASK_ARCHIVE_ROOT=$(_task_archive_root "$1" "$2") || exit 1
    # Per actor, then per list: every machine numbers its copy of the list
    # from 1, and so does every list (a feature's base@task beside its base on
    # one machine), so rows of each share numbers; one directory per actor and
    # list keeps their paths apart. The list's directory is named as Claude
    # Code names its store.
    TASK_ARCHIVE_DAY="$TASK_ARCHIVE_ROOT/$(date +%Y-%m-%d)/$(cs_actor_slug "$1")/${store##*/}"
    TASK_ARCHIVE_COPIED=""
    while read -r id; do
        dst="$TASK_ARCHIVE_DAY/json/$id.json"
        [ -e "$dst" ] || [ -L "$dst" ] || continue
        if [ -L "$dst" ] || ! cmp -s "$store/$id.json" "$dst"; then
            error "refusing to archive: .cs/${dst#"$2"/} holds a different row #$id than $store/$id.json, which is still live. Delete the archived copy to keep the live row (or the live row to keep the copy), then run again; nothing archived"
        fi
        case " $TASK_ARCHIVE_MOVING " in
            *" $id "*) TASK_ARCHIVE_COPIED="$TASK_ARCHIVE_COPIED${TASK_ARCHIVE_COPIED:+ }$id" ;;
            *)
                why="as the highest id"
                [ "$id" = "$TASK_ARCHIVE_TOP" ] || why="as an open row"
                error "refusing to archive: .cs/${dst#"$2"/} holds a copy of row #$id, which stays in the live list $why. Delete the archived copy, then run again; nothing archived" ;;
        esac
    done <<IDS
$TASK_ARCHIVE_IDS
IDS
}

# What a run would do, for the skill to read before it asks: the session's
# answer, whether the cs mod forced this rotation, the store, the rows that
# would move and the row kept back. Moves nothing; refuses on the same stores
# a run refuses.
archive_tasks_plan() {
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    local session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}" answer
    answer=$(_task_archive_answer "$meta_dir")
    _task_archive_select
    if [ -n "$TASK_ARCHIVE_IDS" ]; then
        _task_archive_place "$session_dir" "$meta_dir"
    fi
    echo "answer: $answer"
    echo "forced: $(_task_archive_forced "$meta_dir")"
    echo "store: $TASK_ARCHIVE_STORE"
    if [ -n "$TASK_ARCHIVE_NOTHING" ]; then
        echo "archive: nothing: $TASK_ARCHIVE_NOTHING"
        return 0
    fi
    local id count=0 list="" noun="rows"
    for id in $TASK_ARCHIVE_MOVING; do
        count=$((count + 1))
        list="$list${list:+ }#$id"
    done
    [ "$count" -eq 1 ] && noun="row"
    echo "archive: $count completed $noun: $list"
    if [ "$TASK_ARCHIVE_TOP_DONE" -eq 1 ]; then
        echo "keep: #$TASK_ARCHIVE_TOP, the highest id, stays live"
    fi
    echo "target: .cs/${TASK_ARCHIVE_ROOT#"$meta_dir"/}"
}

# Moves the completed rows _task_archive_select picked into
# .cs/task-archive/<date>/<actor>/<list>/json/, after appending a readable snapshot of
# the whole list to tasks.md there. It copies every row first and removes them
# from the store only once all are copied, so a run that stops part way has
# moved nothing. The next run finishes it: a live row the day's archive holds
# with the same bytes and that this run moves is one an earlier run copied, so
# it is not copied again, and the snapshot is not appended again when such a
# row exists or the last snapshot already shows the list as it stands. Any
# other archived copy of a live row (other bytes, or a row that stays live)
# refuses the run before anything is written, naming the row and what to do:
# an archived row is never overwritten, and the archive never keeps a copy of
# a live row. A row that changes between its copy and its removal stays live.
# Claude Code's locks are checked once, before the run; cs takes neither, so
# a write Claude Code makes to a completed row between its last compare and
# its removal is lost. The window is that small and only completed rows are in
# it, which is accepted.
archive_tasks_run() {
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    local session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}" answer
    answer=$(_task_archive_answer "$meta_dir")
    [ "$answer" = "yes" ] || error "this session has not agreed to task archiving (answer: $answer); ask first, then record it with cs -archive-tasks answer yes"

    _task_archive_select
    if [ -n "$TASK_ARCHIVE_IDS" ]; then
        _task_archive_place "$session_dir" "$meta_dir"
    fi
    if [ -n "$TASK_ARCHIVE_NOTHING" ]; then
        echo "Nothing to archive: $TASK_ARCHIVE_NOTHING"
        return 0
    fi
    local store="$TASK_ARCHIVE_STORE" day_dir="$TASK_ARCHIVE_DAY" id dst

    cs_mkdir_inside "$day_dir/json" \
        || error "could not make .cs/${day_dir#"$meta_dir"/}/json; nothing archived"
    if [ -z "$TASK_ARCHIVE_COPIED" ] && { [ ! -f "$day_dir/tasks.md" ] \
        || [ "$(_task_archive_rows "$store")" != "$(_task_archive_last_rows "$day_dir/tasks.md")" ]; }; then
        cs_append_inside "$day_dir/tasks.md" _task_archive_snapshot "$store" \
            || error "could not add the snapshot to .cs/${day_dir#"$meta_dir"/}/tasks.md; nothing archived"
    fi

    local tmp out
    for id in $TASK_ARCHIVE_MOVING; do
        dst="$day_dir/json/$id.json"
        [ ! -e "$dst" ] || continue
        if out=$(_cs_write_leaves_session "$session_dir" "$dst"); then
            error ".cs/${dst#"$meta_dir"/} leads to $out, outside the session; every row is still in the live list"
        fi
        tmp=$(mktemp "$day_dir/json/.row.XXXXXX") \
            || error "could not copy task row #$id to .cs/${dst#"$meta_dir"/}; every row is still in the live list"
        if ! cp "$store/$id.json" "$tmp" || ! mv "$tmp" "$dst"; then
            rm -f "$tmp"
            error "could not copy task row #$id to .cs/${dst#"$meta_dir"/}; every row is still in the live list"
        fi
    done

    local moved=0
    for id in $TASK_ARCHIVE_MOVING; do
        dst="$day_dir/json/$id.json"
        if ! cmp -s "$store/$id.json" "$dst"; then
            rm -f "$dst"
            warn "Task row #$id changed while it was archived; it stays in the live list"
            continue
        fi
        rm -f "$store/$id.json"
        moved=$((moved + 1))
    done

    local rel=".cs/${day_dir#"$meta_dir"/}" noun="rows"
    [ "$moved" -eq 1 ] && noun="row"
    if [ "$TASK_ARCHIVE_TOP_DONE" -eq 1 ]; then
        echo "Archived $moved completed task $noun to $rel (#$TASK_ARCHIVE_TOP stays live: it is the highest id, and Claude Code numbers new tasks after it)"
    else
        echo "Archived $moved completed task $noun to $rel"
    fi
}

# Keeps the session's answer in .cs/local/task-archive. The dispatch has
# refused a session where git tracks a file in .cs/local (_vet_current_session);
# the write goes through cs's writers, so a .cs/local that links out of the
# session takes nothing.
archive_tasks_record_answer() {  # yes|no
    case "${1:-}" in
        yes|no) ;;
        *) error "Usage: cs -archive-tasks answer yes|no" ;;
    esac
    cs_mkdir_inside "$CLAUDE_SESSION_META_DIR/local" \
        && cs_write_atomic "$CLAUDE_SESSION_META_DIR/local/task-archive" printf '%s\n' "$1" \
        || error "could not record the answer in .cs/local/task-archive"
}

run_archive_tasks() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ] || [ ! -d "${CLAUDE_SESSION_META_DIR}" ]; then
        error "cs -archive-tasks must be run from inside a cs session"
    fi
    case "${1:-}" in
        plan) archive_tasks_plan ;;
        run) archive_tasks_run ;;
        answer) shift; archive_tasks_record_answer "$@" ;;
        *) error "Usage: cs -archive-tasks plan|run|answer yes|no" ;;
    esac
}
