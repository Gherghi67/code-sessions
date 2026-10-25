// ABOUTME: Tests for the lab's surface registry: each bundled mod surface, its states drawn by the mod's own code, and its parts.
// ABOUTME: Expected rows are read off the mods' draw code by hand, never off the lab's own output.
import { test, expect } from 'bun:test'
import { SURFACES, state, surface } from './surfaces.ts'
const { layout, toText, validate } = require('../mods-layout.js')

const rows = (id: string, cols: number, width = cols) => toText(layout(state(id).draw(cols, 'light'), width)).map((r: string) => r.replace(/\s+$/, ''))

test('every surface is named <mod>.<slot> and comes from a generated bundle', () => {
  for (const s of SURFACES) {
    expect({ id: s.id, prefix: s.id.startsWith(`${s.mod}.${s.slot}`), source: s.source }).toEqual({ id: s.id, prefix: true, source: 'generated' })
  }
  expect(new Set(SURFACES.map((s: any) => s.id)).size).toBe(SURFACES.length)
})

test('every state has a unique id, a name, and draws a tree the engine accepts, light and dark', () => {
  for (const s of SURFACES) {
    expect({ surface: s.id, unique: new Set(s.states.map((x: any) => x.id)).size === s.states.length }).toEqual({ surface: s.id, unique: true })
    for (const st of s.states) for (const theme of ['light', 'dark']) {
      const tree = st.draw(80, theme)
      expect({ frame: `${s.id}/${st.id}/${theme}`, named: st.name.length > 0, refused: validate(tree) }).toEqual({ frame: `${s.id}/${st.id}/${theme}`, named: true, refused: [] })
    }
  }
})

// A state names what a person sees, so two states of one surface that draw
// the same cells, character and ink, in both themes, at rest and with the
// pointer over each of its Buttons, name one thing twice. The pointer is what
// tells the rail's hover cards (absent on the desktop) and a call's pressable
// chevron (a Button, which inverts under it) from their twins at rest.
const buttonPaths = (n: any, path: number[] = [], out: number[][] = []): number[][] => {
  if (!n || typeof n !== 'object') return out
  if (n.type === 'Button') out.push(path)
  ;(n.children || []).forEach((k: any, i: number) => buttonPaths(k, path.concat([i]), out))
  return out
}
test('no two states of a surface draw the same screen at 80 cols, light and dark, at rest or under the pointer', () => {
  const { layoutScreen, interact } = require('../mods-layout.js')
  const paint = (tree: any) => layoutScreen(tree, 80).rows.map((r: any[]) => r.map(c => c.ch + JSON.stringify(c.st)).join('')).join('\n')
  const screen = (st: any) => ['light', 'dark'].map(theme => {
    const tree = st.draw(80, theme)
    return [paint(tree), ...buttonPaths(tree).map(hover => paint(interact(tree, { hover, focus: null })))].join('\n\n')
  }).join('\n\n')
  const twins: string[] = []
  for (const s of SURFACES) {
    const seen = new Map<string, string>()
    for (const st of s.states) {
      const key = screen(st), first = seen.get(key)
      if (first === undefined) seen.set(key, st.id)
      else twins.push(`${s.id}: ${first} == ${st.id}`)
    }
  }
  expect(twins).toEqual([])
})

// The pointer over a rail bar, worked by hand from drawBand: the bar is a
// Button, so it inverts and drops its dim; its hover.scope lights the card of
// the same scope, an absolute Box at the label's top left that swaps
// display none for flex, so the hovered prompt, italic and not dim, covers
// the named one (both padded by fitLeft to the label's 66 cells).
const pathOfKey = (n: any, key: string, path: number[] = []): number[] | undefined => {
  if (!n || typeof n !== 'object') return undefined
  if (n.props?.key === key) return path
  for (let i = 0; i < (n.children || []).length; i++) { const p = pathOfKey(n.children[i], key, path.concat([i])); if (p) return p }
  return undefined
}
test('cs draws a rail bar under the pointer inverted, with its prompt over the named one', () => {
  const { layoutScreen, interact } = require('../mods-layout.js')
  const tree = state('cs.AbovePrompt/rail-few').draw(80, 'light')
  const g = layoutScreen(interact(tree, { hover: pathOfKey(tree, 'cs-rail-0'), focus: null }), 75)
  expect(toText(g)[1].replace(/\s+$/, '')).toBe('  \u25cf \u2502\u2502\u2503  #1 fix the login redirect')
  expect([g.rows[1][4].st, g.rows[1][5].st.inverse, g.rows[1][9].st]).toMatchObject([{ inverse: true, dim: false }, false, { italic: true, dim: false }])
  expect(toText(layoutScreen(tree, 75))[1].replace(/\s+$/, '')).toBe('  \u25cf \u2502\u2502\u2503  #3 why does the cache miss on first load')
})

