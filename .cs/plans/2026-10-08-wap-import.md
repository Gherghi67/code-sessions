---
status: copy design committed 66b4ae95 (2026-10-09); --apply now waits for the code-sessions rename (plan 2026-10-09-code-sessions.md: the script becomes scripts/cs-to-code-sessions.py and the profile moves to ~/.local/share/code-sessions/home)
created: 2026-10-08
---
# cs -> ags import (`scripts/cs-to-ags.py`), first for `wap`

User go 2026-10-08 ("ok, go") on the proposal, with its defaults: move the features, carry retired-feature and
scratch transcripts as inert history, remove stable's `wap` link at the end.

REVISED 2026-10-09: user ("but it won't delete the current original `cs` data") chose "Leave cs as it is": nothing
outside the profile is written. ags gets links to the project and to each feature folder in ~/.claude-sessions (one
worktree both can open); conversations, side files, prompt history, settings and secrets are copied under the same
paths; no worktree move, no branch-out registry rewrite, no CLAUDE.local.md rewording (the profile ships cs -> ags, so
the cs wording works in ags), no markers, cs's link stays. Open sessions are a note, not a blocker. The move design
below is superseded; it shipped in 9f73cc49 and is replaced by the follow-up commit.

REVISED AGAIN 2026-10-09 (conversation c625fca3): user ruling "make sure `ags` do not interact at all with `cs`;
if `cs` is ahead of `ags`, we need to refetch the differences to copy again". The link design (4474aaa7) is
superseded. AskUserQuestion answers: full APFS clone (Recommended); a file or secret changed in both -> keep ags's
and report (Recommended); retire the ags trials wap-ags / wap-ags-test; the way back (ags-to-cs.py) copies too.

Copy design:
- Base: `<profile>/sessions/wap` = clonefile(2) of the whole project dir (one call clones the tree; keeps mtimes;
  sockets/fifos removed after), its own repo; `.git/worktrees` emptied. Process files left out: .cs/session.lock,
  .cs/local/run-lease.json|.guard, .cs/local/.session-lock.*, .cs/local/.run-lease.*; .cs/local/migrated (each
  manager stamps its own).
- Features: each registered `~/.claude-sessions/wap@<task>` cloned to `<profile>/sessions/wap@<task>`, its admin
  dir copied into the copy's `.git/worktrees/<id>`, gitdir + `.git` file rewritten (ags-to-cs copy_worktree).
- Rekeyed to the copy's physical paths: Claude folders, history.jsonl "project", .claude.json projects, Codex
  trust, settings.local.json autoMemoryDirectory. Retired/scratch history keeps its keys. Registry untouched.
- Record per base in `<profile>/.cs-to-ags/<name>.json` (+ `<name>.paths/<session>.gz` path lists): per worktree
  the paths present on both sides at the last sync, cs_since (scan start) / ags_since (sync end) ctime marks,
  HEAD + index digest (ls-files -s), base text of .cs/local/state; heads of every branch.
