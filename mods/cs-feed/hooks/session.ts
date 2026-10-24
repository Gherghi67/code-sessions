// ABOUTME: cs-feed's per-load core: this session's record (mirror of .cs/local/feed and feed-view), the transcript snapshot and its refresh, the observations and the clocks.
// ABOUTME: A new Load is made by every register(); $.state holds only three redraw tokens, written only from $.clock callbacks; the record is written only from event hooks.
import type { EngineInterface } from 'claude-code'
import { atom, read } from 'claude-code'

import type { Session } from './settings'
import { CS_LOCAL, FEED_FILE, OFF_LINE, ON_LINE, VIEW_FILE, VET_TIMEOUT_MS, isOn, parseStoredView, viewText } from './settings'
import type { CallId, Transcript, Turn } from './transcript'
import { buildTranscript, callId, EMPTY } from './transcript'

type $ = EngineInterface

/**
 * Redraw tokens. None holds a fact: the value is a counter whose only use is
 * that a write redraws the drawings that read it while drawing (IDX:3469).
 * A write that lands after this session's feed went off therefore changes
 * nothing anyone draws from (the readers pass through); and the writers are
 * $.clock callbacks, which recheck `active()` after every await.
 *
 * - LIVE: what an open turn's rows, the Spinner or the band draw from changed:
 *   the snapshot, the phase or the band's `working` (Seen, below). Read only by
 *   drawings that depend on the open turn. A reply row reads it only while its
 *   steps-line claim is pending (verdict.ReplyDecision, ruling §20.23 (a)), so
 *   turn.complete's bump re-evaluates that one instance; a settled reply never
 *   reads it (AssistantMessage is not evaluated while it streams, spike5 M18).
 * - TICK: one second passed (elapsed times, the helper band, theme).
 * - PULSE: an animation frame (70 ms), only while something drawn animates.
 */
export const LIVE = atom({ plugin: 'cs-feed', key: 'live' } as const, 0)
export const TICK = atom({ plugin: 'cs-feed', key: 'tick' } as const, 0)
export const PULSE = atom({ plugin: 'cs-feed', key: 'pulse' } as const, 0)

/** Keeps the state source beside its literal declaration for the engine's scan. */
export function readLive($: $): Promise<number> {
  return read($, LIVE)
}

/**
 * Where the main loop stands, from main-loop turn.start / turn.complete (observed,
 * never awaited across: they set a field and call next). The observers run
 * whatever this session's toggle says, so a flip finds the phase current.
 * `unknown` only after a module load mid-turn (a change of these files, such as
 * a cs update): no turn.start reaches a new load for a turn already running
 * (spike Q5); the first band draw settles it from AbovePrompt.isWorking.
 */
export type Phase = 'unknown' | 'idle' | 'live'

/**
 * What a live event told this load about one stored row or call, keyed by its
 * immutable id. These are observations, not a transcript copy: nothing is
 * derived from them by merging with the snapshot, and losing them (a module
 * reload) degrades to the documented fallback named on each.
 */
