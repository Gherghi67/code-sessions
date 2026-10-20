#!/usr/bin/env bash
# ABOUTME: Tests that dot/dot-dot session names are rejected on create and remove
# ABOUTME: Guards against `cs ..` restructuring $HOME and `cs -rm ../x` escaping the sessions root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# `cs ..` resolves session_dir to the sessions-root parent (== $HOME in real use)
# and would run migrate_session against it. It must be rejected as an invalid name.
test_create_rejects_dotdot() {
    local parent output status=0
    parent="$(dirname "$CS_SESSIONS_ROOT")"
    output=$("$CS_BIN" ".." < /dev/null 2>&1) || status=$?
    assert_output_contains "$output" "Session name" "cs .. must be rejected as invalid" || return 1
    assert_not_exists "$parent/.cs" "cs .. must not create .cs in the sessions-root parent" || return 1
    assert_not_exists "$parent/CLAUDE.md" "cs .. must not write a CLAUDE.md in the parent" || return 1
}

# `cs .` run from the sessions root: the root is not a session, so it is refused.
test_create_rejects_dot() {
    local output status=0
    output=$(cd "$CS_SESSIONS_ROOT" && "$CS_BIN" "." < /dev/null 2>&1) || status=$?
    # `cs .` means "the session I am standing in"; the sessions root is not one,
    # so it is refused rather than opened, created or migrated as a session '.'.
    assert_output_contains "$output" "Not a cs session" "cs . outside a session must be refused" || return 1
    assert_eq "1" "$status" "cs . outside a session must exit non-zero" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/.cs" "cs . must not migrate the sessions root" || return 1
}

# Dotted names like a version tag are legitimate and must still work.
test_create_allows_dotted_name() {
    local output status=0
    output=$("$CS_BIN" "v2026.7.4" < /dev/null 2>&1) || status=$?
    assert_eq "0" "$status" "a normal dotted name must still launch, got: $output" || return 1
    assert_dir "$CS_SESSIONS_ROOT/v2026.7.4" "dotted session name is created" || return 1
}

# cs keeps its own staging dirs at the sessions root under leading-dot names
# (.spawn/, .usage/). A session name may not start with a dot, so `cs .spawn`
# is refused rather than migrating that dir into a session.
test_create_rejects_a_leading_dot() {
    local output status=0
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'seed\n' > "$CS_SESSIONS_ROOT/.spawn/example.seed"
    output=$("$CS_BIN" ".spawn" < /dev/null 2>&1) || status=$?
    assert_eq "1" "$status" "cs .spawn must exit non-zero" || return 1
    assert_output_contains "$output" "Session name cannot start with a dot" "says why it refused" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/.spawn/.cs" "cs .spawn must not migrate the staging dir" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/example.seed" "the staged seed is untouched" || return 1
}

# `cs -rm ..` would rm -rf the sessions-root parent. Must be rejected before removal.
test_remove_rejects_dotdot() {
    local parent output status=0
    parent="$(dirname "$CS_SESSIONS_ROOT")"
    printf 'sentinel\n' > "$parent/keepme.txt"
    output=$(printf 'y\n' | "$CS_BIN" -rm ".." 2>&1) || status=$?
    assert_output_contains "$output" "Invalid session name" "cs -rm .. must be rejected as invalid" || return 1
    assert_file_exists "$parent/keepme.txt" "cs -rm .. must not touch the sessions-root parent" || return 1
}

# A traversal target must also be rejected (name contains a slash).
test_remove_rejects_traversal() {
    local parent output status=0
    parent="$(dirname "$CS_SESSIONS_ROOT")"
    mkdir -p "$parent/victim"
    output=$(printf 'y\n' | "$CS_BIN" -rm "../victim" 2>&1) || status=$?
    assert_output_contains "$output" "Invalid session name" "cs -rm ../victim must be rejected as invalid" || return 1
    assert_dir "$parent/victim" "cs -rm ../victim must not delete a dir outside the sessions root" || return 1
}

run_test test_create_rejects_dotdot
run_test test_create_rejects_dot
run_test test_create_allows_dotted_name
run_test test_create_rejects_a_leading_dot
run_test test_remove_rejects_dotdot
run_test test_remove_rejects_traversal

# A name cs creates is also a name cs must be able to dispatch back. Bare `cs`
# in a session directory re-enters as `cs <name>`, and a leading hyphen lands
# in the verb arms: a session named -uninstall would run that verb instead of
# opening, and one named -rm would reach remove_session.
test_a_leading_hyphen_is_rejected() {
    local out rc=0
    out=$(CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions" "$CS_BIN" -adopt -uninstall 2>&1 </dev/null) || rc=$?
    assert_eq 1 "$rc" "a leading-hyphen name is refused" || return 1
    assert_eq "Error: cs -adopt: unknown option '-uninstall'. Usage: cs -adopt <name> [--yes] [--engine claude|codex]" "$out" \
        "adopt reads it as an option it does not know" || return 1
    if [ -e "$TEST_TMPDIR/sessions/-uninstall" ] || [ -L "$TEST_TMPDIR/sessions/-uninstall" ]; then
        echo "  FAIL: a session named -uninstall was made"; return 1
    fi
}

run_test test_a_leading_hyphen_is_rejected

report_results
