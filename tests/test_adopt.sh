#!/usr/bin/env bash
# ABOUTME: Tests for the cs -adopt command that converts existing projects to cs sessions
# ABOUTME: Validates symlink creation, .cs/ structure, CLAUDE.local.md protocol placement, and edge cases

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to also unset session env vars
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
}

# ============================================================================
# Tests
# ============================================================================

test_adopt_creates_cs_structure() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_dir "$project_dir/.cs" ".cs/ directory should exist" || return 1
    assert_dir "$project_dir/.cs/local" ".cs/local/ should exist" || return 1
    assert_exists "$project_dir/.cs/local/session.log" "session.log should exist" || return 1
    assert_exists "$project_dir/.cs/README.md" ".cs/README.md should exist" || return 1
    local nf
    nf=$(ls "$project_dir"/.cs/memory/narrative.*.md 2>/dev/null | head -1)
    assert_exists "$nf" "a per-actor narrative file should exist" || return 1
    assert_not_exists "$project_dir/.cs/sync.conf" "sync.conf must not be created (sync subsystem removed)" || return 1
}

test_adopt_creates_symlink() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_symlink "$CS_SESSIONS_ROOT/my-session" "Session symlink should exist" || return 1

    local target
    target="$(readlink -f "$CS_SESSIONS_ROOT/my-session")"
    local real_project
    real_project="$(cd "$project_dir" && pwd -P)"
    assert_eq "$real_project" "$target" "Symlink should point to project directory" || return 1
}

test_adopt_creates_claude_local_md_when_none_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_exists "$project_dir/CLAUDE.local.md" "CLAUDE.local.md should be created" || return 1
    assert_file_contains "$project_dir/CLAUDE.local.md" "Session Documentation Protocol" \
        "CLAUDE.local.md should contain session protocol" || return 1
    assert_not_exists "$project_dir/CLAUDE.md" "CLAUDE.md should not be created when none existed" || return 1
}

test_adopt_leaves_existing_claude_md_untouched() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    cat > "$project_dir/CLAUDE.md" << 'EOF'
# My Project Rules

- Use TypeScript for all files
- Follow strict ESLint config
EOF

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_file_contains "$project_dir/CLAUDE.local.md" "Session Documentation Protocol" \
        "CLAUDE.local.md should contain session protocol" || return 1
    assert_file_contains "$project_dir/CLAUDE.md" "Use TypeScript for all files" \
        "CLAUDE.md should preserve original content" || return 1
    assert_file_not_contains "$project_dir/CLAUDE.md" "Session Documentation Protocol" \
        "CLAUDE.md must not gain the protocol" || return 1
}

# A user's own CLAUDE.local.md is gitignored, so git holds no copy of it: the
# protocol is appended below every line the user wrote.
test_adopt_appends_protocol_to_an_existing_claude_local_md() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    printf '# My local notes\n\nUSER-LOCAL-KEEP\n' > "$project_dir/CLAUDE.local.md"
    local before
    before=$(cat "$project_dir/CLAUDE.local.md")

    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    local after
    after=$(cat "$project_dir/CLAUDE.local.md")
    case "$after" in
        "$before"*) ;;
        *)
            echo "  FAIL: adopt must keep every line of an existing CLAUDE.local.md above the protocol"
            echo "    after: $after"
            return 1
            ;;
    esac
    assert_file_contains "$project_dir/CLAUDE.local.md" "<!-- cs:session-protocol -->" \
        "the protocol is appended to the user's CLAUDE.local.md" || return 1
}

# A CLAUDE.local.md that already carries a cs sentinel is left exactly as it is.
test_adopt_leaves_a_claude_local_md_with_the_protocol_alone() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nUSER-EDITED-PROTOCOL-LINE\n' \
        > "$project_dir/CLAUDE.local.md"
    local before
    before=$(cat "$project_dir/CLAUDE.local.md")

    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    assert_eq "$before" "$(cat "$project_dir/CLAUDE.local.md")" \
        "a CLAUDE.local.md that already has the protocol must be byte-identical after adopt" || return 1
}

# A project with a .gitignore but no git repo keeps every ignore rule it had;
# cs only adds its own. The rules matter before the adopt commit: a lost
# `.env` line would commit the file it was hiding.
test_adopt_without_git_keeps_the_existing_gitignore_lines() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    printf 'node_modules/\n.env' > "$project_dir/.gitignore"
    printf 'API_TOKEN=example\n' > "$project_dir/.env"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    assert_file_contains "$project_dir/.gitignore" '^node_modules/$' \
        "the project's node_modules/ rule must survive" || return 1
    assert_file_contains "$project_dir/.gitignore" '^\.env$' \
        "the project's last rule, without a trailing newline, must survive whole" || return 1
    assert_file_contains "$project_dir/.gitignore" '^\.cs/local/$' \
        "cs adds its .cs/local/ rule" || return 1
    assert_eq "" "$(git -C "$project_dir" ls-files .env)" \
        "the ignored .env must not be committed by the adopt" || return 1
}

# The same merge in a project that is already a git repo: a last line with no
# trailing newline must not swallow cs's first appended rule.
test_adopt_into_git_repo_keeps_a_last_gitignore_line_without_newline() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git commit --allow-empty -m "initial" -q)
    printf 'build/\ndist' > "$project_dir/.gitignore"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    assert_file_contains "$project_dir/.gitignore" '^dist$' \
        "the project's last rule must survive whole" || return 1
    assert_file_contains "$project_dir/.gitignore" '^\.cs/local/$' \
        "cs adds its .cs/local/ rule on a line of its own" || return 1
}

