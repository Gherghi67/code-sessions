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

## Words and observation corrections

| Test | Source sentence |
|---|---|
| error rules preserve ordered literal remedies and reject quoted safeguard prose | explore-features.md:386-405, ordered rules 1-12; design/rationale.md:475, safeguard rules accept an error prefix OR a whole one-line reply |
| steps ownership agrees with the mermaid scanner on its documented fence fixtures | design/rationale.md:541 requires parity; mods/cs-mermaid/test/register.test.tsx:9-20 supplies the six input shapes; the expected booleans are literals |
| peer and hook labels clean only their display text and keep safe fallbacks | explore-features.md:475 gives hook routing and 110-character limit; :482 gives the literal build-helper headline; :485 specifies sender attributes |
| helper envelopes preserve report data as inert frames and bound plain leads | explore-features.md:492-515 gives frame fields, target, score, plain lists, report path and six-line lead cap |
| a response anchors its text before filing the same row’s new calls | design/sketch/hooks/register.tsx:213-217 records text against the previous call before updating from tool_use blocks |

Errors, peer labels and report frames each first failed `Error: not implemented`. The URL userinfo case first received `Opening reader:example@example.com`, then passed as `Opening example.com`. The anchor-order case first received true for an anchor on a first row whose call had not yet preceded its text, then passed false.

Two stale sketch assertions were corrected against the rationale before implementation: §20.10 says `+1 line`, so the extended chip test failed with `Received: ["+1 lines"]` before the fix; §20.6 permits a whole one-line safeguard message, so that new assertion received undefined before the prefix-or-one-line fix. Multiline quoted prose remains a normal reply.

The kit refuses imports outside the plugin. Actual scanner parity therefore used a temporary in-plugin copy of cs-mermaid's TypeScript source. All copied files were byte-identical and their SHA-256 hashes are in mermaid-equivalence.log. An initial directory diff reported only the intentionally omitted hooks.json; the source-only check passed. The actual scanner and the independent literal expectations both passed (20 tests total). The temporary import and copied modules were removed; committed tests retain the literal fixtures. No engine mocks were used.

The latest complete run after the words slice reports 24 pass, 0 fail; npx tsc exits 0. Input-boundary review found no executable interpretation of JSON, attributes or tool output. JSON is parsed as unknown and narrowed; arbitrary field names are data. URL labels read only hostname, never userinfo. Report paths become display basenames and are never opened.

## Verdicts and claim observations

| Test | Source sentence |
|---|---|
| helper state derives all five states from call outcome and the agent list | design/sketch/hooks/verdict.ts:55-65, in-flight means dispatched, busy answered helper means running, then failed/stopped/finished; explore-features.md:420-426 elapsed examples |
| rule 1 folds a live turn onto its first machinery call and counts only completed steps | explore-features.md:243 and :266-270, first call draws the turn line, only done calls count; rationale.md:472 keeps it when its first kind is hidden |
| rule 2 hides a spent turn when clear is on and keep and group are off | explore-features.md:245, not visible and not opened means nothing |
| rule 3 suppresses a still-running call when its kept turn is folded | explore-features.md:246, group on, live call, unopened means nothing |
| rule 4 groups commands at the first run call and names its live call | explore-features.md:247 and :320, grouped commands use the first run call; live call gives present words |
| rule 5 collapses spent each-command rows when after is clear and keep is off | explore-features.md:248, spent after-clear keep-off unopened uses the run line |
| rule 6 draws the call’s own words and honors expanded style | explore-features.md:249 and :333, otherwise own line; expanded style opens output |
| standalone and unknown calls obey kind hiding and preserve observed helper timing | design/sketch/hooks/verdict.ts:72-100, helper/question before folding, unfiled running call waits for filing; explore-features.md:420, no observed spawn means no time |
| a reply evaluated before turn completion stays pending then claims exactly once | design/rationale.md:539, pending live claim, turn.complete bump, claim, then tool yields |
| reply claims settle in either evaluation order and fragments remain write-once | design/rationale.md:539, both bump orders, complete-before-first evaluation, live fragment then whole text, spent fragment false for good; last call includes helpers |
| failed replies remain visible when said is hidden and desktop keeps the engine body | design/rationale.md:470-471, both surfaces and errors before said hiding |
| groups preserve non-call content and expansion, and known results ride on their calls | engine index.d.ts:10524-10532 requires isCallsOnly true; explore-features.md:433-442 helper groups and :350 known result suppression |
| an unknown phase uses the band observation or a running call without inventing a turn id | design/sketch/hooks/session.ts openTurn contract: phase unknown uses AbovePrompt.isWorking, then a call without a result; open turn may have no call id |
| spinner rewrites only an empty engine message using machinery steps and response mode | explore-features.md:362-371; design/rationale.md:478 preserves engine compaction text/suffix; :481 machinery-only steps |
| user routing preserves authorship, quiet hook text and conservative task notifications | explore-features.md:471-485 ordered routing and burst member records; design/rationale.md:477 unknown task is background |
| the band caps helper kinds, remembers vanished members and preserves survey and desktop composition | explore-features.md:447-452 batch rules and maxRows 6 pin; :550-565 desktop, survey and composition; :535-538 background timing and width |
| command answers trim the feed prefix and mode labels preserve existing session modes | explore-features.md:178-180 command output and §3.5; design/sketch/hooks/verdict.ts sessionModes contract |

