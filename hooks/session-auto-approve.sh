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
# The path is read exactly: $(jq -r) would strip a trailing newline, and
# the hook would then judge a name the write never touches. A path holding
# a newline anywhere falls through instead of being reasoned about.
FILE_PATH=$(echo "$INPUT" | jq -r '(.tool_input.file_path // "") + "x"')
FILE_PATH="${FILE_PATH%x}"
case "$FILE_PATH" in
    *'
'*) exit 0 ;;
esac

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

# A directory's real path, kept exact: $(pwd -P) would strip a trailing
# newline, so a directory named with one would never match the real parent
# of a write beneath it, and a decoy at the stripped name would stand in for
# it. A real path holding a newline anywhere fails instead: nothing cs makes
# is named that way, and every comparison below would be reasoning about a
# name it cannot hold.
_cs_nl='
'
_cs_realdir() {
    local real
    real="$(cd "$1" 2>/dev/null && pwd -P && printf x)" || return 1
    real="${real%x}"
    real="${real%"$_cs_nl"}"
    case "$real" in *"$_cs_nl"*) return 1 ;; esac
    printf '%s' "$real"
}

# Canonicalize the write target's parent directory so that no symlink or
# spelling can smuggle the path outside .cs/. A parent that doesn't resolve
# (e.g. a not-yet-created nested dir) falls through to the normal prompt.
PARENT_DIR="${FILE_PATH%/*}"
[ "$PARENT_DIR" = "$FILE_PATH" ] && PARENT_DIR="."
REAL_PARENT="$(_cs_realdir "$PARENT_DIR")" || exit 0
REAL_META="$(_cs_realdir "$META_DIR")" || REAL_META=""
REAL_CS="$(_cs_realdir "$SESSION_DIR/.cs")" || REAL_CS=""

# Only consider files whose real parent is inside the session's .cs/ tree,
# compared as the filesystem spelled them: on a case-sensitive filesystem a
# SESSION/ beside session/ is another directory, and folding case here
# would take its .cs/ for ours.
case "$REAL_PARENT/" in
    "${REAL_META:-/cs-no-meta}"/*|"${REAL_CS:-/cs-no-cs}"/*) ;;
    *) exit 0 ;;
esac

# The classification below is lowercased: APFS keeps the case a caller
# typed, so pwd -P returns LOCAL/ for the directory local/, and a spelling
# must not change what a path is. On a case-sensitive filesystem LOCAL is
# another directory and lowercasing only costs it the approval.
_cs_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
REAL_PARENT_LC="$(_cs_lower "$REAL_PARENT")"
REAL_META_LC="$(_cs_lower "$REAL_META")"
REAL_CS_LC="$(_cs_lower "$REAL_CS")"
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
    real="$(_cs_realdir "$1")" || return 1
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
# No link under a control directory is followed (audit C2, #886). A link
# there can alias a control file into content or content into a control
# file, and the shapes compound (chains, links inside linked directories,
# names ending in a newline, hops through the session root), so where a
# link points is never reasoned about: any symlink under .cs/local,
# .cs/age-recipients, .cs/private, .cs/claude-config, the project's .claude/
# or an in-session CLAUDE_CONFIG_DIR declines every write, and stderr names
# the first one found. The only links allowed are the ones cs places: an
# encrypted session's .cs/private and .cs/claude-config link into the vault
# mount (CS_VAULT_LINKS, lib/63-encrypt.sh), so those two roots are followed
# once, by identity, and the vault directory is scanned instead; inside
# claude-config, the shared names cs links to the shell's config dir.
# find -P never follows a link, and the walk has no depth bound: a planted
# link one level below the bound would be the next finding. The only prune
# is the project's .claude/worktrees directory, where `claude --worktree`
# keeps whole checkouts that Claude Code does not read as this session's
# config. A walk of a few thousand entries costs tens of milliseconds; an
# encrypted session's claude-config/projects grows with its transcripts and
# is where a prune would go if the scan ever needs bounding.
_cs_decline() {
    printf 'cs auto-approve: not approving, %s\n' "$1" >&2
    exit 0
}
# KEEP IN SYNC with lib/75-launch.sh _link_shared_claude_config, which links
# these names from the shell's config dir into .cs/claude-config.
_CS_SHARED_CONFIG_NAMES="settings.json settings.local.json CLAUDE.md AGENTS.md
rules skills commands agents hooks plugins output-styles keybindings.json vale"
_cs_shared_config_link() {
    # $1 a config dir's real path, $2 a link found under it. True when it is
    # one cs made: directly in the dir, by a shared name, and the same file
    # as that name in the shell's config dir: ~/.claude, or the
    # CLAUDE_CONFIG_DIR the shell had, which the launch keeps in
    # CLAUDE_SECURESTORAGE_CONFIG_DIR.
    local name="${2#"$1"/}" shared shell
    for shared in $_CS_SHARED_CONFIG_NAMES; do
        [ "$name" = "$shared" ] || continue
        for shell in "${HOME:-}/.claude" "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}"; do
            if [ -n "$shell" ] && [ "$2" -ef "$shell/$name" ]; then
                return 0
            fi
        done
    done
    return 1
}
_cs_glob_quote() {
    # $1 with find's pattern characters escaped, so -path matches it
    # literally: a session path holding [ ] * ? must not widen or miss
    # the prune.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\[/\\[}"
    s="${s//\]/\\]}"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    printf '%s' "$s"
}
_cs_links="$(mktemp "${TMPDIR:-/tmp}/cs-approve.XXXXXX")" || exit 0
trap 'rm -f "$_cs_links"' EXIT
_cs_scan_links() {
    # $1 a directory's real path; $2 "config" when cs's shared links are
    # allowed directly in it; $3 a subdirectory of it not to enter.
    # Paths come NUL-separated through a file, so a name with a newline in
    # it cannot split into pieces, and find failing on an unreadable
    # subdirectory declines rather than passing a partial scan.
    if [ -n "${3:-}" ]; then
        find -P "$1" \( -path "$(_cs_glob_quote "$1/$3")" -type d \) -prune -o -type l -print0 \
            > "$_cs_links" 2>/dev/null || _cs_decline "could not scan $1 for symlinks"
    else
        find -P "$1" -type l -print0 \
            > "$_cs_links" 2>/dev/null || _cs_decline "could not scan $1 for symlinks"
    fi
    while IFS= read -r -d '' _cs_link; do
        if [ "${2:-}" = config ] && _cs_shared_config_link "$1" "$_cs_link"; then
            continue
        fi
        _cs_decline "symlink under a control directory: $_cs_link"
    done < "$_cs_links"
}
_cs_scan_root() {
    # $1 a control directory as spelled; $2 its metadata root when cs links
    # it into the vault, else empty; $3, $4 as for _cs_scan_links. A root
    # link is allowed only when it is the same directory as the vault
    # mount's entry of that name and the mount is a real directory. A root
    # that does not exist has nothing under it to scan.
    if [ -L "$1" ]; then
        if [ -z "$2" ] || [ -L "$2/vault-mnt" ] || ! [ "$1" -ef "$2/vault-mnt/${1##*/}" ]; then
            _cs_decline "symlink under a control directory: $1"
        fi
    elif [ ! -e "$1" ]; then
        return 0
    fi
    _cs_root_real="$(_cs_realdir "$1")" || _cs_decline "control directory that does not resolve: $1"
    _cs_scan_links "$_cs_root_real" "${3:-}" "${4:-}"
}
# Usually one directory under two spellings: scanned once.
_cs_seen=""
for _cs_root in "$META_DIR" "$SESSION_DIR/.cs"; do
    if [ -n "$_cs_seen" ] && [ "$_cs_root" -ef "$_cs_seen" ]; then
        continue
    fi
    _cs_seen="$_cs_root"
    _cs_scan_root "$_cs_root/local" ""
    _cs_scan_root "$_cs_root/age-recipients" ""
    _cs_scan_root "$_cs_root/private" "$_cs_root"
    _cs_scan_root "$_cs_root/claude-config" "$_cs_root" config
