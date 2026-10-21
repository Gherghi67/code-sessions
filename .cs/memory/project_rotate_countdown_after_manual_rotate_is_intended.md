---
name: project-rotate-countdown-after-manual-rotate-is-intended
description: "The cs mod's 20 s auto-/clear countdown after ANY armed handoff, including a /rotate the user ran by hand, is deliberate upstream behaviour; the rotate skill's stale sentence (keystroke is the user's unless CS_ROTATE_FORCE_CTX is set) is fixed in the fork (ags then, code-sessions since 2026-10-09) since 2026-10-05 and still stale in stable cs."
metadata:
  node_type: memory
  type: project
  originSessionId: 1ce6a096-920f-4b79-b0c5-cd5b6c5b1c5d
  modified: 2026-10-05T11:20:00.000Z
---

History on cs `origin/main`: c020a6c (2026-09-16) added the countdown for forced rotations; 8348e72 the same
day fixed "a /rotate the person ran by hand ... started no countdown" as a defect ("an armed handoff always
gets the countdown"); 2026.9.18 made forced rotation default-on at 80% with "the grace is unchanged";
ce8365b records the maintainer's call to keep the countdown. `CS_ROTATE_FORCE_CTX=off` (or `0`) disables
forcing and the countdown; a prompt or key press stops a running count.

**Why:** the skill text (skills/rotate/SKILL.md step 11) contradicts the code, which invites "fixing" the
code; that would reverse an upstream decision.

**How to apply:** treat it as a documentation fix (user chose: the fork only, 2026-10-05). Done in the fork (then ags) on
2026-10-05 (engine-neutral skills Phase 1): step 11 now says forcing is on at 80% by default, the countdown
follows any armed handoff, and only `CS_ROTATE_FORCE_CTX=off`/`0` leaves the keystroke to the user;
tests/test_commands.sh pins it. Stable cs's skill still carries the old sentence. Changing behaviour so
manual rotations wait for the user is a feature change to raise with the user, not a bug fix.
