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

1. **One band line, no fill, no chip, no caps.** The line is the
   rail's ticks on the left and, at the right end, only the words that
   need a keypress now, in this order of precedence: `/clear in Ns`
   (armed handoff) · `rotate` (context past the threshold) · `wrap` ·
   `queue N · start` · features (see 5). Each word is a Button as today,
   its chord beside it when keybindings.json binds one. Colour: the
   session colour on the thick tick and on a word that is pressable;
   the countdown keeps its amber/crit ramp; everything else dim. Two
   accents at most on a healthy line.
2. **The Handoff pane is removed.** Its countdown moves to the band; its
   next-step preview is not redrawn anywhere (the handoff file holds
   it, and the rotate band's press already reads it). `closeHandoffPane`,
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
   (`━` for the prompt being read, from the `onScreen` reports of
   `ui.render` UserMessage rows), `┄` for a prompt the engine refused to
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
6. **No model involvement.** The band reads files and cs output; it
   registers no tool and injects no prompt text.
7. **One module stays.** The band, the rail's transcript walk and the
   features reader live in `register.tsx` as sections, under the
   one-module-per-plugin rule (`project_mod_one_module_version_floor`);
   the tests in `mods/cs/test/` cover the walk and the width budget with
   fixture transcripts.

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
