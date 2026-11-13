# Contributing to cs

Practical guide for adding hooks, commands, and other contributions to cs.

## Development Setup

```bash
git clone https://github.com/hex/claude-sessions.git
cd claude-sessions
```

The `cs` command is **assembled** from ordered fragments in `lib/*.sh` into the
single `bin/cs` that ships. **Edit the `lib/` fragments, never `bin/cs` directly**,
then rebuild and commit the regenerated `bin/cs`:

```bash
./build.sh   # concatenates lib/*.sh (in numeric-prefix order) into bin/cs
```

CI rebuilds and fails if the committed `bin/cs` is out of sync with `lib/`. Each
fragment has a numeric prefix (`00`, `05`, …, `99`) that fixes its position; the
`bin/cs` blob stays byte-identical whether you edit a fragment or the assembled
file, so a build is transparent. Hooks live in `hooks/`, skills (the former
slash commands included) in `skills/`, and tests in `tests/`.

This checkout is code-sessions, a fork of cs that follows hex/claude-sessions.
It keeps upstream's names: the command is `cs`, its companions are `cs-*`, and
it builds to `bin/cs`. `setup.sh` installs it into a profile of its own and puts
the launchers `code-sessions` and `ccs` on PATH, so `cs` on PATH stays the
original; `lib/00-header.sh` marks the build with `CS_FORK`. Shared workspace/storage/context
fragments and namespaced adapter fragments are described in
[Engine adapters](docs/engine-adapters.md). Keep native configuration and parsers
inside their adapter; build.sh still produces a standalone shell executable.

## Running Tests

Tests use a shared library (`tests/test_lib.sh`) that provides assertions, temporary directories, and test isolation.

```bash
# Run all tests (aggregates per-suite results and exits non-zero on any failure)
bash tests/run_all.sh

# Run a single test file
bash tests/test_hooks.sh

# Run the suites one at a time, streaming each one's output live
CS_TEST_JOBS=1 bash tests/run_all.sh

# Run the Rust TUI tests
cargo test --manifest-path tui/Cargo.toml
```

`run_all.sh` runs several suites at once by default and replays their output in
the order a serial run would have printed it, so the concurrency is invisible
unless something fails. It announces its plan first (`running 57 suites at 10
jobs`); the lane count is what explains the wall time. While it runs, each
suite prints one line to stderr as it finishes (`[12/57] test_queue.sh 4s`,
with `FAIL` appended when it failed), so a slow gate and a hung one look
different. The report ends with the ten slowest suites and their seconds,
then every skipped test (see below), then the verdict.
`CS_TEST_JOBS=1` runs them one at a time and streams each suite's output as it
happens, which is what you want when bisecting a failure inside a single suite.

The lanes default to half the cores on a workstation (a runner with four cores
or fewer keeps them all) and every suite runs under `nice -n 10`, so a gate
leaves the machine usable while it runs. One gate per checkout: a second
`run_all.sh` started while one is running refuses with the holder's pid and
exits 3 (`tests/.run_all.lock`; a lock whose pid is dead is taken over).

The lanes take suites from one queue, longest file first, so a lane that
finishes picks up the next suite rather than waiting on a fixed share.
`CS_TEST_SHARD=N/M` runs shard N of M, balanced by line count; CI runs the bash
suites as two shards per OS. A suite that runs long for its length carries a
`# run_all-weight: N` line and counts as N times its lines, as `test_install.sh`
does with 2.

The gate stops a suite that runs past 1200 seconds, along with its child
processes, counts it as failed and names it in a `timed out after 1200s` line;
the other suites still run. The slowest suite, `test_install.sh`, takes about 600 seconds on a loaded machine.
`CS_TEST_SUITE_TIMEOUT` sets the cap in seconds.

### Skipped tests and the tools a test needs

A test that returns 77 skips: the suite counts it apart
(`Results: 40/42 passed, 0 failed, 2 skipped`) and still passes. Return 77 when
the machine cannot build the test's fixture, such as a privilege, a filesystem
or a bash version it lacks. Never return 0 from a skip: that counts as a pass.

A test that needs a command guards it with `require_tool`, never with its own
`command -v` (`test_docs.sh` fails on the common hand-written `command -v`
guards, though not on every shape a guard can take):

```bash
test_mod_unit_tests_pass_under_bun() {
    require_tool bun || return $?
    ...
}
```

