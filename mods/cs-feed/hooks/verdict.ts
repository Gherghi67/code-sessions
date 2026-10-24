// ABOUTME: cs-feed's decisions: for each render site, what the row draws, from its own props, the snapshot, the view and this load's observations.
// ABOUTME: Pure functions with no $ and no clock; draw.tsx turns a verdict into a tree. Every decision also says whether it depends on the open turn (then the row reads LIVE).
import type { AgentInfo, PromptOrigin, SessionMessage, UserMessageFrom, UserMessageTask } from 'claude-code'

import type { Observations, Opened, Phase } from './session'
import type { Kind, View } from './settings'
import { modeOf } from './settings'
import type { CallId, FiledCall, Run, Transcript, Turn, TurnId } from './transcript'
import { callId } from './transcript'
import type { ErrorLine, Frame } from './words'
import { repliesOwnSteps, isRefusal, errorLine, callWords, clean, framesFromText, hookTextLine, senderOf, peerHeadline, fit, elapsed, marks } from './words'

/**
 * A call as a row's props show it, from ToolUse or one ToolGroupCall, parsed at
 * the site boundary. Liveness and the call's own outcome come from here, the
 * engine's word on every draw (K3), never from the snapshot: a call cannot be
 * stuck "running" past the moment its row's props say it ended.
 */
export type CallView = {
  readonly id?: CallId // ToolGroupCall.tool_use_id is optional (older desktop): no id, the call draws its own line
  readonly tool: string
  readonly input: Readonly<Record<string, unknown>>
  readonly isRunning: boolean
  readonly isErrored: boolean
  readonly isInterrupted: boolean
  readonly output?: unknown
}

/** What every decision reads. Built once per draw by the shell. */
export type Context = {
  readonly t: Transcript
  readonly view: View
  readonly obs: Observations
  readonly opened: Opened
  /** session.openTurn: the Turn, not an id, since an open turn with no call yet has none. */
  readonly open?: Turn
  readonly phase: Phase
  readonly agents: readonly import('claude-code').AgentInfo[]
  readonly now: number
  readonly surface: 'terminal' | 'desktop' | 'vscode' | 'mobile' | string
  /** Clicks reach a mod: any surface but the terminal, or a fullscreen terminal (§4.6). */
  readonly clickable: boolean
  readonly room: number // columns for text
  /** The desktop band's rate-limit percentages (§9.2), read only for a desktop AbovePrompt draw. */
  readonly usage?: { readonly fiveHour?: number; readonly week?: number }
}

/**
 * A decision, whether it was taken from the open turn's state (the shell then
 * reads LIVE), and which clock tokens what it draws moves with: TICK for an
 * elapsed time or a polled count, PULSE for an animation frame.
 */
export type Decision<V> = { readonly verdict: V; readonly live: boolean; readonly clock?: Clock }

/** The clock tokens a drawing reads besides LIVE; absent: none. */
export type Clock = 'tick' | 'pulse' | 'both'

/** Both drawings' clocks, for a row that stacks several decisions. */
export function clocks(all: readonly (Clock | undefined)[]): Clock | undefined {
  const tick = all.some(clock => clock === 'tick' || clock === 'both')
  const pulse = all.some(clock => clock === 'pulse' || clock === 'both')
  return tick && pulse ? 'both' : tick ? 'tick' : pulse ? 'pulse' : undefined
}

export type CallVerdict =
  | { readonly draw: 'nothing' }
  | { readonly draw: 'turn'; readonly turn: TurnId; readonly done: number; readonly opened: boolean; readonly body: readonly CallVerdict[] }
  | { readonly draw: 'run'; readonly run: Run; readonly naming?: CallId; readonly opened: boolean }
  | { readonly draw: 'call'; readonly call: CallView; readonly filed?: FiledCall; readonly opened: boolean }
  | { readonly draw: 'helper'; readonly call: CallView; readonly state: HelperState; readonly elapsedMs?: number }
  | { readonly draw: 'question'; readonly call: CallView; readonly opened: boolean }

export type HelperState = 'dispatched' | 'running' | 'finished' | 'failed' | 'stopped'

/**
 * A helper's state with no event observed (§7.1): the row's own props, the
 * filed call's agentId (ToolUseSummary) and the polled agent list.
 *   call in flight                      -> dispatched
 *   call answered, its agent still busy -> running   (a background launch)
 *   else errored -> failed, interrupted -> stopped, else finished
 * Elapsed: running -> now - obs.helperStartedAt (absent when this load never
 * saw the spawn: no time, the §7.1 pin); finished -> outcome.durationMs (absent
 * on a background launch: no time).
 */
export function helperState(call: CallView, filed: FiledCall | undefined, agents: readonly import('claude-code').AgentInfo[]): HelperState {
  if (call.isRunning) return 'dispatched'
  const agent = filed?.agentId ? agents.find(agent => agent.id === filed.agentId) : undefined
  if (agent && helperBusy(agent.status)) return 'running'
  if (call.isErrored || agent?.status === 'failed') return 'failed'
  if (call.isInterrupted || agent?.status === 'killed') return 'stopped'
  return 'finished'
}

