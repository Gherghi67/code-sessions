// ABOUTME: The rows Claude Code 2.1.310 draws around a mod's words (toast, ask dialog, command reply, slash menu row, log row, working line, footer modes, background hint, turn line), redrawn as engine trees.
// ABOUTME: Read off the 2.1.310 bundle's own components (named per function); the words inside come from the mods' exported tables. Colours are theme keys the lab page resolves.
import type { RenderElement } from 'claude-code'
import { elements } from './registry.ts'

// Cells a string takes: one per code point, as every word these rows carry
// is (no wide or combining characters reach them).
const cells = (s: string): number => Array.from(s).length

// A line broken into rows no wider than `width` as wrap-ansi breaks it with
// {trim:false, hard:true} (2.1.310's Ip in "wrap" mode): a word that does not
// fit moves to a new row whole, one wider than a row breaks across rows, and
// the space between two words ends a row while it fits, else starts the next.
export function wrapRows(line: string, width: number): string[] {
  const rows: string[][] = []
  let row: string[] = []
  const next = (start: string[] = []) => { rows.push(row); row = start }
  line.split(' ').forEach((word, i) => {
    let used = row.length
    if (i > 0) {
      if (used >= width) { next(); used = 0 }
      row.push(' ')
      used++
    }
    const chars = Array.from(word)
    if (chars.length > width) {
      const thisRow = 1 + Math.floor((chars.length - (width - used) - 1) / width)
      const nextRow = Math.floor((chars.length - 1) / width)
      if (nextRow < thisRow) next()
      let shown = row.length
      chars.forEach((c, k) => {
        if (shown + 1 <= width) row.push(c)
        else { next([c]); shown = 0 }
        shown++
        if (shown === width && k < chars.length - 1) { next(); shown = 0 }
      })
      return
    }
    if (used + chars.length > width && used > 0 && chars.length > 0) next()
    row = row.concat(chars)
  })
  rows.push(row)
  return rows.map(r => r.join(''))
}

// $7e: a toast's text with every line break as U+FFFD (Sa:
// `n.replace(/[\n\r\u2028\u2029]/g,"\uFFFD")`), so it is one line.
const oneLine = (text: string): string => text.replace(/[\n\r\u2028\u2029]/g, '\uFFFD')

// A toast (dV and JF): a round, dim-bordered box at the transcript's top
// right, one cell of padding each side, the plugin's name dim on its own first
// row, then the words ($7e) wrapped at the box's room, at most three rows, the
// third holding the rest joined by spaces and cut with `…`. The box is no
// wider than 44 cells or the terminal less two (UIe, ate), and no wider than
// its widest row and the four cells of frame (jIe). Drawn at rest: the slide
// in from the right edge and the leaving fade are motion.
const TOAST_WIDEST = 44
const TOAST_FRAME = 4
const TOAST_ROWS = 3
export function toast(plugin: string, text: string, cols: number): RenderElement {
  const el = elements()
  const room = Math.max(1, Math.min(Math.max(1, cols - 2), TOAST_WIDEST))
  const wrapped = wrapRows(oneLine(text), Math.max(1, room - TOAST_FRAME))
  const lines = [...wrapped.slice(0, TOAST_ROWS - 1), wrapped.slice(TOAST_ROWS - 1).join(' ')].filter((line, i) => i === 0 || line !== '')
  const width = Math.min(room, Math.max(cells(plugin), ...lines.map(cells)) + TOAST_FRAME)
  return el.Box({ width: cols, justifyContent: 'flex-end', children: [
    el.Box({ width, flexDirection: 'column', borderStyle: 'round', borderDimColor: true, paddingX: 1, children: [
      el.Text({ dimColor: true, wrap: 'truncate-end', children: plugin }),
      ...lines.map(line => el.Text({ wrap: 'truncate-end', children: line })),
    ] }),
  ] })
}

