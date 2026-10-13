#!/usr/bin/env bash
# ABOUTME: Tests for scripts/cs-to-code-sessions.py, which gives code-sessions its own copy of each session the stable cs has.
# ABOUTME: A fixture cs with adopted, created, nested and gone sessions, history and secrets, copied and re-synced into a profile.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
MOVE="$SCRIPT_DIR/../scripts/cs-to-code-sessions.py"
BACK="$SCRIPT_DIR/../scripts/code-sessions-to-cs.py"
PROFILE_CS="$SCRIPT_DIR/../bin/cs"

WAP_ID=11111111-1111-4111-8111-111111111111
FEAT_ID=33333333-3333-4333-8333-333333333333
FIX_ID=44444444-4444-4444-8444-444444444444
OLD_ID=55555555-5555-4555-8555-555555555555
OTHER_ID=66666666-6666-4666-8666-666666666666
SCRATCH_ID=77777777-7777-4777-8777-777777777777
MINE_ID=99999999-9999-4999-8999-999999999999
TASK_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
GONE_ID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
GONE_ROOT_ID=cccccccc-cccc-4ccc-8ccc-cccccccccccc
OUTER_ID=dddddddd-dddd-4ddd-8ddd-dddddddddddd
INNER_ID=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee

project_key() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

physical() {
    (cd -P "$1" && pwd)
}

cs_protocol() {
    cat <<'EOF'
<!-- cs:session-protocol -->
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.

Secrets live in the cs session store, never in a project file. `cs -secrets set`
Consume a secret inline — `some-command --token "$(cs -secrets get API_KEY)"` —

<!-- cs:wrap-cues -->
To opt out, keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
}

# A cs feature worktree as cs and branch-out make them: a linked worktree of the
# project in cs's sessions root, its state naming the base.
add_feature() {  # task branch id
    local dir="$CSROOT/wap@$1"
    git -C "$PROJECT" worktree add -q -b "$2" "$dir"
    mkdir -p "$dir/.cs/local" "$dir/.claude"
    printf 'task_branch: %s\ncs_mode: tracked\ncs_base: wap\nclaude_session_id: %s\n' "$2" "$3" > "$dir/.cs/local/state"
    cs_protocol > "$dir/CLAUDE.local.md"
    printf '{\n  "autoMemoryDirectory": "%s/.cs/memory",\n  "plansDirectory": ".cs/plans"\n}\n' "$dir" \
        > "$dir/.claude/settings.local.json"
    mkdir -p "$CLAUDE/projects/$(project_key "$(physical "$dir")")"
    printf '{"feature":"%s"}\n' "$1" > "$CLAUDE/projects/$(project_key "$(physical "$dir")")/$3.jsonl"
}

# The stable cs as it is before the move, under the test HOME: wap is a project
# cs adopted, with a cs/<task> feature and a branch-out feature; a retired
# feature and a scratch folder left conversations behind; wap-other is another
# cs session whose folder name starts like wap's features. cs-secrets is a stub
# that keeps each value in a file and logs its arguments.
make_fixture() {
    PROFILE="$HOME/.local/share/code-sessions/home"
    CSROOT="$HOME/.claude-sessions"
    CLAUDE="$HOME/.claude"
    STUB_STORE="$TEST_TMPDIR/cs-store"
    export STUB_STORE
    mkdir -p "$PROFILE/sessions" "$PROFILE/.local/bin" "$PROFILE/.claude" "$PROFILE/.codex" \
        "$CSROOT" "$HOME/.local/bin" "$HOME/.codex" "$STUB_STORE/wap" "$CLAUDE/projects"
    cp "$SCRIPT_DIR/../bin/cs-secrets" "$PROFILE/.local/bin/cs-secrets"
    use_fake_keychain

    PROJECT="$TEST_TMPDIR/projects/wap"
    mkdir -p "$PROJECT/.cs/local" "$PROJECT/.claude"
    git init -q -b main "$PROJECT"
    printf '.cs/\n.claude/settings.local.json\nCLAUDE.local.md\nnode_modules/\n' > "$PROJECT/.gitignore"
    printf 'code\n' > "$PROJECT/app.js"
    git -C "$PROJECT" add -A
    git -C "$PROJECT" commit -q -m 'wap project'
    printf 'claude_session_id: %s\nsession_name: wap\nengine: claude\n' "$WAP_ID" > "$PROJECT/.cs/local/state"
    { printf 'A note of my own about `cs -list`.\n\n'; cs_protocol; } > "$PROJECT/CLAUDE.local.md"
    printf '{\n  "autoMemoryDirectory": "%s/.cs/memory"\n}\n' "$(physical "$PROJECT")" \
        > "$PROJECT/.claude/settings.local.json"
    ln -s "$PROJECT" "$CSROOT/wap"
    PROJECT_KEY=$(project_key "$(physical "$PROJECT")")
    mkdir -p "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID/subagents" "$CLAUDE/file-history/$WAP_ID" \
        "$CLAUDE/session-env/$WAP_ID" "$CLAUDE/tasks/wap"
    printf '{"n":1}\n{"n":2}\n' > "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl"
    printf '{"agent":1}\n' > "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID/subagents/agent-1.jsonl"
    printf 'before the edit\n' > "$CLAUDE/file-history/$WAP_ID/snap@v1"
    printf 'PATH=x\n' > "$CLAUDE/session-env/$WAP_ID/hook-1.sh"
    printf '{"id":"1"}\n' > "$CLAUDE/tasks/wap/1.json"

    add_feature feat cs/feat "$FEAT_ID"
    FEAT="$CSROOT/wap@feat"
    FEAT_OLD=$(physical "$FEAT")
    printf 'feature work\n' > "$FEAT/feature.txt"
    git -C "$FEAT" add feature.txt
    git -C "$FEAT" commit -q -m 'feature commit'
    printf 'staged\n' > "$FEAT/staged.txt"
    git -C "$FEAT" add staged.txt
    printf 'unstaged\n' >> "$FEAT/feature.txt"
    printf 'untracked\n' > "$FEAT/scratch.txt"
    mkdir -p "$FEAT/node_modules/dep"
    printf 'ignored\n' > "$FEAT/node_modules/dep/index.js"
    git -C "$FEAT" update-ref refs/worktree/cs/session/autosave HEAD

    add_feature fix wap-fix "$FIX_ID"
    # Links into the project by absolute path, as some features have them.
    mkdir -p "$PROJECT/node_modules/pkg"
    printf 'pkg\n' > "$PROJECT/node_modules/pkg/index.js"
    printf 'A=1\n' > "$PROJECT/.env.x"
    ln -s "$CSROOT/wap/node_modules" "$CSROOT/wap@fix/node_modules"
    ln -s "$PROJECT/.env.x" "$CSROOT/wap@fix/.env.x"
    REGISTRY="$HOME/.agent-worktrees/registry/wap-repo/wap@fix.json"
    mkdir -p "${REGISTRY%/*}"
    printf '{\n  "worktreePath": "%s",\n  "sessionName": "wap@fix",\n  "sessionManager": "cs",\n  "branch": "wap-fix"\n}\n' \
        "$CSROOT/wap@fix" > "$REGISTRY"

    # Left behind by a retired feature and a conversation's scratch folder.
    OLD_KEY=$(project_key "$(physical "$CSROOT")/wap@old")
    SCRATCH_KEY=$(project_key "/private/tmp/claude-501/$OLD_KEY/$SCRATCH_ID/scratchpad")
    mkdir -p "$CLAUDE/projects/$OLD_KEY" "$CLAUDE/projects/$SCRATCH_KEY"
    printf '{"old":1}\n' > "$CLAUDE/projects/$OLD_KEY/$OLD_ID.jsonl"
    printf '{"scratch":1}\n' > "$CLAUDE/projects/$SCRATCH_KEY/$SCRATCH_ID.jsonl"
    # Another session whose folder name starts like a wap feature's.
    mkdir -p "$CSROOT/wap-other/.cs"
    OTHER_KEY=$(project_key "$(physical "$CSROOT/wap-other")")
    mkdir -p "$CLAUDE/projects/$OTHER_KEY"
    printf '{"other":1}\n' > "$CLAUDE/projects/$OTHER_KEY/$OTHER_ID.jsonl"

    {
        printf '{"display":"main prompt","timestamp":1,"project":"%s"}\n' "$(physical "$PROJECT")"
        printf '{"display":"feature prompt","timestamp":2,"project":"%s"}\n' "$FEAT_OLD"
        printf '{"display":"retired prompt","timestamp":3,"project":"%s/wap@old"}\n' "$(physical "$CSROOT")"
        printf '{"display":"other prompt","timestamp":4,"project":"%s"}\n' "$(physical "$CSROOT/wap-other")"
    } > "$CLAUDE/history.jsonl"
    jq -n --arg p "$(physical "$PROJECT")" --arg f "$FEAT_OLD" '{projects: {
        ($p): {allowedTools: ["Bash(ls)"], hasTrustDialogAccepted: true, lastCost: 1},
        ($f): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
    jq -n --arg p "$(physical "$PROJECT")" '{theme: "dark", projects: {($p): {hasTrustDialogAccepted: false}}}' \
        > "$PROFILE/.claude/.claude.json"
    printf 'model = "x"\n\n[projects."%s"]\ntrust_level = "trusted"\n\n[projects."/elsewhere"]\ntrust_level = "untrusted"\n' \
        "$FEAT_OLD" > "$HOME/.codex/config.toml"
    printf 'model = "y"\n' > "$PROFILE/.codex/config.toml"

    printf 's3cret-value' > "$STUB_STORE/wap/TOKEN"
    cat > "$HOME/.local/bin/cs-secrets" <<'EOF'
#!/usr/bin/env bash
set -eu
session=""
if [ "$1" = --session ]; then session=$2; shift 2; fi
echo "$* backend=${CS_SECRETS_BACKEND:-unset} prefix=${CS_SECRETS_KEYCHAIN_PREFIX:-unset} dir=${CS_SECRETS_DIR:-unset}" >> "$STUB_STORE/argv.log"
case "$1" in
    list)
        if [ -d "$STUB_STORE/$session" ] && [ -n "$(ls "$STUB_STORE/$session")" ]; then
            echo "Secrets for session: $session"
            for f in "$STUB_STORE/$session"/*; do echo "  - ${f##*/}"; done
        else
            echo "No secrets stored for session: $session"
        fi ;;
    get) cat "$STUB_STORE/$session/$2"; echo ;;
    set) mkdir -p "$STUB_STORE/$session"; cat > "$STUB_STORE/$session/$2"; echo "Stored secret: $2" ;;
esac
EOF
    chmod +x "$HOME/.local/bin/cs-secrets"
}

# A session as cs creates one in its own folder in the sessions root: its own
# repository (none with norepo), state, protocol, and a conversation.
make_created() {  # name id [norepo]
    local dir="$CSROOT/$1" key
    mkdir -p "$dir/.cs/local" "$dir/.claude"
    printf 'notes\n' > "$dir/notes.md"
    if [ "${3:-}" != norepo ]; then
        git init -q -b main "$dir"
        printf '.cs/local/\n.claude/settings.local.json\nCLAUDE.local.md\n' > "$dir/.gitignore"
        git -C "$dir" add -A
        git -C "$dir" commit -q -m "$1 session"
    fi
    printf 'claude_session_id: %s\nsession_name: %s\nengine: claude\n' "$2" "$1" > "$dir/.cs/local/state"
    cs_protocol > "$dir/CLAUDE.local.md"
    printf '{\n  "autoMemoryDirectory": "%s/.cs/memory"\n}\n' "$(physical "$dir")" > "$dir/.claude/settings.local.json"
    key=$(project_key "$(physical "$dir")")
    mkdir -p "$CLAUDE/projects/$key"
    printf '{"session":"%s"}\n' "$1" > "$CLAUDE/projects/$key/$2.jsonl"
}

# outer, a project cs adopted, with inner, another project cs adopted, inside it.
make_nested() {
    OUTER_SRC="$TEST_TMPDIR/projects/outer"
    INNER_SRC="$OUTER_SRC/inner"
    mkdir -p "$OUTER_SRC/.cs/local" "$INNER_SRC/.cs/local"
    git init -q -b main "$OUTER_SRC"
    printf '.cs/\n' > "$OUTER_SRC/.gitignore"
    printf 'outer\n' > "$OUTER_SRC/outer.txt"
    git -C "$OUTER_SRC" add .gitignore outer.txt
    git -C "$OUTER_SRC" commit -q -m outer
    git init -q -b main "$INNER_SRC"
    printf '.cs/\n' > "$INNER_SRC/.gitignore"
    printf 'inner\n' > "$INNER_SRC/inner.txt"
    git -C "$INNER_SRC" add -A
    git -C "$INNER_SRC" commit -q -m inner
    printf 'claude_session_id: %s\n' "$OUTER_ID" > "$OUTER_SRC/.cs/local/state"
    printf 'claude_session_id: %s\n' "$INNER_ID" > "$INNER_SRC/.cs/local/state"
    ln -s "$OUTER_SRC" "$CSROOT/outer"
    ln -s "$INNER_SRC" "$CSROOT/inner"
}

ccs_secret() {  # session name
    CS_SECRETS_KEYCHAIN_PREFIX=code-sessions CS_SECRETS_DIR="$PROFILE/.cs-secrets" \
        "$PROFILE/.local/bin/cs-secrets" --session "$1" get "$2"
}

# Every file and link under a directory, hashed, so a test can prove it was only read.
fingerprint() {
    (cd "$1" && find . \( -type f -o -type l \) -print | sort | while IFS= read -r f; do
        if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s %s\n' "$f" "$(shasum < "$f")"; fi
    done) | shasum
}

run_move() {
    local status=0
    python3 "$MOVE" "$@" > "$TEST_TMPDIR/out.log" 2>&1 || status=$?
    OUT=$(cat "$TEST_TMPDIR/out.log")
    return "$status"
}

# Waits out session_transfer.MARGIN_NS. A change made within the margin before
# a run is looked at again on the next run, so a change that must be reported
# once is made longer than the margin before the run that reports it.
wait_past_the_margin() {
    sleep "$(cd "$SCRIPT_DIR/../scripts" && python3 -B -c 'import session_transfer; print(session_transfer.MARGIN_NS / 1e9 + 0.1)')"
}

# Everything the stable side has, so a test can prove the hand-over only read it.
cs_side_fingerprint() {
    {
        fingerprint "$CSROOT"
        fingerprint "$PROJECT"
        fingerprint "$CLAUDE"
        fingerprint "$HOME/.codex"
        shasum < "$HOME/.claude.json"
        shasum < "$REGISTRY"
        git -C "$PROJECT" worktree list --porcelain
        fingerprint "$STUB_STORE/wap"
    } | shasum
}

# Where the copies land, by the physical path Claude Code keys its folders on.
ccs_dir() {  # session name
    printf '%s/%s' "$(physical "$PROFILE/sessions")" "$1"
}

test_dry_run_changes_nothing() {
    make_fixture
    local cs_before profile_before
    cs_before=$(cs_side_fingerprint)
    profile_before=$(fingerprint "$PROFILE")
    run_move --session wap || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'would copy .*projects/wap to .*sessions/wap, with a repository of its own' || return 1
    assert_output_contains "$OUT" "wap@feat: would copy it to .*sessions/wap@feat, a worktree of code-sessions's wap on cs/feat" || return 1
    assert_output_contains "$OUT" "wap@fix: would copy it to .*sessions/wap@fix, a worktree of code-sessions's wap on wap-fix" || return 1
    assert_output_contains "$OUT" 'secrets of wap to copy: TOKEN' || return 1
    assert_output_contains "$OUT" "ccs wap resumes conversation $WAP_ID" || return 1
    assert_output_contains "$OUT" 'Dry run: nothing changed' || return 1
    assert_output_not_contains "$OUT" 'link' || return 1
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    assert_eq "$profile_before" "$(fingerprint "$PROFILE")" "the profile changed"
}

