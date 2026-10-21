---
status: approved 2026-10-09; phase 1 committed as 8d08066e on branch code-sessions (not pushed); branch-out updated; phase 2 deployed and verified 2026-10-09 15:49; phase 3 (wap copy) applied and verified 2026-10-09 16:01; phase 4 (folder renamed to ~/Documents/cs/code-sessions, session renamed code-sessions) applied by the user and verified 2026-10-09 16:21
created: 2026-10-09
---
# The fork becomes code-sessions: cs inside, `code-sessions` / `ccs` outside

## Decisions (user, 2026-10-09)

- "what about if we do a fork from the original `cs` and name it `code-sessions` instead and we keep everything with
  `cs` and remove the `ags` (but also, somehow I want them separated, one command for original cs and one command
  for my fork)".
- Fork command: `code-sessions` plus the alias `ccs` (picked "code-sessions + ccs (Recommended)"). Stable cs keeps `cs`.
- Messages: "cs, with a fork banner (Recommended)": all text stays upstream's `cs`; only the version line, banner and
  help header say code-sessions. In a plain terminal the user types `ccs` even where a hint says `cs`.
- Checkout folder ~/Documents/cs/agent-sessions -> ~/Documents/cs/code-sessions "as the last step".
- Supersedes the pending class B/C question of the cs-remnants check: cs names are the fork's own now.

## Ground truth (2026-10-09, read-only)

- Fork vs upstream v2026.10.7: 196 files, +38,969/-19,051; ~716 diff lines in lib/hooks/skills/mods/completions are
  the cs->ags rename; `.cs/`, `CS_*`, `hooks/cs`, `cs/<task>` were never renamed.
- `ags`/`agent-sessions` words: lib 427, hooks 53, skills 85, mods 163, completions 18, tests 771, scripts 165, docs
  390, tui 35, install.sh.in 121, setup.sh 22, build.sh 10, README 166, CONTRIBUTING 12.
- Files: bin/ags*, completions/_ags + ags.bash, scripts/ags-profile.sh, ags-carry-over.sh, cs-to-ags.py,
  ags-to-cs.py, tests/test_ags_carry_over.sh, test_ags_to_cs.sh, test_cs_to_ags.sh; bin/cs* and completions/_cs,
  cs.bash are symlinks to the ags files.
- AGS_ variables: AGS_BIN (33 uses: launch, codex, mods cs and cs-update, narrative hook, tests), AGS_CARRY_OVER,
  AGS_TO_CS_WORDING, AGS_URL/AGS_*_URL (installer), AGS_SETUP_CARGO_*, AGS_SOURCE, AGS_LAUNCH_LOG.
- Separation comes from scripts/ags-profile.sh (CLAUDE_CONFIG_DIR, CODEX_HOME, CS_SESSIONS_ROOT, CS_* dirs, tmux
  socket `ags`, encrypted secrets, PATH with the profile bin first). Inside an ags Claude the shell snapshot keeps the
  profile bin first (~/.zshrc and ~/.local/bin/env only prepend ~/.local/bin when missing), so `cs` there is the fork.
- HAZARD (exists today): lib/00-header.sh REPO_URL/RELEASES_BASE are hex/claude-sessions, so `cs -update` typed
  inside a fork session runs upstream's installer into the profile (CS_INSTALL_DIR). Only the outer wrapper refuses
  -update/-uninstall. The binary itself must refuse.
