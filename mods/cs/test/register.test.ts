// ABOUTME: Unit tests for the cs mod against a fake engine `$`.
// ABOUTME: Covers the band's gate (crit, working, survey), the three presses and the wrap key's two-press guard, the armed handoff and its next-step toast, the heartbeat, /queue, and the /finish toasts and gate word.
import { test, expect, beforeEach } from 'bun:test'
import { readFileSync } from 'node:fs'

// The plugin realm provides `h` and `Fragment` as globals; the test does the same.
;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, buildBandEntries, parsePrompts, RAIL_TEXT_CHARS, DEFAULT_PERCENT, GRACE_SECONDS, NEXT_STEP_CHARS, WRAP_QUESTION, WRAP_YES, QUEUE_START, QUEUE_COMPACT, QUEUE_KICK, QUEUE_MODE_QUESTION, QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS, nextStepLine, isUnconsumed } from '../hooks/register.tsx'

type Hook = ($: any, e: any, next: (e: any) => Promise<any>) => Promise<any>
const hooks: Record<string, Hook> = {}
const on = (event: string, a: any, b?: any) => {
  const matcher = b ? a : undefined
  const fn: Hook = b ?? a
  const narrowed = matcher?.component ?? matcher?.command ?? matcher?.skill
  hooks[narrowed ? `${event}:${narrowed}` : event] = fn
}

let percent: number | undefined
let filled: any[]
let ran: any[]
let written: Record<string, string>
let existing: Set<string>
let files: Record<string, string>
let sessionId: string
let envVars: Record<string, string | undefined>
// The conversation's working directory, and where each path lands as `$.fs.stat` resolves it
// (a path absent here does not exist).
let cwdPath: string
let realPaths: Record<string, string>
let timers: { ms: number; fn: () => void; kind: 'after' | 'every'; cancelled: boolean }[]
let invalidated: string[]
let toasts: string[]
let logs: string[]
let asks: { question: string; options: any }[]
// Every pane call the mod makes: it opens, closes and lists none.
let panes: { op: 'open' | 'close' | 'panes'; args?: any }[]
// What the person does with the next dialog: a label, or a rejection (dismissed, or a `-p` run).
let answer: string | Error
// What the person answers to the queue's "how should the tasks run" question.
let modeAnswer: string | Error
// What `$.process.run` was asked to run, and what it answers with (or rejects with).
let runs: { argv: string[]; init: any }[]
let runResult: { exitCode: number; stdout: string; stderr: string } | Error
// Answers for the next runs in order, ahead of runResult; empty means runResult answers.
let nextRuns: ({ exitCode: number; stdout: string; stderr: string } | Error)[]
// What `$.prompt.submit` was handed.
let submitted: any[]
// How many process runs had happened when `$.session.compact` was called, and what it answers with (or rejects with).
let compactedAt: number[]
let compactResult: any
let commands: any[]
let availableCommands: { name: string; source: string; plugin?: string }[]
let sessionValues: Map<string, { value: boolean; version: number }>
// What `$.ui.scroll` was asked, and what it answers; the paths `$.fs.read` was given; each file's mtime.
let scrolls: any[]
let scrollResult: any
let reads: string[]
let mtimes: Record<string, number>
// The clock `$.clock.now` reads, and the pids `kill -0` finds alive.
let nowMs: number
let livePids: Set<string>
const timer = (kind: 'after' | 'every') => (ms: number, fn: () => void) => {
  const t = { ms, fn, kind, cancelled: false }
  timers.push(t)
  return { cancel: () => { t.cancelled = true } }
}
const $ = {
  env: { get: async (name: string) => envVars[name] },
  session: {
    usage: async () => ({ context: { percent } }),
    cwd: async () => cwdPath,
    id: async () => sessionId,
    compact: async () => {
      compactedAt.push(runs.length)
      if (compactResult instanceof Error) throw compactResult
      return compactResult
    },
  },
  prompt: {
    fill: async (args: any) => { filled.push(args); return { isFilled: true } },
    submit: async (args: any) => { submitted.push(args); return {} },
  },
  command: {
    list: async () => availableCommands,
    run: async (args: any) => { ran.push(args); return { text: '' } },
    register: async (spec: any) => { commands.push(spec); return { command: spec.name } },
  },
  state: {
    get: async (ref: { plugin: string; key: string }): Promise<{ value?: boolean; version: number }> =>
      sessionValues.get(`${sessionId}:${ref.plugin}:${ref.key}`) ?? { version: 0 },
    set: async (ref: { plugin: string; key: string }, value: boolean, options?: { ifVersion: number }) => {
      const key = `${sessionId}:${ref.plugin}:${ref.key}`
      const version = sessionValues.get(key)?.version ?? 0
      if (options !== undefined && options.ifVersion !== version) return { isSet: false, version }
      sessionValues.set(key, { value, version: version + 1 })
      return { isSet: true, version: version + 1 }
    },
  },
  process: {
    run: async (argv: string[], init: any) => {
      if (argv[0] === 'kill' && argv[1] === '-0') return { exitCode: livePids.has(argv[2]) ? 0 : 1, stdout: '', stderr: '' }
      runs.push({ argv, init })
      const r = nextRuns.length > 0 ? nextRuns.shift()! : runResult
      if (r instanceof Error) throw r
      return r
    },
  },
  ui: {
    resolve: async () => ({ Box: 'Box', Text: 'Text', Button: 'Button' }),
    invalidate: (event: string) => { invalidated.push(event) },
    toast: (text: string) => { toasts.push(text) },
    scroll: async (args: any) => { scrolls.push(args); return scrollResult },
    log: (text: string) => { logs.push(text) },
    open: async (args: any) => { panes.push({ op: 'open', args }) },
    close: async (args: any) => { panes.push({ op: 'close', args }) },
    panes: async () => { panes.push({ op: 'panes' }); return [] },
    ask: async (question: string, options: any) => {
      asks.push({ question, options })
      const reply = question === QUEUE_MODE_QUESTION ? modeAnswer : answer
      if (reply instanceof Error) throw reply
      return reply
    },
  },
  clock: { after: timer('after'), every: timer('every'), now: async () => nowMs },
  fs: {
    write: async (path: string, text: string) => { written[path] = text; files[path] = text },
    exists: async (path: string) => existing.has(path) || path in files,
    read: async (path: string) => { reads.push(path); if (path in files) return files[path]; throw new Error(`ENOENT ${path}`) },
    // A directory is listed from the files under it, a deeper file standing
    // for the directory that holds it; one with none is absent.
    list: async (path: string) => {
      const prefix = `${path.replace(/\/+$/, '')}/`
      const under = Object.keys(files).filter(k => k.startsWith(prefix)).map(k => k.slice(prefix.length))
      if (under.length === 0) throw new Error(`ENOENT ${path}`)
      const names = [...new Set(under.map(rest => rest.split('/')[0]))]
      return names.map(name => under.includes(name)
        ? { name, kind: 'file', size: files[prefix + name].length, isLink: false }
        : { name, kind: 'directory', size: 0, isLink: false })
    },
    stat: async (path: string, options?: { resolve?: boolean }) => {
      if (path in files) return { kind: 'file', size: files[path].length, mtimeMs: mtimes[path] ?? 0, isLink: false }
      if (!(path in realPaths)) throw new Error(`ENOENT ${path}`)
      return { kind: 'directory', size: 0, mtimeMs: 0, isLink: false, ...(options?.resolve ? { realPath: realPaths[path] } : {}) }
    },
  },
}

// The options the engine hands register, with the prompt bars turned on, as
// most tests here are about them; plugin.json's defaults leave them off.
const OPTIONS = { bandPrompts: true, bandPrompt: 'latest', bandBars: 10 }
// The band following the reader's scroll, and drawing every bar that fits.
const READING = { ...OPTIONS, bandPrompt: 'read' }
const UNCAPPED = { ...OPTIONS, bandBars: 100 }
const DRAWN = { type: 'Survey', props: {}, children: [] }
const band = (props: Partial<{ isWorking: boolean; hasSurvey: boolean; bodyColumns: number }> = {}, surface = 'terminal') =>
  hooks['ui.render:AbovePrompt']($, { surface, props: { isWorking: false, hasSurvey: false, bodyColumns: 110, ...props } }, async () => DRAWN)

function buttons(tree: any): any[] {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(buttons)
  if (tree.type === 'Button') return [tree]
  return (tree.children ?? []).flatMap(buttons)
}
const findButton = (tree: any) => buttons(tree)[0]

beforeEach(() => {
  for (const k of Object.keys(hooks)) delete hooks[k]
  percent = undefined; filled = []; ran = []; written = {}; existing = new Set(['/work/.cs/local'])
  timers = []; invalidated = []; toasts = []; logs = []; asks = []; answer = WRAP_YES; modeAnswer = QUEUE_HERE; panes = []
  runs = []; runResult = { exitCode: 0, stdout: '', stderr: '' }; nextRuns = []; submitted = []; commands = []
  compactedAt = []; compactResult = { messages: [] }
  availableCommands = []; sessionValues = new Map()
  scrolls = []; scrollResult = {}; reads = []; mtimes = {}
  nowMs = 1_800_000_000_000; livePids = new Set()
  // The default fixture is the lead conversation of a cs session.
  sessionId = 'uuid-lead'
  // /work sits under the default sessions root by its own name, and the launch
  // said where cs is, as every cs launch does.
  envVars = { HOME: '/home', CS_BIN: '/opt/cs/bin/cs' }
  cwdPath = '/work'
  realPaths = { '/work': '/work', '/home/.claude-sessions/work': '/work' }
  files = { '/work/.cs/local/state': 'claude_session_color: red\nclaude_session_id: uuid-lead\n' }
  register(on as any, OPTIONS)
})

test('the default threshold is the statusline warn band', () => {
  expect(DEFAULT_PERCENT).toBe(40)
})

test('CS_STATUSLINE_CTX_WARN moves the band with the bar', async () => {
  envVars.CS_STATUSLINE_CTX_WARN = '50'
  percent = 49
  expect(await band()).toBe(DRAWN)
  percent = 50
  expect(findButton(await band())).toBeDefined()
  envVars.CS_ROTATE_BUTTON_CTX = '10'
  percent = 10
  expect(findButton(await band())).toBeDefined()
})

test('below the threshold the band passes the drawn tree through untouched', async () => {
  percent = 39
  expect(await band()).toBe(DRAWN)
})

test('CS_ROTATE_BUTTON_CTX in the process environment sets the threshold', async () => {
  envVars.CS_ROTATE_BUTTON_CTX = '55'
  percent = 54
  expect(await band()).toBe(DRAWN)
  percent = 55
  expect(findButton(await band())).toBeDefined()
})

test('an unusable CS_ROTATE_BUTTON_CTX falls back to the default', async () => {
  envVars.CS_ROTATE_BUTTON_CTX = 'soon'
  percent = 39
  expect(await band()).toBe(DRAWN)
  percent = 40
  expect(findButton(await band())).toBeDefined()
})

test('a quoted claude_session_id in state still names the lead', async () => {
  files['/work/.cs/local/state'] = 'claude_session_id: "uuid-lead"  \n'
  percent = 40
  expect(findButton(await band())).toBeDefined()
})

test('at the threshold the band adds the rotate key on the strip:jump1 action, first, beneath what was drawn', async () => {
  percent = 40
  const tree = await band()
  expect(tree).not.toBe(DRAWN)
  expect(buttons(tree)).toHaveLength(2)
  const button = findButton(tree)
  expect(button.props.action).toBe('strip:jump1')
  // No bare digit: a hotkey fires from an empty composer, where a digit typed
  // as an answer to a numbered question belongs (measured live).
  expect(button.props.hotkey).toBeUndefined()
  expect(button.props.plain).toBe(true)
  expect(button.props.label).toBe('rotate')
  const json1 = JSON.stringify(tree)
  expect(json1).toContain('"Survey"')
  expect(json1).not.toContain('borderStyle')
})

// The engine draws a Button with no hotkey as its label alone, so the band
// spells the key itself: the chord the person's keybindings.json gives the
// Button's action, as written there, and nothing when no chord presses it.
const KEYS = '/home/.claude/keybindings.json'
const bindKeys = (bindings: Record<string, string | null>, context = 'Global') => {
  files[KEYS] = JSON.stringify({ bindings: [{ context, bindings }] })
}
const words = (tree: any): string[] => texts(tree).map(textOf)
// The words drawn while no pointer rests on the band: a hover card's stay hidden.
const restingWords = (tree: any): string[] => {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(restingWords)
  if (tree.props?.display === 'none') return []
  if (tree.type === 'Text') return [textOf(tree)]
  return (tree.children ?? []).flatMap(restingWords)
}

// Chords that share a prefix (`ctrl+x 1`, `ctrl+x 2`) spell the prefix once,
// dim, and each Button's own key beside its label: `ctrl+x  1 rotate  ·  2 wrap`.
test('the band spells a shared chord prefix once and each Button\'s own key beside it', async () => {
  envVars.HOME = '/home'
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2', 'ctrl+x r': 'command:rotate' })
  percent = 40
  expect(words(await band())).toEqual(['\u25cf', 'ctrl+x', '1', '  \u00b7  ', '2'])
  arm()
  expect(words(await band())).toEqual(['\u25cf', 'ctrl+x', '1'])
})

test('chords with different prefixes are spelled whole, as slice 1 drew them', async () => {
  envVars.HOME = '/home'
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+w 2': 'strip:jump2' })
  percent = 40
  expect(words(await band())).toEqual(['\u25cf', 'ctrl+x 1', '  \u00b7  ', 'ctrl+w 2'])
})

test('a chord bound elsewhere is spelled as the person wrote it', async () => {
  envVars.HOME = '/home'
  bindKeys({ 'Ctrl+K 9': 'strip:jump1' })
  percent = 40
  const drawn = words(await band())
  expect(drawn).toContain('Ctrl+K 9')
  expect(drawn.join(' ')).not.toContain('ctrl+x')
})

test('with no chord bound the band draws no key, and the Buttons stay', async () => {
  envVars.HOME = '/home'
  percent = 40
  const cases: (() => void)[] = [
    () => { delete files[KEYS] },
    () => { files[KEYS] = '{ not json' },
    () => { files[KEYS] = '[]' },
    () => bindKeys({ 'ctrl+x 1': null, 'ctrl+x 2': 'command:wrap' }),
    () => bindKeys({ 'ctrl+x 1': 'strip:jump1' }, 'Transcript'),
  ]
  for (const arrange of cases) {
    arrange()
    const tree = await band()
    expect(buttons(tree)).toHaveLength(2)
    expect(words(tree).join(' ')).not.toContain('+')
  }
})

test('CLAUDE_CONFIG_DIR names the keybindings.json the band reads, as it does for Claude Code', async () => {
  envVars.HOME = '/home'
  envVars.CLAUDE_CONFIG_DIR = '/cfg'
  bindKeys({ 'ctrl+x 1': 'strip:jump1' })
  percent = 40
  expect(words(await band()).join(' ')).not.toContain('ctrl+x 1')
  files['/cfg/keybindings.json'] = files[KEYS]
  expect(words(await band())).toContain('ctrl+x 1')
})

test('the band draws no context gauge: the status bar already carries it', async () => {
  percent = 71
  const tree = JSON.stringify(await band())
  expect(tree).not.toContain('ctx')
  expect(tree).not.toContain('71%')
})

// Claude Code draws its footer (the status bar and the mode line) two columns
// in from the prompt's rule (measured on 2.1.292); the band starts in the same
// column so the twins line up.
const boxes = (tree: any): any[] => {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(boxes)
  const own = tree.type === 'Box' ? [tree] : []
  return [...own, ...(tree.children ?? []).flatMap(boxes)]
}

test('the band starts in the status bar\'s column, two in from the prompt\'s rule', async () => {
  percent = 40
  const tree = await band()
  expect(boxes(tree).find((b: any) => b.props.key === 'cs-rotate-band').props.marginLeft).toBe(2)
})

// The chord is the one pressable thing a word has, so it alone wears the
// session colour; the labels are the engine's plain Buttons and the
// separators dim.
test('the keys are in the session colour, the prefix and the separators dim, and nothing else but the mark is coloured', async () => {
  envVars.HOME = '/home'
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  percent = 40
  const tree = await band()
  for (const key of ['1', '2']) {
    expect(texts(tree).find((t: any) => textOf(t) === key).props).toMatchObject({ bold: true, color: 'rgb(220,38,38)' })
  }
  expect(texts(tree).find((t: any) => textOf(t) === 'ctrl+x').props).toEqual({ dimColor: true })
  const separators = texts(tree).filter((t: any) => textOf(t) === '  \u00b7  ')
  expect(separators).toHaveLength(1)
  expect(separators[0].props).toEqual({ dimColor: true })
  expect(texts(tree).filter((t: any) => t.props.color !== undefined).map(textOf)).toEqual(['\u25cf', '1', '2'])
})

test('the band draws no rule: the mark stands where the line starts, its first word after it', async () => {
  envVars.HOME = '/home'
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  percent = 40
  const tree = await band()
  expect(JSON.stringify(tree)).not.toContain('\u258c')
  expect(words(tree).slice(0, 2)).toEqual(['\u25cf', 'ctrl+x'])
})

test('with no palette colour the keys are bold in the terminal\'s ink, and only the mark is coloured', async () => {
  envVars.HOME = '/home'
  files['/work/.cs/local/state'] = 'claude_session_color: teal\nclaude_session_id: uuid-lead\n'
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  percent = 40
  const tree = await band()
  expect(texts(tree).filter((t: any) => t.props.color !== undefined).map(textOf)).toEqual(['\u25cf'])
})

// With a handoff armed and its count running, the line reads
// `/clear in 20s  ·  ctrl+x  1 /clear now`: the count first, then the key.
test('armed and counting, the countdown is the first word after the mark, a separator between it and the key', async () => {
  envVars.HOME = '/home'
  bindKeys({ 'ctrl+x 1': 'strip:jump1' })
  await startGrace()
  const tree = await band()
  expect(words(tree)).toEqual(['\u25cf', `/clear in ${GRACE_SECONDS}s`, '  \u00b7  ', 'ctrl+x', '1'])
  const json = JSON.stringify(tree)
  expect(json.indexOf(`/clear in ${GRACE_SECONDS}s`)).toBeLessThan(json.indexOf('/clear now'))
  expect(buttons(tree).map((b: any) => b.props.label)).toEqual(['/clear now'])
})

