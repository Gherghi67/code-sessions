---
parent: 9b55fe8f-7a1b-4c99-a9e5-00e713e8b90e
created: 2026-10-09T08:47:00Z
purpose: Redesign scripts/cs-to-ags.py so ags never touches cs (own copies, no shared folders) and a rerun re-fetches what cs added since the last copy
status: consumed
consumed_by: c625fca3-7ee6-4662-bd80-4cf3b7230581
---

## 1. Next Step

The user's newest ruling (the /rotate argument, verbatim): "make sure `ags` do not interact at all with `cs` ,
basically, if `cs` is ahead of `ags`, we need to refetch the differences to copy again".

That overturns the design committed in 4474aaa7, where ags gets SYMLINKS to cs's folders: `<profile>/sessions/wap ->
~/Documents/erpk_aolbackend` and `<profile>/sessions/wap@<task> -> ~/.claude-sessions/wap@<task>`. Those share
`.cs/local/state`, the worktrees and the project's `.git` with stable cs. That is interaction. NOTHING has been applied
for real. Only dry runs ran on the real wap, and the real profile has no wap entry. So there is nothing to undo.

Do this, in order:

1. Reconcile the native task list. #20-#24 are completed. #25 "Gate, commit, real dry run" is done in substance:
   gate 90/90, commits 9f73cc49 and 4474aaa7, dry run exit 0. Mark it completed. Add one task per step below.
2. Propose the copy design, short, and ask the user with AskUserQuestion. This is the third design in two days,
   and its choices are genuinely theirs. Then build on their answer. Proposal skeleton, with recommended defaults:
   - **Project:** a full copy into `<profile>/sessions/wap`, as a real directory and its own repository. Use
     `cp -c -R` (APFS clone, so no extra space): `.git`, `.cs/`, `node_modules`, `.env*`, everything. Then it is a
     session ags created, with no link to cs. The alternative, `git clone` plus copying `.cs/`, loses ignored and
     untracked files. Both the project and the copy are on the same APFS volume (/Users/...).
   - **Features:** each `~/.claude-sessions/wap@<task>` becomes a linked worktree of the ags COPY's repository. Do
     what `scripts/ags-to-cs.py` `copy_worktree` does in the other direction: copytree the worktree, copy its admin
     dir `<repo>/.git/worktrees/<id>` into the copy's `.git/worktrees/`, then rewrite `gitdir` and the worktree's
     `.git` file. The copy's `.git/worktrees` must start EMPTY, so drop the original's entries, as ags-to-cs's
     `copy_directory` does. Separate repos mean the same branch can be checked out in both.
   - **Paths change, so rekey everything** to the copy's paths: the Claude folder names, `history.jsonl` "project",
     `.claude.json` projects, Codex `[projects."..."]` trust, `.claude/settings.local.json` autoMemoryDirectory.
     9f73cc49's version of the script already did this rekeying for features; reuse it
     (`git show 9f73cc49:scripts/cs-to-ags.py`). Branch-out registry: leave cs's entries alone. That is cs-side
     data, and "do not interact" means not touching it either.
   - **Re-sync when cs is ahead (a rerun):**
     - git: `git -C <copy> fetch <cs repo> '+refs/heads/*:refs/remotes/cs/*'`, then fast-forward each ags branch
       that is strictly behind its cs counterpart. A branch that diverged is reported, not merged. A feature that
       is new in cs is copied.
     - Working-tree and `.cs/` files: three-way, using a per-file manifest (sha) of what the last copy wrote, kept
       in the profile, e.g. `.cs-to-ags/<session>.json`. Changed only in cs: copy it. Changed only in ags: keep.
       Changed in both: keep ags's and report it (recommended default; ask).
     - Transcripts: the merge_tree prefix rule already does this (cs grew: copy; both grew: report).
     - Secrets: copy names ags lacks. Ask whether a changed value should overwrite.
   - **cs is only read.** The test fingerprint `cs_side_fingerprint` in `tests/test_cs_to_ags.sh` already proves
     this for the link design; keep it as the main assertion.
   - **Flag to the user:** the existing ags trial sessions `wap-ags` and `wap-ags-test` are git worktrees of
     cs's `~/Documents/erpk_aolbackend/.git` (branches `ags-trial`, `ags-test`). That is interaction too; offer to
     retire them or rebase them onto the copy. `scripts/ags-to-cs.py`'s link kinds (`link`, `worktree-link`) also
     share folders. Ask whether the way back should copy as well.
3. After building: run the suite plus mutants. The runner is in the scratchpad: `mutate_par3.py` runs mutants 4-wide
   on scratch copies of `scripts/`, `tests/` and `bin/`. Then `CS_TEST_JOBS=4 bash tests/run_all.sh --changed`, which
   takes over 10 minutes, so run it in the background. Then commit, then a real dry run
   (`python3 scripts/cs-to-ags.py --session wap`). Do NOT run `--apply` without the user's explicit go.

The repo `/Users/bogdan.gherghina/Documents/cs/agent-sessions` (branch `codex/agent-sessions-rebrand`) is clean at
4474aaa7, apart from `.cs/`, which is git-ignored here. Nothing is pushed. This handoff stays uncommitted (ignored),
so a branch switch needs no commit first.

User-side reminders, once:
- The agents-sidebar update is due before 2026-10-13: its updater refuses while `plugin/statusline-bridge.sh` is
  modified in `~/.local/share/agents-sidebar/src`. The route I gave: `git -C ~/.local/share/agents-sidebar/src checkout
  plugin/statusline-bridge.sh`, delete the `.pre-ags-mode` backup, update, then reapply the 12 lines.
- `! sh setup.sh` deploys the launcher-guard change in `scripts/ags-profile.sh`.
- MCP logins in the profile; `ags -update` in a terminal to bind the keys.

## 2. Settled and rejected

- Import moves the 15 features with `git worktree move`, rewrites the branch-out registry, settings and protocol wording, removes cs's link (9f73cc49) | proposed by me, "ok, go" from the user | REJECTED by the user: "but it won't delete the current original `cs` data"
- "Leave cs as it is": ags links to the project and the feature folders, copies the rest, edits nothing outside the profile (4474aaa7) | user picked "Leave cs as it is (Recommended)" in AskUserQuestion | now OVERTURNED by "make sure `ags` do not interact at all with `cs`": links share state
- "Move, but cs keeps links" and "Keep the move as built" | offered in the same AskUserQuestion | not chosen
- "ok, go" was read as the go for the wap import with its defaults (move the features, carry history, remove the link last), not for the agents-sidebar update | me | the import was the pending "Say go"; the sidebar was not touched
- Open check by process as well as lock | me | stable cs execs claude and the lock goes with it: `wap@rpc-facade-ship-2` had claude pid 5364 running with no `.cs/session.lock`
- In the link design, an open cs session is a note, not a blocker | me | nothing moves, so a rerun brings what grew; in the move design it was a blocker
- Only engines and session managers (claude, codex, cs, ags, matched against the first two argv basenames) count as open | me | a shell or an editor in the project does not hold it
- No cs->ags rewording of CLAUDE.local.md in the link design | me | the profile ships `cs -> ags` and `cs-secrets -> ags-secrets` on PATH, so the cs wording works in ags
- Helpers shared by both scripts in `scripts/session_transfer.py` | me | so the two directions cannot drift; copies are APFS clones via libSystem `clonefile` through ctypes, falling back to `copy2`
- `ags-to-cs.py` entry_state: cs's real folder that the ags link resolves to counts as "ours" (it used to require a cs link) | me | needed for the way back in the link design
- Retired-feature and scratch transcript folders are carried as history under their own names, `--no-history` to skip; the 3 Codex-app worktree folders stay out | proposal default accepted with "ok, go" | not wap's sessions
- `.claude.json` and Codex config merges are skipped while any process runs from the profile's `.local/bin/` | me | a running ags Claude may rewrite `.claude.json` under us
- The mutant that drops the encrypted secrets backend was deliberately not run | me | ags-secrets would write to the REAL login keychain
- The in-place mutation loop was stopped and replaced by a 4-wide runner on scratch copies | me | about 2.5 min per mutant serially; the script was restored from a `.keep` copy and checked with cmp
- Launcher guard (`scripts/ags-profile.sh`): `.`, -adopt, -checkpoint and -narrative pass in a `.cs` dir that an ags sessions-root LINK resolves to | me | committed; still fits a copy design only if the copy is a real dir under the profile home, which the guard already allows

## 3. Conversation-only facts

IDS
- measured: repo `/Users/bogdan.gherghina/Documents/cs/agent-sessions`, branch `codex/agent-sessions-rebrand`: 4474aaa7 "cs-to-ags: leave cs as it is; ags links to the same folders", 9f73cc49 "cs-to-ags: move a project cs adopted, with its features, into ags", 1de36e87 base. Nothing pushed.
- measured: this conversation `9b55fe8f-7a1b-4c99-a9e5-00e713e8b90e`; launch env `CS_CLAUDE_SESSION_ID=fed20df3-168c-4117-97c3-48c4e4c23121`.
- measured: plan file `.cs/plans/2026-10-08-wap-import.md` (ignored), with the revised status and steps 1-8; step 8 (--apply) is open.
- measured: scratchpad `/private/tmp/claude-501/-Users-bogdan-gherghina-Documents-cs-agent-sessions/9b55fe8f-7a1b-4c99-a9e5-00e713e8b90e/scratchpad/`: `mutate_par3.py` + `mutants3.py` (current runner and list: entries (file, name, old, new)), `mutate_par.py`/`mutants_list.py`/`mutants_list2.py` (the move design's), `mutants2.log`, `mutants3.log`, `real-dry-run.txt` (move design), `real-dry-run2.txt` (link design), `gate2.log`, `cs-to-ags.py.keep`, `ags-profile.sh.keep`. Scratch is temporary.
- measured: wap = `~/.claude-sessions/wap -> /Users/bogdan.gherghina/Documents/erpk_aolbackend`; on 10-08: branch `wap`, head `04b41dcf69` "<cs> Untrack .cs/ and add the dashboard-892 and incident docs" (2026-10-07 20:27, 219 commits squashed, backup branch `backup/wap-pre-squash-2026-10-07`); `git ls-files .cs` = 0; `.gitignore:22 .cs/`.
- measured (10-09 dry run): 17 features, each a real dir in `~/.claude-sessions` and a registered worktree: bots (cs/bots), fix-achievements-tests (cs/fix-achievements-tests), fix-spend-log-amount (wap-fix-spend-log-amount), flatten-event-task-writes (wap-flatten-event-task-writes), jest-ci-cost (cs/jest-ci-cost), login-deadlock-retry (wap-login-deadlock-retry), pinus-container-adapter (wap-pinus-container-adapter), refactor-chat-handler (cs/fix-blocked-words-broadcast), refactor-low-stakes-admin-controllers (cs/...), refactor-statistics-remote (cs/...), remove-pinus (cs/remove-pinus), remove-pinus-logger (cs/remove-pinus-logger), rpc-facade (wap-rpc-facade), rpc-facade-ship-2 (wap-rpc-facade-ship-2), single-jack-fever-event (cs/single-jack-fever-event), spawn-marauder-race (wap-spawn-marauder-race), test (cs/test).
- measured: branch-out registry `~/.agent-worktrees/registry/erpk_aolbackend/<session>.json`, fields include worktreePath, sessionManager ("cs"), branch, baseRef, baseCommit, handoffPath; 7 match live features.
- measured: open in cs at the 10-09 dry run: wap (pid 66384 `claude --name wap --resume ed2acaf5-...`, and 1 more), wap@fix-achievements-tests (pid 15744), wap@fix-spend-log-amount (pid 29854, and 1 more), wap@rpc-facade-ship-2 (pid 5364 in tmux session `cs`, window `wap@rpc-facade-ship-2`, parent `tmux new-session -d -s cs ... '/Users/bogdan.gherghina/.local/bin/cs' 'wap@rpc-facade-ship-2'`, since 2026-10-07 12:00, no session.lock).
- measured (10-08): `ags jev-ultrafast` pid 80141 on ttys006 (since 2026-10-07 20:39); gone at the 10-09 dry run (no ags-running note).
- measured: profile `~/.local/share/agent-sessions/home`: `sessions/` (ask dir; links cv-refactor, jev-dating-copy, jev-ultrafast, monitor-staff, red-dragon-macos-emulator, wap-ags, wap-ags-test), `.local/bin/` has `cs -> ags` and `cs-secrets -> ags-secrets`; `.claude/.claude.json`; `.codex/config.toml` already trusts `/Users/bogdan.gherghina/Documents/erpk_aolbackend`.
- measured: trial worktrees of cs's repo: `~/.local/share/agent-sessions/home/work/wap-ags` (branch ags-trial) and `.../work/wap-ags-test` (branch ags-test).
- measured: other worktrees of the repo: roast worktrees under `~/.claude/roast-worktrees/wap@*`, 14 under `~/.codex/worktrees/*/erpk_aolbackend`, `~/.gemini/antigravity/worktrees/erpk_aolbackend/fix_test_suite_regressions`, `~/Documents/erpk-ava-teardown-cache`, `~/Documents/erpk_aolbackend-testing-infrastructure`, a /private/tmp scratch one. 40 in total on 10-08.
- measured: agents-sidebar checkout `~/.local/share/agents-sidebar/src` HEAD `150452a` (2026.10.6), ` M plugin/statusline-bridge.sh` (+12 lines: loop over CLAUDE_CONFIG_DIR / CLAUDE_SECURESTORAGE_CONFIG_DIR choosing `<dir>/agents-sidebar-status/original-statusline`), `?? plugin/statusline-bridge.sh.pre-ags-mode` (== HEAD); the identical copy `~/.claude/skills/agents-sidebar/statusline-bridge.sh` has its own `.pre-ags-mode`; the profile settings.json statusLine runs the checkout's bridge. Made by workflow wf_1d1a3e50-994 (2026-10-07), not this conversation.
- measured: Claude task lists are keyed by session name: `~/.claude/tasks/wap` (lib/75-launch.sh:471 `export CLAUDE_CODE_TASK_LIST_ID="$session_name"`).

READINGS
- measured (10-08 ~16:50): 15 features; 40 worktrees; 56 Claude folders matching wap (2.1G): main 186M/76 conversations, 11 live features with folders, 33 retired, 8 /private/tmp scratch, 3 Codex-app; secrets 8 `cs:wap:*` + 1 orphan `cs:wap@fix-stats-report-enums:*`; history.jsonl 2786 lines for the main path, 4503 for `~/.claude-sessions/wap@*`; stable `cs 2026.10.7`.
- measured: stable wap stamp `.cs/local/migrated` line 1 `2026.10.7<TAB><the actor's work email><TAB>0` (no engine field).
- measured: move-design dry run 2.925 s total; "Claude history of wap, 76 conversation(s) ... 501 new"; history 39 folders/621 conversations/1861 files; 7258 prompt lines.
- measured (10-09 link-design dry run, exit 0): 18 links; "ags wap resumes conversation 87ce729e-e2ac-45cf-8f56-378df55f84e3"; "history of 39 retired feature and scratch folder(s), no session, 613 conversation(s), files to copy: 1844 new"; "prompt history: 7292 line(s) to append"; "Claude project settings to merge for ~/Documents/erpk_aolbackend"; 8 secrets to copy (names: NEW_RELIC_API_KEY, WAP_STAGING_GAME_DATABASE_URL, WAP_PRODUCTION_SLAVE_GAME_DATABASE_URL, WAP_PRODUCTION_STATS_DATABASE_URL, ADMIN_PASSWORD, WAP_STAGING_ADMIN_PASSWORD, WAP_STAGING_STATS_DATABASE_URL, TEAMCITY_TOKEN; values never read).
- measured: wap's binding moved during the conversation: 864307cf (10-08 start) -> 04057c60 -> 87ce729e (10-09).
- measured: tests: link design `tests/test_cs_to_ags.sh` 8/8; mutants 20/20 caught (mutants3.log); move design 10/10, mutants 23/23 + 3/3; test_ags_to_cs 10/10; test_setup 20/20; test_docs 8/8; `CS_TEST_JOBS=4 run_all --changed` "OK: all 90 suites passed" twice (slowest test_rotation 469 s under mutant load).
- measured: context-warning hook at 45%.

ERRORS
- measured: test bug "FAIL: a rerun duplicated the prompt history / expected: 4 / actual: 3" (the fixture has 3 wap lines).
- measured: `assert_file_contains ... "--resume $WAP_ID"`: grep read the leading `--` as an option; fixed by "name wap --resume ...".
- measured: `assert_output_contains` is grep BRE: `\(` is a group, so "open right now: wap@feat \(pid ..." failed to match; use `.`; `a|b` is literal in BRE.
- measured: Write tool: "File has been modified since read, either by the user or by a linter. Read it again before attempting to write it." after python edits.
- measured: `run_all --changed` exceeded the 600 s foreground timeout and was backgrounded.
- measured: zsh `ls -d *erpk-aolbackend* ...` printed nothing ("no matches found" suppressed); use find.

USER
- user: "ok, go" (after the move-design proposal; read as the go for the import).
- user: "- The agents-sidebar status-line edit is still uncommitted. Its release asks for an update before 2026-10-13, and its updater refuses while that edit is there. / what have you changed there?" (answered: the 12-line bridge loop above).
- user: "but it won't delete the current original `cs` data" -> AskUserQuestion answer "Leave cs as it is (Recommended)".
- user: "/rotate and make sure `ags` do not interact at all with `cs` , basically, if `cs` is ahead of `ags`, we need to refetch the differences to copy again".

UNVERIFIED
- assumed: finishing or retiring a linked feature in ags removes the worktree for cs too (lib/30-worktree.sh:538 `git worktree remove --force "$wt_dir"`, and git resolving the link path). Moot under a copy design.
- assumed: `clonefile` actually cloned on the real volume (only fixtures in /var/folders were exercised); `shutil.copystat` after the clone keeps copy2's metadata.
- assumed: Claude Code reads per-project prompt history in file order, so appended older lines are fine.
- assumed: no ags Claude rewrites `.claude.json` while the script merges, guarded only by the ps check for the profile's `.local/bin/`.
- assumed: `cp -c -R` of a 2+ GB project with node_modules is fast and safe while cs sessions run in it. Not measured.
- measured in fixture only: ags's first open of a handed-over session runs its migration ("Added cs:memory-note to CLAUDE.local.md", "Backfilled claude_session_color in .cs/local/state (pink)") and launches `claude --name wap --resume <id> /color pink`.
- assumed: the launcher-guard change is not deployed (`! sh setup.sh` not run since).

## 4. Primary Request and Intent

Make ags usable for daily work in place of stable cs, with `wap` as its main session, brought over by
`scripts/cs-to-ags.py`. The user's constraints, in order: carry everything (memory `feedback_migration_tools_carry_everything`);
do not delete cs's data ("but it won't delete the current original `cs` data"); and now "make sure `ags` do not
interact at all with `cs`", where a rerun re-fetches what cs has that ags lacks. The way back stays `scripts/ags-to-cs.py`.

## 5. Key Technical Concepts

- Claude folder name = the physical path with every non-alphanumeric character turned into `-`, so a copy at a new
  path needs rekeyed folders, `history.jsonl` "project" fields and `.claude.json` keys.
- ags finds features as `$CS_SESSIONS_ROOT/<base>@*` dirs whose `git rev-parse --show-toplevel` is registered in the
  base repo's `git worktree list --porcelain` (lib/30-worktree.sh:134-160).
- A linked worktree = its `.git` file (`gitdir: <repo>/.git/worktrees/<id>`) plus the admin dir's `gitdir` back-pointer.
  ags-to-cs.py `copy_worktree` shows how to re-home one into a copied repo.
- Stable cs execs claude, which takes its `.cs/session.lock` with it, so an open session shows up as a process
  (`lsof -a -d cwd -F pn` + `ps -A -o pid= -o command=`).
- merge_tree's append-only rule (scripts/session_transfer.py): a missing file is copied; one where the destination
  is a prefix of the source is replaced; one where the source is a prefix of the destination counts "ahead" and is
  kept; one that differs inside counts "diverged" and is reported.

## 6. Files and Code Sections

- `scripts/session_transfer.py` (new in 9f73cc49): tilde, claude_project_key, pid_alive, session_is_open, read_text,
  state_value, write_atomic(prefix=), copy_file (clonefile then copy2), merge_tree(src, dst, apply, tmp_suffix), Tally,
  special_files, AGS_TO_CS_WORDING + reword_protocol(text, wording), scrubbed_env, secret_names, copy_secret.
- `scripts/cs-to-ags.py` (4474aaa7, link design): Importer.plan / plan_features / open_sessions / history_keys /
  prompt_history / project_settings / codex_trust / secrets; handle() links, copies, merges, copies secrets.
  The move design with the rekeying lives in `git show 9f73cc49:scripts/cs-to-ags.py`.
- `scripts/ags-to-cs.py`: imports the shared module; entry_state treats cs's real folder as "ours" for shared kinds.
- `tests/test_cs_to_ags.sh`: fixture `make_fixture`; `cs_side_fingerprint` (CSROOT, project, ~/.claude, ~/.codex,
  ~/.claude.json, registry, worktree list, stub store); 8 tests including the round trip and bin/ags launching from the profile copy.
- `scripts/ags-profile.sh` guard + `tests/test_setup.sh` `test_launcher_runs_directory_commands_in_a_project_ags_has`.
- `docs/migration.md` "Opening a cs session in ags" (link design; rewrite it for the copy design), `docs/getting-started.md` pointer.

## 7. Problem Solving

- Move design built and verified, then rejected by the user. Link design built and verified (cs byte-identical
  after --apply), then overturned by "do not interact at all".
- Found the lock-less stable sessions; added the process scan.
- Mutation runs: serial in-place took ~2.5 min each, so they now run 4-wide on scratch copies; every mutant was caught.

## 8. Pending Tasks

- Native list: #20-#24 completed; #25 "Gate, commit, real dry run" in_progress (done in substance: mark completed).
- Next: the copy design (Next Step), then `--apply` only on the user's go.
- User-side: agents-sidebar update before 2026-10-13; `! sh setup.sh` for the guard; MCP logins in the profile;
  `ags -update` for the keys.
- Follow-ups carried from the 10-08 handoff (unchanged): re-test switch live under 10.7's band; Codex git approvals in
  worktree sessions; narrative Stop hook forcing a turn after switch/rotate; Codex manual `r`; Codex in encrypted
  sessions; doctor stamp row for Codex; `-switch` completion; sync-script rename for JSX text and possessives;
  CODEX_* scrub in branch-out's ags tmux server; `ags -spawn` tmux env inheritance; wap-ags-test's leftover edits.

## 9. Current Work

The link design is committed (4474aaa7) and its real dry run is clean, but the user's rotate argument rules out links.
Nothing was applied to the real profile. The repo is clean except git-ignored `.cs/`. The narrative
`.cs/memory/narrative.gherghinabogdan7-gmail-com.md` has this conversation's entries (2026-10-08/09). This handoff was
written from the full, uncompacted conversation.

## Successor report

- The native task list did NOT carry over: TaskList was empty, so #20-#25 could not be marked; created #26-#30 instead. Found by TaskList at the start.
- Feature count is stale: the dry run now lists 19 features, not 17 (new: wap@naval-spend-sources, wap@sw-titles-expiry), and the open set changed (wap itself no longer open; naval-spend-sources and sw-titles-expiry are). Found by the real dry run.
- Re-derived the scale, which the handoff did not carry and which shaped the design: project 1.5G (98k files, 76k in node_modules), each feature ~90k files / ~880M with its own node_modules, ~1.6M files in all; so the per-file sha manifest the handoff proposed was dropped for ctime marks + a path list. Found with du/find.
- Re-derived what counts as process state in .cs (lib/02-shared.sh, lib/15-lock.sh: session.lock, local/run-lease.json, run-lease.guard, .session-lock.*/.run-lease.* temps) and that cs's sessions root already holds dot dirs (.spawn, .usage, .voice), so .ags-to-cs/ there is ignored as a session. Found by grep and ls.
- The handoff said wap-ags-test had "leftover edits" without saying what: one modified, tracked handoff (the switch test's successor report) plus an ignored 7869-line checkpoint its own handoff says to preserve. Committing it needed `git add -f`, since .cs is ignored in that branch even for tracked files. Found by git status --ignored and the refused add.
- The real dry run now notes "an ags session is running (pid 2319 ... home/.local/bin/ags)", so an --apply now would leave .claude.json and the Codex trust for a rerun. Not in the handoff.