`require_tool <tool>...` returns 0 when every tool is on `PATH`. It checks
every tool before it answers. A missing tool that `CS_TEST_REQUIRE_TOOLS`, a
space-separated list, names fails the test with `FAIL: <tool> is not on PATH,
and CS_TEST_REQUIRE_TOOLS says this run has it`. Otherwise the missing tools
skip the test with `SKIP: <tools> not on PATH`. CI sets the list to the tools
its job installs, so a runner that lost one goes red instead of skipping the
tests that need it. Locally the list is unset and a missing tool only skips.
Call `require_tool` directly, never inside `$( )`, and pass its status through
unchanged: call a helper that wraps it as `_need_expect || return $?`, not
`|| return 77`.

`run_all.sh` lists every skipped test above the verdict, with its suite and,
for a missing tool, the tool, and the verdict counts them:

```text
skipped tests:
  test_mod_rotate.sh: test_mod_unit_tests_pass_under_bun (bun not on PATH)
  test_queue.sh: test_queue_add_fails_when_the_task_cannot_be_written

================================================================
OK: all 63 suites passed, 2 tests skipped
```

### Which tests to run, and when

The full gate takes minutes. Most of the time you do not want it.

| Situation | Run |
|---|---|
| Red/green loop on one file | that file's suite alone, roughly a second or two |
| About to commit | `bash tests/run_all.sh --changed` |
| About to merge, or cutting a release | `bash tests/run_all.sh` |
| About to push a shell change | `bash tests/lint_shell.sh` (the shellcheck lane CI runs; a full `run_all.sh` runs it too, and `--changed` runs it for a change to the lint, its baseline or its suite, and when a change sends `--changed` to the full gate) |
| Waiting for a GitHub Actions run on `main` or a release tag | `bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]` |

`tests/lint_shell.sh` fails on any shellcheck error, and on a warning count that differs from
`.shellcheck-warnings`. It runs shellcheck once per file under `nice -n 10`, as many at once as the machine has
processors, and stops with exit 2 naming any file shellcheck could not run on. The count is measured with the shellcheck version CI pins in
`.github/workflows/test.yml` (v0.11.0); another version can count differently. When you fix
warnings, lower that number in the same commit.

The suite `tests/test_lint_checkout.sh` runs the lint on the checkout, so a full `run_all.sh` fails
when the lint fails. It judges only at the pinned version. Any other shellcheck skips the test, and
`run_all.sh` names both versions in its skip list. A missing shellcheck skips it through `require_tool`.
When `CS_TEST_REQUIRE_TOOLS` names shellcheck, another version or a missing shellcheck fails the test instead.
A `SHELLCHECK_VERSION` in `test.yml` that is not one `vN.N.N`, and a shellcheck that reports no version, fail it in every run.
CI's bash jobs have no shellcheck at the pinned version, so they skip it and CI's `shellcheck` job does
the linting there.

Use `tests/ci_wait.sh` for runs on `main` and release tags, with an authenticated
`gh`, `jq`, and Git. On a pull request, a newer push intentionally cancels the
older run through `test.yml`'s `cancel-in-progress`. The script could rerun that
intended cancellation, so do not use it for pull-request runs.

It waits until the run completes and every job has a conclusion, then prints each
job's conclusion, step count, and name. `CI_WAIT_INTERVAL` sets the poll interval
in seconds, with a default of 30; use one or more digits.
When a `gh run view` call fails with an HTTP 5xx, or with a network error such as
a TLS handshake timeout, a dropped connection (`unexpected EOF`, `connection reset
by peer`), an I/O timeout, a failed DNS lookup (gh prints `error connecting to
<host>`) or a proxy's `Bad Gateway`, the script tries it twice more,
one poll interval apart, and prints a `retrying:` line before each try; a third
failure exits 4. The script never retries a failed `gh run rerun`, since a server
or network error does not prove the rerun did not start.

The script reruns failed jobs only when at least one job has a `cancelled`
conclusion and zero steps. Every other non-success job must have a `cancelled`
or `skipped` conclusion and zero steps.
It prints a notice while waiting for a higher attempt number before judging the
rerun. If the attempt has not increased on the 21st stale read, it exits 4.
The default limit is three reruns; `--max-reruns N` changes it, and 0 disables reruns.

