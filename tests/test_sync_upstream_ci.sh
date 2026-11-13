#!/usr/bin/env bash
# ABOUTME: Tests for scripts/sync-upstream-ci.sh, which the Sync upstream workflow runs on a schedule.
# ABOUTME: A fixture upstream and fork, a bare repository as the fork on GitHub, and a gh that records its calls.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
CI="$SCRIPT_DIR/../scripts/sync-upstream-ci.sh"

# Upstream at v1, the fork one commit ahead of it on its own branch, and the
# fork's repository on GitHub as origin. Upstream is not a remote yet, as in a
# fresh Actions checkout: the script adds it.
make_fixture() {
    UP="$TEST_TMPDIR/upstream"
    FORK="$TEST_TMPDIR/fork"
    ORIGIN="$TEST_TMPDIR/origin.git"
    GH="$TEST_TMPDIR/gh"
    mkdir -p "$UP/lib" "$GH"
    git init -q -b main "$UP"
    printf '# ABOUTME: Session state.\n\n_read_state() {\n    cat "$1"\n}\n' > "$UP/lib/40-state.sh"
    printf 'cs is a session manager.\n' > "$UP/README.md"
    (cd "$UP" && git add -A && git commit -q -m v1 && git tag v1) || return 1
    git clone -q "$UP" "$FORK" || return 1
    printf 'code-sessions is a fork of cs.\n' > "$FORK/README.md"
    (cd "$FORK" && git checkout -q -b fork-main && git add -A && git commit -q -m "the fork") || return 1
    git init -q --bare "$ORIGIN"
    git -C "$FORK" remote remove origin
    git -C "$FORK" remote add origin "$ORIGIN"
    git -C "$FORK" push -q origin fork-main || return 1
    make_gh
}

# gh, as far as the script uses it. Every call is one line of $GH/calls; the
# lists answer from $GH/pr-list and $GH/issue-list (what --jq would print), a
# --body-file is kept as $GH/<pr|issue>-body, and a file named after a call
# ($GH/fail-pr-create, $GH/fail-api-graphql) makes that call fail. The
# repository has Issues switched on until $GH/issues-off exists; then, as on
# GitHub, every issue command fails.
make_gh() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
dir="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$dir/calls"
call="$1-$2"
case "$call" in
    issue-*)
        if [ -e "$dir/issues-off" ]; then
            echo "the 'fork/repo' repository has disabled issues" >&2
            exit 1
        fi
        ;;
esac
if [ -e "$dir/fail-$call" ]; then
    echo "gh: $(cat "$dir/fail-$call")" >&2
    exit 1
