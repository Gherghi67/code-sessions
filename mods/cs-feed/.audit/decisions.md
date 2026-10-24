# Feed part 1

The continued brief permits pure observation helpers over an explicit Load in session.ts for gap 1 and gap 6. Hook registration, site, perform, ui.press, timers and draw remain part 2. The implementation keeps the prescribed Session/View registry, immutable transcript indexes and discriminated verdicts.

The original brief rejects malformed stored views. This overrides the sketch's defaulting behavior. Rationale 2.3 overrides sketch comments for step counts, singular output lines and safeguard matching.

Test provenance and observed red/green runs are recorded here as slices finish.

## Settings

All source references below are relative to the authorized feed-arch directory unless a brief is named.

| Test | Source |
|---|---|
| an off session reports raw without changing its view | design/rationale.md:111, raw is on false, not a field set |
| the file switch accepts only its complete on line | design/rationale.md:178, exactly on plus newline is on |
| a mode matches every field and requires no hidden kinds | explore-features.md:63, all preset fields match and hide is empty |
| stored views refuse torn, malformed, invalid and incomplete records | brief-feed-1:30, each refused with the specific reason |
| feed accepts the usage grammar and rejects unknown or extra sole words | explore-features.md:116-138, parser table and edges; design/rationale.md:31-37 adds on, off, status |
| commands change only the session fields named by the transition table | design/rationale.md:221-224 and explore-features.md:120-130 |

Observed failures before implementation: modeOf threw `Error: not implemented`; missing FIELDS gave `Expected: "normal", Received: "clean"`; stored-view refusal gave `Expected: "feed-view is torn: missing closing newline", Received: Error: not implemented`; grammar and transition each threw `Error: not implemented`. After implementation the kit reported 6 pass, 0 fail.

The sketch's set command allowed a boolean for style. Setting is a field-discriminated union so those inputs cannot be constructed. The registry still supplies grammar, values, pictures and mode matching. Stored-view rejection overrides the sketch's fallback as required by the brief.

The initial npx invocation selected an unrelated cached npm package named tsc and exited 1. The installed TypeScript compiler is version 6.0.3. A temporary node_modules/.bin/tsc link to that installed compiler makes npx resolve it without adding a dependency.