# A .gitignore that only MENTIONS one of cs's rules, commented out or negated,
# does not ignore that path: cs still adds the rule as a line of its own, and
# git then ignores the per-actor state.
test_adopt_adds_its_rule_beside_a_commented_or_negated_mention() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git commit --allow-empty -m "initial" -q)
    printf '# .cs/local/\n!.cs/archives/\n' > "$project_dir/.gitignore"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    assert_file_contains "$project_dir/.gitignore" '^\.cs/local/$' \
        "cs adds .cs/local/ although a comment mentions it" || return 1
    assert_file_contains "$project_dir/.gitignore" '^\.cs/archives/$' \
        "cs adds .cs/archives/ although a negation mentions it" || return 1
    assert_eq ".cs/local/session.log" \
        "$(git -C "$project_dir" check-ignore .cs/local/session.log)" \
        "git ignores the per-actor log" || return 1
}

# The home directory is never a project: adopting it would git init and
# commit everything under it. Refused before anything is written.
test_adopt_refuses_the_home_directory() {
    local output rc=0
    output=$(cd "$HOME" && "$CS_BIN" -adopt home-session 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: adopting \$HOME must fail"
        return 1
    fi
    assert_output_contains "$output" "Refusing to adopt your home directory" \
        "the refusal names the home directory" || return 1
    assert_not_exists "$HOME/.cs" "no .cs/ may be created in \$HOME" || return 1
    assert_not_exists "$HOME/CLAUDE.local.md" "no CLAUDE.local.md may be written in \$HOME" || return 1
    assert_not_exists "$HOME/.gitignore" "no .gitignore may be written in \$HOME" || return 1
    assert_not_exists "$HOME/.git" "no git repo may be created in \$HOME" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/home-session" "no session link may be created" || return 1
}

# The sessions root holds every session, and adopting it, or a directory that
# contains it, would git init and commit all of them and link a session into
# itself. Refused before anything is written, like $HOME.
test_adopt_refuses_the_sessions_root_and_its_parents() {
    local root parent dir output rc
    root=$(cd "$CS_SESSIONS_ROOT" && pwd -P)
    parent=$(cd "$TEST_TMPDIR" && pwd -P)
    for dir in "$root" "$parent"; do
        rc=0
        output=$(cd "$dir" && "$CS_BIN" -adopt root-session 2>&1) || rc=$?
        assert_eq 1 "$rc" "adopting $dir must fail" || return 1
        assert_output_contains "$output" "Error: Refusing to adopt $dir: it is or contains the sessions root ($root). Run cs -adopt from a project directory." \
            "the refusal names the sessions root" || return 1
        assert_not_exists "$dir/.cs" "no .cs/ may be created in $dir" || return 1
        assert_not_exists "$dir/.gitignore" "no .gitignore may be written in $dir" || return 1
        assert_not_exists "$dir/.git" "no git repo may be created in $dir" || return 1
        assert_not_exists "$CS_SESSIONS_ROOT/root-session" "no session link may be created" || return 1
    done
    # Positive control: a sibling of the sessions root is a project like any other.
    mkdir -p "$TEST_TMPDIR/sibling"
    (cd "$TEST_TMPDIR/sibling" && "$CS_BIN" -adopt sibling-session >/dev/null 2>&1) \
        || { echo "  FAIL: adopting a sibling of the sessions root failed"; return 1; }
    assert_symlink "$CS_SESSIONS_ROOT/sibling-session" "the sibling is adopted" || return 1
}

test_adopt_refuses_a_directory_already_linked() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt first-name >/dev/null 2>&1)

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt second-name 2>&1); then
        echo "  FAIL: Should have failed for a directory already linked under another name"
        return 1
    fi
    if ! grep -q "first-name" <<< "$output"; then
        echo "  FAIL: Error message should name the existing session 'first-name': $output"
        return 1
    fi
    assert_not_exists "$CS_SESSIONS_ROOT/second-name" "no symlink should be created for the refused name" || return 1
}

test_adopt_relinks_orphaned_records_interactively() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local narrative
    narrative=$(ls "$project_dir"/.cs/memory/narrative.*.md | head -1)
    printf '\nmarker: orphaned-records-survive\n' >> "$narrative"
    local before
    before=$(cat "$narrative")

    local output rc=0
    output=$(cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: re-adopt should exit 0: $output"; return 1; }

    assert_symlink "$CS_SESSIONS_ROOT/new-name" "new symlink should exist" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/old-name" "old symlink name should stay gone" || return 1
    local after
    after=$(cat "$narrative")
    assert_eq "$before" "$after" "narrative file should be byte-identical after re-adopt" || return 1
}

# Re-adopting orphaned records promises to preserve them; the command log is
# one of them, and every byte it held must survive the re-adopt.
test_readopt_keeps_the_session_log() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local log="$project_dir/.cs/local/session.log"
    printf 'marker: log-survives-readopt\n' >> "$log"
    local before
    before=$(cat "$log")

    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }
    local after
    after=$(cat "$log")
    case "$after" in
        "$before"*) ;;
        *)
            echo "  FAIL: re-adopt must keep every byte of the existing session.log"
            echo "    after: $after"
            return 1
            ;;
    esac
}

# An encrypted session keeps its log behind .cs/private. Re-adopting its
# records must not start a plaintext .cs/local/session.log beside it, which
# the next open refuses.
test_readopt_of_an_encrypted_session_keeps_its_log_in_the_vault() {
    local project_dir="$TEST_TMPDIR/my-project" vault="$TEST_TMPDIR/vault-mnt"
    mkdir -p "$project_dir" "$vault/private"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"
    mv "$project_dir/.cs/local/session.log" "$vault/private/session.log"
    ln -s "$vault/private" "$project_dir/.cs/private"
    _mark_hand_made_vault "$project_dir"
    local before
    before=$(cat "$vault/private/session.log")

    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }

    assert_not_exists "$project_dir/.cs/local/session.log" \
        "no plaintext session.log beside .cs/private" || return 1
    assert_eq "$before" "$(cat "$vault/private/session.log")" \
        "the vault's session.log is untouched" || return 1
    local out rc=0
    out=$("$CS_BIN" new-name <<< "" 2>&1) || rc=$?
    assert_eq 0 "$rc" "the re-adopted session opens: $out" || return 1
}

