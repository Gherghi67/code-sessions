# ABOUTME: Launch a cs session in Google's Antigravity CLI (agy), and the hook agy runs from cs's plugin.
# ABOUTME: Context goes over as an always-on rule; the hook binds the conversation a reopen resumes by id.

# agy reads workspace rules from .agents/rules/*.md at the root of the folder
# it runs in, and keeps one with `trigger: always_on` in every turn, as Claude
# keeps CLAUDE.local.md. cs rewrites this one at each launch and never
# replaces a file it did not write: the mark says it is cs's.
# _antigravity_rule_is_cs (lib/30-worktree.sh) and _session_agents_only_cs
# (lib/65-sessions.sh) spell both out too, for the retire and cs -rm.
CS_ANTIGRAVITY_RULE=".agents/rules/cs-session.md"
CS_ANTIGRAVITY_RULE_MARK="<!-- cs:antigravity-session-context -->"

# The binding is the id of the conversation a reopen resumes with
# --conversation, which cs's hook records once the conversation reaches the
# model (cs -antigravity-hook, below). Before the hook, cs bound the folder's
# latest conversation and reopened it with --continue, which falls back to a
# parent or child folder's conversation when this folder has none; a binding
# that still says latest reopens that way until the hook replaces it.
CS_ANTIGRAVITY_LATEST=latest

# A binding cs may pass to agy: the legacy word, or a UUID. The binding lies in
# the session folder, which the agent can write, so it is checked every time.
_antigravity_binding_valid() {  # binding
    [ "$1" = "$CS_ANTIGRAVITY_LATEST" ] || _is_uuid "$1"
}

_antigravity_launch_error() {  # message
    printf 'Error: %s\n' "$1" >&2
    return 1
}

_cs_antigravity_adapter_dependencies() {
    command -v "${AGY_BIN:-agy}" >/dev/null 2>&1 \
        || printf '%s\n' 'agy (install: curl -fsSL https://antigravity.google/cli/install.sh | bash)'
    # The memory index the rule carries is read with Python (cs_memory_index).
    command -v python3 >/dev/null 2>&1 || printf '%s\n' python3
    return 0
}

_cs_antigravity_adapter_capabilities() {
    # launch: agy starts in the session folder. exact_resume: the hook binds
    # the conversation by id and a reopen passes --conversation <id>.
    # startup_context, memory_index: the always-on rule carries the session's
    # facts and its memory index, rewritten at each launch.
    # recovery_autosave: the hook hands write_file and edit_file to recovery.
    printf '%s\n' launch exact_resume startup_context recovery_autosave memory_index
}

_cs_antigravity_adapter_prepare_workspace() {  # session_dir, mode
    # The rule is written at launch, where its context is current.
    case "$2" in create|migrate_storage|migrate|worktree) return 0 ;; *) return 2 ;; esac
}

_cs_antigravity_adapter_launch() {
    _launch_antigravity_bound "$@"
}

# agy keeps its conversations under ~/.gemini/antigravity-cli, outside an
# encrypted session's vault, so it opens none. main refuses before the
# pre-open asks for the vault's password; _launch_antigravity_bound, for any
# other caller.
_antigravity_encrypted_refusal() {  # session_name
    printf '%s is encrypted, and Antigravity keeps its conversations in %s, outside the vault. Open it under Claude: cs %s --engine claude\n' \
        "$1" "$HOME/.gemini/antigravity-cli" "$1"
}

# An absolute path with its . and .. levels folded by spelling alone. The
# links on it stay, so cs_append_inside still sees where a write would land.
_antigravity_fold_path() {  # absolute path
    local rest="${1#/}" part out=""
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
        case "$part" in
            ''|.) ;;
            ..) out="${out%/*}" ;;
            *) out="$out/$part" ;;
        esac
    done
    printf '%s\n' "${out:-/}"
}

