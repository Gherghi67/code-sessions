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

// An absolute child takes no room in its parent's flow and paints at its
// offsets over the parent's box, in the order the children are written
// (2.1.310 paints childNodes in order; Rx places it). Worked by hand.
const Abs = (props: any, ...children: any[]) => B({ position: 'absolute', ...props }, ...children)
test('an absolute child takes no room in the flow and paints at its top and left, in child order', () => {
  expect(toText(layout(B({}, T({}, 'a'), Abs({ top: 0, left: 0 }, T({}, 'zz')), T({}, 'b')), 40))).toEqual(['zb'])
  expect(toText(layout(B({ width: 4, height: 2, position: 'relative' }, Abs({ top: 1, left: 1 }, T({}, 'zz'))), 40))).toEqual(['    ', ' zz '])
  expect(toText(layout(B({ width: 5 }, T({}, 'abcde'), Abs({ top: 0, left: 1 }, T({}, 'XY'))), 40))).toEqual(['aXYde'])
  expect(toText(layout(B({ width: 5 }, Abs({ top: 0, left: 1 }, T({}, 'XY')), T({}, 'abcde')), 40))).toEqual(['abcde'])
})

// Rx: "if(tt(_))fe=g[0]+_+q;else if(tt(I))fe=f-g[2]-I-Se-Z" and the same down
// the column: left and top count from inside the border, the padding not
// counted; right and bottom from the far border, less the child's size.
test('an absolute child sits inside the border, by left and top or by right and bottom', () => {
  expect(toText(layout(B({ width: 6, height: 3, borderStyle: 'single', paddingLeft: 2 }, Abs({ top: 0, left: 0 }, T({}, 'X'))), 40))).toEqual(['\u250c\u2500\u2500\u2500\u2500\u2510', '\u2502X   \u2502', '\u2514\u2500\u2500\u2500\u2500\u2518'])
  expect(toText(layout(B({ width: 6, height: 3 }, Abs({ bottom: 0, right: 1 }, T({}, 'zz'))), 40))).toEqual(['      ', '      ', '   zz '])
})

// Rx sizes the child apart from the flow: its own width, or what its left
// and right leave ("if(!tt(X)&&tt(_)&&tt(I))X=z-_-I"), else its content's,
// unbounded (measure mode undefined), so a Text in it never wraps to the parent.
test('an absolute child takes its own width, or what its left and right leave, or its content\'s', () => {
  expect(toText(layout(B({ width: 3, height: 1 }, Abs({ top: 0, left: 1 }, T({}, 'abcdef'))), 40))).toEqual([' abcdef'])
  expect(toText(layout(B({ width: 6, height: 2 }, Abs({ top: 0, left: 1, right: 1 }, T({}, 'abc def'))), 40))).toEqual([' abc  ', ' def  '])
})

// An absolute Box with no background skips its own blit ("skipSelfBlit:G&&
// pe&&!ue.style.opaque&&ue.style.backgroundColor===void 0"): its padding is
// transparent, and only what it draws lands.
test('an absolute child\'s own room is transparent over what is under it', () => {
  expect(toText(layout(B({ width: 5 }, T({}, 'abcde'), Abs({ top: 0, left: 0, paddingLeft: 2 }, T({}, 'X'))), 40))).toEqual(['abXde'])
})

// The lab draws no syntax colour: a Code node is its source, line by line, dim.
test('a Code node draws its source as plain dim lines', () => {
  const g = layout({ type: 'Code', props: { source: 'graph TD\n  A --> B', language: 'mermaid' }, children: [] }, 40)
  expect(toText(g).map((r: string) => r.replace(/\s+$/, ''))).toEqual(['graph TD', '  A --> B'])
  expect(g.rows[1][2].st).toMatchObject({ dim: true, color: '' })
})

