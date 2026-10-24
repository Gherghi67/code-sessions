// ABOUTME: Compile-time checks on the painter table: tsc fails if a refused shape stops being refused (each @ts-expect-error must still error).
// ABOUTME: Not loaded by the engine; run by `tsc -p tsconfig.json` in tests/test_mod_feed.sh.
import type { PainterTable } from '../hooks/register'
import type { decideReply } from '../hooks/verdict'

type SpinnerPainter = PainterTable['Spinner']

// The Spinner may rewrite its props.
export const rewriting: SpinnerPainter = async () => ({ drawn: { kind: 'rewrite', props: { message: 'Working · step 2', suffix: '' } }, live: true })

// @ts-expect-error a Spinner painter that returns a tree of its own is refused: it would drop cs's tip row.
export const replacing: SpinnerPainter = async () => ({ drawn: { kind: 'tree', tree: null as never }, live: false })

// @ts-expect-error a Spinner painter that draws nothing is refused too (the §5.2 conflict, ruling §20.15).
export const hiding: SpinnerPainter = async () => ({ drawn: { kind: 'nothing' }, live: false })

// @ts-expect-error the band goes around what next(e) drew, never in its place.
export const bandInstead: PainterTable['AbovePrompt'] = async () => ({ drawn: { kind: 'tree', tree: null as never }, live: false })

// @ts-expect-error a table missing a hooked site is refused.
export const partial: PainterTable = { Spinner: rewriting }

// A reply decision is live while its steps-line claim is pending, so turn.complete's LIVE bump re-evaluates it (ruling §20.23 (a)).
export const pendingReply: ReturnType<typeof decideReply> = { verdict: { body: 'engine', name: true }, claim: 'pending', live: true }

// @ts-expect-error a reply decision whose claim is settled is never live: the reply is not evaluated while it streams, and twice once stored (spike5 M18), so nothing is left for LIVE to redraw.
export const liveSettledReply: ReturnType<typeof decideReply> = { verdict: { body: 'engine', name: true }, claim: 'drawn', live: true }
