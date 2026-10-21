---
name: project-shared-index-commit-by-pathspec
description: "A Codex thread and Claude workflow agents edited this one folder at once; a bare git commit swept the thread's staged files into a review-fix commit, which the thread then pushed. Commit by pathspec."
metadata:
  node_type: memory
  type: project
  originSessionId: 3ae3e90b-2583-4baa-8cd7-7525ed444d6d
  modified: 2026-10-14T08:53:00.766Z
---

On 2026-10-13, during /fix-review on PR #2, a Codex desktop thread (cwd ~/Documents/cs, writing into this
folder) staged its Codex hook-registration work while a workflow agent ran `git add <files> && git commit`.
The commit, f1b9d248 "(review N1)", took 9 unrelated files. The Codex thread then pushed f1b9d248 to the PR
itself as its "approved combined commit", so the commit could not be split any more. Its message names only N1.

**Why:** two engines working in one folder share a single git index. `git add` plus a bare `git commit`
commits everything anyone has staged. Checking `git diff --cached --stat` is not enough, since nothing stops
the commit on a mismatch.

**How to apply:**
- Before a commit-making run here, check whether another engine is working in this folder: Codex rollouts
  under ~/.codex/sessions/<date>/ whose cwd covers it, and `lsof -d cwd`. Never kill anything
  ([[feedback-workflow-agents-never-kill]]).
- Agents commit with `git commit -F <msg> -- <files>` and then check that `git show --stat HEAD` lists
  exactly those files.
- Agents leave files they did not change alone: never restore or clean them to make `git status` look clean.
- Run gates on a commit, e.g. a `git archive` copy, when the tree may hold another session's edits.
