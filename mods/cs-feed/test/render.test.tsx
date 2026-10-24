// ABOUTME: Checks each feed painter's visible words through real mounted engine render chains.
// ABOUTME: Test hooks supply recorded session inputs and retain an observable engine drawing beneath the feed.
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

function session(on: On) {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'on\n' } : { deny: 'ENOENT: no such file or directory' })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
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
