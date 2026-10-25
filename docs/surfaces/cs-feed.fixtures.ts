// ABOUTME: cs-feed's surfaces in each state: verdicts and a transcript handed to the mod's own draw functions, as its render hooks hand them.
// ABOUTME: Typed against draw.tsx's Pen, verdict.ts's verdicts and transcript.ts's Transcript, so a shape change breaks this file at type-check.
import type { RenderElement } from 'claude-code'
import { drawBand, drawCall, drawCommandOutput, drawGroup, drawHelpersPane, drawReply, drawSettingsPane, drawUser, inks, type Pen } from '../../mods/cs-feed/hooks/draw.tsx'
import type { Observations } from '../../mods/cs-feed/hooks/session.ts'
import { DEFAULT_VIEW, PRESETS, modeOf, type Session, type View } from '../../mods/cs-feed/hooks/settings.ts'
import { callId, type CallId, type FiledCall, type Outcome, type Run, type Transcript } from '../../mods/cs-feed/hooks/transcript.ts'
import type { BandVerdict, CallVerdict, CallView, Context, GroupVerdict, HelperBlock, ReplyVerdict, UserVerdict } from '../../mods/cs-feed/hooks/verdict.ts'
import { errorLine, marks } from '../../mods/cs-feed/hooks/words.ts'
import { elements, type State, type Surface, type Theme } from './registry.ts'

// ---- one turn's transcript: three shell commands and a read, one refused run, a helper ----
const id = (n: number): CallId => callId(`toolu_${String(n).padStart(2, '0')}`)
const done = (lines: number, over: Partial<Extract<Outcome, { state: 'done' }>> = {}): Outcome => ({ state: 'done', errored: false, refused: false, interrupted: false, lines, ...over })
const TURN = id(1), RUN = id(1), REFUSED = id(6)
const filed = (n: number, tool: string, input: Record<string, unknown>, outcome: Outcome, run?: CallId, cls: FiledCall['cls'] = 'machinery'): FiledCall =>
  ({ id: id(n), tool, input, cls, outcome, turn: TURN, run, step: n })
const CALLS: FiledCall[] = [
  filed(1, 'Bash', { command: 'bun test', description: 'Run the tests' }, done(12, { output: '12 pass\n0 fail' }), RUN),
  filed(2, 'Bash', { command: 'ls docs', description: 'List the docs' }, done(4), RUN),
  filed(3, 'Read', { file_path: '/repo/app.py' }, done(0), RUN),
  filed(4, 'Bash', { command: 'git status', description: 'Show the working tree' }, done(2), RUN),
  filed(6, 'Bash', { command: 'rm -rf build', description: 'Remove the build' }, done(1, { errored: true, refused: true, output: 'PreToolUse:Bash hook blocked: rm -rf' }), REFUSED),
  filed(7, 'Agent', { description: 'Map the draw code', subagent_type: 'Explore' }, done(0, { durationMs: 72000 }), undefined, 'helper'),
  filed(8, 'Agent', { description: 'Read the tests', subagent_type: 'Explore' }, { state: 'running' }, undefined, 'helper'),
]
const SHELL_RUN: Run = { id: RUN, turn: TURN, calls: [id(1), id(2), id(3), id(4)] }
const REFUSED_RUN: Run = { id: REFUSED, turn: TURN, calls: [REFUSED] }
const RUNS: Run[] = [SHELL_RUN, REFUSED_RUN]
const transcript: Transcript = {
  calls: new Map(CALLS.map(call => [call.id, call])),
  turns: [{ id: TURN, first: id(1), steps: [id(1), id(2), id(3), id(4), REFUSED], runs: [RUN, REFUSED] }],
  byId: new Map(),
  runs: new Map(RUNS.map(run => [run.id, run])),
  background: [],
}
const observations = (): Observations => ({
  promptAt: new Map(), frames: new Map(), bursts: { of: new Map(), members: new Map() }, batch: { kinds: new Map() },
  anchors: new Map(), latestByCall: new Map(), anchorSeq: 0, stepsDrawn: new Map(), turnOpeners: new Set(), peerPending: false,
  helperStartedAt: new Map(), bgSeenAt: new Map(), bgEnded: new Set(), phase: 'idle',
})

