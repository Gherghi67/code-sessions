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

# Replace each line of file $1 equal to $2 with $3.
_replace_line() {  # file, old, new
    OLD="$2" NEW="$3" awk '$0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next } { print }' "$1" > "$1.splice" \
        && mv "$1.splice" "$1"
}

# The Best Practices section as cs wrote it on either side of 2026-06-12: the
# two differ only in $1, the bullet naming the command to run at the end.
_best_practices_section() {  # run-bullet
    printf '%s\n' '' '## Best Practices' '' \
        "- Document discoveries as you find them - don't wait until the end" \
        '- Use .cs/artifacts/ for any reusable scripts or configs' \
        "$1" \
        '- Never write raw API keys or passwords to artifact files - use cs -secrets'
}

# A new session named $1; its CLAUDE.local.md as cs writes it is copied to
# $TEST_TMPDIR/$1.fresh. Prints the session directory.
_fresh_session() {  # name
    "$CS_BIN" "$1" <<< "" >/dev/null 2>&1 || true
    cp "$CS_SESSIONS_ROOT/$1/CLAUDE.local.md" "$TEST_TMPDIR/$1.fresh"
    echo "$CS_SESSIONS_ROOT/$1"
}

# Open session $1 with every one-time migration phase due: without the stamp
# an open runs them all, as the first open under a new cs version does. What
# the open prints goes to $TEST_TMPDIR/$1.out, and its exit status to
# $TEST_TMPDIR/$1.rc.
_reopen_with_migration() {  # name
    local rc=0
    rm -f "$CS_SESSIONS_ROOT/$1/.cs/local/migrated"
    "$CS_BIN" "$1" <<< "" > "$TEST_TMPDIR/$1.out" 2>&1 || rc=$?
    echo "$rc" > "$TEST_TMPDIR/$1.rc"
}

# Whether what the last open of session $1 printed has the whole line $2.
_open_printed() {  # name, line
    grep -Fxq -- "$2" "$TEST_TMPDIR/$1.out"
}

# The CLAUDE.md cs wrote for a new session, byte for byte, as four commits
# had it: 7d8542d4 (2025-12-01) and 71c37d13 (2026-02-06) wrote it with no cs
# sentinel; 4d377b5a (2026-05-12) opened its sentinels with cs:memory-rules;
# c7e37ecf (v2026.5.5, 2026-05-26) opened them with cs:memory-note.
FIXTURES="$SCRIPT_DIR/fixtures"

# A session named $1 laid out as the cs that wrote fixture $2 left it: that
# template as CLAUDE.md and no CLAUDE.local.md. CLAUDE.md is committed when $3
# is "commit", as cs did once sessions were git repositories. Prints the
# session directory.
_session_from_template() {  # name, fixture, commit|untracked
    local dir="$CS_SESSIONS_ROOT/$1"
    "$CS_BIN" "$1" <<< "" >/dev/null 2>&1 || true
    rm -f "$dir/CLAUDE.md" "$dir/CLAUDE.local.md"
    cp "$FIXTURES/$2" "$dir/CLAUDE.md"
    if [ "$3" = commit ]; then
        (cd "$dir" && git add CLAUDE.md && git commit -qm "session template") >/dev/null 2>&1
    fi
    echo "$dir"
}

# File $1 with the /summary heading, protocol lines and bullet cs wrote
# replaced by their /wrap text.
_with_wrap_text() {  # file
    _replace_line "$1" '## Summary Command' '## Wrap-up Command'
    _replace_line "$1" "$SUMMARY_LINE_ROOT" "$WRAP_SENTENCE"
    _replace_line "$1" "$SUMMARY_LINE_CS_DIR" "$WRAP_SENTENCE"
    _replace_line "$1" "$SUMMARY_BULLET" "$WRAP_BULLET"
}

# The header over the rows an open prints for the files it changed, and the
# rows it prints when it rewrites the cue block, and when it rewrites a line
# of the protocol, in each file.
NOTICE_HEADER='✳ cs updated these files'
DROPPED_OFFERS='  CLAUDE.local.md  offers /wrap alone, without /sweep or /summary'
POINTED_LOCAL='  CLAUDE.local.md  session protocol points at /wrap'
POINTED_ROOT='  CLAUDE.md        session protocol points at /wrap'

# What the open prints when it cannot read or rewrite CLAUDE.md.
UNREWRITTEN_ROOT='could not rewrite CLAUDE.md; any /summary line cs wrote there still points at a command that is gone'

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

