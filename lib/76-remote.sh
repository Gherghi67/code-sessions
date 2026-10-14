# ABOUTME: Backs 'cs <name> --remote': serve an open session through claude remote-control,
# ABOUTME: in its own window of the cs tmux session when run inside tmux.

# The Claude Code version remote-control was measured on (spike606, 2026-10-14):
# its flags after the verb, the refusal of root flags before it, and the env
# it hands the sessions it starts.
_REMOTE_MIN_CLAUDE_VERSION="2.1.299"

# The absolute path of the claude remote-control is run by, in
# _CS_REMOTE_BIN. remote-control refuses root options before its verb, and
# the mode of the sessions it starts is --remote's own --permission-mode, so
# remote-control runs with CLAUDE_CODE_BIN's command word alone: whatever
# CLAUDE_CODE_BIN carries after it is dropped, and one line on stderr names
# it, before anything is opened.
_CS_REMOTE_BIN=""

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
# check_dependencies has already found the command word on PATH. The text
# after the command word is named as written, blanks around it trimmed. The
# tmux window is handed _CS_REMOTE_BIN, with nothing after it, so its run
# drops nothing and the line is printed once, on the caller's terminal.
_remote_claude_bin() {
    local word rest found output version rc=0
    word=$(_claude_bin_word)
    rest=$(_trim "${CLAUDE_CODE_BIN#*"$word"}")
    [ -z "$rest" ] \
        || warn "cs --remote runs $word remote-control without the rest of CLAUDE_CODE_BIN; --remote's own --permission-mode sets the permission mode of the sessions it starts. Dropped: $rest" >&2
    found=$(command -v -- "$word") || error "cs --remote cannot find $word on PATH"
    case "$found" in
        /*) ;;
        *) found="$(cd "$(dirname "$found")" && pwd)/$(basename "$found")" ;;
    esac
    output=$("$found" --version 2>/dev/null) || rc=$?
    [ "$rc" -eq 0 ] \
        || error "cs --remote needs Claude Code $_REMOTE_MIN_CLAUDE_VERSION or later for claude remote-control; $found --version exited with status $rc."
    version=$(awk 'match($0, /[0-9]+\.[0-9]+\.[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }' <<< "$output")
    [ -n "$version" ] \
        || error "cs --remote needs Claude Code $_REMOTE_MIN_CLAUDE_VERSION or later for claude remote-control; $found --version printed no version number."
    _version_at_least "$version" "$_REMOTE_MIN_CLAUDE_VERSION" \
        || error "cs --remote needs Claude Code $_REMOTE_MIN_CLAUDE_VERSION or later for claude remote-control; $found is $version. Update Claude Code, then retry."
    _CS_REMOTE_BIN="$found"
}

# The pid of the remote-control server serving session <name>, from its
# .cs/local/remote.pid, when that pid runs `remote-control --name <name>`.
# Fails otherwise. A server whose release never ran (its process group
# killed with SIGKILL, a crash, a restart) leaves the file behind, and its pid
# can later belong to any program, so a running pid alone proves nothing; the
# argv is matched as the live-duplicate guard in launch_claude_code matches
# --name, padded so demo does not match demo-2. ps is called directly, not
# through CS_PS_BIN: that seam blanks the machine-wide scan in tests, and this
# asks about one pid.
_remote_server_pid() {  # meta_dir, session_name
    local f="$1/local/remote.pid" pid="" args
    [ -f "$f" ] || return 1
    IFS= read -r pid < "$f" 2>/dev/null || true
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    args=$(ps -ww -o args= -p "$pid" 2>/dev/null) || return 1
    case " $args " in
        *" remote-control --name $2 "*) printf '%s' "$pid" ;;
        *) return 1 ;;
    esac
}

# The refusals an open meets when the session's lock is held by a live
# process: a session a remote-control server serves takes no other open, not
# even a forced one (one claude family per session directory), and
# `cs <name> --remote` serves only a session that is not open. Returns when
# neither applies.
_remote_refuse_live() {  # session_name, meta_dir, lock_pid, [remote]
    local spid
    if spid=$(_remote_server_pid "$2" "$1"); then
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
# window are made here first, on the caller's terminal. A server that fails
# later would take its error with the window, so a sh in front waits for
# Enter after a failure; it is the window's first process, and when the
# window closes it ends and the server, its foreground job, gets the hangup.
# tmux starts the window with the tmux server's environment, not this
# shell's, so the command names the sessions root and the claude checked
# here (_CS_REMOTE_BIN, an absolute path): the window serves this session
# with that claude, whatever the tmux server's own settings and PATH say.
_remote_open_window() {  # session_name, permission_mode
    local name="$1" mode="$2" meta="$SESSIONS_ROOT/$1/.cs"
    if session_is_live "$meta"; then
        _remote_refuse_live "$name" "$meta" "$(read_lock_pid "$meta")" remote
    fi
    _spawn_precheck "$name" "remote:$name" "cs --remote"
    _cs_tmux_window "remote:$name" \
        "sh -c $(_sq '"$@" || { s=$?; printf "\nclaude remote-control exited with status %s. Press Enter to close this window.\n" "$s"; read -r _; exit "$s"; }') cs-remote env CS_REMOTE_WINDOW=1 $(_sq "CS_SESSIONS_ROOT=$SESSIONS_ROOT") $(_sq "CLAUDE_CODE_BIN=$_CS_REMOTE_BIN") $(_sq "$(_cs_self)") $(_sq "$name") --remote --permission-mode $(_sq "$mode")"
    info "remote:$name runs in tmux session cs (window $_CS_TMUX_WID). Attach: $(_spawn_attach_hint)"
}

# After the server <pid> exits: remove .cs/local/remote.pid while it names
# <pid>, release the session lock (which names <pid> as well), and detach a
# vault this open mounted. Run in the background before the exec, so $$ here
# is the pid the server takes over. It ignores the signals that stop the
# server, holds no terminal, and checks once a second, like the vault waiter
# SessionEnd leaves.
_remote_release_after() {  # pid, meta_dir
    local pid=""
    trap - EXIT
    trap '' HUP INT TERM
    while kill -0 "$1" 2>/dev/null; do
        sleep 1
    done
    { IFS= read -r pid < "$2/local/remote.pid"; } 2>/dev/null || true
    if [ "$pid" = "$1" ]; then
        rm -f "$2/local/remote.pid"
    fi
    release_session_lock "$2"
    _detach_opened_vault
}

# Serve the session through claude remote-control, in place of this cs:
# launch_claude_code has opened it with every export a claude launch gets, and
# the server hands its whole environment to the sessions it starts, so cs's
# hooks, memory path, task list and secrets scope reach them. Never returns.
#
# cs execs the server, as every other launch execs claude, so the server
# keeps this pid: the session lock and .cs/local/remote.pid name it, and the
# server meets Ctrl-C and the hangup of a closed window or terminal exactly
# as when run by hand, which stops it cleanly (measured on 2.1.299). Its
# exit status is the run's. What cs leaves behind goes once the server has
# exited, through _remote_release_after.
_serve_remote() {  # session_name, session_dir, permission_mode
    local name="$1" dir="$2" mode="$3" meta="$2/.cs"
    # remote-control refuses to start while an API key is set.
    unset ANTHROPIC_API_KEY
    # Inside tmux the window keeps its remote:<name> name, which
    # _spawn_precheck reads to refuse a second window.
    [ -n "${TMUX:-}" ] || set_tab_title "cs: $name (remote)" "auto:$name"
    cd "$dir" || error "could not enter $dir"
    printf '%s\n' "$$" > "$meta/local/remote.pid" || error "could not write $meta/local/remote.pid"
    _remote_release_after "$$" "$meta" < /dev/null > /dev/null 2>&1 &
    info "Serving $name through claude remote-control (permission mode $mode). Ctrl-C or closing the window stops it."
    exec "$_CS_REMOTE_BIN" remote-control --name "$name" --permission-mode "$mode"
}
