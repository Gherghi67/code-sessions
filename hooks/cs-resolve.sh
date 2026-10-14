#!/usr/bin/env bash
# ABOUTME: Resolves the cs session for a hook, from the env or from the cwd
# ABOUTME: Sourced by every hook; also carries JSONL tail repair. Not a hook itself

# Claude Code front ends differ in what they can hand a hook. The CLI is
# launched by `cs`, which exports the session contract before exec, so a hook
# inherits it. The desktop app spawns sessions itself: CLAUDE_ENV_FILE is
# offered to SessionStart and writes to it succeed, but nothing propagates to
# the Bash tool or to later hooks, so no hook can publish the contract to the
# rest of the session. What every front end does supply is the directory the
# session is open on (CLAUDE_PROJECT_DIR, and `cwd` in the hook input). A cs
# session is marked on disk by its .cs/ directory, and known to this machine
# by its entry under the sessions root: cs puts every session it makes there,
# as the directory itself or as a link to it.
#
# So: trust the env when it is there, and otherwise find the session the same
# way a person would, by looking at where we are -- except in a terminal, where
# `cs` is how a session is entered and the contract would have been exported.
# The .cs/ marker alone is never enough: a cloned repository can carry any
# file under .cs/, and a hook cannot run the checks `cs` runs at open, so the
# walk accepts only a directory the sessions root knows.

# Resolve the session and export the contract. Returns 0 when a session was
# found, non-zero otherwise, leaving the caller's own decline path to run
# (hooks decline differently: exit 0, an approve payload, a JSON verdict).
cs_resolve_session() {  # [hook_input_json]
    local input="${1:-}" start="" dir="" name=""

    # Env first: the CLI path resolves here and never reaches the walk below.
    # The disabled marker is the one thing that does apply to it as well, and
    # deliberately: an opt-out that silenced one front end but not the other
    # would be a worse rule than "this directory is not a cs session".
    if [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]; then
        [ -d "$CLAUDE_SESSION_DIR" ] || return 1
        : "${CLAUDE_SESSION_META_DIR:=$CLAUDE_SESSION_DIR/.cs}"
        export CLAUDE_SESSION_META_DIR
        _cs_session_is_enabled "$CLAUDE_SESSION_DIR" || return 1
        # Preserved, not overwritten: a teammate is handed the contract AND
        # this marker by session-start.sh, so its later hooks resolve here
        # while session-end.sh can still see the launch was someone else's.
        : "${CS_RESOLVED_FROM:=env}"
        export CS_RESOLVED_FROM
        _cs_note_tracked_files
        return 0
    fi

    # A terminal claude enters a session through `cs`, which exports the
    # contract above, so one arriving here was started another way and is not in
    # a session -- the .cs/ it may be standing in belongs to a session, not to
    # this conversation. Claude Code names its own front end here: an
    # interactive terminal is "cli" and `claude -p` is "sdk-cli". The test is
    # affirmative on purpose, listing the terminal rather than excluding it, so
    # an unset or unfamiliar entrypoint keeps the walk that a front end able to
    # publish nothing depends on.
    #
    # An agent-team teammate is the exception that stops this being a test on
    # the entrypoint alone: Claude Code respawns it in a tmux pane, which
    # inherits neither the contract nor an entrypoint from the lead, so it
    # derives plain "cli" and reads identically to a bare claude. It is in the
    # session -- it was spawned to work there -- so the launch flag decides.
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in
        cli|sdk-cli)
            _cs_is_teammate || return 1
            ;;
    esac

    # Prefer CLAUDE_PROJECT_DIR: it names the folder the session was opened on
    # and stays constant, where a hook input's cwd can follow the conversation.
    start="${CLAUDE_PROJECT_DIR:-}"
    if [ -z "$start" ] && [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
        start=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
    fi
    # Deliberately no $PWD fallback. A hook's working directory is whatever the
    # front end happened to leave it at, not a statement about which session is
    # open, so resolving from it would bind a hook to a session nobody asked
    # for — including any tool run from inside a session checkout.
    [ -n "$start" ] || return 1
    [ -d "$start" ] || return 1

    dir=$(_cs_find_session_root "$start") || return 1
    [ -n "$dir" ] || return 1
    _cs_session_is_registered "$dir" || return 1
    _cs_session_is_enabled "$dir" || return 1

    name=$(_cs_session_name "$dir")

    CLAUDE_SESSION_DIR="$dir"
    CLAUDE_SESSION_META_DIR="$dir/.cs"
    CLAUDE_SESSION_NAME="$name"
    # Which path resolved matters downstream: only a cs launch owns the
    # session lock, so a hook that got here by walking must not remove it.
    CS_RESOLVED_FROM=walk
    export CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_SESSION_NAME CS_RESOLVED_FROM
    _cs_note_tracked_files
    return 0
}

