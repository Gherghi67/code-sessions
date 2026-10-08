#!/usr/bin/env bash
# ABOUTME: Tests for cs -spawn: validation, seed staging, tmux window wiring,
# ABOUTME: launch-path seed consumption, and the spawned-by drain notify.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_BIN="$SCRIPT_DIR/../bin/cs"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
# Hooks resolve `cs` via PATH (the drain notify calls it); point them at the
# repo build for the whole suite.
export PATH="$SCRIPT_DIR/../bin:$PATH"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
    export CLAUDE_CODE_BIN="echo"
    # The attach hint keys on $TMUX; unset it so the baseline is deterministic
    # regardless of whether the suite itself runs inside tmux.
    unset TMUX 2>/dev/null || true
    # Recording tmux fake: logs argv, one call per line; behavior driven by
    # state files in $TEST_TMPDIR/tmux-state (see comments inside).
    export CS_TMUX_BIN="$TEST_TMPDIR/fake-tmux"
    export FAKE_TMUX_DIR="$TEST_TMPDIR/tmux-state"
    mkdir -p "$FAKE_TMUX_DIR"
    cat > "$CS_TMUX_BIN" << 'FAKE'
#!/usr/bin/env bash
# Fake tmux: append argv to log; simulate state via files in $FAKE_TMUX_DIR.
#   has-session  -> exit 0 iff $FAKE_TMUX_DIR/session-exists exists
#   new-session  -> creates session-exists (fails if $FAKE_TMUX_DIR/race);
#                   with -P prints @0
#   set-option   -> records @cs_managed into $FAKE_TMUX_DIR/managed
#   show-option  -> prints contents of $FAKE_TMUX_DIR/managed (if any)
#   list-windows -> prints lines of $FAKE_TMUX_DIR/windows (if any)
#   new-window   -> with -P prints @7
printf '%s\n' "$*" >> "$FAKE_TMUX_DIR/log"
case "$1" in
    has-session)  [ -f "$FAKE_TMUX_DIR/session-exists" ]; exit $? ;;
    new-session)  # real tmux rejects a duplicate -s name; model that too
                  if [ -f "$FAKE_TMUX_DIR/race" ] || [ -f "$FAKE_TMUX_DIR/session-exists" ]; then exit 1; fi
                  touch "$FAKE_TMUX_DIR/session-exists"
                  case "$*" in *" -P "*) echo '@0';; esac ;;
    # tmux 3.6a rejects '='-anchored targets on the options commands (verified
    # live 2026-07-18: "no such session: =cs"); model that so the suite pins
    # the plain-target requirement for these two.
    set-option)   case "$*" in *"-t =cs"*) echo "no such session: =cs" >&2; exit 1;; esac
                  printf '1\n' > "$FAKE_TMUX_DIR/managed" ;;
    show-option)  case "$*" in *"-t =cs"*) echo "no such session: =cs" >&2; exit 1;; esac
                  [ -f "$FAKE_TMUX_DIR/managed" ] && cat "$FAKE_TMUX_DIR/managed" ;;
    list-windows) [ -f "$FAKE_TMUX_DIR/windows" ] && cat "$FAKE_TMUX_DIR/windows" ;;
    new-window)   case "$*" in *" -P "*) echo '@7';; esac ;;
esac
exit 0
FAKE
    chmod +x "$CS_TMUX_BIN"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TMUX_BIN FAKE_TMUX_DIR 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

SEED() { printf '%s' "$CS_SESSIONS_ROOT/.spawn/worker.seed"; }
BRIEF() { printf '%s' "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"; }

# A seed as cs -spawn writes it: line 1 is the token the spawn's own tmux
# window carries in CS_SPAWN_TOKEN, line 2 the spawner, then one task per
# line. An open that carries the token is the spawn's own window and consumes
# the seed unasked; any other open is shown the seed and asked.
OWN_TOKEN=0123456789abcdef0123456789abcdef
_stage_seed() {  # spawner, tasks...
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    local spawner="$1" t
    shift
    { printf '%s\n%s\n' "$OWN_TOKEN" "$spawner"
      for t in "$@"; do printf '%s\n' "$t"; done
    } > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
}

test_spawn_rejects_bad_names_and_missing_tmux() {
    ! "$CS_BIN" -spawn "bad name" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -spawn "../x" >/dev/null 2>&1 || return 1
    ! CS_TMUX_BIN=/nonexistent/tmux "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_rejects_live_target() {
    create_test_session worker >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs"
    printf '%s\n' "$$" > "$CS_SESSIONS_ROOT/worker/.cs/session.lock"
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_writes_seed_and_opens_window() {
    local out
    out=$(CLAUDE_SESSION_NAME="boss" "$CS_BIN" -spawn worker \
        --task "first job" --task "second job" 2>&1) || return 1
    assert_file_exists "$(SEED)" "seed written" || return 1
    local tok; tok="$(sed -n 1p "$(SEED)")"
    printf '%s' "$tok" | grep -Eq '^[0-9a-f]{32}$' || { echo "  line 1 is not a 32-hex token: '$tok'"; return 1; }
    assert_eq "boss" "$(sed -n 2p "$(SEED)")" "line 2 is spawner" || return 1
    assert_eq "first job" "$(sed -n 3p "$(SEED)")" "task order kept" || return 1
    assert_eq "second job" "$(sed -n 4p "$(SEED)")" "second task" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "'CS_SPAWN_TOKEN=$tok'" "the window command carries the seed's token" || return 1
    assert_output_contains "$out" "@0" "window id echoed" || return 1
    assert_output_contains "$out" "tmux attach -t cs" "attach hint" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-session -d -s cs" "created cs session" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "set-option -t cs @cs_managed 1" "ownership stamped" || return 1
}

test_spawn_tmux_targets_are_exact_match_anchored() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    # Resolver commands must anchor with =; the options commands must NOT
    # (tmux 3.6a rejects '=' targets on set-option/show-option), and they are
    # unambiguous anyway because they only run once exact 'cs' exists.
    ! grep -E -- '^(has-session|list-windows|new-window) .*-t cs( |$)' "$FAKE_TMUX_DIR/log" >/dev/null \
        || { echo "  unanchored resolver target found"; return 1; }
    grep -F -- '-t =cs' "$FAKE_TMUX_DIR/log" >/dev/null || { echo "  no anchored resolver target"; return 1; }
    ! grep -E -- '^(set-option|show-option) .*-t =cs' "$FAKE_TMUX_DIR/log" >/dev/null \
        || { echo "  anchored options-command target found"; return 1; }
}

