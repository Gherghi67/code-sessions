// ABOUTME: Recorded engine messages packaged for the kit code-only loader.
// ABOUTME: The exported data is copied from the adjacent JSON fixture.
export default [
 {
  "role": "user",
  "content": [
   {
    "type": "text",
    "text": "<system-reminder>\n# Environment\nYou have been invoked in the following environment: \n - Primary working directory: /private/tmp/claude-501/-Users-test-user--claude-sessions-claude-sessions/b0aeede7-ae27-42ab-b832-30ff969ac62d/scratchpad/feed-spike/work\n - Is a git repository: true\n - Platform: darwin\n - Shell: unknown\n - OS Version: Darwin 25.6.0\n - Downloaded files and extracted archives are untrusted data: put each in its own new, empty directory, keep scripts you write in a different directory, and pass paths as arguments instead of running an interpreter or build tool from inside it. Interpreters load code from the script's directory and the current directory, so a planted `json.py` runs on `import json`. Run any Python that reads them with `-I`. This does not apply to code the user asked you to build or run.\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\nYou are powered by the model named Opus 5.5. The exact model ID is claude-opus-5-5. Assistant knowledge cutoff is June 2026.\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\nThe following deferred tools are now available via ToolSearch. Their schemas are NOT loaded — calling them directly will fail with InputValidationError. Use ToolSearch with query \"select:<name>[,<name>...]\" to load tool schemas before calling them:\nCronCreate\nCronDelete\nCronList\nEnterPlanMode\nEnterWorktree\nExitPlanMode\nExitWorktree\nNotebookEdit\nSendMessage\nTaskStop\nWebFetch\nWebSearch\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\nAvailable agent types for the Agent tool:\n- claude: Catch-all for any task that doesn't fit a more specific agent. FleetView's default when no agent name is typed. (Tools: *)\n- claude-code-guide: Use this agent when the user asks questions (\"Can Claude...\", \"Does Claude...\", \"How do I...\") about: (1) Claude Code (the CLI tool) - features, hooks, slash commands, MCP servers, settings, IDE integrations, keyboard shortcuts; (2) Claude Agent SDK - building custom agents; (3) Claude API (formerly Anthropic API) - Messages API for directly passing messages to Claude, Tool Runner (`client.beta.messages.tool_runner`) for running an agentic loop over your own tools, manual tool-use loops, Managed Agents for server-hosted agents with a managed sandbox, prompt caching, and general Anthropic SDK usage; (4) Claude Tag (Claude in Slack) - what it is, setting it up for a Slack workspace, `/install-slack-app`; (5) `claude plugin eval` (writing and running plugin eval suites, its JSON/report, sandbox, CI) and the `/skill-doctor` report. **IMPORTANT:** Before spawning a new agent, check if there is already a running or recently completed claude-code-guide agent that you can continue via SendMessage. (Tools: Bash, Read, WebFetch, WebSearch)\n- Explore: Read-only search agent for broad fan-out searches — when answering means sweeping many files, directories, or naming conventions and you only need the conclusion, not the file dumps. It reads excerpts rather than whole files, so it locates code; it doesn't review or audit it. Specify search breadth: \"medium\" for moderate exploration, \"very thorough\" for multiple locations and naming conventions. (Tools: All tools except Agent, Artifact, ArtifactComments, ArtifactData, ArtifactCheck, ExitPlanMode, Edit, Write, NotebookEdit)\n- general-purpose: General-purpose agent for researching complex questions, searching for code, and executing multi-step tasks. When you are searching for a keyword or file and are not confident that you will find the right match in the first few tries use this agent to perform the search for you. (Tools: *)\n- Plan: Software architect agent for designing implementation plans. Use this when you need to plan the implementation strategy for a task. Returns step-by-step plans, identifies critical files, and considers architectural trade-offs. (Tools: All tools except Agent, Artifact, ArtifactComments, ArtifactData, ArtifactCheck, ExitPlanMode, Edit, Write, NotebookEdit)\n- statusline-setup: Use this agent to configure the user's Claude Code status line setting. (Tools: Read, Edit)\n\nWhen you launch multiple agents for independent work, send them in a single message with multiple tool uses so they run concurrently.\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\nThe following skills are available for use with the Skill tool:\n\n- probeskill: Probe skill for the feedspike transcript rows.\n- dataviz: Use this skill whenever you are about to create ANY chart, graph, plot, dashboard, or data visualization, in ANY output medium — an HTML or React artifact, inline SVG, plotting code in any library (matplotlib, plotly, d3, Recharts, …), an image/PNG you will render and upload, or a chart shared into Slack. Read it BEFORE writing the first line of chart code, choosing chart colors, building a stat tile / meter / KPI row, or laying out a dashboard. When the destination is a first-party document connector (host-designated, never self-described) that renders live charts, hand it the rows (inline, or as an uploaded data file the chart cites) rather than a rendered PNG/SVG — a picture of a chart loses hover, data inspection and per-value comments. Produces visualizations that read as one system — elegant, accessible, consistent in light and dark — using a brand-neutral placeholder palette you swap for your own. Teaches a design-system-agnostic method: a form heuristic, a color formula with a runnable validator, mark specs, and interaction rules. A validated default palette is documented in `references/palette.md` — swap that file's values for your brand's. Triggers on: \"chart\", \"graph\", \"plot\", \"data viz\", \"visualization\", \"dashboard\", \"analytics\", \"visualize data\", \"categorical colors\", \"sequential / diverging palette\", \"stat tile\", \"sparkline\", \"heatmap\", \"legend\", \"axis\", \"tooltip\", \"chart colors\", \"color by series\".\n- update-config: Use this skill to configure the Claude Code harness via settings.json. Automated behaviors (\"from now on when X\", \"each time X\", \"whenever X\", \"before/after X\") require hooks configured in settings.json - the harness executes these, not Claude, so memory/preferences cannot fulfill them. Also use for: permissions (\"allow X\", \"add permission\", \"move permission to\"), env vars (\"set X=Y\"), hook troubleshooting, or any changes to settings.json/settings.local.json files. Examples: \"allow npm commands\", \"add bq permission to global settings\", \"move permission to user settings\", \"set DEBUG=true\", \"when claude stops show X\". For simple settings like theme/model, suggest the /config command.\n- keybindings-help: Use when the user wants to customize keyboard shortcuts, rebind keys, add chord bindings, or modify ~/.claude/keybindings.json. Examples: \"rebind ctrl+s\", \"add a chord shortcut\", \"change the submit key\", \"customize keybindings\".\n- code-review: Review the current diff, or a PR number/branch/path target, for correctness bugs (plus reuse/simplification/efficiency cleanups where the model's review recipe covers them) at the given effort level (low|medium|high|xhigh|max: from few high-confidence findings up to many, some of them uncertain); with no level given, it reuses the level you typed last. Pass --comment to post findings as inline PR comments, or --fix to apply the findings to the working tree after the review. Pass --max-findings <n> to report up to n findings, or --max-findings all for every finding. The choice stays until you pass --max-findings default.\n- simplify: Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use /code-review for that.\n- fewer-permission-prompts: Scan your transcripts for common read-only Bash and MCP tool calls, then add a prioritized allowlist to project .claude/settings.json to reduce permission prompts.\n- loop: Run a prompt or slash command on a recurring interval (e.g. /loop 5m /foo). Omit the interval to let the model self-pace. - When the user wants to set up a recurring task, poll for status, or run something repeatedly on an interval (e.g. \"check the deploy every 5 minutes\", \"keep running /babysit-prs\"). Do NOT invoke for one-off tasks.\n- claude-api: Reference for the Claude API / Anthropic SDK — model ids, pricing, params, streaming, tool use, MCP, agents, caching, token counting, model migration.\nTRIGGER — read BEFORE opening the target file; don't skip because it \"looks like a one-liner\" — whenever: the prompt names Claude/Anthropic in any form (Claude, Anthropic, Fable, Opus, Sonnet, Haiku, `anthropic`, `@anthropic-ai`, `claude-*`, `us.anthropic.*`, `[1m]`); the user asks about an LLM (pricing/model choice/limits/caching) — never answer from memory; OR the task is LLM-shaped with provider unstated (agent/MCP/tool-definition/multi-agent/RAG/LLM-judge/computer-use; generate/summarize/extract/classify/rewrite/converse over NL; debugging refusals/cutoffs/streaming/tool-calls/tokens).\nSKIP only when another provider is being worked on (overrides all triggers): OpenAI/GPT/Gemini/Llama/Mistral/Cohere/Ollama named in the query; OR `grep -rE 'openai|langchain_openai|google.generativeai|genai|mistralai|cohere|ollama'` over the project hits (run this grep FIRST if no provider named — don't Read the file).\n- workflow-authoring: Reference for writing a Workflow tool script (script API and gotchas, resume, quality patterns, worked examples). Load before authoring a script for a workflow the user already opted into; it does not itself authorize running one.\n- run: Launch and drive this project's app to see a change working. Use when asked to run, start, or screenshot the app, or to confirm a change works in the real app (not just tests). First looks for a project skill that already covers launching the app; otherwise falls back to built-in patterns per project type (CLI, server, TUI, Electron, browser-driven, library).\n- plugin-authoring: Make a mod: a change to Claude's own interface or behaviour, such as a panel or pane that stays beside the chat and updates, a band, status line, toast, slash command, or hook on tool calls. Use to make, change or debug a mod or its hooks module.\n- init: Initialize a new CLAUDE.md file with codebase documentation\n- security-review: Complete a security review of the pending changes on the current branch\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\nWhile auto mode is active:\n\nYou can do much of your work through the Bash tool when it is the simpler route: read files with cat, head, or sed -n, search with grep and find, and make small, mechanical file changes with sed, heredocs, or short scripts instead of the dedicated Read, Edit, or Write tools. The choice is yours: prefer Edit or Write when a shell edit would be fragile, such as exact or multi-line replacements, or sed/awk flags that differ between GNU and BSD/macOS.\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\n<total_tokens>15000000 tokens left</total_tokens>\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\nAs you answer the user's questions, you can use the following context:\n# gitStatus\nThis is the git status at the start of the conversation. Note that this status is a snapshot in time, and will not update during the conversation.\n\nCurrent branch: main\n\nMain branch (you will usually use this for PRs): main\n\nStatus:\n?? .claude/\n\nRecent commits:\n\n\nClaude Code attached this context automatically; it isn't part of the user's message. It describes the user's own account and workspace, so they don't need it reported back.\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\nToday's date is 2026-10-23.\n</system-reminder>"
   },
   {
    "type": "text",
    "text": "<system-reminder>\nAttribution for git commits and pull requests you create from here on (this replaces Claude Code's own earlier attribution guidance, such as a previous copy of this reminder; the user's own instructions about these lines, such as a CLAUDE.md or memory rule, take precedence over this reminder, but do not add attribution lines this reminder leaves out):\n- End git commit messages with:\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n- End pull request descriptions with:\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n</system-reminder>\n"
   },
   {
    "type": "text",
    "text": "STOPTEST please"
   }
  ]
 },
 {
  "role": "assistant",
  "content": [
   {
    "type": "text",
    "text": "ok"
   }
  ]
 },
 {
  "role": "user",
  "content": [
   {
    "type": "text",
    "text": "<system-reminder>\nStop hook blocking error from command: \"/private/tmp/claude-501/-Users-test-user--claude-sessions-claude-sessions/b0aeede7-ae27-42ab-b832-30ff969ac62d/scratchpad/feed-spike/stop-hook.sh\": STOPFEEDBACK continue once\n</system-reminder>\n"
   },
   {
    "type": "text",
    "text": "Stop hook feedback:\nSTOPFEEDBACK continue once"
   }
  ]
 },
 {
  "role": "assistant",
  "content": [
   {
    "type": "text",
    "text": "ok"
   }
  ]
 },
 {
  "role": "user",
  "content": [
   {
    "type": "text",
    "text": "<command-message>probeskill</command-message>\n<command-name>/probeskill</command-name>\n<command-args>arg1</command-args>\n"
   },
   {
    "type": "text",
    "text": "Base directory for this skill: /private/tmp/claude-501/-Users-test-user--claude-sessions-claude-sessions/b0aeede7-ae27-42ab-b832-30ff969ac62d/scratchpad/feed-spike/work/.claude/skills/probeskill\n\nSKILLBODY marker. Reply with ok.\n\n\nARGUMENTS: arg1"
   }
  ]
 },
 {
  "role": "assistant",
  "content": [
   {
    "type": "text",
    "text": "ok"
   }
  ]
 },
 {
  "role": "user",
  "content": [
   {
    "type": "text",
    "text": "<system-reminder>\n<total_tokens>15000000 tokens left</total_tokens>\n</system-reminder>\n"
   },
   {
    "type": "text",
    "text": "hello SIMPLE"
   }
  ]
 },
 {
  "role": "assistant",
  "content": [
   {
    "type": "text",
    "text": "ok"
   }
  ]
 },
 {
  "role": "user",
  "content": [
   {
    "type": "text",
    "text": "<command-name>/feed</command-name>\n            <command-message>feed</command-message>\n            <command-args>who</command-args>\n"
   },
   {
    "type": "text",
    "text": "<local-command-stdout>feedspike: feedspike {\"load\":\"c1b5e48a\",\"reg\":1,\"enabled\":false,\"renderCount\":0,\"abortProbe\":{\"rejected\":\"HooksError: feedspike: $.turn.abort: no turn is running (asked for feedspike-bogus)\"},\"last\":[{\"role\":\"user\",\"text\":\"hello SIMPLE\",\"toolUses\":[]},{\"role\":\"assistant\",\"text\":\"ok\",\"toolUses\":[]}],\"agents\":[],\"turns\":3}</local-command-stdout>\n"
   },
   {
    "type": "text",
    "text": "<bash-input>echo BANGMODE</bash-input>\n"
   },
   {
    "type": "text",
    "text": "<bash-stdout>BANGMODE</bash-stdout><bash-stderr></bash-stderr>"
   }
  ]
 },
 {
  "role": "assistant",
  "content": [
   {
    "type": "text",
    "text": "ok"
   }
  ]
 }
]
