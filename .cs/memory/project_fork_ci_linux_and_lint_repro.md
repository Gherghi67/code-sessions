---
name: project-fork-ci-linux-and-lint-repro
description: "A green macOS run_all does not prove the fork's ubuntu CI job or its shellcheck gate; reproduce both locally (Docker ubuntu:24.04 with lsof+procps, su -s /bin/bash; pinned shellcheck v0.11.0 darwin binary in the scratchpad) before pushing test or platform-tool changes."
metadata:
  node_type: memory
  type: project
  originSessionId: ff4f73b3-2e9f-4b71-a12d-f4d6aaa582d1
  modified: 2026-10-16T09:15:26.592Z
---

Found 2026-10-10 fixing PR #1 on Gherghi67/claude-sessions: macOS passed every suite while
ubuntu-latest failed four. The causes were platform-only: cs-secrets picks the keychain on its own
only on Darwin (tests now branch on `keychain_is_default` in tests/test_lib.sh), and GNU `stat -f`
means --file-system (use `_file_mode`). shellcheck is not installed on this Mac, so the warning-count
gate (.shellcheck-warnings) also only failed in CI.

Reproducing locally:
- Docker Desktop may be stopped: `open -a Docker`, then wait for `docker info` (about a minute). Native arm64
  `ubuntu:24.04` (no `--platform`) ran the PR #7 suites green on 2026-10-15 and is faster than emulation.
- Docker 29 runs here. `docker run --rm --platform linux/amd64 -v <dir>:/src:ro ubuntu:24.04` with
  apt packages git jq python3 openssl curl tmux sqlite3 file procps lsof. Copy the tree with
  `git ls-files -z | tar --null -T - -cf - | tar -x -C <dir>/repo`, `git init` and commit inside, and
  run the suites as a non-root user via `su runner -s /bin/bash -c '...'`: plain `su -c` runs dash,
  where `${PIPESTATUS[0]}` dies with "Bad substitution".
- Without lsof, test_cs_to_code_sessions' open-session test fails (open_sessions finds cwds via
  lsof); without procps there is no ps. Both are container artifacts, not regressions.
- Fetch the pinned shellcheck (v0.11.0, `shellcheck-v0.11.0.darwin.aarch64.tar.xz` from the
  koalaman releases) into the scratchpad and run `PATH=<it>:$PATH bash tests/lint_shell.sh`. It takes
  about 3 min, past the Bash tool's 2-min default, so run it in the background. For a per-file diff
  against main, lint a `git archive main` copy and compare with line numbers stripped.

**Why:** Linux-only and lint failures otherwise surface only after a push to the PR.

**How to apply:** before pushing a change that touches tests, platform tools (stat, keychain, ps,
lsof) or many shell files, run the affected suites in the container and the lint locally. See
[[project-tests-reach-real-keychain]] and [[project-upstream-sync-test-adaptations]].
