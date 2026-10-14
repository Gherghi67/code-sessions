#!/usr/bin/env bash
# ABOUTME: Tests opening under the sessions root: a flat-layout session migrates into .cs/ keeping its
# ABOUTME: .gitignore, a non-session directory is refused, and a relative root is made absolute first.

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
    assert_eq "secret.key" "$(git -C "$dir" check-ignore secret.key)" \
        "git still ignores the key file" || return 1
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
    assert_eq "tracked" "$(awk -F': ' '/^cs_mode:/{print $2}' "$dir/.cs/local/state")" \
        "the session records that git is to carry .cs" || return 1
}

# The migration records the mode the session's features take, as adopt does.
# A user who then commits only the tracked side of the moves (git add -u)
# leaves .cs untracked, so a feature is refused instead of hiding the base's
# .cs from git through the common info/exclude.
test_feature_of_a_migrated_session_waits_for_git_to_carry_cs() {
    local dir="$CS_SESSIONS_ROOT/flat-session" out rc=0
    mkdir -p "$dir/logs"
    printf 'Claude Code Session Log\nSession: flat-session\n' > "$dir/logs/session.log"
    printf '# Session: flat-session\n' > "$dir/README.md"
    printf '# Session Documentation Protocol\n' > "$dir/CLAUDE.md"
    (cd "$dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m initial)
    "$CS_BIN" flat-session <<< "" >/dev/null 2>&1 || true
    (cd "$dir" && git add -u && git commit -q -m "commit the moves of tracked files") \
        || { echo "  FAIL: commit fixture"; return 1; }

    out=$("$CS_BIN" flat-session@t < /dev/null 2>&1) || rc=$?

    assert_eq 1 "$rc" "the feature is refused" || return 1
    assert_eq "Error: Session 'flat-session' expects git to carry .cs (cs_mode: tracked in $dir/.cs/local/state), but git tracks nothing under .cs there. Commit it first (git add .cs .gitignore .gitattributes, then git commit, in $dir), or set that line to 'cs_mode: ignored' to keep .cs out of git, which features then hide through .git/info/exclude." \
        "$out" "the refusal names both ways on" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/flat-session@t" "no worktree is created" || return 1
    assert_eq "" "$(git -C "$dir" branch --list cs/t)" "no branch is created" || return 1
    assert_file_not_contains "$dir/.git/info/exclude" '^\.cs/$' "the base's .cs is not hidden from git" || return 1
    assert_eq "?? .cs/" "$(git -C "$dir" status --porcelain -- .cs)" "git still shows the base's .cs" || return 1
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
run_test test_flat_layout_migration_commits_nothing
run_test test_feature_of_a_migrated_session_waits_for_git_to_carry_cs
run_test test_open_refuses_a_directory_that_is_not_a_session
run_test test_open_under_a_relative_sessions_root_makes_it_absolute

report_results
