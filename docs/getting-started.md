# Getting started with code-sessions

code-sessions is a fork of cs with Claude and Codex support.

## Install this checkout

```bash
sh ./setup.sh
```

Setup builds the fork and installs it as `cs`, `ccs` and `code-sessions`, using
your normal `~/.claude` and `~/.codex` configuration and logins. It backs up the
existing cs installation before replacing it. No uninstall or agents-sidebar
fork is needed. Use `--skip-tui-build` to skip building the optional picker.

When upgrading from the private profile, setup imports missing conversation
files and Codex thread records. Existing records win on a conflict, which is
reported; the old profile remains available. It does not replace credentials
or personal preferences. Already-running agents retain their old launch
configuration until reopened.

Existing project folders, secrets and vaults remain in place. If the old fork
session store exists, `ccs` keeps using it, including its secret namespace and
tmux server; `cs` uses the usual session store. Both run the same fork and
share normal engine configuration. Fresh installations use the usual store
for all three commands.

Choose integrations with `CS_INSTALL_ENGINES=claude,codex` (the default).
Setup requires Bash, Git, jq and Python 3. Install the native CLIs separately.
The ordinary upstream Agents sidebar works with this configuration.

## Adopt a project or create a workspace

To make the current project a code-sessions workspace, run this from its root:

```bash
cd /path/to/my-project
ccs -adopt my-project --engine codex
```

Adoption keeps the project files where they are and adds `.cs/` workspace
metadata. The adoption operation may commit its bookkeeping files to the
project's Git repository. Omit `--engine` to use the configured default, or
specify `--engine claude` to choose Claude explicitly. The first open of an
adopted project starts a new conversation; there is nothing to resume yet.
Re-adopting a project whose `.cs/` records name a conversation keeps it.

To create a separate session workspace for a task that is not an existing
project, run:

```bash
ccs research-notes --engine codex
```

This creates a workspace and starts Codex there. If the former fork's session
store exists, `ccs` uses
`~/.local/share/code-sessions/home/sessions/research-notes/`. Fresh installations
use `~/.claude-sessions/research-notes/`. Running the same command later resumes
that workspace.

## Resume and switch engines

Resume with the saved engine:

```bash
ccs research-notes
```

Use an explicit flag to bypass the resume/fresh prompt:

```bash
ccs research-notes --resume
ccs research-notes --fresh
```

A failed resume preserves its recorded conversation. Fresh creates a new native
conversation while retaining the workspace and notes. Each engine keeps its own
binding; switching engines does not erase the other engine's history.

To switch engines, close the current interactive CLI first, then launch with the
other engine:

```bash
ccs research-notes --engine claude
ccs research-notes --engine codex
```

In the session picker (`ccs -tui`), select a session and press `e` to open
**Engine / model / effort**. On the Engine row, press Left, Right, or Space to
choose Claude or Codex, then Enter to save. The session menu shows the selected
engine; press Enter again to open it. The engine becomes the session's saved
preference when it launches. Esc cancels unsaved changes. Changing engines
clears the model and effort fields so the other engine uses its native defaults.

The workspace files and `.cs/` notes are shared. Claude and Codex keep separate
native conversation histories, so `--engine` alone opens the other engine's
own conversation, which has not seen the work done since it last ran. Keep
one interactive owner open for a workspace at a time.

To carry the current conversation's work across, ask for the `switch` skill
from inside the conversation (`/switch` in Claude, `$switch` in Codex; name
`claude` or `codex`, or leave it out for the other engine). It writes and arms
a rotation handoff the way the `rotate` skill does, then records the move with
`cs -switch` and tells you how to leave: `/exit` in Claude (the `cs` mod
counts down and runs it for you), `/quit` in Codex. When the CLI exits, cs
reopens the session in the same terminal under the other engine, in a fresh
conversation that starts from the handoff. That engine becomes the session's
saved engine. The previous conversation stays on disk and is not resumed;
`ccs research-notes --engine <previous engine>` opens it again.

Ask for `--resume` with the switch to resume the other engine's last
conversation in this session instead. The handoff becomes its first new
message. When that engine has no conversation recorded here, cs says so and
starts a fresh one.

`cs -switch cancel` drops a recorded switch and leaves the handoff armed, so
`/clear` continues from it in the same engine. A `/clear` instead of the exit
also takes the handoff in the same engine; cs then drops the switch with a
notice. If the CLI exits with an error, or the other engine cannot start, cs
prints both ways back and the handoff stays armed:

```bash
ccs research-notes --engine codex --from-handoff
ccs research-notes --engine claude
```

`--from-handoff` starts a fresh conversation from the pending handoff without
the resume prompt: the armed one, otherwise the newest unconsumed one, labelled
`(from another checkout)` when this checkout did not write it. Without a
pending handoff it refuses and points at `--fresh`. It cannot be combined with
`--fresh`, `--resume` or `-finish`. Codex does not open an
[encrypted session](session-layout.md#encrypted-sessions) yet, so the switch
into Codex and `--engine codex --from-handoff` refuse there; open it with
`cs <name> --engine claude`.

Run `ccs .` from the root of an adopted project or registered session to open
that workspace. From anywhere, `ccs` with no arguments opens the interactive
session picker when the TUI was built before installation. Without the picker,
bare `ccs` prints help; named session launches still work.

## Work in a parallel feature worktree

From an existing session, create a named feature worktree with:

```bash
ccs my-project@fix-auth --engine codex
```

List feature worktrees from the base session with:

```bash
ccs my-project -features
```

The base project should have a clean, committed starting point before you
create a worktree. The worktree has its own session metadata and shares the
base repository's Git history. When the feature is done, finish it from the
base: `ccs my-project -finish fix-auth` opens the base on the `finish` skill
(`/finish fix-auth` in Claude, `$finish fix-auth` in Codex, which you can also
type in an open base session). It lands the feature on the base and removes
the worktree once the feature's conversation is closed. Under Codex it asks
you to approve its steps outside the sandbox: asking GitHub for the PR,
writing the base's `.git`, and removing the worktree beside it.

## Save a manual checkpoint

From an active session, ask the assistant to save a named checkpoint, or run:

```bash
ccs -checkpoint "before changing the schema"
ccs -checkpoint list
ccs -checkpoint show <checkpoint-name>
```

A checkpoint records the current Git HEAD, changed-file list, and session
narrative under `.cs/checkpoints/`. It is a reference snapshot; commit your code
separately when you want to preserve the contents of the changes themselves.

## Current Codex limits

Codex currently supports engine selection, launch, exact thread resume,
shared startup context, rotation, the `switch` skill in both directions, and
finishing a feature (`-finish`, `$finish`).
Claude's hooks and mods do not run inside Codex. Codex does not yet provide
cs's autosave and crash recovery, automatic queue or mailbox
delivery, runtime usage reporting, encrypted sessions, or native terminal
controls. Manual status and workspace management are available.

This fork updates from its checkout. `cs -update` refuses to replace it with
an upstream release; rerun `setup.sh` to install checkout changes.
