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
    mkdir -p "$HOME" "$CS_SESSIONS_ROOT" "$CS_TRANSCRIPTS_DIR" "$TEST_TMPDIR/bin"
    use_fake_keychain
    # The fake records how cs started it and touches nothing under HOME.
    cat > "$TEST_TMPDIR/bin/agy" <<'AGY'
#!/usr/bin/env bash
# --help lists the flags cs passes, less any named in AGY_HELP_OMIT.
if [ "${1:-}" = --help ]; then
    for flag in --continue --model --effort --mode; do
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
    unset XDG_CONFIG_HOME AGY_BIN AGY_EXIT AGY_HELP_OMIT
    unset CS_DEFAULT_ENGINE CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CS_LEAD_PID CLAUDE_PID
    unset CS_RUN_ENGINE CS_RUN_ID CS_SESSION_DIR CS_SESSION_NAME CS_SESSION_META_DIR
}

teardown() {
    export PATH="${AGY_SAVED_PATH:-$PATH}"
    rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CS_TRANSCRIPTS_DIR CS_NO_UPDATE_CHECK CS_NO_ITERM2
    unset CS_NO_FUNCTION_HOOKS CLAUDE_CODE_BIN CODEX_BIN AGY_SAVED_PATH AGY_CLEAN_PATH
    unset AGY_LOG AGY_ARGV AGY_PWD AGY_ENV AGY_STATE AGY_BIN AGY_EXIT AGY_HELP_OMIT CS_DEFAULT_ENGINE
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
    assert_eq latest "$(cat "$dir/.cs/local/antigravity-conversation")" "binds the folder's latest conversation" || return 1
    assert_file_contains "$dir/.cs/local/state" '^engine: antigravity$' "the engine is remembered" || return 1
    assert_file_contains "$AGY_ENV" '^CS_RUN_ENGINE=antigravity$' "the run names its engine" || return 1
    assert_file_contains "$AGY_ENV" '^CS_SESSION_NAME=fresh$' "agy receives the session identity" || return 1
    assert_file_not_contains "$AGY_ENV" '^CLAUDE_CODE_SESSION_ID=' "Claude's conversation id does not leak" || return 1
    assert_not_exists "$dir/CLAUDE.local.md" "Antigravity does not prepare Claude" || return 1
    assert_not_exists "$dir/.claude" "Antigravity does not configure Claude" || return 1
    assert_output_contains "$output" 'Antigravity via cs' "the launch says what it supports"
}

test_reopen_continues_and_fresh_and_resume_choose_explicitly() {
    local output
    output=$("$CS_BIN" reopen --engine antigravity 2>&1) || { echo "$output"; return 1; }
    output=$("$CS_BIN" reopen 2>&1) || { echo "$output"; return 1; }
    assert_eq --continue "$(_agy_argv)" "an unattended reopen continues the latest conversation" || return 1
    output=$("$CS_BIN" reopen --fresh 2>&1) || { echo "$output"; return 1; }
    assert_eq "" "$(_agy_argv)" "--fresh starts a new conversation" || return 1
    output=$("$CS_BIN" reopen --resume 2>&1) || { echo "$output"; return 1; }
    assert_eq --continue "$(_agy_argv)" "--resume continues without asking"
}