export type Observations = {
  /**
   * typed prompt uuid -> when it was stored (origin `composer`, door `prompt` or,
   * typed mid-turn, `delivery`). A stored row's UserMessage.requestId is this
   * uuid (spike5 M17, 17 of 17). Two instances match no row and draw no HH:MM:
   * the pre-store `placeholder` instance, and a queued prompt's instances (their
   * ids are in no row; the stored row's instance then uses the uuid).
   * Lost: the row shows no HH:MM (§3.1 parity).
   */
  readonly promptAt: Map<string, number>
  /** user-row uuid -> teammate frames parsed from the raw envelope (§8.3 source 1). Lost: parse the row's text. */
  readonly frames: Map<string, readonly import('./words').Frame[]>
  /** peer-row uuid -> its burst's head uuid; `open` is the burst a new peer row joins (§8.2). Lost: one line per message. */
  readonly bursts: { readonly of: Map<string, string>; readonly members: Map<string, readonly { uuid: string; sender: string; at?: number }[]>; open?: string }
  /** The helper batch keeps vanished agents' kinds until no member is busy. */
  readonly batch: { readonly kinds: Map<string, string>; startedAt?: number }
  /**
   * reply uuid -> the newest call id stored before it in the same turn, the
   * reply's whole text as stored, and an order stamp (§4.4). The key is the
   * `response` append's e.uuid, which IS AssistantMessage.requestId (spike5 M17,
   * 18 of 18; the full uuid, not its first groups, not the API's msg_ id).
   *
   * Recorded synchronously at the top of the response hook, BEFORE await
   * next(e) (uuid and tool_use blocks are pinned; spike5 M18: the reply's two
   * evaluations come +6-9 ms and +13-26 ms after its append, with no
   * invalidate, and never while it streams), so the first evaluation finds it.
   * The text is replaced by the stored text from next(e)'s result, synchronously,
   * in case a hook beneath rewrote a text block (rewritable); an evaluation
   * between the two sees a mismatch and reads as a fragment for that draw.
   * While the turn is live that leaves the claim pending (§20.23), so
   * the stored text is in place by the turn.complete re-evaluation. Only when
   * the evaluation in that window also finds the turn spent (no Stop hook)
   * does site() record stepsDrawn false, and the write-once record keeps it
   * false for that reply: the line stays on the first call's row (rare,
   * cosmetic; rationale gap 6).
   *
   * Whether the reply may carry the steps line is `words.repliesOwnSteps(text)`,
   * a function of the text alone, so the tool row and the reply row agree in
   * either plugin order (finding 6). The reply row draws it only when the text
   * it is handed equals `text` (a fragment never draws it). Lost: the line
   * stays on the first call's row.
   */
  readonly anchors: Map<string, { readonly call: CallId; readonly text: string; readonly seq: number }>
  /** call id -> uuid of the newest anchored reply whose `call` is it: "the last such block wins" (§4.4a). An index over `anchors`, rewritten per reply. */
  readonly latestByCall: Map<CallId, string>
  /** The stamp the next anchor takes. */
  anchorSeq: number
  /**
   * reply uuid -> whether that reply's row drew its turn's steps line, as the
   * evaluation that SETTLED its claim decided (verdict.stepsOwner,
   * StepsClaim): the first evaluation that is not 'pending'. Written once per
   * uuid, by site() after the AssistantMessage painter (module memory, never
   * $.state, so a render may write it); a pending evaluation writes nothing.
   * The tool row yields only to `true`. A settling evaluation that read as a
   * fragment (see `anchors`) records false for good; while the turn is live a
   * fragment only leaves the claim pending. Lost: the line stays on the first
   * call's row.
   */
  readonly stepsDrawn: Map<string, boolean>
  /** The newest tool_use id stored since the last prompt row: the anchor a reply gets. */
  callSincePrompt?: CallId
  /**
   * Live provenance for segmentation (finding 1): the first tool_use id of the
   * first model row of a turn opened by an idle peer row. buildTranscript opens
   * a turn at that call. Keyed by a call id because plain messages() holds call
   * ids and nothing else stable. Origin `peer` covers teammate envelopes too,
   * which the history rule (transcript.opensPeerTurn) does not match.
   * A peer turn whose reply has no tool_use gives the response hook no id, so
   * it takes no opener: only the history rule (joinApi) can open it
   * (open-measurements M30). Lost: history rule only.
   */
  readonly turnOpeners: Set<CallId>
  /**
   * The last main-loop prompt-door row stored was an idle peer message (origin
   * `peer`, isMeta). Set by the prompt hook SYNCHRONOUSLY after its await
   * next(e) resolves, with no further await, from `door === 'prompt'`:
   * `peerPending = origin.kind === 'peer' && isMeta` (so a typed prompt or an
   * idle task notification sets it false). Consumed by turn.start, which
   * copies it into `mainTurn.peer` and clears it.
   *
   * Measured order at the receiver (spike5 M19, 5 of 5): session.receive ->
   * prompt.submit -> session.append door prompt (peer, isMeta) -> that hook's
   * next(e) resolves -> turn.start 0-1 ms later. Both hooks run in this load's
   * environment and the append continuation's seq was below turn.start's every
   * time, so turn.start reads the flag the prompt hook just set.
   */
  peerPending: boolean
  /**
   * The main-loop turn running now, from turn.start to turn.complete: whether
   * an idle peer row opened it, and whether its opener call was taken. The
   * response hook adds the first tool_use id of a peer turn to turnOpeners.
   */
  mainTurn?: { readonly peer: boolean; openerTaken: boolean }
  /**
   * Agent call id -> when agent.spawn said it started: a RUNNING helper's elapsed
   * time, the one helper fact no source carries. Everything else about a helper
   * is derived (verdict.helperState). Lost: "dispatched · running" with no time (§7.1 pin).
   */
  readonly helperStartedAt: Map<CallId, number>
  /** background call id -> first time this load saw it (§9.1 elapsed; the transcript has no timestamps). */
  readonly bgSeenAt: Map<CallId, number>
  /**
   * background call ids a task notification named as ended (its <tool-use-id>),
   * seen at session.append on door `delivery` (mid-turn) or `prompt` (idle),
   * origin `task-notification` (spike2 M1c). After reload the API snapshot also supplies recorded closes (option B).
   */
  readonly bgEnded: Set<CallId>
  phase: Phase
  /** Last AbovePrompt.isWorking (noteWorking). */
  working?: boolean
}

/** The chevrons a person opened: run ids, call ids, `turn-<first call>`, `batch-<first helper>`, `burst-<uuid>`. */
export type Opened = Set<string>

/**
 * What the open turn's drawings were last drawn from (finding 2). A refresh
 * bumps LIVE when any member differs from the last bump's, so a change of phase
 * or of `working` with an identical snapshot still redraws the rows that read
 * LIVE. Trace: the final reply is stored, the refresh lands and bumps (phase
 * live); turn.complete then sets phase idle and calls dirty(); the next refresh
 * finds the same `transcript` but `phase` changed, bumps LIVE, and the turn's
 * rows redraw spent and stop reading LIVE.
 */
export type Seen = { readonly transcript: string; readonly phase: Phase; readonly working: boolean | undefined }

/**
 * The snapshot and its one refresh (validate2 gap 2):
 *
 *   clean       `cached` is current; a render reads it with no $ call
 *   scheduled   dirty() set a $.clock.after(0); a render that asks first starts the refresh itself
 *   refreshing  `inFlight` is the one read in progress; every caller awaits it
 *
 * `again`: a dirty() that lands while `refreshing` sets it (it schedules
 * nothing itself). When the in-flight refresh settles it clears `again` and
 * starts exactly one more refresh, whose messages() read begins after every
 * dirty() of the window, so the rows those dirty() calls announced are in it.
 * N dirty() calls in one window cost one more read, not N.
 */
