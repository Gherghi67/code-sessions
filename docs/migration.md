# code-sessions migration and compatibility

**code-sessions** keeps the fork's Claude and Codex features while using the
normal native configuration directories.

## Moving from the private engine profile

Run `sh setup.sh` from this checkout. Setup backs up the existing cs binaries,
managed integrations and configuration files under
`~/.local/share/code-sessions/backups/<timestamp>`, then installs this fork as
`cs`, `ccs` and `code-sessions`.

The installed integrations use `~/.claude` and `~/.codex`. Native credentials
and personal settings already there remain authoritative. Upstream
agents-sidebar works without the former profile-account patch.

Missing Claude conversation files, file history, Codex rollouts, prompt history
and Codex thread metadata are imported from the old engine profile. A
divergent existing file is preserved and reported. The old profile stays
available; imported rollout files share their inode where possible so an
already-running agent's appends remain visible after import.

Project directories, worktree paths, session secrets and encrypted vaults stay
in place. `ccs` continues using the old fork session store when it exists,
including its secrets namespace and tmux socket. `cs` uses the normal
`~/.claude-sessions` store. Both commands run this fork, with the same normal
Claude and Codex settings. On a fresh installation all commands use the
normal session store.

Restart running agents to adopt the new configuration. To inspect or repeat
the history import:

```bash
python3 scripts/shared-config.py
python3 scripts/shared-config.py --apply
```

The following older session-copy tools remain available for moving project
copies between the two session stores. They are not needed to share engine
configuration.

## Provider-specific preparation

Core creation, adoption, migration, and worktrees prepare the portable `.cs/`
workspace and then call the selected adapter's `prepare_workspace` operation.
Codex does not write `AGENTS.md`, Claude instructions/settings, or Claude memory
configuration, and does not allocate Claude UUID/color. Opening that workspace
with Claude prepares its own native integration. Existing Claude configuration
is preserved on Codex opens rather than removed. Claude's existing instruction
migration and resume behavior are retained behind its adapter.

```bash
ccs investigate --engine codex
ccs -adopt existing-project --engine codex
ccs existing-project@worker --engine codex
ccs investigate --engine claude
```

## Installation and updates

From this checkout:

```bash
CS_INSTALL_ENGINES=codex sh ./setup.sh          # core and Codex bootstrap helper
CS_INSTALL_ENGINES=claude sh ./setup.sh         # core and Claude integrations
CS_INSTALL_ENGINES=claude,codex sh ./setup.sh    # both (fresh-install default)
```

Setup remembers installed adapters in `~/.local/bin/.cs-install-engines`.
Selections add or refresh adapters; they do not uninstall existing adapters.
The fork updates from its checkout; `cs -update` refuses upstream releases
because they would replace the fork. Rerun `setup.sh` to install changes.
Tests use isolated homes and do not install globally.

## Older ags profiles

The automatic ags-to-private-profile rename belonged to the old isolated
installer. Preserve any remaining `~/.local/share/agent-sessions/home` before
moving its session data; current setup does not move or delete it.

## Copying a cs session into code-sessions

`cs -adopt` refuses a folder that already has `.cs/`, so a session the
original cs has cannot simply be adopted again. `scripts/cs-to-code-sessions.py`
gives code-sessions a copy of it instead, so `ccs <name>` opens it on the
conversations the original cs left off with. The two never share a folder.
`--session` names one session (repeatable); `--all` takes every one in
`~/.claude-sessions`, one after another, and ends with a line per session and
the count of problems. It prints what it would do; `--apply` does it:

```bash
scripts/cs-to-code-sessions.py --session wap            # the plan; nothing is written
scripts/cs-to-code-sessions.py --session wap --apply    # rerun later to bring over what cs did since
scripts/cs-to-code-sessions.py --all --apply            # every cs session; then ccs -list
```

It and `scripts/code-sessions-to-cs.py` need git 2.31 or later.

- The session's folder is copied whole into the profile's sessions root,
  whether the original adopted it (a link in `~/.claude-sessions`) or created
  it there (a folder of its own): its repository if it has one, `.cs/`,
  `node_modules`, ignored and untracked files. On APFS the copy is a clone,
  which costs no space until either side writes. From then on it is
  code-sessions's own.
