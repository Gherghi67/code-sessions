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
# paths changed). The model is agy's own line's; cost and title stayed null.
AGY_AFTER_TURN='{"cwd":"/work/agysess","session_id":"6778f9f7-33fb-4aa5-8194-f0142b7a86ea","conversation_id":"6778f9f7-33fb-4aa5-8194-f0142b7a86ea","transcript_path":"/x/transcript.jsonl","model":{"id":"Gemini 4 Argon (Medium)","display_name":"Gemini 4 Argon (Medium)","effort":"medium"},"workspace":{"current_dir":"/work/agysess","project_dir":"/work/agysess"},"version":"1.5.9","context_window":{"total_input_tokens":14891,"total_output_tokens":5,"context_window_size":1048576,"used_percentage":1.4201164245605469,"remaining_percentage":98.57988357543945,"current_usage":{"input_tokens":10458,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"exceeds_200k_tokens":false,"product":"antigravity","quota":{"gemini-5h":{"remaining_fraction":0.4,"reset_time":"2026-11-14T20:42:16Z","reset_in_seconds":17960}},"agent_state":"idle","cycle_mode":"auto","sandbox":{"enabled":false},"plan_tier":"Google AI Pro","terminal_width":160}'
# The same run idle before its first turn: the model is known, and the
# context reads 0 of a window agy has sized.
AGY_BEFORE_TURN='{"cwd":"/work/agysess","session_id":"","conversation_id":"","model":{"id":"Gemini 4 Argon (Medium)","display_name":"Gemini 4 Argon (Medium)","effort":"medium"},"workspace":{"current_dir":"/work/agysess","project_dir":"/work/agysess"},"context_window":{"total_input_tokens":0,"total_output_tokens":0,"context_window_size":1048576,"used_percentage":0,"remaining_percentage":100,"current_usage":null},"agent_state":"idle","terminal_width":160}'
# While agy authenticates: no model, and a window of size 0.
AGY_STARTING='{"cwd":"/work/agysess","session_id":"","model":null,"workspace":{"current_dir":"/work/agysess"},"context_window":{"total_input_tokens":0,"context_window_size":0,"used_percentage":0},"agent_state":"authenticating","terminal_width":80}'
# The quota a Google AI Pro account reported on 2026-11-16 (agy 1.5.9),
# verbatim: a 5-hour and a weekly bucket for Gemini models, a weekly one
# named for Argon, and an unused pair for the third-party models. agy's own
# line drew none of it.
AGY_QUOTA='{"3p-5h":{"remaining_fraction":1,"reset_time":"2026-11-16T16:44:09Z","reset_in_seconds":17999},"3p-weekly":{"remaining_fraction":1,"reset_time":"2026-11-23T11:44:09Z","reset_in_seconds":604799},"gemini-5h":{"remaining_fraction":0.97945833,"reset_time":"2026-11-16T15:37:12Z","reset_in_seconds":13982},"gemini-argon-wtu-weekly":{"remaining_fraction":0.8842949,"reset_time":"2026-11-21T15:41:11Z","reset_in_seconds":446221},"gemini-weekly":{"remaining_fraction":0.9794862,"reset_time":"2026-11-22T22:20:09Z","reset_in_seconds":556559}}'

# The rate_limits the adapter hands over for payload $1 with model $2 (a
# display name, a whole model object, or null) and quota $3. The previous call's payload is removed
# first, so an adapter that dies before the renderer runs reads as that, not
# as the null the call before it left.
_quota_rate_limits() {
    local payload
    payload=$(jq -c --argjson model "$2" --argjson quota "$3" \
        '.model = (if $model == null or ($model | type) == "object" then $model
                   else {id: $model, display_name: $model} end)
         | .quota = $quota' <<< "$1")
    rm -f "$STUB_IN"
    printf '%s' "$payload" | "$STUB_DIR/cs-statusline-agy" > /dev/null
    if [ -f "$STUB_IN" ]; then
        jq -cS '.rate_limits // null' "$STUB_IN"
    else
        printf 'the renderer never ran'
    fi
}

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
        CS_INSTALL_DIR CS_CLAUDE_DIR CS_CONFIG_DIR CODEX_HOME AGY_BIN NO_COLOR STUB_ENV STUB_IN STUB_DIR 2>/dev/null || true
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

