// ABOUTME: The cs band's states and the drawings proposed for it, as engine trees for docs/mods-design-lab.html.
// ABOUTME: Loaded by the lab as a plain script and by bun tests through module.exports; draw functions are pure.
(function (root) {
  "use strict";

  // The keybindings the installer writes (CS_ROTATE_WRAP_KEYS in lib/01-manifests.sh).
  var CHORDS = { rotate: "ctrl+x 1", wrap: "ctrl+x 2", feed: "ctrl+x 3" };

  var PROMPTS = [
    "fix the login redirect", "add a retry to the upload client", "why does the cache miss on first load",
    "rename the settings module", "write the migration for the orders table", "make the sidebar collapse on narrow screens",
    "explain the session timeout", "drop the unused date helpers", "speed up the search index build",
    "add a dark theme to the docs", "check the release notes for typos", "split the report into two pages",
    "move the config loader out of main", "run the full suite and fix what fails",
  ];

  // A band's facts: register.tsx's BandFacts without the press callbacks.
  // `featured.pressable` stands for an onPress; `countdown.ink` names the
  // count's ramp step (session, amber, crit), which a drawing resolves for its
  // theme; `rail` is what the prompt bars draw from; `chords` the bound keys.
  function facts(over) {
    var base = { rotating: false, armed: false, wrapping: false, waiting: 0, queued: 0, mail: 0, chords: CHORDS };
    return Object.assign(base, over);
  }

  var STATES = [
    { id: "idle", name: "nothing to say", facts: facts({}) },
    { id: "rotate-due", name: "context past the threshold", facts: facts({ rotating: true, wrapping: true }) },
    { id: "countdown", name: "handoff armed, counting down to the /clear", facts: facts({ countdown: { seconds: 7, ink: "amber" }, rotating: true, armed: true }) },
    { id: "armed-clear-now", name: "handoff armed, waiting for a press", facts: facts({ rotating: true, armed: true }) },
    { id: "feed-off", name: "idle, the feed mod installed and off", facts: facts({ feed: { on: false } }) },
    { id: "feed-on", name: "idle, the feed on", facts: facts({ feed: { on: true } }) },
    { id: "queue-waiting", name: "tasks queued, nothing running them", facts: facts({ waiting: 3 }) },
    { id: "queue-running", name: "the queue running its tasks", facts: facts({ queued: 3 }) },
    { id: "gate-running", name: "a /finish gate running", facts: facts({ gate: "finishing fix-auth · gate 1m 12s" }) },
    { id: "mail", name: "mail from another session", facts: facts({ mail: 2 }) },
    { id: "features-ready", name: "a feature ready to finish", facts: facts({ featured: { label: "3 features · fix-auth ready", pressable: true } }) },
    // Every word an idle band can carry at once: the most a line is asked to hold.
    { id: "everything", name: "every word an idle band can carry at once", facts: facts({
      featured: { label: "3 features · fix-auth ready", pressable: true }, rotating: true, wrapping: true,
      feed: { on: true }, waiting: 2, mail: 1, rail: { prompts: PROMPTS.slice(0, 6), named: 5, refused: [] },
    }) },
    { id: "rail-few", name: "three prompts on the rail", facts: facts({ rail: { prompts: PROMPTS.slice(0, 3), named: 2, refused: [] } }) },
    { id: "rail-many", name: "fourteen prompts, the oldest folded", facts: facts({ rail: { prompts: PROMPTS.slice(), named: 13, refused: [5] } }) },
    { id: "no-chords", name: "context past the threshold, keybindings unbound", facts: facts({ rotating: true, wrapping: true, chords: {} }) },
  ];

  // ---- the band's vocabulary, as register.tsx spells it ----
  // cs.bandBars' default (mods/cs/.claude-plugin/plugin.json) and the fewest
  // cells after the rail that name a prompt.
  var BAND_BARS = 10;
  var RAIL_LABEL_MIN = 10;
  var MARK = "●";
  var SEP = "  ·  ";
  // The engine actions the chord Buttons answer to (ROTATE_ACTION and its siblings).
  var ACTIONS = { rotate: "strip:jump1", wrap: "strip:jump2", feed: "strip:jump3" };

  function T(props, text) { return { type: "Text", props: props, children: [text] }; }
  function Bx(props, kids) { return { type: "Box", props: props, children: kids.filter(Boolean) }; }
  function Btn(props, kids) { return { type: "Button", props: props, children: kids || [] }; }
  // Every glyph the band draws takes one cell, so a code point is a cell.
  function cells(text) { return Array.from(text).length; }

  // The inks, by the lab painter's names. The session colour stands as
  // `claude` (the session palette's orange is the same rgb); amber and crit
  // pivot on the theme as the bar's do. The session palette's blue and green
  // are not names the painter knows, so the mark's running and clear inks
  // stand as `suggestion` and `success`.
  function inks(theme) {
    var dark = theme === "dark";
    return { own: "claude", amber: dark ? "AMBER_D" : "AMBER_L", crit: dark ? "CRIT_D" : "CRIT_L", running: "suggestion", clear: "success" };
  }
  function rampInk(step, theme) {
    var ink = inks(theme);
    return step === "session" ? ink.own : ink[step];
  }

  // bandState over the facts a drawing has: the gate or the queue's own word
  // means something runs, a rotate key means a rotation is due.
  function bandState(f) {
    if (f.gate !== undefined || f.queued > 0) return "running";
    return f.rotating ? "due" : "clear";
  }
  function markInk(f, theme) {
    var ink = inks(theme), state = bandState(f);
    return state === "running" ? ink.running : state === "due" ? ink.amber : ink.clear;
  }

  // buildBandEntries, with `role` naming the chord a key answers to.
  function entriesOf(f) {
    var out = [];
    if (f.featured !== undefined) out.push({ key: "cs-features", kind: f.featured.pressable ? "press" : "word", label: f.featured.label });
    if (f.countdown !== undefined) out.push({ key: "cs-countdown", kind: "word", label: "/clear in " + f.countdown.seconds + "s", ink: f.countdown.ink });
    if (f.rotating) out.push({ key: "cs-rotate", kind: "chord", role: "rotate", label: f.armed ? "/clear now" : "rotate" });
    if (f.wrapping) out.push({ key: "cs-wrap", kind: "chord", role: "wrap", label: "wrap" });
    if (f.feed !== undefined) out.push({ key: "cs-feed", kind: "chord", role: "feed", label: f.feed.on ? "feed ✓" : "feed", check: f.feed.on });
    if (f.waiting > 0) out.push({ key: "cs-queue", kind: "press", label: "▤ queue " + f.waiting + " · start" });
    if (f.gate !== undefined) out.push({ key: "cs-gate", kind: "word", label: f.gate });
    if (f.queued > 0) out.push({ key: "cs-queued", kind: "word", label: "▤ queue " + f.queued });
    if (f.mail > 0) out.push({ key: "cs-mail", kind: "word", label: "mail " + f.mail });
    return out;
  }

  function sharedPrefix(chords) {
    var bound = chords.filter(function (c) { return c !== undefined; });
    if (bound.length === 0) return undefined;
    var prefixes = bound.map(function (c) { var at = c.lastIndexOf(" "); return at <= 0 ? undefined : c.slice(0, at); });
    var first = prefixes[0];
    return first !== undefined && prefixes.every(function (p) { return p === first; }) ? first : undefined;
  }

  function railTicks(count, budget, most) {
    for (var hidden = Math.max(0, count - most); hidden < count; hidden++) {
      if (count - hidden + (hidden > 0 ? cells("…" + hidden) : 0) <= budget) return { hidden: hidden };
    }
    return undefined;
  }

  function fitLeft(text, width) {
    var fitted = cells(text) <= width ? text : Array.from(text).slice(0, Math.max(0, width - 1)).join("") + "…";
    return fitted + " ".repeat(Math.max(0, width - cells(fitted)));
  }

  // One entry as the shipped band draws it: a word dim (a ramp ink bold), a
  // chord or a press a plain Button, the feed's check in the session colour.
  function entryNode(e, theme) {
    if (e.kind === "word") return e.ink === undefined ? T({ dimColor: true }, e.label) : T({ bold: true, color: rampInk(e.ink, theme) }, e.label);
    if (e.kind === "press") return Btn({ key: e.key, plain: true, label: e.label });
    var props = { key: e.key, action: ACTIONS[e.role], plain: true, label: e.label };
    return e.check ? Btn(props, [e.label.slice(0, -1), T({ color: inks(theme).own }, "✓")]) : Btn(props);
  }

  // The shipped band's words: a shared chord prefix spelled once, dim, before
  // the first bound key; each key bold in the session colour; `sep` between
  // entries. Returns the nodes and the cells they take.
  function actions(f, entries, theme, sep) {
    var chordOf = function (e) { return e.kind === "chord" ? f.chords[e.role] : undefined; };
    var prefix = sharedPrefix(entries.map(chordOf));
    var first = entries.findIndex(function (e) { return chordOf(e) !== undefined; });
    var spelled = function (e) {
      var c = chordOf(e);
      return c === undefined ? undefined : prefix === undefined ? c : c.slice(prefix.length + 1);
    };
    var nodes = [], text = [];
    entries.forEach(function (e, i) {
      if (i > 0) nodes.push(T({ dimColor: true }, sep));
      var lead = i === first && prefix !== undefined;
      if (lead) nodes.push(Bx({ marginRight: 2 }, [T({ dimColor: true }, prefix)]));
      var k = spelled(e);
      if (k !== undefined) nodes.push(Bx({ marginRight: 1 }, [T({ bold: true, color: inks(theme).own }, k)]));
      nodes.push(entryNode(e, theme));
      text.push((lead ? prefix + "  " : "") + (k === undefined ? "" : k + " ") + e.label);
    });
    return { nodes: nodes, cells: cells(text.join(sep)) };
  }

  // The rail's bars after `hidden` folded prompts: `…N` dim, `┃` bold in the
  // session colour for the named prompt, `┆` for one a jump was refused, `│`
  // otherwise, each a Button scoped for its hover card.
  function railNodes(rail, hidden, theme) {
    var out = [];
    if (hidden > 0) out.push(T({ dimColor: true }, "…" + hidden));
    for (var i = hidden; i < rail.prompts.length; i++) {
      if (i === rail.named) out.push(T({ bold: true, color: inks(theme).own }, "┃"));
      else out.push(Btn({ key: "cs-rail-" + i, plain: true, dimColor: true, label: rail.refused.indexOf(i) >= 0 ? "┆" : "│", hover: { scope: "cs-rail-" + i, dimColor: false } }));
    }
    return out;
  }
  function railCells(rail, hidden) { return (hidden > 0 ? cells("…" + hidden) : 0) + rail.prompts.length - hidden; }
  function promptLabel(rail, width) { return fitLeft("#" + (rail.named + 1) + " " + rail.prompts[rail.named], width); }
  function hasRail(f) { return f.rail !== undefined && f.rail.prompts.length > 1; }

  // The band as the draw site composes it: a blank row, then at two cells in
  // the mark, the words, the rail after a 3-cell gap, and the named prompt in
  // what the line leaves. The hover cards that swap a prompt in under the
  // pointer are left out: they draw nothing until a bar is hovered.
  function drawShipped(f, cols, theme) {
    var entries = entriesOf(f);
    var words = actions(f, entries, theme, SEP);
    var budget = cols - 2 - 2 - (words.cells > 0 ? 3 + words.cells : 0);
    var ticks = hasRail(f) ? railTicks(f.rail.prompts.length, budget, BAND_BARS) : undefined;
    if (entries.length === 0 && ticks === undefined) return null;
    var labelCells = ticks === undefined ? 0 : budget - railCells(f.rail, ticks.hidden) - 2;
    return Bx({ flexDirection: "column" }, [
      Bx({ marginTop: 1 }, [
        Bx({ key: "cs-rotate-band", marginLeft: 2 }, [
          Bx({ key: "cs-mark", marginRight: 1 }, [T({ color: markInk(f, theme) }, MARK)]),
        ].concat(words.nodes, [
          ticks !== undefined && Bx({ key: "cs-rail", marginLeft: words.cells > 0 ? 3 : 0 }, railNodes(f.rail, ticks.hidden, theme)),
          labelCells >= RAIL_LABEL_MIN && Bx({ width: labelCells, marginLeft: 2 }, [T({ dimColor: true, italic: true, wrap: "truncate-end" }, promptLabel(f.rail, labelCells))]),
        ])),
      ]),
    ]);
  }

  var VARIANTS = [
    { id: "shipped", name: "Shipped", note: "The band register.tsx draws today. With every word at once it clips at 60 and at 80: the line has no rule for what to drop.", draw: drawShipped },
  ];

  var api = { STATES: STATES, VARIANTS: VARIANTS };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.BandVariants = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
