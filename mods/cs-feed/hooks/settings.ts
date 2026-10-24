// ABOUTME: cs-feed settings: the per-session record (on/off and the view), the two presets, the mode name, and the /feed grammar, all derived from one FIELDS table.
// ABOUTME: Pure. On/off is the file .cs/local/feed (cs's band writes it too); the view is the sibling .cs/local/feed-view, which only cs-feed writes.

export const PLUGIN = 'cs-feed'

/**
 * The per-session truth, shared with cs's band (Alex's ruling 2, design
 * revision 2). Relative to `$.session.cwd()`, which both sides read the same
 * way. Exactly `on\n` is on; anything else is off: absent, torn by a
 * non-atomic write, `off\n`, or any other text. cs's band reads it with
 * `=== 'on\n'` (mods/cs/hooks/register.tsx readFeed) and writes it from the
 * chord `ctrl+x 3 feed` (pressFeed). A contract between two plugins: KEEP IN
 * SYNC with readFeed and pressFeed; a test in each mod pins these literals.
 */
export const FEED_FILE = '.cs/local/feed'
export const ON_LINE = 'on\n'
export const OFF_LINE = 'off\n'
/** The directory whose presence says "this may be a cs session". /feed never creates it ($.fs.write would), and asks cs -vet-session only where it exists. */
export const CS_LOCAL = '.cs/local'
/**
 * How long `cs -vet-session` may take before its answer counts as a refusal.
 * Every /feed write asks it first, as cs's band press does, and so does a
 * read that finds FEED_FILE on with no answer cached for it (ruling §20.22,
 * accepted by Alex 2026-10-24; session.vetRefusal, session.vetOnRead). KEEP
 * IN SYNC with VET_TIMEOUT_MS in mods/cs/hooks/register.tsx. The env name
 * `CS_BIN` stays a literal at its one read, as cs's is: validate lists the
 * names a module reads.
 */
export const VET_TIMEOUT_MS = 10000
/**
 * The view (clean/normal fields and the hide list), JSON plus a closing
 * newline. A sibling of FEED_FILE, not inside it: the band's readFeed is
 * `=== 'on\n'`, so any second field in `feed` would read as off there.
 * Written only by cs-feed (/feed and the settings pane).
 */
export const VIEW_FILE = '.cs/local/feed-view'
/** The Button cs's band draws for the chord: `ui.press` reaches cs-feed's hook addressed `{ plugin, element }`. KEEP IN SYNC with cs's buildBandEntries key `cs-feed`. */
export const BAND_PLUGIN = 'cs'
export const BAND_ELEMENT = 'cs-feed'

/** What the feed file says. Pure: the whole line or nothing (a torn write without its newline is off, as the band reads it). */
export function isOn(text: string | undefined): boolean {
  return text === ON_LINE
}

export const KINDS = ['you', 'said', 'tool', 'agent', 'question', 'peer', 'helper', 'search'] as const
export type Kind = (typeof KINDS)[number]

export type Style = 'expanded' | 'subtle' | 'line'
export type Commands = 'grouped' | 'each'
export type After = 'clear' | 'keep'

/**
 * What the view draws while this session's feed is on. There is no `raw`
 * field: raw is `Session.on === false`, and site() returns the engine's
 * drawing before any painter runs, so no painter can read a view while raw
 * (the fork's C1 class: per-hook raw checks).
 */
export type View = {
  readonly group: boolean
  readonly clear: boolean
  readonly keep: boolean
  readonly style: Style
  readonly commands: Commands
  readonly after: After
  readonly hide: readonly Kind[]
}

/**
 * This session's record as cs-feed mirrors it per load (session.feedRecord):
 * `on` from FEED_FILE where cs -vet-session passes (a file that says on in a
 * session cs refuses reads as off, ruling §20.22), `view` from VIEW_FILE.
 * Not $.state: lost at /clear, --resume, --continue and a relaunch (spike3
 * M13). `on` false: every hook
 * passes the engine's drawing through (spike4: +32 worker hops per three-turn
 * scenario beside cs's three mods, about +8-10 ms at each turn's end, accepted);
 * the observers keep observing.
 */
