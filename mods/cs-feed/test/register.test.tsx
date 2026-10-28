// ABOUTME: Checks the feed's hook inventory and behavior through the engine test kit.
// ABOUTME: Recording registrars inspect declarations; rendering and effects use the real engine chains.
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { PAINTERS, register } from '../hooks/register'
import { BAND_ELEMENT, BAND_PLUGIN } from '../hooks/settings'

test('register installs one hook per door and every feed render site', () => {
  const seen: { event: string; matcher: unknown }[] = []
  const record = (event: string, matcher: unknown) => { seen.push({ event, matcher: typeof matcher === 'function' ? undefined : matcher }) }
  register(record as unknown as On)
  expect(seen.find(entry => entry.event === 'ui.press')?.matcher).toEqual({ plugin: BAND_PLUGIN, element: BAND_ELEMENT })
  expect(seen).toEqual([
    { event: 'session.start', matcher: undefined },
    { event: 'command.run', matcher: { command: 'feed' } },
    { event: 'command.run', matcher: { command: 'helpers' } },
    { event: 'ui.press', matcher: { plugin: 'cs', element: 'cs-feed' } },
    { event: 'ui.render', matcher: { component: 'Pane', requestId: 'cs-feed' } },
    { event: 'ui.render', matcher: { component: 'Pane', requestId: 'cs-feed-helpers' } },
    ...['prompt', 'command', 'response', 'tool-result', 'delivery'].map(door => ({ event: 'session.append', matcher: { door } })),
    { event: 'turn.start', matcher: undefined },
    { event: 'turn.complete', matcher: undefined },
    { event: 'agent.spawn', matcher: undefined },
    ...['UserMessage', 'AssistantMessage', 'ToolUse', 'ToolGroup', 'ToolResult', 'ToolProgress', 'TurnDuration', 'CommandOutput', 'Spinner', 'SessionMode', 'AbovePrompt'].map(component => ({ event: 'ui.render', matcher: { component } })),
  ])
  expect(seen.filter(entry => entry.event === 'ui.render' && typeof entry.matcher === 'object' && entry.matcher !== null && 'component' in entry.matcher && entry.matcher.component !== 'Pane').map(entry => typeof entry.matcher === 'object' && entry.matcher !== null && 'component' in entry.matcher ? entry.matcher.component : undefined)).toEqual(Object.keys(PAINTERS))
})

test('two quick cs button presses share its held write and feed reads on only after it settles', {
  plugins: [{ name: 'cs', register(on) {
    let pending: Promise<void> | undefined
    on('ui.render', { component: 'ToolProgress' }, ($, e) => {
      const press = () => pending ??= $.fs.write('/session/.cs/local/feed', 'on\n').finally(() => { pending = undefined })
      return $.ui.resolve(e).Button({ key: 'cs-feed', label: 'feed', onPress: press })
    })
  } }],
}, async ($, on) => {
  let file = 'off\n'
  let writes = 0
  const reads: string[] = []
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => {
    if (!e.path.endsWith('/feed')) return { deny: 'ENOENT: no such file or directory' }
    reads.push(file)
    return { value: file }
  })
  on('fs.write', async ($, e) => { writes++; entered?.(); await held; file = e.text; return { value: undefined } })
  on('session.messages', () => ({ value: [] }))
  const clock = mock.clock(on)
  const row = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b' } })
  expect(reads).toEqual(['off\n'])
  const first = $.ui.press({ plugin: 'cs', key: 'cs-feed' })
  await started
  const second = $.ui.press({ plugin: 'cs', key: 'cs-feed' })
  await clock.settle()
  expect(writes).toBe(1)
  expect(reads).toEqual(['off\n'])
  release?.()
  await Promise.all([first, second])
  expect(reads).toEqual(['off\n', 'on\n', 'on\n'])
  expect(await $.command.run({ command: 'feed', args: 'status', origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } })).toEqual({ text: 'on · clean' })
  expect(writes).toBe(1)
  await row.unmount()
})

test('session start issues both command registrations before waiting', async ($, on) => {
  const calls: string[] = []
  let release: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  on('command.register', async ($, e) => {
    calls.push(`register ${e.name}`)
    if (e.name === 'feed') await held
    if (e.name === 'helpers') release?.()
    return { value: { command: e.name } }
  })
  on('session.start', ($, e) => { calls.push('engine start'); return { cwd: e.cwd } })
  expect(await $.session.start({ cwd: '/session', surface: 'terminal', isInteractive: true })).toEqual({ cwd: '/session' })
  expect(calls).toEqual(['register feed', 'register helpers', 'engine start'])
})

test('session start registers /feed and /helpers with their menu words, and /helpers answers where the pane opens', async ($, on) => {
  const specs: unknown[] = []
  on('command.register', async ($, e) => { specs.push({ ...e }); return { value: { command: e.name } } })
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  await $.session.start({ cwd: '/session', surface: 'terminal', isInteractive: true })
  expect(specs).toEqual([
    { name: 'feed', description: 'Chat view for this session: on, off, clean, normal, raw, or one setting', argumentHint: 'on | off | clean | normal | raw | status | <setting> <value>', immediate: true },
    { name: 'helpers', description: "Show each helper's own work, call by call", immediate: true },
  ])
  expect(await $.command.run({ command: 'helpers', args: '', origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } })).toEqual({ text: 'Helpers open above the prompt.' })
})
