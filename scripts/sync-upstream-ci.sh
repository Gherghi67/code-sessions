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
# of a bundle, checks that it merges exactly its own checkout of the branch
# with the release as upstream has it, and hands it to git and gh.
#
# publish needs gh signed in (GH_TOKEN, GH_REPO) as someone whose pushes and
# pull requests start workflows. The token GitHub hands a workflow does not,
# and a sync pull request no check ran on would be merged untested.
#
# A release that changes what runs with the token (a workflow, or this
# script) is not pushed: a branch pushed to this repository runs its own
# workflows at once, with whatever token permissions they declare, before
# anyone has read them. It gets an issue instead, holding the one command
# that approves it. A run started with approve=<tag> and commit=<id> merges
# that release again, checks the tag still points at the commit the person
# read, and pushes it. SYNC_AUTO_MERGE=all pushes such a release unapproved.
# Once pushed, a changed workflow runs for the pull request, on a ref that is
# not main, so the token stays out of its reach as long as the secret is kept
# in an environment only main may use.
#
# One release a run, the oldest first, since each is merged onto the one
# before it. A release that already has a pull request from this
# repository's cs/sync-<tag> branch, that branch alone, or an open issue
# carrying the workflow's label is left to whoever has it (the run that
# approves it goes past its issue), and the later ones wait behind it. Held
# for longer than SYNC_STALL_DAYS since it was tagged, it fails the run by
# name; so does a sync pull request closed without merging, since a release
# cannot be skipped. Tags are fetched from upstream and never pushed: a v*
# tag pushed to the fork would start its release workflow.

UPSTREAM_REMOTE="${SYNC_UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${SYNC_UPSTREAM_URL:-https://github.com/hex/claude-sessions.git}"
BASE_BRANCH="${SYNC_BASE_BRANCH:-main}"
# true (or unset): a clean merge's pull request merges itself. false: every
# pull request waits for a person. Either way a release that changes a
# guarded path is pushed only once a person approves it. all: such a release
# is pushed without approval, and merges itself too. Upper or lower case
# alike; publish takes any other value as false (read_auto_merge). Control
# characters are dropped, so the warning that names the value stays one line.
AUTO_MERGE=$(printf '%s' "${SYNC_AUTO_MERGE:-}" | tr -d '[:cntrl:]' | tr '[:upper:]' '[:lower:]')
# What the job holding the token runs or is defined by.
GUARDED=(.github scripts/sync-upstream-ci.sh)
# Set in a run started from a release's issue: the release a person read the
# guarded change of, and the commit they read.
APPROVE_TAG="${SYNC_APPROVE_TAG:-}"
APPROVE_COMMIT="${SYNC_APPROVE_COMMIT:-}"
ISSUE_PREFIX="Sync upstream "
ISSUE_SUFFIX=" needs a person"
# The workflow's own issues carry it. Anyone can open an issue with any
# title, but only someone with triage access can label one, so an issue
# without it neither holds a release back nor starts the job with the token.
LABEL=sync-upstream
# How many days the oldest missing release may be held (by a pull request, a
# branch or an issue) after it was tagged before the run fails to say so.
STALL_DAYS="${SYNC_STALL_DAYS:-3}"
# GitHub refuses a pull request or issue body over 65,536 characters, and
# upstream decides how long the parts it writes are: the sync report, fences
# included, gets at most REPORT_CAP bytes of a body, the list of guarded
# files LIST_CAP. Bytes, since no character is shorter than one.
REPORT_CAP=20000
LIST_CAP=4000
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

# Issues are how the workflow asks for a person. With them switched off every
# issue command fails, so the run stops here, by name, before it merges anything.
require_issues() {
    local enabled
    enabled=$(gh api 'repos/{owner}/{repo}' --jq .has_issues) \
        || fail "Could not read whether the repository has Issues switched on; gh said why above."
    [ "$enabled" = true ] \
        || fail "The repository has Issues switched off, and this workflow opens an issue for each release that needs a person. Switch them on with gh repo edit --enable-issues, or in Settings, General, Features."
}