export function helperBusy(status: string): boolean {
  return status === 'running' || status === 'pending' || status === 'waiting'
}

/**
 * §4.5, for one call. Order of tests:
 *   - rule 1 first for the turn's first call (the turn line), then:
 *   - kind hidden (tool, search, agent, question)            -> nothing
 *     Ruling §20.3: a hidden kind hides the call's own line and run lines made
 *     only of hidden calls, never the turn line: the turn line is the turn's,
 *     not its first call's. Hidden calls still count in "{n} steps this turn".
 *   - helper -> 'helper' (never folded); question -> 'question'
 *   - unfiled (id not in t.calls):
 *       open turn and isRunning -> nothing (a call about to be filed; the next
 *       refresh files it, and LIVE redraws this row); else -> 'call' (history
 *       the snapshot does not hold, drawn from its props)
 *   - then the fork's rules 1-6 with firstOfTurn, firstOfRun, live = isRunning,
 *     spent = (filed.turn !== cx.open?.id), turnOpened = opened.has(`turn-${filed.turn}`)
 *   - rule 1's turn line yields to a reply only when that reply's row DREW
 *     it (`stepsOwner`): the reply anchored to the turn's last filed call
 *     recorded `stepsDrawn` true when it settled its claim. Then the first
 *     call draws nothing (§4.4). While that reply has not settled its claim
 *     (`stepsDrawn` has no entry: not evaluated yet, or evaluated while the
 *     turn was live and left pending) the line stays here and the decision is
 *     live, so the LIVE bump the reply's claim schedules redraws this row.
 *     A fenced reply never claims, so its line stays here in both plugin orders.
 * live = the call's turn is the open turn, or the call is unfiled while a turn is open.
 */
export function decideCall(call: CallView, cx: Context): Decision<CallVerdict> {
  return callDecision(call, cx, true)
}

function callDecision(call: CallView, cx: Context, turnLine: boolean): Decision<CallVerdict> {
  const filed = call.id ? cx.t.calls.get(call.id) : undefined
  const turn = filed ? cx.t.byId.get(filed.turn) : undefined
  // An unfiled call reads LIVE only while a turn is open (it may be about to be filed, rationale decision 8);
  // while idle it is history older than the snapshot's window, or id-less, and no refresh will file it.
  const live = filed ? filed.turn === cx.open?.id : cx.open !== undefined
  const opened = filed ? cx.opened.has(`turn-${filed.turn}`) : false
  const folded = cx.view.group && !(!live && cx.view.keep)
  if (filed && turn && folded && turnLine && turn.first === filed.id) {
    const owner = stepsOwner(filed.turn, cx)
    if (typeof owner === 'object') return { verdict: { draw: 'nothing' }, live }
    const done = turn.steps.filter(id => cx.t.calls.get(id)?.outcome.state === 'done').length
    return { verdict: !done && !opened ? { draw: 'nothing' } : { draw: 'turn', turn: filed.turn, done, opened, body: opened ? [callDecision(call, cx, false).verdict] : [] }, live: live || owner === 'pending' }
  }
  const refused = call.isErrored && typeof call.output === 'string' && isRefusal(call.output)
  const cls = filed?.cls ?? (refused ? 'machinery' : call.tool === 'Agent' || call.tool === 'Task' ? 'helper' : call.tool === 'AskUserQuestion' ? 'question' : 'machinery')
  if (hidden(cx.view, callKind(call.tool, cls))) return { verdict: { draw: 'nothing' }, live }
  if (cls === 'helper') {
    const state = helperState(call, filed, cx.agents)
    const started = call.id ? cx.obs.helperStartedAt.get(call.id) : undefined
    const elapsedMs = state === 'running' || state === 'dispatched' ? started === undefined ? undefined : Math.max(0, cx.now - started) : filed?.outcome.state === 'done' ? filed.outcome.durationMs : undefined
    // A running helper's end comes from the tick's agent list and its elapsed from the clock; a dispatched one's end is its own row's props.
    return { verdict: { draw: 'helper', call, state, elapsedMs }, live, clock: state === 'running' || (state === 'dispatched' && elapsedMs !== undefined) ? 'tick' : undefined }
  }
  if (cls === 'question') return { verdict: { draw: 'question', call, opened: call.id ? cx.opened.has(call.id) : false }, live }
  if (!filed && cx.open && call.isRunning) return { verdict: { draw: 'nothing' }, live }
  if (filed?.cls === 'machinery' && folded && !opened) return { verdict: { draw: 'nothing' }, live }
  if (filed && !live && !cx.view.keep && cx.view.clear && !opened) return { verdict: { draw: 'nothing' }, live }
  if (filed && cx.view.group && call.isRunning && !opened) return { verdict: { draw: 'nothing' }, live }
  if (filed?.run && (cx.view.commands === 'grouped' || (!live && cx.view.after === 'clear' && !cx.view.keep && !opened))) return { verdict: runDecision(call, filed, cx), live }
  return { verdict: { draw: 'call', call, filed, opened: cx.view.style === 'expanded' || (call.id ? cx.opened.has(call.id) : false) }, live }
}

