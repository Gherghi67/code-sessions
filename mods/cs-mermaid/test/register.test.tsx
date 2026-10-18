// ABOUTME: Engine test-kit tests for the cs-mermaid register module: inline drawing, the fallback to source, fit and palette helpers.
// ABOUTME: Also pins the drawDiagrams option, which turns off both the drawing and the system prompt section.
import { test, expect } from 'claude-code/testing'
import type { On } from 'claude-code'

import { DISABLED, OPTION, PROMPT_SECTION, blockRows, fencesOf, fillFor, fit, labelColor, paletteFor, roleOf, splitReply } from '../hooks/register'
import { parse } from '../hooks/parse'

const TEXT = ['Flow:', '', '```mermaid', 'graph TD', '  A[prompt] --> B{cached?}', '  B -->|no| C[render]', '```'].join('\n')

test('fencesOf finds mermaid fences and ignores other fences', () => {
  expect(fencesOf(TEXT)).toEqual(['graph TD\n  A[prompt] --> B{cached?}\n  B -->|no| C[render]'])
  expect(fencesOf('```ts\nconst a = 1\n```')).toEqual([])
  // A four-backtick block quoting mermaid source is not a fence of its own.
  expect(fencesOf('x\n````mermaid\ngraph TD\nA-->B\n````\n')).toEqual([])
})

test('a reply without mermaid is left to the engine', async ($, on) => {
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine drew it</Text>
  })
  const mounted = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text: 'plain', isFirstOfReply: true } })
  expect(await mounted.find({ type: 'Text', text: 'engine drew it' })).toBeDefined()
  await mounted.unmount()
})

// The engine stand-in draws each block it is handed and records what it was handed.
function engine(on: On, seen: { text: string; isFirstOfReply: boolean }[]) {
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    seen.push({ text: e.props.text, isFirstOfReply: e.props.isFirstOfReply })
    return <Text>engine: {e.props.text}</Text>
  })
}

test('a reply with a fence hands its prose to the engine and draws the chart as blocks, with no fence left', async ($, on) => {
  on('config.list', () => ({ value: [] }))
  const seen: { text: string; isFirstOfReply: boolean }[] = []
  engine(on, seen)
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text: TEXT, isFirstOfReply: true } })
  expect(seen).toEqual([{ text: 'Flow:\n', isFirstOfReply: true }])
  expect(await reply.find({ type: 'Text', text: 'engine: Flow:' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'prompt' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'cached?' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'render' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'no' })).toBeDefined()
  expect(await reply.findAll({ type: 'Code' })).toEqual([])
  // Role hues: prompt leads, cached? branches, render ends.
  expect((await reply.find({ type: 'Text', text: 'prompt' }))?.props.backgroundColor).toBe('#D3F9D8')
  expect((await reply.find({ type: 'Text', text: 'cached?' }))?.props.backgroundColor).toBe('#FFF3BF')
  expect((await reply.find({ type: 'Text', text: 'render' }))?.props.backgroundColor).toBe('#E9ECEF')
  // The `no` label answers the decision: drawn in the answer's colour, not the line's.
  expect((await reply.find({ type: 'Text', text: 'no' }))?.props.color).toBe('#C92A2A')
  await reply.unmount()
})

test('a reply that opens with a fence gives the bullet to no prose part', async ($, on) => {
  on('config.list', () => ({ value: [] }))
  const seen: { text: string; isFirstOfReply: boolean }[] = []
  engine(on, seen)
  const text = '```mermaid\ngraph TD\n  A --> B\n```\nafter'
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text, isFirstOfReply: true } })
  expect(seen).toEqual([{ text: '\nafter', isFirstOfReply: false }])
  await reply.unmount()
})

test('an unsupported chart stays a fence with the reason under it', async ($, on) => {
  on('config.list', () => ({ value: [] }))
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine drew it</Text>
  })
  const text = '```mermaid\ngraph TD\n  subgraph S\n  A --> B\n  end\n```'
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text, isFirstOfReply: true } })
  expect(await reply.find({ type: 'Code', text: 'subgraph S' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'mermaid: subgraphs are not supported' })).toBeDefined()
  await reply.unmount()
})

test('with drawDiagrams off, a reply with a fence is left to the engine', { options: { [OPTION]: false } }, async ($, on) => {
  on('config.list', () => ({ value: [] }))
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine drew it</Text>
  })
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text: TEXT, isFirstOfReply: true } })
  expect(await reply.find({ type: 'Text', text: 'engine drew it' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'cached?' })).toBeUndefined()
  await reply.unmount()
})

const ENGINE_SECTIONS = { sections: [{ id: 'intro', text: 'engine intro', scope: 'shared' as const }] }
const TERMINAL_PROMPT = { model: 'claude-test', promptModel: 'claude-test', surfaces: ['terminal'], tools: [], outputStyle: null, traits: [] } as const

// The session directory, and which paths exist under it.
function session(on: On, existing: string[]) {
  on('session.cwd', () => ({ value: '/work/demo' }))
  on('fs.exists', ($, e) => ({ value: existing.includes(e.path) }))
}

test('a terminal session prompt ends with the diagrams section', async ($, on) => {
  session(on, [])
  on('prompt.compose', () => ENGINE_SECTIONS)
  const composed = await $.prompt.compose(TERMINAL_PROMPT)
  expect(composed.sections.map(s => s.id)).toEqual(['intro', 'cs-mermaid:diagrams'])
  expect(composed.sections[1]).toEqual(PROMPT_SECTION)
})

