# ABOUTME: Carries the other engine's newer conversation into a plain reopen (Claude <-> Codex).
# ABOUTME: Shared by both launches: what can be offered, the offer's rows, and their wording.

# Reopening a session under the other engine used to resume that engine's own
# conversation, the one from before the switch, so the work done since stayed
# behind. An attended open now offers the newer conversation instead: y carries
# it over, converted by cs-codex-thread, as a new conversation that takes the
# target engine's binding (the old one stays on disk, and e still resumes it).
# cs -switch never asks: its relaunch passes --from-handoff or --resume, and
# keeps its handoff design. Spawned, --resume and unattended opens resume as
# before.

_transplant_label() {  # engine
    case "$1" in
        claude) printf 'Claude\n' ;;
        codex) printf 'Codex\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# The other engine's conversation, when it is the newer one: the session's
# last run was under that engine. cs_launch_session records a run's engine as
# the run ends, so during a launch the state still names the previous run's.
# Prints "<engine> <native id>". Nothing is offered on a same-engine open, from
# or to Antigravity (its format is not probed yet), or in an encrypted session:
# Codex keeps its threads outside the vault, so none ever ran there to carry.
_transplant_source() {  # session_dir, target engine
    local session_dir="$1" target="$2" last id
    case "$target" in claude|codex) ;; *) return 1 ;; esac
    last=$(_read_local_state "$session_dir/.cs/local/state" engine)
    case "$last" in claude|codex) ;; *) return 1 ;; esac
    [ "$last" != "$target" ] || return 1
    ! _switch_session_encrypted "$session_dir" || return 1
    id=$(cs_binding_read "$session_dir" "$last" 2>/dev/null) || return 1
    case "$last" in
        claude) _is_uuid "$id" || return 1 ;;
        codex) _codex_thread_id_valid "$id" || return 1 ;;
    esac
    printf '%s %s\n' "$last" "$id"
}

# How many messages the helper's count names: a plain number, else 0.
_transplant_count() {  # stats JSON
    local count
    count=$(printf '%s\n' "$1" | jq -r '.messages' 2>/dev/null) || count=0
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    printf '%s\n' "$count"
}

# "8 messages, ~29k tokens": the count, and its size at four characters a token.
_transplant_size() {  # stats JSON
    printf '%s\n' "$1" | jq -r '
        "\(.messages) message" + (if .messages == 1 then "" else "s" end)
        + ", ~\(((.characters // 0) / 4000) | ceil)k tokens"' 2>/dev/null
}

# The offer, laid out like the pending-handoff menu. y carries the other
# engine's conversation over, e resumes the target engine's own earlier one
# (offered only when there is one), and r and d join while a rotation handoff
# waits; the caller printed that handoff's line. The default key gets the mark.
_transplant_offer_print() {  # source engine, source id, target engine, size, own id, handoff, default key
    local from to dy="" dn="" dr=""
    from=$(_transplant_label "$1")
    to=$(_transplant_label "$3")
    case "$7" in
        y) dy=' · default' ;;
        n) dn=' · default' ;;
        r) dr=' · default' ;;
    esac
    printf "${DIM}The newest conversation here is %s's:${NC} %s ${DIM}(%s)${NC}\n" "$from" "${2:0:8}" "$4"
    echo
    _resume_menu_row y "$GREEN" 'carry over' "continue the $from conversation in $to$dy"
    [ -z "$5" ] || _resume_menu_row e "$COMMENT" 'earlier' "resume the earlier $to conversation instead"
    if [ -n "$6" ]; then
        _resume_menu_row r "$GOLD" 'from handoff' "fresh conversation that picks up the handoff$dr"
        _resume_menu_row n "$COMMENT" 'fresh' "fresh conversation; the handoff waits for later$dn"
        _resume_menu_row d "$ORANGE" 'discard' 'retire the handoff, then carry over'
    else
        _resume_menu_row n "$COMMENT" 'fresh' "fresh conversation$dn"
    fi
    echo
    printf '    %b›%b ' "$GOLD" "$NC"
}

# What the helper said when it could not read the other engine's conversation,
# as one dim line; the usual question follows it.
_transplant_unreadable() {  # source engine, helper output
    local reason="${2#cs-codex-thread: }"
    reason=${reason%%$'\n'*}
    printf "${DIM}cs: the %s conversation cannot be carried over: %s${NC}\n" "$(_transplant_label "$1")" "${reason:-unknown error}"
}
