// ABOUTME: cs-feed's words: every string the feed draws that is not a setting, from call words and run counts to error lines, peer headlines and report frames.
// ABOUTME: Pure. The strings are the spec's (explore-features §4.6, §6, §8), pinned by tests; the dropped clock strings ("· 19s ·") are not brought back.
import type { FiledCall, Run, Transcript } from './transcript'
import type { CallView } from './verdict'

export type Tense = 'present' | 'past'

/** §4.6 call words: a cleaned description of 3+ characters, else by tool ("Reading app.py", "Opened example.com"). */
export function callWords(call: Pick<CallView, 'tool' | 'input'>, tense: Tense): string {
  throw new Error('not implemented')
}

/** §4.6 cleaning: first non-empty line, no NAME=value, paths to base names, no UUIDs, hex runs or long digit tokens. */
export function clean(text: string): string {
  throw new Error('not implemented')
}

/** "mcp__claude_ai_Slack__send" -> "Slack send"; a built-in keeps its name. */
export function toolName(tool: string): string {
  throw new Error('not implemented')
}

/** §4.6 run words: the naming call's present words, "N steps refused by a hook", one call's words, or the counts ("Ran 2 shell commands · read 1 file"). */
export function runWords(run: Run, t: Transcript, naming?: string): string {
  throw new Error('not implemented')
}

/** §4.6 chips after " · ": refused, "N failed", "+N lines" (plural kept for one: "+1 lines", ruling §20.10). */
export function runChips(run: Run, t: Transcript): readonly string[] {
  throw new Error('not implemented')
}
export function callChips(call: CallView, filed?: FiledCall): readonly string[] {
  throw new Error('not implemented')
}

/** "1 step this turn" / "{n} steps this turn". */
export function stepsLine(done: number): string {
  throw new Error('not implemented')
}

/** §4.6 fit: cut to room-1 (at least 4) at a space in the second half, trim separators, add "…". */
export function fit(text: string, room: number): string {
  throw new Error('not implemented')
}

/** "8s", "1m 12s", "1h 3m"; floors at 0. */
export function elapsed(ms: number): string {
  throw new Error('not implemented')
}

/** Local 24-hour "09:07". One formatter (the fork had two). */
export function hhmm(at: number): string {
  throw new Error('not implemented')
}

/** §4.7b: errored text that reads as a PreToolUse/PermissionRequest hook's refusal. */
export function isRefusal(text: string): boolean {
  throw new Error('not implemented')
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
  throw new Error('not implemented')
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