test_apply_copies_the_session_and_leaves_cs_as_it_is() {
    make_fixture
    echo $$ > "$PROJECT/.cs/session.lock"
    # A git command and a process running in cs leave a lock and a pipe behind.
    : > "$PROJECT/.git/index.lock"
    mkfifo "$PROJECT/.cs/local/pipe"
    local cs_before
    cs_before=$(cs_side_fingerprint)
    run_move --session wap --apply || { echo "$OUT"; return 1; }

    # Not one byte of the cs side changed: folders, worktrees, history, settings, secrets.
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1

    # code-sessions has its own copy and its own repository, which knows only its own worktrees.
    local wap feat fix
    wap=$(ccs_dir wap); feat=$(ccs_dir wap@feat); fix=$(ccs_dir wap@fix)
    [ -d "$wap" ] && [ ! -L "$PROFILE/sessions/wap" ] || { echo "  FAIL: wap is not a folder of its own"; return 1; }
    [ ! -L "$PROFILE/sessions/wap@feat" ] || { echo "  FAIL: wap@feat is a link"; return 1; }
    assert_eq "$wap/.git" "$(cd "$feat" && cd -P "$(git rev-parse --git-common-dir)" && pwd)" || return 1
    assert_eq "$(printf '%s\n' "$wap" "$feat" "$fix")" \
        "$(git -C "$wap" worktree list --porcelain | sed -n 's/^worktree //p')" || return 1
    assert_file_not_exists "$wap/.cs/session.lock" || return 1
    assert_file_not_exists "$wap/.git/index.lock" "cs's git lock came along" || return 1
    assert_not_exists "$wap/.cs/local/pipe" "cs's pipe came along" || return 1
    assert_file_exists "$wap/app.js" || return 1

    # A feature keeps its branch, index, uncommitted, untracked and ignored files, and its own refs.
    assert_eq "cs/feat" "$(git -C "$feat" branch --show-current)" || return 1
    assert_eq "staged.txt" "$(git -C "$feat" diff --cached --name-only)" || return 1
    assert_file_contains "$feat/feature.txt" '^unstaged$' || return 1
    assert_file_exists "$feat/scratch.txt" || return 1
    assert_file_exists "$feat/node_modules/dep/index.js" || return 1
    # A link into cs's project points at code-sessions's copy, so nothing writes through to cs.
    assert_eq "$PROFILE/sessions/wap/node_modules" "$(readlink "$fix/node_modules")" || return 1
    assert_eq "$PROFILE/sessions/wap/.env.x" "$(readlink "$fix/.env.x")" || return 1
    git -C "$feat" rev-parse -q --verify refs/worktree/cs/session/autosave >/dev/null \
        || { echo "  FAIL: the feature's own ref did not come along"; return 1; }
    assert_eq "$PROFILE/sessions/wap@feat/.cs/memory" \
        "$(jq -r .autoMemoryDirectory "$feat/.claude/settings.local.json")" || return 1
    assert_eq "$PROFILE/sessions/wap/.cs/memory" "$(jq -r .autoMemoryDirectory "$wap/.claude/settings.local.json")" || return 1
    assert_file_contains "$wap/CLAUDE.local.md" 'managed by the cs tool' || return 1

    # Conversations under the copies' folder names, with their side files.
    local projects="$PROFILE/.claude/projects"
    cmp -s "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl" "$projects/$(project_key "$wap")/$WAP_ID.jsonl" \
        || { echo "  FAIL: wap's conversation was not copied"; return 1; }
    assert_file_exists "$projects/$(project_key "$wap")/$WAP_ID/subagents/agent-1.jsonl" || return 1
    assert_file_exists "$projects/$(project_key "$feat")/$FEAT_ID.jsonl" || return 1
    assert_file_exists "$projects/$(project_key "$fix")/$FIX_ID.jsonl" || return 1
    assert_not_exists "$projects/$PROJECT_KEY" "a conversation stayed under cs's folder name" || return 1
    assert_file_exists "$PROFILE/.claude/file-history/$WAP_ID/snap@v1" || return 1
    assert_file_exists "$PROFILE/.claude/session-env/$WAP_ID/hook-1.sh" || return 1
    assert_file_exists "$PROFILE/.claude/tasks/wap/1.json" || return 1
    # History with no session comes too; another session's stays out.
    assert_file_exists "$projects/$OLD_KEY/$OLD_ID.jsonl" || return 1
    assert_file_exists "$projects/$SCRATCH_KEY/$SCRATCH_ID.jsonl" || return 1
    assert_not_exists "$projects/$OTHER_KEY" "wap-other's conversations came along" || return 1

    # Prompt history under the copies' paths; other sessions' stay out.
    local prompts="$PROFILE/.claude/history.jsonl"
    assert_eq "$wap" "$(jq -r 'select(.display == "main prompt") | .project' "$prompts")" || return 1
    assert_eq "$feat" "$(jq -r 'select(.display == "feature prompt") | .project' "$prompts")" || return 1
    assert_file_contains "$prompts" 'retired prompt' || return 1
    assert_file_not_contains "$prompts" 'other prompt' || return 1

    # Settings follow each path to its copy; the profile's own stay.
    local state="$PROFILE/.claude/.claude.json"
    assert_eq '["Bash(ls)"]' "$(jq -c --arg p "$wap" '.projects[$p].allowedTools' "$state")" || return 1
    assert_eq null "$(jq --arg p "$wap" '.projects[$p].lastCost' "$state")" || return 1
    assert_eq true "$(jq --arg p "$feat" '.projects[$p].hasTrustDialogAccepted' "$state")" || return 1
    assert_eq false "$(jq --arg p "$(physical "$PROJECT")" '.projects[$p].hasTrustDialogAccepted' "$state")" \
        "a profile setting was overwritten" || return 1
    assert_eq dark "$(jq -r .theme "$state")" || return 1
    assert_file_contains "$PROFILE/.codex/config.toml" "^\[projects.\"$feat\"\]" || return 1
    assert_file_not_contains "$PROFILE/.codex/config.toml" "\"$FEAT_OLD\"" || return 1
    assert_file_contains "$PROFILE/.codex/config.toml" '^model = "y"' || return 1
    assert_file_not_contains "$PROFILE/.codex/config.toml" 'elsewhere' || return 1

    # Secrets reach the profile's cs-secrets on stdin; argv never carries a value.
    # They land in the keychain under code-sessions:<session>, never under the
    # original's cs:<session>, which the stable cs-secrets reads. Where there is
    # no keychain they land in the profile's encrypted store.
    assert_eq "s3cret-value" "$(ccs_secret wap TOKEN)" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 's3cret' "the value reached argv" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 'prefix=code-sessions' "cs-secrets got the code-sessions prefix" || return 1
    if keychain_is_default; then
        assert_eq "code-sessions:wap:TOKEN" "$(fake_keychain_items)" || return 1
    else
        assert_eq "" "$(fake_keychain_items)" "a secret reached a keychain this platform does not use" || return 1
        assert_file_exists "$PROFILE/.cs-secrets/wap.enc" || return 1
    fi

    jq -e 'select(.action == "copied-feature" and .session == "wap@feat")' "$PROFILE/.cs-to-code-sessions/log.jsonl" >/dev/null \
        || { echo "  FAIL: the copy is not in the log"; return 1; }
    assert_file_exists "$PROFILE/.cs-to-code-sessions/wap/record.json" || return 1
    assert_output_contains "$OUT" 'cs keeps wap as it was'
}

# What cs did after the first copy comes over where code-sessions left the same thing
# alone; what code-sessions did is kept; something both did keeps code-sessions's and is said once.
test_rerun_brings_over_what_cs_changed_and_keeps_what_code_sessions_changed() {
    make_fixture
    git -C "$PROJECT" branch topic main
    git -C "$PROJECT" commit -q --allow-empty -m 'main moves on'
    git -C "$PROJECT" branch -f topic main
    printf 'abcd\n' > "$PROJECT/same-size.txt"
    printf '#!/bin/sh\n' > "$PROJECT/tool.sh"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap feat
    wap=$(ccs_dir wap); feat=$(ccs_dir wap@feat)
    sleep 0.05

    # cs: an uncommitted edit, a commit on a feature, a new branch, a deletion,
    # a note, a new binding, a grown conversation.
    printf 'cs edit\n' >> "$PROJECT/app.js"
    printf 'wxyz\n' > "$PROJECT/same-size.txt"
    chmod +x "$PROJECT/tool.sh"
    printf 'committed in cs\n' > "$FEAT/later.txt"
    git -C "$FEAT" add later.txt
    git -C "$FEAT" commit -q -m 'cs commit'
    git -C "$PROJECT" branch cs/new main
    rm "$FEAT/scratch.txt"
    mkdir -p "$PROJECT/.cs/memory"
    printf 'cs note\n' > "$PROJECT/.cs/memory/note.md"
    sed -i.bak "s/^claude_session_id: .*/claude_session_id: $OTHER_ID/" "$PROJECT/.cs/local/state"
    rm "$PROJECT/.cs/local/state.bak"
    printf '{"n":3}\n' >> "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl"
    printf 'cs side\n' > "$PROJECT/both.txt"
    # A stat-dirty index: a git status here would rewrite cs's index.
    touch "$PROJECT/.gitignore"
    # A branch cs rewrote, a change staged only in cs, a setting cs added.
    git -C "$PROJECT" branch -f topic main~1
    printf 'staged in cs\n' > "$FEAT/staged2.txt"
    git -C "$FEAT" add staged2.txt
    jq '.cs_added = 1' "$FEAT/.claude/settings.local.json" > "$TEST_TMPDIR/s.json"
    cat "$TEST_TMPDIR/s.json" > "$FEAT/.claude/settings.local.json"
    # Both sides: the protocol file and a state key.
    printf 'cs line\n' >> "$PROJECT/CLAUDE.local.md"
    sed -i.bak 's/^engine: .*/engine: cs-side/' "$PROJECT/.cs/local/state"
    rm "$PROJECT/.cs/local/state.bak"
    # code-sessions: its own file, its own state key, and the same file as cs.
    printf 'code-sessions only\n' > "$wap/code-sessions-notes.txt"
    printf 'claude_session_color: pink\n' >> "$wap/.cs/local/state"
    sed -i.bak 's/^engine: .*/engine: code-sessions-side/' "$wap/.cs/local/state"
    rm "$wap/.cs/local/state.bak"
    printf 'code-sessions side\n' > "$wap/both.txt"
    printf 'code-sessions line\n' >> "$wap/CLAUDE.local.md"
    rm "$feat/node_modules/dep/index.js"
    # Longer ago than the margin, or the third run below would report the conflicts again.
    wait_past_the_margin

    local cs_before status=0
    cs_before=$(cs_side_fingerprint)
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "a file changed on both sides was not reported" || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the rerun changed the cs side" || return 1
    assert_output_contains "$OUT" 'in code-sessions at .*sessions/wap since an earlier run' || return 1
    assert_output_contains "$OUT" 'branches new in cs, added: cs/new' || return 1
    assert_output_contains "$OUT" "wap@feat: took cs's HEAD and index: cs/feat at " || return 1
    assert_output_contains "$OUT" "wap: kept code-sessions's both.txt (added on both sides)" || return 1
    assert_output_contains "$OUT" "wap: kept code-sessions's CLAUDE.local.md (changed on both sides)" || return 1
    assert_output_contains "$OUT" "wap: kept code-sessions's .cs/local/state (engine changed on both sides)" || return 1
    assert_output_contains "$OUT" 'branches cs moved on, moved along: topic' || return 1
    assert_output_contains "$OUT" 'Claude history of wap, 1 conversation(s), files copied: 1 grown since the last copy' || return 1
    assert_output_contains "$OUT" 'secrets of wap code-sessions already has: TOKEN' || return 1
    assert_output_not_contains "$OUT" 'prompt history' || return 1

    assert_file_contains "$wap/app.js" '^cs edit$' || return 1
    assert_file_contains "$wap/same-size.txt" '^wxyz$' "a change that kept the size did not come" || return 1
    [ -x "$wap/tool.sh" ] || { echo "  FAIL: a mode cs changed did not come"; return 1; }
    # A blob staged only in cs reached code-sessions's repository, not just its index.
    assert_eq 'staged in cs' "$(git -C "$feat" show :staged2.txt 2>&1)" || return 1
    assert_file_contains "$wap/.cs/memory/note.md" 'cs note' || return 1
    assert_file_contains "$wap/code-sessions-notes.txt" 'code-sessions only' || return 1
    assert_file_contains "$wap/both.txt" 'code-sessions side' || return 1
    assert_file_contains "$wap/.cs/local/state" "^claude_session_id: $OTHER_ID$" || return 1
    assert_file_contains "$wap/.cs/local/state" '^claude_session_color: pink$' || return 1
    assert_file_contains "$wap/.cs/local/state" '^engine: code-sessions-side$' || return 1
    assert_file_contains "$wap/CLAUDE.local.md" '^code-sessions line$' || return 1
    assert_file_not_contains "$wap/CLAUDE.local.md" '^cs line$' || return 1
    assert_eq "$(git -C "$PROJECT" rev-parse topic)" "$(git -C "$wap" rev-parse topic)" "the branch cs rewrote" || return 1
    assert_eq 1 "$(jq .cs_added "$feat/.claude/settings.local.json")" "cs's new setting did not come" || return 1
    assert_eq "$PROFILE/sessions/wap@feat/.cs/memory" \
        "$(jq -r .autoMemoryDirectory "$feat/.claude/settings.local.json")" "the setting came under cs's path" || return 1
    assert_eq "$(git -C "$PROJECT" rev-parse cs/new)" "$(git -C "$wap" rev-parse cs/new)" || return 1
    assert_eq "$(git -C "$FEAT" rev-parse HEAD)" "$(git -C "$feat" rev-parse HEAD)" || return 1
    assert_eq "$(git -C "$FEAT" rev-parse HEAD)" "$(git -C "$wap" rev-parse refs/remotes/cs/cs/feat)" || return 1
    assert_file_contains "$feat/later.txt" 'committed in cs' || return 1
    assert_file_not_exists "$feat/scratch.txt" || return 1
    assert_eq "$(git -C "$FEAT" status --porcelain)" "$(git -C "$feat" status --porcelain)" \
        "the feature's working state differs from cs's" || return 1
    cmp -s "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl" "$PROFILE/.claude/projects/$(project_key "$wap")/$WAP_ID.jsonl" \
        || { echo "  FAIL: the grown conversation was not brought over"; return 1; }
    assert_eq 3 "$(wc -l < "$PROFILE/.claude/history.jsonl" | tr -d ' ')" "a rerun duplicated the prompt history" || return 1

    # Said once: the next rerun has nothing to report, and code-sessions's side stays.
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: files: nothing new in cs' || return 1
    assert_output_not_contains "$OUT" '!' || return 1
    assert_file_contains "$wap/both.txt" 'code-sessions side' || return 1
    assert_file_not_exists "$feat/node_modules/dep/index.js" "a file code-sessions deleted came back"
}

# A folder code-sessions's copy has as a link elsewhere is never written through:
# what cs adds under it stays out, and the link is reported once.
test_a_link_in_the_copy_is_never_written_through() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap outside="$TEST_TMPDIR/outside" status=0
    wap=$(ccs_dir wap)
    mkdir -p "$outside" "$PROJECT/linked/deep"
    ln -s "$outside" "$wap/linked"
    printf 'from cs\n' > "$PROJECT/linked/new-file"
    printf 'from cs\n' > "$PROJECT/linked/deep/new-file"
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "a link in the way was not reported" || { echo "$OUT"; return 1; }
    assert_eq "" "$(ls -A "$outside")" "the sync wrote through code-sessions's link" || return 1
    assert_output_contains "$OUT" "wap: kept code-sessions's linked (" || return 1
    assert_eq 1 "$(grep -c "kept code-sessions's linked (" <<< "$OUT")" "the link was reported more than once" || return 1
    assert_symlink "$wap/linked"
}

# The same for the copy's reflogs: a folder of .git/logs that code-sessions has
# as a link elsewhere gets no reflog written through it, and is reported once.
test_a_link_in_the_copy_s_reflogs_is_never_written_through() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap outside="$TEST_TMPDIR/outside" status=0
    wap=$(ccs_dir wap)
    mkdir -p "$outside"
    printf 'notes of mine\n' > "$outside/main"
    rm -r "$wap/.git/logs/refs/heads"
    ln -s "$outside" "$wap/.git/logs/refs/heads"
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "a link in the way was not reported" || { echo "$OUT"; return 1; }
    assert_eq 'notes of mine' "$(cat "$outside/main")" "the sync wrote a reflog through code-sessions's link" || return 1
    assert_output_contains "$OUT" "a link or a file in code-sessions's .git where git keeps reflogs, left as it is: .*/logs/refs/heads$" || return 1
    assert_eq 1 "$(grep -c "where git keeps reflogs" <<< "$OUT")" "the link was reported more than once" || return 1
    assert_output_not_contains "$OUT" "reflogs only cs went on with" || return 1
    assert_symlink "$wap/.git/logs/refs/heads"
}

# The same for the Claude history: a conversation folder code-sessions has as a
# link elsewhere gets nothing written through it, and is reported.
test_a_link_in_the_copied_history_is_never_written_through() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap outside="$TEST_TMPDIR/outside" status=0 subagents
    wap=$(ccs_dir wap)
    subagents="$PROFILE/.claude/projects/$(project_key "$wap")/$WAP_ID/subagents"
    mkdir -p "$outside"
    rm -r "$subagents"
    ln -s "$outside" "$subagents"
    printf '{"agent":2}\n' > "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID/subagents/agent-2.jsonl"
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "a link in the way was not reported" || { echo "$OUT"; return 1; }
    assert_eq "" "$(ls -A "$outside")" "the history copy wrote through code-sessions's link" || return 1
    assert_output_contains "$OUT" "a link or a file in code-sessions where cs has a folder, left as it is: .*/$WAP_ID/subagents$" || return 1
    assert_output_not_contains "$OUT" "continued in both" || return 1
    assert_symlink "$subagents"
}

# A file cs replaced with a folder is no link in the way: the dry run, which
# deletes nothing, says so as the real run does.
test_a_file_cs_replaced_with_a_folder_comes_over() {
    make_fixture
    printf 'a file\n' > "$PROJECT/notes"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap
    wap=$(ccs_dir wap)
    rm "$PROJECT/notes"
    mkdir "$PROJECT/notes"
    printf 'in a folder\n' > "$PROJECT/notes/today"
    run_move --session wap || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: files: 1 to copy from cs, 1 to delete as in cs' || return 1
    assert_output_not_contains "$OUT" "kept code-sessions's notes" || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_file_contains "$wap/notes/today" 'in a folder'
}

# A folder of the copy that cannot be searched stops only the paths below it.
test_an_unsearchable_folder_in_the_copy_stops_only_its_paths() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap status=0
    wap=$(ccs_dir wap)
    mkdir "$wap/locked"
    chmod 600 "$wap/locked"
    mkdir -p "$PROJECT/locked/sub"
    printf 'below\n' > "$PROJECT/locked/sub/file"
    printf 'later\n' > "$PROJECT/zz-later"
    run_move --session wap --apply || status=$?
    chmod 700 "$wap/locked"
    assert_eq 1 "$status" "the unsearchable folder was not reported" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "kept code-sessions's locked/sub/file (could not read it: Permission denied)" || return 1
    assert_file_contains "$wap/zz-later" 'later'
}

