// ABOUTME: The band designer's document: frames of editor trees, the selection, and the reducer that edits them.
// ABOUTME: Pure, no DOM; loaded by docs/mods-design-lab.html as a plain script and by bun tests through module.exports.
(function (root) {
  "use strict";

  // An editor node is { type: "Box" | "Text" | "Button", props, kids }: a
  // Text's words are its `text` prop, so only a Box or a Button has kids. A
  // node is addressed by its index path from the frame's root. A frame drawn
  // from a mod surface's state names it as `source`, and one whose tree holds
  // a node the designer cannot edit (Markdown, Code) is a reference frame,
  // `ref`, read but never edited.
  // Doc = { frames: [{ id, name, tree, source?, ref? }], selection: { frame, path } | null,
  //         exportFrame: the frame the JSX pane prints,
  //         edit: what the last edit did, as the history lists it }.

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
    if (LEAVES[n.type]) return { type: n.type, props: Object.assign({}, n.props), children: [] };
    var p = Object.assign({}, n.props);
    var text = p.text || ""; delete p.text;
    var hb = p.hoverBorderColor, hg = p.hoverBackgroundColor;
    delete p.hoverBorderColor; delete p.hoverBackgroundColor;
    if (hb || hg) { p.hover = Object.assign({}, p.hover); if (hb) p.hover.borderColor = hb; if (hg) p.hover.backgroundColor = hg; }
    Object.keys(p).forEach(function (k) { if (p[k] === "" || p[k] === false || p[k] === undefined) delete p[k]; });
    if (n.type === "Text") return { type: "Text", props: p, children: [text] };
    if (n.type === "Button") return { type: "Button", props: p, children: n.kids.map(buttonChild) };
    return { type: "Box", props: p, children: n.kids.map(toEngine) };
  }

  // A Button's child as register.tsx writes it: a Text with nothing but its
  // words is the bare string, which the engine draws the same.
  function buttonChild(k) {
    var bare = k.type === "Text" && Object.keys(k.props).every(function (name) { return name === "text"; });
    return bare ? k.props.text || "" : toEngine(k);
  }

  // A copy of `tree` with the node at `path` replaced by change(node).
  function updateAt(tree, path, change) {
    if (path.length === 0) return change(tree);
    var kids = tree.kids.slice();
    kids[path[0]] = updateAt(kids[path[0]], path.slice(1), change);
    return Object.assign({}, tree, { kids: kids });
  }

  // What a reference frame holds besides Box, Text and Button: elements with
  // no children the engine draws from their props.
  var LEAVES = { Markdown: true, Code: true };

  // Why the designer cannot edit an engine tree, or null when it can: the
  // first element it holds that is not a Box, Text or Button, or a Text inside
  // a Text, whose words the editor holds as one string.
  function uneditable(e) {
    if (!e || typeof e !== "object") return null;
    if (!TYPES[e.type]) return "it holds a " + e.type + " node";
    var kids = (e.children || []).filter(function (k) { return k && typeof k === "object"; });
    if (e.type === "Text" && kids.length) return "it holds a Text inside a Text";
    for (var i = 0; i < kids.length; i++) { var why = uneditable(kids[i]); if (why) return why; }
    return null;
  }

  // A copy of `doc` with the selected frame's tree changed. `change(tree)`
  // returns the new tree, `edit` (the words the history lists it by) and,
  // when the edit moves the selection, `select`, the path now selected.
  function editTree(doc, verb, change) {
    if (!doc.selection) throw new Error(verb + " needs a selected frame");
    var id = doc.selection.frame, edited = frameOf(doc, id);
    if (edited.ref) throw new Error(edited.name + " is a reference frame, drawn by the mod: the designer does not edit it");
    var out = change(edited.tree);
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

  // Where the node at `from` lands when dropped on the grid's cell, or null
  // when nowhere, or where it already is. A pointer inside a sibling, at any
  // depth, reorders among the siblings. Anywhere else the node under the
  // pointer takes it when it may hold it, else the nearest container above
  // that may. The gap is the first drawn child whose midpoint along the
  // parent's direction is not before the pointer.
  function dropTarget(tree, grid, from, cell) {
    var at = pathOfCell(grid, cell.r, cell.c);
    if (from.length === 0 || !at || within(at, from)) return null;
    var parent = from.slice(0, -1), i = from[from.length - 1];
    var p = at.length > parent.length && within(at, parent) ? parent : at;
    while (p && (nodeAt(tree, p).type === "Text" || canDrop(tree, from, p) !== null)) p = p.length ? p.slice(0, -1) : null;
    if (!p) return null;
    var index = gapAt(tree, grid, p, cell);
    if (show(p) === show(parent) && (index === i || index === i + 1)) return null;
    return { parentPath: p, index: index };
  }

  // Where a node of `type` from outside the frame lands when dropped on the
  // grid's cell, or null off the drawing: the node under the pointer when it
  // may hold one, else the nearest container above that may, at the gap
  // dropTarget would pick.
  function insertTarget(tree, grid, type, cell) {
    var p = pathOfCell(grid, cell.r, cell.c);
    while (p && (nodeAt(tree, p).type === "Text" || refusal(type, nodeAt(tree, p)) !== null)) p = p.length ? p.slice(0, -1) : null;
    if (!p) return null;
    return { parentPath: p, index: gapAt(tree, grid, p, cell) };
  }

  // The gap among the children of the Box at `p` before the first drawn child
  // whose midpoint along the Box's direction is not before the cell.
  function gapAt(tree, grid, p, cell) {
    var dir = String(nodeAt(tree, p).props.flexDirection || "row");
    var column = /^column/.test(dir), reverse = /-reverse$/.test(dir), pos = column ? cell.r : cell.c;
    var kids = nodeAt(tree, p).kids;
    for (var k = 0; k < kids.length; k++) {
      var s = spanOf(grid, p.concat([k]));
      if (!s) continue;
      var mid = column ? (s.top + s.bottom) / 2 : (s.left + s.right) / 2;
      if (reverse ? mid <= pos : mid >= pos) return k;
    }
    return kids.length;
  }

  // Where a new node goes for the node at `path`: a Box takes it as its
  // last child, anything else has it placed right after.
  function insertPoint(tree, path) {
    var node = nodeAt(tree, path);
    if (node.type === "Box" || path.length === 0) return { parentPath: path, index: node.kids.length };
    return { parentPath: path.slice(0, -1), index: path[path.length - 1] + 1 };
  }

  function insertAt(tree, parentPath, index, node) {
    return updateAt(tree, parentPath, function (p) {
      if (index < 0 || index > p.kids.length) throw new Error("no gap " + index + " in " + show(parentPath) + ": it has " + p.kids.length + " children");
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

  // The inverse of toEngine: an engine tree as the editor holds it, empty
  // props dropped, a hover of only the two colours spelled as their fields.
  var HOVER_FIELDS = { borderColor: "hoverBorderColor", backgroundColor: "hoverBackgroundColor" };
  function fromEngine(e) {
    var props = {};
    Object.keys(e.props || {}).forEach(function (k) {
      var v = e.props[k];
      if (v === "" || v === false || v === undefined) return;
      if (k === "hover" && Object.keys(v).every(function (h) { return HOVER_FIELDS[h]; })) {
        Object.keys(v).forEach(function (h) { props[HOVER_FIELDS[h]] = v[h]; });
        return;
      }
      props[k] = v;
    });
    var kids = (e.children || []).filter(function (k) { return k !== null && k !== undefined && k !== false; });
    if (e.type === "Text") {
      if (kids.some(function (k) { return typeof k === "object"; })) throw new Error("the editor holds a Text's words as one string; this Text has a Text inside it");
      var words = kids.join("");
      if (words !== "") props.text = words;
      return { type: "Text", props: props, kids: [] };
    }
    return { type: e.type, props: props, kids: kids.map(function (k) { return engineChild(k, e.type); }) };
  }
  // A Box's children are elements; a Button's are strings and Text, and the
  // editor holds a string as a Text carrying those words.
  function engineChild(k, parent) {
    if (typeof k === "object") return fromEngine(k);
    if (parent !== "Button") throw new Error("a " + parent + " holds no bare string; " + JSON.stringify(k) + " needs a Text");
    if (typeof k !== "string") throw new Error("a Button holds strings and Text; " + JSON.stringify(k) + " is neither");
    return { type: "Text", props: k === "" ? {} : { text: k }, kids: [] };
  }

  function frameNumber(id) { return +String(id).replace(/^f/, "") || 0; }
  function nameOf(doc, id) { return frameOf(doc, id).name; }

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
    insert: function (doc, a) {
      return editTree(doc, "insert", function (tree) {
        var why = refusal(a.node.type, nodeAt(tree, a.parentPath));
        if (why) throw new Error(why);
        return { tree: insertAt(tree, a.parentPath, a.index, clone(a.node)), edit: "insert " + a.node.type, select: a.parentPath.concat([a.index]) };
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
    // A copy of frame `from`, a tree read from elsewhere, or an empty Box.
    addFrame: function (doc, a) {
      if (a.from !== undefined && a.tree !== undefined) throw new Error("addFrame takes a frame to copy or a tree, not both");
      var id = "f" + (Math.max.apply(null, doc.frames.map(function (f) { return frameNumber(f.id); })) + 1);
      var source = a.from !== undefined ? frameOf(doc, a.from) : null;
      var name = source ? source.name + " copy" : a.name || "Frame " + (doc.frames.length + 1);
      var tree = source ? clone(source.tree) : a.tree ? clone(a.tree) : { type: "Box", props: {}, kids: [] };
      var added = { id: id, name: name, tree: tree };
      var from = source ? source.source : a.source;
      if (from) added.source = { surface: from.surface, state: from.state };
      if (source ? source.ref : a.ref) added.ref = true;
      return Object.assign({}, doc, { frames: doc.frames.concat([added]), selection: { frame: id, path: [] }, edit: "add frame " + name });
    },
    renameFrame: function (doc, a) {
      if (!String(a.name).trim()) throw new Error("a frame needs a name");
      var was = nameOf(doc, a.frame);
      return Object.assign({}, doc, {
        frames: doc.frames.map(function (f) { return f.id === a.frame ? Object.assign({}, f, { name: a.name }) : f; }),
        edit: "rename frame " + was + " to " + a.name,
      });
    },
    removeFrame: function (doc, a) {
      var name = nameOf(doc, a.frame);
      if (doc.frames.length === 1) throw new Error("the last frame cannot be removed");
      var frames = doc.frames.filter(function (f) { return f.id !== a.frame; });
      return Object.assign({}, doc, {
        frames: frames,
        selection: doc.selection && doc.selection.frame === a.frame ? null : doc.selection,
        exportFrame: doc.exportFrame === a.frame ? frames[0].id : doc.exportFrame,
        edit: "remove frame " + name,
      });
    },
    selectFrame: function (doc, a) {
      frameOf(doc, a.frame);
      return Object.assign({}, doc, { selection: { frame: a.frame, path: [] } });
    },
    exportFrame: function (doc, a) {
      return Object.assign({}, doc, { exportFrame: a.frame, edit: "export frame " + nameOf(doc, a.frame) });
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
  // A field's draft, settled before anything else reaches the history: a
  // step when it changed the frames or the export, nothing when it was
  // retyped back to what the present holds.
  function commitDraft(h, draft) {
    if (!draft) return h;
    var content = function (d) { return JSON.stringify({ frames: d.frames, exportFrame: d.exportFrame }); };
    return content(draft) === content(h.present) ? h : commit(h, draft);
  }

  function undo(h) {
    if (h.past.length === 0) return h;
    return { past: h.past.slice(0, -1), present: h.past[h.past.length - 1], future: [h.present].concat(h.future) };
  }
  function redo(h) {
    if (h.future.length === 0) return h;
    return { past: h.past.concat([h.present]), present: h.future[0], future: h.future.slice(1) };
  }
  // `by` steps from the present: back when negative, ahead when positive.
  function jump(h, by) {
    for (var i = 0; i < Math.abs(by); i++) h = by < 0 ? undo(h) : redo(h);
    return h;
  }

  // ---- reading what was saved ----
  // localStorage is outside the page's control: a saved document is checked
  // field by field and refused with the reason, never patched up.
  var TYPES = { Box: true, Text: true, Button: true };
  // `ref`: the node is a reference frame's, which may also be a Markdown or Code.
  function readTree(n, ref) {
    if (!n || typeof n !== "object") throw new Error("a saved node is not an object");
    if (!TYPES[n.type] && !(ref && LEAVES[n.type])) throw new Error("a saved node is a " + n.type + ", not a Box, Text or Button");
    if (!n.props || typeof n.props !== "object") throw new Error("a saved " + n.type + " has no props");
    if (!Array.isArray(n.kids)) throw new Error("a saved " + n.type + " has no kids list");
    var kids = n.kids.map(function (k) { return readTree(k, ref); });
    kids.forEach(function (k) { var why = refusal(k.type, n); if (why) throw new Error("a saved tree is refused: " + why); });
    return { type: n.type, props: n.props, kids: kids };
  }
  function readDoc(d) {
    if (!d || !Array.isArray(d.frames) || d.frames.length === 0) throw new Error("a saved document has no frames");
    var frames = d.frames.map(function (f) {
      if (typeof f.id !== "string" || typeof f.name !== "string") throw new Error("a saved frame has no id or no name");
      var frame = { id: f.id, name: f.name, tree: readTree(f.tree, f.ref === true) };
      if (f.source !== undefined) {
        if (!f.source || typeof f.source.surface !== "string" || typeof f.source.state !== "string") throw new Error("a saved frame names a source with no surface and state");
        frame.source = { surface: f.source.surface, state: f.source.state };
      }
      if (f.ref === true) frame.ref = true;
      return frame;
    });
    frames.forEach(function (f, i) {
      if (frames.findIndex(function (g) { return g.id === f.id; }) !== i) throw new Error("a saved document has two frames with the id " + f.id);
    });
    if (!frames.some(function (f) { return f.id === d.exportFrame; })) throw new Error("a saved document exports " + d.exportFrame + ", which is not one of its frames");
    var doc = { frames: frames, selection: null, exportFrame: d.exportFrame };
    if (d.selection) doc = apply(doc, { type: "select", frame: d.selection.frame, path: d.selection.path });
    if (typeof d.edit === "string") doc.edit = d.edit;
    return doc;
  }

  var api = { history: history, commit: commit, commitDraft: commitDraft, replace: replace, undo: undo, redo: redo, jump: jump, readDoc: readDoc, readTree: readTree, apply: apply, canDrop: canDrop, dropTarget: dropTarget, refusal: refusal, insertTarget: insertTarget, uneditable: uneditable, insertPoint: insertPoint, wordPaths: wordPaths, nodeAt: nodeAt, parentOf: parentOf, pathOfCell: pathOfCell, spanOf: spanOf, toEngine: toEngine, fromEngine: fromEngine };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.BandEditor = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