// The terminal's name margin is 7 cells, and a row's text has the rest.
const PAD = 7
const context = (cols: number, view: View, t: Transcript): Context => ({ t, view, obs: observations(), opened: new Set(), phase: 'idle', agents: [], now: 0, surface: 'terminal', clickable: false, room: cols - PAD })
const pen = (cols: number, theme: Theme, over: { clickable?: boolean; view?: View; pad?: number; t?: Transcript } = {}): Pen => {
  const cx = context(cols, over.view ?? DEFAULT_VIEW, over.t ?? transcript)
  return { el: elements(), ink: inks(theme === 'light'), room: cx.room, pad: over.pad ?? PAD, clickable: over.clickable ?? false, press: async () => {}, helpers: async () => {}, cx: { ...cx, clickable: over.clickable ?? false } }
}
type Draw = (cols: number, theme: Theme) => RenderElement
const state = (id: string, name: string, draw: Draw): State => ({ id, name, draw })

// ---- UserMessage ----
const PROMPT_AT = new Date(2026, 9, 25, 9, 41).getTime()
const user = (v: Exclude<UserVerdict, { draw: 'engine' }>): Draw => (cols, theme) => drawUser(v, pen(cols, theme))
const CARD = { tone: 'ok' as const, status: 'gate green', sub: '42 tests', target: 'main', scores: [{ label: 'suites', dots: ['ok', 'ok', 'ok', 'bad'] as const, pass: 3, of: 4 }], lists: [{ label: 'findings', count: 2, first: 'the band clips at 60 cols' }], report: 'gate.md' }
const userStates: State[] = [
  state('you', 'reading a prompt they typed', user({ draw: 'you', text: 'fix the login redirect' })),
  state('you-at', 'reading a prompt with the time they sent it', user({ draw: 'you', text: 'fix the login redirect', at: PROMPT_AT })),
  state('you-slash', 'reading a slash command they ran', user({ draw: 'you', text: '/feed clean' })),
  state('hook-text', 'reading what a hook added to their prompt', user({ draw: 'hookText', line: 'cs: the band names prompt 4' })),
  state('peer', 'reading a message from another session', user({ draw: 'peer', sender: 'fix-auth', headline: 'gate green, ready to land' })),
  state('peer-nested', 'reading one message of an opened burst', user({ draw: 'peer', sender: 'fix-auth', headline: 'gate green, ready to land', nested: true })),
  state('burst-closed', 'skimming several messages folded into one line', user({ draw: 'burst', members: [{ uuid: 'u1', sender: 'fix-auth', at: PROMPT_AT }, { uuid: 'u2', sender: 'docs', at: PROMPT_AT }], opened: false })),
  state('burst-opened', 'reading the first message of an opened burst', user({ draw: 'burst', members: [{ uuid: 'u1', sender: 'fix-auth', at: PROMPT_AT }, { uuid: 'u2', sender: 'docs', at: PROMPT_AT }], opened: true, own: { sender: 'fix-auth', headline: 'gate green, ready to land' } })),
  state('helper-note', 'told a helper finished', user({ draw: 'helperNote', durationMs: 12000, headline: 'mapped the draw code' })),
  state('background-note', 'told a background task moved', user({ draw: 'backgroundNote' })),
  state('frames-text', 'reading a teammate report with more lines folded', user({ draw: 'frames', frames: [{ from: 'fix-auth', state: 'waiting', at: PROMPT_AT, relays: false, lead: { text: 'Gate **green**; run `/finish` to land.', more: 3 } }] })),
  state('frames-card', 'reading a teammate verdict card', user({ draw: 'frames', frames: [{ from: 'fix-auth', state: 'waiting', relays: true, lead: { sentence: 'The gate ran on the branch head.', card: CARD, more: 0 } }] })),
]

