---
name: reference-branch-out-skill-location
description: "The user-level /branch-out skill lives outside every repo and outside git; Claude command at ~/.claude/commands/branch-out.md, Codex skill and helper at ~/.codex/skills/branch-out/ (helper symlinked as ~/.local/bin/branch-out, tests in scripts/test-branch-out); backups use a `.pre-<change>` suffix."
metadata:
  node_type: memory
  type: reference
  originSessionId: 1ce6a096-920f-4b79-b0c5-cd5b6c5b1c5d
  modified: 2026-10-14T14:21:01.329Z
---

- Claude: `~/.claude/commands/branch-out.md`.
- Codex: `~/.codex/skills/branch-out/SKILL.md`; helper `scripts/branch-out` (symlinked to
  `~/.local/bin/branch-out`); tests `scripts/test-branch-out` (needs no `ws`; the ws block skips when `ws`
  is absent). Registry: `~/.agent-worktrees/registry/<repo>/<session>@<slug>.json`.
- Not under version control: the directory keeps pre-change copies as `*.pre-common-worktree`,
  `*.pre-auto-commit`, `*.pre-any-session`, ..., `*.pre-cs-prefix`; take one before editing.
- Since 2026-10-02 it works in any cs session via `branch-out context --json` (base session, source
  checkout, `.cs` mode, default base ref; wap still defaults to `github/wap` and its GIT_WORKFLOW.md).
- Branch names (user's choice, 2026-10-14): `cs/<slug>`, matching `cs <session>@<slug>`, unless the repo
  has a GIT_WORKFLOW.md in the checkout, the main checkout or on the default base ref; then
  `<session>-<slug>` (wap: `wap-<slug>`). Before 2026-10-14 every branch-out branch was `<session>-<slug>`.
  cs `/finish` cannot land or retire a feature whose branch is not `cs/<task>` (finish.sh and
  retire_feature_worktree require it), so that still holds for wap and for every older feature.
- `test-branch-out` cannot run in two copies at once: cs's process scan sees the other run's session
  and fails with "already running elsewhere". Run mutation copies one at a time (~1.5 min each).
- Renaming a branch-out branch to `cs/<task>` gets past finish.sh's branch check, but `prepare` looks the PR up
  by the current head name (`gh pr list --head`), so a PR opened from the old name reads as `pr_state: none`.
  Run `gh pr list --head <old-name> --state all` first (2026-10-05: PR #12 from fix/adopt-first-launch was
  already MERGED into main and the renamed branch hid it).
- One copy serves Claude, Codex and code-sessions: the code-sessions profile's
  `.claude/commands/branch-out.md` and `.codex/skills/branch-out` are symlinks to the files above
  (`~/.local/share/agent-sessions/recovery-*` holds an inactive old copy). Edit the originals only.
- `prepare` must leave `claude_session_id` unset for every manager. The worktree exists before the
  first `cs <session>@<slug>`, so cs treats it as a reopen: a pre-seeded id with no transcript made
  it ask "Continue previous conversation?" for a conversation that never existed (fixed 2026-10-09;
  `test-branch-out` fails if an id is written or the real-cs first open asks). A phantom resume
  prompt on a branch-out feature is a branch-out bug, not a cs one.
