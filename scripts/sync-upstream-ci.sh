#!/usr/bin/env bash
# ABOUTME: The GitHub Actions side of scripts/sync-upstream.py: merges the oldest upstream release the fork lacks.
# ABOUTME: A clean merge becomes a cs/sync-<tag> pull request set to merge itself; one that needs a person becomes an issue.
set -euo pipefail

# Run by .github/workflows/sync-upstream.yml, in two jobs that share nothing
# but a directory of results:
#
#   sync-upstream-ci.sh merge <dir>     reads only: needs no token that can write
#   sync-upstream-ci.sh publish <dir>   pushes, opens the pull request or the issue
#
# They are apart because merging runs build.sh from the merged tree, which is
# upstream's code before anyone has looked at it. That job holds no secret.
# publish holds one, and runs nothing from the merge: it takes the commit out
# of a bundle and hands it to git and gh.
#
# publish needs gh signed in (GH_TOKEN, GH_REPO) as someone whose pushes and
# pull requests start workflows. The token GitHub hands a workflow does not,
# and a sync pull request no check ran on would be merged untested.
#
# A release that changes what runs with the token (a workflow, or this
# script) still gets its pull request, but is never set to merge itself: a
# person reads that part first. Until it is merged the token is out of its
# reach, as long as the secret is kept in an environment only main may use:
# a changed workflow runs for the pull request, on a ref that is not main.
#
# One release a run, the oldest first, since each is merged onto the one
# before it. A release that already has a pull request, a cs/sync-<tag>
# branch or an open issue is left to whoever has it, and the later ones wait
# behind it. Tags are fetched from upstream and never pushed: a v* tag pushed
# to the fork would start its release workflow.

UPSTREAM_REMOTE="${SYNC_UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${SYNC_UPSTREAM_URL:-https://github.com/hex/claude-sessions.git}"
BASE_BRANCH="${SYNC_BASE_BRANCH:-main}"
# true: a clean merge merges itself, unless it changes a guarded path. false:
# every pull request waits for a person. all: guarded paths merge themselves too.
AUTO_MERGE="${SYNC_AUTO_MERGE:-true}"
# What the job holding the token runs or is defined by.
GUARDED=(.github scripts/sync-upstream-ci.sh)
ISSUE_PREFIX="Sync upstream "
ISSUE_SUFFIX=" needs a person"
SYNC_PY="$(cd -- "$(dirname -- "$0")" && pwd)/sync-upstream.py"

# The run's outcome, in the log and on the run's summary page.
note() {
    printf '%s\n' "$*"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n\n' "$*" >> "$GITHUB_STEP_SUMMARY"
}

fail() {
    printf '::error::%s\n' "$*"
    note "$*"
    exit 1
}

# Without gh's token: start runs the merged tree's build.sh.
sync() {
    env -u GH_TOKEN -u GITHUB_TOKEN python3 "$SYNC_PY" --remote "$UPSTREAM_REMOTE" "$@"
}

open_issues() {  # number<TAB>title, one open issue a line
    gh issue list --state open --limit 200 --json number,title --jq '.[] | "\(.number)\t\(.title)"'
}

# What the merge job found, for the publish job: one value a file.
result() {  # name, value
    printf '%s\n' "$2" > "$out/$1"
}

# The oldest missing release, merged in a worktree of its own. Leaves in <dir>:
# outcome (none: up to date; skip: someone has it; clean: merged and committed;
# person: it needs one), and with clean or person the tag, the report, the
# release the fork had before, and for clean the commit and a bundle holding it.
merge() {
    merge_release
    # The publish job, and with it the token, is only started for a pull
    # request or an issue to open, or for an issue of its own it may close.
    local publish=false
    case "$(cat "$out/outcome")" in
        clean | person) publish=true ;;
        *) ! open_issues | cut -f2- | grep -x -- "$ISSUE_PREFIX"'v.*'"$ISSUE_SUFFIX" > /dev/null || publish=true ;;
    esac
    [ -z "${GITHUB_OUTPUT:-}" ] || printf 'publish=%s\n' "$publish" >> "$GITHUB_OUTPUT"
}

