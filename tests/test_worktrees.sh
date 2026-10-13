#!/usr/bin/env bash
# ABOUTME: Tests for worktree-backed parallel task sessions
# ABOUTME: Covers name parsing, creation, launch env, merge-back, removal, doctor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"


# --- Name parsing (via cs CLI behavior) ---

test_worktree_name_rejected_without_base() {
    local output
    output=$("$CS_BIN" "@fix-auth" 2>&1 || true)
    assert_output_contains "$output" "Session name" "empty base half must be rejected" || return 1
}

test_worktree_name_rejects_bad_task_half() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj@fix/auth" 2>&1 || true)
    assert_output_contains "$output" "feature name" "slash in feature half must be rejected" || return 1
}

# Both halves refuse a leading dot: the base half is a session name, and the
# feature half becomes the branch cs/<feature>, a ref git refuses.
test_worktree_name_rejects_a_leading_dot_in_either_half() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj@.hidden" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "feature name cannot start with a dot" "a leading dot in the feature half is refused" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@.hidden" "no worktree is created for it" || return 1
    output=$("$CS_BIN" ".myproj@fix" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "Session name cannot start with a dot" "a leading dot in the base half is refused" || return 1
}

test_plain_names_still_work() {
    local output
    output=$("$CS_BIN" "-list" 2>&1)
    assert_output_not_contains "$output" "Unknown" "plain subcommands unaffected" || return 1
}

# Launch cs against a session/worktree with stdin closed; the echo stub
# stands in for claude so cs exits after setup.
cs_launch() {
    "$CS_BIN" "$1" < /dev/null > /dev/null 2>&1 || true
}

# Land the feature tip into the base through the integrate entry with a
# trivial gate, the way /finish does before it retires; prints the sha.
land_feature() {  # base task
    local wt="$CS_SESSIONS_ROOT/$1@$2" sha
    sha=$(git -C "$wt" rev-parse HEAD) || return 1
    "$CS_BIN" "$1" -integrate-feature "$2" "$sha" -- true >/dev/null 2>&1 || return 1
    printf '%s\n' "$sha"
}

# Field positions in a -features --porcelain record.
_feat_field() {  # line field_number
    printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

# Build a ps seam for the ownership walk. Process inspection may be restricted
# in a test sandbox; production uses BSD ps, while these integration tests
# inject the one parent edge relevant to the scenario.
fixed_parent_ps_stub() {
    local parent="$1" stub="$TEST_TMPDIR/parent-ps-stub"
    cat > "$stub" << STUB
#!/usr/bin/env bash
printf '%s\n' "$parent"
STUB
    chmod +x "$stub"
    echo "$stub"
}

test_worktree_create_tracked_mode() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    assert_dir "$wt" "worktree dir should exist" || return 1
    assert_file_exists "$wt/.git" "linked worktree .git should be a file" || return 1
    assert_eq "cs/fix-auth" "$(git -C "$wt" branch --show-current)" "worktree on task branch" || return 1
    assert_file_exists "$wt/.cs/README.md" "tracked .cs rides the checkout" || return 1
    assert_file_contains "$wt/.cs/local/state" "task_branch: cs/fix-auth" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_mode: tracked" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_base: myproj" || return 1
    # Fresh identity, not the base's
    local base_uuid wt_uuid
    base_uuid=$(awk -F': ' '/^claude_session_id/{print $2}' "$base_dir/.cs/local/state")
    wt_uuid=$(awk -F': ' '/^claude_session_id/{print $2}' "$wt/.cs/local/state")
    [ "$base_uuid" != "$wt_uuid" ] || { echo "  FAIL: worktree must get its own UUID"; return 1; }
}

# A worktree of an encrypted session carries the same vault links; opening it
# while the vault is locked refuses by name, as the base does, before
# anything writes through the dangling links.
test_worktree_open_refuses_a_locked_vault() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" out rc=0
    rm -rf "$wt/.cs/memory"
    ln -s "$TEST_TMPDIR/unmounted/memory" "$wt/.cs/memory"
    _make_launch_sentinel
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open refuses" || return 1
    assert_eq "Error: myproj@fix-auth: .cs/memory points at $TEST_TMPDIR/unmounted/memory, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "names the dangling link" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}

# Creating a worktree checks out the base's committed vault links; with the
# vault locked they dangle, and setup would mkdir through them halfway
# through registering the worktree. Refuse before git sees anything, and
# refuse the encrypted base outright, since mounting it would only lead there.
test_worktree_create_refuses_a_locked_base_vault() {
    local base_dir out rc=0
    base_dir=$(create_test_session_with_git "myproj")
    rm -rf "$base_dir/.cs/memory"
    ln -s "$TEST_TMPDIR/unmounted/memory" "$base_dir/.cs/memory"
    git -C "$base_dir" add -A .cs/memory
    git -C "$base_dir" -c user.email=t@example.com -c user.name=t commit -qm "vault link"
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the create refuses" || return 1
    assert_eq "Error: myproj: .cs/memory links into encrypted storage, and feature worktrees of an encrypted session are not supported yet." \
        "$out" "refuses the encrypted base instead of asking to mount it" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "no task branch on refusal" || return 1
}

# cs -encrypt links the four names relative to .cs/ ("vault-mnt/<name>"), so a
# checkout of them resolves inside the worktree, where nothing is mounted; and
# a base whose .cs/ is ignored gives the worktree plaintext files of its own.
# Until worktrees of an encrypted session are designed, both refuse by name.
_encrypt_base_links() {  # base_dir; links shaped as cs -encrypt writes them, vault mounted
    local base="$1" sub
    rm -rf "$base/.cs/memory"
    for sub in memory plans claude-config private; do
        mkdir -p "$base/.cs/vault-mnt/$sub"
        ln -s "vault-mnt/$sub" "$base/.cs/$sub"
    done
    echo sealed > "$base/.cs/vault-mnt/memory/narrative.md"
}

test_worktree_create_refuses_an_encrypted_base() {
    local base_dir out rc=0
    base_dir=$(create_test_session_with_git "myproj")
    _encrypt_base_links "$base_dir"
    git -C "$base_dir" add -A .cs
    git -C "$base_dir" -c user.email=t@example.com -c user.name=t commit -qm "vault links"
    _make_launch_sentinel
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the create refuses" || return 1
    assert_eq "Error: myproj: .cs/memory links into encrypted storage, and feature worktrees of an encrypted session are not supported yet." \
        "$out" "names the base's vault link" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "no task branch on refusal" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}

test_worktree_create_refuses_an_encrypted_base_with_untracked_links() {
    local base_dir out rc=0
    base_dir=$(create_test_session_with_git "myproj")
    _encrypt_base_links "$base_dir"
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the create refuses" || return 1
    assert_eq "Error: myproj: .cs/memory links into encrypted storage, and feature worktrees of an encrypted session are not supported yet." \
        "$out" "names the base's vault link" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
}

test_worktree_open_refuses_once_its_base_is_encrypted() {
    local base_dir out rc=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    _encrypt_base_links "$base_dir"
    _make_launch_sentinel
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open refuses" || return 1
    assert_eq "Error: myproj: .cs/memory links into encrypted storage, and feature worktrees of an encrypted session are not supported yet." \
        "$out" "names the base's vault link" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}

test_worktree_create_refuses_dirty_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "change" >> "$base_dir/CLAUDE.md"
    local output
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty base must refuse" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
}

test_worktree_create_reuses_existing_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    git -C "$base_dir" branch cs/fix-auth
    cs_launch "myproj@fix-auth"
    assert_eq "cs/fix-auth" "$(git -C "$CS_SESSIONS_ROOT/myproj@fix-auth" branch --show-current)" \
        "existing branch is reused, not errored on" || return 1
}

test_worktree_create_ignored_mode_bootstraps_cs() {
    # A repo whose .gitignore excludes .cs/ entirely (like the cs dev repo)
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_dir "$wt/.cs/memory" "ignored mode bootstraps .cs skeleton" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "# Project CLAUDE.md" "$(cat "$wt/CLAUDE.md")" \
        "bootstrap must not overwrite the project's CLAUDE.md" || return 1
}

test_ignored_mode_worktree_starts_with_nothing_untracked() {
    # Ignored mode only means .cs is not TRACKED — it does not mean the project
    # ignores it. A project that never gitignored .cs/ gets a worktree whose .cs
    # skeleton cs itself just wrote, untracked, which the merge preflight then
    # refuses. cs must not manufacture its own merge blocker.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    # No .gitignore entry for .cs/ — this is the freya shape.
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    assert_eq "" "$others" "a fresh ignored-mode worktree must have nothing untracked" || return 1
}

