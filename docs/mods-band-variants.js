// ABOUTME: The cs band's states and the drawings proposed for it, as engine trees for docs/mods-design-lab.html.
// ABOUTME: The states and the shipped band come from the cs mod's bundle (docs/surfaces/cs.js), loaded first; the sketches are pure.
(function (root) {
  "use strict";

  // The band's facts and the band itself, from the cs mod's own code: the
  // catalogue is the first fifteen of the band surface's states, the ones
  // every sketch is drawn in.
  var cs = root.CsSurfaces;
  if (!cs) throw new Error("the band variants need the cs mod's bundle (docs/surfaces/cs.js) loaded first");
  var STATES = cs.STATES.slice(0, cs.CATALOGUE);

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
  // register.tsx's cellWidth: a grapheme is two cells when it is wide (CJK,
  // Hangul, fullwidth forms, most emoji), none when it only marks another.
  // The engine below still counts a code point as a cell, so a wide glyph
  // lays out one cell narrower than the terminal draws it.
  var WIDE = /[ᄀ-ᅟ⺀-〾ぁ-㏿㐀-䶿一-鿿ꀀ-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]|[\u{1F300}-\u{1F64F}]|[\u{1F900}-\u{1F9FF}]|[\u{20000}-\u{3FFFD}]/u;
  var ZERO = /^[\p{M}​-‏️]+$/u;
  function graphemes(text) {
    if (typeof Intl === "undefined" || !Intl.Segmenter) return Array.from(text);
    return Array.from(new Intl.Segmenter("en", { granularity: "grapheme" }).segment(text), function (piece) { return piece.segment; });
  }
  function cellsOf(grapheme) {
    if (ZERO.test(grapheme)) return 0;
    return WIDE.test(grapheme.replace(/[\p{M}​-‏️]/gu, "")) ? 2 : 1;
  }
  function cells(text) { return graphemes(text).reduce(function (sum, g) { return sum + cellsOf(g); }, 0); }

  // The inks, by the lab painter's names. The session colour stands as
  // `claude`, 215,119,87, two steps of red off the session palette's orange
  // (217,119,87, which RAW.CORAL matches exactly): `claude` is a theme key
  // the JSX prints as a string, where CORAL would print as a const the mod
  // must declare. Amber and crit
  // pivot on the theme as the bar's do. The session palette's blue and green
  // are not names the painter knows, so the mark's running and clear inks
  // stand as `suggestion` and `success`.
  function inks(theme) {
    var dark = theme === "dark";
    return { own: "claude", amber: dark ? "AMBER_D" : "AMBER_L", crit: dark ? "CRIT_D" : "CRIT_L", running: "suggestion", clear: "success" };
  }
  function rampInk(seconds, theme) {
    var ink = inks(theme), step = cs.countdownStep(seconds);
    return step === "session" ? ink.own : ink[step];
  }

  // The mark's state from the facts the band's own bandState reads: a gate or
  // the queue running, else a rotation due, else nothing.
  function bandState(f) {
    if (f.gate !== undefined || f.queueRunning) return "running";
    return f.due ? "due" : "clear";
  }
  function markInk(f, theme) {
    var ink = inks(theme), state = bandState(f);
    return state === "running" ? ink.running : state === "due" ? ink.amber : ink.clear;
  }

  // buildBandEntries, with `role` naming the chord a key answers to.
  function entriesOf(f) {
    var out = [];
    if (f.featured !== undefined) out.push({ key: "cs-features", kind: f.featured.pressable ? "press" : "word", label: f.featured.label });
    if (f.countdown !== undefined) out.push({ key: "cs-countdown", kind: "word", label: "/clear in " + f.countdown.seconds + "s", seconds: f.countdown.seconds });
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

  // `text` at most `width` cells, ending in `…` when anything was cut.
  function cut(text, width) {
    if (cells(text) <= width) return text;
    var fitted = "", used = 0;
    for (var g of graphemes(text)) {
      if (used + cellsOf(g) > width - 1) break;
      fitted += g;
      used += cellsOf(g);
    }
    return fitted + "…";
  }
  function fitLeft(text, width) {
    var fitted = cut(text, width);
    return fitted + " ".repeat(Math.max(0, width - cells(fitted)));
  }

  // One entry as the shipped band draws it: a word dim (the count bold in its
  // ramp ink), a chord or a press a plain Button, the feed's check in the
  // session colour.
  function entryNode(e, theme, wordStyle) {
    if (e.kind === "word") return e.seconds === undefined ? T(wordStyle || { dimColor: true }, e.label) : T({ bold: true, color: rampInk(e.seconds, theme) }, e.label);
    if (e.kind === "press") return Btn({ key: e.key, plain: true, label: e.label });
    var props = { key: e.key, action: ACTIONS[e.role], plain: true, label: e.label };
    return e.check ? Btn(props, [e.label.slice(0, -1), T({ color: inks(theme).own }, "✓")]) : Btn(props);
  }

  // A chord's key, bold in the session colour one cell before its word, and
  // the word's Button, held in one Box so the two move as one.
  function chord(e, key, button, theme) {
    return Bx({ key: "cs-chord-" + e.role }, [Bx({ marginRight: 1 }, [T({ bold: true, color: inks(theme).own }, key)]), button]);
  }

  // The shipped band's words: a shared chord prefix spelled once, dim,
  // `prefixGap` cells (2 on the shipped band) before the first bound key; each
  // key bold in the session colour; `sep` between entries. Returns the nodes
  // and the cells they take.
  function actions(f, entries, theme, sep, prefixGap) {
    var gap = prefixGap === undefined ? 2 : prefixGap;
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
      if (lead) nodes.push(Bx({ marginRight: gap }, [T({ dimColor: true }, prefix)]));
      var k = spelled(e);
      nodes.push(k === undefined ? entryNode(e, theme) : chord(e, k, entryNode(e, theme), theme));
      text.push((lead ? prefix + " ".repeat(gap) : "") + (k === undefined ? "" : k + " ") + e.label);
    });
    return { nodes: nodes, cells: cells(text.join(sep)) };
  }

  // The rail's bars after `hidden` folded prompts: `…N` dim, `┃` bold in the
  // session colour for the named prompt, `┆` for one a jump was refused, `│`
  // otherwise, each a Button scoped for its hover card.
  function railNodes(rail, hidden, namedInk) {
    var out = [];
    if (hidden > 0) out.push(T({ dimColor: true }, "…" + hidden));
    for (var i = hidden; i < rail.prompts.length; i++) {
      if (i === rail.named) out.push(T(namedInk === undefined ? { bold: true } : { bold: true, color: namedInk }, "┃"));
      else out.push(Btn({ key: "cs-rail-" + i, plain: true, dimColor: true, label: rail.refused.indexOf(i) >= 0 ? "┆" : "│", hover: { scope: "cs-rail-" + i, dimColor: false } }));
    }
    return out;
  }
  function railCells(rail, hidden) { return (hidden > 0 ? cells("…" + hidden) : 0) + rail.prompts.length - hidden; }
  function promptName(rail) { return "#" + (rail.named + 1) + " " + rail.prompts[rail.named]; }
  function promptLabel(rail, width) { return fitLeft(promptName(rail), width); }
  function hasRail(f) { return f.rail !== undefined && f.rail.prompts.length > 1; }

  // The rail and the named prompt in `budget` cells, `gap` cells after the
  // words, as the shipped band fits them: undefined when no bar fits; the
  // label, padded to what is left, only when that is RAIL_LABEL_MIN or more.
  function railRun(f, budget, namedInk, gap) {
    var ticks = hasRail(f) ? railTicks(f.rail.prompts.length, budget, BAND_BARS) : undefined;
    if (ticks === undefined) return undefined;
    var labelCells = budget - railCells(f.rail, ticks.hidden) - 2;
    return [
      Bx({ key: "cs-rail", marginLeft: gap }, railNodes(f.rail, ticks.hidden, namedInk)),
      labelCells >= RAIL_LABEL_MIN && Bx({ width: labelCells, marginLeft: 2 }, [T({ dimColor: true, italic: true, wrap: "truncate-end" }, promptLabel(f.rail, labelCells))]),
    ];
  }

  // A band's line under its blank row, two cells in.
  function band(nodes) {
    return Bx({ flexDirection: "column" }, [Bx({ marginTop: 1 }, [Bx({ key: "cs-rotate-band", marginLeft: 2 }, nodes)])]);
  }

  // Words alone in the default ink, three cells apart: no mark, no key beside
  // its word; the bound chords trail as one dim hint (`ctrl+x 1 2`), in the
  // order of their words. A line too long drops the hint, then folds its last
  // words into `…N`, the rail's own fold; the rail is a word, `prompt N of M`.
  function drawQuiet(f, cols, theme) {
    var entries = entriesOf(f);
    var items = entries.map(function (e) { return { node: entryNode(e, theme, {}), cells: cells(e.label) }; });
    if (hasRail(f)) {
      var where = "prompt " + (f.rail.named + 1) + " of " + f.rail.prompts.length;
      items.push({ node: T({ dimColor: true, italic: true }, where), cells: cells(where) });
    }
    if (items.length === 0) return null;
    var bound = entries.map(function (e) { return e.kind === "chord" ? f.chords[e.role] : undefined; }).filter(function (c) { return c !== undefined; });
    var prefix = sharedPrefix(bound);
    var hint = bound.length === 0 ? "" : prefix === undefined ? bound.join(" ") : prefix + " " + bound.map(function (c) { return c.slice(prefix.length + 1); }).join(" ");
    var gap = "   ";
    var room = cols - 2;
    var span = function (n) { return items.slice(0, n).reduce(function (sum, it) { return sum + it.cells; }, 0) + gap.length * Math.max(0, n - 1); };
    var kept = items.length;
    var withHint = hint !== "" && span(kept) + 4 + cells(hint) <= room;
    var fold = function (n) { return n === items.length ? 0 : gap.length + cells("…" + (items.length - n)); };
    while (kept > 1 && span(kept) + fold(kept) > room) kept--;
    var nodes = [];
    items.slice(0, kept).forEach(function (it, i) {
      if (i > 0) nodes.push(T({}, gap));
      nodes.push(it.node);
    });
    if (kept < items.length) nodes.push(T({ dimColor: true }, gap + "…" + (items.length - kept)));
    if (withHint) nodes.push(Bx({ marginLeft: 4 }, [T({ dimColor: true }, hint)]));
    return band(nodes);
  }

  // The bound keys lead, each digit bold in the session colour and the only
  // coloured ink on the line, its word beside it in the default ink; a shared
  // prefix is spelled once, dim, before them. The other words follow, dim,
  // two cells apart, then the rail with its named bar bold and uncoloured.
  function drawKeysFirst(f, cols, theme) {
    var entries = entriesOf(f);
    var chordOf = function (e) { return e.kind === "chord" ? f.chords[e.role] : undefined; };
    var ordered = entries.filter(function (e) { return e.kind === "chord"; }).concat(entries.filter(function (e) { return e.kind !== "chord"; }));
    var prefix = sharedPrefix(ordered.map(chordOf));
    var nodes = [], text = [];
    if (prefix !== undefined) { nodes.push(Bx({ marginRight: 2 }, [T({ dimColor: true }, prefix)])); text.push(prefix + "  "); }
    ordered.forEach(function (e, i) {
      if (i > 0) { nodes.push(T({}, "  ")); text.push("  "); }
      var c = chordOf(e);
      var k = c === undefined ? undefined : prefix === undefined ? c : c.slice(prefix.length + 1);
      if (k !== undefined) text.push(k + " ");
      if (e.kind === "chord") {
        var button = Btn({ key: e.key, action: ACTIONS[e.role], plain: true, label: e.label });
        nodes.push(k === undefined ? button : chord(e, k, button, theme));
      } else if (e.kind === "press") nodes.push(Btn({ key: e.key, plain: true, label: e.label }));
      else nodes.push(T(e.seconds === undefined ? { dimColor: true } : { bold: true }, e.label));
      text.push(e.label);
    });
    var wordCells = cells(text.join(""));
    var rail = railRun(f, cols - 2 - (wordCells > 0 ? 3 + wordCells : 0), undefined, wordCells > 0 ? 3 : 0);
    if (entries.length === 0 && rail === undefined) return null;
    return band(nodes.concat(rail || []));
  }

  // What the band is in, as a word: the mark's states spelled out, with what
  // runs and whether the handoff is armed.
  function statusWord(f) {
    if (f.gate !== undefined) return "running gate";
    if (f.queued > 0) return "running queue";
    if (f.armed) return "armed";
    return f.rotating ? "due" : "idle";
  }

  // The state's word leads in the mark's ink, bold, where the mark stood;
  // the shipped words and rail follow it.
  function drawStatusFirst(f, cols, theme) {
    var entries = entriesOf(f);
    var status = statusWord(f);
    var words = actions(f, entries, theme, SEP);
    var rail = railRun(f, cols - 2 - cells(status) - 2 - (words.cells > 0 ? 3 + words.cells : 0), inks(theme).own, words.cells > 0 ? 3 : 0);
    if (entries.length === 0 && rail === undefined) return null;
    return band([Bx({ key: "cs-status", marginRight: 2 }, [T({ bold: true, color: markInk(f, theme) }, status)])].concat(words.nodes, rail || []));
  }

  // Two zones across the whole line, pushed apart by space-between: the mark
  // and the shipped words on the left; on the right the named prompt, cut to
  // what is left, then the rail, its newest bar at the right edge.
  function drawTwoZone(f, cols, theme) {
    var entries = entriesOf(f);
    var words = actions(f, entries, theme, SEP);
    var leftCells = 2 + words.cells;
    var budget = cols - 2 - leftCells - 3;
    var ticks = hasRail(f) ? railTicks(f.rail.prompts.length, budget, BAND_BARS) : undefined;
    if (entries.length === 0 && ticks === undefined) return null;
    var right = [], rightCells = 0;
    if (ticks !== undefined) {
      var room = budget - railCells(f.rail, ticks.hidden) - 2;
      var name = cut(promptName(f.rail), room);
      if (room >= RAIL_LABEL_MIN) {
        right.push(Bx({ marginRight: 2 }, [T({ dimColor: true, italic: true }, name)]));
        rightCells += cells(name) + 2;
      }
      right.push(Bx({ key: "cs-rail" }, railNodes(f.rail, ticks.hidden, inks(theme).own)));
      rightCells += railCells(f.rail, ticks.hidden);
    }
    return band([Bx({ width: Math.max(cols - 2, leftCells + (rightCells > 0 ? 3 + rightCells : 0)), justifyContent: "space-between" }, [
      Bx({ key: "cs-actions" }, [Bx({ key: "cs-mark", marginRight: 1 }, [T({ color: markInk(f, theme) }, MARK)])].concat(words.nodes)),
      right.length > 0 && Bx({ key: "cs-where" }, right),
    ])]);
  }

  // The rail leads and takes the line: its bars at the inset, the named
  // prompt growing into whatever the words leave. The words fold to the right
  // edge, compact (the prefix one cell from its key, two cells between
  // words), and the mark ends the line.
  function drawRailFirst(f, cols, theme) {
    var entries = entriesOf(f);
    var words = actions(f, entries, theme, "  ", 1);
    var rightCells = words.cells + 2;
    var budget = cols - 2 - rightCells - 3;
    var ticks = hasRail(f) ? railTicks(f.rail.prompts.length, budget, BAND_BARS) : undefined;
    if (entries.length === 0 && ticks === undefined) return null;
    var left = [], leftCells = 0;
    if (ticks !== undefined) {
      left.push(Bx({ key: "cs-rail" }, railNodes(f.rail, ticks.hidden, inks(theme).own)));
      leftCells += railCells(f.rail, ticks.hidden);
      var room = budget - leftCells - 2;
      var name = cut(promptName(f.rail), room);
      if (room >= RAIL_LABEL_MIN) {
        left.push(Bx({ marginLeft: 2 }, [T({ dimColor: true, italic: true }, name)]));
        leftCells += 2 + cells(name);
      }
    }
    return band([Bx({ width: Math.max(cols - 2, leftCells + (leftCells > 0 ? 3 : 0) + rightCells), justifyContent: "flex-end" }, [
      left.length > 0 && Bx({ key: "cs-where", flexGrow: 1 }, left),
      Bx({ key: "cs-actions" }, words.nodes.concat([Bx({ key: "cs-mark", marginLeft: 1 }, [T({ color: markInk(f, theme) }, MARK)])])),
    ])]);
  }

  // The old presets' capsule around the shipped words: a round border in the
  // mark's ink, which carries the state, so no mark; the rail and the named
  // prompt, cut and unpadded, inside it. The border is the band's separation
  // from the transcript, so no blank row above.
  function drawCapsule(f, cols, theme) {
    var entries = entriesOf(f);
    var words = actions(f, entries, theme, SEP);
    var budget = cols - 2 - 4 - (words.cells > 0 ? 3 + words.cells : 0);
    var ticks = hasRail(f) ? railTicks(f.rail.prompts.length, budget, BAND_BARS) : undefined;
    if (entries.length === 0 && ticks === undefined) return null;
    var rail = [];
    if (ticks !== undefined) {
      rail.push(Bx({ key: "cs-rail", marginLeft: words.cells > 0 ? 3 : 0 }, railNodes(f.rail, ticks.hidden, inks(theme).own)));
      var room = budget - railCells(f.rail, ticks.hidden) - 2;
      if (room >= RAIL_LABEL_MIN) rail.push(Bx({ marginLeft: 2 }, [T({ dimColor: true, italic: true }, cut(promptName(f.rail), room))]));
    }
    return Bx({ flexDirection: "column" }, [
      Bx({ key: "cs-rotate-band", marginLeft: 2, borderStyle: "round", borderColor: markInk(f, theme), paddingX: 1 }, words.nodes.concat(rail)),
    ]);
  }

  // Two rows: the mark and the shipped words, then the rail and its named
  // prompt under the words with the whole width to itself. With no words the
  // rail's row carries the mark.
  function drawStacked(f, cols, theme) {
    var entries = entriesOf(f);
    var words = actions(f, entries, theme, SEP);
    var budget = cols - 2 - 2;
    var ticks = hasRail(f) ? railTicks(f.rail.prompts.length, budget, BAND_BARS) : undefined;
    if (entries.length === 0 && ticks === undefined) return null;
    var mark = Bx({ key: "cs-mark", marginRight: 1 }, [T({ color: markInk(f, theme) }, MARK)]);
    var rows = [];
    if (entries.length > 0) rows.push(Bx({ key: "cs-actions" }, [mark].concat(words.nodes)));
    if (ticks !== undefined) {
      var where = [Bx({ key: "cs-rail" }, railNodes(f.rail, ticks.hidden, inks(theme).own))];
      var room = budget - railCells(f.rail, ticks.hidden) - 2;
      if (room >= RAIL_LABEL_MIN) where.push(Bx({ marginLeft: 2 }, [T({ dimColor: true, italic: true }, cut(promptName(f.rail), room))]));
      rows.push(entries.length > 0 ? Bx({ key: "cs-where", marginLeft: 2 }, where) : Bx({ key: "cs-where" }, [mark].concat(where)));
    }
    return Bx({ flexDirection: "column" }, [Bx({ marginTop: 1 }, [Bx({ key: "cs-rotate-band", marginLeft: 2, flexDirection: "column" }, rows)])]);
  }

  var VARIANTS = [
    { id: "shipped", name: "Shipped", note: "The band the cs mod draws, from its own drawBand in the bundled docs/surfaces/cs.js, handed the terminal less the five [-] cells. With every word at once it clips at 60 and at 80: the line has no rule for what to drop.", draw: cs.band },
    { id: "quiet", name: "Quiet line", note: "Words only, in the default ink; the chords trail as one dim hint. Past the width the hint goes first, then the last words fold into …N, so it never overruns.", draw: drawQuiet },
    { id: "keys-first", name: "Keys first", note: "The bound keys lead and their digits are the only colour on the line; the other words follow, dim, two cells apart. Every word at once clips at 60 and at 80.", draw: drawKeysFirst },
    { id: "status-first", name: "Status first", note: "A word for the state leads where the mark stood (due, armed, running gate, running queue, idle), in the mark's ink; the shipped words follow. It repeats the gate's own word, and every word at once clips at 60 and at 80.", draw: drawStatusFirst },
    { id: "two-zone", name: "Two zones", note: "Actions on the left, the named prompt and the rail pushed to the right edge with space-between, so the rail always ends where the line does. Every word at once clips at 60 and at 80.", draw: drawTwoZone },
    { id: "rail-first", name: "Rail first", note: "The rail leads at the inset and its named prompt grows into the room; the words fold compact to the right edge and the mark ends the line. Every word at once clips at 60 and at 80.", draw: drawRailFirst },
    { id: "capsule", name: "Capsule", note: "The shipped words in a round border whose ink carries the state, for comparison with the rotate capsule presets: three rows for one line of words. Every word at once clips at 60 and at 80.", draw: drawCapsule },
    { id: "stacked", name: "Stacked", note: "Two rows: the shipped words, then the rail under them with the whole width, so a long line of words no longer squeezes the rail out. The words' row still clips at 60 and at 80 with every word at once.", draw: drawStacked },
  ];

  var api = { STATES: STATES, VARIANTS: VARIANTS };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.BandVariants = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