// One thin line, a blank line above it: no fill, whatever the terminal
// background measures, no chip, no caps, no border, no Claude mark. The key
// stays: it is the band's identity.
test('the band is one thin line: a keyed box with no fill, chip, caps, border, hover or Claude mark', async () => {
  envVars.CS_TERM_BG_RGB = '252;247;229'
  envVars.CS_STATUSLINE_CAPS = '1'
  percent = 40
  const tree = JSON.stringify(await band())
  expect(tree).toContain('"marginTop":1')
  expect(tree).toContain('"key":"cs-rotate-band"')
  expect(tree).not.toContain('backgroundColor')
  expect(tree).not.toContain('"cs"')
  expect(tree).not.toContain('\ue0b6')
  expect(tree).not.toContain('\ue0b4')
  expect(tree).not.toContain('borderStyle')
  expect(tree).not.toContain('borderColor')
  expect(tree).not.toContain('hover')
  expect(tree).not.toContain('\u2733')
  expect(tree).not.toContain('"claude"')
})


test('while a turn runs the button is hidden', async () => {
  percent = 90
  expect(await band({ isWorking: true })).toBe(DRAWN)
})

test('while a survey holds the band the hook yields', async () => {
  percent = 90
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
})

test('an unknown percentage draws nothing', async () => {
  percent = undefined
  expect(await band()).toBe(DRAWN)
})

test('a press runs the rotate skill and fills nothing', async () => {
  percent = 80
  const button = findButton(await band())
  await button.props.onPress()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
  expect(filled).toEqual([])
})

// The skill ends by arming a marker in .cs/local, so the press asks cs first,
// as the clear button and the forced /rotate do.
test('while git tracks a control file, a press runs no rotation', async () => {
  percent = 80
  runResult = tracked
  await findButton(await band()).props.onPress()
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(ran).toEqual([])
})

test('outside a cs session the band draws nothing at crit', async () => {
  percent = 90
  existing = new Set(); files = {}
  expect(await band()).toBe(DRAWN)
})

test('a session opted out with .cs/local/disabled gets no button', async () => {
  percent = 90
  existing.add('/work/.cs/local/disabled')
  expect(await band()).toBe(DRAWN)
})

test('a teammate conversation (not the one .cs/local/state names) gets no button', async () => {
  percent = 90
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
})

test('with no state file to name the lead the band draws nothing', async () => {
  percent = 90
  files = {}
  expect(await band()).toBe(DRAWN)
})

const MARKER = '/work/.cs/local/pending-handoff'
const HANDOFF = '/work/.cs/handoffs/2026-09-15-next-step.md'
const UNCONSUMED = '---\nparent: uuid-lead\nstatus: unconsumed\n---\n\n## 1. Next Step\n'
// Armed the way the rotate skill leaves it: an unconsumed handoff, then the marker.
const arm = () => { files[HANDOFF] = UNCONSUMED; files[MARKER] = '2026-09-15-next-step.md\n' }

test('an armed handoff turns the button into the clear button, whatever the context', async () => {
  arm()
  for (const p of [undefined, 3, 90]) {
    percent = p
    const tree = await band()
    expect(buttons(tree)).toHaveLength(1)
    const button = findButton(tree)
    expect(button.props.action).toBe('strip:jump1')
    expect(button.props.hotkey).toBeUndefined()
    expect(button.props.plain).toBe(true)
    expect(findButton(tree).props.label).toBe('/clear now')
    const json = JSON.stringify(tree)
    expect(json).not.toContain('borderStyle')
    expect(json).not.toContain('borderColor')
    expect(json).not.toContain('undefined')
    expect(json).not.toContain('ctx')
  }
})

