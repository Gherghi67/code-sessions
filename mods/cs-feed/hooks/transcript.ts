// ABOUTME: cs-feed's one cross-row structure: turns, runs and filed calls, a pure function of one $.session.messages() result.
// ABOUTME: Built whole on every refresh and swapped in; never merged, never written to $.state. Same transcript, same answer, whatever was switched when.
import type { ApiMessage, SessionMessage, ToolUseSummary } from 'claude-code'
import { isRefusal, callWords, looksLikeTest } from './words'

export type CallId = string & { readonly __brand: 'CallId' }

export function callId(value: string): CallId {
  if (!value) throw new Error('A tool call id must not be empty')
  // Engine tool-use ids are opaque strings; this constructor enforces their only local invariant.
  return value as CallId
}

/**
 * A turn's identity is its first call's tool_use_id (any class: a turn that
 * opens with a helper still has one). It is stable across reads while
 * messages() slides its 4096-entry window, where a position would shift and
 * file every call under the wrong turn until the next build. A turn with no
 * call has no id and needs none: nothing of it folds, nothing has a chevron.
 *
 * Residual: a turn whose real first call has slid out of the window takes the
 * id of its first call still in the window, once. Its turn chevron closes.
 */
export type TurnId = CallId

/**
 * Machinery joins runs and counts as a step of the turn. A helper (Agent, Task)
 * or a question (AskUserQuestion) stands alone, unless a hook refused it, when
 * it is filed as machinery (§4.7c).
 */
export type CallClass = 'machinery' | 'helper' | 'question'

export type QuestionPair = { readonly question: string; readonly answer: string }

export type Outcome =
  | { readonly state: 'running' } // no result in the transcript yet
  | {
      readonly state: 'done'
      readonly errored: boolean
      readonly refused: boolean // errored and the text reads as a hook refusal (words.isRefusal)
      readonly interrupted: boolean
      readonly lines: number // the "+N lines" chip
      readonly output?: string // stdout+stderr or the error text, cut to 2000; kept for the newest OUTPUT_KEPT calls only
      readonly answers?: readonly QuestionPair[] // questions only
      /** ToolUseSummary.durationMs: a foreground helper that ran to completion. Absent on a background launch. */
      readonly durationMs?: number
    }

export type FiledCall = {
  readonly id: CallId
  readonly tool: string
  readonly input: Readonly<Record<string, unknown>>
  readonly cls: CallClass
  readonly outcome: Outcome
  /** Always set: a filed call's turn holds at least this call, so it has an id. */
  readonly turn: TurnId
  /** The run this call is in; absent for a standalone call. A run's id is its first call's. */
  readonly run?: CallId
  /** Machinery steps filed through this call; helpers and questions do not increment it. */
  readonly step: number
  /**
   * ToolUseSummary.agentId on an Agent call: known while the session tracks the
   * run and once the call is answered. Links the row to $.agent.list() and to
   * $.session.messages({ agentId }) without an agent.spawn observation.
   */
  readonly agentId?: string
}

export type Run = { readonly id: CallId; readonly turn: TurnId; readonly calls: readonly CallId[] }

export type Turn = {
  /** The first call's id; absent while the turn has no call. */
  readonly id?: TurnId
  /** The turn's first machinery call: the row the turn line draws on. */
  readonly first?: CallId
  /** Machinery calls plus refused standalone ones, in order: what "{n} steps this turn" counts (done ones). */
  readonly steps: readonly CallId[]
  readonly runs: readonly CallId[]
}

/** A Bash call started with run_in_background that no later entry says has ended (§9.1). */
export type BackgroundRun = { readonly id: CallId; readonly words: string; readonly isTest: boolean }

export type Transcript = {
  readonly calls: ReadonlyMap<CallId, FiledCall>
  /** In transcript order. Only the last one is ever looked up by place (the open turn); every other lookup goes by id. */
  readonly turns: readonly Turn[]
  readonly byId: ReadonlyMap<TurnId, Turn>
  readonly runs: ReadonlyMap<CallId, Run>
  readonly background: readonly BackgroundRun[]
}

