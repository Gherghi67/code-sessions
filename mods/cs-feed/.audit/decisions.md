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
| stored views refuse torn, malformed, invalid and incomplete records | errand-70483ca3-760c-4d6b-9ae3-ef9451d0dad4.brief.md:31, each refused with the specific reason |
| feed accepts the usage grammar and rejects unknown or extra sole words | explore-features.md:116-138, parser table and edges; design/rationale.md:31-37 adds on, off, status |
| commands change only the session fields named by the transition table | design/rationale.md:221-224 and explore-features.md:120-130 |

Observed failures before implementation: modeOf threw `Error: not implemented`; missing FIELDS gave `Expected: "normal", Received: "clean"`; stored-view refusal gave `Expected: "feed-view is torn: missing closing newline", Received: Error: not implemented`; grammar and transition each threw `Error: not implemented`. After implementation the kit reported 6 pass, 0 fail.

The sketch's set command allowed a boolean for style. Setting is a field-discriminated union so those inputs cannot be constructed. The registry still supplies grammar, values, pictures and mode matching. Stored-view rejection overrides the sketch's fallback as required by the brief.

The initial npx invocation selected an unrelated cached npm package named tsc and exited 1. The installed TypeScript compiler is version 6.0.3. A temporary node_modules/.bin/tsc link to that installed compiler makes npx resolve it without adding a dependency.

## Transcript and labels

| Test | Source sentence or dump line |
|---|---|
| recorded prompts, deliveries and Stop continuations retain their measured turns | spike2.md:85: typed text during a text-only stream becomes its own turn; :128: idle peer reply is the first entry and has no preceding user; :145: idle task notification starts its own turn; :151: STOPTEST and two adjacent ok replies are one turn. The seven plain captures have respectively 3, 1, 2, 4, 2, 2, 3 visible turns. Every paired API capture is exercised. |
| only plain user text without tool results or bash framing opens a turn | design/rationale.md:108: text, no tool results, not bash-mode text |
| API joins verify ordered tool ids and stop at the first inconsistent pair | design/sketch/hooks/transcript.ts, joinApi comment: same tool_use ids in the same order and same text; stop at the first inconsistent pair |
| a tool-free text verifies only when it is unique in both lists | design/rationale.md revision 2.1 and spike2.md:151; m1d API entries 11 and 13 both say ok, and a truncated newest API window must not verify them |
| peer history accepts one anchored preamble and refuses quoted envelopes | design/rationale.md:388: every block is the measured preamble at offset 0 or a reminder quoting no envelope; exactly one preamble |
| background launches close on idle notifications and API mid-turn notifications | design/rationale.md:621: the same API read finds background closes folded into tool_result content; explore-features.md:541: description or command is retained for test detection |
| questions retain literal answers and shorten only the question sentence | explore-features.md:584-585: first ? or : followed by space/end, else first period; the literal Which look and Anything else pins |
| structured output precedes model-facing wrappers and retains its count when capped | explore-features.md:212: stdout and stderr joined, else error text; capped at 2000 characters |
| a prompt-door idle peer opens its first response call unless a typed prompt intervenes | design/rationale.md:538: prompt-door peer isMeta, then turn.start, then response call is an opener; typed prompt in between is none |
| call labels clean descriptions and name tools without exposing commands | explore-features.md:297-304: Bash, Read, cleaned path, WebFetch literal pins; :288: MCP tool name |
| hook refusals and background test words use the specified phrases | explore-features.md §4.7b refusal phrases and :539: test, tests, suite, spec, specs, e2e, verify, check |
| compact labels preserve singular counts and bounded time and text | explore-features.md:267: 1 step this turn; :426: elapsed formats and floor; design/sketch/hooks/words.ts: fit and hhmm contracts |
| run summaries count kinds and chips without counting refused calls as failed work | explore-features.md:306-333: exact count ordering, three literal run examples, refused count, failed count and +1 lines |

Before implementations, each first red was `Error: not implemented` (open, peer, join, build, background, questions, labels, classification, compact formatting, run summaries). Unique-text verification first failed `Expected: [1], Received: []`. Pure peer observations first failed `Export named 'observePrompt' not found`. The question-priority extension failed with `Received: Read v1.2` and `First.Second`; the command-only background extension received `isTest: false`; the structured-output extension received `lines: 1, output: <tool_result>wrapped</tool_result>` rather than the three stdout/stderr lines. Each was rerun green after its fix. Full logs remain local in .audit; the latest run is 19 pass, 0 fail.

The engine kit does not load JSON imports. Each fixture therefore also has a TypeScript data export with the two required ABOUTME lines. This is a data packaging requirement, not an engine mock. Parent redaction and payload equivalence are recorded below.

m1b's leading orphan assistant reply gets an implicit visible turn, as required to retain leading-window content. It proves no historical peer join: open-measurements.md M23 explicitly says its peer row is first and cannot exercise an adjacent assistant gap. The join test uses a shape-derived pair and says so. The API background close follows rationale option B over the stale sketch's reload-loss comment. Machinery-only step counts follow ruling 20.12 over the sketch's all-filed-call pseudocode.

## Fixture identity and packaging check

All fourteen JSON dumps retain their recorded structure and line numbering. Twenty-eight encoded username path segments were changed from the original human username to `test-user`; no other JSON bytes changed. Their TypeScript data modules contain the adjacent JSON bytes, two ABOUTME lines, `export default`, and one module-terminating newline. All fourteen parsed payload pairs are equal. The kit loader rejects JSON imports, so these modules package the recorded data without mocking the engine.

The first packaging assertion assumed no extra terminating newline and failed before any edit. Inspection showed the generator adds exactly one newline. The corrected check asserts that exact wrapper and passed for all fourteen pairs. Evidence is in the local `.audit/fixture-equivalence.log`.
