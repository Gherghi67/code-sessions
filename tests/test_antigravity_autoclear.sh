#!/usr/bin/env bash
# ABOUTME: Tests the automatic /clear after a rotation under Antigravity: the count cs's agy hooks start and stop,
# ABOUTME: and the watcher that types /clear and go. Payloads are agy 1.5.12's shapes; no agy process runs.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/24-engine-adapters.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../lib/41-bindings.sh"
source "$SCRIPT_DIR/../lib/75-launch.sh"
source "$SCRIPT_DIR/../lib/76-codex.sh"
source "$SCRIPT_DIR/../lib/76-codex-vault.sh"
source "$SCRIPT_DIR/../lib/77-codex-hooks.sh"
source "$SCRIPT_DIR/../lib/78-switch.sh"
source "$SCRIPT_DIR/../lib/79-antigravity-vault.sh"
source "$SCRIPT_DIR/../lib/79-antigravity.sh"

BOUND=11111111-1111-4111-8111-111111111111
SUB=55555555-5555-4555-8555-555555555555
CLEARED=66666666-6666-4666-8666-666666666666
HANDOFF=2026-11-19-continue.md
OTHER_HANDOFF=2026-11-19-later.md
RUN=33333333-3333-4333-8333-333333333333
OTHER_RUN=44444444-4444-4444-8444-444444444444

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    SESSION="$TEST_TMPDIR/session"
    KEYS="$TEST_TMPDIR/keys"
    mkdir -p "$SESSION/.cs/local" "$SESSION/.cs/handoffs"
    git -C "$SESSION" init -q
    printf 'engine: antigravity\n' > "$SESSION/.cs/local/state"
    printf '%s\n' "$BOUND" > "$SESSION/.cs/local/antigravity-conversation"
    _handoff "$HANDOFF"
    _arm "$HANDOFF"
    export CS_CACHE_DIR="$TEST_TMPDIR/cache" CS_ACTOR=tester
    export CODEX_HOME="$TEST_TMPDIR/codex-home"
    mkdir -p "$CODEX_HOME"
    _lease "$RUN"
    # The run's private directory as the launch leaves it once the run has
    # bound its conversation on an agy that carries a rotation through
    # /clear (clear-rebind), with the watcher the launch started alive in it:
    # this shell stands in for the watcher.
    RUN_DIR="$CS_CACHE_DIR/antigravity-runs/$RUN"
    ( umask 077 && mkdir -p "$RUN_DIR" )
    chmod 700 "$CS_CACHE_DIR/antigravity-runs" "$RUN_DIR"
    : > "$RUN_DIR/clear-rebind"
    : > "$RUN_DIR/bound"
    : > "$RUN_DIR/seen-$BOUND"
    : > "$RUN_DIR/held-$BOUND"
    printf '%s %s\n' "$$" "$RUN" > "$RUN_DIR/watcher.pid"
    STAMP="$RUN_DIR/autoclear"
    # A stand-in for agy runs each hook as its child, as agy does, and first
    # records itself in the run's directory as the agy the launch started
    # (native.pid, which cs_run_child writes), unless AGY_TEST_KEEP_NATIVE
    # says another process is that agy. The hook is bin/cs with one check
    # stood down: the test's cache lies under TMPDIR, which the hooks rightly
    # refuse for the run's directory (bin/cs without its closing `main "$@"`,
    # the stub, then main); test_a_run_dir_the_agent_can_write_gets_no_count
    # runs the real check. AGY_TEST_STUB, when set, is more shell run before
    # main.
    cat > "$TEST_TMPDIR/agy-standin.sh" <<'STANDIN'
[ -n "${AGY_TEST_KEEP_NATIVE:-}" ] || printf '%s\n' "$$" > "$AGY_TEST_NATIVE_FILE"
bash "$AGY_TEST_HOOK" "$@"
exit $?
STANDIN
    cat > "$TEST_TMPDIR/cs-hook.sh" <<'HOOK'
eval "$(sed '$d' "$CS_BIN")"
_codex_run_dir_in_sandbox_root() { return 1; }
eval "${AGY_TEST_STUB:-}"
main "$@"
HOOK
    WATCHER=""
}