test('pressing the clear button runs /clear and fills nothing', async () => {
  arm(); percent = 3
  await findButton(await band()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(filled).toEqual([])
})

test('the rotate press never clears', async () => {
  percent = 80
  await findButton(await band()).props.onPress()
  expect(ran).not.toContainEqual({ command: 'clear', args: '' })
})

test('an armed handoff is still lead-only and yields to a running turn', async () => {
  arm(); percent = 90
  expect(await band({ isWorking: true })).toBe(DRAWN)
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
})

test('a marker naming a handoff that is gone, consumed, or outside the store does not arm', async () => {
  percent = 39
  arm(); delete files[HANDOFF]
  expect(await band()).toBe(DRAWN)
  arm(); files[HANDOFF] = UNCONSUMED.replace('status: unconsumed', 'status: consumed')
  expect(await band()).toBe(DRAWN)
  arm(); files[HANDOFF] = '## no frontmatter\nstatus: unconsumed\n'
  expect(await band()).toBe(DRAWN)
  arm(); files[MARKER] = '../local/state\n'
  expect(await band()).toBe(DRAWN)
  percent = 40
  expect(findButton(await band()).props.label).toBe('rotate')
})

// cs loads only a handoff whose file name is plain (letters, digits and ._@-,
// at most 160 characters), so a marker naming any other, even an unconsumed
// handoff that exists, arms nothing: the /clear would load nothing.
test('a marker naming a handoff whose name is not plain does not arm', async () => {
  percent = 39
  for (const name of ['2026-09-15-e\x1b[1mb\x07.md', '2026-09-15 next.md', 'a'.repeat(158) + '.md']) {
    files = { ...files, [`/work/.cs/handoffs/${name}`]: UNCONSUMED, [MARKER]: `${name}\n` }
    expect(await band()).toBe(DRAWN)
  }
  const longest = 'a'.repeat(157) + '.md'
  files = { ...files, [`/work/.cs/handoffs/${longest}`]: UNCONSUMED, [MARKER]: `${longest}\n` }
  expect(findButton(await band()).props.label).toBe('/clear now')
})

// The marker is read as the SessionStart hook reads it (tr -d '[:space:]' in
// the C locale): ASCII whitespace is dropped and nothing else, so a marker
// whose name starts with U+FEFF, U+00A0 or U+2028 names a file the hook will
// not load, and arms nothing.
test('a marker is read as the hook reads it: only ASCII whitespace is dropped', async () => {
  percent = 39
  for (const lead of ['﻿', ' ', ' ']) {
    arm(); files[MARKER] = `${lead}2026-09-15-next-step.md\n`
    expect(await band()).toBe(DRAWN)
  }
  arm(); files[MARKER] = '\t 2026-09-15-next-step.md\r\n'
  expect(findButton(await band()).props.label).toBe('/clear now')
})

// An encrypted session keeps the marker and its handoffs behind .cs/private.
const PRIVATE_MARKER = '/work/.cs/private/pending-handoff'
const PRIVATE_HANDOFF = '/work/.cs/private/handoffs/2026-09-15-next-step.md'

test('an encrypted session arms from the marker and handoff behind .cs/private', async () => {
  files[PRIVATE_HANDOFF] = UNCONSUMED; files[PRIVATE_MARKER] = '2026-09-15-next-step.md\n'
  percent = 3
  expect(findButton(await band()).props.label).toBe('/clear now')
})

test('a private marker never arms from the plaintext handoff store', async () => {
  files[HANDOFF] = UNCONSUMED; files[PRIVATE_MARKER] = '2026-09-15-next-step.md\n'
  percent = 39
  expect(await band()).toBe(DRAWN)
})

// cs judges whether it trusts the session's control files: a marker git tracks
// (a pull brought it in) names a rotation the SessionStart hook refuses, so it
// arms nothing, and the band says why, once per answer.
const VETTED = { exitCode: 0, stdout: '', stderr: '' }
const TRACKED = "Error: .cs/local/pending-handoff is tracked in git (per-actor state must stay local). Fix with: git -C /work --literal-pathspecs rm -r --cached -- .cs/local && git -C /work commit -m 'stop tracking .cs/local'"
const tracked = { exitCode: 1, stdout: '', stderr: `${TRACKED}\n` }

test('the band asks cs nothing as it draws, however often it redraws', async () => {
  arm(); percent = 3
  for (let i = 0; i < 5; i++) expect(findButton(await band()).props.label).toBe('/clear now')
  expect(runs).toEqual([])
})

test('pressing the clear button asks cs about the session, and a tracked control file clears nothing', async () => {
  arm(); percent = 3
  runResult = tracked
  await findButton(await band()).props.onPress()
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(ran).toEqual([])
  expect(toasts).toEqual([`cs: no rotation in this session: ${TRACKED}`])
  // the band then draws the session as unarmed (below the threshold: nothing),
  // and the same refusal at the next turn's end is not said again
  expect(await band()).toBe(DRAWN)
  envVars.CS_ROTATE_FORCE_CTX = '70'
  await turnComplete()
  expect(runs).toHaveLength(2)
  expect(toasts).toHaveLength(1)
})

test('once cs trusts the session again, the next press clears', async () => {
  arm(); percent = 3
  runResult = tracked
  await findButton(await band()).props.onPress()
  runResult = VETTED
  envVars.CS_ROTATE_FORCE_CTX = '70'; percent = 80
  await turnComplete()
  expect(findButton(await band()).props.label).toBe('/clear now')
  await findButton(await band()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a turn ending with a tracked control file starts no countdown and forces no /rotate', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  runResult = tracked
  await turnComplete()
  await fireAfter()
  expect(timers.filter(t => t.kind === 'every')).toEqual([])
  expect(ran).toEqual([])
  expect(Object.keys(written)).toEqual([])
  // with no handoff armed, the same turn's end past the threshold forces nothing either
  delete files[MARKER]
  await turnComplete()
  await fireAfter()
  expect(ran).toEqual([])
  expect(Object.keys(written)).toEqual([])
})

test('a control file git starts tracking during the count clears nothing at zero', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  runResult = tracked
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([])
})

test('a press while cs is still answering, then the count reaching zero, clears once', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const zero = ticker()!
  const run = $.process.run
  let answer: (r: any) => void = () => {}
  let asked: () => void = () => {}
  const reached = new Promise<void>(r => { asked = r })
  $.process.run = async (argv: string[], init: any) => {
    $.process.run = run
    runs.push({ argv, init })
    asked()
    return new Promise(r => { answer = r })
  }
  try {
    const press = findButton(await band()).props.onPress()
    await reached
    await zero.fn()
    answer(VETTED)
    await press
  } finally {
    $.process.run = run
  }
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('with the forcing off, a prompt after a refusal asks cs afresh at the next press', async () => {
  envVars.CS_ROTATE_FORCE_CTX = 'off'
  arm(); percent = 3
  runResult = tracked
  await findButton(await band()).props.onPress()
  expect(await band()).toBe(DRAWN)
  runResult = VETTED
  await promptSubmit()
  expect(findButton(await band()).props.label).toBe('/clear now')
  await findButton(await band()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('when cs cannot answer, a press clears nothing and the band says why', async () => {
  arm(); percent = 3
  delete envVars.CS_BIN
  await findButton(await band()).props.onPress()
  expect(runs).toHaveLength(0)
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = new Error('spawn ENOENT')
  envVars.CS_ROTATE_FORCE_CTX = '70'; percent = 80
  await turnComplete()
  expect(ran).toEqual([])
  expect(toasts).toEqual([
    'cs: no rotation in this session: the launch did not say where cs is (CS_BIN)',
    'cs: no rotation in this session: cs -vet-session did not run: spawn ENOENT',
  ])
})

test('an empty marker names no handoff, so the band behaves as unarmed', async () => {
  files[MARKER] = '\n'
  percent = 39
  expect(await band()).toBe(DRAWN)
  percent = 40
  expect(findButton(await band()).props.label).toBe('rotate')
})

test('session.start writes a heartbeat under the session meta dir', async () => {
  const r = await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(r).toEqual({ cwd: '/work' })
  const text = written['/work/.cs/local/cs.heartbeat']
  expect(text).toMatch(/^\d{4}-\d{2}-\d{2}T.*Z\n$/)
})

// While git tracks the session's control files the mod adds nothing there: cs
// is asked before the heartbeat lands, and its refusal is said once.
test('a session whose control files git tracks gets no heartbeat', async () => {
  runResult = tracked
  await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(written).toEqual({})
  expect(toasts).toEqual([`cs: no rotation in this session: ${TRACKED}`])
})

test('outside a cs session no heartbeat is written', async () => {
  await hooks['session.start']($, { cwd: '/plain', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

// The sessions root names a session; nothing inside a directory can, since a
// cloned repository may carry any file under .cs/. The cwd is a cs session
// when <root>/<its name> is the cwd itself.
test('a directory with .cs/local that the sessions root does not name gets no heartbeat', async () => {
  cwdPath = '/clone'
  existing = new Set(['/clone/.cs/local'])
  realPaths = { '/clone': '/clone' }
  await hooks['session.start']($, { cwd: '/clone', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

test('a root entry of the same name that is another directory does not make the cwd a session', async () => {
  cwdPath = '/clone/work'
  existing = new Set(['/clone/work/.cs/local'])
  realPaths = { '/clone/work': '/clone/work', '/home/.claude-sessions/work': '/work' }
  await hooks['session.start']($, { cwd: '/clone/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

test('CS_SESSIONS_ROOT names the sessions root', async () => {
  envVars.CS_SESSIONS_ROOT = '/roots'
  realPaths = { '/work': '/work', '/roots/work': '/work' }
  await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual(['/work/.cs/local/cs.heartbeat'])
  realPaths = { '/work': '/work', '/home/.claude-sessions/work': '/work' }
  written = {}
  await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

test('an adopted session is named by the session_name its state records, and the root entry must be the cwd', async () => {
  cwdPath = '/code/project'
  existing = new Set(['/code/project/.cs/local'])
  files = { '/code/project/.cs/local/state': 'session_name: alias\nclaude_session_id: uuid-lead\n' }
  realPaths = { '/code/project': '/code/project', '/home/.claude-sessions/alias': '/code/project' }
  await hooks['session.start']($, { cwd: '/code/project', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual(['/code/project/.cs/local/cs.heartbeat'])
  realPaths['/home/.claude-sessions/alias'] = '/elsewhere'
  written = {}
  await hooks['session.start']($, { cwd: '/code/project', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

test('the lead of a directory the sessions root does not name gets no button', async () => {
  percent = 90
  realPaths = { '/work': '/work' }
  expect(await band()).toBe(DRAWN)
})

// A turn's end, the way the engine reports it: answered on the main loop unless said otherwise.
const turnComplete = (e: Partial<{ reason: string; agentId: string }> = {}) =>
  hooks['turn.complete']($, { reason: 'answer', answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', ...e }, async () => ({ text: 'ok' }))
// The pending `after` timers, run the way the clock would run them.
const fireAfter = async () => { for (const t of timers.filter(t => t.kind === 'after' && !t.cancelled)) { t.cancelled = true; await t.fn() } }

test('with CS_ROTATE_FORCE_CTX set, a turn ending past it schedules /rotate from a timer, not from the hook', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 70
  await turnComplete()
  expect(ran).toEqual([])
  expect(timers.map(t => t.kind)).toEqual(['after'])
  await fireAfter()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

test('without CS_ROTATE_FORCE_CTX a turn ending past the 80% default forces a rotation', async () => {
  percent = 80
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  await fireAfter()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

test('under the default a turn ending below 80% forces nothing', async () => {
  percent = 79
  await turnComplete()
  expect(timers).toEqual([])
  expect(ran).toEqual([])
})

test('CS_ROTATE_FORCE_CTX=off, and 0, turn the forcing off entirely', async () => {
  for (const value of ['off', 'OFF', '0']) {
    envVars.CS_ROTATE_FORCE_CTX = value
    percent = 100
    await turnComplete()
    expect(timers).toEqual([])
    expect(ran).toEqual([])
  }
})

test('below the force threshold, or with an unusable value, a turn ending forces nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 69
  await turnComplete()
  // An unusable value is the default, not "off": a typo must not quietly
  // disable a rotation the person is relying on. 100 is past 80, so it forces.
  envVars.CS_ROTATE_FORCE_CTX = 'critical'
  percent = 100
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
})

test('a whole number outside 1..100 is the default 80, not a threshold no turn can reach', async () => {
  for (const value of ['101', '150', '999']) {
    envVars.CS_ROTATE_FORCE_CTX = value
    percent = 79
    await turnComplete()
    expect(timers).toEqual([])
  }
  percent = 80
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  await fireAfter()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

test('a forced rotation runs once per conversation, and a failed /rotate is not retried', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 80
  await turnComplete()
  expect(written['/work/.cs/local/cs.forced']).toBe('uuid-lead\n')
  await turnComplete(); await turnComplete()
  expect(timers).toHaveLength(1)
  // the marker is written before the timer is scheduled, so a rejected run stays rejected
  $.command.run = async () => { throw new Error('unknown command') }
  await fireAfter()
  expect(toasts).toEqual(['cs: /rotate did not run: Error: unknown command'])
  await turnComplete()
  expect(timers).toHaveLength(1)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  // a marker from an earlier conversation of the session does not count
  files['/work/.cs/local/cs.forced'] ='uuid-earlier\n'
  await turnComplete()
  expect(timers).toHaveLength(2)
})

test('a subagent\'s turn, an aborted, errored or refused one, a teammate, or an unarmed non-cs directory forces nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 90
  await turnComplete({ agentId: 'agent-1' })
  await turnComplete({ reason: 'aborted' })
  await turnComplete({ reason: 'error' })
  await turnComplete({ reason: 'refusal' })
  sessionId = 'uuid-teammate'
  await turnComplete()
  sessionId = 'uuid-lead'; existing = new Set(); files = {}
  await turnComplete()
  expect(timers).toEqual([])
  expect(Object.keys(written)).toEqual([])
})

// The rotate button runs /rotate for the person in one key, so that rotation
// must not stop to ask either: before it runs, the press writes the
// conversation's id to .cs/local/cs.pressed, which cs -archive-tasks plan
// reads as a forced rotation. The end of the next main-loop turn empties it,
// whatever ended that turn, so a /rotate typed later in the conversation asks
// as a manual one does; a run the engine refuses empties it at once.
const PRESSED = '/work/.cs/local/cs.pressed'

test('a press names the conversation in cs.pressed before /rotate runs, and the end of the main loop\'s turn empties it', async () => {
  percent = 80
  let atRun: string | undefined
  const run = $.command.run
  $.command.run = async (args: any) => { atRun = files[PRESSED]; ran.push(args); return { text: '' } }
  try {
    await findButton(await band()).props.onPress()
  } finally {
    $.command.run = run
  }
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
  expect(atRun).toBe('uuid-lead\n')
  await turnComplete({ agentId: 'agent-1' })
  expect(files[PRESSED]).toBe('uuid-lead\n')
  await turnComplete({ reason: 'aborted' })
  expect(files[PRESSED]).toBe('')
})

test('a press whose /rotate the engine refuses empties cs.pressed at once', async () => {
  percent = 80
  const run = $.command.run
  $.command.run = async () => { throw new Error('unknown command') }
  let refused: unknown
  try {
    await findButton(await band()).props.onPress()
  } catch (err) {
    refused = err
  } finally {
    $.command.run = run
  }
  expect(String(refused)).toBe('Error: unknown command')
  expect(files[PRESSED]).toBe('')
})

test('the end of a turn leaves a press marker naming another conversation, and one git tracks, as they are', async () => {
  files[PRESSED] = 'uuid-earlier\n'
  await turnComplete()
  expect(runs).toEqual([])
  expect(files[PRESSED]).toBe('uuid-earlier\n')
  files[PRESSED] = 'uuid-lead\n'
  runResult = tracked
  await turnComplete()
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(files[PRESSED]).toBe('uuid-lead\n')
  expect(written).toEqual({})
})

// A marker that cannot be emptied would make a later typed /rotate read as
// pressed, so the failure is said; the turn's end goes on to what follows it.
test('a press marker the turn end cannot empty is said, and the turn end goes on', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 80
  files[PRESSED] = 'uuid-lead\n'
  const write = $.fs.write
  $.fs.write = async (path: string, text: string) => {
    if (path === PRESSED) throw new Error('EACCES')
    return write(path, text)
  }
  let result: any
  try {
    result = await turnComplete()
  } finally {
    $.fs.write = write
  }
  expect(toasts).toEqual(['cs: could not empty .cs/local/cs.pressed: Error: EACCES'])
  expect(files[PRESSED]).toBe('uuid-lead\n')
  expect(result).toEqual({ text: 'ok' })
  expect(timers.map(t => t.kind)).toEqual(['after'])
})

test('a turn ending past the force threshold with a handoff already armed runs no second /rotate', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 90
  arm()
  await turnComplete()
  await fireAfter()
  expect(ran).toEqual([])
})

// The countdown's ticker, and one tick of it as the clock would run it.
const ticker = () => timers.find(t => t.kind === 'every' && !t.cancelled)
const tick = async (n = 1) => { for (let i = 0; i < n; i++) await ticker()!.fn() }
const promptSubmit = (text = 'keep going') =>
  hooks['prompt.submit']($, { text, wait: false, origin: { kind: 'composer' } }, async (e) => ({ text: e.text }))

test('with the handoff armed and force on, a turn ending starts a countdown the band shows, one redraw a second', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  expect(ticker()?.ms).toBe(1000)
  expect(GRACE_SECONDS).toBe(20)
  expect(JSON.stringify(await band())).toContain(`/clear in ${GRACE_SECONDS}s`)
  await tick(3)
  expect(invalidated).toEqual(['ui.render', 'ui.render', 'ui.render'])
  expect(JSON.stringify(await band())).toContain(`/clear in ${GRACE_SECONDS - 3}s`)
  expect(ran).toEqual([])
  // one countdown at a time: another turn ending does not start a second
  await turnComplete()
  expect(timers.filter(t => t.kind === 'every')).toHaveLength(1)
})

test('at zero the countdown runs /clear, once, and stops ticking', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  const t = ticker()!
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await band())).not.toContain('/clear in')
})

test('a prompt entering the session stops the countdown and passes through', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(2)
  const t = ticker()!
  expect(await promptSubmit('one more thing')).toEqual({ text: 'one more thing' })
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await band())).not.toContain('/clear in')
  expect(ran).toEqual([])
  // the next turn ending restarts it from the top
  await turnComplete()
  expect(JSON.stringify(await band())).toContain(`/clear in ${GRACE_SECONDS}s`)
})

test('pressing the clear button mid-countdown stops the ticker before it clears', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(2)
  const t = ticker()!
  await findButton(await band()).props.onPress()
  expect(t.cancelled).toBe(true)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a countdown reaching zero while a turn runs or a survey holds the band clears nothing and stops', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  for (const props of [{ isWorking: true }, { hasSurvey: true }]) {
    await band()
    await turnComplete()
    const t = ticker()!
    await band(props)
    await tick(GRACE_SECONDS)
    expect(ran).toEqual([])
    expect(t.cancelled).toBe(true)
  }
})

test('a countdown reaching zero re-checks the handoff: one consumed meanwhile clears nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  files[HANDOFF] = UNCONSUMED.replace('status: unconsumed', 'status: consumed')
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([])
})

test('with the forcing off, or outside the lead, an armed handoff starts no countdown and prompt.submit passes through', async () => {
  envVars.CS_ROTATE_FORCE_CTX = 'off'
  arm(); percent = 80
  await turnComplete()
  envVars.CS_ROTATE_FORCE_CTX = '70'
  sessionId = 'uuid-teammate'
  await turnComplete()
  expect(timers).toEqual([])
  expect(toasts).toEqual([])
  expect(await promptSubmit()).toEqual({ text: 'keep going' })
})

test('a prompt arriving while the zero tick is still checking the handoff wins: nothing clears', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const zero = tick()
  await promptSubmit('wait, one more thing')
  await zero
  expect(ran).toEqual([])
  // and a press racing the zero tick clears once, not twice
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const button = findButton(await band())
  const zero2 = tick()
  await button.props.onPress()
  await zero2
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a /clear run from anywhere else ends the countdown, so no timer outlives the conversation', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  const t = ticker()!
  const e = { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }
  expect(await hooks['command.run:clear']($, e, async () => ({ text: '' }))).toEqual({ text: '' })
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await band())).not.toContain('/clear in')
})

test('a rejected /clear at zero shows a toast and clears nothing else', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  $.command.run = async () => { throw new Error('no session') }
  await tick(GRACE_SECONDS)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['cs: /clear did not run: Error: no session'])
  expect(ran).toEqual([])
})

// The SessionStart hook's own rule (_handoff_is_unconsumed): the frontmatter
// must close, and the status must sit inside it.
test('isUnconsumed follows the hook: unclosed frontmatter, or a status after it, is not armed', () => {
  expect(isUnconsumed('---\nstatus: unconsumed\n---\n')).toBe(true)
  expect(isUnconsumed('---\nstatus: unconsumed\n')).toBe(false)
  expect(isUnconsumed('---\nparent: x\n---\nstatus: unconsumed\n')).toBe(false)
  expect(isUnconsumed('---\nstatus: consumed\n---\n')).toBe(false)
  expect(isUnconsumed('')).toBe(false)
})

test('a tick that lands while the zero tick is still reading does not push the count negative or clear twice', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const t = ticker()!
  const first = t.fn()
  const second = t.fn()
  await first; await second
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(JSON.stringify(await band())).not.toContain('/clear in -')
})


test('a conversation met at load is forced whatever it started at; one born of a /clear that starts past the threshold is not, and says so once', async () => {
  // resumed (or launched) already past the line: forced, as asked
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
  // the successor wakes past the line: that is the loop, and it stops here
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 71
  await turnComplete(); await turnComplete()
  expect(timers).toHaveLength(1)
  expect(toasts).toEqual(['cs: CS_ROTATE_FORCE_CTX=70 is below this conversation\'s starting context (71%); not forcing a rotation'])
  // a teammate past the line is not the lead: no rotation, and no toast about one
  sessionId = 'uuid-teammate'
  percent = 90
  await turnComplete()
  expect(timers).toHaveLength(1)
  expect(toasts).toHaveLength(1)
  // a successor that starts below and works its way past is forced as usual
  sessionId = 'uuid-later'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-later\n'
  percent = 30
  await turnComplete()
  percent = 90
  await turnComplete()
  expect(timers).toHaveLength(2)
  // a reload forgets: the conversation it meets next is adopted, whatever it reads
  register(on as any, OPTIONS)
  sessionId = 'uuid-reloaded'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-reloaded\n'
  percent = 95
  await turnComplete()
  expect(timers).toHaveLength(3)
})

const clearRun = () =>
  hooks['command.run:clear']($, { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }, async () => ({ text: '' }))

test('the first conversation leaves its session color to the launch', async () => {
  await band()
  await band()
  await turnComplete()
  expect(ran).toEqual([])
})

test('a conversation without a session color runs no color command', async () => {
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-lead\n'
  await band()
  await clearRun()
  sessionId = 'uuid-next'
  await band()
  expect(ran).toEqual([])
})

test('a conversation with an unknown session color runs no color command', async () => {
  await band()
  for (const color of ['mauve', 'constructor']) {
    files['/work/.cs/local/state'] = `claude_session_color: ${color}\nclaude_session_id: uuid-lead\n`
    await clearRun()
    sessionId = `uuid-${color}`
    await band()
  }
  expect(ran).toEqual([])
  expect(logs).toEqual([])
})

test('a conversation outside a cs session runs no color command', async () => {
  delete realPaths['/home/.claude-sessions/work']
  await band()
  await clearRun()
  sessionId = 'uuid-next'
  await band()
  expect(ran).toEqual([])
})

test('a conversation after /clear reapplies the session color once', async () => {
  await band()
  await clearRun()
  sessionId = 'uuid-next'
  expect(await band()).toBe(DRAWN)
  await band()
  await turnComplete()
  expect(ran).toEqual([{ command: 'color', args: 'red' }])
})

test('a /clear after a plugin reload reapplies the session color once', async () => {
  await band()
  // The harness captures hooks by matcher without the engine's On overloads.
  register(on as any, OPTIONS)
  await clearRun()
  sessionId = 'uuid-next'
  await band()
  await band()
  expect(ran).toEqual([{ command: 'color', args: 'red' }])
})

test('a refused session color leaves the drawn tree intact and logs once', async () => {
  await band()
  await clearRun()
  sessionId = 'uuid-next'
  const run = $.command.run
  $.command.run = async (args) => { ran.push(args); throw new Error('command refused') }
  try {
    expect(await band()).toBe(DRAWN)
    expect(await band()).toBe(DRAWN)
  } finally {
    $.command.run = run
  }
  expect(ran).toEqual([{ command: 'color', args: 'red' }])
  expect(logs).toEqual(['cs: /color red did not run: Error: command refused'])
})

test('a pending session color leaves rendering and running-turn guards responsive', async () => {
  arm(); percent = 80
  await band()
  await turnComplete()
  sessionId = 'uuid-fork'
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: uuid-fork\n'
  const run = $.command.run
  $.command.run = (args) => {
    if (args.command !== 'color') return run(args)
    ran.push(args)
    return new Promise(() => {})
  }
  try {
    const rendered = await Promise.race([band({ isWorking: true }), settle().then(() => 'render blocked')])
    expect(rendered).toBe(DRAWN)
    await tick(GRACE_SECONDS)
    expect(ran).toEqual([{ command: 'color', args: 'red' }])
    runResult = LISTED
    answer = QUEUE_START
    await queue('')
    await settle()
    expect(runs.map(x => x.argv[2])).toEqual(['/work', 'list', 'start'])
    expect(submitted).toEqual([])
    expect(logs).toEqual([])
  } finally {
    $.command.run = run
  }
})

test('a successor that starts past the threshold still gets the countdown once the person arms a handoff themselves', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  arm()
  await turnComplete()
  expect(ticker()).toBeDefined()
})

test('a /clear before any turn ends still marks the next conversation as /clear-born: past the threshold it is not forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  expect(toasts).toHaveLength(1)
})

test('a new conversation id with no /clear seen in this process is a resume: adopted and forced as asked', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  sessionId = 'uuid-resumed'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-resumed\n'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

test('the /clear the mod runs itself marks the successor as /clear-born too, so a wake past the threshold is not forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  await findButton(await band()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-next\n' }
  sessionId = 'uuid-next'
  percent = 75
  await turnComplete()
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toEqual([])
  expect(toasts).toHaveLength(1)
})

test('a /clear whose successor never answers does not mark a later /resume as /clear-born: the band drawn in the successor consumes the birth', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-wake'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-wake\n'
  await band()
  sessionId = 'uuid-resumed'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-resumed\n'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

test('resuming a conversation that was once judged adopts it afresh: the old judgment is dropped', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-judged'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-judged\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  sessionId = 'uuid-other'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-other\n'
  percent = 20
  await turnComplete()
  sessionId = 'uuid-judged'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-judged\n'
  percent = 75
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toHaveLength(1)
})

test('a /clear the mod runs itself that is rejected leaves no birth behind: a later /resume past the threshold is forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  $.command.run = async () => { throw new Error('no session') }
  await tick(GRACE_SECONDS)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['cs: /clear did not run: Error: no session'])
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-resumed\n' }
  sessionId = 'uuid-resumed'
  percent = 72
  await turnComplete()
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toHaveLength(1)
  expect(toasts).toHaveLength(1)
})

test('a typed /clear that the engine refuses leaves no birth behind either', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  const e = { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }
  await expect(hooks['command.run:clear']($, e, async () => { throw new Error('refused') })).rejects.toThrow('refused')
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-resumed\n' }
  sessionId = 'uuid-resumed'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

// The wrap key: a second button on the strip:jump2 action that runs /wrap. It
// draws only where the band draws unarmed; once a handoff is armed the band's
// one job is the /clear.
const wrapButton = (tree: any) => buttons(tree).find((b: any) => b.props.action === 'strip:jump2')
test('at the threshold the band adds a second button on strip:jump2 that reads as the wrap key, after the rotate key', async () => {
  percent = 40
  const tree = await band()
  expect(buttons(tree)).toHaveLength(2)
  expect(buttons(tree)[0].props.action).toBe('strip:jump1')
  const button = wrapButton(tree)
  expect(button.props.hotkey).toBeUndefined()
  expect(button.props.plain).toBe(true)
  expect(wrapButton(tree).props.label).toBe('wrap')
})

// One key, then the engine's own dialog. /wrap replaces .cs/summary.md and
// runs two Opus passes, so the press asks rather than acts; a held `2` repeats
// on keydown (contract) and each repeat only re-opens the same question.
test('pressing 2 asks before /wrap, and only the yes runs it', async () => {
  percent = 40
  answer = WRAP_YES
  await wrapButton(await band()).props.onPress()
  expect(asks).toEqual([{ question: WRAP_QUESTION, options: { header: 'Wrap', options: [WRAP_YES, 'Not now'] } }])
  expect(ran).toEqual([{ command: 'wrap', args: '' }])

  answer = 'Not now'
  await wrapButton(await band()).props.onPress()
  expect(asks).toHaveLength(2)
  expect(ran).toHaveLength(1)

  // dismissed, or a `-p` run with nobody to ask: nothing runs and nothing is said
  answer = new Error('dismissed')
  await wrapButton(await band()).props.onPress()
  expect(ran).toHaveLength(1)
  expect(toasts).toEqual([])
})

test('a /wrap the answer runs that the engine refuses is said once', async () => {
  percent = 40
  answer = WRAP_YES
  $.command.run = async () => { throw new Error('no session') }
  await wrapButton(await band()).props.onPress()
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['cs: /wrap did not run: Error: no session'])
  expect(ran).toEqual([])
})

// A wrap that finished leaves nothing for the key to do until the conversation
// moves on. /wrap's last pass writes .cs/local/wrapped naming the conversation
// it ran in; the band draws the rotate key alone while the marker names this
// one, and the next turn that starts from a prompt empties it. A continuation
// (a turn started with no prompt, as a Stop hook's feedback starts one) does not.
// A summary written any other way proves nothing.
const WRAPPED = '/work/.cs/local/wrapped'
const turnStart = (text: string) => hooks['turn.start']($, { text, turnId: `turn-${text.length}` }, async (e: any) => ({ turnId: e.turnId }))

test('a finished wrap hides the wrap key until a turn starts from a prompt', async () => {
  percent = 40
  await turnStart('please wrap up')
  files[WRAPPED] = 'uuid-lead\n'
  expect(wrapButton(await band())).toBeUndefined()
  expect(findButton(await band()).props.action).toBe('strip:jump1')

  await turnStart('')
  expect(wrapButton(await band())).toBeUndefined()

  await turnStart('next thing')
  expect(files[WRAPPED]).toBe('')
  expect(wrapButton(await band())).toBeDefined()
})

// Work queued behind the wrap starts its own turn, and a second wrap that fails
// a pass writes no marker of its own: either way the first wrap's marker is gone.
test('queued work, or a second wrap that fails, brings the key back', async () => {
  percent = 40
  files[WRAPPED] = 'uuid-lead\n'
  await turnStart('and then fix the tests')
  expect(wrapButton(await band())).toBeDefined()

  files[WRAPPED] = 'uuid-lead\n'
  await turnStart('/wrap')
  expect(wrapButton(await band())).toBeDefined()
})

test('while git tracks the control files, a prompt leaves the wrap marker as git has it', async () => {
  percent = 40
  files[WRAPPED] = 'uuid-lead\n'
  runResult = tracked
  await turnStart('next thing')
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(written).toEqual({})
  expect(files[WRAPPED]).toBe('uuid-lead\n')
})

test('a summary with no wrap marker, or a marker naming another conversation, keeps the wrap key', async () => {
  percent = 40
  files['/work/.cs/summary.md'] = '# Session Summary\n'
  expect(wrapButton(await band())).toBeDefined()
  files[WRAPPED] = 'uuid-teammate\n'
  expect(wrapButton(await band())).toBeDefined()
  await turnStart('x')
  expect(files[WRAPPED]).toBe('uuid-teammate\n')
})

test('an armed handoff draws the clear key alone: no wrap key', async () => {
  arm(); percent = 90
  expect(buttons(await band())).toHaveLength(1)
  expect(wrapButton(await band())).toBeUndefined()
})

// The engine refuses a tree with a Button under an inline element (measured
// on 2.1.273: "Button inside an inline element; drawing the engine's own"),
// and the whole band vanishes with it.
function buttonsUnderText(tree: any, inText = false): number {
  if (!tree || typeof tree !== 'object') return 0
  if (tree.type === 'Button' && inText) return 1
  const inline = inText || tree.type === 'Text'
  return (tree.children ?? []).reduce((n: number, c: any) => n + buttonsUnderText(c, inline), 0)
}

test('no button is ever nested in a Text, armed or not', async () => {
  percent = 40
  expect(buttonsUnderText(await band())).toBe(0)
  arm()
  expect(buttonsUnderText(await band())).toBe(0)
})

// The contract lets a held key repeat on keydown, and a digit with no button
// on it lands in the composer (measured: a second `2` while armed typed `2`,
// and a non-empty composer takes every hotkey with it). So `2` keeps a button
// while armed: each press only re-arms, the window restarts, nothing is typed,
// and the confirmation sits on `3`.

// The count's colour ramp: the session's own colour while there is time, the
// bar's amber from ten seconds, its crit red under five. Inks KEEP IN SYNC
// with _sgr in bin/cs-statusline (tests/test_mod_rotate.sh pins them).
function texts(tree: any): any[] {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(texts)
  const own = tree.type === 'Text' ? [tree] : []
  return [...own, ...(tree.children ?? []).flatMap(texts)]
}
const textOf = (node: any): string => (node.children ?? []).map((c: any) => typeof c === 'string' ? c : '').join('')
const HANDOFF_WITH_STEP = '---\nparent: uuid-lead\nstatus: unconsumed\n---\n\n# Next Step\n\nRun the secrets suites solo.\nTriage the store file.\n\n# Settled\n\nNothing.\n'
const countText = (tree: any) => texts(tree).find(t => /^\/clear in \d+s$/.test(textOf(t)))
const startGrace = async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); files[HANDOFF] = HANDOFF_WITH_STEP; percent = 80
  await band()
  await turnComplete()
}

test('the band\'s count ramps: session colour past ten seconds, amber from ten to five, crit red under five', async () => {
  envVars.CS_TERM_BG_RGB = '252;247;229'
  await startGrace()
  let count = countText(await band())
  expect(count.props).toMatchObject({ bold: true, color: 'rgb(220,38,38)' })
  await tick(9) // 11 s left
  expect(countText(await band()).props.color).toBe('rgb(220,38,38)')
  await tick(1) // 10
  expect(countText(await band()).props.color).toBe('rgb(180,83,9)')
  await tick(5) // 5
  expect(countText(await band()).props.color).toBe('rgb(180,83,9)')
  await tick(1) // 4
  count = countText(await band())
  expect(textOf(count)).toBe('/clear in 4s')
  expect(count.props.color).toBe('rgb(215,0,21)')
})

test('on a dark terminal the ramp takes the bar\'s dark inks', async () => {
  envVars.CS_TERM_BG_RGB = '30;30;30'
  envVars.CS_TERM_THEME = 'dark'
  files['/work/.cs/local/state'] = 'claude_session_color: cyan\nclaude_session_id: uuid-lead\n'
  await startGrace()
  expect(countText(await band()).props.color).toBe('rgb(8,145,178)')
  await tick(10)
  expect(countText(await band()).props.color).toBe('rgb(253,230,138)')
  await tick(6)
  expect(countText(await band()).props.color).toBe('rgb(255,69,58)')
})

test('a session with no colour, or one outside the palette, keeps the band\'s own ink until the amber', async () => {
  files['/work/.cs/local/state'] = 'claude_session_color: chartreuse\nclaude_session_id: uuid-lead\n'
  await startGrace()
  expect(countText(await band()).props.color).toBeUndefined()
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-lead\n'
  expect(countText(await band()).props.color).toBeUndefined()
  await tick(10)
  // no measured background and no theme: the light amber, as the bar picks
  expect(countText(await band()).props.color).toBe('rgb(180,83,9)')
})


// The count's start toasts the handoff's next step, from a timer (the count
// starts inside the turn's own hook), so the twenty seconds are spent knowing
// what the next conversation will do. One toast per armed handoff: the band's
// redraws, and a count restarted for the same handoff, say nothing more.
test('the first count on an armed handoff toasts its next step once, from a timer', async () => {
  await startGrace()
  expect(toasts).toEqual([])
  await fireAfter()
  expect(toasts).toEqual(['cs: next step: Run the secrets suites solo.'])
  await band(); await tick(2); await band()
  expect(toasts).toHaveLength(1)
  await promptSubmit()
  await turnComplete(); await fireAfter()
  expect(ticker()).toBeDefined()
  expect(toasts).toHaveLength(1)
})

test('a handoff armed after the /clear, in the same process, is toasted in its turn', async () => {
  await startGrace(); await fireAfter()
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  files[HANDOFF] = '---\nparent: uuid-two\nstatus: unconsumed\n---\n\n## 1. Next Step\n\nShip it.\n'
  sessionId = 'uuid-two'; percent = 10
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: uuid-two\n'
  await band(); await turnComplete(); await fireAfter()
  expect(toasts).toEqual(['cs: next step: Run the secrets suites solo.', 'cs: next step: Ship it.'])
})

test('a count that ends before its timer fires, or a handoff with no next step, toasts nothing', async () => {
  await startGrace()
  await promptSubmit()
  await fireAfter()
  expect(toasts).toEqual([])
  register(on as any, OPTIONS)
  arm(); files[HANDOFF] = '---\nparent: uuid-lead\nstatus: unconsumed\n---\n\nNo heading here.\n'
  await band(); await turnComplete(); await fireAfter()
  expect(ticker()).toBeDefined()
  expect(toasts).toEqual([])
})

// The count opens no pane and the /clear paths wait on none: nothing of the
// mod's opens, closes or lists a pane.
test('no path of the mod opens, closes or lists a pane', async () => {
  await startGrace(); await fireAfter()
  await promptSubmit()
  await turnComplete(); await fireAfter()
  await findButton(await band()).props.onPress()
  await hooks['command.run:clear']($, { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }, async () => ({ text: '' }))
  register(on as any, OPTIONS); arm()
  await band(); await turnComplete(); await tick(GRACE_SECONDS)
  expect(ran.filter(r => r.command === 'clear')).toHaveLength(2)
  expect(panes).toEqual([])
  expect(hooks['ui.render:Pane']).toBeUndefined()
})

test('nextStepLine is the first line of the Next Step section, however the heading is numbered', () => {
  expect(nextStepLine(HANDOFF_WITH_STEP)).toBe('Run the secrets suites solo.')
  expect(nextStepLine('---\nstatus: unconsumed\n---\n\n## 1. Next Step\n\n  One thing.  \n\n- a\n')).toBe('One thing.')
  expect(nextStepLine('---\nstatus: unconsumed\n---\n\nNo heading here.\n')).toBeUndefined()
  expect(nextStepLine('# Next Step\n\n\n# Settled\n\nNothing.\n')).toBeUndefined()
})

test('a first line past the toast\'s length is cut there with an ellipsis', () => {
  const long = 'x'.repeat(NEXT_STEP_CHARS) + 'y'.repeat(10)
  expect(nextStepLine(`# Next Step\n\n${long}\nnext line\n`)).toBe('x'.repeat(NEXT_STEP_CHARS) + '\u2026')
  expect(nextStepLine(`# Next Step\n\n${'x'.repeat(NEXT_STEP_CHARS)}\n`)).toBe('x'.repeat(NEXT_STEP_CHARS))
})

test('a # line inside a fenced block belongs to the step, and a fence line is not the step\'s first line', () => {
  expect(nextStepLine('## Next Step\n\n```bash\n# build first\n./build.sh\n```\n\n## Settled\n')).toBe('# build first')
  expect(nextStepLine('## Next Step\n\n~~~\n```\n## not a heading\n~~~\nThen merge.\n')).toBe('```')
  expect(nextStepLine('## Next Step\n\n~~~\n\n## not a heading\n~~~\n')).toBe('## not a heading')
})

// /queue hands the task to `cs -queue add` by the path the launch exported,
// which resolves this session's queue from the environment claude inherited.
const startSession = () => hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
const queue = (args: string) => hooks['command.run:queue']($, { command: 'queue', args }, async () => ({ text: 'unhandled' }))

test('the mod registers /queue at load, to run at once even mid-turn', async () => {
  await startSession()
  expect(commands).toHaveLength(2)
  expect(commands[0]).toMatchObject({ name: 'queue', immediate: true, argumentHint: '[task]' })
  expect(commands[1]).toMatchObject({ name: 'cs', immediate: true, argumentHint: 'next|prev|first|last|<n>' })
})

test('/queue with a task runs cs -queue add with the task as one argument and says it is queued', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  const r = await queue('fix the flaky "rotate" test; then rerun it')
  expect(runs.map(x => x.argv)).toEqual([['/opt/cs/bin/cs', '-queue', 'add', 'fix the flaky "rotate" test; then rerun it']])
  expect(r).toEqual({ text: 'Queued: fix the flaky "rotate" test; then rerun it' })
  expect(toasts).toEqual(['cs: queued: fix the flaky "rotate" test; then rerun it'])
  await settle()
  expect(asks).toEqual([])
})

// The toast is one line under the prompt; a long task is cut so it fits.
test('/queue with a long task confirms it in a toast cut to 60 characters', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  const task = 'a'.repeat(59) + 'bc' + ' tail'
  await queue(`  ${task}  `)
  expect(toasts).toEqual([`cs: queued: ${'a'.repeat(59)}b…`])
})

test('/queue with no task, or only spaces, prints cs -queue list', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = { exitCode: 0, stdout: 'Pending:\n  1. first\n  2. second\n', stderr: '' }
  expect(await queue('')).toEqual({ text: 'Pending:\n  1. first\n  2. second' })
  expect(await queue('   ')).toEqual({ text: 'Pending:\n  1. first\n  2. second' })
  expect(runs.map(x => x.argv)).toEqual([['/opt/cs/bin/cs', '-queue', 'list'], ['/opt/cs/bin/cs', '-queue', 'list']])
  expect(toasts).toEqual([])
})

// The offer is made after the listing is back on screen, so the person reads
// the tasks before answering; the drain itself belongs to the Stop hook.
const settle = () => new Promise(r => setTimeout(r, 0))
const LISTED = { exitCode: 0, stdout: 'Pending (2)\n  1. first\n  2. second\n\nDone (1)\n  - shipped\n', stderr: '' }

test('/queue with pending tasks offers to start them; Start while idle arms the queue and starts a turn', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  expect(await queue('')).toEqual({ text: 'Pending (2)\n  1. first\n  2. second\n\nDone (1)\n  - shipped' })
  await settle()
  expect(asks).toEqual([
    { question: 'Start the 2 queued tasks now?', options: { header: 'Queue', options: [QUEUE_START, 'Not yet', QUEUE_COMPACT] } },
    { question: QUEUE_MODE_QUESTION, options: { header: 'Queue', options: [QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS] } },
  ])
  expect(runs.map(x => x.argv)).toEqual([['/opt/cs/bin/cs', '-queue', 'list'], ['/opt/cs/bin/cs', '-queue', 'start']])
  expect(submitted).toEqual([{ text: QUEUE_KICK }])
})

