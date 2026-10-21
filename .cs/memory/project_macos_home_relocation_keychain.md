---
name: project-macos-home-relocation-keychain
description: Never isolate a Claude/Codex profile by relocating HOME on macOS; the login keychain resolves through HOME, so Claude Code cannot save its OAuth login. Isolate through per-tool directory variables, and register hooks by absolute path.
metadata:
  type: project
---

On macOS, a process started with HOME pointed at a directory that has no `Library/Keychains`
sees no login keychain at all. Claude Code then fails its OAuth login: macOS shows a
"Keychain Not Found: a keychain cannot be found to store '<user>'" dialog (Cancel / Reset To
Defaults), and Claude Code prints "OAuth error: Couldn't save your login". Pressing "Reset To
Defaults" creates or swaps a login keychain and can strand the user's saved passwords, so never
advise it. The same HOME relocation also hides `~/.ssh`, `~/.config/gh`, `~/.npmrc` and similar.

Found 2026-10-02: the experimental `ags` launcher (template `scripts/ags-profile.sh`, now
`scripts/code-sessions-profile.sh`; profile now ~/.local/share/code-sessions/home) exported
`HOME=~/.local/share/agent-sessions/home`. Fixed by keeping HOME and isolating through
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `CS_SESSIONS_ROOT`, `CS_CLAUDE_DIR`, `CS_HOOKS_DIR`,
`CS_TRANSCRIPTS_DIR`, `CS_COMMANDS_DIR`, `CS_SKILLS_DIR`, `CS_INSTALL_DIR`, `CS_CONFIG_DIR`,
`CS_CACHE_DIR` and `CS_SECRETS_DIR`. `tests/test_setup.sh` now asserts the launcher keeps HOME.

**Why:** isolation via config-dir variables keeps the keychain and credentials working, but
anything still spelled with `~` or `$HOME` then points at the user's stable install.

**How to apply:** for any profile or sandbox around Claude Code or Codex, never set HOME.
Register hook commands by absolute path (`CS_HOOK_PATHS=absolute` at install time), since a
`~/.claude/hooks/cs/...` command would run the stable install's hooks. Route every
`$HOME/.claude/...`, `$HOME/.cache/cs`, `$HOME/.local/bin` read through its override variable,
especially destructive ones: the legacy auto-memory migration copies then deletes its source.
Related: [[session-narrative-gherghinabogdan7-gmail-com]].