// ctrl+x tab moves the focus along the band's Buttons; the focused one
// inverts, its words only: the key beside it is a Text of its own.
test('cs draws the focused Button of the band inverted', () => {
  const { layoutScreen, interact } = require('../mods-layout.js')
  const tree = state('cs.AbovePrompt/rotate-due').draw(80, 'light')
  const row = layoutScreen(interact(tree, { hover: null, focus: pathOfKey(tree, 'cs-rotate') }), 75).rows[1]
  expect(row.map((c: any) => c.ch).join('').replace(/\s+$/, '')).toBe('  \u25cf ctrl+x  1 rotate  \u00b7  2 wrap')
  expect(row.map((c: any, x: number) => c.st.inverse ? x : -1).filter((x: number) => x >= 0)).toEqual([14, 15, 16, 17, 18, 19])
})

// A node of a state's tree by child index path, as a layout cell names it.
const partNode = (surfaceId: string, part: any) => {
  let n = state(`${surfaceId}/${part.state}`).draw(80, 'light')
  for (const i of part.path) n = n && typeof n === 'object' ? n.children[i] : undefined
  return n
}
test('every part names an element of its state', () => {
  for (const s of SURFACES) for (const p of s.parts) {
    const n = partNode(s.id, p)
    expect({ part: `${s.id}#${p.id}`, element: !!n && typeof n === 'object' }).toEqual({ part: `${s.id}#${p.id}`, element: true })
  }
})

// drawPane: a column padded one cell each side; the title, a blank row, the
// phase lines, then each section after a blank row: its version, then each
// kept line verbatim (parseSpan strips the marks and keeps a continuation's indent).
test('cs-update draws the pane with its notes, keys above them', () => {
  expect(rows('cs-update.Pane.cs-update/idle-notes', 80)).toEqual([
    ' cs 2026.10.25 is available',
    '',
    ' 1: update now   Esc: later',
    ' Installs in place; the new files take effect on your next launch.',
    '',
    ' 2026.10.25',
    " - The band's mark keeps its colour",
    ' - cs -update checks the signature',
    '   before it installs',
    '',
    ' 2026.10.20',
    ' - A link survives as text',
  ])
})

test('cs-update says the notes were not fetched, and names the version', () => {
  expect(rows('cs-update.Pane.cs-update/idle-no-notes', 80).slice(-1)).toEqual([' Release notes could not be fetched at launch; the update is 2026.10.25.'])
})

test('cs-update retires the key once the update is done, and keeps it after a failure', () => {
  expect(rows('cs-update.Pane.cs-update/done', 80).slice(2, 4)).toEqual([' Update finished. Takes effect on your next launch.', ' Esc: close'])
  expect(rows('cs-update.Pane.cs-update/failed-no-bin', 80).slice(2, 4)).toEqual([' The launch did not say where cs is; run `cs -update` from a shell.', ' 1: update now   Esc: later'])
  expect(rows('cs-update.Pane.cs-update/running', 80)[2]).toBe(' updating… running cs -update 2026.10.25')
})

// The version heading is bold in the session colour as rgb (SESSION_PALETTE
// blue, 106,155,204), and in the default ink for a session with none.
test('cs-update paints the release heading in the session colour', () => {
  const heading = (id: string) => layout(state(id).draw(80, 'light'), 80).rows[5][1].st
  expect(heading('cs-update.Pane.cs-update/idle-notes')).toMatchObject({ color: 'rgb(106,155,204)', bold: true })
  expect(heading('cs-update.Pane.cs-update/idle-no-colour')).toMatchObject({ color: '', bold: true })
})

