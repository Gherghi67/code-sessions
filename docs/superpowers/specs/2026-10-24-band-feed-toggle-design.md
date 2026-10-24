# The session feed toggle and band alternatives

The contract at `mods/cs/.claude-plugin/types/claude-code/index.d.ts` is engine-written and gitignored, present in any installed checkout; citations use repository-relative paths and line numbers from 2.1.309.

Keep the current one-line band as the baseline:
`● ctrl+x  1 rotate  ·  2 wrap`, with the rail after the words.
The mark comes first, the shared chord prefix is dim and appears once, and
rotation keys appear only when due. The feed control adds one entry after
wrap. An armed handoff still offers the clear key alone.

## The control and its state

An ordered `BandEntry[]` carries words, chords, and presses. One pure builder
chooses the entries from the facts the hook gathers. Rendering and rail width
use the same list. Callbacks travel with their entries, avoiding a second
table that would have to match the first. Nineteen snapshots captured before
the refactor pin the existing drawing, including its colours and spacing.

The band discovers `/feed` through `$.command.list()`, matching both the
command name and its `cs-feed` provider. This reads availability without
queuing a status command or adding its output to the transcript. The contract
defines the list at line 3144[^commands] and its provider at line 1781[^provider].
`$.plugin` describes only the caller, and `engine.create.plugins` is a partial
list on reload, so neither supplies a reliable current inventory.
See line 2355[^identity] and line 4041[^plugin-list].

This discovery requires cs-feed to register `/feed` only while its global
install switch is on. Command presence alone cannot establish an
unrelated configuration boolean. The companion mod is outside this job, so
that registration rule still needs verification with it.

`cs.feedOn` is one host-owned session boolean, false when unset. Every render
and press reads that value. Registration never resets it. Host state survives
hot reloads and redraws subscribers after a write, per line 3466[^state].
A failed send rolls back only the optimistic write's version; a later reverse
report keeps its value, using the conditional write at line 3491[^state-set].
`/cs feed on|off` writes the same value without sending `/feed` again.

All outgoing communication stays in `tellFeed($, on)`. It runs `/feed on` or
`/feed off`. The contract queues programmatic commands until idle, even
though a registered immediate command can handle typed input during a turn.
See line 3152[^command-run] and line 1936[^immediate]. Mid-turn delivery
remains unverified. A shared-store channel would need a session address and
coordination with cs-feed, while session state would still own the value.

The check in `feed ✓` uses a coloured Text inside the Button. The engine
allows that child shape at line 1108[^button-text]. Separators remain beside
Buttons. The `press` testing API at line 16079[^test-press] is not a declared
runtime `$.ui.press` operation, so that transport needs engine support or a
separate measurement before use.

## Alternatives to the global install switch

The supplied cross-session probe[^cross-session] measured a global option
flip reloading other open sessions roughly one second later, with a notice
row in each transcript. The contract fixes options for each activation and
reloads when they change, at line 9770[^activation]. The ranking below favors
the current per-session, live-toggle design.

1. **Keep hooks registered and return early while the session is off.**
   This is the smallest implementation and keeps live toggling. It depends
   on session state at line 3466[^state], with a local copy refreshed by
   state changes if avoiding a read on every render matters. It still enters
   the worker for matching renders, so it breaks the strict zero-render-cost
   constraint. A worker-side early return keyed on `$.state` is this same
   option, not a way to remove the dispatch. Registration offers no removal
   operation at line 9790[^registration].

2. **Choose whether to load cs-feed when cs launches the session.**
   An unused session can have no feed render hooks. This moves complexity
   into the launcher and depends on a session-specific initial settings
   source. The initial plugin set comes from settings before hooks run,
   per line 3673[^load-settings]. It breaks activation by a live band press
   unless another mechanism reloads it. A shared settings-file edit
   repeats the original problem; a `--settings` file is outside the agreed
   product design. This remains an alternative, not part of the change.

3. **Let cs refuse cs-feed at registration until the session needs it.**
   Refusal admits none of that module's hooks, nouns, or tools, so an unused
   session pays no feed render dispatch. It depends on cs loading before
   cs-feed and on a later load or reload to reconsider admission. Those rules
   are explicit at line 4567[^admission]. It breaks an immediate first-use
   toggle without another activation mechanism, and adds ordering and
   refusal handling to cs.

4. **Overlay loading settings in a `settings.read` hook.**
   The contract permits rewriting keys that select plugins, but the answer
   applies from the next load. An unstable merge falls back to file values,
   per line 3673[^load-settings]. A stable session-local overlay could keep
   feed hooks out of unused sessions without writing user settings. It needs
   an experiment for the reload trigger, activation order, and stable merge.
   It breaks deterministic first-use activation until an experiment
   establishes those. The contract does not promise direct activation.

