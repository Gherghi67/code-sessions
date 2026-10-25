// ABOUTME: The cs band in each state: facts turned into the BandView the mod's AbovePrompt hook builds, drawn by the mod's own drawBand.
// ABOUTME: The facts are the band catalogue the variants gallery shares; typed against BandView, so a change to it breaks this file at type-check.
import type { RenderElement } from 'claude-code'
import {
  AMBER_AT, ASKS, COMMANDS, CRIT_AT, FEED_ACTION, LOGS, MARK_INK, REPLIES, ROTATE_ACTION, TOASTS, WRAP_ACTION,
  bandState, buildBandEntries, countdownColor, drawBand, featuresWordOf, finishToast, paletteColor,
  type BandView, type FeatureRecord, type FinishRecord,
} from '../../mods/cs/hooks/register.tsx'
import { askDialog, commandReply, inlineToast, logRow, menuRows, toast } from './chrome.ts'
import { elements, type State, type Surface, type Theme } from './registry.ts'

// What the AbovePrompt hook has read by the time it builds the band: its
// buildBandEntries facts without the presses, and what else drawBand is
// handed. `due` is a rotation due (context past the threshold, or a handoff
// armed), which shows mid-turn too, where `rotating` is the key that only an
// idle band offers; `queueRunning` is the queue armed or draining, not merely
// holding tasks. `colour` is the session's palette name, null for none.
export type Facts = {
  featured?: { label: string; pressable: boolean }
  countdown?: { seconds: number }
  rotating: boolean
  armed: boolean
  wrapping: boolean
  feed?: { on: boolean }
  waiting: number
  gate?: string
  queued: number
  mail: number
  chords: { rotate?: string; wrap?: string; feed?: string }
  rail?: { prompts: string[]; named: number; refused: number[] }
  due: boolean
  queueRunning: boolean
  survey: boolean
  colour: string | null
  surface: 'terminal' | 'desktop'
}

// The keybindings the installer writes (CS_ROTATE_WRAP_KEYS in lib/01-manifests.sh).
export const CHORDS = { rotate: 'ctrl+x 1', wrap: 'ctrl+x 2', feed: 'ctrl+x 3' }
// cs.bandBars' default (mods/cs/.claude-plugin/plugin.json).
const BAND_BARS = 10
// The cells AbovePrompt keeps at the right of every row for its `[-]` (d.ts
// AbovePrompt bodyColumns), so the band is handed the terminal's width less them.
export const RESERVED = 5

export const PROMPTS = [
  'fix the login redirect', 'add a retry to the upload client', 'why does the cache miss on first load',
  'rename the settings module', 'write the migration for the orders table', 'make the sidebar collapse on narrow screens',
  'explain the session timeout', 'drop the unused date helpers', 'speed up the search index build',
  'add a dark theme to the docs', 'check the release notes for typos', 'split the report into two pages',
  'move the config loader out of main', 'run the full suite and fix what fails',
]

export function facts(over: Partial<Facts>): Facts {
  return { rotating: false, armed: false, wrapping: false, waiting: 0, queued: 0, mail: 0, chords: CHORDS, due: false, queueRunning: false, survey: false, colour: 'orange', surface: 'terminal', ...over }
}

// The ramp step the count is in, as countdownColor picks its ink.
export function countdownStep(seconds: number): 'session' | 'amber' | 'crit' {
  return seconds < CRIT_AT ? 'crit' : seconds <= AMBER_AT ? 'amber' : 'session'
}

const press = () => {}
const ACTION = { rotate: ROTATE_ACTION, wrap: WRAP_ACTION, feed: FEED_ACTION }

