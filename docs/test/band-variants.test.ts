// ABOUTME: Tests for the band variants gallery in docs/mods-band-variants.js.
// ABOUTME: Pins the state catalogue, the shipped band's port against register.tsx, and every sketch against the engine.
import { test, expect } from 'bun:test'
const { STATES, VARIANTS } = require('../mods-band-variants.js')
const { layout, toText, validate } = require('../mods-layout.js')

const state = (id: string) => {
  const found = STATES.find((s: any) => s.id === id)
  if (found === undefined) throw new Error(`no state ${id}`)
  return found.facts
}

test('the catalogue names every state the gallery draws, in order', () => {
  expect(STATES.map((s: any) => s.id)).toEqual([
    'idle', 'rotate-due', 'countdown', 'armed-clear-now', 'feed-off', 'feed-on', 'queue-waiting', 'queue-running',
    'gate-running', 'mail', 'features-ready', 'everything', 'rail-few', 'rail-many', 'no-chords',
  ])
})

test('the catalogue carries the labels buildBandEntries and its producers write', () => {
  expect(state('features-ready').featured).toEqual({ label: '3 features · fix-auth ready', pressable: true })
  expect(state('gate-running').gate).toBe('finishing fix-auth · gate 1m 12s')
  expect(state('countdown').countdown).toEqual({ seconds: 7, ink: 'amber' })
  expect(state('rail-few').rail.prompts.length).toBe(3)
  expect(state('rail-many').rail.prompts.length).toBe(14)
  expect(state('no-chords').chords).toEqual({})
  expect(state('rotate-due').chords).toEqual({ rotate: 'ctrl+x 1', wrap: 'ctrl+x 2', feed: 'ctrl+x 3' })
})

const variant = (id: string) => {
  const found = VARIANTS.find((v: any) => v.id === id)
  if (found === undefined) throw new Error(`no variant ${id}`)
  return found
}
const lines = (variantId: string, stateId: string, cols: number) => toText(layout(variant(variantId).draw(state(stateId), cols, 'light'), cols))

test('the gallery draws the shipped band first, then the sketches', () => {
  expect(VARIANTS.map((v: any) => v.id)).toEqual(['shipped', 'quiet', 'keys-first', 'status-first'])
})

// Each sketch in the state that shows what it tries, worked by hand from its
// note before it was drawn.
const SKETCHES: [string, string, number, string[]][] = [
  ['quiet', 'rotate-due', 80, [' '.repeat(29), '  rotate   wrap    ctrl+x 1 2']],
  ['quiet', 'everything', 60, [' '.repeat(59), '  3 features \u00b7 fix-auth ready   rotate   wrap   feed \u2713   \u20263']],
  ['keys-first', 'rotate-due', 80, [' '.repeat(26), '  ctrl+x  1 rotate  2 wrap']],
  ['keys-first', 'countdown', 80, [' '.repeat(36), '  ctrl+x  1 /clear now  /clear in 7s']],
  ['status-first', 'countdown', 80, [' '.repeat(46), '  armed  /clear in 7s  \u00b7  ctrl+x  1 /clear now']],
  ['status-first', 'gate-running', 80, [' '.repeat(48), '  running gate  finishing fix-auth \u00b7 gate 1m 12s']],
]
for (const [v, s, cols, want] of SKETCHES) {
  test(`${v} draws ${s} at ${cols} cols as its note describes`, () => {
    expect(lines(v, s, cols)).toEqual(want)
  })
}

// Read off the draw site in mods/cs/hooks/register.tsx, by hand: a blank row
// (marginTop 1), the 2-cell inset, the mark and its gap, the shared prefix and
// its two cells, each key and one cell, the labels, the dim separator.
test('shipped draws the rotate-due band register.tsx draws', () => {
  expect(lines('shipped', 'rotate-due', 80)).toEqual([
    ' '.repeat(31),
    '  \u25cf ctrl+x  1 rotate  \u00b7  2 wrap',
  ])
})

