#!/usr/bin/env bash
# ABOUTME: Tests for the shared assertions in test_lib.sh that every suite uses
# ABOUTME: A broken assertion reports the wrong verdict for every test at once

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Big enough that the writer cannot finish before an early-matching reader
# exits. The pipe buffer is the threshold that matters, not any round number.
big_output() {  # first line
    printf '%s\n' "$1"
    head -c 200000 /dev/zero | tr '\0' 'x' | fold -w 100
}

# ============================================================================
# Tests
# ============================================================================

# A pattern that matches on the FIRST line of a large output is the worst case:
# an early-exiting reader closes the pipe while the writer still has most of the
# payload to push. Piped, the writer dies of SIGPIPE, pipefail promotes 141 to
# the pipeline status, and the assertion reports a match as a failure -- turning
# a passing test red for reasons that have nothing to do with what it tests.
test_output_contains_survives_an_early_match_in_a_large_output() {
    local out
    out="$(big_output MATCH_ON_LINE_ONE)"
    assert_output_contains "$out" "MATCH_ON_LINE_ONE" \
        "an early match in a large output must be reported as a match" || return 1
}

test_output_not_contains_survives_a_large_output() {
    local out
    out="$(big_output MATCH_ON_LINE_ONE)"
    assert_output_not_contains "$out" "PATTERN_THAT_IS_ABSENT" \
        "an absent pattern in a large output must be reported as absent" || return 1
}

# The repair must not have made the assertions unconditionally true: each one
# still has to report the case it exists to catch.
test_output_contains_still_fails_on_a_real_miss() {
    local rc=0
    assert_output_contains "hello" "goodbye" "expected-miss" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { echo "assert_output_contains passed on a genuine miss"; return 1; }
}

test_output_not_contains_still_fails_on_a_real_hit() {
    local rc=0
    assert_output_not_contains "hello" "hello" "expected-hit" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { echo "assert_output_not_contains passed on a genuine hit"; return 1; }
}

# cs's live-duplicate guard scans the whole machine's process table for the
# session name or its UUID. Suites run in parallel and fifteen of them launch a
# session called test-session, so a suite that reads the real `ps` intermittently
# sees a sibling suite's process and reports the session as already running. The
# process table is a shared resource like ~/.claude/projects and the terminal:
# setup() has to isolate it, or the isolation depends on every test author
# remembering the seam.
# The first version of this test called the shared setup() and passed, while two
# dozen suites that define their own setup() went on reading the real ps. A test
# that only proves the invariant where the fix already applies is worse than no
# test: it reports the exposure as closed. Assert the property a suite with its
# own setup() actually gets.
test_process_table_isolation_survives_a_suite_that_overrides_setup() {
    local probe="$TEST_TMPDIR/probe.sh"
    cat > "$probe" <<PROBE
#!/usr/bin/env bash
SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/test_lib.sh"
setup() { :; }   # the pattern 24 suites use
setup
[ -n "\${CS_PS_BIN:-}" ] || { echo MISSING; exit 1; }
"\$CS_PS_BIN" -Ao args= | head -1
echo "OK"
PROBE
    chmod +x "$probe"
    local out
    out=$(/bin/bash "$probe" 2>&1) || { echo "  FAIL: probe suite errored: $out"; return 1; }
    case "$out" in
        MISSING*) echo "  FAIL: a suite with its own setup() gets no CS_PS_BIN"; return 1 ;;
        OK) : ;;
        *) echo "  FAIL: the argv scan returned output for an overriding suite: $out"; return 1 ;;
    esac
}

# The stub must not blind the other ps consumers: the lock's ancestry walk and
# presence's pid join read real per-process facts through the same seam.
test_process_table_stub_passes_through_other_ps_forms() {
    local out
    out=$("$CS_PS_BIN" -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')
    case "$out" in
        ''|*[!0-9]*) echo "  FAIL: -o ppid= must return this process's real parent, got '$out'"; return 1 ;;
    esac
}