// Yoga sizes a Box by its width whatever it holds: an empty one has no rows
// but still takes its cells in a row beside a sibling (cs-feed's name margin).
test('an empty Box of an explicit width takes its cells in a row', () => {
  const g = layout(B({}, B({ width: 3 }), T({}, 'ab')), 40)
  expect(toText(g)).toEqual(['   ab'])
  expect(layout(B({ width: 3 }), 40)).toMatchObject({ w: 3, h: 0 })
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
  require('./surfaces.ts')
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

test('a column aligned flex-start does not stretch its children', () => {
  const { layoutScreen } = require('../mods-layout.js')
  const g = layoutScreen(B({ flexDirection: 'column', alignItems: 'flex-start' }, B({}, B({ flexGrow: 1 }, T({}, 'a')), T({}, 'b'))), 10)
  expect(toText(g)).toEqual(['ab        '])
  expect(toText(layout(you2(), 40))).toEqual(['you09:41'])
})

// Box and Text default to flexShrink 1 in 2.1.310 ("var Ab={flexWrap:"nowrap",
// flexDirection:"row",flexGrow:0,flexShrink:1,...}"), and Yoga gives a child
// no minimum of its content's: a row whose children overrun it takes the
// overrun off each in proportion to flexShrink times its basis ("ne+=K*
// (J.flexShrink*ae)/G"), sizes rounded on their running sum ("_+=D[P];let
// B=_+0.5|0"), then each Text wraps or truncates in what it is left.
// Worked by hand.
test('a row shrinks the children that overrun it, each in proportion to its basis', () => {
  const { layoutScreen } = require('../mods-layout.js')
  // abcde and fghij, 10 cells in 5: 2.5 each, rounded on the running sum to 3
  // and 2; each wraps hard in its cells.
  const g = layoutScreen(B({ flexDirection: 'column' }, B({}, T({}, 'abcde'), T({}, 'fghij'))), 5)
  expect([g.w, toText(g)]).toEqual([5, ['abcfg', 'de hi', '   j ']])
  // A truncate-end Text: 8 + 3 cells in 10 leaves 8 - 8/11 and 3 - 3/11,
  // rounded to 7 and 3; abcdefgh truncates to abcdef and the mark.
  expect(toText(layout(B({ width: 10 }, T({ wrap: 'truncate-end' }, 'abcdefgh'), T({}, 'xyz')), 40))).toEqual(['abcdef\u2026xyz'])
  // A wrapping one: 11 + 2 cells in 10 leaves 8.46 and 1.54, rounded to 8 and
  // 2; aaa bbb ccc wraps at its words in 8, dd fits its 2.
  expect(toText(layout(B({ width: 10 }, T({}, 'aaa bbb ccc'), T({}, 'dd')), 40))).toEqual(['aaa bbb dd', 'ccc       '])
})

// A Button never shrinks: the engine draws it in a Box of flexShrink 0
// ("wc(s,{ref:h,flexShrink:0,alignSelf:"flex-start",..."), and so does a
// child that sets flexShrink 0. The Text beside them takes all the overrun.
test('a Button and a child of flexShrink 0 keep their cells while the Text beside them shrinks', () => {
  expect(toText(layout(B({ width: 8 }, { type: 'Button', props: { label: 'rotate', plain: true }, children: [] }, T({}, 'abcdef')), 40))).toEqual(['rotateab', '      cd', '      ef'])
  expect(toText(layout(B({ width: 8 }, B({ flexShrink: 0 }, T({}, 'rotate')), T({}, 'abcdef')), 40))).toEqual(['rotateab', '      cd', '      ef'])
})

// A Box's own width is only its basis: a row that cannot hold it shrinks it
// like any child (Yoga reads width as the flex basis, "let A=at(E.width,p);
// if(A===A)return A>0?A:0"), and what the Box holds wraps in what is left.
test('a Box of an explicit width shrinks in a row that cannot hold it', () => {
  expect(toText(layout(B({ width: 6 }, B({ width: 8 }, T({}, 'abcdefgh'))), 40))).toEqual(['abcdef', 'gh    '])
})

// A Box of an explicit width is that wide whatever it holds: two Buttons of
// 2 cells each keep their 4 in its 3 and the second draws past its edge, into
// the margin of the Box after it, which draws nothing there; the renderer
// paints children in order, so the margin's room never erases it.
test('what a Box cannot shrink draws past its width, under the sibling after it', () => {
  const Bt = (label: string) => ({ type: 'Button', props: { label, plain: true }, children: [] })
  const g = layout(B({}, B({ width: 3 }, Bt('ab'), Bt('cd')), B({ marginLeft: 2 }, T({}, 'x'))), 40)
  expect([g.w, toText(g)]).toEqual([6, ['abcd x']])
  // The root takes the terminal's cells exactly, and draws past them too.
  const { layoutScreen } = require('../mods-layout.js')
  const root = layoutScreen(B({}, Bt('ab'), Bt('cd')), 3)
  expect([root.w, toText(root)]).toEqual([3, ['abcd']])
})

// The Button is a Box of flexShrink 0 around one Text of the default wrap
// ("z?wc(n,{inverse:C,dimColor:W,...H},B?"":wc(n,{color:"suggestion"},f),B?"":": ",...N)"),
// so a label wider than the room wraps at its words like any Text.
test('a Button whose label is wider than its room wraps it', () => {
  expect(toText(layout({ type: 'Button', props: { label: 'abcdef', plain: true }, children: [] }, 3))).toEqual(['abc', 'def'])
  const g = layout({ type: 'Button', props: { label: 'abcdef', hotkey: '1', plain: true }, children: [] }, 4)
  expect(toText(g)).toEqual(['1: ', 'abcd', 'ef'])
  expect(g.rows[0][0].st.color).toBe('suggestion')
})

// A child shrunk to no cells still draws: a wrapping Text given 0 cells
// draws whole, so the mark paints into its Box's margin cell, under the
// Button laid out after it.
test('a child shrunk to no cells draws past them, under what is drawn after it', () => {
  expect(toText(layout(B({ width: 5 }, B({ marginRight: 1 }, T({}, '\u25cf')), { type: 'Button', props: { label: 'abcd', plain: true }, children: [] }), 40))).toEqual(['\u25cfabcd'])
})
const you2 = () => B({ flexDirection: 'column' }, B({}, B({ flexGrow: 1 }, T({}, 'you')), T({}, '09:41')))

// Ink breaks a Text at each newline before it wraps what is left of a line
// to the room (cs-update's failed exit prints cs -update's stderr under it).
test('a Text breaks into rows at each newline, then wraps each row to the room', () => {
  expect(toText(layout(T({}, 'cs -update exited 3.\ndownload failed'), 40))).toEqual(['cs -update exited 3.', 'download failed'])
  expect(toText(layout(T({}, 'abcdef\ngh'), 4))).toEqual(['abcd', 'ef', 'gh'])
  expect(toText(layout(T({}, 'a\n\nb'), 4))).toEqual(['a', '', 'b'])
})

// 2.1.310 wraps a Text in its render (gv) and its measure (s1) through Ip:
// `wrap` is ku(n,u,{trim:!1,hard:!0}), the bundle's wrapper over
// Bun.wrapAnsi, `wrap-trim` the same with trim. A word moves to the next row
// whole and only a word wider than the row breaks; a row that starts with the
// space the wrap carried over draws without it ("I=_.startsWith(" ")?
// _.slice(1):_,P=vf(I)>0?I:_"), unless the space is all the row holds.
// Worked by hand from wrap-ansi's rules, the ones Bun.wrapAnsi implements.
test('a Text wraps at its words, as the engine wraps it', () => {
  const rows = (s: string, w: number, wrap?: string) => toText(layout(T(wrap ? { wrap } : {}, s), w))
  expect(rows('one two three', 7)).toEqual(['one two', 'three'])
  expect(rows('abcdefghij klm', 4)).toEqual(['abcd', 'efgh', 'ij ', 'klm'])
  expect(rows('  \u00b7  ', 1)).toEqual([' ', ' ', '\u00b7', ' ', ' '])
  expect(rows('mail 1', 1)).toEqual(['m', 'a', 'i', 'l', ' ', '1'])
  expect(rows('ab  cd', 3, 'wrap-trim')).toEqual(['ab', 'cd'])
})

// What a Text given no cells draws: ku returns the text unchanged for a
// width that is not above 0 ("if(!(t>0))return e"), so a wrapping Text draws
// whole; o1 returns "" below 1, so a truncating one draws nothing.
test('a wrapping Text given no cells draws whole, a truncating one draws nothing', () => {
  expect(toText(layout(T({}, 'ab'), 0))).toEqual(['ab'])
  expect(toText(layout(T({ wrap: 'truncate-end' }, 'ab'), 0))).toEqual([''])
})

// A truncating Text is cut whole (gv hands Ip the text, newlines and all,
// when the mode does not wrap): its widest line decides, and what follows
// the cut, the rest of the lines included, is gone.
test('a truncating Text is cut once across its lines', () => {
  expect(toText(layout(T({ wrap: 'truncate-end' }, 'abcdef\ngh'), 4))).toEqual(['abc\u2026'])
  expect(toText(layout(T({ wrap: 'truncate-end' }, 'ab\ncdefgh'), 4))).toEqual(['ab', 'c\u2026'])
  expect(toText(layout(T({ wrap: 'truncate-end' }, 'ab\ncd'), 4))).toEqual(['ab', 'cd'])
})

// The engine's own wrap is the oracle: over a battery of texts and widths,
// the lab's rows are Bun.wrapAnsi's (bun 1.4.4, the Bun 2.1.310 embeds) with
// a carried space dropped from a continuation row, and the Text measures the
// widest row Bun.wrapAnsi gives.
test('a Text wraps as Bun.wrapAnsi does, over a battery of texts and widths', () => {
  const texts = ['one two three', 'a  b', ' lead', 'trail  ', 'abcdefghij klm', 'x yy zzz wwww vvvvv', '  \u00b7  ', 'ctrl+x  1 rotate  \u00b7  2 wrap', 'a b c d e f g', 'word\nnext line here']
  const misses: string[] = []
  for (const s of texts) for (let w = 1; w <= 12; w++) {
    const raw = Bun.wrapAnsi(s, w, { trim: false, hard: true }).split('\n')
    const widest = Math.max(...s.split('\n').map(l => l.length))
    const drawn = widest <= w ? s.split('\n') : s.split('\n').flatMap(l => Bun.wrapAnsi(l, w, { trim: false, hard: true }).split('\n').map((r, i) => i && r.startsWith(' ') && r.length > 1 ? r.slice(1) : r))
    const g = layout(T({}, s), w)
    const got = { rows: toText(g), w: g.w }
    const want = { rows: drawn, w: widest <= w ? widest : Math.max(...raw.map(r => r.length)) }
    if (JSON.stringify(got) !== JSON.stringify(want)) misses.push(`${JSON.stringify(s)} at ${w}: ${JSON.stringify(got)} != ${JSON.stringify(want)}`)
  }
  expect(misses).toEqual([])
})

// The 2.1.310 bundle's Markdown renderer: strong is bold, em italic, and a
// codespan is its text in the theme's permission ink, no backticks; the lab
// draws a Markdown node as that one styled run, broken and wrapped as a Text.
test('a Markdown node draws its text with bold, italic and code styled, the marks gone', () => {
  const md = (text: string) => ({ type: 'Markdown', props: { text }, children: [] })
  const g = layout(md('Gate **green**; run `/finish` to *land*.'), 40)
  expect(toText(g)).toEqual(['Gate green; run /finish to land.'])
  expect(g.rows[0][5].st).toMatchObject({ bold: true, color: '' })
  expect(g.rows[0][4].st.bold).toBe(false)
  expect(g.rows[0][16].st).toMatchObject({ color: 'permission', bold: false })
  expect(g.rows[0][27].st.italic).toBe(true)
  expect(toText(layout(md('one two three\nfour'), 7))).toEqual(['one two', 'three', 'four'])
})

// A pane as the 2.1.310 bundle frames an inline one (Tle): a round border,
// dim while the pane is not focused, one cell of padding each side, so the
// body has the columns less 4; a tab per open pane on the first row only when
// two or more are open; the body at most rows - 2 (and - 1 under tabs) tall,
// clipped, since the frame hides its overflow; the close mark ✕ on the top
// border, dim, two cells in from the right (CloseMark, right: 2).
test('a pane draws its body in a round dim frame with the close mark on the top edge', () => {
  const { layoutPane } = require('../mods-layout.js')
  const g = layoutPane(T({}, 'hi'), { columns: 10, rows: 5, title: 'Notes', titles: ['Notes'] })
  expect(toText(g)).toEqual(['╭──────✕─╮', '│ hi     │', '╰────────╯'])
  expect(g.rows[0][0].st.dim).toBe(true)
  expect(g.rows[0][7].st.dim).toBe(true)
})

test('a pane clips its body to its rows, and shows its tabs only beside another pane', () => {
  const { layoutPane } = require('../mods-layout.js')
  const body = B({ flexDirection: 'column' }, T({}, 'one'), T({}, 'two'), T({}, 'three'), T({}, 'four'))
  expect(toText(layoutPane(body, { columns: 12, rows: 5, title: 'A', titles: ['A'] })).slice(1, -1)).toEqual(['│ one      │', '│ two      │', '│ three    │'])
  const tabbed = layoutPane(body, { columns: 12, rows: 5, title: 'B', titles: ['A', 'B'] })
  expect(toText(tabbed).slice(1, -1)).toEqual(['│ A B      │', '│ one      │', '│ two      │'])
  expect(tabbed.rows[1][4].st.bold).toBe(true)
  expect(tabbed.rows[1][2].st.dim).toBe(true)
})

test('toJsx prints a Markdown or a Code node as the element the mod writes', () => {
  expect(toJsx({ type: 'Markdown', props: { text: 'Gate **green**' }, children: [] })).toBe('<Markdown text="Gate **green**" />')
  expect(toJsx(B({}, { type: 'Code', props: { source: 'graph TD', language: 'mermaid' }, children: [] }))).toBe('<Box>\n  <Code source="graph TD" language="mermaid" />\n</Box>')
})
