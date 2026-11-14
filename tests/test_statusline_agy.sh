#!/usr/bin/env bash
# ABOUTME: Tests for bin/cs-statusline-agy, the Antigravity status line that runs cs-statusline on agy's payload
# ABOUTME: Covers the payload mapping, stamps left alone, exits that never fail agy, and cs -statusline's agy report

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

ADAPTER="$SCRIPT_DIR/../bin/cs-statusline-agy"
SL="$SCRIPT_DIR/../bin/cs-statusline"
unset CS_BIN
CS_BIN="$SCRIPT_DIR/../bin/cs"

# agy 1.5.9's payload after one turn, as a live probe recorded it (email and
# paths changed). The model and quota are agy's own line's; cost and title
# stayed null.
AGY_AFTER_TURN='{"cwd":"/work/agysess","session_id":"6778f9f7-33fb-4aa5-8194-f0142b7a86ea","conversation_id":"6778f9f7-33fb-4aa5-8194-f0142b7a86ea","transcript_path":"/x/transcript.jsonl","model":{"id":"Gemini 4 Argon (Medium)","display_name":"Gemini 4 Argon (Medium)","effort":"medium"},"workspace":{"current_dir":"/work/agysess","project_dir":"/work/agysess"},"version":"1.5.9","context_window":{"total_input_tokens":14891,"total_output_tokens":5,"context_window_size":1048576,"used_percentage":1.4201164245605469,"remaining_percentage":98.57988357543945,"current_usage":{"input_tokens":10458,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"exceeds_200k_tokens":false,"product":"antigravity","quota":{"gemini-5h":{"remaining_fraction":0.4,"reset_time":"2026-11-14T20:42:16Z","reset_in_seconds":17960}},"agent_state":"idle","cycle_mode":"auto","sandbox":{"enabled":false},"plan_tier":"Google AI Pro","terminal_width":160}'
# The same run idle before its first turn: the model is known, and the
# context reads 0 of a window agy has sized.
AGY_BEFORE_TURN='{"cwd":"/work/agysess","session_id":"","conversation_id":"","model":{"id":"Gemini 4 Argon (Medium)","display_name":"Gemini 4 Argon (Medium)","effort":"medium"},"workspace":{"current_dir":"/work/agysess","project_dir":"/work/agysess"},"context_window":{"total_input_tokens":0,"total_output_tokens":0,"context_window_size":1048576,"used_percentage":0,"remaining_percentage":100,"current_usage":null},"agent_state":"idle","terminal_width":160}'
# While agy authenticates: no model, and a window of size 0.
AGY_STARTING='{"cwd":"/work/agysess","session_id":"","model":null,"workspace":{"current_dir":"/work/agysess"},"context_window":{"total_input_tokens":0,"context_window_size":0,"used_percentage":0},"agent_state":"authenticating","terminal_width":80}'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in
            CS_*|CLAUDE_*|NO_COLOR|COLORTERM|TERM_PROGRAM|FORCE_COLOR|TMUX|TMUX_PANE|COLORFGBG|ITERM_PROFILE|LC_TERMINAL|SSH_CONNECTION|AGY_BIN)
                unset "$_v" 2>/dev/null || true ;;
        esac
    done < <(env)
    unset COLUMNS 2>/dev/null || true
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export HOME="$TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$TEST_TMPDIR/xdg"
    mkdir -p "$CS_SESSIONS_ROOT" "$HOME" "$XDG_CONFIG_HOME/cs"
    export TERM="xterm-256color" CS_TERM_THEME="light"
    export CS_SECURITY_BIN="$TEST_TMPDIR/no-such-security"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/no-such-config"
}

teardown() {
    [ -z "${TEST_TMPDIR:-}" ] || rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CS_TERM_THEME CS_SECURITY_BIN CLAUDE_CONFIG_DIR CLAUDE_SESSION_NAME \
        CS_INSTALL_DIR CS_CLAUDE_DIR CS_CONFIG_DIR AGY_BIN NO_COLOR STUB_ENV STUB_IN STUB_DIR 2>/dev/null || true
}

# A copy of the adapter beside a stub renderer that records the environment
# it names and the payload it got, in an install folder of the test's own,
# STUB_DIR.
_stub_install() {
    local dir="$TEST_TMPDIR/stub-bin"
    mkdir -p "$dir"
    cp "$ADAPTER" "$dir/cs-statusline-agy"
    cat > "$dir/cs-statusline" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${CS_STATUSLINE_ENGINE:-unset} ${CS_STATUSLINE_PARENT:-unset}" > "$STUB_ENV"
cat > "$STUB_IN"
printf 'stub line\n'
exit "${STUB_EXIT:-0}"
STUB
    chmod +x "$dir/cs-statusline-agy" "$dir/cs-statusline"
    export STUB_ENV="$TEST_TMPDIR/stub-env" STUB_IN="$TEST_TMPDIR/stub-in"
    STUB_DIR=$dir
}

