---
name: summary
description: Generate an intelligent summary of this cs session by synthesizing its documentation (README, narratives, timeline) into .cs/summary.md, using the session's recorded evidence. Invoke when the user asks for a session summary.
model: opus
---

Generate an intelligent summary of this cs session by synthesizing all documentation files.

You are working in a cs session. Your task is to summarize the entire session by reading and synthesizing all documentation files.

## Steps

1. **Read all session documentation:**
   - .cs/README.md (objective, environment, outcome)
   - .cs/memory/narrative.<actor>.md (per-actor lab notebooks — your own in full; a teammate's only from the line the resume digest named for it, or its last few sections, never the whole file; older sections were rotated into .cs/narrative-archive/<actor>/ and are history — grep one only when the summary needs a date or a detail the live file no longer carries)
   - .cs/timeline.jsonl (structured session events: starts, ends, checkpoints)

2. **Synthesize into a cohesive summary** that tells the story of this session. The summary should:
   - Explain what you were trying to accomplish
   - Describe the environment and context
   - Highlight key discoveries and insights
   - Summarize the changes and modifications made
   - List notable files or outputs produced — bound the git log to this session with the earliest `started` event's timestamp in `.cs/timeline.jsonl` (e.g. `git log --since=<that timestamp> --stat`), so you attribute only this session's work
   - Conclude with the outcome and results

3. **Write the summary to .cs/summary.md** in the session metadata directory. If `.cs/summary.md` already exists, replace it — this pass always writes the canonical current summary. Use this structure:

```markdown
# Session Summary: [SESSION_NAME]

**Date:** [Session date]
**Duration:** [Approximate duration if determinable]

## Objective

[What was the goal of this session?]

## Environment

[What system/server/context were you working in?]

## Key Discoveries

[What did you learn? List important findings with brief explanations]

## Changes Made

[What modifications were made? Organize by category if appropriate]

## Key Files & Outputs

[List notable files created or changed during the session — derive from the session-bounded git log and your own record — with brief descriptions]

## Outcome

[What was accomplished? Were objectives met? What's the current state?]

## Notes for Future Reference

[Any important context or gotchas for future work]
```

`[SESSION_NAME]` = the session name from `.cs/README.md`'s title; fall back to the session directory name.

4. **Make the summary narrative and insightful**, not just a concatenation of files. Explain the "why" behind discoveries and changes. Connect related pieces of information.

## Important

- Read ALL documentation files completely before writing the summary
- If files are empty or minimal, note what was not documented
- The summary should be understandable by someone who wasn't present in the session
- Match each section's length to what the session actually produced. A section with little to report gets a line, not a paragraph — the structure is a checklist of what to cover, not a quota to fill.
- If the session is still in progress, note that in the summary
