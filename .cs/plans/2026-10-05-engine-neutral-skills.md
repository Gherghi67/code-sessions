# Master plan: session-manager skills that every engine inherits

Created 2026-10-05. Status: Phases 0, 1 and 2 done 2026-10-05; rotation under Codex (Phase 3's hook
part + Phase 4's rotate item) done the same day on the user's request; all uncommitted. Approved 2026-10-05 ("start implementing the plan"): checkpoint,
Phase 0, Phase 1, then check in before Phase 2; the user's "continue" started Phase 2 (checkpoint
`2026-10-05-134644-pre-phase-2.md` first). Decisions so far: commands become skills (option 1).
Branch `codex/agent-sessions-rebrand` (ags only; stable cs untouched). The rebrand is committed (4d88090),
so the base is clean.

## Goal

Every skill and command ags ships (skills `feature`, `finish`, `prose-hygiene`, `rotate`, `store-secret`,
`write-as-me`; commands `checkpoint`, `summary`, `sweep`, `wrap`) is owned by the session manager and works
under Claude and Codex. Logic lives once in ags; an engine adapter only registers it in that engine's native
place and declares what it supports. Features an engine cannot host are declared unsupported, not faked.

## Ground truth (2026-10-05)

- docs/engine-adapters.md "Deferred boundaries": hooks and rotation are still Claude integrations. Codex
  adapter capabilities: `launch`, `exact_resume`, `startup_context`; Claude adds `feature_finish`.
- install.sh.in deploys skills, commands, hooks and mods only for Claude (`~/.claude/...`, lines 351-498)
  and never touches `CODEX_HOME`; a Codex session has none of the 10 items.
- Item bodies hard-code `~/.claude/...` paths (finish, write-as-me, summary, sweep, wrap). Under setup.sh's
  profile this already runs the STABLE install's copies, even for Claude (profile keeps the real HOME and
  exports CS_SKILLS_DIR/CS_COMMANDS_DIR/CS_HOOKS_DIR that no body uses).
- Codex 0.160 (binary schemas + `codex features list` on the profile): hooks stable/on; SessionStart input
  `source` startup|resume|clear|compact|fork, output `hookSpecificOutput.additionalContext`; plugins
  stable/on; manifests read from `.codex-plugin/`, `.claude-plugin/`, `.cursor-plugin/plugin.json`;
  plugins install via `codex plugin marketplace add` + `codex plugin add`; skills from
  `$CODEX_HOME/skills/` and `.agents/skills/`; `plugin_hooks` shows "removed"; hooks carry a
  `trusted_hash`. Codex's built-in skill-writing text defines SKILL.md frontmatter name, description,
  argument-hint, disable-model-invocation, user-invocable, allowed-tools, context/agent/model, and
  `$ARGUMENTS`/`$N` in the body. No commands or custom-prompts folder was found.
- Per-item coupling audit: see the 2026-10-05 narrative entry and the audit table below.

| Item | Class | Needs |
|---|---|---|
| checkpoint | wording | repackage as a skill |
| prose-hygiene | as-is | deploy for Codex; callers stop using a ~/.claude path |
| store-secret | wording | neutral file-tool wording, per-engine logging threat; stale ref name |
| wrap | shared code | neutral home for sweep/summary bodies; `.cs/local/wrapped` stays a Claude mod detail |
| checkpoint/summary/sweep/wrap | packaging | commands become skills (Claude still invokes `/name`) |
| summary | shared code | critic without Claude's Task tool; resume digest in shared context |
| sweep | shared code + hook | guard via an ags verb; Codex must load MEMORY.md at start; per-engine budget |
| feature | shared code + hook | spawn brief/kick in the shared launch; `-spawn` forwards the engine; mail delivery |
| finish | shared code + capability | helper via an ags verb; Codex `feature_finish` through startup context |
| rotate | shared code + hook | Codex SessionStart consumes the marker and rebinds; Codex launch `[Y/n/r/d]` |
| write-as-me | shared code | per-engine transcript reader (Codex rollout format unverified) |

Claude-only by nature (declared, not ported): the mod's `1` button, forced rotation and its 20 s
countdown, the FileChanged auto-wake after `/clear`, `watchPaths`.

## Phases

### Phase 0: verify Codex in a sandbox CODEX_HOME — DONE 2026-10-05

Run by a subagent against codex-cli 0.160.0 with a sandbox `CODEX_HOME`, no login, no repo or real-config
changes. Evidence and scripts: the scratchpad `phase0/` dir of conversation 253ee472 (rpc.py app-server
client, hooksum.py, rollouts, config snapshots). "Observed" = ran codex; otherwise read from strings/schemas.
- Plugins (observed): a plain Claude `.claude-plugin/marketplace.json` + `.claude-plugin/plugin.json`
  works unchanged. `codex plugin marketplace add <path>` then `codex plugin add <plugin>@<marketplace>`
  copies it to `$CODEX_HOME/plugins/cache/<mkt>/<plugin>/<version>/` (a copy: edits need a reinstall) and
  writes `[marketplaces.<mkt>]` + `[plugins."<plugin>@<mkt>"] enabled = true` to config.toml. Plugin skills
  list namespaced `<plugin>:<skill>`. Plugin hooks DO register (`plugin_hooks` "removed" means the flag is
  gone, not the feature) and run with `PLUGIN_ROOT` and `CLAUDE_PLUGIN_ROOT` set to the cache dir.