teardown() {
    [ -z "$WATCHER" ] || { kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null || true; }
    rm -rf "$TEST_TMPDIR"
    unset CS_CACHE_DIR CS_ACTOR CODEX_HOME CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_SESSION_DIR
    unset CS_ROTATE_FORCE_CTX CS_ANTIGRAVITY_CLEAR_GRACE CS_CODEX_CLEAR_GRACE AGY_TEST_STUB
}

_handoff() {  # name, [status]
    printf -- '---\nparent: %s\ncreated: 2026-11-19T10:00:00Z\npurpose: continue\nstatus: %s\n---\n\n## Next Step\nGo on.\n' \
        "$BOUND" "${2:-unconsumed}" > "$SESSION/.cs/handoffs/$1"
}

_arm() { printf '%s\n' "$1" > "$SESSION/.cs/local/pending-handoff"; }

# The session's lease and lock, as the launch of the named run writes them.
_lease() {  # run_id, [owner_pid]
    printf '%s\n' "${2:-$$}" > "$SESSION/.cs/session.lock"
    jq -n --arg run "$1" --arg owner "${2:-$$}" '{run_id: $run, engine: "antigravity", owner_pid: ($owner | tonumber)}' \
        > "$SESSION/.cs/local/run-lease.json"
}

# Runs cs's hook the way agy does: the payload on stdin, the launch's
# environment, as a child of the stand-in agy (setup).
_agy_hook() {  # verb, payload, [run_id], [engine]
    printf '%s' "$2" | env CS_RUN_ENGINE="${4-antigravity}" CS_RUN_ID="${3:-$RUN}" CS_RUN_OWNER_PID="$$" \
        CS_SESSION_DIR="$SESSION" CS_SESSION_NAME=demo CS_BIN="$CS_BIN" \
        AGY_TEST_NATIVE_FILE="$RUN_DIR/native.pid" AGY_TEST_HOOK="$TEST_TMPDIR/cs-hook.sh" \
        bash "$TEST_TMPDIR/agy-standin.sh" -antigravity-hook "$1"
}

# A Stop payload as agy 1.5.12 sends one: fullyIdle is false while a
# background task or subagent still runs, and absent from some payloads.
_stop() {  # conversation, [reason], [fully_idle: true|false|absent]
    local idle=',"fullyIdle":true'
    case "${3:-true}" in
        false) idle=',"fullyIdle":false' ;;
        absent) idle="" ;;
    esac
    printf '{"conversationId":"%s","lastUserInput":"go","executionNum":0,"terminationReason":"%s","continuationActive":false%s}' \
        "$1" "${2-NO_TOOL_CALL}" "$idle"
}

_pre() {  # conversation, [typed], [invocation], [steps]
    printf '{"conversationId":"%s","lastUserInput":"%s","invocationNum":%s,"initialNumSteps":%s}' \
        "$1" "${2-go}" "${3:-0}" "${4:-5}"
}

_stamp_field() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$STAMP"; }

_stamp_at() {  # deadline
    printf '12345\n' > "$RUN_DIR/autoclear-generation"
    printf 'deadline=%s\nhandoff=%s\nrun=%s\ngeneration=12345\n' "$1" "$HANDOFF" "$RUN" > "$STAMP"
    chmod 600 "$STAMP"
}

_stale_stamp() { _stamp_at 1; }

# --- the count: started by the bound conversation's Stop ---

# A turn of the conversation the session is bound to ends normally, with
# nothing left running and a handoff armed: the deadline goes into the run's
# own directory, 0600, naming the handoff and the run. agy's Stop hook cannot
# show anything, so the answer is {} and nothing else.
test_an_idle_turn_end_with_a_handoff_armed_starts_the_count() {
    local out now deadline
    now=$(date +%s)
    out=$(_agy_hook stop "$(_stop "$BOUND")") || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_eq '{}' "$out" "the Stop hook answers nothing that would continue the turn" || return 1
    assert_file_exists "$STAMP" || return 1
    assert_eq 600 "$(_file_mode "$STAMP")" "the deadline is the user's alone" || return 1
    assert_eq "$HANDOFF" "$(_stamp_field handoff)" || return 1
    assert_eq "$RUN" "$(_stamp_field run)" || return 1
    deadline=$(_stamp_field deadline)
    [ "$deadline" -ge $((now + 20)) ] && [ "$deadline" -le $((now + 22)) ] \
        || { echo "  FAIL: deadline $deadline is not about 20 s after $now"; return 1; }
    assert_not_exists "$SESSION/.cs/local/autoclear" "the agent can write the session" || return 1
}