test('shipped draws nothing when the band has nothing to say', () => {
  expect(variant('shipped').draw(state('idle'), 80, 'light')).toBeNull()
})

// 14 prompts, cs.bandBars 10, no words at 80 cols: the budget is 80 - 2 - 2 =
// 76; railTicks starts at hidden 14 - 10 = 4 and 10 bars + `…4` is 12 <= 76.
// The label takes 76 - 12 - 2 = 62 cells.
test('shipped folds the oldest four of fourteen prompts and names the newest', () => {
  const label = '#14 run the full suite and fix what fails'
  expect(lines('shipped', 'rail-many', 80)[1]).toBe('  \u25cf \u20264\u2502\u2506\u2502\u2502\u2502\u2502\u2502\u2502\u2502\u2503  ' + label + ' '.repeat(62 - label.length))
})

test('every variant that draws a rail folds fourteen prompts into \u20264 at 80 cols', () => {
  const railed = VARIANTS.filter((v: any) => lines(v.id, 'rail-many', 80).some((row: string) => row.includes('\u2503')))
  expect(railed.map((v: any) => v.id)).toEqual(['shipped', 'keys-first', 'status-first'])
  for (const v of railed) expect({ variant: v.id, folded: lines(v.id, 'rail-many', 80).some((row: string) => row.includes('\u20264')) }).toEqual({ variant: v.id, folded: true })
})

const cells = () => VARIANTS.flatMap((v: any) => STATES.map((s: any) => ({ v, s })))

test('the engine accepts every variant in every state', () => {
  for (const { v, s } of cells()) {
    for (const theme of ['light', 'dark']) expect({ cell: `${v.id} / ${s.id} / ${theme}`, refused: validate(v.draw(s.facts, 80, theme)) }).toEqual({ cell: `${v.id} / ${s.id} / ${theme}`, refused: [] })
  }
})

// The cells that overrun 60 cols, each declared in its variant's note.
test('the cells that clip at 60 cols are the ones the notes name', () => {
  const clipped = cells().filter(({ v, s }: any) => layout(v.draw(s.facts, 60, 'light'), 60).w > 60).map(({ v, s }: any) => `${v.id} / ${s.id}`)
  expect(clipped).toEqual(['shipped / everything', 'keys-first / everything', 'status-first / everything'])
})

test('every variant fits 60 cols in every state, or its note says it clips', () => {
  for (const { v, s } of cells()) {
    const w = layout(v.draw(s.facts, 60, 'light'), 60).w
    expect({ cell: `${v.id} / ${s.id}`, fits: w <= 60 || /\bclips\b/.test(v.note) }).toEqual({ cell: `${v.id} / ${s.id}`, fits: true })
  }
})

// Glyphs a monospace terminal font renders: box drawing, the mark, the queue
// glyph, the middle dot, the ellipsis and the check. Never the Miscellaneous
// Symbols block, emoji, or the small square, which render as tofu or too light.
test('no variant draws a glyph outside the terminal-safe set', () => {
  const allowed = /^[\x20-\x7e\u2500-\u257f\u25cf\u25a4\u00b7\u2026\u2713]*$/u
  for (const { v, s } of cells()) {
    for (const cols of [60, 80]) {
      const text = lines(v.id, s.id, cols).join('\n')
      expect({ cell: `${v.id} / ${s.id} / ${cols}`, banned: /[\u2600-\u26ff\u25aa]|[\u{1f000}-\u{1faff}]/u.test(text) }).toEqual({ cell: `${v.id} / ${s.id} / ${cols}`, banned: false })
      expect({ cell: `${v.id} / ${s.id} / ${cols}`, safe: text.split('\n').every(row => allowed.test(row)) }).toEqual({ cell: `${v.id} / ${s.id} / ${cols}`, safe: true })
    }
  }
})
