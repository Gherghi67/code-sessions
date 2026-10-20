// ABOUTME: Unit tests for the cs-update mod against a fake engine `$`.
// ABOUTME: Covers the span parser, the once-per-load gate (env, option, lead, tombstone), the pane body, the update key and /cs-update.
import { test, expect, beforeEach } from 'bun:test'

;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, parseSpan, stripInline, PANE, OPTION, HEARTBEAT, DONE } from '../hooks/register.tsx'

type Hook = ($: any, e: any, next: (e: any) => Promise<any>) => Promise<any>
const hooks: Record<string, Hook> = {}
const on = (event: string, a: any, b?: any) => {
  const matcher = b ? a : undefined
  const fn: Hook = b ?? a
  const narrowed = matcher?.component ?? matcher?.command
  hooks[narrowed ? `${event}:${narrowed}` : event] = fn
}

let envVars: Record<string, string | undefined>
let files: Record<string, string>
let written: Record<string, string>
let panes: { op: 'open' | 'close'; args: any }[]
let toasts: string[]
let invalidated: string[]
let runs: { argv: string[]; init: any }[]
let runResult: { exitCode: number; stdout: string; stderr: string } | Error
let commands: any[]
let sessionId: string
// Directories that exist with no file of their own, and where each path lands
// once its links are followed (as `$.fs.stat(path, { resolve: true })` answers).
let existing: Set<string>
let realPaths: Record<string, string>

// The default runner: records the call and answers with `runResult`. A test
// that swaps it in (for a run held in flight) gets it back in beforeEach.
const defaultRun = async (argv: string[], init: any) => {
  runs.push({ argv, init })
  if (runResult instanceof Error) throw runResult
  return runResult
}

// The default writer: records the call. A test that swaps it in (to fail one
// path write) gets it back in beforeEach, same as the runner above.
let defaultWrite = async (path: string, text: string) => { written[path] = text }

const $ = {
  env: { get: async (name: string) => envVars[name] },
  session: { id: async () => sessionId, cwd: async () => '/work' },
  fs: {
    read: async (path: string) => { if (path in files) return files[path]; throw new Error(`ENOENT ${path}`) },
    exists: async (path: string) => path in files || existing.has(path),
    write: (path: string, text: string) => defaultWrite(path, text),
    stat: async (path: string, options?: { resolve?: boolean }) => {
      if (!(path in realPaths)) throw new Error(`ENOENT ${path}`)
      return { kind: 'directory', size: 0, mtimeMs: 0, isLink: false, ...(options?.resolve ? { realPath: realPaths[path] } : {}) }
    },
  },
  ui: {
    resolve: async () => ({ Box: 'Box', Text: 'Text', Button: 'Button' }),
    open: async (args: any) => { panes.push({ op: 'open', args }) },
    close: async (args: any) => { panes.push({ op: 'close', args }) },
    toast: (text: string) => { toasts.push(text) },
    invalidate: (event: string) => { invalidated.push(event) },
  },
  process: { run: defaultRun as (argv: string[], init: any) => Promise<any> },
  command: { register: async (spec: any) => { commands.push(spec); return { command: spec.name } } },
}

const SPAN = `## 2026.99.3

One fix: the statusline is readable on light terminals.

### Fixes

- **Statusline: readable.** The \`chiptext\` token was **wrong** in [two places](https://example.com/x).
  A continuation line.

## 2026.99.2

One change: the locked-session menu is single-keypress.

### Changed

- **Menu: keypress.** Cancel stays the default.
`

const start = () => hooks['session.start']($, { cwd: '/work' }, async () => 'started')
const opens = () => panes.filter(p => p.op === 'open')
// A `.map()` inside JSX lands as an array child, so both walkers flatten
// arrays before reading an element's children.
function texts(tree: any): string[] {
  if (typeof tree === 'string') return [tree]
  if (Array.isArray(tree)) return tree.flatMap(texts)
  if (!tree || typeof tree !== 'object') return []
  return (tree.children ?? []).flatMap(texts)
}
function buttons(tree: any): any[] {
  if (Array.isArray(tree)) return tree.flatMap(buttons)
  if (!tree || typeof tree !== 'object') return []
  if (tree.type === 'Button') return [tree]
  return (tree.children ?? []).flatMap(buttons)
}
function headings(tree: any): any[] {
  if (Array.isArray(tree)) return tree.flatMap(headings)
  if (!tree || typeof tree !== 'object') return []
  if (tree.type === 'Text' && tree.props.bold && tree.props.color) return [tree]
  return (tree.children ?? []).flatMap(headings)
}
const draw = () => hooks['ui.render:Pane']($, { requestId: PANE }, async () => 'other')

