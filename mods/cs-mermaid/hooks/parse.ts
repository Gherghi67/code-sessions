// ABOUTME: Parses a mermaid flowchart (graph/flowchart TD TB BT LR RL) into nodes, edges and styles.
// ABOUTME: Any statement outside the supported subset refuses the whole chart with the reason; there are no partial graphs.
import { cellWidth } from './text'

export type Dir = 'TD' | 'BT' | 'LR' | 'RL'
export type Shape = 'rect' | 'round' | 'stadium' | 'subroutine' | 'cylinder' | 'circle' | 'doublecircle' | 'diamond' | 'hexagon' | 'flag' | 'parallelogram' | 'trapezoid'
export type LineStyle = 'solid' | 'dotted' | 'thick'
// Blocks have no border, so `stroke:` is accepted and ignored; `fill:` and `color:` are kept.
export type NodeStyle = { fill?: string; color?: string }

export type GraphNode = { id: string; label: string; shape: Shape; style?: NodeStyle }
export type Arrow = { style: LineStyle; headAtTo: boolean; headAtFrom: boolean; label?: string }
export type GraphEdge = { id: number; from: string; to: string } & Arrow
export type Graph = { dir: Dir; nodes: GraphNode[]; edges: GraphEdge[] }
export type ParseError = { error: string }

export const LIMITS = { nodes: 200, edges: 400, label: 60 }

// Each shape by its opening and closing delimiters, longest openers first so `([` wins over `(`.
const SHAPES: { open: string; close: string; shape: Shape }[] = ([
  { open: '([', close: '])', shape: 'stadium' },
  { open: '[[', close: ']]', shape: 'subroutine' },
  { open: '[(', close: ')]', shape: 'cylinder' },
  { open: '((', close: '))', shape: 'circle' },
  { open: '(((', close: ')))', shape: 'doublecircle' },
  { open: '{{', close: '}}', shape: 'hexagon' },
  { open: '[/', close: '/]', shape: 'parallelogram' },
  { open: '[\\', close: '\\]', shape: 'parallelogram' },
  { open: '[/', close: '\\]', shape: 'trapezoid' },
  { open: '[\\', close: '/]', shape: 'trapezoid' },
  { open: '[', close: ']', shape: 'rect' },
  { open: '(', close: ')', shape: 'round' },
  { open: '{', close: '}', shape: 'diamond' },
  { open: '>', close: ']', shape: 'flag' },
] as { open: string; close: string; shape: Shape }[]).sort((p, q) => q.open.length - p.open.length)

const ID = /^[A-Za-z0-9_.-]+/
// An arrow: optional head at the source, the shaft, optional head at the target.
const ARROW = /^(<)?(-{2,}|={2,}|-\.+-)(>|o|x)?(?![-=.>ox])/

export function parse(source: string): Graph | ParseError {
  const statements = splitStatements(source)
  const first = statements.shift()
  if (first === undefined) return { error: 'empty diagram' }
  const header = /^(?:graph|flowchart)\s+(TD|TB|BT|LR|RL)$/.exec(first)
  if (!header) return { error: `not a flowchart: "${first.slice(0, 40)}"` }
  const dir: Dir = header[1] === 'TB' ? 'TD' : (header[1] as Dir)

  const nodes = new Map<string, GraphNode>()
  const edges: GraphEdge[] = []
  const classes = new Map<string, NodeStyle>()
  const classOf = new Map<string, string>()
  const styled = new Map<string, NodeStyle>()

  for (const statement of statements) {
    let match: RegExpExecArray | null
    if (/^(subgraph\b|end$)/.test(statement)) return { error: 'subgraphs are not supported' }
    if (/^(linkStyle|click|direction)\b/.test(statement)) continue
    if ((match = /^classDef\s+([\w,]+)\s+(.+)$/.exec(statement))) {
      for (const name of (match[1] ?? '').split(',')) classes.set(name, readStyle(match[2] ?? ''))
      continue
    }
    if ((match = /^class\s+([\w,]+)\s+(\w+)$/.exec(statement))) {
      for (const id of (match[1] ?? '').split(',')) classOf.set(id, match[2] ?? '')
      continue
    }
    if ((match = /^style\s+(\w+)\s+(.+)$/.exec(statement))) {
      styled.set(match[1] ?? '', readStyle(match[2] ?? ''))
      continue
    }
    const failure = readChain(statement, nodes, edges, classOf)
    if (failure) return { error: failure }
    if (nodes.size > LIMITS.nodes) return { error: `more than ${LIMITS.nodes} nodes` }
    if (edges.length > LIMITS.edges) return { error: `more than ${LIMITS.edges} edges` }
  }
  if (nodes.size === 0) return { error: 'no nodes' }

  const fallback = classes.get('default')
  for (const node of nodes.values()) {
    const named = classOf.get(node.id)
    const style = { ...(named ? classes.get(named) : fallback), ...styled.get(node.id) }
    if (Object.keys(style).length > 0) node.style = style
  }
  return { dir, nodes: [...nodes.values()], edges }
}

// Statements end at a newline or a `;` outside quotes and brackets; `%%` comments are dropped.
export function splitStatements(source: string): string[] {
  const out: string[] = []
  let current = ''
  let quote = false
  let depth = 0
  const lines = source.split('\n')
  for (const rawLine of lines) {
    const line = rawLine.trim()
    if (line.startsWith('%%')) continue
    for (let i = 0; i < line.length; i++) {
      const ch = line[i] ?? ''
      if (!quote && ch === '%' && line[i + 1] === '%') break
      if (ch === '"') quote = !quote
      else if (!quote && (ch === '[' || ch === '(' || ch === '{')) depth++
      else if (!quote && (ch === ']' || ch === ')' || ch === '}')) depth = Math.max(0, depth - 1)
      if (ch === ';' && !quote && depth === 0) {
        if (current.trim()) out.push(current.trim())
        current = ''
        continue
      }
      current += ch
    }
    if (current.trim()) out.push(current.trim())
    current = ''
    quote = false
    depth = 0
  }
  return out
}