# The adapter hands cs-statusline the session, folder, context, quota and
# width, under Claude Code's names, and nothing of the model or cost, which
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
    assert_eq '{"columns":160,"context_window":{"used_percentage":1.4201164245605469},"cwd":"/work/agysess","rate_limits":{"five_hour":{"resets_at":1794688936,"used_percentage":60}},"session_id":"6778f9f7-33fb-4aa5-8194-f0142b7a86ea","workspace":{"current_dir":"/work/agysess"}}' \
        "$(jq -cS . "$STUB_IN")" "only the session, folder, context, quota and width go over" || return 1
}

# agy's quota is a fraction left per bucket; Claude Code's rate_limits are
# the percentage used per window, with the reset as an epoch. The 5-hour and
# weekly windows each take the most-used bucket of the running model's
# family: gemini-* for a Gemini model, 3p-* for any other. A bucket named for
# one model (gemini-argon-...) counts for its whole family, since agy
# documents none of the names. No model yet, no quota.
test_the_quota_maps_onto_rate_limits_for_the_running_model() {
    _stub_install
    assert_eq '{"five_hour":{"resets_at":1794843432,"used_percentage":2},"seven_day":{"resets_at":1795275671,"used_percentage":12}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Argon (High)"' "$AGY_QUOTA")" \
        "Argon counts Gemini's 5h and the most-used Gemini weekly bucket" || return 1
    assert_eq '{"five_hour":{"resets_at":1794843432,"used_percentage":2},"seven_day":{"resets_at":1795275671,"used_percentage":12}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Flash"' "$AGY_QUOTA")" \
        "every Gemini model counts the same buckets, Argon's included" || return 1
    assert_eq '{"five_hour":{"resets_at":1794847449,"used_percentage":0},"seven_day":{"resets_at":1795434249,"used_percentage":0}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Claude Sonnet 5.5 (Thinking)"' "$AGY_QUOTA")" \
        "a third-party model counts the 3p buckets" || return 1
    assert_eq 'null' "$(_quota_rate_limits "$AGY_AFTER_TURN" null "$AGY_QUOTA")" \
        "with no model yet, no quota goes over" || return 1
}

# A window the running model's family has no usable bucket for is left out;
# another family's bucket never stands in for it.
test_the_quota_never_borrows_another_familys_bucket() {
    _stub_install
    assert_eq '{"five_hour":{"resets_at":null,"used_percentage":10}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Flash"' '{"gemini-5h":{"remaining_fraction":0.9},"gemini-weekly":{"remaining_fraction":null},"3p-weekly":{"remaining_fraction":0.05}}')" \
        "a Gemini model whose weekly bucket has no fraction shows no wk" || return 1
    assert_eq 'null' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Claude Sonnet 5.5"' '{"gemini-5h":{"remaining_fraction":0.1},"gemini-weekly":{"remaining_fraction":0.1}}')" \
        "a third-party model with only Gemini buckets shows no quota" || return 1
}

# agy names the model twice, as display_name and id. An empty or missing
# display name falls through to the id, and a Gemini model given as a slug
# still spends the Gemini buckets.
test_the_quota_reads_the_model_from_either_name() {
    local quota='{"gemini-5h":{"remaining_fraction":0.9},"3p-5h":{"remaining_fraction":0.1}}'
    _stub_install
    assert_eq '{"five_hour":{"resets_at":null,"used_percentage":10}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '{"id":"Gemini 4 Flash"}' "$quota")" \
        "the id alone names the model" || return 1
    assert_eq '{"five_hour":{"resets_at":null,"used_percentage":10}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '{"display_name":"","id":"Gemini 4 Flash"}' "$quota")" \
        "an empty display name falls through to the id" || return 1
    assert_eq '{"five_hour":{"resets_at":null,"used_percentage":10}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '{"id":"models/gemini-4-flash"}' "$quota")" \
        "a Gemini slug is a Gemini model" || return 1
    assert_eq '{"five_hour":{"resets_at":null,"used_percentage":90}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '{"display_name":"","id":"claude-sonnet-5-5"}' "$quota")" \
        "any other id is a third-party model" || return 1
}