# The session protocol's /wrap line as cs wrote it from 2026-07-07 (ef700c18),
# as it wrote it on 2026-07-07 before that (dc04c0db), and as it wrote it from
# 2026-06-12 to 2026-07-06 (35e14fb0).
WRAP_LINE_WITH_CHECKPOINT='When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Use `/summary` for the narrative alone, or `/sweep` for the memory pass alone. Mid-session, use `/checkpoint <label>` to snapshot git state and the narrative — e.g. before a risky refactor or destructive operation, and after reaching a green milestone (tests passing, a feature working) — saved under .cs/checkpoints/.'
WRAP_LINE_AT_MEANINGFUL_MOMENTS='When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Use `/summary` for the narrative alone, or `/sweep` for the memory pass alone. Mid-session, use `/checkpoint <label>` to snapshot git state and the narrative at meaningful moments (saved under .cs/checkpoints/).'
WRAP_LINE_SHORT='When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Use `/summary` for the narrative alone, or `/sweep` for the memory pass alone.'

# The /wrap sentence alone, which every /summary protocol line and the short
# /wrap line become.
WRAP_SENTENCE='When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md).'

# The session protocol's line pointing at /summary, as cs wrote it from
# 2026-02-06 to 2026-06-11, and as it wrote it from 2025-11-24 to 2026-02-05.
SUMMARY_LINE_CS_DIR='When the session is complete, use the `/summary` command to generate an intelligent summary of the entire session. This will create a .cs/summary.md file synthesizing all documentation.'
SUMMARY_LINE_ROOT='When the session is complete, use the `/summary` command to generate an intelligent summary of the entire session. This will create a summary.md file synthesizing all documentation.'

# The Best Practices bullet cs wrote from 2025-11-24 to 2026-06-11, and the
# one it wrote from 2026-06-12 to 2026-07-06.
SUMMARY_BULLET='- Run `/summary` at the end to create a cohesive record'
WRAP_BULLET='- Run `/wrap` at the end to distill memory and create a cohesive record'

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
        _open_printed "cue-$v" "$DROPPED_OFFERS" \
            || { echo "  FAIL: the open names the offers it dropped"; cat "$TEST_TMPDIR/cue-$v.out"; return 1; }
        cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/cue-$v.once"
        _reopen_with_migration "cue-$v"
        cmp -s "$TEST_TMPDIR/cue-$v.once" "$dir/CLAUDE.local.md" \
            || { echo "  FAIL: a second open changed the $v session's CLAUDE.local.md"; return 1; }
    done
}

# Each /wrap line cs wrote loses the sentence offering /summary and /sweep
# alone and keeps the rest; the open says it rewrote the protocol and drops no
# cue offer, since the cue block is the template's already.
test_open_drops_the_sweep_and_summary_sentence_from_each_wrap_line_cs_wrote() {
    local v line expected dir
    for v in short meaningful checkpoint; do
        case "$v" in
            short)
                line=$WRAP_LINE_SHORT
                expected=$WRAP_SENTENCE ;;
            meaningful)
                line=$WRAP_LINE_AT_MEANINGFUL_MOMENTS
                expected="$WRAP_SENTENCE"' Mid-session, use `/checkpoint <label>` to snapshot git state and the narrative at meaningful moments (saved under .cs/checkpoints/).' ;;
            checkpoint)
                line=$WRAP_LINE_WITH_CHECKPOINT
                expected="$WRAP_SENTENCE"' Mid-session, use `/checkpoint <label>` to snapshot git state and the narrative — e.g. before a risky refactor or destructive operation, and after reaching a green milestone (tests passing, a feature working) — saved under .cs/checkpoints/.' ;;
        esac
        dir=$(_fresh_session "wrap-line-$v")
        _splice_wrap_line "$dir/CLAUDE.local.md" "$line"
        _reopen_with_migration "wrap-line-$v"
        assert_eq "$expected" "$(grep '^When the session is complete' "$dir/CLAUDE.local.md")" \
            "the $v line keeps all but the /summary and /sweep sentence" || return 1
        _open_printed "wrap-line-$v" "$POINTED_LOCAL" \
            || { echo "  FAIL: the open names the protocol it rewrote"; cat "$TEST_TMPDIR/wrap-line-$v.out"; return 1; }
        ! _open_printed "wrap-line-$v" "$DROPPED_OFFERS" \
            || { echo "  FAIL: the open names offers it did not drop"; return 1; }
    done
}