# Re-adopting an encrypted session whose vault is locked refuses before it
# writes anything: the records behind the vault links cannot be reached, so
# adopt would set up a half session over them. The state keeps the
# conversation it names, and no session link is made.
test_readopt_of_an_encrypted_session_with_a_locked_vault_refuses() {
    local project_dir="$TEST_TMPDIR/my-project" vault="$TEST_TMPDIR/vault-mnt" out rc=0 expected before
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"
    rm "$project_dir/.cs/local/session.log"
    ln -s "$vault/private" "$project_dir/.cs/private"
    printf 'claude_session_id: 11111111-2222-4333-8444-555555555555\n' >> "$project_dir/.cs/local/state"
    before=$(cat "$project_dir/.cs/local/state")

    out=$(cd "$project_dir" && "$CS_BIN" -adopt new-name --yes </dev/null 2>&1) || rc=$?
    assert_eq 1 "$rc" "the re-adopt refuses: $out" || return 1
    expected="Error: Cannot re-adopt as 'new-name': .cs/private points at $vault/private, which is missing (encrypted storage not mounted?). Mount it and run cs -adopt again; nothing was changed."
    assert_eq "$expected" "$out" "the locked vault is named" || return 1
    assert_eq "$before" "$(cat "$project_dir/.cs/local/state")" "the state is untouched" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/new-name" "no session link" || return 1
    assert_not_exists "$project_dir/.cs/local/session.log" \
        "no plaintext session.log beside .cs/private" || return 1
}

# cs -encrypt links memory, plans, claude-config and private into the vault;
# with it locked, the first of them to lead nowhere is the one named.
test_readopt_with_every_vault_link_dangling_refuses_naming_memory() {
    local project_dir="$TEST_TMPDIR/my-project" out rc=0 sub before
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"
    rm "$project_dir/.cs/local/session.log"
    for sub in memory plans claude-config private; do
        rm -rf "$project_dir/.cs/$sub"
        ln -s "vault-mnt/$sub" "$project_dir/.cs/$sub"
    done
    before=$(cat "$project_dir/.cs/local/state")

    out=$(cd "$project_dir" && "$CS_BIN" -adopt new-name --yes </dev/null 2>&1) || rc=$?
    assert_eq 1 "$rc" "the re-adopt refuses: $out" || return 1
    assert_eq "Error: Cannot re-adopt as 'new-name': .cs/memory points at vault-mnt/memory, which is missing (encrypted storage not mounted?). Mount it and run cs -adopt again; nothing was changed." \
        "$out" "memory is named first" || return 1
    assert_eq "$before" "$(cat "$project_dir/.cs/local/state")" "the state is untouched" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/new-name" "no session link" || return 1
}

# A cloned project can commit .gitignore, .gitattributes or CLAUDE.local.md as
# a link to a file outside the checkout, and adopt appends to all three. Each
# is refused before adopt writes anything: the file outside keeps its bytes,
# and the project gets no .cs and no session link.
test_adopt_refuses_a_committed_link_it_would_write_through() {
    local name project_dir outside before out rc
    for name in CLAUDE.local.md .gitignore .gitattributes; do
        project_dir="$TEST_TMPDIR/proj-$name"
        outside="$TEST_TMPDIR/outside-$name"
        mkdir -p "$project_dir"
        printf 'a file that is not the project'"'"'s\n' > "$outside"
        before=$(cksum < "$outside")
        ( cd "$project_dir" && git init -q && git config user.email jane.roe@example.com \
            && git config user.name "Jane Roe" && ln -s "../outside-$name" "$name" \
            && git add -A && git commit -q -m "a project with a committed link" )

        rc=0
        out=$(cd "$project_dir" && "$CS_BIN" -adopt "linked" </dev/null 2>&1) || rc=$?

        assert_eq 1 "$rc" "adopt refuses a linked $name: $out" || return 1
        assert_eq "Error: $name is a symlink to ../outside-$name, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
            "$out" "the refusal names $name" || return 1
        assert_eq "$before" "$(cksum < "$outside")" "the file $name points at keeps its bytes" || return 1
        assert_not_exists "$project_dir/.cs" "no session records behind a linked $name" || return 1
        assert_not_exists "$CS_SESSIONS_ROOT/linked" "no session link behind a linked $name" || return 1
    done
}

# Records the open would refuse are refused by the re-adopt too, before it
# links a session that can never open: here a queue committed in .cs/private.
test_readopt_refuses_records_the_open_would_refuse() {
    local project_dir="$TEST_TMPDIR/my-project" out rc=0 before
    mkdir -p "$project_dir/.cs/private/queue"
    ( cd "$project_dir" && git init -q && git config user.email jane.roe@example.com \
        && git config user.name "Jane Roe" \
        && printf -- '---\nstatus: active\n---\n# x\n' > .cs/README.md \
        && printf 'armed\n' > .cs/private/queue.state \
        && printf 'a task the repository wrote\n' > .cs/private/queue/0000000001-task \
        && git add -A -f && git commit -q -m "a project with session records" )
    before=$(git -C "$project_dir" rev-parse HEAD)

    out=$(cd "$project_dir" && "$CS_BIN" -adopt new-name --yes </dev/null 2>&1) || rc=$?

    assert_eq 1 "$rc" "the re-adopt refuses: $out" || return 1
    assert_eq "Error: .cs/private/queue.state is tracked in git (per-actor state must stay local). Fix with: git -C \"$(cd "$project_dir" && pwd -P)\" rm -r --cached .cs/private && git commit -m 'stop tracking .cs/private'" \
        "$out" "the refusal names the tracked file" || return 1
    assert_eq "$before" "$(git -C "$project_dir" rev-parse HEAD)" "adopt commits nothing" || return 1
    assert_eq "" "$(git -C "$project_dir" status --porcelain)" "adopt writes nothing" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/new-name" "no session link" || return 1
}

