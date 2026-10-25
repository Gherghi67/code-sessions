// ABOUTME: Tests for the moments the lab draws a moving state at: each state that moves turns `t` into the clock the mod reads, and a still state ignores it.
// ABOUTME: Glyphs, counts and inks are read by hand off the mods' arrays and constants and the 2.1.310 bundle's spinner, never off the lab's own output.
import { test, expect } from 'bun:test'
import { SURFACES, state } from './surfaces.ts'
const { layout, layoutScreen, toText } = require('../mods-layout.js')

const rows = (id: string, t: number) => toText(layout(state(id).draw(80, 'light', t), 80)).map((r: string) => r.replace(/\s+$/, ''))
const cell = (id: string, t: number, r: number, c: number) => layout(state(id).draw(80, 'light', t), 80).rows[r][c]
const screen = (id: string, t: number) => toText(layoutScreen(state(id).draw(80, 'light', t), 80)).map((r: string) => r.replace(/\s+$/, ''))

// draw.tsx:77 `braille[Math.floor(pen.cx.now / 70) % braille.length]`, with
// words.ts braille = ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏: one glyph per 70 ms; the batch's
// time is its start to now (verdict.ts:245), 42 s at the state's start.
test("a running batch turns the braille spinner every 70 ms and counts its time from the state's start", () => {
  expect(rows('cs-feed.ToolGroup/batch-running', 0)[0]).toBe('       ⠋ 3 helpers · 1 done · 2 running · 42s ›')
  expect(rows('cs-feed.ToolGroup/batch-running', 70)[0]).toBe('       ⠙ 3 helpers · 1 done · 2 running · 42s ›')
  expect(rows('cs-feed.ToolGroup/batch-running', 140)[0]).toBe('       ⠹ 3 helpers · 1 done · 2 running · 42s ›')
  // 1000 / 70 = 14.28, frame 14, glyph 4; 43 s.
  expect(rows('cs-feed.ToolGroup/batch-running', 1000)[0]).toBe('       ⠼ 3 helpers · 1 done · 2 running · 43s ›')
})

// register.tsx:412 hands drawBand `Math.floor(cx.now / 70)`, and draw.tsx:144
// draws `braille[frame % braille.length]`; the head's time is
// elapsed(now - batch start), 1m 12s at the start.
test('the helpers band turns its spinner per 70 ms frame and its head counts on', () => {
  expect(rows('cs-feed.AbovePrompt/helpers-running', 0)[0]).toBe('       ⠋ 3 helpers · 1 done · 2 running · 1m 12s')
  expect(rows('cs-feed.AbovePrompt/helpers-running', 70)[0]).toBe('       ⠙ 3 helpers · 1 done · 2 running · 1m 12s')
  expect(rows('cs-feed.AbovePrompt/helpers-running', 140)[0]).toBe('       ⠹ 3 helpers · 1 done · 2 running · 1m 12s')
  // 9 s on: frame 128, glyph 8; 81 s is 1m 21s.
  expect(rows('cs-feed.AbovePrompt/helpers-running', 9000)[0]).toBe('       ⠇ 3 helpers · 1 done · 2 running · 1m 21s')
  // Settled, the spinner is the still mark, and the head's time still runs
  // (verdict.ts:508 counts from the batch's start whenever one is known).
  expect(rows('cs-feed.AbovePrompt/helpers-settled', 9000)[0]).toBe('       ● 3 helpers · 3 done · 1m 21s')
})

// draw.tsx:145 `breathing[Math.floor(frame / 2) % breathing.length]`, with
// breathing = · • ● •: a step per two 70 ms frames.
test('the background band breathes its mark one step per two frames', () => {
  const mark = (t: number) => cell('cs-feed.AbovePrompt/background', t, 0, 7).ch
  expect([0, 70, 140, 280, 420, 560].map(mark)).toEqual(['·', '·', '•', '●', '•', '·'])
  // 8 s on: frame 114, step 57, the second glyph; its tail counts from 42 s to 50 s.
  expect(rows('cs-feed.AbovePrompt/background', 8000)[0]).toBe('       • Running in the background · Building the     · 50s · you can keep')
})

test("a running helper's line and the Helpers pane count the seconds on", () => {
  expect(rows('cs-feed.ToolUse/helper-running', 3000)).toEqual(['       Map the draw code · running · 1m 15s ›'])
  expect(rows('cs-feed.Pane.cs-feed-helpers/working', 3000)[0]).toBe('● Explore · working · 1m 15s')
  const mixed = rows('cs-feed.Pane.cs-feed-helpers/mixed', 3000)
  expect([mixed[0], mixed[4]]).toEqual(['● Explore · working · 1m 15s', '○ Plan · finished · 30s'])
  expect(rows('cs-feed.AbovePrompt/desktop', 3000)).toEqual(['42% · 5h 17% · week Helper · Map the draw code · 1m 15s ⚗ Test · bun test · 15s'])
})

