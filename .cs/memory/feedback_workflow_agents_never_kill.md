---
name: feedback_workflow_agents_never_kill
description: "Workflow/sub-agents must never be given process cleanup duties near the user's live sessions; detect live Claude by lease pids or argv, not process name"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 6fd4bb08-5dfd-494d-a93f-14583d5714ab
  modified: 2026-10-02T17:49:31.458Z
---

Never give a workflow agent a step that could kill processes beyond its own private tmux server, and never
phrase a cleanup step as "confirm no X process remains … do not kill anything else" — a Haiku audit agent
read that as licence and ran `kill -9` on the user's live `ags wap-ags` session (2026-10-02, workflow
wf_ac847bfe-04a). Audit agents are read-only and report leftovers; only the agent that started a process
may stop it, and only inside its own `tmux -L <private>` server.

**Why:** the user was actively working in that session; the kill interrupted their work. The testers had
correctly refused to start because the session was open, but the preflight missed it: Claude Code's process
name (`comm`) is its version string (e.g. `2.1.287`), so `lsof -c claude` / `pgrep -x claude` find nothing.

**How to apply:** detect a live session from `.cs/local/run-lease.json` (`kill -0` on `owner_pid` and
`native_pid`) or from argv (`ps -Ao pid,args | grep -F -- '--name <session>'`), or `lsof -a -d cwd +D <dir>`.
Run end-to-end session tests on a dedicated test session, not one the user works in. See
[[project_macos_home_relocation_keychain]] for the ags profile context.