function callKind(tool: string, cls = 'machinery'): Kind {
  return cls === 'helper' ? 'agent' : cls === 'question' ? 'question' : tool === 'WebSearch' || tool === 'WebFetch' ? 'search' : 'tool'
}

function runDecision(call: CallView, filed: FiledCall, cx: Context): CallVerdict {
  const stored = filed.run ? cx.t.runs.get(filed.run) : undefined
  if (!stored) return { draw: 'call', call, filed, opened: cx.opened.has(filed.id) }
  const visible = stored.calls.filter(id => { const member = cx.t.calls.get(id); return member && !hidden(cx.view, callKind(member.tool, member.cls)) })
  if (visible[0] !== filed.id) return { draw: 'nothing' }
  const naming = !cx.view.group || !cx.open ? visible.findLast(id => id === filed.id ? call.isRunning : cx.t.calls.get(id)?.outcome.state === 'running') : undefined
  return { draw: 'run', run: { ...stored, calls: visible }, naming, opened: cx.view.style === 'expanded' || cx.opened.has(`open-${stored.id}`) }
}

/**
 * Who draws a turn's steps line, as the tool row sees it:
 *
 *   last = the turn's last filed call; uuid = obs.latestByCall.get(last)
 *   no uuid, `said` hidden, or !repliesOwnSteps(text) -> 'tool'
 *   obs.stepsDrawn.get(uuid) === true                  -> { reply: uuid }   (the tool row draws nothing)
 *   === false                                          -> 'tool'
 *   no entry yet (not evaluated, or pending)           -> 'pending'         (the tool row draws it, live)
 *
 * The reply row's side is decideReply's claim (StepsClaim). An evaluation of
 * a reply with no record yet:
 *   cannot own the line (no anchor, `said` hidden, a fenced anchored text,
 *   or not latestByCall.get(last))                     -> 'declined'
 *   could own it, its turn still live                  -> 'pending': no line, reads LIVE
 *   could own it, its turn spent (cx.phase 'idle', or not the open turn):
 *     handed the anchored text                         -> 'drawn'
 *     handed other text (a fragment)                   -> 'declined'
 * site() records a settled claim once (session.noteStepsDrawn) and every
 * later evaluation of that row reuses it; a pending claim records nothing.
 * So exactly one row draws the line once the claim settles, and a claimed
 * line is never stale: a spent turn gets no more calls.
 *
 * Why a recorded claim, not a shared derivation: the reply is evaluated only
 * right after it is stored (spike5 M18), and, while pending, at each LIVE
 * bump. Without a Stop hook (spike5's rig) turn.complete comes first, the
 * reply's first evaluation claims, and the tool row, live while pending,
 * yields at the claim's LIVE bump. With one (cs sessions; spike4's rig, 36 of
 * 36 turns, open-measurements M27) the Stop hook runs between the reply's
 * store and turn.complete: the reply's first evaluations find the turn live
 * and stay pending; turn.complete's phase change bumps LIVE, which
 * re-evaluates the reply (§20.23 (a));
 * it finds the turn spent and claims, and its claim's bump makes the tool row
 * yield. A derivation both rows evaluate at different moments drew it nowhere
 * in that order. Keyed by the turn's LAST call: a reply followed by more
 * calls is never the owner (a pending one settles 'declined' at the refresh
 * that files the next call).
 */
export function stepsOwner(turn: TurnId, cx: Context): 'tool' | 'pending' | { readonly reply: string } {
  const last = [...cx.t.calls.values()].filter(call => call.turn === turn).at(-1)
  const uuid = last ? cx.obs.latestByCall.get(last.id) : undefined
  const anchor = uuid ? cx.obs.anchors.get(uuid) : undefined
  if (!uuid || !anchor || hidden(cx.view, 'said') || !repliesOwnSteps(anchor.text)) return 'tool'
  const drawn = cx.obs.stepsDrawn.get(uuid)
  return drawn === true ? { reply: uuid } : drawn === false ? 'tool' : 'pending'
}

export type GroupVerdict =
  | { readonly draw: 'engine' } // ctrl+o (isExpanded), or a group a hook other than ours set apart
  | { readonly draw: 'batch'; readonly key: string; readonly opened: boolean; readonly helpers: readonly BatchHelper[]; readonly elapsedMs?: number }
  | { readonly draw: 'stack'; readonly calls: readonly CallVerdict[] } // each call's own verdict, stacked; all 'nothing' draws nothing

export type BatchHelper = { readonly call: CallView; readonly kind: string; readonly state: HelperState }

/**
 * A ToolGroup row is drawn here, never unfolded: unfolding would hand the
 * engine's ToolUse rows `isExpanded: true` (IDX ToolUse.isExpanded), which is
 * how ctrl+o says itself, and the fork had to infer ctrl+o globally (C2). So a
 * group passes through on its own `isExpanded` and otherwise stacks its calls'
 * decisions; ctrl+o needs no module flag.
 */
