#!/bin/sh
# ABOUTME: Installs the fork with the user's normal Claude and Codex configuration.
# ABOUTME: Backs up the replaced cs installation and imports old engine history.
set -eu
usage() {
    cat <<'EOF'
Usage: sh setup.sh [--skip-tui-build] [--no-carry-over]

Installs this fork as cs, code-sessions and ccs in ~/.local/bin, with its
integrations in ~/.claude and ~/.codex. Replaces an existing cs installation
after backing up its managed files; uninstalling first is unnecessary.
Imports missing conversations from the former private engine profile.
Existing project folders and session secrets stay in place. ccs continues
to use the former fork's sessions when that store exists; cs uses its usual
session store. Both commands run this fork with the normal engine configs.
--no-carry-over is accepted for compatibility; configuration is now shared.
CS_INSTALL_ENGINES can select claude, codex, or claude,codex.
EOF
}
build_tui=1
for argument in "$@"; do
    case "$argument" in
        --skip-tui-build) build_tui=0 ;;
        --no-carry-over) ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
: "${HOME:?HOME must be set}"
checkout_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
cd "$checkout_dir"
for dependency in bash git jq python3; do
    command -v "$dependency" >/dev/null 2>&1 || { printf 'Missing prerequisite: %s\n' "$dependency" >&2; exit 1; }
done
engines_file="$HOME/.local/bin/.cs-install-engines"
[ -f "$engines_file" ] || engines_file="$HOME/.local/share/code-sessions/home/.local/bin/.cs-install-engines"
if [ -z "${CS_INSTALL_ENGINES:-}" ] && [ -f "$engines_file" ]; then
    CS_INSTALL_ENGINES=$(cat "$engines_file")
fi
CS_INSTALL_ENGINES=${CS_INSTALL_ENGINES:-claude,codex}
case "$CS_INSTALL_ENGINES" in
    claude|codex|claude,codex|codex,claude) ;;
    *) printf 'Invalid CS_INSTALL_ENGINES\n' >&2; exit 2 ;;
esac
export CS_INSTALL_ENGINES
printf 'Building code-sessions from %s\n' "$checkout_dir"
bash ./build.sh
if [ "$build_tui" -eq 1 ] && command -v cargo >/dev/null 2>&1; then
    cargo build --release --locked --manifest-path "$checkout_dir/tui/Cargo.toml"
fi
backup_dir=$(python3 scripts/shared-config.py --backup)
printf 'Installation backup: %s\n' "$backup_dir"
python3 scripts/shared-config.py --apply --backup-dir "$backup_dir"
# Discard the old profile's overrides when setup runs inside one of its sessions.
env -u CODE_SESSIONS_HOME -u CODE_SESSIONS_ORIGINAL_ROOT -u CLAUDE_CONFIG_DIR \
    -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CS_CLAUDE_DIR -u CS_HOOKS_DIR \
    -u CS_SKILLS_DIR -u CS_COMMANDS_DIR -u CS_TRANSCRIPTS_DIR -u CS_INSTALL_DIR \
    -u CS_CONFIG_DIR -u CS_CACHE_DIR -u CS_DATA_DIR -u CS_SECRETS_DIR \
    CODEX_HOME="$HOME/.codex" XDG_CONFIG_HOME="$HOME/.config" \
    XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache" \
    CS_REPLACE_ORIGINAL=1 CS_HOOK_PATHS=absolute SHELL="${SHELL:-/bin/sh}" \
    bash ./install.sh
mkdir -p "$HOME/.local/bin"
for command_name in code-sessions ccs; do
    wrapper_tmp=$(mktemp "$HOME/.local/bin/.code-sessions-wrapper.XXXXXX")
    cp scripts/code-sessions-profile.sh "$wrapper_tmp"
    chmod 755 "$wrapper_tmp"
    mv -f "$wrapper_tmp" "$HOME/.local/bin/$command_name"
done
add_command_path() {
    startup_file=$1
    if [ -f "$startup_file" ] && { grep -Fqx '# >>> code-sessions PATH >>>' "$startup_file" \
        || grep -Fqx '# >>> agent-sessions PATH >>>' "$startup_file"; }; then
        return
    fi
    mkdir -p "$(dirname "$startup_file")"
    cat >> "$startup_file" <<'EOF'

# >>> code-sessions PATH >>>
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< code-sessions PATH <<<
EOF
}
case "${SHELL##*/}" in
    zsh) add_command_path "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash)
        add_command_path "$HOME/.bashrc"
        if [ -f "$HOME/.bash_profile" ]; then add_command_path "$HOME/.bash_profile"
        elif [ -f "$HOME/.bash_login" ]; then add_command_path "$HOME/.bash_login"
        else add_command_path "$HOME/.profile"; fi ;;
    *) add_command_path "$HOME/.profile" ;;
esac
"$HOME/.local/bin/cs" -version
printf '\nInstalled with ~/.claude and ~/.codex. No separate engine login or sidebar fork is needed.\n'
printf 'Use ccs for your existing fork sessions, or cs for the usual session store.\n'
printf 'Already-running agents keep their launch configuration; reopen them when convenient.\n'