# A background task or subagent still running can wake the conversation and
# raise an approval prompt with no hook of cs's in between: no count then.
# agy 1.5.12 sent fullyIdle false while a background command ran.
test_a_turn_end_with_work_still_running_starts_no_count() {
    local idle
    for idle in false absent; do
        _agy_hook stop "$(_stop "$BOUND" NO_TOOL_CALL "$idle")" >/dev/null || return 1
        assert_not_exists "$STAMP" "a count with fullyIdle $idle" || return 1
    done
    # Not a count, so the handoff still gets its one count once the work is done.
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_file_exists "$STAMP" "the turn the finished work woke counts" || return 1
}

test_a_turn_that_did_not_end_normally_starts_no_count() {
    local reason
    for reason in USER_CANCELED ERROR MAX_INVOCATIONS TERMINAL_STEP_TYPE TERMINAL_CUSTOM_HOOK ""; do
        _agy_hook stop "$(_stop "$BOUND" "$reason")" >/dev/null || return 1
        assert_not_exists "$STAMP" "a count after a turn that ended '$reason'" || return 1
    done
}

test_a_turn_of_another_conversation_starts_no_count() {
    _agy_hook stop "$(_stop "$SUB")" >/dev/null || return 1
    assert_not_exists "$STAMP" "a subagent's turn is not the session's" || return 1
}

# An agy the agent starts inside the run inherits the run's environment, and
# its Stop could name the session's conversation (agy -p --conversation):
# only a hook whose parent is the agy the launch started counts down. That
# agy's parent is no proof either: agy starts commands through a shell.
test_a_turn_end_from_another_agy_starts_no_count() {
    local other status=0
    sleep 30 & other=$!
    printf '%s\n' "$other" > "$RUN_DIR/native.pid"
    AGY_TEST_KEEP_NATIVE=1 _agy_hook stop "$(_stop "$BOUND")" >/dev/null || status=$?
    [ "$status" = 0 ] || { kill "$other" 2>/dev/null; echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_not_exists "$STAMP" "a Stop from another agy" || { kill "$other" 2>/dev/null; return 1; }
    kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
    printf '%s\n' "$$" > "$RUN_DIR/native.pid"
    AGY_TEST_KEEP_NATIVE=1 _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_not_exists "$STAMP" "a Stop whose grandparent is the launch's agy" || return 1
    rm -f "$RUN_DIR/native.pid"
    AGY_TEST_KEEP_NATIVE=1 _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_not_exists "$STAMP" "a Stop with no agy recorded" || return 1
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_file_exists "$STAMP" "a Stop from the launch's agy counts" || return 1
}

# Without the /clear route (an agy older than 1.5.10, or a plugin without its
# SessionStart entry), a /clear would leave the rotation behind.
test_a_run_without_the_clear_route_starts_no_count() {
    rm -f "$RUN_DIR/clear-rebind"
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_not_exists "$STAMP" "no clear-rebind mark" || return 1
    ln -s "$RUN_DIR/bound" "$RUN_DIR/clear-rebind"
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_not_exists "$STAMP" "a link at the mark is not the mark" || return 1
}

# No live watcher of this run's means nothing would type the keys.
test_a_turn_with_no_watcher_starts_no_count() {
    local dead case
    ( exit 0 ) & dead=$!; wait "$dead"
    for case in none dead other-run; do
        case "$case" in
            none) rm -f "$RUN_DIR/watcher.pid" ;;
            dead) printf '%s %s\n' "$dead" "$RUN" > "$RUN_DIR/watcher.pid" ;;
            other-run) printf '%s %s\n' "$$" "$OTHER_RUN" > "$RUN_DIR/watcher.pid" ;;
        esac
        _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
        assert_not_exists "$STAMP" "a count with watcher: $case" || return 1
    done
}

