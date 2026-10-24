// ABOUTME: cs-feed's decisions: for each render site, what the row draws, from its own props, the snapshot, the view and this load's observations.
// ABOUTME: Pure functions with no $ and no clock; draw.tsx turns a verdict into a tree. Every decision also says whether it depends on the open turn (then the row reads LIVE).
import type { PromptOrigin, UserMessageFrom, UserMessageTask } from 'claude-code'

import type { Observations, Opened, Phase } from './session'
import type { Kind, View } from './settings'
import type { CallId, FiledCall, Run, Transcript, Turn, TurnId } from './transcript'
import type { ErrorLine, Frame } from './words'

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
}

/** A decision and whether it was taken from the open turn's state (the shell then reads LIVE). */
export type Decision<V> = { readonly verdict: V; readonly live: boolean }

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
  throw new Error('not implemented')
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
 * live = the call's turn is the open turn, or the call is unfiled.
 */
export function decideCall(call: CallView, cx: Context): Decision<CallVerdict> {
  throw new Error('not implemented')
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
 * re-evaluates the reply (ruling §20.23 (a), accepted by Alex 2026-10-24);
 * it finds the turn spent and claims, and its claim's bump makes the tool row
 * yield. A derivation both rows evaluate at different moments drew it nowhere
 * in that order. Keyed by the turn's LAST call: a reply followed by more
 * calls is never the owner (a pending one settles 'declined' at the refresh
 * that files the next call).
 */
export function stepsOwner(turn: TurnId, cx: Context): 'tool' | 'pending' | { readonly reply: string } {
  throw new Error('not implemented')
}

export type GroupVerdict =
  | { readonly draw: 'engine' } // ctrl+o (isExpanded), or a group a hook other than ours set apart
  | { readonly draw: 'batch'; readonly helpers: readonly CallView[] } // §7.2: two or more helper launches, all known
  | { readonly draw: 'stack'; readonly calls: readonly CallVerdict[] } // each call's own verdict, stacked; all 'nothing' draws nothing

/**
 * A ToolGroup row is drawn here, never unfolded: unfolding would hand the
 * engine's ToolUse rows `isExpanded: true` (IDX ToolUse.isExpanded), which is
 * how ctrl+o says itself, and the fork had to infer ctrl+o globally (C2). So a
 * group passes through on its own `isExpanded` and otherwise stacks its calls'
 * decisions; ctrl+o needs no module flag.
 */
export function decideGroup(props: { calls: readonly CallView[]; isActive: boolean; isExpanded: boolean }, cx: Context): Decision<GroupVerdict> {
  throw new Error('not implemented')
}

/** ToolResult: nothing when its call is filed (the result rides on the call's chip and opened output); else the engine's (§4.8). */
export function decideToolResult(id: CallId, isExpanded: boolean | undefined, cx: Context): 'nothing' | 'engine' {
  throw new Error('not implemented')
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
  | { readonly draw: 'frames'; readonly frames: readonly Frame[] }
  | { readonly draw: 'peer'; readonly sender: string; readonly headline: string }
  | { readonly draw: 'burst'; readonly members: readonly { uuid: string; sender: string; at?: number }[]; readonly opened: boolean }
  | { readonly draw: 'helperNote'; readonly durationMs?: number; readonly headline: string }
  | { readonly draw: 'backgroundNote' }

/**
 * §8.1 routing, terminal and desktop, isExpanded -> engine. Ruling §20.8: a
 * task notification is a helper's when ctx.agents knows task.id or the filed
 * call task.toolUseId is a helper; a filed non-helper call is a background
 * task; an id neither knows reads as a background task, not a helper.
 */
export function decideUser(row: UserRow, cx: Context): Decision<UserVerdict> {
  throw new Error('not implemented')
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
 * (ruling §20.23 (a), accepted by Alex 2026-10-24): a pending reply reads
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
 * rules require an error prefix (ruling §20.6). On desktop the body stays the
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
  throw new Error('not implemented')
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
 * "Writing" moved here from the transcript's tail (revision 1 read `tail
 * 'text'`): the reply row is stored only once it has streamed (spike5 M18), so
 * the tail says 'text' only after the writing is over. `mode` is the engine's
 * own word on what the turn does. That the Spinner instance is re-evaluated
 * when `mode` changes is inferred (a prop change), not measured
 * (open-measurements M22).
 */
export function decideSpinner(props: { message: string | null; mode: 'requesting' | 'responding' | 'thinking' | 'tool-input' | 'tool-use' }, cx: Context): Decision<SpinnerVerdict> {
  throw new Error('not implemented')
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
 */
export function decideBand(props: { hasSurvey: boolean; isWorking: boolean; maxRows: number; bodyColumns: number }, usage: { fiveHour?: number; week?: number }, cx: Context): Decision<BandVerdict> {
  throw new Error('not implemented')
}

/** CommandOutput §3.3: dim "·" and the text, red on error, a leading "cs-feed:" removed; isExpanded -> engine. */
export function decideCommandOutput(props: { command: string; text: string; isErrored: boolean }, cx: Context): 'engine' | 'nothing' | { text: string; isErrored: boolean } {
  throw new Error('not implemented')
}

/** SessionMode §3.5: append "feed {mode} · /feed to switch" while this session's feed is on. Off (raw), site() passes the row through before any painter runs, so this never says "feed raw". */
export function sessionModes(modes: readonly string[], view: View): readonly string[] {
  throw new Error('not implemented')
}

/** Shared with the pane: is a kind hidden? */
export function hidden(view: View, kind: Kind): boolean {
  return view.hide.includes(kind)
}
