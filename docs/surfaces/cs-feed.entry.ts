// ABOUTME: Bundle entry for the cs-feed mod's surfaces: the mod's draw functions with the lab's fixtures, as one page global.
// ABOUTME: Built by docs/surfaces/build.sh into docs/surfaces/cs-feed.js, a plain script the file:// lab loads.
import { surfaces } from './cs-feed.fixtures.ts'

;(globalThis as { CsFeedSurfaces?: unknown }).CsFeedSurfaces = { surfaces }