- A session folder inside another session's folder (a project adopted inside
  another adopted project) is copied once, as its own session. The outer copy
  holds a link to the inner copy where the inner folder was, so the tree looks
  as it does in cs, and no sync of the outer copy ever touches that path. A
  run of the outer session alone leaves the inner one out too, and says so.
  When the inner session is not copied (encrypted, or a name code-sessions
  uses for another session), the path is left out with no link, and the run
  says why. If the outer copy already has a link or a folder there from an
  earlier run, it is kept as it is and named, and a kept link stays recorded.
  A folder the outer repository tracks files in (a subproject
  adopted on its own) comes with the outer copy as well, since git would show
  a link there as a deletion, and the outer copy's links and virtual
  environments that name a path in it name the outer copy's own folder; the
  inner session's copy is its own.
- If cs stops having the inner session, the outer copy keeps its link and
  leaves the path alone, and says so. If the inner folder becomes a session
  after the outer was copied, the folder the outer copy has there duplicates
  the inner copy: it is named as a problem until it is moved aside, and the
  next run puts the link in its place.
- Each feature worktree (`<name>@<task>`) is copied beside it as a linked
  worktree of the copy's repository, on the same branch, with its index,
  uncommitted changes and per-worktree refs. A link that points into the
  folder of a cs session that has a copy, made by this run or an earlier one,
  by an absolute path (a `node_modules` or `.env` shared with the project) is
  pointed at that session's copy instead, so nothing writes through it. A
  link into any other session's folder, one inside the session's own
  included, is left as it is and named as a problem, since the copy would
  write through it into cs; the run that copies that session puts it right.
- A Python virtual environment (a folder with `pyvenv.cfg`) names folders by
  absolute path in `pyvenv.cfg`, `bin/activate*`, each script's shebang and,
  for an editable install, its `.pth` file, finder module and
  `direct_url.json`. In the copy, each of those that names the folder of a
  cs session that has a copy names that copy instead, so the copy's `pip`
  installs into the copy and its Python imports the copy's source; one that
  names another session's folder keeps naming cs's until a run copies that
  session. A binary file is left as it is. The run, a dry run included,
  names each such environment once, with how many of its text files it
  rewrites.
- The original cs never reads the `engine:` its state names: it opens Claude
  on `claude_session_id`. A session whose state names another engine (left
  by trials of this fork) is copied with `engine: claude`, so `ccs <name>`
  opens the same Claude conversation as `cs <name>`. The run says so, and that
  `ccs <name> --engine codex` opens the session's Codex thread instead (and
  makes Codex its engine). From then on the engine is code-sessions's own:
  it is set only when the copy is first made, and a rerun never changes the
  copy's engine, so a Codex session you opened with ccs stays Codex.
- Each session's Claude conversations are copied from `~/.claude/projects` into
  the profile's, under the folder name of the copy's path, whole: subagents,
  workflows, tool results. Their `file-history`, `session-env` and task list
  come too, and the session's lines of `history.jsonl` (the prompt history),
  pointed at the copy, with the files of `~/.claude/paste-cache` those lines
  name by `contentHash` (new files only, counted in the output). A
  `paste-cache` that is there but cannot be read is a problem; a rerun brings
  the files once it can be read.
- Each Codex thread a session binds (`.cs/local/codex-thread-id`) comes too:
  its rollout from `~/.codex/sessions` into the profile's Codex home at the
  same place under `sessions/`, which is all Codex needs to resume the thread
  by id, and its name from `session_index.jsonl`. A rollout that grew in the
  original is brought over; one code-sessions went on with is kept, and one
  continued on both sides is reported once per change in the original.
- Conversations of the session's retired features and of its scratch folders
  belong to no session any more. They come too, as history; `--no-history`
  leaves them out.
- Trust and per-project settings in `~/.claude.json` and `~/.codex/config.toml`
  are copied into the profile's under the copy's paths, without overwriting
  what the profile has. While a code-sessions session runs, these two files are
  left and a rerun brings them.
- Secrets are copied from the original's store into the profile's, values on
  stdin: from the keychain's `cs:<session>:<name>` items to its
  `code-sessions:<session>:<name>` ones. Stdin reaches as far as
  `cs-secrets`: its keychain backend hands the value to
  `security add-generic-password -w`, so it is in that process's arguments
  while it runs.
