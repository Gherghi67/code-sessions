---
name: project-bash32-heredoc-fails-in-codex-sandbox
description: "macOS /bin/bash 3.2 writes every here-string and here-document to a temp file, which Codex's read-only sandbox refuses; a loop fed that way silently reads nothing, so a session-manager verb a skill runs as a probe must not use them."
metadata:
  node_type: memory
  type: project
  originSessionId: 004de3c1-dc50-4979-a4c0-4481d347cba1
  modified: 2026-10-05T12:22:24.407Z
---

Found 2026-10-05 in a live ags Codex session (launch runs `sandbox_policy: read-only`,
`approval_policy: on-request`): `ags -engine supports rotation` printed "ags: line 1670: cannot create
temp file for here document: Operation not permitted", and `cs_engine_supports`' `done <<< "$capabilities"`
loop read zero capabilities, answering "not supported" for everything. Fixed with a whole-line `case`
match. Bash 5.1+ pipes short here-strings, so the bug hides wherever a newer bash runs. Codex then asked
the user to escalate, which is how it surfaced.

Reproducing it: `sandbox-exec -p '(version 1)(allow default)(deny file-write*)(allow file-write* (literal
"/dev/null"))' /bin/bash -c 'cat <<< hi'`. Denying only /tmp and /var/folders is NOT enough: bash 3.2
falls back to /var/tmp. `codex sandbox -P :read-only -C <dir> -- <cmd>` replays Codex's own policy.

**Why:** the capability probe gates every engine-dependent skill; a false negative there makes a working
adapter feature refuse under Codex, and nothing in the exit code shows why.

**How to apply:** any fork verb (`cs -engine ...`; `ags -engine` before the rename) a skill calls as a read-only check stays free of `<<<`, here-documents and
mktemp; prefer `case` matches and printf. tests/test_engine_adapters.sh
`test_engine_verb_supports_answers_without_temp_files` guards the probe; add the same sandbox-exec test
for any new read-only verb a skill calls. Related: [[project-codex-cli-test-gotchas]].
