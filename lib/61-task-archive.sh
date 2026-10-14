# ABOUTME: cs -archive-tasks: moves completed native task rows out of Claude Code's task
# ABOUTME: store into the session's .cs/task-archive/<date>/; plumbing /rotate and /wrap drive.

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
# with (id equal to the file's number, subject, description, a known status,
# blocks and blockedBy arrays); errors naming the file otherwise.
_task_row_status() {  # store, id
    local status
    status=$(jq -r --arg id "$2" '
        if type == "object" and .id == $id
            and (.subject | type) == "string" and (.description | type) == "string"
            and (.status == "pending" or .status == "in_progress" or .status == "completed")
            and (.blocks | type) == "array" and (.blockedBy | type) == "array"
        then .status else "unrecognised" end' "$1/$2.json" 2>/dev/null) || status="unrecognised"
    [ "$status" != "unrecognised" ] \
        || error "refusing to archive: $1/$2.json is not a task row in the format cs knows; nothing archived"
    printf '%s\n' "$status"
}

# Where the session keeps its task archive: in the vault behind .cs/private
# for an encrypted session, else .cs/task-archive. Errors when the vault is
# locked or the path leads out of the session.
_task_archive_root() {  # session_dir, meta_dir
    local root="$2/task-archive" out
    if [ -L "$2/private" ] || [ -e "$2/private" ]; then
        [ -d "$2/private" ] \
            || error "the session's vault is locked (.cs/private leads to a missing directory); mount it, then archive again. Nothing archived"
        root="$2/private/task-archive"
    fi
    if out=$(_cs_write_leaves_session "$1" "$root"); then
        error ".cs/${root#"$2"/} leads to $out, outside the session; nothing archived"
    fi
    printf '%s\n' "$root"
}

# One row of the readable copy: its heading, then its description.
_task_row_markdown() {  # row file
    jq -r '"## #\(.id) [\(.status)] \(.subject)\n\n\(.description)\n"' "$1"
}

# Moves the completed rows of the session's task list into
# .cs/task-archive/<date>/json/, after appending a readable snapshot of the
# whole list to tasks.md there. The row with the highest id stays in the store
# whatever its status: Claude Code numbers a new task one past the highest id
# it can see (or its .highwatermark, which it writes only on a reset), so the
# highest row moving would hand its number to the next task.
archive_tasks_run() {
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    local answer
    answer=$(_task_archive_answer "$meta_dir")
    [ "$answer" = "yes" ] || error "this session has not agreed to task archiving (answer: $answer); ask first, then record it with cs -archive-tasks answer yes"

    local store
    store=$(_task_store_dir)
    if [ ! -d "$store" ]; then
        echo "Nothing to archive: no task list at $store"
        return 0
    fi

    _task_store_check "$store"
    local ids top id status
    ids=$(_task_store_ids "$store")
    if [ -z "$ids" ]; then
        echo "Nothing to archive: no task rows in $store"
        return 0
    fi
    top=$(printf '%s\n' "$ids" | tail -n 1)
    local moving=() top_done=0
    while read -r id; do
        status=$(_task_row_status "$store" "$id")
        [ "$status" = "completed" ] || continue
        if [ "$id" = "$top" ]; then
            top_done=1
            continue
        fi
        moving+=("$id")
    done <<EOF
$ids
EOF
    if [ "${#moving[@]}" -eq 0 ]; then
        if [ "$top_done" -eq 1 ]; then
            echo "Nothing to archive: no completed task row below #$top, the highest id"
        else
            echo "Nothing to archive: no completed task rows"
        fi
        return 0
    fi

    local session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}" root day_dir
    root=$(_task_archive_root "$session_dir" "$meta_dir")
    day_dir="$root/$(date +%Y-%m-%d)"
    mkdir -p "$day_dir/json"
    {
        printf '# Task list as of %s (before archiving completed rows)\n\n' "$(date '+%Y-%m-%d %H:%M')"
        while read -r id; do
            _task_row_markdown "$store/$id.json"
        done <<EOF
$ids
EOF
    } >> "$day_dir/tasks.md"

    local dst tmp moved=0
    for id in "${moving[@]}"; do
        dst="$day_dir/json/$id.json"
        tmp=$(mktemp "$day_dir/json/.row.XXXXXX")
        cp "$store/$id.json" "$tmp"
        mv "$tmp" "$dst"
        rm -f "$store/$id.json"
        moved=$((moved + 1))
    done

    local rel=".cs/${day_dir#"$meta_dir"/}" noun="rows"
    [ "$moved" -eq 1 ] && noun="row"
    if [ "$top_done" -eq 1 ]; then
        echo "Archived $moved completed task $noun to $rel (#$top stays live: it is the highest id, and Claude Code numbers new tasks after it)"
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
        run) archive_tasks_run ;;
        answer) shift; archive_tasks_record_answer "$@" ;;
        *) error "Usage: cs -archive-tasks run|answer yes|no" ;;
    esac
}