# A bucket agy sends in another shape is not guessed at: one with no
# fraction is skipped, a fraction past either end is held to it, even just
# past full, and a reset that is not a time, or is more than 31 days away,
# leaves the window without one. A reset agy gives only as seconds is counted
# from now. No usable bucket, or no quota at all, sends no rate_limits.
test_the_quota_tolerates_what_agy_may_send() {
    local before after got
    _stub_install
    assert_eq 'null' "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Argon"' null)" "no quota, no rate_limits" || return 1
    assert_eq 'null' "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Argon"' '"full"')" "a quota that is not an object" || return 1
    assert_eq 'null' "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Argon"' '{"gemini-5h":{"reset_time":"2026-11-16T15:37:12Z"},"gemini-daily":{"remaining_fraction":0.5}}')" \
        "a bucket with no fraction, or a window cs does not draw" || return 1
    assert_eq '{"five_hour":{"resets_at":1794843432,"used_percentage":100},"seven_day":{"resets_at":null,"used_percentage":0}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Argon"' '{"gemini-5h":{"remaining_fraction":-0.2,"reset_time":"2026-11-16T15:37:12.250Z"},"gemini-weekly":{"remaining_fraction":1.5,"reset_time":"soon"}}')" \
        "a fraction past either end is held to it; a fractional second still parses" || return 1
    assert_eq '{"five_hour":{"resets_at":null,"used_percentage":0}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Argon"' '{"gemini-5h":{"remaining_fraction":1.004}}')" \
        "a fraction just past full reads 0, not -0" || return 1
    assert_eq '{"five_hour":{"resets_at":null,"used_percentage":50},"seven_day":{"resets_at":null,"used_percentage":50}}' \
        "$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Argon"' '{"gemini-5h":{"remaining_fraction":0.5,"reset_in_seconds":2e19},"gemini-weekly":{"remaining_fraction":0.5,"reset_time":"2099-01-01T00:00:00Z"}}')" \
        "a reset decades away is no reset" || return 1
    before=$(date +%s)
    got=$(_quota_rate_limits "$AGY_AFTER_TURN" '"Gemini 4 Argon"' '{"gemini-5h":{"remaining_fraction":0.5,"reset_in_seconds":600}}')
    after=$(date +%s)
    assert_eq '50' "$(jq -r .five_hour.used_percentage <<< "$got")" "half left is half used" || return 1
    [ "$(jq -r .five_hour.resets_at <<< "$got")" -ge $((before + 600)) ] \
        && [ "$(jq -r .five_hour.resets_at <<< "$got")" -le $((after + 600)) ] \
        || { echo "  FAIL: a reset given in seconds counts from now: $got"; return 1; }
}

