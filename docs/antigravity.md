# Antigravity CLI sessions

cs can launch a named session with Google's Antigravity CLI (`agy`) while
keeping the session's files, notes, and workspace under the same `.cs/`
directory that Claude Code and Codex use. This first version is
launch-level: cs starts and reopens `agy` in the session with the session's
context handed over. cs's hooks, skills, status line, `cs -switch`, mail, and
rotation do not reach Antigravity yet.

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
credentials or read its state under `~/.gemini/`.

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

## Reopening

`agy --continue` reopens the most recent conversation in the folder `agy` runs
in. `agy` names a conversation's ID only on the terminal as it exits, so cs
cannot record it. cs binds the folder's latest conversation instead: after the
first launch, `.cs/local/antigravity-conversation` holds the word `latest`, and
`cs -engine` shows `conversation: latest`.

| Open | What `agy` gets |
| --- | --- |
| `cs <name>` on a terminal, after a first launch | asks `Continue previous Antigravity conversation? [Y/n]`; `y` or Enter adds `--continue`, `n` starts a new conversation |
| `cs <name>` unattended (no terminal) | `--continue` |
| `cs <name> --resume` | `--continue`; refused if no Antigravity launch has happened yet |
| `cs <name> --fresh` | a new conversation |

This is not an exact resume, and the engine does not claim `exact_resume`:

- `--continue` reopens whichever conversation `agy` used last in that folder,
  including one started there outside cs or picked with `/resume`.
- According to `agy`'s release notes, `--continue` falls back to a conversation
  in a parent or child folder when the session folder has none. A first launch
  whose `agy` exits with an error (a sign-in that never finished, a crash at
  start) therefore leaves no binding, and the next open starts a new
  conversation. A first launch left with `/exit` before any turn still binds.
- For a session folder below a checkout's root (an adopted subfolder), `agy`
  still finds the rule, because it walks from the working folder up to the
  repository root. Which conversation `--continue` picks there was not checked
  against a live `agy`.
- `cs -conversations` lists no Antigravity conversations, because cs never
  learns their IDs.

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

`cs -engine` under Antigravity reports `launch`, `startup_context`, and
`memory_index`. `cs -engine supports <capability>` exits 1 for everything else.
Skills that check before relying on a capability refuse cleanly.

| Not available under Antigravity yet | What cs does instead |
| --- | --- |
| Rotation (`rotation`) | `--from-handoff` is refused before the session is opened or migrated, and the refusal names the Claude command. A pending handoff stays armed for the next Claude or Codex launch. |
| `cs -switch` | Refused both from an Antigravity run and to Antigravity as a target. Exit and reopen with `--engine` instead. |
| Spawn briefs and task queues (`spawn_brief`) | `cs -spawn --engine antigravity` opens the session only; with `--brief` or `--task` it is refused before anything is staged. |
| `-finish` (`feature_finish`) | Refused before the session opens. Run it under Claude or Codex. A retire refusal for a feature of an Antigravity base names `cs <base> --engine claude -finish`. |
| Mail delivery (`mail_delivery`) | `cs -msg` still works from the shell. Nothing surfaces mail inside `agy`. |
| Recovery copies (`recovery_autosave`) | No hook reports `agy`'s edits, so no shadow-ref snapshots are made. |
| Encrypted sessions | Refused before the vault opens: `agy` keeps conversations in `~/.gemini/antigravity`, outside the vault. |
| `--remote` | Claude only. |

A feature worktree (`cs <base>@<feature> --engine antigravity`) launches like
any other session, with its own rule and the shared exclude entry.

The design was checked against `agy` 1.4.10 on 2026-10-30: two headless turns
confirmed that an always-on rule in `.agents/rules/` reaches the model and that
`--continue` reopens the folder's conversation. The test suite uses a fake
`agy` only.

## Follow-ups

These come later as separate changes: hooks (which would give cs the
conversation ID for an exact resume, and file-change events for recovery
copies), the shipped skills, the status line, `cs -switch`, mail delivery, and
rotation.
