# ABOUTME: Actor identity, narrative budget, private-dir, tmux window-title, atomic file rewrite, state-file
# ABOUTME: lock and settings.json rewrite code that cs AND its hooks run. build.sh folds this into bin/cs and copies it to hooks/cs-shared.sh.

# Normalize an arbitrary identity string to a filesystem-safe slug.
_slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-*$//'
}

# The raw identity driving a session, before slugging. Args: the session root
# (where git config is read) and its meta dir (where the pinned identity lives);
# either may be empty. Precedence: $CS_ACTOR > <meta>/local/identity > git
# user.email > git user.name > "unknown". if/elif/else, not three independent
# tests: a pinned identity file ends the search by EXISTING, so a blank pin
# resolves to "unknown" rather than falling through to git.
cs_actor_raw() {  # session_dir, meta_dir
    local sdir="${1:-}" meta="${2:-}" raw=""
    if [ -n "${CS_ACTOR:-}" ]; then
        raw="$CS_ACTOR"
    elif [ -n "$meta" ] && [ -f "$meta/local/identity" ]; then
        IFS= read -r raw < "$meta/local/identity" || true
    else
        local gitdir="${sdir:-.}"
        raw=$(git -C "$gitdir" config user.email 2>/dev/null || true)
        [ -z "$raw" ] && raw=$(git -C "$gitdir" config user.name 2>/dev/null || true)
    fi
    [ -z "$raw" ] && raw="unknown"
    printf '%s\n' "$raw"
}

# Resolve the current actor as a slug. With a session_dir arg, resolve the
# pinned identity and git config from that dir (callers may run before
# CLAUDE_SESSION_META_DIR is exported). Without, use env + cwd.
cs_actor_slug() {
    local sdir="${1:-}" meta=""
    if [ -n "$sdir" ]; then
        meta="$sdir/.cs"
    else
        meta="${CLAUDE_SESSION_META_DIR:-}"
    fi
    _slugify "$(cs_actor_raw "$sdir" "$meta")"
}

# 224 KiB budget, 112 KiB tail. The ceiling is the Read tool's: it refuses a
# file over 256 KiB, and the resume reads the live narrative in one call, so a
# file past that size cannot be read in full at all. The budget sits under the
# ceiling with room for the appends made while the over-budget warning is on
# screen and before anyone rotates. The tail is what a resume actually costs;
# sections run about 2 KB and an active day produces 60-odd of them, so 112 KiB
# is most of a day. The 2:1 ratio keeps rotation infrequent: a full tail's
# worth must accumulate again before the next one.
CS_NARRATIVE_MAX_DEFAULT=229376
CS_NARRATIVE_KEEP_DEFAULT=114688