# The workflow's open issues in $issues, number<TAB>title a line: only those
# with its label. A list gh could not read fails the run: taken for no issue,
# it would merge a release a person already has, or never start the job that
# closes the workflow's own.
open_issues() {
    issues=$(gh issue list --label "$LABEL" --state open --limit 200 --json number,title --jq '.[] | "\(.number)\t\(.title)"') \
        || fail "Could not list the repository's open issues; gh said why above."
}

# The oldest missing release is held by someone. Held for longer than
# STALL_DAYS since it was tagged, the run has to fail, or a stall stays green
# and nobody sees it. The merge job only writes that down: failing there would
# start no publish job, and the workflow's merged issues would stay open. The
# publish job, started for it, does its usual work and then fails with it.
stalled() {  # tag, releases missing, what holds it
    local created behind
    created=$(git for-each-ref --format='%(creatordate:unix)' "refs/tags/$1")
    [[ $created =~ ^[0-9]+$ ]] || fail "Could not read when $1 was tagged."
    [ $(($(date +%s) - created)) -gt $((10#$STALL_DAYS * 86400)) ] || return 0
    behind=$(($2 - 1))
    case "$behind" in
        0) behind="" ;;
        1) behind=" 1 later release waits behind it." ;;
        *) behind=" $behind later releases wait behind it." ;;
    esac
    result stall "$1, tagged $(git for-each-ref --format='%(creatordate:short)' "refs/tags/$1"), has waited longer than SYNC_STALL_DAYS ($STALL_DAYS days) allows: $3$behind"
    note "That is longer than SYNC_STALL_DAYS ($STALL_DAYS days) allows, so the run fails once it has done the rest of its work."
}

# A bad input is not repeated in the message: whoever started the run typed
# it, and the runner takes a log line that starts with :: as a command.
require_approval_inputs() {
    [ -n "$APPROVE_TAG$APPROVE_COMMIT" ] || return 0
    [[ $APPROVE_TAG =~ ^v[0-9][0-9A-Za-z._-]*$ ]] \
        || fail "approve must name a release tag, as the issue that asks for the approval gives it."
    [[ $APPROVE_COMMIT =~ ^[0-9a-f]{40}$ ]] \
        || fail "commit must be the release's full commit id, 40 hex digits, as the issue that asks for the approval gives it."
}

# A person approved the commit they read. A tag that points elsewhere now
# names something nobody has read.
require_approved_commit() {  # tag, the commit it points at
    [ "$2" = "$APPROVE_COMMIT" ] \
        || fail "$1 points at $2, not at the approved $APPROVE_COMMIT: the tag moved since, or the approval names another commit. Read the change again and approve the commit $1 points at."
}

# What the merge job found, for the publish job: one value a file.
result() {  # name, value
    printf '%s\n' "$2" > "$out/$1"
}

# The oldest missing release, merged in a worktree of its own. Leaves in <dir>:
# outcome (none: up to date; skip: someone has it; clean: merged and committed;
# person: it needs one), and with clean or person the tag and the report, and
# for clean the commit and a bundle holding it. With skip, stall when it has
# been held too long.
merge() {
    require_approval_inputs
    if ! [[ $STALL_DAYS =~ ^[0-9]{1,5}$ ]]; then
        # A typo is no reason to have no alarm at all.
        printf '::warning::SYNC_STALL_DAYS is not a whole number of days, so this run takes 3.\n'
        STALL_DAYS=3
    fi
    require_issues
    merge_release
    # The publish job, and with it the token, is only started for a pull
    # request or an issue to open, for an issue of its own it may close, or
    # to fail the run over a release held too long.
    local publish=false
    case "$(cat "$out/outcome")" in
        clean | person) publish=true ;;
        *)
            open_issues
            ! printf '%s\n' "$issues" | cut -f2- | grep -x -- "$ISSUE_PREFIX"'v.*'"$ISSUE_SUFFIX" > /dev/null || publish=true
            ;;
    esac
    [ ! -e "$out/stall" ] || publish=true
    [ -z "${GITHUB_OUTPUT:-}" ] || printf 'publish=%s\n' "$publish" >> "$GITHUB_OUTPUT"
}