test('cs-update parts name the hotkey Button and a release heading', () => {
  const s = surface('cs-update.Pane.cs-update')
  const at = (id: string) => partNode(s.id, s.parts.find((x: any) => x.id === id))
  expect(at('update-key')).toMatchObject({ type: 'Button', props: { key: 'cs-update-now', hotkey: '1', label: 'update now' } })
  expect(at('release-heading')).toMatchObject({ type: 'Text', children: ['2026.10.25'] })
})

// drawUser and drawCall, read by hand: every row after the 7-cell margin
// (paddingLeft pad), a nested peer 2 cells further; hookNotice and peerLine
// prefix their glyphs; a call's mark, words, each chip and its chevron sit
// one cell apart.
test('cs-feed draws its rows after the name margin', () => {
  expect(rows('cs-feed.UserMessage/hook-text', 80)).toEqual(['       \u25cb cs: the band names prompt 4'])
  expect(rows('cs-feed.UserMessage/peer-nested', 80)).toEqual(['         \u21c4 fix-auth \u00b7 gate green, ready to land'])
  expect(rows('cs-feed.ToolUse/call-errored', 80)).toEqual(['       \u25cb Show the working tree 1 failed +1 line \u203a'])
  expect(rows('cs-feed.ToolGroup/batch-failed', 80)[0]).toBe('       \u2715 3 helpers \u00b7 2 done \u00b7 1 failed \u00b7 42s \u203a')
})

// drawCommandOutput: the 7-cell margin, the dot dim in a 2-cell Box, then
// the answer, red and not dim when the command refused.
test('cs-feed draws a command\'s answer after a dim dot in two cells', () => {
  expect(rows('cs-feed.CommandOutput/errored', 80)).toEqual(['       · no feed change in this session: cs refused this session'])
  const g = layout(state('cs-feed.CommandOutput/errored').draw(80, 'light'), 80)
  expect([g.rows[0][7].st.dim, g.rows[0][9].st]).toMatchObject([true, { color: '#b42318', dim: false }])
})

// drawHelpersPane: the mark and the head one cell apart, then the helper's
// now line and its calls each 2 cells in, dim.
test('cs-feed draws the Helpers pane\'s now line and calls two cells under the head', () => {
  expect(rows('cs-feed.Pane.cs-feed-helpers/working', 80)).toEqual([
    '● Explore · working · 1m 12s',
    '  now: Reading draw.tsx',
    '  Searched the code for drawBand',
    '  Read words.ts',
  ])
  const g = layout(state('cs-feed.Pane.cs-feed-helpers/working').draw(80, 'light'), 80)
  expect([g.rows[0][0].st, g.rows[1][2].st.dim]).toMatchObject([{ color: '#d97757', dim: false }, true])
})

// drawBand's helpers: the head after the 7-cell margin, then a row per kind,
// one cell between the kind, each of its cells and its fraction.
test('cs-feed draws the helpers above the prompt after the name margin', () => {
  expect(rows('cs-feed.AbovePrompt/helpers-running', 80)).toEqual([
    '       ⠋ 3 helpers · 1 done · 2 running · 1m 12s',
    '       Explore ◐ ● 1/2',
    '       Plan ◐ 0/1',
  ])
  const g = layout(state('cs-feed.AbovePrompt/helpers-running').draw(80, 'light'), 80)
  expect([g.rows[0][7].st.color, g.rows[1][15].st.color, g.rows[1][17].st.color]).toEqual(['#5b3fb5', '#5b3fb5', '#1f7a4a'])
})

// drawReply: `claude` dim in the claude ink in a 7-cell Box, then the
// engine's drawing of the reply.
test('cs-feed draws the claude margin dim beside the reply', () => {
  expect(rows('cs-feed.AssistantMessage/margin-and-reply', 80)).toEqual(['claude Fixed: the token now refreshes before fetch retries.'])
  const g = layout(state('cs-feed.AssistantMessage/margin-and-reply').draw(80, 'light'), 80)
  expect(g.rows[0][0].st).toMatchObject({ color: '#8a4a1f', dim: true })
})

