---
name: project-moving-a-cs-session-folder
description: "Stable cs has no rename or move verb. Moving a session's folder (or renaming the session) must run after its conversation exits, never from inside it, and must not rewrite ~/.claude.json while other Claude sessions run."
metadata:
  node_type: memory
  type: project
  originSessionId: 8a98ed88-d62b-4948-86ac-cc2cbc37a382
  modified: 2026-10-13T10:00:00.000Z
---

Worked out 2026-10-09 while preparing phase 4 of the code-sessions plan (move ~/Documents/cs/agent-sessions to
~/Documents/cs/code-sessions, rename cs session ags-lifecycle to code-sessions).

- A running Claude keeps appending its transcript to `~/.claude/projects/<key of the old path>/` until it exits.
  Renaming that folder from inside the conversation splits the transcript, so the move runs after `/exit`. It
  also waits until no process has its cwd in the folder and the pid in `.cs/session.lock` is dead (stable cs
  holds it with the `bash ~/.local/bin/cs <name>` launcher, which can live for days across /clear rotations).
  Orphans count too: on 2026-10-09 the first `--apply` refused on a `tail -f | ugrep` pipeline a Monitor from a
  conversation two days earlier had left (PPID 1, cwd in the folder, ugrep's comm the Claude version string).
  Auto mode denied the agent's `kill`; the user stopped them.
- The pieces that name the path or the session: the folder; the `~/.claude-sessions/<name>` link; `session_name`
  in `.cs/local/state`; `autoMemoryDirectory` in `.claude/settings.local.json`; the `~/.claude/projects` folder (key =
  path with every non-alphanumeric character turned into `-`); `"project"` lines in `~/.claude/history.jsonl`. Keychain
  secrets `cs:<name>:*` are a seventh piece when the session has any. `~/.claude-sessions/index.md` regenerates itself
  on session end.
- `~/.claude.json` is rewritten by every running Claude process, so editing it while others run can lose the edit.
  Its per-project entry holds only the trust flag, run statistics and empty tool or MCP lists. Leaving it costs
  one trust question in the new folder.
- `history.jsonl` is append-only safe: add rekeyed copies of the lines with `O_APPEND` and never rewrite the file.
  Python's `json.dumps(..., ensure_ascii=False, separators=(",", ":"))` reproduces Claude's lines byte for byte.

**Why:** these are the ways a naive `mv` plus a new link goes wrong: a split transcript, a lost `.claude.json` write, or
prompt history and auto-memory left at the old path.

**How to apply:** for any session move or rename, reuse
`.cs/local/rename-to-code-sessions.py` in this session (dry run by default, `--apply`, rerunnable, refuses while the
session or any process is inside). Hand it to the user to run from `~` after they exit. For a session that lives
inside the code-sessions profile (no ccs rename verb either), use `.cs/local/rename-profile-session.py OLD NEW`
(2026-10-13, renamed the profile's ask to ask-ags; refuses while any ccs runs; moves history.jsonl lines in place;
its record lets a rerun finish a stopped rename). Related: [[project-wap-copied-into-code-sessions]].