export function decideGroup(props: { calls: readonly CallView[]; isActive: boolean; isExpanded: boolean; isCallsOnly?: boolean }, cx: Context): Decision<GroupVerdict> {
  if (props.isExpanded || props.isCallsOnly !== true) return { verdict: { draw: 'engine' }, live: false }
  const decisions = props.calls.map(call => decideCall(call, cx))
  const live = decisions.some(decision => decision.live)
  if (props.calls.length >= 2 && !hidden(cx.view, 'agent') && props.calls.every(call => call.id && cx.t.calls.get(call.id)?.cls === 'helper')) {
    const helpers = props.calls.map(call => ({ call, kind: typeof call.input.subagent_type === 'string' ? call.input.subagent_type : 'general-purpose', state: helperState(call, call.id ? cx.t.calls.get(call.id) : undefined, cx.agents) }))
    const starts = props.calls.flatMap(call => { const at = call.id ? cx.obs.helperStartedAt.get(call.id) : undefined; return at === undefined ? [] : [at] })
    const ends = props.calls.flatMap(call => {
      const start = call.id ? cx.obs.helperStartedAt.get(call.id) : undefined
      const outcome = call.id ? cx.t.calls.get(call.id)?.outcome : undefined
      return start !== undefined && outcome?.state === 'done' && outcome.durationMs !== undefined ? [start + outcome.durationMs] : []
    })
    const running = helpers.some(helper => helper.state === 'running' || helper.state === 'dispatched')
    const end = running ? cx.now : ends.length ? Math.max(...ends) : undefined
    const key = `helpers-${props.calls[0]?.id}`
    // §7.2 while any runs: the spinner turns (PULSE), the elapsed and the states move with the tick.
    return { verdict: { draw: 'batch', key, opened: cx.opened.has(key), helpers, elapsedMs: starts.length && end !== undefined ? Math.max(0, end - Math.min(...starts)) : undefined }, live, clock: running ? 'both' : undefined }
  }
  return { verdict: { draw: 'stack', calls: decisions.map(decision => decision.verdict) }, live, clock: clocks(decisions.map(decision => decision.clock)) }
}

/** ToolResult: nothing when its call is filed (the result rides on the call's chip and opened output); else the engine's (§4.8). */
export function decideToolResult(id: CallId, isExpanded: boolean | undefined, cx: Context): 'nothing' | 'engine' {
  return !isExpanded && cx.t.calls.has(id) ? 'nothing' : 'engine'
}

export type UserRow = {
  readonly uuid: string
  readonly text: string
  readonly origin: PromptOrigin
  readonly isExpanded: boolean
  readonly task?: UserMessageTask
  readonly from?: UserMessageFrom
}

export type UserVerdict =
  | { readonly draw: 'engine' }
  | { readonly draw: 'nothing' }
  | { readonly draw: 'you'; readonly text: string; readonly at?: number }
  | { readonly draw: 'hookText'; readonly line: string }
  | { readonly draw: 'frames'; readonly frames: readonly (Frame & { readonly from: string })[] }
  | { readonly draw: 'peer'; readonly sender: string; readonly headline: string; readonly nested?: true } // nested: a member row of an opened burst, indented by 2
  | { readonly draw: 'burst'; readonly members: readonly { uuid: string; sender: string; at?: number }[]; readonly opened: boolean; readonly own?: { readonly sender: string; readonly headline: string } } // own: the head's message, its indented line while opened
  | { readonly draw: 'helperNote'; readonly durationMs?: number; readonly headline: string }
  | { readonly draw: 'backgroundNote' }

/**
 * §8.1 routing, terminal and desktop, isExpanded -> engine. Ruling §20.8: a
 * task notification is a helper's when ctx.agents knows task.id or the filed
 * call task.toolUseId is a helper; a filed non-helper call is a background
 * task; an id neither knows reads as a background task, not a helper.
 */