export type Snap = {
  cached: Transcript
  state: 'clean' | 'scheduled' | 'refreshing'
  inFlight?: Promise<Transcript>
  again: boolean
  /** The Seen of the last LIVE bump. */
  bumped?: Seen
}

export type Load = {
  /**
   * Mirror of FEED_FILE and VIEW_FILE; undefined until the per-load read
   * settles (feedRecord). `on` is true only when the file says on AND cs
   * trusts this session's control files (`vet`, below): a session cs refuses
   * reads as off. Written by feedRecord() (the load's read) and applyFeed()
   * (every later read), the view half also by writeFeed(); never by a render
   * except through feedRecord's one per-load promise.
   */
  feed?: Session
  record?: Promise<Session>
  /** Writing commands wait before deriving their next view; readers keep their independent tickets. */
  writes?: Promise<void>
  /**
   * cs's answer on this session's control files for the `on\n` the mirror
   * last read (§20.22: the writes and the on-read are vetted).
   * Undefined: not asked for the file's current on,
   * or the file reads off. Set from vetOnRead's answer (by feedRecord at the
   * load's on-read, by applyFeed('status') at an outside flip to on), by
   * applyFeed to 'passed' when a press's write turned the file on (cs's
   * pressFeed vetted it on the way in), and at a successful write's ticketed
   * read-back. A read that finds the file off clears it, so the next on
   * that no writer of ours vetted is vetted again. A refused writeFeed leaves
   * it as it was (the mirror and the drawing stay as they were). Cached for
   * the load otherwise: a session cs stops trusting after a pass keeps the
   * pass until the file reads off or the next load (the band labels its key
   * off at cs's next vet).
   */
  vet?: Vetted
  /** The last read-side refusal logged ($.ui.log), so each distinct refusal is logged once per load, as cs's band de-duplicates its feed complaint (readFeed's feedComplaint). Cleared by a pass. */
  vetLogged?: string
  /**
   * Read tickets for FEED_FILE (applyFeed): `started` is taken when a read
   * begins, `applied` is the ticket of the read the mirror holds. A read
   * whose ticket is below `applied` is dropped when it resolves, so the
   * latest-started read wins even when two reads resolve out of order (a
   * typed /feed's read-back beside a band press's read). Two quick band
   * presses do not need it: cs's pressFeed is single-flight and hands the
   * second press the first one's in-flight promise, so it writes once and both
   * hooks' reads start after that write.
   */
  reads: { started: number; applied: number }
  snap: Snap
  readonly obs: Observations
  readonly opened: Opened
  /** The polled agent list and theme, refreshed by the 1 s tick. */
  agents: readonly import('claude-code').AgentInfo[]
  light: boolean
  themeAt?: number
  desktopBand?: boolean
  /** Whether the tick and pulse are scheduled; cleared by a callback that stops. startClocks is idempotent on it, so an off-on-off within one load never doubles them. */
  clocks: { tick: boolean; pulse: boolean }
}

export function newLoad(): Load {
  return {
    reads: { started: 0, applied: 0 }, snap: { cached: EMPTY, state: 'scheduled', again: false },
    obs: { promptAt: new Map(), frames: new Map(), bursts: { of: new Map(), members: new Map() }, batch: { kinds: new Map() }, anchors: new Map(), latestByCall: new Map(), anchorSeq: 0, stepsDrawn: new Map(), turnOpeners: new Set(), peerPending: false, helperStartedAt: new Map(), bgSeenAt: new Map(), bgEnded: new Set(), phase: 'unknown' },
    opened: new Set(), agents: [], light: false, clocks: { tick: false, pulse: false },
  }
}

/** Called after the prompt-door append settles, before turn.start. */
export function observePrompt(load: Load, row: { door: 'prompt' | 'delivery'; peer: boolean; isMeta: boolean }): void {
  if (row.door === 'prompt') {
    load.obs.peerPending = row.peer && row.isMeta
    load.obs.callSincePrompt = undefined
  }
}

export function observeTurnStart(load: Load): void {
  load.obs.mainTurn = { peer: load.obs.peerPending, openerTaken: false }
  load.obs.peerPending = false
  load.obs.phase = 'live'
}

export function observeTurnComplete(load: Load): void {
  load.obs.phase = 'idle'
  load.obs.mainTurn = undefined
}

/** Returns whether the shell must schedule the claim's LIVE bump. */
export function recordStepsClaim(load: Load, reply: string, claim: import('./verdict').StepsClaim): boolean {
  if (claim === 'pending' || load.obs.stepsDrawn.has(reply)) return false
  const drew = claim === 'drawn'
  load.obs.stepsDrawn.set(reply, drew)
  return drew
}

