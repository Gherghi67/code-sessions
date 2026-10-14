# ABOUTME: The deploy manifests (hooks, commands, skills, mods, and what past versions
# ABOUTME: left behind), the settings-strip filter and the rotate/wrap key bindings; build.sh
# ABOUTME: folds this into bin/cs and splices it into install.sh, so both read one list.

# Files a past version deployed into the hooks directory and this one does not:
# retired hooks, and any support file that went with them. Removed on install
# and on uninstall, wherever an older cs left them.
# install.sh and run_uninstall both clean these up.
# When retiring a hook in a release, add its filename here.
RETIRED_HOOKS=(
    narrative-precompact.sh   # retired: PreCompact cannot inject context (no hookSpecificOutput/additionalContext); Stop reminder covers capture
    discovery-commits.sh      # renamed to autosave-commits.sh (general all-file crash recovery, not discoveries-specific)
    discoveries-reminder.sh   # retired: session narrative moved to .cs/memory/narrative.md (native lazy-load, no size budget)
    discoveries-archiver.sh   # retired in v2026.4.7 (archive flow replaced by size-budget compaction)
    aboutme-prereader.sh      # retired: source-file ABOUTME-header nudge experiment
    gotcha-prewriter.sh       # retired: brief pre-write gotcha-surfacing experiment; approach was rethought
    aboutme-validator.sh      # retired: never-shipped PostToolUse-on-Write experiment from a feature branch that registered the hook in settings.json without the file ever landing in source
    command-tracker.sh        # retired: CLI command capture; @-included payload did not influence model behaviour at a rate justifying its context cost
    cs-logo.png               # retired: the icon source for the finished-turn notification, which the iTerm2 sidebar owns now (not a hook; a file the hooks directory carried)
    files-scan.sh             # retired: workspace file indexer for .cs/files.md (assumption that the agent can't introspect file sizes has expired)
    files-context.sh          # retired: PreToolUse:Read context injector that surfaced files.md token estimates
    changes-tracker.sh        # retired: PostToolUse change log re-narrating git history into .cs/changes.md; git log/diff/status is authoritative
    artifact-tracker.sh       # retired: PreToolUse:Write redirect was inert (updatedInput path rewrite is not honored by the harness); tracking removed entirely
    prose-lint.sh             # retired with the `cs -lint` verb it called; MUST stay listed, because a deployed copy calling the removed verb reads error()'s exit 1 as "violations found" and blocks every turn-end
    memory-index-guard.sh     # moved into the sweep skill (sweep/scripts/), so the guard travels with the skill to every engine
)

# Hook scripts cs ships; deployed to ~/.claude/hooks/cs/ and registered in
# settings.json.
CS_HOOKS=(
    session-start.sh
    autosave-commits.sh
    narrative-reminder.sh
    session-end.sh
    subagent-context.sh
    tool-failure-logger.sh
    session-auto-approve.sh
    bash-logger.sh
    scope-prompt.sh
)

# Files under hooks/ that the hooks source, or that cs points other tools at,
# rather than files Claude Code invokes as hooks. Deployed and removed alongside
# the hooks, never registered against an event. The prompt-rewriter scripts are
# reached through $EDITOR, not through any hook event.
CS_HOOK_LIBS=(
    cs-resolve.sh
    cs-shared.sh
    cs-iterm-tab.py
    prompt-rewriter.sh
    prompt-rewriter-model.sh
    prompt-rewriter-vendor.sh
)

# Slash commands earlier versions deployed to ~/.claude/commands/. cs ships
# none now: they became skills of the same name, the one format every engine
# reads. install.sh and run_uninstall delete these files; a command left
# beside its skill would answer the same /name twice.
RETIRED_COMMANDS=(
    summary.md
    checkpoint.md
    sweep.md
    wrap.md
)

