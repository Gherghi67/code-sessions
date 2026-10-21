---
name: project-auto-mode-refusals-here
description: "Actions the Claude Code safety checks refused in this session, and what went through instead: terminal-typing code (TIOCSTI) until the user explicitly chose that design; `bash -c install.sh` into a scratch HOME (rm check); gh pr merge twice (a request like \"complete the PR\" is not enough; the user's explicit retry is); the copy script's --all dry run."
metadata:
  node_type: memory
  type: project
  modified: 2026-10-19T07:59:11.073Z
  originSessionId: ffcb29b8-ff69-4fd2-9cfd-82c035b7610d
---

- 2026-10-15: writing a watcher that types /clear into the Codex terminal (TIOCSTI) was refused as "Tmux Self
  Drive". Not worked around; asked the user, who picked that design explicitly, and the same code then went in
  through the Edit tool. Testing TIOCSTI in a scratch pty was never refused.
- 2026-10-15: `e2e-env.sh <scratch> /bin/bash -c "... install.sh"` was refused by the built-in rm safety check
  (it cannot read the rm calls inside install.sh); two earlier identical runs had gone through. For a scratch
  reinstall after a lib change, `cp bin/cs <scratch>/home/.local/bin/cs` was enough (install copies it as is).
- Earlier, recorded in the session summary: `gh pr merge` once (went through on the user's "try again"), and the
  copy script's `--all` dry run (2026-10-14).
- 2026-10-19: `gh pr merge 7 --merge --match-head-commit ...` after the user said "complete the PR" was refused as
  "Merge Without Review" although CI was green and the review answered. Reported it and stopped; the user's
  "try again" let the identical command through. Second time the same pattern held.

**Why:** each refusal stopped work mid-step; knowing them lets a plan route around them up front.

**How to apply:** before building something that drives a terminal or another agent's input, ask the user first
and say what it will type. Before `gh pr merge`, expect the refusal unless the user said to merge in so many words:
check CI and mergeability, then report the refusal with the exact command and wait. For scratch installs, copy the built files instead of running install.sh through
`bash -c`. Never retry a refused action in another form; ask.
