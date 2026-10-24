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
