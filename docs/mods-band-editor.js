// ABOUTME: The band designer's document: frames of editor trees, the selection, and the reducer that edits them.
// ABOUTME: Pure, no DOM; loaded by docs/mods-design-lab.html as a plain script and by bun tests through module.exports.
(function (root) {
  "use strict";

  // An editor node is { type: "Box" | "Text" | "Button", props, kids }: a
  // Text's words are its `text` prop, so only a Box or a Button has kids. A
  // node is addressed by its index path from the frame's root.
  // Doc = { frames: [{ id, name, tree }], selection: { frame, path } | null,
  //         exportFrame: the frame the JSX pane prints }.

  var show = function (path) { return JSON.stringify(path); };

  function nodeAt(tree, path) {
    var node = tree;
    for (var i = 0; i < path.length; i++) {
      if (path[i] < 0 || path[i] >= node.kids.length) throw new Error("no node at " + show(path) + ": " + show(path.slice(0, i)) + " has " + node.kids.length + " children");
      node = node.kids[path[i]];
    }
    return node;
  }

  // The parent's path and the node's index in it; null for the root.
  function parentOf(tree, path) {
    nodeAt(tree, path);
    return path.length === 0 ? null : { path: path.slice(0, -1), index: path[path.length - 1] };
  }

  // The path of the node that drew the cell, or null off the grid.
  function pathOfCell(grid, row, col) {
    var r = grid.rows[row];
    var cell = r && r[col];
    return cell ? cell.path : null;
  }

  function within(path, ancestor) {
    if (path.length < ancestor.length) return false;
    for (var i = 0; i < ancestor.length; i++) if (path[i] !== ancestor[i]) return false;
    return true;
  }

  // The rows and columns, inclusive, of every cell the node or a descendant
  // drew; null when it drew none.
  function spanOf(grid, path) {
    var span = null;
    grid.rows.forEach(function (r, y) {
      r.forEach(function (c, x) {
        if (!within(c.path, path)) return;
        if (!span) span = { top: y, left: x, bottom: y, right: x };
        span.top = Math.min(span.top, y); span.bottom = Math.max(span.bottom, y);
        span.left = Math.min(span.left, x); span.right = Math.max(span.right, x);
      });
    });
    return span;
  }

  function frameOf(doc, id) {
    var frame = doc.frames.find(function (f) { return f.id === id; });
    if (!frame) throw new Error("no frame " + id);
    return frame;
  }

  // The editor tree's props are the engine's, plus the ones only the editor
  // spells: `text` (a Text's words) and the two hover colours a field sets.
  function toEngine(n) {
    var p = Object.assign({}, n.props);
    var text = p.text || ""; delete p.text;
    var hb = p.hoverBorderColor, hg = p.hoverBackgroundColor;
    delete p.hoverBorderColor; delete p.hoverBackgroundColor;
    if (hb || hg) { p.hover = Object.assign({}, p.hover); if (hb) p.hover.borderColor = hb; if (hg) p.hover.backgroundColor = hg; }
    Object.keys(p).forEach(function (k) { if (p[k] === "" || p[k] === false || p[k] === undefined) delete p[k]; });
    if (n.type === "Text") return { type: "Text", props: p, children: [text] };
    if (n.type === "Button") return { type: "Button", props: p, children: n.kids.map(toEngine) };
    return { type: "Box", props: p, children: n.kids.map(toEngine) };
  }

  var ACTIONS = {
    select: function (doc, a) {
      nodeAt(frameOf(doc, a.frame).tree, a.path);
      return Object.assign({}, doc, { selection: { frame: a.frame, path: a.path.slice() } });
    },
    deselect: function (doc) { return Object.assign({}, doc, { selection: null }); },
  };

  function apply(doc, action) {
    var step = Object.prototype.hasOwnProperty.call(ACTIONS, action.type) ? ACTIONS[action.type] : undefined;
    if (!step) throw new Error("unknown action " + JSON.stringify(action.type));
    return step(doc, action);
  }

  var api = { apply: apply, nodeAt: nodeAt, parentOf: parentOf, pathOfCell: pathOfCell, spanOf: spanOf, toEngine: toEngine };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.BandEditor = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
