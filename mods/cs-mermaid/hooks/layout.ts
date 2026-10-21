// ABOUTME: Layered layout of a parsed flowchart: back edges reversed, longest-path layers, crossing-reduction sweeps, per-edge ports.
// ABOUTME: Answers placed blocks, line runs and edge labels in character cells, or the reason a chart cannot be drawn; toText renders one for tests.
import type { Graph, GraphEdge, GraphNode, LineStyle } from './parse'
import { cellWidth, truncateToWidth } from './text'

export type Placed = { node: GraphNode; x: number; y: number; width: number; height: number }
export type Run = { x: number; y: number; text: string }
export type Label = { x: number; y: number; text: string }
export type Layout = { width: number; height: number; boxes: Placed[]; runs: Run[]; labels: Label[] }
export type LayoutError = { error: string }

const MARGIN = 1
const MAX_CELLS = 200_000
const MAX_SEGMENTS = 12_000

// Items are real nodes or the dummy vertices a long edge is split into, one per layer it crosses.
type Item = {
  key: string
  node?: GraphNode
  layer: number
  order: number
  along: number // size on the layer axis (TD: height)
  cross: number // size on the cross axis (TD: width)
  a0: number
  c0: number
}
// One edge piece between adjacent layers.
type Segment = { edge: GraphEdge; from: Item; to: Item; exit: number; entry: number; first: boolean; last: boolean }

