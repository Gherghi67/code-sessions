# ABOUTME: Backs 'cs <name> --remote': serve an open session through claude remote-control,
# ABOUTME: in its own window of the cs tmux session when run inside tmux.

# The Claude Code version remote-control was measured on (spike606, 2026-10-14):
# its flags after the verb, the refusal of root flags before it, and the env
# it hands the sessions it starts.
_REMOTE_MIN_CLAUDE_VERSION="2.1.299"

# The absolute path of the claude remote-control is run by, in
# _CS_REMOTE_BIN. remote-control refuses root options before its verb rather
# than drop them, so a CLAUDE_CODE_BIN carrying options after the command is
# refused here the same way, by name, before anything is opened.
_CS_REMOTE_BIN=""

# Path of the running server's pid file; the EXIT trap of _serve_remote reads
# it from this global when it fires.
_CS_REMOTE_PID_FILE=""

# True when dotted version <have> is <want> or later, compared field by field
# as numbers (2.1.1000 is later than 2.1.299). Both are three dot-separated
# runs of digits.
_version_at_least() {  # have, want
    local IFS=. h1 h2 h3 w1 w2 w3
    read -r h1 h2 h3 <<< "$1"
    read -r w1 w2 w3 <<< "$2"
    h1=$((10#$h1)); h2=$((10#$h2)); h3=$((10#$h3))
    w1=$((10#$w1)); w2=$((10#$w2)); w3=$((10#$w3))
    [ "$h1" -eq "$w1" ] || return $(( h1 > w1 ? 0 : 1 ))
    [ "$h2" -eq "$w2" ] || return $(( h2 > w2 ? 0 : 1 ))
    return $(( h3 >= w3 ? 0 : 1 ))
}

# Resolve and vet the claude that runs remote-control; sets _CS_REMOTE_BIN.
# check_dependencies has already found the command word on PATH.
_remote_claude_bin() {
    local word rest found version
    word=$(_claude_bin_word)
    rest=$(_trim "${CLAUDE_CODE_BIN#*"$word"}")
    [ -z "$rest" ] || error "cs --remote runs claude remote-control, which refuses options before its verb; CLAUDE_CODE_BIN carries \"$rest\" after the command. Set CLAUDE_CODE_BIN to the command alone for --remote."
    found=$(command -v -- "$word") || error "cs --remote cannot find $word on PATH"
    case "$found" in
        /*) ;;
        *) found="$(cd "$(dirname "$found")" && pwd)/$(basename "$found")" ;;
    esac
    version=$("$found" --version 2>/dev/null \
        | awk 'match($0, /[0-9]+\.[0-9]+\.[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }') || version=""
    [ -n "$version" ] \
        || error "cs --remote needs Claude Code $_REMOTE_MIN_CLAUDE_VERSION or later for claude remote-control; $found --version printed no version number."
    _version_at_least "$version" "$_REMOTE_MIN_CLAUDE_VERSION" \
        || error "cs --remote needs Claude Code $_REMOTE_MIN_CLAUDE_VERSION or later for claude remote-control; $found is $version. Update Claude Code, then retry."
    _CS_REMOTE_BIN="$found"
}

# The pid of the remote-control server serving a session, from its
# .cs/local/remote.pid, when that process is running. Fails otherwise.
_remote_server_pid() {  # meta_dir
    local f="$1/local/remote.pid" pid=""
    [ -f "$f" ] || return 1
    IFS= read -r pid < "$f" 2>/dev/null || true
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s' "$pid"
}

# The refusals an open meets when the session's lock is held by a live
# process: a session a remote-control server serves takes no other open, not
# even a forced one (one claude family per session directory), and
# `cs <name> --remote` serves only a session that is not open. Returns when
# neither applies.
_remote_refuse_live() {  # session_name, meta_dir, lock_pid, [remote]
    local spid
    if spid=$(_remote_server_pid "$2"); then
        error "Session $1 is served by cs $1 --remote (remote-control PID $spid); stop it first with Ctrl-C in its window, or close the window."
    fi
    [ -z "${4:-}" ] \
        || error "Session $1 is already open (PID $3); cs $1 --remote serves only a session that is not open. Close it first."
    return 0
}

# Inside tmux the server gets a window of its own, remote:<name>, in the
# cs-owned tmux session, where it has a terminal for its first-run and
# folder-trust prompts. The window runs `cs <name> --remote` again with
# CS_REMOTE_WINDOW set, so that run serves in place instead of opening
# another window. The refusals a window would show and then lose with the
# window are made here first, on the caller's terminal.
_remote_open_window() {  # session_name, permission_mode
    local name="$1" mode="$2" meta="$SESSIONS_ROOT/$1/.cs"
    if session_is_live "$meta"; then
        _remote_refuse_live "$name" "$meta" "$(read_lock_pid "$meta")" remote
    fi
    _spawn_precheck "$name" "remote:$name"
    _cs_tmux_window "remote:$name" \
        "env CS_REMOTE_WINDOW=1 $(_sq "$(_cs_self)") $(_sq "$name") --remote --permission-mode $(_sq "$mode")"
    info "remote:$name runs in tmux session cs (window $_CS_TMUX_WID). Attach: $(_spawn_attach_hint)"
}

# Run claude remote-control in the session directory, which launch_claude_code
# has opened with every export a claude launch gets: the server hands its
# whole environment to the sessions it starts, so cs's hooks, memory path,
# task list and secrets scope reach them. Never returns.
#
# The server is cs's foreground child, so it shares cs's terminal, and a
# Ctrl-C or the hangup of a closed window reaches it directly; cs holds the
# session lock until it exits. A sh in front records its own pid in
# .cs/local/remote.pid and then execs claude, so the file names the server.
# Signals to cs only wait for the server: bash runs a trap after its
# foreground child ends, and ':' rather than an ignored signal, since an
# ignored one would be ignored by the server too. cs then exits with the
# server's status, and the EXIT trap removes the pid file and the lock.
#
# A server that fails in its tmux window would take its error with the
# window, so there it waits for a key first.
_serve_remote() {  # session_name, session_dir, permission_mode, in_window
    local name="$1" dir="$2" mode="$3" in_window="$4" rc=0 key=""
    _CS_REMOTE_PID_FILE="$dir/.cs/local/remote.pid"
    trap '[ -n "${TMUX:-}" ] || reset_tab_title; rm -f "$_CS_REMOTE_PID_FILE"; release_session_lock "$_CS_LOCK_META_DIR"; _detach_opened_vault' EXIT
    trap ':' HUP INT TERM
    # remote-control refuses to start while an API key is set.
    unset ANTHROPIC_API_KEY
    # Inside tmux the window keeps its remote:<name> name, which
    # _spawn_precheck reads to refuse a second window.
    [ -n "${TMUX:-}" ] || set_tab_title "cs: $name (remote)" "auto:$name"
    cd "$dir"
    info "Serving $name through claude remote-control (permission mode $mode). Ctrl-C or closing the window stops it."
    sh -c 'printf "%s\n" "$$" > "$1" || exit 1; shift; exec "$@"' cs-remote \
        "$_CS_REMOTE_PID_FILE" "$_CS_REMOTE_BIN" remote-control --name "$name" --permission-mode "$mode" \
        || rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$in_window" ] && cs_interactive; then
        printf '%s\n' "claude remote-control exited with status $rc. Press a key to close this window."
        IFS= read -rsn1 key || true
    fi
    exit "$rc"
}
