#!/usr/bin/env bash
# ABOUTME: Tests opening under the sessions root: a flat-layout session migrates into .cs/ keeping its
# ABOUTME: .gitignore, a non-session directory is refused, and a relative root is made absolute first.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# A flat-layout session cs created long ago (its logs/session.log opens with
# cs's header), in a git repo whose .gitignore hides a key file. The structural
# migration commits with add -A, so the user's rule must still be there when
# it does.
test_flat_layout_migration_keeps_the_sessions_gitignore() {
    local dir="$CS_SESSIONS_ROOT/flat-session"
    mkdir -p "$dir/logs"
    printf 'Claude Code Session Log\nSession: flat-session\n' > "$dir/logs/session.log"
    printf '# Session Documentation Protocol\n' > "$dir/CLAUDE.md"
    printf 'secret.key\n' > "$dir/.gitignore"
    printf 'example-key\n' > "$dir/secret.key"
    (cd "$dir" && git init -q && git add .gitignore CLAUDE.md && git commit -q -m initial)

    "$CS_BIN" flat-session <<< "" >/dev/null 2>&1 || true

    assert_dir "$dir/.cs" "the flat session migrated into .cs/" || return 1
    assert_file_contains "$dir/.gitignore" '^secret\.key$' \
        "the session's own .gitignore rule survives the migration" || return 1
    assert_file_contains "$dir/.gitignore" '^\.cs/local/$' \
        "cs's .cs/local/ rule is merged in" || return 1
    assert_eq "" "$(git -C "$dir" ls-files secret.key)" \
        "the ignored key file is not committed by the migration" || return 1
}

# The sessions root also holds directories that are not sessions (editor
# config, a worktree holder). Opening one by name is refused before cs writes
# its session files into it.
test_open_refuses_a_directory_that_is_not_a_session() {
    local dir="$CS_SESSIONS_ROOT/notes" out rc=0
    mkdir -p "$dir"
    printf 'my notes\n' > "$dir/todo.txt"

    out=$("$CS_BIN" notes <<< "" 2>&1) || rc=$?

    assert_eq 1 "$rc" "opening a non-session directory exits 1" || return 1
    assert_output_contains "$out" "Error: $dir is not a cs session (no .cs/ directory); cs will not write session files into it. Move it out of $CS_SESSIONS_ROOT or open another name." \
        "the refusal names the directory" || return 1
    assert_not_exists "$dir/.cs" "no .cs/ is created" || return 1
    assert_not_exists "$dir/.gitignore" "no .gitignore is written" || return 1
    assert_not_exists "$dir/CLAUDE.local.md" "no CLAUDE.local.md is written" || return 1
    # Positive control: a directory that is a session still opens.
    "$CS_BIN" real-session <<< "" >/dev/null 2>&1 || { echo "  FAIL: creating real-session failed"; return 1; }
    out=$("$CS_BIN" real-session <<< "" 2>&1) \
        || { echo "  FAIL: reopening a real session failed: $out"; return 1; }
}

# A relative sessions root names a directory under the one cs is started in.
# cs moves into the session before it launches claude, and claude's hooks and
# cs-secrets run from there, so the root and the session paths claude is
# handed are absolute. A root starting with a dash is a path, not an option to
# the commands cs gives it to. A nested root (x/y) is the positive control: it
# has no dash, so it fails only where a relative root is used after a cd.
test_open_under_a_relative_sessions_root_makes_it_absolute() {
    local w="$TEST_TMPDIR/w" root out rc
    mkdir -p "$w"
    cat > "$TEST_TMPDIR/claude-stub" << 'SCRIPT'
#!/bin/bash
printf '%s\n' "CS_SESSIONS_ROOT=$CS_SESSIONS_ROOT" "CLAUDE_SESSION_DIR=$CLAUDE_SESSION_DIR" \
    "CLAUDE_SESSION_META_DIR=$CLAUDE_SESSION_META_DIR" > "$CS_PROBE_ENV_OUT"
SCRIPT
    chmod +x "$TEST_TMPDIR/claude-stub"
    for root in -r x/y; do
        rc=0
        out=$(cd "$w" && CS_SESSIONS_ROOT="$root" CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub" \
            CS_PROBE_ENV_OUT="$TEST_TMPDIR/env.out" "$CS_BIN" demo-x <<< "" 2>&1) || rc=$?
        assert_eq 0 "$rc" "cs demo-x under the root $root exits 0 (output: $out)" || return 1
        assert_dir "$w/$root/demo-x/.cs" "the session is created under \$PWD/$root" || return 1
        assert_eq "CS_SESSIONS_ROOT=$w/$root
CLAUDE_SESSION_DIR=$w/$root/demo-x
CLAUDE_SESSION_META_DIR=$w/$root/demo-x/.cs" "$(cat "$TEST_TMPDIR/env.out" 2>&1)" \
            "claude is handed the root $root and the session's paths absolute" || return 1
        rm -f "$TEST_TMPDIR/env.out"
        rc=0
        out=$(cd "$w" && CS_SESSIONS_ROOT="$root" "$CS_BIN" -list 2>&1) || rc=$?
        assert_eq 0 "$rc" "cs -list under the root $root exits 0 (output: $out)" || return 1
        assert_eq 1 "$(printf '%s\n' "$out" | grep -c '^demo-x ')" \
            "cs -list under the root $root lists demo-x (output: $out)" || return 1
    done
}

echo ""
echo "Opening existing directories under the sessions root"
echo "===================================================="
echo ""

run_test test_flat_layout_migration_keeps_the_sessions_gitignore
run_test test_open_refuses_a_directory_that_is_not_a_session
run_test test_open_under_a_relative_sessions_root_makes_it_absolute

report_results
