// ABOUTME: Unit tests for the mod band layout engine in docs/mods-layout.js.
// ABOUTME: Covers Text runs, Box flex in both directions, nesting, borders and the shipped rotate band as an oracle.
import { test, expect } from 'bun:test'
const { layout, toText, toJsx } = require('../mods-layout.js')

const T = (props: any, s: string) => ({ type: 'Text', props, children: [s] })

test('a Text node lays out as one row carrying its style', () => {
  const g = layout(T({ color: 'claude', bold: true }, 'rotate'), 40)
  expect(toText(g)).toEqual(['rotate'])
  expect(g.rows[0][0].st.color).toBe('claude')
  expect(g.rows[0][0].st.bold).toBe(true)
})

const B = (props: any, ...children: any[]) => ({ type: 'Box', props, children })

test('a row Box places its children side by side with gap cells between', () => {
  const g = layout(B({ gap: 2 }, T({}, 'ab'), T({}, 'cd')), 40)
  expect(toText(g)).toEqual(['ab  cd'])
  expect(g.w).toBe(6)
})

test('a column Box stacks its children and pads them to the widest', () => {
  const g = layout(B({ flexDirection: 'column' }, T({}, 'one'), T({}, 'three')), 40)
  expect(toText(g)).toEqual(['one  ', 'three'])
})

test('a row Box top-aligns children of different heights', () => {
  // The width-2 Box is what makes "abcd" wrap; the row itself is roomy.
  const g = layout(B({ gap: 1 }, B({ width: 2 }, T({ wrap: 'wrap' }, 'abcd')), T({}, 'x')), 40)
  expect(toText(g)).toEqual(['ab x', 'cd  '])
})

test('an explicit width holds a Box open, and clips it when overflow is hidden', () => {
  expect(toText(layout(B({ width: 8 }, T({}, 'ab')), 40))).toEqual(['ab      '])
  expect(toText(layout(B({ width: 3, overflow: 'hidden' }, T({ wrap: 'end' }, 'abcdef')), 40))).toEqual(['ab…'])
})

test('padding and a border grow the Box around its content', () => {
  const g = layout(B({ borderStyle: 'round', paddingX: 1 }, T({}, 'hi')), 40)
  expect(toText(g)).toEqual(['╭────╮', '│ hi │', '╰────╯'])
})

test('a Box nests inside a Box', () => {
  const g = layout(B({ flexDirection: 'column' }, B({ gap: 1 }, T({}, 'a'), T({}, 'b')), T({}, 'cc')), 40)
  expect(toText(g)).toEqual(['a b', 'cc '])
})

test('justifyContent spreads the slack inside a fixed width', () => {
  const row = (just: string) => toText(layout(B({ width: 9, justifyContent: just }, T({}, 'ab'), T({}, 'cd')), 40))[0]
  expect(row('flex-start')).toBe('abcd     ')
  expect(row('center')).toBe('  abcd   ')
  expect(row('flex-end')).toBe('     abcd')
  expect(row('space-between')).toBe('ab     cd')
})

test('flexGrow takes the slack before justifyContent sees it', () => {
  const g = layout(B({ width: 10, justifyContent: 'flex-end' }, T({ flexGrow: 1 }, 'ab'), T({}, 'cd')), 40)
  expect(toText(g)).toEqual(['ab      cd'])
})

test('alignItems places a short child against a taller sibling', () => {
  const tall = B({ flexDirection: 'column' }, T({}, 'x'), T({}, 'y'), T({}, 'z'))
  expect(toText(layout(B({ gap: 1, alignItems: 'flex-end' }, tall, T({}, 'o')), 40))).toEqual(['x  ', 'y  ', 'z o'])
  expect(toText(layout(B({ gap: 1, alignItems: 'center' }, tall, T({}, 'o')), 40))).toEqual(['x  ', 'y o', 'z  '])
})

test('display none draws nothing and takes no room', () => {
  expect(toText(layout(B({}, B({ display: 'none' }, T({}, 'gone')), T({}, 'here')), 40))).toEqual(['here'])
})

test('a Text nested in a Text is one inline run per child, each with its own style', () => {
  const g = layout({ type: 'Text', props: {}, children: [T({ dimColor: true }, '  ·  '), T({ color: 'claude', bold: true }, '47%')] }, 40)
  expect(toText(g)).toEqual(['  ·  47%'])
  expect(g.rows[0][0].st.dim).toBe(true)
  expect(g.rows[0][5].st.color).toBe('claude')
})

