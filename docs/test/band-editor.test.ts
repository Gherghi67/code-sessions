// ABOUTME: Tests for the band designer's document model in docs/mods-band-editor.js.
// ABOUTME: Pins the reducer action by action, the history, the cell-to-node lookup and the engine round trip.
import { test, expect } from 'bun:test'
const E = require('../mods-band-editor.js')
const { layout } = require('../mods-layout.js')
const { STATES, VARIANTS } = require('../mods-band-variants.js')

const facts = (id: string) => STATES.find((s: any) => s.id === id).facts
const drawn = (variantId: string, stateId: string, cols: number) =>
  layout(VARIANTS.find((v: any) => v.id === variantId).draw(facts(stateId), cols, 'light'), cols)

// Paths read off the shipped band's tree: the column [] holds the blank-row
// Box [0], which holds the band [0,0] at marginLeft 2; its children are the
// mark Box [0,0,0], the prefix Box [0,0,1], the first key's Box [0,0,2] and
// the rotate Button [0,0,3]. On `  ● ctrl+x  1 rotate  ·  2 wrap` (31 cells,
// 2 rows): col 2 is the mark's Text, col 10 the prefix Box's 2-cell margin,
// col 14 the `r` of rotate, col 0 the band's inset.
test('pathOfCell names the node under a cell of the shipped band', () => {
  const g = drawn('shipped', 'rotate-due', 80)
  expect(E.pathOfCell(g, 1, 2)).toEqual([0, 0, 0, 0])
  expect(E.pathOfCell(g, 1, 10)).toEqual([0, 0, 1])
  expect(E.pathOfCell(g, 1, 14)).toEqual([0, 0, 3])
  expect(E.pathOfCell(g, 1, 0)).toEqual([0, 0])
  expect(E.pathOfCell(g, 0, 5)).toEqual([0])
  expect(E.pathOfCell(g, 2, 0)).toBeNull()
  expect(E.pathOfCell(g, 1, 31)).toBeNull()
  expect(E.pathOfCell(g, -1, 0)).toBeNull()
})

// The capsule's round border is the bordered Box's own, [0].
test('pathOfCell gives a border cell to the Box it frames', () => {
  const g = drawn('capsule', 'rotate-due', 80)
  expect(g.rows[0][2].ch).toBe('╭')
  expect(E.pathOfCell(g, 0, 2)).toEqual([0])
  expect(E.pathOfCell(g, 1, 2)).toEqual([0])
})

// The cells a node spans: its own and its descendants'. Rows and cols inclusive.
test('spanOf covers a node and everything inside it', () => {
  const g = drawn('shipped', 'rotate-due', 80)
  expect(E.spanOf(g, [0, 0, 3])).toEqual({ top: 1, left: 14, bottom: 1, right: 19 })
  expect(E.spanOf(g, [0, 0])).toEqual({ top: 1, left: 0, bottom: 1, right: 30 })
  expect(E.spanOf(g, [0, 0, 9])).toBeNull()
})

const box = (props: any, ...kids: any[]) => ({ type: 'Box', props, kids })
const text = (t: string, props: any = {}) => ({ type: 'Text', props: { text: t, ...props }, kids: [] })
const button = (label: string, props: any = {}) => ({ type: 'Button', props: { label, ...props }, kids: [] })
const tree = () => box({}, text('a'), box({ flexDirection: 'column' }, text('b'), button('go')), text('c'))
const doc = (selection: any = null) => ({ frames: [{ id: 'f1', name: 'Band', tree: tree() }], selection, exportFrame: 'f1' })

test('nodeAt walks the index path and parentOf names the parent and the index', () => {
  expect(E.nodeAt(tree(), [1, 1])).toEqual(button('go'))
  expect(E.nodeAt(tree(), [])).toEqual(tree())
  expect(E.parentOf(tree(), [1, 1])).toEqual({ path: [1], index: 1 })
  expect(E.parentOf(tree(), [])).toBeNull()
  expect(() => E.nodeAt(tree(), [1, 5])).toThrow('no node at [1,5]: [1] has 2 children')
  expect(() => E.nodeAt(tree(), [0, 0])).toThrow('no node at [0,0]: [0] has 0 children')
})

