# ABOUTME: Rotates the current actor's narrative once it passes its byte budget: the
# ABOUTME: oldest '## ' sections move verbatim to .cs/narrative-archive/. Backs 'cs -narrative'.

# One line per '## ' heading: the heading's byte offset, a space, the heading.
# LC_ALL=C makes awk's length() count bytes, so offsets survive multibyte text
# (real headings carry an em dash). env hands the locale to awk alone; the
# shell's own locale is never changed. BSD awk counts bytes in any locale, so
# on it no test can tell this locale from none: the byte count is untestable
# there and is pinned only where awk counts characters.
_narrative_headings() {  # file
    env LC_ALL=C awk 'BEGIN { off = 0 } { if (substr($0, 1, 3) == "## ") print off, $0; off += length($0) + 1 }' "$1"
}

# Byte offset of the first heading to KEEP: the earliest one with at most KEEP
# bytes between it and EOF. When even the final section is larger than KEEP,
# that final heading is the cut, so the tail is one oversized section rather
# than nothing.
_narrative_cut() {  # headings, size, keep
    local headings="$1" size="$2" keep="$3" off line
    while read -r off line; do
        [ -n "$off" ] || continue
        if [ $((size - off)) -le "$keep" ]; then
            echo "$off"
            return 0
        fi
    done <<EOF
$headings
EOF
    printf '%s\n' "$headings" | tail -1 | cut -d' ' -f1
}

# What the live narrative holds after a rotation: its header block from the
# snapshot, then everything in the live file past the cut.
_narrative_kept_text() {  # snap, live, head_end, cut
    if [ "$3" -gt 0 ]; then
        head -c "$3" "$1" || return 1
    fi
    tail -c +$(($4 + 1)) "$2"
}

