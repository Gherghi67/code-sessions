# ABOUTME: Backs 'cs -spawn': open a session in the cs-owned tmux session,
# ABOUTME: optionally staging tasks the launch path arms on open.

# Every tmux call goes through this wrapper; tests point CS_TMUX_BIN at a fake.
_tmux() {
    "${CS_TMUX_BIN:-tmux}" "$@"
}

# The spawner's own calls: on the server CS_TMUX_SOCKET names (tmux -L), else
# the default one. A window runs with its server's environment, not the
# spawner's, so a second install on a shared server would run as the first.
# Not in _tmux: the launch publishes into whichever server $TMUX names.
_spawn_tmux() {
    _tmux ${CS_TMUX_SOCKET:+-L "$CS_TMUX_SOCKET"} "$@"
}

# Single-quote encode one word for a shell command line handed to tmux.
_sq() {  # text
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Absolute path of the running cs binary (the tmux server's PATH may lack
# ~/.local/bin, so the window command must not rely on lookup).
_cs_self() {
    case "$0" in
        */*) printf '%s/%s' "$(cd -- "$(dirname "$0")" && pwd)" "$(basename "$0")";;
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

# An open reads a seed only after renaming it to a name of its own,
# .<name>.seed.claim.<pid>, so a seed cs -spawn publishes while the open asks
# is never the one it reads, sets aside or deletes. The launch's EXIT trap
# (which INT and TERM reach through their exit) calls _spawn_put_back_claim,
# so an open that stops before it consumed the seed leaves it staged again
# under <name>.seed.
_CS_SPAWN_CLAIM=""
_CS_SPAWN_SEED=""

# Put a claimed seed back under its staged name. ln refuses a name a newer
# spawn published meanwhile; the claimed seed is then set aside as .stale.
_spawn_put_back_claim() {
    local claim="$_CS_SPAWN_CLAIM" seed="$_CS_SPAWN_SEED"
    _CS_SPAWN_CLAIM=""
    [ -n "$claim" ] && [ -e "$claim" ] || return 0
    if ln "$claim" "$seed" 2>/dev/null; then
        rm -f "$claim"
    elif mv "$claim" "$seed.stale" 2>/dev/null; then
        warn "A newer spawn seed is staged: $seed; the one this open read is set aside: $seed.stale"
    else
        warn "Spawn seed could not be put back: $claim"
    fi
    return 0
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
    # session named <name>.seed never has its own staging file matched. And
    # the claim an open killed outright leaves: .<name>.seed.claim.<pid>, a
    # digit first, so a session named <name>.seed.claim never has its own
    # claim matched. Twin of the staging match in tui/src/session.rs.
    for staged in "$SESSIONS_ROOT/.spawn/.$1.seed."?????? \
                  "$SESSIONS_ROOT/.spawn/.$1.seed.claim."[0-9]*; do
        [ -e "$staged" ] || continue
        rm -f "$staged"
    done
}

# True when the tmux session named $CS_TMUX_SESSION carries cs's stamp. Only
# meaningful once has-session has confirmed the exact name exists: the plain '-t'
# target is required because tmux 3.6a rejects '=' anchors on the options
# commands. Shared by _spawn_precheck (errors on a foreign session) and the
# doctor's spawn check (warns), so the @cs_managed contract lives in one place.
_cs_tmux_managed() {
    [ "$(_spawn_tmux show-option -t "${CS_TMUX_SESSION:-cs}" -v @cs_managed 2>/dev/null || true)" = "1" ]
}

# Pre-window checks that must pass BEFORE the seed is written, so a refused
# spawn never leaves a pending seed behind.
# The window to open is named <window>, the session name unless given, and
# <asker> names the cs command that wants it (cs -spawn unless given).
_spawn_precheck() {  # name, [window], [asker]
    local tmux_session="${CS_TMUX_SESSION:-cs}"
    case "$tmux_session" in *[:.]*) error "CS_TMUX_SESSION=$tmux_session: a tmux session name cannot contain colon or dot" ;; esac
    local name="$1" window="${2:-$1}" asker="${3:-cs -spawn}"
    command -v "${CS_TMUX_BIN:-tmux}" >/dev/null 2>&1 || error "$asker needs tmux"
    if session_is_live "$SESSIONS_ROOT/$name/.cs"; then
        error "Session $name is already live"
    fi
    if _spawn_tmux has-session -t "=$tmux_session" 2>/dev/null; then
        _cs_tmux_managed || error "A tmux session named '$tmux_session' exists but was not created by cs; close or rename it"
        # Best-effort tidiness check only. session_is_live above is the real
        # guard against double-launching a session; tmux automatic-rename can
        # rename a window out from under this name match, and the only cost of a
        # miss is a duplicate window name in the cs session, never a second live
        # launch. Do not add locking here for that benign case.
        if _spawn_tmux list-windows -t "=${CS_TMUX_SESSION:-cs}" -F '#{window_name}' 2>/dev/null | grep -Fxq "$window"; then
            error "A window named $window already exists in tmux session ${CS_TMUX_SESSION:-cs}"
        fi
    fi
}

# How to reach the cs tmux session. tmux attach refuses to nest, so a caller
# already inside tmux is told to switch-client instead. switch-client cannot
# leave the server $TMUX names ("<socket path>,<pid>,<session>"), so from any
# other one the hint for CS_TMUX_SOCKET's server attaches.
_spawn_attach_hint() {
    local tmux="tmux" here="${TMUX:-}"
    [ -z "${CS_TMUX_SOCKET:-}" ] || tmux=$(printf 'tmux -L %q' "$CS_TMUX_SOCKET")
    here="${here%%,*}"
    if [ -n "$here" ] && { [ -z "${CS_TMUX_SOCKET:-}" ] || [ "${here##*/}" = "$CS_TMUX_SOCKET" ]; }; then
        printf '%s switch-client -t %q' "$tmux" "${CS_TMUX_SESSION:-cs}"
    else
        printf '%s attach -t %q' "$tmux" "${CS_TMUX_SESSION:-cs}"
    fi
}

_spawn_window() {  # name, token, engine
    local name="$1" token="$2" engine="$3" cmd="env" assignments="" selector
    # An existing tmux server retains the environment that started it. Carry
    # the caller's configuration, including unsets, without copying credentials.
    # env options must precede its assignments on both BSD and GNU env.
    for selector in HOME PATH XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME \
        CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR CODEX_HOME \
        CODE_SESSIONS_HOME CODE_SESSIONS_ORIGINAL_ROOT CS_BIN CS_INSTALL_DIR \
        CS_CONFIG_DIR CS_CACHE_DIR CS_DATA_DIR CS_CLAUDE_DIR CS_HOOKS_DIR \
        CS_COMMANDS_DIR CS_SKILLS_DIR CS_TRANSCRIPTS_DIR CS_SESSIONS_ROOT \
        CS_SECRETS_DIR CS_SECRETS_KEYCHAIN_PREFIX CS_SECRETS_BACKEND \
        CS_TMUX_SOCKET CS_TMUX_SESSION CS_TMUX_BIN CLAUDE_CODE_BIN CODEX_BIN \
        CS_CODEX_THREAD_BIN CS_DEFAULT_ENGINE; do
        if [ "${!selector+x}" = x ]; then
            assignments="$assignments $(_sq "$selector=${!selector}")"
        else
            cmd="$cmd -u $selector"
        fi
    done
    # The token proves to the launch that this window is the spawn's own, so
    # only it consumes the seed unasked (see the seed consumer in
    # lib/75-launch.sh). It is correlation, not a secret: anyone who can read
    # the seed can read it, and `ps` shows it for as long as the launch runs.
    # `env` rather than a VAR=value prefix, which tmux's default-shell need
    # not understand.
    cmd="$cmd$assignments $(_sq "CS_SPAWN_TOKEN=$token") $(_sq "$(_cs_self)") $(_sq "$name") --engine $(_sq "$engine")"
    _cs_tmux_window "$name" "$cmd"
    info "spawned $name in tmux session ${CS_TMUX_SESSION:-cs} (window $_CS_TMUX_WID). Attach: $(_spawn_attach_hint)"
}

# Open a window named <window> running <cmd> in the cs-owned tmux session, and
# leave its id in _CS_TMUX_WID. A global rather than printed: the options call
# below would print into a capture, and error would end only the capture.
_CS_TMUX_WID=""
_cs_tmux_window() {  # window, cmd
    # Try to create the cs session outright: tmux rejects a duplicate -s name,
    # so "already exists" and "a concurrent spawner just created it" collapse
    # into the same fallthrough to new-window.
    if _CS_TMUX_WID=$(_spawn_tmux new-session -d -s "${CS_TMUX_SESSION:-cs}" -n "$1" -P -F '#{window_id}' "$2" 2>/dev/null); then
        # Plain target: tmux 3.6a rejects '=' anchors on the options commands;
        # exact 'cs' was just created by new-session, so this cannot misfire.
        _spawn_tmux set-option -t "${CS_TMUX_SESSION:-cs}" @cs_managed 1
        return 0
    fi
    _CS_TMUX_WID=$(_spawn_tmux new-window -t "=${CS_TMUX_SESSION:-cs}" -n "$1" -P -F '#{window_id}' "$2") \
        || error "tmux new-window failed for $1"
}

run_spawn() {
    local name="" brief="" engine=""
    local usage='Usage: cs -spawn <name> [--engine claude|codex] [--brief <file>] [--task "..."] ...'
    local tasks
    tasks=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --engine)
                [ $# -ge 2 ] || error "--engine needs a value"
                [ -z "$engine" ] || error "cs -spawn takes one --engine"
                shift
                cs_engine_known "$1" || error "Unknown engine: $1. Choose claude or codex."
                engine="$1";;
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
    # The spawner is whatever the environment says. It becomes the worker's
    # report-back address and goes into its kick prompt, so it must be a
    # session name; an empty one means "no spawner" (no report-back wiring).
    local spawner="${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-}}"
    if [ -n "$spawner" ] && ! cs_split_worktree_name "$spawner"; then
        # validate_session_name exits on a bad name; a subshell turns that
        # into a status so the error can name where the name came from.
        ( validate_session_name "$spawner" ) >/dev/null 2>&1 \
            || error "cs -spawn: CLAUDE_SESSION_NAME is not a session name: $spawner"
    fi
    # The spawn's own window runs a seed's tasks and brief unasked, so a seed
    # for a session that already exists is work handed to that session's
    # user. Another session's work goes through task mail they accept; a
    # terminal outside any session, and the base briefing one of its own
    # features, are that user.
    if [ -n "$spawner" ] && { [ "${#tasks[@]}" -gt 0 ] || [ -n "$brief" ]; } \
        && is_session_dir "$SESSIONS_ROOT/$name" \
        && [ "${spawner%%@*}" != "${name%%@*}" ]; then
        error "session $spawner cannot hand work to the existing session $name; send it as task mail for $name's user to accept: cs -msg $name --kind task \"<task>\""
    fi
    # Explicit selection wins; otherwise inherit the spawning run, then the
    # target preference/default. Do not rely on tmux's ambient environment.
    engine=$(_session_engine "$SESSIONS_ROOT/$name" "${engine:-${CS_RUN_ENGINE:-}}") || return 1
    if [ "$engine" = codex ] && [ "${#tasks[@]}" -gt 0 ]; then
        error "Codex does not host the walk-away task queue; use --brief without --task"
    fi
    _spawn_precheck "$name"
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
    _spawn_window "$name" "$token" "$engine"
}

# Shared seed consent, delivery and queue staging. The launch owns the lease
# and supplies the captured _spawn_token; returns the native prompt in spawn_kick.
_spawn_prepare_launch() {  # session_name, session_dir
    local session_name="$1" session_dir="$2"
    # Spawn seed: tasks and a brief staged by cs -spawn for this session.
    # Consumed here, after the already-running guard and before any exec arm,
    # so a window that died before launching self-heals on the session's next
    # open. A stale seed (>1h) is set aside with its brief, never silently
    # armed days later.
    #
    # Consent (audit H2): a seed is a file in .spawn/, and anything that can
    # write there could arm the next open of this name with its own tasks and
    # a kick that says "begin". Line 1 of the seed is a token the spawn's own
    # tmux window carries in CS_SPAWN_TOKEN; only that window consumes unasked.
    # Every other open (by hand, a script, a window that died and was reopened
    # elsewhere) is shown the seed as data and asked. The token was taken out
    # of the environment before the lock (above), so claude, a collision
    # redirect and any nested launch never carry it.
    spawn_kick=""
    [ -n "${SESSIONS_ROOT:-}" ] || return 0
    local _seed="$SESSIONS_ROOT/.spawn/$session_name.seed" _claim
    if [ -f "$_seed" ]; then
        local _now _age
        _now=$(date +%s)
        _age=$(( _now - $(_epoch_mtime "$_seed") ))
        if [ "$_age" -gt 3600 ]; then
            mv "$_seed" "$_seed.stale" 2>/dev/null || true
            warn "Stale spawn seed set aside: $_seed.stale (re-run cs -spawn if still wanted)"
        else
            # Read the seed once: line 1 the token, line 2 the spawner, then
            # one task per line up to the brief marker, if the seed has one;
            # the brief is the rest of the file and is never read as tasks.
            # Whitespace-only lines are skipped, not merely empty ones:
            # _queue_add trims and then errors on an empty body, which under
            # errexit would abort the whole session launch over a stray space
            # in a hand-edited seed.
            local _seed_token="" _spawner="" _line _lineno=0 _n=0 _mark
            local _tasks
            _tasks=()
            # Everything below reads the seed under a name this open owns
            # (_spawn_put_back_claim in lib/52-spawn.sh): a seed published in
            # .spawn while the consent ask waits is not the one shown, and the
            # tasks, the brief, a decline and the delete all belong to the
            # seed that was shown. The traps put it back if the open stops.
            _claim="$SESSIONS_ROOT/.spawn/.$session_name.seed.claim.$$"
            mv "$_seed" "$_claim" \
                || error "Spawn seed could not be read: $_seed (seed kept; re-open the session to retry)"
            _CS_SPAWN_SEED="$_seed"
            _CS_SPAWN_CLAIM="$_claim"
            _mark=$(_spawn_brief_mark_line "$_claim") \
                || error "Spawn seed could not be read: $_seed (seed kept; re-open the session to retry)"
            while IFS= read -r _line || [ -n "$_line" ]; do
                _lineno=$((_lineno + 1))
                [ "$_lineno" != "$_mark" ] || break
                case "$_lineno" in
                    1) _seed_token="$_line"; continue ;;
                    2) _spawner="$_line"; continue ;;
                esac
                case "$_line" in *[![:space:]]*) : ;; *) continue ;; esac
                _tasks+=("$_line")
                _n=$((_n + 1))
            done < "$_claim"
            # Never empty-equals-empty: a seed with no token line (older cs,
            # or hand-written) is foreign to every open.
            local _consume=1
            if [ -n "$_spawn_token" ] && [ "$_spawn_token" = "$_seed_token" ]; then
                :
            else
                _consume=0
                # Shown as data: control characters stripped, so a crafted
                # seed cannot draw over the question it is answering.
                local _shown_spawner _shown
                _shown_spawner=$(printf '%s' "$_spawner" | tr -d '[:cntrl:]')
                echo
                printf "${GOLD}A spawn seed is staged for this session:${NC} %s\n" "$_seed"
                printf '    spawner: %s\n' "${_shown_spawner:-(none)}"
                if [ -n "$_mark" ]; then
                    printf '    brief:   inline, %s bytes (becomes .cs/brief.md)\n' \
                        "$(tail -n +"$((_mark + 1))" "$_claim" | wc -c | tr -d ' ')"
                fi
                if [ "$_n" -gt 0 ]; then
                    printf '    tasks (queued and armed; the walk-away drain runs them unattended):\n'
                    local _i=0
                    for _line in ${_tasks[@]+"${_tasks[@]}"}; do
                        _i=$((_i + 1))
                        _shown=$(printf '%s' "$_line" | tr -d '[:cntrl:]')
                        printf '      %d. %s\n' "$_i" "$_shown"
                    done
                fi
                # The answer is a keypress on a terminal, never redirected
                # stdin: `cs name <<< ""` hands read a newline, which is the
                # empty answer the default arm took (Codex round 1), and a
                # script could type y as easily. With no terminal the seed
                # stays staged for an attended open and this launch goes on
                # without it. On a terminal: Enter or y takes the seed, n or
                # Escape sets the seed and brief aside like a stale pair so
                # the next open does not ask again, any other key asks
                # again, and EOF leaves it staged.
                if [ ! -t 0 ]; then
                    _spawn_put_back_claim
                    warn "Spawn seed left staged: $_seed (open $session_name in a terminal to answer, or remove it)"
                else
                    local _answer
                    while :; do
                        printf "${DIM}This open is not the spawn's own window.${NC} Take the seed? [Y/n] "
                        if ! IFS= read -rsn1 _answer; then
                            echo
                            _spawn_put_back_claim
                            warn "Spawn seed left staged: $_seed (open $session_name in a terminal to answer, or remove it)"
                            break
                        fi
                        echo
                        case "$_answer" in
                            ''|[yY]) _consume=1; break ;;
                            $'\e'|[nN])
                                _CS_SPAWN_CLAIM=""
                                mv "$_claim" "$_seed.stale" 2>/dev/null || true
                                warn "Spawn seed declined and set aside: $_seed.stale (re-run cs -spawn if still wanted)"
                                break ;;
                        esac
                    done
                fi
            fi
        fi
        if [ "${_consume:-0}" = 1 ]; then
            local _has_brief=0 _qdir
            if [ "${CS_RUN_ENGINE:-claude}" = codex ] && [ "$_n" -gt 0 ]; then
                error "Codex does not host the walk-away task queue; use --brief without --task (seed kept)"
            fi
            if [ "${CS_RUN_ENGINE:-claude}" = codex ] && [ -e "$session_dir/.cs/local/spawn-kick.json" ]; then
                error "An earlier spawn kickoff is pending; deliver it before taking another seed (seed kept)"
            fi
            # The spawner becomes the worker's report-back address, in
            # spawned-by and in the kick's `cs -msg <spawner>`, so a seed
            # being taken has it held to the session-name rules cs -spawn
            # holds it to, in a subshell since both rules exit on a bad name.
            # A seed that breaks them is refused before anything is written
            # or queued, and the trap puts it back. A seed left staged or
            # declined above is not taken, so nothing is asked of it.
            if [ -n "$_spawner" ] \
                && ! ( cs_split_worktree_name "$_spawner" || validate_session_name "$_spawner" ) >/dev/null 2>&1; then
                error "Spawn seed $_seed names a spawner that is not a session name: $(_cs_plain_name "$_spawner" 80) (seed kept; remove it or re-run cs -spawn, then re-open the session)"
            fi
            # The brief is written in before any task is queued, and a write
            # that fails stops the launch with the seed still staged, so the
            # next open retries. Consuming the seed regardless would start the
            # session without the brief it was opened for. errexit does not
            # see a failed left operand, so the abort is explicit.
            if [ -n "$_mark" ]; then
                # A link in the brief's place would turn the write into one
                # over whatever it names; a directory would take the file.
                [ ! -L "$session_dir/.cs/brief.md" ] \
                    || error "Spawn brief could not be delivered: $session_dir/.cs/brief.md is a link (seed kept; remove it and re-open the session to retry)"
                [ ! -d "$session_dir/.cs/brief.md" ] \
                    || error "Spawn brief could not be delivered: $session_dir/.cs/brief.md is a directory (seed kept; remove it and re-open the session to retry)"
                cs_write_atomic "$session_dir/.cs/brief.md" tail -n +"$((_mark + 1))" "$_claim" \
                    || error "Spawn brief could not be delivered to $session_dir/.cs/brief.md (seed kept; re-open the session to retry)"
                _has_brief=1
            fi
            # The queue is a cs content file: behind .cs/private in an
            # encrypted session, where the drain reads it. spawned-by is an
            # id and stays in .cs/local (docs/session-layout.md).
            _qdir=$(cs_private_dir "$session_dir/.cs") \
                || error "$session_name: .cs/private dangles after the open checked it (vault unmounted mid-launch?). Mount it, then reopen. (seed kept)"
            # Every write that can fail runs before the first task is queued:
            # a failure stops the open with the seed staged again, and that
            # seed is then the only copy of its tasks, so the retry queues
            # each one once.
            if [ -n "$_spawner" ] && { [ "$_n" -gt 0 ] || [ "$_has_brief" = 1 ]; }; then
                printf '%s\n' "$_spawner" > "$session_dir/.cs/local/spawned-by" 2>/dev/null \
                    || error "could not record the spawner in $session_dir/.cs/local/spawned-by (seed kept; fix it and re-open the session to retry)"
            fi
            # A task that cannot be queued takes back the ones this open queued
            # before it, so the seed put back is the only copy of its tasks. A
            # take-back that fails names every file left, for the person to
            # remove before a retry queues them again.
            local _queued=() _left=() _f
            for _line in ${_tasks[@]+"${_tasks[@]}"}; do
                if _queue_write_task "$_qdir" "$_line"; then
                    _queued+=("$_QUEUE_ADDED")
                    continue
                fi
                for _f in ${_queued[@]+"${_queued[@]}"}; do
                    rm -f "$_f" 2>/dev/null && [ ! -e "$_f" ] || _left+=("$_f")
                done
                if [ "${#_left[@]}" -gt 0 ]; then
                    error "could not write the task into $_qdir/queue; it is not queued, and ${#_left[@]} task(s) this open queued before it could not be taken back: ${_left[*]}. Remove them before re-opening the session, or the retry queues them again (seed kept)"
                fi
                error "could not write the task into $_qdir/queue; it is not queued (seed kept; the ${#_queued[@]} task(s) this open queued before it were taken back)"
            done
            if [ "$_n" -gt 0 ] || [ "$_has_brief" = 1 ]; then
                local _work=""
                [ "$_has_brief" = 1 ] && _work="Your brief is .cs/brief.md: read it first."
                if [ "$_n" -gt 0 ]; then
                    _work="${_work:+$_work }Your walk-away queue is armed with $_n task(s); begin."
                else
                    _work="$_work Then begin."
                fi
                if [ -n "$_spawner" ]; then
                    spawn_kick="Spawned by $_spawner. $_work Send results with: cs -msg $_spawner -k result \"...\""
                else
                    spawn_kick="$_work"
                fi
            fi
            if [ "${CS_RUN_ENGINE:-claude}" = codex ] && [ -n "$spawn_kick" ]; then
                cs_write_atomic "$session_dir/.cs/local/spawn-kick.json" jq -n \
                    --arg prompt "$spawn_kick" '{prompt: $prompt, attempted: false}' \
                    || error "Cannot save spawn kickoff (seed kept; reopen to retry)"
            fi
            # Once its tasks are queued the seed is spent: only the claimed
            # seed is deleted (one published since stays staged for its own
            # open), and a failure from here on cannot put it back to be
            # queued a second time.
            _CS_SPAWN_CLAIM=""
            rm -f "$_claim"
            if [ "$_n" -gt 0 ]; then
                _queue_set_state "$_qdir" armed \
                    || error "the seed's $_n task(s) are queued but the queue could not be armed; arm it with: cs $session_name -queue start"
            fi

        fi
    fi
}

# Only an owned, fresh seed or an already accepted receipt bypasses native
# resume questions. Foreign staged work still needs the seed consent flow.
_spawn_launch_is_owned() {  # session_name, session_dir
    [ ! -f "$2/.cs/local/spawn-kick.json" ] || return 0
    [ -n "${SESSIONS_ROOT:-}" ] && [ -n "${_spawn_token:-}" ] || return 1
    local seed="$SESSIONS_ROOT/.spawn/$1.seed" token age
    [ -f "$seed" ] || return 1
    IFS= read -r token < "$seed" || return 1
    [ "$token" = "$_spawn_token" ] || return 1
    age=$(( $(date +%s) - $(_epoch_mtime "$seed") ))
    [ "$age" -le 3600 ]
}