test_git_moved_on_both_sides_is_left_and_reported_once() {
    make_fixture
    git -C "$PROJECT" branch side main
    git -C "$PROJECT" branch ff main
    printf 'old\n' > "$PROJECT/notes.txt"
    printf 'gone\n' > "$PROJECT/gone.txt"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap feat
    wap=$(ccs_dir wap); feat=$(ccs_dir wap@feat)
    sleep 0.05
    git -C "$FEAT" commit -q --allow-empty -m 'cs feature commit'
    git -C "$feat" commit -q --allow-empty -m 'code-sessions feature commit'
    local ccs_head
    ccs_head=$(git -C "$feat" rev-parse HEAD)
    commit_on() {  # repo branch message
        local tree parent
        tree=$(git -C "$1" rev-parse "$2^{tree}"); parent=$(git -C "$1" rev-parse "$2")
        git -C "$1" update-ref "refs/heads/$2" "$(git -C "$1" commit-tree "$tree" -p "$parent" -m "$3")"
    }
    commit_on "$PROJECT" side 'cs side'
    commit_on "$wap" side 'code-sessions side'
    # ff: code-sessions moved it, and cs took that commit and went on from it.
    commit_on "$wap" ff 'code-sessions on ff'
    git -C "$PROJECT" fetch -q "$wap" ff:ff
    commit_on "$PROJECT" ff 'cs on top'
    printf 'cs memory\n' > "$FEAT/.cs/cs-note.md"
    printf 'cs work\n' >> "$FEAT/feature.txt"
    # The project too: commits on main on both sides, and file changes in cs.
    git -C "$PROJECT" commit -q --allow-empty -m 'cs main'
    git -C "$wap" commit -q --allow-empty -m 'code-sessions main'
    printf 'cs notes\n' > "$PROJECT/notes.txt"
    rm "$PROJECT/gone.txt"
    # Past the marks' 2 s margin, as between real runs.
    sleep 2.1
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: git left as code-sessions has it' || return 1
    assert_file_contains "$wap/notes.txt" '^old$' "a file came over while git disagreed" || return 1
    assert_output_contains "$OUT" 'branch side moved on in both cs and code-sessions; code-sessions.s is kept, cs.s is at refs/remotes/cs/side' || return 1
    assert_output_contains "$OUT" 'wap@feat: git left as code-sessions has it: HEAD or the index moved on both sides; only its .cs/ is brought over' || return 1
    assert_eq "$ccs_head" "$(git -C "$feat" rev-parse HEAD)" || return 1
    assert_output_contains "$OUT" 'branches cs moved on, moved along: ff' || return 1
    assert_eq "$(git -C "$PROJECT" rev-parse ff)" "$(git -C "$wap" rev-parse ff)" || return 1
    assert_file_contains "$feat/.cs/cs-note.md" 'cs memory' || return 1
    assert_file_not_contains "$feat/feature.txt" 'cs work' "a tracked file came over onto code-sessions's own commit" || return 1

    # Once git agrees again, what cs changed meanwhile comes over: nothing was dropped.
    git -C "$wap" reset -q --hard "$(git -C "$PROJECT" rev-parse main)"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_file_contains "$wap/notes.txt" '^cs notes$' "cs's change made while git disagreed was dropped" || return 1
    assert_file_not_exists "$wap/gone.txt" "the path record lost what lies outside .cs/"
}

# A file code-sessions kept, changed there only or on both sides, stays code-sessions's
# when cs changes it again later, until the two sides hold the same content.
test_a_file_code_sessions_kept_stays_kept_when_cs_changes_it_later() {
    make_fixture
    printf 'old\n' > "$PROJECT/both.md"
    # Past the marks' 2 s margin, so the first rerun sees cs's files as unchanged.
    sleep 2.1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap status=0
    wap=$(ccs_dir wap)
    printf 'code-sessions edit\n' > "$wap/app.js"
    printf 'code-sessions both\n' > "$wap/both.md"
    printf 'cs both\n' > "$PROJECT/both.md"
    # Past the marks' 2 s margin, so the next run is the last to see these edits as new.
    sleep 2.1
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: files: 1 changed in code-sessions only, kept' || return 1
    assert_output_contains "$OUT" "wap: kept code-sessions's both.md (changed on both sides)" || return 1

    printf 'later cs edit\n' > "$PROJECT/app.js"
    printf 'later cs both\n' > "$PROJECT/both.md"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "a later cs change overwrote what code-sessions kept" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "wap: kept code-sessions's app.js (changed on both sides)" || return 1
    assert_output_contains "$OUT" "wap: kept code-sessions's both.md (changed on both sides)" || return 1
    assert_file_contains "$wap/app.js" '^code-sessions edit$' || return 1
    assert_file_contains "$wap/both.md" '^code-sessions both$' || return 1

    # Once both sides agree, the next cs change comes over again.
    cp "$wap/app.js" "$PROJECT/app.js"
    cp "$wap/both.md" "$PROJECT/both.md"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'app.js' || return 1
    assert_output_not_contains "$OUT" 'both.md' || return 1
    printf 'after\n' > "$PROJECT/app.js"
    printf 'after both\n' > "$PROJECT/both.md"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_file_contains "$wap/app.js" '^after$' || return 1
    assert_file_contains "$wap/both.md" '^after both$'
}

# A file code-sessions changed and then changed back to cs's content is no longer kept.
test_a_file_code_sessions_changed_back_is_no_longer_kept() {
    make_fixture
    # Past the marks' 2 s margin before each run that must not see the edit before it as new.
    sleep 2.1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap
    wap=$(ccs_dir wap)
    printf 'code-sessions edit\n' > "$wap/app.js"
    sleep 2.1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    cp "$PROJECT/app.js" "$wap/app.js"
    sleep 2.1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    printf 'later cs edit\n' > "$PROJECT/app.js"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'app.js' "a file changed back to cs's content was still kept" || return 1
    assert_file_contains "$wap/app.js" '^later cs edit$'
}

# A run that leaves a folder alone for a link in the way forgets nothing below it:
# once the folder is back, a file code-sessions kept is still kept.
test_a_file_code_sessions_kept_stays_kept_past_a_link_in_its_folder() {
    make_fixture
    mkdir -p "$PROJECT/sub"
    printf 'old\n' > "$PROJECT/sub/f"
    sleep 2.1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap away="$TEST_TMPDIR/away" outside="$TEST_TMPDIR/outside" status=0
    wap=$(ccs_dir wap)
    printf 'code-sessions edit\n' > "$wap/sub/f"
    printf 'cs edit\n' > "$PROJECT/sub/f"
    sleep 2.1
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "wap: kept code-sessions's sub/f (changed on both sides)" || return 1

    mkdir -p "$outside"
    mv "$wap/sub" "$away"
    ln -s "$outside" "$wap/sub"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "a link in the way was not reported" || { echo "$OUT"; return 1; }
    rm "$wap/sub"
    mv "$away" "$wap/sub"

    printf 'later cs edit\n' > "$PROJECT/sub/f"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "the run past the link forgot what code-sessions kept" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "wap: kept code-sessions's sub/f (changed on both sides)" || return 1
    assert_file_contains "$wap/sub/f" '^code-sessions edit$'
}

# A conversation's workflow state, which Claude Code rewrites whole rather than
# appends to: cs's file (WF_DIR/<name>), made before the first copy.
make_workflow() {  # name...
    WF_DIR="$CLAUDE/projects/$PROJECT_KEY/$WAP_ID/workflows"
    mkdir -p "$WF_DIR"
    local name
    for name in "$@"; do
        printf '{"workflow":"%s","step":1,"state":"running"}\n' "$name" > "$WF_DIR/$name"
    done
}

# The profile's copy of cs's workflow file name.
wf_copy() {  # name
    printf '%s/.claude/projects/%s/%s/workflows/%s' "$PROFILE" "$(project_key "$(ccs_dir wap)")" "$WAP_ID" "$1"
}

# cs rewrote a history file whole after the copy, and code-sessions left its
# copy as the run wrote it: the rerun brings cs's over and names it, no problem.
test_a_history_file_cs_rewrote_whole_comes_over() {
    make_fixture
    make_workflow wf_1.json
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local copy
    copy=$(wf_copy wf_1.json)
    cmp -s "$WF_DIR/wf_1.json" "$copy" || { echo "  FAIL: the workflow did not come with the first copy"; return 1; }
    printf '{"workflow":"wf_1.json","step":2,"state":"done"}\n' > "$WF_DIR/wf_1.json"

    run_move --session wap || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'Claude history of wap, 1 conversation(s), files to copy: 1 rewritten in cs since the last copy$' \
        || return 1
    assert_output_contains "$OUT" "rewritten in cs since the last copy and untouched in code-sessions, would be brought over: .*/$WAP_ID/workflows/wf_1.json$" \
        || return 1
    assert_file_contains "$copy" '"step":1' "a dry run wrote the copy" || return 1

    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_contains "$OUT" "rewritten in cs since the last copy and untouched in code-sessions, brought over: .*/$WAP_ID/workflows/wf_1.json$" \
        || return 1
    cmp -s "$WF_DIR/wf_1.json" "$copy" || { echo "  FAIL: cs's rewrite did not come over"; return 1; }
    # The copy that rerun wrote is its own too: cs's next rewrite comes as well.
    printf '{"workflow":"wf_1.json","step":3}\n{"pending":1}\n' > "$WF_DIR/wf_1.json"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    cmp -s "$WF_DIR/wf_1.json" "$copy" || { echo "  FAIL: cs's second rewrite did not come over"; return 1; }
    # Rewritten shorter, a start of the copy: no copy that went on, since no one wrote it.
    printf '{"workflow":"wf_1.json","step":3}\n' > "$WF_DIR/wf_1.json"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'went on past' || return 1
    cmp -s "$WF_DIR/wf_1.json" "$copy" || { echo "  FAIL: cs's shorter rewrite did not come over"; return 1; }
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_not_contains "$OUT" 'rewritten'
}

# Rewritten on both sides: code-sessions's copy stays, reported once per change in cs.
test_a_history_file_rewritten_on_both_sides_is_kept_and_reported_once() {
    make_fixture
    make_workflow wf_1.json
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local copy status=0
    copy=$(wf_copy wf_1.json)
    printf '{"workflow":"wf_1.json","step":2,"side":"cs"}\n' > "$WF_DIR/wf_1.json"
    printf '{"workflow":"wf_1.json","step":2,"side":"code-sessions"}\n' > "$copy"

    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "a history file rewritten on both sides was not reported" || { echo "$OUT"; return 1; }
    assert_eq 1 "$(grep -c "! continued in both cs and code-sessions, left as it is: .*/workflows/wf_1.json$" <<< "$OUT")" \
        "not reported exactly once" || { echo "$OUT"; return 1; }
    assert_file_contains "$copy" '"side":"code-sessions"' || return 1

    # Said once: the next rerun keeps code-sessions's quietly.
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_contains "$OUT" "1 file(s) code-sessions rewrote, unchanged in cs since the last run; code-sessions's kept" || return 1
    assert_file_contains "$copy" '"side":"code-sessions"' || return 1

    # cs's next rewrite is reported again, and still not copied over code-sessions's.
    printf '{"workflow":"wf_1.json","step":3,"side":"cs"}\n' > "$WF_DIR/wf_1.json"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "cs's next rewrite was not reported" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "! continued in both cs and code-sessions, left as it is: .*/workflows/wf_1.json$" || return 1
    assert_file_contains "$copy" '"side":"code-sessions"'
}

# Rewritten in code-sessions only: kept, and no problem, on this rerun and the next.
test_a_history_file_code_sessions_rewrote_whole_is_kept() {
    make_fixture
    make_workflow wf_1.json
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local copy
    copy=$(wf_copy wf_1.json)
    printf '{"workflow":"wf_1.json","step":2,"side":"code-sessions"}\n' > "$copy"

    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_not_contains "$OUT" 'continued in both' || return 1
    assert_output_contains "$OUT" "1 file(s) code-sessions rewrote, unchanged in cs since the last run; code-sessions's kept" || return 1
    assert_file_contains "$copy" '"side":"code-sessions"' || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_file_contains "$copy" '"side":"code-sessions"'
}

# A copy an earlier version of the script made has no signature in the record:
# nothing proves it untouched, so where cs rewrote it, it is kept and reported
# once, whatever its times say (a write put back with touch -r included).
test_a_history_copy_an_earlier_version_made_is_reported_once_and_kept() {
    make_fixture
    make_workflow wf_1.json wf_2.json wf_3.json
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    # What an earlier version left: the same record, without the signatures.
    rm "$PROFILE/.cs-to-code-sessions/wap/history.gz"
    # code-sessions rewrote wf_2 in place, and wf_3 too with its mtime put back; cs rewrote all three.
    printf '{"workflow":"wf_2.json","side":"code-sessions"}\n' > "$(wf_copy wf_2.json)"
    touch -r "$(wf_copy wf_3.json)" "$TEST_TMPDIR/wf_3.mtime"
    printf '{"workflow":"wf_3.json","side":"code-sessions"}\n' > "$(wf_copy wf_3.json)"
    touch -r "$TEST_TMPDIR/wf_3.mtime" "$(wf_copy wf_3.json)"
    local name status=0
    for name in wf_1.json wf_2.json wf_3.json; do
        printf '{"workflow":"%s","step":2,"side":"cs"}\n' "$name" > "$WF_DIR/$name"
    done

    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'untouched in code-sessions, brought over' || return 1
    for name in wf_1.json wf_2.json wf_3.json; do
        assert_eq 1 "$(grep -c "! continued in both cs and code-sessions, left as it is: .*/workflows/$name$" <<< "$OUT")" \
            "$name not reported exactly once" || { echo "$OUT"; return 1; }
    done
    assert_file_contains "$(wf_copy wf_1.json)" '"step":1' "the copy of wf_1 was replaced" || return 1
    assert_file_contains "$(wf_copy wf_2.json)" '"side":"code-sessions"' "the copy of wf_2 was replaced" || return 1
    assert_file_contains "$(wf_copy wf_3.json)" '"side":"code-sessions"' "the copy of wf_3 was replaced" || return 1

    # Said once: the next rerun keeps them quietly.
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_contains "$OUT" "code-sessions's kept"
}

# The way back takes the same care: a history file code-sessions rewrote whole
# comes into cs's copy where cs left it as the last run wrote it.
test_the_way_back_brings_a_history_file_code_sessions_rewrote_whole() {
    make_fixture
    make_workflow wf_1.json
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local copy back
    copy=$(wf_copy wf_1.json)
    back="$CLAUDE/projects/$(project_key "$(physical "$CSROOT")/wap-ccs")/$WAP_ID/workflows/wf_1.json"
    python3 "$BACK" --apply --session wap > "$TEST_TMPDIR/back.log" 2>&1 || { cat "$TEST_TMPDIR/back.log"; return 1; }
    cmp -s "$copy" "$back" || { echo "  FAIL: the workflow did not come back"; return 1; }
    printf '{"workflow":"wf_1.json","step":2,"side":"code-sessions"}\n' > "$copy"

    python3 "$BACK" --apply --session wap > "$TEST_TMPDIR/back.log" 2>&1 || { cat "$TEST_TMPDIR/back.log"; return 1; }
    assert_file_not_contains "$TEST_TMPDIR/back.log" '!' || return 1
    assert_file_contains "$TEST_TMPDIR/back.log" \
        "rewritten in code-sessions since the last copy and untouched in cs, brought over: .*/workflows/wf_1.json$" || return 1
    cmp -s "$copy" "$back" || { echo "  FAIL: code-sessions's rewrite did not come back"; return 1; }
}

test_features_cs_starts_or_ends_and_code_sessions_removes() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    add_feature late cs/late 88888888-8888-4888-8888-888888888888
    git -C "$PROJECT" worktree remove --force "$CSROOT/wap@fix"
    rm -rf "$PROFILE/sessions/wap@feat"
    git -C "$(ccs_dir wap)" worktree prune
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "wap@late: copy it to .*sessions/wap@late, a worktree of code-sessions's wap on cs/late" || return 1
    assert_output_contains "$OUT" 'wap@feat: code-sessions removed its copy after an earlier run; not copied again' || return 1
    assert_output_contains "$OUT" 'wap@fix: cs no longer has it; code-sessions keeps its copy' || return 1
    assert_eq "cs/late" "$(git -C "$(ccs_dir wap@late)" branch --show-current)" || return 1
    assert_not_exists "$PROFILE/sessions/wap@feat" || return 1
    assert_dir "$PROFILE/sessions/wap@fix" || return 1

    # A feature on a commit no branch holds cannot become a worktree of code-sessions's repository.
    local loose status=0
    loose=$(git -C "$PROJECT" commit-tree "$(git -C "$PROJECT" rev-parse 'main^{tree}')" -p main -m loose)
    git -C "$PROJECT" worktree add -q --detach "$CSROOT/wap@det" "$loose"
    mkdir -p "$CSROOT/wap@det/.cs/local"
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "wap@det: not copied: its detached HEAD ${loose:0:10} is on no branch the copy has" || return 1
    assert_not_exists "$PROFILE/sessions/wap@det"
}

# Without the paths both sides had, every file code-sessions deleted would look new in cs.
test_a_lost_record_stops_the_sync() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    rm "$PROFILE/.cs-to-code-sessions/wap/wap.paths.gz"
    rm "$(ccs_dir wap)/app.js"
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "stopped: the record of wap's last sync has lost" || return 1
    assert_file_not_exists "$(ccs_dir wap)/app.js" "a file code-sessions deleted came back"
}

# The ags-era script kept its record under another name; a rerun adopts it
# rather than taking the copy for a different wap.
test_a_record_from_the_ags_era_is_adopted() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    mv "$PROFILE/.cs-to-code-sessions" "$PROFILE/.cs-to-ags"
    printf 'later\n' > "$PROJECT/later.txt"
    git -C "$PROJECT" add later.txt
    git -C "$PROJECT" commit -q -m 'cs commit'
    run_move --session wap || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'already has a different' || return 1
    assert_dir "$PROFILE/.cs-to-ags" "a dry run renamed the record" || return 1
    assert_not_exists "$PROFILE/.cs-to-code-sessions" "a dry run renamed the record" || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'already has a different' || return 1
    assert_file_exists "$(ccs_dir wap)/later.txt" || return 1
    assert_dir "$PROFILE/.cs-to-code-sessions" || return 1
    assert_not_exists "$PROFILE/.cs-to-ags"
}

