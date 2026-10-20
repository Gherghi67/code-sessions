# ABOUTME: PID-based session lock: acquire, release, and the already-open collision menu.
# ABOUTME: Prevents opening one session in two terminals without --force.

# Emit one numbered menu row and register its action, keeping the printed number
# and the dispatch table in lockstep so a keypress N maps to dispatch[N-1]. The
# label is padded so the dim consequence column aligns. n and dispatch are the
# caller's locals (bash dynamic scope), so a row can never desync the two.
_lock_menu_row() {  # action color label consequence
    n=$((n + 1)); dispatch+=("$1")
    printf '    %b%b%d%b  %b%-16s%b%b%s%b\n' \
        "$BOLD" "$2" "$n" "$NC" "$WHITE" "$3" "$NC" "$DIM" "$4" "$NC"
}

_lock_collision_menu() {
    local session_name="$1" lock_pid="$2"
    local choice="" feature="" offers_worktree=1
    # Worktrees can't nest: a worktree session offers only force/cancel.
    case "$session_name" in
        *@*) offers_worktree=0 ;;
    esac

    local color
    color=$(_read_local_state "$SESSIONS_ROOT/$session_name/.cs/local/state" claude_session_color 2>/dev/null || true)

    # Existing feature worktrees of this base (sibling base@* dirs), so the user
    # can jump back into one instead of only forcing or creating. Capped so the
    # fixed actions stay single-keypress addressable (<= 9 total options).
    local features=() f
    if [ "$offers_worktree" -eq 1 ]; then
        for f in "$SESSIONS_ROOT/$session_name"@*; do
            [ -d "$f" ] || continue          # literal glob when none exist
            features+=("${f##*/}")           # basename, fork-free
        done
        # Five, not six: the fixed rows below can run to four (force, new
        # feature, session manager, cancel) and a tenth option would not be
        # addressable by a single keypress.
        [ "${#features[@]}" -gt 5 ] && features=("${features[@]:0:5}")
    fi

    echo
    printf '  %b%b%b  %b %bis already open%b %b· PID %s%b\n' \
        "$YELLOW" "$ICON_LOCK" "$NC" "$(_session_pill "$session_name" "$color")" \
        "$COMMENT" "$NC" "$DIM" "$lock_pid" "$NC"
    echo

    # Display order drives both the printed numbers and the dispatch table (a
    # keypress N maps to dispatch[N-1]); _lock_menu_row keeps the two in lockstep.
    # Sections are cosmetic.
    local dispatch=() n=0 feat
    if [ "${#features[@]}" -gt 0 ]; then
        printf '    %bopen a feature%b\n' "$DIM" "$NC"
        for f in "${features[@]}"; do
            feat="${f#*@}"
            _lock_menu_row "open:$f" "$GREEN" "@$feat" "resume · cs/$feat"
        done
        echo
        printf '    %bor start here%b\n' "$DIM" "$NC"
    fi
    _lock_menu_row "force" "$ORANGE" 'force start' 'two sessions share one checkout'
    if [ "$offers_worktree" -eq 1 ]; then
        _lock_menu_row "new" "$GREEN" 'new feature' 'its own worktree + branch'
    fi
    # The way out that is neither forcing this session nor starting work here:
    # go pick a different one. Offered only when a picker is installed, so the
    # row can never name a command that answers with "not installed".
    if _tui_bin >/dev/null 2>&1; then
        _lock_menu_row "tui" "$GOLD" 'session manager' 'browse every session'
    fi
    _lock_menu_row "cancel" "$COMMENT" 'cancel' 'default'

    echo
    printf '    %b›%b ' "$GOLD" "$NC"
    # Single keypress, no Enter. EOF (piped close) falls through to cancel.
    read -rsn1 choice || choice=""
    echo

    local action="cancel"
    if [[ "$choice" =~ ^[1-9]$ ]] && [ "$choice" -le "${#dispatch[@]}" ]; then
        action="${dispatch[$((choice - 1))]}"
    fi

    case "$action" in
        force) return 0 ;;                              # force a second launch here
        open:*) exec "$0" "${action#open:}" ;;          # resume an existing feature
        tui) _vault_leave; exec "$0" -tui ;;            # pick a different session
        new)
            printf '    %bFeature name%b  %b›%b ' "$WHITE" "$NC" "$GOLD" "$NC"
            read -r feature || feature=""
            [ -n "$feature" ] && printf '    %b→ creates %s@%s · branch cs/%s%b\n' \
                "$DIM" "$session_name" "$feature" "$feature" "$NC"
            # cs_split_worktree_name validates the name after the re-exec;
            # keeping a second copy of its regex here would just drift.
            exec "$0" "$session_name@$feature"
            ;;
        *) info "Cancelled"; exit 0 ;;
    esac
}