test('a session with .cs/local/disabled gets no diagrams section', async ($, on) => {
  session(on, [`/work/demo/${DISABLED}`])
  on('prompt.compose', () => ENGINE_SECTIONS)
  expect((await $.prompt.compose(TERMINAL_PROMPT)).sections.map(s => s.id)).toEqual(['intro'])
})

test('a prompt with no terminal, or a --bare one, gets no diagrams section', async ($, on) => {
  session(on, [])
  on('prompt.compose', () => ENGINE_SECTIONS)
  expect((await $.prompt.compose({ ...TERMINAL_PROMPT, surfaces: [], traits: ['print'] })).sections.map(s => s.id)).toEqual(['intro'])
  expect((await $.prompt.compose({ ...TERMINAL_PROMPT, traits: ['bare'] })).sections.map(s => s.id)).toEqual(['intro'])
})

test('with drawDiagrams off, the prompt gets no diagrams section', { options: { [OPTION]: false } }, async ($, on) => {
  on('prompt.compose', () => ENGINE_SECTIONS)
  expect((await $.prompt.compose(TERMINAL_PROMPT)).sections.map(s => s.id)).toEqual(['intro'])
})

test('fit turns a wide LR chart, keeps one that fits, and reports one that cannot fit', () => {
  const wide = parse('graph LR\n  A[a long label here] --> B[another long label] --> C[and a third one]')
  if ('error' in wide) throw new Error(wide.error)
  const turned = fit(wide, 40)
  if ('error' in turned) throw new Error(turned.error)
  expect(turned.turned).toBe(true)
  expect(turned.drawn.width).toBeLessThanOrEqual(40)
  const kept = fit(wide, 200)
  if ('error' in kept) throw new Error(kept.error)
  expect(kept.turned).toBe(false)
  const fan = parse('graph TD\n  A --> B & C & D & E & F')
  if ('error' in fan) throw new Error(fan.error)
  // five 5-wide blocks, four 3-cell gaps, a margin each side
  expect(fit(fan, 20)).toEqual({ error: 'diagram is 39 columns wide, the transcript 20' })
})

test('a node takes its role from its shape, else from its place in the flow; a style fill wins', () => {
  const graph = parse(['graph TD', '  S((go)) --> A[one] --> B[two] --> C[three]', '  B --> D[four]', '  E{ask} --> F[alone]', '  G[lone]', '  style B fill:#abc'].join('\n'))
  if ('error' in graph) throw new Error(graph.error)
  const role = (id: string) => roleOf(graph.nodes.find(n => n.id === id)!, graph)
  expect(role('S')).toBe('start')
  expect(role('A')).toBe('step')
  expect(role('B')).toBe('decision')
  expect(role('C')).toBe('end')
  expect(role('D')).toBe('end')
  expect(role('E')).toBe('decision')
  expect(role('F')).toBe('end')
  expect(role('G')).toBe('step')
  expect(fillFor('start', paletteFor('light'))).toBe('#D3F9D8')
  expect(fillFor('end', paletteFor('dark'))).toBe('#3A3D42')
  expect(fillFor('decision', paletteFor('light'))).toBe('#FFF3BF')
  expect(fillFor('step', paletteFor('light'))).toBe('#ECECFF')
  expect(graph.nodes.find(n => n.id === 'B')!.style).toEqual({ fill: '#abc' })
})

test('a decision answer colours its label; other labels take the line colour', () => {
  expect(labelColor('yes', paletteFor('light'))).toBe('#2B8A3E')
  expect(labelColor('Fail', paletteFor('light'))).toBe('#C92A2A')
  expect(labelColor('degraded', paletteFor('dark'))).toBe('#FF8787')
  expect(labelColor('retry later', paletteFor('light'))).toBe('#333333')
  expect(labelColor('nothing', paletteFor('light'))).toBe('#333333')
})

test('the palette follows the theme row', () => {
  expect(paletteFor('dark').fill).toBe('#3B3F6B')
  expect(paletteFor('dark-daltonized').fill).toBe('#3B3F6B')
  expect(paletteFor('light').fill).toBe('#ECECFF')
  expect(paletteFor(undefined).fill).toBe('#ECECFF')
})

test('blockRows pads full-width rows with the label centred, measured in cells', () => {
  expect(blockRows('ab', 8, 3)).toEqual(['        ', '   ab   ', '        '])
  expect(blockRows('abc', 8, 3)).toEqual(['        ', '  abc   ', '        '])
  expect(blockRows('界界', 6, 3)).toEqual(['      ', ' 界界 ', '      '])
  expect(blockRows('toolong', 4, 5)).toEqual(['    ', '    ', 'too…', '    ', '    '])
})

test('splitReply keeps prose and fences in order', () => {
  expect(splitReply(TEXT)).toEqual([
    { kind: 'text', body: 'Flow:\n' },
    { kind: 'mermaid', body: 'graph TD\n  A[prompt] --> B{cached?}\n  B -->|no| C[render]' },
  ])
  expect(splitReply('a\n```mermaid\ngraph TD\nA --> B\n```\nb\n```mermaid\ngraph LR\nC --> D\n```')).toEqual([
    { kind: 'text', body: 'a' },
    { kind: 'mermaid', body: 'graph TD\nA --> B' },
    { kind: 'text', body: '\nb' },
    { kind: 'mermaid', body: 'graph LR\nC --> D' },
  ])
})

