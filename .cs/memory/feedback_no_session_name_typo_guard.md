---
name: feedback-no-session-name-typo-guard
description: "User declined (2026-10-15) a 'did you mean <session>?' guard for new session names one edit away from an existing one, after `ccs code-session` silently created a new session."
metadata:
  node_type: memory
  type: feedback
  modified: 2026-10-15T09:30:00.000Z
---

`ccs code-session --engine=claude` (missing "s") created a new session `code-session` and saved its engine there,
so `code-sessions` still opened in Codex; the user read it as an engine-persistence bug. Offered a near-name
prompt before creating; the user answered "No", and had the stray session removed (`cs -rm code-session --force`).

**Why:** the user prefers cs to keep creating a session for any new name.

**How to apply:** when a launch "forgets" a setting, check the shell history for a near-miss session name first;
do not propose the typo guard again unless the user brings it up.