test_adopt_orphaned_records_noninteractive_hints() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local narrative
    narrative=$(ls "$project_dir"/.cs/memory/narrative.*.md | head -1)
    local before
    before=$(cat "$narrative")

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt new-name </dev/null 2>&1); then
        echo "  FAIL: non-interactive re-adopt should fail without a terminal"
        return 1
    fi
    if ! grep -qi "re-run interactively" <<< "$output"; then
        echo "  FAIL: error should hint at re-running interactively: $output"
        return 1
    fi
    assert_dir "$project_dir/.cs" ".cs/ should be untouched" || return 1
    local after
    after=$(cat "$narrative")
    assert_eq "$before" "$after" "narrative file must not change on a refused re-adopt" || return 1
}

test_adopt_orphaned_records_decline_cancels() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local output rc=0
    output=$(cd "$project_dir" && printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: declining re-adopt should exit 0: $output"; return 1; }
    if ! grep -qi "cancelled" <<< "$output"; then
        echo "  FAIL: output should say Cancelled: $output"
        return 1
    fi
    assert_not_exists "$CS_SESSIONS_ROOT/new-name" "no symlink should be created on decline" || return 1
}

# --yes answers the re-adopt question, so a script or an agent with no
# terminal re-adopts orphaned records; it may stand before or after the name.
test_adopt_yes_relinks_orphaned_records_without_a_terminal() {
    local project_dir="$TEST_TMPDIR/my-project" narrative before output rc
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"
    narrative=$(ls "$project_dir"/.cs/memory/narrative.*.md | head -1)
    before=$(cat "$narrative")

    rc=0
    output=$(cd "$project_dir" && "$CS_BIN" -adopt new-name --yes </dev/null 2>&1) || rc=$?
    assert_eq 0 "$rc" "re-adopt with --yes after the name exits 0: $output" || return 1
    assert_symlink "$CS_SESSIONS_ROOT/new-name" "the session link exists" || return 1
    assert_eq "$before" "$(cat "$narrative")" "the records are kept" || return 1

    rm "$CS_SESSIONS_ROOT/new-name"
    rc=0
    output=$(cd "$project_dir" && "$CS_BIN" -adopt -y third-name </dev/null 2>&1) || rc=$?
    assert_eq 0 "$rc" "re-adopt with -y before the name exits 0: $output" || return 1
    assert_symlink "$CS_SESSIONS_ROOT/third-name" "the session link exists" || return 1
}

# Without a terminal and without --yes the re-adopt is refused, and the
# refusal names both ways to answer it.
test_adopt_orphaned_records_noninteractive_names_yes() {
    local project_dir="$TEST_TMPDIR/my-project" output rc=0
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"
    output=$(cd "$project_dir" && "$CS_BIN" -adopt new-name </dev/null 2>&1) || rc=$?
    assert_eq 1 "$rc" "the re-adopt is refused" || return 1
    assert_eq "Error: Directory carries session records (.cs/) but no session link. Re-run interactively or with --yes to re-adopt them as 'new-name', or remove .cs/ to adopt fresh." \
        "$output" "the refusal names --yes" || return 1
}

# A flag adopt does not know is refused, never taken for the session name.
test_adopt_refuses_an_unknown_flag() {
    local project_dir="$TEST_TMPDIR/my-project" output rc=0
    mkdir -p "$project_dir"
    output=$(cd "$project_dir" && "$CS_BIN" -adopt my-session --yse </dev/null 2>&1) || rc=$?
    assert_eq 1 "$rc" "an unknown flag is refused" || return 1
    assert_eq "Error: cs -adopt: unknown option '--yse'. Usage: cs -adopt <name> [--yes]" \
        "$output" "the refusal names the flag" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/my-session" "nothing is adopted" || return 1
}

test_adopt_fails_if_session_name_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    mkdir -p "$CS_SESSIONS_ROOT/my-session"

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt my-session 2>&1); then
        echo "  FAIL: Should have failed for existing session name"
        return 1
    fi

    if ! grep -qi "already exists" <<< "$output"; then
        echo "  FAIL: Error message should mention 'already exists': $output"
        return 1
    fi
}

test_adopt_validates_session_name() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt "bad name!" 2>&1); then
        echo "  FAIL: Should have failed for invalid session name"
        return 1
    fi
}

test_list_shows_adopted_sessions() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    local output
    output=$("$CS_BIN" -list 2>&1)

    if ! grep -q "my-session" <<< "$output"; then
        echo "  FAIL: cs -list should show adopted session 'my-session'"
        echo "  Output: $output"
        return 1
    fi
}

test_remove_adopted_session_removes_symlink_only() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    echo "y" | CS_ASSUME_TTY=1 "$CS_BIN" -remove my-session 2>&1

    assert_not_exists "$CS_SESSIONS_ROOT/my-session" "Symlink should be removed" || return 1
    assert_dir "$project_dir" "Original project should still exist" || return 1
    assert_dir "$project_dir/.cs" ".cs/ should still exist in original project" || return 1
}

test_adopt_preserves_existing_git_repo() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && git init -q && git commit --allow-empty -m "initial" -q)

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    local log_output
    log_output=$(cd "$project_dir" && git log --oneline --format="%s")
    if ! grep -q "initial" <<< "$log_output"; then
        echo "  FAIL: Original git commit 'initial' not found in history"
        echo "  History: $log_output"
        return 1
    fi
}

test_adopt_inits_git_when_none_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_dir "$project_dir/.git" "Git repo should be initialized" || return 1
}