// A toast outside the fullscreen renderer, where 2.1.310's toast() hands it
// to addNotification as `text:U7e(plugin,text)`, `${fJ(e)}: ${$7e(n)}`, and
// Pwe draws it: `e(n,{color:a.color,dimColor:!a.color,wrap:"truncate",
// children:a.text})`, one row, dim since a toast has no colour, cut with `…`.
// It sits first in the footer's right-hand column (uhe: `alignItems:
// "flex-end"`, `children:[x,Ge]`, the notification above the modes), the
// footer row two cells in from each side. Drawn alone: the prompt hint on the
// left and the modes under it are not, nor the two other places Pwe draws:
// the row above the prompt while a timed hint holds it (`toastOnRow1`), and a
// pane header's `▔` rule (Uu).
export function inlineToast(plugin: string, text: string, cols: number): RenderElement {
  const el = elements()
  return el.Box({ width: cols, paddingX: 2, flexDirection: 'column', alignItems: 'flex-end', children: [
    el.Text({ dimColor: true, wrap: 'truncate', children: `${plugin}: ${oneLine(text)}` }),
  ] })
}

// A rule across the terminal (Ql with no title): `─` in the inactive ink.
const rule = (cols: number): RenderElement => elements().Text({ color: 'inactive', children: '─'.repeat(cols) })

// The dialog `$.ui.ask` opens (M9, one single-select question): a rule; the
// header chip ` ☐ header ` on the permission ink (Bw, no arrows and no Submit
// tab, since one question hides them); the question bold; each option as
// `❯ 1. label`, the pointer and the label in the suggestion ink on the row
// that has the focus; the row Claude Code adds for typed text (`Type
// something.`); a rule; `Chat about this`; and the keys under it. The
// numbers count the typed-text row, and Chat about this comes after it. Each
// key is a hint (q: `[d," to ",s]`) and ve joins them with a dim ` · `
// (`a>0&&e(n,{dimColor:!0,children:" \xB7 "})`). This is the dialog without
// a screen reader: with one (`uo=rt()`), Chat about this is an option of the
// list (`Qr=uo&&!D.multiSelect?[{type:"text",value:"__chat__",label:"Chat
// about this"}]:[]`) and the rule and the keys are not drawn (`Rs=!uo&&...`).
export type Dialog = { question: string; header: string; options: readonly string[] }
export function askDialog(dialog: Dialog, cols: number, focus = 0): RenderElement {
  const el = elements()
  const pointer = (on: boolean) => on ? el.Text({ color: 'suggestion', children: '❯' }) : el.Text({ children: ' ' })
  const digits = String(dialog.options.length + 1).length
  const other = dialog.options.length + 1
  return el.Box({ flexDirection: 'column', children: [
    rule(cols),
    el.Box({ flexDirection: 'column', children: [
      el.Box({ marginBottom: 1, children: [el.Box({ children: [el.Text({ backgroundColor: 'permission', color: 'inverseText', children: ` ☐ ${dialog.header} ` })] })] }),
      el.Box({ gap: 1, children: [el.Text({ bold: true, color: 'text', children: dialog.question })] }),
      el.Box({ flexDirection: 'column', children: [
        el.Box({ marginTop: 1, flexDirection: 'column', children: [
          ...dialog.options.map((label, i) => el.Box({ gap: 1, children: [
            pointer(i === focus),
            el.Text({ dimColor: true, children: `${i + 1}.`.padEnd(digits + 1) }),
            el.Text({ color: i === focus ? 'suggestion' : undefined, children: label }),
          ] })),
          el.Box({ gap: 1, children: [
            pointer(focus === dialog.options.length),
            el.Box({ children: [
              el.Box({ flexShrink: 0, children: [el.Text({ dimColor: true, children: `${other}.`.padEnd(digits + 2) })] }),
              el.Text({ color: 'inactive', children: 'Type something.' }),
            ] }),
          ] }),
        ] }),
        el.Box({ flexDirection: 'column', children: [
          rule(cols),
          el.Box({ gap: 1, children: [pointer(false), el.Text({ children: `${other + 1}. Chat about this` })] }),
        ] }),
        el.Box({ marginTop: 1, children: [el.Text({ color: 'inactive', dimColor: true, children: 'Enter to select · ↑/↓ to navigate · Esc to cancel' })] }),
      ] }),
    ] }),
  ] })
}

