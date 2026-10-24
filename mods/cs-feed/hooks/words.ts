// ABOUTME: cs-feed's words: every string the feed draws that is not a setting, from call words and run counts to error lines, peer headlines and report frames.
// ABOUTME: Pure. The strings are the spec's (explore-features §4.6, §6, §8), pinned by tests; the dropped clock strings ("· 19s ·") are not brought back.
import type { FiledCall, Run, Transcript } from './transcript'
import type { CallView } from './verdict'

export type Tense = 'present' | 'past'

/** §4.6 call words: a cleaned description of 3+ characters, else by tool ("Reading app.py", "Opened example.com"). */
export function callWords(call: Pick<CallView, 'tool' | 'input'>, tense: Tense): string {
  const description = typeof call.input.description === 'string' ? clean(call.input.description) : ''
  if (description.length >= 3) return description
  const past = tense === 'past'
  const path = call.input.file_path ?? call.input.notebook_path
  const file = typeof path === 'string' ? basename(path) : ''
  const skill = typeof call.input.skill === 'string' ? clean(call.input.skill) : ''
  const host = typeof call.input.url === 'string' ? call.input.url.match(/^https?:\/\/([^/?#]+)/i)?.[1]?.replace(/^www\./, '') : undefined
  switch (call.tool) {
    case 'Bash': case 'PowerShell': return past ? 'Ran a shell command' : 'Running a shell command'
    case 'Read': return `${past ? 'Read' : 'Reading'} ${file || 'a file'}`
    case 'Edit': case 'MultiEdit': case 'Write': case 'NotebookEdit': return `${past ? 'Edited' : 'Editing'} ${file || 'a file'}`
    case 'Grep': case 'Glob': return past ? 'Searched the code' : 'Searching the code'
    case 'WebSearch': return past ? 'Searched the web' : `Searching the web${typeof call.input.query === 'string' && call.input.query ? ` for ${clean(call.input.query)}` : ''}`
    case 'WebFetch': return `${past ? 'Opened' : 'Opening'} ${host || 'a web page'}`
    case 'Skill': return `${past ? 'Loaded' : 'Loading'} ${skill ? `the ${skill} skill` : 'a skill'}`
    case 'Agent': case 'Task': return past ? 'Asked a helper' : 'Asking a helper'
    case 'AskUserQuestion': return past ? 'Used AskUserQuestion' : 'Asking you a question'
    case 'TodoWrite': return past ? 'Updated the todo list' : 'Updating the todo list'
    default: return `${past ? 'Used' : 'Using'} ${toolName(call.tool)}`
  }
}

/** §4.6 cleaning: first non-empty line, no NAME=value, paths to base names, no UUIDs, hex runs or long digit tokens. */
export function clean(text: string): string {
  return (text.split('\n').find(line => line.trim()) ?? '')
    .replace(/\b[A-Za-z_][A-Za-z_0-9]*=(?:"[^"]*"|'[^']*'|\S+)/g, '')
    .replace(/(?:~\/|\.\.?\/|\/)[^\s,;]+/g, path => basename(path))
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '')
    .replace(/\b[0-9a-f]{12,}\b/gi, '')
    .replace(/\S{20,}/g, token => /\d/.test(token) ? '' : token)
    .replace(/\s+/g, ' ').replace(/\s+([.,;:!?])/g, '$1').trim()
}

function basename(path: string): string {
  return path.replace(/\/+$/, '').split(/[\\/]/).at(-1) ?? ''
}

/** "mcp__claude_ai_Slack__send" -> "Slack send"; a built-in keeps its name. */
export function toolName(tool: string): string {
  return tool.startsWith('mcp__') ? tool.slice(5).replace(/^claude_ai_/, '').replace(/_+/g, ' ') : tool
}

/** §4.6 run words: the naming call's present words, "N steps refused by a hook", one call's words, or the counts ("Ran 2 shell commands · read 1 file"). */
export function runWords(run: Run, t: Transcript, naming?: string): string {
  if (naming) return naming
  const calls = run.calls.flatMap(id => { const call = t.calls.get(id); return call ? [call] : [] })
  const ran = calls.filter(call => call.outcome.state !== 'done' || !call.outcome.refused)
  if (calls.length && !ran.length) return refusedWords(calls.length)
  const first = calls[0]
  if (calls.length === 1 && first) return callWords(first, first.outcome.state === 'running' ? 'present' : 'past')
  const counts = new Map<string, number>()
  for (const call of ran) {
    const kind = call.tool === 'Bash' || call.tool === 'PowerShell' ? 'shell' : ['Edit', 'MultiEdit', 'Write', 'NotebookEdit'].includes(call.tool) ? 'Edit' : call.tool === 'Glob' ? 'Grep' : call.tool === 'Task' ? 'Agent' : call.tool
    counts.set(kind, (counts.get(kind) ?? 0) + 1)
  }
  const text = [...counts].sort(([a, n], [b, m]) => m - n || (a < b ? -1 : a > b ? 1 : 0)).map(([kind, n]) => countWords(kind, n)).join(' · ')
  return text.charAt(0).toUpperCase() + text.slice(1)
}

function refusedWords(n: number): string {
  return `${n} ${n === 1 ? 'step' : 'steps'} refused by a hook`
}

function countWords(kind: string, n: number): string {
  const noun = (word: string) => `${n} ${word}${n === 1 ? '' : 's'}`
  const times = n === 1 ? 'once' : `${n} times`
  switch (kind) {
    case 'shell': return `ran ${noun('shell command')}`
    case 'Read': return `read ${noun('file')}`
    case 'Edit': return `made ${noun('edit')}`
    case 'Grep': return `searched the code ${times}`
    case 'Skill': return `loaded ${noun('skill')}`
    case 'WebSearch': return `searched the web ${times}`
    case 'WebFetch': return `opened ${noun('web page')}`
    case 'Agent': return `asked ${noun('helper')}`
    default: return `used ${toolName(kind)} ${times}`
  }
}

/** §4.6 chips after " · ": refused, "N failed", "+N lines" (plural kept for one: "+1 lines", ruling §20.10). */
export function runChips(run: Run, t: Transcript): readonly string[] {
  const outcomes = run.calls.flatMap(id => { const outcome = t.calls.get(id)?.outcome; return outcome?.state === 'done' ? [outcome] : [] })
  const refused = outcomes.filter(outcome => outcome.refused).length
  const failed = outcomes.filter(outcome => outcome.errored && !outcome.refused).length
  const lines = outcomes.reduce((n, outcome) => n + outcome.lines, 0)
  return [...(refused && refused < run.calls.length ? [refusedWords(refused)] : []), ...(failed ? [`${failed} failed`] : []), ...(lines ? [`+${lines} lines`] : [])]
}
export function callChips(call: CallView, filed?: FiledCall): readonly string[] {
  if (call.isRunning) return []
  const outcome = filed?.outcome
  const text = typeof call.output === 'string' ? call.output : ''
  const refused = call.isErrored && (isRefusal(text) || (outcome?.state === 'done' && outcome.refused))
  const lines = outcome?.state === 'done' ? outcome.lines : text.trim() ? text.trimEnd().split('\n').length : 0
  return [...(refused ? [refusedWords(1)] : call.isErrored ? ['1 failed'] : []), ...(lines ? [`+${lines} lines`] : [])]
}

/** "1 step this turn" / "{n} steps this turn". */
export function stepsLine(done: number): string {
  return `${done} ${done === 1 ? 'step' : 'steps'} this turn`
}

/** §4.6 fit: cut to room-1 (at least 4) at a space in the second half, trim separators, add "…". */
export function fit(text: string, room: number): string {
  if (text.length <= room) return text
  const width = Math.max(4, room - 1)
  const space = text.lastIndexOf(' ', width)
  return text.slice(0, space > width / 2 ? space : width).replace(/[\s·,;:|\-]+$/, '') + '…'
}

/** "8s", "1m 12s", "1h 3m"; floors at 0. */
export function elapsed(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`
  return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`
}

/** Local 24-hour "09:07". One formatter (the fork had two). */
export function hhmm(at: number): string {
  const date = new Date(at)
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

/** §4.7b: errored text that reads as a PreToolUse/PermissionRequest hook's refusal. */
export function isRefusal(text: string): boolean {
  return /(?:PreToolUse|PermissionRequest)(?::\S+)?\s+hook\s+(?:error|blocked|denied)|blocked by a hook|hook[^\n]*denied/i.test(text)
}

export type Tone = 'violet' | 'red' | 'amber'
export type ErrorLine = { readonly head: string; readonly rest: readonly string[]; readonly tone: Tone; readonly act: boolean }

/**
 * §6 rules 1-12, first match wins. Ruling §20.6: rules 1 and 2 (safeguards)
 * also need the text to start with an error prefix or "API Error", so a normal
 * reply quoting such a sentence stays a reply.
 */
export function errorLine(text: string): ErrorLine | undefined {
  throw new Error('not implemented')
}

/** §8.2 headline: first non-empty line, tags removed, paths shrunk, a status object read as words, fit. */
export function peerHeadline(text: string, room: number): string {
  throw new Error('not implemented')
}

/** §8.2 sender from the envelope's from, teammate_id or name, cleaned; else "another session". */
export function senderOf(from: unknown, raw?: string): string {
  throw new Error('not implemented')
}

export type Card = {
  readonly tone: 'ok' | 'bad' | 'mid'
  readonly status: string
  readonly sub?: string
  readonly target?: string
  readonly scores: readonly { label: string; dots: readonly ('ok' | 'bad' | 'mid')[]; pass: number; of: number }[]
  readonly lists: readonly { label: string; count: number; first: string }[]
  readonly report?: string
}
export type Frame = {
  readonly from: string
  readonly state?: string // "_notification" stripped, underscores as spaces, idle -> "waiting"
  readonly at?: number
  readonly summary?: string
  readonly relays: boolean
  readonly lead?: { readonly sentence?: string; readonly card?: Card; readonly text?: string; readonly more: number }
}

/** §8.3 source 1: teammate-message envelopes in a raw user row (session.append), parsed once by uuid. */
export function parseEnvelopes(raw: string): readonly Frame[] {
  throw new Error('not implemented')
}
/** §8.3 source 2: frames read from a row's own text (a row stored before this load). */
export function framesFromText(text: string): readonly Frame[] {
  throw new Error('not implemented')
}

/** §9.1 test words: test, tests, suite, spec, specs, e2e, verify, check. */
export function looksLikeTest(words: string): boolean {
  return /\b(?:tests?|suite|specs?|e2e|verify|check)\b/i.test(words)
}

/** §8.1 #3: text whose first line starts with a hook name and reaches a colon; the quiet line it draws. */
export function hookTextLine(text: string): string | undefined {
  throw new Error('not implemented')
}

/**
 * Whether a reply may carry its turn's steps line (§4.4), from the reply's
 * whole stored text alone (finding 6). False when the text holds a mermaid
 * fence: cs-mermaid, when it is the outer hook, calls next once per prose part
 * and not at all for a diagram-only reply (mods/cs-mermaid/hooks/register.tsx
 * 195-197), so no single drawing of ours would own the line. A function of
 * the text, not of what this load saw drawn, so the tool row and the reply row
 * decide the same in either plugin order.
 *
 * The fence scan is cs-mermaid's rule (`scanFences`: a ```mermaid line, outer
 * ```` or ~~~ blocks quote it), duplicated: plugins do not import each other.
 * A test runs both scanners over cs-mermaid's own fixtures and pins equal answers.
 */
export function repliesOwnSteps(text: string): boolean {
  throw new Error('not implemented')
}
