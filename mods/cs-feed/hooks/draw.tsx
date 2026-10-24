// ABOUTME: cs-feed's trees: turns a verdict into elements from $.ui.resolve(e), with the inks (§13) and the 7-column name margin.
// ABOUTME: No decisions and no $ calls but resolve; a Button never sits inside a Text (the engine refuses the whole tree).
import type { EngineInterface, RenderElement } from 'claude-code'

import type { BandVerdict, CallVerdict, GroupVerdict, ReplyVerdict, UserVerdict } from './verdict'
import type { FeedCommand, Session } from './settings'

type Elements = ReturnType<EngineInterface['ui']['resolve']>

export type Inks = {
  readonly you: string; readonly claude: string; readonly peer: string; readonly mark: string; readonly chip: string
  readonly green: string; readonly red: string; readonly amber: string; readonly accent: string
}
/** §13 table; `light` from the /config theme, read by the 1 s tick at most every 30 s. */
export function inks(light: boolean): Inks {
  throw new Error('not implemented')
}

/** Context every tree needs: elements, inks, room, whether chevrons are Buttons, and the press handler. */
export type Pen = {
  readonly el: Elements
  readonly ink: Inks
  readonly room: number
  readonly pad: number // 7 on the terminal, 0 on desktop
  readonly clickable: boolean
  readonly press: (key: string) => void // session.toggle
}

export const NOTHING = (pen: Pen): RenderElement => { throw new Error('not implemented') } // an empty Box: draws no row

/** Turn line, run line, call line, helper row, question rows (§4.6, §7.1, §11). */
export function drawCall(v: CallVerdict, pen: Pen): RenderElement {
  throw new Error('not implemented')
}
/** 'stack' draws each call's tree in a column; 'batch' the §7.2 helper batch; 'engine' never reaches here. */
export function drawGroup(v: Exclude<GroupVerdict, { draw: 'engine' }>, pen: Pen): RenderElement {
  throw new Error('not implemented')
}
/** The "you" margin, the hook-text line, peer lines, bursts, frames and cards (§3.1, §8). */
export function drawUser(v: Exclude<UserVerdict, { draw: 'engine' }>, pen: Pen): RenderElement {
  throw new Error('not implemented')
}
/**
 * The "claude" margin beside the ENGINE's drawing of the reply (passed in as
 * `engine`), the error line in its place, and the steps line under it. The
 * reply's markdown is never redrawn by the mod: an inner hook's drawing (cs-
 * mermaid's diagrams) survives whichever order the two load in.
 */
export function drawReply(v: ReplyVerdict, engine: RenderElement, pen: Pen): RenderElement {
  throw new Error('not implemented')
}
/** Ours above `beneath` (what next(e) drew: cs's band, or the engine's), in one column. */
export function drawBand(v: Exclude<BandVerdict, { draw: 'engine' }>, beneath: RenderElement, frame: number, pen: Pen): RenderElement {
  throw new Error('not implemented')
}

/** The "Chat view" pane (§2.3) for this session: header, an on/off row (FeedCommand `toggle`), one row per FIELDS entry with its picture, the Show chips. Buttons are siblings of Texts, never inside one. */
export function drawSettingsPane(mode: string, session: Session, pen: Pen, onPress: (cmd: FeedCommand) => void): RenderElement {
  throw new Error('not implemented')
}
/** The "Helpers" pane (§7.4): last 6 helpers, newest first, head, "now:", up to 12 calls from each one's transcript. */
export function drawHelpersPane(blocks: readonly HelperBlock[], pen: Pen): RenderElement {
  throw new Error('not implemented')
}
export type HelperBlock = { readonly head: string; readonly running: boolean; readonly now?: string; readonly calls: readonly string[] }
