#!/usr/bin/env bash
# ABOUTME: Guards /wrap's memory index and reports dead references in its entries.
# ABOUTME: Run by that pass (wrap-sweep.md) from the session root; not a hook itself.

set -euo pipefail

INDEX=".cs/memory/MEMORY.md"
# The archive index: a reference entry listing, in MEMORY.md's own pointer
# shape, the pointers /wrap's memory pass moved out of MEMORY.md. Claude Code
# reads it only through its pointer in MEMORY.md.
ARCHIVE=".cs/memory/reference_memory_archive.md"
# The snapshot copies MEMORY.md, so it sits where the session keeps its cs
# files: .cs/private for an encrypted session, whose index lives in the vault,
# .cs/local for any other. cs-shared.sh (build.sh's copy of lib/02-shared.sh)
# holds that rule.
_shared="$(dirname "$0")/cs-shared.sh"
[ -r "$_shared" ] || { printf 'memory-index-guard: %s is missing; reinstall cs\n' "$_shared" >&2; exit 2; }
# shellcheck source=cs-shared.sh
. "$_shared"
if ! _snapshot_dir=$(cs_private_dir .cs); then
    printf 'memory-index-guard: .cs/private is locked; mount the session'"'"'s vault, then retry\n' >&2
    exit 2
fi
# While git tracks a file in that directory, a repository wrote it: a
# snapshot taken there would sit beside it, and a committed one restored would
# put the repository's index over this session's. Nothing runs until it is
# untracked.
if _tracked=$(cs_files_tracked_notice .cs "$PWD"); then
    printf 'memory-index-guard: %s\n' "$_tracked" >&2
    exit 2
fi
SNAPSHOT="$_snapshot_dir/memory-index.snapshot"
ARCHIVE_SNAPSHOT="$_snapshot_dir/memory-archive.snapshot"
# Claude Code loads MEMORY.md at every session start and cuts it past 25,000
# bytes or 200 lines, whichever comes first; pointers beyond the cut are never
# read again. Each budget keeps room under its limit for the pointers written
# between two sweeps (by Claude Code mid-conversation, or by another actor):
# 600 bytes is three or four of today's 150-180 byte pointers, and four lines
# is the same four pointers. Bytes, not characters; every line, blank and
# heading lines too.
BUDGET=24400
LINE_BUDGET=196

_die() {  # message
    printf 'memory-index-guard: %s\n' "$1" >&2
    exit 2
}

# The target of every pointer, one per line, sorted for comm. A pointer is a
# line opening with `- [title](target)`; a link later on the line is
# supporting text, not a pointer. grep exits 1 on no match and 2 on a read
# error, and only the first is an empty index.
_pointers() {  # file
    local lines rc=0
    lines=$(grep -E '^- \[[^]]*\]\([^)]+\)' "$1") || rc=$?
    [ "$rc" -le 1 ] || _die "cannot read $1"
    [ -n "$lines" ] || return 0
    printf '%s\n' "$lines" | sed -E 's/^- \[[^]]*\]\(([^)]+)\).*/\1/' | env LC_ALL=C sort -u
}

# Each line on stdin, after <label>, as a plain name: .cs/memory is tracked, so
# a clone chooses the entry file names and the pointers MEMORY.md holds.
_print_names() {  # label
    local name
    while IFS= read -r name; do
        printf '%s %s\n' "$1" "$(_cs_plain_name "$name" 160)"
    done
}

