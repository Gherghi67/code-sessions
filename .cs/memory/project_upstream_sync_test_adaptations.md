---
name: project-upstream-sync-test-adaptations
description: "Merging an upstream cs release into the fork (code-sessions, formerly ags): upstream tests read claude_session_id from state right after a stubbed launch, but the fork only stages it (pending-binding-claude.json) until SessionStart; the fork asks the resume question only with a terminal; Claude functions live in other fragments; watchdog-only cutoffs can still occur at 4 jobs, so verify the affected suites with lower concurrency before changing lib. Adapt the tests, not lib."
metadata:
  node_type: memory
  type: project
  originSessionId: 47477832-c0a9-4412-84cc-7c5790fc195d
  modified: 2026-10-14T20:34:00Z
---

The v2026.10.3 merge (e7e7abf) needed the same few test adaptations about fifteen times; expect them on
every later sync:
- **Staged binding.** A launch stages the new conversation in `.cs/local/pending-binding-claude.json`
  (`candidate_id`); only SessionStart commits it to `.cs/local/state`. Stubs that do not run the hook
  leave state empty, so upstream assertions like "the launch records the conversation" read the
  candidate instead (helpers in tests/test_adopt.sh: `_adopt_launched_id`, `_adopt_acknowledge_launch`).
  test_rotation's `_stub_claude` runs SessionStart only for a rebind (`CS_FRESH_REBIND=1`), and a first
  conversation is not one.
- **Resume question needs a terminal.** The fork takes the default without one (`! cs_interactive`), so
  upstream tests expecting "Continue previous conversation?" need `CS_ASSUME_TTY=1`.
- **Moved functions.** `_exec_fresh_rebind`, `_claude_project_dir` and `_claude_encode_path` live in
  lib/42-claude-state.sh; the migration phases moved to lib/46-claude-workspace.sh (inline code, so
  the sync script cannot relocate it: port upstream's changes there by hand). Tests that source
  lib/40-state.sh for those need 42 too.
- **Claude runs as the fork's child**, never exec'd: vault detach and similar "after exec" expectations
  differ.
- **"The launch wrote state"** (10.4's state-lock tests): the fork writes `engine: claude` after the run
  through the run lease and the state lock, so that line is the write to assert, not
  `claude_session_id`.
- **Watchdog timeouts need separate verification.** At 9 parallel jobs on this machine, 10-12 suites
  hit the 600 s limit during the 10.3 and 10.4 merges and passed alone (test_uuid: 53 s).
  Four jobs reduce contention but do not guarantee the limit: on 2026-10-14, the PR #4 full run
  passed 89 suites while session-copy and worktrees timed out late in their cases without assertion
  failures. A focused run with two workers and `CS_TEST_SUITE_TIMEOUT=1200` passed copy 72/72 in
  596 s and worktrees 126/126 in 456 s. Both complete shell CI jobs subsequently passed.
  Inspect the logs first; a cutoff with continuing successful cases warrants focused verification,
  while assertion failures still need investigation. Start sync `continue` at `CS_TEST_JOBS=4`;
  use fewer workers for verification when the watchdog alone stops a suite.

**Why:** these are design differences of the fork, not merge bugs; changing lib to satisfy the upstream
test would undo the fork's lease and binding model.

**How to apply:** after `scripts/sync-upstream.py catch-up` (or `start`) stops, resolve, run
`continue` in the sync worktree, and classify each failure into one of these before touching lib. The shared test harness must clear the live launcher's session, profile, deployment, run-lease,
and secret-namespace overrides before fixture setup. Earlier leaks wrote test mail and an
`encrypted` tag into a live session; PR #4 added a regression for the profile and run overrides. Related: [[feedback-fork-divergence-via-sync-script]].