# The numeric lock remains the compatibility liveness view. A modern launch
# also has a token-qualified lease; publish and release both under one guard.
_cs_acquire_session_lock_guarded() {  # meta_dir, force
    local meta="$1" force="$2" lock_pid="" lease_tmp="" lock_tmp=""
    _refuse_session_lock_not_a_file "$meta/session.lock"
    lock_pid=$(_cs_session_live_pid "$meta") || lock_pid=""
    if declare -F _remote_refuse_live >/dev/null; then
        _remote_refuse_live "$session_name" "$meta" "$lock_pid" "$remote"
    fi
    if [ -n "$lock_pid" ] && [ "$force" != true ]; then return 73; fi
    if [ -e "$meta/session.lock" ] && [ -z "$lock_pid" ]; then
        warn "Removing stale session lock (PID $(_cs_plain_name "$(read_lock_pid "$meta")" 40))"
    fi
    umask 077
    lock_tmp=$(mktemp "$meta/local/.session-lock.XXXXXX") || return 1
    printf '%s\n' "$$" > "$lock_tmp" || { rm -f "$lock_tmp"; return 1; }
    if [ -n "${CS_RUN_ID:-}" ]; then
        lease_tmp=$(mktemp "$meta/local/.run-lease.XXXXXX") || { rm -f "$lock_tmp"; return 1; }
        if ! jq -nc --arg id "$CS_RUN_ID" --arg engine "$CS_RUN_ENGINE" \
            --argjson owner "$$" --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{run_id: $id, engine: $engine, owner_pid: $owner, started_at: $started}' > "$lease_tmp"; then
            rm -f "$lock_tmp" "$lease_tmp"
            return 1
        fi
        mv "$lease_tmp" "$meta/local/run-lease.json" || { rm -f "$lock_tmp" "$lease_tmp"; return 1; }
    else
        rm -f "$meta/local/run-lease.json" || { rm -f "$lock_tmp"; return 1; }
    fi
    mv "$lock_tmp" "$meta/session.lock" || { rm -f "$lock_tmp"; return 1; }
}

_require_session_lock_perl() {  # meta_dir
    perl -MFcntl=:flock -e 1 >/dev/null 2>&1 || {
        printf 'Error: cs needs perl to lock this session (%s); install perl and retry\n' "$1" >&2
        return 1
    }
}

# Take a lock without an interactive collision menu, for encryption. Use the
# same mutex and lease guard as an open so a concurrent launcher cannot be
# replaced between the liveness check and publication. Returns 1 for a live
# holder and 2 for a held mutex; other failures keep their own status.
_take_session_lock() {  # meta_dir
    local meta="$1" status=0 remote="" session_name=""
    _CS_LOCK_LIVE_PID=""
    _require_session_lock_perl "$meta" || return 3
    _refuse_session_lock_not_a_file "$meta/session.lock"
    _cs_lock "$meta/session.mutex.lock" || return 2
    cs_run_guarded "$meta" _cs_acquire_session_lock_guarded "$meta" false || status=$?
    _cs_unlock "$meta/session.mutex.lock"
    case "$status" in
        73) _CS_LOCK_LIVE_PID=$(_cs_session_live_pid "$meta") || true; return 1 ;;
        0) return 0 ;;
        *) return 3 ;;
    esac
}

