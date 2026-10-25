// ABOUTME: Tests for docs/surfaces/shim.js, the engine globals a bundled mod's draw code runs against in the lab.
// ABOUTME: Pins the tree shape h and the element table build: children flattened, empty children dropped, presses off the props.
import { test, expect } from 'bun:test'
require('../surfaces/shim.js')
const g = globalThis as any
const { Box, Text, Button } = g.LabElements

test('h builds an element tree with the children flattened and the empty ones dropped', () => {
  const tree = g.h(Box, { gap: 1 }, 'a', [g.h(Text, null, 'b'), [null, 'c']], null, false, true, undefined, 0)
  expect(tree).toEqual({
    type: 'Box', props: { gap: 1 },
    children: ['a', { type: 'Text', props: {}, children: ['b'] }, 'c', 0],
  })
})

test('an element called directly takes its children from props, one or many', () => {
  expect(Text({ children: 'one' })).toEqual({ type: 'Text', props: {}, children: ['one'] })
  expect(Box({})).toEqual({ type: 'Box', props: {}, children: [] })
  expect(Box({ key: 'k', children: [Text({ children: ['x', false] })] })).toEqual({ type: 'Box', props: { key: 'k' }, children: [{ type: 'Text', props: {}, children: ['x'] }] })
})

test('a press stays off the printed props and can still be called', () => {
  let pressed = 0
  const button = g.h(Button, { key: 'go', plain: true, label: 'go', onPress: () => { pressed++ } })
  expect(button).toEqual({ type: 'Button', props: { key: 'go', plain: true, label: 'go' }, children: [] })
  expect(JSON.stringify(button)).toBe('{"type":"Button","props":{"key":"go","plain":true,"label":"go"},"children":[]}')
  button.onPress()
  expect(pressed).toBe(1)
})

test('a function component is called with its props and children, as the engine calls it', () => {
  const Pair = (p: any) => g.h(Box, { flexDirection: 'column' }, p.children, g.h(Text, null, p.tail))
  expect(g.h(Pair, { tail: 'z' }, g.h(Text, null, 'y'))).toEqual({
    type: 'Box', props: { flexDirection: 'column' },
    children: [{ type: 'Text', props: {}, children: ['y'] }, { type: 'Text', props: {}, children: ['z'] }],
  })
})

test('a Fragment or a tag the engine has no element for is refused by name', () => {
  expect(() => g.h(g.Fragment, null, 'a')).toThrow('the lab draws no Fragment: no cs mod draws one')
  expect(() => g.h('Box', null)).toThrow('h was handed "Box", not an element of the table or a component function')
})
