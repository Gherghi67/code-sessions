#!/bin/bash
# ABOUTME: Runs a command under one oracle launch's throwaway HOME and config dir, with an environment built from nothing (env -i).
# ABOUTME: Usage: env.sh <home> <cmd...>; RIG_PORT, RIG_CS_BIN, RIG_UPDATE, RIG_SESSIONS and RIG_TALLY_DIR add the fake API, CS_BIN, CS_UPDATE_AVAILABLE, CS_SESSIONS_ROOT and the tally directory.
set -euo pipefail
home="$1"; shift
vars=(HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" USER=oracle PATH=/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin
    LANG=en_US.UTF-8 TERM=xterm-256color COLORTERM=truecolor
    CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1)
if [ -n "${RIG_PORT:-}" ]; then
    # A key-shaped stand-in for the local fake API; it is assembled here so no
    # credential-shaped literal sits in the tree.
    vars+=(ANTHROPIC_BASE_URL="http://127.0.0.1:$RIG_PORT" ANTHROPIC_API_KEY="$(cat "$home/fake-key")")
fi
[ -z "${RIG_CS_BIN:-}" ] || vars+=(CS_BIN="$RIG_CS_BIN")
[ -z "${RIG_UPDATE:-}" ] || vars+=(CS_UPDATE_AVAILABLE="$RIG_UPDATE")
[ -z "${RIG_SESSIONS:-}" ] || vars+=(CS_SESSIONS_ROOT="$RIG_SESSIONS")
[ -z "${RIG_TALLY_DIR:-}" ] || vars+=(RIG_TALLY_DIR="$RIG_TALLY_DIR")
exec env -i "${vars[@]}" "$@"
