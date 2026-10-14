#!/usr/bin/env bash
# ABOUTME: Tests for hooks/memory-index-guard.sh, the guard on /wrap's memory-pass MEMORY.md rewrites
# ABOUTME: Covers removed links, the byte budget, a missing snapshot, and restore

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

GUARD="$SCRIPT_DIR/../hooks/memory-index-guard.sh"

# A session root holding a MEMORY.md with two pointers; the guard runs from it.
_guard_session() {
    SESSION="$TEST_TMPDIR/session"
    mkdir -p "$SESSION/.cs/memory" "$SESSION/.cs/local"
    INDEX="$SESSION/.cs/memory/MEMORY.md"
    cat > "$INDEX" << 'EOF'
- [Alpha rule](feedback_alpha.md): never do alpha twice
- [Beta fact](project_beta.md): beta only runs on Tuesdays
EOF
}

_guard() {  # subcommand...
    ( cd "$SESSION" && bash "$GUARD" "$@" )
}

test_check_fails_when_a_link_is_removed() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md): never do alpha twice' > "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check must fail when a pointer's link is gone" || return 1
    assert_output_contains "$out" "removed: project_beta.md" \
        "check must name the link that was removed" || return 1
}

# Appends one pointer line padded so MEMORY.md ends at exactly $1 bytes.
_pad_index_to() {  # bytes
    local head='- [Pad](project_pad.md): ' size fill
    size=$(wc -c < "$INDEX")
    fill=$(( $1 - size - ${#head} - 1 ))
    { printf '%s' "$head"; head -c "$fill" /dev/zero | tr '\0' x; printf '\n'; } >> "$INDEX"
    assert_eq "$1" "$(wc -c < "$INDEX" | tr -d ' ')" "fixture must be $1 bytes" || return 1
}

test_check_fails_over_the_byte_budget() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    _pad_index_to 24401 || return 1
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check must fail one byte past the budget" || return 1
    assert_output_contains "$out" "over budget: 24401 bytes > 24400" \
        "check must print the size against the budget" || return 1
}

# step 5 runs check once per sweep even when nothing was written; with no
# snapshot there is nothing to compare, and that must never read as a pass.
test_check_without_a_snapshot_is_an_error() {
    _guard_session
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 2 "$rc" "check with no snapshot must not pass" || return 1
    assert_output_contains "$out" "no snapshot at .cs/local/memory-index.snapshot; run snapshot before editing MEMORY.md" \
        "the error must name the missing snapshot and the fix" || return 1
}

test_check_without_the_index_is_an_error() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    rm "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 2 "$rc" "check with MEMORY.md gone must not pass" || return 1
    assert_output_contains "$out" "no .cs/memory/MEMORY.md here; run from the session root" \
        "the error must name the missing index" || return 1
}

# Rewriting a pointer shorter and adding a new one is what step 5 asks for.
test_check_passes_a_rewrite_that_keeps_every_link_at_the_budget() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    cat > "$INDEX" << 'EOF'
- [Alpha rule](feedback_alpha.md): never alpha twice
- [Beta fact](project_beta.md): beta only on Tuesdays
- [Gamma](reference_gamma.md): the gamma board
EOF
    _pad_index_to 24400 || return 1
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "a rewrite keeping every link within budget must pass: $out" || return 1
    assert_output_contains "$out" "MEMORY.md: 24400/24400 bytes" \
        "a pass must still print the size against the budget" || return 1
}

# The budget is bytes: an em dash is three bytes and one character, so a
# character count would pass a file that Claude Code truncates.
test_check_counts_bytes_not_characters() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Delta](project_delta.md): delta — then epsilon' >> "$INDEX"
    _pad_index_to 24401 || return 1
    local chars
    chars=$(LC_ALL=en_US.UTF-8 wc -m < "$INDEX" | tr -d ' ')
    [ "$chars" -le 24400 ] || { echo "  FAIL: fixture must fit the budget in characters, has $chars"; return 1; }
    local rc=0
    _guard check > /dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "24401 bytes must fail even when the characters fit" || return 1
}

