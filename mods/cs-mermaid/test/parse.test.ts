// ABOUTME: Tests for the mermaid flowchart parser: statements, shapes, arrows, labels, styles.
// ABOUTME: Pins that unsupported syntax refuses the whole chart and that the node, edge and label limits hold.
import { test, expect } from 'claude-code/testing'

import { parse, splitStatements } from '../hooks/parse'

test('a two-node flowchart', () => {
  expect(parse('graph TD\n  A --> B')).toEqual({
    dir: 'TD',
    nodes: [{ id: 'A', label: 'A', shape: 'rect' }, { id: 'B', label: 'B', shape: 'rect' }],
    edges: [{ id: 0, from: 'A', to: 'B', label: undefined, style: 'solid', headAtTo: true, headAtFrom: false }],
  })
})

test('statements split on newlines and on semicolons outside quotes and brackets', () => {
  expect(splitStatements('graph TD\nA --> B; B --> C\nC["x; y"] --> D;')).toEqual(['graph TD', 'A --> B', 'B --> C', 'C["x; y"] --> D'])
  const graph = parse('graph TD\nA --> B; B --> C')
  if ('error' in graph) throw new Error(graph.error)
  expect(graph.nodes.map(n => n.id)).toEqual(['A', 'B', 'C'])
  expect(graph.edges.map(e => `${e.from}>${e.to}`)).toEqual(['A>B', 'B>C'])
})

test('quoted labels keep arrows, ampersands and semicolons', () => {
  const graph = parse('graph TD\n  A["R&D"] --> B\n  C["x --> y"] --> B')
  if ('error' in graph) throw new Error(graph.error)
  expect(graph.nodes.map(n => n.label)).toEqual(['R&D', 'B', 'x --> y'])
  expect(graph.edges.map(e => `${e.from}>${e.to}`)).toEqual(['A>B', 'C>B'])
})

test('comments and an init preamble before the header are dropped', () => {
  const graph = parse('%% a comment\n%%{init: {"theme":"dark"}}%%\ngraph TD\n  A --> B %% trailing\n')
  if ('error' in graph) throw new Error(graph.error)
  expect(graph.nodes.map(n => n.id)).toEqual(['A', 'B'])
})

test('every direction is kept as written', () => {
  for (const [written, dir] of [['TD', 'TD'], ['TB', 'TD'], ['BT', 'BT'], ['LR', 'LR'], ['RL', 'RL']] as const) {
    const graph = parse(`graph ${written}\n  A --> B`)
    if ('error' in graph) throw new Error(graph.error)
    expect(graph.dir).toBe(dir)
  }
})

test('arrowheads at either end, shafts, and labels in both spellings', () => {
  const graph = parse(['graph LR', '  A <--> B', '  C <-- D', '  E --- F', '  G -.-> H', '  I ==> J', '  K -- go --> L', '  M -->|stop| N', '  O == fast ==> P', '  Q -. slow .-> R'].join('\n'))
  if ('error' in graph) throw new Error(graph.error)
  expect(graph.edges.map(e => [e.from, e.to, e.headAtFrom, e.headAtTo, e.style, e.label])).toEqual([
    ['A', 'B', true, true, 'solid', undefined],
    ['C', 'D', true, false, 'solid', undefined],
    ['E', 'F', false, false, 'solid', undefined],
    ['G', 'H', false, true, 'dotted', undefined],
    ['I', 'J', false, true, 'thick', undefined],
    ['K', 'L', false, true, 'solid', 'go'],
    ['M', 'N', false, true, 'solid', 'stop'],
    ['O', 'P', false, true, 'thick', 'fast'],
    ['Q', 'R', false, true, 'dotted', 'slow'],
  ])
})

test('a chain of arrows is not read as one labelled edge', () => {
  const graph = parse('graph LR\n  A --> B --> C\n  D -- go --> E --> F')
  if ('error' in graph) throw new Error(graph.error)
  expect(graph.edges.map(e => [e.from, e.to, e.label])).toEqual([['A', 'B', undefined], ['B', 'C', undefined], ['D', 'E', 'go'], ['E', 'F', undefined]])
})

test('every shape delimiter is recognised and stripped', () => {
  const graph = parse('graph LR\n  a[(Database)] --> b{{Decision}} --> c([Stadium]) --> d(((Double))) --> e>Flag] --> f[[Sub]] --> g[/Para/] --> h[\\Trap/] --> i((Circle)) --> j(Round) --> k{Diamond}')
  if ('error' in graph) throw new Error(graph.error)
  expect(graph.nodes.map(n => [n.label, n.shape])).toEqual([
    ['Database', 'cylinder'], ['Decision', 'hexagon'], ['Stadium', 'stadium'], ['Double', 'doublecircle'], ['Flag', 'flag'],
    ['Sub', 'subroutine'], ['Para', 'parallelogram'], ['Trap', 'trapezoid'], ['Circle', 'circle'], ['Round', 'round'], ['Diamond', 'diamond'],
  ])
})

test('fan-in and fan-out with &', () => {
  const graph = parse('graph TD\n  a & b --> c & d')
  if ('error' in graph) throw new Error(graph.error)
  expect(graph.edges.map(e => `${e.from}>${e.to}`)).toEqual(['a>c', 'a>d', 'b>c', 'b>d'])
})

test('style, classDef, class, ::: and the default class; stroke is accepted and dropped', () => {
  const graph = parse(['graph TD', '  A --> B --> C --> D:::hot', '  style A fill:#f9f,stroke:#333,color:#fff', '  classDef hot fill:#fdd,stroke:#c00;', '  class B hot;', '  style B stroke:#0a0', '  classDef default fill:#eee'].join('\n'))
  if ('error' in graph) throw new Error(graph.error)
  expect(graph.nodes.map(n => [n.id, n.style])).toEqual([
    ['A', { fill: '#f9f', color: '#fff' }],
    ['B', { fill: '#fdd' }],
    ['C', { fill: '#eee' }],
    ['D', { fill: '#fdd' }],
  ])
})

test('unsupported or malformed input is refused whole, never drawn partially', () => {
  expect(parse('sequenceDiagram\n  A->>B: hi')).toEqual({ error: 'not a flowchart: "sequenceDiagram"' })
  expect(parse('graph TD\n  subgraph S\n  A --> B\n  end')).toEqual({ error: 'subgraphs are not supported' })
  expect(parse('graph TD\n  A --o B')).toEqual({ error: '"o" arrow ends are not supported' })
  expect(parse('graph TD\n  A --x B')).toEqual({ error: '"x" arrow ends are not supported' })
  expect(parse('graph TD\n  A -->')).toEqual({ error: 'dangling arrow in "A -->"' })
  expect(parse('graph TD\n  A[unclosed --> B')).toEqual({ error: 'unclosed "[" in "[unclosed --> B"' })
  expect(parse('graph TD\n  A --> B ??')).toEqual({ error: 'expected an arrow at "??"' })
  expect(parse('graph TD')).toEqual({ error: 'no nodes' })
})

test('size limits refuse oversized input with the limit named', () => {
  let big = 'graph TD\n'
  for (let i = 0; i < 201; i++) big += `N${i} --> N${i + 1}\n`
  expect(parse(big)).toEqual({ error: 'more than 200 nodes' })
  expect(parse(`graph TD\n  A[${'x'.repeat(61)}] --> B`)).toEqual({ error: 'node label longer than 60 cells' })
})