// A slash command and its reply in the transcript: the command echoed as the
// person's row (nl: `❯ /name args` on the user-message ground), then the
// reply under the `  ⎿  ` connector, the connector dim and the reply drawn as
// Markdown in the default ink (Yn), led by the name of the plugin that
// answered it (A2n). A mod's command answers with text alone, never as an
// error, so the error ink Yn also has is not drawn here.
export function commandReply(plugin: string, command: string, args: string, reply: string): RenderElement {
  const el = elements()
  return el.Box({ flexDirection: 'column', children: [
    el.Box({ flexDirection: 'column', backgroundColor: 'userMessageBackground', paddingRight: 1, children: [
      el.Text({ children: [el.Text({ color: 'inactive', children: '❯' }), ' ', el.Text({ color: 'text', children: `/${[command, args].filter(Boolean).join(' ')}` })] }),
    ] }),
    el.Box({ children: [
      el.Text({ dimColor: true, children: '  ⎿  ' }),
      el.Box({ flexDirection: 'column', flexGrow: 1, children: [el.Markdown({ text: `${plugin}: ${reply}` })] }),
    ] }),
  ] })
}

// Rows of the slash menu (RPe and Ye), two cells in: `❯ ` on the selected row
// and two spaces on the others, the name, spaces to the name column (the
// longest name listed plus five; past 40% of the terminal, that 40% plus the
// pointer's two cells, fewer when the description lane is narrower: ee, Ao),
// then the description, cut where the terminal ends less four cells and
// carried to a second row under the description column at its last space
// (Ue). The selected row is in the suggestion ink, the others dim. A command
// a mod registers is a local one: no `(plugin)` mark, no lane, and its
// argument hint is not a menu column. Claude Code cuts a name wider than its
// column less four cells (`Ct=V-2-W`); the lab draws names whole.
export type MenuCommand = { name: string; description: string }
export function menuRows(commands: readonly MenuCommand[], selected: number, cols: number): RenderElement {
  const el = elements()
  const widest = Math.max(...commands.map(c => cells(`/${c.name}`))) + 5
  const cap = Math.floor(cols * 0.4)
  const pointer = cells('❯ ')
  const lane = cols - cap - 4 - 1
  const column = widest > cap ? cap + (lane < 0 ? pointer : Math.min(pointer, lane)) : widest
  const room = Math.max(0, cols - column - 4)
  return el.Box({ paddingX: 2, children: [el.Box({ flexDirection: 'column', children: commands.flatMap((c, i) => {
    const on = i === selected
    const ink = on ? 'suggestion' : undefined
    const name = `/${c.name}`
    const [first, rest] = firstRow(c.description, room)
    const row = el.Text({ wrap: 'truncate', children: [
      el.Text({ color: ink, dimColor: !on, children: on ? '❯ ' : '  ' }),
      el.Text({ color: ink, dimColor: !on, children: name }),
      el.Text({ color: ink, dimColor: !on, children: ' '.repeat(Math.max(0, column - cells(name) - 2)) }),
      el.Text({ color: ink, dimColor: !on, children: first }),
    ] })
    if (rest === '') return [row]
    return [row, el.Text({ wrap: 'truncate', children: [' '.repeat(column), el.Text({ color: ink, dimColor: !on, children: cut(rest, Math.max(0, cols - column - 4)) })] })]
  }) })] })
}

// Ue: the words that fit `room`, broken at the last space, and the rest.
function firstRow(text: string, room: number): [string, string] {
  if (room <= 0 || cells(text) <= room) return [text, '']
  const head = Array.from(text).slice(0, room).join('')
  const after = Array.from(text).slice(room).join('')
  if (after.startsWith(' ')) return [head, after.trimStart()]
  const space = head.lastIndexOf(' ')
  return space > 0 ? [head.slice(0, space), text.slice(space + 1)] : [head, after]
}