# Each pointer target on stdin that names an entry file with no file of that
# name in .cs/memory. A target names an entry file only when it is a bare file
# name ending in .md, with no / and no : in it; any other target (a URL, a
# path, a link with an #anchor) names none and is not checked. MEMORY.md and
# the archive share this rule.
_missing_entries() {
    local target
    while IFS= read -r target; do
        case "$target" in
            ''|*/*|*:*) continue ;;
            *.md) ;;
            *) continue ;;
        esac
        [ -f ".cs/memory/$target" ] || printf '%s\n' "$target"
    done
}

_need_index() {
    [ -f "$INDEX" ] || _die "no $INDEX here; run from the session root"
}

# Without a snapshot there is nothing to compare against, and check must not
# report that as a clean rewrite.
_need_snapshot() {
    [ -f "$SNAPSHOT" ] || _die "no snapshot at $SNAPSHOT; run snapshot before editing MEMORY.md"
    [ -r "$SNAPSHOT" ] || _die "cannot read $SNAPSHOT"
}

# Each backticked repository path in one memory entry, without interpreting
# its contents as shell text.
_reference_tokens() {  # entry
    env LC_ALL=C awk '
        {
            rest = $0
            while (match(rest, /`[^`]+`/)) {
                token = substr(rest, RSTART + 1, RLENGTH - 2)
                rest = substr(rest, RSTART + RLENGTH)
                if (token ~ /[[:space:][:cntrl:]]/ || token ~ /^[\/~]/ || token ~ /:/) continue
                if (token ~ /\// || token ~ /\.(sh|md|rs|mjs|json)$/) print token
            }
        }
    ' "$1"
}

_reference_live() {  # token
    local resolved root
    [ -f "$1" ] || [ -d "$1" ] || return 1
    resolved=$(_cs_write_target "./$1") || return 1
    root=$(pwd -P) || _die "cannot resolve the session root"
    case "$resolved" in "$root"|"$root"/*) return 0 ;; esac
    return 1
}

_refs() {
    local entry tokens token seen=$'\n' dead="" entries=0 references=0
    for entry in .cs/memory/*.md; do
        [ -f "$entry" ] || continue
        entries=$((entries + 1))
        tokens=$(_reference_tokens "$entry") || _die "cannot read $entry"
        while IFS= read -r token; do
            [ -n "$token" ] || continue
            case "$seen" in *$'\n'"$token"$'\n'*) continue ;; esac
            seen="$seen$token"$'\n'
            references=$((references + 1))
            if ! _reference_live "$token"; then
                dead="${dead}dead: $(_cs_plain_name "$entry" 240): $token"$'\n'
            fi
        done <<< "$tokens"
    done
    if [ -n "$dead" ]; then
        printf '%s' "$dead" | env LC_ALL=C sort
    else
        printf 'ok: %s references in %s entries, none dead\n' "$references" "$entries"
    fi
}

case "${1:-}" in
    refs)
        _refs
        ;;
    snapshot)
        [ -d .cs/memory ] || _die "no .cs/memory here; run from the session root"
        cs_mkdir_inside "$_snapshot_dir" || _die "cannot create $_snapshot_dir"
        # Claude Code writes MEMORY.md with the first entry, so a fresh
        # session's first sweep starts from an empty index.
        if [ -f "$INDEX" ]; then
            cs_write_atomic "$SNAPSHOT" cat "$INDEX" || _die "cannot write $SNAPSHOT"
        else
            cs_write_atomic "$SNAPSHOT" : || _die "cannot write $SNAPSHOT"
        fi
        # The archive too, so check sees a pointer lost from it; a session
        # with no archive yet snapshots it as empty.
        if [ -f "$ARCHIVE" ]; then
            cs_write_atomic "$ARCHIVE_SNAPSHOT" cat "$ARCHIVE" || _die "cannot write $ARCHIVE_SNAPSHOT"
        else
            cs_write_atomic "$ARCHIVE_SNAPSHOT" : || _die "cannot write $ARCHIVE_SNAPSHOT"
        fi
        printf 'snapshot: %s\n' "$SNAPSHOT"
        ;;
    check)
        _need_index
        _need_snapshot
        [ -f "$ARCHIVE_SNAPSHOT" ] || _die "no snapshot at $ARCHIVE_SNAPSHOT; run snapshot before editing MEMORY.md"
        [ -r "$ARCHIVE_SNAPSHOT" ] || _die "cannot read $ARCHIVE_SNAPSHOT"
        status=0
        before=$(_pointers "$SNAPSHOT")
        after=$(_pointers "$INDEX")
        # The archive's pointer to itself is no pointer: Claude Code reads the
        # archive only through its pointer in MEMORY.md.
        archived=""
        [ ! -f "$ARCHIVE" ] || archived=$(_pointers "$ARCHIVE" | sed '/^reference_memory_archive\.md$/d')
        archived_before=$(_pointers "$ARCHIVE_SNAPSHOT" | sed '/^reference_memory_archive\.md$/d')
        # A pointer gone from MEMORY.md is lost unless the archive holds it:
        # there it was moved, and check passes it. A pointer gone from the
        # archive is lost unless MEMORY.md holds it.
        gone=$(env LC_ALL=C comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')
        indexed=$(printf '%s\n%s\n' "$after" "$archived" | sed '/^$/d' | env LC_ALL=C sort -u)
        removed=$(printf '%s\n%s\n' "$before" "$archived_before" | sed '/^$/d' | env LC_ALL=C sort -u \
            | env LC_ALL=C comm -23 - <(printf '%s\n' "$indexed") | sed '/^$/d')
        if [ -n "$removed" ]; then
            printf '%s\n' "$removed" | _print_names 'removed:'
            status=1
        fi
        demoted=$(env LC_ALL=C comm -12 <(printf '%s\n' "$gone") <(printf '%s\n' "$archived") | sed '/^$/d')
        if [ -n "$demoted" ]; then
            printf '%s\n' "$demoted" | _print_names 'demoted:'
        fi
        duplicate=$(env LC_ALL=C comm -12 <(printf '%s\n' "$after") <(printf '%s\n' "$archived") | sed '/^$/d')
        if [ -n "$duplicate" ]; then
            printf '%s\n' "$duplicate" | _print_names 'duplicate:'
            status=1
        fi
        dangling=$(printf '%s\n%s\n' "$after" "$archived" | env LC_ALL=C sort -u | _missing_entries)
        if [ -n "$dangling" ]; then
            printf '%s\n' "$dangling" | _print_names 'dangling:'
            status=1
        fi
        # An entry this sweep wrote after the snapshot is in no snapshot, so
        # the entries on disk are checked too: each needs a pointer, in
        # MEMORY.md or the archive.
        entries=$(cd .cs/memory && for f in user_*.md feedback_*.md project_*.md reference_*.md; do
            [ -f "$f" ] || continue
            printf '%s\n' "$f"
        done | env LC_ALL=C sort)
        unindexed=$(env LC_ALL=C comm -23 <(printf '%s\n' "$entries") <(printf '%s\n' "$indexed") | sed '/^$/d')
        if [ -n "$unindexed" ]; then
            printf '%s\n' "$unindexed" | _print_names 'unindexed:'
            status=1
        fi
        size=$(wc -c < "$INDEX" | tr -d ' ')
        if [ "$size" -gt "$BUDGET" ]; then
            printf 'over budget: %s bytes > %s\n' "$size" "$BUDGET"
            status=1
        fi
        # Claude Code counts lines after turning a CRLF, a lone CR, U+2028
        # and U+2029 each into one newline, so each is one line break here
        # too: a CR ending a line is the CRLF's. awk counts a last line with
        # no newline, which wc -l does not.
        lines=$(env LC_ALL=C awk -v cr=$'\r' -v ls=$'\342\200\250' -v ps=$'\342\200\251' '
            function count(s, sep,   n, i) {
                n = 0
                while ((i = index(s, sep)) > 0) { n++; s = substr(s, i + length(sep)) }
                return n
            }
            {
                s = $0
                if (substr(s, length(s)) == cr) s = substr(s, 1, length(s) - 1)
                breaks += count(s, cr) + count(s, ls) + count(s, ps)
            }
            END { print NR + breaks }' "$INDEX")
        if [ "$lines" -gt "$LINE_BUDGET" ]; then
            printf 'over budget: %s lines > %s\n' "$lines" "$LINE_BUDGET"
            status=1
        fi
        printf 'MEMORY.md: %s/%s bytes\n' "$size" "$BUDGET"
        printf 'MEMORY.md: %s/%s lines\n' "$lines" "$LINE_BUDGET"
        exit "$status"
        ;;
    restore)
        _need_snapshot
        cs_write_atomic "$INDEX" cat "$SNAPSHOT" || _die "cannot write $INDEX"
        printf 'restored: %s from %s\n' "$INDEX" "$SNAPSHOT"
        ;;
    *)
        _die "usage: memory-index-guard.sh snapshot|check|restore|refs"
        ;;
esac
