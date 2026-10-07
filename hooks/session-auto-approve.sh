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
# Every comparison from here on is lowercased: APFS keeps the case a caller
# typed, so pwd -P returns LOCAL/ for the directory local/, and a spelling
# must not change what a path is. On a case-sensitive filesystem LOCAL is
# another directory and lowercasing only costs it the approval.
_cs_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
REAL_PARENT_LC="$(_cs_lower "$REAL_PARENT")"
REAL_META_LC="$(_cs_lower "$REAL_META")"
REAL_CS_LC="$(_cs_lower "$REAL_CS")"
case "$REAL_PARENT_LC/" in
    "${REAL_META_LC:-/cs-no-meta}"/*|"${REAL_CS_LC:-/cs-no-cs}"/*) ;;
    *) exit 0 ;;
esac
BASENAME_LC="$(_cs_lower "${FILE_PATH##*/}")"

# Classify by where the write really lands, not by the spelled path: a
# shared directory can carry a committed link into local/ (memory/notes ->
# ../local), and cs accepts a .cs/claude-config that links anywhere, so a
# config linked into memory/ makes a memory write a Claude Code setting.
# Each control directory is resolved from both metadata roots and a parent
# inside it falls through to the prompt. Only the files cs reads as data for
# people and Claude stay frictionless; everything cs itself acts on prompts:
# .cs/local (pre-open runs at the next open; the queue and the mailbox
# execute), Claude Code's own config in an encrypted session, the secret-sync
# keys, and the vault's copies of the same control files, which sit beside
# its content. The one marker Claude arms by hand is pending-handoff: it names
# a handoff Claude already wrote, and session-start.sh rejects any name with
# a separator.
_cs_real_lc() {
    # Real, lowercased path of $1, or nothing when it does not resolve.
    local real
    real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    _cs_lower "$real"
}
for _cs_root in "$META_DIR" "$SESSION_DIR/.cs"; do
    for _cs_name in local claude-config age-recipients .git; do
        _cs_ctl="$(_cs_real_lc "$_cs_root/$_cs_name")" || continue
        case "$REAL_PARENT_LC/" in
            "$_cs_ctl"/)
                [ "$_cs_name" = local ] && [ "$BASENAME_LC" = pending-handoff ] || exit 0 ;;
            "$_cs_ctl"/*) exit 0 ;;
        esac
    done
    _cs_ctl="$(_cs_real_lc "$_cs_root/private")" || continue
    case "$REAL_PARENT_LC/" in
        "$_cs_ctl"/)
            [ "$BASENAME_LC" = pending-handoff ] || exit 0 ;;
        "$_cs_ctl"/handoffs/*|"$_cs_ctl"/checkpoints/*|"$_cs_ctl"/narrative-archive/*) ;;
        "$_cs_ctl"/*) exit 0 ;;
    esac
done
# A link beneath a control directory can point the other way, into content:
# claude-config/settings.json -> ../memory/config.json lands the write in
# memory/, where it reads as content, while Claude Code reads it as its
# settings; local/queue -> ../memory/tasks does the same for the drain. Any
# link under a control directory that resolves to the target or to one of its
# ancestors declines. The scan is cheap: local/ and private/ hold few entries,
# and the links cs itself puts in claude-config point out at ~/.claude, so
# their targets never match a path under .cs/. Paths come NUL-separated
# through a file so a planted name with a newline in it cannot split into
# pieces that resolve to nothing and slip past.
TARGET_LC="$REAL_PARENT_LC/$BASENAME_LC"
_cs_links="$(mktemp "${TMPDIR:-/tmp}/cs-approve.XXXXXX")" || exit 0
trap 'rm -f "$_cs_links"' EXIT
for _cs_root in "$META_DIR" "$SESSION_DIR/.cs"; do
    for _cs_name in local claude-config age-recipients private; do
        _cs_ctl="$(cd "$_cs_root/$_cs_name" 2>/dev/null && pwd -P)" || continue
        find "$_cs_ctl" -type l -print0 2>/dev/null > "$_cs_links" || exit 0
        while IFS= read -r -d '' _cs_link; do
            _cs_dest="$(readlink "$_cs_link")" || exit 0
            case "$_cs_dest" in
                /*) ;;
                *) _cs_dest="${_cs_link%/*}/$_cs_dest" ;;
            esac
            if [ -d "$_cs_dest" ]; then
                _cs_real="$(cd "$_cs_dest" 2>/dev/null && pwd -P)" || continue
            else
                _cs_real="$(cd "${_cs_dest%/*}" 2>/dev/null && pwd -P)" || continue
                _cs_real="$_cs_real/${_cs_dest##*/}"
            fi
            _cs_real="$(_cs_lower "$_cs_real")"
            case "$TARGET_LC/" in
                "$_cs_real"/*) exit 0 ;;
            esac
        done < "$_cs_links"
    done
done

# At the root of .cs/ itself: the lock and the secret-sync files.
case "$REAL_PARENT_LC" in
    "$REAL_META_LC"|"$REAL_CS_LC")
        case "$BASENAME_LC" in
            session.lock|secrets.*) exit 0 ;;
        esac ;;
esac

jq -n '{
    hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: { behavior: "allow" }
    }
}'
