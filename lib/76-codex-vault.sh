# ABOUTME: An encrypted session's Codex home, inside its vault: made, linked and seeded at
# ABOUTME: launch, and confined by cs's permissions profile so the agent cannot rewrite it.

# Codex keeps rollouts, history, its state databases and logs in CODEX_HOME.
# An encrypted session runs it on .cs/private/codex-home, which is in the vault,
# so none of that lands in the shared home in plaintext. Only these names are
# shared, by symlink: the login, instructions and extensions. Everything else
# Codex writes is born in the vault, a file a later Codex adds included. The
# directories are made in the shared home when missing, so no link dangles
# where Codex would make a directory; a file link may dangle until Codex
# writes through it (codex login writes through auth.json's link).
CS_CODEX_VAULT_LINK_FILES="auth.json auth.json.lock auth.lock AGENTS.md hooks.json"
CS_CODEX_VAULT_LINK_DIRS="skills agents plugins rules hooks"
# The lock files hold nothing: a real one Codex made before cs linked it is
# replaced. A real auth.json would hold a login, so it is never touched.
CS_CODEX_VAULT_LOCKS="auth.json.lock auth.lock"

# The home cs installs into and reads its own Codex files from: the shell's,
# also while a launch has pointed CODEX_HOME at a session's vault.
_codex_shared_home() {
    printf '%s\n' "${CS_CODEX_SHARED_HOME:-${CODEX_HOME:-$HOME/.codex}}"
}

# A vault home, by its spelling: as linked, or as it resolves into the mount.
_codex_is_vault_home() {  # path
    case "$1" in
        */.cs/private/codex-home|*/.cs/vault-mnt/private/codex-home) return 0 ;;
    esac
    return 1
}

# Where a Codex conversation is told its rotation handoffs and their marker are,
# relative to the session: in the vault for an encrypted session, as
# cs_handoff_dir and cs_private_dir decide.
_codex_handoffs_shown() {  # session_dir
    if _switch_session_encrypted "$1"; then echo .cs/private/handoffs; else echo .cs/handoffs; fi
}

_codex_marker_shown() {  # session_dir
    if _switch_session_encrypted "$1"; then echo .cs/private/pending-handoff; else echo .cs/local/pending-handoff; fi
}

# The vault home of an encrypted session, as it resolves (the spelling Codex
# keys hook trust by). Fails while the vault is not mounted.
_codex_vault_home_path() {  # session_dir
    local private
    private=$(cd -P -- "$1/.cs/private" 2>/dev/null && pwd -P) || return 1
    printf '%s/codex-home\n' "$private"
}

