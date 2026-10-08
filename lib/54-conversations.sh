# ABOUTME: cs -conversations: the session's conversation chain from timeline.jsonl.
# ABOUTME: Renders started/rotated events with lineage arrows in local time.

run_conversations() {
    [ $# -eq 0 ] || error "Usage: cs -conversations"
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -conversations must be run inside a cs session, or as: cs <session> -conversations"
    fi
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    if [ ! -s "$timeline" ]; then
        echo "No conversation history recorded."
        return 0
    fi
    local current
    current=$(_read_local_state "$CLAUDE_SESSION_META_DIR/local/state" claude_session_id)
    # One line per conversation's first started event (later starteds fold
    # into a resumed-count suffix); one line per rotated event. Torn or
    # foreign lines are skipped by the tolerant per-line parse. A started or
    # rotated record with a field of the wrong type is skipped too, but named
    # on stderr by its line number ("W:<n>"), so one bad record never empties
    # the listing. Every rendered line ("O:<text>") has its control characters
    # stripped (tab kept): the fields are recorded data, and an escape sequence
    # in one must not reach the terminal.
    local line
    jq -rRs --arg current "$current" '
        def str_or_null: type == "string" or . == null;
        def well_typed: (.ts | str_or_null) and
            (if .event == "started"
             then (.session_id | type == "string") and (.source | str_or_null)
             else (.to | type == "string") and (.from | str_or_null)
                 and (.reason | str_or_null) and (.handoff | str_or_null) end);
        [split("\n") | to_entries[] | select(.value | length > 0)
         | {line: (.key + 1), e: (.value | fromjson? // empty)}
         | select((.e | type == "object")
             and (.e.event == "started" or .e.event == "rotated"))] as $all |
        ($all[] | select(.e | well_typed | not) | "W:\(.line)"),
        ([$all[] | select(.e | well_typed) | .e] as $ev |
        (reduce $ev[] as $e ({};
            if $e.event == "started"
            then .[$e.session_id] = (.[$e.session_id] // 0) + 1
            else . end)) as $n |
        (reduce $ev[] as $e ({seen: {}, out: []};
            if $e.event == "started" then
                if .seen[$e.session_id] then . else
                    .seen[$e.session_id] = true |
                    .out += [{ts: $e.ts,
                        txt: ($e.session_id[0:8] + "  started (" + ($e.source // "?")
                            + (if ($n[$e.session_id] // 1) > 1
                               then ", resumed " + (($n[$e.session_id] - 1) | tostring) + "x"
                               else "" end)
                            + ")"
                            + (if $current != "" and $e.session_id == $current
                               then "  [current]" else "" end))}]
                end
            else
                .out += [{ts: $e.ts,
                    txt: ((if ($e.from // "") == "" then "?" else $e.from[0:8] end)
                        + " > " + ($e.to[0:8]) + "  rotated (" + ($e.reason // "?")
                        + (if ($e.handoff // "") != "" then ": " + $e.handoff else "" end)
                        + ")")}]
            end)).out[] |
        "O:" + (((.ts as $ts | try ($ts | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")) catch ($ts // "?"))
            + "  " + .txt) | gsub("[\\x00-\\x08\\x0a-\\x1f\\x7f-\\x9f]"; "")))
    ' "$timeline" | while IFS= read -r line; do
        case "$line" in
            W:*) warn "Skipped $timeline line ${line#W:}: a started or rotated record with a field of the wrong type" >&2 ;;
            O:*) printf '%s\n' "${line#O:}" ;;
        esac
    done
}
