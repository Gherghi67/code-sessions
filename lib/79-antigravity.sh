# ABOUTME: Launch a cs session in Google's Antigravity CLI (agy), at launch level.
# ABOUTME: Hands the session context over as an always-on workspace rule; reopens with --continue.

# agy reads workspace rules from .agents/rules/*.md at the root of the folder
# it runs in, and keeps one with `trigger: always_on` in every turn, as Claude
# keeps CLAUDE.local.md. cs rewrites this one at each launch and never
# replaces a file it did not write: the mark says it is cs's.
# _antigravity_rule_is_cs (lib/30-worktree.sh) and _session_agents_only_cs
# (lib/65-sessions.sh) spell both out too, for the retire and cs -rm.
CS_ANTIGRAVITY_RULE=".agents/rules/cs-session.md"
CS_ANTIGRAVITY_RULE_MARK="<!-- cs:antigravity-session-context -->"

# agy reopens a folder's latest conversation with --continue and names a
# conversation's id only on the terminal as it exits, so cs binds the folder's
# latest conversation rather than an id. The binding is the word that says so.
CS_ANTIGRAVITY_LATEST=latest

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
    # launch: agy starts in the session folder, and a reopen continues its
    # latest conversation there (--continue), which is not an exact resume.
    # startup_context, memory_index: the always-on rule carries the session's
    # facts and its memory index, rewritten at each launch.
    printf '%s\n' launch startup_context memory_index
}

_cs_antigravity_adapter_prepare_workspace() {  # session_dir, mode
    # The rule is written at launch, where its context is current.
    case "$2" in create|migrate_storage|migrate|worktree) return 0 ;; *) return 2 ;; esac
}

_cs_antigravity_adapter_launch() {
    _launch_antigravity_bound "$@"
}

# agy keeps its conversations under ~/.gemini/antigravity, outside an
# encrypted session's vault, so it opens none. main refuses before the
# pre-open asks for the vault's password; _launch_antigravity_bound, for any
# other caller.
_antigravity_encrypted_refusal() {  # session_name
    printf '%s is encrypted, and Antigravity keeps its conversations in %s, outside the vault. Open it under Claude: cs %s --engine claude\n' \
        "$1" "$HOME/.gemini/antigravity" "$1"
}

# The clone-local exclude keeps the rule out of git status, so it never
# dirties the project or blocks a feature's retirement. The entry is anchored
# at the session folder, which can sit below the checkout's root. A folder
# outside any checkout needs none.
_antigravity_exclude_rule() {  # session_dir
    local exclude prefix
    exclude=$(cd -- "$1" && git rev-parse --git-path info/exclude 2>/dev/null) || return 0
    prefix=$(cd -- "$1" && git rev-parse --show-prefix 2>/dev/null) || return 0
    [ -n "$exclude" ] || return 0
    # A folder name holding a glob character must match only itself.
    prefix=$(printf '%s' "$prefix" | sed 's/[][*?\\]/\\&/g')
    case "$exclude" in
        /*) ;;
        *) exclude="$1/$exclude" ;;
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
    local binding_file recorded response="" continue_arg="" actor

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
    if [ -n "$recorded" ] && [ "$recorded" != "$CS_ANTIGRAVITY_LATEST" ]; then
        _antigravity_launch_error "Invalid Antigravity binding in $binding_file: expected '$CS_ANTIGRAVITY_LATEST'. Repair or remove it, then reopen."
        return 1
    fi

    # A pending rotation handoff stays armed for the next Claude or Codex
    # launch: agy runs no cs hook that would take it.
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
            continue_arg=--continue
            ;;
        auto)
            [ -z "$recorded" ] || continue_arg=--continue
            if [ -n "$continue_arg" ] && cs_interactive; then
                printf 'Continue previous Antigravity conversation? [Y/n] '
                IFS= read -rsn1 response || { printf '\n'; return 130; }
                printf '\n'
                case "$response" in
                    $'\e') return 130 ;;
                    [nN]) continue_arg="" ;;
                esac
            fi
            ;;
    esac
    local -a CS_NATIVE_LAUNCH_ARGS
    _cs_native_launch_options antigravity || return 1
    _antigravity_flags_listed "$agy_bin" ${continue_arg:+"$continue_arg"} \
        ${CS_NATIVE_LAUNCH_ARGS[@]+"${CS_NATIVE_LAUNCH_ARGS[@]}"} || return 1

    cd -- "$session_dir" || return 1
    unset CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CLAUDE_PID
    unset CLAUDE_PROJECT_DIR CLAUDE_CODE_TASK_LIST_ID CLAUDE_CODE_ENABLE_TODO_TOOLS
    unset CLAUDE_CODE_ENABLE_FUNCTION_HOOKS CLAUDE_CODE_AUTO_MEMORY_PATH
    unset CLAUDE_COWORK_MEMORY_PATH_OVERRIDE
    actor=$(cs_actor_slug "$session_dir") || return 1
    _antigravity_exclude_rule "$session_dir" \
        || warn "could not add $CS_ANTIGRAVITY_RULE to the checkout's info/exclude; git status will list it"
    _antigravity_write_rule "$session_name" "$session_dir" "$actor" "$CS_BIN" || return 1
    if [ -z "$recorded" ]; then
        cs_run_with_lease "$meta_dir" cs_binding_write "$session_dir" antigravity "$CS_ANTIGRAVITY_LATEST" || {
            _antigravity_launch_error "Could not save the Antigravity binding: $binding_file"
            return 1
        }
    fi
    # Recorded before agy starts, as Codex does, so cs commands run inside it
    # (cs -doctor, the picker) see the engine the session now runs under.
    cs_run_with_lease "$meta_dir" _cs_set_local_state_unlocked "$meta_dir/local/state" engine antigravity || {
        _antigravity_launch_error "Could not record the session's engine in $meta_dir/local/state"
        return 1
    }

    printf '%s\n' "Antigravity via cs: session context is on ($CS_ANTIGRAVITY_RULE), and a reopen continues agy's latest conversation in this folder. Rotation, mail, the task queue and automatic recovery are not available under Antigravity yet."
    local status=0
    cs_run_child "$agy_bin" ${continue_arg:+"$continue_arg"} ${CS_NATIVE_LAUNCH_ARGS[@]+"${CS_NATIVE_LAUNCH_ARGS[@]}"} || status=$?
    return "$status"
}
