# ABOUTME: An encrypted session's Antigravity home, inside its vault: a $HOME for agy made at launch whose
# ABOUTME: entries link back to the user's own, checked again at every open and by cs's hooks during the run.

# agy keeps its conversations, brain, summaries, history, logs and caches in
# $HOME/.gemini/antigravity-cli and has no setting that moves them: it
# resolves everything from $HOME (measured on agy 1.5.9 and 1.5.10). An
# encrypted session runs agy with HOME set to .cs/private/antigravity-home,
# which is in the vault, so all of that is born there and none of it lands in
# the user's home in plaintext.
#
# Every command agy starts inherits that HOME, so the home holds a link to
# each entry of the user's home but .gemini: git, gh and ssh find their files,
# and macOS finds the login keychain through the Library link (measured on agy
# 1.5.10, 2026-11-19). In .gemini everything links back to the user's
# ~/.gemini except agy's own state (antigravity-cli, and the names
# CS_AGY_VAULT_GEMINI_PRIVATE lists) and GEMINI.md, which is cs's rule for the
# session, written at each launch. In antigravity-cli only the names
# CS_AGY_VAULT_CLI_LINKS lists link back, and CS_AGY_VAULT_CLI_COPIES are
# copied in at each open; the rest is the conversations'. So agy's
# configuration and its global permission grants (config/), its hooks,
# plugins and sandbox profiles stay in the user's ~/.gemini, outside the
# session, where agy's terminal sandbox keeps commands from writing them, as
# for any agy session; a global grant answered in an encrypted session is
# saved there in plaintext (the user's choice, 2026-11-19). settings.json
# (its grants and folder trust) cannot be a link, since agy replaces the file
# whenever it saves it: it is a copy, kept by the hooks as the run began, and
# what a run saves in it lasts until the next open.
#
# The links themselves sit in the session, which agy's sandbox lets a command
# write, so a command could swap one for a file of its own, or plant a name
# the home has no link for (a .zshenv a command run outside the sandbox would
# read). The home is therefore made to match the user's again at every open,
# and cs's PreInvocation and PostToolUse hooks do the same during the run:
# whatever does not belong is moved aside into antigravity-home.moved/, beside
# the home and in the vault, never deleted, its link restored, and the turn is
# stopped and the user told (_antigravity_hook_vault_check). A swap and its use
# within one command, or a background process racing the checks, still gets
# through.

# The names in the user's ~/.gemini that stay in the vault: agy's state, the
# desktop app's, and the Gemini CLI's history and temp folders. GEMINI.md is
# cs's rule.
CS_AGY_VAULT_GEMINI_PRIVATE="antigravity-cli antigravity history tmp GEMINI.md"
# The names in antigravity-cli that link back: hooks, and the binaries and
# updater agy keeps there.
CS_AGY_VAULT_CLI_LINKS="hooks.json bin builtin updater installation_id"
# The names in antigravity-cli copied from the user's at every open instead:
# agy replaces settings.json with a file of its own whenever it saves it (a
# folder trust answered, measured on agy 1.5.10), which would replace a link,
# and the onboarding records, without which agy runs its onboarding again,
# its data-use consent included. The copy of settings.json is the vault's for
# the run: the hooks keep it as the run began (_antigravity_hook_vault_check).
CS_AGY_VAULT_CLI_COPIES="settings.json cache/onboarding.json cache/nux_state.json"
# Directories made in the user's home when missing, so no link dangles where
# agy would make a directory.
CS_AGY_VAULT_GEMINI_DIRS="config sandbox"
CS_AGY_VAULT_CLI_DIRS="bin builtin updater"
# The login agy keeps in ~/.gemini (file-based; not rewritten at a token
# refresh: its mtime stood still across ten days of use, 2026-11-09..19).
CS_AGY_LOGIN=jetski-standalone-oauth-token

# The home cs links back to: the shell's, also inside a run, where bin/cs's
# header has put HOME back from CS_ANTIGRAVITY_SHARED_HOME.
_antigravity_shared_home() {
    printf '%s\n' "${CS_ANTIGRAVITY_SHARED_HOME:-$HOME}"
}

# A vault home, by its last name: the launch exports it resolved, and a
# hand-made vault can sit anywhere.
_antigravity_is_vault_home() {  # path
    case "$1" in */antigravity-home) return 0 ;; esac
    return 1
}

