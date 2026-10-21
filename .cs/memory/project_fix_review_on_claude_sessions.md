---
name: project-fix-review-on-claude-sessions
description: "/fix-review on hex/claude-sessions: gh pr view finds no PR (head is on the Gherghi67 fork), and its jest/eslint/push-gates steps map to build.sh sync, lint_shell.sh and run_all.sh"
metadata:
  node_type: memory
  type: project
  originSessionId: de70438f-72a6-4b58-80d9-e660d664a6ae
  modified: 2026-10-14T20:34:00Z
---

`~/.claude/skills/fix-review` is written for the game-server repo (jest, eslint,
`scripts/push-gates.sh`, origin = CodeCommit). On hex/claude-sessions:

- **PR lookup.** A branch here tracks `origin/main` (hex), and the PR head lives on the fork, so
  `gh pr view` prints "no pull requests found" and §2 would stop. Find it with
  `gh pr list -R hex/claude-sessions --state all --json number,headRefName` filtered on the branch.
  A code-sessions PR lives inside the fork instead (PRs #1 and #2, head `code-sessions`, base the
  fork's `main`). The fork is now named Gherghi67/code-sessions; it used to be claude-sessions. Pass
  `-R Gherghi67/code-sessions` with the Gherghi67 token to every gh call.
- **Push.** Neither the upstream nor `origin` is pushable. Push to the fork URL by name, as in
  [[user-github-accounts]]: `GH_TOKEN="$(gh auth token --user Gherghi67)" git push
  https://github.com/Gherghi67/code-sessions.git HEAD:refs/heads/<branch>`. Post the round-up
  with the same prefix.
- **Mutation checks in a workflow.** The reviewer should run a trimmed copy of the suite that keeps
  only the `run_test` lines it needs, not the whole file. test_cs_to_code_sessions.sh alone takes
  about 7 minutes (422 s on 2026-10-14). On PR #2 the harness forced a re-reviewer to answer
  mid-run, and it returned "changes" only because its evidence was missing. Two engines working in
  this folder share one index, so agents must commit by pathspec
  ([[project-shared-index-commit-by-pathspec]]).
- **Gates** (what CI's test.yml runs): `bash build.sh`, then `git diff --exit-code` on the
  generated files test.yml's build-sync step lists (bin/cs and its four helpers, both cs-shared.sh
  copies, install.sh; read the list from test.yml, it grows); `tests/lint_shell.sh` with
  shellcheck 0.11.0, which is not installed on this machine (download it to the scratchpad);
  `bash tests/run_all.sh` (`CS_TEST_JOBS=4`; duration varies substantially with load); and
  the touched suites in the Linux container per [[project-fork-ci-linux-and-lint-repro]].
  For watchdog-only cutoffs, inspect the logs and verify the affected suites with less concurrency
  and a sufficient time budget; [[project-upstream-sync-test-adaptations]] records the measured case.
  [[project-secrets-suites-fail-locally]] names two suites that used to be red locally; they
  passed in the 90/90 run of 2026-10-12.

**Why:** found 2026-10-03 running `/fix-review` on PR #12. The skill's literal steps would have
stopped at "no open PR" and then pushed to the wrong remote.

**How to apply:** follow fix-review's triage, test-first and round-up steps as written, and use
these substitutions for its lookup, push and gate steps.