export function layout(graph: Graph): Layout | LayoutError {
  const flip = graph.dir === 'LR' || graph.dir === 'RL'
  const items = new Map<string, Item>()
  for (const node of graph.nodes) {
    const [along, cross] = flip ? [cellWidth(node.label) + 4, 3] : [3, cellWidth(node.label) + 4]
    items.set(node.id, { key: node.id, node, layer: 0, order: 0, along, cross, a0: 0, c0: 0 })
  }

  // Layering: back edges found by an iterative depth-first walk are reversed for layout.
  const outgoing = new Map<string, GraphEdge[]>()
  for (const edge of graph.edges) (outgoing.get(edge.from) ?? outgoing.set(edge.from, []).get(edge.from)!).push(edge)
  const reversed = new Set<number>()
  {
    const state = new Map<string, 'open' | 'done'>()
    for (const root of graph.nodes) {
      if (state.has(root.id)) continue
      const stack: { id: string; next: number }[] = [{ id: root.id, next: 0 }]
      state.set(root.id, 'open')
      while (stack.length > 0) {
        const top = stack[stack.length - 1]!
        const edges = outgoing.get(top.id) ?? []
        if (top.next >= edges.length) {
          state.set(top.id, 'done')
          stack.pop()
          continue
        }
        const edge = edges[top.next++]!
        const seen = state.get(edge.to)
        if (edge.to === edge.from || seen === 'open') reversed.add(edge.id)
        else if (seen === undefined) {
          state.set(edge.to, 'open')
          stack.push({ id: edge.to, next: 0 })
        }
      }
    }
  }
  const tailOf = (edge: GraphEdge) => (reversed.has(edge.id) ? edge.to : edge.from)
  const headOf = (edge: GraphEdge) => (reversed.has(edge.id) ? edge.from : edge.to)
  const forward = graph.edges.filter(edge => edge.from !== edge.to)
  {
    // Longest path from a source, in topological order (Kahn).
    const indegree = new Map<string, number>()
    const children = new Map<string, string[]>()
    for (const node of graph.nodes) indegree.set(node.id, 0)
    for (const edge of forward) {
      indegree.set(headOf(edge), (indegree.get(headOf(edge)) ?? 0) + 1)
      ;(children.get(tailOf(edge)) ?? children.set(tailOf(edge), []).get(tailOf(edge))!).push(headOf(edge))
    }
    const queue = graph.nodes.filter(node => indegree.get(node.id) === 0).map(node => node.id)
    while (queue.length > 0) {
      const id = queue.shift()!
      const layer = items.get(id)!.layer
      for (const child of children.get(id) ?? []) {
        const item = items.get(child)!
        item.layer = Math.max(item.layer, layer + 1)
        indegree.set(child, (indegree.get(child) ?? 1) - 1)
        if (indegree.get(child) === 0) queue.push(child)
      }
    }
  }

  // Count the expanded work before allocating any dummy vertices.
  const segmentCount = forward.reduce((sum, edge) => sum + items.get(headOf(edge))!.layer - items.get(tailOf(edge))!.layer, 0)
  if (segmentCount > MAX_SEGMENTS) return { error: `diagram has too many edge segments (${segmentCount}, limit ${MAX_SEGMENTS})` }

  // Dummy vertices: a long edge becomes a chain of segments between adjacent layers.
  const segments: Segment[] = []
  const chains = new Map<number, Segment[]>()
  for (const edge of forward) {
    const tail = items.get(tailOf(edge))!
    const head = items.get(headOf(edge))!
    const chain: Segment[] = []
    let previous = tail
    for (let layer = tail.layer + 1; layer < head.layer; layer++) {
      const dummy: Item = { key: `#${edge.id}@${layer}`, layer, order: 0, along: 1, cross: 1, a0: 0, c0: 0 }
      items.set(dummy.key, dummy)
      chain.push({ edge, from: previous, to: dummy, exit: 0, entry: 0, first: false, last: false })
      previous = dummy
    }
    chain.push({ edge, from: previous, to: head, exit: 0, entry: 0, first: false, last: false })
    chain[0]!.first = true
    chain[chain.length - 1]!.last = true
    chains.set(edge.id, chain)
    segments.push(...chain)
  }

  const outgoingSegments = new Map<Item, Segment[]>()
  const incomingSegments = new Map<Item, Segment[]>()
  const segmentsByGap = new Map<number, Segment[]>()
  const degree = new Map<Item, number>()
  for (const segment of segments) {
    ;(outgoingSegments.get(segment.from) ?? outgoingSegments.set(segment.from, []).get(segment.from)!).push(segment)
    ;(incomingSegments.get(segment.to) ?? incomingSegments.set(segment.to, []).get(segment.to)!).push(segment)
    ;(segmentsByGap.get(segment.to.layer) ?? segmentsByGap.set(segment.to.layer, []).get(segment.to.layer)!).push(segment)
    degree.set(segment.from, (degree.get(segment.from) ?? 0) + 1)
    degree.set(segment.to, (degree.get(segment.to) ?? 0) + 1)
  }

  const layers: Item[][] = []
  for (const item of items.values()) (layers[item.layer] ??= []).push(item)
  for (let i = 0; i < layers.length; i++) layers[i] ??= []
  orderLayers(layers, segments, segmentsByGap, degree)

  // Cross positions: real nodes widen for their ports, and in TD for the label that sits
  // beside a straight exit; layers are centred on the widest.
  const crossGap = flip ? 1 : 3
  const labelOf = (s: Segment) => (s.first && s.edge.label ? cellWidth(s.edge.label) : 0)
  // A labelled exit: the port, a gap, the label, and a cell of air before the next port's line.
  const exitSpan = (s: Segment) => (!flip && labelOf(s) > 0 ? labelOf(s) + 4 : 2)
  for (const item of items.values()) {
    if (!item.node) continue
    const exits = (outgoingSegments.get(item) ?? []).slice()
    const entries = (incomingSegments.get(item) ?? []).slice().length
    // n ports two cells apart need 2n+1 cells; a labelled exit needs its label's room after it.
    const exitRoom = exits.reduce((sum, s) => sum + exitSpan(s), 0) + 1
    item.cross = Math.max(item.cross, entries * 2 + 1, exitRoom)
  }
  const totals = layers.map(layer => layer.reduce((sum, item) => sum + item.cross, 0) + crossGap * Math.max(0, layer.length - 1))
  const maxTotal = Math.max(0, ...totals)
  layers.forEach((layer, i) => {
    let c = MARGIN + Math.floor((maxTotal - (totals[i] ?? 0)) / 2)
    for (const item of layer) {
      item.c0 = c
      c += item.cross + crossGap
    }
  })

  // Ports: each segment leaves and enters at its own column, spread across the node and
  // ordered by the far end so segments do not cross on the way out.
  for (const item of items.values()) {
    const centre = (other: Item) => other.c0 + Math.floor(other.cross / 2)
    const exits = (outgoingSegments.get(item) ?? []).slice().sort((p, q) => centre(p.to) - centre(q.to))
    const entries = (incomingSegments.get(item) ?? []).slice().sort((p, q) => centre(p.from) - centre(q.from))
    entries.forEach((s, i) => (s.entry = portAt(item, i, entries.length)))
    if (!item.node || exits.every(s => exitSpan(s) === 2)) {
      exits.forEach((s, i) => (s.exit = portAt(item, i, exits.length)))
      continue
    }
    // Labelled exits: each port is followed by the room its label needs.
    const used = exits.reduce((sum, s) => sum + exitSpan(s), 0) - 2
    let c = item.c0 + 1 + Math.floor((item.cross - 2 - used) / 2)
    for (const s of exits) {
      s.exit = c
      c += exitSpan(s)
    }
  }
  // Ends one cell apart run straight: rounding, not meaning, put them apart.
  for (const s of segments) {
    if (Math.abs(s.exit - s.entry) !== 1) continue
    const siblings = (segmentsByGap.get(s.to.layer) ?? []).filter(o => o !== s)
    // Never snap onto, or right beside, another line in the same gap.
    const clear = (c: number) => !siblings.some(o => Math.abs(o.exit - c) <= 1 || Math.abs(o.entry - c) <= 1)
    if (clear(s.entry) && s.entry > s.from.c0 && s.entry < s.from.c0 + s.from.cross - 1) s.exit = s.entry
    else if (clear(s.exit) && s.exit > s.to.c0 && s.exit < s.to.c0 + s.to.cross - 1) s.entry = s.exit
  }
  // Two different segments sharing a column in one gap would overlap: nudge the entry.
  for (let gap = 1; gap < layers.length; gap++) {
    const inGap = segmentsByGap.get(gap) ?? []
    const used = new Set<number>()
    for (const s of inGap) used.add(s.exit)
    for (const s of inGap) {
      if (s.from.node && s.to.node && s.exit === s.entry) continue
      const taken = new Set([...used].filter(c => inGap.some(o => o !== s && (o.exit === c || o.entry === c))))
      let entry = s.entry
      // Whole steps of two first, so a moved entry stays clear of its neighbours.
      for (const delta of [0, 2, -2, 1, -1]) {
        const candidate = s.entry + delta
        if (candidate > s.to.c0 && candidate < s.to.c0 + s.to.cross - 1 && !taken.has(candidate)) {
          entry = candidate
          break
        }
      }
      s.entry = entry
      used.add(entry)
    }
  }

  // Bus rows per gap for segments that move across; overlapping spans take different rows.
  const busOf = new Map<Segment, number>()
  const busCount: number[] = []
  for (let gap = 1; gap < layers.length; gap++) {
    const movers = (segmentsByGap.get(gap) ?? []).filter(s => s.exit !== s.entry).sort((p, q) => Math.min(p.exit, p.entry) - Math.min(q.exit, q.entry))
    const rowEnds: number[] = []
    for (const s of movers) {
      const lo = Math.min(s.exit, s.entry)
      const hi = Math.max(s.exit, s.entry)
      let row = rowEnds.findIndex(end => end + 2 <= lo)
      if (row < 0) row = rowEnds.push(-Infinity) - 1
      rowEnds[row] = hi
      busOf.set(s, row)
    }
    busCount[gap] = rowEnds.length
  }

  // Along positions: every layer is as tall as its tallest item. A gap holds its buses at its
  // far end and, in LR, room near its start for the labels that run along the edge.
  const gapStart: number[] = []
  const gapSize: number[] = []
  let a = MARGIN
  layers.forEach((layer, i) => {
    gapStart[i] = a
    if (i > 0) {
      const labelRoom = flip ? Math.max(0, ...(segmentsByGap.get(i) ?? []).filter(s => labelOf(s) > 0).map(s => labelOf(s) + 2)) : 0
      gapSize[i] = Math.max(2, 2 + (busCount[i] ?? 0), labelRoom + (busCount[i] ?? 0) + 1)
      a += gapSize[i]!
    }
    const along = Math.max(1, ...layer.map(item => item.along))
    for (const item of layer) {
      item.a0 = a
      item.along = along
    }
    a += along
  })
  const busRow = (s: Segment, bus: number) => (gapStart[s.to.layer] ?? 0) + (gapSize[s.to.layer] ?? 2) - 2 - bus

  // Nodes alone already provide a lower bound on the final drawing size.
  // Refuse an oversized drawing before allocating its line grid.
  const nodes = [...items.values()].filter(item => item.node)
  const alongSize = Math.max(0, ...nodes.map(item => item.a0 + item.along)) + MARGIN
  const crossSize = Math.max(0, ...nodes.map(item => item.c0 + item.cross)) + MARGIN
  if (alongSize * crossSize > MAX_CELLS) {
    return { error: `diagram would be ${flip ? alongSize : crossSize}x${flip ? crossSize : alongSize} cells` }
  }

  const grid = new Grid()
  // A dummy vertex is the edge passing through its layer: draw it as a straight piece.
  for (const item of items.values()) {
    if (item.node) continue
    const edgeId = Number(item.key.slice(1).split('@')[0])
    const style = graph.edges[edgeId]?.style ?? 'solid'
    grid.along(edgeId, item.c0, item.a0, item.a0 + item.along - 1, style)
  }
  for (const s of segments) {
    const start = s.from.a0 + s.from.along
    const end = s.to.a0 - 1
    const bus = busOf.get(s)
    if (bus === undefined) grid.along(s.edge.id, s.exit, start, end, s.edge.style)
    else {
      const row = busRow(s, bus)
      grid.along(s.edge.id, s.exit, start, row, s.edge.style)
      grid.cross(s.edge.id, row, s.exit, s.entry, s.edge.style)
      grid.along(s.edge.id, s.entry, row, end, s.edge.style)
    }
    // Heads: the drawn direction of a reversed edge runs opposite to the written one.
    const flipped = reversed.has(s.edge.id)
    const headAtDrawnEnd = flipped ? s.edge.headAtFrom : s.edge.headAtTo
    const headAtDrawnStart = flipped ? s.edge.headAtTo : s.edge.headAtFrom
    if (s.last && headAtDrawnEnd) grid.arrow(s.edge.id, s.entry, end, 'end')
    if (s.first && headAtDrawnStart) grid.arrow(s.edge.id, s.exit, start, 'start')
  }

  const width0 = Math.max(...[...items.values()].map(item => item.c0 + item.cross), 0) + 2
  const boxes: Placed[] = []
  const blocked = new Occupancy()
  for (const item of items.values()) {
    if (!item.node) continue
    blocked.add(item.a0, item.c0, item.along, item.cross)
    const { x, y } = point(flip, item.a0, item.c0)
    boxes.push({ node: item.node, x, y, width: flip ? item.along : item.cross, height: flip ? item.cross : item.along })
  }

  // Labels: a rectangle beside the first segment that covers no node, no other edge and no
  // other label; the edge's own cells beneath it are erased. Truncated when nothing fits.
  const labels: Label[] = []
  for (const edge of graph.edges) {
    if (!edge.label) continue
    const chain = chains.get(edge.id)
    const s = chain?.[0]
    if (!s) continue
    const start = s.from.a0 + s.from.along
    const bus = busOf.get(s)
    const row = bus === undefined ? start : busRow(s, bus)
    const text = edge.label
    const placed = placeLabel(grid, blocked, labels, flip, edge.id, text, s, row, width0)
    labels.push(placed)
    blocked.add(flip ? placed.x : placed.y, flip ? placed.y : placed.x, flip ? cellWidth(placed.text) : 1, flip ? 1 : cellWidth(placed.text))
  }

  let runs = grid.runs(flip)
  const width = Math.max(...boxes.map(b => b.x + b.width), ...runs.map(r => r.x + cellWidth(r.text)), ...labels.map(l => l.x + cellWidth(l.text)), 0) + MARGIN
  const height = Math.max(...boxes.map(b => b.y + b.height), ...runs.map(r => r.y + 1), ...labels.map(l => l.y + 1), 0) + MARGIN
  if (width * height > MAX_CELLS) return { error: `diagram would be ${width}x${height} cells` }

  if (graph.dir === 'BT' || graph.dir === 'RL') {
    const mirrorY = graph.dir === 'BT'
    for (const box of boxes) {
      if (mirrorY) box.y = height - box.y - box.height
      else box.x = width - box.x - box.width
    }
    for (const label of labels) {
      if (mirrorY) label.y = height - 1 - label.y
      else label.x = width - label.x - cellWidth(label.text)
    }
    runs = runs.map(run => {
      if (mirrorY) return { x: run.x, y: height - 1 - run.y, text: [...run.text].map(mirrorGlyphY).join('') }
      return { x: width - run.x - run.text.length, y: run.y, text: [...run.text].reverse().map(mirrorGlyphX).join('') }
    })
  }
  return { width, height, boxes, runs, labels }
}

