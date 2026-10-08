#!/usr/bin/env bash
# ABOUTME: Tests opening a directory that already exists under the sessions root: a flat-layout
# ABOUTME: session migrates into .cs/ keeping its .gitignore, and a non-session directory is refused.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# A flat-layout session cs created long ago (its logs/session.log opens with
# cs's header), in a git repo whose .gitignore hides a key file. The structural
# migration commits with add -A, so the user's rule must still be there when
# it does.
test_flat_layout_migration_keeps_the_sessions_gitignore() {
    local dir="$CS_SESSIONS_ROOT/flat-session"
    mkdir -p "$dir/logs"
    printf 'Claude Code Session Log\nSession: flat-session\n' > "$dir/logs/session.log"
    printf '# Session Documentation Protocol\n' > "$dir/CLAUDE.md"
    printf 'secret.key\n' > "$dir/.gitignore"
    printf 'example-key\n' > "$dir/secret.key"
    (cd "$dir" && git init -q && git add .gitignore CLAUDE.md && git commit -q -m initial)

    "$CS_BIN" flat-session <<< "" >/dev/null 2>&1 || true

    assert_dir "$dir/.cs" "the flat session migrated into .cs/" || return 1
    assert_file_contains "$dir/.gitignore" '^secret\.key$' \
        "the session's own .gitignore rule survives the migration" || return 1
    assert_file_contains "$dir/.gitignore" '^\.cs/local/$' \
        "cs's .cs/local/ rule is merged in" || return 1
    assert_eq "" "$(git -C "$dir" ls-files secret.key)" \
        "the ignored key file is not committed by the migration" || return 1
}

echo ""
echo "Opening existing directories under the sessions root"
echo "===================================================="
echo ""

run_test test_flat_layout_migration_keeps_the_sessions_gitignore

report_results
