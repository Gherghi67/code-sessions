// ABOUTME: Lays a mod band tree (Box / Text / Button) out into a grid of styled cells.
// ABOUTME: Loaded by docs/mods-design-lab.html as a plain script; exported for bun tests.
(function (root) {
  "use strict";

  // A cell is one terminal column: the character, the style it carries, and
  // the index path from the root to the node that drew it (a Box owns its
  // border, padding, gaps, margins and slack). `st` is shared between cells
  // of the same run, so never mutate one in place.
  var EMPTY = { color: "", bg: "", bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };

  function styleOf(props) {
    var p = props || {};
    return {
      color: p.color || "",
      bg: p.backgroundColor || "",
      bold: !!p.bold,
      dim: !!p.dimColor,
      italic: !!p.italic,
      underline: !!p.underline,
      strikethrough: !!p.strikethrough,
      inverse: !!p.inverse,
    };
  }

  var chars = function (s) { return Array.from(String(s)); };
  function run(s, st, path) { return chars(s).map(function (ch) { return { ch: ch, st: st, path: path, ink: true }; }); }
  function blanks(n, st, path) { var out = []; for (var i = 0; i < n; i++) out.push({ ch: " ", st: st || EMPTY, path: path }); return out; }

  // A truncated run no wider than `room`, by the Text wrap mode, its newlines
  // taking no cells: the 2.1.310 renderer cuts a Text that does not wrap
  // whole (o1), so the cut can fall past a newline and drops the lines after
  // it. A truncation mark inherits the style of the run it lands in. Below
  // one cell nothing is left.
  function truncate(cells, room, mode) {
    if (room < 1) return [];
    var shown = cells.filter(function (c) { return c.ch !== "\n"; });
    var dots = function (from) { return { ch: "…", st: from.st, path: from.path, ink: true }; };
    if (room === 1) return [dots(shown[0])];
    var head = function (n) { var out = [], seen = 0; for (var i = 0; i < cells.length && seen < n; i++) { out.push(cells[i]); if (cells[i].ch !== "\n") seen++; } return out; };
    var tail = function (n) { var out = [], seen = 0; for (var i = cells.length - 1; i >= 0 && seen < n; i--) { out.unshift(cells[i]); if (cells[i].ch !== "\n") seen++; } return out; };
    if (mode === "truncate-start") return [dots(shown[shown.length - room])].concat(tail(room - 1));
    if (mode === "middle" || mode === "truncate-middle") {
      var left = Math.floor((room - 1) / 2);
      return head(left).concat([dots(shown[left])], tail(room - 1 - left));
    }
    return head(room - 1).concat([dots(shown[room - 1])]);
  }

  // One line broken into rows no wider than `columns` as Bun.wrapAnsi breaks
  // it with hard on, the 2.1.310 wrap (wrap-ansi's rules): a word that does
  // not fit moves to a new row whole, one wider than a row breaks across rows,
  // the space between two words stays at the end of a row or starts the
  // next. `trim` drops the spaces each row starts and ends with.
  function wordRows(line, columns, trim) {
    if (trim && line.every(function (c) { return c.ch === " "; })) return [[]];
    var words = [[]], spaces = [];
    line.forEach(function (c) { if (c.ch === " ") { spaces.push(c); words.push([]); } else words[words.length - 1].push(c); });
    var rows = [[]];
    var last = function () { return rows[rows.length - 1]; };
    words.forEach(function (word, i) {
      if (trim) { var lead = 0; while (lead < last().length && last()[lead].ch === " ") lead++; rows[rows.length - 1] = last().slice(lead); }
      var used = last().length;
      if (i > 0) {
        if (used >= columns && !trim) { rows.push([]); used = 0; }
        if (used > 0 || !trim) { last().push(spaces[i - 1]); used++; }
      }
      if (word.length > columns) {
        var thisRow = 1 + Math.floor((word.length - (columns - used) - 1) / columns);
        var nextRow = Math.floor((word.length - 1) / columns);
        if (nextRow < thisRow) rows.push([]);
        var shown = last().length;
        word.forEach(function (c, k) {
          if (shown + 1 <= columns) last().push(c); else { rows.push([c]); shown = 0; }
          shown++;
          if (shown === columns && k < word.length - 1) { rows.push([]); shown = 0; }
        });
        return;
      }
      if (used + word.length > columns && used > 0 && word.length > 0) rows.push([]);
      rows[rows.length - 1] = last().concat(word);
    });
    if (trim) rows = rows.map(function (r) { var end = r.length; while (end > 0 && r[end - 1].ch === " ") end--; return r.slice(0, end); });
    return rows;
  }

  // A Text's rows in `room` cells, and the cells it measures, as the 2.1.310
  // terminal draws and measures it (gv and s1). A Text whose widest line fits
  // draws as written. A wrapping one is broken line by line; a row that
  // starts with the space carried over from the row above draws without it,
  // unless the space is all the row holds, but measures with it. Given no
  // cells it draws whole. Any other mode is cut once (`truncate`).
  function textRows(cells, room, mode) {
    var lines = [[]];
    cells.forEach(function (c) { if (c.ch === "\n") lines.push([]); else lines[lines.length - 1].push(c); });
    var widest = function (rows) { return rows.reduce(function (a, r) { return Math.max(a, r.length); }, 0); };
    var natural = widest(lines);
    var wraps = !mode || mode === "wrap" || mode === "wrap-trim";
    if (natural <= room || (wraps && room <= 0)) return { w: natural, rows: lines };
    if (!wraps) {
      var cut = truncate(cells, room, mode), rows = [[]];
      cut.forEach(function (c) { if (c.ch === "\n") rows.push([]); else rows[rows.length - 1].push(c); });
      return { w: widest(rows), rows: rows };
    }
    var measured = 0, drawn = [];
    lines.forEach(function (line) {
      wordRows(line, room, mode === "wrap-trim").forEach(function (r, i) {
        measured = Math.max(measured, r.length);
        drawn.push(i > 0 && r.length > 1 && r[0].ch === " " ? r.slice(1) : r);
      });
    });
    return { w: measured, rows: drawn };
  }

  // A Code node as 2.1.310's highlighter draws a language it has no grammar
  // for (mermaid, the one a mod draws): each line in the theme's plain code
  // ink, `codeForeground` (the page resolves it per theme), broken at the
  // width cell by cell, a trailing newline dropped. A language among its
  // grammars draws in scope colours the lab does not reproduce; no mod
  // surface hands it one.
  function codeRows(source, width, path) {
    var lines = source.split("\n");
    if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
    var ink = styleOf({ color: "codeForeground" }), room = Math.max(1, width), rows = [];
    lines.forEach(function (line) {
      var cells = run(line, ink, path);
      if (!cells.length) rows.push([]);
      for (var i = 0; i < cells.length; i += room) rows.push(cells.slice(i, i + room));
    });
    return { w: rows.reduce(function (a, r) { return Math.max(a, r.length); }, 0), rows: rows };
  }

  // A Markdown text as one inline run, as the 2.1.310 renderer styles it:
  // **strong** bold, *em* or _em_ italic, `code` in the theme's permission
  // ink, the marks dropped. Blocks (headings, lists, fences) draw as text.
  var MD_INLINE = /(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*|_[^_\s][^_]*_)/;
  function markdownCells(text, path) {
    return text.split(MD_INLINE).reduce(function (cells, piece, i) {
      if (i % 2 === 0) return cells.concat(run(piece, EMPTY, path));
      if (piece.indexOf("**") === 0) return cells.concat(run(piece.slice(2, -2), styleOf({ bold: true }), path));
      if (piece.charAt(0) === "`") return cells.concat(run(piece.slice(1, -1), styleOf({ color: "permission" }), path));
      return cells.concat(run(piece.slice(1, -1), styleOf({ italic: true }), path));
    }, []);
  }

  // A Text child of a Text is an inline run: it inherits what it does not set.
  function mergeStyle(parent, props) {
    var p = props || {}, st = {};
    st.color = p.color || parent.color;
    st.bg = p.backgroundColor || parent.bg;
    st.bold = p.bold === undefined ? parent.bold : !!p.bold;
    st.dim = p.dimColor === undefined ? parent.dim : !!p.dimColor;
    st.italic = p.italic === undefined ? parent.italic : !!p.italic;
    st.underline = p.underline === undefined ? parent.underline : !!p.underline;
    st.strikethrough = p.strikethrough === undefined ? parent.strikethrough : !!p.strikethrough;
    st.inverse = p.inverse === undefined ? parent.inverse : !!p.inverse;
    return st;
  }

  function textCells(node, inherited, path) {
    var st = mergeStyle(inherited || EMPTY, node.props);
    var cells = [];
    (node.children || []).forEach(function (kid, i) {
      if (kid == null || kid === false) return;
      if (typeof kid === "string" || typeof kid === "number") cells = cells.concat(run(kid, st, path));
      else if (kid.type === "Text") cells = cells.concat(textCells(kid, st, path.concat([i])));
    });
    return cells;
  }

  function grid(rows) {
    var w = rows.reduce(function (a, r) { return Math.max(a, r.length); }, 0);
    return { w: w, h: rows.length, rows: rows };
  }
  // A Text's grid: the cells it measures, which can be more than its widest
  // drawn row (`textRows`).
  function textGrid(t) { return { w: t.w, h: t.rows.length, rows: t.rows }; }

  var BORDERS = {
    single: { tl: "\u250c", t: "\u2500", tr: "\u2510", r: "\u2502", br: "\u2518", b: "\u2500", bl: "\u2514", l: "\u2502" },
    double: { tl: "\u2554", t: "\u2550", tr: "\u2557", r: "\u2551", br: "\u255d", b: "\u2550", bl: "\u255a", l: "\u2551" },
    round: { tl: "\u256d", t: "\u2500", tr: "\u256e", r: "\u2502", br: "\u256f", b: "\u2500", bl: "\u2570", l: "\u2502" },
    bold: { tl: "\u250f", t: "\u2501", tr: "\u2513", r: "\u2503", br: "\u251b", b: "\u2501", bl: "\u2517", l: "\u2503" },
    singleDouble: { tl: "\u2553", t: "\u2500", tr: "\u2556", r: "\u2551", br: "\u255c", b: "\u2500", bl: "\u2559", l: "\u2551" },
    doubleSingle: { tl: "\u2552", t: "\u2550", tr: "\u2555", r: "\u2502", br: "\u255b", b: "\u2550", bl: "\u2558", l: "\u2502" },
    classic: { tl: "+", t: "-", tr: "+", r: "|", br: "+", b: "-", bl: "+", l: "|" },
    arrow: { tl: "\u2198", t: "\u2193", tr: "\u2199", r: "\u2190", br: "\u2196", b: "\u2191", bl: "\u2197", l: "\u2192" },
  };

  function padRow(row, w, st, path) { return row.length >= w ? row.slice(0, w) : row.concat(blanks(w - row.length, st, path)); }
  function num(v) { return typeof v === "number" ? v : 0; }
  // padding / margin: the side spelling wins over the axis, the axis over the whole.
  function edge(p, side, axis) {
    var v = p[side];
    if (typeof v !== "number") v = p[axis];
    if (typeof v !== "number") v = p.padding !== undefined && side.indexOf("padding") === 0 ? p.padding : p.margin;
    return num(v);
  }
  function pads(p) {
    return {
      l: edge(p, "paddingLeft", "paddingX"), r: edge(p, "paddingRight", "paddingX"),
      t: edge(p, "paddingTop", "paddingY"), b: edge(p, "paddingBottom", "paddingY"),
    };
  }
  function margins(p) {
    return {
      l: edge(p, "marginLeft", "marginX"), r: edge(p, "marginRight", "marginX"),
      t: edge(p, "marginTop", "marginY"), b: edge(p, "marginBottom", "marginY"),
    };
  }

  // `fill`: the node takes exactly `availWidth` (Yoga's stretch, or the size
  // a row's flex gave it), as the root does in the terminal and a Box does in
  // a column, and draws past it what does not fit; without it the node is
  // measured in at most `availWidth`, as Yoga measures a flex basis.
  function layout(node, availWidth, at, fill) {
    var width = Math.max(0, availWidth == null ? 80 : availWidth);
    var path = at || [];
    if (!node) return grid([]);
    if (node.type === "Button") return layoutButton(node, width, path);
    if (node.type === "Box") return layoutBox(node, width, path, !!fill);
    var text = null;
    if (node.type === "Text") text = textRows(textCells(node, EMPTY, path), width, (node.props || {}).wrap);
    if (node.type === "Markdown") text = textRows(markdownCells(String((node.props || {}).text || ""), path), width);
    if (node.type === "Code") text = codeRows(String((node.props || {}).source || ""), width, path);
    if (!text) return grid([]);
    var g = textGrid(text);
    if (fill) g.w = width;
    return g;
  }
  // The tree as the terminal draws it in a row `width` cells wide.
  function layoutScreen(node, width) { return layout(node, width, [], true); }

  // A pane's body framed as the 2.1.310 terminal frames an inline pane that is
  // not focused: a round dim border, one cell of padding each side, a tab per
  // open pane (`titles`, the shown one `title` bold, the rest dim) only when
  // two or more are open, the body clipped to what `rows` leaves, and the dim
  // close mark on the top border two cells in from the right. The frame's
  // cells name the root, so a press on it lands on the body's root.
  function layoutPane(node, o) {
    var inner = Math.max(0, o.columns - 4), path = [];
    var dim = styleOf({ dimColor: true });
    var tabs = o.titles.length > 1;
    var body = layoutScreen(node, inner).rows.slice(0, Math.max(0, o.rows - 2 - (tabs ? 1 : 0)));
    if (tabs) {
      var row = [];
      o.titles.forEach(function (t, i) {
        if (i) row = row.concat(blanks(1, EMPTY, path));
        row = row.concat(run(t, styleOf(t === o.title ? { bold: true } : { dimColor: true }), path));
      });
      body.unshift(row);
    }
    var top = run("\u256d" + repeat("\u2500", inner + 2) + "\u256e", dim, path);
    if (o.columns >= 4) top[o.columns - 3] = { ch: "\u2715", st: dim, path: path };
    var rows = [top].concat(body.map(function (r) {
      return [{ ch: "\u2502", st: dim, path: path }].concat(blanks(1, EMPTY, path), padRow(r, inner, EMPTY, path), blanks(1, EMPTY, path), [{ ch: "\u2502", st: dim, path: path }]);
    }), [run("\u2570" + repeat("\u2500", inner + 2) + "\u256f", dim, path)]);
    return grid(rows);
  }

  // A Button as the 2.1.310 terminal draws it: a plain one is its hotkey in
  // suggestion, `: `, then its label, or the label alone with no hotkey; any
  // other is `[ label ]` bold, in suggestion for variant primary, and never
  // shows its hotkey. Children, when there are any, draw in the label's place
  // as inline runs (strings and Text), inside the brackets. The engine reads
  // no colour or bold of a Button's own. It draws the Button as one Text of
  // the default wrap, so a label wider than the room wraps in it.
  function layoutButton(node, width, path) {
    var p = node.props || {};
    var st = styleOf(p.plain ? { dimColor: p.dimColor } : { dimColor: p.dimColor, bold: true, color: p.variant === "primary" ? "suggestion" : "" });
    var drawn = (node.children || []).some(function (k) { return k != null && k !== false && k !== ""; });
    var body = drawn ? textCells({ props: {}, children: node.children }, st, path) : run(p.label == null ? "" : String(p.label), st, path);
    var cells;
    if (!p.plain) cells = run("[ ", st, path).concat(body, run(" ]", st, path));
    else if (p.hotkey) cells = run(String(p.hotkey), mergeStyle(st, { color: "suggestion" }), path).concat(run(": ", st, path), body);
    else cells = body;
    return textGrid(textRows(cells, width, "wrap"));
  }

  function layoutBox(node, width, path, fill) {
    var p = node.props || {};
    if (p.display === "none") return grid([]);
    var m = margins(p), pd = pads(p);
    var border = p.borderStyle && BORDERS[p.borderStyle] ? p.borderStyle : "";
    var edge = border ? 1 : 0;
    var edgeSt = { color: p.borderColor || "", bg: "", bold: false, dim: !!p.borderDimColor, italic: false, underline: false, strikethrough: false, inverse: false };
    var fillSt = { color: "", bg: p.backgroundColor || "", bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };

    var chrome = 2 * edge + pd.l + pd.r;
    var outer = typeof p.width === "number" ? p.width : 0;
    // Room the children get: an explicit width fixes it, else what is left of
    // the band after this Box's own margins and chrome.
    var inner = outer ? Math.max(0, outer - chrome) : Math.max(0, width - m.l - m.r - chrome);
    // The fewest cells a stretched Box's content takes: all it was given.
    var least = !outer && fill ? inner : 0;

    var gap = num(p.gap);
    var dir = String(p.flexDirection || "row");
    var column = dir.indexOf("column") === 0;
    var reverse = /-reverse$/.test(dir);

    // Every child is measured in at most the inner room, its flex basis; a row
    // then grows or shrinks them to fit (`placeRow`).
    // A child's path keeps its index among all the children, falsy ones too.
    // An absolute child takes no room in the flow (`placeAbsolute`).
    var blocks = [], loose = [];
    (node.children || []).forEach(function (kid, i) {
      if (!kid) return;
      if ((kid.props || {}).position === "absolute") loose.push({ node: kid, at: path.concat([i]), i: i });
      else blocks.push({ node: kid, g: layout(kid, inner, path.concat([i])), at: path.concat([i]), i: i });
    });
    if (reverse) blocks.reverse();
    // A column stretches each Box it holds that sets no width of its own to
    // the column's width, unless the column aligns its items otherwise.
    if (column && (p.alignItems === undefined || p.alignItems === "stretch")) {
      var colWidth = outer ? inner : Math.max(least, blocks.reduce(function (a, b) { return Math.max(a, b.g.w); }, 0));
      blocks.forEach(function (b) { if (b.node.type === "Box" && typeof (b.node.props || {}).width !== "number") b.g = layout(b.node, colWidth, b.at, true); });
    }

    var body = column ? placeColumn(blocks, inner, gap, p, outer, least) : placeRow(blocks, inner, gap, p, outer, least);

    // An explicit width, or a width the Box was handed whole, is the Box's
    // width: what its children draw past it spills over its edge.
    var w = outer || fill ? inner : body.w;
    // Height: an explicit height pads or (with overflow hidden) clips the body.
    var h = body.h;
    if (typeof p.height === "number") {
      var room = Math.max(0, p.height - 2 * edge - pd.t - pd.b);
      h = body.h > room && p.overflow === "hidden" ? room : Math.max(room, body.h);
    }

    // The Box's own cells: its margins, then its border, then the padding and
    // body its background fills; its children are painted over them in the
    // order the mod wrote them. Overflow hidden cuts them at the body's edge.
    var x0 = m.l + edge + pd.l, y0 = m.t + edge + pd.t;
    var iw = w + pd.l + pd.r, ih = h + pd.t + pd.b;
    var W = m.l + 2 * edge + iw + m.r, H = m.t + 2 * edge + ih + m.b;
    if (!H) return { w: outer ? outer + m.l + m.r : 0, h: 0, rows: [] };
    var canvas = [];
    for (var y = 0; y < H; y++) {
      var inside = y >= m.t + edge && y < m.t + edge + ih;
      canvas.push(blanks(m.l + edge, EMPTY, path).concat(blanks(iw, inside ? fillSt : EMPTY, path), blanks(edge + m.r, EMPTY, path)));
    }
    if (border) {
      var g = BORDERS[border];
      canvas[m.t] = blanks(m.l, EMPTY, path).concat(run(g.tl + repeat(g.t, iw) + g.tr, edgeSt, path), blanks(m.r, EMPTY, path));
      canvas[m.t + 1 + ih] = blanks(m.l, EMPTY, path).concat(run(g.bl + repeat(g.b, iw) + g.br, edgeSt, path), blanks(m.r, EMPTY, path));
      for (var r = m.t + 1; r <= m.t + ih; r++) { canvas[r][m.l] = { ch: g.l, st: edgeSt, path: path, ink: true }; canvas[r][m.l + 1 + iw] = { ch: g.r, st: edgeSt, path: path, ink: true }; }
    }
    var cut = { right: p.overflow === "hidden" ? x0 + w : Infinity, bottom: y0 + h };
    var spots = body.spots.map(function (s, k) { return { g: s.g, x: x0 + s.x, y: y0 + s.y, i: blocks[k].i }; });
    var box = { x: m.l, y: m.t, w: 2 * edge + iw, h: 2 * edge + ih, edge: edge, pd: pd, column: column, p: p };
    loose.forEach(function (a) { spots.push(placeAbsolute(a, box)); });
    spots.sort(function (a, b) { return a.i - b.i; }).forEach(function (s) { paint(canvas, s.g, s.x, s.y, cut, path); });
    // The background sits under everything the Box holds: every cell a child
    // drew without a background of its own takes it, as the padding does.
    if (p.backgroundColor) for (var by = m.t + edge; by < m.t + edge + ih; by++) {
      canvas[by] = canvas[by].slice(0, m.l + edge).concat(underpaint(canvas[by].slice(m.l + edge, m.l + edge + iw), p.backgroundColor), canvas[by].slice(m.l + edge + iw));
    }
    return { w: W, h: H, rows: canvas };
  }

  // An absolute child as 2.1.310 places it (Rx), apart from the flow: its own
  // width, or what its left and right leave of the Box inside the border,
  // else its content's, unbounded; the same down the column. It sits at its
  // left (or its right) and its top (or its bottom) counted from inside the
  // border, the padding not counted, or, given neither, where the Box's
  // justifyContent (along a row) or alignItems (across it) would put it.
  // `box` is the parent's border box on its canvas.
  function placeAbsolute(a, box) {
    var q = a.node.props || {}, km = margins(q), e = box.edge;
    var size = function (own, from, to, room) { return typeof own === "number" ? own : typeof from === "number" && typeof to === "number" ? Math.max(0, room - from - to) : null; };
    var w = size(q.width, q.left, q.right, box.w - 2 * e), h = size(q.height, q.top, q.bottom, box.h - 2 * e);
    var props = Object.assign({}, q, w === null ? {} : { width: w }, h === null ? {} : { height: h });
    var g = layout({ type: a.node.type, props: props, children: a.node.children }, w === null ? UNBOUNDED : w + km.l + km.r, a.at, w !== null);
    var at = function (lead, trail, extent, span, pad0, pad1, align) {
      if (typeof lead === "number") return e + lead;
      if (typeof trail === "number") return extent - e - trail - span;
      var from = e + pad0, to = extent - e - pad1;
      return align === "center" ? Math.round(from + (to - from - span) / 2) : align === "flex-end" ? to - span : from;
    };
    var rowAlign = box.column ? box.p.alignItems : box.p.justifyContent, colAlign = box.column ? box.p.justifyContent : box.p.alignItems;
    return {
      g: g, i: a.i,
      x: box.x + at(q.left, q.right, box.w, g.w, box.pd.l, box.pd.r, rowAlign),
      y: box.y + at(q.top, q.bottom, box.h, g.h, box.pd.t, box.pd.b, colAlign),
    };
  }
  // The room an absolute child of no width of its own is measured in: its
  // content's, whatever it is.
  var UNBOUNDED = 1e6;

  // A cell a node drew (text, a border, a background) always lands; a cell a
  // Box only keeps room with (padding, gaps, margins, slack) lands only where
  // nothing has been drawn, so a later sibling's room never erases what an
  // earlier one drew past its own cells.
  function inked(c) { return !!(c.ink || (c.st && c.st.bg)); }
  // What lands past the canvas's edge widens its row, the gap kept by the
  // Box at `path`.
  function paint(canvas, g, x, y, cut, path) {
    g.rows.forEach(function (r, dy) {
      var row = canvas[y + dy];
      if (!row || y + dy >= cut.bottom) return;
      r.forEach(function (c, dx) {
        var at = x + dx;
        if (at >= cut.right) return;
        while (row.length < at) row.push({ ch: " ", st: EMPTY, path: path });
        if (at >= row.length || inked(c) || !inked(row[at])) row[at] = c;
      });
    });
  }

  function underpaint(row, bg) {
    return row.map(function (c) {
      if (c.st && c.st.bg) return c;
      var st = {}; for (var k in (c.st || EMPTY)) st[k] = (c.st || EMPTY)[k];
      st.bg = bg;
      return { ch: c.ch, st: st, path: c.path, ink: c.ink };
    });
  }

  function repeat(ch, n) { var s = ""; for (var i = 0; i < n; i++) s += ch; return s; }

  // Spread `free` cells between children by justifyContent. Returns the lead
  // pad and the pad between each pair.
  function spread(just, free, n) {
    if (n < 1 || free <= 0) return { lead: 0, between: 0, tail: Math.max(0, free) };
    if (just === "center") return { lead: Math.floor(free / 2), between: 0, tail: free - Math.floor(free / 2) };
    if (just === "flex-end") return { lead: free, between: 0, tail: 0 };
    if (n > 1 && just === "space-between") { var b = Math.floor(free / (n - 1)); return { lead: 0, between: b, tail: free - b * (n - 1) }; }
    if (just === "space-around") { var a = Math.floor(free / n); return { lead: Math.floor(a / 2), between: a, tail: free - a * (n - 1) - Math.floor(a / 2) }; }
    if (just === "space-evenly") { var e = Math.floor(free / (n + 1)); return { lead: e, between: e, tail: free - e * n }; }
    return { lead: 0, between: 0, tail: free };
  }

  // Where a child of `size` cells sits in `room` cells by an align value.
  function alignAt(align, size, room) {
    var slack = Math.max(0, room - size);
    return align === "center" ? Math.floor(slack / 2) : align === "flex-end" ? slack : 0;
  }

  // The main sizes Yoga gives a row's children (2.1.310's wx): `free` cells
  // shared out by flexGrow, or, when they overrun the row, taken off each in
  // proportion to its flexShrink times its basis; a child whose factor is 0
  // keeps its basis, and one the share would take below 0 stops there while
  // the rest share again. The sizes are rounded on their running sum, so they
  // add up to what the row has.
  function flexSizes(items, free) {
    var n = items.length;
    var frozen = items.map(function (it) { return free >= 0 ? it.grow === 0 : it.shrink === 0; });
    var size = items.map(function (it) { return it.basis; });
    for (var pass = 0; pass <= n; pass++) {
      var left = free, grow = 0, weight = 0, factors = 0, live = 0;
      items.forEach(function (it, i) {
        if (frozen[i]) left -= size[i] - it.basis;
        else { grow += it.grow; weight += it.shrink * it.basis; factors += it.shrink; live++; }
      });
      if (!live) break;
      if (left > 0 && grow > 0 && grow < 1) left = Math.min(left, free * grow);
      else if (left < 0 && weight > 0 && factors < 1) left = Math.max(left, free * factors);
      var lost = 0, target = [];
      items.forEach(function (it, i) {
        if (frozen[i]) return;
        var t = it.basis;
        if (left > 0 && grow > 0) t += left * it.grow / grow;
        else if (left < 0 && weight > 0) t += left * it.shrink * it.basis / weight;
        target[i] = t;
        size[i] = Math.max(0, t);
        lost += size[i] - t;
      });
      if (lost === 0) break;
      var stopped = false;
      items.forEach(function (it, i) { if (!frozen[i] && (size[i] - target[i]) * lost > 0) { frozen[i] = true; stopped = true; } });
      if (!stopped) break;
    }
    var sum = 0, edge = 0;
    return size.map(function (v) { sum += v; var next = (sum + 0.5) | 0, out = next - edge; edge = next; return out; });
  }

  // A child's own margin cells along a row, which its grid carries.
  function marginX(node) { if (node.type !== "Box") return 0; var m = margins(node.props || {}); return m.l + m.r; }

  // Each child's place in a row Box's body, and the body's size. A row that
  // is handed its width (`outer`, or `least` when stretched) grows its
  // children into the slack; any row whose children overrun the room shrinks
  // them; each child whose size moved is laid out again at exactly that size.
  // A Button never shrinks or grows: the engine draws it in a Box of
  // flexShrink 0 and no flexGrow.
  function placeRow(blocks, inner, gap, p, outer, least) {
    var items = blocks.map(function (b) {
      var q = b.node.props || {}, button = b.node.type === "Button", mx = marginX(b.node);
      return { basis: b.g.w - mx, margin: mx, grow: button ? 0 : num(q.flexGrow), shrink: button ? 0 : typeof q.flexShrink === "number" ? q.flexShrink : 1 };
    });
    var content = items.reduce(function (a, it) { return a + it.basis + it.margin; }, 0) + gap * Math.max(0, blocks.length - 1);
    var room = outer ? inner : Math.max(least, Math.min(content, inner));
    var sizes = flexSizes(items, room - content);
    // A width the Box sets is only its basis: the size the row gives it wins.
    var placed = blocks.map(function (b, i) {
      if (sizes[i] === items[i].basis) return b.g;
      var sized = b.node.type === "Box" ? { type: "Box", props: Object.assign({}, b.node.props, { width: sizes[i] }), children: b.node.children } : b.node;
      return layout(sized, sizes[i] + items[i].margin, b.at, true);
    });
    var used = placed.reduce(function (a, g) { return a + g.w; }, 0) + gap * Math.max(0, blocks.length - 1);
    var s = spread(p.justifyContent, room - used, blocks.length);
    var h = placed.reduce(function (a, g) { return Math.max(a, g.h); }, 0) || (blocks.length ? 1 : 0);

    var x = s.lead, spots = [];
    placed.forEach(function (g, i) {
      if (i) x += gap + s.between;
      spots.push({ g: g, x: x, y: alignAt(p.alignItems, g.h, h) });
      x += g.w;
    });
    return { w: outer ? inner : Math.max(room, x), h: h, spots: spots };
  }

  // Each child's place in a column Box's body, and the body's size.
  function placeColumn(blocks, inner, gap, p, outer, least) {
    var natural = blocks.reduce(function (a, b) { return Math.max(a, b.g.w); }, 0);
    var w = outer ? inner : Math.max(least, natural);
    var y = 0, spots = [];
    blocks.forEach(function (b, i) {
      if (i) y += gap;
      spots.push({ g: b.g, x: alignAt(p.alignItems, b.g.w, w), y: y });
      y += b.g.h;
    });
    return { w: w, h: y, spots: spots };
  }

  // Plain text of each row, for tests and for the copy-as-text button.
  function toText(g) {
    return g.rows.map(function (r) { return r.map(function (c) { return c.ch; }).join(""); });
  }

  // ---- JSX ----
  // The order props are spelled in, so two trees that differ only in the order
  // the editor set them print the same.
  // The order the shipped mod spells them in (mods/cs/hooks/register.tsx):
  // layout, then the frame, then the ink, then what a Button is.
  var PROP_ORDER = ["key", "flexDirection", "justifyContent", "alignItems", "flexWrap", "flexGrow", "gap",
    "width", "height",
    "borderStyle", "borderColor", "borderDimColor",
    "padding", "paddingX", "paddingY", "paddingTop", "paddingBottom", "paddingLeft", "paddingRight",
    "margin", "marginX", "marginY", "marginTop", "marginBottom", "marginLeft", "marginRight",
    "backgroundColor", "overflow", "display",
    "hotkey", "action", "plain", "label",
    "color", "bold", "dimColor", "italic", "underline", "strikethrough", "inverse", "wrap", "autoFocus", "hover"];

  // A palette key is a string the engine resolves ("claude"); an ALL_CAPS name
  // is one of the mod's own consts, so it is braced.
  function colorExpr(v) { return /^[A-Z][A-Z0-9_]*$/.test(String(v)) ? "{" + v + "}" : JSON.stringify(String(v)); }

  function propText(name, v) {
    if (v === undefined || v === null || v === false || v === "") return "";
    if (v === true) return name;
    if (typeof v === "number") return name + "={" + v + "}";
    if (name === "hover") {
      var inner = Object.keys(v).map(function (k) {
        return k + ": " + (k === "scope" ? JSON.stringify(v[k]) : typeof v[k] === "boolean" || typeof v[k] === "number" ? v[k] : colorExpr(v[k]).replace(/[{}]/g, ""));
      }).join(", ");
      return inner ? "hover={{ " + inner + " }}" : "";
    }
    if (name === "color" || name === "borderColor" || name === "backgroundColor") return name + "=" + colorExpr(v);
    return stringProp(name, String(v));
  }

  function attrs(props) {
    var p = props || {};
    var seen = {};
    var out = PROP_ORDER.map(function (k) { seen[k] = true; return propText(k, p[k]); }).filter(Boolean);
    Object.keys(p).forEach(function (k) { if (!seen[k]) { var t = propText(k, p[k]); if (t) out.push(t); } });
    return out.length ? " " + out.join(" ") : "";
  }

  // A single-quoted JS string the person can paste: quote and backslash
  // escaped, anything outside printable ASCII (marks, meters, non-breaking
  // spaces, astral characters) spelled as a code point escape.
  function jsString(s) {
    return "'" + Array.from(s).map(function (ch) {
      var c = ch.codePointAt(0);
      if (c > 0xffff) return "\\u{" + c.toString(16) + "}";
      if (c < 0x20 || c > 0x7e) return "\\u" + ("000" + c.toString(16)).slice(-4);
      if (ch === "'" || ch === "\\") return "\\" + ch;
      return ch;
    }).join("") + "'";
  }

  // Text children: printable ASCII stands bare unless JSX would read part of
  // it as markup (`<`, `>`, `{`, `}`) or decode it as an entity (`&`);
  // everything else is a braced string.
  function textLiteral(s) {
    if (/^[\x20-\x7e]*$/.test(s) && !/[<>{}&]/.test(s)) return s;
    return "{" + jsString(s) + "}";
  }

  // A string prop: a JSX attribute string has no escapes and decodes entities,
  // so only printable ASCII without `"`, `&` or `\` stands quoted; anything
  // else is a braced string.
  function stringProp(name, s) {
    if (/^[\x20-\x7e]*$/.test(s) && !/["&\\]/.test(s)) return name + "=\"" + s + "\"";
    return name + "={" + jsString(s) + "}";
  }

  // A Text's or a Button's children on one line: strings as literals, Text as tags.
  function inline(node) {
    var kids = (node.children || []).filter(function (k) { return k !== null && k !== undefined && k !== false; });
    return kids.map(function (k) {
      return typeof k === "string" || typeof k === "number" ? textLiteral(String(k)) : toJsx(k, "");
    }).join("");
  }

  function toJsx(node, indent) {
    var pad = indent || "";
    if (!node) return "";
    if (node.type === "Button") {
      var drawn = inline(node);
      return pad + "<Button" + attrs(node.props) + " onPress={press}" + (drawn ? ">" + drawn + "</Button>" : " />");
    }
    if (node.type === "Text") return pad + "<Text" + attrs(node.props) + ">" + inline(node) + "</Text>";
    if (node.type === "Box") {
      var kidsB = (node.children || []).filter(Boolean);
      var open = pad + "<Box" + attrs(node.props) + ">";
      if (!kidsB.length) return pad + "<Box" + attrs(node.props) + " />";
      return [open].concat(kidsB.map(function (k) { return toJsx(k, pad + "  "); }), pad + "</Box>").join("\n");
    }
    if (node.type === "Markdown" || node.type === "Code") return pad + "<" + node.type + attrs(node.props) + " />";
    return "";
  }

  // What the engine refuses. It drops a bad tree silently and the fake engine
  // stays green, so the editor refuses the nest rather than letting it ship.
  function validate(node, out) {
    out = out || [];
    if (!node || typeof node !== "object") return out;
    var p = node.props || {};
    if (node.type === "Text") {
      (node.children || []).forEach(function (kid) {
        if (kid && typeof kid === "object" && kid.type !== "Text") {
          out.push("A " + kid.type + " inside a Text: the engine drops the whole tree.");
        }
      });
    }
    if (p.hover && !p.key && !(p.hover && p.hover.scope)) {
      out.push("hover on a " + node.type + " needs a key or a hover.scope.");
    }
    (node.children || []).forEach(function (kid) { if (kid && typeof kid === "object") validate(kid, out); });
    return out;
  }

  var api = { layout: layout, layoutScreen: layoutScreen, layoutPane: layoutPane, toText: toText, validate: validate, toJsx: toJsx, BORDERS: BORDERS, EMPTY: EMPTY, blanks: blanks };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.ModLayout = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