// A text no wider than `room`, its last cell `…` when cut.
function cut(text: string, room: number): string {
  if (cells(text) <= room) return text
  return room < 1 ? '' : Array.from(text).slice(0, room - 1).join('') + '…'
}

// A `$.ui.log` row (a notice, jg): the `⏺` mark in a two-cell column, then
// `<plugin>: <text>` wrapped ten cells short of the terminal, both in the
// inactive ink. Claude Code adds the plugin's name itself.
export function logRow(plugin: string, text: string, cols: number): RenderElement {
  const el = elements()
  return el.Box({ width: cols, children: [
    el.Box({ minWidth: 2, children: [el.Text({ color: 'inactive', children: '⏺' })] }),
    el.Box({ flexDirection: 'column', width: cols - 10, children: [el.Text({ color: 'inactive', wrap: 'wrap', children: `${plugin}: ${text}` })] }),
  ] })
}

// The working line (Rn and nn), one blank row above it: the spinner's glyph
// in a two-cell column, the message and its suffix (`…` unless the hook says
// otherwise, and none after a message that ends in `…` or `...`) in the
// claude ink, then the dim tail in parentheses, its parts joined by ` · `:
// the time, and `↓` and the tokens in a two-cell column.
// Drawn still: the glyph is one frame (`✻`) and the shimmer that runs along
// the message is not drawn.
export type Working = { message: string; suffix: string; elapsed: string; tokens: string }
export function workingLine(w: Working): RenderElement {
  const el = elements()
  const dim = (s: string) => el.Text({ dimColor: true, children: s })
  return el.Box({ flexDirection: 'column', children: [el.Box({ flexWrap: 'wrap', marginTop: 1, children: [
    el.Box({ width: 2, height: 1, children: [el.Text({ color: 'claude', children: '✻' })] }),
    el.Text({ color: 'claude', children: w.suffix === '…' && /(…|\.\.\.)$/.test(w.message) ? w.message : w.message + w.suffix }),
    el.Text({ children: ' ' }),
    dim('('), dim(w.elapsed), dim(' · '),
    el.Box({ children: [el.Box({ width: 2, children: [dim('↓')] }), dim(`${w.tokens} tokens`)] }),
    dim(')'),
  ] })] })
}

// The footer's modes (vj, inside the right-hand column uhe, its row two
// cells in from each side): the labels joined by ` & `, dim, at the right.
// The prompt hint on the left of that row is not drawn here.
export function footerModes(modes: readonly string[], cols: number): RenderElement {
  const el = elements()
  return el.Box({ width: cols, paddingX: 2, justifyContent: 'flex-end', children: modes.length === 0 ? [] : [el.Text({ dimColor: true, children: modes.join(' & ') })] })
}

// The background hint under a running tool call (z): five cells in, dim.
export function backgroundHint(hint: string): RenderElement {
  const el = elements()
  return el.Box({ flexDirection: 'column', children: hint === '' ? [] : [el.Box({ paddingLeft: 5, children: [el.Text({ dimColor: true, children: hint })] })] })
}

// The line a finished turn leaves (its row in the turn's message list): a dim
// `✻` in a two-cell column, then `<verb> for <time>` and ` · done <clock>`,
// dim. The verb is one of eight, picked by the message's id.
export function turnLine(verb: string, duration: string, done: string): RenderElement {
  const el = elements()
  return el.Box({ children: [
    el.Box({ minWidth: 2, children: [el.Text({ dimColor: true, children: '✻' })] }),
    el.Text({ children: [el.Text({ dimColor: true, children: `${verb} for ${duration} · done ${done}` })] }),
  ] })
}

// What a hook that takes a row away leaves: nothing.
export function nothing(): RenderElement {
  return elements().Box({})
}
