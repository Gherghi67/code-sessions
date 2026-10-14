# ABOUTME: cs -archive-tasks: moves completed native task rows out of Claude Code's task
# ABOUTME: store into the session's .cs/task-archive/<date>/<actor>/; plumbing /rotate and /wrap drive.

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
                error ".cs/${link#"$2"/} leads to $out, outside the session; nothing archived"
            fi
        done < <(find -H "$root" -type l -print0)
    fi
    printf '%s\n' "$root"
}

# One row of the readable copy: its heading, then its description.
_task_row_markdown() {  # row file
    jq -r '"## #\(.id) [\(.status)] \(.subject)\n\n\(.description)\n"' "$1"
}

# The readable snapshot of the whole list a run appends to tasks.md: a dated
# header, then every row in id order (TASK_ARCHIVE_IDS).
_task_archive_snapshot() {  # store
    local id
    printf '# Task list as of %s (before archiving completed rows)\n\n' "$(date '+%Y-%m-%d %H:%M')"
    while read -r id; do
        _task_row_markdown "$1/$id.json"
    done <<IDS
$TASK_ARCHIVE_IDS
IDS
}

# Reads the session's task list and decides what a run moves. Sets
# TASK_ARCHIVE_STORE, TASK_ARCHIVE_IDS (every row, ascending by number),
# TASK_ARCHIVE_TOP (the highest id), TASK_ARCHIVE_TOP_DONE (1 when that row is
# completed), TASK_ARCHIVE_MOVING (the completed rows below it, space
# separated) and TASK_ARCHIVE_NOTHING (why nothing moves; empty when rows do).
# The highest row stays in the store whatever its status: Claude Code numbers
# a new task one past the highest id it can see (or its .highwatermark, which
# it writes only on a reset), so moving that row would hand its number to the
# next task. Errors on a store it does not recognise.
_task_archive_select() {
    TASK_ARCHIVE_STORE=$(_task_store_dir)
    TASK_ARCHIVE_IDS="" TASK_ARCHIVE_TOP="" TASK_ARCHIVE_TOP_DONE=0
    TASK_ARCHIVE_MOVING="" TASK_ARCHIVE_NOTHING=""
    local store="$TASK_ARCHIVE_STORE" id status
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

# What a run would do, for the skill to read before it asks: the session's
# answer, the store, the rows that would move and the row kept back. Moves
# nothing; refuses on the same stores a run refuses.
archive_tasks_plan() {
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    local session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}" answer root
    answer=$(_task_archive_answer "$meta_dir")
    _task_archive_select
    [ -n "$TASK_ARCHIVE_NOTHING" ] || root=$(_task_archive_root "$session_dir" "$meta_dir")
    echo "answer: $answer"
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
    echo "target: .cs/${root#"$meta_dir"/}"
}

# Moves the completed rows _task_archive_select picked into
# .cs/task-archive/<date>/<actor>/json/, after appending a readable snapshot of the
# whole list to tasks.md there. An archived row is never overwritten: a row
# already archived under the same number with other bytes refuses the run
# before anything is written, and one with the same bytes (a run that stopped
# after its copy) finishes moving. A row that changes between its copy and
# its removal stays live.
archive_tasks_run() {
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    local session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}" answer
    answer=$(_task_archive_answer "$meta_dir")
    [ "$answer" = "yes" ] || error "this session has not agreed to task archiving (answer: $answer); ask first, then record it with cs -archive-tasks answer yes"

    _task_archive_select
    if [ -n "$TASK_ARCHIVE_NOTHING" ]; then
        echo "Nothing to archive: $TASK_ARCHIVE_NOTHING"
        return 0
    fi
    local store="$TASK_ARCHIVE_STORE" root day_dir id dst
    root=$(_task_archive_root "$session_dir" "$meta_dir")
    # Per actor: every machine numbers its copy of the list from 1, so two
    # actors' rows share numbers, and one directory each keeps their paths apart.
    day_dir="$root/$(date +%Y-%m-%d)/$(cs_actor_slug "$session_dir")"
    for id in $TASK_ARCHIVE_MOVING; do
        dst="$day_dir/json/$id.json"
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            { [ ! -L "$dst" ] && cmp -s "$store/$id.json" "$dst"; } \
                || error "refusing to archive: .cs/${dst#"$meta_dir"/} already holds a different row #$id; nothing archived"
        fi
    done

    cs_mkdir_inside "$day_dir/json" \
        || error "could not make .cs/${day_dir#"$meta_dir"/}/json; nothing archived"
    cs_append_inside "$day_dir/tasks.md" _task_archive_snapshot "$store" \
        || error "could not add the snapshot to .cs/${day_dir#"$meta_dir"/}/tasks.md; nothing archived"

    local tmp out moved=0
    for id in $TASK_ARCHIVE_MOVING; do
        dst="$day_dir/json/$id.json"
        if [ ! -e "$dst" ]; then
            if out=$(_cs_write_leaves_session "$session_dir" "$dst"); then
                error ".cs/${dst#"$meta_dir"/} leads to $out, outside the session; rows from #$id on stay live"
            fi
            tmp=$(mktemp "$day_dir/json/.row.XXXXXX")
            cp "$store/$id.json" "$tmp"
            mv "$tmp" "$dst"
            if ! cmp -s "$store/$id.json" "$dst"; then
                rm -f "$dst"
                warn "Task row #$id changed while it was archived; it stays in the live list"
                continue
            fi
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

archive_tasks_record_answer() {  # yes|no
    case "${1:-}" in
        yes|no) ;;
        *) error "Usage: cs -archive-tasks answer yes|no" ;;
    esac
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf '%s\n' "$1" > "$CLAUDE_SESSION_META_DIR/local/task-archive"
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