export function decideUser(row: UserRow, cx: Context): Decision<UserVerdict> {
  const answer = (verdict: UserVerdict): Decision<UserVerdict> => ({ verdict, live: false })
  if (row.isExpanded || !drawsOrigin(row.origin.kind)) return answer({ draw: 'engine' })
  const origin = row.origin.kind
  const typed = origin === 'composer' || origin === 'bridge' || origin === 'sdk'
  const hook = hookTextLine(row.text)
  if (!typed && origin !== 'task-notification') {
    const frames = (cx.obs.frames.get(row.uuid) ?? framesFromText(row.text)).map(frame => ({ ...frame, from: frame.from || (row.from?.name ? senderOf(row.from) : 'helper') }))
    if (frames.length) return answer(hidden(cx.view, 'peer') ? { draw: 'nothing' } : { draw: 'frames', frames })
  }
  if (typed || origin === 'scheduled-trigger' || (origin === 'unclassified' && !row.from?.name && !hook)) {
    if (cx.surface !== 'terminal') return answer({ draw: 'engine' })
    return answer(hidden(cx.view, 'you') ? { draw: 'nothing' } : { draw: 'you', text: row.text, at: cx.obs.promptAt.get(row.uuid) })
  }
  if (hook) return answer({ draw: 'hookText', line: hook })
  if (origin === 'task-notification') {
    const filed = row.task?.toolUseId ? cx.t.calls.get(callId(row.task.toolUseId)) : undefined
    const helper = filed?.cls === 'helper' || cx.agents.some(agent => agent.id === row.task?.id)
    if (helper) return answer(hidden(cx.view, 'helper') ? { draw: 'nothing' } : { draw: 'helperNote', durationMs: row.task?.durationMs, headline: peerHeadline(row.text, cx.room) })
    return answer(cx.view.clear && !cx.view.keep ? { draw: 'nothing' } : { draw: 'backgroundNote' })
  }
  if (hidden(cx.view, 'peer')) return answer({ draw: 'nothing' })
  const head = cx.obs.bursts.of.get(row.uuid)
  const members = head ? cx.obs.bursts.members.get(head) : undefined
  const live = head === row.uuid && cx.obs.bursts.open === head
  const own = { sender: senderOf(row.from, row.text), headline: peerHeadline(row.text, cx.room - 2) }
  if (head && members && members.length >= 2) {
    // §8.2: the rest draw nothing until the burst is opened; then each message, the head's included, is its own indented line.
    const opened = cx.opened.has(`burst-${head}`)
    if (head === row.uuid) return { verdict: { draw: 'burst', members, opened, ...(opened ? { own } : {}) }, live }
    if (!opened) return answer({ draw: 'nothing' })
    return { verdict: { draw: 'peer', ...own, nested: true }, live }
  }
  return { verdict: { draw: 'peer', sender: own.sender, headline: peerHeadline(row.text, cx.room) }, live }
}

/**
 * The origins §8.1 routes: typed rows, task notifications, scheduled
 * triggers, peer and teammate messages, and unclassified rows. Every other
 * kind is unmeasured, so its row keeps the engine's drawing. Exhaustive over
 * the contract's kinds: a kind the engine adds fails to compile here instead
 * of drawing as a peer line.
 */
function drawsOrigin(kind: PromptOrigin['kind']): boolean {
  switch (kind) {
    case 'composer': case 'bridge': case 'sdk': case 'task-notification': case 'scheduled-trigger':
    case 'peer': case 'peer-send-message': case 'unclassified':
      return true
    case 'projects-relay': case 'channel': case 'coordinator': case 'observer': case 'observer-activity':
    case 'auto-continuation': case 'slack-ping': case 'plugin':
      return false
  }
}

export type ReplyVerdict = {
  /** The engine draws the text, with isFirstOfReply rewritten to false so it draws no bullet of its own. */
  readonly body: 'engine' | 'nothing' | { readonly error: ErrorLine }
  readonly name: boolean // the "claude" margin: first block of a reply, terminal only
  readonly stepsLine?: CallVerdict // §4.4, the turn line moved under this reply
}

/** The reply row's side of the steps line (stepsOwner): settled ('drawn', 'declined') and recorded once, or 'pending' while its turn is live. */
export type StepsClaim = 'drawn' | 'declined' | 'pending'

/**
 * A reply decision is live exactly while its steps-line claim is pending
 * (§20.23 (a)): a pending reply reads
 * LIVE so that turn.complete's bump re-evaluates it, and it draws no steps
 * line yet (the tool row does). A settled claim never reads LIVE: the reply
 * is not evaluated while it streams and twice once stored (spike5 M18), so
 * nothing a LIVE read could redraw remains for it.
 */
export type ReplyDecision =
  | { readonly verdict: ReplyVerdict; readonly claim: 'drawn' | 'declined'; readonly live: false }
  | { readonly verdict: ReplyVerdict & { readonly stepsLine?: never }; readonly claim: 'pending'; readonly live: true }

