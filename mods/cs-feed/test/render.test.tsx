// ABOUTME: Checks each feed painter's visible words through real mounted engine render chains.
// ABOUTME: Test hooks supply recorded session inputs and retain an observable engine drawing beneath the feed.
import { expect, mock, test } from 'claude-code/testing'
import type { AgentInfo, On, SessionMessage } from 'claude-code'

function session(on: On, rows: SessionMessage[] = [], agents: () => AgentInfo[] = () => []) {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'on\n' } : { deny: 'ENOENT: no such file or directory' })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.messages', ($, e) => ({ value: e.as === 'api' ? [] : rows }))
  on('agent.list', () => ({ value: agents() }))
  on('config.list', () => ({ value: [] }))
  return mock.clock(on)
}

test('UserMessage draws the terminal you margin and leaves the desktop engine body intact', async ($, on) => {
  session(on)
  let calls = 0
  on('ui.render', { component: 'UserMessage' }, ($, e) => { calls++; return $.ui.resolve(e).Text({ children: 'engine prompt' }) })
  const terminal = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect((await terminal.find({ type: 'Text', text: 'you' }))?.text).toBe('you')
  expect((await terminal.find({ type: 'Text', text: 'you' }))?.props.color).toBe('#9fb4c8')
  expect((await terminal.find({ type: 'Text', text: 'Read the notes' }))?.text).toBe('Read the notes')
  expect(await terminal.find({ text: 'engine prompt' })).toBeUndefined()
  const desktop = await $.ui.mount({ plugin: 'cs-feed', surface: 'desktop', component: 'UserMessage', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect((await desktop.find({ type: 'Text' }))?.text).toBe('engine prompt')
  expect(calls).toBe(2)
  await terminal.unmount()
  await desktop.unmount()
})

test('UserMessage keeps hook feedback as a quiet circle line', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', props: { text: 'Stop hook feedback:\nTests need another pass', origin: { kind: 'unclassified' }, isExpanded: false } })
  expect((await row.find({ type: 'Text' }))?.text).toBe('○ Tests need another pass')
  await row.unmount()
})

test('AssistantMessage frames the engine markdown once with the terminal claude margin', async ($, on) => {
  session(on)
  const flags: boolean[] = []
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => { flags.push(e.props.isFirstOfReply); return $.ui.resolve(e).Text({ children: 'engine markdown' }) })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Here is the answer.', isFirstOfReply: true } })
  expect((await row.find({ type: 'Text', text: 'claude' }))?.text).toBe('claude')
  expect((await row.find({ type: 'Text', text: 'claude' }))?.props.color).toBe('#e3c4a2')
  expect((await row.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect(flags).toEqual([false])
  await row.unmount()
})

test('ToolUse draws a completed read with its own words and a fullscreen disclosure', async ($, on) => {
  session(on)
  let calls = 0
  on('ui.render', { component: 'ToolUse' }, ($, e) => { calls++; return $.ui.resolve(e).Text({ children: 'engine tool' }) })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolUse', viewport: { columns: 80, rows: 24, isFullscreen: true }, props: { tool_use_id: 'read', tool: 'Read', input: { file_path: '/repo/notes.md' }, isRunning: false, isErrored: false, isInterrupted: false, output: 'the notes' } })
  expect((await row.find({ type: 'Text', text: 'Read notes.md' }))?.text).toBe('Read notes.md')
  expect((await row.find({ type: 'Button' }))?.props.label).toBe('›')
  expect(calls).toBe(1)
  await $.ui.press({ plugin: 'cs-feed', key: 'read' })
  expect((await row.find({ type: 'Text', text: 'the notes' }))?.text).toBe('the notes')
  expect((await row.find({ type: 'Button' }))?.props.label).toBe('⌄')
  expect(calls).toBe(2)
  await row.unmount()
})

test('ToolResult hides a filed result while its own expanded row stays with the engine', async ($, on) => {
  session(on, [{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'read', tool: 'Read', input: {} }] }])
  let calls = 0
  on('ui.render', { component: 'ToolResult' }, ($, e) => { calls++; return $.ui.resolve(e).Text({ children: 'engine result' }) })
  const props = { tool_use_id: 'read', tool: 'Read', output: 'notes', isErrored: false }
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolResult', requestId: 'normal', props })
  expect(await row.findAll({ type: 'Text' })).toEqual([])
  const expanded = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolResult', requestId: 'expanded', props: { ...props, isExpanded: true } })
  expect((await expanded.find({ type: 'Text' }))?.text).toBe('engine result')
  expect(calls).toBe(2)
  await row.unmount()
  await expanded.unmount()
})

test('prompt peer observations group two stored messages under their first row', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine peer' }))
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'head', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'First update' }] } })
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'tail', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'Second update' }] } })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'head', props: { text: 'First update', origin: { kind: 'peer' }, isExpanded: false } })
  expect((await row.find({ type: 'Text', text: '⇄' }))?.text.split(' · ').slice(0, 2)).toEqual(['⇄ 2 messages', 'another session'])
  const tail = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'tail', props: { text: 'Second update', origin: { kind: 'peer' }, isExpanded: false } })
  expect(await tail.findAll({ type: 'Text' })).toEqual([])
  await row.unmount()
  await tail.unmount()
})

test('an already drawn peer head becomes a burst when the next peer arrives', async ($, on) => {
  const clock = session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine peer' }))
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'head', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'First update' }] } })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'head', props: { text: 'First update', origin: { kind: 'peer' }, isExpanded: false } })
  expect((await row.find({ type: 'Text' }))?.text).toBe('⇄ another session · First update')
  await clock.settle()
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'tail', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'Second update' }] } })
  const tail = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'tail', props: { text: 'Second update', origin: { kind: 'peer' }, isExpanded: false } })
  await clock.settle()
  expect((await row.find({ type: 'Text', text: '⇄' }))?.text.split(' · ').slice(0, 2)).toEqual(['⇄ 2 messages', 'another session'])
  expect(await tail.findAll({ type: 'Text' })).toEqual([])
  await row.unmount()
  await tail.unmount()
})