# Back to the shell's home from a vault home a launch into an encrypted
# session exported. bin/cs's header does the same before anything reads HOME;
# this covers a caller that sourced the libraries. A vault home with no
# shell's home beside it cannot be undone, and fails.
_antigravity_drop_inherited_vault_home() {
    if [ -n "${CS_ANTIGRAVITY_SHARED_HOME:-}" ]; then
        case "$CS_ANTIGRAVITY_SHARED_HOME" in
            /*) [ ! -d "$CS_ANTIGRAVITY_SHARED_HOME" ] || export HOME="$CS_ANTIGRAVITY_SHARED_HOME" ;;
        esac
        unset CS_ANTIGRAVITY_SHARED_HOME
    fi
    ! _antigravity_is_vault_home "${HOME:-}"
}

# The vault home of an encrypted session, as it resolves. Fails while the
# vault is not mounted.
_antigravity_vault_home_path() {  # session_dir
    local private
    private=$(cd -P -- "$1/.cs/private" 2>/dev/null && pwd -P) || return 1
    printf '%s/antigravity-home\n' "$private"
}

# Makes <home> match <shared>. Modes: open, at a launch, also copies
# CS_AGY_VAULT_CLI_COPIES in from the user's; check, in a hook, also keeps
# antigravity-cli/settings.json as <snapshot> holds it, taking the snapshot at
# the run's first check; report only says how the home does not match.
# Prints one line per entry moved aside or link pointed back, as
# "moved <path in the home>" and "relinked <path in the home>", control
# characters escaped; a link added for a new entry of the user's home, or
# removed for one that is gone, is the home following the user's and is not
# printed, nor is a copy refreshed or settings.json put back. Each entry
# moved goes to <moved>/<stamp>/<its path in the home>. Fails, saying why on
# stderr, when it cannot finish.
CS_AGY_VAULT_SYNC_PY='
import os, sys, time, tempfile
(mode, shared, home, moved_root, gem_private, cli_links, gem_dirs, cli_dirs,
 cli_copies, snapshot) = sys.argv[1:11]
gem_private = set(gem_private.split())
cli_links = cli_links.split()
gem_dirs = gem_dirs.split()
cli_dirs = cli_dirs.split()
cli_copies = cli_copies.split()
report = mode == "report"
stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + str(os.getpid())

def shown(rel):
    return "".join(c if c.isprintable() else "\\x%02x" % ord(c) for c in rel)

def say(kind, rel):
    print(kind + " " + shown(rel))

def move_aside(rel):
    say("moved", rel)
    if report:
        return
    dest = os.path.join(moved_root, stamp, rel)
    os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
    os.rename(os.path.join(home, rel), dest)

def is_dir(path):
    return os.path.isdir(path) and not os.path.islink(path)

def ensure_dir(rel):
    path = os.path.join(home, rel)
    if os.path.lexists(path) and not is_dir(path):
        move_aside(rel)
    if not report and not os.path.lexists(path):
        os.mkdir(path, 0o700)
    if not report:
        os.chmod(path, 0o700)

def link(rel, target):
    path = os.path.join(home, rel)
    if os.path.islink(path):
        if os.readlink(path) == target:
            return
        say("relinked", rel)
        if report:
            return
        os.unlink(path)
    elif os.path.lexists(path):
        move_aside(rel)
    if not report:
        os.symlink(target, path)

def names(path):
    try:
        return set(os.listdir(path))
    except FileNotFoundError:
        return set()

def level(rel, shared_dir, linked, private):
    """Links each name in linked; keeps private names; moves the rest aside,
    but a link of cs naming an entry the user no longer has is just removed."""
    here = os.path.join(home, rel) if rel else home
    for name in sorted(linked):
        link(os.path.join(rel, name) if rel else name, os.path.join(shared_dir, name))
    if not os.path.isdir(here):
        return
    for name in sorted(names(here) - set(linked) - set(private)):
        sub = os.path.join(rel, name) if rel else name
        path = os.path.join(home, sub)
        if os.path.islink(path) and os.path.dirname(os.readlink(path)) == shared_dir:
            if not report:
                os.unlink(path)
            continue
        move_aside(sub)

def read(path):
    with open(path, "rb") as f:
        return f.read()

def write_atomic(rel, data):
    """Writes a file of the home by a temp file in its folder renamed over the
    name; whatever stands there but a file is moved aside first."""
    path = os.path.join(home, rel)
    if os.path.lexists(path) and (os.path.islink(path) or not os.path.isfile(path)):
        move_aside(rel)
    fd, tmp = tempfile.mkstemp(prefix=".cs-tmp.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise

def copy_in(rel, src):
    """A copy at <rel> of the file <src> of the user, refreshed; none when there is none."""
    path = os.path.join(home, rel)
    if not os.path.isfile(src):
        if os.path.lexists(path) and (os.path.islink(path) or not os.path.isfile(path)):
            move_aside(rel)
        elif os.path.lexists(path):
            os.unlink(path)
        return
    data = read(src)
    if os.path.isfile(path) and not os.path.islink(path) and read(path) == data:
        return
    write_atomic(rel, data)

def guard_settings(rel):
    """settings.json as the run began: the snapshot is taken at the first check,
    after agy has saved any trust answered at its start, and put back whenever
    a command changes the file. A link or folder there is moved aside."""
    path = os.path.join(home, rel)
    absent = snapshot + ".absent"
    if not os.path.lexists(snapshot) and not os.path.lexists(absent):
        if os.path.isfile(path) and not os.path.islink(path):
            fd = os.open(snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(read(path))
        else:
            os.close(os.open(absent, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        return
    if os.path.lexists(path) and (os.path.islink(path) or not os.path.isfile(path)):
        move_aside(rel)
    if os.path.lexists(absent):
        if os.path.lexists(path):
            os.unlink(path)
        return
    want = read(snapshot)
    if os.path.isfile(path) and read(path) == want:
        return
    write_atomic(rel, want)

def make_shared_dirs(shared_dir, wanted):
    if report:
        return
    for name in wanted:
        path = os.path.join(shared_dir, name)
        if not os.path.lexists(path):
            os.makedirs(path, mode=0o700, exist_ok=True)

def main():
    gem_shared = os.path.join(shared, ".gemini")
    cli_shared = os.path.join(gem_shared, "antigravity-cli")
    make_shared_dirs(gem_shared, gem_dirs)
    make_shared_dirs(cli_shared, cli_dirs)
    level("", shared, names(shared) - {".gemini"}, {".gemini"})
    ensure_dir(".gemini")
    level(".gemini", gem_shared, (names(gem_shared) | set(gem_dirs)) - gem_private, gem_private)
    rule = os.path.join(home, ".gemini", "GEMINI.md")
    if os.path.lexists(rule) and (os.path.islink(rule) or not os.path.isfile(rule)):
        move_aside(os.path.join(".gemini", "GEMINI.md"))
    cli = os.path.join(".gemini", "antigravity-cli")
    ensure_dir(cli)
    for name in cli_links:
        link(os.path.join(cli, name), os.path.join(cli_shared, name))
    if mode == "open":
        for name in cli_copies:
            if "/" in name:
                ensure_dir(os.path.join(cli, os.path.dirname(name)))
            copy_in(os.path.join(cli, name), os.path.join(cli_shared, name))
    elif mode == "check":
        guard_settings(os.path.join(cli, "settings.json"))

try:
    main()
except OSError as e:
    sys.exit("cs: the vault Antigravity home: " + shown(str(e)))
'

_antigravity_vault_sync() {  # open|check|report, shared_home, vault_home, [snapshot]
    local moved="${3%/*}/antigravity-home.moved"
    # The hook can run from the checkout, which must not supply Python imports.
    python3 -I -c "$CS_AGY_VAULT_SYNC_PY" "$1" "$2" "$3" "$moved" \
        "$CS_AGY_VAULT_GEMINI_PRIVATE" "$CS_AGY_VAULT_CLI_LINKS" "$CS_AGY_VAULT_GEMINI_DIRS" "$CS_AGY_VAULT_CLI_DIRS" \
        "$CS_AGY_VAULT_CLI_COPIES" "${4:-}"
}

# Makes or refreshes the vault home and prints its path. What the sync moved
# aside or pointed back is said on stderr, with where the moved entries are.
# The home is named as a plain name: .cs/private is a link the agent can point
# at a directory whose name carries a terminal escape.
_antigravity_vault_home_prepare() {  # session_dir, shared_home
    local home shared="$2" shown changes
    case "$shared" in
        /*) ;;
        *) _antigravity_launch_error "The home cs links agy's vault home to must be an absolute path, not $(_cs_plain_name "$shared" 160)."; return 1 ;;
    esac
    _antigravity_is_vault_home "$shared" && {
        _antigravity_launch_error "HOME is another encrypted session's Antigravity home ($(_cs_plain_name "$shared" 160)); open this session from a shell whose HOME is your own."
        return 1
    }
    home=$(_antigravity_vault_home_path "$1") || {
        _antigravity_launch_error "$1 is encrypted, but its vault is not mounted; cs makes its Antigravity home there."
        return 1
    }
    shown=$(_cs_plain_name "$home" 160)
    if [ ! -f "$shared/.gemini/$CS_AGY_LOGIN" ]; then
        _antigravity_launch_error "agy has no login in $shared/.gemini ($CS_AGY_LOGIN), which the vault Antigravity home links to. Sign in with agy once outside this session, then reopen."
        return 1
    fi
    # The agent can write .cs/private: a home it planted as a link would have
    # cs link and move wherever it points.
    if [ -L "$home" ] || { [ -e "$home" ] && [ ! -d "$home" ]; }; then
        _antigravity_launch_error "$shown is a link or not a directory; cs does not follow a link there. Move it aside; the next open makes the vault Antigravity home."
        return 1
    fi
    (umask 077 && mkdir -p "$home") && chmod 700 "$home" || {
        _antigravity_launch_error "Could not make the vault Antigravity home $shown."
        return 1
    }
    # A login file where cs's link belongs: agy rewrote it, or something else
    # that can write to the session wrote it, and cs cannot tell which. It is
    # moved aside with the rest, and the shared login linked again.
    changes=$(_antigravity_vault_sync open "$shared" "$home") || {
        _antigravity_launch_error "Could not make the vault Antigravity home $shown match $shared; the line above says why."
        return 1
    }
    if [ -n "$changes" ]; then
        warn "cs found entries in the vault Antigravity home $shown that are not its links to $shared, moved them into $(_cs_plain_name "${home%/*}" 160)/antigravity-home.moved/, and linked the shared ones again: $(printf '%s' "$changes" | tr '\n' ';' | sed 's/;$//; s/;/; /g')" >&2
    fi
    printf '%s\n' "$home"
}

# The rule agy loads into every turn of an encrypted session: cs's context as
# a global rule, in the vault home's .gemini/GEMINI.md, never in the session
# folder, where the workspace rule would sit in plaintext. A GEMINI.md the
# user keeps in ~/.gemini follows it, since cs's file takes that name.
_antigravity_emit_vault_rule() {  # cs_bin; shared CS_CONTEXT_* fields are dynamically scoped
    printf '%s\n\n' "$CS_ANTIGRAVITY_RULE_MARK"
    cs_emit_engine_context "$@"
}

# Written from inside the home's .gemini, entered by its physical path and
# checked to be the home's own, by a temporary file renamed over the name.
_antigravity_write_vault_rule() {  # session_name, session_dir, actor, cs_bin, vault_home, shared_home
    local home_p tmp user_rule="$6/.gemini/GEMINI.md"
    if ! (
        home_p=$(cd -P -- "$5" && pwd) || exit 1
        cd -P -- "$5/.gemini" && [ "$(pwd)" = "$home_p/.gemini" ] || exit 1
        tmp=$(mktemp .cs-rule.XXXXXX) || exit 1
        trap 'rm -f -- "$tmp"' EXIT
        {
            cs_session_context "$1" "$2" "$3" _antigravity_emit_vault_rule "$4" || exit 1
            if [ -f "$user_rule" ]; then
                printf '\n\n'
                cat -- "$user_rule" || exit 1
            fi
        } > "$tmp" && mv -f -- "$tmp" GEMINI.md
    ); then
        _antigravity_launch_error "Could not write the Antigravity session rule into the vault: $(_cs_plain_name "$5" 160)/.gemini/GEMINI.md"
        return 1
    fi
}

# The workspace rule a run before the session was encrypted left: cs's
# context in plaintext in the session folder. Removed when it is cs's; one
# that is not cs's is the user's and stays.
_antigravity_drop_workspace_rule() {  # session_dir
    _antigravity_rule_is_cs "$1" || return 0
    rm -f -- "$1/$CS_ANTIGRAVITY_RULE"
}

# The vault home recorded in the run directory, which only cs can write.
_antigravity_run_vault_home() {  # run_dir
    local home=""
    [ -n "$1" ] && [ -f "$1/vault" ] && [ ! -L "$1/vault" ] || return 1
    IFS= read -r home < "$1/vault" || return 1
    case "$home" in /*/antigravity-home) ;; *) return 1 ;; esac
    [ -d "$home" ] && [ ! -L "$home" ] || return 1
    printf '%s\n' "$home"
}

