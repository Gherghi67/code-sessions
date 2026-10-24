// ABOUTME: cs-feed's trees: turns a verdict into elements from $.ui.resolve(e), with the inks (§13) and the 7-column name margin.
// ABOUTME: No decisions and no $ calls but resolve; a Button never sits inside a Text (the engine refuses the whole tree).
import type { EngineInterface, RenderElement } from 'claude-code'

import type { BandVerdict, CallVerdict, GroupVerdict, ReplyVerdict, UserVerdict } from './verdict'
import type { FeedCommand, Session } from './settings'
import { burstLine, frameBody, frameHead, helperNoteLine, hhmm, hookNotice, joined, labels, marks, peerLine } from './words'

type Elements = ReturnType<EngineInterface['ui']['resolve']>

export type Inks = {
  readonly you: string; readonly claude: string; readonly peer: string; readonly mark: string; readonly chip: string
  readonly green: string; readonly red: string; readonly amber: string; readonly accent: string
}
/** §13 table; `light` from the /config theme, read by the 1 s tick at most every 30 s. */
export function inks(light: boolean): Inks {
  return light
    ? { you: '#2f4f6f', claude: '#8a4a1f', peer: '#5b3fb5', mark: '#5b3fb5', chip: '#e4e6eb', green: '#1f7a4a', red: '#b42318', amber: '#8a5a00', accent: '#d97757' }
    : { you: '#9fb4c8', claude: '#e3c4a2', peer: '#a78bfa', mark: '#b9acec', chip: '#3b3b3b', green: '#7fbf8f', red: '#e06c6c', amber: '#d8b36a', accent: '#d97757' }
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

export const NOTHING = (pen: Pen): RenderElement => pen.el.Box({})

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
  const { Box, Text } = pen.el
  switch (v.draw) {
    case 'nothing': return NOTHING(pen)
    case 'you': return <Box flexDirection="column" marginTop={1}><Box flexDirection="row"><Box width={pen.pad}><Text color={pen.ink.you} dimColor>{labels.you}</Text></Box><Box flexGrow={1}><Text>{v.text}</Text></Box>{v.at === undefined ? null : <Text dimColor>{hhmm(v.at)}</Text>}</Box></Box>
    case 'hookText': return <Box paddingLeft={pen.pad}><Text dimColor>{hookNotice(v.line)}</Text></Box>
    case 'peer': return <Box paddingLeft={pen.pad}><Text color={pen.ink.peer}>{peerLine(v.sender, v.headline)}</Text></Box>
    case 'helperNote': return <Box paddingLeft={pen.pad}><Text color={pen.ink.peer}>{helperNoteLine(v.headline, v.durationMs)}</Text></Box>
    case 'backgroundNote': return <Box paddingLeft={pen.pad}><Text dimColor>{labels.backgroundUpdate}</Text></Box>
    case 'burst': {
      const head = v.members[0]
      if (!head) return NOTHING(pen)
      return <Box flexDirection="column" paddingLeft={pen.pad}><Box flexDirection="row"><Text color={pen.ink.peer}>{burstLine(v.members)}</Text>{chevron(`burst-${head.uuid}`, v.opened, pen)}</Box>{v.opened ? v.members.map(member => <Box paddingLeft={2}><Text color={pen.ink.peer}>{joined([member.sender, member.at === undefined ? undefined : hhmm(member.at)])}</Text></Box>) : null}</Box>
    }
    case 'frames': return <Box flexDirection="column" paddingLeft={pen.pad}>{v.frames.map(frame => <Box flexDirection="column"><Text color={pen.ink.peer}>{frameHead(frame)}</Text><Box flexDirection="column" paddingLeft={2}>{frameBody(frame).map(line => <Text dimColor>{line}</Text>)}</Box></Box>)}</Box>
  }
}

function chevron(key: string, opened: boolean, pen: Pen): RenderElement {
  const { Button, Text } = pen.el
  const label = opened ? marks.opened : marks.closed
  return pen.clickable ? <Button key={key} label={label} onPress={() => pen.press(key)} /> : <Text dimColor>{label}</Text>
}
/**
 * The "claude" margin beside the ENGINE's drawing of the reply (passed in as
 * `engine`), the error line in its place, and the steps line under it. The
 * reply's markdown is never redrawn by the mod: an inner hook's drawing (cs-
 * mermaid's diagrams) survives whichever order the two load in.
 */
export function drawReply(v: ReplyVerdict, engine: RenderElement, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  const body = typeof v.body === 'object'
    ? <Box flexDirection="column" paddingLeft={pen.pad}><Text color={v.body.error.tone === 'red' ? pen.ink.red : v.body.error.tone === 'amber' ? pen.ink.amber : pen.ink.peer}>{v.body.error.head}</Text>{v.body.error.rest.map(line => <Text dimColor>{line}</Text>)}</Box>
    : v.body === 'nothing' ? NOTHING(pen)
      : <Box flexDirection="row"><Box width={pen.pad}>{v.name ? <Text color={pen.ink.claude} dimColor>{labels.claude}</Text> : null}</Box><Box flexGrow={1} flexDirection="column">{engine}</Box></Box>
  return <Box flexDirection="column">{body}{v.stepsLine ? drawCall(v.stepsLine, pen) : null}</Box>
}
/** Ours above `beneath` (what next(e) drew: cs's band, or the engine's), in one column. */
export function drawBand(v: Exclude<BandVerdict, { draw: 'engine' }>, beneath: RenderElement, frame: number, pen: Pen): RenderElement {
  throw new Error('not implemented')
}

/** The "Chat view" pane (§2.3) for this session: header, an on/off row (FeedCommand `switch`), one row per FIELDS entry with its picture, the Show chips. Buttons are siblings of Texts, never inside one. */
export function drawSettingsPane(mode: string, session: Session, pen: Pen, onPress: (cmd: FeedCommand) => void): RenderElement {
  throw new Error('not implemented')
}
/** The "Helpers" pane (§7.4): last 6 helpers, newest first, head, "now:", up to 12 calls from each one's transcript. */
export function drawHelpersPane(blocks: readonly HelperBlock[], pen: Pen): RenderElement {
  throw new Error('not implemented')
}
export type HelperBlock = { readonly head: string; readonly running: boolean; readonly now?: string; readonly calls: readonly string[] }
