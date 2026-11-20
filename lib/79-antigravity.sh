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
# model (cs -antigravity-hook, below). Before the hook, cs wrote the word
# latest before agy started and reopened with --continue, which falls back to
# a parent or child folder's conversation when this folder has none. The word
# names no conversation, so an open of a binding that still says latest starts
# a new one, and the hook replaces the word with its id.
CS_ANTIGRAVITY_LATEST=latest

# A binding cs accepts: a UUID, or the legacy word, which names none. The
# binding lies in the session folder, which the agent can write, so it is
# checked every time.
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
    # rotation: exit and reopen with --from-handoff (or answer r). The launch
    # supplies an interactive prompt; PreInvocation binds and consumes it.
    # spawn_brief: the launch writes a seed's brief in and sends its kickoff
    # as the first prompt, once; agy hosts no walk-away task queue.
    # feature_finish: -finish sends a first prompt naming the finish skill's
    # SKILL.md, since agy hands a typed /cs:finish no folder.
    # mail_delivery: PreInvocation shows unread mail at each prompt, and Stop
    # wakes a turn that ends with mail which came while it ran.
    printf '%s\n' launch exact_resume startup_context recovery_autosave memory_index rotation engine_switch spawn_brief feature_finish mail_delivery
    # clear_rotation: /clear (or /new) carries an armed rotation into the new
    # conversation, which takes the binding. Claimed only inside a run whose
    # launch found it usable (_antigravity_clear_rebind_on), so the rotate
    # skill offers /clear only where it works.
    if _antigravity_clear_rebind_on; then
        printf '%s\n' clear_rotation
    fi
    # auto_clear: once a turn of the session's conversation ends with a
    # handoff armed and nothing left running, cs types /clear and go itself,
    # once for each handoff. Claimed only while this run's watcher lives
    # so the rotate skill promises the count only where cs will type.
    if _antigravity_autoclear_available_grace >/dev/null; then
        printf '%s\n' auto_clear
    fi
}

# The oldest agy on which invocationNum was measured going back to 0 at each
# prompt typed into one interactive run, which the mail at each prompt stands
# on: 1.5.9, on 2026-11-15. 1.5.8 was measured headless only (2026-11-14),
# where each turn is a process of its own and the reset proves nothing.
# shellcheck disable=SC2034  # read by cs -doctor in lib/60-doctor.sh
CS_ANTIGRAVITY_MAIL_MIN_VERSION=1.5.9

# The oldest agy on which a conversation /clear or /new started was measured
# apart from a subagent's, which the /clear rebind stands on: 1.5.10, on
# 2026-11-17, in one interactive run. A subagent's hooks carried
# lastUserInput "" at every event and initialNumSteps 0 at its first model
# call; every main conversation's carried the prompt typed into it.
CS_ANTIGRAVITY_CLEAR_MIN_VERSION=1.5.10

# The installed agy's version: the first run of three dot-separated numbers
# its --version prints (1.5.9 prints the number alone). Fails when agy exits
# with an error or names no version, so doctor can say it cannot tell. A
# launch names the binary it resolved; doctor asks AGY_BIN or the PATH's.
_antigravity_version() {  # [agy_bin]
    local out
    out=$("${1:-${AGY_BIN:-agy}}" --version 2>&1) || return 1
    [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# cs's skills ship inside its agy plugin, which offers them as /cs:<name>.
# The installer deploys them only into a plugin that is cs's, through a
# skills/ folder of its own; a folder there that is not holds none of them.
_cs_antigravity_adapter_skill_dir() {
    local dir
    dir=$(_antigravity_plugin_dir)
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        printf 'Error: cs'"'"'s Antigravity plugin is not installed at %s, so none of its skills are. Run setup.sh again, with agy installed, to add it.\n' "$dir" >&2
        return 1
    fi
    if ! _antigravity_plugin_is_cs "$dir" || ! _antigravity_plugin_subdir_ok "$dir/skills"; then
        printf 'Error: %s is not cs'"'"'s Antigravity plugin with a skills folder of its own, so cs installed no skills there. cs -doctor names the fix.\n' "$dir" >&2
        return 1
    fi
    printf '%s/skills\n' "$dir"
}

# The folder of cs's finish skill for a -finish open, once the open can
# work: the skill is installed in cs's plugin with the script it runs, and agy
# takes a first prompt. Without them the open would carry a prompt agy cannot
# act on. main asks before the open migrates, locks or unarchives the
# session; the launch asks again.
_antigravity_finish_dir() {
    local dir
    dir=$(cs_engine_skill_dir antigravity finish) || return 1
    [ ! -L "$dir/scripts" ] && [ ! -L "$dir/scripts/finish.sh" ] && [ -f "$dir/scripts/finish.sh" ] \
        && [ -x "$dir/scripts/finish.sh" ] || {
        _antigravity_launch_error "The cs finish skill for Antigravity in $dir has no runnable scripts/finish.sh, so -finish has nothing to start. Run setup.sh again, with agy installed, to restore it."
        return 1
    }
    _antigravity_flags_listed "${AGY_BIN:-agy}" --prompt-interactive || return 1
    printf '%s\n' "$dir"
}

# The first prompt of a -finish open. agy 1.5.2 handed a typed explicit-only
# skill its text and no folder (one measured run), so the prompt names the
# skill's own file and the invocation it stands for, and the skill reads its
# task from that, as it reads it from a typed message.
_antigravity_finish_kick() {  # feature, finish_skill_dir
    printf 'Finish the feature %s with cs'"'"'s finish skill, as if the user had typed /cs:finish %s. Read %s/SKILL.md and follow it; its scripts are in %s/scripts/.\n' \
        "$1" "$1" "$2" "$2"
}

_cs_antigravity_adapter_prepare_workspace() {  # session_dir, mode
    # The rule is written at launch, where its context is current.
    case "$2" in create|migrate_storage|migrate|worktree) return 0 ;; *) return 2 ;; esac
}

_cs_antigravity_adapter_launch() {
    _launch_antigravity_bound "$@"
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
# must be one its --help lists. agy 1.5.5 prints that usage on stderr, with
# status 0, so both streams are read. The help is read once per agy binary in
# a process: it takes agy about 0.3 s, and a launch asks more than once.
_CS_AGY_HELP_BIN=""
_CS_AGY_HELP=""
_antigravity_flags_listed() {  # agy_bin, args...
    local agy_bin="$1" help arg
    shift
    [ "$#" -gt 0 ] || return 0
    if [ "$_CS_AGY_HELP_BIN" != "$agy_bin" ]; then
        _CS_AGY_HELP=$("$agy_bin" --help 2>&1) || _CS_AGY_HELP=""
        _CS_AGY_HELP_BIN=$agy_bin
    fi
    help=$_CS_AGY_HELP
    for arg in "$@"; do
        case "$arg" in --*) ;; *) continue ;; esac
        printf '%s\n' "$help" | grep -E -- "^[[:space:]]*$arg([[:space:]]|$)" >/dev/null || {
            _antigravity_launch_error "The Antigravity CLI at $agy_bin does not list $arg in its --help, and this launch passes it. Update it (agy update), or launch without the option that adds $arg."
            return 1
        }
    done
}

