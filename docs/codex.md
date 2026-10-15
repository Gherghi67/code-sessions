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
startup/bootstrap helper. Codex CLI must be installed and authenticated for
the current user; CS does not configure Codex credentials.

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

A plain `--engine` reopens the other engine's own conversation, which has not
seen the work done since it last ran. To carry the work across, ask for
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

Codex does not open an [encrypted session](session-layout.md#encrypted-sessions)
yet: it keeps its conversations in `CODEX_HOME`, outside the vault. Every Codex
launch of one refuses before the vault's password is asked for, `--engine codex
--from-handoff` included, and names `cs <name> --engine claude`; a switch into
Codex refuses there as well.

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
transfer the other engine's conversation history or native memory. The
`switch` skill carries the work across in a rotation handoff; for a plain
`--engine` reopen, summarize important findings in the shared notes so both
conversations can pick them up.

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

`$rotate` works. It writes and arms a handoff, then tells you to run `/clear`
and send any message: Codex starts no turn by itself, and the handoff loads with
that first message through the SessionStart hook cs registers for Codex
(`cs -codex-hook session-start` in `$CODEX_HOME/hooks.json`, trusted in
`config.toml` by the installer). The same hook rebinds the session after every
`/clear`, so the next `cs <name>` resumes the conversation you were in.
Exiting instead and answering `r` at the next launch starts a fresh thread from
the handoff and runs its first turn on its own. `$switch` does the same across
engines (see [Switching engines](#switching-engines)).

You need not type the `/clear` either. As the `cs` mod counts down under
Claude, cs does it under Codex: when a turn ends with a handoff armed, the Stop
hook (`cs -codex-hook stop`) shows a line saying what happens in 20 seconds, and
a watcher cs runs beside the Codex CLI then types `/clear` and `go` into the
terminal, at typing speed, since Codex takes a faster burst for a paste. With a
switch pending it types `/quit`, and cs reopens the session under the other
engine. The watcher looks for the switch when the count ends, as the mod does
at zero, so a switch recorded or cancelled (`cs -switch cancel`) during the
count is the one that counts. The line names what the switch would start: the
engine, the model, the effort when one was asked for, and the approval. A
switch that would move a run launched with `--native-approval` to automatic
approval (`cs -switch --approve-for-me`, or a switch into Codex that names no
approval) gets no count: nobody is at the keys when the count ends, and the
agent can arm such a switch itself, so the line says the exit is yours and cs
types nothing. A message you send first stops the count (the UserPromptSubmit hook,
`cs -codex-hook user-prompt-submit`) and keeps the conversation; the count starts
again when that turn ends. Only the conversation the launch bound counts down,
and only while its run still holds the session: after a forced second launch
(`--force`) takes it over, the first run's count types nothing.
`CS_ROTATE_FORCE_CTX=off` (or `0`) at launch turns it off, as under Claude, and
`CS_CODEX_CLEAR_GRACE` sets the seconds (default 20; `0` turns it off too).
The watcher runs only when cs has a terminal. The deadline it acts on lives in
a directory private to the run, `codex-runs/<run id>` under cs's cache (`CS_CACHE_DIR`, by default
`~/.cache/cs`), made mode 700 before Codex starts and removed when the run ends.
It is kept out of the session because Codex's workspace sandbox can write
anywhere there, and in `/tmp` and `$TMPDIR`: a deadline the agent could write
would let it have the watcher type into an approval prompt. When the cache lies
under one of those, or the directory cannot be made, the launch says the
automatic `/clear` is off for that run and the `/clear` stays yours. It types through the terminal's simulated-input call
(TIOCSTI); where the terminal refuses it, as Linux does with
`dev.tty.legacy_tiocsti=0`, `session.log` says so and the `/clear` stays yours.
The watcher cannot see the screen: text you have typed into the composer and
not sent when the count ends is sent, with `/clear` appended, to the
conversation you are in, so send or clear a draft first; the line at the end of
the turn says so. A prompt you send while cs types stops the rest of its keys:
cs keeps a marker in the run's directory while it types, the UserPromptSubmit
hook removes it, and cs checks it before each key, before Enter and before
`go`, so `go` never lands in the turn your prompt started. `session.log` then
says a prompt went in while cs was typing.

The Claude hooks and
function-hook mods do not run in Codex. Successful Codex patches automatically
save a recovery copy through the same shadow-ref consumer as Claude edits.
The installer registers `cs -codex-hook files-changed` for PostToolUse and
deploys its recovery files to `$CODEX_HOME/hooks/cs/`; see
[Completed file changes and recovery copies](engine-adapters.md#completed-file-changes-and-recovery-copies).
Codex does not yet participate in Claude's automatic recovery prompt, queue delivery, usage
reporting (`cs -usage`), encrypted sessions, observed runtime status, or native
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