test_adopt_into_git_repo_without_claude_md_stages_bookkeeping() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A && git commit --allow-empty -m "initial" -q)

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    local tracked
    tracked=$(git -C "$project_dir" ls-files .cs/README.md)
    if [[ -z "$tracked" ]]; then
        echo "  FAIL: .cs/README.md should be tracked by git after adopting a repo with no CLAUDE.md"
        return 1
    fi

    local log_output
    log_output=$(git -C "$project_dir" log --oneline --format="%s")
    if ! grep -q "^Adopt as cs session: my-session$" <<< "$log_output"; then
        echo "  FAIL: Adopt commit 'Adopt as cs session: my-session' not found in history"
        echo "  History: $log_output"
        return 1
    fi
}

# Adoption commits inside the user's own project repo. A bare `git commit`
# there commits the whole index, so work they had staged is swept into a commit
# titled "Adopt as cs session" — the same defect the narrative rotation commit
# carried, at the other site where cs commits into a checkout it does not own.
test_adopt_commits_only_its_own_bookkeeping() {
    local project_dir="$TEST_TMPDIR/staged-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A && git commit --allow-empty -m "initial" -q)
    printf 'work in progress\n' > "$project_dir/user-file.txt"
    git -C "$project_dir" add -- user-file.txt

    (cd "$project_dir" && "$CS_BIN" -adopt staged-session)

    local subject swept staged
    # HEAD must BE the adopt commit first: the fixture's initial commit predates
    # user-file.txt, so "HEAD does not contain it" holds even when no adopt
    # commit was made at all.
    subject=$(git -C "$project_dir" log -1 --format=%s)
    assert_eq "Adopt as cs session: staged-session" "$subject" "HEAD must be the adopt commit" || return 1
    swept=$(git -C "$project_dir" show --name-only --format= HEAD | grep -c 'user-file.txt' || true)
    assert_eq "0" "$swept" "the user's staged file must not ride along in the adopt commit" || return 1
    staged=$(git -C "$project_dir" diff --cached --name-only -- user-file.txt)
    assert_eq "user-file.txt" "$staged" "and it must still be staged afterwards" || return 1
}

# ============================================================================
# README.md frontmatter
# ============================================================================

test_readme_has_yaml_frontmatter() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    local first_line
    first_line=$(head -1 "$readme")
    assert_eq "---" "$first_line" "README should start with YAML frontmatter delimiter" || return 1
}

test_readme_frontmatter_has_status() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "status:" "Frontmatter should have status field" || return 1
}

test_readme_frontmatter_has_created_date() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "created: 20" "Frontmatter should have created date" || return 1
}

test_readme_frontmatter_has_tags() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "tags:" "Frontmatter should have tags field" || return 1
}

test_readme_frontmatter_has_aliases() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" 'aliases:' "Frontmatter should have aliases field" || return 1
    assert_file_contains "$readme" 'test-session' "Aliases should contain session name" || return 1
}

test_readme_objective_still_extractable() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    # The sed pattern used by session-start.sh should still work
    local obj
    obj=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$readme" | head -1)
    assert_eq "[Describe what you're trying to accomplish in this session]" "$obj" \
        "Objective should still be extractable with existing sed pattern" || return 1
}

test_adopt_sets_memory_merge_driver() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A)
    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    assert_file_contains "$project_dir/.gitattributes" "MEMORY.md merge=ours" \
        ".gitattributes should mark MEMORY.md merge=ours" || return 1
    local drv
    drv=$(git -C "$project_dir" config merge.ours.driver 2>/dev/null || echo "")
    assert_eq "true" "$drv" "merge.ours.driver should be configured" || return 1
}

test_adopt_gitignores_cs_local() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt my-session)
    assert_file_contains "$project_dir/.gitignore" ".cs/local/" \
        ".gitignore should ignore .cs/local/" || return 1
}

# An encrypted session mounts its volume at .cs/vault-mnt by convention; git
# must ignore it both in the .gitignore cs writes and in a project's own
# .gitignore that adopt appends to.
test_adopt_gitignores_the_vault_mount() {
    local fresh="$TEST_TMPDIR/fresh" owned="$TEST_TMPDIR/owned"
    mkdir -p "$fresh" "$owned"
    (cd "$fresh" && git init -q && "$CS_BIN" -adopt fresh-session >/dev/null 2>&1)
    (cd "$owned" && git init -q && printf 'node_modules/\n' > .gitignore \
        && "$CS_BIN" -adopt owned-session >/dev/null 2>&1)
    git -C "$fresh" check-ignore -q .cs/vault-mnt/memory/narrative.md \
        || { echo "  FAIL: cs's own .gitignore must ignore .cs/vault-mnt/"; return 1; }
    git -C "$owned" check-ignore -q .cs/vault-mnt/memory/narrative.md \
        || { echo "  FAIL: adopt must append .cs/vault-mnt/ to a project .gitignore"; return 1; }
    assert_file_contains "$owned/.gitignore" "node_modules/" "the project's own entry stays" || return 1
}

# .cs/private holds what .cs/local holds for a plain session, so a directory
# of that name stays out of git the same way. Only the directory: an encrypted
# session's .cs/private is a link, and the link itself is committed.
test_adopt_gitignores_a_private_directory_and_not_its_link() {
    local fresh="$TEST_TMPDIR/fresh" owned="$TEST_TMPDIR/owned" linked="$TEST_TMPDIR/linked"
    mkdir -p "$fresh" "$owned" "$linked"
    (cd "$fresh" && git init -q && "$CS_BIN" -adopt fresh-session >/dev/null 2>&1)
    (cd "$owned" && git init -q && printf 'node_modules/\n' > .gitignore \
        && "$CS_BIN" -adopt owned-session >/dev/null 2>&1)
    (cd "$linked" && git init -q && "$CS_BIN" -adopt linked-session >/dev/null 2>&1)
    mkdir -p "$fresh/.cs/private" "$owned/.cs/private"
    git -C "$fresh" check-ignore -q .cs/private/session.log \
        || { echo "  FAIL: cs's own .gitignore must ignore .cs/private/"; return 1; }
    git -C "$owned" check-ignore -q .cs/private/session.log \
        || { echo "  FAIL: adopt must append .cs/private/ to a project .gitignore"; return 1; }
    ln -s vault-mnt/private "$linked/.cs/private"
    if git -C "$linked" check-ignore -q .cs/private; then
        echo "  FAIL: the .cs/private link itself must stay committable"; return 1
    fi
}