// The session survey as Claude Code 2.1.310 draws it in the band's place
// (cL, read off the bundle): a blank row, then the cyan mark in a Box of
// minWidth 2 beside the question, bold; under it, two cells in, each answer
// in a Box 10 cells wide, its key cyan ("e(s,{width:B9e,...", B9e=10). The
// engine nests the key in the answer's Text; here they are two Texts side by
// side, the same cells, since the designer holds a Text's words as one string.
function survey(): RenderElement {
  const el = elements()
  const answers = [['1', 'Bad'], ['2', 'Fine'], ['3', 'Good'], ['0', 'Dismiss']]
  return el.Box({ flexDirection: 'column', marginTop: 1, children: [
    el.Box({ children: [el.Box({ minWidth: 2, children: [el.Text({ color: 'ansi:cyan', children: '\u25cf' })] }), el.Text({ bold: true, wrap: 'wrap', children: 'How is Claude doing this session? (optional)' })] }),
    el.Box({ marginLeft: 2, children: answers.map(([key, label]) => el.Box({ width: 10, children: [el.Text({ color: 'ansi:cyan', children: key }), el.Text({ children: `: ${label}` })] })) }),
  ] })
}

// The BandView the hook would hand drawBand for these facts, in a terminal
// `cols` wide and the light or dark theme. The engine's own drawing is
// nothing, or its survey, which owns the band.
export function viewOf(f: Facts, cols: number, theme: Theme): BandView {
  const el = elements()
  const own = paletteColor(f.colour ?? undefined)
  const entries = buildBandEntries({
    featured: f.featured && { label: f.featured.label, onPress: f.featured.pressable ? press : undefined },
    countdown: f.countdown && { seconds: f.countdown.seconds, ink: countdownColor(f.countdown.seconds, f.colour ?? undefined, undefined, theme) },
    rotating: f.rotating, armed: f.armed, wrapping: f.wrapping, waiting: f.waiting, gate: f.gate, queued: f.queued, mail: f.mail,
    feed: f.feed && { on: f.feed.on, color: own, onPress: press },
    rotate: press, wrap: press, queue: press,
  })
  const chords: Record<string, string> = {}
  for (const role of ['rotate', 'wrap', 'feed'] as const) { const chord = f.chords[role]; if (chord !== undefined) chords[ACTION[role]] = chord }
  const prompts = (f.rail?.prompts ?? []).map((text, i) => ({ uuid: `p${i}`, text }))
  const rail = f.rail && prompts.length > 1 ? { prompts, named: f.rail.named, denied: new Set(f.rail.refused.map(i => `p${i}`)), bars: BAND_BARS, jump: async () => {} } : undefined
  const markColor = MARK_INK[bandState({ gate: f.gate !== undefined, queueRunning: f.queueRunning, rotationDue: f.due })](undefined, theme)
  const drawn = f.survey ? survey() : el.Box({})
  return { drawn, entries, chords, own, markColor, hasSurvey: f.survey, bodyColumns: cols - RESERVED, surface: f.surface, rail }
}

export function band(f: Facts, cols: number, theme: Theme): RenderElement {
  return drawBand(viewOf(f, cols, theme), elements())
}

const feature = (state: string, ahead = 2): FeatureRecord => ({ task: 'fix-auth', ahead, state })
const word = (records: FeatureRecord[], pressable: boolean) => {
  const w = featuresWordOf(records)
  if (w === undefined) throw new Error('cs fixture: featuresWordOf drew no word for ' + JSON.stringify(records))
  return { label: w.label, pressable: pressable && w.finish !== undefined }
}
// featuresWordOf's state words for one feature: `ready` with work ahead, `no
// commits` with none, and each state _feature_readiness prints.
const ONE_FEATURE: [string, FeatureRecord][] = [
  ['ready', feature('ready')], ['no-commits', feature('ready', 0)], ['staged', feature('staged')], ['locked', feature('locked')],
  ['dirty', feature('dirty')], ['untracked', feature('untracked')], ['vault-locked', feature('vault-locked')], ['base-dirty', feature('base-dirty')], ['merged', feature('merged')],
]
const DUE = { rotating: true, wrapping: true, due: true }