// startCountdown: `left -= 1` once a second; countdownColor: crit when
// `left < CRIT_AT` (5), amber when `left <= AMBER_AT` (10), else the session's
// palette colour (orange, 217,119,87); AMBER_LIGHT 180,83,9, CRIT_LIGHT 215,0,21.
test('the countdown ticks a second at a time and walks its ink from the session colour to amber to crit', () => {
  const at = (t: number) => ({ line: rows('cs.AbovePrompt/countdown-session', t)[1], ink: cell('cs.AbovePrompt/countdown-session', t, 1, 4).st.color })
  expect(at(0)).toEqual({ line: '  ● /clear in 15s  ·  ctrl+x  1 /clear now', ink: 'rgb(217,119,87)' })
  expect(at(4999)).toEqual({ line: '  ● /clear in 11s  ·  ctrl+x  1 /clear now', ink: 'rgb(217,119,87)' })
  expect(at(5000)).toEqual({ line: '  ● /clear in 10s  ·  ctrl+x  1 /clear now', ink: 'rgb(180,83,9)' })
  expect(at(10000)).toEqual({ line: '  ● /clear in 5s  ·  ctrl+x  1 /clear now', ink: 'rgb(180,83,9)' })
  expect(at(11000)).toEqual({ line: '  ● /clear in 4s  ·  ctrl+x  1 /clear now', ink: 'rgb(215,0,21)' })
  // At zero the count holds: the tick that reaches it is the last.
  expect(at(15000)).toEqual({ line: '  ● /clear in 0s  ·  ctrl+x  1 /clear now', ink: 'rgb(215,0,21)' })
  expect(at(60000)).toEqual(at(15000))
  expect(rows('cs.AbovePrompt/countdown', 3000)[1]).toBe('  ● /clear in 4s  ·  ctrl+x  1 /clear now')
})

// gateWord: `finishing <task> · gate ${gateElapsed(secs)}`, gateElapsed pads
// the seconds past a minute to two digits.
test("the /finish gate's word counts its time on, padded past a minute", () => {
  expect(rows('cs.AbovePrompt/gate-running', 999)[1]).toBe('  ● finishing fix-auth · gate 1m 12s')
  expect(rows('cs.AbovePrompt/gate-running', 1000)[1]).toBe('  ● finishing fix-auth · gate 1m 13s')
  expect(rows('cs.AbovePrompt/gate-running', 53000)[1]).toBe('  ● finishing fix-auth · gate 2m 05s')
  expect(rows('cs.AbovePrompt/survey-gate', 53000)[4]).toBe('  finishing fix-auth · gate 2m 05s')
})

// 2.1.310's working line: `frame: Hn(T)`, `Hn(l) = Math.round(EUe(l, 2000) *
// (DIn().length - 1))`, `EUe(r,t) = (1 - Math.cos(2*Math.PI*r/t)) / 2`, DIn()
// = · ✢ ✳ ✶ ✻ ✽ off ghostty, Ife drawing `wUe()[frame % 12]`, the mirrored
// twelve, so frame 0..5 is DIn's own glyph. T is the shared clock read on
// a grid: `Wa(requesting ? 50 : 100)` asks for 50 or 100 ms and Wa rounds
// it up to whole 16 ms frames, `Math.ceil(o / 16) * 16`, so T steps 64 ms
// while requesting and 112 while responding, `Math.floor(now / h) * h`.
// The lab's clock reads 750 ms at the state's start: T = 704 on the 64 ms
// grid, EUe = (1 - cos 126.7°) / 2 = 0.799, x 5 = 4.00, frame 4, ✻.
// The time is `un(elapsed)`: whole seconds floored under a minute, then
// `${m}m ${Math.round(s)}s` with the 60 carried.
test("the working line breathes its glyph over two seconds and counts its time as 2.1.310's un", () => {
  const line = (t: number) => screen('cs-feed.Spinner/thinking', t)[1]
  expect(line(0)).toBe('✻ Thinking (24s · ↓ 1.2k tokens)')
  // Clock 800, T 768: EUe = (1 - cos 138.2°) / 2 = 0.873, x 5 = 4.37, frame
  // 4, ✻. A 50 ms grid would keep T at 800: EUe 0.905, x 5 = 4.52, ✽.
  expect(line(50)).toBe('✻ Thinking (24s · ↓ 1.2k tokens)')
  // Clock 1000, T 960: EUe = 0.996, x 5 = 4.98, frame 5.
  expect(line(250)).toBe('✽ Thinking (24s · ↓ 1.2k tokens)')
  // Clock 2000, T 1984: EUe = 0.0006, frame 0; 25 s.
  expect(line(1250)).toBe('· Thinking (25s · ↓ 1.2k tokens)')
  // Clock 1250, T 1216: EUe = 0.889, x 5 = 4.45, frame 4.
  expect(line(500)).toBe('✻ Thinking (24s · ↓ 1.2k tokens)')
  // Writing, on the 112 ms grid: clock 800, T 784: EUe = 0.889, x 5 = 4.45,
  // frame 4, ✻. A 100 ms grid would keep T at 800: ✽.
  expect(screen('cs-feed.Spinner/writing', 50)[1]).toBe('✻ Writing · step 3 (24s · ↓ 1.2k tokens)')
  expect(line(35999).slice(1)).toBe(' Thinking (59s · ↓ 1.2k tokens)')
  expect(line(36000).slice(1)).toBe(' Thinking (1m 0s · ↓ 1.2k tokens)')
  // 119.5 s: Math.round(59.5) is 60, carried into the minutes.
  expect(line(95500).slice(1)).toBe(' Thinking (2m 0s · ↓ 1.2k tokens)')
})