merge_release() {
    result outcome none
    git remote get-url "$UPSTREAM_REMOTE" > /dev/null 2>&1 || git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
    local tags tag branch waiting prs pr state url found number worktree log status
    tags=$(sync missing)
    if [ -z "$tags" ]; then
        [ -z "$APPROVE_TAG" ] || fail "This run approves $APPROVE_TAG, but $BASE_BRANCH lacks no upstream release."
        note "Up to date with upstream."
        return 0
    fi
    tag=${tags%%$'\n'*}
    branch="cs/sync-$tag"
    waiting=$(printf '%s\n' "$tags" | wc -l | tr -d ' ')
    [ "$waiting" = 1 ] || note "$waiting releases to merge; this run takes $tag, the oldest."
    if [ -n "$APPROVE_TAG" ]; then
        [ "$APPROVE_TAG" = "$tag" ] \
            || fail "This run approves $APPROVE_TAG, but the oldest release $BASE_BRANCH lacks is $tag, and releases are merged in order."
        # As upstream has it: sync missing has just fetched its tags.
        require_approved_commit "$tag" "$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}")"
    fi

    result outcome skip
    prs=$(gh pr list --head "$branch" --state all --json isCrossRepository,state,url \
        --jq '.[] | "\(.isCrossRepository)\t\(.state)\t\(.url)"') \
        || fail "Could not list the pull requests for $branch; gh said why above."
    # --head matches a branch of that name in any repository, and anyone can
    # open a pull request from a fork's. Only this repository's own count, the
    # newest first. awk reads to the end: one that stopped at the first match
    # would leave printf writing to a closed pipe, a failure under pipefail.
    pr=$(printf '%s\n' "$prs" | awk -F '\t' '$1 == "false" && !found { print $2 "\t" $3; found = 1 }')
    if [ -n "$pr" ]; then
        state=${pr%%$'\t'*}
        url=${pr#*$'\t'}
        case "$state" in
            # Squashed or rebased, the pull request is merged and the release
            # still is not an ancestor of main: every later sync would start
            # from an older one. A green run that skipped it would hide that.
            MERGED) fail "$url is merged, but $BASE_BRANCH does not contain $tag: it was not landed with a merge commit. Merge $tag again by hand (scripts/sync-upstream.py start --to $tag) and land that with a merge commit." ;;
            # Taken for someone having it, it would hold every later release
            # back for good, each run green.
            CLOSED) fail "$url was closed without merging, and $tag cannot be skipped: each sync merges onto the one before it, so every later release waits behind it. Reopen it, or merge $tag by hand (scripts/sync-upstream.py start --to $tag) and land that with a merge commit." ;;
        esac
        note "$tag already has a pull request ($url); nothing to do until it lands."
        stalled "$tag" "$waiting" "its pull request $url is still open. Find out what keeps it from merging (a failing check, or auto-merge off) and merge it."
        return 0
    fi
    found=0
    git ls-remote --exit-code --heads origin "refs/heads/$branch" > /dev/null 2>&1 || found=$?
    case "$found" in
        0)
            note "$tag: the fork already has a $branch branch and no pull request for it; left to whoever pushed it."
            stalled "$tag" "$waiting" "the fork has a $branch branch and no pull request for it. Open one, or, if a run stopped between pushing the branch and opening its pull request, delete the branch (git push origin :$branch) and the next run merges $tag again."
            return 0
            ;;
        2) ;;
        *) fail "Could not read the fork's branches (git ls-remote exited $found)." ;;
    esac
    if [ -n "$APPROVE_TAG" ]; then
        # Its issue asked for this run, and stays open until the release lands.
        note "$tag is approved for commit $APPROVE_COMMIT."
    else
        open_issues
        number=$(printf '%s\n' "$issues" | awk -F '\t' -v title="$ISSUE_PREFIX$tag$ISSUE_SUFFIX" '$2 == title && number == "" { number = $1 } END { print number }')
        if [ -n "$number" ]; then
            note "$tag waits for a person: an issue for it is open (#$number)."
            stalled "$tag" "$waiting" "issue #$number is still open. It needs a person, to merge $tag by hand or to approve it as the issue says."
            return 0
        fi
    fi

    # Beside the results, not among them: they are uploaded for the publish job.
    worktree="$out.worktree"
    log="$out/sync.log"
    result tag "$tag"
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
    # An approval is for a clean merge. This one needs a person to merge it,
    # and its issue is open already: a second one would only repeat it.
    [ -z "$APPROVE_TAG" ] || [ "$status" = 0 ] \
        || fail "$tag was approved, but it does not merge cleanly onto $BASE_BRANCH as it is now; see the report above. Merge it by hand (scripts/sync-upstream.py start --to $tag); its issue stays open until $BASE_BRANCH contains it."
}

