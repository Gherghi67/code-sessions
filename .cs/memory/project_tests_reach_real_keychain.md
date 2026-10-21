---
name: project-tests-reach-real-keychain
description: "On macOS a test that runs the real bin/cs-secrets with the keychain backend writes the developer's login keychain; use test_lib's use_fake_keychain. The copy scripts scrub CS_*, so CS_SECRETS_BACKEND or CS_PLATFORM_OVERRIDE in a test does not protect."
metadata:
  node_type: memory
  type: project
  originSessionId: 1d37927d-822c-485c-ad40-895066b1f99c
  modified: 2026-10-09T15:50:08.000Z
---

Found 2026-10-09 when the fork's profile moved from the encrypted secrets store to the keychain
(code-sessions:<session>:<name>). The copy-script suites copy the real bin/cs-secrets into a fixture profile, and
the scripts call it through session_transfer.scrubbed_env(), which drops every CS_* variable. Once the profile
env stopped forcing CS_SECRETS_BACKEND=encrypted, those calls would have used /usr/bin/security against the login
keychain of whoever runs the tests.

**Why:** a test run would have created or deleted real keychain items under code-sessions:* or cs:* names.

**How to apply:** any test that reaches cs-secrets with the keychain backend calls `use_fake_keychain` (tests/test_lib.sh:
a file-backed `security` first on PATH; teardown restores PATH; suites that override teardown, like
test_cs_secrets.sh, use a subshell test body). After such work, `security dump-keychain | grep -c
'"svce"<blob>="code-sessions:'` before and after the run should not change. Related: [[project-secrets-suites-fail-locally]].
