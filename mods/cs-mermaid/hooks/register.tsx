// ABOUTME: cs-mermaid mod: draws each mermaid flowchart fence in a reply inline, as coloured blocks and line glyphs, and tells the model they draw.
// ABOUTME: One /config row (`cs-mermaid.drawDiagrams`, on by default) turns off both the drawing and the system prompt section.
import type { EngineInterface, Register } from 'claude-code'

import { layout } from './layout'
import type { Layout } from './layout'
import { parse } from './parse'
import type { Graph, GraphNode, ParseError } from './parse'
import { cellWidth, padToWidth, truncateToWidth } from './text'

// The /config row (`cs-mermaid.drawDiagrams`): off, fences stay source and the
// model is not told they draw.
export const OPTION = 'drawDiagrams'

// Part of every request's system prompt: kept short, and narrow enough that
// task lists and numbered steps never draw. prompt.compose needs Claude Code
// 2.1.300 or later; an older one refuses this whole module.
export const PROMPT_SECTION = {
  id: 'cs-mermaid:diagrams',
  text: 'Mermaid flowchart fences (```mermaid with graph TD or graph LR) are drawn as diagrams in this terminal. Add one beside the prose only when an answer describes a flow that branches, loops or has four or more stages; never for a task list or numbered steps. One fence, short labels, no subgraphs; `{ }` for a decision, `(( ))` for a start or end, `[ ]` for a step; other diagram types show as source.',
  scope: 'session',
} as const

// cs's per-session opt-out of everything it injects (`cs -doctor`'s authority rows).
export const DISABLED = '.cs/local/disabled'

// A mermaid fence opens and closes on its own line with exactly three backticks. A line of four
// or more backticks, or of three tildes, opens an outer block that quotes what it holds, closed by
// a line of the same mark at least as long; a fence inside one is quoted source, not a chart.
type Fence = { start: number; end: number; body: string }
export function scanFences(text: string): Fence[] {
  const fences: Fence[] = []
  let outer: { mark: string; length: number } | undefined
  let open: { start: number; bodyStart: number } | undefined
  let at = 0
  for (const line of text.split('\n')) {
    const next = at + line.length + 1
    const trimmed = line.trim()
    const run = /^(`{3,}|~{3,})/.exec(trimmed)
    if (run) {
      const mark = run[1]!
      if (outer) {
        if (mark[0] === outer.mark && mark.length >= outer.length && trimmed === mark) outer = undefined
      } else if (open) {
        if (trimmed === '```') {
          fences.push({ start: open.start, end: at + line.length, body: text.slice(open.bodyStart, Math.max(open.bodyStart, at - 1)) })
          open = undefined
        }
      } else if (mark === '```' && trimmed.slice(3).trim() === 'mermaid') {
        // The newline before the fence belongs to it, not to the prose above.
        open = { start: Math.max(0, at - 1), bodyStart: next }
      } else if (mark.length > 3 || mark[0] === '~') {
        outer = { mark: mark[0]!, length: mark.length }
      }
    }
    at = next
  }
  return fences
}

export function fencesOf(text: string): string[] {
  return scanFences(text).map(fence => fence.body.trim()).filter(Boolean)
}

export type Fitted = { drawn: Layout; graph: Graph; turned: boolean } | { error: string }

// A left-to-right chart wider than the transcript is turned top-down; a chart still too wide, or one
// the engine refuses, is reported so the reply shows the source instead of a clipped drawing.
export function fit(graph: Graph, columns: number): Fitted {
  const first = layout(graph)
  if ('error' in first) return first
  if (first.width <= columns) return { drawn: first, graph, turned: false }
  if (graph.dir === 'LR' || graph.dir === 'RL') {
    const turned = layout({ ...graph, dir: graph.dir === 'LR' ? 'TD' : 'BT' })
    if ('error' in turned) return turned
    if (turned.width <= columns) return { drawn: turned, graph, turned: true }
    return { error: `diagram is ${turned.width} columns wide, the transcript ${columns}` }
  }
  return { error: `diagram is ${first.width} columns wide, the transcript ${columns}` }
}

// Nodes are solid blocks: three rows of background colour with the label on the middle row.
// Mermaid's default theme fills every node #ECECFF; here a node's role in the flow gives it a
// hue, so a chart of plain `[ ]` boxes still reads as a flow: a decision (diamond or hexagon,
// or any node that branches) amber, a start (a circle, or a node nothing leads to) green, an
// end (a node that leads nowhere) grey. A `style` or `classDef` fill wins over all of it.
type Palette = { fill: string; decision: string; start: string; end: string; text: string; line: string; good: string; bad: string }
const LIGHT: Palette = { fill: '#ECECFF', decision: '#FFF3BF', start: '#D3F9D8', end: '#E9ECEF', text: '#1F1F1F', line: '#333333', good: '#2B8A3E', bad: '#C92A2A' }
const DARK: Palette = { fill: '#3B3F6B', decision: '#6B5A1E', start: '#1F4D2B', end: '#3A3D42', text: '#F2F2F2', line: '#D3D3D3', good: '#69DB7C', bad: '#FF8787' }

export function paletteFor(theme: unknown): Palette {
  return typeof theme === 'string' && theme.startsWith('dark') ? DARK : LIGHT
}

export type Role = 'step' | 'decision' | 'start' | 'end'