# An open that changes files names them under one header, a row per change in
# the order made; an open that changes nothing prints no header.
test_open_names_the_files_it_changed_under_one_header() {
    local dir
    dir=$(_fresh_session "notice-block")
    _cue_block_with_triggers | _splice_cue_block "$dir/CLAUDE.local.md"
    _splice_wrap_line "$dir/CLAUDE.local.md" "$WRAP_LINE_WITH_CHECKPOINT"
    _reopen_with_migration "notice-block"
    assert_eq "$(printf '%s\n' "$NOTICE_HEADER" "$DROPPED_OFFERS" "$POINTED_LOCAL")" \
        "$(awk -v h="$NOTICE_HEADER" '$0 == h { on = 1; print; next } on && /^  / { print; next } { on = 0 }' "$TEST_TMPDIR/notice-block.out")" \
        "one header, then a row per change" || return 1
    _reopen_with_migration "notice-block"
    ! grep -Fq -- "$NOTICE_HEADER" "$TEST_TMPDIR/notice-block.out" \
        || { echo "  FAIL: an open that changed nothing printed the header"; cat "$TEST_TMPDIR/notice-block.out"; return 1; }
}

# A line that is not a row, here the warning about a colour the README names,
# ends the block: the next row starts a new one under its own header.
test_open_heads_the_rows_after_a_warning_again() {
    local dir out
    dir=$(_fresh_session "notice-split")
    grep -vxF '.cs/session.mutex.lock' "$dir/.gitignore" > "$dir/.gitignore.new" && mv "$dir/.gitignore.new" "$dir/.gitignore"
    git -C "$dir" commit -qm "drop a lock rule" -- .gitignore || { echo "  FAIL: fixture commit"; return 1; }
    awk 'NR == 1 { print; print "claude_session_color: chartreuse"; next } { print }' "$dir/.cs/README.md" > "$dir/.cs/README.new" \
        && mv "$dir/.cs/README.new" "$dir/.cs/README.md"
    awk 'index($0, "claude_session_color:") != 1' "$dir/.cs/local/state" > "$dir/.cs/local/state.new" \
        && mv "$dir/.cs/local/state.new" "$dir/.cs/local/state"
    _reopen_with_migration "notice-split"
    out=$(awk -v h="$NOTICE_HEADER" '$0 == h || /^  / || /^ignoring / { print }' "$TEST_TMPDIR/notice-split.out" \
        | sed -E 's/^(  \.cs\/local\/state  backfilled claude_session_color) \([a-z]+\)$/\1 (COLOUR)/')
    assert_eq "$(printf '%s\n' "$NOTICE_HEADER" \
            '  .gitignore       ignores .cs/session.mutex.lock' \
            '                   → tracked file: commit it with your next change' \
            "ignoring claude_session_color in .cs/README.md: not one of claude's colours" \
            "$NOTICE_HEADER" \
            '  .cs/README.md    machine-local fields moved to .cs/local/state or dropped' \
            '  .cs/local/state  backfilled claude_session_color (COLOUR)')" \
        "$out" "the warning ends one block and the next row heads another" || return 1
}

# The line cs wrote pointing at /summary, either wording, becomes the /wrap
# sentence; a second open changes nothing.
test_open_rewrites_each_summary_line_cs_wrote() {
    local v line dir
    for v in cs-dir root; do
        case "$v" in
            cs-dir) line=$SUMMARY_LINE_CS_DIR ;;
            root) line=$SUMMARY_LINE_ROOT ;;
        esac
        dir=$(_fresh_session "summary-line-$v")
        _splice_wrap_line "$dir/CLAUDE.local.md" "$line"
        assert_file_contains "$dir/CLAUDE.local.md" '^When the session is complete, use the `/summary` command' \
            "precondition: the $v session carries the /summary line" || return 1
        _reopen_with_migration "summary-line-$v"
        assert_eq 'When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md).' \
            "$(grep '^When the session is complete' "$dir/CLAUDE.local.md")" "the $v line becomes the /wrap sentence" || return 1
        cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/summary-line-$v.once"
        _reopen_with_migration "summary-line-$v"
        cmp -s "$TEST_TMPDIR/summary-line-$v.once" "$dir/CLAUDE.local.md" \
            || { echo "  FAIL: a second open changed the $v session's CLAUDE.local.md"; return 1; }
    done
}

