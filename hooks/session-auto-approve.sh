#!/usr/bin/env bash
# ABOUTME: PermissionRequest hook that auto-approves writes to .cs/ metadata files
# ABOUTME: Falls through to normal permission prompt for all other operations

set -euo pipefail

INPUT=$(cat)

# Test before sourcing rather than catching a failed source with ||: under
# bash 3.2, cs's floor, a `.` of a missing file kills a non-interactive shell
# outright and the || never runs. A partial install would then abort the hook
# before its own decline, silently. When the library is absent the fallback
# is the env-only check this guard replaced, so the hook behaves as it used to.
_cs_lib="$(dirname "$0")/cs-resolve.sh"
# shellcheck source=cs-resolve.sh
# Parse-check before sourcing: a truncated or corrupt library is readable,
# and sourcing it aborts the hook at the syntax error, before the fallback
# below is even defined. One fork against several the hook already makes.
# errexit is suspended across the source, not just around it: a library that
# parses clean and fails when RUN (an inserted `=======` conflict marker is a
# valid-looking command) fails INSIDE the sourced file, where set -e fires
# before any outer || can catch it. Exit 2 out of a PreToolUse hook is
# Claude Code's blocking code. Whatever the source defined before failing
# still stands; the check below decides whether it is usable.
case $- in *e*) _cs_had_e=1 ;; *) _cs_had_e=0 ;; esac
set +e
[ -r "$_cs_lib" ] && "${BASH:-/bin/bash}" -n "$_cs_lib" 2>/dev/null && . "$_cs_lib"
if [ "$_cs_had_e" = 1 ]; then set -e; fi
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
# Only run in cs sessions
cs_resolve_session "$INPUT" || exit 0

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Only consider Write and Edit tools
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
    exit 0
fi

# Never auto-approve a path spelled with a .. component — it could resolve
# outside the session's .cs/ tree and defeat the permission prompt entirely.
case "$FILE_PATH" in
    ..|../*|*/../*|*/..) exit 0 ;;
esac

# A symlink at the target itself resolves inside .cs/ by its parent, so the
# canonicalization below cannot see it; only an lstat of the final component
# can. Session directories are git-shared by design, so a pulled symlink would
# otherwise redirect every auto-approved metadata write out of the session.
# cs never creates symlinks inside .cs/, so nothing legitimate lands here.
# An executable target is a script wherever it sits: Edit keeps the mode bits,
# so an approved Edit of one changes what runs.
if [ -L "$FILE_PATH" ] || [ -x "$FILE_PATH" ]; then
    exit 0
fi

# cs refuses to open a session whose .cs or .cs/local is a symlink (a clone
# can commit one), but a claude started in the directory by hand still runs
# this hook, and pwd -P below would approve writes into the link's target.
for _cs_dir in "$SESSION_DIR/.cs" "$META_DIR" "$META_DIR/local"; do
    if [ -L "$_cs_dir" ]; then
        exit 0
    fi
done

# Canonicalize the write target's parent directory so that no symlink or
# spelling can smuggle the path outside .cs/. A parent that doesn't resolve
# (e.g. a not-yet-created nested dir) falls through to the normal prompt.
PARENT_DIR="${FILE_PATH%/*}"
[ "$PARENT_DIR" = "$FILE_PATH" ] && PARENT_DIR="."
REAL_PARENT="$(cd "$PARENT_DIR" 2>/dev/null && pwd -P)" || exit 0
REAL_META="$(cd "$META_DIR" 2>/dev/null && pwd -P)" || REAL_META=""
REAL_CS="$(cd "$SESSION_DIR/.cs" 2>/dev/null && pwd -P)" || REAL_CS=""

# Only consider files whose real parent is inside the session's .cs/ tree.
# REL is that parent relative to the real .cs/, with the trailing slash that
# lets a bare "local/" match the same pattern as "local/queue/".
case "$REAL_PARENT/" in
    "${REAL_META:-/cs-no-meta}"/*) REL="${REAL_PARENT#"$REAL_META"}" ;;
    "${REAL_CS:-/cs-no-cs}"/*)     REL="${REAL_PARENT#"$REAL_CS"}" ;;
    *) exit 0 ;;
esac
REL="${REL#/}/"
# An encrypted session links memory, plans, claude-config and private into
# .cs/vault-mnt (lib/63-encrypt.sh), so every real path there starts with it.
REL="${REL#vault-mnt/}"

# Classify by the REAL path: a shared directory can carry a committed symlink
# whose spelled path looks like content (memory/notes -> ../local). Only the
# files cs reads as data for people and Claude are frictionless; everything
# cs itself acts on falls through to the prompt: .cs/local (pre-open runs at
# the next open; the queue and the mailbox execute), Claude Code's own config
# in an encrypted session, the secret-sync keys and files, the lock, and the
# vault's copies of the same control files, which sit beside its content.
# The one marker Claude arms by hand is pending-handoff: it names a handoff
# Claude already wrote, and session-start.sh rejects any name with a separator.
case "$REL" in
    local/|private/)
        [ "${FILE_PATH##*/}" = pending-handoff ] || exit 0 ;;
    local/*|claude-config/*|age-recipients/*|.git/*|vault-mnt/*) exit 0 ;;
    private/handoffs/*|private/checkpoints/*|private/narrative-archive/*) ;;
    private/*) exit 0 ;;
    /)
        case "${FILE_PATH##*/}" in
            session.lock|secrets.*) exit 0 ;;
        esac ;;
esac

jq -n '{
    hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: { behavior: "allow" }
    }
}'
