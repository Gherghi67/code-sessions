// ABOUTME: Exercises the pure state transitions behind live transcript observations.
// ABOUTME: Event order comes from the design's measured append and turn-start sequence.
import { expect, mock, test } from 'claude-code/testing'
import { newLoad, observePrompt, observeTurnStart, observeResponse, openTurn, replaceResponseText } from '../hooks/session'
import { buildTranscript } from '../hooks/transcript'

const STATUS = { command: 'feed', args: 'status', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } } as const

for (const file of ['off\n', undefined]) test(`${file === undefined ? 'an absent' : 'an off'} feed reads once per load without asking cs to vet it`, async ($, on) => {
  const reads: string[] = []
  const logs: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => {
    reads.push(e.path)
    if (e.path === '/session/.cs/local/feed' && file !== undefined) return { value: file }
    return { deny: 'ENOENT: no such file or directory' }
  })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    return $.ui.resolve(e).Text({ children: 'engine reply' })
  })
  const one = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'answer', isFirstOfReply: true } })
  const two = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'answer', isFirstOfReply: true } })
  expect((await one.find({ type: 'Text' }))?.text).toBe('engine reply')
  expect((await two.find({ type: 'Text' }))?.text).toBe('engine reply')
  expect(reads).toEqual(['/session/.cs/local/feed', '/session/.cs/local/feed-view'])
  expect(logs).toEqual([])
  await one.unmount()
  await two.unmount()
})

test('two renders share an on-read vet and a refusal keeps both on the engine with one log', {
  plugins: [{ name: 'render-entry', tier: 'prepend', register(on) {
    on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
      await $.ui.log('render-entry')
      return next(e)
    })
  } }],
}, async ($, on) => {
  const calls: unknown[] = []
  const logs: string[] = []
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  let overlap: (() => void) | undefined
  let entries = 0
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  const bothEntered = new Promise<void>(resolve => { overlap = resolve })
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => {
    if (e.path === '/session/.cs/local/feed') return { value: 'on\n' }
    return { deny: 'ENOENT: no such file or directory' }
  })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', async ($, e) => {
    calls.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs })
    entered?.()
    await held
    return { value: { exitCode: 1, stdout: '', stderr: 'first line\nnot a trusted session\n\n', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.log', ($, e) => {
    if (e.text === 'render-entry') {
      entries++
      if (entries === 2) overlap?.()
    } else logs.push(e.text)
    return { value: undefined }
  })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine reply' }))
  const one = $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'answer', isFirstOfReply: true } })
  await started
  const two = $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'answer', isFirstOfReply: true } })
  await bothEntered
  release?.()
  const mounted = await Promise.all([one, two])
  for (const row of mounted) {
    expect((await row.find({ type: 'Text' }))?.text).toBe('engine reply')
    await row.unmount()
  }
  expect(calls).toEqual([{ argv: ['/bin/cs', '-vet-session', '/session'], timeoutMs: 10000 }])
  expect(logs).toEqual(['cs-feed: the feed is off in this session: not a trusted session'])
})

test('feed status reads a hand edit and vets an outside flip on only once', async ($, on) => {
  let file = 'off\n'
  let vets = 0
  const logs: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: file } : { deny: 'ENOENT: no such file or directory' })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => { vets++; return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  expect(await $.command.run(STATUS)).toEqual({ text: 'off · raw' })
  file = 'on\n'
  expect(await $.command.run(STATUS)).toEqual({ text: 'on · clean' })
  expect(await $.command.run(STATUS)).toEqual({ text: 'on · clean' })
  expect(vets).toBe(1)
  file = 'off\n'
  expect(await $.command.run(STATUS)).toEqual({ text: 'off · raw' })
  expect(logs).toEqual([])
})

test('feed on refuses a directory without cs local before asking for the binary or writing', async ($, on) => {
  const effects: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('fs.exists', ($, e) => { effects.push(e.path); return { value: false } })
  on('env.get', () => { effects.push('env'); return { value: undefined } })
  on('fs.write', () => { effects.push('write'); return { value: undefined } })
  expect(await $.command.run({ ...STATUS, args: 'on' })).toEqual({ text: 'cs-feed: this directory is not a cs session (no .cs/local), so nothing changed.' })
  expect(effects).toEqual(['/session/.cs/local'])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off · raw' })
})

test('a missing launch binary refuses a feed write and preserves the mirror and files', async ($, on) => {
  const writes: unknown[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'off\n' } : { deny: 'ENOENT: no such file or directory' })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: undefined }))
  on('fs.write', ($, e) => { writes.push(e); return { value: undefined } })
  expect(await $.command.run({ ...STATUS, args: 'normal' })).toEqual({ text: 'cs-feed: no feed change in this session: the launch did not say where cs is (CS_BIN)' })
  expect(writes).toEqual([])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off · raw' })
})