- With `--all`, a folder in `~/.claude-sessions` that is no session (no
  `.cs/`) and the root's `.voice/` (the write-as-me corpus) come too, file by
  file: new files and files that only grew. A file that differs from the
  original's inside is kept as the profile has it, and named. `.usage/` (each
  install keeps its own usage cache), `.spawn/` (runtime) and `index.md` (cs
  writes it afresh) stay, named once.

Nothing outside the profile is written: `~/.claude-sessions`, the project and
its feature folders, `~/.claude`, `~/.claude.json`, `~/.codex` and the
original's keychain items are only read, and git runs there only to read. The
keychain gains only the profile's own `code-sessions:` items. The session protocol in
`CLAUDE.local.md` comes over as it is: both sides word it for cs. A session or
feature open in the original cs while the script runs is named: what it writes
afterwards comes over on a rerun.

A rerun brings over what the original cs changed since the last run, wherever
code-sessions left the same thing alone, and keeps what code-sessions changed:

- Branches: the original's are fetched into the copy as `refs/remotes/cs/*`. A
  branch code-sessions did not move since is moved to the original's commit,
  and one code-sessions moved too is fast-forwarded when it is strictly behind;
  otherwise code-sessions's is kept and the branch is reported. A branch new in
  the original comes with its reflog (see Reflogs below).
- The rest of the repository's metadata, as a fresh copy would have it. Each
  tag the original has and the copy lacks comes, unless the original had it
  at the last run too: code-sessions deleted it, and it stays deleted. An
  existing tag is never moved: one on both sides on different objects keeps
  code-sessions's and is reported once. For each remote both repositories
  configure with the same URL, its remote-tracking refs
  (`refs/remotes/<remote>/*`) are added; moved along where code-sessions left
  them where the last run had them, or where they are behind the original's;
  and deleted where the original pruned them and code-sessions left them
  alone, before any is added, as `git fetch --prune` prunes first (a pruned
  `foo` may hold the name a new `foo/bar` needs). One code-sessions fetched
  past the original's, moved elsewhere or deleted is kept and reported once,
  and `refs/remotes/<remote>/HEAD` follows the original's. A remote whose URL
  differs is code-sessions's own; the run says so once. A ref or tag git
  will not write, such as the original's new tag `rel/1.0` where
  code-sessions has a tag `rel`, is reported and tried again on the next run;
  the rest are written. The `branch.<name>` settings of a branch both have
  (its upstream) and the `remote.<name>` settings come where the copy has no
  such section; one the copy has is never changed, and one it removed stays
  removed. A `remote.<name>` section is carried whole, every key it holds
  (`url`, `fetch`, `pushurl`, `proxy`, `uploadpack` and `receivepack`
  included), so a command or proxy set there in cs is set in the copy. The
  dry run counts each kind and names the first ten.
- Reflogs: a branch or remote-tracking ref that ends the run on the original's
  commit takes the original's reflog, as a fresh copy has it, when the copy's
  holds nothing of its own: each of its lines one of the original's, in the
  same order from the first, or one a run of this script wrote. So a ref the
  run adds or moves along has the original's history, and so does one an
  earlier version of the script added or moved with only git's one line. One
  whose original reflog names a commit the copy lacks (amended or rebased
  away in the original, kept only by that reflog) keeps git's line instead,
  so `git fsck` finds nothing wrong in the copy. A link or a file in place
  of a folder of the copy's `.git/logs` is reported once and left as it is,
  and no reflog is written below it: git itself still writes its lines
  through such a link, the script never does.
- `FETCH_HEAD`: the script's fetches write none, so the copy's stays its own.
  One an earlier version's fetch of the original's branches wrote becomes the
  original's again, or is removed where the original's names a commit none of
  its refs leads to.
- A worktree's HEAD and index: taken from the original when the copy's did not
  change, staged blobs included. When both changed, git is left as the copy has
  it and only that worktree's `.cs/` is brought over until git agrees again
  (for example after a reset onto `refs/remotes/cs/<branch>` in the copy); the
  original's other changes stay pending meanwhile, not dropped. That is
  reported once per change on the original's side.
