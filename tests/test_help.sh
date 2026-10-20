#!/usr/bin/env bash
# ABOUTME: Smoke tests for `cs -help` / `cs -version` output integrity
# ABOUTME: Guards against the unquoted-heredoc command-substitution regression

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# `cs -help` is a `cat << EOF` heredoc. It must not command-substitute its body:
# backticks/$(...) in the help text would run as commands. Regression: the
# tmux "allow-passthrough on" mention was backtick-quoted, so bash executed it
# ("command not found") and dropped the text from the output.
test_help_no_command_substitution() {
    local out
    out=$("$CS_BIN" -help 2>&1)
    assert_output_not_contains "$out" "command not found" \
        "cs -help must not execute its own help text" || return 1
    assert_output_contains "$out" "Usage: cs" \
        "help must document cs as the primary command" || return 1
    assert_output_contains "$out" "allow-passthrough on" \
        "the literal help text must survive (not be command-substituted away)"
}

test_help_names_the_fork_and_its_launcher() {
    local out
    out=$("$CS_BIN" -help 2>&1)
    assert_output_contains "$out" "code-sessions, a fork of cs" "the header names the fork" || return 1
    assert_output_contains "$out" "starts as ccs (or code-sessions)" "and the launcher to type in a terminal" || return 1
}

test_version_prints_clean() {
    local out
    out=$("$CS_BIN" -version 2>&1)
    assert_output_not_contains "$out" "command not found" "cs -version must be clean" || return 1
    assert_output_contains "$out" "cs " "cs -version should print the primary version line" || return 1
    assert_output_contains "$out" "(code-sessions, a fork of cs)" "the version line names the fork" || return 1
}

# The cs mod, the rotate skill and /wrap ask cs -vet-session before they write
# into a session; a user reading why a rotation did not arm finds it in the
# help.
test_vet_session_answers_help() {
    local out rc=0
    out=$("$CS_BIN" -vet-session --help 2>&1) || rc=$?
    assert_eq "0" "$rc" "cs -vet-session --help exits 0" || return 1
    assert_eq "Usage:
  -vet-session <dir>  Exit 0 when git tracks no file in <dir>'s .cs/local or .cs/private, else name the file and how to untrack it (the cs mod, /rotate and /wrap ask before they write there)" \
        "$out" "and prints its usage line" || return 1
}

echo ""
echo "cs help/version tests"
echo "====================="
echo ""

run_test test_help_no_command_substitution
run_test test_help_names_the_fork_and_its_launcher
run_test test_version_prints_clean
run_test test_vet_session_answers_help

report_results