- Rerun: fetch cs heads into refs/remotes/cs/*; per branch: ags untouched -> take cs's; cs untouched -> keep;
  ags strictly behind -> ff; else report. Per worktree git: ags untouched (HEAD+index) -> take cs's HEAD and
  index (staged-only blobs copied); both moved -> report and sync only its .cs/. Files: changed only in cs (ctime
  > cs_since) -> copy; only in ags -> keep; both -> equal or keep ags's + report; deletions follow the path list.
  .cs/local/state merged per key. Transcripts: merge_tree prefix rule. Secrets: copy missing; a value that
  differs is reported, never overwritten (no fingerprint of a value is stored).
- cs only read: every git command on cs's side runs with GIT_OPTIONAL_LOCKS=0 (status-like refreshes would
  rewrite cs's index); tests fingerprint the cs side before/after.
- ags-to-cs.py: link kinds become copies (mirror), reruns resync the same way.
- After the read-only review (2026-10-09): marks per side are taken BEFORE that side is read (2 s margin), the
  script's own writes are recorded with their ctimes (<session>.written.gz) and a file is re-stat'ed before it
  is replaced or deleted; a git divergence syncs only .cs/ with a .cs-only mark, so cs's other changes stay
  pending until git agrees again (reported once per cs change); the index is built in a temp file and renamed
  in before the refs move; absolute links into cs's folders are re-pointed at the copy (wap@refactor-chat-handler
  and wap@remove-pinus-logger link node_modules and .env into the project); a new feature whose branch is
  checked out in ags or whose detached commit ags lacks is refused; a lost path list stops the run; failed
  reads/writes keep the marks; mode changes count; ags-to-cs saves its record after each session and does not
  recopy a copy cs removed.

## Measured (2026-10-08 ~16:50, read-only)

- `~/.claude-sessions/wap -> ~/Documents/erpk_aolbackend` (adopted link). `.cs/` untracked since 04b41dcf69.
- 15 features, real worktree dirs `~/.claude-sessions/wap@<task>`: 8 `cs/<task>`, 7 branch-out (`wap-<slug>`, JSON in
  `~/.agent-worktrees/registry/erpk_aolbackend/`, fields worktreePath + sessionManager).
- Transcripts: main key 186 MB / 76; 11 live-feature keys; 33 retired-feature keys; 8 `/private/tmp` scratch keys;
  3 Codex-app worktree keys (not wap's, left out). Per conversation: file-history/<uuid>, session-env/<uuid>.
  Task lists keyed by session name: `~/.claude/tasks/wap`.
- history.jsonl: 2786 lines for the main path, 4503 for `~/.claude-sessions/wap@*`.
- Secrets: 8 `cs:wap:*` (+1 orphan `cs:wap@fix-stats-report-enums:*`, not carried: no such session).
- No Codex bindings. Profile already trusts the main path (Codex config.toml, .claude.json).
- ags's migration does not reword cs -> ags protocol phrases; the import does.

## Design

- `scripts/session_transfer.py`: helpers shared with `ags-to-cs.py` (key, liveness, merge_tree with APFS clones,
  protocol wording table, scrubbed env, secret listing).
- `scripts/cs-to-ags.py --session NAME [--apply] [--no-history]`, stdlib, /usr/bin/python3 3.9. Paths from HOME.
  Supports an adopted (link) base and its features; a base cs created in its own folder is refused with a reason.
- Order per base: refusals (base or any feature open; ags name taken; dangling link; encrypted) -> ags link ->
  each feature `git worktree move` into `<profile>/sessions/` (+ settings.local.json autoMemoryDirectory, branch-out
  registry JSON, marker `.cs/local/cs-origin`) -> reword CLAUDE.local.md -> transcripts (rekeyed for features),
  file-history, session-env, tasks/<name> -> history.jsonl lines (feature paths rewritten) -> retired/scratch history
  under old keys -> .claude.json projects + Codex trust (skipped while an ags process runs) -> secrets via
  cs-secrets get / ags-secrets set on stdin -> stable link removed only when the whole family succeeded.
- Every change goes to `<profile>/.cs-to-ags/log.jsonl`. The way back stays `scripts/ags-to-cs.py`.
- Wrapper guard (`scripts/ags-profile.sh`): `.`, -adopt, -checkpoint, -narrative pass in a `.cs` dir an ags
  sessions-root entry points at.

- Open check (added while building): a lock is not enough, since stable cs execs claude and the lock goes with it
  (wap@rpc-facade-ship-2 ran with no lock). lsof cwd + ps: any process inside a feature that moves blocks; in the
  project, only claude/codex/cs/ags. The dry run still lists the plan under the blocker; --apply refuses.

## Steps

1. [x] shared module + ags-to-cs refactor (test_ags_to_cs 10/10)
2. [x] cs-to-ags.py (real dry run 3 s)
3. [x] wrapper guard + test (test_setup 20/20)
4. [x] tests/test_cs_to_ags.sh 10/10, 26 mutants all caught, docs/migration.md + getting-started
5. [x] gate (run_all --changed: all 90 suites), commit 9f73cc49, real dry run (exit 1: open sessions)
6. [x] rework to leave cs as it is: suite 8/8, 20 mutants caught, test_ags_to_cs 10/10, test_setup 20/20, docs
7. [ ] `! sh setup.sh` to deploy the launcher guard (not needed for the import itself)
8. [ ] --apply on the user's go; best after closing the cs sessions the dry run names, so ags starts from their
   latest state (a rerun brings what grew either way)
9. [x] copy design: committed 66b4ae95. Suites 12/12 + 10/10, docs 8/8; mutants 42/42 + 8/8 (controls pass);
   gate before the review fixes 89/90 (test_local_state load flake, passes alone); real dry run exit 0, 19 features
8b. [ ] --apply on the user's go (an ags session running defers .claude.json/Codex trust to a rerun)
10. [x] retire wap-ags / wap-ags-test: user picked "Commit the edit, then remove"; d61d39072e on ags-test keeps
    the switch test's successor report + ignored checkpoint; `ags -rm --force` (links), `git worktree remove` both
