# ABOUTME: Codex hook entry points the installer registers in $CODEX_HOME/hooks.json (`cs -codex-hook <verb>`):
# ABOUTME: rebind after /clear with an armed rotation, recovery, and the automatic /clear after a rotation.

# What a fresh Codex conversation is told when it continues a rotation, both
# after /clear (this hook) and after `r` at launch (the launch context). The
# Claude wording lives in hooks/session-start.sh, which cannot source cs.
# Codex starts no turn on its own after /clear, so the context arrives with the
# user's first message and says how to read it. printf, not a here-document:
# bash 3.2 writes a here-document to a temp file.
_rotation_preamble_codex() {  # handoff_basename, actor_slug
    printf '%s\n' \
        '--- Conversation Rotation ---' \
        "This fresh conversation continues rotated work. Read .cs/handoffs/$1 FIRST — it is the previous conversation's handoff; the prior conversation is not loaded, and the handoff plus your own .cs/memory/narrative.$2.md carry the context." \
        '' \
        'The message that arrives with this context starts the work. A bare nudge — "go", "continue", "ok" — means begin: execute the handoff'"'"'s next step and report what you did, without re-summarising the handoff or asking which part to start with. A message carrying its own content takes precedence over the handoff; answer that instead. Ask first only where you normally would: the handoff is missing, unreadable, or genuinely ambiguous, or its next step is destructive or irreversible.' \
        '' \
        "Once that next step is done, append a \`## Successor report\` section to the end of .cs/handoffs/$1: each thing you had to look up again, re-derive, or found wrong in the handoff, with how you found out, or \`none\`. Append only; never rewrite what the previous conversation wrote."
}

# A /clear with nothing armed: a clean break, said so the conversation does not
# act on history it no longer has.
_fresh_notice_codex() {  # actor_slug
    printf '%s\n' \
        '--- Fresh Conversation ---' \
        'The user explicitly started a fresh conversation in this cs session with /clear; the prior conversation is not loaded. Treat this as a clean break, not a continuation.' \
        '' \
        'For prior context, read as needed:' \
        "- .cs/memory/narrative.$1.md — your findings and decisions from earlier work (append only here)" \
        '- .cs/README.md — session objective'
}

cmd_codex_hook() {  # event
    case "${1:-}" in
        session-start) _codex_hook_session_start ;;
        files-changed) _codex_hook_files_changed ;;
        stop) _codex_hook_stop ;;
        user-prompt-submit) _codex_hook_user_prompt_submit ;;
        *)
            printf 'Usage: cs -codex-hook session-start|files-changed|stop|user-prompt-submit\n' >&2
            return 2
            ;;
    esac
}

_codex_hook_files_changed() {
    local event hook
    [ "${CS_RUN_ENGINE:-}" = codex ] && [ -n "${CS_SESSION_DIR:-}" ] || return 0
    event=$(cs_engine_call codex files_changed) || return 0
    [ -n "$event" ] || return 0
    hook="${CODEX_HOME:-$HOME/.codex}/hooks/cs/autosave-commits.sh"
    [ -r "$hook" ] || return 0
    printf '%s' "$event" | bash "$hook" --event || true
}

# Codex fires SessionStart on the first turn of a thread, before the model
# call: source `resume` for every cs launch (cs creates the thread, then
# resumes it), `clear` for the first message after /clear, with the new
# thread's id. Only `clear` changes anything here; the launch path owns every
# other binding and its own rotation (`r`). The hook must never fail a turn,
# so every path returns 0 and anything it cannot do it skips.
_codex_hook_session_start() {
    local input session_id source session_dir meta log_dir actor handoff context="" sysmsg=""
    input=$(cat) || input=""
    session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
    source=$(printf '%s' "$input" | jq -r '.source // ""' 2>/dev/null) || source=""
    # Only a conversation cs launched carries a session; a plain codex run
    # anywhere else passes through untouched.
    [ "${CS_RUN_ENGINE:-}" = codex ] && [ -n "${CS_SESSION_DIR:-}" ] || return 0
    session_dir="$CS_SESSION_DIR"
    meta="$session_dir/.cs"
    [ -d "$meta/local" ] || return 0
    _codex_thread_id_valid "$session_id" || return 0
    # The rotate skill and the launch prompt read which conversations this
    # checkout ran from this line; hooks/session-start.sh writes it for Claude.
    # A locked vault drops it rather than leave a plaintext log beside it.
    if log_dir=$(cs_private_dir "$meta"); then
        { printf '%s - Session started (source: %s, ID: %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
            "${source:-unknown}" "$session_id" >> "$log_dir/session.log"; } 2>/dev/null || true
    fi
    [ "$source" = clear ] || return 0
    # The launched conversation alone may rebind: the slot is one per checkout.
    cs_run_lease_owned "$meta" || return 0
    handoff=$(_rotation_armed_handoff "$session_dir")
    cs_run_with_lease "$meta" _codex_hook_rebind "$session_dir" "$session_id" "$handoff" || return 0
    actor=$(cs_actor_slug "$session_dir" 2>/dev/null) || actor=unknown
    if [ -n "$handoff" ]; then
        _handoff_set_status "$session_dir/.cs/handoffs/$handoff" consumed "$session_id" || true
        rm -f "$meta/local/pending-handoff" 2>/dev/null || true
        context=$(_rotation_preamble_codex "$handoff" "$actor")
        sysmsg="Rotation loaded from $handoff; this conversation continues from it."
    else
        context=$(_fresh_notice_codex "$actor")
    fi
    jq -n --arg context "$context" --arg sysmsg "$sysmsg" '
        {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}
        + (if $sysmsg == "" then {} else {systemMessage: $sysmsg} end)' 2>/dev/null || true
    return 0
}

