// ABOUTME: cs-feed's $.state names: three redraw tokens, each a counter that holds no fact (see session.ts). The per-session on/off is a file, not state.
// ABOUTME: Declared once here so the atoms are typed; KEEP IN SYNC with the atom() calls in session.ts.
declare module 'claude-code' {
  interface PluginState {
    'cs-feed': { live: number; tick: number; pulse: number }
  }
}