# restore puts back exactly what snapshot took, byte for byte: cs never
# rewrites MEMORY.md content of its own.
test_restore_puts_back_the_snapshot_byte_for_byte() {
    _guard_session
    printf '%s\n' '- [Delta](project_delta.md): delta — no trailing newline next' >> "$INDEX"
    printf '%s' 'last line without newline' >> "$INDEX"
    cp "$INDEX" "$TEST_TMPDIR/original"
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md)' > "$INDEX"
    _guard restore > /dev/null || return 1
    cmp -s "$TEST_TMPDIR/original" "$INDEX" || { echo "  FAIL: restore must reproduce the snapshot exactly"; return 1; }
}

test_restore_without_a_snapshot_leaves_the_index_alone() {
    _guard_session
    cp "$INDEX" "$TEST_TMPDIR/original"
    local out rc=0
    out=$(_guard restore 2>&1) || rc=$?
    assert_eq 2 "$rc" "restore with no snapshot must fail" || return 1
    assert_output_contains "$out" "no snapshot at .cs/local/memory-index.snapshot" \
        "the error must name the missing snapshot" || return 1
    cmp -s "$TEST_TMPDIR/original" "$INDEX" || { echo "  FAIL: a failed restore must not touch MEMORY.md"; return 1; }
}

test_unknown_subcommand_prints_usage() {
    _guard_session
    local out rc=0
    out=$(_guard verify 2>&1) || rc=$?
    assert_eq 2 "$rc" "an unknown subcommand must fail" || return 1
    assert_output_contains "$out" "usage: memory-index-guard.sh snapshot|check|restore" \
        "the error must list the subcommands" || return 1
}

# A pointer is its first link; a link inside its summary is supporting text.
test_check_passes_when_a_supporting_link_is_dropped() {
    _guard_session
    printf '%s\n' '- [Gamma](project_gamma.md): see [vendor docs](https://example.com/docs)' >> "$INDEX"
    _guard snapshot > /dev/null || return 1
    sed -i.bak 's|: see \[vendor docs\](https://example.com/docs)|: vendor configuration|' "$INDEX"
    grep -q 'vendor configuration' "$INDEX" || { echo "  FAIL: fixture edit did not land"; return 1; }
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "dropping a supporting link keeps every pointer: $out" || return 1
}

# Merging two pointers into one is forbidden even when the merged line still
# mentions the other entry's file.
test_check_fails_when_two_pointers_are_merged() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Beta fact](project_beta.md): Tuesdays; see [Alpha](feedback_alpha.md)' > "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a merged pointer must fail" || return 1
    assert_output_contains "$out" "removed: feedback_alpha.md" \
        "check must name the pointer the merge removed" || return 1
}

# Every entry in a memory bucket needs a pointer, including one this sweep
# wrote after the snapshot: an unindexed entry is never read again.
test_check_fails_on_an_unindexed_bucket_entry() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    : > "$SESSION/.cs/memory/project_delta.md"
    : > "$SESSION/.cs/memory/notes.md"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a bucket entry with no pointer must fail" || return 1
    assert_output_contains "$out" "unindexed: project_delta.md" \
        "check must name the entry with no pointer" || return 1
    assert_output_not_contains "$out" "notes.md" \
        "a file outside the four buckets is not an entry" || return 1
}

# .cs/memory is tracked, so a clone chooses the entry file names and the
# pointers MEMORY.md holds, and a name can carry a terminal escape: a raw ESC
# or BEL byte, or backslash text echo -e would turn into one. check names a
# removed pointer and an unindexed entry as plain names, each character a
# plain name lacks replaced by _.
test_check_names_a_pointer_and_an_entry_as_plain_names() {
    _guard_session
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m out rc=0
    printf '%s\n' "- [Odd](feedback_o$bad.md): odd" >> "$INDEX"
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md): never do alpha twice' \
        '- [Beta fact](project_beta.md): beta only runs on Tuesdays' > "$INDEX"
    : > "$SESSION/.cs/memory/project_p$bad.md"
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check fails" || return 1
    assert_eq "removed: feedback_o$shown.md" "$(grep '^removed:' <<< "$out")" \
        "check names the removed pointer as a plain name" || return 1
    assert_eq "unindexed: project_p$shown.md" "$(grep '^unindexed:' <<< "$out")" \
        "check names the unindexed entry as a plain name" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches Claude" || return 1
}

