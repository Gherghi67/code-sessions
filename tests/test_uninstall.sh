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

# The confirmation waits on a person, so a session can open after the first
# check. The check runs again once the answer is in, before the first
# removal: a session that went live during the prompt still refuses the
# whole uninstall with every binary in place.
test_uninstall_rechecks_live_sessions_after_the_confirmation() {
    local home="$TEST_TMPDIR/late-home" root="$TEST_TMPDIR/late-sessions" stub="$TEST_TMPDIR/mount-stub-late"
    _stage_install "$home"
    mkdir -p "$root/late-open/.cs"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    local rc=0 out f
    { sleep 1; echo "$$" > "$root/late-open/.cs/session.lock"; printf 'yny'; } \
        | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/late.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/late.out")
    assert_eq 1 "$rc" "uninstall exits 1 when a session opened during the prompt" || return 1
    assert_output_contains "$out" "Error: Kept $root: these sessions are live: late-open. Close them, then delete $root." \
        "the refusal names the session that opened" || return 1
    for f in cs cs-secrets cs-statusline cs-subagent-statusline; do
        assert_file_exists "$home/.local/bin/$f" "$f is still installed after the late refusal" || return 1
    done
}

# The data question waits on a person too. A session that opens while
# "Delete session data?" is pending is found once the answer is in, before
# rm -rf, and the data stays. The answers are: go ahead, keep the keychain
# secrets, then (once the session is open) delete the data.
test_uninstall_rechecks_live_sessions_after_the_data_question() {
    local home="$TEST_TMPDIR/data-home" root="$TEST_TMPDIR/data-sessions" stub="$TEST_TMPDIR/mount-stub-data"
    _stage_install "$home"
    mkdir -p "$root/late-data/.cs"
    echo "notes" > "$root/late-data/.cs/notes.md"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    local rc=0 out
    { printf 'yn'; sleep 2; echo "$$" > "$root/late-data/.cs/session.lock"; printf 'y'; } \
        | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/data.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/data.out")
    assert_output_contains "$out" "Session data exists at $root" "the data question was reached before the session opened" || return 1
    assert_eq 1 "$rc" "uninstall exits 1 when a session opened during the data question" || return 1
    assert_output_contains "$out" "Error: Kept $root: these sessions are live: late-data. Close them, then delete $root." \
        "the refusal names the session that opened" || return 1
    assert_file_exists "$root/late-data/.cs/notes.md" "the session data survives" || return 1
}

# A volume can be mounted inside the sessions root while "Delete session
# data?" is pending, as an encrypted session opening attaches its vault.
# The mount table is read again once the answer is in, before rm -rf, which
# would recurse into the volume: the data stays and the refusal names it.
test_uninstall_rechecks_mounts_after_the_data_question() {
    local home="$TEST_TMPDIR/mnt-home" root="$TEST_TMPDIR/mnt-sessions" stub="$TEST_TMPDIR/mount-stub-mnt"
    _stage_install "$home"
    mkdir -p "$root/vaulted/.cs/vault-mnt"
    echo "notes" > "$root/vaulted/.cs/vault-mnt/notes.md"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    local rc=0 out
    { printf 'yn'; sleep 2
      printf '%s\n' "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" \
          "/dev/disk9s1 on $root/vaulted/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled, noowners, mounted by tester)" > "$stub/table"
      printf 'y'; } \
        | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/mnt.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/mnt.out")
    assert_output_contains "$out" "Session data exists at $root" "the data question was reached before the mount" || return 1
    assert_eq 1 "$rc" "uninstall exits 1 when a volume was mounted during the data question" || return 1
    assert_output_contains "$out" "Error: Kept $root: a volume is mounted inside it at $root/vaulted/.cs/vault-mnt, and deleting the directory would delete what the volume holds. Unmount it before you delete $root." \
        "the refusal names the mount" || return 1
    assert_file_exists "$root/vaulted/.cs/vault-mnt/notes.md" "the volume's data survives" || return 1
}

