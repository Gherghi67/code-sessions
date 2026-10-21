---
name: feedback-ags-features-belong-to-session-manager
description: "In the fork (code-sessions since 2026-10-09, formerly ags), Claude and Codex are engine adapters; every skill, command and session feature (rotate, sweep, wrap...) belongs to the session manager and each adapter inherits it by registering it natively, never as a per-engine copy or a Claude-only add-on; a capability refusal under Codex is a stopgap, not done."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 1ce6a096-920f-4b79-b0c5-cd5b6c5b1c5d
  modified: 2026-10-14T19:30:00.000Z
---

The user rejected "install the rotate skill for Codex" (2026-10-05): "aren't claude and codex supposed to be
adapters for ags session manager, and inherit this /rotate?", then extended it to "all the Claude skills
that original cs brings". Design every fork feature as shared session-manager code plus a thin adapter
registration (the engine's own skills/hooks location), with a capability the adapter declares
(`cs_engine_supports`) so an engine that cannot host a feature refuses cleanly instead of half-working.

**Why:** separate per-engine copies drift, and the adapter boundary (docs/engine-adapters.md) is the
architecture the user is building toward; rotation and hooks are still listed there as "deferred".

On 2026-10-05, shown `$rotate` refusing under Codex at its capability check, the user corrected: "we do
not want this to refuse, we want rotate to also work in ags with codex". A capability refusal is a
stopgap while the adapter lacks the feature, not an acceptable end state.

**How to apply:** when a feature works only in Claude, propose moving its logic into shared session-manager code and
having each adapter register it; do not propose Codex-specific forks, and do not present a clean refusal
under Codex as done: port the feature (rotation now works under Codex via `cs -codex-hook`; it was `ags -codex-hook` before the 2026-10-09 rename). Only
Claude-only-by-nature pieces (the cs mod's button and countdown, FileChanged auto-wake) stay declared
unsupported.

The same holds for engine UI the manager can configure. On 2026-10-14 Codex under `ccs` showed no usage, because
the profile's CODEX_HOME config.toml had no `[tui] status_line`. Offered: carry the user's own `~/.codex` `[tui]`
through carry-over.sh, or have code-sessions set its own Codex status line, as the installer does with
cs-statusline for Claude. The user chose the second ("I want this"); PR #4. Prefer a manager-owned default
over copying the user's personal engine config. Plan:
.cs/plans/2026-10-05-engine-neutral-skills.md. Related: [[session-narrative-gherghinabogdan7-gmail-com]].
