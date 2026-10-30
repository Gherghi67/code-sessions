# Antigravity CLI sessions

cs can launch a named session with Google's Antigravity CLI (`agy`) while
keeping the session's files, notes, and workspace under the same `.cs/`
directory that Claude Code and Codex use. cs starts `agy` in the session with
the session's context handed over, and a hook records the conversation so a
reopen resumes exactly that one and `agy`'s edits reach recovery. cs's skills,
status line, `cs -switch`, mail, and rotation do not reach Antigravity yet.

## Launching

```bash
cs investigate --engine antigravity
```

The engine is chosen as for the other two: `--engine` on the command, then the
session's saved preference, then `CS_DEFAULT_ENGINE`, otherwise Claude. An
Antigravity launch saves `antigravity` as the session's engine just before
`agy` starts, as Codex does, so cs commands run inside it see that engine and
`cs investigate` opens it under Antigravity again.

cs runs the `agy` it finds on `PATH`. Set `AGY_BIN` to an executable path when
it is installed elsewhere (`cs -spawn` carries it into the tmux window). The
memory index in the session rule is read with Python 3, which setup already
requires. When either is missing, cs stops before creating anything and names
what to install:

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

`agy` must be signed in for the current user. cs does not configure its
credentials or read its conversations under `~/.gemini/`. The one thing cs
writes there is its own hook plugin (see below).