# A /summary line, Best Practices bullet or Summary Command heading the user
# edited is theirs, and so is a "## Summary Command" heading of their own over
# text cs never wrote: an open leaves CLAUDE.local.md and CLAUDE.md as they were.
test_open_leaves_an_edited_summary_line_alone() {
    local dir edited_line='When the session is complete, use the `/summary` command to generate an intelligent summary of the entire session. This will create a .cs/summary.md file synthesizing all my notes.'
    dir=$(_fresh_session summary-line-edited)
    _splice_wrap_line "$dir/CLAUDE.local.md" "$edited_line"
    _replace_line "$dir/CLAUDE.local.md" '## Wrap-up Command' '## Summary Commands'
    _best_practices_section '- Run `/summary` at the end to create a cohesive record of the work' >> "$dir/CLAUDE.local.md"
    printf '%s\n' '' '## Summary Command' '' 'Each evening I write three lines on what shipped.' >> "$dir/CLAUDE.local.md"
    assert_file_contains "$dir/CLAUDE.local.md" '^## Summary Commands$' "precondition: the heading carries the edit" || return 1
    printf '%s\n' '# Notes' '' '## Summary Command' '' "$edited_line" '' \
        '- Run `/summary` at the end to create a cohesive record of the work' > "$dir/CLAUDE.md"
    (cd "$dir" && git add CLAUDE.md && git commit -qm notes) >/dev/null 2>&1
    cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/summary-line-edited.seeded"
    cp "$dir/CLAUDE.md" "$TEST_TMPDIR/summary-line-edited.root"
    _reopen_with_migration summary-line-edited
    cmp -s "$TEST_TMPDIR/summary-line-edited.seeded" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: an open changed the edited /summary line"; diff "$TEST_TMPDIR/summary-line-edited.seeded" "$dir/CLAUDE.local.md" | head -20; return 1; }
    cmp -s "$TEST_TMPDIR/summary-line-edited.root" "$dir/CLAUDE.md" \
        || { echo "  FAIL: an open changed the edited CLAUDE.md"; diff "$TEST_TMPDIR/summary-line-edited.root" "$dir/CLAUDE.md" | head -20; return 1; }
}

# The Best Practices bullet cs wrote pointing at /summary becomes the bullet
# cs later wrote pointing at /wrap, and nothing else changes; a second open
# changes nothing.
test_open_rewrites_the_best_practices_bullet_cs_wrote() {
    local dir
    dir=$(_fresh_session summary-bullet)
    _best_practices_section "$SUMMARY_BULLET" >> "$dir/CLAUDE.local.md"
    assert_file_contains "$dir/CLAUDE.local.md" '^- Run `/summary` at the end to create a cohesive record$' \
        "precondition: the session carries the /summary bullet" || return 1
    { cat "$TEST_TMPDIR/summary-bullet.fresh"; _best_practices_section "$WRAP_BULLET"; } > "$TEST_TMPDIR/summary-bullet.expected"
    _reopen_with_migration summary-bullet
    cmp -s "$TEST_TMPDIR/summary-bullet.expected" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: the bullet becomes the /wrap bullet"; diff "$TEST_TMPDIR/summary-bullet.expected" "$dir/CLAUDE.local.md" | head -20; return 1; }
    _reopen_with_migration summary-bullet
    cmp -s "$TEST_TMPDIR/summary-bullet.expected" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: a second open changed the bullet session's CLAUDE.local.md"; return 1; }
}

# The "## Summary Command" heading cs wrote over its /summary protocol line
# becomes the template's "## Wrap-up Command" over the /wrap sentence, and
# nothing else changes; a second open changes nothing.
test_open_rewrites_the_summary_command_heading() {
    local dir
    dir=$(_fresh_session summary-heading)
    _replace_line "$dir/CLAUDE.local.md" '## Wrap-up Command' '## Summary Command'
    _splice_wrap_line "$dir/CLAUDE.local.md" "$SUMMARY_LINE_CS_DIR"
    assert_file_contains "$dir/CLAUDE.local.md" '^## Summary Command$' \
        "precondition: the session carries the Summary Command heading" || return 1
    cp "$TEST_TMPDIR/summary-heading.fresh" "$TEST_TMPDIR/summary-heading.expected"
    _splice_wrap_line "$TEST_TMPDIR/summary-heading.expected" "$WRAP_SENTENCE"
    _reopen_with_migration summary-heading
    cmp -s "$TEST_TMPDIR/summary-heading.expected" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: the heading becomes Wrap-up Command"; diff "$TEST_TMPDIR/summary-heading.expected" "$dir/CLAUDE.local.md" | head -20; return 1; }
    _reopen_with_migration summary-heading
    cmp -s "$TEST_TMPDIR/summary-heading.expected" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: a second open changed the heading session's CLAUDE.local.md"; return 1; }
}

