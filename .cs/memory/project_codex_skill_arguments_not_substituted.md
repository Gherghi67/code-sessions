---
name: project-codex-skill-arguments-not-substituted
description: "Codex (0.160) never substitutes $ARGUMENTS, $ARGUMENTS[N] or $N in a SKILL.md, despite its own skill-writing text listing them; a `$name` mention injects the whole SKILL.md and its path, and the model must read the arguments from the user's message."
metadata:
  node_type: memory
  type: project
  originSessionId: 004de3c1-dc50-4979-a4c0-4481d347cba1
  modified: 2026-10-05T12:22:24.047Z
---

Measured 2026-10-05 with the profile logged in (codex-cli 0.160.0): a probe skill run as
`$args-probe alpha beta` through `codex exec`, and ags's `checkpoint` picked from the TUI's `$` popup.
In both rollouts the injected user item is `<skill><name>..</name><path>/abs/SKILL.md</path>` followed by
the whole file, frontmatter included, with `$ARGUMENTS`, `$ARGUMENTS[0]`, `$0` and `$1` left literal.
The user's own message arrives as a separate item. The model coped: `$checkpoint phase2 probe label` ran
`ags -checkpoint 'phase2 probe label'`. Codex's built-in skill-creator text ("Use $ARGUMENTS,
$ARGUMENTS[N], or $N") does not describe this runtime.

**Why:** a shared skill written for Claude's substitution reads `$ARGUMENTS` as a placeholder that never
fills under Codex; it works only while the model infers what was meant.

**How to apply:** a skill that takes arguments also says, in words, to read them from the text after the
skill name in the user's message (Phase 4 wording item in .cs/plans/2026-10-05-engine-neutral-skills.md).
Judge skill output by the rollout's injected items, not by the reply. Related:
[[project-codex-ignores-disable-model-invocation]], [[feedback-ags-features-belong-to-session-manager]].