export const EMPTY: Transcript = { calls: new Map(), turns: [], byId: new Map(), runs: new Map(), background: [] }
export const OUTPUT_KEPT = 400

/**
 * Does this user entry open a turn? A user entry opens a turn when it has text,
 * no tool results, and is not bash-mode text (<bash-input>, <bash-stdout>),
 * which runs no model turn. Measured on 2.1.309 (spike Q4, spike2 M1):
 *
 *   - Plain messages() drops isMeta rows (Stop-hook feedback, a skill's body)
 *     and local-command echoes. A Stop-hook continuation is two assistant
 *     entries in a row: one turn.
 *   - A prompt typed mid-turn, a peer message and a task notification delivered
 *     into a running turn never appear: the engine folds them into the next
 *     tool_result's content (visible only in `as: 'api'`). They cannot split a turn.
 *   - A prompt typed during a text-only turn, and a task notification arriving
 *     while idle, appear as user entries after the last turn's reply. Each is a
 *     turn of its own in the engine too, so opening one is right.
 *
 * Residual (rationale, open question Q-idle-delivery): a peer message arriving
 * while idle is stored isMeta, so plain drops it and its turn's reply and calls
 * read as part of the previous turn, the same plain shape as a Stop-hook
 * continuation. Not measured: what an interrupted turn leaves before the next
 * prompt (the rule opens a turn on that prompt either way).
 */
export function opensTurn(entry: SessionMessage): boolean {
  return entry.role === 'user' && entry.text.trim().length > 0 && !entry.toolResults?.length && !/^\s*<bash-(?:input|stdout)>/.test(entry.text)
}

/**
 * The whole structure from the whole transcript, in one pass:
 *
 *   turn = none; run = undefined
 *   for entry of messages:
 *     user:      if opensTurn(entry): turn = new Turn (no id yet); run = undefined
 *                (tool-result entries add nothing: toolUses carry their outcome)
 *     assistant: if the joined api message before it opens a peer turn (opensPeerTurn via joinApi),
 *                or its first tool_use id is in openers: turn = new Turn; run = undefined
 *                if entry.text.trim(): run = undefined
 *                for use of entry.toolUses: file(use)
 *   file(use):   turn.id ??= use.id   (the turn's identity is its first call)
 *                cls = classOf(use); refused standalones become machinery
 *                machinery: run ??= use.id; runs[run].push(use.id); turn.first ??= use.id; steps.push
 *                standalone: run = undefined (a standalone call ends the run)
 *                step = turn.steps.length; agentId = use.agentId; durationMs = use.durationMs
 *
 * A total function of the transcript: every tool_use in it is filed exactly
 * once, under the turn whose opening entry precedes it, and that turn's id is
 * a call id the transcript itself holds. With no `openers` there is no input
 * from live events, and the same transcript files the same way before and after
 * any switch; `openers` is the one live input (finding 1, below).
 */