export type Session = { readonly on: boolean; readonly view: View }

export type Preset = 'clean' | 'normal'
export type Mode = 'raw' | Preset | 'custom'

/** Everything a View holds but `hide`: what a preset sets. */
export type Fields = Omit<View, 'hide'>

export const PRESETS: { readonly [P in Preset]: { readonly fields: Fields; readonly help: string } } = {
  clean: { fields: { group: true, clear: true, keep: false, style: 'subtle', commands: 'grouped', after: 'clear' }, help: "your messages, Claude's replies, and one line per turn for the work" },
  normal: { fields: { group: false, clear: false, keep: true, style: 'subtle', commands: 'grouped', after: 'keep' }, help: 'each run of tool calls is one line with counts' },
}
export const RAW_HELP = "Claude Code's own drawing"

/**
 * The view an absent VIEW_FILE yields: clean, no kind hidden.
 * The fork merged stored records over the raw preset's fields because raw was
 * a field set; here raw is `on: false`, and the first switch-on (the band key,
 * /feed on, a setting change from raw) needs a view.
 */
export const DEFAULT_VIEW: View = { ...PRESETS.clean.fields, hide: [] }

/**
 * One row per setting. The /feed grammar, its replies, the usage line, the
 * settings pane's rows and pictures, and `modeOf` all read this table: adding a
 * setting is one entry (design red flag: hand-synced list).
 */
export type FieldSpec<F extends keyof Fields = keyof Fields> = { [K in F]: {
  readonly field: K
  readonly word: string // the /feed word: `group`, `style`, ...
  readonly title: string // the pane's pressable title
  readonly values: readonly Fields[K][] // in cycle order; booleans as [true, false]
  readonly spoken: (v: Fields[K]) => string // `on`, `off`, `subtle`, ...
  readonly picture: (v: Fields[K]) => readonly string[] // the pane's dim example lines
} }[F]
const spoken = (value: Fields[keyof Fields]): string => typeof value === 'boolean' ? (value ? 'on' : 'off') : value
export const FIELDS: readonly FieldSpec[] = [
  { field: 'group', word: 'group', title: 'Group a turn into one line', values: [true, false], spoken,
    picture: value => value ? ['you   fix the login bug', '○ 6 steps this turn ›', 'claude Fixed: the token now refreshes.'] : ['you   fix the login bug', '○ Ran 3 shell commands · read 2 files ›', '○ Edited auth.ts', 'claude Fixed: the token now refreshes.'] },
  { field: 'clear', word: 'clear', title: 'Clear after the turn', values: [true, false], spoken,
    picture: value => [value ? 'a finished turn keeps only its one line (grouping on) or nothing (off)' : 'a finished turn keeps its rows'] },
  { field: 'keep', word: 'keep', title: 'Keep every card', values: [true, false], spoken,
    picture: value => [value ? 'finished turns stay drawn as they ran, whatever "clear" says' : '"clear after the turn" decides'] },
  { field: 'style', word: 'style', title: 'Card style', values: ['expanded', 'subtle', 'line'], spoken,
    picture: value => value === 'expanded' ? ['○ Ran 2 shell commands', '  ○ Ran the tests +12 lines', '  ○ Listed the files +4 lines'] : [value === 'subtle' ? '○ Ran 2 shell commands +16 lines ›' : '○ Ran 2 shell commands'] },
  { field: 'commands', word: 'commands', title: 'Commands in the chat', values: ['grouped', 'each'], spoken,
    picture: value => value === 'grouped' ? ['○ Ran 3 shell commands · read 1 file'] : ['○ Ran the tests', '○ Listed the files', '○ Read app.py'] },
  { field: 'after', word: 'after', title: 'After a command finishes', values: ['clear', 'keep'], spoken,
    picture: value => [value === 'clear' ? 'a finished turn keeps the run line, not each command' : 'each finished command keeps its own line'] },
]

