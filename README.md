<img src="https://raw.githubusercontent.com/hex/claude-sessions/main/assets/banner.svg" width="100%" alt="cs: a session manager for Claude Code">

cs creates persistent workspaces for [Claude Code](https://github.com/anthropics/claude-code), with session notes, conversation resume, and local git history.

[![Test](https://github.com/hex/claude-sessions/actions/workflows/test.yml/badge.svg)](https://github.com/hex/claude-sessions/actions/workflows/test.yml)

## Install

Requires macOS or Linux, Bash 3.2+, git, jq, perl, Claude Code, and a UTF-8 locale.
Non-UTF-8 locales such as `ja_JP.eucJP`, `ko_KR.eucKR`, and `zh_CN.eucCN` cause syntax errors in cs and two of its hooks.

```bash
curl -fsSL https://github.com/hex/claude-sessions/releases/latest/download/install.sh | bash
```

From a checkout:

```bash
git clone https://github.com/hex/claude-sessions.git
cd claude-sessions
./install.sh
```

Review [install.sh](install.sh) before running it. The piped command always installs the release, even inside a checkout.
The installer puts the commands in `~/.local/bin/`, registers hooks, and installs skills, mods, and Bash and Zsh completions.

## First run in 60 seconds

1. Run `cs debug-api`. cs creates a workspace and opens Claude Code without needing an existing project or git repository.
2. Describe your task. cs records the first substantive prompt in the session's `Objective` section and keeps notes under `.cs/`.
3. Exit Claude Code. Run `cs debug-api` again and accept the prompt to resume the recorded conversation.
4. Run `cs` to open the session picker. Choose a session to reopen it, or use `cs .` from a known session root.

![cs statusline cycling through quiet, context warning, critical context, queued tasks and unread mail, and quota reset countdowns](https://raw.githubusercontent.com/hex/claude-sessions/main/assets/statusline.svg)

The [statusline guide](docs/statusline.md) covers the capsules, colors, thresholds, font setup, and agent rows.

## Features

| Feature | What it does | Details |
|---|---|---|
| Session records | Keeps objectives, per-actor narratives, memory, plans, checkpoints, and a timeline in `.cs/`. | [Session layout](docs/session-layout.md) |
| Crash recovery | Saves edits to shadow git refs without adding normal branch commits. | [Autosave hook](docs/hooks.md#autosave-commitssh-posttooluse-on-writeedit) |
| Conversation rotation | Hands work to a fresh conversation through `/rotate` and `/clear`. | [Rotation and queue hooks](docs/hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) |
| Parallel worktrees | Gives each feature its own checkout and session records. | [Worktree records](docs/session-layout.md) |
| Task queue | Runs confirmed tasks at turn boundaries, with failure, context, and quota breakers. | [Queue behavior](docs/hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) |
| Cross-session mail | Delivers local messages and wakes idle sessions for unread arrivals. | [Mail wakes](docs/hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) |
| Secrets | Uses the macOS keychain or encrypted files, with signed age exports for sync. | [Secrets guide](docs/secrets.md) |
| Encrypted sessions | Keeps notes, transcripts, plans, and private state in a vault on macOS. | [Encrypted sessions](docs/session-layout.md#encrypted-sessions) |
| Statusline | Shows session, git, model, context, queue, mail, and rate limits. | [Statusline guide](docs/statusline.md) |
| Prompt grounding | Adds matching files, recent commits, changes, and clarification guidance to code-work prompts. | [Scope hook](docs/hooks.md#scope-promptsh-userpromptsubmit) |
| Prompt rewriting | Ctrl+G rewrites a draft in the composer for you to review before sending. | [Prompt rewriter](docs/hooks.md#prompt-rewritersh-not-a-hook--an-editor-shim) |
| Session wrap | `/wrap` saves memory, summarizes the narrative, and archives completed tasks without committing. | [Memory checks](docs/hooks.md#memory-index-guardsh-not-a-hook--run-by-wraps-memory-pass) |
| Inline Mermaid | Draws supported flowcharts in replies. Requires Claude Code 2.1.300+. | [Mermaid mod](docs/hooks.md#cs-mermaid-not-a-hook-script--a-claude-code-mod) |
| Release notes | Shows pending release notes in-session through `/cs-update`. | [Update mod](docs/hooks.md#cs-update-not-a-hook-script--a-claude-code-mod) |
| Other front ends | Session hooks also work in desktop and IDE conversations opened in a `.cs/` workspace. | [Session resolution](docs/hooks.md#how-a-hook-finds-its-session-cs-resolvesh) |

## More

<details>
<summary>Command reference and setup details</summary>

### Commands

Run `cs -h` for help and `cs -v` for the version. Aliases include `-help`, `-version`, `-ls`, `-diag`, and `-remove`.

| Command | Purpose |
|---|---|
| `cs -- <name>` | Ends option parsing before creating or resuming a session. |
| `cs -tui` | Opens the picker from any directory. |
| `cs -list [--tag <tag>] [--archived]` | Lists sessions, filters a tag, or lists only archived sessions. |
| `cs -search <query> [--include-archived]` | Searches session narratives, memory, and README files. |
| `cs -whoami`, `cs -who` | Shows your actor name or contributors from git history. |
| `cs -checkpoint "<label>"` | Saves narrative, changes, and the current git revision. Use `list` or `show <name>` to inspect snapshots. |
| `cs -narrative rotate` | Archives the oldest narrative sections past the size budget. `cs <name> -narrative rotate` targets a named session. |
| `cs -queue add "<task>"` | Adds a task. Other actions are `accept <id>`, `list`, `start [subagents\|workflow]`, `rm <n>`, `clear`, and `log`. |
| `cs -msg <session> "note"` | Sends mail. Bare `cs -msg` reads unread mail. Use `log`, `thread <id>`, or `--reply <thread> "note"` for history and replies. |
| `cs -spawn <name> [--brief <file>] [--task "..."]` | Opens a cs tmux window with a first-turn brief or an armed task queue. Attach with `tmux attach -t cs`. |
| `cs -conversations` | Shows the conversation chain. `cs <name> -conversations` targets another session. |
| `cs -tag add\|rm <tag>` | Edits README frontmatter tags. Use `-tag list` or `cs <name> -tag ...` to inspect or target another session. |
| `cs -archive <name>...`, `cs -unarchive <name>...` | Hides or restores sessions. Opening an archived session restores it. |
| `cs -live` | Lists local live sessions with actor, uptime, agent state, and status. |
| `cs -status "<text>"` | Sets advertised status. Bare `-status` reads it. `--clear` restores the `Objective` fallback. |
| `cs -usage [--all] [<name>]` | Reports session token usage over the 5-hour and weekly windows. |
| `cs -doctor` | Checks installation, session state, recovery, settings, and model-context permissions. |
| `cs -vet-session <dir>` | Exits 0 if git tracks no `.cs/local` or `.cs/private` files. Otherwise names the files and how to untrack them. |
| `cs -encrypt <name>` | Moves a closed session's private files into a vault on macOS. Asks for a password at each open. |
| `cs -statusline enable\|disable` | Registers or removes the statusline and agent rows. Restart Claude Code after enabling. |
| `cs -statusline caps on\|off\|ask` | Records whether your font displays rounded capsule ends. |
| `cs -detect-theme` | Reports terminal theme detection. |
| `cs -rm <name>...` | Confirms each removal and names user files, including untracked worktree files. |
| `cs -update [--check\|--force]` | Checks for an update without installing, or reinstalls the latest release. |

### Sessions, locks, and safety

A new session starts with one commit of its initial files. Later edits autosave to shadow refs for crash recovery.
Other task names work the same way, such as `cs homeassistant`, `cs router-config`, and `cs research-llms` for home automation, network setup, and research.
`cs .` requires the exact root of a known session, adopted project, or feature worktree. It refuses subdirectories and unrelated directories with adoption guidance.
cs stores a conversation identifier in gitignored `.cs/local/state` and resumes that exact conversation with `claude --resume`, rather than `--continue`. Launches pass `--name` and a per-session `/color`.
The duplicate-conversation guard recognizes identifiers after `--session-id`, `--resume`, `-r`, and `--parent-session-id`, so a leftover shell child carrying the identifier does not block a launch. `--force` overrides that guard and the ordinary process lock.
A running lock process or a statusline heartbeat under 900 seconds old makes a session live. This is local presence, including conversations opened outside cs, with no network presence service.
The destructive guards use the process lock, so a heartbeat alone does not block removal. A remote-control server blocks opening, removal, and forced removal until it stops.
From inside a session, `--force` cannot remove or archive another live session, except the base's own features, or a base with a live feature unless run from that base. Force with user files also requires `--delete-files`.
Removing a base also removes its age pins in `~/.cs-secrets/sessions/<name>/`; removing a feature or adopted link keeps them. A mounted vault inside a session blocks removal, and finish and uninstall never delete through it.
Archive state lives in tracked `.cs/archived`, so it syncs through git and hides sessions from normal listing and search. See [shared and machine-local records](docs/session-layout.md).
Outside the launcher, desktop and IDE hooks keep notes, timeline, recovery, and scope context without replacing the recorded conversation. Plain `claude` in a terminal remains cs-blind. A newer outside conversation triggers a launch warning with its identifier and `claude --resume <identifier>`.

### Usage and health

`cs -usage` sums input and output tokens, deduplicates requests, excludes cache reads, and includes nested subagent and workflow transcripts. The model column describes the parent conversation. A named session adds per-conversation and lifetime totals.
`READS>350L` reports untargeted/all Read results over 350 lines and estimates untargeted tokens as characters divided by four. Only an explicit offset or limit makes a read targeted. Harness truncation does not, and shell `cat` or `head` reads do not count. Both file records and inline subagent results count.
The [statusline's reset stamps](docs/statusline.md) anchor usage windows. Agent states `busy`, `waiting`, and `idle` come from `~/.claude/sessions/` only while the process identifier and start time still match. Older hosts before Claude Code 2.1.224, or the shell reader without jq, show no state.
Doctor checks the secrets backend, hooks, shadow refs, memory writability, statusline registration, settings counts, project tokens, cs and cs-update runtime markers, and the migration stamp. Its Authority section lists context-injecting hooks and their opt-outs.
For a picker installed from a checkout, doctor checks Rust and Cargo input timestamps and compares the installed binary with that checkout's build, from any directory. Release downloads skip this build check. Build with `cd tui && cargo build --release`; installation takes the newer of `tui/target/release/cs-tui` and `bin/cs-tui`.

### Adopt an existing project

Run `cs -adopt my-project` inside the project. cs adds `.cs/`, a sessions-root symlink, and gitignored `CLAUDE.local.md` without moving the project or changing your `CLAUDE.md`.
Adoption commits nothing and preserves an existing index. Without git, it initializes branch `main`. It lists pending `.cs/`, `.gitignore`, and `.gitattributes` changes.
Recorded `cs_mode: tracked` requires `.cs/` committed before creating features. Existing `.cs/` ignore rules select `ignored` mode instead, with feature exclusions in `.git/info/exclude`. You can edit the mode in `.cs/local/state`.
Before writing, adoption refuses outward symlinks at `.gitignore`, `.gitattributes`, or `CLAUDE.local.md`, and tracked files under `.cs/local` or `.cs/private`. Existing orphaned `.cs/` records need confirmation. `--yes` or `-y` skips that question; unattended adoption without it refuses.
Adoption offers the newest native conversation in the unchanged directory, or starts fresh when none exists. It seeds `Objective` from the first eligible prompt, skips slash commands and prompts under eight characters, and clips at 100 characters. Without a conversation it leaves the placeholder.
`cs -adopt --worktrees` registers this repository's `.claude/worktrees/*` with conversations as `<repo>.<worktree>`, retaining their conversation and `Objective`. It hides cs files through local exclusions, commits nothing, and leaves tracked `CLAUDE.md` alone.
It skips missing conversations, tracked `CLAUDE.local.md` or `.claude/settings.local.json`, non-worktrees, and repository layouts with `HEAD` before `.git`. Reruns finish partial adoptions, add new worktrees, and prune deleted links. `--dry-run` writes nothing.

### Parallel worktrees

`cs myproj@fix-auth` creates branch `cs/fix-auth`; `cs myproj@perf` opens another independent feature. An already-open base offers existing features, a new feature, a forced launch, the picker, or cancellation.
Each feature has its own conversation, color, task list, and recovery refs, and shares the base's secrets. The base needs a commit and, in tracked mode, committed `.cs/` records. A dirty base asks before branching from its last commit, or refuses without a terminal.
When git ignores `.cs/`, the feature inherits memory topics, `MEMORY.md`, plans, and summary, but not narratives, local state, or timeline. [Session layout](docs/session-layout.md#merge-policy) explains record fusion and keeping the base's memory index.
[`/feature <name>`](skills/feature/SKILL.md) writes a brief and runs `cs -spawn <base>@<name> --brief <file>`. The feature reads `.cs/brief.md` first, the base keeps working, and the result returns by mail. The model may invoke it; the spawn permission prompt remains.
Use `cs <base> -features` for readiness and `cs <base> -finish <feature>` to open the base with [`/finish <feature>`](skills/finish/SKILL.md). Only the user invokes finish.
Finish captures the feature commit, merges in a detached temporary worktree, fast-forwards the base, reports any GitHub pull request, and fuses session records. Ordinary feature branches use a merge with `--no-ff`.
Finish runs no gate unless requested with `--gate`. It reports `gate skipped` only for an already-merged pull request with passing recorded merge checks and no extra base commits. A clean gate checkout lacks ignored dependencies, environment files, and build output; a gate needing them must install them, for example `-- sh -c 'npm ci && npm test'`.
Finish can land work while the feature conversation runs, but retirement waits for it to close. Close it and rerun finish. No keystroke or signal closes the other session.
Retirement commits nothing and refuses dirty or untracked work. Recreated build directories such as `node_modules`, `target`, and `.venv` go with the checkout. Other ignored files go to system trash, with each file or whole-directory count listed. It refuses if neither `trash` on macOS nor `gio trash` on Linux can preserve those files. Special files can also block retirement.
Abandon with `cs -rm myproj@fix-auth`. See [feature records](docs/session-layout.md) for inherited copies and `.cs/features/<task>/` outcomes.

### Task queue and mail

Bare `cs -queue` lists pending and completed tasks. `rm <n>` removes a pending task; `clear` empties it and stops draining. Outside a session, `cs <session> -queue add "..."` targets it; from another session, that becomes task mail requiring acceptance.
`/queue <task>` adds even mid-turn. Bare `/queue` lists tasks and offers Start, Not yet, or Compact when idle. Start chooses this conversation, subagents, or workflows, with the workflow choice authorizing that tool. Without the cs mod, run `cs -queue start [subagents|workflow]` yourself.
The drain takes tasks in listed order at turn boundaries, mirrors native tasks, and checks delegated results. Breakers park it at five failures, 85% context, or 85% 5-hour usage by default. `start` rearms it; `log` shows the journal. [Queue hooks](docs/hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) document the scope rules, return digest, and configurable limits.
Mail uses `--kind notify|task|text|result`. Task mail enters the queue only after `cs -queue accept <id>`. Bodies are at most 65,536 bytes; a lone `-` reads stdin. Unread bodies repeat in prompt context until read, at most five and truncated. This is same-machine mail without authenticated sender attribution.
Each message has a thread and a sender copy. Replies infer the peer and reject a conflicting named target; thread views order by reply relationships rather than timestamps. [Session layout](docs/session-layout.md) describes atomic message files.
A spawned session's completed queue drain mails the spawner. Only the spawned window takes a staged brief and tasks without asking; other opens within an hour show the seed and ask. See [spawn staging](docs/session-layout.md) and [mail wake limits](docs/configuration.md).

### Conversation rotation and wrap

Invoke `/rotate`, then `/clear` to continue from its handoff. The [hooks guide](docs/hooks.md) covers the automatic wake, context thresholds, Ctrl+X actions, wrap confirmation, and forced rotation countdown.
At the next launch, `y` or Enter resumes, `r` starts from the handoff, `n` starts fresh, and `d` discards then resumes. Resume and fresh disarm the marker with a notice but leave the handoff pending. The launch card and plain resume prompt show the recorded context when the statusline supplies it.
Cross-checkout handoffs carry a label and remain usable. Choosing one consumes it under the successor's identifier. Names must contain only letters, digits, `._@-`, and at most 160 characters. cs skips invalid names with a notice. A valid armed marker wins; otherwise the last unconsumed basename in lexical order wins.
Compaction and context-limit forks preserve the marker. [Session layout](docs/session-layout.md) documents lineage-stamped handoffs, their marker, and encrypted storage.
The rotate skill supersedes its earlier pending handoffs and prunes clean, tracked consumed, discarded, or superseded handoffs older than 30 days by `created:`, keeping the newest ten. No cs command prunes them. Git history retains removed files.
Handoffs redact credentials, identifying data, and sensitive personal detail, put blockers first, reference committed work by path, and keep the user's words while condensing agent reasoning.
`cs -conversations` folds starts with resume counts and marks the current conversation. Rotation events name the old and new identifiers and a reason, `handoff`, `declined-resume`, `resume-failed`, or `rebind`.
`/wrap` saves durable memory, sweeps findings into the narrative, writes `.cs/summary.md`, rotates the narrative, and archives completed tasks with consent. It checks memory pointers and budgets, moves finished or enforced-rule pointers to the memory archive before rewording, and keeps entries while adding tasks for checks that could enforce them. It commits nothing. `/checkpoint <label>` saves a snapshot mid-session.
See [memory checks](docs/hooks.md#memory-index-guardsh-not-a-hook--run-by-wraps-memory-pass), [task archives](docs/session-layout.md), and [narrative budgets](docs/configuration.md).

### Remote control

`cs <name> --remote [--permission-mode <mode>]` serves the session through `claude remote-control --name <name>` for the Claude app or claude.ai/code. Requires Claude Code 2.1.299+ and a full login; cs clears `ANTHROPIC_API_KEY`.
Its app and web children use the session's hooks, memory, tasks, and secrets. Live listings show `remote` and the server process identifier, and doctor reports the server.
cs checks that the first word of `CLAUDE_CODE_BIN` identifies Claude Code. Explicit permission mode wins; otherwise it carries the configured mode, maps `--dangerously-skip-permissions` to `bypassPermissions`, or uses `default`. It drops `--allow-dangerously-skip-permissions` with a notice. cs refuses other options and wrappers such as `op run -- claude` by name.
Inside tmux, the server gets `remote:<name>` in the cs tmux session and preserves the invoking root and Claude command. Otherwise it uses the current terminal. First-run trust questions require a terminal. `--spawn=same-dir` keeps child sessions in this directory; an encrypted session has its own config trust prompt.
The first child leads, simultaneous children remain guests, and a later child becomes lead after the lead exits. Children keep the remote window or `cs: <name> (remote)` tab title. A staged spawn seed waits for the next ordinary open.
Stop with Ctrl+C or close the window. A forced kill can leave a child and stale marker; doctor clears a marker whose process no longer serves. Restart can reattach the old cloud session with its old title. See [remote state](docs/session-layout.md).

### Shell completion

For Bash, add this to `~/.bashrc`:

```bash
[[ -f ~/.bash_completion.d/cs.bash ]] && source ~/.bash_completion.d/cs.bash
```

For Zsh, add this to `~/.zshrc` before `compinit`:

```bash
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

Restart the shell or source its configuration. `cs <TAB>` offers sessions and flags; `cs home<TAB>` completes a matching session; `cs -<TAB>` offers global flags; `cs session -secrets <TAB>` offers secrets actions. Names come from cs and include adopted symlink sessions, matching `cs -list`.

### Installation, updates, and settings

The binaries are `cs`, `cs-secrets`, `cs-statusline`, `cs-subagent-statusline`, and `cs-tui`. Hooks live in `~/.claude/hooks/cs/`; `/checkpoint`, `/wrap`, their memory and summary passes, the six skills, and the three mods install under `~/.claude/`.
The skills are `store-secret`, `prose-hygiene`, `rotate`, `finish`, `feature`, and `write-as-me`. The mods are `cs`, `cs-update`, and `cs-mermaid`. See [hook and mod behavior](docs/hooks.md) and [rotate and wrap keys](docs/configuration.md#rotate-and-wrap-keys).
Settings changes create mode-preserving sibling backups named `settings.json.cs-bak.<UTC stamp>`, with numbered collision suffixes. Unchanged writes create none, and cs retains the five newest backups.
The `.installed` record under the hook directory stores SHA-256 checksums. Install, update, and uninstall replace or remove only cs-written content, including content shipped by a past release without a record, and list preserved user files with `Kept <path>` warnings.
Retired user files warn once per content, except paths containing newlines cannot enter the record and warn each time. FIFOs, devices, and links to them stay unread. Symlinked skill directories stay untouched. Retired commands disappear only when cs wrote them. Content checking and replacement are separate operations; a concurrent rewrite can occur between them.
`.tui-origin`, beside `.version` and outside `.installed`, records `checkout <path>` or `release` for doctor's picker check. Installing no picker or preserving your own picker link leaves it unchanged; uninstall removes it.
Updates come from GitHub Releases with SHA-256 verification and [minisign](https://jedisct1.github.io/minisign/) verification when available. `cs -update --check` prints the full pending notes. A launch uses a compact update card when you disable function-hook mods; otherwise the [update mod](docs/hooks.md#cs-update-not-a-hook-script--a-claude-code-mod) shows them.
For defaults and overrides, see [configuration](docs/configuration.md). `CS_SESSIONS_ROOT` defaults to `~/.claude-sessions`; cs and cs-secrets resolve a relative value from their startup directory.

### Writing, terminal integration, and Markdown notes

[`prose-hygiene`](skills/prose-hygiene/SKILL.md) judges a draft against phrase, structure, and voice rules with a scoring rubric.
[`/write-as-me`](skills/write-as-me/SKILL.md) drafts messages, replies, pull requests, and docs in your voice. First use builds an editable profile from typed transcript messages at `~/.claude-sessions/.voice/profile.md`. Supplementary writing in `.voice/sources/*.md` joins the corpus on each build.
With [claude-council](https://github.com/hex/claude-council) or the codex plugin installed, the Stop hook offers decision-point advice and review. See [advisor behavior](docs/hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) for consent and reminder limits.
cs redirects [Claude Code auto memory](https://code.claude.com/docs/en/memory) into `.cs/memory/`; the harness owns memory-file format and cs owns the storage path. See [memory records](docs/session-layout.md).
In iTerm2, cs tints the tab with the session color and resets it on exit. Shell integration enables a finished-turn dock bounce until the next prompt; tmux adds progress and a Claude title icon. [Configuration](docs/configuration.md) covers the opt-out, and doctor reports the integration state.
The sessions root contains Markdown notes and an `index.md` regenerated on session end. Session README frontmatter has `status`, `created`, `tags`, and `aliases`; conversation identifiers and activity state stay machine-local. See [session layout](docs/session-layout.md) before opening this directory in [Obsidian](https://obsidian.md).
For git sharing, see [merge policy](docs/session-layout.md#merge-policy) and [signed, per-machine secrets sync](docs/secrets.md), including [age](https://github.com/FiloSottile/age) exports. Launch installs the per-clone memory merge driver; pulling before the first launch uses ordinary text merging, and doctor warns when the driver is missing.
For secrets commands, examples such as `cs my-project -secrets list`, storage backends, and live-session write restrictions, see the [secrets guide](docs/secrets.md). Named narrative rotation refuses another live session except a base's own features. `--force` bypasses neither guard.

</details>

## Uninstall

```bash
cs -uninstall
```

## Documentation

| Guide | Contents |
|---|---|
| [Configuration](docs/configuration.md) | Every environment variable cs reads and the values it exports. |
| [Session layout](docs/session-layout.md) | Shared and local records, encryption, and merge policy. |
| [Hooks](docs/hooks.md) | Hook behavior, prompt rewriting, and Claude Code mods. |
| [Secrets](docs/secrets.md) | Storage backends, backups, and signed sync files. |
| [Statusline](docs/statusline.md) | Segments, colors, thresholds, and agent rows. |

## License

[MIT](LICENSE). Contributions can start with an issue or pull request.