// Every state that moves names the step its mod redraws at and how long the
// lab plays it: the 70 ms pulse, the 1 s tick, the working line's 64 ms
// clock (112 ms while Claude writes), and the countdown's own length. A
// clock that counts up plays five minutes rounded up to a whole tick, so the
// scrubber's last step is the state's end: 4286 x 70 = 300020, 4688 x 64 =
// 300032, 2679 x 112 = 300048.
test('each moving state declares its tick and length, and every other state is still', () => {
  const moving = SURFACES.flatMap((s: any) => s.states.filter((st: any) => st.motion).map((st: any) => `${s.id}/${st.id} ${st.motion.tick} ${st.motion.duration}`))
  const pulse = '70 300020', second = 1000, minutes = 300000
  expect(moving).toEqual([
    `cs.AbovePrompt/countdown ${second} 7000`,
    `cs.AbovePrompt/gate-running ${second} ${minutes}`,
    `cs.AbovePrompt/countdown-session ${second} 15000`,
    `cs.AbovePrompt/countdown-crit ${second} 3000`,
    `cs.AbovePrompt/survey-gate ${second} ${minutes}`,
    `cs-feed.ToolUse/helper-running ${second} ${minutes}`,
    `cs-feed.ToolGroup/batch-running ${pulse}`,
    `cs-feed.ToolGroup/batch-opened ${pulse}`,
    `cs-feed.AbovePrompt/helpers-running ${pulse}`,
    `cs-feed.AbovePrompt/helpers-settled ${second} ${minutes}`,
    `cs-feed.AbovePrompt/helpers-overflow ${pulse}`,
    `cs-feed.AbovePrompt/background ${pulse}`,
    `cs-feed.AbovePrompt/background-test ${pulse}`,
    `cs-feed.AbovePrompt/background-narrow ${pulse}`,
    `cs-feed.AbovePrompt/desktop ${second} ${minutes}`,
    `cs-feed.Pane.cs-feed-helpers/working ${second} ${minutes}`,
    `cs-feed.Pane.cs-feed-helpers/mixed ${second} ${minutes}`,
    `cs-feed.Spinner/engine 64 300032`,
    `cs-feed.Spinner/engine-ellipsis 64 300032`,
    `cs-feed.Spinner/thinking 64 300032`,
    `cs-feed.Spinner/working 64 300032`,
    `cs-feed.Spinner/call 64 300032`,
    `cs-feed.Spinner/writing 112 300048`,
    `cs-feed.Spinner/helpers 64 300032`,
  ])
})

// A still state draws one moment whatever t it is handed; a moving one draws
// something else within its length, so neither declaration is idle.
test('a still state ignores t, and a moving one moves within its length', () => {
  const paint = (st: any, t: number) => JSON.stringify(layoutScreen(st.draw(80, 'light', t), 80).rows.map((r: any[]) => r.map(c => [c.ch, c.st])))
  const wrong: string[] = []
  for (const s of SURFACES) for (const st of s.states) {
    const at0 = paint(st, 0), later = [st.motion?.tick ?? 70, 1000, 61000].map(t => paint(st, t))
    const moves = later.some(p => p !== at0)
    if (moves !== Boolean(st.motion)) wrong.push(`${s.id}/${st.id} ${st.motion ? 'declares motion and stands still' : 'moves undeclared'}`)
  }
  expect(wrong).toEqual([])
  expect(rows('cs.AbovePrompt/idle', 5000)).toEqual(rows('cs.AbovePrompt/idle', 0))
  expect(rows('cs-feed.ToolGroup/batch-done', 5000)).toEqual(rows('cs-feed.ToolGroup/batch-done', 0))
})

// The count the scrubber reads beside t: the seconds left, where there is one.
test('a countdown state says its seconds left at a moment', () => {
  expect([0, 2999, 3000, 7000, 9000].map(t => state('cs.AbovePrompt/countdown').motion.count(t))).toEqual(['7s left', '5s left', '4s left', '0s left', '0s left'])
  expect(state('cs-feed.Spinner/thinking').motion.count).toBeUndefined()
})
