// ABOUTME: Exercises the feed clocks across a mid-tick switch off using the real engine chains.
// ABOUTME: The kit clock holds time; recording hooks hold an agent-list answer and capture token writes.
import { expect, mock, test } from 'claude-code/testing'

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