test('a vetted preset writes the view before the switch and redraws an on-session view change', async ($, on) => {
  const files = new Map<string, string>([['/session/.cs/local/feed', 'off\n']])
  const writes: { path: string; text: string }[] = []
  const runs: unknown[] = []
  const redraws: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => {
    const text = files.get(e.path)
    return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text }
  })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => {
    runs.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs })
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.write', ($, e) => { writes.push({ path: e.path, text: e.text }); files.set(e.path, e.text); return { value: undefined } })
  on('ui.invalidate', ($, e) => { redraws.push(e.event); return { value: undefined } })
  expect(await $.command.run({ ...STATUS, args: 'normal' })).toEqual({ text: 'Chat view: normal. each run of tool calls is one line with counts.' })
  expect(writes).toEqual([
    { path: '/session/.cs/local/feed-view', text: '{"group":false,"clear":false,"keep":true,"style":"subtle","commands":"grouped","after":"keep","hide":[]}\n' },
    { path: '/session/.cs/local/feed', text: 'on\n' },
  ])
  expect(await $.command.run(STATUS)).toEqual({ text: 'on · normal' })
  expect(await $.command.run({ ...STATUS, args: 'clean' })).toEqual({ text: "Chat view: clean. your messages, Claude's replies, and one line per turn for the work." })
  expect(await $.command.run(STATUS)).toEqual({ text: 'on · clean' })
  expect(redraws).toEqual(['ui.render', 'ui.render'])
  expect(runs).toEqual([
    { argv: ['/bin/cs', '-vet-session', '/session'], timeoutMs: 10000 },
    { argv: ['/bin/cs', '-vet-session', '/session'], timeoutMs: 10000 },
  ])
})

test('overlapping preset writes finish in command order without replacing the later view', {
  plugins: [{ name: 'command-entry', tier: 'prepend', register(on) {
    on('command.run', { command: 'feed' }, async ($, e, next) => {
      await $.ui.log(e.args)
      return next(e)
    })
  } }],
}, async ($, on) => {
  const files = new Map<string, string>([['/session/.cs/local/feed', 'off\n']])
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  let second: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  const secondEntered = new Promise<void>(resolve => { second = resolve })
  let first = true
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => {
    const text = files.get(e.path)
    return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text }
  })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('ui.log', ($, e) => { if (e.text === 'clean') second?.(); return { value: undefined } })
  on('fs.write', async ($, e) => {
    if (first) { first = false; entered?.(); await held }
    files.set(e.path, e.text)
    return { value: undefined }
  })
  const clock = mock.clock(on)
  const normal = $.command.run({ ...STATUS, args: 'normal' })
  await started
  const clean = $.command.run({ ...STATUS, args: 'clean' })
  await secondEntered
  await clock.settle()
  release?.()
  await Promise.all([normal, clean])
  expect(await $.command.run(STATUS)).toEqual({ text: 'on · clean' })
  expect(files.get('/session/.cs/local/feed-view')).toBe('{"group":true,"clear":true,"keep":false,"style":"subtle","commands":"grouped","after":"clear","hide":[]}\n')
})

test('an unknown phase uses the band observation or a running call without inventing a turn id', () => {
  const load = newLoad()
  const t = buildTranscript([{ role: 'user', text: 'work', toolUses: [] }, { role: 'assistant', text: '', toolUses: [{ tool_use_id: 'live', tool: 'Read', input: {} }] }])
  expect(openTurn(load, t)?.id).toBe('live')
  load.obs.working = false
  expect(openTurn(load, t)).toBeUndefined()
  load.obs.phase = 'live'
  const empty = buildTranscript([{ role: 'user', text: 'work', toolUses: [] }])
  expect(openTurn(load, empty)).toEqual({ steps: [], runs: [] })
  load.obs.phase = 'idle'
  expect(openTurn(load, empty)).toBeUndefined()
})

test('a prompt-door idle peer opens its first response call unless a typed prompt intervenes', () => {
  const load = newLoad()
  observePrompt(load, { door: 'prompt', peer: true, isMeta: true })
  observeTurnStart(load)
  observeResponse(load, { uuid: 'reply', text: 'working', calls: ['peer-call'] })
  expect([...load.obs.turnOpeners]).toEqual(['peer-call'])
  observeResponse(load, { uuid: 'later', text: 'done', calls: ['later-call'] })
  expect([...load.obs.turnOpeners]).toEqual(['peer-call'])
  const typed = newLoad()
  observePrompt(typed, { door: 'prompt', peer: true, isMeta: true })
  observePrompt(typed, { door: 'prompt', peer: false, isMeta: false })
  observeTurnStart(typed)
  observeResponse(typed, { uuid: 'reply', text: 'working', calls: ['typed-call'] })
  expect([...typed.obs.turnOpeners]).toEqual([])
})

test('a response anchors its text before filing the same row’s new calls', () => {
  const load = newLoad()
  observeResponse(load, { uuid: 'first', text: 'starting', calls: ['before'] })
  expect(load.obs.anchors.has('first')).toBe(false)
  observeResponse(load, { uuid: 'second', text: 'continuing', calls: ['after'] })
  expect(load.obs.anchors.get('second')).toEqual({ call: 'before', text: 'continuing', seq: 1 })
  expect(load.obs.callSincePrompt).toBe('after')
  replaceResponseText(load, 'second', 'stored text')
  expect(load.obs.anchors.get('second')).toEqual({ call: 'before', text: 'stored text', seq: 1 })
  expect([...load.obs.latestByCall]).toEqual([['before', 'second']])
})
