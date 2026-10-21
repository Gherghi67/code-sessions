---
name: project-secrets-suites-fail-locally
description: "On /Users/bogdan.gherghina, test_cs_secrets.sh (79/84) and test_cs_secrets_concurrency.sh (4/6) failed on an unmodified 2026.10.1; both pass on the fork by 2026-10-09, so compare counts before blaming a change"
metadata:
  node_type: memory
  type: project
  originSessionId: de70438f-72a6-4b58-80d9-e660d664a6ae
  modified: 2026-10-05T07:23:41.459Z
---

On actor gherghinabogdan7-gmail-com's machine (/Users/bogdan.gherghina, macOS Darwin 25.6.0),
`bash tests/run_all.sh` in hex/claude-sessions reports 2/71 suites failed even on a clean
`git archive` export of 2026.10.1 (1f2b3c4): `test_cs_secrets.sh` 79/84 (the encrypted-file store
tests) and `test_cs_secrets_concurrency.sh` 4/6. The cause was not investigated.

**Why:** seen identically on 2026-10-02 and 2026-10-03 across three heads (1f2b3c4, 00126c9,
598441a). None of them touched cs-secrets.

**How to apply:** when those two suites are red on a branch that does not touch `bin/cs-secrets`
or `lib/80-secrets.sh`, compare the pass counts with these. The same counts mean the failures
were already there, not a regression. Report them that way, with the counts. A different count, or any
other suite failing, is real. Recheck the baseline on an unmodified checkout if a release has
landed since. See [[project-fix-review-on-claude-sessions]].

Update 2026-10-09: on the code-sessions fork (8d08066e, then ca5e147a) both suites passed in full
(test_cs_secrets 88/88, the concurrency suite inside run_all 90/90), so the baseline above belongs to 2026.10.1;
a red run now is worth investigating.
