---
name: project-codex-cli-test-gotchas
description: "Codex CLI probes and hook failures: exec stdin, sandbox profiles, offline turns, persisted turn evidence, and PostToolUse errors that hide completed commands. A running session can retain a removed hook until restart."
metadata:
  node_type: memory
  type: project
  originSessionId: 004de3c1-dc50-4979-a4c0-4481d347cba1
  modified: 2026-10-14T21:10:00Z
---

Observed 2026-10-05 (codex-cli 0.160.0):
- `codex exec '<prompt>'` run from a tool whose stdin stays open prints "Reading additional input from
  stdin..." and waits forever; one run hung 10 minutes. Always `< /dev/null`.
- `codex sandbox -C <dir> -- <cmd>` refuses without `--permission-profile`; the built-in names are
  `:read-only` and `:workspace`. `:workspace` allows the temp dirs, `:read-only` denies all writes.
- With no `codex login`, an app-server `thread/start` + `turn/start` still fires SessionStart hooks
  (before the model call) and writes `$CODEX_HOME/sessions/.../rollout-*.jsonl`, whose user items
  include the injected skill list. Hook execution, hook trust (`hooks/list`) and skill visibility
  can all be verified in a scratch CODEX_HOME without credentials.
- Hook commands run through a shell (a single-quoted path with spaces works) and unsandboxed, with the
  launching process's environment; Codex hooks cannot start a turn.

Added 2026-10-14 (codex-cli 0.162.0-alpha.17.2):
- A real turn with no model: a scratch CODEX_HOME whose config.toml sets `model_provider` to one with
  `base_url = "http://127.0.0.1:9/v1"`, `requires_openai_auth = false` and zero retries, then
  `codex exec --skip-git-repo-check resume <thread> "hi" </dev/null`. It loops on "Reconnecting...
  waiting for network", so bound it with `perl -e 'alarm 90; exec @ARGV' codex ...` (macOS has no
  `timeout`).
- App-server `thread/turns/list` (`limit: 1`, `sortDirection: "desc"`, `itemsView: "notLoaded"`) reads
  the persisted turns without loading the thread, in about 0.1 s. A thread made by thread/start plus
  inject_items lists none, although its rollout already holds a `turn_context` and a user-role
  environment message (only `event_msg` `task_started` marks a turn). A turn whose CLI was killed is
  listed with status `interrupted`. The SessionStart log is no such record: a group matcher or an
  untrusted hook keeps a start out of it (PR #2 fix fced974d, `cs-codex-thread --latest-turn`).

Added 2026-10-15 (local date), from the code-sessions profile:
- A failing `PostToolUse` command can hide the result of a tool that completed. The profile registered
  `cs -codex-hook files-changed`, while its deployed dispatcher accepted only `session-start`.
  The caller received `Usage: cs -codex-hook session-start` after shell commands and file reads.
  That usage text names the supported event, not the failing event.
- The repair tool also returned the hook error. After restart, comparison with its timestamped
  backup proved that it had removed the obsolete final group and preserved the other hooks.
  A tool error alone therefore did not establish that the command made no changes.
- The running session kept failing after the entry disappeared from `hooks.json`. Exiting and
  reopening Codex restored tool access; `/clear` had not refreshed this hook configuration.

Added 2026-10-15 (driving the Codex 0.162 TUI in a pty, for the automatic /clear):
- A real turn without a model: a scratch `model_providers` entry pointing at a tiny local server that answers
  POST .../responses with three SSE events (response.created, response.output_item.done with an assistant
  message, response.completed with usage). Turns complete and Stop/UserPromptSubmit hooks fire.
- Keys must arrive at typing speed: a burst is read as a paste, so "/clear" sent at once stays unsent and a
  19-key line at 50 ms a key gets its Enter turned into a newline (8 keys at that pace submit). Keys sent while
  Codex is still starting (a cs launch bootstraps about 10 s first) are replayed as a burst too.
- Codex dies at once on SIGTERM, SIGHUP and SIGINT and restores nothing (raw mode, kitty keyboard flags, cursor).
- A Stop hook's {"systemMessage": ...} shows in the TUI; hook input carries session_id and turn_id.

**Why:** each of these cost time or produced a false conclusion when first hit.

**How to apply:** use these when testing the fork's Codex adapter (Phase 3+ of
.cs/plans/2026-10-05-engine-neutral-skills.md); prefer the offline app-server route before asking the user
for a login. Related: [[project-codex-hooks-skip-until-trusted]], [[project-bash32-heredoc-fails-in-codex-sandbox]].