# Under the run lease: point the session at the thread /clear opened, so the
# next `cs <name>` resumes it, and record the lineage the way a launch does.
_codex_hook_rebind() {  # session_dir, thread_id, handoff
    local session_dir="$1" thread_id="$2" handoff="$3" previous log_dir reason=rebind
    previous=$(cs_binding_read "$session_dir" codex) || return 1
    [ "$previous" != "$thread_id" ] || return 0
    cs_binding_write "$session_dir" codex "$thread_id" || return 1
    _cs_set_local_state_unlocked "$session_dir/.cs/local/state" engine codex || return 1
    [ -z "$handoff" ] || reason=handoff
    if log_dir=$(cs_private_dir "$session_dir/.cs"); then
        { printf '%s - Rebound codex thread: %s -> %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
            "${previous:-none}" "$thread_id" >> "$log_dir/session.log"; } 2>/dev/null || true
    fi
    if [ -n "$previous" ]; then
        _timeline_rotated "$session_dir" "$previous" "$thread_id" "$reason" "$handoff" codex || true
    fi
    _timeline_started "$session_dir" codex "$thread_id" clear || true
}

# The automatic /clear after a rotation: Codex's counterpart of the cs mod's
# countdown under Claude. No Codex plugin can run a command, so three pieces
# share the job. The Stop hook, at the end of a turn that leaves a handoff
# armed, writes a deadline into this run's private directory. The
# UserPromptSubmit hook drops it, so a message sent first keeps the
# conversation; the count starts again when that turn ends. A watcher the Codex
# launch runs beside the CLI (lib/76-codex.sh) types /clear, then go, into the
# terminal once the deadline has passed and the same handoff is still armed;
# with a switch pending it types /quit, and cs reopens the session under the
# other engine. CS_ROTATE_FORCE_CTX set to off (or 0) leaves the keys to the
# user, as it does under Claude, and so does CS_CODEX_CLEAR_GRACE=0.
#
# The deadline is the watcher's licence to type, so it lives where the agent
# cannot write: Codex's workspace sandbox writes anywhere in the session, /tmp
# and $TMPDIR, and a deadline forged there would have the watcher type /clear
# and Enter into whatever the terminal shows, an approval prompt included. The
# hooks and the watcher each find the directory from their own environment:
# cs's cache, then codex-runs/<run id>, made 0700 by the launch before Codex
# starts and removed when the run ends.
_codex_run_dir() {
    _is_uuid "${CS_RUN_ID:-}" || return 1
    printf '%s/codex-runs/%s\n' "${CS_CACHE_DIR:-$HOME/.cache/cs}" "$CS_RUN_ID"
}

# Whether a directory lies, once symlinks are resolved, under a root the
# sandbox may write: the session, $TMPDIR or /tmp (macOS's /tmp is
# /private/tmp). A directory it cannot resolve counts as inside.
_codex_run_dir_in_sandbox_root() {  # dir, session_dir
    local dir root resolved
    dir=$(cd "$1" 2>/dev/null && pwd -P) || return 0
    for root in "$2" "${TMPDIR:-}" /tmp /private/tmp; do
        [ -n "$root" ] || continue
        resolved=$(cd "$root" 2>/dev/null && pwd -P) || continue
        case "$dir/" in "${resolved%/}/"*) return 0 ;; esac
    done
    return 1
}

