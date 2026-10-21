---
name: project-whole-repo-roast-pr
description: "A /roast of a whole repository (not a branch) needs a synthetic PR: an empty root commit as base and one commit with main's tree on top; GitHub opens no PR between unrelated histories, and gh pr diff returned all 171,817 lines with no cap."
metadata:
  node_type: memory
  type: project
  originSessionId: 475ec8cf-9bee-464c-b9c7-e7a0d159c7a6
  modified: 2026-10-14T14:20:41.109Z
---

On 2026-10-14 the user asked /roast to review "all the repo" on the fork's main, with nothing new on the
branch. What worked (PR #3 on Gherghi67/code-sessions):

- `git commit-tree <empty tree 4b825dc6...>` gives a root commit; `git commit-tree <main>^{tree} -p <root>`
  gives the snapshot. Neither touches the index or the worktree. Push both as `roast/empty-base-<date>`
  and `roast/whole-repo-<date>`, open the PR between them, mark it review only, never merge, delete
  both branches after. An orphan base with no shared commit cannot be PR'd at all.
- `gh pr diff` returned the full 296-file, 171,817-line diff. I had assumed a 20,000-line cap and
  wrote that into the reviewer's prompt and the PR body; measure before claiming a limit.
- In zsh, push the refspec as `"${BASE}:refs/heads/..."`: `"$BASE:refs..."` takes `:r` as a modifier
  (see [[project-bash-tool-runs-zsh]]).

Related: [[project-roast-skill-name]], [[user-github-accounts]].