# Archive the oldest sections of this actor's narrative when the file is over
# CS_NARRATIVE_MAX_BYTES, leaving a tail of about CS_NARRATIVE_KEEP_BYTES.
rotate_narrative() {
    if [ -z "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}" ] || [ ! -d "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}" ]; then
        error "cs -narrative rotate must be run from inside a cs session"
    fi
    local session_dir="${CS_SESSION_DIR:-${CLAUDE_SESSION_DIR:-$(dirname -- "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}")}}"
    # The leave checks read a path as in the session by its spelling under
    # session_dir, so every path here is spelled from it: a metadata dir
    # spelled another way (relative, through a linked parent, with a ./)
    # would never match and would skip them. One that is a different
    # directory names a different session, and cs will not pick one.
    [ "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}" -ef "$session_dir/.cs" ] \
        || error "CLAUDE_SESSION_META_DIR is ${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}, not $session_dir/.cs; cs -narrative rotate needs both to name one session."
    local meta_dir="$session_dir/.cs"
    local actor
    actor=$(cs_actor_slug "$session_dir")
    local live="$meta_dir/memory/narrative.$actor.md"
    [ -f "$live" ] || error "No narrative for actor $actor at $live"
    [ -r "$live" ] || error "Cannot read $live"

    local max keep size
    max=$(_narrative_budget "${CS_NARRATIVE_MAX_BYTES:-}" "$CS_NARRATIVE_MAX_DEFAULT")
    keep=$(_narrative_budget "${CS_NARRATIVE_KEEP_BYTES:-}" "$CS_NARRATIVE_KEEP_DEFAULT")
    size=$(wc -c < "$live" | tr -d ' ')
    if [ "$size" -le "$max" ]; then
        info "nothing to rotate: narrative.$actor.md is $((size / 1024)) KB (budget $((max / 1024)) KB)"
        return 0
    fi
    # An encrypted session's narrative sits in the vault behind the .cs/memory
    # link, so its archive must too. A .cs/narrative-archive link is used as
    # it is; otherwise .cs/private holds the archive. With neither, the only
    # place left is plaintext, so the rotation refuses.
    local arch_root="$meta_dir/narrative-archive"
    if [ -L "$meta_dir/memory" ] && [ ! -L "$arch_root" ]; then
        if [ ! -d "$meta_dir/private" ]; then
            error "narrative.$actor.md lives on encrypted storage (.cs/memory is a link), and neither .cs/private nor .cs/narrative-archive is there to hold its archive. Link one of them into the vault, then run cs -narrative rotate again."
        fi
        arch_root="$meta_dir/private/narrative-archive"
    fi
    local arch_dir="$arch_root/$actor"
    # A link out of the session would carry the kept tail onto a file the
    # session does not own (audit M8); refuse before the first write.
    local out
    if out=$(_cs_write_leaves_session "$session_dir" "$live"); then
        case "$out" in "cs could not ask git"*) error "$out" ;; esac
        error "${live#"$session_dir"/} leads to $out, outside the session; cs will not rotate through it."
    fi
    # Work from a snapshot: the cut is computed on bytes that cannot change under
    # us, and the live file is compared against that snapshot before it is rewritten.
    # Its name is unpredictable: a clone can plant a link at any name it can
    # guess, and cp would follow it (Codex r2 #5). It is made in the
    # directory the live file's name sits in, which a .cs/memory link can
    # take out of the session even when the narrative there links back in.
    ! _cs_refuses_write rotate_narrative "$meta_dir/memory" || error "Cannot write to $meta_dir/memory"
    local snap
    snap=$(mktemp "$meta_dir/memory/.narrative.$actor.rotate.XXXXXX") || error "Cannot write to $meta_dir/memory"
    cp "$live" "$snap"
    # grep -c exits 1 on zero matches; under set -e -o pipefail that would end
    # cs instead of reaching the warning below, hence the || true.
    local headings count head_end cut
    headings=$(_narrative_headings "$snap")
    count=$(printf '%s\n' "$headings" | grep -c . || true)
    if [ "$count" -lt 2 ]; then
        rm -f "$snap"
        warn "narrative.$actor.md is over budget but has fewer than two sections; nothing can be archived without touching the tail"
        return 0
    fi
    local first
    first="${headings%%$'\n'*}"
    head_end="${first%% *}"
    cut=$(_narrative_cut "$headings" "$size" "$keep")
    if [ "$cut" -le "$head_end" ]; then
        rm -f "$snap"
        info "nothing to rotate: the first section already starts the retained tail"
        return 0
    fi

    local sections through
    sections=$(printf '%s\n' "$headings" | awk -v c="$cut" '$1 + 0 < c + 0' | grep -c . || true)
    through=$(printf '%s\n' "$headings" | awk -v c="$cut" '$1 + 0 < c + 0' \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1 || true)
    [ -n "$through" ] || through="undated"

    # Nor may the archive chunk land outside the session.
    if out=$(_cs_write_leaves_session "$session_dir" "$arch_dir"); then
        rm -f "$snap"
        case "$out" in "cs could not ask git"*) error "$out" ;; esac
        error "${arch_dir#"$session_dir"/} leads to $out, outside the session; cs will not rotate through it."
    fi
    # The check above resolves the archive dir's parent, which need not
    # exist yet; mkdir -p makes every missing level under the nearest one
    # that does, so cs_mkdir_inside checks that one.
    cs_mkdir_inside "$arch_dir" || { rm -f "$snap"; error "Cannot write to $arch_dir"; }
    [ -w "$arch_dir" ] || { rm -f "$snap"; error "Cannot write to $arch_dir"; }
    # Every temp name here is unpredictable: a clone can commit any name it
    # can guess, as a link out of the session (audit M8, Codex r1).
    local body
    body=$(mktemp "$arch_dir/.body.XXXXXX") || { rm -f "$snap"; error "Cannot write to $arch_dir"; }
    # head first, tail second: the bounded producer runs to completion and the
    # consumer reads all of it. The other order lets head close the pipe early
    # and tail die of SIGPIPE, which pipefail turns into a failed rotation on
    # any file whose kept tail is larger than the pipe buffer.
    head -c "$cut" "$snap" | tail -c +$((head_end + 1)) > "$body"
    local blob chunk chunk_tmp
    # The id of the text itself: git runs from the caller's directory, which
    # can sit in a repository a clone laid out, and would otherwise run the
    # clean filter that repository's config names on the text first.
    blob=$(git hash-object --no-filters -- "$body" | cut -c1-8)
    chunk="$arch_dir/$through-$blob.md"
    if [ -L "$chunk" ]; then
        rm -f "$body" "$snap"
        error "archive chunk $chunk is a symlink; cs will not rotate through it."
    fi
    chunk_tmp=$(mktemp "$arch_dir/.chunk.XXXXXX") || { rm -f "$body" "$snap"; error "Cannot write to $arch_dir"; }
    {
        printf '<!-- rotated from narrative.%s.md: %s sections through %s -->\n' "$actor" "$sections" "$through"
        printf '<!-- verbatim copy of the sections that preceded the live tail; never edited -->\n\n'
        cat "$body"
    } > "$chunk_tmp"
    rm -f "$body"
    local created=0
    if [ -f "$chunk" ]; then
        if cmp -s "$chunk" "$chunk_tmp"; then
            rm -f "$chunk_tmp"
        else
            rm -f "$chunk_tmp" "$snap"
            error "archive chunk $chunk exists with different content; refusing to overwrite"
        fi
    else
        mv "$chunk_tmp" "$chunk"
        created=1
    fi

    # Test seam: lets a suite change the live file between the snapshot and the
    # rewrite, which is the window every guard below exists for. The value names
    # a file whose bytes replace the live file; it is data, never run.
    if [ -n "${CS_NARRATIVE_ROTATE_MIDPOINT:-}" ]; then
        if [ ! -f "$CS_NARRATIVE_ROTATE_MIDPOINT" ]; then
            rm -f "$snap"
            [ "$created" -eq 1 ] && rm -f "$chunk"
            error "CS_NARRATIVE_ROTATE_MIDPOINT names no file: $CS_NARRATIVE_ROTATE_MIDPOINT"
        fi
        cp "$CS_NARRATIVE_ROTATE_MIDPOINT" "$live"
    fi

    # The live file must still open with the same bytes the snapshot did up to the
    # cut; a peer merge or an edit inside the archived run means the cut no longer
    # describes this file. Compared as equal-length truncated streams, not via
    # `cmp -n`: on this platform's cmp, -n misreports EOF whenever the two files'
    # total lengths differ, even when both are longer than the requested window.
    if ! cmp -s <(head -c "$cut" "$snap") <(head -c "$cut" "$live"); then
        rm -f "$snap"
        [ "$created" -eq 1 ] && rm -f "$chunk"
        error "narrative.$actor.md changed during rotation; run cs -narrative rotate again"
    fi
    if ! cs_write_atomic "$live" _narrative_kept_text "$snap" "$live" "$head_end" "$cut"; then
        rm -f "$snap"
        [ "$created" -eq 1 ] && rm -f "$chunk"
        error "could not rewrite narrative.$actor.md"
    fi
    rm -f "$snap"

    local chunk_rel=".cs/${arch_root#"$meta_dir"/}/$actor/$(basename "$chunk")"
    # No commit: the cut and the chunk stay on disk, and files under .cs/ are
    # committed only when the user asks.

    local timeline="$meta_dir/timeline.jsonl"
    _append_record "$timeline" \
           --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg actor "$actor" \
           --argjson sections "$sections" \
           --argjson bytes "$((cut - head_end))" \
           --arg archive "$chunk_rel" \
           '{ts: $ts, event: "narrative_rotated", actor: $actor, sections: $sections, bytes: $bytes, archive: $archive}'

    local archived_kb now_kb
    archived_kb=$(( (cut - head_end) / 1024 ))
    now_kb=$(( $(wc -c < "$live" | tr -d ' ') / 1024 ))
    echo "rotated $sections sections (${archived_kb} KB) -> $chunk_rel; live file now ${now_kb} KB"
}

# Dispatcher for cs -narrative
run_narrative() {
    local sub="${1:-}"
    case "$sub" in
        rotate)
            rotate_narrative
            ;;
        *)
            # Names both forms: this dispatcher is reached from inside a
            # session AND from `cs <name> -narrative`, and a message that
            # prescribes only the first sends a caller who correctly named a
            # session off to rotate whichever one their shell is standing in.
            error "Usage: cs -narrative rotate   |   cs <name> -narrative rotate"
            ;;
    esac
}
