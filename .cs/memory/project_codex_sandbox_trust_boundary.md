---
name: project-codex-sandbox-trust-boundary
description: "The whole Codex -C workspace (the session dir, .cs/local, .claude/settings*.json; not .git or .codex) plus /tmp and $TMPDIR is agent-writable, and CS_RUN_ID/CS_SESSION_DIR reach sandboxed commands, so state cs's trusted side acts on must live outside them (CS_CACHE_DIR); trusted Codex hooks run unsandboxed; a PermissionRequest hook exiting 2 denies."
metadata:
  node_type: memory
  type: project
  modified: 2026-10-16T09:15:12.460Z
  originSessionId: ffcb29b8-ff69-4fd2-9cfd-82c035b7610d
---

Found 2026-10-15 fixing PR #7's B1 (codex-cli 0.162.0-alpha.17.2, `codex sandbox` probes): a command under
workspace-write wrote `.cs/local/codex-autoclear` and the trusted watcher typed `/clear` + Enter, which picks the
highlighted "Yes, proceed" in an approval overlay. The sandbox could not write `.git` or a sibling folder and
could not open /dev/tty; `CS_RUN_ID` and `CS_SESSION_DIR` were in its environment, and run-lease.json is
readable. `.cs/local/pending-switch` and the session's `.claude/settings*.json` are writable too, so a switch
the agent arms (or rewrites after a check) can carry looser approval into a relaunch. The TUI says hooks run
outside the sandbox once trusted, so hooks can write `${CS_CACHE_DIR}`. A PermissionRequest hook that exits 2
reads as a denial; `{}` with exit 0 is no decision.

**Why:** cs's trusted side (launcher, watcher, settle) treated `.cs/local` as cs-private; it is the agent's.

**How to apply:** anything that makes the trusted side type keys, quit, relaunch or choose permissions must come
from a 0700 per-run dir outside the workspace, /tmp, $TMPDIR and Codex's `writable_roots` (the PR #7 pattern:
`${CS_CACHE_DIR}/codex-runs/<run id>`, validated each read), never from the session dir or the agent's env.
Every new Codex hook verb must exit 0 on every path. Related: [[project-codex-sandbox-git-readonly]].
