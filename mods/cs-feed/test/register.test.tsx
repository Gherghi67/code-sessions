// ABOUTME: Checks the feed's hook inventory and behavior through the engine test kit.
// ABOUTME: Recording registrars inspect declarations; rendering and effects use the real engine chains.
import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { PAINTERS, register } from '../hooks/register'

test('register installs one hook per door and every feed render site', () => {
  const seen: { event: string; matcher: unknown }[] = []
  const record = (event: string, matcher: unknown) => { seen.push({ event, matcher: typeof matcher === 'function' ? undefined : matcher }) }
  register(record as unknown as On)
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
