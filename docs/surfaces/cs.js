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
  var PRESSED = ".cs/local/cs.pressed";
  var WRAP_QUESTION = "Run /wrap for this session?";
  var WRAP_YES = "Yes, wrap up";
  var QUEUE_START = "Start";
  var QUEUE_COMPACT = "Compact";
  var TOAST_TASK_CHARS = 60;
  function cutTask(task) {
    return task.length > TOAST_TASK_CHARS ? `${task.slice(0, TOAST_TASK_CHARS)}…` : task;
  }
  var FINISH_RECORD = "finish-progress.json";
  var FINISH_OUTCOMES = new Set(["landed", "refused", "retired"]);
  var QUEUE_MODE_QUESTION = "How should the queued tasks run?";
  var QUEUE_HERE = "In this conversation";
  var QUEUE_SUBAGENTS = "In subagents";
  var QUEUE_WORKFLOWS = "As workflows";
  var QUEUE_MODE_WORDS = { [QUEUE_HERE]: [], [QUEUE_SUBAGENTS]: ["subagents"], [QUEUE_WORKFLOWS]: ["workflow"] };
  var ASKS = {
    wrap: { question: WRAP_QUESTION, header: "Wrap", options: [WRAP_YES, "Not now"] },
    queueStart: (count) => ({ question: `Start the ${count} queued ${count === 1 ? "task" : "tasks"} now?`, header: "Queue", options: [QUEUE_START, "Not yet", QUEUE_COMPACT] }),
    queueMode: { question: QUEUE_MODE_QUESTION, header: "Queue", options: [QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS] }
  };
  var TOASTS = {
    queued: (task) => `queued: ${cutTask(task)}`,
    bandOption: (problem) => `the band draws no prompt bars: ${problem}. Set it in /config.`,
    promptNotDrawn: "that prompt is not on screen yet",
    scrollRefused: (deny) => deny,
    transcriptTail: () => `the transcript is over ${READ_CAP / 1024 / 1024} MiB; the rail lists the prompts of its tail`,
    forceBelowStart: (force, startPercent) => `CS_ROTATE_FORCE_CTX=${force} is below this conversation's starting context (${startPercent}%); not forcing a rotation`,
    rotateFailed: (err) => `/rotate did not run: ${err}`,
    clearFailed: (err) => `/clear did not run: ${err}`,
    nextStep: (line) => `next step: ${line}`,
    noRotation: (refusal) => `no rotation in this session: ${refusal}`,
    feedFailed: (err) => `feed update failed: ${err}`,
    finishFailed: (task, err) => `/finish${task === "" ? "" : ` ${task}`} did not run: ${err}`,
    pressedNotEmptied: (err) => `could not empty ${PRESSED}: ${err}`,
    wrapFailed: (err) => `/wrap did not run: ${err}`,
    queueNoBin: "the launch did not say where cs is (CS_BIN); run cs -queue start from a shell in this session",
    queueModeUnknown: (how) => `'${how}' is not a way to run the queue; it is not started`,
    notCompacted: (reason) => `the conversation was not compacted (${reason}); the queue is not started`,
    queueStartFailed: (err) => `cs -queue start did not run: ${err}`,
    queueStartExited: (code, tail) => `cs -queue start exited ${code}${tail === "" ? "" : `: ${tail}`}`,
    queueKickFailed: (err) => `the queue is armed, but its first turn did not start: ${err}`,
    finishRecordUnread: (dir) => `.cs/${dir}/${FINISH_RECORD} is not a record cs wrote; /finish progress is not shown`,
    finishPidUnknown: (err) => `cannot tell whether /finish is still running: ${err}`
  };
  var LOGS = {
    featuresUnread: (err) => `the features word could not be read: ${err}`,
    featuresExited: (base, code, line) => `cs ${base} -features exited ${code}: ${line}`,
    featuresUnreadable: (base, record) => `cs ${base} -features gave a record the band cannot read: ${record}`,
    featuresNoAnswer: (base, err) => `cs ${base} -features did not answer: ${err}`,
    transcriptUnread: (err) => `the transcript could not be read: ${err}`,
    colorFailed: (color, err) => `/color ${color} did not run: ${err}`,
    feedUnread: (message) => `the feed setting could not be read: ${message}`
  };
  var REPLIES = {
    queueNoBin: 'The launch did not say where cs is (CS_BIN); run `cs -queue add "<task>"` from a shell in this session.',
    queueFailed: (what, err) => `${what} did not run: ${err}`,
    queueExited: (what, code, tail) => tail === "" ? `${what} exited ${code}.` : `${what} exited ${code}.
${tail}`,
    queued: (task) => `Queued: ${task}`,
    csUsage: "usage: /cs next|prev|first|last|<n>",
    railEmpty: "the rail has no prompts",
    noneAfter: "no prompt after this one",
    noneBefore: "no prompt before this one",
    railCount: (count) => `the rail has ${count} ${count === 1 ? "prompt" : "prompts"}`
  };
  var COMMANDS = {
    queue: { name: "queue", description: "Add a task to this cs session's walk-away queue, or list it.", argumentHint: "[task]", immediate: true },
    cs: { name: "cs", description: "Scroll the transcript along the band's rail of prompts.", argumentHint: "next|prev|first|last|<n>", immediate: true }
  };
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
  var DROP_ORDER = ["cs-mail", "cs-queued", "cs-features", "cs-gate"];
  var SEP = "  ·  ";
  function chordSpelling(entries, chords) {
    const prefix = sharedPrefix(entries.flatMap((entry) => entry.kind === "chord" ? [chords[entry.action]] : []));
    return {
      prefix,
      spelled: (action) => {
        const chord = chords[action];
        return chord === undefined ? undefined : prefix === undefined ? chord : chord.slice(prefix.length + 1);
      }
    };
  }
  var firstChordOf = (entries, chords) => entries.findIndex((entry) => entry.kind === "chord" && chords[entry.action] !== undefined);
  function wordCellsOf(entries, chords, { prefix, spelled }, prefixed) {
    const firstChord = firstChordOf(entries, chords);
    return cellWidth(entries.map((entry, index) => {
      const chord = entry.kind === "chord" ? spelled(entry.action) : undefined;
      const keyed = chord === undefined ? entry.label : entry.keyOnly ? chord : `${chord} ${entry.label}`;
      return `${index === firstChord && prefixed && prefix !== undefined ? `${prefix}  ` : ""}${keyed}`;
    }).join(SEP));
  }
  var SHORTEN_ORDER = ["cs-features", "cs-queue"];
  var SHORTEST_CELLS = 2;
  var LEAVE_ORDER = ["cs-countdown", "cs-features", "cs-queue"];
  function fitBand(all, chords, room) {
    const spelling = chordSpelling(all, chords);
    for (let kept = all;; ) {
      const fitted = shortenBand(kept, chords, spelling, room);
      const excess = wordCellsOf(fitted.entries, chords, spelling, fitted.prefixed) - room;
      const last = fitted.entries[fitted.entries.length - 1];
      if (excess <= 0 || last === undefined)
        return fitted;
      const leaving = LEAVE_ORDER.find((key) => fitted.entries.some((entry) => entry.key === key));
      if (leaving === undefined) {
        if (last.kind !== "chord")
          throw new Error(`cs: the band left ${last.key} for last, where only chords stay`);
        const keep = (last.keyOnly ? 0 : cellWidth(last.label)) - excess;
        if (keep >= 1)
          return { entries: [...fitted.entries.slice(0, -1), { ...last, label: cutToCells(last.label, keep), ink: undefined }], prefixed: false };
      }
      kept = kept.filter((entry) => entry.key !== (leaving ?? last.key));
    }
  }
  function shortenBand(all, chords, spelling, room) {
    const over = (entries, prefixed) => wordCellsOf(entries, chords, spelling, prefixed) - room;
    let entries = all;
    for (const key of DROP_ORDER) {
      if (over(entries, true) <= 0)
        return { entries, prefixed: true };
      entries = entries.filter((entry) => entry.key !== key || entry.kind !== "word");
    }
    if (over(entries, true) <= 0)
      return { entries, prefixed: true };
    for (const key of SHORTEN_ORDER) {
      const excess = over(entries, false);
      if (excess <= 0)
        return { entries, prefixed: false };
      entries = entries.map((entry) => {
        const cells = cellWidth(entry.label);
        return entry.key !== key || cells <= SHORTEST_CELLS ? entry : { ...entry, label: cutToCells(entry.label, Math.max(SHORTEST_CELLS, cells - excess)) };
      });
    }
    for (let i = entries.length - 1;i >= 0; i--) {
      if (over(entries, false) <= 0)
        return { entries, prefixed: false };
      entries = entries.map((entry, j) => j === i && entry.kind === "chord" && spelling.spelled(entry.action) !== undefined ? { ...entry, keyOnly: true } : entry);
    }
    return { entries, prefixed: false };
  }
  function drawBand(v, el) {
    const { Box, Text, Button } = el;
    const { chords, own } = v;
    const markCells = v.hasSurvey ? 0 : cellWidth(MARK) + 1;
    const { entries, prefixed } = fitBand(v.entries, chords, v.bodyColumns - 2 - markCells);
    const spelling = chordSpelling(v.entries, chords);
    const { spelled } = spelling;
    const prefix = prefixed ? spelling.prefix : undefined;
    const firstChord = firstChordOf(entries, chords);
    const key = (action) => {
      const text = spelled(action);
      return text !== undefined && /* @__PURE__ */ h(Box, {
        marginRight: 1
      }, /* @__PURE__ */ h(Text, {
        bold: true,
        color: own
      }, text));
    };
    const keyButton = (entry) => {
      const text = spelled(entry.action);
      if (text === undefined)
        throw new Error(`cs: the band drew ${entry.key} as a key it has no chord for`);
      return /* @__PURE__ */ h(Button, {
        key: entry.key,
        action: entry.action,
        plain: true,
        label: text,
        onPress: entry.onPress
      }, /* @__PURE__ */ h(Text, {
        bold: true,
        color: own
      }, text));
    };
    const wordCells = wordCellsOf(entries, chords, spelling, prefixed);
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
      }, SEP),
      index === firstChord && prefix !== undefined && /* @__PURE__ */ h(Box, {
        marginRight: 2
      }, /* @__PURE__ */ h(Text, {
        dimColor: true
      }, prefix)),
      entry.kind === "chord" && !entry.keyOnly && key(entry.action),
      entry.kind === "word" ? entry.ink === undefined ? /* @__PURE__ */ h(Text, {
        dimColor: true
      }, entry.label) : /* @__PURE__ */ h(Text, {
        bold: true,
        color: entry.ink.color
      }, entry.label) : entry.kind === "chord" ? entry.keyOnly ? keyButton(entry) : entry.ink === undefined ? /* @__PURE__ */ h(Button, {
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
    return `${fitted.trimEnd()}…`;
  }
  function fitLeft(text, width) {
    const fitted = cutToCells(text, width);
    return fitted + " ".repeat(Math.max(0, width - cellWidth(fitted)));
  }
  var ROTATE_ACTION = "strip:jump1";
  var WRAP_ACTION = "strip:jump2";
  var FEED_ACTION = "strip:jump3";
  function finishToast(record) {
    const task = cutTask(record.task);
    switch (record.step) {
      case "landed":
        return `landed ${task} ${record.sha.slice(0, 7)} -> ${(record.result ?? "").slice(0, 7)}`;
      case "refused":
        return `/finish ${task} refused: ${record.reason ?? ""}`;
      case "retired":
        return `retired ${task}`;
      default:
        return `finishing ${task}`;
    }
  }
  function gateElapsed(secs) {
    if (secs < 60)
      return `${secs}s`;
    return `${Math.floor(secs / 60)}m ${String(secs % 60).padStart(2, "0")}s`;
  }

  // docs/surfaces/registry.ts
  var timer = (tick) => ({ tick, duration: Math.ceil(5 * 60 * 1000 / tick) * tick });
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
  var rule = (cols) => elements().Text({ color: "inactive", children: "─".repeat(cols) });
  function askDialog(dialog, cols, focus = 0) {
    const el = elements();
    const pointer = (on) => on ? el.Text({ color: "suggestion", children: "❯" }) : el.Text({ children: " " });
    const digits = String(dialog.options.length + 1).length;
    const other = dialog.options.length + 1;
    return el.Box({ flexDirection: "column", children: [
      rule(cols),
      el.Box({ flexDirection: "column", children: [
        el.Box({ marginBottom: 1, children: [el.Box({ children: [el.Text({ backgroundColor: "permission", color: "inverseText", children: ` ☐ ${dialog.header} ` })] })] }),
        el.Box({ gap: 1, children: [el.Text({ bold: true, color: "text", children: dialog.question })] }),
        el.Box({ flexDirection: "column", children: [
          el.Box({ marginTop: 1, flexDirection: "column", children: [
            ...dialog.options.map((label, i) => el.Box({ gap: 1, children: [
              pointer(i === focus),
              el.Text({ dimColor: true, children: `${i + 1}.`.padEnd(digits + 1) }),
              el.Text({ color: i === focus ? "suggestion" : undefined, children: label })
            ] })),
            el.Box({ gap: 1, children: [
              pointer(focus === dialog.options.length),
              el.Box({ children: [
                el.Box({ flexShrink: 0, children: [el.Text({ dimColor: true, children: `${other}.`.padEnd(digits + 2) })] }),
                el.Text({ color: "inactive", children: "Type something." })
              ] })
            ] })
          ] }),
          el.Box({ flexDirection: "column", children: [
            rule(cols),
            el.Box({ gap: 1, children: [pointer(false), el.Text({ children: `${other + 1}. Chat about this` })] })
          ] }),
          el.Box({ marginTop: 1, children: [el.Text({ color: "inactive", dimColor: true, children: "Enter to select · ↑/↓ to navigate · Esc to cancel" })] })
        ] })
      ] })
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
  function logRow(plugin, text, cols) {
    const el = elements();
    return el.Box({ width: cols, children: [
      el.Box({ minWidth: 2, children: [el.Text({ color: "inactive", children: "⏺" })] }),
      el.Box({ flexDirection: "column", width: cols - 10, children: [el.Text({ color: "inactive", wrap: "wrap", children: `${plugin}: ${text}` })] })
    ] });
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
  function survey() {
    const el = elements();
    const answers = [["1", "Bad"], ["2", "Fine"], ["3", "Good"], ["0", "Dismiss"]];
    return el.Box({ flexDirection: "column", marginTop: 1, children: [
      el.Box({ children: [el.Box({ minWidth: 2, children: [el.Text({ color: "ansi:cyan", children: "●" })] }), el.Text({ bold: true, wrap: "wrap", children: "How is Claude doing this session? (optional)" })] }),
      el.Box({ marginLeft: 2, children: answers.map(([key, label]) => el.Box({ width: 10, children: [el.Text({ color: "ansi:cyan", children: key }), el.Text({ children: `: ${label}` })] })) })
    ] });
  }
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
    const drawn = f.survey ? survey() : el.Box({});
    return { drawn, entries, chords, own, markColor, hasSurvey: f.survey, bodyColumns: cols - RESERVED, surface: f.surface, rail };
  }
  function band(f, cols, theme) {
    return drawBand(viewOf(f, cols, theme), elements());
  }
  var GATE = { task: "fix-auth", seconds: 72 };
  var gateWord = (seconds) => `finishing ${GATE.task} · gate ${gateElapsed(seconds)}`;
  function factsAt(f, t) {
    const seconds = Math.floor(t / 1000);
    if (f.gate !== undefined && f.gate !== gateWord(GATE.seconds))
      throw new Error(`cs fixture: a gate word is GATE's, at its start; got ${JSON.stringify(f.gate)}`);
    return {
      ...f,
      countdown: f.countdown && { seconds: Math.max(0, f.countdown.seconds - seconds) },
      gate: f.gate === undefined ? undefined : gateWord(GATE.seconds + seconds)
    };
  }
  function motionOf(f) {
    const start = f.countdown?.seconds;
    if (start !== undefined)
      return { tick: 1000, duration: start * 1000, count: (t) => `${Math.max(0, start - Math.floor(t / 1000))}s left` };
    if (f.gate !== undefined)
      return timer(1000);
    return;
  }
  var feature = (state, ahead = 2) => ({ task: "fix-auth", ahead, state });
  var word = (records, pressable) => {
    const w = featuresWordOf(records);
    if (w === undefined)
      throw new Error("cs fixture: featuresWordOf drew no word for " + JSON.stringify(records));
    return { label: w.label, pressable: pressable && w.finish !== undefined };
  };
  var ONE_FEATURE = [
    ["ready", feature("ready")],
    ["no-commits", feature("ready", 0)],
    ["staged", feature("staged")],
    ["locked", feature("locked")],
    ["dirty", feature("dirty")],
    ["untracked", feature("untracked")],
    ["vault-locked", feature("vault-locked")],
    ["base-dirty", feature("base-dirty")],
    ["merged", feature("merged")]
  ];
  var DUE = { rotating: true, wrapping: true, due: true };
  var CATALOGUE = 15;
  var STATES = [
    { id: "idle", name: "nothing to say", facts: facts({}) },
    { id: "rotate-due", name: "context past the threshold", facts: facts(DUE) },
    { id: "countdown", name: "handoff armed, counting down to the /clear", facts: facts({ countdown: { seconds: 7 }, rotating: true, armed: true, due: true }) },
    { id: "armed-clear-now", name: "handoff armed, waiting for a press", facts: facts({ rotating: true, armed: true, due: true }) },
    { id: "feed-off", name: "idle, the feed mod installed and off", facts: facts({ feed: { on: false } }) },
    { id: "feed-on", name: "idle, the feed on", facts: facts({ feed: { on: true } }) },
    { id: "queue-waiting", name: "tasks queued, nothing running them", facts: facts({ waiting: 3 }) },
    { id: "queue-running", name: "the queue running its tasks", facts: facts({ queued: 3, queueRunning: true }) },
    { id: "gate-running", name: "a /finish gate running", facts: facts({ gate: gateWord(GATE.seconds) }) },
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
    { id: "no-chords", name: "context past the threshold, keybindings unbound", facts: facts({ ...DUE, chords: {} }) },
    { id: "rotate-wrapped", name: "past the threshold after /wrap ran in this conversation", facts: facts({ rotating: true, due: true }) },
    { id: "countdown-session", name: "handoff armed, the count still in the session colour", facts: facts({ countdown: { seconds: 15 }, rotating: true, armed: true, due: true }) },
    { id: "countdown-crit", name: "handoff armed, seconds from the /clear", facts: facts({ countdown: { seconds: 3 }, rotating: true, armed: true, due: true }) },
    { id: "armed-with-queue", name: "handoff armed with tasks queued", facts: facts({ rotating: true, armed: true, due: true, queued: 3 }) },
    { id: "due-midturn", name: "a turn running past the threshold, with mail", facts: facts({ due: true, mail: 2 }) },
    { id: "queued-blocked", name: "tasks queued while a turn runs", facts: facts({ queued: 3 }) },
    { id: "survey-gate", name: "a survey up while a /finish gate runs", facts: facts({ survey: true, gate: gateWord(GATE.seconds) }) },
    { id: "features-many-ready", name: "several features ready to finish", facts: facts({ featured: word([feature("ready"), feature("ready"), feature("dirty")], true) }) },
    ...ONE_FEATURE.map(([sid, record]) => ({ id: `features-one-${sid}`, name: sid === "ready" ? "one feature, ready to finish" : `one feature, not ready: ${sid.replace("-", " ")}`, facts: facts({ featured: word([record], true) }) })),
    { id: "features-none-ready", name: "several features, none ready", facts: facts({ featured: word([feature("dirty"), feature("locked"), feature("staged")], true) }) },
    { id: "features-midturn", name: "a turn running, the ready feature not pressable", facts: facts({ featured: word([feature("ready")], false) }) },
    { id: "chords-mixed", name: "keys bound under different prefixes", facts: facts({ ...DUE, chords: { rotate: "ctrl+x 1", wrap: "ctrl+y 2" } }) },
    { id: "chords-partial", name: "only the rotate key bound", facts: facts({ ...DUE, chords: { rotate: "ctrl+x 1" } }) },
    { id: "rail-no-label", name: "the words leaving the rail no room to name a prompt", facts: facts({ ...DUE, feed: { on: true }, waiting: 2, rail: { prompts: PROMPTS.slice(0, 6), named: 5, refused: [] } }) },
    { id: "rail-uncoloured", name: "the rail in a session with no colour", facts: facts({ colour: null, rail: { prompts: PROMPTS.slice(0, 3), named: 2, refused: [] } }) },
    { id: "rail-desktop", name: "the rail on the desktop app, no hover cards", facts: facts({ surface: "desktop", rail: { prompts: PROMPTS.slice(0, 3), named: 2, refused: [] } }) }
  ];
  var kebab = (key) => key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
  var chromeStates = (lines) => Object.keys(lines).map((key) => ({ id: kebab(key), name: lines[key].name, draw: lines[key].draw }));
  var csToast = (text) => (cols) => toast("cs", text, cols);
  var TOAST_STATES = {
    queued: { name: "queuing a task with /queue", draw: csToast(TOASTS.queued("fix the login redirect")) },
    bandOption: { name: "loading the band with a /config value it cannot draw", draw: csToast(TOASTS.bandOption("cs.bandBars is the most bars the band draws, a whole number of 1 or more; got 0")) },
    promptNotDrawn: { name: "jumping to a prompt no row has drawn since a resume", draw: csToast(TOASTS.promptNotDrawn) },
    scrollRefused: { name: "jumping to a prompt the engine would not scroll to", draw: csToast(TOASTS.scrollRefused("the window moved meanwhile")) },
    transcriptTail: { name: "working in a conversation whose transcript is past 4 MiB", draw: csToast(TOASTS.transcriptTail()) },
    forceBelowStart: { name: "starting a conversation already past the forced rotation", draw: csToast(TOASTS.forceBelowStart(70, 75)) },
    rotateFailed: { name: "seeing a forced /rotate fail to run", draw: csToast(TOASTS.rotateFailed("Error: unknown command")) },
    clearFailed: { name: "seeing the countdown reach zero and /clear fail to run", draw: csToast(TOASTS.clearFailed("Error: no session")) },
    nextStep: { name: "watching the countdown start on an armed handoff", draw: csToast(TOASTS.nextStep("Run the secrets suites solo.")) },
    noRotation: { name: "working in a session cs will not rotate", draw: csToast(TOASTS.noRotation("the launch did not say where cs is (CS_BIN)")) },
    feedFailed: { name: "pressing feed when the feed file cannot be written", draw: csToast(TOASTS.feedFailed("EACCES: permission denied")) },
    finishFailed: { name: "pressing the features word when /finish cannot run", draw: csToast(TOASTS.finishFailed("fix-auth", "a turn is running")) },
    pressedNotEmptied: { name: "ending a turn when the press marker cannot be emptied", draw: csToast(TOASTS.pressedNotEmptied("Error: EACCES")) },
    wrapFailed: { name: "answering yes to /wrap when it cannot run", draw: csToast(TOASTS.wrapFailed("Error: no session")) },
    queueNoBin: { name: "pressing the queue start where the launch did not say where cs is", draw: csToast(TOASTS.queueNoBin) },
    queueModeUnknown: { name: "typing a way to run the queue cs does not know", draw: csToast(TOASTS.queueModeUnknown("in parallel please")) },
    notCompacted: { name: "choosing Compact when the conversation is not compacted", draw: csToast(TOASTS.notCompacted("a turn is running")) },
    queueStartFailed: { name: "starting the queue when cs cannot run", draw: csToast(TOASTS.queueStartFailed("spawn ENOENT")) },
    queueStartExited: { name: "starting the queue when cs refuses", draw: csToast(TOASTS.queueStartExited(1, "Error: the queue is locked")) },
    queueKickFailed: { name: "starting the queue when its first turn cannot start", draw: csToast(TOASTS.queueKickFailed("session closed")) },
    finishRecordUnread: { name: "running /finish when its progress record is not one cs wrote", draw: csToast(TOASTS.finishRecordUnread("local")) },
    finishPidUnknown: { name: "running /finish when its process cannot be checked", draw: csToast(TOASTS.finishPidUnknown("spawn EPERM")) }
  };
  var FINISH = { id: "4242-1799999990", pid: 4242, task: "fix-auth", sha: "1234567" + "f".repeat(33), step: "started" };
  var FINISH_STATES = [
    { id: "finishing", name: "running /finish on a feature", draw: csToast(finishToast(FINISH)) },
    { id: "landed", name: "seeing /finish land a feature", draw: csToast(finishToast({ ...FINISH, step: "landed", result: "89abcde" + "0".repeat(33) })) },
    { id: "finish-refused", name: "seeing /finish refuse a feature", draw: csToast(finishToast({ ...FINISH, step: "refused", reason: "the gate failed: 2 suites red" })) },
    { id: "retired", name: "seeing /finish retire a feature", draw: csToast(finishToast({ ...FINISH, step: "retired" })) },
    { id: "rotate-failed-two-lines", name: "seeing a forced /rotate fail with an error of two lines", draw: csToast(TOASTS.rotateFailed(`Error: refused
see /doctor`)) }
  ];
  var INLINE_STATES = [
    { id: "queued-inline", name: "queuing a task with /queue, outside the fullscreen renderer", draw: (cols) => inlineToast("cs", TOASTS.queued("fix the login redirect"), cols) },
    { id: "force-below-start-inline", name: "starting past the forced rotation, outside the fullscreen renderer", draw: (cols) => inlineToast("cs", TOASTS.forceBelowStart(70, 75), cols) }
  ];
  var ASK_STATES = [
    { id: "wrap", name: "pressing the wrap key", draw: (cols) => askDialog(ASKS.wrap, cols) },
    { id: "wrap-not-now", name: "moving to Not now in the wrap dialog", draw: (cols) => askDialog(ASKS.wrap, cols, 1) },
    { id: "queue-start-one", name: "running bare /queue with one task queued", draw: (cols) => askDialog(ASKS.queueStart(1), cols) },
    { id: "queue-start-many", name: "pressing the queue start with three tasks queued", draw: (cols) => askDialog(ASKS.queueStart(3), cols) },
    { id: "queue-mode", name: "choosing how the queued tasks run", draw: (cols) => askDialog(ASKS.queueMode, cols) }
  ];
  var TASK = "fix the login redirect";
  var COMMAND_STATES = [
    { id: "queue-added", name: "queuing a task with /queue", draw: () => commandReply("cs", "queue", TASK, REPLIES.queued(TASK)) },
    { id: "queue-no-bin", name: "running /queue where the launch did not say where cs is", draw: () => commandReply("cs", "queue", TASK, REPLIES.queueNoBin) },
    { id: "queue-failed", name: "running bare /queue when cs cannot run", draw: () => commandReply("cs", "queue", "", REPLIES.queueFailed("cs -queue list", "spawn ENOENT")) },
    { id: "queue-exited", name: "queuing a task cs refuses", draw: () => commandReply("cs", "queue", TASK, REPLIES.queueExited("cs -queue add", 1, "")) },
    { id: "cs-usage", name: "running /cs with a word it does not take", draw: () => commandReply("cs", "cs", "sideways", REPLIES.csUsage) },
    { id: "rail-empty", name: "running /cs in a conversation with no prompts yet", draw: () => commandReply("cs", "cs", "next", REPLIES.railEmpty) },
    { id: "none-after", name: "running /cs next on the last prompt", draw: () => commandReply("cs", "cs", "next", REPLIES.noneAfter) },
    { id: "none-before", name: "running /cs prev on the first prompt", draw: () => commandReply("cs", "cs", "prev", REPLIES.noneBefore) },
    { id: "rail-count", name: "running /cs with a number past the last prompt", draw: () => commandReply("cs", "cs", "9", REPLIES.railCount(4)) }
  ];
  var MENU = [COMMANDS.queue, COMMANDS.cs];
  var MENU_STATES = [
    { id: "queue-selected", name: "typing /q in the prompt", draw: (cols) => menuRows(MENU, 0, cols) },
    { id: "cs-selected", name: "moving to /cs in the slash menu", draw: (cols) => menuRows(MENU, 1, cols) }
  ];
  var csLog = (text) => (cols) => logRow("cs", text, cols);
  var LOG_STATES = {
    featuresUnread: { name: "ending a turn when the features word cannot be read", draw: csLog(LOGS.featuresUnread("spawn ENOENT")) },
    featuresExited: { name: "ending a turn when cs refuses to list the features", draw: csLog(LOGS.featuresExited("api", 2, "error: the features index under .cs/local is locked by another cs process")) },
    featuresUnreadable: { name: "ending a turn when cs lists a feature the band cannot read", draw: csLog(LOGS.featuresUnreadable("work", "fix-auth")) },
    featuresNoAnswer: { name: "ending a turn when cs does not answer for the features", draw: csLog(LOGS.featuresNoAnswer("work", "spawn ENOENT")) },
    transcriptUnread: { name: "ending a turn when the transcript cannot be read", draw: csLog(LOGS.transcriptUnread("EACCES")) },
    colorFailed: { name: "starting a conversation whose session colour does not apply", draw: csLog(LOGS.colorFailed("red", "Error: command refused")) },
    feedUnread: { name: "drawing the band when the feed setting cannot be read", draw: csLog(LOGS.feedUnread("cs: $.fs.read(/work/.cs/local/feed) failed: EACCES")) }
  };
  var chromeSurface = (slot, states) => ({ id: `cs.${slot}`, mod: "cs", slot, source: "chrome", global: "CsSurfaces", states, parts: [] });
  var surfaces = [
    {
      id: "cs.AbovePrompt",
      mod: "cs",
      slot: "AbovePrompt",
      source: "generated",
      global: "CsSurfaces",
      chrome: { kind: "above-prompt" },
      states: STATES.map((s) => {
        const motion = motionOf(s.facts);
        return { id: s.id, name: s.name, draw: (cols, theme, t = 0) => band(factsAt(s.facts, t), cols, theme), ...motion && { motion } };
      }),
      parts: [
        { id: "band-mark", name: "band mark", state: "rotate-due", path: [1, 0, 0] },
        { id: "chord", name: "chord key", state: "rotate-due", path: [1, 0, 2] },
        { id: "chord-word", name: "chord word Button", state: "rotate-due", path: [1, 0, 3] },
        { id: "countdown", name: "countdown word", state: "countdown", path: [1, 0, 1] },
        { id: "rail-tick", name: "rail tick", state: "rail-few", path: [1, 0, 1, 0] },
        { id: "prompt-label", name: "prompt label", state: "rail-few", path: [1, 0, 2] }
      ]
    },
    chromeSurface("toast", [...chromeStates(TOAST_STATES), ...FINISH_STATES, ...INLINE_STATES]),
    chromeSurface("ask", ASK_STATES),
    chromeSurface("command", COMMAND_STATES),
    chromeSurface("menu", MENU_STATES),
    chromeSurface("log", chromeStates(LOG_STATES))
  ];

  // docs/surfaces/cs.entry.ts
  globalThis.CsSurfaces = { surfaces, STATES, CATALOGUE, CHORDS, PROMPTS, band, countdownStep, facts };
})();
