# Session Summary: agent-sessions

**Date:** 2026-10-01 through 2026-10-19 (Europe/Bucharest); refreshed after PR #7 merged and was deployed.
**Duration:** About two and a half calendar weeks across many resumed and rotated conversations. Compactions, usage-limit pauses and overlapping feature runs make active work time impossible to estimate.

## Objective

The session began by validating the lifecycle of ags, an experimental fork of cs with Claude and Codex adapters. It grew into making that fork usable for daily development: isolate its profile, give both engines the same manager features, carry the user's own tooling over, and copy existing projects and conversations without losing work.

The fork now runs as **code-sessions** or **ccs** and keeps cs's names inside its profile; the README keeps agent-sessions as this session's historical title. The latest round brought the cs mod's automatic `/clear` after a rotation to Codex (PR #7), answered a grumpy review that failed it on a security hole, merged it into the fork's `main` and installed it into the profile.

## Environment

Work began in `~/Documents/cs/agent-sessions`, moved to `~/Documents/cs/code-sessions`, and since 2026-10-14 runs in the profile's own copy at `~/.local/share/code-sessions/home/sessions/code-sessions` on macOS. `~/Documents/cs/code-sessions` is a stale stable-cs copy at `bcaeca65`; installing from it now does harm (see Notes).

The checkout is on branch `code-sessions` at `dcba7749`, clean, equal to the fork's `code-sessions` branch. The fork's `main` is `4bad6ee6`, PR #7's merge commit, whose tree is identical to `dcba7749`; the profile's installed `cs` is built from the same commit. Session metadata under `.cs/` is ignored by Git. Publication goes to `Gherghi67/code-sessions` as the personal account Gherghi67, through the `github` remote; `origin` is hex's upstream and is never pushed to.

The profile at `~/.local/share/code-sessions/home` has its own engine configuration, conversations, session copies, executables, caches, keychain namespace and tmux server. Personal skills and agents stay linked from `~/.claude` and `~/.codex` by the user's choice. The manager is Bash (suites under `tests/`), the picker is Rust, ShellCheck 0.11.0 holds a 129-warning baseline, `bash` and `/bin/bash` are both GNU Bash 3.2.57, and Codex CLI is `0.162.0-alpha.17.2`. CI runs on macOS and Ubuntu.

## Key Discoveries

### Profile isolation depends on native credential and process behaviour

Changing HOME hid the macOS login keychain from Claude, so its OAuth login could not be saved. The launcher keeps HOME and redirects each tool through its own variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, the `CS_*` roots), and hooks are registered by absolute path. Later checks found sharing through vault directories, the tmux server's environment, keychain counts and picker caches; each got its own path, and secrets moved to a `code-sessions:<session>:<name>` keychain namespace.

### One manager, two engines, native registration each

The user chose one manager implementation with thin adapters. Codex needs trusted hook hashes before it runs a hook, `agents/openai.yaml` to keep a skill explicit-only, and skills that read their arguments from the message, since it does not substitute `$ARGUMENTS`. Switch is rotation plus an engine change, fresh from the handoff by default; a live Claude-Codex-Claude round trip confirmed it.

### Copies, not links, with evidence from both sides

The user rejected any design where the two managers alter the same files. The transfer tools make independent copies and record per-side marks, so a receiver's edit survives later source changes and a conflict is reported, never overwritten. Copying every session surfaced requirements well beyond project files: tags, remote-tracking refs, branch config, reflogs, prompt history, whole-file workflow rewrites, nested repositories and feature worktrees.

### Driving Codex's terminal

Codex has no plugin that can run a command, so cs can only issue `/clear` by typing it. TIOCSTI works on macOS from a background process; Codex 0.162 needs typing speed (100 ms a key here), since a burst is read as a paste and its Enter becomes a newline. Codex dies at once on TERM, HUP and INT and restores no terminal state, which ruled out kill-and-relaunch. A three-event mock Responses server gives real offline turns for hook experiments.

### The session folder belongs to the agent

