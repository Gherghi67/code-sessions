#!/usr/bin/env bash
# ABOUTME: Tests for scripts/sync-upstream.py, which merges an upstream release into the fork.
# ABOUTME: A fixture upstream, a fork that splits and reshapes it, and an upstream release to merge.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
SYNC="$SCRIPT_DIR/../scripts/sync-upstream.py"

# Upstream v1: a state fragment, a mail fragment that names the command and
# reads the session variables, a command file, a companion script, a build
# that commits bin/cs.
make_upstream() {
    UP="$TEST_TMPDIR/upstream"
    mkdir -p "$UP/lib" "$UP/bin"
    git init -q -b main "$UP"
    cat > "$UP/lib/40-state.sh" <<'EOF'
# ABOUTME: Session state.

# Pick a colour for the prompt bar.
_alloc_color() {
    echo red
}

_read_state() {
    cat "$1"
}
EOF
    cat > "$UP/lib/53-mail.sh" <<'EOF'
# ABOUTME: Mail between sessions.

send_mail() {
    [ -n "${CLAUDE_SESSION_META_DIR:-}" ] || return 0
    [ -n "$1" ] || error "cs -msg needs a body"
    echo "$1" >> "$CLAUDE_SESSION_META_DIR/mail"
}

# cs never reads mail twice.
read_mail() {
    cat "$CLAUDE_SESSION_META_DIR/mail"
}
EOF
    mkdir -p "$UP/commands"
    printf '# Checkpoint\n\nSave a labelled checkpoint of the session.\nRun `cs -checkpoint <label>`.\nIt snapshots git state.\n' \
        > "$UP/commands/checkpoint.md"
    printf '#!/usr/bin/env bash\necho "cs-statusline v1"\n' > "$UP/bin/cs-statusline"
    printf '#!/usr/bin/env bash\ncd "$(dirname "$0")"\ncat lib/*.sh > bin/cs\n' > "$UP/build.sh"
    printf 'cs is a session manager.\n' > "$UP/README.md"
    mkdir -p "$UP/tests"
    printf '# A test the fork never touches.\nrun_mail_tests\n' > "$UP/tests/test_mail.sh"
    chmod +x "$UP/bin/cs-statusline" "$UP/build.sh"
    (cd "$UP" && bash build.sh && git add -A && git commit -q -m v1 && git tag v1)
}

# The fork: Claude's colour helper moves to a fragment of its own, the session
# variables become engine-neutral (except one line, kept on purpose), the
# command file becomes a skill, and the README is rewritten by hand. The
# command stays cs.
make_fork() {
    FORK="$TEST_TMPDIR/fork"
    git clone -q "$UP" "$FORK"
    cat > "$FORK/lib/40-state.sh" <<'EOF'
# ABOUTME: Session state.

_read_state() {
    cat "$1"
}
EOF
    cat > "$FORK/lib/42-claude-state.sh" <<'EOF'
# ABOUTME: Claude's own session state.

_claude_only() {
    echo claude
}

# Pick a colour for the prompt bar.
_alloc_color() {
    echo red
}
EOF
    cat > "$FORK/lib/53-mail.sh" <<'EOF'
# ABOUTME: Mail between sessions.

send_mail() {
    [ -n "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}" ] || return 0
    [ -n "$1" ] || error "cs -msg needs a body"
    echo "$1" >> "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/mail"
}

# cs never reads mail twice.
read_mail() {
    cat "$CLAUDE_SESSION_META_DIR/mail"
}
EOF
    mkdir -p "$FORK/skills/checkpoint"
    git -C "$FORK" mv commands/checkpoint.md skills/checkpoint/SKILL.md
    printf -- '---\nname: checkpoint\n---\n%s\n' "$(cat "$FORK/skills/checkpoint/SKILL.md")" \
        > "$FORK/skills/checkpoint/SKILL.md"
    printf 'code-sessions is a fork of cs.\n' > "$FORK/README.md"
    (cd "$FORK" && git checkout -q -b rebrand && bash build.sh && git add -A && git commit -q -m rebrand)
}