/** Called before next(response); the returned stored text may then replace the anchor text. */
export function observeResponse(load: Load, row: { uuid: string; text: string; calls: readonly string[] }): void {
  const first = row.calls[0]
  if (first && load.obs.mainTurn?.peer && !load.obs.mainTurn.openerTaken) {
    load.obs.turnOpeners.add(callId(first))
    load.obs.mainTurn.openerTaken = true
  }
  if (row.text && load.obs.callSincePrompt) {
    const call = load.obs.callSincePrompt
    load.obs.anchors.set(row.uuid, { call, text: row.text, seq: ++load.obs.anchorSeq })
    load.obs.latestByCall.set(call, row.uuid)
  }
  const last = row.calls.at(-1)
  if (last) load.obs.callSincePrompt = callId(last)
}

export function replaceResponseText(load: Load, uuid: string, text: string): void {
  const anchor = load.obs.anchors.get(uuid)
  if (anchor) load.obs.anchors.set(uuid, { ...anchor, text })
}

/**
 * The feed draws and its clocks run: this session's record says on.
 * Rechecked (finding 4) in every clock callback and in the LIVE bump after
 * every await in them, and immediately before every $.state write and every
 * $.clock.after/every call: a typed /feed off (immediate, mid-turn included)
 * or a band press can land during any of those awaits. Synchronous, so nothing
 * can interleave between the check and the call it guards. Observers do not
 * check it: they record whatever the toggle says. toggle() does not check it
 * either, on purpose: a chevron press after off costs one invalidate, harmless.
 */
export function active(load: Load): boolean {
  return load.feed?.on === true
}

/**
 * This session's record, read once per load and mirrored in `load.feed`: one
 * per-load promise, started by whichever caller asks first (a render, a
 * command, a press) and awaited by every render, so a render that lands
 * before anything else sees the file, not a default.
 *
 *   const cwd = await $.session.cwd()
 *   fileOn = isOn(await $.fs.read(`${cwd}/${FEED_FILE}`) or undefined on ENOENT)   // a ticketed read (applyFeed)
 *   load.vet = fileOn ? await vetOnRead(load, $, cwd) : undefined                 // off or absent: no cs process
 *   on     = fileOn && load.vet === 'passed'
 *   view   = parseStoredView(await $.fs.read(`${cwd}/${VIEW_FILE}`) or undefined)
 *
 * Any read error other than ENOENT is logged ($.ui.log, with the error) and
 * reads as off, as the band's readFeed does (it catches, logs a new complaint
 * once and returns false), so both sides then show off, never on.
 *
 * Vetted once per load when the file says on (§20.22: the on-read asks
 * the same cs -vet-session as writeFeed). A
 * refused session reads as off: the mirror says off, every hook passes the
 * engine's drawing through, nothing is written, and the refusal is logged once
 * (vetOnRead). cs's band labels the key off there too (`lastRefusal ===
 * undefined && readFeed`), so both sides agree and both refuse writes
 * (rationale (e) trace 7). A session whose file says off or is absent spawns
 * no cs process.
 *
 * Where it waits: site() awaits this promise at `load.feed ?? await
 * feedRecord(load, $)`, before context() and so before the refresh's two
 * messages() reads. In an on-session the first painted draw after a load
 * therefore waits for the vet (one cs process, 0.15-0.44 s, cs's
 * measurement; up to VET_TIMEOUT_MS, then refused, if cs hangs), and so does
 * every hooked evaluation that arrives before the promise settles, the
 * pass-through ones included, since off or on is not known until cs answers
 * (a row passing through on its own isExpanded excepted: site() returns it
 * before the await):
 * their next(e), cs's band beneath AbovePrompt among them, runs after it. The
 * hook's budget does not count the wait (HookBudget: the clock stops while a
 * $ call is in flight). noteWorking runs before the await, so the phase still
 * settles. After it settles, the off path costs no op again.
 *
 * A mirror, not a per-draw read: the off path costs the hop and next(e), no op.
 * The file can change behind the mirror only through a writer other than cs's
 * band press and /feed (a hand edit, a second Claude session in this
 * directory); that is seen at the next press, /feed (/feed status re-reads
 * it first, through applyFeed, and vets a flip to on), or load (Tradeoffs).
 */
export function feedRecord(load: Load, $: $): Promise<Session> {
  return load.record ??= (async () => {
    const cwd = await $.session.cwd()
    const feed = await readLocal($, `${cwd}/${FEED_FILE}`)
    const stored = await readLocal($, `${cwd}/${VIEW_FILE}`)
    const view = parseStoredView(stored.text)
    load.vet = isOn(feed.text) ? await vetOnRead(load, $, cwd) : undefined
    load.feed = { on: !feed.failed && !stored.failed && isOn(feed.text) && load.vet === 'passed', view }
    return load.feed
  })()
}

async function readLocal($: $, path: string): Promise<{ text?: string; failed: boolean }> {
  try {
    return { text: await $.fs.read(path), failed: false }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (/\bENOENT\b/.test(message)) return { failed: false }
    await $.ui.log(`cs-feed: could not read ${path}: ${message}`)
    return { failed: true }
  }
}

/**
 * Which read applyFeed makes, and so whether cs already vetted the file it
 * reads. `press`: after cs's pressFeed, which vets before it writes. `write`:
 * writeFeed's read-back, after its own vet passed. `status`: /feed status's
 * re-read, after no writer of ours: a flip to on found there arrived from
 * outside both writers (a hand edit, a second Claude process in this
 * directory, a pull), so it is vetted before it turns the feed on.
 */
export type FeedRead = 'press' | 'write' | 'status'

