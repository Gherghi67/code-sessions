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

  // A copy of `tree` with the node at `path` replaced by change(node).
  function updateAt(tree, path, change) {
    if (path.length === 0) return change(tree);
    var kids = tree.kids.slice();
    kids[path[0]] = updateAt(kids[path[0]], path.slice(1), change);
    return Object.assign({}, tree, { kids: kids });
  }

  // A copy of `doc` with the selected frame's tree changed. `change(tree)`
  // returns the new tree and `edit`, the words the history lists it by.
  function editTree(doc, verb, change) {
    if (!doc.selection) throw new Error(verb + " needs a selected frame");
    var id = doc.selection.frame;
    var out = change(frameOf(doc, id).tree);
    return Object.assign({}, doc, {
      frames: doc.frames.map(function (f) { return f.id === id ? Object.assign({}, f, { tree: out.tree }) : f; }),
      edit: out.edit,
    });
  }

  var ACTIONS = {
    select: function (doc, a) {
      nodeAt(frameOf(doc, a.frame).tree, a.path);
      return Object.assign({}, doc, { selection: { frame: a.frame, path: a.path.slice() } });
    },
    deselect: function (doc) { return Object.assign({}, doc, { selection: null }); },
    // An empty value ("", false, undefined) removes the prop, as the JSX
    // printer would drop it.
    setProp: function (doc, a) {
      return editTree(doc, "setProp", function (tree) {
        return {
          tree: updateAt(tree, a.path, function (n) {
            var props = Object.assign({}, n.props);
            if (a.value === "" || a.value === false || a.value === undefined) delete props[a.name];
            else props[a.name] = a.value;
            return Object.assign({}, n, { props: props });
          }),
          edit: "set " + a.name + " on " + nodeAt(tree, a.path).type,
        };
      });
    },
  };

  function apply(doc, action) {
    var step = Object.prototype.hasOwnProperty.call(ACTIONS, action.type) ? ACTIONS[action.type] : undefined;
    if (!step) throw new Error("unknown action " + JSON.stringify(action.type));
    return step(doc, action);
  }

  // History = { past: Doc[], present: Doc, future: Doc[] }. Each Doc is a
  // structural clone, so no later edit can reach into a step.
  var HISTORY_CAP = 200;
  var clone = function (doc) { return JSON.parse(JSON.stringify(doc)); };
  function history(doc) { return { past: [], present: clone(doc), future: [] }; }
  // An edit: the present becomes a step back, and the steps ahead are gone.
  function commit(h, doc) {
    return { past: h.past.concat([h.present]).slice(-HISTORY_CAP), present: clone(doc), future: [] };
  }
  // Not an edit (a selection): the present moves and no step is taken.
  function replace(h, doc) { return { past: h.past, present: clone(doc), future: h.future }; }

  var api = { history: history, commit: commit, replace: replace, apply: apply, nodeAt: nodeAt, parentOf: parentOf, pathOfCell: pathOfCell, spanOf: spanOf, toEngine: toEngine };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.BandEditor = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