- Plain skills (observed): `$CODEX_HOME/skills/<name>/SKILL.md` lists un-namespaced (scope user). Claude
  frontmatter keys (`disable-model-invocation`, `model`, `argument-hint`, `allowed-tools`,
  `user-invocable`) are accepted and IGNORED: a `disable-model-invocation: true` skill stays model-visible.
  Codex's own switch is `agents/openai.yaml` `policy.allow_implicit_invocation: false` (strings).
  `$ARGUMENTS` substitution unverified (needs a model turn).
- Hooks (observed): loaded from `$CODEX_HOME/hooks.json` (Claude shape) and/or `[[hooks.<Event>]]` in
  config.toml (both at once warns). Project `.codex/hooks.json` loads only for a trusted project. Every
  hook starts `untrusted` and is skipped until trusted; editing makes it `modified`. Pre-trust without a
  prompt: `[hooks.state."<key>"] trusted_hash = "sha256:<hex>"` (or app-server `config/value/write`).
  Key `<abs source path>:<event_snake>:<group>:<handler>` (plugins: `<pluginId>:hooks/hooks.json:...`).
  Hash = sha256 of compact sorted-key JSON `{"event_name":"session_start","hooks":[{"async":false,
  "command":"...","timeout":600,"type":"command"}]}` with defaults filled (matcher/statusMessage when set);
  predicted a hash and the pre-trusted hook ran. Multi-handler groups untested. No `codex hooks` CLI.
- SessionStart (observed): fires on the first `turn/start` (not `thread/start`), before the model call.
  stdin: session_id, transcript_path, cwd, hook_event_name, model, permission_mode, source.
  `thread/start` `sessionStartSource:"clear"` gives `source:"clear"`; a `matcher:"clear"` hook ran only then.
- Rollouts (observed): `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<local time>-<thread uuid>.jsonl`, created
  on the first turn. Lines `{timestamp, ordinal, type, payload}`; user text = `response_item` message
  role user, `content[].type=="input_text"` (drop injected `<environment_context>`); assistant =
  role assistant `output_text` (+ `phase`). `session_meta` carries id, cwd, cli_version, source.
- `/clear` and `/new` both exist (strings); which `source` `/new` sends is unverified (likely startup).
- Still needs the user's `codex login` in the profile: the `/new` source and live `$ARGUMENTS`.

Consequences for later phases: Phase 2 can ship ONE Claude-format plugin to both engines, or plain
`$CODEX_HOME/skills` + `hooks.json` (no `ags:` namespace on skill names); either way ags must write the
hook trust hash itself. `disable-model-invocation` on finish needs an `agents/openai.yaml` twin for Codex.

### Phase 1: neutral foundation — DONE 2026-10-05 (uncommitted; gate result in the narrative)

What landed, and where it differs from the proposal:
- Helper paths are SKILL-RELATIVE, not ags verbs (decided while implementing): both engines tell the
  model where a skill was loaded from (Claude Code prints "Base directory for this skill:", seen in the
  2.1.289 binary; Codex lists the SKILL.md path), so `scripts/finish.sh`, `scripts/build-corpus.sh` and
  `<skill-dir>/scripts/memory-index-guard.sh` resolve per install with no new verbs. wrap reads
  `../sweep/SKILL.md` and `../summary/SKILL.md`; summary's critic gets `../prose-hygiene/SKILL.md`
  resolved to an absolute path. Fixes the ags profile running the stable install's copies.
  `${CLAUDE_SKILL_DIR}` exists in Claude Code but was avoided: Codex would see it literally.
- The memory guard moved `hooks/memory-index-guard.sh` -> `skills/sweep/scripts/` (a CS_SKILL_FILES
  entry), so it travels with the skill; the hooks-dir copy is in RETIRED_HOOKS.
- Commands are skills: `skills/{checkpoint,summary,sweep,wrap}/SKILL.md` with `name`/`description`;
  `commands/` is gone; `CS_COMMANDS` replaced by `RETIRED_COMMANDS` (install and uninstall delete only
  those four files); doctor's command drift scan removed. `$ARGUMENTS`, `model: opus` and
  `allowed-tools: Bash` kept. Model invocation stays ON for all four (checkpoint too: finish offers it).
- Engine variable: NO new `CS_SESSION_ENGINE`. `CS_RUN_ENGINE` is already exported into every native
  child by `cs_run_child`, so the shared code reads that.
- New verb `ags -engine` (lib/24-engine-adapters.sh `cmd_engine`): prints `engine:`, `conversation:`
  (`cs_binding_read` for that engine) and `capabilities:`; `ags -engine supports <cap>` exits 0 silently or
  prints "<cap> is not supported under <engine> in ags" and exits 1. Run engine first, else the saved one.
  Help line, completions (4 files) and tests in tests/test_engine_adapters.sh.