merge_release() {
    result outcome none
    git remote get-url "$UPSTREAM_REMOTE" > /dev/null 2>&1 || git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
    local tags tag branch waiting pr found worktree log status
    tags=$(sync missing)
    if [ -z "$tags" ]; then
        note "Up to date with upstream."
        return 0
    fi
    tag=${tags%%$'\n'*}
    branch="cs/sync-$tag"
    waiting=$(printf '%s\n' "$tags" | wc -l | tr -d ' ')
    [ "$waiting" = 1 ] || note "$waiting releases to merge; this run takes $tag, the oldest."

    result outcome skip
    pr=$(gh pr list --head "$branch" --state all --json state,url --jq '.[0] | select(.) | "\(.state)\t\(.url)"')
    if [ -n "$pr" ]; then
        # Squashed or rebased, the pull request is merged and the release still
        # is not an ancestor of main: every later sync would start from an
        # older one. A green run that skipped it would hide that for good.
        [ "${pr%%$'\t'*}" != MERGED ] \
            || fail "${pr#*$'\t'} is merged, but $BASE_BRANCH does not contain $tag: it was not landed with a merge commit. Merge $tag again by hand (scripts/sync-upstream.py start --to $tag) and land that with a merge commit."
        note "$tag already has a pull request (${pr#*$'\t'}); nothing to do until it lands."
        return 0
    fi
    found=0
    git ls-remote --exit-code --heads origin "refs/heads/$branch" > /dev/null 2>&1 || found=$?
    case "$found" in
        0)
            note "$tag: the fork already has a $branch branch and no pull request for it; left to whoever pushed it."
            return 0
            ;;
        2) ;;
        *) fail "Could not read the fork's branches (git ls-remote exited $found)." ;;
    esac
    # Not grep -q: it stops at the first match, and under pipefail the gh it
    # leaves writing to a closed pipe would turn that match into a failure.
    if open_issues | cut -f2- | grep -Fx -- "$ISSUE_PREFIX$tag$ISSUE_SUFFIX" > /dev/null; then
        note "$tag waits for a person: an issue for it is open."
        return 0
    fi

    # Beside the results, not among them: they are uploaded for the publish job.
    worktree="$out.worktree"
    log="$out/sync.log"
    result tag "$tag"
    result have "$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2> /dev/null || true)"
    status=0
    sync start --to "$tag" --no-fetch --skip-tests --worktree "$worktree" > "$log" 2>&1 || status=$?
    cat "$log"
    # The report without what only makes sense beside the sync worktree, which
    # is gone when the run ends.
    { grep -v -F -e "$worktree" "$log" | grep -v -e '^Tests skipped' -e '^Bring it into '; } > "$out/report" || true
    case "$status" in
        0)
            result head "$(git -C "$worktree" rev-parse HEAD)"
            git bundle create --quiet "$out/sync.bundle" "refs/heads/sync/$tag" ^HEAD
            result outcome clean
            note "$tag merged cleanly."
            ;;
        1)
            result outcome person
            note "$tag needs a person."
            ;;
        *) fail "scripts/sync-upstream.py failed on $tag (exit $status); see the log above." ;;
    esac
    git worktree remove --force "$worktree" > /dev/null 2>&1 || true
}