function load(options: Record<string, unknown> = {}) {
  for (const k of Object.keys(hooks)) delete hooks[k]
  register(on as any, { [OPTION]: true, ...options } as any)
}

beforeEach(() => {
  envVars = { CS_UPDATE_AVAILABLE: '2026.99.3', CS_BIN: '/opt/cs/bin/cs', HOME: '/home/u' }
  files = {
    '/work/.cs/local/state': 'claude_session_color: red\nclaude_session_id: uuid-lead\n',
    '/home/u/.cache/cs/update-notes-full-2026.99.3': SPAN,
  }
  written = {}; panes = []; toasts = []; invalidated = []; runs = []; commands = []
  // /work sits under the default sessions root by its own name.
  existing = new Set(['/work/.cs/local'])
  realPaths = { '/work': '/work', '/home/u/.claude-sessions/work': '/work' }
  runResult = { exitCode: 0, stdout: 'ok', stderr: '' }
  ;($ as any).process.run = defaultRun
  ;($ as any).env.get = async (name: string) => envVars[name]
  defaultWrite = async (path: string, text: string) => { written[path] = text }
  sessionId = 'uuid-lead'
  load()
})

test('stripInline drops links, bold and code marks and keeps the words', () => {
  expect(stripInline('The `chiptext` token was **wrong** in [two places](https://example.com/x).'))
    .toBe('The chiptext token was wrong in two places.')
})

test('stripInline strips an unpaired ** and an unpaired backtick too', () => {
  expect(stripInline('a **b `c')).toBe('a b c')
})

test('parseSpan yields one section per version with prose and bullets, headings and blanks dropped', () => {
  const sections = parseSpan(SPAN)
  expect(sections.map(s => s.version)).toEqual(['2026.99.3', '2026.99.2'])
  expect(sections[0].lines).toEqual([
    'One fix: the statusline is readable on light terminals.',
    '- Statusline: readable. The chiptext token was wrong in two places.',
    '  A continuation line.',
  ])
  expect(sections[1].lines).toEqual([
    'One change: the locked-session menu is single-keypress.',
    '- Menu: keypress. Cancel stays the default.',
  ])
})

test('parseSpan of an empty file is no sections', () => {
  expect(parseSpan('')).toEqual([])
})

test('session.start opens the pane once per load and writes the heartbeat', async () => {
  expect(await start()).toBe('started')
  expect(opens()).toHaveLength(1)
  expect(opens()[0].args).toMatchObject({ id: PANE, title: 'cs 2026.99.3 is available', closeOnEscape: true, focus: true })
  expect(written['/work/' + HEARTBEAT]).toMatch(/^\d{4}-/)
  await start()
  expect(opens()).toHaveLength(1)
})

// While git tracks the session's control files, cs -vet-session refuses and
// the mod writes nothing into .cs/local: no heartbeat, no DONE marker, and a
// stale marker is left as git has it.
// The installer runs alone, apart from the -vet-session asks around it.
const updateRuns = () => runs.filter(r => r.argv[1] === '-update')

const vetRefusing = () => {
  ;($ as any).process.run = async (argv: string[], init: any) => {
    runs.push({ argv, init })
    if (argv[1] === '-vet-session') return { exitCode: 1, stdout: '', stderr: 'Error: .cs/local/state is tracked in git\n' }
    return runResult
  }
}

test('a session whose control files git tracks gets no heartbeat', async () => {
  vetRefusing()
  await start()
  expect(written['/work/' + HEARTBEAT]).toBeUndefined()
  expect(runs.map(r => r.argv)).toContainEqual(['/opt/cs/bin/cs', '-vet-session', '/work'])
})

test('while git tracks the control files, a stale DONE marker is left as git has it', async () => {
  vetRefusing()
  files['/work/' + DONE] = '2026.99.1\nUpdate finished. Takes effect on your next launch.\n'
  await start()
  expect(written['/work/' + DONE]).toBeUndefined()
})

test('while git tracks the control files, a finished update writes no DONE marker', async () => {
  vetRefusing()
  await start()
  await buttons(await draw())[0].props.onPress()
  expect(texts(await draw()).join('\n')).toContain('Update finished. Takes effect on your next launch.')
  expect(written['/work/' + DONE]).toBeUndefined()
})

