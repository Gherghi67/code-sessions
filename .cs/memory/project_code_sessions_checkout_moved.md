---
name: project-code-sessions-checkout-moved
description: "Since 2026-10-14 the code-sessions repo work happens in the fork profile's copy of this session (<profile>/sessions/code-sessions, own .git); ~/Documents/cs/code-sessions is a stale stable-cs copy, and setup.sh must run from the profile copy."
metadata:
  node_type: memory
  type: project
  modified: 2026-10-16T09:15:12.748Z
  originSessionId: ffcb29b8-ff69-4fd2-9cfd-82c035b7610d
---

The session moved into the fork on 2026-10-14 (the copy tool made `/Users/bogdan.gherghina/.local/share/code-sessions/home/sessions/code-sessions`,
a real folder with its own .git). Work since (PRs #4 fixes, #5, #6, #7) was committed there and pushed to
Gherghi67/code-sessions. `~/Documents/cs/code-sessions`, the stable-cs copy, stayed at bcaeca65.

**Why:** on 2026-10-15 a `setup.sh` run from the Documents checkout installed bcaeca65 into the profile, without
PR #4's security fix and PRs #5 and #6, and nothing said so.

**How to apply:** build, install (`sh setup.sh`) and commit from the profile copy; fetch the fork before working
(`git fetch https://github.com/Gherghi67/code-sessions.git main code-sessions`), since another conversation or
Codex may have pushed. Treat the Documents copy as read-only history unless the user says otherwise.
Since PR #7's fixes (dcba7749) an older install is worse than missing fixes: its installer keeps the new Codex
PermissionRequest hook registered and its old `cs -codex-hook` default arm exits 2, which Codex reads as a
denial of every approval.
Related: [[project-wap-copied-into-code-sessions]].