# An issue this workflow opened for a release that has since been merged.
close_merged_issues() {
    local number title merged
    open_issues | while IFS=$'\t' read -r number title; do
        case "$title" in
            "$ISSUE_PREFIX"v*"$ISSUE_SUFFIX") ;;
            *) continue ;;
        esac
        merged=${title#"$ISSUE_PREFIX"}
        merged=${merged%"$ISSUE_SUFFIX"}
        [[ $merged =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || continue
        git fetch --quiet --no-tags "$UPSTREAM_URL" "refs/tags/$merged:refs/tags/$merged" 2> /dev/null || continue
        if git merge-base --is-ancestor "$merged^{commit}" HEAD 2> /dev/null; then
            gh issue close "$number" --comment "\`$BASE_BRANCH\` contains $merged now."
            note "Closed #$number: $BASE_BRANCH contains $merged."
        fi
    done
}

publish() {
    local outcome tag branch head have body url id refusal guarded
    close_merged_issues
    outcome=$(cat "$out/outcome")
    case "$outcome" in
        none | skip) return 0 ;;
        clean | person) ;;
        *) fail "The merge job left an outcome this script does not know: $outcome" ;;
    esac
    # Read as data: these files come from the job that ran upstream's build.
    tag=$(cat "$out/tag")
    [[ $tag =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || fail "The merge job left a tag that is not a release tag."
    branch="cs/sync-$tag"
    body="$out/body.md"

    if [ "$outcome" = person ]; then
        {
            printf 'Upstream release `%s` did not merge cleanly into `%s`. `scripts/sync-upstream.py` reported:\n\n' "$tag" "$BASE_BRANCH"
            printf '```text\n%s\n```\n\n' "$(cat "$out/report")"
            printf 'To merge it by hand, in a checkout at the head of `%s` (CONTRIBUTING.md, "Merging upstream releases"):\n\n' "$BASE_BRANCH"
            printf '```bash\nscripts/sync-upstream.py start --to %s\n```\n\n' "$tag"
            printf 'Resolve what it lists, run `continue` in the sync worktree, push the result as `%s` and open a pull request. ' "$branch"
            printf 'The workflow leaves this release alone while this issue is open or that branch or pull request exists, and later releases wait behind it. '
            printf 'It closes this issue once `%s` contains %s.\n' "$BASE_BRANCH" "$tag"
        } > "$body"
        url=$(gh issue create --title "$ISSUE_PREFIX$tag$ISSUE_SUFFIX" --body-file "$body")
        note "$tag needs a person: ${url##*$'\n'}"
        return 0
    fi

    head=$(cat "$out/head")
    [[ $head =~ ^[0-9a-f]{40}$ ]] || fail "The merge job left a commit id that is not one."
    git fetch --quiet --no-tags "$out/sync.bundle" "refs/heads/sync/$tag"
    [ "$(git rev-parse FETCH_HEAD)" = "$head" ] || fail "The bundle does not hold the commit the merge job named."
    # A sync is this branch's head merged with the release, nothing else.
    git merge-base --is-ancestor "$head^1" HEAD || fail "The merge is not based on $BASE_BRANCH."
    have=$(cat "$out/have")
    # Asked of the commit itself, not of the merge job: that one ran upstream's build.
    guarded=$(git diff --name-only "$head^1" "$head" -- "${GUARDED[@]}")
    {
        printf 'Upstream release `%s`, merged by `scripts/sync-upstream.py`. It left nothing for a person.\n\n' "$tag"
        case "$UPSTREAM_URL" in
            https://github.com/*)
                [[ ! $have =~ ^v[0-9][0-9A-Za-z._-]*$ ]] \
                    || printf 'What upstream changed: %s/compare/%s...%s\n\n' "${UPSTREAM_URL%.git}" "$have" "$tag"
                ;;
        esac
        printf '```text\n%s\n```\n\n' "$(cat "$out/report")"
        printf '## Verification\n\nThe workflow built the generated files and ran no tests: the checks on this pull request are the gate.\n\n'
        printf '## Merging\n\nWith a merge commit, never squashed or rebased. The release has to stay an ancestor of `%s`, or the next sync starts again from an older one.\n' "$BASE_BRANCH"
        if [ -n "$guarded" ] && [ "$AUTO_MERGE" != all ]; then
            printf '\nThis one is not set to merge itself. It changes what runs with the repository'"'"'s sync token, so read these before merging it:\n\n'
            printf '%s\n' "$guarded" | sed 's/.*/- `&`/'
        fi
    } > "$body"
    git push --quiet origin "$head:refs/heads/$branch" \
        || fail "Could not push $branch. A release that changes .github/workflows needs a token with the Workflows permission."
    # A branch with no pull request would make every later run skip this release.
    url=$(gh pr create --base "$BASE_BRANCH" --head "$branch" --title "Merge upstream $tag" --body-file "$body") || {
        git push --quiet origin ":refs/heads/$branch" || true
        fail "Could not open the pull request for $branch; the branch was removed again."
    }
    url=${url##*$'\n'}
    note "$tag merged cleanly: $url"
    if [ "$AUTO_MERGE" = false ]; then
        note "Auto-merge is off (SYNC_AUTO_MERGE=false): merge it with a merge commit once its checks pass."
        return 0
    fi
    if [ -n "$guarded" ] && [ "$AUTO_MERGE" != all ]; then
        note "It waits for a person: it changes $(printf '%s' "$guarded" | tr '\n' ' '). Read that, then merge it with a merge commit."
        return 0
    fi
    # Asked of the API, not of gh pr merge --auto: that merges at once a pull
    # request nothing blocks, and with no required checks on the branch that
    # means before a single test has run. The API refuses instead.
    id=$(gh pr view "$url" --json id --jq .id)
    # shellcheck disable=SC2016  # GraphQL variables, not the shell's
    if refusal=$(gh api graphql -f pr="$id" -f head="$head" -f query='
        mutation($pr: ID!, $head: GitObjectID!) {
          enablePullRequestAutoMerge(input: {pullRequestId: $pr, mergeMethod: MERGE, expectedHeadOid: $head}) {
            clientMutationId
          }
        }' 2>&1 > /dev/null); then
        note "It merges itself, with a merge commit, once its required checks pass."
    else
        printf '::warning::Auto-merge could not be turned on for %s: %s\n' "$url" "$refusal"
        note "Auto-merge could not be turned on, so it waits for a person. GitHub said: $refusal"
        gh pr comment "$url" --body "Auto-merge could not be turned on for this pull request (\`$refusal\`). It needs the repository's \"Allow auto-merge\" setting and a rule on \`$BASE_BRANCH\` that requires the checks. Until then, merge it by hand once the checks pass: \`gh pr merge --merge --match-head-commit $head\`." > /dev/null || true
    fi
}

case "$#:${1:-}" in
    2:merge | 2:publish) ;;
    *)
        echo "usage: sync-upstream-ci.sh merge|publish <results directory>" >&2
        exit 2
        ;;
esac
mkdir -p "$2"
out="$(cd -- "$2" && pwd)"
"$1"