export function buildTranscript(messages: readonly SessionMessage[], api?: readonly ApiMessage[], openers?: ReadonlySet<CallId>): Transcript {
  const calls = new Map<CallId, FiledCall>()
  const turns: { id?: TurnId; first?: CallId; steps: CallId[]; runs: CallId[] }[] = []
  const byId = new Map<TurnId, Turn>()
  const runs = new Map<CallId, { id: CallId; turn: TurnId; calls: CallId[] }>()
  const joined = api ? joinApi(messages, api) : new Map<number, ApiMessage>()
  let turn: (typeof turns)[number] | undefined
  let run: (typeof runs extends Map<CallId, infer R> ? R : never) | undefined
  const count = messages.reduce((n, entry) => n + entry.toolUses.length, 0)
  let filed = 0
  for (const [index, entry] of messages.entries()) {
    const peer = joined.get(index)
    const first = entry.toolUses[0]
    if (opensTurn(entry) || (peer && opensPeerTurn(peer)) || (first && openers?.has(callId(first.tool_use_id)))) {
      turn = { steps: [], runs: [] }
      turns.push(turn)
      run = undefined
    }
    if (entry.role !== 'assistant') continue
    if (!turn && (entry.text.trim() || entry.toolUses.length)) {
      turn = { steps: [], runs: [] }
      turns.push(turn)
    }
    if (entry.text.trim()) run = undefined
    for (const use of entry.toolUses) {
      if (!turn) throw new Error(`Call ${use.tool_use_id} has no transcript turn`)
      const id = callId(use.tool_use_id)
      if (calls.has(id)) throw new Error(`Duplicate tool call id ${id}`)
      turn.id ??= id
      byId.set(turn.id, turn)
      const outcome = outcomeOf(use, filed++ >= count - OUTPUT_KEPT)
      const cls: CallClass = outcome.state === 'done' && outcome.refused ? 'machinery' : use.tool === 'Agent' || use.tool === 'Task' ? 'helper' : use.tool === 'AskUserQuestion' ? 'question' : 'machinery'
      if (cls === 'machinery') {
        if (!run) {
          run = { id, turn: turn.id, calls: [] }
          runs.set(id, run)
          turn.runs.push(id)
        }
        run.calls.push(id)
        turn.first ??= id
        turn.steps.push(id)
      } else run = undefined
      calls.set(id, { id, tool: use.tool, input: use.input, cls, outcome, turn: turn.id, run: cls === 'machinery' ? run?.id : undefined, step: turn.steps.length, agentId: use.agentId })
    }
  }
  return { calls, turns, byId, runs, background: backgroundRuns(messages, api) }
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function outcomeOf(use: ToolUseSummary, keepOutput: boolean): Outcome {
  if (use.text === undefined && use.result === undefined) return { state: 'running' }
  const result = object(use.result) ? use.result : undefined
  const output = [result?.stdout, result?.stderr].filter(part => typeof part === 'string' && part.length > 0).join('\n')
  const error = [result?.error, result?.denyReason].filter(part => typeof part === 'string' && part.length > 0).join('\n')
  const text = output || error || use.text || (typeof use.result === 'string' ? use.result : '')
  const errored = use.isError === true || typeof result?.denyReason === 'string'
  return { state: 'done', errored, refused: errored && isRefusal(text), interrupted: result?.interrupted === true, lines: text.trim() ? text.trimEnd().split('\n').length : 0, output: keepOutput && text ? text.slice(0, 2000) : undefined, durationMs: use.durationMs, answers: use.tool === 'AskUserQuestion' ? questionPairs(use.input, use.result) : undefined }
}

/**
 * Q-idle-delivery option B (Alex rules; finding 1). An idle peer message is
 * stored isMeta, so plain drops it and its turn reads as part of the previous
 * one. Two sources open such a turn, and only these two:
 *
 *  1. Live provenance, for rows stored while this load ran: a call id in
 *     `openers` (Observations.turnOpeners, from session.append origin `peer`)
 *     opens a turn at that call. Exact, and it covers teammate envelopes.
 *  2. History (rows from before the load): where plain has two assistant
 *     entries in a row, the `api` user message between those two replies
 *     opens a turn only if opensPeerTurn says so.
 *
 * Not a substring search. The previous rule (an envelope tag anywhere in a text
 * block) split on a Stop hook whose feedback quoted `<task-notification>`:
 * M1d shows that feedback becomes a text-only api user message between two
 * adjacent assistant entries. Withdrawn with it: "an injection the feed does
 * not know can only merge, never split" as a structural claim. It now holds
 * only as far as opensPeerTurn's anchored prefix holds, which the tests below
 * check case by case; it is not proven for every hook type.
 *
 * Also withdrawn: "no switch can file a call in a different turn than a fresh
 * build". It holds for source 2 alone. With source 1 a fresh load (a change
 * of these files, such as a cs update, or a relaunch) loses the openers and
 * falls back to source 2: a teammate idle turn, which source 2 does not match,
 * merges again after it. A per-session toggle is not a reload and loses nothing.
 *
 * Source 1's live order is measured (spike5 M19): the prompt hook sets
 * peerPending synchronously after its next(e), turn.start (0-1 ms later)
 * consumes it into the turn's record, and the response hook adds that turn's
 * first tool_use id. See session.Observations.peerPending.
 */

/**
 * Source 2 needs, for two adjacent plain assistant entries, the `api` message
 * between them. Neither form carries a uuid, and their windows differ (plain
 * drops isMeta and local-command rows; api is "the messages the next request is
 * built from", the last compaction's summary in place of what it replaced,
 * opening on a user message; each holds at most 4096). So the join is
 * positional, anchored at the newest end, and verified pair by pair:
 *
 *   A = plain's assistant entries, newest first; B = api's assistant messages, newest first
 *   pair A[k] with B[k] for k = 0, 1, … while the pair is CONSISTENT:
 *     - same tool_use ids in the same order (plain toolUses[].tool_use_id, api tool_use blocks' `id`), and
 *     - same text (plain `text` === api text blocks joined the way plain joins them)
 *   stop at the first inconsistent pair, or when either list ends.
 *   A consistent pair is VERIFIED only when (revision 2.1, validate3):
 *     - it carries tool_use ids (they are unique, so a shifted pair cannot match them), or
 *     - it is tool-free and its text occurs exactly once among plain's tool-free
 *       assistant texts AND exactly once among api's.
 *   A consistent tool-free pair whose text repeats is unverified: the walk goes on
 *   past it, and every gap that touches it answers false.
 *   For a verified pair (A[k], B[k]) whose next-older pair (A[k+1], B[k+1]) is also
 *   verified, and whose plain entries are adjacent (no plain user entry between them):
 *   the api messages strictly between B[k+1] and B[k] must be exactly one user
 *   message U; then opensPeerTurn(U) decides. Zero or two or more user messages
 *   between them, or anything else: false.
 *
 * Why text alone does not verify: two consecutive identical short tool-free
 * texts (m1d's Stop-hook continuation is `ok`, `ok`) with a one-message offset
 * between the windows would verify a shifted pair and put a peer preamble one
 * entry off. The offset is reachable: the refresh reads plain, then api, so a
 * row stored between the reads gives api one message plain lacks. Under one
 * divergence a shifted pair is inconsistent (the walk stops) or a repeated
 * tool-free text (unverified), so it never verifies. Cost: a repeated tool-free
 * text closes the gaps beside it to the merge.
 *
 * Every failure answers false, the merge: the conservative direction (a peer
 * turn reads as part of the previous turn, as without option B). Compaction
 * replaces the oldest api messages with a summary, so the pairing stops there;
 * turns older than the last compaction fall back to the merge.
 *
 * Assumption, not measured, load-bearing (open-measurements M23): between two
 * verified anchors, plain and api hold the same assistant messages in the same
 * order (api never merges two stored assistant rows that plain keeps apart,
 * nor the reverse). One divergence makes the walk stop or leaves the pair
 * unverified, so the rule only stops splitting. Two compensating divergences
 * between verified pairs (one api message extra, one missing) are not closed
 * by the rule above: there it could split wrongly, which M23 measures.
 *
 * Kit tests use synthetic adjacent assistant pairs for peer joining, changed
 * text, differing or reordered ids, and uniqueness on each side. The recorded
 * m1d `ok`, `ok` pair remains unverified even with the newest API reply absent.
 * m1b has no earlier assistant to verify around its first peer row (M23).
 *
 * Returns, for each plain index of an A[k] that passed, the one api user
 * message U between it and the older verified entry; buildTranscript asks
 * opensPeerTurn(U) for those indexes and for no other.
 */
export function joinApi(plain: readonly SessionMessage[], api: readonly ApiMessage[]): ReadonlyMap<number, ApiMessage> {
  const left = plain.flatMap((message, index) => message.role === 'assistant' ? [{ index, text: message.text, ids: message.toolUses.map(use => use.tool_use_id) }] : []).reverse()
  const right = api.flatMap((message, index) => message.role === 'assistant' ? [{ index, text: apiText(message), ids: message.content.flatMap(block => block.type === 'tool_use' && typeof block.id === 'string' ? [block.id] : []) }] : []).reverse()
  const joined = new Map<number, ApiMessage>()
  const leftCounts = textCounts(left)
  const rightCounts = textCounts(right)
  let newer: { plain: number; api: number; verified: boolean } | undefined
  for (let i = 0; i < Math.min(left.length, right.length); i++) {
    const a = left[i]
    const b = right[i]
    if (!a || !b) throw new Error(`Missing API join pair at ${i}`)
    if (a.text !== b.text || a.ids.length !== b.ids.length || a.ids.some((id, j) => id !== b.ids[j])) break
    const verified = a.ids.length > 0 || (leftCounts.get(a.text) === 1 && rightCounts.get(b.text) === 1)
    if (verified && newer?.verified && newer.plain === a.index + 1 && newer.api === b.index + 2) {
      const between = api[b.index + 1]
      if (between?.role === 'user') joined.set(newer.plain, between)
    }
    newer = { plain: a.index, api: b.index, verified }
  }
  return joined
}

function textCounts(rows: readonly { text: string; ids: readonly string[] }[]): ReadonlyMap<string, number> {
  const counts = new Map<string, number>()
  for (const row of rows) if (row.ids.length === 0) counts.set(row.text, (counts.get(row.text) ?? 0) + 1)
  return counts
}

function apiText(message: ApiMessage): string {
  return message.content.flatMap(block => block.type === 'text' && typeof block.text === 'string' ? [block.text] : []).join('\n')
}

/**
 * The history rule, conservative by construction: a whitelist of block
 * shapes, true only when EVERY block of the message is one of
 *   (a) a text block that STARTS (offset 0, no leading whitespace) with the one
 *       measured engine preamble `Another Claude session sent a message:\n<cross-session-message `
 *       (M1b) and holds its closing `</cross-session-message>`; or
 *   (b) a text block that starts with `<system-reminder>` and holds none of
 *       `<cross-session-message`, `<teammate-message`, `<task-notification>`
 *       (an engine reminder riding along, such as the token count),
 * and exactly one block is (a). Anything else answers false: a tool_result
 * block, a `Stop hook feedback:` block or a `<system-reminder>\nStop hook
 * blocking error` block (M1d: neither is (a); the reminder is (b) only while it
 * quotes no envelope), any block of a shape not measured.
 * A tag quoted anywhere else, a block that only contains the preamble later in
 * its text, a teammate envelope (not measured: added only once measured), and
 * `<task-notification>` (an idle notification is a plain user entry already,
 * M1c, so it is never this shape) all answer false: the two replies stay one turn.
 *
 * Kit tests, fixtures derived from spike2's recorded dumps with neutral text:
 *   - m1d api, the Stop-hook feedback edited to read `Stop hook feedback:\n<task-notification>…</task-notification>`  -> false, one turn
 *   - the same with `<cross-session-message from="x">…</cross-session-message>` quoted in the feedback           -> false
 *   - a system-reminder block (hook context) holding the full peer preamble                                       -> false
 *   - a text block `see: Another Claude session sent a message:\n<cross-session-message …>` (preamble not at 0)    -> false
 *   - m1b api entry 0 (the idle peer row)                                                                          -> true, a turn of its own
 *   - m1b starts with an orphan reply, so it cannot prove an adjacent-pair peer join (M23).
 *   - source 1 uses a shape-derived event sequence; the first peer call is a live opener.
 */
export function opensPeerTurn(between: ApiMessage): boolean {
  if (between.role !== 'user' || typeof between.content === 'string') return false
  let peers = 0
  for (const block of between.content) {
    if (block.type !== 'text' || typeof block.text !== 'string') return false
    if (block.text.startsWith('Another Claude session sent a message:\n<cross-session-message ') && block.text.includes('</cross-session-message>')) {
      peers++
    } else if (!block.text.startsWith('<system-reminder>') || /<(?:cross-session-message|teammate-message|task-notification)/.test(block.text)) return false
  }
  return peers === 1
}

/** Questions' answers and pairs from a stored AskUserQuestion record (§11b). */
export function questionPairs(input: unknown, result: unknown): readonly QuestionPair[] {
  if (!object(result)) return []
  const question = (text: string) => {
    const normalized = text.replace(/\s+/g, ' ')
    const boundary = normalized.search(/[?:](?:\s|$)/)
    return (boundary >= 0 ? normalized.slice(0, boundary) : normalized.split('.')[0] ?? '').trim()
  }
  const pairs = object(result.answers) ? Object.entries(result.answers).flatMap(([key, value]) => typeof value === 'string' ? [{ question: question(key), answer: value }] : []) : []
  if (pairs.length || typeof result.response !== 'string') return pairs
  const first: unknown = object(input) && Array.isArray(input.questions) ? input.questions[0] : undefined
  return [{ question: object(first) && typeof first.question === 'string' ? question(first.question) : 'a question', answer: result.response }]
}

/**
 * Background runs from the transcript (§9.1, minus the classic.Stop source the
 * fork used, which sec-default skips on org seats): a Bash use with
 * `run_in_background` (or a result marked `backgroundedToDeliverMessage`, spike2
 * M1a) opens one; a KillShell/TaskStop naming it, or a later user entry naming
 * its id in a <tool-use-id> or <task-id> tag (an idle task notification), closes
 * it. A notification delivered mid-turn is not in plain messages() (M1c), so
 * the API tool_result content supplies that close (rationale option B). A run
 * started before a reload is recovered here, its elapsed counted from this
 * load's first sight.
 */
export function backgroundRuns(messages: readonly SessionMessage[], api: readonly ApiMessage[] = []): readonly BackgroundRun[] {
  const running = new Map<CallId, BackgroundRun>()
  const taskCalls = new Map<string, CallId>()
  const close = (id: string) => running.delete(taskCalls.get(id) ?? callId(id))
  for (const entry of messages) {
    if (entry.role === 'user') for (const id of notificationIds(entry.text)) close(id)
    for (const use of entry.toolUses) {
      const result = object(use.result) ? use.result : undefined
      if (use.tool === 'Bash' && (use.input.run_in_background === true || result?.backgroundedToDeliverMessage === true)) {
        const id = callId(use.tool_use_id)
        const label = use.input.description || use.input.command
        const commandLike = typeof label === 'string' && /[;&|<>`$\/\\]|^\s*(?:cd|bash|python\d*(?:\.\d+)*|node|npm|git|pgrep)\b/.test(label)
        const words = callWords(commandLike ? { tool: 'Bash', input: {} } : use, 'present')
        running.set(id, { id, words, isTest: typeof label === 'string' && looksLikeTest(label) })
        if (typeof result?.backgroundTaskId === 'string') taskCalls.set(result.backgroundTaskId, id)
      }
      if (use.tool === 'KillShell' || use.tool === 'TaskStop') {
        const id = use.input.task_id ?? use.input.shell_id
        if (typeof id === 'string' && id) close(id)
      }
    }
  }
  for (const entry of api) {
    if (entry.role !== 'user') continue
    for (const block of entry.content) {
      const text = block.type === 'tool_result' ? block.content : block.type === 'text' ? block.text : undefined
      if (typeof text !== 'string') continue
      for (const notification of text.matchAll(/<task-notification>[\s\S]*?<\/task-notification>/g)) {
        for (const id of notificationIds(notification[0])) close(id)
      }
    }
  }
  return [...running.values()]
}

function notificationIds(text: string): readonly string[] {
  return [...text.matchAll(/<(?:tool-use-id|task-id)>([^<]+)<\/(?:tool-use-id|task-id)>/g)].flatMap(match => match[1]?.trim() ? [match[1].trim()] : [])
}