# Ownership lets the installer repair a partial plugin. Rotation instead
# needs an enabled PreInvocation command that can actually bind its consumer.
# With an event and its verb, the same check for that event's command.
_antigravity_rotation_hook_ready() {  # [event, verb, expected_cs]
    local dir commands command cs_path event="${1:-PreInvocation}" verb="${2:-pre-invocation}" expected_cs="${3:-}"
    dir=$(_antigravity_plugin_dir)
    _antigravity_plugin_is_cs "$dir" \
        && _antigravity_plugin_manifest_is_cs "$dir/plugin.json" || return 1
    if [ -f "$HOME/.gemini/config/config.json" ]; then
        jq -e --arg name "$CS_ANTIGRAVITY_PLUGIN" '.plugins[$name].enabled != false' \
            "$HOME/.gemini/config/config.json" >/dev/null 2>&1 || return 1
    fi
    commands=$(jq -er --arg name "$CS_ANTIGRAVITY_HOOK_NAME" --arg event "$event" --arg tail " -antigravity-hook $verb" --arg expected "$expected_cs" '
        .[$name][$event] | arrays | .[]
        | select(type == "object" and .enabled != false)
        | select($expected == "" or .matcher == null or .matcher == "*")
        | (.hooks // [.]) | arrays | .[]
        | select(type == "object" and .enabled != false and .type == "command")
        | .command | strings | select(endswith($tail))
    ' "$dir/hooks.json" 2>/dev/null) || return 1
    while IFS= read -r command; do
        cs_path=${command%" -antigravity-hook $verb"}
        case "$cs_path" in
            \'*\')
                cs_path=${cs_path#\'}
                cs_path=${cs_path%\'}
                cs_path=${cs_path//"'\\''"/\'}
                ;;
        esac
        # Accept only the installer's shell-word encoding, never evaluate a
        # hook command to find its path. This includes paths with quotes.
        [ "$(_antigravity_hook_command "$cs_path" "$verb")" = "$command" ] || continue
        case "$cs_path" in /*) ;; *) continue ;; esac
        [ -f "$cs_path" ] && [ -x "$cs_path" ] || continue
        { [ -z "$expected_cs" ] || [ "$cs_path" -ef "$expected_cs" ] || cmp -s "$cs_path" "$expected_cs"; } && return 0
    done < <(printf '%s\n' "$commands")
    return 1
}

# Whether a run may carry a rotation through /clear: an agy at least
# CS_ANTIGRAVITY_CLEAR_MIN_VERSION, whose payloads tell a conversation /clear
# started from a subagent's, and a plugin whose SessionStart, which marks a
# new conversation, and PreInvocation, which rebinds to it, can both run cs.
_antigravity_clear_rebind_usable() {  # agy_bin
    local version
    version=$(_antigravity_version "$1") && _version_at_least "$version" "$CS_ANTIGRAVITY_CLEAR_MIN_VERSION" || return 1
    _antigravity_rotation_hook_ready && _antigravity_rotation_hook_ready SessionStart session-start
}

_antigravity_autoclear_hooks_ready() {  # cs_bin
    # Stop arms the watcher. Each of these events also cancels a count or
    # typing, so all four must run a cs build that knows this protocol.
    _antigravity_rotation_hook_ready SessionStart session-start "$1" &&
        _antigravity_rotation_hook_ready PreInvocation pre-invocation "$1" &&
        _antigravity_rotation_hook_ready PostToolUse post-tool-use "$1" &&
        _antigravity_rotation_hook_ready Stop stop "$1"
}

# Whether this run's launch found the /clear rebind usable and said so in the
# run's directory.
_antigravity_clear_rebind_on() {
    local run_dir
    run_dir=$(_antigravity_run_dir) && _antigravity_run_dir_ok "$run_dir" || return 1
    [ -f "$run_dir/clear-rebind" ] && [ ! -L "$run_dir/clear-rebind" ]
}

# cs's status line under agy is bin/cs-statusline-agy, which runs
# cs-statusline on agy's payload. A launch hands it to agy through --settings,
# which holds for that run only and is never saved, so agy's settings.json is
# never written and nothing is left to take back. It stacks under agy's own
# line, which shows the model and mode that cs's line leaves out; the quota
# is cs's.
CS_ANTIGRAVITY_STATUSLINE=cs-statusline-agy

_antigravity_settings_file() {
    printf '%s\n' "$HOME/.gemini/antigravity-cli/settings.json"
}

_antigravity_statusline_path() {
    printf '%s/%s\n' "${CS_INSTALL_DIR:-$HOME/.local/bin}" "$CS_ANTIGRAVITY_STATUSLINE"
}

# Whether a launch passes cs's status line, in _AGY_STATUSLINE: on, or the
# reason it does not. off: cs -statusline disable turned it off
# (_statusline_antigravity_off_marker); a no to the installer's question about
# Claude Code's bar does not. disabled: CS_STATUSLINE_DISABLE. missing: the adapter, or cs-statusline beside it, is
# not installed. no-jq: both need jq. own: agy's settings.json names a status
# line, which is the user's, and a setting for the run would cover it.
# unreadable: that file is not a JSON object, so cs cannot tell. Whether agy
# takes --settings is the launch's question (_antigravity_flags_listed).
_antigravity_statusline_state() {
    local bin settings
    bin=$(_antigravity_statusline_path)
    settings=$(_antigravity_settings_file)
    if [ -e "$(_statusline_antigravity_off_marker)" ]; then
        _AGY_STATUSLINE=off
    elif [ "${CS_STATUSLINE_DISABLE:-}" = 1 ]; then
        _AGY_STATUSLINE=disabled
    elif ! command -v jq >/dev/null 2>&1; then
        _AGY_STATUSLINE=no-jq
    elif [ -e "$settings" ] || [ -L "$settings" ]; then
        if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
            _AGY_STATUSLINE=unreadable
        elif jq -e '.statusLine != null' "$settings" >/dev/null 2>&1; then
            _AGY_STATUSLINE=own
        else
            _AGY_STATUSLINE=on
        fi
    else
        _AGY_STATUSLINE=on
    fi
    # Only a line cs would pass needs the adapter. agy resolves its command
    # after entering the session, where a relative path could name the
    # agent's executable instead of the one checked here.
    if [ "$_AGY_STATUSLINE" = on ] && { [[ "$bin" != /* ]] \
        || ! { [ -f "$bin" ] && [ -x "$bin" ] && [ -f "${bin%/*}/cs-statusline" ] && [ -x "${bin%/*}/cs-statusline" ]; }; }; then
        _AGY_STATUSLINE=missing
    fi
}

# The --settings value that gives a run cs's status line.
_antigravity_statusline_settings() {
    jq -cn --arg command "$(_cs_hook_shell_word "$(_antigravity_statusline_path)")" \
        '{statusLine: {command: $command, stack_with_default: true}}'
}

_launch_antigravity_bound() {  # session_name, session_dir, is_new, force, merge, intent, remote_mode
    local session_name="$1" session_dir="$2" merge_feature="${5:-}" intent="${6:-auto}"
    local finish_dir="" merge_kick=""
    local meta_dir="$session_dir/.cs" agy_bin="${AGY_BIN:-agy}"
    local binding_file recorded reopen response="" actor run_dir=""
    local pending_handoff rotation_handoff="" rotation_origin="" prompt="" receipt_dir
    local requested="${_cs_agy_resume_id:-}"
    local -a reopen_args=() prompt_args=()

    [ -d "$session_dir" ] || {
        _antigravity_launch_error "Session directory does not exist: $session_dir"
        return 1
    }
    # A vault home inherited from another encrypted session's launch is never
    # this session's (lib/76-codex-vault.sh, lib/79-antigravity-vault.sh); a
    # codex or agy the agent starts gets the shell's.
    _codex_drop_inherited_vault_home
    _antigravity_drop_inherited_vault_home || {
        _antigravity_launch_error "HOME is an encrypted session's Antigravity home, with no home of yours beside it; open this session from a shell whose HOME is your own."
        return 1
    }
    # An encrypted session runs agy on a home inside its vault, made below once
    # nothing else refuses; shared_home is the one it links back to.
    local vault_home="" vault_id shared_home="$HOME" rule_shown="$CS_ANTIGRAVITY_RULE"
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
    if [ -n "$requested" ] && ! _antigravity_rotation_hook_ready PreInvocation pre-invocation "$CS_BIN"; then
        _antigravity_launch_error "--resume-conversation requires the cs Antigravity binding hook. Enable the cs plugin and run setup.sh again."
        return 1
    fi
    if _switch_session_encrypted "$session_dir" && ! {
        _antigravity_rotation_hook_ready PreInvocation pre-invocation "$CS_BIN" &&
            _antigravity_rotation_hook_ready PostToolUse post-tool-use "$CS_BIN"
    }; then
        _antigravity_launch_error "Encrypted Antigravity requires working PreInvocation and PostToolUse hooks from this cs build. Enable the cs plugin and run setup.sh again to register both."
        return 1
    fi
    # -finish starts agy on the finish skill's own file. main has refused
    # already when that cannot work; this is the check for any other caller.
    if [ -n "$merge_feature" ]; then
        finish_dir=$(_antigravity_finish_dir) || return 1
    fi
    cs_run_with_lease "$meta_dir" _launch_handoff_recover "$session_dir" antigravity || {
        _antigravity_launch_error "An Antigravity handoff attempt needs recovery. Repair writable state and reopen with --resume. If no consumer was recorded, inspect native agy history before repairing $(_launch_handoff_receipt_dir "$session_dir" antigravity)/intent.json; do not replay it with --from-handoff."
        return 1
    }
    binding_file="$meta_dir/local/$(_cs_binding_file antigravity)"
    recorded=$(cs_binding_read "$session_dir" antigravity) || {
        _antigravity_launch_error "Cannot read the Antigravity binding: $binding_file. Repair or remove it, then reopen."
        return 1
    }
    if [ -n "$recorded" ] && ! _antigravity_binding_valid "$recorded"; then
        _antigravity_launch_error "Invalid Antigravity binding in $binding_file: expected a conversation id (a UUID). Repair or remove it, then reopen."
        return 1
    fi
    # The legacy word may stand in a folder with no conversation of its own,
    # where --continue would open another folder's for the hook to bind by id.
    [ "$recorded" != "$CS_ANTIGRAVITY_LATEST" ] || recorded=""
    reopen="$recorded"

    pending_handoff=$(_pending_handoff_pick "$session_dir")
    case "$intent" in
        handoff)
            [ -n "$pending_handoff" ] || {
                _antigravity_launch_error "$(_switch_no_handoff_message "$session_name")"
                return 1
            }
            rotation_handoff=${pending_handoff##*/}
            rotation_origin=$(_switch_handoff_origin "$pending_handoff" "$session_dir")
            reopen=""
            ;;
        resume)
            if [ -n "$requested" ]; then
                reopen="$requested"
            elif [ -z "$recorded" ]; then
                _antigravity_launch_error "Cannot resume: no recorded Antigravity conversation. Use --fresh."
                return 1
            elif [ -n "${_cs_switch_resume:-}" ]; then
                rotation_handoff=$(_rotation_armed_handoff "$session_dir")
                [ -n "$rotation_handoff" ] || {
                    _antigravity_launch_error "No armed handoff to carry into the switched conversation."
                    return 1
                }
                pending_handoff="$(cs_handoff_dir "$meta_dir")/$rotation_handoff"
            else
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
            fi
            ;;
        auto)
            # Nobody sits at the spawn's own window to answer: its open
            # continues the conversation, as Enter would, with the kickoff.
            if { [ -n "$recorded" ] || [ -n "$pending_handoff" ]; } && cs_interactive \
                && ! _spawn_seed_is_owned "$session_name"; then
                if [ -n "$pending_handoff" ]; then
                    local origin=""
                    _handoff_is_local "$pending_handoff" "$session_dir" || origin=" (from another checkout)"
                    printf 'Rotation handoff pending: %s%s\n' "${pending_handoff##*/}" "$origin"
                    printf 'Continue previous Antigravity conversation? [Y/n/r=from handoff/d=discard] '
                else
                    printf 'Continue previous Antigravity conversation? [Y/n] '
                fi
                IFS= read -rsn1 response || { printf '\n'; return 130; }
                printf '\n'
                case "$response" in
                    $'\e') return 130 ;;
                    [nN]) reopen=""; _disarm_rotation_marker "$session_dir" "$pending_handoff" ;;
                    [rR])
                        if [ -n "$pending_handoff" ]; then
                            rotation_handoff=${pending_handoff##*/}
                            reopen=""
                        else
                            _disarm_rotation_marker "$session_dir"
                        fi
                        ;;
                    [dD])
                        _disarm_rotation_marker "$session_dir"
                        [ -z "$pending_handoff" ] || _handoff_set_status "$pending_handoff" discarded || return 1
                        ;;
                    *) _disarm_rotation_marker "$session_dir" "$pending_handoff" ;;
                esac
            else
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
            fi
            ;;
        fresh) reopen=""; _disarm_rotation_marker "$session_dir" "$pending_handoff" ;;
    esac
    if [ -n "$rotation_handoff" ]; then
        # A rotation requires the binding hook and a private run directory.
        # Ordinary launches can still work without either, with a warning.
        if ! _antigravity_rotation_hook_ready; then
            _antigravity_launch_error "The cs Antigravity hook is missing or disabled; enable the cs plugin or run setup.sh again. The handoff stays pending."
            return 1
        fi
        receipt_dir=$(_launch_handoff_receipt_dir "$session_dir" antigravity) \
            && cs_cache_dir_make_private "$receipt_dir" \
            && _launch_handoff_receipt_dir_ok "$receipt_dir" "$session_dir" || {
                _antigravity_launch_error "Cannot prepare private handoff receipts; the handoff stays pending."
                return 1
            }
        actor=$(cs_actor_slug "$session_dir") || return 1
        # The handoff is named where the conversation finds it: in the vault
        # (.cs/private/handoffs) for an encrypted session.
        if [ -n "${_cs_switch_resume:-}" ]; then
            prompt="This conversation resumes after the session ran under ${_cs_switched_from:-another engine}. Read $(_codex_handoffs_shown "$session_dir")/$rotation_handoff first: it carries the work done since you last ran here. Then continue from its next step."
        else
            prompt=$(_rotation_preamble "$rotation_handoff" "$actor" "$(_codex_handoffs_shown "$session_dir")") || return 1
        fi
        [ -z "$rotation_origin" ] || prompt="$rotation_origin