# cs_write_atomic stages each write in a temp file beside its destination; one
# left by a killed writer must not reach an autosave snapshot, both under the
# .gitignore cs writes and under a project's own .gitignore that adopt appends to.
test_adopt_gitignores_atomic_write_temps() {
    local fresh="$TEST_TMPDIR/fresh" owned="$TEST_TMPDIR/owned" tmp dir
    mkdir -p "$fresh" "$owned"
    (cd "$fresh" && git init -q && "$CS_BIN" -adopt fresh-session >/dev/null 2>&1)
    (cd "$owned" && git init -q && printf 'node_modules/\n' > .gitignore \
        && "$CS_BIN" -adopt owned-session >/dev/null 2>&1)
    for dir in "$fresh" "$owned"; do
        bash -c 'source "$1"; cs_write_atomic "$2/notes.md" ls -A "$2"' _ \
            "$SCRIPT_DIR/../hooks/cs-shared.sh" "$dir" > /dev/null || { echo "  FAIL: cs_write_atomic failed in $dir"; return 1; }
        tmp=$(grep 'notes\.md\.' "$dir/notes.md" | head -1)
        [ -n "$tmp" ] || { echo "  FAIL: no temp name seen while writing notes.md in $dir"; return 1; }
        : > "$dir/$tmp"
        git -C "$dir" check-ignore -q "$tmp" \
            || { echo "  FAIL: $dir/.gitignore does not ignore the atomic-write temp $tmp"; return 1; }
        if git -C "$dir" check-ignore -q notes.md; then
            echo "  FAIL: the ignore rule also hides the destination notes.md in $dir"; return 1
        fi
    done
}

# ============================================================================
# First launch after adopt
# ============================================================================

UUID_PRIOR="33333333-3333-4333-8333-333333333333"

# A claude stub that records each launch's argv (one line per launch, each
# argument in its own brackets so word boundaries are visible), and fails
# a --resume at once, as claude does for an id that names no conversation.
_adopt_claude_stub() {
    cat > "$TEST_TMPDIR/claude-stub" << SCRIPT
#!/bin/bash
printf '<%s>' "\$@" >> "$TEST_TMPDIR/claude-args"; echo >> "$TEST_TMPDIR/claude-args"
case "\$*" in *--resume*) exit 1 ;; esac
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
}

_adopt_state_id() {  # project_dir
    awk '/^claude_session_id:/ { print $2; exit }' "$1/.cs/local/state" 2>/dev/null
}

_adopt_state_color() {  # project_dir
    awk '/^claude_session_color:/ { print $2; exit }' "$1/.cs/local/state" 2>/dev/null
}

# Write one key into a project's local state, replacing any line it already
# holds; an append would leave two lines and the first-match reader blind to
# the second.
_adopt_write_state() {  # project_dir key value
    local state="$1/.cs/local/state"
    mkdir -p "$1/.cs/local"
    { [ ! -f "$state" ] || awk -v key="$2" 'index($0, key ":") != 1' "$state"; printf '%s: %s\n' "$2" "$3"; } > "$state.tmp" \
        && mv "$state.tmp" "$state"
}

# An adopted directory already exists, so its first open is a reopen. It used to
# ask "Continue previous conversation?" for a conversation that never existed;
# the default answer's --resume then failed and a fallback started fresh.
test_first_launch_after_adopt_starts_fresh_without_asking() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1)
    _adopt_claude_stub

    local output
    output=$("$CS_BIN" probe <<< "" 2>&1) || true

    assert_output_not_contains "$output" "Continue previous conversation" "the first launch offers nothing to resume" || return 1
    assert_output_not_contains "$output" "No previous conversation found" "the first launch never takes the resume-failed fallback" || return 1
    assert_output_contains "$output" "(+ new)" "the card calls the first launch new" || return 1

    local launches recorded
    launches=$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)
    assert_eq "1" "$(printf '%s\n' "$launches" | grep -c .)" "claude launches exactly once" || return 1
    recorded=$(_adopt_state_id "$project_dir")
    [ -n "$recorded" ] || { echo "  FAIL: the launch must record the conversation it starts"; return 1; }
    assert_output_contains "$launches" "<--session-id><$recorded>" "claude starts the recorded conversation" || return 1
    assert_output_contains "$launches" "<--name><probe>" "the conversation is named after the session" || return 1
    assert_output_not_contains "$launches" "<--resume>" "nothing to resume" || return 1
    assert_output_not_contains "$launches" "<--continue>" "cs never passes --continue" || return 1
    if grep -q '"event":"rotated"' "$project_dir/.cs/timeline.jsonl" 2>/dev/null; then
        echo "  FAIL: the first conversation rotates from nothing"; return 1
    fi
}

# A project Claude Code already ran in has a conversation to resume: the first
# open binds the newest one and asks, as before.
test_first_launch_after_adopt_offers_the_projects_newest_conversation() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$project_dir")"
    mkdir -p "$proj"
    printf '{"type":"user","sessionId":"%s"}\n' "$UUID_PRIOR" > "$proj/$UUID_PRIOR.jsonl"
    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1)
    _adopt_claude_stub

    local output
    output=$("$CS_BIN" probe <<< "y" 2>&1) || true
    assert_output_contains "$output" "Continue previous conversation?" "an existing conversation is offered" || return 1
    assert_output_contains "$(head -1 "$TEST_TMPDIR/claude-args")" "<--resume><$UUID_PRIOR>" \
        "the answer resumes the project's conversation" || return 1
}

# The README's Objective line as the picker and the hooks read it.
_adopt_readme_objective() {  # project_dir
    sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$1/.cs/README.md" | head -1
}

