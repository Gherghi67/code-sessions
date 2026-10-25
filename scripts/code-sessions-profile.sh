#!/bin/sh
# ABOUTME: Starts the fork with the user's normal Claude and Codex configuration.
# ABOUTME: Keeps existing fork session folders and secrets addressable without moving projects.
set -eu
legacy="$HOME/.local/share/code-sessions/home"
# Explicit config outside the former profile remains the user's choice.
case "${CLAUDE_CONFIG_DIR:-}" in "$legacy"/*) unset CLAUDE_CONFIG_DIR ;; esac
case "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" in "$legacy"/*) unset CLAUDE_SECURESTORAGE_CONFIG_DIR ;; esac
case "${CODEX_HOME:-}" in "$legacy"/*) unset CODEX_HOME ;; esac
unset CODE_SESSIONS_HOME CODE_SESSIONS_ORIGINAL_ROOT
unset CS_SESSION_NAME CS_SESSION_DIR CS_SESSION_META_DIR CS_ACTOR
unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
unset CS_CLAUDE_DIR CS_TRANSCRIPTS_DIR CS_HOOKS_DIR CS_COMMANDS_DIR CS_SKILLS_DIR
unset CS_CONFIG_DIR CS_CACHE_DIR CS_DATA_DIR CS_INSTALL_DIR
export CS_BIN="$HOME/.local/bin/cs"
export PATH="$HOME/.local/bin:$PATH"
# Manager data stays in place: no project moves, secret copies or vault renames.
if [ -d "$legacy/sessions" ]; then
    export CS_SESSIONS_ROOT="$legacy/sessions"
    export CS_SECRETS_KEYCHAIN_PREFIX=code-sessions CS_SECRETS_DIR="$legacy/.cs-secrets"
    export CS_DATA_DIR="$legacy/.local/share/cs"
    export CS_TMUX_SOCKET=code-sessions CS_TMUX_SESSION=code-sessions
else
    unset CS_SESSIONS_ROOT CS_SECRETS_KEYCHAIN_PREFIX CS_SECRETS_DIR CS_TMUX_SOCKET CS_TMUX_SESSION
fi
exec "$CS_BIN" "$@"