export type BandState = { id: string; name: string; facts: Facts }
// How many of STATES, from the first, the band variants gallery draws every sketch in.
export const CATALOGUE = 15
// The catalogue the gallery has always drawn, first and in its order; then
// every other state the hook can hand drawBand.
export const STATES: BandState[] = [
  { id: 'idle', name: 'nothing to say', facts: facts({}) },
  { id: 'rotate-due', name: 'context past the threshold', facts: facts(DUE) },
  { id: 'countdown', name: 'handoff armed, counting down to the /clear', facts: facts({ countdown: { seconds: 7 }, rotating: true, armed: true, due: true }) },
  { id: 'armed-clear-now', name: 'handoff armed, waiting for a press', facts: facts({ rotating: true, armed: true, due: true }) },
  { id: 'feed-off', name: 'idle, the feed mod installed and off', facts: facts({ feed: { on: false } }) },
  { id: 'feed-on', name: 'idle, the feed on', facts: facts({ feed: { on: true } }) },
  { id: 'queue-waiting', name: 'tasks queued, nothing running them', facts: facts({ waiting: 3 }) },
  { id: 'queue-running', name: 'the queue running its tasks', facts: facts({ queued: 3, queueRunning: true }) },
  { id: 'gate-running', name: 'a /finish gate running', facts: facts({ gate: 'finishing fix-auth · gate 1m 12s' }) },
  { id: 'mail', name: 'mail from another session', facts: facts({ mail: 2 }) },
  { id: 'features-ready', name: 'a feature ready to finish', facts: facts({ featured: word([feature('ready'), feature('dirty'), feature('merged')], true) }) },
  // Every word an idle band can carry at once: the most a line is asked to hold.
  { id: 'everything', name: 'every word an idle band can carry at once', facts: facts({
    featured: word([feature('ready'), feature('dirty'), feature('merged')], true), ...DUE,
    feed: { on: true }, waiting: 2, mail: 1, rail: { prompts: PROMPTS.slice(0, 6), named: 5, refused: [] },
  }) },
  { id: 'rail-few', name: 'three prompts on the rail', facts: facts({ rail: { prompts: PROMPTS.slice(0, 3), named: 2, refused: [] } }) },
  { id: 'rail-many', name: 'fourteen prompts, the oldest folded', facts: facts({ rail: { prompts: PROMPTS.slice(), named: 13, refused: [5] } }) },
  { id: 'no-chords', name: 'context past the threshold, keybindings unbound', facts: facts({ ...DUE, chords: {} }) },
  { id: 'rotate-wrapped', name: 'past the threshold after /wrap ran in this conversation', facts: facts({ rotating: true, due: true }) },
  { id: 'countdown-session', name: 'handoff armed, the count still in the session colour', facts: facts({ countdown: { seconds: 15 }, rotating: true, armed: true, due: true }) },
  { id: 'countdown-crit', name: 'handoff armed, seconds from the /clear', facts: facts({ countdown: { seconds: 3 }, rotating: true, armed: true, due: true }) },
  { id: 'armed-with-queue', name: 'handoff armed with tasks queued', facts: facts({ rotating: true, armed: true, due: true, queued: 3 }) },
  { id: 'due-midturn', name: 'a turn running past the threshold, with mail', facts: facts({ due: true, mail: 2 }) },
  { id: 'queued-blocked', name: 'tasks queued while a turn runs', facts: facts({ queued: 3 }) },
  { id: 'survey-gate', name: 'a survey up while a /finish gate runs', facts: facts({ survey: true, gate: 'finishing fix-auth · gate 1m 12s' }) },
  { id: 'features-many-ready', name: 'several features ready to finish', facts: facts({ featured: word([feature('ready'), feature('ready'), feature('dirty')], true) }) },
  ...ONE_FEATURE.map(([sid, record]): BandState => ({ id: `features-one-${sid}`, name: sid === 'ready' ? 'one feature, ready to finish' : `one feature, not ready: ${sid.replace('-', ' ')}`, facts: facts({ featured: word([record], true) }) })),
  { id: 'features-none-ready', name: 'several features, none ready', facts: facts({ featured: word([feature('dirty'), feature('locked'), feature('staged')], true) }) },
  { id: 'features-midturn', name: 'a turn running, the ready feature not pressable', facts: facts({ featured: word([feature('ready')], false) }) },
  { id: 'chords-mixed', name: 'keys bound under different prefixes', facts: facts({ ...DUE, chords: { rotate: 'ctrl+x 1', wrap: 'ctrl+y 2' } }) },
  { id: 'chords-partial', name: 'only the rotate key bound', facts: facts({ ...DUE, chords: { rotate: 'ctrl+x 1' } }) },
  { id: 'rail-no-label', name: 'the words leaving the rail no room to name a prompt', facts: facts({ ...DUE, feed: { on: true }, waiting: 2, rail: { prompts: PROMPTS.slice(0, 6), named: 5, refused: [] } }) },
  { id: 'rail-uncoloured', name: 'the rail in a session with no colour', facts: facts({ colour: null, rail: { prompts: PROMPTS.slice(0, 3), named: 2, refused: [] } }) },
  { id: 'rail-desktop', name: 'the rail on the desktop app, no hover cards', facts: facts({ surface: 'desktop', rail: { prompts: PROMPTS.slice(0, 3), named: 2, refused: [] } }) },
]