# A fresh session has no MEMORY.md until Claude Code writes the first entry,
# so the first sweep snapshots nothing and must still reach a passing check.
test_first_sweep_snapshots_an_absent_index_as_empty() {
    _guard_session
    rm "$INDEX"
    local out rc=0
    out=$(_guard snapshot 2>&1) || rc=$?
    assert_eq 0 "$rc" "snapshot with no MEMORY.md yet must succeed: $out" || return 1
    [ -f "$SESSION/.cs/local/memory-index.snapshot" ] && [ ! -s "$SESSION/.cs/local/memory-index.snapshot" ] \
        || { echo "  FAIL: the snapshot of an absent index must be an empty file"; return 1; }
    : > "$SESSION/.cs/memory/project_first.md"
    printf '%s\n' '- [First](project_first.md): the first entry' > "$INDEX"
    rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "a first sweep that indexes its entry must pass: $out" || return 1
    : > "$SESSION/.cs/memory/project_second.md"
    rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a first sweep still fails on an unindexed entry" || return 1
    assert_output_contains "$out" "unindexed: project_second.md" \
        "check must name the entry with no pointer" || return 1
}

# An absent index is only a fresh session inside a session root; anywhere else
# snapshot must refuse rather than record an empty index.
test_snapshot_outside_a_session_root_is_an_error() {
    mkdir -p "$TEST_TMPDIR/elsewhere"
    local out rc=0
    out=$( cd "$TEST_TMPDIR/elsewhere" && bash "$GUARD" snapshot 2>&1 ) || rc=$?
    assert_eq 2 "$rc" "snapshot outside a session root must fail" || return 1
    assert_output_contains "$out" "no .cs/memory here; run from the session root" \
        "the error must name the missing directory" || return 1
    [ ! -e "$TEST_TMPDIR/elsewhere/.cs" ] || { echo "  FAIL: snapshot must not create .cs outside a session root"; return 1; }
}

test_check_with_an_unreadable_snapshot_is_an_error() {
    [ "$(id -u)" -ne 0 ] || return 77
    _guard_session
    _guard snapshot > /dev/null || return 1
    chmod 000 "$SESSION/.cs/local/memory-index.snapshot"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    chmod 600 "$SESSION/.cs/local/memory-index.snapshot"
    assert_eq 2 "$rc" "an unreadable snapshot must not read as an empty one" || return 1
    assert_output_contains "$out" "cannot read .cs/local/memory-index.snapshot" \
        "the error must name the snapshot" || return 1
}


# An encrypted session's MEMORY.md lives in its vault; the snapshot is a copy
# of it, so it goes behind .cs/private too, never into .cs/local.
test_snapshot_goes_into_the_private_dir() {
    _guard_session
    mkdir -p "$TEST_TMPDIR/vault/private"
    ln -s "$TEST_TMPDIR/vault/private" "$SESSION/.cs/private"
    _mark_hand_made_vault "$SESSION"
    local out
    out=$(_guard snapshot 2>&1) || { echo "  FAIL: snapshot exited non-zero: $out"; return 1; }
    assert_eq "$(cat "$INDEX")" "$(cat "$TEST_TMPDIR/vault/private/memory-index.snapshot")" \
        "the snapshot should be the index, in the private dir" || return 1
    assert_file_not_exists "$SESSION/.cs/local/memory-index.snapshot" \
        "nothing may be copied into .cs/local" || return 1
    _guard check > /dev/null || { echo "  FAIL: check should read the private snapshot"; return 1; }
}

test_snapshot_refuses_a_locked_private_dir() {
    _guard_session
    ln -s "$TEST_TMPDIR/unmounted/private" "$SESSION/.cs/private"
    local out rc=0
    out=$(_guard snapshot 2>&1) || rc=$?
    assert_eq 2 "$rc" "snapshot must fail while the vault is locked" || return 1
    assert_eq "memory-index-guard: .cs/private is locked; mount the session's vault, then retry" \
        "$out" "snapshot must say why" || return 1
    assert_file_not_exists "$SESSION/.cs/local/memory-index.snapshot" \
        "nothing may be copied into .cs/local" || return 1
}