/**
 * Reads FEED_FILE and applies it to the mirror (ticketed, see Load.reads).
 * Called after `await next(e)` in the ui.press hook on cs's `cs-feed` Button
 * ('press'), after cs-feed's own write (writeFeed, 'write'), and by perform()
 * before transition for /feed status ('status'), so status reports the file
 * as vetted (off where cs refuses), not a mirror a hand edit or a second
 * Claude process in this directory left stale. It reads FEED_FILE only: the
 * view stays the mirror's.
 *
 *   await feedRecord(load, $)                                       // the load's read first, the same per-load promise: a press
 *                                                                   // during the load's vet neither finds load.feed unset nor outranks its ticket
 *   const ticket = ++load.reads.started
 *   const fileOn = isOn(the read)
 *   let vet = load.vet
 *   if (!fileOn) vet = undefined                                   // the next on is vetted again unless a writer of ours vetted it
 *   else if (after === 'write') vet = 'passed'                      // commit this writer's fresh answer with its read ticket
 *   else if (vet === undefined && after !== 'status') vet = 'passed'   // the writer vetted it on the way in: no cs process
 *   else if (vet === undefined) vet = await vetOnRead(load, $, cwd)    // an outside flip to on: one cs process
 *   if (ticket < load.reads.applied) return                        // a read started earlier that resolves later changes nothing, load.vet included
 *   load.reads.applied = ticket; load.vet = vet
 *   const on = fileOn && vet === 'passed'                          // a cached refusal keeps a refused press's unchanged on, off
 *
 * and when `on` changed:
 *
 *   load.feed = { on, view: load.feed.view }
 *   if (on) dirty(load, $)                 // a flip on rebuilds once, whole
 *   $.ui.invalidate('ui.render')           // every hooked instance reads the mirror again
 *
 * The press path trusts the file it reads after next(e): cs's refusal is cs's
 * module memory, so an outside on that lands after cs-feed's last read and
 * before a press cs refuses (the file read off before, on after) reads as the
 * press's write and turns on.
 * Accepted (ruling §20.22: a press's read is not vetted again); the band
 * labels the key off there, and the next load's vet reads it off.
 *
 * The invalidate is cs-feed's own and comes after the mirror changed. cs's
 * pressFeed already invalidated before cs-feed's next(e) resolved (cs's
 * instances, as the contract states it; the scope is unmeasured,
 * open-measurements M28: if it is global, that wave drew every feed instance
 * with the old mirror, a cost only), so the shared AbovePrompt instance may
 * have been drawn once with cs-feed's old mirror; this later invalidate supersedes any evaluation still
 * in flight (spike3 M15: drawn again at once with the new value, never blank).
 * It is also what redraws cs's band after a typed /feed: cs-feed hooks
 * AbovePrompt, so its invalidate re-evaluates that instance, whose chain runs
 * cs's band hook, which re-reads the file (inferred from the shared hop
 * labels, spike3 M14 debug and spike4 3b; not measured for this pair).
 * Never called from a render, never from a session.append hook.
 */
export async function applyFeed(load: Load, $: $, after: FeedRead): Promise<void> {
  await feedRecord(load, $)
  const ticket = ++load.reads.started
  const cwd = await $.session.cwd()
  const file = await readLocal($, `${cwd}/${FEED_FILE}`)
  if (ticket < load.reads.applied) return
  const fileOn = isOn(file.text)
  let vet = load.vet
  if (!fileOn) vet = undefined
  else if (after === 'write') vet = 'passed'
  else if (vet === undefined) vet = after === 'status' ? await vetOnRead(load, $, cwd) : 'passed'
  if (ticket < load.reads.applied) return
  load.reads.applied = ticket
  load.vet = vet
  if (vet === 'passed') load.vetLogged = undefined
  const current = load.feed
  if (!current) throw new Error('feed record did not settle')
  const on = fileOn && vet === 'passed'
  if (current.on === on) return
  load.feed = { on, view: current.view }
  if (on) dirty(load, $)
  await $.ui.invalidate('ui.render')
}

/** What a /feed write did: written, nothing (no .cs/local), or nothing because cs refused this session's control files (the reason, for the reply). */
export type WriteOutcome = 'written' | 'no-session' | { readonly refused: string }

/**
 * Writes this session's record, from an event hook only (perform: /feed typed,
 * a settings-pane press), and only where cs trusts this session's control
 * files, as cs's band press does (§20.22):
 *
 *   const cwd = await $.session.cwd()
 *   if (!(await $.fs.exists(`${cwd}/${CS_LOCAL}`))) return 'no-session'   // never create .cs/local; no vet spawned
 *   const refusal = await vetRefusal($, cwd)
 *   if (refusal !== undefined) return { refused: refusal }                   // nothing written, the mirror and load.vet untouched
 *   if (view changed) await $.fs.write(`${cwd}/${VIEW_FILE}`, viewText(next.view))   // view first: a reader never sees on with the old view
 *   load.feed = { on: load.feed.on, view: next.view }
 *   await $.fs.write(`${cwd}/${FEED_FILE}`, next.on ? ON_LINE : OFF_LINE)
 *   await applyFeed(load, $, 'write')                                       // read back and commit this write's pass with its ticket; no second vet
 *   return 'written'
 *
 * The vet comes after the directory test, so a directory with no .cs/local
 * spawns no cs process, and before the first write, so a refused session gets
 * neither file. Its cost is one cs process per writing /feed (0.15-0.44 s,
 * measured by cs), awaited inside the immediate command, mid-turn included.
 * Non-atomic writes, as the band's: a write torn by a crash leaves a file that
 * reads as off on both sides.
 */