# cs execs claude in its place, which takes the lock with it: an engine or a
# session manager running in a folder shows the session is open. It is named,
# since what it writes later needs a rerun; the copy goes ahead.
test_a_session_open_in_cs_is_named_and_still_copied() {
    make_fixture
    echo $$ > "$FEAT/.cs/session.lock"
    local claude_pid shell_pid
    (cd "$PROJECT" && exec -a claude sleep 30) &
    claude_pid=$!
    (cd "$CSROOT/wap@fix" && exec sleep 30) &
    shell_pid=$!
    sleep 0.3
    run_move --session wap --apply || { kill "$claude_pid" "$shell_pid"; echo "$OUT"; return 1; }
    kill "$claude_pid" "$shell_pid" 2>/dev/null; wait "$claude_pid" "$shell_pid" 2>/dev/null
    assert_output_contains "$OUT" "note: open in cs right now: wap .pid $claude_pid: claude 30., wap@feat\. What it writes" || return 1
    assert_output_not_contains "$OUT" 'wap@fix .pid' "a plain process counted as an open session" || return 1
    assert_dir "$PROFILE/sessions/wap@feat" || return 1
    assert_file_not_exists "$PROFILE/sessions/wap@feat/.cs/session.lock" "cs's lock came along" || return 1
    assert_file_exists "$PROFILE/.claude/projects/$(project_key "$(ccs_dir wap)")/$WAP_ID.jsonl"
}

