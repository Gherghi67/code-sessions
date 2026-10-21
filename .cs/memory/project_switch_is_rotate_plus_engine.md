---
name: project_switch_is_rotate_plus_engine
description: "Engine switching in the fork (code-sessions, formerly ags) is decided: `switch` = rotate's handoff + relaunch under the other engine; rotate stays unchanged; no transcript transplant even though a spike proved one works"
metadata:
  node_type: memory
  type: project
  originSessionId: ddcca91c-0ae4-440f-bce4-71296c75474e
  modified: 2026-10-07T13:10:05.573Z
---

On 2026-10-07 the user decided how a session moves between Claude and Codex in ags (now code-sessions): "rotate should be
enough ... we can leave rotate like it is, and switch will act like a rotate and also switch to the other
engine". Planned as Phase 6 of `.cs/plans/2026-10-05-engine-neutral-skills.md`.

**Why:** a same-day spike showed a live-conversation transplant works both ways (ags writes a Claude JSONL
and `claude --resume` accepts it; Codex `thread/inject_items` accepts user/assistant items), but the copy
costs ~50-80k uncached tokens on the first turn of the new engine and depends on two unstable formats. The
user judged the rotate handoff (~4-5k tokens) enough.

Default chosen the same day: every switch starts a fresh conversation from the newest handoff (the
round trip carries the other engine's work forward through it); `--resume` (resume the target engine's last
conversation, then feed it the handoff) is an option, not the default.

**How to apply:** do not propose or build a transcript transplant for `switch`; reuse rotate's handoff
steps without editing rotate, and put the engine change in shared session-manager code (the launcher already waits for
the CLI, so it can relaunch after exit). Subagent conversations stay in the original engine's folder and
are not moved. Built and live-tested 2026-10-07 (f23a6a0c); the verb is `cs -switch` in code-sessions. See [[feedback-ags-features-belong-to-session-manager]].