// The sessions root names a session; nothing inside a directory can, since a
// cloned repository may carry any file under .cs/, .cs/local included, and
// still pass cs -vet-session. A directory the root does not name gets no
// write from this mod: no heartbeat, no DONE marker, no tombstone.
test('a directory with .cs/local that the sessions root does not name gets no heartbeat', async () => {
  existing = new Set(['/clone/.cs/local'])
  realPaths = { '/clone': '/clone' }
  await hooks['session.start']($, { cwd: '/clone' }, async () => 'started')
  expect(written).toEqual({})
})

test('a root entry of the same name that is another directory does not make the cwd a session', async () => {
  realPaths = { '/work': '/work', '/home/u/.claude-sessions/work': '/elsewhere' }
  await start()
  expect(written['/work/' + HEARTBEAT]).toBeUndefined()
})

test('CS_SESSIONS_ROOT names the sessions root', async () => {
  envVars.CS_SESSIONS_ROOT = '/roots'
  realPaths = { '/work': '/work', '/roots/work': '/work' }
  await start()
  expect(written['/work/' + HEARTBEAT]).toMatch(/^\d{4}-/)
  realPaths = { '/work': '/work', '/home/u/.claude-sessions/work': '/work' }
  written = {}
  await start()
  expect(written['/work/' + HEARTBEAT]).toBeUndefined()
})

test('an adopted session is named by the session_name its state records', async () => {
  files['/work/.cs/local/state'] = 'session_name: alias\nclaude_session_id: uuid-lead\n'
  realPaths = { '/work': '/work', '/home/u/.claude-sessions/alias': '/work' }
  await start()
  expect(written['/work/' + HEARTBEAT]).toMatch(/^\d{4}-/)
})

test('in a directory the sessions root does not name, a stale DONE marker is left as it is', async () => {
  realPaths = { '/work': '/work' }
  files['/work/' + DONE] = '2026.99.1\nUpdate finished. Takes effect on your next launch.\n'
  await start()
  await draw()
  expect(written).toEqual({})
})

// The gate is asked again at the write, so a root entry gone while the pane
// is open (the session removed or its link moved) takes no DONE marker.
test('in a directory the sessions root no longer names, a finished update writes no DONE marker', async () => {
  await start()
  realPaths = { '/work': '/work' }
  written = {}
  await buttons(await draw())[0].props.onPress()
  expect(texts(await draw()).join('\n')).toContain('Update finished. Takes effect on your next launch.')
  expect(written).toEqual({})
})

test('no pending version, no pane, no toast', async () => {
  delete envVars.CS_UPDATE_AVAILABLE
  await start()
  expect(opens()).toHaveLength(0)
  expect(toasts).toEqual([])
})

test('the option off skips the launch pane', async () => {
  load({ [OPTION]: false })
  await start()
  expect(opens()).toHaveLength(0)
})

test('a teammate (a session that is not the one cs launched) gets no pane', async () => {
  sessionId = 'uuid-teammate'
  await start()
  expect(opens()).toHaveLength(0)
})

test('a quoted id in the state file still names the lead', async () => {
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: "uuid-lead"\n'
  await start()
  expect(opens()).toHaveLength(1)
})

test('no state file (not a cs session) means no pane', async () => {
  delete files['/work/.cs/local/state']
  await start()
  expect(opens()).toHaveLength(0)
})

test('the pane draws the title, every version in the session colour, its lines, and the two keys', async () => {
  await start()
  const tree = await draw()
  const words = texts(tree).join('\n')
  // A lone pane draws no title of its own, so the body carries it.
  expect(words).toContain('cs 2026.99.3 is available')
  expect(headings(tree).map(t => [t.props.color, texts(t).join('')])).toEqual([['red', '2026.99.3'], ['red', '2026.99.2']])
  expect(words).toContain('One fix: the statusline is readable on light terminals.')
  expect(words).toContain('- Menu: keypress. Cancel stays the default.')
  // A continuation line hangs under its bullet: it is indented, not run on.
  const cont = texts(tree).find(t => t.includes('A continuation line.'))
  expect(cont).toBe('  A continuation line.')
  const keys = buttons(tree)
  expect(keys.map(b => b.props.hotkey)).toEqual(['1'])
  expect(keys[0].props.label).toBe('update now')
  expect(words).toContain('Esc: later')
  expect(words).toContain('Installs in place; the new files take effect on your next launch.')
  // The pane does not scroll, so the key row sits above the notes body,
  // never below where a long changelog span could push it off the fold.
  const list = texts(tree)
  const keyRow = list.findIndex(t => t.includes('Esc: later'))
  const notesStart = list.findIndex(t => t.includes('One fix: the statusline is readable on light terminals.'))
  expect(keyRow).toBeGreaterThanOrEqual(0)
  expect(notesStart).toBeGreaterThanOrEqual(0)
  expect(keyRow).toBeLessThan(notesStart)
})