# An uninstall that keeps the secrets keeps the age state cs-secrets holds for
# each session beside them (~/.cs-secrets/sessions/<session>/), even when it
# deletes the session data. The settings.json lock is cs's alone and has no
# user left once cs is gone, so it goes; settings.json itself stays. The
# answers are: go ahead, keep the keychain secrets, delete the data.
test_uninstall_keeping_secrets_keeps_age_state_and_removes_the_settings_lock() {
    local home="$TEST_TMPDIR/s2-home" root="$TEST_TMPDIR/s2-sessions" stub="$TEST_TMPDIR/mount-stub-s2" rc=0 out
    _stage_install "$home"
    mkdir -p "$root/proj/.cs" "$home/.cs-secrets/sessions/proj"
    printf 'age1pinned example.com\n' > "$home/.cs-secrets/sessions/proj/age-trusted"
    printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$home/.claude/settings.json"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    printf 'yny' | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/s2.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/s2.out")
    assert_eq 0 "$rc" "uninstall exit status: $out" || return 1
    assert_output_contains "$out" "Kept secrets in keychain" "the secrets were kept" || return 1
    assert_not_exists "$root" "the session data is deleted" || return 1
    assert_eq "age1pinned example.com" "$(cat "$home/.cs-secrets/sessions/proj/age-trusted")" \
        "the session's age state stays with its kept secrets" || return 1
    assert_not_exists "$home/.claude/settings.json.mutex.lock" "the settings lock is removed" || return 1
    assert_eq '{"permissions":{"allow":["Bash(ls:*)"]}}' "$(jq -c . "$home/.claude/settings.json")" \
        "settings.json stays with the user's own settings" || return 1
}

# "Delete secrets from keychain?" waits on a person too. A session that opens
# while it is pending is live when cs-secrets purges, and from inside another
# session cs-secrets refuses that purge. The uninstall says whose secrets it
# kept and why, and purges the rest. The answers are: go ahead, (the session
# opens) delete the secrets, then keep the data.
test_uninstall_names_each_session_whose_secrets_it_kept() {
    local home="$TEST_TMPDIR/sk-home" root="$TEST_TMPDIR/sk-sessions" stub="$TEST_TMPDIR/mount-stub-sk"
    _stage_install "$home"
    cp "$SCRIPT_DIR/../bin/cs-secrets" "$home/.local/bin/cs-secrets"
    mkdir -p "$root/opens-late/.cs" "$root/closed/.cs"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    local s
    for s in opens-late closed; do
        printf 'v1' | HOME="$home" CS_SESSIONS_ROOT="$root" CS_SECRETS_BACKEND=encrypted \
            CS_SECRETS_PASSWORD=test-password-for-ci CLAUDE_SESSION_NAME="$s" \
            "$home/.local/bin/cs-secrets" set API_KEY >/dev/null 2>&1 \
            || { echo "  FAIL: fixture: could not seed $s's secret"; return 1; }
    done
    sleep 300 &
    local pid=$! rc=0 out kept left
    { printf 'y'; sleep 2; echo "$pid" > "$root/opens-late/.cs/session.lock"; printf 'yn'; } \
        | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" CS_SECRETS_BACKEND=encrypted \
            CS_SECRETS_PASSWORD=test-password-for-ci CLAUDE_SESSION_NAME=sender "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/sk.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/sk.out")
    kept=$(grep -F "Kept the secrets of session" <<< "$out")
    left=$(HOME="$home" CS_SESSIONS_ROOT="$root" CS_SECRETS_BACKEND=encrypted CS_SECRETS_PASSWORD=test-password-for-ci \
        CLAUDE_SESSION_NAME=opens-late "$SCRIPT_DIR/../bin/cs-secrets" export 2>&1)
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    assert_output_contains "$out" "^Secrets may exist in OS keychain for these sessions:$" "the secrets question was reached: $out" || return 1
    assert_eq "Kept the secrets of session opens-late: session sender cannot change the secrets of session opens-late while it is live (pid $pid); --force does not override that from another session. Close opens-late first." \
        "$kept" "the uninstall names the session whose secrets it kept, and why" || return 1
    assert_output_contains "$out" "^Purged 1 secret(s) for session: closed$" "the closed session's secrets are purged" || return 1
    assert_eq "export CS_SECRET_API_KEY=v1" "$left" "the live session's secret stays" || return 1
}

echo ""
echo "cs -uninstall ordering"
echo "======================"
echo ""

run_test test_uninstall_with_a_live_session_removes_nothing
run_test test_uninstall_rechecks_live_sessions_after_the_confirmation
run_test test_uninstall_rechecks_live_sessions_after_the_data_question
run_test test_uninstall_rechecks_mounts_after_the_data_question
run_test test_uninstall_keeping_secrets_keeps_age_state_and_removes_the_settings_lock
run_test test_uninstall_names_each_session_whose_secrets_it_kept

report_results