# Upstream v2 changes the moved helper, adds a function beside it, edits the
# rewritten lines and the kept one, the moved command file, the companion and
# the README.
release_upstream() {
    sed -i.bak 's/echo red/echo blue/' "$UP/lib/40-state.sh"
    printf '\n_is_uuid() {\n    [ -n "$1" ]\n}\n' >> "$UP/lib/40-state.sh"
    printf '\n# <!-- cs:wrap-cues --> stays a sentinel; "cs: %%s" is the command.\n' >> "$UP/lib/53-mail.sh"
    # A jq variable named cs is not the command.
    printf '%s\n' '' 'mail_keys() {' '    jq -r --argjson cs "$1" '"'"'$cs | keys[]'"'"' "$2"' '}' >> "$UP/lib/53-mail.sh"
    sed -i.bak -e 's/cs -msg needs a body/cs -msg needs a non-empty body/' \
        -e 's/echo "\$1" >> /printf "%s\\n" "$1" >> /' \
        -e 's/# cs never reads mail twice\./# cs never reads mail twice, nor drops it./' \
        -e 's|cat "$CLAUDE_SESSION_META_DIR/mail"|cat "$CLAUDE_SESSION_META_DIR/mail" 2>/dev/null|' "$UP/lib/53-mail.sh"
    sed -i.bak 's/It snapshots git state\./It snapshots git state and the narrative./' "$UP/commands/checkpoint.md"
    sed -i.bak 's/v1/v2/' "$UP/bin/cs-statusline"
    printf 'cs is a session manager for Claude Code.\n' > "$UP/README.md"
    printf 'assert_output_contains "$out" "cs -msg needs a non-empty body"\n' >> "$UP/tests/test_mail.sh"
    printf 'ls "$CLAUDE_SESSION_DIR"\n' >> "$UP/tests/test_mail.sh"
    rm -f "$UP"/lib/*.bak "$UP"/bin/*.bak "$UP"/commands/*.bak
    (cd "$UP" && bash build.sh && git add -A && git commit -q -m v2 && git tag v2)
}

make_fixture() {
    make_upstream && make_fork && release_upstream
}

sync_start() {
    (cd "$FORK" && python3 "$SYNC" start --skip-tests) > "$TEST_TMPDIR/sync.log" 2>&1
}

sync_continue() {
    (cd "$WT" && python3 "$SYNC" continue --skip-tests "$@") > "$TEST_TMPDIR/continue.log" 2>&1
}

resolve_readme() {
    printf 'code-sessions is a fork of cs, for Claude Code and Codex.\n' > "$WT/README.md"
}

test_start_translates_upstream_into_the_forks_dialect() {
    make_fixture || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    local status=0
    sync_start || status=$?
    # Only the README, rewritten by hand on both sides, is left for a person.
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" '1 left in conflict' || return 1
    assert_file_contains "$WT/README.md" '^<<<<<<< ours' || return 1
    # The moved helper takes upstream's change where the fork keeps it; the
    # function upstream added stays where upstream put it.
    assert_file_contains "$WT/lib/42-claude-state.sh" 'echo blue' || return 1
    assert_file_contains "$WT/lib/42-claude-state.sh" '_claude_only' || return 1
    assert_file_not_contains "$WT/lib/40-state.sh" '_alloc_color' || return 1
    assert_file_contains "$WT/lib/40-state.sh" '_is_uuid()' || return 1
    # Upstream's edits arrive with the fork's variable forms; the line the fork
    # kept stays as upstream writes it, and the command stays cs.
    grep -Fqx '    [ -n "$1" ] || error "cs -msg needs a non-empty body"' "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: message not merged"; return 1; }
    grep -Fqx '    printf "%s\n" "$1" >> "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/mail"' "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: variable not rewritten"; return 1; }
    grep -Fqx '    cat "$CLAUDE_SESSION_META_DIR/mail" 2>/dev/null' "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: kept line rewritten"; return 1; }
    grep -Fqx '# cs never reads mail twice, nor drops it.' "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: comment not merged"; return 1; }
    grep -Fqx '# <!-- cs:wrap-cues --> stays a sentinel; "cs: %s" is the command.' "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: sentinel or command changed"; return 1; }
    grep -Fqx "    jq -r --argjson cs \"\$1\" '\$cs | keys[]' \"\$2\"" "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: jq variable cs changed"; return 1; }
    # In a file the fork never touched, upstream's new lines take the variable forms.
    assert_eq '# A test the fork never touches.
run_mail_tests
assert_output_contains "$out" "cs -msg needs a non-empty body"
ls "${CS_SESSION_DIR:-${CLAUDE_SESSION_DIR:-}}"' "$(cat "$WT/tests/test_mail.sh")" || return 1
    # The command file's change lands in the skill the fork made of it.
    assert_file_contains "$WT/skills/checkpoint/SKILL.md" 'It snapshots git state and the narrative\.' || return 1
    assert_file_contains "$WT/skills/checkpoint/SKILL.md" '^name: checkpoint$' || return 1
    assert_not_exists "$WT/commands/checkpoint.md" || return 1
    assert_eq 'echo "cs-statusline v2"' "$(tail -1 "$WT/bin/cs-statusline")" || return 1
    # Generated files are rebuilt, never merged: bin/cs is still the fork's build.
    assert_eq "$(git -C "$FORK" show rebrand:bin/cs)" "$(cat "$WT/bin/cs")" || return 1
    # The fork's own checkout is untouched.
    assert_eq rebrand "$(git -C "$FORK" rev-parse --abbrev-ref HEAD)" || return 1
    assert_eq "" "$(git -C "$FORK" status --porcelain)"
}

test_continue_commits_a_merge_the_fork_can_fast_forward_to() {
    make_fixture || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    sync_start
    local status=0
    sync_continue || status=$?
    assert_eq 1 "$status" "continue refuses while markers remain" || return 1
    assert_file_contains "$TEST_TMPDIR/continue.log" 'README.md' || return 1
    resolve_readme
    sync_continue --trailer "Co-Authored-By: Test <t@example.com>" \
        || { cat "$TEST_TMPDIR/continue.log"; return 1; }
    # A real merge: the fork's tip and the release are both parents.
    assert_eq "$(git -C "$FORK" rev-parse rebrand) $(git -C "$FORK" rev-parse 'v2^{commit}')" \
        "$(git -C "$WT" log -1 --format=%P)" || return 1
    git -C "$WT" log -1 --format=%B | grep -q '^Co-Authored-By: Test' || { echo "  FAIL: no trailer"; return 1; }
    assert_eq "" "$(git -C "$WT" status --porcelain)" || return 1
    # build.sh ran: bin/cs carries the merged sources.
    assert_file_contains "$WT/bin/cs" 'echo blue' || return 1
    git -C "$FORK" merge -q --ff-only sync/v2 || return 1
    # Merged once, a rerun finds nothing to do.
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Already contains v2'
}

test_continue_refuses_a_function_defined_in_two_fragments() {
    make_fixture || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    sync_start
    resolve_readme
    printf '\n_claude_only() {\n    echo twice\n}\n' >> "$WT/lib/40-state.sh"
    local status=0
    sync_continue || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/continue.log" '_claude_only: lib/40-state.sh, lib/42-claude-state.sh' || return 1
    # Nothing was committed: the merge is still in progress.
    git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null || { echo "  FAIL: merge was committed"; return 1; }
}

test_start_refuses_uncommitted_work() {
    make_fixture || return 1
    printf 'draft\n' >> "$FORK/README.md"
    local status=0
    sync_start || status=$?
    assert_eq 2 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/sync.log" 'uncommitted changes' || return 1
    assert_not_exists "$TEST_TMPDIR/fork-sync-v2"
}

test_start_merges_an_upstream_that_only_touched_untouched_files() {
    make_upstream && make_fork || return 1
    printf 'notes\n' > "$UP/NOTES.md"
    (cd "$UP" && git add -A && git commit -q -m notes && git tag v1.1)
    WT="$TEST_TMPDIR/fork-sync-v1.1"
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" "Committed the merge of v1.1" || return 1
    assert_eq notes "$(cat "$WT/NOTES.md")"
}

# A checkout kept inside another repository (a cs session folder) gets its
# sync worktree beside that repository, not as untracked files inside it.
test_start_puts_the_worktree_outside_an_enclosing_repository() {
    make_upstream || return 1
    git init -q "$TEST_TMPDIR/outer"
    FORK="$TEST_TMPDIR/outer/fork"
    git clone -q "$UP" "$FORK"
    (cd "$FORK" && git checkout -q -b rebrand)
    printf 'notes\n' > "$UP/NOTES.md"
    (cd "$UP" && git add -A && git commit -q -m notes && git tag v1.1)
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_dir "$TEST_TMPDIR/fork-sync-v1.1" || return 1
    assert_not_exists "$TEST_TMPDIR/outer/fork-sync-v1.1"
}

# Tag one more upstream release that writes one file: $1 tag, $2 path, $3 text.
release() {
    printf '%s\n' "$3" > "$UP/$2"
    (cd "$UP" && git add -A && git commit -q -m "$1" && git tag "$1")
}

run_sync() {  # command [args...]: output in sync.log, exit status kept
    (cd "$FORK" && python3 "$SYNC" "$@") > "$TEST_TMPDIR/sync.log" 2>&1
}

test_status_lists_missing_releases_and_dry_runs_the_next() {
    make_fixture || return 1
    release v3 NOTES.md notes || return 1
    local status=0
    run_sync status || status=$?
    assert_eq 1 "$status" "status exits 1 while a release is missing" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" 'contains v1\. 2 release(s)' || return 1
    local v2 v3
    v2=$(grep -n '^  v2 ' "$TEST_TMPDIR/sync.log" | cut -d: -f1)
    v3=$(grep -n '^  v3 ' "$TEST_TMPDIR/sync.log" | cut -d: -f1)
    [ -n "$v2" ] && [ -n "$v3" ] && [ "$v2" -lt "$v3" ] \
        || { cat "$TEST_TMPDIR/sync.log"; echo "  FAIL: releases not listed oldest first"; return 1; }
    # The dry run names what the next merge leaves for a person.
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Merging v2 next would leave 1 file(s)' || return 1
    assert_file_contains "$TEST_TMPDIR/sync.log" '^  README.md$' || return 1
    # And it is only a dry run: no worktree, no branch, the checkout untouched.
    assert_not_exists "$TEST_TMPDIR/fork-sync-v2" || return 1
    assert_eq "" "$(git -C "$FORK" branch --list 'sync/*')" || return 1
    assert_eq "" "$(git -C "$FORK" status --porcelain)"
}

test_status_exits_0_when_up_to_date() {
    make_upstream && make_fork || return 1
    run_sync status || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Up to date: this branch contains v1'
}

test_catch_up_lands_clean_releases_and_stops_at_the_first_conflict() {
    make_upstream && make_fork || return 1
    release v1.1 NOTES.md notes || return 1
    release v1.2 README.md 'cs is a session manager for Claude Code.' || return 1
    release v1.3 CHANGES.md changes || return 1
    local status=0
    run_sync catch-up --skip-tests || status=$?
    assert_eq 1 "$status" "catch-up stops at the release that needs a person" \
        || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    # v1.1 merged cleanly: landed on the fork's branch, its worktree and branch gone.
    assert_eq rebrand "$(git -C "$FORK" rev-parse --abbrev-ref HEAD)" || return 1
    git -C "$FORK" merge-base --is-ancestor 'v1.1^{commit}' rebrand || { echo "  FAIL: v1.1 not landed"; return 1; }
    assert_eq notes "$(cat "$FORK/NOTES.md")" || return 1
    assert_not_exists "$TEST_TMPDIR/fork-sync-v1.1" || return 1
    assert_eq "" "$(git -C "$FORK" branch --list sync/v1.1)" || return 1
    # v1.2 waits in its worktree; v1.3 is not started.
    WT="$TEST_TMPDIR/fork-sync-v1.2"
    assert_file_contains "$WT/README.md" '^<<<<<<< ours' || return 1
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Still to merge after it: v1.3' || return 1
    assert_not_exists "$TEST_TMPDIR/fork-sync-v1.3" || return 1
    # Run again before it is resolved: it points at the waiting worktree.
    status=0
    run_sync catch-up --skip-tests || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/sync.log" 'waits in .*/fork-sync-v1\.2\.' || return 1
    # Resolved and committed there, the next run lands it and finishes the rest.
    resolve_readme
    sync_continue || { cat "$TEST_TMPDIR/continue.log"; return 1; }
    run_sync catch-up --skip-tests || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Landed v1.2 on rebrand' || return 1
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Up to date' || return 1
    git -C "$FORK" merge-base --is-ancestor 'v1.3^{commit}' rebrand || { echo "  FAIL: v1.3 not landed"; return 1; }
    assert_eq "" "$(git -C "$FORK" branch --list 'sync/*')" || return 1
    assert_eq "" "$(git -C "$FORK" status --porcelain)"
}

