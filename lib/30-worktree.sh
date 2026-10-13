# ABOUTME: Parallel feature worktrees: name parsing, bootstrap, create, merge, and record fusion.
# ABOUTME: Backs 'cs <base>@<feature>' and the finish skill's integrate and retire entries.

cs_split_worktree_name() {
    local name="$1"
    case "$name" in
        *@*) ;;
        *) return 1 ;;
    esac
    CS_WT_BASE="${name%%@*}"
    CS_WT_TASK="${name#*@}"
    if [ -z "$CS_WT_BASE" ]; then
        error "Session name cannot be empty before '@' (expected <base>@<feature>)"
    fi
    validate_session_name "$CS_WT_BASE"
    # The feature half names the branch cs/<feature>, and git refuses a ref
    # component that starts with a dot.
    case "$CS_WT_TASK" in
        .*) error "Worktree feature name cannot start with a dot" ;;
    esac
    if [ -z "$CS_WT_TASK" ] || ! [[ "$CS_WT_TASK" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        error "Worktree feature name must contain only alphanumeric characters, hyphens, underscores, and dots"
    fi
    return 0
}

# Create the .cs/ skeleton inside a worktree whose repo does not track .cs/
# (ignored mode). Leaves the checkout's CLAUDE.md alone — in these repos it
# is the project's own tracked file.
bootstrap_worktree_meta() {
    local wt_dir="$1" base_name="$2" task="$3" base_dir="$4"
    mkdir -p "$wt_dir/.cs"/{local,memory}
    _copy_base_context "$base_dir/.cs" "$wt_dir/.cs"
    _write_session_readme_head "$wt_dir/.cs/README.md" "$base_name@$task" "[worktree]" "[\"$base_name@$task\"]"
    cat >> "$wt_dir/.cs/README.md" << EOF
Feature worktree of session '$base_name' on branch cs/$task.

## Objective

[Describe this feature]
EOF
    cat > "$wt_dir/.cs/local/session.log" << EOF
Claude Code Session Log
Session: $base_name@$task
Started: $(date '+%Y-%m-%d %H:%M:%S')

================================================================================

EOF
    ensure_narrative_file "$wt_dir"
}

# Give an ignored-mode feature the base's context, which git cannot carry:
# the memory topics, the MEMORY.md index, plans/ and summary.md. Never a
# narrative (the feature keeps its own and fusion appends it back), .cs/local,
# a lock or the timeline. A symlink is skipped, not followed: it would copy
# whatever it points at into the feature. plans/ is copied file by file for
# the same reason, so a link inside it (to another session's plans, say) stays
# behind; only regular files come over. A failed copy warns and the create
# goes on; the feature only starts with less context.
# Each topic copied is recorded as .cs/local/inherited-topics/<name>, a file
# holding the copy's "<cksum> <bytes>", so the fuse can tell a topic the
# feature wrote from one it was handed. One file per topic: the file system
# keeps any name whole, and nothing has to parse one.
_copy_base_context() {  # base_meta wt_meta
    local src="$1" dst="$2" f name sum
    for f in "$src"/memory/*.md; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        name="${f##*/}"
        case "$name" in narrative.*.md|narrative.md) continue ;; esac
        if ! cp "$f" "$dst/memory/$name"; then
            warn "could not copy memory/$name from the base"
            continue
        fi
        sum=$(cksum < "$dst/memory/$name") \
            && mkdir -p "$dst/local/inherited-topics" \
            && printf '%s\n' "$sum" > "$dst/local/inherited-topics/$name" \
            || warn "could not record memory/$name as inherited from the base"
    done
    if [ -d "$src/plans" ] && [ ! -L "$src/plans" ]; then
        local rel parent
        mkdir -p "$dst/plans" || warn "could not create plans/ in the feature"
        # find -P (the default) never descends a linked dir, and -type f
        # leaves out links and specials.
        (cd "$src/plans" && find . -type f -print0) | while IFS= read -r -d '' rel; do
            rel="${rel#./}"
            # Parameter expansion, not dirname: a "-sub" component reads as an
            # option to it, and $( ) drops a trailing newline from a name.
            parent=.
            case "$rel" in */*) parent="${rel%/*}" ;; esac
            { mkdir -p "$dst/plans/$parent" && cp "$src/plans/$rel" "$dst/plans/$rel"; } \
                || warn "could not copy plans/$rel from the base"
        done || warn "could not list plans/ in the base"
    fi
    if [ -f "$src/summary.md" ] && [ ! -L "$src/summary.md" ]; then
        cp "$src/summary.md" "$dst/summary.md" || warn "could not copy summary.md from the base"
    fi
    return 0
}

# True when a checkout has uncommitted changes to tracked files (staged or
# unstaged). Untracked files are a separate question with per-site messages.
_tree_is_dirty() {
    ! git -C "$1" diff --quiet 2>/dev/null \
        || ! git -C "$1" diff --cached --quiet 2>/dev/null
}

# Paths in a worktree that git does not track, one per line, leaving out cs's
# own bookkeeping: the whole .cs tree in ignored mode, plus the settings and
# protocol files, none of it the user's to commit (ignored-mode fusion carries
# .cs into the base before the removal, and the removal passes --force
# precisely because these are expected). Finder's .DS_Store is no one's work
# either, as cs -rm also treats it. With --ignored, the ignored paths; else
# the untracked ones git does not ignore.
_worktree_others() {  # wt_dir [--ignored]
    # -z, then one path per line with a newline inside a name shown as "?":
    # without it git quotes any name holding a newline or a non-ASCII byte,
    # and the quote in front hides cs's own files from the patterns below.
    # Names are bytes here (LC_ALL=C): in a multibyte locale that cannot
    # decode one, tr stops mid-list. A listing that fails is a failure, never
    # an empty list: the caller would remove the worktree on it.
    local listing
    listing=$(git -C "$1" ls-files -z --others ${2:+"$2"} --exclude-standard 2>/dev/null \
              | LC_ALL=C tr '\n\0' '?\n') || return 1
    [ -n "$listing" ] || return 0
    printf '%s\n' "$listing" \
        | LC_ALL=C grep -v -e '^\.cs/' -e '^\.claude/settings\.local\.json$' -e '^CLAUDE\.local\.md$' \
            -e '^\.DS_Store$' -e '/\.DS_Store$' \
        || [ $? -eq 1 ]
}

# Untracked files in a worktree that git does not ignore, one per line: work
# the user has not committed, which retire refuses over. The merge gate and
# the readiness screen MUST read from this one definition; when they
# disagreed, a worktree predating the cs exclude reported blocked on a merge
# that would have gone straight through.
_worktree_untracked_at_risk() {  # wt_dir
    _worktree_others "$1"
}

# Directory names whose contents a build, an install or a test run writes
# again: an ignored file under one of these, at any depth, goes with a retired
# worktree. Every other ignored file goes to the system trash instead.
CS_REGENERABLE_DIRS=(
    node_modules .svelte-kit .next .nuxt .output .turbo .parcel-cache .vite .astro .angular
    coverage .nyc_output htmlcov
    __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .venv venv .hypothesis
    target .gradle .dart_tool .direnv
    test-results playwright-report
)

# The paths given one per line on stdin that lie under a regenerable
# directory (keep=regenerable) or that do not (keep=other). A path's last
# component is its own name, so only the directories above it count.
_regenerable_filter() {  # regenerable|other
    LC_ALL=C awk -F/ -v keep="$1" -v names="${CS_REGENERABLE_DIRS[*]}" '
        BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) regenerable[list[i]] = 1 }
        {
            under = 0
            for (i = 1; i < NF; i++) if ($i in regenerable) { under = 1; break }
            if (under == (keep == "regenerable")) print
        }'
}

# The system trash command, one word per line: macOS's trash, else GLib's
# gio trash. Prints nothing when neither is installed.
_system_trash_command() {
    if command -v trash >/dev/null 2>&1; then
        echo trash
    elif command -v gio >/dev/null 2>&1; then
        printf '%s\n' gio trash
    fi
}

# The entries of a listing of files a removal would destroy, from three
# lists on stdin separated by empty lines: the checkout's paths that stay
# (tracked, or deleted anyway); "<count><TAB><path>" for each directory git
# does not list into (a nested repository, shown by git as one path ending in
# "/"); and the paths at risk. A directory holding no path that stays is one
# entry with the number of files at risk under it, any other path is an
# entry alone. Prints "<files><TAB><entry>", the entries holding the most
# files first, then by path.
_untracked_entries() {
    local tab=$'\t'
    LC_ALL=C awk '
        BEGIN { section = 0 }
        $0 == "" { section++; next }
        section == 0 {
            dir = $0
            if (!sub(/\/[^\/]*$/, "/", dir) || (dir in tracked)) next
            n = split(dir, seg, "/")
            dir = ""
            for (i = 1; i < n; i++) { dir = dir seg[i] "/"; tracked[dir] = 1 }
            next
        }
        section == 1 {
            cut = index($0, "\t")
            inside[substr($0, cut + 1)] = substr($0, 1, cut - 1)
            next
        }
        {
            files = 1
            if ($0 ~ /\/$/) {
                if (!($0 in inside)) { unknown = $0; exit }
                files = inside[$0]
            }
            entry = $0
            n = split($0, seg, "/")
            dir = ""
            for (i = 1; i < n; i++) {
                dir = dir seg[i] "/"
                if (!(dir in tracked)) { entry = dir; break }
            }
            count[entry] += files
        }
        END {
            if (unknown != "") {
                printf "no file count for the directory %s\n", unknown > "/dev/stderr"
                exit 1
            }
            for (entry in count) printf "%d\t%s\n", count[entry], entry
        }' \
    | LC_ALL=C sort -t "$tab" -k1,1nr -k2
}

# The listing of the entries on stdin (_untracked_entries): the count phrase
# ("1 file", "60,882 files"), then one line per entry indented four spaces, a
# directory with its file count in a column past the longest directory
# shown. With a number, at most that many entries, then how many are not
# shown; with "all", every entry.
_untracked_listing_format() {  # shown|all
    LC_ALL=C awk -v shown="$1" '
        function grouped(n,    s) {
            s = sprintf("%d", n)
            while (s ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]($|,)/, ",&", s)
            return s
        }
        function files(n) { return grouped(n) (n == 1 ? " file" : " files") }
        BEGIN { if (shown == "all") shown = -1 }
        {
            cut = index($0, "\t")
            total += substr($0, 1, cut - 1)
            if (shown >= 0 && NR > shown) next
            held[NR] = substr($0, 1, cut - 1)
            path[NR] = substr($0, cut + 1)
            if (path[NR] ~ /\/$/ && length(path[NR]) > width) width = length(path[NR])
        }
        END {
            print files(total)
            for (i = 1; i <= NR && (shown < 0 || i <= shown); i++) {
                if (path[i] ~ /\/$/) printf "    %-" width "s  (%s)\n", path[i], files(held[i])
                else printf "    %s\n", path[i]
            }
            if (shown >= 0 && NR > shown) printf "    ... and %s more\n", grouped(NR - shown)
        }'
}

# The listing, at most 20 entries, from the three lists _untracked_entries
# reads on stdin.
_untracked_listing_render() {
    _untracked_entries | _untracked_listing_format 20
}

# The three lists _untracked_entries reads, for the paths at risk in a
# checkout given one per line, and paths that stay beside the tracked ones
# (deleted anyway, so never inside a collapsed entry). git lists a nested
# repository as one path ending in "/", so the files under each are counted
# here. Fails when git cannot list the tracked paths or a nested repository
# cannot be read.
_untracked_listing_input() {  # checkout_dir paths [staying_paths]
    local dir="$1" paths="$2" staying="${3:-}" tracked nested="" repo files
    tracked=$(git -C "$dir" ls-files -z | LC_ALL=C tr '\n\0' '?\n') || return 1
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        files=$(find "$dir/$repo" ! -type d | wc -l) || return 1
        nested="$nested${files//[[:space:]]/}"$'\t'"$repo"$'\n'
    done <<< "$(printf '%s\n' "$paths" | LC_ALL=C grep '/$' || [ $? -eq 1 ])"
    [ -z "$tracked" ] || printf '%s\n' "$tracked"
    [ -z "$staying" ] || printf '%s\n' "$staying"
    printf '\n%s\n' "$nested"
    printf '%s\n' "$paths"
}

# The listing of files a removal of the checkout would destroy, at most 20
# entries, for the paths at risk given one per line.
_untracked_listing() {  # checkout_dir paths
    local input
    input=$(_untracked_listing_input "$1" "$2") || return 1
    printf '%s\n' "$input" | _untracked_listing_render
}

# Print the PID of a live lock on a session that the invoker does not own:
# empty when the lock is absent, its process is dead, or the lock is the
# invoking conversation's own (session_lock_owned_by_invoker). The integrate
# and retire entries both refuse on a non-empty answer.
_foreign_live_lock_pid() {  # session_name lock_file
    local pid
    [ -f "$2" ] || return 0
    pid=$(cat "$2" 2>/dev/null || echo "")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
    session_lock_owned_by_invoker "$1" "$pid" && return 0
    printf '%s\n' "$pid"
}

# Absolute form of a `git rev-parse` path answer (--git-dir, --git-common-dir).
# git answers relative to the checkout from a main worktree and absolute from
# a linked one; every path built on the answer (the integrate mutex, the temp
# worktree) must resolve the same from both.
_git_path_abs() {  # checkout_dir rev-parse-flag
    local p
    p=$(git -C "$1" rev-parse "$2" 2>/dev/null) || return 1
    case "$p" in
        /*) printf '%s\n' "$p" ;;
        *) printf '%s\n' "$1/$p" ;;
    esac
}

# The same merge policy setup_merge_attributes (lib/45-migrate.sh:4) gives a
# checkout, written clone-local: merge.ours.driver into the shared config and
# the three attribute lines into <common>/info/attributes, which every
# worktree of the repo reads and which dirties no tree. The temp worktree
# checks out whatever .gitattributes the base has committed, which may lack
# these lines; without them tracked-mode timeline and narrative appends on
# both sides conflict instead of union-merging.
_setup_merge_attributes_clone_local() {  # base_dir common_dir
    git -C "$1" config merge.ours.driver true 2>/dev/null || true
    local attrs="$2/info/attributes"
    mkdir -p "$2/info"
    if ! grep -q 'MEMORY\.md merge=ours' "$attrs" 2>/dev/null; then
        printf '.cs/memory/MEMORY.md merge=ours\n' >> "$attrs"
    fi
    if ! grep -q 'timeline\.jsonl merge=union' "$attrs" 2>/dev/null; then
        printf '.cs/timeline.jsonl merge=union\n' >> "$attrs"
    fi
    if ! grep -q 'narrative\.\*\.md merge=union' "$attrs" 2>/dev/null; then
        printf '.cs/memory/narrative.*.md merge=union\n' >> "$attrs"
    fi
}

# Tracked-.cs mode: MEMORY.md merges with merge=ours, so an edit to it on the
# feature is dropped by the merge that follows (only pointers to new targets
# are appended after it); say so first.
_warn_memory_index_changed() {  # base_dir ref
    local mb
    mb=$(git -C "$1" merge-base HEAD "$2" 2>/dev/null || echo "")
    if [ -n "$mb" ] \
        && ! git -C "$1" diff --quiet "$mb" "$2" -- .cs/memory/MEMORY.md 2>/dev/null; then
        warn "MEMORY.md changed on $2; merge=ours keeps the base copy and appends only pointers to targets it lacks. Review: git -C \"$1\" diff $mb $2 -- .cs/memory/MEMORY.md"
    fi
}

# Print the task name of every verified feature worktree of a base, one per
# line. Glob the sessions root then ask git to confirm each candidate — the
# reverse direction would enumerate the main checkout, and for an adopted base
# it would also enumerate the underlying project's own worktrees, which are not
# cs sessions at all. Asking git for the path on both sides is what makes this
# survive a directory whose two spellings differ, exactly as
# _doctor_check_worktrees does.
_worktree_features() {  # base_name
    local base_name="$1"
    local base_dir d name task d_real registered
    base_dir=$(_resolve_session_dir "$base_name")
    [ -d "$base_dir" ] || return 0
    git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0

    registered=$(git -C "$base_dir" worktree list --porcelain 2>/dev/null || true)

    for d in "$SESSIONS_ROOT/$base_name"@*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        task="${name#*@}"
        [ -n "$task" ] || continue
        d_real=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) \
            || d_real=$(cd "$d" 2>/dev/null && pwd -P || echo "$d")
        case "
$registered
" in
            *"
worktree $d_real
"*) printf '%s\n' "$task" ;;
        esac
    done
}

# Print one tab-separated readiness record for a base's feature worktree:
#   task branch ahead merged ff wt_dirty untracked base_dirty lock state
# Every fact is computed by the function the real gate calls, so the answer can
# never disagree with the refusal the merge would produce.
_feature_readiness() {  # base_name task
    local base_name="$1" task="$2"
    local base_dir wt_dir wt_name branch
    base_dir=$(_resolve_session_dir "$base_name")
    wt_name="$base_name@$task"
    wt_dir="$SESSIONS_ROOT/$wt_name"
    branch=$(_read_local_state "$wt_dir/.cs/local/state" task_branch)
    [ -n "$branch" ] || branch="cs/$task"

    local ahead=0 merged=0 ff=0 wt_dirty=0 untracked=0 base_dirty=0 lock="none"

    ahead=$(git -C "$base_dir" rev-list --count "HEAD..$branch" 2>/dev/null || echo 0)

    # "Already merged" needs the tip STRICTLY behind base HEAD. A fresh
    # worktree's branch sits AT base HEAD, where is-ancestor is also true, so
    # a bare is-ancestor would report untouched work as landed. Same guard as
    # _doctor_check_worktrees.
    if git -C "$base_dir" merge-base --is-ancestor "$branch" HEAD 2>/dev/null \
        && [ "$(git -C "$base_dir" rev-parse "$branch" 2>/dev/null)" \
             != "$(git -C "$base_dir" rev-parse HEAD 2>/dev/null)" ]; then
        merged=1
    fi

    # A merge fast-forwards when base HEAD is already an ancestor of the
    # branch: `git merge --no-edit` carries no --no-ff, so no merge commit is
    # written and the screen must not promise one.
    if git -C "$base_dir" merge-base --is-ancestor HEAD "$branch" 2>/dev/null; then
        ff=1
    fi

    _tree_is_dirty "$wt_dir" && wt_dirty=1
    _tree_is_dirty "$base_dir" && base_dirty=1

    local others
    others=$(_worktree_untracked_at_risk "$wt_dir") \
        || error "Could not list the untracked files in $wt_dir"
    if [ -n "$others" ]; then
        untracked=$(printf '%s\n' "$others" | wc -l | tr -d '[:space:]')
    fi

    # Gate order: base lock, then worktree lock. A lock owned by this invoker
    # is exempt, exactly as the merge gate treats it.
    local lock_session lock_file pid
    for lock_session in "$base_name" "$wt_name"; do
        if [ "$lock_session" = "$base_name" ]; then
            lock_file="$base_dir/.cs/session.lock"
        else
            lock_file="$wt_dir/.cs/session.lock"
        fi
        [ -f "$lock_file" ] || continue
        pid=$(cat "$lock_file" 2>/dev/null || echo "")
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
        session_lock_owned_by_invoker "$lock_session" "$pid" && continue
        if [ "$lock_session" = "$base_name" ]; then lock="base"; else lock="worktree"; fi
        break
    done

    # State is the first blocker retire_feature_worktree would hit, in its order.
    local state="ready"
    if [ "$lock" != "none" ]; then
        state="locked"
    elif [ "$wt_dirty" = 1 ]; then
        state="dirty"
    elif [ "$untracked" != 0 ]; then
        state="untracked"
    elif [ "$base_dirty" = 1 ]; then
        state="base-dirty"
    elif [ "$merged" = 1 ]; then
        state="merged"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$task" "$branch" "$ahead" "$merged" "$ff" \
        "$wt_dirty" "$untracked" "$base_dirty" "$lock" "$state"
}

# Resolve a symlinked directory to its real path, portably. BSD readlink gained
# -f only in macOS 12.3; cd+pwd -P follows the link on every platform, and the
# fallback keeps the original path rather than aborting under set -e.
_resolve_symlink_dir() {
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# Resolve a session name to its real directory (adopted sessions are
# symlinks into the project checkout). Prints the resolved path.
_resolve_session_dir() {
    local dir="$SESSIONS_ROOT/$1"
    [ -L "$dir" ] && dir="$(_resolve_symlink_dir "$dir")"
    printf '%s\n' "$dir"
}

# Gate worktree creation on the base checkout's tracked state. Runs in the
# main shell so a declined consent can exit cs cleanly (the creator is
# command-substituted, where an exit only leaves the subshell). Clean base
# returns; dirty base asks for informed consent on interactive terminals
# (the feature branches from the last commit and will not include uncommitted
# changes) and refuses everywhere else.
confirm_clean_worktree_base() {
    local base_dir="$1" base_name="$2"
    git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    _tree_is_dirty "$base_dir" || return 0
    if cs_interactive; then
        printf '\n    %b⚠%b  %s has uncommitted changes; the feature branches from the\n       last commit and will not include them.\n' \
            "$YELLOW" "$NC" "$base_name"
        printf '    Continue?  %b[y/N]%b %b›%b ' "$DIM" "$NC" "$GOLD" "$NC"
        local consent=""
        read -r consent || consent=""
        if [[ ! "$consent" =~ ^[Yy]$ ]]; then
            info "Cancelled"
            exit 0
        fi
    else
        error "Session '$base_name' has uncommitted changes; commit them first (a worktree materializes committed state only)"
    fi
}

# Create a linked git worktree of a base session as a sibling session dir.
# The caller gates dirty base state via confirm_clean_worktree_base. Prints
# the new worktree path.
create_worktree_session() {
    local base_dir="$1" base_name="$2" task="$3"
    local wt_dir="$SESSIONS_ROOT/$base_name@$task"
    local branch="cs/$task"

    if ! git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1; then
        error "Session '$base_name' has no git repo; worktrees need one"
    fi
    if [ -f "$base_dir/.git" ]; then
        error "Session '$base_name' is itself a worktree; create features from the main checkout"
    fi
    # Dirty-state gating happens in the caller (confirm_clean_worktree_base):
    # this function runs command-substituted, where an exit cannot stop cs.
    local untracked
    untracked=$(git -C "$base_dir" ls-files --others --exclude-standard 2>/dev/null | head -5 || true)
    if [ -n "$untracked" ]; then
        warn "Untracked files will not appear in the worktree:" >&2
        printf '%s\n' "$untracked" >&2
    fi

    if git -C "$base_dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        git -C "$base_dir" worktree add "$wt_dir" "$branch" >/dev/null \
            || error "git worktree add failed (is branch '$branch' checked out in another worktree?)"
    else
        git -C "$base_dir" worktree add -b "$branch" "$wt_dir" >/dev/null \
            || error "git worktree add failed"
    fi
    # The checkout can carry a committed link or per-actor state from the
    # base's history; refuse before the state writes below go through it.
    cs_assert_local_untracked "$wt_dir"

    local mode="tracked"
    if [ -z "$(git -C "$base_dir" ls-files -- .cs 2>/dev/null)" ]; then
        mode="ignored"
        bootstrap_worktree_meta "$wt_dir" "$base_name" "$task" "$base_dir"
    fi

    # The protocol file is normally gitignored, so no worktree inherits it
    # through git in either mode; write this worktree's own copy. The FILE
    # only — never touch a .gitignore here (ignored-mode worktrees check out
    # project repos whose .gitignore is theirs). Guarded: a repo that
    # (against CC convention) TRACKS CLAUDE.local.md checks its own copy
    # into the worktree; only overwrite when absent or already cs's own.
    if [ ! -f "$wt_dir/CLAUDE.local.md" ] \
        || grep -q 'cs:session-protocol' "$wt_dir/CLAUDE.local.md"; then
        write_session_claude_md "$wt_dir"
    fi

    # Cover the protocol file via the clone-local info/exclude in BOTH
    # modes. In ignored mode the checkout's .gitignore belongs to the
    # project and is never touched. In tracked mode the file is normally
    # covered by the base's own .gitignore entry — but a base committed
    # before the CLAUDE.local.md backfill (and never relaunched since)
    # checks out a .gitignore missing it, which would otherwise leave the
    # file untracked and block retirement's preflight. The exclude
    # entry is clone-local and harmless alongside a .gitignore entry (never
    # tracked, never dirties the task branch; shared with the base checkout
    # through the common git dir).
    local exclude
    exclude=$( (cd "$wt_dir" && git rev-parse --git-path info/exclude) 2>/dev/null || echo "" )
    # A worktree's git-path resolves to the common git dir, which git reports
    # as an absolute path. Reading that as relative would prepend $wt_dir,
    # writing the exclude entry to a nonsense path and leaving the protocol file
    # untracked, which then blocks retirement.
    case "$exclude" in
        "") : ;;
        /*) : ;;
        *) exclude="$wt_dir/$exclude" ;;
    esac
    if [ -n "$exclude" ]; then
        mkdir -p "${exclude%/*}" 2>/dev/null || true
        if ! grep -qF 'CLAUDE.local.md' "$exclude" 2>/dev/null; then
            echo 'CLAUDE.local.md' >> "$exclude"
        fi
        if ! grep -qF '.claude/settings.local.json' "$exclude" 2>/dev/null; then
            echo '.claude/settings.local.json' >> "$exclude"
        fi
        # Ignored mode means .cs is not TRACKED — it does not mean the project
        # ignores it. Where the project's .gitignore never named .cs/, the
        # skeleton bootstrap_worktree_meta just wrote shows up as untracked in
        # every git status the user runs here. Tracked mode must not get this
        # entry: there .cs belongs to the checkout.
        if [ "$mode" = "ignored" ] && ! grep -qF '.cs/' "$exclude" 2>/dev/null; then
            echo '.cs/' >> "$exclude"
        fi
    fi

    local state="$wt_dir/.cs/local/state"
    _set_local_state "$state" claude_session_id "$(_alloc_uuid)"
    _set_local_state "$state" claude_session_color "$(_alloc_random_color)"
    _set_local_state "$state" task_branch "$branch"
    _set_local_state "$state" cs_mode "$mode"
    _set_local_state "$state" cs_base "$base_name"

    setup_auto_memory "$wt_dir"

    # A feature worktree is a full cs session holding the same narrative, plans
    # and machine-local state as its base, so it gets the same privacy. cs
    # created this directory, so unlike an adopted session the ROOT is cs's to
    # set too. Kept here rather than left to migrate_session, which the worktree
    # open path deliberately never calls.
    _harden_session_meta "$wt_dir"
    chmod 700 "$wt_dir" 2>/dev/null || true

    echo "$wt_dir"
}

# The /finish progress record: one JSON object, replaced whole at each step of
# an integrate or a retire, that the cs mod reads to toast a start and an
# outcome and to draw a band while a gate runs (docs/session-layout.md). It
# sits with the base's other cs files: behind .cs/private in an encrypted
# session, in .cs/local otherwise, and nowhere while the vault is locked.
# Advisory only: a record that cannot be written costs one warning on stderr
# and the run goes on unrecorded, since landing correctly matters more than
# saying so. Each run has its own id; pid is this cs process, so a reader can
# tell a step a killed run left behind from one still running. Globals,
# because the EXIT handler that records a refusal runs after the locals are
# gone.
_finish_progress_begin() {  # base_dir task
    _FINISH_PROGRESS="" _FINISH_ID="$$-$(date +%s)" _FINISH_TASK="$2"
    _FINISH_SHA="" _FINISH_GATE_STARTED="" _FINISH_OUTCOME=""
    local dir
    if ! dir=$(cs_private_dir "$1/.cs"); then
        warn "cs: /finish progress not recorded: .cs/private $(cs_private_state "$1/.cs")" >&2
        return 0
    fi
    if ! CS_WRITE_QUIET=1 cs_mkdir_inside "$dir"; then
        warn "cs: /finish progress not recorded: could not create $dir" >&2
        return 0
    fi
    _FINISH_PROGRESS="$dir/finish-progress.json"
    trap '_finish_progress_exit "$?"' EXIT
}

# Replace the record with this run at <step>; an outcome (landed, refused,
# retired) may carry one more field, the landed commit or the refusal's reason.
_finish_progress_write() {  # step [key value]
    [ -n "${_FINISH_PROGRESS:-}" ] || return 0
    local step="$1" key="${2:-}" value="${3:-}"
    case "$step" in landed|refused|retired) _FINISH_OUTCOME="$step" ;; esac
    if ! cs_write_atomic "$_FINISH_PROGRESS" jq -nc \
            --arg id "$_FINISH_ID" --argjson pid "$$" --arg task "$_FINISH_TASK" \
            --arg sha "$_FINISH_SHA" --arg step "$step" --argjson ts "$(date +%s)" \
            --arg gate_started "$_FINISH_GATE_STARTED" --arg key "$key" --arg value "$value" \
            '{id: $id, pid: $pid, task: $task, sha: $sha, step: $step, ts: $ts}
             + (if $gate_started == "" then {} else {gate_started: ($gate_started | tonumber)} end)
             + (if $key == "" then {} else {($key): $value} end)' 2>/dev/null; then
        warn "cs: /finish progress not recorded: could not write $_FINISH_PROGRESS" >&2
        _FINISH_PROGRESS=""
    fi
    return 0
}

# The EXIT handler: a run that ends in failure before it wrote an outcome was
# refused, and the reason is the first line of the error that ended it. Never
# fails, so a handler chained after it still runs and the exit status stands.
_finish_progress_exit() {  # exit status
    if [ "$1" = 0 ] || [ -z "${_FINISH_PROGRESS:-}" ] || [ -n "${_FINISH_OUTCOME:-}" ]; then
        return 0
    fi
    local reason="${_CS_ERROR_MESSAGE:-}"
    reason="${reason%%$'\n'*}"
    if [ -z "$reason" ]; then
        case "$1" in 130|143) reason="interrupted" ;; *) reason="cs exited $1" ;; esac
    fi
    _finish_progress_write refused reason "$reason" || true
    return 0
}

# Move the worktree's ignored files that are not regenerable to the system
# trash, so retiring it deletes nothing git keeps no copy of; files under a
# regenerable directory (CS_REGENERABLE_DIRS) go with the worktree. Leaves
# what it moved in _RETIRE_TRASHED_COUNT and _RETIRE_TRASHED_LINES (one line
# per entry, by absolute path) for _retire_trashed_note. Refuses, having
# removed nothing, when no trash command is installed or the one that is
# fails.
_retire_trash_ignored_work() {  # wt_dir task
    local wt_dir="$1" task="$2" ignored trash_paths regenerable input entries listing count them=them nl=$'\n'
    ignored=$(_worktree_others "$wt_dir" --ignored) \
        || error "Could not list the ignored files in $wt_dir; nothing was removed"
    [ -n "$ignored" ] || return 0
    trash_paths=$(printf '%s\n' "$ignored" | _regenerable_filter other)
    [ -n "$trash_paths" ] || return 0
    regenerable=$(printf '%s\n' "$ignored" | _regenerable_filter regenerable)
    input=$(_untracked_listing_input "$wt_dir" "$trash_paths" "$regenerable") \
        && entries=$(printf '%s\n' "$input" | _untracked_entries) \
        || error "Could not count the ignored files in $wt_dir; nothing was removed"
    listing=$(printf '%s\n' "$entries" | _untracked_listing_format 20)
    count="${listing%%"$nl"*}"
    [ "$count" != "1 file" ] || them=it
    local -a trash_cmd=() targets=() named=()
    local word entry raw
    while IFS= read -r word; do trash_cmd+=("$word"); done <<< "$(_system_trash_command)"
    [ -n "${trash_cmd[0]:-}" ] \
        || error "Worktree has ${count% *} ignored ${count#* } that retiring moves to the system trash, but neither trash nor gio is installed, so nothing was removed. Move or delete $them, then run /finish $task here again:
${listing#*"$nl"}"
    # The lists show a newline inside a name as "?", so a "?" in an entry is
    # looked up among the names on disk that hold a newline: the trash
    # command gets the name as it is. Both are one character, so the entry's
    # length is the length of the name it stands for.
    case "$entries" in
        *'?'*)
            while IFS= read -r -d '' raw; do
                case "$raw" in *"$nl"*) named+=("$raw") ;; esac
            done < <(git -C "$wt_dir" ls-files -z --others --ignored --exclude-standard 2>/dev/null)
            ;;
    esac
    while IFS= read -r entry; do
        entry="${entry#*$'\t'}"
        case "$entry" in
            *'?'*)
                for raw in ${named[@]+"${named[@]}"}; do
                    case "${raw//"$nl"/?}" in
                        "$entry"*) entry="${raw:0:${#entry}}"; break ;;
                    esac
                done
                ;;
        esac
        targets+=("$wt_dir/${entry%/}")
    done <<< "$entries"
    local trash_err
    trash_err=$("${trash_cmd[@]}" "${targets[@]}" 2>&1 >/dev/null) \
        || error "Could not move ${count% *} ignored ${count#* } to the system trash, so nothing was removed; anything the trash command did move is in the trash. Move or delete $them, then run /finish $task here again:
${listing#*"$nl"}
${trash_cmd[0]}: ${trash_err:-exited with an error}"
    _RETIRE_TRASHED_COUNT="$count"
    _RETIRE_TRASHED_LINES=$(printf '%s\n' "$entries" \
        | LC_ALL=C awk -v dir="$wt_dir/" '{ cut = index($0, "\t"); print substr($0, 1, cut) dir substr($0, cut + 1) }' \
        | _untracked_listing_format all | tail -n +2)
}

# What _retire_trash_ignored_work moved to the system trash, as a heading
# ending in $1 and one line per entry; nothing when it moved nothing.
_retire_trashed_note() {  # heading_end
    [ -n "${_RETIRE_TRASHED_COUNT:-}" ] || return 0
    printf 'Moved %s ignored %s to the system trash%s:\n%s\n' \
        "${_RETIRE_TRASHED_COUNT% *}" "${_RETIRE_TRASHED_COUNT#* }" "$1" "$_RETIRE_TRASHED_LINES"
}

# Retire an integrated feature worktree: fuse its session records into the
# base (ignored mode), remove the worktree and delete its branch. Backs the
# unadvertised `cs <base> -retire-feature <task> <sha> [--force]` that
# skills/finish/scripts/finish.sh drives after an integrate. It never merges:
# <sha> is the commit /finish landed and must already be reachable from the
# base, and the branch tip must be too, so nothing the base lacks is ever
# discarded. --force is the squash-merged-PR path — the skill passes it only
# on GitHub's evidence that the PR merged, since the branch is then never an
# ancestor — and every other refusal still applies. Every refusal names what
# the user has to do next, in their own words; the skill prints them verbatim.
retire_feature_worktree() {  # base_name task sha [--force]
    local usage="Usage: cs <base> -retire-feature <task> <sha> [--force]"
    [ $# -ge 3 ] || error "$usage"
    local base_name="$1" task="$2" sha="$3" force=""
    shift 3
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1; shift ;;
            *) error "$usage" ;;
        esac
    done
    local base_dir
    base_dir=$(_resolve_session_dir "$base_name")
    local wt_dir="$SESSIONS_ROOT/$base_name@$task"
    local branch="cs/$task"

    [ -d "$base_dir" ] || error "Base session not found: $base_name"
    [ -d "$wt_dir" ] || error "No worktree for feature '$task' (expected $wt_dir)"
    _finish_progress_begin "$base_dir" "$task"

    local wt_name="$base_name@$task"
    if [ "${CLAUDE_SESSION_NAME:-}" = "$wt_name" ]; then
        error "This is the '$wt_name' conversation itself, and a worktree can't remove the directory it is running in. Close this session, then run /finish $task in '$base_name'."
    fi

    sha=$(git -C "$base_dir" rev-parse -q --verify "$sha^{commit}" 2>/dev/null) \
        || error "Commit not found in $base_name: $sha"
    _FINISH_SHA="$sha"
    local tip
    tip=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null) || error "Not a git checkout: $wt_dir"
    # Without --force the captured commit must be in the base. With it (a
    # squash-merged PR, on GitHub's evidence) that check is skipped, but the
    # branch tip must still be at or behind the captured commit either way:
    # a commit made after the capture is work no landing carried, and
    # deleting the branch would lose it.
    if [ -z "$force" ]; then
        git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null \
            || error "$sha is not integrated into $base_name; run /finish $task before retiring"
    fi
    if ! git -C "$base_dir" merge-base --is-ancestor "$tip" "$sha" 2>/dev/null \
        && { [ -n "$force" ] || ! git -C "$base_dir" merge-base --is-ancestor "$tip" HEAD 2>/dev/null; }; then
        local n_after
        n_after=$(git -C "$wt_dir" rev-list --count "$sha..HEAD" 2>/dev/null || echo "?")
        error "$n_after commit(s) on $branch after $sha are not integrated; run /finish $task again before retiring"
    fi

    local pid
    pid=$(_foreign_live_lock_pid "$wt_name" "$wt_dir/.cs/session.lock")
    if [ -n "$pid" ]; then
        error "The feature is landed, but its worktree is still here: the '$wt_name' conversation is open in it (PID $pid), and a directory can't be removed from under a running Claude. Close that session yourself (/exit there), then run /finish $task here again and it will be removed."
    fi
    pid=$(_foreign_live_lock_pid "$base_name" "$base_dir/.cs/session.lock")
    if [ -n "$pid" ]; then
        error "Base session '$base_name' is open elsewhere (PID $pid); run /finish $task from that conversation"
    fi

    # git worktree remove --force recurses into a mount, so a volume mounted
    # inside the worktree would lose what it holds.
    local mounted
    mounted=$(_volume_mounted_under "$wt_dir") \
        || error "cs could not read the mount table, so it cannot tell whether a volume is mounted inside $wt_dir; refusing to remove the worktree."
    [ -z "$mounted" ] \
        || error "The feature is landed, but its worktree has a volume mounted inside it at $mounted, and removing the worktree would delete what the volume holds. Unmount it, then run /finish $task here again."

    if _tree_is_dirty "$wt_dir"; then
        error "Worktree has uncommitted changes; commit them in $wt_dir first (cs never commits for you)"
    fi
    local wt_untracked
    wt_untracked=$(_worktree_untracked_at_risk "$wt_dir") \
        || error "Could not list the untracked files in $wt_dir; nothing was removed"
    if [ -n "$wt_untracked" ]; then
        local wt_listing wt_count wt_them=them nl=$'\n'
        wt_listing=$(_untracked_listing "$wt_dir" "$wt_untracked") \
            || error "Could not count the untracked files in $wt_dir; nothing was removed"
        wt_count="${wt_listing%%"$nl"*}"
        [ "$wt_count" != "1 file" ] || wt_them=it
        error "Worktree has ${wt_count% *} untracked ${wt_count#* } that removal would destroy; commit or remove $wt_them first:
${wt_listing#*"$nl"}"
    fi
    # The base's own .cs/ bookkeeping is exempt: in tracked mode the integrate
    # that just landed this feature wrote a timeline event there, and removing
    # a worktree touches no base file, so that dirt is no reason to refuse.
    if ! git -C "$base_dir" diff --quiet -- . ':(exclude).cs' 2>/dev/null \
        || ! git -C "$base_dir" diff --cached --quiet -- . ':(exclude).cs' 2>/dev/null; then
        error "Base session has uncommitted changes; commit them in $base_dir first"
    fi

    # Ignored-mode records are fused only once the worktree is gone: set them
    # aside, remove, then fuse from the copy, so a removal that fails (a
    # locked worktree, say) leaves the base's records untouched and puts the
    # worktree's own back, and the retry fuses exactly once.
    # The staging directory sits beside the worktree, on its filesystem, so
    # both moves are renames: nothing is half-copied on a failure.
    # A fuse that refuses after the removal would strand the records in the
    # staging directory, so its one refusal is asked before anything moves.
    # Asked whether or not the worktree has a log: a locked vault takes the
    # base's .cs/memory with it, which every fuse writes.
    local mode aside=""
    mode=$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)
    if [ "$mode" = "ignored" ]; then
        cs_private_dir "$base_dir/.cs" >/dev/null \
            || error "cannot fuse the worktree's records: $base_dir/.cs/private is locked. Mount it, then retry."
    fi
    _retire_trash_ignored_work "$wt_dir" "$task"
    local trashed nl=$'\n'
    trashed=$(_retire_trashed_note " before this failed")
    if [ "$mode" = "ignored" ]; then
        aside="$SESSIONS_ROOT/.retire-$wt_name.$$"
        mkdir "$aside" 2>/dev/null || error "Could not create $aside to set aside $wt_dir/.cs for the record fuse${trashed:+$nl$trashed}"
        mv "$wt_dir/.cs" "$aside/cs" || { rmdir "$aside" 2>/dev/null; error "Could not set aside $wt_dir/.cs for the record fuse${trashed:+$nl$trashed}"; }
    fi
    local remove_err
    if ! remove_err=$(git -C "$base_dir" worktree remove --force "$wt_dir" 2>&1); then
        if [ -n "$aside" ]; then
            if mv "$aside/cs" "$wt_dir/.cs"; then
                rmdir "$aside" 2>/dev/null
            else
                error "git worktree remove failed for $wt_dir, and its session records could not be put back: they are at $aside/cs (move that directory to $wt_dir/.cs by hand)
$remove_err${trashed:+$nl$trashed}"
            fi
        fi
        error "git worktree remove failed for $wt_dir; nothing was fused or deleted
$remove_err${trashed:+$nl$trashed}"
    fi
    if [ -n "$aside" ]; then
        ( fuse_session_records "$aside/cs" "$base_dir/.cs" ) \
            || error "The worktree $wt_dir is removed, but its session records could not be fused into $base_dir/.cs: they are at $aside/cs. Fuse what is missing by hand, then delete that directory.${trashed:+$nl$trashed}"
        rm -rf "$aside"
    fi
    if [ -n "$force" ]; then
        git -C "$base_dir" branch -D "$branch" >/dev/null 2>&1 \
            || warn "Branch $branch was not deleted"
    else
        git -C "$base_dir" branch -d "$branch" >/dev/null 2>&1 \
            || warn "Branch $branch was not deleted (not fully merged?)"
    fi
    _spawn_discard_seeds "$wt_name"

    _append_record "$base_dir/.cs/timeline.jsonl" \
           --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "worktree-retired" \
           --arg task "$task" \
        '{ts: $ts, event: $event, task: $task}'
    _finish_progress_write retired
    _retire_trashed_note ""
    printf 'retired %s %s\n' "$task" "$sha"
}

# Remove the temp worktree and release the mutex on every exit path of
# integrate_feature_worktree, including error's exit 1. Globals because an
# EXIT trap runs after the function's locals are gone.
_integrate_cleanup() {
    if [ -n "${_INTEGRATE_TMP:-}" ]; then
        # Remove if present, then prune regardless: a directory gone with its
        # registration surviving is exactly what prune exists for. A temp
        # that cannot be removed must not abort the handler under set -e:
        # the lock below still has to be released.
        if [ -d "$_INTEGRATE_TMP" ]; then
            git -C "$_INTEGRATE_BASE_DIR" worktree remove --force "$_INTEGRATE_TMP" >/dev/null 2>&1 \
                || { rm -rf "$_INTEGRATE_TMP" 2>/dev/null || :; }
        fi
        git -C "$_INTEGRATE_BASE_DIR" worktree prune >/dev/null 2>&1 || true
    fi
    # A run terminated mid-gate still holds the gate's output log. A log that
    # cannot be removed must not abort the handler under set -e: the lock
    # below still has to be released.
    [ -n "${_INTEGRATE_GATE_LOG:-}" ] && { rm -f "$_INTEGRATE_GATE_LOG" 2>/dev/null || :; }
    # A lock already gone must not abort the handler under set -e: the path
    # still has to be forgotten below.
    [ -n "${_INTEGRATE_LOCK:-}" ] && { rm -r "$_INTEGRATE_LOCK" 2>/dev/null || :; }
    # A TERM'd run cleans up twice, from the signal handler and then from EXIT.
    # Forgetting the paths after the first pass keeps the second from removing
    # a lock or temp another integrate has since taken.
    _INTEGRATE_LOCK=""
    _INTEGRATE_TMP=""
    _INTEGRATE_GATE_LOG=""
    return 0
}

# Integrate a feature worktree's captured commit into the base session while
# the feature stays open: merge base HEAD + <sha> in a temporary detached
# worktree, run the gates there, fast-forward the base onto the result. Removes
# nothing — the worktree, the branch and the feature session all remain until
# retire_feature_worktree, the same skill's closing step. Backs the unadvertised
# `cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate...>`
# that skills/finish/scripts/finish.sh drives. Every refusal is an error that
# names the next command.
integrate_feature_worktree() {  # base_name task sha [--from-remote [--ci-green]] -- gate...
    local usage="Usage: cs <base> -integrate-feature <task> <sha> [--from-remote [--ci-green]] -- <gate command...>"
    [ $# -ge 3 ] || error "$usage"
    local base_name="$1" task="$2" sha="$3"
    shift 3
    local from_remote="" ci_green=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-remote) from_remote=1; shift ;;
            # The caller vouches that the PR's checks passed on the landing
            # commit; the entry has no GitHub access and never infers it.
            --ci-green) ci_green=1; shift ;;
            --) shift; break ;;
            *) error "$usage" ;;
        esac
    done
    [ -z "$ci_green" ] || [ -n "$from_remote" ] || error "$usage (--ci-green needs --from-remote: it describes the landing commit's checks on origin)"
    [ $# -gt 0 ] || error "$usage (a gate command is required; pass -- true to run none)"

    local base_dir wt_dir branch
    base_dir=$(_resolve_session_dir "$base_name")
    wt_dir="$SESSIONS_ROOT/$base_name@$task"
    branch="cs/$task"
    [ -d "$base_dir" ] || error "Base session not found: $base_name"
    [ -d "$wt_dir" ] || error "No worktree for feature '$task' (expected $wt_dir)"
    _finish_progress_begin "$base_dir" "$task"
    # Herestring, not a pipe: grep -q's early exit would SIGPIPE the writer
    # and pipefail would read that as "not registered".
    local features
    features=$(_worktree_features "$base_name")
    grep -qxF -- "$task" <<< "$features" \
        || error "$wt_dir is not a registered worktree of $base_name (see: git -C \"$base_dir\" worktree list)"

    # Only the base lock matters: the feature worktree is never touched, so
    # its conversation may stay open. A live base that is not this
    # conversation is a refusal, never a wait.
    local pid
    pid=$(_foreign_live_lock_pid "$base_name" "$base_dir/.cs/session.lock")
    [ -z "$pid" ] || error "Base session '$base_name' is open elsewhere (PID $pid); run /finish $task from that conversation"

    sha=$(git -C "$base_dir" rev-parse -q --verify "$sha^{commit}" 2>/dev/null) \
        || error "Commit not found in $base_name: $sha"
    _FINISH_SHA="$sha"
    # Before the split: a detached base has no branch to land on either way,
    # and the ff-only would move a detached HEAD while the branch stays put.
    local base_branch
    base_branch=$(git -C "$base_dir" symbolic-ref -q --short HEAD 2>/dev/null) \
        || error "Base checkout is detached; check out the branch to land on (for a PR, the branch it targets), then re-run"
    if [ -n "$from_remote" ]; then
        git -C "$base_dir" merge-base --is-ancestor "$sha" "refs/remotes/origin/$base_branch" 2>/dev/null \
            || error "$sha is not reachable from origin/$base_branch; run: git -C \"$base_dir\" fetch origin, then check the PR's base branch"
    else
        git -C "$base_dir" merge-base --is-ancestor "$sha" "$branch" 2>/dev/null \
            || error "$sha is not reachable from $branch; capture the feature HEAD again"
    fi
    # Nothing to land: the record gains no step, and the retire that follows
    # writes the outcome.
    if git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        printf 'already-integrated %s %s\n' "$task" "$sha"
        return 0
    fi
    _finish_progress_write started

    if _tree_is_dirty "$base_dir"; then
        error "Base session has uncommitted changes; commit them in $base_dir first"
    fi
    local git_dir common
    git_dir=$(_git_path_abs "$base_dir" --git-dir) || error "Not a git checkout: $base_dir"
    common=$(_git_path_abs "$base_dir" --git-common-dir) || error "Not a git checkout: $base_dir"
    if git -C "$base_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
        || [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
        error "Base checkout has a merge or rebase in progress; finish or abort it, then re-run"
    fi

    # The mutex the autosave hook honours (hooks/autosave-commits.sh spells
    # the same path). Per-CHECKOUT, not per-clone: the base is always a main
    # checkout, so its --git-dir is the common dir, while a feature
    # worktree's autosave takes its own private gitdir's lock and never
    # contends with this integrate — the feature conversation stays open and
    # keeps snapshotting throughout a gate run. An existing directory is a
    # refusal, never stolen: a stale one is the user's to inspect and remove
    # (cs -doctor names it).
    local lock="$git_dir/cs/integrate.lock"
    mkdir -p "$git_dir/cs"
    # The base's own autosave takes this same lock for the length of one tree
    # write, so a refusal on the first try is far more often a snapshot in
    # flight than another integrate. Five tries a second apart outlast that
    # and still refuse promptly on a genuinely held lock.
    local tries=0
    while ! mkdir "$lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 5 ]; then
            error "Another integrate or an in-flight autosave holds $lock; wait a few seconds and re-run. Remove that directory only if it persists with no cs running"
        fi
        sleep 1
    done
    _INTEGRATE_LOCK="$lock"
    _INTEGRATE_BASE_DIR="$base_dir"
    _INTEGRATE_TMP=""
    _INTEGRATE_GATE_LOG=""
    # EXIT alone is not enough: a TERM/INT'd bash skips the EXIT trap
    # (measured: exit 143, no cleanup), stranding the mutex and the temp.
    # Same shape as lib/75-launch.sh:112-113. Armed before the pid write: a
    # write that fails under set -e must still release the directory. The
    # progress handler goes first, while $? is still the exit status.
    trap '_finish_progress_exit "$?"; _integrate_cleanup' EXIT
    trap '_integrate_cleanup; exit 130' INT TERM
    # The holder's pid, for cs -doctor's liveness check. Inside the lock, so
    # the directory and its evidence are created and removed together; the
    # autosave hook's own brief hold records nothing and releases with rmdir.
    echo "$$" > "$lock/pid"

    _integrate_in_temp "$base_dir" "$wt_dir" "$task" "$sha" "$common" "$from_remote" "$ci_green" "$@"
}

# The mutation half of integrate_feature_worktree, entered with the mutex
# held and the cleanup trap armed: merge base HEAD + <sha> in a temporary
# detached worktree under $TMPDIR, run the gate argv there, then
# fast-forward the base onto the result. The fast-forward is the atomic
# "base has not moved" check; a red gate or a conflict leaves base exactly
# as it was. No hook of the project fires inside the temp (core.hooksPath
# points at an empty directory for the add and the merge): the gate argv is
# the project's gate, run explicitly.
_integrate_in_temp() {  # base_dir wt_dir task sha common from_remote ci_green gate...
    local base_dir="$1" wt_dir="$2" task="$3" sha="$4" common="$5" from_remote="$6" ci_green="$7"
    shift 7

    local B
    B=$(git -C "$base_dir" rev-parse HEAD)
    # Before 2a92ac67 the temp lived under <common>/cs/finish/, so a run killed
    # then can have left a <task>.<pid> directory there. Nothing reads that
    # path any more, and removing it would mean cs deleting inside an adopted
    # repo's .git for no change in behaviour (#838). Leave it; do not add a sweep.
    # Outside any .git directory: tools refuse to serve or read files under
    # one (Vite's server.fs.deny holds **/.git/**, so a vitest browser run in
    # the temp never connects and the gate goes red for where it ran). An
    # empty directory, which git worktree add fills.
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/cs-finish-$task.XXXXXX") \
        || error "Could not create a temporary directory for the integrate under ${TMPDIR:-/tmp}"
    # Armed as soon as the directory exists, before the add: an add that fails
    # half-way leaves a directory and a registration behind, and only a
    # _INTEGRATE_TMP the cleanup can see gets them removed. The cleanup
    # removes a directory that never became a worktree and prunes either way.
    _INTEGRATE_TMP="$tmp"
    # /dev/null is not a directory on BSD, so hooks are silenced with a real
    # empty one.
    local no_hooks
    no_hooks=$(mktemp -d "${TMPDIR:-/tmp}/cs-nohooks.XXXXXX")
    if ! git -C "$base_dir" -c core.hooksPath="$no_hooks" worktree add --detach "$tmp" "$B" >/dev/null 2>&1; then
        rmdir "$no_hooks"
        error "git worktree add failed for $tmp"
    fi

    local mode
    mode=$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)
    if [ "$mode" = "tracked" ]; then
        _setup_merge_attributes_clone_local "$base_dir" "$common"
        _warn_memory_index_changed "$base_dir" "$sha"
    fi

    # --no-ff locally: the merge commit names the feature and is the audit
    # trail /finish leaves, and it gives the retire verb's ancestor check
    # something to find. --from-remote: the landing commit already exists on
    # origin and names the PR, so a fast-forward is the right shape there.
    local sha7 merge_status=0
    sha7=$(printf '%s' "$sha" | cut -c1-7)
    _finish_progress_write merging
    if [ -n "$from_remote" ]; then
        git -C "$tmp" -c core.hooksPath="$no_hooks" merge --no-edit "$sha" >/dev/null 2>&1 || merge_status=$?
    else
        git -C "$tmp" -c core.hooksPath="$no_hooks" merge --no-ff --no-edit \
            -m "Merge feature $task ($sha7)" "$sha" >/dev/null 2>&1 || merge_status=$?
    fi
    # The merge commit this integrate will land, read before the gate runs.
    # Everything after the gate is measured against it: what lands is this
    # commit, never whatever the temp holds when the gate is done.
    # merge=ours kept the base's MEMORY.md; a pointer to a topic only the
    # feature indexed is appended and folded into the merge commit, so it
    # lands with it. A --from-remote landing is origin's commit, left as is.
    if [ "$merge_status" = 0 ] && [ "$mode" = "tracked" ] && [ -z "$from_remote" ] \
        && git -C "$tmp" cat-file -e "$sha:.cs/memory/MEMORY.md" 2>/dev/null; then
        local feature_index added
        feature_index=$(mktemp "${TMPDIR:-/tmp}/cs-memory-index.XXXXXX")
        if ! git -C "$tmp" show "$sha:.cs/memory/MEMORY.md" > "$feature_index" \
            || ! added=$(_append_missing_memory_pointers "$feature_index" "$tmp/.cs/memory/MEMORY.md"); then
            rm -f "$feature_index"; rmdir "$no_hooks"
            error "Could not carry the feature's MEMORY.md pointers into the merge in $tmp; base untouched"
        fi
        rm -f "$feature_index"
        if [ "$added" != 0 ]; then
            git -C "$tmp" add -- .cs/memory/MEMORY.md \
                && git -C "$tmp" -c core.hooksPath="$no_hooks" commit -q --amend --no-edit >/dev/null \
                || { rmdir "$no_hooks"; error "Could not commit the feature's MEMORY.md pointers in $tmp; base untouched"; }
            info "MEMORY.md: appended $added pointer(s) from the feature (base lines kept)"
        fi
    fi
    local M=""
    [ "$merge_status" = 0 ] && M=$(git -C "$tmp" rev-parse HEAD)
    if [ "$merge_status" != 0 ]; then
        rmdir "$no_hooks"
        local conflicts base_branch advice
        conflicts=$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null || true)
        base_branch=$(git -C "$base_dir" symbolic-ref -q --short HEAD 2>/dev/null || echo HEAD)
        if [ -n "$from_remote" ]; then
            # Nothing of the feature's is in this conflict: it is the base's
            # own commits against what origin carries, so the feature worktree
            # is the wrong place to fix it.
            advice="Resolve it in the base (git -C \"$base_dir\" merge origin/$base_branch): the conflict is between $base_dir's local commits and origin's $base_branch, not with the feature. Then re-run /finish $task"
        else
            advice="Resolve on the feature branch (git merge $base_branch in $wt_dir), then re-run /finish $task"
        fi
        error "Merge of $sha conflicts with $base_dir at $B; base untouched. Conflicting paths:
${conflicts:-(none reported; see git -C \"$tmp\" status)}
$advice"
    fi
    # An untracked file in the base colliding with a path the merge touches
    # passes _tree_is_dirty (tracked-only) and the temp merge itself, then
    # aborts the ff-only landing with a message that blames the wrong cause.
    # Caught here, before the gate spends any cost on a doomed landing.
    local touched_file others_file collisions
    touched_file=$(mktemp "${TMPDIR:-/tmp}/cs-touched.XXXXXX")
    others_file=$(mktemp "${TMPDIR:-/tmp}/cs-untracked.XXXXXX")
    git -C "$tmp" diff --name-only "$B" HEAD > "$touched_file"
    git -C "$base_dir" ls-files --others --exclude-standard > "$others_file"
    collisions=""
    if [ -s "$touched_file" ] && [ -s "$others_file" ]; then
        collisions=$(grep -Fxf "$touched_file" "$others_file" 2>/dev/null || true)
    fi
    rm -f "$touched_file" "$others_file"
    if [ -n "$collisions" ]; then
        rmdir "$no_hooks"
        error "Untracked files in $base_dir collide with paths the feature adds; base untouched. Colliding paths:
$collisions
Move or delete these untracked files in $base_dir, then re-run /finish $task"
    fi
    # Submodules after the merge, so the gates see the MERGED gitlinks: a
    # feature that adds or bumps a submodule is otherwise gated against
    # absent or stale contents.
    if [ -f "$tmp/.gitmodules" ]; then
        git -C "$tmp" -c core.hooksPath="$no_hooks" submodule update --init --recursive -q >/dev/null 2>&1 \
            || { rmdir "$no_hooks"; error "submodule update failed in $tmp"; }
    fi
    rmdir "$no_hooks"

    # A remote landing whose base has nothing origin lacks fast-forwards onto
    # the PR's landing commit; the temp holds exactly that tree. When the
    # caller vouches (--ci-green) that origin's checks passed on that very
    # commit, a local gate would only repeat them in a checkout without the
    # project's gitignored dependencies, so skip it and say so. A base carrying
    # its own commits makes a merge those checks never saw, and then the gate
    # runs.
    local gate_skipped="" B7
    B7=$(printf '%s' "$B" | cut -c1-7)
    if [ -n "$from_remote" ] && [ -n "$ci_green" ] \
        && git -C "$base_dir" merge-base --is-ancestor "$B" "$sha" 2>/dev/null; then
        gate_skipped=1
        echo "gate skipped: $base_dir at $B7 fast-forwards onto $sha7, whose checks passed on origin; nothing local to test"
    fi
    if [ -z "$gate_skipped" ]; then
        # `-- true` is how the caller says there is no gate: nothing worth a
        # band runs, so only a real gate is a step of the record.
        if [ $# -ne 1 ] || [ "$1" != true ]; then
            _FINISH_GATE_STARTED=$(date +%s)
            _finish_progress_write gate
        fi
        # A global, so _integrate_cleanup removes it when the run is
        # terminated mid-gate.
        _INTEGRATE_GATE_LOG=$(mktemp "${TMPDIR:-/tmp}/cs-gate.XXXXXX")
        # </dev/null: a gate that reads stdin would otherwise consume whatever
        # cs was given and block a non-interactive run forever.
        if ! (cd "$tmp" && "$@") > "$_INTEGRATE_GATE_LOG" 2>&1 < /dev/null; then
            cat "$_INTEGRATE_GATE_LOG" >&2
            rm -f "$_INTEGRATE_GATE_LOG"
            _INTEGRATE_GATE_LOG=""
            error "Gate failed in $tmp (output above); base $base_dir untouched at $B
The gate ran in a clean checkout of the merged commit: gitignored files (installed dependencies, .env, build output) are not there. A gate that needs them must create them first, e.g. -- sh -c 'npm ci && npm test'"
        fi
        rm -f "$_INTEGRATE_GATE_LOG"
        _INTEGRATE_GATE_LOG=""
    fi

    # A green gate that changed the temp is still a refusal. What lands is M,
    # so a file the gate wrote is either dropped on the floor or — once the
    # gate commits it — rides into the base unreviewed. Generated output
    # belongs on the feature branch, committed by the person who ran the build.
    local gate_head gate_dirt tampered
    gate_head=$(git -C "$tmp" rev-parse HEAD 2>/dev/null || echo "")
    gate_dirt=$(git -C "$tmp" status --porcelain --untracked-files=no 2>/dev/null || true)
    tampered=""
    if [ -n "$gate_dirt" ]; then
        tampered="tracked files or submodules changed:
$gate_dirt"
    fi
    if [ "$gate_head" != "$M" ]; then
        tampered="${tampered:+$tampered
}HEAD moved to ${gate_head:-(unreadable)}"
    fi
    if git -C "$tmp" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        tampered="${tampered:+$tampered
}a merge is in progress"
    fi
    if [ -n "$tampered" ]; then
        error "The gate changed the temp checkout; base $base_dir untouched at $B. What the gate changed:
$tampered
Commit the generated output on the feature branch, then re-run /finish $task"
    fi

    # Re-verify the base immediately before landing. --ff-only alone is not
    # the "base unchanged" check: a base reset to an ancestor of B still
    # fast-forwards, and unrelated tracked dirt survives one. The residual
    # window between this check and the merge is the one race left; the
    # mutex keeps cs's own writer (the autosave hook) out of it.
    if [ "$(git -C "$base_dir" rev-parse HEAD)" != "$B" ]; then
        error "Base $base_dir moved during the gates (was $B, now $(git -C "$base_dir" rev-parse --short HEAD)); re-run /finish $task"
    fi
    if _tree_is_dirty "$base_dir" || git -C "$base_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        error "Base $base_dir changed during the gates (uncommitted changes or a merge in progress); commit or abort, then re-run /finish $task"
    fi
    # Fast-forward BEFORE removing the temp: until then the merge commit is
    # reachable only from the temp's detached HEAD.
    local R ff_err ff_status=0
    R="$M"
    _finish_progress_write fast-forward
    ff_err=$(git -C "$base_dir" merge --ff-only "$R" 2>&1 >/dev/null) || ff_status=$?
    if [ "$ff_status" != 0 ]; then
        error "Base $base_dir moved or changed during the gates (was $B); re-run /finish $task
${ff_err:-(no output from git merge --ff-only)}"
    fi
    # The base's landing is the one merge that runs with the project's hooks
    # live — it is the user's checkout, and a post-merge hook is entitled to
    # fire there. One that commits leaves base past the commit cs landed, so
    # read HEAD back and report where the base actually is.
    local landed
    landed=$(git -C "$base_dir" rev-parse HEAD)
    if [ "$landed" != "$R" ]; then
        warn "A post-merge hook moved $base_dir to $landed after landing $R"
    fi
    # Keep _INTEGRATE_TMP until the removal is verified, so the EXIT cleanup
    # still has the path if this removal fails; a leftover temp is reported,
    # never silently forgotten.
    if git -C "$base_dir" worktree remove --force "$tmp" >/dev/null 2>&1; then
        _INTEGRATE_TMP=""
    else
        warn "Temporary worktree $tmp could not be removed; run: git -C \"$base_dir\" worktree remove --force \"$tmp\""
    fi

    # The feature's tree has landed in the base, and nothing has scanned it
    # since the base opened: a link the feature committed here is refused
    # by the append, never written through.
    _append_record "$base_dir/.cs/timeline.jsonl" \
           --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "feature-integrated" \
           --arg task "$task" \
           --arg sha "$sha" \
           --arg result "$landed" \
        '{ts: $ts, event: $event, task: $task, sha: $sha, result: $result}'
    _finish_progress_write landed result "$landed"
    printf 'integrated %s %s -> %s\n' "$task" "$sha" "$landed"
}

# Append one JSONL file onto another, keeping every record on its own line. A
# process killed mid-write leaves a last line with no newline; a bare `cat >>`
# then splices two records into one, and the tolerant per-line reader
# (`fromjson? // empty` in run_conversations) drops BOTH the splice and the
# record that followed it. Terminating on either side costs one byte and keeps
# the loss at zero. Fails, appending nothing, when a link takes <dst> out of
# its session.
_append_jsonl() {  # src dst
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    _terminate_jsonl "$dst"
    cs_append_inside "$dst" cat "$src" || return 1
    _terminate_jsonl "$dst"
}

# A log fused onto another starts on a line of its own.
_blank_line_then_cat() {  # file
    echo ""
    cat "$1"
}

# Append to the base's memory index each "- [title](target)" pointer of the
# feature's index whose target the base index does not name, once per target,
# and print how many were appended. The base's own lines stay as they are (a
# pointer both sides reworded keeps the base wording); only a pointer to a
# topic the base has never indexed is added, so it is not lost at /finish.
# A pointer whose topic file is not beside the base index is left out: the
# base deleted that topic after the feature branched, and the deletion stands.
# Fails, appending nothing, when a link takes the base index out of its
# session: a feature can commit MEMORY.md as a link, and a merge installs it.
_append_missing_memory_pointers() {  # feature_index base_index
    local src="$1" dst="$2" have="$2" missing
    [ -f "$src" ] || { printf '0'; return 0; }
    [ -f "$dst" ] || have=/dev/null
    # Bytes, not characters: the index is UTF-8 in any locale, and awk stops
    # on a line a multibyte locale cannot decode.
    missing=$(LC_ALL=C awk '
        function target(s) {
            if (s !~ /^- \[/ || !match(s, /]\([^)]*\)/)) return ""
            return substr(s, RSTART + 2, RLENGTH - 3)
        }
        FILENAME == ARGV[1] { t = target($0); if (t != "") seen[t] = 1; next }
        { t = target($0); if (t == "" || (t in seen)) next; seen[t] = 1; print t "\t" $0 }
    ' "$have" "$src") || return 1
    local entry kept="" tab="	"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        [ -f "${dst%/*}/${entry%%"$tab"*}" ] || continue
        kept="$kept${entry#*"$tab"}"$'\n'
    done <<< "$missing"
    missing=$(printf '%s' "$kept")
    [ -n "$missing" ] || { printf '0'; return 0; }
    _terminate_jsonl "$dst"
    cs_append_inside "$dst" printf '%s\n' "$missing" || return 1
    printf '%s' "$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
}

# Says how a feature's topic relates to the copy it started with: "unchanged"
# or "edited" for a topic the create recorded as inherited, nothing for one
# the feature wrote itself (or one a create with no record handed over).
# Fails when the record is there and cannot be read (the directory or the
# topic's file), or the topic cannot be summed: answering "the feature wrote it" then would bring a deleted topic
# back and call the fuse a success.
_inherited_topic_state() {  # feature_meta topic_file
    local dir="$1/local/inherited-topics" record was now
    record="$dir/${2##*/}"
    [ -e "$dir" ] || [ -L "$dir" ] || return 0
    [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 1
    [ -e "$record" ] || [ -L "$record" ] || return 0
    was=$(cat "$record") || return 1
    now=$(cksum < "$2") || return 1
    if [ "$now" = "$was" ]; then echo unchanged; else echo edited; fi
}

