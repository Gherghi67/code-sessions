// ABOUTME: The lab's surface registry: SURFACES, every cs mod surface the bundles under docs/surfaces carry, in one list.
// ABOUTME: Loaded as a plain script after the shim and the bundles; a bundle missing from the page is refused by name.
(function (root) {
  "use strict";
  // One global per mod bundle, in the order the Components panel lists them.
  var GLOBALS = ["CsFeedSurfaces", "CsUpdateSurfaces"];
  var surfaces = [];
  GLOBALS.forEach(function (name) {
    var bundle = root[name];
    if (!bundle || !Array.isArray(bundle.surfaces)) throw new Error("the lab's surface registry needs the " + name + " bundle loaded first (docs/surfaces/*.js)");
    bundle.surfaces.forEach(function (s) {
      if (s.global !== name) throw new Error(s.id + " says it comes from " + s.global + ", but the " + name + " bundle carries it");
      surfaces.push(s);
    });
  });
  root.SURFACES = surfaces;
  if (typeof module !== "undefined" && module.exports) module.exports = { SURFACES: surfaces, GLOBALS: GLOBALS };
})(typeof globalThis !== "undefined" ? globalThis : this);