# The adapter hands cs-statusline the session, folder, context and width,
# under Claude Code's names, and nothing of the model, quota or cost, which
# agy's own line shows. It names the engine, and agy as the parent every
# repaint shares: the shell that runs the adapter stands in for agy.
test_the_adapter_maps_agy_payload_onto_cs_statusline_input() {
    local dir out
    _stub_install
    dir=$STUB_DIR
    printf '%s' "$AGY_AFTER_TURN" > "$TEST_TMPDIR/payload"
    out=$(bash -c 'printf "%s\n" "$$" > "$1"; "$2" < "$3"; :' _ \
        "$TEST_TMPDIR/agy-pid" "$dir/cs-statusline-agy" "$TEST_TMPDIR/payload") \
        || { echo "  FAIL: the adapter failed"; return 1; }
    assert_eq "stub line" "$out" "the renderer's line is the adapter's" || return 1
    assert_eq "antigravity $(cat "$TEST_TMPDIR/agy-pid")" "$(cat "$STUB_ENV")" \
        "the renderer is told the engine, and agy's pid as its parent" || return 1
    assert_eq '{"columns":160,"context_window":{"used_percentage":1.4201164245605469},"cwd":"/work/agysess","session_id":"6778f9f7-33fb-4aa5-8194-f0142b7a86ea","workspace":{"current_dir":"/work/agysess"}}' \
        "$(jq -cS . "$STUB_IN")" "only the session, folder, context and width go over" || return 1
}

# agy reads the context as 0 before the first turn, and sizes the window only
# once the model is known; Claude Code sends no reading then, and the bar
# shows none.
test_the_context_waits_for_the_first_turn() {
    local dir
    _stub_install
    dir=$STUB_DIR
    printf '%s' "$AGY_BEFORE_TURN" | "$dir/cs-statusline-agy" > /dev/null
    assert_eq "null" "$(jq -c .context_window.used_percentage "$STUB_IN")" "no reading before the first turn" || return 1
    printf '%s' "$AGY_STARTING" | "$dir/cs-statusline-agy" > /dev/null
    assert_eq "null" "$(jq -c .context_window.used_percentage "$STUB_IN")" "no reading while the window is unsized" || return 1
    assert_eq "80" "$(jq -c .columns "$STUB_IN")" "the width still goes over" || return 1
}

# agy turns a custom line off after a run of failures, so nothing the adapter
# meets fails it: input that is not JSON, fields of the wrong type, a renderer
# that fails or is missing, no jq.
test_the_adapter_never_fails_agy() {
    local dir out status
    _stub_install
    dir=$STUB_DIR
    status=0
    out=$(printf 'not json' | "$dir/cs-statusline-agy") || status=$?
    assert_eq "0:" "$status:$out" "input that is not JSON prints nothing" || return 1
    status=0
    printf '%s' '{"workspace":"x","context_window":5,"terminal_width":"wide","session_id":7}' \
        | "$dir/cs-statusline-agy" > /dev/null || status=$?
    assert_eq "0" "$status" "fields of the wrong type are taken as missing" || return 1
    assert_eq '{"columns":null,"context_window":{"used_percentage":null},"cwd":"","session_id":"","workspace":{"current_dir":""}}' \
        "$(jq -cS . "$STUB_IN")" "and none of them goes over" || return 1
    status=0
    printf '%s' "$AGY_AFTER_TURN" | STUB_EXIT=3 "$dir/cs-statusline-agy" > /dev/null || status=$?
    assert_eq "0" "$status" "a failing renderer does not fail agy" || return 1
    mkdir -p "$TEST_TMPDIR/nojq"
    ln -s "$(command -v dirname)" "$TEST_TMPDIR/nojq/dirname"
    rm -f "$STUB_IN"
    status=0
    out=$(printf '%s' "$AGY_AFTER_TURN" | PATH="$TEST_TMPDIR/nojq" "$BASH" "$dir/cs-statusline-agy") || status=$?
    assert_eq "0:" "$status:$out" "without jq the adapter prints nothing" || return 1
    assert_not_exists "$STUB_IN" "and runs no renderer" || return 1
    rm -f "$dir/cs-statusline"
    status=0
    out=$(printf '%s' "$AGY_AFTER_TURN" | "$dir/cs-statusline-agy") || status=$?
    assert_eq "0:" "$status:$out" "a missing renderer prints nothing" || return 1
}

