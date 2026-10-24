# ABOUTME: Builds the cost oracle's throwaway plugins: the counting probe (a copy of cs-feed's hooks with one tally statement per hook body), the counting positive control and a dummy pane plugin.
# ABOUTME: Usage: python3 -I probe.py <cs-feed mod dir> <out dir>; prints the inserted counts and exits 1 when an insertion does not land exactly as planned.
import json, os, re, shutil, sys

MOD, OUT = sys.argv[1], sys.argv[2]

# Module memory only; written once, at session.end, to $RIG_TALLY_DIR/tally-<name>.json.
TALLY = """// ABOUTME: The oracle's counter: each call records [Date.now(), label] in module memory; flush writes them once.
// ABOUTME: flush is called from session.end only, so no write of the counter lands in the measured window.
import type { EngineInterface } from 'claude-code'

const entries: [number, string][] = []

export function tally(label: string): void {
  entries.push([Date.now(), label])
}

export async function flush($: EngineInterface, name: string): Promise<void> {
  const dir = await $.env.get('RIG_TALLY_DIR')
  if (!dir) throw new Error('RIG_TALLY_DIR is not set for the oracle run')
  await $.fs.write(`${dir}/tally-${name}.json`, JSON.stringify(entries))
}
"""

PROBE_REGISTER = """// ABOUTME: The oracle's probe: cs-feed's own register, from the instrumented copy under ./feed, with on passed unchanged.
// ABOUTME: Adds one session.end hook that writes the tally; cs-feed registers no session.end of its own.
import type { On } from 'claude-code'
import { register as registerFeed } from './feed/register'
import { flush } from './tally'

export function register(on: On) {
  registerFeed(on)
  on('session.end', async ($, e, next) => {
    await flush($, 'cs-feed')
    return next(e)
  })
}
"""

# The positive control: one passthrough ui.render hook making no $ call, as the
# Q3 probe, plus its /passcount command; counted the same way as the probe.
CONTROL_REGISTER = """// ABOUTME: The oracle's positive control: one passthrough ui.render hook that returns next(e) and makes no $ call, counted per component.
// ABOUTME: /passcount answers the count so far; session.end writes the tally once.
import type { On } from 'claude-code'
import { flush, tally } from './tally'

let total = 0
const byComponent: Record<string, number> = {}

export function register(on: On) {
  on('ui.render', ($, e, next) => {
    tally(`ui.render ${e.component}`)
    total++
    byComponent[e.component] = (byComponent[e.component] ?? 0) + 1
    return next(e)
  })
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'passcount', description: 'passrender probe: evaluations so far' })
    return next(e)
  })
  on('command.run', { command: 'passcount' }, () => ({ text: `passrender total=${total} ${JSON.stringify(byComponent)}` }))
  on('session.end', async ($, e, next) => {
    await flush($, 'passrender')
    return next(e)
  })
}
"""

# A pane of an unrelated plugin, opened by its own command (an asked open is
# placed at any width).
DUMMY_REGISTER = """// ABOUTME: The oracle's unrelated pane: a plugin whose /dummypane command opens its own pane, which draws one line.
// ABOUTME: Its Pane hook selects its own requestId only; the screen shows DUMMYPANE while it is open.
import type { On } from 'claude-code'

export function register(on: On) {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'dummypane', description: 'Open the oracle dummy pane' })
    return next(e)
  })
  on('command.run', { command: 'dummypane' }, async ($) => {
    const opened = await $.ui.open({ id: 'dummy-pane', title: 'Dummy' })
    return { text: opened.isPlaced ? 'dummy pane placed' : `dummy pane not placed: ${opened.reason}` }
  })
  on('ui.render', { component: 'Pane', requestId: 'dummy-pane' }, async ($, e, next) => {
    await next(e)
    const { Text } = await $.ui.resolve(e)
    return <Text>DUMMYPANE body</Text>
  })
}
"""

ON_CALL = re.compile(r"^(\s*)on\('([^']+)'(?:, \{([^}]*)\})?, (?:async )?\(([^)]*)\) => \{")
ON_TOKEN = re.compile(r"\bon\('")


def fail(message):
    print(f"probe build refused: {message}")
    sys.exit(1)


def label(event, matcher):
    if matcher is None:
        return event
    pairs = []
    for part in matcher.split(","):
        key, value = (s.strip() for s in part.split(":", 1))
        pairs.append(f"{key}={value.strip(chr(39))}")
    return f"{event} {' '.join(pairs)}"


def code_lines(text):
    return [line for line in text.splitlines() if not line.lstrip().startswith(("//", "*", "/*"))]


def plugin(dir_, name, modules, register, types=None):
    os.makedirs(f"{dir_}/.claude-plugin", exist_ok=True)
    os.makedirs(f"{dir_}/hooks", exist_ok=True)
    manifest = {"name": name, "version": "0.0.1", "description": f"cs-feed cost oracle: {name}.", "author": {"name": "cs"}}
    if types:
        manifest["types"] = types
    with open(f"{dir_}/.claude-plugin/plugin.json", "w") as f:
        json.dump(manifest, f)
    with open(f"{dir_}/hooks/hooks.json", "w") as f:
        json.dump({"modules": modules}, f)
    with open(f"{dir_}/hooks/register.tsx", "w") as f:
        f.write(register)