export function modeOf(session: Session): Mode {
  // raw when this session's feed is off; a preset only when all six fields match
  // it and nothing is hidden (§1.2, `/feed hide peer` then `/feed clean` reads custom).
  if (!session.on) return 'raw'
  if (session.view.hide.length) return 'custom'
  for (const preset of ['clean', 'normal'] as const) {
    if (FIELDS.every(({ field }) => session.view[field] === PRESETS[preset].fields[field])) return preset
  }
  return 'custom'
}

/** VIEW_FILE's text is refused when torn, malformed, incomplete or invalid. */
export function parseStoredView(text: string | undefined): View {
  if (text === undefined) return DEFAULT_VIEW
  if (!text.endsWith('\n')) throw new Error('feed-view is torn: missing closing newline')
  let value: unknown
  try { value = JSON.parse(text) } catch { throw new Error('feed-view contains invalid JSON') }
  if (!isRecord(value)) throw new Error('feed-view must be an object')
  const fields: Record<string, unknown> = value
  for (const spec of FIELDS) {
    if (!(spec.field in fields)) throw new Error(`feed-view is missing field ${spec.field}`)
    if (!spec.values.some(allowed => allowed === fields[spec.field])) throw new Error(`feed-view field ${spec.field} has invalid value ${JSON.stringify(fields[spec.field])}`)
  }
  if (!('hide' in fields)) throw new Error('feed-view is missing field hide')
  if (!Array.isArray(fields.hide) || !fields.hide.every(isKind)) throw new Error(`feed-view field hide has invalid value ${JSON.stringify(fields.hide)}`)
  if (typeof fields.group !== 'boolean' || typeof fields.clear !== 'boolean' || typeof fields.keep !== 'boolean'
    || (fields.style !== 'expanded' && fields.style !== 'subtle' && fields.style !== 'line')
    || (fields.commands !== 'grouped' && fields.commands !== 'each') || (fields.after !== 'clear' && fields.after !== 'keep')) {
    throw new Error('feed-view field registry disagrees with the view contract')
  }
  return { group: fields.group, clear: fields.clear, keep: fields.keep, style: fields.style, commands: fields.commands, after: fields.after, hide: fields.hide }
}