- Files: one the original changed is copied where the copy did not change it,
  and a file the original deleted is deleted in the copy. A file changed on
  both sides keeps the copy's and is reported once per change on the
  original's side. A file the copy changed stays the copy's until both sides
  hold the same content again, so a later change in the original is reported
  rather than copied over it. `.cs/local/state` is merged key by key.
- Features the original started since are copied, unless their branch is
  checked out in the copy already or their commit is on no branch the copy's
  repository has; one the original finished stays in the copy, and one whose
  copy code-sessions removed is not copied again.
- Conversations and Codex rollouts that grew in the original are brought
  over when the copy is an unchanged start of them. A history file Claude
  Code rewrites whole rather than appends to (a conversation's workflow
  state, `<conversation>/workflows/wf_*.json`, or a task) is brought over
  when the original rewrote it and the copy is still as a run of the script
  left it; one only the copy rewrote is kept, and said so. One continued or
  rewritten on both sides keeps the copy's and is reported once per change
  in the original.
- A link or a virtual environment's file that neither side changed is put
  right when it should now name another place, for example a session copied
  since.
- A secret whose value differs is reported and never overwritten, and its
  value is never shown.

Which files changed is told by their inode change time (ctime), which only the
kernel sets: the profile's `.cs-to-code-sessions/<name>/` keeps a mark per side,
taken before that side is read, the ctimes of the script's own writes, and the
paths both sides had at the last sync, so a deletion is told from an addition.
For git it keeps the original's branch tips, remote-tracking refs and tag
names at the last sync (the names in `tag-names.gz`), the settings sections it
looked at, the tags it kept as the copy has them and a digest of each remote
URL that differs, so a later run tells which side moved what and reports each
once; no URL is written there. A record from before these were kept brings
what the copy lacks, moves a remote-tracking ref only forward, and deletes
none: on that first run a remote-tracking ref, a branch's upstream, a remote
or a tag code-sessions deleted comes back, and a remote-tracking ref the
original pruned stays in the copy, unreported.
A file the copy changes while the script runs is left as it is. Should that
record lose its path list, the script stops rather than bring back files the
copy deleted.