test_setup_isolates_the_process_table() {
    [ -n "${CS_PS_BIN:-}" ] \
        || { echo "  FAIL: setup() must export CS_PS_BIN so no test reads the real ps"; return 1; }
    [ -x "$CS_PS_BIN" ] \
        || { echo "  FAIL: CS_PS_BIN must point at an executable stub: $CS_PS_BIN"; return 1; }
    local out
    out="$("$CS_PS_BIN" -Ao args= 2>/dev/null)"
    [ -z "$out" ] \
        || { echo "  FAIL: the default ps stub must report no processes, got: $out"; return 1; }
}

# Write a throwaway suite that sources test_lib.sh and replaces setup(), the
# way 24 suites do, then runs the given body. Prints the suite's path; the
# caller runs it with the environment it wants the suite to inherit.
_overriding_suite() {  # body, as bash source
    local probe="$TEST_TMPDIR/probe.sh"
    {
        printf 'SCRIPT_DIR=%q\n' "$SCRIPT_DIR"
        printf 'source %q\n' "$SCRIPT_DIR/test_lib.sh"
        printf 'setup() { :; }\nsetup\n'
        printf 'TEST_TMPDIR=%q\n' "$TEST_TMPDIR"
        printf '%s\n' "$1"
    } > "$probe"
    echo "$probe"
}

