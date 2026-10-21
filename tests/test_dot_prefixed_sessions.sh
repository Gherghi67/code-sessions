#!/usr/bin/env bash
# ABOUTME: Tests that the sessions-root scans see a dot-prefixed session (one named before
# ABOUTME: leading dots were refused): cs -usage reads its rate-limit stamp, cs -search its files.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# The newest rate-limit stamp wins the -usage header, whichever session holds
# it. A plain session holds an older stamp, as the positive control: its pct
# is the one shown whenever the dotted session is skipped.
test_usage_reads_the_limits_of_a_dot_prefixed_session() {
    local now
    now=$(date +%s)
    mkdir -p "$CS_SESSIONS_ROOT/.work/.cs/local" "$CS_SESSIONS_ROOT/plain/.cs/local"
    cat > "$CS_SESSIONS_ROOT/plain/.cs/local/limits" << EOF
five_hour_used_pct: 11
five_hour_resets_at: $((now + 3600))
seven_day_used_pct: 12
seven_day_resets_at: $((now + 86400))
stamped_at: $((now - 60))
EOF
    cat > "$CS_SESSIONS_ROOT/.work/.cs/local/limits" << EOF
five_hour_used_pct: 62
five_hour_resets_at: $((now + 3600))
seven_day_used_pct: 41
seven_day_resets_at: $((now + 86400))
stamped_at: $now
EOF
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    assert_output_contains "$output" "5h 62%" "the dotted session's newer 5h pct heads the table" || return 1
    assert_output_contains "$output" "week 41%" "the dotted session's newer week pct heads the table" || return 1
}

test_search_finds_a_match_in_a_dot_prefixed_session() {
    mkdir -p "$CS_SESSIONS_ROOT/.work/.cs/memory" "$CS_SESSIONS_ROOT/plain/.cs/memory"
    printf '# Session: .work\n\nzebra-needle in the dotted session\n' > "$CS_SESSIONS_ROOT/.work/.cs/README.md"
    printf '# Session: plain\n\nzebra-needle in the plain session\n' > "$CS_SESSIONS_ROOT/plain/.cs/README.md"
    local output
    output=$("$CS_BIN" -search zebra-needle 2>&1) || true
    assert_output_contains "$output" "zebra-needle in the plain session" "positive control: the plain session matches" || return 1
    assert_output_contains "$output" "zebra-needle in the dotted session" "the dotted session matches too" || return 1
}

echo ""
echo "Dot-prefixed sessions in sessions-root scans"
echo "============================================"
echo ""

run_test test_usage_reads_the_limits_of_a_dot_prefixed_session
run_test test_search_finds_a_match_in_a_dot_prefixed_session

report_results
