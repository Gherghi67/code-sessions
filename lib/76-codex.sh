# ABOUTME: Launch a cs session in Codex using a persistent, session-local thread binding.
# ABOUTME: Refreshes CS context without a model turn and releases the shared lock on exit.

# A separate named profile lets /clear reload the last rotation's /model choice
# without changing defaults for other sessions. Reused per checkout, reset at each
# launch; it contains only model settings, never authentication or permissions.
_codex_rotation_profile_path() {  # session_dir
    local key
    key=$(python3 -I -c 'import hashlib, os, sys; print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:20])' "$1") || return 1
    printf '%s/cs-rotation-%s.config.toml\n' "${CODEX_HOME:-$HOME/.codex}" "$key"
}

# CODEX_HOME is the vault home for an encrypted session, which the agent can
# write while cs's profile is off: a link or a non-file at the profile's name
# stops the launch, and _codex_write_into_place writes the profile, never
# through a link.
_codex_rotation_profile_prepare() {  # session_dir, settings JSON; sets CS_CODEX_ROTATION_PROFILE
    local profile content
    profile=$(_codex_rotation_profile_path "$1") || return 1
    if [ -L "$profile" ] || { [ -e "$profile" ] && [ ! -f "$profile" ]; }; then
        _codex_launch_error "$(_cs_plain_name "$profile") is a link or not a regular file; cs does not write the Codex model profile through it. Remove it; cs writes the file again at the next open."
        return 1
    fi
    mkdir -p "$(dirname "$profile")" || return 1
    # The x keeps the last newline through $( ); a failed jq writes nothing.
    content=$(
        printf '%s' "$2" | jq -r 'to_entries[] | .key + " = " + (.value | tojson)' || exit 1
        printf x
    ) || return 1
    printf '%s' "${content%x}" | _codex_write_into_place "$profile" || return 1
    CS_CODEX_ROTATION_PROFILE=$profile
}

# A trusted project's .codex/config.toml outranks the profile, and command-line
# overrides outrank both for the whole run, a later /model choice included. So
# an explicit choice the project also sets stays on the command line, and every
# other one seeds the profile, where Stop can replace it. What /clear reloads
# regardless goes to the Stop hook as CS_CODEX_ROTATION_FIXED. When Codex cannot
# say what the project sets, explicit choices stay on the command line.
_codex_rotation_setup() {  # helper, codex_bin, session_dir; sets rotation_cli_* and the profile
    local pinned plan
    pinned=$(cs_run_child "$1" --codex-bin "$2" --cwd "$3" --project-config 2>/dev/null) || pinned=""
    printf '%s' "$pinned" | jq -e 'type == "object"' >/dev/null 2>&1 || pinned=null
    plan=$(jq -cn --argjson pinned "$pinned" \
        --arg model "${CS_LAUNCH_MODEL:-}" --arg effort "${CS_LAUNCH_EFFORT:-}" '
        reduce (["model", $model], ["model_reasoning_effort", $effort]) as [$key, $choice]
            ({cli: {}, profile: {}, fixed: {}};
            if $choice == "" then
                if $pinned != null and ($pinned | has($key))
                then .fixed[$key] = {value: $pinned[$key].value, source: $pinned[$key].file}
                else . end
            elif $pinned == null or ($pinned | has($key)) then
                .cli[$key] = $choice | .fixed[$key] = {value: $choice, source: "the command line"}
            else .profile[$key] = $choice end)') || return 1
    rotation_cli_model=$(printf '%s' "$plan" | jq -r '.cli.model // ""') || return 1
    rotation_cli_effort=$(printf '%s' "$plan" | jq -r '.cli.model_reasoning_effort // ""') || return 1
    CS_CODEX_ROTATION_FIXED=$(printf '%s' "$plan" | jq -c '.fixed') || return 1
    _codex_rotation_profile_prepare "$3" "$(printf '%s' "$plan" | jq -c '.profile')"
}

_codex_launch_error() {  # message
    printf 'Error: %s\n' "$1" >&2
    return 1
}

# Writes stdin to the destination, in a folder the agent can write. The temp
# file beside it is made by mkstemp and written through the descriptor that
# made it, never opened again by name, so a link swapped in for it receives
# nothing; os.replace (rename(2)) then replaces the destination itself, never
# following a link there. A link or a non-file already at the destination is
# refused, named. The file keeps mkstemp's 0600 mode.
_codex_write_into_place() {  # destination; the content on stdin
    python3 -I -c '
import os, stat, sys, tempfile
dest = sys.argv[1]
tmp = None
try:
    try:
        mode = os.lstat(dest).st_mode
    except FileNotFoundError:
        mode = None
    if mode is not None and not stat.S_ISREG(mode):
        # Shown as cs shows a plain name (_cs_plain_name): the path may lead through a planted link.
        shown = "".join(c if c.isascii() and (c.isalnum() or c in "._/@-") else "_" for c in dest)
        print(shown + " is a link or not a regular file; cs does not write through it.", file=sys.stderr)
        sys.exit(1)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest) or ".", prefix="." + os.path.basename(dest) + ".")
    with os.fdopen(fd, "wb") as stream:
        stream.write(sys.stdin.buffer.read())
    os.replace(tmp, dest)
except Exception:
    if tmp is not None:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    sys.exit(1)
' "$1"
}

_cs_codex_adapter_dependencies() {
    # Codex takes an executable path, not a shell command string.
    command -v "$CODEX_BIN" >/dev/null 2>&1 || printf '%s\n' codex
    command -v python3 >/dev/null 2>&1 || printf '%s\n' python3
    return 0
}

# Where the installer puts cs's skills for Codex.
_cs_codex_adapter_skill_dir() {
    printf '%s/skills\n' "$(_codex_shared_home)"
}

