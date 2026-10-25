(() => {
  // mods/cs-mermaid/hooks/text.ts
  var WIDE = /[ᄀ-ᅟ⺀-〾ぁ-㏿㐀-䶿一-鿿ꀀ-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]|[\u{1F300}-\u{1F64F}]|[\u{1F900}-\u{1F9FF}]|[\u{20000}-\u{3FFFD}]/u;
  var ZERO = /^[\p{M}​-‏️]+$/u;
  function graphemes(text) {
    const Segmenter = Intl.Segmenter;
    if (!Segmenter)
      return Array.from(text);
    return Array.from(new Segmenter("en", { granularity: "grapheme" }).segment(text), (piece) => piece.segment);
  }
  function cellsOf(grapheme) {
    if (ZERO.test(grapheme))
      return 0;
    const base = grapheme.replace(/[\p{M}​-‏️]/gu, "");
    return WIDE.test(base) ? 2 : 1;
  }
  function cellWidth(text) {
    let width = 0;
    for (const grapheme of graphemes(text))
      width += cellsOf(grapheme);
    return width;
  }
  function truncateToWidth(text, width) {
    if (cellWidth(text) <= width)
      return text;
    if (width <= 0)
      return "";
    let out = "";
    let used = 0;
    for (const grapheme of graphemes(text)) {
      const cells = cellsOf(grapheme);
      if (used + cells > width - 1)
        break;
      out += grapheme;
      used += cells;
    }
    return out + "…";
  }
  function padToWidth(text, width) {
    return text + " ".repeat(Math.max(0, width - cellWidth(text)));
  }

  // mods/cs-mermaid/hooks/layout.ts
  var MARGIN = 1;
  var MAX_CELLS = 200000;
  function layout(graph) {
    const flip = graph.dir === "LR" || graph.dir === "RL";
    const items = new Map;
    for (const node of graph.nodes) {
      const [along, cross] = flip ? [cellWidth(node.label) + 4, 3] : [3, cellWidth(node.label) + 4];
      items.set(node.id, { key: node.id, node, layer: 0, order: 0, along, cross, a0: 0, c0: 0 });
    }
    const outgoing = new Map;
    for (const edge of graph.edges)
      (outgoing.get(edge.from) ?? outgoing.set(edge.from, []).get(edge.from)).push(edge);
    const reversed = new Set;
    {
      const state = new Map;
      for (const root of graph.nodes) {
        if (state.has(root.id))
          continue;
        const stack = [{ id: root.id, next: 0 }];
        state.set(root.id, "open");
        while (stack.length > 0) {
          const top = stack[stack.length - 1];
          const edges = outgoing.get(top.id) ?? [];
          if (top.next >= edges.length) {
            state.set(top.id, "done");
            stack.pop();
            continue;
          }
          const edge = edges[top.next++];
          const seen = state.get(edge.to);
          if (edge.to === edge.from || seen === "open")
            reversed.add(edge.id);
          else if (seen === undefined) {
            state.set(edge.to, "open");
            stack.push({ id: edge.to, next: 0 });
          }
        }
      }
    }
    const tailOf = (edge) => reversed.has(edge.id) ? edge.to : edge.from;
    const headOf = (edge) => reversed.has(edge.id) ? edge.from : edge.to;
    const forward = graph.edges.filter((edge) => edge.from !== edge.to);
    {
      const indegree = new Map;
      const children = new Map;
      for (const node of graph.nodes)
        indegree.set(node.id, 0);
      for (const edge of forward) {
        indegree.set(headOf(edge), (indegree.get(headOf(edge)) ?? 0) + 1);
        (children.get(tailOf(edge)) ?? children.set(tailOf(edge), []).get(tailOf(edge))).push(headOf(edge));
      }
      const queue = graph.nodes.filter((node) => indegree.get(node.id) === 0).map((node) => node.id);
      while (queue.length > 0) {
        const id = queue.shift();
        const layer = items.get(id).layer;
        for (const child of children.get(id) ?? []) {
          const item = items.get(child);
          item.layer = Math.max(item.layer, layer + 1);
          indegree.set(child, (indegree.get(child) ?? 1) - 1);
          if (indegree.get(child) === 0)
            queue.push(child);
        }
      }
    }
    const segments = [];
    const chains = new Map;
    for (const edge of forward) {
      const tail = items.get(tailOf(edge));
      const head = items.get(headOf(edge));
      const chain = [];
      let previous = tail;
      for (let layer = tail.layer + 1;layer < head.layer; layer++) {
        const dummy = { key: `#${edge.id}@${layer}`, layer, order: 0, along: 1, cross: 1, a0: 0, c0: 0 };
        items.set(dummy.key, dummy);
        chain.push({ edge, from: previous, to: dummy, exit: 0, entry: 0, first: false, last: false });
        previous = dummy;
      }
      chain.push({ edge, from: previous, to: head, exit: 0, entry: 0, first: false, last: false });
      chain[0].first = true;
      chain[chain.length - 1].last = true;
      chains.set(edge.id, chain);
      segments.push(...chain);
    }
    const layers = [];
    for (const item of items.values())
      (layers[item.layer] ??= []).push(item);
    for (let i = 0;i < layers.length; i++)
      layers[i] ??= [];
    orderLayers(layers, segments);
    const crossGap = flip ? 1 : 3;
    const labelOf = (s) => s.first && s.edge.label ? cellWidth(s.edge.label) : 0;
    const exitSpan = (s) => !flip && labelOf(s) > 0 ? labelOf(s) + 4 : 2;
    for (const item of items.values()) {
      if (!item.node)
        continue;
      const exits = segments.filter((s) => s.from === item);
      const entries = segments.filter((s) => s.to === item).length;
      const exitRoom = exits.reduce((sum, s) => sum + exitSpan(s), 0) + 1;
      item.cross = Math.max(item.cross, entries * 2 + 1, exitRoom);
    }
    const totals = layers.map((layer) => layer.reduce((sum, item) => sum + item.cross, 0) + crossGap * Math.max(0, layer.length - 1));
    const maxTotal = Math.max(0, ...totals);
    layers.forEach((layer, i) => {
      let c = MARGIN + Math.floor((maxTotal - (totals[i] ?? 0)) / 2);
      for (const item of layer) {
        item.c0 = c;
        c += item.cross + crossGap;
      }
    });
    for (const item of items.values()) {
      const centre = (other) => other.c0 + Math.floor(other.cross / 2);
      const exits = segments.filter((s) => s.from === item).sort((p, q) => centre(p.to) - centre(q.to));
      const entries = segments.filter((s) => s.to === item).sort((p, q) => centre(p.from) - centre(q.from));
      entries.forEach((s, i) => s.entry = portAt(item, i, entries.length));
      if (!item.node || exits.every((s) => exitSpan(s) === 2)) {
        exits.forEach((s, i) => s.exit = portAt(item, i, exits.length));
        continue;
      }
      const used = exits.reduce((sum, s) => sum + exitSpan(s), 0) - 2;
      let c = item.c0 + 1 + Math.floor((item.cross - 2 - used) / 2);
      for (const s of exits) {
        s.exit = c;
        c += exitSpan(s);
      }
    }
    for (const s of segments) {
      if (Math.abs(s.exit - s.entry) !== 1)
        continue;
      const siblings = segments.filter((o) => o !== s && o.to.layer === s.to.layer);
      const clear = (c) => !siblings.some((o) => Math.abs(o.exit - c) <= 1 || Math.abs(o.entry - c) <= 1);
      if (clear(s.entry) && s.entry > s.from.c0 && s.entry < s.from.c0 + s.from.cross - 1)
        s.exit = s.entry;
      else if (clear(s.exit) && s.exit > s.to.c0 && s.exit < s.to.c0 + s.to.cross - 1)
        s.entry = s.exit;
    }
    for (let gap = 1;gap < layers.length; gap++) {
      const inGap = segments.filter((s) => s.to.layer === gap);
      const used = new Set;
      for (const s of inGap)
        used.add(s.exit);
      for (const s of inGap) {
        if (s.from.node && s.to.node && s.exit === s.entry)
          continue;
        const taken = new Set([...used].filter((c) => inGap.some((o) => o !== s && (o.exit === c || o.entry === c))));
        let entry = s.entry;
        for (const delta of [0, 2, -2, 1, -1]) {
          const candidate = s.entry + delta;
          if (candidate > s.to.c0 && candidate < s.to.c0 + s.to.cross - 1 && !taken.has(candidate)) {
            entry = candidate;
            break;
          }
        }
        s.entry = entry;
        used.add(entry);
      }
    }
    const busOf = new Map;
    const busCount = [];
    for (let gap = 1;gap < layers.length; gap++) {
      const movers = segments.filter((s) => s.to.layer === gap && s.exit !== s.entry).sort((p, q) => Math.min(p.exit, p.entry) - Math.min(q.exit, q.entry));
      const rowEnds = [];
      for (const s of movers) {
        const lo = Math.min(s.exit, s.entry);
        const hi = Math.max(s.exit, s.entry);
        let row = rowEnds.findIndex((end) => end + 2 <= lo);
        if (row < 0)
          row = rowEnds.push(-Infinity) - 1;
        rowEnds[row] = hi;
        busOf.set(s, row);
      }
      busCount[gap] = rowEnds.length;
    }
    const gapStart = [];
    const gapSize = [];
    let a = MARGIN;
    layers.forEach((layer, i) => {
      gapStart[i] = a;
      if (i > 0) {
        const labelRoom = flip ? Math.max(0, ...segments.filter((s) => s.to.layer === i && labelOf(s) > 0).map((s) => labelOf(s) + 2)) : 0;
        gapSize[i] = Math.max(2, 2 + (busCount[i] ?? 0), labelRoom + (busCount[i] ?? 0) + 1);
        a += gapSize[i];
      }
      const along = Math.max(1, ...layer.map((item) => item.along));
      for (const item of layer) {
        item.a0 = a;
        item.along = along;
      }
      a += along;
    });
    const busRow = (s, bus) => (gapStart[s.to.layer] ?? 0) + (gapSize[s.to.layer] ?? 2) - 2 - bus;
    const grid = new Grid;
    for (const item of items.values()) {
      if (item.node)
        continue;
      const edgeId = Number(item.key.slice(1).split("@")[0]);
      const style = graph.edges[edgeId]?.style ?? "solid";
      grid.along(edgeId, item.c0, item.a0, item.a0 + item.along - 1, style);
    }
    for (const s of segments) {
      const start = s.from.a0 + s.from.along;
      const end = s.to.a0 - 1;
      const bus = busOf.get(s);
      if (bus === undefined)
        grid.along(s.edge.id, s.exit, start, end, s.edge.style);
      else {
        const row = busRow(s, bus);
        grid.along(s.edge.id, s.exit, start, row, s.edge.style);
        grid.cross(s.edge.id, row, s.exit, s.entry, s.edge.style);
        grid.along(s.edge.id, s.entry, row, end, s.edge.style);
      }
      const flipped = reversed.has(s.edge.id);
      const headAtDrawnEnd = flipped ? s.edge.headAtFrom : s.edge.headAtTo;
      const headAtDrawnStart = flipped ? s.edge.headAtTo : s.edge.headAtFrom;
      if (s.last && headAtDrawnEnd)
        grid.arrow(s.edge.id, s.entry, end, "end");
      if (s.first && headAtDrawnStart)
        grid.arrow(s.edge.id, s.exit, start, "start");
    }
    const width0 = Math.max(...[...items.values()].map((item) => item.c0 + item.cross), 0) + 2;
    const boxes = [];
    const blocked = new Occupancy;
    for (const item of items.values()) {
      if (!item.node)
        continue;
      blocked.add(item.a0, item.c0, item.along, item.cross);
      const { x, y } = point(flip, item.a0, item.c0);
      boxes.push({ node: item.node, x, y, width: flip ? item.along : item.cross, height: flip ? item.cross : item.along });
    }
    const labels = [];
    for (const edge of graph.edges) {
      if (!edge.label)
        continue;
      const chain = chains.get(edge.id);
      const s = chain?.[0];
      if (!s)
        continue;
      const start = s.from.a0 + s.from.along;
      const bus = busOf.get(s);
      const row = bus === undefined ? start : busRow(s, bus);
      const text = edge.label;
      const placed = placeLabel(grid, blocked, labels, flip, edge.id, text, s, row, width0);
      labels.push(placed);
      blocked.add(flip ? placed.x : placed.y, flip ? placed.y : placed.x, flip ? cellWidth(placed.text) : 1, flip ? 1 : cellWidth(placed.text));
    }
    let runs = grid.runs(flip);
    const width = Math.max(...boxes.map((b) => b.x + b.width), ...runs.map((r) => r.x + cellWidth(r.text)), ...labels.map((l) => l.x + cellWidth(l.text)), 0) + MARGIN;
    const height = Math.max(...boxes.map((b) => b.y + b.height), ...runs.map((r) => r.y + 1), ...labels.map((l) => l.y + 1), 0) + MARGIN;
    if (width * height > MAX_CELLS)
      return { error: `diagram would be ${width}x${height} cells` };
    if (graph.dir === "BT" || graph.dir === "RL") {
      const mirrorY = graph.dir === "BT";
      for (const box of boxes) {
        if (mirrorY)
          box.y = height - box.y - box.height;
        else
          box.x = width - box.x - box.width;
      }
      for (const label of labels) {
        if (mirrorY)
          label.y = height - 1 - label.y;
        else
          label.x = width - label.x - cellWidth(label.text);
      }
      runs = runs.map((run) => {
        if (mirrorY)
          return { x: run.x, y: height - 1 - run.y, text: [...run.text].map(mirrorGlyphY).join("") };
        return { x: width - run.x - run.text.length, y: run.y, text: [...run.text].reverse().map(mirrorGlyphX).join("") };
      });
    }
    return { width, height, boxes, runs, labels };
  }
  function point(flip, along, cross) {
    return flip ? { x: along, y: cross } : { x: cross, y: along };
  }
  function portAt(item, i, n) {
    if (!item.node)
      return item.c0;
    const inner = item.cross - 2;
    const start = item.c0 + 1 + Math.floor((inner - (2 * n - 1)) / 2);
    return start + 2 * i;
  }
  function orderLayers(layers, segments) {
    const starts = [
      layers.map((layer) => [...layer]),
      layers.map((layer) => [...layer].reverse()),
      layers.map((layer) => [...layer].sort((p, q) => segments.filter((s) => s.from === q || s.to === q).length - segments.filter((s) => s.from === p || s.to === p).length))
    ];
    let best = Infinity;
    let bestOrder = starts[0];
    for (const start of starts) {
      start.forEach((layer, i) => layers[i] = layer);
      const count = refineOrder(layers, segments);
      if (count < best) {
        best = count;
        bestOrder = layers.map((layer) => [...layer]);
      }
      if (best === 0)
        break;
    }
    bestOrder.forEach((layer, i) => {
      layers[i] = layer;
      layer.forEach((item, j) => item.order = j);
    });
  }
  var ORDERING_BUDGET = 4000000;
  function refineOrder(layers, segments) {
    layers.forEach((layer) => layer.forEach((item, i) => item.order = i));
    let work = 0;
    const exhausted = () => work > ORDERING_BUDGET;
    const up = new Map;
    const down = new Map;
    for (const s of segments) {
      (down.get(s.from) ?? down.set(s.from, []).get(s.from)).push(s.to);
      (up.get(s.to) ?? up.set(s.to, []).get(s.to)).push(s.from);
    }
    const sweep = (layer, neighbours) => {
      const score = new Map;
      for (const item of layer) {
        const near = neighbours.get(item) ?? [];
        score.set(item, near.length === 0 ? item.order : near.reduce((sum, n) => sum + n.order, 0) / near.length);
      }
      layer.sort((p, q) => (score.get(p) ?? 0) - (score.get(q) ?? 0) || p.order - q.order);
      layer.forEach((item, i) => item.order = i);
    };
    const crossings = () => {
      let count = 0;
      for (let i = 1;i < layers.length; i++) {
        const between = segments.filter((s) => s.to.layer === i);
        work += between.length * (between.length - 1) / 2;
        for (let p = 0;p < between.length; p++)
          for (let q = p + 1;q < between.length; q++) {
            const a = between[p], b = between[q];
            if ((a.from.order - b.from.order) * (a.to.order - b.to.order) < 0)
              count++;
          }
      }
      return count;
    };
    let best = crossings();
    let bestOrder = layers.map((layer) => [...layer]);
    for (let pass = 0;pass < 4 && best > 0 && !exhausted(); pass++) {
      if (pass % 2 === 0)
        for (let i = 1;i < layers.length; i++)
          sweep(layers[i], up);
      else
        for (let i = layers.length - 2;i >= 0; i--)
          sweep(layers[i], down);
      const now = crossings();
      if (now < best) {
        best = now;
        bestOrder = layers.map((layer) => [...layer]);
      }
    }
    bestOrder.forEach((layer, i) => {
      layers[i] = layer;
      layer.forEach((item, j) => item.order = j);
    });
    for (let round = 0;round < 10 && best > 0 && !exhausted(); round++) {
      let improved = false;
      for (const layer of layers) {
        for (let i = 0;i + 1 < layer.length && !exhausted(); i++) {
          const p = layer[i], q = layer[i + 1];
          [layer[i], layer[i + 1]] = [q, p];
          p.order = i + 1;
          q.order = i;
          const now = crossings();
          if (now < best) {
            best = now;
            improved = true;
          } else {
            [layer[i], layer[i + 1]] = [p, q];
            p.order = i;
            q.order = i + 1;
          }
        }
      }
      if (!improved)
        break;
    }
    const factorial = (n) => n <= 1 ? 1 : n * factorial(n - 1);
    const combinations = layers.reduce((product, layer) => product * factorial(layer.length), 1);
    if (best > 0 && combinations <= 5000 && !exhausted()) {
      const search = (index) => {
        if (index === layers.length) {
          const now = crossings();
          if (now < best) {
            best = now;
            bestOrder = layers.map((layer) => [...layer]);
          }
          return;
        }
        const layer = layers[index];
        for (const perm of permutations([...layer])) {
          layer.splice(0, layer.length, ...perm);
          layer.forEach((item, i) => item.order = i);
          search(index + 1);
          if (best === 0)
            return;
        }
      };
      bestOrder = layers.map((layer) => [...layer]);
      search(0);
      bestOrder.forEach((layer, i) => {
        layers[i] = layer;
        layer.forEach((item, j) => item.order = j);
      });
      return best;
    }
    for (let round = 0;round < 6 && best > 0 && !exhausted(); round++) {
      let improved = false;
      for (const layer of layers) {
        if (layer.length < 2 || layer.length > 6 || exhausted())
          continue;
        const current = [...layer];
        let bestPerm = current;
        for (const perm of permutations(current)) {
          perm.forEach((item, i) => item.order = i);
          const now = crossings();
          if (now < best) {
            best = now;
            bestPerm = [...perm];
            improved = true;
          }
        }
        layer.splice(0, layer.length, ...bestPerm);
        layer.forEach((item, i) => item.order = i);
      }
      if (!improved)
        break;
    }
    return best;
  }
  function* permutations(list) {
    if (list.length <= 1) {
      yield [...list];
      return;
    }
    for (let i = 0;i < list.length; i++) {
      const rest = [...list.slice(0, i), ...list.slice(i + 1)];
      for (const tail of permutations(rest))
        yield [list[i], ...tail];
    }
  }

  class Occupancy {
    cells = new Set;
    add(a0, c0, along, cross) {
      for (let a = a0;a < a0 + along; a++)
        for (let c = c0;c < c0 + cross; c++)
          this.cells.add(`${a},${c}`);
    }
    has(a, c) {
      return this.cells.has(`${a},${c}`);
    }
  }
  function placeLabel(grid, blocked, labels, flip, edgeId, text, s, row, width) {
    const free = (a, c, len) => {
      for (let i = 0;i < len; i++) {
        if (blocked.has(a, c + i))
          return false;
        if (grid.ownedByOther(edgeId, a, c + i))
          return false;
      }
      return true;
    };
    const len = cellWidth(text);
    const start = s.from.a0 + s.from.along;
    const straight = s.exit === s.entry;
    const candidates = flip ? [
      { a: start, c: s.exit - 1 },
      { a: start, c: s.exit + 1 },
      { a: s.to.a0 - 1 - len, c: s.entry - 1 }
    ] : straight ? [
      { a: start, c: s.exit + 2 },
      { a: start, c: s.exit - 1 - len }
    ] : [
      { a: start, c: s.exit + 2 },
      { a: start, c: s.exit - 1 - len },
      { a: row, c: Math.min(s.exit, s.entry) + 2 }
    ];
    for (const at of candidates) {
      if (flip) {
        if (at.c < 0)
          continue;
        const ok = Array.from({ length: len }, (_, i) => !blocked.has(at.a + i, at.c) && !grid.ownedByOther(edgeId, at.a + i, at.c)).every(Boolean);
        if (!ok)
          continue;
        for (let i = 0;i < len; i++)
          grid.erase(at.a + i, at.c);
        const { x, y } = point(true, at.a, at.c);
        return { x, y, text };
      }
      if (at.c < 1 || at.c + len > width + 20)
        continue;
      if (!free(at.a, at.c, len))
        continue;
      if (labels.some((l) => l.y === at.a && l.x < at.c + len && l.x + cellWidth(l.text) > at.c))
        continue;
      for (let i = 0;i < len; i++)
        grid.erase(at.a, at.c + i);
      return { x: at.c, y: at.a, text };
    }
    const at = candidates[0];
    let room = 0;
    while (room < len && (flip ? !blocked.has(at.a + room, at.c) && !grid.ownedByOther(edgeId, at.a + room, at.c) : !blocked.has(at.a, at.c + room) && !grid.ownedByOther(edgeId, at.a, at.c + room)))
      room++;
    const cut = truncateToWidth(text, Math.max(1, room));
    for (let i = 0;i < cellWidth(cut); i++)
      flip ? grid.erase(at.a + i, at.c) : grid.erase(at.a, at.c + i);
    const { x, y } = point(flip, at.a, at.c);
    return { x, y, text: cut };
  }
  var UP = 1;
  var DOWN = 2;
  var LEFT = 4;
  var RIGHT = 8;

  class Grid {
    cells = new Map;
    mark(owner, a, c, bit, style) {
      const key = `${a},${c}`;
      const cell = this.cells.get(key);
      if (!cell) {
        this.cells.set(key, { owner, mask: bit, style, crossing: false });
        return;
      }
      if (cell.owner !== owner)
        cell.crossing = true;
      cell.mask |= bit;
    }
    along(owner, c, a0, a1, style) {
      const [lo, hi] = a0 <= a1 ? [a0, a1] : [a1, a0];
      for (let a = lo;a <= hi; a++) {
        if (a < hi)
          this.mark(owner, a, c, DOWN, style);
        if (a > lo)
          this.mark(owner, a, c, UP, style);
      }
      if (lo === hi)
        this.mark(owner, lo, c, UP | DOWN, style);
    }
    cross(owner, a, c0, c1, style) {
      const [lo, hi] = c0 <= c1 ? [c0, c1] : [c1, c0];
      for (let c = lo;c <= hi; c++) {
        if (c < hi)
          this.mark(owner, a, c, RIGHT, style);
        if (c > lo)
          this.mark(owner, a, c, LEFT, style);
      }
    }
    arrow(owner, c, a, at) {
      const key = `${a},${c}`;
      const cell = this.cells.get(key) ?? { owner, mask: UP | DOWN, style: "solid", crossing: false };
      cell.arrow = at;
      this.cells.set(key, cell);
    }
    erase(a, c) {
      this.cells.delete(`${a},${c}`);
    }
    ownedByOther(owner, a, c) {
      const cell = this.cells.get(`${a},${c}`);
      return cell !== undefined && (cell.owner !== owner || cell.crossing);
    }
    runs(flip) {
      const byRow = new Map;
      for (const [key, cell] of this.cells) {
        const [a, c] = key.split(",").map(Number);
        const x = flip ? a : c;
        const y = flip ? c : a;
        (byRow.get(y) ?? byRow.set(y, []).get(y)).push({ x, glyph: glyphOf(cell, flip) });
      }
      const runs = [];
      for (const [y, cells] of byRow) {
        cells.sort((p, q) => p.x - q.x);
        let run;
        for (const cell of cells) {
          if (run && run.x + run.text.length === cell.x)
            run.text += cell.glyph;
          else
            runs.push(run = { x: cell.x, y, text: cell.glyph });
        }
      }
      return runs.sort((p, q) => p.y - q.y || p.x - q.x);
    }
  }
  function glyphOf(cell, flip) {
    if (cell.arrow === "end")
      return flip ? "►" : "▼";
    if (cell.arrow === "start")
      return flip ? "◄" : "▲";
    if (cell.crossing)
      return "┼";
    let mask = cell.mask;
    if (flip)
      mask = (cell.mask & UP ? LEFT : 0) | (cell.mask & DOWN ? RIGHT : 0) | (cell.mask & LEFT ? UP : 0) | (cell.mask & RIGHT ? DOWN : 0);
    const vertical = (mask & (UP | DOWN)) !== 0 && (mask & (LEFT | RIGHT)) === 0;
    const horizontal = (mask & (LEFT | RIGHT)) !== 0 && (mask & (UP | DOWN)) === 0;
    if (vertical)
      return cell.style === "dotted" ? "┆" : cell.style === "thick" ? "┃" : "│";
    if (horizontal)
      return cell.style === "dotted" ? "┄" : cell.style === "thick" ? "━" : "─";
    const table = {
      [DOWN | RIGHT]: "┌",
      [DOWN | LEFT]: "┐",
      [UP | RIGHT]: "└",
      [UP | LEFT]: "┘",
      [UP | DOWN | RIGHT]: "├",
      [UP | DOWN | LEFT]: "┤",
      [LEFT | RIGHT | DOWN]: "┬",
      [LEFT | RIGHT | UP]: "┴"
    };
    return table[mask] ?? "┼";
  }
  var MIRROR_Y = { "┌": "└", "└": "┌", "┐": "┘", "┘": "┐", "┬": "┴", "┴": "┬", "▼": "▲", "▲": "▼" };
  var MIRROR_X = { "┌": "┐", "┐": "┌", "└": "┘", "┘": "└", "├": "┤", "┤": "├", "►": "◄", "◄": "►" };
  function mirrorGlyphY(glyph) {
    return MIRROR_Y[glyph] ?? glyph;
  }
  function mirrorGlyphX(glyph) {
    return MIRROR_X[glyph] ?? glyph;
  }

  // mods/cs-mermaid/hooks/parse.ts
  var LIMITS = { nodes: 200, edges: 400, label: 60 };
  var SHAPES = [
    { open: "([", close: "])", shape: "stadium" },
    { open: "[[", close: "]]", shape: "subroutine" },
    { open: "[(", close: ")]", shape: "cylinder" },
    { open: "((", close: "))", shape: "circle" },
    { open: "(((", close: ")))", shape: "doublecircle" },
    { open: "{{", close: "}}", shape: "hexagon" },
    { open: "[/", close: "/]", shape: "parallelogram" },
    { open: "[\\", close: "\\]", shape: "parallelogram" },
    { open: "[/", close: "\\]", shape: "trapezoid" },
    { open: "[\\", close: "/]", shape: "trapezoid" },
    { open: "[", close: "]", shape: "rect" },
    { open: "(", close: ")", shape: "round" },
    { open: "{", close: "}", shape: "diamond" },
    { open: ">", close: "]", shape: "flag" }
  ].sort((p, q) => q.open.length - p.open.length);
  var ID_SOURCE = "[A-Za-z0-9_]+(?:[.-][A-Za-z0-9_]+)*";
  var ID = new RegExp(`^${ID_SOURCE}`);
  var IDS_SOURCE = `${ID_SOURCE}(?:,${ID_SOURCE})*`;
  var ARROW = /^(<)?(-{2,}|={2,}|-\.+-)(?:(>|o|x)|(?![-=.>ox]))/;
  function parse(source) {
    const statements = splitStatements(source);
    const first = statements.shift();
    if (first === undefined)
      return { error: "empty diagram" };
    const header = /^(?:graph|flowchart)(?:\s+(TD|TB|BT|LR|RL))?$/.exec(first);
    if (!header)
      return { error: `not a flowchart: "${first.slice(0, 40)}"` };
    const dir = header[1] === undefined || header[1] === "TB" ? "TD" : header[1];
    const nodes = new Map;
    const edges = [];
    const classes = new Map;
    const classOf = new Map;
    const styled = new Map;
    for (const statement of statements) {
      let match;
      if (/^(subgraph\b|end$)/.test(statement))
        return { error: "subgraphs are not supported" };
      if (/^(linkStyle|click|direction)\b/.test(statement))
        continue;
      if (match = new RegExp(`^classDef\\s+(${IDS_SOURCE})\\s+(.+)$`).exec(statement)) {
        for (const name of (match[1] ?? "").split(","))
          classes.set(name, readStyle(match[2] ?? ""));
        continue;
      }
      if (match = new RegExp(`^class\\s+(${IDS_SOURCE})\\s+(${ID_SOURCE})$`).exec(statement)) {
        for (const id of (match[1] ?? "").split(","))
          classOf.set(id, match[2] ?? "");
        continue;
      }
      if (match = new RegExp(`^style\\s+(${ID_SOURCE})\\s+(.+)$`).exec(statement)) {
        styled.set(match[1] ?? "", readStyle(match[2] ?? ""));
        continue;
      }
      const failure = readChain(statement, nodes, edges, classOf);
      if (failure)
        return { error: failure };
      if (nodes.size > LIMITS.nodes)
        return { error: `more than ${LIMITS.nodes} nodes` };
      if (edges.length > LIMITS.edges)
        return { error: `more than ${LIMITS.edges} edges` };
    }
    if (nodes.size === 0)
      return { error: "no nodes" };
    const fallback = classes.get("default");
    for (const node of nodes.values()) {
      const named = classOf.get(node.id);
      const style = { ...named ? classes.get(named) : fallback, ...styled.get(node.id) };
      if (Object.keys(style).length > 0)
        node.style = style;
    }
    return { dir, nodes: [...nodes.values()], edges };
  }
  function splitStatements(source) {
    const out = [];
    let current = "";
    let quote = false;
    let depth = 0;
    const lines = source.split(`
`);
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line.startsWith("%%"))
        continue;
      for (let i = 0;i < line.length; i++) {
        const ch = line[i] ?? "";
        if (!quote && ch === "%" && line[i + 1] === "%")
          break;
        if (ch === '"')
          quote = !quote;
        else if (!quote && (ch === "[" || ch === "(" || ch === "{"))
          depth++;
        else if (!quote && (ch === "]" || ch === ")" || ch === "}"))
          depth = Math.max(0, depth - 1);
        if (ch === ";" && !quote && depth === 0) {
          if (current.trim())
            out.push(current.trim());
          current = "";
          continue;
        }
        current += ch;
      }
      if (current.trim())
        out.push(current.trim());
      current = "";
      quote = false;
      depth = 0;
    }
    return out;
  }
  function readChain(statement, nodes, edges, classOf) {
    let rest = statement;
    let previous;
    let arrow;
    for (;; ) {
      const group = [];
      for (;; ) {
        const read = readNode(rest, nodes, classOf);
        if ("error" in read)
          return read.error;
        group.push(read.id);
        rest = read.rest.trimStart();
        if (!rest.startsWith("&"))
          break;
        rest = rest.slice(1).trimStart();
      }
      if (previous && arrow) {
        for (const from of previous) {
          for (const to of group) {
            if (from === to)
              return `self-loops are not supported ("${from}")`;
            edges.push({ id: edges.length, from, to, ...arrow });
          }
        }
      }
      previous = group;
      if (rest === "")
        return;
      const next = readArrow(rest);
      if ("error" in next)
        return next.error;
      arrow = next.arrow;
      rest = next.rest.trimStart();
      if (rest === "")
        return `dangling arrow in "${statement}"`;
    }
  }
  function readArrow(text) {
    const inline = /^(<)?(--|==|-\.)\s+([^-=.|][^|]*?)\s+(--|==|\.-)(?:(>|o|x)|(?![-=.>ox]))/.exec(text);
    let head = null;
    let label;
    let rest;
    let shaft;
    if (inline) {
      label = unquote(inline[3] ?? "");
      shaft = inline[2] ?? "--";
      head = inline;
      rest = text.slice(inline[0].length);
    } else {
      const plain = ARROW.exec(text);
      if (!plain)
        return { error: `expected an arrow at "${text.slice(0, 20)}"` };
      shaft = plain[2] ?? "--";
      head = plain;
      rest = text.slice(plain[0].length);
      const piped = /^\s*\|("[^"]*"|[^|]*)\|/.exec(rest);
      if (piped) {
        label = unquote(piped[1] ?? "");
        rest = rest.slice(piped[0].length);
      }
    }
    const tail = inline ? inline[5] : head[3];
    if (tail === "o" || tail === "x")
      return { error: `"${tail}" arrow ends are not supported` };
    if (label !== undefined && cellWidth(label) > LIMITS.label)
      return { error: `edge label longer than ${LIMITS.label} cells` };
    const style = shaft.startsWith("=") ? "thick" : shaft.includes(".") ? "dotted" : "solid";
    return { arrow: { style, headAtTo: tail === ">", headAtFrom: head[1] === "<", label: label || undefined }, rest };
  }
  function readNode(text, nodes, classOf) {
    const idMatch = ID.exec(text);
    if (!idMatch)
      return { error: `expected a node at "${text.slice(0, 20)}"` };
    const id = idMatch[0];
    let rest = text.slice(id.length);
    let label;
    let shape = "rect";
    const opener = SHAPES.find((one) => rest.startsWith(one.open));
    if (opener) {
      const candidates = SHAPES.filter((one) => one.open === opener.open);
      const body = readDelimited(rest, opener.open, candidates.map((one) => one.close));
      if ("error" in body)
        return body;
      label = body.text;
      shape = candidates.find((one) => one.close === body.close)?.shape ?? opener.shape;
      rest = body.rest;
    }
    const inlineClass = new RegExp(`^:::(${ID_SOURCE})`).exec(rest);
    if (inlineClass) {
      classOf.set(id, inlineClass[1] ?? "");
      rest = rest.slice(inlineClass[0].length);
    }
    if (label !== undefined) {
      const clean = label.trim().replace(/^"(.*)"$/s, "$1").replace(/<br\s*\/?>/gi, " ").trim();
      if (cellWidth(clean) > LIMITS.label)
        return { error: `node label longer than ${LIMITS.label} cells` };
      nodes.set(id, { id, label: clean || id, shape });
    } else if (!nodes.has(id)) {
      nodes.set(id, { id, label: id, shape: "rect" });
    }
    return { id, rest };
  }
  function readDelimited(text, open, closers) {
    let quote = false;
    const sorted = [...closers].sort((p, q) => q.length - p.length);
    for (let i = open.length;i < text.length; i++) {
      const ch = text[i];
      if (ch === '"') {
        quote = !quote;
        continue;
      }
      if (quote)
        continue;
      for (const close of sorted) {
        if (text.startsWith(close, i))
          return { text: text.slice(open.length, i), close, rest: text.slice(i + close.length) };
      }
    }
    return { error: `unclosed "${open}" in "${text.slice(0, 20)}"` };
  }
  function unquote(label) {
    return label.trim().replace(/^"(.*)"$/s, "$1").trim();
  }
  function readStyle(text) {
    const style = {};
    for (const part of text.split(/,(?![^()]*\))/)) {
      const [key, value] = part.split(":").map((piece) => piece.trim());
      if (!value)
        continue;
      if (key === "fill")
        style.fill = value;
      else if (key === "color")
        style.color = value;
    }
    return style;
  }

  // mods/cs-mermaid/hooks/register.tsx
  function fit(graph, columns) {
    const first = layout(graph);
    if ("error" in first)
      return first;
    if (first.width <= columns)
      return { drawn: first, graph, turned: false };
    if (graph.dir === "LR" || graph.dir === "RL") {
      const turned = layout({ ...graph, dir: graph.dir === "LR" ? "TD" : "BT" });
      if ("error" in turned)
        return turned;
      if (turned.width <= columns)
        return { drawn: turned, graph, turned: true };
      return { error: `diagram is ${turned.width} columns wide, the transcript ${columns}` };
    }
    return { error: `diagram is ${first.width} columns wide, the transcript ${columns}` };
  }
  var LIGHT = { fill: "#ECECFF", decision: "#FFF3BF", start: "#D3F9D8", end: "#E9ECEF", text: "#1F1F1F", line: "#333333", good: "#2B8A3E", bad: "#C92A2A" };
  var DARK = { fill: "#3B3F6B", decision: "#6B5A1E", start: "#1F4D2B", end: "#3A3D42", text: "#F2F2F2", line: "#D3D3D3", good: "#69DB7C", bad: "#FF8787" };
  function paletteFor(theme) {
    return typeof theme === "string" && theme.startsWith("dark") ? DARK : LIGHT;
  }
  function roleOf(node, graph) {
    if (node.shape === "diamond" || node.shape === "hexagon")
      return "decision";
    const outgoing = graph.edges.filter((edge) => edge.from === node.id).length;
    const incoming = graph.edges.filter((edge) => edge.to === node.id).length;
    if (node.shape === "circle" || node.shape === "doublecircle")
      return outgoing === 0 && incoming > 0 ? "end" : "start";
    if (outgoing >= 2)
      return "decision";
    if (outgoing === 0 && incoming > 0)
      return "end";
    if (incoming === 0 && outgoing > 0)
      return "start";
    return "step";
  }
  function fillFor(role, palette) {
    return role === "step" ? palette.fill : palette[role];
  }
  var GOOD = new Set(["yes", "y", "ok", "pass", "passed", "true", "healthy", "success", "done", "valid"]);
  var BAD = new Set(["no", "n", "fail", "failed", "false", "error", "degraded", "invalid", "timeout", "reject", "rejected"]);
  function labelColor(text, palette) {
    const word = text.trim().toLowerCase();
    if (GOOD.has(word))
      return palette.good;
    if (BAD.has(word))
      return palette.bad;
    return palette.line;
  }
  function blockRows(label, width, height) {
    const blank = " ".repeat(width);
    const inner = truncateToWidth(label, width);
    const left = Math.floor((width - cellWidth(inner)) / 2);
    const middle = padToWidth(" ".repeat(left) + inner, width);
    return Array.from({ length: height }, (_, i) => i === Math.floor(height / 2) ? middle : blank);
  }
  function Drawing({ drawn, graph, palette, elements }) {
    const { Box, Text } = elements;
    return /* @__PURE__ */ h(Box, {
      width: drawn.width,
      height: drawn.height,
      position: "relative"
    }, drawn.runs.map((run) => /* @__PURE__ */ h(Box, {
      position: "absolute",
      top: run.y,
      left: run.x
    }, /* @__PURE__ */ h(Text, {
      color: palette.line
    }, run.text))), drawn.boxes.map((box) => {
      const role = roleOf(box.node, graph);
      const fill = box.node.style?.fill ?? fillFor(role, palette);
      const text = box.node.style?.color ?? palette.text;
      return /* @__PURE__ */ h(Box, {
        position: "absolute",
        top: box.y,
        left: box.x,
        width: box.width,
        height: box.height,
        flexDirection: "column"
      }, blockRows(box.node.label, box.width, box.height).map((row) => /* @__PURE__ */ h(Text, {
        color: text,
        backgroundColor: fill,
        bold: role === "decision"
      }, row)));
    }), drawn.labels.map((label) => /* @__PURE__ */ h(Box, {
      position: "absolute",
      top: label.y,
      left: label.x
    }, /* @__PURE__ */ h(Text, {
      italic: true,
      color: labelColor(label.text, palette)
    }, label.text))));
  }
  function drawFence(source, error, elements) {
    const { Box, Text, Code } = elements;
    return /* @__PURE__ */ h(Box, {
      flexDirection: "column"
    }, /* @__PURE__ */ h(Code, {
      source,
      language: "mermaid"
    }), /* @__PURE__ */ h(Text, {
      dimColor: true
    }, "mermaid: ", error));
  }
  var FITTED_KEPT = 32;
  var fittedCache = new Map;
  function fitSource(source, columns) {
    const key = `${columns}
${source}`;
    const known = fittedCache.get(key);
    if (known)
      return known;
    const graph = parse(source);
    const fitted = "error" in graph ? graph : fit(graph, columns);
    fittedCache.set(key, fitted);
    if (fittedCache.size > FITTED_KEPT)
      fittedCache.delete(fittedCache.keys().next().value);
    return fitted;
  }

  // docs/surfaces/registry.ts
  function elements() {
    const el = globalThis.LabElements;
    if (el === undefined)
      throw new Error("the lab shim (docs/surfaces/shim.js) is not loaded: LabElements is undefined");
    return el;
  }

  // docs/surfaces/cs-mermaid.fixtures.ts
  function fence(source, cols, theme) {
    const el = elements();
    const fitted = fitSource(source, Math.max(20, cols - 6));
    if ("error" in fitted)
      return drawFence(source, fitted.error, el);
    return el.Box({ marginY: 1, children: [Drawing({ drawn: fitted.drawn, graph: fitted.graph, palette: paletteFor(theme), elements: el })] });
  }
  var state = (id, name, source) => ({ id, name, draw: (cols, theme) => fence(source, cols, theme) });
  var lines = (...rows) => rows.join(`
`);
  var surfaces = [{
    id: "cs-mermaid.AssistantMessage",
    mod: "cs-mermaid",
    slot: "AssistantMessage",
    source: "generated",
    global: "CsMermaidSurfaces",
    needs: ["position=absolute", "Code"],
    states: [
      state("diagram", "reading a flowchart drawn in the reply", lines("graph TD", "  A[Start] --> B{Tests pass?}", "  B -->|yes| C[Ship]", "  B -->|no| D[Fix]")),
      state("turned", "reading a left-to-right chart turned top-down to fit", lines("graph LR", "  A[Open the branch] --> B[Run the gate] --> C[Review the diff] --> D[Land it on main] --> E[Tag the release]")),
      state("node-roles", "reading a chart whose blocks say start, step, decision and end", lines("graph TD", "  S((start)) --> P[step]", "  P --> Q{decide}", "  Q --> E[end]", "  Q --> P")),
      state("edge-styles", "reading solid, dotted and thick edges with answer labels", lines("graph TD", "  A[ask] -->|yes| B[go]", "  A -.->|no| C[stop]", "  A ==> D[retry]")),
      state("refused", "reading a fence the mod cannot draw, and why", lines("graph TD", "  subgraph one", "    A --> B", "  end")),
      state("too-wide", "reading a chart too wide for the transcript", lines("graph TD", ...["build the docs", "run the tests", "lint the shell", "check the bundle", "sign the release", "tag the commit"].map((step, i) => `  A[release] --> N${i}[${step}]`)))
    ],
    parts: [
      { id: "node-block", name: "node block", state: "diagram", path: [0, 0] },
      { id: "source-fallback", name: "source fallback", state: "refused", path: [0] }
    ]
  }];

  // docs/surfaces/cs-mermaid.entry.ts
  globalThis.CsMermaidSurfaces = { surfaces };
})();
