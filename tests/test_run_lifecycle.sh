#!/usr/bin/env bash
# ABOUTME: Shared lease contract: contention, forced successors, hooks, and supervision.
# ABOUTME: Uses a fake adapter and real child processes without native runtimes.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/15-lock.sh"
source "$SCRIPT_DIR/../lib/16-lifecycle.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../hooks/cs-resolve.sh"

cs_interactive() { return 1; }
warn() { printf '%s\n' "$*" >&2; }

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export HOME="$TEST_TMPDIR/home"
    export CS_TEST_SESSION_DIR="$TEST_TMPDIR/session"
    export CS_TEST_SOURCE_DIR="$SCRIPT_DIR/.."
    export CS_TEST_WORKER="$TEST_TMPDIR/worker"
    mkdir -p "$HOME" "$CS_TEST_SESSION_DIR/.cs/local"
    unset CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_LEAD_PID CLAUDE_PID
    cat > "$TEST_TMPDIR/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
source "$CS_TEST_SOURCE_DIR/lib/15-lock.sh"
source "$CS_TEST_SOURCE_DIR/lib/16-lifecycle.sh"
source "$CS_TEST_SOURCE_DIR/lib/40-state.sh"
cs_interactive() { return 1; }
warn() { printf '%s\n' "$*" >&2; }
_set_local_state() { printf '%s: %s\n' "$2" "$3" >> "$1"; }
cs_engine_call() {
    printf '%s\n' "$CS_RUN_ID" > "$CS_TEST_SESSION_DIR/run-id"
    cs_run_child "$CS_TEST_WORKER"
}
cs_launch_session claude demo "$CS_TEST_SESSION_DIR" false "${CS_TEST_FORCE:-false}" '' auto
DRIVER
    cat > "$CS_TEST_WORKER" <<'WORKER'
#!/usr/bin/env bash
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
source "$CS_TEST_SOURCE_DIR/hooks/cs-resolve.sh"
CLAUDE_PID=$$
# SessionStart establishes the native lead claim before other hooks inspect it.
if [ "${CS_TEST_LEGACY_LEAD:-0}" = 1 ]; then
    unset CS_LEAD_CLAIM
else
    export CS_LEAD_CLAIM=1
    cs_lead_claim "$CS_SESSION_META_DIR/local" test-session
fi
if cs_is_lead; then printf 'lead\n' > "$CS_TEST_SESSION_DIR/lead"; fi
printf '%s\n' "$$" > "$CS_TEST_SESSION_DIR/child-pid"
printf '%s\n' "$CS_RUN_ID" > "$CS_TEST_SESSION_DIR/child-run-id"
[ "${CS_TEST_STAY:-0}" = 1 ] || exit "${CS_TEST_EXIT:-0}"
trap 'exit 0' TERM
while :; do sleep 0.05; done
WORKER
    chmod +x "$TEST_TMPDIR/driver" "$CS_TEST_WORKER"
}

teardown() {
    if [ -s "$CS_TEST_SESSION_DIR/child-pid" ]; then
        kill -TERM "$(cat "$CS_TEST_SESSION_DIR/child-pid")" 2>/dev/null || true
    fi
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$TEST_TMPDIR"
    unset CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_LEAD_PID CLAUDE_PID
    unset CS_TEST_STAY CS_TEST_EXIT CS_TEST_FORCE
}

_wait_for_file() {
    local n=0
    while [ "$n" -lt 100 ]; do
        [ ! -s "$1" ] || return 0
        sleep 0.05
        n=$((n + 1))
    done
    printf 'File did not appear: %s\n' "$1" >&2
    return 1
}

_test_lease() {
    export CS_RUN_ID="$1" CS_RUN_ENGINE=claude CS_RUN_OWNER_PID="$$"
    export CS_LEAD_PID="$$" CLAUDE_PID="$$"
    export CS_SESSION_META_DIR="$CS_TEST_SESSION_DIR/.cs"
}

test_shared_exit_status_and_cleanup() {
    local status=0
    CS_TEST_EXIT=17 "$TEST_TMPDIR/driver" || status=$?
    assert_eq 17 "$status" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/lead" lead "supervised native child is the lead" || return 1
    assert_eq "$(cat "$CS_TEST_SESSION_DIR/run-id")" "$(cat "$CS_TEST_SESSION_DIR/child-run-id")" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/run-lease.json" || return 1
}

