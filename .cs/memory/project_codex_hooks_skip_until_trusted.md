---
name: project-codex-hooks-skip-until-trusted
description: "Codex (0.160) silently skips every newly configured hook, plugin hooks included, until it is trusted; the fork (code-sessions, formerly ags) can pre-trust its own hook only by writing hooks.state.<key>.trusted_hash, a sha256 of the hook's compact sorted-key JSON."
metadata:
  node_type: memory
  type: project
  originSessionId: 253ee472-541b-4427-945c-adc332a35890
  modified: 2026-10-05T12:21:59.000Z
---

Measured 2026-10-05 in a sandbox CODEX_HOME (codex-cli 0.160.0, no login), by the Phase 0 subagent of the
engine-neutral skills plan. A hook from `$CODEX_HOME/hooks.json`, from `[[hooks.<Event>]]` in config.toml,
or from an installed plugin's `hooks/hooks.json` starts `untrusted` and does not run; editing a trusted
hook makes it `modified` (skipped again). There is no `codex hooks` CLI; the TUI has a review screen.
Pre-trust without a prompt:

```toml
[hooks.state."<abs source path>:session_start:<group>:<handler>"]   # plugins: "<pluginId>:hooks/hooks.json:..."
trusted_hash = "sha256:<hex>"
```

The hash is sha256 of compact JSON with sorted keys,
`{"event_name":"session_start","hooks":[{"async":false,"command":"...","timeout":600,"type":"command"}]}`,
defaults filled in, `matcher`/`statusMessage` included when set. A predicted hash made the hook run.
The initial native probe did not test multi-handler groups; mixed-group registration, removal and trust-index regressions were added on 2026-10-13. The plan's Phase 0 section has the rest (scratchpad scripts:
rpc.py, hooksum.py).

**Why:** a fork hook registered for Codex would install cleanly and then never fire, with nothing in the
output saying so, so rotation or the narrative reminder would look broken under Codex.

**How to apply:** the fork writes its hook and hash together through `_codex_hooks_register` in
lib/01-manifests.sh (since 2026-10-05; jq -cS + sha256 reproduced Phase 0's recorded hashes exactly, and
tests/test_install.sh `test_codex_hook_trust_hash_matches_codex` pins one of them). Trust is keyed by the
group AND handler positions in hooks.json. Append a group on first install, but replace only the CS handler on reinstall, preserving its matcher and neighboring handlers. On uninstall, remove only the CS handler and renumber later handlers' trust keys; remove the group and shift later groups only when it becomes empty. Include the retained matcher in CS's trust hash, and never grant trust to neighboring user handlers. Re-check the
formula against `hooks/list` after a Codex upgrade. Related:
[[feedback-ags-features-belong-to-session-manager]].