// words.ts errorLine: one head in its tone, then its follow-up lines dim.
test('cs-feed draws a reply error as its head and dim follow-ups', () => {
  expect(rows('cs-feed.AssistantMessage/error-usage-limit', 80)).toEqual(['       Usage limit reached', '       resets 5pm', '       nothing is lost', '       /model to switch'])
  const g = layout(state('cs-feed.AssistantMessage/error-usage-limit').draw(80, 'light'), 80)
  expect(g.rows[0][7].st).toMatchObject({ color: '#b42318', dim: false })
  expect(g.rows[1][7].st).toMatchObject({ dim: true })
})

// drawSettingsPane: the header, the switch, then per FIELDS row its title
// Button, its value, and the command that flips it after a dot.
test('cs-feed draws the Chat view pane from the mod\'s FIELDS', () => {
  const pane = rows('cs-feed.Pane.cs-feed/clean', 80)
  expect(pane[0]).toBe('Chat view clean \u00b7 /feed clean \u00b7 /feed normal \u00b7 /feed raw \u00b7 /feed close')
  expect(pane[2]).toBe('[ Group a turn into one line ] on \u00b7 /feed group off')
  expect(rows('cs-feed.Pane.cs-feed/raw', 80)[1]).toBe('[ Feed ] off')
  expect(rows('cs-feed.Pane.cs-feed/kinds-hidden', 80).at(-2)).toContain('[ \u25cb peer ]')
})

// The band, read off drawBand by hand: a blank row (marginTop 1), the 2-cell
// inset, the mark and its gap, the shared prefix and its two cells, each key
// and one cell, the labels, the dim separator. The hook hands it the terminal
// less the five `[-]` cells, so at 80 cols bodyColumns is 75.
test('cs draws the rotate-due band as the mod does', () => {
  expect(rows('cs.AbovePrompt/rotate-due', 80)).toEqual(['', '  ● ctrl+x  1 rotate  ·  2 wrap'])
})

// Every word the band can show, 107 cells in the 73 bodyColumns 75 leaves
// after the inset: the five Buttons keep their 60 cells, every other child
// shrinks by 34/41 of its basis, so each separator, the prefix and the mail
// word get 1 cell and wrap into the rows below, and the mark and the keys
// get none and draw into the cell of their margin. Worked by hand row by row
// (scratchpad everything-80.md); the band is 6 rows tall.
test('cs draws the band of every word as the engine shrinks it into bodyColumns', () => {
  const { layoutScreen } = require('../mods-layout.js')
  const g = toText(layoutScreen(state('cs.AbovePrompt/everything').draw(80, 'light'), 75)).map((r: string) => r.replace(/\s+$/, ''))
  const at = (cells: [number, string][]) => { const r = Array(75).fill(' '); for (const [x, ch] of cells) r[x] = ch; return r.join('').replace(/\s+$/, '') }
  expect(g).toEqual([
    '',
    '  \u25cf3 features \u00b7 fix-auth ready c  1rotate 2wrap 3feed \u2713 \u25a4 queue 2 \u00b7 start m',
    at([[31, 't'], [74, 'a']]),
    at([[30, '\u00b7'], [31, 'r'], [41, '\u00b7'], [47, '\u00b7'], [55, '\u00b7'], [73, '\u00b7'], [74, 'i']]),
    at([[31, 'l'], [74, 'l']]),
    at([[31, '+']]),
    at([[31, 'x'], [74, '1']]),
  ])
})

// The frame cuts a tree at the edge of the cells it is handed. A row shrinks
// what overruns it, so only what cannot shrink ever reaches the cut. At 80
// cols one row does: the Chat view's Show row is eight Buttons, 88 cells and
// 7 gaps, in the pane's 76; a Button never shrinks, so the row runs past the
// pane, whose frame hides it (worked by hand from drawSettingsPane's kinds).
test('only the Chat view\'s row of kind Buttons draws past the cells it is handed at 80 cols', () => {
  const { layoutScreen } = require('../mods-layout.js')
  const past: string[] = []
  for (const s of SURFACES) for (const st of s.states) {
    const room = s.chrome?.kind === 'above-prompt' ? 75 : s.chrome?.kind === 'pane' ? 76 : 80
    const g = layoutScreen(st.draw(80, 'light'), room)
    const reach = g.rows.reduce((a: number, r: any[]) => Math.max(a, r.length), g.w)
    if (reach > room) past.push(`${s.id}/${st.id}: ${reach} of ${room}`)
  }
  expect(past).toEqual(['clean', 'normal', 'raw', 'custom', 'kinds-hidden', 'every-other-value'].map(id => `cs-feed.Pane.cs-feed/${id}: 95 of 76`))
})

