// ABOUTME: The shape of the lab's surface registry: each cs mod surface, the states a person meets it in, and its reusable parts.
// ABOUTME: Every mod's entry builds its list from these types; the lab reads the bundled lists as SURFACES.
import type { EngineInterface, RenderElement } from 'claude-code'

export type Elements = ReturnType<EngineInterface['ui']['resolve']>
export type Theme = 'light' | 'dark'

// What a surface draws that the lab's engine cannot draw yet. The frame
// badges each one over what it can draw.
export type Need = 'position=absolute' | 'Code' | 'hover' | 'focus inverse' | 'engine drawing'

// One state, named for what a person is doing. `cols` is the terminal's
// width; the draw function takes off what the engine reserves.
export type State = { id: string; name: string; draw: (cols: number, theme: Theme) => RenderElement }

// A reusable piece of a surface: a node of one state's tree, by its child
// index path from the root.
export type Part = { id: string; name: string; state: string; path: number[] }

// The frame the engine draws around a surface: a pane's border and tabs, or
// the band's reserved `[-]` cells.
export type Chrome = { kind: 'pane'; title: string; rows: number } | { kind: 'above-prompt' }

export type Surface = {
  id: string
  mod: string
  slot: string
  source: 'generated'
  global: string
  needs: Need[]
  chrome?: Chrome
  states: State[]
  parts: Part[]
}

// The element table the shim puts on the page.
declare global {
  // eslint-disable-next-line no-var
  var LabElements: Elements
}
export function elements(): Elements {
  const el = globalThis.LabElements
  if (el === undefined) throw new Error('the lab shim (docs/surfaces/shim.js) is not loaded: LabElements is undefined')
  return el
}