PR #7's reviewer found, and a `codex sandbox` probe confirmed, that Codex's workspace-write sandbox can write anywhere under the `-C` workspace except `.git`: `.cs/local`, `pending-switch` and `.claude/settings*.json` included. `CS_RUN_ID` and `CS_SESSION_DIR` reach sandboxed commands. A forged deadline therefore made cs's trusted watcher type `/clear` and Enter, and Enter on Codex's approval overlay picks "Yes, proceed". The sandbox cannot open `/dev/tty`, so the watcher had given the agent a capability it lacked. Trusted Codex hooks run outside the sandbox, which is what lets the fix move cs's state into `CS_CACHE_DIR`. A PermissionRequest hook that exits 2 reads as a denial.

The reviewer's secondary claim, that moving the stamp also closes the forged-switch trigger, was wrong: the trusted Stop hook reads `pending-switch` itself, and the agent can run `cs -switch` legitimately.

### Validation has to reach the failure boundary

Several rounds showed green suites built on chosen fixtures: PR #4's first tests missed project-controlled Python imports and invalid TOML; PR #7's tests stubbed exactly the parts its measurements concerned. Mutation runs settled every "the test does not cover X" claim, and independent reviewers repeatedly found real defects behind green per-commit suites. Long suites can hit the 600-second watchdog under load; their logs and focused reruns decide whether a cutoff is a failure. Two engines working in one folder share a Git index, so agents commit by pathspec.

### Workflows and usage limits

Twice a workflow agent hit the five-hour usage limit. The agent's call never returned and the run never notified; stopping it, telling the stalled agent's prompt what was already committed, and resuming with the run id replayed finished agents from cache and continued cleanly.

Claude Code's auto-mode check refused `gh pr merge` both times it was tried here, as "Merge Without Review", even with CI green and the review answered and after the user asked to "complete the PR". Each time the identical command went through once the user said "try again"; the refusal is reported and waited out, never routed around.

## Changes Made

### Lifecycle, profile and shared skills

Lifecycle validation corrected stale rotation assertions and adopted-session naming. The adapter foundation landed in `4d88090e`; profile work kept HOME, separated the configuration and storage roots, and moved sessions to `sessions/`. Checkpoint, summary, sweep and wrap became shared skill packages deployed to both engines. Codex rotation registers a trusted SessionStart hook that rebinds after `/clear`. `f23a6a0c` added engine switching. `scripts/sync-upstream.py` translates upstream releases into the fork's layout; releases 2026.10.3 through 2026.10.7 were merged with it.

### Rebrand, secrets and transfer tools

`8d08066e` restored cs naming inside the fork behind the code-sessions/ccs launchers; `ca5e147a` added the keychain namespace and Codex finish support. The transfer tools grew from links into independent copies both ways; `aa29122d` added `--all`, created and nested sessions and Git parity on reruns. PR #1's fixes closed held-file and symlink problems; PR #2's fixed reflog writes, nested-session mapping and gone-session reporting, and `fced974d` made failed-launch handoff restoration read persisted thread turns. PRs #1 and #2 merged.

### Codex status line, approval default and recovery

