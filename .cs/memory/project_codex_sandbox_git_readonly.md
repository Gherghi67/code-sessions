---
name: project-codex-sandbox-git-readonly
description: "Codex's workspace-write sandbox keeps .git read-only even inside the workspace and always allows /tmp; a skill that writes git or outside its folder needs escalated permissions, and a trial under /tmp hides the refusal."
metadata:
  node_type: memory
  type: project
  originSessionId: 1d37927d-822c-485c-ad40-895066b1f99c
  modified: 2026-10-09T15:50:08.000Z
---

Observed 2026-10-09 (codex-cli 0.162.0-alpha.17.2) running the finish skill with `codex exec -s workspace-write`
in a base session: `cs <base> -integrate-feature` failed with `mkdir .git/cs: Operation not permitted` although
`.git` is inside the session folder. Retiring a feature also removes a worktree beside the folder, outside the
writable root. The first trial lived under /private/tmp and would have passed, because workspace-write always
allows /tmp and $TMPDIR. `codex exec` cannot ask for approval, so there the step just fails; interactive Codex
(on-request) can ask.

**Why:** a skill that works under Claude can silently stop under Codex at the first git write, and a test set up
under /tmp reports green for the wrong reason.

**How to apply:** a shared skill whose steps write `.git`, leave the session folder, or need the network (gh)
should tell Codex to run those steps with escalated permissions from the start (skills/finish/SKILL.md
"Under Codex" is the pattern). Put live Codex trials outside /tmp and $TMPDIR (e.g. ~/.cache/<name>), and delete
the trust entry Codex adds to the profile's .codex/config.toml afterwards. Related: [[project-codex-cli-test-gotchas]].
