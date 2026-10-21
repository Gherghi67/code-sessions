---
name: project-codex-refused-on-encrypted-sessions
description: "User decided 2026-10-12 (PR #1 review B2): the fork refuses every Codex launch on an encrypted session as a stopgap; a vault-backed per-session CODEX_HOME is the follow-up feature, not yet built."
metadata:
  node_type: memory
  type: project
  originSessionId: ff4f73b3-2e9f-4b71-a12d-f4d6aaa582d1
  modified: 2026-10-12T12:05:23.304Z
---

Codex keeps rollouts, history.jsonl and its sqlite state in CODEX_HOME (~/.codex), outside the vault.
Upstream cs protects Claude by running it on .cs/claude-config inside the vault
(`_export_session_claude_config`); the fork had no Codex equivalent, so the grumpy review on PR #1
(B2, P1) flagged that an encrypted session opened under Codex leaked outside the vault. On
2026-10-12 the user chose to refuse Codex on encrypted sessions now (guard in lib/99-main.sh before
the vault password prompt, and in `_launch_codex_bound`) rather than build the vault home in that PR.

**Why:** the vault-backed home (.cs/private/codex-home with linked skills/AGENTS.md, a seeded
config.toml, re-registered hook trust keyed on the home's own hooks.json path, handoff paths in the
vault) depends on Codex behaviour that has to be checked against the real binary: whether auth.json
refresh survives a symlink, and whether keyring auth means one codex login per session.

**How to apply:** treat the refusal as a stopgap, per [[feedback-ags-features-belong-to-session-manager]];
when Codex/encryption work comes up, the follow-up is the vault-backed CODEX_HOME. Keep
`_switch_engine_reads_vault` and the switch machinery, which the follow-up needs.