acquire_session_lock() {  # meta_dir, force, session_name
    local meta="$1" force="${2:-}" session_name="$3" remote="${4:-}" status=0 lock_pid=""
    _require_session_lock_perl "$meta" || return 1
    _refuse_session_lock_not_a_file "$meta/session.lock"
    lock_pid=$(_cs_session_live_pid "$meta") || lock_pid=""
    if [ -n "$lock_pid" ] && [ "$force" = true ] && [ "${CS_COLLISION_FORCE:-}" != 1 ]; then
        warn "Overriding active session lock (PID $lock_pid)"
    fi
    while :; do
        status=0
        if ! _cs_lock "$meta/session.mutex.lock"; then
            printf 'Error: Another cs is opening this session (%s is held)\n' "$meta/session.mutex.lock" >&2
            return 1
        fi
        cs_run_guarded "$meta" _cs_acquire_session_lock_guarded "$meta" "$force" || status=$?
        _cs_unlock "$meta/session.mutex.lock"
        [ "$status" -ne 0 ] || return 0
        [ "$status" -eq 73 ] || return "$status"
        lock_pid=$(_cs_session_live_pid "$meta") || lock_pid=""
        if cs_interactive; then
            # Never hold the ownership guard while waiting for user input.
            _lock_collision_menu "$session_name" "$lock_pid"
            CS_COLLISION_FORCE=1
            force=true
            warn "Overriding active session lock (PID $lock_pid)"
        else
            printf 'Error: Session is already open (PID %s)\n' "$lock_pid" >&2
            printf 'Use --force to override: cs %s --force\n' "$session_name" >&2
            return 1
        fi
    done
}

_cs_release_session_lock_guarded() {  # meta_dir
    local meta="$1" lock_pid=""
    [ ! -L "$meta/session.lock" ] && [ -f "$meta/session.lock" ] || return 0
    if [ -f "$meta/local/run-lease.json" ]; then
        cs_run_lease_owned "$meta" || return 0
        rm -f "$meta/session.lock" "$meta/local/run-lease.json"
    elif [ -z "${CS_RUN_ID:-}" ]; then
        { IFS= read -r lock_pid < "$meta/session.lock"; } 2>/dev/null || return 0
        [ "$lock_pid" != "$$" ] || rm -f "$meta/session.lock"
    fi
}

release_session_lock() {  # meta_dir
    [ -d "$1" ] || return 0
    _cs_lock "$1/session.mutex.lock" 2>/dev/null || return 0
    cs_run_guarded "$1" _cs_release_session_lock_guarded "$1" || true
    _cs_unlock "$1/session.mutex.lock"
}

# True (exit 0) when a session's process is currently alive on this machine.
# Arg: meta_dir (the session's .cs dir).
# A SIGKILL can end the supervising shell before its native child. Preserve
# that child's exclusion until it exits; its start time distinguishes a reused
# PID. If process metadata is unavailable, conservatively keep the live lock.
_cs_session_live_pid() {  # meta_dir
    local meta="$1" owner="" native="" signature="" actual=""
    owner=$(read_lock_pid "$meta")
    owner="${owner#"${owner%%[![:space:]]*}"}"
    owner="${owner%"${owner##*[![:space:]]}"}"
    case "$owner" in ''|*[!0-9]*) return 1 ;; esac
    owner="${owner#"${owner%%[!0]*}"}"
    _cs_pid_in_range "$owner" || return 1
    if kill -0 "$owner" 2>/dev/null; then printf '%s\n' "$owner"; return 0; fi
    native=$(jq -er --arg owner "$owner" \
        'select((.owner_pid | tostring) == $owner) | .native_pid | select(type == "number" and . > 1)' \
        "$meta/local/run-lease.json" 2>/dev/null) || return 1
    kill -0 "$native" 2>/dev/null || return 1
    signature=$(jq -r '.native_started // ""' "$meta/local/run-lease.json" 2>/dev/null) || signature=""
    if [ -n "$signature" ]; then
        actual=$(LC_ALL=C "${CS_PS_BIN:-ps}" -o lstart= -p "$native" 2>/dev/null | sed 's/^[[:space:]]*//') || actual=""
        [ -z "$actual" ] || [ "$actual" = "$signature" ] || return 1
    fi
    printf '%s\n' "$native"
}

