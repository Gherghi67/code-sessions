#!/usr/bin/env bash
# ABOUTME: Exercises the Antigravity (agy) adapter through cs with a fake agy on PATH.
# ABOUTME: HOME, the sessions root and the keychain are temporary; no real ~/.gemini state is read.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CS_TRANSCRIPTS_DIR="$TEST_TMPDIR/claude-projects"
    export CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1
    export CS_NO_FUNCTION_HOOKS=1
    # Neither other engine may be needed for an Antigravity session.
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/no-claude"
    export CODEX_BIN="$TEST_TMPDIR/bin/no-codex"
    export AGY_LOG="$TEST_TMPDIR/agy.log" AGY_ARGV="$TEST_TMPDIR/agy-argv"
    export AGY_PWD="$TEST_TMPDIR/agy-pwd" AGY_ENV="$TEST_TMPDIR/agy-env" AGY_STATE="$TEST_TMPDIR/agy-state"
    export AGY_HOOK_OUT="$TEST_TMPDIR/agy-hook-out"
    export AGY_NEW_ID=11111111-1111-4111-8111-111111111111 AGY_LATEST_ID=22222222-2222-4222-8222-222222222222
    mkdir -p "$HOME" "$CS_SESSIONS_ROOT" "$CS_TRANSCRIPTS_DIR" "$TEST_TMPDIR/bin"
    use_fake_keychain
    # The fake records how cs started it, then runs the hooks a real turn
    # would from cs's plugin, the way agy 1.4.11 was measured to: a new
    # conversation's SessionStart, a PreInvocation per model call, a
    # PostToolUse write_file for each path in AGY_EDITS, and a PreInvocation
    # for each subagent id in AGY_SUBAGENTS. A run left before any turn
    # (AGY_NO_TURN) fires none. Hook stdout goes to AGY_HOOK_OUT.
    cat > "$TEST_TMPDIR/bin/agy" <<'AGY'
#!/usr/bin/env bash
# --help lists the flags cs passes, less any named in AGY_HELP_OMIT.
if [ "${1:-}" = --help ]; then
    for flag in --continue --conversation --model --effort --mode; do
        case " ${AGY_HELP_OMIT:-} " in *" $flag "*) continue ;; esac
        printf '  %-30s %s\n' "$flag" "what $flag does"
    done
    exit 0
fi
printf '%s\n' "$*" >> "$AGY_LOG"
printf '%s\n' "$@" > "$AGY_ARGV"
pwd -P > "$AGY_PWD"
env | grep -E '^(CS_|CLAUDE_)' | sort > "$AGY_ENV"
grep '^engine:' "$CS_SESSION_META_DIR/local/state" > "$AGY_STATE" 2>/dev/null || : > "$AGY_STATE"
conversation="" new=""
while [ $# -gt 0 ]; do
    case "$1" in
        --conversation) conversation="$2"; shift ;;
        --continue) conversation="$AGY_LATEST_ID" ;;
    esac
    shift
done
[ -n "$conversation" ] || { conversation="$AGY_NEW_ID"; new=1; }
# A link planted in the run's directory, as a process with the user's rights
# could: cs's marks must never write through it.
[ -z "${AGY_PLANT_LINK:-}" ] \
    || ln -s "$AGY_PLANT_LINK" "$HOME/.cache/cs/antigravity-runs/$CS_RUN_ID/seen-$conversation"
[ -z "${AGY_PLANT_LOG:-}" ] \
    || { rm -f "$CS_SESSION_META_DIR/local/session.log"; ln -s "$AGY_PLANT_LOG" "$CS_SESSION_META_DIR/local/session.log"; }
hooks="$HOME/.gemini/config/plugins/cs/hooks.json"
fire() {  # event, payload
    local cmd
    [ -f "$hooks" ] || return 0
    jq -r --arg e "$1" '.[] | (.[$e] // [])[] | (.hooks // [.])[] | .command' "$hooks" \
        | while IFS= read -r cmd; do
            printf '%s' "$2" | (cd "${hooks%/*}" && sh -c "$cmd") >> "$AGY_HOOK_OUT" 2>&1
        done
}
payload() {  # id, [extra JSON]
    local extra="${2:-}"
    [ -n "$extra" ] || extra='{}'
    jq -nc --arg id "$1" --arg ws "$(pwd -P)" --argjson extra "$extra" \
        '{conversationId: $id, workspacePaths: [$ws], modelName: "fake"} + $extra'
}
if [ -z "${AGY_NO_TURN:-}" ]; then
    [ -z "$new" ] || fire SessionStart "$(payload "$conversation")"
    fire PreInvocation "$(payload "$conversation" '{"invocationNum": 0}')"
    for edit in ${AGY_EDITS:-}; do
        printf 'edited\n' > "$edit"
        fire PostToolUse "$(payload "$conversation" "$(jq -nc --arg p "$edit" \
            '{stepIdx: 2, error: "", toolCall: {name: "write_file", args: {Path: $p, Content: "edited\n"}}}')")"
    done
    fire PreInvocation "$(payload "$conversation" '{"invocationNum": 1}')"
    for sub in ${AGY_SUBAGENTS:-}; do
        fire SessionStart "$(payload "$sub")"
        fire PreInvocation "$(payload "$sub" '{"invocationNum": 0}')"
    done
fi
exit "${AGY_EXIT:-0}"
AGY
    chmod +x "$TEST_TMPDIR/bin/agy"
    export AGY_SAVED_PATH="$PATH"
    # No test may reach a real agy: every PATH directory holding one is
    # dropped, so the fake is the only agy and a "missing" PATH has none.
    local entry clean=""
    local IFS=:
    for entry in $PATH; do
        [ -n "$entry" ] && [ ! -e "$entry/agy" ] || continue
        clean="${clean:+$clean:}$entry"
    done
    unset IFS
    export AGY_CLEAN_PATH="$clean"
    export PATH="$TEST_TMPDIR/bin:$clean"
    unset XDG_CONFIG_HOME AGY_BIN AGY_EXIT AGY_HELP_OMIT AGY_NO_TURN AGY_EDITS AGY_SUBAGENTS AGY_PLANT_LINK AGY_PLANT_LOG
    _install_agy_hook
    unset CS_DEFAULT_ENGINE CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CS_LEAD_PID CLAUDE_PID
    unset CS_RUN_ENGINE CS_RUN_ID CS_SESSION_DIR CS_SESSION_NAME CS_SESSION_META_DIR
}