- Profile files holding the profile's absolute path: .claude/settings.json, .claude.json, plugins/installed_plugins.json,
  plugins/known_marketplaces.json, history.jsonl, agents-sidebar-status/original-statusline, .codex/hooks.json,
  .codex/config.toml, .codex/history.jsonl, backups/*.pre-carry-over, caches under .cache/cs. Real dir sessions in
  the profile: sessions/ask (its Claude folder is keyed on the profile path); the other 5 are links into ~/Documents.
- branch-out (outside git: ~/.claude/commands/branch-out.md, ~/.codex/skills/branch-out) decides sessionManager `ags`
  from AGS_BIN; shared by stable cs and the fork through carry-over links.

## Phases

### Phase 1: code (repo only; nothing live touched) — branch `code-sessions` from 66b4ae95

1. Files back to upstream's names: bin/cs (build output), bin/cs-secrets, cs-statusline, cs-subagent-statusline,
   cs-codex-thread as real files; completions/_cs, cs.bash; drop the ags files and the cs->ags symlinks.
2. Text in code (lib, hooks, skills, mods, completions, tests, scripts, tui, install.sh.in, setup.sh, build.sh): the
   inverse of sync-upstream.py's rename(): ags-<companion> -> cs-<companion>, bin/ags -> bin/cs, _ags/ags.bash ->
   _cs/cs.bash, $AGS_*_URL -> $CS_*_URL, the command word ags -> cs, "an ags" -> "a cs". Keep the engine-neutral
   `${CS_SESSION_DIR:-${CLAUDE_SESSION_DIR}}` forms. Then review every remaining ags by hand.
3. Fork identity: product name code-sessions; `cs -version` / help header / launch banner say code-sessions; marker
   `CODE_SESSIONS_HOME` (the profile root) exported by the wrapper replaces AGS_BIN as "this is the fork"
   (`${AGS_BIN:-${CS_BIN}}` becomes `$CS_BIN`); tmux socket/session `code-sessions`; setup variables
   CODE_SESSIONS_CARRY_OVER etc.
4. The binary refuses -update and -uninstall when it is the fork (it updates from its checkout via setup.sh).
5. Wrapper scripts/code-sessions-profile.sh, installed as ~/.local/bin/code-sessions and ~/.local/bin/ccs, execs the
   profile's cs. Profile root ~/.local/share/code-sessions/home.
6. setup.sh: one-time move of ~/.local/share/agent-sessions/home to the new root before install (refuse while any
   process runs from the old profile bin): mv, rename Claude project folders keyed on the old profile path, rewrite
   the old prefix in the profile files listed above, drop .cache/cs keyed caches, repair worktrees; install.sh and
   the carry-over then regenerate hooks and Codex trust. Remove the old ~/.local/bin/ags* wrappers (only files that
   are our wrapper). Keep recognising the old "agent-sessions PATH" block.
7. Copy scripts: scripts/cs-to-code-sessions.py and scripts/code-sessions-to-cs.py (records under
   <profile>/.cs-to-code-sessions/ and ~/.claude-sessions/.code-sessions-to-cs/); their CLAUDE.local.md rewording
   tables go (both sides say cs now); refs/remotes/cs/* label stays.
8. sync-upstream.py: drop the command-name renames, keep the session-variable rewrite and the fragment/file layout
   mapping; GENERATED = bin/cs, hooks/cs-shared.sh, sweep copy, install.sh.
9. Docs: README, docs/*.md, CONTRIBUTING: ags -> cs or code-sessions; migration.md describes code-sessions.
10. Gate: build.sh in sync, `CS_TEST_JOBS=4 bash tests/run_all.sh`, bun suites via the npx shim, a stub-engine
    launch through the new wrapper in a scratch HOME, and a setup.sh profile move in a scratch HOME.

Phase 1 outcome (2026-10-09, conversation 11461b58): steps 1-10 done. Deviations: the carry-over opt-out is
`CS_CARRY_OVER` (keeps cs's names), not CODE_SESSIONS_CARRY_OVER. Added to step 6: the move rewrites both the physical
and the setup-given spelling of the profile path (install.sh recognises its own hooks only by the path it writes; with
one spelling the SessionStart hook was registered twice), and rewords every session's CLAUDE.local.md protocol from ags
to cs (awk, the same 7 phrases the copy scripts used; on the 5 real sessions the result is byte-identical to the
current template, cksum 2777902387 5910). Step 7: the back copy's fallback name is `<name>-ccs`; scrubbed_env drops
CODE_SESSIONS_HOME instead of AGS_*. Step 8: path_map's symlink branch removed (the fork has no symlinks now). Step 9:
lines that differed from upstream only by branding were restored from v2026.10.7 (318 lines; CHANGELOG and
assets/banner.svg back to upstream byte for byte), the rest reworded by hand; migration.md rewritten, with a "Moving an
ags profile" section. tests/test_install.sh's Codex trust-hash known answer keeps its recorded agent-sessions path. Gate: run_all 90/90 (after the test_switch stub fix), bun mod
suites 5/5 and 10/10 and unit 141/141 and 34/34, cargo test 382 passed. Phase 2 needs branch-out updated first: its
helper detects the fork only by ags signals that no longer exist, so it would file a code-sessions feature with the
original cs.

### Phase 2: deploy (user runs it)

`! sh setup.sh` with no fork session open (pid 21215 `ags cv-refactor` was open on 2026-10-09). Then verify:
`code-sessions -version`, `ccs -version`, `cs -version` is still stable, profile moved, `ask` resumes, the 5 links
open, Codex hooks trusted. branch-out: DONE 2026-10-09 before phase 2 (backups *.pre-code-sessions of the helper, its
test, SKILL.md and the Claude command): manager `code-sessions` detected by CODE_SESSIONS_HOME + a CS_BIN inside the
profile, launcher code-sessions/ccs on PATH, verb launch-code-sessions, tmux server/session code-sessions; a session the
old ags started (AGS_BIN) refuses instead of reading as cs. test-branch-out passes; mutants 4/4 caught.

Phase 2 outcome (2026-10-09 15:49, the user's `! sh setup.sh`): profile moved to ~/.local/share/code-sessions/home;
6 old ags launchers removed; ccs/code-sessions print "cs 2026.10.7 (code-sessions, a fork of cs)", ~/.local/bin/cs
still the original 2026.10.7. No profile config names the old path or an ags helper; one SessionStart hook; Codex
cs hook trusted (hash matches _codex_hook_trust_hash); sidebar original-statusline -> new cs-statusline. All 5
sessions' CLAUDE.local.md = current template (cksum 2777902387), each recorded Claude conversation found under the new
key; `ccs -list` lists the 5. Left for the user: ~/.local/share/agent-sessions/recovery-20261001-121033 (11 MB, a
2026-10-01 recovery snapshot; setup removes the folder only when empty). Keys not bound (no terminal under `!`): the
installer says "run cs -update", which refuses in the profile; `sh setup.sh` from a real terminal asks instead.

### Phase 3: wap copy (needs the user's explicit go)

`python3 scripts/cs-to-code-sessions.py --session wap --apply`, then open with `ccs wap`.

Outcome (2026-10-09, user picked "Apply now" after a clean dry run): exit 0, 94 s. Copied wap (own repository,
branch wap-dev, same 2 dirty paths as cs) and its 19 features as worktrees of the copy (20 worktrees, all inside
the profile; each feature's branch and dirty count equal cs's), 16 Claude history folders under the new keys plus
39 retired/scratch ones (1844 files), wap's task list (148 files), 7393 prompt-history lines, .claude.json project
settings and Codex trust for the new path, 8 secrets (encrypted store in the profile). `ccs wap` resumes
e3f03418; `ccs -list` shows wap and the 19 features. Absolute node_modules/.env links in wap@refactor-chat-handler
and wap@remove-pinus-logger point at the copy. cs untouched: ~/.claude-sessions/wap link unchanged,
erpk_aolbackend's worktree list has no code-sessions path. Record: <profile>/.cs-to-code-sessions/wap/ and
log.jsonl. wap@rpc-facade and wap@sw-titles-expiry were open in cs during the copy; rerun the same command to
bring over what they wrote since.

### Phase 4: rename the checkout folder (last; ask before touching stable cs's link)

mv ~/Documents/cs/agent-sessions ~/Documents/cs/code-sessions; this dev session is stable cs `ags-lifecycle`: its
link in ~/.claude-sessions and its Claude folder in ~/.claude/projects move with it. Memory entries naming ags are
updated after.

Prepared 2026-10-09 (user: "Script, run after exit" + rename the session to `code-sessions`). The move cannot run from
inside this session: Claude keeps writing its transcript under the old project key until it exits. Script
.cs/local/rename-to-code-sessions.py (dry run by default, `--apply`, rerunnable): refuses while session.lock's pid lives,
while any process has its cwd inside the folder, or when a target exists; then mv the folder, ~/.claude-sessions/code-sessions
-> new path (ags-lifecycle link removed), session_name in .cs/local/state, autoMemoryDirectory in .claude/settings.local.json,
rename ~/.claude/projects/<key>, append rekeyed copies of the folder's 155 ~/.claude/history.jsonl lines (append only;
all 155 round-trip byte-identical). Not touched on purpose: ~/.claude.json (other Claude processes rewrite it; the entry
holds only the trust flag and stats, so Claude asks the trust question once), .cs/README.md aliases/Location (history),
~/.agent-worktrees/registry/agent-sessions/ags-lifecycle@adopt-first-launch.json (stale entry for a worktree retired
2026-10-05). No secrets, no Codex trust, no launcher or profile file names the path. Scratch-layout test: dry run,
both refusals, apply, idempotent rerun; the real dry run refuses on this session's lock (pid 92684). Memory entries
updated the same day: ags -> code-sessions/the fork where they name current things; project_wap_moves_to_ags replaced by
project_wap_copied_into_code_sessions.

Phase 4 outcome (2026-10-09, conversation 1d37927d): the first `--apply` refused on two orphans from 7 Oct (a Monitor's
`tail -f | ugrep` on conversation 74d13ec6's finished gate log; the user stopped them). Rerun applied. Verified: the old
folder is gone; ~/.claude-sessions/code-sessions -> new path, no ags-lifecycle link; state session_name code-sessions;
autoMemoryDirectory rekeyed; ~/.claude/projects has only the new key, holding this conversation; `cs -list` shows
code-sessions; no git worktrees to repair. Claude added its own trusted ~/.claude.json entry for the new path; the old
entry and the registry's stale ags-lifecycle@adopt-first-launch.json stay, as planned. `engine: codex` in .cs/local/state
predates the rename (noted 5 Oct) and stable cs does not read it.

### After phase 4: the profile's secrets in the macOS keychain (user, 2026-10-09)

User: "make ccs to also store in macos keychain". The launcher used CS_SECRETS_BACKEND=encrypted because keychain items
are named cs:<session>:<name>, one namespace per user: wap exists in both installs and would have shared its secrets.
Now: cs-secrets takes CS_SECRETS_KEYCHAIN_PREFIX (default cs; [A-Za-z0-9_-] only, since it goes into grep patterns),
the launcher sets code-sessions and unsets an inherited CS_SECRETS_BACKEND (a session opened before this exported
encrypted). cs -list (lib/65-sessions.sh) and the picker (tui count_keychain_items) count under the prefix.
Copy scripts use session_transfer.profile_secrets_env (scrubbed env + prefix + CS_SECRETS_DIR). setup.sh
move_secrets_to_keychain: per <profile>/.cs-secrets/<session>.enc, through the profile's cs-secrets: skipped unless
cs-secrets picks the keychain; skipped while sessions/<session> or <session>@* holds a live session.lock pid; skipped
when the keychain already has one of its names; else migrate-backend keychain --from encrypted --delete-source, file
removed once empty. Tests use a file-backed fake `security` (test_lib use_fake_keychain; teardown restores PATH).
Real data to move on the next `sh setup.sh`: wap.enc (8), jev-dating-copy.enc, wap-ags.enc (the retired trial's).

### After phase 4: finish under Codex (user, 2026-10-09)

User: "yes, go" to running $finish end to end under Codex and, if it works, giving Codex feature_finish. Live trial
(~/.cache/code-sessions-finish-trial, profile CODEX_HOME, codex-cli 0.162.0-alpha.17.2, `codex exec '$finish feat'`):
under -s workspace-write Codex followed the skill (read SKILL.md, finish.sh prepare, `cs trial -integrate-feature feat
<sha> -- true`) and stopped at "mkdir .git/cs: Operation not permitted" (Codex keeps .git read-only); under
-s danger-full-access the whole ritual ran: integrate a665e9f+24de129 -> 8f237bf, report, retire (worktree and
cs/feat gone). Built: Codex capabilities gain feature_finish; _launch_codex_bound arms kick `$finish <task>` (a
handoff taken with r wins and warns, as on Claude); 99-main's refusal is engine-neutral; lib/30-worktree.sh
_finish_command (state engine codex -> `$finish`) in retire/integrate/_integrate_in_temp refusals, the open-feature
refusal names Codex and /quit for a feature that last ran under Codex; finish.sh finish_word for its handoff and
retire lines; SKILL.md "## Under Codex" (user types $finish; run finish.sh and both cs entries with escalated
permissions from the start; AskUserQuestion -> plain text). Not verifiable without a TTY: the interactive approval
flow; check it after setup.sh with `ccs <base> --engine codex -finish <task>`.

Both committed as ca5e147a and deployed 2026-10-09 (setup.sh: wap 8, jev-dating-copy 1, wap-ags 2 moved into the
keychain; backup <profile>/.cs-secrets.pre-keychain). Open: the interactive Codex finish check.

### Phase 5: every cs session, not only wap (user, 2026-10-12)

User: "copy all the original cs sessions to code-sessions with all things to be the same, not only wap", through dynamic
workflows. Decision: the profile's own ags-era `ask` is renamed `ask-ags` (.cs/local/rename-profile-session.py, outside
git) so cs's `ask` keeps its name. `scripts/cs-to-code-sessions.py --all` copies every base with its features: sessions
cs created in its own folder, sessions without a repository, nested sessions (claude-sessions holds code-sessions: the
inner is copied once and the outer's copy has a link at its path), the conversations and prompt lines of links whose
folder is gone, `.voice` and plain folders of the cs root; `.usage`, `.spawn` and `index.md` are left out. Python
virtualenv text files are rewritten to the copy's path in both directions. Built and reviewed in wf_cb4f2de6-87e; the
apply and per-session verification follow in a second workflow. Sessions open in cs during the copy need a rerun.

Phase 5 outcome (2026-10-13, workflows wf_cb4f2de6-87e, wf_5ab56ede-2fa, wf_ae5a2b82-7ed and one follow-up agent; all
uncommitted): rename ask -> ask-ags applied (record <profile>/.rename-profile-session/ask-to-ask-ags.json finished);
`--all --apply` copied every cs session and feature (28 sessions and 30 features by the last run, plus .voice and coverage-check; the two links
whose folders are gone carry only their prompt history). The copies of claude-sessions, code-sessions, my-task and x
record `engine: claude` (stable cs ignores their `engine: codex`), with their bound Codex rollouts in the profile's
.codex, so `ccs <name> --engine codex` resumes them. Reruns now also carry tags, remote-tracking refs, branch and
remote config sections, reflogs and FETCH_HEAD (records keep remotes, config, tag-names.gz), and take a Claude history
file cs rewrote whole when the profile left it alone (history.gz signatures). Gates: test_cs_to_code_sessions 59/59,
test_code_sessions_to_cs 12/12, test_docs 8/8, lint baseline 129. Independent checker (scratchpad verify_copy.py) and
spot checks: every copy matches cs except drift from sessions open in cs; cs snapshots unchanged by the tool. Last run
2026-10-13 12:14 rc 0 "No problems." Open: rerun `scripts/cs-to-code-sessions.py --all --apply` after closing the cs
sessions that were open; the carry-over's links from the profile into ~/.claude and ~/.codex (10-07 design) stay: user,
2026-10-13, "it will keep sharing for now"; stale ags-era .claude.json entries for erpk_aolbackend and
jev-ultrafast in the profile are optional cleanup.

## Not in scope

- Renaming `.cs/`, `CS_*`, `cs/<task>` (they are upstream's names and stay).
- A GitHub repository for the fork (origin stays hex/claude-sessions).