test('select and deselect move the selection and nothing else', () => {
  expect(E.apply(doc(), { type: 'select', frame: 'f1', path: [1, 0] })).toEqual(doc({ frame: 'f1', path: [1, 0] }))
  expect(E.apply(doc({ frame: 'f1', path: [1, 0] }), { type: 'deselect' })).toEqual(doc())
  expect(() => E.apply(doc(), { type: 'select', frame: 'f1', path: [7] })).toThrow('no node at [7]: [] has 3 children')
  expect(() => E.apply(doc(), { type: 'select', frame: 'f9', path: [] })).toThrow('no frame f9')
})

test('an action the reducer does not know throws naming it', () => {
  expect(() => E.apply(doc(), { type: 'zap' })).toThrow('unknown action "zap"')
})

const sel = (path: number[]) => ({ frame: 'f1', path })
const edited = (t: any, selection: any, edit: string) => ({ frames: [{ id: 'f1', name: 'Band', tree: t }], selection, exportFrame: 'f1', edit })

test('setProp sets a prop on the node at the path, and an empty value removes it', () => {
  expect(E.apply(doc(sel([1, 1])), { type: 'setProp', path: [1, 1], name: 'plain', value: true }))
    .toEqual(edited(box({}, text('a'), box({ flexDirection: 'column' }, text('b'), button('go', { plain: true })), text('c')), sel([1, 1]), 'set plain on Button'))
  expect(E.apply(doc(sel([1])), { type: 'setProp', path: [1], name: 'flexDirection', value: '' }))
    .toEqual(edited(box({}, text('a'), box({}, text('b'), button('go')), text('c')), sel([1]), 'set flexDirection on Box'))
  expect(E.apply(doc(sel([0])), { type: 'setProp', path: [0], name: 'bold', value: false })).toEqual(edited(tree(), sel([0]), 'set bold on Text'))
  expect(() => E.apply(doc(), { type: 'setProp', path: [0], name: 'bold', value: true })).toThrow('setProp needs a selected frame')
})

test('setProp leaves the document it was given untouched', () => {
  const before = doc(sel([0]))
  E.apply(before, { type: 'setProp', path: [0], name: 'color', value: 'claude' })
  expect(before).toEqual(doc(sel([0])))
})

// A text field is typed into a draft and committed once on blur or Enter:
// three keystrokes are one step back.
test('commit takes one undo step for a field however many keystrokes drafted it', () => {
  const h = E.history(doc(sel([0])))
  let draft = h.present
  for (const t of ['x', 'xy', 'xyz']) draft = E.apply(draft, { type: 'setProp', path: [0], name: 'text', value: t })
  const next = E.commit(h, draft)
  expect(next.past).toEqual([doc(sel([0]))])
  expect(next.present).toEqual(edited(box({}, text('xyz'), box({ flexDirection: 'column' }, text('b'), button('go')), text('c')), sel([0]), 'set text on Text'))
  expect(next.future).toEqual([])
})

// Selecting is not an edit: it moves the present without a step to undo.
test('replace swaps the present and keeps both stacks', () => {
  const h = E.commit(E.history(doc()), doc(sel([0])))
  expect(E.replace(h, doc(sel([2])))).toEqual({ past: [doc()], present: doc(sel([2])), future: [] })
})

// The 201st commit drops the oldest step: 200 are kept, the first is gone.
test('history keeps the last 200 steps', () => {
  let h = E.history(doc())
  for (let i = 1; i <= 201; i++) h = E.commit(h, { ...doc(), edit: `step ${i}` })
  expect(h.past.length).toBe(200)
  expect(h.past[0].edit).toBe('step 1')
  expect(h.past[199].edit).toBe('step 200')
  expect(h.present.edit).toBe('step 201')
})

// `to.index` counts the gaps between the parent's children as they stand
// before the move: 0 is before the first, kids.length after the last.
const col = (...kids: any[]) => box({ flexDirection: 'column' }, ...kids)
test('move puts a node at a gap among its siblings or into another parent, and the selection follows it', () => {
  expect(E.apply(doc(sel([0])), { type: 'move', from: [0], to: { parentPath: [], index: 3 } }))
    .toEqual(edited(box({}, col(text('b'), button('go')), text('c'), text('a')), sel([2]), 'move Text'))
  expect(E.apply(doc(sel([2])), { type: 'move', from: [2], to: { parentPath: [1], index: 1 } }))
    .toEqual(edited(box({}, text('a'), col(text('b'), text('c'), button('go'))), sel([1, 1]), 'move Text'))
  expect(E.apply(doc(sel([1, 1])), { type: 'move', from: [1, 1], to: { parentPath: [], index: 0 } }))
    .toEqual(edited(box({}, button('go'), text('a'), col(text('b')), text('c')), sel([0]), 'move Button'))
  expect(E.apply(doc(sel([0])), { type: 'move', from: [0], to: { parentPath: [1], index: 2 } }))
    .toEqual(edited(box({}, col(text('b'), button('go'), text('a')), text('c')), sel([0, 2]), 'move Text'))
})