// 14 prompts, cs.bandBars 10, no words: the budget is 75 - 2 - 2 = 71;
// railTicks folds 14 - 10 = 4 and 10 bars + `…4` is 12 <= 71. The label
// takes 71 - 12 - 2 = 57 cells, padded.
test('cs folds the oldest four of fourteen prompts and names the newest in what bodyColumns leaves', () => {
  const label = '#14 run the full suite and fix what fails'
  const line = toText(layout(state('cs.AbovePrompt/rail-many').draw(80, 'light'), 80))[1]
  expect(line).toBe('  ● …4│┆│││││││┃  ' + label + ' '.repeat(57 - label.length))
})

// register.tsx's inks: the mark amber (AMBER_LIGHT 180,83,9) while a rotation
// is due, blue (106,155,204) while the queue runs, green (22,163,74) when
// nothing is due; keys and the feed check in the session colour (orange
// 217,119,87); a 7 s count amber, bold.
test('cs paints the mark, the keys, the feed check and the count in the mod\'s inks', () => {
  const line = (id: string, theme = 'light') => layout(state(`cs.AbovePrompt/${id}`).draw(80, theme), 80).rows[1]
  expect(line('rotate-due')[2]).toMatchObject({ ch: '●', st: { color: 'rgb(180,83,9)' } })
  expect(line('rotate-due', 'dark')[2]).toMatchObject({ ch: '●', st: { color: 'rgb(253,230,138)' } })
  expect(line('queue-running')[2]).toMatchObject({ st: { color: 'rgb(106,155,204)' } })
  expect(line('mail')[2]).toMatchObject({ st: { color: 'rgb(22,163,74)' } })
  expect(line('rotate-due')[12]).toMatchObject({ ch: '1', st: { color: 'rgb(217,119,87)', bold: true } })
  expect(line('feed-on')[19]).toMatchObject({ ch: '✓', st: { color: 'rgb(217,119,87)' } })
  expect(line('countdown')[4]).toMatchObject({ ch: '/', st: { color: 'rgb(180,83,9)', bold: true } })
})

test('cs draws nothing of its own when the band has nothing to say', () => {
  expect(layout(state('cs.AbovePrompt/idle').draw(80, 'light'), 80).h).toBe(0)
})

// register.tsx's fence branch: a fence fitSource refuses is its source in a
// Code block, the reason under it, dim; one that fits is a relative canvas
// of absolute runs and blocks one blank row above and below.
test('cs-mermaid draws a refused fence as its source and the reason', () => {
  expect(state('cs-mermaid.AssistantMessage/refused').draw(80, 'light')).toEqual({
    type: 'Box', props: { flexDirection: 'column' }, children: [
      { type: 'Code', props: { source: 'graph TD\n  subgraph one\n    A --> B\n  end', language: 'mermaid' }, children: [] },
      { type: 'Text', props: { dimColor: true }, children: ['mermaid: ', 'subgraphs are not supported'] },
    ],
  })
  expect(rows('cs-mermaid.AssistantMessage/too-wide', 80).at(-1)).toBe('mermaid: diagram is 128 columns wide, the transcript 74')
})

// A fitted chart is a 20 by 16 relative canvas between the fence's blank
// rows; each run, block and label paints at its top and left on it. Worked
// by hand from the coordinates fitSource gives this source: Start's block at
// 1,5 (9 by 3, the label centred on its middle row), the arrow at 4,9 and
// 5,9, Tests pass? at 6,2, the branches and their labels at rows 9 to 11,
// Ship at 12,1 and Fix at 12,12.
test('cs-mermaid draws a fitted chart\'s blocks, lines and labels where its layout puts them', () => {
  const g = layout(state('cs-mermaid.AssistantMessage/diagram').draw(80, 'light'), 80)
  expect(toText(g).map((r: string) => r.replace(/\s+$/, ''))).toEqual([
    '', '', '',
    '       Start',
    '',
    '         \u2502',
    '         \u25bc',
    '',
    '    Tests pass?',
    '',
    '    \u2502 yes  \u2502 no',
    '    \u2502      \u2514\u2500\u2500\u2500\u2510',
    '    \u25bc          \u25bc',
    '',
    '   Ship       Fix',
    '', '', '',
  ])
  expect([g.rows[2][5].st.bg, g.rows[3][7].st.bg, g.rows[2][4].st.bg]).toEqual(['#D3F9D8', '#D3F9D8', ''])
})