session_is_live() {  # meta_dir
    _cs_session_live_pid "$1" >/dev/null
}

# True when target_pid is this cs process or one of its live ancestors. A cs
# launched from inside Claude is a descendant of the process recorded in the
# session lock: Claude runs in place of cs on a fresh launch and on a resume
# that is sure to land, and as a child of the lock-owning shell otherwise. The
# bounded BSD/POSIX ps walk fails closed on malformed output, disappearing
# processes, or an unexpectedly deep chain. PID 1 can never be a cs lock owner.
_pid_is_self_or_ancestor() {  # target_pid
    local target="$1" current="$$" parent="" depth=0
    case "$target" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$target" -gt 1 ] || return 1

    while [ "$depth" -lt 64 ]; do
        [ "$current" = "$target" ] && return 0
        case "$current" in
            ""|*[!0-9]*) return 1 ;;
        esac
        [ "$current" -gt 1 ] || return 1
        parent=$("${CS_PS_BIN:-ps}" -o ppid= -p "$current" 2>/dev/null \
            | awk 'NR == 1 { print $1 }') || return 1
        case "$parent" in
            ""|*[!0-9]*) return 1 ;;
        esac
        [ "$parent" != "$current" ] || return 1
        current="$parent"
        depth=$((depth + 1))
    done
    return 1
}

# True only for the invoking conversation's own lock. Exact session identity
# prevents a foreign alias of the same checkout from borrowing the ancestry
# exemption; ancestry prevents a stale lock whose PID was reused by an
# unrelated live process from borrowing the name.
session_lock_owned_by_invoker() {  # session_name, lock_pid
    [ -n "${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}" ] \
        && [ "${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}" = "$1" ] \
        && _pid_is_self_or_ancestor "$2"
}

# True when cs runs inside a session (CLAUDE_SESSION_NAME) other than <name>.
# A terminal outside every session is the user, never another session.
_called_from_other_session() {  # name
    [ -n "${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}" ] && [ "${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}" != "$1" ]
}

# Refuses <verb> (remove, archive, rotate the narrative of) on session <name>
# while its claude is running when cs runs inside a session that does not own
# it, --force or not: the flag skips the live check only from a terminal
# outside every session and for the caller's own sessions. A session owns itself and, from its base,
# its own features (<base>@<task>); a feature owns neither its base nor a
# sibling. An idle target is left to the verb's own checks. Called directly,
# never in $(...), so the error ends cs.
_refuse_live_other_session() {  # name meta_dir verb
    _called_from_other_session "$1" || return 0
    case "${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}" in
        *@*) ;;
        *) case "$1" in "${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}"@*) return 0 ;; esac ;;
    esac
    local pid
    pid="$(live_lock_pid "$2")"
    [ -n "$pid" ] || return 0
    error "session ${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}} cannot $3 session $1 while it is live (pid $pid); --force does not override that from another session. Close $1 first."
}