// ---- the rows Claude Code draws around cs's words ----
// One state per line the mod can hand the engine, each with the values a
// person meets it with. Keyed by the tables' own keys, so a line added to a
// table and not here fails the type-check.
const kebab = (key: string) => key.replace(/[A-Z]/g, c => `-${c.toLowerCase()}`)
type Line = { name: string; draw: (cols: number) => RenderElement }
const chromeStates = <K extends string>(lines: Record<K, Line>): State[] =>
  (Object.keys(lines) as K[]).map(key => ({ id: kebab(key), name: lines[key].name, draw: lines[key].draw }))

const csToast = (text: string) => (cols: number) => toast('cs', text, cols)
const TOAST_STATES: Record<keyof typeof TOASTS, Line> = {
  queued: { name: 'queuing a task with /queue', draw: csToast(TOASTS.queued('fix the login redirect')) },
  bandOption: { name: 'loading the band with a /config value it cannot draw', draw: csToast(TOASTS.bandOption('cs.bandBars is the most bars the band draws, a whole number of 1 or more; got 0')) },
  promptNotDrawn: { name: 'jumping to a prompt no row has drawn since a resume', draw: csToast(TOASTS.promptNotDrawn) },
  scrollRefused: { name: 'jumping to a prompt the engine would not scroll to', draw: csToast(TOASTS.scrollRefused('the window moved meanwhile')) },
  transcriptTail: { name: 'working in a conversation whose transcript is past 4 MiB', draw: csToast(TOASTS.transcriptTail()) },
  forceBelowStart: { name: 'starting a conversation already past the forced rotation', draw: csToast(TOASTS.forceBelowStart(70, 75)) },
  rotateFailed: { name: 'seeing a forced /rotate fail to run', draw: csToast(TOASTS.rotateFailed('Error: unknown command')) },
  clearFailed: { name: 'seeing the countdown reach zero and /clear fail to run', draw: csToast(TOASTS.clearFailed('Error: no session')) },
  nextStep: { name: 'watching the countdown start on an armed handoff', draw: csToast(TOASTS.nextStep('Run the secrets suites solo.')) },
  noRotation: { name: 'working in a session cs will not rotate', draw: csToast(TOASTS.noRotation('the launch did not say where cs is (CS_BIN)')) },
  feedFailed: { name: 'pressing feed when the feed file cannot be written', draw: csToast(TOASTS.feedFailed('EACCES: permission denied')) },
  finishFailed: { name: 'pressing the features word when /finish cannot run', draw: csToast(TOASTS.finishFailed('fix-auth', 'a turn is running')) },
  pressedNotEmptied: { name: 'ending a turn when the press marker cannot be emptied', draw: csToast(TOASTS.pressedNotEmptied('Error: EACCES')) },
  wrapFailed: { name: 'answering yes to /wrap when it cannot run', draw: csToast(TOASTS.wrapFailed('Error: no session')) },
  queueNoBin: { name: 'pressing the queue start where the launch did not say where cs is', draw: csToast(TOASTS.queueNoBin) },
  queueModeUnknown: { name: 'typing a way to run the queue cs does not know', draw: csToast(TOASTS.queueModeUnknown('in parallel please')) },
  notCompacted: { name: 'choosing Compact when the conversation is not compacted', draw: csToast(TOASTS.notCompacted('a turn is running')) },
  queueStartFailed: { name: 'starting the queue when cs cannot run', draw: csToast(TOASTS.queueStartFailed('spawn ENOENT')) },
  queueStartExited: { name: 'starting the queue when cs refuses', draw: csToast(TOASTS.queueStartExited(1, 'Error: the queue is locked')) },
  queueKickFailed: { name: "starting the queue when its first turn cannot start", draw: csToast(TOASTS.queueKickFailed('session closed')) },
  finishRecordUnread: { name: 'running /finish when its progress record is not one cs wrote', draw: csToast(TOASTS.finishRecordUnread('local')) },
  finishPidUnknown: { name: 'running /finish when its process cannot be checked', draw: csToast(TOASTS.finishPidUnknown('spawn EPERM')) },
}
const FINISH: FinishRecord = { id: '4242-1799999990', pid: 4242, task: 'fix-auth', sha: '1234567' + 'f'.repeat(33), step: 'started' }
const FINISH_STATES: State[] = [
  { id: 'finishing', name: 'running /finish on a feature', draw: csToast(finishToast(FINISH)) },
  { id: 'landed', name: 'seeing /finish land a feature', draw: csToast(finishToast({ ...FINISH, step: 'landed', result: '89abcde' + '0'.repeat(33) })) },
  { id: 'finish-refused', name: 'seeing /finish refuse a feature', draw: csToast(finishToast({ ...FINISH, step: 'refused', reason: 'the gate failed: 2 suites red' })) },
  { id: 'retired', name: 'seeing /finish retire a feature', draw: csToast(finishToast({ ...FINISH, step: 'retired' })) },
]

