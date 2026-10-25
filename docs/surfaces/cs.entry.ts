// ABOUTME: Bundle entry for the cs mod's band: the mod's drawBand with the lab's band facts, as one page global.
// ABOUTME: Built by docs/surfaces/build.sh into docs/surfaces/cs.js; the variants gallery reads its STATES and band() too.
import { CHORDS, PROMPTS, STATES, band, countdownStep, facts, surfaces } from './cs.fixtures.ts'

;(globalThis as { CsSurfaces?: unknown }).CsSurfaces = { surfaces, STATES, CHORDS, PROMPTS, band, countdownStep, facts }
