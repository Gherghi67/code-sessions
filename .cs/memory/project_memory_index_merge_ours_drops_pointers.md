---
name: project-memory-index-merge-ours-drops-pointers
description: "cs writes `.cs/memory/MEMORY.md merge=ours`, which silently deletes memory pointers on round-trip merges (base into feature, feature back into base); entry files still merge, so they end up unindexed. Not a legacy backlog; the root cause of /sweep's unindexed failures."
metadata:
  node_type: memory
  type: project
  originSessionId: 1ce6a096-920f-4b79-b0c5-cd5b6c5b1c5d
  modified: 2026-10-05T08:47:55.482Z
---

`setup_merge_attributes` (lib/45-migrate.sh, also lib/30-worktree.sh; same in stable cs 2026.10.1, and
`cs doctor` warns when `merge.ours.driver` is missing) marks MEMORY.md `merge=ours` while entry files merge
normally. Round trip measured in wap (2026-10-03, read-only git): merging `wap` (128 pointers) into a
feature branch kept the branch's stale 65 (both sides changed, ours driver); merging the feature back into
`wap` was then a plain one-sided change (wap's MEMORY.md unchanged since the merge base), so wap went
130 -> 66 pointers with no conflict (`154d6c4bd5`, 2026-09-23). The same loss had been repaired once on
2026-09-14 (`41491df158`). All 173 unindexed wap entries had a pointer in some committed MEMORY.md
(use `git log --full-history`; plain `git log -- path` hid most of the 293 commits).

**Why:** `memory-index-guard.sh check` failing on "unindexed" entries is real damage, so silencing the
check (e.g. baselining legacy entries) would hide a recurring loss.

**How to apply:** fix the attribute (e.g. `merge=union`, as narratives and timeline use; update the doctor
check), then repair lost pointers. Separately, 262 wap entries at ~200 B per pointer cannot fit the
24400 B index budget, so repair also needs much shorter pointers or consolidation; ask the user.