test('a Text may go inside a Button, which then draws it in its label\'s place', () => {
  expect(E.apply(doc(sel([0])), { type: 'move', from: [0], to: { parentPath: [1, 1], index: 0 } }))
    .toEqual(edited(box({}, col(text('b'), { ...button('go'), kids: [text('a')] }), text('c')), sel([0, 1, 0]), 'move Text'))
})

test('a move the engine would refuse, or that would lose the node, throws the reason', () => {
  expect(() => E.apply(doc(sel([1])), { type: 'move', from: [1], to: { parentPath: [1], index: 0 } })).toThrow('cannot move [1] into itself')
  expect(() => E.apply(doc(sel([1])), { type: 'move', from: [1], to: { parentPath: [0], index: 0 } })).toThrow('a Box cannot go inside a Text')
  expect(() => E.apply(doc(sel([1, 1])), { type: 'move', from: [1, 1], to: { parentPath: [2], index: 0 } })).toThrow('a Button cannot go inside a Text')
  const twin = { frames: [{ id: 'f1', name: 'Band', tree: box({}, box({}), button('go')) }], selection: sel([0]), exportFrame: 'f1' }
  expect(() => E.apply(twin, { type: 'move', from: [0], to: { parentPath: [1], index: 0 } })).toThrow('a Box cannot go inside a Button')
  expect(() => E.apply(doc(sel([])), { type: 'move', from: [], to: { parentPath: [], index: 0 } })).toThrow('the root cannot move')
  expect(E.canDrop(tree(), [1, 1], [0])).toBe('a Button cannot go inside a Text')
  expect(E.canDrop(tree(), [2], [1])).toBeNull()
})

test('remove takes the node out and selects its parent; the root stays', () => {
  expect(E.apply(doc(sel([1, 0])), { type: 'remove', path: [1, 0] }))
    .toEqual(edited(box({}, text('a'), col(button('go')), text('c')), sel([1]), 'remove Text'))
  expect(() => E.apply(doc(sel([])), { type: 'remove', path: [] })).toThrow('the root cannot be removed')
})

test('duplicateNode puts a copy right after the node and selects the copy', () => {
  expect(E.apply(doc(sel([1])), { type: 'duplicateNode', path: [1] }))
    .toEqual(edited(box({}, text('a'), col(text('b'), button('go')), col(text('b'), button('go')), text('c')), sel([2]), 'duplicate Box'))
  expect(() => E.apply(doc(sel([])), { type: 'duplicateNode', path: [] })).toThrow('the root cannot be duplicated')
})

test('setText rewrites a Text\'s words, and only a Text\'s', () => {
  expect(E.apply(doc(sel([1, 0])), { type: 'setText', path: [1, 0], text: 'beta' }))
    .toEqual(edited(box({}, text('a'), col(text('beta'), button('go')), text('c')), sel([1, 0]), 'edit the words of a Text'))
  expect(() => E.apply(doc(sel([1, 1])), { type: 'setText', path: [1, 1], text: 'x' })).toThrow('setText needs a Text; [1,1] is a Button')
})

// Tab walks the words on the strip in the order the tree holds them.
test('wordPaths lists every Text and Button in document order', () => {
  expect(E.wordPaths(tree())).toEqual([[0], [1, 0], [1, 1], [2]])
  expect(E.wordPaths(box({}, { ...button('feed'), kids: [text('feed '), text('✓')] }))).toEqual([[0], [0, 0], [0, 1]])
})

// An engine tree with its empty props dropped, as toEngine drops them.
const bare = (e: any): any => {
  if (typeof e !== 'object' || e === null) return e
  const props: any = {}
  for (const [k, v] of Object.entries(e.props || {})) if (v !== '' && v !== false && v !== undefined) props[k] = v
  return { type: e.type, props, children: (e.children || []).filter((k: any) => k !== null && k !== undefined && k !== false).map(bare) }
}
const engineTrees = () => VARIANTS.flatMap((v: any) => STATES.flatMap((s: any) => ['light', 'dark'].map(theme => ({ cell: `${v.id} / ${s.id} / ${theme}`, tree: v.draw(s.facts, 80, theme) })))).filter((c: any) => c.tree !== null)