# A cs session keeps its notes in .cs/, which change while the session is open.
test_start_ignores_a_cs_sessions_own_notes() {
    make_upstream && make_fork || return 1
    mkdir -p "$FORK/.cs/handoffs"
    printf 'objective\n' > "$FORK/.cs/README.md"
    (cd "$FORK" && git add -A && git commit -q -m "session notes") || return 1
    release v1.1 NOTES.md notes || return 1
    printf 'outcome\n' >> "$FORK/.cs/README.md"
    printf 'next step\n' > "$FORK/.cs/handoffs/2026-01-01.md"
    WT="$TEST_TMPDIR/fork-sync-v1.1"
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" "Committed the merge of v1.1" || return 1
    # The notes are as the session left them, and none of it reached the merge.
    assert_eq ' M .cs/README.md
?? .cs/handoffs/' "$(git -C "$FORK" status --porcelain)" || return 1
    assert_eq objective "$(cat "$WT/.cs/README.md")" || return 1
    assert_not_exists "$WT/.cs/handoffs"
}

# A GitHub Actions checkout has the fork as origin and upstream beside it.
test_remote_names_the_upstream() {
    make_upstream && make_fork || return 1
    release v1.1 NOTES.md notes || return 1
    git init -q --bare "$TEST_TMPDIR/fork-origin.git"
    git -C "$FORK" remote rename origin hex > /dev/null 2>&1 || return 1
    git -C "$FORK" remote add origin "$TEST_TMPDIR/fork-origin.git"
    git -C "$FORK" push -q origin rebrand || return 1
    local status=0
    run_sync missing || status=$?
    assert_eq 2 "$status" "origin is not upstream here" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    run_sync --remote hex missing || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_eq v1.1 "$(cat "$TEST_TMPDIR/sync.log")" || return 1
    WT="$TEST_TMPDIR/fork-sync-v1.1"
    (cd "$FORK" && SYNC_UPSTREAM_REMOTE=hex python3 "$SYNC" start --skip-tests) > "$TEST_TMPDIR/sync.log" 2>&1 \
        || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" "Committed the merge of v1.1" || return 1
    assert_eq notes "$(cat "$WT/NOTES.md")"
}

