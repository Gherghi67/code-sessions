# cs band: a prompt rail, one thin line, features on it — design

Date: 2026-10-23
Status: pending spec review
Decision trail: Alex, 2026-10-23: "I want cs to have the same feature"
(oikon48/prompt-rail's rail of prompts, after reading its source);
"redesign the mod pane that we currently have, it looks too heavy";
"integrate /feature /finish inside the mod somehow that it provides real
value"; ruling by AskUserQuestion: feature state goes on the band only,
no pane.

## Context and goal

The cs mod (`mods/cs/hooks/register.tsx`) draws two things today: the
rotate band, a filled capsule above the prompt (chip, Powerline caps, up
to three buttons with chord keys, dot separators, a countdown), and the
Handoff pane beside the transcript (the next step's preview and the
grace countdown). A second band line draws under a running `/finish`
gate. The capsule copies the status bar's idiom into the transcript's
space, where it reads as a sticky note under the prompt rather than part
of the chrome.

The goal: one dim line above the prompt that is quiet while nothing
needs a key, carries a rail of the conversation's prompts so the person
can see where they are and jump back, and shows the state of the
session's features where a key can act on it. No pane.

## Decisions

1. **One band line, no fill, no chip, no caps.** Alex picked the shape
   from nine rendered variants (2026-10-23, "B with G"): a left rule `▌`
   in the session colour anchors the line, as the launch banner's bar
   does; then the rail's ticks; then the words. Keys show their shared
   chord prefix once, dim (`ctrl+x`), and each Button its own key in the
   session colour with a short label: `1 rotate`, `2 wrap`, `queue N ·
   start`, armed `/clear in Ns` (amber/crit ramp) then `1 /clear now`,
   `finishing <task> · 2m10s`, features (see 5). With no chord bound the
   labels stand alone. Separator `  ·  ` dim. Two accents at most on a
   healthy line: the rule and the keys share the session colour. The
   measured line: `▌  ───━─────   ctrl+x  1 rotate  ·  2 wrap`.
2. **The Handoff pane is removed.** Its countdown moves to the band. Its
   next-step preview becomes one toast when the countdown starts (Alex,
   AskUserQuestion 2026-10-23: "Yes, as a toast when the countdown
   starts"): the handoff's next step, cut to the toast's length, shown
   once per arming; nothing persistent. `closeHandoffPane`,
   `PREVIEW_PANE`, the pane render hook and the `Pane` component go.
3. **The rail lists the live branch of the transcript.** The mod reads
   the session's `.jsonl` (path from `$.session.cwd()` and
   `$.session.id()`, the slug rule `lib/00-header.sh:41` already
   states; never from `classic.*`, which the security default skips in
   user mods), walks `parentUuid` back from the last row, and lists the
   person's prompts on that chain, so a `/rewind` drops its abandoned
   prompts and a resume keeps the earlier ones. The file is read again
   only when `$.fs.stat` says its size or mtime changed, after
   `turn.complete` and on `session.start`. One tick per prompt: `─`
   (`━` for the prompt being read: the topmost prompt still on screen by
   the `onScreen` reports of `ui.render` UserMessage rows, ties to the
   earliest), `┄` for a prompt the engine refused to
   scroll to. A press on a tick calls `$.ui.scroll({ to: { requestId },
   block: 'start' })`; a `{ deny }` is toasted once a session and marks
   the tick dotted. `/cs next`, `/cs prev`, `/cs first`, `/cs last`,
   `/cs N` move along the rail for keybindings. Hover text (the prompt's
   first line) is the Button's label on the desktop and absent in the
   terminal, where the ticks alone fit.
4. **The rail has a width budget.** Ticks take what the line leaves
   after the words; past that, the oldest prompts collapse into one
   `…N` run at the left. A conversation with one prompt draws no rail.
5. **Features on the band.** In a base session with feature worktrees,
   the band's last word is the features' state, read from
   `cs <base> -features --json` (a new output form of the existing row:
   task, state, ahead, behind, sha), refreshed on `turn.complete` and
   on a 30 s clock while the band is idle: `2 features · fix-auth ready`
   names the one feature a press can finish, and a press runs
   `/finish <task>`; `3 features · 1 staged` when none is ready names the
   most advanced state and a press runs `cs <base> -features` as a
   command so the list lands in the transcript. In a feature session the
   word is the feature's own state against its base: `ahead 3 · ready`
   with a press that runs `/finish`, or `behind 2`, `dirty`, `staged`,
   `finishing · gate 2m10s` (the second band line today) with no press.
   `ready` is `_feature_readiness`'s word, not the mod's judgment.

   As built (2026-10-23, slice 3), after reading the code this decision
   names:
   - The source is `cs <base> -features --porcelain`, which already prints
     the record (task, branch, ahead, merged, ff, wt_dirty, untracked,
     base_dirty, lock, state) and is tested in `tests/test_worktrees.sh`; no
     `--json` arm is added. It carries no `behind` count, so no `behind N`
     word is drawn.
   - Placement: the word sits on the left, right after the rule ("Left
     side", 2026-10-23), and before the key words when they are due too
     ("Both due", 2026-10-23: the rotate word shows from 40% context, so
     yielding to it hid the features word for most of a long
     conversation); the gap beside the rail names the prompt being read.
     While a `/finish` gate runs, or a survey holds the band, the features
     word is not drawn.
   - A feature session draws no features word (Alex, "Feature word",
     2026-10-23): `/finish` integrates only from the base's conversation
     (the skill's `role: feature` prints a handoff line and stops), and
     asked from a feature session cs reads the base conversation's own live
     lock as `locked`, so the word would mostly say `ahead N · locked`.
   - In a base: one feature ready names it and a press runs `/finish
     <task>`; two or more ready read `N features · K ready` and a press runs
     bare `/finish`, which lists the features and asks which; none ready
     reads `1 feature · <task> <state>` or `N features · none ready` with no
     press. `ready` with nothing ahead of the base reads `no commits`.
   - The base is the session's name; a name with `@` is a feature
     (`base@task`), since `validate_session_name` never admits `@`.
   - The record is read at an IO boundary: a line that is not ten fields,
     a non-integer `ahead`, or a state outside the eight `_feature_readiness`
     prints is logged once and draws no word.
6. **No model involvement.** The band reads files and cs output; it
   registers no tool and injects no prompt text.
7. **One module stays.** The band, the rail's transcript walk and the
   features reader live in `register.tsx` as sections, under the
   one-module-per-plugin rule (`project_mod_one_module_version_floor`);
   the tests in `mods/cs/test/` cover the walk and the width budget with
   fixture transcripts.

   As built after slice 3 (2026-10-23): the left rule `▌` is gone. Alex,
   on the live band: "I don't like the left bar and the fact that is
   empty", then "I don't like the left rail at all". The line starts with
   its first word two columns in; the read prompt and the bars stay
   right-aligned ("Empty left": "Keep it right-aligned").

   As built, the left's other words (2026-10-23). Alex: "we need to find
   what to use on the left when wrap rotate and feature are not present",
   then picked "Task in progress" ("Left word"), added "+ unread mail and
   queue if present", and for the queue picked "Both" ("Which queue"):
   - No task word. A `▸ <subject>` word naming the task in progress was
     built and merged (be8b4253), then dropped: on the live band Claude
     Code's own task list draws the same subject just above it. Alex
     ("Duplicated", 2026-10-23): "we already have the task display from
     claude", picked "Drop the task word". Rejected: draw it only while
     the list is collapsed.
   - Queue word: `▤ queue N`, dim, no press, while the cs queue holds
     tasks but the start key is not drawn (queue armed or draining, a turn
     running, or an armed handoff's clear key standing alone). The start
     key and the queue word never draw together.
   - Mail word: `mail N`, dim, no press, the `.json` files in the
     mailbox's `new/` that `cs -msg` has not read. A plain word, not `✉`:
     Dingbats are not proven to render in Alex's terminal font.
   - Order: features · keys · gate · queue · mail, `  ·  ` between,
     all counted in terminal cells (a wide character takes two) in the
     width the gap label and the rail are left.
   - Queue and mail draw under a running `/finish` gate and mid-turn
     (counts, nothing to press), never under a survey, and only in the
     lead conversation. Both are read when the band draws, as the start
     key's count already was; no clock of their own.

## Where the complexity moves

The pane's layout logic goes. What arrives: a transcript reader in the
mod (parentUuid walk, stat-gated), a `--json` arm on `-features` in
`lib/30-worktree.sh`, and a width budget for the ticks. The design lab's
"Inked" capsule preset (`docs/mods-design-lab.html`) stops describing
the shipped band and is updated or removed with the band.

## Slices

1. The thin band replacing the capsule: rotate, wrap, queue, countdown
   words only, the pane removed. Captured in tmux for Alex's reaction
   before anything else.
2. The rail: transcript walk, ticks, press to jump, `/cs` moves.
3. Features: `-features --json`, the band word, the press.

## Measured before slice 2 (2026-10-23, Claude Code 2.1.309, terminal)

A throwaway mod (scratchpad `scroll-probe/`, script `run.sh`) in an
isolated tmux with three prompts, the middle one answered by 60 lines:
`$.ui.scroll({ to: { requestId }, block: 'start' })` from a `command.run`
hook answered `{}` and the screen moved from the reply's tail to the
prompt's row at the top. Two facts the rail must honour:

- The composer's echo draws first as a `UserMessage` with `requestId`
  `placeholder`; the real id arrives on the next render. A jump to
  `placeholder` is denied (`nothing drawn under that requestId`). The
  rail keys rows by the transcript's uuid and ignores `placeholder`.
- `onScreen` was `null` on every first render of a row; the terminal
  reports it on later redraws (contract: `null` means the site is not
  laid out yet). The "prompt being read" reads the latest report per
  row: a `null` before any report leaves nothing, and a `null` after a
  report removes it, since that is the row drawn outside the viewport
  (measured in slice 2: under "a `null` leaves the last report
  standing", a prompt scrolled off kept `first: 0` and stayed thick).
