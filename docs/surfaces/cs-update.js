(() => {
  // mods/cs-update/hooks/register.tsx
  var TOASTS = {
    declined: (version) => `cs ${version} is available · run cs -update to install it, or /cs-update for the notes`,
    notRecorded: (err) => `could not record the finished update: ${err}`
  };
  var REPLIES = {
    notLead: "The release-notes pane belongs to the conversation cs launched.",
    nothingPending: "This launch found no newer cs; the check runs again at the next launch.",
    notesOpen: "Release notes are in the side pane."
  };
  var COMMANDS = {
    "cs-update": { name: "cs-update", description: "Release notes for the pending cs update, with 1 to install it." }
  };
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

  // docs/surfaces/chrome.ts
  var cells = (s) => Array.from(s).length;
  function wrapRows(line, width) {
    const rows = [];
    let row = [];
    const next = (start = []) => {
      rows.push(row);
      row = start;
    };
    line.split(" ").forEach((word, i) => {
      let used = row.length;
      if (i > 0) {
        if (used >= width) {
          next();
          used = 0;
        }
        row.push(" ");
        used++;
      }
      const chars = Array.from(word);
      if (chars.length > width) {
        const thisRow = 1 + Math.floor((chars.length - (width - used) - 1) / width);
        const nextRow = Math.floor((chars.length - 1) / width);
        if (nextRow < thisRow)
          next();
        let shown = row.length;
        chars.forEach((c, k) => {
          if (shown + 1 <= width)
            row.push(c);
          else {
            next([c]);
            shown = 0;
          }
          shown++;
          if (shown === width && k < chars.length - 1) {
            next();
            shown = 0;
          }
        });
        return;
      }
      if (used + chars.length > width && used > 0 && chars.length > 0)
        next();
      row = row.concat(chars);
    });
    rows.push(row);
    return rows.map((r) => r.join(""));
  }
  var oneLine = (text) => text.replace(/[\n\r\u2028\u2029]/g, "�");
  var TOAST_WIDEST = 44;
  var TOAST_FRAME = 4;
  var TOAST_ROWS = 3;
  function toast(plugin, text, cols) {
    const el = elements();
    const room = Math.max(1, Math.min(Math.max(1, cols - 2), TOAST_WIDEST));
    const wrapped = wrapRows(oneLine(text), Math.max(1, room - TOAST_FRAME));
    const lines = [...wrapped.slice(0, TOAST_ROWS - 1), wrapped.slice(TOAST_ROWS - 1).join(" ")].filter((line, i) => i === 0 || line !== "");
    const width = Math.min(room, Math.max(cells(plugin), ...lines.map(cells)) + TOAST_FRAME);
    return el.Box({ width: cols, justifyContent: "flex-end", children: [
      el.Box({ width, flexDirection: "column", borderStyle: "round", borderDimColor: true, paddingX: 1, children: [
        el.Text({ dimColor: true, wrap: "truncate-end", children: plugin }),
        ...lines.map((line) => el.Text({ wrap: "truncate-end", children: line }))
      ] })
    ] });
  }
  function inlineToast(plugin, text, cols) {
    const el = elements();
    return el.Box({ width: cols, paddingX: 2, flexDirection: "column", alignItems: "flex-end", children: [
      el.Text({ dimColor: true, wrap: "truncate", children: `${plugin}: ${oneLine(text)}` })
    ] });
  }
  function commandReply(plugin, command, args, reply) {
    const el = elements();
    return el.Box({ flexDirection: "column", children: [
      el.Box({ flexDirection: "column", backgroundColor: "userMessageBackground", paddingRight: 1, children: [
        el.Text({ children: [el.Text({ color: "inactive", children: "❯" }), " ", el.Text({ color: "text", children: `/${[command, args].filter(Boolean).join(" ")}` })] })
      ] }),
      el.Box({ children: [
        el.Text({ dimColor: true, children: "  ⎿  " }),
        el.Box({ flexDirection: "column", flexGrow: 1, children: [el.Markdown({ text: `${plugin}: ${reply}` })] })
      ] })
    ] });
  }
  function menuRows(commands, selected, cols) {
    const el = elements();
    const widest = Math.max(...commands.map((c) => cells(`/${c.name}`))) + 5;
    const cap = Math.floor(cols * 0.4);
    const pointer = cells("❯ ");
    const lane = cols - cap - 4 - 1;
    const column = widest > cap ? cap + (lane < 0 ? pointer : Math.min(pointer, lane)) : widest;
    const room = Math.max(0, cols - column - 4);
    return el.Box({ paddingX: 2, children: [el.Box({ flexDirection: "column", children: commands.flatMap((c, i) => {
      const on = i === selected;
      const ink = on ? "suggestion" : undefined;
      const name = `/${c.name}`;
      const [first, rest] = firstRow(c.description, room);
      const row = el.Text({ wrap: "truncate", children: [
        el.Text({ color: ink, dimColor: !on, children: on ? "❯ " : "  " }),
        el.Text({ color: ink, dimColor: !on, children: name }),
        el.Text({ color: ink, dimColor: !on, children: " ".repeat(Math.max(0, column - cells(name) - 2)) }),
        el.Text({ color: ink, dimColor: !on, children: first })
      ] });
      if (rest === "")
        return [row];
      return [row, el.Text({ wrap: "truncate", children: [" ".repeat(column), el.Text({ color: ink, dimColor: !on, children: cut(rest, Math.max(0, cols - column - 4)) })] })];
    }) })] });
  }
  function firstRow(text, room) {
    if (room <= 0 || cells(text) <= room)
      return [text, ""];
    const head = Array.from(text).slice(0, room).join("");
    const after = Array.from(text).slice(room).join("");
    if (after.startsWith(" "))
      return [head, after.trimStart()];
    const space = head.lastIndexOf(" ");
    return space > 0 ? [head.slice(0, space), text.slice(space + 1)] : [head, after];
  }
  function cut(text, room) {
    if (cells(text) <= room)
      return text;
    return room < 1 ? "" : Array.from(text).slice(0, room - 1).join("") + "…";
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
  var surfaces = [
    {
      id: "cs-update.Pane.cs-update",
      mod: "cs-update",
      slot: "Pane",
      source: "generated",
      global: "CsUpdateSurfaces",
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
    },
    chromeSurface("toast", [
      { id: "declined", name: "launching after declining the update cs offered", draw: (cols) => toast("cs-update", TOASTS.declined("2026.11.2"), cols) },
      { id: "not-recorded", name: "finishing an update whose outcome cannot be written down", draw: (cols) => toast("cs-update", TOASTS.notRecorded("ENOSPC: no space left on device"), cols) },
      { id: "declined-inline", name: "launching after declining the update, outside the fullscreen renderer", draw: (cols) => inlineToast("cs-update", TOASTS.declined("2026.11.2"), cols) }
    ]),
    chromeSurface("command", [
      { id: "not-lead", name: "running /cs-update in a teammate conversation", draw: () => commandReply("cs-update", "cs-update", "", REPLIES.notLead) },
      { id: "nothing-pending", name: "running /cs-update when this launch found no newer cs", draw: () => commandReply("cs-update", "cs-update", "", REPLIES.nothingPending) },
      { id: "notes-open", name: "running /cs-update to reopen the release notes", draw: () => commandReply("cs-update", "cs-update", "", REPLIES.notesOpen) }
    ]),
    chromeSurface("menu", [
      { id: "selected", name: "typing /cs-u in the prompt", draw: (cols) => menuRows([COMMANDS["cs-update"]], 0, cols) }
    ])
  ];
  function chromeSurface(slot, states) {
    return { id: `cs-update.${slot}`, mod: "cs-update", slot, source: "chrome", global: "CsUpdateSurfaces", states, parts: [] };
  }

  // docs/surfaces/cs-update.entry.ts
  globalThis.CsUpdateSurfaces = { surfaces };
})();
