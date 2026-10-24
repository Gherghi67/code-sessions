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
  // A turn is open, so the tick asks for the agent list.
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('ui.render', { component: 'ToolProgress' }, ($, e) => $.ui.resolve(e).Text({ children: `hint:${e.props.hint}` }))
  await $.turn.start({ text: 'Work', turnId: 'turn' })
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

const SPAWN = { prompt: 'Work', provider: { plugin: 'engine', tier: 'core' }, parentModel: 'model', background: false, fork: false } as const

test('the tick asks for the agent list only while a turn is open or a helper is busy', async ($, on) => {
  let agents: AgentInfo[] = []
  let lists = 0
  const clock = feedOn(on, [{ role: 'user', text: 'Start', toolUses: [] }], () => { lists++; return agents })
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('agent.spawn', () => ({ model: 'model', agentId: 'reader' }))
  on('ui.render', { component: 'ToolProgress' }, ($, e) => $.ui.resolve(e).Text({ children: e.props.hint }))
  await $.turn.start({ text: 'Start', turnId: 'turn' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 'turn', reason: 'answer' })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b' } })
  await clock.settle()
  expect(lists).toBe(1)
  await clock.advance(3000)
  expect(lists).toBe(1)
  agents = [{ id: 'reader', type: 'Explore', description: 'Read the notes', status: 'running' }]
  await $.agent.spawn({ ...SPAWN, tool_use_id: 'read-call', description: 'Read the notes', subagentType: 'Explore' })
  await clock.settle()
  expect(lists).toBe(2)
  await clock.advance(3000)
  expect(lists).toBe(5)
  agents = []
  await clock.advance(1000)
  expect(lists).toBe(6)
  await clock.advance(3000)
  expect(lists).toBe(6)
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

test('a call older than the snapshot is drawn from its props once while no turn is open, whatever the LIVE bumps', async ($, on) => {
  const rows: SessionMessage[] = [{ role: 'user', text: 'Start', toolUses: [] }]
  const clock = feedOn(on, rows, () => [])
  const bumps: unknown[] = []
  let draws = 0
  on('state.set', async ($, e, next) => { if (e.key === 'live') bumps.push(e.value); return next(e) })
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('ui.render', { component: 'ToolUse' }, ($, e) => { draws++; return $.ui.resolve(e).Text({ children: 'engine tool' }) })
  await $.turn.start({ text: 'Start', turnId: 'turn' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 'turn', reason: 'answer' })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolUse', requestId: 'old', props: { tool_use_id: 'old', tool: 'Read', input: { file_path: 'notes.md' }, isRunning: false, isErrored: false, isInterrupted: false } })
  await clock.settle()
  const before = { draws, bumps: bumps.length }
  for (const uuid of ['one', 'two']) {
    rows.push({ role: 'assistant', text: '', toolUses: [{ tool_use_id: `call-${uuid}`, tool: 'Read', input: { file_path: `${uuid}.md` }, result: {} }] })
    await $.session.append({ door: 'response', origin: { kind: 'model', model: 'model' }, uuid, message: { type: 'assistant', role: 'assistant', content: [{ type: 'tool_use', id: `call-${uuid}`, name: 'Read', input: { file_path: `${uuid}.md` } }] } })
    await clock.settle()
  }
  expect(bumps.length).toBe(before.bumps + 2)
  expect(draws).toBe(before.draws)
  await row.unmount()
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

test('the desktop band draws the usage windows, and a failed appearance probe keeps the theme and the tick', async ($, on) => {
  const ticks: unknown[] = []
  const probes: unknown[] = []
  const logs: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'on\n' } : { deny: 'ENOENT: no such file or directory' })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => {
    if (e.argv[0] === '/bin/cs') return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    probes.push(e.argv)
    throw new Error('no defaults here')
  })
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200000 }, rateLimits: [{ kind: 'five_hour', percentUsed: 20 }, { kind: 'seven_day', percentUsed: 49 }] } }))
  const clock = mock.clock(on)
  on('state.set', async ($, e, next) => { if (e.key === 'tick') ticks.push(e.value); return next(e) })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine band' }))
  const band = await $.ui.mount({ plugin: 'cs-feed', surface: 'desktop', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 90, scroll: { offset: 0, bodyRows: 6 }, view: {} } })
  expect((await band.find({ type: 'Text', text: '20%' }))?.text).toBe('20% · 5h')
  expect((await band.find({ type: 'Text', text: '49%' }))?.text).toBe('49% · week')
  expect(await band.find({ type: 'Text', text: 'Test' })).toBeUndefined()
  await clock.advance(3000)
  expect(probes).toEqual([['/usr/bin/defaults', 'read', '-g', 'AppleInterfaceStyle']])
  expect(ticks).toEqual([1, 2, 3])
  expect(logs).toEqual([])
  await band.unmount()
})

test('a pulse write that fails stops the pulse with one log line, and the next painted draw starts it again', async ($, on) => {
  const clock = feedOn(on, [], () => [{ id: 'reader', type: 'Explore', description: 'Read the notes', status: 'running' }])
  const pulses: unknown[] = []
  const logs: string[] = []
  let refuse = true
  on('state.set', async ($, e, next) => {
    if (e.key !== 'pulse') return next(e)
    if (refuse) { refuse = false; return { deny: 'pulse refused' } }
    pulses.push(e.value)
    return next(e)
  })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  on('ui.render', { component: 'ToolProgress' }, ($, e) => $.ui.resolve(e).Text({ children: e.props.hint }))
  const props = { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b' } as const
  const first = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolProgress', requestId: 'first', props })
  await clock.advance(700)
  expect(logs).toEqual(['pulse stopped: cs-feed: $.state.set: pulse refused'])
  expect(pulses).toEqual([])
  const second = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolProgress', requestId: 'second', props })
  await clock.advance(70)
  expect(pulses).toEqual([1])
  await first.unmount()
  await second.unmount()
})

for (const key of ['live', 'tick'] as const) test(`a ${key} bump whose token read is in flight when the feed goes off writes nothing`, async ($, on) => {
  let file = 'on\n'
  let hold: string | undefined
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  const writes: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: file } : { deny: 'ENOENT: no such file or directory' })
  on('fs.exists', () => ({ value: true }))
  on('fs.write', ($, e) => { if (e.path.endsWith('/feed')) file = e.text; return { value: undefined } })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  let rows: SessionMessage[] = []
  on('session.messages', ($, e) => ({ value: e.as === 'api' ? [] : rows }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  on('state.get', async ($, e, next) => { if (e.key === hold) { hold = undefined; entered?.(); await held } return next(e) })
  on('state.set', async ($, e, next) => { writes.push(e.key); return next(e) })
  const clock = mock.clock(on)
  on('ui.render', { component: 'ToolProgress' }, ($, e) => $.ui.resolve(e).Text({ children: `hint:${e.props.hint}` }))
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b' } })
  await clock.settle()
  hold = key
  rows = [{ role: 'user', text: 'Start', toolUses: [] }, { role: 'assistant', text: 'Working on it', toolUses: [] }]
  const moving = key === 'live'
    ? $.session.append({ door: 'response', origin: { kind: 'model', model: 'model' }, uuid: 'reply', message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text: 'Working on it' }] } }).then(() => clock.settle())
    : clock.advance(1000)
  await started
  expect(await $.command.run({ command: 'feed', args: 'off', origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } })).toEqual({ text: 'Chat view: off.' })
  writes.length = 0
  release?.()
  await moving
  await clock.advance(3000)
  expect(writes).toEqual([])
  await row.unmount()
})
