// ABOUTME: Exercises the feed clocks across a mid-tick switch off using the real engine chains.
// ABOUTME: The kit clock holds time; recording hooks hold an agent-list answer and capture token writes.
import { expect, mock, test } from 'claude-code/testing'
import type { AgentInfo, On, SessionMessage } from 'claude-code'

test('a tick suspended in agent list stops after feed off without a token write or another wait', async ($, on) => {
  let file = 'on\n'
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  const writes: string[] = []
  let waits = 0
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: file } : { deny: 'ENOENT: no such file or directory' })
  on('fs.exists', () => ({ value: true }))
  on('fs.write', ($, e) => { if (e.path.endsWith('/feed')) file = e.text; return { value: undefined } })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.messages', () => ({ value: [] }))
  // The load's first refresh reads the list at once; the tick's read is the one held.
  let lists = 0
  on('agent.list', async () => { if (++lists > 1) { entered?.(); await held } return { value: [] } })
  on('config.list', () => ({ value: [] }))
  on('state.set', async ($, e, next) => { writes.push(e.key); return next(e) })
  on('clock.after', { ms: 1000 }, async ($, e, next) => { waits++; return next(e) })
  const clock = mock.clock(on)
  on('ui.render', { component: 'ToolProgress' }, ($, e) => $.ui.resolve(e).Text({ children: `hint:${e.props.hint}` }))
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b' } })
  expect((await row.find({ type: 'Text' }))?.text).toBe('hint:')
  const advancing = clock.advance(1000)
  await started
  expect(await $.command.run({ command: 'feed', args: 'off', origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } })).toEqual({ text: 'Chat view: off.' })
  writes.length = 0
  release?.()
  await advancing
  await clock.advance(5000)
  expect(writes).toEqual([])
  expect(waits).toBe(1)
  expect((await row.find({ type: 'Text' }))?.text).toBe('hint:ctrl+b')
  await row.unmount()
})

for (const status of ['pending', 'waiting'] as const) test(`the pulse continues while a helper is ${status}`, async ($, on) => {
  const pulses: unknown[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'on\n' } : { deny: 'ENOENT: no such file or directory' })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [{ id: 'helper', description: 'Read notes', type: 'Explore', status }] }))
  on('config.list', () => ({ value: [] }))
  on('state.set', async ($, e, next) => { if (e.key === 'pulse') pulses.push(e.value); return next(e) })
  on('ui.render', { component: 'ToolProgress' }, ($, e) => $.ui.resolve(e).Text({ children: e.props.hint }))
  const clock = mock.clock(on)
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b' } })
  await clock.advance(70)
  expect(pulses).toEqual([1])
  await clock.advance(70)
  expect(pulses).toEqual([1, 2])
  await row.unmount()
})

function feedOn(on: On, rows: SessionMessage[], agents: () => AgentInfo[]) {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'on\n' } : { deny: 'ENOENT: no such file or directory' })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.messages', ($, e) => ({ value: e.as === 'api' ? [] : rows }))
  on('agent.list', () => ({ value: agents() }))
  on('config.list', () => ({ value: [] }))
  return mock.clock(on)
}

const HELPER_CALLS = [
  { tool_use_id: 'bg-call', tool: 'Agent', input: { description: 'Read the notes', subagent_type: 'Explore' }, result: {}, text: 'launched', agentId: 'reader' },
  { tool_use_id: 'done-call', tool: 'Agent', input: { description: 'Make a plan', subagent_type: 'Plan' }, result: {}, text: 'done', agentId: 'planner', durationMs: 4000 },
]

test('a running helper row and a busy helper batch redraw with the clocks; a finished helper row is drawn once', async ($, on) => {
  const clock = feedOn(on, [{ role: 'user', text: 'Look around', toolUses: [] }, { role: 'assistant', text: '', toolUses: HELPER_CALLS }], () => [
    { id: 'reader', type: 'Explore', description: 'Read the notes', status: 'running' },
    { id: 'planner', type: 'Plan', description: 'Make a plan', status: 'completed' },
  ])
  const draws = new Map<string, number>()
  const count = (id: string | undefined) => draws.set(id ?? '', (draws.get(id ?? '') ?? 0) + 1)
  on('ui.render', { component: 'ToolUse' }, ($, e) => { count(e.requestId); return $.ui.resolve(e).Text({ children: 'engine tool' }) })
  on('ui.render', { component: 'ToolGroup' }, ($, e) => { count(e.requestId); return $.ui.resolve(e).Text({ children: 'engine group' }) })
  const call = (id: string, description: string, type: string) => ({ tool_use_id: id, tool: 'Agent', input: { description, subagent_type: type }, isRunning: false, isErrored: false, isInterrupted: false })
  const running = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolUse', requestId: 'running', props: call('bg-call', 'Read the notes', 'Explore') })
  const finished = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolUse', requestId: 'finished', props: call('done-call', 'Make a plan', 'Plan') })
  const batch = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolGroup', requestId: 'batch', props: { calls: [call('bg-call', 'Read the notes', 'Explore'), call('done-call', 'Make a plan', 'Plan')], isActive: false, isExpanded: false, isCallsOnly: true } })
  expect((await running.find({ type: 'Text' }))?.text).toBe('Read the notes · running')
  expect((await finished.find({ type: 'Text' }))?.text).toBe('Make a plan · finished · 4s')
  await clock.settle()
  const before = new Map(draws)
  await clock.advance(140)
  expect(draws.get('running')).toBe(before.get('running'))
  expect(draws.get('batch') ?? 0).toBeGreaterThan(before.get('batch') ?? 0)
  await clock.advance(3000)
  expect(draws.get('running') ?? 0).toBeGreaterThanOrEqual((before.get('running') ?? 0) + 3)
  expect(draws.get('finished')).toBe(before.get('finished'))
  await running.unmount()
  await finished.unmount()
  await batch.unmount()
})

test('the working line redraws with the clock while it counts helpers', async ($, on) => {
  const clock = feedOn(on, [{ role: 'user', text: 'Look around', toolUses: [] }], () => [{ id: 'reader', type: 'Explore', description: 'Read the notes', status: 'running' }])
  let draws = 0
  const messages: (string | null)[] = []
  on('ui.render', { component: 'Spinner' }, ($, e) => { draws++; messages.push(e.props.message); return $.ui.resolve(e).Text({ children: e.props.message ?? '' }) })
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  await $.turn.start({ text: 'Look around', turnId: 'turn' })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'Spinner', props: { word: 'Thinking', message: null, suffix: '…', mode: 'thinking' } })
  await clock.settle()
  expect(messages.at(-1)).toBe('Thinking · 1 helper working')
  const before = draws
  await clock.advance(3000)
  expect(draws).toBeGreaterThanOrEqual(before + 3)
  await row.unmount()
})