# A cue block or a /wrap line the user edited is theirs, inside the sentence
# offering /summary and /sweep or outside it, and so is a copy of cs's text
# with CRLF line ends: an open leaves the file as it was and names no offer
# it dropped.
test_open_leaves_an_edited_cue_and_wrap_line_alone() {
    local dir
    dir=$(_fresh_session cue-edited)
    _cue_block_with_signals | sed 's/^- "that works", "looks good", "we.re good", "all set"$/- "that works", "looks good", "ship it"/' \
        | _splice_cue_block "$dir/CLAUDE.local.md"
    assert_file_contains "$dir/CLAUDE.local.md" '"ship it"$' "precondition: the block carries the edit" || return 1
    _splice_wrap_line "$dir/CLAUDE.local.md" 'When the session is complete, use the `/wrap` command. Use `/summary` for the narrative alone, or `/sweep` for memory.'
    printf '%s\n' "${WRAP_LINE_WITH_CHECKPOINT%.}"' (and before a release).' >> "$dir/CLAUDE.local.md"
    cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/cue-edited.seeded"
    _reopen_with_migration cue-edited
    cmp -s "$TEST_TMPDIR/cue-edited.seeded" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: an open changed the edited CLAUDE.local.md"; diff "$TEST_TMPDIR/cue-edited.seeded" "$dir/CLAUDE.local.md" | head -20; return 1; }

    dir=$(_fresh_session cue-crlf)
    _cue_block_with_signals | _splice_cue_block "$dir/CLAUDE.local.md"
    _splice_wrap_line "$dir/CLAUDE.local.md" "$WRAP_LINE_WITH_CHECKPOINT"
    awk '{ printf "%s\r\n", $0 }' "$dir/CLAUDE.local.md" > "$TEST_TMPDIR/cue-crlf.seeded"
    cp "$TEST_TMPDIR/cue-crlf.seeded" "$dir/CLAUDE.local.md"
    _reopen_with_migration cue-crlf
    cmp -s "$TEST_TMPDIR/cue-crlf.seeded" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: an open changed the CRLF copy"; diff "$TEST_TMPDIR/cue-crlf.seeded" "$dir/CLAUDE.local.md" | head -20; return 1; }
    ! _open_printed cue-crlf "$DROPPED_OFFERS" \
        || { echo "  FAIL: the open names offers the CRLF copy still makes"; return 1; }
}

# A session whose CLAUDE.md cs wrote before it used sentinels keeps its whole
# protocol there. An open rewrites the /summary heading, protocol line and
# bullet in it and changes nothing else; a second open changes nothing. The
# 2025-12-01 template names no .cs/ path, so the open also writes
# CLAUDE.local.md as a new session gets it; the 2026-02-06 one does, so the
# session gets none.
test_open_rewrites_the_summary_text_in_a_claude_md_cs_wrote_without_sentinels() {
    local v c dir
    _fresh_session pre-sentinel-fresh >/dev/null
    for v in 7d8542d4:untracked 71c37d13:commit; do
        c=${v%%:*}
        dir=$(_session_from_template "pre-$c" "session-claude-md-$c.md" "${v#*:}")
        cp "$FIXTURES/session-claude-md-$c.md" "$TEST_TMPDIR/pre-$c.expected"
        _with_wrap_text "$TEST_TMPDIR/pre-$c.expected"
        _reopen_with_migration "pre-$c"
        cmp -s "$TEST_TMPDIR/pre-$c.expected" "$dir/CLAUDE.md" \
            || { echo "  FAIL: the $c CLAUDE.md points at /wrap"; diff "$TEST_TMPDIR/pre-$c.expected" "$dir/CLAUDE.md" | head -20; return 1; }
        _open_printed "pre-$c" "$POINTED_ROOT" \
            || { echo "  FAIL: the open names the CLAUDE.md protocol it rewrote"; cat "$TEST_TMPDIR/pre-$c.out"; return 1; }
        case "$c" in
            7d8542d4)
                cmp -s "$TEST_TMPDIR/pre-sentinel-fresh.fresh" "$dir/CLAUDE.local.md" \
                    || { echo "  FAIL: the $c session's CLAUDE.local.md is not the new session's"; return 1; } ;;
            71c37d13)
                assert_file_not_exists "$dir/CLAUDE.local.md" "the $c session gets no CLAUDE.local.md" || return 1 ;;
        esac
        _reopen_with_migration "pre-$c"
        cmp -s "$TEST_TMPDIR/pre-$c.expected" "$dir/CLAUDE.md" \
            || { echo "  FAIL: a second open changed the $c CLAUDE.md"; return 1; }
        case "$c" in
            7d8542d4)
                cmp -s "$TEST_TMPDIR/pre-sentinel-fresh.fresh" "$dir/CLAUDE.local.md" \
                    || { echo "  FAIL: a second open changed the $c CLAUDE.local.md"; return 1; } ;;
        esac
    done
}