test_sessions_the_script_does_not_copy_say_why() {
    make_fixture
    local status=0
    # A session cs created in its own folder comes; an encrypted one stays.
    run_move --session wap-other || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'would copy .*claude-sessions/wap-other to .*sessions/wap-other' || return 1
    mkdir -p "$CSROOT/vault/.cs/local"
    printf '#!/bin/bash\n' > "$CSROOT/vault/.cs/local/pre-open"
    status=0
    run_move --session vault --apply || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'encrypted: its vault opens only with its password' || return 1
    assert_not_exists "$PROFILE/sessions/vault" || return 1
    status=0
    run_move --session nope || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'No cs session named nope' || return 1
    status=0
    run_move --session wap@feat || status=$?
    assert_eq 2 "$status" || return 1
    assert_output_contains "$OUT" 'name a base session' || return 1

    # A feature code-sessions already has under that name, and a folder git does not list, stay out; the rest comes.
    mkdir -p "$PROFILE/sessions/wap@feat" "$CSROOT/wap@gone/.cs"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap@feat: not copied: code-sessions already has a different wap@feat' || return 1
    assert_output_contains "$OUT" "wap@gone: not copied: not a registered worktree of wap's repository" || return 1
    assert_dir "$PROFILE/sessions/wap@fix" || return 1
    assert_not_exists "$PROFILE/sessions/wap@gone" || return 1

    rm -rf "$PROFILE/sessions"/* "$PROFILE/.cs-to-code-sessions"
    ln -s "$PROJECT" "$PROFILE/sessions/wap"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'code-sessions already has a different wap' || return 1
    assert_not_exists "$PROFILE/sessions/wap@fix" || return 1

    # A folder of that name this script did not copy is code-sessions's own, not a copy to update.
    rm "$PROFILE/sessions/wap"
    mkdir -p "$PROFILE/sessions/wap/.cs"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'code-sessions already has a different wap' || return 1
    assert_not_exists "$PROFILE/sessions/wap/app.js"
}

test_a_code_sessions_session_running_leaves_the_shared_config_files() {
    make_fixture
    local before
    before=$(shasum < "$PROFILE/.claude/.claude.json")
    # Anything run from the profile's bin may rewrite .claude.json under us.
    bash -c "exec -a '$(physical "$PROFILE")/.local/bin/cs' sleep 30" &
    local pid=$!
    sleep 0.5
    run_move --session wap --apply || { kill "$pid"; echo "$OUT"; return 1; }
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    assert_output_contains "$OUT" 'a code-sessions session is running' || return 1
    assert_eq "$before" "$(shasum < "$PROFILE/.claude/.claude.json")" || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'Claude project settings merged' || return 1
    assert_output_contains "$OUT" 'Codex trust added'
}

# A secret is never overwritten: a value that differs is said, and kept.
test_a_secret_that_differs_is_reported_and_kept() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    printf 'changed-in-cs' > "$STUB_STORE/wap/TOKEN"
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "secret TOKEN of wap differs between cs and code-sessions; code-sessions's is kept" || return 1
    assert_output_not_contains "$OUT" 'changed-in-cs' || return 1
    assert_eq "s3cret-value" "$(ccs_secret wap TOKEN)"
}

# The way back: code-sessions-to-cs.py gives cs a copy of its own, and cs's original
# stays as it was.
test_round_trip_with_code_sessions_to_cs() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap
    wap=$(ccs_dir wap)
    printf '{"n":"code-sessions"}\n' >> "$PROFILE/.claude/projects/$(project_key "$wap")/$WAP_ID.jsonl"
    local project_before feat_before
    project_before=$(fingerprint "$PROJECT"); feat_before=$(fingerprint "$FEAT")
    python3 "$BACK" --apply --session wap --session wap@feat --session wap@fix > "$TEST_TMPDIR/back.log" 2>&1 \
        || { cat "$TEST_TMPDIR/back.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/back.log" 'wap -> cs wap-ccs' || return 1
    assert_eq "$project_before" "$(fingerprint "$PROJECT")" "the way back changed cs's project" || return 1
    assert_eq "$feat_before" "$(fingerprint "$FEAT")" "the way back changed cs's feature" || return 1
    [ -d "$CSROOT/wap-ccs" ] && [ ! -L "$CSROOT/wap-ccs" ] || { echo "  FAIL: cs got no copy of its own"; return 1; }
    assert_eq "cs/feat" "$(git -C "$CSROOT/wap-ccs@feat" branch --show-current)" || return 1
    cmp -s "$PROFILE/.claude/projects/$(project_key "$wap")/$WAP_ID.jsonl" \
        "$CLAUDE/projects/$(project_key "$(physical "$CSROOT")/wap-ccs")/$WAP_ID.jsonl" \
        || { echo "  FAIL: the conversation code-sessions went on with did not come back"; return 1; }
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: files: nothing new in cs'
}

# What code-sessions itself makes of the result: it lists both features and resumes each
# session's conversation from the profile's copy.
test_code_sessions_opens_the_copied_session_and_its_features() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$TEST_TMPDIR/claude-argv" > "$TEST_TMPDIR/claude"
    chmod +x "$TEST_TMPDIR/claude"
    local env_profile=(CODE_SESSIONS_HOME="$PROFILE" CS_SESSIONS_ROOT="$PROFILE/sessions" CS_TRANSCRIPTS_DIR="$PROFILE/.claude/projects"
        CLAUDE_CONFIG_DIR="$PROFILE/.claude" CS_CLAUDE_DIR="$PROFILE/.claude" CLAUDE_CODE_BIN="$TEST_TMPDIR/claude")
    local features
    features=$(env "${env_profile[@]}" "$PROFILE_CS" wap -features --porcelain 2>&1) || { echo "$features"; return 1; }
    assert_output_contains "$features" 'feat' || return 1
    assert_output_contains "$features" 'fix' || return 1
    env "${env_profile[@]}" "$PROFILE_CS" wap < /dev/null > "$TEST_TMPDIR/launch.log" 2>&1 \
        || { cat "$TEST_TMPDIR/launch.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/claude-argv" "name wap --resume $WAP_ID" || { cat "$TEST_TMPDIR/launch.log"; return 1; }
    env "${env_profile[@]}" "$PROFILE_CS" wap@feat < /dev/null > "$TEST_TMPDIR/launch.log" 2>&1 \
        || { cat "$TEST_TMPDIR/launch.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/claude-argv" "name wap@feat --resume $FEAT_ID" || { cat "$TEST_TMPDIR/launch.log"; return 1; }
}

# A session cs created in its own folder (a folder in its sessions root, not a
# link) is copied as an adopted one is: a folder of its own in the profile with
# its own repository, its feature a worktree of that, and its history, prompts
# and secrets under the copy's path.
test_a_session_cs_created_in_its_own_folder_is_copied_with_its_feature() {
    make_fixture
    make_created mine "$MINE_ID"
    git -C "$CSROOT/mine" worktree add -q -b cs/task "$CSROOT/mine@task"
    mkdir -p "$CSROOT/mine@task/.cs/local"
    printf 'task_branch: cs/task\ncs_base: mine\nclaude_session_id: %s\n' "$TASK_ID" > "$CSROOT/mine@task/.cs/local/state"
    printf 'task work\n' > "$CSROOT/mine@task/task.txt"
    local task_key
    task_key=$(project_key "$(physical "$CSROOT/mine@task")")
    mkdir -p "$CLAUDE/projects/$task_key" "$STUB_STORE/mine"
    printf '{"task":1}\n' > "$CLAUDE/projects/$task_key/$TASK_ID.jsonl"
    printf 'mine-value' > "$STUB_STORE/mine/KEY"
    printf '{"display":"mine prompt","timestamp":5,"project":"%s"}\n' "$(physical "$CSROOT/mine")" >> "$CLAUDE/history.jsonl"
    local cs_before
    cs_before=$({ cs_side_fingerprint; git -C "$CSROOT/mine" worktree list --porcelain; fingerprint "$STUB_STORE/mine"; } | shasum)
    run_move --session mine --apply || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$({ cs_side_fingerprint; git -C "$CSROOT/mine" worktree list --porcelain; fingerprint "$STUB_STORE/mine"; } | shasum)" \
        "the cs side changed" || return 1
    assert_output_contains "$OUT" 'copy .*claude-sessions/mine to .*sessions/mine, with a repository of its own' || return 1
    assert_output_contains "$OUT" "mine@task: copy it to .*sessions/mine@task, a worktree of code-sessions's mine on cs/task" || return 1

    local mine task
    mine=$(ccs_dir mine); task=$(ccs_dir mine@task)
    [ -d "$mine" ] && [ ! -L "$PROFILE/sessions/mine" ] || { echo "  FAIL: mine is not a folder of its own"; return 1; }
    assert_eq "mine session" "$(git -C "$mine" log -1 --format=%s)" || return 1
    assert_eq "$mine/.git" "$(cd "$task" && cd -P "$(git rev-parse --git-common-dir)" && pwd)" \
        "the feature is not a worktree of the copy's repository" || return 1
    assert_eq "cs/task" "$(git -C "$task" branch --show-current)" || return 1
    assert_file_contains "$task/task.txt" 'task work' || return 1
    assert_eq "$PROFILE/sessions/mine/.cs/memory" "$(jq -r .autoMemoryDirectory "$mine/.claude/settings.local.json")" || return 1
    assert_file_exists "$PROFILE/.claude/projects/$(project_key "$mine")/$MINE_ID.jsonl" || return 1
    assert_file_exists "$PROFILE/.claude/projects/$(project_key "$task")/$TASK_ID.jsonl" || return 1
    assert_eq "$mine" "$(jq -r 'select(.display == "mine prompt") | .project' "$PROFILE/.claude/history.jsonl")" || return 1
    assert_eq "mine-value" "$(ccs_secret mine KEY)" || return 1
    assert_output_contains "$OUT" "ccs mine resumes conversation $MINE_ID" || return 1
    assert_file_exists "$PROFILE/.cs-to-code-sessions/mine/record.json" || return 1

    # A rerun brings over what cs changed since, as for a project cs adopted.
    printf 'more\n' >> "$CSROOT/mine/notes.md"
    run_move --session mine --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'in code-sessions at .*sessions/mine since an earlier run' || return 1
    assert_output_contains "$OUT" 'mine: files: 1 copied from cs' || return 1
    assert_file_contains "$mine/notes.md" '^more$'
}

# A session with .cs/ and no repository is copied too, whether cs created it
# in its own folder or adopted it.
test_a_session_without_a_repository_is_copied() {
    make_fixture
    printf 'claude_session_id: %s\nsession_name: wap-other\n' "$OTHER_ID" > "$CSROOT/wap-other/.cs/state-note"
    printf 'other notes\n' > "$CSROOT/wap-other/notes.md"
    local plain="$TEST_TMPDIR/projects/plain"
    mkdir -p "$plain/.cs/local"
    printf 'plain notes\n' > "$plain/notes.md"
    ln -s "$plain" "$CSROOT/plain"
    local cs_before
    cs_before=$({ cs_side_fingerprint; fingerprint "$plain"; } | shasum)
    run_move --session wap-other --session plain --apply || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$({ cs_side_fingerprint; fingerprint "$plain"; } | shasum)" "the cs side changed" || return 1
    assert_output_contains "$OUT" 'copy .*claude-sessions/wap-other to .*sessions/wap-other (it has no repository)' || return 1
    assert_output_contains "$OUT" 'copy .*projects/plain to .*sessions/plain (it has no repository)' || return 1
    local other
    other=$(ccs_dir wap-other)
    [ -d "$other" ] && [ ! -L "$PROFILE/sessions/wap-other" ] || { echo "  FAIL: wap-other is not a folder of its own"; return 1; }
    assert_not_exists "$other/.git" || return 1
    assert_file_contains "$other/notes.md" 'other notes' || return 1
    assert_file_contains "$(ccs_dir plain)/notes.md" 'plain notes' || return 1
    assert_file_exists "$PROFILE/.claude/projects/$(project_key "$other")/$OTHER_ID.jsonl" || return 1
    assert_eq "$other" "$(jq -r 'select(.display == "other prompt") | .project' "$PROFILE/.claude/history.jsonl")" || return 1

    printf 'cs later\n' >> "$CSROOT/wap-other/notes.md"
    printf 'code-sessions own\n' > "$other/own.md"
    run_move --session wap-other --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap-other: files: 1 copied from cs, 1 changed in code-sessions only, kept' || return 1
    assert_file_contains "$other/notes.md" '^cs later$' || return 1
    assert_file_contains "$other/own.md" 'code-sessions own'
}

# A session folder inside another's (here inner, a project of its own inside
# outer's) is copied once, as its own session; outer's copy has a link to it
# in its place, and no sync of outer's copy goes near it.
test_a_session_inside_another_is_copied_once_and_linked() {
    make_fixture
    make_nested
    local outer_src="$OUTER_SRC" inner_src="$INNER_SRC"
    local outer_key inner_key
    outer_key=$(project_key "$(physical "$outer_src")"); inner_key=$(project_key "$(physical "$inner_src")")
    mkdir -p "$CLAUDE/projects/$outer_key" "$CLAUDE/projects/$inner_key"
    printf '{"outer":1}\n' > "$CLAUDE/projects/$outer_key/$OUTER_ID.jsonl"
    printf '{"inner":1}\n' > "$CLAUDE/projects/$inner_key/$INNER_ID.jsonl"
    cs_now() { { cs_side_fingerprint; fingerprint "$outer_src"; git -C "$outer_src" status --porcelain; } | shasum; }
    local cs_before
    cs_before=$(cs_now)

    # outer alone, as a dry run: inner stays out of it, and is named.
    run_move --session outer || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'outer/inner is the folder of cs session inner, copied on its own: would be left out here, with a link to .*sessions/inner in its place; it has no copy yet: --session inner makes one' || return 1

    run_move --session outer --session inner --apply || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_now)" "the cs side changed" || return 1
    local outer inner
    outer=$(ccs_dir outer); inner=$(ccs_dir inner)
    assert_symlink "$PROFILE/sessions/outer/inner" || return 1
    assert_eq "$PROFILE/sessions/inner" "$(readlink "$PROFILE/sessions/outer/inner")" || return 1
    [ -d "$inner" ] && [ ! -L "$PROFILE/sessions/inner" ] || { echo "  FAIL: inner is not a folder of its own"; return 1; }
    assert_eq "inner" "$(git -C "$inner" log -1 --format=%s)" "inner's copy has not its own repository" || return 1
    assert_eq "outer" "$(git -C "$outer" log -1 --format=%s)" || return 1
    assert_file_contains "$outer/outer.txt" '^outer$' || return 1
    assert_eq "" "$(gzip -dc "$PROFILE/.cs-to-code-sessions/outer/outer.paths.gz" | tr '\0' '\n' | grep '^inner')" \
        "outer's record lists inner's files" || return 1
    assert_file_exists "$PROFILE/.claude/projects/$(project_key "$outer")/$OUTER_ID.jsonl" || return 1
    assert_file_exists "$PROFILE/.claude/projects/$(project_key "$inner")/$INNER_ID.jsonl" || return 1
    assert_not_exists "$PROFILE/.claude/projects/$(project_key "$outer")/$INNER_ID.jsonl" || return 1

    # A change on each side of cs lands once, in its own copy, and nothing is in the way.
    printf 'inner change\n' >> "$inner_src/inner.txt"
    printf 'new in inner\n' > "$inner_src/added.txt"
    printf 'outer change\n' >> "$outer_src/outer.txt"
    cs_before=$(cs_now)
    run_move --session outer --session inner --apply || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_now)" "the rerun changed the cs side" || return 1
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_contains "$OUT" 'outer/inner is the folder of cs session inner, copied on its own: left alone here' || return 1
    assert_output_contains "$OUT" 'outer: files: 1 copied from cs' || return 1
    assert_output_contains "$OUT" 'inner: files: 2 copied from cs' || return 1
    assert_file_contains "$inner/inner.txt" '^inner change$' || return 1
    assert_file_contains "$inner/added.txt" 'new in inner' || return 1
    assert_file_contains "$outer/outer.txt" '^outer change$' || return 1
    assert_symlink "$PROFILE/sessions/outer/inner" || return 1
    assert_eq "$PROFILE/sessions/inner" "$(readlink "$PROFILE/sessions/outer/inner")"
}

# A session whose folder is gone is not copied, and says so; its Claude
# conversations and prompts come as history under the names they had, and
# nothing else does. cs cannot open it either, so it is a note, not a problem.
test_a_session_whose_folder_is_gone_brings_only_its_history() {
    make_fixture
    local gone="$TEST_TMPDIR/projects/gone" key root_key
    ln -s "$gone" "$CSROOT/old"
    key=$(project_key "$(physical "$TEST_TMPDIR/projects")/gone")
    root_key=$(project_key "$(physical "$CSROOT")/old")
    mkdir -p "$CLAUDE/projects/$key" "$CLAUDE/projects/$root_key" "$CLAUDE/file-history/$GONE_ID" "$STUB_STORE/old"
    printf '{"gone":1}\n' > "$CLAUDE/projects/$key/$GONE_ID.jsonl"
    printf '{"gone":2}\n' > "$CLAUDE/projects/$root_key/$GONE_ROOT_ID.jsonl"
    printf 'snap\n' > "$CLAUDE/file-history/$GONE_ID/snap@v1"
    printf '{"display":"gone prompt","timestamp":6,"project":"%s/gone"}\n' "$(physical "$TEST_TMPDIR/projects")" \
        >> "$CLAUDE/history.jsonl"
    printf 'old-value' > "$STUB_STORE/old/TOKEN"
    local cs_before profile_before status=0
    cs_before=$({ cs_side_fingerprint; fingerprint "$STUB_STORE/old"; } | shasum)
    profile_before=$(fingerprint "$PROFILE")

    run_move --session old || status=$?
    assert_eq 0 "$status" "a session cs cannot open either failed the run" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^old: not copied$' || return 1
    assert_output_contains "$OUT" '  note: its directory .*projects/gone no longer exists, so cs cannot open it either' || return 1
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_contains "$OUT" 'its Claude history, as history under the same folder name(s), 2 conversation(s), files to copy: 3 new' || return 1
    assert_output_contains "$OUT" 'prompt history: 1 line(s) to append' || return 1
    status=0
    run_move --session old --apply --no-history || status=$?
    assert_eq 0 "$status" || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'Claude history' || return 1
    assert_output_not_contains "$OUT" 'prompt history' || return 1
    assert_eq "$profile_before" "$(fingerprint "$PROFILE")" "a dry run or --no-history wrote to the profile" || return 1

    status=0
    run_move --session old --apply || status=$?
    assert_eq 0 "$status" || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$({ cs_side_fingerprint; fingerprint "$STUB_STORE/old"; } | shasum)" "the cs side changed" || return 1
    cmp -s "$CLAUDE/projects/$key/$GONE_ID.jsonl" "$PROFILE/.claude/projects/$key/$GONE_ID.jsonl" \
        || { echo "  FAIL: the conversation under the link's target did not come"; return 1; }
    assert_file_exists "$PROFILE/.claude/projects/$root_key/$GONE_ROOT_ID.jsonl" || return 1
    assert_file_exists "$PROFILE/.claude/file-history/$GONE_ID/snap@v1" || return 1
    assert_eq "$(physical "$TEST_TMPDIR/projects")/gone" \
        "$(jq -r 'select(.display == "gone prompt") | .project' "$PROFILE/.claude/history.jsonl")" || return 1
    assert_file_not_contains "$PROFILE/.claude/history.jsonl" 'main prompt' "another session's prompts came along" || return 1
    # Nothing else: no folder, no record, no secret.
    assert_not_exists "$PROFILE/sessions/old" || return 1
    assert_not_exists "$PROFILE/.cs-to-code-sessions/old" || return 1
    if ccs_secret old TOKEN >/dev/null 2>&1; then echo "  FAIL: a secret of a session left behind came"; return 1; fi
    # A rerun has nothing new to bring.
    status=0
    run_move --session old --apply || status=$?
    assert_eq 0 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'its Claude history, as history under the same folder name(s), 2 conversation(s): nothing new' || return 1
    assert_output_not_contains "$OUT" 'prompt history'
}

# --all brings the folders beside the sessions too: one that is no session,
# and the root's .voice, file by file, keeping what code-sessions changed;
# .usage, .spawn and index.md stay, named once.
test_folders_beside_the_sessions_come_file_by_file() {
    make_fixture
    mkdir -p "$CSROOT/plain/sub" "$CSROOT/.voice" "$CSROOT/.usage" "$CSROOT/.spawn"
    printf 'report\n' > "$CSROOT/plain/sub/report.json"
    printf 'corpus\n' > "$CSROOT/.voice/corpus.md"
    printf 'profile\n' > "$CSROOT/.voice/profile.md"
    printf '{}\n' > "$CSROOT/.usage/cache.json"
    printf '# Sessions\n' > "$CSROOT/index.md"
    local cs_before
    cs_before=$(cs_side_fingerprint)
    run_move --all --apply || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    assert_output_contains "$OUT" '^plain (a folder, not a session)$' || return 1
    assert_output_contains "$OUT" 'copy .*claude-sessions/plain to .*sessions/plain, file by file' || return 1
    assert_output_contains "$OUT" '^\.voice (a folder, not a session)$' || return 1
    assert_eq 1 "$(grep -c 'Left out of' <<< "$OUT")" "what stays was not named once" || return 1
    assert_output_contains "$OUT" 'Left out of ~/.claude-sessions: .spawn (runtime files of a running cs), .usage (each install keeps its own usage cache), index.md (cs writes it afresh)' || return 1
    assert_file_contains "$PROFILE/sessions/plain/sub/report.json" 'report' || return 1
    assert_not_exists "$PROFILE/sessions/plain/.cs" || return 1
    assert_file_contains "$PROFILE/sessions/.voice/corpus.md" 'corpus' || return 1
    assert_file_contains "$PROFILE/sessions/.voice/profile.md" 'profile' || return 1
    assert_not_exists "$PROFILE/sessions/.usage" || return 1
    assert_not_exists "$PROFILE/sessions/.spawn" || return 1
    assert_not_exists "$PROFILE/sessions/index.md" || return 1

    # cs grows one file and adds another; code-sessions rewrote a third, and keeps it.
    printf 'more corpus\n' >> "$CSROOT/.voice/corpus.md"
    printf 'new\n' > "$CSROOT/plain/new.json"
    printf 'code-sessions profile\n' > "$PROFILE/sessions/.voice/profile.md"
    run_move --all --apply || { echo "$OUT"; return 1; }
    assert_file_contains "$PROFILE/sessions/.voice/corpus.md" '^more corpus$' || return 1
    assert_file_contains "$PROFILE/sessions/plain/new.json" 'new' || return 1
    assert_file_contains "$PROFILE/sessions/.voice/profile.md" '^code-sessions profile$' || return 1
    assert_output_contains "$OUT" "differ from cs's; code-sessions's kept: .*sessions/.voice/profile.md" || return 1
    assert_output_contains "$OUT" '^  \.voice: brought up to date (a folder, not a session)$'
}

# --all takes every session in the cs root, whatever kind, one after another,
# and ends with a line for each and the problems it met.
test_all_copies_every_session_and_ends_with_a_summary() {
    make_fixture
    make_created mine "$MINE_ID"
    ln -s "$TEST_TMPDIR/projects/gone" "$CSROOT/old"
    mkdir -p "$CSROOT/lost@feature/.cs" "$CSROOT/plain" "$CSROOT/.voice"
    printf 'x\n' > "$CSROOT/plain/file"
    printf 'corpus\n' > "$CSROOT/.voice/corpus.md"
    printf '# Sessions\n' > "$CSROOT/index.md"
    local cs_before profile_before status=0
    cs_before=$(cs_side_fingerprint)
    profile_before=$(fingerprint "$PROFILE")
    run_move --all || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_eq "$profile_before" "$(fingerprint "$PROFILE")" "the dry run changed the profile" || return 1
    assert_output_contains "$OUT" '^Summary of the dry run:$' || return 1
    assert_output_contains "$OUT" '^  mine: would be copied$' || return 1
    assert_output_contains "$OUT" '^  wap: would be copied$' || return 1
    assert_output_contains "$OUT" '^    wap@feat: would be copied$' || return 1
    assert_output_contains "$OUT" '^    wap@fix: would be copied$' || return 1
    assert_output_contains "$OUT" '^  wap-other: would be copied$' || return 1
    assert_output_contains "$OUT" '^  old: not copied: its folder is gone (it left no history)$' || return 1
    assert_output_contains "$OUT" '^  lost@feature: not copied: its base lost is not in cs$' || return 1
    assert_output_contains "$OUT" '^  plain: would be copied (a folder, not a session)$' || return 1
    assert_output_contains "$OUT" '^  \.voice: would be copied (a folder, not a session)$' || return 1
    assert_output_contains "$OUT" '^1 problem(s), each marked ! above\.$' || return 1
    assert_output_contains "$OUT" 'Left out of ~/.claude-sessions: index.md (cs writes it afresh)' || return 1

    status=0
    run_move --all --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    assert_output_contains "$OUT" '^Summary:$' || return 1
    assert_output_contains "$OUT" '^  mine: copied$' || return 1
    assert_output_contains "$OUT" '^  wap: copied$' || return 1
    assert_output_contains "$OUT" '^    wap@fix: copied$' || return 1
    assert_dir "$(ccs_dir mine)" || return 1
    assert_dir "$(ccs_dir wap@feat)" || return 1
    assert_dir "$(ccs_dir wap-other)" || return 1
    assert_not_exists "$PROFILE/sessions/old" || return 1
    assert_not_exists "$PROFILE/sessions/lost@feature" || return 1
    # Every session's record and every change in one log.
    assert_file_exists "$PROFILE/.cs-to-code-sessions/mine/record.json" || return 1
    assert_file_exists "$PROFILE/.cs-to-code-sessions/wap-other/record.json" || return 1
    jq -e 'select(.action == "copied" and .session == "mine")' "$PROFILE/.cs-to-code-sessions/log.jsonl" >/dev/null \
        || { echo "  FAIL: mine's copy is not in the log"; return 1; }

    # With the feature whose base is missing gone, a rerun brings each session up to date and has no
    # problem; the session whose folder is gone is a note.
    rm -r "$CSROOT/lost@feature"
    run_move --all --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^  wap: brought up to date$' || return 1
    assert_output_contains "$OUT" '^    wap@feat: brought up to date$' || return 1
    assert_output_contains "$OUT" '^  plain: brought up to date (a folder, not a session)$' || return 1
    assert_output_contains "$OUT" '^  old: not copied: its folder is gone (it left no history)$' || return 1
    assert_output_contains "$OUT" '^No problems\.$' || return 1
    assert_output_contains "$OUT" '^Done\. ccs -list lists the sessions' || return 1
    assert_output_not_contains "$OUT" 'ccs wap /'
}

# --all keeps the refusal: a name code-sessions already uses for another
# session is left as it is, and the rest still comes.
test_all_still_refuses_a_name_code_sessions_uses_for_another_session() {
    make_fixture
    mkdir -p "$PROFILE/sessions/wap-other/.cs"
    printf 'mine\n' > "$PROFILE/sessions/wap-other/own.txt"
    local before status=0
    before=$(fingerprint "$PROFILE/sessions/wap-other")
    run_move --all --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^wap-other: not copied$' || return 1
    assert_output_contains "$OUT" '! code-sessions already has a different wap-other; remove that one, then rerun' || return 1
    assert_output_contains "$OUT" '^  wap-other: not copied: code-sessions already has a different wap-other' || return 1
    assert_eq "$before" "$(fingerprint "$PROFILE/sessions/wap-other")" "code-sessions's own wap-other changed" || return 1
    assert_not_exists "$PROFILE/.cs-to-code-sessions/wap-other" || return 1
    assert_dir "$(ccs_dir wap)"
}

# The way back from a nested layout: cs's copy of outer links to cs's copy of
# inner, never into the profile. While inner cannot go back (it is open in
# code-sessions), the link that would lead into the profile is named, and the
# run that copies inner puts it right.
test_the_way_back_never_links_a_nested_session_into_the_profile() {
    make_fixture
    make_nested
    run_move --session outer --session inner --apply || { echo "$OUT"; return 1; }
    into_profile() {
        find "$CSROOT/outer-ccs" -type l -exec readlink {} \; | grep -F -e "$PROFILE" -e "$(physical "$PROFILE")"
    }
    local status=0
    echo $$ > "$PROFILE/sessions/inner/.cs/session.lock"
    python3 "$BACK" --apply --session outer --session inner > "$TEST_TMPDIR/back.log" 2>&1 || status=$?
    rm "$PROFILE/sessions/inner/.cs/session.lock"
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/back.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/back.log" 'outer -> cs outer-ccs' || return 1
    assert_file_contains "$TEST_TMPDIR/back.log" \
        '! links into the code-sessions profile left as they are, so cs would write there through them: .*sessions/inner' \
        || { cat "$TEST_TMPDIR/back.log"; return 1; }

    python3 "$BACK" --apply --session outer --session inner > "$TEST_TMPDIR/back.log" 2>&1 \
        || { cat "$TEST_TMPDIR/back.log"; return 1; }
    assert_symlink "$CSROOT/outer-ccs/inner" || return 1
    assert_eq "$CSROOT/inner-ccs" "$(readlink "$CSROOT/outer-ccs/inner")" || return 1
    assert_eq "" "$(into_profile)" "a link in cs's copy still leads into the profile" || return 1
    printf 'from cs\n' > "$CSROOT/outer-ccs/inner/written-from-cs.txt"
    assert_not_exists "$PROFILE/sessions/inner/written-from-cs.txt" "a write in cs's copy landed in the profile"
}

# A Python virtual environment as python -m venv, uv and an editable install
# leave it: its folder named by absolute path in pyvenv.cfg, bin/activate, each
# script's shebang, and the project's in a .pth file and direct_url.json.
make_venv() {  # session folder, as cs reaches it
    local venv="$1/.venv" site
    site="$venv/lib/python3.12/site-packages"
    mkdir -p "$venv/bin" "$site/lab-0.1.dist-info"
    printf 'home = /usr/bin\nversion = 3.12.0\ncommand = /usr/bin/python3 -m venv %s\n' "$venv" > "$venv/pyvenv.cfg"
    printf "VIRTUAL_ENV='%s'\nexport VIRTUAL_ENV\nOTHER='%s-other/x'\nMOUNTED='/mnt%s'\n" "$venv" "$1" "$1" \
        > "$venv/bin/activate"
    printf '#!%s/.venv/bin/python3\nimport pip\n' "$(physical "$1")" > "$venv/bin/pip"
    chmod +x "$venv/bin/pip"
    ln -s /usr/bin/python3 "$venv/bin/python3"
    printf 'BIN\0%s\0' "$venv" > "$venv/bin/native"
    printf '%s/src\n' "$1" > "$site/_editable_impl_lab.pth"
    printf '{"url":"file://%s","dir_info":{"editable":true}}\n' "$1" > "$site/lab-0.1.dist-info/direct_url.json"
    printf 'see %s/.venv\n' "$1" > "$1/venv-notes.md"
}

# In the copy each of those names the copy, so its pip installs into the copy
# and its editable install imports the copy's source; a binary and a file
# outside the environment stay byte for byte. What cs installs later comes the
# same way.
test_a_python_environment_in_the_copy_names_the_copy() {
    make_fixture
    make_created lab "$MINE_ID"
    local lab="$CSROOT/lab" copy="$PROFILE/sessions/lab" before
    make_venv "$lab"
    before=$(fingerprint "$lab")
    run_move --session lab --apply || { echo "$OUT"; return 1; }
    assert_eq "$before" "$(fingerprint "$lab")" "the cs side changed" || return 1
    assert_file_contains "$copy/.venv/bin/activate" "^VIRTUAL_ENV='$copy/.venv'$" || return 1
    assert_file_contains "$copy/.venv/bin/activate" "^OTHER='$lab-other/x'$" || return 1
    assert_file_contains "$copy/.venv/bin/activate" "^MOUNTED='/mnt$lab'$" || return 1
    assert_eq "#!$copy/.venv/bin/python3" "$(head -1 "$copy/.venv/bin/pip")" || return 1
    [ -x "$copy/.venv/bin/pip" ] || { echo "  FAIL: pip is no longer executable"; return 1; }
    assert_file_contains "$copy/.venv/pyvenv.cfg" "venv $copy/.venv$" || return 1
    assert_eq "$copy/src" "$(cat "$copy/.venv/lib/python3.12/site-packages/_editable_impl_lab.pth")" || return 1
    assert_file_contains "$copy/.venv/lib/python3.12/site-packages/lab-0.1.dist-info/direct_url.json" \
        "file://$copy\"" || return 1
    cmp -s "$lab/.venv/bin/native" "$copy/.venv/bin/native" || { echo "  FAIL: a binary was rewritten"; return 1; }
    cmp -s "$lab/venv-notes.md" "$copy/venv-notes.md" || { echo "  FAIL: a file outside the venv was rewritten"; return 1; }
    assert_eq "/usr/bin/python3" "$(readlink "$copy/.venv/bin/python3")" || return 1

    printf '#!%s/.venv/bin/python3\nimport tool\n' "$lab" > "$lab/.venv/bin/tool"
    run_move --session lab --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_contains "$OUT" 'lab: files: 1 copied from cs' || return 1
    assert_eq "#!$copy/.venv/bin/python3" "$(head -1 "$copy/.venv/bin/tool")" || return 1

    # The way back names cs's copy in the same places.
    python3 "$BACK" --apply --session lab > "$TEST_TMPDIR/back.log" 2>&1 || { cat "$TEST_TMPDIR/back.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/back.log" 'lab -> cs lab-ccs' || return 1
    assert_file_contains "$CSROOT/lab-ccs/.venv/bin/activate" "^VIRTUAL_ENV='$CSROOT/lab-ccs/.venv'$" || return 1
    assert_eq "#!$CSROOT/lab-ccs/.venv/bin/python3" "$(head -1 "$CSROOT/lab-ccs/.venv/bin/tool")"
}

# A feature worktree inside its own project is that feature's folder: a Claude
# working there is named as open in the feature.
test_a_session_open_in_a_feature_inside_its_project_is_named() {
    make_fixture
    local inside="$PROJECT/.worktrees/in" pid
    git -C "$PROJECT" worktree add -q -b cs/in "$inside"
    mkdir -p "$inside/.cs/local"
    printf 'task_branch: cs/in\ncs_base: wap\n' > "$inside/.cs/local/state"
    ln -s "$inside" "$CSROOT/wap@in"
    # It ends on its own; nothing here signals it.
    (cd "$inside" && exec -a claude sleep 4) &
    pid=$!
    sleep 0.3
    run_move --session wap || true
    wait "$pid"
    assert_output_contains "$OUT" "note: open in cs right now: wap@in .pid $pid: claude 4" || { echo "$OUT"; return 1; }
}

# A nested layout that changes after the copy. When cs stops having inner as a
# session, outer's copy keeps its link and leaves the path alone, saying so,
# with no problem on any run. When inner becomes a cs session after outer was
# copied, the folder outer's copy has there duplicates inner's copy: a problem
# until it is moved aside, and then a link takes its place.
test_a_nested_layout_that_changes_after_the_copy() {
    make_fixture
    make_nested
    run_move --session outer --session inner --apply || { echo "$OUT"; return 1; }
    rm "$CSROOT/inner"
    local status
    for _ in 1 2; do
        run_move --session outer --apply || { echo "$OUT"; return 1; }
        assert_output_contains "$OUT" 'outer/inner was the folder of cs session inner, which cs no longer has: the copy keeps its link to .*sessions/inner and leaves that path alone' \
            || return 1
    done
    assert_symlink "$PROFILE/sessions/outer/inner" || return 1

    rm -rf "$PROFILE/sessions"/* "$PROFILE/.cs-to-code-sessions"
    run_move --session outer --apply || { echo "$OUT"; return 1; }
    [ -d "$PROFILE/sessions/outer/inner" ] && [ ! -L "$PROFILE/sessions/outer/inner" ] \
        || { echo "  FAIL: inner, no session then, did not come with outer"; return 1; }
    ln -s "$INNER_SRC" "$CSROOT/inner"
    status=0
    run_move --session outer --session inner --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "outer/inner is the folder of cs session inner now, copied on its own, but outer's copy has its own inner there from before: left as it is; move .*sessions/outer/inner aside and rerun to put a link to inner's copy in its place" \
        || { echo "$OUT"; return 1; }
    rm -rf "$PROFILE/sessions/outer/inner"
    run_move --session outer --session inner --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_symlink "$PROFILE/sessions/outer/inner" || return 1
    assert_eq "$PROFILE/sessions/inner" "$(readlink "$PROFILE/sessions/outer/inner")"
}

# A session folder inside another one's that the outer repository tracks is
# part of the outer project: it comes with the outer copy, which then shows
# what cs shows, and the inner session is copied on its own as well.
test_a_session_folder_the_outer_repository_tracks_comes_with_it() {
    make_fixture
    local mono="$TEST_TMPDIR/projects/mono" copy
    mkdir -p "$mono/api/.cs/local" "$mono/.cs/local"
    git init -q -b main "$mono"
    printf '.cs/\n' > "$mono/.gitignore"
    printf 'api code\n' > "$mono/api/server.js"
    git -C "$mono" add -A
    git -C "$mono" commit -q -m mono
    ln -s "$mono" "$CSROOT/mono"
    ln -s "$mono/api" "$CSROOT/mono-api"
    run_move --session mono --session mono-api --apply || { echo "$OUT"; return 1; }
    copy=$(ccs_dir mono)
    [ -d "$copy/api" ] && [ ! -L "$copy/api" ] || { echo "  FAIL: api is not a folder in mono's copy"; return 1; }
    assert_eq "" "$(git -C "$copy" status --porcelain)" "mono's copy shows a change cs does not have" || return 1
    assert_output_contains "$OUT" "mono/api is the folder of cs session mono-api, and mono's repository tracks files there: copied with mono as well" \
        || return 1
    assert_file_contains "$(ccs_dir mono-api)/server.js" 'api code' || return 1
    printf 'more\n' >> "$mono/api/server.js"
    run_move --session mono --session mono-api --apply || { echo "$OUT"; return 1; }
    assert_file_contains "$copy/api/server.js" '^more$' || return 1
    assert_file_contains "$(ccs_dir mono-api)/server.js" '^more$'
}

# A session folder inside another one's whose session is not copied gets no
# link in the outer copy: it would lead into a different session code-sessions
# has under that name, or to a copy no run can make. The path is left out,
# and the run says why.
test_a_nested_session_that_is_not_copied_gets_no_link() {
    make_fixture
    make_nested
    mkdir -p "$PROFILE/sessions/inner/.cs"
    printf 'own\n' > "$PROFILE/sessions/inner/own.txt"
    local status=0
    run_move --session outer --session inner --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'outer/inner is the folder of cs session inner, which is not copied (code-sessions already has a different inner; remove that one, then rerun): left out here, with no link' \
        || { echo "$OUT"; return 1; }
    [ ! -L "$PROFILE/sessions/outer/inner" ] || { echo "  FAIL: outer's copy links to code-sessions's own inner"; return 1; }
    assert_not_exists "$PROFILE/sessions/outer/inner" || return 1

    # Encrypted, and not in the run: no link, and no hint that a run could copy it.
    rm -rf "$PROFILE/sessions/inner" "$PROFILE/sessions/outer" "$PROFILE/.cs-to-code-sessions"
    printf '#!/bin/bash\n' > "$INNER_SRC/.cs/local/pre-open"
    run_move --session outer --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'outer/inner is the folder of cs session inner, which is not copied (encrypted' || return 1
    assert_output_not_contains "$OUT" 'makes one' || return 1
    [ ! -L "$PROFILE/sessions/outer/inner" ] || { echo "  FAIL: outer's copy links to a copy no run makes"; return 1; }
    assert_not_exists "$PROFILE/sessions/outer/inner"
}

# A name code-sessions is still renaming away from is left. A rename of a
# profile session moves its folder first, and its transcripts, prompt
# history, settings and secrets after; until its record says finished they
# may still be under the old name, a copy would merge into them, and the
# rename could no longer finish. Here the rename stopped after the folder.
test_a_name_code_sessions_is_still_renaming_is_left() {
    make_fixture
    make_created ask "$MINE_ID"
    local own=12121212-1212-4212-8212-121212121212 key status=0
    key=$(project_key "$(physical "$PROFILE/sessions")/ask")
    mkdir -p "$PROFILE/sessions/ask-ags/.cs/local" "$PROFILE/.claude/projects/$key" "$PROFILE/.rename-profile-session"
    printf 'claude_session_id: %s\nsession_name: ask\n' "$own" > "$PROFILE/sessions/ask-ags/.cs/local/state"
    printf '{"own ask":1}\n' > "$PROFILE/.claude/projects/$key/$own.jsonl"
    printf '{"old": "ask", "new": "ask-ags", "started": "x", "finished": null}\n' \
        > "$PROFILE/.rename-profile-session/ask-to-ask-ags.json"
    # Another name's record, and one whose name only starts like ask's, stop nothing here.
    printf '{"old": "ask-to-b", "new": "c", "finished": null}\n' > "$PROFILE/.rename-profile-session/ask-to-b-to-c.json"
    run_move --session ask --apply || status=$?
    assert_eq 1 "$status" "a copy went ahead while ask was being renamed" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "! the rename of code-sessions's own ask to ask-ags has not finished (record .*ask-to-ask-ags.json); finish it, then rerun" \
        || { echo "$OUT"; return 1; }
    assert_not_exists "$PROFILE/sessions/ask" || return 1
    assert_eq "$own.jsonl" "$(ls "$PROFILE/.claude/projects/$key")" "the copy merged into the renamed session's conversations" \
        || return 1
    # A record that cannot be read may still be unfinished: the name stays left.
    printf '{' > "$PROFILE/.rename-profile-session/ask-to-ask-ags.json"
    status=0
    run_move --session ask --apply || status=$?
    assert_eq 1 "$status" "an unreadable record let the copy go ahead" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "! the rename of code-sessions's own ask to ask-ags has not finished" || return 1
    assert_not_exists "$PROFILE/sessions/ask" || return 1
    # Finished: the conversations moved with it, and cs's ask is copied under the name.
    mv "$PROFILE/.claude/projects/$key" "$PROFILE/.claude/projects/$key-ags"
    printf '{"old": "ask", "new": "ask-ags", "started": "x", "finished": "y"}\n' \
        > "$PROFILE/.rename-profile-session/ask-to-ask-ags.json"
    run_move --session ask --apply || { echo "$OUT"; return 1; }
    assert_dir "$(ccs_dir ask)" || return 1
    assert_file_exists "$PROFILE/.claude/projects/$key/$MINE_ID.jsonl" || return 1
    assert_file_not_exists "$PROFILE/.claude/projects/$key/$own.jsonl"
}

# Only a link whose target is not there any more is a folder gone, a note. A
# target that is there but cannot be looked at, or is not a folder, is a
# problem: cs may still open it from a shell that can read it.
test_a_session_folder_that_cannot_be_read_is_a_problem_not_gone() {
    make_fixture
    local status=0
    mkdir -p "$TEST_TMPDIR/locked/proj/.cs/local"
    printf 'claude_session_id: %s\n' "$MINE_ID" > "$TEST_TMPDIR/locked/proj/.cs/local/state"
    ln -s "$TEST_TMPDIR/locked/proj" "$CSROOT/locked"
    chmod 000 "$TEST_TMPDIR/locked"
    run_move --session locked || status=$?
    chmod 755 "$TEST_TMPDIR/locked"
    assert_eq 1 "$status" "a folder that cannot be read did not fail the run" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^  ! its directory .*locked/proj cannot be read: Permission denied$' || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'no longer exists' || return 1

    printf 'a file\n' > "$TEST_TMPDIR/a-file"
    ln -s "$TEST_TMPDIR/a-file" "$CSROOT/filed"
    status=0
    run_move --session filed || status=$?
    assert_eq 1 "$status" "a link to a file did not fail the run" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^  ! its link points at .*a-file, which is not a folder$' || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'no longer exists' || return 1

    ln -s "$CSROOT/loop" "$CSROOT/loop"
    status=0
    run_move --session loop || status=$?
    assert_eq 1 "$status" "a link that loops did not fail the run" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^  ! its directory .*loop cannot be read: Too many levels of symbolic links$' \
        || { echo "$OUT"; return 1; }

    # A target whose path runs through a file is not there: gone, a note.
    ln -s "$TEST_TMPDIR/a-file/proj" "$CSROOT/through"
    status=0
    run_move --session through || status=$?
    assert_eq 0 "$status" "a target that is not there failed the run" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '  note: its directory .*a-file/proj no longer exists, so cs cannot open it either'
}

# --all where the only thing left behind is a session whose folder is gone:
# cs cannot open it either, and its history comes, so the run has no problem.
test_all_with_only_a_folder_gone_has_no_problem() {
    make_fixture
    local key status=0
    ln -s "$TEST_TMPDIR/projects/gone" "$CSROOT/old"
    key=$(project_key "$(physical "$TEST_TMPDIR/projects")/gone")
    mkdir -p "$CLAUDE/projects/$key"
    printf '{"gone":1}\n' > "$CLAUDE/projects/$key/$GONE_ID.jsonl"
    run_move --all || status=$?
    assert_eq 0 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^  old: not copied: its folder is gone (history would be carried)$' || return 1
    assert_output_contains "$OUT" '^No problems\.$' || return 1
    run_move --all --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^  old: not copied: its folder is gone (history carried)$' || return 1
    assert_file_exists "$PROFILE/.claude/projects/$key/$GONE_ID.jsonl" || return 1
    run_move --all --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^  old: not copied: its folder is gone (history carried)$' || return 1
    status=0
    run_move --all --no-history || status=$?
    assert_eq 0 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '^  old: not copied: its folder is gone (its history left out: --no-history)$'
}

CODEX_THREAD=01a0ed7c-af4c-7d80-874a-99dab5257ca2
OTHER_THREAD=01a0ed6b-3af6-7292-a607-c2eb3eefc58a
CODEX_ROLLOUT=2026/09/29/rollout-2026-09-29T17-06-06-$CODEX_THREAD.jsonl
OTHER_ROLLOUT=2026/09/29/rollout-2026-09-29T16-47-02-$OTHER_THREAD.jsonl

# A session the fork's earlier trials opened under Codex, as cs creates one:
# its state says engine: codex, which the stable cs never reads, and it binds
# a Codex thread whose rollout is only in ~/.codex/sessions. Another thread
# is in Codex's home and its index too, bound by no session.
make_codex_session() {  # name id
    make_created "$1" "$2"
    sed -i.bak 's/^engine: claude$/engine: codex/' "$CSROOT/$1/.cs/local/state"
    rm "$CSROOT/$1/.cs/local/state.bak"
    printf '%s\n' "$CODEX_THREAD" > "$CSROOT/$1/.cs/local/codex-thread-id"
    mkdir -p "$HOME/.codex/sessions/2026/09/29"
    printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$CODEX_THREAD" > "$HOME/.codex/sessions/$CODEX_ROLLOUT"
    printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$OTHER_THREAD" > "$HOME/.codex/sessions/$OTHER_ROLLOUT"
    {
        printf '{"id":"%s","thread_name":"other thread","updated_at":"t1"}\n' "$OTHER_THREAD"
        printf '{"id":"%s","thread_name":"x thread","updated_at":"t2"}\n' "$CODEX_THREAD"
    } > "$HOME/.codex/session_index.jsonl"
}

# The stable cs opens Claude on claude_session_id whatever the state's engine
# says. The copy's state says claude, so ccs opens the same conversation; the
# run says so, and names the flag that opens the Codex thread instead. A
# rerun keeps code-sessions's engine and takes the conversation cs moved to.
test_a_session_cs_named_codex_for_opens_claude_in_code_sessions() {
    make_fixture
    make_codex_session x "$MINE_ID"
    local cs_before copy
    cs_before=$(cs_side_fingerprint)
    run_move --session x || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "engine: cs's state says codex, which the stable cs never runs: it opens Claude on conversation $MINE_ID\. The copy's state would say claude, so ccs x does the same; ccs x --engine codex opens its Codex thread $CODEX_THREAD instead, and makes Codex its engine" \
        || { echo "$OUT"; return 1; }
    run_move --session x --apply || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    assert_output_contains "$OUT" "The copy's state says claude, so ccs x does the same" || return 1
    copy=$(ccs_dir x)
    assert_file_contains "$copy/.cs/local/state" '^engine: claude$' || return 1
    assert_file_not_contains "$copy/.cs/local/state" 'codex' || return 1
    assert_file_contains "$copy/.cs/local/state" "^claude_session_id: $MINE_ID$" || return 1
    assert_eq "$CODEX_THREAD" "$(cat "$copy/.cs/local/codex-thread-id")" || return 1

    # code-sessions's launcher opens Claude on cs's conversation.
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$TEST_TMPDIR/claude-argv" > "$TEST_TMPDIR/claude"
    chmod +x "$TEST_TMPDIR/claude"
    env CODE_SESSIONS_HOME="$PROFILE" CS_SESSIONS_ROOT="$PROFILE/sessions" CS_TRANSCRIPTS_DIR="$PROFILE/.claude/projects" \
        CLAUDE_CONFIG_DIR="$PROFILE/.claude" CS_CLAUDE_DIR="$PROFILE/.claude" CLAUDE_CODE_BIN="$TEST_TMPDIR/claude" \
        "$PROFILE_CS" x < /dev/null > "$TEST_TMPDIR/launch.log" 2>&1 || { cat "$TEST_TMPDIR/launch.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/claude-argv" "name x --resume $MINE_ID" || { cat "$TEST_TMPDIR/launch.log"; return 1; }

    # cs moves on to another conversation; its state still says codex.
    sleep 0.05
    sed -i.bak "s/^claude_session_id: .*/claude_session_id: $OTHER_ID/" "$CSROOT/x/.cs/local/state"
    rm "$CSROOT/x/.cs/local/state.bak"
    printf '{"later":1}\n' > "$CLAUDE/projects/$(project_key "$(physical "$CSROOT/x")")/$OTHER_ID.jsonl"
    run_move --session x --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'engine:' || return 1
    assert_file_contains "$copy/.cs/local/state" '^engine: claude$' || return 1
    assert_file_contains "$copy/.cs/local/state" "^claude_session_id: $OTHER_ID$" || return 1

    # One that binds no Codex thread says what --engine codex does then.
    make_codex_session y "$TASK_ID"
    rm "$CSROOT/y/.cs/local/codex-thread-id"
    run_move --session y || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "ccs y --engine codex starts a Codex conversation instead (it binds none), and makes Codex its engine"
}

