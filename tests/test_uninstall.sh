#!/usr/bin/env bash
# ABOUTME: Tests cs -uninstall's ordering: a live session refuses the whole uninstall before
# ABOUTME: anything is removed, so the refusal never leaves session data with no tool to open it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# Stage the installed binaries cs -uninstall removes, in a fake HOME.
_stage_install() {  # home
    local bin="$1/.local/bin" f
    mkdir -p "$bin" "$1/.claude"
    for f in cs cs-secrets cs-statusline cs-subagent-statusline; do
        printf '#!/bin/sh\n' > "$bin/$f"
        chmod +x "$bin/$f"
    done
}

# Refused before the first removal: every binary is still installed, the
# refusal is the data step's own text, and the exit is non-zero.
test_uninstall_with_a_live_session_removes_nothing() {
    local home="$TEST_TMPDIR/live-home" root="$TEST_TMPDIR/live-sessions" stub="$TEST_TMPDIR/mount-stub"
    _stage_install "$home"
    mkdir -p "$root/live-lock/.cs" "$root/dead-lock/.cs"
    echo "$$" > "$root/live-lock/.cs/session.lock"
    echo 99999999 > "$root/dead-lock/.cs/session.lock"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    local rc=0 out f
    printf 'yny' | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/live.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/live.out")
    assert_eq 1 "$rc" "uninstall exits 1 while a session is live" || return 1
    assert_output_contains "$out" "Error: Kept $root: these sessions are live: live-lock. Close them, then delete $root." \
        "the refusal names the live session" || return 1
    for f in cs cs-secrets cs-statusline cs-subagent-statusline; do
        assert_file_exists "$home/.local/bin/$f" "$f is still installed after the refusal" || return 1
    done
    assert_file_exists "$root/live-lock/.cs/session.lock" "the live session's data survives" || return 1

    # Positive control: with the session closed, the same uninstall removes
    # the tool and, answered no, keeps the data.
    echo 99999999 > "$root/live-lock/.cs/session.lock"
    rc=0
    printf 'ynn' | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/closed.out" 2>&1 || rc=$?
    assert_eq 0 "$rc" "uninstall completes once no session is live: $(cat "$TEST_TMPDIR/closed.out")" || return 1
    assert_not_exists "$home/.local/bin/cs" "cs is removed" || return 1
    assert_dir "$root/live-lock/.cs" "the data is kept when the answer is no" || return 1
}

echo ""
echo "cs -uninstall ordering"
echo "======================"
echo ""

run_test test_uninstall_with_a_live_session_removes_nothing

report_results
