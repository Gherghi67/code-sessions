// ABOUTME: Tests for the rows the lab draws as Claude Code 2.1.310 draws them around the mods' words: toast, dialog, command reply, menu, log, working line, footer, hint, turn line.
// ABOUTME: Every expected row is worked by hand from the 2.1.310 bundle's components and the mods' tables, never read off the lab's own output.
import { test, expect } from 'bun:test'
import { SURFACES, state, surface } from './surfaces.ts'
const { layoutScreen, toText } = require('../mods-layout.js')

const screen = (id: string, cols = 80) => toText(layoutScreen(state(id).draw(cols, 'light'), cols)).map((r: string) => r.replace(/\s+$/, ''))
const grid = (id: string, cols = 80) => layoutScreen(state(id).draw(cols, 'light'), cols)

test('every chrome surface comes from a mod bundle and draws the words of that mod', () => {
  const chrome = SURFACES.filter((s: any) => s.source === 'chrome').map((s: any) => s.id)
  expect(chrome).toEqual([
    'cs.toast', 'cs.ask', 'cs.command', 'cs.menu', 'cs.log',
    'cs-feed.command', 'cs-feed.menu', 'cs-feed.log', 'cs-feed.Spinner', 'cs-feed.SessionMode', 'cs-feed.ToolProgress', 'cs-feed.TurnDuration',
    'cs-update.toast', 'cs-update.command', 'cs-update.menu',
  ])
})

// JF: the box is min(cols - 2, 44) wide at most, its words wrapped at four
// cells less; at 80 cols `cs: queued: fix the login redirect` (34 cells)
// fits one row, so the box is 34 + 4 = 38 wide, at the right edge.
test('a short toast is a round dim box at the top right, the plugin name on its own row', () => {
  const pad = ' '.repeat(42)
  expect(screen('cs.toast/queued')).toEqual([
    `${pad}╭${'─'.repeat(36)}╮`,
    `${pad}│ ${'cs'.padEnd(34)} │`,
    `${pad}│ cs: queued: fix the login redirect │`,
    `${pad}╰${'─'.repeat(36)}╯`,
  ])
  const g = grid('cs.toast/queued')
  expect([g.rows[0][42].st.dim, g.rows[1][44].st.dim, g.rows[2][44].st.dim]).toEqual([true, true, false])
})

// wrap-ansi {trim:false, hard:true} at 40: `this` ends row one at exactly 40,
// so the space before `conversation's` starts row two; `(75%);` leaves row
// two at 39 and the space after it fits, ending the row at 40.
test('a toast wrapped at forty cells keeps the space wrap-ansi carries, and its box is 44 wide', () => {
  const pad = ' '.repeat(36)
  expect(screen('cs.toast/force-below-start')).toEqual([
    `${pad}╭${'─'.repeat(42)}╮`,
    `${pad}│ ${'cs'.padEnd(40)} │`,
    `${pad}│ cs: CS_ROTATE_FORCE_CTX=70 is below this │`,
    `${pad}│  conversation's starting context (75%);  │`,
    `${pad}│ ${'not forcing a rotation'.padEnd(40)} │`,
    `${pad}╰${'─'.repeat(42)}╯`,
  ])
})

// Four rows at 40: the third holds rows three and four joined by a space,
// cut to 39 cells and `…`.
test('a toast past three rows joins the rest into the third and cuts it', () => {
  const pad = ' '.repeat(36)
  expect(screen('cs.toast/band-option')).toEqual([
    `${pad}╭${'─'.repeat(42)}╮`,
    `${pad}│ ${'cs'.padEnd(40)} │`,
    `${pad}│ ${'cs: the band draws no prompt bars: '.padEnd(40)} │`,
    `${pad}│ ${'cs.bandBars is the most bars the band '.padEnd(40)} │`,
    `${pad}│ draws, a whole number of 1 or more; got… │`,
    `${pad}╰${'─'.repeat(42)}╯`,
  ])
})