test_missing_prints_the_tags_oldest_first_and_nothing_else() {
    make_fixture || return 1
    release v3 NOTES.md notes || return 1
    run_sync missing || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_eq 'v2
v3' "$(cat "$TEST_TMPDIR/sync.log")" || return 1
    assert_eq "" "$(git -C "$FORK" status --porcelain)" || return 1
    # Up to date, it prints nothing and still exits 0.
    git -C "$FORK" merge -q -s ours --no-edit v3 || return 1
    run_sync missing || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_eq "" "$(cat "$TEST_TMPDIR/sync.log")"
}

# Upstream v1.1 has a hook, and a test that names it. The fork adds a line to
# the hook and names it in a fragment of its own.
make_hook_fixture() {
    make_upstream || return 1
    mkdir -p "$UP/hooks"
    cat > "$UP/hooks/reminder.sh" <<'EOF'
#!/usr/bin/env bash
# ABOUTME: Reminds the session to write its narrative before it stops.

remind() {
    echo "write the narrative"
    echo "then stop"
}

remind
EOF
    chmod +x "$UP/hooks/reminder.sh"
    printf '# hooks/reminder.sh has a suite of its own.\n' >> "$UP/tests/test_mail.sh"
    (cd "$UP" && bash build.sh && git add -A && git commit -q -m hook && git tag v1.1) || return 1
    make_fork || return 1
    cat > "$FORK/hooks/reminder.sh" <<'EOF'
#!/usr/bin/env bash
# ABOUTME: Reminds the session to write its narrative before it stops.

remind() {
    echo "write the narrative"
    echo "then stop"
    echo "the fork retires staged features"
}

remind
EOF
    printf '%s\n' '# ABOUTME: What only the fork runs.' '' 'run_reminder() {' '    bash hooks/reminder.sh' '}' \
        > "$FORK/lib/90-fork.sh"
    (cd "$FORK" && bash build.sh && git add -A && git commit -q -m "the fork's hook")
}

