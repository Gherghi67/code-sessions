// ABOUTME: Tests for the band variants gallery in docs/mods-band-variants.js.
// ABOUTME: Pins the state catalogue, the shipped band (the cs mod's own drawBand, bundled) against register.tsx read by hand, and every sketch against the engine.
import { test, expect } from 'bun:test'
import './surfaces.ts'
const { STATES, VARIANTS } = require('../mods-band-variants.js')
const { layout, toText, validate, toJsx } = require('../mods-layout.js')

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
  expect(state('countdown').countdown).toEqual({ seconds: 7 })
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
  expect(VARIANTS.map((v: any) => v.id)).toEqual(['shipped', 'quiet', 'keys-first', 'status-first', 'two-zone', 'rail-first', 'capsule', 'stacked'])
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
  ['two-zone', 'rail-many', 80, [' '.repeat(80), '  \u25cf ' + ' '.repeat(21) + '#14 run the full suite and fix what fails  \u20264\u2502\u2506\u2502\u2502\u2502\u2502\u2502\u2502\u2502\u2503']],
  ['two-zone', 'everything', 120, [' '.repeat(120), '  \u25cf 3 features \u00b7 fix-auth ready  \u00b7  ctrl+x  1 rotate  \u00b7  2 wrap  \u00b7  3 feed \u2713  \u00b7  \u25a4 queue 2 \u00b7 start  \u00b7  mail 1' + ' '.repeat(5) + '\u2502\u2502\u2502\u2502\u2502\u2503']],
  ['rail-first', 'rotate-due', 80, [' '.repeat(80), '  ' + ' '.repeat(53) + 'ctrl+x 1 rotate  2 wrap \u25cf']],
  ['rail-first', 'rail-many', 80, [' '.repeat(80), '  \u20264\u2502\u2506\u2502\u2502\u2502\u2502\u2502\u2502\u2502\u2503  #14 run the full suite and fix what fails' + ' '.repeat(21) + ' \u25cf']],
  ['capsule', 'rotate-due', 80, ['  \u256d' + '\u2500'.repeat(29) + '\u256e', '  \u2502 ctrl+x  1 rotate  \u00b7  2 wrap \u2502', '  \u2570' + '\u2500'.repeat(29) + '\u256f']],
  ['capsule', 'rail-few', 80, ['  \u256d' + '\u2500'.repeat(47) + '\u256e', '  \u2502 \u2502\u2502\u2503  #3 why does the cache miss on first load \u2502', '  \u2570' + '\u2500'.repeat(47) + '\u256f']],
  ['stacked', 'everything', 120, [
    ' '.repeat(109),
    '  \u25cf 3 features \u00b7 fix-auth ready  \u00b7  ctrl+x  1 rotate  \u00b7  2 wrap  \u00b7  3 feed \u2713  \u00b7  \u25a4 queue 2 \u00b7 start  \u00b7  mail 1',
    '    \u2502\u2502\u2502\u2502\u2502\u2503  #6 make the sidebar collapse on narrow screens' + ' '.repeat(51),
  ]],
  ['stacked', 'rail-many', 80, [' '.repeat(59), '  \u25cf \u20264\u2502\u2506\u2502\u2502\u2502\u2502\u2502\u2502\u2502\u2503  #14 run the full suite and fix what fails']],
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

// The inks the shipped band carries, cell by cell, on the light theme, as
// register.tsx's constants spell them: the mark amber (AMBER_LIGHT 180,83,9)
// while a rotation is due, the keys and the feed check in the session colour
// (the palette's orange, 217,119,87), a 7 s count amber and bold. The
// columns are counted off the oracle lines: `  ● ctrl+x  1 rotate  ·  2 wrap`
// puts the mark at 2 and the first key at 12; `  ● ctrl+x  3 feed ✓` puts the
// check at 19; `  ● /clear in 7s  ·  ...` starts the countdown word at 4.
const bandRow = (variantId: string, stateId: string) => layout(variant(variantId).draw(state(stateId), 80, 'light'), 80).rows[1]
test('shipped paints the mark, the keys, the feed check and the countdown in their inks', () => {
  expect(bandRow('shipped', 'rotate-due')[2]).toMatchObject({ ch: '\u25cf', st: { color: 'rgb(180,83,9)', dim: false } })
  expect(bandRow('shipped', 'rotate-due')[12]).toMatchObject({ ch: '1', st: { color: 'rgb(217,119,87)', bold: true, dim: false } })
  expect(bandRow('shipped', 'feed-on')[19]).toMatchObject({ ch: '\u2713', st: { color: 'rgb(217,119,87)', dim: false } })
  expect(bandRow('shipped', 'countdown')[4]).toMatchObject({ ch: '/', st: { color: 'rgb(180,83,9)', bold: true, dim: false } })
})

test('shipped prints the feed chord with its coloured check as the Button children register.tsx writes', () => {
  const tree = variant('shipped').draw(state('feed-on'), 80, 'light')
  expect(toJsx(tree)).toContain("<Button key=\"cs-feed\" action=\"strip:jump3\" plain label={'feed \\u2713'} onPress={press}>feed <Text color=\"rgb(217,119,87)\">{'\\u2713'}</Text></Button>")
})