teardown() {
    export PATH="${AGY_SAVED_PATH:-$PATH}"
    rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CS_TRANSCRIPTS_DIR CS_NO_UPDATE_CHECK CS_NO_ITERM2
    unset CS_NO_FUNCTION_HOOKS CLAUDE_CODE_BIN CODEX_BIN AGY_SAVED_PATH AGY_CLEAN_PATH
    unset AGY_LOG AGY_ARGV AGY_PWD AGY_ENV AGY_STATE AGY_BIN AGY_EXIT AGY_HELP_OMIT CS_DEFAULT_ENGINE
    unset AGY_HOOK_OUT AGY_NEW_ID AGY_LATEST_ID AGY_NO_TURN AGY_EDITS AGY_SUBAGENTS AGY_PLANT_LINK AGY_PLANT_LOG
}

# cs's plugin as the installer writes it, in the test's HOME.
_install_agy_hook() {
    local script plugin="$HOME/.gemini/config/plugins/cs"
    ( source "$SCRIPT_DIR/../lib/01-manifests.sh" && _antigravity_plugin_register "$CS_BIN" ) || return 1
    mkdir -p "$plugin/scripts"
    for script in autosave-commits.sh cs-resolve.sh cs-shared.sh cs-engine-events.sh; do
        cp "$SCRIPT_DIR/../hooks/$script" "$plugin/scripts/$script" || return 1
    done
}

_binding() {
    cat "$(_session_dir "$1")/.cs/local/antigravity-conversation" 2>/dev/null
}

_session_dir() {
    printf '%s/%s\n' "$CS_SESSIONS_ROOT" "$1"
}

_rule() {
    printf '%s/.agents/rules/cs-session.md\n' "$(_session_dir "$1")"
}

# The argv agy got, one line, so an empty launch reads as "".
_agy_argv() {
    tr '\n' ' ' < "$AGY_ARGV" | sed 's/ $//'
}