# The clone-local exclude keeps the rule out of git status, so it never
# dirties the project or blocks a feature's retirement. The entry is anchored
# at the session folder, which can sit below the checkout's root. A folder
# outside any checkout needs none.
_antigravity_exclude_rule() {  # session_dir
    local exclude prefix session_p
    exclude=$(cd -- "$1" && git rev-parse --git-path info/exclude 2>/dev/null) || return 0
    prefix=$(cd -- "$1" && git rev-parse --show-prefix 2>/dev/null) || return 0
    [ -n "$exclude" ] || return 0
    # A folder name holding a glob character must match only itself.
    prefix=$(printf '%s' "$prefix" | sed 's/[][*?\\]/\\&/g')
    # Below the checkout's root git answers ../../.git/info/exclude, relative
    # to the physical folder it ran in. Spelled under the session, that path
    # would read as leaving it; folded, it names the checkout's own file.
    case "$exclude" in
        /*) ;;
        *)
            session_p=$(cd -P -- "$1" && pwd) || return 1
            exclude=$(_antigravity_fold_path "$session_p/$exclude")
            ;;
    esac
    _append_exclude_once "$exclude" "/$prefix$CS_ANTIGRAVITY_RULE"
}

_antigravity_emit_rule() {  # cs_bin; shared CS_CONTEXT_* fields are dynamically scoped
    printf -- '---\ntrigger: always_on\ndescription: cs session context, rewritten by cs at each launch\n---\n%s\n\n' \
        "$CS_ANTIGRAVITY_RULE_MARK"
    cs_emit_engine_context "$@"
}

# A link anywhere on the rule's path could carry the write out of the session,
# and a rule without cs's mark is the user's: both refuse, naming the fix.
_antigravity_write_rule() {  # session_name, session_dir, actor, cs_bin
    local session_dir="$2" rule="$2/$CS_ANTIGRAVITY_RULE" link session_p tmp
    for link in "$session_dir/.agents" "$session_dir/.agents/rules" "$rule"; do
        if [ -L "$link" ]; then
            _antigravity_launch_error "$link is a link; cs writes the Antigravity session rule only into a folder of the session's own. Replace the link with a folder, then reopen."
            return 1
        fi
    done
    if [ -e "$rule" ] && ! _antigravity_rule_is_cs "$session_dir"; then
        _antigravity_launch_error "$rule was not written by cs, which keeps its Antigravity session context there. Move it aside, then reopen."
        return 1
    fi
    mkdir -p "${rule%/*}" || return 1
    # The checks above name paths, and a folder on the path swapped for a link
    # after them would carry the write out. The write runs from inside the
    # rules folder instead, entered by its physical path and checked to lie in
    # the session: the shell's working folder stays the one checked, whatever
    # the path names by then. The temporary file is built there under a name
    # agy does not load (no .md), and the rename brings the rule in whole.
    if ! (
        session_p=$(cd -P -- "$session_dir" && pwd) || exit 1
        cd -P -- "${rule%/*}" && [ "$(pwd)" = "$session_p/${CS_ANTIGRAVITY_RULE%/*}" ] || exit 1
        tmp=$(mktemp .cs-session.XXXXXX) || exit 1
        trap 'rm -f -- "$tmp"' EXIT
        cs_session_context "$1" "$session_dir" "$3" _antigravity_emit_rule "$4" > "$tmp" \
            && mv -f -- "$tmp" "${rule##*/}"
    ); then
        _antigravity_launch_error "Could not write the Antigravity session rule: $rule"
        return 1
    fi
}

# agy stops with its usage on a flag it does not know, by then after cs has
# written the rule and recorded the engine, so each flag this launch passes
# must be one its --help lists.
_antigravity_flags_listed() {  # agy_bin, args...
    local agy_bin="$1" help arg
    shift
    [ "$#" -gt 0 ] || return 0
    help=$("$agy_bin" --help 2>/dev/null) || help=""
    for arg in "$@"; do
        case "$arg" in --*) ;; *) continue ;; esac
        printf '%s\n' "$help" | grep -E -- "^[[:space:]]*$arg([[:space:]]|$)" >/dev/null || {
            _antigravity_launch_error "The Antigravity CLI at $agy_bin does not list $arg in its --help, and this launch passes it. Update it (agy update), or launch without the option that adds $arg."
            return 1
        }
    done
}