# Skills cs ships; each deploys as <skills dir>/<name>/SKILL.md, for Claude
# under ~/.claude/skills and for Codex under $CODEX_HOME/skills (default
# ~/.codex/skills). Both engines get the same files.
CS_SKILLS=(
    store-secret
    prose-hygiene
    rotate
    switch
    finish
    feature
    write-as-me
    checkpoint
    summary
    sweep
    wrap
)

# Skills retired or renamed in past versions but possibly still installed from
# older cs versions. install.sh and run_uninstall both delete these directories.
# When retiring or renaming a skill in a release, add its OLD name here: a skill
# directory left behind keeps answering its slash command forever, and nothing
# else ever removes it.
#
# Only the Claude skills directory is swept. Every name below retired before
# cs deployed skills to Codex, so in a Codex skills directory it can only be
# the user's own skill. A skill retired after shipping to Codex must also be
# removed from there.
#
# Do not add a doctor row for a leftover directory; it cannot report one. The
# only cs that could still hold it is one older than the retirement, and that cs
# has no entry here to check against; the upgrade that gives it the entry is the
# same install that deletes the directory. So the row would warn about a state
# it can never observe.
RETIRED_SKILLS=(
    voice   # renamed to write-as-me; Claude Code 2.1.227 ships a built-in /voice (Toggle voice mode)
    merge   # replaced by finish: integrate and report, never remove
    cs-hint # a mod (deployed under skills/ like every mod): the hint line under the prompt, retired
    cs-rotate # a mod: renamed to cs, cs's in-session mod (the rotate band, forced rotation, the wrap key)
)

# Support files skills ship beyond SKILL.md, as skills/<skill>/<path> entries.
# Files under scripts/ are executables; agents/openai.yaml is Codex's
# per-skill settings, which Claude ignores.
CS_SKILL_FILES=(
    write-as-me/scripts/build-corpus.sh
    finish/scripts/finish.sh
    finish/agents/openai.yaml   # Codex ignores disable-model-invocation; this is its switch
    switch/agents/openai.yaml   # the same switch for the switch skill: run only when the user asks
    sweep/scripts/memory-index-guard.sh
    sweep/scripts/cs-shared.sh  # build.sh's copy of hooks/cs-shared.sh, which the guard sources
)

# Mods cs ships: Claude Code function-hooks plugins, deployed file by file as
# ~/.claude/skills/<mod>/<path> (the mod's bun tests stay in the checkout).
CS_MOD_FILES=(
    cs/.claude-plugin/plugin.json
    cs/hooks/hooks.json
    cs/hooks/register.tsx
    cs-update/.claude-plugin/plugin.json
    cs-update/hooks/hooks.json
    cs-update/hooks/register.tsx
)

# Remove a hook registration from any event in a settings JSON string,
# matching either path spelling; drops wrappers that empty out. Prints the
# updated JSON.
_strip_hook_registration() {
    local settings="$1" p="$2" t="$3"
    echo "$settings" | jq --arg p "$p" --arg t "$t" '
        if .hooks then
            .hooks |= with_entries(
                .value |= (
                    map(.hooks |= map(select(.command != $p and .command != $t)))
                    | map(select(.hooks | length > 0))
                )
            )
        else . end
    '
}

# The SessionStart hook cs registers for Codex: Codex runs the command through
# a shell, so a path outside the plain-word alphabet is single-quoted.
_codex_hook_command() {  # cs_path
    case "$1" in
        *[!A-Za-z0-9_./+-]*)
            printf "'%s' -codex-hook session-start" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s -codex-hook session-start' "$1" ;;
    esac
}