export async function writeFeed(load: Load, $: $, next: Session): Promise<WriteOutcome> {
  const cwd = await $.session.cwd()
  if (!(await $.fs.exists(`${cwd}/${CS_LOCAL}`))) return 'no-session'
  const refused = await vetRefusal($, cwd)
  if (refused !== undefined) return { refused }
  const current = load.feed ?? await feedRecord(load, $)
  const viewChanged = viewText(current.view) !== viewText(next.view)
  if (viewChanged) await $.fs.write(`${cwd}/${VIEW_FILE}`, viewText(next.view))
  load.feed = { on: current.on, view: next.view }
  await $.fs.write(`${cwd}/${FEED_FILE}`, next.on ? ON_LINE : OFF_LINE)
  await applyFeed(load, $, 'write')
  if (viewChanged && load.feed.on === current.on) await $.ui.invalidate('ui.render')
  return 'written'
}

/**
 * cs's answer on this session's control files, by cs's own rule, asked the
 * way cs's band asks it (mods/cs/hooks/register.tsx sessionVetted, on main):
 *
 *   const bin = await $.env.get("CS_BIN")                        // a literal: validate lists the env names a module reads
 *   no bin                -> 'the launch did not say where cs is (CS_BIN)'
 *   await $.process.run([bin, '-vet-session', cwd], { timeoutMs: VET_TIMEOUT_MS })
 *     exit 0              -> undefined (trusted)
 *     exit != 0           -> the last non-empty stderr line, else `cs -vet-session exited ${code}`
 *   throws (a timeout too) -> `cs -vet-session did not run: ${message}`
 *
 * Returns the refusal or undefined. It reports nothing itself: each caller
 * says the refusal its own way. writeFeed's caller (perform) puts it in the
 * command's reply, once, to the person who typed it; vetOnRead logs it once
 * per distinct text. No toast and no `lastRefusal`: cs's own lastRefusal is
 * cs's module memory; this shares nothing with it, and cs's band asks again
 * at its next acting step, so the two answer the same rule, not the same call.
 */
export async function vetRefusal($: $, cwd: string): Promise<string | undefined> {
  const bin = await $.env.get('CS_BIN')
  if (!bin) return 'the launch did not say where cs is (CS_BIN)'
  try {
    const result = await $.process.run([bin, '-vet-session', cwd], { timeoutMs: VET_TIMEOUT_MS })
    if (result.exitCode === 0) return undefined
    return result.stderr.split(/\r?\n/).filter(line => line.trim() !== '').at(-1) ?? `cs -vet-session exited ${result.exitCode}`
  } catch (error) {
    return `cs -vet-session did not run: ${error instanceof Error ? error.message : String(error)}`
  }
}

/** cs's answer on this session's control files: trusted, or refused with cs's own text (vetRefusal's). */
export type Vetted = 'passed' | { readonly refused: string }

/**
 * The read-side vet (§20.22: a file that
 * says on is vetted before the feed turns on). Asked only when FEED_FILE reads
 * exactly `on\n` and no answer is cached for that on (Load.vet): by
 * feedRecord at the load's read, and by applyFeed('status') for a flip to on
 * no writer of ours vetted. The same vetRefusal as writeFeed's, so the same
 * argv, VET_TIMEOUT_MS and refusal texts as cs's sessionVetted.
 *
 *   const refusal = await vetRefusal($, cwd)
 *   if (refusal === undefined) { load.vetLogged = undefined; return 'passed' }
 *   if (refusal !== load.vetLogged) $.ui.log(`cs-feed: the feed is off in this session: ${refusal}`)
 *   load.vetLogged = refusal
 *   return { refused: refusal }
 *
 * The log de-duplicates per distinct text, as cs's readFeed does with its
 * feed complaint: a cleared answer vetted again with the same refusal logs
 * nothing new. The caller stores the answer in Load.vet (applyFeed only when
 * its read still wins its ticket). Cost: one cs process (0.15-0.44 s), in
 * on-sessions only.
 */
export async function vetOnRead(load: Load, $: $, cwd: string): Promise<Vetted> {
  const refused = await vetRefusal($, cwd)
  if (refused === undefined) {
    load.vetLogged = undefined
    return 'passed'
  }
  if (refused !== load.vetLogged) {
    load.vetLogged = refused
    await $.ui.log(`cs-feed: the feed is off in this session: ${refused}`)
  }
  return { refused }
}

