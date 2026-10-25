// ABOUTME: The engine globals a cs mod's bundled draw code runs against in the design lab: h, Fragment and the element table.
// ABOUTME: Builds the lab's {type, props, children} trees; loaded as a plain script before the bundles, and by bun tests.
(function (root) {
  "use strict";

  // Children as the engine reads them: arrays flattened, and null,
  // undefined, false and true drawing nothing.
  function flat(kids, out) {
    kids.forEach(function (k) {
      if (Array.isArray(k)) flat(k, out);
      else if (k !== null && k !== undefined && k !== false && k !== true) out.push(k);
    });
    return out;
  }

  // An element of the table: its props without children or callbacks, so a
  // tree prints and compares as data. A Button's press is kept on the node,
  // not enumerable, for a frame that presses it.
  function element(type) {
    return function (props) {
      var src = props || {}, p = {};
      Object.keys(src).forEach(function (k) { if (k !== "children" && typeof src[k] !== "function") p[k] = src[k]; });
      var kids = src.children === undefined ? [] : flat(Array.isArray(src.children) ? src.children : [src.children], []);
      var node = { type: type, props: p, children: kids };
      if (typeof src.onPress === "function") Object.defineProperty(node, "onPress", { value: src.onPress, enumerable: false });
      return node;
    };
  }
  var table = { Box: element("Box"), Text: element("Text"), Button: element("Button"), Markdown: element("Markdown"), Code: element("Code") };
  var known = Object.keys(table).map(function (k) { return table[k]; });

  // The classic JSX factory: `tag` is an element of the table or a component
  // function (cs-mermaid's Drawing), called with its props and children.
  function h(tag, props) {
    if (tag === Fragment) throw new Error("the lab draws no Fragment: no cs mod draws one");
    if (typeof tag !== "function") throw new Error("h was handed " + JSON.stringify(tag) + ", not an element of the table or a component function");
    var kids = Array.prototype.slice.call(arguments, 2);
    var p = Object.assign({}, props || {});
    if (kids.length) p.children = known.indexOf(tag) >= 0 ? kids : kids.length === 1 ? kids[0] : kids;
    return tag(p);
  }
  function Fragment() { throw new Error("the lab draws no Fragment: no cs mod draws one"); }

  root.h = h;
  root.Fragment = Fragment;
  root.LabElements = table;
})(typeof globalThis !== "undefined" ? globalThis : this);