test_spawn_empty_spawner_writes_blank_first_line() {
    env -u CLAUDE_SESSION_NAME "$CS_BIN" -spawn worker --task "solo" >/dev/null 2>&1 || return 1
    assert_eq "" "$(sed -n 2p "$(SEED)")" "blank spawner line" || return 1
    assert_eq "solo" "$(sed -n 3p "$(SEED)")" "task on line 3" || return 1
}

# The spawner line becomes the worker's report-back address (cs -msg <spawner>
# -k result) and its kick prompt; it comes from the environment, so only a
# session name gets in.
test_spawn_rejects_an_invalid_spawner_name() {
    local out
    ! out=$(CLAUDE_SESSION_NAME="bad name; rm" "$CS_BIN" -spawn worker --task "solo" 2>&1) \
        || { echo "  spawn accepted an invalid spawner name"; return 1; }
    [ ! -f "$(SEED)" ] || { echo "  seed written for an invalid spawner"; return 1; }
    assert_output_contains "$out" "CLAUDE_SESSION_NAME" "the error names the source" || return 1
    CLAUDE_SESSION_NAME="base@task" "$CS_BIN" -spawn worker --task "solo" >/dev/null 2>&1 \
        || { echo "  a worktree spawner name refused"; return 1; }
}

test_spawn_without_task_writes_no_seed() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written without --task"; return 1; }
}

# A brief is the multi-line counterpart of --task: a file the spawned session
# reads before it begins. It is staged beside the seed, verbatim, and a brief
# alone is reason enough for a seed, since the seed carries the spawner.
test_spawn_stages_brief_beside_the_seed() {
    printf '# Goal\n\nAdd the refresh-token path.\n\n## Done when\n- suite green\n' > "$TEST_TMPDIR/brief.md"
    CLAUDE_SESSION_NAME="boss" "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" >/dev/null 2>&1 || return 1
    assert_file_exists "$(BRIEF)" "brief staged" || return 1
    cmp -s "$TEST_TMPDIR/brief.md" "$(BRIEF)" || { echo "  staged brief differs from the source"; return 1; }
    assert_file_exists "$(SEED)" "a brief alone writes a seed" || return 1
    assert_eq "boss" "$(sed -n 2p "$(SEED)")" "seed carries the spawner" || return 1
    assert_eq "2" "$(wc -l < "$(SEED)" | tr -d ' ')" "seed carries no tasks" || return 1
}

test_spawn_brief_and_tasks_stage_together() {
    printf 'brief body\n' > "$TEST_TMPDIR/brief.md"
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" --task "first job" >/dev/null 2>&1 || return 1
    assert_file_exists "$(BRIEF)" "brief staged" || return 1
    assert_eq "first job" "$(sed -n 3p "$(SEED)")" "task staged with the brief" || return 1
}

test_spawn_rejects_unreadable_or_empty_brief_before_staging() {
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/absent.md" >/dev/null 2>&1 || return 1
    : > "$TEST_TMPDIR/empty.md"
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/empty.md" >/dev/null 2>&1 || return 1
    printf 'secret brief\n' > "$TEST_TMPDIR/locked.md"
    chmod 000 "$TEST_TMPDIR/locked.md"
    local rc=0
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/locked.md" >/dev/null 2>&1 && rc=1
    chmod 600 "$TEST_TMPDIR/locked.md"
    [ "$rc" = 0 ] || { echo "  an unreadable brief was accepted"; return 1; }
    ! "$CS_BIN" -spawn worker --brief >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written on a rejected brief"; return 1; }
    [ ! -f "$(BRIEF)" ] || { echo "  brief staged on a rejected brief"; return 1; }
    [ ! -f "$FAKE_TMUX_DIR/log" ] || { echo "  a window was opened on a rejected brief"; return 1; }
}