Each numbered decision row ran red before its branch was implemented. Row 1 threw `Error: not implemented`; rows 2 and 3 received a call instead of `{ draw: nothing }`; rows 4 and 5 received `call` instead of `run`; row 6 received `opened: false` instead of true. Helper, group, spinner, user, band and command tests each threw `Error: not implemented`. Standalone handling first returned a call instead of nothing for an unfiled running row. Reply tests first could not import observeTurnComplete; the hidden-error extension then received body nothing instead of its literal Connection lost error. A pending ReplyDecision initially failed tsc TS2322 because its local body annotation permitted stepsLine; narrowing the annotation to Omit<ReplyVerdict, 'stepsLine'> fixed the type without a cast.

recordStepsClaim is a pure explicit-Load transition: it returns true only for the first drawn claim, requesting a bump from the future shell. It does not call a clock or write engine state. Tests evaluate both orders as separate fresh Loads, record every settled claim immediately, then verify one owner. Actual hook/timer integration remains part 2. replaceResponseText preserves the anchor's call, sequence and index after the stored text replaces the pre-next text; its first test run reported the missing export before implementation.

Review extensions: empty sender name first routed as peer, then correctly as you; the report lead pin first counted 3 rather than 2 remaining nonblank lines; the question fallback first returned [] rather than a question/free text. Each exact extension was red before its fix. Integrated peer joining and live-openers now assert turn ids [a,b] versus [a] without either source. Settings grammar now checks every full literal command, raw/off starts from an on custom view, and FIELDS-backed type narrowing removes the repeated parser switch. Their empirical mutation results are recorded with the final verification.

At the pure-modules checkpoint the kit reports 41 pass, 0 fail; npx tsc exits 0. Public verdicts remain discriminated unions, and pending replies cannot carry a steps line. New observation fields are inert batch/burst inputs; polling, timers and hook wiring are deferred. No process, filesystem or dynamic code execution was added to the pure modules.

## Fixture identity and packaging check

All fourteen JSON dumps retain their recorded structure and line numbering. Twenty-eight encoded username path segments were changed from the original human username to `test-user`; no other JSON bytes changed. Their TypeScript data modules contain the adjacent JSON bytes, two ABOUTME lines, `export default`, and one module-terminating newline. All fourteen parsed payload pairs are equal. The kit loader rejects JSON imports, so these modules package the recorded data without mocking the engine.

The first packaging assertion assumed no extra terminating newline and failed before any edit. Inspection showed the generator adds exactly one newline. The corrected check asserts that exact wrapper and passed for all fourteen pairs. Evidence is in the local `.audit/fixture-equivalence.log`.