After every job succeeds, the script fetches the logs once and prints each job's
last skipped-test block, including missing-tool reasons, or `skipped tests: none`.
Every job must have a log line. A skip block must end with a blank line followed
by the 64-character `=` rule that `run_all.sh` prints. Logs with Windows line
endings work too.
A job that runs `bash tests/run_all.sh` must include its
`OK: all <N> suites passed` verdict. The verdict's skipped-test count must match
the number of lines in that job's skip block. A verdict without a skip count
means zero skips, so it needs no skip block. A missing verdict or a count mismatch
exits 4, naming the job and both counts.
`--since <rev>` compares the sets of `run_test` names in each suite at that revision
and the run's `headSha`, using the same file path in both trees. The comparison
works from the repo root or a subdirectory. Moving a registration within its
suite does not add it, and removing one does not add it either.
A renamed suite counts all its registrations as added. A skipped registration
added in that range stops the release.
The script resolves `--since` before calling gh and checks that the run's
`headSha` exists locally before waiting.
Read the rest of the skip list for checks the range depends on; the script cannot
judge those dependencies.

| Exit | Meaning |
|---|---|
| 0 | Every job succeeded, with no skipped registration added in the requested range. |
| 1 | A job failed, has another non-success conclusion that does not qualify for an infrastructure rerun, or the completed run has no jobs. |
| 2 | Invalid arguments, an unresolvable `--since` revision, or an invalid `CI_WAIT_INTERVAL`; read the usage line. |
| 3 | Infrastructure cancellations persisted through the rerun limit. |
| 4 | A command failed, the run JSON was invalid, a log or verdict check failed, the run's head was missing locally, or a rerun never appeared. Read the error; fetch a missing head before retrying the same run. |
| 5 | A test registration added since the requested revision appears in the skip list. Investigate each skip before tagging. Record skips CI produces by design in the session narrative (`.cs/memory/narrative.<actor>.md`) and name them to the user before Step 9 of `.claude/commands/release.md`. Never edit approved release notes; fix any other skips before tagging. |

`--changed` reads the working tree against `HEAD` plus untracked files and runs
only the suites whose text names a changed path (a changed suite runs itself).
Three kinds of change have no honest subset and run the full gate: anything
under `lib/` or `bin/cs` (assembled from every fragment, invoked by most
suites), `tests/test_lib.sh`, and a source path no suite names. Session state,
docs and config (`.cs/`, `docs/`, the top-level `*.md`, `.github/`) are ignored
either way; skill and command markdown counts as source.
`CS_TEST_CHANGED` (one path per line) replaces the git-derived list.

Order the gates so the cheap ones run first. A full sweep before a quick manual
check that could send you back to the code is a sweep you pay for twice.

### Run a single suite under both bash versions

```bash
/bin/bash tests/test_foo.sh   # 3.2 on macOS: the floor, and what CI pins
bash tests/test_foo.sh        # 5.x if Homebrew is on PATH: what run_all spawns
```

`run_all.sh` launches suites with a bare `bash`, so on a dev box with Homebrew
the gate runs them under 5.x while a hand-run `/bin/bash tests/...`
uses 3.2. The two disagree — `local x` leaves `x` unset under 4.4 and later,
where `set -u` then aborts the suite, and 3.2 accepts it — so a suite can pass
alone and abort under the gate, or the reverse. Checking both takes seconds and
catches the whole class.

Every bash suite under `tests/` plus the Rust TUI tests must
pass before submitting changes; CI (`.github/workflows/test.yml`) runs them on
every push and pull request. Do not use a bare `for f in tests/*; do bash "$f";
done` loop — its exit status reflects only the last suite, so failures are
masked; `run_all.sh` reports every failing suite.

## Adding a Hook

1. **Create the hook script** in `hooks/your-hook.sh`. Copy an existing hook (e.g., `hooks/tool-failure-logger.sh`) as a starting template.

2. **Register it**:
   - Add the filename to the `CS_HOOKS` array in `lib/01-manifests.sh`, then run `./build.sh`, which folds it into `bin/cs` and splices it into `install.sh` (deploy, flat-layout cleanup, registration stripping, uninstall and doctor all derive from it)
   - Add a `_merge_cs_hook <Event> your-hook.sh <timeout> [matcher] [async]` call in `install.sh.in` alongside the existing ones (see the block around its `_merge_cs_hook SessionStart ...` calls) to register it in `settings.json` under the appropriate event (`SessionStart`, `PreToolUse`, `PostToolUse`, etc.); it derives the deploy and `~`-relative paths from the filename
   - If cs has no hook under that event yet, add the event to `CS_HOOK_EVENTS` in `lib/01-manifests.sh`: the installer reads it to refuse a `settings.json` whose value for one of those events is not a list, and `tests/test_install.sh` fails until it names every event `_register_cs_hooks` registers under