function point(flip: boolean, along: number, cross: number): { x: number; y: number } {
  return flip ? { x: along, y: cross } : { x: cross, y: along }
}

// The i-th of n ports across an item: dummies have one column; a node's ports sit two cells
// apart, the group centred inside its edges.
function portAt(item: Item, i: number, n: number): number {
  if (!item.node) return item.c0
  const inner = item.cross - 2
  const start = item.c0 + 1 + Math.floor((inner - (2 * n - 1)) / 2)
  return start + 2 * i
}

// Several starting orders, each refined by barycenter sweeps and transposes; fewest crossings wins.
function orderLayers(layers: Item[][], segments: Segment[], byGap: Map<number, Segment[]>, degree: Map<Item, number>): void {
  const starts: Item[][][] = [
    layers.map(layer => [...layer]),
    layers.map(layer => [...layer].reverse()),
    layers.map(layer => [...layer].sort((p, q) => (degree.get(q) ?? 0) - (degree.get(p) ?? 0))),
  ]
  let best = Infinity
  let bestOrder = starts[0]!
  for (const start of starts) {
    start.forEach((layer, i) => (layers[i] = layer))
    const count = refineOrder(layers, segments, byGap)
    if (count < best) {
      best = count
      bestOrder = layers.map(layer => [...layer])
    }
    if (best === 0) break
  }
  bestOrder.forEach((layer, i) => {
    layers[i] = layer
    layer.forEach((item, j) => (item.order = j))
  })
}