function isKind(value: unknown): value is Kind {
  return KINDS.some(kind => kind === value)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** VIEW_FILE's text for a view: JSON and a closing newline, so a torn write is told apart. */
export function viewText(view: View): string {
  return `${JSON.stringify(view)}\n`
}

/**
 * §2.2: lowercased, split on whitespace; `close`, `on`, `off`, `status` and the
 * presets only as the sole word; a setting takes its first two words; booleans accept on/off, yes/no,
 * true/false; anything else is `usage`.
 */
export function parseFeedArgs(args: string): FeedCommand {
  const words = args.trim().toLowerCase().split(/\s+/)
  const [word, value] = words
  if (!word) return { kind: 'open' }
  if (words.length === 1) {
    if (word === 'close' || word === 'status') return { kind: word }
    if (word === 'on' || word === 'off') return { kind: 'switch', on: word === 'on' }
    if (word === 'clean' || word === 'normal' || word === 'raw') return { kind: 'preset', to: word }
  }
  if ((word === 'hide' || word === 'show') && isKind(value)) return { kind: word, what: value }
  const spec = FIELDS.find(spec => spec.word === word)
  if (!spec) return { kind: 'usage' }
  switch (spec.field) {
    case 'group': case 'clear': case 'keep': {
      const parsed = fieldValue(spec.values, value)
      if (parsed !== undefined) return { kind: 'set', field: spec.field, value: parsed }
      break
    }
    case 'style': {
      const parsed = fieldValue(spec.values, value)
      if (parsed !== undefined) return { kind: 'set', field: spec.field, value: parsed }
      break
    }
    case 'commands': {
      const parsed = fieldValue(spec.values, value)
      if (parsed !== undefined) return { kind: 'set', field: spec.field, value: parsed }
      break
    }
    case 'after': {
      const parsed = fieldValue(spec.values, value)
      if (parsed !== undefined) return { kind: 'set', field: spec.field, value: parsed }
    }
  }
  return { kind: 'usage' }
}

function fieldValue<T extends Fields[keyof Fields]>(values: readonly T[], word: string | undefined): T | undefined {
  const normalized = word === 'yes' || word === 'true' ? 'on' : word === 'no' || word === 'false' ? 'off' : word
  return values.find(value => spoken(value) === normalized)
}

/**
 * What a typed /feed command or a settings-pane press asks for. Every change is
 * this session's (this directory's: FEED_FILE and VIEW_FILE). The shell asks
 * cs -vet-session first and, refused, writes nothing and replies why (ruling
 * §20.22); passed, it writes VIEW_FILE when `view` changed, then FEED_FILE,
 * then reads FEED_FILE back for the mirror and invalidates. cs's band key does not come through here: it
 * writes FEED_FILE itself, and cs-feed's ui.press hook reads it after next(e).
 * Nothing reloads and no command runs ($.command.run is not used anywhere).
 *
 *   /feed clean | normal   on, the preset's fields, `hide` kept
 *   /feed raw              off (the view is kept for the next on)
 *   /feed on | off         `on` set, the view kept (the pane's on/off row builds the same)
 *   /feed status           nothing written; re-reads FEED_FILE (a vet only for a flip to on no writer of ours vetted); the reply's first word is `on` or `off` as vetted, then the mode
 *   set, hide, show, chip  on, the change applied to this session's view
 *                          (ruling §20.4/§20.5, now per session: a change from raw turns on)
 */
export type Setting = { [F in keyof Fields]: { readonly kind: 'set'; readonly field: F; readonly value: Fields[F] } }[keyof Fields]

export type FeedCommand =
  | { readonly kind: 'open' } // bare /feed
  | { readonly kind: 'close' }
  | { readonly kind: 'switch'; readonly on: boolean } // /feed on | off
  | { readonly kind: 'status' }
  | { readonly kind: 'preset'; readonly to: Preset | 'raw' }
  | Setting
  | { readonly kind: 'hide' | 'show'; readonly what: Kind }
  | { readonly kind: 'usage' }

export type Transition = {
  /** The record to write: VIEW_FILE when its view differs from the current one, then FEED_FILE. Absent: nothing to write (status, open, close, usage). */
  readonly session?: Session
  readonly pane?: 'open' | 'close'
  readonly reply: string // §2.2 reply texts, from FIELDS and PRESETS
}
export function transition(cmd: FeedCommand, current: Session): Transition {
  switch (cmd.kind) {
    case 'open': return { pane: 'open', reply: `Chat view: ${modeOf(current)}. Settings are open above the prompt; /feed close shuts them.` }
    case 'close': return { pane: 'close', reply: 'Chat view settings closed.' }
    case 'status': return { reply: `${current.on ? 'on' : 'off'} · ${modeOf(current)}` }
    case 'usage': return { reply: usageLine() }
    case 'switch': return { session: { ...current, on: cmd.on }, reply: `Chat view: ${cmd.on ? 'on' : 'off'}.` }
    case 'preset': return { session: cmd.to === 'raw' ? { ...current, on: false } : { on: true, view: { ...PRESETS[cmd.to].fields, hide: current.view.hide } }, reply: `Chat view: ${cmd.to}. ${cmd.to === 'raw' ? RAW_HELP : PRESETS[cmd.to].help}.` }
    case 'hide': case 'show': {
      const hide = cmd.kind === 'hide' ? [...new Set([...current.view.hide, cmd.what])] : current.view.hide.filter(kind => kind !== cmd.what)
      return { session: { on: true, view: { ...current.view, hide } }, reply: `Chat view: ${cmd.what} ${cmd.kind === 'hide' ? 'hidden' : 'shown'}.` }
    }
    case 'set': {
      const view: View = { ...current.view, [cmd.field]: cmd.value }
      return { session: { on: true, view }, reply: `Chat view: ${cmd.field} ${spoken(cmd.value)}.` }
    }
  }
}

/** "/feed opens the settings · /feed clean | normal | raw · ..." built from FIELDS. */
export function usageLine(): string {
  return ['/feed opens the settings', '/feed on | off | status', '/feed clean | normal | raw', ...FIELDS.map(spec => `/feed ${spec.word} ${spec.values.map(spoken).join('|')}`), '/feed hide|show <kind>', '/feed close'].join(' · ')
}