# A positive integer override, else the default. Empty, non-numeric and zero
# in any spelling (0, 00) all fall back: a zero budget would rotate on every
# run. The zero check runs on the number, not the text, and the number is
# decimal: a leading zero would reach the callers' arithmetic as an octal
# literal, and `08` aborts it. Sixteen digits or more fall back too: bash
# arithmetic wraps past 64 bits, and a wrapped budget is a silent wrong one.
_narrative_budget() {  # value, default
    local n
    case "${1:-}" in ''|*[!0-9]*|????????????????*) echo "$2"; return;; esac
    n=$((10#$1))
    if [ "$n" -gt 0 ]; then echo "$n"; else echo "$2"; fi
}

# The four names under .cs/ that an encrypted session links into its vault;
# see docs/session-layout.md "Encrypted sessions".
# shellcheck disable=SC2034  # read by cs and by the hooks that source this file
CS_VAULT_LINKS="memory plans claude-config private"

# The directory holding a session's cs content files (command log, mail,
# traces). An encrypted session links .cs/private into its vault; any other
# keeps them in .cs/local. Fails, printing nothing, when .cs/private is a link
# whose vault is locked: a writer drops its line rather than write it anywhere
# else in plaintext.
cs_private_dir() {  # meta_dir
    if [ -L "$1/private" ] || [ -e "$1/private" ]; then
        [ -d "$1/private" ] || return 1
        printf '%s\n' "$1/private"
    else
        printf '%s\n' "$1/local"
    fi
}

# Says what an unusable .cs/private is, for an error message: the vault it
# points at, or that it is not a directory at all.
cs_private_state() {  # meta_dir
    if [ -L "$1/private" ]; then
        printf 'points at %s\n' "$(readlink "$1/private")"
    else
        printf 'is not a directory\n'
    fi
}

# The rotation handoff store: .cs/private/handoffs in an encrypted session,
# .cs/handoffs in every other. Fails, like cs_private_dir, while .cs/private
# dangles: a locked vault has no handoffs to offer or consume.
cs_handoff_dir() {  # meta_dir
    if [ -L "$1/private" ] || [ -e "$1/private" ]; then
        [ -d "$1/private" ] || return 1
        printf '%s\n' "$1/private/handoffs"
    else
        printf '%s\n' "$1/handoffs"
    fi
}

# Names a tmux window after every cs session running in its panes: "cs: a | b",
# in pane order, each name once. Under iTerm's tmux integration the window name
# is the tab's title, and one window holds every pane of a tab, so a single
# session writing its own name took the tab from the other. Each pane records
# its session in the pane option @cs_session; an empty name releases the pane.
# A named window is locked against Claude Code's own titles, as the launch
# locks it: a /clear releases the window and claims it back, and the claim must
# lock it again. With no cs session left it names itself again. Every tmux call
# is best-effort: a title must never fail a launch or a hook. The claim, the
# read of every claim and the rename run under the window's lock, since panes
# claim at the same moment (a layout restore, two /clears) and a rename written
# from a read before another pane's claim would drop that pane's name.
cs_tmux_title_window() {  # pane, session name ("" releases the pane)
    local pane="$1" name="$2" names lock
    [ -n "$pane" ] || return 0
    lock=$(_cs_tmux_title_lock_path "$pane")
    [ -z "$lock" ] || _cs_lock "$lock" || lock=""
    if [ -n "$name" ]; then
        tmux set-option -p -t "$pane" @cs_session "$name" 2>/dev/null || true
    else
        tmux set-option -p -u -t "$pane" @cs_session 2>/dev/null || true
    fi
    names=$(tmux list-panes -t "$pane" -F '#{@cs_session}' 2>/dev/null \
        | awk 'NF && !seen[$0]++ { out = out (out == "" ? "" : " | ") $0 } END { print out }') || names=""
    if [ -n "$names" ]; then
        tmux rename-window -t "$pane" "cs: $names" 2>/dev/null || true
        tmux set-window-option -t "$pane" allow-rename off 2>/dev/null || true
        tmux set-window-option -t "$pane" allow-set-title off 2>/dev/null || true
    else
        tmux set-window-option -t "$pane" automatic-rename on 2>/dev/null || true
        tmux set-window-option -t "$pane" allow-rename on 2>/dev/null || true
        tmux set-window-option -t "$pane" allow-set-title on 2>/dev/null || true
    fi
    _cs_unlock "$lock"
    _cs_iterm_tab_title "$pane"
}

# Under iTerm's tmux integration the tab shows a title iTerm keeps for itself:
# tmux window renames never reach it, and only iTerm's Python API sets it.
# Hands the window to cs-iterm-tab.py in the background, after the lock is
# released, since the helper takes about a second and reads the claims itself
# when it runs. Its output is discarded and nothing waits on it, so a machine
# without iTerm's API or the iterm2 python module goes without the tab title
# and nothing else.
_cs_iterm_tab_title() {  # pane
    local helper window
    [ "${LC_TERMINAL:-}" = iTerm2 ] && [ -z "${CS_NO_ITERM2:-}" ] || return 0
    helper="${CS_HOOKS_DIR:-$HOME/.claude/hooks/cs}/cs-iterm-tab.py"
    [ -f "$helper" ] && command -v python3 >/dev/null 2>&1 || return 0
    window=$(tmux display-message -p -t "$1" '#{window_id}' 2>/dev/null) || return 0
    ( python3 "$helper" "$window" </dev/null >/dev/null 2>&1 & )
}

# Prints the lock file of a pane's window, one per tmux server and window
# under $TMPDIR, which cs_tmux_title_window takes through _cs_lock in its own
# process. A call is a few tmux round trips (385 ms measured on a loaded
# machine, so six panes queue for two seconds), and past the wait the title
# is written without the lock, as a title must never stall a hook. Prints
# nothing when tmux cannot name the window.
_cs_tmux_title_lock_path() {  # pane
    local key
    key=$(tmux display-message -p -t "$1" '#{socket_path}#{window_id}' 2>/dev/null) || key=""
    [ -n "$key" ] || return 0
    printf '%s\n' "${TMPDIR:-/tmp}/cs-title-$(printf '%s' "$key" | tr -c 'A-Za-z0-9@_.-' '_').mutex.lock"
}

# The one lock cs and its hooks take wherever two processes may write the
# same thing at once (a window title, the state file, settings.json): flock(2)
# on a lock file. The kernel ties the lock to the open file and drops it when
# the last descriptor on that file closes, so a holder that dies, however it
# dies, has released it, and no process ever judges another one dead. Bash
# 3.2 has no flock, so bash opens the file on fd 9 and a short perl process
# locks the descriptor it inherits; the lock stays with bash's descriptor
# once perl exits. That shape sets the contract:
# - fd 9 is the lock's, so a process holds one lock at a time. A second take
#   while one is held is refused: opening fd 9 again would drop the first.
# - A lock taken inside $(...) or ( ) belongs to that subshell and is gone
#   when it exits, so the process that does the work takes the lock.
# - A child started while holding inherits fd 9. Release unlocks the open
#   file itself before closing fd 9, so a child still running cannot keep the
#   lock past the release; a holder killed outright keeps it until every
#   child that inherited fd 9 has exited.
# - The path must be a regular file, or absent, when it is created. A
#   directory, symlink, fifo or anything else is refused at once with a line
#   on stderr, and a link is never followed: bash opens the file itself (a
#   descriptor perl opened would close when perl exits), so a link is refused
#   before the open, and perl then checks that the path names the very
#   regular file fd 9 has open. Only a link swapped in between those two
#   steps, by a live process of the same user, is followed, and the lock is
#   then refused.
# - The file is never removed: a removed lock file lets the next taker lock a
#   fresh file while a waiter locks the removed one. A waiter that finds the
#   path naming another file once it holds the lock lets it go and takes the
#   lock on the file the path names.
# - A directory that is missing, or cannot take a new file, refuses at once.
# - A live holder is waited for, but for no more than five seconds: past that
#   the caller goes ahead without the lock or gives up, as it chooses, since a
#   launch or a hook must never stall on a lock a stray process holds.
# - Without perl nothing is locked, and a line on stderr says so.
# Returns 0 holding the lock, 1 holding nothing.
_cs_lock() {  # lock file
    local lock="$1" rc
    if [ -n "${_CS_LOCK_HELD:-}" ]; then
        echo "cs: cannot lock $lock: this process already holds $_CS_LOCK_HELD" >&2
        return 1
    fi
    if ! command -v perl >/dev/null 2>&1; then
        echo "cs: cannot lock $lock: perl not found" >&2
        return 1
    fi
    for _ in 1 2 3; do
        if [ -L "$lock" ] || { [ -e "$lock" ] && [ ! -f "$lock" ]; }; then
            echo "cs: cannot lock $lock: not a regular file" >&2
            return 1
        fi
        { exec 9<>"$lock"; } 2>/dev/null || return 1
        rc=0
        perl -e "$_CS_LOCK_PERL" "$lock" || rc=$?
        case "$rc" in
            0)
                _CS_LOCK_HELD="$lock"
                _CS_LOCK_SUBSHELL=$BASH_SUBSHELL
                return 0
                ;;
            2)
                exec 9<&-
                echo "cs: cannot lock $lock: not a regular file" >&2
                return 1
                ;;
            3) exec 9<&- ;;
            *)
                exec 9<&-
                return 1
                ;;
        esac
    done
    return 1
}

