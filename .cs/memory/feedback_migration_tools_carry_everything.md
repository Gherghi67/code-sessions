---
name: feedback-migration-tools-carry-everything
description: "Tools that move sessions between cs and code-sessions (formerly ags) must carry everything, feature worktrees included; the user rejected leaving <base>@<task> worktrees behind as a reported skip (2026-10-07)."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 2184bde8-099b-45ee-86bb-fbb099bb920a
  modified: 2026-10-07T08:56:12.511Z
---

The first `scripts/ags-to-cs.py` (now `scripts/code-sessions-to-cs.py`) skipped feature worktrees with a reason ("finish or retire it first"). The
user's answer: "I want to copy the feature worktrees". They asked for a fallback that copies "everything".

**Why:** the point of a migration path is that no in-progress work is stranded; a skip the user has to resolve
by hand (finish, retire) defeats it.

**How to apply:** when building a cs<->code-sessions migration (`scripts/cs-to-code-sessions.py` and the way back; wap was copied this way on 2026-10-09), treat
feature worktrees, transcripts, secrets and per-worktree state as in scope from the start. Leave something
behind only when it cannot be done safely (e.g. an encrypted vault needing its password), say why, and offer
the follow-up rather than deciding it is out of scope.