// The engine drops a whole band that nests a block element in a Text, and it
// does so silently — the editor refuses the nest instead.
test('validate names the nests the engine refuses', () => {
  const { validate } = require('../mods-layout.js')
  expect(validate({ type: 'Text', props: {}, children: [{ type: 'Button', props: { label: 'x' }, children: [] }] }))
    .toEqual(['A Button inside a Text: the engine drops the whole tree.'])
  expect(validate(B({}, T({}, 'ok')))).toEqual([])
  expect(validate(B({ hover: { color: 'claude' } }, T({}, 'x'))))
    .toEqual(['hover on a Box needs a key or a hover.scope.'])
})

// The oracle: the band the shipped mod draws (percent 47, nothing armed),
// read off mods/cs/hooks/register.tsx and hand-worked, not recomputed.
test('the shipped rotate band lays out as the mod draws it', () => {
  const band = B({ borderStyle: 'round', borderColor: 'claude', paddingX: 1, key: 'cs-rotate-band' },
    T({ color: 'coral', bold: true }, '✳ '),
    { type: 'Button', props: { key: 'cs-rotate', hotkey: '1', plain: true, label: 'rotate this conversation' }, children: [] },
    T({ dimColor: true }, '  ·  '),
    { type: 'Button', props: { key: 'cs-wrap', hotkey: '2', plain: true, label: 'wrap up this session' }, children: [] },
    { type: 'Text', props: {}, children: [
      T({ dimColor: true }, '  ·  '),
      T({ color: 'warning' }, '█'.repeat(5)),
      T({ dimColor: true }, '░'.repeat(5)),
      T({ color: 'warning', bold: true }, ' 47%'),
    ] },
  )
  const content = '✳ 1: rotate this conversation  ·  2: wrap up this session  ·  '
    + '█████░░░░░ 47%'
  expect(content.length).toBe(76)
  expect(toText(layout(band, 100))).toEqual([
    '╭' + '─'.repeat(78) + '╮',
    '│ ' + content + ' │',
    '╰' + '─'.repeat(78) + '╯',
  ])
})

// Each cell names the node that drew it, as the index path from the root, so
// a click on the canvas can find the node under it. On the oracle band's
// middle row: col 0 is the border and col 1 the padding (the Box's own), col 7
// is the `r` of `rotate` (the Button, child 1), col 66 the first meter cell
// (the warning Text, child 1 of the Text at child 4).
test('every cell of the oracle band names the node that drew it', () => {
  const band = B({ borderStyle: 'round', borderColor: 'claude', paddingX: 1, key: 'cs-rotate-band' },
    T({ color: 'coral', bold: true }, '\u2733 '),
    { type: 'Button', props: { key: 'cs-rotate', hotkey: '1', plain: true, label: 'rotate this conversation' }, children: [] },
    T({ dimColor: true }, '  \u00b7  '),
    { type: 'Button', props: { key: 'cs-wrap', hotkey: '2', plain: true, label: 'wrap up this session' }, children: [] },
    { type: 'Text', props: {}, children: [
      T({ dimColor: true }, '  \u00b7  '),
      T({ color: 'warning' }, '\u2588'.repeat(5)),
      T({ dimColor: true }, '\u2591'.repeat(5)),
      T({ color: 'warning', bold: true }, ' 47%'),
    ] },
  )
  const g = layout(band, 100)
  expect(g.rows[0][0]).toMatchObject({ ch: '\u256d', path: [] })
  expect(g.rows[1][0]).toMatchObject({ ch: '\u2502', path: [] })
  expect(g.rows[1][1]).toMatchObject({ ch: ' ', path: [] })
  expect(g.rows[1][7]).toMatchObject({ ch: 'r', path: [1] })
  expect(g.rows[1][66]).toMatchObject({ ch: '\u2588', path: [4, 1] })
})

// Width 9, content 3 + gap 2 + 1 = 6, so flex-end leads with 3 cells.
test('a gap, a margin and justify slack belong to the Box that makes them', () => {
  const g = layout(B({ width: 9, gap: 2, justifyContent: 'flex-end' }, B({ marginRight: 1 }, T({}, 'ab')), T({}, 'c')), 40)
  expect(toText(g)).toEqual(['   ab   c'])
  expect(g.rows[0].map((c: any) => c.path)).toEqual([[], [], [], [0, 0], [0, 0], [0], [], [], [1]])
})

