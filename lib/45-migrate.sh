# ABOUTME: Session structure creation, git merge attributes, and the legacy migration phases.
# ABOUTME: Runs migrate_session on every open to bring old layouts current.

setup_merge_attributes() {
    local dir="$1"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    git -C "$dir" config merge.ours.driver true 2>/dev/null || _CS_MIGRATE_CLEAN=0
    _append_merge_attribute_lines "$dir/.gitattributes"
}

# Append to an attributes file each of cs's merge lines it lacks. A line
# counts as present only as a whole line, the way git reads one (blanks and a
# CR around it ignored), so one an earlier append glued onto the line before
# is added again.
_append_merge_attribute_lines() {  # file
    local attrs="$1" line
    for line in '.cs/memory/MEMORY.md merge=ours' '.cs/timeline.jsonl merge=union' \
            '.cs/memory/narrative.*.md merge=union' '.cs/memory/reference_memory_archive.md merge=union'; do
        _attribute_line_present "$attrs" "$line" || _append_attribute_line "$attrs" "$line"
    done
}

# Whether an attributes file holds <line> as a whole line: compared as text
# once each run of blanks (a CR too) is one space and none leads or trails.
# Bytes, not characters: awk stops on a line a multibyte locale cannot decode,
# and every open would then append the lines again.
_attribute_line_present() {  # file line
    env LC_ALL=C awk -v want="$2" '
        { gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/ $/, "") }
        $0 == want { found = 1; exit }
        END { exit !found }
    ' "$1" 2>/dev/null
}

# Append one line to an attributes file on a line of its own: a file whose
# last line has no newline gets one first, or git would read the two as one.
_append_attribute_line() {  # file line
    if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
        printf '\n' >> "$1"
    fi
    printf '%s\n' "$2" >> "$1"
}