# An issue this workflow opened for a release that has since been merged.
# Housekeeping: one gh cannot close is a warning, and the next run tries again.
close_merged_issues() {
    local number title merged
    open_issues
    printf '%s\n' "$issues" | while IFS=$'\t' read -r number title; do
        case "$title" in
            "$ISSUE_PREFIX"v*"$ISSUE_SUFFIX") ;;
            *) continue ;;
        esac
        merged=${title#"$ISSUE_PREFIX"}
        merged=${merged%"$ISSUE_SUFFIX"}
        [[ $merged =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || continue
        git fetch --quiet --no-tags "$UPSTREAM_URL" "refs/tags/$merged:refs/tags/$merged" 2> /dev/null || continue
        if git merge-base --is-ancestor "$merged^{commit}" HEAD 2> /dev/null; then
            if gh issue close "$number" --comment "\`$BASE_BRANCH\` contains $merged now."; then
                note "Closed #$number: $BASE_BRANCH contains $merged."
            else
                printf '::warning::Could not close #%s, though %s contains %s.\n' "$number" "$BASE_BRANCH" "$merged"
                note "Could not close #$number, though $BASE_BRANCH contains $merged; the next run tries again."
            fi
        fi
    done
}

# The release first, then the housekeeping: an issue that will not close
# never keeps a release from its pull request or its issue. Last, a release
# the merge job found held too long fails the run. One line of it, read as
# data: the merge job ran upstream's build, and a line of its own starting
# with :: would be a command to the runner.
publish() {
    require_approval_inputs
    read_auto_merge
    publish_release
    close_merged_issues
    [ ! -s "$out/stall" ] || fail "$(head -n 1 "$out/stall" | cut -c 1-1000)"
}

# SYNC_AUTO_MERGE is the kill switch, and one a typo leaves on is not one:
# any value but the three it knows turns auto-merge off, and says so.
read_auto_merge() {
    case "$AUTO_MERGE" in
        '') AUTO_MERGE=true ;;
        true | all | false) ;;
        *)
            printf "::warning::SYNC_AUTO_MERGE is '%s', which is not true, all or false, so auto-merge is off.\n" "$AUTO_MERGE"
            note "SYNC_AUTO_MERGE is '$AUTO_MERGE', which is not true, all or false: auto-merge is off, and every sync pull request waits for a person."
            AUTO_MERGE=false
            ;;
    esac
}