// Crossing counts are the cost of ordering: each is a pass over every pair of segments in a
// gap, and the transposes and permutations below ask for thousands. Past this many pairs the
// order stands as it is, so a chart at the parser's limits draws in a second or two
// instead of holding the render hook for tens of seconds; a small chart never reaches it.
const ORDERING_BUDGET = 4_000_000

function refineOrder(layers: Item[][], segments: Segment[], byGap: Map<number, Segment[]>): number {
  layers.forEach(layer => layer.forEach((item, i) => (item.order = i)))
  let work = 0
  const exhausted = () => work > ORDERING_BUDGET
  const up = new Map<Item, Item[]>()
  const down = new Map<Item, Item[]>()
  for (const s of segments) {
    ;(down.get(s.from) ?? down.set(s.from, []).get(s.from)!).push(s.to)
    ;(up.get(s.to) ?? up.set(s.to, []).get(s.to)!).push(s.from)
  }
  const sweep = (layer: Item[], neighbours: Map<Item, Item[]>) => {
    const score = new Map<Item, number>()
    for (const item of layer) {
      const near = neighbours.get(item) ?? []
      score.set(item, near.length === 0 ? item.order : near.reduce((sum, n) => sum + n.order, 0) / near.length)
    }
    layer.sort((p, q) => (score.get(p) ?? 0) - (score.get(q) ?? 0) || p.order - q.order)
    layer.forEach((item, i) => (item.order = i))
  }
  const crossings = () => {
    let count = 0
    for (let i = 1; i < layers.length; i++) {
      const between = byGap.get(i) ?? []
      work += (between.length * (between.length - 1)) / 2
      for (let p = 0; p < between.length; p++) for (let q = p + 1; q < between.length; q++) {
        const a = between[p]!, b = between[q]!
        if ((a.from.order - b.from.order) * (a.to.order - b.to.order) < 0) count++
      }
    }
    return count
  }
  let best = crossings()
  let bestOrder = layers.map(layer => [...layer])
  for (let pass = 0; pass < 4 && best > 0 && !exhausted(); pass++) {
    if (pass % 2 === 0) for (let i = 1; i < layers.length; i++) sweep(layers[i]!, up)
    else for (let i = layers.length - 2; i >= 0; i--) sweep(layers[i]!, down)
    const now = crossings()
    if (now < best) {
      best = now
      bestOrder = layers.map(layer => [...layer])
    }
  }
  bestOrder.forEach((layer, i) => {
    layers[i] = layer
    layer.forEach((item, j) => (item.order = j))
  })
  // Transpose: swap neighbours while that removes crossings.
  for (let round = 0; round < 10 && best > 0 && !exhausted(); round++) {
    let improved = false
    for (const layer of layers) {
      for (let i = 0; i + 1 < layer.length && !exhausted(); i++) {
        const p = layer[i]!, q = layer[i + 1]!
        ;[layer[i], layer[i + 1]] = [q, p]
        p.order = i + 1
        q.order = i
        const now = crossings()
        if (now < best) {
          best = now
          improved = true
        } else {
          ;[layer[i], layer[i + 1]] = [p, q]
          p.order = i
          q.order = i + 1
        }
      }
    }
    if (!improved) break
  }
  // A small chart: every combination of layer orders, since one layer at a time can stall.
  const factorial = (n: number): number => (n <= 1 ? 1 : n * factorial(n - 1))
  const combinations = layers.reduce((product, layer) => product * factorial(layer.length), 1)
  if (best > 0 && combinations <= 5000 && !exhausted()) {
    const search = (index: number) => {
      if (exhausted()) return
      if (index === layers.length) {
        const now = crossings()
        if (now < best) {
          best = now
          bestOrder = layers.map(layer => [...layer])
        }
        return
      }
      const layer = layers[index]!
      for (const perm of permutations([...layer])) {
        layer.splice(0, layer.length, ...perm)
        layer.forEach((item, i) => (item.order = i))
        search(index + 1)
        if (best === 0 || exhausted()) return
      }
    }
    bestOrder = layers.map(layer => [...layer])
    search(0)
    bestOrder.forEach((layer, i) => {
      layers[i] = layer
      layer.forEach((item, j) => (item.order = j))
    })
    return best
  }
  // Small layers: try every order of one layer with the others fixed, until nothing improves.
  for (let round = 0; round < 6 && best > 0 && !exhausted(); round++) {
    let improved = false
    for (const layer of layers) {
      if (layer.length < 2 || layer.length > 6 || exhausted()) continue
      const current = [...layer]
      let bestPerm = current
      for (const perm of permutations(current)) {
        perm.forEach((item, i) => (item.order = i))
        const now = crossings()
        if (now < best) {
          best = now
          bestPerm = [...perm]
          improved = true
        }
      }
      layer.splice(0, layer.length, ...bestPerm)
      layer.forEach((item, i) => (item.order = i))
    }
    if (!improved) break
  }
  return best
}