5. **Add engine-level session activation and removal.**
   This would meet both zero feed render work before use and a live toggle.
   It costs an upstream API change and depends on defined behavior for
   in-flight hooks, state, and command registration. The current plugin noun
   exposes identity only at line 2355[^identity], and registrations expose
   only an error handler at line 9790[^registration]. No current activation
   or unregister call implements this proposal, so it breaks compatibility
   with the present engine contract.

The supplied first probe[^first-probe] measured a pass-through render round
trip at about 1.8 ms. That is not a demonstrated incremental cost for every
extra plugin. The later memory probe[^memory-probe] found that feedoff
joined existing render dispatches, with no added worker hop and combined
latencies of 0.4–1.8 ms. Neither result proves a universal 1.8 ms floor.
Registered inert hooks still do work; only omitting them establishes zero
feed render dispatches. The current contract offers no demonstrated way to
combine that omission with immediate first-use activation from the band.

## Alternatives for more session toggles

Keep the direct third chord for this single toggle. The ranking below assumes
enough future controls to crowd the band's words or rail. These proposals
describe possible follow-up work.

1. **A `⋯ more` chord opens a pane of toggles.** It costs one compact band
   entry and one extra press to reach a toggle. It depends on a bound Button
   action and a pane renderer, supported at line 1125[^button-action] and
   line 2515[^pane]. A person-requested pane can open at any width. It keeps
   the band on one line but hides individual toggle state until opened.

2. **A `/cs` pane holds the toggles.** It costs no band columns and uses the
   existing immediate command registration, supported at line 3165[^command-register]
   and line 2515[^pane]. It depends on adding a command branch and pane
   renderer. It breaks direct discovery and the one-chord action, because
   the person must remember the command and open the pane first.

3. **A second row holds session controls.** It keeps every toggle visible
   with direct keyboard access. A column Box supports it at line 983[^box].
   It costs another row of transcript space and narrower terminals still
   need an overflow policy. It breaks the one-line look that the baseline
   preserves.

4. **A hover card reveals the toggles.** It saves resting columns but needs
   pre-rendered controls and a keyboard route. Hover runs locally on the
   surface, with no plugin callback, at line 939[^hover]. The band can clip
   absolute cards, per line 948[^card]. It breaks keyboard-only
   discovery if used alone and makes touch access and terminal placement
   extra work. Keep a visible keyboard control alongside the card.

## Integration and verification

`mods/cs/types.d.ts` declares the session value, and the plugin manifest names
that contract in `types`. An augmentation inside the hooks module alone does
not declare the key to the engine. The contract describes state declarations
at line 7978[^state-contract] and manifest types at line 91[^types-contract].

`lib/01-manifests.sh` includes the types file in the install payload and maps
`ctrl+x 3` to `strip:jump3`. `bash build.sh` generates `install.sh` and `bin/cs`
from that source. The validator expectations in `tests/test_mod_rotate.sh`
include command discovery, `tellFeed`, and the declared state reads and writes.

The requested checks pass with 249 Bun tests, 19 snapshots, and 7 shell
checks. A second build leaves the generated files unchanged. The delayed
failure test also fails when a write omits the rollback version guard, then
passes with the guard restored. The companion integration and actual terminal
painting remain untested. Installer and doctor fixtures outside this job's
scope still describe the earlier two-key band and need a separate update.

[^commands]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:3144`.
[^provider]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:1781`.
[^identity]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:2355`.
[^plugin-list]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:4041`.
[^state]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:3466`.
[^state-set]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:3491`.
[^command-run]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:3152`.
[^immediate]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:1936`.
[^button-text]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:1108`.
[^test-press]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:16079`.
[^activation]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:9770`.
[^registration]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:9790`.
[^load-settings]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:3673`.
[^admission]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:4567`.
[^button-action]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:1125`.
[^pane]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:2515`.
[^command-register]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:3165`.
[^box]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:983`.
[^hover]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:939`.
[^card]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:948`.
[^state-contract]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:7978`.
[^types-contract]: `mods/cs/.claude-plugin/types/claude-code/index.d.ts:91`.
[^first-probe]: Supplied `feed-arch/spike.md`, section Q3, cost with zero hooks versus one pass-through render hook.
[^cross-session]: Supplied `feed-arch/spike-xsession.md`, sections 1, 2, and 5, cross-session reloads and session state.
[^memory-probe]: Supplied `feed-arch/spike-mem.md`, the dispatch-count comparison with a fourth mod.