# A session whose CLAUDE.md opened its sentinels with cs:memory-rules (from
# 2026-05-12) is split: the head above the sentinel stays in CLAUDE.md and the
# rest moves to CLAUDE.local.md. An open rewrites the /summary heading and
# protocol line in the head and the cue block and bullet in CLAUDE.local.md;
# neither file names /summary or /sweep, and a second open changes nothing.
test_open_rewrites_the_summary_text_in_both_files_of_a_split_claude_md() {
    local dir fresh
    fresh=$(_fresh_session split-fresh)
    dir=$(_session_from_template split session-claude-md-4d377b5a.md commit)
    awk '/<!-- cs:/ { exit } /[^[:space:]]/ { printf "%s", blanks; blanks = ""; print; next } { blanks = blanks $0 "\n" }' \
        "$FIXTURES/session-claude-md-4d377b5a.md" > "$TEST_TMPDIR/split.expected"
    _with_wrap_text "$TEST_TMPDIR/split.expected"
    _reopen_with_migration split
    cmp -s "$TEST_TMPDIR/split.expected" "$dir/CLAUDE.md" \
        || { echo "  FAIL: the head kept in CLAUDE.md points at /wrap"; diff "$TEST_TMPDIR/split.expected" "$dir/CLAUDE.md" | head -20; return 1; }
    assert_eq "$(_cue_block "$fresh/CLAUDE.local.md")" "$(_cue_block "$dir/CLAUDE.local.md")" \
        "the moved cue block is the template's" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" '^- Run `/wrap` at the end to distill memory and create a cohesive record$' \
        "the moved bullet points at /wrap" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" '/sweep\|`/summary`\|/summary only' "CLAUDE.local.md names no /summary or /sweep" || return 1
    _open_printed split "$POINTED_ROOT" \
        || { echo "  FAIL: the open names the CLAUDE.md protocol it rewrote"; cat "$TEST_TMPDIR/split.out"; return 1; }
    _open_printed split "$DROPPED_OFFERS" \
        || { echo "  FAIL: the open names the offers it dropped"; return 1; }
    cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/split.local.once"
    _reopen_with_migration split
    cmp -s "$TEST_TMPDIR/split.expected" "$dir/CLAUDE.md" \
        || { echo "  FAIL: a second open changed CLAUDE.md"; return 1; }
    cmp -s "$TEST_TMPDIR/split.local.once" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: a second open changed CLAUDE.local.md"; return 1; }
}

# A session whose CLAUDE.md opened its sentinels with cs:memory-note (from
# v2026.5.5) moves to CLAUDE.local.md whole. An open rewrites the heading,
# protocol line, cue block and bullet there; CLAUDE.md is gone, and a second
# open changes nothing.
test_open_rewrites_the_summary_text_of_a_claude_md_moved_whole() {
    local dir fresh
    fresh=$(_fresh_session moved-fresh)
    dir=$(_session_from_template moved session-claude-md-c7e37ecf.md commit)
    _reopen_with_migration moved
    assert_file_not_exists "$dir/CLAUDE.md" "CLAUDE.md moved to CLAUDE.local.md" || return 1
    assert_eq "$WRAP_SENTENCE" "$(grep '^When the session is complete' "$dir/CLAUDE.local.md")" \
        "the protocol line is the /wrap sentence" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" '^## Wrap-up Command$' "the heading names the wrap-up command" || return 1
    assert_eq "$(_cue_block "$fresh/CLAUDE.local.md")" "$(_cue_block "$dir/CLAUDE.local.md")" \
        "the cue block is the template's" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" '^- Run `/wrap` at the end to distill memory and create a cohesive record$' \
        "the bullet points at /wrap" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" '/sweep\|`/summary`\|/summary only\|Summary Command' \
        "CLAUDE.local.md names no /summary or /sweep" || return 1
    cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/moved.once"
    _reopen_with_migration moved
    cmp -s "$TEST_TMPDIR/moved.once" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: a second open changed CLAUDE.local.md"; return 1; }
}

