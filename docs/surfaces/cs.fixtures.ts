// ABOUTME: The cs band in each state: facts turned into the BandView the mod's AbovePrompt hook builds, drawn by the mod's own drawBand.
// ABOUTME: The facts are the band catalogue the variants gallery shares; typed against BandView, so a change to it breaks this file at type-check.
import type { RenderElement } from 'claude-code'
import {
  AMBER_AT, CRIT_AT, FEED_ACTION, MARK_INK, ROTATE_ACTION, WRAP_ACTION,
  bandState, buildBandEntries, countdownColor, drawBand, featuresWordOf, paletteColor,
  type BandView, type FeatureRecord,
} from '../../mods/cs/hooks/register.tsx'
import { elements, type Surface, type Theme } from './registry.ts'

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

// The BandView the hook would hand drawBand for these facts, in a terminal
// `cols` wide and the light or dark theme. The engine's own drawing is
// nothing, or a stand-in for its survey, which owns the band.
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
  const drawn = f.survey ? el.Box({ children: [el.Text({ dimColor: true, children: 'How is Claude doing this session? (the engine draws its survey here)' })] }) : el.Box({})
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
const DUE = { rotating: true, wrapping: true, due: true }

export type BandState = { id: string; name: string; facts: Facts }
// The catalogue the gallery draws, in its order.
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
]

export const surfaces: Surface[] = [{
  id: 'cs.AbovePrompt',
  mod: 'cs',
  slot: 'AbovePrompt',
  source: 'generated',
  global: 'CsSurfaces',
  needs: ['hover', 'focus inverse', 'engine drawing'],
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
}]