# _cs_lock's perl, run on the lock file with bash's fd 9 open on it. Exits 0
# holding the lock; 1 after five seconds of a live holder; 2 when the path is
# not the regular file fd 9 has open (a link, or another type); 3 when the
# path names another regular file than fd 9 has, so the caller opens that one.
_CS_LOCK_PERL='
use Fcntl qw(:flock);
open(my $fd, "+<&=", 9) or exit 1;
my @held = stat($fd);
exit 2 unless @held && -f _;
sub path_names_held {
    my @path = lstat($ARGV[0]);
    return @path && -f _ && $path[0] == $held[0] && $path[1] == $held[1];
}
my @path = lstat($ARGV[0]);
exit 2 unless @path && -f _;
exit 3 unless path_names_held();
for my $poll (0 .. 100) {
    if (flock($fd, LOCK_EX | LOCK_NB)) {
        exit 0 if path_names_held();
        flock($fd, LOCK_UN);
        exit 3;
    }
    select(undef, undef, undef, 0.05) if $poll < 100;
}
exit 1;
'

# Release the lock this process holds on <lock file>. Any other path, an
# empty one, or a lock the parent took, seen from a subshell, is left alone.
_cs_unlock() {  # lock file ("" when none was held)
    [ -n "$1" ] && [ "$1" = "${_CS_LOCK_HELD:-}" ] && [ "${_CS_LOCK_SUBSHELL:-}" = "$BASH_SUBSHELL" ] || return 0
    perl -e 'use Fcntl qw(:flock); open(my $fd, "+<&=", 9) or exit 1; flock($fd, LOCK_UN) or exit 1' \
        || echo "cs: could not unlock $1; closing it instead" >&2
    exec 9<&-
    _CS_LOCK_HELD=""
}