# cs leaves the CLAUDE.md of a checkout it keeps out of git (git_bookkeeping:
# exclude) as the branch has it, /summary text and all.
test_open_leaves_claude_md_alone_where_cs_keeps_out_of_git() {
    local dir
    dir=$(_session_from_template excluded session-claude-md-71c37d13.md commit)
    # An excluded checkout tracks none of cs's files, or the open refuses it.
    git -C "$dir" rm -r -q --cached --ignore-unmatch .cs .claude/settings.local.json CLAUDE.local.md \
        && git -C "$dir" commit -q -m "untrack cs files" \
        || { echo "  FAIL: could not untrack cs's files"; return 1; }
    printf 'git_bookkeeping: exclude\n' >> "$dir/.cs/local/state"
    _reopen_with_migration excluded
    assert_file_exists "$dir/.cs/local/migrated" "the open ran the migration" || { cat "$TEST_TMPDIR/excluded.out"; return 1; }
    cmp -s "$FIXTURES/session-claude-md-71c37d13.md" "$dir/CLAUDE.md" \
        || { echo "  FAIL: an open changed the excluded checkout's CLAUDE.md"; diff "$FIXTURES/session-claude-md-71c37d13.md" "$dir/CLAUDE.md" | head -20; return 1; }
}

# A CLAUDE.md whose first line that is not empty is not cs's "# Session
# Documentation Protocol" heading is the user's, even when it holds a
# /summary heading, protocol line or bullet exactly as cs wrote them: an open
# leaves it byte for byte, in an adopted project where it is committed and in
# a plain session.
test_open_leaves_a_claude_md_cs_did_not_write_alone() {
    local project="$TEST_TMPDIR/widget" dir
    mkdir -p "$project"
    printf '%s\n' '# Widget service' '' 'Build with make.' '' '## Summary Command' '' "$SUMMARY_LINE_CS_DIR" '' \
        '## Habits' '' "$SUMMARY_BULLET" > "$project/CLAUDE.md"
    (cd "$project" && git init -q && git add CLAUDE.md && git commit -qm init) \
        || { echo "  FAIL: could not commit the project's CLAUDE.md"; return 1; }
    cp "$project/CLAUDE.md" "$TEST_TMPDIR/widget.seeded"
    (cd "$project" && "$CS_BIN" -adopt widget --yes) >/dev/null 2>&1 \
        || { echo "  FAIL: could not adopt the project"; return 1; }
    _reopen_with_migration widget
    assert_eq 0 "$(cat "$TEST_TMPDIR/widget.rc")" "the adopted project opens" || { cat "$TEST_TMPDIR/widget.out"; return 1; }
    cmp -s "$TEST_TMPDIR/widget.seeded" "$project/CLAUDE.md" \
        || { echo "  FAIL: an open changed the adopted project's CLAUDE.md"; diff "$TEST_TMPDIR/widget.seeded" "$project/CLAUDE.md" | head -20; return 1; }
    assert_eq "" "$(git -C "$project" status --porcelain -- CLAUDE.md)" "the project's CLAUDE.md stays as committed" || return 1
    ! _open_printed widget "$POINTED_ROOT" \
        || { echo "  FAIL: the open names a CLAUDE.md protocol cs did not write"; return 1; }

    dir=$(_fresh_session own-rules)
    printf '%s\n' '# Project rules' '' "$SUMMARY_BULLET" > "$dir/CLAUDE.md"
    cp "$dir/CLAUDE.md" "$TEST_TMPDIR/own-rules.seeded"
    _reopen_with_migration own-rules
    cmp -s "$TEST_TMPDIR/own-rules.seeded" "$dir/CLAUDE.md" \
        || { echo "  FAIL: an open changed the session's own CLAUDE.md"; diff "$TEST_TMPDIR/own-rules.seeded" "$dir/CLAUDE.md" | head -20; return 1; }
    ! _open_printed own-rules "$POINTED_ROOT" \
        || { echo "  FAIL: the open names a CLAUDE.md protocol cs did not write"; return 1; }
}