# Fuse session records from a worktree .cs into the base .cs (ignored mode:
# the repo does not track .cs/, so git merge cannot carry these). Applies the
# same semantics the merge drivers give tracked repos: union append for
# timeline/log/narratives, copy-never-overwrite for memory topic files,
# base-wins for MEMORY.md plus the feature's pointers to targets it lacks. Every write returns 1 on failure: the caller runs
# this in a subshell on the left of ||, where errexit is off, and deletes the
# staged records only on success. Every write also goes through the link
# check: the landing put the feature's tree in the base, and nothing has
# scanned the base since. A write that fails leaves the earlier ones in the
# base, so the staged records can repeat some the base already holds; the
# caller's error says to fuse what is missing. No pass checks every
# destination before the first write: a full disk leaves the same state, and
# that pass would have to list the destinations a second time.
fuse_session_records() {
    local src="$1" dst="$2"
    local f base inherited

    # Worktrees never run migrate_session, so a task branch created before the
    # log moved to .cs/local/ still keeps its audit trail at .cs/logs/; fuse
    # whichever the worktree has into the base's machine-local log.
    # An encrypted base keeps its log behind .cs/private; a locked one cannot
    # take the log, and .cs/local must not take it in plaintext instead.
    # Resolved before any write, so that refusal leaves the base untouched.
    local candidate srclog="" dstlog=""
    for candidate in "$src/local/session.log" "$src/logs/session.log"; do
        if [ -f "$candidate" ]; then
            srclog="$candidate"
            dstlog=$(cs_private_dir "$dst") \
                || error "cannot fuse the worktree's log: $dst/private is locked. Mount it, then retry."
            break
        fi
    done

    _append_jsonl "$src/timeline.jsonl" "$dst/timeline.jsonl" || return 1
    if [ -n "$srclog" ]; then
        cs_mkdir_inside "$dstlog" || return 1
        cs_append_inside "$dstlog/session.log" _blank_line_then_cat "$srclog" || return 1
    fi

    cs_mkdir_inside "$dst/memory" || return 1
    for f in "$src"/memory/narrative.*.md; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        if [ -f "$dst/memory/$base" ]; then
            # Append the body past the closing --- of the YAML frontmatter.
            # A file not opening with --- has no frontmatter (whole file is
            # body); counting stops at 2 so a --- horizontal rule in the
            # body stays body instead of truncating the append.
            # Bytes, not characters (LC_ALL=C): the records are UTF-8 in any
            # locale, and awk stops on one a multibyte locale cannot decode.
            cs_append_inside "$dst/memory/$base" \
                env LC_ALL=C awk 'NR==1 && $0 != "---" {c=2} /^---$/ && c < 2 {c++; next} c >= 2 {print}' "$f" || return 1
        else
            cs_write_atomic "$dst/memory/$base" cat "$f" || return 1
        fi
    done

    for f in "$src"/memory/*.md; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            MEMORY.md) continue ;;
            narrative.*.md) continue ;;
        esac
        if [ -f "$dst/memory/$base" ]; then
            # The feature started from a copy of the base's topics, so an
            # unchanged one is the base's own file, not a collision.
            cmp -s "$f" "$dst/memory/$base" \
                || warn "memory/$base already exists in the base; skipped"
        else
            # A topic the feature inherited and the base no longer has was
            # deleted in the base. Untouched, it stays deleted; edited, the
            # feature's text comes back and the user is told.
            if ! inherited=$(_inherited_topic_state "$src" "$f"); then
                warn "could not read what the feature inherited for memory/$base, so cs cannot tell whether the base deleted it"
                return 1
            fi
            [ "$inherited" != unchanged ] || continue
            cs_write_atomic "$dst/memory/$base" cat "$f" || return 1
            [ "$inherited" != edited ] \
                || warn "memory/$base was deleted in the base and edited in the feature; the feature's version is back in the base"
        fi
    done

    local added
    added=$(_append_missing_memory_pointers "$src/memory/MEMORY.md" "$dst/memory/MEMORY.md") || return 1
    [ "$added" = 0 ] || info "MEMORY.md: appended $added pointer(s) from the feature (base lines kept)"
}

# List a base session's feature worktrees with their merge readiness. Read
# only: this is a query, not a gate, so it exits 0 even when nothing can merge.
run_features() {  # base_name [--porcelain]
    local base_name="$1"
    shift
    local porcelain=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --porcelain) porcelain=1; shift ;;
            *) error "Usage: cs $base_name -features [--porcelain]" ;;
        esac
    done

    local features task record
    features=$(_worktree_features "$base_name")
    [ -n "$features" ] || return 0

    if [ -n "$porcelain" ]; then
        while IFS= read -r task; do
            [ -n "$task" ] || continue
            _feature_readiness "$base_name" "$task"
        done <<< "$features"
        return 0
    fi

    printf '%-24s %-24s %6s  %s\n' "FEATURE" "BRANCH" "AHEAD" "STATE"
    while IFS= read -r task; do
        [ -n "$task" ] || continue
        record=$(_feature_readiness "$base_name" "$task")
        printf '%s\n' "$record" | awk -F'\t' \
            '{ detail = ($10 == "untracked") ? sprintf("%s file%s untracked", $7, ($7 == 1) ? "" : "s") : $10;
               printf "%-24s %-24s %6s  %s\n", $1, $2, $3, detail }'
    done <<< "$features"
}

# Ensure auto memory directory exists and migrate from default location