test_force_off_and_grace_zero_leave_the_clear_to_the_user() {
    local setting
    for setting in CS_ROTATE_FORCE_CTX=off CS_ROTATE_FORCE_CTX=0 CS_ANTIGRAVITY_CLEAR_GRACE=0; do
        ( export "${setting?}"; _agy_hook stop "$(_stop "$BOUND")" ) >/dev/null || return 1
        assert_not_exists "$STAMP" "a count with $setting" || return 1
    done
}

# The seconds are Antigravity's own setting, read as decimal; Codex's does
# not reach it.
test_the_grace_is_antigravitys_own() {
    local now deadline
    now=$(date +%s)
    CS_ANTIGRAVITY_CLEAR_GRACE=08 _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    deadline=$(_stamp_field deadline)
    [ "$deadline" -ge $((now + 8)) ] && [ "$deadline" -le $((now + 10)) ] \
        || { echo "  FAIL: a grace of 08 gave deadline $deadline from $now"; return 1; }
    rm -f "$STAMP" "$RUN_DIR/autoclear-counted"
    now=$(date +%s)
    CS_CODEX_CLEAR_GRACE=5 _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    deadline=$(_stamp_field deadline)
    [ "$deadline" -ge $((now + 20)) ] && [ "$deadline" -le $((now + 22)) ] \
        || { echo "  FAIL: Codex's grace reached Antigravity: deadline $deadline from $now"; return 1; }
}

# A forced second launch took the session over: this run's turn ends count
# nothing.
test_a_run_without_the_lease_starts_no_count() {
    local other
    sleep 30 & other=$!
    _lease "$OTHER_RUN" "$other"
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null
    local status=$?
    kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
    [ "$status" = 0 ] || { echo "  FAIL: a hook must never fail a turn"; return 1; }
    assert_not_exists "$STAMP" || return 1
}

test_nothing_armed_starts_no_count() {
    rm -f "$SESSION/.cs/local/pending-handoff"
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_not_exists "$STAMP" "nothing armed" || return 1
    _arm "$HANDOFF"
    _handoff "$HANDOFF" consumed
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_not_exists "$STAMP" "a consumed handoff" || return 1
}

# A switch this run recorded carries the armed handoff to the other engine,
# which a /clear would spend here; cs never types /exit for it either, so
# the switch's exit stays the user's. Another run's switch is not this run's.
test_a_pending_switch_starts_no_count() {
    printf 'engine=claude\nmode=fresh\nhandoff=%s\nrun=%s\nmodel=\neffort=\napproval=\n' "$HANDOFF" "$RUN" \
        > "$SESSION/.cs/local/pending-switch"
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_not_exists "$STAMP" "a count toward a switch" || return 1
    printf 'engine=claude\nmode=fresh\nhandoff=%s\nrun=%s\nmodel=\neffort=\napproval=\n' "$HANDOFF" "$OTHER_RUN" \
        > "$SESSION/.cs/local/pending-switch"
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_file_exists "$STAMP" "another run's switch is not this run's" || return 1
}

# The count runs once for each handoff: anything that starts a model call
# meanwhile, a message the user sends among them, stops it for good, and the
# /clear is then the user's. A handoff armed later gets its own count.
test_the_count_runs_once_per_handoff() {
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_file_exists "$STAMP" "the first turn end counts" || return 1
    _agy_hook pre-invocation "$(_pre "$BOUND" "stay here")" >/dev/null || return 1
    assert_not_exists "$STAMP" "the user's message stops it" || return 1
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_not_exists "$STAMP" "the same handoff counts once" || return 1
    _handoff "$OTHER_HANDOFF"
    _arm "$OTHER_HANDOFF"
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_file_exists "$STAMP" "a handoff armed later gets its own count" || return 1
    assert_eq "$OTHER_HANDOFF" "$(_stamp_field handoff)" || return 1
}

# A Stop that wakes the turn for mail continues it: no count.
test_a_mail_wake_starts_no_count() {
    local out
    out=$(AGY_TEST_STUB='_antigravity_hook_mail_wake() { ANTIGRAVITY_HOOK_REPLY="{\"decision\":\"continue\",\"reason\":\"mail\"}"; }' \
        _agy_hook stop "$(_stop "$BOUND")") || return 1
    assert_eq continue "$(printf '%s' "$out" | jq -r .decision)" "the wake answers as before" || return 1
    assert_not_exists "$STAMP" "a count on a turn that goes on" || return 1
}