function* permutations<T>(list: T[]): Generator<T[]> {
  if (list.length <= 1) {
    yield [...list]
    return
  }
  for (let i = 0; i < list.length; i++) {
    const rest = [...list.slice(0, i), ...list.slice(i + 1)]
    for (const tail of permutations(rest)) yield [list[i]!, ...tail]
  }
}

class Occupancy {
  private cells = new Set<string>()
  add(a0: number, c0: number, along: number, cross: number) {
    for (let a = a0; a < a0 + along; a++) for (let c = c0; c < c0 + cross; c++) this.cells.add(`${a},${c}`)
  }
  has(a: number, c: number): boolean {
    return this.cells.has(`${a},${c}`)
  }
}

function placeLabel(grid: Grid, blocked: Occupancy, labels: Label[], flip: boolean, edgeId: number, text: string, s: Segment, row: number, width: number): Label {
  const free = (a: number, c: number, len: number) => {
    for (let i = 0; i < len; i++) {
      if (blocked.has(a, c + i)) return false
      if (grid.ownedByOther(edgeId, a, c + i)) return false
    }
    return true
  }
  // In TD the label is a row of cells across the cross axis; in LR it must still read left to
  // right, so it occupies one cross position and runs along the layer axis.
  const len = cellWidth(text)
  const start = s.from.a0 + s.from.along
  const straight = s.exit === s.entry
  const candidates: { a: number; c: number }[] = flip
    ? [
        { a: start, c: s.exit - 1 },
        { a: start, c: s.exit + 1 },
        { a: s.to.a0 - 1 - len, c: s.entry - 1 },
      ]
    : straight
      ? [
          { a: start, c: s.exit + 2 },
          { a: start, c: s.exit - 1 - len },
        ]
      : [
          // Beside the exit's own vertical run first: the corner and the head stay drawn.
          { a: start, c: s.exit + 2 },
          { a: start, c: s.exit - 1 - len },
          { a: row, c: Math.min(s.exit, s.entry) + 2 },
        ]
  for (const at of candidates) {
    if (flip) {
      if (at.c < 0) continue
      const ok = Array.from({ length: len }, (_, i) => !blocked.has(at.a + i, at.c) && !grid.ownedByOther(edgeId, at.a + i, at.c)).every(Boolean)
      if (!ok) continue
      for (let i = 0; i < len; i++) grid.erase(at.a + i, at.c)
      const { x, y } = point(true, at.a, at.c)
      return { x, y, text }
    }
    if (at.c < 1 || at.c + len > width + 20) continue
    if (!free(at.a, at.c, len)) continue
    if (labels.some(l => l.y === at.a && l.x < at.c + len && l.x + cellWidth(l.text) > at.c)) continue
    for (let i = 0; i < len; i++) grid.erase(at.a, at.c + i)
    return { x: at.c, y: at.a, text }
  }
  // Nothing fits whole: take the first candidate and cut the text to the room there.
  const at = candidates[0]!
  let room = 0
  while (room < len && (flip ? !blocked.has(at.a + room, at.c) && !grid.ownedByOther(edgeId, at.a + room, at.c) : !blocked.has(at.a, at.c + room) && !grid.ownedByOther(edgeId, at.a, at.c + room))) room++
  const cut = truncateToWidth(text, Math.max(1, room))
  for (let i = 0; i < cellWidth(cut); i++) flip ? grid.erase(at.a + i, at.c) : grid.erase(at.a, at.c + i)
  const { x, y } = point(flip, at.a, at.c)
  return { x, y, text: cut }
}