# The Codex thread a session binds comes with it: its rollout at the same
# place in the profile's Codex home, which is all Codex needs to resume it by
# id, and its name from session_index.jsonl. Only what grew in cs comes later;
# a rollout code-sessions went on with is kept. ~/.codex is only read.
test_the_codex_thread_a_session_binds_comes_with_it() {
    make_fixture
    make_codex_session x "$MINE_ID"
    local cs_before rollout="$PROFILE/.codex/sessions/$CODEX_ROLLOUT" status=0
    cs_before=$(cs_side_fingerprint)
    run_move --session x || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "Codex thread $CODEX_THREAD of x, rollout to copy: 1 new; its name in session_index.jsonl to add" \
        || { echo "$OUT"; return 1; }
    assert_not_exists "$rollout" "a dry run copied the rollout" || return 1
    run_move --session x --apply || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    cmp -s "$HOME/.codex/sessions/$CODEX_ROLLOUT" "$rollout" || { echo "  FAIL: the rollout did not come"; return 1; }
    assert_not_exists "$PROFILE/.codex/sessions/$OTHER_ROLLOUT" "a thread no session binds came" || return 1
    assert_eq "{\"id\":\"$CODEX_THREAD\",\"thread_name\":\"x thread\",\"updated_at\":\"t2\"}" \
        "$(cat "$PROFILE/.codex/session_index.jsonl")" || return 1

    # cs's thread grew; then code-sessions went on with it.
    printf '{"cs":2}\n' >> "$HOME/.codex/sessions/$CODEX_ROLLOUT"
    run_move --session x --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "Codex thread $CODEX_THREAD of x, rollout copied: 1 grown since the last copy$" || return 1
    cmp -s "$HOME/.codex/sessions/$CODEX_ROLLOUT" "$rollout" || { echo "  FAIL: the grown rollout did not come"; return 1; }
    printf '{"ccs":3}\n' >> "$rollout"
    run_move --session x --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "Codex thread $CODEX_THREAD of x: code-sessions went on with its rollout past cs's; kept" || return 1
    assert_file_contains "$rollout" '"ccs":3' || return 1
    assert_eq 1 "$(wc -l < "$PROFILE/.codex/session_index.jsonl" | tr -d ' ')" "the name was added twice" || return 1

    # Continued on both sides: kept as code-sessions has it, and a problem.
    printf '{"cs":3}\n' >> "$HOME/.codex/sessions/$CODEX_ROLLOUT"
    run_move --session x --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "! continued in both cs and code-sessions, left as it is: .*$CODEX_THREAD.jsonl" || return 1
    assert_file_contains "$rollout" '"ccs":3'
}