// The same toast outside the fullscreen renderer, one that fits and one cut.
const INLINE_STATES: State[] = [
  { id: 'queued-inline', name: 'queuing a task with /queue, outside the fullscreen renderer', draw: cols => inlineToast('cs', TOASTS.queued('fix the login redirect'), cols) },
  { id: 'force-below-start-inline', name: 'starting past the forced rotation, outside the fullscreen renderer', draw: cols => inlineToast('cs', TOASTS.forceBelowStart(70, 75), cols) },
]

const ASK_STATES: State[] = [
  { id: 'wrap', name: 'pressing the wrap key', draw: cols => askDialog(ASKS.wrap, cols) },
  { id: 'wrap-not-now', name: 'moving to Not now in the wrap dialog', draw: cols => askDialog(ASKS.wrap, cols, 1) },
  { id: 'queue-start-one', name: 'running bare /queue with one task queued', draw: cols => askDialog(ASKS.queueStart(1), cols) },
  { id: 'queue-start-many', name: 'pressing the queue start with three tasks queued', draw: cols => askDialog(ASKS.queueStart(3), cols) },
  { id: 'queue-mode', name: 'choosing how the queued tasks run', draw: cols => askDialog(ASKS.queueMode, cols) },
]

const TASK = 'fix the login redirect'
const COMMAND_STATES: State[] = [
  { id: 'queue-added', name: 'queuing a task with /queue', draw: () => commandReply('cs', 'queue', TASK, REPLIES.queued(TASK)) },
  { id: 'queue-no-bin', name: 'running /queue where the launch did not say where cs is', draw: () => commandReply('cs', 'queue', TASK, REPLIES.queueNoBin) },
  { id: 'queue-failed', name: 'running bare /queue when cs cannot run', draw: () => commandReply('cs', 'queue', '', REPLIES.queueFailed('cs -queue list', 'spawn ENOENT')) },
  { id: 'queue-exited', name: 'queuing a task cs refuses', draw: () => commandReply('cs', 'queue', TASK, REPLIES.queueExited('cs -queue add', 1, '')) },
  { id: 'cs-usage', name: 'running /cs with a word it does not take', draw: () => commandReply('cs', 'cs', 'sideways', REPLIES.csUsage) },
  { id: 'rail-empty', name: 'running /cs in a conversation with no prompts yet', draw: () => commandReply('cs', 'cs', 'next', REPLIES.railEmpty) },
  { id: 'none-after', name: 'running /cs next on the last prompt', draw: () => commandReply('cs', 'cs', 'next', REPLIES.noneAfter) },
  { id: 'none-before', name: 'running /cs prev on the first prompt', draw: () => commandReply('cs', 'cs', 'prev', REPLIES.noneBefore) },
  { id: 'rail-count', name: 'running /cs with a number past the last prompt', draw: () => commandReply('cs', 'cs', '9', REPLIES.railCount(4)) },
]

