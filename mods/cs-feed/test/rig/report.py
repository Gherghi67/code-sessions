# ABOUTME: Judges one cost-oracle run: worker hops from each debug log's `settled in (worker hop …)` lines, the probe's and the control's tallies, the screens and the files each case left.
# ABOUTME: Usage: python3 -I report.py <run-dir>; writes <run-dir>/report.txt and report.json, exits 0 when every assertion holds, 1 on a mismatch, 2 when the positive control voids the run.
import json, os, re, sys
from datetime import datetime, timezone

R = sys.argv[1]
CONTROL_TOTAL = 72  # spike Q3: passrender's worker hops for this scenario, fullscreen, standalone
SPIKE4_NEW_HOPS = 32  # spike4: an inert mod's hops over cs's three mods, fullscreen
PAINTED = ["UserMessage", "AssistantMessage", "ToolUse", "ToolGroup", "ToolResult", "ToolProgress",
           "TurnDuration", "CommandOutput", "Spinner", "SessionMode", "AbovePrompt"]
PANE_HOOKS = ["ui.render component=Pane requestId=PANE", "ui.render component=Pane requestId=HELPERS_PANE"]
HOP = re.compile(r"hooks module (.+?) (\S+) settled in ([0-9.]+)ms \(worker hop, next\(\) included\)(?: key=(.*))?$")
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3})Z ")
REFUSED_LOG = "the feed is off in this session:"

lines, failures, voids, data = [], [], [], {}


def say(text):
    lines.append(text)


def check(ok, what):
    say(f"  {'PASS' if ok else 'FAIL'} {what}")
    if not ok:
        failures.append(what)
    return ok


def void(what):
    say(f"  VOID {what}")
    voids.append(what)


def epoch_ms(stamp):
    return int(datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=timezone.utc).timestamp() * 1000)


class Launch:
    def __init__(self, tag, case, renderer):
        self.tag, self.case, self.renderer = tag, case, renderer
        self.dir = f"{R}/launches/{tag}"
        self.marks, self.says, self.exit_typed = {}, [], None
        for line in open(f"{self.dir}/run.txt"):
            line = line.rstrip("\n")
            m = re.match(r"^(\w+)@(\d+)$", line)
            if m:
                self.marks[m.group(1)] = int(m.group(2))
            m = re.match(r"^enter@(\d+) (.*)$", line)
            if m:
                self.says.append((int(m.group(1)), m.group(2)))
            m = re.match(r"^say@(\d+) /exit$", line)
            if m:
                self.exit_typed = int(m.group(1))
        self.run_txt = open(f"{self.dir}/run.txt").read()
        self.debug = open(f"{self.dir}/debug.txt", errors="replace").read().splitlines() if os.path.exists(f"{self.dir}/debug.txt") else []
        self.hops = []
        for line in self.debug:
            s, m = STAMP.match(line), HOP.search(line)
            if s and m:
                self.hops.append({"t": epoch_ms(s.group(1)), "plugins": m.group(1).split(", "), "event": m.group(2),
                                  "ms": float(m.group(3)), "key": m.group(4) or ""})
        self.alternate = read(f"{self.dir}/alternate_on").strip()

    def tally(self, name):
        path = f"{self.dir}/tally-{name}.json"
        if not os.path.exists(path):
            return None
        return [(int(t), label) for t, label in json.load(open(path))]

    def screen(self, name):
        path = f"{self.dir}/{name}.txt"
        return open(path, errors="replace").read() if os.path.exists(path) else ""

    def entered(self, text, after=0):
        return next(t for t, said in self.says if said == text and t >= after)


def read(path):
    return open(path).read() if os.path.exists(path) else "<absent>"


# Windows over a tally are index ranges: entries are appended in the order the
# module ran them, so two in the same millisecond keep their order.
def counts(entries, lo=0, hi=None):
    out = {}
    for _, label in entries[lo:hi]:
        out[label] = out.get(label, 0) + 1
    return out


def painters(entries, lo=0, hi=None):
    return sum(n for label, n in counts(entries, lo, hi).items() if label.startswith("painter "))


def sites(entries, lo=0, hi=None):
    return sum(counts(entries, lo, hi).get(f"ui.render component={c}", 0) for c in PAINTED)


def first(entries, label, after_ms):
    """Index of the first entry with this label at or after a wall-clock mark."""
    return next((i for i, (t, l) in enumerate(entries) if l == label and t >= after_ms), None)


BAND_KEY = re.compile(r"3 feed( ✓)?\s*$", re.M)


def band_label(screen):
    """The band's feed key as drawn: 'feed ✓', 'feed', or None when the key is not on screen."""
    m = BAND_KEY.search(screen)
    return None if m is None else ("feed ✓" if m.group(1) else "feed")


launches = []
for row in open(f"{R}/cases.tsv"):
    tag, case, renderer = row.rstrip("\n").split("\t")
    launches.append(Launch(tag, case, renderer))
by = {(l.case, l.renderer): l for l in launches}