// ---- AssistantMessage: the engine draws the reply's Markdown; this stands in for it ----
const ENGINE_REPLY = 'Fixed: the token now **refreshes** before `fetch` retries.'
const reply = (v: ReplyVerdict, over: { pad?: number } = {}): Draw => (cols, theme) => drawReply(v, elements().Markdown({ text: ENGINE_REPLY }), pen(cols, theme, over))
const stepsClosed: CallVerdict = { draw: 'turn', turn: TURN, done: 5, opened: false, body: [] }
const stepsOpened: CallVerdict = { draw: 'turn', turn: TURN, done: 5, opened: true, body: [{ draw: 'run', run: SHELL_RUN, opened: false }, { draw: 'run', run: REFUSED_RUN, opened: false }] }
// One error text per rule of words.ts errorLine, in its order.
const ERRORS: [string, string, string][] = [
  ['error-safeguards-cut', "told a provider's safeguards cut the reply", "API Error: Acme's safeguards stopped the response above; continuing"],
  ['error-classifier-cut', 'told a safety classifier cut the reply', 'API Error: stopped by a safety classifier'],
  ['error-safeguards-stopped', 'told the safeguards stopped the reply', 'API Error: this request violates the usage policy'],
  ['error-busy', "told Claude's servers are busy", 'API Error: 529 overloaded'],
  ['error-usage-limit', 'told the usage limit is reached', 'Claude AI usage limit reached, resets 5pm'],
  ['error-too-long', 'told the chat is too long', 'Prompt is too long'],
  ['error-login', 'told to log in again', 'Invalid API key · Please run /login'],
  ['error-billing', 'told the account has a billing problem', 'Credit balance is too low'],
  ['error-connection', 'told the connection dropped', 'Connection error'],
  ['error-server', "told Claude's side failed", 'API Error: 500 internal server error'],
  ['error-refused', 'told the request was refused', 'API Error: 400 invalid_request_error'],
  ['error-other', 'told Claude Code hit an error', 'Error: something else went wrong'],
]
const errorBody = (text: string) => { const line = errorLine(text); if (line === undefined) throw new Error(`cs-feed: errorLine reads no error in ${JSON.stringify(text)}`); return { error: line } }
const replyStates: State[] = [
  state('margin-and-reply', 'reading the first block of a reply', reply({ body: 'engine', name: true })),
  state('reply-no-margin', 'reading a later block of the same reply', reply({ body: 'engine', name: false })),
  state('reply-desktop', 'reading a reply on the desktop app, with no margin', reply({ body: 'engine', name: false }, { pad: 0 })),
  state('reply-steps-closed', "reading a reply with its turn's steps folded under it", reply({ body: 'engine', name: true, stepsLine: stepsClosed })),
  state('reply-steps-opened', "reading a reply with its turn's steps opened", reply({ body: 'engine', name: true, stepsLine: stepsOpened })),
  ...ERRORS.map(([sid, name, text]) => state(sid, name, reply({ body: errorBody(text), name: false }))),
]