def instrument_hooks(feed):
    """One tally per on() body; returns (inserted, on_tokens, labels)."""
    inserted, tokens, labels = 0, 0, []
    for name in sorted(os.listdir(feed)):
        if not name.endswith((".ts", ".tsx")) or name.endswith(".d.ts"):
            continue
        path = f"{feed}/{name}"
        text = open(path).read()
        tokens += sum(len(ON_TOKEN.findall(line)) for line in code_lines(text))
        out = []
        for line in text.splitlines(keepends=True):
            m = ON_CALL.match(line)
            if m:
                tag = label(m.group(2), m.group(3))
                head = line[: m.end()]
                line = f"{head} tally({json.dumps(tag)});{line[m.end():]}"
                inserted += 1
                labels.append(tag)
            out.append(line)
        with open(path, "w") as f:
            f.write("".join(out))
    return inserted, tokens, labels


def insert_once(path, anchor, line_for, where):
    """Inserts line_for(indent) before or after the one line equal to anchor (stripped); fails unless it occurs exactly once."""
    lines = open(path).read().splitlines(keepends=True)
    hits = [i for i, line in enumerate(lines) if line.strip() == anchor]
    if len(hits) != 1:
        fail(f"{os.path.basename(path)}: anchor {anchor!r} found {len(hits)} times, expected 1")
    i = hits[0]
    indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
    new = f"{indent}{line_for}\n"
    lines.insert(i + 1 if where == "after" else i, new)
    open(path, "w").write("".join(lines))


def insert_before_each(path, prefix, line_for, expected):
    lines = open(path).read().splitlines(keepends=True)
    out, n = [], 0
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(prefix):
            key = stripped[len(prefix):].split("'", 1)[0]
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f"{indent}{line_for(key)}\n")
            n += 1
        out.append(line)
    if n != expected:
        fail(f"{os.path.basename(path)}: {prefix!r} found {n} times, expected {expected}")
    open(path, "w").write("".join(out))


def add_import(path):
    lines = open(path).read().splitlines(keepends=True)
    if not (lines[0].startswith("// ABOUTME:") and lines[1].startswith("// ABOUTME:")):
        fail(f"{os.path.basename(path)} does not open with its two ABOUTME lines")
    lines.insert(2, "import { tally } from '../tally'\n")
    open(path, "w").write("".join(lines))


probe = f"{OUT}/probe"
feed = f"{probe}/hooks/feed"
shutil.rmtree(probe, ignore_errors=True)
# The state contract travels with the copy: cs-feed's manifest names hooks/state.d.ts.
shipped_types = json.load(open(f"{MOD}/.claude-plugin/plugin.json"))["types"]
if shipped_types != "./hooks/state.d.ts":
    fail(f"cs-feed's manifest names types {shipped_types!r}; the probe expects ./hooks/state.d.ts")
plugin(probe, "cs-feed", ["./register.tsx"], PROBE_REGISTER, "./hooks/feed/state.d.ts")
shutil.copytree(f"{MOD}/hooks", feed)
os.remove(f"{feed}/hooks.json")
with open(f"{probe}/hooks/tally.ts", "w") as f:
    f.write(TALLY)

inserted, tokens, labels = instrument_hooks(feed)
if inserted != tokens:
    fail(f"inserted {inserted} hook tallies but the copy has {tokens} on( calls")
# Painter entries: the line after site()'s off check runs only where the mirror says on.
insert_once(f"{feed}/register.tsx", "if (!session.on) return await engine()", "tally(`painter ${e.component}`)", "after")
# The mirror's flips after the load's read (applyFeed is the one place `on` changes).
insert_once(f"{feed}/session.ts", "load.feed = { on, view: current.view }", "tally(on ? 'mirror on' : 'mirror off')", "after")
insert_once(f"{feed}/session.ts", "load.feed = { on: !feed.failed && !stored.failed && isOn(feed.text) && load.vet === 'passed', view }", "tally(load.feed.on ? 'record on' : 'record off')", "after")
# Token writes: before each $.state.set of LIVE, TICK or PULSE.
insert_before_each(f"{feed}/session.ts", "await $.state.set({ plugin: 'cs-feed', key: '", lambda key: f"tally('state.set {key}')", 4)
add_import(f"{feed}/register.tsx")
add_import(f"{feed}/session.ts")

control = f"{OUT}/passrender"
shutil.rmtree(control, ignore_errors=True)
plugin(control, "passrender", ["./register.tsx"], CONTROL_REGISTER)
with open(f"{control}/hooks/tally.ts", "w") as f:
    f.write(TALLY)

dummy = f"{OUT}/dummypane"
shutil.rmtree(dummy, ignore_errors=True)
plugin(dummy, "dummypane", ["./register.tsx"], DUMMY_REGISTER)

with open(f"{OUT}/probe-labels.json", "w") as f:
    json.dump(labels, f, indent=1)
print(f"probe: {inserted} hook tallies for {tokens} on( calls, 1 painter marker, 2 mirror markers, 4 state.set markers")
