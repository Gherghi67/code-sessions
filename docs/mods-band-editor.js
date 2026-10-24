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
  var clone = function (value) { return JSON.parse(JSON.stringify(value)); };

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

  // The paths of every Text and Button, in the order the tree holds them:
  // the words a person can edit on the strip.
  function wordPaths(tree) {
    var out = [];
    (function walk(n, path) {
      if (n.type === "Text" || n.type === "Button") out.push(path);
      n.kids.forEach(function (k, i) { walk(k, path.concat([i])); });
    })(tree, []);
    return out;
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
  // returns the new tree, `edit` (the words the history lists it by) and,
  // when the edit moves the selection, `select`, the path now selected.
  function editTree(doc, verb, change) {
    if (!doc.selection) throw new Error(verb + " needs a selected frame");
    var id = doc.selection.frame;
    var out = change(frameOf(doc, id).tree);
    return Object.assign({}, doc, {
      frames: doc.frames.map(function (f) { return f.id === id ? Object.assign({}, f, { tree: out.tree }) : f; }),
      selection: out.select ? { frame: id, path: out.select } : doc.selection,
      edit: out.edit,
    });
  }

  // Why the engine would refuse a node of `type` under `parent`, or null: a
  // Text holds only words, a Button only Text, which draws in its label's place.
  function refusal(type, parent) {
    if (parent.type === "Text") return "a " + type + " cannot go inside a Text";
    if (parent.type === "Button" && type !== "Text") return "a " + type + " cannot go inside a Button";
    return null;
  }

  // Why the node at `from` cannot be moved under `parentPath`, or null when it can.
  function canDrop(tree, from, parentPath) {
    if (from.length === 0) return "the root cannot move";
    if (within(parentPath, from)) return "cannot move " + show(from) + " into itself";
    return refusal(nodeAt(tree, from).type, nodeAt(tree, parentPath));
  }

  function insertAt(tree, parentPath, index, node) {
    return updateAt(tree, parentPath, function (p) {
      var kids = p.kids.slice();
      kids.splice(index, 0, node);
      return Object.assign({}, p, { kids: kids });
    });
  }
  function removeAt(tree, path) {
    var at = path[path.length - 1];
    return updateAt(tree, path.slice(0, -1), function (p) {
      return Object.assign({}, p, { kids: p.kids.filter(function (k, i) { return i !== at; }) });
    });
  }
  // Where `path` points once the node at `removed` is gone: a later sibling
  // of the removed node, or anything inside one, moves up by one.
  function afterRemoval(path, removed) {
    var depth = removed.length - 1;
    if (path.length <= depth || !within(path, removed.slice(0, -1)) || path[depth] <= removed[depth]) return path;
    var out = path.slice();
    out[depth] -= 1;
    return out;
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
    // `to.index` is a gap among the parent's children before the move.
    move: function (doc, a) {
      return editTree(doc, "move", function (tree) {
        var why = canDrop(tree, a.from, a.to.parentPath);
        if (why) throw new Error(why);
        var node = nodeAt(tree, a.from);
        var parentPath = afterRemoval(a.to.parentPath, a.from);
        var sameParent = show(a.to.parentPath) === show(a.from.slice(0, -1));
        var index = sameParent && a.to.index > a.from[a.from.length - 1] ? a.to.index - 1 : a.to.index;
        return { tree: insertAt(removeAt(tree, a.from), parentPath, index, node), edit: "move " + node.type, select: parentPath.concat([index]) };
      });
    },
    remove: function (doc, a) {
      return editTree(doc, "remove", function (tree) {
        if (a.path.length === 0) throw new Error("the root cannot be removed");
        return { tree: removeAt(tree, a.path), edit: "remove " + nodeAt(tree, a.path).type, select: a.path.slice(0, -1) };
      });
    },
    setText: function (doc, a) {
      return editTree(doc, "setText", function (tree) {
        var type = nodeAt(tree, a.path).type;
        if (type !== "Text") throw new Error("setText needs a Text; " + show(a.path) + " is a " + type);
        return {
          tree: updateAt(tree, a.path, function (n) { return Object.assign({}, n, { props: Object.assign({}, n.props, { text: a.text }) }); }),
          edit: "edit the words of a Text",
        };
      });
    },
    duplicateNode: function (doc, a) {
      return editTree(doc, "duplicateNode", function (tree) {
        if (a.path.length === 0) throw new Error("the root cannot be duplicated");
        var node = nodeAt(tree, a.path), at = a.path[a.path.length - 1];
        return { tree: insertAt(tree, a.path.slice(0, -1), at + 1, clone(node)), edit: "duplicate " + node.type, select: a.path.slice(0, -1).concat([at + 1]) };
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
  function history(doc) { return { past: [], present: clone(doc), future: [] }; }
  // An edit: the present becomes a step back, and the steps ahead are gone.
  function commit(h, doc) {
    return { past: h.past.concat([h.present]).slice(-HISTORY_CAP), present: clone(doc), future: [] };
  }
  // Not an edit (a selection): the present moves and no step is taken.
  function replace(h, doc) { return { past: h.past, present: clone(doc), future: h.future }; }

  var api = { history: history, commit: commit, replace: replace, apply: apply, canDrop: canDrop, wordPaths: wordPaths, nodeAt: nodeAt, parentOf: parentOf, pathOfCell: pathOfCell, spanOf: spanOf, toEngine: toEngine };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.BandEditor = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