# Opens the issue that asks a person about release $1, its body in $body, and
# leaves its address in $url. The label first: gh opens no issue with a label
# the repository lacks, and --force makes the call one that also succeeds
# when the label is there (it sets its colour and description again).
open_issue() {
    gh label create "$LABEL" --force --color 5319e7 --description "Releases the Sync upstream workflow left for a person" > /dev/null \
        || fail "Could not create the $LABEL label for the workflow's issues; gh said why above."
    url=$(gh issue create --title "$ISSUE_PREFIX$1$ISSUE_SUFFIX" --label "$LABEL" --body-file "$body") \
        || fail "Could not open the issue for $1; gh said why above."
    url=${url##*$'\n'}
}

# The end of every body: what scripts/sync-upstream.py reported. Upstream
# writes part of it (the file names, and what its build.sh prints to stderr),
# so it comes after everything this script has to say, as many whole lines as
# fit in REPORT_CAP, in a fence longer than any run of backticks among them.
# A fence closes only on a run at least as long as its own, so no line of the
# report can end the block and start markup of its own, an HTML comment that
# hides the rest of the body, say. The report is shown as it is rather than
# with its backticks replaced: a person looks for those files by name.
report_section() {
    local fit kept longest total fence run
    # The lines that fit, the fence they need counted in, and their longest run of backticks.
    fit=$(LC_ALL=C awk -v cap="$REPORT_CAP" '
        {
            run = longest
            s = $0
            while (match(s, /`+/)) {
                if (RLENGTH > run) run = RLENGTH
                s = substr(s, RSTART + RLENGTH)
            }
            fence = run < 3 ? 3 : run + 1
            if (n + length($0) + 1 + 2 * fence + 6 > cap) exit
            n += length($0) + 1
            longest = run
            kept = NR
        }
        END { print kept + 0, longest + 0 }' "$out/report")
    kept=${fit% *}
    longest=${fit#* }
    total=$(LC_ALL=C awk 'END { print NR }' "$out/report")
    fence=$(printf '%*s' "$((longest < 3 ? 3 : longest + 1))" '' | tr ' ' '`')
    printf '`scripts/sync-upstream.py` reported:\n\n%stext\n' "$fence"
    LC_ALL=C awk -v kept="$kept" 'NR > kept { exit } { print }' "$out/report"
    printf '%s\n' "$fence"
    [ "$kept" -lt "$total" ] || return 0
    run="the merge job's log"
    if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
        run="$run in $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    fi
    printf '\nThe report is cut here, after %s of its %s lines, to keep this within GitHub'"'"'s limit on a body. All of it is in %s.\n' "$kept" "$total" "$run"
}

# The guarded files the merge changes ($guarded), an item each, as many as
# fit in LIST_CAP, then how many more: upstream names them. git quotes a name
# with a newline in it, so each is one item and cannot end the list.
guarded_list() {
    printf '%s\n' "$guarded" | LC_ALL=C awk -v cap="$LIST_CAP" '
        { n += length($0) + 5 }
        n <= cap { print "- `" $0 "`"; next }
        { more++ }
        END { if (more) print "- and " more " more" }'
}

publish_release() {
    local outcome tag branch head base parents count release have body url id refusal guarded
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
            printf 'Upstream release `%s` did not merge cleanly into `%s`; its report is below.\n\n' "$tag" "$BASE_BRANCH"
            printf 'To merge it by hand, in a checkout at the head of `%s` (CONTRIBUTING.md, "Merging upstream releases"):\n\n' "$BASE_BRANCH"
            printf '```bash\nscripts/sync-upstream.py start --to %s\n```\n\n' "$tag"
            printf 'Resolve what it lists, run `continue` in the sync worktree, push the result as `%s` and open a pull request. ' "$branch"
            printf 'The workflow leaves this release alone while this issue is open and labelled `%s`, or that branch or pull request exists, and later releases wait behind it. ' "$LABEL"
            printf 'It closes this issue once `%s` contains %s.\n\n' "$BASE_BRANCH" "$tag"
            report_section
        } > "$body"
        open_issue "$tag"
        note "$tag needs a person: $url"
        return 0
    fi

    head=$(cat "$out/head")
    [[ $head =~ ^[0-9a-f]{40}$ ]] || fail "The merge job left a commit id that is not one."
    git fetch --quiet --no-tags "$out/sync.bundle" "refs/heads/sync/$tag"
    [ "$(git rev-parse FETCH_HEAD)" = "$head" ] || fail "The bundle does not hold the commit the merge job named."
    # A sync is this checkout of the branch merged with the release, nothing
    # else. Every upstream commit the fork ever merged is an ancestor of the
    # branch, so a first parent that only had to be one of them would let the
    # merge job, which ran upstream's build, pick what the guarded paths are
    # compared with; GitHub merges the pull request onto the branch's head.
    base=$(git rev-parse HEAD)
    parents=$(git log -1 --format=%P "$head")
    count=$(printf '%s\n' "$parents" | wc -w | tr -d ' ')
    [ "$count" = 2 ] || fail "The merge job's commit has $count parents. A sync is a merge of two: $BASE_BRANCH and the release."
    [ "${parents% *}" = "$base" ] \
        || fail "The merge is not based on $BASE_BRANCH as this job checked it out ($base). If $BASE_BRANCH moved since the merge job ran, the next run merges again."
    # The release as upstream has it, fetched here: into a local tag, never pushed.
    git fetch --quiet --no-tags "$UPSTREAM_URL" "refs/tags/$tag:refs/tags/$tag" \
        || fail "Could not fetch $tag from upstream to check the merge against it."
    release=$(git rev-parse "refs/tags/$tag^{commit}")
    [ "${parents#* }" = "$release" ] || fail "The merge's second parent is not $tag as upstream has it ($release)."
    # Where upstream was when the fork last merged it: what the release adds is after it.
    have=$(git merge-base "$base" "$release") || fail "$BASE_BRANCH and $tag share no history."
    # Read from the commit against this checkout, never from the merge job:
    # that one ran upstream's build.
    guarded=$(git diff --name-only "$base" "$head" -- "${GUARDED[@]}")
    if [ -n "$APPROVE_TAG" ]; then
        [ "$APPROVE_TAG" = "$tag" ] || fail "This run approves $APPROVE_TAG, but the merge job merged $tag."
        # The tag as this job fetched it, which the merge's second parent is.
        require_approved_commit "$tag" "$release"
    elif [ -n "$guarded" ] && [ "$AUTO_MERGE" != all ]; then
        # Not pushed: a branch pushed here runs its own workflows at once,
        # with the token permissions they declare, before anyone reads them.
        {
            printf 'Upstream release `%s` merges cleanly into `%s`, but it changes what the job holding the sync token runs or is defined by:\n\n' "$tag" "$BASE_BRANCH"
            guarded_list
            printf '\nSo the workflow did not push it. A branch pushed to this repository runs its own workflows at once, with whatever token permissions they declare, before anyone has read them.\n\n'
            case "$UPSTREAM_URL" in
                https://github.com/*) printf 'Everything the release changes: %s/compare/%s...%s\n\n' "${UPSTREAM_URL%.git}" "$have" "$tag" ;;
            esac
            printf 'The guarded part alone, in a checkout of `%s` with upstream'"'"'s tags fetched:\n\n' "$BASE_BRANCH"
            printf '```bash\ngit diff %s %s -- %s\n```\n\n' "$have" "$tag" "${GUARDED[*]}"
            printf 'Then approve exactly this release, commit `%s`:\n\n' "$release"
            # Named, where the job knows it: in a checkout whose origin is
            # upstream, gh would otherwise start upstream's workflow.
            printf '```bash\ngh workflow run sync-upstream.yml -f approve=%s -f commit=%s%s\n```\n\n' "$tag" "$release" "${GH_REPO:+ --repo $GH_REPO}"
            printf 'That run merges it again, checks that `%s` still points at that commit, pushes `%s` and opens its pull request, which merges itself or waits as `SYNC_AUTO_MERGE` says. ' "$tag" "$branch"
            printf 'Until then the workflow leaves this release alone, and later releases wait behind it. It closes this issue once `%s` contains %s.\n\n' "$BASE_BRANCH" "$tag"
            report_section
        } > "$body"
        open_issue "$tag"
        note "$tag changes $(printf '%s' "$guarded" | tr '\n' ' '), so it is not pushed until a person approves it: $url"
        return 0
    fi
    {
        printf 'Upstream release `%s`, merged by `scripts/sync-upstream.py`. It left nothing for a person.\n\n' "$tag"
        case "$UPSTREAM_URL" in
            https://github.com/*) printf 'What upstream changed: %s/compare/%s...%s\n\n' "${UPSTREAM_URL%.git}" "$have" "$tag" ;;
        esac
        printf '## Verification\n\nThe workflow built the generated files and ran no tests: the checks on this pull request are the gate.\n\n'
        printf '## Merging\n\nWith a merge commit, never squashed or rebased. The release has to stay an ancestor of `%s`, or the next sync starts again from an older one.\n' "$BASE_BRANCH"
        if [ -n "$guarded" ]; then
            if [ -n "$APPROVE_TAG" ]; then
                printf '\nIt changes what the job holding the sync token runs or is defined by, and was approved by workflow dispatch for commit `%s` once a person had read that:\n\n' "$release"
            else
                printf '\nIt changes what the job holding the sync token runs or is defined by, and was pushed without approval: `SYNC_AUTO_MERGE` is `all`.\n\n'
            fi
            guarded_list
        fi
        printf '\n## Report\n\n'
        report_section
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
        note "Auto-merge is off (SYNC_AUTO_MERGE is not true or all): merge it with a merge commit once its checks pass."
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
