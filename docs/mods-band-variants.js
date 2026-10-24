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

  var api = { STATES: STATES };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.BandVariants = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
