#!/usr/bin/env bash
# ABOUTME: Tests opening a directory that already exists under the sessions root: a flat-layout
# ABOUTME: session migrates into .cs/ keeping its .gitignore, and a non-session directory is refused.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# A flat-layout session cs created long ago (its logs/session.log opens with
# cs's header), in a git repo whose .gitignore hides a key file. The structural
# migration merges cs's rules into that file, so the user's rule must still be
# there for their next `git add`.
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

# The structural migration moves the flat layout into .cs/ and commits
# nothing: the moves stay in the working tree, and one line names what the
# user is left to commit.
test_flat_layout_migration_commits_nothing() {
    local dir="$CS_SESSIONS_ROOT/flat-session" head_before out
    mkdir -p "$dir/logs"
    printf 'Claude Code Session Log\nSession: flat-session\n' > "$dir/logs/session.log"
    printf '# Session: flat-session\n' > "$dir/README.md"
    printf '# Session Documentation Protocol\n' > "$dir/CLAUDE.md"
    (cd "$dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m initial)
    head_before=$(git -C "$dir" rev-parse HEAD)

    out=$("$CS_BIN" flat-session <<< "" 2>&1 || true)

    assert_eq "$head_before" "$(git -C "$dir" rev-parse HEAD)" "the migration makes no commit" || return 1
    assert_eq "" "$(git -C "$dir" diff --cached --name-only)" "and stages nothing" || return 1
    assert_file_exists "$dir/.cs/README.md" "the README moved into .cs/ in the working tree" || return 1
    assert_file_not_exists "$dir/README.md" "and left the root" || return 1
    assert_eq "README.md" "$(git -C "$dir" ls-files README.md)" "git still tracks the README at the root" || return 1
    assert_eq "" "$(git -C "$dir" ls-files .cs)" "and nothing under .cs/" || return 1
    assert_output_contains "$out" "cs committed nothing; it left .cs/, logs/, README.md, .gitignore and .gitattributes for you to commit" \
        "one line names what the migration left" || return 1
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

echo ""
echo "Opening existing directories under the sessions root"
echo "===================================================="
echo ""

run_test test_flat_layout_migration_keeps_the_sessions_gitignore
run_test test_flat_layout_migration_commits_nothing
run_test test_open_refuses_a_directory_that_is_not_a_session

report_results