const UP = 1, DOWN = 2, LEFT = 4, RIGHT = 8
type Cell = { owner: number; mask: number; style: LineStyle; crossing: boolean; arrow?: 'end' | 'start' }

class Grid {
  private cells = new Map<string, Cell>()

  private mark(owner: number, a: number, c: number, bit: number, style: LineStyle) {
    const key = `${a},${c}`
    const cell = this.cells.get(key)
    if (!cell) {
      this.cells.set(key, { owner, mask: bit, style, crossing: false })
      return
    }
    if (cell.owner !== owner) cell.crossing = true
    cell.mask |= bit
  }

  along(owner: number, c: number, a0: number, a1: number, style: LineStyle) {
    const [lo, hi] = a0 <= a1 ? [a0, a1] : [a1, a0]
    for (let a = lo; a <= hi; a++) {
      if (a < hi) this.mark(owner, a, c, DOWN, style)
      if (a > lo) this.mark(owner, a, c, UP, style)
    }
    if (lo === hi) this.mark(owner, lo, c, UP | DOWN, style)
  }

  cross(owner: number, a: number, c0: number, c1: number, style: LineStyle) {
    const [lo, hi] = c0 <= c1 ? [c0, c1] : [c1, c0]
    for (let c = lo; c <= hi; c++) {
      if (c < hi) this.mark(owner, a, c, RIGHT, style)
      if (c > lo) this.mark(owner, a, c, LEFT, style)
    }
  }

