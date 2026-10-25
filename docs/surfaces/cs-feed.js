(() => {
  // mods/cs-feed/hooks/settings.ts
  var KINDS = ["you", "said", "tool", "agent", "question", "peer", "helper", "search"];
  var PRESETS = {
    clean: { fields: { group: true, clear: true, keep: false, style: "subtle", commands: "grouped", after: "clear" }, help: "your messages, Claude's replies, and one line per turn for the work" },
    normal: { fields: { group: false, clear: false, keep: true, style: "subtle", commands: "grouped", after: "keep" }, help: "each run of tool calls is one line with counts" }
  };
  var RAW_HELP = "Claude Code's own drawing";
  var DEFAULT_VIEW = { ...PRESETS.clean.fields, hide: [] };
  var spoken = (value) => typeof value === "boolean" ? value ? "on" : "off" : value;
  var FIELDS = [
    {
      field: "group",
      word: "group",
      title: "Group a turn into one line",
      values: [true, false],
      spoken,
      picture: (value) => value ? ["you   fix the login bug", "6 steps this turn ›", "claude Fixed: the token now refreshes."] : ["you   fix the login bug", "○ Ran 3 shell commands · read 2 files ›", "○ Edited auth.ts", "claude Fixed: the token now refreshes."]
    },
    {
      field: "clear",
      word: "clear",
      title: "Clear after the turn",
      values: [true, false],
      spoken,
      picture: (value) => [value ? "a finished turn keeps only its one line (grouping on) or nothing (off)" : "a finished turn keeps its rows"]
    },
    {
      field: "keep",
      word: "keep",
      title: "Keep every card",
      values: [true, false],
      spoken,
      picture: (value) => [value ? 'finished turns stay drawn as they ran, whatever "clear" says' : '"clear after the turn" decides']
    },
    {
      field: "style",
      word: "style",
      title: "Card style",
      values: ["expanded", "subtle", "line"],
      spoken,
      picture: (value) => value === "expanded" ? ["○ Ran 2 shell commands", "  ○ Ran the tests +12 lines", "  ○ Listed the files +4 lines"] : [value === "subtle" ? "○ Ran 2 shell commands +16 lines ›" : "○ Ran 2 shell commands"]
    },
    {
      field: "commands",
      word: "commands",
      title: "Commands in the chat",
      values: ["grouped", "each"],
      spoken,
      picture: (value) => value === "grouped" ? ["○ Ran 3 shell commands · read 1 file"] : ["○ Ran the tests", "○ Listed the files", "○ Read app.py"]
    },
    {
      field: "after",
      word: "after",
      title: "After a command finishes",
      values: ["clear", "keep"],
      spoken,
      picture: (value) => [value === "clear" ? "a finished turn keeps the run line, not each command" : "each finished command keeps its own line"]
    }
  ];
  function modeOf(session) {
    if (!session.on)
      return "raw";
    if (session.view.hide.length)
      return "custom";
    for (const preset of ["clean", "normal"]) {
      if (FIELDS.every(({ field }) => session.view[field] === PRESETS[preset].fields[field]))
        return preset;
    }
    return "custom";
  }
  function isKind(value) {
    return KINDS.some((kind) => kind === value);
  }
  function parseFeedArgs(args) {
    const words = args.trim().toLowerCase().split(/\s+/);
    const [word, value] = words;
    if (!word)
      return { kind: "open" };
    if (words.length === 1) {
      if (word === "close" || word === "status")
        return { kind: word };
      if (word === "on" || word === "off")
        return { kind: "switch", on: word === "on" };
      if (word === "clean" || word === "normal" || word === "raw")
        return { kind: "preset", to: word };
    }
    if ((word === "hide" || word === "show") && isKind(value))
      return { kind: word, what: value };
    const spec = FIELDS.find((spec) => spec.word === word);
    if (!spec)
      return { kind: "usage" };
    const candidate = { kind: "set", field: spec.field, value: fieldValue(spec.values, value) };
    return isSetting(candidate) ? candidate : { kind: "usage" };
  }
  function isSetting(candidate) {
    return FIELDS.some((spec) => spec.field === candidate.field && spec.values.some((value) => value === candidate.value));
  }
  function fieldValue(values, word) {
    const normalized = word === "yes" || word === "true" ? "on" : word === "no" || word === "false" ? "off" : word;
    return values.find((value) => spoken(value) === normalized);
  }
  function transition(cmd, current) {
    switch (cmd.kind) {
      case "open":
        return { pane: "open", reply: `Chat view: ${modeOf(current)}. Settings are open above the prompt; /feed close shuts them.` };
      case "close":
        return { pane: "close", reply: "Chat view settings closed." };
      case "status":
        return { reply: `${current.on ? "on" : "off"} · ${modeOf(current)}` };
      case "usage":
        return { reply: usageLine() };
      case "switch":
        return { session: { ...current, on: cmd.on }, reply: `Chat view: ${cmd.on ? "on" : "off"}.` };
      case "preset":
        return { session: cmd.to === "raw" ? { ...current, on: false } : { on: true, view: { ...PRESETS[cmd.to].fields, hide: current.view.hide } }, reply: `Chat view: ${cmd.to}. ${cmd.to === "raw" ? RAW_HELP : PRESETS[cmd.to].help}.` };
      case "hide":
      case "show": {
        const hide = cmd.kind === "hide" ? [...new Set([...current.view.hide, cmd.what])] : current.view.hide.filter((kind) => kind !== cmd.what);
        return { session: { on: true, view: { ...current.view, hide } }, reply: `Chat view: ${cmd.what} ${cmd.kind === "hide" ? "hidden" : "shown"}.` };
      }
      case "set": {
        const view = { ...current.view, [cmd.field]: cmd.value };
        return { session: { on: true, view }, reply: `Chat view: ${cmd.field} ${spoken(cmd.value)}.` };
      }
    }
  }
  function usageLine() {
    return ["/feed opens the settings", "/feed on | off | status", "/feed clean | normal | raw", ...FIELDS.map((spec) => `/feed ${spec.word} ${spec.values.map(spoken).join("|")}`), "/feed hide|show <kind>", "/feed close"].join(" · ");
  }

  // mods/cs-feed/hooks/words.ts
  var labels = { you: "you", claude: "claude", backgroundUpdate: "background task update", reportHint: "ctrl+o shows the whole report" };
  var marks = { dot: "·", live: "●", idle: "○", peer: "⇄", closed: "›", opened: "⌄", question: "?", failed: "✕", working: "◐" };
  var braille = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
  var breathing = ["·", "•", "●", "•"];
  var usagePeriods = { fiveHour: "5h", week: "week" };
  var settingsWords = { title: "Chat view", switch: "Feed", shortcuts: "· /feed clean · /feed normal · /feed raw · /feed close", show: "Show", hideHelp: "/feed hide <kind> · /feed show <kind>" };
  function settingValue(value) {
    return typeof value === "boolean" ? value ? "on" : "off" : value;
  }
  function settingCommand(word, value) {
    return `/feed ${word} ${settingValue(value)}`;
  }
  function kindChip(kind, shown) {
    return `${shown ? marks.live : marks.idle} ${kind}`;
  }
  var logs = {
    viewUnusable: (path, reason) => `could not use ${path}: ${reason}; the feed draws its default view until /feed writes the file again`,
    unread: (path, reason) => `could not read ${path}: ${reason}`,
    feedOff: (refusal) => `the feed is off in this session: ${refusal}`,
    clockStopped: (reason) => `clock stopped: ${reason}`,
    pulseStopped: (reason) => `pulse stopped: ${reason}`,
    helperUnread: (id, deny) => `could not read helper ${id}'s transcript: ${deny}`
  };
  var replies = {
    notASession: "this directory is not a cs session (no .cs/local), so nothing changed.",
    refused: (refusal) => `no feed change in this session: ${refusal}`,
    helpersOpen: "Helpers open above the prompt."
  };
  var commands = {
    feed: { name: "feed", description: "Chat view for this session: on, off, clean, normal, raw, or one setting", argumentHint: "on | off | clean | normal | raw | status | <setting> <value>", immediate: true },
    helpers: { name: "helpers", description: "Show each helper's own work, call by call", immediate: true }
  };
  function moreKinds(count) {
    return `+${count} more ${count === 1 ? "kind" : "kinds"}`;
  }
  function helperCounts(states, durationMs) {
    const done = states.filter((state) => state === "finished").length;
    const running = states.filter((state) => state === "running" || state === "dispatched").length;
    const failed = states.filter((state) => state === "failed" || state === "stopped").length;
    return joined([`${states.length} ${states.length === 1 ? "helper" : "helpers"}`, done ? `${done} done` : undefined, running ? `${running} running` : undefined, failed ? `${failed} failed` : undefined, durationMs === undefined ? undefined : elapsed(durationMs)]);
  }
  function helperFraction(done, count, failed = 0) {
    return joined([`${done}/${count}`, failed ? `${failed} failed` : undefined]);
  }
  function backgroundLine(words, isTest, more) {
    const label = /[|;&><`$\/]|^(?:cd|bash|python|node|npm|git|pgrep)\b/.test(words) ? "Running a shell command" : words;
    return joined([isTest ? "Test running" : "Running in the background", label, more ? `+${more} more` : undefined]);
  }
  function backgroundTail(durationMs, typing) {
    const tail = joined([durationMs === undefined ? undefined : elapsed(durationMs), typing ? "you can keep typing" : undefined]);
    return tail ? `${marks.dot} ${tail}` : "";
  }
  function usageLabel(percent, period) {
    return joined([`${Math.round(percent)}%`, period]);
  }
  function pillLabel(pill) {
    return joined([pill.kind === "helper" ? "Helper" : pill.kind === "test" ? "⚗ Test" : "Job", pill.words, pill.elapsedMs === undefined ? undefined : elapsed(pill.elapsedMs)]);
  }
  var helpersPaneWords = { none: "No helper ran in this session.", now: "now:" };
  function helperPaneHead(name, status, durationMs) {
    return joined([name, status, durationMs === undefined ? undefined : elapsed(durationMs)]);
  }
  function helperNowLine(step) {
    return `${helpersPaneWords.now} ${step}`;
  }
  function slashCommand(text) {
    const match = /^(\/[A-Za-z0-9][\w:.-]*)(?:\s+([\s\S]*))?$/.exec(text.trim());
    return match?.[1] ? { name: match[1], args: (match[2] ?? "").trim() } : undefined;
  }
  function joined(parts) {
    return parts.filter((part) => part !== undefined && part !== "").join(" · ");
  }
  function peerLine(sender, headline) {
    return `${marks.peer} ${joined([sender, headline])}`;
  }
  function hookNotice(line) {
    return `${marks.idle} ${line}`;
  }
  function burstLine(members) {
    const last = members.at(-1)?.at;
    return `${marks.peer} ${joined([`${members.length} messages`, [...new Set(members.map((member) => member.sender))].join(", "), last === undefined ? undefined : `last ${hhmm(last)}`])}`;
  }
  function helperNoteLine(headline, durationMs) {
    return `${marks.peer} ${joined(["helper", durationMs === undefined ? undefined : elapsed(durationMs), headline])}`;
  }
  function helperLine(call, state, durationMs) {
    const working = state === "running" || state === "dispatched";
    return joined([callWords(call, working ? "present" : "past"), working ? "running" : state, durationMs === undefined ? undefined : elapsed(durationMs)]);
  }
  function outputLines(output) {
    const text = typeof output === "string" ? output : output && typeof output === "object" && !Array.isArray(output) ? ["stdout", "stderr"].flatMap((key) => {
      const value = output[key];
      return typeof value === "string" ? [value] : [];
    }).join(`
`) : "";
    return text.split(`
`).filter((line, index, rows) => line !== "" || index < rows.length - 1).slice(0, 12);
  }
  function questionLines(call, filed) {
    if (filed?.outcome.state === "done" && filed.outcome.answers?.length)
      return filed.outcome.answers.map((pair) => `${marks.question} ${pair.question} → ${pair.answer}`);
    const questions = Array.isArray(call.input.questions) ? call.input.questions.flatMap((question) => {
      if (!question || typeof question !== "object" || !("question" in question) || typeof question.question !== "string")
        return [];
      return [question.question.split(/(?<=[?.!])\s/)[0] ?? question.question];
    }) : [];
    return [...questions.map((question) => `Asked you: ${question}`), ...call.isRunning ? [] : ["No answer"]];
  }
  function frameHead(frame) {
    return `${marks.peer} ${joined([frame.from, frame.state, frame.at === undefined ? undefined : hhmm(frame.at), frame.summary, frame.relays ? "relays content written by others" : undefined])}`;
  }
  function frameBody(frame) {
    const lead = frame.lead;
    if (!lead)
      return [];
    const card = lead.card;
    if (!card)
      return [
        ...lead.text ? [{ kind: "markdown", text: lead.text }] : [],
        ...lead.more ? [{ kind: "hint", text: `+${lead.more} more ${lead.more === 1 ? "line" : "lines"} · ctrl+o shows all` }] : []
      ];
    const lines = [];
    if (lead.sentence)
      lines.push({ kind: "markdown", text: lead.sentence });
    if (card.status || card.sub)
      lines.push({ kind: "status", tone: card.tone, glyph: card.tone === "ok" ? "✓" : card.tone === "bad" ? marks.failed : marks.live, status: card.status, sub: card.sub });
    if (card.target)
      lines.push({ kind: "text", text: `target ${card.target}` });
    for (const score of card.scores)
      lines.push({ kind: "score", label: score.label, dots: score.dots, tally: `${score.pass} of ${score.of} pass` });
    for (const list of card.lists)
      lines.push({ kind: "list", label: list.label, count: String(list.count), first: `${marks.dot} ${list.first}` });
    if (card.report)
      lines.push({ kind: "text", text: `report ${card.report}` });
    lines.push({ kind: "hint", text: labels.reportHint });
    return lines;
  }
  function callWords(call, tense) {
    const description = typeof call.input.description === "string" ? clean(call.input.description) : "";
    if (description.length >= 3)
      return description;
    const past = tense === "past";
    const path = call.input.file_path ?? call.input.notebook_path;
    const file = typeof path === "string" ? basename(path) : "";
    const skill = typeof call.input.skill === "string" ? clean(call.input.skill) : "";
    const host = typeof call.input.url === "string" ? hostname(call.input.url) : undefined;
    switch (call.tool) {
      case "Bash":
      case "PowerShell":
        return past ? "Ran a shell command" : "Running a shell command";
      case "Read":
        return `${past ? "Read" : "Reading"} ${file || "a file"}`;
      case "Edit":
      case "MultiEdit":
      case "Write":
      case "NotebookEdit":
        return `${past ? "Edited" : "Editing"} ${file || "a file"}`;
      case "Grep":
      case "Glob":
        return past ? "Searched the code" : "Searching the code";
      case "WebSearch":
        return past ? "Searched the web" : `Searching the web${typeof call.input.query === "string" && call.input.query ? ` for ${clean(call.input.query)}` : ""}`;
      case "WebFetch":
        return `${past ? "Opened" : "Opening"} ${host || "a web page"}`;
      case "Skill":
        return `${past ? "Loaded" : "Loading"} ${skill ? `the ${skill} skill` : "a skill"}`;
      case "Agent":
      case "Task":
        return past ? "Asked a helper" : "Asking a helper";
      case "AskUserQuestion":
        return past ? "Used AskUserQuestion" : "Asking you a question";
      case "TodoWrite":
        return past ? "Updated the todo list" : "Updating the todo list";
      default:
        return `${past ? "Used" : "Using"} ${toolName(call.tool)}`;
    }
  }
  function clean(text) {
    return (text.split(`
`).find((line) => line.trim()) ?? "").replace(/\b[A-Za-z_][A-Za-z_0-9]*=(?:"[^"]*"|'[^']*'|\S+)/g, "").replace(/(?:~\/|\.\.?\/|\/)[^\s,;]+/g, (path) => basename(path)).replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "").replace(/\b[0-9a-f]{12,}\b/gi, "").replace(/\S{20,}/g, (token) => /\d/.test(token) ? "" : token).replace(/\s+/g, " ").replace(/\s+([.,;:!?])/g, "$1").trim();
  }
  function basename(path) {
    return path.replace(/\/+$/, "").split(/[\\/]/).at(-1) ?? "";
  }
  function hostname(value) {
    try {
      const url = new URL(value);
      return url.protocol === "http:" || url.protocol === "https:" ? url.hostname.replace(/^www\./, "") : undefined;
    } catch {
      return;
    }
  }
  function toolName(tool) {
    return tool.startsWith("mcp__") ? tool.slice(5).replace(/^claude_ai_/, "").replace(/_+/g, " ") : tool;
  }
  function runWords(run, t, naming) {
    if (naming)
      return naming;
    const calls = run.calls.flatMap((id) => {
      const call = t.calls.get(id);
      return call ? [call] : [];
    });
    const ran = calls.filter((call) => call.outcome.state !== "done" || !call.outcome.refused);
    if (calls.length && !ran.length)
      return refusedWords(calls.length);
    const first = calls[0];
    if (calls.length === 1 && first)
      return callWords(first, first.outcome.state === "running" ? "present" : "past");
    const counts = new Map;
    for (const call of ran) {
      const kind = call.tool === "Bash" || call.tool === "PowerShell" ? "shell" : ["Edit", "MultiEdit", "Write", "NotebookEdit"].includes(call.tool) ? "Edit" : call.tool === "Glob" ? "Grep" : call.tool === "Task" ? "Agent" : call.tool;
      counts.set(kind, (counts.get(kind) ?? 0) + 1);
    }
    const text = [...counts].sort(([a, n], [b, m]) => m - n || (a < b ? -1 : a > b ? 1 : 0)).map(([kind, n]) => countWords(kind, n)).join(" · ");
    return text.charAt(0).toUpperCase() + text.slice(1);
  }
  function refusedWords(n) {
    return `${n} ${n === 1 ? "step" : "steps"} refused by a hook`;
  }
  function countWords(kind, n) {
    const noun = (word) => `${n} ${word}${n === 1 ? "" : "s"}`;
    const times = n === 1 ? "once" : `${n} times`;
    switch (kind) {
      case "shell":
        return `ran ${noun("shell command")}`;
      case "Read":
        return `read ${noun("file")}`;
      case "Edit":
        return `made ${noun("edit")}`;
      case "Grep":
        return `searched the code ${times}`;
      case "Skill":
        return `loaded ${noun("skill")}`;
      case "WebSearch":
        return `searched the web ${times}`;
      case "WebFetch":
        return `opened ${noun("web page")}`;
      case "Agent":
        return `asked ${noun("helper")}`;
      default:
        return `used ${toolName(kind)} ${times}`;
    }
  }
  function runChips(run, t) {
    const outcomes = run.calls.flatMap((id) => {
      const outcome = t.calls.get(id)?.outcome;
      return outcome?.state === "done" ? [outcome] : [];
    });
    const refused = outcomes.filter((outcome) => outcome.refused).length;
    const failed = outcomes.filter((outcome) => outcome.errored && !outcome.refused).length;
    const lines = outcomes.reduce((n, outcome) => n + outcome.lines, 0);
    return [...refused && refused < run.calls.length ? [refusedWords(refused)] : [], ...failed ? [`${failed} failed`] : [], ...lineChip(lines)];
  }
  function callChips(call, filed) {
    if (call.isRunning)
      return [];
    const outcome = filed?.outcome;
    const text = typeof call.output === "string" ? call.output : "";
    const refused = call.isErrored && (isRefusal(text) || outcome?.state === "done" && outcome.refused);
    const lines = outcome?.state === "done" ? outcome.lines : text.trim() ? text.trimEnd().split(`
`).length : 0;
    return [...refused ? [refusedWords(1)] : call.isErrored ? ["1 failed"] : [], ...lineChip(lines)];
  }
  function lineChip(lines) {
    return lines ? [`+${lines} ${lines === 1 ? "line" : "lines"}`] : [];
  }
  function stepsLine(done) {
    return `${done} ${done === 1 ? "step" : "steps"} this turn`;
  }
  function fit(text, room) {
    if (text.length <= room)
      return text;
    const width = Math.max(4, room - 1);
    const space = text.lastIndexOf(" ", width);
    return text.slice(0, space > width / 2 ? space : width).replace(/[\s·,;:|\-]+$/, "") + "…";
  }
  function elapsed(ms) {
    const seconds = Math.max(0, Math.floor(ms / 1000));
    if (seconds < 60)
      return `${seconds}s`;
    if (seconds < 3600)
      return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
    return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
  }
  function hhmm(at) {
    const date = new Date(at);
    return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  }
  function isRefusal(text) {
    return /(?:PreToolUse|PermissionRequest)(?::\S+)?\s+hook\s+(?:error|blocked|denied)|blocked by a hook|hook[^\n]*denied/i.test(text);
  }
  function errorLine(text) {
    const prefixed = /^(?:API Error|Error:|Request timed out|Connection error|Claude AI usage limit|Credit balance|Invalid API key|Please run \/login|Prompt is too long)/i.test(text);
    if (!prefixed && text.includes(`
`))
      return;
    const content = text.replace(/^(?:API Error|Error):?\s*/i, "");
    const who = content.match(/^(.{1,40})['’]s safeguards/i)?.[1];
    const line = (head, rest, tone, act = tone === "red") => ({ head, rest, tone, act });
    if (who && /stopped the response above|continuing/i.test(content))
      return line(`${who}'s safeguards cut the reply above`, ["Claude continues", "esc esc goes back to an earlier message"], "violet");
    if (/stopped by a safety classifier/i.test(content))
      return line("A safeguard cut the reply above", ["Claude continues", "esc esc goes back to an earlier message"], "violet");
    if (!prefixed)
      return;
    if (/safeguards|usage policy|\/legal\/aup/i.test(content))
      return line(`${who ?? "The model"}'s safeguards stopped this reply`, ["often a false alarm", "esc esc to edit your message, or /model to switch"], "violet", true);
    if (/529|overloaded/i.test(content))
      return line("Claude's servers are busy", ["not your setup", "Claude Code retries, or send again"], "amber");
    if (/usage limit|rate limit|429/i.test(content)) {
      const reset = content.match(/resets?\s+([^\n,;]+)/i)?.[1]?.trim();
      return line("Usage limit reached", [...reset ? [`resets ${reset}`] : [], "nothing is lost", "/model to switch"], "red");
    }
    if (/prompt is too long|context length|too many tokens/i.test(content))
      return line("This chat is too long for the model", ["run /compact", "nothing is lost"], "red");
    if (/401|403|authentication|login|api key|oauth/i.test(content))
      return line("Login needed", ["run /login", "nothing is lost"], "red");
    if (/credit|billing/i.test(content))
      return line("Billing problem on the account", ["nothing is lost"], "red");
    if (/connection|network|socket|timeout|timed out/i.test(content))
      return line("Connection lost", ["check your internet", "send again to retry"], "amber");
    if (/\b5\d\d\b|server_error|internal/i.test(content))
      return line("Server error on Claude's side", ["your work is kept", "send a message to try again"], "amber");
    if (/400|invalid_request|max_output/i.test(content))
      return line("Claude refused this request", ["ctrl+o shows why", "esc esc to edit your message"], "red");
    return line("Claude Code hit an error", ["ctrl+o shows it"], "amber");
  }

  // mods/cs-feed/hooks/draw.tsx
  function inks(light) {
    return light ? { you: "#2f4f6f", claude: "#8a4a1f", peer: "#5b3fb5", mark: "#5b3fb5", chip: "#e4e6eb", green: "#1f7a4a", red: "#b42318", amber: "#8a5a00", accent: "#d97757" } : { you: "#9fb4c8", claude: "#e3c4a2", peer: "#a78bfa", mark: "#b9acec", chip: "#3b3b3b", green: "#7fbf8f", red: "#e06c6c", amber: "#d8b36a", accent: "#d97757" };
  }
  var NOTHING = (pen) => pen.el.Box({});
  function drawCommandOutput(v, pen) {
    const { Box, Text } = pen.el;
    return /* @__PURE__ */ h(Box, {
      paddingLeft: pen.pad,
      flexDirection: "row"
    }, /* @__PURE__ */ h(Box, {
      width: 2
    }, /* @__PURE__ */ h(Text, {
      dimColor: true
    }, marks.dot)), /* @__PURE__ */ h(Text, {
      color: v.isErrored ? pen.ink.red : undefined,
      dimColor: !v.isErrored
    }, v.text));
  }
  function drawCall(v, pen) {
    const { Box, Text, Button } = pen.el;
    switch (v.draw) {
      case "nothing":
        return NOTHING(pen);
      case "turn":
        return /* @__PURE__ */ h(Box, {
          flexDirection: "column"
        }, v.done > 0 ? /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad,
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          dimColor: true
        }, stepsLine(v.done)), chevron(`turn-${v.turn}`, v.opened, pen)) : null, v.opened ? /* @__PURE__ */ h(Box, {
          paddingLeft: 2,
          flexDirection: "column"
        }, v.body.map((call) => drawCall(call, pen))) : null);
      case "run": {
        const naming = v.naming ? pen.cx.t.calls.get(v.naming) : undefined;
        const words = runWords(v.run, pen.cx.t, naming ? callWords(naming, "present") : undefined);
        const chips = !naming && pen.cx.view.style !== "line" ? runChips(v.run, pen.cx.t) : [];
        return /* @__PURE__ */ h(Box, {
          flexDirection: "column"
        }, /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad,
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          color: naming ? pen.ink.accent : undefined,
          dimColor: !naming
        }, naming ? marks.live : marks.idle), /* @__PURE__ */ h(Text, null, fit(words, pen.room - 4)), chips.map((chip) => /* @__PURE__ */ h(Text, {
          backgroundColor: pen.ink.chip
        }, chip)), chevron(`open-${v.run.id}`, v.opened, pen)), v.opened ? /* @__PURE__ */ h(Box, {
          paddingLeft: 2,
          flexDirection: "column"
        }, v.run.calls.flatMap((id) => {
          const filed = pen.cx.t.calls.get(id);
          if (!filed)
            return [];
          const done = filed.outcome.state === "done" ? filed.outcome : undefined;
          return [drawCall({ draw: "call", call: { id, tool: filed.tool, input: filed.input, isRunning: !done, isErrored: done?.errored === true, isInterrupted: done?.interrupted === true, output: done?.output }, filed, opened: true }, pen)];
        })) : null);
      }
      case "call": {
        const chips = pen.cx.view.style === "line" ? [] : callChips(v.call, v.filed);
        return /* @__PURE__ */ h(Box, {
          flexDirection: "column"
        }, /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad,
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          color: v.call.isErrored ? pen.ink.red : v.call.isRunning ? pen.ink.accent : undefined,
          dimColor: !v.call.isRunning && !v.call.isErrored
        }, v.call.isRunning ? marks.live : marks.idle), /* @__PURE__ */ h(Text, null, fit(callWords(v.call, v.call.isRunning ? "present" : "past"), pen.room - 4)), chips.map((chip) => /* @__PURE__ */ h(Text, {
          backgroundColor: pen.ink.chip
        }, chip)), v.call.id ? chevron(v.call.id, v.opened, pen) : null), v.opened ? /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad + 2,
          flexDirection: "column"
        }, outputLines(v.call.output ?? (v.filed?.outcome.state === "done" ? v.filed.outcome.output : undefined)).map((line) => /* @__PURE__ */ h(Text, {
          dimColor: true
        }, line))) : null);
      }
      case "helper":
        return /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad,
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          color: v.state === "failed" || v.state === "stopped" ? pen.ink.red : pen.ink.peer
        }, helperLine(v.call, v.state, v.elapsedMs)), pen.clickable ? /* @__PURE__ */ h(Button, {
          key: `helper-${v.call.id ?? v.call.tool}`,
          label: marks.closed,
          plain: true,
          dimColor: true,
          onPress: pen.helpers
        }) : /* @__PURE__ */ h(Text, {
          dimColor: true
        }, marks.closed));
      case "question":
        return /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad,
          flexDirection: "column"
        }, questionLines(v.call, v.call.id ? pen.cx.t.calls.get(v.call.id) : undefined).map((line) => /* @__PURE__ */ h(Text, null, line)));
    }
  }
  function drawGroup(v, pen) {
    const { Box, Text } = pen.el;
    if (v.draw === "stack")
      return /* @__PURE__ */ h(Box, {
        flexDirection: "column"
      }, v.calls.map((call) => drawCall(call, pen)));
    const busy = v.helpers.some((helper) => helper.state === "running" || helper.state === "dispatched");
    const failed = v.helpers.some((helper) => helper.state === "failed" || helper.state === "stopped");
    const kinds = [...new Set(v.helpers.map((helper) => helper.kind))];
    const cell = (state) => /* @__PURE__ */ h(Text, {
      color: state === "failed" || state === "stopped" ? pen.ink.red : state === "finished" ? pen.ink.green : pen.ink.peer
    }, state === "failed" || state === "stopped" ? marks.failed : state === "finished" ? marks.live : marks.working);
    return /* @__PURE__ */ h(Box, {
      flexDirection: "column"
    }, /* @__PURE__ */ h(Box, {
      paddingLeft: pen.pad,
      flexDirection: "row",
      gap: 1
    }, /* @__PURE__ */ h(Text, {
      color: busy ? pen.ink.peer : failed ? pen.ink.red : pen.ink.green
    }, busy ? braille[Math.floor(pen.cx.now / 70) % braille.length] : failed ? marks.failed : marks.live), /* @__PURE__ */ h(Text, null, helperCounts(v.helpers.map((helper) => helper.state), v.elapsedMs)), chevron(v.key, v.opened, pen)), kinds.map((kind) => {
      const members = v.helpers.filter((helper) => helper.kind === kind);
      return /* @__PURE__ */ h(Box, {
        paddingLeft: pen.pad + 2,
        flexDirection: "row",
        gap: 1
      }, /* @__PURE__ */ h(Text, {
        dimColor: true
      }, fit(kind, 22)), /* @__PURE__ */ h(Text, {
        dimColor: true
      }, String(members.length)), members.map((helper) => cell(helper.state)), /* @__PURE__ */ h(Text, {
        dimColor: true
      }, helperFraction(members.filter((helper) => helper.state === "finished").length, members.length, members.filter((helper) => helper.state === "failed" || helper.state === "stopped").length)));
    }), v.opened ? v.helpers.map((helper) => /* @__PURE__ */ h(Box, {
      paddingLeft: pen.pad + 2,
      flexDirection: "row",
      gap: 1
    }, cell(helper.state), /* @__PURE__ */ h(Text, null, fit(callWords(helper.call, helper.state === "running" || helper.state === "dispatched" ? "present" : "past"), 60)))) : null);
  }
  function drawUser(v, pen) {
    const { Box, Text } = pen.el;
    switch (v.draw) {
      case "nothing":
        return NOTHING(pen);
      case "you": {
        const command = slashCommand(v.text);
        const text = command ? /* @__PURE__ */ h(Box, {
          flexGrow: 1,
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.you
        }, command.name), command.args ? /* @__PURE__ */ h(Text, {
          dimColor: true
        }, command.args) : null) : /* @__PURE__ */ h(Box, {
          flexGrow: 1
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.you
        }, v.text));
        return /* @__PURE__ */ h(Box, {
          flexDirection: "column",
          marginTop: 1
        }, /* @__PURE__ */ h(Box, {
          flexDirection: "row"
        }, /* @__PURE__ */ h(Box, {
          width: pen.pad
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.you,
          dimColor: true
        }, labels.you)), text, v.at === undefined ? null : /* @__PURE__ */ h(Text, {
          dimColor: true
        }, hhmm(v.at))));
      }
      case "hookText":
        return /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad
        }, /* @__PURE__ */ h(Text, {
          dimColor: true
        }, hookNotice(v.line)));
      case "peer":
        return /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad + (v.nested ? 2 : 0)
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.peer
        }, peerLine(v.sender, v.headline)));
      case "helperNote":
        return /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.peer
        }, helperNoteLine(v.headline, v.durationMs)));
      case "backgroundNote":
        return /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad
        }, /* @__PURE__ */ h(Text, {
          dimColor: true
        }, labels.backgroundUpdate));
      case "burst": {
        const head = v.members[0];
        if (!head)
          return NOTHING(pen);
        return /* @__PURE__ */ h(Box, {
          flexDirection: "column",
          paddingLeft: pen.pad
        }, /* @__PURE__ */ h(Box, {
          flexDirection: "row"
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.peer
        }, burstLine(v.members)), chevron(`burst-${head.uuid}`, v.opened, pen)), v.own ? /* @__PURE__ */ h(Box, {
          paddingLeft: 2
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.peer
        }, peerLine(v.own.sender, v.own.headline))) : null);
      }
      case "frames":
        return /* @__PURE__ */ h(Box, {
          flexDirection: "column",
          paddingLeft: pen.pad
        }, v.frames.map((frame) => /* @__PURE__ */ h(Box, {
          flexDirection: "column"
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.peer
        }, frameHead(frame)), /* @__PURE__ */ h(Box, {
          flexDirection: "column",
          paddingLeft: 2
        }, frameBody(frame).map((line) => drawFrameLine(line, pen))))));
    }
  }
  function drawFrameLine(line, pen) {
    const { Box, Markdown, Text } = pen.el;
    const tone = (value) => value === "ok" ? pen.ink.green : value === "bad" ? pen.ink.red : pen.ink.amber;
    switch (line.kind) {
      case "markdown":
        return /* @__PURE__ */ h(Markdown, {
          text: line.text
        });
      case "status":
        return /* @__PURE__ */ h(Box, {
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          color: tone(line.tone)
        }, line.glyph), line.status ? /* @__PURE__ */ h(Text, null, line.status) : null, line.sub ? /* @__PURE__ */ h(Text, {
          dimColor: true
        }, line.sub) : null);
      case "text":
        return /* @__PURE__ */ h(Text, null, line.text);
      case "score":
        return /* @__PURE__ */ h(Box, {
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, null, line.label), /* @__PURE__ */ h(Box, {
          flexDirection: "row"
        }, line.dots.map((dot) => /* @__PURE__ */ h(Text, {
          color: tone(dot)
        }, marks.live))), /* @__PURE__ */ h(Text, {
          dimColor: true
        }, line.tally));
      case "list":
        return /* @__PURE__ */ h(Box, {
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, null, line.label), /* @__PURE__ */ h(Text, {
          bold: true
        }, line.count), /* @__PURE__ */ h(Text, {
          dimColor: true
        }, line.first));
      case "hint":
        return /* @__PURE__ */ h(Text, {
          dimColor: true
        }, line.text);
    }
  }
  function chevron(key, opened, pen) {
    const { Button, Text } = pen.el;
    const label = opened ? marks.opened : marks.closed;
    return pen.clickable ? /* @__PURE__ */ h(Button, {
      key,
      label,
      plain: true,
      dimColor: true,
      onPress: () => pen.press(key)
    }) : /* @__PURE__ */ h(Text, {
      dimColor: true
    }, label);
  }
  function drawReply(v, engine, pen) {
    const { Box, Text } = pen.el;
    const body = typeof v.body === "object" ? /* @__PURE__ */ h(Box, {
      flexDirection: "column",
      paddingLeft: pen.pad
    }, /* @__PURE__ */ h(Text, {
      color: v.body.error.tone === "red" ? pen.ink.red : v.body.error.tone === "amber" ? pen.ink.amber : pen.ink.peer
    }, v.body.error.head), v.body.error.rest.map((line) => /* @__PURE__ */ h(Text, {
      dimColor: true
    }, line))) : v.body === "nothing" ? NOTHING(pen) : /* @__PURE__ */ h(Box, {
      flexDirection: "row"
    }, /* @__PURE__ */ h(Box, {
      width: pen.pad
    }, v.name ? /* @__PURE__ */ h(Text, {
      color: pen.ink.claude,
      dimColor: true
    }, labels.claude) : null), /* @__PURE__ */ h(Box, {
      flexGrow: 1,
      flexDirection: "column"
    }, engine));
    return /* @__PURE__ */ h(Box, {
      flexDirection: "column"
    }, body, v.stepsLine ? drawCall(v.stepsLine, pen) : null);
  }
  function drawBand(v, beneath, frame, pen) {
    const { Box, Text } = pen.el;
    let ours;
    switch (v.draw) {
      case "helpers":
        ours = /* @__PURE__ */ h(Box, {
          flexDirection: "column",
          paddingLeft: pen.pad
        }, /* @__PURE__ */ h(Box, {
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.peer
        }, v.spinning ? braille[frame % braille.length] : marks.live), /* @__PURE__ */ h(Text, {
          color: pen.ink.peer
        }, v.head)), v.kinds.map((kind) => /* @__PURE__ */ h(Box, {
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          dimColor: true
        }, kind.kind), [...kind.cells].map((cell) => /* @__PURE__ */ h(Text, {
          color: cell === marks.working ? pen.ink.peer : cell === marks.failed ? pen.ink.red : pen.ink.green
        }, cell)), /* @__PURE__ */ h(Text, {
          dimColor: true
        }, helperFraction(kind.done, kind.n)))), v.more ? /* @__PURE__ */ h(Text, {
          dimColor: true
        }, moreKinds(v.more)) : null);
        break;
      case "background":
        ours = /* @__PURE__ */ h(Box, {
          paddingLeft: pen.pad,
          flexDirection: "row",
          gap: 1
        }, /* @__PURE__ */ h(Text, {
          color: pen.ink.accent
        }, breathing[Math.floor(frame / 2) % breathing.length]), /* @__PURE__ */ h(Text, null, fit(backgroundLine(v.words, v.isTest, v.more), pen.room)), /* @__PURE__ */ h(Text, {
          dimColor: true
        }, backgroundTail(v.elapsedMs, v.typing)));
        break;
      case "desktop":
        ours = /* @__PURE__ */ h(Box, {
          justifyContent: "flex-end",
          flexDirection: "row",
          gap: 1
        }, v.usage.fiveHour === undefined ? null : /* @__PURE__ */ h(Text, null, usageLabel(v.usage.fiveHour, usagePeriods.fiveHour)), v.usage.week === undefined ? null : /* @__PURE__ */ h(Text, null, usageLabel(v.usage.week, usagePeriods.week)), v.pills.map((pill) => /* @__PURE__ */ h(Text, {
          backgroundColor: pen.ink.chip
        }, pillLabel(pill))));
        break;
    }
    return /* @__PURE__ */ h(Box, {
      flexDirection: "column"
    }, ours, beneath);
  }
  function drawSettingsPane(mode, session, pen, onPress) {
    const { Box, Text, Button } = pen.el;
    return /* @__PURE__ */ h(Box, {
      flexDirection: "column"
    }, /* @__PURE__ */ h(Box, {
      flexDirection: "row",
      gap: 1
    }, /* @__PURE__ */ h(Text, {
      bold: true
    }, settingsWords.title), /* @__PURE__ */ h(Text, {
      color: pen.ink.accent
    }, mode), /* @__PURE__ */ h(Text, {
      dimColor: true
    }, settingsWords.shortcuts)), /* @__PURE__ */ h(Box, {
      flexDirection: "row",
      gap: 1
    }, /* @__PURE__ */ h(Button, {
      key: "btn-feed",
      label: settingsWords.switch,
      onPress: () => onPress({ kind: "switch", on: !session.on })
    }), /* @__PURE__ */ h(Text, {
      color: pen.ink.accent,
      bold: true
    }, settingValue(session.on))), FIELDS.map((spec) => {
      const current = session.view[spec.field];
      const next = spec.values[(spec.values.findIndex((value) => value === current) + 1) % spec.values.length];
      if (next === undefined)
        throw new Error(`setting ${spec.field} has no next value`);
      const command = settingCommand(spec.word, next);
      return /* @__PURE__ */ h(Box, {
        flexDirection: "column"
      }, /* @__PURE__ */ h(Box, {
        flexDirection: "row",
        gap: 1
      }, /* @__PURE__ */ h(Button, {
        key: `btn-${spec.field}`,
        label: spec.title,
        onPress: () => onPress(parseFeedArgs(command.slice(6)))
      }), /* @__PURE__ */ h(Text, {
        color: pen.ink.accent,
        bold: true
      }, settingValue(current)), /* @__PURE__ */ h(Text, {
        dimColor: true
      }, `${marks.dot} ${command}`)), /* @__PURE__ */ h(Box, {
        paddingLeft: 2,
        flexDirection: "column"
      }, fieldPicture(spec, session.view).map((line) => /* @__PURE__ */ h(Text, {
        dimColor: true
      }, fit(line, Math.max(1, pen.room - 4))))));
    }), /* @__PURE__ */ h(Text, {
      bold: true
    }, settingsWords.show), /* @__PURE__ */ h(Box, {
      flexDirection: "row",
      flexWrap: "wrap",
      columnGap: 1
    }, KINDS.map((kind) => {
      const shown = !session.view.hide.includes(kind);
      return /* @__PURE__ */ h(Button, {
        key: `kind-${kind}`,
        label: kindChip(kind, shown),
        onPress: () => onPress({ kind: shown ? "hide" : "show", what: kind })
      });
    })), /* @__PURE__ */ h(Text, {
      dimColor: true
    }, settingsWords.hideHelp));
  }
  function fieldPicture(spec, view) {
    switch (spec.field) {
      case "group":
      case "clear":
      case "keep":
        return spec.picture(view[spec.field]);
      case "style":
        return spec.picture(view.style);
      case "commands":
        return spec.picture(view.commands);
      case "after":
        return spec.picture(view.after);
    }
  }
  function drawHelpersPane(blocks, pen) {
    const { Box, Text } = pen.el;
    if (!blocks.length)
      return /* @__PURE__ */ h(Box, null, /* @__PURE__ */ h(Text, {
        dimColor: true
      }, helpersPaneWords.none));
    const room = Math.max(1, pen.room - 2);
    return /* @__PURE__ */ h(Box, {
      flexDirection: "column"
    }, blocks.map((block) => {
      const working = block.status === "working";
      return /* @__PURE__ */ h(Box, {
        flexDirection: "column"
      }, /* @__PURE__ */ h(Box, {
        flexDirection: "row",
        gap: 1
      }, /* @__PURE__ */ h(Text, {
        color: working ? pen.ink.accent : block.status === "finished" ? undefined : pen.ink.red,
        dimColor: !working
      }, working ? marks.live : marks.idle), /* @__PURE__ */ h(Text, null, fit(helperPaneHead(block.name, block.status, block.elapsedMs), room))), block.now ? /* @__PURE__ */ h(Box, {
        paddingLeft: 2
      }, /* @__PURE__ */ h(Text, {
        dimColor: true
      }, fit(helperNowLine(block.now), room))) : null, block.calls.map((call) => /* @__PURE__ */ h(Box, {
        paddingLeft: 2
      }, /* @__PURE__ */ h(Text, {
        dimColor: true
      }, fit(call, room)))));
    }));
  }

  // mods/cs-feed/hooks/transcript.ts
  function callId(value) {
    if (!value)
      throw new Error("A tool call id must not be empty");
    return value;
  }
  var EMPTY = { calls: new Map, turns: [], byId: new Map, runs: new Map, background: [] };

  // mods/cs-feed/hooks/verdict.ts
  function decideSpinner(props, cx) {
    if (props.message !== null || !cx.open)
      return { verdict: { draw: "engine" }, live: false };
    const steps = cx.open.steps.length;
    const running = cx.open.steps.map((id) => cx.t.calls.get(id)).findLast((call) => call?.outcome.state === "running");
    const words = cx.view.group && props.mode === "responding" ? "Writing" : cx.view.group && running ? callWords(running, "present") : steps ? "Working" : "Thinking";
    const helpers = cx.agents.filter((agent) => !agent.parentId && (agent.status === "running" || agent.status === "pending")).length;
    const message = words + (steps ? ` · step ${steps}` : "") + (helpers ? ` · ${helpers} ${helpers === 1 ? "helper" : "helpers"} working` : "");
    return { verdict: { draw: "rewrite", message, suffix: "" }, live: true, clock: helpers ? "tick" : undefined };
  }
  function sessionModes(modes, view) {
    return [...modes, `feed ${modeOf({ on: true, view })} · /feed to switch`];
  }

  // docs/surfaces/registry.ts
  function elements() {
    const el = globalThis.LabElements;
    if (el === undefined)
      throw new Error("the lab shim (docs/surfaces/shim.js) is not loaded: LabElements is undefined");
    return el;
  }

  // docs/surfaces/chrome.ts
  var cells = (s) => Array.from(s).length;
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
    const lane = cols - cap - 4 - 1;
    const column = widest > cap ? cap + (lane < 0 ? 2 : Math.min(2, lane)) : widest;
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
  function workingLine(w) {
    const el = elements();
    const dim = (s) => el.Text({ dimColor: true, children: s });
    return el.Box({ flexDirection: "column", children: [el.Box({ flexWrap: "wrap", marginTop: 1, children: [
      el.Box({ width: 2, height: 1, children: [el.Text({ color: "claude", children: "✻" })] }),
      el.Text({ color: "claude", children: w.suffix === "…" && /(…|\.\.\.)$/.test(w.message) ? w.message : w.message + w.suffix }),
      el.Text({ children: " " }),
      dim("("),
      dim(w.elapsed),
      dim(" · "),
      el.Box({ children: [el.Box({ width: 2, children: [dim("↓")] }), dim(`${w.tokens} tokens`)] }),
      dim(")")
    ] })] });
  }
  function footerModes(modes, cols) {
    const el = elements();
    return el.Box({ width: cols, paddingX: 2, justifyContent: "flex-end", children: modes.length === 0 ? [] : [el.Text({ dimColor: true, children: modes.join(" & ") })] });
  }
  function backgroundHint(hint) {
    const el = elements();
    return el.Box({ flexDirection: "column", children: hint === "" ? [] : [el.Box({ paddingLeft: 5, children: [el.Text({ dimColor: true, children: hint })] })] });
  }
  function turnLine(verb, duration, done) {
    const el = elements();
    return el.Box({ children: [
      el.Box({ minWidth: 2, children: [el.Text({ dimColor: true, children: "✻" })] }),
      el.Text({ children: [el.Text({ dimColor: true, children: `${verb} for ${duration} · done ${done}` })] })
    ] });
  }
  function nothing() {
    return elements().Box({});
  }

  // docs/surfaces/cs-feed.fixtures.ts
  var id = (n) => callId(`toolu_${String(n).padStart(2, "0")}`);
  var done = (lines, over = {}) => ({ state: "done", errored: false, refused: false, interrupted: false, lines, ...over });
  var TURN = id(1);
  var RUN = id(1);
  var REFUSED = id(6);
  var filed = (n, tool, input, outcome, run, cls = "machinery") => ({ id: id(n), tool, input, cls, outcome, turn: TURN, run, step: n });
  var CALLS = [
    filed(1, "Bash", { command: "bun test", description: "Run the tests" }, done(12, { output: `12 pass
0 fail` }), RUN),
    filed(2, "Bash", { command: "ls docs", description: "List the docs" }, done(4), RUN),
    filed(3, "Read", { file_path: "/repo/app.py" }, done(0), RUN),
    filed(4, "Bash", { command: "git status", description: "Show the working tree" }, done(2), RUN),
    filed(6, "Bash", { command: "rm -rf build", description: "Remove the build" }, done(1, { errored: true, refused: true, output: "PreToolUse:Bash hook blocked: rm -rf" }), REFUSED),
    filed(7, "Agent", { description: "Map the draw code", subagent_type: "Explore" }, done(0, { durationMs: 72000 }), undefined, "helper"),
    filed(8, "Agent", { description: "Read the tests", subagent_type: "Explore" }, { state: "running" }, undefined, "helper")
  ];
  var SHELL_RUN = { id: RUN, turn: TURN, calls: [id(1), id(2), id(3), id(4)] };
  var REFUSED_RUN = { id: REFUSED, turn: TURN, calls: [REFUSED] };
  var RUNS = [SHELL_RUN, REFUSED_RUN];
  var transcript = {
    calls: new Map(CALLS.map((call) => [call.id, call])),
    turns: [{ id: TURN, first: id(1), steps: [id(1), id(2), id(3), id(4), REFUSED], runs: [RUN, REFUSED] }],
    byId: new Map,
    runs: new Map(RUNS.map((run) => [run.id, run])),
    background: []
  };
  var observations = () => ({
    promptAt: new Map,
    frames: new Map,
    bursts: { of: new Map, members: new Map },
    batch: { kinds: new Map },
    anchors: new Map,
    latestByCall: new Map,
    anchorSeq: 0,
    stepsDrawn: new Map,
    turnOpeners: new Set,
    peerPending: false,
    helperStartedAt: new Map,
    bgSeenAt: new Map,
    bgEnded: new Set,
    phase: "idle"
  });
  var PAD = 7;
  var context = (cols, view, t) => ({ t, view, obs: observations(), opened: new Set, phase: "idle", agents: [], now: 0, surface: "terminal", clickable: false, room: cols - PAD });
  var pen = (cols, theme, over = {}) => {
    const cx = context(cols, over.view ?? DEFAULT_VIEW, over.t ?? transcript);
    return { el: elements(), ink: inks(theme === "light"), room: cx.room, pad: over.pad ?? PAD, clickable: over.clickable ?? false, press: async () => {}, helpers: async () => {}, cx: { ...cx, clickable: over.clickable ?? false } };
  };
  var state = (id, name, draw) => ({ id, name, draw });
  var PROMPT_AT = new Date(2026, 9, 25, 9, 41).getTime();
  var user = (v) => (cols, theme) => drawUser(v, pen(cols, theme));
  var CARD = { tone: "ok", status: "gate green", sub: "42 tests", target: "main", scores: [{ label: "suites", dots: ["ok", "ok", "ok", "bad"], pass: 3, of: 4 }], lists: [{ label: "findings", count: 2, first: "the band clips at 60 cols" }], report: "gate.md" };
  var userStates = [
    state("you", "reading a prompt they typed", user({ draw: "you", text: "fix the login redirect" })),
    state("you-at", "reading a prompt with the time they sent it", user({ draw: "you", text: "fix the login redirect", at: PROMPT_AT })),
    state("you-slash", "reading a slash command they ran", user({ draw: "you", text: "/feed clean" })),
    state("hook-text", "reading what a hook added to their prompt", user({ draw: "hookText", line: "cs: the band names prompt 4" })),
    state("peer", "reading a message from another session", user({ draw: "peer", sender: "fix-auth", headline: "gate green, ready to land" })),
    state("peer-nested", "reading one message of an opened burst", user({ draw: "peer", sender: "fix-auth", headline: "gate green, ready to land", nested: true })),
    state("burst-closed", "skimming several messages folded into one line", user({ draw: "burst", members: [{ uuid: "u1", sender: "fix-auth", at: PROMPT_AT }, { uuid: "u2", sender: "docs", at: PROMPT_AT }], opened: false })),
    state("burst-opened", "reading the first message of an opened burst", user({ draw: "burst", members: [{ uuid: "u1", sender: "fix-auth", at: PROMPT_AT }, { uuid: "u2", sender: "docs", at: PROMPT_AT }], opened: true, own: { sender: "fix-auth", headline: "gate green, ready to land" } })),
    state("helper-note", "told a helper finished", user({ draw: "helperNote", durationMs: 12000, headline: "mapped the draw code" })),
    state("background-note", "told a background task moved", user({ draw: "backgroundNote" })),
    state("frames-text", "reading a teammate report with more lines folded", user({ draw: "frames", frames: [{ from: "fix-auth", state: "waiting", at: PROMPT_AT, relays: false, lead: { text: "Gate **green**; run `/finish` to land.", more: 3 } }] })),
    state("frames-card", "reading a teammate verdict card", user({ draw: "frames", frames: [{ from: "fix-auth", state: "waiting", relays: true, lead: { sentence: "The gate ran on the branch head.", card: CARD, more: 0 } }] }))
  ];
  var ENGINE_REPLY = "Fixed: the token now **refreshes** before `fetch` retries.";
  var reply = (v, over = {}) => (cols, theme) => drawReply(v, elements().Markdown({ text: ENGINE_REPLY }), pen(cols, theme, over));
  var stepsClosed = { draw: "turn", turn: TURN, done: 5, opened: false, body: [] };
  var stepsOpened = { draw: "turn", turn: TURN, done: 5, opened: true, body: [{ draw: "run", run: SHELL_RUN, opened: false }, { draw: "run", run: REFUSED_RUN, opened: false }] };
  var ERRORS = [
    ["error-safeguards-cut", "told a provider's safeguards cut the reply", "API Error: Acme's safeguards stopped the response above; continuing"],
    ["error-classifier-cut", "told a safety classifier cut the reply", "API Error: stopped by a safety classifier"],
    ["error-safeguards-stopped", "told the safeguards stopped the reply", "API Error: this request violates the usage policy"],
    ["error-busy", "told Claude's servers are busy", "API Error: 529 overloaded"],
    ["error-usage-limit", "told the usage limit is reached", "Claude AI usage limit reached, resets 5pm"],
    ["error-too-long", "told the chat is too long", "Prompt is too long"],
    ["error-login", "told to log in again", "Invalid API key · Please run /login"],
    ["error-billing", "told the account has a billing problem", "Credit balance is too low"],
    ["error-connection", "told the connection dropped", "Connection error"],
    ["error-server", "told Claude's side failed", "API Error: 500 internal server error"],
    ["error-refused", "told the request was refused", "API Error: 400 invalid_request_error"],
    ["error-other", "told Claude Code hit an error", "Error: something else went wrong"]
  ];
  var errorBody = (text) => {
    const line = errorLine(text);
    if (line === undefined)
      throw new Error(`cs-feed: errorLine reads no error in ${JSON.stringify(text)}`);
    return { error: line };
  };
  var replyStates = [
    state("margin-and-reply", "reading the first block of a reply", reply({ body: "engine", name: true })),
    state("reply-no-margin", "reading a later block of the same reply", reply({ body: "engine", name: false })),
    state("reply-desktop", "reading a reply on the desktop app, with no margin", reply({ body: "engine", name: false }, { pad: 0 })),
    state("reply-steps-closed", "reading a reply with its turn's steps folded under it", reply({ body: "engine", name: true, stepsLine: stepsClosed })),
    state("reply-steps-opened", "reading a reply with its turn's steps opened", reply({ body: "engine", name: true, stepsLine: stepsOpened })),
    ...ERRORS.map(([sid, name, text]) => state(sid, name, reply({ body: errorBody(text), name: false })))
  ];
  var view = (call, over = {}) => ({ id: call.id, tool: call.tool, input: call.input, isRunning: call.outcome.state === "running", isErrored: call.outcome.state === "done" && call.outcome.errored, isInterrupted: false, output: call.outcome.state === "done" ? call.outcome.output : undefined, ...over });
  var at = (n) => {
    const call = transcript.calls.get(id(n));
    if (call === undefined)
      throw new Error(`cs-feed fixture: no call ${n}`);
    return call;
  };
  var call = (v, over = {}) => (cols, theme) => drawCall(v, pen(cols, theme, over));
  var LIVE = { ...transcript, calls: new Map([[id(1), at(1)], [id(2), { ...at(2), outcome: { state: "running" } }]]) };
  var QUESTION = { id: id(9), tool: "AskUserQuestion", input: { questions: [{ question: "Land the branch now? It is green." }] }, isRunning: true, isErrored: false, isInterrupted: false };
  var toolStates = [
    state("turn-closed", "skimming a turn's steps folded into one line", call(stepsClosed)),
    state("turn-opened", "reading a turn's steps opened", call(stepsOpened)),
    state("run-live", "watching a run while its second call works", call({ draw: "run", run: SHELL_RUN, naming: id(2), opened: false }, { t: LIVE })),
    state("run-done", "skimming a finished run as counts", call({ draw: "run", run: SHELL_RUN, opened: false })),
    state("run-line-style", "skimming a finished run in the line style, no chips", call({ draw: "run", run: SHELL_RUN, opened: false }, { view: { ...DEFAULT_VIEW, style: "line" } })),
    state("run-refused", "told every step of a run was refused by a hook", call({ draw: "run", run: REFUSED_RUN, opened: false })),
    state("run-opened", "reading a run's calls opened", call({ draw: "run", run: SHELL_RUN, opened: true })),
    state("call-running", "watching one call work", call({ draw: "call", call: view(at(1), { isRunning: true, output: undefined }), opened: false })),
    state("call-running-clickable", "watching one call work in a fullscreen terminal, the chevron pressable", call({ draw: "call", call: view(at(1), { isRunning: true, output: undefined }), opened: false }, { clickable: true })),
    state("call-done", "skimming a finished call", call({ draw: "call", call: view(at(2)), filed: at(2), opened: false })),
    state("call-errored", "told a call failed", call({ draw: "call", call: view(at(4), { isErrored: true, output: "fatal: not a git repository" }), opened: false })),
    state("call-opened", "reading a finished call's output", call({ draw: "call", call: view(at(1)), filed: at(1), opened: true })),
    ...["dispatched", "running", "finished", "failed", "stopped"].map((helper) => state(`helper-${helper}`, `watching a helper that is ${helper}`, call({ draw: "helper", call: view(at(7)), state: helper, elapsedMs: helper === "dispatched" ? undefined : 72000 }))),
    state("question-asked", "asked a question in the chat", call({ draw: "question", call: QUESTION, opened: false })),
    state("question-ended", "left a question unanswered", call({ draw: "question", call: { ...QUESTION, isRunning: false }, opened: false }))
  ];
  var batch = (states, opened = false) => ({
    draw: "batch",
    key: `helpers-${id(7)}`,
    opened,
    elapsedMs: 42000,
    helpers: states.map((s, i) => ({ call: view(at(i % 2 === 0 ? 7 : 8)), kind: i < 2 ? "Explore" : "Plan", state: s }))
  });
  var group = (v) => (cols, theme) => drawGroup(v, pen(cols, theme));
  var groupStates = [
    state("stack", "skimming a group of calls stacked one per line", group({ draw: "stack", calls: [{ draw: "call", call: view(at(2)), filed: at(2), opened: false }, { draw: "call", call: view(at(3)), filed: at(3), opened: false }] })),
    state("batch-running", "watching a batch of helpers work", group(batch(["running", "finished", "running"]))),
    state("batch-done", "told every helper of a batch finished", group(batch(["finished", "finished", "finished"]))),
    state("batch-failed", "told a helper of a batch failed", group(batch(["finished", "failed", "finished"]))),
    state("batch-opened", "reading a batch's helpers one per line", group(batch(["running", "finished", "running"], true)))
  ];
  var output = (text, isErrored) => (cols, theme) => drawCommandOutput({ text, isErrored }, pen(cols, theme));
  var outputStates = [
    state("text", "reading a command's answer", output("Chat view: clean. your messages, Claude's replies, and one line per turn for the work.", false)),
    state("errored", "reading a command's refusal", output("no feed change in this session: cs refused this session", true))
  ];
  var band = (v, over = {}) => (cols, theme) => drawBand(v, elements().Box({}), 0, pen(cols, theme, over));
  var HELPERS = { head: "3 helpers · 1 done · 2 running · 1m 12s", kinds: [{ kind: "Explore", cells: marks.working + marks.live, done: 1, n: 2 }, { kind: "Plan", cells: marks.working, done: 0, n: 1 }] };
  var bandStates = [
    state("helpers-running", "watching helpers work above the prompt", band({ draw: "helpers", ...HELPERS, more: 0, spinning: true })),
    state("helpers-settled", "reading a batch of helpers that all finished", band({ draw: "helpers", head: "3 helpers · 3 done · 1m 12s", kinds: [{ kind: "Explore", cells: marks.live + marks.live, done: 2, n: 2 }, { kind: "Plan", cells: marks.live, done: 1, n: 1 }], more: 0, spinning: false })),
    state("helpers-overflow", "watching more kinds of helper than the band has rows for", band({ draw: "helpers", ...HELPERS, more: 2, spinning: true })),
    state("background", "typing while a shell command runs in the background", band({ draw: "background", words: "Building the docs", isTest: false, more: 0, elapsedMs: 42000, typing: true })),
    state("background-test", "typing while the tests run in the background", band({ draw: "background", words: "bun test", isTest: true, more: 1, elapsedMs: 42000, typing: true })),
    state("background-narrow", "running a background task in a narrow terminal, no tail", band({ draw: "background", words: "Building the docs", isTest: false, more: 0, elapsedMs: 42000, typing: false })),
    state("desktop", "reading usage and pills on the desktop app", band({ draw: "desktop", usage: { fiveHour: 42, week: 17 }, pills: [{ kind: "helper", words: "Map the draw code", elapsedMs: 72000 }, { kind: "test", words: "bun test", elapsedMs: 12000 }] }, { pad: 0 }))
  ];
  var PANE_CHROME = 4;
  var settings = (session) => (cols, theme) => drawSettingsPane(modeOf(session), session, { el: elements(), ink: inks(theme === "light"), room: cols - PANE_CHROME }, async () => {});
  var clean2 = DEFAULT_VIEW;
  var settingsStates = [
    state("clean", "reading the settings in the clean view", settings({ on: true, view: clean2 })),
    state("normal", "reading the settings in the normal view", settings({ on: true, view: { ...PRESETS.normal.fields, hide: [] } })),
    state("raw", "reading the settings with the feed off, Claude Code's own drawing", settings({ on: false, view: clean2 })),
    state("custom", "reading the settings after changing one", settings({ on: true, view: { ...clean2, style: "expanded", commands: "each" } })),
    state("kinds-hidden", "reading the settings with two kinds hidden", settings({ on: true, view: { ...clean2, hide: ["peer", "search"] } })),
    state("every-other-value", "reading each setting at its other value", settings({ on: true, view: { group: !clean2.group, clear: !clean2.clear, keep: !clean2.keep, style: "line", commands: clean2.commands === "grouped" ? "each" : "grouped", after: clean2.after === "clear" ? "keep" : "clear", hide: [] } }))
  ];
  var helpersPane = (blocks) => (cols, theme) => drawHelpersPane(blocks, { el: elements(), ink: inks(theme === "light"), room: cols - PANE_CHROME });
  var WORKING = { name: "Explore", status: "working", elapsedMs: 72000, now: "Reading draw.tsx", calls: ["Searched the code for drawBand", "Read words.ts"] };
  var helperStates = [
    state("none", "opening the pane before any helper ran", helpersPane([])),
    state("working", "watching a helper work, call by call", helpersPane([WORKING])),
    state("finished", "reading what a finished helper did", helpersPane([{ name: "Plan", status: "finished", elapsedMs: 30000, calls: ["Read the brief"] }])),
    state("failed", "reading where a helper failed", helpersPane([{ name: "Plan", status: "failed", elapsedMs: 9000, calls: ["Ran the tests"] }])),
    state("mixed", "reading several helpers, newest first", helpersPane([WORKING, { name: "Plan", status: "finished", elapsedMs: 30000, calls: [] }, { name: "general-purpose", status: "stopped", calls: ["Read app.py"] }]))
  ];
  var ON = { on: true, view: clean2 };
  var feedReply = (args) => () => commandReply("cs-feed", "feed", args, transition(parseFeedArgs(args), ON).reply);
  var commandStates = [
    state("open", "opening the Chat view settings with /feed", feedReply("")),
    state("close", "closing the settings with /feed close", feedReply("close")),
    state("status", "asking /feed status", feedReply("status")),
    state("on", "turning the feed on", feedReply("on")),
    state("off", "turning the feed off", feedReply("off")),
    state("clean", "choosing the clean view", feedReply("clean")),
    state("normal", "choosing the normal view", feedReply("normal")),
    state("raw", "choosing Claude Code's own drawing", feedReply("raw")),
    state("hide-kind", "hiding the peer rows", feedReply("hide peer")),
    state("set-field", "setting one field", feedReply("style line")),
    state("usage", "typing a /feed word it does not take", feedReply("loud")),
    state("not-a-session", "running /feed outside a cs session", () => commandReply("cs-feed", "feed", "on", replies.notASession)),
    state("refused", "running /feed in a session cs refuses", () => commandReply("cs-feed", "feed", "on", replies.refused(".cs/local is tracked by git"))),
    state("helpers", "opening the Helpers pane with /helpers", () => commandReply("cs-feed", "helpers", "", replies.helpersOpen))
  ];
  var menuStates = [
    state("feed-selected", "typing /f in the prompt", (cols) => menuRows([commands.feed, commands.helpers], 0, cols)),
    state("helpers-selected", "moving to /helpers in the slash menu", (cols) => menuRows([commands.feed, commands.helpers], 1, cols))
  ];
  var feedLog = (text) => (cols) => logRow("cs-feed", text, cols);
  var logStates = [
    state("view-unusable", "loading a session whose feed-view file is torn", feedLog(logs.viewUnusable("/work/.cs/local/feed-view", "feed-view is torn: missing closing newline"))),
    state("unread", "loading a session whose feed-view file cannot be read", feedLog(logs.unread("/work/.cs/local/feed-view", "cs-feed: $.fs.read: EACCES: permission denied"))),
    state("feed-off", "working in a session cs refuses, with the feed planted on", feedLog(logs.feedOff(".cs/local is tracked by git"))),
    state("clock-stopped", "watching the clock stop when its write is refused", feedLog(logs.clockStopped("cs-feed: $.state.set: tick refused"))),
    state("pulse-stopped", "watching the pulse stop when its write is refused", feedLog(logs.pulseStopped("cs-feed: $.state.set: pulse refused"))),
    state("helper-unread", "opening the Helpers pane when a helper's transcript cannot be read", feedLog(logs.helperUnread("checker", "no transcript for checker")))
  ];
  var RUNNING = id(9);
  var OPEN = { id: TURN, first: id(1), steps: [id(1), id(2), id(3)], runs: [RUN] };
  var working = (open, over = {}) => (cols) => {
    const agents = Array.from({ length: over.agents ?? 0 }, (_, i) => ({ id: `helper-${i}`, type: "Explore", description: "Read the tests", status: "running" }));
    const cx = { ...context(cols, clean2, over.t ?? transcript), open, agents };
    const { verdict } = decideSpinner({ message: null, mode: over.mode ?? "requesting" }, cx);
    return verdict.draw === "rewrite" ? workingLine({ message: verdict.message, suffix: verdict.suffix, elapsed: "24s", tokens: "1.2k" }) : workingLine({ message: "Working", suffix: "…", elapsed: "24s", tokens: "1.2k" });
  };
  var withRunning = { ...transcript, calls: new Map([...transcript.calls, [RUNNING, filed(9, "Bash", { command: "bun test", description: "Run the tests" }, { state: "running" }, RUN)]]) };
  var spinnerStates = [
    state("engine", "working with the feed off, the engine's own word", () => workingLine({ message: "Working", suffix: "…", elapsed: "24s", tokens: "1.2k" })),
    state("engine-ellipsis", "working with the feed off on a todo whose active form ends in an ellipsis", () => workingLine({ message: "Running the suites…", suffix: "…", elapsed: "24s", tokens: "1.2k" })),
    state("thinking", "waiting while Claude thinks before its first step", working({ steps: [], runs: [] })),
    state("working", "waiting on a turn three steps in", working(OPEN)),
    state("call", "waiting on a step that is running", working({ ...OPEN, steps: [...OPEN.steps, RUNNING] }, { t: withRunning })),
    state("writing", "watching Claude write its reply", working(OPEN, { mode: "responding" })),
    state("helpers", "waiting while two helpers work", working(OPEN, { agents: 2 }))
  ];
  var ENGINE_MODES = ["memory paused"];
  var modeStates = [
    state("engine", "reading the footer with the feed off: the engine's modes alone", (cols) => footerModes(ENGINE_MODES, cols)),
    state("clean", "reading the footer in the clean view", (cols) => footerModes(sessionModes(ENGINE_MODES, clean2), cols)),
    state("normal", "reading the footer in the normal view", (cols) => footerModes(sessionModes(ENGINE_MODES, { ...PRESETS.normal.fields, hide: [] }), cols)),
    state("custom", "reading the footer after changing one setting", (cols) => footerModes(sessionModes(ENGINE_MODES, { ...clean2, style: "expanded" }), cols))
  ];
  var chromeSurface = (slot, states) => ({ id: `cs-feed.${slot}`, mod: "cs-feed", slot, source: "chrome", global: "CsFeedSurfaces", states, parts: [] });
  var surface = (slot, states, parts, extra = {}) => ({ id: `cs-feed.${slot}`, mod: "cs-feed", slot, source: "generated", global: "CsFeedSurfaces", states, parts, ...extra });
  var surfaces = [
    surface("UserMessage", userStates, [
      { id: "feed-row", name: "you row with the name margin", state: "you-at", path: [0] },
      { id: "name-margin", name: "name margin", state: "you", path: [0, 0] },
      { id: "peer-line", name: "peer line", state: "peer", path: [0] }
    ]),
    surface("AssistantMessage", replyStates, [
      { id: "reply-margin", name: "claude margin", state: "margin-and-reply", path: [0, 0] },
      { id: "error-line", name: "error line", state: "error-busy", path: [0] }
    ]),
    surface("ToolUse", toolStates, [
      { id: "call-row", name: "call row", state: "call-done", path: [0] },
      { id: "chip", name: "chip", state: "call-done", path: [0, 2] },
      { id: "chevron", name: "chevron", state: "call-done", path: [0, 3] },
      { id: "steps-line", name: "steps line", state: "turn-closed", path: [0] }
    ]),
    surface("ToolGroup", groupStates, [
      { id: "helper-cells", name: "helper cell row", state: "batch-running", path: [1] }
    ]),
    surface("CommandOutput", outputStates, []),
    surface("AbovePrompt", bandStates, [
      { id: "helpers-head", name: "helpers head", state: "helpers-running", path: [0, 0] }
    ]),
    surface("Pane.cs-feed", settingsStates, [
      { id: "settings-row", name: "settings row", state: "clean", path: [2, 0] },
      { id: "kind-chip", name: "kind chip Button", state: "clean", path: [9, 0] }
    ], { slot: "Pane", chrome: { kind: "pane", title: "Chat view", rows: 24 } }),
    surface("Pane.cs-feed-helpers", helperStates, [
      { id: "helper-head", name: "helper head", state: "working", path: [0, 0] }
    ], { slot: "Pane", chrome: { kind: "pane", title: "Helpers", rows: 12 } }),
    chromeSurface("command", commandStates),
    chromeSurface("menu", menuStates),
    chromeSurface("log", logStates),
    chromeSurface("Spinner", spinnerStates),
    chromeSurface("SessionMode", modeStates),
    chromeSurface("ToolProgress", [
      state("engine", "running a tool call with the feed off", () => backgroundHint("(ctrl+b to run in background)")),
      state("feed-on", "running a tool call with the feed on, its hint taken away", () => backgroundHint(""))
    ]),
    chromeSurface("TurnDuration", [
      state("engine", "reading how long the turn took, with the feed off", () => turnLine("Baked", "3s", "3:45 PM")),
      state("feed-on", "ending a turn with the feed on, its time line taken away", () => nothing())
    ])
  ];

  // docs/surfaces/cs-feed.entry.ts
  globalThis.CsFeedSurfaces = { surfaces };
})();