test('every cell of every band the gallery draws names a node', () => {
  const { STATES, VARIANTS } = require('../mods-band-variants.js')
  const unnamed: string[] = []
  for (const v of VARIANTS) for (const st of STATES) for (const cols of [40, 80]) {
    const g = layout(v.draw(st.facts, cols, 'light'), cols)
    g.rows.forEach((r: any[], y: number) => r.forEach((c: any, x: number) => { if (!Array.isArray(c.path)) unnamed.push(`${v.id} / ${st.id} / ${cols} at ${y},${x}`) }))
  }
  expect(unnamed).toEqual([])
})

test('toJsx emits the tree the lab prints, palette keys quoted and raw inks braced', () => {
  const { toJsx } = require('../mods-layout.js')
  const tree = B({ borderStyle: 'round', borderColor: 'CORAL', paddingX: 1, key: 'band' },
    T({ color: 'claude', bold: true }, '✳ '),
    { type: 'Button', props: { key: 'go', hotkey: '1', plain: true, label: 'rotate' }, children: [] })
  expect(toJsx(tree)).toBe(
    '<Box key="band" borderStyle="round" borderColor={CORAL} paddingX={1}>\n'
    + '  <Text color="claude" bold>{\'\\u2733 \'}</Text>\n'
    + '  <Button key="go" hotkey="1" plain label="rotate" onPress={press} />\n'
    + '</Box>')
})

test('toJsx keeps plain ASCII text unescaped and nests inline Text on one line', () => {
  const { toJsx } = require('../mods-layout.js')
  expect(toJsx(T({ dimColor: true }, 'ctx 47%'))).toBe('<Text dimColor>ctx 47%</Text>')
  expect(toJsx({ type: 'Text', props: {}, children: [T({ dimColor: true }, 'a'), T({ bold: true }, 'b')] }))
    .toBe('<Text><Text dimColor>a</Text><Text bold>b</Text></Text>')
})

// The export is only worth having if it pastes: parse what toJsx wrote with
// Bun's own JSX transpiler and rebuild the tree, which must be the one the
// canvas held, text and labels byte for byte.
const jsxTranspiler = new Bun.Transpiler({ loader: 'tsx', tsconfig: JSON.stringify({ compilerOptions: { jsx: 'react', jsxFactory: 'h' } }) })
function reparse(jsx: string): any {
  const js = jsxTranspiler.transformSync('export default (' + jsx + ')').replace('export default', 'return')
  const h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
  return new Function('h', 'Box', 'Text', 'Button', 'press', js)(h, 'Box', 'Text', 'Button', () => {})
}

test('toJsx text survives a paste: angle brackets, braces, quotes, entities and astral characters stay literal', () => {
  for (const s of ['a < b', '{value}', "it's \\ fine", 'say "yes"', 'rocket \u{1F680} \u00b7 ok', '<Text>', 'a &lt; b', 'Save &amp; continue']) {
    const back = reparse(toJsx(T({}, s)))
    expect(back.type).toBe('Text')
    expect(back.children.join('')).toBe(s)
  }
})

test('toJsx string props survive a paste, quotes and all', () => {
  const tree = { type: 'Button', props: { hotkey: '1', plain: true, label: 'say "yes" & <go> {now} \u{1F680}' }, children: [] }
  const back = reparse(toJsx(tree))
  expect(back.props.label).toBe(tree.props.label)
  expect(back.props.hotkey).toBe('1')
})

// A Box background sits under everything it holds: the cells its children
// draw without a background of their own take the Box's, and so do the rows an
// explicit height adds. A child's own background still wins.
test('a Box background fills beneath its children and its height padding', () => {
  const g = layout(B({ backgroundColor: 'rgb(1,2,3)', paddingX: 1, height: 2 }, T({}, 'ab'), T({ backgroundColor: 'red' }, 'c')), 40)
  expect(toText(g)).toEqual([' abc ', '     '])
  const bgs = g.rows.map((r: any[]) => r.map(c => c.st.bg))
  expect(bgs[0]).toEqual(['rgb(1,2,3)', 'rgb(1,2,3)', 'rgb(1,2,3)', 'red', 'rgb(1,2,3)'])
  expect(bgs[1]).toEqual(Array(5).fill('rgb(1,2,3)'))
})

test('a row Box with gaps and justify slack paints the whole band', () => {
  const g = layout(B({ backgroundColor: 'rgb(9,9,9)', width: 10, justifyContent: 'space-between' }, T({}, 'a'), T({}, 'b')), 40)
  expect(toText(g)).toEqual(['a        b'])
  expect(g.rows[0].every((c: any) => c.st.bg === 'rgb(9,9,9)')).toBe(true)
})