// ---- ToolUse ----
const view = (call: FiledCall, over: Partial<CallView> = {}): CallView => ({ id: call.id, tool: call.tool, input: call.input, isRunning: call.outcome.state === 'running', isErrored: call.outcome.state === 'done' && call.outcome.errored, isInterrupted: false, output: call.outcome.state === 'done' ? call.outcome.output : undefined, ...over })
const at = (n: number): FiledCall => { const call = transcript.calls.get(id(n)); if (call === undefined) throw new Error(`cs-feed fixture: no call ${n}`); return call }
const call = (v: CallVerdict, over: { clickable?: boolean; view?: View; t?: Transcript } = {}): Draw => (cols, theme) => drawCall(v, pen(cols, theme, over))
// The same turn while the run's second call works: the first is done, the rest not yet filed.
const LIVE: Transcript = { ...transcript, calls: new Map([[id(1), at(1)], [id(2), { ...at(2), outcome: { state: 'running' } }]]) }
const QUESTION: CallView = { id: id(9), tool: 'AskUserQuestion', input: { questions: [{ question: 'Land the branch now? It is green.' }] }, isRunning: true, isErrored: false, isInterrupted: false }
const toolStates: State[] = [
  state('turn-closed', "skimming a turn's steps folded into one line", call(stepsClosed)),
  state('turn-opened', "reading a turn's steps opened", call(stepsOpened)),
  state('run-live', 'watching a run while its second call works', call({ draw: 'run', run: SHELL_RUN, naming: id(2), opened: false }, { t: LIVE })),
  state('run-done', 'skimming a finished run as counts', call({ draw: 'run', run: SHELL_RUN, opened: false })),
  state('run-line-style', 'skimming a finished run in the line style, no chips', call({ draw: 'run', run: SHELL_RUN, opened: false }, { view: { ...DEFAULT_VIEW, style: 'line' } })),
  state('run-refused', 'told every step of a run was refused by a hook', call({ draw: 'run', run: REFUSED_RUN, opened: false })),
  state('run-opened', "reading a run's calls opened", call({ draw: 'run', run: SHELL_RUN, opened: true })),
  state('call-running', 'watching one call work', call({ draw: 'call', call: view(at(1), { isRunning: true, output: undefined }), opened: false })),
  state('call-running-clickable', 'watching one call work in a fullscreen terminal, the chevron pressable', call({ draw: 'call', call: view(at(1), { isRunning: true, output: undefined }), opened: false }, { clickable: true })),
  state('call-done', 'skimming a finished call', call({ draw: 'call', call: view(at(2)), filed: at(2), opened: false })),
  state('call-errored', 'told a call failed', call({ draw: 'call', call: view(at(4), { isErrored: true, output: 'fatal: not a git repository' }), opened: false })),
  state('call-opened', "reading a finished call's output", call({ draw: 'call', call: view(at(1)), filed: at(1), opened: true })),
  ...(['dispatched', 'running', 'finished', 'failed', 'stopped'] as const).map(helper => state(`helper-${helper}`, `watching a helper that is ${helper}`, call({ draw: 'helper', call: view(at(7)), state: helper, elapsedMs: helper === 'dispatched' ? undefined : 72000 }))),
  state('question-asked', 'asked a question in the chat', call({ draw: 'question', call: QUESTION, opened: false })),
  state('question-ended', 'left a question unanswered', call({ draw: 'question', call: { ...QUESTION, isRunning: false }, opened: false })),
]

// ---- ToolGroup ----
const batch = (states: ('running' | 'finished' | 'failed')[], opened = false): Exclude<GroupVerdict, { draw: 'engine' }> => ({
  draw: 'batch', key: `helpers-${id(7)}`, opened, elapsedMs: 42000,
  helpers: states.map((s, i) => ({ call: view(at(i % 2 === 0 ? 7 : 8)), kind: i < 2 ? 'Explore' : 'Plan', state: s })),
})
const group = (v: Exclude<GroupVerdict, { draw: 'engine' }>): Draw => (cols, theme) => drawGroup(v, pen(cols, theme))
const groupStates: State[] = [
  state('stack', 'skimming a group of calls stacked one per line', group({ draw: 'stack', calls: [{ draw: 'call', call: view(at(2)), filed: at(2), opened: false }, { draw: 'call', call: view(at(3)), filed: at(3), opened: false }] })),
  state('batch-running', 'watching a batch of helpers work', group(batch(['running', 'finished', 'running']))),
  state('batch-done', 'told every helper of a batch finished', group(batch(['finished', 'finished', 'finished']))),
  state('batch-failed', 'told a helper of a batch failed', group(batch(['finished', 'failed', 'finished']))),
  state('batch-opened', "reading a batch's helpers one per line", group(batch(['running', 'finished', 'running'], true))),
]