# Upstream v2 renames the hook; with "edit", it changes a line of it too.
release_renamed_hook() {
    (cd "$UP" && git mv hooks/reminder.sh hooks/blocks.sh) || return 1
    if [ "${1:-}" = edit ]; then
        sed -i.bak 's/write the narrative/write the narrative now/' "$UP/hooks/blocks.sh" && rm -f "$UP/hooks/blocks.sh.bak"
    fi
    (cd "$UP" && bash build.sh && git add -A && git commit -q -m v2 && git tag v2)
}

# The fork's copy takes the new name with its changes; it is not left behind
# as "deleted upstream" while upstream's file arrives without them.
test_a_file_upstream_renamed_keeps_the_forks_changes() {
    make_hook_fixture && release_renamed_hook edit || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    local status=0
    sync_start || status=$?
    assert_file_contains "$TEST_TMPDIR/sync.log" 'hooks/blocks.sh .*merged \[renamed upstream, was hooks/reminder.sh\]' \
        || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_not_contains "$TEST_TMPDIR/sync.log" 'deleted upstream' || return 1
    assert_file_contains "$WT/hooks/blocks.sh" 'write the narrative now' || return 1
    assert_file_contains "$WT/hooks/blocks.sh" 'the fork retires staged features' || return 1
    assert_file_not_contains "$WT/hooks/blocks.sh" '^<<<<<<<' || return 1
    [ -x "$WT/hooks/blocks.sh" ] || { echo "  FAIL: the hook lost its executable bit"; return 1; }
    assert_not_exists "$WT/hooks/reminder.sh" || return 1
    # The fork's own line still names the old file, which no marker can show:
    # the sync waits for a person. Upstream's mention (tests/test_mail.sh) and
    # the built bin/cs are not the fork's to fix.
    assert_eq 1 "$status" "a line of the fork's names the old file" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_eq 'Check by hand, no marker written: lib/90-fork.sh: line 4 names hooks/reminder.sh, which upstream renamed to hooks/blocks.sh' \
        "$(grep 'Check by hand' "$TEST_TMPDIR/sync.log")" || return 1
    git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null || { echo "  FAIL: the merge was committed"; return 1; }
    sed -i.bak 's|hooks/reminder.sh|hooks/blocks.sh|' "$WT/lib/90-fork.sh" && rm -f "$WT/lib/90-fork.sh.bak"
    sync_continue || { cat "$TEST_TMPDIR/continue.log"; return 1; }
    assert_eq hooks/blocks.sh "$(git -C "$WT" ls-files hooks)"
}

