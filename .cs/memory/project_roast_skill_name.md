---
name: project-roast-skill-name
description: "/roast's and /roast-local's reviewer prompts name a grumpy-reviewer skill that does not exist; the installed skill is grumpy-review"
metadata:
  node_type: memory
  type: project
  originSessionId: b3390c80-2f26-4c85-bc49-9ee9ff1ae6d0
  modified: 2026-10-15T09:20:00.000Z
---

`~/.claude/commands/roast.md` tells the reviewer to "Invoke the grumpy-reviewer skill" (and points
Codex at `~/.claude/skills/grumpy-reviewer/SKILL.md`), but on this machine the skill is installed
as `~/.claude/skills/grumpy-review/` (agent `~/.claude/agents/grumpy-review.md`). There is no
`grumpy-reviewer` skill or command, only `~/.claude/agent-memory/grumpy-reviewer`.

**Why:** found 2026-10-02 while running `/roast` on hex/claude-sessions PR #12. A reviewer
given the template's name may not find the skill and review without its passes.

`~/.claude/commands/roast-local.md` repeats both names in its Claude and Codex prompts; on 2026-10-12
the skill was still `~/.claude/skills/grumpy-review/` and `grumpy-reviewer` still did not exist.

2026-10-15: a plain `claude` reviewer started in a cs session folder still loads that folder's
CLAUDE.local.md (the session protocol: read summary, narrative), the context /roast means to withhold. PR #7's
reviewer ran from a detached worktree of the PR head (`git worktree add --detach <scratch> <sha>`), which has no
untracked .cs/ or CLAUDE.local.md; remove it after the review. Such a fresh scratch path is untrusted, so the
reviewer sat at Claude's folder-trust prompt (over 4 min at 0.7 s CPU, no transcript dir) until the user answered it in the
tab; when launching, tell the user to accept that prompt, and check `~/.claude/projects` for its transcript dir.

**How to apply:** when building the `/roast` or `/roast-local` reviewer prompt, write `grumpy-review`, or check
`ls ~/.claude/skills/` first in case the name has changed since. The real fix is editing roast.md,
which nobody has asked for yet. See [[user-github-accounts]].