test('a tombstone (empty notes file) still opens the pane with the fallback body', async () => {
  files['/home/u/.cache/cs/update-notes-full-2026.99.3'] = ''
  await start()
  expect(opens()).toHaveLength(1)
  const words = texts(await draw()).join('\n')
  expect(words).toContain('Release notes could not be fetched at launch; the update is 2026.99.3.')
  expect(buttons(await draw())).toHaveLength(1)
})

test('a missing notes file reads as the tombstone', async () => {
  delete files['/home/u/.cache/cs/update-notes-full-2026.99.3']
  await start()
  expect(opens()).toHaveLength(1)
  expect(texts(await draw()).join('\n')).toContain('could not be fetched')
})

test('CS_CACHE_DIR names the notes cache ahead of HOME', async () => {
  envVars.CS_CACHE_DIR = '/profile/.cache/cs'
  files['/profile/.cache/cs/update-notes-full-2026.99.3'] = SPAN
  delete files['/home/u/.cache/cs/update-notes-full-2026.99.3']
  await start()
  expect(opens()).toHaveLength(1)
  expect(texts(await draw()).join('\n')).toContain('One fix: the statusline is readable on light terminals.')
})

test('another pane id is not the mod\'s to draw', async () => {
  await start()
  expect(await hooks['ui.render:Pane']($, { requestId: 'someone-else' }, async () => 'other')).toBe('other')
})

test('a directory opted out of cs (.cs/local/disabled) gets no pane', async () => {
  files['/work/.cs/local/disabled'] = ''
  await start()
  expect(opens()).toHaveLength(0)
})

test('1 runs cs -update once, by the exported path, with a ten-minute timeout, and reports the install', async () => {
  await start()
  // The key is gone from the redraw once pressed, so the callback is kept
  // and pressed twice; the run is held in flight so the second press lands
  // while the first is running.
  let release!: (v: any) => void
  ;($ as any).process.run = async (argv: string[], init: any) => {
    if (argv[1] === '-vet-session') return { exitCode: 0, stdout: '', stderr: '' }
    runs.push({ argv, init }); return new Promise(r => { release = r })
  }
  const press = buttons(await draw())[0].props.onPress
  const first = press()
  const second = press()
  await Promise.resolve()
  release({ exitCode: 0, stdout: '', stderr: '' })
  await first; await second
  expect(updateRuns()).toHaveLength(1)
  expect(updateRuns()[0].argv).toEqual(['/opt/cs/bin/cs', '-update'])
  expect(updateRuns()[0].init).toMatchObject({ timeoutMs: 600000 })
  const words = texts(await draw()).join('\n')
  // Version-neutral: cs -update installs whatever is latest when pressed,
  // which may be newer than the launch saw.
  expect(words).toContain('Update finished. Takes effect on your next launch.')
  expect(buttons(await draw())).toHaveLength(0)
  expect(invalidated).toContain('ui.render')
})

test('a second press returns at the running guard before any lookup', async () => {
  await start()
  let giveBin!: (v: any) => void
  // Only the press's own lookup is held; the -vet-session ask after the run answers at once.
  let held = false
  ;($ as any).env.get = async (name: string) => {
    if (name !== 'CS_BIN' || held) return envVars[name]
    held = true
    return new Promise(r => { giveBin = r })
  }
  const press = buttons(await draw())[0].props.onPress
  const a = press(); const b = press()
  await Promise.resolve()
  giveBin('/opt/cs/bin/cs')
  await a; await b
  expect(updateRuns()).toHaveLength(1)
})

