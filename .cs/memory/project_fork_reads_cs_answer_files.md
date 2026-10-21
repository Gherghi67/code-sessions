---
name: project-fork-reads-cs-answer-files
description: "code-sessions still reads stable cs's ~/.config/cs answer files (option-keys, statusline-caps) because those paths use XDG_CONFIG_HOME, not CS_CONFIG_DIR; a declined answer in cs silences the fork's question too"
metadata:
  node_type: memory
  type: project
  modified: 2026-10-09T16:56:38.641Z
  originSessionId: 5ebeb788-991d-4e6b-b9d1-0370b3a2fe07
---

Found 2026-10-09 in a readiness check of the code-sessions fork. The launcher exports
`CS_CONFIG_DIR=<profile>/.config/cs` and keeps HOME. Four call sites still build their path from
`${XDG_CONFIG_HOME:-$HOME/.config}/cs`: `_cs_rotate_wrap_keys_answer_file` (lib/01-manifests.sh,
bin/cs, install.sh) and install.sh's `statusline-caps`. So the fork reads and writes the same files
as stable cs. `~/.config/cs/option-keys` says `no` (declined in stable cs on 2026-10-07), so the
fork's doctor reports "declined" and `sh setup.sh` in a terminal never asks about the Ctrl+X R/W keys.

**Why:** the earlier advice ("run sh setup.sh in a real terminal to bind keys") was wrong for this
reason. A "yes" given in the fork would also land in stable cs's file, and stable cs's next update
would then bind the keys in ~/.claude.

**How to apply:** until those paths honour `CS_CONFIG_DIR` (listed as a known gap in Gherghi67/claude-sessions PR #1),
do not promise that the fork asks its own keybinding or statusline questions. Check for any new
`$HOME/.config/cs` path in an upstream sync. Related: [[project-macos-home-relocation-keychain]].