For the Claude history and Codex rollouts, the record's `history.gz` keeps,
per file of the copy a run merged, its size, mtime and ctime right after the
run wrote it (a clone of the original's) or found it equal to the original's,
and the original file's when a run last read it. A copy whose ctime is
unchanged holds what the original once had, so the original's rewrite
replaces it; an original unchanged since tells a rewrite of the copy alone.
A copy an earlier version of the script made has no such entry: where the
original was rewritten, the copy is kept, reported once, then kept quietly until
the original changes it again. A session whose folder is gone keeps no record:
its history only comes when new or grown, as cs cannot open it to rewrite anything. Every change goes to `.cs-to-code-sessions/log.jsonl`, with up
to 1000 of the files kept on both sides. A record the ags-era script left as
`.cs-to-ags/` is renamed on the first run with `--apply`.

The script leaves these behind and names each one: an encrypted session, a
session whose folder is there but cannot be read (looking at its link's
target or its `.cs/` fails with anything but "no such file", or the link
points at a file), a project whose `.git` is not a folder, a feature folder
git does not list as a worktree or whose base is not copied, a name
code-sessions already uses for something else, and a name code-sessions is
still renaming (a record in the profile's `.rename-profile-session/` that is
not finished, or that cannot be read or understood: until then the old
session's transcripts, prompt history, settings and secrets may still be under
that name, a copy would merge into them, and the rename could no longer
finish). Each of these, and anything kept on both sides, is a problem and
makes the run exit 1. A session whose folder is gone (nothing is at its
link's target any more) is left too, but as a note: the original cs cannot
open it either. So is each of its features whose folder is gone too (an
adopted worktree's link, once the base is deleted); a feature folder still
there is a problem, to copy by hand or remove, then rerun. The gone
session's Claude conversations, their side files and its prompt history are
brought over as history, under the folder names and paths they had
(`--no-history` leaves them out). Its summary line reads
`not copied: its folder is gone (...)`, ending in one of:

- `history carried`: what it left is in the profile, brought by this run or
  an earlier one;
- `history would be carried`: a dry run, with some of it still to bring;
- `it left no history`: no conversation and no prompt history under its paths;
- `its history left out: --no-history`.

The first open in code-sessions runs one full migration, because the
original's stamp names no engine. The copy lives under the profile, so the
directory commands (`ccs .`, `-checkpoint`, `-narrative`) work inside it.

## Going back to cs

`scripts/code-sessions-to-cs.py` gives the original cs a copy of the profile's
work, so every code-sessions session opens with `cs <name>` and resumes the
same Claude conversation. It prints what it would do; `--apply` copies:

```bash
scripts/code-sessions-to-cs.py              # the plan; nothing is written
scripts/code-sessions-to-cs.py --apply
```

- Every session is copied whole into `~/.claude-sessions`, wherever the
  profile keeps it, a project code-sessions adopted included, git history and
  local state with it.
- A feature worktree (`<base>@<task>`) becomes a linked worktree of its base's
  copy, under the base's cs name, on the same branch with its index,
  uncommitted changes and per-worktree refs; the original stays a worktree of
  the original. `--session <base>@<task>` alone works once the base is in cs.
- Each session's Claude conversations and their file-history snapshots are
  copied from the profile into `~/.claude`, under the folder Claude Code gives
  the copy's path.
- Secrets go from the profile's keychain items (`code-sessions:<session>:<name>`)
  into the store `cs-secrets` reads, values on stdin (as far as `cs-secrets`;
  see above). One whose value differs is reported, never overwritten.
- A link into the profile by an absolute path is pointed at cs's copy of the
  session it leads into, whichever session that is, so the link a nested
  session's outer copy holds leads to cs's copy of the inner one. A link whose
  session has no cs copy is named as a problem, since cs would write through it
  into the profile; the run that copies that session puts it right. A Python
  virtual environment names cs's copy, as above.

The profile is only read, and git runs there only to read, so code-sessions
keeps working. When cs already has a session of that name, the code-sessions
one arrives as `<name>-ccs`; `--rename OLD=NEW` picks another name and
`--session NAME` copies one session. A rerun brings over what code-sessions
changed since, by the same rules as above with the sides swapped: what cs
changed in its copy is kept until both sides hold the same content again, and
something changed on both sides keeps cs's and is reported once per change in
code-sessions. A copy cs removed is not made again. The record of the last
sync lives in `~/.claude-sessions/.code-sessions-to-cs/`; the ags-era script's
`.ags-to-cs/` and `ags-origin` markers are renamed on the first run with
`--apply`. A copy made before this record existed is named and left; move it
aside and rerun.

The script leaves these behind and names each one: a session open in
code-sessions (close it, then rerun), an encrypted session (its vault needs its
password and links into the profile), a feature worktree whose base is not
copied, and Codex threads (cs has no Codex engine; resume one with
`CODEX_HOME=~/.local/share/code-sessions/home/.codex codex resume <id>`).
Anything left behind makes the run exit 1. Paths come from `HOME` and the
options, never from `CS_*` variables, which name the profile inside a
code-sessions session.

## Remaining compatibility decisions

- The fork keeps upstream's command, data root and `.cs/` metadata names, so
  upstream merges stay plain and nothing in an existing workspace or machine
  configuration needs migrating. Only the launchers carry the fork's name.
- Claude retains its quick failed-resume fallback and legacy transcript
  discovery; Codex refuses to replace a failed exact binding. Unifying resume,
  fresh, and handoff policy requires a lifecycle change with recoverable binding
  transitions, not a naming edit.
- Keep one interactive owner per workspace. Shared run leases, stale-hook
  protection, and normalized events remain to be extracted from Claude hooks.
- Codex's bootstrap uses the existing verified experimental app-server
  protocol for `0.158.0-alpha.2.1`. Supported runtime versions and a live event
  bridge require compatibility investigation before advertising automation.
- Claude owns native recovery, rotation, unattended queue/mail delivery,
  telemetry, and terminal mods. Codex can use shared storage and manual status;
  its runtime usage/state remains unavailable. Conversation listings and TUI
  observations still need engine-qualified views. Unknown Codex telemetry must
  not be interpreted as zero usage or an observed idle state.

See [Engine adapters](engine-adapters.md) for the implemented contract and
[Codex sessions](codex.md) for current runtime limitations.