# The fork deleted the file: upstream renaming it brings nothing back.
test_a_rename_of_a_file_the_fork_deleted_brings_nothing_back() {
    make_hook_fixture || return 1
    (cd "$FORK" && git rm -q hooks/reminder.sh lib/90-fork.sh && bash build.sh && git add -A \
        && git commit -q -m "the fork drops the hook") || return 1
    release_renamed_hook || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" "Committed the merge of v2" || return 1
    assert_eq "" "$(git -C "$WT" ls-files hooks)"
}

# Renamed and changed upstream, it is the fork's deletion against upstream's
# change, as for any other file, under the name the fork knew.
test_a_changed_rename_of_a_file_the_fork_deleted_waits_for_a_person() {
    make_hook_fixture || return 1
    (cd "$FORK" && git rm -q hooks/reminder.sh lib/90-fork.sh && bash build.sh && git add -A \
        && git commit -q -m "the fork drops the hook") || return 1
    release_renamed_hook edit || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    local status=0
    sync_start || status=$?
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$WT/hooks/reminder.sh" '^<<<<<<< deleted in the fork, changed upstream$' || return 1
    assert_file_contains "$WT/hooks/reminder.sh" 'write the narrative now' || return 1
    assert_not_exists "$WT/hooks/blocks.sh"
}