// Start also asks how the tasks run: here, each in a subagent, or each as a
// workflow; the answer rides on cs -queue start.
test('Start then In subagents or As workflows arms the queue in that mode', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  modeAnswer = QUEUE_SUBAGENTS
  await queue('')
  await settle()
  modeAnswer = QUEUE_WORKFLOWS
  await queue('')
  await settle()
  expect(runs.map(x => x.argv.slice(1))).toEqual([['-queue', 'list'], ['-queue', 'start', 'subagents'], ['-queue', 'list'], ['-queue', 'start', 'workflow']])
})

test('Not yet asks nothing more', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = 'Not yet'
  await queue('')
  await settle()
  expect(asks.map(a => a.question)).toEqual(['Start the 2 queued tasks now?'])
})

// A dismissed second question starts nothing and compacts nothing, as a
// dismissed first one does.
test('a dismissed mode question starts nothing', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  modeAnswer = new Error('dismissed')
  for (const a of [QUEUE_START, QUEUE_COMPACT]) {
    answer = a
    await queue('')
    await settle()
  }
  expect(runs.map(x => x.argv[2])).toEqual(['list', 'list'])
  expect(compactedAt).toEqual([])
  expect(submitted).toEqual([])
})

// Free text typed under "Other" names no mode cs knows, so nothing starts.
test('an answer that is no mode starts nothing and says so', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  modeAnswer = 'in parallel please'
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(toasts).toEqual(["cs: 'in parallel please' is not a way to run the queue; it is not started"])
})

test('Compact asks the mode before compacting, then starts in it', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_COMPACT
  modeAnswer = QUEUE_WORKFLOWS
  await queue('')
  await settle()
  expect(asks.map(a => a.question)).toEqual(['Start the 2 queued tasks now?', QUEUE_MODE_QUESTION])
  expect(compactedAt).toEqual([1])
  expect(runs.map(x => x.argv.slice(1))).toEqual([['-queue', 'list'], ['-queue', 'start', 'workflow']])
})

// A turn already running reaches a stop on its own, where the Stop hook hands
// over the first task; a prompt sent now would wait out the whole drain.
test('Start while a turn is running arms the queue and sends no prompt', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  await band({ isWorking: true })
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list', 'start'])
  expect(submitted).toEqual([])
})

// Not yet leaves the queue as it is: the band keeps offering its start key.
test('Not yet runs nothing and sends no prompt', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = 'Not yet'
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(submitted).toEqual([])
})

test('a queue already armed or draining is listed without an offer', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  for (const state of ['armed\n', 'draining\n']) {
    files['/work/.cs/local/queue.state'] = state
    await queue('')
    await settle()
  }
  expect(asks).toEqual([])
  expect(runs.map(x => x.argv[2])).toEqual(['list', 'list'])
})

test('an encrypted session\'s queue state is read behind .cs/private', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  files['/work/.cs/private/queue.state'] = 'draining\n'
  await queue('')
  await settle()
  expect(asks).toEqual([])
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
})

test('an empty queue is listed without an offer', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = { exitCode: 0, stdout: 'Queue is empty.\n\nDone (1)\n  - shipped\n', stderr: '' }
  await queue('')
  await settle()
  expect(asks).toEqual([])
})

test('a start cs refuses, or one that cannot run, says so and sends no prompt', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  answer = QUEUE_START
  nextRuns = [LISTED, { exitCode: 1, stdout: '', stderr: 'Error: the queue is locked\n' }, LISTED, new Error('spawn ENOENT')]
  await queue('')
  await settle()
  await queue('')
  await settle()
  expect(toasts).toEqual(['cs: cs -queue start exited 1: Error: the queue is locked', 'cs: cs -queue start did not run: spawn ENOENT'])
  expect(submitted).toEqual([])
})

test('a prompt the engine refuses is shown, not dropped', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  $.prompt.submit = async () => { throw new Error('session closed') }
  try {
    await queue('')
    await settle()
  } finally {
    $.prompt.submit = async (args: any) => { submitted.push(args); return {} }
  }
  expect(toasts).toEqual(['cs: the queue is armed, but its first turn did not start: session closed'])
})

// Compact frees the context the drain will need first: the conversation is
// compacted before the queue is armed, so a compaction that does not happen
// leaves the queue exactly as it was.
test('Compact compacts the conversation, then arms the queue and starts a turn', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_COMPACT
  await queue('')
  await settle()
  expect(compactedAt).toEqual([1])
  expect(runs.map(x => x.argv[2])).toEqual(['list', 'start'])
  expect(submitted).toEqual([{ text: QUEUE_KICK }])
  expect(toasts).toEqual([])
})

test('a compaction a hook vetoes leaves the queue unarmed and says why', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_COMPACT
  compactResult = { skip: 'a PreCompact hook blocked it' }
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(submitted).toEqual([])
  expect(toasts).toEqual(['cs: the conversation was not compacted (a PreCompact hook blocked it); the queue is not started'])
})

// The engine refuses a compaction while a turn runs.
test('a compaction the engine refuses leaves the queue unarmed and says so', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_COMPACT
  compactResult = new Error('a turn is running')
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(submitted).toEqual([])
  expect(toasts).toEqual(['cs: the conversation was not compacted (a turn is running); the queue is not started'])
})

test('a dismissed offer runs nothing more', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = new Error('dismissed')
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(submitted).toEqual([])
  expect(toasts).toEqual([])
})

test('a refused add prints the exit code and cs\'s own stderr, verbatim', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = { exitCode: 1, stdout: '', stderr: "warning: an earlier line\n\nError: task bodies must be a single line (the queue's done log and listing are line-oriented)\n" }
  const r = await queue('one\ntwo')
  expect(runs[0].argv).toEqual(['/opt/cs/bin/cs', '-queue', 'add', 'one\ntwo'])
  expect(r).toEqual({ text: "cs -queue add exited 1.\nwarning: an earlier line\nError: task bodies must be a single line (the queue's done log and listing are line-oriented)" })
  expect(toasts).toEqual([])
})

test('a run that cannot start says why', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = new Error('spawn ENOENT')
  expect(await queue('')).toEqual({ text: 'cs -queue list did not run: spawn ENOENT' })
})

test('without CS_BIN /queue says the launch did not say where cs is, and runs nothing', async () => {
  delete envVars.CS_BIN
  const r = await queue('something')
  expect(runs).toHaveLength(0)
  expect(r).toEqual({ text: 'The launch did not say where cs is (CS_BIN); run `cs -queue add "<task>"` from a shell in this session.' })
})

// The band's start key: tasks queued and nothing running them. cs writes one
// file per task in the queue directory, behind .cs/private in an encrypted
// session and in .cs/local otherwise.
const QDIR = '/work/.cs/local/queue'
const queueTasks = (n: number, dir = QDIR) => { for (let i = 1; i <= n; i++) files[`${dir}/000000000${i}-seed`] = `task ${i}\n` }
const queueKey = (tree: any) => buttons(tree).find((b: any) => b.props.key === 'cs-queue')
// The band body's elements in order, with the conditional gaps left out.
const bandBody = (tree: any): any[] => {
  if (!tree || typeof tree !== 'object') return []
  if (tree.props?.key === 'cs-rotate-band') return (tree.children ?? []).flat().filter((c: any) => c && typeof c === 'object')
  return (tree.children ?? []).flatMap(bandBody)
}