# An installed hook can change while a launcher from the previous fork is
# still running. That launcher recorded its native PID and start time, but
# predates CS_LEAD_CLAIM; the new hooks must still recognize its native lead.
test_pre_claim_launcher_keeps_its_native_lead_after_upgrade() {
    CS_TEST_LEGACY_LEAD=1 "$TEST_TMPDIR/driver" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/lead" lead "the old launch retains its native lead"
}

test_pre_claim_lease_checks_native_identity_on_every_call() {
    local meta="$CS_TEST_SESSION_DIR/.cs" child other status=0 CS_LEAD_CLAIM=""
    _test_lease old-launch
    acquire_session_lock "$meta" false demo || return 1
    sleep 300 &
    child=$!
    _cs_run_record_child "$meta" "$child" || { kill "$child"; return 1; }
    CLAUDE_PID="$child"
    _CS_IS_LEAD=""
    cs_is_lead || status=1
    # Same PID, another process start: a stale memo must not keep ownership.
    jq '.native_started = "another process"' "$meta/local/run-lease.json" > "$meta/local/lease-test.tmp"
    mv "$meta/local/lease-test.tmp" "$meta/local/run-lease.json"
    if cs_is_lead; then status=1; fi
    # Another child inherits the token, but the lease does not name its PID.
    sleep 300 &
    other=$!
    CLAUDE_PID="$other"
    _CS_IS_LEAD=""
    if cs_is_lead; then status=1; fi
    kill "$child" "$other" 2>/dev/null; wait "$child" 2>/dev/null || true
    wait "$other" 2>/dev/null || true
    release_session_lock "$meta"
    assert_eq 0 "$status" "only the recorded native process with its original start owns the old launch"
}

test_terminal_stdin_reaches_child() {
    cat > "$CS_TEST_WORKER" <<'WORKER'
#!/usr/bin/env bash
IFS= read -r line
printf '%s\n' "$line" > "$CS_TEST_SESSION_DIR/stdin"
WORKER
    printf 'interactive input\n' | "$TEST_TMPDIR/driver"
    assert_file_contains "$CS_TEST_SESSION_DIR/stdin" 'interactive input'
}

test_competing_launch_cannot_steal_lease() {
    CS_TEST_STAY=1 "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/first.log" 2>&1 &
    local launcher=$! status=0 old_id
    _wait_for_file "$CS_TEST_SESSION_DIR/child-pid" || return 1
    old_id=$(cat "$CS_TEST_SESSION_DIR/run-id")
    "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/second.log" 2>&1 || status=$?
    assert_eq 1 "$status" || return 1
    assert_eq "$launcher" "$(cat "$CS_TEST_SESSION_DIR/.cs/session.lock")" || return 1
    assert_eq "$old_id" "$(jq -r .run_id "$CS_TEST_SESSION_DIR/.cs/local/run-lease.json")" || return 1
    kill -TERM "$launcher"
    wait "$launcher" || true
}

test_force_successor_rejects_old_cleanup_and_binding_writer() {
    local meta="$CS_TEST_SESSION_DIR/.cs" status=0
    _test_lease old-run
    acquire_session_lock "$meta" false demo
    _test_lease successor-run
    acquire_session_lock "$meta" true demo
    _test_lease old-run
    release_session_lock "$meta"
    assert_exists "$meta/session.lock" || return 1
    assert_eq successor-run "$(jq -r .run_id "$meta/local/run-lease.json")" || return 1
    cs_run_with_lease "$meta" touch "$TEST_TMPDIR/stale-write" || status=$?
    [ "$status" -ne 0 ] || return 1
    assert_not_exists "$TEST_TMPDIR/stale-write" || return 1
    _CS_IS_LEAD=''
    if cs_is_lead; then echo 'stale token incorrectly owns the lead'; return 1; fi
    _test_lease successor-run
    release_session_lock "$meta"
    assert_not_exists "$meta/session.lock"
}