/**
 * AssistantMessage. Error detection runs before the `said` check (ruling §20.2:
 * hiding what Claude said never hides that the reply failed), and the safeguard
 * rules require an error prefix or a whole one-line reply (ruling §20.6). On desktop the body stays the
 * engine's own and the steps line is still attached under it (ruling §20.1).
 *
 * Live only while its steps-line claim is pending (ReplyDecision, ruling
 * §20.23 (a)): the instance is not evaluated while the reply streams and is
 * evaluated twice once stored (+6-9 ms and +13-26 ms after the append), then
 * not again while idle unless it read LIVE (spike5 M18). Whether the turn is
 * spent at those evaluations depends on whether a Stop hook runs
 * (stepsOwner): without one it is, and the first evaluation settles the
 * claim; with one (every cs session) it is not, the claim stays pending, and
 * the LIVE bump at turn.complete re-evaluates this one instance, which then
 * settles it. site() records a settled claim once (obs.stepsDrawn); later
 * evaluations reuse it and are not live. `row.uuid` is
 * AssistantMessage.requestId, the append's e.uuid (M17).
 *
 * Whole reply or fragment (finding 6): `row.text` is what the hook was handed.
 * With cs-mermaid outer it is one prose part of a fenced reply. The steps line
 * is drawn only when obs.stepsDrawn says this uuid claimed it (or, at the
 * evaluation that settles the claim, the claim rule in stepsOwner holds) and
 * row.text === anchor.text: at most once, and never on a fragment. A fragment
 * read while the turn is live leaves the claim pending (the stored text may
 * still replace a pre-next anchor text); one read once the turn is spent
 * settles it 'declined'. A
 * fragment (text differs from the anchored text) draws `body: 'engine'` with
 * no margin, so the prose parts line up with the diagrams cs-mermaid draws
 * between them. A reply this load did not observe has no anchor and cannot be
 * told from a fragment: it draws the margin (residual, rationale finding 6).
 *
 *   order            diagram-only            prose · diagram · prose
 *   feed outer       margin around mermaid's  margin around mermaid's whole
 *                    drawing; line on tool    drawing; line on tool row
 *                    row (fenced)             (fenced)
 *   mermaid outer    feed not called: the     feed called twice, each a fragment:
 *                    engine/mermaid look,     engine look, no line, no margin;
 *                    line on tool row         line on tool row
 */
export function decideReply(row: { uuid: string; text: string; isFirstOfReply: boolean }, cx: Context): ReplyDecision {
  const anchor = cx.obs.anchors.get(row.uuid)
  const filed = anchor ? cx.t.calls.get(anchor.call) : undefined
  const turn = filed ? cx.t.byId.get(filed.turn) : undefined
  const last = turn?.id ? [...cx.t.calls.values()].filter(call => call.turn === turn.id).at(-1) : undefined
  const fragment = anchor !== undefined && anchor.text !== row.text
  const spent = cx.phase === 'idle' || turn !== cx.open
  const eligible = anchor && turn?.first && last?.id === anchor.call && cx.obs.latestByCall.get(last.id) === row.uuid && !hidden(cx.view, 'said') && repliesOwnSteps(anchor.text) && cx.view.group && !(spent && cx.view.keep)
  const recorded = cx.obs.stepsDrawn.get(row.uuid)
  const claim: StepsClaim = recorded !== undefined ? recorded ? 'drawn' : 'declined' : !eligible ? 'declined' : !spent ? 'pending' : fragment ? 'declined' : 'drawn'
  const error = fragment ? undefined : errorLine(row.text)
  const verdict: Omit<ReplyVerdict, 'stepsLine'> = { body: error ? { error } : hidden(cx.view, 'said') ? 'nothing' : 'engine', name: !error && !hidden(cx.view, 'said') && !fragment && row.isFirstOfReply && cx.surface === 'terminal' }
  if (claim === 'pending') return { verdict, claim, live: true }
  if (claim !== 'drawn' || !eligible || fragment || !turn?.id || !turn.first) return { verdict, claim, live: false }
  const done = turn.steps.filter(id => cx.t.calls.get(id)?.outcome.state === 'done').length
  const opened = cx.opened.has(`turn-${turn.id}`)
  const first = cx.t.calls.get(turn.first)
  const stepsLine: CallVerdict = { draw: 'turn', turn: turn.id, done, opened, body: opened && first ? [callDecision(callView(first), cx, false).verdict] : [] }
  return { verdict: { ...verdict, stepsLine }, claim, live: false }
}

function callView(filed: FiledCall): CallView {
  return { id: filed.id, tool: filed.tool, input: filed.input, isRunning: filed.outcome.state === 'running', isErrored: filed.outcome.state === 'done' && filed.outcome.errored, isInterrupted: filed.outcome.state === 'done' && filed.outcome.interrupted, output: filed.outcome.state === 'done' ? filed.outcome.output : undefined }
}

export type SpinnerVerdict =
  | { readonly draw: 'engine' } // props untouched
  | { readonly draw: 'rewrite'; readonly message: string; readonly suffix: '' } // our words; the engine draws the row, clock, tokens and tip
// No 'nothing' arm: hiding the row is replacing it (ruling 15, rationale). A bare line after a turn passes through.

/**
 * §5. Only when the engine's message is null: words = live call's present
 * words (group on, machinery) | 'Writing' (group on, and the row's own
 * `mode === 'responding'`) | 'Working' (steps > 0) | 'Thinking'; + ' · step N'
 * (N counts what the turn line counts,
 * ruling §20.12); + ' · N helper(s) working'. With a message of the engine's own
 * (compaction) the row is the engine's, suffix included (ruling §20.9).
 *
 * The reply row is stored only once it has streamed (spike5 M18), so
 * the tail says 'text' only after the writing is over. `mode` is the engine's
 * own word on what the turn does. That the Spinner instance is re-evaluated
 * when `mode` changes is inferred (a prop change), not measured
 * (open-measurements M22).
 */