# The resume line names the conversation the copy has once this run is done:
# the one cs moved to, which the sync takes, even in a dry run.
test_the_resume_line_names_the_conversation_after_the_run() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    sleep 0.05
    printf '{"n":1}\n' > "$CLAUDE/projects/$PROJECT_KEY/$OTHER_ID.jsonl"
    sed -i.bak "s/^claude_session_id: .*/claude_session_id: $OTHER_ID/" "$PROJECT/.cs/local/state"
    rm "$PROJECT/.cs/local/state.bak"
    run_move --session wap || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "ccs wap resumes conversation $OTHER_ID" || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" "resumes conversation $WAP_ID" || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "ccs wap resumes conversation $OTHER_ID" || return 1
    assert_file_contains "$(ccs_dir wap)/.cs/local/state" "^claude_session_id: $OTHER_ID$"
}

# Prompt history names what was pasted by its hash in ~/.claude/paste-cache:
# the files the session's lines name come too, new ones only; another
# session's stay, and so does a name that is no hash.
test_pasted_contents_of_the_prompt_history_come_along() {
    make_fixture
    mkdir -p "$CLAUDE/paste-cache" "$PROFILE/.claude/paste-cache"
    printf 'pasted in wap\n' > "$CLAUDE/paste-cache/aaaa1111bbbb2222.txt"
    printf 'pasted in a feature\n' > "$CLAUDE/paste-cache/eeee5555ffff6666.txt"
    printf 'pasted elsewhere\n' > "$CLAUDE/paste-cache/cccc3333dddd4444.txt"
    printf 'cs copy\n' > "$CLAUDE/paste-cache/9999aaaa0000bbbb.txt"
    printf 'profile copy\n' > "$PROFILE/.claude/paste-cache/9999aaaa0000bbbb.txt"
    paste_line() {  # hash timestamp project
        printf '{"display":"[Pasted text #1]","pastedContents":{"1":{"id":1,"type":"text","contentHash":"%s"}},"timestamp":%s,"project":"%s"}\n' \
            "$1" "$2" "$3"
    }
    {
        paste_line aaaa1111bbbb2222 7 "$(physical "$PROJECT")"
        paste_line eeee5555ffff6666 8 "$FEAT_OLD"
        paste_line 9999aaaa0000bbbb 9 "$(physical "$PROJECT")"
        paste_line cccc3333dddd4444 10 "$(physical "$CSROOT/wap-other")"
        paste_line '../../x' 11 "$(physical "$PROJECT")"
        printf '{"display":"inline","pastedContents":{"1":{"id":1,"type":"text","content":"x"}},"timestamp":12,"project":"%s"}\n' \
            "$(physical "$PROJECT")"
    } >> "$CLAUDE/history.jsonl"
    local cs_before
    cs_before=$(cs_side_fingerprint)
    run_move --session wap || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'pasted contents: 2 file(s) of ~/.claude/paste-cache to copy' || { echo "$OUT"; return 1; }
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    assert_output_contains "$OUT" 'pasted contents: 2 file(s) of ~/.claude/paste-cache copied' || return 1
    cmp -s "$CLAUDE/paste-cache/aaaa1111bbbb2222.txt" "$PROFILE/.claude/paste-cache/aaaa1111bbbb2222.txt" \
        || { echo "  FAIL: the pasted text did not come"; return 1; }
    assert_file_exists "$PROFILE/.claude/paste-cache/eeee5555ffff6666.txt" || return 1
    assert_not_exists "$PROFILE/.claude/paste-cache/cccc3333dddd4444.txt" "another session's paste came" || return 1
    assert_file_contains "$PROFILE/.claude/paste-cache/9999aaaa0000bbbb.txt" '^profile copy$' || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'pasted contents' || return 1
    # A line copied by an earlier run still brings the file the profile lacks.
    rm "$PROFILE/.claude/paste-cache/aaaa1111bbbb2222.txt"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'pasted contents: 1 file(s) of ~/.claude/paste-cache copied' || return 1
    assert_file_exists "$PROFILE/.claude/paste-cache/aaaa1111bbbb2222.txt"
}

# Each Python virtual environment whose text files the copy rewrites is named
# once, with how many: in a dry run, when copying, and when a rerun brings a
# file cs changed there. One that names no cs session's folder is not named.
test_each_python_environment_the_copy_rewrites_is_named_once() {
    make_fixture
    make_created lab "$MINE_ID"
    make_venv "$CSROOT/lab"
    mkdir -p "$CSROOT/lab/tools/env/bin"
    printf 'home = /usr/bin\n' > "$CSROOT/lab/tools/env/pyvenv.cfg"
    printf '#!/usr/bin/python3\n' > "$CSROOT/lab/tools/env/bin/tool"
    run_move --session lab || { echo "$OUT"; return 1; }
    assert_eq 1 "$(grep -c 'Python virtual environment' <<< "$OUT")" "an environment was named more than once" \
        || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'lab/\.venv, a Python virtual environment: 5 text file(s) would be rewritten to name the copy$' \
        || { echo "$OUT"; return 1; }
    run_move --session lab --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'lab/\.venv, a Python virtual environment: 5 text file(s) rewritten to name the copy$' || return 1
    sleep 0.05
    printf '#!%s/.venv/bin/python3\nimport tool\n' "$CSROOT/lab" > "$CSROOT/lab/.venv/bin/tool"
    run_move --session lab || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'lab/\.venv, a Python virtual environment: 1 text file(s) would be rewritten to name the copy$'
}

test_all_and_session_together_is_an_error() {
    make_fixture
    local status=0
    run_move --all --session wap || status=$?
    assert_eq 2 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" '--all takes every session; leave out --session' || return 1
    status=0
    run_move || status=$?
    assert_eq 2 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'name a session with --session NAME, or take every one with --all'
}

commit_to() {  # repo branch message: a commit on branch with its tree, whatever is checked out
    local tree parent
    tree=$(git -C "$1" rev-parse "$2^{tree}"); parent=$(git -C "$1" rev-parse "$2")
    git -C "$1" update-ref "refs/heads/$2" "$(git -C "$1" commit-tree "$tree" -p "$parent" -m "$3")"
}

# wap with remotes: github (a bare repository) tracked by main and solo, fork,
# and tags; copied, then changed on each side. Elsewhere main and side move on
# the remote and pruned goes. cs tags (one tag the only way to its commit), pushes
# a new branch with its upstream and a commit past it, fetches with --prune, adds
# a remote mirror and pushes to fork. code-sessions moves the tag kept and its
# refs/remotes/github/side, points fork elsewhere, drops solo's upstream and
# fetches for itself (its FETCH_HEAD).
make_remote_drift() {
    make_fixture
    REMOTE="$TEST_TMPDIR/remote.git"
    git init -q --bare -b main "$REMOTE"
    git -C "$PROJECT" remote add github "$REMOTE"
    git -C "$PROJECT" branch side main
    git -C "$PROJECT" branch pruned main
    git -C "$PROJECT" branch solo main
    git -C "$PROJECT" push -q -u github main solo
    git -C "$PROJECT" push -q github side pruned
    git -C "$PROJECT" remote set-head github main
    git -C "$PROJECT" tag v1 main
    git -C "$PROJECT" tag kept main
    git init -q --bare -b main "$TEST_TMPDIR/fork.git"
    git -C "$PROJECT" remote add fork "$TEST_TMPDIR/fork.git"
    git -C "$PROJECT" push -q fork main
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    WAP=$(ccs_dir wap)

    local other="$TEST_TMPDIR/other" lone own
    git clone -q "$REMOTE" "$other"
    git -C "$other" commit -q --allow-empty -m 'main elsewhere'
    git -C "$other" push -q origin main
    git -C "$other" push -q origin \
        "$(git -C "$other" commit-tree 'origin/side^{tree}' -p origin/side -m 'side elsewhere'):refs/heads/side"
    git -C "$other" push -q origin --delete pruned

    git -C "$PROJECT" tag v2 main
    lone=$(git -C "$PROJECT" commit-tree 'main^{tree}' -p main -m 'only a tag leads here')
    git -C "$PROJECT" tag -a -m 'annotated' v3 "$lone"
    git -C "$PROJECT" branch pushed main
    commit_to "$PROJECT" pushed 'pushed'
    git -C "$PROJECT" push -q -u github pushed
    commit_to "$PROJECT" pushed 'past the push'
    git -C "$PROJECT" fetch -q --prune github
    git init -q --bare -b main "$TEST_TMPDIR/mirror.git"
    git -C "$PROJECT" remote add mirror "$TEST_TMPDIR/mirror.git"
    git -C "$PROJECT" push -q mirror main
    git -C "$PROJECT" push -q fork pushed

    own=$(git -C "$WAP" commit-tree 'main^{tree}' -p main -m 'code-sessions only')
    git -C "$WAP" tag -f kept "$own" > /dev/null
    git -C "$WAP" update-ref refs/remotes/github/side "$own"
    git -C "$WAP" remote set-url fork "$TEST_TMPDIR/elsewhere.git"
    git -C "$WAP" branch --unset-upstream solo
    git -C "$WAP" fetch -q "$REMOTE" main
}

# Every ref under the given prefixes, with what it points at, as git for-each-ref lists them.
refs_of() {  # repo prefix...
    local repo=$1; shift
    git -C "$repo" for-each-ref --format='%(refname) %(objectname) %(symref)' "$@"
}

test_a_rerun_adds_the_tags_cs_has_and_keeps_one_code_sessions_moved() {
    make_remote_drift || return 1
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq "$(refs_of "$PROJECT" refs/tags | grep -v '^refs/tags/kept ')" \
        "$(refs_of "$WAP" refs/tags | grep -v '^refs/tags/kept ')" "the copy's tags differ from cs's" || return 1
    assert_eq tag "$(git -C "$WAP" cat-file -t v3)" "the annotated tag lost its tag object" || return 1
    assert_eq "$(git -C "$PROJECT" rev-parse 'v3^{commit}')" "$(git -C "$WAP" rev-parse 'v3^{commit}')" || return 1
    assert_eq "$(git -C "$WAP" rev-parse main)" "$(git -C "$WAP" rev-parse 'kept^1')" \
        "code-sessions's tag was moved" || return 1
    assert_eq 1 "$status" "the tag code-sessions moved was not reported" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'tags new in cs, added: 2 (v2, v3)' || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "! tags code-sessions has on other objects than cs; code-sessions's are kept: 1 (kept)" \
        || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_not_contains "$OUT" 'tags'
}

test_a_rerun_brings_the_remote_tracking_refs_cs_fetched() {
    make_remote_drift || return 1
    local cs_before status=0
    cs_before=$(cs_side_fingerprint)
    run_move --session wap --apply || status=$?
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the rerun changed the cs side" || return 1
    assert_eq "$(refs_of "$PROJECT" refs/remotes/github refs/remotes/mirror | grep -v '^refs/remotes/github/side ')" \
        "$(refs_of "$WAP" refs/remotes/github refs/remotes/mirror | grep -v '^refs/remotes/github/side ')" \
        "the copy's remote-tracking refs differ from cs's" || return 1
    assert_eq 1 "$status" "the ref code-sessions moved was not reported" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'remote-tracking refs new in cs, added: 2 (github/pushed, mirror/main)' \
        || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'remote-tracking refs cs moved on, moved along: 1 (github/main)' || return 1
    assert_output_contains "$OUT" 'remote-tracking refs cs pruned, deleted: 1 (github/pruned)' || return 1
    assert_output_contains "$OUT" \
        "! remote-tracking refs moved on in both cs and code-sessions; code-sessions's are kept: 1 (github/side)" \
        || return 1
    assert_output_contains "$OUT" \
        "remote fork has another URL in code-sessions than in cs; its remote-tracking refs are code-sessions's own" \
        || return 1
    assert_eq refs/remotes/github/main "$(git -C "$WAP" symbolic-ref refs/remotes/github/HEAD)" || return 1
    assert_eq "$(git -C "$WAP" rev-parse main)" "$(git -C "$WAP" rev-parse 'refs/remotes/github/side^1')" \
        "code-sessions's remote-tracking ref was moved" || return 1
    assert_eq "" "$(git -C "$WAP" for-each-ref refs/remotes/fork/pushed)" "a ref came from a fork of another URL" || return 1
    # The same distance from upstream as in cs: main behind it, pushed ahead.
    local branch
    for branch in main pushed; do
        assert_eq "$(git -C "$PROJECT" rev-list --left-right --count "$branch...$branch@{upstream}")" \
            "$(git -C "$WAP" rev-list --left-right --count "$branch...$branch@{upstream}" 2>&1)" \
            "$branch is not as far from its upstream as in cs" || return 1
    done
    assert_eq "0	1" "$(git -C "$WAP" rev-list --left-right --count 'main...main@{upstream}')" || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_output_not_contains "$OUT" 'remote' || return 1
    # Pruned in cs after code-sessions moved it: kept, and said once.
    git -C "$PROJECT" update-ref -d refs/remotes/github/side
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" \
        "remote-tracking refs code-sessions moved or deleted, kept as they are though cs changed them: 1 (github/side)" \
        || return 1
    assert_eq "$(git -C "$WAP" rev-parse main)" "$(git -C "$WAP" rev-parse 'refs/remotes/github/side^1')" || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'remote'
}

test_a_rerun_gives_branches_and_remotes_the_settings_cs_has() {
    make_remote_drift || return 1
    run_move --session wap --apply
    assert_eq github/pushed "$(git -C "$WAP" rev-parse --abbrev-ref 'pushed@{upstream}' 2>&1)" \
        "pushed has not the upstream it has in cs" || return 1
    assert_eq "$(git -C "$PROJECT" config --get-regexp '^branch\.pushed\.')" \
        "$(git -C "$WAP" config --get-regexp '^branch\.pushed\.')" || return 1
    assert_eq "$(git -C "$PROJECT" config --get-regexp '^remote\.mirror\.')" \
        "$(git -C "$WAP" config --get-regexp '^remote\.mirror\.')" || return 1
    # What code-sessions set stays: solo has no upstream, fork its own URL.
    assert_eq "" "$(git -C "$WAP" config --get-regexp '^branch\.solo\.')" "solo's upstream came back" || return 1
    assert_eq "$TEST_TMPDIR/elsewhere.git" "$(git -C "$WAP" config remote.fork.url)" || return 1
    assert_output_contains "$OUT" 'branch settings (upstream and the rest) new in cs, added for: 1 (pushed)' \
        || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'remotes new in cs, added: 1 (mirror)' || return 1
    run_move --session wap --apply
    assert_output_not_contains "$OUT" 'settings' || return 1
    assert_output_not_contains "$OUT" 'remotes new' || return 1
    assert_eq "" "$(git -C "$WAP" config --get-regexp '^branch\.solo\.')" "solo's upstream came back"
}

test_a_branch_or_ref_a_rerun_adds_comes_with_its_cs_reflog() {
    make_remote_drift || return 1
    run_move --session wap --apply
    local ref
    for ref in refs/heads/pushed refs/remotes/github/pushed refs/remotes/mirror/main; do
        assert_eq "$(git -C "$PROJECT" reflog show --format='%H %gs' "$ref")" \
            "$(git -C "$WAP" reflog show --format='%H %gs' "$ref" 2>&1)" "$ref's reflog differs from cs's" || return 1
    done
    assert_eq 3 "$(git -C "$WAP" reflog show --format=%H pushed | wc -l | tr -d ' ')" || return 1
    assert_output_contains "$OUT" "branches new in cs, added: pushed (with cs's reflog)" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "added: 2 (github/pushed, mirror/main) (each with cs's reflog)" || return 1
}

test_a_rerun_leaves_the_copy_s_fetch_head_alone() {
    make_remote_drift || return 1
    local before="$TEST_TMPDIR/FETCH_HEAD.before"
    cp "$WAP/.git/FETCH_HEAD" "$before"
    run_move --session wap --apply
    cmp -s "$before" "$WAP/.git/FETCH_HEAD" || { echo "  FAIL: the sync overwrote the copy's FETCH_HEAD"; return 1; }
    assert_eq "$(git -C "$PROJECT" rev-parse pushed)" "$(git -C "$WAP" rev-parse refs/remotes/cs/pushed)" || return 1
}

