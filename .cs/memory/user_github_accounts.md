---
name: user-github-accounts
description: "Actor gherghinabogdan7-gmail-com's gh accounts: Gherghi67 is personal, bogdan-gherghina is work; hex/claude-sessions work goes out as Gherghi67 via a fork; the fork's own PRs stay inside Gherghi67/code-sessions (renamed from Gherghi67/claude-sessions)"
metadata:
  node_type: memory
  type: user
  originSessionId: b3390c80-2f26-4c85-bc49-9ee9ff1ae6d0
  modified: 2026-10-13T10:00:00.000Z
---

For actor `gherghinabogdan7-gmail-com` (Bogdan Gherghina, machine /Users/bogdan.gherghina): two
GitHub accounts are logged in to `gh`. `Gherghi67` is their personal account, `bogdan-gherghina` the
work one (the active gh account as of 2026-10-02). Commits in hex/claude-sessions are authored as
`gherghinabogdan7@gmail.com`.

**Why:** they asked to land the hex/claude-sessions fix "with the personal github account" and
confirmed Gherghi67 when asked (2026-10-02).

**How to apply:** for hex/claude-sessions, push, open PRs and post comments as Gherghi67 without
switching the active account: prefix the command with
`GH_TOKEN="$(gh auth token --user Gherghi67)"` (git's github.com credential helper is
`gh auth git-credential`, which honours it). Neither account can push to hex/claude-sessions, so
work goes through the fork `Gherghi67/claude-sessions` (created 2026-10-02). A `/roast` reviewer tab
inherits the active (work) account, so its launch command needs the same prefix or its PR comment
posts as bogdan-gherghina. See [[project-roast-skill-name]].

The fork's own work (branch `code-sessions`) is reviewed through PRs *inside* its own repo, head
`code-sessions` → base `main`, never against hex (user confirmed 2026-10-09; PR #1). By 2026-10-13 that repo
is `Gherghi67/code-sessions` (renamed from Gherghi67/claude-sessions, no longer listed as a fork; PR #1
merged into its main as a merge commit, PR #2 opened that day). Pass `-R Gherghi67/code-sessions` to every
`gh pr` call, the reviewer's included, and push to its URL
(`https://github.com/Gherghi67/code-sessions.git code-sessions`): this checkout's only remote, `origin`, is hex.
