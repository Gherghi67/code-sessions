#!/usr/bin/env bash
# ABOUTME: Tests for session wrap-up cues block in the session protocol file
# ABOUTME: Validates new-session insertion, lazy migration, and tombstone opt-out

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN 2>/dev/null || true
}

# ============================================================================
# A1: new-session CLAUDE.md includes the wrap-cues block
# ============================================================================

test_new_session_has_wrap_cues_block() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true

    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.local.md"

    assert_file_exists "$claude_md" "session CLAUDE.local.md should exist" || return 1
    assert_file_contains "$claude_md" "cs:wrap-cues" \
        "CLAUDE.local.md should contain the cs:wrap-cues sentinel" || return 1
    assert_file_contains "$claude_md" "Session wrap-up cues" \
        "CLAUDE.local.md should contain the section header" || return 1
    assert_file_contains "$claude_md" "AskUserQuestion" \
        "block should instruct Claude to use AskUserQuestion" || return 1
    assert_file_contains "$claude_md" "/wrap" \
        "block should reference the /wrap combo command" || return 1
}

# Build a "legacy" session whose CLAUDE.md predates the wrap-cues block.
_seed_legacy_session_wrap() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: 2026-01-01
tags: []
aliases: ["$name"]
---
# Session: $name
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    # Legacy CLAUDE.md: a .cs/-referencing head with no sentinel of its own,
    # followed by a cs:memory-rules sentinel with header but no cs:wrap-cues.
    # Phase 5 extracts everything from the first sentinel onward into
    # CLAUDE.local.md, leaving the head in CLAUDE.md; Phase 9 then retires
    # the memory-rules block there into a memory-note, and Phase 10 appends
    # wrap-cues there since none exists yet.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
## Auto-memory bucket guidance

Stub — pretend the full bucket table lives here. The sentinel is what matters for migration short-circuits.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    echo "$session_dir"
}

# ============================================================================
# A2: lazy migration appends wrap-cues to legacy CLAUDE.md (idempotent)
# ============================================================================

test_lazy_migration_appends_wrap_cues() {
    local session_dir
    session_dir=$(_seed_legacy_session_wrap "legacy-wrap")

    assert_file_not_contains "$session_dir/CLAUDE.md" "cs:wrap-cues" \
        "precondition: legacy CLAUDE.md should lack cs:wrap-cues sentinel" || return 1

    "$CS_BIN" legacy-wrap <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/CLAUDE.md" "Session Documentation Protocol" \
        "the head above the sentinel stays in CLAUDE.md" || return 1
    assert_file_contains "$session_dir/CLAUDE.local.md" "cs:wrap-cues" \
        "Phase 10 migration should append the sentinel" || return 1
    assert_file_contains "$session_dir/CLAUDE.local.md" "Session wrap-up cues" \
        "appended block should include the section header" || return 1
}

test_lazy_migration_wrap_cues_idempotent() {
    local session_dir
    session_dir=$(_seed_legacy_session_wrap "legacy-wrap")

    "$CS_BIN" legacy-wrap <<< "" >/dev/null 2>&1 || true
    local first_size
    first_size=$(wc -c < "$session_dir/CLAUDE.local.md" | tr -d ' ')

    "$CS_BIN" legacy-wrap <<< "" >/dev/null 2>&1 || true
    local second_size
    second_size=$(wc -c < "$session_dir/CLAUDE.local.md" | tr -d ' ')

    assert_eq "$first_size" "$second_size" \
        "second migration should not change CLAUDE.local.md size" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:wrap-cues -->' "$session_dir/CLAUDE.local.md")
    assert_eq "1" "$sentinel_count" \
        "HTML sentinel must appear exactly once after repeated migrations" || return 1
}

# ============================================================================
# Tombstone opt-out — sentinel present without block content prevents re-add
# ============================================================================

test_wrap_cues_opt_out_respected() {
    local name="opted-out-wrap"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: 2026-01-01
tags: []
aliases: ["$name"]
---
# Session: $name
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    # User deleted the wrap-cues content but kept the tombstone sentinel.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
Memory-rules content stub.

<!-- cs:wrap-cues -->
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m init)

    assert_file_contains "$session_dir/CLAUDE.md" '<!-- cs:wrap-cues -->' \
        "precondition: tombstone sentinel must be present" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "Session wrap-up cues" \
        "precondition: opted-out CLAUDE.md must lack the section header" || return 1

    "$CS_BIN" opted-out-wrap <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/CLAUDE.md" "Session Documentation Protocol" \
        "the head above the sentinel stays in CLAUDE.md" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.local.md" "Session wrap-up cues" \
        "tombstone sentinel must prevent re-addition of the block" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:wrap-cues -->' "$session_dir/CLAUDE.local.md")
    assert_eq "1" "$sentinel_count" \
        "tombstone sentinel must not duplicate" || return 1
}

# The cue block of file $1: its sentinel through its opt-out line.
_cue_block() {  # file
    awk '/^<!-- cs:wrap-cues -->$/ { p = 1 } p { print } p && /^To opt out, delete the prose above/ { exit }' "$1"
}