# The deadline is the watcher's licence to type, so a run directory the
# agent can write is no place for it: here the cache lies under TMPDIR.
test_a_run_dir_the_agent_can_write_gets_no_count() {
    printf '%s' "$(_stop "$BOUND")" | env CS_RUN_ENGINE=antigravity CS_RUN_ID="$RUN" CS_RUN_OWNER_PID="$$" \
        CS_SESSION_DIR="$SESSION" CS_SESSION_NAME=demo "$CS_BIN" -antigravity-hook stop >/dev/null || return 1
    assert_not_exists "$STAMP" "a deadline under TMPDIR" || return 1
}

# --- the count, stopped by any hook of the run ---

# Every model call fires PreInvocation first, and every approval prompt comes
# from a model call, so any hook event of the run stops the count and the
# typing: the user's message, a subagent's call, a woken background task's,
# a new conversation's start, a finished tool, and a turn's end.
test_every_hook_event_of_the_run_stops_the_count_and_the_typing() {
    local case verb payload
    for case in typed subagent woken other-conversation session-start subagent-start tool stop; do
        case "$case" in
            typed) verb='pre-invocation'; payload=$(_pre "$BOUND" "a message") ;;
            subagent) verb='pre-invocation'; payload=$(_pre "$SUB" "" 0 0) ;;
            woken) verb='pre-invocation'; payload=$(_pre "$BOUND" "go" 0 10) ;;
            other-conversation) verb='pre-invocation'; payload=$(_pre "$CLEARED" "go" 0 1) ;;
            session-start) verb='session-start'; payload=$(printf '{"conversationId":"%s","lastUserInput":"go"}' "$CLEARED") ;;
            subagent-start) verb='session-start'; payload=$(printf '{"conversationId":"%s","lastUserInput":""}' "$SUB") ;;
            tool) verb='post-tool-use'; payload=$(printf '{"conversationId":"%s","toolCall":{"name":"run_command","args":{}}}' "$BOUND") ;;
            stop) verb='stop'; payload=$(_stop "$SUB") ;;
        esac
        _stale_stamp
        : > "$RUN_DIR/typing"
        _agy_hook "$verb" "$payload" >/dev/null || { echo "  FAIL: $case: a hook must never fail"; return 1; }
        assert_not_exists "$STAMP" "$case stops the count" || return 1
        assert_not_exists "$RUN_DIR/typing" "$case stops cs's typing" || return 1
    done
}

# A payload the hook cannot read still stops the count.
test_an_unreadable_payload_still_stops_the_count() {
    local verb
    for verb in pre-invocation session-start post-tool-use stop; do
        _stale_stamp
        : > "$RUN_DIR/typing"
        _agy_hook "$verb" 'not json' >/dev/null || return 1
        assert_not_exists "$STAMP" "$verb with an unreadable payload" || return 1
        assert_not_exists "$RUN_DIR/typing" || return 1
    done
}

test_a_newer_hook_prevents_an_older_stop_from_arming() {
    local stop_pid status=0 i
    export AGY_TEST_STOP_READY="$TEST_TMPDIR/stop-ready" AGY_TEST_STOP_RELEASE="$TEST_TMPDIR/stop-release"
    AGY_TEST_STUB='_antigravity_hook_mail_wake() {
        local i
        : > "$AGY_TEST_STOP_READY"
        for ((i = 0; i < 100; i++)); do
            [ ! -f "$AGY_TEST_STOP_RELEASE" ] || return 0
            sleep 0.1
        done
    }' _agy_hook stop "$(_stop "$BOUND")" >/dev/null &
    stop_pid=$!
    for ((i = 0; i < 40; i++)); do
        [ ! -f "$AGY_TEST_STOP_READY" ] || break
        sleep 0.1
    done
    if [ -f "$AGY_TEST_STOP_READY" ]; then
        AGY_TEST_KEEP_NATIVE=1 _agy_hook pre-invocation "$(_pre "$SUB")" >/dev/null || status=$?
    else
        echo "  FAIL: Stop did not reach the barrier"
        status=1
    fi
    : > "$AGY_TEST_STOP_RELEASE"
    wait "$stop_pid" || status=$?
    [ "$status" -eq 0 ] || return "$status"
    assert_not_exists "$STAMP" "a superseded Stop cannot publish a deadline" || return 1
    _agy_hook stop "$(_stop "$BOUND")" >/dev/null || return 1
    assert_file_exists "$STAMP" "a subsequent idle Stop can still count"
}