$prompt"
        prompt_args=(--prompt-interactive "$prompt")
        # r is the user choosing the handoff over the merge armed moments
        # earlier, as under Claude and Codex; the merge waits for its own launch.
        [ -z "$merge_feature" ] \
            || warn "Rotation handoff takes this launch; re-run: cs $session_name -finish $merge_feature"
    elif [ -n "$merge_feature" ]; then
        merge_kick=$(_antigravity_finish_kick "$merge_feature" "$finish_dir")
        prompt_args=(--prompt-interactive "$merge_kick")
    fi
    case "$reopen" in
        '') ;;
        *) reopen_args=(--conversation "$reopen") ;;
    esac
    local -a CS_NATIVE_LAUNCH_ARGS
    _cs_native_launch_options antigravity || return 1
    _antigravity_flags_listed "$agy_bin" ${reopen_args[@]+"${reopen_args[@]}"} \
        ${CS_NATIVE_LAUNCH_ARGS[@]+"${CS_NATIVE_LAUNCH_ARGS[@]}"} ${rotation_handoff:+--prompt-interactive} || return 1
    # cs's status line, for this run only. An agy without --settings, or any
    # reason _antigravity_statusline_state gives, starts with agy's own line;
    # cs -doctor says which.
    local -a statusline_args=()
    local statusline_json
    _antigravity_statusline_state
    if [ "$_AGY_STATUSLINE" = on ] && _antigravity_flags_listed "$agy_bin" --settings 2>/dev/null \
        && statusline_json=$(_antigravity_statusline_settings); then
        statusline_args=(--settings "$statusline_json")
    fi

    if _switch_session_encrypted "$session_dir"; then
        vault_home=$(_antigravity_vault_home_prepare "$session_dir" "$shared_home") || return 1
        rule_shown=".cs/private/antigravity-home/.gemini/GEMINI.md, in the vault"
    fi

    cd -- "$session_dir" || return 1
    cs_unset_claude_env
    actor=$(cs_actor_slug "$session_dir") || return 1
    if [ -n "$vault_home" ]; then
        # An encrypted session's context goes into the vault home as agy's
        # global rule. A workspace rule of cs's that a run before the
        # encryption left is that context in plaintext, and goes.
        _antigravity_drop_workspace_rule "$session_dir" || {
            _antigravity_launch_error "Could not safely remove plaintext Antigravity context from .agents/rules. Check for linked or inaccessible paths there, then reopen."
            return 1
        }
        _antigravity_write_vault_rule "$session_name" "$session_dir" "$actor" "$CS_BIN" "$vault_home" "$shared_home" || return 1
    else
        # The rule first: a launch refused over a rule of the user's adds no
        # exclude entry, which would have git ignore their file on cs's say-so.
        _antigravity_write_rule "$session_name" "$session_dir" "$actor" "$CS_BIN" || return 1
        _antigravity_exclude_rule "$session_dir" \
            || warn "could not add $CS_ANTIGRAVITY_RULE to the checkout's info/exclude; git status will list it"
    fi
    # Recorded before agy starts, as Codex does, so cs commands run inside it
    # (cs -doctor, the picker) see the engine the session now runs under.
    cs_run_with_lease "$meta_dir" _cs_set_local_state_unlocked "$meta_dir/local/state" engine antigravity || {
        _antigravity_launch_error "Could not record the session's engine in $meta_dir/local/state"
        return 1
    }

    # The binding comes from cs's hook, not from here: a run that ends before
    # its conversation reaches the model leaves the binding as it was, so the
    # next open never continues a conversation of another folder. A plugin
    # switched off in agy's config, or one whose PreInvocation cannot run cs,
    # binds nothing either, which the rotation preflight already knows.
    local reopens="a reopen resumes this conversation, and edits are autosaved for recovery" hooked=1
    if ! _antigravity_plugin_is_cs "$(_antigravity_plugin_dir)"; then
        warn "The cs hook for Antigravity is missing from $(_antigravity_plugin_dir): this run's conversation is not recorded for a reopen, and its edits are not autosaved. Run setup.sh again, with agy installed, to add it."
        reopens="the cs hook is missing"
        hooked=""
    elif ! _antigravity_rotation_hook_ready; then
        warn "The cs hook for Antigravity in $(_antigravity_plugin_dir) is switched off or cannot run cs: this run's conversation is not recorded for a reopen. cs -doctor names the fix."
        reopens="the cs hook is off"
        hooked=""
    elif [ ! -r "$(_antigravity_plugin_dir)/scripts/autosave-commits.sh" ]; then
        warn "The cs hook for Antigravity has no recovery consumer in $(_antigravity_plugin_dir)/scripts: this run's edits are not autosaved. Run setup.sh again to add it."
        reopens="a reopen resumes this conversation; edits are not autosaved"
    fi
    # The hook remembers in this run's own directory, out of the session the
    # agent can write, which conversation the run works in; the run's cleanup
    # removes it.
    local protected="$vault_home$requested"
    if run_dir=$(_antigravity_run_dir_prepare "${protected:+protected}" "$session_dir"); then
        _cs_run_helper_dir=$run_dir
        if [ -n "$requested" ] && ! (umask 077; set -C; printf '%s\n' "$requested" > "$run_dir/resume-conversation"); then
            _antigravity_launch_error "Could not record the selected Antigravity conversation."
            return 1
        fi
        if [ -n "$reopen" ]; then
            printf 'resume\n' > "$run_dir/opened" || true
        else
            printf 'fresh\n' > "$run_dir/opened" || true
        fi
        if [ -n "$rotation_handoff" ]; then
            printf '%s\n' "$rotation_handoff" > "$run_dir/handoff" || return 1
        fi
        # The hook checks both the physical path and its identity against
        # these launch records, stored outside the session.
        if [ -n "$vault_home" ]; then
            vault_id=$(cs_dir_identity "${vault_home%/*}") &&
                ( set -C; printf '%s\n' "$vault_home" "$vault_id" > "$run_dir/vault" ) 2>/dev/null || {
                _antigravity_launch_error "Cannot record the vault Antigravity home in this run's directory; cs does not run agy on it unchecked."
                return 1
            }
        fi
        # Whether /clear may move the session to the conversation it starts,
        # decided once for the run, as the version and the plugin stand now.
        if [ -n "$hooked" ] && _antigravity_clear_rebind_usable "$agy_bin"; then
            _antigravity_run_mark "$run_dir/clear-rebind"
        fi
    else
        if [ -n "$requested" ]; then
            _antigravity_launch_error "Cannot prepare a private Antigravity run directory for --resume-conversation."
            return 1
        fi
        if [ -n "$rotation_handoff" ]; then
            _antigravity_launch_error "Cannot prepare a private Antigravity run directory; the handoff stays pending."
            return 1
        fi
        if [ -n "$vault_home" ]; then
            _antigravity_launch_error "Cannot prepare a private Antigravity run directory under ${CS_CACHE_DIR:-$HOME/.cache/cs}/antigravity-runs; an encrypted session's hooks check its vault home from there, so cs does not start agy without it."
            return 1
        fi
        warn "cs could not make a private directory under ${CS_CACHE_DIR:-$HOME/.cache/cs}/antigravity-runs: this run's conversation is recorded for a reopen only if the session has none yet."
    fi
    # A seed cs -spawn staged: the shared consumer writes its brief into
    # .cs/brief.md and builds the kickoff, which goes in as agy's first
    # prompt. The seed is spent before agy starts, so the kickoff is sent at
    # most once: a run that ends before its first turn may still have done
    # work, which cs cannot tell (rotation treats a missing consumer the same
    # way), and the brief stays for the agent to read. agy takes one first
    # prompt, so a rotation handoff this open carries keeps the seed staged
    # for a later open, as does an agy that cannot take the prompt. A seed
    # with tasks waits for a Claude open, unoffered, since taking it here
    # could only fail.
    local spawn_kick="" spawn_wait=""
    if [ -n "${SESSIONS_ROOT:-}" ] && [ -f "$SESSIONS_ROOT/.spawn/$session_name.seed" ]; then
        if _spawn_seed_has_tasks "$SESSIONS_ROOT/.spawn/$session_name.seed"; then
            spawn_wait="it carries tasks and only Claude runs the walk-away queue (take it with: cs $session_name --engine claude)"
        elif [ -n "$rotation_handoff" ]; then
            spawn_wait="this open carries the rotation handoff"
        elif [ -n "$merge_kick" ]; then
            spawn_wait="this open carries -finish $merge_feature"
        elif ! _antigravity_flags_listed "$agy_bin" --prompt-interactive 2>/dev/null; then
            spawn_wait="the Antigravity CLI at $agy_bin does not list --prompt-interactive in its --help (update it: agy update)"
        else
            _spawn_prepare_launch "$session_name" "$session_dir"
            [ -z "$spawn_kick" ] || prompt_args=(--prompt-interactive "$spawn_kick")
        fi
        [ -z "$spawn_wait" ] \
            || warn "A spawn seed is staged for $session_name; it stays staged for a later open, since $spawn_wait."
    fi
    # The automatic /clear after a rotation: a watcher beside agy types
    # /clear and go once a turn ends with a handoff armed
    # (_antigravity_autoclear_arm). It runs only where the /clear route
    # works, the plugin uses this cs build for all four hooks, a terminal
    # takes simulated input, and this run's directory lies where the agent
    # cannot write. Otherwise the launch says why and /clear stays manual.
    # The launch stops it as soon as agy exits, and the run's cleanup removes
    # its directory (lib/16-lifecycle.sh).
    local autoclear="" refusal="" grace=""
    if [ -n "$run_dir" ] && [ -f "$run_dir/clear-rebind" ] && [ ! -L "$run_dir/clear-rebind" ] \
        && [ -t 0 ] && [ -t 1 ] && grace=$(_antigravity_autoclear_grace); then
        if ! _antigravity_autoclear_hooks_ready "$CS_BIN"; then
            refusal="the cs plugin needs enabled SessionStart, PreInvocation, PostToolUse, and Stop hooks from this cs build. Enable the hooks and run setup.sh again."
        elif ! _codex_run_dir_ok "$run_dir" "$session_dir" || ! _launch_handoff_receipt_dir_ok "$run_dir" "$session_dir"; then
            refusal="this run's directory under ${CS_CACHE_DIR:-$HOME/.cache/cs} lies where the agent can write (the session, /tmp or \$TMPDIR)"
        elif refusal=$(_codex_autoclear_probe); then
            _codex_autoclear_watch "$session_dir" "$run_dir" antigravity </dev/null >/dev/null 2>&1 &
            _cs_run_helper_pid=$!
            autoclear=1
        fi
        if [ -z "$autoclear" ]; then
            printf "${DIM:-}cs: no automatic /clear after a rotation: %s${NC:-}\n" "$refusal"
            _codex_autoclear_log "$session_dir" "Automatic /clear is off for this run: $refusal"
        fi
    fi
    # The line names the route this run takes, read from the mark itself:
    # _antigravity_run_mark swallows a failed write, and a run whose mark is
    # missing keeps the binding and the mail with its first conversation.
    if [ -n "$autoclear" ]; then
        printf '%s\n' "Antigravity via cs: session context is on ($rule_shown), $reopens. Rotate with /cs:rotate, and cs types /clear and go for you $grace s after that turn ends. The task queue is not available under Antigravity yet. A conversation started with /clear or /new takes over the session and its cs mail."
    elif [ -n "$run_dir" ] && [ -f "$run_dir/clear-rebind" ] && [ ! -L "$run_dir/clear-rebind" ]; then
        printf '%s\n' "Antigravity via cs: session context is on ($rule_shown), $reopens. Rotate with /cs:rotate, then /clear and send go. The task queue is not available under Antigravity yet. A conversation started with /clear or /new takes over the session and its cs mail."
    else
        printf '%s\n' "Antigravity via cs: session context is on ($rule_shown), $reopens. Rotate with /cs:rotate, then /exit and cs $session_name --from-handoff. The task queue is not available under Antigravity yet. A conversation started with /clear or /new gets no cs mail until you reopen the session."
    fi
    if [ -n "$rotation_handoff" ]; then
        cs_run_with_lease "$meta_dir" _launch_handoff_prepare "$session_dir" antigravity "$rotation_handoff" || {
            _antigravity_launch_error "Cannot record the Antigravity handoff attempt; the handoff stays pending."
            return 1
        }
    fi
    local status=0
    # An encrypted session's agy, and everything it starts, gets the vault
    # home as HOME, with the shell's beside it for cs to go back to (bin/cs's
    # header); nothing else in this shell changes.
    local -a home_args=()
    [ -z "$vault_home" ] || home_args=(env HOME="$vault_home" CS_ANTIGRAVITY_SHARED_HOME="$shared_home" CS_ANTIGRAVITY_VAULT_RUN="$CS_RUN_ID")
    cs_run_child ${home_args[@]+"${home_args[@]}"} "$agy_bin" ${reopen_args[@]+"${reopen_args[@]}"} ${CS_NATIVE_LAUNCH_ARGS[@]+"${CS_NATIVE_LAUNCH_ARGS[@]}"} \
        ${statusline_args[@]+"${statusline_args[@]}"} ${prompt_args[@]+"${prompt_args[@]}"} || status=$?
    # The watcher goes as soon as agy does, before anything else the run does
    # (a switch's relaunch would otherwise get its keys). Keys it typed just
    # before agy exited can wait unread in the terminal and would run in the
    # shell, so the input is flushed then, and only then: the flush would eat
    # ordinary type-ahead.
    _cs_run_end_helper
    if [ -n "$autoclear" ] && [ -e "$(_codex_keys_sent_file "$run_dir")" ]; then
        _codex_flush_input
    fi
    if [ -n "$rotation_handoff" ] && _handoff_is_unconsumed "$pending_handoff"; then
        warn "The Antigravity handoff attempt needs recovery. Reopen with: cs $session_name --resume. If no consumer was recorded, inspect native agy history first; do not replay with --from-handoff."
    fi
    # The hook marks the run bound at its first model call. Without the mark
    # the kickoff may not have arrived; it is not sent again either way. Any
    # entry, a dangling link included, is the mark, as the hook reads it.
    if [ -n "$spawn_kick" ] && [ -n "$hooked" ] && [ -n "$run_dir" ] \
        && [ ! -e "$run_dir/bound" ] && [ ! -L "$run_dir/bound" ]; then
        warn "cs saw no turn start in this run, so the spawn kickoff may not have reached Antigravity. It is not sent again; the brief stays in .cs/brief.md for the agent to read when you reopen: cs $session_name"
    elif [ -n "$spawn_kick" ] && [ -z "$hooked" ]; then
        warn "Without the cs hook this conversation was not recorded, so the next open starts a new conversation that knows nothing of the spawn. The brief stays in .cs/brief.md; point that conversation at it."
    fi
    return "$status"
}

