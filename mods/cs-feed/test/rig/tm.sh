#!/bin/bash
# ABOUTME: Drives one oracle launch on its own tmux server: start a claude beside the fake API, type, send keys, snapshot, wait for text, stop.
# ABOUTME: Usage: tm.sh <launch-dir> start <workdir> | type <text> | send <keys...> | snap <file> | wait <regex> <secs> | stop. Kills only the server named in <launch-dir>/tmux.name.
set -euo pipefail
RIG="$(cd "$(dirname "$0")" && pwd)"
L="$1"; verb="$2"; shift 2
NAMEF="$L/tmux.name"
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
sock() { cat "$NAMEF"; }
case "$verb" in
    start)
        work="$1"
        [ ! -s "$NAMEF" ] || { echo "already running: $(sock)"; exit 1; }
        name="cs-feed-oracle-$(basename "$L")-$$"
        echo "$name" > "$NAMEF"; echo "$name" >> "$L/../servers.created"
        port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
        echo "$port" > "$L/fakeapi.port"
        nohup python3 -I "$RIG/fakeapi.py" "$port" "$L/fakeapi.jsonl" >/dev/null 2>&1 &
        echo $! > "$L/fakeapi.pid"
        [ -s "$L/session.id" ] || uuidgen | tr '[:upper:]' '[:lower:]' > "$L/session.id"
        uuid="$(cat "$L/session.id")"
        launch=(env RIG_PORT="$port" RIG_CS_BIN="${RIG_CS_BIN:-}" RIG_UPDATE="${RIG_UPDATE:-}" RIG_SESSIONS="${RIG_SESSIONS:-}" RIG_TALLY_DIR="$L"
            "$RIG/env.sh" "$L/home" "$RIG_CLAUDE" --session-id "$uuid" --debug-file "$L/debug.txt")
        # PLUGIN_DIRS is a space-separated list of plugin directories, none with a space.
        for dir in ${PLUGIN_DIRS:-}; do launch+=(--plugin-dir "$dir"); done
        cmd="cd $(printf '%q' "$work") && $(printf '%q ' "${launch[@]}"); sleep 3600"
        tmux -L "$name" new-session -d -s oracle -x "${RIG_COLUMNS:-120}" -y 45 "$cmd"
        echo "tmux socket=$name port=$port uuid=$uuid start=$(ms)";;
    send) a=$(ms); tmux -L "$(sock)" send-keys -t oracle "$@"; echo "send@$a $*";;
    type) tmux -L "$(sock)" send-keys -t oracle -l "$1"; echo "typed@$(ms) $1";;
    snap) tmux -L "$(sock)" capture-pane -p -t oracle -S -200 > "$1"; echo "snap@$(ms) $1";;
    alt) tmux -L "$(sock)" display -p -t oracle '#{alternate_on}';;
    wait)
        re="$1"; secs="$2"; end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -le "$end" ]; do
            tmux -L "$(sock)" capture-pane -p -t oracle -S -200 | grep -Eq "$re" && { echo "matched@$(ms) $re"; exit 0; }
            sleep 0.2
        done
        echo "timeout $re"; exit 1;;
    stop)
        [ -s "$NAMEF" ] || exit 0
        name="$(sock)"
        tmux -L "$name" kill-server 2>/dev/null || true
        # kill-server leaves the socket file; it goes once no server answers on it.
        tmux -L "$name" ls >/dev/null 2>&1 || rm -f "${TMUX_TMPDIR:-/private/tmp}/tmux-$(id -u)/$name"
        [ ! -s "$L/fakeapi.pid" ] || kill "$(cat "$L/fakeapi.pid")" 2>/dev/null || true
        echo "$name" >> "$L/../servers.killed"
        rm -f "$NAMEF" "$L/fakeapi.pid"
        echo "killed tmux server $name";;
    *) echo "tm.sh: unknown verb $verb"; exit 2;;
esac