test('a queue with tasks and nothing running them draws a start key, below the threshold too', async () => {
  queueTasks(2)
  const tree = await band()
  expect(buttons(tree).map((b: any) => b.props.label)).toEqual(['\u25a4 queue 2 \u00b7 start'])
  expect(queueKey(tree).props).toMatchObject({ key: 'cs-queue', plain: true })
  expect(queueKey(tree).props.action).toBeUndefined()
  expect(buttonsUnderText(tree)).toBe(0)
})

test('the start key is gone while the queue is armed or draining, and while it is empty', async () => {
  expect(await band()).toBe(DRAWN)
  queueTasks(1)
  for (const state of ['armed\n', 'draining\n']) {
    files['/work/.cs/local/queue.state'] = state
    expect(queueKey(await band())).toBeUndefined()
  }
  files['/work/.cs/local/queue.state'] = 'idle\n'
  expect(queueKey(await band()).props.label).toBe('\u25a4 queue 1 \u00b7 start')
})

test('past the threshold the start key comes after the rotate and wrap keys, a separator before it', async () => {
  percent = 40
  queueTasks(3)
  const tree = await band()
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap', 'cs-queue'])
  const body = bandBody(tree)
  const at = body.indexOf(queueKey(tree))
  expect(body[at - 1]).toMatchObject({ type: 'Text', children: ['  \u00b7  '] })
  expect(buttonsUnderText(tree)).toBe(0)
})

test('an armed handoff draws the clear key alone, whatever is queued', async () => {
  arm()
  queueTasks(2)
  expect(buttons(await band()).map((b: any) => b.props.key)).toEqual(['cs-rotate'])
})

test('a teammate conversation, or one cs did not launch, gets no start key', async () => {
  queueTasks(2)
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
  sessionId = 'uuid-lead'
  cwdPath = '/elsewhere'
  expect(await band()).toBe(DRAWN)
})

test('an encrypted session counts its tasks, and reads its state, behind .cs/private', async () => {
  existing.add('/work/.cs/private')
  queueTasks(5)
  queueTasks(2, '/work/.cs/private/queue')
  expect(queueKey(await band()).props.label).toBe('\u25a4 queue 2 \u00b7 start')
  files['/work/.cs/private/queue.state'] = 'draining\n'
  const tree = await band()
  expect(queueKey(tree)).toBeUndefined()
  expect(restingWords(tree)).toEqual(['\u25cf', '\u25a4 queue 2'])
})

test('pressing the start key asks to start and how, then starts the queue and its first turn', async () => {
  queueTasks(2)
  answer = QUEUE_START
  modeAnswer = QUEUE_SUBAGENTS
  queueKey(await band()).props.onPress()
  await settle()
  expect(asks).toEqual([
    { question: 'Start the 2 queued tasks now?', options: { header: 'Queue', options: [QUEUE_START, 'Not yet', QUEUE_COMPACT] } },
    { question: QUEUE_MODE_QUESTION, options: { header: 'Queue', options: [QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS] } },
  ])
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-queue', 'start', 'subagents']])
  expect(submitted).toEqual([{ text: QUEUE_KICK }])
})

test('a press after the queue was started, or emptied, asks nothing', async () => {
  queueTasks(1)
  const key = queueKey(await band())
  files['/work/.cs/local/queue.state'] = 'armed\n'
  key.props.onPress()
  await settle()
  delete files['/work/.cs/local/queue.state']
  delete files[`${QDIR}/0000000001-seed`]
  key.props.onPress()
  await settle()
  expect(asks).toEqual([])
  expect(runs).toEqual([])
})

test('without CS_BIN a press says where to start the queue, and runs nothing', async () => {
  queueTasks(1)
  delete envVars.CS_BIN
  queueKey(await band()).props.onPress()
  await settle()
  expect(asks).toEqual([])
  expect(runs).toEqual([])
  expect(toasts).toEqual(['cs: the launch did not say where cs is (CS_BIN); run cs -queue start from a shell in this session'])
})

// /finish progress: cs writes one record per step while it integrates and
// retires; the mod reads it on a one-second watch that /finish starts.
const RECORD = '/work/.cs/local/finish-progress.json'
const SHA = '1234567' + 'f'.repeat(33)
const RESULT = '89abcde' + '0'.repeat(33)
const NOW = 1_800_000_000
const record = (r: any, path = RECORD) => { files[path] = JSON.stringify(r) }
const running = (step: string, extra: any = {}) => ({ id: '4242-1799999990', pid: 4242, task: 'fix-auth', sha: SHA, step, ts: NOW, ...extra })
const startFinish = () => hooks['skill.prompt:finish']($, { skill: 'finish', text: 'land it' }, async (e: any) => ({ text: e.text }))
const watches = () => timers.filter(t => t.kind === 'every' && t.ms === 1000)
const watchTick = async () => {
  const live = watches().filter(t => !t.cancelled)
  expect(live).toHaveLength(1)
  await live[0].fn()
}

test('/finish starts one watch, passes its prompt through, and never toasts the outcome of an earlier run', async () => {
  record({ id: '100-1', pid: 100, task: 'old-task', sha: SHA, step: 'landed', result: RESULT, ts: 1 })
  expect(await startFinish()).toEqual({ text: 'land it' })
  await startFinish()
  expect(watches()).toHaveLength(1)
  await watchTick()
  expect(toasts).toEqual([])
})

test('a /finish that starts toasts its task once, however many steps follow', async () => {
  livePids.add('4242')
  await startFinish()
  record(running('started'))
  await watchTick()
  record(running('merging'))
  await watchTick()
  record(running('fast-forward'))
  await watchTick()
  expect(toasts).toEqual(['cs: finishing fix-auth'])
})

test('each outcome toasts once, in its own words, and not again on the next tick', async () => {
  await startFinish()
  record(running('landed', { result: RESULT }))
  await watchTick()
  await watchTick()
  record({ id: '5151-1800000001', pid: 5151, task: 'fix-auth', sha: SHA, step: 'refused', reason: 'Base /work moved during the gates (was abc, now def); re-run /finish fix-auth', ts: NOW })
  await watchTick()
  await watchTick()
  record({ id: '6161-1800000002', pid: 6161, task: 'fix-auth', sha: SHA, step: 'retired', ts: NOW })
  await watchTick()
  await watchTick()
  expect(toasts).toEqual([
    'cs: landed fix-auth 1234567 -> 89abcde',
    'cs: /finish fix-auth refused: Base /work moved during the gates (was abc, now def); re-run /finish fix-auth',
    'cs: retired fix-auth',
  ])
})

test('a long task is cut in the toast as /queue cuts it', async () => {
  livePids.add('4242')
  await startFinish()
  record(running('started', { task: 'a'.repeat(59) + 'bc tail' }))
  await watchTick()
  expect(toasts).toEqual([`cs: finishing ${'a'.repeat(59)}b…`])
})

test('an encrypted session\'s record is read behind .cs/private', async () => {
  await startFinish()
  record({ id: '6161-1800000002', pid: 6161, task: 'fix-auth', sha: SHA, step: 'retired', ts: NOW }, '/work/.cs/private/finish-progress.json')
  await watchTick()
  expect(toasts).toEqual(['cs: retired fix-auth'])
})

test('while a gate runs under a live pid the band shows the task and the time since the gate started, even mid-turn', async () => {
  livePids.add('4242')
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 75 }))
  await watchTick()
  expect(invalidated).toContain('ui.render')
  const tree = JSON.stringify(await band({ isWorking: true }))
  expect(tree).toContain('"Survey"')
  expect(tree).toContain('finishing fix-auth · gate 1m 15s')
  nowMs += 10_000
  expect(JSON.stringify(await band({ isWorking: true }))).toContain('finishing fix-auth · gate 1m 25s')
  nowMs = (NOW - 75 + 42) * 1000
  expect(JSON.stringify(await band({ isWorking: true }))).toContain('finishing fix-auth · gate 42s')
})

test('a gate whose pid is dead, or a record past its gate, draws no band', async () => {
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 5 }))
  await watchTick()
  expect(await band({ isWorking: true })).toBe(DRAWN)
  livePids.add('4242')
  await watchTick()
  expect(JSON.stringify(await band({ isWorking: true }))).toContain('gate 5s')
  record(running('fast-forward', { gate_started: NOW - 5 }))
  invalidated = []
  await watchTick()
  expect(invalidated).toContain('ui.render')
  expect(await band({ isWorking: true })).toBe(DRAWN)
  record(running('gate', { gate_started: NOW - 5 }))
  await watchTick()
  record(running('landed', { gate_started: NOW - 5, result: RESULT }))
  await watchTick()
  expect(await band({ isWorking: true })).toBe(DRAWN)
})

test('with the rotation keys up, the gate word is the band\'s last word, dim, after a separator, and both keys stay', async () => {
  livePids.add('4242')
  nowMs = NOW * 1000
  percent = 40
  await startFinish()
  record(running('gate', { gate_started: NOW - 3 }))
  await watchTick()
  const tree = await band()
  expect(buttons(tree)).toHaveLength(2)
  const body = bandBody(tree)
  expect(body.at(-1)).toMatchObject({ type: 'Text', props: { dimColor: true }, children: ['finishing fix-auth · gate 3s'] })
  expect(body.at(-2)).toMatchObject({ type: 'Text', children: ['  \u00b7  '] })
  expect(boxes(tree).filter((b: any) => b.props.key === 'cs-rotate-band')).toHaveLength(1)
  expect(JSON.stringify(tree)).not.toContain('backgroundColor')
})

test('alone, the gate word draws on the thin line with no separator', async () => {
  livePids.add('4242')
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 3 }))
  await watchTick()
  const tree = await band({ isWorking: true })
  expect(buttons(tree)).toEqual([])
  expect(words(tree)).toEqual(['\u25cf', 'finishing fix-auth · gate 3s'])
  expect(boxes(tree).find((b: any) => b.props.key === 'cs-rotate-band').props.marginLeft).toBe(2)
})

test('the watch ends once the turn is over and nothing runs, and not while a step still runs', async () => {
  livePids.add('4242')
  await startFinish()
  record(running('gate', { gate_started: NOW }))
  await watchTick()
  await hooks['turn.complete']($, { reason: 'answer' }, async () => ({ text: '' }))
  await watchTick()
  expect(watches()[0].cancelled).toBe(false)
  record({ id: '6161-1800000002', pid: 6161, task: 'fix-auth', sha: SHA, step: 'retired', ts: NOW })
  await watchTick()
  expect(toasts).toEqual(['cs: finishing fix-auth', 'cs: retired fix-auth'])
  expect(watches()[0].cancelled).toBe(true)
  // the next /finish watches afresh
  await startFinish()
  expect(watches().filter(t => !t.cancelled)).toHaveLength(1)
})

// ---------------------------------------------------------------------------
// The rail: one tick per prompt on the transcript's live branch.

// The session's transcript: Claude Code keeps it under ~/.claude/projects/<slug>/<id>.jsonl,
// the slug the cwd with every character outside [A-Za-z0-9] made `-`.
const TRANSCRIPT = '/home/.claude/projects/-work/uuid-lead.jsonl'
const row = (o: Record<string, unknown>) => JSON.stringify(o)
const prompt = (uuid: string, parent: string | null, text: unknown, extra: Record<string, unknown> = {}) =>
  row({ uuid, parentUuid: parent, type: 'user', message: { role: 'user', content: text }, ...extra })
const reply = (uuid: string, parent: string) =>
  row({ uuid, parentUuid: parent, type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] } })
const LINEAR = [
  prompt('u1', null, 'say one'), reply('a1', 'u1'),
  prompt('u2', 'a1', 'say two'), reply('a2', 'u2'),
  prompt('u3', 'a2', 'say three\nwith a second line'), reply('a3', 'u3'),
  prompt('u4', 'a3', '  say four  '), reply('a4', 'u4'),
]
const transcript = (lines: string[], mtime = 1) => { files[TRANSCRIPT] = `${lines.join('\n')}\n`; mtimes[TRANSCRIPT] = mtime }
const sessionStart = () => hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e: any) => ({ cwd: e.cwd }))
// A UserMessage row as the engine draws it, reporting what of it is on screen.
const drawRow = (requestId: string, text: string, onScreen: any) =>
  hooks['ui.render:UserMessage']($, { requestId, component: 'UserMessage', surface: 'terminal', props: { text, origin: { kind: 'composer' }, isExpanded: false, onScreen } }, async (e: any) => e)
const cs = (args: string) => hooks['command.run:cs']($, { command: 'cs', args }, async () => ({ text: 'unhandled' }))
// The rail's glyphs in order: each tick's label (a Button, or the Text the read prompt's tick is) and the `…N` run.
const rail = (tree: any): string[] => {
  const box = boxes(tree).find((b: any) => b.props.key === 'cs-rail')
  if (box === undefined) return []
  return (box.children ?? []).flat().filter((c: any) => c && typeof c === 'object')
    .map((c: any) => (c.type === 'Button' ? c.props.label : textOf(c)))
}
const tickButtons = (tree: any) => buttons(tree).filter((b: any) => /^cs-rail-\d+$/.test(b.props.key))

test('the live branch of a linear transcript lists every prompt, first line trimmed and cut to 80 characters', () => {
  const long = prompt('u5', 'a4', 'x'.repeat(100))
  expect(parsePrompts(`${[...LINEAR, long].join('\n')}\n`)).toEqual([
    { uuid: 'u1', text: 'say one' }, { uuid: 'u2', text: 'say two' }, { uuid: 'u3', text: 'say three' }, { uuid: 'u4', text: 'say four' },
    { uuid: 'u5', text: `${'x'.repeat(RAIL_TEXT_CHARS - 1)}\u2026` },
  ])
})

test('a /rewind leaves its abandoned prompts off the branch: the walk follows parentUuid back from the last row', () => {
  const forked = [...LINEAR, prompt('u5', 'a2', 'say five instead'), reply('a5', 'u5')]
  expect(parsePrompts(forked.join('\n')).map(p => p.text)).toEqual(['say one', 'say two', 'say five instead'])
})

test('a /compact boundary row links the branch on through logicalParentUuid', () => {
  const compacted = [
    ...LINEAR,
    row({ uuid: 'b1', parentUuid: null, logicalParentUuid: 'a4', type: 'system', subtype: 'compact_boundary' }),
    prompt('s1', 'b1', 'This session is being continued from a previous conversation', { isCompactSummary: true }),
    prompt('u5', 's1', 'say five'), reply('a5', 'u5'),
  ]
  expect(parsePrompts(compacted.join('\n')).map(p => p.text)).toEqual(['say one', 'say two', 'say three', 'say four', 'say five'])
})

test('tool results, command echoes, meta rows, sidechains, system-origin rows and a torn line are not prompts', () => {
  const noisy = [
    prompt('u1', null, 'say one'), reply('a1', 'u1'),
    prompt('t1', 'a1', [{ type: 'tool_result', tool_use_id: 'x', content: 'done' }]), reply('a2', 't1'),
    prompt('c1', 'a2', '<command-message>rotate</command-message>\n<command-name>/rotate</command-name>'), reply('a3', 'c1'),
    prompt('m1', 'a3', 'Stop hook feedback: narrative check', { isMeta: true }), reply('a4', 'm1'),
    prompt('n1', 'a4', '<task-notification>\n<task-id>b1</task-id>\n</task-notification>', { origin: { kind: 'task-notification' } }), reply('a5', 'n1'),
    prompt('side', 'a5', 'a subagent prompt', { isSidechain: true }),
    prompt('u2', 'a5', [{ type: 'text', text: 'say two' }]), reply('a6', 'u2'),
    '{"uuid":"torn","parentUuid":"a6","type":"us',
  ]
  expect(parsePrompts(noisy.join('\n')).map(p => p.text)).toEqual(['say one', 'say two'])
})

test('after a turn ends the band draws one tick per prompt, the newest thick while no row has reported', async () => {
  transcript(LINEAR)
  await turnComplete()
  expect(invalidated).toContain('ui.render')
  const tree = await band()
  expect(rail(tree)).toEqual(['\u2502', '\u2502', '\u2502', '\u2503'])
  expect(tickButtons(tree).map((b: any) => b.props.key)).toEqual(['cs-rail-0', 'cs-rail-1', 'cs-rail-2'])
  for (const b of tickButtons(tree)) expect(b.props).toMatchObject({ plain: true, dimColor: true })
  expect(tickButtons(tree).some((b: any) => b.props.hotkey !== undefined)).toBe(false)
  expect(buttonsUnderText(tree)).toBe(0)
  expect(texts(tree).find((t: any) => textOf(t) === '\u2503').props).toMatchObject({ bold: true, color: 'rgb(220,38,38)' })
  // Below the threshold the rail still draws after the mark, with no key words, and the read prompt in the gap.
  expect(restingWords(tree)).toEqual(['\u25cf', '\u2503', '#4 say four'.padEnd(100)])
})

test('a conversation with one prompt draws no rail', async () => {
  transcript(LINEAR.slice(0, 2))
  percent = 40
  await turnComplete()
  const tree = await band()
  expect(rail(tree)).toEqual([])
  expect(words(tree)).toEqual(['\u25cf', '1', '  \u00b7  ', '2'].filter(w => w !== '1' && w !== '2'))
})

test('the transcript is read again only when its size or mtime changed', async () => {
  transcript(LINEAR)
  await turnComplete()
  await turnComplete()
  expect(reads.filter(p => p === TRANSCRIPT)).toHaveLength(1)
  transcript(LINEAR, 2)
  await turnComplete()
  expect(reads.filter(p => p === TRANSCRIPT)).toHaveLength(2)
  files[TRANSCRIPT] += prompt('u5', 'a4', 'say five')
  await turnComplete()
  expect(reads.filter(p => p === TRANSCRIPT)).toHaveLength(3)
  expect(rail(await band())).toHaveLength(5)
})

