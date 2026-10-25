// ABOUTME: Bundle entry for the cs-update mod's surfaces: the mod's drawPane with the lab's fixtures, as one page global.
// ABOUTME: Built by docs/surfaces/build.sh into docs/surfaces/cs-update.js, a plain script the file:// lab loads.
import { surfaces } from './cs-update.fixtures.ts'

;(globalThis as { CsUpdateSurfaces?: unknown }).CsUpdateSurfaces = { surfaces }
