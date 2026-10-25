(() => {
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
  var AMBER_LIGHT = "180,83,9";
  var AMBER_DARK = "253,230,138";
  var CRIT_LIGHT = "215,0,21";
  var CRIT_DARK = "255,69,58";
  var AMBER_AT = 10;
  var CRIT_AT = 5;
  function countdownColor(left, session, bg, theme) {
    if (left < CRIT_AT)
      return `rgb(${theme === "dark" ? CRIT_DARK : CRIT_LIGHT})`;
    if (left <= AMBER_AT)
      return amberColor(bg, theme);
    return paletteColor(session);
  }
  function amberColor(bg, theme) {
    const rgb = (bg ?? "").split(";").map((part) => /^\s*\d{1,3}\s*$/.test(part) ? Number(part) : NaN);
    const measured = rgb.length === 3 && rgb.every((v) => v <= 255);
    const light = measured ? 2126 * rgb[0] + 7152 * rgb[1] + 722 * rgb[2] >= 1530000 : theme !== "dark";
    return `rgb(${light ? AMBER_LIGHT : AMBER_DARK})`;
  }
  function bandState(facts) {
    if (facts.gate || facts.queueRunning)
      return "running";
    return facts.rotationDue ? "due" : "clear";
  }
  var MARK_INK = {
    running: () => `rgb(${SESSION_PALETTE.blue})`,
    due: amberColor,
    clear: () => `rgb(${SESSION_PALETTE.green})`
  };
  var MARK = "●";
  function paletteColor(name) {
    const rgb = name === undefined ? undefined : SESSION_PALETTE[name];
    return rgb === undefined ? undefined : `rgb(${rgb})`;
  }
  var TOAST_TASK_CHARS = 60;
  function cutTask(task) {
    return task.length > TOAST_TASK_CHARS ? `${task.slice(0, TOAST_TASK_CHARS)}…` : task;
  }
  var FINISH_OUTCOMES = new Set(["landed", "refused", "retired"]);
  var QUEUE_HERE = "In this conversation";
  var QUEUE_SUBAGENTS = "In subagents";
  var QUEUE_WORKFLOWS = "As workflows";
  var QUEUE_MODE_WORDS = { [QUEUE_HERE]: [], [QUEUE_SUBAGENTS]: ["subagents"], [QUEUE_WORKFLOWS]: ["workflow"] };
  var finishShown = new Set;
  function buildBandEntries(facts) {
    const entries = [];
    if (facts.featured !== undefined) {
      const { label, onPress } = facts.featured;
      entries.push(onPress === undefined ? { key: "cs-features", kind: "word", label } : { key: "cs-features", kind: "press", label, onPress });
    }
    if (facts.countdown !== undefined)
      entries.push({ key: "cs-countdown", kind: "word", label: `/clear in ${facts.countdown.seconds}s`, ink: { color: facts.countdown.ink } });
    if (facts.rotating)
      entries.push({ key: "cs-rotate", kind: "chord", label: facts.armed ? "/clear now" : "rotate", action: ROTATE_ACTION, onPress: facts.rotate });
    if (facts.wrapping)
      entries.push({ key: "cs-wrap", kind: "chord", label: "wrap", action: WRAP_ACTION, onPress: facts.wrap });
    if (facts.feed !== undefined)
      entries.push({ key: "cs-feed", kind: "chord", label: facts.feed.on ? "feed ✓" : "feed", action: FEED_ACTION, onPress: facts.feed.onPress, ink: facts.feed.on ? { text: "✓", color: facts.feed.color } : undefined });
    if (facts.waiting > 0)
      entries.push({ key: "cs-queue", kind: "press", label: `▤ queue ${facts.waiting} · start`, onPress: facts.queue });
    if (facts.gate !== undefined)
      entries.push({ key: "cs-gate", kind: "word", label: facts.gate });
    if (facts.queued > 0)
      entries.push({ key: "cs-queued", kind: "word", label: `▤ queue ${facts.queued}` });
    if (facts.mail > 0)
      entries.push({ key: "cs-mail", kind: "word", label: `mail ${facts.mail}` });
    return entries;
  }
  var RAIL_LABEL_MIN = 10;
  var READ_CAP = 4 * 1024 * 1024;
  var drawnRows = new Map;
  var shown = new Map;
  var denied = new Set;
  function drawBand(v, el) {
    const { Box, Text, Button } = el;
    const { entries, chords, own } = v;
    const actions = entries.flatMap((entry) => entry.kind === "chord" ? [entry.action] : []);
    const prefix = sharedPrefix(actions.map((action) => chords[action]));
    const firstChord = entries.findIndex((entry) => entry.kind === "chord" && chords[entry.action] !== undefined);
    const spelled = (action) => {
      const chord = chords[action];
      return chord === undefined ? undefined : prefix === undefined ? chord : chord.slice(prefix.length + 1);
    };
    const key = (action) => {
      const text = spelled(action);
      return text !== undefined && /* @__PURE__ */ h(Box, {
        marginRight: 1
      }, /* @__PURE__ */ h(Text, {
        bold: true,
        color: own
      }, text));
    };
    const sep = "  ·  ";
    const wordText = entries.map((entry, index) => {
      const chord = entry.kind === "chord" ? spelled(entry.action) : undefined;
      return `${index === firstChord && prefix !== undefined ? `${prefix}  ` : ""}${chord === undefined ? "" : `${chord} `}${entry.label}`;
    }).join(sep);
    const wordCells = cellWidth(wordText);
    const markCells = v.hasSurvey ? 0 : cellWidth(MARK) + 1;
    const budget = v.bodyColumns - 2 - markCells - (wordCells > 0 ? 3 + wordCells : 0);
    const rail = v.rail;
    const counted = rail === undefined ? undefined : railTicks(rail.prompts.length, budget, rail.bars);
    const ticks = rail === undefined || counted === undefined ? undefined : { ...rail, hidden: counted.hidden };
    const railCells = ticks === undefined ? 0 : (ticks.hidden > 0 ? `…${ticks.hidden}`.length : 0) + ticks.prompts.length - ticks.hidden;
    const labelCells = ticks === undefined ? 0 : budget - railCells - 2;
    const labeled = labelCells >= RAIL_LABEL_MIN;
    const hovering = labeled && v.surface === "terminal";
    const label = (prompts, i) => {
      const p = prompts[i];
      if (p === undefined)
        throw new Error(`cs: the band named prompt ${i} of ${prompts.length}`);
      return fitLeft(`#${i + 1} ${p.text}`, labelCells);
    };
    if (entries.length === 0 && ticks === undefined)
      return v.drawn;
    return /* @__PURE__ */ h(Box, {
      flexDirection: "column"
    }, v.drawn, /* @__PURE__ */ h(Box, {
      marginTop: 1
    }, /* @__PURE__ */ h(Box, {
      key: "cs-rotate-band",
      marginLeft: 2
    }, markCells > 0 && /* @__PURE__ */ h(Box, {
      key: "cs-mark",
      marginRight: 1
    }, /* @__PURE__ */ h(Text, {
      color: v.markColor
    }, MARK)), entries.flatMap((entry, index) => [
      index > 0 && /* @__PURE__ */ h(Text, {
        dimColor: true
      }, sep),
      index === firstChord && prefix !== undefined && /* @__PURE__ */ h(Box, {
        marginRight: 2
      }, /* @__PURE__ */ h(Text, {
        dimColor: true
      }, prefix)),
      entry.kind === "chord" && key(entry.action),
      entry.kind === "word" ? entry.ink === undefined ? /* @__PURE__ */ h(Text, {
        dimColor: true
      }, entry.label) : /* @__PURE__ */ h(Text, {
        bold: true,
        color: entry.ink.color
      }, entry.label) : entry.kind === "chord" ? entry.ink === undefined ? /* @__PURE__ */ h(Button, {
        key: entry.key,
        action: entry.action,
        plain: true,
        label: entry.label,
        onPress: entry.onPress
      }) : /* @__PURE__ */ h(Button, {
        key: entry.key,
        action: entry.action,
        plain: true,
        label: entry.label,
        onPress: entry.onPress
      }, entry.label.slice(0, -entry.ink.text.length), /* @__PURE__ */ h(Text, {
        color: entry.ink.color
      }, entry.ink.text)) : /* @__PURE__ */ h(Button, {
        key: entry.key,
        plain: true,
        label: entry.label,
        onPress: entry.onPress
      })
    ]), ticks !== undefined && /* @__PURE__ */ h(Box, {
      key: "cs-rail",
      marginLeft: wordCells > 0 ? 3 : 0
    }, ticks.hidden > 0 && /* @__PURE__ */ h(Text, {
      dimColor: true
    }, `…${ticks.hidden}`), ticks.prompts.slice(ticks.hidden).map((p, j) => {
      const i = ticks.hidden + j;
      if (i === ticks.named)
        return own === undefined ? /* @__PURE__ */ h(Text, {
          bold: true
        }, "┃") : /* @__PURE__ */ h(Text, {
          bold: true,
          color: own
        }, "┃");
      return /* @__PURE__ */ h(Button, {
        key: `cs-rail-${i}`,
        plain: true,
        dimColor: true,
        label: ticks.denied.has(p.uuid) ? "┆" : "│",
        hover: hovering ? { scope: `cs-rail-${i}`, dimColor: false } : undefined,
        onPress: () => ticks.jump(i)
      });
    })), ticks !== undefined && labeled && /* @__PURE__ */ h(Box, {
      width: labelCells,
      marginLeft: 2
    }, /* @__PURE__ */ h(Text, {
      dimColor: true,
      italic: true,
      wrap: "truncate-end"
    }, label(ticks.prompts, ticks.named)), hovering && ticks.prompts.map((_, i) => i >= ticks.hidden && i !== ticks.named && /* @__PURE__ */ h(Box, {
      position: "absolute",
      top: 0,
      left: 0,
      display: "none",
      hover: { scope: `cs-rail-${i}`, display: "flex" }
    }, /* @__PURE__ */ h(Text, {
      italic: true,
      wrap: "truncate-end"
    }, label(ticks.prompts, i))))))));
  }
  function sharedPrefix(chords) {
    const bound = chords.filter((chord) => chord !== undefined);
    if (bound.length === 0)
      return;
    const prefixes = bound.map((chord) => {
      const at = chord.lastIndexOf(" ");
      return at <= 0 ? undefined : chord.slice(0, at);
    });
    const first = prefixes[0];
    return first !== undefined && prefixes.every((prefix) => prefix === first) ? first : undefined;
  }
  var FEATURE_STATES = new Set(["ready", "staged", "locked", "dirty", "untracked", "vault-locked", "base-dirty", "merged"]);
  function stateWord(record) {
    return record.state === "ready" && record.ahead === 0 ? "no commits" : record.state;
  }
  function featuresWordOf(records) {
    if (records.length === 0)
      return;
    const count = `${records.length} ${records.length === 1 ? "feature" : "features"}`;
    const ready = records.filter((r) => stateWord(r) === "ready");
    const only = ready[0];
    if (ready.length === 1 && only !== undefined)
      return { label: `${count} · ${cutTask(only.task)} ready`, finish: only.task };
    if (ready.length > 1)
      return { label: `${count} · ${ready.length} ready`, finish: "" };
    const one = records[0];
    if (records.length === 1 && one !== undefined)
      return { label: `${count} · ${cutTask(one.task)} ${stateWord(one)}` };
    return { label: `${count} · none ready` };
  }
  function railTicks(count, budget, most) {
    for (let hidden = Math.max(0, count - most);hidden < count; hidden++) {
      if (count - hidden + (hidden > 0 ? `…${hidden}`.length : 0) <= budget)
        return { hidden };
    }
    return;
  }
  var WIDE = /[\u1100-\u115f\u2e80-\u303e\u3041-\u33ff\u3400-\u4dbf\u4e00-\u9fff\ua000-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]|[\u{1F300}-\u{1F64F}]|[\u{1F900}-\u{1F9FF}]|[\u{20000}-\u{3FFFD}]/u;
  var ZERO = /^[\p{M}\u200b-\u200f\ufe0f]+$/u;
  function graphemes(text) {
    const Segmenter = Intl.Segmenter;
    if (!Segmenter)
      return Array.from(text);
    return Array.from(new Segmenter("en", { granularity: "grapheme" }).segment(text), (piece) => piece.segment);
  }
  function cellsOf(grapheme) {
    if (ZERO.test(grapheme))
      return 0;
    return WIDE.test(grapheme.replace(/[\p{M}\u200b-\u200f\ufe0f]/gu, "")) ? 2 : 1;
  }
  function cellWidth(text) {
    return graphemes(text).reduce((sum, grapheme) => sum + cellsOf(grapheme), 0);
  }
  function cutToCells(text, width) {
    if (cellWidth(text) <= width)
      return text;
    let fitted = "";
    let used = 0;
    for (const grapheme of graphemes(text)) {
      const cells = cellsOf(grapheme);
      if (used + cells > width - 1)
        break;
      fitted += grapheme;
      used += cells;
    }
    return `${fitted}…`;
  }
  function fitLeft(text, width) {
    const fitted = cutToCells(text, width);
    return fitted + " ".repeat(Math.max(0, width - cellWidth(fitted)));
  }
  var ROTATE_ACTION = "strip:jump1";
  var WRAP_ACTION = "strip:jump2";
  var FEED_ACTION = "strip:jump3";

  // docs/surfaces/registry.ts
  function elements() {
    const el = globalThis.LabElements;
    if (el === undefined)
      throw new Error("the lab shim (docs/surfaces/shim.js) is not loaded: LabElements is undefined");
    return el;
  }

  // docs/surfaces/cs.fixtures.ts
  var CHORDS = { rotate: "ctrl+x 1", wrap: "ctrl+x 2", feed: "ctrl+x 3" };
  var BAND_BARS = 10;
  var RESERVED = 5;
  var PROMPTS = [
    "fix the login redirect",
    "add a retry to the upload client",
    "why does the cache miss on first load",
    "rename the settings module",
    "write the migration for the orders table",
    "make the sidebar collapse on narrow screens",
    "explain the session timeout",
    "drop the unused date helpers",
    "speed up the search index build",
    "add a dark theme to the docs",
    "check the release notes for typos",
    "split the report into two pages",
    "move the config loader out of main",
    "run the full suite and fix what fails"
  ];
  function facts(over) {
    return { rotating: false, armed: false, wrapping: false, waiting: 0, queued: 0, mail: 0, chords: CHORDS, due: false, queueRunning: false, survey: false, colour: "orange", surface: "terminal", ...over };
  }
  function countdownStep(seconds) {
    return seconds < CRIT_AT ? "crit" : seconds <= AMBER_AT ? "amber" : "session";
  }
  var press = () => {};
  var ACTION = { rotate: ROTATE_ACTION, wrap: WRAP_ACTION, feed: FEED_ACTION };
  function viewOf(f, cols, theme) {
    const el = elements();
    const own = paletteColor(f.colour ?? undefined);
    const entries = buildBandEntries({
      featured: f.featured && { label: f.featured.label, onPress: f.featured.pressable ? press : undefined },
      countdown: f.countdown && { seconds: f.countdown.seconds, ink: countdownColor(f.countdown.seconds, f.colour ?? undefined, undefined, theme) },
      rotating: f.rotating,
      armed: f.armed,
      wrapping: f.wrapping,
      waiting: f.waiting,
      gate: f.gate,
      queued: f.queued,
      mail: f.mail,
      feed: f.feed && { on: f.feed.on, color: own, onPress: press },
      rotate: press,
      wrap: press,
      queue: press
    });
    const chords = {};
    for (const role of ["rotate", "wrap", "feed"]) {
      const chord = f.chords[role];
      if (chord !== undefined)
        chords[ACTION[role]] = chord;
    }
    const prompts = (f.rail?.prompts ?? []).map((text, i) => ({ uuid: `p${i}`, text }));
    const rail = f.rail && prompts.length > 1 ? { prompts, named: f.rail.named, denied: new Set(f.rail.refused.map((i) => `p${i}`)), bars: BAND_BARS, jump: async () => {} } : undefined;
    const markColor = MARK_INK[bandState({ gate: f.gate !== undefined, queueRunning: f.queueRunning, rotationDue: f.due })](undefined, theme);
    const drawn = f.survey ? el.Box({ children: [el.Text({ dimColor: true, children: "How is Claude doing this session? (the engine draws its survey here)" })] }) : el.Box({});
    return { drawn, entries, chords, own, markColor, hasSurvey: f.survey, bodyColumns: cols - RESERVED, surface: f.surface, rail };
  }
  function band(f, cols, theme) {
    return drawBand(viewOf(f, cols, theme), elements());
  }
  var feature = (state, ahead = 2) => ({ task: "fix-auth", ahead, state });
  var word = (records, pressable) => {
    const w = featuresWordOf(records);
    if (w === undefined)
      throw new Error("cs fixture: featuresWordOf drew no word for " + JSON.stringify(records));
    return { label: w.label, pressable: pressable && w.finish !== undefined };
  };
  var DUE = { rotating: true, wrapping: true, due: true };
  var STATES = [
    { id: "idle", name: "nothing to say", facts: facts({}) },
    { id: "rotate-due", name: "context past the threshold", facts: facts(DUE) },
    { id: "countdown", name: "handoff armed, counting down to the /clear", facts: facts({ countdown: { seconds: 7 }, rotating: true, armed: true, due: true }) },
    { id: "armed-clear-now", name: "handoff armed, waiting for a press", facts: facts({ rotating: true, armed: true, due: true }) },
    { id: "feed-off", name: "idle, the feed mod installed and off", facts: facts({ feed: { on: false } }) },
    { id: "feed-on", name: "idle, the feed on", facts: facts({ feed: { on: true } }) },
    { id: "queue-waiting", name: "tasks queued, nothing running them", facts: facts({ waiting: 3 }) },
    { id: "queue-running", name: "the queue running its tasks", facts: facts({ queued: 3, queueRunning: true }) },
    { id: "gate-running", name: "a /finish gate running", facts: facts({ gate: "finishing fix-auth · gate 1m 12s" }) },
    { id: "mail", name: "mail from another session", facts: facts({ mail: 2 }) },
    { id: "features-ready", name: "a feature ready to finish", facts: facts({ featured: word([feature("ready"), feature("dirty"), feature("merged")], true) }) },
    { id: "everything", name: "every word an idle band can carry at once", facts: facts({
      featured: word([feature("ready"), feature("dirty"), feature("merged")], true),
      ...DUE,
      feed: { on: true },
      waiting: 2,
      mail: 1,
      rail: { prompts: PROMPTS.slice(0, 6), named: 5, refused: [] }
    }) },
    { id: "rail-few", name: "three prompts on the rail", facts: facts({ rail: { prompts: PROMPTS.slice(0, 3), named: 2, refused: [] } }) },
    { id: "rail-many", name: "fourteen prompts, the oldest folded", facts: facts({ rail: { prompts: PROMPTS.slice(), named: 13, refused: [5] } }) },
    { id: "no-chords", name: "context past the threshold, keybindings unbound", facts: facts({ ...DUE, chords: {} }) }
  ];
  var surfaces = [{
    id: "cs.AbovePrompt",
    mod: "cs",
    slot: "AbovePrompt",
    source: "generated",
    global: "CsSurfaces",
    needs: ["hover", "focus inverse", "engine drawing"],
    chrome: { kind: "above-prompt" },
    states: STATES.map((s) => ({ id: s.id, name: s.name, draw: (cols, theme) => band(s.facts, cols, theme) })),
    parts: [
      { id: "band-mark", name: "band mark", state: "rotate-due", path: [1, 0, 0] },
      { id: "chord", name: "chord key", state: "rotate-due", path: [1, 0, 2] },
      { id: "chord-word", name: "chord word Button", state: "rotate-due", path: [1, 0, 3] },
      { id: "countdown", name: "countdown word", state: "countdown", path: [1, 0, 1] },
      { id: "rail-tick", name: "rail tick", state: "rail-few", path: [1, 0, 1, 0] },
      { id: "prompt-label", name: "prompt label", state: "rail-few", path: [1, 0, 2] }
    ]
  }];

  // docs/surfaces/cs.entry.ts
  globalThis.CsSurfaces = { surfaces, STATES, CHORDS, PROMPTS, band, countdownStep, facts };
})();