test('CS_TRANSCRIPTS_DIR and a session\'s own claude-config move the transcript; the slug follows the resolved cwd', async () => {
  envVars.CS_TRANSCRIPTS_DIR = '/elsewhere'
  files['/elsewhere/-work/uuid-lead.jsonl'] = `${LINEAR.join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(4)
  delete envVars.CS_TRANSCRIPTS_DIR
  existing.add('/work/.cs/claude-config')
  files['/work/.cs/claude-config/projects/-work/uuid-lead.jsonl'] = `${LINEAR.slice(0, 6).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(3)
  existing.delete('/work/.cs/claude-config')
  realPaths['/work'] = '/Volumes/data/work.dir'; realPaths['/home/.claude-sessions/work'] = '/Volumes/data/work.dir'
  files['/home/.claude/projects/-Volumes-data-work-dir/uuid-lead.jsonl'] = `${LINEAR.slice(0, 4).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(2)
})

test('past the width budget the oldest prompts collapse into one dim …N run at the left', async () => {
  register(on as any, UNCAPPED)
  envVars.HOME = '/home'
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  percent = 40
  const many = [prompt('u1', null, 'p1')]
  for (let i = 2; i <= 30; i++) many.push(reply(`a${i - 1}`, `u${i - 1}`), prompt(`u${i}`, `a${i - 1}`, `p${i}`))
  transcript(many)
  await turnComplete()
  // The two-column inset + `● ` (2) + rail + `   ` (3) + `ctrl+x  1 rotate  ·  2 wrap` (27): 39 columns leave 5 cells
  // for 30 ticks, so 28 collapse into `…28` and two ticks follow.
  const glyphs = rail(await band({ bodyColumns: 39 }))
  expect(glyphs).toEqual(['\u202628', '\u2502', '\u2503'])
  expect(tickButtons(await band({ bodyColumns: 39 })).map((b: any) => b.props.key)).toEqual(['cs-rail-28'])
  expect(texts(await band({ bodyColumns: 39 })).find((t: any) => textOf(t) === '\u202628').props).toEqual({ dimColor: true })
  // Wide enough, every tick draws.
  expect(rail(await band({ bodyColumns: 110 }))).toHaveLength(30)
  // No room at all: no rail.
  expect(rail(await band({ bodyColumns: 35 }))).toEqual([])
})

test('the prompt being read is the on-screen row drawn highest, the earliest on ties; a first null report leaves nothing, a later one removes the report; placeholder is ignored', async () => {
  register(on as any, READING)
  transcript(LINEAR)
  await turnComplete()
  await drawRow('placeholder', 'say four', { first: 0, last: 1, of: 2 })
  await drawRow('u1', 'say one', { first: 0, last: 1, of: 2 })
  await drawRow('u2', 'say two', { first: 3, last: 5, of: 6 })
  // A row's first render reports null before it is laid out: nothing changes.
  await drawRow('r3', 'say three\nwith a second line', null)
  expect(rail(await band())).toEqual(['\u2502', '\u2503', '\u2502', '\u2502'])
  // A null after a report is the row scrolled out of view: its report goes.
  await drawRow('u2', 'say two', null)
  expect(rail(await band())).toEqual(['\u2503', '\u2502', '\u2502', '\u2502'])
  // Everything visible reports 0: the topmost, the earliest of them, is being read.
  await drawRow('u2', 'say two', { first: 0, last: 5, of: 6 })
  await drawRow('r3', 'say three\nwith a second line', { first: 0, last: 1, of: 2 })
  expect(rail(await band())).toEqual(['\u2503', '\u2502', '\u2502', '\u2502'])
  // The person scrolled up: the first prompt's row is now the one cut at the top.
  await drawRow('u1', 'say one', { first: 2, last: 4, of: 6 })
  expect(rail(await band())).toEqual(['\u2503', '\u2502', '\u2502', '\u2502'])
})

test('a report that moves the read prompt redraws the band from a timer, never from the render itself', async () => {
  register(on as any, READING)
  transcript(LINEAR)
  await turnComplete()
  await band()
  invalidated = []
  await drawRow('u1', 'say one', { first: 0, last: 1, of: 2 })
  expect(invalidated).toEqual([])
  await fireAfter()
  expect(invalidated).toEqual(['ui.render'])
})

test('a tick\'s press scrolls the transcript to the prompt\'s row; a refusal marks the tick dotted and is toasted once a session', async () => {
  register(on as any, READING)
  transcript(LINEAR)
  await turnComplete()
  await drawRow('u1', 'say one', { first: 0, last: 1, of: 2 })
  await drawRow('r3', 'say three\nwith a second line', { first: 0, last: 1, of: 2 })
  // Both rows whole: the topmost, the first prompt, is being read, so its tick is no Button.
  const tree = await band()
  expect(rail(tree)).toEqual(['\u2503', '\u2502', '\u2502', '\u2502'])
  await tickButtons(tree)[0].props.onPress()
  expect(scrolls).toEqual([{ to: { requestId: 'u2' }, block: 'start' }])
  scrollResult = { deny: 'the window moved meanwhile' }
  await tickButtons(tree)[1].props.onPress()
  await tickButtons(tree)[1].props.onPress()
  expect(scrolls.slice(1)).toEqual([{ to: { requestId: 'r3' }, block: 'start' }, { to: { requestId: 'r3' }, block: 'start' }])
  expect(toasts).toEqual(['cs: the window moved meanwhile'])
  expect(rail(await band())).toEqual(['\u2503', '\u2502', '\u2506', '\u2502'])
})

test('a prompt no row has drawn since a resume is dim, and its press says so once', async () => {
  transcript(LINEAR)
  await turnComplete()
  scrollResult = { deny: 'nothing drawn under that requestId' }
  const tree = await band()
  await tickButtons(tree)[1].props.onPress()
  await tickButtons(tree)[1].props.onPress()
  expect(scrolls).toEqual([{ to: { requestId: 'u2' }, block: 'start' }, { to: { requestId: 'u2' }, block: 'start' }])
  expect(toasts).toEqual(['cs: that prompt is not on screen yet'])
  expect(rail(await band())).toEqual(['\u2502', '\u2502', '\u2502', '\u2503'])
})

test('/cs next, prev, first, last and N move along the rail from the prompt being read', async () => {
  await sessionStart()
  expect(commands.find(c => c.name === 'cs')).toMatchObject({ immediate: true })
  expect(await cs('next')).toEqual({ text: 'cs: the rail has no prompts' })
  transcript(LINEAR)
  await turnComplete()
  for (const [id, text] of [['u1', 'say one'], ['u2', 'say two'], ['u3', 'say three\nwith a second line'], ['u4', '  say four  ']]) await drawRow(id, text, null)
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  expect(await cs('next')).toEqual({})
  expect(await cs('prev')).toEqual({})
  expect(await cs('first')).toEqual({})
  expect(await cs('last')).toEqual({})
  expect(await cs('3')).toEqual({})
  expect(scrolls.map(s => s.to.requestId)).toEqual(['u3', 'u1', 'u1', 'u4', 'u3'])
  expect(await cs('9')).toEqual({ text: 'cs: the rail has 4 prompts' })
  expect(await cs('sideways')).toEqual({ text: 'usage: /cs next|prev|first|last|<n>' })
  await drawRow('u4', '  say four  ', { first: 0, last: 1, of: 2 })
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  await drawRow('u1', 'say one', { first: 4, last: 6, of: 7 })
  expect(await cs('prev')).toEqual({ text: 'cs: no prompt before this one' })
})

test('rows drawn where the band is not the lead\'s, or under a survey, redraw once at most: the read tick settles even when the rail is not drawn', async () => {
  register(on as any, READING)
  transcript(LINEAR)
  await turnComplete()
  const pending = () => timers.filter(t => t.kind === 'after' && !t.cancelled).length
  sessionId = 'uuid-teammate'
  await band()
  const before = pending()
  for (let i = 0; i < 3; i++) await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  expect(pending()).toBe(before + 1)
  await fireAfter()
  await band()
  for (let i = 0; i < 3; i++) await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  expect(pending()).toBe(0)
  sessionId = 'uuid-lead'
  await band({ hasSurvey: true })
  for (let i = 0; i < 3; i++) await drawRow('u1', 'say one', { first: 4, last: 6, of: 7 })
  expect(pending()).toBe(1)
  await fireAfter()
  await band({ hasSurvey: true })
  for (let i = 0; i < 3; i++) await drawRow('u1', 'say one', { first: 4, last: 6, of: 7 })
  expect(pending()).toBe(0)
})

test('with no prompt row left in the viewport, the read tick stays on the prompt last read, not the newest', async () => {
  register(on as any, READING)
  transcript(LINEAR)
  await turnComplete()
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  await fireAfter()
  expect(rail(await band())).toEqual(['│', '┃', '│', '│'])
  await drawRow('u2', 'say two', null)
  await fireAfter()
  expect(rail(await band())).toEqual(['│', '┃', '│', '│'])
  expect(await cs('prev')).toEqual({})
  expect(scrolls.map(s => s.to.requestId)).toEqual(['u1'])
})

test('a prompt whose row has not been drawn is matched by its text only when that text is its alone', async () => {
  register(on as any, READING)
  transcript([
    prompt('u1', null, 'continue'), reply('a1', 'u1'),
    prompt('u2', 'a1', 'continue'), reply('a2', 'u2'),
    prompt('u3', 'a2', 'continue'), reply('a3', 'u3'),
    prompt('u4', 'a3', 'say four'), reply('a4', 'u4'),
  ])
  await turnComplete()
  await drawRow('u3', 'continue', { first: 0, last: 1, of: 2 })
  await drawRow('row-of-u4', 'say four', null)
  await fireAfter()
  expect(rail(await band())).toEqual(['│', '│', '┃', '│'])
  expect(await cs('1')).toEqual({})
  expect(await cs('4')).toEqual({})
  expect(scrolls.map(s => s.to.requestId)).toEqual(['u1', 'row-of-u4'])
})

test('an interrupt row is not a prompt, and a prompt that opens with a tag on a line of its own words is', () => {
  const rows = [
    prompt('u1', null, 'say one'), reply('a1', 'u1'),
    prompt('i1', 'a1', [{ type: 'text', text: '[Request interrupted by user for tool use]' }]), reply('a2', 'i1'),
    prompt('i2', 'a2', '[Request interrupted by user]'), reply('a3', 'i2'),
    prompt('u2', 'a3', '<div class="x"> renders empty'), reply('a4', 'u2'),
    prompt('f1', 'a4', '<teammate-message teammate_id="x">\nhello\n</teammate-message>'), reply('a5', 'f1'),
    prompt('f2', 'a5', '<local-command-stdout>ok</local-command-stdout>'), reply('a6', 'f2'),
  ]
  expect(parsePrompts(rows.join('\n')).map(p => p.text)).toEqual(['say one', '<div class="x"> renders empty'])
})

test('a /clear empties the rail: the next conversation draws none of the last one\'s prompts', async () => {
  transcript(LINEAR)
  await turnComplete()
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  const e = { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }
  invalidated = []
  expect(await hooks['command.run:clear']($, e, async () => ({ text: '' }))).toEqual({ text: '' })
  expect(invalidated).toEqual(['ui.render'])
  expect(rail(await band())).toEqual([])
  expect(await cs('next')).toEqual({ text: 'cs: the rail has no prompts' })
  await turnComplete()
  expect(rail(await band())).toEqual(['│', '│', '│', '┃'])
})

test('a line too narrow for any tick, with nothing else to say, draws nothing', async () => {
  transcript(LINEAR)
  await turnComplete()
  expect(await band({ bodyColumns: 4 })).toBe(DRAWN)
})

test('the rail follows the words on the band line, as upright bars, and the read prompt follows the rail', async () => {
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  transcript(LINEAR)
  percent = 80
  await turnComplete()
  const tree = await band()
  const line = boxes(tree).find((b: any) => b.props.key === 'cs-rotate-band')
  const kids = (line.children ?? []).flat().filter((c: any) => c && typeof c === 'object')
  expect(kids[kids.length - 2].props.key).toBe('cs-rail')
  expect(texts(kids[kids.length - 1]).includes(gapLabel(tree))).toBe(true)
  expect(boxes(tree).some((b: any) => b.props.flexGrow !== undefined)).toBe(false)
  expect(rail(tree)).toEqual(['│', '│', '│', '┃'])
  // `● ` (2), `ctrl+x  1 rotate  ·  2 wrap` (27) and its three-cell gap leave the label 110 - 2 - 2 - 30 - 4 - 2.
  expect(textOf(gapLabel(tree))).toBe('#4 say four'.padEnd(70))
})

test('the focus ring never lands on a rail tick: the keyboard route is /cs', async () => {
  const e = (element: string) => ({ component: 'AbovePrompt', requestId: 'band', plugin: 'cs', element, origin: { kind: 'person' } })
  expect(await hooks['ui.focus:AbovePrompt']($, e('cs-rail-2'), async () => ({}))).toEqual({ deny: 'cs: the rail takes clicks and /cs, not the focus ring' })
  expect(await hooks['ui.focus:AbovePrompt']($, e('cs-rotate'), async () => ({ moved: true }))).toEqual({ moved: true })
})

// After the rail the band names a prompt: the one being read, dim italic; a
// bar under the pointer swaps in its own.
const gapLabel = (tree: any) => texts(tree).find((t: any) => t.props.italic && t.props.dimColor)

test('after the bars the band names the prompt being read, dim italic, whether or not words stand before them', async () => {
  register(on as any, READING)
  transcript(LINEAR)
  await turnComplete()
  const tree = await band()
  // The two-column inset and 110 columns leave 108, the mark 106; four bars and a two-cell gap leave the label 100.
  expect(textOf(gapLabel(tree))).toBe('#4 say four'.padEnd(100))
  const line = boxes(tree).find((b: any) => b.props.key === 'cs-rotate-band')
  const kids = (line.children ?? []).flat().filter((c: any) => c && typeof c === 'object')
  expect(kids.slice(-2).map((k: any) => k.props.key ?? 'label')).toEqual(['cs-rail', 'label'])
  expect(texts(kids[kids.length - 1]).filter((t: any) => t.props.dimColor).map(textOf)).toEqual(['#4 say four'.padEnd(100)])
  // A row reporting moves the label with the read bar.
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  expect(textOf(gapLabel(await band()))).toBe('#2 say two'.padEnd(100))
  // A word on the left moves the bars and the prompt along: `▤ queue 1 · start` (17) and its three-cell gap leave 80.
  queueTasks(1)
  expect(textOf(gapLabel(await band()))).toBe('#2 say two'.padEnd(80))
})

test('each bar under the pointer swaps its own prompt into the gap, italic, covering the read one', async () => {
  transcript(LINEAR)
  await turnComplete()
  const tree = await band()
  // Bar i heats group cs-rail-<i>; the read bar is a Text the label already names.
  expect(tickButtons(tree).map((b: any) => b.props.hover)).toEqual([0, 1, 2].map(i => ({ scope: `cs-rail-${i}`, dimColor: false })))
  const cards = boxes(tree).filter((b: any) => b.props.display === 'none')
  expect(cards.map((c: any) => c.props)).toEqual([0, 1, 2].map(i => ({
    position: 'absolute', top: 0, left: 0, display: 'none', hover: { scope: `cs-rail-${i}`, display: 'flex' },
  })))
  expect(cards.map((c: any) => texts(c).map((t: any) => [textOf(t), t.props]))).toEqual([
    [['#1 say one'.padEnd(100), { italic: true, wrap: 'truncate-end' }]],
    [['#2 say two'.padEnd(100), { italic: true, wrap: 'truncate-end' }]],
    [['#3 say three'.padEnd(100), { italic: true, wrap: 'truncate-end' }]],
  ])
  // The cards sit in the label's own Box, so a card covers the read prompt cell for cell.
  const labelBox = boxes(tree).find((b: any) => b.props.width === 100)
  expect(boxes(labelBox).filter((b: any) => b.props.display === 'none')).toHaveLength(3)
})

test('the gap\'s prompt is cut to the gap with an ellipsis; a gap under ten cells names none and the bars heat nothing', async () => {
  transcript([...LINEAR, prompt('u5', 'a4', 'x'.repeat(40))])
  await turnComplete()
  // 29 columns: 27 after the inset, 25 after the mark, five bars and the two-cell gap leave 18.
  const cut = await band({ bodyColumns: 29 })
  expect(textOf(gapLabel(cut))).toBe(`#5 ${'x'.repeat(14)}…`)
  expect(texts(boxes(cut).find((b: any) => b.props.hover?.scope === 'cs-rail-0')).map(textOf)).toEqual(['#1 say one'.padEnd(18)])
  // 21 columns leave exactly ten.
  expect(textOf(gapLabel(await band({ bodyColumns: 21 })))).toBe(`#5 ${'x'.repeat(6)}…`)
  // 20 leave nine: the bars alone, no card, no hover group.
  const bare = await band({ bodyColumns: 20 })
  expect(gapLabel(bare)).toBeUndefined()
  expect(boxes(bare).filter((b: any) => b.props.display === 'none')).toEqual([])
  expect(tickButtons(bare).map((b: any) => b.props.hover)).toEqual([undefined, undefined, undefined, undefined])
  expect(rail(bare)).toEqual(['│', '│', '│', '│', '┃'])
})

test('a rail past its budget takes the whole gap: no prompt is named beside a collapsed run', async () => {
  register(on as any, UNCAPPED)
  const many = [prompt('u1', null, 'p1')]
  for (let i = 2; i <= 30; i++) many.push(reply(`a${i - 1}`, `u${i - 1}`), prompt(`u${i}`, `a${i - 1}`, `p${i}`))
  transcript(many)
  await turnComplete()
  // 29 columns leave 25 cells after the mark for 30 bars: `…7` and 23 bars, no gap.
  const tree = await band({ bodyColumns: 29 })
  expect(rail(tree)[0]).toBe('…7')
  expect(gapLabel(tree)).toBeUndefined()
  expect(boxes(tree).filter((b: any) => b.props.display === 'none')).toEqual([])
  // 40 leave 36: every bar, the two-cell gap and four cells, under ten, so none either.
  expect(gapLabel(await band({ bodyColumns: 40 }))).toBeUndefined()
  // 46 leave ten.
  expect(textOf(gapLabel(await band({ bodyColumns: 46 })))).toBe('#30 p30   ')
})

// The desktop app paints a card over the line without hiding what is under it
// (prompt-rail's CHANGELOG), so the two prompts would read as one.
test('off the terminal the gap names the prompt being read and draws no hover cards over it', async () => {
  transcript(LINEAR)
  await turnComplete()
  for (const surface of ['desktop', 'vscode', 'mobile']) {
    const tree = await band({}, surface)
    expect(textOf(gapLabel(tree))).toBe('#4 say four'.padEnd(100))
    expect(boxes(tree).filter((b: any) => b.props.display === 'none')).toEqual([])
    expect(tickButtons(tree).map((b: any) => b.props.hover)).toEqual([undefined, undefined, undefined])
  }
})

// The gap is counted in terminal cells: a wide character takes two, and a cut
// never splits one.
test('the gap\'s prompt is measured and cut in cells: wide characters take two, an emoji is never split', async () => {
  transcript([...LINEAR, prompt('u5', 'a4', '\u4e00'.repeat(60))])
  await turnComplete()
  // Five bars leave 99 cells: `#5 ` and 47 two-cell characters are 97, a 48th would pass the 98 left before `…`.
  expect(textOf(gapLabel(await band()))).toBe(`#5 ${'\u4e00'.repeat(47)}\u2026 `)
  transcript([...LINEAR, prompt('u5', 'a4', `${'x'.repeat(13)}\u{1F600}tail`)], 2)
  await turnComplete()
  // 18 cells: `#5 ` and 13 x are 16, the emoji would pass the 17 left before `…`.
  const cut = textOf(gapLabel(await band({ bodyColumns: 29 })))
  expect(cut).toBe(`#5 ${'x'.repeat(13)}\u2026 `)
  expect(cut.isWellFormed()).toBe(true)
  // A Text the engine measures wider than this count would wrap the band onto a second line.
  expect(gapLabel(await band()).props.wrap).toBe('truncate-end')
})

test('the rail and the prompt keep their margins: three cells after the words, two after the bars', async () => {
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  transcript(LINEAR)
  await turnComplete()
  const margins = (tree: any) => {
    const railBox = boxes(tree).find((b: any) => b.props.key === 'cs-rail')
    const labelBox = boxes(tree).find((b: any) => b.props.width !== undefined && texts(b).includes(gapLabel(tree)))
    return [railBox.props.marginLeft, labelBox?.props.marginLeft]
  }
  expect(margins(await band())).toEqual([0, 2])
  percent = 80
  expect(margins(await band())).toEqual([3, 2])
  // No room to name a prompt: the bars alone, three cells after the words.
  expect(margins(await band({ bodyColumns: 42 }))).toEqual([3, undefined])
})

// ---------------------------------------------------------------------------
// The features word: the state of the session's feature worktrees, from
// `cs <base> -features --porcelain` (task branch ahead merged ff wt_dirty
// untracked base_dirty lock state), on the band's left after the rule.

const feature = (task: string, ahead: number, state: string) =>
  [task, `cs/${task}`, String(ahead), '0', '1', '0', '0', '0', 'none', state].join('\t')
const porcelain = (...records: string[]) => { runResult = { exitCode: 0, stdout: records.map(r => `${r}\n`).join(''), stderr: '' } }
const featureRuns = () => runs.filter(r => r.argv[2] === '-features')
const featuresKey = (tree: any) => buttons(tree).find((b: any) => b.props.key === 'cs-features')
// The turn end reads cs without waiting on it; every fake answers at once, so
// one macrotask lets that reading finish.
const settled = () => new Promise(resolve => setTimeout(resolve, 0))
const featuresTurn = async () => { await turnComplete(); await settled() }
// A feature's directory at the sessions root, as cs names it: `<base>@<task>`.
const featureDir = (task: string, base = 'work') => { files[`/home/.claude-sessions/${base}@${task}`] = '' }

test('a base with one feature ready names it on the left, and a press runs /finish on it', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  expect(featureRuns().map(r => r.argv)).toEqual([['/opt/cs/bin/cs', 'work', '-features', '--porcelain']])
  const tree = await band()
  expect(featuresKey(tree).props).toMatchObject({ key: 'cs-features', plain: true, label: '1 feature · fix-auth ready' })
  expect(bandBody(tree).slice(0, 2).map((k: any) => k.type === 'Button' ? k.props.key : textOf(texts(k)[0]))).toEqual(['\u25cf', 'cs-features'])
  await featuresKey(tree).props.onPress()
  expect(ran).toEqual([{ command: 'finish', args: 'fix-auth' }])
})

