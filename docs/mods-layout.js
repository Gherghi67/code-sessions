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
  function run(s, st, path) { return chars(s).map(function (ch) { return { ch: ch, st: st, path: path }; }); }
  function blanks(n, st, path) { var out = []; for (var i = 0; i < n; i++) out.push({ ch: " ", st: st || EMPTY, path: path }); return out; }

  // Break `cells` into rows no wider than `room`, by the Text wrap mode. A
  // truncation mark inherits the style of the run it lands in.
  function wrapCells(cells, room, mode) {
    if (room <= 0) return [[]];
    var dots = function (i) { var from = cells[i] || cells[cells.length - 1]; return { ch: "\u2026", st: from.st, path: from.path }; };
    if (!mode || mode === "wrap") {
      var out = [];
      for (var i = 0; i < cells.length; i += room) out.push(cells.slice(i, i + room));
      return out.length ? out : [[]];
    }
    if (cells.length <= room) return [cells];
    if (mode === "truncate-start") return [[dots(cells.length - room)].concat(cells.slice(cells.length - room + 1))];
    if (mode === "middle" || mode === "truncate-middle") {
      var head = Math.floor((room - 1) / 2);
      return [cells.slice(0, head).concat([dots(head)], cells.slice(cells.length - (room - 1 - head)))];
    }
    return [cells.slice(0, room - 1).concat([dots(room - 1)])];
  }

  // A Text's rows: broken at each newline, then each line wrapped to `room`.
  function textRows(cells, room, mode) {
    var lines = [[]];
    cells.forEach(function (c) { if (c.ch === "\n") lines.push([]); else lines[lines.length - 1].push(c); });
    return lines.reduce(function (rows, line) { return rows.concat(wrapCells(line, room, mode)); }, []);
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

  // `fill`: the Box takes all of `availWidth` (Yoga's stretch), as the root
  // does in the terminal and a Box does in a column; without it the tree is
  // measured at its natural width.
  function layout(node, availWidth, at, fill) {
    var width = Math.max(0, availWidth == null ? 80 : availWidth);
    var path = at || [];
    if (!node) return grid([]);
    if (node.type === "Text") return grid(textRows(textCells(node, EMPTY, path), width, (node.props || {}).wrap));
    if (node.type === "Button") return layoutButton(node, width, path);
    if (node.type === "Box") return layoutBox(node, width, path, !!fill);
    if (node.type === "Markdown") return grid(textRows(markdownCells(String((node.props || {}).text || ""), path), width));
    return grid([]);
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
  // no colour or bold of a Button's own.
  function layoutButton(node, width, path) {
    var p = node.props || {};
    var st = styleOf(p.plain ? { dimColor: p.dimColor } : { dimColor: p.dimColor, bold: true, color: p.variant === "primary" ? "suggestion" : "" });
    var drawn = (node.children || []).some(function (k) { return k != null && k !== false && k !== ""; });
    var body = drawn ? textCells({ props: {}, children: node.children }, st, path) : run(p.label == null ? "" : String(p.label), st, path);
    var cells;
    if (!p.plain) cells = run("[ ", st, path).concat(body, run(" ]", st, path));
    else if (p.hotkey) cells = run(String(p.hotkey), mergeStyle(st, { color: "suggestion" }), path).concat(run(": ", st, path), body);
    else cells = body;
    return grid([cells.slice(0, Math.max(0, width))]);
  }

  function layoutBox(node, width, path, fill) {
    var p = node.props || {};
    if (p.display === "none") return grid([]);
    var m = margins(p), pd = pads(p);
    var border = p.borderStyle && BORDERS[p.borderStyle] ? p.borderStyle : "";
    var edgeSt = { color: p.borderColor || "", bg: "", bold: false, dim: !!p.borderDimColor, italic: false, underline: false, strikethrough: false, inverse: false };
    var fillSt = { color: "", bg: p.backgroundColor || "", bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };

    var chrome = (border ? 2 : 0) + pd.l + pd.r;
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

    // Every child measures against the full inner room; a row that overruns it
    // overflows (the terminal clips) rather than starving its later children.
    // A child's path keeps its index among all the children, falsy ones too.
    var blocks = [];
    (node.children || []).forEach(function (kid, i) { if (kid) blocks.push({ node: kid, g: layout(kid, inner, path.concat([i])), at: path.concat([i]) }); });
    if (reverse) blocks.reverse();
    // A column stretches each Box it holds that sets no width of its own to
    // the column's width, unless the column aligns its items otherwise.
    if (column && (p.alignItems === undefined || p.alignItems === "stretch")) {
      var colWidth = outer ? inner : Math.max(least, blocks.reduce(function (a, b) { return Math.max(a, b.g.w); }, 0));
      blocks.forEach(function (b) { if (b.node.type === "Box" && typeof (b.node.props || {}).width !== "number") b.g = layout(b.node, colWidth, b.at, true); });
    }

    var body = column ? stackColumn(blocks, inner, gap, p, outer, path, least) : stackRow(blocks, inner, gap, p, outer, path, least);

    // Height: an explicit height pads or (with overflow hidden) clips the body.
    var bodyRows = body.rows;
    if (typeof p.height === "number") {
      var room = Math.max(0, p.height - (border ? 2 : 0) - pd.t - pd.b);
      if (bodyRows.length > room && p.overflow === "hidden") bodyRows = bodyRows.slice(0, room);
      while (bodyRows.length < room) bodyRows.push(blanks(body.w, EMPTY, path));
    }

    var w = body.w;
    // The background sits under everything the Box holds: every cell a child
    // drew without a background of its own takes it, as the padding does.
    if (p.backgroundColor) bodyRows = bodyRows.map(function (r) { return underpaint(padRow(r, w, EMPTY, path), p.backgroundColor); });
    var rows = bodyRows.map(function (r) { return blanks(pd.l, fillSt, path).concat(padRow(r, w, fillSt, path), blanks(pd.r, fillSt, path)); });
    for (var i = 0; i < pd.t; i++) rows.unshift(blanks(w + pd.l + pd.r, fillSt, path));
    for (var j = 0; j < pd.b; j++) rows.push(blanks(w + pd.l + pd.r, fillSt, path));

    if (border) {
      var g = BORDERS[border], iw = w + pd.l + pd.r;
      rows = rows.map(function (r) { return [{ ch: g.l, st: edgeSt, path: path }].concat(r, [{ ch: g.r, st: edgeSt, path: path }]); });
      rows.unshift(run(g.tl + repeat(g.t, iw) + g.tr, edgeSt, path));
      rows.push(run(g.bl + repeat(g.b, iw) + g.br, edgeSt, path));
    }

    if (m.l || m.r) rows = rows.map(function (r) { return blanks(m.l, EMPTY, path).concat(r, blanks(m.r, EMPTY, path)); });
    var mw = rows.length ? rows[0].length : 0;
    for (var t = 0; t < m.t; t++) rows.unshift(blanks(mw, EMPTY, path));
    for (var b = 0; b < m.b; b++) rows.push(blanks(mw, EMPTY, path));
    return grid(rows);
  }

  function underpaint(row, bg) {
    return row.map(function (c) {
      if (c.st && c.st.bg) return c;
      var st = {}; for (var k in (c.st || EMPTY)) st[k] = (c.st || EMPTY)[k];
      st.bg = bg;
      return { ch: c.ch, st: st, path: c.path };
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

  function alignRow(g, h, align, st, path) {
    if (g.h >= h) return g;
    var slack = h - g.h, rows = g.rows.slice();
    var top = align === "center" ? Math.floor(slack / 2) : align === "flex-end" ? slack : 0;
    for (var i = 0; i < top; i++) rows.unshift(blanks(g.w, st, path));
    while (rows.length < h) rows.push(blanks(g.w, st, path));
    return grid(rows);
  }

  function stackRow(blocks, inner, gap, p, outer, path, least) {
    var fillSt = { color: "", bg: p.backgroundColor || "", bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };
    var h = blocks.reduce(function (a, b) { return Math.max(a, b.g.h); }, 0) || (blocks.length ? 1 : 0);
    var content = blocks.reduce(function (a, b) { return a + b.g.w; }, 0) + gap * Math.max(0, blocks.length - 1);
    var room = outer ? inner : Math.max(least, content);

    // flexGrow shares the slack before justifyContent sees any of it.
    var grows = blocks.map(function (b) { return num((b.node.props || {}).flexGrow); });
    var total = grows.reduce(function (a, v) { return a + v; }, 0);
    var free = Math.max(0, room - content);
    var extra = blocks.map(function () { return 0; });
    if (total > 0 && free > 0) {
      var left = free;
      grows.forEach(function (v, i) { var share = i === grows.length - 1 ? left : Math.floor(free * v / total); extra[i] = share; left -= share; });
      free = 0;
    }
    var s = spread(p.justifyContent, free, blocks.length);

    var rows = [];
    for (var y = 0; y < h; y++) {
      var row = blanks(s.lead, fillSt, path);
      blocks.forEach(function (b, i) {
        if (i) row = row.concat(blanks(gap + s.between, fillSt, path));
        var a = alignRow(b.g, h, p.alignItems, fillSt, path);
        row = row.concat(a.rows[y] || blanks(b.g.w, fillSt, path), blanks(extra[i], fillSt, path));
      });
      rows.push(row);
    }
    var w = outer ? inner : Math.max(room, rows.reduce(function (a, r) { return Math.max(a, r.length); }, 0));
    return grid(rows.map(function (r) { return p.overflow === "hidden" || outer ? padRow(r, w, fillSt, path) : padRow(r, w, fillSt, path); }));
  }

  function stackColumn(blocks, inner, gap, p, outer, path, least) {
    var fillSt = { color: "", bg: p.backgroundColor || "", bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };
    var natural = blocks.reduce(function (a, b) { return Math.max(a, b.g.w); }, 0);
    var w = outer ? inner : Math.max(least, natural);
    var rows = [];
    blocks.forEach(function (b, i) {
      if (i && gap) for (var n = 0; n < gap; n++) rows.push(blanks(w, fillSt, path));
      var slack = Math.max(0, w - b.g.w);
      var align = p.alignItems;
      var lead = align === "center" ? Math.floor(slack / 2) : align === "flex-end" ? slack : 0;
      b.g.rows.forEach(function (r) { rows.push(padRow(blanks(lead, fillSt, path).concat(r), w, fillSt, path)); });
    });
    return grid(rows);
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
