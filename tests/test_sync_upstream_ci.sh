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

# gh, as far as the script uses it. Every call is one line of $GH/calls. The
# pull request list answers from $GH/pr-list, as --jq would print it
# (isCrossRepository<TAB>state<TAB>url, newest first). The issue list answers
# from $GH/issue-list, number<TAB>title<TAB>labels (comma-separated), and as on
# GitHub --label keeps only the issues that carry it. A --body-file is kept as
# $GH/<pr|issue>-body, and a file named after a call ($GH/fail-pr-create,
# $GH/fail-api-graphql) makes that call fail. An issue is opened with a label
# only once label create has made it, as on GitHub. The repository has Issues
# switched on until $GH/issues-off exists; then, as on GitHub, every issue
# command fails.
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
name="${3:-}"
body=""
label=""
while [ $# -gt 0 ]; do
    [ "$1" != --body-file ] || body="$2"
    [ "$1" != --label ] || label="$2"
    shift
done
case "$call" in
    pr-list) cat "$dir/pr-list" 2> /dev/null ;;
    issue-list)
        awk -F '\t' -v label="$label" 'label == "" || index("," $3 ",", "," label ",") { print $1 "\t" $2 }' \
            "$dir/issue-list" 2> /dev/null
        ;;
    label-create) printf '%s\n' "$name" >> "$dir/labels" ;;
    pr-create) cp "$body" "$dir/pr-body"; echo "https://github.com/fork/repo/pull/7" ;;
    pr-view) echo "PR_node7" ;;
    issue-create)
        if [ -n "$label" ] && ! grep -Fqx -- "$label" "$dir/labels" 2> /dev/null; then
            echo "could not add label: '$label' not found" >&2
            exit 1
        fi
        cp "$body" "$dir/issue-body"
        echo "https://github.com/fork/repo/issues/9"
        ;;
    api-repos/*) if [ -e "$dir/issues-off" ]; then echo false; else echo true; fi ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/gh"
}

# The calls that open the workflow's issue for release $1: its label first,
# since gh opens no issue with a label the repository lacks.
issue_calls() {
    printf '%s\n' \
        "label create sync-upstream --force --color 5319e7 --description Releases the Sync upstream workflow left for a person" \
        "issue create --title Sync upstream $1 needs a person --label sync-upstream --body-file $TEST_TMPDIR/work/body.md"
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

# Fails unless body $1 says $2 (a line of this script's) before the report,
# and ends with the report in a fence that the first line able to close it,
# under CommonMark's rule (a run of backticks at least as long), does close.
# After it only a blank line and the note that the report was cut may follow:
# anything else came out of the report, past its fence.
assert_report_last() {  # body, text this script writes ahead of the report
    local verdict
    verdict=$(awk -v notice="$2" '
        !first && index($0, notice) { first = NR }
        !at && $0 == "`scripts/sync-upstream.py` reported:" { at = NR; next }
        at && NR == at + 2 { fence = $0; sub(/text$/, "", fence); next }
        fence != "" && !closed {
            line = $0
            gsub(/^ +| +$/, "", line)
            if (line ~ /^`+$/ && length(line) >= length(fence)) closed = NR
            if (closed && $0 != fence) wrong = NR
            next
        }
        closed && $0 != "" && $0 !~ /^The report is cut here/ { after = NR }
        END {
            if (!at) print "no report"
            else if (!first || first > at) print "\"" notice "\" is not ahead of the report"
            else if (fence !~ /^```+$/) print "the report is not fenced"
            else if (!closed) print "the report fence is never closed"
            else if (wrong) print "line " wrong " closes the report fence early"
            else if (after) print "line " after " is past the report fence"
            else print "ok"
        }' "$1")
    [ "$verdict" = ok ] || { echo "  FAIL: $1: $verdict"; cat "$1"; return 1; }
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
    # What publish can work out for itself (the release main had) is not among them.
    assert_eq 'body.md
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
    assert_eq "$(issue_calls v1.1)" "$(calls)" || return 1
    assert_file_contains "$GH/issue-body" 'README.md .*1 conflict(s)' || return 1
    assert_file_contains "$GH/issue-body" 'scripts/sync-upstream.py start --to v1.1' || return 1
    assert_file_not_contains "$GH/issue-body" "$TEST_TMPDIR/work" || return 1
    # What to do comes first; the report, which upstream's file names are in, last.
    assert_report_last "$GH/issue-body" 'scripts/sync-upstream.py start --to v1.1' || return 1
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

# A branch pushed to this repository runs its own workflows at once, with
# whatever token permissions they declare, before anyone has read them. So a
# release that changes one is not pushed: its issue lists what it changes,
# shows how to read that, and holds the command that approves exactly the
# release's commit.
test_a_release_that_changes_a_workflow_is_not_pushed_until_approved() {
    make_fixture || return 1
    mkdir -p "$UP/.github/workflows"
    release v1.1 .github/workflows/test.yml 'name: Test' || return 1
    run_ci GH_REPO=fork/repo || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq "$(issue_calls v1.1)" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1
    assert_eq "" "$(git -C "$ORIGIN" tag)" || return 1
    assert_file_contains "$GH/issue-body" '^- `.github/workflows/test.yml`$' || return 1
    assert_file_contains "$GH/issue-body" 'did not push it' || return 1
    assert_file_contains "$GH/issue-body" \
        "^git diff $(git -C "$UP" rev-parse 'v1^{commit}') v1.1 -- .github scripts/sync-upstream-ci.sh\$" || return 1
    # Named, so it starts this repository's workflow from any checkout.
    assert_file_contains "$GH/issue-body" \
        "^gh workflow run sync-upstream.yml -f approve=v1.1 -f commit=$(git -C "$UP" rev-parse 'v1.1^{commit}') --repo fork/repo\$" || return 1
    assert_file_not_contains "$GH/issue-body" "$TEST_TMPDIR/work" || return 1
    assert_file_contains "$TEST_TMPDIR/summary" 'v1.1 changes .github/workflows/test.yml' || return 1
    assert_eq publish=true "$(publish_wanted)" || return 1
    # SYNC_AUTO_MERGE=all is the owner saying upstream's workflows may land unread.
    : > "$GH/calls"
    git -C "$FORK" branch -q -D sync/v1.1
    run_ci SYNC_AUTO_MERGE=all || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)" || return 1
    assert_file_not_contains "$GH/calls" '^issue create' || return 1
    assert_file_contains "$GH/calls" '^api graphql' || return 1
    assert_file_contains "$GH/pr-body" '^- `.github/workflows/test.yml`$'
}

# The script the job with the token runs is guarded like a workflow.
test_a_merge_that_changes_the_publishing_script_is_not_pushed_until_approved() {
    make_fixture || return 1
    mkdir -p "$UP/scripts"
    release v1.1 scripts/sync-upstream-ci.sh 'echo "not the fork'"'"'s script"' || return 1
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq "$(issue_calls v1.1)" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1
    assert_file_contains "$GH/issue-body" '^- `scripts/sync-upstream-ci.sh`$' || return 1
    assert_file_contains "$GH/issue-body" '^gh workflow run sync-upstream.yml -f approve=v1.1 -f commit='
}

# A person read the change and ran the command from the issue. That run goes
# past the release's open issue, merges it again, pushes it and opens its pull
# request, which then merges itself like any clean release. The issue stays
# open until main contains the release.
test_an_approved_release_is_pushed_and_gets_its_pull_request() {
    make_fixture || return 1
    mkdir -p "$UP/.github/workflows"
    release v1.1 .github/workflows/test.yml 'name: Test' || return 1
    local commit
    commit=$(git -C "$UP" rev-parse 'v1.1^{commit}')
    printf '9\tSync upstream v1.1 needs a person\tsync-upstream\n' > "$GH/issue-list"
    run_ci SYNC_APPROVE_TAG=v1.1 SYNC_APPROVE_COMMIT="$commit" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)" || return 1
    assert_eq "$(git -C "$FORK" rev-parse fork-main) $commit" "$(git -C "$ORIGIN" log -1 --format=%P cs/sync-v1.1)" || return 1
    assert_eq "" "$(git -C "$ORIGIN" tag)" || return 1
    assert_file_contains "$GH/calls" '^pr create --base fork-main --head cs/sync-v1.1 ' || return 1
    assert_file_contains "$GH/pr-body" "approved by workflow dispatch for commit \`$commit\`" || return 1
    assert_file_contains "$GH/pr-body" '^- `.github/workflows/test.yml`$' || return 1
    assert_file_contains "$GH/calls" '^api graphql ' || return 1
    assert_eq "" "$(calls | grep '^issue ' || true)"
}

# An approval is for one commit. A tag upstream has moved since, or an id
# mistyped, stops the run by name before anything is pushed, in either job.
test_an_approval_of_another_commit_is_refused() {
    make_fixture || return 1
    mkdir -p "$UP/.github/workflows"
    release v1.1 .github/workflows/test.yml 'name: Test' || return 1
    printf '9\tSync upstream v1.1 needs a person\tsync-upstream\n' > "$GH/issue-list"
    local status commit other
    commit=$(git -C "$UP" rev-parse 'v1.1^{commit}')
    other=$(git -C "$UP" rev-parse 'v1^{commit}')
    status=0
    run_ci SYNC_APPROVE_TAG=v1.1 SYNC_APPROVE_COMMIT="$other" || status=$?
    assert_eq 1 "$status" "another commit" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" "^::error::v1.1 points at $commit, not at the approved $other: the tag moved" || return 1
    assert_not_exists "$TEST_TMPDIR/output.merge" || return 1

    # What is not a release tag and a full commit id is refused before anything runs.
    status=0
    run_ci SYNC_APPROVE_TAG=main SYNC_APPROVE_COMMIT="$commit" || status=$?
    assert_eq 1 "$status" "a branch for a tag" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::approve must name a release tag' || return 1
    status=0
    run_ci SYNC_APPROVE_TAG=v1.1 SYNC_APPROVE_COMMIT="${commit%????}" || status=$?
    assert_eq 1 "$status" "a short commit id" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::commit must be the release' || return 1
    status=0
    run_ci SYNC_APPROVE_TAG=v1.1 || status=$?
    assert_eq 1 "$status" "no commit" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::commit must be the release' || return 1

    # publish checks it again, against the tag as it fetches it.
    rm -rf "$TEST_TMPDIR/work" "$TEST_TMPDIR/publish"
    git clone -q -b fork-main "$ORIGIN" "$TEST_TMPDIR/publish" || return 1
    ci_job "$FORK" merge SYNC_APPROVE_TAG=v1.1 SYNC_APPROVE_COMMIT="$commit" > "$TEST_TMPDIR/ci.log" 2>&1 \
        || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    status=0
    ci_job "$TEST_TMPDIR/publish" publish SYNC_APPROVE_TAG=v1.1 SYNC_APPROVE_COMMIT="$other" > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    assert_eq 1 "$status" "publish, another commit" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" "^::error::v1.1 points at $commit, not at the approved $other: the tag moved" || return 1

    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)"
}

# Releases are merged in order, so only the oldest one main lacks can be approved.
test_an_approval_of_a_release_that_is_not_next_is_refused() {
    make_fixture || return 1
    local status
    status=0
    run_ci SYNC_APPROVE_TAG=v1 SYNC_APPROVE_COMMIT="$(git -C "$UP" rev-parse 'v1^{commit}')" || status=$?
    assert_eq 1 "$status" "up to date" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::This run approves v1, but fork-main lacks no upstream release' || return 1

    mkdir -p "$UP/.github/workflows"
    release v1.1 NOTES.md notes || return 1
    release v1.2 .github/workflows/test.yml 'name: Test' || return 1
    status=0
    run_ci SYNC_APPROVE_TAG=v1.2 SYNC_APPROVE_COMMIT="$(git -C "$UP" rev-parse 'v1.2^{commit}')" || status=$?
    assert_eq 1 "$status" "not the oldest" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::This run approves v1.2, but the oldest release fork-main lacks is v1.1' || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)"
}

# A release that does not merge cleanly onto main as it is now needs a person
# to merge it by hand, not an approval, and its issue is already open: the
# run fails by name instead of opening a second one.
test_an_approved_release_that_does_not_merge_cleanly_fails_the_run() {
    make_fixture || return 1
    release v1.1 README.md 'cs is a session manager for Claude Code.' || return 1
    printf '9\tSync upstream v1.1 needs a person\tsync-upstream\n' > "$GH/issue-list"
    local status=0
    run_ci SYNC_APPROVE_TAG=v1.1 SYNC_APPROVE_COMMIT="$(git -C "$UP" rev-parse 'v1.1^{commit}')" || status=$?
    assert_eq 1 "$status" "a conflict" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::v1.1 was approved, but it does not merge cleanly' || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)"
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
    printf 'false\tOPEN\thttps://github.com/fork/repo/pull/7\n' > "$GH/pr-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" 'v1.1 already has a pull request (https://github.com/fork/repo/pull/7)' || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq publish=false "$(publish_wanted)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1

    : > "$GH/pr-list"
    printf '9\tSync upstream v1.1 needs a person\tsync-upstream\n4\tSomething else\tbug\n' > "$GH/issue-list"
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
    printf 'false\tMERGED\thttps://github.com/fork/repo/pull/7\n' > "$GH/pr-list"
    local status=0
    run_ci || status=$?
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::https://github.com/fork/repo/pull/7 is merged, but fork-main does not contain v1.1' || return 1
    assert_eq "" "$(calls)"
}

# gh pr list --head matches a branch of that name in any repository, and
# anyone can open a pull request from a fork's cs/sync-<tag>. Only one from
# this repository's own branch is the sync's.
test_a_pull_request_from_another_repository_never_holds_a_release() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    printf '%s\n' $'true\tOPEN\thttps://github.com/fork/repo/pull/8' \
        $'true\tCLOSED\thttps://github.com/fork/repo/pull/6' > "$GH/pr-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^pr list --head cs/sync-v1.1 --state all --json isCrossRepository,state,url ' || return 1
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)" || return 1
    assert_file_contains "$GH/calls" '^pr create --base fork-main --head cs/sync-v1.1 '
}

# Closing the sync pull request is how a person would turn a release down,
# but a release cannot be skipped: the next one merges onto it. Taken for
# "someone has it", the closed pull request would hold every later release
# back for good, with every run green.
test_a_sync_pull_request_closed_without_merging_fails_the_run() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    printf 'false\tCLOSED\thttps://github.com/fork/repo/pull/7\n' > "$GH/pr-list"
    local status=0
    run_ci || status=$?
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::https://github.com/fork/repo/pull/7 was closed without merging, and v1.1 cannot be skipped' || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" 'Reopen it, or merge v1.1 by hand' || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1
    # The newest of this repository's pull requests for the branch is the one that counts.
    printf '%s\n' $'false\tOPEN\thttps://github.com/fork/repo/pull/8' \
        $'false\tCLOSED\thttps://github.com/fork/repo/pull/7' > "$GH/pr-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" 'v1.1 already has a pull request (https://github.com/fork/repo/pull/8)'
}

# Anyone can open an issue with any title, but only someone with triage
# access can label one. An issue without the workflow's label neither holds a
# release back nor starts the job that holds the token, and is never closed.
test_only_issues_with_the_workflows_label_count() {
    make_fixture || return 1
    printf '5\tSync upstream v1 needs a person\tbug\n' > "$GH/issue-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^issue list --label sync-upstream ' || return 1
    assert_eq publish=false "$(publish_wanted)" || return 1
    assert_eq "" "$(calls)" || return 1

    release v1.1 NOTES.md notes || return 1
    printf '5\tSync upstream v1.1 needs a person\n' > "$GH/issue-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)" || return 1
    assert_file_contains "$GH/calls" '^pr create --base fork-main --head cs/sync-v1.1 '
}

# A release left to someone for longer than SYNC_STALL_DAYS since it was
# tagged fails the run by name: a stall that stays green is never seen. The
# publish job fails, once it has done its other work, so the issues it can
# close are closed and the merge job's outputs stay true.
test_a_release_held_too_long_fails_the_run() {
    make_fixture || return 1
    (export GIT_COMMITTER_DATE="$(($(date +%s) - 10 * 86400)) +0000" && release v1.1 NOTES.md notes) || return 1
    release v1.2 CHANGES.md changes || return 1
    local status tagged
    tagged=$(git -C "$UP" for-each-ref --format='%(creatordate:short)' refs/tags/v1.1)

    # Its pull request is open: a check that fails, or auto-merge off.
    printf 'false\tOPEN\thttps://github.com/fork/repo/pull/7\n' > "$GH/pr-list"
    printf '9\tSync upstream v1 needs a person\tsync-upstream\n' > "$GH/issue-list"
    status=0
    run_ci || status=$?
    assert_eq 1 "$status" "held by its pull request" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq publish=true "$(publish_wanted)" || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" \
        "^::error::v1.1, tagged $tagged, has waited longer than SYNC_STALL_DAYS (3 days) allows: its pull request https://github.com/fork/repo/pull/7 is still open" || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::v1.1.* 1 later release waits behind it\.$' || return 1
    # The issue of a merged release is closed all the same, and the run fails last.
    assert_eq 'issue close 9 --comment `fork-main` contains v1 now.' "$(calls)" || return 1
    assert_file_contains "$TEST_TMPDIR/summary" 'Closed #9' || return 1
    case "$(tail -n 2 "$TEST_TMPDIR/ci.log" | head -n 1)" in
        '::error::v1.1, tagged '*) ;;
        *) cat "$TEST_TMPDIR/ci.log"; echo "  FAIL: the run did not fail last"; return 1 ;;
    esac

    # Read as data: the merge job ran upstream's build, and a second line
    # starting with :: would be a command to the runner.
    printf 'held\n::warning::not from this script\n' > "$TEST_TMPDIR/work/stall"
    status=0
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    assert_eq 1 "$status" "a stall of two lines" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::held$' || return 1
    assert_file_not_contains "$TEST_TMPDIR/ci.log" '^::warning::not from this script' || return 1

    # A branch and no pull request: a run that stopped between the push and the pull request.
    : > "$GH/pr-list"
    : > "$GH/issue-list"
    : > "$GH/calls"
    git -C "$FORK" push -q origin fork-main:refs/heads/cs/sync-v1.1 || return 1
    status=0
    run_ci || status=$?
    assert_eq 1 "$status" "held by a branch" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq publish=true "$(publish_wanted)" || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" \
        '^::error::v1.1, .*: the fork has a cs/sync-v1.1 branch and no pull request for it\..*git push origin :cs/sync-v1.1' || return 1
    assert_eq "" "$(calls)" || return 1
    git -C "$FORK" push -q origin :refs/heads/cs/sync-v1.1 || return 1

    # Its issue is open: nobody has merged it by hand or approved it.
    printf '3\tSync upstream v1.1 needs a person\tsync-upstream\n' > "$GH/issue-list"
    status=0
    run_ci || status=$?
    assert_eq 1 "$status" "held by its issue" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::v1.1, .*: issue #3 is still open' || return 1

    # How long is the repository's to say, and a value that is no number of
    # days is the default, not no limit at all.
    status=0
    run_ci SYNC_STALL_DAYS=30 || status=$?
    assert_eq 0 "$status" "within SYNC_STALL_DAYS=30" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_not_contains "$TEST_TMPDIR/ci.log" '^::error::' || return 1
    status=0
    run_ci SYNC_STALL_DAYS=soon || status=$?
    assert_eq 1 "$status" "SYNC_STALL_DAYS=soon" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::warning::SYNC_STALL_DAYS is not a whole number of days' || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::v1.1, .*SYNC_STALL_DAYS (3 days)' || return 1
    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)"
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

# A kill switch a typo leaves on is not one. The value is read in any case,
# and one that is not true, all or false turns auto-merge off and says so.
test_auto_merge_is_off_for_any_value_but_true_or_all() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    run_ci SYNC_AUTO_MERGE=False || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^pr create ' || return 1
    assert_file_not_contains "$GH/calls" '^api graphql' || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" 'Auto-merge is off' || return 1
    assert_file_not_contains "$TEST_TMPDIR/ci.log" '^::warning::' || return 1

    local value
    for value in off TRUE; do
        : > "$GH/calls"
        : > "$TEST_TMPDIR/summary"
        git -C "$ORIGIN" branch -q -D cs/sync-v1.1 || return 1
        git -C "$FORK" branch -q -D sync/v1.1 || return 1
        run_ci SYNC_AUTO_MERGE="$value" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
        assert_file_contains "$GH/calls" '^pr create ' || return 1
        case "$value" in
            off)
                assert_file_not_contains "$GH/calls" '^api graphql' || return 1
                assert_file_contains "$TEST_TMPDIR/ci.log" \
                    "^::warning::SYNC_AUTO_MERGE is 'off', which is not true, all or false, so auto-merge is off" || return 1
                assert_file_contains "$TEST_TMPDIR/summary" 'Auto-merge is off' || return 1
                ;;
            TRUE)
                assert_file_contains "$GH/calls" '^api graphql ' || return 1
                assert_file_not_contains "$TEST_TMPDIR/ci.log" '^::warning::' || return 1
                ;;
        esac
    done
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

# The report is upstream's to write: the file names, and what its build.sh
# prints to stderr. In a fence of three backticks, a line of three would end
# the block, and a line opening an HTML comment after it would hide the rest
# of the body, posted under the token owner's name. So every body says what
# this script has to say first, and ends with the report, in a fence no line
# of it can close.
test_the_report_comes_last_in_a_fence_it_cannot_close() {
    make_fixture || return 1
    mkdir -p "$UP/.github/workflows"
    printf 'name: Test\n' > "$UP/.github/workflows/test.yml"
    cat > "$UP/build.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '```' '<!--' '   ``````' '-->' >&2
EOF
    (cd "$UP" && git add -A && git commit -q -m v1.1 && git tag v1.1) || return 1
    # A workflow changed: the issue that asks for the approval.
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/issue-body" '^<!--$' || return 1
    assert_report_last "$GH/issue-body" 'did not push it' || return 1
    assert_report_last "$GH/issue-body" 'gh workflow run sync-upstream.yml -f approve=v1.1' || return 1
    # Pushed all the same: the pull request, and what it says of that.
    : > "$GH/calls"
    git -C "$FORK" branch -q -D sync/v1.1
    run_ci SYNC_AUTO_MERGE=all || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/pr-body" '^<!--$' || return 1
    assert_report_last "$GH/pr-body" 'was pushed without approval' || return 1
    assert_report_last "$GH/pr-body" 'With a merge commit, never squashed or rebased'
}

# GitHub refuses a body over 65,536 characters, so a release with a long
# enough report would fail every run. The report is cut to fit, and says
# where all of it is; so is the list of guarded files a release changes.
test_a_huge_report_is_cut_to_fit_a_body() {
    make_fixture || return 1
    mkdir -p "$UP/.github/many"
    local i long size
    long=$(printf '%0180d' 0)
    for i in $(seq 1 300); do printf 'x\n' > "$UP/.github/many/$long-$i"; done
    cat > "$UP/build.sh" <<'EOF'
#!/usr/bin/env bash
yes 'build.sh says this, over and over' | head -n 20000 >&2
EOF
    (cd "$UP" && git add -A && git commit -q -m v1.1 && git tag v1.1) || return 1
    # Outside a workflow run there is no run to link to.
    run_ci GITHUB_SERVER_URL= GITHUB_REPOSITORY= GITHUB_RUN_ID= || { tail -n 20 "$TEST_TMPDIR/ci.log"; return 1; }
    size=$(wc -c < "$GH/issue-body" | tr -d ' ')
    [ "$size" -lt 65536 ] || { echo "  FAIL: the issue body is $size bytes"; return 1; }
    assert_report_last "$GH/issue-body" 'did not push it' || return 1
    assert_file_contains "$GH/issue-body" '^- and [0-9][0-9]* more$' || return 1
    assert_file_contains "$GH/issue-body" "^The report is cut here, after [0-9][0-9]* of its [0-9][0-9]* lines, .* All of it is in the merge job's log\\.\$" || return 1

    : > "$GH/calls"
    git -C "$FORK" branch -q -D sync/v1.1
    run_ci SYNC_AUTO_MERGE=all GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=fork/repo GITHUB_RUN_ID=42 \
        || { tail -n 20 "$TEST_TMPDIR/ci.log"; return 1; }
    size=$(wc -c < "$GH/pr-body" | tr -d ' ')
    [ "$size" -lt 65536 ] || { echo "  FAIL: the pull request body is $size bytes"; return 1; }
    assert_report_last "$GH/pr-body" 'was pushed without approval' || return 1
    assert_file_contains "$GH/pr-body" '^- and [0-9][0-9]* more$' || return 1
    assert_file_contains "$GH/pr-body" "All of it is in the merge job's log in https://github.example/fork/repo/actions/runs/42\\.\$"
}

# v1 is merged; v1.1 is the release still waiting, v7 is no release at all.
test_an_issue_is_closed_once_its_release_is_merged() {
    make_fixture || return 1
    release v1.1 README.md 'cs is a session manager for Claude Code.' || return 1
    printf '%s\n' $'9\tSync upstream v1 needs a person\tsync-upstream' $'3\tSync upstream v1.1 needs a person\tsync-upstream' \
        $'4\tSync upstream v7 needs a person\tsync-upstream' $'5\tSomething else\tbug' > "$GH/issue-list"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'issue close 9 --comment `fork-main` contains v1 now.' "$(calls)"
}

# Closing issues is housekeeping, done once the release is seen to. An issue
# gh cannot close (a locked one, an API blip) is a warning, and the release
# still gets its pull request.
test_an_issue_that_cannot_be_closed_never_holds_a_release_back() {
    make_fixture || return 1
    release v1.1 NOTES.md notes || return 1
    printf '9\tSync upstream v1 needs a person\tsync-upstream\n' > "$GH/issue-list"
    printf 'HTTP 403: Issue is locked\n' > "$GH/fail-issue-close"
    run_ci || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)" || return 1
    assert_file_contains "$GH/calls" '^pr create --base fork-main --head cs/sync-v1.1 ' || return 1
    assert_file_contains "$GH/calls" '^api graphql ' || return 1
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::warning::Could not close #9' || return 1
    # Tried after the pull request was opened and set to merge itself.
    assert_eq 'issue close 9 --comment `fork-main` contains v1 now.' "$(calls | tail -n 1)"
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

# Puts in work/ what the merge job would leave for a commit with tree $1 and
# parents $2...: its id, and a bundle holding it as sync/v1.1.
forge() {
    local tree="$1" parent commit
    local parents=()
    shift
    for parent in "$@"; do parents+=(-p "$parent"); done
    commit=$(git -C "$FORK" commit-tree "$tree" "${parents[@]}" -m 'Merge upstream v1.1') || return 1
    rm -rf "$TEST_TMPDIR/work" && cp -R "$TEST_TMPDIR/work.good" "$TEST_TMPDIR/work"
    git -C "$FORK" update-ref refs/heads/sync/v1.1 "$commit" || return 1
    git -C "$FORK" bundle create --quiet "$TEST_TMPDIR/work/sync.bundle" refs/heads/sync/v1.1 || return 1
    printf '%s\n' "$commit" > "$TEST_TMPDIR/work/head"
}

# Every upstream commit the fork ever merged is an ancestor of main, and the
# job that ran upstream's build writes the results. If any ancestor would do
# as the merge's first parent, that job could pick what the guarded paths are
# compared with, while GitHub merges the pull request onto main's head.
# publish takes only a merge of its own checkout with the release as upstream
# has it.
test_publish_refuses_a_merge_of_anything_but_main_and_the_release() {
    make_fixture || return 1
    # A workflow of the fork's own, which an older fork commit does not have.
    mkdir -p "$FORK/.github/workflows"
    printf 'name: Fork\n' > "$FORK/.github/workflows/fork.yml"
    (cd "$FORK" && git add -A && git commit -q -m "the fork's workflow" && git push -q origin fork-main) || return 1
    release v1.1 NOTES.md notes || return 1
    rm -rf "$TEST_TMPDIR/work" "$TEST_TMPDIR/publish"
    git clone -q -b fork-main "$ORIGIN" "$TEST_TMPDIR/publish" || return 1
    ci_job "$FORK" merge > "$TEST_TMPDIR/ci.log" 2>&1 || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    cp -R "$TEST_TMPDIR/work" "$TEST_TMPDIR/work.good"
    local main older v1 v1_1 merged forged status
    main=$(git -C "$FORK" rev-parse fork-main)
    older=$(git -C "$FORK" rev-parse fork-main~1)
    v1=$(git -C "$FORK" rev-parse 'v1^{commit}')
    v1_1=$(git -C "$FORK" rev-parse 'v1.1^{commit}')
    merged=$(git -C "$FORK" rev-parse 'sync/v1.1^{tree}')
    # The release merged as it should, less the fork's workflow.
    forged=$(cd "$FORK" && export GIT_INDEX_FILE="$TEST_TMPDIR/forged.index" \
        && git read-tree "$merged" && git rm -q --cached .github/workflows/fork.yml && git write-tree) || return 1

    # First parent an older fork commit, which has no workflow either: compared
    # with it the guarded paths read unchanged, yet landing it on main deletes one.
    forge "$forged" "$older" "$v1_1" || return 1
    assert_eq .github/workflows/fork.yml "$(git -C "$FORK" diff --name-only "$main" "$(cat "$TEST_TMPDIR/work/head")" -- .github)" || return 1
    status=0
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    assert_eq 1 "$status" "first parent an older fork commit" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" '^::error::The merge is not based on fork-main as this job checked it out' || return 1

    # Second parent some other upstream commit than the release.
    forge "$merged" "$main" "$v1" || return 1
    status=0
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    assert_eq 1 "$status" "second parent not the release" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" "^::error::The merge's second parent is not v1.1 as upstream has it" || return 1

    # A third parent brings in what neither side has.
    forge "$merged" "$main" "$v1_1" "$older" || return 1
    status=0
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || status=$?
    assert_eq 1 "$status" "three parents" || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/ci.log" "^::error::The merge job's commit has 3 parents" || return 1

    # None of it pushed or opened anything; the untouched results still publish,
    # and the release's tag, fetched to check against, stays off the fork.
    assert_eq "" "$(calls)" || return 1
    assert_eq fork-main "$(origin_branches)" || return 1
    rm -rf "$TEST_TMPDIR/work" && cp -R "$TEST_TMPDIR/work.good" "$TEST_TMPDIR/work"
    ci_job "$TEST_TMPDIR/publish" publish > "$TEST_TMPDIR/ci.log" 2>&1 || { cat "$TEST_TMPDIR/ci.log"; return 1; }
    assert_file_contains "$GH/calls" '^pr create --base fork-main --head cs/sync-v1.1 ' || return 1
    assert_eq 'cs/sync-v1.1
fork-main' "$(origin_branches)" || return 1
    assert_eq "" "$(git -C "$ORIGIN" tag)"
}

run_test test_up_to_date_changes_nothing
run_test test_a_clean_release_becomes_a_pull_request_set_to_merge_itself
run_test test_the_merged_trees_build_never_sees_a_token
run_test test_a_release_that_needs_a_person_becomes_an_issue
run_test test_a_repository_with_issues_off_fails_by_name
run_test test_issues_that_cannot_be_listed_fail_the_run
run_test test_a_release_that_changes_a_workflow_is_not_pushed_until_approved
run_test test_a_merge_that_changes_the_publishing_script_is_not_pushed_until_approved
run_test test_an_approved_release_is_pushed_and_gets_its_pull_request
run_test test_an_approval_of_another_commit_is_refused
run_test test_an_approval_of_a_release_that_is_not_next_is_refused
run_test test_an_approved_release_that_does_not_merge_cleanly_fails_the_run
run_test test_only_the_oldest_missing_release_is_merged
run_test test_a_release_someone_already_has_is_left_alone
run_test test_a_sync_merged_without_a_merge_commit_fails_the_run
run_test test_a_pull_request_from_another_repository_never_holds_a_release
run_test test_a_sync_pull_request_closed_without_merging_fails_the_run
run_test test_only_issues_with_the_workflows_label_count
run_test test_a_release_held_too_long_fails_the_run
run_test test_a_refused_auto_merge_leaves_the_pull_request_open
run_test test_auto_merge_can_be_switched_off
run_test test_auto_merge_is_off_for_any_value_but_true_or_all
run_test test_a_pull_request_that_cannot_be_opened_takes_its_branch_back
run_test test_the_report_comes_last_in_a_fence_it_cannot_close
run_test test_a_huge_report_is_cut_to_fit_a_body
run_test test_an_issue_is_closed_once_its_release_is_merged
run_test test_an_issue_that_cannot_be_closed_never_holds_a_release_back
run_test test_publish_refuses_results_that_do_not_add_up
run_test test_publish_refuses_a_merge_of_anything_but_main_and_the_release
report_results
