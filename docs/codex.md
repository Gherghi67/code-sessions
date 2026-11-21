# Codex CLI sessions

cs can launch a named session with Codex CLI while keeping the session's files,
notes, and workspace under the same `.cs/` directory used by Claude Code.

## Launching

```bash
cs investigate --engine codex
cs investigate --engine claude
```

CS chooses the engine in this order: `--engine` on the current command, the
session's saved engine preference in `.cs/local/state`, `CS_DEFAULT_ENGINE`,
then the sole installed Codex adapter, otherwise `claude`. The explicit option accepts `claude` or `codex`. Claude remains
the default on legacy or dual-adapter installations when no preference is set. A Codex
launch saves the selected preference after its startup helper succeeds and
before the interactive CLI resumes. A failed Codex startup leaves the prior
engine preference and thread binding intact. A Claude launch records its
preference when SessionStart acknowledges the conversation or the native launch
returns successfully.

Codex launches use the `codex` executable by default. Set `CODEX_BIN` to its
path when it is installed elsewhere. The Codex adapter uses Python 3 for its
startup/bootstrap helper. Opening an [encrypted session](#encrypted-sessions)
under Codex needs Python 3.11 or later (`tomllib`) as `python3` on `PATH`;
macOS's `/usr/bin/python3` is 3.9, and a Homebrew or python.org Python works.
Codex CLI must be installed and authenticated for the current user; CS does
not configure Codex credentials.

The startup helper uses Codex's experimental app-server `thread/inject_items`
API to create or resume a thread and append startup context without starting a
model turn. This API was verified with Codex CLI
`0.158.0-alpha.2.1`; compatibility with other builds depends on those
experimental protocol capabilities being present. CS checks at startup and
reports an error when they are unavailable. It does not upgrade Codex
automatically.

CS selects **Approve for me** by default on Codex launches, including new threads,
exact resumes, and engine switches, by passing `--approve-for-me`. This requires
a Codex build that supports the flag; it is verified with
`0.162.0-alpha.17.2`. Before preparing a thread or consuming a handoff, CS
requires a successful `codex --help` that lists the option when automatic
approval is selected. Unsupported builds are refused in automatic mode;
upgrade Codex or point `CODEX_BIN` at a supporting build. Pass
`--native-approval` to use Codex's configured approval policy instead; this
mode does not require or pass `--approve-for-me`.
Automatic approval uses a `workspace-write` sandbox with
`on-request` approvals and an `auto_review` reviewer. Routine workspace
operations run directly; eligible approval requests go through automatic review,
which can reject an action. You can change the active mode with `/permissions`.
CS applies this launch option without changing your global Codex configuration.

CS keeps the Codex thread ID in the machine-local
`.cs/local/codex-thread-id` file and resumes that exact thread on later Codex
launches. This binding is separate from Claude's conversation UUID. The engine
preference and conversation identity are local to that machine and are not
shared through Git.

Starting a different thread inside the Codex CLI does not update CS's saved
binding in this version. Use `cs <name> --engine codex --fresh` to explicitly create and bind another
conversation in the same workspace; reopening without that choice resumes the
recorded ID.

CS launches Codex with `--no-daemon`, so the thread writer is released when the
CLI exits. Keep one interactive owner for a thread: close that Codex thread in
the desktop app or another CLI before asking CS to resume it.

## Resume or start fresh

```bash
cs investigate --engine codex --resume
cs investigate --engine codex --fresh
```

Both engines accept these mutually exclusive flags. `--resume` fails when no
conversation is recorded and never creates a replacement. `--fresh` keeps the
previous binding until native preparation acknowledges the candidate. A failed
resume returns an error with the old binding intact.

Without either flag, an interactive reopen offers resume or fresh. Unattended
launches resume the recorded conversation by default. A new workspace starts a
conversation. Engine switching preserves the other engine's saved ID.

`--from-handoff` takes the `r` answer without asking: a fresh thread starts
from the pending rotation handoff (the armed one, otherwise the newest
unconsumed one) and runs its first turn on its own. Without a pending handoff
it refuses and points at `--fresh`; it cannot be combined with `--fresh`,
`--resume` or `-finish`. An explicit `--fresh` on Codex also continues an
armed rotation, while Claude's `--fresh` disarms it; `--from-handoff` reads the
same on both engines.

Both engines run under the same launcher-owned lease and cleanup. Codex's
persistent helper acknowledgement establishes its binding; this does not mean
the interactive CLI has completed authentication or a model turn. The normal
CLI exit status is returned to the caller.

## Switching engines

```bash
cs investigate --engine claude
```

After a run under Claude, an attended `--engine codex` reopen offers Claude's
newer conversation (and the other way round): `y` carries it over, `e` resumes
the engine's own earlier conversation (offered only on this prompt), `n` starts
fresh. The carried thread is a new one: cs starts it through app-server, adds
the session context, then a developer note and Claude's messages as user and
assistant items, with every tool call and each tool result's first 4,000
characters (a failed call's result marked `[tool error]`), and binds it.
In the Codex transcript, a completed Claude Bash call appears as a native
command row with its output. Other tools appear as named tool rows with
their arguments, result and failure status. Claude built-ins use the
`claude` server label and MCP tools keep their server and tool names.
Parallel results attach to the matching Claude call ID. Calls and results
without a unique partner in the same reply keep their text representation,
as do arguments too deeply nested or numerically out of range for native replay.
The model history retains the original order, with tool inputs laid out as
fenced `key: value` lines and tool results as fenced text.
There, and in any call kept as text in the transcript, an input crosses as a
`key: value` line per field, a multi-line value (a heredoc, an edit's text)
indented under its name after `|` (one final newline), `|-` (none) or `|+`
(more). Codex's model reads this text, so a value that would read as something
else (empty, `"2"`, `"true"`, edge spaces, a control character) stays quoted
as JSON, and levels nested past 32 cross as JSON.
The helper records the carried model messages and transcript display events
inside matching turn boundaries after the new thread's writer exits, so native
revert removes both views of an exchange. It then resumes the thread in a
separate process and checks the visible turns before reporting success. This makes the imported messages visible in the CLI;
injecting model context alone leaves the transcript blank. When that check finds
a row Codex changed, dropped or added in a carry with native tool rows, the helper
deletes the new thread, says so in one line and carries the conversation again
with its tool calls as reply text; a check that times out, loses its server or
breaks the protocol fails the carry instead. Native tool rows were
verified in the Codex `0.169.0-alpha.11.1` terminal. CI pins `0.167.0-alpha.3.2` on macOS and Linux
and checks native display, revert's next model input, and messages above 4 MiB
using temporary homes and a local mock provider. Existing open threads are not
rewritten.
Imported turns use the import time and do not claim token usage; the context
meter can still read zero until the first Codex model turn.
Claude's thinking stays behind, and since its last compaction a Claude
conversation starts from the compact summary. After `y`, cs names the earlier
thread's full id: `codex resume <id>` opens it outside cs, and the binding
stays on the carried thread. A carry-over Codex refuses leaves one line, and
the launch resumes the earlier thread, or starts a fresh one when there is none.
The other direction writes the Codex thread as a Claude transcript that Claude
resumes; Codex's encrypted reasoning and its injected context (AGENTS.md,
`<environment_context>`, skill bodies and the other tags cs knows as Codex's)
stay behind, while a prompt the user wrapped in a tag crosses. Claude Code shows matching calls and results as native tool rows.
Direct shell commands appear as Bash, MCP calls retain their server and tool
names, and other Codex tools use the `codex` server label. MCP and Codex tool
rows need Claude Code 2.1.326 or later, the oldest checked to draw a tool it
does not have; below it, or when cs cannot read Claude's version, those calls
cross as fenced text and only Bash rows stay native. A Bash row carries
the command alone: Codex's execution options (timeouts, output limits, sandbox
and login settings) stay behind, and a working directory other than the
session's is folded into the command as `cd <directory> && `. A code-mode script
appears with its original input and decoded output. Expand the transcript
with Ctrl+O to inspect each row. Parallel results refer to their originating
call IDs, and a reported tool failure includes its tool name on Claude’s error line.
A result counts as failed when code mode's header says `Script failed` or
`exec_command` reports a non-zero exit code; its text fallback then reads `[tool error]`.
A carried result's `<system-reminder` tags arrive with `<` written as `&lt;`,
as Claude Code writes them in content its own tools did not produce; so do
those in a carried user message, where a `!` command's output is kept.
Calls without a matching result, orphaned results, and inputs Claude cannot
represent as a tool argument object use the fenced text format. Sub-agent
final answers also cross as fenced text. In that format a function call's JSON
arguments cross as `key: value` lines (arguments that are not one JSON object
or list, that repeat a key, or that are nested too deeply to lay out, cross as
written, under a `[tool call: <name>, arguments as written]` head), a custom
tool's input (a code-mode script, a patch), a shell command (its words quoted
as a shell would) and a search cross as written, and each input, each result
and a sub-agent's final answer sit in a code fence, with cs's cut note and
`[image]` marks after it. Text in a fence loses the blank lines before it and
the whitespace after it. In code mode,
Codex's `exec` and `wait` tools record what a script passes to `text()`, as JSON
when it is not a string, so a command run from a script arrives as
`exec_command`'s result object. cs carries a single such result, when nothing is
printed after it, as the command's own output, marked `[exit code N]` when not 0
or `[still running in Codex, session N]`. When a tool result holds several
results, each output crosses under its own `[output k, status]` line, as does a
single result with text printed after it. A printed structure around results
(`Promise.allSettled`'s array, say) first crosses as compact JSON with each
result replaced by `<output k, status>`, and keys a script added to a result
stay in that JSON beside its placeholder, so such a result crosses this way even
alone. A result that starts a line after other text, such as
Codex's truncation warning, converts the same way, and that text stays. When a
tool result holding several results would be cut, a line after the script's
header lists every result's status first. The result's chunk ID, wall time and
token count stay behind, and all of this happens before the tool-result cut;
other tools' output, and JSON holding no command result, cross as written. A
sub-agent's final answer crosses cut like a tool result; its other messages are
encrypted and stay. After a Codex compaction only the prompts Codex kept cross:
its summary is encrypted. A conversation carried on again holds only cs's newest
note. [Getting started](getting-started.md#resume-and-switch-engines) shows the
prompt.

To carry the work across in a written handoff instead, ask for
`$switch` in Codex (or `/switch` in Claude), optionally naming the engine and
`--resume`. The skill writes and arms a handoff by the `rotate` skill's steps,
then runs `cs -switch`, which writes into `.cs/` within the workspace sandbox.
Quit Codex with `/quit`, and
the `cs` that launched it reopens the session in the same terminal under
Claude, in a fresh conversation that starts from the handoff. From Claude the
`cs` mod runs `/exit` for you after a countdown, and Codex opens a fresh thread
from the handoff the way `r` does.

`--resume` resumes the target's last conversation in the session instead and
gives it the handoff as its first message (`codex resume <id> -C <dir>
<prompt>` on Codex). A target with no recorded conversation starts fresh, with
a notice. `cs -switch cancel` drops the recorded switch and keeps the handoff
armed. A `/clear` instead of quitting takes the handoff in the same engine, and
the switch is dropped with a notice. A CLI that exits with an error, or a target
that cannot start, leaves the handoff armed and prints both ways back:
`cs <name> --engine <target> --from-handoff` and `cs <name> --engine
<current>`. When the target exits with an error before its conversation
starts, cs also puts back a handoff its launch had already marked consumed.

## Encrypted sessions

An [encrypted session](session-layout.md#encrypted-sessions) runs Codex on a
Codex home inside its vault, `.cs/private/codex-home`, so its rollouts, history,
state databases and logs never reach the shared home (`$CODEX_HOME`, else
`~/.codex`). At every open, cs:

- links `auth.json`, its two lock files, `AGENTS.md`, `AGENTS.override.md`,
  `.env`, `hooks.json` and the `skills/`, `agents/`, `themes/` and `hooks/`
  folders to the shared home, so the login, instructions and extensions are
  the shell's. `plugins/` is a folder of the vault whose `cache/` and staging
  folders link to the shared ones, so plugins are installed once and their
  data (`plugins/data/`) stays in the vault. `.tmp/` is a folder of the vault
  too: only `.tmp/marketplaces/`, where Codex keeps the marketplaces added
  from git, links to the shared one, so those marketplaces are shared; the
  rest of `.tmp/` is per vault. Everything else Codex writes is
  born in the vault. `.credentials.json`, the file Codex falls back to for MCP
  OAuth logins, is not shared: an MCP server that falls back to it logs in
  again inside the session.
- copies the shared `config.toml` in, with each `[hooks.state]` trust entry
  renamed to the vault home's path, since Codex keys hook trust by the path it
  read the hook from. cs renames `[hooks.state."<key>"]` tables, the form
  Codex writes; an entry for the shared home written another way stops the
  open, which names it. Before Codex starts, cs asks it which hooks it trusts
  there, and refuses to start when a hook trusted in the shared home would not
  run (a guard hook would otherwise stop silently). It refuses too, saying so,
  when Codex lists none of the hooks a trusted `hooks.json` or `config.toml`
  defines for the vault home, as a Codex that lists hooks differently from the
  version cs was checked against (0.167) may: trusting them again in `/hooks`
  cannot help there, so update cs or open the session under Claude.
- copies the shared `rules/` folder in, following the links in it. An approval
  you make during an encrypted run (Codex appends an "always allow" for a
  command or a host to `rules/default.rules`) lasts until the next open, which
  copies the folder again; lasting ones belong in the shared `rules/`.
- starts Codex with cs's permissions profile, `cs-vault-home`, on the command
  line: Codex's workspace sandbox with the vault home read-only, so the agent
  cannot rewrite its own configuration, hooks or rules. The profile carries
  your `[sandbox_workspace_write]` writable roots, network access and
  temp-directory settings. A writable root at or inside the vault home is
  refused, since Codex would let it win over the read-only rule. Under
  `--native-approval` the profile is added only to the
  workspace sandbox, never to read-only or full access, and a
  `default_permissions` profile of your own is refused. A config file that
  defines a profile named `cs-vault-home` is refused too.

cs reads and copies `config.toml` with Python's `tomllib`, so the open needs
Python 3.11 or later as `python3` on `PATH`. macOS's `/usr/bin/python3` is
3.9; a Homebrew or python.org Python works.

Settings Codex saves to `config.toml` during an encrypted run (a hook trusted in
`/hooks`, a dismissed notice, a trusted folder) last until the next open, which
copies the shared file again; make lasting changes in the shared `config.toml`.
Relative paths in it resolve from the copy. Choosing other
permissions in Codex's `/permissions` drops the read-only rule for that run:
outside cs's profile the agent can rewrite the vault home's configuration,
hooks and links for that run, and a hook it trusts there runs outside the
sandbox. cs still runs its own hook scripts from the shared home.

Codex therefore asks whether to trust the session folder at each open of an
encrypted session: cs does not carry an answer given inside one, since anything
that writes to the session outside Codex's sandbox could plant it. To stop the
question, trust the folder in the shared `config.toml` (`~/.codex/config.toml`),
under the session folder's full path, as `pwd -P` prints it:

```toml
[projects."/full/path/to/the/session"]
trust_level = "trusted"
```

A project `.codex/config.toml` in a folder the shared `config.toml` does not
trust is one Codex loads only once you answer that question, after cs has
chosen how to keep the agent out of the vault home, so cs's checks never see
what it sets: the open refuses and names the file. Trust the folder in the
shared `config.toml` as above, so the checks read that file too, or remove it.

cs checks the vault home when it opens the session, but Codex reads the vault
home's `config.toml` again at each `/clear`. The vault home lives inside the
session folder, unlike a plain session's `~/.codex`, so while Codex runs in an
encrypted session nothing else should write to the session folder outside
Codex's sandbox (another conversation of the session, a tool started from
one): such a writer can change what Codex loads, MCP servers included, which
run outside the sandbox. It can also reach past the session: a marketplace
entry it adds makes Codex replace that marketplace's checkout under
`.tmp/marketplaces`, which is the shared home's, so every session's Codex sees
it.

A Codex conversation bound before the session was encrypted stays in the shared
home: when the shared home keeps it, the next open starts the session's first
conversation in the vault and says so, and `--resume` refuses. A bound
conversation that neither home keeps is refreshed as in any session, and that
refresh fails with the binding left in place; a lookup that cannot run stops the
open the same way. If the vault home holds a real `auth.json` where cs's link
was, the open stops: cs cannot tell who wrote it (Codex after a `codex logout`
and `codex login` inside the session, or anything else that can write to the
session). Inspect it before you use it, and move it over the shared
`auth.json` only if it is a login you made yourself; otherwise remove it, and
the next open links the shared login again. Handoffs and the launch context
live in `.cs/private`, and switching
or carrying a conversation between Claude and Codex works as in any other
session. `cs -doctor` checks the vault home's links. `cs -update` or
`install.sh` run inside an encrypted session installs into the shared home.
Antigravity runs an encrypted session on a `$HOME` inside its vault
([Antigravity: encrypted sessions](antigravity.md#encrypted-sessions)).

## Workspace preparation and installation

```bash
CS_INSTALL_ENGINES=codex sh ./setup.sh
cs -adopt existing-project --engine codex
cs existing-project@investigation --engine codex
```

Codex-only create, adopt, worktree, and reopen flows create portable `.cs/`
records without allocating a Claude UUID/color, writing `CLAUDE.local.md`, or
configuring `.claude/settings.local.json`. Existing Claude files remain intact.
Switching to Claude prepares its native configuration at that point. A fresh
Codex-only install leaves `~/.claude/` untouched and remembers the selection.
`cs -doctor` reports the selected adapter's dependencies, binding, and capability
gaps. Install choices and migration rules are in [Migration](migration.md).

Setup uses an isolated profile under `~/.local/share/code-sessions/home/`,
including its own Codex login and session registry. Setup creates the
profile's `.codex/` (mode 700), which the launcher exports as `CODEX_HOME`;
Codex refuses a `CODEX_HOME` that does not exist, and a launch with a missing
one stops and names it. Log in with `codex login` on the first launch. Keep the original cs's
workspaces in the original cs; use a new workspace or a separate project for
these examples.

## Shared session context

The workspace and CS records remain shared across engines: project files,
`.cs/README.md`, plans, handoffs, and memory are in the same session directory.
At startup, CS appends context about the relevant `.cs/` files to the Codex
thread so it can load the session protocol and current notes. This does not
transfer the other engine's native memory. A plain `--engine` reopen offers to
carry the other engine's newer conversation over (see Switching engines), and
the `switch` skill carries the work across in a rotation handoff.

CS does not replace or edit a project's `AGENTS.md`. Claude-specific session
configuration, including `CLAUDE.local.md` and Claude's auto-memory redirect,
continues to apply only to Claude Code.

## Current boundary

The Codex integration currently covers engine selection, launch and exact
thread resume, shared-context bootstrap, packaging of the adapter, and the
shipped skills. The installer copies the skills into `$CODEX_HOME/skills/`,
where Codex lists them by name and a message starts one with `$<name>` (for
example `$checkpoint`); `finish` runs only when asked that way. `cs <base>
--engine codex -finish <feature>` opens the base on `$finish <feature>`, as
Claude's opens on `/finish <feature>`. The skill's steps outside the session
folder (`finish.sh` asking GitHub for the PR state, `cs -integrate-feature`
writing the base's `.git`, `cs -retire-feature` removing the worktree beside
it) cross Codex's workspace sandbox boundary and can require automatic approval
review. Its
refusals name Codex's commands (`/quit`, `$finish`) for a session that last
ran under Codex. A skill that
needs an adapter feature Codex lacks says so and stops: `feature` refuses under
Codex for now.

Rotation keeps the model and reasoning effort used for its final turn,
including a selection made with `/model`. On builds with file-backed named
profiles (`--profile <CONFIG_PROFILE_V2>`), cs launches with a profile scoped to
this checkout and snapshots those two settings when a turn arms a handoff.
Both manual and automatic `/clear` then reload that choice. The profile lives
in `$CODEX_HOME/cs-rotation-<checkout-hash>.config.toml`; each launch resets it to
that launch's choices. A link or anything but a file at that name stops the
launch, named: cs never writes the profile through it; remove it, and the next
launch writes the file again. Other sessions keep their own defaults. Restart an
already running cs/Codex once after installing this support. Older Codex builds
print a notice that model carryover needs file-backed profile support.

A trusted project's `.codex/config.toml` outranks that profile. When it sets
`model` or `model_reasoning_effort`, an explicit `--model` or `--effort` for the
same setting stays a command-line override, so it still wins, and that setting
is fixed for the run: `/clear` reloads it whatever `/model` chose since. The
turn that arms the handoff then says which setting `/clear` will use, and no
automatic `/clear` is counted down; choose again with `/model` after `/clear`.

`$rotate` works. It writes and arms a handoff, then tells you to run `/clear`
and send any message: Codex starts no turn by itself, and the handoff loads with
that first message through the SessionStart hook cs registers for Codex
(`cs -codex-hook session-start` in `$CODEX_HOME/hooks.json`, trusted in
`config.toml` by the installer). The same hook rebinds the session after every
`/clear`, so the next `cs <name>` resumes the conversation you were in.
Exiting instead and answering `r` at the next launch starts a fresh thread from
the handoff and runs its first turn on its own. `$switch` does the same across
engines (see [Switching engines](#switching-engines)).

Taking the handoff, by `/clear`, `r` or a switch's `--resume`, marks it
`consumed` and then drops the marker, the way the SessionStart hook does under
Claude. When the handoff store refuses that write (a folder cs cannot write, or
a store that links out of the session), the marker stays armed and the
conversation still starts from the handoff. The conversation is told why, with
the first line the store wrote, and so are you: in the hook's message after
`/clear`, or on the terminal before the CLI starts. The next start or `/clear`
loads the same handoff again and retries the write. With the marker armed, the
automatic `/clear` counts down again at the end of each turn. To stop the
retry, set the handoff's `status:` to `consumed` and remove
`.cs/local/pending-handoff`.

You need not type the `/clear` either. As the `cs` mod counts down under
Claude, cs does it under Codex: when a turn ends with a handoff armed, the Stop
hook (`cs -codex-hook stop`) shows a line saying what happens in 20 seconds, and
a watcher cs runs beside the Codex CLI then types `/clear` and `go` into the
terminal, at typing speed, since Codex takes a faster burst for a paste. With a
switch pending it types `/quit`, and cs reopens the session under the other
engine. The watcher looks for the switch when the count ends, as the mod does
at zero, so a switch recorded or cancelled (`cs -switch cancel`) during the
count is the one that counts. The line names what the switch would start: the
engine, the model, the effort when one was asked for, and the approval. In a
run launched with `--native-approval` a switch gets no count, whatever approval
it names: nobody is at the keys when the count ends, and the agent can arm a
switch itself (one that loosens approval, with `cs -switch --approve-for-me`,
among them), rewrite it after the watcher has read it, or write the target's
settings into the session (a `.claude/settings.local.json` the relaunch would
load). So the line names the switch, says the exit is yours, and cs types
nothing; only `/clear`, which keeps this Codex, is typed for you there. A message you send first stops the count (the UserPromptSubmit hook,
`cs -codex-hook user-prompt-submit`) and keeps the conversation; the count starts
again when that turn ends. An approval Codex asks for stops it too (the
PermissionRequest hook, `cs -codex-hook permission-request`), so the keys never
land in an approval prompt: a turn can go on past its Stop hook when another
tool's Stop hook asks Codex to continue. That hook makes no approval decision;
it answers `{}`, which Codex reads as none, and the prompt is yours as before. Only the conversation the launch bound counts down,
and only while its run still holds the session: after a forced second launch
(`--force`) takes it over, the first run's count types nothing.
`CS_ROTATE_FORCE_CTX=off` (or `0`) at launch turns it off, as under Claude, and
`CS_CODEX_CLEAR_GRACE` sets the seconds (default 20; `0` turns it off too).
The watcher runs only when cs has a terminal that takes simulated input: it
types through the terminal's simulated-input call (TIOCSTI), and the launch
asks once, before Codex starts, whether that call will work. Where it will not
(no `python3`, or Linux with `dev.tty.legacy_tiocsti=0` for a user who is not
root), the launch prints one line saying why, no watcher runs, and no turn
shows a count: the line at the end of a turn appears only while this run's
watcher is alive to type. The deadline it acts on lives in
a directory private to the run, `codex-runs/<run id>` under cs's cache (`CS_CACHE_DIR`, by default
`~/.cache/cs`), made mode 700 before Codex starts and removed when the run ends.
It is kept out of the session because Codex's workspace sandbox can write
anywhere there, and in `/tmp` and `$TMPDIR`: a deadline the agent could write
would let it have the watcher type into an approval prompt. The same goes for
any root your Codex config adds (`sandbox_workspace_write.writable_roots`):
the launch reads it from `/etc/codex`, `$CODEX_HOME/config.toml` and every
`.codex/config.toml` from the session upward, in any table, profiles included.
Roots a managed device profile adds are not in a file cs can read, so keep
`CS_CACHE_DIR` out of those yourself. When the cache lies under any of these
roots, or the directory cannot be made, the launch says the automatic `/clear`
is off for that run and the `/clear` stays yours. A probe
that declines is logged in `session.log` with its cause, and so are keys the
terminal refuses later all the same, with the error it gave; the `/clear` then
stays yours.
A retire `/finish` stages while a feature's conversation still holds its
worktree lives in the same cache for the same reason
(`retire-staged/<base id>/<task>`): the base's Stop hook runs it, and a stage
an agent could write would let it have that hook delete a branch nothing
integrated. For a stage the roots are read for both the base and the
feature, whose agent is the one the stage is kept from: the same files, and
every `.codex/config.toml` from either session upward. A cache under any of
these roots keeps no stage, so `/finish` asks you to close the feature
conversation and run it again.
The watcher cannot see the screen: text you have typed into the composer and
not sent when the count ends is sent, with `/clear` appended, to the
conversation you are in, so send or clear a draft first; the line at the end of
the turn says so. A prompt you send while cs types stops the rest of its keys:
cs keeps a marker in the run's directory while it types, the UserPromptSubmit
hook removes it, and cs checks it before each key, before Enter and before
`go`, so `go` never lands in the turn your prompt started; an approval prompt
removes it the same way. `session.log` then says a prompt went in while cs was
typing.
cs also stops typing once Codex has exited: the launch records the CLI's pid
in the run's directory, and the typist checks it before each key. When Codex
exits while cs's keys may still wait unread in the terminal (from cs's first
key until half a second after its last Enter), the launch flushes the
terminal's input as it ends, so those keys do not run in your shell. That
flush also drops anything you typed in that sub-second window; at any other
exit, input you typed ahead is left alone.

The Claude hooks and
function-hook mods do not run in Codex. Successful Codex patches automatically
save a recovery copy through the same shadow-ref consumer as Claude edits.
The installer registers `cs -codex-hook files-changed` for PostToolUse and
deploys its recovery files to `$CODEX_HOME/hooks/cs/`; see
[Completed file changes and recovery copies](engine-adapters.md#completed-file-changes-and-recovery-copies).
Codex does not yet participate in Claude's automatic recovery prompt, usage
reporting (`cs -usage`), observed runtime status, or native
terminal controls. CS session-management commands continue to manage the shared
workspace, including manual `cs -status` updates through `CS_SESSION_*`; native runtime observations remain Claude-specific for now.

Codex's own bar under the prompt does show the context and the 5-hour and
weekly limits: the installer sets `[tui] status_line` in
`$CODEX_HOME/config.toml` where it has none, and `cs -statusline
enable|disable` adds or removes it. A status line you set yourself stays. See
[Status line: Codex](statusline.md#codex).

The shared internal dispatch, binding, and context interfaces are described in
[Engine adapters](engine-adapters.md).

Before opening a conversation, press `e` in the session picker to choose
engine, model, effort and approval policy. The same launch choices are accepted
as `cs <name> --engine codex --model <model> --effort <level>` and by
`cs -switch codex --model <model> --effort <level>`. Blank picker fields keep
native defaults. Model names and effort levels are validated by the native CLI.
Codex launches use `--approve-for-me` in a workspace-write sandbox by default;
`--native-approval` leaves approval policy to Codex configuration.


## Session memory

Codex startup and resume refresh `.cs/memory/MEMORY.md` as reference context.
The SessionStart hook refreshes it again after `/clear`, including a rotation.
The shared reader includes at most 196 lines and 24,400 bytes, preserves UTF-8,
labels truncation and skips missing or unreadable indexes.


## Unread mail

The owning thread's UserPromptSubmit hook shows the same bounded unread-mail
preview as Claude: up to five messages with sender, kind and a 160-character
body preview. Mail is labeled as text from other sessions. It remains unread
until `cs -msg` consumes it. This is next-prompt delivery; it does not wake an
idle Codex session. As under
Claude, the hook shows no mail while git tracks a file in the session's control
directory, even one a pull brought after launch.


## Feature briefs and task queues

`cs -spawn <name> --brief <file>` inherits the spawning run's engine. An explicit
`--engine claude|codex` wins; outside a run the target's preference/default applies.
Both adapters use the same seed consent and brief delivery code. Codex starts
its first turn with a prompt for the brief, the queue, or both.

`cs -spawn <name> --engine codex --task "first" --task "second"` queues the
tasks, arms the drain, and submits its kickoff. To use an existing session,
add tasks with `cs <name> -queue add "task"` and arm them with
`cs <name> -queue start`. The next completed Codex response starts the drain.
If Codex is idle, send one prompt to get it started. Use `cs -queue log` to
see completed tasks and breaker trips. The default runs tasks in the
conversation. `cs -queue start subagents` delegates each task to a native
subagent. Workflow mode is available under Claude.

Codex counts recognizable shell and patch failures from the current task's
rollout records. A task that reports `cs-task-failed` or trips the failure
breaker stays queued. Context and five-hour quota trips record the completed
task and park the remainder. If either usage reading is unavailable, the drain
can finish up to `CS_CODEX_QUEUE_MAX_TASKS` tasks before parking, with a
default of 10. If Codex cannot confirm a task handoff and final response from
its active history, the task stays queued for inspection and re-arming.
`cs -queue start` refuses while the drain runs; after an interrupted turn the
next Stop parks the queue, and `cs -queue start` re-arms it then.
An encrypted session drains when cs's permissions profile keeps the vault
Codex home read-only: under automatic approval, or under native approval with
the workspace sandbox. Under native approval with the read-only sandbox or full
access, which get no profile, or with a writable root over Codex's history, the
queue parks with a notice.

A native approval prompt waits for your answer. The first such prompt during
a spawned drain sends the spawner a notice. An armed rotation takes priority
before dispatching the next task, and the fresh conversation resumes the
queue after rebind. When nothing will type /clear (the automatic /clear is
off or there is no watcher), the run waits for you to type /clear and then
send go, and the spawner gets one notice. A switch held under native approval
waits instead until you take it with /quit or drop it with cs -switch cancel,
with the same one notice.

The queue needs Codex 0.167.0 or later: cs confirms each task by the hook
provenance Codex records on the continuation prompt, measured on
0.167.0-alpha.3.2 and 0.169.0-alpha.11.1. Codex 0.158 and 0.162 do not record
it, so `cs -spawn --task` refuses under them and an armed queue parks with a
notice.

Codex retains a durable kickoff receipt in `.cs/local/spawn-kick.json` until
native thread history confirms a turn started. A launch that fails before a turn
retries the kickoff on the next open. A started turn spends it, including when
the CLI later fails or the launcher is interrupted. If history cannot be read,
cs preserves the receipt and refuses automatic replay until history is available;
the open stops before it binds a thread or spends a rotation handoff.
Rotation and finish prompts take precedence and leave staged briefs pending. A
receipt whose kickoff ran no turn returns to pending before such a prompt runs,
so that prompt's turn does not spend the brief.