// A node's role, by its shape first and else by its place in the flow. A lone node is a step.
export function roleOf(node: GraphNode, graph: Graph): Role {
  if (node.shape === 'diamond' || node.shape === 'hexagon') return 'decision'
  const outgoing = graph.edges.filter(edge => edge.from === node.id).length
  const incoming = graph.edges.filter(edge => edge.to === node.id).length
  // A circle is a terminal: the end when the flow only arrives at it, else the start.
  if (node.shape === 'circle' || node.shape === 'doublecircle') return outgoing === 0 && incoming > 0 ? 'end' : 'start'
  if (outgoing >= 2) return 'decision'
  if (outgoing === 0 && incoming > 0) return 'end'
  if (incoming === 0 && outgoing > 0) return 'start'
  return 'step'
}

export function fillFor(role: Role, palette: Palette): string {
  return role === 'step' ? palette.fill : palette[role]
}

// An edge label that answers a decision takes the answer's colour; any other label the line's.
const GOOD = new Set(['yes', 'y', 'ok', 'pass', 'passed', 'true', 'healthy', 'success', 'done', 'valid'])
const BAD = new Set(['no', 'n', 'fail', 'failed', 'false', 'error', 'degraded', 'invalid', 'timeout', 'reject', 'rejected'])
export function labelColor(text: string, palette: Palette): string {
  const word = text.trim().toLowerCase()
  if (GOOD.has(word)) return palette.good
  if (BAD.has(word)) return palette.bad
  return palette.line
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
function Drawing({ drawn, graph, palette, elements }: { drawn: Layout; graph: Graph; palette: Palette; elements: Elements }) {
  const { Box, Text } = elements
  return (
    <Box width={drawn.width} height={drawn.height} position="relative">
      {drawn.runs.map(run => (
        <Box position="absolute" top={run.y} left={run.x}><Text color={palette.line}>{run.text}</Text></Box>
      ))}
      {drawn.boxes.map(box => {
        const role = roleOf(box.node, graph)
        const fill = box.node.style?.fill ?? fillFor(role, palette)
        const text = box.node.style?.color ?? palette.text
        return (
          <Box position="absolute" top={box.y} left={box.x} width={box.width} height={box.height} flexDirection="column">
            {blockRows(box.node.label, box.width, box.height).map(row => (
              <Text color={text} backgroundColor={fill} bold={role === 'decision'}>{row}</Text>
            ))}
          </Box>
        )
      })}
      {drawn.labels.map(label => (
        <Box position="absolute" top={label.y} left={label.x}><Text italic color={labelColor(label.text, palette)}>{label.text}</Text></Box>
      ))}
    </Box>
  )
}

// A reply's text split into prose and mermaid fences, in order.
export function splitReply(text: string): { kind: 'text' | 'mermaid'; body: string }[] {
  const parts: { kind: 'text' | 'mermaid'; body: string }[] = []
  let last = 0
  for (const fence of scanFences(text)) {
    const before = text.slice(last, fence.start)
    if (before.trim()) parts.push({ kind: 'text', body: before })
    parts.push({ kind: 'mermaid', body: fence.body.trim() })
    last = fence.end
  }
  const after = text.slice(last)
  if (after.trim()) parts.push({ kind: 'text', body: after })
  return parts
}

// A reply re-renders on every streaming flush and every width change, and a
// chart near the limits takes over a second to lay out: keep the recent answers.
const FITTED_KEPT = 32
const fittedCache = new Map<string, Fitted | ParseError>()

export function fitSource(source: string, columns: number): Fitted | ParseError {
  const key = `${columns}\n${source}`
  const known = fittedCache.get(key)
  if (known) return known
  const graph = parse(source)
  const fitted = 'error' in graph ? graph : fit(graph, columns)
  fittedCache.set(key, fitted)
  if (fittedCache.size > FITTED_KEPT) fittedCache.delete(fittedCache.keys().next().value as string)
  return fitted
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

  // The prose around a fence goes back to the engine, so the reply keeps its bullet.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    if (fencesOf(e.props.text).length === 0) return next(e)
    // Draw each fence inline, in the room the terminal has; one that does not fit stays a fence.
    const elements = $.ui.resolve(e)
    const { Box, Text, Code } = elements
    const theme = (await $.config.list()).find(row => row.key === 'theme')?.value
    const palette = paletteFor(theme)
    const columns = Math.max(20, (e.viewport?.columns ?? 80) - 6)
    const parts = splitReply(e.props.text)
    // The engine draws the prose, the opening bullet on the reply's first part only.
    const prose = await Promise.all(parts.map((part, index) => part.kind === 'text'
      ? next({ ...e, props: { ...e.props, text: part.body, isFirstOfReply: e.props.isFirstOfReply && index === 0 } })
      : undefined))
    return (
      <Box flexDirection="column">
        {parts.map((part, index) => {
          if (part.kind === 'text') return prose[index]
          const fitted = fitSource(part.body, columns)
          if ('error' in fitted) {
            return (
              <Box flexDirection="column">
                <Code source={part.body} language="mermaid" />
                <Text dimColor>mermaid: {fitted.error}</Text>
              </Box>
            )
          }
          return <Box marginY={1}><Drawing drawn={fitted.drawn} graph={fitted.graph} palette={palette} elements={elements} /></Box>
        })}
      </Box>
    )
  })
}