done
# Claude Code reads the project's own .claude/ and .mcp.json from the
# session root, and both are git-shared: a link there can make an approved
# content write a setting, a hook or an MCP server.
_cs_scan_root "$SESSION_DIR/.claude" "" "" worktrees
if [ -L "$SESSION_DIR/.mcp.json" ]; then
    _cs_decline "symlink under a control directory: $SESSION_DIR/.mcp.json"
fi
REAL_SESSION_LC="$(_cs_realdir "$SESSION_DIR")" || exit 0
REAL_SESSION_LC="$(_cs_lower "$REAL_SESSION_LC")"

# The session's git directory: git reads config there and core.fsmonitor
# runs from it. A clone cannot deliver .git as a link, but a synced session
# can, and a .git file (a worktree) names its directory outright. Wherever it
# really is, a write beneath it prompts. The common directory of a worktree
# is reached through the file it names; nothing deeper is followed.
_cs_git="$SESSION_DIR/.git"
if [ -f "$_cs_git" ] && [ ! -L "$_cs_git" ]; then
    _cs_gitdir="$(sed -n 's/^gitdir: //p' "$_cs_git" 2>/dev/null | head -1)"
    case "$_cs_gitdir" in
        "") _cs_git="" ;;
        /*) _cs_git="$_cs_gitdir" ;;
        *) _cs_git="$SESSION_DIR/$_cs_gitdir" ;;
    esac
fi
if [ -n "$_cs_git" ] && [ -d "$_cs_git" ]; then
    _cs_ctl="$(_cs_realdir "$_cs_git")" || exit 0
    case "$REAL_PARENT_LC/" in
        "$(_cs_lower "$_cs_ctl")"/*) exit 0 ;;
    esac
fi

# Claude Code's active config directory: cs keeps a CLAUDE_CONFIG_DIR the
# shell set when the session has no vault config (lib/75-launch.sh), so it
# can be a content directory of this session. Inside the session, the
# metadata root or .cs/ it is one more control directory; outside, it is
# the user's own and the writes it covers never reach this hook's approval.
# The vault config cs points it at was scanned above, with its allow-list.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -e "$CLAUDE_CONFIG_DIR" ]; then
    _cs_ctl="$(_cs_realdir "$CLAUDE_CONFIG_DIR")" || exit 0
    _cs_ctl_lc="$(_cs_lower "$_cs_ctl")"
    case "$_cs_ctl_lc/" in
        "$REAL_SESSION_LC"/*|"${REAL_META_LC:-/cs-no-meta}"/*|"${REAL_CS_LC:-/cs-no-cs}"/*)
            case "$REAL_PARENT_LC/" in
                "$_cs_ctl_lc"/*) exit 0 ;;
            esac
            if ! [ "$CLAUDE_CONFIG_DIR" -ef "$META_DIR/claude-config" ] \
                && ! [ "$CLAUDE_CONFIG_DIR" -ef "$SESSION_DIR/.cs/claude-config" ]; then
                _cs_scan_root "$CLAUDE_CONFIG_DIR" ""
            fi ;;
    esac
fi

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