# Another run's hooks, and an agy cs did not launch, leave this run's count.
test_hooks_of_another_run_or_outside_a_run_leave_the_count() {
    _stale_stamp
    _agy_hook pre-invocation "$(_pre "$BOUND")" "$OTHER_RUN" >/dev/null || return 1
    assert_file_exists "$STAMP" "another run's model call" || return 1
    _agy_hook pre-invocation "$(_pre "$BOUND")" "$RUN" "" >/dev/null || return 1
    assert_file_exists "$STAMP" "an agy outside a cs run" || return 1
}

# auto_clear is claimed only in a run whose watcher lives, so the rotate
# skill promises the count only where cs will type.
test_auto_clear_is_claimed_only_while_the_watcher_lives() {
    _supports() {
        env CS_RUN_ENGINE=antigravity CS_RUN_ID="$RUN" CS_RUN_OWNER_PID="$$" CS_SESSION_DIR="$SESSION" \
            CS_SESSION_NAME=demo bash -c '
                eval "$(sed "\$d" "$1")"
                _codex_run_dir_in_sandbox_root() { return 1; }
                shift
                main "$@"' cs "$CS_BIN" -engine supports auto_clear >/dev/null 2>&1
    }
    _supports || { echo "  FAIL: a run with a live watcher does not claim auto_clear"; return 1; }
    rm -f "$RUN_DIR/watcher.pid"
    if _supports; then echo "  FAIL: auto_clear claimed with no watcher"; return 1; fi
    printf '%s %s\n' "$$" "$RUN" > "$RUN_DIR/watcher.pid"
    rm -f "$RUN_DIR/clear-rebind"
    if _supports; then echo "  FAIL: auto_clear claimed without the /clear route"; return 1; fi
    : > "$RUN_DIR/clear-rebind"
    if CS_ANTIGRAVITY_CLEAR_GRACE=0 _supports; then echo "  FAIL: auto_clear claimed with the count off"; return 1; fi
}

# --- the watcher, as the Antigravity launch runs it ---

# What the watcher types, one line per call, instead of the terminal; each
# look at the terminal marks a poll, so a test waits for polls, not seconds.
_watcher_stubs() {
    _codex_run_dir_in_sandbox_root() { return 1; }
    _codex_type_keys() { printf '%s\n' "$1" >> "$KEYS"; }
    _codex_autoclear_terminal() { printf 'poll\n' >> "$TEST_TMPDIR/polls"; [ ! -e "$TEST_TMPDIR/tty-closed" ]; }
}

_watch() {
    export CS_RUN_ID=$RUN CS_RUN_ENGINE=antigravity CS_RUN_OWNER_PID=$$
    (
        _watcher_stubs
        _codex_autoclear_watch "$SESSION" "$RUN_DIR" antigravity
    ) & WATCHER=$!
}

_polls() {  # n
    local i=0 n
    while :; do
        n=0
        [ ! -f "$TEST_TMPDIR/polls" ] || n=$(wc -l < "$TEST_TMPDIR/polls" | tr -d ' ')
        [ "$n" -le "$1" ] || return 0
        i=$((i + 1)); [ "$i" -lt 100 ] || { echo "  FAIL: the watcher never polled $1 times"; return 1; }
        sleep 0.1
    done
}

_keys_after() {  # seconds, lines
    local i=0
    while [ "$i" -lt $(( $1 * 10 )) ]; do
        [ -f "$KEYS" ] && [ "$(wc -l < "$KEYS" | tr -d ' ')" = "$2" ] && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}

test_the_watcher_types_clear_then_go_for_antigravity() {
    _stamp_at "$(date +%s)"
    _watch
    _keys_after 6 2 || { echo "  FAIL: expected two prompts, got: $(cat "$KEYS" 2>/dev/null)"; return 1; }
    assert_eq $'/clear\ngo' "$(cat "$KEYS")" || return 1
    assert_not_exists "$STAMP" "the deadline is consumed once" || return 1
}