test_inherited_token_does_not_make_headless_child_lead() {
    local meta="$CS_TEST_SESSION_DIR/.cs" probe="$TEST_TMPDIR/lead-probe"
    _test_lease current-run
    acquire_session_lock "$meta" false demo
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
source "$CS_TEST_SOURCE_DIR/hooks/cs-resolve.sh"
# This shell stands in for the Bash tool. Its child stands in for claude -p.
bash -c 'source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"; source "$CS_TEST_SOURCE_DIR/hooks/cs-resolve.sh"; CLAUDE_PID=$$; if cs_is_lead; then exit 1; else exit 0; fi'
PROBE
    bash "$probe" || return 1
    release_session_lock "$meta"
}

test_session_end_keeps_modern_lease_during_clear() {
    local meta="$CS_TEST_SESSION_DIR/.cs"
    _test_lease current-run
    acquire_session_lock "$meta" false demo
    mkdir -p "$TEST_TMPDIR/hooks"
    cp "$SCRIPT_DIR/../hooks/session-end.sh" "$SCRIPT_DIR/../hooks/cs-resolve.sh" "$TEST_TMPDIR/hooks/"
    cp "$SCRIPT_DIR/../lib/02-shared.sh" "$TEST_TMPDIR/hooks/cs-shared.sh"
    printf '{"session_id":"12345678-1234-1234-1234-123456789abc","reason":"clear"}\n' | \
        CLAUDE_SESSION_NAME=demo CLAUDE_SESSION_DIR="$CS_TEST_SESSION_DIR" \
        CLAUDE_SESSION_META_DIR="$meta" bash "$TEST_TMPDIR/hooks/session-end.sh"
    assert_exists "$meta/session.lock" || return 1
    assert_eq current-run "$(jq -r .run_id "$meta/local/run-lease.json")" || return 1
    release_session_lock "$meta"
}

test_term_stops_child_before_releasing_lease() {
    CS_TEST_STAY=1 "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/launch.log" 2>&1 &
    local launcher=$! child status=0
    _wait_for_file "$CS_TEST_SESSION_DIR/child-pid" || return 1
    child=$(cat "$CS_TEST_SESSION_DIR/child-pid")
    kill -TERM "$launcher"
    wait "$launcher" || status=$?
    assert_eq 143 "$status" || return 1
    if kill -0 "$child" 2>/dev/null; then echo 'native child survived TERM cleanup'; return 1; fi
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/run-lease.json"
}

test_guard_is_held_across_callback_and_recovers_after_exit() {
    cat > "$TEST_TMPDIR/guard-holder" <<'HOLDER'
#!/usr/bin/env bash
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
callback() { printf 'ready\n' > "$CS_TEST_SESSION_DIR/guard-ready"; sleep 0.4; }
cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" callback
HOLDER
    bash "$TEST_TMPDIR/guard-holder" &
    local holder=$! status=0
    _wait_for_file "$CS_TEST_SESSION_DIR/guard-ready" || return 1
    local guard="$CS_TEST_SESSION_DIR/.cs/local/run-lease.guard"
    if command -v flock >/dev/null 2>&1; then
        flock -n "$guard" true || status=$?
    else
        lockf -s -k -t 0 "$guard" true || status=$?
    fi
    [ "$status" -ne 0 ] || { echo 'second process acquired active guard'; return 1; }
    wait "$holder"
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/after-guard"
    assert_exists "$TEST_TMPDIR/after-guard"
}

test_killed_launcher_keeps_surviving_native_excluded() {
    CS_TEST_STAY=1 "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/launch.log" 2>&1 &
    local launcher=$! child status=0 n=0
    _wait_for_file "$CS_TEST_SESSION_DIR/child-pid" || return 1
    child=$(cat "$CS_TEST_SESSION_DIR/child-pid")
    kill -KILL "$launcher"
    wait "$launcher" 2>/dev/null || true
    kill -0 "$child" 2>/dev/null || { echo 'orphan fixture exited unexpectedly'; return 1; }
    session_is_live "$CS_TEST_SESSION_DIR/.cs" || { echo 'orphan native child not counted live'; return 1; }
    "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/second.log" 2>&1 || status=$?
    assert_eq 1 "$status" "orphan child must block new unforced launch" || return 1
    kill -TERM "$child"
    while kill -0 "$child" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
    if kill -0 "$child" 2>/dev/null; then echo 'orphan worker did not stop'; return 1; fi
    "$TEST_TMPDIR/driver" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock"
}

