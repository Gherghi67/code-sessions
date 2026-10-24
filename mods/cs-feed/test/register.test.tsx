// ABOUTME: Checks the feed's hook inventory and behavior through the engine test kit.
// ABOUTME: Recording registrars inspect declarations; rendering and effects use the real engine chains.
import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { register } from '../hooks/register'

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
})