# A CLAUDE.md cs cannot read is named in one warning and left as it is; the
# open goes on and writes no migration stamp, so the next open tries again.
test_open_warns_and_goes_on_when_it_cannot_read_claude_md() {
    local dir
    dir=$(_session_from_template unreadable session-claude-md-71c37d13.md commit)
    chmod 000 "$dir/CLAUDE.md"
    if [ -r "$dir/CLAUDE.md" ]; then
        chmod 644 "$dir/CLAUDE.md"
        echo "  FAIL: precondition: CLAUDE.md is unreadable (this test cannot run as root)"
        return 1
    fi
    _reopen_with_migration unreadable
    chmod 644 "$dir/CLAUDE.md"
    assert_eq 0 "$(cat "$TEST_TMPDIR/unreadable.rc")" "the open goes on" || { cat "$TEST_TMPDIR/unreadable.out"; return 1; }
    assert_eq 1 "$(grep -Fxc -- "$UNREWRITTEN_ROOT" "$TEST_TMPDIR/unreadable.out")" \
        "the open names CLAUDE.md once" || { cat "$TEST_TMPDIR/unreadable.out"; return 1; }
    cmp -s "$FIXTURES/session-claude-md-71c37d13.md" "$dir/CLAUDE.md" \
        || { echo "  FAIL: an open changed the unreadable CLAUDE.md"; return 1; }
    assert_file_not_exists "$dir/.cs/local/migrated" "the next open tries again" || return 1
}

# A CLAUDE.md that is a link to a file outside the session is named in one
# warning, and the file it leads to is left as it is; the open goes on and
# writes no migration stamp, so the next open tries again.
test_open_warns_and_goes_on_when_claude_md_links_out_of_the_session() {
    local dir shared="$TEST_TMPDIR/shared"
    dir=$(_session_from_template linked-out session-claude-md-71c37d13.md untracked)
    mkdir -p "$shared"
    mv "$dir/CLAUDE.md" "$shared/CLAUDE.md"
    ln -s "$shared/CLAUDE.md" "$dir/CLAUDE.md"
    _reopen_with_migration linked-out
    assert_eq 0 "$(cat "$TEST_TMPDIR/linked-out.rc")" "the open goes on" || { cat "$TEST_TMPDIR/linked-out.out"; return 1; }
    assert_eq 1 "$(grep -Fxc -- "$UNREWRITTEN_ROOT" "$TEST_TMPDIR/linked-out.out")" \
        "the open names CLAUDE.md once" || { cat "$TEST_TMPDIR/linked-out.out"; return 1; }
    cmp -s "$FIXTURES/session-claude-md-71c37d13.md" "$shared/CLAUDE.md" \
        || { echo "  FAIL: an open changed the file outside the session"; return 1; }
    assert_symlink "$dir/CLAUDE.md" "CLAUDE.md stays a link" || return 1
    assert_file_not_exists "$dir/.cs/local/migrated" "the next open tries again" || return 1
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
run_test test_open_drops_the_sweep_and_summary_sentence_from_each_wrap_line_cs_wrote
run_test test_open_names_the_files_it_changed_under_one_header
run_test test_open_heads_the_rows_after_a_warning_again
run_test test_open_leaves_an_edited_cue_and_wrap_line_alone
run_test test_open_rewrites_each_summary_line_cs_wrote
run_test test_open_leaves_an_edited_summary_line_alone
run_test test_open_rewrites_the_best_practices_bullet_cs_wrote
run_test test_open_rewrites_the_summary_command_heading
run_test test_open_rewrites_the_summary_text_in_a_claude_md_cs_wrote_without_sentinels
run_test test_open_rewrites_the_summary_text_in_both_files_of_a_split_claude_md
run_test test_open_rewrites_the_summary_text_of_a_claude_md_moved_whole
run_test test_open_leaves_claude_md_alone_where_cs_keeps_out_of_git
run_test test_open_leaves_a_claude_md_cs_did_not_write_alone
run_test test_open_warns_and_goes_on_when_it_cannot_read_claude_md
run_test test_open_warns_and_goes_on_when_claude_md_links_out_of_the_session
report_results