test_the_watcher_leaves_a_stale_handoff_marker_untouched() {
    _arm "$OTHER_HANDOFF"
    _stale_stamp
    _watch
    _polls 2 || return 1
    assert_not_exists "$KEYS" "a stale marker does not license typing" || return 1
    assert_eq "$OTHER_HANDOFF" "$(cat "$SESSION/.cs/local/pending-handoff" 2>/dev/null)" \
        "the watcher only reads the pending marker"
}

test_the_watcher_refuses_a_replaced_vault_even_at_the_same_path() {
    local vault
    mkdir -p "$TEST_TMPDIR/vault/antigravity-home" || return 1
    vault=$(cd -P "$TEST_TMPDIR/vault" && pwd -P) || return 1
    ln -s "$vault" "$SESSION/.cs/private" || return 1
    printf '%s\n%s\n' "$vault/antigravity-home" "$(cs_dir_identity "$vault")" > "$RUN_DIR/vault"
    _stale_stamp

    mv "$vault" "$vault.before" || return 1
    mkdir -p "$vault/antigravity-home" "$vault/handoffs" || return 1
    cp "$SESSION/.cs/handoffs/$HANDOFF" "$vault/handoffs/$HANDOFF" || return 1
    printf '%s\n' "$HANDOFF" > "$vault/pending-handoff"

    _watch
    _polls 3 || return 1
    assert_not_exists "$KEYS" "matching names in a different vault cannot license typing" || return 1
    assert_file_exists "$vault/pending-handoff"
}

# A switch recorded during the count carries the handoff to the other engine:
# cs types neither /clear, which would spend it here, nor /exit, which is the
# user's to type.
test_a_switch_pending_at_the_deadline_types_nothing() {
    printf 'engine=claude\nmode=fresh\nhandoff=%s\nrun=%s\nmodel=\neffort=\napproval=auto\n' "$HANDOFF" "$RUN" \
        > "$SESSION/.cs/local/pending-switch"
    _stamp_at "$(date +%s)"
    _watch
    _polls 3 || return 1
    assert_not_exists "$KEYS" "keys typed: $(tr '\n' ' ' 2>/dev/null < "$KEYS")" || return 1
    assert_not_exists "$STAMP" "the deadline is spent all the same" || return 1
    assert_file_exists "$SESSION/.cs/local/pending-switch" "the switch stays for the user's /exit" || return 1
    assert_file_contains "$SESSION/.cs/local/session.log" \
        "Automatic /clear: a switch to claude (its default model, automatic approval) is pending, so cs typed nothing; /exit to take it, or cs -switch cancel to stay" || return 1
}

test_switch_cancels_between_clear_and_go() {
    local status=0 i
    _stale_stamp
    mkfifo "$TEST_TMPDIR/resume-watch" || return 1
    exec 8<>"$TEST_TMPDIR/resume-watch" || return 1
    _codex_run_dir_in_sandbox_root() { return 1; }
    export CS_RUN_ID=$RUN CS_RUN_ENGINE=antigravity CS_RUN_OWNER_PID=$$
    (
        _watcher_stubs
        sleep() {
            if [ "$1" = 2 ]; then
                : > "$TEST_TMPDIR/waiting-for-go"
                IFS= read -r -t 10 _ <&8
            else
                command sleep "$@"
            fi
        }
        _codex_autoclear_watch "$SESSION" "$RUN_DIR" antigravity
    ) & WATCHER=$!
    for ((i = 0; i < 50; i++)); do
        [ ! -f "$TEST_TMPDIR/waiting-for-go" ] || break
        sleep 0.1
    done
    if [ -f "$TEST_TMPDIR/waiting-for-go" ]; then
        CS_SESSION_DIR="$SESSION" CS_SESSION_NAME=demo CS_INSTALL_DIR="$TEST_TMPDIR" \
            CODEX_BIN=/usr/bin/true cmd_switch codex >/dev/null || status=$?
    else
        echo "  FAIL: watcher did not reach the pause after /clear"
        status=1
    fi
    printf 'resume\n' >&8
    exec 8>&-
    [ "$status" -eq 0 ] || return "$status"
    _polls 3 || return 1
    assert_eq '/clear' "$(cat "$KEYS")" "the switch interrupts the clear before go" || return 1
    assert_file_exists "$SESSION/.cs/local/pending-switch"
}