test('while the update runs the pane says so and hides the key', async () => {
  await start()
  let release!: (v: any) => void
  ;($ as any).process.run = async (argv: string[], init: any) => {
    if (argv[1] === '-vet-session') return { exitCode: 0, stdout: '', stderr: '' }
    runs.push({ argv, init }); return new Promise(r => { release = r })
  }
  const pressed = buttons(await draw())[0].props.onPress()
  await Promise.resolve()
  const words = texts(await draw()).join('\n')
  expect(words).toContain('updating')
  expect(buttons(await draw())).toHaveLength(0)
  release({ exitCode: 0, stdout: '', stderr: '' })
  await pressed
})

test('a non-zero exit shows the last stderr lines and keeps the key for another try', async () => {
  await start()
  runResult = { exitCode: 1, stdout: '', stderr: 'a\nb\nc\nd\ne\nf\nchecksum mismatch\n' }
  await buttons(await draw())[0].props.onPress()
  const words = texts(await draw()).join('\n')
  expect(words).toContain('cs -update exited 1')
  expect(words).toContain('checksum mismatch')
  expect(words).not.toContain('\na\n')
  expect(buttons(await draw())).toHaveLength(1)
})

test('a run that cannot start shows the rejection', async () => {
  await start()
  runResult = new Error('spawn ENOENT')
  await buttons(await draw())[0].props.onPress()
  expect(texts(await draw()).join('\n')).toContain('spawn ENOENT')
})

test('no CS_BIN means the key says so instead of running nothing', async () => {
  delete envVars.CS_BIN
  await start()
  await buttons(await draw())[0].props.onPress()
  expect(runs).toHaveLength(0)
  expect(texts(await draw()).join('\n')).toContain('cs -update')
})

test('the mod registers /cs-update at load', async () => {
  await start()
  expect(commands.map(c => c.name)).toEqual(['cs-update'])
})

const runCommand = () => hooks['command.run:cs-update']($, { command: 'cs-update', args: '', cwd: '/work' }, async () => ({ text: 'unhandled' }))

test('/cs-update reopens the pane after a dismiss, and with the option off, and answers the command', async () => {
  load({ [OPTION]: false })
  await start()
  expect(opens()).toHaveLength(0)
  expect(await runCommand()).toEqual({ text: 'Release notes are in the side pane.' })
  expect(opens()).toHaveLength(1)
  expect(texts(await draw()).join('\n')).toContain('2026.99.3')
})

test('/cs-update with nothing pending says so as its output and opens nothing', async () => {
  delete envVars.CS_UPDATE_AVAILABLE
  await start()
  expect(await runCommand()).toEqual({ text: 'This launch found no newer cs; the check runs again at the next launch.' })
  expect(opens()).toHaveLength(0)
})

for (const pending of [undefined, '2026.99.3']) {
  test(`/cs-update in the fork gives the manual workflow with ${pending ? 'an inherited pending version' : 'no pending version'}`, async () => {
    envVars.CODE_SESSIONS_HOME = '/profile/code-sessions'
    envVars.CS_UPDATE_AVAILABLE = pending
    const result = await runCommand()
    expect(result.text).toContain('scripts/sync-upstream.py catch-up')
    expect(result.text).toContain('then `sh setup.sh`')
    expect(result.text).toContain('https://github.com/hex/claude-sessions/releases')
    expect(result.text).not.toContain('found no newer cs')
    expect(result.text).not.toContain('side pane')
    expect(opens()).toHaveLength(0)
    expect(runs).toHaveLength(0)
  })
}

test('/cs-update in a fork teammate still belongs to the lead conversation', async () => {
  envVars.CODE_SESSIONS_HOME = '/profile/code-sessions'
  sessionId = 'uuid-teammate'
  expect(await runCommand()).toEqual({ text: 'The release-notes pane belongs to the conversation cs launched.' })
  expect(opens()).toHaveLength(0)
  expect(runs).toHaveLength(0)
})

test('/cs-update in a teammate opens nothing', async () => {
  sessionId = 'uuid-teammate'
  await start()
  expect(await runCommand()).toEqual({ text: 'The release-notes pane belongs to the conversation cs launched.' })
  expect(opens()).toHaveLength(0)
})

test('a directory with .cs/local that the sessions root does not name shows no pane and /cs-update does nothing there', async () => {
  realPaths = { '/work': '/work' }
  await start()
  expect(opens()).toHaveLength(0)
  expect(await runCommand()).toEqual({ text: 'The release-notes pane belongs to the conversation cs launched.' })
  expect(opens()).toHaveLength(0)
  expect(written).toEqual({})
})

