#!/bin/bash
# ABOUTME: The cs-feed cost oracle: real claude sessions (throwaway HOME, local fake API, own tmux servers) count the feed's callbacks with an instrumented copy and its worker hops on the shipped plugin.
# ABOUTME: Usage: dispatch-count.sh [run-dir [case...]]; writes everything under run-dir and exits non-zero on any mismatch (2 when the positive control voids the run). Never deployed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$MOD/../.." && pwd)"
RIG_SRC="$HERE/rig"

# require_tool by the suite's convention; test_lib.sh rewrites HOME and PATH and
# sets a CS_BIN of its own at source time, none of which reaches a launch:
# every claude runs under env.sh's env -i.
CLAUDE_PATH="$(command -v claude || true)"
SCRIPT_DIR="$REPO/tests"
# shellcheck source=../../../tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
require_tool claude tmux python3 jq uuidgen || exit $?
case "$CLAUDE_PATH" in /*) ;; *) echo "dispatch-count: claude is not an executable on PATH ($CLAUDE_PATH)"; exit 1 ;; esac
export RIG_CLAUDE="$CLAUDE_PATH"

R="${1:-}"
[ -n "$R" ] || R="$(mktemp -d "${TMPDIR:-/tmp}/cs-feed-oracle.XXXXXX")"
mkdir -p "$R"
R="$(cd "$R" && pwd -P)"
[ ! -e "$R/launches" ] || { echo "dispatch-count: $R already holds a run; give an empty directory"; exit 1; }
shift || true
RENDERERS="${RIG_RENDERERS:-fullscreen default}"
ALL_CASES="control probe-solo probe-beside none shipped-solo v3 shipped-beside band trace7 outside refused panes"
CASES="${*:-$ALL_CASES}"
mkdir -p "$R/launches" "$R/plugins"
: > "$R/launches/servers.created"; : > "$R/launches/servers.killed"
: > "$R/cases.tsv"
echo "dispatch-count: run directory $R"

# Every server this run started is killed by its recorded name, whatever ends the run.
cleanup() {
    local l
    for l in "$R"/launches/*/; do
        [ -s "$l/tmux.name" ] && "$R/rig/tm.sh" "${l%/}" stop >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

# --- the rig, copied into the run directory ---
cp -R "$RIG_SRC" "$R/rig"
VERSION="$("$RIG_CLAUDE" --version | awk '{print $1}')"
echo "claude $VERSION" > "$R/claude-version"

# --- plugins: cs's three mods and the shipped cs-feed copied as they stand; the probe, the control and the dummy pane built ---
P="$R/plugins"
for m in cs cs-update cs-mermaid cs-feed; do
    mkdir -p "$P/$m"
    cp -R "$REPO/mods/$m/.claude-plugin" "$REPO/mods/$m/hooks" "$P/$m/"
    [ ! -d "$REPO/mods/$m/skills" ] || cp -R "$REPO/mods/$m/skills" "$P/$m/"
    rm -rf "$P/$m/.claude-plugin/types"
done
if ! python3 -I "$R/rig/probe.py" "$MOD" "$P" > "$R/probe-build.txt"; then
    cat "$R/probe-build.txt"; echo "dispatch-count: VOID: the probe build did not land every insertion"; exit 2
fi
cat "$R/probe-build.txt"

# The probe must load as shipped code does: the host's static scan runs at validate too.
mkdir -p "$R/validate-home/.claude"
for m in probe passrender dummypane; do
    if ! "$R/rig/env.sh" "$R/validate-home" "$RIG_CLAUDE" plugin validate "$P/$m" > "$R/validate-$m.txt" 2>&1; then
        echo "dispatch-count: VOID: claude plugin validate refused the $m plugin (see $R/validate-$m.txt)"; exit 2
    fi
done

# --- directories the launches run in ---
make_project() {  # dir
    mkdir -p "$1/.claude"
    (cd "$1" && git init -q)
    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$R/rig/stop-hook.sh" > "$1/.claude/settings.json"
}
PLAIN="$R/work"; make_project "$PLAIN"
SESSIONS="$R/sessions"; CSDIR="$SESSIONS/feedrig"; make_project "$CSDIR"; mkdir -p "$CSDIR/.cs/local"
OUTSIDE="$R/outside"; make_project "$OUTSIDE"
REFUSED="$R/refused"; make_project "$REFUSED"; mkdir -p "$REFUSED/.cs/local"
echo "$CSDIR" > "$R/rig/trusted-dir"
VET_STUB="$R/rig/cs-vet-stub.sh"

