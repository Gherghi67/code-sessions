// ABOUTME: The host needs cs's state shape before its hooks can read or write it.
// ABOUTME: Keeping feedOn in host state preserves the setting across hot reloads.
declare module 'claude-code' {
  interface PluginState { cs: { feedOn: boolean } }
}