# A suite started from inside a live cs session inherits that session's
# identity, and cs trusts it: a send under test files its sent copy in the
# caller's own mailbox and signs the mail with the caller's name. The caller is
# staged here rather than inherited, so the test holds on a runner that is in
# no session at all.
test_session_identity_does_not_reach_a_suite_from_its_caller() {
    local caller="$TEST_TMPDIR/caller" root="$TEST_TMPDIR/probe-sessions"
    mkdir -p "$caller/.cs/local/mail/out" "$root"
    local probe
    probe=$(_overriding_suite "export CS_SESSIONS_ROOT=$(printf '%q' "$root")"'
export CLAUDE_CODE_BIN="$(_make_env_stub)"
"$CS_BIN" target >/dev/null 2>&1 <<< ""
"$CS_BIN" target -msg "hello" >/dev/null 2>&1 <<< "" || { echo SEND_FAILED; exit 1; }')
    local out
    out=$(CLAUDE_SESSION_NAME=caller CLAUDE_SESSION_DIR="$caller" \
        CLAUDE_SESSION_META_DIR="$caller/.cs" /bin/bash "$probe" 2>&1) \
        || { echo "  FAIL: probe suite errored: $out"; return 1; }

    local delivered=("$root"/target/.cs/local/mail/new/*.json)
    [ -f "${delivered[0]}" ] && [ "${#delivered[@]}" -eq 1 ] \
        || { echo "  FAIL: the probe's send must deliver exactly one mail to its own fixture"; return 1; }
    assert_eq "0" "$(find "$caller/.cs/local/mail/out" -type f | wc -l | tr -d ' ')" \
        "a suite's send must leave its caller's sent mail alone" || return 1
    assert_eq "" "$(jq -r .from "${delivered[0]}")" \
        "a suite's mail must not be signed with its caller's session name" || return 1
}

# A feature worktree's shell also exports CS_SECRETS_SESSION, the base session
# its secrets are keyed to, and cs-secrets reads it ahead of the session name.
# A suite that stores a secret for its own fixture session would store it under
# the developer's base session instead: on the keychain backend, in the real
# keychain.
test_secrets_identity_does_not_reach_a_suite_from_its_caller() {
    local home="$TEST_TMPDIR/probe-home" root="$TEST_TMPDIR/probe-sessions"
    mkdir -p "$home" "$root"
    # set refuses a session the sessions root lacks, so the root holds both
    # names: a leaked caller-base would store, under the wrong name.
    local probe
    probe=$(_overriding_suite "export HOME=$(printf '%q' "$home") CS_SESSIONS_ROOT=$(printf '%q' "$root")"'
create_test_session fixture >/dev/null
create_test_session caller-base >/dev/null
export CS_SECRETS_BACKEND=encrypted CS_SECRETS_PASSWORD=fixture-password CLAUDE_SESSION_NAME=fixture
"$_CS_TEST_BIN/cs-secrets" set probe_key < <(printf v) >/dev/null 2>&1 || { echo SET_FAILED; exit 1; }')
    local out
    out=$(CS_SECRETS_SESSION=caller-base /bin/bash "$probe" 2>&1) \
        || { echo "  FAIL: probe suite errored: $out"; return 1; }

    assert_eq "fixture.enc" "$(cd "$home/.cs-secrets" && find . -name '*.enc' | sed 's|^\./||')" \
        "a suite's secret must be stored under its own fixture session" || return 1
}

# HOME is scoped at source time, but XDG_CONFIG_HOME outranks it for cs's
# per-machine preferences (the status line's declined and caps markers, the
# option-keys record, the rotation notice). Inherited, a suite's install,
# uninstall or statusline verb reads and deletes the developer's own.
test_config_home_does_not_reach_a_suite_from_its_caller() {
    local caller="$TEST_TMPDIR/caller-config" home="$TEST_TMPDIR/probe-home"
    mkdir -p "$caller" "$home"
    local probe
    probe=$(_overriding_suite "export HOME=$(printf '%q' "$home")"'
"$CS_BIN" -statusline caps off >/dev/null 2>&1 </dev/null || { echo CAPS_FAILED; exit 1; }')
    local out
    out=$(XDG_CONFIG_HOME="$caller" /bin/bash "$probe" 2>&1) \
        || { echo "  FAIL: probe suite errored: $out"; return 1; }

    [ -f "$home/.config/cs/statusline-caps" ] \
        || { echo "  FAIL: the probe's preference must land under its own HOME"; return 1; }
    assert_eq "0" "$(find "$caller" -type f | wc -l | tr -d ' ')" \
        "a suite's preference write must leave its caller's config home alone" || return 1
}

# CS_CLAUDE_DIR outranks HOME too, for Claude Code's settings.json. Inherited,
# a suite that enables or removes the status line under its fixture HOME
# rewrites the caller's settings to point at binaries the suite then deletes.
test_claude_dir_does_not_reach_a_suite_from_its_caller() {
    local caller="$TEST_TMPDIR/caller-claude" home="$TEST_TMPDIR/probe-home"
    mkdir -p "$caller" "$home"
    printf '{"statusLine":{"type":"command","command":"the-callers-own"}}\n' > "$caller/settings.json"
    local probe
    probe=$(_overriding_suite "export HOME=$(printf '%q' "$home")"'
"$CS_BIN" -statusline enable >/dev/null 2>&1 </dev/null || { echo ENABLE_FAILED; exit 1; }')
    local out
    out=$(CS_CLAUDE_DIR="$caller" /bin/bash "$probe" 2>&1) \
        || { echo "  FAIL: probe suite errored: $out"; return 1; }

    assert_eq "$home/.local/bin/cs-statusline" "$(jq -r .statusLine.command "$home/.claude/settings.json" 2>/dev/null)" \
        "the probe's registration must land under its own HOME" || return 1
    assert_eq "the-callers-own" "$(jq -r .statusLine.command "$caller/settings.json")" \
        "a suite's registration must leave its caller's settings alone" || return 1
}

# Claude Code hands a SessionStart hook CLAUDE_ENV_FILE and sources what the
# hook appends. A suite that drives the hook with that variable inherited
# appends its fixture session's identity to the caller's file.
test_env_file_does_not_reach_a_suite_from_its_caller() {
    local envfile="$TEST_TMPDIR/caller-env" dir="$TEST_TMPDIR/probe-sessions/fixture"
    mkdir -p "$dir/.cs/local"
    : > "$envfile"
    local probe
    probe=$(_overriding_suite "dir=$(printf '%q' "$dir")"'
export CS_SESSIONS_ROOT="${dir%/*}"
export CLAUDE_SESSION_NAME=fixture CLAUDE_SESSION_DIR="$dir" CLAUDE_SESSION_META_DIR="$dir/.cs"
printf "{\"session_id\":\"probe-conversation\",\"source\":\"startup\",\"cwd\":\"%s\",\"hook_event_name\":\"SessionStart\"}\n" "$dir" \
    | bash "$SCRIPT_DIR/../hooks/session-start.sh" >/dev/null 2>&1 || { echo HOOK_FAILED; exit 1; }')
    local out
    out=$(CLAUDE_ENV_FILE="$envfile" /bin/bash "$probe" 2>&1) \
        || { echo "  FAIL: probe suite errored: $out"; return 1; }

    [ -e "$dir/.cs/local/context-date/probe-conversation" ] \
        || { echo "  FAIL: the probe's hook must have run for its own fixture session"; return 1; }
    assert_eq "0" "$(wc -c < "$envfile" | tr -d ' ')" \
        "a suite's SessionStart must leave its caller's environment file alone" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "Test harness assertion tests"
echo "============================"
echo ""

# The skip column names a count only when a test was skipped: a suite with none
# reports passed and failed, and a returned 77 adds "N skipped" and the name.
# The suite runs with neither of the variables the gate and CI hand a suite, so
# a test sets exactly the ones it is about and the outer run's cannot leak in.
run_throwaway_suite() {  # body of the suite's tests, as bash source; [VAR=value...]
    local dir suite body="$1"
    shift
    dir="$(mktemp -d "${TMPDIR:-/tmp}/harness-suite.XXXXXX")"
    suite="$dir/test_throwaway.sh"
    {
        printf 'SCRIPT_DIR=%q\n' "$SCRIPT_DIR"
        printf 'source %q\n' "$SCRIPT_DIR/test_lib.sh"
        printf '%s\n' "$body"
        printf 'report_results\n'
    } > "$suite"
    env -u CS_TEST_REQUIRE_TOOLS -u CS_TEST_SKIP_LOG "$@" bash "$suite" 2>&1
    rm -rf "$dir"
}

test_results_line_omits_the_skip_column_when_nothing_skipped() {
    local out
    out="$(run_throwaway_suite 'test_ok() { return 0; }
run_test test_ok')"
    assert_output_contains "$out" "Results: 1/1 passed, 0 failed" "the tally must still print" || return 1
    assert_output_not_contains "$out" "skipped" "no skip column when no test was skipped" || return 1
}

test_results_line_counts_a_skip_when_a_test_returns_77() {
    local out
    out="$(run_throwaway_suite 'test_ok() { return 0; }
test_needs_a_tool() { return 77; }
run_test test_ok
run_test test_needs_a_tool')"
    assert_output_contains "$out" ", 1 skipped" "a returned 77 must be counted as skipped" || return 1
    assert_output_contains "$out" "test_needs_a_tool" "a skipped test must be named" || return 1
}

# A tool no machine has, so "not on PATH" never depends on the host.
ABSENT_TOOL=cs-harness-absent-tool

# CI declares the tools it installs. A test whose tool is declared and missing
# is a broken runner, not a missing optional tool: it fails, naming the tool,
# where a skip would read green having judged nothing.
test_require_tool_fails_when_a_declared_tool_is_missing() {
    local out
    out="$(run_throwaway_suite "test_needs_it() { require_tool $ABSENT_TOOL || return \$?; echo BODY-RAN; }
run_test test_needs_it" "CS_TEST_REQUIRE_TOOLS=age $ABSENT_TOOL")"
    assert_output_contains "$out" "    FAIL: $ABSENT_TOOL is not on PATH, and CS_TEST_REQUIRE_TOOLS says this run has it" \
        "the failure names the missing tool" || return 1
    assert_output_contains "$out" "Results: 0/1 passed, 1 failed" "a declared missing tool is a failure, not a skip" || return 1
    assert_output_not_contains "$out" "BODY-RAN" "the test stops at the guard" || return 1
}

# Undeclared, a missing tool is what it always was on a developer's machine.
test_require_tool_skips_when_an_undeclared_tool_is_missing() {
    local out
    out="$(run_throwaway_suite "test_needs_it() { require_tool $ABSENT_TOOL || return \$?; echo BODY-RAN; }
run_test test_needs_it" "CS_TEST_REQUIRE_TOOLS=age")"
    assert_output_contains "$out" "    SKIP: $ABSENT_TOOL not on PATH" "the skip names the missing tool" || return 1
    assert_output_contains "$out" "Results: 0/1 passed, 0 failed, 1 skipped" "an undeclared missing tool skips" || return 1
    assert_output_not_contains "$out" "BODY-RAN" "the test stops at the guard" || return 1
}

test_require_tool_runs_the_test_when_every_tool_is_present() {
    local out
    out="$(run_throwaway_suite "test_needs_it() { require_tool sh bash || return \$?; echo BODY-RAN; }
run_test test_needs_it" "CS_TEST_REQUIRE_TOOLS=sh")"
    assert_output_contains "$out" "BODY-RAN" "the body runs once the tools are found" || return 1
    assert_output_contains "$out" "Results: 1/1 passed, 0 failed" "a test with its tools passes" || return 1
}

# Suites wrap the guard in a helper. The helper's status is the verdict, so a
# caller that maps any non-zero to 77 turns the declared tool's failure back
# into a skip.
test_a_helper_around_require_tool_passes_the_failure_through() {
    local out
    out="$(run_throwaway_suite "_need_it() { require_tool sh $ABSENT_TOOL; }
test_needs_it() { _need_it || return \$?; echo BODY-RAN; }
run_test test_needs_it" "CS_TEST_REQUIRE_TOOLS=$ABSENT_TOOL")"
    assert_output_contains "$out" "    FAIL: $ABSENT_TOOL is not on PATH" "the helper's guard names the tool" || return 1
    assert_output_contains "$out" "Results: 0/1 passed, 1 failed" "the helper's failure reaches the tally" || return 1
}

# run_all.sh hands each suite a file to record its skips in, one line per
# skipped test: its name, a tab, and the reason when the guard knows it.
test_a_skip_is_recorded_with_its_reason() {
    local out record="$TEST_TMPDIR/skips"
    out="$(run_throwaway_suite "test_needs_it() { require_tool $ABSENT_TOOL || return \$?; }
test_odd_platform() { return 77; }
test_ok() { return 0; }
run_test test_needs_it
run_test test_odd_platform
run_test test_ok" "CS_TEST_SKIP_LOG=$record")"
    assert_eq "$(printf 'test_needs_it\t%s not on PATH\ntest_odd_platform\t' "$ABSENT_TOOL")" "$(cat "$record" 2>/dev/null)" \
        "each skip is recorded once, a tool's reason not leaking onto the next skip: $out" || return 1
}

run_test test_output_contains_survives_an_early_match_in_a_large_output
run_test test_output_not_contains_survives_a_large_output
run_test test_output_contains_still_fails_on_a_real_miss
run_test test_output_not_contains_still_fails_on_a_real_hit
run_test test_setup_isolates_the_process_table
run_test test_process_table_isolation_survives_a_suite_that_overrides_setup
run_test test_process_table_stub_passes_through_other_ps_forms
run_test test_session_identity_does_not_reach_a_suite_from_its_caller
run_test test_secrets_identity_does_not_reach_a_suite_from_its_caller
run_test test_config_home_does_not_reach_a_suite_from_its_caller
run_test test_claude_dir_does_not_reach_a_suite_from_its_caller
run_test test_env_file_does_not_reach_a_suite_from_its_caller
run_test test_results_line_omits_the_skip_column_when_nothing_skipped
run_test test_results_line_counts_a_skip_when_a_test_returns_77
run_test test_require_tool_fails_when_a_declared_tool_is_missing
run_test test_require_tool_skips_when_an_undeclared_tool_is_missing
run_test test_require_tool_runs_the_test_when_every_tool_is_present
run_test test_a_helper_around_require_tool_passes_the_failure_through
run_test test_a_skip_is_recorded_with_its_reason
report_results