  arrow(owner: number, c: number, a: number, at: 'end' | 'start') {
    const key = `${a},${c}`
    const cell = this.cells.get(key) ?? { owner, mask: UP | DOWN, style: 'solid' as const, crossing: false }
    cell.arrow = at
    this.cells.set(key, cell)
  }

  erase(a: number, c: number) {
    this.cells.delete(`${a},${c}`)
  }

  ownedByOther(owner: number, a: number, c: number): boolean {
    const cell = this.cells.get(`${a},${c}`)
    return cell !== undefined && (cell.owner !== owner || cell.crossing)
  }

  runs(flip: boolean): Run[] {
    const byRow = new Map<number, { x: number; glyph: string }[]>()
    for (const [key, cell] of this.cells) {
      const [a, c] = key.split(',').map(Number) as [number, number]
      const x = flip ? a : c
      const y = flip ? c : a
      ;(byRow.get(y) ?? byRow.set(y, []).get(y)!).push({ x, glyph: glyphOf(cell, flip) })
    }
    const runs: Run[] = []
    for (const [y, cells] of byRow) {
      cells.sort((p, q) => p.x - q.x)
      let run: Run | undefined
      for (const cell of cells) {
        if (run && run.x + run.text.length === cell.x) run.text += cell.glyph
        else runs.push((run = { x: cell.x, y, text: cell.glyph }))
      }
    }
    return runs.sort((p, q) => p.y - q.y || p.x - q.x)
  }
}