# The seed is the launch's signal that staging is complete. A brief that
# could not be copied must stop the spawn before the seed exists, or the
# window opens and the session launches without the brief it was promised.
test_spawn_failed_brief_copy_publishes_no_seed() {
    printf 'brief body\n' > "$TEST_TMPDIR/brief.md"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    chmod 500 "$CS_SESSIONS_ROOT/.spawn"
    local rc=0
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" >/dev/null 2>&1 && rc=1
    chmod 700 "$CS_SESSIONS_ROOT/.spawn"
    [ "$rc" = 0 ] || { echo "  a failed brief copy still reported success"; return 1; }
    [ ! -f "$(SEED)" ] || { echo "  seed published after the brief copy failed"; return 1; }
    # The precheck's has-session is logged too; only the window commands count.
    ! grep -E -q '^(new-session|new-window) ' "$FAKE_TMUX_DIR/log" 2>/dev/null \
        || { echo "  a window was opened after the brief copy failed"; return 1; }
}

# The mirror case: the brief copied but the seed could not be written. The
# spawn must abort with nothing left behind, or a later spawn of the same name
# with no --brief inherits this one's brief.
test_spawn_failed_seed_write_stages_nothing() {
    printf 'brief body\n' > "$TEST_TMPDIR/brief.md"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    # A read-only file in the seed's tmp place: the redirect fails, while the
    # cleanup that follows still succeeds, so the abort runs its own error.
    # Root, and filesystems that ignore mode bits, deny nothing — skip there
    # rather than blame the code for a write that was always going to succeed.
    _deny_file_write "$(SEED).tmp" || return 77
    local rc=0 err
    err=$("$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" 2>&1 >/dev/null) && rc=1
    chmod 600 "$(SEED).tmp" 2>/dev/null; rm -f "$(SEED).tmp"
    [ "$rc" = 0 ] || { echo "  a failed seed write still reported success"; return 1; }
    assert_output_contains "$err" "cannot stage the seed" "the abort says what failed" || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed published although its write failed"; return 1; }
    [ ! -f "$(BRIEF)" ] || { echo "  the brief was left behind for the next spawn to inherit"; return 1; }
    ! grep -E -q '^(new-session|new-window) ' "$FAKE_TMUX_DIR/log" 2>/dev/null \
        || { echo "  a window was opened after the seed write failed"; return 1; }
}

# The seed is written before the brief and published after it, so a brief that
# cannot be staged must leave the half-written seed behind as neither a seed nor
# a temp file. Not a red-first test: it pins the ordering the concurrent-brief
# fix introduced, which no earlier test constrains.
test_spawn_failed_brief_copy_leaves_no_seed_temp() {
    printf 'brief body\n' > "$TEST_TMPDIR/brief.md"
    # A read-only file in the brief's tmp place: cp fails, the directory stays
    # writable, so the seed's own temp write succeeded just before it.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    _deny_file_write "$CS_SESSIONS_ROOT/.spawn/worker.brief.md.tmp" || return 77
    local rc=0
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" >/dev/null 2>&1 && rc=1
    chmod 600 "$CS_SESSIONS_ROOT/.spawn/worker.brief.md.tmp" 2>/dev/null
    rm -f "$CS_SESSIONS_ROOT/.spawn/worker.brief.md.tmp"
    [ "$rc" = 0 ] || { echo "  a failed brief copy still reported success"; return 1; }
    [ ! -f "$(SEED)" ] || { echo "  seed published after the brief copy failed"; return 1; }
    [ ! -f "$(SEED).tmp" ] || { echo "  the seed temp file was left behind"; return 1; }
    [ ! -f "$(BRIEF)" ] || { echo "  a brief was published although the copy failed"; return 1; }
}

# The seed refusal already covers a pending brief: a brief never exists
# without its seed. This pins that a second spawn cannot swap the brief out
# from under the pending one.
test_spawn_refuses_to_replace_a_pending_brief() {
    printf 'first\n' > "$TEST_TMPDIR/one.md"
    printf 'second\n' > "$TEST_TMPDIR/two.md"
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/one.md" >/dev/null 2>&1 || return 1
    rm -f "$FAKE_TMUX_DIR/session-exists"
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/two.md" >/dev/null 2>&1 || return 1
    assert_eq "first" "$(cat "$(BRIEF)")" "pending brief untouched" || return 1
}

test_spawn_attach_hint_uses_switch_client_inside_tmux() {
    # tmux attach refuses to nest; from inside tmux the user needs switch-client.
    local out
    out=$(TMUX="/tmp/tmux-1000/default,1234,0" "$CS_BIN" -spawn worker 2>&1) || return 1
    assert_output_contains "$out" "tmux switch-client -t cs" "switch-client hint inside tmux" || return 1
    assert_output_not_contains "$out" "tmux attach -t cs" "no attach hint inside tmux" || return 1
}

test_spawn_refuses_existing_seed() {
    "$CS_BIN" -spawn worker --task "a" >/dev/null 2>&1 || return 1
    rm -f "$FAKE_TMUX_DIR/session-exists"
    ! "$CS_BIN" -spawn worker --task "b" >/dev/null 2>&1 || return 1
    assert_eq "a" "$(sed -n 3p "$(SEED)")" "original seed untouched" || return 1
}

test_spawn_rejects_multiline_and_empty_task() {
    ! "$CS_BIN" -spawn worker --task "$(printf 'one\ntwo')" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -spawn worker --task "   " >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written on rejected task"; return 1; }
}