# A key-shaped stand-in for the fake API, assembled so the tree holds no credential-shaped literal.
FAKE_KEY="sk-""ant-api03-feedoracle-local-stub-key-0000000000AA"

# One fresh throwaway HOME per launch, so no launch inherits another's startup count or tips.
make_home() {  # launch-dir renderer
    local h="$1/home"
    mkdir -p "$h/.claude"
    printf '%s' "$FAKE_KEY" > "$h/fake-key"
    jq -n --arg tui "$2" '{permissions: {allow: ["Bash"], defaultMode: "default"}, theme: "light", tui: $tui}' > "$h/.claude/settings.json"
    jq -n --arg key "${FAKE_KEY: -20}" --arg v "$VERSION" --arg a "$PLAIN" --arg b "$CSDIR" --arg c "$OUTSIDE" --arg d "$REFUSED" '
        def trusted: {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true, projectOnboardingSeenCount: 1};
        {hasCompletedOnboarding: true, theme: "light", lastReleaseNotesSeen: $v, firstStartVersion: $v, lastClawdEntranceVersion: $v,
         customApiKeyResponses: {approved: [$key], rejected: []},
         officialMarketplaceAutoInstallAttempted: true, hasSeenAutoDefaultNotice: true,
         projects: {($a): trusted, ($b): trusted, ($c): trusted, ($d): trusted}}' > "$h/.claude/.claude.json"
    echo '{"bindings": [{"context": "Global", "bindings": {"ctrl+x 3": "strip:jump3"}}]}' > "$h/.claude/keybindings.json"
}

# The cs session directory as cs's band recognises it: under CS_SESSIONS_ROOT, led by this launch's session id.
lead_session() {  # launch-dir feed-file-content-or-empty
    printf 'session_name: feedrig\nclaude_session_id: %s\n' "$(cat "$1/session.id")" > "$CSDIR/.cs/local/state"
    rm -f "$CSDIR/.cs/local/feed" "$CSDIR/.cs/local/feed-view"
    [ -z "$2" ] || printf '%s' "$2" > "$CSDIR/.cs/local/feed"
}

BESIDE="$P/cs $P/cs-update $P/cs-mermaid"

new_launch() {  # tag case renderer plugin-dirs
    L="$R/launches/$1"
    mkdir -p "$L"
    uuidgen | tr '[:upper:]' '[:lower:]' > "$L/session.id"
    make_home "$L" "$3"
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$R/cases.tsv"
    export PLUGIN_DIRS="$4"
    unset RIG_CS_BIN RIG_UPDATE RIG_SESSIONS RIG_COLUMNS
    echo "launch $1 ($3): $4" | sed "s#$P/##g"
}

# shellcheck source=rig/drive.sh
source "$R/rig/drive.sh"

# --- the cases ---

# spike Q3's three turns in a directory that is no cs session, so nothing reads .cs/local/feed: the session is off.
q3_case() {  # case renderer plugin-dirs tallies... (passcount when passrender is the only plugin)
    local c="$1" r="$2" dirs="$3"; shift 3
    new_launch "$c-$r" "$c" "$r" "$dirs"
    launch "$PLAIN"
    q3_turns
    if [ "$c" = control ]; then
        say "/passcount"; sleep 3; snap 02-count; mark count_end
    fi
    finish "$@"
}

# The band key both ways while idle, then typed /feed on, and /feed off and /feed on mid-call.
band_case() {  # renderer
    new_launch "band-$1" band "$1" "$BESIDE $P/probe"
    export RIG_CS_BIN="$VET_STUB" RIG_SESSIONS="$SESSIONS"
    lead_session "$L" ""
    launch "$CSDIR"
    snap 01-idle
    mark press1; tm send C-x 3; sleep 2; snap 02-pressed-on
    cp "$CSDIR/.cs/local/feed" "$L/feed-after-press1" 2>/dev/null || echo absent > "$L/feed-after-press1"
    mark press2; tm send C-x 3; sleep 2; snap 03-pressed-off
    cp "$CSDIR/.cs/local/feed" "$L/feed-after-press2" 2>/dev/null || echo absent > "$L/feed-after-press2"
    say "/feed on"; sleep 2; snap 04-typed-on
    say "SLOWTOOL x"
    tm wait 'Sleep thirty|time.sleep' 20 || true
    sleep 4; snap 05-midcall-on
    mark midcall_off; say "/feed off"; sleep 4; snap 06-midcall-off
    mark midcall_on; say "/feed on"; sleep 4; snap 07-midcall-on-again
    tm wait 'TOOLDONE' 40 || true
    sleep 2; snap 08-turn-done
    cp "$CSDIR/.cs/local/feed" "$L/feed-at-end" 2>/dev/null || echo absent > "$L/feed-at-end"
    finish cs-feed
}

