// ABOUTME: The shape of the lab's surface registry: each cs mod surface, the states a person meets it in, and its reusable parts.
// ABOUTME: Every mod's entry builds its list from these types; the lab reads the bundled lists as SURFACES.
import type { EngineInterface, RenderElement } from 'claude-code'

export type Elements = ReturnType<EngineInterface['ui']['resolve']>
export type Theme = 'light' | 'dark'

// A state that moves: `tick` is the step the mod's own clock redraws at, in
// ms; `duration` how long the lab plays it, a whole number of ticks, holding
// there after; `count` the words the scrubber reads beside t, where the
// state counts something down.
export type Motion = { tick: number; duration: number; count?: (t: number) => string }

// A clock that only counts up plays five minutes, rounded up to a whole tick
// so the scrubber's last step lands on the end.
export const timer = (tick: number): Motion => ({ tick, duration: Math.ceil(5 * 60 * 1000 / tick) * tick })

// One state, named for what a person is doing. `cols` is the terminal's
// width; the draw function takes off what the engine reserves. `t` is the
// moment, in ms since the state began: a moving state turns it into the
// clock its mod reads, and a still state draws the same at every t.
export type State = { id: string; name: string; draw: (cols: number, theme: Theme, t?: number) => RenderElement; motion?: Motion }

// A reusable piece of a surface: a node of one state's tree, by its child
// index path from the root.
export type Part = { id: string; name: string; state: string; path: number[] }

// The frame the engine draws around a surface: a pane's border and tabs, or
// the band's reserved `[-]` cells.
export type Chrome = { kind: 'pane'; title: string; rows: number } | { kind: 'above-prompt' }

// `generated`: the mod's own draw code builds the tree. `chrome`: Claude Code
// draws the row around words the mod hands it (a toast, a dialog, a reply),
// and the lab redraws that row from 2.1.310's components (chrome.ts) with the
// mod's words.
export type Source = 'generated' | 'chrome'

export type Surface = {
  id: string
  mod: string
  slot: string
  source: Source
  global: string
  chrome?: Chrome
  states: State[]
  parts: Part[]
}

// The element table the shim puts on the page.
declare global {
  var LabElements: Elements
}
export function elements(): Elements {
  const el = globalThis.LabElements
  if (el === undefined) throw new Error('the lab shim (docs/surfaces/shim.js) is not loaded: LabElements is undefined')
  return el
}