test('/cs-update after a reload, with no session.start or render between, restores the finished pane instead of offering the update again', async () => {
  files['/work/' + DONE] = '2026.99.3\nUpdate finished. Takes effect on your next launch.\n'
  expect(await runCommand()).toEqual({ text: 'Release notes are in the side pane.' })
  expect(opens()).toHaveLength(1)
  const words = texts(await draw()).join('\n')
  expect(words).toContain('Update finished. Takes effect on your next launch.')
  expect(buttons(await draw())).toHaveLength(0)
})

test('a clean exit writes the DONE marker with the version and the outcome line', async () => {
  await start()
  await buttons(await draw())[0].props.onPress()
  expect(written['/work/' + DONE]).toBe('2026.99.3\nUpdate finished. Takes effect on your next launch.\n')
})

test('a reload restores the finished pane from the DONE marker, in done, with no key', async () => {
  await start()
  await buttons(await draw())[0].props.onPress()
  const marker = written['/work/' + DONE]
  files['/work/' + DONE] = marker
  panes = []
  load()
  await start()
  expect(opens()).toHaveLength(1)
  const words = texts(await draw()).join('\n')
  expect(words).toContain('Update finished. Takes effect on your next launch.')
  expect(words).toContain('Esc: close')
  expect(buttons(await draw())).toHaveLength(0)
})

test('a Pane render with no prior session.start restores the finished pane from the marker on its own (the reload redraw path)', async () => {
  files['/work/' + DONE] = '2026.99.3\nUpdate finished. Takes effect on your next launch.\n'
  const tree = await draw()
  const words = texts(tree).join('\n')
  expect(words).toContain('Update finished. Takes effect on your next launch.')
  expect(words).toContain('Esc: close')
  expect(buttons(tree)).toHaveLength(0)
  expect(opens()).toHaveLength(1)
})

test('a Pane render with no prior session.start and a stale marker falls through to next(e) and empties the marker', async () => {
  files['/work/' + DONE] = '2026.99.1\nUpdate finished. Takes effect on your next launch.\n'
  expect(await draw()).toBe('other')
  expect(written['/work/' + DONE]).toBe('')
  expect(opens()).toHaveLength(0)
})

test('a marker present but no CS_UPDATE_AVAILABLE opens nothing and empties the marker', async () => {
  files['/work/' + DONE] = '2026.99.3\nUpdate finished. Takes effect on your next launch.\n'
  delete envVars.CS_UPDATE_AVAILABLE
  await start()
  expect(opens()).toHaveLength(0)
  expect(written['/work/' + DONE]).toBe('')
})

test('a marker naming a version no longer pending is stale: cleared, and the idle pane opens for the newly pending one', async () => {
  files['/work/' + DONE] = '2026.99.1\nUpdate finished. Takes effect on your next launch.\n'
  await start()
  expect(written['/work/' + DONE]).toBe('')
  expect(opens()).toHaveLength(1)
  const tree = await draw()
  const words = texts(tree).join('\n')
  expect(words).toContain('cs 2026.99.3 is available')
  expect(words).not.toContain('Update finished')
  expect(buttons(tree)).toHaveLength(1)
})

test('a failed write to the DONE marker toasts and the pane still shows done', async () => {
  await start()
  defaultWrite = async (path: string, text: string) => {
    if (path === '/work/' + DONE) throw new Error('disk full')
    written[path] = text
  }
  await buttons(await draw())[0].props.onPress()
  expect(toasts).toEqual(['cs-update: could not record the finished update: disk full'])
  const words = texts(await draw()).join('\n')
  expect(words).toContain('Update finished. Takes effect on your next launch.')
})

// A pane redrawn after a reload asks the lead gate before it restores the
// marker, so a directory the sessions root does not name gets no pane back.
test('in a directory the sessions root does not name, a pane redrawn after a reload is not restored from a fresh DONE marker', async () => {
  realPaths = { '/work': '/work' }
  files['/work/' + DONE] = '2026.99.3\nUpdate finished. Takes effect on your next launch.\n'
  await draw()
  expect(opens()).toHaveLength(0)
  expect(written).toEqual({})
})

test('in a directory the sessions root does not name, session start never spawns cs -vet-session', async () => {
  existing = new Set(['/clone/.cs/local'])
  realPaths = { '/clone': '/clone' }
  await hooks['session.start']($, { cwd: '/clone' }, async () => 'started')
  expect(runs).toHaveLength(0)
})