_cs_codex_adapter_capabilities() {
    # rotation: `cs -codex-hook session-start` rebinds after /clear and loads
    # the armed handoff; the launch prompt's r starts a thread from it.
    # feature_finish: -finish starts the thread on `$finish <task>`, as
    # Claude's starts on /finish <task>.
    # clear_rotation: the same session-start hook hands the new thread the
    # armed rotation at /clear.
    printf '%s\n' launch exact_resume startup_context feature_finish rotation engine_switch recovery_autosave memory_index mail_delivery spawn_brief clear_rotation task_queue
}

# The queue confirms each task by the provenance Codex records on a Stop
# hook's continuation prompt ({type:harness, hook:true}). Measured on
# 0.167.0-alpha.3.2 and 0.169.0-alpha.11.1; 0.158 and 0.162 record none.
CS_CODEX_QUEUE_MIN_VERSION=0.167.0

# Whether a Codex build is CS_CODEX_QUEUE_MIN_VERSION or later, read from the
# first three dot-separated numbers its --version prints: 1 for an older
# build, 2 for a version it cannot read (the binary is missing, --version
# fails, or it prints no x.y.z). A spawner inside Codex's sandbox runs this
# too, where bash 3.2 cannot make a here-string's temp file, so nothing here
# uses one.
_codex_queue_version_ok() {  # [codex_bin]
    local re='([0-9]+)\.([0-9]+)\.([0-9]+)' out h1 h2 h3 w1 w2 w3
    out=$("${1:-${CODEX_BIN:-codex}}" --version 2>/dev/null) || return 2
    [[ "$out" =~ $re ]] || return 2
    h1=$((10#${BASH_REMATCH[1]})) h2=$((10#${BASH_REMATCH[2]})) h3=$((10#${BASH_REMATCH[3]}))
    [[ "$CS_CODEX_QUEUE_MIN_VERSION" =~ $re ]] || return 1
    w1=$((10#${BASH_REMATCH[1]})) w2=$((10#${BASH_REMATCH[2]})) w3=$((10#${BASH_REMATCH[3]}))
    [ "$h1" -eq "$w1" ] || return $(( h1 > w1 ? 0 : 1 ))
    [ "$h2" -eq "$w2" ] || return $(( h2 > w2 ? 0 : 1 ))
    [ "$h3" -ge "$w3" ]
}

_cs_codex_adapter_prepare_workspace() {  # session_dir, mode
    # Startup context is refreshed at launch. No native project configuration
    # or instruction files are required, including a user-owned AGENTS.md.
    case "$2" in create|migrate_storage|migrate|worktree) return 0 ;; *) return 2 ;; esac
}

_cs_codex_adapter_launch() {
    _launch_codex_bound "$@"
}

_codex_cs_binary() {
    cs_running_binary
}

# The helper lives beside the assembled cs binary, including when cs is
# installed outside this checkout. Tests can substitute an isolated helper.
_codex_thread_helper() {
    if [ -n "${CS_CODEX_THREAD_BIN:-}" ]; then
        printf '%s\n' "$CS_CODEX_THREAD_BIN"
        return 0
    fi
    local cs_binary
    cs_binary=$(_codex_cs_binary) || return 1
    local helper
    helper="$(dirname "$cs_binary")/cs-codex-thread"
    [ -x "$helper" ] || helper="$(dirname "$cs_binary")/cs-codex-thread"
    printf '%s\n' "$helper"
}

# A Codex thread's newest turn, as a mark two reads can compare: "turn <id>",
# or "turn " for a thread no turn has started in. Fails when the history
# cannot be read. The start hook's log cannot stand in for it: a matcher the
# user kept on cs's hook group, or a hook Codex does not trust, keeps a start
# out of the log while the turn still runs.
_codex_turn_mark() {  # helper, codex_bin, session_dir, thread_id
    local turn
    turn=$("$1" --codex-bin "$2" --cwd "$3" --thread-id "$4" --latest-turn 2>/dev/null) || return 1
    printf 'turn %s\n' "$turn"
}

# Whether a thread ran a turn since the launch took its mark. A history that
# cannot be read, before or after, may have one: that answers yes.
_codex_thread_ran() {  # helper, codex_bin, session_dir, thread_id, mark_before
    local after
    [ -n "$5" ] || return 0
    after=$(_codex_turn_mark "$1" "$2" "$3" "$4") || return 0
    [ "$after" != "$5" ]
}

_codex_thread_id_valid() {  # thread_id
    [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

# Codex takes the engine-neutral context as its startup instructions.
_codex_emit_context() {  # cs_bin
    cs_emit_engine_context "$@"
}

# The agent can write the folder the context lives in (.cs/private, for an
# encrypted session), so nothing is written through a name it could plant: a
# link or a non-file at the context's own name stops the launch, and the
# context, with the rotation preamble when one is given, is rendered in full
# first and then written by _codex_write_into_place. A failed render replaces
# nothing.
_codex_write_context() {  # session_name, session_dir, output_file, actor, cs_bin, [rotation_handoff]
    local session_name="$1" session_dir="$2" output_file="$3"
    local actor="$4" cs_bin="$5" rotation_handoff="${6:-}"
    local content
    if [ -L "$output_file" ] || { [ -e "$output_file" ] && [ ! -f "$output_file" ]; }; then
        _codex_launch_error "$output_file is a link or not a regular file; cs does not write the Codex context through it. Remove it; cs writes the file again at the next open."
        return 1
    fi
    # The x keeps the context's last newlines through $( ).
    content=$(
        cs_session_context "$session_name" "$session_dir" "$actor" \
            _codex_emit_context "$cs_bin" || exit 1
        if [ -n "$rotation_handoff" ]; then
            printf '\n'
            _rotation_preamble "$rotation_handoff" "$actor" "$(_codex_handoffs_shown "$session_dir")" \
                || exit 1
        fi
        printf x
    ) || return 1
    printf '%s' "${content%x}" | _codex_write_into_place "$output_file"
}

# Commit only a helper-acknowledged candidate while the current lease is held.
_codex_commit_prepared() {  # session_dir, previous_id, thread_id, source
    local session_dir="$1" previous_id="$2" thread_id="$3" source="$4" recorded
    local pending="$session_dir/.cs/local/pending-binding-codex.json"
    local timeline="$session_dir/.cs/timeline.jsonl" rotated_recorded=0 started_recorded=0
    jq -e --arg run "$CS_RUN_ID" --arg candidate "$thread_id" --arg previous "$previous_id" \
        '.run_id == $run and .candidate_id == $candidate and .previous_id == $previous' "$pending" >/dev/null || return 1
    recorded=$(cs_binding_read "$session_dir" codex) || return 1
    [ "$recorded" = "$previous_id" ] || [ "$recorded" = "$thread_id" ] || return 1
    cs_binding_write "$session_dir" codex "$thread_id" || return 1
    _cs_set_local_state_unlocked "$session_dir/.cs/local/state" engine codex || return 1
    # A replay can follow a committed binding whose lineage write was interrupted.
    if [ -f "$timeline" ]; then
        if jq -eRs --arg run "$CS_RUN_ID" --arg id "$thread_id" '
            [split("\n")[] | fromjson? | select(.event == "rotated" and
             .engine == "codex" and .run_id == $run and .to == $id)] | length > 0
        ' "$timeline" >/dev/null 2>&1; then rotated_recorded=1; fi
        if jq -eRs --arg run "$CS_RUN_ID" --arg id "$thread_id" '
            [split("\n")[] | fromjson? | select(.event == "started" and
             .engine == "codex" and .run_id == $run and .session_id == $id)] | length > 0
        ' "$timeline" >/dev/null 2>&1; then started_recorded=1; fi
    fi
    if [ "$rotated_recorded" = 0 ]; then
        # A launch that continues a rotation handoff stages that reason and the
        # handoff's name, and a carry-over the Claude conversation it carries;
        # every other new thread is a plain fresh start. A first thread rotates
        # from nothing and records no rotation, unless it was carried over:
        # its lineage runs through the other engine's conversation.
        local reason handoff carried
        reason=$(jq -r '.reason // ""' "$pending") || return 1
        handoff=$(jq -r '.handoff // ""' "$pending") || return 1
        carried=$(jq -r '.carried_from // ""' "$pending") || return 1
        case "$reason" in
            handoff) carried="" ;;
            transplant) handoff="" ;;
            *) reason=fresh; handoff=""; carried="" ;;
        esac
        if [ -n "$previous_id" ] || [ "$reason" = transplant ]; then
            _timeline_rotated "$session_dir" "$previous_id" "$thread_id" "$reason" "$handoff" codex "$carried" || return 1
        fi
    fi
    if [ "$started_recorded" = 0 ]; then
        _timeline_started "$session_dir" codex "$thread_id" "$source" || return 1
    fi
    rm -f "$pending"
}

_codex_ack_resume() {  # session_dir, thread_id
    _cs_set_local_state_unlocked "$1/.cs/local/state" engine codex || return 1
    _timeline_started "$1" codex "$2" resume
}

# Reconcile the durable kickoff against native history before retrying.
# Unknown history is ambiguous: preserve the receipt and stop, never replay.
# A newly persisted native thread can briefly be absent from the next
# app-server reader. Retry the read once; two failures remain ambiguous and
# never authorize a launch or discard a receipt.
_codex_spawn_turn_mark() {
    _codex_turn_mark "$@" || _codex_turn_mark "$@"
}

_codex_spawn_reconcile() {  # session_dir, helper, codex_bin
    local pending="$1/.cs/local/spawn-kick.json" thread before after
    [ ! -L "$pending" ] && [ ! -d "$pending" ] || {
        _codex_launch_error "Spawn kickoff is a link or directory: $pending"; return 1;
    }
    [ -f "$pending" ] || return 0
    jq -e 'type == "object" and (.prompt | type == "string" and length > 0)
        and (.attempted | type == "boolean")' "$pending" >/dev/null \
        || { _codex_launch_error "Unreadable spawn kickoff: $pending; inspect it before reopening."; return 1; }
    [ "$(jq -r '.attempted' "$pending")" = true ] || return 0
    thread=$(jq -r '.thread // ""' "$pending") || return 1
    before=$(jq -r '.turn_before // ""' "$pending") || return 1
    _codex_thread_id_valid "$thread" && [ -n "$before" ] || return 1
    after=$(_codex_spawn_turn_mark "$2" "$3" "$1" "$thread") || {
        _codex_launch_error "Cannot confirm whether the spawn brief started; kickoff retained at $pending. Retry when thread history is available."
        return 1
    }
    if [ "$after" != "$before" ]; then
        rm -f "$pending"
        return
    fi
    # No turn ran, so the receipt goes back to pending: a rotation or finish
    # prompt that takes this open would otherwise run the turn that spends it.
    cs_write_atomic "$pending" jq 'del(.thread, .turn_before) | .attempted = false' "$pending"
}

# Offered when the session's newer conversation is Claude's (lib/47-transplant.sh).
# The transcript is read before the question, so an empty or unreadable one is
# never offered: the latter is named in one dim line and the usual question
# follows. Sets the caller's transplant_from, transplant_id, transplant_size
# and transplant_path (the transcript the new thread will carry).
_codex_transplant_prepare() {  # session_dir, helper
    local source transcript stats
    source=$(_transplant_source "$1" codex) || return 0
    transcript=$(_conversation_transcript "$1" "${source#* }") || return 0
    if ! stats=$("$2" --read-claude "$transcript" 2>&1); then
        _transplant_unreadable claude "$stats"
        return 0
    fi
    [ "$(_transplant_count "$stats")" -gt 0 ] || return 0
    transplant_from=claude
    transplant_id=${source#* }
    transplant_size=$(_transplant_size "$stats")
    transplant_path=$transcript
}

# The actual cs process owns session.lock, so terminating that PID runs these
# traps and can stop its Codex child before releasing the lock.
_launch_codex_bound() {
    local session_name="$1" session_dir="$2"
    local merge_feature="${5:-}" intent="${6:-auto}"
    local meta_dir="$session_dir/.cs" local_dir="$session_dir/.cs/local"
    local binding_file="$local_dir/codex-thread-id"
    local context_file="$local_dir/codex-instructions.md"
    local codex_bin="${CODEX_BIN:-codex}" helper thread_id recorded_id

    [ -d "$session_dir" ] || {
        _codex_launch_error "Session directory does not exist: $session_dir"
        return 1
    }
    mkdir -p "$local_dir" || return 1
    umask 077

    codex_bin=$(command -v "$codex_bin" 2>/dev/null) || {
        _codex_launch_error "Codex executable not found: ${CODEX_BIN:-codex}. Set CODEX_BIN to one executable path."
        return 1
    }
    [ -x "$codex_bin" ] || {
        _codex_launch_error "Codex executable is not executable: $codex_bin"
        return 1
    }
    # A vault home inherited from another encrypted session's launch is never
    # this session's (lib/76-codex-vault.sh); the shell's home is checked here.
    _codex_drop_inherited_vault_home
    # Codex refuses a CODEX_HOME that does not exist, and its app-server exits
    # before the helper can say why; the helper keeps server output private.
    if [ -n "${CODEX_HOME:-}" ] && [ ! -d "$CODEX_HOME" ]; then
        _codex_launch_error "CODEX_HOME points to $CODEX_HOME, which does not exist. Create it (mkdir -m 700 \"$CODEX_HOME\"), then log in with: codex login"
        return 1
    fi
    case "$codex_bin" in
        /*) ;;
        *) codex_bin="$(cd -- "$(dirname "$codex_bin")" && pwd -P)/$(basename "$codex_bin")" || return 1 ;;
    esac
    # Automatic approval must refuse before preparation binds or spends context.
    # Native approval leaves policy to Codex and needs no automatic-review flag.
    local codex_help=""
    if [ "${CS_LAUNCH_APPROVAL:-auto}" != native ]; then
        if ! codex_help=$(cs_run_child "$codex_bin" --help 2>/dev/null) \
            || ! printf '%s\n' "$codex_help" | grep -E '^[[:space:]]*--approve-for-me([[:space:]]|$)' >/dev/null; then
            _codex_launch_error "Codex at $codex_bin must support --approve-for-me for automatic approval. Upgrade Codex, set CODEX_BIN to a supporting build, or use --native-approval to keep Codex's configured policy."
            return 1
        fi
    fi
    helper=$(_codex_thread_helper) || {
        _codex_launch_error "Cannot locate cs-codex-thread beside the cs executable."
        return 1
    }
    [ -x "$helper" ] || {
        _codex_launch_error "Codex thread helper is missing or not executable: $helper"
        return 1
    }
    # An encrypted session runs Codex on its own home inside the vault
    # (lib/76-codex-vault.sh), exported here for Codex and every helper and hook
    # the run starts, and checked before anything is bound or spent. Its
    # context file goes beside its handoffs, in the vault.
    local vault_home="" vault_check=""
    _export_session_codex_home "$session_dir" || return 1
    if [ -n "${CS_CODEX_SHARED_HOME:-}" ]; then
        vault_home=$CODEX_HOME
        vault_check=$(_codex_vault_check "$helper" "$codex_bin" "$session_dir") || return 1
        ( CS_NATIVE_LAUNCH_ARGS=(); _codex_vault_profile_args "$vault_check" "$vault_home" "${CS_LAUNCH_APPROVAL:-auto}" ) \
            || return 1
        context_file="$meta_dir/private/codex-instructions.md"
        rm -f "$local_dir/codex-instructions.md" 2>/dev/null || true
    fi

    recorded_id=$(cs_binding_read "$session_dir" codex) || {
        _codex_launch_error "Cannot read Codex thread binding: $binding_file"
        return 1
    }
    if [ -e "$binding_file" ] || [ -L "$binding_file" ]; then
        _codex_thread_id_valid "$recorded_id" || {
            _codex_launch_error "Invalid Codex thread binding in $binding_file. Repair it before launching; no new thread was created."
            return 1
        }
    fi
    # A binding made before the session's Codex home moved into its vault names
    # a thread the shared home keeps: it stays there, and this launch starts the
    # session's first conversation in the vault. An explicit resume refuses.
    # Only the shared home's yes says so; a thread neither home keeps takes the
    # ordinary refresh, which fails as in a plain session, and a probe that
    # fails stops the launch with the helper's reason on the terminal.
    local outside_id="" in_vault="" in_shared="" probe_status
    if [ -n "$vault_home" ] && [ -n "$recorded_id" ]; then
        probe_status=0
        in_vault=$(cs_run_child "$helper" --has-thread --thread-id "$recorded_id") || probe_status=$?
        if [ "$probe_status" -ne 0 ]; then
            _codex_launch_error "Could not look for Codex conversation $recorded_id in the vault's Codex home; the binding is unchanged."
            return 1
        fi
        if [ "$in_vault" = no ]; then
            probe_status=0
            in_shared=$(CODEX_HOME="$CS_CODEX_SHARED_HOME" cs_run_child "$helper" --has-thread --thread-id "$recorded_id") \
                || probe_status=$?
            if [ "$probe_status" -ne 0 ]; then
                _codex_launch_error "Could not look for Codex conversation $recorded_id in the shared Codex home $CS_CODEX_SHARED_HOME; the binding is unchanged."
                return 1
            fi
        fi
    fi
    if [ "$in_shared" = yes ]; then
        if [ "$intent" = resume ]; then
            _codex_launch_error "Cannot resume: the recorded Codex conversation $recorded_id is kept in $CS_CODEX_SHARED_HOME, outside the vault. Start one in the vault with --fresh."
            return 1
        fi
        outside_id=$recorded_id
        recorded_id=""
        printf "${DIM}The earlier Codex conversation %s stays in %s, outside the vault; this session's Codex conversations start in the vault from now on.${NC}\n" \
            "$outside_id" "$CS_CODEX_SHARED_HOME"
    fi
    # An earlier kickoff is settled before the launch answers the resume
    # question, binds a thread or spends a handoff: a history that cannot be
    # read stops it here with all three left for the retry.
    _codex_spawn_reconcile "$session_dir" "$helper" "$codex_bin" || return 1

    # File-backed named profiles are advertised as CONFIG_PROFILE_V2. Older
    # builds keep their original launch behavior rather than getting a flag
    # with different semantics. Native approval has not probed help yet. The
    # profile is written before a thread is bound or a handoff spent, so a
    # failure here leaves both for the retry.
    local CS_CODEX_ROTATION_PROFILE="" CS_CODEX_ROTATION_FIXED="{}"
    local rotation_cli_model="" rotation_cli_effort=""
    export CS_CODEX_ROTATION_PROFILE CS_CODEX_ROTATION_FIXED
    if [ -z "$codex_help" ]; then
        codex_help=$(cs_run_child "$codex_bin" --help 2>/dev/null) || codex_help=""
    fi
    if printf '%s\n' "$codex_help" | grep -F 'CONFIG_PROFILE_V2' >/dev/null; then
        _codex_rotation_setup "$helper" "$codex_bin" "$session_dir" || {
            _codex_launch_error "Could not prepare the scoped Codex model profile."
            return 1
        }
    fi

    # A rotation handoff the rotate skill wrote adds r (and d) to the question,
    # as on Claude: r starts a fresh thread that continues from it.
    local pending_handoff rotation_handoff="" rotation_origin=""
    pending_handoff=$(_pending_handoff_pick "$session_dir")
    # Reopened here after a run under Claude: its conversation is the newer
    # one, and an attended open offers to carry it over (lib/47-transplant.sh).
    local transplant_from="" transplant_id="" transplant_size="" transplant_path="" carry=""
    if [ "$intent" = auto ] && cs_interactive && ! _spawn_launch_is_owned "$session_name" "$session_dir"; then
        _codex_transplant_prepare "$session_dir" "$helper"
    fi
    if [ "$intent" = handoff ]; then
        # --from-handoff (and the relaunch of a cs -switch): the r answer,
        # unasked, as on Claude.
        [ -n "$pending_handoff" ] || {
            _codex_launch_error "$(_switch_no_handoff_message "$session_name")"
            return 1
        }
        rotation_handoff=$(basename "$pending_handoff")
        rotation_origin=$(_switch_handoff_origin "$pending_handoff" "$session_dir")
        intent=fresh
    elif [ "$intent" = auto ] && cs_interactive \
        && ! _spawn_launch_is_owned "$session_name" "$session_dir" \
        && { [ -n "$recorded_id" ] || [ -n "$pending_handoff" ] || [ -n "$transplant_from" ]; }; then
        local response=""
        if [ -n "$transplant_from" ]; then
            if [ -n "$pending_handoff" ]; then
                local t_origin=""
                _handoff_is_local "$pending_handoff" "$session_dir" \
                    || t_origin=" ${DIM}(from another checkout)${NC}"
                printf "${DIM}Rotation handoff pending:${NC} %s%b\n" "$(basename "$pending_handoff")" "$t_origin"
            fi
            _transplant_offer_print "$transplant_from" "$transplant_id" codex "$transplant_size" \
                "$recorded_id" "$pending_handoff" y
        elif [ -n "$pending_handoff" ]; then
            local origin=""
            _handoff_is_local "$pending_handoff" "$session_dir" \
                || origin=" ${DIM}(from another checkout)${NC}"
            printf "${DIM}Rotation handoff pending:${NC} %s%b\n" "$(basename "$pending_handoff")" "$origin"
            echo
            if [ -n "$recorded_id" ]; then
                _resume_menu_row y "$GREEN" 'resume' 'continue the previous Codex conversation · default'
            else
                _resume_menu_row y "$GREEN" 'start' 'a new Codex conversation · default'
            fi
            _resume_menu_row r "$GOLD" 'from handoff' 'fresh conversation that picks up the handoff'
            _resume_menu_row n "$COMMENT" 'fresh' 'fresh conversation; the handoff waits for later'
            _resume_menu_row d "$ORANGE" 'discard' 'retire the handoff, then continue as y'
            echo
            printf '    %b›%b ' "$GOLD" "$NC"
        else
            printf 'Continue previous Codex conversation? [Y/n] '
        fi
        IFS= read -rsn1 response || { printf '\n'; return 130; }
        printf '\n'
        # Beside a carry-over, y (and the r or d that continue as y) takes
        # it; e, offered when this engine has a thread of its own, resumes
        # that one instead. Anywhere else e is a key not offered.
        case "$response" in
            $'\e') return 130 ;;
            [nN])
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
                intent=fresh
                ;;
            [rR])
                if [ -n "$pending_handoff" ]; then
                    rotation_handoff=$(basename "$pending_handoff")
                    intent=fresh
                else
                    _disarm_rotation_marker "$session_dir"
                    [ -z "$transplant_from" ] || carry=1
                fi
                ;;
            [dD])
                _disarm_rotation_marker "$session_dir"
                if [ -n "$pending_handoff" ]; then
                    _handoff_set_status "$pending_handoff" discarded || true
                    printf "${DIM}Handoff discarded:${NC} %s\n" "$(basename "$pending_handoff")"
                fi
                [ -z "$transplant_from" ] || carry=1
                ;;
            [eE])
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
                [ -z "$transplant_from" ] || [ -n "$recorded_id" ] || carry=1
                ;;
            *)
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
                [ -z "$transplant_from" ] || carry=1
                ;;
        esac
        # The carried thread is a new one, so the launch takes the fresh path.
        [ -z "$carry" ] || intent=fresh
    elif [ "$intent" = fresh ]; then
        # An explicit fresh start with a rotation armed continues it. Claude's
        # --fresh does not: it disarms the marker (lib/75-launch.sh). Both are
        # kept as they are; --from-handoff is the spelling both engines read
        # as r.
        rotation_handoff=$(_rotation_armed_handoff "$session_dir")
    elif [ "$intent" = resume ] && [ -n "${_cs_switch_resume:-}" ]; then
        # A switch relaunched with --resume: the armed handoff rides the
        # resume as its first message, spent once the thread is refreshed.
        :
    else
        # Resuming, or unattended: the armed rotation is not taken, so it must
        # not survive to be consumed by an unrelated /clear later.
        _disarm_rotation_marker "$session_dir" "$pending_handoff"
    fi
    if [ "$intent" = resume ] && [ -z "$recorded_id" ]; then
        _codex_launch_error "Cannot resume: no recorded Codex conversation. Use --fresh."
        return 1
    fi
    # A thread the shared home keeps is still the binding a new one replaces.
    local previous_id="${recorded_id:-$outside_id}"
    [ "$intent" != fresh ] || recorded_id=""

    cs_export_session_context "$session_name" "$session_dir"
    cs_unset_claude_env
    CS_BIN=$(_codex_cs_binary) || {
        _codex_launch_error "Cannot resolve the cs executable for this session."
        return 1
    }
    export CS_BIN

    local actor
    actor=$(cs_actor_slug "$session_dir") || return 1
    _codex_write_context "$session_name" "$session_dir" "$context_file" "$actor" "$CS_BIN" \
        "$rotation_handoff" || {
        _codex_launch_error "Could not write Codex context: $context_file"
        return 1
    }

    # The helper uses app-server to create or refresh a *persistent* thread and
    # injects context without starting a user/model turn. A failed refresh must
    # never silently bind this session to a new thread.
    local prepared_file helper_status=0
    prepared_file=$(mktemp "$local_dir/.codex-prepared.XXXXXX") || return 1
    if [ -n "$recorded_id" ]; then
        cs_run_child "$helper" --codex-bin "$codex_bin" --cwd "$session_dir" \
            --instructions-file "$context_file" --thread-id "$recorded_id" > "$prepared_file" || helper_status=$?
    elif [ -n "$carry" ]; then
        # y on a carry-over: the new thread takes the Claude conversation
        # after its context. When that fails, the helper says why, one line
        # says what happens instead, and the launch does what y did before:
        # resume this engine's own thread, or start a fresh one.
        cs_run_child "$helper" --codex-bin "$codex_bin" --cwd "$session_dir" \
            --instructions-file "$context_file" --history-from-claude "$transplant_path" \
            --history-source "$transplant_id" > "$prepared_file" || helper_status=$?
        if [ "$helper_status" -ne 0 ]; then
            carry=""
            helper_status=0
            if [ -n "$previous_id" ] && [ -z "$outside_id" ]; then
                printf 'cs: could not carry the Claude conversation over; resuming the earlier Codex conversation.\n' >&2
                intent=auto
                recorded_id="$previous_id"
                cs_run_child "$helper" --codex-bin "$codex_bin" --cwd "$session_dir" \
                    --instructions-file "$context_file" --thread-id "$recorded_id" > "$prepared_file" || helper_status=$?
            else
                printf 'cs: could not carry the Claude conversation over; starting a fresh Codex conversation.\n' >&2
                cs_run_child "$helper" --codex-bin "$codex_bin" --cwd "$session_dir" \
                    --instructions-file "$context_file" > "$prepared_file" || helper_status=$?
            fi
        fi
    else
        cs_run_child "$helper" --codex-bin "$codex_bin" --cwd "$session_dir" \
            --instructions-file "$context_file" > "$prepared_file" || helper_status=$?
    fi
    thread_id=$(cat "$prepared_file")
    rm -f "$prepared_file"
    if [ "$helper_status" -ne 0 ]; then
        if [ -n "$recorded_id" ]; then
            _codex_launch_error "Could not refresh Codex thread $recorded_id. The binding remains in $binding_file; check the helper error and retry."
        else
            _codex_launch_error "Could not create a persistent Codex thread. The previous binding remains unchanged; check the helper error and retry."
        fi
        return "$helper_status"
    fi
    _codex_thread_id_valid "$thread_id" || {
        _codex_launch_error "Codex thread helper returned an invalid ID; refusing to launch."
        return 1
    }
    if [ "$intent" = fresh ] && [ -n "$previous_id" ] && [ "$thread_id" = "$previous_id" ]; then
        _codex_launch_error "Codex returned the previous thread for a fresh launch; binding unchanged."
        return 1
    fi
    if [ -n "$recorded_id" ]; then
        [ "$thread_id" = "$recorded_id" ] || {
            _codex_launch_error "Codex thread helper returned $thread_id for bound thread $recorded_id; refusing to launch."
            return 1
        }
    else
        local stage_reason="${intent:-fresh}" carried_from="" start_source=fresh
        [ -z "$rotation_handoff" ] || stage_reason=handoff
        if [ -n "$carry" ]; then
            stage_reason=transplant
            carried_from="claude:$transplant_id"
            start_source=transplant
        fi
        # An encrypted session's handoff name is its topic, so it stays out of
        # the plaintext pending record and timeline, as on Claude: the
        # rotation is recorded with its reason and without the name.
        local public_handoff="$rotation_handoff"
        ! _switch_session_encrypted "$session_dir" || public_handoff=""
        if ! cs_binding_stage "$session_dir" codex "$previous_id" "$thread_id" "$stage_reason" "$public_handoff" \
            "$carried_from"; then
            _codex_launch_error "Could not stage Codex thread binding: $binding_file"
            return 1
        fi
        if ! cs_run_with_lease "$meta_dir" _codex_commit_prepared "$session_dir" "$previous_id" "$thread_id" "$start_source"; then
            _codex_launch_error "Could not save acknowledged Codex binding; prior transition remains recoverable: $binding_file"
            return 1
        fi
        if [ -n "$carry" ]; then
            printf "${DIM}Carried over the Claude conversation:${NC} %s ${DIM}(%s)${NC}\n" \
                "${transplant_id:0:8}" "$transplant_size"
            # codex resume opens the earlier thread outside cs: the binding
            # stays on the carried one.
            [ -z "$previous_id" ] || [ -n "$outside_id" ] \
                || printf "${DIM}The earlier Codex conversation stays. To return to it:${NC} codex resume %s\n" "$previous_id"
        fi
    fi
    if [ -n "$recorded_id" ]; then
        cs_run_with_lease "$meta_dir" _codex_ack_resume "$session_dir" "$thread_id" || return 1
    fi

    # The new thread is bound now, so the handoff it continues is spent. The
    # kick is Codex's starting prompt, the counterpart of Claude's positional
    # prompt on the same answer: without it the thread would wait for a message.
    local kick="" rotation_starts="" spent="" turn_before="" refusal=""
    if [ -n "$rotation_handoff" ]; then
        # Spent before Codex starts; failed launches restore it below, or in
        # a switch relaunch's settle, if the conversation never begins.
        spent=1
        if declare -F _switch_note_spent >/dev/null; then
            _switch_note_spent "$session_dir" "$rotation_handoff" "$thread_id"
            # Set by _switch_note_spent in lib/78-switch.sh.
            # shellcheck disable=SC2154
            rotation_starts="$_cs_switch_starts"
        fi
        # A refused flip keeps the marker for the next start or /clear to
        # retry (_handoff_spend); the thread still starts from the handoff,
        # and the terminal and the kick name the refusal.
        local shown_handoff shown_marker
        shown_handoff="$(_codex_handoffs_shown "$session_dir")/$rotation_handoff"
        shown_marker="$(_codex_marker_shown "$session_dir")"
        refusal=$(_handoff_spend "$session_dir/$shown_handoff" "$session_dir/$shown_marker" "$thread_id") || true
        # The kick is codex's argv, visible to ps: an encrypted session's
        # handoff name, its topic, stays out of it, as in a switch's resume
        # (_switch_resume_handoff). The terminal still names the file.
        if ! _switch_session_encrypted "$session_dir"; then
            kick="Continue from the pending rotation handoff: read $shown_handoff first."
            [ -z "$refusal" ] || kick="$kick $(_handoff_refusal_warning "$shown_handoff" "$refusal" "$shown_marker")"
        elif [ -z "$refusal" ]; then
            kick="Continue from the pending rotation handoff: read the handoff in .cs/private/handoffs/ whose frontmatter says consumed_by: $thread_id first."
        else
            # No consumed_by line was written to point at: the marker stands
            # in, and the reason stays on the terminal.
            kick="Continue from the pending rotation handoff: read the handoff $shown_marker names, in .cs/private/handoffs/, first."
            kick="$kick $(_handoff_refusal_warning "the handoff $shown_marker names" "cs printed the reason in the terminal" "$shown_marker")"
        fi
        printf "${DIM}Continuing from handoff:${NC} %s%b\n" "$rotation_handoff" "$rotation_origin"
        [ -z "$refusal" ] || _handoff_refusal_notice "$shown_handoff" "$refusal" "$shown_marker"
        # r is the user choosing the handoff over the merge armed moments
        # earlier, as on Claude; the merge waits for its own launch.
        [ -z "$merge_feature" ] \
            || warn "Rotation handoff takes this launch; re-run: cs $session_name -finish $merge_feature"
    elif [ "$intent" = resume ] && [ -n "${_cs_switch_resume:-}" ]; then
        # The kick is the handoff's prompt, set only when one was spent.
        _switch_resume_handoff "$session_dir" "$thread_id" kick
        [ -z "$kick" ] || spent=1
    elif [ -n "$merge_feature" ]; then
        # The finish skill, named the way Codex takes a skill from the user.
        kick="\$finish $merge_feature"
    fi
    # What the thread held before the CLI: a spent handoff goes back only
    # while its history shows no turn since. A mark not taken counts as one.
    if [ -n "$spent" ]; then
        turn_before=$(_codex_turn_mark "$helper" "$codex_bin" "$session_dir" "$thread_id") || turn_before=""
    fi

    printf '%s\n' 'Codex via cs: session context, exact resume and rotation are enabled. Automatic recovery is enabled. Use cs -queue for walk-away tasks.'
    # A dedicated native writer lives for this supervised CLI lifetime.
    # Signals and lock cleanup belong to the shared controller.
    local status=0
    local -a CS_NATIVE_LAUNCH_ARGS
    if [ -n "$CS_CODEX_ROTATION_PROFILE" ]; then
        # Only an explicit choice a project setting would shadow stays a CLI
        # override; the profile carries the rest (_codex_rotation_setup).
        local CS_LAUNCH_MODEL="$rotation_cli_model" CS_LAUNCH_EFFORT="$rotation_cli_effort"
    else
        printf '%s\n' 'cs: this Codex build cannot preserve /model choices across rotation; file-backed --profile support is required.'
    fi
    _cs_native_launch_options codex || return 1
    if [ -n "$CS_CODEX_ROTATION_PROFILE" ]; then
        local profile_name=${CS_CODEX_ROTATION_PROFILE##*/}
        CS_NATIVE_LAUNCH_ARGS+=(--profile "${profile_name%.config.toml}")
    fi
    # The vault home stays out of the agent's reach (lib/76-codex-vault.sh).
    # The queue reads Codex's history there only when cs's profile is on the
    # command line: a native sandbox the user can switch mid-session keeps
    # nothing read-only.
    local vault_protected="" vault_resolved="" vault_id vault_args
    if [ -n "$vault_home" ]; then
        vault_args=${#CS_NATIVE_LAUNCH_ARGS[@]}
        _codex_vault_profile_args "$vault_check" "$vault_home" "${CS_LAUNCH_APPROVAL:-auto}" || return 1
        if [ "${#CS_NATIVE_LAUNCH_ARGS[@]}" -gt "$vault_args" ]; then
            vault_protected=1
        fi
        vault_resolved=$(cd -P -- "$vault_home" 2>/dev/null && pwd -P) || vault_protected=""
    fi
    # The run's approval, for its hooks and the automatic /clear's watcher: a
    # run with native approval never quits for a switch unattended.
    local CS_RUN_APPROVAL=auto
    [ "${CS_LAUNCH_APPROVAL:-auto}" != native ] || CS_RUN_APPROVAL=native
    export CS_RUN_APPROVAL
    # shellcheck disable=SC2034 # shared seed delivery returns this dynamically
    local spawn_kick="" spawn_pending="$local_dir/spawn-kick.json" spawn_attempt=0 spawn_before=""
    if [ -z "$kick" ]; then
        # The older receipt was reconciled above. A pending kick wins over a
        # newer seed, which stays staged for a later open.
        if [ ! -f "$spawn_pending" ] && [ -n "${SESSIONS_ROOT:-}" ] \
            && [ -f "$SESSIONS_ROOT/.spawn/$session_name.seed" ]; then
            _spawn_prepare_launch "$session_name" "$session_dir"
        fi
        if [ -f "$spawn_pending" ]; then
            kick=$(jq -r '.prompt' "$spawn_pending") || return 1
            spawn_before=$(_codex_spawn_turn_mark "$helper" "$codex_bin" "$session_dir" "$thread_id") || {
                _codex_launch_error "Cannot record thread history before spawn kickoff; receipt retained for retry."
                return 1
            }
            cs_write_atomic "$spawn_pending" jq --arg thread "$thread_id" --arg before "$spawn_before" \
                '. + {attempted: true, thread: $thread, turn_before: $before}' "$spawn_pending" || return 1
            spawn_attempt=1
        fi
    fi
    # The automatic /clear after a rotation (lib/77-codex-hooks.sh) types into
    # this terminal, so its watcher runs only where one is attached and will
    # take simulated input, which is asked once here, and only with a private
    # directory for its deadline, made before Codex starts. Where it cannot
    # type, the launch says why, and no turn promises a count. The
    # run's cleanup stops the watcher and removes the directory, after the CLI
    # or when a signal ends the launch (lib/16-lifecycle.sh). Earlier builds
    # kept the deadline in the session, where the agent could forge it; one
    # left there is removed and never read.
    local autoclear_dir refusal
    rm -f "$session_dir/.cs/local/codex-autoclear" 2>/dev/null || true
    # Queue receipts need the same private directory, even without a tty or a
    # rotation countdown. The run supervisor owns its lifetime in both cases.
    if autoclear_dir=$(_codex_run_dir_prepare "$session_dir"); then
        _cs_run_helper_dir=$autoclear_dir
        # Without the record the queue refuses; the launch goes on.
        if [ -n "$vault_protected" ] && vault_id=$(cs_dir_identity "${vault_resolved%/*}"); then
            ( set -C; printf '%s\n' "$vault_resolved" "$vault_id" > "$autoclear_dir/vault-home" ) 2>/dev/null || true
        fi
        # Without this record the queue parks: an older Codex keeps no hook
        # provenance for its Stop to confirm a task by.
        if _codex_queue_version_ok "$codex_bin"; then
            ( set -C; : > "$autoclear_dir/queue-version-ok" ) 2>/dev/null || true
        fi
    fi
    if [ -t 0 ] && [ -t 1 ] && _codex_autoclear_grace >/dev/null; then
        if ! refusal=$(_codex_autoclear_probe); then
            printf "${DIM:-}cs: no automatic /clear after a rotation: %s${NC:-}\n" "$refusal"
            _codex_autoclear_log "$session_dir" "Automatic /clear is off for this run: $refusal"
        elif [ -n "$autoclear_dir" ]; then
            _codex_autoclear_watch "$session_dir" "$autoclear_dir" </dev/null >/dev/null 2>&1 &
            _cs_run_helper_pid=$!
        else
            printf "${DIM}The automatic /clear after a rotation is off for this run: cs could not make a private directory under %s.${NC}\n" \
                "${CS_CACHE_DIR:-$HOME/.cache/cs}/codex-runs"
        fi
    fi
    cs_run_child "$codex_bin" --no-daemon resume "$thread_id" -C "$session_dir" ${CS_NATIVE_LAUNCH_ARGS[@]+"${CS_NATIVE_LAUNCH_ARGS[@]}"} ${kick:+"$kick"} || status=$?
    # Keys the watcher typed just before Codex exited can wait unread in the
    # terminal and would run in the shell, so its input is flushed, but only
    # when the watcher was typing: the flush would eat ordinary type-ahead.
    _cs_run_end_helper
    if [ -n "$_cs_run_helper_dir" ] && [ -e "$(_codex_keys_sent_file "$_cs_run_helper_dir")" ]; then
        _codex_flush_input
    fi
    _cs_run_stop_helper
    if [ "$status" -ne 0 ] && [ -n "$spent" ]; then
        # A switch relaunch's settle reads it too (lib/78-switch.sh).
        _cs_switch_ran=""
        if _codex_thread_ran "$helper" "$codex_bin" "$session_dir" "$thread_id" "$turn_before"; then
            _cs_switch_ran=1
        fi
    fi
    if [ "$status" -ne 0 ] && [ -n "$rotation_handoff" ] && [ -z "${_cs_switched_from:-}" ]; then
        if cs_run_with_lease "$meta_dir" _restore_launch_handoff "$session_dir" \
            "$rotation_handoff" "$thread_id" "$rotation_starts" "${_cs_switch_ran:-}"; then
            printf 'Codex did not start; handoff %s restored for retry.\n' "$rotation_handoff" >&2
        fi
    fi
    if [ "$spawn_attempt" = 1 ]; then
        if ! _codex_spawn_reconcile "$session_dir" "$helper" "$codex_bin"; then
            [ "$status" -ne 0 ] || status=1
        elif [ -f "$spawn_pending" ]; then
            warn "Spawn brief has not started; kickoff retained for the next open."
        fi
    fi
    return "$status"
}

launch_codex() {
    cs_launch_session codex "$@"
}