# The run's own directory: in cs's cache, not in the session the agent can
# write. The launch makes it 0700 before agy starts and says there whether the
# run opened a conversation or started one; the hook marks there the
# conversation the run works in, each one it has weighed and each one that
# has held the session.
_antigravity_run_dir() {
    _is_uuid "${CS_RUN_ID:-}" || return 1
    printf '%s/antigravity-runs/%s\n' "${CS_CACHE_DIR:-$HOME/.cache/cs}" "$CS_RUN_ID"
}

_antigravity_run_dir_ok() {  # run_dir
    [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ "$(_cs_perm_bits "$1")" = 700 ]
}

# Until the selected conversation has bound, mail stays queued and only
# that conversation can claim the run. This record lives in the run cache.
_antigravity_explicit_resume_pending() {  # run_dir
    [ -n "$1" ] && { [ -e "$1/resume-conversation" ] || [ -L "$1/resume-conversation" ]; } \
        && { [ ! -f "$1/bound" ] || [ -L "$1/bound" ]; }
}

# A mark is made only where nothing stands yet, a link included (noclobber
# opens with O_EXCL), so a mark planted as a link never sends a write
# elsewhere.
_antigravity_run_mark() {  # file
    ( set -C; : > "$1" ) 2>/dev/null || true
}

# A directory already there is not this run's, and one the check refuses is
# taken back.
_antigravity_run_dir_prepare() {  # [protected, session_dir]
    local dir
    dir=$(_antigravity_run_dir) || return 1
    ( umask 077 && mkdir -p "${dir%/*}" && mkdir -m 700 "$dir" ) 2>/dev/null || return 1
    if ! _antigravity_run_dir_ok "$dir" || { [ -n "${1:-}" ] && ! _launch_handoff_receipt_dir_ok "$dir" "$2"; }; then
        rmdir "$dir" 2>/dev/null || true
        return 1
    fi
    printf '%s\n' "$dir"
}

# The hook agy runs from cs's plugin (lib/01-manifests.sh), measured on agy
# 1.4.11 and 1.5.8: every hook gets the run's environment and a JSON payload
# on stdin whose conversationId names the conversation it ran in.
# PreInvocation fires before each model call, a resumed conversation's too,
# PostToolUse after each tool, and Stop when the turn's loop ends; a run left
# before the model is called fires none of them. agy reads the hook's stdout
# as JSON: `{}` decides nothing, and it is the answer on every path but the
# two the mail takes (a digest injected at a prompt, a wake at a Stop). The
# hook always exits 0. PreInvocation can still stop a turn in its JSON reply.
# It acts only in the run cs
# launched; any other agy run passes through.
#
# A handler leaves its answer, one JSON object on one line, in
# ANTIGRAVITY_HOOK_REPLY, and in ANTIGRAVITY_HOOK_AFTER a function to run once
# the answer is out. The handler's own stdout goes nowhere, so nothing it runs
# can add to the answer or hold agy's pipe open.
cmd_antigravity_hook() {  # event
    local handler input run_dir
    local AGY_AUTOCLEAR_GENERATION=""
    # Shared mail and handoff helpers use this pin only within this hook.
    local _cs_private_pin_meta="" _cs_private_pin_dir=""
    ANTIGRAVITY_HOOK_REPLY=""
    ANTIGRAVITY_HOOK_AFTER=""
    case "${1:-}" in
        session-start) handler=_antigravity_hook_session_start ;;
        pre-invocation) handler=_antigravity_hook_pre_invocation ;;
        post-tool-use) handler=_antigravity_hook_post_tool_use ;;
        stop) handler=_antigravity_hook_stop ;;
        *)
            if [ -t 0 ]; then
                printf 'Usage: cs -antigravity-hook session-start|pre-invocation|post-tool-use|stop\n' >&2
                return 2
            fi
            handler=""
            ;;
    esac
    if [ -n "$handler" ] && [ "${CS_RUN_ENGINE:-}" = antigravity ] && [ -n "${CS_SESSION_DIR:-}" ]; then
        # Register before reading the payload. Even a malformed event
        # cancels the count and typing, and supersedes an overlapping Stop.
        AGY_AUTOCLEAR_GENERATION=$(_antigravity_autoclear_begin 2>/dev/null) || AGY_AUTOCLEAR_GENERATION=""
    fi
    # Always drain the pipe, even when this is not a managed run.
    input=$(cat 2>/dev/null) || input=""
    if [ -n "$handler" ] && [ "${CS_RUN_ENGINE:-}" = antigravity ] && [ -n "${CS_SESSION_DIR:-}" ]; then
        run_dir=$(_antigravity_run_dir) || run_dir=""
        if { [ -n "${CS_RUN_ID:-}" ] && [ "${CS_ANTIGRAVITY_VAULT_RUN:-}" = "$CS_RUN_ID" ]; } \
            || { [ -n "$run_dir" ] && { [ -e "$run_dir/vault" ] || [ -L "$run_dir/vault" ]; }; }; then
            if [ -n "$run_dir" ] && _cs_private_pin_dir=$(_antigravity_run_private_dir "$CS_SESSION_DIR" "$run_dir") \
                && _antigravity_run_vault_home "$run_dir" >/dev/null && cs_run_lease_owned "$CS_SESSION_DIR/.cs"; then
                _cs_private_pin_meta="$CS_SESSION_DIR/.cs"
            else
                if [ "$1" = pre-invocation ]; then
                    ANTIGRAVITY_HOOK_REPLY=$(_antigravity_hook_vault_error 'cs stopped this turn: the encrypted session vault or its run guard changed or became unavailable. Close and reopen the session to restore it.')
                fi
                handler=""
            fi
        fi
        if [ -n "$handler" ] && [ -d "$CS_SESSION_DIR/.cs/local" ]; then
            "$handler" "$input" </dev/null >/dev/null 2>&1 || true
        fi
    fi
    if [ -n "$ANTIGRAVITY_HOOK_REPLY" ]; then
        printf '%s\n' "$ANTIGRAVITY_HOOK_REPLY"
    else
        printf '{}\n'
    fi
    if [ -n "$ANTIGRAVITY_HOOK_AFTER" ]; then
        "$ANTIGRAVITY_HOOK_AFTER" </dev/null >/dev/null 2>&1 || true
    fi
    return 0
}

