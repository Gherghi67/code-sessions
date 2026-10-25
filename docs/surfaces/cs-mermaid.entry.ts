// ABOUTME: Bundle entry for the cs-mermaid mod's fence: the mod's Drawing and drawFence with the lab's fixtures, as one page global.
// ABOUTME: Built by docs/surfaces/build.sh into docs/surfaces/cs-mermaid.js, a plain script the file:// lab loads.
import { surfaces } from './cs-mermaid.fixtures.ts'

;(globalThis as { CsMermaidSurfaces?: unknown }).CsMermaidSurfaces = { surfaces }