# Trace 7: a planted on in a session cs refuses (no CS_BIN at launch).
trace7_case() {  # renderer
    new_launch "trace7-$1" trace7 "$1" "$BESIDE $P/probe"
    export RIG_SESSIONS="$SESSIONS"
    lead_session "$L" "on
"
    launch "$CSDIR"
    sleep 1; snap 00-ready
    say "hello SIMPLE"; sleep 6; snap 01-turn
    mark press; tm send C-x 3; sleep 2; snap 02-pressed
    mark typed_off; say "/feed off"; sleep 2; snap 03-feed-off
    mark typed_status; say "/feed status"; sleep 2; snap 04-feed-status
    cp "$CSDIR/.cs/local/feed" "$L/feed-at-end" 2>/dev/null || echo absent > "$L/feed-at-end"
    finish cs-feed
}

# /feed on in a directory with no .cs/local: nothing created.
outside_case() {  # renderer
    new_launch "outside-$1" outside "$1" "$P/probe"
    export RIG_CS_BIN="$VET_STUB"
    launch "$OUTSIDE"
    say "/feed on"; sleep 2; snap 01-feed-on
    { [ -e "$OUTSIDE/.cs" ] && echo present || echo absent; } > "$L/cs-dir-after"
    finish cs-feed
}

# /feed on where .cs/local exists and the launch names no CS_BIN: the vet refuses, nothing written.
refused_case() {  # renderer
    new_launch "refused-$1" refused "$1" "$P/probe"
    rm -f "$REFUSED/.cs/local/feed" "$REFUSED/.cs/local/feed-view"
    launch "$REFUSED"
    say "/feed on"; sleep 2; snap 01-feed-on
    ls -A "$REFUSED/.cs/local" > "$L/local-after"
    finish cs-feed
}

# cs-update's pane and a dummy plugin's pane open, the feed's panes shut.
panes_case() {  # renderer
    new_launch "panes-$1" panes "$1" "$BESIDE $P/probe $P/dummypane"
    # cs-update opens its pane unasked at session start, which Claude Code places only from 144 columns.
    export RIG_CS_BIN="$VET_STUB" RIG_SESSIONS="$SESSIONS" RIG_UPDATE="9999.0.0" RIG_COLUMNS=160
    lead_session "$L" ""
    launch "$CSDIR"
    tm wait 'cs 9999.0.0 is available' 10 || true
    say "/dummypane"
    tm wait 'DUMMYPANE' 10 || true
    sleep 4; snap 01-panes-open
    finish cs-feed
}

for r in $RENDERERS; do
    for c in $CASES; do
        case "$c" in
            control) q3_case control "$r" "$P/passrender" passrender ;;
            probe-solo) q3_case probe-solo "$r" "$P/probe $P/passrender" cs-feed passrender ;;
            probe-beside) q3_case probe-beside "$r" "$BESIDE $P/probe $P/passrender" cs-feed passrender ;;
            none) q3_case none "$r" "" ;;
            shipped-solo) q3_case shipped-solo "$r" "$P/cs-feed" ;;
            v3) q3_case v3 "$r" "$BESIDE" ;;
            shipped-beside) q3_case shipped-beside "$r" "$BESIDE $P/cs-feed" ;;
            band) band_case "$r" ;;
            trace7) trace7_case "$r" ;;
            outside) outside_case "$r" ;;
            refused) refused_case "$r" ;;
            panes) panes_case "$r" ;;
            *) echo "dispatch-count: unknown case $c (cases: $ALL_CASES)"; exit 1 ;;
        esac
    done
done

python3 -I "$R/rig/report.py" "$R"