fi
body=""
while [ $# -gt 0 ]; do
    [ "$1" != --body-file ] || body="$2"
    shift
done
case "$call" in
    pr-list) cat "$dir/pr-list" 2> /dev/null ;;
    issue-list) cat "$dir/issue-list" 2> /dev/null ;;
    pr-create) cp "$body" "$dir/pr-body"; echo "https://github.com/fork/repo/pull/7" ;;
    pr-view) echo "PR_node7" ;;
    issue-create) cp "$body" "$dir/issue-body"; echo "https://github.com/fork/repo/issues/9" ;;
    api-repos/*) if [ -e "$dir/issues-off" ]; then echo false; else echo true; fi ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/gh"
}

# Tag one more upstream release that writes one file: $1 tag, $2 path, $3 text.
release() {
    printf '%s\n' "$3" > "$UP/$2"
    (cd "$UP" && git add -A && git commit -q -m "$1" && git tag "$1")
}

# The workflow's two jobs: merge in one checkout, publish in a fresh one that
# has only what the fork's repository holds, with the results directory
# carried between them. [NAME=value...] reach both; the output of both is in
# ci.log, and publish runs only if merge succeeded, as its job does.
run_ci() {
    rm -rf "$TEST_TMPDIR/work" "$TEST_TMPDIR/publish"
    git clone -q -b fork-main "$ORIGIN" "$TEST_TMPDIR/publish" || return 1
    ci_job "$FORK" merge "$@" > "$TEST_TMPDIR/ci.log" 2>&1 || return $?
    ci_job "$TEST_TMPDIR/publish" publish "$@" >> "$TEST_TMPDIR/ci.log" 2>&1
}

ci_job() {  # checkout, merge|publish, [NAME=value...]
    local checkout="$1" job="$2"
    shift 2
    (cd "$checkout" && env PATH="$TEST_TMPDIR/bin:$PATH" GH_STUB_DIR="$GH" SYNC_UPSTREAM_URL="$UP" \
        SYNC_BASE_BRANCH=fork-main GITHUB_STEP_SUMMARY="$TEST_TMPDIR/summary" \
        GITHUB_OUTPUT="$TEST_TMPDIR/output.$job" "$@" bash "$CI" "$job" "$TEST_TMPDIR/work")
}

# What the merge job told the workflow, which starts the publish job on it.
publish_wanted() {
    tail -n 1 "$TEST_TMPDIR/output.merge"
}

calls() {  # the gh calls that change something
    grep -v -e '^pr list ' -e '^issue list ' -e '^pr view ' -e '^api repos/' "$GH/calls" 2> /dev/null || true
}

origin_branches() {
    git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads
}

test_up_to_date_changes_nothing() {
    make_fixture || return 1
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" 'Up to date with upstream' || return 1
    assert_eq "" "$(calls)" || return 1
    # Nothing to open or close: the job that holds the token is not started.
    assert_eq publish=false "$(publish_wanted)" || return 1
    assert_eq fork-main "$(origin_branches)"
}

test_a_clean_release_becomes_a_pull_request_set_to_merge_itself() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    # The merge is on the fork as cs/sync-<tag>: a real merge whose second
    # parent is the release, so the release stays an ancestor once it lands.
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)" || return 1
    local head
    head=$(git -C "$ORIGIN" rev-parse cs/sync-v1.1)
    assert_eq "$(git -C "$FORK" rev-parse fork-main) $(git -C "$UP" rev-parse 'v1.1^{commit}')" \
        "$(git -C "$ORIGIN" log -1 --format=%P cs/sync-v1.1)" || return 1
    assert_eq notes "$(git -C "$ORIGIN" show cs/sync-v1.1:NOTES.md)" || return 1
    # Upstream's tags stay off the fork: a v* tag there starts its release workflow.
    assert_eq "" "$(git -C "$ORIGIN" tag)" || return 1
    assert_file_contains "$GH/calls" '^pr create --base fork-main --head cs/sync-v1.1 --title Merge upstream v1.1 --body-file ' || return 1
    assert_file_contains "$GH/pr-body" 'NOTES.md .*merged' || return 1
    assert_file_contains "$GH/pr-body" 'With a merge commit, never squashed or rebased' || return 1
    assert_file_not_contains "$GH/pr-body" "$TEST_TMPDIR/work" || return 1
    # Auto-merge is asked of the API for exactly the commit that was pushed.
    assert_file_contains "$GH/calls" "^api graphql -f pr=PR_node7 -f head=$head -f query=" || return 1
    grep -q 'enablePullRequestAutoMerge(input: {pullRequestId: \$pr, mergeMethod: MERGE, expectedHeadOid: \$head})' "$GH/calls" \
        || { cat "$GH/calls"; echo "  FAIL: auto-merge is not a merge commit pinned to the head"; return 1; }
    assert_file_not_contains "$GH/calls" '^pr merge' || return 1
    assert_file_contains "$TEST_TMPDIR/summary" 'v1.1 merged cleanly: https://github.com/fork/repo/pull/7' || return 1
    assert_eq publish=true "$(publish_wanted)" || return 1
    assert_file_not_contains "$GH/pr-body" 'not set to merge itself' || return 1
    # What the merge job hands over is a few small files, never the worktree
    # it merged in, and the token that can write was not in reach of the build.
    assert_eq 'body.md
have
head
outcome
report
sync.bundle
sync.log
tag' "$(ls "$TEST_TMPDIR/work")" || return 1
    assert_not_exists "$TEST_TMPDIR/work.worktree" || return 1
    assert_eq fork-main "$(git -C "$FORK" rev-parse --abbrev-ref HEAD)" || return 1
    assert_eq "" "$(git -C "$FORK" status --porcelain)"
}

# Merging runs the merged tree's build.sh: upstream's code, unreviewed. gh's
# token is not in its environment, and the job that has the one that can
# write runs no build at all.
test_the_merged_trees_build_never_sees_a_token() {
    make_fixture || return 1
    # shellcheck disable=SC2016  # the fixture's script, not this suite's variables
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "build saw: ${GH_TOKEN:-nothing} ${GITHUB_TOKEN:-nothing}" >> "$BUILD_LOG"' > "$UP/build.sh"
    (cd "$UP" && git add -A && git commit -q -m v1.1 && git tag v1.1) || return 1
    run_ci GH_TOKEN=secret-token GITHUB_TOKEN=secret-token BUILD_LOG="$TEST_TMPDIR/build.log" \
        || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'build saw: nothing nothing' "$(cat "$TEST_TMPDIR/build.log")" || return 1
    assert_file_contains "$GH/calls" '^pr create '
}

test_a_release_that_needs_a_person_becomes_an_issue() {
    make_fixture || return 1
    release v1.1 README.md 'cs is a session manager for Claude Code.' || return 1
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'issue create --title Sync upstream v1.1 needs a person --body-file '"$TEST_TMPDIR/work/body.md" \
        "$(calls)" || return 1
    assert_file_contains "$GH/issue-body" 'README.md .*1 conflict(s)' || return 1
    assert_file_contains "$GH/issue-body" 'scripts/sync-upstream.py start --to v1.1' || return 1
    assert_file_not_contains "$GH/issue-body" "$TEST_TMPDIR/work" || return 1
    assert_eq publish=true "$(publish_wanted)" || return 1
    # Nothing half-merged reaches the fork.
    assert_eq fork-main "$(origin_branches)"
}

# Issues are how the workflow asks for a person, and with them switched off
# every issue command fails. The run stops by name, before it merges or
# pushes anything, and says how to switch them on.
test_a_repository_with_issues_off_fails_by_name() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    : > "$GH/issues-off"
    local status=0
    run_ci || status=$?
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::The repository has Issues switched off' || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" 'gh repo edit --enable-issues' || return 1
    # The merge job stops before it hands the publish job anything.
    assert_not_exists "$TEST_TMPDIR/output.merge" || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)"
}

# An issue list gh could not read fails the run wherever it is asked for.
# Taken for "no issue", it would merge a release a person already has, or
# never start the job that closes the workflow's own.
test_issues_that_cannot_be_listed_fail_the_run() {
    make_fixture || return 1
    local status
    printf 'HTTP 502\n' > "$GH/fail-issue-list"
    # Up to date: asked whether an issue of the workflow's own is open.
    status=0
    run_ci || status=$?
    assert_eq 1 "$status" "up to date" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" "^::error::Could not list the repository's open issues" || return 1

    # A release to merge: asked whether a person already has it.
    release v1.1 NOTES.md notes || return 1
    status=0
    run_ci || status=$?
    assert_eq 1 "$status" "a release to merge" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" "^::error::Could not list the repository's open issues" || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1

    # Publishing: asked which of the workflow's issues it may close.
    rm "$GH/fail-issue-list"
    rm -rf "$TEST_TMPDIR/work" "$TEST_TMPDIR/publish"
    git clone -q -b fork-main "$ORIGIN" "$TEST_TMPDIR/publish" || return 1
    ci_job "$FORK" merge > "$TEST_TMPDIR/ci.log" 2>&1 || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    printf 'HTTP 502\n' > "$GH/fail-issue-list"
    status=0
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    assert_eq 1 "$status" "publishing" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" "^::error::Could not list the repository's open issues"
}

# A workflow upstream changed runs for the pull request, and once merged it
# runs on main, where the sync token is. A person reads it before that.
test_a_release_that_changes_a_workflow_never_merges_itself() {
    make_fixture || return 1
    mkdir -p "$UP/.github/workflows"
    release v1.1 .github/workflows/test.yml 'name: Test' || return 1
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^pr create --base fork-main --head cs/sync-v1.1 ' || return 1
    assert_file_not_contains "$GH/calls" '^api graphql' || return 1
    assert_file_contains "$GH/pr-body" 'This one is not set to merge itself' || return 1
    assert_file_contains "$GH/pr-body" '^- `.github/workflows/test.yml`$' || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" 'It waits for a person: it changes .github/workflows/test.yml' || return 1
    # SYNC_AUTO_MERGE=all is the owner saying upstream's workflows may land unread.
    : > "$GH/calls"
    git -C "$ORIGIN" update-ref -d refs/heads/cs/sync-v1.1
    git -C "$FORK" branch -q -D sync/v1.1
    run_ci SYNC_AUTO_MERGE=all || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^api graphql' || return 1
    assert_file_not_contains "$GH/pr-body" 'not set to merge itself'
}

# The script the job with the token runs is guarded like a workflow. Upstream
# has no such file, so only a merge job gone wrong could produce this.
test_a_merge_that_changes_the_publishing_script_never_merges_itself() {
    make_fixture || return 1
    mkdir -p "$UP/scripts"
    release v1.1 scripts/sync-upstream-ci.sh 'echo "not the fork'"'"'s script"' || return 1
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^pr create ' || return 1
    assert_file_not_contains "$GH/calls" '^api graphql' || return 1
    assert_file_contains "$GH/pr-body" '^- `scripts/sync-upstream-ci.sh`$'
}

test_only_the_oldest_missing_release_is_merged() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    release v1.2 CHANGES.md changes || return 1
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)" || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" '2 releases to merge; this run takes v1.1, the oldest' || return 1
    ! git -C "$ORIGIN" cat-file -e cs/sync-v1.1:CHANGES.md 2> /dev/null \
        || { echo "  FAIL: v1.2 was merged along with v1.1"; return 1; }
}

# Each of these means someone already has the release: the run leaves it alone.
test_a_release_someone_already_has_is_left_alone() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    printf 'OPEN\thttps://github.com/fork/repo/pull/7\n' > "$GH/pr-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" 'v1.1 already has a pull request (https://github.com/fork/repo/pull/7)' || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq publish=false "$(publish_wanted)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1

    : > "$GH/pr-list"
    printf '9\tSync upstream v1.1 needs a person\n4\tSomething else\n' > "$GH/issue-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" 'v1.1 waits for a person: an issue for it is open' || return 1
    assert_eq "" "$(calls)" || return 1
    # An issue of the workflow's own is open: publish runs, in case it can close it.
    assert_eq publish=true "$(publish_wanted)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1

    : > "$GH/issue-list"
    git -C "$FORK" push -q origin fork-main:refs/heads/cs/sync-v1.1 || return 1
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" 'already has a cs/sync-v1.1 branch and no pull request' || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq "$(git -C "$FORK" rev-parse fork-main)" "$(git -C "$ORIGIN" rev-parse cs/sync-v1.1)"
}

# Squashed, the pull request is merged and the release still is not in main:
# a green run that skipped it would hide that for good.
test_a_sync_merged_without_a_merge_commit_fails_the_run() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    printf 'MERGED\thttps://github.com/fork/repo/pull/7\n' > "$GH/pr-list"
    local status=0
    run_ci || status=$?
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::https://github.com/fork/repo/pull/7 is merged, but fork-main does not contain v1.1' || return 1
    assert_eq "" "$(calls)"
}

# No required checks on main, or the repository setting off: GitHub refuses,
# and the pull request waits for a person instead of merging untested.
test_a_refused_auto_merge_leaves_the_pull_request_open() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    printf 'Pull request is in clean status (enablePullRequestAutoMerge)\n' > "$GH/fail-api-graphql"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::warning::Auto-merge could not be turned on for https://github.com/fork/repo/pull/7: gh: Pull request is in clean status' || return 1
    assert_file_contains "$GH/calls" '^pr comment https://github.com/fork/repo/pull/7 --body Auto-merge could not be turned on' || return 1
    assert_file_not_contains "$GH/calls" '^pr merge' || return 1
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)"
}

test_auto_merge_can_be_switched_off() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    run_ci SYNC_AUTO_MERGE=false || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^pr create ' || return 1
    assert_file_not_contains "$GH/calls" '^api graphql' || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" 'Auto-merge is off'
}

# A pushed branch with no pull request would make every later run skip the release.
test_a_pull_request_that_cannot_be_opened_takes_its_branch_back() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    printf 'HTTP 422\n' > "$GH/fail-pr-create"
    local status=0
    run_ci || status=$?
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::Could not open the pull request for cs/sync-v1.1' || return 1
    assert_eq fork-main "$(origin_branches)"
}

# v1 is merged; v1.1 is the release still waiting, v7 is no release at all.
test_an_issue_is_closed_once_its_release_is_merged() {
    make_fixture || return 1
    release v1.1 README.md 'cs is a session manager for Claude Code.' || return 1
    printf '%s\n' $'9\tSync upstream v1 needs a person' $'3\tSync upstream v1.1 needs a person' \
        $'4\tSync upstream v7 needs a person' $'5\tSomething else' > "$GH/issue-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'issue close 9 --comment `fork-main` contains v1 now.' "$(calls)"
}

# The results directory comes from the job that ran upstream's build, so the
# job with the token reads it as data and checks it against the bundle.
test_publish_refuses_results_that_do_not_add_up() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    rm -rf "$TEST_TMPDIR/work" "$TEST_TMPDIR/publish"
    git clone -q -b fork-main "$ORIGIN" "$TEST_TMPDIR/publish" || return 1
    ci_job "$FORK" merge > "$TEST_TMPDIR/ci.log" 2>&1 || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    cp -R "$TEST_TMPDIR/work" "$TEST_TMPDIR/work.good"
    local status

    # A commit the bundle does not hold: here, the fork's own head.
    git -C "$FORK" rev-parse fork-main > "$TEST_TMPDIR/work/head"
    status=0
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    assert_eq 1 "$status" "a commit other than the bundle's" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::The bundle does not hold the commit the merge job named' || return 1

    # A checkout that is not at the branch the merge was made on.
    rm -rf "$TEST_TMPDIR/work" && cp -R "$TEST_TMPDIR/work.good" "$TEST_TMPDIR/work"
    git -C "$TEST_TMPDIR/publish" checkout -q --detach HEAD~1
    status=0
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    git -C "$TEST_TMPDIR/publish" checkout -q fork-main
    assert_eq 1 "$status" "a merge not based on the branch" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::The merge is not based on fork-main' || return 1

    local bad
    for bad in 'v1.1 --title x' '../v1.1' 'main'; do
        rm -rf "$TEST_TMPDIR/work" && cp -R "$TEST_TMPDIR/work.good" "$TEST_TMPDIR/work"
        printf '%s\n' "$bad" > "$TEST_TMPDIR/work/tag"
        status=0
        ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
        assert_eq 1 "$status" "tag '$bad'" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
        assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::The merge job left a tag that is not a release tag' || return 1
    done

    rm -rf "$TEST_TMPDIR/work" && cp -R "$TEST_TMPDIR/work.good" "$TEST_TMPDIR/work"
    printf 'publish-anything\n' > "$TEST_TMPDIR/work/outcome"
    status=0
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    assert_eq 1 "$status" "an unknown outcome" || { cat "$TEST_TMPDIR/ci.log"; return 1; }

    # None of it pushed or opened anything; the untouched results still publish.
    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1
    rm -rf "$TEST_TMPDIR/work" && cp -R "$TEST_TMPDIR/work.good" "$TEST_TMPDIR/work"
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^pr create --base fork-main --head cs/sync-v1.1 '
}

run_test test_up_to_date_changes_nothing
run_test test_a_clean_release_becomes_a_pull_request_set_to_merge_itself
run_test test_the_merged_trees_build_never_sees_a_token
run_test test_a_release_that_needs_a_person_becomes_an_issue
run_test test_a_repository_with_issues_off_fails_by_name
run_test test_issues_that_cannot_be_listed_fail_the_run
run_test test_a_release_that_changes_a_workflow_never_merges_itself
run_test test_a_merge_that_changes_the_publishing_script_never_merges_itself
run_test test_only_the_oldest_missing_release_is_merged
run_test test_a_release_someone_already_has_is_left_alone
run_test test_a_sync_merged_without_a_merge_commit_fails_the_run
run_test test_a_refused_auto_merge_leaves_the_pull_request_open
run_test test_auto_merge_can_be_switched_off
run_test test_a_pull_request_that_cannot_be_opened_takes_its_branch_back
run_test test_an_issue_is_closed_once_its_release_is_merged
run_test test_publish_refuses_results_that_do_not_add_up
report_results