/**
 * The current snapshot (Snap). Clean: the cached one, no $ call. Scheduled:
 * start the refresh now (the pending after(0) then finds `refreshing` and does
 * nothing). Refreshing: the in-flight promise, shared by every render that
 * asks. A refresh is
 *
 *   snap.state = 'refreshing'
 *   const plain = await $.session.messages()
 *   const api = await $.session.messages({ as: 'api' })   // Q-idle-delivery option B
 *   snapshot = buildTranscript(plain, api, load.obs.turnOpeners)   // whole, never merged
 *   snap.cached = snapshot
 *   const seen = { transcript: signature(snapshot), phase, working }
 *   if (seen differs from snap.bumped in any member) $.clock.after(0, bump)
 *   bump: if (!active(load)) return; snap.bumped = seen; $.state.set(LIVE, n + 1)
 *   if (snap.again && active(load)) { snap.again = false; start one more refresh }   // gap 2
 *   else { snap.state = snap.again ? 'scheduled' : 'clean'; snap.again = false }      // off: marked, no timer; the next painted draw refreshes
 *
 * and is the only $.session.messages() call the mod makes for the main loop.
 * A render that finds `scheduled` runs the refresh inside itself, and one that
 * finds `refreshing` awaits it: either way it awaits two messages() reads
 * under option B (one otherwise), whose latency at 4096 entries is
 * open-measurements #6. The first painted draw after a flip on is such a
 * render.
 */
export function transcript(load: Load, $: $): Promise<Transcript> {
  const snap = load.snap
  if (snap.state === 'clean') return Promise.resolve(snap.cached)
  if (snap.inFlight) return snap.inFlight
  snap.state = 'refreshing'
  snap.inFlight = (async () => {
    try {
      const plain = await $.session.messages()
      const api = await $.session.messages({ as: 'api' })
      const snapshot = buildTranscript(plain, api, load.obs.turnOpeners)
      snap.cached = snapshot
      const seen: Seen = { transcript: JSON.stringify([[...snapshot.calls.values()], snapshot.turns, [...snapshot.runs.values()], snapshot.background]), phase: load.obs.phase, working: load.obs.working }
      if (active(load) && JSON.stringify(seen) !== JSON.stringify(snap.bumped)) {
        $.clock.after(0, async () => {
          if (!active(load)) return
          const value = await read($, LIVE)
          if (!active(load)) return
          snap.bumped = seen
          await $.state.set({ plugin: 'cs-feed', key: 'live' }, value + 1)
        })
      }
      const again = snap.again
      snap.again = false
      snap.inFlight = undefined
      snap.state = again ? 'scheduled' : 'clean'
      if (again && active(load)) return transcript(load, $)
      return snapshot
    } catch (error) {
      snap.inFlight = undefined
      snap.state = 'scheduled'
      throw error
    }
  })()
  return snap.inFlight
}

/**
 * The transcript grew (session.append on the main loop, after next(e)), a turn
 * began or ended, AbovePrompt.isWorking flipped, or this session turned on.
 *
 *   refreshing -> snap.again = true                      (one more refresh after this one; nothing scheduled here)
 *   scheduled  -> nothing                                 (the scheduled refresh has not read yet)
 *   clean      -> state = 'scheduled'; if (active(load)) $.clock.after(0, run the refresh)
 *
 * Off, the snapshot is only marked: nothing reads messages(). dirty()
 * itself never reads messages() and never awaits: it marks or schedules. The
 * refresh runs in the after(0) callback or, when a render asks first, inside
 * that render (transcript()). So the first painted draw after a flip on
 * awaits the refresh's reads inside the render: two messages() calls under
 * Q-idle-delivery option B (plain, then as: 'api'), one otherwise
 * (open-measurements #6 is on this path). dirty() never invalidates
 * (an invalidate from an append hook re-evaluates every instance the
 * plugin's matchers select, 7-9 AssistantMessage and 7-9 UserMessage per
 * reply in spike5 M18).
 */
export function dirty(load: Load, $: $): void {
  if (load.snap.state === 'refreshing') {
    load.snap.again = true
    return
  }
  if (load.snap.state === 'scheduled') return
  load.snap.state = 'scheduled'
  if (active(load)) $.clock.after(0, async () => {
    if (active(load) && load.snap.state === 'scheduled') await transcript(load, $)
  })
}

/**
 * The open turn: the transcript's last turn while the main loop is live. With
 * phase `unknown`, the engine's AbovePrompt.isWorking decides, and before the
 * band has drawn, whether the last turn holds a call with no result.
 *
 * Returns the Turn itself, not its id: an open turn with no call yet has no id
 * (TurnId is its first call's), and the Spinner still needs it ("Thinking").
 */
export function openTurn(load: Load, t: Transcript): Turn | undefined {
  const last = t.turns.at(-1)
  if (load.obs.phase === 'idle') return undefined
  if (load.obs.phase === 'live') return last
  const working = load.obs.working ?? [...t.calls.values()].some(call => call.turn === last?.id && call.outcome.state === 'running')
  return working ? last : undefined
}

/**
 * The engine's word on whether the main loop works, from an AbovePrompt draw
 * (context() calls this, and site() calls it on the pass-through path too, so
 * the phase stays settled while this session's feed is off). Sets `working`;
 * settles phase `unknown` to `live` or `idle`. A flip calls dirty(). Starts the
 * clocks only on a painted draw.
 */
export function noteWorking(load: Load, $: $, isWorking: boolean): void {
  const changed = load.obs.working !== isWorking || load.obs.phase === 'unknown'
  load.obs.working = isWorking
  if (load.obs.phase === 'unknown') load.obs.phase = isWorking ? 'live' : 'idle'
  if (changed) dirty(load, $)
}