export function decideSpinner(props: { message: string | null; mode: 'requesting' | 'responding' | 'thinking' | 'tool-input' | 'tool-use' }, cx: Context): Decision<SpinnerVerdict> {
  if (props.message !== null || !cx.open) return { verdict: { draw: 'engine' }, live: false }
  const steps = cx.open.steps.length
  const running = cx.open.steps.map(id => cx.t.calls.get(id)).findLast(call => call?.outcome.state === 'running')
  const words = cx.view.group && props.mode === 'responding' ? 'Writing' : cx.view.group && running ? callWords(running, 'present') : steps ? 'Working' : 'Thinking'
  const helpers = cx.agents.filter(agent => !agent.parentId && (agent.status === 'running' || agent.status === 'pending')).length
  const message = words + (steps ? ` · step ${steps}` : '') + (helpers ? ` · ${helpers} ${helpers === 1 ? 'helper' : 'helpers'} working` : '')
  // The helper count is the tick's agent list (§5.1), so the line reads TICK while it counts any.
  return { verdict: { draw: 'rewrite', message, suffix: '' }, live: true, clock: helpers ? 'tick' : undefined }
}

export type BandVerdict =
  | { readonly draw: 'engine' }
  | { readonly draw: 'desktop'; readonly usage: { fiveHour?: number; week?: number }; readonly pills: readonly Pill[] }
  | { readonly draw: 'helpers'; readonly head: string; readonly kinds: readonly { kind: string; cells: string; done: number; n: number }[]; readonly more: number; readonly spinning: boolean }
  | { readonly draw: 'background'; readonly words: string; readonly isTest: boolean; readonly more: number; readonly elapsedMs?: number; readonly typing: boolean }
export type Pill = { readonly kind: 'helper' | 'job' | 'test'; readonly words: string; readonly elapsedMs?: number }

/**
 * §9.3: ours stacked ABOVE whatever next(e) drew (cs's band included), one
 * engine pass, survey -> engine. Rows: maxRows - 2 for the band beneath, minus
 * the head; kinds beyond fold into "+N more kinds" (§7.3c). Background line only
 * with no open turn and no helper line.
 *
 * What the band reads (rationale "Cost while on: the band hook"; idle with
 * nothing to show it reads no token and the feed never redraws it):
 *   LIVE   while a turn is open (the engine's isWorking, or the open turn) or a
 *          helper is known (busy, or kept in the batch): a spawn's refresh
 *          bumps LIVE when Seen.helpers changed, so the band learns of a helper
 *          from the agent.spawn hook, never by polling
 *   TICK   while it shows an elapsed time or a count the 1 s tick moves
 *   PULSE  while it animates (the helper spinner, the breathing dot)
 */
export function decideBand(props: { hasSurvey: boolean; isWorking: boolean; maxRows: number; bodyColumns: number }, usage: { fiveHour?: number; week?: number }, cx: Context): Decision<BandVerdict> {
  const agents = cx.agents.filter(agent => !agent.parentId && !agent.teammateId)
  const helpersKnown = agents.some(agent => helperBusy(agent.status)) || cx.obs.batch.kinds.size > 0
  const live = props.isWorking || cx.open !== undefined || helpersKnown
  const answer = (verdict: BandVerdict, clock?: Clock): Decision<BandVerdict> => ({ verdict, live, clock })
  if (props.hasSurvey) return { verdict: { draw: 'engine' }, live: false }
  const background = cx.t.background.filter(run => !cx.obs.bgEnded.has(run.id) && !cx.agents.some(agent => agent.id === run.id || agent.teammateId === run.id || agent.description === run.words))
  const elapsedMs = (id: CallId) => { const at = cx.obs.bgSeenAt.get(id); return at === undefined ? undefined : Math.max(0, cx.now - at) }
  if (cx.surface === 'desktop') {
    const pills: Pill[] = [...agents.filter(agent => agent.status === 'running').map(agent => ({ kind: 'helper' as const, words: fit(agent.description, 28) })), ...background.map(run => ({ kind: run.isTest ? 'test' as const : 'job' as const, words: run.words, elapsedMs: elapsedMs(run.id) }))]
    if (usage.fiveHour === undefined && usage.week === undefined && !pills.length) return answer({ draw: 'engine' })
    const moving = pills.some(pill => pill.elapsedMs !== undefined)
    const turning = pills.some(pill => pill.kind === 'helper')
    return answer({ draw: 'desktop', usage, pills }, moving && turning ? 'both' : moving ? 'tick' : turning ? 'pulse' : undefined)
  }
  if (agents.some(agent => helperBusy(agent.status))) {
    const members = [...cx.obs.batch.kinds].map(([id, kind]) => ({ kind, status: agents.find(agent => agent.id === id)?.status ?? 'completed' }))
    const running = members.filter(member => helperBusy(member.status)).length
    const failed = members.filter(member => member.status === 'failed' || member.status === 'killed').length
    const done = members.length - running - failed
    const kinds = new Map<string, { kind: string; cells: string; done: number; n: number }>()
    for (const member of members) {
      const kind = kinds.get(member.kind) ?? { kind: fit(member.kind === 'general-purpose' ? 'general' : member.kind, 18), cells: '', done: 0, n: 0 }
      const working = helperBusy(member.status)
      const failed = member.status === 'failed' || member.status === 'killed'
      kind.cells += working ? marks.working : failed ? marks.failed : marks.live
      kind.done += !working && !failed ? 1 : 0
      kind.n++
      kinds.set(member.kind, kind)
    }
    const room = Math.max(0, props.maxRows - 3)
    const shown = kinds.size > room ? Math.max(0, room - 1) : room
    const head = [`${members.length} ${members.length === 1 ? 'helper' : 'helpers'}`, ...(done ? [`${done} done`] : []), ...(running ? [`${running} running`] : []), ...(failed ? [`${failed} failed`] : []), ...(cx.obs.batch.startedAt === undefined ? [] : [elapsed(cx.now - cx.obs.batch.startedAt)])].join(' · ')
    // Busy helpers: the counts move with the tick's agent list and the head's elapsed with the clock; the spinner turns.
    return answer({ draw: 'helpers', head, kinds: [...kinds.values()].slice(0, shown), more: Math.max(0, kinds.size - shown), spinning: running > 0 }, running > 0 ? 'both' : 'tick')
  }
  const first = background[0]
  if (!first || props.isWorking || cx.open) return answer({ draw: 'engine' })
  const shownElapsed = elapsedMs(first.id)
  return answer({ draw: 'background', words: first.words, isTest: background.some(run => run.isTest), more: background.length - 1, elapsedMs: shownElapsed, typing: props.bodyColumns >= 90 }, shownElapsed === undefined ? 'pulse' : 'both')
}

