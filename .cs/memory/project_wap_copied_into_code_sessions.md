---
name: project-wap-copied-into-code-sessions
description: "Every stable cs session (wap first on 2026-10-09, all of them with --all on 2026-10-13) was COPIED into code-sessions with scripts/cs-to-code-sessions.py; cs keeps its sessions untouched, each copy is its own folder and repository, and a rerun brings over what cs did since. The two never share folders or state."
metadata:
  node_type: memory
  type: project
  originSessionId: 8a98ed88-d62b-4948-86ac-cc2cbc37a382
  modified: 2026-10-13T09:30:00.000Z
---

History: on 2026-10-07 the user decided to bring wap into the fork ("I will bring `wap` cs session here").
On 2026-10-09 the design changed twice: first "leave cs as it is" (links), then "make sure `ags` do not
interact at all with `cs`; if `cs` is ahead, refetch the differences to copy again", so the tool makes
copies, not links. The fork was renamed ags -> code-sessions the same day.

State after `python3 scripts/cs-to-code-sessions.py --session wap --apply` (2026-10-09 16:01, exit 0, 94 s):
- Copy at ~/.local/share/code-sessions/home/sessions/wap (APFS clone, own .git, branch wap-dev) plus 19
  `wap@*` features as worktrees of that copy; Claude history under the copy's keys, 8 secrets in the
  profile's encrypted store. Opened with `ccs wap`.
- cs side unchanged: ~/.claude-sessions/wap still links to ~/Documents/erpk_aolbackend, which has no worktree
  in the profile.
- Record: ~/.local/share/code-sessions/home/.cs-to-code-sessions/wap/ (record.json, per-session path lists)
  and log.jsonl beside it.

**Why:** the user wants the original cs and the fork side by side with no shared files, so either can be
dropped without damaging the other.

**How to apply:**
- To pick up work done in cs since the copy, rerun the same command (dry run first; `--apply` to copy). When
  both sides changed a file, the copy's version is kept and the conflict is reported.
- To go back, `scripts/code-sessions-to-cs.py --session wap` (also copies).
- Never link a fork session to a cs folder or share `.cs/` between them. Commits made in the copy do not reach
  ~/Documents/erpk_aolbackend; they are pushed to the remotes like any clone.
- Related: [[feedback-migration-tools-carry-everything]], [[reference-branch-out-skill-location]].

**2026-10-13, every session:** the user asked for "all the original cs sessions ... with all things to be the same, not only
wap". `scripts/cs-to-code-sessions.py --all --apply` now copies sessions cs created in its own folder, sessions without a
repo, nested ones (claude-sessions holds code-sessions: the inner is copied once and the outer's copy has a link at its
path), dangling links' prompt history, `.voice` and plain root folders. The profile's own ags-era `ask` was renamed
`ask-ags` first (user's choice) with .cs/local/rename-profile-session.py, so cs's `ask` kept its name. Copies of sessions
whose cs state says `engine: codex` record `engine: claude`, because stable cs ignores the key and opens Claude; their
Codex threads come along for `ccs <name> --engine codex`. Reruns carry git tags, remote-tracking refs, branch config and
reflogs, and take whole-file history rewrites the profile left alone.

- Rerun `--all --apply` after closing cs sessions that were open during the last run; they drift until then.
- The carry-over (scripts/carry-over.sh, 10-07) LINKS profile skills/agents/CLAUDE.md into ~/.claude and ~/.codex: the
  one shared-state exception. User, 2026-10-13: "it will keep sharing for now". Do not turn the links into copies
  unasked; an edit under ccs reaches cs on purpose.

- A dry run can name a feature on a detached HEAD "not copied: ... on no branch the copy has" (exit 1) while `--apply`
  copies it: the run adds cs's new refs before the features. Seen 2026-10-14 with wap@march-size-research when the user
  had wap@drop-application-token re-synced after its /wrap (`--session wap --apply`, rc 0).
