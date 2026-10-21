# ABOUTME: cs -conversations: the session's conversation chain from timeline.jsonl.
# ABOUTME: Renders started/rotated events with lineage arrows in local time.

run_conversations() {
    [ $# -eq 0 ] || error "Usage: cs -conversations"
    if [ -z "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}" ]; then
        error "cs -conversations must be run inside a cs session, or as: cs <session> -conversations"
    fi
    local timeline="${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/timeline.jsonl"
    if [ ! -s "$timeline" ]; then
        echo "No conversation history recorded."
        return 0
    fi
    local current_claude current_codex session_dir
    session_dir="${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/.."
    current_claude=$(cs_binding_read "$session_dir" claude) || current_claude=""
    current_codex=$(cs_binding_read "$session_dir" codex) || current_codex=""
    # Old records have no engine and belong to Claude. Key by engine AND ID:
    # equal opaque native IDs from different engines are separate conversations.
    jq -rRs --arg claude "$current_claude" --arg codex "$current_codex" '
        def key: [.engine, .session_id] | tojson;
        def conversation_label($engine; $id): $engine + ":" + $id[0:8];
        def str_or_null: type == "string" or . == null;
        def well_typed: (.engine | str_or_null) and (.ts | str_or_null) and
            (if .event == "started"
             then (.session_id | type == "string") and (.source | str_or_null)
             else (.to | type == "string") and (.from | str_or_null)
                 and (.reason | str_or_null) and (.handoff | str_or_null) end);
        [split("\n") | to_entries[] | select(.value | length > 0)
         | {line: (.key + 1), e: (.value | fromjson? // empty)}
         | select((.e | type == "object") and (.e.event == "started" or .e.event == "rotated"))] as $all |
        ($all[] | select(.e | well_typed | not) | "W:\(.line)"),
        ([$all[] | select(.e | well_typed) | .e | .engine = (.engine // "claude")] as $ev |
        (reduce $ev[] as $e ({};
            if $e.event == "started"
            then .[$e | key] = (.[$e | key] // 0) + 1
            else . end)) as $n |
        (reduce $ev[] as $e ({seen: {}, out: []};
            if $e.event == "started" then
                ($e | key) as $k |
                if .seen[$k] then . else
                    .seen[$k] = true |
                    .out += [{ts: $e.ts,
                        txt: (conversation_label($e.engine; $e.session_id) + "  started (" + ($e.source // "?")
                            + (if ($n[$k] // 1) > 1
                               then ", resumed " + (($n[$k] - 1) | tostring) + "x"
                               else "" end)
                            + ")"
                            + (if ($e.engine == "claude" and $claude != "" and $e.session_id == $claude)
                                   or ($e.engine == "codex" and $codex != "" and $e.session_id == $codex)
                               then "  [current]" else "" end))}]
                end
            else
                .out += [{ts: $e.ts,
                    txt: ($e.engine + ":" + (if ($e.from // "") == "" then "?" else $e.from[0:8] end)
                        + " > " + ($e.to[0:8]) + "  rotated (" + ($e.reason // "?")
                        + (if ($e.handoff // "") != "" then ": " + $e.handoff else "" end)
                        + ")")}]
            end)).out[] |
        "O:" + (((.ts as $ts | try ($ts | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")) catch ($ts // "?"))
            + "  " + .txt) | explode
                | map(select(. == 9 or (. >= 32 and . != 127 and (. < 128 or . > 159))))
                | implode))
    ' "$timeline" | while IFS= read -r line; do
        case "$line" in
            W:*) warn "Skipped $timeline line ${line#W:}: a started or rotated record with a field of the wrong type" >&2 ;;
            O:*) printf '%s\n' "${line#O:}" ;;
        esac
    done
}
