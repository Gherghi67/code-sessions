---
created: 2026-10-21
purpose: Make engine selection visible and clear in the session picker
status: moved
moved-to: code-sessions@tui-engine-selector
---

# Primary Request and Intent

User: "make the TUI to be able to change the engine". Work on the code-sessions
session picker. It already has per-session launch settings under `e`, including
Claude/Codex selection, but the normal footer does not advertise that control.
Make the control discoverable, show both choices in the dialog, and confirm the
saved engine choice before launch. Preserve existing launch argument forwarding.

# Key Technical Concepts

Rust ratatui/crossterm picker; Mode::LaunchOptions; LaunchChoice; Action::OpenWith.
The picker emits a session plus one argument per stdout line. The shell launcher
validates flags and persists the engine only when the session is opened.

# Files and Code Sections

- tui/src/ui.rs: render_footer, render_session_menu, render_launch_options.
- tui/src/app.rs: execute_menu_action, handle_launch_options, open_action.
- docs/commands.md: document picker engine control.
- lib/65-sessions.sh and tests/test_launch_options.sh: existing launch integration.

# Problem Solving

Confirmed installed cs-tui contains the current engine selector. Source checkout
is clean at 6f265e0e on code-sessions. No source edits yet. Other feature
worktrees and the notebook's uncommitted notes must be preserved.

# Pending Tasks

Implement the UI changes, run full Rust tests and existing shell launch-options
tests, build and install the picker into the code-sessions profile, verify the
installed artifact, and report the controls. No publishing requested.

# Current Work

Root agent in code-session is preparing this isolated feature; no extra session
or agents should launch. Use cs/tui-engine-selector.

# Next Step

Inspect the relevant renderers, implement the scoped change, and verify it.