# A project Claude Code already ran in carries its own first prompt; adopt
# seeds the Objective from it, with the rules the prompt hook applies to a live
# session: no slash command (recorded as an indented <command-name> block), no
# injected meta record, no tool result, nothing under 8 characters.
test_adopt_seeds_the_objective_from_the_newest_conversations_first_prompt() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$project_dir")"
    mkdir -p "$proj"
    {
        printf '{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: the messages below were generated by the user while running local commands."}}\n'
        printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-name>/model</command-name>\\n            <command-message>model</command-message>"}]}}\n'
        printf '{"type":"user","message":{"role":"user","content":"ok"}}\n'
        printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Which one?"}]}}\n'
        printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Rewrite nothing, this is a tool result"}]}}\n'
        printf '{"type":"user","message":{"role":"user","content":"Rewrite the electron UI shell for the desktop app"}}\n'
        printf '{"type":"user","message":{"role":"user","content":"And then ship it"}}\n'
    } > "$proj/$UUID_PRIOR.jsonl"

    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1) \
        || { echo "  FAIL: adopt should succeed"; return 1; }

    assert_eq "Rewrite the electron UI shell for the desktop app" "$(_adopt_readme_objective "$project_dir")" \
        "the first substantive prompt becomes the Objective" || return 1
}

# Seeding the Objective rewrites the README adopt has just created. One adopt
# creates and seeds it under one umask, so the mode it was created with is the
# umask's (644 here); the check catches a seed that narrows it to a temp file's
# 0600. Keeping a mode the umask would not give is test_local_state's to pin.
test_adopt_objective_seed_keeps_the_readmes_mode() {
    local project_dir="$TEST_TMPDIR/mode-project"
    mkdir -p "$project_dir"
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$project_dir")"
    mkdir -p "$proj"
    printf '{"type":"user","message":{"role":"user","content":"Rewrite the electron UI shell for the desktop app"}}\n' \
        > "$proj/$UUID_PRIOR.jsonl"

    (umask 022; cd "$project_dir" && "$CS_BIN" -adopt modeprobe >/dev/null 2>&1) \
        || { echo "  FAIL: adopt should succeed"; return 1; }

    assert_eq "Rewrite the electron UI shell for the desktop app" "$(_adopt_readme_objective "$project_dir")" \
        "the Objective was seeded" || return 1
    assert_eq "644" "$(_file_mode "$project_dir/.cs/README.md")" "the README keeps the mode it was created with" || return 1
}

test_adopt_keeps_the_placeholder_objective_without_a_conversation() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1) \
        || { echo "  FAIL: adopt should succeed"; return 1; }
    assert_eq "[Describe what you're trying to accomplish in this session]" "$(_adopt_readme_objective "$project_dir")" \
        "no conversation leaves the template placeholder for the first prompt" || return 1
}

# Same clip as the prompt hook: 100 characters and an ellipsis.
test_adopt_clips_a_long_first_prompt() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$project_dir")"
    mkdir -p "$proj"
    local long="Rewrite the electron UI shell for the desktop app so that every window opens on the display it was last seen on"
    [ "${#long}" -eq 111 ] || { echo "  FAIL: fixture prompt is ${#long} characters, not 111"; return 1; }
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$long" > "$proj/$UUID_PRIOR.jsonl"

    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1) \
        || { echo "  FAIL: adopt should succeed"; return 1; }

    assert_eq "Rewrite the electron UI shell for the desktop app so that every window opens on the display it was l…" \
        "$(_adopt_readme_objective "$project_dir")" "the objective is clipped at 100 characters with an ellipsis" || return 1
}

# The conversation the first launch recorded is the one the second resumes.
test_second_launch_after_adopt_asks_and_resumes() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1)
    _adopt_claude_stub
    "$CS_BIN" probe <<< "" >/dev/null 2>&1 || true
    local first
    first=$(_adopt_state_id "$project_dir")
    # Claude writes the transcript once the conversation talks; without it
    # migrate would treat the id as an orphan.
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$project_dir")"
    mkdir -p "$proj"
    printf '{"type":"user","sessionId":"%s"}\n' "$first" > "$proj/$first.jsonl"
    : > "$TEST_TMPDIR/claude-args"

    local output
    output=$("$CS_BIN" probe <<< "y" 2>&1) || true
    assert_output_contains "$output" "Continue previous conversation?" "a bound session still asks" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/claude-args")" "<--resume><$first>" \
        "the answer resumes the conversation the first launch recorded" || return 1
}

# Re-adopting orphaned records keeps the conversation they name; it used to be
# replaced with a fresh id, losing the binding (the transcript stayed on disk).
test_readopt_keeps_the_prior_conversation_binding() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    _adopt_write_state "$project_dir" claude_session_id "$UUID_PRIOR"
    _adopt_write_state "$project_dir" claude_session_color pink
    rm "$CS_SESSIONS_ROOT/old-name"

    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }
    assert_eq "$UUID_PRIOR" "$(_adopt_state_id "$project_dir")" \
        "re-adopt keeps the recorded conversation" || return 1
    assert_eq "pink" "$(_adopt_state_color "$project_dir")" \
        "re-adopt keeps the recorded colour" || return 1

    _adopt_claude_stub
    local output
    output=$("$CS_BIN" new-name <<< "y" 2>&1) || true
    assert_output_contains "$output" "Continue previous conversation?" "the kept binding still asks" || return 1
    assert_output_contains "$(head -1 "$TEST_TMPDIR/claude-args")" "<--resume><$UUID_PRIOR>" \
        "the answer resumes the kept conversation" || return 1
}

# Records whose machine-local state did not travel (a clone of a project that
# tracks .cs/) name no conversation, so they open the way a first adoption does.
test_readopt_without_local_state_starts_fresh_without_asking() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"
    rm -f "$project_dir/.cs/local/state"

    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }
    _adopt_claude_stub
    local output
    output=$("$CS_BIN" new-name <<< "" 2>&1) || true
    assert_output_not_contains "$output" "Continue previous conversation" "records with no binding offer nothing to resume" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/claude-args")" "<--session-id><$(_adopt_state_id "$project_dir")>" \
        "claude starts the recorded conversation" || return 1
}