test('a base names its one ready feature among several, counts two or more ready with a bare /finish, and names none with no press', async () => {
  featureDir('fix-auth'); featureDir('docs'); featureDir('perf')
  porcelain(feature('fix-auth', 2, 'dirty'), feature('docs', 1, 'ready'), feature('perf', 4, 'merged'))
  await featuresTurn()
  let tree = await band()
  expect(featuresKey(tree).props.label).toBe('3 features · docs ready')
  await featuresKey(tree).props.onPress()
  porcelain(feature('fix-auth', 2, 'ready'), feature('docs', 1, 'ready'), feature('perf', 4, 'merged'))
  await featuresTurn()
  tree = await band()
  expect(featuresKey(tree).props.label).toBe('3 features · 2 ready')
  await featuresKey(tree).props.onPress()
  expect(ran).toEqual([{ command: 'finish', args: 'docs' }, { command: 'finish', args: '' }])
  porcelain(feature('fix-auth', 2, 'dirty'), feature('docs', 0, 'ready'), feature('perf', 4, 'staged'))
  await featuresTurn()
  tree = await band()
  expect(featuresKey(tree)).toBeUndefined()
  expect(restingWords(tree)).toEqual(['\u25cf', '3 features · none ready'])
  expect(texts(tree).find((t: any) => textOf(t) === '3 features · none ready').props).toEqual({ dimColor: true })
})

test('one feature not ready says its own state; ready with nothing ahead of the base reads no commits', async () => {
  featureDir('fix-auth')
  for (const [ahead, state, word] of [[2, 'dirty', 'dirty'], [0, 'ready', 'no commits'], [5, 'base-dirty', 'base-dirty'], [1, 'vault-locked', 'vault-locked']] as const) {
    porcelain(feature('fix-auth', ahead, state))
    await featuresTurn()
    const tree = await band()
    expect(restingWords(tree)).toEqual(['\u25cf', `1 feature · fix-auth ${word}`])
    expect(featuresKey(tree)).toBeUndefined()
  }
})

test('a feature session draws no features word and asks cs nothing: /finish lands a feature from its base', async () => {
  cwdPath = '/feat'
  realPaths['/feat'] = '/feat'; realPaths['/home/.claude-sessions/work@fix-auth'] = '/feat'
  existing.add('/feat/.cs/local')
  files['/feat/.cs/local/state'] = 'session_name: work@fix-auth\nclaude_session_id: uuid-lead\n'
  porcelain(feature('fix-auth', 3, 'ready'))
  // The rail draws here, so the band is this conversation's to draw.
  files['/home/.claude/projects/-feat/uuid-lead.jsonl'] = `${LINEAR.join('\n')}\n`
  await featuresTurn()
  expect(rail(await band())).toHaveLength(4)
  expect(featureRuns()).toEqual([])
  expect(timers.filter(t => t.kind === 'every' && t.ms === 30000)).toEqual([])
  expect(restingWords(await band())).toEqual(['\u25cf', '\u2503', '#4 say four'.padEnd(100)])
})

test('a cs that fails, cannot start, or prints a record the band cannot read draws no word and is logged once each', async () => {
  featureDir('fix-auth')
  const record = feature('fix-auth', 3, 'ready')
  const answers: any[] = [
    { exitCode: 2, stdout: '', stderr: 'error: no such session\n' },
    { exitCode: 2, stdout: '', stderr: 'error: no such session\n' },
    new Error('spawn ENOENT'),
    { exitCode: 0, stdout: `${record}\textra\n`, stderr: '' },
    { exitCode: 0, stdout: record.replace('\t3\t', '\tthree\t') + '\n', stderr: '' },
    { exitCode: 0, stdout: record.replace(/ready$/, 'landed') + '\n', stderr: '' },
  ]
  for (const answer of answers) {
    runResult = answer
    await featuresTurn()
    expect(await band()).toBe(DRAWN)
  }
  expect(logs).toEqual([
    'cs work -features exited 2: error: no such session',
    'cs work -features did not answer: spawn ENOENT',
    `cs work -features gave a record the band cannot read: ${record}\textra`,
    `cs work -features gave a record the band cannot read: ${record.replace('\t3\t', '\tthree\t')}`,
    `cs work -features gave a record the band cannot read: ${record.replace(/ready$/, 'landed')}`,
  ])
})

test('the features word keeps the left beside the key words, yields to a running gate, and the gap shrinks by its cells', async () => {
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  transcript(LINEAR)
  await featuresTurn()
  // `● ` (2), `1 feature · fix-auth ready` (26) and its three-cell gap leave the label 110 - 2 - 2 - 29 - 4 - 2.
  let tree = await band()
  expect(textOf(gapLabel(tree))).toBe('#4 say four'.padEnd(71))
  percent = 80
  tree = await band()
  const order = bandBody(tree).map((k: any) => k.type === 'Button' ? k.props.key : k.type === 'Text' ? textOf(k) : texts(k).map(textOf).join(''))
  expect(order.slice(0, 6)).toEqual(['\u25cf', 'cs-features', '  \u00b7  ', 'ctrl+x', '1', 'cs-rotate'])
  // The mark (2), the word, `  ·  ` (5) and `ctrl+x  1 rotate  ·  2 wrap` (27) and the gap's three leave the label 108 - 2 - 61 - 4 - 2.
  expect(textOf(gapLabel(tree))).toBe('#4 say four'.padEnd(39))
  percent = undefined
  queueTasks(1)
  tree = await band()
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-features', 'cs-queue', 'cs-rail-0', 'cs-rail-1', 'cs-rail-2'])
  delete files[`${QDIR}/0000000001-seed`]
  livePids.add('4242')
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 3 }))
  await watchTick()
  tree = await band({ isWorking: true })
  expect(featuresKey(tree)).toBeUndefined()
  expect(restingWords(tree).slice(0, 2)).toEqual(['\u25cf', 'finishing fix-auth \u00b7 gate 3s'])
})

test('an idle band asks cs again every 30 s, never while a turn runs, never twice at once, and not at all with no feature', async () => {
  await featuresTurn()
  expect(timers.filter(t => t.kind === 'every' && t.ms === 30000)).toEqual([])
  expect(featureRuns()).toEqual([])
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'dirty'))
  await featuresTurn()
  await featuresTurn()
  const clocks = timers.filter(t => t.kind === 'every' && t.ms === 30000)
  expect(clocks).toHaveLength(1)
  expect(featureRuns()).toHaveLength(2)
  await band({ isWorking: true })
  await clocks[0].fn()
  expect(featureRuns()).toHaveLength(2)
  await band()
  porcelain(feature('fix-auth', 3, 'ready'))
  await clocks[0].fn()
  expect(featureRuns()).toHaveLength(3)
  expect(featuresKey(await band()).props.label).toBe('1 feature · fix-auth ready')
  // A reading still running is not doubled by the next tick.
  const run = $.process.run
  let release: () => void = () => {}
  $.process.run = async (argv: string[], init: any) => {
    if (argv[2] !== '-features') return run(argv, init)
    runs.push({ argv, init })
    await new Promise<void>(r => { release = r })
    return { exitCode: 0, stdout: `${feature('fix-auth', 3, 'ready')}\n`, stderr: '' }
  }
  try {
    const first = clocks[0].fn()
    for (let i = 0; i < 100 && featureRuns().length < 4; i++) await Promise.resolve()
    expect(featureRuns()).toHaveLength(4)
    await clocks[0].fn()
    expect(featureRuns()).toHaveLength(4)
    release()
    await first
  } finally {
    $.process.run = run
  }
  expect(featureRuns().at(-1)?.init).toEqual({ timeoutMs: 20000 })
})

test('a survey owns the band: no features word under one', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
})

test('while a turn runs the features word draws dim with no press; one press is all a word takes until cs answers again', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  let tree = await band({ isWorking: true })
  expect(featuresKey(tree)).toBeUndefined()
  expect(texts(tree).find((t: any) => textOf(t) === '1 feature · fix-auth ready').props).toEqual({ dimColor: true })
  tree = await band()
  await featuresKey(tree).props.onPress()
  tree = await band()
  expect(featuresKey(tree)).toBeUndefined()
  expect(restingWords(tree)).toEqual(['\u25cf', '1 feature · fix-auth ready'])
  expect(ran).toEqual([{ command: 'finish', args: 'fix-auth' }])
  await featuresTurn()
  expect(featuresKey(await band())).toBeDefined()
})

test('a /finish the engine refuses is toasted, not thrown', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  $.command.run = async (args: any) => { ran.push(args); throw new Error('a turn is running') }
  try {
    await featuresKey(await band()).props.onPress()
  } finally {
    $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  }
  expect(toasts).toEqual(['cs: /finish fix-auth did not run: a turn is running'])
})

test('a base with no feature asks cs nothing and runs no clock; the turn a feature is made in reads it', async () => {
  await featuresTurn()
  expect(timers.filter(t => t.kind === 'every' && t.ms === 30000)).toEqual([])
  expect(featureRuns()).toEqual([])
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 0, 'ready'))
  await featuresTurn()
  expect(restingWords(await band())).toEqual(['\u25cf', '1 feature \u00b7 fix-auth no commits'])
  expect(timers.filter(t => t.kind === 'every' && t.ms === 30000)).toHaveLength(1)
})

test('the turn end does not wait on cs: it returns while the features reading still runs, and the band redraws when cs answers', async () => {
  featureDir('fix-auth')
  const run = $.process.run
  let answer: () => void = () => {}
  $.process.run = async (argv: string[], init: any) => {
    if (argv[2] !== '-features') return run(argv, init)
    runs.push({ argv, init })
    await new Promise<void>(r => { answer = r })
    return { exitCode: 0, stdout: `${feature('fix-auth', 3, 'ready')}\n`, stderr: '' }
  }
  try {
    expect(await turnComplete()).toEqual({ text: 'ok' })
    await settled()
    expect(featureRuns()).toHaveLength(1)
    expect(featuresKey(await band())).toBeUndefined()
    invalidated = []
    answer()
    await settled()
  } finally {
    $.process.run = run
  }
  expect(invalidated).toEqual(['ui.render'])
  expect(featuresKey(await band()).props.label).toBe('1 feature · fix-auth ready')
})

// ---------------------------------------------------------------------------
// The band's left after its other words: the cs queue's count while its start
// key is not offered, then unread mail, when there are any.

test('tasks queued while the queue runs, or while a turn runs, draw a dim queue word where the start key would be', async () => {
  queueTasks(3)
  for (const state of ['armed\n', 'draining\n']) {
    files['/work/.cs/local/queue.state'] = state
    const tree = await band()
    expect(restingWords(tree)).toEqual(['\u25cf', '▤ queue 3'])
    expect(texts(tree)[1].props).toEqual({ dimColor: true })
    expect(buttons(tree)).toEqual([])
  }
  files['/work/.cs/local/queue.state'] = 'idle\n'
  expect(restingWords(await band({ isWorking: true }))).toEqual(['\u25cf', '▤ queue 3'])
  const idle = await band()
  expect(queueKey(idle).props.label).toBe('▤ queue 3 · start')
  expect(restingWords(idle)).toEqual(['\u25cf'])
  files['/work/.cs/local/queue.state'] = 'armed\n'
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
})

test('the queue word follows the key words, a separator before it', async () => {
  queueTasks(2)
  files['/work/.cs/local/queue.state'] = 'armed\n'
  expect(restingWords(await band())).toEqual(['\u25cf', '▤ queue 2'])
  percent = 40
  const tree = await band()
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap'])
  expect(restingWords(tree).slice(-2)).toEqual(['  ·  ', '▤ queue 2'])
})

// cs delivers each mail as one file in the mailbox's new/, where it stays
// until `cs -msg` reads it, behind .cs/private in an encrypted session.
const MAIL = '/work/.cs/local/mail'

test('unread mail draws a dim mail word, counting only the .json files directly in new/', async () => {
  files[`${MAIL}/new/1-a.json`] = '{}'
  files[`${MAIL}/new/2-b.json`] = '{}'
  files[`${MAIL}/new/3-c.tmp`] = '{}'
  files[`${MAIL}/cur/0-z.json`] = '{}'
  const tree = await band()
  expect(restingWords(tree)).toEqual(['\u25cf', 'mail 2'])
  expect(texts(tree)[1].props).toEqual({ dimColor: true })
  expect(buttons(tree)).toEqual([])
  delete files[`${MAIL}/new/1-a.json`]; delete files[`${MAIL}/new/2-b.json`]
  expect(await band()).toBe(DRAWN)
})

test('an encrypted session counts its mail behind .cs/private', async () => {
  existing.add('/work/.cs/private')
  files[`${MAIL}/new/1-a.json`] = '{}'
  files[`${MAIL}/new/2-b.json`] = '{}'
  files['/work/.cs/private/mail/new/3-c.json'] = '{}'
  expect(restingWords(await band())).toEqual(['\u25cf', 'mail 1'])
})

test('the mail word comes last, after the queue and key words, and never under a survey or in a teammate', async () => {
  queueTasks(2)
  files['/work/.cs/local/queue.state'] = 'armed\n'
  files[`${MAIL}/new/1-a.json`] = '{}'
  expect(restingWords(await band())).toEqual(['\u25cf', '▤ queue 2', '  ·  ', 'mail 1'])
  files['/work/.cs/local/queue.state'] = 'idle\n'
  const keyed = await band()
  expect(buttons(keyed).map((b: any) => b.props.key)).toEqual(['cs-queue'])
  expect(restingWords(keyed)).toEqual(['\u25cf', '  ·  ', 'mail 1'])
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
})

test('the queue and mail words take their cells from the gap beside the rail', async () => {
  transcript(LINEAR)
  await turnComplete()
  queueTasks(2)
  files['/work/.cs/local/queue.state'] = 'armed\n'
  files[`${MAIL}/new/1-a.json`] = '{}'
  const tree = await band()
  expect(rail(tree)).toEqual(['│', '│', '│', '┃'])
  // `● ` (2), `▤ queue 2  ·  mail 1` (20) and its three-cell gap leave the label 110 - 2 - 2 - 23 - 4 - 2.
  expect(textOf(gapLabel(tree))).toBe('#4 say four'.padEnd(77))
  percent = 80
  // No chord bound: `rotate  ·  wrap  ·  ▤ queue 2  ·  mail 1` (40): 110 - 2 - 2 - 43 - 4 - 2.
  expect(textOf(gapLabel(await band()))).toBe('#4 say four'.padEnd(57))
})