test_term_escalates_when_native_ignores_it() {
    cat > "$CS_TEST_WORKER" <<'WORKER'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$CS_TEST_SESSION_DIR/child-pid"
while :; do sleep 0.05; done
WORKER
    "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/launch.log" 2>&1 &
    local launcher=$! child status=0 started=$SECONDS
    _wait_for_file "$CS_TEST_SESSION_DIR/child-pid" || return 1
    child=$(cat "$CS_TEST_SESSION_DIR/child-pid")
    kill -TERM "$launcher"
    wait "$launcher" || status=$?
    assert_eq 143 "$status" || return 1
    [ "$((SECONDS - started))" -lt 12 ] || { echo 'TERM escalation exceeded bound'; return 1; }
    if kill -0 "$child" 2>/dev/null; then echo 'TERM-ignoring native survived escalation'; return 1; fi
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock"
}

test_guard_released_when_holding_shell_is_killed() {
    cat > "$TEST_TMPDIR/guard-holder" <<'HOLDER'
#!/usr/bin/env bash
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
callback() {
    # $$ remains the parent PID in Bash3 subshells. A child's PPID identifies
    # the actual guard holder without requiring a process-table probe.
    sh -c 'echo "$PPID"' > "$CS_TEST_SESSION_DIR/guard-pid"
    exec 8<> "$CS_TEST_SESSION_DIR/guard-fifo"
    IFS= read -r line <&8
}
cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" callback
HOLDER
    mkfifo "$CS_TEST_SESSION_DIR/guard-fifo"
    bash "$TEST_TMPDIR/guard-holder" > "$TEST_TMPDIR/guard.log" 2>&1 &
    local holder=$! guard_pid
    _wait_for_file "$CS_TEST_SESSION_DIR/guard-pid" || return 1
    guard_pid=$(cat "$CS_TEST_SESSION_DIR/guard-pid")
    kill -KILL "$guard_pid"
    wait "$holder" 2>/dev/null || true
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/after-kill"
    assert_exists "$TEST_TMPDIR/after-kill"
}

# The session directory is the agent's to write, so a link may wait at the
# guard path. Following it would truncate, or create, a file the agent could
# not write itself; cs refuses the guard instead and runs nothing.
test_guard_refuses_a_planted_link_and_leaves_its_target() {
    local guard="$CS_TEST_SESSION_DIR/.cs/local/run-lease.guard" status=0
    printf 'precious\n' > "$TEST_TMPDIR/victim"
    ln -s "$TEST_TMPDIR/victim" "$guard"
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/ran" 2> "$TEST_TMPDIR/err" || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: a linked guard was used'; return 1; }
    assert_eq precious "$(cat "$TEST_TMPDIR/victim")" "the link's target keeps its bytes" || return 1
    assert_not_exists "$TEST_TMPDIR/ran" "the callback does not run" || return 1
    assert_file_contains "$TEST_TMPDIR/err" 'run-lease.guard is not a regular file' || return 1
    rm "$guard"
    ln -s "$TEST_TMPDIR/absent" "$guard"
    status=0
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/ran" 2> /dev/null || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: a dangling guard link was used'; return 1; }
    assert_not_exists "$TEST_TMPDIR/absent" "a dangling link's target is not created" || return 1
    assert_not_exists "$TEST_TMPDIR/ran" "the callback does not run"
}

_guarded_touch_bounded() {  # file to touch
    _run_bounded 5 bash -c 'source "$1/lib/02-shared.sh"; cs_run_guarded "$2" touch "$3"' _ \
        "$CS_TEST_SOURCE_DIR" "$CS_TEST_SESSION_DIR/.cs" "$1" 2> /dev/null
}

# Opening a fifo for writing waits for a reader, so a planted fifo would stall
# every ownership change; a directory cannot be locked as a file.
test_guard_refuses_a_fifo_or_directory_without_hanging() {
    local guard="$CS_TEST_SESSION_DIR/.cs/local/run-lease.guard" status=0
    mkfifo "$guard"
    _guarded_touch_bounded "$TEST_TMPDIR/ran" || status=$?
    [ "$status" -ne 142 ] || { echo '  FAIL: a fifo guard hung the open'; return 1; }
    [ "$status" -ne 0 ] || { echo '  FAIL: a fifo guard was used'; return 1; }
    assert_not_exists "$TEST_TMPDIR/ran" "the callback does not run on a fifo" || return 1
    rm "$guard"
    mkdir "$guard"
    status=0
    _guarded_touch_bounded "$TEST_TMPDIR/ran" || status=$?
    [ "$status" -ne 142 ] || { echo '  FAIL: a directory guard hung the open'; return 1; }
    [ "$status" -ne 0 ] || { echo '  FAIL: a directory guard was used'; return 1; }
    assert_not_exists "$TEST_TMPDIR/ran" "the callback does not run on a directory"
}