# A clone delivers symlinks like any other file, and cs writes through them
# at open: `.cs/README.md -> ~/.zshrc` would take the README's frontmatter.
# Refuse any link under .cs, or at a root file cs rewrites, whose writes land
# outside the session. A link to a directory inside the session is followed
# and that directory scanned too: .cs/memory -> ../payload makes payload's
# links cs's write targets. A hand-made vault's mount is the user's and is not
# walked; cs_write_atomic still refuses a write leading out of it.
_refuse_links_out_of_session() {  # dir
    local dir="$1" dir_p p link real cur todo out seen="" prune="" cfg=""
    dir_p=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 0
    # cs links the shell's settings, skills and the rest into an encrypted
    # session's config dir by design; that dir is skipped only while
    # .cs/claude-config is cs's own link into a vault set up by hand. A clone
    # can commit the layout but not the pre-open that makes it a vault.
    if _cs_hand_made_vault "$dir" >/dev/null; then
        prune="$dir_p/.cs/vault-mnt"
        if [ -L "$dir_p/.cs/claude-config" ] && [ "$dir_p/.cs/claude-config" -ef "$dir_p/.cs/vault-mnt/claude-config" ]; then
            cfg=$(cd -P -- "$dir_p/.cs/vault-mnt/claude-config" 2>/dev/null && pwd -P)
        fi
    fi
    # A flat-layout session (Codex r2 #1) has Phase 1 move these root entries
    # into .cs/ and then write them; vet them before the move.
    local roots="CLAUDE.local.md .gitignore .gitattributes .claude .claude/settings.local.json"
    if needs_cs_migration "$dir_p"; then
        roots="$roots logs archives age-recipients README.md discoveries.md summary.md secrets.enc secrets.age"
    fi
    for p in $roots; do
        [ -L "$dir_p/$p" ] || continue
        out=$(_cs_write_leaves_session "$dir" "$dir_p/$p") || continue
        case "$out" in "cs could not ask git"*) error "$out" ;; esac
        error "$p is a symlink to $(_cs_plain_name "$(readlink "$dir_p/$p")" 160), outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session."
    done
    todo="$dir_p/.cs"
    while [ -n "$todo" ]; do
        cur=${todo%%$'\n'*}
        if [ "$cur" = "$todo" ]; then todo=""; else todo=${todo#*$'\n'}; fi
        case "$cur" in "$prune"|"$prune"/*) [ -n "$prune" ] && continue ;; esac
        case "$cur" in "$cfg"|"$cfg"/*) [ -n "$cfg" ] && continue ;; esac
        case "$seen" in *$'\n'"$cur"$'\n'*) continue ;; esac
        seen="$seen"$'\n'"$cur"$'\n'
        while IFS= read -r -d '' p; do
            link=$p real=""
            if [ -d "$p" ]; then
                # The x keeps a trailing newline that $(...) would strip (Codex r3 #1).
                real=$(cd -P -- "$p" 2>/dev/null && pwd -P && printf x) && real=${real%$'\n'x}
                # The walk list is newline-separated, so such a name would split
                # into two entries and neither would be scanned (Codex r2 #2).
                # Named before the link check, which refuses the same link as
                # leading out without saying why.
                case "$real" in *$'\n'*)
                    error "$(_cs_plain_name "${link#"$dir_p"/}" 160) leads to a directory with a newline in its name, which cs cannot check for links out of the session. Rename it, or cs -rm the session." ;;
                esac
            fi
            if out=$(_cs_write_leaves_session "$dir" "$p"); then
                case "$out" in "cs could not ask git"*) error "$out" ;; esac
                error "$(_cs_plain_name "${p#"$dir_p"/}" 160) is a symlink to $(_cs_plain_name "$(readlink "$p")" 160), outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session."
            fi
            [ -n "$real" ] || continue
            todo="$todo${todo:+$'\n'}$real"
        done < <(find "$cur" \( -path "${prune:-/nonexistent}" -o -path "${cfg:-/nonexistent}" \) -prune -o -type l -print0 2>/dev/null)
    done
}

# Refuse to proceed if per-actor local state has been committed to git, or
# sits behind a symlink: git tracks a link as one path, so `.cs -> payload`
# or `.cs/local -> ../payload` hides a committed pre-open from the pathspec
# check below while the link resolves to it on disk.
cs_assert_local_untracked() {
    local dir="$1" sub tracked
    for sub in .cs .cs/local; do
        [ -L "$dir/$sub" ] || continue
        error "$sub is a symlink to $(_cs_plain_name "$(readlink "$dir/$sub")" 160) (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen."
    done
    # A submodule or nested repository at .cs keeps its files out of the
    # session's index, so the pathspec check below would never see them.
    if _cs_nested_cs "$dir"; then
        error ".cs is a submodule or nested repository (cs state must be a plain directory inside the session). Delete .cs/local/pre-open unless you wrote it, then git rm --cached .cs, remove .cs/.git and git add .cs, then reopen."
    fi
    # Asked before the link walk: a vault set up by hand needs git's answer
    # about .cs/local before its links out are let through, so when git
    # cannot answer, git's own error is the one shown.
    ! tracked=$(cs_tracked_files_notice "$dir/.cs/local" "$dir") || error "$tracked"
    _refuse_links_out_of_session "$dir"
    # .cs/private takes .cs/local's place for the queue, the mailbox and the
    # rotation marker (cs_private_dir), so nothing in it may come from git
    # either. Asked of the directory the name resolves to, in whichever
    # repository lists it: an encrypted session commits the link itself, and
    # a clone can commit the link beside a directory it tracks elsewhere.
    ! tracked=$(cs_tracked_files_notice "$dir/.cs/private" "$dir") || error "$tracked"
}

# For a checkout cs hides itself in through info/exclude (git_bookkeeping:
# exclude): the first path cs would rewrite at open that the branch tracks, or
# "<path> is a symlink" when one of them points elsewhere (a write through it
# lands on the target, which may be tracked). Empty when the open is safe. An
# exclude hides only untracked files, so a tracked one here would be dirtied
# on every open; checked at adoption to skip, and at every open to refuse,
# since the branch moves on. A git that cannot answer prints "cs could not ask
# git ...", which both callers refuse as it stands.
_exclude_session_tracked_conflict() {  # dir
    local dir="$1" p list why
    for p in .claude .claude/settings.local.json CLAUDE.local.md .cs; do
        if [ -L "$dir/$p" ]; then
            printf '%s is a symlink' "$p"
            return 0
        fi
    done
    if ! list=$(_cs_git_at "$dir" ls-files -- .cs .claude/settings.local.json CLAUDE.local.md 2>/dev/null); then
        why=$(_cs_git_error_at "$dir" ls-files -- .cs .claude/settings.local.json CLAUDE.local.md)
        ! _cs_git_not_a_repo "$why" || return 0
        printf 'cs could not ask git whether the branch tracks a file cs rewrites at open: %s' "$(_cs_git_complaint "$why")"
        return 0
    fi
    printf '%s' "${list%%$'\n'*}"
}

# True when cs created this session directory, and so owns its mode. Two ways to
# fail: the directory sits outside the sessions root, or a symlink IN the root
# resolves to it — an adopted session, whose target is the user's own project
# and stays whatever mode they chose, even when they keep it inside the root.
#
# Both sides are resolved before comparing. A plain prefix test on the unresolved
# root silently never matched wherever the root itself sits behind a link (macOS
# /var -> /private/var is the everyday case), so the backfill quietly did nothing
# on exactly the machines it was written on.
_session_root_is_cs_owned() {  # session_dir
    local dir root e
    dir=$(cd -- "$1" 2>/dev/null && pwd -P) || return 1
    root=$(cd -- "${SESSIONS_ROOT:-}" 2>/dev/null && pwd -P) || return 1
    case "$dir" in "$root"/*) ;; *) return 1 ;; esac
    for e in "${SESSIONS_ROOT:-}"/*; do
        [ -L "$e" ] || continue
        [ "$(cd -- "$e" 2>/dev/null && pwd -P)" = "$dir" ] && return 1
    done
    return 0
}

# Bring a session's own data directory to owner-only. cs writes narratives,
# plans, logs, the timeline and machine-local state here, and a session can hold
# anything its user worked on — but bare mkdir takes the caller's umask, so on
# any sessions root that is not itself private the whole lot is world-readable.
# Only .cs is set: reaching a file inside needs execute on the directory, so a
# private .cs covers everything under it whatever the files' own modes are.
#
# Scoped to .cs on purpose. adopt calls create_session_structure with the USER'S
# project directory, whose mode is theirs to choose — a shared checkout or a
# served directory may be world-readable deliberately — so the session root is
# hardened only where cs created it.
_harden_session_meta() {  # session_dir
    [ -d "$1/.cs" ] || return 0
    chmod 700 "$1/.cs" 2>/dev/null || true
    return 0
}

# A session can prepare itself before cs opens it, such as mounting the
# encrypted volume its memory lives on. The command lives in .cs/local/, which
# is never committed, so a cloned session cannot make cs run code (a file sync
# copies it like any other file).
# It runs in the session directory on the user's terminal (a password prompt
# needs the TTY), and any non-zero exit aborts the open. CS_LIVE_LOCK_PID
# carries the pid live_lock_pid reads from the session lock, empty when no
# running process holds it, so the hook needs no lock rule of its own. The
# open has not taken the lock yet, so the pid is the previous holder's.
_run_pre_open() {  # session_name, session_dir
    local hook="$2/.cs/local/pre-open" rc=0 lock_pid
    [ -e "$hook" ] || return 0
    # `git add -f` can still commit into the ignored .cs/local/; refuse before
    # running anything a clone could have delivered.
    cs_assert_local_untracked "$2"
    [ -x "$hook" ] || error "$1: .cs/local/pre-open is not executable; chmod +x it, or remove it."
    lock_pid=$(live_lock_pid "$2/.cs")
    (cd -- "$2" && CS_LIVE_LOCK_PID="$lock_pid" "$hook") || rc=$?
    [ "$rc" -eq 0 ] || error "$1: .cs/local/pre-open exited $rc; not opening the session."
    _arm_vault_detach "$2"
}

# A session can keep .cs/memory, .cs/plans, .cs/claude-config (Claude Code's
# own config dir) and .cs/private (cs's own content files) on an encrypted
# volume by making them symlinks into its mountpoint. Unmounted, the links
# dangle: `test -d` is false through them, so migrate would mkdir through them
# and abort on a raw mkdir error. Refuse by name instead, before anything
# writes there.
_refuse_unmounted_meta() {  # session_name, session_dir
    local sub link target
    for sub in $CS_VAULT_LINKS; do
        link="$2/.cs/$sub"
        if [ -e "$link" ] && [ ! -d "$link" ]; then
            error "$1: .cs/$sub is a file, not a directory or a link into encrypted storage. Remove it, or link it into the vault, then reopen."
        fi
        [ -L "$link" ] && [ ! -e "$link" ] || continue
        target=$(_cs_plain_name "$(readlink "$link")" 160)
        error "$1: .cs/$sub points at $target, which is missing (encrypted storage not mounted?). Mount it, then reopen."
    done
    _refuse_plaintext_beside_private "$1" "$2"
}

# Feature worktrees of an encrypted session are not designed yet. cs -encrypt
# links the four names relative to .cs/, so a checkout of them resolves inside
# the worktree, where nothing is mounted; and a base whose .cs/ is ignored
# gives the worktree plaintext files of its own. Refused by name until then.
_refuse_worktree_of_encrypted_base() {  # base_name, base_dir
    local sub
    for sub in $CS_VAULT_LINKS; do
        [ -L "$2/.cs/$sub" ] || continue
        error "$1: .cs/$sub links into encrypted storage, and feature worktrees of an encrypted session are not supported yet."
    done
}

# The cs content files a plain session keeps in .cs/local and an encrypted one
# keeps behind .cs/private. The open refuses a plaintext copy of any of them,
# and cs -encrypt moves each into the vault.
CS_PRIVATE_LOCAL_FILES="session.log scope-prompt.trace memory-index.snapshot memory-archive.snapshot mail
    queue queue.tmp queue.state queue.mode queue.done queue.current queue.accepted queue.failed queue.migrating
    notifications.jsonl notifications.seen failures rewrite.trace pending-handoff
    pending-switch finish-progress.json"

# Once .cs/private holds a session's cs content files, a copy still in
# .cs/local is plaintext the vault was meant to hold: an unmigrated log, or one
# written by an older cs. Named rather than moved, since a move cannot remove
# the copies backups and snapshots already hold.
_refuse_plaintext_beside_private() {  # session_name, session_dir
    local meta="$2/.cs" name
    [ -e "$meta/private" ] || return 0
    for name in $CS_PRIVATE_LOCAL_FILES; do
        [ -e "$meta/local/$name" ] || continue
        error "$1: .cs/private keeps this session's cs files in its vault, but .cs/local still holds $name in plaintext. Move it into .cs/private or delete it, then reopen."
    done
    if [ -e "$meta/handoffs" ]; then
        error "$1: .cs/private keeps this session's rotation handoffs in its vault, but .cs/handoffs still holds them in plaintext. Move it to .cs/private/handoffs or delete it, then reopen."
    fi
    if [ -e "$meta/checkpoints" ]; then
        error "$1: .cs/private keeps this session's checkpoints in its vault, but .cs/checkpoints is still plaintext. Move it to .cs/private/checkpoints or delete it, then reopen."
    fi
    # A narrative in the vault rotates into it; a .cs/narrative-archive link
    # into the vault is where rotation writes, not a leftover.
    if [ -L "$meta/memory" ] && [ -e "$meta/narrative-archive" ] && [ ! -L "$meta/narrative-archive" ]; then
        error "$1: this session's narrative lives in its vault, but .cs/narrative-archive is still plaintext. Move it to .cs/private/narrative-archive or delete it, then reopen."
    fi
}

# Create session directory structure
# The part of a session README every reader parses: the YAML frontmatter
# (status, created, tags, aliases) and the `# Session: <name>` title, followed
# by one blank line. Callers append their own body. The TUI, the hooks and
# `cs -list` read these fields, so every session kind writes them here.
_write_session_readme_head() {  # readme, name, tags_yaml, aliases_yaml
    local readme="$1" name="$2" tags="$3" aliases="$4"
    cat > "$readme" << EOF
---
status: active
created: $(date '+%Y-%m-%d')
tags: $tags
aliases: $aliases
---
# Session: $name

EOF
}

create_session_structure() {
    local session_dir="$1" engine="${2:-claude}"

    mkdir -p "$session_dir/.cs/local"
    _harden_session_meta "$session_dir"

    # Create README.md with YAML frontmatter for structured queries. A brand
    # new session never has one yet; adopt's orphaned-.cs re-adopt path is the
    # one caller that runs this against a directory that already carries one,
    # and its records must survive untouched.
    if [ ! -f "$session_dir/.cs/README.md" ]; then
        _write_session_readme_head "$session_dir/.cs/README.md" "$(basename "$session_dir")" "[]" "[\"$(basename "$session_dir")\"]"
        cat >> "$session_dir/.cs/README.md" << EOF
**Started:** $(date '+%Y-%m-%d %H:%M:%S')
**Location:** $(hostname):$(pwd)

## Objective

[Describe what you're trying to accomplish in this session]

## Environment

[Describe the system, server, or context you're working in]

## Outcome

[To be filled when session is complete - summarize what was accomplished]
EOF
    fi


    # adopt runs this in the user's own project, whose CLAUDE.local.md may
    # already hold their lines.

    # Initialize session log (machine-local; never git-synced). Only when
    # absent: re-adopted records already carry their command log, an
    # encrypted session's behind .cs/private. While that vault is locked
    # there is nowhere to write it, and the open refuses the locked vault.
    local log_dir
    if log_dir=$(cs_private_dir "$session_dir/.cs") && [ ! -e "$log_dir/session.log" ]; then
        cat > "$log_dir/session.log" << EOF
Agent Sessions Log
Session: $(basename "$session_dir")
Started: $(date '+%Y-%m-%d %H:%M:%S')
Location: $(hostname):$(pwd)

================================================================================

EOF
    fi

    # Portable storage exists regardless of the selected provider.
    mkdir -p "$session_dir/.cs"/{memory,plans}

    # Create the session narrative topic file + index pointer
    cs_engine_call "$engine" prepare_workspace "$session_dir" create || return $?
    ensure_narrative_file "$session_dir"
}

# Move a file or directory if source exists and destination doesn't (idempotent)
migrate_if_exists() {
    local src="$1" dst="$2"
    if [ -e "$src" ] && [ ! -e "$dst" ]; then
        mv "$src" "$dst"
    fi
}

# Convert a legacy line-per-message inbox (already renamed to
# inbox.jsonl.migrating) into per-message maildir documents. Lines at or below
# the old `seen` cursor were read and go to cur/; the rest go to new/. A line
# that does not parse at all is quarantined in mail/corrupt.jsonl — it is
# evidence of the append tearing the maildir removes, not garbage. Records may
# lack a numeric ts (accepted and pinned by test) or a usable id, so neither
# is assumed for the filename: a missing ts sorts to the front and a missing id
# becomes a migration-local sequence, preserving order within the legacy file.
# Every name derives only from the legacy content, so converting the same file
# twice produces the same names and the second run delivers nothing new — which
# is what makes an interrupted conversion safe to retry. Deletes the converted
# file and the cursor when done.
_convert_legacy_inbox() {  # maildir
    local maildir="$1" legacy="$1/inbox.jsonl.migrating"
    [ -f "$legacy" ] || return 0
    _mail_ensure_maildir "$maildir"
    local seen=""
    if [ -f "$maildir/seen" ]; then
        IFS= read -r seen < "$maildir/seen" || true
    fi
    case "$seen" in ''|*[!0-9]*) seen=0;; esac
    local lineno=0 seq=0 line meta ts id fname dest failed=0
    # `|| [ -n "$line" ]` converts a final line the stale writer never
    # terminated rather than dropping it.
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in *[![:space:]]*) : ;; *) continue ;; esac
        meta=$(printf '%s\n' "$line" | jq -r '
            (try (if (.ts|type) == "number" then (.ts|floor|tostring) else "" end) catch "") + "\t" +
            (try (if (.id|type) == "string" then .id else "" end) catch "")
        ' 2>/dev/null) || meta=""
        if [ -z "$meta" ]; then
            printf '%s\n' "$line" >> "$maildir/corrupt.jsonl"
            continue
        fi
        seq=$((seq + 1))
        ts="${meta%%$'\t'*}"
        id="${meta#*$'\t'}"
        # Base-10 normalize before printf %d, which reads a leading zero as octal.
        # A record with no usable ts sorts to the front rather than taking the
        # migration's own clock: "now" differs on every run, which would give
        # the same record a new name each time and defeat the rerun guard below.
        case "$ts" in ''|*[!0-9]*) ts=0;; *) ts=$((10#$ts));; esac
        case "$id" in ''|*[!A-Za-z0-9._-]*) id=$(printf 'legacy-%04d' "$seq");; esac
        # The line's own position is part of the name, so the name depends only
        # on the legacy file's content -- the same record converts to the same
        # filename on every run.
        fname="$(printf '%010d' "$ts")-${id}-$(printf '%04d' "$seq").json"
        if [ "$lineno" -le "$seen" ]; then dest="cur"; else dest="new"; fi
        # A conversion interrupted partway leaves records already delivered.
        # Skip those, in EITHER box: re-delivering one the recipient has since
        # read would resurrect it as unread, and delivering it twice would show
        # the same message twice.
        if [ -e "$maildir/new/$fname" ] || [ -e "$maildir/cur/$fname" ]; then
            continue
        fi
        if ! { printf '%s\n' "$line" > "$maildir/tmp/$fname" \
                && mv "$maildir/tmp/$fname" "$maildir/$dest/$fname"; }; then
            rm -f "$maildir/tmp/$fname"
            failed=1
        fi
    done < "$legacy"
    # Only drop the legacy file once every record reached a box. A failed write
    # is the non-final command of an && list, so errexit does not fire and the
    # loop runs on; unlinking here regardless would destroy the one copy of the
    # mail that never landed. Retrying is safe because the names above are a
    # pure function of the legacy content.
    [ "$failed" -eq 0 ] && rm -f "$legacy" "$maildir/seen"
    return 0
}

# One-time, idempotent mailbox migration, keyed ONLY on inbox.jsonl existing.
# It must not also require new/ to be absent: delivery creates the recipient's
# maildir on send, so a session receiving one new-format message before its
# next open would otherwise read the gate false forever and strand its legacy
# unread mail. Renaming before converting keeps a stale writer safe: one
# holding an open descriptor keeps writing into the renamed inode and its
# lines are still converted; one that reopens the path creates a fresh
# inbox.jsonl, which the next open converts.
migrate_mailbox() {  # session_dir
    local maildir="$1/.cs/local/mail"
    # A migration interrupted between rename and delete left real mail in
    # inbox.jsonl.migrating; convert it before renaming a fresh inbox over it.
    _convert_legacy_inbox "$maildir"
    [ -f "$maildir/inbox.jsonl" ] || return 0
    mv "$maildir/inbox.jsonl" "$maildir/inbox.jsonl.migrating" 2>/dev/null || return 0
    _convert_legacy_inbox "$maildir"
}

# Check if session needs migration from flat layout to .cs/ directory. The
# migration moves README.md and rewrites .gitignore, so it needs proof
# the directory is a cs session, not just a logs/ dir any project can have:
# every flat-layout session cs created opened logs/session.log with the line
# "Claude Code Session Log".
needs_cs_migration() {
    local session_dir="$1" first_line=""
    [ -d "$session_dir/.cs" ] && return 1
    [ -f "$session_dir/logs/session.log" ] || return 1
    IFS= read -r first_line < "$session_dir/logs/session.log" || true
    [ "${first_line%$'\r'}" = "Claude Code Session Log" ]
}

# Rewrite the read-all-narratives sentences cs wrote into existing sessions, and
# the read-the-live-narratives sentences that replaced them (nobody can read a
# teammate's whole file either; a resume reads its own in full and a teammate's
# only from the line the digest names). Three places cs owns: a narrative's
# frontmatter description, its MEMORY.md pointer and the protocol block in
# CLAUDE.local.md. Only the exact sentences cs emitted are
# touched — a narrative body or a user's own prose never is. Temp+mv rather than
# sed -i (BSD/GNU disagree on -i). Idempotent: nothing matches on the second run.
migrate_narrative_resume_wording() {  # session_dir, [actor_slug]
    local session_dir="$1" actor="${2:-}"
    local mem="$session_dir/.cs/memory" f
    if [ -z "$actor" ]; then
        actor=$(cs_actor_slug "$session_dir")
    fi
    # Only the actor's own narrative: a teammate's file is theirs to migrate on
    # their own resume, and a committed edit to its head would show up in their
    # teammates' digests as growth that is not a tail.
    f="$mem/narrative.$actor.md"
    # Keyed to the description line specifically (not just "somewhere in the
    # first 8 lines"): a cs-written narrative has exactly 7 header lines, so
    # a body line beginning on line 8 sits inside a bare line-range window
    # too and would otherwise be rewritten. No pipe into grep -q: under
    # pipefail a huge first line can make `head -8 | grep -q` exit 141 and
    # silently skip the file.
    if [ -f "$f" ] \
        && awk 'NR <= 8 && /^description: .*Read (all|the live) narrative\.\*\.md on resume[.;]/ { f = 1 } NR > 8 { exit } END { exit !f }' "$f"; then
        # One replacement for both vintages: the pattern alternates, the
        # sentence appears once, so a typo cannot migrate half the population
        # to a wording no later gate matches.
        cs_write_atomic "$f" sed -E '1,8{/^description: /s/Read (all narrative\.\*\.md on resume\.|the live narrative\.\*\.md on resume; older sections are archived under \.cs\/narrative-archive\/\.)/Its owner reads it in full on resume; anyone else reads only the lines the resume digest names. Older sections are archived under .cs\/narrative-archive\/./;}' "$f" \
            || { warn "could not rewrite $f; its description keeps the old wording"; _CS_MIGRATE_CLEAN=0; }
    fi
    f="$mem/MEMORY.md"
    if [ -f "$f" ] && grep -qE 'read (all|the live) narrative\.\*\.md on resume' "$f"; then
        cs_write_atomic "$f" sed -E 's/read (all narrative\.\*\.md on resume|the live narrative\.\*\.md on resume, older sections under \.cs\/narrative-archive\/)/its owner reads it in full on resume, anyone else only the lines the resume digest names; older sections under .cs\/narrative-archive\//' "$f" \
            || { warn "could not rewrite $f; its narrative pointer keeps the old wording"; _CS_MIGRATE_CLEAN=0; }
    fi
}

# Phases 13, 6 and 12: the text cs manages in every session, whatever its
# engine: the narrative's description, its MEMORY.md pointer and
# .cs/README.md. Each phase is a no-op once its file is current. Claude's own
# documents (Phase 13's CLAUDE.local.md wording, phases 5 and 7) are the Claude
# adapter's, run from its prepare_workspace migrate.
_migrate_session_documents() {  # session_dir, actor_slug
    local session_dir="$1" actor_slug="$2"

    # Phase 13: the resume protocol reads live narratives only; rewrite the
    # read-all sentences cs wrote into files that predate rotation.
    migrate_narrative_resume_wording "$session_dir" "$actor_slug"

    # Phase 6: Add YAML frontmatter to README.md if missing
    local readme="$session_dir/.cs/README.md"
    # A trailing CR is stripped before the test: a repo cloned with autocrlf
    # with default autocrlf has "---\r" on line 1, which '^---$' does not match —
    # so this phase read the file as having NO frontmatter and PREPENDED a second
    # block, leaving the original orphaned in the body. Two frontmatter blocks
    # break every reader of it (tags, status, aliases) and strand the
    # machine-local fields outside the bounded block Phase 12 scans.
    if [ -f "$readme" ] && ! head -1 "$readme" | tr -d '\r' | grep -q '^---$'; then
        local session_name
        session_name=$(basename "$session_dir")
        # Derive created date from the "Started:" line, then from the git
        # date the README was added (shared history — every clone derives
        # the same value), then from file mtime (non-git sessions only;
        # mtime is not preserved across clones so it must never feed a
        # value that another machine could contradict on merge).
        local created_date
        created_date=$(grep -oE 'Started:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}' "$readme" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
        if [ -z "$created_date" ]; then
            created_date=$(git -C "$session_dir" log --diff-filter=A --format=%as -- .cs/README.md 2>/dev/null | tail -1 || true)
        fi
        if [ -z "$created_date" ]; then
            # GNU stat first, as _epoch_mtime asks it.
            if created_date=$(stat -c '%y' "$readme" 2>/dev/null); then
                created_date=${created_date%% *}
            else
                created_date=$(stat -f '%Sm' -t '%Y-%m-%d' "$readme" 2>/dev/null || date '+%Y-%m-%d')
            fi
        fi
        local existing_content
        existing_content=$(cat "$readme")
        # Through a temp file, like every neighbouring write: redirecting onto
        # the README truncates the user's file before a byte is written, so a
        # write that does not complete leaves nothing behind.
        if cs_write_atomic "$readme" printf -- '---\nstatus: active\ncreated: %s\ntags: []\naliases: ["%s"]\n---\n%s\n' \
            "$created_date" "$session_name" "$existing_content" 2>/dev/null; then
            notice .cs/README.md "added frontmatter"
        else
            _CS_MIGRATE_CLEAN=0
        fi
    fi

    # Phase 12: Move machine-local fields out of README frontmatter into
    # .cs/local/state. claude_session_id / claude_session_color are copied
    # (unless the state file already has its own value — the local machine's
    # binding wins over whatever another machine last pushed); last_resumed
    # and updated are dropped, they are regenerated activity stamps. The
    # README then loses all four lines: hooks on every machine rewrote them
    # with divergent values, which made merge conflicts inevitable whenever
    # a session was shared through git.
    local _state="$session_dir/.cs/local/state"
    # Bounded to the frontmatter block: opened by the `---` on line 1 that Phase 6
    # guarantees, and CLOSED by a second one, which it does not. Without a
    # terminator there is no way to tell frontmatter from prose — fm would stay
    # set to EOF and the strip below would delete a body line — so an unclosed
    # block is left entirely alone. All four keys are ordinary English, and the README
    # carries hand-written prose sections, so a body line beginning "updated:"
    # is the user's own content — matching it anywhere in the file deleted it.
    local _fm_field_re='^(claude_session_id|claude_session_color|last_resumed|updated):'
    # Matching is done on a CR-stripped COPY of each line, and the file is written
    # back untouched: a repo cloned with autocrlf enabled
    # arrives as CRLF, where /^---$/ never matches "---\r", fm is never set, and
    # the whole strip silently no-ops.
    if [ -f "$readme" ] && awk -v re="$_fm_field_re" '
            { line = $0; sub(/\r$/, "", line) }
            NR == 1 && line == "---" { fm = 1; next }
            fm && line == "---"      { closed = 1; exit }
            fm && line ~ re          { found = 1 }
            END                      { exit (found && closed) ? 0 : 1 }
        ' "$readme"; then
        local _legacy_uuid _legacy_color
        _legacy_uuid=$(awk '/^claude_session_id:/ { sub(/^claude_session_id:[[:space:]]*/, ""); gsub(/["\r]/, ""); print; exit }' "$readme")
        _legacy_color=$(awk '/^claude_session_color:/ { sub(/^claude_session_color:[[:space:]]*/, ""); gsub(/["\r]/, ""); print; exit }' "$readme")
        # The README is whatever the clone or the adopted project committed, so
        # only a UUID is taken as a conversation id.
        if [ -n "$_legacy_uuid" ] && [ -z "$(_read_local_state "$_state" claude_session_id)" ]; then
            if _is_uuid "$_legacy_uuid"; then
                _set_local_state_if_absent "$_state" claude_session_id "$_legacy_uuid"
            else
                warn "ignoring claude_session_id in .cs/README.md: not a UUID, so it names no conversation"
            fi
        fi
        # The colour is claude's first prompt, so the same rule: only one of
        # claude's own colours is taken; anything else leaves the slot empty for
        # the backfill below.
        if [ -n "$_legacy_color" ] && [ -z "$(_read_local_state "$_state" claude_session_color)" ]; then
            if _is_session_color "$_legacy_color"; then
                _set_local_state_if_absent "$_state" claude_session_color "$_legacy_color"
            else
                warn "ignoring claude_session_color in .cs/README.md: not one of claude's colours"
            fi
        fi
        if cs_write_atomic "$readme" awk -v re="$_fm_field_re" '
            { line = $0; sub(/\r$/, "", line) }
            NR == 1 && line == "---" { fm = 1; print; next }
            fm && line == "---"      { fm = 0; print; next }
            fm && line ~ re          { next }
            { print }
        ' "$readme"; then
            notice .cs/README.md "machine-local fields moved to .cs/local/state or dropped"
        else
            warn "could not rewrite $readme; its machine-local fields stay in it"
            _CS_MIGRATE_CLEAN=0
        fi
    fi
}

# The session files a completed migration vouches for. Changed after the stamp
# (newer than it), any of them sends the next open through the full migration.
# The Codex adapter manages none of a session's files at migrate time, so the
# list is the same for both engines.
CS_MIGRATION_PROBES=".gitignore .gitattributes CLAUDE.local.md CLAUDE.md .cs/README.md"

# How far an open can trust the last completed migration, from the stamp
# .cs/local/migrated. Prints "fresh" when it can skip every one-time phase,
# "narrative" when only MEMORY.md changed after the stamp (Claude Code writes
# it, and only the narrative check reads it), or "stale: <reason>" when the
# open must run them all. The engine is the open's (CS_MIGRATE_ENGINE, which
# migrate_session sets); outside an open, such as in cs -doctor, it is the
# engine the next open would pick. A stamp written under another engine is
# stale: a Codex open runs none of Claude's phases, so its stamp vouches for
# nothing a Claude open needs, and the reverse.
_migration_stamp_state() {  # session_dir, actor_raw
    local stamp="$1/.cs/local/migrated" line1="" line2="" rest p encrypted=0 engine fields
    if [ ! -f "$stamp" ]; then
        echo "stale: no stamp"
        return 0
    fi
    if ! { IFS= read -r line1 && IFS= read -r line2; } < "$stamp" 2>/dev/null || [ -z "$line2" ]; then
        echo "stale: the stamp is unreadable or incomplete"
        return 0
    fi
    case "$line1" in
        "$VERSION"$'\t'*) ;;
        *) echo "stale: written by cs ${line1%%$'\t'*}, not $VERSION"; return 0 ;;
    esac
    case "$line1" in
        "$VERSION"$'\t'"$2"$'\t'*) ;;
        *) echo "stale: written for another actor"; return 0 ;;
    esac
    if [ -d "$1/.cs/private" ]; then
        encrypted=1
    fi
    # What follows the actor: the encrypted flag, then the engine.
    fields=${line1#"$VERSION"$'\t'"$2"$'\t'}
    case "$fields" in
        "$encrypted"|"$encrypted"$'\t'*) ;;
        *) echo "stale: the stamp records another encryption state"; return 0 ;;
    esac
    engine="${CS_MIGRATE_ENGINE:-}"
    if [ -z "$engine" ]; then
        engine=$(_session_engine "$1" "" 2>/dev/null) || engine=claude
    fi
    case "$fields" in
        "$encrypted"$'\t'"$engine") ;;
        "$encrypted") echo "stale: the stamp names no engine"; return 0 ;;
        *) echo "stale: written for another engine"; return 0 ;;
    esac
    rest="$line2"
    while [ -n "$rest" ]; do
        p=${rest%%$'\t'*}
        rest=${rest#"$p"}
        rest=${rest#$'\t'}
        if [ -n "$p" ] && [ ! -e "$1/$p" ]; then
            echo "stale: $p is gone"
            return 0
        fi
    done
    for p in $CS_MIGRATION_PROBES; do
        if [ "$1/$p" -nt "$stamp" ]; then
            echo "stale: $p changed after the stamp"
            return 0
        fi
    done
    # setup_merge_attributes sets merge.ours.driver in every checkout but an
    # adopted Claude Code worktree, and the doctor's advice for a missing one
    # is to launch once. Every `git config` write rewrites .git/config
    # (SessionStart's hideRefs on each launch among them), so its modification
    # time says nothing: read the value.
    if [ -e "$1/.git" ] && [ "$(_read_local_state "$1/.cs/local/state" git_bookkeeping)" != "exclude" ] \
        && [ "$(git -C "$1" config --get merge.ours.driver 2>/dev/null)" != "true" ]; then
        echo "stale: merge.ours.driver is not set"
        return 0
    fi
    if [ "$1/.cs/memory/MEMORY.md" -nt "$stamp" ]; then
        echo "narrative"
        return 0
    fi
    echo "fresh"
}

# Record a completed migration in .cs/local/migrated. Line 1: the cs version,
# the raw actor, whether the session is encrypted (1) or not (0) and the
# engine the open ran under, tab separated. Line 2: the probe files that exist
# now, tab separated, so a later open can tell one was deleted.
_write_migration_stamp() {  # session_dir, actor_raw, actor_slug, engine
    local dir="$1" encrypted=0 listed="" p
    if [ -d "$dir/.cs/private" ]; then
        encrypted=1
    fi
    for p in $CS_MIGRATION_PROBES .cs/memory/MEMORY.md ".cs/memory/narrative.$3.md" .claude/settings.local.json; do
        if [ -e "$dir/$p" ]; then
            listed="$listed${listed:+$'\t'}$p"
        fi
    done
    cs_write_atomic "$dir/.cs/local/migrated" printf '%s\t%s\t%s\t%s\n%s\n' "$VERSION" "$2" "$encrypted" "$4" "$listed"
}

# Migrate existing session to latest format
migrate_session() {
    local session_dir="$1" engine="${2:-claude}"

    # Per-actor local state must never be committed or linked elsewhere;
    # refuse before the hardening below chmods through a link.
    cs_assert_local_untracked "$session_dir"

    # Sessions created before cs set a mode are still world-readable on disk,
    # and git does not record directory modes, so a fresh clone recreates .cs
    # under the cloner's umask however it was set on the other machine.
    _harden_session_meta "$session_dir"
    # The root only when cs owns it. An adopted session's real directory is the
    # user's project, living wherever they keep it — re-permissioning that on
    # every launch would change their directory behind their back. Testing the
    # PARENT rather than the name: by the time migrate runs, the path has been
    # resolved through the symlink, so the adopted session no longer looks like
    # a link and its basename is the project's, not the session's.
    if _session_root_is_cs_owned "$session_dir"; then
        chmod 700 "$session_dir" 2>/dev/null || true
    fi

    if [ "$(_read_local_state "$session_dir/.cs/local/state" git_bookkeeping)" = "exclude" ]; then
        local conflict
        conflict=$(_exclude_session_tracked_conflict "$session_dir")
        if [ -n "$conflict" ]; then
            case "$conflict" in
                "cs could not ask git"*) error "$conflict" ;;
                *symlink) error "$conflict in $session_dir, and cs writes through it at every open. Replace it with a real file or directory, or cs -rm the session." ;;
                *) error "$conflict is tracked on the branch in $session_dir, and cs would rewrite it at every open. Stop tracking it, or cs -rm the session." ;;
            esac
        fi
    fi

    # A migration whose writes all succeeded stamps .cs/local/migrated.
    # While the stamp is fresh the one-time phases below have nothing left to
    # do, so a reopen skips them ("none"); when MEMORY.md alone changed it runs
    # only the narrative check and restamps ("narrative"). The refusals above
    # and the phases that only test for a leftover's existence run on every
    # open. The stamp sits after cs_assert_local_untracked on purpose: a stamp
    # committed into git is refused before anything trusts it. A phase that
    # carries on past a failed write clears _CS_MIGRATE_CLEAN, so the next
    # open retries it. The stamp names the engine it was written under, so the
    # first open after cs -switch runs the full migration for the other one.
    # CS_MIGRATE_ENGINE and CS_MIGRATE_REPAIR are dynamically scoped: the stamp
    # check reads the first, and the engine adapters' prepare_workspace the
    # second.
    # shellcheck disable=SC2034
    local CS_MIGRATE_ENGINE="$engine"
    local actor_raw actor_slug="" repair=all
    actor_raw=$(cs_actor_raw "$session_dir" "$session_dir/.cs")
    case "$(_migration_stamp_state "$session_dir" "$actor_raw")" in
        fresh) repair=none ;;
        narrative) repair=narrative ;;
    esac
    # shellcheck disable=SC2034
    local CS_MIGRATE_REPAIR="$repair"
    _CS_MIGRATE_CLEAN=1

    # Backfill the merge attributes on existing sessions, and the .cs/local/
    # ignore rule on older sessions whose .gitignore predates it, so per-actor
    # local state never gets committed (which would otherwise trip
    # cs_assert_local_untracked and block the next resume). An adopted Claude
    # Code worktree keeps cs's files out of git through the repo's common
    # exclude instead (git_bookkeeping: exclude): nothing of cs's is committed
    # there for attributes to govern, and an in-tree .gitignore or
    # .gitattributes would be the one thing dirtying its PR branch.
    # The same sessions keep their tracked CLAUDE.md as the branch has it: the
    # two CLAUDE.md migrations further down are skipped for them too.
    local tracked_tree_is_ours=1
    if [ "$(_read_local_state "$session_dir/.cs/local/state" git_bookkeeping)" = "exclude" ]; then
        tracked_tree_is_ours=0
    fi
    if [ "$tracked_tree_is_ours" = 1 ] && [ "$repair" = all ]; then
        setup_merge_attributes "$session_dir"
        ensure_cs_gitignore_entries "$session_dir"
        # Names the rules just appended to a tracked .gitignore. Adopt merges
        # the same rules and names .gitignore in its own row of what it left
        # (_explain_nothing_committed) instead.
        _explain_gitignore_additions "$session_dir"
    fi

    # Phase 1: Structural migration (flat layout -> .cs/ directory)
    if needs_cs_migration "$session_dir"; then
        mkdir -p "$session_dir/.cs"

        # Move directories
        migrate_if_exists "$session_dir/logs" "$session_dir/.cs/logs"
        migrate_if_exists "$session_dir/archives" "$session_dir/.cs/archives"
        migrate_if_exists "$session_dir/age-recipients" "$session_dir/.cs/age-recipients"

        # Move metadata files
        migrate_if_exists "$session_dir/README.md" "$session_dir/.cs/README.md"
        migrate_if_exists "$session_dir/discoveries.md" "$session_dir/.cs/discoveries.md"
        migrate_if_exists "$session_dir/summary.md" "$session_dir/.cs/summary.md"
        migrate_if_exists "$session_dir/secrets.enc" "$session_dir/.cs/secrets.enc"
        migrate_if_exists "$session_dir/secrets.age" "$session_dir/.cs/secrets.age"

        # Merged, not written: the session's own rules keep hiding their
        # files from the user's next `git add`.
        ensure_cs_gitignore_entries "$session_dir"

        notice .cs/ "holds the session metadata, moved out of the workspace root"

        # The moves stay in the working tree for the user to commit, and the
        # session records the mode its features take, as adopt does.
        if [ -d "$session_dir/.git" ]; then
            _explain_nothing_committed "$session_dir" .cs logs archives age-recipients \
                README.md discoveries.md summary.md secrets.enc secrets.age .gitignore .gitattributes
            _record_feature_mode "$session_dir"
        fi
    fi

    # Phase 2: Ensure .cs/ subdirectories exist (handles partial migrations and edge cases)
    if [ ! -d "$session_dir/.cs/local" ]; then
        mkdir -p "$session_dir/.cs/local"
    fi

    # Phase 2a: Convert a legacy line-per-message mail inbox to the maildir,
    # and a legacy line-per-task queue file to the queue directory.
    migrate_mailbox "$session_dir"
    _queue_convert_legacy "$session_dir/.cs/local"

    # Phase 2b: Relocate the session log to machine-local state. The audit trail
    # (bash commands, lifecycle events, autosave notes) is per-checkout, not
    # shared — keeping it git-synced with merge=union interleaved every machine's
    # commands into the one shared repo. Move it under .cs/local/ (gitignored) so
    # it stays with the machine that produced it; the shared structured record
    # lives in timeline.jsonl. The tracked deletion is left for the next normal
    # commit, as with the README-frontmatter move below. One-time, idempotent:
    # once the old file is gone the block is a no-op. During the upgrade window a
    # peer still on the old cs may keep appending to the tracked log, so a
    # one-time modify/delete conflict on this low-stakes file is possible — take
    # either side.
    # An encrypted session's log belongs behind .cs/private; open has already
    # refused a locked vault, so cs_private_dir resolves here.
    if [ -f "$session_dir/.cs/logs/session.log" ]; then
        local log_dir
        log_dir=$(cs_private_dir "$session_dir/.cs") \
            || error "Cannot move .cs/logs/session.log: .cs/private $(cs_private_state "$session_dir/.cs"), and cs cannot write there."
        cat "$session_dir/.cs/logs/session.log" >> "$log_dir/session.log"
        rm -f "$session_dir/.cs/logs/session.log"
        rmdir "$session_dir/.cs/logs" 2>/dev/null || true
        # Drop the obsolete union rule for the relocated log. awk, not grep -v:
        # grep exits 1 when that was the only line, and an empty file is the
        # right result there.
        local ga="$session_dir/.gitattributes"
        if [ "$tracked_tree_is_ours" = 1 ] && [ -f "$ga" ] && grep -q 'logs/session\.log merge=union' "$ga"; then
            cs_write_atomic "$ga" awk '!/logs\/session\.log merge=union/' "$ga" 2>/dev/null || true
        fi
        notice session.log "moved from .cs/logs/ to ${log_dir#"$session_dir"/}/"
    fi

    # Remove inert sync/remote metadata left by older versions (the sync
    # subsystem was removed; nothing reads these files anymore)
    if [ "$repair" = all ]; then
        rm -f "$session_dir/.cs/sync.conf" "$session_dir/.cs/remote.conf"
    fi

    # Native memory import must precede creating a portable memory index.
    cs_engine_call "$engine" prepare_workspace "$session_dir" migrate_storage || return $?
    if [ ! -d "$session_dir/.cs/memory" ] || [ ! -d "$session_dir/.cs/plans" ]; then
        mkdir -p "$session_dir/.cs"/{memory,plans}
    fi

    # Phase 4b: Fold a legacy discoveries.md into the narrative topic file, then
    # ensure the narrative file + index pointer exist (idempotent; skipped while
    # the migration stamp is fresh).
    migrate_discoveries_to_narrative "$session_dir"
    actor_slug=$(_slugify "$actor_raw")
    if [ "$repair" != none ]; then
        ensure_narrative_file "$session_dir" "$actor_slug"
    fi

    # Phase 13: the resume protocol reads live narratives only; rewrite the
    # read-all sentences cs wrote into files that predate rotation. The
    # narrative is no stamp probe and old wording can come back into it (a
    # merge, a restore), so this runs on every open: its probe reads eight
    # lines of the narrative and greps MEMORY.md and CLAUDE.local.md.
    migrate_narrative_resume_wording "$session_dir" "$actor_slug"

    if [ "$repair" = all ]; then
        _migrate_session_documents "$session_dir" "$actor_slug"
    fi

    # The engine's own phases. The adapter reads CS_MIGRATE_REPAIR: Claude runs
    # its one-time phases only when it is "all", and its binding check and
    # colour backfill on every open. A bare call, so errexit still ends the
    # open on a failed write inside it, before anything is stamped.
    cs_engine_call "$engine" prepare_workspace "$session_dir" migrate

    # A stamp that cannot be written costs only speed: without it the next
    # open runs every phase again, which is what it did before the stamp.
    if [ "$repair" != none ] && [ "$_CS_MIGRATE_CLEAN" = 1 ]; then
        _write_migration_stamp "$session_dir" "$actor_raw" "$actor_slug" "$engine" 2>/dev/null || true
    fi
}

# Cross-platform helpers