test('the mail word counts neither a stray file nor a directory in new/', async () => {
  files[`${MAIL}/new/1-a.json`] = '{}'
  files[`${MAIL}/new/.DS_Store`] = ''
  files[`${MAIL}/new/sub.json/2-b.json`] = '{}'
  expect(restingWords(await band())).toEqual(['\u25cf', 'mail 1'])
})

// ---------------------------------------------------------------------------
// The band's /config rows: cs.bandPrompt picks the prompt it names (the newest,
// or the one being read), cs.bandBars the most bars before older prompts fold.

test('by default the band names the newest prompt and draws its bar thick, wherever the reader is; a scroll redraws nothing', async () => {
  transcript(LINEAR)
  await turnComplete()
  await band()
  invalidated = []
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  await fireAfter()
  expect(invalidated).toEqual([])
  const tree = await band()
  expect(textOf(gapLabel(tree))).toBe('#4 say four'.padEnd(100))
  expect(rail(tree)).toEqual(['│', '│', '│', '┃'])
})

test('with cs.bandPrompt read the band names the prompt being read and draws its bar thick', async () => {
  register(on as any, { ...OPTIONS, bandPrompt: 'read' })
  transcript(LINEAR)
  await turnComplete()
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  const tree = await band()
  expect(textOf(gapLabel(tree))).toBe('#2 say two'.padEnd(100))
  expect(rail(tree)).toEqual(['│', '┃', '│', '│'])
})

test('at most cs.bandBars bars draw; older prompts fold into …N and the prompt is still named', async () => {
  const many = [prompt('u1', null, 'p1')]
  for (let i = 2; i <= 30; i++) many.push(reply(`a${i - 1}`, `u${i - 1}`), prompt(`u${i}`, `a${i - 1}`, `p${i}`))
  transcript(many)
  await turnComplete()
  let tree = await band()
  expect(rail(tree)).toEqual(['…20', ...Array(9).fill('│'), '┃'])
  // `…20` and ten bars are 13 cells: 108 - 2 - 13 - 2.
  expect(textOf(gapLabel(tree))).toBe('#30 p30'.padEnd(91))
  register(on as any, { ...OPTIONS, bandBars: 3 })
  transcript(many, 2)
  await turnComplete()
  tree = await band()
  expect(rail(tree)).toEqual(['…27', '│', '│', '┃'])
  // A folded prompt has no bar to hover, so no card either.
  expect(boxes(tree).filter((b: any) => b.props.display === 'none')).toHaveLength(2)
})

test('/config refuses a band value the band cannot draw, where it is typed, and passes every other row', async () => {
  const set = (key: string, value: unknown, plugin = 'cs') => hooks['config.set']($,
    { key, value, previous: 10, provider: { plugin, tier: 'user' }, origin: { kind: 'composer' } },
    async (e: any) => ({ value: e.value }))
  for (const value of [0, -2, 2.5]) {
    expect(await set('cs.bandBars', value)).toEqual({ deny: `cs.bandBars is the most bars the band draws, a whole number of 1 or more; got ${value}` })
  }
  expect(await set('cs.bandPrompt', 'first')).toEqual({ deny: 'cs.bandPrompt is latest or read; got first' })
  expect(await set('cs.bandPrompts', 'yes')).toEqual({ deny: 'cs.bandPrompts is on or off; got yes' })
  expect(await set('cs.bandPrompts', true)).toEqual({ value: true })
  expect(await set('cs.bandBars', 4)).toEqual({ value: 4 })
  expect(await set('cs.bandPrompt', 'read')).toEqual({ value: 'read' })
  expect(await set('other.bandBars', 0, 'other')).toEqual({ value: 0 })
  expect(await set('theme', 'dark', 'engine')).toEqual({ value: 'dark' })
})

test('a bad band value already stored draws no bars and says so once; the rest of the mod still runs', async () => {
  expect(() => register(on as any, { ...OPTIONS, bandBars: 0 })).not.toThrow()
  transcript(LINEAR)
  await turnComplete()
  percent = 80
  // A teammate's band, like any the mod stays silent in, says nothing.
  sessionId = 'uuid-teammate'
  await band()
  expect(toasts).toEqual([])
  sessionId = 'uuid-lead'
  const tree = await band()
  expect(rail(tree)).toEqual([])
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap'])
  await band()
  expect(toasts).toEqual(['cs: the band draws no prompt bars: cs.bandBars is the most bars the band draws, a whole number of 1 or more; got 0. Set it in /config.'])
})

test('by plugin.json\'s defaults the band draws no prompt bars and names no prompt; its other words still draw', async () => {
  const manifest = JSON.parse(readFileSync(new URL('../.claude-plugin/plugin.json', import.meta.url), 'utf8'))
  const defaults = Object.fromEntries(Object.entries(manifest.userConfig).map(([field, spec]: [string, any]) => [field, spec.default]))
  expect(defaults).toEqual({ bandPrompts: false, bandPrompt: 'latest', bandBars: 10 })
  register(on as any, defaults)
  transcript(LINEAR)
  await turnComplete()
  expect(await band()).toBe(DRAWN)
  percent = 80
  const tree = await band()
  expect(rail(tree)).toEqual([])
  expect(gapLabel(tree)).toBeUndefined()
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap'])
  expect(toasts).toEqual([])
})

test('with the prompt bars off, a scroll redraws nothing, whichever prompt the band would name', async () => {
  register(on as any, { ...READING, bandPrompts: false })
  transcript(LINEAR)
  await turnComplete()
  await band()
  invalidated = []
  await drawRow('u1', 'say one', { first: 0, last: 1, of: 2 })
  await fireAfter()
  expect(invalidated).toEqual([])
})

// ---------------------------------------------------------------------------
// The mark: one `●` first on the band, its colour saying what is due: blue
// while a /finish gate or the cs queue runs, amber while a rotation is due,
// green otherwise.

const BLUE = 'rgb(106,155,204)'
const GREEN = 'rgb(22,163,74)'
const AMBER_ON_LIGHT = 'rgb(180,83,9)'
const AMBER_ON_DARK = 'rgb(253,230,138)'
// The band's first element as drawn: the mark's Box and the Texts in it, or undefined when it is not the mark.
const markOf = (tree: any) => {
  const first = bandBody(tree)[0]
  if (first?.props?.key !== 'cs-mark') return undefined
  return { box: first.props, texts: texts(first).map((t: any) => ({ text: textOf(t), ...t.props })) }
}
const marked = (color: string) => ({ box: { key: 'cs-mark', marginRight: 1 }, texts: [{ text: '●', color }] })
const gateRuns = async () => {
  livePids.add('4242')
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 3 }))
  await watchTick()
}

test('with nothing due the band starts with a green mark, one cell and a space before its first word', async () => {
  files[`${MAIL}/new/1-a.json`] = '{}'
  percent = 39
  const tree = await band()
  expect(markOf(tree)).toEqual(marked(GREEN))
  expect(words(tree)).toEqual(['●', 'mail 1'])
})

test('a rotation due draws the mark amber: past the threshold, or with a handoff armed below it', async () => {
  envVars.HOME = '/home'
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  percent = 40
  const tree = await band()
  expect(markOf(tree)).toEqual(marked(AMBER_ON_LIGHT))
  expect(words(tree)).toEqual(['●', 'ctrl+x', '1', '  ·  ', '2'])
  percent = 3
  arm()
  expect(markOf(await band())).toEqual(marked(AMBER_ON_LIGHT))
  // The armed handoff stays due while a turn runs; a mail word keeps the line up.
  files[`${MAIL}/new/1-a.json`] = '{}'
  expect(markOf(await band({ isWorking: true }))).toEqual(marked(AMBER_ON_LIGHT))
})

test('the amber mark pivots as the count does: the measured background first, then the theme', async () => {
  percent = 40
  envVars.CS_TERM_THEME = 'dark'
  expect(markOf(await band())).toEqual(marked(AMBER_ON_DARK))
  envVars.CS_TERM_BG_RGB = '252;247;229'
  expect(markOf(await band())).toEqual(marked(AMBER_ON_LIGHT))
  envVars.CS_TERM_THEME = 'light'
  envVars.CS_TERM_BG_RGB = '30;30;30'
  expect(markOf(await band())).toEqual(marked(AMBER_ON_DARK))
})

test('past the threshold the mark stays amber while a turn runs, though the keys are gone', async () => {
  files[`${MAIL}/new/1-a.json`] = '{}'
  percent = 40
  const tree = await band({ isWorking: true })
  expect(buttons(tree)).toEqual([])
  expect(markOf(tree)).toEqual(marked(AMBER_ON_LIGHT))
  percent = 39
  expect(markOf(await band({ isWorking: true }))).toEqual(marked(GREEN))
})

test('a running queue or /finish gate draws the mark blue', async () => {
  queueTasks(2)
  files['/work/.cs/local/queue.state'] = 'draining\n'
  const queued = await band()
  expect(markOf(queued)).toEqual(marked(BLUE))
  expect(words(queued)).toEqual(['●', '▤ queue 2'])
  // Tasks queued that nothing runs offer the start key: nothing runs yet.
  files['/work/.cs/local/queue.state'] = 'idle\n'
  expect(markOf(await band())).toEqual(marked(GREEN))
  delete files['/work/.cs/local/queue.state']
  for (const k of Object.keys(files)) if (k.startsWith(QDIR)) delete files[k]
  await gateRuns()
  const gated = await band({ isWorking: true })
  expect(markOf(gated)).toEqual(marked(BLUE))
  expect(words(gated)).toEqual(['●', 'finishing fix-auth · gate 3s'])
})

test('running outranks due: a gate or a running queue past the threshold draws the mark blue', async () => {
  percent = 80
  queueTasks(1)
  files['/work/.cs/local/queue.state'] = 'armed\n'
  expect(markOf(await band())).toEqual(marked(BLUE))
  delete files['/work/.cs/local/queue.state']
  await gateRuns()
  const tree = await band()
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap', 'cs-queue'])
  expect(markOf(tree)).toEqual(marked(BLUE))
})

test('under a survey the band draws no mark, even beside the gate word it still carries', async () => {
  percent = 90
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
  await gateRuns()
  const tree = await band({ hasSurvey: true })
  expect(words(tree)).toEqual(['finishing fix-auth · gate 3s'])
  expect(markOf(tree)).toBeUndefined()
  expect(JSON.stringify(tree)).not.toContain('●')
})

test('the mark takes two cells from the line: the bars move over and the named prompt gives them up', async () => {
  transcript(LINEAR)
  await turnComplete()
  // A rail alone: `● ` (2), four bars and the two-cell gap leave the label 110 - 2 - 2 - 4 - 2.
  const tree = await band()
  expect(bandBody(tree).map((c: any) => c.props.key ?? c.type)).toEqual(['cs-mark', 'cs-rail', 'Box'])
  expect(textOf(gapLabel(tree))).toBe('#4 say four'.padEnd(100))
  // 25 columns: 23 after the inset, the mark, four bars and the gap leave 15.
  expect(textOf(gapLabel(await band({ bodyColumns: 25 })))).toBe('#4 say four'.padEnd(15))
  // 20 leave ten, 19 nine: the bars alone.
  expect(textOf(gapLabel(await band({ bodyColumns: 20 })))).toBe('#4 say fo…')
  expect(gapLabel(await band({ bodyColumns: 19 }))).toBeUndefined()
})

// The engine flattens child lists and drops conditional empty children; the
// fixture's h keeps both, so snapshots compare the tree the engine draws.
function bandSnapshot(tree: any): unknown {
  if (Array.isArray(tree)) return tree.flat(Infinity).filter(child => child !== false && child !== undefined && child !== null).map(bandSnapshot)
  if (!tree || typeof tree !== 'object') return tree
  return { type: tree.type, props: tree.props, children: bandSnapshot(tree.children ?? []) }
}

const bandScenes: [string, () => void | Promise<void>, { isWorking?: boolean; hasSurvey?: boolean; bodyColumns?: number }?][] = [
  ['empty', () => {}],
  ['rotate and wrap', () => { percent = 40 }],
  ['wrapped', () => { percent = 40; files['/work/.cs/local/wrapped'] = 'uuid-lead\n' }],
  ['armed', () => { arm() }],
  ['countdown', async () => { arm(); await turnComplete() }],
  ['queue start', () => { queueTasks(2) }],
  ['running queue', () => { queueTasks(2); files['/work/.cs/local/queue.state'] = 'draining\n' }],
  ['mail', () => { files['/work/.cs/local/mail/new/one.json'] = '{}' }],
  ['gate', async () => { await gateRuns() }],
  ['survey gate', async () => { await gateRuns() }, { hasSurvey: true }],
  ['working', () => { percent = 40; queueTasks(2) }, { isWorking: true }],
  ['survey', () => { percent = 40; queueTasks(2) }, { hasSurvey: true }],
  ['features', async () => { featureDir('fix-auth'); porcelain(feature('fix-auth', 3, 'ready')); await featuresTurn() }],
  ['working features', async () => { featureDir('fix-auth'); porcelain(feature('fix-auth', 3, 'ready')); await featuresTurn() }, { isWorking: true }],
  ['rail', async () => { transcript(LINEAR); await turnComplete() }],
  ['narrow rail', async () => { transcript(LINEAR); await turnComplete() }, { bodyColumns: 19 }],
  ['mixed row', async () => { percent = 40; queueTasks(2); files['/work/.cs/local/mail/new/one.json'] = '{}'; transcript(LINEAR); await featuresTurn() }],
  ['unbound', () => { percent = 40; delete files[KEYS] }],
  ['different prefixes', () => { percent = 40; bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+w 2': 'strip:jump2' }) }],
]

for (const [name, arrange, props] of bandScenes) {
  test(`band drawing snapshot: ${name}`, async () => {
    bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
    await arrange()
    expect(JSON.stringify(bandSnapshot(await band(props)))).toMatchSnapshot()
  })
}

test('band entries keep the drawn rotate and wrap labels in order', async () => {
  percent = 40
  const drawnLabels = buttons(await band()).map(button => button.props.label)
  const press = () => {}
  const entries = buildBandEntries({ rotating: true, armed: false, wrapping: true, waiting: 0, queued: 0, mail: 0, rotate: press, wrap: press, queue: press })
  expect(entries.map(entry => entry.label)).toEqual(drawnLabels)
  expect(entries.map(entry => entry.label)).toEqual(['rotate', 'wrap'])
})

const feedKey = (tree: any) => buttons(tree).find(button => button.props.key === 'cs-feed')
const enableFeed = () => {
  availableCommands = [{ name: 'feed', source: 'plugin', plugin: 'cs-feed' }]
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2', 'ctrl+x 3': 'strip:jump3' })
}

test('the feed chord toggles this session and colours its check with the keys', async () => {
  enableFeed()
  percent = 40
  const tree = await band()
  expect(feedKey(tree)?.props.label).toBe('feed')
  expect(feedKey(tree).props.action).toBe('strip:jump3')
  expect(words(tree)).toEqual(['●', 'ctrl+x', '1', '  ·  ', '2', '  ·  ', '3'])
  await feedKey(tree).props.onPress()
  const on = await band()
  expect(feedKey(on).props.label).toBe('feed ✓')
  expect(texts(feedKey(on)).map(text => [textOf(text), text.props.color])).toEqual([['✓', 'rgb(220,38,38)']])
  expect(ran).toEqual([{ command: 'feed', args: 'on' }])
  await feedKey(on).props.onPress()
  expect(feedKey(await band()).props.label).toBe('feed')
  expect(ran).toEqual([{ command: 'feed', args: 'on' }, { command: 'feed', args: 'off' }])
})

test('a refused feed command restores the label and toasts once', async () => {
  enableFeed()
  const run = $.command.run
  $.command.run = async () => { throw new Error('Unknown command: feed') }
  try {
    await feedKey(await band()).props.onPress()
    expect(feedKey(await band()).props.label).toBe('feed')
    expect(toasts).toEqual(['cs: feed did not change: Unknown command: feed'])
  } finally {
    $.command.run = run
  }
})

test('a feed press already awaiting delivery ignores another press', async () => {
  enableFeed()
  const run = $.command.run
  let deliver = () => {}
  $.command.run = async args => {
    ran.push(args)
    await new Promise<void>(resolve => { deliver = resolve })
    return { text: '' }
  }
  try {
    const press = feedKey(await band()).props.onPress()
    await settle()
    const duplicate = feedKey(await band()).props.onPress()
    await settle()
    expect(ran).toEqual([{ command: 'feed', args: 'on' }])
    deliver()
    await Promise.all([press, duplicate])
  } finally {
    deliver()
    $.command.run = run
  }
})

test('the feed control follows command availability and the band ownership gates', async () => {
  enableFeed()
  expect(feedKey(await band()).props.label).toBe('feed')
  expect(feedKey(await band({ isWorking: true }))).toBeUndefined()
  expect(feedKey(await band({ hasSurvey: true }))).toBeUndefined()
  sessionId = 'uuid-teammate'
  expect(feedKey(await band())).toBeUndefined()
  sessionId = 'uuid-lead'
  arm()
  expect(buttons(await band()).map(button => button.props.key)).toEqual(['cs-rotate'])
  delete files[MARKER]
  for (const command of [undefined, { name: 'feed', source: 'user' }, { name: 'feed', source: 'plugin', plugin: 'another-plugin' }]) {
    availableCommands = command === undefined ? [] : [command]
    expect(await band()).toBe(DRAWN)
  }
  expect(ran).toEqual([{ command: 'color', args: 'red' }, { command: 'color', args: 'red' }])
})

test('feed state stays with its session across registration and stale button presses', async () => {
  enableFeed()
  const stale = feedKey(await band())
  await stale.props.onPress()
  register(on as any, OPTIONS)
  expect(feedKey(await band()).props.label).toBe('feed ✓')
  await stale.props.onPress()
  expect(feedKey(await band()).props.label).toBe('feed')
  expect(ran).toEqual([{ command: 'feed', args: 'on' }, { command: 'feed', args: 'off' }])
  await feedKey(await band()).props.onPress()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: uuid-next\n'
  register(on as any, OPTIONS)
  expect(feedKey(await band()).props.label).toBe('feed')
})
