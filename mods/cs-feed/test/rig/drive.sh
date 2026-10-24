#!/bin/bash
# ABOUTME: Shared steps for one oracle launch, sourced by dispatch-count.sh: launch and settle, type a prompt, spike Q3's three turns, exit so session.end writes the tallies, stop.
# ABOUTME: Every step appends a timestamped mark (epoch ms) to $L/run.txt; screens are captured beside it.

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
tm() { "$RIG/tm.sh" "$L" "$@" >> "$L/run.txt"; }
mark() { echo "$1@$(ms)" >> "$L/run.txt"; }
snap() { tm snap "$L/$1.txt"; }

# Launches claude in <workdir> and waits for the prompt; answers the auto-mode dialog when it shows.
launch() {  # workdir
    tm start "$1"
    tm wait '❯' 40 || { echo "launch $(basename "$L"): no prompt within 40 s" >> "$L/run.txt"; return 1; }
    sleep 3
    snap 00-start
    if grep -q 'Make auto mode' "$L/00-start.txt"; then
        echo "auto-mode dialog present" >> "$L/run.txt"
        tm send Down; sleep 0.5; tm send Enter; sleep 1.5
    fi
    "$RIG/tm.sh" "$L" alt > "$L/alternate_on"
}

say() {  # text
    echo "say@$(ms) $1" >> "$L/run.txt"
    tm type "$1"; sleep 0.6; tm send Enter
    echo "enter@$(ms) $1" >> "$L/run.txt"
}

# spike Q3's scenario, with its fixed sleeps.
q3_turns() {
    mark scenario_start
    say "hello SIMPLE"; sleep 6
    say "SLOWTEXT go"; sleep 26
    say "SLOWTOOL x"; sleep 38
    mark scenario_end
    snap 01-turns
}

# /exit runs session.end, which writes each tally named; waits up to 15 s for them, then stops the server.
finish() {  # tally names...
    say "/exit"
    local end=$(( $(date +%s) + 15 )) name missing
    while :; do
        missing=""
        for name in "$@"; do [ -s "$L/tally-$name.json" ] || missing="$missing $name"; done
        [ -n "$missing" ] && [ "$(date +%s)" -le "$end" ] || break
        sleep 0.3
    done
    mark exit_done
    snap 99-exit
    [ -z "$missing" ] || echo "tally missing:$missing" >> "$L/run.txt"
    tm stop
}