function glyphOf(cell: Cell, flip: boolean): string {
  if (cell.arrow === 'end') return flip ? '►' : '▼'
  if (cell.arrow === 'start') return flip ? '◄' : '▲'
  // Two edges through one cell: always a crossing, never a junction, since no two edges share a port.
  if (cell.crossing) return '┼'
  let mask = cell.mask
  if (flip) mask = (cell.mask & UP ? LEFT : 0) | (cell.mask & DOWN ? RIGHT : 0) | (cell.mask & LEFT ? UP : 0) | (cell.mask & RIGHT ? DOWN : 0)
  const vertical = (mask & (UP | DOWN)) !== 0 && (mask & (LEFT | RIGHT)) === 0
  const horizontal = (mask & (LEFT | RIGHT)) !== 0 && (mask & (UP | DOWN)) === 0
  if (vertical) return cell.style === 'dotted' ? '┆' : cell.style === 'thick' ? '┃' : '│'
  if (horizontal) return cell.style === 'dotted' ? '┄' : cell.style === 'thick' ? '━' : '─'
  const table: Record<number, string> = {
    [DOWN | RIGHT]: '┌', [DOWN | LEFT]: '┐', [UP | RIGHT]: '└', [UP | LEFT]: '┘',
    [UP | DOWN | RIGHT]: '├', [UP | DOWN | LEFT]: '┤', [LEFT | RIGHT | DOWN]: '┬', [LEFT | RIGHT | UP]: '┴',
  }
  return table[mask] ?? '┼'
}

const MIRROR_Y: Record<string, string> = { '┌': '└', '└': '┌', '┐': '┘', '┘': '┐', '┬': '┴', '┴': '┬', '▼': '▲', '▲': '▼' }
const MIRROR_X: Record<string, string> = { '┌': '┐', '┐': '┌', '└': '┘', '┘': '└', '├': '┤', '┤': '├', '►': '◄', '◄': '►' }
function mirrorGlyphY(glyph: string): string {
  return MIRROR_Y[glyph] ?? glyph
}
function mirrorGlyphX(glyph: string): string {
  return MIRROR_X[glyph] ?? glyph
}

// The drawing as lines of text: what a test or a preview compares against.
export function toText(drawn: Layout): string {
  const grid = Array.from({ length: drawn.height }, () => Array<string>(drawn.width).fill(' '))
  const put = (x: number, y: number, text: string) => {
    for (let i = 0; i < text.length; i++) if (grid[y] && x + i < drawn.width) grid[y]![x + i] = text[i]!
  }
  for (const run of drawn.runs) put(run.x, run.y, run.text)
  for (const box of drawn.boxes) {
    for (let y = box.y; y < box.y + box.height; y++) put(box.x, y, '█'.repeat(box.width))
    const mid = box.y + Math.floor(box.height / 2)
    const inner = truncateToWidth(box.node.label, box.width - 2)
    put(box.x + 1 + Math.floor((box.width - 2 - cellWidth(inner)) / 2), mid, inner)
  }
  for (const label of drawn.labels) put(label.x, label.y, label.text)
  return grid.map(row => row.join('').replace(/\s+$/, '')).join('\n')
}