# Octal permission bits of a file, as chmod takes them (644), read through a
# symlink so a linked destination reports its target's mode, not the link's
# 755. GNU stat is tried first: BSD stat rejects -c with no output, while GNU
# stat given -f reads it as "file system" and prints something, so the order
# matters and OSTYPE is no guide (Homebrew's gnubin puts GNU stat on a Mac).
_cs_file_mode() {  # path
    stat -L -c %a "$1" 2>/dev/null || stat -L -f %Lp "$1"
}

# Replace a file with a command's stdout, atomically: the output goes to a
# uniquely named temp file in the same directory, which is renamed over the
# destination only once the command has succeeded. The temp file's name starts
# with .cs-tmp., the prefix a session's .gitignore names, so one left by a
# killed writer never reaches an autosave snapshot. A symlinked destination is
# followed to its target, so a shared or linked file is rewritten in place and
# the link survives; inside a session (CLAUDE_SESSION_DIR) a destination under
# it whose links lead out of it is refused instead (_cs_write_leaves_session),
# since a clone can commit `.cs/README.md -> ~/.zshrc`. The destination keeps the
# permission bits it had, and a new file gets the umask's; the temp file takes
# them BEFORE the rename, so a shared directory never sees a 0600 window. A
# failed command, chmod or rename leaves the destination as it was, the temp
# file removed, and returns the failing status. Callers that want a message
# add it: hooks source this file, and `error` is cs's alone.
# Usage: cs_write_atomic <dest> <command> [args...]
# Where a write to a path lands: its symlinks followed, 16 hops as
# cs_write_atomic follows them, and its directory resolved physically, so a
# linked parent counts too. Fails when that directory does not exist, and
# with status 2 when the path is still a link after 16 hops: the kernel
# follows more, so where such a write lands is unknown here.
_cs_write_target() {  # path
    local dest="$1" link dir hops=0
    while [ -L "$dest" ] && [ "$hops" -lt 16 ]; do
        link=$(readlink "$dest") || return 1
        case "$link" in
            /*) dest="$link" ;;
            *) dest="$(dirname "$dest")/$link" ;;
        esac
        hops=$((hops + 1))
    done
    [ ! -L "$dest" ] || return 2
    # cd -P walks each component as the filesystem does: a logical cd would
    # collapse `link/..` to the link's own parent, not the target's.
    dir=$(cd -P "$(dirname "$dest")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "${dir%/}" "$(basename "$dest")"
}

# True when .cs at <root> is a submodule or nested repository, whose files
# the session's index never lists (Codex r2 #4). The gitlink outlives a
# removed .cs/.git, so the index is checked as well; the pathspec also lists
# entries below .cs, so only a gitlink whose whole path is .cs counts.
_cs_nested_cs() {  # root
    [ -e "$1/.cs/.git" ] && return 0
    git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || return 1
    git -C "$1" ls-files -s -- ':(icase).cs' 2>/dev/null \
        | awk -F'\t' '{ split($1, m, " "); if (m[1] == "160000" && tolower($2) == ".cs") hit = 1 } END { exit !hit }' 2>/dev/null
}

# True when the session at <root> has a vault the user set up by hand: a
# .cs/local/pre-open the open would run. A clone can commit one or link one
# in, so it counts only as a real file under a real .cs/local, untracked (the
# same rules cs_assert_local_untracked enforces at open; a standalone command
# like cs <name> -queue never ran that check).
_cs_hand_made_vault() {  # root
    local pre="$1/.cs/local/pre-open"
    [ -f "$pre" ] && [ ! -L "$pre" ] && [ ! -L "$1/.cs" ] && [ ! -L "$1/.cs/local" ] || return 1
    ! _cs_nested_cs "$1" || return 1
    git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || return 0
    [ -z "$(git -C "$1" ls-files -- ':(icase).cs/local' 2>/dev/null | sed -n 1p)" ]
}

# True when a path lies in the session at <root> by its spelling (as typed,
# or under the root's physical path, the spelling an adopted session is
# written by) but a write to it lands outside the root; prints where it lands.
# Two kinds of link lead out by design and are let through:
# - an encrypted session's .cs/claude-config links settings, skills and the
#   rest to the shell's own config, and the open refuses a .cs/claude-config
#   that is not cs's link into the vault;
# - a vault set up by hand mounts anywhere, from .cs/local/pre-open, so while
#   one exists the four vault links, and a .cs/narrative-archive link (which
#   cs -narrative rotate uses as it is), may lead out. A clone cannot ship a
#   pre-open: cs_assert_local_untracked refuses one tracked or linked in.
_cs_write_leaves_session() {  # root, path
    local root="$1" root_p real sub
    root_p=$(cd "$root" 2>/dev/null && pwd -P) || return 1
    case "$2" in
        "$root"/.cs/claude-config/*|"$root_p"/.cs/claude-config/*) return 1 ;;
        "$root"/*|"$root_p"/*) ;;
        *) return 1 ;;
    esac
    if _cs_hand_made_vault "$root"; then
        for sub in $CS_VAULT_LINKS narrative-archive; do
            [ -L "$root/.cs/$sub" ] || continue
            case "$2" in
                "$root/.cs/$sub"|"$root/.cs/$sub"/*|"$root_p/.cs/$sub"|"$root_p/.cs/$sub"/*) return 1 ;;
            esac
        done
    fi
    # An unresolvable directory fails the write at mktemp, writing nothing.
    real=$(_cs_write_target "$2") || {
        [ $? -eq 2 ] || return 1
        real="a chain of more than 16 links"
    }
    case "$real/" in
        "$root_p"/*) return 1 ;;
    esac
    printf '%s\n' "$real"
}

# The session a path lies in, by its spelling: the nearest directory above it
# that holds a .cs, never climbing to the sessions root or past it. A
# directory inside a .cs is never the session, nor is one that is itself a
# link (an adopted session's entry in the sessions root aside): a link a
# clone commits there (.cs/private -> ../../other) would make a .cs it
# reaches the session the write is checked against. Found from
# the path rather than from CLAUDE_SESSION_DIR, so a write into another session
# (cs-secrets --session) or one made with the variable unset is checked against
# the session it lands in. Fails for a path in no session.
_cs_session_root_of() {  # path
    local d stop="${CS_SESSIONS_ROOT:-${HOME:-/nonexistent}/.claude-sessions}"
    case "$1" in
        /*) d="${1%/*}" ;;
        *) d="$PWD/$1"; d="${d%/*}" ;;
    esac
    while [ -n "$d" ] && [ "$d" != "$stop" ]; do
        case "$d/" in
            */.cs/*) ;;
            *) if [ -d "$d/.cs" ] && { [ ! -L "$d" ] || [ "${d%/*}" = "$stop" ]; }; then
                   printf '%s\n' "$d"
                   return 0
               fi ;;
        esac
        d="${d%/*}"
    done
    return 1
}

# The three writers below name a link out of the session on stderr whatever
# the caller wants. A hook sets CS_WRITE_QUIET=1 so that a write failing for any
# other reason (a read-only directory, a full disk) shows only in the status:
# hooks fail quietly, and their stderr reaches the user's terminal.

# The check the writers share: true, with the refusal on stderr, when a write
# to <path> would leave the session it lies in. A relative path is taken from
# the current directory, its links kept, so its spelling still says which
# session it is in. <probe> is the part of the path that exists, when that is
# less than all of it. Every write is checked afresh: a file that passed once
# can be swapped for a link before the next write.
_cs_refuses_write() {  # writer, path, [probe]
    local p="$2" e="${3:-$2}" root out
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    case "$e" in /*) ;; *) e="$PWD/$e" ;; esac
    root=$(_cs_session_root_of "$p") || return 1
    out=$(_cs_write_leaves_session "$root" "$e") || return 1
    echo "$1: $p leads to $out${p#"$e"}, outside the session $root" >&2
}

# Append a command's output to a file, unless a link takes the file out of the
# session it lies in; then name the link on stderr and append nothing.
cs_append_inside() {  # file, command [args...]
    local file="$1"; shift
    ! _cs_refuses_write cs_append_inside "$file" || return 1
    if [ -n "${CS_WRITE_QUIET:-}" ]; then
        { "$@" >> "$file"; } 2>/dev/null
    else
        "$@" >> "$file"
    fi
}

# mkdir -p, unless a link takes the directory out of the session it lies in.
# The levels mkdir -p would make do not exist yet, so the nearest one that does
# is what gets resolved: a link there carries every level made below it.
cs_mkdir_inside() {  # dir
    local dir="$1" e
    case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac
    e="$dir"
    while [ -n "$e" ] && [ ! -e "$e" ] && [ ! -L "$e" ]; do
        e="${e%/*}"
    done
    if [ -n "$e" ] && _cs_refuses_write cs_mkdir_inside "$dir" "$e"; then
        return 1
    fi
    if [ -n "${CS_WRITE_QUIET:-}" ]; then
        mkdir -p "$dir" 2>/dev/null
    else
        mkdir -p "$dir"
    fi
}

cs_write_atomic() {  # dest, command [args...]
    local dest="$1"; shift
    (
        local dir tmp mode link hops=0
        ! _cs_refuses_write cs_write_atomic "$dest" || exit 1
        [ -z "${CS_WRITE_QUIET:-}" ] || exec 2>/dev/null
        while [ -L "$dest" ] && [ "$hops" -lt 16 ]; do
            link=$(readlink "$dest") || exit 1
            case "$link" in
                /*) dest="$link" ;;
                *) dest="$(dirname "$dest")/$link" ;;
            esac
            hops=$((hops + 1))
        done
        if [ -d "$dest" ]; then
            echo "cs_write_atomic: $dest is a directory" >&2
            exit 1
        fi
        dir=$(dirname "$dest")
        tmp=$(mktemp "$dir/.cs-tmp.$(basename "$dest").XXXXXX") || exit 1
        trap 'rm -f "$tmp"' EXIT
        "$@" > "$tmp" || exit $?
        if [ -f "$dest" ]; then
            mode=$(_cs_file_mode "$dest") || exit 1
        else
            mode=$(printf '%o' $((0666 & ~0$(umask))))
        fi
        chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"
    )
}

# The machine-local state file (.cs/local/state) is rewritten whole from its
# old contents, by cs and by the SessionStart hook, so two writers can lose an
# update unless they take turns: they run their change under _cs_lock on
# <file>.mutex.lock beside the file. The vault holder list takes turns
# through it too. Once the lock's wait runs out the change runs without it,
# as a launch or a hook must not stall on it. The lock is taken and let go in
# this function's own process, never in a $(...), which would let go of it
# as the $(...) exits. Returns the command's status.
_cs_with_state_lock() {  # file, command [args...]
    local lock="$1.mutex.lock" rc=0
    shift
    _cs_lock "$lock" || lock=""
    "$@" || rc=$?
    _cs_unlock "$lock"
    return "$rc"
}

# The state file's new contents: every line but the key's, then the key's new
# line when a value is given. Three args set, two unset. A failed read or
# write fails the render, so cs_write_atomic leaves the old file in place
# instead of replacing it with a partial one.
_cs_local_state_render() {  # state, key [, value]
    if [ -f "$1" ]; then
        awk -v key="$2" 'index($0, key ":") != 1' "$1" || return 1
    fi
    if [ $# -ge 3 ]; then
        printf '%s: %s\n' "$2" "$3" || return 1
    fi
}

# Write 'key: value' into a machine-local state file, replacing any existing
# line for that key, under the state lock. Returns non-zero when the write
# failed; the file is then as it was.
cs_local_state_set() {  # state, key, value
    _cs_with_state_lock "$1" cs_write_atomic "$1" _cs_local_state_render "$1" "$2" "$3"
}

# Remove a key's line from a machine-local state file, under the state lock.
# A missing file is a no-op.
cs_local_state_unset() {  # state, key
    [ -f "$1" ] || return 0
    _cs_with_state_lock "$1" cs_write_atomic "$1" _cs_local_state_render "$1" "$2"
}

# .cs/local/vault-holders lists the pids whose life keeps an encrypted
# session's vault mounted, one per line. An add appends; a drop rewrites the
# list without one pid. Both take the lock beside the file, so a drop never
# renames its copy over a line another opener added meanwhile.
cs_vault_holder_add() {  # holders, pid
    _cs_with_state_lock "$1" _cs_append_line "$1" "$2"
}

# Append one line to a file. Its error message is dropped, its status kept.
_cs_append_line() {  # file, line
    { printf '%s\n' "$2" >> "$1"; } 2>/dev/null
}

# A missing list is a no-op. Other lines stay as they are.
cs_vault_holder_drop() {  # holders, pid
    [ -f "$1" ] || return 0
    _cs_with_state_lock "$1" cs_write_atomic "$1" awk -v pid="$2" '$0 != pid' "$1"
}

# Claude Code's settings.json holds the user's permissions, env, MCP servers
# and other tools' hooks. Whether cs can read it: a missing or zero-byte file
# can (cs creates it), anything else jq cannot parse cannot, and is never
# replaced. Returns 1 with "<file> is not valid JSON; left it unchanged and
# wrote no <file>.cs-bak.<stamp> backup: <jq's reason>" in CS_SETTINGS_ERROR
# when it cannot.
# shellcheck disable=SC2034  # CS_SETTINGS_ERROR is read by the callers in cs and install.sh
cs_settings_check() {  # file
    local reason
    CS_SETTINGS_ERROR=""
    [ -s "$1" ] || return 0
    reason=$(jq -e . 2>&1 >/dev/null < "$1") && return 0
    reason="${reason%%$'\n'*}"
    reason="${reason#jq: }"
    [ -n "$reason" ] || reason="jq found no JSON value in it, or only null or false"
    CS_SETTINGS_ERROR="$1 is not valid JSON; left it unchanged and wrote no $1.cs-bak.<stamp> backup: $reason"
    return 1
}

# Rewrite a Claude Code settings file through a command that reads its JSON on
# stdin and prints the new JSON, usually jq and a filter. Claude Code, a second
# install and cs's own verbs all rewrite the file whole, so the read, the
# command and the write happen under one _cs_lock on <file>.mutex.lock beside it, and
# a cs writer waiting on it never loses its change or another's; nothing that
# waits on a person may run inside it. Claude Code takes no such lock: against
# it the guard is that the read and the write are only the command's run time
# apart. A missing or zero-byte file reads as {}; a file cs_settings_check
# refuses, or a command whose output is not JSON, leaves the file as it was.
# When the content changes, the file as it was is first copied beside it as
# <file>.cs-bak.<UTC stamp> (.1, .2 ... numbered past the highest taken for
# that stamp, so a name pruning freed is never reused), mode
# kept, then replaced through cs_write_atomic; unchanged content writes
# nothing, so no backup either. Every changing write keeps one, and then the
# five newest backups are kept and older ones removed. Returns 0 written or
# unchanged, 1 refused with the reason in CS_SETTINGS_ERROR and the file
# untouched.
cs_settings_update() {  # file, command [args...]
    local file="$1" lock="$1.mutex.lock" rc=0
    shift
    CS_SETTINGS_ERROR=""
    if ! _cs_lock "$lock"; then
        CS_SETTINGS_ERROR="could not take the lock $lock; $file left unchanged"
        return 1
    fi
    _cs_settings_rewrite "$file" "$@" || rc=$?
    _cs_unlock "$lock"
    return "$rc"
}

# cs_settings_update's work, run while it holds the lock.
# shellcheck disable=SC2034  # CS_SETTINGS_ERROR is read by the callers in cs and install.sh
_cs_settings_rewrite() {  # file, command [args...]
    local file="$1" current="{}" updated stamp backup="" n=0 taken="" f k
    shift
    cs_settings_check "$file" || return 1
    if [ -s "$file" ]; then
        current=$(cat "$file") || {
            CS_SETTINGS_ERROR="could not read $file; left it unchanged"
            return 1
        }
    fi
    if ! updated=$(printf '%s\n' "$current" | "$@") \
        || ! printf '%s\n' "$updated" | jq -e . >/dev/null 2>&1; then
        CS_SETTINGS_ERROR="could not update $file: the change did not produce JSON; left it unchanged"
        return 1
    fi
    [ "$updated" != "$current" ] || return 0
    if [ -e "$file" ]; then
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        backup="$file.cs-bak.$stamp"
        # The next number is one past the highest this stamp has: pruning
        # removes the lowest, so filling a freed name would make the newest
        # backup sort oldest and be pruned at once.
        for f in "$backup" "$backup".*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            taken=yes
            k="${f#"$backup"}"
            k="${k#.}"
            case "$k" in
                ''|*[!0-9]*) ;;
                *) [ $((10#$k)) -gt "$n" ] && n=$((10#$k)) ;;
            esac
        done
        if [ -n "$taken" ]; then
            n=$((n + 1))
            backup="$file.cs-bak.$stamp.$n"
            while [ -e "$backup" ] || [ -L "$backup" ]; do
                n=$((n + 1))
                backup="$file.cs-bak.$stamp.$n"
            done
        fi
        cp -p "$file" "$backup" 2>/dev/null || {
            CS_SETTINGS_ERROR="could not back up $file to $backup; left it unchanged"
            return 1
        }
    fi
    cs_write_atomic "$file" printf '%s\n' "$updated" || {
        CS_SETTINGS_ERROR="could not write $file; left it unchanged"
        return 1
    }
    _cs_prune_settings_backups "$file" "$backup"
}

# Keeps five of file $1's backups, <file>.cs-bak.<UTC stamp> with an
# optional .<n>, and removes the rest: backup $2, the one this write just
# took, when given, and the newest of the others by stamp and then by n.
# $2 is kept by name, not by order, as a clock set back stamps it older than
# backups already there. A file beside it under any other name, or a link,
# is not a backup cs wrote and is left alone. A backup rm cannot remove
# stays, with rm's own message.
_cs_prune_settings_backups() {  # file, [backup just written]
    local f suffix n keep=5
    [ -z "${2:-}" ] || keep=4
    for f in "$1".cs-bak.*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        [ "$f" != "${2:-}" ] || continue
        suffix="${f#"$1".cs-bak.}"
        case "$suffix" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
                printf '%s 0 %s\n' "$suffix" "$suffix" ;;
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.*)
                n="${suffix#*Z.}"
                case "$n" in
                    ''|*[!0-9]*) ;;
                    *) printf '%s %s %s\n' "${suffix%%Z.*}Z" "$n" "$suffix" ;;
                esac
                ;;
        esac
    done | sort -k1,1 -k2,2n | awk -v keep="$keep" '{ name[NR] = $3 } END { for (i = 1; i <= NR - keep; i++) print name[i] }' \
        | while IFS= read -r suffix; do
            rm -f -- "$1.cs-bak.$suffix" || true
        done
}