# Makes or refreshes the vault home and prints its path. A link that points
# anywhere else is pointed back at the shared home (the shell's home may have
# moved); a real file or directory where a link belongs stops the launch,
# named, since it may hold the only copy of something (a login).
_codex_vault_home_prepare() {  # session_dir, shared_home, helper
    local home shared="$2" name target
    case "$shared" in
        /*) ;;
        *) _codex_launch_error "The shared Codex home must be an absolute path, not $shared."; return 1 ;;
    esac
    home=$(_codex_vault_home_path "$1") || {
        _codex_launch_error "$1 is encrypted, but its vault is not mounted; cs makes its Codex home there."
        return 1
    }
    # The agent can write .cs/private: a codex-home it planted as a link would
    # have cs chmod and link wherever it points.
    if [ -L "$home" ] || { [ -e "$home" ] && [ ! -d "$home" ]; }; then
        _codex_launch_error "$home is a link or not a directory; cs does not follow a link there. Move it aside; the next open makes the vault Codex home."
        return 1
    fi
    (umask 077 && mkdir -p "$home") && chmod 700 "$home" || {
        _codex_launch_error "Could not make the vault Codex home $home."
        return 1
    }
    for name in $CS_CODEX_VAULT_LINK_DIRS; do
        target="$shared/$name"
        if [ ! -d "$target" ] && ! (umask 077 && mkdir -p "$target"); then
            _codex_launch_error "Could not make $target for the vault Codex home to link to."
            return 1
        fi
    done
    for name in $CS_CODEX_VAULT_LINK_FILES $CS_CODEX_VAULT_LINK_DIRS; do
        target="$shared/$name"
        if [ -L "$home/$name" ]; then
            [ "$(readlink "$home/$name")" = "$target" ] && continue
        elif [ -e "$home/$name" ]; then
            case " $CS_CODEX_VAULT_LOCKS " in
                *" $name "*) [ -f "$home/$name" ] && [ ! -s "$home/$name" ] && rm -f "$home/$name" ;;
            esac
            if [ -e "$home/$name" ]; then
                if [ "$name" = auth.json ]; then
                    _codex_launch_error "$home/auth.json is a file, not cs's link to $target: Codex saved a login inside the vault. Keep the newer of the two: mv \"$home/auth.json\" \"$target\" if this one is newer, else rm \"$home/auth.json\". cs then links it again."
                else
                    _codex_launch_error "$home/$name is not cs's link to $target. Move it aside; cs links it at the next open."
                fi
                return 1
            fi
        fi
        ln -sfn "$target" "$home/$name" || {
            _codex_launch_error "Could not link $home/$name to $target."
            return 1
        }
    done
    cs_run_child "$3" --seed-config --shared-home "$shared" --home "$home" --cwd "$1" >/dev/null || {
        _codex_launch_error "Could not copy $shared/config.toml into the vault Codex home; the line above says why."
        return 1
    }
    printf '%s\n' "$home"
}

# Back to the shell's Codex home from a vault home a launch into an encrypted
# session exported (CS_CODEX_SHARED_HOME is set only beside one), or to Codex's
# default when only the vault home's spelling came along.
_codex_drop_inherited_vault_home() {
    if [ -n "${CS_CODEX_SHARED_HOME:-}" ] || _codex_is_vault_home "${CODEX_HOME:-}"; then
        if [ -n "${CS_CODEX_SHARED_HOME:-}" ]; then
            export CODEX_HOME="$CS_CODEX_SHARED_HOME"
        else
            unset CODEX_HOME
        fi
    fi
    unset CS_CODEX_SHARED_HOME
}

# The counterpart of _export_session_claude_config. A vault home inherited
# from a launch into another encrypted session is dropped, back to the shell's
# home, so nothing started from inside one session writes into its vault. An
# encrypted session then gets its own, exported for Codex and every helper and
# hook the run starts, with the shell's home in CS_CODEX_SHARED_HOME.
# The second argument, existing, prepares the home only when Codex has run in
# this vault before, as a Claude launch does: it reads Codex history from it.
_export_session_codex_home() {  # session_dir, [existing]
    local home helper shared
    _codex_drop_inherited_vault_home
    _switch_session_encrypted "$1" || return 0
    if [ "${2:-}" = existing ]; then
        home=$(_codex_vault_home_path "$1") && [ -d "$home" ] || return 0
    fi
    helper=$(_codex_thread_helper) && [ -x "$helper" ] || {
        _codex_launch_error "Cannot locate cs-codex-thread beside the cs executable; cs needs it to prepare the vault Codex home."
        return 1
    }
    shared="${CODEX_HOME:-$HOME/.codex}"
    [ -d "$shared" ] || {
        _codex_launch_error "The shared Codex home $shared does not exist; the vault Codex home links its login there. Run codex login first."
        return 1
    }
    # Kept as spelled: Codex keys the shared home's hook trust by that spelling,
    # and the copy re-keys it and its resolved form both.
    home=$(_codex_vault_home_prepare "$1" "$shared" "$helper") || return 1
    export CS_CODEX_SHARED_HOME="$shared" CODEX_HOME="$home"
}

# Asks Codex what the vault home resolves to and refuses what cs cannot
# confine: a profile some file already defines under cs's name (cs's would
# merge into it), or a hook trusted in the shared home but not here (a guard
# hook would silently stop running). Prints the check's JSON.
_codex_vault_check() {  # helper, codex_bin, session_dir
    local check untrusted
    check=$(cs_run_child "$1" --vault-check --codex-bin "$2" --cwd "$3" \
        --shared-home "$CS_CODEX_SHARED_HOME") || {
        _codex_launch_error "Could not read the vault Codex home's configuration; cs does not start Codex there unchecked."
        return 1
    }
    if [ "$(printf '%s' "$check" | jq -r '.profile_defined')" != false ]; then
        _codex_launch_error "A Codex config file for $3 already defines the permissions profile cs-vault-home, which cs adds to keep the agent out of the vault Codex home. Rename that profile."
        return 1
    fi
    untrusted=$(printf '%s' "$check" | jq -r '.untrusted[]') || return 1
    if [ -n "$untrusted" ]; then
        _codex_launch_error "These hooks are trusted in $CS_CODEX_SHARED_HOME but would not run in the vault Codex home, so cs does not start it: $(printf '%s' "$untrusted" | tr '\n' ';' | sed 's/;$//; s/;/; /g'). Review them with /hooks in a Codex outside this session."
        return 1
    fi
    printf '%s\n' "$check"
}

# cs's permissions profile, on the command line (it outranks every config
# file and stays across /clear): Codex's workspace sandbox with the vault home
# read-only. The profile replaces [sandbox_workspace_write], so its settings are
# carried in: each writable root, network access, and the temp directories it
# keeps read-only. Under automatic approval it is always added. Under native
# approval it follows the user's sandbox: read-only and full access need
# nothing (nothing to write, or no sandbox chosen), a profile of their own is
# refused (cs cannot add its rule to it), anything else gets cs's.
_codex_vault_profile_args() {  # check JSON, home, approval; appends to CS_NATIVE_LAUNCH_ARGS
    local check="$1" home="$2" mode own table
    mode=$(printf '%s' "$check" | jq -r '.sandbox_mode // ""') || return 1
    own=$(printf '%s' "$check" | jq -r '.default_permissions // ""') || return 1
    if [ "$3" = native ]; then
        if [ -n "$own" ] && [ "$own" != cs-vault-home ]; then
            _codex_launch_error "Your Codex config selects the permissions profile $own, and cs cannot add the vault rule to it. Open this encrypted session with automatic approval (--approve-for-me)."
            return 1
        fi
        case "$mode" in
            read-only|danger-full-access) return 0 ;;
        esac
    fi
    table=$(printf '%s' "$check" | jq -r --arg home "$home" '
        .sandbox_workspace_write as $w
        | ([($home | tojson) + "=\"read\""]
           + [($w.writable_roots // [])[] | select(type == "string") | tojson + "=\"write\""]
           + (if $w.exclude_slash_tmp == true then ["\":slash_tmp\"=\"read\""] else [] end)
           + (if $w.exclude_tmpdir_env_var == true then ["\":tmpdir\"=\"read\""] else [] end)) as $fs
        | "permissions.cs-vault-home={extends=\":workspace\", filesystem={" + ($fs | join(", ")) + "}"
          + (if $w.network_access == true then ", network={enabled=true}" else "" end) + "}"') || return 1
    CS_NATIVE_LAUNCH_ARGS+=(-c "$table" -c 'default_permissions="cs-vault-home"')
}