// ---- CommandOutput ----
const output = (text: string, isErrored: boolean): Draw => (cols, theme) => drawCommandOutput({ text, isErrored }, pen(cols, theme))
const outputStates: State[] = [
  state('text', "reading a command's answer", output('Chat view: clean. your messages, Claude\'s replies, and one line per turn for the work.', false)),
  state('errored', "reading a command's refusal", output('no feed change in this session: cs refused this session', true)),
]

// ---- AbovePrompt: ours above what cs or the engine drew, here nothing ----
const band = (v: Exclude<BandVerdict, { draw: 'engine' }>, over: { pad?: number } = {}): Draw => (cols, theme) => drawBand(v, elements().Box({}), 0, pen(cols, theme, over))
const HELPERS = { head: '3 helpers · 1 done · 2 running · 1m 12s', kinds: [{ kind: 'Explore', cells: marks.working + marks.live, done: 1, n: 2 }, { kind: 'Plan', cells: marks.working, done: 0, n: 1 }] }
const bandStates: State[] = [
  state('helpers-running', 'watching helpers work above the prompt', band({ draw: 'helpers', ...HELPERS, more: 0, spinning: true })),
  state('helpers-settled', 'reading a batch of helpers that all finished', band({ draw: 'helpers', head: '3 helpers · 3 done · 1m 12s', kinds: [{ kind: 'Explore', cells: marks.live + marks.live, done: 2, n: 2 }, { kind: 'Plan', cells: marks.live, done: 1, n: 1 }], more: 0, spinning: false })),
  state('helpers-overflow', 'watching more kinds of helper than the band has rows for', band({ draw: 'helpers', ...HELPERS, more: 2, spinning: true })),
  state('background', 'typing while a shell command runs in the background', band({ draw: 'background', words: 'Building the docs', isTest: false, more: 0, elapsedMs: 42000, typing: true })),
  state('background-test', 'typing while the tests run in the background', band({ draw: 'background', words: 'bun test', isTest: true, more: 1, elapsedMs: 42000, typing: true })),
  state('background-narrow', 'running a background task in a narrow terminal, no tail', band({ draw: 'background', words: 'Building the docs', isTest: false, more: 0, elapsedMs: 42000, typing: false })),
  state('desktop', 'reading usage and pills on the desktop app', band({ draw: 'desktop', usage: { fiveHour: 42, week: 17 }, pills: [{ kind: 'helper', words: 'Map the draw code', elapsedMs: 72000 }, { kind: 'test', words: 'bun test', elapsedMs: 12000 }] }, { pad: 0 })),
]

// ---- the Chat view pane, its body as wide as the pane leaves ----
const PANE_CHROME = 4
const settings = (session: Session): Draw => (cols, theme) => drawSettingsPane(modeOf(session), session, { el: elements(), ink: inks(theme === 'light'), room: cols - PANE_CHROME }, async () => {})
const clean = DEFAULT_VIEW
const settingsStates: State[] = [
  state('clean', 'reading the settings in the clean view', settings({ on: true, view: clean })),
  state('normal', 'reading the settings in the normal view', settings({ on: true, view: { ...PRESETS.normal.fields, hide: [] } })),
  state('raw', "reading the settings with the feed off, Claude Code's own drawing", settings({ on: false, view: clean })),
  state('custom', 'reading the settings after changing one', settings({ on: true, view: { ...clean, style: 'expanded', commands: 'each' } })),
  state('kinds-hidden', 'reading the settings with two kinds hidden', settings({ on: true, view: { ...clean, hide: ['peer', 'search'] } })),
  state('every-other-value', 'reading each setting at its other value', settings({ on: true, view: { group: !clean.group, clear: !clean.clear, keep: !clean.keep, style: 'line', commands: clean.commands === 'grouped' ? 'each' : 'grouped', after: clean.after === 'clear' ? 'keep' : 'clear', hide: [] } })),
]