_launch_antigravity_bound() {  # session_name, session_dir, is_new, force, merge, intent, remote_mode
    local session_name="$1" session_dir="$2" intent="${6:-auto}"
    local meta_dir="$session_dir/.cs" agy_bin="${AGY_BIN:-agy}"
    local binding_file recorded reopen response="" actor run_dir
    local -a reopen_args=()

    [ -d "$session_dir" ] || {
        _antigravity_launch_error "Session directory does not exist: $session_dir"
        return 1
    }
    if _switch_session_encrypted "$session_dir"; then
        _antigravity_launch_error "$(_antigravity_encrypted_refusal "$session_name")"
        return 1
    fi
    # Both paths are made absolute before the launch changes into the
    # session folder, where a relative one would name another file.
    agy_bin=$(command -v "$agy_bin" 2>/dev/null) || {
        _antigravity_launch_error "Antigravity CLI not found: ${AGY_BIN:-agy}. Install it with: curl -fsSL https://antigravity.google/cli/install.sh | bash (or set AGY_BIN to its path)."
        return 1
    }
    case "$agy_bin" in
        /*) ;;
        *) agy_bin="$(cd -- "$(dirname "$agy_bin")" && pwd -P)/$(basename "$agy_bin")" || return 1 ;;
    esac
    [ -f "$agy_bin" ] && [ -x "$agy_bin" ] || {
        _antigravity_launch_error "Antigravity CLI is not an executable file: $agy_bin"
        return 1
    }
    CS_BIN=$(cs_running_binary) || {
        _antigravity_launch_error "Cannot resolve the cs executable for this session."
        return 1
    }
    export CS_BIN
    binding_file="$meta_dir/local/$(_cs_binding_file antigravity)"
    recorded=$(cs_binding_read "$session_dir" antigravity) || {
        _antigravity_launch_error "Cannot read the Antigravity binding: $binding_file. Repair or remove it, then reopen."
        return 1
    }
    if [ -n "$recorded" ] && ! _antigravity_binding_valid "$recorded"; then
        _antigravity_launch_error "Invalid Antigravity binding in $binding_file: expected a conversation id (a UUID). Repair or remove it, then reopen."
        return 1
    fi
    reopen="$recorded"

    # A pending rotation handoff stays armed for the next Claude or Codex
    # launch: no cs hook takes one under agy yet.
    case "$intent" in
        handoff)
            _antigravity_launch_error "Antigravity cannot start from a rotation handoff yet. Continue from it under Claude: cs $session_name --engine claude --from-handoff"
            return 1
            ;;
        resume)
            [ -n "$recorded" ] || {
                _antigravity_launch_error "Cannot resume: no recorded Antigravity conversation. Use --fresh."
                return 1
            }
            ;;
        auto)
            if [ -n "$recorded" ] && cs_interactive; then
                printf 'Continue previous Antigravity conversation? [Y/n] '
                IFS= read -rsn1 response || { printf '\n'; return 130; }
                printf '\n'
                case "$response" in
                    $'\e') return 130 ;;
                    [nN]) reopen="" ;;
                esac
            fi
            ;;
        fresh) reopen="" ;;
    esac
    case "$reopen" in
        '') ;;
        "$CS_ANTIGRAVITY_LATEST") reopen_args=(--continue) ;;
        *) reopen_args=(--conversation "$reopen") ;;
    esac
    local -a CS_NATIVE_LAUNCH_ARGS
    _cs_native_launch_options antigravity || return 1
    _antigravity_flags_listed "$agy_bin" ${reopen_args[@]+"${reopen_args[@]}"} \
        ${CS_NATIVE_LAUNCH_ARGS[@]+"${CS_NATIVE_LAUNCH_ARGS[@]}"} || return 1

    cd -- "$session_dir" || return 1
    cs_unset_claude_env
    actor=$(cs_actor_slug "$session_dir") || return 1
    # The rule first: a launch refused over a rule of the user's adds no
    # exclude entry, which would have git ignore their file on cs's say-so.
    _antigravity_write_rule "$session_name" "$session_dir" "$actor" "$CS_BIN" || return 1
    _antigravity_exclude_rule "$session_dir" \
        || warn "could not add $CS_ANTIGRAVITY_RULE to the checkout's info/exclude; git status will list it"
    # Recorded before agy starts, as Codex does, so cs commands run inside it
    # (cs -doctor, the picker) see the engine the session now runs under.
    cs_run_with_lease "$meta_dir" _cs_set_local_state_unlocked "$meta_dir/local/state" engine antigravity || {
        _antigravity_launch_error "Could not record the session's engine in $meta_dir/local/state"
        return 1
    }

    # A seed cs -spawn staged under Claude or Codex, whose window died before
    # it launched, stays staged: agy takes no prompt to start it with.
    [ ! -f "${SESSIONS_ROOT:-}/.spawn/$session_name.seed" ] \
        || warn "A spawn seed is staged for $session_name; it stays staged for the next Claude or Codex open (cs $session_name --engine claude), since Antigravity takes no brief yet."
    # The binding comes from cs's hook, not from here: a run that ends before
    # its conversation reaches the model leaves the binding as it was, so the
    # next open never continues a conversation of another folder.
    local reopens="a reopen resumes this conversation, and edits are autosaved for recovery"
    if ! _antigravity_plugin_is_cs "$(_antigravity_plugin_dir)"; then
        warn "The cs hook for Antigravity is missing from $(_antigravity_plugin_dir): this run's conversation is not recorded for a reopen, and its edits are not autosaved. Run setup.sh again, with agy installed, to add it."
        reopens="the cs hook is missing"
    elif [ ! -r "$(_antigravity_plugin_dir)/scripts/autosave-commits.sh" ]; then
        warn "The cs hook for Antigravity has no recovery consumer in $(_antigravity_plugin_dir)/scripts: this run's edits are not autosaved. Run setup.sh again to add it."
        reopens="a reopen resumes this conversation; edits are not autosaved"
    fi
    # The hook remembers in this run's own directory, out of the session the
    # agent can write, which conversation the run works in; the run's cleanup
    # removes it.
    if run_dir=$(_antigravity_run_dir_prepare); then
        _cs_run_helper_dir=$run_dir
        if [ -n "$reopen" ]; then
            printf 'resume\n' > "$run_dir/opened" || true
        else
            printf 'fresh\n' > "$run_dir/opened" || true
        fi
    else
        warn "cs could not make a private directory under ${CS_CACHE_DIR:-$HOME/.cache/cs}/antigravity-runs: this run's conversation is recorded for a reopen only if the session has none yet."
    fi
    printf '%s\n' "Antigravity via cs: session context is on ($CS_ANTIGRAVITY_RULE), $reopens. Rotation, mail and the task queue are not available under Antigravity yet."
    local status=0
    cs_run_child "$agy_bin" ${reopen_args[@]+"${reopen_args[@]}"} ${CS_NATIVE_LAUNCH_ARGS[@]+"${CS_NATIVE_LAUNCH_ARGS[@]}"} || status=$?
    return "$status"
}

# The run's own directory: in cs's cache, not in the session the agent can
# write. The launch makes it 0700 before agy starts and says there whether the
# run opened a conversation or started one; the hook marks there the
# conversation the run works in and each one it has weighed.
_antigravity_run_dir() {
    _is_uuid "${CS_RUN_ID:-}" || return 1
    printf '%s/antigravity-runs/%s\n' "${CS_CACHE_DIR:-$HOME/.cache/cs}" "$CS_RUN_ID"
}

_antigravity_run_dir_ok() {  # run_dir
    [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ "$(_cs_perm_bits "$1")" = 700 ]
}

# A mark is made only where nothing stands yet, a link included (noclobber
# opens with O_EXCL), so a mark planted as a link never sends a write
# elsewhere.
_antigravity_run_mark() {  # file
    ( set -C; : > "$1" ) 2>/dev/null || true
}

# A directory already there is not this run's, and one the check refuses is
# taken back.
_antigravity_run_dir_prepare() {
    local dir
    dir=$(_antigravity_run_dir) || return 1
    ( umask 077 && mkdir -p "${dir%/*}" && mkdir -m 700 "$dir" ) 2>/dev/null || return 1
    _antigravity_run_dir_ok "$dir" || { rmdir "$dir" 2>/dev/null || true; return 1; }
    printf '%s\n' "$dir"
}

# The hook agy runs from cs's plugin (lib/01-manifests.sh), measured on agy
# 1.4.11: every hook gets the run's environment and a JSON payload on stdin
# whose conversationId names the conversation it ran in. PreInvocation fires
# before each model call, a resumed conversation's too, and PostToolUse after
# each tool; a run left before the model is called fires neither. agy reads
# the hook's stdout as JSON, so every path prints `{}`, which decides nothing,
# and exits 0: the hook never blocks or fails a turn. It acts only in the run
# cs launched; any other agy run passes through.
cmd_antigravity_hook() {  # event
    local handler input
    case "${1:-}" in
        pre-invocation) handler=_antigravity_hook_pre_invocation ;;
        post-tool-use) handler=_antigravity_hook_post_tool_use ;;
        *)
            if [ -t 0 ]; then
                printf 'Usage: cs -antigravity-hook pre-invocation|post-tool-use\n' >&2
                return 2
            fi
            handler=""
            ;;
    esac
    # Read whole first: agy writes the payload into a pipe, and a hook that
    # left before reading it could fail agy's write.
    input=$(cat 2>/dev/null) || input=""
    if [ -n "$handler" ] && [ "${CS_RUN_ENGINE:-}" = antigravity ] && [ -n "${CS_SESSION_DIR:-}" ] \
        && [ -d "$CS_SESSION_DIR/.cs/local" ]; then
        "$handler" "$input" </dev/null >/dev/null 2>&1 || true
    fi
    printf '{}\n'
    return 0
}

# The payload's conversation id, a UUID or nothing: it names a native file and
# goes onto agy's command line at the next reopen.
_antigravity_payload_id() {  # payload
    local id
    id=$(printf '%s' "$1" | jq -r 'if type == "object" then .conversationId // "" else "" end' 2>/dev/null) || return 1
    _is_uuid "$id" || return 1
    printf '%s\n' "$id"
}

# The first conversation to reach the model in a run is the one the run works
# in: the main conversation's model call comes before anything it starts, and
# a subagent's conversation has its own id. Each id is weighed once a run, so
# later model calls stop at a file test.
_antigravity_hook_pre_invocation() {  # payload
    local id run_dir meta="$CS_SESSION_DIR/.cs"
    id=$(_antigravity_payload_id "$1") || return 0
    run_dir=$(_antigravity_run_dir) && _antigravity_run_dir_ok "$run_dir" || run_dir=""
    [ -z "$run_dir" ] || [ ! -e "$run_dir/seen-$id" ] || return 0
    cs_run_lease_owned "$meta" || return 0
    cs_run_with_lease "$meta" _antigravity_hook_bind "$CS_SESSION_DIR" "$id" "$run_dir" || return 0
}

# Under the run lease. The session is bound to its run's first conversation,
# whichever it is: the one a reopen named, a new one, or one opened with
# /resume before the first turn. Later conversations of the run leave the
# binding alone. A run without its directory cannot tell first from later,
# and binds only a session that has no conversation yet (or the legacy word).
_antigravity_hook_bind() {  # session_dir, conversation_id, run_dir
    local session_dir="$1" id="$2" run_dir="$3" previous opened="" source=startup reason=fresh log_dir
    previous=$(cs_binding_read "$session_dir" antigravity) || return 1
    if [ -n "$run_dir" ]; then
        if [ -e "$run_dir/bound" ] || [ -L "$run_dir/bound" ]; then
            _antigravity_run_mark "$run_dir/seen-$id"
            return 0
        fi
        IFS= read -r opened < "$run_dir/opened" 2>/dev/null || opened=""
    elif [ "$previous" = "$id" ] || { [ -n "$previous" ] && [ "$previous" != "$CS_ANTIGRAVITY_LATEST" ]; }; then
        return 0
    fi
    [ "$opened" != resume ] || { source=resume; reason=rebind; }
    if [ "$previous" != "$id" ]; then
        cs_binding_write "$session_dir" antigravity "$id" || return 1
        _cs_set_local_state_unlocked "$session_dir/.cs/local/state" engine antigravity || return 1
        if log_dir=$(cs_private_dir "$session_dir/.cs"); then
            CS_WRITE_QUIET=1 cs_append_inside "$log_dir/session.log" printf '%s - Rebound antigravity conversation: %s -> %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "${previous:-none}" "$id" || true
        fi
        if _is_uuid "$previous"; then
            _timeline_rotated "$session_dir" "$previous" "$id" "$reason" "" antigravity || true
        fi
    fi
    # The rotate skill reads which conversations this checkout ran from this
    # line, as hooks/session-start.sh writes it for Claude.
    if log_dir=$(cs_private_dir "$session_dir/.cs"); then
        CS_WRITE_QUIET=1 cs_append_inside "$log_dir/session.log" printf '%s - Session started (source: %s, ID: %s)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$source" "$id" || true
    fi
    _timeline_started "$session_dir" antigravity "$id" "$source" || true
    [ -z "$run_dir" ] || { _antigravity_run_mark "$run_dir/bound"; _antigravity_run_mark "$run_dir/seen-$id"; }
}

# A finished edit in the run that holds the session's lease, translated by
# the adapter, goes to the recovery consumer the installer put beside the hook.
_antigravity_hook_post_tool_use() {  # payload
    local event script
    cs_run_lease_owned "$CS_SESSION_DIR/.cs" || return 0
    event=$(printf '%s' "$1" | cs_engine_call antigravity files_changed) || return 0
    [ -n "$event" ] || return 0
    script="$(_antigravity_plugin_dir)/scripts/autosave-commits.sh"
    [ -r "$script" ] || return 0
    printf '%s' "$event" | bash "$script" --event || true
}