# Through the real renderer, the quota draws as Claude's does: 5h always, wk
# from 50, and the countdown once a window is tight.
test_the_real_render_shows_the_quota() {
    local out payload
    payload=$(jq -c --argjson quota "$AGY_QUOTA" '.model.display_name = "Gemini 4 Argon (High)" | .quota = $quota' <<< "$AGY_AFTER_TURN")
    out=$(printf '%s' "$payload" | NO_COLOR=1 CLAUDE_SESSION_NAME=agysess "$BASH" "$ADAPTER") || return 1
    assert_eq "agysess > ○ ctx 1% > ◷ 5h 2%" "$out" "the 5-hour window shows, the weekly waits for 50" || return 1
    payload=$(jq -c '.model.display_name = "Claude Sonnet 5.5" | .quota = {"3p-5h":{"remaining_fraction":0.1},"3p-weekly":{"remaining_fraction":0.4}}' <<< "$AGY_AFTER_TURN")
    out=$(printf '%s' "$payload" | NO_COLOR=1 CLAUDE_SESSION_NAME=agysess "$BASH" "$ADAPTER") || return 1
    assert_eq "agysess > ○ ctx 1% > ◷ 5h 90% ⋮ ◶ wk 60%" "$out" "both windows once the weekly passes 50" || return 1
    payload=$(jq -c '.model.display_name = "Gemini 4 Flash" | .quota = {"gemini-5h":{"remaining_fraction":0.2,"reset_in_seconds":3630},"gemini-weekly":{"remaining_fraction":0.1,"reset_in_seconds":174600}}' <<< "$AGY_AFTER_TURN")
    out=$(printf '%s' "$payload" | NO_COLOR=1 CLAUDE_SESSION_NAME=agysess "$BASH" "$ADAPTER") || return 1
    assert_eq "agysess > ○ ctx 1% > ◷ 5h 80% · 1h0m ⋮ ◶ wk 90% · 2d0h" "$out" "the time to reset once a window is tight" || return 1
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

# Through the real renderer, in a session cs launched: the session name, the
# context and the quota show, agy's model does not. The context-pct and
# limits stamps Claude's hooks read, and the width record the cs mod reads,
# stay unwritten though the quota went over; the same reading from Claude
# Code writes them, so it is the engine that keeps them out.
test_the_real_render_shows_the_session_and_stamps_nothing() {
    local dir="$CS_SESSIONS_ROOT/agysess/.cs/local" out
    mkdir -p "$dir"
    # The conversation the launch recorded, so a Claude Code render here is
    # the lead's and writes every stamp.
    printf 'claude_session_id: 6778f9f7-33fb-4aa5-8194-f0142b7a86ea\n' > "$dir/state"
    out=$(printf '%s' "$AGY_AFTER_TURN" | NO_COLOR=1 CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_PARENT=4242 \
        "$BASH" "$ADAPTER") || { echo "  FAIL: the render failed"; return 1; }
    assert_eq "agysess > ○ ctx 1% > ◷ 5h 60%" "$out" "the session, its context and the quota" || return 1
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
    export AGY_BIN="$TEST_TMPDIR/agy"
    printf '#!/bin/sh\nprintf "  --settings  Session settings\\n"\n' > "$AGY_BIN"
    chmod +x "$AGY_BIN"
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

test_antigravity_enable_reports_an_old_or_missing_agy() {
    local out
    export CS_INSTALL_DIR="$TEST_TMPDIR/install" CS_CONFIG_DIR="$TEST_TMPDIR/config" AGY_BIN="$TEST_TMPDIR/agy"
    mkdir -p "$CS_INSTALL_DIR" "$HOME/.gemini/antigravity-cli"
    cp "$ADAPTER" "$SL" "$CS_INSTALL_DIR/"
    printf '#!/bin/sh\nexit 0\n' > "$AGY_BIN"
    chmod +x "$AGY_BIN"
    out=$("$CS_BIN" -statusline enable antigravity 2>&1) || return 1
    assert_output_contains "$out" "does not list --settings" "an old agy is reported" || return 1
    assert_output_not_contains "$out" "show it under agy's own line" "an old agy is not promised a line" || return 1
    rm "$AGY_BIN"
    out=$("$CS_BIN" -statusline enable antigravity 2>&1) || return 1
    assert_output_contains "$out" "Antigravity CLI not found" "leftover config does not imply an installed agy" || return 1
    assert_output_not_contains "$out" "show it under agy's own line" "a missing agy is not promised a line"
}

# Exercise the renderer directly, with a positive control: the same payload
# from Claude stamps limits, so it is the engine gate alone that keeps
# Claude's limits stamp out of an Antigravity render.
test_antigravity_renderer_does_not_stamp_supplied_rate_limits() {
    local dir="$CS_SESSIONS_ROOT/agysess/.cs/local"
    local payload='{"session_id":"6778f9f7-33fb-4aa5-8194-f0142b7a86ea","rate_limits":{"five_hour":{"used_percentage":10}}}'
    mkdir -p "$dir"
    printf 'claude_session_id: 6778f9f7-33fb-4aa5-8194-f0142b7a86ea\n' > "$dir/state"
    printf '%s' "$payload" | NO_COLOR=1 CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_ENGINE=antigravity \
        "$BASH" "$SL" > /dev/null
    assert_not_exists "$dir/limits" "an Antigravity render never stamps supplied rate limits" || return 1
    printf '%s' "$payload" | NO_COLOR=1 CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_ENGINE=claude \
        "$BASH" "$SL" > /dev/null
    assert_exists "$dir/limits" "the same payload from Claude does stamp limits" || return 1
    assert_output_contains "$(cat "$dir/limits")" "five_hour_used_pct: 10" "the positive control consumes the supplied reading"
}

test_antigravity_omits_the_claude_mark_even_with_attention() {
    local dir="$CS_SESSIONS_ROOT/agysess/.cs/local" out
    mkdir -p "$dir"
    touch "$dir/attention"
    out=$(printf '%s' "$AGY_AFTER_TURN" | CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_SEGMENTS=logo,session \
        "$BASH" "$ADAPTER") || return 1
    assert_output_contains "$out" $'\033' "the render is coloured, so the plain-mode logo rule cannot hide a regression" || return 1
    assert_output_contains "$out" "agysess" "the session still draws" || return 1
    assert_output_not_contains "$out" "✳" "Antigravity never draws Claude's mark or attention shade" || return 1
    out=$(printf '%s' '{}' | CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_SEGMENTS=logo,session \
        "$BASH" "$SL") || return 1
    assert_output_contains "$out" "✳" "Claude retains its mark" || return 1
    assert_output_contains "$out" "agysess" "and its session"
}

# These renders contain only the ASCII session name and band padding, so
# bytes after SGR removal are terminal cells, independent of renderer code.
_ascii_band_cells() {
    printf '%s' "$1" | sed "s/$(printf '\033')\[[0-9;]*m//g" | LC_ALL=C wc -c | tr -d ' '
}

test_band_width_uses_the_engine_frame_and_explicit_overrides() {
    local out payload='{"session_id":"agysess","terminal_width":80}'
    export CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_SEGMENTS=session CS_STATUSLINE_LAYOUT=band \
        CS_TERM_THEME=dark CS_TERM_BG_RGB='21;24;40' COLORTERM=truecolor
    out=$(printf '%s' "$payload" | "$BASH" "$ADAPTER") || return 1
    assert_eq 80 "$(_ascii_band_cells "$out")" "agy draws across all 80 reported cells" || return 1
    out=$(printf '%s' '{"columns":80}' | "$BASH" "$SL") || return 1
    assert_eq 76 "$(_ascii_band_cells "$out")" "Claude still reserves its four frame cells" || return 1
    out=$(printf '%s' "$payload" | CS_STATUSLINE_FRAME=6 "$BASH" "$ADAPTER") || return 1
    assert_eq 74 "$(_ascii_band_cells "$out")" "an explicit frame overrides agy's default" || return 1
    out=$(printf '%s' "$payload" | CS_STATUSLINE_FRAME=6 CS_STATUSLINE_COLS=67 "$BASH" "$ADAPTER") || return 1
    assert_eq 67 "$(_ascii_band_cells "$out")" "an explicit final width takes precedence over the frame"
}

test_piped_antigravity_renders_do_not_accumulate_tty_cache_entries() {
    local out parent
    export CLAUDE_SESSION_NAME=agysess CS_STATUSLINE_SEGMENTS=session CS_TERM_THEME_AUTO=1
    for parent in 4242 4343; do
        out=$(printf '%s' '{}' | CS_STATUSLINE_ENGINE=antigravity CS_STATUSLINE_PARENT="$parent" \
            "$BASH" "$SL") || return 1
        assert_output_contains "$out" "agysess" "the piped render still draws for parent $parent" || return 1
    done
    out=$(printf '%s' "$AGY_AFTER_TURN" | "$BASH" "$ADAPTER") || return 1
    assert_output_contains "$out" "agysess" "the adapter also draws normally" || return 1
    assert_not_exists "$HOME/.cache/cs/tty" "piped input cannot name a tty, so no per-process cache is needed"
}

test_antigravity_switch_leaves_other_engines_untouched() {
    local out action
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude" CODEX_HOME="$TEST_TMPDIR/codex" CS_CONFIG_DIR="$TEST_TMPDIR/config"
    export AGY_BIN="$TEST_TMPDIR/no-agy"
    mkdir -p "$CS_CLAUDE_DIR" "$CODEX_HOME" "$CS_CONFIG_DIR"
    printf '{"statusLine":{"command":"my-claude-bridge"}}\n' > "$CS_CLAUDE_DIR/settings.json"
    printf '[tui]\nstatus_line = ["model-name"]\n' > "$CODEX_HOME/config.toml"
    touch "$CS_CONFIG_DIR/statusline-declined" "$CS_CONFIG_DIR/statusline-antigravity-off"
    cp "$CS_CLAUDE_DIR/settings.json" "$TEST_TMPDIR/claude.before"
    cp "$CODEX_HOME/config.toml" "$TEST_TMPDIR/codex.before"
    for action in enable disable; do
        out=$("$CS_BIN" -statusline "$action" antigravity 2>&1) \
            || { echo "  FAIL: scoped $action failed: $out"; return 1; }
        assert_eq "$(cat "$TEST_TMPDIR/claude.before")" "$(cat "$CS_CLAUDE_DIR/settings.json")" "Claude's bridge survives $action" || return 1
        assert_eq "$(cat "$TEST_TMPDIR/codex.before")" "$(cat "$CODEX_HOME/config.toml")" "Codex's line survives $action" || return 1
        assert_exists "$CS_CONFIG_DIR/statusline-declined" "Claude's installer decline survives $action" || return 1
        case "$action" in
            enable) assert_not_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "only Antigravity is enabled" || return 1 ;;
            disable) assert_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "only Antigravity is disabled" || return 1 ;;
        esac
    done
}