# Through the real renderer, in a session cs launched: the session name and
# the context show, agy's model and quota do not. The context-pct and limits
# stamps Claude's hooks read, and the width record the cs mod reads, stay
# unwritten; the same reading from Claude Code writes them, so it is the
# engine that keeps them out.
test_the_real_render_shows_the_session_and_stamps_nothing() {
    local dir="$CS_SESSIONS_ROOT/agysess/.cs/local" out
    mkdir -p "$dir"
    # The conversation the launch recorded, so a Claude Code render here is
    # the lead's and writes every stamp.
    printf 'claude_session_id: 6778f9f7-33fb-4aa5-8194-f0142b7a86ea\n' > "$dir/state"
    out=$(printf '%s' "$AGY_AFTER_TURN" | NO_COLOR=1 CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_PARENT=4242 \
        "$BASH" "$ADAPTER") || { echo "  FAIL: the render failed"; return 1; }
    assert_eq "agysess > ○ ctx 1%" "$out" "the session and its context" || return 1
    assert_not_exists "$dir/context-pct" "no context-pct for Claude's gates" || return 1
    assert_not_exists "$dir/statusline-width" "no width record for the cs mod" || return 1
    assert_not_exists "$dir/limits" "no limits stamp" || return 1
    printf '%s' '{"session_id":"6778f9f7-33fb-4aa5-8194-f0142b7a86ea","workspace":{"current_dir":"/work/agysess"},"context_window":{"used_percentage":1.42},"rate_limits":{"five_hour":{"used_percentage":10}}}' \
        | NO_COLOR=1 CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_PARENT=4242 "$BASH" "$SL" > /dev/null
    assert_eq "1" "$(cat "$dir/context-pct" 2>/dev/null)" "Claude Code's render stamps the context" || return 1
    assert_exists "$dir/limits" "and the limits" || return 1
    assert_exists "$dir/statusline-width" "and the width record" || return 1
}

# cs -statusline names Antigravity where agy is: enable says whether the next
# launch passes the line, disable that it stops, and either leaves agy's
# settings.json as it was. Disable records the choice in a marker of agy's own,
# which enable removes; the installer's Claude decline is a different file.
# Where agy is not, it says nothing of it, and the marker still follows.
test_statusline_command_reports_antigravity() {
    local out settings="$HOME/.gemini/antigravity-cli/settings.json"
    export CS_INSTALL_DIR="$TEST_TMPDIR/install" CS_CLAUDE_DIR="$TEST_TMPDIR/claude" CS_CONFIG_DIR="$TEST_TMPDIR/config"
    mkdir -p "$CS_INSTALL_DIR" "${settings%/*}"
    cp "$ADAPTER" "$SL" "$CS_INSTALL_DIR/"
    printf '{"trustedWorkspaces":[]}\n' > "$settings"
    cp "$settings" "$TEST_TMPDIR/settings.before"
    out=$("$CS_BIN" -statusline enable 2>&1) || { echo "  FAIL: enable failed: $out"; return 1; }
    assert_output_contains "$out" "Antigravity sessions cs starts show it under agy's own line" || return 1
    out=$("$CS_BIN" -statusline disable 2>&1) || { echo "  FAIL: disable failed: $out"; return 1; }
    assert_output_contains "$out" "Antigravity sessions cs starts no longer show it" || return 1
    assert_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "the launch's off switch is recorded" || return 1
    printf '{"statusLine":{"command":"my-line"}}\n' > "$settings"
    cp "$settings" "$TEST_TMPDIR/settings.before"
    out=$("$CS_BIN" -statusline enable 2>&1) || { echo "  FAIL: enable failed: $out"; return 1; }
    assert_output_contains "$out" "Antigravity has a status line of your own in $settings" || return 1
    assert_not_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "enable takes the off switch back" || return 1
    assert_eq "$(cat "$TEST_TMPDIR/settings.before")" "$(cat "$settings")" "agy's settings are never written" || return 1
    rm -rf "$HOME/.gemini"
    export AGY_BIN="$TEST_TMPDIR/no-agy"
    out=$("$CS_BIN" -statusline disable 2>&1) || { echo "  FAIL: disable failed: $out"; return 1; }
    assert_output_not_contains "$out" "Antigravity" "nothing is said where agy is not" || return 1
    assert_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "the choice holds for an agy installed later" || return 1
    out=$("$CS_BIN" -statusline enable 2>&1) || { echo "  FAIL: enable failed: $out"; return 1; }
    assert_output_not_contains "$out" "Antigravity" "nor on enable" || return 1
    assert_not_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "and enable clears it there too" || return 1
}

run_test test_the_adapter_maps_agy_payload_onto_cs_statusline_input
run_test test_the_context_waits_for_the_first_turn
run_test test_the_adapter_never_fails_agy
run_test test_the_real_render_shows_the_session_and_stamps_nothing
run_test test_statusline_command_reports_antigravity
report_results