// `A & B -->|x| C --> D`: node groups joined by arrows. Anything left unread is an error.
function readChain(statement: string, nodes: Map<string, GraphNode>, edges: GraphEdge[], classOf: Map<string, string>): string | undefined {
  let rest = statement
  let previous: string[] | undefined
  let arrow: Arrow | undefined
  for (;;) {
    const group: string[] = []
    for (;;) {
      const read = readNode(rest, nodes, classOf)
      if ('error' in read) return read.error
      group.push(read.id)
      rest = read.rest.trimStart()
      if (!rest.startsWith('&')) break
      rest = rest.slice(1).trimStart()
    }
    if (previous && arrow) {
      for (const from of previous) for (const to of group) edges.push({ id: edges.length, from, to, ...arrow })
    }
    previous = group
    if (rest === '') return undefined
    const next = readArrow(rest)
    if ('error' in next) return next.error
    arrow = next.arrow
    rest = next.rest.trimStart()
    if (rest === '') return `dangling arrow in "${statement}"`
  }
}

function readArrow(text: string): { arrow: Arrow; rest: string } | ParseError {
  // `-- text -->`, `== text ==>`, `-. text .->`
  const inline = /^(<)?(--|==|-\.)\s+([^-=.|][^|]*?)\s+(--|==|\.-)(>|o|x)?(?![-=.>ox])/.exec(text)
  let head: RegExpExecArray | null = null
  let label: string | undefined
  let rest: string
  let shaft: string
  if (inline) {
    label = inline[3]?.trim()
    shaft = inline[2] ?? '--'
    head = inline
    rest = text.slice(inline[0].length)
  } else {
    const plain = ARROW.exec(text)
    if (!plain) return { error: `expected an arrow at "${text.slice(0, 20)}"` }
    shaft = plain[2] ?? '--'
    head = plain
    rest = text.slice(plain[0].length)
    const piped = /^\s*\|([^|]*)\|/.exec(rest)
    if (piped) {
      label = piped[1]?.trim()
      rest = rest.slice(piped[0].length)
    }
  }
  const tail = inline ? inline[5] : head[3]
  if (tail === 'o' || tail === 'x') return { error: `"${tail}" arrow ends are not supported` }
  if (label !== undefined && cellWidth(label) > LIMITS.label) return { error: `edge label longer than ${LIMITS.label} cells` }
  const style: LineStyle = shaft.startsWith('=') ? 'thick' : shaft.includes('.') ? 'dotted' : 'solid'
  return { arrow: { style, headAtTo: tail === '>', headAtFrom: head[1] === '<', label: label || undefined }, rest }
}

function readNode(text: string, nodes: Map<string, GraphNode>, classOf: Map<string, string>): { id: string; rest: string } | ParseError {
  const idMatch = ID.exec(text)
  if (!idMatch) return { error: `expected a node at "${text.slice(0, 20)}"` }
  const id = idMatch[0]
  let rest = text.slice(id.length)
  let label: string | undefined
  let shape: Shape = 'rect'
  const opener = SHAPES.find(one => rest.startsWith(one.open))
  if (opener) {
    const candidates = SHAPES.filter(one => one.open === opener.open)
    const body = readDelimited(rest, opener.open, candidates.map(one => one.close))
    if ('error' in body) return body
    label = body.text
    shape = candidates.find(one => one.close === body.close)?.shape ?? opener.shape
    rest = body.rest
  }
  const inlineClass = /^:::(\w+)/.exec(rest)
  if (inlineClass) {
    classOf.set(id, inlineClass[1] ?? '')
    rest = rest.slice(inlineClass[0].length)
  }
  if (label !== undefined) {
    const clean = label.trim().replace(/^"(.*)"$/s, '$1').replace(/<br\s*\/?>/gi, ' ').trim()
    if (cellWidth(clean) > LIMITS.label) return { error: `node label longer than ${LIMITS.label} cells` }
    nodes.set(id, { id, label: clean || id, shape })
  } else if (!nodes.has(id)) {
    nodes.set(id, { id, label: id, shape: 'rect' })
  }
  return { id, rest }
}

// The text between `open` and the first matching closer, quotes respected, the shortest closer tried last.
function readDelimited(text: string, open: string, closers: string[]): { text: string; close: string; rest: string } | ParseError {
  let quote = false
  const sorted = [...closers].sort((p, q) => q.length - p.length)
  for (let i = open.length; i < text.length; i++) {
    const ch = text[i]
    if (ch === '"') {
      quote = !quote
      continue
    }
    if (quote) continue
    for (const close of sorted) {
      if (text.startsWith(close, i)) return { text: text.slice(open.length, i), close, rest: text.slice(i + close.length) }
    }
  }
  return { error: `unclosed "${open}" in "${text.slice(0, 20)}"` }
}

function readStyle(text: string): NodeStyle {
  const style: NodeStyle = {}
  for (const part of text.split(',')) {
    const [key, value] = part.split(':').map(piece => piece.trim())
    if (!value) continue
    if (key === 'fill') style.fill = value
    else if (key === 'color') style.color = value
  }
  return style
}