test_ignored_mode_worktree_retires_without_a_manual_exclude() {
    # The end the user actually hits: create, commit work, /finish lands it,
    # then retires the worktree.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "feature" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "task work")
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_output_not_contains "$output" "untracked files that removal would destroy" \
        "cs must not refuse over the .cs skeleton it wrote itself" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

test_retire_tolerates_a_worktree_predating_the_cs_exclude() {
    # A worktree created before cs excluded its own bookkeeping still has .cs/
    # untracked, and upgrading cs must unblock it without the user editing
    # info/exclude by hand. Model that by stripping the entry after creation.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"

    local exclude
    exclude=$( (cd "$wt" && git rev-parse --git-path info/exclude) 2>/dev/null )
    case "$exclude" in /*|[A-Za-z]:[\\/]*) : ;; *) exclude="$wt/$exclude" ;; esac
    grep -v -e '^\.cs/$' -e '^\.claude/settings\.local\.json$' "$exclude" > "$exclude.tmp" 2>/dev/null || true
    mv "$exclude.tmp" "$exclude"
    # Fixture sanity: without the entry the skeleton really is untracked again,
    # so this test exercises the preflight rather than the exclude.
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    case "$others" in
        *.cs/*) : ;;
        *) echo "  FAIL: fixture did not reproduce the untracked .cs skeleton"; return 1 ;;
    esac

    echo "feature" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "task work")
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_output_not_contains "$output" "untracked files that removal would destroy" \
        "an older worktree's .cs skeleton must not block retirement" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

test_retire_still_refuses_real_untracked_work() {
    # The carve-out is scoped to cs's own bookkeeping. A file the user would
    # lose must still stop the removal — that is what the gate is for.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "unsaved" > "$wt/notes.txt"
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_output_contains "$output" "untracked files that removal would destroy" \
        "real untracked work must still refuse" || return 1
    assert_output_contains "$output" "notes.txt" "the refusal names the file at risk" || return 1
    assert_dir "$wt" "the worktree survives a refusal" || return 1
}

# An ignored file is as lost as an untracked one when the worktree goes: git
# keeps no copy of either. Retire refuses over it and names it, while cs's own
# ignored bookkeeping and Finder's .DS_Store still pass.
test_retire_refuses_ignored_work() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    printf '*.log\n.DS_Store\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md .gitignore && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "unsaved" > "$wt/build.log"
    : > "$wt/.DS_Store"
    local sha output status=0
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retire refuses: $output" || return 1
    assert_output_contains "$output" "untracked files that removal would destroy" \
        "ignored work refuses like untracked work" || return 1
    assert_output_contains "$output" "build.log" "the refusal names the ignored file" || return 1
    assert_output_not_contains "$output" ".DS_Store" "Finder metadata is not work" || return 1
    assert_file_exists "$wt/build.log" "the ignored file survives the refusal" || return 1
    # Positive control: with the ignored file gone, the same worktree retires.
    rm "$wt/build.log"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds without ignored work: $output" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

test_worktree_of_worktree_refused() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj@fix-auth@deeper" 2>&1 || true)
    assert_output_contains "$output" "feature name" "second @ lands in the feature half and is rejected" || return 1
}

test_worktree_create_succeeds_with_untracked_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "stray" > "$base_dir/stray.txt"   # untracked, must not corrupt the captured path
    local output status=0
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || status=$?
    assert_eq "0" "$status" "cs must exit 0 despite the untracked-files warning" || return 1
    assert_output_not_contains "$output" "No such file" \
        "captured worktree path must not be corrupted by the warning" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree created" || return 1
}

test_worktree_reopen_preserves_project_claude_md() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    cs_launch "proj@task1"   # reopen — the path that used to run migrate_session
    assert_eq "# Project CLAUDE.md" "$(cat "$CS_SESSIONS_ROOT/proj@task1/CLAUDE.md")" \
        "reopen must not rewrite the project's CLAUDE.md" || return 1
}

# A feature reopen skips migrate_session, so it carries its own refusal of a
# linked .cs/local: the checkout would otherwise read and migrate state
# behind the link.
test_worktree_reopen_refuses_a_symlinked_cs_local() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    mv "$wt/.cs/local" "$wt/payload"
    ln -s ../payload "$wt/.cs/local"

    local out rc=0
    out=$("$CS_BIN" "myproj@fix-auth" <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/local is a symlink to ../payload (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen." \
        "$out" "the reopen should refuse the link before reading state behind it" || return 1
}

# Feature creation writes the worktree's state before the caller sees the
# directory, so the refusal has to sit inside create_worktree_session, right
# after the checkout: a base whose history commits `.cs/local` as a link
# would otherwise have its first state writes land behind the link.
test_worktree_creation_refuses_a_committed_cs_local_link() {
    create_test_session_with_git "myproj" > /dev/null
    local base="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$base/payload" && touch "$base/payload/keep"
    rm -rf "$base/.cs/local"
    ln -s ../payload "$base/.cs/local"
    git -C "$base" add -A
    git -C "$base" commit -q -m "ship .cs/local as a link"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"

    local out rc=0
    out=$("$CS_BIN" "myproj@fix-auth" <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_output_contains "$out" "Error: .cs/local is a symlink to ../payload (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen." \
        "creation should refuse the link right after the checkout" || return 1
    assert_not_exists "$wt/payload/state" "no state may be written behind the link" || return 1
}

test_worktree_launch_exports_base_identity() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create first
    local stub env_out _try
    stub=$(_make_env_stub)
    # The reopen launch execs the stub, which prints its env. On a loaded runner
    # the launch can occasionally race the create launch's lock/PID cleanup and
    # take a cancel path, capturing empty output. Retry until the exported
    # identity appears, so the assertions test the identity, not runner load; a
    # genuine failure to export still fails all attempts.
    for _try in 1 2 3 4 5; do
        env_out=$(CLAUDE_CODE_BIN="$stub" "$CS_BIN" "myproj@fix-auth" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=myproj@fix-auth"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=myproj@fix-auth" "display identity is the task name" || return 1
    assert_output_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj@fix-auth" "a feature keeps its own task list, not the base's" || return 1
    assert_output_contains "$env_out" "CS_SECRETS_SESSION=myproj" "secrets stay keyed to the base" || return 1
}

# Claude Code v2.1.233+ leaves the Task tools out on Opus 4.8, Sonnet 5 and
# Fable 5 unless the session opts in. cs's rotation wake, the walk-away drain
# and the rotate skill all address the native task list, so a launch has to
# opt in or those instructions land on a conversation with no list to keep.
# CS_NO_TASK_TOOLS=1 leaves the choice to Claude Code for users who want the
# context back.
# Both launches run under `env -u CLAUDE_CODE_ENABLE_TODO_TOOLS`: a cs session
# exports it, so a suite run from inside one inherits it and the opt-out arm
# reads the developer's environment instead of what cs decided. CI never sets
# it, so the failure appears only on a developer machine.
test_launch_enables_the_task_tools_unless_opted_out() {
    local stub env_out
    stub=$(_make_env_stub)
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_TODO_TOOLS CLAUDE_CODE_BIN="$stub" "$CS_BIN" "tasktools" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=tasktools"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_CODE_ENABLE_TODO_TOOLS=1" "a cs launch opts the session into the Task tools" || return 1
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_TODO_TOOLS CS_NO_TASK_TOOLS=1 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "tasktools-off" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=tasktools-off"*) break ;; esac
    done
    assert_output_not_contains "$env_out" "CLAUDE_CODE_ENABLE_TODO_TOOLS=" "CS_NO_TASK_TOOLS leaves the decision to Claude Code" || return 1
}

# Claude Code loads function-hooks plugins, cs's rotate mod among them, only
# behind CLAUDE_CODE_ENABLE_FUNCTION_HOOKS. A cs launch exports it so the mod
# the installer deployed actually runs; CS_NO_FUNCTION_HOOKS=1 withholds it,
# and a value the shell already set (0 to keep them off) is kept, not forced.
# `env -u` for the same reason as the Task tools test above.
test_launch_enables_function_hooks_unless_opted_out() {
    local stub env_out
    stub=$(_make_env_stub)
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_FUNCTION_HOOKS -u CS_NO_FUNCTION_HOOKS CLAUDE_CODE_BIN="$stub" "$CS_BIN" "fnhooks" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=fnhooks"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1" "a cs launch turns function hooks on" || return 1
    # The negative arms first prove the launch happened: an empty capture would
    # satisfy "not contains" without testing anything.
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_FUNCTION_HOOKS CS_NO_FUNCTION_HOOKS=1 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "fnhooks-off" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=fnhooks-off"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=fnhooks-off" "the opt-out launch reached claude" || return 1
    assert_output_not_contains "$env_out" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=" "CS_NO_FUNCTION_HOOKS withholds the flag" || return 1
    for _try in 1 2 3 4 5; do
        env_out=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CS_NO_FUNCTION_HOOKS=1 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "fnhooks-inherited" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=fnhooks-inherited"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=fnhooks-inherited" "the inherited-flag launch reached claude" || return 1
    assert_output_not_contains "$env_out" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=" "CS_NO_FUNCTION_HOOKS also drops a flag the shell inherited" || return 1
    for _try in 1 2 3 4 5; do
        env_out=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "fnhooks-kept" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=fnhooks-kept"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0" "a value the shell set is kept" || return 1
}

test_retire_after_integrate_removes_worktree_and_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Simulate task work: code + session records, committed on the branch
    echo "fix" > "$wt/auth.txt"
    echo '{"ts":"2026-07-02T00:00:00Z","event":"task"}' >> "$wt/.cs/timeline.jsonl"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local sha output
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1)
    assert_eq "retired fix-auth $sha" "$output" "the entry's own summary line" || return 1
    assert_file_exists "$base_dir/auth.txt" "code landed by the integrate" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" '"event":"task"' "timeline union-merged" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "branch deleted" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "worktree-retired" "retirement recorded" || return 1
}

test_retire_refuses_dirty_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "uncommitted" >> "$wt/CLAUDE.md"
    local sha output
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty worktree refused" || return 1
    assert_dir "$wt" "worktree preserved on refusal" || return 1
}

# git worktree remove --force recurses into a mount, so a volume mounted inside
# the feature worktree would lose what it holds.
test_retire_refuses_a_volume_mounted_inside_the_worktree() {
    local wt sha stub="$TEST_TMPDIR/retire-mount" output status=0
    create_test_session_with_git "myproj" >/dev/null
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir -p "$wt/.cs/vault-mnt"
    echo sealed > "$wt/.cs/vault-mnt/notes.md"
    _stub_mount_table "$stub" "/dev/disk9s1 on $wt/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled)" || return 1
    output=$(PATH="$stub:$PATH" "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retirement refuses" || return 1
    assert_eq "Error: The feature is landed, but its worktree has a volume mounted inside it at $wt/.cs/vault-mnt, and removing the worktree would delete what the volume holds. Unmount it, then run /finish fix-auth here again." \
        "$output" "names the mount" || return 1
    assert_file_exists "$wt/.cs/vault-mnt/notes.md" "the volume's contents survive" || return 1
}

test_retire_refuses_when_the_mount_table_cannot_be_read() {
    local wt sha d="$TEST_TMPDIR/retire-mount-broken" output status=0
    create_test_session_with_git "myproj" >/dev/null
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    _stub_mount_unreadable "$d" || return 1
    output=$(PATH="$d:$PATH" "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retirement refuses" || return 1
    # The stub's own stderr line comes first; the refusal is the last line.
    assert_eq "Error: cs could not read the mount table, so it cannot tell whether a volume is mounted inside $wt; refusing to remove the worktree." \
        "$(printf '%s\n' "$output" | tail -n 1)" "says why" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_refuses_a_live_feature_session_and_says_what_to_do() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha output
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1 || true)
    assert_output_contains "$output" "the 'myproj@fix-auth' conversation is open in it (PID $$)" \
        "the refusal names the open conversation" || return 1
    assert_output_contains "$output" "Close that session yourself (/exit there), then run /finish fix-auth here again" \
        "and tells the user, plainly, what to do" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    rm -f "$wt/.cs/session.lock"
}

test_retire_from_live_base_session_succeeds() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="11111111-1111-4111-8111-111111111111"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    # The lock owner is this test shell, an ancestor of the cs subprocess just
    # like a cs launcher/Claude process is an ancestor of an in-session Bash tool.
    echo "$$" > "$base_dir/.cs/session.lock"
    local output status=0 ps_stub
    ps_stub=$(fixed_parent_ps_stub "$$")
    output=$(CLAUDE_SESSION_NAME="myproj" CS_PS_BIN="$ps_stub" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    assert_eq "0" "$status" "the live base session should be allowed to retire: $output" || return 1
    assert_not_exists "$wt" "retired worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "retired branch deleted" || return 1
}

test_retire_from_inside_the_feature_session_refuses() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local wt_uuid
    wt_uuid=$(awk -F': ' '/^claude_session_id/{print $2; exit}' "$wt/.cs/local/state")
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    echo "$$" > "$wt/.cs/session.lock"
    local output status=0
    output=$(cd "$wt" && CLAUDE_SESSION_NAME="myproj@fix-auth" \
        CS_CLAUDE_SESSION_ID="$wt_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "  FAIL: a feature session must not remove its own live worktree"; return 1; }
    assert_output_contains "$output" "This is the 'myproj@fix-auth' conversation itself" \
        "self-retire refusal identifies the dangerous scenario" || return 1
    assert_output_contains "$output" "Close this session, then run /finish fix-auth in 'myproj'" \
        "self-retire refusal gives the hand-off" || return 1
    assert_dir "$wt" "self-retire refusal preserves the worktree" || return 1
}

test_retire_foreign_live_base_lock_still_refuses() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="22222222-2222-4222-8222-222222222222"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$base_dir/.cs/session.lock"

    local output status=0
    output=$(CLAUDE_SESSION_NAME="foreign" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "  FAIL: a foreign live base lock must refuse"; return 1; }
    assert_output_contains "$output" "is open elsewhere" "foreign live lock keeps the hard refusal" || return 1
    assert_dir "$wt" "foreign-lock refusal preserves the worktree" || return 1
}

test_retire_reused_live_pid_is_not_treated_as_own_lock() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="33333333-3333-4333-8333-333333333333"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    # A stale lock can point at a PID later reused by an unrelated live process.
    # The matching name and UUID are insufficient: that PID must own this cs call.
    sleep 30 &
    local reused_pid=$!
    echo "$reused_pid" > "$base_dir/.cs/session.lock"
    local output status=0 ps_stub
    ps_stub=$(fixed_parent_ps_stub "1")
    output=$(CLAUDE_SESSION_NAME="myproj" CS_PS_BIN="$ps_stub" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    kill "$reused_pid" 2>/dev/null || true
    wait "$reused_pid" 2>/dev/null || true

    [ "$status" -ne 0 ] || { echo "  FAIL: a reused foreign PID must not be exempted"; return 1; }
    assert_output_contains "$output" "is open elsewhere" "reused live PID keeps the hard refusal" || return 1
    assert_dir "$wt" "reused-PID refusal preserves the worktree" || return 1
}

test_retire_refuses_an_unintegrated_feature() {
    # Retirement never merges: a commit the base lacks is a refusal that
    # names /finish, whatever the old merge verb would have done with it.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "an unintegrated feature is refused" || return 1
    assert_output_contains "$output" "is not integrated into myproj; run /finish fix-auth before retiring" \
        "the refusal names /finish" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_file_not_exists "$base_dir/shared.txt" "nothing was merged" || return 1
    assert_eq "cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth | tr -d ' *+')" "branch kept" || return 1
}

test_retire_refuses_commits_after_the_captured_one() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "one" > "$wt/one.txt"
    (cd "$wt" && git add one.txt && git commit -q -m one)
    local sha output status=0
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "two" > "$wt/two.txt"
    (cd "$wt" && git add two.txt && git commit -q -m two)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a tip the base lacks is refused" || return 1
    assert_output_contains "$output" "1 commit(s) on cs/fix-auth after $sha are not integrated; run /finish fix-auth again" \
        "the refusal counts the commits and names /finish" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_force_takes_a_squash_landed_branch() {
    # A PR squash-merged on GitHub leaves cs/<task> a non-ancestor of the base
    # forever; the skill passes --force on that evidence, and the branch goes
    # with -D since -d would refuse it.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "squashed elsewhere" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "0" "$status" "force retires: $output" || return 1
    assert_eq "retired fix-auth $sha" "$output" "the summary line" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "unmerged branch deleted under force" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "force never merges" || return 1
}

test_retire_force_refuses_commits_after_the_captured_one() {
    # --force skips only "is the captured commit in the base": a commit made
    # on the branch after the PR's capture is work the PR never carried, and
    # deleting the branch would lose it.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "in the pr" > "$wt/a.txt"
    (cd "$wt" && git add a.txt && git commit -q -m "A")
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "after the pr" > "$wt/b.txt"
    (cd "$wt" && git add b.txt && git commit -q -m "B")
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "1" "$status" "force refuses a tip past the captured commit" || return 1
    assert_output_contains "$output" "1 commit(s) on cs/fix-auth after $sha are not integrated; run /finish fix-auth again" \
        "the refusal counts the unlanded commits" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_eq "+cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth | tr -d ' ')" "branch kept" || return 1
}

test_retire_fuses_nothing_when_removal_fails_and_retry_fuses_once() {
    # Records are fused only once the worktree is gone: a removal that fails
    # (here: a locked worktree) leaves the base's records untouched and the
    # worktree's own in place, so the retry after unlocking fuses exactly once.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    printf '{"event":"base-seed"}\n' > "$base_dir/.cs/timeline.jsonl"
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '{"event":"from-task"}\n' > "$wt/.cs/timeline.jsonl"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    git -C "$base_dir" worktree lock "$wt"
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a locked worktree cannot be removed: $output" || return 1
    assert_dir "$wt" "worktree survives" || return 1
    assert_file_exists "$wt/.cs/timeline.jsonl" "the worktree's records are back where they were" || return 1
    assert_eq "1" "$(grep -c "base-seed" "$base_dir/.cs/timeline.jsonl")" "base records untouched" || return 1
    assert_file_not_contains "$base_dir/.cs/timeline.jsonl" "from-task" "nothing fused on a failed removal" || return 1
    git -C "$base_dir" worktree unlock "$wt"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retry retires: $output" || return 1
    assert_not_exists "$wt" "worktree removed on retry" || return 1
    assert_eq "1" "$(grep -c "from-task" "$base_dir/.cs/timeline.jsonl")" "fused exactly once" || return 1
}

# An encrypted base keeps its log behind .cs/private, and a locked vault
# cannot take the worktree's. Retire refuses before anything moves: the
# worktree stays whole with its records, nothing is stranded in a .retire-*
# staging directory, and the retry once the vault is mounted fuses once.
test_retire_with_a_locked_base_vault_leaves_the_worktree_whole() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '{"event":"from-task"}\n' > "$wt/.cs/timeline.jsonl"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    ln -s "$TEST_TMPDIR/vault-mnt/private" "$base_dir/.cs/private"
    _mark_hand_made_vault "$base_dir"

    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?

    assert_eq "1" "$status" "retire refuses while the base vault is locked: $output" || return 1
    assert_output_contains "$output" "$base_dir/.cs/private is locked" "the refusal names the vault" || return 1
    assert_dir "$wt" "the worktree survives" || return 1
    assert_file_exists "$wt/.cs/timeline.jsonl" "the worktree keeps its records in place" || return 1
    assert_file_not_contains "$base_dir/.cs/timeline.jsonl" "from-task" "nothing is fused" || return 1
    local stranded
    stranded=$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name '.retire-*')
    assert_eq "" "$stranded" "no records are stranded in a staging directory" || return 1

    mkdir -p "$TEST_TMPDIR/vault-mnt/private"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retry with the vault mounted retires: $output" || return 1
    assert_not_exists "$wt" "worktree removed on retry" || return 1
    assert_eq "1" "$(grep -c "from-task" "$base_dir/.cs/timeline.jsonl")" "fused exactly once" || return 1
}

# A fuse write that fails after the worktree is gone (a full disk, an
# unwritable base) must not count as fused: the staging directory holding
# the only copy of the records stays, and retire names it and exits 1. The
# base's memory directory is made read-only so the narrative copy fails.
test_retire_keeps_the_records_when_a_fuse_write_fails() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf 'only copy of the task notes\n' > "$wt/.cs/memory/narrative.example.md"
    local sha output status=0 aside
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    chmod 555 "$base_dir/.cs/memory"

    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    chmod 755 "$base_dir/.cs/memory"

    assert_eq "1" "$status" "retire reports the failed fuse: $output" || return 1
    assert_output_contains "$output" "its session records could not be fused" "the error says the fuse failed" || return 1
    aside=$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name '.retire-*' | head -1)
    assert_file_exists "$aside/cs/memory/narrative.example.md" "the staged records survive the failed fuse" || return 1
}

test_retire_refusal_for_an_open_session_comes_after_the_landing_check() {
    # An open conversation on an UNLANDED feature must hear "/finish first",
    # not "the feature is landed, close the session".
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "work" > "$wt/w.txt"
    (cd "$wt" && git add w.txt && git commit -q -m work)
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "$$" > "$wt/.cs/session.lock"
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    rm -f "$wt/.cs/session.lock"
    assert_eq "1" "$status" "refused" || return 1
    assert_output_contains "$output" "is not integrated into myproj; run /finish fix-auth before retiring" "the landing check speaks first" || return 1
    assert_output_not_contains "$output" "The feature is landed" "no false reassurance" || return 1
}

test_retire_force_still_refuses_untracked_work() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "precious" > "$wt/never-added.txt"
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "1" "$status" "force skips the ancestry check only" || return 1
    assert_output_contains "$output" "never-added.txt" "the refusal names the path" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_rejects_traversal_task_name() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    # A task argument with path separators would build an escaping worktree
    # path; the entry must reject it with the feature-name charset error before
    # touching the filesystem, matching the launch path's validation.
    local output status=0
    output=$("$CS_BIN" "myproj" -retire-feature "e/../../x" deadbeef 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a task name with path separators must be rejected"; return 1; }
    assert_output_contains "$output" "alphanumeric" "rejects a traversal task name with the charset error" || return 1
}

test_retire_is_hidden_from_completion_and_unknown_command_text() {
    grep -q '^            -retire-feature) # hidden' "$SCRIPT_DIR/../lib/99-main.sh" \
        || { echo "  FAIL: the arm must carry '# hidden' on its own line for test_completions"; return 1; }
    assert_file_not_contains "$SCRIPT_DIR/../lib/99-main.sh" 'Unknown session command.*-retire-feature' \
        "the unknown-command string must not advertise the entry" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" 'retire-feature' "help never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" 'retire-feature' "zsh completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" 'retire-feature' "bash completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../README.md" 'retire-feature' "README never lists it" || return 1
}

test_merge_verb_is_gone() {
    local base_dir output status=0
    base_dir=$(create_test_session_with_git "myproj")
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1) || status=$?
    assert_eq "1" "$status" "--merge is not a session command any more" || return 1
    assert_output_contains "$output" "Unknown session command: --merge" "and says so" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" '[-]-merge' "help does not list it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" '[-]-merge' "zsh completion does not list it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" '[-]-merge' "bash completion does not list it" || return 1
}

# With core.autocrlf enabled, a CRLF-rewritten .gitignore
# carries a trailing \r on every pattern and matches nothing, so files cs means
# to ignore surface as untracked — which then blocks retirement.
test_session_repo_pins_autocrlf_off() {
    local cfg="$TEST_TMPDIR/gitconfig-autocrlf"
    printf '[core]\n\tautocrlf = true\n' > "$cfg"
    GIT_CONFIG_GLOBAL="$cfg" "$CS_BIN" acrlf <<< "" >/dev/null 2>&1
    local repo="$CS_SESSIONS_ROOT/acrlf"
    [ -d "$repo/.git" ] || { echo "  FAIL: session repo not created"; return 1; }
    # --local, not the effective value: a global autocrlf=false on the dev box
    # would otherwise satisfy this without cs having written anything.
    assert_eq "false" "$(git -C "$repo" config --local --get core.autocrlf 2>/dev/null)" \
        "a session repo must pin core.autocrlf off in its own config" || return 1
}

# cs records the protocol file in the worktree's info/exclude, at whatever path
# git reports for it. A worktree's git-path is absolute; mis-reading that as
# relative sends the entry to a nonsense path,
# leaves CLAUDE.local.md untracked, and blocks retirement.
test_worktree_excludes_protocol_file() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    [ -f "$wt/CLAUDE.local.md" ] || { echo "  FAIL: protocol file not written to the worktree"; return 1; }
    (cd "$wt" && git check-ignore -q CLAUDE.local.md) \
        || { echo "  FAIL: CLAUDE.local.md is not ignored inside the worktree"
             echo "  status: $( (cd "$wt" && git status --porcelain) | tr '\n' ' ')"; return 1; }
}

run_test test_worktree_name_rejected_without_base
run_test test_worktree_name_rejects_bad_task_half
run_test test_worktree_name_rejects_a_leading_dot_in_either_half
run_test test_plain_names_still_work
run_test test_worktree_create_tracked_mode
run_test test_worktree_create_refuses_dirty_base
run_test test_worktree_open_refuses_a_locked_vault
run_test test_worktree_create_refuses_a_locked_base_vault
run_test test_worktree_create_refuses_an_encrypted_base
run_test test_worktree_create_refuses_an_encrypted_base_with_untracked_links
run_test test_worktree_open_refuses_once_its_base_is_encrypted
run_test test_worktree_create_reuses_existing_branch
run_test test_worktree_create_ignored_mode_bootstraps_cs
run_test test_ignored_mode_worktree_starts_with_nothing_untracked
run_test test_ignored_mode_worktree_retires_without_a_manual_exclude
run_test test_retire_tolerates_a_worktree_predating_the_cs_exclude
run_test test_retire_still_refuses_real_untracked_work
run_test test_retire_refuses_ignored_work
run_test test_worktree_of_worktree_refused
run_test test_worktree_create_succeeds_with_untracked_base
run_test test_worktree_reopen_preserves_project_claude_md
run_test test_worktree_reopen_refuses_a_symlinked_cs_local
run_test test_worktree_creation_refuses_a_committed_cs_local_link
run_test test_worktree_launch_exports_base_identity
run_test test_launch_enables_the_task_tools_unless_opted_out
run_test test_launch_enables_function_hooks_unless_opted_out
run_test test_retire_after_integrate_removes_worktree_and_branch
run_test test_retire_refuses_dirty_worktree
run_test test_retire_refuses_a_live_feature_session_and_says_what_to_do
run_test test_retire_refuses_a_volume_mounted_inside_the_worktree
run_test test_retire_refuses_when_the_mount_table_cannot_be_read
run_test test_retire_from_live_base_session_succeeds
run_test test_retire_from_inside_the_feature_session_refuses
run_test test_retire_foreign_live_base_lock_still_refuses
run_test test_retire_reused_live_pid_is_not_treated_as_own_lock
run_test test_retire_refuses_an_unintegrated_feature
run_test test_retire_refuses_commits_after_the_captured_one
run_test test_retire_force_takes_a_squash_landed_branch
run_test test_retire_force_still_refuses_untracked_work
run_test test_retire_force_refuses_commits_after_the_captured_one
run_test test_retire_fuses_nothing_when_removal_fails_and_retry_fuses_once
run_test test_retire_with_a_locked_base_vault_leaves_the_worktree_whole
run_test test_retire_keeps_the_records_when_a_fuse_write_fails
run_test test_retire_refusal_for_an_open_session_comes_after_the_landing_check
run_test test_retire_rejects_traversal_task_name
run_test test_retire_is_hidden_from_completion_and_unknown_command_text
run_test test_merge_verb_is_gone

# --- -integrate-feature: integrate while the feature stays open, remove nothing ---

# Build base + feature with one feature commit; prints the feature SHA.
integrate_fixture() {  # base task
    local base_dir wt
    base_dir=$(create_test_session_with_git "$1")
    cs_launch "$1@$2"
    wt="$CS_SESSIONS_ROOT/$1@$2"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    git -C "$wt" rev-parse HEAD
}

test_integrate_refuses_unknown_worktree() {
    create_test_session_with_git "myproj" > /dev/null
    mkdir -p "$CS_SESSIONS_ROOT/myproj@ghost"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature ghost HEAD -- true 2>&1) || status=$?
    assert_eq "1" "$status" "an unregistered worktree refuses" || return 1
    assert_output_contains "$output" "not a registered worktree" "names the reason" || return 1
}

test_integrate_refuses_sha_not_on_feature_branch() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "base only")
    local stray output status=0
    stray=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$stray" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a commit not reachable from cs/<task> refuses" || return 1
    assert_output_contains "$output" "not reachable from cs/fix-auth" "names the branch" || return 1
}

test_integrate_reports_already_integrated_and_does_nothing() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/fix-auth)
    local head output status=0
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "already integrated exits 0: $output" || return 1
    assert_output_contains "$output" "already-integrated fix-auth $sha" "machine line printed" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "no commit is made" || return 1
}

test_integrate_refuses_dirty_base() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    echo "edit" >> "$base_dir/CLAUDE.md"
    local head output status=0
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "dirty base refuses" || return 1
    assert_output_contains "$output" "uncommitted changes" "names the dirt" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
}

test_integrate_refuses_foreign_live_base_lock() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # A live PID that is not an ancestor of the cs process: the ps stub reports
    # PID 1 as every process's parent, so the ancestry walk never reaches $$.
    echo "$$" > "$base_dir/.cs/session.lock"
    local ps_stub output status=0
    ps_stub=$(fixed_parent_ps_stub 1)
    output=$(CLAUDE_SESSION_NAME="other" CS_PS_BIN="$ps_stub" \
        "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a foreign live base lock refuses" || return 1
    assert_output_contains "$output" "open elsewhere" "names the live base" || return 1
}

# A TERM'd integrate runs its cleanup from the signal handler and again from
# the EXIT trap. Between the two another integrate can take the lock, so the
# second pass must not remove a directory it no longer owns.
test_integrate_cleanup_releases_the_lock_only_once() {
    local lock="$TEST_TMPDIR/cleanup-twice/integrate.lock"
    mkdir -p "$lock"
    echo 4242 > "$lock/pid"
    ( source "$SCRIPT_DIR/../lib/30-worktree.sh"
      _INTEGRATE_LOCK="$lock"; _INTEGRATE_BASE_DIR="$TEST_TMPDIR"; _INTEGRATE_TMP=""
      _integrate_cleanup
      [ -d "$lock" ] && { echo "  FAIL: the first pass must remove the lock"; exit 1; }
      # The successor's lock, taken between the two passes.
      mkdir "$lock" && echo 9999 > "$lock/pid"
      _integrate_cleanup
      [ -d "$lock" ] || { echo "  FAIL: the second pass removed the successor's lock"; exit 1; }
    ) || return 1
}

# cs runs under set -e. A lock something else already removed makes the
# handler's rm fail; that must not abort the handler before it forgets the
# path, or the EXIT pass would remove a successor's lock.
test_integrate_cleanup_forgets_a_lock_it_could_not_remove() {
    local lock="$TEST_TMPDIR/cleanup-gone/integrate.lock"
    mkdir -p "$TEST_TMPDIR/cleanup-gone"
    ( set -e
      source "$SCRIPT_DIR/../lib/30-worktree.sh"
      _INTEGRATE_LOCK="$lock"; _INTEGRATE_BASE_DIR="$TEST_TMPDIR"; _INTEGRATE_TMP=""
      _integrate_cleanup
      [ -z "$_INTEGRATE_LOCK" ] || { echo "  FAIL: a failed rm must still forget the lock path"; exit 1; }
      mkdir "$lock" && echo 9999 > "$lock/pid"
      _integrate_cleanup
      [ -d "$lock" ] || { echo "  FAIL: the second pass removed the successor's lock"; exit 1; }
    ) || return 1
}

test_integrate_ignores_the_feature_lock() {
    # The feature session stays open: its lock is not a blocker because the
    # integrate never touches the feature worktree.
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"
    local ps_stub
    ps_stub=$(fixed_parent_ps_stub 1)
    output=$(CS_PS_BIN="$ps_stub" "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds with the feature lock live: $output" || return 1
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    assert_output_contains "$output" "integrated fix-auth $sha -> $head" "summary line names the result" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content is on base" || return 1
    assert_dir "$wt" "the feature worktree remains" || return 1
}

test_integrate_refuses_merge_in_progress() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # Stage a MERGE_HEAD without dirtying the tracked tree.
    git -C "$base_dir" rev-parse HEAD > "$base_dir/.git/MERGE_HEAD"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    rm -f "$base_dir/.git/MERGE_HEAD"
    assert_eq "1" "$status" "a merge in progress refuses" || return 1
    assert_output_contains "$output" "merge or rebase in progress" "names the state" || return 1
}

test_integrate_refuses_stale_mutex_and_names_it() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$base_dir/.git/cs/integrate.lock"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "an existing mutex refuses" || return 1
    assert_output_contains "$output" "$base_dir/.git/cs/integrate.lock" "the refusal names the path" || return 1
    assert_dir "$base_dir/.git/cs/integrate.lock" "the mutex is never stolen" || return 1
}

test_integrate_requires_a_gate_command() {
    local sha output status=0
    sha=$(integrate_fixture myproj fix-auth)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "missing gate argv refuses" || return 1
    assert_output_contains "$output" "Usage: cs <base> -integrate-feature" "prints usage" || return 1
}

test_integrate_requires_a_sha() {
    # `set -u` would otherwise turn a missing positional into an unbound-variable
    # crash instead of the usage line.
    integrate_fixture myproj fix-auth > /dev/null
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth 2>&1) || status=$?
    assert_eq "1" "$status" "missing sha refuses" || return 1
    assert_output_contains "$output" "Usage: cs <base> -integrate-feature" "prints usage, not a shell error" || return 1
    assert_output_not_contains "$output" "unbound variable" "no set -u crash" || return 1
}

test_integrate_is_hidden_from_completion_and_unknown_command_text() {
    grep -q '^            -integrate-feature) # hidden' "$SCRIPT_DIR/../lib/99-main.sh" \
        || { echo "  FAIL: the arm must carry '# hidden' on its own line for test_completions"; return 1; }
    assert_file_not_contains "$SCRIPT_DIR/../lib/99-main.sh" 'Unknown session command.*-integrate-feature' \
        "the unknown-command string must not advertise the entry" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" 'integrate-feature' "help never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" 'integrate-feature' "zsh completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" 'integrate-feature' "bash completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../README.md" 'integrate-feature' "README never lists it" || return 1
}

test_integrate_and_autosave_spell_one_mutex_path() {
    # The hook cannot source lib/, so the path is spelled twice; this is the
    # only thing that keeps the two spellings equal.
    assert_file_contains "$SCRIPT_DIR/../hooks/autosave-commits.sh" 'cs/integrate\.lock' "hook names the mutex" || return 1
    assert_file_contains "$SCRIPT_DIR/../lib/30-worktree.sh" 'cs/integrate\.lock' "entry names the mutex" || return 1
}

run_test test_integrate_refuses_unknown_worktree
run_test test_integrate_refuses_sha_not_on_feature_branch
run_test test_integrate_reports_already_integrated_and_does_nothing
run_test test_integrate_refuses_dirty_base
run_test test_integrate_refuses_foreign_live_base_lock
run_test test_integrate_cleanup_releases_the_lock_only_once
run_test test_integrate_cleanup_forgets_a_lock_it_could_not_remove
run_test test_integrate_ignores_the_feature_lock
run_test test_integrate_refuses_merge_in_progress
run_test test_integrate_refuses_stale_mutex_and_names_it
run_test test_integrate_requires_a_gate_command
run_test test_integrate_requires_a_sha
run_test test_integrate_is_hidden_from_completion_and_unknown_command_text
run_test test_integrate_and_autosave_spell_one_mutex_path

test_integrate_lands_a_no_ff_merge_and_keeps_everything() {
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    assert_output_contains "$output" "integrated fix-auth $sha -> $head" "summary line names the result" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content is on base" || return 1
    assert_eq "3" "$(git -C "$base_dir" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" \
        "base HEAD is a merge commit: its sha plus two parents (--no-ff)" || return 1
    assert_dir "$wt" "the feature worktree remains" || return 1
    # rev-parse, not `branch --list`: git prefixes a branch checked out in a
    # linked worktree with `+`, so the listing never equals the bare name.
    git -C "$base_dir" rev-parse -q --verify refs/heads/cs/fix-auth >/dev/null 2>&1 \
        || { echo "  FAIL: the branch must remain"; return 1; }
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "no temp worktree left registered" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" '"event":"feature-integrated"' "timeline records the integrate" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "\"sha\":\"$sha\"" "event carries the sha" || return 1
    # The merge commit names the feature: it is the only audit trail /finish leaves.
    assert_output_contains "$(git -C "$base_dir" log -1 --format=%s)" "Merge feature fix-auth" "merge subject names the feature" || return 1
}

# The load-bearing local happy path: after an integrate, today's retire verb
# takes its "already merged; cleaning up" branch and merges NOTHING. In
# tracked mode the integrate's own timeline event dirties the base (the
# timeline is tracked there), and the verb refuses dirt — so the test stages
# the general case: a tracked timeline, the refusal, the user's commit of the
# bookkeeping, then the ancestor path. Retirement semantics are unchanged.
test_integrate_then_retire_tolerates_tracked_bookkeeping_dirt() {
    # In tracked-.cs mode the integrate's own timeline event dirties the base.
    # Retirement touches no base file, so that dirt is no reason to refuse:
    # /finish lands and retires in one run, and the bookkeeping stays the
    # user's to commit.
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    assert_eq " M .cs/timeline.jsonl" "$(git -C "$base_dir" status --porcelain)" \
        "the only dirt after an integrate is the tracked timeline event" || return 1
    local head_after_integrate
    head_after_integrate=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire succeeds over bookkeeping dirt: $output" || return 1
    assert_eq "$head_after_integrate" "$(git -C "$base_dir" rev-parse HEAD)" "retire makes no new commit" || return 1
    assert_eq " M .cs/timeline.jsonl" "$(git -C "$base_dir" status --porcelain)" \
        "and commits nothing on the user's behalf" || return 1
    assert_not_exists "$wt" "retire removed the worktree" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "retire deleted the branch" || return 1
}

test_retire_still_refuses_real_base_dirt() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "half-typed" >> "$base_dir/CLAUDE.md"
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a dirty base file outside .cs still refuses" || return 1
    assert_output_contains "$output" "Base session has uncommitted changes" "the refusal is the verb's own" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_integrate_red_gate_leaves_base_untouched() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    # The gate records where it ran: a red gate in the LIVE base would also
    # "leave HEAD unchanged", so location is part of what this proves.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'pwd > "$0/where"; echo GATE-SAYS-NO; exit 3' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "1" "$status" "a red gate refuses" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/where" 2>/dev/null)" "/cs-finish-fix-auth." "the red gate ran in the temp" || return 1
    assert_output_contains "$output" "GATE-SAYS-NO" "the gate output is shown" || return 1
    assert_output_contains "$output" "Gate failed" "names the cause" || return 1
    assert_output_contains "$output" "clean checkout" "and says the gate ran without gitignored files" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "base tree unchanged" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released on failure" || return 1
}

# An untracked base file colliding with a path the feature adds must be caught
# before the gate runs at all: _tree_is_dirty only sees tracked dirt, so
# without this check the gate would run to completion and only THEN hit an
# un-diagnosable ff-only abort.
test_integrate_refuses_untracked_collision_before_the_gate() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    echo "stale" > "$base_dir/feature.txt"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'touch "$0/marker"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "1" "$status" "an untracked collision refuses" || return 1
    assert_output_contains "$output" "feature.txt" "names the colliding path" || return 1
    assert_file_not_exists "$TEST_TMPDIR/marker" "the gate never ran" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_eq "stale" "$(cat "$base_dir/feature.txt")" "the untracked file survives with its content" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_gates_run_in_the_temp_not_the_live_trees() {
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # The gate records where it ran and proves the merged tree is there.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'pwd > "$0/where"; test -f feature.txt' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "gate saw the merged tree: $output" || return 1
    local where
    where=$(cat "$TEST_TMPDIR/where")
    assert_output_contains "$where" "/cs-finish-fix-auth." "gate ran in the temp worktree" || return 1
    # Tools refuse paths under a .git directory (Vite's server.fs.deny has
    # **/.git/**), so a gate run there fails for reasons of its location.
    assert_output_not_contains "$where" "/.git/" "the temp worktree is outside any .git directory" || return 1
    assert_output_not_contains "$where" "$wt" "gate did not run in the feature worktree" || return 1
    [ "$where" != "$base_dir" ] || { echo "  FAIL: gate ran in the live base"; return 1; }
}

test_integrate_refuses_when_base_moved_during_gates() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # The gate itself moves base HEAD: deterministic, no timing.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git -C "$base_dir" commit -q --allow-empty -m moved 2>&1) || status=$?
    assert_eq "1" "$status" "a moved base refuses" || return 1
    assert_output_contains "$output" "moved during the gates" "names the cause" || return 1
    assert_eq "moved" "$(git -C "$base_dir" log -1 --format=%s)" "base keeps only its own new commit" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_when_base_reset_to_an_ancestor_during_gates() {
    # --ff-only would happily land on a base that went BACKWARDS; the explicit
    # HEAD == B check is what refuses it.
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "will be reset away")
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git -C "$base_dir" reset -q --hard HEAD~1 2>&1) || status=$?
    assert_eq "1" "$status" "a base reset during gates refuses" || return 1
    assert_output_contains "$output" "moved during the gates" "names the cause" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_when_base_dirtied_during_gates() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo edit >> "$0/CLAUDE.md"' "$base_dir" 2>&1) || status=$?
    assert_eq "1" "$status" "dirt introduced during gates refuses" || return 1
    assert_output_contains "$output" "changed during the gates" "names the cause" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

test_integrate_terminated_mid_gate_leaves_no_lock_or_temp() {
    # TERM during the gate must still release the mutex and remove the temp:
    # a plain EXIT trap does not fire on TERM. Bash exec-optimizes the last
    # command of `(cd "$tmp" && "$@")`, so the gate's PPID is cs itself, not
    # a subshell one level down — walk up while the ancestor's argv still
    # names -integrate-feature and terminate the topmost one, which lands on
    # cs under either fork shape.
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # The marker is written only after the gate has SEEN the mutex held, so a
    # run that never took the lock (or never reached the gate) cannot pass the
    # release assertions below by never having acquired anything. A private
    # TMPDIR holds the gate's output log, so a leftover is this run's alone.
    local gate_tmp="$TEST_TMPDIR/gate-tmpdir"
    mkdir -p "$gate_tmp"
    output=$(TMPDIR="$gate_tmp" "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c '
        test -d "$0" || exit 9
        : > "$1"
        target=""; p=$PPID
        while [ "${p:-1}" -gt 1 ]; do
            case "$(ps -o args= -p "$p" 2>/dev/null)" in
                *" -integrate-feature "*) target=$p ;;
                *) break ;;
            esac
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " ")
        done
        kill -TERM "$target"; sleep 2
    ' "$base_dir/.git/cs/integrate.lock" "$TEST_TMPDIR/gate-ran" 2>&1) || status=$?
    [ "$status" != 0 ] || { echo "  FAIL: a terminated integrate must not exit 0"; return 1; }
    assert_file_exists "$TEST_TMPDIR/gate-ran" "the gate ran with the mutex held" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released on TERM" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed on TERM" || return 1
    assert_eq "" "$(ls "$gate_tmp")" "nothing left in TMPDIR on TERM, the gate log included" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

# A gate log or a temp worktree the cleanup cannot remove (macOS's user
# immutable flag) must not stop the cleanup: the mutex is still released, so
# the next integrate runs.
test_integrate_terminated_mid_gate_releases_the_lock_when_its_files_stay() {
    command -v chflags >/dev/null 2>&1 || return 77
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local gate_tmp="$TEST_TMPDIR/gate-tmpdir"
    mkdir -p "$gate_tmp"
    output=$(TMPDIR="$gate_tmp" "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c '
        test -d "$0" || exit 9
        chflags uchg "$TMPDIR"/cs-gate.* || exit 8
        : > kept && chflags uchg kept || exit 7
        : > "$1"
        target=""; p=$PPID
        while [ "${p:-1}" -gt 1 ]; do
            case "$(ps -o args= -p "$p" 2>/dev/null)" in
                *" -integrate-feature "*) target=$p ;;
                *) break ;;
            esac
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " ")
        done
        kill -TERM "$target"; sleep 2
    ' "$base_dir/.git/cs/integrate.lock" "$TEST_TMPDIR/gate-ran" 2>&1) || status=$?
    chflags -R nouchg "$gate_tmp" 2>/dev/null || :
    [ "$status" != 0 ] || { echo "  FAIL: a terminated integrate must not exit 0"; return 1; }
    assert_file_exists "$TEST_TMPDIR/gate-ran" "the gate ran with the mutex held and its log immutable" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released although the gate log and the temp worktree stay" || return 1
}

test_integrate_conflict_names_the_path_and_leaves_no_merge_head() {
    local base_dir wt sha output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo "base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base file")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "conflicting base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base edit")
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a conflict refuses" || return 1
    assert_output_contains "$output" "shared.txt" "names the conflicting path" || return 1
    assert_output_contains "$output" "git merge $(git -C "$base_dir" symbolic-ref --short HEAD) in $wt" \
        "the advice names the base's real branch and the worktree to run it in" || return 1
    assert_file_not_exists "$base_dir/.git/MERGE_HEAD" "no MERGE_HEAD in the base" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
}

test_integrate_ignored_mode_fuses_nothing() {
    # Ignored mode: the feature's .cs/ never rides the merge and /finish fuses
    # no records (retire does). The base timeline must gain exactly one event.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# readme" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo '{"ts":"2026-01-01T00:00:00Z","event":"task","note":"feature-side"}' >> "$wt/.cs/timeline.jsonl"
    echo "work" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m work)
    local sha
    sha=$(git -C "$wt" rev-parse HEAD)
    "$CS_BIN" proj -integrate-feature t1 "$sha" -- true >/dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    assert_file_exists "$base_dir/result.txt" "code landed" || return 1
    assert_file_not_contains "$base_dir/.cs/timeline.jsonl" "feature-side" "feature records are not fused by integrate" || return 1
    assert_dir "$wt/.cs" "feature .cs untouched" || return 1
}

test_integrate_tracked_mode_warns_on_memory_index_change() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "- [x](x.md) — feature-side pointer" >> "$wt/.cs/memory/MEMORY.md"
    (cd "$wt" && git add .cs/memory/MEMORY.md && git commit -q -m "index")
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_output_contains "$output" "MEMORY.md changed on $sha" "merge=ours drop is announced" || return 1
}

test_integrate_tracked_mode_union_merges_shared_records() {
    # Both sides append to the tracked timeline; the verb's merge policy
    # (merge=union) must reach the temp worktree or this conflicts.
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo '{"ts":"2026-01-02T00:00:00Z","event":"feature-side"}' >> "$wt/.cs/timeline.jsonl"
    (cd "$wt" && git add .cs/timeline.jsonl && git commit -q -m "feature event")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo '{"ts":"2026-01-03T00:00:00Z","event":"base-side"}' >> "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m "base event")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "union merge lands: $output" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "feature-side" "feature line kept" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "base-side" "base line kept" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .gitattributes)" "no tree is dirtied to get the policy" || return 1
}

# The base's own landing is the one merge cs does NOT run with hooks
# suppressed: it is the user's checkout and their post-merge hook is entitled
# to fire. A hook that commits leaves base past the commit cs just landed, so
# the summary must name where the base actually ended up.
test_integrate_survives_a_base_post_merge_hook_that_commits() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$base_dir/.git/hooks"
    cat > "$base_dir/.git/hooks/post-merge" << 'HOOK'
#!/usr/bin/env bash
git commit -q --allow-empty -m "post-merge bookkeeping"
HOOK
    chmod +x "$base_dir/.git/hooks/post-merge"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "a landing whose hook commits still succeeds: $output" || return 1
    assert_eq "post-merge bookkeeping" "$(git -C "$base_dir" log -1 --format=%s)" "the hook's commit is the base tip" || return 1
    assert_output_contains "$output" "post-merge hook moved" "the hook's move is announced" || return 1
    assert_output_contains "$output" "integrated fix-auth $sha -> $(git -C "$base_dir" rev-parse HEAD)" \
        "the summary names the head the base really has" || return 1
    assert_file_exists "$base_dir/feature.txt" "the feature still landed" || return 1
}

run_test test_integrate_lands_a_no_ff_merge_and_keeps_everything
# The gate runs the project's build, and a build that writes into the tree
# would otherwise land content nobody reviewed: what cs fast-forwards the base
# onto is the merge commit, so a gate-written file either vanishes or, once
# committed by the gate, rides in unseen. Refuse instead.
test_integrate_refuses_a_gate_that_writes_into_the_temp() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo stale > CLAUDE.md' 2>&1) || status=$?
    assert_eq "1" "$status" "a tree-writing gate refuses" || return 1
    assert_output_contains "$output" "CLAUDE.md" "names the path the gate changed" || return 1
    assert_output_contains "$output" "re-run /finish fix-auth" "names the next command" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_a_gate_that_commits_in_the_temp() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    # A real commit: `git add . && git commit` with nothing changed exits 1 and
    # would be caught as a red gate instead, proving nothing.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo generated > built.txt && git add . && git commit -q -m gate-made' 2>&1) || status=$?
    assert_eq "1" "$status" "a committing gate refuses" || return 1
    assert_output_not_contains "$output" "Gate failed" "the gate itself was green; this is the tamper refusal" || return 1
    assert_output_contains "$output" "re-run /finish fix-auth" "names the next command" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
}

test_integrate_refuses_a_gate_that_moves_the_temp_head() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git checkout -q "$head" 2>&1) || status=$?
    assert_eq "1" "$status" "a gate that moves the temp HEAD refuses" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

run_test test_integrate_survives_a_base_post_merge_hook_that_commits
run_test test_integrate_refuses_a_gate_that_writes_into_the_temp
run_test test_integrate_refuses_a_gate_that_commits_in_the_temp
# A detached base has no branch to land on: the ff-only would move a
# detached HEAD and leave the branch behind. The refusal belongs before the
# local/PR split, so both paths get it.
test_integrate_refuses_a_detached_base() {
    local sha base_dir branch head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    branch=$(git -C "$base_dir" symbolic-ref --short HEAD)
    head=$(git -C "$base_dir" rev-parse HEAD)
    git -C "$base_dir" checkout -q --detach
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "the local path refuses a detached base" || return 1
    assert_output_contains "$output" "Base checkout is detached" "names the state" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse "$branch")" "the branch is unmoved" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "HEAD is unmoved" || return 1
}

run_test test_integrate_refuses_a_gate_that_moves_the_temp_head
run_test test_integrate_refuses_a_detached_base
run_test test_integrate_tracked_mode_union_merges_shared_records
run_test test_integrate_then_retire_tolerates_tracked_bookkeeping_dirt
run_test test_retire_still_refuses_real_base_dirt
run_test test_integrate_red_gate_leaves_base_untouched
run_test test_integrate_refuses_untracked_collision_before_the_gate
run_test test_integrate_gates_run_in_the_temp_not_the_live_trees
run_test test_integrate_refuses_when_base_moved_during_gates
run_test test_integrate_refuses_when_base_reset_to_an_ancestor_during_gates
run_test test_integrate_refuses_when_base_dirtied_during_gates
run_test test_integrate_terminated_mid_gate_leaves_no_lock_or_temp
run_test test_integrate_terminated_mid_gate_releases_the_lock_when_its_files_stay
run_test test_integrate_conflict_names_the_path_and_leaves_no_merge_head
run_test test_integrate_ignored_mode_fuses_nothing
run_test test_integrate_tracked_mode_warns_on_memory_index_change

# The feature's tree lands in the base before cs writes the base's timeline
# event, and nothing scanned the base since it opened: a link the feature
# committed at .cs/timeline.jsonl would carry that write out of the session.
test_integrate_and_retire_never_write_through_a_landed_timeline_link() {
    local sha base_dir wt output status=0 outside="$TEST_TMPDIR/outside-timeline"
    local outside_p
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    printf 'outside\n' > "$outside"
    outside_p="$(cd "$TEST_TMPDIR" && pwd -P)/outside-timeline"
    (cd "$wt" && rm .cs/timeline.jsonl && ln -s "$outside" .cs/timeline.jsonl \
        && git add .cs/timeline.jsonl && git commit -q -m "link the timeline out")
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "the landing itself succeeds: $output" || return 1
    assert_symlink "$base_dir/.cs/timeline.jsonl" "the feature's link landed in the base" || return 1
    assert_output_contains "$output" "timeline.jsonl leads to $outside_p" "the refusal names the link" || return 1
    assert_eq "outside" "$(cat "$outside")" "integrate wrote nothing outside the session" || return 1
    status=0
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire itself succeeds: $output" || return 1
    assert_output_contains "$output" "timeline.jsonl leads to $outside_p" "the retire names the link too" || return 1
    assert_eq "outside" "$(cat "$outside")" "retire wrote nothing outside the session" || return 1
}

run_test test_integrate_and_retire_never_write_through_a_landed_timeline_link

# A feature can commit MEMORY.md as a link whose target text reads as a
# pointer line. The merge installs the link in the temp checkout, and the
# pointer carryover then appended that line through it.
test_integrate_never_appends_memory_pointers_through_a_committed_index_link() {
    local sha base_dir wt output status=0 outside
    # Enough levels to climb to / from any temp checkout.
    local up="../../../../../../../../../../../../../../../../../../../../../../../../"
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    outside="$(cd "$TEST_TMPDIR" && pwd -P)/outside-index"
    printf 'outside\n' > "$outside"
    (cd "$wt/.cs/memory" && printf 'topic\n' > x.md && mkdir -- '- [X](x.md)' && : > '- [X](x.md)/.keep' \
        && rm -f MEMORY.md && ln -s -- "- [X](x.md)/$up${outside#/}" MEMORY.md \
        && git add -A . && git commit -q -m "link the index out")
    assert_eq "outside" "$(cat "$wt/.cs/memory/MEMORY.md")" "the fixture's link reaches the outside file" || return 1
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "outside" "$(cat "$outside")" "nothing was appended outside the session" || return 1
    assert_eq "1" "$status" "the integrate refuses: $output" || return 1
    assert_output_contains "$output" "MEMORY.md leads to $outside" "the refusal names the link" || return 1
}

run_test test_integrate_never_appends_memory_pointers_through_a_committed_index_link

# Ignored mode: git overwrites the base's ignored timeline with a link the
# feature force-added, and retire then fuses the worktree's own records into
# the base.
test_retire_never_fuses_records_through_a_landed_timeline_link() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt sha output status=0 outside
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# readme" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    wt="$CS_SESSIONS_ROOT/proj@t1"
    outside="$(cd "$TEST_TMPDIR" && pwd -P)/outside-fuse"
    printf 'outside\n' > "$outside"
    (cd "$wt" && rm -f .cs/timeline.jsonl && ln -s "$outside" .cs/timeline.jsonl \
        && git add -f .cs/timeline.jsonl && git commit -q -m "link the timeline out")
    sha=$(git -C "$wt" rev-parse HEAD)
    git -C "$wt" checkout -q --detach HEAD~1
    echo '{"ts":"2026-01-01T00:00:00Z","event":"task","note":"feature-side"}' > "$wt/.cs/timeline.jsonl"
    "$CS_BIN" proj -integrate-feature t1 "$sha" -- true >/dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    assert_symlink "$base_dir/.cs/timeline.jsonl" "the feature's link landed over the base's ignored timeline" || return 1
    output=$("$CS_BIN" proj -retire-feature t1 "$sha" 2>&1) || status=$?
    assert_eq "outside" "$(cat "$outside")" "the fuse wrote nothing outside the session" || return 1
    assert_eq "1" "$status" "the retire says the records were not fused: $output" || return 1
    assert_output_contains "$output" "timeline.jsonl leads to $outside" "the refusal names the link" || return 1
    assert_output_contains "$output" "could not be fused into" "the staged records are kept and named" || return 1
}

run_test test_retire_never_fuses_records_through_a_landed_timeline_link

# A feature can commit .cs itself as a link. Once it lands, the base's whole
# metadata directory is that link, and the retire's progress record must not
# create its directory on the far side.
test_retire_never_creates_the_progress_directory_through_a_landed_cs_link() {
    local sha base_dir wt output status=0 outside="$TEST_TMPDIR/outside-cs"
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    mkdir "$outside"
    (cd "$wt" && git rm -rq --cached .cs && mv .cs "$TEST_TMPDIR/feature-cs" && ln -s "$outside" .cs \
        && git add .cs && git commit -q -m "link the metadata out")
    sha=$(git -C "$wt" rev-parse HEAD)
    rm "$wt/.cs" && git -C "$wt" checkout -q --detach HEAD~1 \
        && cp -R "$TEST_TMPDIR/feature-cs/local" "$wt/.cs/local" \
        || { echo "  FAIL: could not put the worktree's own .cs back"; return 1; }
    assert_eq "" "$(git -C "$wt" status --porcelain)" "the worktree is clean at the parent commit" || return 1
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "the landing itself succeeds: $output" || return 1
    assert_symlink "$base_dir/.cs" "the feature's link landed in the base" || return 1
    assert_eq "" "$(ls -A "$outside")" "integrate created nothing outside the session" || return 1
    status=0
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "" "$(ls -A "$outside")" "retire created nothing outside the session" || return 1
    assert_eq "0" "$status" "the retire itself succeeds: $output" || return 1
    assert_output_contains "$output" "/finish progress not recorded" "the unrecorded run is named" || return 1
}

run_test test_retire_never_creates_the_progress_directory_through_a_landed_cs_link

# merge=ours keeps the base's MEMORY.md, but a pointer to a topic only the
# feature wrote must still reach the base: appended once, after the base's
# own lines, and a pointer both sides name is not doubled.
test_integrate_tracked_mode_appends_feature_memory_pointers() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    printf '%s\n' '- [A](a.md): base wording' > "$base_dir/.cs/memory/MEMORY.md"
    (cd "$base_dir" && git add .cs/memory/MEMORY.md && git commit -q -m "base index")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    printf '%s\n' '- [A](a.md): feature wording' '- [X](x.md): feature-side' '- [X again](x.md): duplicate' \
        > "$wt/.cs/memory/MEMORY.md"
    echo "x topic" > "$wt/.cs/memory/x.md"
    (cd "$wt" && git add .cs/memory && git commit -q -m "index")
    sha=$(git -C "$wt" rev-parse HEAD)
    printf '%s\n' '- [B](b.md): base-side' >> "$base_dir/.cs/memory/MEMORY.md"
    (cd "$base_dir" && git add .cs/memory/MEMORY.md && git commit -q -m "base pointer")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_eq "- [A](a.md): base wording
- [B](b.md): base-side
- [X](x.md): feature-side" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "base index kept, the feature's new pointer appended once" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .cs/memory)" \
        "the appended pointer is committed, not left as dirt" || return 1
}

run_test test_integrate_tracked_mode_appends_feature_memory_pointers

# A topic the base deleted after the feature branched stays deleted: the merge
# drops the file, and the feature's old pointer to it is not appended back.
test_integrate_tracked_mode_skips_pointers_to_base_deleted_topics() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    printf '%s\n' '- [A](a.md): base' '- [T](t.md): old topic' > "$base_dir/.cs/memory/MEMORY.md"
    echo "t topic" > "$base_dir/.cs/memory/t.md"
    (cd "$base_dir" && git add .cs/memory && git commit -q -m "base index")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo '- [X](x.md): feature-side' >> "$wt/.cs/memory/MEMORY.md"
    echo "x topic" > "$wt/.cs/memory/x.md"
    (cd "$wt" && git add .cs/memory && git commit -q -m "feature topic")
    sha=$(git -C "$wt" rev-parse HEAD)
    printf '%s\n' '- [A](a.md): base' > "$base_dir/.cs/memory/MEMORY.md"
    (cd "$base_dir" && git rm -q .cs/memory/t.md && git add .cs/memory/MEMORY.md && git commit -q -m "drop topic t")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_not_exists "$base_dir/.cs/memory/t.md" "the base's deletion of t.md stands" || return 1
    assert_eq "- [A](a.md): base
- [X](x.md): feature-side" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "no pointer to the deleted topic comes back; the new one is appended" || return 1
}

run_test test_integrate_tracked_mode_skips_pointers_to_base_deleted_topics

test_retire_ignored_mode_fuses_records() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "base note" > "$base_dir/.cs/memory/note-base.md"
    echo "shared note" > "$base_dir/.cs/memory/note-shared.md"
    printf -- '---\ndescription: seed\n---\n# Session narrative (tester)\n\n## Prior finding\n' \
        > "$base_dir/.cs/memory/narrative.tester.md"
    printf -- '---\ndescription: plain-seed\n---\n# Session narrative (plain)\n' \
        > "$base_dir/.cs/memory/narrative.plain.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    # Task work: code (committed) + session records (untracked .cs)
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo '{"event":"from-task"}' >> "$wt/.cs/timeline.jsonl"
    echo "task memory" > "$wt/.cs/memory/note-task.md"
    printf -- '---\nname: n\n---\n# Session narrative (tester)\n\n## Task finding\n\n---\n\n## After rule\n' \
        > "$wt/.cs/memory/narrative.tester.md"
    printf -- '---\nname: other-n\n---\n# Session narrative (other)\n\n## Other finding\n' \
        > "$wt/.cs/memory/narrative.other.md"
    printf -- '# Session narrative (plain)\n\n## Plain finding\n' \
        > "$wt/.cs/memory/narrative.plain.md"
    echo "task version" > "$wt/.cs/memory/note-base.md"
    echo "shared note" > "$wt/.cs/memory/note-shared.md"
    local output merge_status
    local sha
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1)
    merge_status=$?
    assert_eq "0" "$merge_status" "retire exits 0" \
        || { echo "  retire output: $output"; return 1; }
    assert_output_contains "$output" "memory/note-base.md was edited in the feature and not in the base; the feature's version is now in the base" \
        "an inherited topic the feature edited is named" || return 1
    assert_output_not_contains "$output" "note-shared.md" \
        "a topic byte-identical to the base's is skipped silently" || return 1
    assert_eq "task version" "$(cat "$base_dir/.cs/memory/note-base.md")" \
        "the feature's edit replaces the copy the base left unchanged" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "from-task" "timeline appended" || return 1
    assert_file_exists "$base_dir/.cs/memory/note-task.md" "memory file copied" || return 1
    assert_file_exists "$base_dir/.cs/memory/note-base.md" "base memory untouched" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "Task finding" "narrative body appended" || return 1
    assert_file_not_contains "$base_dir/.cs/memory/narrative.tester.md" "name: n" "frontmatter not duplicated" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "description: seed" "base frontmatter kept" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "After rule" \
        "body after horizontal rule survives" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.plain.md" "Plain finding" \
        "no-frontmatter body appended" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.plain.md" "description: plain-seed" \
        "plain base frontmatter kept" || return 1
    assert_file_exists "$base_dir/.cs/memory/narrative.other.md" "unseen narrative copied" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.other.md" "name: other-n" "first copy keeps frontmatter" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_file_exists "$base_dir/result.txt" "code landed by the integrate" || return 1
}

run_test test_retire_ignored_mode_fuses_records

# The repo does not track .cs/, so git gives the feature none of the base's
# context: cs copies the memory topics, the index, plans/ and summary.md.
# Never a narrative (the feature writes its own), .cs/local, or the timeline.
test_worktree_create_ignored_mode_copies_base_context() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local,plans}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    echo "topic body" > "$base_dir/.cs/memory/topic.md"
    printf '%s\n' '- [Topic](topic.md): base pointer' > "$base_dir/.cs/memory/MEMORY.md"
    echo "base narrative" > "$base_dir/.cs/memory/narrative.other.md"
    echo "plan body" > "$base_dir/.cs/plans/plan-a.md"
    echo "summary body" > "$base_dir/.cs/summary.md"
    echo "base-only" > "$base_dir/.cs/local/marker"
    echo '{"event":"base-only"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "topic body" "$(cat "$wt/.cs/memory/topic.md" 2>/dev/null)" "topic copied" || return 1
    assert_eq "- [Topic](topic.md): base pointer" "$(head -1 "$wt/.cs/memory/MEMORY.md" 2>/dev/null)" \
        "index copied with the base's lines first" || return 1
    assert_eq "plan body" "$(cat "$wt/.cs/plans/plan-a.md" 2>/dev/null)" "plans copied" || return 1
    assert_eq "summary body" "$(cat "$wt/.cs/summary.md" 2>/dev/null)" "summary copied" || return 1
    assert_not_exists "$wt/.cs/memory/narrative.other.md" "a narrative is never copied" || return 1
    assert_not_exists "$wt/.cs/local/marker" ".cs/local is never copied" || return 1
    assert_file_not_contains "$wt/.cs/timeline.jsonl" "base-only" "the timeline is never copied" || return 1
}

run_test test_worktree_create_ignored_mode_copies_base_context

# plans/ is copied file by file: a regular file at any depth comes over, a
# link inside plans/ (to a file or a dir, such as another session's plans)
# does not, neither as its target's content nor as the link.
test_worktree_create_ignored_mode_copies_no_plan_links() {
    local base_dir="$CS_SESSIONS_ROOT/proj" other="$CS_SESSIONS_ROOT/other/.cs/plans"
    mkdir -p "$base_dir/.cs"/{memory,local,plans/sub} "$other/deep"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    echo "nested body" > "$base_dir/.cs/plans/sub/plan-b.md"
    echo "other plan" > "$other/secret.md"
    echo "other deep" > "$other/deep/deep.md"
    ln -s "$other/secret.md" "$base_dir/.cs/plans/linked.md"
    ln -s "$other/deep" "$base_dir/.cs/plans/sub/linkdir"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "nested body" "$(cat "$wt/.cs/plans/sub/plan-b.md" 2>/dev/null)" "a nested plan is copied" || return 1
    assert_eq "sub" "$(ls -A "$wt/.cs/plans")" "plans/ holds no link" || return 1
    assert_eq "plan-b.md" "$(ls -A "$wt/.cs/plans/sub")" "plans/sub holds no link" || return 1
}

run_test test_worktree_create_ignored_mode_copies_no_plan_links

# A plan under a directory whose name starts with a dash, or ends in a
# newline, is a regular file like any other and comes over to the feature.
test_worktree_create_ignored_mode_copies_plans_under_odd_dir_names() {
    local base_dir="$CS_SESSIONS_ROOT/proj" nl_dir
    nl_dir="$(printf 'tail\n_')"; nl_dir="${nl_dir%_}"
    mkdir -p "$base_dir/.cs"/{memory,local} "$base_dir/.cs/plans/-sub" "$base_dir/.cs/plans/$nl_dir"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    echo "dash body" > "$base_dir/.cs/plans/-sub/plan.md"
    echo "newline body" > "$base_dir/.cs/plans/$nl_dir/plan.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "dash body" "$(cat "$wt/.cs/plans/-sub/plan.md" 2>/dev/null)" "a plan under -sub/ is copied" || return 1
    assert_eq "newline body" "$(cat "$wt/.cs/plans/$nl_dir/plan.md" 2>/dev/null)" \
        "a plan under a dir ending in a newline is copied" || return 1
}

run_test test_worktree_create_ignored_mode_copies_plans_under_odd_dir_names

# Ignored mode keeps the base's MEMORY.md too, and appends each feature
# pointer whose target the base index does not name.
test_retire_ignored_mode_appends_feature_memory_pointers() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [A](a.md): base wording' > "$base_dir/.cs/memory/MEMORY.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '%s\n' '- [A](a.md): feature wording' '- [X](x.md): feature-side' > "$wt/.cs/memory/MEMORY.md"
    echo "x topic" > "$wt/.cs/memory/x.md"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_eq "- [A](a.md): base wording
- [X](x.md): feature-side" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "base index kept, the feature's new pointer appended" || return 1
}

run_test test_retire_ignored_mode_appends_feature_memory_pointers

# An ignored-mode feature starts with a copy of the base's topics. One the
# base deleted while the feature was open, and the feature never touched, is
# not a topic the feature wrote: the fuse leaves it deleted, pointer and all.
_ignored_base_with_two_topics() {  # prints nothing; base at $CS_SESSIONS_ROOT/proj
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [Gone](gone.md): a topic' '- [Kept](kept.md): a topic' > "$base_dir/.cs/memory/MEMORY.md"
    echo "gone topic" > "$base_dir/.cs/memory/gone.md"
    echo "kept topic" > "$base_dir/.cs/memory/kept.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
}

test_retire_ignored_mode_leaves_a_base_deleted_topic_deleted() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    local odd=$'gone\nagain.md'
    _ignored_base_with_two_topics
    echo "odd topic" > "$base_dir/.cs/memory/$odd"
    cs_launch "proj@t1"
    assert_eq "gone topic" "$(cat "$wt/.cs/memory/gone.md")" "the feature inherited the topic" || return 1
    assert_eq "odd topic" "$(cat "$wt/.cs/memory/$odd")" "and the one with a newline in its name" || return 1
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "feature topic" > "$wt/.cs/memory/new.md"
    printf '%s\n' '- [New](new.md): feature-side' >> "$wt/.cs/memory/MEMORY.md"
    rm "$base_dir/.cs/memory/gone.md" "$base_dir/.cs/memory/$odd"
    printf '%s\n' '- [Kept](kept.md): a topic' > "$base_dir/.cs/memory/MEMORY.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/gone.md" "the deleted topic stays deleted" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/$odd" "whatever its name holds" || return 1
    assert_eq "feature topic" "$(cat "$base_dir/.cs/memory/new.md")" "a topic the feature wrote still lands" || return 1
    assert_eq "" "$(grep -F 'gone.md' "$base_dir/.cs/memory/MEMORY.md")" \
        "no pointer comes back for the deleted topic" || return 1
    assert_eq "- [New](new.md): feature-side" "$(grep -F 'new.md' "$base_dir/.cs/memory/MEMORY.md")" \
        "the feature's own pointer still lands" || return 1
    assert_output_not_contains "$output" "gone.md" "an untouched deleted topic is not mentioned" || return 1
}

run_test test_retire_ignored_mode_leaves_a_base_deleted_topic_deleted

# The feature edited a topic it inherited and the base deleted meanwhile: the
# edit is work, so the feature's text comes back, its pointer with it, and
# the retire says which topic.
test_retire_ignored_mode_brings_back_a_deleted_topic_the_feature_edited() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "gone topic, with a feature note" > "$wt/.cs/memory/gone.md"
    rm "$base_dir/.cs/memory/gone.md" "$base_dir/.cs/memory/kept.md"
    : > "$base_dir/.cs/memory/MEMORY.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_eq "gone topic, with a feature note" "$(cat "$base_dir/.cs/memory/gone.md")" \
        "the feature's edit is back in the base" || return 1
    assert_output_contains "$output" "memory/gone.md was deleted in the base and edited in the feature" \
        "the retire names the topic" || return 1
    assert_eq "- [Gone](gone.md): a topic" "$(grep -F 'gone.md' "$base_dir/.cs/memory/MEMORY.md")" \
        "its pointer comes back with it" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/kept.md" "the untouched deleted topic stays deleted" || return 1
    assert_eq "" "$(grep -F 'kept.md' "$base_dir/.cs/memory/MEMORY.md")" "and so does its pointer" || return 1
}

run_test test_retire_ignored_mode_brings_back_a_deleted_topic_the_feature_edited

# A topic both sides edited cannot go back without overwriting one edit: the
# retire refuses before it removes anything, naming the topic, and the features
# screen counts it as a file the removal would destroy.
test_retire_ignored_mode_refuses_a_topic_both_sides_edited() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "kept topic, feature edit" > "$wt/.cs/memory/kept.md"
    echo "kept topic, base edit" > "$base_dir/.cs/memory/kept.md"
    echo "feature topic" > "$wt/.cs/memory/new.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "1" "$(_feat_field "$line" 7)" "one file at risk: $line" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "The feature's session records hold files the record fuse cannot carry into $base_dir/.cs: the base holds a different file at the same path, or the file is a link or a repository. Nothing was removed. Merge each into $base_dir/.cs by hand, or delete it from $wt/.cs, then run /finish t1 again:
.cs/memory/kept.md" "the refusal names the topic" || return 1
    assert_eq "kept topic, feature edit" "$(cat "$wt/.cs/memory/kept.md")" "the feature's edit is still there" || return 1
    assert_eq "kept topic, base edit" "$(cat "$base_dir/.cs/memory/kept.md")" "the base's edit is untouched" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/new.md" "nothing was fused" || return 1
    # Positive control: once the user settles the topic, the same worktree retires.
    cp "$wt/.cs/memory/kept.md" "$base_dir/.cs/memory/kept.md"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "feature topic" "$(cat "$base_dir/.cs/memory/new.md")" "the feature's topic lands" || return 1
}

run_test test_retire_ignored_mode_refuses_a_topic_both_sides_edited

# Every record under .cs that the base lacks goes back to it, at any depth,
# not just topics and narratives: plans, a summary, handoffs, a brief,
# artifacts, archived narrative sections, a nested topic, a non-.md note. A
# plan or summary the create copied in and only the feature edited replaces
# the base's unchanged copy, named. The README cs wrote for the feature, left
# as written, is the feature's own bookkeeping and goes with it.
test_retire_ignored_mode_carries_every_record_the_base_lacks() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 rel
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.cs/plans"
    echo "base plan" > "$base_dir/.cs/plans/base-plan.md"
    echo "base summary" > "$base_dir/.cs/summary.md"
    echo "# Session: proj" > "$base_dir/.cs/README.md"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    mkdir -p "$wt/.cs/plans/sub" "$wt/.cs/handoffs" "$wt/.cs/artifacts" \
        "$wt/.cs/narrative-archive/someone" "$wt/.cs/memory/sub"
    for rel in plans/feat-plan.md plans/sub/deep-plan.md handoffs/2026-01-01-h.md brief.md \
            artifacts/report.html narrative-archive/someone/old.md memory/sub/deep.md memory/notes.txt; do
        echo "feature $rel" > "$wt/.cs/$rel"
    done
    echo "base plan, feature edit" > "$wt/.cs/plans/base-plan.md"
    echo "base summary, feature edit" > "$wt/.cs/summary.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    for rel in plans/feat-plan.md plans/sub/deep-plan.md handoffs/2026-01-01-h.md brief.md \
            artifacts/report.html narrative-archive/someone/old.md memory/sub/deep.md memory/notes.txt; do
        assert_eq "feature $rel" "$(cat "$base_dir/.cs/$rel" 2>/dev/null)" "$rel lands in the base" || return 1
    done
    assert_eq "base plan, feature edit" "$(cat "$base_dir/.cs/plans/base-plan.md")" "the edited plan lands" || return 1
    assert_eq "base summary, feature edit" "$(cat "$base_dir/.cs/summary.md")" "the edited summary lands" || return 1
    assert_output_contains "$output" "plans/base-plan.md was edited in the feature and not in the base; the feature's version is now in the base" \
        "the plan's replacement is named" || return 1
    assert_output_contains "$output" "summary.md was edited in the feature and not in the base; the feature's version is now in the base" \
        "the summary's replacement is named" || return 1
    assert_eq "# Session: proj" "$(cat "$base_dir/.cs/README.md")" "the base README is untouched" || return 1
    assert_output_not_contains "$output" "README" "the feature's own README is not mentioned" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_ignored_mode_carries_every_record_the_base_lacks

# What the fuse cannot carry without overwriting the base, it refuses to
# destroy: a plan both sides edited, a brief each side wrote, the feature's
# README once edited, a repository nested under .cs with its history, and a
# link. The refusal lists them all and nothing moves, not even what could go.
test_retire_ignored_mode_refuses_records_it_cannot_carry() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.cs/plans"
    echo "base plan" > "$base_dir/.cs/plans/base-plan.md"
    echo "# Session: proj" > "$base_dir/.cs/README.md"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "base plan, feature edit" > "$wt/.cs/plans/base-plan.md"
    echo "base plan, base edit" > "$base_dir/.cs/plans/base-plan.md"
    echo "feature brief" > "$wt/.cs/brief.md"
    echo "base brief" > "$base_dir/.cs/brief.md"
    echo "## Outcome" >> "$wt/.cs/README.md"
    mkdir -p "$wt/.cs/scratch-repo"
    (cd "$wt/.cs/scratch-repo" && git init -q && echo kept > kept.txt && git add kept.txt && git commit -q -m kept)
    ln -s "$base_dir/README.md" "$wt/.cs/plans/link.md"
    echo "could land" > "$wt/.cs/plans/new.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "5" "$(_feat_field "$line" 7)" "five files at risk: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Merge each into $base_dir/.cs by hand, or delete it from $wt/.cs, then run /finish t1 again:
.cs/README.md
.cs/brief.md
.cs/plans/base-plan.md
.cs/plans/link.md
.cs/scratch-repo/" "the refusal names all five" || return 1
    assert_eq "kept" "$(git -C "$wt/.cs/scratch-repo" show HEAD:kept.txt 2>/dev/null)" "the nested repository keeps its history" || return 1
    assert_eq "base plan, base edit" "$(cat "$base_dir/.cs/plans/base-plan.md")" "the base's plan is untouched" || return 1
    assert_file_not_exists "$base_dir/.cs/plans/new.md" "nothing was fused" || return 1
    assert_file_exists "$wt/.cs/plans/new.md" "and nothing was removed" || return 1
}

run_test test_retire_ignored_mode_refuses_records_it_cannot_carry

# .cs itself made a repository is refused whole: walked into, its .git would
# be copied into the base's .cs as files.
test_retire_ignored_mode_refuses_a_cs_that_is_itself_a_repository() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    (cd "$wt/.cs" && git init -q && git add memory/kept.md && git commit -q -m "notes history")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "then run /finish t1 again:
.cs/" "the refusal names .cs itself" || return 1
    assert_eq "notes history" "$(git -C "$wt/.cs" log -1 --format=%s 2>/dev/null)" ".cs keeps its history" || return 1
    assert_not_exists "$base_dir/.cs/.git" "the base's .cs gets no .git" || return 1
}

run_test test_retire_ignored_mode_refuses_a_cs_that_is_itself_a_repository

# A repo that tracks .cs carries it through git, so an untracked file under
# .cs is no more carried than one anywhere else: the retire refuses and names
# it. Only cs's own machine-local files (.cs/local, the locks) go with the
# worktree unasked.
test_retire_tracked_mode_refuses_untracked_session_records() {
    local base_dir wt sha output line status=0 rel
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@t1"
    wt="$CS_SESSIONS_ROOT/myproj@t1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: tracked" || return 1
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    mkdir -p "$wt/.cs/plans" "$wt/.cs/handoffs"
    for rel in plans/feat-plan.md memory/new-topic.md memory/narrative.someone.md handoffs/h.md summary.md; do
        echo "feature $rel" > "$wt/.cs/$rel"
    done
    : > "$wt/.cs/session.lock"
    sha=$(land_feature myproj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" myproj -features --porcelain 2>&1)
    assert_eq "5" "$(_feat_field "$line" 7)" "five files at risk: $line" || return 1
    output=$("$CS_BIN" myproj -retire-feature t1 "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Worktree has untracked files that removal would destroy; commit or remove them first:
.cs/handoffs/h.md
.cs/memory/narrative.someone.md
.cs/memory/new-topic.md
.cs/plans/feat-plan.md
.cs/summary.md" "the refusal names all five" || return 1
    assert_eq "feature plans/feat-plan.md" "$(cat "$wt/.cs/plans/feat-plan.md")" "the plan is still there" || return 1
    # Positive control: committed, they land with the feature and the worktree retires.
    (cd "$wt" && git add .cs && git commit -q -m "session records")
    sha=$(land_feature myproj t1) || { echo "  FAIL: second integrate"; return 1; }
    status=0
    output=$("$CS_BIN" myproj -retire-feature t1 "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "feature plans/feat-plan.md" "$(cat "$base_dir/.cs/plans/feat-plan.md")" "the plan landed" || return 1
}

run_test test_retire_tracked_mode_refuses_untracked_session_records

# cs writes the root CLAUDE.local.md with its protocol sentinel, and that copy
# goes with the worktree. One without the sentinel is the user's own: git
# keeps no copy of it, so the retire refuses and names it.
test_retire_refuses_a_user_authored_claude_local_md() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    assert_file_contains "$wt/CLAUDE.local.md" "cs:session-protocol" "cs wrote the protocol file" || return 1
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "my own notes for this checkout" > "$wt/CLAUDE.local.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Worktree has untracked files that removal would destroy; commit or remove them first:
CLAUDE.local.md" "the refusal names the file" || return 1
    assert_eq "my own notes for this checkout" "$(cat "$wt/CLAUDE.local.md")" "the notes are still there" || return 1
}

run_test test_retire_refuses_a_user_authored_claude_local_md

# Claude Code writes the permission grants made in a feature to its
# .claude/settings.local.json, which git does not carry. The retire adds each
# allow entry the base lacks to the base's file, after the base's own, and
# leaves every other key of both files where it is. Besides permissions.allow,
# the feature's file holds cs's autoMemoryDirectory (the worktree's own
# .cs/memory) and plansDirectory, and here a deny entry.
test_retire_carries_the_feature_permission_grants_into_the_base() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"env": {"A": "1"}, "permissions": {"allow": ["Bash(ls:*)", "Read"]}}' \
        > "$base_dir/.claude/settings.local.json"
    cs_launch "proj@t1"
    assert_eq "$wt/.cs/memory" "$(jq -r .autoMemoryDirectory "$wt/.claude/settings.local.json")" \
        "cs pointed the feature's memory at its own .cs" || return 1
    jq '.permissions = {allow: ["Bash(make:*)", "Read", "Bash(make:*)"], deny: ["Bash(rm:*)"]}' \
        "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '["Bash(ls:*)","Read","Bash(make:*)"]' "$(jq -c .permissions.allow "$base_dir/.claude/settings.local.json")" \
        "the grant survives after the base's own, once" || return 1
    assert_eq '{"A":"1"}' "$(jq -c .env "$base_dir/.claude/settings.local.json")" "the base's other keys stay" || return 1
    assert_eq '["env","permissions"]' "$(jq -c 'keys_unsorted' "$base_dir/.claude/settings.local.json")" \
        "no autoMemoryDirectory or plansDirectory from the feature" || return 1
    assert_eq '["allow"]' "$(jq -c '.permissions | keys' "$base_dir/.claude/settings.local.json")" \
        "and no deny entry" || return 1
}

run_test test_retire_carries_the_feature_permission_grants_into_the_base

# A base with no settings file gets one holding the feature's allow list only.
test_retire_creates_the_base_settings_with_the_feature_grants_alone() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    rm -rf "$base_dir/.claude"
    jq '.permissions.allow = ["Bash(make:*)"]' "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" \
        && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '{"permissions":{"allow":["Bash(make:*)"]}}' "$(jq -c . "$base_dir/.claude/settings.local.json" 2>&1)" \
        "the base's file holds the grant and nothing else" || return 1
}

run_test test_retire_creates_the_base_settings_with_the_feature_grants_alone

# A settings file the union cannot read, the feature's or the base's, refuses
# the retire before anything is removed and names the file.
test_retire_refuses_a_settings_file_it_cannot_read() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 before
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": ["Read"]}}' > "$base_dir/.claude/settings.local.json"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    printf '{' > "$wt/.claude/settings.local.json"
    before=$(cat "$base_dir/.claude/settings.local.json")
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Error: $wt/.claude/settings.local.json is not valid JSON, or its permissions.allow is not a list, so cs cannot add the feature's permission grants to $base_dir/.claude/settings.local.json. Nothing was removed. Fix it, then run /finish t1 again." \
        "the refusal names the feature's file" || return 1
    assert_dir "$wt/.cs/memory" "the worktree is still there" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as it was" || return 1

    printf '%s\n' '{"permissions": {"allow": ["Bash(make:*)"]}}' > "$wt/.claude/settings.local.json"
    printf '%s\n' '{"permissions": {"allow": "Read"}}' > "$base_dir/.claude/settings.local.json"
    before=$(cat "$base_dir/.claude/settings.local.json")
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Error: $base_dir/.claude/settings.local.json is not valid JSON, or its permissions.allow is not a list, so cs cannot add the feature's permission grants to $base_dir/.claude/settings.local.json. Nothing was removed. Fix it, then run /finish t1 again." \
        "the refusal names the base's file" || return 1
    assert_dir "$wt/.cs/memory" "the worktree is still there" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as it was" || return 1
}

run_test test_retire_refuses_a_settings_file_it_cannot_read

# A settings file the repository tracks is carried by git like any other
# file: the retire leaves the base's as the integrate and the base's own
# commits made it, and does not bring back a grant the base dropped since.
test_retire_leaves_a_tracked_settings_file_to_git() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 before
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": ["Read", "Bash(old:*)"]}}' > "$base_dir/.claude/settings.local.json"
    (cd "$base_dir" && git add -f .claude/settings.local.json && git commit -q -m "share settings")
    cs_launch "proj@t1"
    jq '.permissions.allow += ["Bash(make:*)"]' "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" \
        && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt .claude/settings.local.json && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    jq '.permissions.allow -= ["Bash(old:*)"]' "$base_dir/.claude/settings.local.json" > "$base_dir/.claude/s.json" \
        && mv "$base_dir/.claude/s.json" "$base_dir/.claude/settings.local.json"
    (cd "$base_dir" && git commit -q -m "drop a grant" -- .claude/settings.local.json)
    before=$(cat "$base_dir/.claude/settings.local.json")
    assert_eq '["Read","Bash(make:*)"]' "$(jq -c .permissions.allow "$base_dir/.claude/settings.local.json")" \
        "the integrate landed the feature's grant" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as git left it" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .claude)" "and the base's checkout is clean" || return 1
}

run_test test_retire_leaves_a_tracked_settings_file_to_git

# The record of what the feature inherited is what tells a deleted topic from
# a new one. A record that is there and cannot be read must stop the fuse:
# guessing "new" would bring the deleted topic back and report success.
test_retire_ignored_mode_refuses_when_the_inherited_record_cannot_be_read() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    rm "$base_dir/.cs/memory/gone.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    find "$wt/.cs/local/inherited-topics" -type f -exec chmod 000 {} +
    [ ! -r "$wt/.cs/local/inherited-topics/gone.md" ] || return 77
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    find "$CS_SESSIONS_ROOT" -path '*/local/inherited-topics/*' -type f -exec chmod 600 {} + 2>/dev/null
    assert_eq "1" "$status" "the retire fails: $output" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/gone.md" "the deleted topic did not come back" || return 1
    assert_output_contains "$output" "could not read what the feature inherited for memory/gone.md" \
        "the error names the topic" || return 1
    assert_output_contains "$output" "Could not classify the session records in $wt/.cs; nothing was removed" \
        "the retire refuses before it removes anything" || return 1
    assert_dir "$wt/.cs/memory" "the worktree and its records are still there" || return 1
}

run_test test_retire_ignored_mode_refuses_when_the_inherited_record_cannot_be_read

# The same when the record directory itself cannot be searched: a file that
# cannot be seen inside it is not a topic the feature wrote.
test_retire_ignored_mode_refuses_when_the_inherited_directory_cannot_be_searched() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    rm "$base_dir/.cs/memory/gone.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    chmod 000 "$wt/.cs/local/inherited-topics"
    if [ -e "$wt/.cs/local/inherited-topics/gone.md" ]; then
        chmod 700 "$wt/.cs/local/inherited-topics"; return 77
    fi
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    find "$CS_SESSIONS_ROOT" -type d -name inherited-topics -exec chmod 700 {} + 2>/dev/null
    assert_eq "1" "$status" "the retire fails: $output" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/gone.md" "the deleted topic did not come back" || return 1
    assert_output_contains "$output" "could not read what the feature inherited for memory/gone.md" \
        "the error names the topic" || return 1
    assert_dir "$wt/.cs/memory" "the worktree and its records are still there" || return 1
}

run_test test_retire_ignored_mode_refuses_when_the_inherited_directory_cannot_be_searched

# The list of files a removal would destroy is read as bytes. In a locale
# that cannot decode a name, a failed conversion must never read as "nothing
# to lose": the retire would force-remove the worktree and the user's
# untracked file with it.
test_retire_keeps_untracked_work_when_a_name_does_not_decode_in_the_locale() {
    # A multibyte locale that is not UTF-8 and in which bash still parses cs.
    local loc
    loc=$(locale -a 2>/dev/null | grep -m1 -x -e 'zh_CN\.GBK' -e 'ja_JP\.SJIS' -e 'zh_TW\.Big5') || true
    [ -n "$loc" ] || { echo "    SKIP (no GBK, SJIS or Big5 locale here)"; return 77; }
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    (cd "$base_dir" && echo 'secret.env' >> .gitignore && git commit -q -am "ignore the env file")
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "snow" > "$wt/.cs/memory/$(printf '\342\230\203').md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    # Ignored, so git lists it after the .cs entries: past the name the
    # conversion stops on.
    echo "valuable" > "$wt/secret.env"
    output=$(LC_ALL="$loc" "$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "valuable" "$(cat "$wt/secret.env" 2>/dev/null)" "the ignored file is still there" || return 1
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "secret.env" "and names the file" || return 1
}

run_test test_retire_keeps_untracked_work_when_a_name_does_not_decode_in_the_locale

test_retire_fuse_survives_a_torn_timeline_tail() {
    # A crash mid-append leaves a last line with no newline. Appending onto it
    # splices two records into one, and the reader's tolerant `fromjson? //
    # empty` then drops BOTH — the splice and the record that followed it.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add -A && git commit -q -m init)
    # Torn tail: the last record has no terminating newline.
    printf '{"event":"base-last"}' > "$base_dir/.cs/timeline.jsonl"
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '{"event":"from-task"}\n' > "$wt/.cs/timeline.jsonl"
    # Fixture sanity: the base tail really is unterminated, or the splice the
    # test is about cannot happen.
    assert_eq "}" "$(tail -c 1 "$base_dir/.cs/timeline.jsonl")" \
        "fixture must leave the base timeline unterminated" || return 1

    local output merge_status
    local sha
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1)
    merge_status=$?
    assert_eq "0" "$merge_status" "retire exits 0" \
        || { echo "  retire output: $output"; return 1; }

    # Parse the way cs reads it: one record per line, malformed lines dropped.
    local events
    events=$(jq -rRs '[split("\n")[] | select(length > 0) | (fromjson? // empty) | .event] | join(",")' \
        "$base_dir/.cs/timeline.jsonl" 2>/dev/null)
    assert_output_contains "$events" "base-last" \
        "the torn base record must survive the fuse" || return 1
    assert_output_contains "$events" "from-task" \
        "the fused record must survive the fuse" || return 1
}

run_test test_retire_fuse_survives_a_torn_timeline_tail

# Whether the retire fuses .cs or leaves it to git depends on the mode the
# create recorded. A state file without one says neither, so nothing under
# .cs is known to be carried: the retire refuses and the worktree stays.
test_retire_refuses_a_worktree_whose_state_names_no_mode() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "feature topic" > "$wt/.cs/memory/new.md"
    grep -v '^cs_mode:' "$wt/.cs/local/state" > "$wt/.cs/local/state.tmp"
    mv "$wt/.cs/local/state.tmp" "$wt/.cs/local/state"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "$wt/.cs/local/state names no cs_mode, so cs cannot tell whether git or the record fuse carries $wt/.cs; nothing was removed" \
        "the refusal names the state file" || return 1
    assert_eq "feature topic" "$(cat "$wt/.cs/memory/new.md" 2>/dev/null)" "the feature's topic is still there" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/new.md" "and nothing was fused" || return 1
}

run_test test_retire_refuses_a_worktree_whose_state_names_no_mode

# A tracked file marked skip-worktree (or assume-unchanged) hides its edit
# from git diff, and git keeps no copy of the edit: removal would destroy it.
test_retire_refuses_an_edit_git_diff_does_not_show() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    echo "default: 1" > "$base_dir/config.yml"
    echo "default: 2" > "$base_dir/other.yml"
    ln -s defaults-a "$base_dir/profile"
    printf 'defaults-a' > "$base_dir/alias"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    git -C "$wt" update-index --skip-worktree config.yml
    echo "local: tuned" >> "$wt/config.yml"
    git -C "$wt" update-index --assume-unchanged other.yml
    echo "local: tuned too" >> "$wt/other.yml"
    git -C "$wt" update-index --assume-unchanged profile
    ln -sfn defaults-b "$wt/profile"
    # A link whose target spells the file's old bytes: same blob, other type.
    git -C "$wt" update-index --assume-unchanged alias
    rm "$wt/alias" && ln -s defaults-a "$wt/alias"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Worktree has edits git diff does not show (skip-worktree or assume-unchanged), which removal would destroy; commit them, or undo them and clear the flag (git update-index --no-skip-worktree / --no-assume-unchanged), first:" \
        "the refusal says why" || return 1
    assert_eq "alias
config.yml
other.yml
profile" "$(printf '%s\n' "$output" | awk 'listed; /first:$/ { listed = 1 }')" "the refusal names the two files, the retargeted link and the file now a link" || return 1
    assert_eq "default: 1
local: tuned" "$(cat "$wt/config.yml")" "the edit is still there" || return 1
    assert_eq "defaults-b" "$(readlink "$wt/profile")" "the link still has its new target" || return 1
    # Positive control: an unedited flagged file or link is no reason to refuse.
    git -C "$wt" update-index --no-assume-unchanged other.yml
    git -C "$wt" checkout -q -- other.yml
    git -C "$wt" show HEAD:config.yml > "$wt/config.yml"
    ln -sfn defaults-a "$wt/profile"
    rm "$wt/alias" && printf 'defaults-a' > "$wt/alias"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "an unedited flagged file retires: $output" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_refuses_an_edit_git_diff_does_not_show

# An initialised submodule is a checkout of its own: git ls-files in the
# worktree does not list the files inside it, and removal destroys them.
test_retire_refuses_untracked_and_ignored_work_inside_a_submodule() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" lib="$TEST_TMPDIR/sublib"
    local sha output status=0
    mkdir -p "$lib"
    (cd "$lib" && git init -q && git config core.autocrlf false && echo lib > lib.txt \
        && printf '*.env\n' > .gitignore && git add -A && git commit -q -m lib)
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init \
        && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
            git submodule add -q "$lib" sub && git commit -q -m "add submodule") \
        || { echo "  FAIL: submodule fixture"; return 1; }
    cs_launch "proj@t1"
    (cd "$wt" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
        git submodule update --init -q) \
        || { echo "  FAIL: submodule fixture"; return 1; }
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "secret" > "$wt/sub/secret.env"
    echo "notes" > "$wt/sub/notes.txt"
    # The integrate updates submodules in its temporary worktree.
    sha=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
        land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Worktree has untracked files that removal would destroy; commit or remove them first:
sub/notes.txt
sub/secret.env" "the refusal names both files inside the submodule" || return 1
    assert_eq "secret" "$(cat "$wt/sub/secret.env" 2>/dev/null)" "the ignored file is still there" || return 1
    # Positive control: an initialised submodule holding nothing extra retires.
    rm "$wt/sub/secret.env" "$wt/sub/notes.txt"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "a clean submodule retires: $output" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_refuses_untracked_and_ignored_work_inside_a_submodule

test_rm_worktree_unregisters_and_prompts_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Confirm removal, decline branch deletion
    printf 'y\nn\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm "myproj@fix-auth" > /dev/null 2>&1
    assert_not_exists "$wt" "worktree dir removed" || return 1
    git -C "$base_dir" worktree list --porcelain | grep -q "myproj@fix-auth" \
        && { echo "  FAIL: worktree still registered"; return 1; }
    assert_eq "  cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth)" \
        "branch kept when declined" || return 1
}

test_rm_worktree_force_noninteractive_keeps_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"

    "$CS_BIN" -rm "myproj@fix-auth" --force </dev/null >/dev/null 2>&1 || return 1

    assert_not_exists "$wt" "worktree dir removed" || return 1
    git -C "$base_dir" worktree list --porcelain | grep -q "myproj@fix-auth" \
        && { echo "  FAIL: worktree still registered"; return 1; }
    # The nested branch-delete question defaults to NO under --force: this
    # assertion pins that rule, not just that removal succeeded.
    assert_eq "  cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth)" \
        "branch kept under --force with no tty" || return 1
}

run_test test_rm_worktree_unregisters_and_prompts_branch
run_test test_rm_worktree_force_noninteractive_keeps_branch

test_doctor_flags_dangling_and_merged_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@done-task"
    # Simulate a completed-but-unmerged-cleanup state: merge manually.
    # --no-ff so the base HEAD moves past the branch tip; a fast-forward
    # would leave tip == HEAD, indistinguishable from a fresh worktree.
    (cd "$CS_SESSIONS_ROOT/myproj@done-task" && echo x > f && git add f && git commit -q -m t)
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/done-task)
    # And a dangling dir that git does not know about
    mkdir -p "$CS_SESSIONS_ROOT/myproj@ghost/.cs/local"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_contains "$output" "ghost" "dangling @-dir flagged" || return 1
    assert_output_contains "$output" "myproj@done-task branch cs/done-task is fully merged" \
        "merged-but-present worktree flagged" || return 1
}

run_test test_doctor_flags_dangling_and_merged_worktrees

test_doctor_fresh_worktree_not_flagged_merged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fresh-task"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_not_contains "$output" "fully merged" \
        "fresh worktree (tip == base HEAD) must not read as merged" || return 1
    assert_output_contains "$output" "Worktrees: myproj@fresh-task on cs/fresh-task" \
        "fresh worktree reported OK" || return 1
}

run_test test_doctor_fresh_worktree_not_flagged_merged


test_retire_refuses_untracked_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "committed" > "$wt/done.txt"
    (cd "$wt" && git add done.txt && git commit -q -m work)
    echo "precious" > "$wt/never-added.txt"   # untracked user work
    local output status=0
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: retire must refuse"; return 1; }
    assert_output_contains "$output" "untracked" "refusal names the problem" || return 1
    assert_output_contains "$output" "never-added.txt" "refusal names the exact path" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_eq "precious" "$(cat "$wt/never-added.txt")" "untracked work survives" || return 1
}

run_test test_retire_refuses_untracked_worktree

test_worktree_secrets_flag_targets_base_namespace() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create the worktree first
    local output
    output=$("$CS_BIN" "myproj@fix-auth" -secrets list 2>&1)
    assert_output_contains "$output" "session: myproj" \
        "worktree -secrets flag must target the base namespace" || return 1
    assert_output_not_contains "$output" "session: myproj@fix-auth" \
        "must not target the nonexistent worktree namespace" || return 1
}

run_test test_worktree_secrets_flag_targets_base_namespace

# Codex r3 #3: a worktree's secrets route to the base session, so the base
# is vetted too; a base link out of the session refuses the verb.
test_worktree_secrets_flag_vets_the_base_session() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local outside="$TEST_TMPDIR/outside-private" output status=0
    mkdir -p "$outside"
    ln -s "$outside" "$CS_SESSIONS_ROOT/myproj/.cs/private"
    output=$("$CS_BIN" "myproj@fix-auth" -secrets list 2>&1) || status=$?
    assert_eq "1" "$status" "cs should exit 1" || return 1
    assert_eq "Error: .cs/private is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$output" "the refusal names the base's link" || return 1
}

run_test test_worktree_secrets_flag_vets_the_base_session


test_worktree_create_dirty_base_consent_yes() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "wip" >> "$base_dir/CLAUDE.md"
    local output status=0
    output=$(printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" "myproj@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "consented creation should launch, got: $output" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@t1" "worktree created after consent" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/myproj@t1/.cs/local/state" "task_branch: cs/t1" \
        "worktree fully initialized" || return 1
}

test_worktree_create_dirty_base_consent_no() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "wip" >> "$base_dir/CLAUDE.md"
    local output status=0
    output=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" "myproj@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "declined consent cancels cleanly, got: $output" || return 1
    assert_output_contains "$output" "Cancelled" "cancel message shown" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@t1" "no worktree without consent" || return 1
}

run_test test_worktree_create_dirty_base_consent_yes
run_test test_worktree_create_dirty_base_consent_no
run_test test_session_repo_pins_autocrlf_off
run_test test_worktree_excludes_protocol_file

test_features_lists_only_verified_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    # A directory that looks like a worktree but was never registered with git.
    mkdir -p "$CS_SESSIONS_ROOT/myproj@hand-made/.cs/local"
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_output_contains "$output" "fix-auth" "a registered worktree is listed" || return 1
    assert_output_not_contains "$output" "hand-made" "an unregistered lookalike must be excluded" || return 1
}

run_test test_features_lists_only_verified_worktrees

test_features_is_empty_for_a_base_with_no_worktrees() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_eq "" "$output" "a base with no features prints nothing" || return 1
}

run_test test_features_is_empty_for_a_base_with_no_worktrees

test_features_excludes_a_lookalike_whose_name_prefixes_a_real_one() {
    # The verification compares whole lines. A one-sided anchor would verify
    # "wip" against the registered "wip-2", which is precisely the unregistered
    # directory this function exists to exclude. Prefix-colliding task names are
    # ordinary, so this is a realistic collision, not a contrived one.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@wip-2"
    mkdir -p "$CS_SESSIONS_ROOT/myproj@wip/.cs/local"
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_output_contains "$output" "wip-2" "the registered worktree is listed" || return 1
    assert_output_not_contains "$output" $'^wip\t' "an unregistered prefix must not verify" || return 1
}

run_test test_features_excludes_a_lookalike_whose_name_prefixes_a_real_one

test_features_untracked_is_not_reported_as_dirty() {
    # _tree_is_dirty deliberately excludes untracked files: a worktree holding
    # only untracked files is NOT dirty, but is still refused, by a different
    # gate with a different message. A porcelain-non-empty test would conflate
    # them and the screen would disagree with the gate.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    echo "scratch" > "$CS_SESSIONS_ROOT/myproj@fix-auth/notes.txt"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 6)" "untracked files must not set wt_dirty" || return 1
    assert_eq "1" "$(_feat_field "$line" 7)" "the untracked file must be counted" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state must name the untracked gate" || return 1
}

run_test test_features_untracked_is_not_reported_as_dirty

# The features screen reads the same fact the retire refuses on.
test_features_reports_an_edit_git_diff_does_not_show_as_dirty() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" line
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    echo "default: 1" > "$base_dir/config.yml"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    git -C "$wt" update-index --skip-worktree config.yml
    echo "local: tuned" >> "$wt/config.yml"
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "1" "$(_feat_field "$line" 6)" "wt_dirty: $line" || return 1
    assert_eq "dirty" "$(_feat_field "$line" 10)" "state: $line" || return 1
}

run_test test_features_reports_an_edit_git_diff_does_not_show_as_dirty

test_features_does_not_count_the_bookkeeping_the_merge_gate_skips() {
    # A worktree created before cs excluded its own bookkeeping still has .cs/
    # untracked. The merge gate filters exactly that set and would succeed, so
    # readiness reporting "blocked" sends the user hunting for work to commit
    # that is not theirs and does not exist.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"

    local exclude
    exclude=$( (cd "$wt" && git rev-parse --git-path info/exclude) 2>/dev/null )
    case "$exclude" in /*|[A-Za-z]:[\\/]*) : ;; *) exclude="$wt/$exclude" ;; esac
    grep -v -e '^\.cs/$' -e '^\.claude/settings\.local\.json$' "$exclude" > "$exclude.tmp" 2>/dev/null || true
    mv "$exclude.tmp" "$exclude"
    # Fixture sanity: without the entry the skeleton really is untracked again,
    # so the readiness path is reached with something to filter.
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    case "$others" in
        *.cs/*) : ;;
        *) echo "  FAIL: fixture did not reproduce the untracked .cs skeleton"; return 1 ;;
    esac

    local line
    line=$("$CS_BIN" "proj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 7)" \
        "cs's own bookkeeping is not untracked work" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" \
        "readiness must agree with the gate that would let this merge through" || return 1
}

run_test test_features_does_not_count_the_bookkeeping_the_merge_gate_skips

test_features_still_counts_real_untracked_work_in_an_old_worktree() {
    # The filter is scoped to cs's bookkeeping. A file the user would lose must
    # still show up in the count and in the state, or readiness becomes a lie in
    # the other direction.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "unsaved" > "$wt/notes.txt"
    local line
    line=$("$CS_BIN" "proj" -features --porcelain 2>/dev/null)
    assert_eq "1" "$(_feat_field "$line" 7)" "the user's file is still counted" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state must name the untracked gate" || return 1
}

run_test test_features_still_counts_real_untracked_work_in_an_old_worktree

test_features_fresh_worktree_is_not_already_merged() {
    # A fresh worktree's branch sits AT base HEAD, where merge-base
    # --is-ancestor is also true. Reporting that as already-merged is
    # destructive: cs reads is-ancestor as "already merged; cleaning up" and
    # removes the worktree and deletes the branch.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 4)" "a branch AT base HEAD is not already merged" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "a fresh clean worktree is ready" || return 1
}

run_test test_features_fresh_worktree_is_not_already_merged

test_features_reports_a_branch_strictly_behind_as_merged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/fix-auth)
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "1" "$(_feat_field "$line" 4)" "a tip strictly behind base HEAD is merged" || return 1
    assert_eq "merged" "$(_feat_field "$line" 10)" "state must say merged" || return 1
}

run_test test_features_reports_a_branch_strictly_behind_as_merged

test_features_counts_commits_ahead() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo one > "$wt/a.txt"; (cd "$wt" && git add -A && git commit -q -m one)
    echo two > "$wt/b.txt"; (cd "$wt" && git add -A && git commit -q -m two)
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "2" "$(_feat_field "$line" 3)" "two commits ahead of base HEAD" || return 1
    assert_eq "cs/fix-auth" "$(_feat_field "$line" 2)" "branch comes from the state pin" || return 1
}

run_test test_features_counts_commits_ahead

test_features_reports_a_live_worktree_lock_distinctly() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    rm -f "$wt/.cs/session.lock"
    assert_eq "worktree" "$(_feat_field "$line" 9)" "a live lock on the feature worktree is lock=worktree" || return 1
    assert_eq "locked" "$(_feat_field "$line" 10)" "a live worktree lock sets state=locked" || return 1
}

run_test test_features_reports_a_live_worktree_lock_distinctly

test_features_reports_a_live_base_lock_distinctly() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    echo "$$" > "$base_dir/.cs/session.lock"   # this test process is alive
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    rm -f "$base_dir/.cs/session.lock"
    assert_eq "base" "$(_feat_field "$line" 9)" "a live lock on the base is lock=base" || return 1
    assert_eq "locked" "$(_feat_field "$line" 10)" "a live base lock sets state=locked" || return 1
}

run_test test_features_reports_a_live_base_lock_distinctly

test_features_ignores_a_dead_lock_pid() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local dead_pid
    dead_pid=$(bash -c 'echo $$')
    if kill -0 "$dead_pid" 2>/dev/null; then
        echo "  SKIP: PID $dead_pid is unexpectedly alive"
        return 77
    fi
    echo "$dead_pid" > "$wt/.cs/session.lock"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "none" "$(_feat_field "$line" 9)" "a dead pid must not be reported as a lock" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "a dead pid must not set state=locked" || return 1
}

run_test test_features_ignores_a_dead_lock_pid

test_features_human_table_names_the_state() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj" -features 2>&1)
    assert_output_contains "$output" "FEATURE" "the table carries a header" || return 1
    assert_output_contains "$output" "fix-auth" "the feature is listed" || return 1
    assert_output_contains "$output" "ready" "the state is named" || return 1
}

run_test test_features_human_table_names_the_state

test_finish_arms_the_ritual_without_merging() {
    # -finish opens the base with the ritual armed. It must not merge: the
    # branch is still unmerged and the worktree still exists afterwards.
    # The base session directory already exists (created by
    # create_test_session_with_git below), so this launch is a resume, not a
    # fresh session: it hits the "Continue previous conversation?" prompt, so
    # stdin needs an answer rather than an immediate EOF (< /dev/null exits
    # the launch at that prompt before the exec line is ever reached).
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "" 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "the launch prompt must arm the ritual" || return 1
    assert_dir "$wt" "the worktree must survive -finish" || return 1
    assert_file_not_exists "$base_dir/auth.txt" "-finish must not merge" || return 1
}

run_test test_finish_arms_the_ritual_without_merging

test_finish_survives_declining_the_resume() {
    # Answering n takes _exec_fresh_rebind, which builds its OWN prompt chain.
    # Missing it drops the merge intent silently on a routine answer.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' \
        > "$CS_SESSIONS_ROOT/myproj/.cs/local/state"
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "n" 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "a declined resume must keep the merge kick" || return 1
}

run_test test_finish_survives_declining_the_resume

test_finish_rejects_an_unknown_feature() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -finish "no-such-feature" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "no-such-feature" "the refusal must name the feature" || return 1
}

run_test test_finish_rejects_an_unknown_feature

test_finish_rejects_a_prefix_lookalike() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@wip-2"
    local output
    output=$("$CS_BIN" "myproj" -finish "wip" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "No feature worktree 'wip'" \
        "a prefix of a real feature must be refused" || return 1
}

run_test test_finish_rejects_a_prefix_lookalike

test_finish_rejects_a_traversal_feature_name() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -finish "../escape" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "feature name" "a path separator must be rejected" || return 1
}

run_test test_finish_rejects_a_traversal_feature_name

test_finish_warns_when_it_displaces_a_spawn_kick() {
    # Both ride claude's single prompt slot. The merge kick wins because the
    # user took the action seconds ago — but the displacement must not be
    # silent, and the warning must not promise the queue runs after the merge:
    # the drain is the Stop hook, which fires at the first turn end.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    # The seed as cs -spawn writes it (line 1 the token, line 2 the spawner),
    # opened as the spawn's own window via CS_SPAWN_TOKEN, so the seed is
    # consumed unasked and the two kicks compete.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'feedfacefeedfacefeedfacefeedface\nother-session\nfirst staged task\n' > "$CS_SESSIONS_ROOT/.spawn/myproj.seed"
    local output
    output=$(CS_SPAWN_TOKEN=feedfacefeedfacefeedfacefeedface "$CS_BIN" "myproj" -finish "fix-auth" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "the merge kick takes the slot" || return 1
    assert_output_contains "$output" "walk-away queue is armed" "the displacement must be announced" || return 1
    assert_output_not_contains "$output" "after the merge" "must not promise sequencing it cannot enforce" || return 1
}

run_test test_finish_warns_when_it_displaces_a_spawn_kick

# A worktree open runs no migrate_session, so Phase 8 never binds a transcript
# for it. With the recorded id gone and a conversation on disk, the open offers
# that conversation rather than starting a new one over it.
test_worktree_without_its_recorded_id_binds_the_folders_conversation() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" state uuid="55555555-5555-4555-8555-555555555555"
    state="$wt/.cs/local/state"
    awk 'index($0, "claude_session_id:") != 1' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$wt")"
    mkdir -p "$proj"
    printf '{"type":"user","sessionId":"%s"}\n' "$uuid" > "$proj/$uuid.jsonl"
    local output
    output=$("$CS_BIN" "myproj@fix-auth" <<< "" 2>&1 || true)
    assert_output_contains "$output" "Bound claude_session_id in .cs/local/state to $uuid" "the open binds the transcript it found" || return 1
    assert_output_contains "$output" "Continue previous conversation?" "a real conversation is offered" || return 1
    assert_output_contains "$output" "--resume $uuid" "the default answer resumes it" || return 1
    assert_eq "$uuid" "$(awk '/^claude_session_id:/ { print $2; exit }' "$state")" "the binding is recorded" || return 1
}

run_test test_worktree_without_its_recorded_id_binds_the_folders_conversation

test_finish_yields_to_an_explicit_rotation_choice() {
    # r is the user explicitly choosing the rotation handoff at the prompt;
    # a merge armed moments earlier must not silently override that choice.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    # The prompt belongs to a session with a conversation to resume; one with
    # none starts its first without asking. Record the one the handoff's
    # parent names.
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' >> "$base_dir/.cs/local/state"
    mkdir -p "$base_dir/.cs/handoffs"
    cat > "$base_dir/.cs/handoffs/2026-07-16-test.md" << 'EOF'
---
parent: 00000000-0000-4000-8000-000000000000
created: 2026-07-16T10:00:00Z
purpose: test rotation
status: unconsumed
---

## 7. Next Step
Continue the test.
EOF
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "r" 2>&1 || true)
    assert_output_contains "$output" "Rotation handoff takes this launch; re-run: cs myproj -finish fix-auth" \
        "the displaced merge must be announced" || return 1
    assert_output_not_contains "$output" "/finish fix-auth" "the explicit r choice must not be overridden" || return 1
    assert_output_contains "$output" ".cs/handoffs/2026-07-16-test.md" "the handoff prompt must run instead" || return 1
}

run_test test_finish_yields_to_an_explicit_rotation_choice

test_features_table_says_one_file_not_one_files() {
    # The count comes from git, so 1 is an ordinary value. The TUI and this
    # table must word it identically or the same fact reads two ways.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    echo "scratch" > "$CS_SESSIONS_ROOT/myproj@fix-auth/notes.txt"
    local output
    output=$("$CS_BIN" "myproj" -features 2>&1)
    assert_output_not_contains "$output" "1 files" "singular count must not say files" || return 1
    assert_output_contains "$output" "1 file untracked" "expected the singular form" || return 1
}

run_test test_features_table_says_one_file_not_one_files

# --- -integrate-feature --from-remote: land a PR's merge commit ---

# Base + feature + a bare origin that already carries the base branch. Prints
# the feature SHA. The caller lands the PR on origin however the scenario
# needs (merge commit, squash) and fetches.
integrate_remote_fixture() {  # base task
    local sha base_dir origin
    sha=$(integrate_fixture "$1" "$2")
    base_dir="$CS_SESSIONS_ROOT/$1"
    origin="$TEST_TMPDIR/origin.git"
    git init -q --bare "$origin"
    git -C "$base_dir" remote add origin "$origin"
    git -C "$base_dir" push -q origin HEAD >/dev/null 2>&1
    git -C "$base_dir" push -q origin "cs/$2" >/dev/null 2>&1
    printf '%s\n' "$sha"
}

# Land the feature on origin's base branch the way a merged PR does (a merge
# commit), through a throwaway clone. Prints the landing commit.
land_pr_on_origin() {  # base_dir task [--squash]
    local base_dir="$1" task="$2" how="${3:-}" clone branch
    branch=$(git -C "$base_dir" symbolic-ref --short HEAD)
    clone="$TEST_TMPDIR/pr-clone"
    rm -rf "$clone"
    git clone -q "$TEST_TMPDIR/origin.git" "$clone" 2>/dev/null
    git -C "$clone" checkout -q "$branch"
    if [ "$how" = "--squash" ]; then
        git -C "$clone" merge -q --squash "origin/cs/$task" >/dev/null 2>&1
        git -C "$clone" commit -q -m "feature ($task) (#7)"
    else
        git -C "$clone" merge -q --no-ff --no-edit -m "Merge pull request #7 from example-org/cs/$task" "origin/cs/$task"
    fi
    git -C "$clone" push -q origin "$branch" >/dev/null 2>&1
    git -C "$clone" rev-parse HEAD
}

test_integrate_from_remote_fast_forwards_onto_the_pr_merge_commit() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true 2>&1) || status=$?
    assert_eq "0" "$status" "remote landing succeeds: $output" || return 1
    assert_eq "$M" "$(git -C "$base_dir" rev-parse HEAD)" "base fast-forwards to the PR merge commit, no extra commit" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content on base" || return 1
    git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD \
        || { echo "  FAIL: F should be an ancestor after a merge-commit landing"; return 1; }
    assert_output_contains "$output" "integrated fix-auth $M -> $M" "summary line" || return 1
}

test_integrate_from_remote_after_a_local_integrate_still_lands() {
    # grok's inoperability case: base has a commit origin lacks, so a
    # whole-branch --ff-only would refuse forever. Merging the PR's landing
    # commit as an ordinary merge must still work.
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "local only")
    local L
    L=$(git -C "$base_dir" rev-parse HEAD)
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true 2>&1) || status=$?
    assert_eq "0" "$status" "mixed landing succeeds: $output" || return 1
    git -C "$base_dir" merge-base --is-ancestor "$M" HEAD \
        || { echo "  FAIL: the PR merge commit must be reachable from base HEAD"; return 1; }
    git -C "$base_dir" merge-base --is-ancestor "$L" HEAD \
        || { echo "  FAIL: the base's local-only commit must survive the landing"; return 1; }
    assert_file_exists "$base_dir/feature.txt" "feature content on base" || return 1
}

# The entry never sees CI; the skill does, through finish.sh's pr_checks, and
# says so with --ci-green. Only then, and only when the base has nothing origin
# lacks (the temp merge is a fast-forward onto the PR's landing commit, the
# tree those checks ran on), is the local gate redundant: it would repeat the
# checks in a clean checkout that lacks the project's gitignored dependencies.
test_integrate_from_remote_skips_the_gate_with_ci_green_when_base_is_an_ancestor() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote --ci-green -- sh -c 'touch "$0/gate-ran"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "remote landing succeeds: $output" || return 1
    assert_not_exists "$TEST_TMPDIR/gate-ran" "the gate did not run" || return 1
    assert_output_contains "$output" "gate skipped" "the report says the gate was skipped" || return 1
    assert_output_contains "$output" "checks passed" "and why: the PR's checks passed on that tree" || return 1
    assert_eq "$M" "$(git -C "$base_dir" rev-parse HEAD)" "base still fast-forwards to the PR merge commit" || return 1
}

# Without --ci-green nothing vouches for the landing commit: a merged PR with
# absent, failed or bypassed checks keeps its gate.
test_integrate_from_remote_runs_the_gate_without_ci_green() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- sh -c 'touch "$0/gate-ran"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "remote landing succeeds: $output" || return 1
    assert_exists "$TEST_TMPDIR/gate-ran" "the gate ran" || return 1
    assert_output_not_contains "$output" "gate skipped" "no skip reported" || return 1
}

# The base's own commit changes the merged tree, so the checks that passed on
# origin say nothing about it and the gate must still run.
test_integrate_from_remote_runs_the_gate_when_base_diverged() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    echo "local change" > "$base_dir/local.txt"
    (cd "$base_dir" && git add local.txt && git commit -q -m "local only")
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote --ci-green -- sh -c 'touch "$0/gate-ran"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "mixed landing succeeds: $output" || return 1
    assert_exists "$TEST_TMPDIR/gate-ran" "the gate ran on the merge the checks never saw" || return 1
    assert_output_not_contains "$output" "gate skipped" "no skip reported" || return 1
}

# --ci-green describes a PR, so it means nothing on the local path.
test_integrate_refuses_ci_green_without_from_remote() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" --ci-green -- true 2>&1) || status=$?
    assert_eq "1" "$status" "refuses" || return 1
    assert_output_contains "$output" "--ci-green needs --from-remote" "names the rule" || return 1
}

test_integrate_from_remote_refuses_a_commit_origin_does_not_have() {
    local sha base_dir output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    git -C "$base_dir" fetch -q origin
    # F is on origin/cs/fix-auth but NOT on origin/<base branch>.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" --from-remote -- true 2>&1) || status=$?
    assert_eq "1" "$status" "refuses" || return 1
    assert_output_contains "$output" "not reachable from origin/" "names the remote branch" || return 1
}

test_integrate_from_remote_squash_leaves_feature_tip_unintegrated() {
    # The squash case the skill must report: M lands, F is not an ancestor.
    local sha base_dir M status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth --squash)
    git -C "$base_dir" fetch -q origin
    "$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true >/dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "squash landing succeeds" || return 1
    assert_file_exists "$base_dir/feature.txt" "content landed" || return 1
    if git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        echo "  FAIL: after a squash F must NOT be an ancestor (the report depends on it)"; return 1
    fi
}

run_test test_integrate_from_remote_fast_forwards_onto_the_pr_merge_commit
run_test test_integrate_from_remote_after_a_local_integrate_still_lands
run_test test_integrate_from_remote_skips_the_gate_with_ci_green_when_base_is_an_ancestor
run_test test_integrate_from_remote_runs_the_gate_without_ci_green
run_test test_integrate_from_remote_runs_the_gate_when_base_diverged
run_test test_integrate_refuses_ci_green_without_from_remote
run_test test_integrate_from_remote_refuses_a_commit_origin_does_not_have
run_test test_integrate_from_remote_squash_leaves_feature_tip_unintegrated

# --- /finish progress: the record the cs mod reads to toast and draw the gate band ---

# One field of the base's progress record, as jq -r prints it.
progress_field() {  # record_file jq_filter
    jq -r "$2" "$1" 2>/dev/null
}

test_finish_progress_records_a_landing() {
    local sha base_dir record output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    record="$base_dir/.cs/local/finish-progress.json"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_file_exists "$record" "the landing leaves a progress record" || return 1
    assert_eq "landed" "$(progress_field "$record" .step)" "the outcome is landed" || return 1
    assert_eq "fix-auth" "$(progress_field "$record" .task)" "names the task" || return 1
    assert_eq "$sha" "$(progress_field "$record" .sha)" "carries the captured sha" || return 1
    assert_eq "$(git -C "$base_dir" rev-parse HEAD)" "$(progress_field "$record" .result)" "carries the commit the base landed on" || return 1
    case "$(progress_field "$record" .pid)" in ''|*[!0-9]*) echo "  FAIL: pid is not a number"; return 1 ;; esac
    case "$(progress_field "$record" .ts)" in ''|*[!0-9]*) echo "  FAIL: ts is not epoch seconds"; return 1 ;; esac
    [ -n "$(progress_field "$record" '.id // empty')" ] || { echo "  FAIL: the record has no id"; return 1; }
}

test_finish_progress_records_no_gate_step_for_a_true_gate() {
    local sha base_dir record status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    record="$base_dir/.cs/local/finish-progress.json"
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true >/dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "integrate succeeds" || return 1
    assert_eq "landed" "$(progress_field "$record" .step)" "the outcome is landed" || return 1
    assert_eq "false" "$(progress_field "$record" 'has("gate_started")')" "-- true runs no gate worth a band" || return 1
}

test_finish_progress_records_the_gate_step_before_the_gate_runs() {
    local sha base_dir record before after status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    record="$base_dir/.cs/local/finish-progress.json"
    before=$(date +%s)
    # The gate copies the record as it stands while the gate runs.
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'cp "$0" "$1"' "$record" "$TEST_TMPDIR/seen" >/dev/null 2>&1 || status=$?
    after=$(date +%s)
    assert_eq "0" "$status" "integrate succeeds" || return 1
    assert_file_exists "$TEST_TMPDIR/seen" "the record existed while the gate ran" || return 1
    assert_eq "gate" "$(progress_field "$TEST_TMPDIR/seen" .step)" "the step during the gate is gate" || return 1
    assert_eq "fix-auth" "$(progress_field "$TEST_TMPDIR/seen" .task)" "the gate step names the task" || return 1
    local started
    started=$(progress_field "$TEST_TMPDIR/seen" .gate_started)
    case "$started" in ''|*[!0-9]*) echo "  FAIL: gate_started is not epoch seconds: $started"; return 1 ;; esac
    [ "$started" -ge "$before" ] && [ "$started" -le "$after" ] \
        || { echo "  FAIL: gate_started $started is outside the run ($before..$after)"; return 1; }
    case "$(progress_field "$TEST_TMPDIR/seen" .pid)" in ''|*[!0-9]*) echo "  FAIL: the gate step has no pid"; return 1 ;; esac
    assert_eq "landed" "$(progress_field "$record" .step)" "the run still lands" || return 1
    assert_eq "$(progress_field "$TEST_TMPDIR/seen" .id)" "$(progress_field "$record" .id)" "one run, one id" || return 1
}

test_finish_progress_records_a_red_gate_and_a_moved_base_as_refused() {
    local sha base_dir record head status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    record="$base_dir/.cs/local/finish-progress.json"
    head=$(git -C "$base_dir" rev-parse HEAD)
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo GATE-SAYS-NO; exit 3' >/dev/null 2>&1 || status=$?
    assert_eq "1" "$status" "a red gate refuses" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_eq "refused" "$(progress_field "$record" .step)" "a red gate is refused" || return 1
    assert_eq "fix-auth" "$(progress_field "$record" .task)" "names the task" || return 1
    local reason
    reason=$(progress_field "$record" .reason)
    case "$reason" in
        "Gate failed in "*"(output above); base $base_dir untouched at $head") ;;
        *) echo "  FAIL: the reason is the refusal's first line, got: $reason"; return 1 ;;
    esac

    status=0
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git -C "$base_dir" commit -q --allow-empty -m moved >/dev/null 2>&1 || status=$?
    assert_eq "1" "$status" "a moved base refuses" || return 1
    assert_eq "refused" "$(progress_field "$record" .step)" "a moved base is refused" || return 1
    assert_eq "Base $base_dir moved during the gates (was $head, now $(git -C "$base_dir" rev-parse --short HEAD)); re-run /finish fix-auth" \
        "$(progress_field "$record" .reason)" "the moved-base reason is one line" || return 1
}

test_finish_progress_records_a_conflict_as_refused() {
    local base_dir wt sha record head status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo "base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base file")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "conflicting base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base edit")
    head=$(git -C "$base_dir" rev-parse HEAD)
    record="$base_dir/.cs/local/finish-progress.json"
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true >/dev/null 2>&1 || status=$?
    assert_eq "1" "$status" "a conflict refuses" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_eq "refused" "$(progress_field "$record" .step)" "a conflict is refused" || return 1
    assert_eq "Merge of $sha conflicts with $base_dir at $head; base untouched. Conflicting paths:" \
        "$(progress_field "$record" .reason)" "the reason is the refusal's first line" || return 1
}

test_finish_progress_records_a_retirement() {
    local sha base_dir record landed_id output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    echo "fix" > "$CS_SESSIONS_ROOT/myproj@fix-auth/auth.txt"
    (cd "$CS_SESSIONS_ROOT/myproj@fix-auth" && git add auth.txt && git commit -q -m "task work")
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    record="$base_dir/.cs/local/finish-progress.json"
    landed_id=$(progress_field "$record" .id)
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire succeeds: $output" || return 1
    assert_eq "retired" "$(progress_field "$record" .step)" "the outcome is retired" || return 1
    assert_eq "fix-auth" "$(progress_field "$record" .task)" "names the task" || return 1
    [ "$(progress_field "$record" .id)" != "$landed_id" ] || { echo "  FAIL: the retire is a run of its own and needs its own id"; return 1; }
}

# An encrypted session keeps cs's files behind .cs/private, a link into its
# vault; a locked vault (the link dangles) gets no plaintext record instead.
test_finish_progress_goes_behind_private_in_an_encrypted_session() {
    local sha base_dir status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$TEST_TMPDIR/vault/private"
    ln -s "$TEST_TMPDIR/vault/private" "$base_dir/.cs/private"
    _mark_hand_made_vault "$base_dir"
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true >/dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "integrate succeeds" || return 1
    assert_eq "landed" "$(progress_field "$TEST_TMPDIR/vault/private/finish-progress.json" .step)" "the record is in the vault" || return 1
    assert_not_exists "$base_dir/.cs/local/finish-progress.json" "no plaintext record" || return 1
}

test_finish_progress_drops_the_record_while_the_vault_is_locked() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    ln -s "$TEST_TMPDIR/unmounted/private" "$base_dir/.cs/private"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>/dev/null) || status=$?
    assert_eq "0" "$status" "a locked vault does not stop the landing" || return 1
    assert_eq "integrated fix-auth $sha -> $(git -C "$base_dir" rev-parse HEAD)" "$output" "the output is unchanged" || return 1
    assert_not_exists "$base_dir/.cs/local/finish-progress.json" "no plaintext record" || return 1
    assert_not_exists "$TEST_TMPDIR/unmounted" "nothing is created where the vault mounts" || return 1
}

# Progress is advisory: a record that cannot be written costs one warning on
# stderr, never the landing, its exit status or its output.
test_finish_progress_write_failure_changes_nothing_but_one_warning() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # A directory where the record goes: cs_write_atomic refuses it on every write.
    mkdir -p "$base_dir/.cs/local/finish-progress.json"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'exit 0' 2>"$TEST_TMPDIR/stderr") || status=$?
    assert_eq "0" "$status" "the landing still succeeds" || return 1
    assert_eq "integrated fix-auth $sha -> $(git -C "$base_dir" rev-parse HEAD)" "$output" "stdout is the summary line alone" || return 1
    assert_file_exists "$base_dir/feature.txt" "the feature landed" || return 1
    assert_eq "1" "$(wc -l < "$TEST_TMPDIR/stderr" | tr -d ' ')" "exactly one line on stderr: $(cat "$TEST_TMPDIR/stderr")" || return 1
    assert_file_contains "$TEST_TMPDIR/stderr" "^cs: /finish progress not recorded: could not write $base_dir/.cs/local/finish-progress.json$" \
        "the one line is the warning" || return 1
}

run_test test_finish_progress_records_a_landing
run_test test_finish_progress_records_no_gate_step_for_a_true_gate
run_test test_finish_progress_records_the_gate_step_before_the_gate_runs
run_test test_finish_progress_records_a_red_gate_and_a_moved_base_as_refused
run_test test_finish_progress_records_a_conflict_as_refused
run_test test_finish_progress_records_a_retirement
run_test test_finish_progress_goes_behind_private_in_an_encrypted_session
run_test test_finish_progress_drops_the_record_while_the_vault_is_locked
run_test test_finish_progress_write_failure_changes_nothing_but_one_warning

report_results
