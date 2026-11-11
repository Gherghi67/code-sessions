# Antigravity CLI sessions

cs can launch a named session with Google's Antigravity CLI (`agy`) while
keeping the session's files, notes, and workspace under the same `.cs/`
directory that Claude Code and Codex use. cs starts `agy` in the session with
the session's context handed over, and a hook records the conversation so a
reopen resumes exactly that one and `agy`'s edits reach recovery. The same
plugin carries cs's skills, as `/cs:<name>`. cs's status line
and mail do not reach Antigravity yet. Engine switching uses `/cs:switch <target>`. Rotation uses an exit and a fresh managed launch.

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
writes there is its own plugin, with the hook and the skills (see below).

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
- `skills/`, holding cs's skills: the same files `~/.claude/skills/` and
  `$CODEX_HOME/skills/` get (see [Skills](#skills)).

The folder is cs's whole. An install rewrites both files; it never merges into
them. A folder of that name is cs's when its `hooks.json` is cs's, or, with no
`hooks.json`, when it holds only what an install or removal of cs leaves
there: cs's own `plugin.json`, a `scripts/` and a `skills/` folder, and the
`.hooks.json.XXXXXX` and `.plugin.json.XXXXXX` temporary files of an install
cut short, each empty or holding what cs writes. Any other folder of that name
(a `hooks.json` or `plugin.json` that is not cs's, or anything else at its top
level), or one where the folder, `hooks.json` or `scripts/` is a symbolic
link, is kept as it is with a warning, and neither the hook nor the skills are
installed. Without
`jq`, which tells cs's files from yours, every folder of that name is kept.
While cs's `hooks.json` is there, `skills/` does not decide whose the folder
is. cs deploys its skills only into a `skills/` that is a folder of the
plugin's own, and its recovery scripts only into such a `scripts/`: a file of
either name, or a link at `skills/`, is kept and named, and the hook is still
installed and removed. Inside `skills/`, a skill folder that is a link and a
file where a skill folder belongs are kept and named, a skill of yours under
another name is never touched, and cs deploys the rest. With no `hooks.json`,
a `skills/` that is a link or a file keeps the folder yours, as `scripts/`
does.
`cs -uninstall` removes only the files cs wrote: a script or skill file you
changed stays and is named, a skill of yours stays, and the next install
takes the folder back. The uninstall also removes cs's `plugin.json`, and
`agy` loads no folder without one (`agy plugin list`, 1.4.12), so a skill you
left in cs's plugin stays on disk but no longer reaches `agy`. Keep your own
skills in `~/.gemini/config/skills/`, not in cs's plugin. `cs -doctor` under
Antigravity reports whether the hook is
installed, names a cs that is there, has its recovery consumer
(`scripts/autosave-commits.sh`), and is not switched off in
`~/.gemini/config/config.json` (`agy plugin enable cs` turns it back on); for
a folder holding only what cs left, or a hook without its recovery consumer,
it says to run `setup.sh` again. A launch whose hook lacks the recovery
consumer says that edits are not autosaved. Run from the checkout cs was
installed from, `cs -doctor` also compares the plugin's skill copies with the
source, as it compares Codex's, wherever an install would write them (`agy`
on `PATH` or its own folder present).

A plugin was picked over a workspace `<session>/.agents/hooks.json` because it
is written once at install, outside the folder the agent writes. It needs no
git exclude, never meets a `.agents/hooks.json` of the project's, and serves
every session and feature worktree. `agy` runs it for every `agy` run on the
machine. Outside a cs launch of an Antigravity session (no
`CS_RUN_ENGINE=antigravity`), the hook prints `{}` and exits. That costs about
50 ms per model call and tool call.

Every hook prints `{}`, which decides nothing, and exits 0, so it never blocks
or fails a turn. It acts only for the run that holds the session's lease.

## Skills

The installer copies cs's skills into the plugin's `skills/` folder: the same
`SKILL.md` files and helper scripts Claude and Codex get, never a separate
Antigravity copy of their text. `agy` names a plugin's skills after the
plugin, so they are `/cs:checkpoint`, `/cs:wrap`, `/cs:sweep` and so on, in
the `/` menu and in the list the model reads.

| Skill | Under Antigravity |
| --- | --- |
| `checkpoint`, `summary`, `sweep`, `wrap`, `store-secret`, `prose-hygiene`, `write-as-me` | Need no capability Antigravity lacks, and run as under the other engines. `write-as-me` still learns from Claude Code transcripts only. |
| `rotate` | Writes and arms the shared handoff, then asks you to `/exit` and reopen with `cs <name> --from-handoff`. |
| `feature` | Spawns the feature with its brief ([Spawn briefs](#spawn-briefs)). Its result mail is not shown inside `agy`, so read it with `cs -msg`; `/cs:finish <feature>` lands it ([Finishing a feature](#finishing-a-feature)). |
| `finish`, `switch` | Run only when you type them. `switch` carries a handoff to Claude or Codex through a managed exit. `finish` lands and retires a feature ([Finishing a feature](#finishing-a-feature)). Outside a cs session, `switch` stops for want of a session, and `finish` stops when it cannot tell which folder it was loaded from, since `cs -engine skill-dir` needs a session too. |

- **Explicit-only skills.** `finish` and `switch` carry
  `disable-model-invocation: true`, the key Claude Code reads. `agy` reads it
  too and lists them with `model_invocable: false`, so the model never starts
  them on its own judgment. Codex ignores the key and needs
  `agents/openai.yaml` beside the skill; `agy` needs nothing extra.
- **Arguments.** `agy` substitutes no arguments placeholder: it hands the
  model the skill's text with your message. The skills read their arguments
  from that message, as they do under Codex (`/cs:checkpoint before the
  refactor`).
- **Why the plugin.** The global folder `agy` reads skills from,
  `~/.gemini/config/skills/`, is yours. cs already owns its plugin folder, and
  install, uninstall and doctor already handle it, so nothing cs writes can
  meet a skill of yours: your own `~/.gemini/config/skills/rotate/` stays
  yours and stays `/rotate`. The cost is the `cs:` prefix. `agy plugin
  disable cs` switches the whole plugin off in
  `~/.gemini/config/config.json`, and `agy plugin list` then shows it
  `enabled: false` with its skills still named. Whether the model still
  sees a disabled plugin's skills was not checked.
- `agy` keeps an empty `~/.gemini/antigravity-cli/plugin_data/cs/` for the
  plugin. That folder is `agy`'s, and cs leaves it alone.

This was checked against `agy` 1.4.11 on 2026-11-02, with no model call.
`agy plugin validate --strict --json` counts all 11 skills in cs's plugin and
reports nothing but its note that the plugin has no logo. One
`agy -p "/skills" --output-format json` run, which `agy` answers locally,
read a copy of the plugin in a scratch workspace (`.agents/plugins/cs/`) and
listed the skills as `cs:<name>`, with `cs:finish` and `cs:switch`
`model_invocable: false` and the others `true`. That `agy`
substitutes no placeholder comes from its binary: it holds no `$ARGUMENTS`
string, and it wraps an invoked skill's text in a `<SKILL>` block. No model
turn checked it, and no skill has yet run in a live `agy` turn. The test
suite runs the validate check whenever `agy` is on `PATH`.

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
| `cs <name>` in the spawn's own window, its seed staged | `--conversation <id>` when one is bound, then `--prompt-interactive <kickoff>`; asks nothing ([Spawn briefs](#spawn-briefs)) |
| `cs <name> --resume` | `--conversation <id>`; requires a bound conversation or a recoverable handoff receipt |
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

## Rotation

Run `/cs:rotate <purpose>` inside the session. The shared skill writes and
arms a lineage-stamped handoff. Then run `/exit` and reopen from your shell:

```bash
cs investigate --from-handoff
```

The saved engine remains Antigravity. You can also reopen normally and answer
`r` at the pending-handoff prompt. `--from-handoff` takes the armed handoff,
or the lexicographically last unconsumed handoff when none is armed, using
the same manager selection as Claude and Codex. A selection from another
checkout is identified in the prompt. With none pending, the launch refuses.

cs passes the shared rotation context through `agy --prompt-interactive`;
this starts the next step without an extra `go`. It never puts the handoff
into the always-on rule. On the first PreInvocation, cs binds that exact
conversation, marks the selected handoff `consumed` with `consumed_by`, clears
only its matching marker, and records a timeline event with reason `handoff`.
Repeated model calls and subagent conversations do not consume it again.
A later resume uses only `--conversation <id>`, with no handoff prompt.

Before starting agy, cs journals the launch intent in its private cache
(`launch-handoffs/<workspace identity>/antigravity/`). The first hook claims
the consumer ID separately before changing the handoff or binding. A
receipt directory must be owned by you, mode 700, and outside the session,
`/tmp`, `$TMPDIR` and configured sandbox writable roots. A receipt failure
is retried in the same conversation or repaired at the next
launch before any handoff can be offered again. Recovery refuses while state
is unwritable; repair it and reopen with `--resume` to avoid replaying work.
This also restores the first binding when its write failed: cs inspects
protected recovery state during the resume precheck and repairs it only after
acquiring the session's run lease.

A launch cancelled or failed without a consumer receipt leaves the handoff
pending and the previous binding intact, but is ambiguous: the missing hook
does not prove that no work ran. cs refuses another launch until you inspect
native agy history and repair the cached intent. Do not retry that attempt
with `--from-handoff`. Once the hook
has bound the conversation, its receipt stays spent even if agy later fails;
reopen with `--resume` to recover that conversation. A missing or disabled cs
plugin, an unavailable `--prompt-interactive` flag, or failure to create cs's
private cache directory refuses rotation and leaves the handoff pending.

`Y` or Enter at the picker resumes the previous conversation; `n` and
`--fresh` start a bare conversation. Those choices, explicit `--resume`, and
unattended ordinary opens disarm the marker while leaving the handoff pending.
`d` discards the selected handoff. Cancelling the picker leaves it armed.

Antigravity's native `/clear` (alias `/new`) resets context, and `/exit`
(alias `/quit`) closes the CLI; see the [native command reference](https://antigravity.google/docs/cli/reference).
cs uses the exit/reopen route because its current hook contract does not
identify a new main conversation separately from a subagent after the run
has bound once. In-place `/clear` rotation and automatic terminal input are
not implemented. Engine switching uses the managed exit described below.
The capabilities listed under [Capabilities and limits](#capabilities-and-limits) remain unavailable. Native approval settings and
explicit model/effort options follow the ordinary launch behavior.

The route and initial-prompt flag were checked against agy 1.4.12's help,
embedded exit documentation, and the native command reference. Local
regressions use fake agy with isolated state. A live model turn exercising
rotation has not been run.

## Switching engines

Invoke `/cs:switch claude` or `/cs:switch codex` inside Antigravity. The shared
skill writes and arms a rotation handoff, then runs `cs -switch <target>`.
Type `/exit`; cs reopens the session under that target in the same terminal.
Antigravity requires an explicit target. Claude and Codex still default to
each other; name `antigravity` to switch into it.

Switches start a fresh conversation by default. Add `--resume` to deliver the
handoff as the first new prompt in the target's recorded conversation. Without
a recorded UUID (including a legacy `latest` binding), cs starts fresh instead.
Explicit model, effort and approval options apply to the target launch;
Antigravity defaults to native approval and maps `--approve-for-me` to `--mode auto`.

Both fresh and resumed Antigravity targets require the enabled binding hook
and use the protected handoff journal described above. If agy received the
prompt but no consumer was confirmed, follow the recovery instruction with
`--engine antigravity --resume` and inspect native history when needed. Never
replay an ambiguous attempt with `--from-handoff`.

`cs -switch cancel` removes the switch and keeps the handoff armed. To continue
it under Antigravity, exit and run `cs <name> --engine antigravity --from-handoff`.
An unsuccessful source exit leaves the handoff armed without relaunching.
Codex and Antigravity targets refuse encrypted sessions.

## Capabilities and limits

`cs -engine` under Antigravity reports `launch`, `exact_resume`,
`startup_context`, `recovery_autosave`, `memory_index`, `rotation`, `engine_switch`,
`spawn_brief`, and `feature_finish`.
`cs -engine supports <capability>` exits 1 for everything else.
Skills that check before relying on a capability refuse cleanly
([Skills](#skills)).

| Not available under Antigravity yet | What cs does instead |
| --- | --- |
| The walk-away task queue (`cs -spawn --task`) | Refused before anything is staged, as under Codex; use `--brief`. A seed with tasks, staged for Claude, is neither taken nor offered at an Antigravity open: it stays staged, and the open goes on without it and names `cs <name> --engine claude`, which takes it. |
| Mail delivery (`mail_delivery`) | `cs -msg` still works from the shell. Nothing surfaces mail inside `agy`. |
| Encrypted sessions | Refused before the vault opens: `agy` keeps conversations in `~/.gemini/antigravity-cli`, outside the vault. |
| Crash-recovery prompt | Edits are snapshotted ([Recovery copies](#recovery-copies)), but nothing offers them back; restore by hand. |
| `--remote` | Claude only. |

A feature worktree (`cs <base>@<feature> --engine antigravity`) launches like
any other session, with its own rule and the shared exclude entry.

## Spawn briefs

`cs -spawn <name> --engine antigravity --brief <file>`, and the `feature`
skill under `agy`, stage the brief as under the other engines and open the
session in a tmux window. That window's open writes the brief to
`.cs/brief.md`, records the spawner in `.cs/local/spawned-by`, and starts
`agy` with the kickoff as its first prompt (`--prompt-interactive`): read the
brief, begin, and report back with `cs -msg <spawner> -k result "..."`. Where
the session already has a conversation, the window resumes it with the
kickoff and asks nothing, since nobody sits at it. That holds while a rotation
handoff is pending too, as Enter would: the window disarms the rotation marker
and leaves the handoff unconsumed, and the next attended open still offers it
with `r`. Resuming with the kickoff passes `--conversation <id>` and
`--prompt-interactive` together. agy 1.5.2's `--help` lists both and states
no conflict between them, but no live run has combined them yet.

The kickoff is sent at most once. The seed is spent before `agy` starts, so no
reopen sends it again. When a run ends before its first model call, cs cannot
tell whether `agy` did any work, as with a rotation that records no consumer.
It says so and leaves the brief in place for the agent to read at the next open.
Codex instead keeps a receipt and retries, because its thread history shows
whether a turn started.

The cs hook is that evidence, and the binding a reopen needs. Without a usable
one (missing, switched off in `~/.gemini/config/config.json`, or naming a cs
that cannot run), the brief still goes in, since cs spends the seed itself.
The open names the hook instead of doubting the kickoff, and says the next
open starts a new conversation that knows nothing of the spawn, with the brief
still in `.cs/brief.md`.

`agy` takes one first prompt. An open that carries a rotation handoff keeps
the seed staged for a later open, and so does an `agy` whose `--help` does not
list `--prompt-interactive`. A seed with tasks, staged for Claude, also stays
staged, unoffered, for `cs <name> --engine claude`. All three say so. An open
outside the spawn's window shows any other seed and asks before taking it, as
under Claude and Codex. Without a terminal, it leaves the seed staged.

## Finishing a feature

Type `/cs:finish <feature>` in the base's `agy`, or open the base with
`cs <base> --engine antigravity -finish <feature>` (the TUI's merge picker
arms the same). The finish skill runs as under the other engines: it
captures the feature's commit, merges it into the base, reports the PR's
state and retires the worktree.

- **The skill's folder.** `agy` hands a typed explicit-only skill its text but
  no path: on 1.5.2, a probe skill typed as `/csprobe:where` got "The user has
  explicitly invoked the (csprobe:where) skill ... Here are its contents:" and
  could not name its folder. So the skill asks cs: `cs -engine skill-dir finish`
  prints `~/.gemini/config/plugins/cs/skills/finish`, where the installer put
  it, and the skill runs `scripts/finish.sh` from there. It never searches the
  disk for another `finish.sh`.
- **`-finish`.** The open sends one first prompt (`--prompt-interactive`)
  that names the task and that `SKILL.md`, and asks `agy` to follow it as if
  you had typed `/cs:finish <feature>`. It is prose rather than a typed
  `/cs:finish`, since whether `agy` resolves a slash command in that prompt
  was not measured. The open refuses before anything changes when the plugin
  has no `finish` skill (run `setup.sh` again) or the `agy` on `PATH` does not
  list `--prompt-interactive`. A rotation handoff you choose with `r` takes
  the open instead, and cs prints the `-finish` command to run again. A staged
  spawn seed waits for a later open.
- **Approvals.** In Auto mode `agy` asks before a command that leaves its
  terminal sandbox or a destructive Git or file command, unless its own
  review clears it. `finish.sh` asks GitHub for the PR state, and the
  integrate and retire entries write the base's `.git` and remove the
  worktree beside it, so expect to approve them.
- **Retiring while the feature is open.** An Antigravity base has no Stop hook
  that runs a staged retire. While the feature's own conversation is live, the
  retire refuses and says so: close that conversation, then run
  `/cs:finish <feature>` in the base again.

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

These come later as separate changes: the status line, mail
delivery, in-place `/clear` rotation, and encrypted sessions.