The first interactive open of each new session folder or feature worktree
shows `agy`'s folder-trust dialog, which asks
"Do you trust the contents of this project?" and keeps the answer in
`~/.gemini/antigravity-cli/settings.json` (`trustedWorkspaces`). Whether cs's
hook waits for that answer has not been checked live (see
[Recovery copies](#recovery-copies)). If the hook does not run, nothing is
bound and the next open starts a new conversation.

## What cs hands over

Claude gets the session protocol from `CLAUDE.local.md`, and Codex gets it as
startup instructions. `agy` reads workspace rules from `.agents/rules/*.md` at
the root of the folder it runs in, and keeps a rule whose front matter says
`trigger: always_on` in every turn. At each launch cs writes the session's facts
there, in `.agents/rules/cs-session.md`: the session's name, folder and actor,
where its objective, summary, memory, and narrative live, the cs executable,
and the memory index (`.cs/memory/MEMORY.md`). This is the same engine-neutral
context Codex receives.

- The file carries cs's mark (`<!-- cs:antigravity-session-context -->`). cs
  rewrites only a file with that mark. If you have your own file at that path,
  the launch stops and asks you to move it aside.
- If `.agents`, `.agents/rules`, or the rule itself is a symbolic link, the
  launch stops. cs never writes through a link out of the session.
- In a git checkout, cs adds `/.agents/rules/cs-session.md` (anchored at the
  session folder, glob characters escaped) to the checkout's `info/exclude`, so
  the file never shows in `git status`. The entry is added once the rule is
  written, so a launch refused over a rule of yours adds none. cs leaves your
  own `.agents/` files and `.gitignore` alone. The file is built beside the
  rule under a name `agy` does not load and renamed into place from inside the
  rules folder, entered by its physical path, so a folder swapped for a link
  while the rule is written gets nothing.
- While it carries the mark, the rule counts as cs's own, like a
  `CLAUDE.local.md` with cs's sentinel. Retiring a feature takes it with the
  worktree instead of moving it to the trash. `cs -rm --force` and the picker's
  delete count a session's `.agents` as cs's when it holds nothing but this
  rule. Any other file there, or the rule without the mark, is yours and is
  listed. A retire refuses over the rule without the mark, as it does over a
  `CLAUDE.local.md` of yours, because cs's exclude is what hides it from git.

Rules have a size budget in `agy`, so a very long memory index can be cut at a
line boundary. The full index stays in `.cs/memory/MEMORY.md`.

The launch also exports the session identity (`CS_SESSION_NAME`,
`CS_SESSION_DIR`, `CS_SESSION_META_DIR`), `CS_RUN_ENGINE=antigravity` and
`CS_BIN` into `agy`, so cs commands the agent runs find the session. Claude's
conversation variables are cleared so a launch from inside Claude does not leak
them.

## The cs hook

`agy` loads every folder under `~/.gemini/config/plugins/` that holds a
`plugin.json`, and runs the hooks its `hooks.json` names; a plugin is on unless
`agy plugin disable` turned it off. The installer writes cs's own plugin,
`~/.gemini/config/plugins/cs/`, wherever `agy` is on `PATH` (or `AGY_BIN`
names it) or `~/.gemini/antigravity-cli`, `agy`'s own folder, exists, whatever
engines the install chose:

- `plugin.json` and `hooks.json`, with one named hook, `cs-session`:
  `cs -antigravity-hook pre-invocation` before each model call, and
  `cs -antigravity-hook post-tool-use` after each tool (matcher `*`).
- `scripts/`, holding the recovery consumer (`autosave-commits.sh` and the
  three files it sources), as Codex gets under `$CODEX_HOME/hooks/cs/`.

The folder is cs's whole. An install rewrites both files; it never merges into
them. A folder of that name is cs's when its `hooks.json` is cs's, or, with no
`hooks.json`, when it holds only what an install or removal of cs leaves
there: cs's own `plugin.json`, a `scripts/` folder, and the
`.hooks.json.XXXXXX` and `.plugin.json.XXXXXX` temporary files of an install
cut short. Any other folder of that name (a `hooks.json` or `plugin.json` that
is not cs's, or anything else at its top level), or one where the folder,
`hooks.json` or `scripts/` is a symbolic link, is kept as it is with a
warning, and nothing is registered. `cs -uninstall` removes only the files cs
wrote: a script you changed stays, and is named, and the next install takes
the folder back. `cs -doctor` under Antigravity reports whether the hook is
installed, names a cs that is there, has its recovery consumer
(`scripts/autosave-commits.sh`), and is not switched off in
`~/.gemini/config/config.json` (`agy plugin enable cs` turns it back on); for
a folder holding only what cs left, or a hook without its recovery consumer,
it says to run `setup.sh` again. A launch whose hook lacks the recovery
consumer says that edits are not autosaved.

A plugin was picked over a workspace `<session>/.agents/hooks.json` because it
is written once at install, outside the folder the agent writes. It needs no
git exclude, never meets a `.agents/hooks.json` of the project's, and serves
every session and feature worktree. `agy` runs it for every `agy` run on the
machine. Outside a cs launch of an Antigravity session (no
`CS_RUN_ENGINE=antigravity`), the hook prints `{}` and exits. That costs about
50 ms per model call and tool call.

Every hook prints `{}`, which decides nothing, and exits 0, so it never blocks
or fails a turn. It acts only for the run that holds the session's lease.

## Reopening

The hook binds the session to the conversation its run works in:
`.cs/local/antigravity-conversation` holds that conversation's ID, and
`cs -engine` shows it. `agy` hands every hook the ID as `conversationId`. The
binding is written at the first model call of the run, so a run left before
any turn (with `/exit`, a sign-in that never finished, a crash at start)
records nothing.

| Open | What `agy` gets |
| --- | --- |
| `cs <name>` on a terminal, once a conversation is bound | asks `Continue previous Antigravity conversation? [Y/n]`; `y` or Enter adds `--conversation <id>`, `n` starts a new conversation |
| `cs <name>` unattended (no terminal) | `--conversation <id>` |
| `cs <name> --resume` | `--conversation <id>`; refused if no conversation is bound yet |
| `cs <name> --fresh` | a new conversation |

- The run's first conversation to reach the model is the session's: the one a
  reopen named, a new one, or one picked with `/resume` before the first turn.
  A conversation the run meets later (a subagent's, or one opened with
  `/resume` mid-run) has its own ID and leaves the binding alone. The hook
  keeps track of this in a private directory of the run, under
  `~/.cache/cs/antigravity-runs/`, outside the session folder.
- A fresh start keeps the old binding until the new conversation reaches the
  model. Then cs rebinds and records the rotation on the session's timeline.
- The binding lies in the session folder, which the agent can write, so cs
  checks it before every launch: anything but a UUID (or the legacy word below)
  stops the launch before `agy` starts.
- Sessions bound by an earlier cs hold the word `latest`, which names no
  conversation: that cs wrote it before `agy` started, so the folder may have
  none, and `--continue` would open a parent or child folder's. Their next open
  asks nothing and starts a new conversation, and `--resume` refuses. The hook
  replaces the word with the new conversation's ID, and from then on they
  resume by ID. To go back to an older conversation of the folder, pick it with
  `/resume` before the first turn.
- `cs -conversations` lists Antigravity conversations (`antigravity:<id>`) as
  it lists Claude's and Codex's, with the bound one marked `[current]`.
- Without the hook installed, a launch says so: nothing is bound, and every
  open starts a new conversation.

## Launch options

| cs option | `agy` flag |
| --- | --- |
| `--model MODEL` | `--model MODEL` |
| `--effort LEVEL` | `--effort LEVEL` (`agy` accepts `low`, `medium`, `high`, `xhigh`, `max`) |
| `--approve-for-me` | `--mode auto`: edits and safe commands run without asking, and irreversible actions still ask |
| `--native-approval`, or neither | no mode flag, so `agy`'s own default or saved Agent Mode applies |

As with Claude, Antigravity keeps its native approval default unless you ask
for automatic approval. In the picker (`cs -tui`, `e` on a session), the Engine
row cycles Claude, Codex, and Antigravity with Left, Right, or Space.

## Capabilities and limits

`cs -engine` under Antigravity reports `launch`, `exact_resume`,
`startup_context`, `recovery_autosave`, and `memory_index`.
`cs -engine supports <capability>` exits 1 for everything else.
Skills that check before relying on a capability refuse cleanly.

| Not available under Antigravity yet | What cs does instead |
| --- | --- |
| Rotation (`rotation`) | `--from-handoff` is refused before the session is opened or migrated, and the refusal names the Claude command. A pending handoff stays armed for the next Claude or Codex launch. |
| `cs -switch` | Refused both from an Antigravity run and to Antigravity as a target. Exit and reopen with `--engine` instead. |
| Spawn briefs and task queues (`spawn_brief`) | `cs -spawn --engine antigravity` opens the session only; with `--brief` or `--task` it is refused before anything is staged. |
| `-finish` (`feature_finish`) | Refused before the session opens. Run it under Claude or Codex. A retire refusal for a feature of an Antigravity base names `cs <base> --engine claude -finish`. |
| Mail delivery (`mail_delivery`) | `cs -msg` still works from the shell. Nothing surfaces mail inside `agy`. |
| Encrypted sessions | Refused before the vault opens: `agy` keeps conversations in `~/.gemini/antigravity-cli`, outside the vault. |
| Crash-recovery prompt | Edits are snapshotted ([Recovery copies](#recovery-copies)), but nothing offers them back; restore by hand. |
| `--remote` | Claude only. |

A feature worktree (`cs <base>@<feature> --engine antigravity`) launches like
any other session, with its own rule and the shared exclude entry.

## Recovery copies

`agy`'s PostToolUse payload carries the call it ran. `write_file` and
`edit_file` name the file in `args.Path`, and a call that succeeded has an
empty `error`. The hook turns each such edit into the shared `files_changed`
event (`_cs_antigravity_adapter_files_changed` in `lib/25-engine-events.sh`).
The recovery consumer then snapshots it to
`refs/worktree/cs/session/<conversation id>`, as it does for Claude and Codex.
An edit a shell command makes through `run_command` names no file, so it is
not snapshotted. The same is true of shell edits under the other engines.

Nothing offers these copies back under Antigravity. Claude's crash-recovery
prompt reads only the ref of the Claude conversation it starts, a clean `agy`
exit leaves the ref in place, and only a later Claude start or resume of the
session prunes conversation refs whose last snapshot is older than 14 days.
Each snapshot holds the whole working tree, so the newest ref has every edit
up to that moment, whichever conversation made it. `cs -engine` prints the
bound conversation as `conversation:`. To list the refs, newest first, then
compare and restore a file by hand:

```bash
git -C <session> for-each-ref --sort=-committerdate refs/worktree/cs/session/
git -C <session> diff HEAD refs/worktree/cs/session/<conversation id> -- <file>
git -C <session> checkout refs/worktree/cs/session/<conversation id> -- <file>
```

The design was checked against `agy` 1.4.10 on 2026-10-30: two headless turns
confirmed that an always-on rule in `.agents/rules/` reaches the model and that
`--continue` reopens the folder's conversation. The hook was checked against
`agy` 1.4.11 the same day, with a temporary plugin under
`~/.gemini/config/plugins/` and two headless turns:

- The plugin loaded with no entry in `config.json`.
- Hook commands got the run's environment and ran in the plugin's folder.
- A new conversation fired SessionStart, then PreInvocation before each model
  call. A `--conversation <id>` resume fired PreInvocation with the same ID
  and no SessionStart.
- The edits arrived as `write_file` and `edit_file` with an absolute `Path`.

The `hooks.json` shapes come from the hooks guide built into `agy` 1.4.11
(`strings` on the binary, section "Lifecycle Hooks"), not from a live run:
PreInvocation takes a flat list of handlers, PostToolUse groups them under a
`matcher`, and `timeout` is in seconds, 30 by default (cs sets 10).
`agy plugin validate --strict` accepts the file cs writes, and the test suite
runs that check whenever `agy` is on `PATH`.

Not checked live: whether cs's plugin hook runs in a folder `agy` does not
trust yet, or one whose trust the user declined (the headless runs were not
asked), and what a subagent's hooks carry. The test suite uses a fake `agy`
that fires the plugin's hooks with payloads of the measured shape.

## Follow-ups

These come later as separate changes: the shipped skills, the status line,
`cs -switch`, mail delivery, rotation, spawn briefs, `-finish`, and encrypted
sessions.