# Arm a DEBUG trap that swaps <guard> for a link to <target> just before
# cs_run_guarded runs <command>, by default its `umask 077`, after its type
# check and before it creates or opens the guard; `umask "$mask"` comes after
# the create and before the open. The race a sandboxed agent could run
# against cs. Call it in a subshell.
_swap_guard_for_link_before_the_open() {  # guard, target, [command]
    SWAP_GUARD="$1" SWAP_TARGET="$2" SWAP_BEFORE="${3:-umask 077}"
    set -o functrace
    trap '[ "$BASH_COMMAND" != "$SWAP_BEFORE" ] || { rm -f "$SWAP_GUARD"; ln -s "$SWAP_TARGET" "$SWAP_GUARD"; }' DEBUG
}

# A link swapped in after the type check is caught after the open: an existing
# target is opened without a byte written, a dangling link's target is never
# created, whether the guard was there or this call creates it, and the guard
# is refused.
test_guard_refuses_a_link_swapped_in_after_the_type_check() {
    local guard="$CS_TEST_SESSION_DIR/.cs/local/run-lease.guard" status=0
    printf 'precious\n' > "$TEST_TMPDIR/victim"
    : > "$guard"
    (
        _swap_guard_for_link_before_the_open "$guard" "$TEST_TMPDIR/victim"
        cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/ran"
    ) 2> "$TEST_TMPDIR/err" || status=$?
    assert_symlink "$guard" "the seam swapped a link in" || return 1
    [ "$status" -ne 0 ] || { echo '  FAIL: a guard swapped for a link was used'; return 1; }
    assert_eq precious "$(cat "$TEST_TMPDIR/victim")" "the link's target keeps its bytes" || return 1
    assert_not_exists "$TEST_TMPDIR/ran" "the callback does not run" || return 1
    assert_file_contains "$TEST_TMPDIR/err" 'run-lease.guard is not a regular file' || return 1
    _swapped_dangling_link_creates_nothing "$guard" present || return 1
    _swapped_dangling_link_creates_nothing "$guard" absent || return 1
    # shellcheck disable=SC2016  # the command as the DEBUG trap sees it, unexpanded
    _swapped_dangling_link_creates_nothing "$guard" present 'umask "$mask"'
}

_swapped_dangling_link_creates_nothing() {  # guard, present|absent before the call, [command]
    local status=0 case="$2 guard${3:+, before $3}"
    rm -f "$1" "$TEST_TMPDIR/absent" "$TEST_TMPDIR/ran"
    [ "$2" = absent ] || : > "$1"
    (
        _swap_guard_for_link_before_the_open "$1" "$TEST_TMPDIR/absent" "${3:-}"
        cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/ran"
    ) 2> /dev/null || status=$?
    assert_symlink "$1" "the seam swapped a dangling link in ($case)" || return 1
    [ "$status" -ne 0 ] || { echo "  FAIL: a guard swapped for a dangling link was used ($case)"; return 1; }
    assert_not_exists "$TEST_TMPDIR/absent" "a dangling link's target is not created ($case)" || return 1
    assert_not_exists "$TEST_TMPDIR/ran" "the callback does not run ($case)"
}

_inode() { ls -di "$1" | awk '{print $1}'; }

# Every waiter must lock one persistent inode, and opening it never truncates:
# the file cs locks is never rewritten, only created, private, when absent.
test_guard_keeps_its_inode_and_bytes_across_calls() {
    local guard="$CS_TEST_SESSION_DIR/.cs/local/run-lease.guard" before
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" true || return 1
    assert_eq 600 "$(_file_mode "$guard")" "a new guard is private" || return 1
    printf 'kept\n' > "$guard"
    before=$(_inode "$guard")
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/ran" || return 1
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" true || return 1
    assert_exists "$TEST_TMPDIR/ran" "the callback runs on a regular guard" || return 1
    assert_eq "$before" "$(_inode "$guard")" "the guard keeps its inode" || return 1
    assert_eq kept "$(cat "$guard")" "the guard is opened without truncation"
}