/**
 * The clocks, started at a painted draw and gated on need: the 1 s tick
 * (agent list, theme every 30 s, a TICK write) while active; the 70 ms pulse
 * only while a helper runs or a background run is listed (ruling §20.14).
 * Idempotent on load.clocks. Each callback (finding 4):
 *
 *   tick = async () => {
 *     if (!active(load)) return stop('tick')
 *     const agents = await $.agent.list();        if (!active(load)) return stop('tick')
 *     const light = await themeIsLight($, load);  if (!active(load)) return stop('tick')
 *     load.agents = agents; load.light = light
 *     await $.state.set(TICK, n + 1)               // an in-flight write that settles after off redraws only readers, which now pass through
 *     if (!active(load)) return stop('tick')
 *     $.clock.after(1000, tick)
 *   }
 *   stop(k): load.clocks[k] = false                // the next painted draw starts it again
 *
 * What races here is a per-session off landing during an await (a typed
 * /feed off runs mid-turn; a band press while idle). A module reload cancels
 * pending waits (IDX:3512) and the engine never calls a superseded module for a
 * render (spike2 M2); a callback already past its wait writes a token no
 * reader of the new load reads, so no reload-specific check is kept.
 *
 * Validation (kit, `claude plugin test`): mock.clock; the test's own hook on the
 * `agent.list` op answers from a promise the test holds (ops are events,
 * IDX:7008-7016; the kit has no agent mock). Advance to the first tick, run
 * `/feed off` while agent.list is held, release it, advance 5 s: zero
 * `state.set` of TICK or PULSE after the flip and no held wait left.
 */
export function startClocks(load: Load, $: $, desktopBand = false): void {
  if (!active(load)) return
  if (desktopBand) load.desktopBand = true
  if (!load.clocks.tick) {
    load.clocks.tick = true
    $.clock.after(1000, async function tick() {
      if (!active(load)) { load.clocks.tick = false; return }
      try {
        const agents = await $.agent.list()
        if (!active(load)) { load.clocks.tick = false; return }
        load.agents = agents
        if (load.themeAt === undefined || Date.now() - load.themeAt >= 30000) {
          const rows = await $.config.list()
          if (!active(load)) { load.clocks.tick = false; return }
          const theme = rows.find(row => row.key === 'theme')?.value
          load.light = typeof theme === 'string' && theme.startsWith('light')
          if (load.desktopBand) {
            const appearance = await $.process.run(['defaults', 'read', '-g', 'AppleInterfaceStyle'], { timeoutMs: 1000 })
            if (!active(load)) { load.clocks.tick = false; return }
            load.light = appearance.exitCode !== 0 || appearance.stdout.trim() !== 'Dark'
          }
          load.themeAt = Date.now()
        }
        const value = await read($, TICK)
        if (!active(load)) { load.clocks.tick = false; return }
        await $.state.set({ plugin: 'cs-feed', key: 'tick' }, value + 1)
        if (!active(load)) { load.clocks.tick = false; return }
        startPulse(load, $)
        if (active(load)) $.clock.after(1000, tick)
      } catch (error) {
        load.clocks.tick = false
        await $.ui.log(`cs-feed: clock stopped: ${error instanceof Error ? error.message : String(error)}`)
      }
    })
  }
  startPulse(load, $)
}

function animating(load: Load): boolean {
  return load.agents.some(agent => agent.status === 'running') || load.snap.cached.background.some(run => !load.obs.bgEnded.has(run.id))
}

function startPulse(load: Load, $: $): void {
  if (!active(load) || !animating(load) || load.clocks.pulse) return
  load.clocks.pulse = true
  $.clock.after(70, async function pulse() {
    if (!active(load) || !animating(load)) { load.clocks.pulse = false; return }
    const value = await read($, PULSE)
    if (!active(load) || !animating(load)) { load.clocks.pulse = false; return }
    await $.state.set({ plugin: 'cs-feed', key: 'pulse' }, value + 1)
    if (!active(load) || !animating(load)) { load.clocks.pulse = false; return }
    $.clock.after(70, pulse)
  })
}

/**
 * Records a reply's settled steps-line claim once (Observations.stepsDrawn):
 * `drew` is claim === 'drawn'; site() does not call it for a 'pending' claim.
 * A new `true` schedules one LIVE bump through $.clock.after(0) (a clock
 * callback, as every token write; it rechecks active()), so the first call's
 * row, live while the claim was pending, redraws and yields. Called by
 * site(), the one place a render feeds the load besides noteWorking.
 */
export function noteStepsDrawn(load: Load, $: $, reply: string, drew: boolean): void {
  if (!recordStepsClaim(load, reply, drew ? 'drawn' : 'declined') || !active(load)) return
  $.clock.after(0, async () => {
    if (!active(load)) return
    const value = await read($, LIVE)
    if (!active(load)) return
    await $.state.set({ plugin: 'cs-feed', key: 'live' }, value + 1)
  })
}

/**
 * A chevron press: flip the key, then one $.ui.invalidate from the press
 * handler (never from a render). Not gated on active(): a press that lands
 * after this session went off (a stale handle: a drawing still on screen, or
 * a press in flight across the flip) flips its key and invalidates once.
 * Every instance then passes through, so it costs one evaluation wave and
 * changes nothing drawn.
 */
export async function toggle(load: Load, $: $, key: string): Promise<void> {
  if (load.opened.has(key)) load.opened.delete(key)
  else load.opened.add(key)
  await $.ui.invalidate('ui.render')
}