test_typist_checks_cancellation_under_the_antigravity_lock() {
    local lock="$RUN_DIR/autoclear.lock" typing="$RUN_DIR/typing" pid status=0 i
    printf '12345\n' > "$typing"
    printf '12345\n' > "$RUN_DIR/autoclear-generation"
    printf '%s\n' "$$" > "$RUN_DIR/native.pid"
    _cs_lock "$lock" || return 1
    ( exec 9>&-; CS_CODEX_TYPE_SINK="$KEYS" _codex_type_keys /clear "$typing" "$RUN_DIR/native.pid" "$lock" ) &
    pid=$!
    for ((i = 0; i < 30; i++)); do
        [ ! -f "$KEYS" ] || break
        sleep 0.1
    done
    sleep 0.2
    rm -f "$typing"
    _cs_unlock "$lock"
    wait "$pid" || status=$?
    assert_eq 4 "$status" "the typist reports cancellation" || return 1
    assert_file_exists "$KEYS" "the typist reached its sink" || return 1
    assert_eq '' "$(cat "$KEYS")" "no key can go in while cancellation holds the lock"
}

test_a_gone_agy_is_named_in_the_log() {
    _stamp_at "$(date +%s)"
    _watcher_stubs
    _codex_type_keys() { printf '%s\n' "$1" >> "$KEYS"; return 3; }
    export CS_RUN_ID=$RUN CS_RUN_ENGINE=antigravity CS_RUN_OWNER_PID=$$
    _codex_autoclear_watch "$SESSION" "$RUN_DIR" antigravity & WATCHER=$!
    _keys_after 6 1 || { echo "  FAIL: the typist never ran"; return 1; }
    _polls 3 || return 1
    assert_file_contains "$SESSION/.cs/local/session.log" \
        "Automatic /clear: Antigravity had already exited; nothing more typed" || return 1
}

test_autoclear_diagnostics_do_not_follow_a_link_outside_the_session() {
    local log="$TEST_TMPDIR/unrelated.log"
    printf '%s\n' 'unrelated log' > "$log"
    ln -s "$log" "$SESSION/.cs/local/session.log" || return 1

    _codex_autoclear_log "$SESSION" 'Automatic /clear: test diagnostic'
    assert_eq 'unrelated log' "$(cat "$log")" "the outside log is untouched"
}

run_test test_an_idle_turn_end_with_a_handoff_armed_starts_the_count
run_test test_a_turn_end_with_work_still_running_starts_no_count
run_test test_a_turn_that_did_not_end_normally_starts_no_count
run_test test_a_turn_of_another_conversation_starts_no_count
run_test test_a_turn_end_from_another_agy_starts_no_count
run_test test_a_run_without_the_clear_route_starts_no_count
run_test test_a_turn_with_no_watcher_starts_no_count
run_test test_force_off_and_grace_zero_leave_the_clear_to_the_user
run_test test_the_grace_is_antigravitys_own
run_test test_a_run_without_the_lease_starts_no_count
run_test test_nothing_armed_starts_no_count
run_test test_a_pending_switch_starts_no_count
run_test test_the_count_runs_once_per_handoff
run_test test_a_mail_wake_starts_no_count
run_test test_a_run_dir_the_agent_can_write_gets_no_count
run_test test_every_hook_event_of_the_run_stops_the_count_and_the_typing
run_test test_an_unreadable_payload_still_stops_the_count
run_test test_a_newer_hook_prevents_an_older_stop_from_arming
run_test test_hooks_of_another_run_or_outside_a_run_leave_the_count
run_test test_auto_clear_is_claimed_only_while_the_watcher_lives
run_test test_the_watcher_types_clear_then_go_for_antigravity
run_test test_the_watcher_leaves_a_stale_handoff_marker_untouched
run_test test_the_watcher_refuses_a_replaced_vault_even_at_the_same_path
run_test test_a_switch_pending_at_the_deadline_types_nothing
run_test test_switch_cancels_between_clear_and_go
run_test test_typist_checks_cancellation_under_the_antigravity_lock
run_test test_a_gone_agy_is_named_in_the_log
run_test test_autoclear_diagnostics_do_not_follow_a_link_outside_the_session

report_results