# As above, but upstream moves the hook to another directory and puts a
# symlink where hooks/ was. The renamed file is read under the name the fork
# knew, hooks/reminder.sh, which now leads through the link: start refuses
# before it writes anything outside its worktree.
test_start_never_writes_through_a_symlink_out_of_its_worktree() {
    make_hook_fixture || return 1
    (cd "$FORK" && git rm -q hooks/reminder.sh lib/90-fork.sh && bash build.sh && git add -A \
        && git commit -q -m "the fork drops the hook") || return 1
    mkdir -p "$TEST_TMPDIR/outside" "$UP/other"
    (cd "$UP" && git mv hooks/reminder.sh other/blocks.sh) || return 1
    sed -i.bak 's/write the narrative/write the narrative now/' "$UP/other/blocks.sh" && rm -f "$UP/other/blocks.sh.bak"
    rmdir "$UP/hooks" 2>/dev/null || true
    ln -s "$TEST_TMPDIR/outside" "$UP/hooks"
    (cd "$UP" && bash build.sh && git add -A && git commit -q -m v2 && git tag v2) || return 1
    local status=0
    sync_start || status=$?
    assert_eq 2 "$status" "a path that leads out of the worktree is an error" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" '^Error: Refusing to write hooks/reminder.sh: a symbolic link takes it out of the sync worktree' \
        || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_eq "" "$(ls -A "$TEST_TMPDIR/outside")" "nothing written outside the worktree"
}

test_a_file_deleted_on_both_sides_needs_nobody() {
    make_upstream && make_fork || return 1
    (cd "$FORK" && git rm -q bin/cs-statusline && git commit -q -m "the fork drops the companion") || return 1
    (cd "$UP" && git rm -q bin/cs-statusline && git commit -q -m v1.1 && git tag v1.1) || return 1
    WT="$TEST_TMPDIR/fork-sync-v1.1"
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" "Committed the merge of v1.1" || return 1
    assert_file_not_contains "$TEST_TMPDIR/sync.log" 'Check by hand' || return 1
    assert_file_contains "$TEST_TMPDIR/sync.log" '0 left in conflict'
}