# Resolve the private directory once for the hook and check it against the
# launch's physical path and directory identity before using any records.
_antigravity_run_private_dir() {  # session_dir, run_dir
    local home id current
    _antigravity_run_dir_ok "$2" && [ -f "$2/vault" ] && [ ! -L "$2/vault" ] || return 1
    { IFS= read -r home && IFS= read -r id; } < "$2/vault" || return 1
    current=$(_antigravity_vault_home_path "$1") || return 1
    [ "$current" = "$home" ] && [ -n "$id" ] && [ "$(cs_dir_identity "${current%/*}")" = "$id" ] || return 1
    printf '%s\n' "${current%/*}"
}

_antigravity_hook_vault_stop() {  # event, message
    [ "$1" = pre-invocation ] || return 0
    ANTIGRAVITY_HOOK_REPLY=$(jq -nc --arg m "$2" '
        {injectSteps: [{errorMessage: {userMessage: $m}}], terminationBehavior: "terminate"}')
}

# Whether a hook may act on the session's records: it is not encrypted, or
# the launch ran it on its vault home. A .cs/private in a run launched without
# one came mid-run, maybe as a link out of the session, and is left alone.
_antigravity_vault_ok() {  # session_dir, run_dir
    [ "${_cs_private_pin_meta:-}" != "$1/.cs" ] || return 0
    _switch_session_encrypted "$1" || return 0
    _antigravity_run_vault_home "$2" >/dev/null
}

# Where a hook logs: the vault (cs_private_dir) for a run the launch ran on
# the vault home, as Codex's hooks log an encrypted session's, else .cs/local,
# a .cs/private that came mid-run included, which gets nothing.
_antigravity_log_dir() {  # session_dir, run_dir
    if [ "${_cs_private_pin_meta:-}" = "$1/.cs" ]; then
        cs_private_dir "$1/.cs"
    else
        cs_local_dir "$1/.cs"
    fi
}

# During an encrypted session's run, after each tool and before each model
# call: the vault home is made to match the user's again. What did not belong
# is recorded in the run's directory (vault-moved), for the next
# PreInvocation to stop the turn with (_antigravity_hook_vault_report). Fails
# when the run has no vault home.
_antigravity_hook_vault_check() {  # run_dir
    local home changes
    home=$(_antigravity_run_vault_home "$1") || return 1
    changes=$(_antigravity_vault_sync check "$(_antigravity_shared_home)" "$home" "$1/settings.json" 2>/dev/null) || changes="failed"
    [ -n "$changes" ] || return 0
    printf '%s\n' "$changes" >> "$1/vault-moved" 2>/dev/null || true
}

# The PreInvocation answer that stops a turn after a check moved something
# aside: an error line the user sees, and a system message the model reads at
# the next turn. Prints nothing when there is nothing to report; the record is
# spent once read.
_antigravity_hook_vault_report() {  # run_dir
    local home moved="" shown_moved
    [ -f "$1/vault-moved" ] && [ ! -L "$1/vault-moved" ] || return 0
    moved=$(head -c 2000 "$1/vault-moved" 2>/dev/null | tr '\n' ';' | sed 's/;$//; s/;/; /g') || moved=""
    rm -f "$1/vault-moved" 2>/dev/null || true
    [ -n "$moved" ] || return 0
    home=$(_antigravity_run_vault_home "$1") || home="the vault Antigravity home"
    shown_moved="$(_cs_plain_name "${home%/*}" 160)/antigravity-home.moved/"
    jq -nc --arg user "cs stopped this turn: something changed agy's home inside the vault, where only cs's links to your own files belong ($moved). cs moved what did not belong into $shown_moved and linked your own files again. Look at what was moved before you continue." \
        --arg model "cs stopped the last turn because a command changed agy's home inside the vault ($moved), which only cs's links to the user's own files may hold. cs moved the changed entries into $shown_moved and restored the links. Do not write to $(_cs_plain_name "$home" 160) or move anything back; tell the user what you were doing when it happened." '
        {injectSteps: [{errorMessage: {userMessage: $user}}, {systemMessage: {systemMessage: $model}}],
         terminationBehavior: "terminate"}'
}