# The run directory as the launch made it: a real directory, the user's, mode
# 700, and outside every root the sandbox may write.
_codex_run_dir_ok() {  # run_dir, session_dir
    [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
    [ "$(_cs_file_mode "$1" 2>/dev/null)" = 700 ] || return 1
    ! _codex_run_dir_in_sandbox_root "$1" "$2"
}

# The deadline as the Stop hook writes it: a regular file, the user's, mode 600.
_codex_stamp_ok() {  # file
    [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
    [ "$(_cs_file_mode "$1" 2>/dev/null)" = 600 ]
}

# Makes this run's directory, before Codex starts, and prints it. A directory
# already there is not this run's, and one the checks refuse is taken back.
_codex_run_dir_prepare() {  # session_dir
    local dir
    dir=$(_codex_run_dir) || return 1
    ( umask 077 && mkdir -p "${dir%/*}" && mkdir -m 700 "$dir" ) 2>/dev/null || return 1
    if ! _codex_run_dir_ok "$dir" "$1"; then
        rmdir "$dir" 2>/dev/null || true
        return 1
    fi
    printf '%s\n' "$dir"
}

_codex_autoclear_file() {  # run_dir
    printf '%s/autoclear\n' "$1"
}

# The seconds the count runs (CS_CODEX_CLEAR_GRACE, default 20, the mod's
# grace), or failure when the automatic /clear is off. A CS_ROTATE_FORCE_CTX
# nobody can read is not off, as in the mod. The grace is read as decimal, so
# 08 is eight seconds rather than an octal error that would fail the turn. A
# grace of 0 turns the count off, as CS_ROTATE_FORCE_CTX=0 does, rather than
# typing at the next poll, while the turn that armed it may still be closing.
_codex_autoclear_grace() {
    local force grace="${CS_CODEX_CLEAR_GRACE:-20}"
    force=$(printf '%s' "${CS_ROTATE_FORCE_CTX:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ "$force" != off ] || return 1
    ! [[ "$force" =~ ^0+$ ]] || return 1
    if [[ "$grace" =~ ^[0-9]+$ ]]; then grace=$((10#$grace)); else grace=20; fi
    [ "$grace" -ne 0 ] || return 1
    printf '%s\n' "$grace"
}

# Only the conversation this run launched and the session is bound to counts
# down; a turn in any other thread, or a teammate's, never clears it. The hook
# must never fail a turn, so every path returns 0.
_codex_hook_stop() {
    local input session_id session_dir meta run_dir stamp grace bound handoff tmp deadline
    local action=clear target="" switch_file sysmsg
    input=$(cat) || input=""
    [ "${CS_RUN_ENGINE:-}" = codex ] && [ -n "${CS_SESSION_DIR:-}" ] || return 0
    session_dir="$CS_SESSION_DIR"
    meta="$session_dir/.cs"
    [ -d "$meta/local" ] || return 0
    session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
    _codex_thread_id_valid "$session_id" || return 0
    # No private directory, no watcher: nothing would type the keys, so the
    # turn ends without a count or a line promising one.
    run_dir=$(_codex_run_dir) && _codex_run_dir_ok "$run_dir" "$session_dir" || return 0
    stamp=$(_codex_autoclear_file "$run_dir")
    grace=$(_codex_autoclear_grace) || { rm -f "$stamp" 2>/dev/null; return 0; }
    cs_run_lease_owned "$meta" || return 0
    bound=$(cs_binding_read "$session_dir" codex 2>/dev/null) || return 0
    [ "$bound" = "$session_id" ] || return 0
    handoff=$(_rotation_armed_handoff "$session_dir")
    [ -n "$handoff" ] || { rm -f "$stamp" 2>/dev/null; return 0; }
    # A switch this run recorded leaves Codex instead: /quit, and cs relaunches.
    if switch_file=$(_switch_file "$session_dir") && [ -f "$switch_file" ] \
        && [ "$(_switch_field "$switch_file" run)" = "${CS_RUN_ID:-}" ]; then
        target=$(_switch_field "$switch_file" engine)
        [ -z "$target" ] || action=quit
    fi
    # The deadline is worked out before the temp file exists, so nothing that
    # fails here can leave one behind.
    deadline=$(( $(date +%s) + grace ))
    # mktemp makes the file 0600, the mode the watcher requires.
    tmp=$(mktemp "$stamp.XXXXXX" 2>/dev/null) || return 0
    if ! { printf 'deadline=%s\nhandoff=%s\nthread=%s\naction=%s\nrun=%s\n' \
        "$deadline" "$handoff" "$session_id" "$action" "${CS_RUN_ID:-}" > "$tmp" \
        && mv "$tmp" "$stamp"; } 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 0
    fi
    if [ "$action" = quit ]; then
        sysmsg="cs: /quit in $grace s, and cs reopens this session under $target from $handoff. Send a message first to stay."
    else
        sysmsg="cs: /clear and go in $grace s, to continue from $handoff. Send a message first to keep this conversation."
    fi
    jq -n --arg m "$sysmsg" '{systemMessage: $m}' 2>/dev/null || true
    return 0
}

# A message sent while the count runs stops it. Any message does: the hook
# only removes, so a prompt in another thread costs at most one count.
_codex_hook_user_prompt_submit() {
    local run_dir
    cat >/dev/null 2>&1 || true
    [ "${CS_RUN_ENGINE:-}" = codex ] && [ -n "${CS_SESSION_DIR:-}" ] || return 0
    [ -d "$CS_SESSION_DIR/.cs/local" ] || return 0
    run_dir=$(_codex_run_dir) && _codex_run_dir_ok "$run_dir" "$CS_SESSION_DIR" || return 0
    rm -f "$(_codex_autoclear_file "$run_dir")" 2>/dev/null || true
    return 0
}

# Types text and Enter into the controlling terminal as if typed (TIOCSTI):
# a character every 100 ms and a pause before Enter, because Codex reads a
# burst as a paste and its Enter as a newline. Measured on 0.162: "/clear" sent
# at once stayed in the composer unsent, and a 19-character line at 50 ms a key
# got a newline where 8 characters at that pace submitted. Fails where the
# terminal refuses simulated input, as Linux does with dev.tty.legacy_tiocsti=0.
_codex_type_keys() {  # text
    python3 -I -c '
import fcntl, os, sys, termios, time
fd = os.open("/dev/tty", os.O_RDWR)
try:
    for ch in sys.argv[1].encode():
        fcntl.ioctl(fd, termios.TIOCSTI, bytes([ch]))
        time.sleep(0.1)
    time.sleep(0.5)
    fcntl.ioctl(fd, termios.TIOCSTI, b"\r")
finally:
    os.close(fd)
' "$1" 2>/dev/null
}

# Whether the terminal the keys would go to is still there. A closed tab hangs
# it up; the watcher then has nothing to type into and ends.
_codex_autoclear_terminal() {
    { : </dev/tty; } 2>/dev/null
}

# Runs beside the Codex CLI for its lifetime (lib/76-codex.sh) and ends with
# the run's owner or its terminal; the launcher also stops it once the CLI
# exits (_cs_run_stop_helper). Once a second it reads the deadline the Stop
# hook wrote into the run's directory, and only from there: a directory that
# stops being private ends the watch, and a deadline file that is not what the
# hook writes is dropped unread. Past the deadline, with the same handoff still
# armed by this run, it consumes the deadline and types the keys. The armed
# handoff is a liveness check, not the licence: the agent may arm one itself.
# /clear and go are two prompts: Codex starts no turn after /clear, and cs's
# SessionStart hook hands the new thread the handoff with its first message.
_codex_autoclear_watch() {  # session_dir, run_dir
    local session_dir="$1" run_dir="$2" stamp deadline handoff action run
    stamp=$(_codex_autoclear_file "$run_dir")
    while kill -0 "${CS_RUN_OWNER_PID:-$$}" 2>/dev/null && _codex_autoclear_terminal; do
        sleep 1
        if ! _codex_run_dir_ok "$run_dir" "$session_dir"; then
            _codex_autoclear_log "$session_dir" "Automatic /clear: this run's directory is gone or no longer private; the /clear is yours"
            return 0
        fi
        [ -e "$stamp" ] || [ -L "$stamp" ] || continue
        if ! _codex_stamp_ok "$stamp"; then
            rm -f "$stamp" 2>/dev/null || true
            continue
        fi
        run=$(_switch_field "$stamp" run)
        deadline=$(_switch_field "$stamp" deadline)
        if [ "$run" != "${CS_RUN_ID:-}" ] || ! [[ "$deadline" =~ ^[0-9]+$ ]]; then
            rm -f "$stamp" 2>/dev/null || true
            continue
        fi
        [ "$(date +%s)" -ge "$deadline" ] || continue
        handoff=$(_switch_field "$stamp" handoff)
        action=$(_switch_field "$stamp" action)
        rm -f "$stamp" 2>/dev/null || true
        [ -n "$handoff" ] && [ "$(_rotation_armed_handoff "$session_dir")" = "$handoff" ] || continue
        if [ "$action" = quit ]; then
            _codex_type_keys /quit && continue
        else
            _codex_type_keys /clear && sleep 2 && _codex_type_keys go && continue
        fi
        # The keys did not land: the person still has /clear, as before.
        _codex_autoclear_log "$session_dir" "Automatic /clear: the terminal refused simulated input; run /clear and send go"
    done
}

_codex_autoclear_log() {  # session_dir, line
    local log_dir
    if log_dir=$(cs_private_dir "$1/.cs"); then
        { printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" >> "$log_dir/session.log"; } 2>/dev/null || true
    fi
}
