// ABOUTME: cs-mermaid's fence in each state: a source fitted by the mod's own fitSource, drawn by its Drawing or its refused-fence drawFence.
// ABOUTME: The branch is the AssistantMessage hook's, so a change to Fitted or to either draw function breaks this file at type-check.
import type { RenderElement } from 'claude-code'
import { Drawing, drawFence, fitSource, paletteFor } from '../../mods/cs-mermaid/hooks/register.tsx'
import { elements, type State, type Surface, type Theme } from './registry.ts'

// The hook's own fence branch: a chart that fits draws one blank row above and
// below it, one that does not is its source and the reason under it.
function fence(source: string, cols: number, theme: Theme): RenderElement {
  const el = elements()
  const fitted = fitSource(source, Math.max(20, cols - 6))
  if ('error' in fitted) return drawFence(source, fitted.error, el)
  return el.Box({ marginY: 1, children: [Drawing({ drawn: fitted.drawn, graph: fitted.graph, palette: paletteFor(theme), elements: el })] })
}
const state = (id: string, name: string, source: string): State => ({ id, name, draw: (cols, theme) => fence(source, cols, theme) })

const lines = (...rows: string[]) => rows.join('\n')
export const surfaces: Surface[] = [{
  id: 'cs-mermaid.AssistantMessage',
  mod: 'cs-mermaid',
  slot: 'AssistantMessage',
  source: 'generated',
  global: 'CsMermaidSurfaces',
  states: [
    state('diagram', 'reading a flowchart drawn in the reply', lines('graph TD', '  A[Start] --> B{Tests pass?}', '  B -->|yes| C[Ship]', '  B -->|no| D[Fix]')),
    state('turned', 'reading a left-to-right chart turned top-down to fit', lines('graph LR', '  A[Open the branch] --> B[Run the gate] --> C[Review the diff] --> D[Land it on main] --> E[Tag the release]')),
    state('node-roles', 'reading a chart whose blocks say start, step, decision and end', lines('graph TD', '  S((start)) --> P[step]', '  P --> Q{decide}', '  Q --> E[end]', '  Q --> P')),
    state('edge-styles', 'reading solid, dotted and thick edges with answer labels', lines('graph TD', '  A[ask] -->|yes| B[go]', '  A -.->|no| C[stop]', '  A ==> D[retry]')),
    state('refused', 'reading a fence the mod cannot draw, and why', lines('graph TD', '  subgraph one', '    A --> B', '  end')),
    state('too-wide', 'reading a chart too wide for the transcript', lines('graph TD', ...['build the docs', 'run the tests', 'lint the shell', 'check the bundle', 'sign the release', 'tag the commit'].map((step, i) => `  A[release] --> N${i}[${step}]`))),
  ],
  parts: [
    { id: 'node-block', name: 'node block', state: 'diagram', path: [0, 0] },
    { id: 'source-fallback', name: 'source fallback', state: 'refused', path: [0] },
  ],
}]