// M9 with Bw's single-question chips (hideSubmitTab: one question, not
// multiSelect): no arrows, no Submit; options numbered with the typed-text
// row counted, `Chat about this` after it, then the key hints.
test('the wrap dialog draws its chip, question, numbered options, the typed-text row and Chat about this', () => {
  expect(screen('cs.ask/wrap')).toEqual([
    '─'.repeat(80),
    ' ☐ Wrap',
    '',
    'Run /wrap for this session?',
    '',
    '❯ 1. Yes, wrap up',
    '  2. Not now',
    '  3. Type something.',
    '─'.repeat(80),
    '  4. Chat about this',
    '',
    'Enter to select · ↑/↓ to navigate · Esc to cancel',
  ])
  const g = grid('cs.ask/wrap')
  expect([g.rows[1][1].st.bg, g.rows[1][1].st.color, g.rows[5][0].st.color, g.rows[5][5].st.color, g.rows[6][5].st.color, g.rows[7][5].st.color]).toEqual(['permission', 'inverseText', 'suggestion', 'suggestion', '', 'inactive'])
})

test('the queue dialog says task or tasks by its count, and moving the focus moves the pointer', () => {
  expect(screen('cs.ask/queue-start-one')[3]).toBe('Start the 1 queued task now?')
  expect(screen('cs.ask/queue-start-many').slice(3, 9)).toEqual(['Start the 3 queued tasks now?', '', '❯ 1. Start', '  2. Not yet', '  3. Compact', '  4. Type something.'])
  expect(screen('cs.ask/wrap-not-now').slice(5, 7)).toEqual(['  1. Yes, wrap up', '❯ 2. Not now'])
})

// nl then Yn: the echo on the user-message ground, then `  ⎿  ` dim and the
// reply in the default ink.
test('a command reply echoes the command and hangs the reply under the connector', () => {
  expect(screen('cs.command/queue-added')).toEqual(['❯ /queue fix the login redirect', '  ⎿  Queued: fix the login redirect'])
  const g = grid('cs.command/queue-added')
  expect([g.rows[0][0].st.color, g.rows[0][0].st.bg, g.rows[0][79].st.bg, g.rows[1][2].st.dim, g.rows[1][5].st.dim]).toEqual(['inactive', 'userMessageBackground', 'userMessageBackground', true, false])
  expect(screen('cs.command/rail-count')).toEqual(['❯ /cs 9', '  ⎿  cs: the rail has 4 prompts'])
})

// Ye: name column = longest `/name` + 5 = 11, so `/queue` gets 3 spaces and
// `/cs` 6 after the two-cell pointer column.
test('the slash menu lists the mod commands with their descriptions in one column, the selected one in the suggestion ink', () => {
  expect(screen('cs.menu/queue-selected')).toEqual([
    "  ❯ /queue   Add a task to this cs session's walk-away queue, or list it.",
    "    /cs      Scroll the transcript along the band's rail of prompts.",
  ])
  const g = grid('cs.menu/queue-selected')
  expect([g.rows[0][2].st.color, g.rows[0][13].st.color, g.rows[1][4].st.dim, g.rows[1][13].st.dim]).toEqual(['suggestion', 'suggestion', true, true])
})

// /feed's description is 71 cells and the room is 80 - 13 - 4 = 63: Ue cuts
// at 63, the rest starts with a space, and the second row sits under the
// description column.
test('a description past the room carries to a second row under the description column', () => {
  expect(screen('cs-feed.menu/feed-selected')).toEqual([
    '  ❯ /feed      Chat view for this session: on, off, clean, normal, raw, or one',
    `  ${' '.repeat(13)}setting`,
    "    /helpers   Show each helper's own work, call by call",
  ])
})