test_a_dry_run_says_what_a_rerun_would_do_to_git() {
    make_remote_drift || return 1
    local profile_before
    profile_before=$(fingerprint "$PROFILE")
    run_move --session wap
    assert_eq "$profile_before" "$(fingerprint "$PROFILE")" "the dry run changed the profile" || return 1
    assert_output_contains "$OUT" "branches new in cs, would be added: pushed (with cs's reflog)" \
        || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'branch settings (upstream and the rest) new in cs, would be added for: 1 (pushed)' \
        || return 1
    assert_output_contains "$OUT" 'remotes new in cs, would be added: 1 (mirror)' || return 1
    assert_output_contains "$OUT" 'remote fork has another URL in code-sessions than in cs' || return 1
    assert_output_contains "$OUT" \
        "remote-tracking refs new in cs, would be added: 2 (github/pushed, mirror/main) (each with cs's reflog)" || return 1
    assert_output_contains "$OUT" 'remote-tracking refs cs moved on, would be moved along: 1 (github/main)' || return 1
    assert_output_contains "$OUT" 'remote-tracking refs cs pruned, would be deleted: 1 (github/pruned)' || return 1
    assert_output_contains "$OUT" "! remote-tracking refs moved on in both cs and code-sessions" || return 1
    assert_output_contains "$OUT" 'tags new in cs, would be added: 2 (v2, v3)' || return 1
    assert_output_contains "$OUT" "! tags code-sessions has on other objects than cs" || return 1
    # Many are counted, and only the first ten named.
    local n
    for n in 1 2 3 4 5 6 7 8 9 10 11 12; do git -C "$PROJECT" tag "many-$n" main; done
    run_move --session wap
    assert_output_contains "$OUT" 'tags new in cs, would be added: 14 (many-1, many-10, .* and 4 more)'
}

# wap with a github remote (main and foo, main tracked) and a tag v1, copied;
# OTHER is another clone of the remote, for pushes made elsewhere.
make_github_copy() {
    make_fixture
    REMOTE="$TEST_TMPDIR/remote.git"
    git init -q --bare -b main "$REMOTE"
    git -C "$PROJECT" remote add github "$REMOTE"
    git -C "$PROJECT" branch foo main
    git -C "$PROJECT" push -q -u github main
    git -C "$PROJECT" push -q github foo
    git -C "$PROJECT" remote set-head github main
    git -C "$PROJECT" tag v1 main
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    WAP=$(ccs_dir wap)
    OTHER="$TEST_TMPDIR/other"
    git clone -q "$REMOTE" "$OTHER"
}

has_ref() {  # repo ref: the ref itself, not one below it
    git -C "$1" show-ref -q --verify "$2"
}

test_a_rerun_prunes_before_it_adds_and_a_ref_it_cannot_write_stops_only_itself() {
    make_github_copy || return 1
    # Elsewhere foo goes and foo/bar and own/x come; code-sessions has a github/own of its own.
    git -C "$WAP" update-ref refs/remotes/github/own main
    git -C "$OTHER" push -q origin --delete foo
    git -C "$OTHER" push -q origin main:refs/heads/foo/bar main:refs/heads/own/x
    git -C "$OTHER" commit -q --allow-empty -m 'main elsewhere'
    git -C "$OTHER" push -q origin main
    git -C "$PROJECT" fetch -q --prune github
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "the ref that could not be written was not reported" || { echo "$OUT"; return 1; }
    assert_eq "$(git -C "$PROJECT" rev-parse refs/remotes/github/main)" "$(git -C "$WAP" rev-parse refs/remotes/github/main)" \
        "github/main did not move along" || { echo "$OUT"; return 1; }
    has_ref "$WAP" refs/remotes/github/foo/bar || { echo "  FAIL: github/foo/bar was not added"; echo "$OUT"; return 1; }
    ! has_ref "$WAP" refs/remotes/github/foo || { echo "  FAIL: github/foo, pruned in cs, is still there"; return 1; }
    has_ref "$WAP" refs/remotes/github/own || { echo "  FAIL: code-sessions's own github/own went"; return 1; }
    ! has_ref "$WAP" refs/remotes/github/own/x || { echo "  FAIL: github/own/x came through github/own"; return 1; }
    assert_output_contains "$OUT" 'remote-tracking refs cs pruned, deleted: 1 (github/foo)' || return 1
    assert_output_contains "$OUT" 'remote-tracking refs new in cs, added: 1 (github/foo/bar)' || return 1
    assert_output_contains "$OUT" 'remote-tracking refs cs moved on, moved along: 1 (github/main)' || return 1
    assert_output_contains "$OUT" "! wap: could not write the remote-tracking ref github/own/x: .*refs/remotes/github/own" \
        || return 1
    # The next run tries that one again, and only that one.
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "! wap: could not write the remote-tracking ref github/own/x" || return 1
    assert_output_not_contains "$OUT" 'remote-tracking refs'
}

test_a_tag_a_rerun_cannot_add_stops_only_itself() {
    make_github_copy || return 1
    git -C "$WAP" tag rel main
    git -C "$PROJECT" tag rel/1.0 main
    git -C "$PROJECT" tag v2 main
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "the tag that could not be added was not reported" || { echo "$OUT"; return 1; }
    has_ref "$WAP" refs/tags/v2 || { echo "  FAIL: v2 was not added"; echo "$OUT"; return 1; }
    has_ref "$WAP" refs/tags/rel || { echo "  FAIL: code-sessions's tag rel went"; return 1; }
    assert_output_contains "$OUT" 'tags new in cs, added: 1 (v2)' || return 1
    assert_output_contains "$OUT" "! wap: could not add the tag rel/1.0: .*refs/tags/rel" || return 1
}

test_a_reflog_naming_commits_the_copy_lacks_is_not_brought() {
    make_github_copy || return 1
    # cs pushes a draft, then amends it and pushes over it: the draft is left only in cs's reflogs.
    git -C "$PROJECT" branch forced main
    commit_to "$PROJECT" forced 'draft'
    git -C "$PROJECT" push -q -u github forced
    git -C "$PROJECT" update-ref refs/heads/forced \
        "$(git -C "$PROJECT" commit-tree 'main^{tree}' -p main -m 'draft, amended')"
    git -C "$PROJECT" push -q -f github forced
    run_move --session wap
    assert_output_contains "$OUT" 'branches new in cs, would be added: forced$' || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'remote-tracking refs new in cs, would be added: 1 (github/forced)$' || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'branches new in cs, added: forced$' || { echo "$OUT"; return 1; }
    git -C "$WAP" fsck --no-progress > "$TEST_TMPDIR/fsck.log" 2>&1 \
        || { echo "  FAIL: git fsck finds the copy broken"; cat "$TEST_TMPDIR/fsck.log"; return 1; }
    local ref
    for ref in refs/heads/forced refs/remotes/github/forced; do
        assert_eq 1 "$(git -C "$WAP" reflog show --format=%H "$ref" | wc -l | tr -d ' ')" \
            "$ref took a reflog naming a commit the copy lacks" || return 1
    done
    # A rerun moves forced along: its line, like the one that added it, names the sync.
    commit_to "$PROJECT" forced 'after the draft'
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'branches cs moved on, moved along: forced$' || { echo "$OUT"; return 1; }
    assert_eq "$(printf 'sync: from cs\nsync: from cs')" "$(git -C "$WAP" reflog show --format=%gs forced)" || return 1
}

test_a_line_code_sessions_wrote_without_a_message_keeps_its_reflog() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap sha log
    wap=$(ccs_dir wap)
    git -C "$PROJECT" branch side
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    sha=$(git -C "$PROJECT" commit-tree 'side^{tree}' -p side -m x)
    git -C "$PROJECT" update-ref -m 'commit: cs moves side' refs/heads/side "$sha"
    # code-sessions moves side there first, with plumbing that writes no message.
    git -C "$wap" fetch -q "$PROJECT" side
    git -C "$wap" update-ref refs/heads/side "$sha"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    log="$wap/.git/logs/refs/heads/side"
    assert_eq 2 "$(wc -l < "$log" | tr -d ' ')" "side's reflog is not the copy's own" || return 1
    if tail -n 1 "$log" | grep -q -F "$(printf '\t')"; then
        echo "  FAIL: the copy's line for side was replaced"; return 1
    fi
    assert_output_not_contains "$OUT" 'reflogs only cs went on with'
}

test_a_rerun_brings_the_reflogs_only_cs_went_on_with() {
    make_github_copy || return 1
    git -C "$PROJECT" branch late main
    commit_to "$PROJECT" late 'late one'
    commit_to "$PROJECT" late 'late two'
    # main moves on the remote, and both sides fetch it; foo moves, and only cs fetches it.
    git -C "$OTHER" commit -q --allow-empty -m 'main elsewhere'
    git -C "$OTHER" push -q origin main
    git -C "$PROJECT" fetch -q github
    git -C "$WAP" fetch -q --prune github
    git -C "$OTHER" push -q origin "$(git -C "$OTHER" commit-tree 'origin/foo^{tree}' -p origin/foo -m 'foo'):refs/heads/foo"
    git -C "$PROJECT" fetch -q github
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local ref
    for ref in refs/heads/late refs/remotes/github/foo; do
        assert_eq "$(git -C "$PROJECT" reflog show --format='%H %gs' "$ref")" \
            "$(git -C "$WAP" reflog show --format='%H %gs' "$ref" 2>&1)" "$ref's reflog is not cs's" || return 1
    done
    assert_output_contains "$OUT" "reflogs only cs went on with, brought over: 1 (github/foo)" || { echo "$OUT"; return 1; }
    # code-sessions's own fetch stays in its reflog.
    assert_eq 'fetch -q --prune github: fast-forward' \
        "$(git -C "$WAP" reflog show -1 --format=%gs refs/remotes/github/main)" || return 1
    # As the script before this change left a branch it added: git's one line for its update-ref.
    # cs/feat is checked out in the copy's wap@feat, which leaves it to that worktree, but for its reflog.
    local branch
    for branch in late cs/feat; do
        printf '%s %s t <t@t> 1700000000 +0000\n' 0000000000000000000000000000000000000000 \
            "$(git -C "$WAP" rev-parse "$branch")" > "$WAP/.git/logs/refs/heads/$branch"
    done
    run_move --session wap
    assert_output_contains "$OUT" "reflogs only cs went on with, would be brought over: 2 (cs/feat, late)" \
        || { echo "$OUT"; return 1; }
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    for branch in late cs/feat; do
        assert_eq "$(git -C "$PROJECT" reflog show --format='%H %gs' "$branch")" \
            "$(git -C "$WAP" reflog show --format='%H %gs' "$branch")" "$branch's reflog is not cs's" || return 1
    done
    assert_eq 'fetch -q --prune github: fast-forward' \
        "$(git -C "$WAP" reflog show -1 --format=%gs refs/remotes/github/main)" || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'reflogs'
}

test_a_fetch_head_an_earlier_run_wrote_is_put_back() {
    make_github_copy || return 1
    local source
    source=$(jq -r .source "$PROFILE/.cs-to-code-sessions/wap/record.json")
    git -C "$PROJECT" fetch -q github
    # As the script before this change left it: its fetch of cs's branches wrote the copy's FETCH_HEAD.
    git -C "$WAP" fetch -q "$source" '+refs/heads/*:refs/remotes/cs/*'
    grep -q -F "of $source" "$WAP/.git/FETCH_HEAD" || { echo "  FAIL: the fixture has no FETCH_HEAD of cs's branches"; return 1; }
    run_move --session wap
    assert_output_contains "$OUT" "FETCH_HEAD is an earlier run's fetch of cs's branches, would be replaced by cs's" \
        || { echo "$OUT"; return 1; }
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    cmp -s "$PROJECT/.git/FETCH_HEAD" "$WAP/.git/FETCH_HEAD" || { echo "  FAIL: the copy's FETCH_HEAD is not cs's"; return 1; }
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'FETCH_HEAD' || return 1
    # cs's names a commit code-sessions cannot get (on no ref of cs's): the copy is left none.
    git -C "$WAP" fetch -q "$source" '+refs/heads/*:refs/remotes/cs/*'
    git -C "$PROJECT" push -q github \
        "$(git -C "$PROJECT" commit-tree 'main^{tree}' -p main -m 'fetched, then gone'):refs/heads/gone"
    git -C "$PROJECT" fetch -q github gone
    git -C "$PROJECT" update-ref -d refs/remotes/github/gone
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "FETCH_HEAD is an earlier run's fetch of cs's branches, removed" || return 1
    assert_file_not_exists "$WAP/.git/FETCH_HEAD"
}

test_a_tag_code_sessions_deleted_stays_deleted() {
    make_github_copy || return 1
    git -C "$WAP" tag -d v1 > /dev/null
    git -C "$PROJECT" tag v2 main
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    has_ref "$WAP" refs/tags/v2 || { echo "  FAIL: v2 was not added"; return 1; }
    ! has_ref "$WAP" refs/tags/v1 || { echo "  FAIL: v1, deleted in code-sessions, came back"; return 1; }
    assert_output_contains "$OUT" 'tags new in cs, added: 1 (v2)' || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" 'tags' || return 1
    # A record from before the tag names were kept brings each tag the copy lacks.
    rm "$PROFILE/.cs-to-code-sessions/wap/tag-names.gz"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    has_ref "$WAP" refs/tags/v1 || { echo "  FAIL: a record without tag names did not bring v1"; return 1; }
    assert_output_contains "$OUT" 'tags new in cs, added: 1 (v1)'
}

run_test test_dry_run_changes_nothing
run_test test_apply_copies_the_session_and_leaves_cs_as_it_is
run_test test_rerun_brings_over_what_cs_changed_and_keeps_what_code_sessions_changed
run_test test_a_link_in_the_copy_is_never_written_through
run_test test_a_link_in_the_copy_s_reflogs_is_never_written_through
run_test test_a_link_in_the_copied_history_is_never_written_through
run_test test_a_file_cs_replaced_with_a_folder_comes_over
run_test test_an_unsearchable_folder_in_the_copy_stops_only_its_paths
run_test test_git_moved_on_both_sides_is_left_and_reported_once
run_test test_a_file_code_sessions_kept_stays_kept_when_cs_changes_it_later
run_test test_a_file_code_sessions_changed_back_is_no_longer_kept
run_test test_a_file_code_sessions_kept_stays_kept_past_a_link_in_its_folder
run_test test_a_history_file_cs_rewrote_whole_comes_over
run_test test_a_history_file_rewritten_on_both_sides_is_kept_and_reported_once
run_test test_a_history_file_code_sessions_rewrote_whole_is_kept
run_test test_a_history_copy_an_earlier_version_made_is_reported_once_and_kept
run_test test_the_way_back_brings_a_history_file_code_sessions_rewrote_whole
run_test test_features_cs_starts_or_ends_and_code_sessions_removes
run_test test_a_lost_record_stops_the_sync
run_test test_a_record_from_the_ags_era_is_adopted
run_test test_a_session_open_in_cs_is_named_and_still_copied
run_test test_sessions_the_script_does_not_copy_say_why
run_test test_a_code_sessions_session_running_leaves_the_shared_config_files
run_test test_a_secret_that_differs_is_reported_and_kept
run_test test_round_trip_with_code_sessions_to_cs
run_test test_code_sessions_opens_the_copied_session_and_its_features
run_test test_a_session_cs_created_in_its_own_folder_is_copied_with_its_feature
run_test test_a_session_without_a_repository_is_copied
run_test test_a_session_inside_another_is_copied_once_and_linked
run_test test_a_session_whose_folder_is_gone_brings_only_its_history
run_test test_folders_beside_the_sessions_come_file_by_file
run_test test_all_copies_every_session_and_ends_with_a_summary
run_test test_all_still_refuses_a_name_code_sessions_uses_for_another_session
run_test test_all_and_session_together_is_an_error
run_test test_the_way_back_never_links_a_nested_session_into_the_profile
run_test test_a_python_environment_in_the_copy_names_the_copy
run_test test_a_session_open_in_a_feature_inside_its_project_is_named
run_test test_a_nested_layout_that_changes_after_the_copy
run_test test_a_session_folder_the_outer_repository_tracks_comes_with_it
run_test test_a_nested_session_that_is_not_copied_gets_no_link
run_test test_a_name_code_sessions_is_still_renaming_is_left
run_test test_a_session_folder_that_cannot_be_read_is_a_problem_not_gone
run_test test_all_with_only_a_folder_gone_has_no_problem
run_test test_a_session_cs_named_codex_for_opens_claude_in_code_sessions
run_test test_the_codex_thread_a_session_binds_comes_with_it
run_test test_the_resume_line_names_the_conversation_after_the_run
run_test test_pasted_contents_of_the_prompt_history_come_along
run_test test_each_python_environment_the_copy_rewrites_is_named_once
run_test test_a_rerun_adds_the_tags_cs_has_and_keeps_one_code_sessions_moved
run_test test_a_rerun_brings_the_remote_tracking_refs_cs_fetched
run_test test_a_rerun_gives_branches_and_remotes_the_settings_cs_has
run_test test_a_branch_or_ref_a_rerun_adds_comes_with_its_cs_reflog
run_test test_a_rerun_leaves_the_copy_s_fetch_head_alone
run_test test_a_dry_run_says_what_a_rerun_would_do_to_git
run_test test_a_rerun_prunes_before_it_adds_and_a_ref_it_cannot_write_stops_only_itself
run_test test_a_tag_a_rerun_cannot_add_stops_only_itself
run_test test_a_reflog_naming_commits_the_copy_lacks_is_not_brought
run_test test_a_rerun_brings_the_reflogs_only_cs_went_on_with
run_test test_a_line_code_sessions_wrote_without_a_message_keeps_its_reflog
run_test test_a_fetch_head_an_earlier_run_wrote_is_put_back
run_test test_a_tag_code_sessions_deleted_stays_deleted
report_results