// drawFence's Code holds the source; mermaid has no grammar in the engine's
// highlighter, so it draws in the plain code ink, the reason under it dim.
test('cs-mermaid draws a refused fence\'s source in the plain code ink over the dim reason', () => {
  expect(rows('cs-mermaid.AssistantMessage/refused', 80)).toEqual(['graph TD', '  subgraph one', '    A --> B', '  end', 'mermaid: subgraphs are not supported'])
  const g = layout(state('cs-mermaid.AssistantMessage/refused').draw(80, 'light'), 80)
  expect([g.rows[0][0].st, g.rows[4][0].st.dim]).toMatchObject([{ color: 'codeForeground', dim: false }, true])
})

test('cs-mermaid draws a chart that fits as absolute blocks on a relative canvas', () => {
  const tree = state('cs-mermaid.AssistantMessage/diagram').draw(80, 'light')
  expect(tree.props).toEqual({ marginY: 1 })
  expect(tree.children[0].props.position).toBe('relative')
  const start = tree.children[0].children.find((n: any) => n.props.position === 'absolute' && n.children.some((t: any) => String(t.children[0]).trim() === 'Start'))
  expect(start.children.map((t: any) => t.props.backgroundColor)).toEqual(['#D3F9D8', '#D3F9D8', '#D3F9D8'])
})

// drawUser's you row: the 7-cell margin, the words in a flexGrow Box, then
// the time, so the time ends the terminal's row; the desktop band is
// justified flex-end, so its pills end it too.
test('cs-feed\'s time column and desktop band reach the right edge of the row', () => {
  const { layoutScreen } = require('../mods-layout.js')
  const screen = (id: string) => toText(layoutScreen(state(id).draw(80, 'light'), 80))
  expect(screen('cs-feed.UserMessage/you-at')[1]).toBe('you    fix the login redirect' + ' '.repeat(80 - 7 - 22 - 5) + '09:41')
  expect(screen('cs-feed.AbovePrompt/desktop')[0].endsWith('⚗ Test · bun test · 12s')).toBe(true)
  expect(screen('cs-feed.AbovePrompt/desktop')[0].length).toBe(80)
})

test('cs-update prints a failed update\'s stderr tail under its exit line', () => {
  expect(rows('cs-update.Pane.cs-update/failed-exit', 80).slice(2, 6)).toEqual([' cs -update exited 3.', ' download failed', ' checksum mismatch', ' 1: update now   Esc: later'])
})

// drawUser's frames: the head, then under it, 2 cells in, the lead as
// Markdown and the folded-lines hint.
test('cs-feed draws a teammate report\'s lead as Markdown under its head', () => {
  expect(rows('cs-feed.UserMessage/frames-text', 80)).toEqual([
    '       ⇄ fix-auth · waiting · 09:41',
    '         Gate green; run /finish to land.',
    '         +3 more lines · ctrl+o shows all',
  ])
})

// The pane does not scroll: framed in the 16 rows its chrome names, five
// releases of notes lose what falls past row 14 of the body, and the keys
// above them stay.
test('cs-update\'s pane clips a long span of notes, its keys above them', () => {
  const { layoutPane } = require('../mods-layout.js')
  const s = surface('cs-update.Pane.cs-update')
  const g = toText(layoutPane(state('cs-update.Pane.cs-update/several-sections').draw(80, 'light'), { columns: 80, rows: s.chrome.rows, title: s.chrome.title, titles: [s.chrome.title] })).map((r: string) => r.replace(/\s+│$/, ''))
  expect(g.length).toBe(16)
  expect(g[3]).toBe('│  1: update now   Esc: later')
  expect(g[14]).toBe('│  2026.10.23')
})