// Every sketch that spells a chord's key beside its word holds the two in
// one Box keyed for the chord, so the designer moves them together. The
// quiet line spells its keys apart from the words, in one trailing hint; the
// shipped band is the mod's own, which draws the key and the Button side by side.
const ROLES: Record<string, string> = { 'strip:jump1': 'rotate', 'strip:jump2': 'wrap', 'strip:jump3': 'feed' }
test('every sketch with keys beside words groups each chord\'s key with its Button', () => {
  const loose: string[] = []
  for (const v of VARIANTS.filter((x: any) => x.id !== 'quiet' && x.id !== 'shipped')) for (const s of STATES) {
    const walk = (n: any, parent: any) => {
      if (!n || typeof n !== 'object') return
      const role = n.type === 'Button' && ROLES[n.props.action]
      if (role && s.facts.chords[role] !== undefined) {
        const kids = parent.children.filter(Boolean)
        if (parent.props.key !== `cs-chord-${role}` || kids.length !== 2 || kids[1] !== n) loose.push(`${v.id} / ${s.id} / ${role}`)
      }
      ;(n.children || []).forEach((k: any) => walk(k, n))
    }
    walk(v.draw(s.facts, 80, 'light'), null)
  }
  expect(loose).toEqual([])
})

// With nothing to say, drawBand hands back what the engine drew: nothing.
test('shipped draws nothing when the band has nothing to say', () => {
  expect(layout(variant('shipped').draw(state('idle'), 80, 'light'), 80).h).toBe(0)
})

// The band is handed the terminal less the five `[-]` cells: at 80 cols
// bodyColumns is 75. 14 prompts, cs.bandBars 10, no words: the budget is
// 75 - 2 - 2 = 71; railTicks starts at hidden 14 - 10 = 4 and 10 bars + `…4`
// is 12 <= 71. The label takes 71 - 12 - 2 = 57 cells.
test('shipped folds the oldest four of fourteen prompts and names the newest', () => {
  const label = '#14 run the full suite and fix what fails'
  expect(lines('shipped', 'rail-many', 80)[1]).toBe('  \u25cf \u20264\u2502\u2506\u2502\u2502\u2502\u2502\u2502\u2502\u2502\u2503  ' + label + ' '.repeat(57 - label.length))
})

// The fewest cells a named prompt gets. rail-few has no words, so under
// shipped labelCells = cols - 5 ([-]) - 2 (inset) - 2 (mark) - 3 (bars) - 2
// (gap): 24 cols leave 10, the minimum, and the label is cut to fit; 23
// leave 9, and no label is drawn.
test('shipped names the prompt when ten cells are left after the rail, and not at nine', () => {
  expect(lines('shipped', 'rail-few', 24)).toEqual([' '.repeat(19), '  \u25cf \u2502\u2502\u2503  #3 why do\u2026'])
  expect(lines('shipped', 'rail-few', 23)).toEqual([' '.repeat(7), '  \u25cf \u2502\u2502\u2503'])
})

// A wide glyph takes two cells, as register.tsx's cellWidth counts it. The
// prompt `#3 translate the \u8a2d\u5b9a page` is 24 code points and 26 cells: at 80 cols
// its 66-cell label pads with 40 spaces; at 34 cols the 20-cell label keeps
// 17 cells, the first wide glyph (19) and the ellipsis. Read off the label's
// Text (dim, where the hover cards beside it are not), since the engine here
// pads its Box by code points.
test('shipped measures and cuts a prompt with wide glyphs by cells, not code points', () => {
  const wide = { ...state('rail-few'), rail: { prompts: ['fix the login redirect', 'add a retry to the upload client', 'translate the \u8a2d\u5b9a page'], named: 2, refused: [] } }
  const label = (cols: number) => {
    const found: string[] = []
    const walk = (n: any) => { if (n.type === 'Text' && n.props.italic && n.props.dimColor) found.push(n.children[0]); (n.children || []).forEach((k: any) => k && typeof k === 'object' && walk(k)) }
    walk(variant('shipped').draw(wide, cols, 'light'))
    return found
  }
  expect(label(80)).toEqual(['#3 translate the \u8a2d\u5b9a page' + ' '.repeat(40)])
  expect(label(34)).toEqual(['#3 translate the \u8a2d\u2026'])
})

test('every variant that draws a rail folds fourteen prompts into \u20264 at 80 cols', () => {
  const railed = VARIANTS.filter((v: any) => lines(v.id, 'rail-many', 80).some((row: string) => row.includes('\u2503')))
  expect(railed.map((v: any) => v.id)).toEqual(['shipped', 'keys-first', 'status-first', 'two-zone', 'rail-first', 'capsule', 'stacked'])
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
  expect(clipped).toEqual(['shipped / everything', 'keys-first / everything', 'status-first / everything', 'two-zone / everything', 'rail-first / everything', 'capsule / everything', 'stacked / everything'])
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
