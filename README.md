# code-sessions

**code-sessions** is a fork of [cs](https://github.com/hex/claude-sessions) with persistent workspaces
for [Claude Code](https://github.com/anthropics/claude-code) and
[Codex CLI](https://github.com/openai/codex), shared notes, memory, and local Git history.

Start it as `cs`, `code-sessions`, or `ccs`. Setup installs the fork with your
normal `~/.claude` and `~/.codex` configuration, after backing up the replaced
cs installation. It imports conversations from the former private profile.
Existing fork projects and secrets stay in place; `ccs` continues to use their
session store, while `cs` uses the usual `~/.claude-sessions` store.

## Install this checkout

```bash
sh ./setup.sh
```

Setup builds and installs the CLI, both engine integrations, completions, and
the optional picker when Cargo is available. It remembers your engine selection
on reruns. Requires macOS or Linux, Bash 3.2+, Git, jq, Perl, and a UTF-8 locale;
Codex also requires Python 3. Shared run ownership uses `lockf` on macOS or
`flock` on Linux. Install and authenticate your chosen native CLI separately.
Claude's Mermaid mod requires Claude Code 2.1.300+, and remote control requires
2.1.299+.

Follow [Getting started](docs/getting-started.md) for setup, adopting
projects, engine switching, and worktrees. See [Codex sessions](docs/codex.md)
for runtime compatibility and [Migration](docs/migration.md) for copying sessions
between the original cs and this fork.

The launch-time release check reports new upstream releases. To incorporate
them, have an agent follow [Syncing upstream](CONTRIBUTING.md#merging-upstream-releases),
resolve and test each release, then run `sh ./setup.sh` from the updated checkout.
The check itself does not update the installation. [Engine adapters](docs/engine-adapters.md)
describes the fork's shared core and native integrations.

## Usage

```bash
ccs debug-api
```

One command, from any terminal: `ccs <name>` creates the session the first time and resumes it every time after. It needs no project or git repository first.

## First run in 60 seconds

1. Run `ccs debug-api` in a terminal. cs creates a workspace and opens your selected engine.
2. Describe your task. cs records the first substantive prompt in the session's `Objective` section and keeps notes under `.cs/`.
3. Exit the native CLI. Run `ccs debug-api` again and accept the prompt to resume the recorded conversation.

When you forget a name, a bare `ccs` opens a picker of your sessions, and `ccs .` reopens the one whose root you are in.

![Session creation banner, picker with demo focused, and picker with demo marked](https://raw.githubusercontent.com/hex/claude-sessions/main/assets/first-run.svg)

![cs statusline cycling through quiet, context warning, critical context, queued tasks and unread mail, and quota reset countdowns](https://raw.githubusercontent.com/hex/claude-sessions/main/assets/statusline.svg)

The [statusline guide](docs/statusline.md) covers the capsules, colors, thresholds, font setup, and agent rows.

## Features

| Feature | What it does | Details |
|---|---|---|
| Session records | Keeps objectives, per-actor narratives, memory, plans, checkpoints, and a timeline in `.cs/`. | [Session layout](docs/session-layout.md) |
| Crash recovery | Saves edits to shadow git refs without adding normal branch commits. | [Autosave hook](docs/hooks.md#autosave-commitssh-posttooluse-on-writeedit) |
| Conversation rotation | Hands work to a fresh conversation through `/rotate` and `/clear`. | [Rotation and queue hooks](docs/hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) |
| Existing projects | `cs -adopt <name>` registers your project without moving it. | [Adoption](docs/commands.md#adopt-an-existing-project) |
| Parallel worktrees | `cs <base>@<feature>` gives each feature its own checkout and session records. | [Worktrees](docs/commands.md#parallel-worktrees) |
| Remote control | `cs <name> --remote` serves a session for the Claude app or web. | [Remote control](docs/commands.md#remote-control) |
| Task queue | Runs confirmed tasks at turn boundaries, with failure, context, and quota breakers. | [Queue behavior](docs/hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) |
| Cross-session mail | Delivers local messages and wakes idle sessions for unread arrivals. | [Mail wakes](docs/hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) |
| Secrets | Uses the macOS keychain or encrypted files, with signed age exports for sync. | [Secrets guide](docs/secrets.md) |
| Encrypted sessions | Keeps notes, transcripts, plans, and private state in a vault on macOS. | [Encrypted sessions](docs/session-layout.md#encrypted-sessions) |
| Statusline | Shows session, git, model, context, queue, mail, and rate limits. | [Statusline guide](docs/statusline.md) |
| Prompt grounding | Adds matching files, recent commits, changes, and clarification guidance to code-work prompts. | [Scope hook](docs/hooks.md#scope-promptsh-userpromptsubmit) |
| Prompt rewriting | Ctrl+G rewrites a draft in the composer for you to review before sending. | [Prompt rewriter](docs/hooks.md#prompt-rewritersh-not-a-hook--an-editor-shim) |
| Writing skills | Judges prose or drafts from a writing profile. | [Skills](docs/hooks.md#skills) |
| Session wrap | `/wrap` saves memory, summarizes the narrative, and archives completed tasks without committing. | [Memory checks](docs/hooks.md#memory-index-guardsh-not-a-hook--run-by-wraps-memory-pass) |
| Inline Mermaid | Draws supported flowcharts in replies, and a `show-me` skill answers "show me" with one. Requires Claude Code 2.1.300+. | [Mermaid mod](docs/hooks.md#cs-mermaid-not-a-hook-script--a-claude-code-mod)<br><img src="https://raw.githubusercontent.com/hex/claude-sessions/main/assets/mermaid.svg" width="260" alt="Reply prose, then the same prose with a drawn Mermaid chart"> |
| Release notes | Shows pending release notes in-session through `/cs-update`. | [Update mod](docs/hooks.md#cs-update-not-a-hook-script--a-claude-code-mod) |
| Other front ends | Session hooks also work in desktop and IDE conversations opened in a `.cs/` workspace. | [Session resolution](docs/hooks.md#how-a-hook-finds-its-session-cs-resolvesh) |

## Uninstall

```bash
ccs -uninstall
```

## Documentation

| Guide | Contents |
|---|---|
| [Getting started](docs/getting-started.md) | Local installation, profile setup, engines, and first sessions. |
| [Commands](docs/commands.md) | Command reference, adoption, worktrees, queues, remote control, and completion. |
| [Configuration](docs/configuration.md) | Every environment variable cs reads and the values it exports. |
| [Session layout](docs/session-layout.md) | Shared and local records, encryption, and merge policy. |
| [Hooks](docs/hooks.md) | Hook behavior, prompt rewriting, and Claude Code mods. |
| [Secrets](docs/secrets.md) | Storage backends, backups, and signed sync files. |
| [Statusline](docs/statusline.md) | Segments, colors, thresholds, and agent rows. |

## License

[MIT](LICENSE). Contributions can start with an issue or pull request.
