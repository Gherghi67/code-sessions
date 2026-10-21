---
name: feedback-fork-divergence-via-sync-script
description: "The fork (code-sessions, formerly ags) keeps its file split as a fork of hex/claude-sessions and absorbs upstream releases with scripts/sync-upstream.py; the user declined sending behaviour-neutral refactor PRs (file split, $CS_PROG, meta-dir accessor) upstream to shrink the divergence."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 47477832-c0a9-4412-84cc-7c5790fc195d
  modified: 2026-10-05T19:05:42.141Z
---

On 2026-10-05, offered two ways to stop upstream merges conflicting with the rebrand (upstream the
fork's file split and rename helpers as behaviour-neutral PRs to hex/claude-sessions, and/or a local
sync script), the user chose: "it's enough only the sync script, we do not make PR into hex's
claude-sessions". The script now exists (scripts/sync-upstream.py, CONTRIBUTING "Merging upstream
releases") and merged v2026.10.3 as e7e7abf.

**Why:** the user does not want the fork's structure pushed onto upstream's maintainer; ordinary bug
fixes still go upstream through the Gherghi67 fork (PR #12 did), which this choice does not cover.

**How to apply:** when upstream divergence comes up again, improve the sync script (its rename rules,
path map, unit moves) rather than proposing refactor PRs to hex. Since 2026-10-09 the fork keeps cs's names (no rebrand), so rename() only maps CLAUDE_SESSION_* to the CS_ fallback chain. Sync one release at a time and fix
whatever the next real run exposes, as on 2026-10-05. Related:
[[project-upstream-sync-test-adaptations]], [[user-github-accounts]].