3. **Never edit `install.sh` or `bin/cs` by hand** — `./build.sh` writes both. `tests/test_install.sh` fails if the committed built files differ from the build or the array disagrees with the actual contents of `hooks/`.

4. **Document in `docs/hooks.md`** — add a section following the existing format: hook name, event type, description, and behavior.

5. **Write tests** in `tests/` — create a test file or add to an existing one. Use `test_lib.sh` for setup/teardown.

## Adding a Skill

cs ships no slash commands: a skill answers `/name` in Claude Code and is the
one format Codex reads too. The four former commands (`checkpoint`, `summary`,
`sweep`, `wrap`) are skills, and `RETIRED_COMMANDS` in `lib/01-manifests.sh`
lists the command files the installer and uninstaller delete.

1. **Create `skills/name/SKILL.md`** with the skill's frontmatter (`name`, `description`, and `allowed-tools` with the hyphen if it needs one — Claude Code ignores the `allowed_tools` underscore form) and instructions. Copy an existing skill (e.g., `skills/store-secret/`) as a template.
   - Reach a helper the skill ships through its own directory (`scripts/x.sh` relative to the folder the SKILL.md was loaded from) or a `cs` verb, never a `~/.claude/...` path: under the code-sessions profile that path is the original cs install, and under Codex it is no install at all. List each helper in `CS_SKILL_FILES`. `tests/test_commands.sh` fails on a `~/.claude/` path in any SKILL.md.
   - Before relying on an adapter feature (rotation, a spawned session's brief, mail delivery, the memory index at session start), check `cs -engine supports <capability>` and refuse cleanly when it fails.
   - Read the skill's arguments from the user's message, the one that invoked it. Codex and Antigravity substitute no arguments placeholder, and Claude Code replaces one wherever the file spells it, so `tests/test_commands.sh` fails on the placeholder's name in any SKILL.md.
   - A skill only the user may start sets `disable-model-invocation: true`, which Claude Code and Antigravity read. Codex accepts that key and ignores it, so ship `agents/openai.yaml` beside the SKILL.md with `allow_implicit_invocation: false` under `policy:`, and list it in `CS_SKILL_FILES` (see `skills/finish/`). `tests/test_commands.sh` fails when the pair is incomplete.

2. **Add the directory name to the `CS_SKILLS` array** in `lib/01-manifests.sh`, then run `./build.sh` — install, `run_uninstall()`, and doctor all loop over it. The installer copies the same files into each selected engine's skills directory: `~/.claude/skills/` for Claude, `$CODEX_HOME/skills/` (default `~/.codex/skills/`) for Codex, and, wherever `agy` is, `skills/` in cs's Antigravity plugin (`~/.gemini/config/plugins/cs/`). `tests/test_install.sh` fails if the array disagrees with the `skills/` directory contents.

## Code Style

- Match the style of surrounding code.
- Every code file starts with a 2-line `ABOUTME:` comment explaining what the file does:
  ```bash
  # ABOUTME: PostToolUseFailure hook that logs failed tool calls for debugging
  # ABOUTME: Writes tool name, error, and timestamp to the session log (.cs/local or .cs/private)
  ```
- No emojis in code or documentation (unless part of a functional emoji set).
- No temporal names (`NewAPI`, `LegacyHandler`, `ImprovedParser`). Name things for what they do, not their history.
- Test output must be clean. If a test intentionally triggers errors, capture and validate them.

## Merging upstream releases

code-sessions follows hex/claude-sessions, which often ships several releases a day. They are merged one at a time, each onto the one before it, by `scripts/sync-upstream.py`: on GitHub by a workflow, or by hand.

### The workflow

`Sync upstream` (`.github/workflows/sync-upstream.yml`) runs four times a day, and when started by hand with `gh workflow run sync-upstream.yml`. Each run takes the oldest release `main` lacks:

- One that merges with nothing left for a person is pushed as `cs/sync-<tag>` and gets a pull request, set to merge itself with a merge commit once its required checks pass. The workflow runs no tests: `Test` on the pull request is the gate.
- One that merges cleanly but changes a file under `.github/`, or `scripts/sync-upstream-ci.sh`, is not pushed: a branch pushed to this repository runs its own workflows at once. It gets an issue, `Sync upstream <tag> needs a person`, that lists those files, shows how to read the change, and gives the one command that approves exactly that release, `gh workflow run sync-upstream.yml -f approve=<tag> -f commit=<id>` (with `--repo` naming this repository, so it works from a checkout whose `origin` is upstream). Read the change, then run it. That run merges the release again, checks that the tag still points at the commit you read, pushes `cs/sync-<tag>` and opens the pull request, which merges itself or waits like any other; the issue closes once `main` contains the release. It fails by name, pushing nothing, if upstream has moved the tag since, or if an older release is still missing. About one release in three changes a workflow.
- One that needs a person gets an issue, `Sync upstream <tag> needs a person`, with the script's report. Merge it by hand (below), push the result as `cs/sync-<tag>` and open a pull request. The workflow closes the issue once `main` contains the release.
- One that already has a pull request from this repository's `cs/sync-<tag>` branch, that branch alone, or an open issue labelled `sync-upstream` is left to whoever has it (the run that approves a release goes past its issue), and the later releases wait behind it. The workflow puts that label on each issue it opens. A pull request from a fork's branch of the same name does not count, and neither does an issue without the label: anyone can give an issue that title, but only someone with triage access can label it.
- One whose sync pull request was closed without merging fails every run by name. A release cannot be skipped, since each sync merges onto the one before it: reopen the pull request, or merge the release by hand and land it with a merge commit.
- One held like that for longer than `SYNC_STALL_DAYS` days since it was tagged (a repository variable, 3 when unset) fails every run by name, saying what holds it: an open pull request, an issue nobody has acted on, or a branch with no pull request, which a run that stopped between the push and the pull request leaves behind. The run does the rest of its work first, closing the issues it can.

Each pull request and issue ends with the script's report. Upstream writes part of it (file names, and what its `build.sh` prints to stderr), so it comes after everything the workflow has to say, in a code block none of its lines can close. A report too long for GitHub's limit on a body (65,536 characters) is cut at about 20,000 bytes, with a line that links the run whose log holds all of it.

It needs these set up once in the repository:

1. An environment named `upstream-sync`, limited to the `main` branch (Settings, Environments, "Deployment branches and tags"), holding a secret named `UPSTREAM_SYNC_TOKEN`: a fine-grained personal access token for this repository alone, with read and write access to Contents, Pull requests, Issues and Workflows. Store it with `gh secret set UPSTREAM_SYNC_TOKEN --env upstream-sync`, which asks for the value. The token GitHub hands a workflow run cannot do this: a push or a pull request made with it starts no workflow, so `Test` would never run on the sync pull request. Workflows is needed because an approved release, or any release under `SYNC_AUTO_MERGE=all`, may change a file under `.github/workflows`.
2. "Allow auto-merge" in the repository's settings.
3. A ruleset on `main` that requires the eight `Test` checks (`bash` on both systems in two halves each, `build-sync`, `shellcheck`, `rust` on both systems) and allows merge commits only.
4. Issues switched on (`gh repo edit --enable-issues`, or Settings, General, Features). A release that needs a person is reported as an issue; while Issues are off, every run fails by name before it merges anything. The workflow creates the `sync-upstream` label itself, with the token's Issues permission, before it opens an issue.
5. "Automatically delete head branches" (`gh repo edit --delete-branch-on-merge`), so each merged `cs/sync-<tag>` branch is removed instead of staying behind.
6. Once the workflow is on `main`, `gh workflow list --all` showing `Sync upstream` as active. GitHub can leave a fork's scheduled workflows switched off; `gh workflow enable sync-upstream.yml` switches it on.

Without the second and third, GitHub refuses auto-merge: the pull request stays open and the workflow comments on it with the command to merge it by hand. The repository variable `SYNC_AUTO_MERGE` changes the rule: `false` has every sync pull request wait for a person (one that changes `.github/` or the script still needs the approval before it is pushed), and `all` pushes those without approval and lets them merge themselves too. Unset or `true` keeps the rule above. Case does not matter, and any other value counts as `false`, with a warning on the run, so a typo never leaves auto-merge on.

The token is kept away from upstream's code until a person has read what could reach it:

- The workflow has two jobs. `merge` runs the script, and with it `build.sh` from the merged tree, which is upstream's code before anyone has looked at it; that job gets no secret and a token that can only read. `publish` has the sync token and runs nothing the first job produced: it takes the merge commit out of a git bundle, refuses it unless it merges exactly its own checkout of `main` with the release as it fetches it from upstream, reads what it changes against that checkout, and hands it to `git push` and `gh` (`scripts/sync-upstream-ci.sh` is both jobs' script).
- A branch pushed to this repository runs its own workflows at once, with whatever token permissions they declare, before anyone has read them. That is why a release that changes a file under `.github/`, or the script `publish` runs, is not pushed until a person has read that part and approved it, unless `SYNC_AUTO_MERGE` is `all`.
- An approved sync branch still runs its workflows for the pull request before it is merged. A secret of the repository would be in their reach; one in an environment only `main` may use is not, which is why the token is stored there. Once merged, a workflow runs on `main`, where the environment's secret can be read; by then the person who approved it has read it.