test_antigravity_switch_ignores_broken_claude_settings() {
    local out
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude" CS_CONFIG_DIR="$TEST_TMPDIR/config"
    export AGY_BIN="$TEST_TMPDIR/no-agy"
    mkdir -p "$CS_CLAUDE_DIR"
    printf 'broken JSON\n' > "$CS_CLAUDE_DIR/settings.json"
    out=$("$CS_BIN" -statusline disable antigravity 2>&1) \
        || { echo "  FAIL: broken Claude settings blocked disable: $out"; return 1; }
    assert_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "disable records the Antigravity choice" || return 1
    assert_not_exists "$CS_CONFIG_DIR/statusline-declined" "disable does not decline Claude's line" || return 1
    out=$("$CS_BIN" -statusline enable antigravity 2>&1) \
        || { echo "  FAIL: broken Claude settings blocked enable: $out"; return 1; }
    assert_not_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "enable clears the Antigravity choice" || return 1
    assert_eq "broken JSON" "$(cat "$CS_CLAUDE_DIR/settings.json")" "the broken file stays untouched"
}

test_statusline_rejects_an_unknown_engine_before_writing() {
    local out status=0
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude" CS_CONFIG_DIR="$TEST_TMPDIR/config"
    out=$("$CS_BIN" -statusline enable antigravty 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: an unknown engine was accepted: $out"; return 1; }
    assert_not_exists "$CS_CLAUDE_DIR/settings.json" "a mistyped engine never changes Claude's registration" || return 1
    assert_not_exists "$CS_CONFIG_DIR/statusline-antigravity-off" "nor Antigravity's choice"
}

run_test test_the_adapter_maps_agy_payload_onto_cs_statusline_input
run_test test_the_quota_maps_onto_rate_limits_for_the_running_model
run_test test_the_quota_never_borrows_another_familys_bucket
run_test test_the_quota_reads_the_model_from_either_name
run_test test_the_quota_tolerates_what_agy_may_send
run_test test_the_real_render_shows_the_quota
run_test test_the_context_waits_for_the_first_turn
run_test test_the_adapter_never_fails_agy
run_test test_the_real_render_shows_the_session_and_stamps_nothing
run_test test_statusline_command_reports_antigravity
run_test test_antigravity_enable_reports_an_old_or_missing_agy
run_test test_antigravity_renderer_does_not_stamp_supplied_rate_limits
run_test test_antigravity_omits_the_claude_mark_even_with_attention
run_test test_band_width_uses_the_engine_frame_and_explicit_overrides
run_test test_piped_antigravity_renders_do_not_accumulate_tty_cache_entries
run_test test_antigravity_switch_leaves_other_engines_untouched
run_test test_antigravity_switch_ignores_broken_claude_settings
run_test test_statusline_rejects_an_unknown_engine_before_writing
report_results
