# ABOUTME: Backs 'cs -spawn': open a session in the cs-owned tmux session,
# ABOUTME: optionally staging tasks the launch path arms on open.

# Every tmux call goes through this wrapper; tests point CS_TMUX_BIN at a fake.
_tmux() {
    "${CS_TMUX_BIN:-tmux}" "$@"
}

# Single-quote encode one word for a shell command line handed to tmux.
_sq() {  # text
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Absolute path of the running cs binary (the tmux server's PATH may lack
# ~/.local/bin, so the window command must not rely on lookup).
_cs_self() {
    case "$0" in
        */*) printf '%s/%s' "$(cd "$(dirname "$0")" && pwd)" "$(basename "$0")";;
        *)   command -v -- "$0" 2>/dev/null || printf '%s' "$0";;
    esac
}

# The line in a seed that ends its task lines: every line after it is the
# spawn's brief, verbatim. The brief rides inside the seed so the pair is
# published, consumed and set aside as one file. cs -spawn refuses a task
# equal to it.
SPAWN_BRIEF_MARK='--- cs-spawn-brief ---'

# The line number of a seed's brief marker; nothing when the seed carries no
# brief. Lines 1 and 2 are the token and the spawner, never the marker.
_spawn_brief_mark_line() {  # seed
    awk -v m="$SPAWN_BRIEF_MARK" 'NR > 2 && $0 == m { print NR; exit }' "$1"
}

# The suffixes of what cs -spawn stages under $SESSIONS_ROOT/.spawn/ for a
# session name, and of what the launch sets aside when the seed ages out, one
# per line. Nothing stages or reads a .brief.md name; a session's removal still
# deletes one found there. Twin of SPAWN_STAGING_SUFFIXES in
# tui/src/session.rs; the two lists change together.
_spawn_staging_suffixes() {
    printf '%s\n' .seed .seed.stale .brief.md .brief.md.stale
}

# Delete any staged or stale seed and brief for a name. Called when the
# session is deleted: a leftover seed would block re-spawning the name and arm
# a future same-name session with dead tasks and a dead brief.
_spawn_discard_seeds() {  # name
    local suffix staged
    for suffix in $(_spawn_staging_suffixes); do
        rm -f "$SESSIONS_ROOT/.spawn/$1$suffix"
    done
    # The staging file cs -spawn leaves when killed before it published:
    # mktemp's .<name>.seed.XXXXXX. Exactly six characters follow, so a
    # session named <name>.seed never has its own staging file matched. Twin
    # of the staging match in tui/src/session.rs.
    for staged in "$SESSIONS_ROOT/.spawn/.$1.seed."??????; do
        [ -e "$staged" ] || continue
        rm -f "$staged"
    done
}

# True when the tmux session named 'cs' carries cs's ownership stamp. Only
# meaningful once has-session has confirmed exact 'cs' exists: the plain '-t cs'
# target is required because tmux 3.6a rejects '=' anchors on the options
# commands. Shared by _spawn_precheck (errors on a foreign session) and the
# doctor's spawn check (warns), so the @cs_managed contract lives in one place.
_cs_tmux_managed() {
    [ "$(_tmux show-option -t cs -v @cs_managed 2>/dev/null || true)" = "1" ]
}

# Pre-window checks that must pass BEFORE the seed is written, so a refused
# spawn never leaves a pending seed behind.
_spawn_precheck() {  # name
    local name="$1"
    command -v "${CS_TMUX_BIN:-tmux}" >/dev/null 2>&1 || error "cs -spawn needs tmux"
    if session_is_live "$SESSIONS_ROOT/$name/.cs"; then
        error "Session $name is already live"
    fi
    if _tmux has-session -t =cs 2>/dev/null; then
        _cs_tmux_managed || error "A tmux session named 'cs' exists but was not created by cs; close or rename it"
        # Best-effort tidiness check only. session_is_live above is the real
        # guard against double-launching a session; tmux automatic-rename can
        # rename a window out from under this name match, and the only cost of a
        # miss is a duplicate window name in the cs session, never a second live
        # launch. Do not add locking here for that benign case.
        if _tmux list-windows -t =cs -F '#{window_name}' 2>/dev/null | grep -Fxq "$name"; then
            error "A window named $name already exists in tmux session cs"
        fi
    fi
}

# How to reach the cs tmux session. tmux attach refuses to nest, so a caller
# already inside tmux is told to switch-client instead.
_spawn_attach_hint() {
    if [ -n "${TMUX:-}" ]; then
        printf 'tmux switch-client -t cs'
    else
        printf 'tmux attach -t cs'
    fi
}

_spawn_window() {  # name, token
    local name="$1" token="$2" cmd wid
    # The token proves to the launch that this window is the spawn's own, so
    # only it consumes the seed unasked (see the seed consumer in
    # lib/75-launch.sh). It is correlation, not a secret: anyone who can read
    # the seed can read it, and `ps` shows it for as long as the launch runs.
    # `env` rather than a VAR=value prefix, which tmux's default-shell need
    # not understand.
    cmd="env $(_sq "CS_SPAWN_TOKEN=$token") $(_sq "$(_cs_self)") $(_sq "$name")"
    # Try to create the cs session outright: tmux rejects a duplicate -s name,
    # so "already exists" and "a concurrent spawner just created it" collapse
    # into the same fallthrough to new-window.
    if wid=$(_tmux new-session -d -s cs -n "$name" -P -F '#{window_id}' "$cmd" 2>/dev/null); then
        # Plain target: tmux 3.6a rejects '=' anchors on the options commands;
        # exact 'cs' was just created by new-session, so this cannot misfire.
        _tmux set-option -t cs @cs_managed 1
        info "spawned $name in tmux session cs (window $wid). Attach: $(_spawn_attach_hint)"
        return 0
    fi
    wid=$(_tmux new-window -t =cs -n "$name" -P -F '#{window_id}' "$cmd") \
        || error "tmux new-window failed for $name"
    info "spawned $name in tmux session cs (window $wid). Attach: $(_spawn_attach_hint)"
}

run_spawn() {
    local name="" brief=""
    local usage='Usage: cs -spawn <name> [--brief <file>] [--task "..."] ...'
    local tasks
    tasks=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --task)
                [ $# -ge 2 ] || error "--task needs a value"
                shift
                local t
                t="$(_trim "$1")"
                [ -n "$t" ] || error "cs -spawn --task needs a non-empty task"
                _queue_require_single_line "$t"
                [ "$t" != "$SPAWN_BRIEF_MARK" ] \
                    || error "cs -spawn --task: '$SPAWN_BRIEF_MARK' marks where a seed's brief starts and cannot be a task"
                tasks+=("$t");;
            --brief)
                [ $# -ge 2 ] || error "--brief needs a file"
                shift
                [ -z "$brief" ] || error "cs -spawn takes one --brief"
                [ -f "$1" ] && [ -r "$1" ] || error "cs -spawn --brief: cannot read $1"
                [ -s "$1" ] || error "cs -spawn --brief: $1 is empty"
                brief="$1";;
            -*) error "Unknown option: $1. $usage";;
            *)
                [ -z "$name" ] || error "cs -spawn takes exactly one session name"
                name="$1";;
        esac
        shift
    done
    [ -n "$name" ] || error "$usage"
    if ! cs_split_worktree_name "$name"; then
        validate_session_name "$name"
    fi
    _spawn_precheck "$name"
    # The spawner is whatever the environment says. It becomes the worker's
    # report-back address and goes into its kick prompt, so it must be a
    # session name; an empty one means "no spawner" (no report-back wiring).
    local spawner="${CLAUDE_SESSION_NAME:-}"
    if [ -n "$spawner" ] && ! cs_split_worktree_name "$spawner"; then
        # validate_session_name exits on a bad name; a subshell turns that
        # into a status so the error can name where the name came from.
        ( validate_session_name "$spawner" ) >/dev/null 2>&1 \
            || error "cs -spawn: CLAUDE_SESSION_NAME is not a session name: $spawner"
    fi
    # One token per spawn, for the window command and the seed alike. The
    # launch consumes the seed unasked only when the two match.
    local token
    token=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    [ "${#token}" -eq 32 ] || error "cs -spawn: could not read 16 random bytes from /dev/urandom"
    # A brief is staged with a seed even when there are no tasks: the seed
    # carries the spawner, which the brief's report-back line needs.
    if [ "${#tasks[@]}" -gt 0 ] || [ -n "$brief" ]; then
        local sdir="$SESSIONS_ROOT/.spawn" seed staged
        seed="$sdir/$name.seed"
        [ ! -f "$seed" ] || error "A pending spawn for $name exists: $seed"
        mkdir -p "$sdir" || error "cs -spawn: cannot create $sdir"
        # The whole spawn is one file: the token, the spawner, one task per
        # line, then the brief marker and the brief verbatim. It is written
        # under a name of its own and published with ln, which refuses an
        # existing name, so two spawns of one name cannot both publish and a
        # seed never pairs with another run's brief. A run killed before ln
        # leaves only its own dot-named temp, which no launch reads. Each step
        # is an AND list, which errexit does not judge, so every abort is
        # explicit.
        staged=$(mktemp "$sdir/.$name.seed.XXXXXX") \
            || error "cs -spawn: cannot stage the seed in $sdir"
        # One printf for the lines before the brief, so one status covers
        # them: a brace group reports only its LAST command. An empty array is
        # unbound under bash 3.2's set -u; the guard expands to nothing then.
        local _payload _t
        _payload="$token
$spawner
"
        for _t in ${tasks[@]+"${tasks[@]}"}; do _payload="$_payload$_t
"; done
        [ -z "$brief" ] || _payload="$_payload$SPAWN_BRIEF_MARK
"
        { printf '%s' "$_payload" && { [ -z "$brief" ] || cat "$brief"; }; } > "$staged" \
            || { rm -f "$staged" 2>/dev/null || :; error "cs -spawn: cannot stage the seed in $sdir"; }
        if ! ln "$staged" "$seed" 2>/dev/null; then
            rm -f "$staged" 2>/dev/null || :
            [ ! -e "$seed" ] || error "A pending spawn for $name exists: $seed"
            error "cs -spawn: cannot publish the seed in $sdir (ln failed; the filesystem may not support hard links)"
        fi
        rm -f "$staged" || warn "cs -spawn: could not remove the staging file $staged"
    fi
    _spawn_window "$name" "$token"
}