// jg: the ⏺ mark in a two-cell column, then `<plugin>: <text>`, both
// inactive. cs's own lines start with `cs:`, so the plugin name doubles.
test('a log row names the plugin before the text, in the inactive ink', () => {
  expect(screen('cs.log/transcript-unread')).toEqual(['⏺ cs: cs: the transcript could not be read: EACCES'])
  expect(screen('cs-feed.log/clock-stopped')).toEqual(['⏺ cs-feed: clock stopped: cs-feed: $.state.set: tick refused'])
  expect(grid('cs.log/transcript-unread').rows[0][2].st.color).toBe('inactive')
})

// Rn and nn: a blank row, the glyph in two cells, the message (cs-feed's,
// with its suffix ''), a space, then `(24s · ↓ 1.2k tokens)` dim.
test("the working line carries cs-feed's message in the engine's row, its time and tokens dim", () => {
  expect(screen('cs-feed.Spinner/engine')).toEqual(['', '✻ Working… (24s · ↓ 1.2k tokens)'])
  expect(screen('cs-feed.Spinner/thinking')).toEqual(['', '✻ Thinking (24s · ↓ 1.2k tokens)'])
  expect(screen('cs-feed.Spinner/working')[1]).toBe('✻ Working · step 3 (24s · ↓ 1.2k tokens)')
  expect(screen('cs-feed.Spinner/writing')[1]).toBe('✻ Writing · step 3 (24s · ↓ 1.2k tokens)')
  expect(screen('cs-feed.Spinner/helpers')[1]).toBe('✻ Working · step 3 · 2 helpers working (24s · ↓ 1.2k tokens)')
  const g = grid('cs-feed.Spinner/thinking')
  expect([g.rows[1][0].st.color, g.rows[1][2].st.color, g.rows[1][11].st.dim]).toEqual(['claude', 'claude', true])
})

// vj: modes joined by ` & `, dim, at the right of a row two cells in.
test("the footer joins the engine's modes and cs-feed's with an ampersand, at the right", () => {
  const modes = 'memory paused & feed clean · /feed to switch'
  expect(screen('cs-feed.SessionMode/clean')).toEqual([`${' '.repeat(80 - 2 - modes.length)}${modes}`])
  expect(screen('cs-feed.SessionMode/engine')).toEqual([`${' '.repeat(80 - 2 - 13)}memory paused`])
})

test('with the feed on the background hint and the turn line are gone; off, the engine draws them', () => {
  expect(screen('cs-feed.ToolProgress/engine')).toEqual(['     (ctrl+b to run in background)'])
  expect(screen('cs-feed.ToolProgress/feed-on')).toEqual([])
  expect(screen('cs-feed.TurnDuration/engine')).toEqual(['✻ Baked for 3s · done 3:45 PM'])
  expect(screen('cs-feed.TurnDuration/feed-on')).toEqual([])
})

test('cs-update hands the engine its toast, its replies and its menu row', () => {
  expect(screen('cs-update.toast/declined').slice(1, 4).map((r: string) => r.trim())).toEqual([
    `│ ${'cs-update'.padEnd(40)} │`,
    `│ ${'cs 2026.11.2 is available · run cs '.padEnd(40)} │`,
    '│ -update to install it, or /cs-update for │',
  ])
  expect(screen('cs-update.command/notes-open')).toEqual(['❯ /cs-update', '  ⎿  Release notes are in the side pane.'])
  // The description is 62 cells and the room 80 - 15 - 4 = 61: Ue breaks at
  // the space before `it.`.
  expect(screen('cs-update.menu/selected')).toEqual(['  ❯ /cs-update   Release notes for the pending cs update, with 1 to install', `  ${' '.repeat(15)}it.`])
})

test('every toast, log line, reply and dialog the mods export has its own state', () => {
  const ids = (id: string) => surface(id).states.map((s: any) => s.id)
  expect(ids('cs.toast').length).toBe(26)
  expect(ids('cs.log').length).toBe(7)
  expect(ids('cs-feed.log').length).toBe(6)
  expect(ids('cs-update.toast')).toEqual(['declined', 'not-recorded'])
  expect(ids('cs-update.command')).toEqual(['not-lead', 'nothing-pending', 'notes-open'])
})