# The payload fields the handlers read, in one jq: AGY_HOOK_ID, the
# conversation id, a UUID or the read fails (it names a native file and goes
# onto agy's command line at the next reopen); AGY_HOOK_INVOCATION,
# PreInvocation's invocationNum when it is a whole number, else empty;
# AGY_HOOK_TERMINATION, Stop's terminationReason when it is a word, else
# empty; AGY_HOOK_STEPS, PreInvocation's initialNumSteps when it is a whole
# number, else empty; AGY_HOOK_TYPED, 1 when lastUserInput is a string
# that is not empty, else empty (the prompt itself is never kept); and
# AGY_HOOK_IDLE, 1 when Stop's fullyIdle is true, else empty (agy 1.5.12 sent
# false while a background command still ran).
_antigravity_payload_read() {  # payload
    local fields rest
    AGY_HOOK_ID="" AGY_HOOK_INVOCATION="" AGY_HOOK_TERMINATION="" AGY_HOOK_STEPS="" AGY_HOOK_TYPED="" AGY_HOOK_IDLE=""
    # Each field is kept only when every character in it is one its shape
    # allows, judged by what is left once those are deleted (a regex "$"
    # also matches before a newline), so none can carry the separator or a
    # second line; anything else reads as "".
    fields=$(printf '%s' "$1" | jq -r 'if type == "object" then
            [((.conversationId | strings | select(length == 36 and gsub("[0-9A-Fa-f-]"; "") == "")) // ""),
             ((.invocationNum | numbers | select(. >= 0 and . == floor and . < 1e9) | tostring) // ""),
             ((.terminationReason | strings | select(length <= 40 and gsub("[A-Z_]"; "") == "")) // ""),
             ((.initialNumSteps | numbers | select(. >= 0 and . == floor and . < 1e9) | tostring) // ""),
             (if (.lastUserInput | type) == "string" and (.lastUserInput | length) > 0 then "1" else "" end),
             (if .fullyIdle == true then "1" else "" end)]
            | join("|")
        else "" end' 2>/dev/null) || return 1
    # Split by expansion, not read with a here-document, which bash 3.2
    # writes to a temp file a sandbox may refuse.
    AGY_HOOK_ID=${fields%%"|"*}
    rest=${fields#*"|"}
    AGY_HOOK_INVOCATION=${rest%%"|"*}
    rest=${rest#*"|"}
    AGY_HOOK_TERMINATION=${rest%%"|"*}
    rest=${rest#*"|"}
    AGY_HOOK_STEPS=${rest%%"|"*}
    rest=${rest#*"|"}
    AGY_HOOK_TYPED=${rest%%"|"*}
    AGY_HOOK_IDLE=${rest#*"|"}
    if ! _is_uuid "$AGY_HOOK_ID"; then
        AGY_HOOK_ID="" AGY_HOOK_INVOCATION="" AGY_HOOK_TERMINATION="" AGY_HOOK_STEPS="" AGY_HOOK_TYPED="" AGY_HOOK_IDLE=""
        return 1
    fi
}

# A conversation the user started: one a prompt was typed into, agy's
# lastUserInput. Measured on agy 1.5.10 (2026-11-17): a subagent's
# conversation fires SessionStart, PreInvocation, PostToolUse,
# PostInvocation and Stop as a main one does, with an id of its own, but its
# lastUserInput was "" at every event, a follow-up turn its parent sent
# included, while a main conversation's (the run's first, one /clear or /new
# started, one /resume opened, a turn its own subagent's answer woke) always
# carried the prompt typed last.
_antigravity_hook_typed() {
    [ "$AGY_HOOK_TYPED" = 1 ]
}

# SessionStart fires once for each conversation agy starts: the run's first
# when the launch opened none, one /clear or /new started, and a subagent's;
# never for one opened with --conversation or /resume. Once the run has bound
# its conversation, a typed one is marked new in the run's directory, for
# PreInvocation to move the session to it (_antigravity_hook_bind). The mark
# is all this does: it never binds, and always answers {}.
_antigravity_hook_session_start() {  # payload
    local run_dir
    _antigravity_payload_read "$1" || return 0
    _antigravity_hook_typed || return 0
    run_dir=$(_antigravity_run_dir) && _antigravity_run_dir_ok "$run_dir" || return 0
    [ -f "$run_dir/clear-rebind" ] && [ ! -L "$run_dir/clear-rebind" ] || return 0
    [ -e "$run_dir/bound" ] || [ -L "$run_dir/bound" ] || return 0
    cs_run_lease_owned "$CS_SESSION_DIR/.cs" || return 0
    _antigravity_run_mark "$run_dir/new-$AGY_HOOK_ID"
}

# The first conversation to reach the model in a run is the one the run works
# in: the main conversation's model call comes before anything it starts, and
# a subagent's conversation has its own id. Each id is weighed at its first
# model call in the run, so later model calls stop at a file test. A later one
# takes the session only when /clear or /new started it
# (_antigravity_hook_rebind_clear), and its first model call is then handed
# the rotation armed for it. An id already weighed is weighed again only at a
# prompt typed into a conversation that held the session earlier in the run
# while another holds it: the user went back to it with /resume
# (_antigravity_hook_retake). The first model call of a turn carries the
# unread mail, after the rotation, in one answer.
_antigravity_hook_pre_invocation() {  # payload
    local run_dir meta="$CS_SESSION_DIR/.cs" rotation="" weigh="" AGY_HOOK_DIGEST="" stop="" failed=""
    run_dir=$(_antigravity_run_dir) && _antigravity_run_dir_ok "$run_dir" || run_dir=""
    # An encrypted session's vault home is checked before every model call of
    # the run that holds the lease; anything a command changed there stops the
    # turn here, before the model can act again (lib/79-antigravity-vault.sh).
    if [ -n "${_cs_private_pin_dir:-}" ]; then
        _antigravity_hook_vault_check "$run_dir" || failed=1
        stop=$(_antigravity_hook_vault_report "$run_dir")
        [ -z "$failed" ] || stop=$(_antigravity_hook_vault_error "$CS_AGY_VAULT_CHECK_FAILURE")
        if [ -n "$stop" ]; then
            ANTIGRAVITY_HOOK_REPLY=$stop
            return 0
        fi
    fi
    _antigravity_payload_read "$1" || return 0
    if [ -z "$run_dir" ] || [ ! -e "$run_dir/seen-$AGY_HOOK_ID" ]; then
        weigh=1
    elif [ -f "$run_dir/held-$AGY_HOOK_ID" ] && [ ! -L "$run_dir/held-$AGY_HOOK_ID" ] \
        && [ "$AGY_HOOK_INVOCATION" = 0 ] && _antigravity_hook_typed \
        && [ "$(cs_binding_read "$CS_SESSION_DIR" antigravity 2>/dev/null)" != "$AGY_HOOK_ID" ]; then
        # The binding is read without the lease only to spare the lease every
        # prompt of the conversation that holds the session; the retake reads
        # it again under the lease.
        weigh=1
    fi
    if [ -n "$weigh" ] && cs_run_lease_owned "$meta"; then
        # The lease runs its callback in a subshell, so the rotation comes
        # back on descriptor 3; nothing else the callback prints is kept.
        rotation=$(cs_run_with_lease "$meta" _antigravity_hook_bind "$CS_SESSION_DIR" "$AGY_HOOK_ID" "$run_dir" \
            3>&1 >/dev/null 2>&1) || true
    fi
    [ "$AGY_HOOK_INVOCATION" != 0 ] || _antigravity_hook_mail_digest "$AGY_HOOK_ID"
    [ -n "$rotation$AGY_HOOK_DIGEST" ] || return 0
    ANTIGRAVITY_HOOK_REPLY=$(jq -nc --arg r "$rotation" --arg m "$AGY_HOOK_DIGEST" '
        {injectSteps: ([$r, $m] | map(select(. != "") | {systemMessage: {systemMessage: .}})),
         terminationBehavior: ""}' 2>/dev/null) || ANTIGRAVITY_HOOK_REPLY=""
}

# Under the run lease. The session is bound to its run's first conversation,
# whichever it is: the one a reopen named, a new one, or one opened with
# /resume before the first turn. Of the conversations the run meets later,
# only one /clear or /new started may take the binding
# (_antigravity_hook_rebind_clear), and one that held it earlier in the run
# takes it back when the user returns to it with /resume
# (_antigravity_hook_retake); a subagent's, and one /resume opened that the
# run never bound, leave it alone. Each conversation the binding moves to is
# marked held. A run without its directory cannot tell first from later, and
# binds only a session that has no conversation yet (or the legacy word).
_antigravity_hook_bind() {  # session_dir, conversation_id, run_dir
    local session_dir="$1" id="$2" run_dir="$3" previous opened="" source=startup reason=fresh log_dir handoff="" receipt_dir
    if [ -n "$run_dir" ]; then
        if _antigravity_explicit_resume_pending "$run_dir"; then
            local expected
            [ -f "$run_dir/resume-conversation" ] && [ ! -L "$run_dir/resume-conversation" ] \
                && IFS= read -r expected < "$run_dir/resume-conversation" \
                && [ "$id" = "$expected" ] && [ "$AGY_HOOK_INVOCATION" = 0 ] && _antigravity_hook_typed || return 0
        fi
        if [ -e "$run_dir/bound" ] || [ -L "$run_dir/bound" ]; then
            if [ -e "$run_dir/seen-$id" ] || [ -L "$run_dir/seen-$id" ]; then
                _antigravity_hook_retake "$session_dir" "$id" "$run_dir" || true
                return 0
            fi
            _antigravity_hook_rebind_clear "$session_dir" "$id" "$run_dir" || true
            _antigravity_run_mark "$run_dir/seen-$id"
            return 0
        fi
        IFS= read -r opened < "$run_dir/opened" 2>/dev/null || opened=""
    fi
    [ "$opened" != resume ] || { source=resume; reason=rebind; }
    if [ -n "$run_dir" ] && [ -f "$run_dir/handoff" ]; then
        IFS= read -r handoff < "$run_dir/handoff" || handoff=""
        # Ownership comes from the protected launch intent. Reading mutable
        # binding state first could let a later conversation claim this turn
        # after a transient binding failure. Recovery may fail, ownership stays.
        receipt_dir=$(_launch_handoff_receipt_dir "$session_dir" antigravity) || return 1
        _launch_handoff_receipt_dir_ok "$receipt_dir" "$session_dir" \
            && [ -f "$receipt_dir/intent.json" ] && [ ! -L "$receipt_dir/intent.json" ] || return 1
        previous=$(jq -er '.previous | strings' "$receipt_dir/intent.json") || return 1
        _launch_handoff_claim "$session_dir" antigravity "$handoff" "$id" "$previous" || return 1
        _launch_handoff_record "$session_dir" antigravity "$handoff" "$id" "$previous" || return 1
        _launch_handoff_recover "$session_dir" antigravity || return 1
        reason=handoff
    else
        previous=$(cs_binding_read "$session_dir" antigravity) || return 1
        if [ -z "$run_dir" ] && { [ "$previous" = "$id" ] \
            || { [ -n "$previous" ] && [ "$previous" != "$CS_ANTIGRAVITY_LATEST" ]; }; }; then
            return 0
        fi
        if [ "$previous" != "$id" ]; then
            cs_binding_write "$session_dir" antigravity "$id" || return 1
            _cs_set_local_state_unlocked "$session_dir/.cs/local/state" engine antigravity || return 1
        fi
    fi
    # Both log lines go to .cs/local, or into the vault for a run the launch
    # ran on the vault home (_antigravity_log_dir); a .cs/private that came
    # mid-run, maybe as a link out of the session, gets nothing.
    if [ "$previous" != "$id" ]; then
        if log_dir=$(_antigravity_log_dir "$session_dir" "$run_dir"); then
            CS_WRITE_QUIET=1 cs_append_inside "$log_dir/session.log" printf '%s - Rebound antigravity conversation: %s -> %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "${previous:-none}" "$id" || true
        fi
        if _is_uuid "$previous" && [ "$reason" != handoff ]; then
            _timeline_rotated "$session_dir" "$previous" "$id" "$reason" "$handoff" antigravity || true
        fi
    fi
    # The rotate skill reads which conversations this checkout ran from this
    # line, as hooks/session-start.sh writes it for Claude.
    if log_dir=$(_antigravity_log_dir "$session_dir" "$run_dir"); then
        CS_WRITE_QUIET=1 cs_append_inside "$log_dir/session.log" printf '%s - Session started (source: %s, ID: %s)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$source" "$id" || true
    fi
    _timeline_started "$session_dir" antigravity "$id" "$source" || true
    if [ -n "$run_dir" ]; then
        _antigravity_run_mark "$run_dir/bound"
        _antigravity_run_mark "$run_dir/seen-$id"
        _antigravity_run_mark "$run_dir/held-$id"
    fi
}

# Under the run lease, for a conversation the run meets after it has bound
# its own, at that conversation's first weighing. It takes the session only
# when /clear or /new started it, which is all of: the launch found the
# rebind usable (clear-rebind: agy at least CS_ANTIGRAVITY_CLEAR_MIN_VERSION
# and cs's SessionStart entry); SessionStart marked it new (a /resume starts
# nothing, and a --conversation open is the run's first); a prompt was typed
# into it; this is its first model call; and its trajectory starts with that
# prompt, where a subagent's starts empty (initialNumSteps 0 on agy 1.5.10).
# The marks are counted only as regular files: a link at their name, which
# only a process with the user's rights could plant in the run's private
# directory, counts for nothing. Then, as Codex's SessionStart hook does at
# /clear (_codex_hook_rebind), the binding moves to it and the lineage is
# recorded, the conversation is marked held, so that a /resume back to it
# later in the run takes the session back (_antigravity_hook_retake), and
# the rotation /cs:rotate armed is spent for it: its context
# goes out on descriptor 3 for PreInvocation to hand the model. A spend the
# store refused keeps the marker for the next /clear and says so there. An
# encrypted session's handoff and marker are the vault's, for a run the launch
# ran on the vault home; one whose .cs/private came mid-run, maybe as a link
# out of the session, is left alone (_antigravity_vault_ok). So is a marker
# in files git tracks, which came with a pull rather than from /cs:rotate
# here: the binding still moves, nothing is spent, and the conversation is
# asked on descriptor 3 to tell the user why, in fixed words. The tracked-
# files notice itself stays out of it: it names a file the repository chose
# and ends in advice written for the user to act on (an untrack and a commit
# that takes whatever else is staged, or cs -rm), which Claude's Stop hook
# shows the user only and which the model here could run. The next open
# refuses the session and prints that notice (cs_assert_local_untracked).
# Everything up to the session's engine state, written last, runs under the
# run guard. That write comes last because its state lock (_cs_lock) reopens
# descriptor 9, the one cs_run_guarded holds the guard on, which lets go of
# the guard. The launch already recorded the engine as antigravity, so a
# failed write there no longer holds back the rotation: by then the binding
# has moved, the handoff is spent, its context is out and the lineage is
# written, and the failure only fails the call.
_antigravity_hook_rebind_clear() {  # session_dir, conversation_id, run_dir
    local session_dir="$1" id="$2" run_dir="$3" previous handoff="" reason=clear refusal="" context="" log_dir actor
    local handoffs private shown
    [ -f "$run_dir/clear-rebind" ] && [ ! -L "$run_dir/clear-rebind" ] || return 0
    [ -f "$run_dir/new-$id" ] && [ ! -L "$run_dir/new-$id" ] || return 0
    [ "$AGY_HOOK_INVOCATION" = 0 ] && _antigravity_hook_typed || return 0
    [ -n "$AGY_HOOK_STEPS" ] && [ "$AGY_HOOK_STEPS" -ge 1 ] || return 0
    _antigravity_vault_ok "$session_dir" "$run_dir" || return 0
    previous=$(cs_binding_read "$session_dir" antigravity) || return 1
    [ "$previous" != "$id" ] || return 0
    if cs_files_tracked_notice "$session_dir/.cs" "$session_dir" >/dev/null; then
        context="Tell the user before anything else: cs reads no queue, mail or rotation in this session, because git tracks files in its .cs/local or .cs/private (they came with a pull or a checkout), or one of them looks like a git repository, or cs could not ask git about them. So this conversation got no rotation, and one /cs:rotate armed stays armed. Do not untrack, commit, delete or remove anything for this yourself, and do not run cs -rm: the fix is the user's, and cs refuses the next open of this session and says why and what to do."
    else
        handoff=$(_rotation_armed_handoff "$session_dir")
    fi
    cs_binding_write "$session_dir" antigravity "$id" || return 1
    _antigravity_run_mark "$run_dir/held-$id"
    if [ -n "$handoff" ]; then
        reason=handoff
        handoffs=$(cs_handoff_dir "$session_dir/.cs") && private=$(cs_private_dir "$session_dir/.cs") || return 1
        shown=$(_codex_handoffs_shown "$session_dir")
        refusal=$(_handoff_spend "$handoffs/$handoff" "$private/pending-handoff" "$id") || true
        actor=$(cs_actor_slug "$session_dir" 2>/dev/null) || actor=unknown
        context=$(_rotation_preamble "$handoff" "$actor" "$shown")
        if [ -n "$refusal" ]; then
            context="$context

$(_handoff_refusal_warning "$shown/$handoff" "$refusal" "$(_codex_marker_shown "$session_dir")")"
        fi
    fi
    if [ -n "$context" ]; then
        { printf '%s' "$context" >&3; } 2>/dev/null || true
    fi
    if log_dir=$(_antigravity_log_dir "$session_dir" "$run_dir"); then
        CS_WRITE_QUIET=1 cs_append_inside "$log_dir/session.log" printf '%s - Rebound antigravity conversation: %s -> %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "${previous:-none}" "$id" || true
        CS_WRITE_QUIET=1 cs_append_inside "$log_dir/session.log" printf '%s - Session started (source: clear, ID: %s)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$id" || true
    fi
    if _is_uuid "$previous"; then
        _timeline_rotated "$session_dir" "$previous" "$id" "$reason" "$handoff" antigravity || true
    fi
    _timeline_started "$session_dir" antigravity "$id" clear || true
    _cs_set_local_state_unlocked "$session_dir/.cs/local/state" engine antigravity || return 1
}

# Under the run lease, for a conversation the run has already weighed, at a
# prompt typed into it while another conversation holds the session. It takes
# the session back only when it held it earlier in this run: the held mark,
# counted only as a regular file, as clear-rebind and new are. That is the
# conversation the user left for a /clear or /new and went back to with
# /resume; one /resume opened that the run never bound, and every subagent,
# leave the binding alone, as under Codex. The binding moves back and the
# lineage is recorded as the run's first bind records a conversation opened
# with /resume (source resume, reason rebind). Nothing is spent and nothing
# goes out on descriptor 3: a rotation /cs:rotate armed stays armed for the
# next /clear. An encrypted session's whose .cs/private came mid-run is left
# alone (_antigravity_vault_ok). A call made without a payload
# read, with no invocationNum set, is no first model call and takes nothing.
_antigravity_hook_retake() {  # session_dir, conversation_id, run_dir
    local session_dir="$1" id="$2" run_dir="$3" previous log_dir
    [ -f "$run_dir/held-$id" ] && [ ! -L "$run_dir/held-$id" ] || return 0
    [ "${AGY_HOOK_INVOCATION:-}" = 0 ] && _antigravity_hook_typed || return 0
    _antigravity_vault_ok "$session_dir" "$run_dir" || return 0
    previous=$(cs_binding_read "$session_dir" antigravity) || return 1
    [ "$previous" != "$id" ] || return 0
    cs_binding_write "$session_dir" antigravity "$id" || return 1
    _antigravity_run_mark "$run_dir/held-$id"
    if log_dir=$(_antigravity_log_dir "$session_dir" "$run_dir"); then
        CS_WRITE_QUIET=1 cs_append_inside "$log_dir/session.log" printf '%s - Rebound antigravity conversation: %s -> %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "${previous:-none}" "$id" || true
        CS_WRITE_QUIET=1 cs_append_inside "$log_dir/session.log" printf '%s - Session started (source: resume, ID: %s)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$id" || true
    fi
    if _is_uuid "$previous"; then
        _timeline_rotated "$session_dir" "$previous" "$id" rebind "" antigravity || true
    fi
    _timeline_started "$session_dir" antigravity "$id" resume || true
    # Last: its state lock (_cs_lock) reopens descriptor 9 and so lets go of the run guard.
    _cs_set_local_state_unlocked "$session_dir/.cs/local/state" engine antigravity || return 1
}

# A finished edit in the run that holds the session's lease, translated by
# the adapter, goes to the recovery consumer the installer put beside the hook.
# An encrypted session's vault home is checked first.
_antigravity_hook_post_tool_use() {  # payload
    local event script run_dir
    cs_run_lease_owned "$CS_SESSION_DIR/.cs" || return 0
    # An encrypted session's vault home, checked after every tool: what a
    # command changed there is moved aside before anything else runs, and the
    # next model call stops the turn (_antigravity_hook_pre_invocation).
    if [ -n "${_cs_private_pin_dir:-}" ] && run_dir=$(_antigravity_run_dir); then
        _antigravity_hook_vault_check "$run_dir" || return 0
    fi
    event=$(printf '%s' "$1" | cs_engine_call antigravity files_changed) || return 0
    [ -n "$event" ] || return 0
    script="$(_antigravity_plugin_dir)/scripts/autosave-commits.sh"
    [ -r "$script" ] || return 0
    printf '%s' "$event" | bash "$script" --event || true
}

# Mail, measured on agy 1.5.8. A PreInvocation answer
# {"injectSteps": [{"systemMessage": {"systemMessage": ...}}]} reaches the
# model and stays in the conversation for later turns. invocationNum is 0 at
# the first model call of each turn and counts every later call in it, those a
# Stop answer adds included, so 0 is the turn's prompt. A Stop answer
# {"decision": "continue", "reason": ...} runs the loop again with the reason
# as a system message. continuationActive, which agy documents as the guard
# against a Stop that keeps continuing, stayed false at every Stop, so the
# wake keeps its own count, written before each wake goes out, and agy stops
# it after ten continuations whatever the hook says. agy has no event for a
# conversation idle at its prompt, so mail that comes then waits for the next
# prompt. The wake's own records live in cs's cache, not beside the mail
# (_antigravity_mail_state_dir): cs acts on them, and the agent can write
# anywhere in the session.

# The folder that holds the session's mail, printed when the conversation is
# the one the session is bound to, in the run that holds its lease: a
# subagent's conversation has an id of its own, as does one opened mid-run
# with /resume, and another agy run in the folder holds no lease. One /clear
# or /new started takes the binding at its first model call
# (_antigravity_hook_rebind_clear), and one that held it earlier in the run
# takes it back at a prompt typed into it after /resume
# (_antigravity_hook_retake), both before the digest is read, so the mail
# follows them. Mail git tracks came with a
# pull, a merge or a checkout, not from a sender on this machine, so none of
# it is shown then, as under Claude and Codex. An encrypted session's mail is
# the vault's, read in a run the launch ran on the vault home; a .cs/private
# that came mid-run, maybe as a link out of the session, is never read
# through (_antigravity_vault_ok).
_antigravity_mail_dir() {  # conversation_id
    local bound private run_dir=""
    cs_run_lease_owned "$CS_SESSION_DIR/.cs" || return 1
    run_dir=$(_antigravity_run_dir) && _antigravity_run_dir_ok "$run_dir" || run_dir=""
    _antigravity_explicit_resume_pending "$run_dir" && return 1
    _antigravity_vault_ok "$CS_SESSION_DIR" "$run_dir" || return 1
    bound=$(cs_binding_read "$CS_SESSION_DIR" antigravity 2>/dev/null) || return 1
    [ "$bound" = "$1" ] || return 1
    ! cs_files_tracked_notice "$CS_SESSION_DIR/.cs" "$CS_SESSION_DIR" >/dev/null || return 1
    private=$(cs_private_dir "$CS_SESSION_DIR/.cs") || return 1
    printf '%s/mail\n' "$private"
}

# The wake's records, woke and wakes, in cs's cache: a 0700 directory named
# by the session directory's identity (cs_retire_cache_dir), so they last
# across runs as Claude's mail/woke does, and kept outside every root an
# agent's sandbox may write, as the handoff receipts are
# (_launch_handoff_receipt_dir_ok). In the session the agent could plant them
# as links that send cs's writes out of it, or as a count that silences the
# wake. With "make" a missing directory is made; fails when no such
# directory is there.
_antigravity_mail_state_dir() {  # [make]
    local dir
    dir=$(cs_retire_cache_dir antigravity-mail "$CS_SESSION_DIR") || return 1
    [ -z "${1:-}" ] || cs_cache_dir_make_private "$dir" || return 1
    cs_cache_dir_private "$dir" \
        && ! _codex_run_dir_in_sandbox_root "$dir" "$CS_SESSION_DIR" \
        && ! _codex_run_dir_in_config_root "$dir" "$CS_SESSION_DIR" || return 1
    printf '%s\n' "$dir"
}

# A record is written without following a link (cs_write_atomic follows
# one): a temp file in its directory, renamed over the name. A link at the
# name goes first, since BSD mv onto a link to a directory moves the file into
# that directory; anything else there but a regular file, a directory above
# all, refuses the write.
_antigravity_mail_state_write() {  # file, text
    local tmp
    if [ -L "$1" ]; then rm -f "$1" 2>/dev/null || return 1; fi
    [ ! -e "$1" ] || [ -f "$1" ] || return 1
    tmp=$(mktemp "${1%/*}/.cs-tmp.XXXXXX" 2>/dev/null) || return 1
    if printf '%s' "$2" > "$tmp" && mv -f "$tmp" "$1" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

# A prompt gets the unread mail as a system message, every prompt until
# cs -msg moves it to cur/, as Claude's and Codex's prompt hooks give it.
# A prompt also clears the wake budget, as scope-prompt.sh does for a typed
# prompt: a wake continues its turn and never starts one, so invocationNum 0
# is always a prompt. The digest goes to AGY_HOOK_DIGEST, which
# _antigravity_hook_pre_invocation answers with.
_antigravity_hook_mail_digest() {  # conversation_id
    local mail state MAIL_DIGEST=""
    mail=$(_antigravity_mail_dir "$1") || return 0
    if state=$(_antigravity_mail_state_dir); then
        rm -f "$state/wakes" 2>/dev/null || true
    fi
    cs_mail_digest "${mail%/mail}"
    AGY_HOOK_DIGEST=$MAIL_DIGEST
}

# A turn that ends on its own with mail that came after its prompt goes on, so
# an exchange between sessions moves without a keystroke. Only NO_TOOL_CALL
# wakes: it is the only end known to be the model's own normal one. A headless
# agy 1.5.8 turn that used a tool (read_file) ended so on 2026-11-14, and so
# did every turn typed into an interactive 1.5.9 run on 2026-11-15, none of
# which used a tool. Any other end stays as it is: a turn the user stopped,
# one that failed, one agy cut off at a limit, one a hook ended, an injected
# response, and TERMINAL_STEP_TYPE, a stop on a step type agy treats as
# terminal, whose list agy does not document and which may hand control back
# to the user. If an interactive turn that uses tools turns out to end that
# way, mail that came during it waits for the next prompt. The rest is the
# wake Claude's hook runs too
# (cs_mail_wake_scan and cs_mail_wake_silence, lib/02-shared.sh, which read
# each record only from a regular file, never through a link), with its
# records in cs's cache rather than in the mail folder, where the agent could
# plant them (_antigravity_mail_state_dir): woke lists the messages a wake has
# already announced, so each one wakes once and a continued turn that brings
# none stops, and wakes counts the wakes since the last prompt against
# CS_MAIL_WAKE_MAX (5), which ends a volley between two unattended sessions.
# No usable directory there, no wake. CS_NO_MAIL_WAKE turns the wake off. The
# digest names nothing in woke, so mail a prompt showed and the turn left
# unread still wakes it once. A turn that ends without a wake may start the
# automatic /clear's count (_antigravity_autoclear_arm).
_antigravity_hook_stop() {  # payload
    _antigravity_payload_read "$1" || return 0
    _antigravity_hook_mail_wake
    [ -n "$ANTIGRAVITY_HOOK_REPLY" ] || _antigravity_autoclear_arm
}

# The mail wake for the Stop _antigravity_hook_stop has read: its answer goes
# to ANTIGRAVITY_HOOK_REPLY, or none.
_antigravity_hook_mail_wake() {
    local mail state answer nl='
'
    # shellcheck disable=SC2034  # set and read by cs_mail_wake_* (lib/02-shared.sh)
    local MAIL_UNREAD=0 MAIL_FRESH=0 MAIL_NAMES="" MAIL_FROM="" MAIL_WAKES=0
    [ "$AGY_HOOK_TERMINATION" = NO_TOOL_CALL ] || return 0
    mail=$(_antigravity_mail_dir "$AGY_HOOK_ID") || return 0
    [ -d "$mail/new" ] || return 0
    state=$(_antigravity_mail_state_dir make) || return 0
    cs_mail_wake_scan "$mail" "$state/woke"
    cs_mail_wake_silence "$state/wakes"
    [ "$MAIL_FRESH" = 1 ] || return 0
    answer=$(jq -nc --arg r "$(cs_mail_wake_reason)" '{decision: "continue", reason: $r}' 2>/dev/null) || return 0
    # The count is written in the cache directory before the answer, and a
    # wake it cannot count is not sent, so the ceiling holds whatever stands
    # at the name. A kill after the count costs one unit of the budget: the
    # message stays unannounced and wakes at a later Stop. woke is written once
    # the answer is out, since writing it first could lose the wake.
    _antigravity_mail_state_write "$state/wakes" "$((MAIL_WAKES + 1))$nl" || return 0
    ANTIGRAVITY_HOOK_REPLY=$answer
    AGY_MAIL_WAKE_DIR="$state" AGY_MAIL_WAKE_NAMES="$MAIL_NAMES"
    ANTIGRAVITY_HOOK_AFTER=_antigravity_mail_wake_record
}

_antigravity_mail_wake_record() {
    _antigravity_mail_state_write "$AGY_MAIL_WAKE_DIR/woke" "$AGY_MAIL_WAKE_NAMES" || true
}

# The automatic /clear after a rotation, as cs gives Codex
# (lib/77-codex-hooks.sh): a watcher the launch runs beside agy types /clear
# and then go into the terminal, at typing speed, through TIOCSTI, once a
# turn of the session's conversation ends with a handoff armed. agy 1.5.12
# took both from the keyboard that way (measured live, 2026-11-19): the slash
# menu offered /clear, the Enter ran it, and go started the new
# conversation, which cs's hooks then bind and hand the handoff
# (_antigravity_hook_rebind_clear). Measured the same day:
# - agy's Stop hook can show nothing: its answer continues the turn or
#   nothing. So the count runs once for each handoff, announced by the
#   rotate skill's last line, rather than again after every turn.
# - Every model call fires PreInvocation first, the one a finished
#   background task or subagent wakes included, and an approval prompt comes
#   from a model call, and the approval prompt has no hook of its own. Every
#   event cancels the count and remaining keys (cmd_antigravity_hook). The
#   typist checks the marker under the same lock before sending each key.
#   agy supplies no way to verify which part of the UI receives the input.
# - Stop's fullyIdle was false while a background command ran; such work
#   wakes the conversation later and can ask for approval then, so no count
#   starts until a turn ends with nothing left running.
# The deadline, the typing marker and the record of the counted handoff live
# in the run's own directory in cs's cache, outside the session, /tmp and
# $TMPDIR, where the agent writes only through a command or edit agy lets
# it run there.

# The seconds the count runs: CS_ANTIGRAVITY_CLEAR_GRACE (default 20, 0
# turns it off), read as Codex's grace is; CS_ROTATE_FORCE_CTX=off or 0 turns
# it off too. Codex's own setting does not reach it.
_antigravity_autoclear_grace() {
    CS_CODEX_CLEAR_GRACE="${CS_ANTIGRAVITY_CLEAR_GRACE:-20}" _codex_autoclear_grace
}

# What the count does at its end: clear, or hold when a switch this run
# recorded is pending. Unlike Codex's, it never quits: nobody is at the keys,
# and a switch's exit stays the user's /exit, as a native-approval Codex
# run's does (_codex_autoclear_action).
_antigravity_autoclear_action() {  # session_dir
    CS_RUN_APPROVAL=native _codex_autoclear_action "$1"
}

# At the deadline, read the handoff from the store the launch used. A vault
# remount, replacement at the same path, or one added to a running session
# cannot give the watcher permission to type.
_antigravity_autoclear_handoff() {  # session_dir, run_dir
    local session_dir="$1" run_dir="$2" private
    if [ -e "$run_dir/vault" ] || [ -L "$run_dir/vault" ]; then
        private=$(_antigravity_run_private_dir "$session_dir" "$run_dir") || return 1
        _rotation_peek_armed_handoff "$private/handoffs" "$private/pending-handoff"
    else
        ! _switch_session_encrypted "$session_dir" || return 1
        _rotation_peek_armed_handoff "$session_dir/.cs/handoffs" "$session_dir/.cs/local/pending-handoff"
    fi
}

# The active delay in seconds. Rotation reports it only with the /clear
# route, the count enabled and a live watcher.
_antigravity_autoclear_available_grace() {
    local run_dir
    run_dir=$(_antigravity_run_dir) && _antigravity_run_dir_ok "$run_dir" || return 1
    [ -f "$run_dir/clear-rebind" ] && [ ! -L "$run_dir/clear-rebind" ] || return 1
    _codex_watcher_alive "$run_dir" && _antigravity_autoclear_grace
}

# A new hook invalidates any older Stop before handling its payload. The
# hook's pid is unique while that hook can still publish a deadline. Keep the
# generation and cancellation under the same lock as publication.
_antigravity_autoclear_begin() (
    local run_dir
    run_dir=$(_antigravity_run_dir) && [ -f "$run_dir/watcher.pid" ] \
        && _codex_run_dir_ok "$run_dir" "$CS_SESSION_DIR" || return 1
    umask 077
    _cs_lock "$run_dir/autoclear.lock" || {
        _antigravity_autoclear_cancel "$run_dir"
        return 1
    }
    _antigravity_autoclear_cancel "$run_dir" || return 1
    _antigravity_mail_state_write "$run_dir/autoclear-generation" "$$"$'\n' || return 1
    printf '%s\n' "$$"
)

_antigravity_autoclear_cancel() {  # run_dir
    rm -f "$1/autoclear-generation" "$1/autoclear" "$1/typing"
}

# Cancel a count or remaining keys before publishing a switch. Holding the
# same lock as the typist and Stop makes this one change for the watcher.
_antigravity_autoclear_write_switch() (  # switch_file, command [args...]
    local run_dir
    if run_dir=$(_antigravity_run_dir) && [ -f "$run_dir/watcher.pid" ] \
        && _codex_run_dir_ok "$run_dir" "$CS_SESSION_DIR"; then
        umask 077
        _cs_lock "$run_dir/autoclear.lock" || return 1
        _antigravity_autoclear_cancel "$run_dir" || return 1
    fi
    cs_write_atomic "$@"
)

# Read, validate and claim the deadline under one lock. An overlapping
# hook can cancel the old stamp and publish a new one while a poll waits.
_antigravity_autoclear_take_stamp() (  # run_dir
    local run_dir="$1" stamp="$1/autoclear" deadline handoff scheduled current
    umask 077
    _cs_lock "$run_dir/autoclear.lock" 0 || return 1
    if ! _codex_stamp_ok "$stamp" || [ "$(_switch_field "$stamp" run)" != "${CS_RUN_ID:-}" ]; then
        rm -f "$stamp" 2>/dev/null
        return 1
    fi
    deadline=$(_switch_field "$stamp" deadline)
    if ! [[ "$deadline" =~ ^[0-9]+$ ]]; then
        rm -f "$stamp" 2>/dev/null
        return 1
    fi
    [ "$(date +%s)" -ge "$deadline" ] || return 1
    handoff=$(_switch_field "$stamp" handoff)
    scheduled=$(_switch_field "$stamp" generation)
    rm -f "$stamp" || return 1
    { IFS= read -r current < "$run_dir/autoclear-generation"; } 2>/dev/null || return 1
    [ -n "$handoff" ] && [ -n "$scheduled" ] && [ "$scheduled" = "$current" ] || return 1
    ( set -C; printf '%s\n' "$current" > "$run_dir/typing" ) 2>/dev/null || return 2
    printf '%s\n' "$handoff"
)

# Whether the hook runs for the agy this launch started: agy runs a hook's
# command through sh -c, which hands it the process, so every hook's parent
# was agy's own pid on 1.5.12, the pid cs_run_child records in the run's
# directory (native.pid). An agy the agent starts inside the run inherits the
# run's environment, but its hooks' parent is that agy. A shell that forks
# instead of handing over makes every hook fail this, and the count stays
# off: a grandparent is no proof, since agy may start the agent's commands
# through such a shell too.
_antigravity_hook_from_native() {  # run_dir
    local native=""
    [ -f "$1/native.pid" ] && [ ! -L "$1/native.pid" ] || return 1
    { IFS= read -r native < "$1/native.pid"; } 2>/dev/null || return 1
    [[ "$native" =~ ^[0-9]+$ ]] && [ "$PPID" = "$native" ]
}

# Whether the handoff has had its count in this run, read only from a regular
# file in the run's directory.
_antigravity_autoclear_counted() {  # run_dir, handoff
    local counted=""
    [ -f "$1/autoclear-counted" ] && [ ! -L "$1/autoclear-counted" ] || return 1
    IFS= read -r counted < "$1/autoclear-counted" 2>/dev/null || true
    [ "$counted" = "$2" ]
}

# At the end of a turn _antigravity_hook_stop has read, with no mail wake:
# starts the count when the turn ended normally (NO_TOOL_CALL) with nothing
# left running (fullyIdle), in the conversation the session is bound to, in
# the agy this launch started (_antigravity_hook_from_native), in the run
# that holds the session, with a handoff armed that has not had its
# count in this run, no switch of this run's pending, and this run's watcher
# alive to type. The handoff is recorded as counted before the deadline is
# written, so a record that cannot be written starts no count. Every path
# returns 0: the hook never fails a turn.
_antigravity_autoclear_arm() {
    local run_dir grace bound handoff
    [ -n "$AGY_AUTOCLEAR_GENERATION" ] || return 0
    [ "$AGY_HOOK_TERMINATION" = NO_TOOL_CALL ] && [ "$AGY_HOOK_IDLE" = 1 ] || return 0
    run_dir=$(_antigravity_run_dir) && _codex_run_dir_ok "$run_dir" "$CS_SESSION_DIR" || return 0
    [ -f "$run_dir/clear-rebind" ] && [ ! -L "$run_dir/clear-rebind" ] || return 0
    grace=$(_antigravity_autoclear_grace) || return 0
    _codex_watcher_alive "$run_dir" || return 0
    _antigravity_hook_from_native "$run_dir" || return 0
    cs_run_lease_owned "$CS_SESSION_DIR/.cs" || return 0
    ! _antigravity_explicit_resume_pending "$run_dir" || return 0
    _antigravity_vault_ok "$CS_SESSION_DIR" "$run_dir" || return 0
    bound=$(cs_binding_read "$CS_SESSION_DIR" antigravity 2>/dev/null) || return 0
    [ "$bound" = "$AGY_HOOK_ID" ] || return 0
    # A /clear there would carry no rotation (_antigravity_hook_rebind_clear).
    ! cs_files_tracked_notice "$CS_SESSION_DIR/.cs" "$CS_SESSION_DIR" >/dev/null || return 0
    handoff=$(_rotation_armed_handoff "$CS_SESSION_DIR")
    [ -n "$handoff" ] || return 0
    [ "$(_antigravity_autoclear_action "$CS_SESSION_DIR")" = clear ] || return 0
    _antigravity_autoclear_publish "$run_dir" "$handoff" "$grace" || true
}

_antigravity_autoclear_publish() (  # run_dir, handoff, grace
    local run_dir="$1" handoff="$2" generation deadline contents
    umask 077
    _cs_lock "$run_dir/autoclear.lock" || return 0
    IFS= read -r generation < "$run_dir/autoclear-generation" || return 0
    [ "$generation" = "$AGY_AUTOCLEAR_GENERATION" ] || return 0
    ! _antigravity_autoclear_counted "$run_dir" "$handoff" || return 0
    _antigravity_mail_state_write "$run_dir/autoclear-counted" "$handoff"$'\n' || return 0
    deadline=$(( $(date +%s) + $3 ))
    printf -v contents 'deadline=%s\nhandoff=%s\nrun=%s\ngeneration=%s\n' \
        "$deadline" "$handoff" "${CS_RUN_ID:-}" "$generation"
    _antigravity_mail_state_write "$run_dir/autoclear" "$contents"
)