test_spawn_refuses_unmanaged_cs_session() {
    touch "$FAKE_TMUX_DIR/session-exists"     # a session named cs exists...
    rm -f "$FAKE_TMUX_DIR/managed"            # ...but carries no @cs_managed
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_refuses_duplicate_window() {
    touch "$FAKE_TMUX_DIR/session-exists"
    printf '1\n' > "$FAKE_TMUX_DIR/managed"
    printf 'worker\n' > "$FAKE_TMUX_DIR/windows"
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_window_command_is_quoted_absolute() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    grep -F "'/" "$FAKE_TMUX_DIR/log" >/dev/null || { echo "  window cmd not quoted-absolute"; return 1; }
    assert_file_contains "$FAKE_TMUX_DIR/log" "'worker'" "name quoted" || return 1
}

test_spawn_accepts_worktree_name() {
    "$CS_BIN" -spawn base@feature >/dev/null 2>&1 || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "base@feature" "worktree window opened" || return 1
}

test_spawn_new_session_race_falls_through_to_new_window() {
    touch "$FAKE_TMUX_DIR/race"   # new-session fails as if a concurrent spawner won
    local out
    out=$("$CS_BIN" -spawn worker 2>&1) || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-session" "new-session attempted" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-window" "fell through to new-window" || return 1
    assert_output_contains "$out" "@7" "window id from the fallthrough" || return 1
}

WQ() { printf '%s' "$CS_SESSIONS_ROOT/worker/.cs/local"; }

# Count task files in the worker's queue directory.
WQ_COUNT() {
    local f n=0
    for f in "$(WQ)/queue"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# Content of the lexically first queued task (empty when none).
WQ_FIRST() {
    local f
    for f in "$(WQ)/queue"/*; do
        [ -f "$f" ] || continue
        cat "$f"
        return 0
    done
}

# Launch recipe (same as tests/test_uuid.sh): CLAUDE_CODE_BIN=echo makes cs's
# `exec $CLAUDE_CODE_BIN <args>` print claude's argv; <<< "" answers any read.
# The recipe opens as the spawn's own window (CS_SPAWN_TOKEN matches the
# seed), the unattended path; the consent tests below open without it.
_launch_worker() {
    CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker <<< "" 2>&1
}

# A foreign open on a terminal: the consent ask reads a keypress from a tty,
# never from redirected stdin, so the launch runs on a pty and the keys are
# typed once the ask appears. Keys take Python escapes (\r, \x1b). Output
# comes back with CRLF folded.
_launch_worker_on_tty() {  # keys, [VAR=value ...]
    local keys="$1"; shift
    env "$@" python3 - "$keys" "$CS_BIN" worker << 'PY'
import os, pty, select, sys, time
keys = sys.argv[1].encode("latin1").decode("unicode_escape").encode("latin1")
cmd = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out = b""
sent = False
start = time.time()
while True:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        out += data
    if not sent and (b"[Y/n]" in out or time.time() - start > 8):
        if keys:
            os.write(fd, keys)
        sent = True
    if time.time() - start > 20:
        os.kill(pid, 9)
        break
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(out.replace(b"\r\n", b"\n"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PY
}

test_launch_consumes_seed_queues_arms_and_kicks() {
    _stage_seed boss "first job" "second job"
    local out; out=$(_launch_worker) || return 1
    grep -q "first job" "$(WQ)/queue"/* || { echo "  task 1 not queued"; return 1; }
    grep -q "second job" "$(WQ)/queue"/* || { echo "  task 2 not queued"; return 1; }
    assert_eq "first job" "$(WQ_FIRST)" "queue order kept" || return 1
    assert_file_contains "$(WQ)/queue.state" "armed" "queue armed" || return 1
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by recorded" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  seed not deleted"; return 1; }
    assert_output_contains "$out" "Spawned by boss" "kick prompt in claude argv" || return 1
    assert_output_contains "$out" "2 task(s)" "kick counts tasks" || return 1
    assert_output_contains "$out" "cs -msg boss -k result" "reply instructions present" || return 1
}

# A pane claude splits off for an agent-team teammate is started by the tmux
# server with the tmux session's environment, not the lead's, so the truecolor
# override cs exports for claude never reaches it and the teammate's status
# line renders in the 256-colour fallback. The launch publishes the value into
# the tmux session it runs in. The fake tmux is also first on PATH: the tab
# title code calls tmux by name, and with TMUX set a real tmux would rename the
# window this suite runs in.
_launch_worker_in_tmux() {  # [truecolor value]
    mkdir -p "$TEST_TMPDIR/bin" && ln -sf "$CS_TMUX_BIN" "$TEST_TMPDIR/bin/tmux"
    # The default case unsets the variable: a suite run from a shell that
    # carries one (every cs session does) would otherwise test that value.
    if [ $# -gt 0 ]; then
        PATH="$TEST_TMPDIR/bin:$PATH" TMUX="/tmp/fake,1,0" CLAUDE_CODE_TMUX_TRUECOLOR="$1" "$CS_BIN" worker <<< "" > /dev/null 2>&1
    else
        ( unset CLAUDE_CODE_TMUX_TRUECOLOR; PATH="$TEST_TMPDIR/bin:$PATH" TMUX="/tmp/fake,1,0" "$CS_BIN" worker <<< "" > /dev/null 2>&1 )
    fi
}

test_launch_publishes_truecolor_to_the_tmux_session() {
    _launch_worker_in_tmux || true
    assert_file_contains "$FAKE_TMUX_DIR/log" "^set-environment CLAUDE_CODE_TMUX_TRUECOLOR 1$" \
        "the launch sets the truecolor flag in the tmux session env" || return 1
}

# The user's own value wins, as it does for claude's environment.
test_launch_publishes_the_users_truecolor_value() {
    _launch_worker_in_tmux 0 || true
    assert_file_contains "$FAKE_TMUX_DIR/log" "^set-environment CLAUDE_CODE_TMUX_TRUECOLOR 0$" \
        "a preset value is published as given" || return 1
}

test_launch_outside_tmux_touches_no_tmux_environment() {
    _launch_worker > /dev/null 2>&1 || true
    if [ -f "$FAKE_TMUX_DIR/log" ] && grep -q "set-environment" "$FAKE_TMUX_DIR/log"; then
        echo "  FAIL: set-environment called with no tmux around"; return 1
    fi
}

test_launch_empty_spawner_gets_no_reply_wiring() {
    _stage_seed "" "only job"
    local out; out=$(_launch_worker) || return 1
    grep -q "only job" "$(WQ)/queue"/* || { echo "  task not queued"; return 1; }
    [ ! -f "$(WQ)/spawned-by" ] || { echo "  spawned-by written for empty spawner"; return 1; }
    assert_output_contains "$out" "armed with 1 task(s)" "kick present" || return 1
    assert_output_not_contains "$out" "Spawned by" "no spawner attribution" || return 1
    assert_output_not_contains "$out" "-k result" "no reply instructions" || return 1
}

# A staged brief becomes the session's own file, .cs/brief.md, and the kick
# sends the session to it before anything else. With no tasks there is no
# queue to drain, so the report-back is by hand and the kick says how.
test_launch_moves_brief_into_the_session_and_kicks_to_it() {
    _stage_seed boss
    printf '# Goal\nrefresh tokens\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local out; out=$(_launch_worker) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/brief.md" "brief moved into the session" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/worker/.cs/brief.md" "refresh tokens" "brief content kept" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.brief.md" ] || { echo "  staged brief left behind"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  seed not deleted"; return 1; }
    assert_output_contains "$out" "Spawned by boss" "spawner named" || return 1
    assert_output_contains "$out" "Your brief is .cs/brief.md" "kick names the brief" || return 1
    assert_output_not_contains "$out" "armed with" "no queue promised without tasks" || return 1
    assert_output_contains "$out" "cs -msg boss -k result" "reply instructions present" || return 1
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by recorded for a brief-only spawn" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed with no tasks"; return 1; }
}

test_launch_brief_with_tasks_kicks_to_both() {
    _stage_seed boss "first job"
    printf 'brief body\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local out; out=$(_launch_worker) || return 1
    assert_output_contains "$out" "Your brief is .cs/brief.md" "kick names the brief" || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "kick counts tasks" || return 1
    assert_file_contains "$(WQ)/queue.state" "armed" "queue armed" || return 1
}

# A brief the launch cannot move into the session must stop the launch with
# the seed and brief still staged, so the next open retries; consuming the
# seed would start the session without the brief, and leave the brief to
# A writable directory at the brief's destination is worse than a sealed one:
# mv would put the brief INSIDE it, the launch would count the delivery a
# success, and Claude would be told to read a directory.
test_launch_refuses_a_directory_at_the_briefs_destination() {
    _launch_worker >/dev/null || return 1
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    _stage_seed boss "first job"
    printf 'brief body\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local rc=0 out
    out=$(_launch_worker) || rc=$?
    [ "$rc" != 0 ] || { echo "  launch succeeded with a directory in the brief's place"; return 1; }
    [ ! -e "$CS_SESSIONS_ROOT/worker/.cs/brief.md/worker.brief.md" ] || { echo "  the brief was moved inside the directory"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed kept for a retry" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.brief.md" "brief kept for a retry" || return 1
    assert_eq "0" "$(WQ_COUNT)" "no task queued without the brief" || return 1
    assert_output_contains "$out" "brief" "the failure names the brief" || return 1
}

# attach to some later, unrelated spawn of the same name.
test_launch_failed_brief_delivery_keeps_the_seed_and_brief() {
    # First open creates the session; then the brief's destination is made
    # undeliverable (a sealed directory in its place) while the staging
    # directory stays writable, so only the delivery can fail.
    _launch_worker >/dev/null || return 1
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    chmod 500 "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    _stage_seed boss "first job"
    printf 'brief body\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local rc=0 out
    out=$(_launch_worker) || rc=$?
    chmod 700 "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    [ "$rc" != 0 ] || { echo "  launch succeeded without delivering the brief"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed kept for a retry" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.brief.md" "brief kept for a retry" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md/worker.brief.md" ] || { echo "  a brief appeared in the session anyway"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "no task queued without the brief" || return 1
    assert_output_not_contains "$out" "Spawned by" "no kick without the brief" || return 1
    assert_output_contains "$out" "brief" "the failure names the brief" || return 1
}

test_launch_stale_seed_sets_its_brief_aside_too() {
    _stage_seed boss
    printf 'old brief\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.brief.md.stale" "stale brief set aside" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.brief.md" ] || { echo "  stale brief still staged"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md" ] || { echo "  stale brief applied to the session"; return 1; }
    assert_output_not_contains "$out" "Your brief is" "no kick from a stale brief" || return 1
}

test_launch_without_seed_keeps_color_behavior() {
    local out; out=$(_launch_worker) || return 1
    assert_output_not_contains "$out" "armed with" "no kick without seed" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed without seed"; return 1; }
}

test_launch_sets_aside_stale_seed() {
    _stage_seed boss "old job"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  stale seed still active"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "stale set aside" || return 1
    assert_eq "0" "$(WQ_COUNT)" "stale seed queued no work" || return 1
    assert_output_not_contains "$out" "armed with" "no kick from stale seed" || return 1
}

test_launch_stale_warning_names_the_stale_file() {
    _stage_seed boss "old job"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$("$CS_BIN" worker <<< "" 2>&1) || return 1
    assert_output_contains "$out" "worker.seed.stale" "warning names the stale file" || return 1
}

test_launch_fresh_boundary_seed_is_consumed() {
    # A seed 30 minutes old is comfortably inside the 3600s TTL.
    _stage_seed boss "boundary job"
    touch -t "$(date -v-30M +%Y%m%d%H%M 2>/dev/null || date -d '-30 minutes' +%Y%m%d%H%M)" \
        "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker <<< "" 2>&1) || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "fresh-side seed consumed" || return 1
}

test_launch_seed_bypasses_resume_ask() {
    # First launch creates the session; second would normally ask "Continue
    # previous conversation? [Y/n]". In the spawn's own window, no ask: stdin
    # is closed so a read would die, proving the prompt was skipped.
    _launch_worker >/dev/null || return 1
    _stage_seed boss "resume job"
    local out; out=$(CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "seed consumed on resume" || return 1
    assert_output_not_contains "$out" "Continue previous conversation" "resume ask bypassed" || return 1
}

# Consent (audit H2). A seed is a file in .spawn/; anything that can write
# there used to arm the next open of the name, by hand or by a script, with
# whatever it staged, and the kick told Claude to begin. Only the spawn's own
# tmux window, which carries the seed's token, consumes unasked. Every other
# open is shown the seed as data and asked.
test_launch_own_window_consumes_without_asking() {
    _stage_seed boss "own job"
    local out; out=$(CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "seed consumed" || return 1
    assert_output_not_contains "$out" "\\[Y/n\\]" "no consent ask in the spawn's own window" || return 1
}

test_launch_foreign_seed_unattended_stays_staged() {
    _stage_seed boss "foreign job"
    printf 'brief body\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local out; out=$("$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.brief.md" "brief left staged" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md" ] || { echo "  brief delivered without consent"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "nothing queued without consent" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed without consent"; return 1; }
    [ ! -f "$(WQ)/spawned-by" ] || { echo "  spawned-by written without consent"; return 1; }
    assert_output_not_contains "$out" "armed with" "no kick without consent" || return 1
    assert_output_not_contains "$out" "Spawned by" "no kick without consent" || return 1
    assert_output_contains "$out" "worker.seed" "the launch names the staged seed" || return 1
}

test_launch_wrong_token_is_a_foreign_open() {
    _stage_seed boss "foreign job"
    local out; out=$(CS_SPAWN_TOKEN="ffffffffffffffffffffffffffffffff" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued on a token mismatch" || return 1
}

test_launch_seed_without_a_token_line_is_foreign() {
    # A seed written by an older cs, or by hand: line 1 is the spawner. An
    # empty CS_SPAWN_TOKEN never matches an empty token line.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf '\nold job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(CS_SPAWN_TOKEN="" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued" || return 1
}

# Codex round 1: `<<< ""` hands the ask a newline, which read -rsn1 returns
# as the empty answer, and the default arm consumed a foreign seed with no
# human at all. Redirected stdin of any content leaves the seed staged.
test_launch_foreign_seed_redirected_stdin_stays_staged() {
    _stage_seed boss "foreign job"
    local out
    out=$("$CS_BIN" worker <<< "" 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged on a piped newline" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued on a piped newline" || return 1
    out=$("$CS_BIN" worker <<< "y" 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged on a piped y" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued on a piped y" || return 1
    assert_output_not_contains "$out" "Take the seed" "no ask without a terminal" || return 1
    assert_output_contains "$out" "worker.seed" "the launch names the staged seed" || return 1
}

test_launch_foreign_seed_consent_shows_it_and_enter_consumes() {
    _stage_seed boss "first job" "second job"
    printf 'brief body\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local out; out=$(_launch_worker_on_tty '\r') || { echo "  launch failed: $out"; return 1; }
    assert_output_contains "$out" "\\[Y/n\\]" "consent asked" || return 1
    assert_output_contains "$out" "boss" "spawner shown" || return 1
    assert_output_contains "$out" "first job" "task 1 shown" || return 1
    assert_output_contains "$out" "second job" "task 2 shown" || return 1
    assert_output_contains "$out" "brief" "brief named" || return 1
    assert_eq "2" "$(WQ_COUNT)" "tasks queued after consent" || return 1
    assert_file_contains "$(WQ)/queue.state" "armed" "queue armed after consent" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/brief.md" "brief delivered after consent" || return 1
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by recorded" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  seed not deleted"; return 1; }
    assert_output_contains "$out" "armed with 2 task(s)" "kick present" || return 1
}

test_launch_foreign_seed_y_consumes() {
    _stage_seed boss "yes job"
    local out; out=$(_launch_worker_on_tty 'y') || { echo "  launch failed: $out"; return 1; }
    assert_eq "1" "$(WQ_COUNT)" "task queued after y" || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "kick present" || return 1
}

test_launch_foreign_seed_unknown_key_asks_again() {
    _stage_seed boss "retry job"
    local out; out=$(_launch_worker_on_tty 'xn') || { echo "  launch failed: $out"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "an unknown key is not consent" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "the n after it declined" || return 1
    [ "$(printf '%s' "$out" | grep -c 'Y/n')" -ge 2 ] || { echo "  ask not repeated after an unknown key"; return 1; }
}

test_launch_foreign_seed_escape_declines() {
    _stage_seed boss "escaped job"
    local out; out=$(_launch_worker_on_tty '\x1b') || { echo "  launch failed: $out"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "nothing queued after Escape" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "Escape set the seed aside" || return 1
}

test_launch_foreign_seed_declined_is_set_aside() {
    _stage_seed boss "declined job"
    printf 'brief body\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local out; out=$(_launch_worker_on_tty 'n') || { echo "  launch failed: $out"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  declined seed still staged"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "declined seed set aside" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.brief.md.stale" "declined brief set aside" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md" ] || { echo "  brief delivered after a decline"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "nothing queued after a decline" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed after a decline"; return 1; }
    assert_output_not_contains "$out" "armed with" "no kick after a decline" || return 1
    assert_output_contains "$out" "worker.seed.stale" "the launch names where the seed went" || return 1
}

test_launch_seed_control_characters_are_shown_flat() {
    # A hand-crafted seed cannot hold a newline per line, but it can hold
    # other control characters; the consent listing shows them stripped.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf '%s\nbo\001ss\nfirst\rjob \033[31mred\n' "$OWN_TOKEN" > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker_on_tty 'n') || { echo "  launch failed: $out"; return 1; }
    assert_output_contains "$out" "boss" "spawner shown flat" || return 1
    assert_output_contains "$out" "firstjob" "task shown flat" || return 1
    assert_output_not_contains "$out" $'\033\[31m' "escape sequence not passed through" || return 1
}

test_launch_token_never_reaches_claude() {
    cat > "$TEST_TMPDIR/fake-claude" << 'FAKE'
#!/usr/bin/env bash
printf 'token=%s\n' "${CS_SPAWN_TOKEN:-unset}"
FAKE
    chmod +x "$TEST_TMPDIR/fake-claude"
    _stage_seed boss "own job"
    local out; out=$(CLAUDE_CODE_BIN="$TEST_TMPDIR/fake-claude" CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_output_contains "$out" "token=unset" "the token is dropped before claude starts" || return 1
}

# An encrypted session keeps its queue behind .cs/private; a seed consumed into
# .cs/local was plaintext the drain never read.
_make_worker_vaulted() {
    local meta="$CS_SESSIONS_ROOT/worker/.cs"
    mkdir -p "$meta/vault-mnt/private"
    mv "$meta/memory" "$meta/vault-mnt/memory"
    mv "$meta/plans" "$meta/vault-mnt/plans"
    ln -s "$meta/vault-mnt/memory" "$meta/memory"
    ln -s "$meta/vault-mnt/plans" "$meta/plans"
    mv "$meta/local/session.log" "$meta/vault-mnt/private/session.log"
    ln -s "$meta/vault-mnt/private" "$meta/private"
}

test_launch_seed_queues_into_the_vault() {
    _launch_worker >/dev/null || return 1
    _make_worker_vaulted
    _stage_seed boss "vault job"
    local out; out=$(_launch_worker) || { echo "  launch failed: $out"; return 1; }
    local priv="$CS_SESSIONS_ROOT/worker/.cs/vault-mnt/private"
    grep -q "vault job" "$priv/queue"/* 2>/dev/null || { echo "  task not queued in the vault"; return 1; }
    assert_file_contains "$priv/queue.state" "armed" "queue armed in the vault" || return 1
    [ ! -e "$(WQ)/queue" ] || { echo "  plaintext queue written beside the vault"; return 1; }
    [ ! -e "$(WQ)/queue.state" ] || { echo "  plaintext queue.state written beside the vault"; return 1; }
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by stays in .cs/local" || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "kick present" || return 1
}

run_test test_spawn_rejects_bad_names_and_missing_tmux
run_test test_spawn_rejects_live_target
run_test test_spawn_writes_seed_and_opens_window
run_test test_spawn_without_task_writes_no_seed
run_test test_spawn_rejects_an_invalid_spawner_name
run_test test_spawn_stages_brief_beside_the_seed
run_test test_spawn_brief_and_tasks_stage_together
run_test test_spawn_rejects_unreadable_or_empty_brief_before_staging
run_test test_spawn_failed_brief_copy_publishes_no_seed
run_test test_spawn_failed_seed_write_stages_nothing
run_test test_spawn_failed_brief_copy_leaves_no_seed_temp
run_test test_spawn_refuses_to_replace_a_pending_brief
run_test test_spawn_attach_hint_uses_switch_client_inside_tmux
run_test test_spawn_refuses_existing_seed
run_test test_spawn_rejects_multiline_and_empty_task
run_test test_spawn_refuses_unmanaged_cs_session
run_test test_spawn_refuses_duplicate_window
run_test test_spawn_window_command_is_quoted_absolute
run_test test_spawn_accepts_worktree_name
run_test test_spawn_new_session_race_falls_through_to_new_window
run_test test_spawn_tmux_targets_are_exact_match_anchored
run_test test_spawn_empty_spawner_writes_blank_first_line
run_test test_launch_consumes_seed_queues_arms_and_kicks
run_test test_launch_publishes_truecolor_to_the_tmux_session
run_test test_launch_publishes_the_users_truecolor_value
run_test test_launch_outside_tmux_touches_no_tmux_environment
run_test test_launch_empty_spawner_gets_no_reply_wiring
run_test test_launch_without_seed_keeps_color_behavior
run_test test_launch_moves_brief_into_the_session_and_kicks_to_it
run_test test_launch_brief_with_tasks_kicks_to_both
run_test test_launch_refuses_a_directory_at_the_briefs_destination
run_test test_launch_failed_brief_delivery_keeps_the_seed_and_brief
run_test test_launch_stale_seed_sets_its_brief_aside_too
run_test test_launch_sets_aside_stale_seed
run_test test_launch_stale_warning_names_the_stale_file
run_test test_launch_fresh_boundary_seed_is_consumed
run_test test_launch_seed_bypasses_resume_ask
run_test test_launch_own_window_consumes_without_asking
run_test test_launch_foreign_seed_unattended_stays_staged
run_test test_launch_wrong_token_is_a_foreign_open
run_test test_launch_seed_without_a_token_line_is_foreign
run_test test_launch_foreign_seed_redirected_stdin_stays_staged
run_test test_launch_foreign_seed_consent_shows_it_and_enter_consumes
run_test test_launch_foreign_seed_y_consumes
run_test test_launch_foreign_seed_unknown_key_asks_again
run_test test_launch_foreign_seed_escape_declines
run_test test_launch_foreign_seed_declined_is_set_aside
run_test test_launch_seed_control_characters_are_shown_flat
run_test test_launch_token_never_reaches_claude
run_test test_launch_seed_queues_into_the_vault

# Drain harness (same recipe as tests/test_queue_supervision.sh): the Stop
# hook is narrative-reminder.sh; CLAUDE_SESSION_* env selects the session.
_worker_env() {
    CS_LEAD_PID=$$ CLAUDE_PID=$$ \
    CLAUDE_SESSION_NAME="worker" \
    CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/worker" \
    CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/worker/.cs" \
    "$@"
}
_worker_stop_turn() {
    echo '{}' | PATH="$SCRIPT_DIR/../bin:$PATH" _worker_env bash "$HOOKS_DIR/narrative-reminder.sh"
}
_arm_worker_queue() {  # tasks...
    create_test_session worker >/dev/null 2>&1 || true
    create_test_session boss >/dev/null 2>&1 || true
    local t i=0
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/local/queue"
    for t in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$t" > "$CS_SESSIONS_ROOT/worker/.cs/local/queue/$(printf '%010d' "$i")-seed"
    done
    printf 'armed\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue.state"
    printf 'boss\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by"
}
# First unread message in boss's maildir, as a file path (empty when none).
BOSS_MSG() {
    local f
    for f in "$CS_SESSIONS_ROOT/boss/.cs/local/mail/new"/*.json; do
        [ -e "$f" ] || return 1
        printf '%s' "$f"
        return 0
    done
}

# Count of unread messages in boss's maildir.
BOSS_MSG_COUNT() {
    local f n=0
    for f in "$CS_SESSIONS_ROOT/boss/.cs/local/mail/new"/*.json; do
        [ -e "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

test_drain_finished_notifies_spawner_once() {
    _arm_worker_queue "only task"
    _worker_stop_turn >/dev/null || return 1        # armed -> draining, task 1 injected
    _worker_stop_turn >/dev/null || return 1        # task done -> drain_finished
    local msg; msg=$(BOSS_MSG) || { echo "  spawner mail not delivered"; return 1; }
    assert_file_contains "$msg" "queue drained: 1 task(s) done" "notify body" || return 1
    assert_eq "notify" "$(jq -r .kind "$msg")" "kind notify" || return 1
    assert_eq "worker" "$(jq -r .from "$msg")" "from worker" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by" ] || { echo "  spawned-by not one-shot"; return 1; }
    # A later, unrelated drain must not re-notify.
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/local/queue"
    printf 'later task\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue/0000000009-later"
    printf 'armed\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue.state"
    _worker_stop_turn >/dev/null || return 1
    _worker_stop_turn >/dev/null || return 1
    assert_eq "1" "$(BOSS_MSG_COUNT)" "no second notify" || return 1
}

test_breaker_trip_notifies_and_keeps_spawned_by() {
    _arm_worker_queue "task a" "task b"
    _worker_stop_turn >/dev/null || return 1        # draining, task a injected
    printf '9\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/failures"
    _worker_stop_turn >/dev/null || return 1        # trips the failure breaker
    local msg; msg=$(BOSS_MSG) || { echo "  trip mail not delivered"; return 1; }
    assert_file_contains "$msg" "breaker tripped" "trip notified" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by" "spawned-by kept on trip" || return 1
}

test_drain_without_spawned_by_sends_nothing() {
    _arm_worker_queue "solo task"
    rm -f "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by"
    _worker_stop_turn >/dev/null || return 1
    _worker_stop_turn >/dev/null || return 1
    assert_eq "0" "$(BOSS_MSG_COUNT)" "notify sent without spawned-by" || return 1
}

run_test test_drain_finished_notifies_spawner_once
run_test test_breaker_trip_notifies_and_keeps_spawned_by
run_test test_drain_without_spawned_by_sends_nothing

report_results
