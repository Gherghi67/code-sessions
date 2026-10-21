---
name: project-roast-local-base-is-local-ref
description: "/roast-local takes origin/HEAD's branch name as the base and then diffs the LOCAL branch of that name; in the code-sessions checkout local main is v2026.9.23, 262 commits behind origin/main, so pass origin/main"
metadata:
  node_type: memory
  type: project
  originSessionId: ff4f73b3-2e9f-4b71-a12d-f4d6aaa582d1
  modified: 2026-10-12T18:08:51.892Z
---

Step 3 of `~/.claude/commands/roast-local.md` reads `git symbolic-ref refs/remotes/origin/HEAD` and strips
`refs/remotes/origin/`, which leaves `main`. Every later `git log <base>..HEAD`, and the reviewer's
`git diff main`, then resolve `refs/heads/main`, the local branch. In `~/Documents/cs/code-sessions` that
branch is f26dd7a5 (Release v2026.9.23), 262 commits behind origin/main (3620edbf, v2026.10.7, the base of
the fork's PR #1). A review against `main` would also review upstream's own 262 commits.

**Why:** found 2026-10-12 running `/roast-local` on the fork. It was caught by a rev-parse before the
reviewer tab opened, not by the command's own checks.

**How to apply:** in this repo, use `origin/main` as the base and name it in the reviewer prompt, saying the
local main is stale. In any repo, compare `git rev-parse main` with `git rev-parse origin/main` before
trusting a bare base name (`git rev-parse --short` with two revisions fails). Fast-forwarding the local
main is the user's call; nobody has asked for it. Related: [[project-roast-skill-name]],
[[project-fix-review-on-claude-sessions]].