test('every tree the gallery draws comes back unchanged from the editor', () => {
  for (const { cell, tree: e } of engineTrees()) expect({ cell, back: E.toEngine(E.fromEngine(e)) }).toEqual({ cell, back: bare(e) })
})

test('every editor tree read from the gallery survives a trip through the engine', () => {
  for (const { cell, tree: e } of engineTrees()) {
    const t = E.fromEngine(e)
    expect({ cell, back: E.fromEngine(E.toEngine(t)) }).toEqual({ cell, back: t })
  }
})

test('fromEngine spells a Text\'s words as text, the hover colours as fields, and keeps any other hover whole', () => {
  expect(E.fromEngine({ type: 'Box', props: { key: 'k', hover: { borderColor: 'claude' }, gap: 0 }, children: [
    { type: 'Text', props: { dimColor: true, bold: false }, children: ['hi'] },
    { type: 'Button', props: { key: 'r', plain: true, label: '│', hover: { scope: 'r', dimColor: false } }, children: [] },
    null,
  ] })).toEqual(box({ key: 'k', hoverBorderColor: 'claude', gap: 0 },
    text('hi', { dimColor: true }),
    button('│', { key: 'r', plain: true, hover: { scope: 'r', dimColor: false } })))
  expect(() => E.fromEngine({ type: 'Text', props: {}, children: [{ type: 'Text', props: {}, children: ['x'] }] }))
    .toThrow('the editor holds a Text\'s words as one string; this Text has a Text inside it')
})

const frames = (...fs: any[]) => ({ frames: fs, selection: null, exportFrame: fs[0].id })
const frame = (id: string, name: string, t: any) => ({ id, name, tree: t })
const blank = () => box({})

test('addFrame copies a frame, takes a tree, or starts empty, and selects the new frame\'s root', () => {
  const one = frames(frame('f1', 'Band', tree()))
  expect(E.apply(one, { type: 'addFrame', from: 'f1' }))
    .toEqual({ frames: [frame('f1', 'Band', tree()), frame('f2', 'Band copy', tree())], selection: { frame: 'f2', path: [] }, exportFrame: 'f1', edit: 'add frame Band copy' })
  expect(E.apply(one, { type: 'addFrame', tree: box({ gap: 1 }), name: 'Quiet line' }))
    .toEqual({ frames: [frame('f1', 'Band', tree()), frame('f2', 'Quiet line', box({ gap: 1 }))], selection: { frame: 'f2', path: [] }, exportFrame: 'f1', edit: 'add frame Quiet line' })
  expect(E.apply(frames(frame('f1', 'A', blank()), frame('f7', 'B', blank())), { type: 'addFrame' }).frames.map((f: any) => [f.id, f.name, f.tree]))
    .toEqual([['f1', 'A', blank()], ['f7', 'B', blank()], ['f8', 'Frame 3', blank()]])
  expect(() => E.apply(one, { type: 'addFrame', from: 'f1', tree: blank() })).toThrow('addFrame takes a frame to copy or a tree, not both')
})

test('renameFrame, selectFrame and exportFrame name, pick and mark one frame', () => {
  const two = frames(frame('f1', 'A', blank()), frame('f2', 'B', blank()))
  expect(E.apply(two, { type: 'renameFrame', frame: 'f2', name: 'Keys' })).toEqual({ ...frames(frame('f1', 'A', blank()), frame('f2', 'Keys', blank())), edit: 'rename frame B to Keys' })
  expect(() => E.apply(two, { type: 'renameFrame', frame: 'f2', name: ' ' })).toThrow('a frame needs a name')
  expect(E.apply(two, { type: 'selectFrame', frame: 'f2' })).toEqual({ ...two, selection: { frame: 'f2', path: [] } })
  expect(E.apply(two, { type: 'exportFrame', frame: 'f2' })).toEqual({ ...two, exportFrame: 'f2', edit: 'export frame B' })
})

test('removeFrame drops a frame, its selection and its export mark; the last frame stays', () => {
  const two = { ...frames(frame('f1', 'A', blank()), frame('f2', 'B', blank())), selection: { frame: 'f2', path: [] }, exportFrame: 'f2' }
  expect(E.apply(two, { type: 'removeFrame', frame: 'f2' })).toEqual({ frames: [frame('f1', 'A', blank())], selection: null, exportFrame: 'f1', edit: 'remove frame B' })
  expect(() => E.apply(frames(frame('f1', 'A', blank())), { type: 'removeFrame', frame: 'f1' })).toThrow('the last frame cannot be removed')
})