const MENU = [COMMANDS.queue, COMMANDS.cs]
const MENU_STATES: State[] = [
  { id: 'queue-selected', name: 'typing /q in the prompt', draw: cols => menuRows(MENU, 0, cols) },
  { id: 'cs-selected', name: 'moving to /cs in the slash menu', draw: cols => menuRows(MENU, 1, cols) },
]

const csLog = (text: string) => (cols: number) => logRow('cs', text, cols)
const LOG_STATES: Record<keyof typeof LOGS, Line> = {
  featuresUnread: { name: 'ending a turn when the features word cannot be read', draw: csLog(LOGS.featuresUnread('spawn ENOENT')) },
  featuresExited: { name: 'ending a turn when cs refuses to list the features', draw: csLog(LOGS.featuresExited('api', 2, 'error: the features index under .cs/local is locked by another cs process')) },
  featuresUnreadable: { name: 'ending a turn when cs lists a feature the band cannot read', draw: csLog(LOGS.featuresUnreadable('work', 'fix-auth')) },
  featuresNoAnswer: { name: 'ending a turn when cs does not answer for the features', draw: csLog(LOGS.featuresNoAnswer('work', 'spawn ENOENT')) },
  transcriptUnread: { name: 'ending a turn when the transcript cannot be read', draw: csLog(LOGS.transcriptUnread('EACCES')) },
  colorFailed: { name: 'starting a conversation whose session colour does not apply', draw: csLog(LOGS.colorFailed('red', 'Error: command refused')) },
  feedUnread: { name: 'drawing the band when the feed setting cannot be read', draw: csLog(LOGS.feedUnread('cs: $.fs.read(/work/.cs/local/feed) failed: EACCES')) },
}

const chromeSurface = (slot: string, states: State[]): Surface => ({ id: `cs.${slot}`, mod: 'cs', slot, source: 'chrome', global: 'CsSurfaces', states, parts: [] })

export const surfaces: Surface[] = [{
  id: 'cs.AbovePrompt',
  mod: 'cs',
  slot: 'AbovePrompt',
  source: 'generated',
  global: 'CsSurfaces',
  chrome: { kind: 'above-prompt' },
  states: STATES.map(s => ({ id: s.id, name: s.name, draw: (cols: number, theme: Theme) => band(s.facts, cols, theme) })),
  parts: [
    { id: 'band-mark', name: 'band mark', state: 'rotate-due', path: [1, 0, 0] },
    { id: 'chord', name: 'chord key', state: 'rotate-due', path: [1, 0, 2] },
    { id: 'chord-word', name: 'chord word Button', state: 'rotate-due', path: [1, 0, 3] },
    { id: 'countdown', name: 'countdown word', state: 'countdown', path: [1, 0, 1] },
    { id: 'rail-tick', name: 'rail tick', state: 'rail-few', path: [1, 0, 1, 0] },
    { id: 'prompt-label', name: 'prompt label', state: 'rail-few', path: [1, 0, 2] },
  ],
},
  chromeSurface('toast', [...chromeStates(TOAST_STATES), ...FINISH_STATES, ...INLINE_STATES]),
  chromeSurface('ask', ASK_STATES),
  chromeSurface('command', COMMAND_STATES),
  chromeSurface('menu', MENU_STATES),
  chromeSurface('log', chromeStates(LOG_STATES)),
]
