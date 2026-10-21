---
name: project-codex-ignores-disable-model-invocation
description: "Codex (0.160) accepts but ignores SKILL.md's disable-model-invocation, so a user-only skill such as finish stays model-invocable there unless it also ships agents/openai.yaml with policy.allow_implicit_invocation: false."
metadata:
  node_type: memory
  type: project
  originSessionId: 253ee472-541b-4427-945c-adc332a35890
  modified: 2026-10-05T12:21:59.000Z
---

Measured 2026-10-05 (codex-cli 0.160.0, sandbox CODEX_HOME, app-server `skills/list` plus the rollout's
model-visible skill list): a skill with `disable-model-invocation: true` still appears to the model. Codex
also accepts and ignores `model`, `argument-hint`, `allowed-tools` and `user-invocable`. Its own switch is
`agents/openai.yaml` beside SKILL.md with `policy.allow_implicit_invocation: false`. Verified 2026-10-05
with a control run: with the yaml, finish is missing from the skill list a turn's rollout gives the
model; without it, finish is listed. `$finish` typed by the user still loads it.

**Why:** the fork's finish skill relies on `disable-model-invocation` so that only the user can start a landing
(merge, gate, fast-forward, worktree removal). Deployed to Codex unchanged, the model could start it on its
own.

**How to apply:** every fork skill marked `disable-model-invocation` ships `agents/openai.yaml` listed in
CS_SKILL_FILES; tests/test_commands.sh `test_explicit_only_skills_ship_a_codex_policy` enforces it (since
Phase 2, 2026-10-05). Re-check after a Codex upgrade. Related: [[project-codex-hooks-skip-until-trusted]].