Upstream's tags are fetched and never pushed: a `v*` tag on the fork would start its release workflow.

### By hand

Upstream is the remote named `origin`; `--remote <name>` before the command, or `SYNC_UPSTREAM_REMOTE`, names another.

```bash
scripts/sync-upstream.py status       # the releases this branch lacks, oldest first, and what the next one conflicts in
scripts/sync-upstream.py catch-up     # merge them in order
# it stops at the first release that needs a person; resolve it in the sync worktree it prints, then, there:
scripts/sync-upstream.py continue
scripts/sync-upstream.py catch-up     # back in this checkout: lands that one and goes on with the rest
```

`status` fetches, lists the missing releases and dry-runs the next merge without writing anything; it exits 1 while a release is missing, so a script can use it as a check (`--brief` skips the dry run, and `missing` prints only the tags, oldest first). `catch-up` merges each missing release on its own: one that needs no person is built, tested, committed and fast-forwarded into this branch, and its worktree removed. To merge a single release by hand instead:

```bash
scripts/sync-upstream.py start        # newest v* tag on origin/main; --to <tag> for another
# resolve what it reports in the sync worktree it prints, then, there:
scripts/sync-upstream.py continue
git merge --ff-only sync/<tag>        # back in this checkout
```

Commit your work first: the merge starts from the last commit, and git only recognises a moved file once it is committed. A cs session's own notes under `.cs/` do not count, since they change while the session is open. `start` makes a worktree beside this checkout (outside any repository that encloses it) on a `sync/<tag>` branch and records a real merge with both parents. Before merging, it rewrites upstream into this fork's dialect, so the fork's reshaping does not conflict:

- Variables: `$CLAUDE_SESSION_*` becomes `${CS_SESSION_*:-${CLAUDE_SESSION_*:-}}`, on the lines the fork rewrote and the lines upstream adds; a line the fork kept stays as upstream wrote it. A default is kept whatever it nests (`${CLAUDE_SESSION_NAME:-${dir##*/}}` becomes `${CS_SESSION_NAME:-${CLAUDE_SESSION_NAME:-${dir##*/}}}`). Command names are upstream's on both sides and need no rewriting.
- Functions: a function the fork keeps in another `lib/` fragment gets upstream's change there.
- Files: an upstream file the fork moved (`commands/*.md` to `skills/*/SKILL.md`) merges into the moved file. A file upstream renamed takes the new name in the fork, with the fork's changes merged into it.
- Generated files (`bin/cs`, `hooks/cs-shared.sh`, `install.sh`) are never merged; `continue` rebuilds them.

Prose (README, `docs/`, CHANGELOG) merges plainly, since the fork's prose is its own. What is left is where both sides changed the same lines, which get conflict markers, and what no marker can show, which `start` lists under "Check by hand":

- A line upstream added that reads a session variable through an operator (`${CLAUDE_SESSION_NAME//@/+}`, `${CLAUDE_SESSION_DIR%/}`). Bash applies an operator to one variable, so there is no `CS_`-first form of it; make the statement read one family of variables.
- A line of the fork's own that still names a file upstream renamed.
- A file that is not text and changed on both sides, or was deleted on one side and changed on the other.

`start` exits 0 once the merge is committed, 1 when it waits for a person for either reason, and 2 on an error. `continue` refuses while a conflict marker remains or a function is defined in two fragments, then runs `build.sh` and `tests/run_all.sh` (`--skip-tests` skips them) and commits. Nothing is pushed. When the fork rewrites another upstream form, add the rule to `rename()` in the script so the next merge applies it.

Land upstream-sync pull requests with a merge commit, preserving the sync commit's upstream parent. Squashing or rebasing loses release ancestry and makes the next sync offer releases already integrated.

## Releasing

Releases are managed via the `/release` slash command. See `.claude/commands/release.md` for the full checklist, which covers version bumps, changelog, signing, and GitHub Release creation.
