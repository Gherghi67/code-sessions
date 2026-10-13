#!/usr/bin/env bash
# ABOUTME: Tests that cs helpers hand the C locale to the command that needs it, never to the shell,
# ABOUTME: and that each one prints the same exact bytes under every bash present.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
LIB="$SCRIPT_DIR/../lib"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Each helper below runs in a forked copy of the shell (a pipeline or a
# command substitution), and a bash linked against libintl can die when it
# changes its own locale there. Runs the shell code in $2 with bash $1, under
# a UTF-8 locale when this machine has one so a helper that drops its C
# locale prints something else, with the lib fragments sourced and set -x on.
# Prints what the code printed; the trace lands in $TEST_TMPDIR/trace.
_traced() {  # bash, shell code, args...
    local b="$1" code="$2" utf8
    shift 2
    utf8="$(utf8_locale)"
    env -i PATH="$PATH" HOME="$TEST_TMPDIR" ${utf8:+"LC_ALL=$utf8"} "$b" -c '
        lib="$1"; shift
        source "$lib/02-shared.sh"; source "$lib/30-worktree.sh"; source "$lib/65-sessions.sh"
        set -x
        '"$code" x "$LIB" "$@" 2>"$TEST_TMPDIR/trace"
}

# Asserts the trace of the last _traced run holds no locale assignment the
# shell made to itself.
_assert_no_shell_locale() {  # bash, helper name
    assert_eq "" "$(shell_locale_assignments "$TEST_TMPDIR/trace")" \
        "$1 must not assign its own locale inside $2" || return 1
}

# The complaint keeps printable ASCII only: each byte of the two-byte é and
# the control byte become "?". The "fatal:" line wins over the trace line.
test_git_complaint_keeps_printable_bytes_only() {
    local b out
    for b in $(every_bash); do
        out="$(_traced "$b" '_cs_git_complaint "$1"' "$(printf 'trace: one\nfatal: caf\303\251 \001x')")"
        assert_eq "fatal: caf?? ?x" "$out" "$b: the complaint, byte for byte" || return 1
        _assert_no_shell_locale "$b" _cs_git_complaint || return 1
    done
}

# The file name and the commit message keep only plain path characters: the
# space and each byte of é become "_".
test_untrack_notice_keeps_plain_path_bytes_only() {
    local b out
    for b in $(every_bash); do
        out="$(_traced "$b" 'cs_untrack_notice "$1" /top "$2"' "$(printf 'caf\303\251/a b')" 's*x')"
        assert_eq "caf__/a_b is tracked in git (per-actor state must stay local). Fix with: git -C /top --literal-pathspecs rm -r --cached -- s\\*x && git -C /top commit -m 'stop tracking s_x'" \
            "$out" "$b: the notice, byte for byte" || return 1
        _assert_no_shell_locale "$b" cs_untrack_notice || return 1
    done
}

# A .cs/private that leads to the session itself is named with no command,
# and the tracked file it reports keeps only plain path characters.
test_tracked_files_notice_names_a_link_to_the_session_in_plain_bytes() {
    local s="$TEST_TMPDIR/s" b out
    mkdir -p "$s/.cs"
    git -C "$s" init -q
    ln -s .. "$s/.cs/private"
    printf 'x\n' > "$s/$(printf 'caf\303\251')"
    git -C "$s" add "$(printf 'caf\303\251')"
    for b in $(every_bash); do
        out="$(_traced "$b" 'cs_tracked_files_notice "$1" "$2"' "$s/.cs/private" "$s")"
        assert_eq ".cs/private leads to a directory that holds this session's own files, where git tracks caf__ (per-actor state must stay local). Make .cs/private a directory of its own." \
            "$out" "$b: the notice, byte for byte" || return 1
        _assert_no_shell_locale "$b" cs_tracked_files_notice || return 1
    done
}

# Every untracked and ignored name but cs's own, one a line in git's byte
# order: a newline inside a name shows as "?", and a multibyte name passes
# through whole.
test_worktree_untracked_at_risk_lists_names_as_bytes() {
    local w="$TEST_TMPDIR/w" b out
    mkdir -p "$w/.cs"
    git -C "$w" init -q
    printf '*.log\n' > "$w/.gitignore"
    : > "$w/.cs/x"
    : > "$w/a.log"
    : > "$w/keep"
    : > "$w/$(printf 'caf\303\251')"
    : > "$w/$(printf 'na\nme')"
    for b in $(every_bash); do
        out="$(_traced "$b" '_worktree_untracked_at_risk "$1"' "$w")"
        assert_eq "$(printf '.gitignore\ncaf\303\251\nkeep\nna?me\na.log')" "$out" \
            "$b: the names at risk, byte for byte" || return 1
        _assert_no_shell_locale "$b" _worktree_untracked_at_risk || return 1
    done
}

# Untracked entries but cs's own, in C-locale byte order: uppercase before
# "_" before lowercase.
test_worktree_untracked_entries_sorts_in_byte_order() {
    local d="$TEST_TMPDIR/d" b out
    mkdir -p "$d/.cs"
    git -C "$d" init -q
    : > "$d/.cs/y"
    : > "$d/B"
    : > "$d/_x"
    : > "$d/a"
    for b in $(every_bash); do
        out="$(_traced "$b" '_worktree_untracked_entries "$1"' "$d")"
        assert_eq "B, _x, a" "$out" "$b: the entries, byte for byte" || return 1
        _assert_no_shell_locale "$b" _worktree_untracked_entries || return 1
    done
}

echo ""
echo "Shell locale tests"
echo "=================="
echo ""

run_test test_git_complaint_keeps_printable_bytes_only
run_test test_untrack_notice_keeps_plain_path_bytes_only
run_test test_tracked_files_notice_names_a_link_to_the_session_in_plain_bytes
run_test test_worktree_untracked_at_risk_lists_names_as_bytes
run_test test_worktree_untracked_entries_sorts_in_byte_order

report_results
