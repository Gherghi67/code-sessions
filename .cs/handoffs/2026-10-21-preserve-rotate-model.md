---
created: 2026-10-21
purpose: Preserve the selected Codex model and reasoning effort after rotate and clear
status: moved
moved-to: code-sessions@preserve-rotate-model
---

The user reports: "rotate does not preserve the model chosen after running clear".
Investigate the Codex launch and clear paths, reproduce the loss with a regression,
and preserve the chosen model and reasoning effort. Work on cs/preserve-rotate-model.
The clean source checkout starts at 6f265e0e. Other feature worktrees have unrelated work.
Inspect lib/76-codex.sh, lib/77-codex-hooks.sh, the Codex adapter and thread helper,
and launch option handling. Build generated files after shell fragment edits.
Run focused tests and the repository's applicable gates. Do not publish or merge.