# Refuses <verb> (remove, archive) on base session <name> while one of its
# features (<name>@<task>) is live, when cs runs inside any session but <name>
# itself, --force or not: a feature's worktree points into its base's
# repository. Only a terminal outside every session and the base itself are
# not refused; a sibling feature is, and so is the live feature itself, whose
# own worktree the base holds. Called directly, never in $(...), so the error
# ends cs. A feature is <name>'s when <name>@<its task> is the same directory
# as the feature's (-ef), not when the names match as strings: a volume that
# ignores letter case or Unicode normalization finds one directory under
# several spellings, and a glob compares bytes.
_refuse_base_with_live_feature() {  # name verb
    [ -n "${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}" ] || return 0
    [ "${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}" != "$1" ] || return 0
    case "$1" in *@*) return 0 ;; esac
    local feature entry pid
    for feature in "$SESSIONS_ROOT"/*@*; do
        entry="${feature##*/}"
        [ "$SESSIONS_ROOT/$1@${entry#*@}" -ef "$feature" ] || continue
        [ -d "$feature/.cs" ] || continue
        pid="$(live_lock_pid "$feature/.cs")"
        [ -n "$pid" ] || continue
        error "session ${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}} cannot $2 session $1 while its feature ${feature##*/} is live (pid $pid); --force does not override that from another session. Close ${feature##*/} first."
    done
}

# Epoch mtime of a file, 0 on error. Arg: path. GNU stat is asked first, as
# _cs_file_mode does: BSD stat rejects -c with no output, while GNU stat reads
# -f as --file-system and prints that, and OSTYPE is no guide to which stat
# PATH finds (Homebrew's gnubin puts GNU stat on a Mac).
_epoch_mtime() {  # path
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# How long after the last statusline write a lockless conversation still counts
# as live, matching the TUI's HEARTBEAT_WINDOW_SECS. A conversation opened
# outside cs writes no lock, but its statusline touches .cs/local/context-pct
# every minute or two while it is open: an idle bar repaints once a minute.
HEARTBEAT_WINDOW_SECS=900

# True when the statusline heartbeat is fresh: context-pct was written within
# HEARTBEAT_WINDOW_SECS of now_epoch. Detects conversations open outside cs (no
# lock). A future mtime counts as live, matching the TUI's clamping. Takes
# now_epoch like session_uptime_secs so a loop over many sessions reads the
# clock once.
session_heartbeat_alive() {  # meta_dir, now_epoch
    local f="$1/local/context-pct"
    [ -f "$f" ] || return 1
    local mtime
    mtime="$(_epoch_mtime "$f")"
    [ "$(( $2 - mtime ))" -le "$HEARTBEAT_WINDOW_SECS" ]
}

# True when a session should DISPLAY as live: PID-locked, or breathing via the
# statusline heartbeat. Display surfaces (cs -live, cs -usage) use this so they
# match the TUI. The destructive guards (rm/archive/spawn) use strict
# session_is_live, so a session whose process is gone can still be removed
# without --force even if its statusline was touched recently. Uninstall's
# delete of the whole sessions root uses this broader test: it has no --force,
# and a conversation opened outside cs holds no lock.
session_display_live() {  # meta_dir, now_epoch
    session_is_live "$1" || session_heartbeat_alive "$1" "$2"
}

# Seconds since a session was last launched (its lock file's mtime).
# Args: meta_dir, now_epoch. Prints 0 if the lock is absent/unreadable.
session_uptime_secs() {  # meta_dir, now_epoch
    local f="$1/session.lock" now="$2" started
    [ -f "$f" ] || { echo 0; return 0; }
    started="$(_epoch_mtime "$f")"
    case "$started" in ''|*[!0-9]*) echo 0; return 0;; esac
    [ "$started" -gt 0 ] || { echo 0; return 0; }
    echo $(( now - started ))
}

# Stops cs, naming <lock file>, when it is anything but a regular file or
# absent. cs creates and removes the session lock as a regular file: a write
# or a read would go through a link to whatever it names, a directory would
# pass for a stale lock that rm cannot remove, and a write to a fifo blocks
# with no reader while the openers' mutex is held. Called before anything is
# written.
_refuse_session_lock_not_a_file() {  # lock_file
    [ ! -L "$1" ] || error "$1 is a link, where cs keeps the session lock; remove it and open the session again"
    [ ! -d "$1" ] || error "$1 is a directory, where cs keeps the session lock; remove it and open the session again"
    [ ! -e "$1" ] || [ -f "$1" ] || error "$1 is not a regular file, where cs keeps the session lock; remove it and open the session again"
}