// Button chrome as the 2.1.310 bundle's terminal Button draws it (function
// `rr`): plain is a Text of `{hotkey in suggestion}: ` then the label, or the
// label alone with no hotkey; any other Button is one bold Text `[ label ]`
// that never shows its hotkey, in suggestion only for variant primary.
// Children replace the label, inside the brackets when not plain.
const Btn = (props: any, ...children: any[]) => ({ type: 'Button', props, children })
test('a Button that is not plain draws [ label ] bold and never its hotkey', () => {
  const g = layout(Btn({ label: 'Feed', hotkey: '1' }), 40)
  expect(toText(g)).toEqual(['[ Feed ]'])
  expect(g.rows[0].every((c: any) => c.st.bold === true)).toBe(true)
  expect(g.rows[0][2].st.color).toBe('')
  expect(layout(Btn({ label: 'go', variant: 'primary' }), 40).rows[0][2].st).toMatchObject({ color: 'suggestion', bold: true })
})

test('a plain Button draws hotkey: label with the hotkey in suggestion, or the label alone', () => {
  const g = layout(Btn({ label: 'update now', hotkey: '1', plain: true }), 40)
  expect(toText(g)).toEqual(['1: update now'])
  expect(g.rows[0][0].st).toMatchObject({ color: 'suggestion', bold: false })
  expect(g.rows[0][1].st).toMatchObject({ color: '', bold: false })
  expect(toText(layout(Btn({ label: 'rotate', plain: true }), 40))).toEqual(['rotate'])
})

test('a Button\'s children replace its label, inside the brackets when it is not plain', () => {
  const kids = ['feed ', T({ color: 'claude' }, '✓')]
  expect(toText(layout(Btn({ label: 'feed ✓' }, ...kids), 40))).toEqual(['[ feed ✓ ]'])
  const g = layout(Btn({ label: 'feed ✓', plain: true }, ...kids), 40)
  expect(toText(g)).toEqual(['feed ✓'])
  expect(g.rows[0][5].st.color).toBe('claude')
})

test('a dim Button draws dim, and a colour or bold set on a Button is not the engine\'s to read', () => {
  expect(layout(Btn({ label: 'x', plain: true, dimColor: true }), 40).rows[0][0].st.dim).toBe(true)
  expect(layout(Btn({ label: 'x', plain: true, color: 'claude', bold: true }), 40).rows[0][0].st).toMatchObject({ color: '', bold: false })
})

// Yoga's default alignItems is stretch: a Box in a column takes the column's
// width, and the root takes the terminal's, so a flexGrow child gets the
// slack (cs-feed's time column) and justifyContent has room (its desktop
// band's flex-end). layoutScreen draws a tree as the terminal does, the root
// filling the row; layout measures it at its natural width.
test('a row Box stretches to the width of its column parent, so flexGrow takes the slack', () => {
  const { layoutScreen } = require('../mods-layout.js')
  const you = B({ flexDirection: 'column' }, B({}, B({ flexGrow: 1 }, T({}, 'you')), T({}, '09:41')))
  expect(toText(layoutScreen(you, 20))).toEqual(['you            09:41'])
  expect(toText(layoutScreen(B({ flexDirection: 'column' }, B({ justifyContent: 'flex-end', gap: 1 }, T({}, 'a'), T({}, 'b'))), 10))).toEqual(['       a b'])
  expect(toText(layout(B({ flexDirection: 'column', width: 8 }, B({}, B({ flexGrow: 1 }, T({}, 'a')), T({}, 'b'))), 40))).toEqual(['a      b'])
})

test('a column aligned flex-start does not stretch its children, and a stretched row still measures what overflows it', () => {
  const { layoutScreen } = require('../mods-layout.js')
  const g = layoutScreen(B({ flexDirection: 'column', alignItems: 'flex-start' }, B({}, B({ flexGrow: 1 }, T({}, 'a')), T({}, 'b'))), 10)
  expect(toText(g)).toEqual(['ab        '])
  expect(layoutScreen(B({ flexDirection: 'column' }, B({}, T({}, 'abcde'), T({}, 'fghij'))), 5).w).toBe(10)
  expect(toText(layout(you2(), 40))).toEqual(['you09:41'])
})
const you2 = () => B({ flexDirection: 'column' }, B({}, B({ flexGrow: 1 }, T({}, 'you')), T({}, '09:41')))