# The options the cue block of file $1 offers: the lines under "**When fired**".
_cue_options() {  # file
    awk '/^\*\*When fired\*\*/ { p = 1; next } p && /^$/ { exit } p { print }' "$1"
}

# Replace the cue block of file $1 with the text on stdin.
_splice_cue_block() {  # file
    local block
    block=$(cat)
    BLOCK="$block" awk '
        /^<!-- cs:wrap-cues -->$/ { print ENVIRON["BLOCK"]; skip = 1; next }
        skip && /^To opt out, delete the prose above/ { skip = 0; next }
        !skip { print }
    ' "$1" > "$1.splice" && mv "$1.splice" "$1"
}

# Replace the line of file $1 that opens "When the session is complete" with $2.
_splice_wrap_line() {  # file, line
    LINE="$2" awk '/^When the session is complete, / { print ENVIRON["LINE"]; next } { print }' "$1" > "$1.splice" \
        && mv "$1.splice" "$1"
}

# A new session named $1; its CLAUDE.local.md as cs writes it is copied to
# $TEST_TMPDIR/$1.fresh. Prints the session directory.
_fresh_session() {  # name
    "$CS_BIN" "$1" <<< "" >/dev/null 2>&1 || true
    cp "$CS_SESSIONS_ROOT/$1/CLAUDE.local.md" "$TEST_TMPDIR/$1.fresh"
    echo "$CS_SESSIONS_ROOT/$1"
}

# Open session $1 with every one-time migration phase due: without the stamp
# an open runs them all, as the first open under a new cs version does.
_reopen_with_migration() {  # name
    rm -f "$CS_SESSIONS_ROOT/$1/.cs/local/migrated"
    "$CS_BIN" "$1" <<< "" >/dev/null 2>&1 || true
}

# The cue block cs wrote from 2026-05-12, offering four options.
_cue_block_with_triggers() {
    cat << 'EOF'
<!-- cs:wrap-cues -->
## Session wrap-up cues

When the conversation reaches a natural stopping point — work shipped, a PR merged, a deploy completed, a bug fixed, or the user signaling they're winding down — proactively offer to distill the session via AskUserQuestion BEFORE the conversation drifts.

**Strong triggers (fire on any single occurrence):**
- "shipped", "PR merged", "PR up", "deployed", "released"
- "let's call it", "wraps up", "done for the day", "good place to stop"
- "all good now", "that did it", "ready to ship"

**Soft triggers (require a corroborating signal — a recent commit, an explicit "done", or two or more soft signals in succession):**
- "that works", "looks good", "we're good", "all set"

**When fired**, use AskUserQuestion with header "Wrap up?" and these options:
- "Run /wrap" — distill memory entries AND write a session summary in sequence (the usual choice)
- "Run /sweep only" — just the memory pass; skip the narrative summary
- "Run /summary only" — just the narrative; skip the memory pass
- "Not yet — keep working"

Do not fire on every short affirmative ("yes", "ok", "thanks"). Fire when the *work itself* has reached a coherent stopping point, not when a single answer satisfied a single question. False positives erode the signal — be picky.

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
}

# The cue block cs wrote from 2026-07-07, offering the same four options.
_cue_block_with_signals() {
    cat << 'EOF'
<!-- cs:wrap-cues -->
## Session wrap-up cues

When the conversation reaches a natural stopping point — work shipped, a PR merged, a deploy completed, a bug fixed, or the user signaling they're winding down — proactively offer to distill the session via AskUserQuestion BEFORE the conversation drifts.

**Strong signals (sufficient on their own — but only when the phrase describes work that actually completed; never fire when it reports a problem, is negated, or is part of a plan for later):**
- "shipped", "PR merged", "PR up", "deployed", "released"
- "let's call it", "wraps up", "done for the day", "good place to stop"
- "all good now", "that did it", "ready to ship"

**Soft signals (require a corroborating signal — a recent commit, an explicit "done", or two or more soft signals in succession):**
- "that works", "looks good", "we're good", "all set"

**When fired**, use AskUserQuestion with header "Wrap up?" and these options:
- "Run /wrap" — distill memory entries AND write a session summary in sequence (the usual choice)
- "Run /sweep only" — just the memory pass; skip the narrative summary
- "Run /summary only" — just the narrative; skip the memory pass
- "Not yet — keep working"

Do not fire on every short affirmative ("yes", "ok", "thanks"). Fire when the *work itself* has reached a coherent stopping point, not when a single answer satisfied a single question. False positives erode the signal — be picky.

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
}

# The session protocol's /wrap line as cs wrote it from 2026-07-07, and as it
# wrote it from 2026-06-12 to 2026-07-06.
WRAP_LINE_WITH_CHECKPOINT='When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Use `/summary` for the narrative alone, or `/sweep` for the memory pass alone. Mid-session, use `/checkpoint <label>` to snapshot git state and the narrative — e.g. before a risky refactor or destructive operation, and after reaching a green milestone (tests passing, a feature working) — saved under .cs/checkpoints/.'
WRAP_LINE_SHORT='When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Use `/summary` for the narrative alone, or `/sweep` for the memory pass alone.'

