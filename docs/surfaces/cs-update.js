(() => {
  // mods/cs-update/hooks/register.tsx
  function stripInline(s) {
    return s.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/\*\*/g, "").replace(/`/g, "");
  }
  function parseSpan(text) {
    const sections = [];
    for (const raw of text.split(`
`)) {
      const line = raw.replace(/\s+$/, "");
      if (line.startsWith("## ")) {
        sections.push({ version: line.slice(3).trim(), lines: [] });
        continue;
      }
      if (sections.length === 0)
        continue;
      if (line === "" || line.startsWith("#") || line.startsWith("<!--"))
        continue;
      sections[sections.length - 1].lines.push(stripInline(line));
    }
    return sections;
  }
  function drawPane(v, el, update) {
    const { Box, Text, Button } = el;
    const { version, sections, accent, phase, outcome } = v;
    return /* @__PURE__ */ h(Box, {
      flexDirection: "column",
      paddingX: 1
    }, /* @__PURE__ */ h(Text, {
      bold: true
    }, `cs ${version} is available`), /* @__PURE__ */ h(Box, {
      marginTop: 1,
      flexDirection: "column"
    }, phase === "running" && /* @__PURE__ */ h(Text, {
      dimColor: true
    }, `updating… running cs -update ${version}`), (phase === "done" || phase === "failed") && /* @__PURE__ */ h(Text, null, outcome), (phase === "idle" || phase === "failed") && /* @__PURE__ */ h(Box, null, /* @__PURE__ */ h(Button, {
      key: "cs-update-now",
      hotkey: "1",
      plain: true,
      label: "update now",
      onPress: update
    }), /* @__PURE__ */ h(Text, {
      dimColor: true
    }, "   Esc: later")), phase === "idle" && /* @__PURE__ */ h(Text, {
      dimColor: true
    }, "Installs in place; the new files take effect on your next launch."), phase === "done" && /* @__PURE__ */ h(Text, {
      dimColor: true
    }, "Esc: close")), sections === undefined || sections.length === 0 ? /* @__PURE__ */ h(Box, {
      marginTop: 1
    }, /* @__PURE__ */ h(Text, null, `Release notes could not be fetched at launch; the update is ${version}.`)) : sections.map((s) => /* @__PURE__ */ h(Box, {
      key: `v-${s.version}`,
      flexDirection: "column",
      marginTop: 1
    }, /* @__PURE__ */ h(Text, {
      bold: true,
      color: accent
    }, s.version), s.lines.map((line, j) => /* @__PURE__ */ h(Box, {
      key: `l-${s.version}-${j}`
    }, /* @__PURE__ */ h(Text, null, line))))));
  }

  // mods/cs/hooks/register.tsx
  var SESSION_PALETTE = {
    red: "220,38,38",
    blue: "106,155,204",
    green: "22,163,74",
    yellow: "202,138,4",
    purple: "130,125,189",
    orange: "217,119,87",
    pink: "196,102,134",
    cyan: "8,145,178"
  };
  var FINISH_OUTCOMES = new Set(["landed", "refused", "retired"]);
  var QUEUE_HERE = "In this conversation";
  var QUEUE_SUBAGENTS = "In subagents";
  var QUEUE_WORKFLOWS = "As workflows";
  var QUEUE_MODE_WORDS = { [QUEUE_HERE]: [], [QUEUE_SUBAGENTS]: ["subagents"], [QUEUE_WORKFLOWS]: ["workflow"] };
  var finishShown = new Set;
  var READ_CAP = 4 * 1024 * 1024;
  var drawnRows = new Map;
  var shown = new Map;
  var denied = new Set;
  var FEATURE_STATES = new Set(["ready", "staged", "locked", "dirty", "untracked", "vault-locked", "base-dirty", "merged"]);

  // docs/surfaces/registry.ts
  function elements() {
    const el = globalThis.LabElements;
    if (el === undefined)
      throw new Error("the lab shim (docs/surfaces/shim.js) is not loaded: LabElements is undefined");
    return el;
  }

  // docs/surfaces/cs-update.fixtures.ts
  var NOTES = [
    "## 2026.10.25",
    "### Fixed",
    "- The band's **mark** keeps its colour",
    "- `cs -update` checks the signature",
    "  before it installs",
    "## 2026.10.20",
    "- A [link](https://example.com) survives as text",
    ""
  ].join(`
`);
  var base = { version: "2026.10.25", sections: parseSpan(NOTES), accent: `rgb(${SESSION_PALETTE.blue})`, phase: "idle", outcome: "" };
  var pane = (over) => () => drawPane({ ...base, ...over }, elements(), () => {});
  var surfaces = [{
    id: "cs-update.Pane.cs-update",
    mod: "cs-update",
    slot: "Pane",
    source: "generated",
    global: "CsUpdateSurfaces",
    needs: [],
    chrome: { kind: "pane", title: "cs 2026.10.25 is available", rows: 16 },
    states: [
      { id: "idle-notes", name: "reading the notes before installing", draw: pane({}) },
      { id: "idle-no-colour", name: "reading the notes in a session with no colour", draw: pane({ accent: undefined }) },
      { id: "idle-no-notes", name: "offered an update whose notes were not fetched", draw: pane({ sections: [] }) },
      { id: "several-sections", name: "reading notes that span many releases", draw: pane({ sections: parseSpan(Array.from({ length: 5 }, (_, i) => `## 2026.10.${25 - i}
- release note ${i + 1}
- and a second line`).join(`
`)) }) },
      { id: "running", name: "waiting while cs -update runs", draw: pane({ phase: "running" }) },
      { id: "failed-no-bin", name: "told the launch did not say where cs is", draw: pane({ phase: "failed", outcome: "The launch did not say where cs is; run `cs -update` from a shell." }) },
      { id: "failed-exit", name: "reading why cs -update failed", draw: pane({ phase: "failed", outcome: `cs -update exited 3.
download failed
checksum mismatch` }) },
      { id: "done", name: "told the update finished", draw: pane({ phase: "done", outcome: "Update finished. Takes effect on your next launch." }) }
    ],
    parts: [
      { id: "update-key", name: "hotkey Button", state: "idle-notes", path: [1, 0, 0] },
      { id: "release-heading", name: "release heading", state: "idle-notes", path: [2, 0] },
      { id: "note-line", name: "note line", state: "idle-notes", path: [2, 1] }
    ]
  }];

  // docs/surfaces/cs-update.entry.ts
  globalThis.CsUpdateSurfaces = { surfaces };
})();