// ---- the Helpers pane ----
const helpersPane = (blocks: readonly HelperBlock[]): Draw => (cols, theme) => drawHelpersPane(blocks, { el: elements(), ink: inks(theme === 'light'), room: cols - PANE_CHROME })
const WORKING: HelperBlock = { name: 'Explore', status: 'working', elapsedMs: 72000, now: 'Reading draw.tsx', calls: ['Searched the code for drawBand', 'Read words.ts'] }
const helperStates: State[] = [
  state('none', 'opening the pane before any helper ran', helpersPane([])),
  state('working', 'watching a helper work, call by call', helpersPane([WORKING])),
  state('finished', 'reading what a finished helper did', helpersPane([{ name: 'Plan', status: 'finished', elapsedMs: 30000, calls: ['Read the brief'] }])),
  state('failed', 'reading where a helper failed', helpersPane([{ name: 'Plan', status: 'failed', elapsedMs: 9000, calls: ['Ran the tests'] }])),
  state('mixed', 'reading several helpers, newest first', helpersPane([WORKING, { name: 'Plan', status: 'finished', elapsedMs: 30000, calls: [] }, { name: 'general-purpose', status: 'stopped', calls: ['Read app.py'] }])),
]

const surface = (slot: string, states: State[], parts: Surface['parts'], extra: Partial<Surface> = {}): Surface =>
  ({ id: `cs-feed.${slot}`, mod: 'cs-feed', slot, source: 'generated', global: 'CsFeedSurfaces', needs: [], states, parts, ...extra })

export const surfaces: Surface[] = [
  surface('UserMessage', userStates, [
    { id: 'feed-row', name: 'you row with the name margin', state: 'you-at', path: [0] },
    { id: 'name-margin', name: 'name margin', state: 'you', path: [0, 0] },
    { id: 'peer-line', name: 'peer line', state: 'peer', path: [0] },
  ]),
  surface('AssistantMessage', replyStates, [
    { id: 'reply-margin', name: 'claude margin', state: 'margin-and-reply', path: [0, 0] },
    { id: 'error-line', name: 'error line', state: 'error-busy', path: [0] },
  ]),
  surface('ToolUse', toolStates, [
    { id: 'call-row', name: 'call row', state: 'call-done', path: [0] },
    { id: 'chip', name: 'chip', state: 'call-done', path: [0, 2] },
    { id: 'chevron', name: 'chevron', state: 'call-done', path: [0, 3] },
    { id: 'steps-line', name: 'steps line', state: 'turn-closed', path: [0] },
  ]),
  surface('ToolGroup', groupStates, [
    { id: 'helper-cells', name: 'helper cell row', state: 'batch-running', path: [1] },
  ]),
  surface('CommandOutput', outputStates, []),
  surface('AbovePrompt', bandStates, [
    { id: 'helpers-head', name: 'helpers head', state: 'helpers-running', path: [0, 0] },
  ]),
  surface('Pane.cs-feed', settingsStates, [
    { id: 'settings-row', name: 'settings row', state: 'clean', path: [2, 0] },
    { id: 'kind-chip', name: 'kind chip Button', state: 'clean', path: [9, 0] },
  ], { slot: 'Pane', chrome: { kind: 'pane', title: 'Chat view', rows: 24 } }),
  surface('Pane.cs-feed-helpers', helperStates, [
    { id: 'helper-head', name: 'helper head', state: 'working', path: [0, 0] },
  ], { slot: 'Pane', chrome: { kind: 'pane', title: 'Helpers', rows: 12 } }),
]