# ============================================================================
# The cue offers /wrap or nothing, and no session text names /sweep or /summary
# ============================================================================

test_new_session_cue_offers_wrap_or_nothing() {
    local dir
    dir=$(_fresh_session cue-new)
    assert_eq "$(printf '%s\n' '- "Run /wrap" — distill memory entries AND write a session summary in sequence' '- "Not yet — keep working"')" \
        "$(_cue_options "$dir/CLAUDE.local.md")" "the options the cue offers" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" '/sweep' "no session text names /sweep" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" '/summary[^.]' "no session text names /summary" || return 1
}

# Phase 10 appends the same block the template writes, so a migrated session
# and a new one get the same wrap-up guidance.
test_appended_cue_block_matches_the_template() {
    local fresh migrated
    fresh=$(_fresh_session cue-template)
    migrated=$(_seed_legacy_session_wrap "legacy-wrap")
    "$CS_BIN" legacy-wrap <<< "" >/dev/null 2>&1 || true
    assert_eq "$(_cue_block "$fresh/CLAUDE.local.md")" "$(_cue_block "$migrated/CLAUDE.local.md")" \
        "the appended block is the template's" || return 1
}

# An open rewrites a four-option cue block cs wrote, either wording, to the
# block a new session gets, and changes nothing else; a second open changes
# nothing at all.
test_open_rewrites_each_four_option_cue_cs_wrote() {
    local v dir
    for v in triggers signals; do
        dir=$(_fresh_session "cue-$v")
        "_cue_block_with_$v" | _splice_cue_block "$dir/CLAUDE.local.md"
        _splice_wrap_line "$dir/CLAUDE.local.md" "$WRAP_LINE_WITH_CHECKPOINT"
        _reopen_with_migration "cue-$v"
        assert_eq "$(printf '%s\n' '- "Run /wrap" — distill memory entries AND write a session summary in sequence' '- "Not yet — keep working"')" \
            "$(_cue_options "$dir/CLAUDE.local.md")" "the $v block offers /wrap or nothing" || return 1
        cmp -s "$TEST_TMPDIR/cue-$v.fresh" "$dir/CLAUDE.local.md" \
            || { echo "  FAIL: the $v session's CLAUDE.local.md is not the new session's"; diff "$TEST_TMPDIR/cue-$v.fresh" "$dir/CLAUDE.local.md" | head -20; return 1; }
        cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/cue-$v.once"
        _reopen_with_migration "cue-$v"
        cmp -s "$TEST_TMPDIR/cue-$v.once" "$dir/CLAUDE.local.md" \
            || { echo "  FAIL: a second open changed the $v session's CLAUDE.local.md"; return 1; }
    done
}

# The /wrap line cs wrote before /checkpoint joined it loses the same sentence.
test_open_drops_the_sweep_and_summary_sentence_from_the_short_wrap_line() {
    local dir
    dir=$(_fresh_session cue-short)
    _splice_wrap_line "$dir/CLAUDE.local.md" "$WRAP_LINE_SHORT"
    _reopen_with_migration cue-short
    assert_file_contains "$dir/CLAUDE.local.md" '^When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (\.cs/summary\.md)\.$' \
        "the line keeps its /wrap sentence alone" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" '/sweep' "the line no longer names /sweep" || return 1
}

# A cue block or a /wrap line the user edited is theirs: an open leaves the
# file as it was.
test_open_leaves_an_edited_cue_and_wrap_line_alone() {
    local dir
    dir=$(_fresh_session cue-edited)
    _cue_block_with_signals | sed 's/^- "that works", "looks good", "we.re good", "all set"$/- "that works", "looks good", "ship it"/' \
        | _splice_cue_block "$dir/CLAUDE.local.md"
    assert_file_contains "$dir/CLAUDE.local.md" '"ship it"$' "precondition: the block carries the edit" || return 1
    _splice_wrap_line "$dir/CLAUDE.local.md" 'When the session is complete, use the `/wrap` command. Use `/summary` for the narrative alone, or `/sweep` for memory.'
    cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/cue-edited.seeded"
    _reopen_with_migration cue-edited
    cmp -s "$TEST_TMPDIR/cue-edited.seeded" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: an open changed the edited CLAUDE.local.md"; diff "$TEST_TMPDIR/cue-edited.seeded" "$dir/CLAUDE.local.md" | head -20; return 1; }
}

echo "Running test_wrap_cues.sh"
echo ""
run_test test_new_session_has_wrap_cues_block
run_test test_lazy_migration_appends_wrap_cues
run_test test_lazy_migration_wrap_cues_idempotent
run_test test_wrap_cues_opt_out_respected
run_test test_new_session_cue_offers_wrap_or_nothing
run_test test_appended_cue_block_matches_the_template
run_test test_open_rewrites_each_four_option_cue_cs_wrote
run_test test_open_drops_the_sweep_and_summary_sentence_from_the_short_wrap_line
run_test test_open_leaves_an_edited_cue_and_wrap_line_alone
report_results