// The rest of the band's states, each read off buildBandEntries and drawBand
// by hand at 80 cols (bodyColumns 75).
const bandLine = (id: string) => rows(`cs.AbovePrompt/${id}`, 80)
const ink = (id: string, col: number) => layout(state(`cs.AbovePrompt/${id}`).draw(80, 'light'), 80).rows[1][col].st
test('cs draws the keys the hook leaves for each state', () => {
  expect(bandLine('rotate-wrapped')[1]).toBe('  ● ctrl+x  1 rotate')
  expect(bandLine('armed-with-queue')[1]).toBe('  ● ctrl+x  1 /clear now  ·  ▤ queue 3')
  expect(bandLine('chords-mixed')[1]).toBe('  ● ctrl+x 1 rotate  ·  ctrl+y 2 wrap')
  expect(bandLine('chords-partial')[1]).toBe('  ● ctrl+x  1 rotate  ·  wrap')
  expect(bandLine('due-midturn')[1]).toBe('  ● mail 2')
  expect(bandLine('queued-blocked')[1]).toBe('  ● ▤ queue 3')
})

// The count is the session colour above AMBER_AT, amber to CRIT_AT, crit
// under it; the mark reads the hook's own facts: due mid-turn is amber,
// tasks queued with nothing running them green, not the queue's blue.
test('cs inks the count by its ramp and the mark by what is due, not by the words drawn', () => {
  expect(bandLine('countdown-session')[1]).toBe('  ● /clear in 15s  ·  ctrl+x  1 /clear now')
  expect(ink('countdown-session', 4)).toMatchObject({ color: 'rgb(217,119,87)', bold: true })
  expect(ink('countdown-crit', 4)).toMatchObject({ color: 'rgb(215,0,21)', bold: true })
  expect(ink('due-midturn', 2).color).toBe('rgb(180,83,9)')
  expect(ink('armed-with-queue', 2).color).toBe('rgb(180,83,9)')
  expect(ink('queued-blocked', 2).color).toBe('rgb(22,163,74)')
})

test('cs gives a survey the band: no mark, the gate word alone under the survey', () => {
  const lines = bandLine('survey-gate')
  expect(lines.length).toBe(3)
  expect(lines[2]).toBe('  finishing fix-auth · gate 1m 12s')
})

// featuresWordOf: one feature names its task and its state word, `no
// commits` for a ready one with nothing ahead; only a ready word is pressable.
test('cs says a feature\'s state in every word featuresWordOf has, and presses only a ready one', () => {
  const words: [string, string][] = [['ready', 'ready'], ['no-commits', 'no commits'], ['staged', 'staged'], ['locked', 'locked'], ['dirty', 'dirty'], ['untracked', 'untracked'], ['vault-locked', 'vault-locked'], ['base-dirty', 'base-dirty'], ['merged', 'merged']]
  for (const [id, word] of words) {
    const tree = state(`cs.AbovePrompt/features-one-${id}`).draw(80, 'light')
    const entry = tree.children[1].children[0].children[1]
    expect({ id, line: bandLine(`features-one-${id}`)[1], type: entry.type }).toEqual({ id, line: `  ● 1 feature · fix-auth ${word}`, type: id === 'ready' ? 'Button' : 'Text' })
  }
  expect(bandLine('features-many-ready')[1]).toBe('  ● 3 features · 2 ready')
  expect(bandLine('features-none-ready')[1]).toBe('  ● 3 features · none ready')
  expect(state('cs.AbovePrompt/features-midturn').draw(80, 'light').children[1].children[0].children[1].type).toBe('Text')
})

// rotate, wrap, the feed and the queue take 62 cells; the budget is
// 75 - 2 - 2 - (3 + 62) = 6, room for the six bars and no label.
test('cs draws the rail without its label when the words leave under ten cells', () => {
  expect(bandLine('rail-no-label')[1]).toBe('  ● ctrl+x  1 rotate  ·  2 wrap  ·  3 feed ✓  ·  ▤ queue 2 · start   │││││┃')
})

test('cs draws the named bar uncoloured with no session colour, and no hover cards off the terminal', () => {
  const named = layout(state('cs.AbovePrompt/rail-uncoloured').draw(80, 'light'), 80).rows[1][6]
  expect(named).toMatchObject({ ch: '┃', st: { color: '', bold: true } })
  const cards = (id: string) => JSON.stringify(state(`cs.AbovePrompt/${id}`).draw(80, 'light')).split('"position":"absolute"').length - 1
  expect(cards('rail-few')).toBe(2)
  expect(cards('rail-desktop')).toBe(0)
})