test_missing_agy_names_the_install_line_before_creating_anything() {
    local output status=0
    output=$(PATH="$AGY_CLEAN_PATH" "$CS_BIN" no-agy --engine antigravity 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a launch without agy must fail: $output"; return 1; }
    assert_output_contains "$output" 'Missing required dependencies: agy' "names the binary" || return 1
    assert_output_contains "$output" 'curl -fsSL https://antigravity.google/cli/install.sh | bash' \
        "names the install line" || return 1
    assert_not_exists "$(_session_dir no-agy)" "a missing agy must not create the session"
}

test_fresh_launch_starts_agy_in_the_session_with_its_context_rule() {
    local output dir rule
    output=$(CLAUDE_CODE_SESSION_ID=leaked "$CS_BIN" fresh --engine antigravity 2>&1) \
        || { echo "  FAIL: launch failed: $output"; return 1; }
    dir=$(_session_dir fresh)
    rule=$(_rule fresh)
    assert_eq "" "$(_agy_argv)" "a new session starts a new conversation" || return 1
    assert_eq "$(cd "$dir" && pwd -P)" "$(cat "$AGY_PWD")" "agy runs in the session folder" || return 1
    assert_file_contains "$rule" '^trigger: always_on$' "the rule is always in context" || return 1
    assert_file_contains "$rule" 'cs:antigravity-session-context' "the rule carries cs's mark" || return 1
    assert_file_contains "$rule" '^Session: fresh$' "the rule names the session" || return 1
    assert_file_contains "$rule" '# Session memory index' "the rule carries the memory index" || return 1
    assert_eq "$AGY_NEW_ID" "$(_binding fresh)" "the hook binds the conversation by its id" || return 1
    assert_eq "" "$(grep -v -x -F '{}' "$AGY_HOOK_OUT")" "every hook answers {} and nothing else" || return 1
    assert_file_contains "$dir/.cs/local/state" '^engine: antigravity$' "the engine is remembered" || return 1
    assert_file_contains "$AGY_ENV" '^CS_RUN_ENGINE=antigravity$' "the run names its engine" || return 1
    assert_file_contains "$AGY_ENV" '^CS_SESSION_NAME=fresh$' "agy receives the session identity" || return 1
    assert_file_not_contains "$AGY_ENV" '^CLAUDE_CODE_SESSION_ID=' "Claude's conversation id does not leak" || return 1
    assert_not_exists "$dir/CLAUDE.local.md" "Antigravity does not prepare Claude" || return 1
    assert_not_exists "$dir/.claude" "Antigravity does not configure Claude" || return 1
    assert_output_contains "$output" 'Antigravity via cs' "the launch says what it supports"
}

test_reopen_resumes_by_id_and_fresh_and_resume_choose_explicitly() {
    local output
    output=$("$CS_BIN" reopen --engine antigravity 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" reopen 2>&1) || { echo "$output"; return 1; }
    assert_eq "--conversation $AGY_NEW_ID" "$(_agy_argv)" "an unattended reopen resumes the bound conversation" || return 1
    output=$(AGY_NO_TURN=1 "$CS_BIN" reopen --fresh 2>&1) || { echo "$output"; return 1; }
    assert_eq "" "$(_agy_argv)" "--fresh starts a new conversation" || return 1
    output=$("$CS_BIN" reopen --resume 2>&1) || { echo "$output"; return 1; }
    assert_eq "--conversation $AGY_NEW_ID" "$(_agy_argv)" "--resume resumes without asking"
}

test_the_reopen_question_takes_n_as_fresh_and_enter_as_continue() {
    local output
    output=$("$CS_BIN" asked --engine antigravity 2>&1) || { echo "$output"; return 1; }
    output=$(printf 'n' | AGY_NO_TURN=1 CS_ASSUME_TTY=1 "$CS_BIN" asked 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" 'Continue previous Antigravity conversation' "asks on a terminal" || return 1
    assert_eq "" "$(_agy_argv)" "n starts fresh" || return 1
    output=$(printf 'y' | CS_ASSUME_TTY=1 "$CS_BIN" asked 2>&1) || { echo "$output"; return 1; }
    assert_eq "--conversation $AGY_NEW_ID" "$(_agy_argv)" "y continues" || return 1
    output=$(printf 'n' | AGY_NO_TURN=1 CS_ASSUME_TTY=1 "$CS_BIN" asked 2>&1) || { echo "$output"; return 1; }
    output=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_BIN" asked 2>&1) || { echo "$output"; return 1; }
    assert_eq "--conversation $AGY_NEW_ID" "$(_agy_argv)" "Enter continues"
}

# A first run that never reached the model (left with /exit before a turn, a
# sign-in never finished, a crash at start) has no conversation to resume,
# and --continue would fall back to a parent or child folder's (review R2).
# Nothing is bound, so the next open starts a new conversation.
test_a_first_run_left_before_any_turn_binds_nothing() {
    local output status=0 binding
    output=$(AGY_NO_TURN=1 "$CS_BIN" stumble --engine antigravity 2>&1) \
        || { echo "  FAIL: a clean exit must succeed: $output"; return 1; }
    binding="$(_session_dir stumble)/.cs/local/antigravity-conversation"
    assert_not_exists "$binding" "a run left before any turn binds nothing" || return 1
    output=$(AGY_NO_TURN=1 AGY_EXIT=1 "$CS_BIN" stumble 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: agy's failure must reach the caller: $output"; return 1; }
    assert_not_exists "$binding" "a failed first run binds nothing" || return 1
    output=$("$CS_BIN" stumble 2>&1) || { echo "  FAIL: the next open must launch: $output"; return 1; }
    assert_eq "" "$(_agy_argv)" "the next open starts a new conversation, never --continue" || return 1
    assert_eq "$AGY_NEW_ID" "$(_binding stumble)" "a run that reaches the model binds its conversation" || return 1
    status=0
    output=$(AGY_NO_TURN=1 AGY_EXIT=1 "$CS_BIN" stumble 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: agy's failure must reach the caller: $output"; return 1; }
    assert_eq "--conversation $AGY_NEW_ID" "$(_agy_argv)" "the failed run resumed by id" || return 1
    assert_eq "$AGY_NEW_ID" "$(_binding stumble)" "a later failed run keeps the binding an earlier run made"
}

test_resume_without_a_binding_refuses() {
    local output status=0 dir
    output=$("$CS_BIN" unbound --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir unbound)
    rm -f "$dir/.cs/local/antigravity-conversation"
    : > "$AGY_LOG"
    output=$("$CS_BIN" unbound --resume 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: --resume without a binding must fail"; return 1; }
    assert_output_contains "$output" 'no recorded antigravity conversation' "says why" || return 1
    assert_eq "" "$(cat "$AGY_LOG")" "agy is not started"
}

test_an_invalid_binding_refuses_before_agy_starts() {
    local output status=0 dir
    output=$("$CS_BIN" damaged --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir damaged)
    local bad
    # The binding lies where the agent can write, and goes onto agy's command
    # line: only a UUID (or the legacy word) passes.
    for bad in not-the-word --dangerously-skip-permissions "$AGY_NEW_ID-x" "../$AGY_NEW_ID"; do
        printf '%s\n' "$bad" > "$dir/.cs/local/antigravity-conversation"
        : > "$AGY_LOG"
        status=0
        output=$("$CS_BIN" damaged 2>&1) || status=$?
        [ "$status" -ne 0 ] || { echo "  FAIL: the binding '$bad' must fail"; return 1; }
        assert_output_contains "$output" 'Invalid Antigravity binding' "names the damage" || return 1
        assert_eq "" "$(cat "$AGY_LOG")" "agy is not started for '$bad'" || return 1
    done
}

test_launch_options_map_to_agy_flags() {
    local output
    output=$("$CS_BIN" options --engine antigravity --model gemini-3-pro --effort high --approve-for-me 2>&1) \
        || { echo "$output"; return 1; }
    assert_eq '--model gemini-3-pro --effort high --mode auto' "$(_agy_argv)" \
        "model, effort and automatic approval reach agy" || return 1
    output=$("$CS_BIN" options --native-approval --model gemini-3-flash 2>&1) || { echo "$output"; return 1; }
    assert_eq "--conversation $AGY_NEW_ID --model gemini-3-flash" "$(_agy_argv)" "native approval adds no mode"
}

# An agy whose --help lacks a flag cs would pass is refused before the rule,
# the binding or the engine is written, and the refusal names the flag.
test_an_agy_without_a_flag_cs_passes_is_refused_before_anything_is_written() {
    local output status=0 dir
    : > "$AGY_LOG"
    output=$(AGY_HELP_OMIT=--effort "$CS_BIN" older --engine antigravity --effort high 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a flag agy lacks must stop the launch: $output"; return 1; }
    assert_output_contains "$output" 'does not list --effort' "names the flag" || return 1
    assert_eq "" "$(cat "$AGY_LOG")" "agy is not started" || return 1
    dir=$(_session_dir older)
    assert_not_exists "$(_rule older)" "no rule is written" || return 1
    assert_not_exists "$dir/.cs/local/antigravity-conversation" "no binding is written" || return 1
    printf 'engine: claude\n' > "$dir/.cs/local/state"
    status=0
    output=$(AGY_HELP_OMIT=--mode "$CS_BIN" older --engine antigravity --approve-for-me 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a flag agy lacks must stop the launch: $output"; return 1; }
    assert_output_contains "$output" 'does not list --mode' "names the flag" || return 1
    assert_eq 'engine: claude' "$(cat "$dir/.cs/local/state")" "the engine stays the one it last ran under" || return 1
    output=$(AGY_HELP_OMIT=--effort "$CS_BIN" older --engine antigravity 2>&1) \
        || { echo "  FAIL: a flag cs does not pass is no reason to refuse: $output"; return 1; }
}

test_the_rule_stays_out_of_git_status() {
    local output dir
    output=$("$CS_BIN" quiet --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir quiet)
    [ -d "$dir/.git" ] || { echo "  FAIL: the session should be a git checkout"; return 1; }
    assert_eq "" "$(git -C "$dir" status --porcelain --untracked-files=all -- .agents)" \
        "the rule is not listed as untracked" || return 1
    assert_file_contains "$dir/.git/info/exclude" '^/\.agents/rules/cs-session\.md$' "the exclude is anchored" || return 1
    output=$("$CS_BIN" quiet 2>&1) || { echo "$output"; return 1; }
    assert_eq 1 "$(grep -c 'cs-session.md' "$dir/.git/info/exclude")" "a reopen adds no second entry"
}

# An exclude file swapped for a link out of the session gets no entry, and a
# dangling one creates nothing where it leads; the launch goes on and says so.
test_the_exclude_entry_is_never_appended_through_a_link() {
    local output dir outside="$TEST_TMPDIR/outside-config" missing="$TEST_TMPDIR/not-there"
    output=$("$CS_BIN" fenced --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir fenced)
    printf 'Host example\n' > "$outside"
    rm -f "$dir/.git/info/exclude"
    ln -s "$outside" "$dir/.git/info/exclude"
    output=$("$CS_BIN" fenced 2>&1) || { echo "  FAIL: the launch goes on without the entry: $output"; return 1; }
    assert_eq 'Host example' "$(cat "$outside")" "nothing is appended through the link" || return 1
    assert_output_contains "$output" ".agents/rules/cs-session.md to the checkout's info/exclude" "the launch says the entry is missing" || return 1
    rm -f "$dir/.git/info/exclude"
    ln -s "$missing" "$dir/.git/info/exclude"
    output=$("$CS_BIN" fenced 2>&1) || { echo "  FAIL: the launch goes on without the entry: $output"; return 1; }
    assert_not_exists "$missing" "a dangling link creates nothing where it leads"
}

# A session folder below a checkout's root (one with no .git of its own,
# inside a repo) gets its entry in that repo's exclude, anchored at the
# session folder, with the glob characters of its path escaped.
test_the_exclude_entry_is_anchored_below_the_checkout_root() {
    local output repo="$TEST_TMPDIR/repo" dir
    export CS_SESSIONS_ROOT="$repo/[x] sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
    git init -q "$repo"
    output=$("$CS_BIN" deep --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir deep)
    rm -rf "$dir/.git"
    output=$("$CS_BIN" deep 2>&1) || { echo "$output"; return 1; }
    [ ! -e "$dir/.git" ] || { echo "  FAIL: the session must stay below the checkout root"; return 1; }
    assert_file_contains "$repo/.git/info/exclude" \
        '^/\\\[x\\\] sessions/deep/\.agents/rules/cs-session\.md$' "anchored, glob characters escaped" || return 1
    assert_eq "" "$(git -C "$repo" status --porcelain --untracked-files=all -- "$dir/.agents")" \
        "the rule is not listed as untracked"
}

test_a_rule_cs_did_not_write_is_never_replaced() {
    local output status=0 rule exclude
    output=$("$CS_BIN" owned --engine antigravity 2>&1) || { echo "$output"; return 1; }
    rule=$(_rule owned)
    exclude="$(_session_dir owned)/.git/info/exclude"
    grep -vxF '/.agents/rules/cs-session.md' "$exclude" > "$exclude.new" || true
    mv "$exclude.new" "$exclude"
    printf 'the user wrote this\n' > "$rule"
    : > "$AGY_LOG"
    output=$("$CS_BIN" owned 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a user's rule must stop the launch"; return 1; }
    assert_output_contains "$output" 'was not written by cs' "names the conflict" || return 1
    assert_eq 'the user wrote this' "$(cat "$rule")" "the user's file is unchanged" || return 1
    assert_eq "" "$(cat "$AGY_LOG")" "agy is not started" || return 1
    assert_file_not_contains "$exclude" 'cs-session.md' \
        "a refused launch adds no exclude entry that would ignore the user's rule"
}

test_a_linked_rules_folder_is_never_written_through() {
    local output status=0 dir outside="$TEST_TMPDIR/outside"
    output=$("$CS_BIN" linked --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir linked)
    rm -rf "$dir/.agents"
    mkdir -p "$outside"
    ln -s "$outside" "$dir/.agents"
    output=$("$CS_BIN" linked 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a linked .agents must stop the launch"; return 1; }
    assert_output_contains "$output" 'is a link' "names the link" || return 1
    assert_eq "" "$(ls -A "$outside")" "nothing is written through the link"
}

# A rules folder swapped for a link after the launch checked it, while the
# rule's text is being built, still gets nothing written through it. The
# memory index is read with python3 between the checks and the write, so a
# python3 ahead on PATH holds the launch there while the test swaps.
test_a_rules_folder_swapped_for_a_link_mid_write_gets_nothing() {
    local output dir outside="$TEST_TMPDIR/outside-rules" status=0 pid tries=0 real_python
    output=$("$CS_BIN" racing --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir racing)
    printf -- '- [Entry](entry.md) - a pointer\n' > "$dir/.cs/memory/MEMORY.md"
    mkdir -p "$outside"
    real_python=$(command -v python3) || { echo "  FAIL: python3 is required"; return 1; }
    cat > "$TEST_TMPDIR/bin/python3" <<PY
#!/usr/bin/env bash
case "\$*" in
    *MEMORY.md*)
        : > "$TEST_TMPDIR/building"
        while [ ! -e "$TEST_TMPDIR/swapped" ]; do sleep 0.05; done ;;
esac
exec "$real_python" "\$@"
PY
    chmod +x "$TEST_TMPDIR/bin/python3"
    "$CS_BIN" racing > "$TEST_TMPDIR/racing.out" 2>&1 &
    pid=$!
    while [ ! -e "$TEST_TMPDIR/building" ] && [ "$tries" -lt 400 ]; do
        sleep 0.05
        tries=$((tries + 1))
    done
    rm -rf "$dir/.agents/rules"
    ln -s "$outside" "$dir/.agents/rules"
    : > "$TEST_TMPDIR/swapped"
    wait "$pid" || status=$?
    rm -f "$TEST_TMPDIR/bin/python3"
    assert_file_exists "$TEST_TMPDIR/building" "the launch reached the rule's text" || return 1
    assert_eq "" "$(ls -A "$outside")" "nothing lands through the link" || return 1
    [ "$status" -ne 0 ] || { echo "  FAIL: the launch must refuse: $(cat "$TEST_TMPDIR/racing.out")"; return 1; }
}

test_capabilities_claim_exact_resume_and_recovery_only() {
    local output dir capability status
    output=$("$CS_BIN" caps --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir caps)
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=antigravity "$CS_BIN" -engine 2>&1) \
        || { echo "  FAIL: cs -engine failed: $output"; return 1; }
    assert_output_contains "$output" 'engine: antigravity' || return 1
    assert_output_contains "$output" "conversation: $AGY_NEW_ID" || return 1
    assert_output_contains "$output" 'capabilities: launch exact_resume startup_context recovery_autosave memory_index' || return 1
    for capability in launch exact_resume startup_context recovery_autosave memory_index; do
        CS_SESSION_DIR="$dir" CS_RUN_ENGINE=antigravity "$CS_BIN" -engine supports "$capability" \
            || { echo "  FAIL: $capability should be supported"; return 1; }
    done
    for capability in rotation spawn_brief mail_delivery feature_finish; do
        status=0
        output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=antigravity "$CS_BIN" -engine supports "$capability" 2>&1) \
            || status=$?
        assert_eq 1 "$status" "$capability must not be claimed" || return 1
        assert_output_contains "$output" "$capability is not supported under antigravity" || return 1
    done
}

test_unknown_engine_errors_list_all_three() {
    local output
    output=$("$CS_BIN" whichever --engine wat 2>&1) || true
    assert_output_contains "$output" 'Choose claude, codex or antigravity' || return 1
    assert_not_exists "$(_session_dir whichever)"
}

test_spawn_refuses_a_brief_or_task_it_cannot_deliver() {
    local output status=0 brief="$TEST_TMPDIR/brief.md"
    output=$("$CS_BIN" -spawn worker --engine antigravity --task 'do it' 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a task under antigravity must be refused"; return 1; }
    assert_output_contains "$output" 'takes no brief or task' "says why" || return 1
    printf '# brief\n' > "$brief"
    status=0
    output=$("$CS_BIN" -spawn worker --engine antigravity --brief "$brief" 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a brief under antigravity must be refused"; return 1; }
    assert_not_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "no seed is staged"
}

# A seed cs -spawn staged under another engine (its window died before it
# launched) stays for the next Claude or Codex open, and the open says so.
test_a_staged_spawn_seed_is_named_and_left_for_another_engine() {
    local output seed="$CS_SESSIONS_ROOT/.spawn/seeded.seed"
    output=$("$CS_BIN" seeded --engine antigravity 2>&1) || { echo "$output"; return 1; }
    mkdir -p "${seed%/*}"
    printf 'token\ntask: do it\n' > "$seed"
    output=$("$CS_BIN" seeded 2>&1) || { echo "  FAIL: the open must go on: $output"; return 1; }
    assert_output_contains "$output" 'A spawn seed is staged for seeded' "the open names the seed" || return 1
    assert_file_exists "$seed" "the seed stays staged"
}

test_finish_and_handoff_launches_are_refused() {
    local output status=0
    output=$("$CS_BIN" lander --engine antigravity 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" lander -finish feat 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: -finish under antigravity must fail"; return 1; }
    assert_output_contains "$output" '-finish is not supported under antigravity' || return 1
    status=0
    : > "$AGY_LOG"
    output=$("$CS_BIN" lander --from-handoff 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: --from-handoff under antigravity must fail"; return 1; }
    assert_output_contains "$output" 'cannot start from a rotation handoff' || return 1
    assert_eq "" "$(cat "$AGY_LOG")" "agy is not started"
}

test_switch_is_refused_from_an_antigravity_run() {
    local output status=0 dir
    output=$("$CS_BIN" leaver --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir leaver)
    printf '{"run_id":"run-1"}\n' > "$dir/.cs/local/run-lease.json"
    output=$(CS_SESSION_DIR="$dir" CS_SESSION_NAME=leaver CS_RUN_ID=run-1 CS_RUN_ENGINE=antigravity \
        "$CS_BIN" -switch claude 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a switch from antigravity must fail"; return 1; }
    assert_output_contains "$output" 'cs -switch is not supported under antigravity' || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" "no switch is armed"
}

test_an_encrypted_session_is_refused_before_its_vault_opens() {
    local output status=0 dir
    output=$("$CS_BIN" sealed --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir sealed)
    mkdir -p "$dir/.cs/private"
    : > "$AGY_LOG"
    output=$("$CS_BIN" sealed 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: an encrypted session must be refused"; return 1; }
    assert_output_contains "$output" 'Antigravity keeps its conversations' || return 1
    assert_eq "" "$(cat "$AGY_LOG")" "agy is not started"
}

test_a_feature_worktree_launches_and_keeps_its_rule_out_of_git() {
    local output feature
    output=$("$CS_BIN" tree --engine antigravity 2>&1) || { echo "$output"; return 1; }
    git -C "$(_session_dir tree)" -c user.name=t -c user.email=t@example.com commit -qm base --allow-empty \
        >/dev/null 2>&1 || true
    output=$("$CS_BIN" tree@feat --engine antigravity 2>&1) || { echo "$output"; return 1; }
    feature=$(_session_dir tree@feat)
    assert_eq "$(cd "$feature" && pwd -P)" "$(cat "$AGY_PWD")" "agy runs in the feature" || return 1
    assert_file_exists "$(_rule tree@feat)" || return 1
    assert_eq "" "$(git -C "$feature" status --porcelain --untracked-files=all -- .agents)" \
        "the feature's rule is not untracked"
}

# A session that last ran under Claude records antigravity before agy starts,
# so a cs command run inside agy sees the engine it runs under.
test_the_engine_is_recorded_before_agy_starts() {
    local output dir
    output=$("$CS_BIN" switching --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir switching)
    printf 'engine: claude\n' > "$dir/.cs/local/state"
    output=$("$CS_BIN" switching --engine antigravity 2>&1) || { echo "$output"; return 1; }
    assert_eq 'engine: antigravity' "$(cat "$AGY_STATE")" "agy sees its own engine recorded"
}

# Both paths are resolved before the launch changes into the session folder:
# a relative AGY_BIN, or cs started by a relative path, names the same file.
test_relative_agy_and_cs_paths_resolve_before_the_launch_changes_folder() {
    local output dir cs_dir
    cs_dir=$(cd "$(dirname "$CS_BIN")" && pwd -P)
    output=$(cd "$TEST_TMPDIR" && AGY_BIN=bin/agy PATH="$AGY_CLEAN_PATH" "$CS_BIN" relative --engine antigravity 2>&1) \
        || { echo "  FAIL: a relative AGY_BIN must launch: $output"; return 1; }
    dir=$(_session_dir relative)
    assert_eq "$(cd "$dir" && pwd -P)" "$(cat "$AGY_PWD")" "the relative agy ran in the session" || return 1
    output=$(cd "$cs_dir" && env -u CS_BIN "./$(basename "$CS_BIN")" relative --fresh 2>&1) \
        || { echo "  FAIL: cs by a relative path must launch: $output"; return 1; }
    assert_file_contains "$AGY_ENV" "^CS_BIN=$cs_dir/$(basename "$CS_BIN")$" "CS_BIN is the running cs, absolute" || return 1
    assert_file_contains "$(_rule relative)" "^Agent-sessions executable: $cs_dir/$(basename "$CS_BIN")$" \
        "the rule names the running cs"
}

# --from-handoff is refused before the open unarchives or migrates anything.
test_from_handoff_is_refused_before_the_open_changes_the_session() {
    local output status=0 dir
    output=$("$CS_BIN" shelved --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir shelved)
    : > "$dir/.cs/archived"
    output=$("$CS_BIN" shelved --from-handoff 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: --from-handoff must be refused"; return 1; }
    assert_output_contains "$output" '--from-handoff is not supported under antigravity' || return 1
    assert_file_exists "$dir/.cs/archived" "the refused open leaves the session archived"
}

test_doctor_names_antigravity_and_its_binding() {
    local output dir
    output=$("$CS_BIN" checked --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir checked)
    output=$(CS_SESSION_DIR="$dir" CS_SESSION_META_DIR="$dir/.cs" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" 'Antigravity dependencies available' || return 1
    assert_output_contains "$output" 'Antigravity integration capabilities: launch, exact_resume, startup_context, recovery_autosave, memory_index' || return 1
    assert_output_contains "$output" "Antigravity binding: $AGY_NEW_ID" || return 1
    assert_output_contains "$output" "Antigravity hook installed: $HOME/.gemini/config/plugins/cs" || return 1
    if [[ "$output" == *Codex* ]]; then
        echo "  FAIL: an Antigravity doctor run must not name Codex: $output"; return 1
    fi
}

# A binding an older cs wrote names no conversation: the open continues the
# folder's latest once, the hook records that conversation's id, and every
# later open resumes it by id.
test_a_legacy_latest_binding_continues_once_then_resumes_by_id() {
    local output
    output=$(AGY_NO_TURN=1 "$CS_BIN" legacy --engine antigravity 2>&1) || { echo "$output"; return 1; }
    printf 'latest\n' > "$(_session_dir legacy)/.cs/local/antigravity-conversation"
    output=$("$CS_BIN" legacy 2>&1) || { echo "$output"; return 1; }
    assert_eq --continue "$(_agy_argv)" "the legacy binding continues the latest conversation" || return 1
    assert_eq "$AGY_LATEST_ID" "$(_binding legacy)" "the hook records the continued conversation's id" || return 1
    assert_file_contains "$(_session_dir legacy)/.cs/timeline.jsonl" \
        "\"engine\":\"antigravity\",\"session_id\":\"$AGY_LATEST_ID\",\"source\":\"resume\"" "recorded as resumed" || return 1
    output=$("$CS_BIN" legacy 2>&1) || { echo "$output"; return 1; }
    assert_eq "--conversation $AGY_LATEST_ID" "$(_agy_argv)" "the next open resumes it by id"
}

# A fresh start keeps the old binding until the new conversation reaches the
# model, then rebinds and records the rotation.
test_a_fresh_start_rebinds_once_it_reaches_the_model() {
    local output dir second=44444444-4444-4444-8444-444444444444
    output=$("$CS_BIN" renew --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir renew)
    output=$(AGY_NO_TURN=1 AGY_NEW_ID=$second "$CS_BIN" renew --fresh 2>&1) || { echo "$output"; return 1; }
    assert_eq "$AGY_NEW_ID" "$(_binding renew)" "a fresh run left before any turn keeps the binding" || return 1
    output=$(AGY_NEW_ID=$second "$CS_BIN" renew --fresh 2>&1) || { echo "$output"; return 1; }
    assert_eq "$second" "$(_binding renew)" "a fresh run that reaches the model rebinds" || return 1
    assert_file_contains "$dir/.cs/timeline.jsonl" \
        "\"from\":\"$AGY_NEW_ID\",\"to\":\"$second\",\"reason\":\"fresh\"" "the rotation is recorded" || return 1
    assert_file_contains "$dir/.cs/local/session.log" "Rebound antigravity conversation: $AGY_NEW_ID -> $second" || return 1
    output=$("$CS_BIN" renew 2>&1) || { echo "$output"; return 1; }
    assert_eq "--conversation $second" "$(_agy_argv)" "the next open resumes the new conversation"
}

# The run's first conversation to reach the model is the session's. One the
# run meets later, a subagent's, has its own id and never takes the binding.
test_a_later_conversation_in_the_run_never_takes_the_binding() {
    local output dir sub=55555555-5555-4555-8555-555555555555
    output=$(AGY_SUBAGENTS=$sub "$CS_BIN" nested --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir nested)
    assert_eq "$AGY_NEW_ID" "$(_binding nested)" "a subagent's conversation leaves the binding" || return 1
    assert_file_not_contains "$dir/.cs/timeline.jsonl" "$sub" "nor reaches the timeline" || return 1
    assert_eq 1 "$(grep -c "\"session_id\":\"$AGY_NEW_ID\"" "$dir/.cs/timeline.jsonl")" \
        "a run records its conversation once, however many model calls it makes" || return 1
    output=$(AGY_SUBAGENTS=$sub "$CS_BIN" nested 2>&1) || { echo "$output"; return 1; }
    assert_eq "$AGY_NEW_ID" "$(_binding nested)" "nor in a resumed run" || return 1
    assert_eq "" "$(ls -A "$HOME/.cache/cs/antigravity-runs" 2>/dev/null)" "each run's directory goes with it"
}

# The hook acts only in the run cs launched, for a conversation id that is a
# UUID; everything else answers {} and changes nothing.
test_the_hook_acts_only_in_the_run_cs_launched() {
    local output dir payload status
    output=$(AGY_NO_TURN=1 "$CS_BIN" guarded --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir guarded)
    payload=$(jq -nc --arg id "$AGY_NEW_ID" '{conversationId: $id}')
    output=$(printf '%s' "$payload" | "$CS_BIN" -antigravity-hook pre-invocation) || return 1
    assert_eq '{}' "$output" "a plain agy run gets {}" || return 1
    output=$(printf '%s' "$payload" | CS_RUN_ENGINE=antigravity CS_SESSION_DIR="$dir" \
        CS_RUN_ID=66666666-6666-4666-8666-666666666666 "$CS_BIN" -antigravity-hook pre-invocation) || return 1
    assert_eq '{}' "$output" "a run that does not hold the session's lease gets {}" || return 1
    assert_not_exists "$dir/.cs/local/antigravity-conversation" "and binds nothing" || return 1
    for payload in 'not json' '{"conversationId": "../../x"}' '{"conversationId": 7}' '[]'; do
        output=$(printf '%s' "$payload" | CS_RUN_ENGINE=antigravity CS_SESSION_DIR="$dir" \
            "$CS_BIN" -antigravity-hook pre-invocation) || return 1
        assert_eq '{}' "$output" "a malformed payload gets {}: $payload" || return 1
    done
    status=0
    output=$(printf '{}' | "$CS_BIN" -antigravity-hook from-a-newer-cs) || status=$?
    assert_eq 0 "$status" "an unknown verb from another cs's plugin never fails a turn" || return 1
    assert_eq '{}' "$output" || return 1
    assert_not_exists "$dir/.cs/local/antigravity-conversation" "nothing was bound" || return 1
    # Inside the run that holds the lease, an id that is not a UUID is not
    # bound either, and every hook still answers {}.
    for bad in "../../$AGY_NEW_ID" "$AGY_NEW_ID-x" '--help'; do
        : > "$AGY_HOOK_OUT"
        output=$(AGY_NEW_ID="$bad" "$CS_BIN" guarded 2>&1) || { echo "$output"; return 1; }
        assert_not_exists "$dir/.cs/local/antigravity-conversation" "the id '$bad' is not bound" || return 1
        assert_eq "" "$(grep -v -x -F '{}' "$AGY_HOOK_OUT")" "every hook answers {} for '$bad'" || return 1
    done
}

test_conversations_lists_the_antigravity_conversations() {
    local output dir second=44444444-4444-4444-8444-444444444444
    output=$("$CS_BIN" listed --engine antigravity 2>&1) || { echo "$output"; return 1; }
    output=$(AGY_NEW_ID=$second "$CS_BIN" listed --fresh 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir listed)
    output=$(CS_SESSION_META_DIR="$dir/.cs" "$CS_BIN" -conversations 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" "antigravity:${AGY_NEW_ID:0:8}  started (startup)" || return 1
    assert_output_contains "$output" "antigravity:${AGY_NEW_ID:0:8} > ${second:0:8}  rotated (fresh)" || return 1
    assert_output_contains "$output" "antigravity:${second:0:8}  started (startup)  \\[current\\]"
}

test_a_missing_hook_is_named_at_launch_and_by_doctor() {
    local output dir
    rm -rf "$HOME/.gemini/config/plugins/cs"
    output=$("$CS_BIN" hookless --engine antigravity 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" 'The cs hook for Antigravity is missing' "the launch says so" || return 1
    assert_output_not_contains "$output" 'a reopen resumes this conversation' "and promises no exact reopen" || return 1
    dir=$(_session_dir hookless)
    assert_not_exists "$dir/.cs/local/antigravity-conversation" "no hook, no binding" || return 1
    output=$(CS_SESSION_DIR="$dir" CS_SESSION_META_DIR="$dir/.cs" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" 'Antigravity hook not installed' "doctor says so" || return 1
    mkdir -p "$HOME/.gemini/config/plugins/cs"
    printf '{"mine": {}}\n' > "$HOME/.gemini/config/plugins/cs/hooks.json"
    output=$(CS_SESSION_DIR="$dir" CS_SESSION_META_DIR="$dir/.cs" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "is not cs's, so cs left it alone" "a folder of the user's is named" || return 1
    rm -rf "$HOME/.gemini/config/plugins/cs"
    _install_agy_hook || return 1
    mkdir -p "$HOME/.gemini/config"
    printf '{"plugins": {"cs": {"enabled": false}}}\n' > "$HOME/.gemini/config/config.json"
    output=$(CS_SESSION_DIR="$dir" CS_SESSION_META_DIR="$dir/.cs" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" 'agy plugin enable cs' "a plugin switched off is named with the fix"
}

# A hook whose recovery consumer is gone (an install cut short before its
# scripts, or scripts/ deleted) still binds, but promises no autosave.
test_a_hook_without_its_recovery_consumer_is_named_at_launch_and_by_doctor() {
    local output dir
    rm -rf "$HOME/.gemini/config/plugins/cs/scripts"
    output=$("$CS_BIN" unsaved --engine antigravity 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" 'edits are not autosaved' "the launch says so" || return 1
    assert_output_not_contains "$output" 'edits are autosaved for recovery' "and promises no autosave" || return 1
    assert_eq "$AGY_NEW_ID" "$(_binding unsaved)" "the hook still binds the conversation" || return 1
    dir=$(_session_dir unsaved)
    output=$(CS_SESSION_DIR="$dir" CS_SESSION_META_DIR="$dir/.cs" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" 'has no recovery consumer' "doctor says so" || return 1
    assert_output_not_contains "$output" 'Antigravity hook installed' "and does not call it installed"
}

# What an install or a removal of cs left is cs's to finish: doctor sends the
# user to setup.sh, not to rename the folder.
test_doctor_sends_a_folder_cs_left_to_setup() {
    local output dir plugin="$HOME/.gemini/config/plugins/cs"
    output=$(AGY_NO_TURN=1 "$CS_BIN" leftover --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir leftover)
    rm "$plugin/hooks.json"
    output=$(CS_SESSION_DIR="$dir" CS_SESSION_META_DIR="$dir/.cs" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" 'holds only what an install or removal of cs left there' || return 1
    assert_output_not_contains "$output" "is not cs's" "a folder cs left is not called the user's"
}

# The hook's writes never follow a link: not a mark planted in the run's
# directory, not the session's log turned into a link out of the session.
test_the_hook_never_writes_through_a_link() {
    local output dir victim="$TEST_TMPDIR/victim" log_victim="$TEST_TMPDIR/log-victim"
    output=$(AGY_NO_TURN=1 "$CS_BIN" linked --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir linked)
    output=$(AGY_PLANT_LINK="$victim" "$CS_BIN" linked 2>&1) || { echo "$output"; return 1; }
    assert_not_exists "$victim" "a mark planted as a link is not written through" || return 1
    assert_eq "$AGY_NEW_ID" "$(_binding linked)" "the run still binds its conversation" || return 1
    printf 'theirs\n' > "$log_victim"
    output=$(AGY_PLANT_LOG="$log_victim" AGY_NEW_ID=44444444-4444-4444-8444-444444444444 \
        "$CS_BIN" linked --fresh 2>&1) || true
    assert_eq theirs "$(cat "$log_victim")" "the log line is not appended through a link planted mid-run" || return 1
    assert_eq 44444444-4444-4444-8444-444444444444 "$(_binding linked)" "the binding is still made"
}

# The installer quotes a cs path the shell would split; doctor reads it back.
test_doctor_reads_back_a_quoted_cs_path() {
    local output dir odd="$TEST_TMPDIR/it's here"
    output=$(AGY_NO_TURN=1 "$CS_BIN" quoted --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir quoted)
    mkdir -p "$odd"
    ln -s "$CS_BIN" "$odd/cs"
    ( source "$SCRIPT_DIR/../lib/01-manifests.sh" && _antigravity_plugin_register "$odd/cs" ) || return 1
    output=$(CS_SESSION_DIR="$dir" CS_SESSION_META_DIR="$dir/.cs" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Antigravity hook installed" "a quote in the path is read back"
}

test_edits_in_a_run_are_autosaved_for_recovery() {
    local output dir
    output=$(AGY_NO_TURN=1 "$CS_BIN" saved --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir saved)
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || git -C "$dir" init -q || return 1
    output=$(AGY_EDITS="$dir/notes.txt" CS_TEST_SYNC=1 "$CS_BIN" saved 2>&1) || { echo "$output"; return 1; }
    assert_eq edited "$(git -C "$dir" show "refs/worktree/cs/session/$AGY_NEW_ID:notes.txt" 2>&1)" \
        "agy's write reaches the conversation's recovery ref"
}

run_test test_missing_agy_names_the_install_line_before_creating_anything
run_test test_fresh_launch_starts_agy_in_the_session_with_its_context_rule
run_test test_reopen_resumes_by_id_and_fresh_and_resume_choose_explicitly
run_test test_the_reopen_question_takes_n_as_fresh_and_enter_as_continue
run_test test_a_first_run_left_before_any_turn_binds_nothing
run_test test_resume_without_a_binding_refuses
run_test test_an_invalid_binding_refuses_before_agy_starts
run_test test_launch_options_map_to_agy_flags
run_test test_an_agy_without_a_flag_cs_passes_is_refused_before_anything_is_written
run_test test_the_rule_stays_out_of_git_status
run_test test_the_exclude_entry_is_never_appended_through_a_link
run_test test_the_exclude_entry_is_anchored_below_the_checkout_root
run_test test_a_rule_cs_did_not_write_is_never_replaced
run_test test_a_linked_rules_folder_is_never_written_through
run_test test_a_rules_folder_swapped_for_a_link_mid_write_gets_nothing
run_test test_capabilities_claim_exact_resume_and_recovery_only
run_test test_unknown_engine_errors_list_all_three
run_test test_spawn_refuses_a_brief_or_task_it_cannot_deliver
run_test test_a_staged_spawn_seed_is_named_and_left_for_another_engine
run_test test_finish_and_handoff_launches_are_refused
run_test test_switch_is_refused_from_an_antigravity_run
run_test test_an_encrypted_session_is_refused_before_its_vault_opens
run_test test_a_feature_worktree_launches_and_keeps_its_rule_out_of_git
run_test test_the_engine_is_recorded_before_agy_starts
run_test test_relative_agy_and_cs_paths_resolve_before_the_launch_changes_folder
run_test test_from_handoff_is_refused_before_the_open_changes_the_session
run_test test_doctor_names_antigravity_and_its_binding
run_test test_a_legacy_latest_binding_continues_once_then_resumes_by_id
run_test test_a_fresh_start_rebinds_once_it_reaches_the_model
run_test test_a_later_conversation_in_the_run_never_takes_the_binding
run_test test_the_hook_acts_only_in_the_run_cs_launched
run_test test_conversations_lists_the_antigravity_conversations
run_test test_a_missing_hook_is_named_at_launch_and_by_doctor
run_test test_a_hook_without_its_recovery_consumer_is_named_at_launch_and_by_doctor
run_test test_edits_in_a_run_are_autosaved_for_recovery
run_test test_doctor_reads_back_a_quoted_cs_path
run_test test_the_hook_never_writes_through_a_link
run_test test_doctor_sends_a_folder_cs_left_to_setup
report_results
