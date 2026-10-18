// ABOUTME: cs-mermaid mod: draws each mermaid flowchart fence in a reply inline, as coloured blocks and line glyphs, and tells the model they draw.
// ABOUTME: One /config row (`cs-mermaid.drawDiagrams`, on by default) turns off both the drawing and the system prompt section.
import type { EngineInterface, Register } from 'claude-code'

import { layout } from './layout'
import type { Layout } from './layout'
import { parse } from './parse'
import type { Graph, Shape } from './parse'
import { cellWidth, padToWidth, truncateToWidth } from './text'

// The /config row (`cs-mermaid.drawDiagrams`): off, fences stay source and the
// model is not told they draw.
export const OPTION = 'drawDiagrams'

// Appended after the cache boundary, so it is paid on every request: kept short,
// and narrow enough that task lists and numbered steps never draw.
export const PROMPT_SECTION = {
  id: 'cs-mermaid:diagrams',
  text: 'Mermaid flowchart fences (```mermaid with graph TD or graph LR) are drawn as diagrams in this terminal. Add one beside the prose only when an answer describes a flow that branches, loops or has four or more stages; never for a task list or numbered steps. One fence, short labels, no subgraphs; other diagram types show as source.',
  scope: 'session',
} as const

// cs's per-session opt-out of everything it injects (`cs -doctor`'s authority rows).
export const DISABLED = '.cs/local/disabled'

const FENCE = /```mermaid[ \t]*\n([\s\S]*?)\n[ \t]*```/g

export function fencesOf(text: string): string[] {
  return [...text.matchAll(FENCE)].map(match => (match[1] ?? '').trim()).filter(Boolean)
}

export type Fitted = { drawn: Layout; turned: boolean } | { error: string }

// A left-to-right chart wider than the transcript is turned top-down; a chart still too wide, or one
// the engine refuses, is reported so the reply shows the source instead of a clipped drawing.
export function fit(graph: Graph, columns: number): Fitted {
  const first = layout(graph)
  if ('error' in first) return first
  if (first.width <= columns) return { drawn: first, turned: false }
  if (graph.dir === 'LR' || graph.dir === 'RL') {
    const turned = layout({ ...graph, dir: graph.dir === 'LR' ? 'TD' : 'BT' })
    if ('error' in turned) return turned
    if (turned.width <= columns) return { drawn: turned, turned: true }
    return { error: `diagram is ${turned.width} columns wide, the transcript ${columns}` }
  }
  return { error: `diagram is ${first.width} columns wide, the transcript ${columns}` }
}

// Nodes are solid blocks: three rows of background colour with the label on the middle row.
// Mermaid's default theme fills nodes #ECECFF; the decision node and the circle get their own hue.
type Palette = { fill: string; decision: string; circle: string; text: string; line: string }
const LIGHT: Palette = { fill: '#ECECFF', decision: '#FFF3BF', circle: '#F3D9FA', text: '#1F1F1F', line: '#333333' }
const DARK: Palette = { fill: '#3B3F6B', decision: '#6B5A1E', circle: '#5A2E66', text: '#F2F2F2', line: '#D3D3D3' }

export function paletteFor(theme: unknown): Palette {
  return typeof theme === 'string' && theme.startsWith('dark') ? DARK : LIGHT
}

// Decisions (diamond, hexagon) and circles get their own hue; every other shape is a plain block.
export function fillFor(shape: Shape, palette: Palette): string {
  if (shape === 'diamond' || shape === 'hexagon') return palette.decision
  if (shape === 'circle' || shape === 'doublecircle') return palette.circle
  return palette.fill
}

// The rows of a block `width` cells wide and `height` tall, the label centred on the middle row.
export function blockRows(label: string, width: number, height: number): string[] {
  const blank = ' '.repeat(width)
  const inner = truncateToWidth(label, width)
  const left = Math.floor((width - cellWidth(inner)) / 2)
  const middle = padToWidth(' '.repeat(left) + inner, width)
  return Array.from({ length: height }, (_, i) => (i === Math.floor(height / 2) ? middle : blank))
}

type Elements = ReturnType<EngineInterface['ui']['resolve']>

// The diagram as coloured blocks and line glyphs.
function Drawing({ drawn, palette, elements }: { drawn: Layout; palette: Palette; elements: Elements }) {
  const { Box, Text } = elements
  return (
    <Box width={drawn.width} height={drawn.height} position="relative">
      {drawn.runs.map(run => (
        <Box position="absolute" top={run.y} left={run.x}><Text color={palette.line}>{run.text}</Text></Box>
      ))}
      {drawn.boxes.map(box => {
        const fill = box.node.style?.fill ?? fillFor(box.node.shape, palette)
        const text = box.node.style?.color ?? palette.text
        return (
          <Box position="absolute" top={box.y} left={box.x} width={box.width} height={box.height} flexDirection="column">
            {blockRows(box.node.label, box.width, box.height).map(row => (
              <Text color={text} backgroundColor={fill} bold={box.node.shape === 'diamond' || box.node.shape === 'hexagon'}>{row}</Text>
            ))}
          </Box>
        )
      })}
      {drawn.labels.map(label => (
        <Box position="absolute" top={label.y} left={label.x}><Text italic color={palette.line}>{label.text}</Text></Box>
      ))}
    </Box>
  )
}

// A reply's text split into prose and mermaid fences, in order.
export function splitReply(text: string): { kind: 'text' | 'mermaid'; body: string }[] {
  const parts: { kind: 'text' | 'mermaid'; body: string }[] = []
  let last = 0
  for (const match of text.matchAll(FENCE)) {
    const before = text.slice(last, match.index)
    if (before.trim()) parts.push({ kind: 'text', body: before })
    parts.push({ kind: 'mermaid', body: (match[1] ?? '').trim() })
    last = (match.index ?? 0) + match[0].length
  }
  const after = text.slice(last)
  if (after.trim()) parts.push({ kind: 'text', body: after })
  return parts
}

export const register: Register = (on, options) => {
  if (options[OPTION] === false) return

  // Only a prompt for a session that draws in a terminal says fences draw; `--bare` keeps its one section.
  // A session's .cs/local/disabled turns off every cs injection into the model's context, this one too.
  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!e.surfaces.includes('terminal') || e.traits.includes('bare')) return composed
    if (await $.fs.exists(`${await $.session.cwd()}/${DISABLED}`)) return composed
    return { sections: [...composed.sections, PROMPT_SECTION] }
  })

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    if (fencesOf(e.props.text).length === 0) return next(e)
    // Draw each fence inline, in the room a transcript row has; one that does not fit stays a fence.
    const elements = $.ui.resolve(e)
    const { Box, Text, Markdown, Code } = elements
    const theme = (await $.config.list()).find(row => row.key === 'theme')?.value
    const palette = paletteFor(theme)
    const columns = Math.max(20, (e.viewport?.columns ?? 80) - 6)
    return (
      <Box flexDirection="column">
        {splitReply(e.props.text).map(part => {
          if (part.kind === 'text') return <Markdown text={part.body} />
          const graph = parse(part.body)
          const fitted = 'error' in graph ? graph : fit(graph, columns)
          if ('error' in fitted) {
            return (
              <Box flexDirection="column">
                <Code source={part.body} language="mermaid" />
                <Text dimColor>mermaid: {fitted.error}</Text>
              </Box>
            )
          }
          return <Box marginY={1}><Drawing drawn={fitted.drawn} palette={palette} elements={elements} /></Box>
        })}
      </Box>
    )
  })
}