# A pull, a merge or a checkout puts committed files into a session that is
# already open, where none of the open's refusals run again. So each hook asks
# once, as it resolves its session, whether git tracks anything in the
# directory that holds the queue, the mailbox and the rotation marker. While
# it does, cs_private_dir (cs-shared.sh) fails for this session and every
# reader and writer of those files stands down; the Stop hook shows the
# notice. Not exported: the answer is this hook run's, asked again by the next,
# and cs-shared.sh drops an inherited one as it loads. A hook that sources no
# cs-shared.sh reads none of those files.
#
# The status line cannot ask git on every render, so the answer is also left
# for it as a mark, ~/.cache/cs/tracked/<session name>, present while git
# tracks the files and removed by the first run that finds them untracked.
# Keyed by name because the status line knows a session only by name (it
# writes to $SESSIONS_ROOT/<name>/.cs/local); names are unique within one
# sessions root, so only two roots under one HOME holding the same name share
# a mark.
_cs_note_tracked_files() {
    command -v cs_files_tracked_notice >/dev/null 2>&1 || return 0
    local mark=""
    case "${CLAUDE_SESSION_NAME:-}" in
        ''|*/*) ;;
        *) [ -z "${HOME:-}" ] || mark="$HOME/.cache/cs/tracked/$CLAUDE_SESSION_NAME" ;;
    esac
    # shellcheck disable=SC2034  # read by cs_private_dir (cs-shared.sh) and the Stop hook
    if CS_TRACKED_FILES_NOTICE=$(cs_files_tracked_notice "$CLAUDE_SESSION_META_DIR" "$CLAUDE_SESSION_DIR"); then
        CS_TRACKED_FILES_META="$CLAUDE_SESSION_META_DIR"
        [ -z "$mark" ] || [ -e "$mark" ] || { mkdir -p "${mark%/*}" && : > "$mark"; } 2>/dev/null || true
    else
        [ -z "$mark" ] || [ ! -e "$mark" ] || rm -f "$mark" 2>/dev/null || true
    fi
    return 0
}

# Walk up looking for the .cs/ that marks a session root. The nearest one
# decides: a repository with its own .cs/ cloned inside a session is not that
# session's work, so the walk never passes it to bind the clone to the
# enclosing session (the registry check on the nearest one declines instead).
# Stops at $HOME and at / so an unrelated .cs far up the tree cannot capture a
# stray folder.
_cs_find_session_root() {  # start_dir
    local d
    d=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    local home_p
    home_p=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P || printf '/nonexistent')
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        # Boundary before the marker test, so $HOME itself is never a session
        # root: a stray ~/.cs would otherwise adopt every project directly under
        # home into a phantom session named after the home directory.
        [ "$d" = "$home_p" ] && return 1
        if [ -d "$d/.cs" ]; then
            printf '%s\n' "$d"
            return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}

# Which claude is the conversation cs launched. cs exports CS_LEAD_PID, the pid
# it hands to claude, and Claude Code stamps CLAUDE_PID with the pid of
# whichever claude fires a hook. The exec arms replace cs with claude, so there
# the two are equal. The resume arm runs claude as cs's child, since it needs
# the exit status, and a CLAUDE_CODE_BIN that forks claude (`op run --`, a
# script without exec) puts claude below the launch pid on any arm. What the
# lead starts (a mod's process run, a `claude -p` from the Bash tool) is below
# the launch pid too, and inherits every export, so neither the environment
# nor the process tree tells the lead from its children.
#
# So the lead says so itself. Its SessionStart claims the launch in
# .cs/local/lead-pid as "<CS_LEAD_PID> <CLAUDE_PID> <session_id>"
# (cs_lead_claim). The lead's SessionStart runs before the lead can start
# anything, so the first claude under the launch to claim is the lead, and
# the claim holds while that claude lives. Every launch clears the file
# before claude starts (lib/75-launch.sh) and a claim keyed by another launch
# pid is ignored, so a claim cannot speak for a later launch. The lead's
# SessionEnd removes it with the lock (cs_lead_release).
#
# The claim counts only under a launch that clears the file and expects it:
# such a launch exports CS_LEAD_CLAIM=1. A session a cs from before the claim
# opened carries no marker and, open across an update of the hooks, no claim
# either, so the first `claude -p` its lead ran would claim it. Without the
# marker nothing is claimed or read, and the claude carrying the launch pid is
# the only lead. Every claude under the launch inherits the marker: it says
# the launch takes claims, never which claude is the lead.

# The claim for this launch: sets _CS_CLAIM_PID and returns 0, or returns 1
# when there is none. A pid that is not a plain number is no claim: kill -0
# reads -1 as every process the user owns.
_cs_lead_claim_read() {
    local launch="" pid=""
    _CS_CLAIM_PID=""
    [ "${CS_LEAD_CLAIM:-}" = 1 ] || return 1
    [ -n "${CLAUDE_SESSION_META_DIR:-}" ] && [ -n "${CS_LEAD_PID:-}" ] || return 1
    { read -r launch pid _ < "$CLAUDE_SESSION_META_DIR/local/lead-pid"; } 2>/dev/null || return 1
    [ "$launch" = "$CS_LEAD_PID" ] || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    _CS_CLAIM_PID="$pid"
}

# True when <ancestor> is <pid> or above it, by a walk up the parent pids ps
# reports. A ps that cannot answer ends the walk with false.
_cs_pid_descends_from() {  # pid ancestor
    local p="$1" i=0
    while [ "$i" -lt 16 ]; do
        [ "$p" = "$2" ] && return 0
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]') || return 1
        case "$p" in ''|*[!0-9]*) return 1 ;; esac
        [ "$p" -gt 1 ] || return 1
        i=$((i + 1))
    done
    return 1
}

# Called by session-start.sh on every source, with the directory the claim is
# written in (cs_local_dir's, so nothing is written while git tracks it) and
# the payload's session id. The claude carrying the launch pid always claims.
# Any other claude claims only from below the launch pid, and only while no
# live claude holds the claim or the holder is one it started: a claude the
# lead started before the lead's own SessionStart ran (another plugin's
# SessionStart hook running `claude -p`) got there first and gives way. The
# launch pid is above every claude under the launch, so a holder carrying it
# is never displaced. The read of the holder and the write are one step under
# the lock beside the file (lead-pid.mutex.lock): two claudes starting at once
# take turns, so the lead and a claude it started cannot both pass the read
# and the lead holds the claim whichever came first. Past the lock's wait the
# step runs without it, as the state file's does: a hook must not stall.
cs_lead_claim() {  # local_dir session_id
    [ "${CS_LEAD_CLAIM:-}" = 1 ] || return 1
    [ -n "$1" ] && [ -n "${CS_LEAD_PID:-}" ] && [ -n "${CLAUDE_PID:-}" ] || return 1
    if [ "$CLAUDE_PID" != "$CS_LEAD_PID" ]; then
        _cs_pid_descends_from "$CLAUDE_PID" "$CS_LEAD_PID" || return 1
    fi
    _cs_with_state_lock "$1/lead-pid" _cs_lead_claim_write "$1" "$2" || return 1
    _CS_IS_LEAD=""
}

# cs_lead_claim's step under the lock: gives way to a live holder that is not
# this claude's descendant, else writes the claim.
_cs_lead_claim_write() {  # local_dir session_id
    if [ "$CLAUDE_PID" != "$CS_LEAD_PID" ] && _cs_lead_claim_read \
        && [ "$_CS_CLAIM_PID" != "$CLAUDE_PID" ] && kill -0 "$_CS_CLAIM_PID" 2>/dev/null; then
        _cs_pid_descends_from "$_CS_CLAIM_PID" "$CLAUDE_PID" || return 1
    fi
    cs_write_atomic "$1/lead-pid" printf '%s %s %s\n' "$CS_LEAD_PID" "$CLAUDE_PID" "$2"
}

# Removes the claim when it names this claude, so an ending claude never takes
# another's. session-end.sh calls it where it removes the launch's lock.
cs_lead_release() {  # local_dir
    [ -n "$1" ] || return 1
    _cs_lead_claim_read && [ "$_CS_CLAIM_PID" = "${CLAUDE_PID:-}" ] || return 1
    rm -f "$1/lead-pid"
}

# True when the claude a hook fires for is the lead: it carries the launch pid,
# or the claim for this launch names it. Anything else is not the lead: a tmux
# teammate (tmux starts it, and CS_LEAD_PID is absent from its environment), a
# `claude -p` run from inside the session, a front end that walked in from the
# directory. Both variables must be non-empty, not merely equal: unset on both
# sides compares equal. Memoized, so a hook that asks more than once gets one
# answer; cs_lead_claim drops the memo when it writes.
_CS_IS_LEAD=""
cs_is_lead() {
    if [ -z "$_CS_IS_LEAD" ]; then
        _CS_IS_LEAD=0
        if [ -n "${CS_LEAD_PID:-}" ] && [ -n "${CLAUDE_PID:-}" ]; then
            if [ "$CLAUDE_PID" = "$CS_LEAD_PID" ]; then
                _CS_IS_LEAD=1
            elif _cs_lead_claim_read && [ "$_CS_CLAIM_PID" = "$CLAUDE_PID" ]; then
                _CS_IS_LEAD=1
            fi
        fi
    fi
    [ "$_CS_IS_LEAD" = 1 ]
}

# True for a claude started from inside a cs session that is not the lead: a
# `claude -p` the lead's Bash tool ran, a plugin, a script. It inherits the
# exported contract (CS_LEAD_PID among it) so its hooks resolve from the env,
# yet its pid is not the launch and the claim does not name it. Only the
# contract's presence makes this judgement: a front end that walked in, or a
# session cs did not launch, carries no CS_LEAD_PID and is not a nested child.
cs_is_nested_child() {
    [ -n "${CS_LEAD_PID:-}" ] && [ -n "${CLAUDE_PID:-}" ] || return 1
    ! cs_is_lead
}

# True when a live claude other than this one holds the claim: the claude is
# shown to be a guest, where cs_is_nested_child only fails to show it is the
# lead. The two differ where no claim stands (the lead's SessionStart could not
# write one, ps could not show it was under the launch, or the launch takes no
# claim, so no claude under it is shown a guest), and each caller
# takes the side that loses nothing. What a guest must not take from the lead
# (the armed rotation, the once-only digest, the attention flag) asks this
# one, so a lead with no claim keeps them. What a guest must not remove (the
# lock) asks cs_is_nested_child, so the same doubt leaves a live holder's lock.
cs_is_shown_nested_child() {
    cs_is_nested_child || return 1
    _cs_lead_claim_read && kill -0 "$_CS_CLAIM_PID" 2>/dev/null
}

# Claude Code launches an agent-team teammate with --agent-id, --agent-name and
# --team-name, and rejects the launch unless all three are given. All three are
# required here for that reason: one flag alone also matches a person asking
# what --agent-id does, whose prompt is in the argv of a claude that is not a
# teammate. CLAUDE_PID names the claude a hook is firing for, and a process that
# cannot be read cannot be shown to be a teammate: in a terminal that means the
# session was not entered through cs, which is the case for declining.
_cs_is_teammate() {
    local args=""
    [ -n "${CLAUDE_PID:-}" ] || return 1
    args=$(ps -o args= -p "$CLAUDE_PID" 2>/dev/null) || return 1
    [ -n "$args" ] || return 1
    # Padded on both sides so each match is the whole flag: --agent-idle-foo
    # shares a prefix with --agent-id and is not it.
    local flag
    for flag in --agent-id --agent-name --team-name; do
        case " $args " in
            *" $flag "*|*" $flag="*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# A session opts out of hook behaviour with .cs/local/disabled. Before this
# resolver a bare `claude` in a session dir was cs-blind; the marker restores
# that on request rather than by accident.
_cs_session_is_enabled() {  # session_dir
    [ -f "$1/.cs/local/disabled" ] && return 1
    return 0
}

# True when the sessions root knows this directory: an entry there IS it (a
# created session, a feature worktree, a vault) or links to it (an adopted
# session, at its own project path). Nothing inside the directory can prove
# it, because a cloned repository can carry any file under .cs/ and a hook
# never runs the checks `cs` runs at open; an entry under this machine's root
# is what a clone cannot carry. Identity is by inode, never by spelling: a
# case-insensitive filesystem keeps the typed case, and a home reached through
# a symlink spells the same directory two ways. CS_SESSIONS_ROOT is read when
# a front end passes it on, and the default root otherwise, as session-end.sh
# does for the index.
_cs_session_is_registered() {  # session_dir
    local root entry
    root="${CS_SESSIONS_ROOT:-${HOME:-/nonexistent}/.claude-sessions}"
    [ -d "$root" ] || return 1
    # A session cs created sits under its own name; one adopted under a chosen
    # name is a link, so every link is tried (dotted names included).
    [ "$root/$(basename "$1")" -ef "$1" ] && return 0
    for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        [ -L "$entry" ] || continue
        [ "$entry" -ef "$1" ] && return 0
    done
    return 1
}

# The name a session is known by is not always its basename: `cs -adopt` links
# a chosen name at an unrelated project path, and the link is invisible from the
# directory this walk arrives at. Adoption records the name in machine-local
# state, and opening an adopted session through cs rewrites it there, so a
# session adopted before cs wrote the key picks it up on its next open.
#
# Ordinary sessions record nothing: such a session IS its directory, so the
# basename is the answer, and a recorded name would outrank it while stale the
# moment the directory was renamed.
_cs_session_name() {  # session_dir
    local n=""
    if [ -f "$1/.cs/local/state" ]; then
        n=$(awk '/^session_name:/ { print $2; exit }' "$1/.cs/local/state" 2>/dev/null || true)
    fi
    [ -n "$n" ] || n=$(basename "$1")
    printf '%s\n' "$n"
}

# Terminate a JSONL file whose last line lost its newline to an interrupted
# write, so the next `>>` starts a fresh line instead of splicing two records
# onto one. The tolerant per-line reader (`fromjson? // empty` in
# run_conversations) drops a spliced line whole, losing the torn record AND the
# intact one appended after it. Shape shared with bin/cs's _terminate_jsonl —
# hooks cannot source bin/cs.
_cs_terminate_jsonl() {  # file
    [ -s "$1" ] || return 0
    [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] || return 0
    cs_append_inside "$1" printf '\n' || true
}