`bcaeca65` (PR #4) made the installer write a Codex footer with context use and the five-hour and weekly limits; five review fixes followed and PR #4 merged. `d3951ce2` (PR #6) launches Codex with `--approve-for-me`; review fixes `f4785952` and `1569b434` followed and PR #6 merged as `8c0716d3`. PR #5 (from `cs/improvements`) added recovery adapters for both engines, the picker's engine/model/effort/approval choices and shared sidebar subscription switching; its fixes landed in `c42e734d`..`5e027581` and it merged into `code-sessions` as `2ab9e35a`. `/finish improvements` on 2026-10-15 found it already integrated and retired the worktree.

### Codex automatic /clear and its review (PR #7)

`4fd1b653` added the count: a Stop hook writes a deadline when the bound thread's turn ends with a handoff armed, UserPromptSubmit cancels it, and a watcher beside the Codex CLI types `/clear` then `go`. The grumpy review failed it on B1 and raised six risks, nine nits and a question. A read-only verification workflow reproduced every finding; the user then decided four points: `CS_CODEX_CLEAR_GRACE=0` turns the count off, an unattended switch never loosens approval, the typing stays blind (no tty-idle gate), and a PermissionRequest hook should cancel the count.

A fix workflow of six sequential agents committed one finding at a time, each with a failing test first; two independent reviewers then checked the whole diff, and a follow-up agent fixed what they confirmed:

| Area | Commits | What changed |
|---|---|---|
| Trust boundary (B1) | `2944a27c`, `a8f0c04c` | Stamp, markers and pid files live in a 0700 per-run directory, `${CS_CACHE_DIR}/codex-runs/<run id>`, refused when it lies under the session, `$TMPDIR`, `/tmp` or a Codex `writable_roots` (compared by inode); stamp must be a 0600 regular file. |
| Switches | `cffb5c62`, `9d098ebb`, `343ca6d2` | The action is decided at the deadline; the message names engine, model and approval; a native-approval run never types `/quit` for any switch, stricter than the user's pick because `pending-switch` and `.claude/settings*.json` stay agent-writable until settle reads them. |
| Typing | `ede7a2bb`, `9cac1549`, `b6ad0be7`, `0c5e9210` | A typing marker the typist checks before every key and Enter; prompts and the new PermissionRequest hook remove it; it goes down before the deadline is spent, so a prompt in that gap also stops the keys. |
| Watcher process | `d4b0149f`, `b4fd02ae`, `64c1f46a`, `ca287815` | TERM trap instead of pkill; bounded stop with KILL; typing stops once the native CLI is gone; tty flushed only after keys; a one-time TIOCSTI probe gates the watcher and the Stop hook promises a count only while it lives; failures log their cause. |
| Smaller fixes | `2c6f00ab`, `ad9b5bc4`, `de240b46`, `bd750b58`, `c53a2ebe`, `33f46025` | Decimal grace, 0 = off, unread `thread=` dropped, uninstall removes each hook on its own, lease check at the deadline, unknown hook verb answers `{}` with exit 0. |
| Tests | `dbf96b83`, `b0bf81c6`, `2b3a784b`, `f9c22920` | Fresh stand-ins per test, zombies count as gone, waits count watcher polls instead of seconds, the launch wiring is covered. |

At push time the fork's branch had moved: PR #8 (`cs/fix-agents-sidebar-switch`) had merged into it. The user chose to merge it in (`dcba7749`), re-run every gate and push without force. The round-up is [PR #7 comment 6210227867](https://github.com/Gherghi67/code-sessions/pull/7#issuecomment-6210227867).

On 2026-10-19 nothing new had been posted on the PR and all six CI jobs were green at `dcba7749`. It merged into `main` as `4bad6ee6` with a merge commit, as PRs #1, #2, #4 and #6 did, keeping the `code-sessions` branch. `sh setup.sh` then ran from this copy inside `env -i` with only HOME, USER, SHELL, TERM, LANG, TMPDIR and a plain PATH, so the conversation's `CS_*` and `CLAUDE_*` variables stayed out of the install. It exited 0 without warnings. The installed `cs` is byte-identical to `bin/cs`; Codex's `hooks.json` registers the PermissionRequest hook and all 13 hooks carry a trusted hash; an unknown hook verb and `permission-request` both answer `{}` with exit 0. No Codex CLI from the profile was running, so none needed a restart.

## Key Files & Outputs

Attribution uses first-parent history since the earliest recorded start, `2026-10-01T12:37:13Z`; imported releases count as merge work, not as this session's commits.

| File or output | Purpose |
|---|---|
| `setup.sh`, `scripts/code-sessions-profile.sh`, `scripts/carry-over.sh` | Profile deployment, launchers, personal-tool carry-over. |
| `scripts/session_transfer.py`, `scripts/cs-to-code-sessions.py`, `scripts/code-sessions-to-cs.py` | Independent copies with recorded synchronization. |
| `scripts/sync-upstream.py` | Release catch-up into the fork's layout. |
| `lib/16-lifecycle.sh`, `lib/76-codex.sh`, `lib/77-codex-hooks.sh`, `lib/78-switch.sh` | Run ownership, Codex launch, hooks, the automatic /clear watcher, switching. |
| `lib/01-manifests.sh`, `install.sh.in`, `lib/85-adopt-uninstall.sh` | Hook registration and trust, Codex status line, uninstall. |
| `tests/test_codex_autoclear.sh`, `tests/test_codex_hooks.sh`, `tests/test_codex_launch.sh`, `tests/test_codex_hook_registration.sh` | The automatic /clear: 46, 27, 38 and 5 tests after PR #7's fixes. |
| `docs/codex.md`, `skills/rotate/SKILL.md`, `skills/switch/SKILL.md`, `docs/migration.md` | User-facing behaviour of the count, switching and copies. |
| `.cs/plans/2026-10-05-engine-neutral-skills.md` | Master plan; its "Codex automatic /clear" section now records the review fixes. |
| Scratchpad `ffcb29b8/.../fix-review-7/` | Review text, verify and fix workflow results, gate logs, round-up draft. |
| Scratchpad `ffcb29b8/.../setup-2026-10-19.log` | The deploying `setup.sh` run. |

## Outcome

The session produced the isolated code-sessions fork, shared Claude/Codex manager features, upstream catch-up, independent session copies and a reviewed Codex integration. PRs #1, #2, #4, #6 and #7 merged into the fork's main (#7 as `4bad6ee6` on 2026-10-19, carrying #5 and #8, which had merged into `code-sessions`). PR #7's review findings were all answered before it merged:

| Finding group | Result |
|---|---|
| B1, R1-R6, N1-N9 | 16 fixed, each with a failing test or mutation proof first |
| B1's switch paragraph | Fixed differently than proposed (the review's premise was wrong) |
| Q1 | Already satisfied by the docs and skills |
| Extras | PermissionRequest hook; five follow-ups from the independent review |