# A project that commits .cs/ brings its README frontmatter along. Adopt leaves
# the conversation slot empty, so the first open's migration imported the
# README's claude_session_id and the resume prompt passed it to claude unquoted:
# whoever wrote the project chose words on claude's command line.
test_adopt_ignores_a_committed_readme_id_that_is_not_a_uuid() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir/.cs"
    printf -- '---\nstatus: active\nclaude_session_id: --dangerously-skip-permissions --model x\n---\n# Session\n' \
        > "$project_dir/.cs/README.md"
    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt probe >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }
    _adopt_claude_stub

    local output
    output=$("$CS_BIN" probe <<< "" 2>&1) || true

    assert_output_not_contains "$output" "Continue previous conversation" "an id that is not a UUID is never offered for resume" || return 1
    local launches recorded
    launches=$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)
    assert_eq "1" "$(printf '%s\n' "$launches" | grep -c .)" "claude launches exactly once" || return 1
    assert_output_not_contains "$launches" "dangerously-skip-permissions" "the README's words never reach claude's argv" || return 1
    recorded=$(_adopt_state_id "$project_dir")
    [[ "$recorded" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || { echo "  FAIL: the open must record a real conversation id: '$recorded'"; return 1; }
    assert_output_contains "$launches" "<--session-id><$recorded>" "claude starts the recorded conversation" || return 1
}

# Re-adopt puts back the conversation the records name, and only a conversation
# id: words in the slot name nothing to resume.
test_readopt_drops_a_prior_binding_that_is_not_a_uuid() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    _adopt_write_state "$project_dir" claude_session_id "--dangerously-skip-permissions"
    rm "$CS_SESSIONS_ROOT/old-name"

    local output
    output=$(cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name 2>&1) \
        || { echo "  FAIL: re-adopt should succeed: $output"; return 1; }
    assert_eq "" "$(_adopt_state_id "$project_dir")" \
        "re-adopt keeps no id when the prior one is not a UUID" || return 1
    assert_output_contains "$output" "ignoring claude_session_id in .cs/local/state" "re-adopt says what it dropped" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs -adopt tests"
echo "==============="
echo ""

run_test test_adopt_gitignores_cs_local
run_test test_adopt_gitignores_the_vault_mount
run_test test_adopt_gitignores_a_private_directory_and_not_its_link
run_test test_adopt_gitignores_atomic_write_temps
run_test test_adopt_sets_memory_merge_driver

run_test test_adopt_creates_cs_structure
run_test test_adopt_creates_symlink
run_test test_adopt_creates_claude_local_md_when_none_exists
run_test test_adopt_leaves_existing_claude_md_untouched
run_test test_adopt_appends_protocol_to_an_existing_claude_local_md
run_test test_adopt_leaves_a_claude_local_md_with_the_protocol_alone
run_test test_adopt_without_git_keeps_the_existing_gitignore_lines
run_test test_adopt_into_git_repo_keeps_a_last_gitignore_line_without_newline
run_test test_adopt_adds_its_rule_beside_a_commented_or_negated_mention
run_test test_adopt_refuses_the_home_directory
run_test test_adopt_refuses_the_sessions_root_and_its_parents
run_test test_adopt_refuses_a_directory_already_linked
run_test test_adopt_relinks_orphaned_records_interactively
run_test test_readopt_keeps_the_session_log
run_test test_readopt_of_an_encrypted_session_keeps_its_log_in_the_vault
run_test test_readopt_of_an_encrypted_session_with_a_locked_vault_refuses
run_test test_readopt_with_every_vault_link_dangling_refuses_naming_memory
run_test test_adopt_refuses_a_committed_link_it_would_write_through
run_test test_readopt_refuses_records_the_open_would_refuse
run_test test_adopt_orphaned_records_noninteractive_hints
run_test test_adopt_orphaned_records_decline_cancels
run_test test_adopt_yes_relinks_orphaned_records_without_a_terminal
run_test test_adopt_orphaned_records_noninteractive_names_yes
run_test test_adopt_refuses_an_unknown_flag
run_test test_adopt_fails_if_session_name_exists
run_test test_adopt_validates_session_name
run_test test_list_shows_adopted_sessions
run_test test_remove_adopted_session_removes_symlink_only
run_test test_adopt_preserves_existing_git_repo
run_test test_adopt_inits_git_when_none_exists
run_test test_adopt_into_git_repo_without_claude_md_stages_bookkeeping
run_test test_adopt_commits_only_its_own_bookkeeping

# First launch after adopt
run_test test_first_launch_after_adopt_starts_fresh_without_asking
run_test test_first_launch_after_adopt_offers_the_projects_newest_conversation
run_test test_second_launch_after_adopt_asks_and_resumes
run_test test_adopt_seeds_the_objective_from_the_newest_conversations_first_prompt
run_test test_adopt_objective_seed_keeps_the_readmes_mode
run_test test_adopt_keeps_the_placeholder_objective_without_a_conversation
run_test test_adopt_clips_a_long_first_prompt
run_test test_readopt_keeps_the_prior_conversation_binding
run_test test_readopt_without_local_state_starts_fresh_without_asking
run_test test_adopt_ignores_a_committed_readme_id_that_is_not_a_uuid
run_test test_readopt_drops_a_prior_binding_that_is_not_a_uuid

# README frontmatter
run_test test_readme_has_yaml_frontmatter
run_test test_readme_frontmatter_has_status
run_test test_readme_frontmatter_has_created_date
run_test test_readme_frontmatter_has_tags
run_test test_readme_frontmatter_has_aliases
run_test test_readme_objective_still_extractable

report_results