/** One helper in the Helpers pane (§7.4): its head's parts, its current step while it works, and its own last calls in words. */
export type HelperBlock = {
  readonly name: string
  readonly status: 'working' | 'finished' | 'failed' | 'stopped'
  readonly elapsedMs?: number
  readonly now?: string
  readonly calls: readonly string[]
}

/**
 * §7.4: the last 6 top-level helpers of `agents` (as $.agent.list() orders
 * them), newest first. A running helper's elapsed comes from the spawn this
 * load saw (helperStartedAt, by its Agent call, found through the call's
 * agentId); a finished one's from the call's durationMs; neither known: no
 * time. Its own calls are the last 12 tool uses of its transcript (`own`, by
 * agent id), present while a call has no result, past once it has one; "now"
 * is the newest call's present words while the helper works. An unreadable
 * transcript (`own` has undefined) leaves the head alone (§7.4 (c)).
 */
export function decideHelpersPane(agents: readonly AgentInfo[], t: Transcript, own: ReadonlyMap<string, readonly SessionMessage[] | undefined>, obs: Observations, now: number): readonly HelperBlock[] {
  const crew = agents.filter(agent => !agent.parentId && !agent.teammateId).slice(-6).reverse()
  return crew.map(agent => {
    const working = helperBusy(agent.status)
    const filed = [...t.calls.values()].find(call => call.agentId === agent.id)
    const started = filed ? obs.helperStartedAt.get(filed.id) : undefined
    const elapsedMs = working ? started === undefined ? undefined : Math.max(0, now - started) : filed?.outcome.state === 'done' ? filed.outcome.durationMs : undefined
    const uses = (own.get(agent.id) ?? []).flatMap(message => message.toolUses).slice(-12)
    const done = (use: (typeof uses)[number]) => use.result !== undefined || use.text !== undefined
    const last = uses.at(-1)
    return {
      name: clean(agent.description) || agent.name || agent.type || 'helper',
      status: working ? 'working' : agent.status === 'failed' ? 'failed' : agent.status === 'killed' ? 'stopped' : 'finished',
      elapsedMs,
      now: working && last ? callWords(last, 'present') : undefined,
      calls: uses.map(use => callWords(use, done(use) ? 'past' : 'present')),
    }
  })
}

/** CommandOutput §3.3: dim "·" and the text, red on error, a leading "cs-feed:" removed; isExpanded -> engine. */
export function decideCommandOutput(props: { command: string; text: string; isErrored: boolean }, cx: Context): 'engine' | 'nothing' | { text: string; isErrored: boolean } {
  const text = props.text.trim().replace(/^cs-feed:\s*/, '').trim()
  return text ? { text, isErrored: props.isErrored } : 'nothing'
}

/** SessionMode §3.5: append "feed {mode} · /feed to switch" while this session's feed is on. Off (raw), site() passes the row through before any painter runs, so this never says "feed raw". */
export function sessionModes(modes: readonly string[], view: View): readonly string[] {
  return [...modes, `feed ${modeOf({ on: true, view })} · /feed to switch`]
}

/** Shared with the pane: is a kind hidden? */
export function hidden(view: View, kind: Kind): boolean {
  return view.hide.includes(kind)
}