# The snapshot lives in .cs/local, and while git tracks a file there a
# repository wrote it: a snapshot taken there would sit beside it, and a
# committed one restored would put the repository's index over the session's.
# Every subcommand refuses, naming the file, and touches nothing.
test_every_subcommand_refuses_while_git_tracks_a_control_file() {
    _guard_session
    local before snap="$SESSION/.cs/local/memory-index.snapshot" sub out rc
    printf -- '- [Planted](project_planted.md): from the repository\n' > "$snap"
    git -C "$SESSION" init -q
    git -C "$SESSION" add .cs/local/memory-index.snapshot
    before=$(cat "$INDEX")
    for sub in snapshot check restore; do
        rc=0
        out=$(_guard "$sub" 2>&1) || rc=$?
        assert_eq 2 "$rc" "$sub refuses" || return 1
        assert_eq "memory-index-guard: .cs/local/memory-index.snapshot is tracked in git (per-actor state must stay local). Fix with: git -C $SESSION --literal-pathspecs rm -r --cached -- .cs/local && git -C $SESSION commit -m 'stop tracking .cs/local'" \
            "$out" "$sub names the tracked file" || return 1
        assert_eq "$before" "$(cat "$INDEX")" "$sub leaves MEMORY.md as it was" || return 1
        assert_eq "- [Planted](project_planted.md): from the repository" "$(cat "$snap")" \
            "$sub leaves the snapshot as it was" || return 1
    done
}

# The pointers and the entries are compared with comm, which needs them sorted
# the way it reads them: both sorts and comm get the C locale through env, so
# the lists come out in byte order (uppercase, then "_", then lowercase) in any
# caller's locale, and the shell never changes its own locale for them, which
# can crash a bash linked against libintl in the forked copies they run in.
test_check_lists_in_byte_order_without_the_shell_assigning_its_own_locale() {
    local b utf8 out rc own
    utf8="$(utf8_locale)"
    _guard_session
    printf '%s\n' '- [A](project_a.md): a' '- [B](project_B.md): b' '- [C](project__c.md): c' \
        '- [Keep](feedback_keep.md): kept' > "$INDEX"
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Keep](feedback_keep.md): kept' > "$INDEX"
    : > "$SESSION/.cs/memory/feedback_keep.md"
    : > "$SESSION/.cs/memory/project_yak.md"
    : > "$SESSION/.cs/memory/project_Zed.md"
    for b in $(every_bash); do
        rc=0
        out=$(cd "$SESSION" && env ${utf8:+"LC_ALL=$utf8"} "$b" -x "$GUARD" check 2>"$TEST_TMPDIR/trace") || rc=$?
        assert_eq 1 "$rc" "$b: check fails on the removed and unindexed entries" || return 1
        assert_eq "removed: project_B.md
removed: project__c.md
removed: project_a.md
unindexed: project_Zed.md
unindexed: project_yak.md
MEMORY.md: 33/24400 bytes" "$out" "$b: the report, in byte order" || return 1
        own="$(shell_locale_assignments "$TEST_TMPDIR/trace")"
        assert_eq "" "$own" "$b must not assign its own locale during check" || return 1
    done
}

run_test test_check_fails_when_a_link_is_removed
run_test test_check_passes_a_rewrite_that_keeps_every_link_at_the_budget
run_test test_check_counts_bytes_not_characters
run_test test_check_without_a_snapshot_is_an_error
run_test test_check_without_the_index_is_an_error
run_test test_check_fails_over_the_byte_budget
run_test test_restore_puts_back_the_snapshot_byte_for_byte
run_test test_restore_without_a_snapshot_leaves_the_index_alone
run_test test_unknown_subcommand_prints_usage

run_test test_check_passes_when_a_supporting_link_is_dropped
run_test test_check_fails_when_two_pointers_are_merged
run_test test_check_fails_on_an_unindexed_bucket_entry
run_test test_check_names_a_pointer_and_an_entry_as_plain_names
run_test test_first_sweep_snapshots_an_absent_index_as_empty
run_test test_snapshot_outside_a_session_root_is_an_error
run_test test_check_with_an_unreadable_snapshot_is_an_error
run_test test_snapshot_goes_into_the_private_dir
run_test test_snapshot_refuses_a_locked_private_dir
run_test test_every_subcommand_refuses_while_git_tracks_a_control_file
run_test test_check_lists_in_byte_order_without_the_shell_assigning_its_own_locale

report_results