test_the_reopen_question_takes_n_as_fresh_and_enter_as_continue() {
    local output
    output=$("$CS_BIN" asked --engine antigravity 2>&1) || { echo "$output"; return 1; }
    output=$(printf 'n' | CS_ASSUME_TTY=1 "$CS_BIN" asked 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" 'Continue previous Antigravity conversation' "asks on a terminal" || return 1
    assert_eq "" "$(_agy_argv)" "n starts fresh" || return 1
    output=$(printf 'y' | CS_ASSUME_TTY=1 "$CS_BIN" asked 2>&1) || { echo "$output"; return 1; }
    assert_eq --continue "$(_agy_argv)" "y continues"
}

# The first launch binds before agy starts. When that agy fails (a sign-in
# never finished, a crash at start), the folder may hold no conversation, and
# --continue would fall back to a parent or child folder's: the binding goes.
test_a_failed_first_run_leaves_no_binding() {
    local output status=0 binding
    output=$(AGY_EXIT=1 "$CS_BIN" stumble --engine antigravity 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: agy's failure must reach the caller: $output"; return 1; }
    binding="$(_session_dir stumble)/.cs/local/antigravity-conversation"
    assert_not_exists "$binding" "the failed first run's binding goes" || return 1
    output=$("$CS_BIN" stumble 2>&1) || { echo "  FAIL: the next open must launch: $output"; return 1; }
    assert_eq "" "$(_agy_argv)" "the next open starts a new conversation" || return 1
    assert_eq latest "$(cat "$binding")" "a run that ends cleanly binds" || return 1
    status=0
    output=$(AGY_EXIT=1 "$CS_BIN" stumble 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: agy's failure must reach the caller: $output"; return 1; }
    assert_eq latest "$(cat "$binding")" "a later failed run keeps the binding an earlier run made"
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
    printf 'not-the-word\n' > "$dir/.cs/local/antigravity-conversation"
    : > "$AGY_LOG"
    output=$("$CS_BIN" damaged 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: an invalid binding must fail"; return 1; }
    assert_output_contains "$output" 'Invalid Antigravity binding' "names the damage" || return 1
    assert_eq "" "$(cat "$AGY_LOG")" "agy is not started"
}

test_launch_options_map_to_agy_flags() {
    local output
    output=$("$CS_BIN" options --engine antigravity --model gemini-3-pro --effort high --approve-for-me 2>&1) \
        || { echo "$output"; return 1; }
    assert_eq '--model gemini-3-pro --effort high --mode auto' "$(_agy_argv)" \
        "model, effort and automatic approval reach agy" || return 1
    output=$("$CS_BIN" options --native-approval --model gemini-3-flash 2>&1) || { echo "$output"; return 1; }
    assert_eq '--continue --model gemini-3-flash' "$(_agy_argv)" "native approval adds no mode"
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

test_capabilities_claim_only_launch_context_and_memory() {
    local output dir capability status
    output=$("$CS_BIN" caps --engine antigravity 2>&1) || { echo "$output"; return 1; }
    dir=$(_session_dir caps)
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=antigravity "$CS_BIN" -engine 2>&1) \
        || { echo "  FAIL: cs -engine failed: $output"; return 1; }
    assert_output_contains "$output" 'engine: antigravity' || return 1
    assert_output_contains "$output" 'conversation: latest' || return 1
    assert_output_contains "$output" 'capabilities: launch startup_context memory_index' || return 1
    for capability in launch startup_context memory_index; do
        CS_SESSION_DIR="$dir" CS_RUN_ENGINE=antigravity "$CS_BIN" -engine supports "$capability" \
            || { echo "  FAIL: $capability should be supported"; return 1; }
    done
    for capability in exact_resume rotation spawn_brief mail_delivery feature_finish recovery_autosave; do
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
    assert_output_contains "$output" 'Antigravity integration capabilities: launch, startup_context, memory_index' || return 1
    assert_output_contains "$output" 'Antigravity binding: latest' || return 1
    if [[ "$output" == *Codex* ]]; then
        echo "  FAIL: an Antigravity doctor run must not name Codex: $output"; return 1
    fi
}

test_files_changed_drains_input_and_emits_nothing() {
    local output
    output=$(printf '%s\n' '{"hook_event_name":"PostToolUse","tool_name":"Write"}' \
        | bash -c 'source "$1"; cs_engine_call antigravity files_changed' _ "$SCRIPT_DIR/../hooks/cs-engine-events.sh") \
        || { echo "  FAIL: files_changed failed"; return 1; }
    assert_eq "" "$output" "no event is invented"
}

run_test test_missing_agy_names_the_install_line_before_creating_anything
run_test test_fresh_launch_starts_agy_in_the_session_with_its_context_rule
run_test test_reopen_continues_and_fresh_and_resume_choose_explicitly
run_test test_the_reopen_question_takes_n_as_fresh_and_enter_as_continue
run_test test_a_failed_first_run_leaves_no_binding
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
run_test test_capabilities_claim_only_launch_context_and_memory
run_test test_unknown_engine_errors_list_all_three
run_test test_spawn_refuses_a_brief_or_task_it_cannot_deliver
run_test test_finish_and_handoff_launches_are_refused
run_test test_switch_is_refused_from_an_antigravity_run
run_test test_an_encrypted_session_is_refused_before_its_vault_opens
run_test test_a_feature_worktree_launches_and_keeps_its_rule_out_of_git
run_test test_the_engine_is_recorded_before_agy_starts
run_test test_relative_agy_and_cs_paths_resolve_before_the_launch_changes_folder
run_test test_from_handoff_is_refused_before_the_open_changes_the_session
run_test test_doctor_names_antigravity_and_its_binding
run_test test_files_changed_drains_input_and_emits_nothing
report_results