- Capabilities: Claude now declares `rotation spawn_brief memory_index mail_delivery`; Codex declares
  none of them. rotate checks `rotation` before writing anything; feature checks `spawn_brief` and says
  where mail surfaces (`mail_delivery`); sweep names `memory_index` for the byte budget. finish does NOT
  check `feature_finish`: that capability gates the launcher's `-finish` arming, and the ritual's verbs
  are engine-neutral (to confirm under Codex in Phase 4).
- Wording: `$CS_SESSION_NAME` instead of `$CLAUDE_SESSION_NAME`; shell/file-read/file-write tool
  instead of Bash/Read/Write tool names; AskUserQuestion marked "on Claude Code"; summary's critic uses
  "your harness's subagent tool" and, with none, skips the gate and says so (never self-judges);
  rotate step 1 reads `ags -engine`'s `conversation:`; rotate step 11 now says forcing is on by default
  at 80% and the 20 s countdown follows any armed handoff unless `CS_ROTATE_FORCE_CTX=off`/`0`;
  store-secret names `refs/worktree/cs/session/<id>` and the per-engine logging threat;
  build-corpus.sh cites lib/42-claude-state.sh.
- Tests: test_commands moved to the skill layout plus 4 new invariants (no `~/.claude/` path in any
  SKILL.md, former commands are skills, capability checks, countdown wording; each fails on HEAD's text);
  test_retired_skills gains 3 retired-command tests; test_install/test_doctor/test_docs follow the layout.
- Docs: CONTRIBUTING (Adding a Command folded into Adding a Skill), README, docs/engine-adapters.md
  (capability table, `ags -engine`), docs/hooks.md, docs/session-layout.md.
- Still unverified live: that Claude substitutes `$ARGUMENTS` in a SKILL.md and honours `model: opus`
  there (needs a real `/checkpoint <label>` in the redeployed profile).

### Phase 2: one payload, both adapters register it — DONE 2026-10-05 (uncommitted)

Decision: plain skill directories, not a plugin. Codex lists `$CODEX_HOME/skills/<name>/SKILL.md`
un-namespaced (same names as Claude's `/name`), the deploy reuses the installer's existing copy loop and
manifests, and the install needs no `codex` binary. A plugin would need `codex plugin marketplace add` +
`codex plugin add` at install time, would namespace every skill as `ags:<name>`, and is a cached copy
that a source edit only reaches after a reinstall. Hooks are not part of this phase: the first ags
hook for Codex comes with Phase 3, and its trust hash with it.

What landed:
- install.sh.in: new `_deploy_skills <dir>` (each SKILL.md + `CS_SKILL_FILES`, local copy or download;
  a download marks only `*/scripts/*` executable). Claude calls it for `~/.claude/skills` and then
  deploys the mods there as before; a new codex block calls it for `${CODEX_HOME:-$HOME/.codex}/skills`,
  creating a missing Codex home with mode 700. Mods stay Claude-only. RETIRED_SKILLS is swept only
  from the Claude dir (every entry predates the Codex deploy; comment in lib/01-manifests.sh).
- `skills/finish/agents/openai.yaml` (`policy: allow_implicit_invocation: false`), listed in
  `CS_SKILL_FILES`, so both engines get it and Claude ignores it.
- Uninstall (lib/85-adopt-uninstall.sh): with codex selected, removes the `CS_SKILLS` names from
  `${CODEX_HOME:-$HOME/.codex}/skills` and nothing else (Codex's `.system/` and user skills stay).
- Doctor drift (lib/60-doctor.sh): scans `skills/*/agents/*.yaml` too, and the Codex copies as
  "Codex skill drift" when codex is selected and the Codex home exists.
- setup.sh: makes the profile's `.codex` (700) BEFORE install.sh and passes
  `CODEX_HOME=$profile_home/.codex`, so a CODEX_HOME in the caller's shell cannot receive the profile's skills.
- Tests: test_commands `test_explicit_only_skills_ship_a_codex_policy` (fails with the yaml removed);
  test_install: Codex deploy byte-identical + 700 home + no mods, CODEX_HOME honoured, Claude-only
  leaves no `.codex`, uninstall removes only cs names (a user `merge` skill, `.system/`, a foreign skill
  survive), Codex-only installs ship the skills; `test_skill_files_exist_in_repo` now requires scripts
  executable and data files not; test_doctor Codex drift; test_setup profile `.codex/skills` and a
  caller CODEX_HOME left empty (stale `commands` copy removed from its staging); test_lib unsets CODEX_HOME.
- Docs: CONTRIBUTING (Codex twin rule, both skills dirs), README (Codex skills bullet),
  docs/engine-adapters.md (install paragraph, deferred boundaries), docs/codex.md (current boundary),
  docs/hooks.md (stale "commands" in the drift sentence).
- Verified against codex-cli 0.160.0 in a scratch CODEX_HOME (app-server, no login): `skills/list`
  shows all 10 as scope user, no errors. A `turn/start` rollout's injected skill list holds 9 of them
  and leaves out `finish`; with `agents/openai.yaml` moved away, `finish` is listed (control run).
- Gate: `tests/run_all.sh` 80/80 green (lint suite skipped: no shellcheck). Every new test was
  mutation-checked (narrative). `sh ./setup.sh --skip-tui-build` redeployed the profile: its
  `.codex/skills` and `.claude/skills` match `skills/` byte for byte, `.codex` is 700, the user's own
  `~/.codex/skills` is untouched. Profile doctor (engine forced to claude) reports "Codex skill drift"
  for an edited Codex copy and OK once restored.

Deferred:
- To Phase 3: every Codex hook ags writes needs its `trusted_hash` written in the same step, tested
  against Codex's `hooks/list` (memory project_codex_hooks_skip_until_trusted).
- To Phases 3/4: the Codex adapter's capability list grows only as each feature lands (rotation in
  Phase 3/4, spawn_brief and mail_delivery in Phase 4, memory_index if Codex ever loads the index at
  start). Until then `rotate` and `feature` refuse under Codex.
- To Phase 4: skill wording still says `/name` and `/clear`; Codex starts a skill with `$name`.
  Live-verified after the profile's `codex login` (see "Live Codex checks" below): `$ARGUMENTS` is
  never substituted.

Live Codex checks, 2026-10-05 (profile logged in; codex-cli 0.160.0, model GPT-6.1-Sol):
- `$name` in a message (exec and TUI) injects the whole SKILL.md, frontmatter included, as a user
  item `<skill><name>..</name><path>/abs/SKILL.md</path>...</skill>`; the absolute path is what makes
  the skill-relative helpers resolve. The TUI's `$` picker lists ags skills as `[Skill]`.
- `$ARGUMENTS`, `$ARGUMENTS[0]`, `$0` and `$1` stay literal in the injected text (probe skill via exec;
  `checkpoint` via the TUI). The model takes the arguments from the message itself: `$checkpoint
  phase2 probe label` ran `ags -checkpoint 'phase2 probe label'`. Codex's skill-writing text that
  mentions `$ARGUMENTS` does not describe this runtime.
- `$finish` loads finish on request although implicit selection is off.
- `ags wap-ags-test --engine codex` (fresh thread): `$checkpoint codex live test` saved
  `2026-10-05-143617-codex-live-test.md` with a timeline event; `$rotate` stopped at the capability
  check ("rotation is not supported under codex in ags", nothing written).
- The ags Codex launch runs `approval_policy: on-request`, `sandbox_policy: read-only` (turn_context),
  so every ags verb that writes asks for approval (the checkpoint did). Phase 4 decides whether the
  launch passes a sandbox mode or leaves it to the user's Codex config.
- First ags Codex launch in a worktree asks to trust the folder; the trust applies to the repository
  root and is saved in the profile's config.toml (the user's own ~/.codex already trusted it).
- Bug found and fixed (Phase 1 code): `cs_engine_supports` looped over a here-string; macOS
  /bin/bash 3.2 writes here-strings to a temp file, which the read-only sandbox refuses ("cannot
  create temp file for here document"), so the probe read no capabilities and answered "not
  supported" for every capability, a false negative for any engine that declares one. Now a
  whole-line `case` match; test `test_engine_verb_supports_answers_without_temp_files` runs the probe
  under `sandbox-exec` denying every write (denying only /tmp and /var/folders does not reproduce:
  bash falls back to /var/tmp) and failed before the fix. Replayed with `codex sandbox -P :read-only`.
- To Phase 5: doctor's drift scan (Codex copies included) runs only when the session's engine
  resolves to claude (`cmd_doctor` gates every Claude check on it, lib/60-doctor.sh ~773) and the
  Claude hooks `.version` stamp matches. So under a Codex session, or on a Codex-only install, nothing
  compares Codex's copies. Example: this checkout's own `.cs/local/state` says `engine: codex`, so
  `ags -doctor` here skips the scan.

### Rotation under Codex — DONE 2026-10-05 (uncommitted)

User, after `$rotate` refused under Codex: "we do not want this to refuse, we want rotate to also work
in ags with codex". Verified first with a temporary probe hook in the profile (removed after): see the
narrative. Facts the design rests on: SessionStart fires on a thread's first turn (`resume` for every
ags launch, `clear` for the first message after a TUI `/clear`, with the new thread id); the hook env
carries the CS_RUN_*/CS_SESSION_* variables; additionalContext reaches the model; systemMessage shows
as "↳ Hook · ..."; hooks run through a shell, unsandboxed; `codex resume <id> [PROMPT]` starts a turn.

What landed:
- `ags -codex-hook session-start` (hidden verb, lib/77-codex-hooks.sh). Every source: logs
  `Session started (source: X, ID: thread)` to .cs/local/session.log (rotate step 7 and the launch
  prompt's `_handoff_is_local` read it). Only `clear`, and only for the run that owns the lease:
  rebinds `.cs/local/codex-thread-id` to the new thread, records `rotated` (reason handoff|rebind) and
  `started` (source clear), consumes an armed handoff (`consumed_by: <thread>`), and returns the
  Codex rotation preamble (or a fresh-conversation notice) plus a systemMessage. Never fails a turn.
- Installer (lib/01-manifests.sh, shared with uninstall): `_codex_hooks_register` appends ags's
  SessionStart group to `$CODEX_HOME/hooks.json` after the user's (in place on reinstall) and writes
  `[hooks.state."<hooks.json>:session_start:<i>:0"] trusted_hash` in config.toml; the command is
  `<install dir>/ags -codex-hook session-start`, single-quoted when the path needs it.
  `_codex_hooks_unregister` removes ours and renumbers trust tables of later groups. A hooks.json that
  is not JSON is left alone with a warning.
- Codex launch (lib/76-codex.sh): the `[Y/n/r/d]` handoff prompt (shared `_pending_handoff_pick`,
  `_handoff_set_status`, `_rotation_armed_handoff` in lib/75-launch.sh; Claude's path now calls the
  first two). `r`, or an explicit `--fresh` with a rotation armed, appends the preamble to the new
  thread's context, stages the binding with reason handoff, consumes the handoff and starts
  `codex resume <id> -C <dir> "Continue from the pending rotation handoff: read ... first."`. y/n,
  unattended and explicit resume disarm the marker, as on Claude. Codex declares `rotation`.
- rotate skill: Codex form of steps 10/11 (send a message after `/clear`; final line
  "**Run `/clear` now, then send `go`** — this conversation is ready to rotate.").
- Tests: new tests/test_codex_hooks.sh (8); test_codex_launch +5 (r, n, d, explicit fresh, resume
  disarms); test_install +5 (known-answer trust hash from real Codex, registration + idempotent
  reinstall, user hooks/trust preserved and restored by uninstall, renumbering, unreadable hooks.json);
  test_engine_adapters (Codex declares rotation; probes use spawn_brief); test_commands (Codex closing
  line). 10 targeted mutants, all caught after one added test.
- Docs: README (engine table, install bullet), docs/engine-adapters.md (capability table, the hook,
  trust keying), docs/codex.md.
- Verified live on wap-ags-test (profile redeployed; hooks/list `trusted`): `$rotate` under Codex
  wrote, committed and armed a handoff whose parent is the Codex thread; `/clear` + `go` loaded it
  ("rotation received"), rebound 01a10bfb -> 01a10bfd, consumed it, timeline rotated/started; a
  second `$rotate`, `/quit`, relaunch showed the menu, `r` started the thread by itself ("relaunch
  received"), rebound 01a10bfd -> 01a10bff. Gate: tests/run_all.sh 81/81.

Not done (still Phase 3/5): the shared session-start core (Claude's hook keeps its own copy of the
marker resolution and consumption); Codex Stop/UserPromptSubmit (narrative reminder, mail digest);
no auto-start after a Codex `/clear` (Codex hooks cannot start a turn); doctor does not yet check the
Codex hook's registration and trust. Update 2026-10-15: Codex now registers Stop and UserPromptSubmit
(for the automatic /clear, see the section below), and cs itself types `/clear` and `go` after a rotation,
which starts the next turn; the narrative reminder and mail digest on those hooks are still not done.

### Phase 3: shared session-start core + Codex hooks
- Done above for SessionStart: the Codex hook and its trust hash (installer writes both; uninstall
  removes both; tested against `hooks/list`).
- Extract session-start.sh's engine-neutral work (marker consume, rotation context, resume digest,
  MEMORY.md inline, timeline event with the real engine) into a shared function.
- Codex SessionStart hook calls it; on `clear`, rebinds `.cs/local/codex-thread-id`.
- Decide Stop / UserPromptSubmit for Codex (narrative reminder, mail digest) per Phase 0.
- Trust-hash fact from the setup carry-over (2026-10-07, scripts/ags-carry-over.sh): Codex 0.160 caps a
  SessionEnd hook's timeout at 3 s (default 1) before hashing, so a SessionEnd hook's trusted_hash must be
  computed on the capped value. The carry-over trusts only definitions ~/.codex already trusts, hashed from
  the copy the profile holds; ags's own Stop/UserPromptSubmit/SessionEnd hooks need the same rule.

### Phase 4: per-item Codex behaviour
- rotate: done (see "Rotation under Codex").
- Deferred from Phase 2: skill wording for Codex (`$name` rather than `/name`; `/clear` stays a
  Codex command too). `$ARGUMENTS` stays literal under Codex (verified live): checkpoint and any skill
  taking arguments should also say to read them from the user's message.
- From the live checks: ags verbs a skill runs (`-checkpoint`, `-narrative`, `-msg`) need approval
  under the launch's read-only sandbox; decide the launch's sandbox mode. Any ags verb a skill calls
  as a read-only probe must not write, temp files included (the `cs_engine_supports` bug).
- rotate: Codex launch prompt offers `r` for an armed handoff; Codex wording (you type `/clear`).
- feature: brief/kick in the shared launch; `-spawn` passes `--engine`.
- finish: Codex `feature_finish` via startup context; neutral CLI refusal messages.
- summary: critic fallback when the engine has no subagent tool.
- sweep: Codex loads MEMORY.md at start; budget per engine.
- write-as-me: Codex transcript reader feeding the same corpus.

### Phase 5: docs and tests
- Deferred from Phase 2: doctor drift for Codex sessions and Codex-only installs (Claude-gated in
  `cmd_doctor`, and no hooks `.version` stamp to gate on).
- docs/engine-adapters.md (deferred boundaries), docs/codex.md, docs/hooks.md.
- Tests per item; Codex hook tests with stub hook-input JSON; installer tests for a Codex-only and a dual
  install; `bash tests/run_all.sh` green.

### Phase 6: `switch` — rotate, then relaunch under the other engine — DONE 2026-10-07 (uncommitted)

Decision (user, 2026-10-07): `rotate` stays as it is; `switch` acts like a rotate and also moves the
session to the other engine. No transcript transplant: a spike proved one works both ways (Claude JSONL
written by ags and resumed; Codex `thread/inject_items` with user/assistant items), but the user judged the
rotate handoff enough. Spike notes are in the narrative (2026-10-07).

- Skill `switch` (one payload, both adapters register it, like rotate): runs rotate's steps 1-9 unchanged
  (write the lineage-stamped handoff, arm `pending-handoff`), then records the target engine through a new
  ags verb (e.g. `ags -switch [claude|codex]`; no argument = the other engine). It never edits rotate's
  file; share rotate's steps by reference or by moving them into a helper both skills call.
- The verb validates the target (installed, adapter present, capability `rotation`), writes
  `.cs/local/pending-switch` (`.cs/private/` when encrypted), and prints how to exit this CLI.
- Launcher: `cs_run_child` already waits for the CLI (lib/16-lifecycle.sh:48). After it returns, a
  pending switch is consumed: the engine preference becomes the target, and ags relaunches
  `<name> --engine <target>` in the same terminal, starting a fresh conversation from the armed handoff
  without the resume prompt (the `r` path).
- Default (user, 2026-10-07): every switch starts a FRESH conversation from the newest handoff, so a round
  trip C1 -> H1 -> X1 -> H2 -> C2 carries the other engine's work forward; the old conversation (C1) stays
  on disk, untouched and not resumed. Option `--resume` (not the default): resume the target engine's last
  bound conversation and feed the newest handoff in as its first new message (the launcher's existing kick
  path), trading a heavier, possibly stale context for that conversation's full detail.
- Refusals: background agents or workflows still running (exiting would cut them off), target engine not
  installed, a switch already pending. A failed relaunch leaves the handoff armed and says how to reopen
  with either engine.
- Codex: the ags verb needs approval under the launch's read-only sandbox (Phase 4 item); the skill tells
  the user to exit with Codex's own quit, since `/clear` cannot change engines.
- Tests: verb (target choice, refusals, encrypted path), launcher relaunch after a pending switch (stub
  engines recording argv, handoff consumed once, preference updated, binding of the old engine kept), and
  the skill wording for both engines. Docs: getting-started "Resume and switch engines", codex.md.
- Ordering (user, 2026-10-07): `switch` first, then the cs->ags `wap` import; upstream v2026.10.6/10.7 still
  to merge (10.6 touches lib/75-launch.sh, which this phase edits).
- Pre-build findings (2026-10-07, read in source):
  - No non-interactive way into the `r` path exists on Claude: an explicit `--fresh` DISARMS the marker
    (lib/75-launch.sh:912, `_disarm_rotation_marker` then `_exec_fresh_rebind ... fresh`), while Codex's
    `--fresh` continues an armed rotation (lib/76-codex.sh:258; its comment claims Claude parity that is not
    there). The relaunch needs its own launch intent (e.g. `handoff`, flag `--from-handoff`) that both adapters
    take as `r`: Claude `_exec_fresh_rebind "$session_dir" handoff <basename> ...`, Codex `rotation_handoff=`.
    `cs_launch_session` validates intent `auto|resume|fresh` (lib/16-lifecycle.sh:103).
  - The `ags` mod (mods/cs/hooks/register.tsx `startCountdown`) runs `/clear` 20 s after ANY turn that ends
    with a handoff armed, while forced rotation is on (the default). A switch's armed handoff would be consumed
    by a same-engine `/clear`. With a switch pending the mod must run `/exit` instead (or stand down).
  - The relaunch point: `main` ends with `cs_launch_session` (lib/99-main.sh:537); after it returns the lock is
    released and `state engine` holds the engine just run. Re-entering `main` for the target (per-engine
    `migrate_session`, `check_dependencies`) needs the run's exported CS_RUN_*/CS_LEAD_PID/session context
    cleared first.
  - `.cs/local/pending-switch` should name the handoff basename; the launcher relaunches only while that
    handoff is still unconsumed, so a `/clear` typed instead of exiting drops the switch with a notice.
- What landed (workflow wf_d55c7bda-e2f, then the parent's fixes of the skill's five low review findings):
  - lib/78-switch.sh (new): `ags -switch [claude|codex] [--resume]`, `--check` (every refusal but the armed
    handoff; writes nothing), `cancel`; `<private>/pending-switch` = engine/mode/handoff/run key=value lines,
    listed in CS_PRIVATE_LOCAL_FILES. Extra refusals beyond the design: CS_RUN_ID must match the live
    run-lease; an encrypted session cannot switch into Codex (Codex reads handoffs and writes session.log in
    plaintext) and refuses up front when plaintext leftovers would block the reopen.
  - `--from-handoff` (intent `handoff`): both adapters take `r` without asking; refuses without a pending
    handoff and with --fresh/--resume/-finish; labels a handoff from another checkout. `--fresh` unchanged on
    both engines (only the misleading Codex comment was corrected).
  - Settle runs inside cs_launch_session after the CLI exits (lease held, vault mounted): consumes the record
    once when run= matches; no relaunch on a non-zero exit, a /clear-consumed handoff, a missing target CLI or
    a session that would not reopen (each prints both reopen commands and keeps the handoff armed). main then
    re-execs `<name> --engine <target> --from-handoff|--resume --switched-from <prev>` with the run's
    environment restored from a snapshot taken after flag parsing (CS_RUN_*, CS_LEAD_PID etc. cleared). A
    relaunch that fails before its CLI starts puts the handoff back (spend recorded via _switch_note_spent).
  - mode=resume: spends the handoff just before the target CLI starts, consumed_by the resumed conversation;
    falls back to fresh with a notice when the target has no binding.
  - skills/switch/SKILL.md + agents/openai.yaml (user-only on both engines): --check first, background-work
    refusal, rotate's steps 1-9 read from ../rotate/SKILL.md, then `ags -switch`; final lines "**Run `/exit`
    now** (or press `1` on the capsule above the prompt)" / "**Quit Codex now (`/quit`)**". The new
    conversation starts by itself on both engines (the handoff is its opening prompt).
  - Mod: with pending-switch present the armed key reads "1: /exit and continue in <engine>", the grace reads
    "/exit in Ns" and zero runs /exit ($.command.run). Five stale `cs:` toast expectations fixed in
    register.test.ts.
  - Tests: tests/test_switch.sh 36 (bash 3.2), test_commands +7 (incl. rotate step numbers pinned),
    test_mod_rotate +2, register.test.ts switch cases. Gate: run_all 88/88 (2564 passed, 10 skipped), bun
    tests 116/116 via an `npx bun@1` shim, sandbox round trip claude -> codex -> claude with stub engines.
  - Docs: getting-started "Resume and switch engines", codex.md "Switching engines", engine-adapters.md,
    session-layout.md, hooks.md (the mod's switch state), README.
- Verified live 2026-10-07 on wap-ags-test (Claude Code 2.1.293, codex-cli 0.160.1): `/switch codex` -> --check,
  handoff, `ags -switch codex`, exact final line; the mod's band read "1: /exit and continue in codex", counted 20 s
  and ran /exit; ags reopened under Codex, which started from the handoff unprompted; `$switch claude` -> `ags -switch
  claude`, exact /quit line; /quit -> "Switching wap-ags-test to claude: a fresh conversation from ..." and Claude
  started unprompted; final /exit with nothing pending -> ags exit 0, no relaunch. State engine, bindings and
  consumed_by correct after each leg. Not verified: a real hdiutil vault.
- Live friction (follow-ups): under Codex in a worktree session the handoff's git add/commit asked for approval six
  times (the git dir is outside Codex's writable roots; Phase 4 sandbox decision); Claude's narrative Stop hook made
  Claude take one more turn after the switch's final line, burying it (bug 5's hook; the countdown still ran after
  that turn); the launch prompt names the handoff but not its parent id (the frontmatter has it).
- Deferred: Codex in encrypted sessions generally (pre-existing: plaintext session.log and handoffs); a
  manual `r` at the Codex prompt still spends the handoff before Codex starts; completion of -switch's own
  arguments; after a failed Codex relaunch the saved engine is codex (Codex records it when binding).

### Upstream v2026.10.6 and 10.7 merged — 2026-10-07 (1d4d7881, 0da7ba56; not pushed)
- Migration stamp (`.cs/local/migrated`, upstream 10.6) ported with an ENGINE field: line 1 is version, actor,
  0|1, engine; another engine or none is stale, so every `ags -switch` costs one full migration. Repair level
  reaches the Claude adapter through `CS_MIGRATE_REPAIR`; the Codex adapter manages no migrate-time files.
- Kept: Claude runs as ags's child on every launch (upstream 10.6 execs it on a sure resume); the inverted test
  is `test_resume_of_a_real_conversation_keeps_ags_as_the_parent`.
- 10.7's band keys are Ctrl+X 1 / Ctrl+X 2 (actions strip:jump1/2), labels without "1:"; the band chip reads
  `ags`. Switch follows: its final line is "**Run `/exit` now** (or press the capsule above the prompt, or Ctrl+X 1
  if you bound it)" and the armed key reads `/exit and continue in <engine>`.
- Sync script: the bare-`cs` rename skips jq's `--arg cs`/`--argjson cs`; it still misses JSX text (`>cs<`) and
  possessives (`cs's`), and docs merge plainly: check those by hand after each sync (grep added lines).
- run_all skips the mod's bun tests here (no bun): run them through an `npx --yes bun@1` shim after each sync.

### Codex automatic /clear after a rotation — 2026-10-15 (4fd1b653, PR #7; review fixes below)
- User: "do the automatic clear after rotate also in codex"; picked "Type /clear + go" over kill-and-relaunch
  (Codex dies on SIGTERM/HUP/INT and restores no terminal state) after the auto-mode classifier refused the
  first write of the typing code ("Tmux Self Drive"); the user's pick was the explicit go-ahead.
- lib/77-codex-hooks.sh: `cs -codex-hook stop` writes `.cs/local/codex-autoclear` (deadline, handoff, thread,
  action clear|quit, run) when the turn that ends is the bound thread's, this run holds the lease and a
  handoff is armed, and returns a systemMessage; `user-prompt-submit` deletes it. `_codex_autoclear_watch`
  (started by lib/76-codex.sh beside the CLI when stdin and stdout are a tty) types `/clear`, then `go`
  (or `/quit` with this run's pending switch) via TIOCSTI at 100 ms a key. CS_ROTATE_FORCE_CTX off/0 turns it
  off; CS_CODEX_CLEAR_GRACE sets the seconds (20).
- lib/16-lifecycle.sh: `_cs_run_helper_pid` and `_cs_run_stop_helper`; `_cs_run_cleanup` stops the helper
  first. Without that, a launcher killed while its terminal hung up stayed in wait4 on the watcher, which
  waited for the launcher (reproduced twice in a scratch HOME). The watcher also ends when /dev/tty is gone.
- install.sh.in registers and trusts both hooks; uninstall removes them. Skills rotate/switch and docs/codex.md
  describe the count; README's adapter table too.
- Measured on codex-cli 0.162 with a mock Responses server: keys must come at typing speed (a burst stays
  unsent; 19 keys at 50 ms got a newline, 8 submitted); Stop's systemMessage shows in the TUI; the full path
  (turn -> Stop -> watcher -> /clear + go -> SessionStart rebind, reason handoff, handoff consumed) ran.
- Tests: test_codex_hooks 19, new test_codex_autoclear 13, test_codex_hook_registration 4, test_install 106,
  test_codex_launch 33, test_run_lifecycle 11, test_commands 62, engine suites; 12/12 mutants killed;
  shellcheck at the 129 baseline. run_all not run.
- Not done: the narrative reminder and mail digest on Codex Stop; doctor rows for the Codex hooks; Linux
  without TIOCSTI only logs to session.log (no tmux fallback).

#### PR #7 review fixes — 2026-10-15 (2944a27c..0c5e9210, 23 commits on code-sessions)
The grumpy review failed the commit on B1: `.cs/local/codex-autoclear` sat in Codex's workspace-write sandbox,
so a prompt-injected agent could forge a deadline (run id is in its env) and have the trusted watcher type
/clear + Enter into an approval overlay ("Yes, proceed" is the default). Reproduced with `codex sandbox`.
- Stamp, typing marker, keys-sent marker, watcher.pid and native.pid now live in a private per-run directory,
  `${CS_CACHE_DIR}/codex-runs/<run id>` (0700, not a symlink, owned by the user; stamp 0600). It is refused
  when it lies under the session, $TMPDIR, /tmp or any `sandbox_workspace_write.writable_roots` in Codex's
  config files, compared by inode. The launcher makes it before Codex starts, removes it in
  `_cs_run_stop_helper` (normal end and signal path); a SIGKILLed run leaves an empty 0700 dir, unswept.
- The watcher decides /clear vs /quit at the deadline (as the mod re-reads at zero), checks the lease, puts
  its typing marker down before spending the deadline, and the python typist checks the marker and the
  native CLI pid before every key and Enter. UserPromptSubmit and a new PermissionRequest hook
  (`cs -codex-hook permission-request`, prints `{}`, never decides) remove both.
- Switch, user decision "never loosen": the message names engine, model and approval. Review follow-up made
  it stricter: a run launched with native approval (`CS_RUN_APPROVAL` unset/native) never types /quit for any
  switch, because pending-switch and `.claude/settings*.json` stay agent-writable until settle reads them.
- Watcher process: TERM trap ends its own child (no pkill); `_cs_run_stop_helper` waits bounded, then KILL;
  tty input is flushed only when keys were sent. A one-time probe (/dev/tty, TIOCSTI, Linux legacy_tiocsti)
  gates the watcher; the Stop hook promises a count only while watcher.pid is alive; failures log their cause.
- CS_CODEX_CLEAR_GRACE is decimal (08 works) and 0 turns the count off (user decision). `thread=` dropped.
  Uninstall removes each Codex hook on its own. An unknown hook verb answers `{}` and exits 0 when piped
  (exit 2 would read as a PermissionRequest denial).
- Not done: an older cs installed over this one keeps the PermissionRequest registration with the old exit-2
  default arm, which denies approvals; the tmux fallback; sweeping stale codex-runs dirs.
- Landed 2026-10-19: PR #8 merged in as dcba7749 (CI green on all six jobs), and PR #7 merged into the fork's
  main as 4bad6ee6 (merge commit, main's tree equals dcba7749; `code-sessions` branch kept). Deployed the same
  day with `sh setup.sh` from the profile copy: installed cs equals bin/cs, PermissionRequest registered and trusted.

## Not in scope

Stable cs. Bug 3 (MEMORY.md `merge=ours`) and bug 5 (narrative reminder) stay separate, though Phase 3
touches the same hooks.

## Risks

- The branch carries a large uncommitted rebrand: checkpoint before Phase 1.
- Phase 0 may show plugin hooks do not load, which changes Phase 2's packaging, not the design.
- Live Codex checks need the user's `codex login` in the profile.