# Codex skips a hook, silently, until config.toml trusts it: a table
# [hooks.state."<hooks.json path>:session_start:<group>:<handler>"] holding the
# sha256 of the handler group's definition, as compact sorted-key JSON with
# Codex's defaults filled in. cs writes that hash in the same step that
# registers its hook, so the hook runs without a review prompt.
_codex_hook_trust_hash() {  # command, [matcher as JSON]
    local json
    json=$(jq -ncS --arg c "$1" --argjson matcher "${2:-null}" \
        '{event_name: "session_start", hooks: [{async: false, command: $c, timeout: 600, type: "command"}]}
         + (if $matcher == null then {} else {matcher: $matcher} end)' \
        | tr -d '\n') || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$json" | sha256sum | cut -c1-64
    else
        printf '%s' "$json" | shasum -a 256 | cut -c1-64
    fi
}

# A config.toml rewrite: drop the trust table for each listed key, then rename
# trust tables past a removed group or handler down by one index. shift_from
# is a group index, group:handler for a handler removal, or empty for none.
_codex_trust_tables_edit() {  # config, hooks_file, shift_from, keys...
    local config="$1" file="$2" shift_from="$3" tmp
    shift 3
    [ -f "$config" ] || return 0
    tmp=$(mktemp "$config.cs.XXXXXX") || return 1
    awk -v prefix="[hooks.state.\"$file:session_start:" -v shift_from="$shift_from" -v drops="$(printf '%s\n' "$@")" '
        BEGIN {
            shift_parts = split(shift_from, removed, ":")
            n = split(drops, list, "\n")
            for (i = 1; i <= n; i++) if (list[i] != "") drop["[hooks.state.\"" list[i] "\"]"] = 1
        }
        # Blank lines wait for the next line that survives, so a dropped table
        # takes its separating blank with it and trailing blanks never pile up.
        /^[[:space:]]*$/ { if (!skip) blanks++; next }
        $0 in drop { skip = 1; next }
        skip && /^[[:space:]]*\[/ { skip = 0 }
        skip { next }
        { while (blanks > 0) { print ""; blanks-- } }
        shift_from != "" && index($0, prefix) == 1 {
            rest = substr($0, length(prefix) + 1)
            split(rest, parts, ":")
            handler = parts[2]; sub(/"\].*$/, "", handler)
            if (shift_parts == 2 && parts[1] == removed[1] && handler ~ /^[0-9]+$/ && handler + 0 > removed[2] + 0) {
                print prefix parts[1] ":" (handler - 1) substr(parts[2], length(handler) + 1)
                next
            }
            if (shift_parts == 1 && parts[1] ~ /^[0-9]+$/ && parts[1] + 0 > shift_from + 0) {
                print prefix (parts[1] - 1) substr(rest, length(parts[1]) + 1)
                next
            }
        }
        { print }
    ' "$config" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
}

# Index of cs's own SessionStart group in a hooks.json document, or nothing.
_codex_hook_group_index() {  # hooks.json content
    printf '%s' "$1" | jq -r '
        [(.hooks.SessionStart // [])
         | to_entries[]
         | select(any(.value.hooks[]?; (.command // "") | endswith(" -codex-hook session-start")))
         | .key] | first // empty'
}

# Index of cs's handler inside its SessionStart group.
_codex_hook_handler_index() {  # hooks.json content, group index
    printf '%s' "$1" | jq -r --argjson i "$2" '
        [.hooks.SessionStart[$i].hooks | to_entries[]
         | select((.value.command // "") | endswith(" -codex-hook session-start"))
         | .key] | first // empty'
}

# Register cs's SessionStart hook in <codex_dir>/hooks.json and trust it in
# <codex_dir>/config.toml. A reinstall replaces only cs's handler in place;
# a first install appends a group. User handlers and group matchers keep their
# positions and trust. A hooks.json that is not valid JSON is left alone.
_codex_hooks_register() {  # codex_dir, command
    local dir="$1" cmd="$2" file="$1/hooks.json" config="$1/config.toml"
    local doc index handler=0 matcher tmp hash key
    case "$file" in *'"'*|*\\*) return 1 ;; esac
    if [ -f "$file" ]; then
        doc=$(cat "$file") || return 1
        printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
    else
        doc='{}'
    fi
    index=$(_codex_hook_group_index "$doc")
    if [ -n "$index" ]; then
        handler=$(_codex_hook_handler_index "$doc" "$index") || return 1
    fi
    doc=$(printf '%s' "$doc" | jq --arg c "$cmd" --arg i "$index" --argjson h "$handler" '
        {type: "command", command: $c} as $ours
        | .hooks = (.hooks // {})
        | .hooks.SessionStart = (.hooks.SessionStart // [])
        | if $i == "" then .hooks.SessionStart += [{hooks: [$ours]}]
          else .hooks.SessionStart[($i | tonumber)].hooks[$h] = $ours end') || return 1
    [ -n "$index" ] || index=$(printf '%s' "$doc" | jq '.hooks.SessionStart | length - 1')
    matcher=$(printf '%s' "$doc" | jq -c --argjson i "$index" '.hooks.SessionStart[$i].matcher // null') || return 1
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$file.cs.XXXXXX") || return 1
    printf '%s\n' "$doc" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    hash=$(_codex_hook_trust_hash "$cmd" "$matcher") || return 1
    key="$file:session_start:$index:$handler"
    _codex_trust_tables_edit "$config" "$file" "" "$key" || return 1
    [ -f "$config" ] || { : > "$config" && chmod 600 "$config"; } || return 1
    if [ -s "$config" ]; then printf '\n' >> "$config" || return 1; fi
    printf '[hooks.state."%s"]\ntrusted_hash = "sha256:%s"\n' "$key" "$hash" >> "$config"
}

# Remove only cs's handler, and its group if empty. Trust follows the remaining
# handlers or groups as their indices move. Remove an empty hooks.json.
_codex_hooks_unregister() {  # codex_dir
    local dir="$1" file="$1/hooks.json" config="$1/config.toml" doc index handler shift_from count tmp
    [ -f "$file" ] || return 0
    doc=$(cat "$file") || return 1
    index=$(_codex_hook_group_index "$doc" 2>/dev/null) || return 1
    [ -n "$index" ] || return 0
    handler=$(_codex_hook_handler_index "$doc" "$index") || return 1
    count=$(printf '%s' "$doc" | jq --argjson i "$index" '.hooks.SessionStart[$i].hooks | length') || return 1
    shift_from="$index:$handler"
    [ "$count" != 1 ] || shift_from="$index"
    doc=$(printf '%s' "$doc" | jq --argjson i "$index" --argjson h "$handler" '
        del(.hooks.SessionStart[$i].hooks[$h])
        | if .hooks.SessionStart[$i].hooks == [] then del(.hooks.SessionStart[$i]) else . end
        | if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end
        | if .hooks == {} then del(.hooks) else . end') || return 1
    if [ "$doc" = '{}' ]; then
        rm -f "$file" || return 1
    else
        tmp=$(mktemp "$file.cs.XXXXXX") || return 1
        printf '%s\n' "$doc" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    fi
    _codex_trust_tables_edit "$config" "$file" "$shift_from" "$file:session_start:$index:$handler"
}

# Codex draws the bar under its prompt from [tui] status_line in config.toml,
# and its default bar leaves out the context and the 5-hour and weekly limits.
# This line is the Codex side of cs-statusline: install.sh and cs -statusline
# enable add it where config.toml has no status line, a status line the user
# wrote stays theirs, and cs -statusline disable and cs -uninstall take back
# only this exact line. A change to the list must still recognise this one.
CS_CODEX_STATUS_LINE='status_line = ["project-name", "git-branch", "model-with-reasoning", "task-progress", "context-used", "five-hour-limit", "weekly-limit"]'

# config.toml read line by line the way a TOML parser places each line: a
# header opens a table unless it sits inside a multi-line string or array.
# The first pass finds [tui] and the status line; MODE then decides:
#   state  print none (no status line), cs (cs's line), own (the user's), or
#          by-hand (tui as an inline table or dotted keys, which a [tui]
#          header added after them would define twice)
#   set    the config with cs's line at the top of [tui], or with a [tui]
#          table of its own before the first table (at the end when there
#          is none): cs's Codex hook re-appends its trust table on every
#          install, and a [tui] after it would move each time
#   unset  the config without cs's line, and without the [tui] header when
#          nothing else is left in that table
# shellcheck disable=SC2016  # awk program, expanded by awk
_codex_status_line_awk='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# Count brackets outside strings and comments, and notice a multi-line string.
function scan(s,    i, j, c, q) {
    q = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "" && (substr(s, i, 3) == "\"\"\"" || substr(s, i, 3) == "\047\047\047")) {
            j = index(substr(s, i + 3), substr(s, i, 3))
            if (j == 0) { ml = substr(s, i, 3); return }
            i += j + 4; continue
        }
        if (q != "") { if (c == "\\" && q == "\"") { i++; continue } if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; continue }
        if (c == "#") return
        if (c == "[") depth++
        else if (c == "]") depth--
    }
}
FNR == 1 { pass++ }
pass == 1 {
    lines = FNR
    if (ml != "") { if (index($0, ml)) ml = ""; next }
    if (depth == 0 && $0 ~ /^[ \t]*\[/) {
        table = $0; sub(/^[ \t]*\[\[?/, "", table); sub(/\]\]?[ \t]*(#.*)?$/, "", table); table = trim(table)
        if (table == "tui" && !tui) tui = FNR
        if (!head) head = FNR
        next
    }
    if (depth == 0) {
        if (table == "tui" && $0 ~ /^[ \t]*status_line[ \t]*=/) {
            if (trim($0) == OURS) ours = FNR; else own = 1
        } else if (table == "" && $0 ~ /^[ \t]*tui[ \t]*\.[ \t]*status_line[ \t]*=/) own = 1
        else if (table == "" && $0 ~ /^[ \t]*tui[ \t]*[.=]/) byhand = 1
        if (table == "tui" && FNR != ours && $0 !~ /^[ \t]*$/) others++
    }
    scan($0)
    next
}
MODE == "set" {
    if (!tui && FNR == head) { print "[tui]"; print OURS; print "" }
    print; if (FNR == tui) print OURS; last = $0; next
}
MODE == "unset" {
    if (FNR == ours) next
    # Blank lines wait for the next line that survives, so a dropped [tui]
    # at the end takes the blank line before it along.
    if ($0 ~ /^[ \t]*$/) { if (!dropping) held++; next }
    if (FNR == tui && !others) { dropping = 1; next }
    dropping = 0
    while (held > 0) { print ""; held-- }
    print
}
END {
    if (MODE == "state") print (ours ? "cs" : own ? "own" : byhand ? "by-hand" : "none")
    if (MODE == "set" && !tui && !head) {
        if (lines && last !~ /^[ \t]*$/) print ""
        print "[tui]"; print OURS
    }
    if (MODE == "unset" && !dropping) while (held > 0) { print ""; held-- }
}'

_codex_status_line_state() {  # config
    [ -f "$1" ] || { echo none; return 0; }
    awk -v MODE=state -v OURS="$CS_CODEX_STATUS_LINE" "$_codex_status_line_awk" "$1"
}

# With a Python that has tomllib (3.11+), an edit must leave TOML that Codex
# reads with cs's list as [tui] status_line (set) or none there (unset).
# Without one there is nothing to check against.
_codex_status_line_check() {  # set|unset, file
    local py
    for py in python3 /usr/bin/python3; do
        command -v "$py" >/dev/null 2>&1 || continue
        "$py" -I -c 'import tomllib' 2>/dev/null || continue
        "$py" -I -c '
import sys, tomllib
mode, path, line = sys.argv[1:]
try:
    with open(path, "rb") as f:
        tui = tomllib.load(f).get("tui", {})
    want = tomllib.loads(line)["status_line"]
except Exception:
    sys.exit(1)
sys.exit(0 if (tui.get("status_line") == want if mode == "set" else "status_line" not in tui) else 1)
' "$1" "$2" "$CS_CODEX_STATUS_LINE"
        return
    done
    return 0
}

_codex_status_line_edit() {  # set|unset, config
    local tmp
    tmp=$(mktemp "$2.cs.XXXXXX") || return 2
    awk -v MODE="$1" -v OURS="$CS_CODEX_STATUS_LINE" "$_codex_status_line_awk" "$2" "$2" > "$tmp" \
        && _codex_status_line_check "$1" "$tmp" && mv "$tmp" "$2" || { rm -f "$tmp"; return 2; }
}

# Add cs's status line to <codex_dir>/config.toml where it has none.
# 0 added; 1 left as it is, with the state found on stdout (cs, own or
# by-hand); 2 the write failed.
_codex_status_line_add() {  # codex_dir
    local config="$1/config.toml" state
    state=$(_codex_status_line_state "$config") || return 2
    [ "$state" = none ] || { printf '%s\n' "$state"; return 1; }
    [ -f "$config" ] || { : > "$config" && chmod 600 "$config"; } || return 2
    _codex_status_line_edit set "$config"
}

# Take cs's status line back out of <codex_dir>/config.toml. 0 removed; 1
# not cs's, with the state found on stdout (none, own or by-hand); 2 the
# write failed.
_codex_status_line_remove() {  # codex_dir
    local config="$1/config.toml" state
    state=$(_codex_status_line_state "$config") || return 2
    [ "$state" = cs ] || { printf '%s\n' "$state"; return 1; }
    _codex_status_line_edit unset "$config"
}

# The Claude Code keybindings cs offers to add. Ctrl+X R and Ctrl+X W are
# "command:<name>" actions, which submit /<name>. Ctrl+X 1 and Ctrl+X 2 are
# the engine actions the cs mod's band Buttons answer to, so they press the
# band's rotate (or /clear) and wrap keys (KEEP IN SYNC with ROTATE_ACTION
# and WRAP_ACTION in mods/cs/hooks/register.tsx). install.sh asks once per
# machine and binds them, cs -uninstall takes back only the keys that still
# hold these values, and cs -doctor reports them.
CS_ROTATE_WRAP_KEYS='{"ctrl+x r":"command:rotate","ctrl+x w":"command:wrap","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}'

# Option+1 and Option+2 on the same two commands, as cs 2026.10.6 bound them.
# iTerm2 selects panes with Option+number, so there they never reach Claude
# Code. Wherever they still hold these values, an install that binds the
# chords takes them back, and so does cs -uninstall.
# shellcheck disable=SC2034  # read by install.sh's _bind_rotate_wrap_keys, cs -uninstall and cs -doctor
CS_RETIRED_OPTION_KEYS='{"alt+1":"command:rotate","alt+2":"command:wrap"}'

# The jq definitions shared by the filters below. keynorm follows Claude
# Code's key parser (2.1.291) as far as the keys cs compares need: case
# ignored, control is ctrl, opt and option are alt, command, super and win
# are cmd, esc, return and del are escape, enter and delete, modifiers in
# any order, and a chord's keys split on any run of spaces. It keeps meta
# apart from alt and leaves space and arrow glyphs as typed, which no cs key
# uses. cs's own keys are already in that form. ours: whether a to_entries pair from a context block is one of
# the bindings in $cs, key and value both.
_CS_KEYBINDING_DEFS='
    def keynorm:
        ["alt", "cmd", "ctrl", "meta", "shift"] as $mods
        | [splits("\\s+") | select(length > 0) | ascii_downcase | split("+")
            | map({"control": "ctrl", "opt": "alt", "option": "alt", "command": "cmd",
                   "super": "cmd", "win": "cmd", "esc": "escape", "return": "enter",
                   "del": "delete"}[.] // .)
            | ([.[] | select(. as $p | any($mods[]; . == $p))] | unique)
              + [.[] | select(. as $p | any($mods[]; . == $p) | not)]
            | join("+")]
        | join(" ");
    def ours: . as $e | ($e.key | keynorm) as $k | $cs | has($k) and .[$k] == $e.value;
'

# Claude Code reads its keybindings from its config dir. Inside an encrypted
# session that dir is the session's .cs/claude-config, which no other session
# reads; it links the shell's keybindings.json instead, so cs's keys belong in
# the shell's config dir, which launch records in
# CLAUDE_SECURESTORAGE_CONFIG_DIR (empty for ~/.claude).
_cs_keybindings_file() {
    local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    case "$dir" in
        */.cs/claude-config) dir="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-$HOME/.claude}" ;;
    esac
    printf '%s\n' "$dir/keybindings.json"
}

# This machine's answer to the installer's question, yes or no; absent until
# it has been asked on a terminal. The file keeps the name it had when the
# keys were Option+1 / Option+2, so a machine that said yes then gets the
# chords on its next install.
_cs_rotate_wrap_keys_answer_file() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cs/option-keys"
}

# Whether a keybindings file has the shape cs reads and merges into: one JSON
# object whose "bindings" is an array of context blocks, each an object whose
# own "bindings", when present, is an object. Slurped, so a file holding two
# documents is refused rather than read as two; -e turns invalid JSON, an
# empty file and a false answer alike into a non-zero exit.
_cs_keybindings_shape_ok() {  # file
    jq -se 'length == 1 and (.[0] | type == "object" and (.bindings | type == "array")
        and all(.bindings[]; type == "object" and ((.bindings // {}) | type == "object")))' \
        "$1" > /dev/null 2>&1
}

# Reads a keybindings document that passed the shape check on stdin and prints
# one line per cs key: "bound<TAB>key" when every binding of it, in any
# context, holds cs's value; "free<TAB>key" when nothing binds it; and
# "conflict<TAB>key<TAB>action" when something else does. A chord also
# conflicts when its first key is bound on its own to an action, which
# Claude Code would stop reaching once it waits for the chord's second key:
# "conflict<TAB>key<TAB>action<TAB>prefix". Keys compare as keynorm spells
# them. An action that is not a non-empty string (a null that unbinds the
# key, an empty "") prints as JSON, so no field is ever empty; a null on the
# prefix is no conflict, as it binds nothing.
_cs_rotate_wrap_keys_status() {
    jq -r --argjson cs "$CS_ROTATE_WRAP_KEYS" "$_CS_KEYBINDING_DEFS"'
        def show: if type == "string" and length > 0 then . else tojson end;
        [.bindings[] | (.bindings // {}) | to_entries[] | .key |= keynorm] as $all
        | $cs | to_entries[] | . as $c
        | [$all[] | select(.key == $c.key) | .value] as $vals
        | ($c.key | split(" ") | if length > 1 then .[0] else null end) as $prefix
        | [$all[] | select(.key == $prefix and .value != null) | .value] as $pvals
        | if any($vals[]; . != $c.value) then
            "conflict\t\($c.key)\t\([$vals[] | select(. != $c.value)][0] | show)"
          elif ($pvals | length) > 0 then "conflict\t\($c.key)\t\($pvals[0] | show)\t\($prefix)"
          elif ($vals | length) == 0 then "free\t\($c.key)"
          else "bound\t\($c.key)"
          end'
}

# Prints, comma-separated, the keys of a keybindings document on stdin that
# hold one of the bindings in the JSON object $1, spelled as the file spells
# them; empty when none does.
_cs_keybindings_held() {  # bindings-json
    jq -r --argjson cs "$1" "$_CS_KEYBINDING_DEFS"'
        [.bindings[] | (.bindings // {}) | to_entries[] | select(ours) | .key] | unique | join(", ")'
}

# Prints a keybindings document on stdin, compact, without the bindings in the
# JSON object $1 (key and value both; a key bound to anything else stays). A
# Global block left empty goes; another context keeps its block.
_cs_keybindings_strip() {  # bindings-json
    jq -c --argjson cs "$1" "$_CS_KEYBINDING_DEFS"'
        .bindings |= map(
            if any((.bindings // {}) | to_entries[]; ours) then
                .bindings |= with_entries(select(ours | not))
                | select(.bindings != {} or .context != "Global")
            else . end)'
}
