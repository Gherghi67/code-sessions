---
name: project-bash-tool-runs-zsh
description: "On this machine the Bash tool runs zsh: a variable named path clobbers PATH, $var:t etc. are history modifiers (write ${var}:path), unquoted $list does not word-split, a bare =word expands, and grep is ugrep (use -F for literal text); write tool commands defensively."
metadata:
  node_type: memory
  type: project
  originSessionId: 47477832-c0a9-4412-84cc-7c5790fc195d
  modified: 2026-10-06T11:42:46.762Z
---

Hit on 2026-10-05 in the ags session, each costing a retry:
- `for pair in ...; do path=${pair%%:*}; ...` broke every later command with "command not found":
  zsh ties `path` to `PATH`. Use another name (`f`).
- `git show "$r:tests/x.sh"` became `git show HEADests/x.sh`: `:t` is a zsh modifier. Write
  `"${r}:tests/x.sh"`.
- `for f in $files` looped once over the whole newline-separated string. Use `xargs` or
  `while read`.
- `echo =====` failed with "==== not found" (`=cmd` expansion). Quote it or use `'-----'`.
- macOS `cat -A` does not exist; `date -v-3H` is the BSD form.
- `grep` is a shell function running ugrep 7.8, where `$` anywhere in a pattern is an anchor:
  `grep -c 'links="$HOME'` printed 0 for a line that was there (2026-10-06), and a verification
  read it as "missing". Check literal text with `grep -F`.

**Why:** the harness shell is the user's zsh, while repo scripts are bash; commands that look like
bash fail in ways that read as unrelated errors.

**How to apply:** in Bash tool commands avoid those names and forms, or wrap a non-trivial snippet in
`bash -c '...'` or a heredoc'd Python script. Repo scripts are unaffected (they run under bash).
Related: [[project-bash32-heredoc-fails-in-codex-sandbox]].