# The check after the open: fd 9 must be the regular file the path names. A
# link, a fifo or another file swapped in between the type check and the open
# is refused. Without perl the type checks still refuse a link and a fifo.
# The cases open fd 9 in a subshell, so the suite's own descriptors stay put.
test_guard_open_check_needs_the_file_the_path_names() {
    ( _guard_open_check_cases )
}

# PATH is assigned in a subshell, not prefixed to the call: through a prefixed
# PATH, bash 3.2's command -v still finds the perl it hashed, which then fails
# to run.
_fd9_is_file_without_perl() (  # path
    # shellcheck disable=SC2123  # a PATH without perl is the point
    PATH="$TEST_TMPDIR/no-perl"
    _cs_fd9_is_file "$1"
)

_guard_open_check_cases() {
    local dir="$TEST_TMPDIR/fd" status=0
    mkdir "$dir" "$TEST_TMPDIR/no-perl"
    : > "$dir/a"
    : > "$dir/b"
    ln -s a "$dir/link"
    mkfifo "$dir/fifo"
    exec 9<> "$dir/a"
    _cs_fd9_is_file "$dir/a" || { echo '  FAIL: the open file itself was refused'; status=1; }
    if _cs_fd9_is_file "$dir/b"; then echo '  FAIL: another regular file was accepted'; status=1; fi
    if _cs_fd9_is_file "$dir/link"; then echo '  FAIL: a link to the open file was accepted'; status=1; fi
    _fd9_is_file_without_perl "$dir/a" || { echo '  FAIL: no perl: the open file was refused'; status=1; }
    if _fd9_is_file_without_perl "$dir/link"; then echo '  FAIL: no perl: a link was accepted'; status=1; fi
    if _fd9_is_file_without_perl "$dir/fifo"; then echo '  FAIL: no perl: a fifo path was accepted'; status=1; fi
    mv "$dir/a" "$dir/a.old"
    : > "$dir/a"
    if _cs_fd9_is_file "$dir/a"; then echo '  FAIL: a replaced path was accepted'; status=1; fi
    exec 9<> "$dir/fifo"
    if _cs_fd9_is_file "$dir/fifo"; then echo '  FAIL: a fifo was accepted'; status=1; fi
    if _fd9_is_file_without_perl "$dir/fifo"; then echo '  FAIL: no perl: a fifo was accepted'; status=1; fi
    # The fifo opened, then a regular file put back at its path.
    rm "$dir/fifo"
    : > "$dir/fifo"
    if _cs_fd9_is_file "$dir/fifo"; then echo '  FAIL: an open fifo was accepted'; status=1; fi
    if _fd9_is_file_without_perl "$dir/fifo"; then echo '  FAIL: no perl: an open fifo was accepted'; status=1; fi
    exec 9<&-
    if _cs_fd9_is_file "$dir/a"; then echo '  FAIL: a closed descriptor was accepted'; status=1; fi
    return "$status"
}

run_test test_shared_exit_status_and_cleanup
run_test test_pre_claim_launcher_keeps_its_native_lead_after_upgrade
run_test test_pre_claim_lease_checks_native_identity_on_every_call
run_test test_terminal_stdin_reaches_child
run_test test_competing_launch_cannot_steal_lease
run_test test_force_successor_rejects_old_cleanup_and_binding_writer
run_test test_inherited_token_does_not_make_headless_child_lead
run_test test_session_end_keeps_modern_lease_during_clear
run_test test_term_stops_child_before_releasing_lease
run_test test_guard_is_held_across_callback_and_recovers_after_exit
run_test test_killed_launcher_keeps_surviving_native_excluded
run_test test_term_escalates_when_native_ignores_it
run_test test_guard_released_when_holding_shell_is_killed
run_test test_guard_refuses_a_planted_link_and_leaves_its_target
run_test test_guard_refuses_a_fifo_or_directory_without_hanging
run_test test_guard_refuses_a_link_swapped_in_after_the_type_check
run_test test_guard_keeps_its_inode_and_bytes_across_calls
run_test test_guard_open_check_needs_the_file_the_path_names
report_results