for l in launches:
    say(f"[{l.tag}]")
    want = "1" if l.renderer == "fullscreen" else "0"
    if l.alternate != want:
        void(f"{l.tag}: tmux alternate_on={l.alternate}, expected {want} for the {l.renderer} renderer")
    if "tally missing" in l.run_txt:
        void(f"{l.tag}: {re.search(r'tally missing:.*', l.run_txt).group(0)}")
    entries = l.tally("cs-feed") or []
    rec = {"renderer": l.renderer, "hops_to_scenario_end": None}

    if l.case == "control":
        end = l.marks["count_end"]
        hops = [h for h in l.hops if h["plugins"] == ["passrender@inline"] and h["event"] == "ui.render" and h["t"] <= end]
        control = l.tally("passrender") or []
        tallied = [e for e in control if e[0] <= end]
        rec.update(control_hops=len(hops), control_tally=len(tallied), control_by_component=counts(tallied))
        say(f"  control: {len(hops)} passrender ui.render hops to count_end, {len(tallied)} tallied, by component {counts(tallied)}")
        if l.renderer == "fullscreen" and len(hops) != CONTROL_TOTAL:
            void(f"{l.tag}: the positive control logged {len(hops)} ui.render hops, spike Q3 logged {CONTROL_TOTAL}")
        elif l.renderer == "fullscreen":
            check(True, f"positive control: {len(hops)} = spike Q3's {CONTROL_TOTAL}")
        check(len(hops) == len(tallied), f"control: tally ({len(tallied)}) equals its hop lines ({len(hops)})")

    if l.case in ("probe-solo", "probe-beside"):
        # Compared up to /exit: each plugin writes its tally from its own
        # session.end, one after the other, and a render can land between the two.
        control = l.tally("passrender") or []
        cut = l.exit_typed
        probe = counts([e for e in entries if e[0] < cut])
        ctrl = counts([e for e in control if e[0] < cut])
        per = {c: (probe.get(f"ui.render component={c}", 0), ctrl.get(f"ui.render {c}", 0)) for c in PAINTED}
        rec.update(probe=probe, control_by_component=ctrl, site_vs_control=per)
        say(f"  probe tallies before /exit: {probe}")
        for c, (a, b) in per.items():
            check(a == b, f"session off: site() entries for {c} ({a}) equal the control's ({b})")
        check(painters(entries) == 0, f"session off: painter entries {painters(entries)} = 0")
        check(all(probe.get(p, 0) == 0 for p in PANE_HOOKS), "session off: the feed's Pane hooks ran 0 times")
        check(sum(n for k, n in probe.items() if k.startswith("state.set")) == 0, "session off: no state.set of LIVE, TICK or PULSE")

    if l.case in ("none", "shipped-solo", "v3", "shipped-beside"):
        end = l.marks["scenario_end"]
        mine = [h for h in l.hops if h["t"] <= end]
        rec["hops_to_scenario_end"] = len(mine)
        own = [h for h in mine if "cs-feed@inline" in h["plugins"]]
        new = [h for h in own if h["plugins"] == ["cs-feed@inline"]]
        def group(hs):
            out = {}
            for h in hs:
                k = h["event"] + (" " + re.sub(r"[0-9a-f]{8}-[0-9a-f-]{27}", "<uuid>", re.sub(r"(collapsed|toolu)[-_].*", r"\1-*", h["key"])) if h["key"] else "")
                out[k] = out.get(k, 0) + 1
            return out
        rec.update(feed_hops=len(own), feed_only_hops=len(new), feed_only_by_event=group(new), feed_joined_by_event=group([h for h in own if h not in new]))
        settled = sorted(h["ms"] for h in new)
        if settled:
            rec["feed_only_ms_p50"] = settled[len(settled) // 2]
            rec["feed_only_ms_p90"] = settled[min(len(settled) - 1, int(0.9 * len(settled)))]
        say(f"  worker hops to scenario_end: {len(mine)}; with cs-feed in the label: {len(own)}, cs-feed alone: {len(new)} {group(new)}")

    if l.case == "band":
        scr_on, scr_off = l.screen("02-pressed-on"), l.screen("03-pressed-off")
        check(read(f"{l.dir}/feed-after-press1") == "on\n", f"band key: the file reads on after the first press ({read(l.dir + '/feed-after-press1')!r})")
        check(band_label(scr_on) == "feed ✓", f"band key: the band's label reads `feed ✓` after the first press ({band_label(scr_on)})")
        check(read(f"{l.dir}/feed-after-press2") == "off\n", f"band key: the file reads off after the second press ({read(l.dir + '/feed-after-press2')!r})")
        check(band_label(scr_off) == "feed", f"band key: the band's label reads `feed` after the second press ({band_label(scr_off)})")
        on1 = first(entries, "mirror on", l.marks["press1"])
        off1 = first(entries, "mirror off", l.marks["press2"])
        typed_on = l.entered("/feed on", l.marks["press2"])
        on2 = first(entries, "mirror on", typed_on)
        off3 = first(entries, "mirror off", l.marks["midcall_off"])
        on3 = first(entries, "mirror on", l.marks["midcall_on"])
        rec.update(flips={"press1_on": on1, "press2_off": off1, "typed_on": on2, "midcall_off": off3, "midcall_on": on3}, probe=counts(entries))
        if check(None not in (on1, off1, on2, off3, on3), "every flip landed in the mirror (press on, press off, typed on, mid-call off, mid-call on)"):
            s1, p1 = sites(entries, on1, off1), painters(entries, on1, off1)
            check(p1 > 0 and s1 == p1, f"band key on: every site() entry after the flip painted ({p1} painter of {s1} site entries)")
            check(painters(entries, off1, on2) == 0, f"band key off: painter entries after the flip {painters(entries, off1, on2)} = 0")
            ticks_on = sum(n for k, n in counts(entries, on2, off3).items() if k.startswith("state.set"))
            check(ticks_on > 0, f"typed on: the clocks wrote tokens while on ({ticks_on} state.set), so the off count below can move")
            p3 = painters(entries, off3, on3)
            st3 = sum(n for k, n in counts(entries, off3, on3).items() if k.startswith("state.set"))
            check(p3 == 0, f"/feed off mid-call: painter entries after the flip {p3} = 0")
            check(st3 == 0, f"/feed off mid-call: state.set of LIVE, TICK or PULSE after the flip {st3} = 0")
            check(painters(entries, on3) > 0, f"/feed on mid-call: painter entries resume ({painters(entries, on3)})")

    if l.case == "trace7":
        logged = [line for line in l.debug if REFUSED_LOG in line]
        rec.update(refusal_log_lines=len(logged), probe=counts(entries))
        check(painters(entries) == 0, f"planted on, refused: painter entries for the whole run {painters(entries)} = 0")
        for name in ("00-ready", "01-turn", "02-pressed", "04-feed-status"):
            got = band_label(l.screen(name))
            check(got == "feed", f"planted on, refused: the band's label reads `feed` ({name}: {got})")
        check(len(logged) == 1, f"planted on, refused: exactly one `{REFUSED_LOG}` line in the debug log ({len(logged)})")
        if logged:
            t = epoch_ms(STAMP.match(logged[0]).group(1))
            check(t < l.marks["press"], "planted on, refused: the one log line came before the press, so press, /feed off and /feed status added none")
        check(read(f"{l.dir}/feed-at-end") == "on\n", "planted on, refused: the file still reads on (nothing written)")
        check("no feed change in this session: the launch did not say where cs is (CS_BIN)" in l.screen("03-feed-off"), "planted on, refused: /feed off replies with the refusal")
        for name in ("00-ready", "03-feed-off"):
            check("cs-feed: cs-feed:" not in l.screen(name), f"planted on, refused: the engine names the plugin once on the log and reply lines ({name})")

    if l.case == "outside":
        check(read(f"{l.dir}/cs-dir-after").strip() == "absent", "outside a cs session: /feed on created nothing")
        check("this directory is not a cs session" in l.screen("01-feed-on"), "outside a cs session: the reply says so")
        check(painters(entries) == 0, "outside a cs session: painter entries 0")

    if l.case == "refused":
        check(read(f"{l.dir}/local-after").strip() == "", f"no CS_BIN: /feed on wrote nothing in .cs/local ({read(l.dir + '/local-after').split()})")
        check("no feed change in this session: the launch did not say where cs is (CS_BIN)" in l.screen("01-feed-on"), "no CS_BIN: the reply names the refusal")
        check(painters(entries) == 0, "no CS_BIN: painter entries 0")

    if l.case == "panes":
        scr = l.screen("01-panes-open")
        probe = counts(entries)
        rec["probe"] = probe
        check("cs 9999.0.0 is available" in scr, "unrelated panes: cs-update's pane is open")
        check("DUMMYPANE" in scr, "unrelated panes: the dummy plugin's pane is open")
        for p in PANE_HOOKS:
            check(probe.get(p, 0) == 0, f"unrelated panes: {p} ran {probe.get(p, 0)} times, expected 0")
    data[l.tag] = rec

say("[hops over baseline]")
for r in ("fullscreen", "default"):
    for with_, base in (("shipped-solo", "none"), ("shipped-beside", "v3")):
        a, b = by.get((with_, r)), by.get((base, r))
        if a and b:
            d = data[a.tag]["hops_to_scenario_end"] - data[b.tag]["hops_to_scenario_end"]
            data[f"over-{with_}-{r}"] = d
            note = f"; spike4's inert mod: {SPIKE4_NEW_HOPS}" if with_ == "shipped-beside" and r == "fullscreen" else ""
            say(f"  {r} {with_}: {data[a.tag]['hops_to_scenario_end']} - {base} {data[b.tag]['hops_to_scenario_end']} = {d} over baseline (cs-feed alone in the label: {data[a.tag]['feed_only_hops']}){note}")

verdict = 2 if voids else (1 if failures else 0)
say(f"[verdict] {'VOID' if voids else ('FAIL' if failures else 'PASS')}: {len(failures)} failed, {len(voids)} void")
open(f"{R}/report.txt", "w").write("\n".join(lines) + "\n")
json.dump(data, open(f"{R}/report.json", "w"), indent=1)
print("\n".join(lines))
sys.exit(verdict)