# ${CLAUDE_SESSION_NAME:-${dir##*/}} has a fork form; ${CLAUDE_SESSION_NAME//@/+}
# has none, and a merge that keeps it is not a clean one.
test_start_stops_at_an_expansion_with_no_fork_form() {
    make_upstream && make_fork || return 1
    # shellcheck disable=SC2016  # the fixture's text, not this suite's variables
    printf '%s\n' 'name="${CLAUDE_SESSION_NAME:-${dir##*/}}"' \
        'where="${CLAUDE_SESSION_NAME:-$CLAUDE_SESSION_DIR}"' \
        'label="${CLAUDE_SESSION_NAME//@/+}"' >> "$UP/tests/test_mail.sh"
    (cd "$UP" && git add -A && git commit -q -m v1.1 && git tag v1.1) || return 1
    WT="$TEST_TMPDIR/fork-sync-v1.1"
    local status=0
    run_sync status || status=$?
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Merging v1.1 next would leave 1 file(s)' || return 1
    status=0
    sync_start || status=$?
    assert_eq 1 "$status" "an expansion with no fork form waits for a person" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    # shellcheck disable=SC2016
    grep -Fq 'Check by hand, no marker written: tests/test_mail.sh: line 5 keeps ${CLAUDE_SESSION_NAME//@/+}, which has no CS_ form' \
        "$TEST_TMPDIR/sync.log" || { cat "$TEST_TMPDIR/sync.log"; echo "  FAIL: the kept expansion is not reported"; return 1; }
    assert_eq 1 "$(grep -c 'Check by hand' "$TEST_TMPDIR/sync.log")" || return 1
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Nothing is committed yet' || return 1
    # shellcheck disable=SC2016
    assert_eq '# A test the fork never touches.
run_mail_tests
name="${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-${dir##*/}}}"
where="${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-${CS_SESSION_DIR:-${CLAUDE_SESSION_DIR:-}}}}"
label="${CLAUDE_SESSION_NAME//@/+}"' "$(cat "$WT/tests/test_mail.sh")" || return 1
    git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null || { echo "  FAIL: the merge was committed"; return 1; }
    # Once a person has looked, continue commits it.
    sync_continue || { cat "$TEST_TMPDIR/continue.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/continue.log" "Committed the merge of v1.1"
}

# This checkout, not a fixture: upstream changes VERSION in lib/00-header.sh in
# every release, and a line of the fork's touching it made each release a
# conflict. Merges the fork's header with the last release it merged, bumped.
test_an_upstream_version_bump_merges_into_this_forks_header() {
    local repo="$SCRIPT_DIR/.." release
    # By subject: the pull request that lands a sync repeats its title in the
    # body of its own merge commit, whose second parent is the fork's branch.
    release=$(git -C "$repo" log --merges --format='%s %P' 2>/dev/null \
        | awk '/^Merge upstream v[^ ]* into [^ ]* [0-9a-f]+ [0-9a-f]+$/ { print $NF; exit }')
    if [ -z "$release" ] || ! git -C "$repo" show "$release:lib/00-header.sh" > "$TEST_TMPDIR/base" 2>/dev/null; then
        echo "  SKIP: this checkout's history holds no merged upstream release"
        return 77
    fi
    sed 's/^VERSION=.*/VERSION="9999.1.1"/' "$TEST_TMPDIR/base" > "$TEST_TMPDIR/upstream"
    cp "$repo/lib/00-header.sh" "$TEST_TMPDIR/ours"
    git merge-file -p --zdiff3 "$TEST_TMPDIR/ours" "$TEST_TMPDIR/base" "$TEST_TMPDIR/upstream" > "$TEST_TMPDIR/merged" \
        || { sed -n '/^<<<<<<< /,/^>>>>>>> /p' "$TEST_TMPDIR/merged"; echo "  FAIL: a version bump conflicts with the fork's header"; return 1; }
    assert_file_contains "$TEST_TMPDIR/merged" '^VERSION="9999.1.1"$' || return 1
    assert_file_contains "$TEST_TMPDIR/merged" '^CS_FORK="code-sessions"$'
}

run_test test_start_translates_upstream_into_the_forks_dialect
run_test test_status_lists_missing_releases_and_dry_runs_the_next
run_test test_status_exits_0_when_up_to_date
run_test test_catch_up_lands_clean_releases_and_stops_at_the_first_conflict
run_test test_start_puts_the_worktree_outside_an_enclosing_repository
run_test test_continue_commits_a_merge_the_fork_can_fast_forward_to
run_test test_continue_refuses_a_function_defined_in_two_fragments
run_test test_start_refuses_uncommitted_work
run_test test_start_merges_an_upstream_that_only_touched_untouched_files
run_test test_start_ignores_a_cs_sessions_own_notes
run_test test_remote_names_the_upstream
run_test test_missing_prints_the_tags_oldest_first_and_nothing_else
run_test test_a_file_upstream_renamed_keeps_the_forks_changes
run_test test_a_rename_of_a_file_the_fork_deleted_brings_nothing_back
run_test test_a_changed_rename_of_a_file_the_fork_deleted_waits_for_a_person
run_test test_start_never_writes_through_a_symlink_out_of_its_worktree
run_test test_a_file_deleted_on_both_sides_needs_nobody
run_test test_start_stops_at_an_expansion_with_no_fork_form
run_test test_an_upstream_version_bump_merges_into_this_forks_header
report_results