Gates on `dcba7749`: `run_all.sh` 94/94 on macOS (also 94/94 on `0c5e9210` before the merge); Ubuntu 24.04 container, nine touched suites green, `test_install` 92 passed with 14 interactive-prompt skips; ShellCheck 0.11.0 129/129; `build.sh` leaves the generated files unchanged; the fork's CI green on all six jobs. The review worktree is removed, and the profile now runs `dcba7749`.

## Notes for Future Reference

- Never install from `~/Documents/cs/code-sessions`: its older installer would keep PR #7's PermissionRequest hook registered while its old `cs -codex-hook` exits 2, which Codex reads as a denial of every approval. Deploy with `sh setup.sh` from this profile copy; running it from a conversation, `env -i` with a minimal environment keeps the session's variables out.
- Anything cs's trusted side acts on (typing keys, quitting, relaunching, choosing permissions) must come from outside the Codex workspace, `/tmp` and `$TMPDIR`; the per-run directory under `CS_CACHE_DIR` is the pattern. Every Codex hook verb must exit 0 on every path.
- A native-approval run never gets an unattended `/quit` toward a switch; if the user wants only native-to-automatic blocked, that is a one-line change in `_codex_autoclear_action` plus its tests.
- Not done: a sweep for empty `codex-runs` directories a SIGKILLed run leaves; the tmux fallback where TIOCSTI is refused; doctor rows for the Codex hooks; vault-backed `CODEX_HOME` (Codex is still refused on encrypted sessions); the deferred Codex subagent customization; a guard that keeps `run_all` from writing to the real keychain (an open task).
- Fork PRs need `-R Gherghi67/code-sessions` and the Gherghi67 token on every `gh` call; check `git ls-remote` before pushing, since other conversations push to `code-sessions` too.
- Docker Desktop may be stopped; `open -a Docker` and wait for `docker info`. Native arm64 `ubuntu:24.04` runs the suites faster than amd64 emulation.
- When a launch seems to forget its engine, look for a near-miss session name in the shell history first.
- The project copies stay independent while personal-tool links stay shared by the user's choice; rerun a base-level copy after source sessions close to bring later changes.
